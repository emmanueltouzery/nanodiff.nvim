local async = vim.async
local async_sys = async.wrap(3, vim.system) -- TODO share instead of c/p

local logtab = require('logtab')

local M = {}

local function get_git_log(git_root)
  local cmd = {
    "git", "-P",
    "-c", "gc.auto=0",
    "-c", "core.quotePath=false",
    "log",
    "-n256",
    "--diff-merges=first-parent",
    "--numstat", "--raw",
    -- %x1e starts a new commit record, %x1f separates each field
    "--pretty=format:%x1e%H%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%ar%x1f%D%x1f%gd%x1f%s",
    "--", git_root
  }

  local obj = async_sys(cmd, { text = true })
  if obj.code ~= 0 then 
    vim.notify("Failed to invoke Git log: " .. obj.stderr, vim.log.levels.ERROR, {
      title = "Nanodiff",
    })
    return {}
  end

  local commits = {}
  local current_commit = nil

  for line in obj.stdout:gmatch("[^\r\n]+") do
    -- Check if line starts with Record Separator (\x1e)
    if line:sub(1, 1) == "\x1e" then
      local header = line:sub(2) -- strip \x1e
      local f = vim.split(header, "\x1f", { plain = true })

      current_commit = {
        hash = f[1],
        parents = vim.split(f[2] or "", " "),
        author_name = f[3],
        timestamp = tonumber(f[4]),
        iso_date = f[5],
        relative_date = f[6],
        ref_names = f[7],
        ref_log = f[8],
        subject = f[9],
        stat = {},
        raw = {}
      }
      table.insert(commits, current_commit)

    elseif current_commit then
      -- Line is part of diff output (--raw or --numstat)
      if line:sub(1, 1) == ":" then
        table.insert(current_commit.raw, line)
      else
        local added, deleted, path = line:match("^([%d%-]+)\t([%d%-]+)\t(.+)$")
        if path then
          table.insert(current_commit.stat, {
            added = added,
            deleted = deleted,
            path = path
          })
        end
      end
    end
  end

  return commits
end

function M.display_log()
  async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}).stdout)
    local git_log = get_git_log(git_root)
    vim.schedule(function() logtab.open_log_tab(git_log, git_root) end)
  end):raise_on_error()
end

return M
