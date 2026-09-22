-- TODO duplicated. try to share in some "git.lua" file
local async = vim.async
local async_sys = async.wrap(3, vim.system)

local M = {}

local function win_set_diff(winnr)
  vim.wo[winnr].diff = true
  vim.wo[winnr].scrollbind = true
  vim.wo[winnr].foldmethod = "diff"
  vim.wo[winnr].foldlevel = 0 -- Collapses all unchanged folds by default
  vim.wo[winnr].foldenable = true
end

-- also see https://github.com/sindrets/diffview.nvim/issues/2
local function protect_buffer_from_floats(buf)
  local group = vim.api.nvim_create_augroup("NanodiffFloatProtect_" .. buf, { clear = true })

  vim.api.nvim_create_autocmd("WinLeave", {
    group = group,
    buffer = buf, -- Strictly scoped to your diff buffer handle!
    callback = function()
      -- Defer briefly so Neovim registers the newly created float in the window list
      vim.schedule(function()
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          local config = vim.api.nvim_win_get_config(win)
          
          -- If a floating window exists, make sure diff is turned off for it
          if config.relative and config.relative ~= "" then
            if vim.wo[win].diff then
              vim.wo[win].diff = false
              vim.wo[win].scrollbind = false
              vim.wo[win].cursorbind = false
            end
          end
        end
      end)
    end,
  })
end

-- TODO bufhidden=wipe?
local function win_load_disk_file(winnr, path)
  local bufnr = vim.fn.bufadd(path) -- will reuse existing matching buffers
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  protect_buffer_from_floats(bufnr)
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

function M.win_load_buf(git_root, winnr, path, sha)
  vim.wo[winnr].diff = false
  vim.wo[winnr].scrollbind = false
  if sha == "disk" then
    win_load_disk_file(winnr, path)
  else
    win_load_sha_file(winnr, git_root, path, sha)
  end
end

return M
