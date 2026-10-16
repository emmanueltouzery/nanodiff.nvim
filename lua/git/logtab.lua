local filetree = require('core.filetree')
local bufdata = require('core.bufdata')
local log_filter = require('core.log_filter')
local io_helpers = require('core.io_helpers')
local difflayout = require('core.difflayout')
local tabcommon = require('git.tabcommon')
local async = vim.async

local M = {}

local function format_commit_summary(commit, has_selection)
  local file_count = #commit.files
  local total_added = 0
  local total_deleted = 0

  for _, file in ipairs(commit.files) do
    total_added = total_added + (tonumber(file.added) or 0)
    total_deleted = total_deleted + (tonumber(file.deleted) or 0)
  end

  local files_str = string.format("M %d %s", file_count, file_count == 1 and "file" or "files")

  local refs_str = ""
  -- for git stash, prefer ref_log (%gd -> "stash@{0}") over ref_names (%D -> "refs/stash")
  -- for git log, ref_log will be ""
  if commit.ref_log and commit.ref_log ~= "" then
    refs_str = string.format(" %s", commit.ref_log)
  elseif commit.ref_names and commit.ref_names ~= "" then
    refs_str = string.format(" (%s)", commit.ref_names)
  end

  local short_hash = commit.hash:sub(1, 8)

  local added_str = tostring(total_added)
  local added_pad = string.rep(" ", math.max(0, 5 - #added_str))

  local deleted_str = tostring(total_deleted)
  local deleted_pad = string.rep(" ", math.max(0, 5 - #deleted_str))

  -- %-10s -> Left-aligned string (10 chars wide)
  return {
    {string.format("%-10s", files_str), "DiffviewFilePanelCounter"},
    {" | ", "DiffviewNonText"},
    {added_pad, nil},
    {added_str, "DiffviewFilePanelInsertions"},
    {deleted_pad, nil},
    {deleted_str, "DiffviewFilePanelDeletions"},
    {"| ", "DiffviewNonText"},
    {short_hash, "DiffviewHash"},
    {refs_str, "DiffviewReference"},
    {" " .. commit.subject, has_selection and "DiffviewFilePanelSelected" or nil},
    {" " .. commit.author_name, "DiffviewFilePanelPath"},
    {", " .. commit.date,  "DiffviewFilePanelPath"},
  }
end

local function load_entry(ft, ft_st, bottom_buf, git_root, commit, item, skip_refresh_bottom_buf)
  local bottom_buf_data = bufdata.get_data(bottom_buf)
  filetree.set_selected_item(ft_st, commit, item)
  bottom_buf_data.selected_item = {section = commit.hash, path = item.path}
  tabcommon.win_load_buf(git_root, bottom_buf_data.diff1_win, item.path, item.left_sha or commit.hash .. "^")
  tabcommon.win_load_buf(git_root, bottom_buf_data.diff2_win, item.path, item.right_sha or commit.hash)
  if not skip_refresh_bottom_buf then
    filetree.redisplay(bottom_buf_data.ft, bottom_buf_data.ft_st, true)
  end
end

local function get_header(bottom_buf, log)
  local bottom_buf_data = bufdata.get_data(bottom_buf)
  return {
    { {"Options: ", "DiffviewFilePanelPath"}, {"g!", "DiffviewFilePanelCounter"} },
    {},
    { {bottom_buf_data.title .. " ", "DiffviewFilePanelTitle"}, {string.format("(%d)", #log), "DiffviewFilePanelCounter"} },
  }
end

function M.open_log_tab(title, log, git_root, cmd_fn, opts)
  vim.cmd("tabnew")
  local bottom_buf = vim.api.nvim_win_get_buf(0)
  local bottom_win = vim.api.nvim_get_current_win()

  local bottom_buf_data = bufdata.get_data(bottom_buf)
  bottom_buf_data.bottom_win = bottom_win
  bottom_buf_data.title = title

  bottom_buf_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.hash end,
    section_get_items = function(s) return s.files end,
    get_header = function() return get_header(bottom_buf, log) end,
    render_item = tabcommon.tree_render_item,
    render_section = format_commit_summary,
    item_activated = function(ft, ft_st, section, item, skip_refresh_bottom_buf)
      load_entry(ft, ft_st, bottom_buf, git_root, section or {}, item or {left_hash = "nil", right_hash = "nil"}, skip_refresh_bottom_buf)
    end,
    expand_default = false,
  })
  bottom_buf_data.ft_st = filetree.create_ft_st({
    bufnr = bottom_buf,
    winnr = bottom_win,
  })

  difflayout.setup_log_tab_layout(bottom_buf, opts)

  filetree.set_contents(bottom_buf_data.ft, bottom_buf_data.ft_st, log)

  vim.api.nvim_set_current_win(bottom_win)

  vim.api.nvim_buf_set_name(bottom_buf, "Nanodiff Log")

  if opts.shortcuts.activate then
    vim.keymap.set('n', opts.shortcuts.activate, function()
      filetree.handle_enter(bufdata.get_data(bottom_buf).ft, bufdata.get_data(bottom_buf).ft_st)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.yank_commit then
    vim.keymap.set('n', opts.shortcuts.yank_commit, function()
      local section, item = filetree.get_cur_section_item(bottom_buf)
      local hash = section.hash
      vim.fn.setreg("+", hash)
      vim.notify("Copied '" .. hash .. "' to the clipboard", vim.log.levels.INFO, {source = "nanodiff"})
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.filters then
    vim.keymap.set('n', opts.shortcuts.filters, function()
      local log_filter_options = {
        { "=a", "Search authors", "--author=" },
        { "=g", "Search commit message", "--grep=" },
        { "=G", "Search changes", "-G" },
        { "=B", "Before date", "--before=" },
        { "=A", "After date", "--after=" },
      }
      log_filter.open_filtering_modal(bottom_buf, options, function()
        io_helpers.async_progress("Refreshing log", function()
          local git_log = cmd_fn(git_root, vim.tbl_values(bottom_buf_data.search_settings))
          vim.schedule(function()
            local bufdata = bufdata.get_data(bottom_buf)
            filetree.set_contents(bufdata.ft, bufdata.ft_st, git_log)
          end)
        end)
      end)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.scroll_backward then
    vim.keymap.set('n', opts.shortcuts.scroll_backward, function()
      vim.api.nvim_win_call(bufdata.get_data(bottom_buf).diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.scroll_forward then
    vim.keymap.set('n', opts.shortcuts.scroll_forward, function()
      vim.api.nvim_win_call(bufdata.get_data(bottom_buf).diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.prev_file then
    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file(bufdata.get_data(bottom_buf).ft, bufdata.get_data(bottom_buf).ft_st)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.next_file then
    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file(bufdata.get_data(bottom_buf).ft, bufdata.get_data(bottom_buf).ft_st)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end
end

return M
