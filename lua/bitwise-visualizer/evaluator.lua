--- Pure evaluator for the language independent bitwise expression IR.
---
--- No Neovim APIs are used here; the module is unit testable with plain Lua.
---
--- IR node shapes (all plain tables, produced by `bitwise-visualizer.parser`):
---
---   { kind = "literal", text, base, digits, suffix }
---   { kind = "binary",  text, op, left, right }
---   { kind = "unary",   text, op, operand }
---   { kind = "paren",   text, inner }
---   { kind = "unknown", text }
---
--- Every evaluated node gains:
---
---   value    bitwise.Bits            the (possibly partially unknown) value
---   status   "known"|"partial"|"unknown"
---   notes    string[]                human readable caveats
---   exact    boolean                 false when semantics had to be guessed

local bits = require("bitwise-visualizer.bits")

local M = {}

--- Semantics used when a language adapter does not provide its own.
---@class bitwise.Semantics
---@field default_width integer
---@field default_signed boolean
---@field shift_semantics "undefined"|"mask"|"saturate"
---@field arithmetic_shift_right boolean
---@field logical_shift_op string|nil
---@field logical_shift_unsigned boolean|nil result of the logical shift is unsigned (JavaScript)
---@field literal_type fun(node: table, ctx: table): integer|nil, boolean|nil
M.default_semantics = {
  default_width = 32,
  default_signed = true,
  shift_semantics = "undefined",
  arithmetic_shift_right = true,
  logical_shift_op = nil,
  logical_shift_unsigned = false,
}

---@param node table
---@return integer
function M.count_nodes(node)
  if type(node) ~= "table" then
    return 0
  end
  local n = 1
  for _, key in ipairs({ "left", "right", "operand", "inner" }) do
    if node[key] then
      n = n + M.count_nodes(node[key])
    end
  end
  return n
end

---@param dst table
---@param src table|nil
local function merge_notes(dst, src)
  if not src then
    return
  end
  local seen = {}
  for _, n in ipairs(dst) do
    seen[n] = true
  end
  for _, n in ipairs(src) do
    if not seen[n] then
      seen[n] = true
      dst[#dst + 1] = n
    end
  end
end

---@param op string
---@return boolean
function M.is_shift(op)
  return op == "<<" or op == ">>" or op == ">>>"
end

--- Operators understood by the evaluator. Adding an entry here (plus letting the
--- language adapter report the token) is all that is required to support a new
--- bitwise operator.
M.binary_ops = {
  ["&"] = { name = "and", apply = bits.band, contributes = "and" },
  ["|"] = { name = "or", apply = bits.bor, contributes = "or" },
  ["^"] = { name = "xor", apply = bits.bxor, contributes = "xor" },
  ["<<"] = { name = "shl", shift = true },
  [">>"] = { name = "shr", shift = true },
  [">>>"] = { name = "ushr", shift = true, logical = true },
  -- Arithmetic is folded so that operands such as `y + 5` can be shown as a
  -- known value, but it never triggers a visualisation on its own.
  ["+"] = { name = "add", apply = bits.add, arith = true },
  ["-"] = { name = "sub", apply = bits.sub, arith = true },
  ["*"] = { name = "mul", apply = bits.mul, arith = true },
}

--- Is this a bitwise operator (as opposed to folded arithmetic)?
---@param op string|nil
---@return boolean
function M.is_bitwise(op)
  if not op then
    return false
  end
  local spec = M.binary_ops[op]
  if spec then
    return not spec.arith
  end
  return op == "~"
end

M.unary_ops = {
  ["~"] = { name = "not", apply = bits.bnot },
  ["-"] = { name = "neg", apply = bits.negate },
  ["+"] = {
    name = "pos",
    apply = function(v)
      return v
    end,
  },
}

---@param ctx table
---@return integer, boolean
local function ctx_type(ctx)
  return ctx.width, ctx.signed
end

---@param node table
---@param ctx table
---@return table evaluated node
local eval

---@param node table
---@param ctx table
---@return table evaluated node
local function eval_node(node, ctx)
  local width, signed = ctx_type(ctx)
  local notes = {}

  if node.kind == "literal" then
    -- Parse the magnitude unsigned, then apply the sign, so that the exact
    -- boundary values (-128 in 8 bits, ...) are not reported as overflow.
    local magnitude, overflow = bits.from_digits(node.digits, node.base, width, false)
    if not magnitude then
      node.value = bits.unknown(width, signed)
      node.status = "unknown"
      node.notes = { "unparsable literal: " .. tostring(node.text) }
      node.exact = false
      return node
    end
    local value = magnitude
    if node.negative then
      value = bits.negate(magnitude)
      if signed and magnitude:msb() == 1 then
        -- Only exactly -2^(width-1) is representable with the sign bit set.
        for i = 1, width - 1 do
          if magnitude:get(i) == 1 then
            overflow = true
            break
          end
        end
      elseif not signed then
        overflow = true -- a negative literal cannot be unsigned
      end
    elseif signed and magnitude:msb() == 1 then
      overflow = true
    end
    value.signed = signed
    if overflow then
      notes[#notes + 1] =
        string.format("literal %s does not fit in %d-bit %s", node.text, width, signed and "signed" or "unsigned")
    end
    node.value = value
    node.status = value:knowledge()
    node.notes = notes
    node.exact = not overflow
    return node
  end

  if node.kind == "unknown" then
    node.value = bits.unknown(width, signed)
    node.status = "unknown"
    node.notes = {}
    node.exact = true
    return node
  end

  if node.kind == "paren" then
    local inner = eval(node.inner, ctx)
    node.value = inner.value
    node.status = inner.status
    node.notes = inner.notes
    node.exact = inner.exact
    return node
  end

  if node.kind == "unary" then
    local operand = eval(node.operand, ctx)
    local spec = M.unary_ops[node.op]
    if not spec then
      node.value = bits.unknown(width, signed)
      node.status = "unknown"
      node.notes = { "unsupported unary operator: " .. tostring(node.op) }
      node.exact = false
      return node
    end
    node.value = spec.apply(operand.value)
    node.status = node.value:knowledge()
    merge_notes(notes, operand.notes)
    node.notes = notes
    node.exact = operand.exact
    return node
  end

  if node.kind == "binary" then
    local left = eval(node.left, ctx)
    local right = eval(node.right, ctx)
    merge_notes(notes, left.notes)
    merge_notes(notes, right.notes)
    local spec = M.binary_ops[node.op]
    if not spec then
      node.value = bits.unknown(width, signed)
      node.status = "unknown"
      node.notes = { "unsupported operator: " .. tostring(node.op) }
      node.exact = false
      node.left, node.right = left, right
      return node
    end

    if spec.shift then
      local sem = ctx.semantics
      local arithmetic = (node.op == ">>") and sem.arithmetic_shift_right ~= false and left.value.signed
      local amount = bits.to_number(right.value)
      local result
      local exact = left.exact and right.exact
      if amount == nil then
        result = bits.unknown(left.value.width, left.value.signed)
        notes[#notes + 1] = "shift amount is not known at compile time"
      else
        if amount < 0 then
          result = bits.unknown(left.value.width, left.value.signed)
          notes[#notes + 1] = "negative shift amount is undefined"
          exact = false
        elseif amount >= left.value.width then
          if sem.shift_semantics == "mask" then
            local masked = amount % left.value.width
            notes[#notes + 1] = string.format("shift count masked to %d (mod %d)", masked, left.value.width)
            amount = masked
            result = nil
          elseif sem.shift_semantics == "saturate" then
            notes[#notes + 1] = "shift count >= width: result is fully shifted out"
            amount = left.value.width
            result = nil
          else
            result = bits.unknown(left.value.width, left.value.signed)
            notes[#notes + 1] =
              string.format("shift count %d >= width %d is undefined behaviour", amount, left.value.width)
            exact = false
          end
        end
        if result == nil then
          if node.op == "<<" then
            result = bits.shl(left.value, amount)
            local w = left.value.width
            local lost_known, lost_unknown = false, false
            for i = math.max(1, w - amount + 1), w do
              local b = left.value:get(i)
              if b == 1 then
                lost_known = true
              elseif b == bits.U then
                lost_unknown = true
              end
            end
            if lost_known then
              notes[#notes + 1] = string.format("high bits shifted out of the %d-bit width", w)
            elseif lost_unknown then
              notes[#notes + 1] = string.format("unknown high bits may be shifted out of the %d-bit width", w)
            end
            -- Languages with unbounded integers never truncate, so a value that
            -- leaves the window makes the printed decimal wrong: say so.
            if sem.unbounded then
              local grew = lost_known or lost_unknown or (result.signed and result:msb() == 1 and left.value:msb() == 0)
              if grew then
                exact = false
                node.decimal_unreliable = true
                notes[#notes + 1] =
                  string.format("value grows past the %d-bit display window; the decimal is not shown", w)
              end
            end
          else
            result = bits.shr(left.value, amount, arithmetic)
          end
        end
        -- `>>>` in languages that define it as an unsigned shift (JavaScript's
        -- ToUint32) yields an unsigned value, unlike Java's int-typed `>>>`.
        if spec.logical and sem.logical_shift_unsigned and sem.logical_shift_op == node.op and result.signed then
          result = result:resize(result.width, false)
        end
      end
      node.shift_amount = amount
      node.arithmetic = arithmetic
      node.value = result
      node.status = result:knowledge()
      node.notes = notes
      node.exact = exact
      node.left, node.right = left, right
      return node
    end

    node.value = spec.apply(left.value, right.value)
    if spec.arith and ctx.semantics.unbounded and left.value:is_known() and right.value:is_known() then
      -- Unbounded integers (Python) never wrap, so a wrapped decimal would lie.
      local wide = math.min(128, left.value.width * 2)
      local exact_value =
        spec.apply(left.value:resize(wide, left.value.signed), right.value:resize(wide, right.value.signed))
      if bits.to_decimal(exact_value) ~= bits.to_decimal(node.value) then
        node.decimal_unreliable = true
        notes[#notes + 1] =
          string.format("value grows past the %d-bit display window; the decimal is not shown", left.value.width)
      end
    end
    node.status = node.value:knowledge()
    node.notes = notes
    node.exact = left.exact and right.exact
    node.left, node.right = left, right
    return node
  end

  node.value = bits.unknown(width, signed)
  node.status = "unknown"
  node.notes = { "unsupported expression kind: " .. tostring(node.kind) }
  node.exact = false
  return node
end

--- A value whose printed decimal cannot be trusted poisons every value computed
--- from it: the bits shown are the low bits, but the number is not the number.
---@param node table
---@param ctx table
---@return table
eval = function(node, ctx)
  local result = eval_node(node, ctx)
  for _, key in ipairs({ "left", "right", "operand", "inner" }) do
    local child = result[key]
    if type(child) == "table" and child.decimal_unreliable and not result.decimal_unreliable then
      result.decimal_unreliable = true
      result.notes = result.notes or {}
      local explained = false
      for _, note in ipairs(result.notes) do
        if note:find("display window", 1, true) then
          explained = true
        end
      end
      if not explained then
        result.notes[#result.notes + 1] = "an operand grows past the display window; decimals are not shown"
      end
    end
  end
  return result
end

--- Walk the IR and let the language adapter report the type of each literal.
--- The widest literal type wins, and a single unsigned literal makes the whole
--- expression unsigned (mirroring C's usual arithmetic conversions).
---@param node table
---@param semantics table
---@param acc table
local function infer_type(node, semantics, acc)
  if type(node) ~= "table" then
    return
  end
  if node.kind == "literal" and semantics.literal_type then
    local w, s = semantics.literal_type(node)
    if w and w > acc.width then
      acc.width = w
    end
    if s == false then
      acc.signed = false
    end
  end
  for _, key in ipairs({ "left", "right", "operand", "inner" }) do
    if node[key] then
      infer_type(node[key], semantics, acc)
    end
  end
end

--- Evaluate an IR tree.
---@param root table IR root node (mutated in place with results)
---@param opts table|nil { width, signed, semantics, max_nodes }
---@return table|nil evaluated root, string|nil error
function M.evaluate(root, opts)
  opts = opts or {}
  if type(root) ~= "table" then
    return nil, "invalid expression"
  end
  local max_nodes = opts.max_nodes or 64
  local n = M.count_nodes(root)
  if n > max_nodes then
    return nil, string.format("expression too complex (%d nodes > %d)", n, max_nodes)
  end

  local semantics = {}
  for k, v in pairs(M.default_semantics) do
    semantics[k] = v
  end
  for k, v in pairs(opts.semantics or {}) do
    semantics[k] = v
  end

  local width = opts.width
  local force_width = type(width) == "number"
  local signed = opts.signed
  if signed == nil then
    signed = semantics.default_signed
  end

  if not force_width then
    local acc = { width = semantics.default_width, signed = signed }
    infer_type(root, semantics, acc)
    width = acc.width
    if opts.signed == nil then
      signed = acc.signed
    end
  end

  local ctx = {
    width = width,
    signed = signed,
    semantics = semantics,
    force_width = force_width,
  }

  local ok, res = pcall(eval, root, ctx)
  if not ok then
    return nil, tostring(res)
  end
  res.width = width
  res.signed = signed
  return res
end

--- Per-bit "contribution" mask for a binary operation. Used by the renderer to
--- highlight the bit positions that actually drive the result.
---@param op string
---@param left bitwise.Bits
---@param right bitwise.Bits
---@return boolean[] little-endian, indexed by bit position
function M.contribution_mask(op, left, right)
  local mask = {}
  local width = math.max(left.width, right.width)
  for i = 1, width do
    local a, b = left:get(i), right:get(i)
    local active = false
    if op == "&" then
      active = a == 1 and b == 1
    elseif op == "|" then
      active = a == 1 or b == 1
    elseif op == "^" then
      active = (a == 1 or b == 1) and not (a == 1 and b == 1) and a ~= bits.U and b ~= bits.U
    end
    mask[i] = active
  end
  return mask
end

return M
