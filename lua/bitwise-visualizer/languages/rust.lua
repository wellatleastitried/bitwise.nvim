--- Rust adapter. Rust spells bitwise NOT `!`.

local util = require("bitwise-visualizer.languages.util")

local SUFFIX_WIDTH = {
  i8 = 8,
  u8 = 8,
  i16 = 16,
  u16 = 16,
  i32 = 32,
  u32 = 32,
  i64 = 64,
  u64 = 64,
  isize = 64,
  usize = 64,
}

---@param node table
---@return integer|nil width, boolean|nil signed
local function literal_type(node)
  local suffix = (node.suffix or ""):lower()
  if suffix == "" then
    return nil, nil
  end
  local width = SUFFIX_WIDTH[suffix]
  local signed
  if suffix:sub(1, 1) == "u" then
    signed = false
  elseif suffix:sub(1, 1) == "i" then
    signed = true
  end
  return width, signed
end

---@type bitwise.Adapter
return {
  name = "rust",
  nodes = {
    binary = util.set({ "binary_expression" }),
    unary = util.set({ "unary_expression" }),
    paren = util.set({ "parenthesized_expression" }),
    literal = util.set({ "integer_literal" }),
  },
  binary_operators = util.set({ "&", "|", "^", "<<", ">>", "+", "-", "*" }),
  unary_operators = { ["!"] = "~", ["-"] = "-" },
  parse_literal = function(text)
    return util.scan_integer(text, { separators = "_", octal_prefix = true })
  end,
  semantics = {
    default_width = 32, -- `i32` is Rust's default integer type
    default_signed = true,
    -- Debug builds panic and release builds mask; either way the result is not
    -- something we should confidently display.
    shift_semantics = "undefined",
    arithmetic_shift_right = true,
    literal_type = literal_type,
  },
  notes = { "Rust integer types are inferred; the width shown is a best effort" },
}
