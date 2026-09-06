--- Language adapter registry.
---
--- An adapter describes, for one Tree-sitter language, how to recognise the
--- node types that make up a bitwise expression and how that language's integer
--- semantics behave. Everything else in the plugin is language agnostic.
---
---@class bitwise.Adapter
---@field name string
---@field nodes table<string, table<string, boolean>> node type sets by role
---@field operators table<string, boolean> accepted operator tokens
---@field parse_literal fun(text: string): table|nil { base, digits, suffix }
---@field semantics bitwise.Semantics
---@field notes string[]|nil always-applicable caveats

local M = {}

---@type table<string, bitwise.Adapter>
local registry = {}

--- Aliases mapping a Tree-sitter language name onto a registered adapter.
local aliases = {
  cpp = "c",
  cuda = "c",
  objc = "c",
  arduino = "c",
  typescript = "javascript",
  tsx = "javascript",
  jsx = "javascript",
}

local util = require("bitwise-visualizer.languages.util")

M.set = util.set
M.scan_integer = util.scan_integer
M.common_operators = util.common_operators

--- Register (or replace) an adapter. Exposed so users can add languages
--- without patching the plugin.
---@param adapter bitwise.Adapter
function M.register(adapter)
  assert(type(adapter) == "table" and adapter.name, "adapter must have a name")
  registry[adapter.name] = adapter
end

--- Point a Tree-sitter language at an existing adapter.
---@param lang string
---@param target string
function M.alias(lang, target)
  aliases[lang] = target
end

---@param lang string|nil Tree-sitter language name
---@param allow_generic boolean|nil fall back to the structural adapter
---@return bitwise.Adapter|nil
function M.get(lang, allow_generic)
  if not lang then
    return nil
  end
  local adapter = registry[aliases[lang] or lang]
  if adapter then
    return adapter
  end
  if allow_generic then
    return M.generic
  end
  return nil
end

--- Every language name (adapters plus aliases) the plugin can analyse.
---@return string[]
function M.supported()
  local out, seen = {}, {}
  for name in pairs(registry) do
    if not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  for alias in pairs(aliases) do
    if not seen[alias] then
      seen[alias] = true
      out[#out + 1] = alias
    end
  end
  table.sort(out)
  return out
end

for _, name in ipairs({ "c", "rust", "go", "java", "javascript", "python", "lua" }) do
  M.register(require("bitwise-visualizer.languages." .. name))
end

--- Structural fallback for languages without a dedicated adapter. Not put in
--- the registry: it is only reached explicitly.
M.generic = require("bitwise-visualizer.languages.generic")

return M
