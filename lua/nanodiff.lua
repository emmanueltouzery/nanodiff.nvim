local async = vim.async
local difftab = require('difftab')
local log = require('log')

local async_sys = async.wrap(3, vim.system)

local M = {
  log = log.display_log,
}

local function get_diff_status(git_root)
  local current_commit =  vim.trim(async_sys({"git", "rev-parse", "HEAD"}, {cwd = git_root}).stdout)

  local output = async_sys({"git", "status", "--porcelain=v2"}, {cwd = git_root})

  local staged = {}
  local unstaged = {}
  local untracked = {}

  for line in output.stdout:gmatch("[^\r\n]+") do
    local prefix = line:sub(1, 1)

    if prefix == "1" then
      -- Ordinary changes: "1 <XY> sub mH mI mW hH hI <path>"
      local xy, path = line:match("^1%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
      if xy then
        local x = xy:sub(1, 1) -- Staged
        local y = xy:sub(2, 2) -- Unstaged

        if x ~= "." then
          table.insert(staged, { path = path, status = x })
        end
        if y ~= "." then
          table.insert(unstaged, { path = path, status = y })
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

        if x == "R" or x == "C" then
          table.insert(staged, {
            path = path,
            orig_path = orig_path,
            status = x,
          })
        elseif x ~= "." then
          table.insert(staged, { path = path, status = x })
        end

        if y ~= "." then
          table.insert(unstaged, { path = path, status = y })
        end
      end

    elseif prefix == "?" then
      -- Untracked files: "? <path>"
      local path = line:match("^%?%s+(.+)$")
      if path then
        table.insert(untracked, { path = path, status = "?" })
      end
    end
  end

  return {
    {title = "Staged", contents = staged, left_sha = current_commit, right_sha = "stage"},
    {title = "Unstaged", contents = unstaged, left_sha = current_commit, right_sha = "disk"},
    {title = "Untracked", contents = untracked, left_sha = nil, right_sha = "disk"},
  }
end

function M.status()
  -- TODO maybe there's a way to skip vim.schedule from within async.run?
  async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}).stdout)
    local status = get_diff_status(git_root)
    vim.schedule(function() difftab.open_diff_tab(status, git_root) end)
  end):raise_on_error()
end

local function get_diff_revspec(git_root, revspec)
  local commits_stdout = async_sys({"git", "rev-parse", "--revs-only", "--no-flags", revspec}, {text = true, cwd = git_root}).stdout
  local right_sha, left_sha = unpack(vim.split(commits_stdout:gsub("%^", ""), "%s+", { trimempty = true }))

  local output = vim.trim(async_sys({"git", "diff", "--name-status", "-M", revspec}, {text = true, cwd = git_root}).stdout)

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

      if code_char == "A" then
        status = "added"
      elseif code_char == "D" then
        status = "deleted"
      elseif code_char == "M" then
        status = "modified"
      elseif code_char == "R" then
        status = "renamed"
        orig_path = parts[2]
        path = parts[3]
      elseif code_char == "C" then
        status = "copied"
        orig_path = parts[2]
        path = parts[3]
      else
        status = "unknown"
      end

      table.insert(results, {
        path = path,
        orig_path = orig_path,
        status = status,
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

function M.revspec(revspec)
  async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {text = true}).stdout)
    local contents = get_diff_revspec(git_root, revspec)
    vim.schedule(function() difftab.open_diff_tab(contents, git_root) end)
  end):raise_on_error()
end

return M
