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
    io_helpers.run_cmd({"git", "restore", item.path}, {cwd = git_root})
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
      -- force both windows to nil so that the "wait_for_windows_ready" trick
      -- works. Otherwise if the window is already loaded nothing happens
      difflayout.win_load_null_file(tab_data.diff1_win)
      difflayout.win_load_null_file(tab_data.diff2_win)
      -- schedule so the "load null file" is executed
      vim.schedule(function()
        tabcommon.win_load_buf(
          tab_data.git_root, tab_data.diff1_win, tab_data.marked.item.path, 
          tab_data.marked.item.left_sha or tab_data.marked.section.left_sha,
          tab_data.marked.section.left_winbar
        )
        tabcommon.win_load_buf(
          tab_data.git_root, tab_data.diff2_win, item.path,
          item.right_sha or section.right_sha, section.right_winbar
        )
        local relevant_windows = {tab_data.diff1_win, tab_data.diff2_win}
        difflayout.wait_for_windows_ready(relevant_windows, function()
          for _, winnr in ipairs(relevant_windows) do
            difflayout.win_set_diff(winnr)
          end
        end)
        tab_data.marked = nil
      end)
    else
      tab_data.marked = { section = section, item = item }
    end
    filetree.redisplay(tab_data.ft, tab_data.ft_st, false)
  end
end

return M
