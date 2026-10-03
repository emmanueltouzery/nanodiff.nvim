local async = vim.async
local difftab = require('difftab')
local log = require('log')

local async_sys = async.wrap(3, vim.system)

local M = {
  log = log.display_log,
  stashes = log.display_stashes,
}

local fs_open = async.wrap(4, vim.uv.fs_open)  -- fs_open(path, flags, mode, cb)
local fs_fstat = async.wrap(2, vim.uv.fs_fstat) -- fs_fstat(fd, cb)
local fs_read = async.wrap(4, vim.uv.fs_read)  -- fs_read(fd, size, offset, cb)
local fs_close = async.wrap(2, vim.uv.fs_close) -- fs_close(fd, cb)

local function count_lines_async(filepath)
  local err, fd = fs_open(filepath, "r", 438)
  if err or not fd then return 0 end

  -- 2. Stat (to get file size)
  local err_stat, stat = fs_fstat(fd)
  if err_stat or not stat or stat.size == 0 then
    fs_close(fd)
    return 0
  end

  -- 3. Read content
  local err_read, content = fs_read(fd, stat.size, 0)
  fs_close(fd)

  if err_read or not content or #content == 0 then return 0 end

  -- 4. Count lines
  local _, count = content:gsub("\n", "")
  if content:sub(-1) ~= "\n" then
    count = count + 1
  end

  return count
end

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

local function count_file_lines(filepath)
  local file = io.open(filepath, "rb")
  if not file then return 0 end

  local content = file:read("*a")
  file:close()

  if #content == 0 then return 0 end

  -- content:gsub("\n", "") returns (modified_string, count_of_replacements)
  local _, count = content:gsub("\n", "")

  -- If the file has content but doesn't end with a trailing newline, add 1
  if content:sub(-1) ~= "\n" then
    count = count + 1
  end

  return count
end

local function get_diff_status(git_root)
  local commit_output = async_sys({"git", "rev-parse", "HEAD"}, {cwd = git_root})
  if commit_output.code ~= 0 then
    error("git rev-parse error: " .. commit_output.stderr)
  end
  local current_commit =  vim.trim(commit_output.stdout)

  -- need to fetch the per-file diffstats separately
  local diff_numstat_output = async_sys({"git", "diff", "HEAD", "--numstat"})
  if diff_numstat_output.code ~= 0 then
    error("git diff error: " .. diff_numstat_output.stderr)
  end
  local diff_numstat = parse_diff_numstat(diff_numstat_output.stdout)

  local output = async_sys({"git", "status", "--porcelain=v2"}, {cwd = git_root})

  local staged = {}
  local changes = {}

  for line in output.stdout:gmatch("[^\r\n]+") do
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
        table.insert(changes, { path = path, status = "?", added = count_lines_async(path), deleted = 0, left_sha = "nil" })
      end
    end
  end

  return {
    {title = "Changes", contents = changes, left_sha = current_commit, right_sha = "disk"},
    {title = "Staged", contents = staged, left_sha = current_commit, right_sha = "stage"},
  }
end

function M.status()
  local msg_id = vim.api.nvim_echo({{'Loading...'}}, true, {
    kind='progress', status='running', title='Git status', source='nanodiff', percent = nil
  })
  local status = async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}).stdout)
    return get_diff_status(git_root)
  end):wait()
  vim.api.nvim_echo({{'Done'}}, true, {
    id = msg_id, kind='progress', status='success', source='nanodiff', title='Git status'
  })
  difftab.open_diff_tab(status, git_root)
end

local function get_diff_revspec(git_root, revspec)
  local commits_stdout = async_sys({"git", "rev-parse", "--revs-only", "--no-flags", revspec}, {text = true, cwd = git_root}).stdout
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
  local diff_numstat_output = async_sys({"git", "diff", "--numstat", revspec})
  if diff_numstat_output.code ~= 0 then
    error("git diff --numstat error: " .. diff_numstat_output.stderr)
  end
  local diff_numstat = parse_diff_numstat(diff_numstat_output.stdout)

  local output_obj = async_sys({"git", "diff", "--name-status", "-M", revspec}, {text = true, cwd = git_root})
  if output_obj.code ~= 0 then
    error("git diff error: " .. output_obj.stderr)
  end
  local output = vim.trim(output_obj.stdout)

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

  return {{
    title = "Changes",
    contents = status,
    left_sha = left_sha,
    right_sha = right_sha,
    contents = results,
  }}
end

local function revspec_display_commits_popup(git_root, left_buf, revspec)
  local git_commits = async.run(function()
    return async_sys({"git", "log", "--first-parent", "--stat", revspec}, {cwd = git_root}).stdout
  end):wait()
  local git_commits_lines = vim.split(git_commits, "[\r\n]")

  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[bufnr].filetype = "git"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, git_commits_lines)
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
  vim.api.nvim_win_call(w, function()
    vim.keymap.set({'n', 'v'}, 'q', function()
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), false)
    end, {buffer = true})
  end)
end

function M.revspec(revspec)
  local msg_id = vim.api.nvim_echo({{'Loading...'}}, true, {
    kind='progress', status='running', title='Git revspec', source='nanodiff', percent = nil
  })
  local ok, contents = async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {text = true}).stdout)
    return get_diff_revspec(git_root, revspec)
  end):pwait()
  local status = 'failed'
  if ok then
    status = 'success'
    local left_buf = difftab.open_diff_tab(contents, git_root)

    vim.keymap.set('n', 'L', function() revspec_display_commits_popup(git_root, left_buf, revspec) end, {
      noremap = true,
      silent = true,
      buffer = left_buf
    })
  end
  vim.api.nvim_echo({{'Done'}}, true, {
    id = msg_id, kind='progress', status=status, source='nanodiff', title='Git revspec'
  })
end

return M
