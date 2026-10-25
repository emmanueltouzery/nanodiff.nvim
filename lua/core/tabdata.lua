-- i'd use tabfer-local variables, vim.b, but there is a perf cost,
-- you can't write all data types, and you get vim.NIL instead of nil
local M = {}
local state = {} -- Map of tabnr -> Lua table

function M.get_data()
  local tabnr = vim.api.nvim_get_current_tabpage()
  if not state[tabnr] then
    state[tabnr] = {}
  end
  return state[tabnr]
end

function M.add_cleanup(cleanup_fn)
  local tabnr = vim.api.nvim_get_current_tabpage()
  state[tabnr].__cleanups = state[tabnr].__cleanups or {}
  table.insert(state[tabnr].__cleanups, cleanup_fn)
end

vim.api.nvim_create_autocmd("TabClosedPre", {
  group = vim.api.nvim_create_augroup("MyPluginStateCleanup", { clear = true }),
  callback = function(args)
    local closing_tab_id = vim.api.nvim_get_current_tabpage()
    for _, cleanup_fn in ipairs((state[closing_tab_id] or {}).__cleanups or {}) do
      cleanup_fn()
    end
    state[closing_tab_id] = nil
  end,
})

return M
