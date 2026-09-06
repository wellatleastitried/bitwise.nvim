--- Runs the Neovim-independent test suites.
---
---   lua tests/run_core.lua        (or: nvim -l tests/run_core.lua)

package.path = table.concat({
  "./lua/?.lua",
  "./lua/?/init.lua",
  "./tests/?.lua",
  package.path,
}, ";")

local t = require("harness")

require("core.bits_spec")
require("core.literals_spec")
require("core.evaluator_spec")
require("core.formatter_spec")

os.exit(t.summary())
