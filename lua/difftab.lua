local tree = require('tree')

local M = {}

-- TODO duplicated. try to share in some "git.lua" file
local async = vim.async
local async_sys = async.wrap(3, vim.system)

-- TODO wipe? TODO reuse buffer if existing?
local function win_load_disk_file(winnr, path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_win_set_buf(winnr, bufnr)
  vim.wo[winnr].diff = true
  vim.wo[winnr].scrollbind = true
end

local function win_load_sha_file(winnr, git_root, path, sha)
  local fname_without_path = vim.fs.basename(path)
  local bufname = string.format("git://%s/%s", sha, fname_without_path)
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr ~= -1 then
    vim.api.nvim_win_set_buf(winnr, bufnr)

    vim.wo[winnr].diff = true
    vim.wo[winnr].scrollbind = true
  else
    async.run(function()
      local contents = async_sys({"git", "show", sha .. ":" .. path}, {cwd = git_root}).stdout
      vim.schedule(function()
        local bufnr = vim.api.nvim_create_buf(true, false) -- listed, not scratch
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(contents, "[\r\n]"))

        vim.api.nvim_buf_set_name(bufnr, bufname)

        vim.bo[bufnr].readonly = true
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("filetype detect")
        end)
        vim.bo[bufnr].readonly = true
        vim.bo[bufnr].modified = false
        vim.bo[bufnr].modifiable = false

        vim.api.nvim_win_set_buf(winnr, bufnr)

        vim.wo[winnr].diff = true
        vim.wo[winnr].scrollbind = true
      end)
    end):raise_on_error()
  end
end

local function win_load_buf(git_root, winnr, path, sha)
  vim.wo[winnr].diff = false
  vim.wo[winnr].scrollbind = false
  if sha == "disk" then
    win_load_disk_file(winnr, path)
  else
    win_load_sha_file(winnr, git_root, path, sha)
  end
end

local function left_buf_handle_enter(git_root, bufnr)
  local line = vim.fn.line('.') + 1

  local section_line = line
  local section
  while section_line > 0 do
    section = vim.b[bufnr].line_to_section[section_line] 
    if section ~= vim.NIL then
      break
    end
    section_line = section_line - 1
  end
  print("section: " .. vim.inspect(section))

  local path = vim.b[bufnr].line_to_path[line] 
  print("path: " .. vim.inspect(path))

  if path ~= vim.NIL then
    win_load_buf(git_root, vim.b.diff1_win, path, section.left_sha)
    win_load_buf(git_root, vim.b.diff2_win, path, section.right_sha)
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

  vim.keymap.set('n', '<CR>', function() left_buf_handle_enter(git_root, left_buf) end, {
    noremap = true,
    silent = true,
    buffer = left_buf
  })

  return {
    left_buf = left_buf,
    left_win = left_win,
    right_win = right_win,
  }
end

return M
