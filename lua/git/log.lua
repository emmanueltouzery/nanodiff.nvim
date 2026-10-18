local async = vim.async

local io_helpers = require('core.io_helpers')
local options = require('core.options')
local logtab = require('git.logtab')

local M = {}

function M.parse_git_log_output(stdout, opts)
  local commits = {}
  local current_commit = nil

  for line in stdout:gmatch("[^\r\n]+") do
    -- Check if line starts with Record Separator (\x1e)
    if line:sub(1, 1) == "\x1e" then
      local header = line:sub(2) -- strip \x1e
      local f = vim.split(header, "\x1f", { plain = true })

      local timestamp = tonumber(f[4])
      local iso_date = f[5]
      local relative_date = f[6]
      local date = os.difftime(os.time(), timestamp) > opts.relative_date_cutoff_seconds and iso_date or relative_date

      current_commit = {
        hash = f[1],
        parents = vim.split(f[2] or "", " "),
        author_name = f[3],
        timestamp = timestamp,
        date = date,
        ref_names = f[7],
        ref_log = f[8],
        subject = f[9],
        stat = {},
        files = {}
      }
      table.insert(commits, current_commit)

    elseif current_commit then
      -- Line starts with ':' -> Parse --raw metadata directly
      if line:sub(1, 1) == ":" then
        -- Parse status code and rest of line after status
        -- Example normal: :100644 100644 ... M\tlua/helpers.lua
        -- Example rename: :100644 100644 ... R100\told.lua\tnew.lua
        local status_char, paths_str = line:match("^:%d+%s+%d+%s+%S+%s+%S+%s+([A-Z])%d*\t(.+)$")

        if status_char and paths_str then
          local paths = vim.split(paths_str, "\t", { plain = true })

          if status_char == "R" or status_char == "C" then
            -- Renamed/Copied files contain both old and new paths separated by a tab
            table.insert(current_commit.files, {
              status = status_char,
              path = paths[1],
              new_path = paths[2]
            })
          elseif status_char == "A" then
            -- added file
            table.insert(current_commit.files, {
              status = status_char,
              path = paths[1],
              left_sha = "nil",
            })
          else
            table.insert(current_commit.files, {
              status = status_char,
              path = paths[1]
            })
          end
        end

      else
        -- Line is part of --numstat output (per-file stats)
        local added, deleted, path = line:match("^([%d%-]+)%s+([%d%-]+)%s+(.+)$")
        if path then
          for _, file in ipairs(current_commit.files) do
            if file.path == path or file.new_path == path then
              file.added = tonumber(added) or 0
              file.deleted = tonumber(deleted) or 0
              break
            end
          end
        end
      end
    end
  end
  return commits
end

function M.display_log_cmd(title_fn, cmd_fn, opts)
  io_helpers.async_progress("Loading git log", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}))
    local git_log = cmd_fn(git_root)
    vim.schedule(function()
      logtab.open_log_tab(title_fn(git_root), git_log, git_root, cmd_fn, opts)
    end)
  end)
end

return M
