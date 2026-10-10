local M = {}
local devicons = require'nvim-web-devicons'
local bufdata = require('bufdata')

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

  vim.api.nvim_buf_clear_namespace(bufnr, ns_hl_id, 0, -1)
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

local function insert_item(is_selected, tree, parts, item, depth)
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
  if is_selected then
    target.is_selected = true
  end

  if depth == #parts then
    -- Copy all original item fields onto the leaf
    -- can't reuse the item because we need a different path, we'd have to mutate
    for k, v in pairs(item) do
      if k == "path" then target.path = part else target[k] = v end
    end
  else
    target.is_dir, target.subs = true, target.subs or {}
    insert_item(is_selected, target.subs, parts, item, depth + 1)
  end
end

local function build_tree(items, selected_path)
  local root = {}
  local selected_item = nil
  for idx, item in ipairs(items or {}) do
    local is_selected = item.path == selected_path
    local parts = {}
    for part in item.path:gmatch("[^/]+") do table.insert(parts, part) end
    insert_item(is_selected, root, parts, item)
    if is_selected then
      selected_item = item
    end
  end
  -- TODO drop that returning selected_item
  return compress_and_sort(root), selected_item
end

-- will return the line number of the selected item
local function render_tree(conflicts_state, lines, line_to_item, selected_path, section_expand_st, tree, depth, full_path, reveal_selected)
-- print("render_tree selected_path: " .. vim.inspect(selected_path))
  local selection_line = nil
  local function path_append(root, child)
    if root == "" then
      return child
    else
      return root .. "/" .. child
    end
  end

  local prefix = string.rep(" ", depth*2)
  for idx, item in ipairs(tree) do
    if item.is_dir then
      local full_path = path_append(full_path, item.path)
      line_to_item[#lines+1] = {type = "dir", path = full_path}
      -- 3 spaces for the prefix where files have the status [M] and so on
      table.insert(lines, {
        {"   " .. prefix, nil},
        {folder_open, "DiffviewFolderSign"},
        {item.path, "DiffviewFolderName"},
      })
      local expand = (reveal_selected and item.is_selected)
        or section_expand_st.folder_expanded == nil
        or section_expand_st.folder_expanded[full_path] ~= false
      if expand then
        local sl, sp = render_tree(conflicts_state, lines, line_to_item, selected_path, section_expand_st, item.subs, depth + 1, full_path, reveal_selected)
        if sl and selection_line == nil then
          selection_line = sl
          selected_path = sp
        end
      end
    else
      local line_info
      local icon, icon_hl_group = devicons.get_icon(item.path, extension, { default = true })
      local item_full_path = path_append(full_path, item.path)
      local is_selected = item_full_path == selected_path
      if is_selected then
        selection_line = #lines+1
        selected_path = item_full_path
      end
      local path_hl = is_selected and "DiffviewFilePanelSelected" or nil
      local status_hl = item.left_sha == "nil" and "DiffviewFilePanelInsertions" or nil -- untracked files
      if item.status == "U" then
        -- git conflict: don't display the +- diffstat, rather the number of conflicts
        line_info = {
          {item.status, status_hl},
          {string.format("%s ", prefix), nil},
          {icon .. " ", icon_hl_group},
          {item.path .. " ", path_hl},
          {conflicts_state.conflicts[item_full_path] ~= nil and #conflicts_state.conflicts[item_full_path] or "", "DiffviewFilePanelConflicts"},
        }
      elseif item.orig_path then
        line_info = {
          {item.status, status_hl},
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
          {item.status, status_hl},
          {string.format("%s ", prefix), nil},
          {icon .. " ", icon_hl_group},
          {item.path .. " ", path_hl},
        }
        if item.added ~= nil or item.deleted ~= nil then
          table.insert(line_info, {"+" .. (item.added or 0), "DiffviewFilePanelInsertions"})
          table.insert(line_info, {" ", nil})
          table.insert(line_info, {"-" .. (item.deleted or 0),  "DiffviewFilePanelDeletions"})
        end
      end
      line_to_item[#lines+1] = {type = "path", path = item_full_path}
      if item.left_sha then
        line_to_item[#lines+1].left_sha = item.left_sha -- used for untracked files
      end
      table.insert(lines, line_info)
    end
  end
  return selection_line, selected_path
end

local function tree_collect_files(nodes, prefix, acc)
    acc = acc or {}
    for _, node in ipairs(nodes or {}) do
        -- Build the full path
        local full_path = (prefix == "" or not prefix) and node.path or (prefix .. "/" .. node.path)

        if node.is_dir then
            tree_collect_files(node.subs, full_path, acc)
        else
            table.insert(acc, full_path)
        end
    end
    return acc
end

-- will return the files in display order (including not-displayed files due to collapsed folders) and line number of the selected item
-- TODO if add_section always renders even collapsed folders, don't
-- call it for every refresh, only call render_tree again
function M.add_section(conflicts_state, section_obj, lines, line_to_item,
    header, items, selected_path, section_expand_st, section_expand_default, reveal_selected)
  if #items == 0 and not section_obj.always_show then return {}, nil end

  line_to_item[#lines+1] = {type = "section", header = header, section_obj = section_obj}
  table.insert(lines, header)

  local tree = build_tree(items, selected_path)

  local expanded = section_expand_default or false
  if section_expand_st ~= nil then
    expanded = section_expand_st.section_expanded
  end
  expanded = expanded or (reveal_selected and selected_path ~= nil) -- if the selected item is in this section, always expand
  local selection_line = nil
  if expanded then
    selection_line = render_tree(conflicts_state, lines, line_to_item, selected_path, section_expand_st or {}, tree, 1, "", reveal_selected)
  end
  return tree_collect_files(tree, "", {}), selection_line
end

function M.get_cur_section_item(bufnr)
  local line = vim.fn.line('.')
  local bdata = bufdata.get_data(bufnr)

  local section_line = line
  local section_item
  while section_line > 0 do
    section_item = bdata.line_to_item[section_line]
    if section_item ~= nil and section_item.type == "section" then
      break
    end
    section_line = section_line - 1
  end
  if section_item == nil then
    -- possible if we put header text before the first section
    return nil, nil
  end
  local section = section_item.section_obj

  local item = bdata.line_to_item[line]
  return section, item
end

function M.next_file(section_key, section_items_key, bufnr, git_root, refresh, load_entry)
  local bdata = bufdata.get_data(bufnr)

  local next = false
  for i, file in ipairs(bdata.sorted_files) do
    if next then
      bdata.selected_item = file
      refresh(bufnr)
      local section, item = M.get_cur_section_item(bufnr) -- TODO dodgy: we rely on refresh() moving the cursor to the item
      load_entry(bufnr, git_root, section, item, true)
      return
    end
    if file.path == bdata.selected_item.path and file.section == bdata.selected_item.section then
      next = true
    end
  end
  -- didn't find, presumably got past the end, select the first
  bdata.selected_item = bdata.sorted_files[1]
  refresh(bufnr)
  local section, item = M.get_cur_section_item(bufnr) -- TODO dodgy: we rely on refresh() moving the cursor to the item
  load_entry(bufnr, git_root, section, item, true)
end

function M.prev_file(section_key, section_items_key, bufnr, git_root, refresh, load_entry)
  local bdata = bufdata.get_data(bufnr)

  local prev = false
  for i = #bdata.sorted_files, 1, -1 do
    local file = bdata.sorted_files[i]
    if prev then
      bdata.selected_item = file
      refresh(bufnr)
      local section, item = M.get_cur_section_item(bufnr) -- TODO dodgy: we rely on refresh() moving the cursor to the item
      load_entry(bufnr, git_root, section, item, true)
      return
    end
    if file.path == bdata.selected_item.path and file.section == bdata.selected_item.section then
      prev = true
    end
  end
  -- didn't find, presumably got past the start, select the last
  bdata.selected_item = bdata.sorted_files[#bdata.sorted_files]
  refresh(bufnr)
  local section, item = M.get_cur_section_item(bufnr) -- TODO dodgy: we rely on refresh() moving the cursor to the item
  load_entry(bufnr, git_root, section, item, true)
end

function M.handle_enter(section_key, section_expand_default, git_root, bufnr, refresh, load_entry)
  local section, item = M.get_cur_section_item(bufnr)
  if item == nil then
    return
  end
  local section_key_val = section[section_key]
  local bdata = bufdata.get_data(bufnr)

  if item.type == "dir" then
    bdata.tree_expand_st[section_key_val] = bdata.tree_expand_st[section_key_val] or { section_expanded = true }
    bdata.tree_expand_st[section_key_val].folder_expanded = bdata.tree_expand_st[section_key_val].folder_expanded or {}
    local folder_expanded = bdata.tree_expand_st[section_key_val].folder_expanded
    prev_expanded = folder_expanded[item.path]
    if prev_expanded == nil then
      prev_expanded = true
    end
    folder_expanded[item.path] = not prev_expanded
    refresh(bufnr)
  elseif item.type == "section" then
    if bdata.tree_expand_st[section_key_val] == nil then
      bdata.tree_expand_st[section_key_val] = {}
    end
    local prev_expanded = bdata.tree_expand_st[section_key_val].section_expanded
    if prev_expanded == nil then
      prev_expanded = section_expand_default
    end
    bdata.tree_expand_st[section_key_val].section_expanded = not prev_expanded
    refresh(bufnr)
  elseif item.type == "path" then
    load_entry(bufnr, git_root, section, item)
  end
end

M._private = {
  build_tree = build_tree,
}

return M
