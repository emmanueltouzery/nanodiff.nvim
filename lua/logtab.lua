local filetree = require('filetree')
local tabcommon = require('tabcommon')

local M = {}

local function format_commit_summary(commit)
  local file_count = #commit.stat
  local total_added = 0
  local total_deleted = 0

  for _, file in ipairs(commit.stat) do
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

  -- %-10s -> Left-aligned string (10 chars wide)
  -- %5d   -> Right-aligned integer (5 chars wide)
  return string.format(
    "%-10s | %5d     %5d | %s%s %s %s, %s",
    files_str,
    total_added,
    total_deleted,
    short_hash,
    refs_str,
    commit.subject,
    commit.author_name,
    commit.relative_date
  )
end

local function load_entry(git_root, commit, path)
  tabcommon.win_load_buf(git_root, vim.b.diff1_win, path, commit.hash .. "^")
  tabcommon.win_load_buf(git_root, vim.b.diff2_win, path, commit.hash)
end

local function bottom_buf_handle_enter(git_root, bufnr)
  local line = vim.fn.line('.') + 1

  local commit_line = line
  local commit
  while commit_line > 0 do
    commit = vim.b[bufnr].line_to_commit[commit_line] 
    if commit ~= vim.NIL and commit ~= nil then
      break
    end
    commit_line = commit_line - 1
  end

  local path = vim.b[bufnr].line_to_path[line] 

  if path ~= vim.NIL and path ~= nil then
    load_entry(git_root, commit, path)
  end
end

function M.open_log_tab(log, git_root)
  vim.cmd("tabnew")

  -- Create an unlisted, scratch buffer for the bottom
  local bottom_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[bottom_buf].buftype = "nofile"
  vim.bo[bottom_buf].bufhidden = "wipe"
  vim.bo[bottom_buf].swapfile = false

  local lines = {}
  local line_to_path = {}
  local line_to_commit = {}
  for _, commit in ipairs(log) do
    line_to_commit[#lines+1] = commit
    filetree.add_section(lines, line_to_path, format_commit_summary(commit), commit.files)
  end
  vim.b[bottom_buf].line_to_path = line_to_path
  vim.b[bottom_buf].line_to_commit = line_to_commit

  local bottom_win = vim.api.nvim_get_current_win()

  vim.api.nvim_buf_set_lines(bottom_buf, 0, -1, false, lines)
  vim.api.nvim_win_set_buf(bottom_win, bottom_buf)

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

  vim.b[bottom_buf].diff1_win = diff1_win
  vim.b[bottom_buf].diff2_win = diff2_win

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
    local lowest_idx_line_to_path = math.min(unpack(vim.tbl_keys(line_to_path)))
    load_entry(git_root, log[1], line_to_path[lowest_idx_line_to_path])
  end

  vim.keymap.set('n', '<CR>', function() bottom_buf_handle_enter(git_root, bottom_buf) end, {
    noremap = true,
    silent = true,
    buffer = bottom_buf
  })

end

return M
