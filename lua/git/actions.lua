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

local function do_drop_changes(item, do_hash)
  -- first switch to the next file as this file will disappear
  filetree.next_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
  local git_root = tabdata.get_data().git_root
  return async.run(function()
    local msg = nil
    if do_hash then
      local hash = io_helpers.run_cmd({"git", "hash-object", "-w", "--", item.path}, {cwd = git_root})
      msg = string.format("File restored from index. Undo with :sp %s | %%!git show %s", item.path, hash:sub(1, 11))
    end

    if item.left_sha == "nil" then
      -- untracked file, delete it
      io_helpers.async_fs_unlink(vim.fs.joinpath(git_root, item.path))
      -- since we didn't touch the index, we must force a reload
      vim.schedule(function()
        tabdata.get_data().reload_diff(tabdata.get_data().git_root)
      end)
    else
      -- tracked file, staged or not
      io_helpers.run_cmd({"git", "restore", "--source=HEAD", "--staged", "--worktree", "--", item.path})
    end
    if msg ~= nil then
      vim.schedule(function()
        vim.notify(msg, vim.log.levels.INFO, {source = "nanodiff"})
      end)
    end
  end):raise_on_error()
end

function M.drop_changes()
  local tab_data = tabdata.get_data()
  -- will drop changes from the item under the cursor
  local section, item = filetree.get_cur_section_item(tab_data.ft_st)
  if section == nil then
    -- no item under the cursor
    return
  end
  local full_path = vim.fs.joinpath(tab_data.git_root, item.path)
  local opened_bufnr = vim.fn.bufnr(full_path)
  if opened_bufnr ~= -1 and vim.bo[opened_bufnr].modified then
    vim.notify("Refusing to restore a file with unsaved changes!", vim.log.levels.WARN, {source = "nanodiff"})
    return
  end

  local lstat = vim.uv.fs_lstat(full_path)
  if lstat.type == "directory" then
    vim.ui.select({"Yes", "No"}, {prompt="Discard changes in the whole git folder " .. item.path .. "?"}, function(choice)
      if choice == "Yes" then
        do_drop_changes(item, false)
      end
    end)
  elseif lstat.type == "file" then
    do_drop_changes(item, true)
  end
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
    vim.schedule(function()
      local tab_data = tabdata.get_data()
      tab_data.ft_st.selected_item = nil -- reset selected_item
      tab_data.reload_log(function(log)
        if #log == 0 then
          -- no more stashes
          vim.cmd.tabclose()
        end
      end)
    end)
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
      barrier.wait(tabcommon.windows_set_diff_if_needed)
      tab_data.marked = nil
    else
      tab_data.marked = { section = section, item = item }
    end
    filetree.redisplay(tab_data.ft, tab_data.ft_st, false)
  end
end

function M.display_commit_popup(git_root, commit)
  async.run("Loading git commit", function()
    local git_commits = io_helpers.run_cmd({"git", "show", "--stat", commit}, {cwd = git_root})
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
  end):raise_on_error()
end


return M
