--- Python adapter.
---
--- Python integers have arbitrary precision, so any fixed width shown here is a
--- display convention rather than a language rule. Results are still exact as
--- long as they fit in the configured width; when they do not, the evaluator
--- reports the truncation instead of hiding it.

local util = require("bitwise-visualizer.languages.util")

---@type bitwise.Adapter
return {
  name = "python",
  nodes = {
    binary = util.set({ "binary_operator" }),
    unary = util.set({ "unary_operator" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({ "integer" }),
  },
  binary_operators = util.set({ "&", "|", "^", "<<", ">>", "+", "-", "*" }),
  unary_operators = { ["~"] = "~", ["-"] = "-", ["+"] = "+" },
  parse_literal = function(text)
    if text:lower():find("[jl]$") then
      return nil -- complex / legacy long literal
    end
    return util.scan_integer(text, { separators = "_", octal_prefix = true })
  end,
  semantics = {
    default_width = 64,
    default_signed = true,
    -- Python never has undefined shift behaviour; values simply grow or vanish.
    shift_semantics = "saturate",
    arithmetic_shift_right = true,
    unbounded = true,
  },
  notes = { "Python integers are arbitrary precision; the width shown is a display convention" },
}
