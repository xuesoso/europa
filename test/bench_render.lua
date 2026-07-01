-- Performance benchmark for the notebook render layer.
--
-- Two workloads that mirror running many cell blocks:
--   * chatty   — cells that stream output line-by-line; each new line forces a
--                redraw (worst case for the syntax-highlight + flatten cost).
--   * batch    — many queued cells, each finalized with one redraw (the common
--                "run all cells" / queued shape).
--
-- Prints wall time per workload. Also asserts the rendered text is correct, so
-- an optimization that speeds things up but changes output is caught here.
--
--   nvim --headless -u NONE -N -l test/bench_render.lua
vim.opt.rtp:prepend('.')
local render = require('vimcmdline.notebook.render')

local FT = 'python'            -- exercise the per-line syntax-highlight path
local BORDER = 'rounded'

-- Force a synchronous redraw (the real code debounces via defer_fn; the bench
-- drives it directly so timings are deterministic). M.finish clears the pending
-- flag and redraws now.
local function redraw_now(buf, id) render.finish(buf, id) end

local function ns() return vim.loop.hrtime() end
local function ms(dt) return dt / 1e6 end

-- A python-ish output line, unique per (cell,line) so cross-cell caching cannot
-- cheat; within a cell earlier lines recur across redraws (the realistic case).
local function line(cellidx, i)
  return string.format('result_%d = compute(%d, %d)  # value for cell %d', i, i * 2, i * 3, cellidx)
end

-- Warm up: first use of a filetype loads its syntax; keep that out of the timed
-- section so we measure steady-state cost.
do
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'warmup' })
  render.begin(b, 1, 1, 1, 200, BORDER, true, FT)
  render.add(b, 1, 'stdout', line(0, 1) .. '\n')
  redraw_now(b, 1)
end

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

-- Chatty workload: CELLS cells, each streaming LINES lines one chunk at a time,
-- redrawing after every chunk. Total redraws = CELLS * LINES, each redraw over a
-- growing output block.
local function bench_chatty(cells, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
  local seq = 0
  local t0 = ns()
  for c = 1, cells do
    seq = seq + 1
    render.begin(buf, seq, 1, 1, 200, BORDER, true, FT)
    for i = 1, lines do
      render.add(buf, seq, 'stdout', line(c, i) .. '\n')
      redraw_now(buf, seq)  -- a redraw per streamed line
    end
    render.mark_done(buf, seq, c, 'ok')
  end
  local dt = ns() - t0
  -- Correctness: last cell's captured text must be exactly its LINES lines.
  local txt = render.get_range_text(buf, 1, 1)
  check('chatty_line_count', txt and #txt or 0, lines)
  check('chatty_first_line', txt and txt[1] or nil, line(cells, 1))
  check('chatty_last_line', txt and txt[#txt] or nil, line(cells, lines))
  return dt
end

-- Batch/queued workload: CELLS cells, each gets all its output in one add and a
-- single redraw (mark_done). Mirrors "run all" where each cell finalizes once.
local function bench_batch(cells, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
  local seq = 0
  local t0 = ns()
  for c = 1, cells do
    seq = seq + 1
    render.begin(buf, seq, 1, 1, 200, BORDER, true, FT)
    local chunk = {}
    for i = 1, lines do
      chunk[#chunk + 1] = line(c, i)
    end
    render.add(buf, seq, 'stdout', table.concat(chunk, '\n') .. '\n')
    render.mark_done(buf, seq, c, 'ok')  -- one redraw
  end
  local dt = ns() - t0
  local txt = render.get_range_text(buf, 1, 1)
  check('batch_line_count', txt and #txt or 0, lines)
  check('batch_last_line', txt and txt[#txt] or nil, line(cells, lines))
  return dt
end

-- Re-run workload: the same notebook (fixed set of cells) executed top-to-bottom
-- RERUNS times. Output lines depend only on the line index (not the run), so a
-- second run reproduces the same text — the edit/run-all/repeat loop everyone
-- actually does. Uses a stable per-line string so reruns recur.
local function bench_rerun(cells, lines, reruns)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
  local seq = 0
  local function stable(c, i)
    return string.format('cell_%d_line_%d = value(%d)', c, i, i)
  end
  local t0 = ns()
  for _ = 1, reruns do
    for c = 1, cells do
      seq = seq + 1
      render.begin(buf, seq, 1, 1, 200, BORDER, true, FT)
      local chunk = {}
      for i = 1, lines do
        chunk[#chunk + 1] = stable(c, i)
      end
      render.add(buf, seq, 'stdout', table.concat(chunk, '\n') .. '\n')
      render.mark_done(buf, seq, c, 'ok')
    end
  end
  local dt = ns() - t0
  local txt = render.get_range_text(buf, 1, 1)
  check('rerun_line_count', txt and #txt or 0, lines)
  check('rerun_last_line', txt and txt[#txt] or nil, stable(cells, lines))
  return dt
end

local CHATTY_CELLS, CHATTY_LINES = 8, 40
local BATCH_CELLS, BATCH_LINES = 200, 20
local RERUN_CELLS, RERUN_LINES, RERUNS = 30, 20, 10

local d_chatty = bench_chatty(CHATTY_CELLS, CHATTY_LINES)
local d_batch = bench_batch(BATCH_CELLS, BATCH_LINES)
local d_rerun = bench_rerun(RERUN_CELLS, RERUN_LINES, RERUNS)

print('----------------------------------------')
print(string.format('chatty  %d cells x %d lines (redraw/line): %8.1f ms',
  CHATTY_CELLS, CHATTY_LINES, ms(d_chatty)))
print(string.format('batch   %d cells x %d lines (1 redraw ea): %8.1f ms',
  BATCH_CELLS, BATCH_LINES, ms(d_batch)))
print(string.format('rerun   %d cells x %d lines x %d runs:     %8.1f ms',
  RERUN_CELLS, RERUN_LINES, RERUNS, ms(d_rerun)))
print(string.format('TOTAL:                                    %8.1f ms',
  ms(d_chatty + d_batch + d_rerun)))
print('----------------------------------------')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('BENCH OK')
  vim.cmd('qall!')
end
