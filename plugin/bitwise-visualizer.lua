-- bitwise-visualizer.nvim
--
-- Plugin entry point. Everything works with the shipped defaults, so calling
-- `require("bitwise-visualizer").setup()` is optional.

if vim.g.loaded_bitwise_visualizer then
  return
end
vim.g.loaded_bitwise_visualizer = true

if vim.fn.has("nvim-0.10") ~= 1 then
  vim.notify("[bitwise-visualizer] requires Neovim 0.10 or newer", vim.log.levels.WARN)
  return
end

require("bitwise-visualizer").setup(vim.g.bitwise_visualizer or {})
