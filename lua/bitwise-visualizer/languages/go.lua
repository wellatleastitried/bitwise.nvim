--- Go adapter. Go spells bitwise NOT as a unary `^` and additionally provides
--- the AND-NOT operator `&^`.

local util = require("bitwise-visualizer.languages.util")
local bits = require("bitwise-visualizer.bits")
local evaluator = require("bitwise-visualizer.evaluator")

-- Registering an operator is all it takes for the evaluator, formatter and
-- renderer to support it.
evaluator.binary_ops["&^"] = {
  name = "andnot",
  apply = function(a, b)
    return bits.band(a, bits.bnot(b))
  end,
}

---@type bitwise.Adapter
return {
  name = "go",
  nodes = {
    binary = util.set({ "binary_expression" }),
    unary = util.set({ "unary_expression" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({ "int_literal" }),
  },
  binary_operators = util.set({ "&", "|", "^", "<<", ">>", "&^", "+", "-", "*" }),
  unary_operators = { ["^"] = "~", ["-"] = "-", ["+"] = "+" },
  parse_literal = function(text)
    return util.scan_integer(text, { separators = "_", octal_prefix = true, leading_zero_octal = true })
  end,
  semantics = {
    default_width = 64, -- `int` is 64 bit on all mainstream Go platforms
    default_signed = true,
    -- Go defines over-wide shifts: the value is simply shifted out.
    shift_semantics = "saturate",
    arithmetic_shift_right = true,
  },
}
