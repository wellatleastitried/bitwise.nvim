--- Turns an evaluated IR node into aligned, highlightable text rows.
---
--- The formatter emits *highlight keys* (`"one"`, `"zero"`, `"active"`, ...)
--- rather than Neovim highlight group names, which keeps it free of Neovim
--- APIs and unit testable.
---
--- Output shape:
---   {
---     lines  = { { { text = "1010", hl = "one" }, ... }, ... },
---     width  = 8,          -- bits actually displayed
---     eval_width = 32,     -- bits the value was computed with
---     signed = true,
---     status = "known" | "partial" | "unknown",
---     notes  = { "..." },
---   }

local bits = require("bitwise-visualizer.bits")
local evaluator = require("bitwise-visualizer.evaluator")

local M = {}

M.SEPARATOR_CHAR = "─"
local MAX_LABEL = 48

---@param s string
---@return string
local function truncate(s)
  s = s:gsub("%s+", " ")
  if #s <= MAX_LABEL then
    return s
  end
  return s:sub(1, MAX_LABEL - 1) .. "…"
end

---@param chunks table[]
---@return table[]
local function coalesce(chunks)
  local out = {}
  for _, c in ipairs(chunks) do
    if c.text ~= "" then
      local last = out[#out]
      if last and last.hl == c.hl then
        last.text = last.text .. c.text
      else
        out[#out + 1] = { text = c.text, hl = c.hl }
      end
    end
  end
  return out
end

---@param n integer
---@return table chunk
local function pad(n)
  return { text = string.rep(" ", math.max(n, 0)), hl = nil }
end

--- Render a value's bits into chunks, grouped and highlighted.
---@param value bitwise.Bits
---@param width integer display width
---@param group integer group size, 0 disables
---@param mask boolean[]|nil little-endian contribution mask
---@return table[] chunks, integer printed_width
local function bit_chunks(value, width, group, mask)
  local chunks = {}
  local count = 0
  for i = width, 1, -1 do
    local b = value:get(i)
    local text = (b == bits.U) and "?" or tostring(b)
    local hl
    if mask and mask[i] then
      hl = "active"
    elseif b == bits.U then
      hl = "unknown"
    elseif b == 1 then
      hl = "one"
    else
      hl = "zero"
    end
    chunks[#chunks + 1] = { text = text, hl = hl }
    count = count + 1
    if group > 0 and i > 1 and ((i - 1) % group == 0) then
      chunks[#chunks + 1] = { text = " ", hl = nil }
      count = count + 1
    end
  end
  return chunks, count
end

---@param width integer
---@param group integer
---@return integer
local function printed_width(width, group)
  if group > 0 then
    return width + math.ceil(width / group) - 1
  end
  return width
end

--- Choose the display width.
---@param values bitwise.Bits[]
---@param cfg table
---@return integer
function M.choose_width(values, cfg)
  local eval_width = values[1] and values[1].width or 32
  if type(cfg.width) == "number" then
    return math.min(cfg.width, eval_width)
  end
  local need = 1
  for _, v in ipairs(values) do
    need = math.max(need, v:visual_width())
  end
  local candidates = cfg.display_widths or { 8, 16, 32, 64 }
  local best = eval_width
  for _, w in ipairs(candidates) do
    if w >= need and w <= eval_width then
      best = w
      break
    end
  end
  return best
end

--- Describe the value column for a row.
---@param value bitwise.Bits
---@param text string
---@param cfg table
---@param is_result boolean|nil
---@return table[] chunks
local function annotation_chunks(value, text, cfg, is_result)
  local out = {}
  local dec = bits.to_decimal(value)
  local label = cfg.show_labels and truncate(text or "") or nil
  if is_result and dec then
    -- The expression itself is on the very next line; repeating it adds noise.
    label = nil
  end
  if label and dec and label == dec then
    label = nil -- the source text already is the decimal value
  end
  if label and not dec then
    out[#out + 1] = { text = label, hl = "label" }
    return out
  end
  if label then
    out[#out + 1] = { text = label, hl = "label" }
    out[#out + 1] = pad(2)
  end
  if dec and cfg.show_decimal then
    out[#out + 1] = { text = "(" .. dec .. ")", hl = "value" }
    if cfg.show_hex then
      out[#out + 1] = pad(1)
      out[#out + 1] = { text = bits.to_hex(value), hl = "value" }
    end
  elseif dec and cfg.show_hex then
    out[#out + 1] = { text = bits.to_hex(value), hl = "value" }
  end
  return out
end

--- Build one operand/result row.
---@param opts table { prefix, prefix_width, value, text, width, cfg, mask, result }
---@return table[] chunks
local function value_row(opts)
  local cfg = opts.cfg
  local chunks = {}
  local prefix = opts.prefix or ""
  chunks[#chunks + 1] = { text = prefix, hl = prefix ~= "" and "operator" or nil }
  chunks[#chunks + 1] = pad(opts.prefix_width - #prefix)
  local bc = bit_chunks(opts.value, opts.width, cfg.group_bits or 0, opts.mask)
  for _, c in ipairs(bc) do
    chunks[#chunks + 1] = c
  end
  chunks[#chunks + 1] = pad(2)
  for _, c in ipairs(annotation_chunks(opts.value, opts.text, cfg, opts.result)) do
    chunks[#chunks + 1] = c
  end
  return coalesce(chunks)
end

---@param prefix_width integer
---@param width integer
---@param group integer
---@return table[]
local function separator_row(prefix_width, width, group)
  return {
    { text = string.rep(" ", prefix_width), hl = nil },
    { text = string.rep(M.SEPARATOR_CHAR, printed_width(width, group)), hl = "separator" },
  }
end

--- Format an evaluated IR node.
---@param node table evaluated IR node (must be `binary` or `unary`)
---@param cfg table configuration table
---@return table|nil rendered, string|nil reason
function M.format(node, cfg)
  cfg = cfg or {}
  if type(node) ~= "table" then
    return nil, "expression was not evaluated"
  end
  while node.kind == "paren" and type(node.inner) == "table" do
    node = node.inner
  end
  if node.kind ~= "binary" and node.kind ~= "unary" then
    return nil, "not an operation"
  end
  if not node.value then
    return nil, "expression was not evaluated"
  end

  local status = node.value:knowledge()
  if status ~= "known" and cfg.show_unknown == false then
    return nil, "unknown values are disabled"
  end

  local operands = node.kind == "binary" and { node.left, node.right } or { node.operand }

  if status == "unknown" and cfg.show_fully_unknown == false then
    local any_known = false
    for _, o in ipairs(operands) do
      if o.value and o.value:knowledge() ~= "unknown" then
        any_known = true
      end
    end
    if not any_known then
      return nil, "fully unknown expression"
    end
  end

  --- Rows whose value grew past the display window must not print a decimal.
  local no_decimal_cfg
  local function row_cfg(ir)
    if not (type(ir) == "table" and ir.decimal_unreliable) then
      return cfg
    end
    if not no_decimal_cfg then
      no_decimal_cfg = {}
      for k, v in pairs(cfg) do
        no_decimal_cfg[k] = v
      end
      no_decimal_cfg.show_decimal = false
    end
    return no_decimal_cfg
  end

  local is_shift = evaluator.is_shift(node.op)
  local values = { node.value }
  for _, o in ipairs(operands) do
    if o.value and not (is_shift and o == node.right) then
      values[#values + 1] = o.value
    end
  end

  local eval_width = node.value.width
  local width = M.choose_width(values, cfg)
  local group = cfg.group_bits or 0
  local op_text = node.op_text or node.op
  local prefix_width = #op_text + 1

  local mask
  if node.kind == "binary" and not is_shift then
    mask = evaluator.contribution_mask(node.op, node.left.value, node.right.value)
  end

  local lines = {}

  if node.kind == "unary" then
    lines[#lines + 1] = value_row({
      prefix = op_text,
      prefix_width = prefix_width,
      value = node.operand.value,
      text = node.operand.text,
      width = width,
      cfg = row_cfg(node.operand),
    })
  elseif is_shift then
    lines[#lines + 1] = value_row({
      prefix = "",
      prefix_width = prefix_width,
      value = node.left.value,
      text = node.left.text,
      width = width,
      cfg = row_cfg(node.left),
    })
    local amount = node.shift_amount and tostring(node.shift_amount) or truncate(node.right.text or "?")
    lines[#lines + 1] = coalesce({
      { text = op_text .. " " .. amount, hl = "operator" },
      pad(1),
      {
        text = (node.arithmetic and "(arithmetic)" or (node.op == ">>" and "(logical)" or "")),
        hl = "note",
      },
    })
  else
    lines[#lines + 1] = value_row({
      prefix = "",
      prefix_width = prefix_width,
      value = node.left.value,
      text = node.left.text,
      width = width,
      cfg = row_cfg(node.left),
      mask = mask,
    })
    lines[#lines + 1] = value_row({
      prefix = op_text,
      prefix_width = prefix_width,
      value = node.right.value,
      text = node.right.text,
      width = width,
      cfg = row_cfg(node.right),
      mask = mask,
    })
  end

  lines[#lines + 1] = separator_row(prefix_width, width, group)

  lines[#lines + 1] = value_row({
    prefix = "",
    prefix_width = prefix_width,
    value = node.value,
    text = node.text,
    width = width,
    cfg = row_cfg(node),
    mask = mask,
    result = true,
  })

  local notes = {}
  for _, n in ipairs(node.notes or {}) do
    notes[#notes + 1] = n
  end
  -- Hiding redundant sign/zero extension needs no explanation, but hiding
  -- *unknown* high bits does: say so rather than implying a narrow value.
  if width < eval_width then
    local hides_unknown = false
    for _, v in ipairs(values) do
      for i = width + 1, v.width do
        if v:get(i) == bits.U then
          hides_unknown = true
          break
        end
      end
    end
    if hides_unknown then
      notes[#notes + 1] = string.format(
        "%d-bit %s value, showing the low %d bits",
        eval_width,
        node.value.signed and "signed" or "unsigned",
        width
      )
    end
  end
  if cfg.show_notes ~= false then
    for _, n in ipairs(notes) do
      lines[#lines + 1] = { { text = string.rep(" ", prefix_width) .. n, hl = "note" } }
    end
  end

  return {
    lines = lines,
    width = width,
    eval_width = eval_width,
    signed = node.value.signed,
    status = status,
    notes = notes,
  }
end

--- Compact single-line summary used by the `eol` position.
---@param node table evaluated IR node
---@param cfg table
---@return table|nil chunks
function M.format_inline(node, cfg)
  local rendered = M.format(node, cfg)
  if not rendered then
    return nil
  end
  local value = node.value
  local chunks = { { text = " ", hl = nil } }
  local bc = bit_chunks(value, rendered.width, cfg.group_bits or 0, nil)
  for _, c in ipairs(bc) do
    chunks[#chunks + 1] = c
  end
  local dec = bits.to_decimal(value)
  if dec and cfg.show_decimal ~= false and not node.decimal_unreliable then
    chunks[#chunks + 1] = { text = "  (" .. dec .. ")", hl = "value" }
  end
  return coalesce(chunks), rendered
end

--- Render to plain strings (used by tests and by `:BitwiseVisualizerShow!`).
---@param rendered table
---@return string[]
function M.to_strings(rendered)
  local out = {}
  for _, line in ipairs(rendered.lines) do
    local parts = {}
    for _, chunk in ipairs(line) do
      parts[#parts + 1] = chunk.text
    end
    out[#out + 1] = (table.concat(parts):gsub("%s+$", ""))
  end
  return out
end

return M
