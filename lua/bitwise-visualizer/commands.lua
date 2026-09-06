--- User commands.

local M = {}

---@param name string
---@param fn fun(opts: table)
---@param opts table|nil
local function cmd(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

--- Create (or recreate) every user command.
function M.create()
  local bv = require("bitwise-visualizer")
  local config = require("bitwise-visualizer.config")

  cmd("BitwiseVisualizerEnable", function()
    bv.enable()
  end, { desc = "Enable the bitwise visualizer" })

  cmd("BitwiseVisualizerDisable", function()
    bv.disable()
  end, { desc = "Disable the bitwise visualizer" })

  cmd("BitwiseVisualizerToggle", function()
    local on = bv.toggle()
    vim.notify("[bitwise-visualizer] " .. (on and "enabled" or "disabled"), vim.log.levels.INFO)
  end, { desc = "Toggle the bitwise visualizer" })

  cmd("BitwiseVisualizerShow", function(opts)
    if opts.bang then
      local lines, why = bv.render_text()
      if not lines then
        vim.notify("[bitwise-visualizer] " .. (why or "nothing to show"), vim.log.levels.WARN)
        return
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      return
    end
    local result, why = bv.analyze()
    if not result then
      vim.notify("[bitwise-visualizer] " .. (why or "nothing to visualize"), vim.log.levels.WARN)
      return
    end
    bv.show()
  end, { bang = true, desc = "Visualize the expression under the cursor (! echoes it as text)" })

  cmd("BitwiseVisualizerHide", function()
    bv.hide()
  end, { desc = "Clear the visualization in the current buffer" })

  cmd("BitwiseVisualizerWidth", function(opts)
    local arg = vim.trim(opts.args)
    local width = arg == "auto" and "auto" or tonumber(arg)
    if width == nil then
      vim.notify("[bitwise-visualizer] usage: :BitwiseVisualizerWidth auto|8|16|32|64", vim.log.levels.ERROR)
      return
    end
    bv.configure({ width = width })
  end, {
    nargs = 1,
    desc = "Set the bit width",
    complete = function()
      return { "auto", "8", "16", "32", "64" }
    end,
  })

  cmd("BitwiseVisualizerStatus", function()
    local status = bv.status()
    vim.notify(vim.inspect(status), vim.log.levels.INFO)
  end, { desc = "Show bitwise visualizer diagnostics" })

  cmd("BitwiseVisualizerReset", function()
    config.reset()
    bv.configure({})
  end, { desc = "Restore the default configuration" })
end

return M
