--- C / C++ / Objective-C adapter.

local util = require("bitwise-visualizer.languages.util")

--- Width and signedness implied by an integer literal suffix.
---@param node table IR literal node
---@return integer|nil width, boolean|nil signed
local function literal_type(node)
  local suffix = (node.suffix or ""):lower()
  local width
  if suffix:find("ll") then
    width = 64
  elseif suffix:find("l") then
    width = 64 -- LP64: `long` is 64 bit on the platforms this plugin targets
  end
  local signed
  if suffix:find("u") then
    signed = false
  end
  return width, signed
end

---@type bitwise.Adapter
return {
  name = "c",
  nodes = {
    binary = util.set({ "binary_expression" }),
    unary = util.set({ "unary_expression" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({ "number_literal", "char_literal" }),
  },
  binary_operators = util.set({ "&", "|", "^", "<<", ">>", "+", "-", "*" }),
  unary_operators = { ["~"] = "~", ["-"] = "-", ["+"] = "+" },
  parse_literal = function(text)
    -- Character literals are integers in C; strip any encoding prefix first.
    local without_prefix = text:gsub("^[uUL8]+", "")
    if without_prefix:sub(1, 1) == "'" then
      return util.scan_char(without_prefix)
    end
    return util.scan_integer(text, { separators = "'", leading_zero_octal = true, octal_prefix = false })
  end,
  semantics = {
    default_width = 32,
    default_signed = true,
    -- Shifting by >= the operand width is undefined behaviour in C, so the
    -- evaluator must not pretend to know the result.
    shift_semantics = "undefined",
    arithmetic_shift_right = true,
    literal_type = literal_type,
  },
}
