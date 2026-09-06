--- Lua adapter (Lua 5.3+ / LuaJIT-with-integers semantics).
---
--- Note the two meanings of `~`: binary it is XOR, unary it is NOT. Lua's `>>`
--- is a *logical* shift, and shifts of 64 or more bits produce zero.

local util = require("bitwise-visualizer.languages.util")

---@type bitwise.Adapter
return {
  name = "lua",
  nodes = {
    binary = util.set({ "binary_expression" }),
    unary = util.set({ "unary_expression" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({ "number" }),
  },
  binary_operators = util.set({ "&", "|", "~", "<<", ">>", "+", "-", "*" }),
  unary_operators = { ["~"] = "~", ["-"] = "-" },
  operator_aliases = { ["~"] = "^" }, -- binary `~` is XOR
  parse_literal = function(text)
    return util.scan_integer(text, { octal_prefix = false })
  end,
  -- tree-sitter-lua names the assignment fields `name` / `value`.
  bindings = { assignment_statement = { "name", "value" } },
  semantics = {
    default_width = 64,
    default_signed = true,
    shift_semantics = "saturate",
    -- Lua's right shift always fills with zeroes.
    arithmetic_shift_right = false,
  },
}
