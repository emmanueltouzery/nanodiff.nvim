local M = {}
local devicons = require'nvim-web-devicons'

-- local folder_closed = "",
local folder_open = " "
local ns_hl_id = vim.api.nvim_create_namespace("nanodiff_ui_highlights")

function M.render_lines(bufnr, lines)
  local lines_text = {}
  local highlights = {}

  for line_idx, line in ipairs(lines) do
    local line_0idx = line_idx - 1 -- Convert 1-based Lua index to 0-based Neovim index

    if type(line) == "string" then
      table.insert(lines_text, line)
    else
      local line_text = ""
      for _, chunk in ipairs(line) do
        local text = chunk[1]
        local hl_group = chunk[2]

        local start_byte = #line_text
        line_text = line_text .. text
        local end_byte = #line_text

        if hl_group then
          table.insert(highlights, {
            line = line_0idx,
            hl = hl_group,
            s = start_byte,
            e = end_byte,
          })
        end
      end
      table.insert(lines_text, line_text)
    end
  end

  vim.api.nvim_buf_clear_namespace(0, ns_hl_id, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines_text)

  for _, item in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, ns_hl_id, item.hl, item.line, item.s, item.e)
  end
end

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

local function render_tree(lines, line_to_item, selected_path, section_expand_st, tree, depth, full_path)
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
      if section_expand_st ~= nil then
      end
      local full_path = path_append(full_path, item.path)
      line_to_item[#lines+1] = {type = "dir", path = full_path}
      -- 3 spaces for the prefix where files have the status [M] and so on
      table.insert(lines, {
        {"   " .. prefix, nil},
        {folder_open, "DiffviewFolderSign"},
        {item.path, "DiffviewFolderName"},
      })
      if section_expand_st.folder_expanded == nil or section_expand_st.folder_expanded[full_path] ~= false then
        render_tree(lines, line_to_item, selected_path, section_expand_st, item.subs, depth + 1, full_path)
      end
    else
      local line_info
      local icon, icon_hl_group = devicons.get_icon(item.path, extension, { default = true })
      local item_full_path = path_append(full_path, item.path)
      local path_hl = item_full_path == selected_path and "DiffviewFilePanelSelected" or nil
      local status_hl = item.left_sha == "nil" and "DiffviewFilePanelInsertions" or nil -- untracked files
      if item.orig_path then
        line_info = {
          {string.format("[%s]", item.status), status_hl},
          {string.format("%s ", prefix), nil},
          {icon .. " ", icon_hl_group},
          {item.orig_path, nil},
          {" -> ", nil},
          {item.path, path_hl},
          {" +" .. (item.added or 0), "DiffviewFilePanelInsertions"},
          {" -" .. (item.deleted or 0), "DiffviewFilePanelDeletions"},
        }
      else
        line_info = {
          {string.format("[%s]", item.status), status_hl},
          {string.format("%s ", prefix), nil},
          {icon .. " ", icon_hl_group},
          {item.path .. " ", path_hl},
          {"+" .. (item.added or 0), "DiffviewFilePanelInsertions"},
          {" ", nil},
          {"-" .. (item.deleted or 0),  "DiffviewFilePanelDeletions"},
        }
      end
      line_to_item[#lines+1] = {type = "path", path = item_full_path}
      if item.left_sha then
        line_to_item[#lines+1].left_sha = item.left_sha -- used for untracked files
      end
      table.insert(lines, line_info)
    end
  end
end

function M.add_section(section_obj, lines, line_to_item,
    header, items, selected_path, section_expand_st, section_expand_default)
  if #items == 0 then return end

  line_to_item[#lines+1] = {type = "section", header = header, section_obj = section_obj}
  table.insert(lines, header)

  local expanded = section_expand_default or false
  if section_expand_st ~= nil then
    expanded = section_expand_st.section_expanded
  end

  if expanded then
    local tree = build_tree(items, 0)
    render_tree(lines, line_to_item, selected_path, section_expand_st or {}, tree, 1, "")
  end
end

M._private = {
  build_tree = build_tree,
}

return M
