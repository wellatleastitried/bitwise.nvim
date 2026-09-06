--- Arbitrary-width bit vectors with tri-state bits.
---
--- This module is intentionally free of any Neovim API usage so that it can be
--- unit tested with a plain Lua interpreter.
---
--- A bit vector stores its bits little-endian: index 1 is the least significant
--- bit. Every bit is one of:
---   * `0`  -- known zero
---   * `1`  -- known one
---   * `-1` -- unknown (`M.U`), i.e. only determinable at runtime
---
--- All arithmetic is performed on the bit array itself (never on Lua numbers),
--- which keeps 64-bit results exact regardless of the host Lua's number type.
---@class bitwise.Bits
---@field width integer
---@field signed boolean
---@field bits integer[] little-endian array of 0 / 1 / -1

local M = {}

--- Sentinel value for an unknown bit.
M.U = -1

local Bits = {}
Bits.__index = Bits
M.Bits = Bits

---@param v any
---@return boolean
function M.is_bits(v)
  return getmetatable(v) == Bits
end

--- Create a new bit vector filled with `fill`.
---@param width integer
---@param signed boolean|nil
---@param fill integer|nil defaults to 0
---@return bitwise.Bits
function M.new(width, signed, fill)
  assert(type(width) == "number" and width >= 1 and width <= 128, "invalid width")
  fill = fill or 0
  local bits = {}
  for i = 1, width do
    bits[i] = fill
  end
  return setmetatable({ width = width, signed = signed and true or false, bits = bits }, Bits)
end

--- A fully unknown value of the given width.
---@param width integer
---@param signed boolean|nil
---@return bitwise.Bits
function M.unknown(width, signed)
  return M.new(width, signed, M.U)
end

---@param arr integer[] little-endian bit array
---@param width integer
---@param signed boolean|nil
---@return bitwise.Bits
function M.from_array(arr, width, signed)
  local v = M.new(width, signed, 0)
  for i = 1, width do
    v.bits[i] = arr[i] or 0
  end
  return v
end

function Bits:clone()
  return M.from_array(self.bits, self.width, self.signed)
end

--- Get bit `i` (1 = least significant). Out-of-range reads return 0.
---@param i integer
---@return integer
function Bits:get(i)
  local b = self.bits[i]
  if b == nil then
    return 0
  end
  return b
end

--- The most significant (sign) bit.
---@return integer
function Bits:msb()
  return self:get(self.width)
end

---@return boolean true when every bit is known
function Bits:is_known()
  for i = 1, self.width do
    if self.bits[i] == M.U then
      return false
    end
  end
  return true
end

---@return boolean true when every bit is unknown
function Bits:is_fully_unknown()
  for i = 1, self.width do
    if self.bits[i] ~= M.U then
      return false
    end
  end
  return true
end

--- Knowledge classification of this value.
---@return "known"|"partial"|"unknown"
function Bits:knowledge()
  local known, unknown = 0, 0
  for i = 1, self.width do
    if self.bits[i] == M.U then
      unknown = unknown + 1
    else
      known = known + 1
    end
  end
  if unknown == 0 then
    return "known"
  elseif known == 0 then
    return "unknown"
  end
  return "partial"
end

--- Number of significant bits required to represent the value, ignoring
--- redundant leading sign/zero extension. Unknown bits always count.
---@return integer
function Bits:significant_width()
  local ext = self.signed and self:msb() or 0
  local w = 1
  for i = self.width, 1, -1 do
    if self.bits[i] ~= ext then
      w = self.signed and math.min(i + 1, self.width) or i
      break
    end
  end
  return math.max(w, 1)
end

--- Number of bits worth displaying: leading bits that merely repeat the
--- extension pattern (sign/zero for known values, `?` for unknown-extended
--- values) carry no information and can be hidden.
---@return integer
function Bits:visual_width()
  local top = self:get(self.width)
  local ext = (top == M.U) and M.U or (self.signed and top or 0)
  local w = 1
  for i = self.width, 1, -1 do
    if self:get(i) ~= ext then
      if ext ~= M.U and self.signed then
        w = math.min(i + 1, self.width)
      else
        w = i
      end
      break
    end
  end
  return math.max(w, 1)
end

--- Reinterpret / resize the value.
---
--- Narrowing truncates (as C-style casts do). Widening sign-extends for signed
--- values and zero-extends otherwise. Returns the new value plus whether any
--- information was lost.
---@param width integer
---@param signed boolean|nil defaults to `self.signed`
---@return bitwise.Bits, boolean truncated
function Bits:resize(width, signed)
  if signed == nil then
    signed = self.signed
  end
  local out = M.new(width, signed, 0)
  local ext = self.signed and self:msb() or 0
  for i = 1, width do
    if i <= self.width then
      out.bits[i] = self:get(i)
    else
      out.bits[i] = ext
    end
  end
  local truncated = false
  if width < self.width then
    local keep_ext = signed and out:msb() or 0
    for i = width + 1, self.width do
      if self:get(i) ~= keep_ext then
        truncated = true
        break
      end
    end
  end
  return out, truncated
end

--------------------------------------------------------------------------------
-- Tri-state logic
--------------------------------------------------------------------------------

local U = M.U

---@param a integer
---@param b integer
---@return integer
local function and_bit(a, b)
  if a == 0 or b == 0 then
    return 0
  end
  if a == U or b == U then
    return U
  end
  return 1
end

local function or_bit(a, b)
  if a == 1 or b == 1 then
    return 1
  end
  if a == U or b == U then
    return U
  end
  return 0
end

local function xor_bit(a, b)
  if a == U or b == U then
    return U
  end
  return (a ~= b) and 1 or 0
end

local function not_bit(a)
  if a == U then
    return U
  end
  return a == 1 and 0 or 1
end

M.bit_ops = { ["and"] = and_bit, ["or"] = or_bit, ["xor"] = xor_bit, ["not"] = not_bit }

---@param a bitwise.Bits
---@param b bitwise.Bits
---@param fn fun(a: integer, b: integer): integer
---@return bitwise.Bits
local function zip(a, b, fn)
  local width = math.max(a.width, b.width)
  local signed = a.signed and b.signed
  local x = a.width == width and a or (a:resize(width))
  local y = b.width == width and b or (b:resize(width))
  local out = M.new(width, signed, 0)
  for i = 1, width do
    out.bits[i] = fn(x:get(i), y:get(i))
  end
  return out
end

function M.band(a, b)
  return zip(a, b, and_bit)
end

function M.bor(a, b)
  return zip(a, b, or_bit)
end

function M.bxor(a, b)
  return zip(a, b, xor_bit)
end

---@param a bitwise.Bits
---@return bitwise.Bits
function M.bnot(a)
  local out = M.new(a.width, a.signed, 0)
  for i = 1, a.width do
    out.bits[i] = not_bit(a:get(i))
  end
  return out
end

--- Left shift by a constant amount.
---@param a bitwise.Bits
---@param amount integer
---@return bitwise.Bits
function M.shl(a, amount)
  local out = M.new(a.width, a.signed, 0)
  for i = 1, a.width do
    local src = i - amount
    out.bits[i] = (src >= 1) and a:get(src) or 0
  end
  return out
end

--- Right shift by a constant amount.
---@param a bitwise.Bits
---@param amount integer
---@param arithmetic boolean when true the sign bit is replicated
---@return bitwise.Bits
function M.shr(a, amount, arithmetic)
  local fill = arithmetic and a:msb() or 0
  local out = M.new(a.width, a.signed, 0)
  for i = 1, a.width do
    local src = i + amount
    out.bits[i] = (src <= a.width) and a:get(src) or fill
  end
  return out
end

--- Increment by one, wrapping at the vector width. Unknown bits poison the
--- carry chain from the point they are reached.
---@param a bitwise.Bits
---@return bitwise.Bits
function M.increment(a)
  local out = M.new(a.width, a.signed, 0)
  local carry = 1
  for i = 1, a.width do
    local b = a:get(i)
    if carry == 0 then
      out.bits[i] = b
    elseif b == U then
      for j = i, a.width do
        out.bits[j] = U
      end
      return out
    else
      out.bits[i] = xor_bit(b, carry)
      carry = and_bit(b, carry)
    end
  end
  return out
end

--- Add two vectors, wrapping at the width. The carry chain is exact until the
--- first unknown bit, after which every remaining bit becomes unknown.
---@param a bitwise.Bits
---@param b bitwise.Bits
---@return bitwise.Bits
function M.add(a, b)
  assert(a.width == b.width, "width mismatch")
  local out = M.new(a.width, a.signed and b.signed, 0)
  local carry = 0
  for i = 1, a.width do
    local x, y = a:get(i), b:get(i)
    if x == U or y == U or carry == U then
      for j = i, a.width do
        out.bits[j] = U
      end
      return out
    end
    local sum = x + y + carry
    out.bits[i] = sum % 2
    carry = sum >= 2 and 1 or 0
  end
  return out
end

--- Two's complement subtraction.
---@param a bitwise.Bits
---@param b bitwise.Bits
---@return bitwise.Bits
function M.sub(a, b)
  return M.add(a, M.negate(b))
end

--- Multiply, wrapping at the width. Any unknown bit in either operand makes the
--- whole product unknown: partial knowledge does not survive multiplication in
--- any useful form.
---@param a bitwise.Bits
---@param b bitwise.Bits
---@return bitwise.Bits
function M.mul(a, b)
  assert(a.width == b.width, "width mismatch")
  local signed = a.signed and b.signed
  if not a:is_known() or not b:is_known() then
    return M.unknown(a.width, signed)
  end
  local out = M.new(a.width, signed, 0)
  for i = 1, b.width do
    if b:get(i) == 1 then
      out = M.add(out, M.shl(a, i - 1))
    end
  end
  out.signed = signed
  return out
end

--------------------------------------------------------------------------------
-- Decimal string arithmetic (exact for any width)
--------------------------------------------------------------------------------

---@param s string decimal digits
---@return string quotient, integer remainder
local function dec_div2(s)
  local out, rem = {}, 0
  for i = 1, #s do
    local d = rem * 10 + (s:byte(i) - 48)
    out[i] = string.char(48 + math.floor(d / 2))
    rem = d % 2
  end
  local q = table.concat(out):gsub("^0+", "")
  return (q == "" and "0" or q), rem
end

---@param s string decimal digits
---@param add integer 0 or 1
---@return string
local function dec_mul2_add(s, add)
  local out, carry = {}, add
  for i = #s, 1, -1 do
    local d = (s:byte(i) - 48) * 2 + carry
    out[#out + 1] = string.char(48 + (d % 10))
    carry = math.floor(d / 10)
  end
  while carry > 0 do
    out[#out + 1] = string.char(48 + (carry % 10))
    carry = math.floor(carry / 10)
  end
  local rev = {}
  for i = #out, 1, -1 do
    rev[#rev + 1] = out[i]
  end
  local s2 = table.concat(rev):gsub("^0+", "")
  return s2 == "" and "0" or s2
end

local DIGITS = {}
for i = 0, 9 do
  DIGITS[string.char(48 + i)] = i
end
for i = 0, 5 do
  DIGITS[string.char(97 + i)] = 10 + i
  DIGITS[string.char(65 + i)] = 10 + i
end

--- Convert a non-negative digit string in `base` into an unbounded bit array.
---@param digits string
---@param base integer 2, 8, 10 or 16
---@return integer[]|nil bits little-endian, nil when the digits are invalid
local function digits_to_bit_array(digits, base)
  digits = digits:gsub("_", ""):gsub("'", "")
  if digits == "" then
    return nil
  end
  local arr = {}
  if base == 10 then
    for i = 1, #digits do
      if not DIGITS[digits:sub(i, i)] or DIGITS[digits:sub(i, i)] >= 10 then
        return nil
      end
    end
    local s = digits:gsub("^0+", "")
    if s == "" then
      return { 0 }
    end
    while s ~= "0" do
      local q, r = dec_div2(s)
      arr[#arr + 1] = r
      s = q
    end
    return arr
  end
  local per = ({ [2] = 1, [8] = 3, [16] = 4 })[base]
  if not per then
    return nil
  end
  for i = #digits, 1, -1 do
    local d = DIGITS[digits:sub(i, i)]
    if not d or d >= base then
      return nil
    end
    for k = 0, per - 1 do
      arr[#arr + 1] = math.floor(d / (2 ^ k)) % 2
    end
  end
  return arr
end

M._digits_to_bit_array = digits_to_bit_array

--- Parse a literal magnitude into a bit vector of `width`.
---@param digits string
---@param base integer
---@param width integer
---@param signed boolean|nil
---@return bitwise.Bits|nil value, boolean|string overflow_or_error
function M.from_digits(digits, base, width, signed)
  local arr = digits_to_bit_array(digits, base)
  if not arr then
    return nil, "invalid literal digits"
  end
  local out = M.new(width, signed, 0)
  local overflow = false
  for i = 1, #arr do
    if i <= width then
      out.bits[i] = arr[i]
    elseif arr[i] == 1 then
      overflow = true
    end
  end
  -- A positive literal that fills the sign bit of a signed vector overflows too.
  if signed and not overflow and out:msb() == 1 then
    overflow = true
  end
  return out, overflow
end

--- Negate (two's complement).
---@param a bitwise.Bits
---@return bitwise.Bits
function M.negate(a)
  return M.increment(M.bnot(a))
end

--- Render the value as a decimal string. Returns nil when any bit is unknown.
---@param a bitwise.Bits
---@return string|nil
function M.to_decimal(a)
  if not a:is_known() then
    return nil
  end
  local neg = a.signed and a:msb() == 1
  local v = neg and M.negate(a) or a
  local s = "0"
  for i = v.width, 1, -1 do
    s = dec_mul2_add(s, v:get(i))
  end
  if neg and s ~= "0" then
    s = "-" .. s
  end
  return s
end

--- Render the value as an unsigned hexadecimal string. Returns nil when any bit
--- is unknown.
---@param a bitwise.Bits
---@return string|nil
function M.to_hex(a)
  if not a:is_known() then
    return nil
  end
  local nibbles = {}
  for i = a.width, 1, -4 do
    local lo = math.max(i - 3, 1)
    local v = 0
    for j = i, lo, -1 do
      v = v * 2 + a:get(j)
    end
    nibbles[#nibbles + 1] = string.format("%X", v)
  end
  local s = table.concat(nibbles):gsub("^0+", "")
  return "0x" .. (s == "" and "0" or s)
end

--- Bit characters from most significant to least significant.
---@param a bitwise.Bits
---@param width integer|nil display width, defaults to the vector width
---@return string[]
function M.to_chars(a, width)
  width = width or a.width
  local out = {}
  for i = width, 1, -1 do
    local b = a:get(i)
    out[#out + 1] = (b == U) and "?" or tostring(b)
  end
  return out
end

--- Convert to a Lua number. Only safe (and only defined) for fully known values
--- that fit in 53 bits of magnitude; returns nil otherwise.
---@param a bitwise.Bits
---@return number|nil
function M.to_number(a)
  local s = M.to_decimal(a)
  if not s then
    return nil
  end
  local n = tonumber(s)
  if not n or math.abs(n) > 2 ^ 53 then
    return nil
  end
  return n
end

--- Build a bit vector from a Lua integer (used mostly by tests).
---@param n number
---@param width integer
---@param signed boolean|nil
---@return bitwise.Bits
function M.from_number(n, width, signed)
  local neg = n < 0
  local mag = string.format("%.0f", math.abs(n))
  local v = M.from_digits(mag, 10, width, false)
  v = v or M.new(width, signed, 0)
  if neg then
    v = M.negate(v)
  end
  v.signed = signed and true or false
  return v
end

return M
