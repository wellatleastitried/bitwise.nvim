--- Structural adapter: analyses *any* Tree-sitter grammar.
---
--- Language-specific adapters recognise node types by name. That is precise but
--- only covers languages someone has written an adapter for. This adapter
--- classifies nodes by their shape instead -- "two named children plus an
--- operator token that reads as a bitwise operator" -- which holds across
--- virtually every infix grammar, from Ada and VHDL to Verilog and Zig.
---
--- It is deliberately cautious: unknown semantics mean a 64-bit signed model,
--- shifts wider than the value degrade to unknown, and a note says the analysis
--- is generic. Languages that are not infix (Forth, APL, Lisp) simply never
--- match, and the plugin stays silent.

local util = require("bitwise-visualizer.languages.util")

--- Operator spellings seen across languages, mapped to the canonical operator.
local BINARY = {
  ["&"] = "&",
  ["|"] = "|",
  ["^"] = "^",
  ["<<"] = "<<",
  [">>"] = ">>",
  [">>>"] = ">>>",
  ["&^"] = "&^",
  -- Only spellings that are unambiguously bitwise. `and`/`or`/`xor`/`not` are
  -- boolean in almost every language this fallback reaches, so guessing there
  -- would print a confidently wrong result.
  ["band"] = "&",
  ["bor"] = "|",
  ["bxor"] = "^",
  ["bitand"] = "&",
  ["bitor"] = "|",
  ["bitxor"] = "^",
  ["shl"] = "<<",
  ["shr"] = ">>",
  ["sll"] = "<<",
  ["srl"] = ">>",
  ["sla"] = "<<",
  ["sra"] = ">>",
  ["lsl"] = "<<",
  ["lsr"] = ">>",
  ["asr"] = ">>",
  ["+"] = "+",
  ["-"] = "-",
  ["*"] = "*",
}

local UNARY = {
  ["~"] = "~",
  ["bnot"] = "~",
  ["-"] = "-",
  ["+"] = "+",
}

--- Type names that denote a plain name reference in some grammar.
local IDENTIFIER_PATTERNS = { "identifier", "^name$", "variable", "^varname$", "^word$", "^symbol$" }

local identifier_nodes = setmetatable({}, {
  __index = function(_, t)
    if type(t) ~= "string" then
      return false
    end
    for _, pattern in ipairs(IDENTIFIER_PATTERNS) do
      if t:find(pattern) then
        return true
      end
    end
    return false
  end,
})

---@param node TSNode
---@param bufnr integer
---@return string|nil kind "binary" | "unary" | "paren" | "literal" | "identifier"
local function classify(node, bufnr)
  local named = util.named_children(node)
  local token = util.operator_token(node, bufnr)
  local key = token and token:lower() or nil

  if #named == 2 and key and BINARY[key] then
    return "binary"
  end
  if #named == 1 then
    if key and UNARY[key] then
      return "unary"
    end
    if util.is_bracketed(node) then
      return "paren"
    end
    -- Transparent wrappers (Perl's `$y` around `y`, grouping nodes) carry no
    -- meaning of their own: their text is the child's text plus decoration.
    local outer = util.node_text(node, bufnr)
    local inner = util.node_text(named[1], bufnr)
    if outer:gsub("^[%s%(%[%$@%%]*", ""):gsub("[%s%)%]]*$", "") == inner then
      return "paren"
    end
  end
  if #named == 0 then
    local text = util.node_text(node, bufnr)
    if text == "" then
      return nil
    end
    if util.scan_any_integer(text) then
      return "literal"
    end
    -- Allow the sigils used by Perl, Ruby, PHP and shell variable names.
    if identifier_nodes[node:type()] and text:match("^[%$@%%&]?[%a_][%w_]*$") then
      return "identifier"
    end
  end
  return nil
end

---@type bitwise.Adapter
return {
  name = "generic",
  generic = true,
  classify = classify,
  identifier_nodes = identifier_nodes,
  -- `nodes` is unused when `classify` is present but keeps the shape uniform
  -- for anything that introspects adapters.
  nodes = { binary = {}, unary = {}, paren = {}, literal = {} },
  binary_operators = setmetatable({}, {
    __index = function(_, token)
      return BINARY[type(token) == "string" and token:lower() or ""] ~= nil
    end,
  }),
  operator_aliases = setmetatable({}, {
    __index = function(_, token)
      return BINARY[type(token) == "string" and token:lower() or ""]
    end,
  }),
  unary_operators = setmetatable({}, {
    __index = function(_, token)
      return UNARY[type(token) == "string" and token:lower() or ""]
    end,
  }),
  parse_literal = util.scan_any_integer,
  semantics = {
    default_width = 64,
    default_signed = true,
    -- Nothing is known about this language's shift rules, so do not invent any.
    shift_semantics = "undefined",
    arithmetic_shift_right = true,
  },
  notes = { "generic Tree-sitter analysis: 64-bit signed semantics assumed" },
}
