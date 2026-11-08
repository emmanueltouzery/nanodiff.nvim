local io_helpers = require('core.io_helpers')
local difftab = require('git.difftab')
local log = require('git.log')
local logtab = require('git.logtab')
local conflicts = require('git.conflicts')
local actions = require('git.actions')

local M = {
  actions = actions,
}

function M.get_repo_root()
  return vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}))
end

-- Regular file: added<TAB>deleted<TAB>path<NUL>
-- Rename/copy: added<TAB>deleted<TAB><TAB>old_path<NUL>new_path<NUL>
local function parse_diff_numstat(stdout)
  local stats = {}
  local pos = 1

  while pos <= #stdout do
    local added, deleted, path
    added, deleted, path, pos = stdout:match(
      "^([%d%-]+)\t([%d%-]+)\t([^%z]*)%z()",
      pos
    )

    local entry = {
      added = tonumber(added) or 0, -- binary files are represented by -
      deleted = tonumber(deleted) or 0,
    }

    if path == "" then -- rename
      local old_path, new_path
      old_path, pos = stdout:match("^([^%z]*)%z()", pos)
      new_path, pos = stdout:match("^([^%z]*)%z()", pos)

      entry.old_path = old_path
      entry.new_path = new_path
    else
      entry.path = path
    end

    stats[entry.new_path or entry.path] = entry
  end

  return stats
end

local function get_diff_status(git_root, opts)
  local current_commit = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "HEAD"}, {cwd = git_root}))

  -- need to fetch the per-file diffstats separately
  local diff_numstat = parse_diff_numstat(io_helpers.run_cmd({
    "git", "-c", "core.quotepath=false", "diff", "HEAD", "--numstat", "-z"
  }))

  local output = io_helpers.run_cmd({"git", "-c", "core.quotepath=false", "status", "--porcelain=v2", "--untracked-files=all"}, {cwd = git_root})

  local staged = {}
  local changes = {}

  for line in output:gmatch("[^\r\n]+") do
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
        local added = vim.async.await(io_helpers.count_file_lines(vim.fs.joinpath(git_root, path)))
        table.insert(changes, { path = path, status = "?", added = added, deleted = 0, left_sha = "nil" })
      end
    end
  end

  -- need to fetch conflicts separately
  local conflicts_output = io_helpers.run_cmd({"git", "diff", "--name-only", "--diff-filter=U"})
  local conflicted_files = vim.tbl_map(
    function(p) return { path = p, status = "U" } end,
    vim.split(conflicts_output, '\n', { trimempty = true })
  )
  local conflict_commits = {ours = "nil", theirs = "nil", base = "nil"}
  if #conflicted_files > 0 then
    conflict_commits = conflicts.get_conflict_commits(git_root)
  end

  local conflicts_section = {
    title = "Conflicts", contents = conflicted_files,
    left_sha = conflict_commits.ours, left_winbar = "OURS " .. conflict_commits.ours,
    mid_sha = "disk", mid_winbar = "LOCAL",
    right_sha = conflict_commits.theirs, right_winbar = "THEIRS " .. conflict_commits.theirs,
    base_sha = conflict_commits.base, bottom_winbar = "BASE " .. conflict_commits.base,
    conflict_desc = conflict_commits.desc,
  }

  return {
    conflicts_section,
    {title = "Changes", contents = changes, left_sha = ":0", right_sha = "disk", always_show = true}, -- :0 = staged file, so we're looking at unstaged changes
    {title = "Staged", contents = staged, left_sha = current_commit, right_sha = ":0"},
  }
end

function M.status(opts)
  io_helpers.async_progress("Loading git status", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}))
    local branch = vim.trim(io_helpers.run_cmd({"git", "branch", "--show"}))
    local status = get_diff_status(git_root, opts)
    vim.schedule(function()
      if vim.iter(status):all(function(item) return #item.contents == 0 end) then
        vim.notify("No changes to display", vim.log.levels.INFO, {source = "nanodiff"})
      else
        difftab.open_diff_tab(status, nil, "Branch", branch, git_root, get_diff_status, true, opts)
      end
    end)
  end)
end

local function get_diff_revspec(git_root, revspec)
  local commits_stdout = io_helpers.run_cmd({"git", "rev-parse", "--revs-only", "--no-flags", revspec}, {text = true, cwd = git_root})
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
  local diff_numstat = parse_diff_numstat(io_helpers.run_cmd({
    "git", "-c", "core.quotepath=false", "diff", "--numstat", "-z", revspec
  }))

  local output = vim.trim(io_helpers.run_cmd({
    "git", "-c", "core.quotepath=false", "diff", "--name-status", "-M", revspec
  }, {text = true, cwd = git_root}))

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

  return revspec, {{
    title = "Changes",
    left_sha = left_sha,
    right_sha = right_sha,
    contents = results,
  }}
end

--- Converts a git diff revspec into an equivalent git log commit range string.
-- @param revspec string The input revspec (e.g., "master", "master...", "A..B", "A...B")
-- @return string The converted range suitable for git log (e.g., "merge_base..B")
local function async_diff_to_log_revspec(revspec)
  if revspec == "" then
    return "HEAD"
  end
  if vim.endswith(revspec, "^!") then
    -- C^! means the commit C, excluding its parents
    return revspec
  end

  -- 1. Check for triple-dot range: "A...B" or "A..."
  local a_triple, b_triple = revspec:match("^([^.]*)%.%.%.([^.]*)$")
  if a_triple then
    local ref_a = a_triple ~= "" and a_triple or "HEAD"
    local ref_b = b_triple ~= "" and b_triple or "HEAD"

    local merge_base = vim.trim(io_helpers.run_cmd({"git", "merge-base", ref_a, ref_b}, {cwd = git_root}))
    if merge_base then
      return string.format("%s..%s", merge_base, ref_b)
    else
      -- Fallback if merge-base fails (e.g., unrelated histories)
      return string.format("%s..%s", ref_a, ref_b)
    end
  end

  -- 2. Check for double-dot range: "A..B" or "A.."
  local a_double, b_double = revspec:match("^([^.]*)%.%.([^.]*)$")
  if a_double then
    local ref_a = a_double ~= "" and a_double or "HEAD"
    local ref_b = b_double ~= "" and b_double or "HEAD"
    return string.format("%s..%s", ref_a, ref_b)
  end

  -- 3. Single rev spec: "master" -> compares commit 'master' to current HEAD
  return string.format("%s..HEAD", revspec)
end

function M.revspec(revspec, opts)
  io_helpers.async_progress("Loading git revspec", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {text = true}))
    local revspec, contents = get_diff_revspec(git_root, revspec)
    local log_revspec = async_diff_to_log_revspec(revspec)
    vim.schedule(function()
      if vim.iter(contents):all(function(item) return #item.contents == 0 end) then
      vim.notify("No changes to display", vim.log.levels.INFO, {source = "nanodiff"})
    else
      local commits_iterator = log.parse_git_log_output({
        "git", "-P", "-c", "gc.auto=0", "-c", "core.quotePath=false", "log", "--first-parent", "--stat", log_revspec,
        "--diff-merges=first-parent", "--numstat", "--raw", "--pretty=format:%x1e%h%x1f%p%x1f%an%x1f%at%x1f%ai%x1f%ar%x1f%D%x1f%gd%x1f%s",
      }, {cwd = git_root}, opts)

      local left_buf = difftab.open_diff_tab(
        contents, { title="Commits", iterator = commits_iterator }, "Revspec", revspec, git_root,
        function(git_root)
          local revspec, contents = get_diff_revspec(git_root, revspec)
          return contents
        end, false, opts)
      end
    end)
  end)
end

function M.log(opts)
  local single_file_path = opts.path
  local buf = opts.buf
  if type(buf) == "number" then
    single_file_path = vim.api.nvim_buf_get_name(buf)
  end
  local function log_view_title(git_root)
    local title = "Log view"
    if single_file_path then
      single_file_path = vim.fs.relpath(git_root, single_file_path)
      title = { {title .. " ", "DiffviewFilePanelTitle"}, { single_file_path .. " ", "DiffviewFolderName" } }
    end
    return title
  end

  io_helpers.async_progress("Loading git log", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}))
    if single_file_path then
      single_file_path = vim.fs.relpath(git_root, single_file_path)
    end
    local function get_iterator_fn(tab_data)
      local extra_params = vim.tbl_values(tab_data.search_settings)
      local cmd = vim.iter({
        { "git", "-P",
        "-c", "gc.auto=0",
        "-c", "core.quotePath=false",
        "log",
      }, (extra_params or {}), {
        "--diff-merges=first-parent",
        "--numstat", "--raw",
        "--pretty=format:%x1e%h%x1f%p%x1f%an%x1f%at%x1f%ai%x1f%ar%x1f%D%x1f%gd%x1f%s",
      }}):flatten():totable()
      if single_file_path then
        table.insert(cmd, "--follow")
      end
      vim.list_extend(cmd, { "--", single_file_path or git_root })
      return log.parse_git_log_output(cmd, { cwd = git_root }, opts)
    end
    local branch = vim.trim(io_helpers.run_cmd({"git", "branch", "--show"}))
    vim.schedule(function()
      logtab.open_log_tab(
        log_view_title(git_root, branch),
        {
          {"Branch: ", "DiffviewFolderName"},
          {branch, "DiffviewFilePanelPath"}
        },
        get_iterator_fn, git_root, opts)
    end)
  end, opts)
end

function M.stashes(opts)
  io_helpers.async_progress("Loading git stashes", function()
    local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}))
    -- if there are no stashes, the following calls don't react well, check first
    if io_helpers.async_sys({"git", "rev-parse", "--verify", "--quiet", "refs/stash"}).code ~= 0 then
      vim.schedule(function()
        vim.notify("No stashes", vim.log.levels.WARN, {source="nanodiff"})
      end)
      return
    end
    local function get_iterator_fn(tab_data)
      local extra_params = vim.tbl_values(tab_data.search_settings)
      local cmd = vim.iter({
        { "git", "-P",
        "-c", "gc.auto=0",
        "-c", "core.quotePath=false",
        "log",
      }, (extra_params or {}), {
        "-g", -- --walk-reflogs: iterate through the stash stack
        "--diff-merges=first-parent", -- ONLY compare against main commit (prevents double/massive output)
        "--numstat", "--raw",
        "--pretty=format:%x1e%h%x1f%P%x1f%an%x1f%at%x1f%ai%x1f%ar%x1f%D%x1f%gd%x1f%s",
        "refs/stash"
      }}):flatten():totable()
      return log.parse_git_log_output(cmd, { cwd = git_root }, opts)
    end
    vim.schedule(function()
      -- logtab does title == "Stashes" tests!
      logtab.open_log_tab("Stashes", nil, get_iterator_fn, git_root, opts)
    end)
  end, opts)
end

return M
