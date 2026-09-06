--- Java adapter (also a reasonable fit for other JVM C-like grammars).

local util = require("bitwise-visualizer.languages.util")

---@param node table
---@return integer|nil width, boolean|nil signed
local function literal_type(node)
  local suffix = (node.suffix or ""):lower()
  if suffix == "l" then
    return 64, true
  end
  return nil, nil
end

---@type bitwise.Adapter
return {
  name = "java",
  nodes = {
    binary = util.set({ "binary_expression" }),
    unary = util.set({ "unary_expression" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({
      "decimal_integer_literal",
      "hex_integer_literal",
      "binary_integer_literal",
      "octal_integer_literal",
      "character_literal",
    }),
  },
  binary_operators = util.set({ "&", "|", "^", "<<", ">>", ">>>", "+", "-", "*" }),
  unary_operators = { ["~"] = "~", ["-"] = "-", ["+"] = "+" },
  parse_literal = function(text)
    if text:sub(1, 1) == "'" then
      return util.scan_char(text)
    end
    return util.scan_integer(text, { separators = "_", octal_prefix = false, leading_zero_octal = true })
  end,
  semantics = {
    default_width = 32,
    default_signed = true,
    -- Java masks the shift count with width-1.
    shift_semantics = "mask",
    arithmetic_shift_right = true,
    logical_shift_op = ">>>",
    literal_type = literal_type,
  },
}
