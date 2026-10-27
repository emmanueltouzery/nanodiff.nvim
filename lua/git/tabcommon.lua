local async = vim.async
local io_helpers = require("core.io_helpers")
local devicons = require("nvim-web-devicons")
local difflayout = require("core.difflayout")
local tabdata = require("core.tabdata")

local M = {}

local FILE_SIZE_LIMIT_BYTES = 1 * 1024 * 1024; -- 1Mb

local function win_load_sha_file(winnr, git_root, path, sha, winbar, on_loaded)
  local bufname = string.format("nanodiff://%s/%s", sha, path)
  local bufnr = vim.fn.bufnr(bufname)
  if bufnr ~= -1 then
    vim.api.nvim_win_set_buf(winnr, bufnr)
    if on_loaded then on_loaded() end
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
        -- the buffer is wipe, may have been closed by now if the user moves
        -- between files quickly
        local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
        if ok then
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
        end
        -- even on failure, so we don't block the barrier
        if on_loaded then on_loaded() end
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

-- on_loaded (optional) is called once the buffer is displayed in the window
function M.win_load_buf(git_root, winnr, path, sha, winbar, on_loaded)
  vim.api.nvim_set_option_value('diff', false, { win = winnr, scope = 'local' })
  vim.api.nvim_set_option_value('scrollbind', false, { win = winnr, scope = 'local' })

  if sha == "nil" then
    difflayout.win_load_null_file(winnr, on_loaded)
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
          difflayout.win_load_null_file(winnr, on_loaded)
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
              difflayout.win_load_disk_file(winnr, path, on_loaded)
              if winbar ~= nil then
                vim.wo[winnr].winbar = winbar
              end
            end)
          end):raise_on_error()
        else
          win_load_sha_file(winnr, git_root, path, sha, winbar, on_loaded)
        end
        -- if we don't force the line number to zero, neovim
        -- might reposition the file at the last-remembered line number
        -- for that file
        vim.api.nvim_win_set_cursor(winnr, { 1, 0 })
      end)
    end):raise_on_error()
  end
end

function M.tree_render_item(prefix, item, is_selected, extra, conflicts_state, right_align_diffstat, extra_icon)
  local path_hl = is_selected and "DiffviewFilePanelSelected" or nil
  local status_hl = nil
  if item.status == "A" or item.status == "?" then
    status_hl = "DiffviewFilePanelInsertions"
  elseif item.status == "D" then
    status_hl = "DiffviewFilePanelDeletions"
  end
  local icon, icon_hl_group = devicons.get_icon(item.path, extension, { default = true })
  local diffstat_prefix = " "
  local diffstat_hl_suffix = ""
  if right_align_diffstat then
    diffstat_prefix = ""
    diffstat_hl_suffix = "+right_align"
  end
  if item.status == "U" then
    -- git conflict: don't display the +- diffstat, rather the number of conflicts
    line_info = {
      {"│", "DiffviewNonText"},
      {string.format("%s  ", prefix), nil},
      {item.status, status_hl},
      {" ", nil},
      {icon .. " ", icon_hl_group},
      {item.path .. " ", path_hl},
      {conflicts_state.conflicts[extra.item_full_path] ~= nil
        and " " .. #conflicts_state.conflicts[extra.item_full_path]
        or "",
      "DiffviewFilePanelConflicts+right_align"},
    }
  elseif item.orig_path then
    line_info = {
      {"│", "DiffviewNonText"},
      {string.format("%s  ", prefix), nil},
      {item.status, status_hl},
      {" ", nil},
      {icon .. " ", icon_hl_group},
      {item.orig_path, nil},
      {" -> ", nil},
      {item.path .. diffstat_prefix, path_hl},
    }
    if extra_icon then
      table.insert(line_info, {extra_icon, "DiffviewFilePanelSelected+right_align"})
    end
    if item.added ~= nil and item.added ~= 0 then
      table.insert(line_info, {"+" .. item.added, "DiffviewFilePanelInsertions" .. diffstat_hl_suffix})
    end
    if item.deleted ~= nil and item.deleted ~= 0 then
      table.insert(line_info, {"-" .. item.deleted,  "DiffviewFilePanelDeletions" .. diffstat_hl_suffix})
    end
  else
    line_info = {
      {"│", "DiffviewNonText"},
      {string.format("%s  ", prefix), nil},
      {item.status, status_hl},
      {" ", nil},
      {icon .. " ", icon_hl_group},
      {item.path .. diffstat_prefix, path_hl},
    }
    if extra_icon then
      table.insert(line_info, {extra_icon, "DiffviewFilePanelSelected+right_align"})
    end
    if item.added ~= nil and item.added ~= 0 then
      table.insert(line_info, {"+" .. item.added, "DiffviewFilePanelInsertions" .. diffstat_hl_suffix})
    end
    if item.deleted ~= nil and item.deleted ~= 0 then
      table.insert(line_info, {"-" .. item.deleted,  "DiffviewFilePanelDeletions" .. diffstat_hl_suffix})
    end
  end
  return line_info
end

local function window_contains_nil_buffer(w)
  local buf = vim.api.nvim_win_get_buf(w)
  return vim.api.nvim_buf_get_name(buf) == "nanodiff://null"
end

local function windows_prefer_non_null_buffer(window_list)
  return vim.iter(window_list):find(function(w) return not window_contains_nil_buffer(w) end) or window_list[1]
end

function M.add_fwd_bwd_scroll(panel_buf, window_list, opts)
  local tab_data = tabdata.get_data()
  if opts.shortcuts.scroll_backward then
    vim.keymap.set('n', opts.shortcuts.scroll_backward, function()
      -- scrolling is a nop on an empty buffer, apply to the non-empty buffer if there's one
      local w = windows_prefer_non_null_buffer(window_list)
      vim.api.nvim_win_call(w, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buffer = panel_buf })
  end

  if opts.shortcuts.scroll_forward then
    vim.keymap.set('n', opts.shortcuts.scroll_forward, function()
      -- scrolling is a nop on an empty buffer, apply to the non-empty buffer if there's one
      local w = windows_prefer_non_null_buffer(window_list)
      vim.api.nvim_win_call(w, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buffer = panel_buf })
  end
end

function M.windows_set_diff_if_needed(window_list)
  -- if there are two windows and one is the null buffer, diff mode is counter-productive:
  -- the non-empty buffer will be entirely tinted green and harder to read
  if #window_list > 2 or not vim.iter(window_list):any(window_contains_nil_buffer) then
    for _, winnr in ipairs(window_list) do
      difflayout.win_set_diff(winnr)
    end
  end
end

return M
