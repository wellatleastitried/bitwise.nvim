--- Decoration management.
---
--- The source buffer is never modified: everything is drawn with extmarks
--- (virtual lines, or virtual text for the `eol` position). Exactly one extmark
--- per buffer is ever alive.

local config = require("bitwise-visualizer.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("bitwise-visualizer")

--- Per-buffer render state, used to skip redundant redraws.
---@type table<integer, table>
local state = {}

--- Default highlight definitions, linked to standard groups so they inherit
--- from any colourscheme.
local default_links = {
  BitwiseVisualizerOne = "String",
  BitwiseVisualizerZero = "Comment",
  BitwiseVisualizerUnknown = "DiagnosticWarn",
  BitwiseVisualizerActive = "DiagnosticOk",
  BitwiseVisualizerSeparator = "NonText",
  BitwiseVisualizerOperator = "Operator",
  BitwiseVisualizerLabel = "Identifier",
  BitwiseVisualizerValue = "Number",
  BitwiseVisualizerNote = "Comment",
  BitwiseVisualizerResult = "Special",
}

--- Create the plugin's highlight groups if they do not exist yet.
function M.setup_highlights()
  for name, link in pairs(default_links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

--- Rendering backends. Additional modes (floating window, split, ...) can be
--- registered here without touching the rest of the plugin.
---@type table<string, fun(bufnr: integer, row: integer, payload: table, cfg: table)>
M.backends = {}

---@param name string
---@param fn fun(bufnr: integer, row: integer, payload: table, cfg: table)
function M.register_backend(name, fn)
  M.backends[name] = fn
end

---@param cfg table
---@param key string|nil
---@return string|nil
local function hl_group(cfg, key)
  if not key then
    return nil
  end
  return cfg.highlights[key]
end

--- Convert formatter chunks into extmark virt_text chunks.
---@param line table[]
---@param cfg table
---@return table[]
local function to_virt_chunks(line, cfg)
  local out = {}
  for _, chunk in ipairs(line) do
    local group = hl_group(cfg, chunk.hl)
    out[#out + 1] = { chunk.text, group }
  end
  if #out == 0 then
    out[1] = { "", nil }
  end
  return out
end

M.backends.virt_lines = function(bufnr, row, payload, cfg)
  local virt_lines = {}
  for _, line in ipairs(payload.rendered.lines) do
    virt_lines[#virt_lines + 1] = to_virt_chunks(line, cfg)
  end
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
    virt_lines = virt_lines,
    virt_lines_above = cfg.position ~= "below",
    hl_mode = "combine",
    right_gravity = false,
  })
end

M.backends.eol = function(bufnr, row, payload, cfg)
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
    virt_text = to_virt_chunks(payload.inline, cfg),
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

--- A cheap structural signature of what is about to be drawn.
---@param row integer
---@param payload table
---@param cfg table
---@return string
local function signature(row, payload, cfg)
  local parts = { tostring(row), cfg.position, tostring(config.version) }
  local lines = payload.rendered and payload.rendered.lines or { payload.inline }
  for _, line in ipairs(lines) do
    for _, chunk in ipairs(line) do
      parts[#parts + 1] = chunk.text
      parts[#parts + 1] = chunk.hl or "-"
    end
    parts[#parts + 1] = "\n"
  end
  return table.concat(parts, "\1")
end

--- Remove any decoration owned by this plugin from `bufnr`.
---@param bufnr integer|nil defaults to the current buffer
function M.clear(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  end
  state[bufnr] = nil
end

--- Remove decorations from every buffer.
function M.clear_all()
  for bufnr in pairs(state) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    end
  end
  state = {}
end

--- Draw a visualisation. Redundant redraws are skipped so that cursor movement
--- inside the same expression costs nothing.
---@param bufnr integer
---@param row integer 0-indexed anchor line
---@param payload table { rendered = ..., inline = ... }
---@param cfg table|nil
---@return boolean drawn
function M.render(bufnr, row, payload, cfg)
  cfg = cfg or config.get()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local backend_name = cfg.position == "eol" and "eol" or (cfg.renderer or "virt_lines")
  local backend = M.backends[backend_name]
  if not backend then
    vim.notify("[bitwise-visualizer] unknown renderer: " .. tostring(backend_name), vim.log.levels.ERROR)
    return false
  end

  local sig = signature(row, payload, cfg)
  local prev = state[bufnr]
  if prev and prev.signature == sig then
    return false
  end

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local ok, err = pcall(backend, bufnr, row, payload, cfg)
  if not ok then
    state[bufnr] = nil
    vim.notify("[bitwise-visualizer] render failed: " .. tostring(err), vim.log.levels.DEBUG)
    return false
  end
  state[bufnr] = { signature = sig, row = row }
  return true
end

--- Is anything currently drawn in this buffer?
---@param bufnr integer|nil
---@return boolean
function M.is_active(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return state[bufnr] ~= nil
end

--- Extmarks currently owned by the plugin (used by the test-suite).
---@param bufnr integer|nil
---@return table[]
function M.extmarks(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  return vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { details = true })
end

return M
