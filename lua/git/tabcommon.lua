local async = vim.async
local io_helpers = require("core.io_helpers")
local devicons = require("nvim-web-devicons")
local difflayout = require("core.difflayout")
local tabdata = require("core.tabdata")
local filetree = require("core.filetree")

local M = {}

local FILE_SIZE_LIMIT_BYTES = 1 * 1024 * 1024; -- 1Mb

function M.register_files_shortcuts(opts)
  local function set_shortcut(shortcut, fn)
    local prev = vim.fn.maparg(shortcut, "n", false, true)
    vim.keymap.set("n", shortcut, fn)
    return prev
  end

  local function reset_shortcut(prev, shortcut)
    if prev and not vim.tbl_isempty(prev) then
      vim.fn.mapset(prev)
    else
      pcall(vim.keymap.del, "n", shortcut)
    end
  end

  -- option name -> window field in tabdata
  local targets = {
    { "focus_first_file",  "diff1_win" },
    { "focus_second_file", "diff2_win" },
    { "focus_third_file",  "diff3_win" },
    { "focus_fourth_file", "diff4_win" },
  }

  for _, t in ipairs(targets) do
    local name, win_field = t[1], t[2]
    local lhs = opts.shortcuts[name]
    if lhs ~= nil then
      tabdata.add_tab_enter_leave(
        function()
          local data = tabdata.get_data()
          data.previous_shortcuts = data.previous_shortcuts or {}
          data.previous_shortcuts[name] = set_shortcut(lhs, function()
            local win = tabdata.get_data()[win_field]
            if win and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_set_current_win(win)
            end
          end)
        end,
        function()
          local prev = (tabdata.get_data().previous_shortcuts or {})[name]
          reset_shortcut(prev, lhs)
        end)
    end
  end

  -- special handling for focus_panel which may focus the commits sub-panel in revspec mode
  if opts.shortcuts.focus_panel ~= nil then
    local lhs = opts.shortcuts.focus_panel 
    tabdata.add_tab_enter_leave(
      function()
        local data = tabdata.get_data()
        data.previous_shortcuts = data.previous_shortcuts or {}
        data.previous_shortcuts.focus_panel = set_shortcut(lhs, function()
          local win = tabdata.get_data().left_win
          local selection_grid = tabdata.get_data().selection_grid 
          if selection_grid ~= nil and selection_grid == "commits" then
            win = tabdata.get_data().left_bottom_win
          end
          if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_set_current_win(win)
          end
        end)
      end,
      function()
        local prev = (tabdata.get_data().previous_shortcuts or {}).focus_panel
        reset_shortcut(prev, lhs)
      end)
    end
end

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
  path = vim.fs.joinpath(git_root, path)
  -- use realpath to resolve symlinks, git grep returns error code 1 for symlinks
  -- if realpath return nil, the file doesn't exist, possible if we're looking at another branch
  path = vim.uv.fs_realpath(path) or path
  path = vim.fs.relpath(git_root, path)
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

function M.tree_render_item(prefix, item, is_selected, extra, conflicts_state, extra_icon)
  local path_hl = is_selected and "NanodiffFilePanelSelected" or nil
  local status_hl = nil
  if item.status == "A" or item.status == "?" then
    status_hl = "NanodiffAdd"
  elseif item.status == "D" then
    status_hl = "NanodiffDelete"
  end
  local icon, icon_hl_group = devicons.get_icon(item.path, extension, { default = true })
  local diffstat_prefix = " "
  local diffstat_hl_suffix = "+right_align"
  if item.status == "U" then
    -- git conflict: don't display the +- diffstat, rather the number of conflicts
    line_info = {
      {"│", "NanodiffNonText"},
      {string.format("%s  ", prefix), nil},
      {item.status, status_hl},
      {" ", nil},
      {icon .. " ", icon_hl_group},
      {item.path .. " ", path_hl},
      {conflicts_state.conflicts[extra.item_full_path] ~= nil
        and " " .. #conflicts_state.conflicts[extra.item_full_path]
        or "",
      "NanodiffConflicts+right_align"},
    }
  elseif item.orig_path then
    line_info = {
      {"│", "NanodiffNonText"},
      {string.format("%s  ", prefix), nil},
      {item.status, status_hl},
      {" ", nil},
      {icon .. " ", icon_hl_group},
      {item.orig_path, nil},
      {" -> ", nil},
      {item.path .. diffstat_prefix, path_hl},
    }
    if extra_icon then
      table.insert(line_info, {extra_icon, "NanodiffFilePanelSelected+right_align"})
    end
    if item.added ~= nil and item.added ~= 0 then
      table.insert(line_info, {"+" .. item.added, "NanodiffAdd" .. diffstat_hl_suffix})
    end
    if item.deleted ~= nil and item.deleted ~= 0 then
      table.insert(line_info, {"-" .. item.deleted,  "NanodiffDelete" .. diffstat_hl_suffix})
    end
  else
    line_info = {
      {"│", "NanodiffNonText"},
      {string.format("%s  ", prefix), nil},
      {item.status, status_hl},
      {" ", nil},
      {icon .. " ", icon_hl_group},
      {item.path .. diffstat_prefix, path_hl},
    }
    if extra_icon then
      table.insert(line_info, {extra_icon, "NanodiffFilePanelSelected+right_align"})
    end
    if item.added ~= nil and item.added ~= 0 then
      table.insert(line_info, {"+" .. item.added, "NanodiffAdd" .. diffstat_hl_suffix})
    end
    if item.deleted ~= nil and item.deleted ~= 0 then
      table.insert(line_info, {"-" .. item.deleted,  "NanodiffDelete" .. diffstat_hl_suffix})
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

function M.add_fwd_bwd_scroll(ft, ft_st, window_list, opts)
  local panel_buf = ft_st.bufnr
  local tab_data = tabdata.get_data()
  if opts.shortcuts.scroll_backward then
    vim.keymap.set('n', opts.shortcuts.scroll_backward, function()
      -- scrolling is a nop on an empty buffer, apply to the non-empty buffer if there's one
      local w = windows_prefer_non_null_buffer(window_list)
      vim.api.nvim_win_call(w, function()
        vim.cmd("normal! " .. vim.keycode("<C-b>"))
      end)
    end, { noremap = true, silent = true, buf = panel_buf })
  end

  if opts.shortcuts.scroll_forward then
    vim.keymap.set('n', opts.shortcuts.scroll_forward, function()
      -- scrolling is a nop on an empty buffer, apply to the non-empty buffer if there's one
      local w = windows_prefer_non_null_buffer(window_list)
      vim.api.nvim_win_call(w, function()
        vim.cmd("normal! " .. vim.keycode("<C-f>"))
      end)
    end, { noremap = true, silent = true, buf = panel_buf })
  end

  if opts.shortcuts.jump_to_first then
    vim.keymap.set('n', opts.shortcuts.jump_to_first, function()
      for i = 1, vim.api.nvim_buf_line_count(ft_st.bufnr) do
        if ft_st.line_to_item[i] ~= nil and ft_st.line_to_item[i].type == "path" then
          vim.api.nvim_win_set_cursor(0, {i, 0})
          filetree.handle_enter( ft, ft_st)
          return
        end
      end
    end, { noremap = true, silent = true, buf = panel_buf })
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

function M.refresh_from_iterator(log_iterator, on_done, on_update)
  local is_first_render = true
  local tab_data = tabdata.get_data()
  local log = {}

  local task = async.run(function()
    for commits in log_iterator do
      vim.list_extend(log, commits)
      tab_data.log_count = #log
      vim.schedule(function()
        if on_update then
          on_update(log)
        else
          filetree.set_contents(tab_data.ft, tab_data.ft_st, log, {
            focus_selected = is_first_render,
            expand_first_section = is_first_render,
          })
        end
        is_first_render = false
      end)
      -- async.sleep(0)
    end
    if #log == 0 then
      -- empty log: the loop rendered nothing, still clear the previous contents
      tab_data.log_count = 0
      vim.schedule(function()
        if on_update then
          on_update(log)
        else
          filetree.set_contents(tab_data.ft, tab_data.ft_st, log)
        end
      end)
    end
    if on_done then
      vim.schedule(function() on_done(log) end)
    end
  end):raise_on_error()

  tabdata.add_cleanup(function()
    pcall(function()
      task:close()
    end)
  end)
end

function M.render_commit_section(section, has_selection, icon, opts)
  local title = section.subject
  local title_hl = nil
  local ref = section.ref_log or section.hash
  local max_length_author = opts.panel_width() - #ref - #section.date - 4
  local author_name = section.author_name
  if #author_name > max_length_author then
    author_name = string.sub(author_name, 1, max_length_author - 1) .. "…"
  end
  if has_selection then
    title_hl = "NanodiffFilePanelTitle" 
  end
  local default_icon = " "
  if #section.parents > 1 then
    default_icon = " "
  end
  local ref_names = nil
  if section.ref_names ~= nil and #section.ref_names > 0 then
    ref_names = section.ref_names
      :gsub("tag: ", "󰓹 ")
      :gsub("HEAD %-> ", "󰉳 ")
    if ref_names == section.ref_names then
      -- none of the patterns matched, prepend a "ref" icon
      ref_names = " " .. ref_names
    end
    ref_names = ref_names
      :gsub("HEAD", " ")
  end
  -- required_height in difftab depends on the number of rows returned here
  return vim.tbl_filter(function(kv) return kv[1][1] ~= nil end, {{
    { icon or default_icon, "NanodiffCommitLine" },
    { title .. " ", title_hl },
  }, {
    { ref_names, "NanodiffRef" },
  }, {
    { "¦ ", "NanodiffCommitLine"},
    { author_name, "NanodiffName"},
    { " " .. section.date, "NanodiffDim"},
    {ref, "NanodiffHash+right_align"},
  }})
end

return M
