local async = vim.async
local io_helpers = require("core.io_helpers")
local devicons = require("nvim-web-devicons")
local difflayout = require("core.difflayout")

local M = {}

local FILE_SIZE_LIMIT_BYTES = 1 * 1024 * 1024; -- 1Mb

local function win_load_sha_file(winnr, git_root, path, sha, winbar)
  local bufname = string.format("nanogit://%s/%s", sha, path)
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr ~= -1 then
    vim.api.nvim_win_set_buf(winnr, bufnr)
  else
    -- create the buffer immediately to prevent races
    local bufnr = vim.api.nvim_create_buf(true, false) -- listed, not scratch
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].buftype = "nofile"
    vim.api.nvim_buf_set_name(bufnr, bufname)

    async.run(function()
      -- gsub: remove extra newline from git show
      local contents = io_helpers.run_cmd({"git", "show", sha .. ":" .. path}, {cwd = git_root})
        :gsub("\r\n$", ""):gsub("\n$", ""):gsub("\r$", "") -- remove final line ending

      contents = contents:gsub("\r\n", "\n"):gsub("\r", "\n") -- normalize to \n
      local lines = vim.split(contents, "\n", { plain = true })

      vim.schedule(function()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        vim.bo[bufnr].readonly = true
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("filetype detect")
        end)
        vim.bo[bufnr].readonly = true
        vim.bo[bufnr].modified = false
        vim.bo[bufnr].modifiable = false

        vim.api.nvim_win_set_buf(winnr, bufnr)
        if winbar ~= nil then
          vim.wo[winnr].winbar = winbar
        end
      end)
    end):raise_on_error()
  end
end

--check if a file is binary using only git, lifted and modified from diffview.nvim
--@return boolean -- True if the file was binary for the given rev, or it didn't exist.
local function is_binary(git_root, path, rev)
  -- -I ignore binary files, -e ., match any character (for non-binary files)
  local cmd = { "git", "grep", "-I", "--name-only", "-e", "." }
  if rev == "disk" then
    cmd[#cmd+1] = "--untracked"
    cmd[#cmd+1] = "--no-exclude-standard"
  elseif rev == ":0" then
    cmd[#cmd+1] = "--cached"
  else
    cmd[#cmd+1] = rev
  end
  vim.list_extend(cmd, {"--", path})
  local res = io_helpers.async_sys(cmd, { cwd = git_root })
  return res.code ~= 0
end

local function blob_size(git_root, path, rev)
  if rev == "disk" then
    local stat = vim.uv.fs_stat(git_root .. "/" .. path)
    return stat and stat.size or 0
  else
    local res = io_helpers.async_sys({ "git", "cat-file", "-s", rev .. ":" .. path }, { cwd = git_root })
    return (res.code == 0) and tonumber(res.stdout) or 0
  end
end

function M.win_load_buf(git_root, winnr, path, sha, winbar)
  vim.api.nvim_set_option_value('diff', false, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('scrollbind', false, { win = winnr, scope = 'local' })

  if sha == "nil" then
    difflayout.win_load_null_file(winnr)
    -- if we don't force the line number to zero, neovim
    -- might reposition the file at the last-remembered line number
    -- for that file
    vim.api.nvim_win_set_cursor(winnr, { 1, 0 })
    if winbar ~= nil then
      vim.wo[winnr].winbar = winbar
    end
  else
    async.run(function()
      local is_display = true
      local blob_size = blob_size(git_root, path, sha)
      if blob_size > FILE_SIZE_LIMIT_BYTES then
        is_display = false
      else
        is_display = not is_binary(git_root, path, sha)
      end
      vim.schedule(function()
        if not is_display then
          difflayout.win_load_null_file(winnr)
          if winbar ~= nil then
            vim.wo[winnr].winbar = winbar
          end
        elseif sha == "disk" then
          async.run(function()
            -- the path may be a git path, but maybe neovim's current folder is not
            -- the repo's root
            if not vim.uv.fs_access(path, "R") then
              local git_root = vim.trim(io_helpers.run_cmd({"git", "rev-parse", "--show-toplevel"}, {cwd = git_root}))
              path = vim.fs.joinpath(git_root, path)
            end
            vim.schedule(function()
              difflayout.win_load_disk_file(winnr, path)
              if winbar ~= nil then
                vim.wo[winnr].winbar = winbar
              end
            end)
          end):raise_on_error()
        else
          win_load_sha_file(winnr, git_root, path, sha, winbar)
        end
        -- if we don't force the line number to zero, neovim
        -- might reposition the file at the last-remembered line number
        -- for that file
        vim.api.nvim_win_set_cursor(winnr, { 1, 0 })
      end)
    end):raise_on_error()
  end
end

function M.tree_render_item(prefix, item, is_selected, extra, conflicts_state)
  local path_hl = is_selected and "DiffviewFilePanelSelected" or nil
  local status_hl = item.left_sha == "nil" and "DiffviewFilePanelInsertions" or nil -- untracked files
  local icon, icon_hl_group = devicons.get_icon(item.path, extension, { default = true })
  if item.status == "U" then
    -- git conflict: don't display the +- diffstat, rather the number of conflicts
    line_info = {
      {item.status, status_hl},
      {string.format("%s ", prefix), nil},
      {icon .. " ", icon_hl_group},
      {item.path .. " ", path_hl},
      {conflicts_state.conflicts[extra.item_full_path] ~= nil
        and " " .. #conflicts_state.conflicts[extra.item_full_path]
        or "",
      "DiffviewFilePanelConflicts+right_align"},
    }
  elseif item.orig_path then
    line_info = {
      {item.status, status_hl},
      {string.format("%s ", prefix), nil},
      {icon .. " ", icon_hl_group},
      {item.orig_path, nil},
      {" -> ", nil},
      {item.path, path_hl},
      {" +" .. (item.added or 0), "DiffviewFilePanelInsertions+right_align"},
      {" -" .. (item.deleted or 0), "DiffviewFilePanelDeletions+right_align"},
    }
  else
    line_info = {
      {item.status, status_hl},
      {string.format("%s ", prefix), nil},
      {icon .. " ", icon_hl_group},
      {item.path, path_hl},
    }
    if item.added ~= nil or item.deleted ~= nil then
      table.insert(line_info, {"+" .. (item.added or 0), "DiffviewFilePanelInsertions+right_align"})
      table.insert(line_info, {"-" .. (item.deleted or 0),  "DiffviewFilePanelDeletions+right_align"})
    end
  end
  return line_info
end

return M
