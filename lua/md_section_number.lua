local parser = require("md_section_number.heading.parser")
local replacer = require("md_section_number.heading.replacer")
local toc = require("md_section_number.toc")
local M = {}

local DEFAULT_OPTS = {
  max_level = 4,
  min_level = 1,
  directory_relativenumber = true,
  ignore_pairs = {
    { "```", "```" },
    { "\\~\\~\\~", "\\~\\~\\~" },
    { "<!--", "-->" },
  },
  toc = {
    width = 30,
    position = "right",
    indent_space_number = 2,
    header_prefix = "- ",
    toc_level = 6,
    winopts = {
      relativenumber = true,
    },
  },
}

local function setup_directory_relativenumber(enabled)
  local group = vim.api.nvim_create_augroup("MSNDirectoryRelativenumberGroup", { clear = true })
  if not enabled then
    return
  end

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "FileType" }, {
    group = group,
    callback = function()
      local filetype = vim.bo.filetype
      local bufname = vim.api.nvim_buf_get_name(0)
      if filetype == "netrw" or (bufname ~= "" and vim.fn.isdirectory(bufname) == 1) then
        vim.opt_local.relativenumber = true
      end
    end,
  })
end

local function merge_options(conf)
  return vim.tbl_deep_extend("force", DEFAULT_OPTS, conf or {})
end

local function judge_heading_by_line_number(start_line, end_line, cur_line)
  if start_line == -1 or end_line == -1 then
    return true
  end
  if start_line == nil or end_line == nil then
    return true
  end
  return start_line <= cur_line and cur_line <= end_line
end

function M.setup(conf)
  local opts = merge_options(conf)
  if not opts then
    return
  end
  parser.setup(opts)
  replacer.setup(opts)
  toc.setup(opts.toc)
  setup_directory_relativenumber(opts.directory_relativenumber)
end

local function get_headings(...)
  local origin_heading_lines = parser.get_heading_lines(vim.api.nvim_buf_get_lines(0, 0, -1, false))
  local heading_lines = {}
  if select("#", ...) == 3 then
    local start_line, end_line, offset = ...
    for _, heading in ipairs(origin_heading_lines) do
      if judge_heading_by_line_number(start_line, end_line, heading[1] + 1) then
        table.insert(heading_lines, replacer.change_heading_level(heading, offset))
      else
        table.insert(heading_lines, heading)
      end
    end
  else
    heading_lines = origin_heading_lines
  end
  return origin_heading_lines, heading_lines
end

function M._update_heading_number(is_clear, start_line, end_line, ...)
  local origin_heading_lines, heading_lines = get_headings(start_line, end_line, ...)
  heading_lines = replacer.insert_heading_number(heading_lines)
  if nil == heading_lines or #heading_lines == 0 then
    return
  end
  for index, heading in ipairs(heading_lines) do
    local line_index = heading[1]
    local heading_content = heading[2]
    local origin_heading_content = origin_heading_lines[index][2]
    local level = heading[3]
    local heading_number = heading[4]
    local updated_heading_content = replacer.replaceHeadingNumber(heading_content, heading_number, level, is_clear)
    if
      origin_heading_content ~= updated_heading_content
      and judge_heading_by_line_number(start_line, end_line, line_index + 1)
    then
      replacer.update_line(line_index, string.len(origin_heading_content), updated_heading_content)
    end
  end
end

function M.update_heading_number(firstline, lastline)
  M._update_heading_number(false, firstline, lastline)
end

function M.clear_heading_number(firstline, lastline)
  M._update_heading_number(true, firstline, lastline)
end

function M.header_decrease(firstline, lastline)
  M._update_heading_number(true, firstline, lastline, -1)
end

function M.header_increase(firstline, lastline)
  M._update_heading_number(true, firstline, lastline, 1)
end

function M.toggle_toc()
  toc.toggle()
end

return M
