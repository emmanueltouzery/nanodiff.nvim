local async = vim.async

local filetree = require('core.filetree')
local difflayout = require('core.difflayout')
local bufdata = require('core.bufdata')
local options = require('core.options')
local io_helpers = require('core.io_helpers')
local tabcommon = require('git.tabcommon')
local conflicts = require('git.conflicts')
local index_watcher = require('git.index_watcher')

local M = {}

local function format_section_header(section, has_selection)
  return {{ " " .. section.title .. " ", "DiffviewFilePanelTitle" }, {string.format("(%d)", #section.contents), "DiffviewFilePanelCounter"} }
end

local function load_entry(ft, ft_st, left_buf, git_root, section, item, skip_refresh_left_buf)
  local left_buf_data = bufdata.get_data(left_buf)
  filetree.set_selected_item(ft_st, section, item)
  difflayout.diff_tab_layout_load_buf(left_buf_data, section, item, function(win, path, rev)
    tabcommon.win_load_buf(git_root, win, path, rev)
  end)
  tabcommon.win_load_buf(git_root, left_buf_data.diff1_win, item.path, item.left_sha or section.left_sha)
  tabcommon.win_load_buf(git_root, left_buf_data.diff2_win, item.path, item.right_sha or section.right_sha)
  if not skip_refresh_left_buf then
    filetree.redisplay(left_buf_data.ft, left_buf_data.ft_st, true)
  end
end

function M.open_diff_tab(sections, git_root, reload_index, opts)
  vim.cmd("tabnew")

  local left_buf = vim.api.nvim_win_get_buf(0)
  local left_buf_data = bufdata.get_data(left_buf)

  local left_win = vim.api.nvim_get_current_win()
  left_buf_data.left_win = left_win

  left_buf_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.title end,
    section_get_items = function(s) return s.contents end,
    get_header = function() return {} end, -- TODO
    render_item = function(prefix, item, is_selected, extra)
      return tabcommon.tree_render_item(prefix, item, is_selected, extra, left_buf_data.conflicts_state)
    end,
    render_section = format_section_header,
    item_activated = function(ft, ft_st, section, item, skip_refresh_left_buf)
      load_entry(ft, ft_st, left_buf, git_root, section or {}, item or {left_hash = "nil", right_hash = "nil"}, skip_refresh_left_buf)
    end,
    expand_default = true,
  })
  left_buf_data.ft_st = filetree.create_ft_st({
    bufnr = left_buf,
    winnr = left_win,
  })

  local conflicts_section = sections[1]
  if sections[1].title == "Conflicts" then
    left_buf_data.conflicts_state = {conflicts = {}}
    conflicts.register_watchers(conflicts_section, left_buf, function()
      filetree.redisplay(left_buf_data.ft, left_buf_data.ft_st, false)
    end)
  end

  if reload_index then
    index_watcher.setup_index_watch(git_root, left_buf, function()
      async.run(function()
        local sel = left_buf_data.ft_st.selected_item
        local sections = reload_index(git_root)
        vim.schedule(function()
          -- i must clear all stage-related managed buffers, because what's staged/stashed and so on
          -- may have changed
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local b = vim.api.nvim_win_get_buf(w)
            if vim.startswith(vim.api.nvim_buf_get_name(b), "nanogit://:") then
              -- if we delete the buffer, that would close the window
              -- because buffers a "hidden=wipe", that'll clean it
              difflayout.win_load_null_file(w)
            end
          end

          -- an item may have changed section, if it was staged or unstaged for instance
          -- try to find it back
          local final_section = vim.iter(sections):find(function(s)
            return vim.iter(left_buf_data.ft.section_get_items(s)):find(function(i) return i.path == sel.item.path end)
          end)
          if final_section then
            sel.section = final_section
          else
            sel = nil
          end
          filetree.set_contents(left_buf_data.ft, left_buf_data.ft_st, sections)
          filetree.handle_enter(left_buf_data.ft, left_buf_data.ft_st)
        end)
      end):raise_on_error()
    end)
  end

  difflayout.diff_tab_layout_init(left_buf, opts)

  vim.api.nvim_set_current_win(left_win)

  filetree.set_contents(left_buf_data.ft, left_buf_data.ft_st, sections)

  vim.api.nvim_buf_set_name(left_buf, "Nanodiff Diff")

  if opts.shortcuts.activate then
    vim.keymap.set('n', opts.shortcuts.activate, function()
      filetree.handle_enter(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.scroll_backward then
    vim.keymap.set('n', opts.shortcuts.scroll_backward, function()
      vim.api.nvim_win_call(bufdata.get_data(left_buf).diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.scroll_forward then
    vim.keymap.set('n', opts.shortcuts.scroll_forward, function()
      vim.api.nvim_win_call(bufdata.get_data(left_buf).diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.prev_file then
    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.next_file then
    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.stage_unstage then
    vim.keymap.set('n', opts.shortcuts.stage_unstage, function()
      -- will stage the item under the cursor
      local section, item = filetree.get_cur_section_item(bufdata.get_data(left_buf).ft_st)
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
      async.run(function()
        io_helpers.run_cmd(command, {cwd = git_root})
      end):raise_on_error()
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.drop_changes then
    vim.keymap.set('n', opts.shortcuts.drop_changes, function()
      -- will drop changes from the item under the cursor
      local section, item = filetree.get_cur_section_item(bufdata.get_data(left_buf).ft_st)
      if section == nil then
        -- no item under the cursor
        return
      end
      local diff2_win = bufdata.get_data(left_buf).diff2_win
      if vim.bo[vim.api.nvim_win_get_buf(diff2_win)].modified then
        vim.notify("Refusing to restore a file with unsaved changes!", vim.log.levels.WARN, {source = "nanodiff"})
        return
      end

      -- first switch to the next file as this file will disappear
      filetree.next_file(bufdata.get_data(left_buf).ft, bufdata.get_data(left_buf).ft_st)
      async.run(function()
        local hash = io_helpers.run_cmd({"git", "hash-object", "-w", "--", item.path}, {cwd = git_root})
        io_helpers.run_cmd({"git", "restore", item.path}, {cwd = git_root})
        vim.schedule(function()
          vim.notify(
            string.format("File restored from index. Undo with :sp %s | %%!git show %s", item.path, hash:sub(1, 11)),
            vim.log.levels.INFO, {source = "nanodiff"}
          )
        end)
      end):raise_on_error()
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  return left_buf
end

return M
