--- JavaScript / TypeScript adapter.
---
--- JavaScript converts both operands of a bitwise operator to 32-bit signed
--- integers (`>>>` yields an unsigned result) and masks shift counts with 31.

local util = require("bitwise-visualizer.languages.util")

---@type bitwise.Adapter
return {
  name = "javascript",
  nodes = {
    binary = util.set({ "binary_expression" }),
    unary = util.set({ "unary_expression" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({ "number" }),
  },
  -- Destructuring binds names through pattern-specific node types; listing them
  -- lets the resolver see those writes instead of silently missing them.
  identifier_nodes = util.set({
    "identifier",
    "shorthand_property_identifier",
    "shorthand_property_identifier_pattern",
  }),
  binary_operators = util.set({ "&", "|", "^", "<<", ">>", ">>>", "+", "-", "*" }),
  unary_operators = { ["~"] = "~", ["-"] = "-", ["+"] = "+" },
  parse_literal = function(text)
    if text:sub(-1) == "n" then
      return nil -- BigInt: not 32-bit coerced, do not guess
    end
    return util.scan_integer(text, { separators = "_", octal_prefix = true, leading_zero_octal = true })
  end,
  semantics = {
    default_width = 32,
    default_signed = true,
    shift_semantics = "mask",
    arithmetic_shift_right = true,
    logical_shift_op = ">>>",
    -- `>>>` is specified as ToUint32, so its result is unsigned (unlike Java).
    logical_shift_unsigned = true,
  },
  notes = { "JavaScript coerces bitwise operands to 32-bit signed integers" },
}
