local parser = require("md_section_number.heading.parser")

local M = {}

M.options = {
  width = 30,
  position = "right",
  indent_space_number = 2,
  header_prefix = "- ",
  default_display_level = 6,
  start_folded = false,
  winopts = {
    number = false,
    relativenumber = true,
    wrap = false,
    winfixwidth = true,
    list = false,
    spell = false,
  },
  bufopts = {
    bufhidden = "wipe",
    filetype = "msnumber",
    modifiable = false,
  },
}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.options, opts or {})
end

local bindBufGroupName = "MSNbindBufEventGroup"
local tocBufGroupName = "MSNtocBufEventGroup"
local globalGroupName = "MSNGlobalEventGroup"

local tocHlNameSpace = vim.api.nvim_create_namespace("tocHlNameSpace")
local markdownFileType = { markdown = true, md = true }
local move_tbl = {
  left = "H",
  right = "L",
}

M.viewBind = {}
M.autocmd_setup_done = false

local function current_tabpage_key(tabpage)
  return tostring(tabpage or vim.api.nvim_get_current_tabpage())
end

local function create_state(tabpage)
  local key = current_tabpage_key(tabpage)
  return {
    tabpage = key,
    MdHeaders = nil,
    displayLevel = nil,
    collapsed = {},
    foldVersion = 0,
    lastFoldVersion = 0,
    TocWin = nil,
    TocBuf = nil,
    BindBuf = nil,
    BindWin = nil,
    changeTick = nil,
    allMdHeaders = nil,
    maxLevel = nil,
    bindBufGroupName = bindBufGroupName .. "_" .. key,
    tocBufGroupName = tocBufGroupName .. "_" .. key,
  }
end

local function get_state(tabpage)
  return M.viewBind[current_tabpage_key(tabpage)]
end

local function ensure_state(tabpage)
  local key = current_tabpage_key(tabpage)
  if not M.viewBind[key] then
    M.viewBind[key] = create_state(tabpage)
  end
  return M.viewBind[key]
end

local function has_valid_win(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

-- local buildInEvent = { }

local function clear_all_autocmd(state)
  local check_buf_valid = function(buf_id)
    return buf_id ~= nil and vim.api.nvim_buf_is_valid(buf_id)
  end
  if not state then
    return
  end
  if check_buf_valid(state.BindBuf) then
    vim.api.nvim_clear_autocmds({ group = state.bindBufGroupName, buffer = state.BindBuf })
  end
  if check_buf_valid(state.TocBuf) then
    vim.api.nvim_clear_autocmds({ group = state.tocBufGroupName, buffer = state.TocBuf })
  end
end

function M.unbind(tabpage)
  local state = get_state(tabpage)
  if not state then
    return
  end
  clear_all_autocmd(state)
  M.viewBind[state.tabpage] = nil
end

local function create_side_window()
  vim.cmd("vsplit")
  local win = vim.api.nvim_get_current_win()
  local move_to = move_tbl[M.options.position]
  vim.api.nvim_command("wincmd " .. move_to)
  vim.api.nvim_win_set_width(win, M.options.width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  for k, v in pairs(M.options.bufopts) do
    vim.api.nvim_buf_set_option(buf, k, v)
  end
  for k, v in pairs(M.options.winopts) do
    vim.opt_local[k] = v
  end
  return win, buf
end

local function add_indent_for_header(header)
  local header_str = header[2]
  local indent_str = string.rep(" ", M.options.indent_space_number)
  header_str = M.options.header_prefix .. vim.trim(header_str:gsub("#", "", header[3]))
  if header[3] > 1 then
    header_str = string.rep(indent_str, header[3] - 1) .. header_str
  end
  return header_str
end

-- assign each header a stable ordinal path, e.g. the 3rd H2 under the 1st H1 is "1.3"
local function compute_header_paths(headers)
  local counters = {}
  for _, header in ipairs(headers) do
    local level = header[3]
    counters[level] = (counters[level] or 0) + 1
    for k = #counters, level + 1, -1 do
      counters[k] = nil
    end
    local parts = {}
    for k = 1, level do
      parts[k] = tostring(counters[k] or 1)
    end
    header[4] = table.concat(parts, ".")
  end
end

local function has_collapsed_ancestor(collapsed, path)
  local dot = path:find(".", 1, true)
  while dot ~= nil do
    if collapsed[path:sub(1, dot - 1)] then
      return true
    end
    dot = path:find(".", dot + 1, true)
  end
  return false
end

local function reload_headers(state, header_level_offset)
  local change_flag = false
  header_level_offset = header_level_offset or 0
  if not state or not state.BindBuf then
    return change_flag
  end
  local current_change_tick = vim.api.nvim_buf_get_changedtick(state.BindBuf)
  if state.allMdHeaders == nil or (state.changeTick ~= current_change_tick) then
    state.allMdHeaders = parser.get_heading_lines(vim.api.nvim_buf_get_lines(state.BindBuf, 0, -1, false))
    compute_header_paths(state.allMdHeaders)
    local max_level = 1
    for _, header in ipairs(state.allMdHeaders) do
      if header[3] > max_level then
        max_level = header[3]
      end
    end
    state.maxLevel = max_level
    change_flag = true
  end
  state.changeTick = current_change_tick

  -- display level
  local currentDisplayLevel = state.displayLevel
  if state.displayLevel == nil then
    state.displayLevel = state.maxLevel
  end
  if header_level_offset ~= 0 then
    state.displayLevel = math.max(1, math.min(state.displayLevel + header_level_offset, state.maxLevel))
  end

  -- per-node fold state
  state.foldVersion = state.foldVersion or 0
  if state.lastFoldVersion ~= state.foldVersion then
    change_flag = true
    state.lastFoldVersion = state.foldVersion
  end
  if change_flag or currentDisplayLevel == nil or currentDisplayLevel ~= state.displayLevel then
    change_flag = true
    local collapsed = state.collapsed or {}
    local display_header = {}
    for _, header in ipairs(state.allMdHeaders) do
      if header[3] > state.displayLevel then
        goto continue
      end
      if has_collapsed_ancestor(collapsed, header[4]) then
        goto continue
      end
      table.insert(display_header, header)
      ::continue::
    end
    state.MdHeaders = display_header
  end

  return change_flag
end

local function render_headers(state, header_level_offset, force)
  -- get change flag, update headers
  local change_flag = force or reload_headers(state, header_level_offset)
  if not change_flag then
    return
  end
  -- start update
  if not state or not has_valid_win(state.TocWin) or not vim.api.nvim_buf_is_valid(state.TocBuf) then
    return
  end
  vim.api.nvim_buf_set_option(state.TocBuf, "modifiable", true)
  local all_headers_with_indent = {}
  for _, header in ipairs(state.MdHeaders or {}) do
    table.insert(all_headers_with_indent, add_indent_for_header(header))
  end
  -- clear
  vim.api.nvim_buf_set_lines(state.TocBuf, 0, -1, false, {})
  -- reset
  vim.api.nvim_buf_set_lines(state.TocBuf, 0, -1, false, all_headers_with_indent)
  vim.api.nvim_buf_set_option(state.TocBuf, "modifiable", false)
end

-- collapse every heading at the shallowest level: only top-level headings stay visible
local function collapse_top_level_headers(state)
  state.collapsed = {}
  local min_level = math.huge
  for _, h in ipairs(state.allMdHeaders or {}) do
    if h[3] < min_level then
      min_level = h[3]
    end
  end
  for _, h in ipairs(state.allMdHeaders or {}) do
    if h[3] == min_level then
      state.collapsed[h[4]] = true
    end
  end
end

-- fresh fold state for a (re)bound buffer, honoring the start_folded option
local function reset_fold_state(state)
  state.collapsed = {}
  if M.options.start_folded then
    reload_headers(state)
    collapse_top_level_headers(state)
  end
  state.foldVersion = (state.foldVersion or 0) + 1
end

local function get_toc_index(state, lineNumber)
  if not state or not state.MdHeaders or #state.MdHeaders == 0 then
    return 1
  end
  lineNumber = lineNumber or vim.api.nvim_win_get_cursor(state.BindWin)[1]
  local left = 1
  local right = #state.MdHeaders
  if lineNumber < state.MdHeaders[left][1] then
    return left
  end
  if lineNumber > state.MdHeaders[right][1] then
    return right
  end
  while left <= right do
    local middle = math.floor((left + right) / 2)
    local middleVal = state.MdHeaders[middle][1] + 1
    if middleVal == lineNumber then
      return middle
    elseif lineNumber > middleVal then
      left = middle + 1
    elseif lineNumber < middleVal then
      right = middle - 1
    end
  end
  return math.max(math.min(left, right), 1)
end

local function set_toc_position(state, contentLinenumber)
  if not state or not has_valid_win(state.TocWin) or not vim.api.nvim_buf_is_valid(state.TocBuf) then
    return
  end
  local index = get_toc_index(state, contentLinenumber)
  local line_count = vim.api.nvim_buf_line_count(state.TocBuf)
  if line_count > 0 then
    index = math.min(index, line_count)
  end
  vim.api.nvim_win_set_cursor(state.TocWin, { index, 0 })
  vim.api.nvim_buf_clear_namespace(state.TocBuf, tocHlNameSpace, 0, -1)
  vim.api.nvim_buf_add_highlight(state.TocBuf, tocHlNameSpace, "Search", index - 1, 0, -1)
end

local function jump_header()
  local state = get_state()
  if not state then
    return
  end
  -- pin the target heading before any re-render: clearing the toc buffer
  -- inside render_headers clamps the toc cursor to row 1
  local pinned_path = nil
  local content_linenumber = nil
  if state.MdHeaders and #state.MdHeaders > 0 then
    local cursor_index = math.min(vim.api.nvim_win_get_cursor(0)[1], #state.MdHeaders)
    pinned_path = state.MdHeaders[cursor_index][4]
    content_linenumber = state.MdHeaders[cursor_index][1] + 1
  end
  -- headers may be stale if the markdown buffer changed since the last render
  local changed = reload_headers(state)
  if changed then
    render_headers(state, 0, true)
  end
  if not state.MdHeaders or #state.MdHeaders == 0 then
    return
  end
  -- locate the same heading in the refreshed list by its ordinal path
  local header_index = nil
  if pinned_path then
    for index, header in ipairs(state.MdHeaders) do
      if header[4] == pinned_path then
        header_index = index
        break
      end
    end
  end
  if not header_index then
    header_index = content_linenumber and get_toc_index(state, content_linenumber) or 1
  end
  header_index = math.min(header_index, #state.MdHeaders)
  local line_number =
    math.min(state.MdHeaders[header_index][1] + 1, vim.api.nvim_buf_line_count(state.BindBuf))
  vim.api.nvim_win_set_buf(state.BindWin, state.BindBuf)
  vim.api.nvim_set_current_win(state.BindWin)
  vim.api.nvim_win_set_cursor(state.BindWin, { line_number, 0 })
  vim.api.nvim_feedkeys("zz", "n", false)
  set_toc_position(state)
  -- add to jump list
  vim.cmd("normal! m'")
end

function M.closeToc()
  local state = get_state()
  if not state or not has_valid_win(state.TocWin) then
    return
  end
  vim.api.nvim_win_close(state.TocWin, true)
  M.unbind(state.tabpage)
end

local function set_mappings(state)
  local function change_display_level(levelOffset)
    return function()
      if not state or not state.MdHeaders then
        return
      end
      local header_index = vim.api.nvim_win_get_cursor(state.TocWin)[1]
      local content_linenumber = state.MdHeaders[header_index][1] + 1
      render_headers(state, levelOffset)
      set_toc_position(state, content_linenumber)
      vim.api.nvim_feedkeys("zz", "n", false)
    end
  end
  local function change_fold_state(action)
    return function()
      if not state or not state.MdHeaders or #state.MdHeaders == 0 then
        return
      end
      reload_headers(state)
      local header_index = math.min(vim.api.nvim_win_get_cursor(state.TocWin)[1], #state.MdHeaders)
      local header = state.MdHeaders[header_index]
      if not header then
        return
      end
      local content_linenumber = header[1] + 1
      local path = header[4]
      if action == "open_all" then
        state.collapsed = {}
      elseif action == "close_all" then
        collapse_top_level_headers(state)
      elseif action == "close" or (action == "toggle" and not state.collapsed[path]) then
        state.collapsed[path] = true
      elseif action == "open" or (action == "toggle" and state.collapsed[path]) then
        state.collapsed[path] = nil
        -- reveal only the next level: children show up, deeper levels stay folded
        local prefix = path .. "."
        for _, h in ipairs(state.allMdHeaders or {}) do
          local child_path = h[4]
          if child_path:sub(1, #prefix) == prefix and not child_path:sub(#prefix + 1):find(".", 1, true) then
            state.collapsed[child_path] = true
          end
        end
      else
        return
      end
      state.foldVersion = (state.foldVersion or 0) + 1
      render_headers(state)
      set_toc_position(state, content_linenumber)
      vim.api.nvim_feedkeys("zz", "n", false)
    end
  end
  local mappings = {
    ["<cr>"] = jump_header,
    q = function()
      M.closeToc()
    end,
    r = function()
      if not state then
        return
      end
      local origin_position = vim.api.nvim_win_get_cursor(state.TocWin)
      render_headers(state)
      local line_count = vim.api.nvim_buf_line_count(state.TocBuf)
      if line_count == 0 then
        return
      end
      local row = get_toc_index(state)
      local line = vim.api.nvim_buf_get_lines(state.TocBuf, row - 1, row, false)[1]
      if line == nil then
        line = ""
      end
      local col = math.min(#line, origin_position[2])
      vim.api.nvim_win_set_cursor(state.TocWin, { row, col })
      vim.api.nvim_buf_clear_namespace(state.TocBuf, tocHlNameSpace, 0, -1)
      vim.api.nvim_buf_add_highlight(state.TocBuf, tocHlNameSpace, "Search", row - 1, 0, -1)
    end,
    ["h"] = change_display_level(-1),
    ["l"] = change_display_level(1),
    ["W"] = change_display_level(-5),
    ["E"] = change_display_level(5),
    ["zo"] = change_fold_state("open"),
    ["zc"] = change_fold_state("close"),
    ["za"] = change_fold_state("toggle"),
    ["zR"] = change_fold_state("open_all"),
    ["zM"] = change_fold_state("close_all"),
  }
  for k, v in pairs(mappings) do
    vim.keymap.set("n", k, v, { buffer = state.TocBuf, silent = true, noremap = true })
  end
end

local function set_bind_buf_autocmd(state)
  if not state then
    return
  end
  local bindBufEventGroup = vim.api.nvim_create_augroup(state.bindBufGroupName, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = bindBufEventGroup,
    buffer = state.BindBuf,
    callback = function()
      local tabpage = state.tabpage
      vim.schedule(function()
        local current_state = get_state(tabpage)
        if not current_state then
          return
        end
        render_headers(current_state)
        set_toc_position(current_state)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = bindBufEventGroup,
    buffer = state.BindBuf,
    callback = function()
      local tabpage = state.tabpage
      vim.schedule(function()
        local current_state = get_state(tabpage)
        if not current_state then
          return
        end
        set_toc_position(current_state)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = bindBufEventGroup,
    buffer = state.BindBuf,
    callback = function()
      local tabpage = state.tabpage
      vim.schedule(function()
        local current_state = get_state(tabpage)
        if not current_state then
          return
        end
        if vim.api.nvim_get_current_win() == current_state.TocWin then
          return
        end
        M.closeToc()
      end)
    end,
  })
end

local function set_toc_buf_autocmd(state)
  if not state then
    return
  end
  local tocBufEventGroup = vim.api.nvim_create_augroup(state.tocBufGroupName, { clear = true })
  vim.api.nvim_create_autocmd({ "WinClosed", "QuitPre" }, {
    group = tocBufEventGroup,
    buffer = state.TocBuf,
    callback = function()
      M.unbind(state.tabpage)
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = tocBufEventGroup,
    buffer = state.TocBuf,
    callback = function()
      local tabpage = state.tabpage
      vim.schedule(function()
        local current_state = get_state(tabpage)
        if not current_state then
          return
        end
        if current_state.BindWin == nil or not vim.api.nvim_win_is_valid(current_state.BindWin) then
          M.unbind(tabpage)
          return
        end

        local currentBuf = vim.api.nvim_win_get_buf(current_state.BindWin)
        if currentBuf ~= current_state.BindBuf then
          return
        end
        render_headers(current_state)
        set_toc_position(current_state)
      end)
    end,
  })
  -- keep the highlight on the cursor line so it always marks the jump target
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = tocBufEventGroup,
    buffer = state.TocBuf,
    callback = function()
      local current_state = get_state(state.tabpage)
      if not current_state or not has_valid_win(current_state.TocWin) then
        return
      end
      if not vim.api.nvim_buf_is_valid(current_state.TocBuf) then
        return
      end
      local row = vim.api.nvim_win_get_cursor(current_state.TocWin)[1]
      vim.api.nvim_buf_clear_namespace(current_state.TocBuf, tocHlNameSpace, 0, -1)
      vim.api.nvim_buf_add_highlight(current_state.TocBuf, tocHlNameSpace, "Search", row - 1, 0, -1)
    end,
  })
end

local function switch_bind(state, bind_buf, bind_win)
  -- no toc
  if not state or not state.TocBuf then
    return
  end
  -- filetype judgment
  local filetype = vim.api.nvim_buf_get_option(bind_buf, "filetype")
  if not markdownFileType[filetype] then
    return
  end
  if bind_buf == state.BindBuf and bind_win == state.BindWin then
    return
  end
  if bind_buf ~= state.BindBuf then
    state.BindBuf = bind_buf
    state.allMdHeaders = nil
    state.displayLevel = nil
    reset_fold_state(state)
    render_headers(state)
  end
  if bind_win ~= state.BindWin then
    state.BindWin = bind_win
  end
  set_bind_buf_autocmd(state)
  set_toc_position(state)
end

local function set_autocmd()
  if M.autocmd_setup_done then
    return
  end

  local globalEventGroup = vim.api.nvim_create_augroup(globalGroupName, { clear = true })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = globalEventGroup,
    pattern = { "*.md", "*.markdown" },
    callback = function()
      local tabpage = vim.api.nvim_get_current_tabpage()
      local bind_buf = vim.api.nvim_get_current_buf()
      local bind_win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        local state = get_state(tabpage)
        if not state then
          return
        end
        switch_bind(state, bind_buf, bind_win)
      end)
    end,
  })
  vim.api.nvim_create_autocmd("WinEnter", {
    group = globalEventGroup,
    pattern = { "*.md", "*.markdown" },
    callback = function()
      local tabpage = vim.api.nvim_get_current_tabpage()
      local bind_buf = vim.api.nvim_get_current_buf()
      local bind_win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        local current_state = get_state(tabpage)
        if not current_state then
          return
        end
        if bind_buf == current_state.BindBuf then
          current_state.BindWin = bind_win
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("QuitPre", {
    group = globalEventGroup,
    pattern = { "*.md", "*.markdown" },
    callback = function()
      local tabpage = vim.api.nvim_get_current_tabpage()
      vim.schedule(function()
        local current_state = get_state(tabpage)
        if not current_state then
          return
        end
        local wins = vim.api.nvim_tabpage_list_wins(tabpage)
        local non_essential_window_flag = #wins == 1 and wins[1] == current_state.TocWin

        -- support for some session function(like vim-startify)
        if non_essential_window_flag then
          local current_buf = current_state.BindBuf
          M.unbind(tabpage)
          vim.api.nvim_set_current_buf(current_buf)
          vim.cmd(":quit")
        end
      end)
    end,
  })
  M.autocmd_setup_done = true
end

local function focus_origin_position(state)
  if not state or not has_valid_win(state.BindWin) then
    return
  end
  vim.api.nvim_set_current_win(state.BindWin)
end

function M.openToc()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local state = ensure_state(tabpage)
  if has_valid_win(state.TocWin) then
    return
  end
  state.BindBuf = vim.api.nvim_get_current_buf()
  state.BindWin = vim.api.nvim_get_current_win()

  local win, buf = create_side_window()
  state.TocWin = win
  state.TocBuf = buf

  reset_fold_state(state)
  render_headers(state)
  set_mappings(state)
  set_autocmd()
  set_toc_buf_autocmd(state)
  set_bind_buf_autocmd(state)
  focus_origin_position(state)
end

function M.toggle()
  local state = get_state()
  if state and has_valid_win(state.TocWin) then
    M.closeToc()
  else
    M.openToc()
  end
end

return M
