--- Runs the Neovim integration suites.
---
---   nvim -l tests/run_nvim.lua
---
--- Requires the Tree-sitter parsers of the languages under test; suites for
--- missing parsers are skipped rather than failed.

vim.opt.runtimepath:prepend(vim.fn.getcwd())
package.path = table.concat({
  vim.fn.getcwd() .. "/lua/?.lua",
  vim.fn.getcwd() .. "/lua/?/init.lua",
  vim.fn.getcwd() .. "/tests/?.lua",
  package.path,
}, ";")

local t = require("harness")

require("bitwise-visualizer").setup({})

require("nvim.parser_spec")
require("nvim.resolver_spec")
require("nvim.generic_spec")
require("nvim.integration_spec")

os.exit(t.summary())
