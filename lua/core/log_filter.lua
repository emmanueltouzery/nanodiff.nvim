local filetree = require('core.filetree')
local tabdata = require('core.tabdata')

local M = {}

local function refresh_modal(tab_data, bufnr, options)
  local lines = {
    { { "Options", "DiffviewFilePanelTitle"}, },
  }
  for _, opt in ipairs(options) do
    local opt_val = { opt[3], "DiffviewDim1" }
    local opt_raw = tab_data.search_settings[opt[1]] 
    if opt_raw then
      opt_val = { opt[3] .. opt_raw, "DiffviewFilePanelCounter" }
    end
    table.insert(lines, {
      { " " .. opt[1] .. " ", "DiffviewSecondary" }, { opt[2], "DiffviewFilePanelFileName" }, { " (", nil }, opt_val, { ")", nil},
    })
  end

  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  filetree.render_lines(bufnr, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  return #lines
end

function M.open_filtering_modal(options, refresh_bottom_buf)
  local tab_data = tabdata.get_data()
  if tab_data.search_settings == nil then
    tab_data.search_settings = {}
  end
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"

  local win_height = refresh_modal(tab_data, bufnr, options)

  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false

  for _, opt in ipairs(options) do
    vim.keymap.set('n', opt[1], function()
      vim.ui.input({ prompt = opt[2], scope = 'window' }, function(v)
        if v == nil then return end
        local tab_data = tabdata.get_data()
        if v == "" then
          tab_data.search_settings[opt[1]] = nil
        else
          tab_data.search_settings[opt[1]] = opt[3] .. v
        end
        refresh_modal(tab_data, bufnr, options)
      end)
    end, { noremap = true, silent = true, buffer = bufnr })
  end

  local width = vim.api.nvim_get_option("columns")
  local height = vim.api.nvim_get_option("lines") - vim.o.cmdheight - 1

  local opts = {
    style = "minimal",
    border = "rounded",
    relative = "editor",
    row = (height - win_height) / 2,
    col = (width - 100) / 2,
    width = 100,
    height = win_height,
  }
  local w = vim.api.nvim_open_win(bufnr, true, opts)
  -- Adds a 1-character left margin inside the buffer area
  vim.wo[w].foldcolumn = "1"
  vim.api.nvim_win_call(w, function()
    vim.keymap.set({'n', 'v'}, 'q', function() vim.api.nvim_win_close(w, false) end, {buf = bufnr})
  end)

  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(w),
    once = true,
    callback = function()
      refresh_bottom_buf(tab_data)
    end,
  })
end

return M
