local async = vim.async

local filetree = require('core.filetree')
local difflayout = require('core.difflayout')
local tabdata = require('core.tabdata')
local options = require('core.options')
local io_helpers = require('core.io_helpers')
local tabcommon = require('git.tabcommon')
local conflicts = require('git.conflicts')
local index_watcher = require('git.index_watcher')
local actions = require('git.actions')
local logtab = require('git.logtab')

local M = {}

local function format_section_header(section, has_selection)
  return {{{ " " .. section.title .. " ", "DiffviewFilePanelTitle" }, {string.format("(%d)", #(section.contents)), "DiffviewFilePanelCounter"}}}
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
  vim.cmd("norm! zz")
  print(string.format("conflict [%d/%d]", idx, #matches))
end

local function load_entry(ft, ft_st, git_root, section, item, skip_refresh_left_buf, opts)
  local tab_data = tabdata.get_data()
  filetree.set_selected_item(ft_st, section, item)
  local barrier = difflayout.windows_ready_barrier(tab_data)
  difflayout.diff_tab_layout_load_buf(tab_data, section, item, opts, function(win, path, rev, winbar)
    tabcommon.win_load_buf(git_root, win, path, rev, winbar, barrier.add(win))
  end)
  tabcommon.win_load_buf(
    git_root, tab_data.diff1_win, item.path, item.left_sha or section.left_sha,
    section.left_winbar, barrier.add(tab_data.diff1_win))
  tabcommon.win_load_buf(
    git_root, tab_data.diff2_win, item.path, item.right_sha or section.right_sha,
    section.right_winbar, barrier.add(tab_data.diff2_win))
  if not skip_refresh_left_buf then
    filetree.redisplay(tab_data.ft, tab_data.ft_st, true)
  end

  -- activate diff mode only when all windows are ready
  barrier.wait(function(all_windows)
    if section.mid_sha then
      local mid_buf = vim.api.nvim_win_get_buf(tab_data.diff3_win)
      if opts.shortcuts.conflict_previous then
        vim.keymap.set('n', opts.shortcuts.conflict_previous, function()
          local conflict_lines = vim.tbl_map(function(c) return c.start_lnum end, tab_data.conflicts_state.conflicts[item.path])
          jump_match(conflict_lines, "prev")
        end, { noremap = true, silent = true, buf = mid_buf })
      end
      if opts.shortcuts.conflict_next then
        vim.keymap.set('n', opts.shortcuts.conflict_next, function()
          local conflict_lines = vim.tbl_map(function(c) return c.start_lnum end, tab_data.conflicts_state.conflicts[item.path])
          jump_match(conflict_lines, "next")
        end, { noremap = true, silent = true, buf = mid_buf })
      end

      local function get_conflict_at_line()
        local tab_data = tabdata.get_data()
        local lnum = vim.fn.line(".")
        for _, conflict in ipairs(tab_data.conflicts_state.conflicts[item.path]) do
          if conflict.start_lnum <= lnum and conflict.end_lnum >= lnum then
            return conflict
          end
        end
        return nil
      end

      local function conflict_choose_ours(conflict)
        if conflict.base_lnum then
          -- if base_lnum is present, drop between base_lnum and end_lnum
          vim.api.nvim_buf_set_lines(mid_buf, conflict.base_lnum - 1, conflict.end_lnum, true, {})
        else
          -- if base_lnum is not present, drop between sep_lnum and end_lnum
          vim.api.nvim_buf_set_lines(mid_buf, conflict.sep_lnum - 1, conflict.end_lnum, true, {})
        end
        -- drop start_lnum (do it at the end otherwise it shifts line numbers for the other operations)
        vim.api.nvim_buf_set_lines(mid_buf, conflict.start_lnum - 1, conflict.start_lnum, true, {})
      end

      if opts.shortcuts.conflict_choose_ours then
        vim.keymap.set('n', opts.shortcuts.conflict_choose_ours, function()
          local conflict = get_conflict_at_line()
          if conflict then
            conflict_choose_ours(conflict)
          end
        end, { noremap = true, silent = true, buf = mid_buf })
      end

      if opts.shortcuts.all_conflicts_choose_ours then
        vim.keymap.set('n', opts.shortcuts.all_conflicts_choose_ours, function()
          local conflicts = tab_data.conflicts_state.conflicts[item.path]
          -- loop in reverse as indices are shifting and
          -- don't like looping on a list that's getting modified as we remove conflicts
          for i = #conflicts, 1, -1 do
            conflict_choose_ours(conflicts[i])
          end
        end, { noremap = true, silent = true, buf = mid_buf })
      end

      local function conflict_choose_theirs(conflict)
        -- drop end_lnum (do it at the start otherwise other operations shifts line numbers for it)
        vim.api.nvim_buf_set_lines(mid_buf, conflict.end_lnum - 1, conflict.end_lnum, true, {})
        -- drop between start_lnum and sep_lnum
        vim.api.nvim_buf_set_lines(mid_buf, conflict.start_lnum - 1, conflict.sep_lnum, true, {})
      end

      if opts.shortcuts.conflict_choose_theirs then
        vim.keymap.set('n', opts.shortcuts.conflict_choose_theirs, function()
          local conflict = get_conflict_at_line()
          if conflict then
            conflict_choose_theirs(conflict)
          end
        end, { noremap = true, silent = true, buf = mid_buf })
      end

      if opts.shortcuts.all_conflicts_choose_theirs then
        vim.keymap.set('n', opts.shortcuts.all_conflicts_choose_theirs, function()
          local conflicts = tab_data.conflicts_state.conflicts[item.path]
          -- loop in reverse as indices are shifting and
          -- don't like looping on a list that's getting modified as we remove conflicts
          for i = #conflicts, 1, -1 do
            conflict_choose_theirs(conflicts[i])
          end
        end, { noremap = true, silent = true, buf = mid_buf })
      end

      local function conflict_choose_all(conflict)
        -- drop separators, from end to start (to avoid line numbers shifting)
        vim.api.nvim_buf_set_lines(mid_buf, conflict.end_lnum - 1, conflict.end_lnum, true, {})
        vim.api.nvim_buf_set_lines(mid_buf, conflict.sep_lnum - 1, conflict.sep_lnum, true, {})
        if conflict.base_lnum then
          -- decided that "all" shouldn't include the base revision (unlike diffview)
          -- vim.api.nvim_buf_set_lines(mid_buf, conflict.base_lnum - 1, conflict.base_lnum, true, {})
          vim.api.nvim_buf_set_lines(mid_buf, conflict.base_lnum - 1, conflict.sep_lnum - 1, true, {})
        end
        vim.api.nvim_buf_set_lines(mid_buf, conflict.start_lnum - 1, conflict.start_lnum, true, {})
      end

      if opts.shortcuts.conflict_choose_all then
        vim.keymap.set('n', opts.shortcuts.conflict_choose_all, function()
          local conflict = get_conflict_at_line()
          if conflict then
            conflict_choose_all(conflict)
          end
        end, { noremap = true, silent = true, buf = mid_buf })
      end

      if opts.shortcuts.all_conflicts_choose_all then
        vim.keymap.set('n', opts.shortcuts.all_conflicts_choose_all, function()
          local conflicts = tab_data.conflicts_state.conflicts[item.path]
          -- loop in reverse as indices are shifting and
          -- don't like looping on a list that's getting modified as we remove conflicts
          for i = #conflicts, 1, -1 do
            conflict_choose_all(conflicts[i])
          end
        end, { noremap = true, silent = true, buf = mid_buf })
      end
    end
    tabcommon.windows_set_diff_if_needed(all_windows)
  end)
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

local function open_side_by_side_popup(side1, side2, title, opts)
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

    local opts_title = {
        relative = "editor",
        width = width + 2, -- +2 for left & right borders
        height = 1,
        row = row + height + 2, -- +2 for bottom & bottom borders
        col = col,
        style = "minimal",
        border = "none",
    }

    local title_bufnr = git_text_to_buffer(string.rep(" ", width/2 - (#title/2)) .. title)
    local ns_id = vim.api.nvim_create_namespace("nanodiff_ui_highlights")
    vim.api.nvim_buf_add_highlight(title_bufnr, ns_id, "DiffviewFilePanelTitle", 0, 0, -1)

    local win_left = vim.api.nvim_open_win(side1.buf, true, opts_left)
    vim.wo[win_left].winbar = "%= " .. side1.title .. " %="
    local win_right = vim.api.nvim_open_win(side2.buf, false, opts_right)
    vim.wo[win_right].winbar = "%= " .. side2.title .. " %="
    local win_title = vim.api.nvim_open_win(title_bufnr, false, opts_title)

    vim.keymap.set('n', opts.shortcuts.conflict_modal_switch_commit, function()
      vim.api.nvim_set_current_win(win_right)
    end, { buf = side1.buf, silent = true })

    vim.keymap.set('n', opts.shortcuts.conflict_modal_switch_commit, function()
      vim.api.nvim_set_current_win(win_left)
    end, { buf = side2.buf, silent = true })

    for _, win in ipairs({ win_left, win_right }) do
        local bufnr = vim.api.nvim_win_get_buf(win)
        vim.keymap.set('n', 'q', function()
            pcall(vim.api.nvim_win_close, win_left, true)
            pcall(vim.api.nvim_win_close, win_right, true)
            pcall(vim.api.nvim_win_close, win_title, true)
        end, { buf = bufnr, silent = true })
    end

    return win_left, win_right
end

local function open_conflict_commits(tab_data, opts)
  local section, item = filetree.get_cur_section_item(tab_data.ft_st)
  if section.base_sha == nil then
    vim.notify("No conflict", vim.log.levels.WARN, {source = "nanodiff"})
    return
  end
  async.run(function()
    local fmt = "--format=commit %h (%m)%nAuthor: %an <%ae>%nDate:   %ad%n%n%w(0,4,4)%B"

    -- base ↔ ours: > = changes ours added; < = changes ours lacks (reversed relative to base)
    local commits_base_ours = io_helpers.run_cmd(
      {"git", "log", "-p", "--left-right", "--cherry-pick", fmt, section.base_sha .. "..." .. section.left_sha, "--", item.path},
      {cwd = tab_data.git_root}
    ):gsub("(commit %x+ )%(<%)", "%1(REVERSED)")
    -- base ↔ theirs: > = changes theirs added; < = changes theirs lacks (reversed relative to base)
    local commits_base_theirs = io_helpers.run_cmd(
      {"git", "log", "-p", "--left-right", "--cherry-pick", fmt, section.base_sha .. "..." .. section.right_sha, "--", item.path},
      {cwd = tab_data.git_root}
    ):gsub("(commit %x+ )%(<%)", "%1(REVERSED)")
    vim.schedule(function()
      open_side_by_side_popup({
        title = "commits base ↔ ours",
        buf = git_text_to_buffer(commits_base_ours),
      }, {
        title = "commits base ↔ theirs",
        buf = git_text_to_buffer(commits_base_theirs),
      }, section.conflict_desc, opts)
    end)
  end):raise_on_error()
end

local function reload_diff(git_root, reload_index)
  local tab_data = tabdata.get_data()
  async.run(function()
    local sel = tab_data.ft_st.selected_item
    local sections = reload_index(git_root, opts)
    vim.schedule(function()
      -- i must clear all stage-related managed buffers, because what's staged/stashed and so on
      -- may have changed
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if vim.startswith(vim.api.nvim_buf_get_name(b), "nanodiff://") then
          -- if we delete the buffer, that would close the window
          -- because buffers a "hidden=wipe", that'll clean it
          difflayout.win_load_null_file(w)
        end
      end

      -- an item may have changed section, if it was staged or unstaged for instance
      -- try to find it back
      local item_section_after = vim.iter(sections):find(function(s)
        return vim.iter(tab_data.ft.section_get_items(s)):find(function(i) return i.path == sel.item.path end)
      end)
      if item_section_after then
        sel.section = item_section_after
      else
        sel = nil
      end
      filetree.set_contents(tab_data.ft, tab_data.ft_st, sections)
      filetree.handle_enter(tab_data.ft, tab_data.ft_st)
    end)
  end):raise_on_error()
end

local function prepare_leftpane_log_filetree(tab_data, left_bottom_win, left_bottom_buf, opts)
  tab_data.leftpane_log_ft = filetree.create_ft({
    section_get_key = function(s) return s.hash end,
    section_get_items = function(s) return s.files end,
    get_header = function() return {
      { {"Commits: ", "DiffviewFilePanelPath"}, {#tab_data.log, "DiffviewFilePanelCounter"} },
      {},
    } end,
    render_item = function(prefix, item, is_selected, extra)
      return tabcommon.tree_render_item(
        prefix, item, is_selected, extra, tab_data.conflicts_state,
        true, -- right_align_diffstat
        extra_icon
      )
    end,
    render_section = function(section, has_selection)
      return tabcommon.render_commit_section(section, has_selection, nil, opts)
    end,
    item_activated = function(ft, ft_st, section, item, skip_refresh_left_buf)
      logtab.load_entry(
        tab_data.leftpane_log_ft, tab_data.leftpane_log_ft_st, left_bottom_buf,
        tab_data.git_root, section or {}, item,
        skip_refresh_left_buf, opts
      )
    end,
    expand_default = false,
    lines_between_sections = function(prev_section, section)
        return {}
    end
  })
  tab_data.leftpane_log_ft_st = filetree.create_ft_st({
    bufnr = left_bottom_buf,
    winnr = left_bottom_win,
    selected_item = selected_item,
  })

  -- nicer looks for commit messages that'll be too long
  vim.api.nvim_set_option_value("wrap", false, { win = left_bottom_win })
  vim.api.nvim_set_option_value("list", true, { win = left_bottom_win })
  vim.api.nvim_set_option_value("listchars", "extends:…", { win = left_bottom_win })

  if opts.shortcuts.open_log then
    vim.keymap.set(
      'n', opts.shortcuts.open_log, function()
        local section, item = filetree.get_cur_section_item(tabdata.get_data().leftpane_log_ft_st)
        if section then
          actions.display_commit_popup(git_root, section.hash)
        end
      end,
      { noremap = true, silent = true, buf = left_buf }
    )
  end

  if opts.shortcuts.yank_commit then
    vim.keymap.set('n', opts.shortcuts.yank_commit, function()
      local section, item = filetree.get_cur_section_item(tabdata.get_data().leftpane_log_ft_st)
      if section then
        local hash = section.hash
        vim.fn.setreg("+", hash)
        vim.notify("Copied '" .. hash .. "' to the clipboard", vim.log.levels.INFO, {source = "nanodiff"})
      end
    end, { noremap = true, silent = true, buf = bottom_buf })
  end
end

local function add_standard_filetree_shortcuts(tab_data, buf, ft, ft_st, opts)
  if opts.shortcuts.close_tab then
    vim.keymap.set(
      'n', opts.shortcuts.close_tab, function() vim.cmd.tabclose() end,
      { noremap = true, silent = true, buf = buf }
    )
  end

  if opts.shortcuts.activate then
    vim.keymap.set('n', opts.shortcuts.activate, function()
      filetree.handle_enter(ft, ft_st)
    end, { noremap = true, silent = true, buf = buf })
  end

  tabcommon.add_fwd_bwd_scroll(ft, ft_st, {tab_data.diff1_win, tab_data.diff2_win}, opts)

  if opts.shortcuts.prev_file then
    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file(ft, ft_st)
    end, { noremap = true, silent = true, buf = buf })
  end

  if opts.shortcuts.next_file then
    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file(ft, ft_st)
    end, { noremap = true, silent = true, buf = buf })
  end

  if opts.shortcuts.mark_file_for_diff then
    vim.keymap.set('n', opts.shortcuts.mark_file_for_diff, function()
      actions.mark_file_for_diff()
    end, { noremap = true, silent = true, buf = buf })
  end
end

function M.open_diff_tab(diff_sections, iterator_section, desc_key, desc_val, git_root, reload_index, watch_index, opts)
  local filename = vim.fs.relpath(git_root, opts.selected_file or vim.api.nvim_buf_get_name(0))
  local selected_item = nil
  for _, section in ipairs(diff_sections) do
    for _, item in ipairs(section.contents) do
      if item.path == filename then
        selected_item = {
          section = section,
          item = item,
        }
        break
      end
    end
  end
  vim.cmd("tabnew")

  local left_buf = vim.api.nvim_win_get_buf(0)
  local tab_data = tabdata.get_data()
  tab_data.diff_sections = diff_sections
  tab_data.reload_diff = function(git_root) -- API, can be used by external callers and actions
    reload_diff(git_root, reload_index)
  end
  tab_data.git_root = git_root -- we don't really need this, but it's handy for API users

  local left_win = vim.api.nvim_get_current_win()
  tab_data.left_win = left_win

  tabcommon.register_files_shortcuts(opts)

  tab_data.ft = filetree.create_ft({
    section_get_key = function(s) return s.title end,
    section_get_items = function(s) return s.contents end,
    get_header = function() return {
      { {desc_key .. ": ", "DiffviewFilePanelPath"}, {desc_val, "DiffviewFilePanelCounter"} },
      {},
    } end,
    render_item = function(prefix, item, is_selected, extra)
      local extra_icon = nil
      if tab_data.marked ~= nil and extra.item_full_path == tab_data.marked.item.path then
        extra_icon = " "
      end
      return tabcommon.tree_render_item(
        prefix, item, is_selected, extra, tab_data.conflicts_state,
        true, -- right_align_diffstat
        extra_icon
      )
    end,
    render_section = format_section_header,
    item_activated = function(ft, ft_st, section, item, skip_refresh_left_buf)
      load_entry(
        ft, ft_st, git_root, section or {}, item or {left_sha = "nil", right_sha = "nil"}, 
        skip_refresh_left_buf, opts
      )
    end,
    expand_default = true,
    lines_between_sections = function(prev_section, section)
      local items = prev_section ~= nil and (prev_section.contents or prev_section.files)
      if prev_section ~= nil and (#items > 0 or prev_section.always_show) then
        return {""}
      else 
        return {}
      end
    end
  })
  tab_data.ft_st = filetree.create_ft_st({
    bufnr = left_buf,
    winnr = left_win,
    selected_item = selected_item,
  })

  local has_conflicts = false
  if diff_sections[1].title == "Conflicts" then
    has_conflicts = true
    tab_data.conflicts_state = {conflicts = {}}
    conflicts.register_watchers(diff_sections[1], function()
      filetree.redisplay(tab_data.ft, tab_data.ft_st, false)
    end)
  end

  if watch_index then
    index_watcher.setup_index_watch(git_root, left_buf, function()
      vim.schedule(function()
        reload_diff(git_root, reload_index)
      end)
    end)
  end

  if iterator_section ~= nil then
    local iterator_height = math.floor((vim.o.lines - vim.o.cmdheight - vim.o.laststatus - vim.o.showtabline) * (1 - opts.diff_log_panel_height_ratio))
    tab_data.left_bottom_win = vim.api.nvim_open_win(0, true, {
      split = "below",
      height = iterator_height,
      win = 0,
    })
    tab_data.left_bottom_buf = vim.api.nvim_create_buf(true, false) -- listed, not scratch
    difflayout.set_buf_options(tab_data.left_bottom_buf)
    vim.api.nvim_win_set_buf(tab_data.left_bottom_win, tab_data.left_bottom_buf)
    difflayout.set_win_options(tab_data.left_bottom_win)
    -- Lock the height against <C-W>= balancing
    vim.wo[tab_data.left_bottom_win].winfixheight = true

    vim.api.nvim_set_current_win(tab_data.left_win)

    -- vim.wo[tab_data.left_bottom_win].winbar = "Commits"
    prepare_leftpane_log_filetree(tab_data, tab_data.left_bottom_win, tab_data.left_bottom_buf, opts)

    difflayout.diff_tab_layout_init(left_buf, opts)

    add_standard_filetree_shortcuts(
      tab_data, tab_data.left_bottom_buf, tab_data.leftpane_log_ft, tab_data.leftpane_log_ft_st, opts)

    tabcommon.refresh_from_iterator(
      iterator_section.iterator,
      function() -- on_done
        -- tabcommon.render_commit_section will return 2 rows
        -- unless there's ref_names, then it'll be 3 rows
        local logs_with_refs = vim.tbl_filter(
          function(commit) return commit.ref_names ~= nil and #commit.ref_names > 0 end,
          tab_data.log
        )
        -- final +2 for the header including the number of commits
        local required_height = (#tab_data.log - #logs_with_refs) * 2 + #logs_with_refs * 3 + 2
        if required_height < iterator_height then
          -- shrink the pane in height if possible
          vim.api.nvim_win_set_height(tab_data.left_bottom_win, required_height)
        end
      end,
      function(log)
        tab_data.log = log
        filetree.set_contents(tab_data.leftpane_log_ft, tab_data.leftpane_log_ft_st, log, {
          focus_selected = false,
          expand_first_section = false,
        })
      end
    )
  else
    difflayout.diff_tab_layout_init(left_buf, opts)
  end

  vim.api.nvim_set_current_win(left_win)

  filetree.set_contents(tab_data.ft, tab_data.ft_st, diff_sections)

  vim.api.nvim_buf_set_name(left_buf, "Nanodiff Diff-" .. vim.api.nvim_get_current_tabpage())

  vim.bo[left_buf].filetype = "NanodiffDiffPanel"

  if has_conflicts and opts.shortcuts.open_conflict_commits then
    vim.keymap.set(
      'n', opts.shortcuts.open_conflict_commits, function() open_conflict_commits(tabdata.get_data(), opts) end,
      { noremap = true, silent = true, buf = left_buf }
    )
  end

  add_standard_filetree_shortcuts(tab_data, left_buf, tab_data.ft, tab_data.ft_st, opts)

  if opts.shortcuts.stage_unstage then
    vim.keymap.set('n', opts.shortcuts.stage_unstage, function()
      actions.stage_unstage()
    end, { noremap = true, silent = true, buf = left_buf })
  end

  if opts.shortcuts.drop_changes then
    vim.keymap.set('n', opts.shortcuts.drop_changes, function()
      actions.drop_changes()
    end, { noremap = true, silent = true, buf = left_buf })
  end

  return left_buf
end

return M
