--- The structural (generic) adapter: analysing languages that have no
--- dedicated adapter, purely from the shape of the syntax tree.

local t = require("harness")
local h = require("nvim.helpers")
local bv = require("bitwise-visualizer")
local parser = require("bitwise-visualizer.parser")
local languages = require("bitwise-visualizer.languages")

---@param filetype string
---@param lines string[]
---@param needle string
---@return string
local function render(filetype, lines, needle)
  local buf = h.buffer(filetype, lines)
  for i, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      h.cursor_on(needle, i)
      break
    end
  end
  return table.concat(bv.render_text({ buf = buf }) or {}, "\n")
end

t.describe("generic adapter", function()
  t.describe("literal scanning", function()
    local scan = languages.generic.parse_literal

    t.it("reads the integer syntaxes used across languages", function()
      t.eq("FF", scan("0xFF").digits)
      t.eq(16, scan("16#FF#").base) -- Ada / VHDL
      t.eq(2, scan("2#1010#").base)
      t.eq(16, scan("8'hFF").base) -- Verilog
      t.eq(16, scan("$FF").base) -- Pascal
      t.eq(2, scan("%1010").base)
      t.eq(16, scan("#xff").base) -- Lisp
      t.eq(16, scan("&HFF").base) -- BASIC
      t.eq("1000", scan("1_000").digits)
      t.eq("10", scan("10u8").digits)
    end)

    t.it("refuses ambiguous and non-numeric text", function()
      t.is_nil(scan("010"), "a leading zero means different things per language")
      t.is_nil(scan("abc"))
      t.is_nil(scan("0xZZ"))
      t.is_nil(scan(""))
    end)
  end)

  if h.has_parser("ruby") then
    t.it("analyses Ruby without a dedicated adapter", function()
      t.is_nil(languages.get("ruby"), "ruby must not have its own adapter")
      local out = render("ruby", { "a = 0xF0 & 0x3C" }, "0xF0 & 0x3C")
      t.contains(out, "0011 0000", "the result must be computed")
      t.contains(out, "generic", "the generic analysis must be disclosed")
    end)

    t.it("never reads boolean operators as bitwise ones", function()
      t.eq("", render("ruby", { "x = (12 and 10)" }, "12 and 10"))
      t.eq("", render("ruby", { "x = (12 or 10)" }, "12 or 10"))
      t.eq("", render("ruby", { "x = !5" }, "!5"))
    end)

    t.it("resolves constants in a generic language", function()
      local out = render("ruby", { "y = 10", "a = y | 3" }, "y | 3")
      t.contains(out, "0000 1011")
    end)
  end

  if h.has_parser("ruby") then
    t.it("refuses a write it cannot prove is visible", function()
      -- Without an adapter the scoping rules are unknown, so only writes at the
      -- same nesting level as the use may be trusted.
      t.contains(render("ruby", { "def f", "  y = 20", "end", "r = y & 3" }, "y & 3"), "????")
      t.contains(render("ruby", { "if c", "  y = 20", "end", "r = y & 3" }, "y & 3"), "????")
      t.contains(render("ruby", { "while c", "  y = 20", "end", "r = y & 3" }, "y & 3"), "????")
    end)

    t.it("refuses a write guarded by a statement modifier", function()
      for _, modifier in ipairs({ "if c", "unless c", "while c", "until c" }) do
        local lines = { "y = 20 " .. modifier, "r = y & 3" }
        t.contains(render("ruby", lines, "y & 3"), "????", modifier .. " is still conditional")
      end
    end)

    t.it("refuses a conditional short-circuit assignment", function()
      t.contains(render("ruby", { "c and y = 20", "r = y & 3" }, "y & 3"), "????")
      t.contains(render("ruby", { "c or y = 20", "r = y & 3" }, "y & 3"), "????")
    end)

    t.it("still resolves a write beside the use", function()
      t.contains(render("ruby", { "def f", "  y = 10", "  a = y | 3", "end" }, "y | 3"), "0000 1010")
    end)
  end

  if h.has_parser("perl") then
    t.it("resolves a Perl scalar", function()
      t.contains(render("perl", { "my $y = 10;", "my $a = $y | 3;" }, "$y | 3"), "0000 1010")
    end)
  end

  if h.has_parser("bash") then
    t.it("resolves and refuses shell assignments", function()
      t.contains(render("bash", { "y=10", "x=$(( y & 12 ))" }, "y & 12"), "0000 1010")
      t.contains(render("bash", { "y=10", "y=20", "x=$(( y & 12 ))" }, "y & 12"), "????")
      t.contains(render("bash", { "f() {", "  y=20", "}", "x=$(( y & 12 ))" }, "y & 12"), "????")
      -- A subshell assignment never reaches the parent shell.
      t.contains(render("bash", { "( y=20 )", "x=$(( y & 12 ))" }, "y & 12"), "????")
      t.contains(render("bash", { "[ x ] && y=20", "x=$(( y & 12 ))" }, "y & 12"), "????")
    end)

    t.it("refuses names that a shell construct may rewrite", function()
      local cases = {
        { "((y++))" },
        { "((y=20))" },
        { "unset y" },
        { "read y" },
        { "let y=20" },
        { "for y in 1 2; do :; done" },
        { "while read y; do :; done" },
      }
      for _, case in ipairs(cases) do
        local lines = { "y=10", case[1], "x=$(( y & 12 ))" }
        t.contains(render("bash", lines, "y & 12"), "????", case[1] .. " must poison the name")
      end
    end)

    t.it("analyses shell arithmetic expansion", function()
      local out = render("bash", { "x=$(( 10 & 12 ))" }, "10 & 12")
      t.contains(out, "0000 1000")
    end)
  end

  if h.has_parser("forth") then
    t.it("stays silent on languages that are not infix", function()
      local out = render("forth", { ": foo 10 12 AND ;" }, "AND")
      t.eq("", out, "postfix languages must produce nothing")
    end)
  end

  if h.has_parser("c") then
    t.it("prefers a dedicated adapter over the fallback", function()
      h.buffer("c", { "int x = 10 & 12;" })
      local row, col = h.cursor_on("&")
      local found = parser.find_at(0, row, col, {
        trigger = "expression",
        subexpression = true,
        operators = {},
        resolve = true,
        generic = true,
      })
      t.ok(found)
      t.eq("c", found.adapter.name)
    end)

    t.it("can be disabled", function()
      h.buffer("markdown", { "10 & 12" })
      local found, why = parser.find_at(0, 0, 3, {
        trigger = "expression",
        subexpression = true,
        operators = {},
        generic = false,
      })
      t.is_nil(found)
      t.contains(why, "unsupported language")
    end)
  end
end)
