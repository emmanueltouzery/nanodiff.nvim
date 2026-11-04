local async = vim.async

local io_helpers = require('core.io_helpers')
local options = require('core.options')
local tabdata = require('core.tabdata')
local filetree = require('core.filetree')
local logtab = require('git.logtab')

local M = {}

-- will run the command you give and parse its output as a git log output,
-- so a list of git "commits". Sometimes (in particular when returning stashes),
-- git can be quite slow, so we return an async iterator: you can consume it with
-- for..in in an async block.
--
-- Internally when a stdout chunk from git is parsed, it gets push()ed
-- as a list of "commits". Push will wake up any sleeping consumer, or
-- if the consumer is behind, add items to the queue.
-- We return a function that returns the next item (potentially async awaiting it),
-- or nil when the log is fully read.
function M.parse_git_log_output(cmd, system_opts, opts)
  local queue = {}
  local waiting = nil
  local finished = false

  local current_commit = nil
  local now = os.time()
  -- stdout chunks can end in the middle of a line, keep the partial line for the next chunk
  local partial_line = ""

  local function push(value)
    if waiting then
      local resume = waiting
      waiting = nil
      resume(value)
    else
      table.insert(queue, value)
    end
  end

  local function parse_chunk(stdout)
    local chunk_commits = {}
    for line in stdout:gmatch("[^\r\n]+") do
      -- Check if line starts with Record Separator (\x1e)
      if line:sub(1, 1) == "\x1e" then
        if current_commit ~= nil then
          -- flush the previous commit to the list
          table.insert(chunk_commits, current_commit)
          current_commit = nil
          -- print("added commit " .. vim.inspect(current_commit))
        end

        local header = line:sub(2) -- strip \x1e
        local f = vim.split(header, "\x1f", { plain = true })

        local timestamp = tonumber(f[4])
        local iso_date = string.sub(f[5], 1, 16) -- drop seconds+TZ, no space when displaying (render_commit_section in particular)
        local relative_date = f[6]
        local date = os.difftime(now, timestamp) > opts.relative_date_cutoff_seconds and iso_date or relative_date

        current_commit = {
          hash = f[1],
          parents = vim.split(f[2] or "", " "),
          author_name = f[3],
          timestamp = timestamp,
          date = date,
          ref_names = f[7],
          ref_log = f[8] ~= "" and f[8] or nil,
          subject = f[9],
          stat = {},
          files = {}
        }

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
    if #chunk_commits > 0 then
      -- the last commit is held back until we see the next one, so a chunk may yield nothing
      push(chunk_commits)
    end
  end

  vim.system(cmd, vim.tbl_extend("force", system_opts or {}, {
    stdout = function(err, data)
      if data and data ~= "" then
        data = partial_line .. data
        -- use an empty capture to get the position just before the last newline
        -- .* is greedy.
        local last_newline = data:match(".*()\n")
        if last_newline then
          partial_line = data:sub(last_newline + 1)
          parse_chunk(data:sub(1, last_newline))
        else
          partial_line = data
        end
      end
    end,
  }), function(result)
    if partial_line ~= "" then
      parse_chunk(partial_line)
      partial_line = ""
    end
    finished = true
    if current_commit ~= nil then
      push({current_commit})
    end
    push(nil)
  end)

  return function()
    if #queue > 0 then
      return table.remove(queue, 1)
    end

    if finished then
      return nil
    end

    -- async.await can take a callback-taking function;
    -- when the callback is called, the await resolves.
    -- assign that callback to 'waiting', so when it's
    -- called, we'll move on
    return async.await(function(done)
      waiting = done
    end)
  end
end

return M
