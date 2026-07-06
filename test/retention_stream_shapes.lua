-- Regression: runaway-output retention must hold for stream shapes that never
-- (or rarely) emit a newline — '\r' progress bars (tqdm) and print(end='')
-- floods. Before the fix these bypassed the line-count trigger entirely: the
-- open tail line grew without bound, with O(n^2) re-concatenation per chunk.
--   nvim --headless -u NONE -N -l test/retention_stream_shapes.lua
vim.opt.rtp:prepend('.')
local render = require('vimcmdline.notebook.render')

local fail = 0
local function check(label, cond, detail)
  if cond then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. (detail and (' [' .. tostring(detail) .. ']') or ''))
  end
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'run()' })

local function retained_bytes(s, e)
  local t = render.get_range_text(buf, s, e) or {}
  local b = 0
  for _, l in ipairs(t) do
    b = b + #l + 1
  end
  return b, t
end

-- 1. '\r' progress bar: thousands of repaints collapse to the final visible
--    state, not an ever-growing tail.
render.begin(buf, 1, 2, 2, 20, 'rounded', true, nil, 100)
for i = 1, 5000 do
  render.add(buf, 1, 'stdout', ('\r%3d%% |%s|'):format(i % 101, string.rep('#', 40)))
end
render.mark_done(buf, 1, 1, 'ok')
local bytes, lines = retained_bytes(2, 2)
check('cr_bar_single_line', #lines == 1, #lines .. ' lines')
check('cr_bar_shows_last_repaint', lines[1] ~= nil
  and lines[1]:find('%', 1, true) ~= nil and #lines[1] < 100, lines[1])

-- 2. Newline-free flood (print(end='')): retained bytes stay near the byte
--    budget (cap * 256), with the elision marker present.
local cap = 100
render.begin(buf, 2, 2, 2, 20, 'rounded', true, nil, cap)
for i = 1, 2000 do
  render.add(buf, 2, 'stdout', string.rep('x', 100))
end
render.mark_done(buf, 2, 2, 'ok')
-- Byte budget covers head + tail; allow the trigger hysteresis (budget/8) and
-- up to two TAIL_SPLIT pieces of slop (one open remainder each side of trim).
local budget = cap * 256
local bound = budget + math.floor(budget / 8) + 2 * 4096 + 200
bytes, lines = retained_bytes(2, 2)
check('no_newline_flood_bounded', bytes <= bound,
  bytes .. ' bytes vs bound ' .. bound)
local joined = table.concat(lines, '\n')
check('no_newline_flood_elision_marker', joined:find('elided', 1, true) ~= nil)

-- 3. The flood cost is flat, not quadratic. 200k bytes of newline-free stream
--    used to cost ~gigabytes of string copying; bounded tail keeps it well
--    under a generous wall-clock budget.
local t0 = vim.loop.hrtime()
render.begin(buf, 3, 2, 2, 20, 'rounded', true, nil, cap)
for i = 1, 5000 do
  render.add(buf, 3, 'stdout', string.rep('y', 100))
end
render.mark_done(buf, 3, 3, 'ok')
local ms = (vim.loop.hrtime() - t0) / 1e6
check('no_newline_flood_flat_cost', ms < 5000, ('%.0f ms'):format(ms))

-- 4. UTF-8 safety: tail splitting never cuts inside a codepoint, so every
--    retained line starts at a codepoint boundary.
render.begin(buf, 4, 2, 2, 20, 'rounded', true, nil, cap)
for i = 1, 3000 do
  render.add(buf, 4, 'stdout', string.rep('é', 10))  -- 2-byte codepoints
end
render.mark_done(buf, 4, 4, 'ok')
local _, ulines = retained_bytes(2, 2)
local utf8_ok = true
for _, l in ipairs(ulines) do
  local b = l:byte(1)
  if b and b >= 0x80 and b < 0xC0 then
    utf8_ok = false
  end
end
check('tail_split_utf8_boundary', utf8_ok)

-- 5. Ordinary newline-terminated retention still behaves (marker + head kept).
render.begin(buf, 5, 2, 2, 20, 'rounded', true, nil, cap)
for i = 1, 1000 do
  render.add(buf, 5, 'stdout', ('line %d\n'):format(i))
end
render.mark_done(buf, 5, 5, 'ok')
local _, nlines = retained_bytes(2, 2)
local njoined = table.concat(nlines, '\n')
check('newline_flood_still_capped', #nlines <= cap + 20, #nlines .. ' lines')
check('newline_flood_head_kept', njoined:find('line 1\n', 1, true) ~= nil)
check('newline_flood_tail_kept', njoined:find('line 1000', 1, true) ~= nil)
check('newline_flood_marker', njoined:find('elided', 1, true) ~= nil)

-- 6. Mixed: '\r' repaints interleaved with real newlines keep the closed lines.
render.begin(buf, 6, 2, 2, 20, 'rounded', true, nil, cap)
render.add(buf, 6, 'stdout', 'epoch 1\n')
for i = 1, 200 do
  render.add(buf, 6, 'stdout', ('\rprogress %d'):format(i))
end
render.add(buf, 6, 'stdout', '\ndone\n')
render.mark_done(buf, 6, 6, 'ok')
local _, mlines = retained_bytes(2, 2)
local mjoined = table.concat(mlines, '\n')
check('mixed_keeps_closed_lines', mjoined:find('epoch 1', 1, true) ~= nil
  and mjoined:find('done', 1, true) ~= nil)
check('mixed_collapses_repaints', mjoined:find('progress 200', 1, true) ~= nil
  and mjoined:find('progress 199', 1, true) == nil)

if fail > 0 then
  vim.cmd('cquit!')
else
  print('RETENTION STREAM SHAPES OK')
  vim.cmd('qall!')
end
