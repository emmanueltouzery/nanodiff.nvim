local filetree = require('filetree')
local tabcommon = require('tabcommon')

local M = {}

local function load_entry(section, path)
  tabcommon.win_load_buf(git_root, vim.b.diff1_win, path, section.left_sha)
  tabcommon.win_load_buf(git_root, vim.b.diff2_win, path, section.right_sha)
end

local function left_buf_handle_enter(git_root, bufnr)
  local line = vim.fn.line('.')

  local section_line = line
  local section
  while section_line > 0 do
    section = vim.b[bufnr].line_to_section[section_line] 
    if section ~= vim.NIL and section ~= nil then
      break
    end
    section_line = section_line - 1
  end

  local path = vim.b[bufnr].line_to_path[line] 

  if path ~= vim.NIL and path ~= nil then
    load_entry(section, path)
  end
end

function M.open_diff_tab(sections, git_root)
  vim.cmd("tabnew")

  -- Create an unlisted, scratch buffer for the left side
  local left_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false

  local lines = {}
  local line_to_path = {}
  local line_to_section = {}
  for _, section in ipairs(sections) do
    line_to_section[#lines+1] = section
    filetree.add_section(lines, line_to_path, {{ " " .. section.title, "DiffviewFilePanelTitle" }}, section.contents)
  end
  vim.b[left_buf].line_to_path = line_to_path
  vim.b[left_buf].line_to_section = line_to_section

  filetree.render_lines(left_buf, lines)

  -- Lock buffer against accidental modifications
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].readonly = true

  -- Assign scratch buffer to the current window
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  -- Split to create the right window
  vim.cmd("rightbelow vsplit")
  local diff1_win = vim.api.nvim_get_current_win()

  -- Set left window width to 40 characters
  vim.api.nvim_win_set_width(left_win, 40)

  -- Get the width of the remaining available space
  local total_remaining = vim.api.nvim_win_get_width(diff1_win)

  local half_width = math.floor(total_remaining / 2)
  vim.cmd("rightbelow " .. half_width .. "vsplit")
  local diff2_win = vim.api.nvim_get_current_win()

  vim.b[left_buf].diff1_win = diff1_win
  vim.b[left_buf].diff2_win = diff2_win

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
    local lowest_idx_line_to_path = math.min(unpack(vim.tbl_keys(line_to_path)))
    load_entry(first_nonempty_section, line_to_path[lowest_idx_line_to_path])
  end

  vim.keymap.set('n', '<CR>', function() left_buf_handle_enter(git_root, left_buf) end, {
    noremap = true,
    silent = true,
    buffer = left_buf
  })
end

return M
