local t = require("harness")
local h = require("nvim.helpers")
local bv = require("bitwise-visualizer")
local config = require("bitwise-visualizer.config")
local renderer = require("bitwise-visualizer.renderer")

---@return string[]
local function text_at(needle, src, filetype)
  h.buffer(filetype or "c", { src })
  h.cursor_on(needle)
  local lines, why = bv.render_text()
  return lines, why
end

---@return string
local function joined(needle, src, filetype)
  local lines = text_at(needle, src, filetype)
  return lines and table.concat(lines, "\n") or ""
end

t.describe("integration", function()
  if not h.has_parser("c") then
    t.it("SKIPPED: no C parser available", function() end)
    return
  end

  t.describe("end to end", function()
    t.it("visualizes `10 & 12`", function()
      local out = joined("&", "int x = 10 & 12;")
      t.contains(out, "1010")
      t.contains(out, "1100")
      t.contains(out, "1000")
      t.contains(out, "(8)")
    end)

    t.it("visualizes partially known expressions", function()
      local out = joined("&", "int x = flags & 0x0F;")
      t.contains(out, "????")
      t.contains(out, "flags")
      t.contains(out, "0x0F")
    end)

    t.it("suppresses fully unknown expressions by default", function()
      local lines, why = text_at("^", "int x = foo() ^ bar();")
      t.is_nil(lines)
      t.contains(why, "fully unknown")
    end)

    t.it("shows fully unknown expressions when asked", function()
      config.reset()
      bv.configure({ show_fully_unknown = true })
      local out = joined("^", "int x = foo() ^ bar();")
      t.contains(out, "????")
      t.contains(out, "foo()")
      config.reset()
    end)

    t.it("visualizes shifts", function()
      local out = joined("<<", "int x = 10 << 2;")
      t.contains(out, "<< 2")
      t.contains(out, "(40)")
    end)

    t.it("visualizes nested expressions per cursor position", function()
      local inner = joined("&", "int x = (10 & 12) ^ 3;")
      t.contains(inner, "(8)")
      local outer = joined("^ 3", "int x = (10 & 12) ^ 3;")
      t.contains(outer, "(11)")
    end)
  end)

  t.describe("rendering", function()
    t.it("draws exactly one extmark", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      t.eq(true, bv.show())
      t.eq(1, #renderer.extmarks(0))
    end)

    t.it("uses virtual lines and never touches the buffer", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.show()
      local marks = renderer.extmarks(0)
      local details = marks[1][4]
      t.ok(details.virt_lines, "expected virtual lines")
      t.eq(4, #details.virt_lines)
      t.eq(true, details.virt_lines_above)
      t.eq("int x = 10 & 12;", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
    end)

    t.it("applies highlight groups rather than raw text", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.show()
      local virt = renderer.extmarks(0)[1][4].virt_lines
      local groups = {}
      for _, line in ipairs(virt) do
        for _, chunk in ipairs(line) do
          if chunk[2] then
            groups[chunk[2]] = true
          end
        end
      end
      t.ok(groups["BitwiseVisualizerOne"] or groups["BitwiseVisualizerActive"])
      t.ok(groups["BitwiseVisualizerZero"])
      t.ok(groups["BitwiseVisualizerSeparator"])
    end)

    t.it("renders below the line when configured", function()
      bv.configure({ position = "below" })
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.show()
      t.eq(false, renderer.extmarks(0)[1][4].virt_lines_above)
      config.reset()
      bv.configure({})
    end)

    t.it("renders a compact eol summary when configured", function()
      bv.configure({ position = "eol" })
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.show()
      local details = renderer.extmarks(0)[1][4]
      t.ok(details.virt_text)
      t.is_nil(details.virt_lines)
      config.reset()
      bv.configure({})
    end)

    t.it("skips redundant redraws", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      t.eq(true, bv.show(), "first draw")
      t.eq(false, bv.show(), "identical redraw is skipped")
    end)
  end)

  t.describe("cursor movement", function()
    t.it("follows the cursor onto another expression", function()
      h.buffer("c", { "int a = 10 & 12;", "int b = 1 | 2;" })
      h.cursor_on("&", 1)
      bv.show()
      local first = renderer.extmarks(0)[1]
      t.eq(0, first[2], "anchored to the first line")

      h.cursor_on("|", 2)
      bv.show()
      local marks = renderer.extmarks(0)
      t.eq(1, #marks, "still exactly one extmark")
      t.eq(1, marks[1][2], "anchored to the second line")
    end)

    t.it("clears when the cursor leaves every expression", function()
      h.buffer("c", { "int x = 10 & 12;", "int y = 0;" })
      h.cursor_on("&", 1)
      bv.show()
      t.eq(1, #renderer.extmarks(0))
      h.cursor_on("y", 2)
      bv.refresh()
      t.eq(0, #renderer.extmarks(0), "no stale extmarks")
      t.eq(false, renderer.is_active(0))
    end)

    t.it("updates when the buffer changes", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.show()
      t.contains(table.concat(bv.render_text(), "\n"), "(8)")

      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "int x = 10 | 12;" })
      h.cursor_on("|")
      local out = table.concat(bv.render_text(), "\n")
      t.contains(out, "(14)", "the cached result must be invalidated")
    end)
  end)

  t.describe("configuration", function()
    t.it("warns about misspelled option names", function()
      local msgs = {}
      local notify = vim.notify
      vim.notify = function(msg)
        msgs[#msgs + 1] = msg
      end
      require("bitwise-visualizer").setup({ widht = 8, update = { debonce = 10 } })
      vim.notify = notify
      require("bitwise-visualizer").setup({})
      t.eq(1, #msgs)
      t.contains(msgs[1], "widht")
      t.contains(msgs[1], "update.debonce")
    end)

    t.it("accepts user-defined operator and highlight keys", function()
      local msgs = {}
      local notify = vim.notify
      vim.notify = function(msg)
        msgs[#msgs + 1] = msg
      end
      require("bitwise-visualizer").setup({
        operators = { ["<<<"] = true },
        highlights = { mine = "Comment" },
        disabled_filetypes = { "go" },
      })
      vim.notify = notify
      require("bitwise-visualizer").setup({})
      t.eq(0, #msgs)
    end)

    t.it("honours an explicit width", function()
      bv.configure({ width = 16 })
      local out = joined("&", "int x = 10 & 12;")
      t.contains(out, "0000 0000 0000 1010")
      config.reset()
      bv.configure({})
    end)

    t.it("honours group_bits", function()
      bv.configure({ group_bits = 0 })
      local out = joined("&", "int x = 10 & 12;")
      t.contains(out, "00001010")
      config.reset()
      bv.configure({})
    end)

    t.it("honours show_decimal", function()
      bv.configure({ show_decimal = false })
      local out = joined("&", "int x = 10 & 12;")
      t.eq(nil, out:find("(8)", 1, true))
      config.reset()
      bv.configure({})
    end)

    t.it("honours disabled operators", function()
      bv.configure({ operators = { ["&"] = false } })
      local lines = text_at("&", "int x = 10 & 12;")
      t.is_nil(lines)
      config.reset()
      bv.configure({})
    end)

    t.it("honours the operator-only trigger", function()
      bv.configure({ trigger = "operator" })
      t.ok(text_at("&", "int x = 10 & 12;"))
      t.is_nil(text_at("12", "int x = 10 & 12;"))
      config.reset()
      bv.configure({})
    end)

    t.it("honours max_nodes", function()
      bv.configure({ max_nodes = 3 })
      -- Not on an operator, so the whole chain is selected: 7 IR nodes.
      local lines, why = text_at("8;", "int x = 1 & 2 & 4 & 8;")
      t.is_nil(lines)
      t.contains(why, "too complex")
      config.reset()
      bv.configure({})
    end)

    t.it("honours max_line_length", function()
      bv.configure({ max_line_length = 5 })
      local lines, why = text_at("&", "int x = 10 & 12;")
      t.is_nil(lines)
      t.contains(why, "line too long")
      config.reset()
      bv.configure({})
    end)

    t.it("rejects an invalid width", function()
      local before = config.get().width
      config.setup({ width = 7 })
      t.eq(before, config.get().width, "invalid configuration is not applied")
      config.reset()
    end)

    t.it("skips disabled filetypes", function()
      local lines, why = text_at("&", "10 & 12", "markdown")
      t.is_nil(lines)
      t.ok(why)
    end)
  end)

  t.describe("enable / disable", function()
    t.it("toggles", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.enable()
      t.eq(true, bv.is_enabled())
      t.eq(1, #renderer.extmarks(0))

      t.eq(false, bv.toggle())
      t.eq(false, bv.is_enabled())
      t.eq(0, #renderer.extmarks(0), "disabling removes decorations")

      t.eq(true, bv.toggle())
      t.eq(1, #renderer.extmarks(0))
    end)

    t.it("hides on request without disabling", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.show()
      bv.hide()
      t.eq(0, #renderer.extmarks(0))
      t.eq(true, bv.is_enabled())
    end)

    t.it("still shows on demand while disabled", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      bv.disable()
      t.eq(true, bv.show())
      bv.enable()
    end)

    t.it("enable() turns auto back on even if it was configured off", function()
      config.setup({ auto = false })
      h.buffer("c", { "int x = 10 & 12;", "int y = 3 & 4;" })
      h.cursor_on("&", 1)

      bv.enable()
      t.eq(true, config.get().auto, "enable() must force auto = true")
      t.eq(1, #renderer.extmarks(0))

      -- With auto back on, moving to another expression must redraw without
      -- an explicit show() call.
      h.cursor_on("&", 2)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
      vim.wait(200)
      t.contains(table.concat(bv.render_text() or {}, "\n"), "0000 0000")

      config.reset()
    end)

    t.it("disable() turns auto back off so the two flags never disagree", function()
      config.setup({ auto = true })
      bv.disable()
      t.eq(false, config.get().enabled)
      t.eq(false, config.get().auto)
      config.reset()
    end)
  end)

  t.describe("commands", function()
    local expected = {
      "BitwiseVisualizerEnable",
      "BitwiseVisualizerDisable",
      "BitwiseVisualizerToggle",
      "BitwiseVisualizerShow",
      "BitwiseVisualizerHide",
      "BitwiseVisualizerWidth",
      "BitwiseVisualizerStatus",
      "BitwiseVisualizerReset",
    }

    t.it("are all defined", function()
      local commands = vim.api.nvim_get_commands({})
      for _, name in ipairs(expected) do
        t.ok(commands[name], "missing command: " .. name)
      end
    end)

    t.it("BitwiseVisualizerWidth changes the width", function()
      vim.cmd("BitwiseVisualizerWidth 16")
      t.eq(16, config.get().width)
      vim.cmd("BitwiseVisualizerWidth auto")
      t.eq("auto", config.get().width)
    end)

    t.it("BitwiseVisualizerToggle flips the state", function()
      local before = bv.is_enabled()
      vim.cmd("BitwiseVisualizerToggle")
      t.eq(not before, bv.is_enabled())
      vim.cmd("BitwiseVisualizerToggle")
      t.eq(before, bv.is_enabled())
    end)
  end)

  t.describe("status", function()
    t.it("reports the analysed expression", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      local status = bv.status()
      t.eq("c", status.language)
      t.eq("10 & 12", status.expression)
      t.eq("known", status.status)
      t.list_contains(status.supported_languages, "python")
    end)

    t.it("reports why nothing is shown", function()
      h.buffer("c", { "int x = 0;" })
      h.cursor_on("0")
      local status = bv.status()
      t.ok(status.reason)
      t.is_nil(status.expression)
    end)
  end)

  t.describe("performance", function()
    t.it("stays responsive in a large buffer", function()
      local lines = {}
      for i = 1, 20000 do
        lines[i] = "int v" .. i .. " = 10 & 12;"
      end
      h.buffer("c", lines)
      h.cursor_on("&", 10000)
      local start = vim.uv.hrtime()
      for _ = 1, 50 do
        bv.refresh()
      end
      local ms = (vim.uv.hrtime() - start) / 1e6
      t.ok(ms < 1000, string.format("50 refreshes took %.1fms", ms))
      t.eq(1, #renderer.extmarks(0))
    end)

    t.it("caches repeated analysis of the same expression", function()
      h.buffer("c", { "int x = 10 & 12;" })
      h.cursor_on("&")
      local first = bv.analyze()
      local second = bv.analyze()
      t.eq(first, second, "the same result table must be reused")
    end)

    t.it("invalidates the cache when the filetype changes", function()
      if not h.has_parser("python") then
        return
      end
      local buf = h.buffer("c", { "x = 1 << 40" })
      h.cursor_on("<<")
      local c_out = table.concat(bv.render_text() or {}, "\n")
      t.contains(c_out, "undefined behaviour", "C shifts of 40 are undefined at 32 bits")
      vim.bo[buf].filetype = "python"
      pcall(vim.treesitter.start, buf, "python")
      h.cursor_on("<<")
      local py_out = table.concat(bv.render_text() or {}, "\n")
      t.contains(py_out, "1099511627776", "Python semantics must replace the cached C result")
    end)
  end)
end)
