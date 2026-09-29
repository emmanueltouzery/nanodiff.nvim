-- i'd use buffer-local variables, vim.b, but there is a perf cost,
-- you can't write all data types, and you get vim.NIL instead of nil
local M = {}
local state = {} -- Map of bufnr -> Lua table

function M.get_data(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not state[bufnr] then
    state[bufnr] = {}
  end
  return state[bufnr]
end

vim.api.nvim_create_autocmd("BufWipeout", {
  group = vim.api.nvim_create_augroup("MyPluginStateCleanup", { clear = true }),
  callback = function(args)
    state[args.buf] = nil
  end,
})

return M
