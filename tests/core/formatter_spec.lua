local t = require("harness")
local evaluator = require("bitwise-visualizer.evaluator")
local formatter = require("bitwise-visualizer.formatter")
local c = require("bitwise-visualizer.languages.c")

--- Formatting defaults mirroring `config.defaults` but without needing Neovim.
local function cfg(over)
  local base = {
    width = "auto",
    display_widths = { 8, 16, 32, 64 },
    group_bits = 0,
    show_decimal = true,
    show_hex = false,
    show_labels = true,
    show_unknown = true,
    show_fully_unknown = false,
    show_notes = true,
    highlights = {},
  }
  for k, v in pairs(over or {}) do
    base[k] = v
  end
  return base
end

local function lit(text)
  local p = assert(c.parse_literal(text), text)
  return { kind = "literal", text = text, base = p.base, digits = p.digits, suffix = p.suffix }
end

local function unknown(text)
  return { kind = "unknown", text = text }
end

local function bin(op, l, r, text)
  return { kind = "binary", op = op, op_text = op, text = text or "expr", left = l, right = r }
end

local function un(op, x, text)
  return { kind = "unary", op = op, op_text = op, text = text or "expr", operand = x }
end

---@return string[] lines
local function render(node, over, lang)
  local semantics = (lang or c).semantics
  local options = cfg(over)
  local evaluated = assert(evaluator.evaluate(node, { width = options.width, semantics = semantics }))
  local rendered, why = formatter.format(evaluated, options)
  assert(rendered, why)
  return formatter.to_strings(rendered), rendered
end

--- All bit characters on a line, ignoring alignment padding.
local function bits_of(line)
  local field = line:gsub("^%s*", ""):gsub("^[^01?]*", "")
  local found = field:match("^[01?]+[01?%s]*") or ""
  return (found:gsub("%s%s.*$", ""):gsub("%s+$", ""))
end

t.describe("formatter", function()
  t.describe("layout", function()
    t.it("renders operands, a separator and the result", function()
      local lines = render(bin("&", lit("10"), lit("12"), "10 & 12"))
      t.eq(4, #lines)
      t.contains(lines[1], "00001010")
      t.contains(lines[1], "(10)")
      t.contains(lines[2], "&")
      t.contains(lines[2], "00001100")
      t.contains(lines[3], formatter.SEPARATOR_CHAR)
      t.contains(lines[4], "00001000")
      t.contains(lines[4], "(8)")
    end)

    t.it("aligns every row on the same bit column", function()
      local lines = render(bin("&", lit("10"), lit("12"), "10 & 12"))
      local col1 = lines[1]:find("0")
      local col2 = lines[2]:find("0")
      local col4 = lines[4]:find("0")
      t.eq(col1, col2)
      t.eq(col1, col4)
    end)

    t.it("groups bits", function()
      local lines = render(bin("&", lit("10"), lit("12")), { group_bits = 4 })
      t.eq("0000 1010", bits_of(lines[1]))
    end)

    t.it("shows source labels for non-literal operands", function()
      local lines = render(bin("&", unknown("flags"), lit("0x0F"), "flags & 0x0F"), { group_bits = 4 })
      t.contains(lines[1], "???? ????")
      t.contains(lines[1], "flags")
      t.contains(lines[2], "0000 1111")
      t.contains(lines[2], "0x0F")
      t.contains(lines[4], "0000 ????")
      t.contains(lines[4], "flags & 0x0F")
    end)

    t.it("can hide decimal annotations", function()
      local lines = render(bin("&", lit("10"), lit("12")), { show_decimal = false })
      t.eq(nil, lines[1]:find("(10)", 1, true))
    end)

    t.it("can show hexadecimal annotations", function()
      local lines = render(bin("&", lit("10"), lit("12")), { show_hex = true })
      t.contains(lines[4], "0x8")
    end)
  end)

  t.describe("operator specific output", function()
    t.it("AND / OR / XOR results", function()
      t.eq("00001000", bits_of(render(bin("&", lit("10"), lit("12")))[4]))
      t.eq("00001110", bits_of(render(bin("|", lit("10"), lit("12")))[4]))
      t.eq("00000110", bits_of(render(bin("^", lit("10"), lit("12")))[4]))
    end)

    t.it("NOT renders a single operand row prefixed by the operator", function()
      local lines = render(un("~", lit("10"), "~10"), { width = 8 })
      t.eq(3, #lines)
      t.contains(lines[1], "~")
      t.eq("00001010", bits_of(lines[1]))
      t.eq("11110101", bits_of(lines[3]))
    end)

    t.it("shifts show the shift amount on its own row", function()
      local lines = render(bin("<<", lit("10"), lit("2"), "10 << 2"), { group_bits = 4 })
      t.eq("0000 1010", bits_of(lines[1]))
      t.contains(lines[2], "<< 2")
      t.eq("0010 1000", bits_of(lines[4]))
      t.contains(lines[4], "(40)")
    end)

    t.it("labels arithmetic versus logical right shifts", function()
      local signed = render(bin(">>", un("-", lit("8")), lit("1"), "-8 >> 1"), { width = 8 })
      t.contains(signed[2], "arithmetic")
      local lua = require("bitwise-visualizer.languages.lua")
      local logical = render(bin(">>", un("-", lit("8")), lit("1"), "-8 >> 1"), { width = 8 }, lua)
      t.contains(logical[2], "logical")
    end)
  end)

  t.describe("highlighting", function()
    local function hl_of(rendered, line_index)
      local out = {}
      for _, chunk in ipairs(rendered.lines[line_index]) do
        out[#out + 1] = tostring(chunk.hl) .. ":" .. chunk.text
      end
      return table.concat(out, "|")
    end

    t.it("marks contributing bits for AND", function()
      local _, rendered = render(bin("&", lit("10"), lit("12")))
      t.contains(hl_of(rendered, 1), "active:1")
      t.contains(hl_of(rendered, 4), "active:1")
    end)

    t.it("uses a dedicated highlight for unknown bits", function()
      local _, rendered = render(bin("&", unknown("f"), lit("0x0F")))
      t.contains(hl_of(rendered, 1), "unknown:")
    end)
  end)

  t.describe("automatic width", function()
    t.it("shrinks to the smallest lossless width", function()
      local _, rendered = render(bin("&", lit("10"), lit("12")))
      t.eq(8, rendered.width)
      t.eq(32, rendered.eval_width)
    end)

    t.it("grows when the value needs it", function()
      local _, rendered = render(bin("|", lit("0x1000"), lit("1")))
      t.eq(16, rendered.width)
    end)

    t.it("never displays fewer bits than a forced width", function()
      local _, rendered = render(bin("&", lit("10"), lit("12")), { width = 32 })
      t.eq(32, rendered.width)
    end)

    t.it("says nothing when the hidden bits are redundant sign extension", function()
      local _, rendered = render(bin("&", lit("10"), lit("12")))
      t.eq(0, #rendered.notes)
    end)

    t.it("says so when the hidden bits are unknown", function()
      local _, rendered = render(bin("&", unknown("flags"), lit("0x0F")))
      t.eq(1, #rendered.notes)
      t.contains(rendered.notes[1], "showing the low 8 bits")
    end)
  end)

  t.describe("unknown handling", function()
    t.it("suppresses fully unknown expressions by default", function()
      local evaluated = assert(evaluator.evaluate(bin("^", unknown("foo()"), unknown("bar()")), {
        semantics = c.semantics,
      }))
      local rendered, why = formatter.format(evaluated, cfg())
      t.is_nil(rendered)
      t.contains(why, "fully unknown")
    end)

    t.it("renders fully unknown expressions on request", function()
      local lines = render(bin("^", unknown("foo()"), unknown("bar()"), "foo() ^ bar()"), {
        show_fully_unknown = true,
        group_bits = 4,
        width = 8,
      })
      t.eq("???? ????", bits_of(lines[1]))
      t.contains(lines[1], "foo()")
      t.eq("???? ????", bits_of(lines[4]))
      t.contains(lines[4], "foo() ^ bar()")
    end)

    t.it("suppresses everything unknown when configured", function()
      local evaluated = assert(evaluator.evaluate(bin("&", unknown("flags"), lit("0x0F")), {
        semantics = c.semantics,
      }))
      local rendered, why = formatter.format(evaluated, cfg({ show_unknown = false }))
      t.is_nil(rendered)
      t.contains(why, "unknown values are disabled")
    end)
  end)

  t.describe("guards", function()
    t.it("refuses to format a non-operation", function()
      local rendered, why = formatter.format({ kind = "literal", value = false }, cfg())
      t.is_nil(rendered)
      t.contains(why, "not an operation")
    end)

    t.it("refuses to format an unevaluated node", function()
      local rendered, why = formatter.format({ kind = "binary" }, cfg())
      t.is_nil(rendered)
      t.contains(why, "not evaluated")
    end)
  end)
end)
