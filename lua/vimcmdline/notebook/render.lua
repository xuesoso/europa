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

-- A segment stores its output pre-split into lines (seg.raw), maintained
-- incrementally as chunks are appended: appending a chunk splices its first
-- part onto the open tail line and appends the rest. This is equivalent to
-- split(concat(chunks), '\n') — raw's last element is '' exactly when the
-- accumulated text ends in a newline — but each redraw no longer re-joins and
-- re-splits the whole segment (which made streaming N lines O(N^2)).
local function seg_append(seg, text)
  local parts = vim.split(text, '\n', { plain = true })
  local raw = seg.raw
  raw[#raw] = raw[#raw] .. parts[1]
  for i = 2, #parts do
    raw[#raw + 1] = parts[i]
  end
end

-- Flatten accumulated segments into a list of {text, hlgroup} screen lines.
local function flatten(c)
  local out = {}
  for _, seg in ipairs(c.segments) do
    local group = HL[seg.kind] or HL.stdout
    local raw = seg.raw
    -- A segment ending in a newline has a trailing '' — skip it so the next
    -- segment is not preceded by a spurious blank line.
    local n = #raw
    if n > 1 and raw[n] == '' then
      n = n - 1
    end
    for i = 1, n do
      out[#out + 1] = { raw[i], group }
    end
  end
  while #out > 0 and out[#out][1] == '' do
    table.remove(out)
  end
  return out
end

-- ft -> scratch bufnr, reused across redraws to color output text with the
-- parent file's syntax instead of one flat color per output kind.
local syntax_bufs = {}

local function get_syntax_buf(ft)
  local buf = syntax_bufs[ft]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = ft
  syntax_bufs[ft] = buf
  return buf
end

-- Highlight-run cache. Keyed by ft \0 fallback_hl \0 text; the value is the list
-- of {chunk, hlgroup} runs. Every redraw re-highlights ALL of a cell's output
-- lines, and while a cell streams the earlier lines recur unchanged on each
-- redraw, so the same (ft, text) is highlighted over and over — caching turns
-- those repeats into a table lookup. Runs depend only on the syntax rules, not
-- on colours, so a :colorscheme change (which only recolours existing groups)
-- never invalidates them. Bounded by a hard cap: when exceeded the whole cache
-- is dropped (cheap, and streaming's ever-growing partial lines would otherwise
-- accrete stale one-shot keys).
local hl_cache = {}
local hl_cache_n = 0
local HL_CACHE_MAX = 4096

local function hl_cache_put(key, runs)
  if hl_cache_n >= HL_CACHE_MAX then
    hl_cache = {}
    hl_cache_n = 0
  end
  hl_cache[key] = runs
  hl_cache_n = hl_cache_n + 1
end

local function hl_key(ft, fallback_hl, text)
  return ft .. '\0' .. fallback_hl .. '\0' .. text
end

-- Compute and cache highlight runs for a BATCH of uncached lines in a single
-- nvim_buf_call: one context switch and one `syntax sync` per redraw instead
-- of one per line. Each text is still highlighted as line 1 of the scratch
-- buffer (per-line isolation, identical to highlighting them one at a time).
--
-- The column scan is a SINGLE strictly-ascending synID pass per line, with the
-- ids collected into a Lua table and the runs derived afterwards. This matters
-- far more than it looks: Vim's syntax engine computes column state
-- incrementally left-to-right, and RE-querying a column it has already passed
-- (which the old run-boundary loop did once per run, when the inner loop's
-- mismatch column was re-queried as the next run's start) forces it to
-- restart parsing the line from the sync point — measured ~5x slower for
-- identical query counts. Group names are resolved once per distinct id via a
-- per-batch memo, not per column.
local function ft_highlight_fill(ft, jobs)
  if vim.g.syntax_on ~= 1 then
    pcall(vim.cmd, 'syntax enable')
  end
  local buf = get_syntax_buf(ft)
  local synID, synIDtrans, synIDattr = vim.fn.synID, vim.fn.synIDtrans, vim.fn.synIDattr
  local set_lines = vim.api.nvim_buf_set_lines
  local names = {}  -- id -> resolved group name ('' when none)
  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd('syntax sync fromstart')
    for _, job in ipairs(jobs) do
      local text, fallback_hl = job[2], job[3]
      set_lines(buf, 0, -1, false, { text })
      local len = #text
      local ids = {}
      for col = 1, len do
        ids[col] = synID(1, col, 1)
      end
      local runs = {}
      local s = 1
      for col = 2, len + 1 do
        if col > len or ids[col] ~= ids[s] then
          local id = ids[s]
          local name = names[id]
          if name == nil then
            name = id ~= 0 and synIDattr(synIDtrans(id), 'name') or ''
            names[id] = name
          end
          runs[#runs + 1] = { text:sub(s, col - 1), (name ~= '' and name) or fallback_hl }
          s = col
        end
      end
      if #runs == 0 then
        runs = { { text, fallback_hl } }
      end
      hl_cache_put(job[1], runs)
    end
  end)
  if not ok then
    for _, job in ipairs(jobs) do
      hl_cache_put(job[1], { { job[2], job[3] } })
    end
  end
end

-- Split `text` into {chunk, hlgroup} runs following filetype `ft`'s :syntax
-- highlighting. Falls back to a single `fallback_hl` run when `ft` is empty
-- or has no syntax definitions (e.g. plain stdout with no filetype).
local function ft_highlight_line(ft, text, fallback_hl)
  if not ft or ft == '' or text == '' then
    return { { text, fallback_hl } }
  end
  local key = hl_key(ft, fallback_hl, text)
  local hit = hl_cache[key]
  if hit then
    return hit
  end
  ft_highlight_fill(ft, { { key, text, fallback_hl } })
  return hl_cache[key] or { { text, fallback_hl } }
end

-- Display-width cache: build_virt asks for the width of every line on every
-- redraw and lines recur unchanged across a cell's redraws, so memoise
-- strdisplaywidth (a vim.fn crossing) per text. Same drop-all cap as the
-- highlight cache.
local width_cache = {}
local width_cache_n = 0
local WIDTH_CACHE_MAX = 8192

local function dw(text)
  local w = width_cache[text]
  if w then
    return w
  end
  w = vim.fn.strdisplaywidth(text)
  if width_cache_n >= WIDTH_CACHE_MAX then
    width_cache = {}
    width_cache_n = 0
  end
  width_cache[text] = w
  width_cache_n = width_cache_n + 1
  return w
end

local BORDER_HL = 'CmdlineNotebookBorder'

local BORDERS = {
  rounded = { tl = '╭', tr = '╮', bl = '╰', br = '╯', h = '─', v = '│' },
  single  = { tl = '┌', tr = '┐', bl = '└', br = '┘', h = '─', v = '│' },
  double  = { tl = '╔', tr = '╗', bl = '╚', br = '╝', h = '═', v = '║' },
}

-- Truncate text to a maximum display width, adding an ellipsis if cut.
local function trunc(text, width)
  if dw(text) <= width then
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
-- Color a content line's text per `ft`'s syntax, unless it is one of our own
-- plugin notices (drawn in HL.info) rather than actual kernel output.
local function content_runs(l, ft)
  if not ft or l[2] == HL.info then
    return { { l[1], l[2] } }
  end
  return ft_highlight_line(ft, l[1], l[2])
end

-- Pre-fill the highlight cache for every content line that will need syntax
-- runs, in ONE batched nvim_buf_call, so the per-line content_runs calls below
-- are pure cache hits. `texts` is a list of {text, fallback_hl}.
local function prefill_hl(ft, texts)
  if not ft or ft == '' then
    return
  end
  local jobs
  for _, t in ipairs(texts) do
    local text, fallback = t[1], t[2]
    if text ~= '' and fallback ~= HL.info then
      local key = hl_key(ft, fallback, text)
      if not hl_cache[key] then
        jobs = jobs or {}
        jobs[#jobs + 1] = { key, text, fallback }
      end
    end
  end
  if jobs then
    ft_highlight_fill(ft, jobs)
  end
end

local function build_virt(lines, border, title, ft)
  local b = BORDERS[border]

  -- No border: plain lines, with the title (if any) as a leading plain line.
  if not b then
    local virt = {}
    if title then
      virt[#virt + 1] = { { title[1], title[2] } }
    end
    prefill_hl(ft, lines)
    for _, l in ipairs(lines) do
      virt[#virt + 1] = content_runs(l, ft)
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
    width = math.max(width, dw(l[1]))
  end
  if title then
    width = math.max(width, dw(title[1]) + 2)
  end
  if width > cap then
    width = cap
  end

  local top
  if title then
    local fill = math.max(width - 1 - dw(title[1]), 0)
    top = {
      { b.tl .. b.h .. ' ', BORDER_HL },
      { title[1], title[2] },
      { ' ' .. string.rep(b.h, fill) .. b.tr, BORDER_HL },
    }
  else
    top = { { b.tl .. string.rep(b.h, width + 2) .. b.tr, BORDER_HL } }
  end

  -- Truncate every line up front, then batch-highlight the truncated texts
  -- (truncation changes the text, so the cache key is the truncated form).
  local shown = {}
  for i, l in ipairs(lines) do
    shown[i] = { trunc(l[1], width), l[2] }
  end
  prefill_hl(ft, shown)

  local virt = { top }
  for _, l in ipairs(shown) do
    local text = l[1]
    local pad = width - dw(text)
    local chunks = { { b.v .. ' ', BORDER_HL } }
    for _, run in ipairs(content_runs(l, ft)) do
      chunks[#chunks + 1] = run
    end
    chunks[#chunks + 1] = { string.rep(' ', pad) .. ' ' .. b.v, BORDER_HL }
    virt[#virt + 1] = chunks
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
  c.last_draw = vim.loop.hrtime() / 1e6
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
    -- Guard the format: an aborted cell has no execution count (see mark_done),
    -- and only a real number is valid for '%d'.
    if type(c.count) == 'number' then
      label = label .. (' [%d]'):format(c.count)
    end
    title = { label, c.ok and HL.ok or HL.error }
  end
  local virt = build_virt(lines, c.border, title, c.ft)
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

-- Coalesce rapid updates so a chatty loop does not thrash the screen, but
-- paint the LEADING edge: the first update after a quiet period draws
-- immediately (so a cell's first output appears without the debounce delay),
-- and only updates arriving within the debounce window are deferred.
local REDRAW_DEBOUNCE_MS = 40

local function schedule(bufnr, cell_id)
  local c = cell(bufnr, cell_id)
  if not c or c.pending then
    return
  end
  local now = vim.loop.hrtime() / 1e6
  if not c.last_draw or (now - c.last_draw) >= REDRAW_DEBOUNCE_MS then
    redraw(bufnr, cell_id)
    return
  end
  c.pending = true
  vim.defer_fn(function()
    local cc = cell(bufnr, cell_id)
    if cc then
      cc.pending = false
      redraw(bufnr, cell_id)
    end
  end, REDRAW_DEBOUNCE_MS)
end

-- Begin a fresh cell run: clear any prior output anchored in the cell's range.
function M.begin(bufnr, cell_id, start_line, end_line, max_lines, border, marker, ft)
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
    ft = ft,
    done = false,
    count = nil,
    ok = true,
  }
end

-- Mark a cell finished: record the execution count and ok/error status so the
-- "✓ [N]" / "✗ [N]" run marker can be drawn.
--
-- A cell that was queued behind one that errored gets aborted by the kernel: it
-- reports status 'aborted' and execution_count null, which arrives here as
-- vim.NIL (a userdata) after JSON decoding. Normalise both so the marker never
-- formats the sentinel (vim.NIL is truthy, so a plain `if count` does not catch
-- it) and an aborted/errored cell is never shown as a success.
function M.mark_done(bufnr, cell_id, count, status)
  local c = cell(bufnr, cell_id)
  if not c then
    return
  end
  c.done = true
  c.pending = false
  c.count = type(count) == 'number' and count or nil
  c.ok = status == 'ok'
  redraw(bufnr, cell_id)
end

function M.add(bufnr, cell_id, kind, text)
  local c = cell(bufnr, cell_id)
  if not c then
    return
  end
  local last = c.segments[#c.segments]
  if not (last and last.kind == kind) then
    last = { kind = kind, raw = { '' } }
    c.segments[#c.segments + 1] = last
  end
  seg_append(last, text)
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
