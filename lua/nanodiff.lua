local async = vim.async

local async_sys = async.wrap(3, vim.system)

local M = {}

-- merge empty subfolders together.. a single "a/b" level
-- and sort files & folders in the tree
local function compress_and_sort(nodes)
  if not nodes then return end

  for _, n in ipairs(nodes) do
    compress_and_sort(n.subs)
    while n.subs and #n.subs == 1 and n.subs[1].is_dir do
      n.path, n.subs = n.path .. "/" .. n.subs[1].path, n.subs[1].subs
    end
  end

  -- sort folders before files
  table.sort(nodes, function(a, b)
    if (a.is_dir or false) ~= (b.is_dir or false) then
      return a.is_dir == true
    end
    return a.path < b.path
  end)

  return nodes
end

local function insert_item(tree, parts, item, depth)
  depth = depth or 1
  local part = parts[depth]

  -- find existing directory/node at current level
  local target
  for _, node in ipairs(tree) do
    if node.path == part then target = node break end
  end

  -- didn't meet that subdirectory yet, create it
  if not target then
    target = { path = part }
    table.insert(tree, target)
  end

  if depth == #parts then
    -- Copy all original item fields onto the leaf
    -- can't reuse the item because we need a different path, we'd have to mutate
    for k, v in pairs(item) do
      if k == "path" then target.path = part else target[k] = v end
    end
  else
    target.is_dir, target.subs = true, target.subs or {}
    insert_item(target.subs, parts, item, depth + 1)
  end
end

local function build_tree(items)
  local root = {}
  for _, item in ipairs(items or {}) do
    local parts = {}
    for part in item.path:gmatch("[^/]+") do table.insert(parts, part) end
    insert_item(root, parts, item)
  end
  return compress_and_sort(root)
end

local function render_tree(lines, line_to_path, tree, depth)
  local prefix = string.rep(" ", depth*2)
  for _, item in ipairs(tree) do
    if item.is_dir then
      table.insert(lines, prefix .. item.path)
      render_tree(lines, line_to_path, item.subs, depth + 1)
    else
      local display_str, target_path
      if item.orig_path then
        display_str = string.format("%s[%s] %s -> %s", prefix, item.status, item.orig_path, item.path)
        target_path = item.path
      else
        display_str = string.format("%s[%s] %s", prefix, item.status, item.path)
        target_path = item.path
      end
      table.insert(lines, display_str)
      line_to_path[#lines] = target_path
    end
  end
end

local function add_section(lines, line_to_path, header, items)
  if #items == 0 then return end

  local tree = build_tree(items, 0)

  table.insert(lines, "== " .. header .. " ==")
  render_tree(lines, line_to_path, tree, 1)
  table.insert(lines, "") -- Empty line separator
end

local function open_status_tab(sections)
  vim.cmd("tabnew")

  -- 2. Create an unlisted, scratch buffer for the left side
  local left_buf = vim.api.nvim_create_buf(false, true)

  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false

  local lines = {}
  vim.b[left_buf].line_to_path = {}
  for _, section in ipairs(sections) do
    add_section(lines, vim.b[left_buf].line_to_path, section.title, section.contents)
  end

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

local function get_diff_status(git_root)
  local current_commit =  async_sys({"git", "rev-parse", "HEAD"}, {cwd = git_root}).stdout

  local output = async_sys({"git", "status", "--porcelain=v2"}, {cwd = git_root})

  local staged = {}
  local unstaged = {}
  local untracked = {}

  for line in output.stdout:gmatch("[^\r\n]+") do
    local prefix = line:sub(1, 1)

    if prefix == "1" then
      -- Ordinary changes: "1 <XY> sub mH mI mW hH hI <path>"
      local xy, path = line:match("^1%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
      if xy then
        local x = xy:sub(1, 1) -- Staged
        local y = xy:sub(2, 2) -- Unstaged

        if x ~= "." then
          table.insert(staged, { path = path, status = x })
        end
        if y ~= "." then
          table.insert(unstaged, { path = path, status = y })
        end
      else
        print("couldn't match line: " .. line)
      end

    elseif prefix == "2" then
      -- Renamed/Copied changes: "2 <XY> sub mH mI mW hH hI X score <path>\t<origPath>"
      local xy, paths = line:match("^2%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(.+)$")
      if xy and paths then
        local x = xy:sub(1, 1)
        local y = xy:sub(2, 2)

        -- Paths are tab-separated: "new_path\told_path"
        local path, orig_path = paths:match("^([^\t]+)\t(.+)$")

        if x == "R" or x == "C" then
          table.insert(staged, {
            path = path,
            orig_path = orig_path,
            status = x,
          })
        elseif x ~= "." then
          table.insert(staged, { path = path, status = x })
        end

        if y ~= "." then
          table.insert(unstaged, { path = path, status = y })
        end
      end

    elseif prefix == "?" then
      -- Untracked files: "? <path>"
      local path = line:match("^%?%s+(.+)$")
      if path then
        table.insert(untracked, { path = path, status = "?" })
      end
    end
  end

  return {
    {title = "Staged", contents = staged, left_sha = current_commit, right_sha = "stage"},
    {title = "Unstaged", contents = unstaged, left_sha = current_commit, right_sha = "disk"},
    {title = "Untracked", contents = untracked, left_sha = nil, right_sha = "disk"},
  }
end

function M.status()
  async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {text = true}).stdout)
    local status = get_diff_status(git_root)
    vim.schedule(function() open_status_tab(status) end)
  end):raise_on_error()
end

local function get_diff_revspec(git_root, revspec)
  local commits_stdout = async_sys({"git", "rev-parse", "--revs-only", "--no-flags", revspec}, {text = true, cwd = git_root}).stdout
  local left_sha, right_sha = unpack(vim.split(commits_stdout:gsub("%^", ""), "%s+", { trimempty = true }))

  local output = vim.trim(async_sys({"git", "diff", "--name-status", "-M", revspec}, {text = true, cwd = git_root}).stdout)

  local results = {}

  for line in output:gmatch("[^\r\n]+") do
    -- Split line by tab characters
    local parts = {}
    for part in line:gmatch("[^\t]+") do
      table.insert(parts, part)
    end

    if #parts >= 2 then
      local raw_code = parts[1]
      local code_char = raw_code:sub(1, 1)
      local path = parts[2]
      local orig_path = nil
      local status

      if code_char == "A" then
        status = "added"
      elseif code_char == "D" then
        status = "deleted"
      elseif code_char == "M" then
        status = "modified"
      elseif code_char == "R" then
        status = "renamed"
        orig_path = parts[2]
        path = parts[3]
      elseif code_char == "C" then
        status = "copied"
        orig_path = parts[2]
        path = parts[3]
      else
        status = "unknown"
      end

      table.insert(results, {
        path = path,
        orig_path = orig_path,
        status = status,
      })
    end
  end

  return {{
    title = "Changes",
    contents = status,
    left_sha = left_sha,
    right_sha = right_sha,
    contents = results,
  }}
end

function M.revspec(revspec)
  async.run(function()
    local git_root = vim.trim(async_sys({"git", "rev-parse", "--show-toplevel"}, {text = true}).stdout)
    local contents = get_diff_revspec(git_root, revspec)
    vim.schedule(function() open_status_tab(contents) end)
  end):raise_on_error()
end

M._private = {
  build_tree = build_tree,
}

return M
