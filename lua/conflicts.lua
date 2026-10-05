local io_helpers = require("io_helpers")

local M = {}

local augroup = vim.api.nvim_create_augroup("ConflictListeners", { clear = true })

-- when rebasing HEAD is the upstream target branch you are rebasing onto,
-- while the commit being replayed from your feature branch is stage 3 ("theirs").

-- with git worktrees for instance the path to git files will
-- not be the simple .git/<file>
local function get_git_path(git_root, file)
  local output = io_helpers.run_cmd({"git", "rev-parse", "--git-path", file}, {cwd = git_root})
  return vim.fs.joinpath(git_root, vim.trim(output))
end

local function ref_to_sha(git_root, ref)
  return vim.trim(io_helpers.run_cmd({"git", "log", "-1", "--format=%h", ref}, {cwd = git_root}))
end

function M.get_conflict_commits(git_root)
  if vim.uv.fs_access(get_git_path(git_root, "MERGE_HEAD"), "R") then
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "MERGE_HEAD"),
      base = vim.trim(io_helpers.run_cmd({"git", "merge-base", "HEAD", "MERGE_HEAD"}, {cwd = git_root}))
    }
  elseif vim.uv.fs_access(get_git_path(git_root, "CHERRY_PICK_HEAD"), "R") then
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "CHERRY_PICK_HEAD"),
      base = ref_to_sha(git_root, "CHERRY_PICK_HEAD~1")
    }
  elseif vim.uv.fs_access(get_git_path(git_root, "REVERT_HEAD"), "R") then
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "REVERT_HEAD~1"),
      base = ref_to_sha(git_root, "REVERT_HEAD")
    }
  else
    local rebase_sha = get_git_path(git_root, "rebase-merge/stopped-sha")
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

function M.register_watchers(conflicts_section, conflicts_state, refresh)
  local conflicts_path = {}
  for _, item in ipairs(conflicts_section.contents) do
    conflicts_path[item.path] = true
  end
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "NanodiffDiskBufferLoaded",
    callback = function(args)
      if conflicts_path[args.data.path] then
        local path = args.data.path
        refresh_conflicts(args.buf, path, conflicts_state, refresh)

        -- register a buffer write watcher to update the conflicts count and refresh the sidebar
        vim.api.nvim_create_autocmd("BufWritePost", {
          group = augroup,
          buffer = args.buf,
          callback = function(args)
            refresh_conflicts(args.buf, path, conflicts_state, refresh)
          end,
        })
      end
    end,
  })

  -- unregister the watchers when the tab is closed
end

return M
