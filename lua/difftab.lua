local tree = require('tree')

local M = {}

function M.open_diff_tab(sections)
  vim.cmd("tabnew")

  -- 2. Create an unlisted, scratch buffer for the left side
  local left_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false

  local lines = {}
  local line_to_path = {}
  local line_to_section = {}
  for _, section in ipairs(sections) do
    line_to_section[#lines+1] = section
    tree.add_section(lines, line_to_path, section.title, section.contents)
  end
  vim.b[left_buf].line_to_path = line_to_path
  vim.b[left_buf].line_to_section = line_to_section

  if lines and #lines > 0 then
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, lines)
  end

  -- Lock buffer against accidental modifications
  vim.bo[left_buf].modifiable = false
  vim.bo[left_buf].readonly = true

  -- 4. Assign scratch buffer to the current window
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  -- 5. Split to create the right window
  vim.cmd("rightbelow vsplit")
  local right_win = vim.api.nvim_get_current_win()

  -- 6. Set left window width to 40 characters
  vim.api.nvim_win_set_width(left_win, 40)

  -- 7. Configure left window options (including winfixbuf)
  vim.wo[left_win].winfixbuf = true -- Lock window to this buffer
  vim.wo[left_win].number = false
  vim.wo[left_win].relativenumber = false
  vim.wo[left_win].signcolumn = "no"
  vim.wo[left_win].wrap = false

  return {
    left_buf = left_buf,
    left_win = left_win,
    right_win = right_win,
  }
end

return M
