--- Constant resolution: `int y = 10; ... y | z` must show the bits of `y`,
--- but only when the syntax tree proves the value.

local t = require("harness")
local h = require("nvim.helpers")
local bv = require("bitwise-visualizer")

---@param filetype string
---@param lines string[]
---@param needle string cursor lands on the first occurrence of this
---@return string rendered text ("" when nothing is shown)
local function render(filetype, lines, needle)
  local buf = h.buffer(filetype, lines)
  for i, line in ipairs(lines) do
    if line:find(needle, 1, true) then
      h.cursor_on(needle, i)
      break
    end
  end
  local out = bv.render_text({ buf = buf })
  return table.concat(out or {}, "\n")
end

t.describe("constant resolution", function()
  if not h.has_parser("c") then
    t.it("SKIPPED: no C parser available", function() end)
    return
  end

  t.it("resolves a single-assignment local", function()
    local out = render("c", { "int f(int z) {", "  int y = 10;", "  return y | z;", "}" }, "y | z")
    t.contains(out, "0000 1010", "the bits of y must be known")
    t.contains(out, "y", "the label must stay the source text")
  end)

  t.it("resolves a #define", function()
    local out = render("c", { "#define MASK 0xF0", "int f(int z) { return MASK & z; }" }, "MASK & z")
    t.contains(out, "1111 0000")
  end)

  t.it("refuses a name that is assigned twice", function()
    local out = render("c", { "int f(void) {", "  int m = 1;", "  m = 7;", "  return m & 3;", "}" }, "m & 3")
    t.contains(out, "????", "a reassigned local must stay unknown")
    t.eq(nil, out:find("0000 0001", 1, true), "the stale initialiser must not be shown")
  end)

  t.it("refuses a name whose address is taken", function()
    local out = render("c", {
      "void g(int *p);",
      "int f(void) {",
      "  int p = 5;",
      "  g(&p);",
      "  return p & 3;",
      "}",
    }, "p & 3")
    t.contains(out, "????")
    t.eq(nil, out:find("0000 0101", 1, true))
  end)

  t.it("refuses a name mutated with a compound assignment", function()
    local out = render("c", { "int f(void) {", "  int k = 4;", "  k |= 1;", "  return k & 3;", "}" }, "k & 3")
    t.contains(out, "????")
  end)

  t.it("refuses a name shadowed by a function parameter", function()
    local out = render("c", { "int y = 5;", "void g(int y) {", "  int r = y & 3;", "}" }, "y & 3")
    t.contains(out, "????", "the parameter shadows the global, so nothing is known")
  end)

  t.it("refuses a declaration from a block that does not enclose the use", function()
    local lines = { "int y = 5;", "void g(int c) {", "  if (c) { int y = 20; }", "  int r = y & 3;", "}" }
    t.contains(render("c", lines, "y & 3"), "????", "the nested 20 is invisible here and may shadow the global")
  end)

  t.it("refuses a name that a conditional branch may reassign", function()
    local lines = { "int y = 10;", "void g(int c) {", "  if (c) { y = 3; }", "  int r = y & 1;", "}" }
    t.contains(render("c", lines, "y & 1"), "????")
  end)

  t.it("refuses a variable scoped to a for-init clause", function()
    local lines = { "int m = 0xFF;", "void g(void) {", "  for (int m = 2; m < 3; ) { }", "  int r = m & 0x0F;", "}" }
    t.contains(render("c", lines, "m & 0x0F"), "????")
  end)

  t.it("treats an identifier at a block's closing brace as outside that block", function()
    local lines = { "int y = 5;", "void g(int c) {", "  if (c) { int y = 20; }y & 3;", "}" }
    t.contains(render("c", lines, "y & 3"), "????", "an identifier starting at a block's closing brace is outside it")
  end)

  t.it("still resolves a binding from an enclosing scope", function()
    local lines = { "void g(void) {", "  int y = 10;", "  if (1) { int r = y | 3; }", "}" }
    t.contains(render("c", lines, "y | 3"), "0000 1010")
  end)

  t.it("still resolves past an unrelated read of the same name", function()
    local lines = { "int y = 5;", "void g(void) {", "  int a = y & 1;", "  int r = y & 3;", "}" }
    t.contains(render("c", lines, "y & 3"), "0000 0101")
  end)

  t.it("resolves a #define that precedes the use", function()
    t.contains(render("c", { "#define MASK 0xF0", "int r = MASK & 3;" }, "MASK & 3"), "1111 0000")
  end)

  t.it("refuses a #define that follows the use", function()
    t.contains(render("c", { "int r = MASK & 3;", "#define MASK 0xF0" }, "MASK & 3"), "????")
  end)

  t.it("refuses a macro that was undefined", function()
    local out = render("c", { "#define MASK 0xF0", "#undef MASK", "int r = MASK & 3;" }, "MASK & 3")
    t.contains(out, "????")
  end)

  t.it("refuses a macro defined under conditional compilation", function()
    local lines = { "#ifdef FOO", "#define MASK 0xF0", "#endif", "int r = MASK & 3;" }
    t.contains(render("c", lines, "MASK & 3"), "????")
  end)

  t.it("does not mistake a comparison for an assignment", function()
    for _, op in ipairs({ "==", "!=", "<=", ">=" }) do
      local lines = { "int y = 10;", "void g(void) {", "  if (y " .. op .. " 3) { }", "  int r = y & 1;", "}" }
      t.contains(render("c", lines, "y & 1"), "0000 1010", op .. " must not poison the name")
    end
  end)

  t.it("refuses a name assigned after the use", function()
    local out =
      render("c", { "int f(void) {", "  int q;", "  int r = q & 3;", "  q = 9;", "  return r;", "}" }, "q & 3")
    t.contains(out, "????")
  end)

  t.it("resolves through a nested constant expression", function()
    local out = render("c", { "int f(int z) {", "  int y = 1 << 3;", "  return y | z;", "}" }, "y | z")
    t.contains(out, "0000 1000")
  end)

  t.it("can be switched off", function()
    bv.configure({ resolve_identifiers = false })
    local out = render("c", { "int f(int z) {", "  int y = 10;", "  return y | z;", "}" }, "y | z")
    bv.configure({ resolve_identifiers = true })
    t.eq(nil, out:find("0000 1010", 1, true), "resolution must be disabled")
  end)

  if h.has_parser("python") then
    t.it("resolves a Python assignment", function()
      local out = render("python", { "y = 10", "z = foo()", "a = y | z" }, "y | z")
      t.contains(out, "0000 1010")
    end)

    t.it("refuses a loop variable that Python leaks into the enclosing scope", function()
      local lines = { "i = 0xFF", "for i in range(3):", "    pass", "r = i & 0x0F" }
      t.contains(render("python", lines, "i & 0x0F"), "????")
    end)

    t.it("does not treat a comprehension variable as a rebinding", function()
      local lines = { "n = 3", "vals = [n & 1 for n in range(4)]", "r = n & 1" }
      t.contains(render("python", lines, "n & 1"), "0000 0011")
    end)

    t.it("refuses a name rebound by an assignment expression", function()
      local lines = { "y = 0xFF", "if (y := 3):", "    pass", "r = y & 0x0F" }
      t.contains(render("python", lines, "y & 0x0F"), "????")
    end)

    t.it("refuses a deleted name", function()
      t.contains(render("python", { "y = 10", "del y", "r = y & 3" }, "y & 3"), "????")
    end)

    t.it("refuses a rebound Python name", function()
      local out = render("python", { "y = 10", "y = 20", "a = y | 1" }, "y | 1")
      t.contains(out, "????")
    end)
  end

  if h.has_parser("perl") then
    t.it("refuses an incremented Perl scalar", function()
      t.contains(render("perl", { "my $y = 10;", "$y++;", "my $r = $y & 3;" }, "$y & 3"), "????")
    end)
  end

  if h.has_parser("lua") then
    t.it("resolves a Lua local", function()
      local out = render("lua", { "local y = 10", "local a = y | 3" }, "y | 3")
      t.contains(out, "0000 1010")
    end)

    t.it("refuses a Lua multiple assignment", function()
      local out = render("lua", { "local y, w = 10, 20", "local a = y | 3" }, "y | 3")
      t.contains(out, "????")
    end)
  end

  if h.has_parser("javascript") then
    t.it("refuses a compound assignment written with its own node type", function()
      for _, op in ipairs({ "|=", "<<=", "&&=", "+=" }) do
        local lines = { "let y = 0xF0;", "y " .. op .. " 1;", "const r = y & 0x0F;" }
        t.contains(render("javascript", lines, "y & 0x0F"), "????", op .. " must poison the name")
      end
    end)

    t.it("refuses a shorthand destructuring assignment", function()
      local lines = { "let y = 0xF0;", "({ y } = o);", "const r = y & 0x0F;" }
      t.contains(render("javascript", lines, "y & 0x0F"), "????")
    end)

    t.it("ignores a compound assignment to an unrelated name", function()
      local lines = { "let y = 0xF0;", "let z = 1;", "z |= 2;", "const r = y & 0x0F;" }
      t.contains(render("javascript", lines, "y & 0x0F"), "1111 0000")
    end)

    t.it("refuses a for...of target", function()
      local lines = { "let y = 0xFF;", "function g(a) { for (y of a) { } return y & 0x0F; }" }
      t.contains(render("javascript", lines, "y & 0x0F"), "????")
    end)

    t.it("refuses a variable scoped to a for-init clause", function()
      local lines = { "let m = 0xFF;", "function g() { for (let m = 2; m < 3; ) { } return m & 0x0F; }" }
      t.contains(render("javascript", lines, "m & 0x0F"), "????")
    end)

    t.it("resolves a JavaScript const", function()
      local out = render("javascript", { "const y = 10;", "let a = y | 3;" }, "y | 3")
      t.contains(out, "0000 1010")
    end)
  end
end)
