--- Helpers shared by the language adapters.
---
--- Kept separate from `languages/init.lua` so adapter modules can use them
--- without a circular require.

local M = {}

---@param list string[]
---@return table<string, boolean>
function M.set(list)
  local t = {}
  for _, v in ipairs(list) do
    t[v] = true
  end
  return t
end

--- The operator tokens every C-like language shares.
M.common_operators = M.set({ "&", "|", "^", "~", "<<", ">>" })

--- Shared literal scanner for C-family syntax: `0x`, `0b`, `0o`, leading-zero
--- octal, digit separators (`_` and `'`) and trailing type suffixes.
---@param text string
---@param opts table|nil { separators, octal_prefix, leading_zero_octal }
--- Some grammars (notably C) fold a leading sign into the literal token, so the
--- sign is reported separately via the `negative` field.
---@return table|nil literal { base, digits, suffix, negative }
function M.scan_integer(text, opts)
  opts = opts or {}
  local s = text
  if opts.separators then
    s = s:gsub("[" .. opts.separators .. "]", "")
  end
  if s == "" or s:find("%.") then
    return nil -- empty, or a floating point literal
  end

  local negative = false
  local sign = s:sub(1, 1)
  if sign == "-" or sign == "+" then
    negative = sign == "-"
    s = s:sub(2)
    if s == "" then
      return nil
    end
  end

  local base, body
  local prefix = s:sub(1, 2):lower()
  if prefix == "0x" then
    base, body = 16, s:sub(3)
  elseif prefix == "0b" then
    base, body = 2, s:sub(3)
  elseif prefix == "0o" and opts.octal_prefix ~= false then
    base, body = 8, s:sub(3)
  elseif opts.leading_zero_octal and #s > 1 and s:sub(1, 1) == "0" and s:sub(2, 2):match("%d") then
    base, body = 8, s:sub(2)
  else
    base, body = 10, s
  end

  local digit_class = ({ [2] = "[01]", [8] = "[0-7]", [10] = "%d", [16] = "%x" })[base]
  local digits = body:match("^(" .. digit_class .. "+)")
  if not digits then
    return nil
  end
  local suffix = body:sub(#digits + 1)
  if base == 10 and suffix:sub(1, 1):lower() == "e" then
    return nil -- exponent form: not an integer literal
  end
  if suffix ~= "" and not suffix:match("^[%a_][%w_]*$") then
    return nil
  end
  return { base = base, digits = digits, suffix = suffix, negative = negative }
end

--- Character literals such as `'A'`, `'\n'`, `'\x41'` and `'\101'`.
---@param text string
---@return table|nil literal
function M.scan_char(text)
  local body = text:match("^'(.*)'$")
  if not body or body == "" then
    return nil
  end
  local escapes = { n = 10, t = 9, r = 13, a = 7, b = 8, f = 12, v = 11, e = 27 }
  escapes["\\"] = 92
  escapes["'"] = 39
  escapes['"'] = 34
  escapes["?"] = 63
  local code
  if #body == 1 then
    code = body:byte()
  elseif body:sub(1, 1) == "\\" then
    local rest = body:sub(2)
    if rest:match("^[xX]%x+$") then
      code = tonumber(rest:sub(2), 16)
    elseif rest:match("^[0-7]+$") then
      code = tonumber(rest, 8)
    elseif #rest == 1 then
      code = escapes[rest]
    end
  end
  if not code or code > 0x10FFFF then
    return nil
  end
  return { base = 10, digits = tostring(code), suffix = "", negative = false }
end

--------------------------------------------------------------------------------
-- Tree-sitter helpers shared by the parser and by structural (generic) adapters
--------------------------------------------------------------------------------

--- Text of a syntax node, or "" when it cannot be read.
---@param node TSNode
---@param bufnr integer
---@return string
function M.node_text(node, bufnr)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or type(text) ~= "string" then
    return ""
  end
  return text
end

--- Named, non-comment children.
---@param node TSNode
---@return TSNode[]
function M.named_children(node)
  local out = {}
  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" then
      out[#out + 1] = child
    end
  end
  return out
end

--- The token carrying the node's operator: the grammar's `operator` field when
--- it has one, otherwise the first unnamed child that is not a bracket.
---@param node TSNode
---@param bufnr integer
---@return string|nil token, TSNode|nil child
function M.operator_token(node, bufnr)
  local field = node:field("operator")
  if field and field[1] then
    return M.node_text(field[1], bufnr), field[1]
  end
  for child in node:iter_children() do
    if not child:named() then
      local t = child:type()
      if t ~= "(" and t ~= ")" and t ~= "[" and t ~= "]" then
        return t, child
      end
    end
  end
  return nil, nil
end

--- Does the node wrap its single child in brackets?
---@param node TSNode
---@return boolean
function M.is_bracketed(node)
  local open, close = false, false
  for child in node:iter_children() do
    if not child:named() then
      local t = child:type()
      if t == "(" or t == "[" then
        open = true
      elseif t == ")" or t == "]" then
        close = true
      end
    end
  end
  return open and close
end

--- Literal scanner that accepts the integer syntaxes found across languages:
--- C-family prefixes, Ada/VHDL `16#FF#`, Verilog `8'hFF`, Pascal `$FF` / `%1010`,
--- Lisp `#xFF` and plain decimals, with `_` / `'` separators and letter suffixes.
--- Ambiguous forms (a leading zero that might or might not mean octal) are
--- rejected rather than guessed.
---@param text string
---@return table|nil literal { base, digits, suffix, negative }
function M.scan_any_integer(text)
  local s = text
  local negative = false
  local sign = s:match("^([%+%-])")
  if sign then
    negative = sign == "-"
    s = s:sub(2)
  end
  if s == "" then
    return nil
  end

  --- Verilog style: `8'hFF`, `'b1010`.
  local vbase, vdigits = s:match("^%d*'([bBoOdDhH])([%w_]+)$")
  if vbase then
    local bases = { b = 2, o = 8, d = 10, h = 16 }
    return M.finish_literal(vdigits, bases[vbase:lower()], "", negative)
  end

  --- Ada / VHDL style: `16#FF#`, `2#1010#`.
  local abase, adigits = s:match("^(%d+)#([%w_]+)#?$")
  if abase then
    local base = tonumber(abase)
    if base and base >= 2 and base <= 16 then
      return M.finish_literal(adigits, base, "", negative)
    end
    return nil
  end

  local prefixes = {
    ["0x"] = 16,
    ["0X"] = 16,
    ["0b"] = 2,
    ["0B"] = 2,
    ["0o"] = 8,
    ["0O"] = 8,
    ["#x"] = 16,
    ["#b"] = 2,
    ["#o"] = 8,
    ["#d"] = 10,
    ["&h"] = 16,
    ["&H"] = 16,
    ["&o"] = 8,
    ["&O"] = 8,
    ["&b"] = 2,
    ["&B"] = 2,
  }
  local head = s:sub(1, 2)
  if prefixes[head] then
    return M.finish_literal(s:sub(3), prefixes[head], "", negative)
  end
  if s:sub(1, 1) == "$" then
    return M.finish_literal(s:sub(2), 16, "", negative)
  end
  if s:sub(1, 1) == "%" then
    return M.finish_literal(s:sub(2), 2, "", negative)
  end

  -- Plain decimal. A leading zero means octal in some languages and decimal in
  -- others, so refuse it instead of risking a wrong value.
  if s:match("^0%d") then
    return nil
  end
  return M.finish_literal(s, 10, "", negative)
end

--- Split trailing letters off a digit run and validate it against `base`.
---@param body string
---@param base integer
---@param suffix string
---@param negative boolean
---@return table|nil
function M.finish_literal(body, base, suffix, negative)
  body = body:gsub("[_']", "")
  if body == "" then
    return nil
  end
  local digits, extra = body, suffix
  -- Peel a type suffix (`10u8`, `255L`) off bases that cannot contain letters.
  if base ~= 16 then
    local d, tail = body:match("^(%w-)([%a_][%w_]*)$")
    if d and d ~= "" and tail then
      digits, extra = d, tail
    end
  end
  local valid = ("0123456789abcdef"):sub(1, base)
  for c in digits:lower():gmatch(".") do
    if not valid:find(c, 1, true) then
      return nil
    end
  end
  return { base = base, digits = digits, suffix = extra or "", negative = negative }
end

return M
