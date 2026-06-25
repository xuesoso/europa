-- Inline output rendering via extmark virtual lines, one mark per executed cell.
local M = {}

M.ns = vim.api.nvim_create_namespace('vimcmdline_notebook')

-- bufnr -> { cells = { [cell_id] = {end_line,start_line,segments,mark_id,pending,max_lines} } }
local state = {}

local HL = {
  stdout = 'CmdlineNotebookStdout',
  stderr = 'CmdlineNotebookStderr',
  error  = 'CmdlineNotebookError',
  result = 'CmdlineNotebookResult',
  info   = 'CmdlineNotebookPrompt',
  ok     = 'CmdlineNotebookOk',
}

local function bstate(bufnr)
  state[bufnr] = state[bufnr] or { cells = {} }
  return state[bufnr]
end

local function cell(bufnr, cell_id)
  local s = state[bufnr]
  return s and s.cells[cell_id] or nil
end

-- Flatten accumulated segments into a list of {text, hlgroup} screen lines.
local function flatten(c)
  local out = {}
  for _, seg in ipairs(c.segments) do
    local group = HL[seg.kind] or HL.stdout
    local parts = vim.split(seg.text, '\n', { plain = true })
    -- A segment ending in a newline yields a trailing "" — drop it so the next
    -- segment is not preceded by a spurious blank line.
    if #parts > 1 and parts[#parts] == '' then
      table.remove(parts)
    end
    for _, part in ipairs(parts) do
      out[#out + 1] = { part, group }
    end
  end
  while #out > 0 and out[#out][1] == '' do
    table.remove(out)
  end
  return out
end

local BORDER_HL = 'CmdlineNotebookBorder'

local BORDERS = {
  rounded = { tl = '╭', tr = '╮', bl = '╰', br = '╯', h = '─', v = '│' },
  single  = { tl = '┌', tr = '┐', bl = '└', br = '┘', h = '─', v = '│' },
  double  = { tl = '╔', tr = '╗', bl = '╚', br = '╝', h = '═', v = '║' },
}

-- Truncate text to a maximum display width, adding an ellipsis if cut.
local function trunc(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end
  local lo, hi = 0, vim.fn.strchars(text)
  while lo < hi do
    local mid = math.floor((lo + hi + 1) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid)) <= width - 1 then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return vim.fn.strcharpart(text, 0, lo) .. '…'
end

-- Turn the {text, hlgroup} lines into extmark virt_lines, optionally wrapped in
-- a box with the given border style (nil/'none'/unknown => no box).
-- Build the extmark virt_lines for a cell. `title` (optional {text, hl}) is the
-- run marker: embedded in the box's top border when there is output, or drawn
-- as a single rule line ("─── ✓ [N] ───") when there is none.
local function build_virt(lines, border, title)
  local b = BORDERS[border]

  -- No border: plain lines, with the title (if any) as a leading plain line.
  if not b then
    local virt = {}
    if title then
      virt[#virt + 1] = { { title[1], title[2] } }
    end
    for _, l in ipairs(lines) do
      virt[#virt + 1] = { { l[1], l[2] } }
    end
    return virt
  end

  -- Bordered, no output: a single rule line embedding the title.
  if #lines == 0 then
    if not title then
      return {}
    end
    return {
      {
        { string.rep(b.h, 3) .. ' ', BORDER_HL },
        { title[1], title[2] },
        { ' ' .. string.rep(b.h, 3), BORDER_HL },
      },
    }
  end

  -- Bordered box; the title (if any) is embedded in the top border.
  local cap = math.max((vim.o.columns or 80) - 4, 10)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l[1]))
  end
  if title then
    width = math.max(width, vim.fn.strdisplaywidth(title[1]) + 2)
  end
  if width > cap then
    width = cap
  end

  local top
  if title then
    local fill = math.max(width - 1 - vim.fn.strdisplaywidth(title[1]), 0)
    top = {
      { b.tl .. b.h .. ' ', BORDER_HL },
      { title[1], title[2] },
      { ' ' .. string.rep(b.h, fill) .. b.tr, BORDER_HL },
    }
  else
    top = { { b.tl .. string.rep(b.h, width + 2) .. b.tr, BORDER_HL } }
  end

  local virt = { top }
  for _, l in ipairs(lines) do
    local text = trunc(l[1], width)
    local pad = width - vim.fn.strdisplaywidth(text)
    virt[#virt + 1] = {
      { b.v .. ' ', BORDER_HL },
      { text, l[2] },
      { string.rep(' ', pad) .. ' ' .. b.v, BORDER_HL },
    }
  end
  virt[#virt + 1] = { { b.bl .. string.rep(b.h, width + 2) .. b.br, BORDER_HL } }
  return virt
end

local function redraw(bufnr, cell_id)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local c = cell(bufnr, cell_id)
  if not c then
    return
  end
  local lines = flatten(c)
  local max = c.max_lines
  if max and max > 0 and #lines > max then
    local kept = {}
    for i = 1, max - 1 do
      kept[i] = lines[i]
    end
    kept[#kept + 1] = {
      ('… %d more lines (:CmdLineNotebookOpenOutput)'):format(#lines - (max - 1)),
      HL.info,
    }
    lines = kept
  end
  -- The run marker ("✓ [N]" / "✗ [N]") is drawn in the border once finished:
  -- embedded in the top border for cells with output, or as a single rule line
  -- for cells with none.
  local title = nil
  if c.marker and c.done then
    local label = c.ok and '✓' or '✗'
    if c.count then
      label = label .. (' [%d]'):format(c.count)
    end
    title = { label, c.ok and HL.ok or HL.error }
  end
  local virt = build_virt(lines, c.border, title)
  if #virt == 0 then
    if c.mark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, M.ns, c.mark_id)
      c.mark_id = nil
    end
    return
  end
  local linecount = vim.api.nvim_buf_line_count(bufnr)
  local line0 = math.min(math.max(c.end_line - 1, 0), linecount - 1)
  local opts = {
    virt_lines = virt,
    virt_lines_above = false,
    invalidate = true,
    undo_restore = false,
  }
  if c.mark_id then
    opts.id = c.mark_id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, line0, 0, opts)
  if ok then
    c.mark_id = id
  end
end

-- Coalesce rapid updates so a chatty loop does not thrash the screen.
local function schedule(bufnr, cell_id)
  local c = cell(bufnr, cell_id)
  if not c or c.pending then
    return
  end
  c.pending = true
  vim.defer_fn(function()
    local cc = cell(bufnr, cell_id)
    if cc then
      cc.pending = false
      redraw(bufnr, cell_id)
    end
  end, 40)
end

-- Begin a fresh cell run: clear any prior output anchored in the cell's range.
function M.begin(bufnr, cell_id, start_line, end_line, max_lines, border, marker)
  local s = bstate(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, math.max(start_line - 1, 0), end_line)
  -- Drop stored output for any earlier run whose range overlaps this one, so
  -- re-running a cell REPLACES its output instead of leaving a stale run that
  -- find_cell() could return (and so cell state does not grow unbounded).
  for id, c in pairs(s.cells) do
    if c.start_line <= end_line and c.end_line >= start_line then
      s.cells[id] = nil
    end
  end
  s.cells[cell_id] = {
    end_line = end_line,
    start_line = start_line,
    segments = {},
    mark_id = nil,
    pending = false,
    max_lines = max_lines,
    border = border,
    marker = marker,
    done = false,
    count = nil,
    ok = true,
  }
end

-- Mark a cell finished: record the execution count and ok/error status so the
-- "✓ [N]" / "✗ [N]" run marker can be drawn.
function M.mark_done(bufnr, cell_id, count, status)
  local c = cell(bufnr, cell_id)
  if not c then
    return
  end
  c.done = true
  c.pending = false
  c.count = count
  c.ok = status ~= 'error'
  redraw(bufnr, cell_id)
end

function M.add(bufnr, cell_id, kind, text)
  local c = cell(bufnr, cell_id)
  if not c then
    return
  end
  local last = c.segments[#c.segments]
  if last and last.kind == kind then
    last.text = last.text .. text
  else
    c.segments[#c.segments + 1] = { kind = kind, text = text }
  end
  schedule(bufnr, cell_id)
end

-- Force an immediate redraw (called on idle / execute_reply).
function M.finish(bufnr, cell_id)
  local c = cell(bufnr, cell_id)
  if not c then
    return
  end
  c.pending = false
  redraw(bufnr, cell_id)
end

function M.clear_all(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, 0, -1)
  if state[bufnr] then
    state[bufnr].cells = {}
  end
end

function M.clear_range(bufnr, start_line, end_line)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, math.max(start_line - 1, 0), end_line)
  local s = state[bufnr]
  if s then
    for id, c in pairs(s.cells) do
      if c.end_line >= start_line and c.end_line <= end_line then
        s.cells[id] = nil
      end
    end
  end
end

local function find_cell(bufnr, start_line, end_line)
  local s = state[bufnr]
  if not s then
    return nil
  end
  -- Return the most recent (highest cell_id) run whose anchor is in range.
  local best, best_id
  for id, c in pairs(s.cells) do
    if c.end_line >= start_line and c.end_line <= end_line then
      if not best_id or id > best_id then
        best, best_id = c, id
      end
    end
  end
  return best
end

-- Full (untruncated) output text for the cell in a line range, as a list.
function M.get_range_text(bufnr, start_line, end_line)
  local c = find_cell(bufnr, start_line, end_line)
  if not c then
    return nil
  end
  local out = {}
  for _, l in ipairs(flatten(c)) do
    out[#out + 1] = l[1]
  end
  return out
end

return M
