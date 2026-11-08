local async = vim.async
local io_helpers = require("core.io_helpers")
local tabdata = require("core.tabdata")

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

function M.win_load_null_file(winnr, on_loaded)
  local bufname = "nanodiff://null"
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(true, false) -- listed, not scratch
    vim.api.nvim_buf_set_name(bufnr, bufname)
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].buftype = "nofile"
  end
  vim.api.nvim_win_set_buf(winnr, bufnr)
  if on_loaded then on_loaded() end
end

function M.win_load_disk_file(winnr, path, on_loaded)
  local bufnr = vim.fn.bufadd(path) -- will reuse existing matching buffers
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    -- we know it's our buffer since it's not loaded.
    -- wouldn't want to do that on the user's buffers
    vim.bo[bufnr].bufhidden = "wipe"
  end
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_win_set_buf(winnr, bufnr)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "NanodiffDiskBufferLoaded",
    data = { path = path, buf = bufnr },
  })
  if on_loaded then on_loaded() end
end

-- diff layout is one window at the bottom, then the diffed windows on top
-- of it, but which may include more than two diff windows in case of conflicts
function M.diff_tab_layout_load_buf(tab_data, section, item, opts, win_load_buf)
  local has_base_sha = section.base_sha ~= nil and opts.conflicts_display_mode == "ours_local_theirs_base"
  if section.mid_sha then
    if tab_data.diff3_win == nil then
      -- whatever, give it any buf for now
      tab_data.diff3_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(tab_data.diff1_win), true, {
        split = "right",
        win = tab_data.diff1_win,
      })
    end
    if not has_base_sha then
      -- MESSY... if base_sha is present, we'll tear down and recreate this window...
      win_load_buf(tab_data.diff3_win, item.path, section.mid_sha, section.mid_winbar)
    end
  elseif tab_data.diff3_win then
    vim.api.nvim_win_close(tab_data.diff3_win, false)
    tab_data.diff3_win = nil
  end
  if has_base_sha then
    if tab_data.diff4_win == nil then
      -- must close and reopen diff2 and diff3

      -- Save buffers of diff2 and diff3
      local buf2 = vim.api.nvim_win_get_buf(tab_data.diff2_win)
      local buf3 = vim.api.nvim_win_get_buf(tab_data.diff3_win)
      vim.bo[buf2].bufhidden = "hide"
      vim.bo[buf3].bufhidden = "hide"
      vim.api.nvim_win_close(tab_data.diff2_win, false)
      vim.api.nvim_win_close(tab_data.diff3_win, false)

      -- create diff4 under diff1, give it any buf for now
      tab_data.diff4_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(tab_data.diff1_win), true, {
        split = "below",
        win = tab_data.diff1_win,
      })

      -- recreate diff2 and diff3
      tab_data.diff3_win = vim.api.nvim_open_win(buf3, true, {
        split = "right",
        win = tab_data.diff1_win,
      })
      tab_data.diff2_win = vim.api.nvim_open_win(buf2, true, {
        split = "right",
        win = tab_data.diff3_win,
      })
      vim.bo[buf2].bufhidden = "wipe"
      vim.bo[buf3].bufhidden = "wipe"
    end
    win_load_buf(tab_data.diff3_win, item.path, section.mid_sha, section.mid_winbar)
    win_load_buf(tab_data.diff4_win, item.path, section.base_sha, section.bottom_winbar)
  elseif tab_data.diff4_win then
    vim.api.nvim_win_close(tab_data.diff4_win, false)
    tab_data.diff4_win = nil
  end

  -- after all the window churn, make sure the left window is focused
  vim.api.nvim_set_current_win(tab_data.left_win)
end

function M.set_win_options(win)
  vim.wo[win].winfixbuf = true -- Lock window to this buffer
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].wrap = false
  vim.wo[win].spell = false
end

function M.set_buf_options(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
end

function M.diff_tab_layout_init(left_buf, opts)
  local tab_data = tabdata.get_data()
  local left_win = tab_data.left_win

  M.set_buf_options(left_buf)

  -- Split to create the right window
  vim.cmd("rightbelow vsplit")
  vim.cmd("wincmd L") -- if we have two vertical panes on the left, move fully to the right
  local diff1_win = vim.api.nvim_get_current_win()

  -- Set left window width
  vim.api.nvim_win_set_width(left_win, opts.panel_width())
  -- Lock the width against <C-W>= balancing
  vim.wo[left_win].winfixwidth = true

  -- Get the width of the remaining available space
  local total_remaining = vim.api.nvim_win_get_width(diff1_win)

  local half_width = math.floor(total_remaining / 2)
  vim.cmd("rightbelow " .. half_width .. "vsplit")
  local diff2_win = vim.api.nvim_get_current_win()

  tab_data.diff1_win = diff1_win
  tab_data.diff2_win = diff2_win

  M.set_win_options(left_win)
end

-- I have seen diff "corruption", the diff being incorrect, if
-- loading windows one by one and enabling diff mode for them
-- as they are loaded (so the windows configuration keeps changing
-- after enabling diff mode for multiple windows in the tab).
--
-- This went away when I started enabling diff mode only after
-- the window configuration/window buffer mapping was stable.
-- => every window load registers itself with `add()` and calls the
-- returned callback once its buffer is in place. `wait()` runs its
-- callback when all the registered loads are done.
-- Starting a new barrier for a tab invalidates the previous one, so that
-- if the user moves quickly between files, a stale load doesn't trigger.
function M.windows_ready_barrier(tab_data)
  tab_data.load_generation = (tab_data.load_generation or 0) + 1
  local generation = tab_data.load_generation
  local pending = 0
  local all_windows = {}
  local on_all_ready = nil

  local function check()
    if pending == 0 and on_all_ready and tab_data.load_generation == generation then
      local cb = on_all_ready
      on_all_ready = nil
      cb(all_windows)
    end
  end

  return {
    add = function(winnr)
      pending = pending + 1
      table.insert(all_windows, winnr)
      local done = false
      return function()
        if not done then
          done = true
          pending = pending - 1
          check()
        end
      end
    end,
    wait = function(cb)
      on_all_ready = cb
      check()
    end,
  }
end

return M
