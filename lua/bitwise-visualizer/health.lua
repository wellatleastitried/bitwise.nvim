--- `:checkhealth bitwise-visualizer`

local M = {}

local start = vim.health.start or vim.health.report_start
local ok = vim.health.ok or vim.health.report_ok
local warn = vim.health.warn or vim.health.report_warn
local err = vim.health.error or vim.health.report_error
local info = vim.health.info or vim.health.report_info

function M.check()
  start("bitwise-visualizer")

  if vim.fn.has("nvim-0.10") == 1 then
    ok("Neovim " .. tostring(vim.version()))
  else
    err("Neovim 0.10 or newer is required")
    return
  end

  if vim.treesitter and vim.treesitter.get_parser then
    ok("Tree-sitter is available")
  else
    err("Tree-sitter is not available")
    return
  end

  local cfg = require("bitwise-visualizer.config").get()
  if cfg.generic_fallback ~= false then
    info("Generic fallback is on: languages without an adapter are analysed structurally")
  else
    info("Generic fallback is off: only languages with an adapter are analysed")
  end

  local languages = require("bitwise-visualizer.languages")
  local available, missing = {}, {}
  for _, lang in ipairs(languages.supported()) do
    if #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", false) > 0 then
      available[#available + 1] = lang
    else
      missing[#missing + 1] = lang
    end
  end

  if #available > 0 then
    ok("Parsers installed: " .. table.concat(available, ", "))
  else
    warn("No parser for any supported language is installed")
  end
  if #missing > 0 then
    info("Supported but not installed: " .. table.concat(missing, ", "))
  end

  info(
    ("enabled=%s auto=%s width=%s position=%s trigger=%s"):format(
      tostring(cfg.enabled),
      tostring(cfg.auto),
      tostring(cfg.width),
      cfg.position,
      cfg.trigger
    )
  )

  if require("bitwise-visualizer").is_enabled() then
    ok("Plugin is enabled")
  else
    warn("Plugin is currently disabled (:BitwiseVisualizerEnable)")
  end
end

return M
