local async = vim.async

local filetree = require('filetree')
local tabcommon = require('tabcommon')
local bufdata = require('bufdata')
local conflicts = require('conflicts')
local index_watcher = require('index_watcher')

local M = {}

local function format_section_header(section, has_selection)
  return {{ " " .. section.title .. " ", "DiffviewFilePanelTitle" }, {string.format("(%d)", #section.contents), "DiffviewFilePanelCounter"} }
end

local function load_entry(ft, ft_st, left_buf, git_root, section, item, skip_refresh_left_buf)
  local left_buf_data = bufdata.get_data(left_buf)
  filetree.set_selected_item(ft_st, section, item)
  if section.mid_sha then
    if left_buf_data.diff3_win == nil then
      -- whatever, give it any buf for now
      left_buf_data.diff3_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(left_buf_data.diff1_win), true, {
        split = "right",
        win = left_buf_data.diff1_win,
      })
    end
    tabcommon.win_load_buf(git_root, left_buf_data.diff3_win, item.path, section.mid_sha)
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
    tabcommon.win_load_buf(git_root, left_buf_data.diff3_win, item.path, section.mid_sha)
    tabcommon.win_load_buf(git_root, left_buf_data.diff4_win, item.path, section.bottom_sha)
  elseif left_buf_data.diff4_win then
    vim.api.nvim_win_close(left_buf_data.diff4_win, false)
    left_buf_data.diff4_win = nil
  end
  tabcommon.win_load_buf(git_root, left_buf_data.diff1_win, item.path, item.left_sha or section.left_sha)
  tabcommon.win_load_buf(git_root, left_buf_data.diff2_win, item.path, item.right_sha or section.right_sha)
  if not skip_refresh_left_buf then
    filetree.redisplay(left_buf_data.ft, left_buf_data.ft_st, true)
  end
end

function M.open_diff_tab(sections, git_root, reload_index, opts)
  vim.cmd("tabnew")

  vim.wo.spell = false

  local left_buf = vim.api.nvim_win_get_buf(0)
  local left_buf_data = bufdata.get_data(left_buf)

  local left_win = vim.api.nvim_get_current_win()
  left_buf_data.left_win = left_win

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].filetype = "NanodiffFileHistory"

  left_buf_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.title end,
    section_get_items = function(s) return s.contents end,
    get_header = function() return {} end, -- TODO
    render_item = tabcommon.tree_render_item,
    render_section = format_section_header,
    item_activated = function(ft, ft_st, section, item, skip_refresh_left_buf)
      load_entry(ft, ft_st, left_buf, git_root, section or {}, item or {left_hash = "nil", right_hash = "nil"}, skip_refresh_left_buf)
    end,
    expand_default = true,
  })
  left_buf_data.ft_st = filetree.create_ft_st({
    bufnr = left_buf,
    winnr = left_win,
  })

  local conflicts_section = sections[1]
  if sections[1].title == "Conflicts" then
    left_buf_data.conflicts_state = {conflicts = {}}
    conflicts.register_watchers(conflicts_section, left_buf_data.conflicts_state, function() refresh_left_buf(left_buf) end)
  end

  if reload_index then
    index_watcher.setup_index_watch(git_root, left_buf, function()
      async.run(function()
        local sections = reload_index(git_root)
        vim.schedule(function()
          left_buf_data.sections = sections
          refresh_left_buf(left_buf)
        end)
      end):raise_on_error()
    end)
  end

  -- Split to create the right window
  vim.cmd("rightbelow vsplit")
  local diff1_win = vim.api.nvim_get_current_win()

  -- Set left window width to 40 characters
  vim.api.nvim_win_set_width(left_win, 40)
  -- Lock the width against <C-W>= balancing
  vim.wo[left_win].winfixwidth = true

  -- Get the width of the remaining available space
  local total_remaining = vim.api.nvim_win_get_width(diff1_win)

  local half_width = math.floor(total_remaining / 2)
  vim.cmd("rightbelow " .. half_width .. "vsplit")
  local diff2_win = vim.api.nvim_get_current_win()

  left_buf_data.diff1_win = diff1_win
  left_buf_data.diff2_win = diff2_win

  filetree.set_contents(left_buf_data.ft, left_buf_data.ft_st, sections)

  -- Configure left window options (including winfixbuf)
  vim.wo[left_win].winfixbuf = true -- Lock window to this buffer
  vim.wo[left_win].number = false
  vim.wo[left_win].relativenumber = false
  vim.wo[left_win].signcolumn = "no"
  vim.wo[left_win].wrap = false

  vim.api.nvim_set_current_win(left_win)

  vim.api.nvim_buf_set_name(left_buf, "Nanodiff Diff")

  vim.keymap.set('n', '<CR>', function()
    filetree.handle_enter(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
  end, { noremap = true, silent = true, buffer = left_buf })

  if opts.shortcuts.fwd then
    vim.keymap.set('n', opts.shortcuts.bwd, function()
      vim.api.nvim_win_call(diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })

    vim.keymap.set('n', opts.shortcuts.fwd, function()
      vim.api.nvim_win_call(diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })

    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })

    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  return left_buf
end

return M
