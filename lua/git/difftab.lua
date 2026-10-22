local async = vim.async

local filetree = require('core.filetree')
local difflayout = require('core.difflayout')
local tabdata = require('core.tabdata')
local options = require('core.options')
local io_helpers = require('core.io_helpers')
local tabcommon = require('git.tabcommon')
local conflicts = require('git.conflicts')
local index_watcher = require('git.index_watcher')

local M = {}

local function format_section_header(section, has_selection)
  return {{ " " .. section.title .. " ", "DiffviewFilePanelTitle" }, {string.format("(%d)", #section.contents), "DiffviewFilePanelCounter"} }
end

local function jump_match(matches, dir)
  if #matches == 0 then return end
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  
  -- Default to wrap-around indices if no condition is met
  local idx = (dir == "next" and 1) or #matches

  for i, line in ipairs(matches) do
    if dir == "next" and line > cur then 
      idx = i; break                -- Stop at the very first match ahead of us
    elseif dir == "prev" and line < cur then 
      idx = i                       -- Keep updating until we pass the cursor, leaving the last valid one
    end
  end

  vim.api.nvim_win_set_cursor(0, { matches[idx], 0 })
  print(string.format("conflict [%d/%d]", idx, #matches))
end

local function load_entry(ft, ft_st, git_root, section, item, skip_refresh_left_buf, opts)
  local tab_data = tabdata.get_data()
  filetree.set_selected_item(ft_st, section, item)
  difflayout.diff_tab_layout_load_buf(tab_data, section, item, opts, function(win, path, rev, winbar)
    tabcommon.win_load_buf(git_root, win, path, rev, winbar)
  end)
  tabcommon.win_load_buf(git_root, tab_data.diff1_win, item.path, item.left_sha or section.left_sha, section.left_winbar)
  tabcommon.win_load_buf(git_root, tab_data.diff2_win, item.path, item.right_sha or section.right_sha, section.right_winbar)
  if not skip_refresh_left_buf then
    filetree.redisplay(tab_data.ft, tab_data.ft_st, true)
  end
  -- activate diff mode only when all windows are ready
  local relevant_windows = {tab_data.diff1_win, tab_data.diff2_win}
  if section.bottom_sha then
    table.insert(relevant_windows, tab_data.diff4_win)
  end
  if section.mid_sha then
    table.insert(relevant_windows, tab_data.diff3_win)
  end
  difflayout.wait_for_windows_ready(relevant_windows, function()
    if section.mid_sha then
      local mid_buf = vim.api.nvim_win_get_buf(tab_data.diff3_win)
      if opts.shortcuts.conflict_previous then
        vim.keymap.set('n', opts.shortcuts.conflict_previous, function()
          local conflict_lines = tab_data.conflicts_state.conflicts[item.path]
          jump_match(conflict_lines, "prev")
        end, { noremap = true, silent = true, buffer = mid_buf })
      end
      if opts.shortcuts.conflict_next then
        vim.keymap.set('n', opts.shortcuts.conflict_next, function()
          local conflict_lines = tab_data.conflicts_state.conflicts[item.path]
          jump_match(conflict_lines, "next")
        end, { noremap = true, silent = true, buffer = mid_buf })
      end
    end
    for _, winnr in ipairs(relevant_windows) do
      difflayout.win_set_diff(winnr)
    end
  end)
end

local function open_side_by_side_popup(side1, side2, opts)
    local ui = vim.api.nvim_list_uis()[1]
    local width = math.floor(ui.width * 2 / 3)
    local height = math.floor(ui.height * 2 / 3)

    local row = math.floor((ui.height - height) / 2)
    local col = math.floor((ui.width - width) / 2)

    local half_width = math.floor(width / 2)

    local border_no_right = {
      "┌",  -- top-left
      "─",  -- top
      "",   -- top-right (omitted)
      "",   -- right (omitted)
      "",   -- bottom-right (omitted)
      "─",  -- bottom
      "└",  -- bottom-left
      "│",  -- left
    }

    local opts_left = {
        relative = "editor",
        width = half_width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = border_no_right,
    }

    local border_no_left = {
      "",   -- top-left (omitted)
      "─",  -- top
      "┐",  -- top-right
      "│",  -- right
      "┘",  -- bottom-right
      "─",  -- bottom
      "",   -- bottom-left (omitted)
      "",   -- left (omitted)
    }

    local opts_right = {
        relative = "editor",
        width = width - half_width,
        height = height,
        row = row,
        col = col + half_width+1,
        style = "minimal",
        border = border_no_left,
    }

    local win_left = vim.api.nvim_open_win(side1.buf, true, opts_left)
    vim.wo[win_left].winbar = "%= " .. side1.title .. " %="
    local win_right = vim.api.nvim_open_win(side2.buf, false, opts_right)
    vim.wo[win_right].winbar = "%= " .. side2.title .. " %="

    vim.keymap.set('n', opts.shortcuts.conflict_modal_switch_commit, function()
      vim.api.nvim_set_current_win(win_right)
    end, { buffer = side1.buf, silent = true })

    vim.keymap.set('n', opts.shortcuts.conflict_modal_switch_commit, function()
      vim.api.nvim_set_current_win(win_left)
    end, { buffer = side2.buf, silent = true })

    for _, win in ipairs({ win_left, win_right }) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        vim.keymap.set('n', 'q', function()
            pcall(vim.api.nvim_win_close, win_left, true)
            pcall(vim.api.nvim_win_close, win_right, true)
        end, { buffer = bufnr, silent = true })
    end

    return win_left, win_right
end

local function git_text_to_buffer(text)
  local summary_lines = vim.split(text, '\n', { trimempty = true })
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.bo[bufnr].filetype = "git"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].buftype = "nofile"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, summary_lines)
  vim.bo[bufnr].readonly = true
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].modifiable = false
  return bufnr
end

local function open_conflict_commits(tab_data, opts)
  local section, item = filetree.get_cur_section_item(tab_data.ft_st)
  async.run(function()
    local fmt = "--format=commit %H (%m)%nAuthor: %an <%ae>%nDate:   %ad%n%n%w(0,4,4)%B"

    -- base ↔ ours: > = changes ours added; < = changes ours lacks (reversed relative to base)
    local commits_base_ours = io_helpers.run_cmd(
      {"git", "log", "-p", "--left-right", "--cherry-pick", fmt, section.bottom_sha .. "..." .. section.left_sha, "--", item.path},
      {cwd = tab_data.git_root}
    ):gsub("(commit %x+ )%(<%)", "%1(REVERSED)")
    -- base ↔ theirs: > = changes theirs added; < = changes theirs lacks (reversed relative to base)
    local commits_base_theirs = io_helpers.run_cmd(
      {"git", "log", "-p", "--left-right", "--cherry-pick", fmt, section.bottom_sha .. "..." .. section.right_sha, "--", item.path},
      {cwd = tab_data.git_root}
    ):gsub("(commit %x+ )%(<%)", "%1(REVERSED)")
    vim.schedule(function()
      open_side_by_side_popup({
        title = "commits base ↔ ours",
        buf = git_text_to_buffer(commits_base_ours),
      }, {
        title = "commits base ↔ theirs",
        buf = git_text_to_buffer(commits_base_theirs),
      }, opts)
    end)
  end):raise_on_error()
end

function M.open_diff_tab(sections, desc_key, desc_val, git_root, reload_index, opts)
  vim.cmd("tabnew")

  local left_buf = vim.api.nvim_win_get_buf(0)
  local tab_data = tabdata.get_data()
  tab_data.git_root = git_root -- we don't really need this, but it's handy for API users

  local left_win = vim.api.nvim_get_current_win()
  tab_data.left_win = left_win

  tab_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.title end,
    section_get_items = function(s) return s.contents end,
    get_header = function() return {
      { {desc_key .. ": ", "DiffviewFilePanelPath"}, {desc_val, "DiffviewFilePanelCounter"} },
      {},
    } end,
    render_item = function(prefix, item, is_selected, extra)
      return tabcommon.tree_render_item(
        prefix, item, is_selected, extra, tab_data.conflicts_state, true
      )
    end,
    render_section = format_section_header,
    item_activated = function(ft, ft_st, section, item, skip_refresh_left_buf)
      load_entry(
        ft, ft_st, git_root, section or {}, item or {left_hash = "nil", right_hash = "nil"}, 
        kip_refresh_left_buf, opts
      )
    end,
    expand_default = true,
    lines_between_sections = function(prev_section, section)
      if prev_section ~= nil then return {""} else return {} end
    end
  })
  tab_data.ft_st = filetree.create_ft_st({
    bufnr = left_buf,
    winnr = left_win,
  })

  local has_conflicts = false
  if sections[1].title == "Conflicts" then
    has_conflicts = true
    tab_data.conflicts_state = {conflicts = {}}
    conflicts.register_watchers(sections[1], function()
      filetree.redisplay(tab_data.ft, tab_data.ft_st, false)
    end)
  end

  if reload_index then
    index_watcher.setup_index_watch(git_root, left_buf, function()
      async.run(function()
        local sel = tab_data.ft_st.selected_item
        local sections = reload_index(git_root, opts)
        vim.schedule(function()
          -- i must clear all stage-related managed buffers, because what's staged/stashed and so on
          -- may have changed
          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            local b = vim.api.nvim_win_get_buf(w)
            if vim.startswith(vim.api.nvim_buf_get_name(b), "nanodiff://:") then
              -- if we delete the buffer, that would close the window
              -- because buffers a "hidden=wipe", that'll clean it
              difflayout.win_load_null_file(w)
            end
          end

          -- an item may have changed section, if it was staged or unstaged for instance
          -- try to find it back
          local final_section = vim.iter(sections):find(function(s)
            return vim.iter(tab_data.ft.section_get_items(s)):find(function(i) return i.path == sel.item.path end)
          end)
          if final_section then
            sel.section = final_section
          else
            sel = nil
          end
          filetree.set_contents(tab_data.ft, tab_data.ft_st, sections)
          filetree.handle_enter(tab_data.ft, tab_data.ft_st)
        end)
      end):raise_on_error()
    end)
  end

  difflayout.diff_tab_layout_init(left_buf, opts)

  vim.api.nvim_set_current_win(left_win)

  filetree.set_contents(tab_data.ft, tab_data.ft_st, sections)

  vim.api.nvim_buf_set_name(left_buf, "Nanodiff Diff")

  vim.api.nvim_exec_autocmds("User", {
    pattern = "NanodiffDiffReady",
    data = {
      tab_id = vim.api.nvim_get_current_tabpage(),
    },
  })

  if opts.shortcuts.close_tab then
    vim.keymap.set(
      'n', opts.shortcuts.close_tab, function() vim.cmd.tabclose() end,
      { noremap = true, silent = true, buffer = left_buf }
    )
  end

  if has_conflicts and opts.shortcuts.open_conflict_commits then
    vim.keymap.set(
      'n', opts.shortcuts.open_conflict_commits, function() open_conflict_commits(tab_data, opts) end,
      { noremap = true, silent = true, buffer = left_buf }
    )
  end

  if opts.shortcuts.activate then
    vim.keymap.set('n', opts.shortcuts.activate, function()
      filetree.handle_enter(tabdata.get_data().ft, tabdata.get_data().ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.scroll_backward then
    vim.keymap.set('n', opts.shortcuts.scroll_backward, function()
      vim.api.nvim_win_call(tabdata.get_data().diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.scroll_forward then
    vim.keymap.set('n', opts.shortcuts.scroll_forward, function()
      vim.api.nvim_win_call(tabdata.get_data().diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.prev_file then
    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.next_file then
    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file(tabdata.get_data().ft, tabdata.get_data().ft_st)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.jump_to_first then
    vim.keymap.set('n', opts.shortcuts.jump_to_first, function()
      local ft_st = tabdata.get_data().ft_st
      for i = 1, vim.api.nvim_buf_line_count(ft_st.bufnr) do
        if ft_st.line_to_item[i] ~= nil and ft_st.line_to_item[i].type == "path" then
          vim.api.nvim_win_set_cursor(0, {i, 0})
          filetree.handle_enter( tabdata.get_data().ft, ft_st)
          return
        end
      end
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.stage_unstage then
    vim.keymap.set('n', opts.shortcuts.stage_unstage, function()
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
      async.run(function()
        io_helpers.run_cmd(command, {cwd = git_root})
      end):raise_on_error()
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  if opts.shortcuts.drop_changes then
    vim.keymap.set('n', opts.shortcuts.drop_changes, function()
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
