-- i'd use tabfer-local variables, vim.b, but there is a perf cost,
-- you can't write all data types, and you get vim.NIL instead of nil
local M = {}
local state = {} -- Map of tabnr -> Lua table

function M.get_data(tabnr)
  local tabnr = tabnr or vim.api.nvim_get_current_tabpage()
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

function M.add_tab_enter_leave(enter_fn, leave_fn)
  local tabnr = vim.api.nvim_get_current_tabpage()
  if enter_fn then
    state[tabnr].__tabenters = state[tabnr].__tabenters or {}
    table.insert(state[tabnr].__tabenters, enter_fn)
    -- immediately run the enter_fn
    enter_fn()
  end
  if leave_fn then
    state[tabnr].__tableaves = state[tabnr].__tableaves or {}
    table.insert(state[tabnr].__tableaves, leave_fn)
  end
end

local function invoke_tab_leave(leave_tab_id)
  for _, leave_fn in ipairs((state[leave_tab_id] or {}).__tableaves or {}) do
    leave_fn()
  end
end

-- will be called multiple times during normal operation,
-- should be idempotent
function M.init()
  vim.api.nvim_create_autocmd("TabClosedPre", {
    group = vim.api.nvim_create_augroup("NanodiffStateCleanup", { clear = true }),
    callback = function(args)
      local closing_tab_id = vim.api.nvim_get_current_tabpage()
      for _, cleanup_fn in ipairs((state[closing_tab_id] or {}).__cleanups or {}) do
        cleanup_fn()
      end
      invoke_tab_leave(closing_tab_id)
      state[closing_tab_id] = nil
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = vim.api.nvim_create_augroup("NanodiffTabEntry", { clear = true }),
    callback = function(args)
      local entering_tab_id = vim.api.nvim_get_current_tabpage()
      for _, enter_fn in ipairs((state[entering_tab_id] or {}).__tabenters or {}) do
        enter_fn()
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabLeave", {
    group = vim.api.nvim_create_augroup("NanodiffTabLeave", { clear = true }),
    callback = function(args)
      local leave_tab_id = vim.api.nvim_get_current_tabpage()
      invoke_tab_leave(leave_tab_id)
    end,
  })
end

return M
