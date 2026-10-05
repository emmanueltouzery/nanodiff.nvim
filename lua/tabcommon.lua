local async = vim.async
local io_helpers = require("io_helpers")

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

local function win_load_disk_file(winnr, path)
  async.run(function()
    -- the path may be a git path, but maybe neovim's current folder is not
    -- the repo's root
    if not vim.uv.fs_access(path, "R") then
      local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}))
      path = vim.fs.joinpath(git_root, path)
    end
    vim.schedule(function()
      local bufnr = vim.fn.bufadd(path) -- will reuse existing matching buffers
      if not vim.api.nvim_buf_is_loaded(bufnr) then
        -- we know it's our buffer since it's not loaded.
        -- wouldn't want to do that on the user's buffers
        vim.bo[bufnr].bufhidden = "wipe"
      end
      vim.fn.bufload(bufnr)
      vim.bo[bufnr].buflisted = true
      vim.api.nvim_win_set_buf(winnr, bufnr)
      win_set_diff(winnr)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "NanodiffDiskBufferLoaded",
        data = { path = path },
      })
    end)
  end):raise_on_error()
end

local function win_load_sha_file(winnr, git_root, path, sha)
  local bufname = string.format("git://%s/%s", sha, path)
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr ~= -1 then
    vim.api.nvim_win_set_buf(winnr, bufnr)
    win_set_diff(winnr)
  else
    async.run(function()
      -- gsub: remove extra newline from git show
      local contents = io_helpers.run_cmd({"git", "show", sha .. ":" .. path}, {cwd = git_root}):gsub("\r?\n$", "")
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
        vim.bo[bufnr].bufhidden = "wipe"

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
    vim.bo[bufnr].bufhidden = "wipe"
  end
  vim.api.nvim_win_set_buf(winnr, bufnr)
  win_set_diff(winnr)
end

function M.win_load_buf(git_root, winnr, path, sha)
  vim.wo[winnr].diff = false
  vim.wo[winnr].scrollbind = false
  if sha == "disk" then
    win_load_disk_file(winnr, path)
  elseif sha == "nil" then
    win_load_null_file(winnr)
  else
    win_load_sha_file(winnr, git_root, path, sha)
  end
end

return M
