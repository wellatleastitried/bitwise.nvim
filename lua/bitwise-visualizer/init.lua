--- Public API and update orchestration.
---
---   require("bitwise-visualizer").setup({ ... })
---
--- The module wires together parser -> evaluator -> formatter -> renderer and
--- owns the (small) amount of state the plugin needs.

local config = require("bitwise-visualizer.config")
local parser = require("bitwise-visualizer.parser")
local evaluator = require("bitwise-visualizer.evaluator")
local formatter = require("bitwise-visualizer.formatter")
local renderer = require("bitwise-visualizer.renderer")
local languages = require("bitwise-visualizer.languages")

local M = {}

M.languages = languages

local augroup = nil
local timer = nil

--- Per-buffer memo of the last evaluated expression.
---@type table<integer, table>
local cache = {}

--- `config.options` is the single source of truth for whether the plugin is
--- on: `enable()`/`disable()`/`toggle()` persist their state there (through
--- `M.configure`) rather than through a separate runtime flag, so this and
--- `cfg.enabled` can never disagree.
---@return boolean
local function enabled()
  return config.get().enabled
end

---@param a table|nil
---@param b table|nil
---@return boolean
local function same_range(a, b)
  if not a or not b then
    return false
  end
  return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

---@param bufnr integer
---@param cfg table
---@return boolean, string|nil
local function buffer_eligible(bufnr, cfg)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false, "invalid buffer"
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false, "special buffer"
  end
  local ft = vim.bo[bufnr].filetype
  if vim.tbl_contains(cfg.disabled_filetypes or {}, ft) then
    return false, "filetype disabled"
  end
  if vim.api.nvim_buf_line_count(bufnr) > (cfg.max_buffer_lines or math.huge) then
    return false, "buffer too large"
  end
  return true
end

--- Analyse the expression at a position without touching any decorations.
---@param bufnr integer|nil
---@param row integer|nil 0-indexed
---@param col integer|nil 0-indexed
---@param overrides table|nil configuration overrides for this call
---@return table|nil result { ir, rendered, inline, lang, range }, string|nil reason
function M.analyze(bufnr, row, col, overrides)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cfg = config.get()
  if overrides then
    cfg = vim.tbl_deep_extend("force", vim.deepcopy(cfg), overrides)
  end

  if row == nil or col == nil then
    local pos = vim.api.nvim_win_get_cursor(0)
    row = row or (pos[1] - 1)
    col = col or pos[2]
  end

  local ok, reason = buffer_eligible(bufnr, cfg)
  if not ok then
    return nil, reason
  end

  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  if not line then
    return nil, "no such line"
  end
  if #line > (cfg.max_line_length or math.huge) then
    return nil, "line too long"
  end

  local found, why = parser.find_at(bufnr, row, col, {
    trigger = cfg.trigger,
    subexpression = cfg.subexpression,
    operators = cfg.operators or {},
    resolve = cfg.resolve_identifiers ~= false,
    generic = cfg.generic_fallback ~= false,
  })
  if not found then
    return nil, why
  end

  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = cache[bufnr]
  if
    cached
    and cached.tick == tick
    and cached.version == config.version
    and cached.lang == found.lang
    and not overrides
    and same_range(cached.range, found.ir.range)
    and cached.op == found.ir.op
  then
    return cached.result
  end

  local evaluated, err = evaluator.evaluate(found.ir, {
    width = cfg.width,
    semantics = found.adapter.semantics,
    max_nodes = cfg.max_nodes,
  })
  if not evaluated then
    return nil, err
  end

  for _, note in ipairs(found.adapter.notes or {}) do
    evaluated.notes[#evaluated.notes + 1] = note
  end

  local rendered, why2 = formatter.format(evaluated, cfg)
  if not rendered then
    return nil, why2
  end

  local inline = formatter.format_inline(evaluated, cfg)

  local result = {
    ir = evaluated,
    rendered = rendered,
    inline = inline,
    lang = found.lang,
    range = found.ir.range,
    row = found.ir.range[1],
    on_operator = found.on_operator,
  }

  if not overrides then
    cache[bufnr] = {
      tick = tick,
      version = config.version,
      lang = found.lang,
      range = found.ir.range,
      op = found.ir.op,
      result = result,
    }
  end
  return result
end

--- Recompute and redraw for the current window.
---@param opts table|nil { force = boolean }
---@return boolean drawn
function M.refresh(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local cfg = config.get()

  if not enabled() and not opts.force then
    renderer.clear(bufnr)
    return false
  end
  if vim.api.nvim_get_mode().mode:find("i") and not cfg.update.in_insert and not opts.force then
    renderer.clear(bufnr)
    return false
  end

  local result = M.analyze(bufnr)
  if not result then
    renderer.clear(bufnr)
    return false
  end

  return renderer.render(bufnr, result.row, result, cfg)
end

--- Debounced refresh used by the autocommands.
local function schedule_refresh()
  local cfg = config.get()
  local delay = math.max(cfg.update.debounce or 0, 0)
  if timer then
    timer:stop()
  else
    timer = (vim.uv or vim.loop).new_timer()
  end
  if delay == 0 then
    vim.schedule(function()
      pcall(M.refresh)
    end)
    return
  end
  timer:start(
    delay,
    0,
    vim.schedule_wrap(function()
      pcall(M.refresh)
    end)
  )
end

local function clear_autocmds()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
end

local function create_autocmds()
  clear_autocmds()
  local cfg = config.get()
  augroup = vim.api.nvim_create_augroup("BitwiseVisualizer", { clear = true })

  if cfg.auto then
    vim.api.nvim_create_autocmd(cfg.update.events, {
      group = augroup,
      callback = schedule_refresh,
    })
  end

  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    group = augroup,
    callback = function(args)
      renderer.clear(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = augroup,
    callback = function(args)
      if not config.get().update.in_insert then
        renderer.clear(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = augroup,
    callback = function(args)
      cache[args.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    callback = renderer.setup_highlights,
  })
end

--- Configure the plugin. Safe to call repeatedly.
---@param opts table|nil
---@return bitwise.Config
function M.setup(opts)
  local cfg = config.setup(opts)
  cache = {}
  renderer.setup_highlights()
  renderer.clear_all()
  create_autocmds()
  require("bitwise-visualizer.commands").create()
  if cfg.enabled and cfg.auto then
    vim.schedule(function()
      pcall(M.refresh)
    end)
  end
  return cfg
end

--- Change configuration at runtime and redraw.
---@param patch table
function M.configure(patch)
  config.get(patch)
  cache = {}
  renderer.clear_all()
  create_autocmds()
  if enabled() then
    M.refresh()
  end
  return config.options
end

--- Enable the plugin and turn cursor-following back on.
---
--- Both `enabled` and `auto` are set so that the visualisation actually
--- follows the cursor afterwards, rather than appearing once and then
--- requiring `auto = true` to already have been set separately. Use
--- `configure({ auto = false })` afterwards if you want it enabled but
--- manual-only (see `show()`/`hide()`).
function M.enable()
  M.configure({ enabled = true, auto = true })
end

--- Disable the plugin: stop cursor-following and clear any visualisation.
---
--- Sets `auto = false` along with `enabled` so the two flags never disagree
--- about whether anything is currently following the cursor. `show()` still
--- works on demand while disabled.
function M.disable()
  M.configure({ enabled = false, auto = false })
end

--- Flip between the states produced by `enable()` and `disable()`.
---@return boolean now_enabled
function M.toggle()
  if enabled() then
    M.disable()
    return false
  end
  M.enable()
  return true
end

---@return boolean
function M.is_enabled()
  return enabled()
end

--- Force a one-shot visualisation even when `auto` is off or the plugin is
--- disabled.
---@return boolean drawn
function M.show()
  return M.refresh({ force = true })
end

--- Remove the visualisation from the current buffer.
function M.hide()
  renderer.clear(vim.api.nvim_get_current_buf())
end

--- Plain-text visualisation for the expression at the cursor. Handy for
--- `:messages`, tests, or piping into another window.
---@param overrides table|nil
---@return string[]|nil lines, string|nil reason
function M.render_text(overrides)
  local result, why = M.analyze(nil, nil, nil, overrides)
  if not result then
    return nil, why
  end
  return formatter.to_strings(result.rendered)
end

--- Diagnostic snapshot, mostly for `:checkhealth` and bug reports.
---@return table
function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = vim.api.nvim_win_get_cursor(0)
  local result, why = M.analyze(bufnr, pos[1] - 1, pos[2])
  return {
    enabled = enabled(),
    auto = config.get().auto,
    width = config.get().width,
    language = parser.language_at(bufnr, pos[1] - 1, pos[2]),
    supported_languages = languages.supported(),
    active = renderer.is_active(bufnr),
    expression = result and result.ir.text or nil,
    status = result and result.rendered.status or nil,
    reason = why,
  }
end

return M
