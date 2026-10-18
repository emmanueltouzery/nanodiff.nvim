local io_helpers = require("core.io_helpers")
local tabdata = require("core.tabdata")
local index_watcher = require("git.index_watcher")

local M = {}

local augroup = vim.api.nvim_create_augroup("ConflictListeners", { clear = true })

-- when rebasing HEAD is the upstream target branch you are rebasing onto,
-- while the commit being replayed from your feature branch is stage 3 ("theirs").

local function ref_to_sha(git_root, ref)
  return vim.trim(io_helpers.run_cmd({"git", "log", "-1", "--format=%h", ref}, {cwd = git_root}))
end

function M.get_conflict_commits(git_root)
  if vim.uv.fs_access(index_watcher.get_git_path(git_root, "MERGE_HEAD"), "R") then
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "MERGE_HEAD"),
      base = vim.trim(io_helpers.run_cmd({"git", "merge-base", "HEAD", "MERGE_HEAD"}, {cwd = git_root}))
    }
  elseif vim.uv.fs_access(index_watcher.get_git_path(git_root, "CHERRY_PICK_HEAD"), "R") then
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "CHERRY_PICK_HEAD"),
      base = ref_to_sha(git_root, "CHERRY_PICK_HEAD~1")
    }
  elseif vim.uv.fs_access(index_watcher.get_git_path(git_root, "REVERT_HEAD"), "R") then
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "REVERT_HEAD~1"),
      base = ref_to_sha(git_root, "REVERT_HEAD")
    }
  else
    local rebase_sha = index_watcher.get_git_path(git_root, "rebase-merge/stopped-sha")
    if vim.uv.fs_access(rebase_sha, "R") then
      local sha = vim.trim(io.open(rebase_sha):read("*a"))
      return {
        ours = ref_to_sha(git_root, "HEAD"),
        theirs = sha,
        base = sha .. "~1"
      }
    else
      error("git conflict get commits: no branch matched")
    end
  end
end

local function refresh_conflicts(bufnr, path, conflicts_state, refresh)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local indices = {}
  for i, item in ipairs(lines) do
    if vim.startswith(item, "<<<<<<<") then
      table.insert(indices, i)
    end
  end
  conflicts_state.conflicts[path] = indices
  refresh()
end

function M.register_watchers(conflicts_section, refresh)
  local tab_data = tabdata.get_data()
  local conflicts_state = tab_data.conflicts_state
  local conflicts_path = {}
  for _, item in ipairs(conflicts_section.contents) do
    conflicts_path[item.path] = true
  end
  local autocmd_id = vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "NanodiffDiskBufferLoaded",
    callback = function(args)
      if conflicts_path[args.data.path] then
        local path = args.data.path
        local buf = args.data.buf
        refresh_conflicts(buf, path, conflicts_state, refresh)

        -- register a buffer write watcher to update the conflicts count and refresh the sidebar
        vim.api.nvim_create_autocmd("BufWritePost", {
          group = augroup,
          buffer = args.data.buf,
          callback = function(args)
            refresh_conflicts(buf, path, conflicts_state, refresh)
          end,
        })
      end
    end,
  })

  -- unregister the watchers when the tab is closed
  tabdata.add_cleanup(function()
    vim.api.nvim_del_autocmd(autocmd_id)
  end)
end

return M
