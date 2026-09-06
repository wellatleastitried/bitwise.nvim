--- Helpers for the Neovim-side suites.

local M = {}

--- Is a Tree-sitter parser available for `lang`?
---@param lang string
---@return boolean
function M.has_parser(lang)
  local ok = pcall(vim.treesitter.language.add, lang)
  if not ok then
    return false
  end
  return #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".*", false) > 0
end

--- Create a scratch buffer, make it current and place the cursor.
---@param filetype string
---@param lines string[]
---@return integer bufnr
function M.buffer(filetype, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = ""
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].filetype = filetype
  vim.api.nvim_set_current_buf(bufnr)
  pcall(vim.treesitter.start, bufnr, vim.treesitter.language.get_lang(filetype) or filetype)
  return bufnr
end

--- Put the cursor on the first occurrence of `needle` in line `row` (1-based).
---@param needle string
---@param row integer|nil
function M.cursor_on(needle, row)
  row = row or 1
  local line = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or ""
  local col = line:find(needle, 1, true)
  assert(col, "needle not found in line: " .. needle)
  vim.api.nvim_win_set_cursor(0, { row, col - 1 })
  return row - 1, col - 1
end

return M
