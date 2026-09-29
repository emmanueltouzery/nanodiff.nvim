local filetree = require('filetree')
local tabcommon = require('tabcommon')
local bufdata = require('bufdata')

local M = {}

local function refresh_left_buf(left_buf)
  local lines = {}
  local line_to_path = {}
  local line_to_extra = {}
  local line_to_section = {}
  local left_buf_data = bufdata.get_data(left_buf)
  for _, section in ipairs(left_buf_data.sections) do
    line_to_section[#lines+1] = section
    local selected_path = nil
    if left_buf_data.selected_item ~= nil and left_buf_data.selected_item.section == section.title then
      selected_path = left_buf_data.selected_item.path
    end
    if #lines > 0 then
      -- separator from the previous section
      table.insert(lines, "")
    end
    filetree.add_section(
      lines, line_to_path, line_to_extra,
      {{ " " .. section.title, "DiffviewFilePanelTitle" }}, section.contents,
      selected_path, left_buf_data.tree_expand_st[section.title], true
    )
  end
  left_buf_data.line_to_path = line_to_path
  left_buf_data.line_to_extra = line_to_extra
  left_buf_data.line_to_section = line_to_section

  vim.bo[left_buf].modifiable = true
  vim.bo[left_buf].readonly = false
  filetree.render_lines(left_buf, lines)
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].readonly = true
end

local function load_entry(left_buf, section, path, extra)
  local left_buf_data = bufdata.get_data(left_buf)
  left_buf_data.selected_item = {section = section.title, path = path}
  tabcommon.win_load_buf(git_root, left_buf_data.diff1_win, path, (extra or {}).left_sha or section.left_sha)
  tabcommon.win_load_buf(git_root, left_buf_data.diff2_win, path, (extra or {}).right_sha or section.right_sha)
  refresh_left_buf(left_buf)
end

local function left_buf_handle_enter(git_root, bufnr)
  local line = vim.fn.line('.')
  local bdata = bufdata.get_data(bufnr)

  local section_line = line
  local section
  while section_line > 0 do
    section = bdata.line_to_section[section_line] 
    if section ~= nil then
      break
    end
    section_line = section_line - 1
  end

  local path = bdata.line_to_path[line]
  local extra = bdata.line_to_extra[line]

  if section_line == line then
    if bdata.tree_expand_st[section.title] == nil then
      bdata.tree_expand_st[section.title] = {}
    end
    local prev_expanded = bdata.tree_expand_st[section.title].section_expanded
    if prev_expanded == nil then
      prev_expanded = true
    end
    bdata.tree_expand_st[section.title].section_expanded = not prev_expanded
    refresh_left_buf(bufnr)
  elseif path ~= nil then
    load_entry(bufnr, section, path, extra)
  end
end

function M.open_diff_tab(sections, git_root)
  vim.cmd("tabnew")

  vim.wo.spell = false

  -- Create an unlisted, scratch buffer for the left side
  local left_buf = vim.api.nvim_create_buf(false, true)
  local left_buf_data = bufdata.get_data(left_buf)

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false

  left_buf_data.sections = sections
  left_buf_data.tree_expand_st = {}

  refresh_left_buf(left_buf)

  -- Assign scratch buffer to the current window
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

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

  -- display the first entry immediately
  local first_nonempty_section = vim.iter(sections):find(function(s) return #s.contents > 0 end)
  if first_nonempty_section then
    -- due to sorting in the treeview (including sorting folders first), the first path
    -- in the section may not be the first in the treeview, so use line_to_path to
    -- find the first displayed path
    local lowest_idx_line_to_path
    local l2p = left_buf_data.line_to_path
    for i = 1, vim.api.nvim_buf_line_count(left_buf) do
      if l2p[i] and l2p[i] ~= vim.NIL and l2p[i] ~= nil then
        lowest_idx_line_to_path = i
        break
      end
    end
    local extra = left_buf_data.line_to_extra[lowest_idx_line_to_path]
    load_entry(
      left_buf, first_nonempty_section,
      left_buf_data.line_to_path[lowest_idx_line_to_path],
      extra)
  end

  vim.keymap.set('n', '<CR>', function() left_buf_handle_enter(git_root, left_buf) end, {
    noremap = true,
    silent = true,
    buffer = left_buf
  })
end

return M
