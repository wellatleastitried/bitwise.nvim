local t = require("harness")
local util = require("bitwise-visualizer.languages.util")

--- Adapters are pure tables, so they can be exercised without Neovim.
local function adapter(name)
  return require("bitwise-visualizer.languages." .. name)
end

t.describe("literals", function()
  t.describe("C", function()
    local parse = adapter("c").parse_literal

    t.it("reads decimal, hex, binary and octal", function()
      t.eq(10, parse("10").base == 10 and 10 or -1)
      t.eq("10", parse("10").digits)
      t.eq(16, parse("0xFF").base)
      t.eq("FF", parse("0xFF").digits)
      t.eq(2, parse("0b1010").base)
      t.eq(8, parse("0755").base)
      t.eq("755", parse("0755").digits)
    end)

    t.it("keeps suffixes", function()
      t.eq("u", parse("42u").suffix)
      t.eq("ULL", parse("42ULL").suffix)
      t.eq(16, parse("0xFFu").base)
    end)

    t.it("strips C++ digit separators", function()
      t.eq("1000000", parse("1'000'000").digits)
    end)

    t.it("reports a sign folded into the literal token", function()
      t.eq(true, parse("-1").negative)
      t.eq("1", parse("-1").digits)
      t.eq(false, parse("1").negative)
    end)

    t.it("reads character literals", function()
      t.eq("65", parse("'A'").digits)
      t.eq("10", parse("'\\n'").digits)
      t.eq("65", parse("'\\x41'").digits)
      t.eq("8", parse("'\\010'").digits)
      t.eq("65", parse("u'A'").digits)
      t.is_nil(parse("''"))
    end)

    t.it("rejects floats", function()
      t.is_nil(parse("1.5"))
      t.is_nil(parse("1e10"))
    end)

    t.it("maps suffixes onto a width and signedness", function()
      local lit = adapter("c").semantics.literal_type
      local w, s = lit({ suffix = "u" })
      t.is_nil(w)
      t.eq(false, s)
      local w2 = lit({ suffix = "LL" })
      t.eq(64, w2)
    end)
  end)

  t.describe("Rust", function()
    local a = adapter("rust")

    t.it("strips underscores and reads suffixes", function()
      t.eq("10101010", a.parse_literal("0b1010_1010").digits)
      t.eq("u8", a.parse_literal("255u8").suffix)
      t.eq(8, a.parse_literal("0o17").base)
    end)

    t.it("derives width and signedness from the suffix", function()
      local w, s = a.semantics.literal_type({ suffix = "u8" })
      t.eq(8, w)
      t.eq(false, s)
      local w2, s2 = a.semantics.literal_type({ suffix = "i64" })
      t.eq(64, w2)
      t.eq(true, s2)
    end)

    t.it("uses `!` for bitwise NOT", function()
      t.eq("~", a.unary_operators["!"])
    end)
  end)

  t.describe("Go", function()
    local a = adapter("go")

    t.it("supports the AND-NOT operator", function()
      t.eq(true, a.binary_operators["&^"])
      t.ok(require("bitwise-visualizer.evaluator").binary_ops["&^"])
    end)

    t.it("uses unary `^` for NOT", function()
      t.eq("~", a.unary_operators["^"])
    end)
  end)

  t.describe("Java", function()
    local a = adapter("java")

    t.it("supports the unsigned right shift", function()
      t.eq(true, a.binary_operators[">>>"])
      t.eq("mask", a.semantics.shift_semantics)
    end)

    t.it("widens on the L suffix", function()
      local w = a.semantics.literal_type({ suffix = "L" })
      t.eq(64, w)
    end)
  end)

  t.describe("JavaScript", function()
    local a = adapter("javascript")

    t.it("declines BigInt literals rather than guessing", function()
      t.is_nil(a.parse_literal("10n"))
      t.eq("10", a.parse_literal("10").digits)
    end)

    t.it("uses 32-bit signed semantics", function()
      t.eq(32, a.semantics.default_width)
      t.eq(true, a.semantics.default_signed)
    end)
  end)

  t.describe("Lua", function()
    local a = adapter("lua")

    t.it("treats binary `~` as XOR and unary `~` as NOT", function()
      t.eq("^", a.operator_aliases["~"])
      t.eq("~", a.unary_operators["~"])
    end)

    t.it("uses a logical right shift", function()
      t.eq(false, a.semantics.arithmetic_shift_right)
    end)
  end)

  t.describe("Python", function()
    local a = adapter("python")

    t.it("reads 0o/0b/underscore forms", function()
      t.eq(8, a.parse_literal("0o777").base)
      t.eq("1010", a.parse_literal("0b1_010").digits)
    end)
  end)

  t.describe("scan_integer", function()
    t.it("does not treat a bare 0 as octal", function()
      t.eq(10, util.scan_integer("0", { leading_zero_octal = true }).base)
    end)

    t.it("rejects garbage", function()
      t.is_nil(util.scan_integer("0x", {}))
      t.is_nil(util.scan_integer("", {}))
      t.is_nil(util.scan_integer("0b12", {}))
    end)
  end)
end)
