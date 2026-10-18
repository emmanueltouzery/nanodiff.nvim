-- inspired by mini.diff's index watcher
local async = vim.async

local tabdata = require("core.tabdata")
local io_helpers = require("core.io_helpers")

local M = {}

-- with git worktrees for instance the path to git files will
-- not be the simple .git/<file>
function M.get_git_path(git_root, file)
  local output = io_helpers.run_cmd({"git", "rev-parse", "--git-path", file}, {cwd = git_root})
  return vim.fs.joinpath(git_root, vim.trim(output))
end

-- NOTE: Watching single 'index' file is not enough as staging by Git is done
-- via "create fresh 'index.lock' file, apply modifications, change file name
-- to 'index'". Hence watch the whole '.git' (first level) and react only if
-- change was in 'index' file.
M.setup_index_watch = function(git_path, bufnr, index_changed_cb)
  async.run(function()
    local git_dir_path = M.get_git_path(git_path, ".")
    local buf_fs_event, timer = vim.loop.new_fs_event(), vim.loop.new_timer()

    local watch_index = function(_, filename, _)
      if filename ~= 'index' then return end
      -- Debounce to not overload during incremental staging (like in script)
      timer:stop()
      timer:start(50, 0, index_changed_cb)
    end
    buf_fs_event:start(git_dir_path, { recursive = false }, watch_index)
    vim.schedule(function()
      tabdata.add_cleanup(function()
        vim.loop.timer_stop(timer)
        vim.loop.fs_event_stop(buf_fs_event)
      end)
    end)
  end):raise_on_error()
end

return M
