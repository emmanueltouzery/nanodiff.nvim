local io_helpers = require("core.io_helpers")
local tabdata = require("core.tabdata")
local index_watcher = require("git.index_watcher")

local M = {}

local augroup = vim.api.nvim_create_augroup("ConflictListeners", { clear = true })

local gutter_ns_id = vim.api.nvim_create_namespace("nanodiff_gutter_signs")

-- when rebasing HEAD is the upstream target branch you are rebasing onto,
-- while the commit being replayed from your feature branch is stage 3 ("theirs").

local function ref_to_sha(git_root, ref)
  return vim.trim(io_helpers.run_cmd({"git", "log", "-1", "--format=%h", ref}, {cwd = git_root}))
end

-- stash apply/pop conflicts leave no state file: find the stash whose
-- content matches the index stages of a conflicted file.
local function find_conflicting_stash(git_root)
  local unmerged = io_helpers.run_cmd({"git", "ls-files", "-u"}, {cwd = git_root})
  local stages, path = {}, nil
  for line in unmerged:gmatch("[^\n]+") do
    local blob, stage, p = line:match("^%d+ (%x+) (%d)\t(.+)$")
    if p and (path == nil or p == path) then
      path = p
      stages[tonumber(stage)] = blob
    end
  end
  -- need stages 1 and 3 for a reliable match (a "deleted by us" file has no stage 2)
  if not (path and stages[1] and stages[3]) then return nil end
  local function blob_at(rev)
    return vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--verify", "-q", rev .. ":" .. path}, {cwd = git_root}))
  end

  -- Request both the full hash (%H) for comparison, and the short hash (%h) for display
  local stashes = io_helpers.run_cmd({"git", "stash", "list", "--format=%gd %h %H"}, {cwd = git_root})
  for ref, short_sha, full_sha in stashes:gmatch("(stash@%b{}) (%x+) (%x+)") do
    if blob_at(full_sha) == stages[3] and blob_at(full_sha .. "^1") == stages[1] then
      return {
        name = ref,       -- e.g., "stash@{1}"
        sha = short_sha,
      }
    end
  end
  return nil
end

function M.get_conflict_commits(git_root)
  if vim.uv.fs_access(index_watcher.get_git_path(git_root, "MERGE_HEAD"), "R") then
    local theirs = ref_to_sha(git_root, "MERGE_HEAD")
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = theirs,
      base = vim.trim(io_helpers.run_cmd({"git", "merge-base", "HEAD", "MERGE_HEAD"}, {cwd = git_root})),
      desc = string.format("Merging commit %s into your current branch.", theirs),
    }
  elseif vim.uv.fs_access(index_watcher.get_git_path(git_root, "CHERRY_PICK_HEAD"), "R") then
    local theirs = ref_to_sha(git_root, "CHERRY_PICK_HEAD")
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = theirs,
      base = ref_to_sha(git_root, "CHERRY_PICK_HEAD~1"),
      desc = string.format("Cherry-picking commit %s.", theirs),
    }
  elseif vim.uv.fs_access(index_watcher.get_git_path(git_root, "REVERT_HEAD"), "R") then
    local revert_sha = ref_to_sha(git_root, "REVERT_HEAD")
    return {
      ours = ref_to_sha(git_root, "HEAD"),
      theirs = ref_to_sha(git_root, "REVERT_HEAD~1"),
      base = revert_sha,
      desc = string.format("Reverting commit %s.", revert_sha),
    }
  else
    local rebase_sha_path = index_watcher.get_git_path(git_root, "rebase-merge/stopped-sha")
    if vim.uv.fs_access(rebase_sha_path, "R") then
      local sha = vim.trim(io.open(rebase_sha_path):read("*a"))

      local branch_name = nil
      local branch_file = index_watcher.get_git_path(git_root, "rebase-merge/head-name")
      if vim.uv.fs_access(branch_file, "R") then
        local f = io.open(branch_file, "r")
        if f then
          branch_name = vim.trim(f:read("*a")):gsub("^refs/heads/", "")
          f:close()
        end
      end

      local desc = branch_name 
        and string.format("Rebasing branch '%s' at commit %s.", branch_name, sha)
        or string.format("Rebasing at commit %s.", sha)

      return {
        ours = ref_to_sha(git_root, "HEAD"),
        theirs = sha,
        base = sha .. "~1",
        desc = desc,
      }
    end 
    local stash = find_conflicting_stash(git_root)
    if stash then
      return {
        ours = ref_to_sha(git_root, "HEAD"),
        theirs = stash.sha,
        base = stash.sha .. "^1",
        desc = string.format("Applying conflicting stash %s (%s).", stash.name, stash.sha),
      }
    end
    -- i could at least display the conflicted files contents...
    -- as find_conflicting_stash does.. git ls-files -u, stages 1 2 3
    -- (base, ours, theirs), but i'd really like to have the full metadata
    -- for the "open_conflict_commits" feature
    error("git conflict get commits: no branch matched")
  end
end

local CONFLICT_START = [[^<<<<<<< ]]
local CONFLICT_BASE = [[^||||||| ]]
local CONFLICT_SEP = [[^=======$]]
local CONFLICT_END = [[^>>>>>>> ]]

-- full parsing of the conflicts will enable spc-co and stuff AND the gutter indicators
local function refresh_conflicts(bufnr, path, conflicts_state, refresh)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local conflicts = {}
  local conflict_info = {}
  for i, item in ipairs(lines) do
    if item:match(CONFLICT_START) then
      conflict_info.start_lnum = i
    elseif item:match(CONFLICT_BASE) then
      conflict_info.base_lnum = i
    elseif item:match(CONFLICT_SEP) then
      conflict_info.sep_lnum = i
    elseif item:match(CONFLICT_END) then
      conflict_info.end_lnum = i
      table.insert(conflicts, conflict_info)
      conflict_info = {}
    end
  end
  conflicts_state.conflicts[path] = conflicts

  vim.api.nvim_buf_clear_namespace(bufnr, gutter_ns_id, 0, -1)
  for _, conflict in ipairs(conflicts) do
    for lnum = conflict.start_lnum-1, conflict.end_lnum-1 do
      vim.api.nvim_buf_set_extmark(bufnr, gutter_ns_id, lnum, 0, {
        sign_text = "▎",
        sign_hl_group = "DiagnosticError",
      })
    end
  end

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
        vim.api.nvim_create_autocmd({ "InsertLeave", "TextChanged" }, {
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
