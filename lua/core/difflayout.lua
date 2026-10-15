local async = vim.async
local io_helpers = require("core.io_helpers")
local bufdata = require("core.bufdata")

local M = {}

function M.win_set_diff(winnr)
  -- without scope=local any popups opening over the window will inherit the diff flag,
  -- completely breaking the diff
  vim.api.nvim_set_option_value('diff', true, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('scrollbind', true, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('foldmethod', 'diff', { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('foldlevel', 0, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('foldenable', true, { win = winnr, scope = 'local' })
end

function M.win_load_null_file(winnr)
  local bufname = "nanogit://null"
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(true, false) -- listed, not scratch
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.bo[bufnr].bufhidden = "wipe"
  end
  vim.api.nvim_win_set_buf(winnr, bufnr)
  M.win_set_diff(winnr)
end

function M.win_load_disk_file(winnr, path)
  local bufnr = vim.fn.bufadd(path) -- will reuse existing matching buffers
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    -- we know it's our buffer since it's not loaded.
    -- wouldn't want to do that on the user's buffers
    vim.bo[bufnr].bufhidden = "wipe"
  end
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_win_set_buf(winnr, bufnr)
  M.win_set_diff(winnr)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NanodiffDiskBufferLoaded",
    data = { path = path, buf = bufnr },
  })
end

-- diff layout is one window at the bottom, then the diffed windows on top
-- of it, but which may include more than two diff windows in case of conflicts
function M.diff_tab_layout_load_buf(left_buf_data, section, item, win_load_buf)
  if section.mid_sha then
    if left_buf_data.diff3_win == nil then
      -- whatever, give it any buf for now
      left_buf_data.diff3_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(left_buf_data.diff1_win), true, {
        split = "right",
        win = left_buf_data.diff1_win,
      })
    end
    if not section.bottom_sha then
      -- MESSY... if bottom_sha is present, we'll tear down and recreate this window...
      win_load_buf(left_buf_data.diff3_win, item.path, section.mid_sha)
    end
  elseif left_buf_data.diff3_win then
    vim.api.nvim_win_close(left_buf_data.diff3_win, false)
    left_buf_data.diff3_win = nil
  end
  if section.bottom_sha then
    if left_buf_data.diff4_win == nil then
      -- must close and reopen diff2 and diff3

      -- Save buffers of diff2 and diff3
      local buf2 = vim.api.nvim_win_get_buf(left_buf_data.diff2_win)
      local buf3 = vim.api.nvim_win_get_buf(left_buf_data.diff3_win)
      vim.bo[buf2].bufhidden = "hide"
      vim.bo[buf3].bufhidden = "hide"
      vim.api.nvim_win_close(left_buf_data.diff2_win, false)
      vim.api.nvim_win_close(left_buf_data.diff3_win, false)

      -- create diff4 under diff1, give it any buf for now
      left_buf_data.diff4_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(left_buf_data.diff1_win), true, {
        split = "below",
        win = left_buf_data.diff1_win,
      })

      -- recreate diff2 and diff3
      left_buf_data.diff3_win = vim.api.nvim_open_win(buf3, true, {
        split = "right",
        win = left_buf_data.diff1_win,
      })
      left_buf_data.diff2_win = vim.api.nvim_open_win(buf2, true, {
        split = "right",
        win = left_buf_data.diff3_win,
      })
      vim.bo[buf2].bufhidden = "wipe"
      vim.bo[buf3].bufhidden = "wipe"
    end
    win_load_buf(left_buf_data.diff3_win, item.path, section.mid_sha)
    win_load_buf(left_buf_data.diff4_win, item.path, section.bottom_sha)
  elseif left_buf_data.diff4_win then
    vim.api.nvim_win_close(left_buf_data.diff4_win, false)
    left_buf_data.diff4_win = nil
  end
end

function M.diff_tab_layout_init(left_buf, opts)
  local left_buf_data = bufdata.get_data(left_buf)
  local left_win = left_buf_data.left_win

  vim.wo.spell = false

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].filetype = "NanodiffFileHistory"

  -- Split to create the right window
  vim.cmd("rightbelow vsplit")
  local diff1_win = vim.api.nvim_get_current_win()

  -- Set left window width to 40 characters
  vim.api.nvim_win_set_width(left_win, opts.panel_width)
  -- Lock the width against <C-W>= balancing
  vim.wo[left_win].winfixwidth = true

  -- Get the width of the remaining available space
  local total_remaining = vim.api.nvim_win_get_width(diff1_win)

  local half_width = math.floor(total_remaining / 2)
  vim.cmd("rightbelow " .. half_width .. "vsplit")
  local diff2_win = vim.api.nvim_get_current_win()

  left_buf_data.diff1_win = diff1_win
  left_buf_data.diff2_win = diff2_win

  -- Configure left window options (including winfixbuf)
  vim.wo[left_win].winfixbuf = true -- Lock window to this buffer
  vim.wo[left_win].number = false
  vim.wo[left_win].relativenumber = false
  vim.wo[left_win].signcolumn = "no"
  vim.wo[left_win].wrap = false
end

function M.setup_log_tab_layout(bottom_buf, opts)
  local bottom_buf_data = bufdata.get_data(bottom_buf)
  local bottom_win = bottom_buf_data.bottom_win

  vim.wo.spell = false

  vim.bo[bottom_buf].buftype = "nofile"
  vim.bo[bottom_buf].bufhidden = "wipe"
  vim.bo[bottom_buf].swapfile = false
  vim.bo[bottom_buf].filetype = "NanodiffFiles"

  -- Open a new window above the current one
  bottom_buf_data.diff1_win = vim.api.nvim_open_win(0, true, {
    split = 'above',
    win = current_win,
  })

  -- Split that new window vertically to create the top-right window
  bottom_buf_data.diff2_win = vim.api.nvim_open_win(0, true, {
    split = 'right',
    win = top_left_win,
  })
  vim.api.nvim_win_resize(bottom_win, -1, opts.panel_height)

  -- Lock the height against <C-W>= balancing
  vim.wo[bottom_win].winfixheight = true

  -- Configure bottom window options (including winfixbuf)
  vim.wo[bottom_win].winfixbuf = true -- Lock window to this buffer
  vim.wo[bottom_win].number = false
  vim.wo[bottom_win].relativenumber = false
  vim.wo[bottom_win].signcolumn = "no"
  vim.wo[bottom_win].wrap = false
end

return M
