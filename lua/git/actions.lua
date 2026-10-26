--- splitting and exporting actions to the API allows users to reuse that code (perform
--- something besides the action, make them accessible through other shortcuts...)

local async = vim.async

local io_helpers = require('core.io_helpers')
local filetree = require('core.filetree')
local tabdata = require('core.tabdata')
local difflayout = require('core.difflayout')
local tabcommon = require('git.tabcommon')

local M = {}

function M.stage_unstage()
  -- will stage the item under the cursor
  local section, item = filetree.get_cur_section_item(tabdata.get_data().ft_st)
  if section == nil then
    -- no item under the cursor
    return
  end
  -- switch to the next file, if we did follow the file as it moves to the
  -- staged/unstaged section, it would be very annoying to stage multiple
  -- files one after the other when doing a review
  filetree.next_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
  local path = item.path
  -- TODO if conflicted file, allow staging if the number of conflicts is zero...
  local command = nil
  if section.right_sha == "disk" then
    -- unstaged, stage it
    command = {"git", "add", path}
  else
    -- staged, unstage it
    command = {"git", "restore", "--staged", path}
  end
  return async.run(function()
    io_helpers.run_cmd(command, {cwd = tabdata.get_data().git_root})
  end):raise_on_error()
end

function M.drop_changes()
  -- will drop changes from the item under the cursor
  local section, item = filetree.get_cur_section_item(tabdata.get_data().ft_st)
  if section == nil then
    -- no item under the cursor
    return
  end
  local diff2_win = tabdata.get_data().diff2_win
  if vim.bo[vim.api.nvim_win_get_buf(diff2_win)].modified then
    vim.notify("Refusing to restore a file with unsaved changes!", vim.log.levels.WARN, {source = "nanodiff"})
    return
  end

  -- first switch to the next file as this file will disappear
  filetree.next_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
  local git_root = tabdata.get_data().git_root
  return async.run(function()
    local hash = io_helpers.run_cmd({"git", "hash-object", "-w", "--", item.path}, {cwd = git_root})

    if item.left_sha == "nil" then
      -- untracked file, delete it
      io_helpers.async_fs_unlink(vim.fs.joinpath(git_root, item.path))
      -- since we didn't touch the index, we must force a reload
      vim.schedule(function()
        tabdata.get_data().reload_diff(tabdata.get_data().git_root)
      end)
    else
      -- tracked file, git restore
      io_helpers.run_cmd({"git", "restore", item.path}, {cwd = git_root})
    end
    vim.schedule(function()
      vim.notify(
        string.format("File restored from index. Undo with :sp %s | %%!git show %s", item.path, hash:sub(1, 11)),
        vim.log.levels.INFO, {source = "nanodiff"}
      )
    end)
  end):raise_on_error()
end

function M.unstash()
  local tab_data = tabdata.get_data()
  return async.run(function()
    local section, item = filetree.get_cur_section_item(tab_data.ft_st)
    if section == nil then
      -- no item under the cursor
      return
    end
    io_helpers.run_cmd({"git", "stash", "pop", section.ref_log}, {cwd = tab_data.git_root})
    vim.schedule(function() vim.cmd.tabclose() end)
  end):raise_on_error()
end

function M.drop_stash()
  local tab_data = tabdata.get_data()
  return async.run(function()
    local section, item = filetree.get_cur_section_item(tab_data.ft_st)
    if section == nil then
      -- no item under the cursor
      return
    end
    io_helpers.run_cmd({"git", "stash", "drop", section.ref_log}, {cwd = tab_data.git_root})
    local git_log = tab_data.reload_log(tab_data.git_root)
    if git_log == nil then
      -- will be nil if there are no more stashes
      vim.cmd.tabclose()
    else
      vim.schedule(function()
        local tab_data = tabdata.get_data()
        tab_data.ft_st.selected_item = nil -- reset selected_item
        filetree.set_contents(tab_data.ft, tab_data.ft_st, git_log)
      end)
    end
  end):raise_on_error()
end

function M.mark_file_for_diff()
  local tab_data = tabdata.get_data()
  local section, item = filetree.get_cur_section_item(tab_data.ft_st)
  if item then
    if tab_data.marked then
      local barrier = difflayout.windows_ready_barrier(tab_data)
      tabcommon.win_load_buf(
        tab_data.git_root, tab_data.diff1_win, tab_data.marked.item.path,
        tab_data.marked.item.left_sha or tab_data.marked.section.left_sha,
        tab_data.marked.section.left_winbar, barrier.add(tab_data.diff1_win)
      )
      tabcommon.win_load_buf(
        tab_data.git_root, tab_data.diff2_win, item.path,
        item.right_sha or section.right_sha,
        section.right_winbar, barrier.add(tab_data.diff2_win)
      )
      barrier.wait(function(all_windows)
        for _, winnr in ipairs(all_windows) do
          difflayout.win_set_diff(winnr)
        end
      end)
      tab_data.marked = nil
    else
      tab_data.marked = { section = section, item = item }
    end
    filetree.redisplay(tab_data.ft, tab_data.ft_st, false)
  end
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

function M.revspec_display_commits_popup(git_root, revspec)
  io_helpers.async_progress("Loading git revspec log", function()
    local log_revspec = async_diff_to_log_revspec(revspec)
    local git_commits = io_helpers.run_cmd({"git", "log", "--first-parent", "--stat", log_revspec}, {cwd = git_root})
    vim.schedule(function()
      local git_commits_lines = vim.split(git_commits, "[\r\n]")

      local bufnr = vim.api.nvim_create_buf(false, false)
      vim.bo[bufnr].filetype = "git"
      vim.bo[bufnr].bufhidden = "wipe"
      vim.bo[bufnr].buftype = "nofile"
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, git_commits_lines)
      vim.bo[bufnr].readonly = true
      vim.bo[bufnr].modified = false
      vim.bo[bufnr].modifiable = false
      local width = vim.api.nvim_get_option("columns")
      local height = vim.api.nvim_get_option("lines") - vim.o.cmdheight - 1
      local win_height = math.min(#git_commits_lines, 50)
      if win_height > height then
        win_height = height
      end

      local opts = {
        style = "minimal",
        border = "rounded",
        relative = "editor",
        row = (height - win_height) / 2,
        col = (width - 100) / 2,
        width = 100,
        height = win_height,
      }
      local w = vim.api.nvim_open_win(bufnr, true, opts)
      -- Adds a 1-character left margin inside the buffer area
      vim.wo[w].foldcolumn = "1"
      vim.keymap.set({'n', 'v'}, 'q', function() vim.api.nvim_win_close(w, false) end, {buf = bufnr})
    end)
  end)
end


return M
