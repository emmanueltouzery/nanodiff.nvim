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

local function render_tree(lines, line_to_path, tree, depth, full_path)
  local function path_append(root, child)
    if root == "" then
      return child
    else
      return root .. "/" .. child
    end
  end

  local prefix = string.rep(" ", depth*2)
  for _, item in ipairs(tree) do
    if item.is_dir then
      table.insert(lines, prefix .. item.path)
      render_tree(lines, line_to_path, item.subs, depth + 1, path_append(full_path, item.path))
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
      line_to_path[#lines+1] = path_append(full_path, target_path)
    end
  end
end

function M.add_section(lines, line_to_path, header, items)
  if #items == 0 then return end

  local tree = build_tree(items, 0)

  table.insert(lines, "== " .. header .. " ==")
  render_tree(lines, line_to_path, tree, 1, "")
  table.insert(lines, "") -- Empty line separator
end

return M
