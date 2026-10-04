local filetree = require('filetree')
local tabcommon = require('tabcommon')
local bufdata = require('bufdata')

local M = {}

local function format_commit_summary(commit)
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
    {" " .. commit.subject, "DiffviewFilePanelSelected"},
    {" " .. commit.author_name, "DiffviewFilePanelPath"},
    {", " .. commit.relative_date,  "DiffviewFilePanelPath"},
  }
end

local function refresh_bottom_buf(bottom_buf)
  local lines = {}
  local bottom_buf_data = bufdata.get_data(bottom_buf)
  bottom_buf_data.line_to_item = {}
  for _, commit in ipairs(bottom_buf_data.log) do
    local selected_path = nil
    if bottom_buf_data.selected_item ~= nil and bottom_buf_data.selected_item.commit == commit.hash then
      selected_path = bottom_buf_data.selected_item.path
    end
    filetree.add_section(nil, commit,
      lines, bottom_buf_data.line_to_item,
      format_commit_summary(commit), commit.files, selected_path, bottom_buf_data.tree_expand_st[commit.hash]
    )
  end
  vim.bo[bottom_buf].modifiable = true
  vim.bo[bottom_buf].readonly = false
  filetree.render_lines(bottom_buf, lines)
  vim.bo[bottom_buf].modifiable = false
  vim.bo[bottom_buf].readonly = true
end

local function load_entry(bottom_buf, git_root, commit, item)
  local bottom_buf_data = bufdata.get_data(bottom_buf)
  bottom_buf_data.selected_item = {commit = commit.hash, path = item.path}
  tabcommon.win_load_buf(git_root, bottom_buf_data.diff1_win, item.path, commit.hash .. "^")
  tabcommon.win_load_buf(git_root, bottom_buf_data.diff2_win, item.path, commit.hash)
  refresh_bottom_buf(bottom_buf)
end

local function bottom_buf_handle_enter(git_root, bufnr)
  filetree.handle_enter("hash", false, git_root, bufnr, refresh_bottom_buf, load_entry)
end

function M.open_log_tab(log, git_root)
  vim.cmd("tabnew")
  local bottom_buf = vim.api.nvim_win_get_buf(0)

  vim.wo.spell = false

  vim.bo[bottom_buf].buftype = "nofile"
  vim.bo[bottom_buf].bufhidden = "wipe"
  vim.bo[bottom_buf].swapfile = false

  local bottom_buf_data = bufdata.get_data(bottom_buf)
  bottom_buf_data.log = log
  bottom_buf_data.tree_expand_st = {}

  if #log > 0 then
    bottom_buf_data.tree_expand_st[log[1].hash] = {section_expanded = true}
  end

  refresh_bottom_buf(bottom_buf)
  local bottom_win = vim.api.nvim_get_current_win()

  -- Open a new window above the current one
  local diff1_win = vim.api.nvim_open_win(0, true, {
    split = 'above',
    win = current_win,
  })

  -- Split that new window vertically to create the top-right window
  local diff2_win = vim.api.nvim_open_win(0, true, {
    split = 'right',
    win = top_left_win,
  })

  vim.api.nvim_win_set_height(bottom_win, 15)
  -- Lock the height against <C-W>= balancing
  vim.wo[bottom_win].winfixheight = true

  bottom_buf_data.diff1_win = diff1_win
  bottom_buf_data.diff2_win = diff2_win

  -- Configure bottom window options (including winfixbuf)
  vim.wo[bottom_win].winfixbuf = true -- Lock window to this buffer
  vim.wo[bottom_win].number = false
  vim.wo[bottom_win].relativenumber = false
  vim.wo[bottom_win].signcolumn = "no"
  vim.wo[bottom_win].wrap = false

  -- display the first entry immediately
  if #log > 0 then
    -- due to sorting in the treeview (including sorting folders first), the first path
    -- in the section may not be the first in the treeview, so use line_to_path to
    -- find the first displayed path
    local lowest_idx_line_to_path
    local l2p = bottom_buf_data.line_to_item
    for i = 1, vim.api.nvim_buf_line_count(bottom_buf) do
      if l2p[i] and l2p[i] ~= nil and l2p[i].type == "path" then
        lowest_idx_line_to_path = i
        break
      end
    end
    load_entry(bottom_buf, git_root, log[1], bottom_buf_data.line_to_item[lowest_idx_line_to_path])
  end

  vim.keymap.set('n', '<CR>', function() bottom_buf_handle_enter(git_root, bottom_buf) end, {
    noremap = true,
    silent = true,
    buffer = bottom_buf
  })

end

return M
