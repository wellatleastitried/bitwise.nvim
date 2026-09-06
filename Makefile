LUA ?= lua
NVIM ?= nvim

.PHONY: test test-core test-nvim lint format

test: test-core test-nvim

## Pure-Lua evaluator/formatter tests (no Neovim required)
test-core:
	@$(LUA) tests/run_core.lua

## Tree-sitter, extmark and command tests (headless Neovim)
test-nvim:
	@$(NVIM) -l tests/run_nvim.lua

lint:
	@command -v luacheck >/dev/null && luacheck lua tests || echo "luacheck not installed, skipping"

format:
	@command -v stylua >/dev/null && stylua lua tests plugin || echo "stylua not installed, skipping"
