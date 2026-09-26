-- TODO duplicated. try to share in some "git.lua" file
local async = vim.async
local async_sys = async.wrap(3, vim.system)

local M = {}

local function win_set_diff(winnr)
  -- without scope=local any popups opening over the window will inherit the diff flag,
  -- completely breaking the diff
  vim.api.nvim_set_option_value('diff', true, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('scrollbind', true, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('foldmethod', 'diff', { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('foldlevel', 0, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('foldenable', true, { win = winnr, scope = 'local' })
end

-- TODO bufhidden=wipe?
local function win_load_disk_file(winnr, path)
  local bufnr = vim.fn.bufadd(path) -- will reuse existing matching buffers
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  vim.api.nvim_win_set_buf(winnr, bufnr)
  win_set_diff(winnr)
end

local function win_load_sha_file(winnr, git_root, path, sha)
  local fname_without_path = vim.fs.basename(path)
  local bufname = string.format("git://%s/%s", sha, fname_without_path)
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr ~= -1 then
    vim.api.nvim_win_set_buf(winnr, bufnr)
    win_set_diff(winnr)
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
        win_set_diff(winnr)
      end)
    end):raise_on_error()
  end
end

local function win_load_null_file(winnr)
  local bufname = "git://null"
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(true, false) -- listed, not scratch
    vim.api.nvim_buf_set_name(bufnr, bufname)
  end
  vim.api.nvim_win_set_buf(winnr, bufnr)
  win_set_diff(winnr)
end

function M.win_load_buf(git_root, winnr, path, sha)
  vim.wo[winnr].diff = false
  vim.wo[winnr].scrollbind = false
  if sha == "disk" then
    win_load_disk_file(winnr, path)
  elseif sha == nil then
    win_load_null_file(winnr)
  else
    win_load_sha_file(winnr, git_root, path, sha)
  end
end

return M
