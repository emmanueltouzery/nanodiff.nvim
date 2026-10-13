local async = vim.async

local filetree = require('core.filetree')
local difflayout = require('core.difflayout')
local tabcommon = require('tabcommon')
local bufdata = require('core.bufdata')
local conflicts = require('conflicts')
local index_watcher = require('index_watcher')

local M = {}

local function format_section_header(section, has_selection)
  return {{ " " .. section.title .. " ", "DiffviewFilePanelTitle" }, {string.format("(%d)", #section.contents), "DiffviewFilePanelCounter"} }
end

local function load_entry(ft, ft_st, left_buf, git_root, section, item, skip_refresh_left_buf)
  local left_buf_data = bufdata.get_data(left_buf)
  filetree.set_selected_item(ft_st, section, item)
  difflayout.diff_tab_layout_load_buf(left_buf_data, section, item, function(win, path, rev)
    tabcommon.win_load_buf(git_root, win, path, rev)
  end)
  tabcommon.win_load_buf(git_root, left_buf_data.diff1_win, item.path, item.left_sha or section.left_sha)
  tabcommon.win_load_buf(git_root, left_buf_data.diff2_win, item.path, item.right_sha or section.right_sha)
  if not skip_refresh_left_buf then
    filetree.redisplay(left_buf_data.ft, left_buf_data.ft_st, true)
  end
end

function M.open_diff_tab(sections, git_root, reload_index, opts)
  vim.cmd("tabnew")

  local left_buf = vim.api.nvim_win_get_buf(0)
  local left_buf_data = bufdata.get_data(left_buf)

  local left_win = vim.api.nvim_get_current_win()
  left_buf_data.left_win = left_win

  left_buf_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.title end,
    section_get_items = function(s) return s.contents end,
    get_header = function() return {} end, -- TODO
    render_item = function(prefix, item, is_selected)
      return tabcommon.tree_render_item(prefix, item, is_selected, left_buf_data.conflicts_state)
    end,
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
    conflicts.register_watchers(conflicts_section, left_buf_data.conflicts_state, function()
      filetree.redisplay(left_buf_data.ft, left_buf_data.ft_st, false)
    end)
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

  difflayout.diff_tab_layout_init(left_buf)

  vim.api.nvim_set_current_win(left_win)

  filetree.set_contents(left_buf_data.ft, left_buf_data.ft_st, sections)

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
