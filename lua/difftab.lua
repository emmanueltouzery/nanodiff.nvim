local async = vim.async

local filetree = require('filetree')
local tabcommon = require('tabcommon')
local bufdata = require('bufdata')
local conflicts = require('conflicts')
local index_watcher = require('index_watcher')

local M = {}

local function refresh_left_buf(left_buf, scroll_win)
  local lines = {}
  local left_buf_data = bufdata.get_data(left_buf)
  left_buf_data.line_to_item = {}
  left_buf_data.sorted_files = {}
  local selection_line = nil
  for _, section in ipairs(left_buf_data.sections) do
    local selected_path = nil
    if left_buf_data.selected_item ~= nil and left_buf_data.selected_item.section == section.title then
      selected_path = left_buf_data.selected_item.path
    end
    if #lines > 0 then
      -- separator from the previous section
      table.insert(lines, "")
    end
    local section_sorted_files, sl = filetree.add_section(left_buf_data.conflicts_state, section,
      lines, left_buf_data.line_to_item,
      {{ " " .. section.title .. " ", "DiffviewFilePanelTitle" }, {string.format("(%d)", #section.contents), "DiffviewFilePanelCounter"} },
      section.contents, selected_path, left_buf_data.tree_expand_st[section.title], true, scroll_win ~= nil
    )
    if section_sorted_files then
      vim.list_extend(left_buf_data.sorted_files, vim.tbl_map(function(p) return {path = p, section = section.title} end, section_sorted_files))
    end
    if sl and selection_line == nil then
      selection_line = sl
    end
  end
  left_buf_data.line_to_path = line_to_path
  left_buf_data.line_to_extra = line_to_extra
  left_buf_data.line_to_section = line_to_section

  vim.bo[left_buf].modifiable = true
  vim.bo[left_buf].readonly = false
  filetree.render_lines(left_buf, lines)
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].readonly = true
  if scroll_win and selection_line then
    vim.api.nvim_win_set_cursor(scroll_win, { selection_line, 0 })
  end
end

local function load_entry(left_buf, git_root, section, item)
  local left_buf_data = bufdata.get_data(left_buf)
  left_buf_data.selected_item = {section = section.title, path = item.path}
  if section.mid_sha then
    if left_buf_data.diff3_win == nil then
      -- whatever, give it any buf for now
      left_buf_data.diff3_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(left_buf_data.diff1_win), true, {
        split = "right",
        win = left_buf_data.diff1_win,
      })
    end
    tabcommon.win_load_buf(git_root, left_buf_data.diff3_win, item.path, section.mid_sha)
  elseif left_buf_data.diff3_win then
    vim.api.nvim_win_close(left_buf_data.diff3_win, false)
    left_buf_data.diff3_win = nil
  end
  if section.bottom_sha then
    if left_buf_data.diff4_win == nil then
      -- must close and reopen diff2 and diff3

      -- Save buffers of diff2 and diff3
      local buf2 = vim.api.nvim_win_get_buf(left_buf_data.diff2_win)
      local buf3 = vim.api.nvim_win_get_buf(left_buf_data.diff3_win)
      vim.bo[buf2].bufhidden = "hide"
      vim.bo[buf3].bufhidden = "hide"
      vim.api.nvim_win_close(left_buf_data.diff2_win, false)
      vim.api.nvim_win_close(left_buf_data.diff3_win, false)

      -- create diff4 under diff1, give it any buf for now
      left_buf_data.diff4_win = vim.api.nvim_open_win(vim.api.nvim_win_get_buf(left_buf_data.diff1_win), true, {
        split = "below",
        win = left_buf_data.diff1_win,
      })

      -- recreate diff2 and diff3
      left_buf_data.diff3_win = vim.api.nvim_open_win(buf3, true, {
        split = "right",
        win = left_buf_data.diff1_win,
      })
      left_buf_data.diff2_win = vim.api.nvim_open_win(buf2, true, {
        split = "right",
        win = left_buf_data.diff3_win,
      })
      vim.bo[buf2].bufhidden = "wipe"
      vim.bo[buf3].bufhidden = "wipe"
    end
    tabcommon.win_load_buf(git_root, left_buf_data.diff3_win, item.path, section.mid_sha)
    tabcommon.win_load_buf(git_root, left_buf_data.diff4_win, item.path, section.bottom_sha)
  elseif left_buf_data.diff4_win then
    vim.api.nvim_win_close(left_buf_data.diff4_win, false)
    left_buf_data.diff4_win = nil
  end
  tabcommon.win_load_buf(git_root, left_buf_data.diff1_win, item.path, item.left_sha or section.left_sha)
  tabcommon.win_load_buf(git_root, left_buf_data.diff2_win, item.path, item.right_sha or section.right_sha)
  refresh_left_buf(left_buf)
end

local function left_buf_handle_enter(git_root, bufnr)
  filetree.handle_enter("title", true, git_root, bufnr, refresh_left_buf, load_entry)
end

function M.open_diff_tab(sections, git_root, reload_index, opts)
  vim.cmd("tabnew")

  vim.wo.spell = false

  local left_buf = vim.api.nvim_win_get_buf(0)
  local left_buf_data = bufdata.get_data(left_buf)

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].filetype = "NanodiffFileHistory"

  left_buf_data.sections = sections
  left_buf_data.tree_expand_st = {}

  local conflicts_section = sections[1]
  if sections[1].title == "Conflicts" then
    left_buf_data.conflicts_state = {conflicts = {}}
    conflicts.register_watchers(conflicts_section, left_buf_data.conflicts_state, function() refresh_left_buf(left_buf) end)
  end

  if reload_index then
    index_watcher.setup_index_watch(git_root, left_buf, function()
      async.run(function()
        local sections = reload_index(git_root)
        vim.schedule(function()
          left_buf_data.sections = sections
          refresh_left_buf(left_buf)
        end)
      end):raise_on_error()
    end)
  end

  refresh_left_buf(left_buf)

  local left_win = vim.api.nvim_get_current_win()

  -- Split to create the right window
  vim.cmd("rightbelow vsplit")
  local diff1_win = vim.api.nvim_get_current_win()

  -- Set left window width to 40 characters
  vim.api.nvim_win_set_width(left_win, 40)
  -- Lock the width against <C-W>= balancing
  vim.wo[left_win].winfixwidth = true

  -- Get the width of the remaining available space
  local total_remaining = vim.api.nvim_win_get_width(diff1_win)

  local half_width = math.floor(total_remaining / 2)
  vim.cmd("rightbelow " .. half_width .. "vsplit")
  local diff2_win = vim.api.nvim_get_current_win()

  left_buf_data.diff1_win = diff1_win
  left_buf_data.diff2_win = diff2_win

  -- Configure left window options (including winfixbuf)
  vim.wo[left_win].winfixbuf = true -- Lock window to this buffer
  vim.wo[left_win].number = false
  vim.wo[left_win].relativenumber = false
  vim.wo[left_win].signcolumn = "no"
  vim.wo[left_win].wrap = false

  vim.api.nvim_set_current_win(left_win)
  -- display the first entry immediately
  local first_nonempty_section = vim.iter(sections):find(function(s) return #s.contents > 0 end)
  if first_nonempty_section then
    -- due to sorting in the treeview (including sorting folders first), the first path
    -- in the section may not be the first in the treeview, so use line_to_path to
    -- find the first displayed path
    local lowest_idx_line_to_path
    local l2p = left_buf_data.line_to_item
    for i = 1, vim.api.nvim_buf_line_count(left_buf) do
      if l2p[i] and l2p[i] ~= nil and l2p[i].type == "path" then
        lowest_idx_line_to_path = i
        break
      end
    end
    load_entry(
      left_buf, git_root, first_nonempty_section,
      left_buf_data.line_to_item[lowest_idx_line_to_path])
    vim.api.nvim_win_set_cursor(left_win, { lowest_idx_line_to_path, 0 })
    -- Force the top of the buffer (line 1) to be visible at the top of the window
    vim.fn.winrestview({ topline = 1 })
  else
    -- no data, display nil buffers
    load_entry(
      left_buf, git_root, {}, {left_sha = "nil", right_sha = "nil"})
    vim.api.nvim_win_set_cursor(left_win, { 1, 0 })
  end

  vim.api.nvim_buf_set_name(left_buf, "Nanodiff Diff")

  vim.keymap.set('n', '<CR>', function() left_buf_handle_enter(git_root, left_buf) end, {
    noremap = true,
    silent = true,
    buffer = left_buf
  })

  if opts.shortcuts.fwd then
    vim.keymap.set('n', opts.shortcuts.bwd, function()
      vim.api.nvim_win_call(diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })

    vim.keymap.set('n', opts.shortcuts.fwd, function()
      vim.api.nvim_win_call(diff1_win, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = left_buf })

    vim.keymap.set('n', opts.shortcuts.prev_file, function()
      filetree.prev_file("title", "items", left_buf, git_root, function(bufnr) refresh_left_buf(bufnr, left_win) end, load_entry)
    end, { noremap = true, silent = true, buffer = left_buf })

    vim.keymap.set('n', opts.shortcuts.next_file, function()
      filetree.next_file("title", "items", left_buf, git_root, function(bufnr) refresh_left_buf(bufnr, left_win) end, load_entry)
    end, { noremap = true, silent = true, buffer = left_buf })
  end

  return left_buf
end

return M
