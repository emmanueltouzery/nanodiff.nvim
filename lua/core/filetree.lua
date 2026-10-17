local M = {}

-- local folder_closed = "",
local folder_open = " "
local ns_hl_id = vim.api.nvim_create_namespace("nanodiff_ui_highlights")

function M.render_lines(bufnr, lines)
  local lines_text = {}
  local highlights = {}
  local extmarks = {}

  for line_idx, line in ipairs(lines) do
    local line_0idx = line_idx - 1 -- Convert 1-based Lua index to 0-based Neovim index

    if type(line) == "string" then
      table.insert(lines_text, line)
    else
      local line_text = ""
      local virt_text = {}
      local virt_text_pos = nil
      for _, chunk in ipairs(line) do
        local text = chunk[1]
        local hl_group = chunk[2]


        if hl_group then
          if hl_group:find("+", 1, true) then
            -- virtual text
            local hl, text_pos = unpack(vim.split(hl_group, "+", { plain = true }))
            virt_text_pos = text_pos
            table.insert(virt_text, { text, hl })
          else
            local start_byte = #line_text
            line_text = line_text .. text
            local end_byte = #line_text
            table.insert(highlights, {
              line = line_0idx,
              hl = hl_group,
              s = start_byte,
              e = end_byte,
            })
          end
        else
          line_text = line_text .. text
        end
      end
      table.insert(lines_text, line_text)
      if #virt_text > 0 then
        table.insert(extmarks, { lnum = #lines_text-1, virt_text_pos = virt_text_pos, virt_text = virt_text })
      end
    end
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_hl_id, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines_text)

  for _, item in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(bufnr, ns_hl_id, item.hl, item.line, item.s, item.e)
  end

  for _, em in ipairs(extmarks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns_hl_id, em.lnum, 0, {
      virt_text = em.virt_text,
      virt_text_pos = em.virt_text_pos,
    })
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
  for idx, item in ipairs(items or {}) do
    local parts = {}
    for part in item.path:gmatch("[^/]+") do table.insert(parts, part) end
    insert_item(root, parts, item)
  end
  return compress_and_sort(root)
end

-- will return the line number of the selected item
local function render_tree(ft, ft_st, selected_path, section_expand_st, tree, depth, full_path, expand_selected)
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
      ft_st.line_to_item[#ft_st.lines+1] = {type = "dir", path = full_path}
      -- 3 spaces for the prefix where files have the status [M] and so on
      table.insert(ft_st.lines, {
        {"   " .. prefix, nil},
        {folder_open, "DiffviewFolderSign"},
        {item.path, "DiffviewFolderName"},
      })
      local expand_set = section_expand_st.folder_expanded and section_expand_st.folder_expanded[full_path]
      local expand = expand_set ~= false or expand_selected
      if expand then
        local sl, sp = render_tree(ft, ft_st, selected_path, section_expand_st, item.subs, depth + 1, full_path, expand_selected)
        if sl and selection_line == nil then
          selection_line = sl
          selected_path = sp
        end
      end
    else
      local line_info
      local item_full_path = path_append(full_path, item.path)
      local is_selected = item_full_path == selected_path
      if is_selected then
        selection_line = #ft_st.lines+1
        selected_path = item_full_path
      end
      local line_info = ft.render_item(prefix, item, is_selected, {item_full_path = item_full_path})
      ft_st.line_to_item[#ft_st.lines+1] = {type = "path", path = item_full_path}
      if item.left_sha then
        ft_st.line_to_item[#ft_st.lines+1].left_sha = item.left_sha -- used for untracked files
      end
      table.insert(ft_st.lines, line_info)
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

function M.create_ft(params)
  return {
    section_get_key = params.section_get_key,
    section_get_items = params.section_get_items,
    get_header = params.get_header,
    render_item = params.render_item,
    render_section = params.render_section,
    item_activated = params.item_activated,
    expand_default = params.expand_default,
  }
end

function M.create_ft_st(params)
  return {
    -- where to render
    bufnr = params.bufnr,
    winnr = params.winnr,

    -- depends on data alone
    sections = {},
    tree_by_section = {},
    sorted_files = {}, -- subfields secion+path

    -- user-applied state
    tree_expand_st = {},
    selected_item = nil, -- subfields section+path

    -- depends on node expansion state
    lines = {},
    line_to_item = {},
  }
end

-- will return line number of the selected item
local function add_section_to_lines(ft, ft_st, section_obj, selected_path, section_expand_st, expand_selected)
  local section_key = ft.section_get_key(section_obj)
  local items = ft.section_get_items(section_obj)
  if #items == 0 and not section_obj.always_show then return nil end

  local header = ft.render_section(section_obj, selected_path)
  ft_st.line_to_item[#ft_st.lines+1] = {type = "section", header = header, section_obj = section_obj}
  table.insert(ft_st.lines, header)

  local tree = ft_st.tree_by_section[section_key]

  local expand_set = section_expand_st ~= nil and section_expand_st.section_expanded or nil
  local expanded = nil
  if expand_selected and selected_path then
    -- we were asked to expand when we have the selection,
    -- we have the selection, expand
    expanded = true
  elseif expand_set ~= nil then
    -- the user asked something, respect it
    expanded = expand_set
  else
    -- not selected, no user request, expand as per default
    expanded = ft.expand_default
  end
  local selection_line = nil
  if expanded then
    selection_line = render_tree(ft, ft_st, selected_path, section_expand_st or {}, tree, 1, "", expand_selected)
  end
  return selection_line
end

--- redisplay must be performed after node expand/collapse or selection change
function M.redisplay(ft, ft_st, focus_selected)
  ft_st.lines = ft.get_header()
  ft_st.line_to_item = {}

  local selection_line = nil
  for _, section in ipairs(ft_st.sections) do
    local section_key = ft.section_get_key(section)
    local selected_path = nil
    if ft_st.selected_item ~= nil and ft.section_get_key(ft_st.selected_item.section) == section_key then
      selected_path = ft_st.selected_item.item.path
    end
    local sl = add_section_to_lines(ft, ft_st, section, selected_path, ft_st.tree_expand_st[section_key], focus_selected)
    if sl and selection_line == nil then
      selection_line = sl
    end
  end

  vim.bo[ft_st.bufnr].modifiable = true
  vim.bo[ft_st.bufnr].readonly = false
  M.render_lines(ft_st.bufnr, ft_st.lines)
  vim.bo[ft_st.bufnr].modifiable = false
  vim.bo[ft_st.bufnr].readonly = true
  if focus_selected and selection_line then
    vim.api.nvim_win_set_cursor(ft_st.winnr, { selection_line, 0 })
  end
end

function M.set_contents(ft, ft_st, data, selected_item)
  ft_st.sections = data
  ft_st.tree_by_section = {}
  ft_st.sorted_files = {}
  if selected_item then
    ft_st.selected_item = selected_item
  end

  if #data > 0 then
    -- expand the first non-empty section
    local fst_non_empty_idx, _ = vim.iter(ipairs(data)):find(
      function(_, s) return #ft.section_get_items(s) > 0 end
    )
    ft_st.tree_expand_st[ft.section_get_key(data[fst_non_empty_idx])] = {section_expanded = true}
  end

  for _, section in ipairs(data) do
    local section_key = ft.section_get_key(section)
    local items = ft.section_get_items(section)
    local section_tree = build_tree(items)
    ft_st.tree_by_section[section_key] = section_tree
    local section_sorted_files = tree_collect_files(section_tree, "", {})
    vim.list_extend(ft_st.sorted_files,
      vim.tbl_map(function(p) return {
        item = vim.iter(items):find(function(item) return item.path == p end),
        section = section
      } end,
      section_sorted_files))
    if #ft_st.sorted_files > 0 and ft_st.selected_item == nil then
      ft_st.selected_item = ft_st.sorted_files[1]
    end
  end
  M.redisplay(ft, ft_st, true)
  -- display the first entry immediately
  if #data > 0 then
    ft.item_activated(ft, ft_st, ft_st.selected_item.section, ft_st.selected_item.item, true)
    -- Force the top of the buffer (line 1) to be visible at the top of the window
    vim.fn.winrestview({ topline = 1 })
  else
    -- no data, display nil buffers
    ft.item_activated(ft, ft_st, nil, nil)
    vim.api.nvim_win_set_cursor(bottom_win, { 1, 0 })
  end
end

function M.get_cur_section_item(ft_st)
  local line = vim.fn.line('.')

  local section_line = line
  local section_item
  while section_line > 0 do
    section_item = ft_st.line_to_item[section_line]
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

  local item = ft_st.line_to_item[line]
  return section, item
end

function M.next_file(ft, ft_st)
  local next = false
  for i, file in ipairs(ft_st.sorted_files) do
    if next then
      ft_st.selected_item = file
      M.redisplay(ft, ft_st, true)
      local section, item = M.get_cur_section_item(ft_st) -- TODO dodgy: we rely on redisplay() moving the cursor to the item
      ft.item_activated(ft, ft_st, section, item, true)
      return
    end
    if file.item.path == ft_st.selected_item.item.path and file.section == ft_st.selected_item.section then
      next = true
    end
  end
  -- didn't find, presumably got past the end, select the first
  ft_st.selected_item = ft_st.sorted_files[1]
  M.redisplay(ft, ft_st, true)
  local section, item = M.get_cur_section_item(ft_st) -- TODO dodgy: we rely on redisplay() moving the cursor to the item
  ft.item_activated(ft, ft_st, section, item, true)
end

function M.prev_file(ft, ft_st)
  local prev = false
  for i = #ft_st.sorted_files, 1, -1 do
    local file = ft_st.sorted_files[i]
    if prev then
      ft_st.selected_item = file
      M.redisplay(ft, ft_st, true)
      local section, item = M.get_cur_section_item(ft_st) -- TODO dodgy: we rely on redisplay() moving the cursor to the item
      ft.item_activated(ft, ft_st, section, item, true)
      return
    end
    if file.item.path == ft_st.selected_item.item.path and file.section == ft_st.selected_item.section then
      prev = true
    end
  end
  -- didn't find, presumably got past the start, select the last
  ft_st.selected_item = ft_st.sorted_files[#ft_st.sorted_files]
  M.redisplay(ft, ft_st, true)
  local section, item = M.get_cur_section_item(ft_st) -- TODO dodgy: we rely on redisplay() moving the cursor to the item
  ft.item_activated(ft, ft_st, section, item, true)
end

function M.set_selected_item(ft_st, section, item)
  ft_st.selected_item = {section = section, item = item}
end

function M.handle_enter(ft, ft_st)
  local section, item = M.get_cur_section_item(ft_st)
  if item == nil then
    return
  end
  local section_key_val = ft.section_get_key(section)

  if item.type == "dir" then
    ft_st.tree_expand_st[section_key_val] = ft_st.tree_expand_st[section_key_val] or { section_expanded = true }
    ft_st.tree_expand_st[section_key_val].folder_expanded = ft_st.tree_expand_st[section_key_val].folder_expanded or {}
    local folder_expanded = ft_st.tree_expand_st[section_key_val].folder_expanded
    prev_expanded = folder_expanded[item.path]
    if prev_expanded == nil then
      prev_expanded = true
    end
    folder_expanded[item.path] = not prev_expanded
    M.redisplay(ft, ft_st, false)
  elseif item.type == "section" then
    if ft_st.tree_expand_st[section_key_val] == nil then
      ft_st.tree_expand_st[section_key_val] = {}
    end
    local prev_expanded = ft_st.tree_expand_st[section_key_val].section_expanded
    if prev_expanded == nil then
      prev_expanded = ft.expand_default
    end
    ft_st.tree_expand_st[section_key_val].section_expanded = not prev_expanded
    M.redisplay(ft, ft_st, false)
  elseif item.type == "path" then
    ft.item_activated(ft, ft_st, section, item)
  end
end

M._private = {
  build_tree = build_tree,
}

return M
