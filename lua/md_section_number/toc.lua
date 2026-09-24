local parser = require("md_section_number.heading.parser")

local M = {}

M.options = {
  width = 30,
  position = "right",
  indent_space_number = 2,
  header_prefix = "- ",
  default_display_level = 6,
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

local function reload_headers(state, header_level_offset)
  local change_flag = false
  header_level_offset = header_level_offset or 0
  if not state or not state.BindBuf then
    return change_flag
  end
  local current_change_tick = vim.api.nvim_buf_get_changedtick(state.BindBuf)
  if state.allMdHeaders == nil or (state.changeTick ~= current_change_tick) then
    state.allMdHeaders = parser.get_heading_lines(vim.api.nvim_buf_get_lines(state.BindBuf, 0, -1, false))
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
  if change_flag or currentDisplayLevel == nil or currentDisplayLevel ~= state.displayLevel then
    change_flag = true
    local display_header = {}
    for _, header in ipairs(state.allMdHeaders) do
      if header[3] > state.displayLevel then
        goto continue
      end
      table.insert(display_header, header)
      ::continue::
    end
    state.MdHeaders = display_header
  end

  return change_flag
end

local function render_headers(state, header_level_offset)
  -- get change flag, update headers
  local change_flag = reload_headers(state, header_level_offset)
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
  vim.api.nvim_win_set_cursor(state.TocWin, { index, 0 })
  vim.api.nvim_buf_clear_namespace(state.TocBuf, tocHlNameSpace, 0, -1)
  vim.api.nvim_buf_add_highlight(state.TocBuf, tocHlNameSpace, "Search", index - 1, 0, -1)
end

local function jump_header()
  local state = get_state()
  if not state then
    return
  end
  if not state.MdHeaders then
    reload_headers(state)
  end
  if not state.MdHeaders or #state.MdHeaders == 0 then
    return
  end
  local header_index = math.min(vim.api.nvim_win_get_cursor(0)[1], #state.MdHeaders)
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
