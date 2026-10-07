local async = vim.async
local difftab = require('difftab')
local log = require('log')
local conflicts = require('conflicts')
local io_helpers = require('io_helpers')

local M = {
  log = log.display_log,
  stashes = log.display_stashes,
}

local function get_new_path(path)
  if path:find(" => ") then
    -- Handle grouped renames like "dir/{old => new}/file.lua"
    local prefix, new_part, suffix = path:match("^(.-)%{%S*%s*=>%s*(%S*)%}(.*)$")
    if prefix then
      return (prefix .. new_part .. suffix):gsub("//+", "/")
    end
    -- Handle simple renames like "old.lua => new.lua"
    return path:match("=>%s*(.+)$")
  end
  return path
end

local function parse_diff_numstat(stdout)
  local stats = {}

  for line in stdout:gmatch("[^\r\n]+") do
    local added, deleted, path = line:match("^([%d%-]+)%s+([%d%-]+)%s+(.+)$")
    if path then
      local real_path = get_new_path(path)
      stats[real_path] = {
        added = tonumber(added) or 0,
        deleted = tonumber(deleted) or 0,
      }
    end
  end

  return stats
end

local function get_diff_status(git_root)
  local current_commit = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "HEAD"}, {cwd = git_root}))

  -- need to fetch the per-file diffstats separately
  local diff_numstat = parse_diff_numstat(io_helpers.run_cmd({"git", "diff", "HEAD", "--numstat"}))

  local output = io_helpers.run_cmd({"git", "status", "--porcelain=v2"}, {cwd = git_root})

  local staged = {}
  local changes = {}

  for line in output:gmatch("[^\r\n]+") do
    local prefix = line:sub(1, 1)

    if prefix == "1" then
      -- Ordinary changes: "1 <XY> sub mH mI mW hH hI <path>"
      local xy, path = line:match("^1%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
      if xy then
        local x = xy:sub(1, 1) -- Staged
        local y = xy:sub(2, 2) -- Changes

        local stats = diff_numstat[path]
        if x ~= "." then
          table.insert(staged, { path = path, status = x, added = stats.added, deleted = stats.deleted })
        end
        if y ~= "." then
          table.insert(changes, { path = path, status = y, added = stats.added, deleted = stats.deleted })
        end
      else
        print("couldn't match line: " .. line)
      end

    elseif prefix == "2" then
      -- Renamed/Copied changes: "2 <XY> sub mH mI mW hH hI X score <path>\t<origPath>"
      local xy, paths = line:match("^2%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
      if xy and paths then
        local x = xy:sub(1, 1)
        local y = xy:sub(2, 2)

        -- Paths are tab-separated: "new_path\told_path"
        local path, orig_path = paths:match("^([^\t]+)\t(.+)$")

        local stats = diff_numstat[path]
        if x == "R" or x == "C" then
          table.insert(staged, {
            path = path,
            orig_path = orig_path,
            status = x,
            added = stats.added, deleted = stats.deleted
          })
        elseif x ~= "." then
          table.insert(staged, { path = path, status = x, added = stats.added, deleted = stats.deleted })

        end

        if y ~= "." then
          table.insert(changes, { path = path, status = y, added = stats.added, deleted = stats.deleted })
        end
      end

    elseif prefix == "?" then
      -- Untracked files: "? <path>"
      local path = line:match("^%?%s+(.+)$")
      if path then
        table.insert(changes, { path = path, status = "?", added = nil, deleted = nil, left_sha = "nil" })
      end
    end
  end

  -- need to fetch conflicts separately
  local conflicts_output = io_helpers.run_cmd({"git", "diff", "--name-only", "--diff-filter=U"})
  local conflicted_files = vim.tbl_map(
    function(p) return { path = p, status = "U" } end,
    vim.split(conflicts_output, '\n', { trimempty = true })
  )
  local conflict_commits = {ours = "nil", theirs = "nil", base = "nil"}
  if #conflicted_files > 0 then
    conflict_commits = conflicts.get_conflict_commits(git_root)
  end

  return {
    {title = "Conflicts", contents = conflicted_files,
      left_sha = conflict_commits.ours, mid_sha = "disk", right_sha = conflict_commits.theirs, bottom_sha = conflict_commits.base },
    {title = "Changes", contents = changes, left_sha = ":0", right_sha = "disk"}, -- :0 = staged file, so we're looking at unstaged changes
    {title = "Staged", contents = staged, left_sha = current_commit, right_sha = ":0"},
  }
end

function M.status()
  io_helpers.async_progress("Loading git status", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}))
    local status = get_diff_status(git_root)
    vim.schedule(function()
      difftab.open_diff_tab(status, git_root, get_diff_status)
    end)
  end)
end

local function get_diff_revspec(git_root, revspec)
  local commits_stdout = io_helpers.run_cmd({"git", "rev-parse", "--revs-only", "--no-flags", revspec}, {text = true, cwd = git_root})
  local right_sha, left_sha = unpack(vim.split(commits_stdout:gsub("%^", ""), "%s+", { trimempty = true }))
  if left_sha == nil then
    -- git rev-parse resolved a single sha. that means the revspec contained a single sha,
    -- we're comparing that sha with the worktree
    left_sha = right_sha
    right_sha = "disk"
    -- update the revspec so that revspec_display_commits_popup works properly
    revspec = revspec .. "..HEAD"
  end

  -- need to fetch the per-file diffstats separately
  local diff_numstat = parse_diff_numstat(io_helpers.run_cmd({"git", "diff", "--numstat", revspec}))

  local output = vim.trim(io_helpers.run_cmd({"git", "diff", "--name-status", "-M", revspec}, {text = true, cwd = git_root}))

  local results = {}

  for line in output:gmatch("[^\r\n]+") do
    -- Split line by tab characters
    local parts = {}
    for part in line:gmatch("[^\t]+") do
      table.insert(parts, part)
    end

    if #parts >= 2 then
      local raw_code = parts[1]
      local code_char = raw_code:sub(1, 1)
      local path = parts[2]
      local orig_path = nil
      local status

      if code_char == "R" then
        -- renamed
        orig_path = parts[2]
        path = parts[3]
      elseif code_char == "C" then
        -- copied
        orig_path = parts[2]
        path = parts[3]
      end

      local numstat = diff_numstat[path]
      table.insert(results, {
        path = path,
        orig_path = orig_path,
        status = code_char,
        added = numstat.added or 0,
        deleted = numstat.deleted or 0,
      })
    end
  end

  return revspec, {{
    title = "Changes",
    contents = status,
    left_sha = left_sha,
    right_sha = right_sha,
    contents = results,
  }}
end

local function revspec_display_commits_popup(git_root, left_buf, revspec)
  io_helpers.async_progress("Loading git revspec log", function()
    local git_commits = io_helpers.run_cmd({"git", "log", "--first-parent", "--stat", revspec}, {cwd = git_root})
    vim.schedule(function()
      local git_commits_lines = vim.split(git_commits, "[\r\n]")

      local bufnr = vim.api.nvim_create_buf(false, false)
      vim.bo[bufnr].filetype = "git"
      vim.bo[bufnr].bufhidden = "wipe"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, git_commits_lines)
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      vim.bo[bufnr].modifiable = false
      local width = vim.api.nvim_get_option("columns")
      local height = vim.api.nvim_get_option("lines") - vim.o.cmdheight - 1
      local win_height = pref_height or 50
      if win_height > height then
        win_height = height
      end

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
      vim.keymap.set({'n', 'v'}, 'q', function() vim.api.nvim_win_close(w, false) end, {buf = bufnr})
    end)
  end)
end

function M.revspec(revspec)
  io_helpers.async_progress("Loading git revspec", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {text = true}))
    local revspec, contents = get_diff_revspec(git_root, revspec)
    vim.schedule(function()
      local left_buf = difftab.open_diff_tab(contents, git_root, nil)

      vim.keymap.set(
        'n', 'L', function() revspec_display_commits_popup(git_root, left_buf, revspec) end,
        { noremap = true, silent = true, buffer = left_buf }
      )
    end)
  end)
end

return M
