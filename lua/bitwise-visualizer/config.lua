--- User configuration and defaults.

local M = {}

--- Default configuration. Every value here is chosen so the plugin is useful
--- immediately after installation with no `setup()` call at all.
---@class bitwise.Config
M.defaults = {
  --- Master switch. `false` disables all analysis and rendering.
  enabled = true,

  --- When true the visualisation follows the cursor. When false it is only
  --- shown after an explicit `:BitwiseVisualizerShow` / `show()` call.
  --- `enable()`/`disable()`/`toggle()` set this together with `enabled`, so
  --- the two never disagree; set it directly with `setup()`/`configure()`
  --- for a permanently manual-only setup.
  auto = true,

  --- Bit width used for evaluation and display.
  --- `"auto"`  - use the language's natural width, then shrink the *display*
  ---             to the smallest of `display_widths` that loses no information.
  --- number    - force 8, 16, 32 or 64 bits.
  width = "auto",

  --- Candidate widths for `width = "auto"` display shrinking.
  display_widths = { 8, 16, 32, 64 },

  --- Insert a space every N bits (0 disables grouping).
  group_bits = 4,

  --- Extra columns rendered next to each row.
  show_decimal = true,
  show_hex = false,

  --- Show the source text of each operand as a label.
  show_labels = true,

  --- Render expressions that contain runtime (unknown) operands.
  show_unknown = true,

  --- Render expressions in which *nothing* is known (e.g. `foo() ^ bar()`).
  --- Off by default because such a visualisation carries no information beyond
  --- the shape of the operation.
  show_fully_unknown = false,

  --- Resolve identifiers that provably hold a constant (`int y = 10;`, and
  --- `#define MASK 0xF0` in C) by reading the syntax tree. Only single-assignment
  --- names that are never mutated or address-taken are resolved; everything else
  --- stays unknown.
  resolve_identifiers = true,

  --- Analyse languages that have no dedicated adapter by classifying syntax
  --- nodes structurally. Set to false to restrict the plugin to the languages
  --- listed in `:help bitwise-visualizer-languages`.
  generic_fallback = true,

  --- Show caveats (overflow, undefined shifts, language notes).
  show_notes = true,

  --- Operators to visualise. Set an entry to `false` to ignore it.
  operators = {
    ["&"] = true,
    ["|"] = true,
    ["^"] = true,
    ["~"] = true,
    ["<<"] = true,
    [">>"] = true,
    [">>>"] = true,
    ["&^"] = true,
    ["-"] = true,
    ["+"] = true,
  },

  --- `"expression"` activates anywhere inside the expression;
  --- `"operator"` only when the cursor is on the operator token itself.
  trigger = "expression",

  --- When the cursor is on an operator inside a nested expression, visualise
  --- just that subexpression instead of the whole tree.
  subexpression = true,

  --- Where the virtual lines are drawn: `"above"`, `"below"` or `"eol"`
  --- (a compact single-line summary at the end of the line).
  position = "above",

  --- Rendering backend. `"virt_lines"` is the only built-in one; additional
  --- backends can be registered with `renderer.register_backend()`.
  renderer = "virt_lines",

  --- Update behaviour.
  update = {
    --- Milliseconds to wait after the triggering event before recomputing.
    debounce = 50,
    --- Update while in insert mode.
    in_insert = false,
    --- Autocommand events that trigger a refresh.
    events = { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "BufEnter" },
  },

  --- Guard rails.
  --- Maximum number of IR nodes in an expression before it is ignored.
  max_nodes = 32,
  --- Ignore lines longer than this (generated / minified files).
  max_line_length = 500,
  --- Skip buffers larger than this many lines for cursor-driven updates.
  max_buffer_lines = 100000,

  --- Filetypes to skip entirely (in addition to unsupported languages).
  disabled_filetypes = { "help", "text", "markdown", "TelescopePrompt" },

  --- Highlight groups used by the renderer.
  highlights = {
    one = "BitwiseVisualizerOne",
    zero = "BitwiseVisualizerZero",
    unknown = "BitwiseVisualizerUnknown",
    active = "BitwiseVisualizerActive",
    separator = "BitwiseVisualizerSeparator",
    operator = "BitwiseVisualizerOperator",
    label = "BitwiseVisualizerLabel",
    value = "BitwiseVisualizerValue",
    note = "BitwiseVisualizerNote",
    result = "BitwiseVisualizerResult",
  },
}

---@type bitwise.Config
M.options = vim.deepcopy(M.defaults)

--- Bumped on every configuration change so caches can be invalidated cheaply.
M.version = 1

local VALID_WIDTHS = { [8] = true, [16] = true, [32] = true, [64] = true }

--- Keys whose sub-tables are user-extensible (operator tokens, highlight
--- names) and must therefore not be checked for typos.
local FREEFORM = { operators = true, highlights = true }

--- Warn about misspelled option names instead of silently ignoring them.
---@param opts table
---@param defaults table
---@param prefix string
---@param found string[]
local function collect_unknown(opts, defaults, prefix, found)
  for key, value in pairs(opts) do
    if defaults[key] == nil then
      found[#found + 1] = prefix .. tostring(key)
    elseif
      not FREEFORM[key]
      and type(value) == "table"
      and type(defaults[key]) == "table"
      and not vim.islist(value)
    then
      collect_unknown(value, defaults[key], prefix .. tostring(key) .. ".", found)
    end
  end
end

---@param opts table
---@return string|nil error
local function validate(opts)
  if opts.width ~= nil and opts.width ~= "auto" and not VALID_WIDTHS[opts.width] then
    return "width must be 'auto', 8, 16, 32 or 64"
  end
  if opts.trigger ~= nil and opts.trigger ~= "expression" and opts.trigger ~= "operator" then
    return "trigger must be 'expression' or 'operator'"
  end
  if opts.position ~= nil and not vim.tbl_contains({ "above", "below", "eol" }, opts.position) then
    return "position must be 'above', 'below' or 'eol'"
  end
  if opts.update and opts.update.debounce ~= nil and type(opts.update.debounce) ~= "number" then
    return "update.debounce must be a number"
  end
  return nil
end

--- Merge user options into the active configuration.
---@param opts table|nil
---@return bitwise.Config
function M.setup(opts)
  opts = opts or {}
  local unknown = {}
  collect_unknown(opts, M.defaults, "", unknown)
  if #unknown > 0 then
    table.sort(unknown)
    vim.notify(
      "[bitwise-visualizer] unknown option(s): "
        .. table.concat(unknown, ", ")
        .. " (see :help bitwise-visualizer-configuration)",
      vim.log.levels.WARN
    )
  end
  local err = validate(opts)
  if err then
    vim.notify("[bitwise-visualizer] " .. err, vim.log.levels.ERROR)
    return M.options
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  M.version = M.version + 1
  return M.options
end

--- Read (and optionally patch) the active configuration.
---@param patch table|nil
---@return bitwise.Config
function M.get(patch)
  if patch then
    local err = validate(patch)
    if err then
      vim.notify("[bitwise-visualizer] " .. err, vim.log.levels.ERROR)
      return M.options
    end
    M.options = vim.tbl_deep_extend("force", M.options, patch)
    M.version = M.version + 1
  end
  return M.options
end

--- Restore the shipped defaults.
function M.reset()
  M.options = vim.deepcopy(M.defaults)
  M.version = M.version + 1
end

return M
