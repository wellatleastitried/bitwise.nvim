--- Conservative constant resolution for identifiers.
---
--- `int y = 10; ... y | z` should visualize the bits of `y`, but only when that
--- can be proven from the syntax tree alone. The rule is deliberately strict:
--- an identifier resolves only when the nearest enclosing scope that mentions it
--- contains exactly one write, that write is an initialiser with a value, it
--- happens before the use, and the name is never mutated or address-taken.
--- Anything less certain stays unknown -- a wrong value is worse than no value.

local M = {}

--- Scope-introducing node types, shared across the supported grammars.
local SCOPES = {
  compound_statement = true, -- C/C++
  block = true, -- Rust/Go/Lua/Java
  statement_block = true, -- JavaScript/TypeScript
  function_definition = true,
  function_declaration = true,
  function_item = true,
  function_definition_statement = true,
  method_declaration = true,
  method_definition = true,
  class_body = true,
  constructor_declaration = true,
  translation_unit = true,
  source_file = true,
  program = true,
  module = true,
  chunk = true,
}

--- Node types that bound a name's visibility without being full scopes in every
--- grammar: the three-clause `for`, `if`/`while` init-statements and friends.
--- A write inside one of these is only trusted when the use is inside it too.
local BOUNDARIES = {
  for_statement = true,
  for_in_statement = true,
  for_of_statement = true,
  enhanced_for_statement = true,
  for_range_loop = true,
  for_expression = true,
  while_statement = true,
  if_statement = true,
  switch_statement = true,
  catch_clause = true,
  with_statement = true,
  numeric_for_statement = true,
  generic_for_statement = true,
  -- Ruby statement modifiers: `y = 20 if c` is just as conditional as a block.
  if_modifier = true,
  unless_modifier = true,
  while_modifier = true,
  until_modifier = true,
  rescue_modifier = true,
  -- Shell: a subshell assignment never escapes, and a `&&`/`||` list is
  -- conditional.
  subshell = true,
  list = true,
  case_item = true,
  -- Perl / PHP / others spell the same ideas with these.
  conditional_statement = true,
  unless_statement = true,
  elsif_clause = true,
  else_clause = true,
  ternary_expression = true,
  conditional_expression = true,
  -- An assignment nested in a binary expression is short-circuited or
  -- sequenced: `c and y = 20`. Modelled languages never reach this.
  binary = true,
  binary_expression = true,
}

--- Loop constructs whose target is rebound on every iteration. The value is
--- never knowable, and (in Python and JavaScript) the binding outlives the
--- loop, so any occurrence in this field poisons resolution.
--- The field names differ per grammar, and one node type (`for_statement`) is
--- spelled differently by Python and shell, so each entry is a list.
local LOOP_TARGETS = {
  for_statement = { "left", "variable" }, -- Python / shell
  for_in_statement = { "left" }, -- JavaScript `for...in`
  for_of_statement = { "left" }, -- JavaScript `for...of`
  enhanced_for_statement = { "name" }, -- Java
  for_range_loop = { "declarator" }, -- C++
}

--- Node types that make any conclusion about the value unsafe.
local POISON = {
  pointer_expression = true, -- C `&y` / `*y`
  reference_expression = true, -- Rust `&y`
  unary_expression = false, -- handled through the operator token instead
  update_expression = true, -- `y++`
  augmented_assignment = true, -- Python `y |= 1`
  augmented_assignment_expression = true, -- JavaScript/TypeScript `y |= 1`
  named_expression = true, -- Python `(y := 3)` rebinds in the enclosing scope
  postinc_expression = true, -- Perl `$y++`
  preinc_expression = true,
  postdec_expression = true,
  predec_expression = true,
  postfix_expression = true, -- shell `((y++))`
  prefix_expression = true,
  unset_command = true, -- shell `unset y`
  delete_statement = true, -- Python `del y`
  -- A bare word argument to a command may be a name the command writes
  -- (`read y`, `let y=20`, `eval`). We cannot tell, so we refuse.
  command = true,
  compound_assignment_expr = true, -- Rust `y |= 1`
  assignment = false,
}

--- Node types that bind a name to a value, with their (name, value) fields.
--- Restricting the lookup to these types matters: a generic "left/right" field
--- probe would mistake the `y` in `y | z` for an assignment target.
local BINDINGS = {
  init_declarator = { "declarator", "value" }, -- C/C++
  assignment_expression = { "left", "right" }, -- C/C++/Java/JavaScript/Rust
  assignment = { "left", "right" }, -- Python
  assignment_statement = { "left", "right" }, -- Lua/Go
  variable_declarator = { "name", "value" }, -- Java/JavaScript
  let_declaration = { "pattern", "value" }, -- Rust
  const_item = { "name", "value" }, -- Rust
  static_item = { "name", "value" }, -- Rust
  short_var_declaration = { "left", "right" }, -- Go
  var_spec = { "name", "value" }, -- Go
  const_spec = { "name", "value" }, -- Go
  variable_assignment = { "name", "value" }, -- shell
}

--- Operators that end in `=` without assigning anything.
local COMPARISONS = {
  ["=="] = true,
  ["==="] = true,
  ["!="] = true,
  ["!=="] = true,
  ["<="] = true,
  [">="] = true,
  ["~="] = true, -- Lua "not equal"
  ["<>"] = true,
  ["=~"] = true,
  ["<=>"] = true,
}

--- List wrappers around a single target/value (`local y = 10` in Lua, `y := 1`
--- in Go). More than one child means a multiple assignment: give up.
local UNWRAP = {
  variable_list = true,
  expression_list = true,
  identifier_list = true,
}

local MAX_NODES = 4000

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

---@param a TSNode
---@param b TSNode
---@return boolean
local function same(a, b)
  return a:id() == b:id()
end

--- Is `outer` an ancestor of (or equal to) `inner`?
---@param outer TSNode
---@param inner TSNode
---@return boolean
local function contains(outer, inner)
  local cur = inner
  while cur do
    if same(cur, outer) then
      return true
    end
    cur = cur:parent()
  end
  return false
end

--- Read a named field, tolerating grammars (Lua) that put the field on a list
--- wrapper instead of the statement itself.
---@param node TSNode
---@param name string
---@return TSNode|nil field, boolean multiple
local function field_of(node, name)
  local direct = node:field(name)
  if #direct > 1 then
    return nil, true
  end
  if direct[1] then
    return direct[1], false
  end
  for child in node:iter_children() do
    if child:named() then
      local nested = child:field(name)
      if #nested > 1 then
        return nil, true
      end
      if nested[1] then
        return nested[1], false
      end
    end
  end
  return nil, false
end

--- Unwrap `variable_list` / `expression_list` style single-element wrappers.
---@param node TSNode
---@return TSNode|nil
local function unwrap(node)
  if not UNWRAP[node:type()] then
    return node
  end
  if node:named_child_count() ~= 1 then
    return nil -- `a, b = 1, 2`
  end
  return node:named_child(0)
end

--- Classify one occurrence of the name.
---@param ident TSNode
---@param bufnr integer
---@param adapter bitwise.Adapter
---@return string kind "read" | "write" | "poison"
---@return TSNode|nil value the written expression, for writes
local function classify(ident, bufnr, adapter)
  local parent = ident:parent()
  if not parent then
    return "read"
  end
  if POISON[parent:type()] then
    return "poison"
  end

  local function binding_for(node)
    return (adapter.bindings and adapter.bindings[node:type()]) or BINDINGS[node:type()]
  end

  -- The bound name can sit below the binding node: `local y = 10` wraps it in a
  -- `variable_list`, Perl's `my $y` wraps it in `variable_declaration > scalar`.
  -- Climb through single-child wrappers looking for a node we understand.
  local hops = 0
  while parent and hops < 4 do
    if UNWRAP[parent:type()] and parent:parent() then
      parent = parent:parent()
    end
    if binding_for(parent) or parent:named_child_count() ~= 1 or not parent:parent() then
      break
    end
    parent = parent:parent()
    if POISON[parent:type()] then
      return "poison"
    end
    hops = hops + 1
  end
  -- C spells address-of as a `pointer_expression`, but some grammars fold it
  -- into a generic unary node, so check the operator token as well.
  local op = parent:field("operator")[1]
  local op_text = op and text_of(op, bufnr) or nil
  if op_text == "&" and parent:named_child_count() == 1 then
    return "poison"
  end

  local binding = binding_for(parent)
  if not binding then
    -- An unknown parent that carries a compound assignment (`y >>= 2` in a
    -- grammar we do not model) is a write we cannot read: refuse the name.
    -- Comparisons end in `=` too and must not be mistaken for one.
    if op_text and op_text:sub(-1) == "=" and not COMPARISONS[op_text] then
      return "poison"
    end
    return "read"
  end
  local lhs, multi = field_of(parent, binding[1])
  if multi then
    return "poison"
  end
  if not lhs or not contains(lhs, ident) then
    return "read"
  end
  lhs = unwrap(lhs)
  if not lhs then
    return "poison"
  end
  if op_text and op_text ~= "=" then
    return "poison" -- `y |= 1`, `y += 1`, ...
  end
  -- Some grammars wrap the bound name (Perl `my $y` -> scalar -> varname). A
  -- single-child chain is pure decoration; anything wider is a real structure
  -- such as `a[i] = ...` or a destructuring pattern, which we refuse.
  while lhs and not same(lhs, ident) do
    if lhs:named_child_count() ~= 1 then
      return "poison"
    end
    lhs = lhs:named_child(0)
  end
  if not lhs then
    return "poison"
  end
  local value, many = field_of(parent, binding[2])
  if many or not value then
    return "poison"
  end
  value = unwrap(value)
  if not value then
    return "poison"
  end
  return "write", value, parent
end

--- Does the range of `outer` cover the first character of `inner`?
--- Tree-sitter end columns are exclusive, hence the `>=` on the end boundary.
---@param outer TSNode
---@param inner TSNode
---@return boolean
local function spans_start(outer, inner)
  local srow, scol, erow, ecol = outer:range()
  local row, col = inner:range()
  if row < srow or (row == srow and col < scol) then
    return false
  end
  if row > erow or (row == erow and col >= ecol) then
    return false
  end
  return true
end

--- The nearest node that limits where a write is visible.
---@param node TSNode
---@param scope TSNode
---@return TSNode
local function nearest_boundary(node, scope)
  local cur = node:parent()
  while cur do
    if SCOPES[cur:type()] or BOUNDARIES[cur:type()] or same(cur, scope) then
      return cur
    end
    cur = cur:parent()
  end
  return scope
end

--- Is this occurrence the target of a loop that rebinds it every iteration?
---@param node TSNode
---@return boolean
local function is_loop_target(node)
  local cur, parent = node, node:parent()
  for _ = 1, 3 do
    if not parent then
      return false
    end
    local fields = LOOP_TARGETS[parent:type()]
    if fields then
      for _, field in ipairs(fields) do
        local target = parent:field(field)[1]
        if target and (same(target, cur) or spans_start(target, node)) then
          return true
        end
      end
      return false
    end
    cur, parent = parent, parent:parent()
  end
  return false
end

---@param a TSNode
---@param b TSNode
---@return boolean true when `a` starts before `b`
local function precedes(a, b)
  local arow, acol = a:range()
  local brow, bcol = b:range()
  return arow < brow or (arow == brow and acol < bcol)
end

--- Is this occurrence of the name a binding site that carries no value we can
--- read -- a function parameter, a lambda argument, a destructuring pattern?
--- Such a declaration shadows anything in an enclosing scope, so resolution
--- must stop rather than reach past it.
---@param node TSNode
---@param scope TSNode
---@return boolean
local function is_opaque_declaration(node, scope)
  local parent = node:parent()
  while parent and not same(parent, scope) do
    local t = parent:type()
    if t:find("param", 1, true) or t:find("pattern", 1, true) then
      return true
    end
    parent = parent:parent()
  end
  return false
end

--- Is this node inside conditional compilation?
---@param node TSNode
---@return boolean
local function under_conditional(node)
  local parent = node:parent()
  while parent do
    if parent:type():find("^preproc_if") then
      return true
    end
    parent = parent:parent()
  end
  return false
end

--- Structural visibility check for grammars we do not model.
---
--- Without knowing which node types introduce scopes, the only safe assumption
--- is that a write is visible when its binding sits at the same nesting level
--- as the use: the binding node reaches their common ancestor within a couple
--- of hops, allowing for a statement wrapper. A write buried inside a method
--- body, `if` branch or loop is further down and is refused.
---@param binding TSNode the node that performs the assignment
---@param ident TSNode
---@return boolean
local function shares_nesting_level(binding, ident)
  local ancestors = {}
  local cur = ident:parent()
  while cur do
    ancestors[cur:id()] = true
    cur = cur:parent()
  end
  cur = binding
  for _ = 0, 2 do
    if not cur then
      return false
    end
    if ancestors[cur:id()] then
      return true
    end
    cur = cur:parent()
  end
  return false
end

--- Look for writes to `name` inside `scope`.
---@param scope TSNode
---@param name string
---@param ident TSNode the use being resolved
---@param adapter bitwise.Adapter
---@param bufnr integer
---@return TSNode|nil value, boolean poisoned
local function scan(scope, name, ident, adapter, bufnr)
  local identifiers = adapter.identifier_nodes or { identifier = true }
  local budget = MAX_NODES
  local found, count = nil, 0
  local stack = { scope }
  while #stack > 0 do
    local node = table.remove(stack)
    budget = budget - 1
    if budget <= 0 then
      return nil, true
    end
    local t = node:type()
    if identifiers[t] and text_of(node, bufnr) == name and not same(node, ident) then
      if is_opaque_declaration(node, scope) or is_loop_target(node) then
        return nil, true -- a parameter, pattern or loop target is never a constant
      end
      local kind, value, binding = classify(node, bufnr, adapter)
      if kind == "poison" then
        return nil, true
      elseif kind == "write" then
        count = count + 1
        if count > 1 then
          return nil, true
        end
        -- Only a write that precedes the use and is visible from it tells us
        -- anything. A write in a block the use is not inside may be shadowing
        -- the real binding, or may be a conditional reassignment of it.
        if not precedes(node, ident) or not spans_start(nearest_boundary(node, scope), ident) then
          return nil, true
        end
        -- `SCOPES`/`BOUNDARIES` are node-type names, so they say nothing about a
        -- grammar with no adapter. Fall back to a purely structural rule there.
        if adapter.generic and (not binding or not shares_nesting_level(binding, ident)) then
          return nil, true
        end
        found = value
      end
    elseif t == "preproc_def" then
      local dname = node:field("name")[1]
      if dname and text_of(dname, bufnr) == name then
        count = count + 1
        -- A macro defined inside #if/#ifdef may not be the one in effect.
        if count > 1 or not precedes(node, ident) or under_conditional(node) then
          return nil, true
        end
        found = node:field("value")[1]
        if not found then
          return nil, true
        end
      end
    elseif node:named_child_count() == 0 then
      -- Some grammars keep a whole assignment in one token (`let y=20` in
      -- shell is a single `word`), so the name is never a node of its own.
      local txt = text_of(node, bufnr)
      local parent = node:parent()
      if parent and POISON[parent:type()] and txt:sub(1, #name + 1) == name .. "=" then
        return nil, true
      end
      -- Shell arithmetic contexts fold `y++`/`++y`/`y--`/`--y` into a single
      -- token too (`((y++))` is one `word`, not its own increment node), and
      -- this pattern is never anything but a mutation.
      if txt == name .. "++" or txt == "++" .. name or txt == name .. "--" or txt == "--" .. name then
        return nil, true
      end
    elseif t == "preproc_call" then
      -- `#undef NAME` is a preproc_call in the C grammar, not its own type.
      local directive = node:field("directive")[1]
      local argument = node:field("argument")[1]
      if
        directive
        and argument
        and vim.trim(text_of(directive, bufnr)) == "#undef"
        and vim.trim(text_of(argument, bufnr)) == name
      then
        return nil, true
      end
    end
    for child in node:iter_children() do
      if child:named() then
        stack[#stack + 1] = child
      end
    end
  end
  return found, false
end

--- Resolve an identifier to the syntax node holding its constant value.
---@param ident TSNode
---@param adapter bitwise.Adapter
---@param bufnr integer
---@return TSNode|nil value
---@return string|nil name
function M.resolve(ident, adapter, bufnr)
  local name = text_of(ident, bufnr)
  if name == "" then
    return nil
  end

  local scopes = {}
  local node = ident:parent()
  while node do
    if SCOPES[node:type()] or node:parent() == nil then
      scopes[#scopes + 1] = node
    end
    node = node:parent()
  end

  for _, scope in ipairs(scopes) do
    local value, poisoned = scan(scope, name, ident, adapter, bufnr)
    if poisoned then
      return nil
    end
    if value then
      return value, name
    end
  end
  return nil
end

return M
