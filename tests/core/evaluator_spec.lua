local t = require("harness")
local bits = require("bitwise-visualizer.bits")
local evaluator = require("bitwise-visualizer.evaluator")

local adapters = {
  c = require("bitwise-visualizer.languages.c"),
  java = require("bitwise-visualizer.languages.java"),
  go = require("bitwise-visualizer.languages.go"),
  lua = require("bitwise-visualizer.languages.lua"),
  javascript = require("bitwise-visualizer.languages.javascript"),
  rust = require("bitwise-visualizer.languages.rust"),
  python = require("bitwise-visualizer.languages.python"),
}

--- Build IR nodes directly: the evaluator is completely independent of
--- Tree-sitter, which is exactly what makes it testable here.
local function lit(text, lang)
  local parsed = adapters[lang or "c"].parse_literal(text)
  assert(parsed, "unparsable literal in test: " .. text)
  return {
    kind = "literal",
    text = text,
    base = parsed.base,
    digits = parsed.digits,
    suffix = parsed.suffix,
    negative = parsed.negative,
  }
end

local function bin(op, left, right)
  return { kind = "binary", op = op, op_text = op, text = "expr", left = left, right = right }
end

local function un(op, operand)
  return { kind = "unary", op = op, op_text = op, text = "expr", operand = operand }
end

local function unknown(text)
  return { kind = "unknown", text = text }
end

---@return table evaluated, string|nil err
local function ev(node, lang, opts)
  opts = opts or {}
  opts.semantics = adapters[lang or "c"].semantics
  return evaluator.evaluate(node, opts)
end

local function dec(node)
  return bits.to_decimal(node.value)
end

local function chars(node, width)
  return table.concat(bits.to_chars(node.value, width or node.value.width))
end

local function has_note(node, needle)
  for _, n in ipairs(node.notes or {}) do
    if n:find(needle, 1, true) then
      return true
    end
  end
  return false
end

t.describe("evaluator", function()
  t.describe("operators", function()
    t.it("AND", function()
      t.eq("8", dec(ev(bin("&", lit("10"), lit("12")))))
    end)

    t.it("OR", function()
      t.eq("14", dec(ev(bin("|", lit("10"), lit("12")))))
    end)

    t.it("XOR", function()
      t.eq("6", dec(ev(bin("^", lit("10"), lit("12")))))
    end)

    t.it("NOT", function()
      t.eq("-11", dec(ev(un("~", lit("10")))))
    end)

    t.it("left shift", function()
      t.eq("40", dec(ev(bin("<<", lit("10"), lit("2")))))
    end)

    t.it("right shift", function()
      t.eq("2", dec(ev(bin(">>", lit("10"), lit("2")))))
    end)

    t.it("unary minus", function()
      t.eq("-10", dec(ev(un("-", lit("10")))))
    end)

    t.it("Go's AND-NOT", function()
      t.eq("2", dec(ev(bin("&^", lit("10"), lit("12")), "go")))
    end)

    t.it("Java's unsigned right shift", function()
      local r = ev(bin(">>>", un("-", lit("8")), lit("1")), "java")
      t.eq("2147483644", dec(r))
    end)

    t.it("refuses to guess unsupported operators", function()
      local r = ev(bin("**", lit("1"), lit("2")))
      t.eq("unknown", r.status)
      t.eq(false, r.exact)
    end)
  end)

  t.describe("literal bases", function()
    t.it("hexadecimal", function()
      t.eq("15", dec(ev(bin("&", lit("0xFF"), lit("0x0F")))))
    end)

    t.it("binary", function()
      t.eq("8", dec(ev(bin("&", lit("0b1010"), lit("0b1100")))))
    end)

    t.it("octal", function()
      t.eq("5", dec(ev(bin("&", lit("0755"), lit("07")))), "0755 & 07 == 0o5")
    end)

    t.it("digit separators", function()
      t.eq("255", dec(ev(bin("|", lit("0b1111'0000"), lit("0x0F")))))
    end)
  end)

  t.describe("width and signedness", function()
    t.it("honours an explicit width", function()
      local r = ev(bin("&", lit("0xFF"), lit("0x0F")), "c", { width = 8 })
      t.eq(8, r.value.width)
      t.eq("00001111", chars(r))
    end)

    t.it("uses the language default width", function()
      t.eq(32, ev(bin("&", lit("1"), lit("1")), "c").value.width)
      t.eq(64, ev(bin("&", lit("1"), lit("1")), "go").value.width)
      t.eq(64, ev(bin("&", lit("1"), lit("1")), "lua").value.width)
    end)

    t.it("widens for 64-bit literal suffixes", function()
      local r = ev(bin("<<", lit("1ULL"), lit("40")), "c")
      t.eq(64, r.value.width)
      t.eq("1099511627776", dec(r))
    end)

    t.it("makes the expression unsigned when a literal is unsigned", function()
      local r = ev(un("~", lit("0u")), "c")
      t.eq(false, r.value.signed)
      t.eq("4294967295", dec(r))
    end)

    t.it("keeps 64-bit results exact", function()
      local r = ev(un("~", lit("0")), "lua")
      t.eq("-1", dec(r))
      local all_ones = ev(bin("|", lit("0xFFFFFFFF"), lit("0")), "lua")
      t.eq("4294967295", dec(all_ones))
    end)

    t.it("performs an arithmetic right shift on signed values", function()
      t.eq("-4", dec(ev(bin(">>", un("-", lit("8")), lit("1")), "c")))
    end)

    t.it("performs a logical right shift in Lua", function()
      local r = ev(bin(">>", un("-", lit("8")), lit("1")), "lua")
      t.eq("9223372036854775804", dec(r))
    end)

    t.it("handles a sign folded into the literal token", function()
      local r = ev(bin(">>", lit("-1"), lit("1")), "c")
      t.eq("-1", dec(r))
      t.eq("known", r.status)
    end)

    t.it("accepts the most negative representable literal", function()
      local r = ev(bin("&", lit("-128"), lit("-1")), "c", { width = 8 })
      t.eq("-128", dec(r))
      t.eq(true, r.exact)
    end)

    t.it("reports a negative literal that does not fit", function()
      local r = ev(bin("&", lit("-129"), lit("-1")), "c", { width = 8 })
      t.ok(has_note(r, "does not fit"))
    end)

    t.it("wraps a negative literal in an unsigned expression", function()
      -- C says the conversion is well defined modulo 2^w, so this is 1u.
      local r = ev(bin("&", lit("-1"), lit("1u")), "c", { width = 8 })
      t.eq("1", dec(r))
      t.eq("11111111", chars(r.left))
    end)

    t.it("evaluates character literals as integers", function()
      t.eq("65", dec(ev(bin("|", lit("'A'"), lit("0")))))
    end)

    t.it("gives JavaScript >>> an unsigned result", function()
      local r = ev(bin(">>>", lit("-1", "javascript"), lit("0", "javascript")), "javascript")
      t.eq("4294967295", dec(r))
      t.eq(false, r.value.signed)
    end)

    t.it("keeps Java >>> signed", function()
      local r = ev(bin(">>>", lit("-1", "java"), lit("0", "java")), "java")
      t.eq("-1", dec(r))
      t.eq(true, r.value.signed)
      local shifted = ev(bin(">>>", lit("-1", "java"), lit("1", "java")), "java")
      t.eq("2147483647", dec(shifted))
    end)

    t.it("flags a Python shift that grows past the display window", function()
      local r = ev(bin("<<", lit("1", "python"), lit("63", "python")), "python")
      t.eq(true, r.decimal_unreliable)
      t.ok(has_note(r, "display window"))
    end)

    t.it("does not flag a Python shift that stays inside the window", function()
      local r = ev(bin("<<", lit("1", "python"), lit("4", "python")), "python")
      t.eq(nil, r.decimal_unreliable)
      t.eq("16", dec(r))
    end)

    t.it("notes bits shifted out of a fixed width", function()
      local r = ev(bin("<<", lit("255"), lit("30")), "c")
      t.ok(has_note(r, "shifted out"))
      t.eq(nil, r.decimal_unreliable, "C truncation is well defined, so the decimal stands")
    end)

    t.it("folds addition, subtraction and multiplication", function()
      t.eq("15", dec(ev(bin("+", lit("10"), lit("5")))))
      t.eq("5", dec(ev(bin("-", lit("10"), lit("5")))))
      t.eq("50", dec(ev(bin("*", lit("10"), lit("5")))))
    end)

    t.it("keeps addition exact below the first unknown bit", function()
      local r = ev(bin("+", lit("1"), unknown("n")), "c", { width = 8 })
      t.eq("unknown", r.status)
    end)

    t.it("wraps arithmetic at the width like the language does", function()
      t.eq("0", dec(ev(bin("+", lit("255"), lit("1")), "c", { width = 8 })))
      t.eq("-1", dec(ev(bin("-", lit("0"), lit("1")), "c", { width = 8 })))
    end)

    t.it("does not classify arithmetic as a bitwise operation", function()
      t.eq(false, evaluator.is_bitwise("+"))
      t.eq(false, evaluator.is_bitwise("*"))
      t.eq(true, evaluator.is_bitwise("&"))
      t.eq(true, evaluator.is_bitwise("~"))
      t.eq(true, evaluator.is_bitwise(">>"))
    end)

    t.it("flags Python arithmetic that grows past the window", function()
      local r = ev(bin("*", lit("1", "python"), lit("1", "python")), "python")
      t.eq(nil, r.decimal_unreliable)
      local big = ev(bin("+", bin("<<", lit("1", "python"), lit("63", "python")), lit("0", "python")), "python")
      t.eq(true, big.decimal_unreliable, "the overflow must propagate to the parent")
    end)

    t.it("reports literal overflow instead of hiding it", function()
      local r = ev(bin("&", lit("300"), lit("0xFF")), "c", { width = 8 })
      t.ok(has_note(r, "does not fit"))
      t.eq(false, r.exact)
    end)
  end)

  t.describe("shift edge cases", function()
    t.it("treats over-wide shifts as undefined in C", function()
      local r = ev(bin("<<", lit("1"), lit("32")), "c")
      t.eq("unknown", r.status)
      t.ok(has_note(r, "undefined behaviour"))
    end)

    t.it("masks the shift count in Java", function()
      local r = ev(bin("<<", lit("1"), lit("33")), "java")
      t.eq("2", dec(r))
      t.ok(has_note(r, "masked"))
    end)

    t.it("shifts the value out in Go", function()
      local r = ev(bin("<<", lit("1"), lit("64")), "go")
      t.eq("0", dec(r))
      t.ok(has_note(r, "shifted out"))
    end)

    t.it("rejects negative shift counts", function()
      local r = ev(bin("<<", lit("1"), un("-", lit("2"))), "c")
      t.eq("unknown", r.status)
      t.ok(has_note(r, "negative shift"))
    end)

    t.it("cannot evaluate a runtime shift count", function()
      local r = ev(bin("<<", lit("1"), unknown("n")), "c")
      t.eq("unknown", r.status)
      t.ok(has_note(r, "not known at compile time"))
    end)
  end)

  t.describe("partially known values", function()
    t.it("keeps the known bits of `flags & 0x0F`", function()
      local r = ev(bin("&", unknown("flags"), lit("0x0F")), "c", { width = 8 })
      t.eq("partial", r.status)
      t.eq("0000????", chars(r))
    end)

    t.it("keeps the known bits of `flags | 0xF0`", function()
      local r = ev(bin("|", unknown("flags"), lit("0xF0")), "c", { width = 8 })
      t.eq("1111????", chars(r))
    end)

    t.it("stays fully unknown for `foo() ^ bar()`", function()
      local r = ev(bin("^", unknown("foo()"), unknown("bar()")), "c", { width = 8 })
      t.eq("unknown", r.status)
      t.eq("????????", chars(r))
    end)

    t.it("never claims to know a runtime value", function()
      local r = ev(bin("&", unknown("a"), unknown("b")), "c")
      t.is_nil(bits.to_decimal(r.value))
    end)
  end)

  t.describe("nested expressions", function()
    t.it("evaluates `(10 & 12) ^ 3`", function()
      local inner = { kind = "paren", text = "(10 & 12)", inner = bin("&", lit("10"), lit("12")) }
      t.eq("11", dec(ev(bin("^", inner, lit("3")))))
    end)

    t.it("evaluates chained operations", function()
      local expr = bin("|", bin("&", lit("0xF0"), lit("0x3C")), bin("<<", lit("1"), lit("0")))
      t.eq("49", dec(ev(expr)))
    end)

    t.it("propagates partial knowledge through nesting", function()
      local expr = bin("|", bin("&", unknown("x"), lit("0x0F")), lit("0xF0"))
      local r = ev(expr, "c", { width = 8 })
      t.eq("1111????", chars(r))
    end)

    t.it("refuses expressions above the complexity limit", function()
      local expr = lit("1")
      for _ = 1, 20 do
        expr = bin("&", expr, lit("1"))
      end
      local r, err = ev(expr, "c", { max_nodes = 8 })
      t.is_nil(r)
      t.contains(err, "too complex")
    end)
  end)

  t.describe("malformed input", function()
    t.it("handles an unparsable literal", function()
      local r = ev(bin("&", { kind = "literal", text = "??", base = 10, digits = "zz" }, lit("1")))
      t.eq("partial", r.status, "an unparsable operand degrades to unknown bits")
      t.eq("unknown", r.left.status)
      t.ok(has_note(r.left, "unparsable literal"))
    end)

    t.it("handles a non-table root", function()
      local r, err = evaluator.evaluate("not an expression")
      t.is_nil(r)
      t.contains(err, "invalid expression")
    end)
  end)

  t.describe("contribution mask", function()
    t.it("marks 1 & 1 positions", function()
      local a = bits.from_digits("1010", 2, 4, false)
      local b = bits.from_digits("1100", 2, 4, false)
      local mask = evaluator.contribution_mask("&", a, b)
      t.eq(true, mask[4])
      t.eq(false, mask[3])
      t.eq(false, mask[2])
      t.eq(false, mask[1])
    end)

    t.it("marks XOR positions where exactly one bit is set", function()
      local a = bits.from_digits("1010", 2, 4, false)
      local b = bits.from_digits("1100", 2, 4, false)
      local mask = evaluator.contribution_mask("^", a, b)
      t.eq(false, mask[4])
      t.eq(true, mask[3])
      t.eq(true, mask[2])
    end)
  end)
end)
