-- Inline output rendering via extmark virtual lines, one mark per executed cell.
local image = require('vimcmdline.notebook.image')

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
  return #parts - 1  -- raw entries added (for the retention trigger counter)
end

-- Number of display lines a text segment contributes: a segment ending in a
-- newline has a trailing '' raw entry that is suppressed at render time.
local function seg_nlines(seg)
  local n = #seg.raw
  if n > 1 and seg.raw[n] == '' then
    return n - 1
  end
  return n
end

local function marker_line(c)
  return { ('··· %d lines elided ···'):format(c.dropped), HL.info }
end

-- The ordered segment walk for a cell: the frozen head (once retention has
-- elided something), a synthetic 1-line elision marker, then the live tail.
-- Cells that never overflowed have everything in c.segments.
local function seg_walk(c)
  if not c.head_segs then
    return c.segments
  end
  local walk = {}
  for _, seg in ipairs(c.head_segs) do
    walk[#walk + 1] = seg
  end
  if c.dropped > 0 then
    walk[#walk + 1] = { kind = 'marker' }
  end
  for _, seg in ipairs(c.segments) do
    walk[#walk + 1] = seg
  end
  return walk
end

-- Flatten accumulated segments into a list of {text, hlgroup} screen lines.
-- Inline-figure segments contribute their placeholder grid rows, tagged with
-- img=true so downstream stages skip truncation/syntax-highlighting for them.
-- The retention marker renders as an info line.
local function flatten(c)
  local out = {}
  for _, seg in ipairs(seg_walk(c)) do
    if seg.kind == 'image' then
      for _, row in ipairs(seg.image.rows) do
        -- w: placeholder rows have a known display width (their column
        -- count); carrying it avoids strdisplaywidth over the long
        -- combining-character strings on every redraw.
        out[#out + 1] = { row, seg.image.hl, img = true, w = seg.image.cols }
      end
    elseif seg.kind == 'marker' then
      out[#out + 1] = marker_line(c)
    else
      local group = HL[seg.kind] or HL.stdout
      local raw = seg.raw
      -- A segment ending in a newline has a trailing '' — skip it so the next
      -- segment is not preceded by a spurious blank line.
      local n = seg_nlines(seg)
      for i = 1, n do
        out[#out + 1] = { raw[i], group }
      end
    end
  end
  while #out > 0 and out[#out][1] == '' do
    table.remove(out)
  end
  return out
end

-- Free terminal-side image placements owned by a cell (about to be dropped).
local function free_cell_images(c)
  for _, seg in ipairs(seg_walk(c)) do
    if seg.kind == 'image' then
      image.free(seg.image.id)
    end
  end
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
  if not ft or l.img or l[2] == HL.info then
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
    if text ~= '' and fallback ~= HL.info and not t.img then
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
    width = math.max(width, l.w or dw(l[1]))
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
  -- Placeholder grid rows are never truncated: their width is already capped
  -- by fit(), and cutting one would corrupt the figure.
  local shown = {}
  for i, l in ipairs(lines) do
    if l.img then
      shown[i] = l
    else
      shown[i] = { trunc(l[1], width), l[2] }
    end
  end
  prefill_hl(ft, shown)

  local virt = { top }
  for _, l in ipairs(shown) do
    local text = l[1]
    local pad = width - (l.w or dw(text))
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

-- ---- output retention (head+tail elision) ---------------------------------
--
-- A runaway cell (`while True: print(...)`) must not grow memory or redraw
-- cost without bound. Each cell keeps at most `cap` text lines (option
-- cmdline_notebook_max_kept_lines; 0 = unlimited): on first overflow the
-- first floor(cap/2) lines are FROZEN as the head, and thereafter lines are
-- dropped from the front of the live tail, so the display shows how the
-- output started and what it is doing now, with an exact
-- "··· N lines elided ···" marker in between. Invariants:
--   * only closed lines strictly behind the streaming splice point are ever
--     dropped — never the open tail line the next chunk may extend;
--   * image segments are exempt: encountered during elision they relocate to
--     the frozen head (they precede all surviving tail content);
--   * trims fire with hysteresis (cap + slack) so per-append cost stays O(1)
--     amortised, and each trim recomputes counts exactly from #raw arithmetic
--     rather than trusting an incremental counter.
local function trim_slack(cap)
  return math.max(8, math.floor(cap / 8))
end

local function trim(c)
  local cap = c.cap
  -- Exact tail total, in display lines.
  local tail_total = 0
  for _, seg in ipairs(c.segments) do
    if seg.kind ~= 'image' then
      tail_total = tail_total + seg_nlines(seg)
    end
  end

  -- First overflow: freeze the head (first floor(cap/2) text lines; images
  -- encountered on the way move with it).
  if not c.head_segs then
    local budget = math.max(1, math.floor(cap / 2))
    local head, taken = {}, 0
    while taken < budget and #c.segments > 0 do
      local seg = c.segments[1]
      if seg.kind == 'image' then
        head[#head + 1] = table.remove(c.segments, 1)
      else
        local n = seg_nlines(seg)
        if n <= budget - taken and #c.segments > 1 then
          head[#head + 1] = table.remove(c.segments, 1)
          taken = taken + n
        else
          local k = math.min(budget - taken, n - 1)  -- never take the open tail
          if k < 1 then
            break
          end
          local piece = {}
          for i = 1, k do
            piece[i] = seg.raw[i]
          end
          head[#head + 1] = { kind = seg.kind, raw = piece }
          local rest = {}
          for i = k + 1, #seg.raw do
            rest[#rest + 1] = seg.raw[i]
          end
          seg.raw = rest
          taken = taken + k
          break
        end
      end
    end
    c.head_segs = head
    c.head_nlines = taken
    tail_total = tail_total - taken
  end

  -- Drop from the front of the tail until head + tail fits the cap.
  local excess = c.head_nlines + tail_total - cap
  local dropped = 0
  while excess > 0 and #c.segments > 0 do
    local seg = c.segments[1]
    if seg.kind == 'image' then
      -- Exempt: relocate before the elided region.
      c.head_segs[#c.head_segs + 1] = table.remove(c.segments, 1)
    else
      local n = seg_nlines(seg)
      local is_last = #c.segments == 1
      if n <= excess and not is_last then
        table.remove(c.segments, 1)
        dropped = dropped + n
        excess = excess - n
      else
        local k = math.min(excess, n - (is_last and 1 or 0))
        if k < 1 then
          break
        end
        local rest = {}
        for i = k + 1, #seg.raw do
          rest[#rest + 1] = seg.raw[i]
        end
        seg.raw = rest
        dropped = dropped + k
        excess = excess - k
        break
      end
    end
  end
  c.dropped = c.dropped + dropped

  -- Reset the (approximate) trigger counter to the exact retained raw count.
  local nraw = 0
  for _, seg in ipairs(c.segments) do
    if seg.kind ~= 'image' then
      nraw = nraw + #seg.raw
    end
  end
  c.nraw = nraw

  if dropped > 0 and not c.notified then
    c.notified = true
    local capv = cap
    vim.schedule(function()
      vim.notify(('europa: cell output exceeded %d kept lines — showing first/last'
        .. ' (:CmdLineNotebookInterrupt stops the cell)'):format(capv),
        vim.log.levels.WARN)
    end)
  end
end

-- Build the display window for redraw WITHOUT materialising every retained
-- line: identical output to "full flatten, trailing-blank trim, then the
-- max_lines cap", but text beyond the window is skipped with per-segment
-- arithmetic instead of being walked line by line.
local function display_lines(c)
  local max = c.max_lines
  local walk = seg_walk(c)

  -- Totals: text lines (the marker counts as one), image rows, and the
  -- trailing blank lines the reference semantics trim before capping.
  local total_text, img_rows = 0, 0
  for _, seg in ipairs(walk) do
    if seg.kind == 'image' then
      img_rows = img_rows + #seg.image.rows
    elseif seg.kind == 'marker' then
      total_text = total_text + 1
    else
      total_text = total_text + seg_nlines(seg)
    end
  end
  local trailing = 0
  do
    local iw = #walk
    while iw >= 1 do
      local seg = walk[iw]
      if seg.kind == 'image' or seg.kind == 'marker' then
        break
      end
      local raw, j = seg.raw, seg_nlines(seg)
      while j >= 1 and raw[j] == '' do
        trailing = trailing + 1
        j = j - 1
      end
      if j >= 1 then
        break
      end
      iw = iw - 1
    end
  end
  local trimmed = total_text - trailing

  local capped = max and max > 0 and (trimmed + img_rows > max)
  local shown = capped and math.min(max - 1, trimmed) or trimmed

  local out, g = {}, 0
  for _, seg in ipairs(walk) do
    if seg.kind == 'image' then
      for _, row in ipairs(seg.image.rows) do
        out[#out + 1] = { row, seg.image.hl, img = true, w = seg.image.cols }
      end
    elseif seg.kind == 'marker' then
      if g < shown then
        out[#out + 1] = marker_line(c)
      end
      g = g + 1
    else
      local n = seg_nlines(seg)
      if g < shown then
        local take = math.min(n, shown - g)
        local group = HL[seg.kind] or HL.stdout
        local raw = seg.raw
        for i = 1, take do
          out[#out + 1] = { raw[i], group }
        end
      end
      g = g + n  -- O(1) skip for segments wholly beyond the window
    end
  end
  local hidden = trimmed - shown
  if capped and hidden > 0 then
    out[#out + 1] = {
      ('… %d more lines (:CmdLineNotebookOpenOutput)'):format(hidden),
      HL.info,
    }
  end
  return out
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
  local lines = display_lines(c)
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
-- `max_kept` is the retention cap (nil => 10000 default; 0 => unlimited).
function M.begin(bufnr, cell_id, start_line, end_line, max_lines, border, marker, ft, max_kept)
  local s = bstate(bufnr)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, math.max(start_line - 1, 0), end_line)
  -- Drop stored output for any earlier run whose range overlaps this one, so
  -- re-running a cell REPLACES its output instead of leaving a stale run that
  -- find_cell() could return (and so cell state does not grow unbounded).
  -- Terminal-side image placements owned by dropped runs are freed.
  for id, c in pairs(s.cells) do
    if c.start_line <= end_line and c.end_line >= start_line then
      free_cell_images(c)
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
    -- retention state
    cap = max_kept == nil and 10000 or max_kept,
    head_segs = nil,
    head_nlines = 0,
    dropped = 0,
    nraw = 0,
    notified = false,
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
    c.nraw = c.nraw + 1
  end
  c.nraw = c.nraw + seg_append(last, text)
  -- Retention: nraw is a cheap raw-entry trigger (>= tail display lines); the
  -- frozen head no longer lives in nraw, so it is added back here — otherwise
  -- the retained total would drift up to head + cap + slack. The trim itself
  -- recomputes exact counts.
  if c.cap > 0 and c.head_nlines + c.nraw > c.cap + trim_slack(c.cap) then
    trim(c)
  end
  schedule(bufnr, cell_id)
end

-- Append an inline figure (already transmitted to the terminal by image.lua):
-- img = {id=..., rows={placeholder row texts}, cols=..., hl=...}.
function M.add_image(bufnr, cell_id, img)
  local c = cell(bufnr, cell_id)
  if not c then
    image.free(img.id)  -- cell vanished between event and render
    return
  end
  c.segments[#c.segments + 1] = { kind = 'image', image = img }
  schedule(bufnr, cell_id)
end

-- Re-fit every displayed figure in `bufnr` to a new size and redraw the cells
-- that changed. Text segments are not touched — only image segments are
-- re-transmitted/re-gridded. Returns the number of figures resized.
function M.resize_images(bufnr, want_cols, cell_aspect, want_rows)
  local s = state[bufnr]
  if not s then
    return 0
  end
  local n = 0
  for cell_id, c in pairs(s.cells) do
    local changed = false
    for _, seg in ipairs(seg_walk(c)) do
      if seg.kind == 'image' and image.resize(seg.image, want_cols, cell_aspect, want_rows) then
        changed = true
        n = n + 1
      end
    end
    if changed then
      redraw(bufnr, cell_id)
    end
  end
  return n
end

-- Resize figures across EVERY buffer render.lua knows about (a figure stays
-- resizable even after its kernel stopped, since the PNG bytes live on the
-- segment). Returns the number of figures resized.
function M.resize_all_images(want_cols, cell_aspect, want_rows)
  local n = 0
  for bufnr in pairs(state) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      n = n + M.resize_images(bufnr, want_cols, cell_aspect, want_rows)
    end
  end
  return n
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
    for _, c in pairs(state[bufnr].cells) do
      free_cell_images(c)
    end
    state[bufnr].cells = {}
  end
end

function M.clear_range(bufnr, start_line, end_line)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.ns, math.max(start_line - 1, 0), end_line)
  local s = state[bufnr]
  if s then
    for id, c in pairs(s.cells) do
      if c.end_line >= start_line and c.end_line <= end_line then
        free_cell_images(c)
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

-- Structured output for the cell in a line range, for the output popup:
-- an ordered list of {kind='text', lines={...}} and {kind='image', png=...,
-- iw=..., ih=...} chunks (image chunks carry the retained PNG bytes so the
-- popup can make its own, larger placement). nil when no cell matches.
function M.get_range_output(bufnr, start_line, end_line)
  local c = find_cell(bufnr, start_line, end_line)
  if not c then
    return nil
  end
  local out = {}
  for _, seg in ipairs(seg_walk(c)) do
    if seg.kind == 'image' then
      out[#out + 1] = { kind = 'image', png = seg.image.png,
                        iw = seg.image.iw, ih = seg.image.ih }
    else
      local lines, n
      if seg.kind == 'marker' then
        lines, n = { marker_line(c)[1] }, 1
      else
        lines, n = seg.raw, seg_nlines(seg)
      end
      local last = out[#out]
      if not (last and last.kind == 'text') then
        last = { kind = 'text', lines = {} }
        out[#out + 1] = last
      end
      for i = 1, n do
        last.lines[#last.lines + 1] = lines[i]
      end
    end
  end
  return out
end

-- Full (untruncated) output text for the cell in a line range, as a list.
-- Inline figures are represented by a one-line note (placeholder glyphs are
-- meaningless outside their highlighted virt_lines).
function M.get_range_text(bufnr, start_line, end_line)
  local c = find_cell(bufnr, start_line, end_line)
  if not c then
    return nil
  end
  local out = {}
  local last_img
  for _, l in ipairs(flatten(c)) do
    if l.img then
      if l[2] ~= last_img then  -- one note per figure, not per grid row
        out[#out + 1] = '[inline figure]'
        last_img = l[2]
      end
    else
      out[#out + 1] = l[1]
      last_img = nil
    end
  end
  return out
end

return M
