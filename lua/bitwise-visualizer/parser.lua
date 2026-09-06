--- Tree-sitter discovery and IR extraction.
---
--- This is the only module that talks to Tree-sitter. It converts a syntax node
--- into the language independent IR consumed by `evaluator`.

local languages = require("bitwise-visualizer.languages")
local resolver = require("bitwise-visualizer.resolver")
local evaluator = require("bitwise-visualizer.evaluator")

local M = {}

---@param node TSNode
---@param bufnr integer
---@return string
local function text_of(node, bufnr)
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or type(text) ~= "string" then
    return ""
  end
  return text
end

---@param node TSNode
---@return table range { srow, scol, erow, ecol }
local function range_of(node)
  local srow, scol, erow, ecol = node:range()
  return { srow, scol, erow, ecol }
end

--- The unnamed child of `node` that carries its operator token.
---@param node TSNode
---@param bufnr integer
---@return string|nil token, TSNode|nil child
local function operator_token(node, bufnr)
  -- Prefer the grammar's own field when it exposes one.
  local field = node:field("operator")
  if field and field[1] then
    return text_of(field[1], bufnr), field[1]
  end
  for child in node:iter_children() do
    if not child:named() then
      local t = child:type()
      if t ~= "(" and t ~= ")" then
        return t, child
      end
    end
  end
  return nil, nil
end

---@param node TSNode
---@return TSNode[]
local function named_children(node)
  local out = {}
  for child in node:iter_children() do
    if child:named() and child:type() ~= "comment" then
      out[#out + 1] = child
    end
  end
  return out
end

--- The role a node plays, according to the adapter. Name-based adapters use
--- their node type sets; the generic adapter classifies by shape instead.
---@param adapter bitwise.Adapter
---@param node TSNode
---@param bufnr integer
---@return string|nil kind "binary" | "unary" | "paren" | "literal" | "identifier"
local function kind_of(adapter, node, bufnr)
  if adapter.classify then
    return adapter.classify(node, bufnr)
  end
  local t = node:type()
  if adapter.nodes.binary[t] then
    return "binary"
  elseif adapter.nodes.unary[t] then
    return "unary"
  elseif adapter.nodes.paren[t] then
    return "paren"
  elseif adapter.nodes.literal[t] then
    return "literal"
  end
  local identifiers = adapter.identifier_nodes or { identifier = true }
  if identifiers[t] then
    return "identifier"
  end
  return nil
end

---@param adapter bitwise.Adapter
---@param node TSNode
---@param bufnr integer
---@return boolean
local function is_expression_node(adapter, node, bufnr)
  local kind = kind_of(adapter, node, bufnr)
  return kind == "binary" or kind == "unary" or kind == "paren" or kind == "literal"
end

--- Re-point a resolved subtree at the identifier that stands for it, so that
--- cursor logic never focuses an operator living somewhere else in the file.
---@param ir table
---@param range table
---@param text string
---@return table
local function localize(ir, range, text)
  if type(ir) ~= "table" then
    return ir
  end
  ir.range = range
  ir.op_range = nil
  ir.text = text
  for _, key in ipairs({ "left", "right", "operand", "inner" }) do
    if ir[key] then
      localize(ir[key], range, text)
    end
  end
  return ir
end

--- Build the IR for `node`. Anything the adapter cannot describe becomes an
--- explicit `unknown` operand rather than a failure, which is what makes
--- partially known expressions work.
---@param node TSNode
---@param adapter bitwise.Adapter
---@param bufnr integer
---@param opts table { operators: table<string, boolean> }
---@return table ir
local build_ir
function build_ir(node, adapter, bufnr, opts)
  local kind = kind_of(adapter, node, bufnr)
  local text = text_of(node, bufnr)
  local range = range_of(node)

  if kind == "paren" then
    local children = named_children(node)
    if #children == 1 then
      local inner = build_ir(children[1], adapter, bufnr, opts)
      return { kind = "paren", text = text, range = range, inner = inner }
    end
    return { kind = "unknown", text = text, range = range }
  end

  if kind == "binary" then
    local token, op_node = operator_token(node, bufnr)
    local op = token and (adapter.operator_aliases and adapter.operator_aliases[token] or token)
    if token and adapter.binary_operators[token] and opts.operators[op] ~= false then
      local children = named_children(node)
      if #children == 2 then
        return {
          kind = "binary",
          op = op,
          op_text = token,
          text = text,
          range = range,
          op_range = op_node and range_of(op_node) or nil,
          left = build_ir(children[1], adapter, bufnr, opts),
          right = build_ir(children[2], adapter, bufnr, opts),
        }
      end
    end
    return { kind = "unknown", text = text, range = range }
  end

  if kind == "unary" then
    local token, op_node = operator_token(node, bufnr)
    local op = token and adapter.unary_operators[token]
    if op and opts.operators[op] ~= false then
      local children = named_children(node)
      if #children == 1 then
        return {
          kind = "unary",
          op = op,
          op_text = token,
          text = text,
          range = range,
          op_range = op_node and range_of(op_node) or nil,
          operand = build_ir(children[1], adapter, bufnr, opts),
        }
      end
    end
    return { kind = "unknown", text = text, range = range }
  end

  if kind == "literal" then
    local lit = adapter.parse_literal(text)
    if lit then
      return {
        kind = "literal",
        text = text,
        range = range,
        base = lit.base,
        digits = lit.digits,
        suffix = lit.suffix,
        negative = lit.negative,
      }
    end
  end

  if opts.resolve and kind == "identifier" and (opts.depth or 0) < 4 then
    opts.seen = opts.seen or {}
    if not opts.seen[text] then
      local value = resolver.resolve(node, adapter, bufnr)
      if value then
        opts.seen[text] = true
        local sub
        if value:type() == "preproc_arg" then
          local lit = adapter.parse_literal((text_of(value, bufnr):gsub("^%s+", ""):gsub("%s+$", "")))
          sub = lit
              and {
                kind = "literal",
                text = text,
                base = lit.base,
                digits = lit.digits,
                suffix = lit.suffix,
                negative = lit.negative,
              }
            or nil
        else
          local nested = vim.tbl_extend("force", opts, { depth = (opts.depth or 0) + 1 })
          sub = build_ir(value, adapter, bufnr, nested)
          if sub.kind == "unknown" then
            sub = nil
          end
        end
        opts.seen[text] = nil
        if sub then
          sub.resolved = true
          return localize(sub, range, text)
        end
      end
    end
  end

  return { kind = "unknown", text = text, range = range }
end

--- Does this IR tree contain at least one bitwise operation?
---@param ir table
---@return boolean
function M.has_operation(ir)
  if type(ir) ~= "table" then
    return false
  end
  -- Folded arithmetic (`y + 5`, `-x`) is not itself worth visualising.
  if (ir.kind == "binary" or ir.kind == "unary") and evaluator.is_bitwise(ir.op) then
    return true
  end
  for _, key in ipairs({ "left", "right", "operand", "inner" }) do
    if ir[key] and M.has_operation(ir[key]) then
      return true
    end
  end
  return false
end

---@param range table { srow, scol, erow, ecol }
---@param row integer 0-indexed
---@param col integer 0-indexed
---@return boolean
function M.range_contains(range, row, col)
  local srow, scol, erow, ecol = range[1], range[2], range[3], range[4]
  if row < srow or row > erow then
    return false
  end
  if row == srow and col < scol then
    return false
  end
  if row == erow and col > ecol then
    return false
  end
  return true
end

--- The Tree-sitter language that actually applies at a position (honours
--- injections such as C inside Markdown). Ensures the tree is parsed.
---@param bufnr integer
---@param row integer
---@param col integer
---@return string|nil
function M.language_at(bufnr, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not ok or not parser then
    return nil
  end
  -- `get_node` only looks at already-parsed trees, so make sure one exists.
  pcall(parser.parse, parser, false)
  local ok_lang, tree = pcall(function()
    return parser:language_for_range({ row, col, row, col })
  end)
  if ok_lang and tree then
    return tree:lang()
  end
  return parser:lang()
end

--- Find the bitwise expression relevant to a cursor position.
---@param bufnr integer
---@param row integer 0-indexed
---@param col integer 0-indexed
---@param opts table { trigger, subexpression, operators }
---@return table|nil result { ir, node, adapter, lang, range, on_operator }
---@return string|nil reason when nothing was found
function M.find_at(bufnr, row, col, opts)
  opts = opts or {}
  opts.operators = opts.operators or {}

  local lang = M.language_at(bufnr, row, col)
  local adapter = languages.get(lang, opts.generic ~= false)
  if not adapter then
    return nil, "unsupported language"
  end

  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col }, lang = lang })
  if not ok or not node then
    return nil, "no syntax node at cursor"
  end

  -- Climb to the largest contiguous expression made only of nodes the adapter
  -- understands. This keeps `(10 & 12) ^ 3` together.
  local candidates = {}
  local cur = node
  while cur do
    if is_expression_node(adapter, cur, bufnr) then
      candidates[#candidates + 1] = cur
    elseif #candidates > 0 then
      break
    end
    cur = cur:parent()
  end
  if #candidates == 0 then
    return nil, "cursor is not inside an expression"
  end

  -- Prefer the largest expression, but a non-bitwise parent (`1 + (10 & 12)`)
  -- must not hide the operation nested inside it, so fall back inwards.
  local outermost, ir
  for i = #candidates, 1, -1 do
    local candidate = candidates[i]
    if not candidate:has_error() then
      local built = build_ir(candidate, adapter, bufnr, opts)
      if M.has_operation(built) then
        outermost, ir = candidate, built
        break
      end
    end
  end
  if not ir then
    if candidates[#candidates]:has_error() then
      return nil, "expression contains syntax errors"
    end
    return nil, "no bitwise operation in expression"
  end

  -- Which operator, if any, is directly under the cursor?
  local focus = M.focus_subexpression(ir, row, col)
  local on_operator = focus ~= nil

  if opts.trigger == "operator" and not on_operator then
    return nil, "cursor is not on a bitwise operator"
  end

  local selected = ir
  if opts.subexpression and focus then
    selected = focus
  end
  if not M.has_operation(selected) then
    selected = ir
  end
  -- `(10 & 12)` is an operation wrapped in parentheses; show the operation.
  while selected.kind == "paren" and selected.inner do
    selected = selected.inner
  end
  -- `1 + (10 & 12)` is rooted at arithmetic: visualise the bitwise part.
  if not evaluator.is_bitwise(selected.op) then
    selected = M.outermost_operation(selected) or selected
  end

  return {
    ir = selected,
    root_ir = ir,
    node = outermost,
    adapter = adapter,
    lang = lang,
    range = range_of(outermost),
    on_operator = on_operator,
  }
end

--- The outermost bitwise operation in an IR tree, if any.
---@param ir table
---@return table|nil
function M.outermost_operation(ir)
  if type(ir) ~= "table" then
    return nil
  end
  if (ir.kind == "binary" or ir.kind == "unary") and evaluator.is_bitwise(ir.op) then
    return ir
  end
  for _, key in ipairs({ "inner", "left", "right", "operand" }) do
    if ir[key] then
      local found = M.outermost_operation(ir[key])
      if found then
        return found
      end
    end
  end
  return nil
end

--- The innermost operation whose operator token sits under the cursor.
---@param ir table
---@param row integer
---@param col integer
---@return table|nil
function M.focus_subexpression(ir, row, col)
  if type(ir) ~= "table" then
    return nil
  end
  for _, key in ipairs({ "left", "right", "operand", "inner" }) do
    if ir[key] then
      local found = M.focus_subexpression(ir[key], row, col)
      if found then
        return found
      end
    end
  end
  if (ir.kind == "binary" or ir.kind == "unary") and ir.op_range then
    -- Treat the position just after the operator as "on" it, matching how a
    -- cursor sitting at the end of `&` reads to a human.
    local r = { ir.op_range[1], ir.op_range[2], ir.op_range[3], ir.op_range[4] }
    if M.range_contains(r, row, col) then
      return ir
    end
  end
  return nil
end

return M
