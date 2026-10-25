local filetree = require('core.filetree')
local tabdata = require('core.tabdata')
local log_filter = require('core.log_filter')
local io_helpers = require('core.io_helpers')
local difflayout = require('core.difflayout')
local tabcommon = require('git.tabcommon')
local actions = require('git.actions')
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
  local tab_data = tabdata.get_data()
  filetree.set_selected_item(ft_st, commit, item)
  tab_data.selected_item = {section = commit.hash, path = item.path}
  tabcommon.win_load_buf(git_root, tab_data.diff1_win, item.path, item.left_sha or commit.hash .. "^")
  tabcommon.win_load_buf(git_root, tab_data.diff2_win, item.path, item.right_sha or commit.hash)
  if not skip_refresh_bottom_buf then
    filetree.redisplay(tab_data.ft, tab_data.ft_st, true)
  end
  -- activate diff mode only when all windows are ready
  local relevant_windows = {tab_data.diff1_win, tab_data.diff2_win}
  difflayout.wait_for_windows_ready(relevant_windows, function()
    for _, winnr in ipairs(relevant_windows) do
      difflayout.win_set_diff(winnr)
    end
  end)
end

local function get_header()
  local tab_data = tabdata.get_data()
  local first_row = { {"Options: ", "DiffviewFilePanelPath"}, {"g!", "DiffviewFilePanelCounter"} }
  for k, v in pairs(tab_data.search_settings or {}) do
    table.insert(first_row, { " " .. v, "DiffviewSecondary" })
  end
  local title_row = {}
  if type(tab_data.title) == "table" then
    vim.list_extend(title_row, tab_data.title)
  else
    table.insert(title_row, {tab_data.title .. " ", "DiffviewFilePanelTitle"})
  end
  table.insert(title_row, {string.format("(%d)", tab_data.log_count), "DiffviewFilePanelCounter"})
  return {
    first_row,
    {},
    title_row
  }
end

function M.open_log_tab(title, log, git_root, cmd_fn, opts)
  vim.cmd("tabnew")
  local bottom_buf = vim.api.nvim_win_get_buf(0)
  local bottom_win = vim.api.nvim_get_current_win()

  local tab_data = tabdata.get_data()
  tab_data.log_count = #log
  tab_data.reload_log = function() -- API, can be used by external callers and actions
    local log = cmd_fn()
    tab_data.log_count = #log
    return log
  end
  tab_data.git_root = git_root -- we don't really need this, but it's handy for API users
  tab_data.bottom_win = bottom_win
  tab_data.title = title

  tab_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.hash end,
    section_get_items = function(s) return s.files end,
    get_header = get_header,
    render_item = tabcommon.tree_render_item,
    render_section = format_commit_summary,
    item_activated = function(ft, ft_st, section, item, skip_refresh_bottom_buf)
      load_entry(ft, ft_st, bottom_buf, git_root, section or {}, item or {left_hash = "nil", right_hash = "nil"}, skip_refresh_bottom_buf)
    end,
    expand_default = false,
  })
  tab_data.ft_st = filetree.create_ft_st({
    bufnr = bottom_buf,
    winnr = bottom_win,
  })

  difflayout.setup_log_tab_layout(bottom_buf, opts)

  filetree.set_contents(tab_data.ft, tab_data.ft_st, log)

  vim.api.nvim_set_current_win(bottom_win)

  vim.api.nvim_buf_set_name(bottom_buf, "Nanodiff Log")

  vim.bo[bottom_buf].filetype = "NanodiffLogPanel"

  if opts.shortcuts.activate then
    vim.keymap.set('n', opts.shortcuts.activate, function()
      filetree.handle_enter(tabdata.get_data().ft, tabdata.get_data().ft_st)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.yank_commit then
    vim.keymap.set('n', opts.shortcuts.yank_commit, function()
      local section, item = filetree.get_cur_section_item(tabdata.get_data().ft_st)
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
      log_filter.open_filtering_modal(log_filter_options, function()
        io_helpers.async_progress("Refreshing log", function()
          local git_log = cmd_fn(git_root, vim.tbl_values(tab_data.search_settings))
          vim.schedule(function()
            local tab_data = tabdata.get_data()
            tab_data.ft_st.selected_item = nil -- reset selected_item
            filetree.set_contents(tab_data.ft, tab_data.ft_st, git_log)
          end)
        end)
      end)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.close_tab then
    vim.keymap.set(
      'n', opts.shortcuts.close_tab, function() vim.cmd.tabclose() end,
      { noremap = true, silent = true, buffer = left_buf }
    )
  end

  if opts.shortcuts.scroll_backward then
    vim.keymap.set('n', opts.shortcuts.scroll_backward, function()
      vim.api.nvim_win_call(tabdata.get_data().diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.scroll_forward then
    vim.keymap.set('n', opts.shortcuts.scroll_forward, function()
      vim.api.nvim_win_call(tabdata.get_data().diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.prev_file then
    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.next_file then
    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.unstash then
    vim.keymap.set('n', opts.shortcuts.unstash, function()
      actions.unstash()
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end

  if opts.shortcuts.drop_stash then
    vim.keymap.set('n', opts.shortcuts.drop_stash, function()
      actions.drop_stash()
    end, { noremap = true, silent = true, buffer = bottom_buf })
  end
end

return M
