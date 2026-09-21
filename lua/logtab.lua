local filetree = require('filetree')

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
  if commit.ref_names and commit.ref_names ~= "" then
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
end

return M
