local t = require("harness")
local bits = require("bitwise-visualizer.bits")

local function b(str, signed)
  -- `str` is written most-significant-bit first, `?` marks an unknown bit.
  local width = #str
  local v = bits.new(width, signed)
  for i = 1, width do
    local ch = str:sub(width - i + 1, width - i + 1)
    v.bits[i] = (ch == "?") and bits.U or tonumber(ch)
  end
  return v
end

local function s(v, width)
  return table.concat(bits.to_chars(v, width))
end

t.describe("bits", function()
  t.describe("construction", function()
    t.it("parses decimal literals", function()
      local v = bits.from_digits("10", 10, 8, true)
      t.eq("00001010", s(v))
      t.eq("10", bits.to_decimal(v))
    end)

    t.it("parses hexadecimal literals", function()
      t.eq("11111111", s(bits.from_digits("FF", 16, 8, false)))
      t.eq("00001111", s(bits.from_digits("0F", 16, 8, false)))
    end)

    t.it("parses binary literals", function()
      t.eq("10101010", s(bits.from_digits("10101010", 2, 8, false)))
    end)

    t.it("parses octal literals", function()
      t.eq("00111111", s(bits.from_digits("77", 8, 8, false)))
    end)

    t.it("rejects invalid digits", function()
      local v, err = bits.from_digits("2", 2, 8, false)
      t.is_nil(v)
      t.contains(err, "invalid")
    end)

    t.it("is exact for 64-bit values beyond double precision", function()
      local v = bits.from_digits("18446744073709551615", 10, 64, false)
      t.eq(string.rep("1", 64), s(v))
      t.eq("18446744073709551615", bits.to_decimal(v))
    end)

    t.it("reports overflow instead of silently truncating", function()
      local _, overflow = bits.from_digits("256", 10, 8, false)
      t.eq(true, overflow)
      local _, ok = bits.from_digits("255", 10, 8, false)
      t.eq(false, ok)
      local _, signed_overflow = bits.from_digits("128", 10, 8, true)
      t.eq(true, signed_overflow, "128 does not fit in a signed byte")
    end)
  end)

  t.describe("tri-state logic", function()
    t.it("AND: zero dominates unknown", function()
      t.eq("0010?010", s(bits.band(b("1010?010"), b("0111?111"))))
    end)

    t.it("OR: one dominates unknown", function()
      t.eq("1111?111", s(bits.bor(b("1010?010"), b("0101?101"))))
    end)

    t.it("XOR: unknown poisons the bit", function()
      t.eq("1111??11", s(bits.bxor(b("1010??00"), b("0101??11"))))
    end)

    t.it("NOT preserves unknown bits", function()
      t.eq("0101?101", s(bits.bnot(b("1010?010"))))
    end)

    t.it("classifies knowledge", function()
      t.eq("known", b("1010"):knowledge())
      t.eq("partial", b("10?0"):knowledge())
      t.eq("unknown", b("????"):knowledge())
    end)
  end)

  t.describe("shifts", function()
    t.it("shifts left and drops the high bits", function()
      t.eq("00101000", s(bits.shl(b("00001010"), 2)))
      t.eq("00000000", s(bits.shl(b("00001010"), 8)))
    end)

    t.it("performs a logical right shift", function()
      t.eq("00101000", s(bits.shr(b("10100000"), 2, false)))
    end)

    t.it("performs an arithmetic right shift", function()
      t.eq("11101000", s(bits.shr(b("10100000", true), 2, true)))
    end)

    t.it("propagates unknown bits through shifts", function()
      t.eq("??????00", s(bits.shl(b("0??????0"), 1)))
    end)
  end)

  t.describe("signed values", function()
    t.it("renders negative decimals via two's complement", function()
      local v = bits.from_number(-1, 8, true)
      t.eq("11111111", s(v))
      t.eq("-1", bits.to_decimal(v))
    end)

    t.it("distinguishes signed from unsigned interpretation", function()
      local v = b("11111111", true)
      t.eq("-1", bits.to_decimal(v))
      v.signed = false
      t.eq("255", bits.to_decimal(v))
    end)

    t.it("negates exactly at 64 bits", function()
      local v = bits.from_number(-1, 64, true)
      t.eq("-1", bits.to_decimal(v))
      t.eq(string.rep("1", 64), s(v))
    end)

    t.it("handles the most negative value", function()
      local v = bits.new(8, true)
      v.bits[8] = 1
      t.eq("-128", bits.to_decimal(v))
    end)
  end)

  t.describe("resize", function()
    t.it("sign-extends when widening signed values", function()
      local v = b("1111", true):resize(8)
      t.eq("11111111", s(v))
    end)

    t.it("zero-extends when widening unsigned values", function()
      local v = b("1111", false):resize(8)
      t.eq("00001111", s(v))
    end)

    t.it("reports truncation when narrowing loses information", function()
      local _, truncated = b("100000000", false):resize(8)
      t.eq(true, truncated)
      local _, kept = b("000001111", false):resize(8)
      t.eq(false, kept)
    end)
  end)

  t.describe("display width", function()
    t.it("hides redundant zero extension", function()
      t.eq(5, b("00000000000000000000000000001010", true):visual_width())
    end)

    t.it("hides redundant sign extension", function()
      t.eq(1, b("11111111", true):visual_width())
    end)

    t.it("hides an unknown extension run", function()
      t.eq(1, b("????????", true):visual_width())
      t.eq(4, b("????1010", true):visual_width())
    end)
  end)

  t.describe("conversions", function()
    t.it("formats hexadecimal", function()
      t.eq("0xFF", bits.to_hex(b("11111111")))
      t.eq("0x0", bits.to_hex(b("00000000")))
    end)

    t.it("refuses to convert unknown values", function()
      t.is_nil(bits.to_decimal(b("1010????")))
      t.is_nil(bits.to_hex(b("1010????")))
      t.is_nil(bits.to_number(b("1010????")))
    end)
  end)
end)

t.describe("arithmetic", function()
  local function v(n, width)
    return bits.from_number(n, width or 8, true)
  end

  t.it("adds and wraps", function()
    t.eq("7", bits.to_decimal(bits.add(v(3), v(4))))
    t.eq("0", bits.to_decimal(bits.add(bits.from_digits("255", 10, 8, false), bits.from_digits("1", 10, 8, false))))
  end)

  t.it("subtracts", function()
    t.eq("-1", bits.to_decimal(bits.sub(v(3), v(4))))
  end)

  t.it("multiplies", function()
    t.eq("42", bits.to_decimal(bits.mul(v(6), v(7))))
    t.eq("-6", bits.to_decimal(bits.mul(v(-3), v(2))))
  end)

  t.it("keeps low bits exact until the first unknown carry", function()
    local a = bits.from_array({ 1, 0, bits.U, 0, 0, 0, 0, 0 }, 8, false)
    local sum = bits.add(a, bits.from_digits("1", 10, 8, false))
    t.eq(0, sum:get(1))
    t.eq(1, sum:get(2))
    t.eq(bits.U, sum:get(3))
  end)

  t.it("declines to guess an unknown product", function()
    local a = bits.unknown(8, false)
    t.eq("unknown", bits.mul(a, bits.from_digits("2", 10, 8, false)):knowledge())
  end)
end)
