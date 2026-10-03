local io_helpers = require("io_helpers")

local M = {}

-- when rebasing HEAD is the upstream target branch you are rebasing onto,
-- while the commit being replayed from your feature branch is stage 3 ("theirs").

-- with git worktrees for instance the path to git files will
-- not be the simple .git/<file>
local function get_git_path(git_root, file)
  local output = io_helpers.run_cmd({"git", "rev-parse", "--git-path", file}, {cwd = git_root})
  return vim.trim(output)
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
      ours = ref_to_sha("HEAD"),
      theirs = ref_to_sha("CHERRY_PICK_HEAD"),
      base = ref_to_sha("CHERRY_PICK_HEAD~1")
    }
  elseif vim.uv.fs_access(get_git_path(git_root, "REVERT_HEAD"), "R") then
    return {
      ours = ref_to_sha("HEAD"),
      theirs = ref_to_sha("REVERT_HEAD~1"),
      base = ref_to_sha("REVERT_HEAD")
    }
  else
    local rebase_sha = get_git_path(git_root, "rebase-merge/stopped-sha")
    if vim.uv.fs_access(rebase_sha, "R") == 1 then
      local sha = vim.trim(vim.io.open(rebase_sha[1]):read("*a"))
      return {
        ours = ref_to_sha("HEAD"),
        theirs = sha,
        base = sha .. "~1"
      }
    end
    error("git conflict get commits: no branch matched")
  end
end

return M
