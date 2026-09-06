local t = require("harness")
local h = require("nvim.helpers")
local parser = require("bitwise-visualizer.parser")

local OPTS = { trigger = "expression", subexpression = true, operators = {} }

---@param src string single line of source
---@param filetype string
---@param needle string cursor lands on the first occurrence of this
---@return table|nil, string|nil
local function find(src, filetype, needle)
  h.buffer(filetype, { src })
  local row, col = h.cursor_on(needle)
  return parser.find_at(0, row, col, vim.tbl_extend("force", {}, OPTS))
end

t.describe("parser", function()
  if not h.has_parser("c") then
    t.it("SKIPPED: no C parser available", function() end)
    return
  end

  t.describe("expression discovery", function()
    t.it("finds the expression from the operator", function()
      local found = find("int x = 10 & 12;", "c", "&")
      t.ok(found)
      t.eq("binary", found.ir.kind)
      t.eq("&", found.ir.op)
      t.eq(true, found.on_operator)
      t.eq("10", found.ir.left.text)
      t.eq("12", found.ir.right.text)
    end)

    t.it("finds the expression from an operand", function()
      local found = find("int x = 10 & 12;", "c", "12")
      t.ok(found)
      t.eq("&", found.ir.op)
      t.eq(false, found.on_operator)
    end)

    t.it("ignores positions outside any expression", function()
      local found, why = find("int x = 10 & 12;", "c", "int")
      t.is_nil(found)
      t.ok(why)
    end)

    t.it("ignores non-bitwise expressions", function()
      local found, why = find("int x = 10 + 12;", "c", "+")
      t.is_nil(found)
      t.contains(why, "no bitwise operation")
    end)

    t.it("classifies unknown operands", function()
      local found = find("int x = flags & 0x0F;", "c", "&")
      t.eq("unknown", found.ir.left.kind)
      t.eq("flags", found.ir.left.text)
      t.eq("literal", found.ir.right.kind)
      t.eq(16, found.ir.right.base)
    end)

    t.it("treats function calls as unknown", function()
      local found = find("int x = foo() ^ bar();", "c", "^")
      t.eq("unknown", found.ir.left.kind)
      t.eq("foo()", found.ir.left.text)
    end)
  end)

  t.describe("nesting and precedence", function()
    t.it("keeps parentheses in the tree", function()
      local found = find("int x = (10 & 12) ^ 3;", "c", "^ 3")
      t.eq("^", found.ir.op)
      t.eq("paren", found.ir.left.kind)
      t.eq("&", found.ir.left.inner.op)
    end)

    t.it("respects operator precedence from the grammar", function()
      -- `&` binds tighter than `|`, so the root must be `|`.
      local found = find("int x = 1 | 2 & 3;", "c", "|")
      t.eq("|", found.ir.op)
      t.eq("&", found.ir.right.op)
    end)

    t.it("focuses the subexpression under the cursor", function()
      local found = find("int x = (10 & 12) ^ 3;", "c", "&")
      t.eq("&", found.ir.op, "cursor on & selects the AND")
      local outer = find("int x = (10 & 12) ^ 3;", "c", "^ 3")
      t.eq("^", outer.ir.op, "cursor on ^ selects the XOR")
    end)

    t.it("selects the whole expression when not on an operator", function()
      local found = find("int x = (10 & 12) ^ 3;", "c", "3;")
      t.eq("^", found.ir.op)
    end)

    t.it("handles chained operations", function()
      local found = find("int x = 1 | 2 | 4 | 8;", "c", "| 8")
      t.eq("|", found.ir.op)
      t.eq("8", found.ir.right.text)
    end)

    t.it("looks through parentheses around the whole expression", function()
      local found = find("int x = (10 & 12);", "c", "10")
      t.ok(found)
      t.eq("binary", found.ir.kind)
      t.eq("&", found.ir.op)
    end)

    t.it("finds a bitwise expression nested in a non-bitwise parent", function()
      local found = find("int x = 1 + (10 & 12);", "c", "12")
      t.ok(found)
      t.eq("&", found.ir.op)
    end)

    t.it("handles a negative literal folded into one token", function()
      local found = find("int x = -1 >> 1;", "c", ">>")
      t.eq("literal", found.ir.left.kind)
      t.eq(true, found.ir.left.negative)
    end)

    t.it("handles character literals", function()
      local found = find("int x = 0 & 'A';", "c", "&")
      t.eq("literal", found.ir.right.kind)
      t.eq("65", found.ir.right.digits)
    end)

    t.it("handles unary NOT inside a binary expression", function()
      local found = find("int x = ~mask & 0xFF;", "c", "&")
      t.eq("unary", found.ir.left.kind)
      t.eq("~", found.ir.left.op)
    end)
  end)

  t.describe("trigger modes", function()
    t.it("operator mode only fires on the operator", function()
      h.buffer("c", { "int x = 10 & 12;" })
      local row, col = h.cursor_on("&")
      t.ok(parser.find_at(0, row, col, { trigger = "operator", operators = {} }))
      local row2, col2 = h.cursor_on("12")
      local found, why = parser.find_at(0, row2, col2, { trigger = "operator", operators = {} })
      t.is_nil(found)
      t.contains(why, "not on a bitwise operator")
    end)

    t.it("respects disabled operators", function()
      h.buffer("c", { "int x = 10 & 12;" })
      local row, col = h.cursor_on("&")
      local found, why = parser.find_at(0, row, col, { operators = { ["&"] = false } })
      t.is_nil(found)
      t.contains(why, "no bitwise operation")
    end)
  end)

  t.describe("robustness", function()
    t.it("declines malformed source", function()
      local found = find("int x = 10 & ;", "c", "&")
      t.is_nil(found)
    end)

    t.it("declines incomplete source", function()
      local found = find("int x = 10 &", "c", "&")
      t.is_nil(found)
    end)

    t.it("declines unsupported languages when the fallback is off", function()
      h.buffer("markdown", { "10 & 12" })
      local found, why = parser.find_at(0, 0, 3, vim.tbl_extend("force", {}, OPTS, { generic = false }))
      t.is_nil(found)
      t.contains(why, "unsupported language")
    end)

    t.it("declines buffers without a parser", function()
      h.buffer("", { "10 & 12" })
      local found = parser.find_at(0, 0, 3, OPTS)
      t.is_nil(found)
    end)

    t.it("survives an out-of-range position", function()
      h.buffer("c", { "int x = 10 & 12;" })
      local ok = pcall(parser.find_at, 0, 99, 99, OPTS)
      t.eq(true, ok)
    end)
  end)

  t.describe("other languages", function()
    local cases = {
      {
        lang = "lua",
        filetype = "lua",
        src = "local x = 0xF0 | 0x0F",
        needle = "|",
        op = "|",
      },
      {
        lang = "lua",
        filetype = "lua",
        src = "local x = 10 ~ 12",
        needle = "~",
        op = "^", -- Lua's binary `~` is XOR
      },
      {
        lang = "python",
        filetype = "python",
        src = "x = 0b1010 & 0b1100",
        needle = "&",
        op = "&",
      },
      {
        lang = "java",
        filetype = "java",
        src = "class A { void f() { int x = -8 >>> 1; } }",
        needle = ">>>",
        op = ">>>",
      },
      {
        lang = "javascript",
        filetype = "javascript",
        src = "let x = 0xFF & 0x0F;",
        needle = "&",
        op = "&",
      },
    }

    for _, case in ipairs(cases) do
      t.it(case.lang .. ": " .. case.src, function()
        if not h.has_parser(case.lang) then
          return
        end
        local found = find(case.src, case.filetype, case.needle)
        t.ok(found, "expected to find an expression")
        t.eq(case.op, found.ir.op)
        t.eq(case.lang, found.lang)
      end)
    end
  end)
end)
