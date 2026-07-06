-- Retention (head+tail elision) + windowed-redraw tests.
--
-- The cornerstone is a REFERENCE IMPLEMENTATION of the pre-retention
-- algorithm (concat chunks per segment, full split, trailing-blank trim,
-- then the max_lines display cap). Below the retention cap the new windowed
-- renderer must reproduce it byte-for-byte across randomized (seeded)
-- segment/chunk sequences. Above the cap, invariants pin the elision:
-- exact frozen head prefix, contiguous tail suffix, exact elided count,
-- bounded retention, images exempt, and O(1)-amortised streaming cost.
--
--   nvim --headless -u NONE -N -l test/retention_test.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
vim.g.cmdline_notebook_figures = 'inline'  -- explicit opt-in: keep the kitty gate deterministic off-terminal
vim.o.columns = 200
vim.o.lines = 60
local render = require('vimcmdline.notebook.render')
local img = require('vimcmdline.notebook.image')

img._set_tty_writer(function() return true end)

local fail = 0
local function check(label, got, want)
  if got == want or vim.deep_equal(got, want) then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. '\n  got=' .. vim.inspect(got) .. '\n want=' .. vim.inspect(want))
  end
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })

-- Extract the displayed text lines from the cell's extmark (border='none' =>
-- each virt line is the plain text of one display line).
local function displayed()
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      local s = {}
      for _, chunk in ipairs(line) do
        s[#s + 1] = chunk[1]
      end
      out[#out + 1] = table.concat(s)
    end
  end
  return out
end

-- ---- reference implementation (the pre-retention algorithm) ---------------
local function reference(ops, max_lines)
  -- merge consecutive same-kind ops into segments, concat their text
  local segs = {}
  for _, op in ipairs(ops) do
    local last = segs[#segs]
    if last and last.kind == op.kind then
      last.text = last.text .. op.text
    else
      segs[#segs + 1] = { kind = op.kind, text = op.text }
    end
  end
  -- full flatten with per-segment trailing-'' suppression
  local lines = {}
  for _, seg in ipairs(segs) do
    local parts = vim.split(seg.text, '\n', { plain = true })
    if #parts > 1 and parts[#parts] == '' then
      table.remove(parts)
    end
    for _, p in ipairs(parts) do
      lines[#lines + 1] = p
    end
  end
  -- cell-level trailing blank trim
  while #lines > 0 and lines[#lines] == '' do
    table.remove(lines)
  end
  -- display cap
  if max_lines and max_lines > 0 and #lines > max_lines then
    local kept = {}
    for i = 1, max_lines - 1 do
      kept[i] = lines[i]
    end
    local dropped = #lines - (max_lines - 1)
    kept[#kept + 1] = ('… %d more lines (:CmdLineNotebookOpenOutput)'):format(dropped)
    return kept, lines
  end
  return lines, lines
end

-- ---- (1) randomized equivalence below the cap -----------------------------
math.randomseed(20260702)
local KINDS = { 'stdout', 'stderr', 'result' }
local PIECES = { 'a', 'bb', 'line\n', '\n', '', 'x\ny\n', 'zz\n\n', 'q\nr', '\n\n', 'end' }

local eq_fail = 0
for it = 1, 200 do
  local ops = {}
  for _ = 1, math.random(1, 12) do
    ops[#ops + 1] = {
      kind = KINDS[math.random(#KINDS)],
      text = PIECES[math.random(#PIECES)] .. (math.random() < 0.3 and PIECES[math.random(#PIECES)] or ''),
    }
  end
  local max_lines = ({ 0, 3, 5, 20 })[math.random(4)]
  local for_cap = ({ 0, 10000 })[math.random(2)]  -- unlimited AND default cap

  render.clear_all(buf)
  render.begin(buf, it, 1, 1, max_lines, nil, false, nil, for_cap)
  for _, op in ipairs(ops) do
    render.add(buf, it, op.kind, op.text)
  end
  render.finish(buf, it)

  local want_display, want_full = reference(ops, max_lines)
  local got_display = displayed()
  if not vim.deep_equal(got_display, want_display) then
    eq_fail = eq_fail + 1
    print(('EQUIV MISMATCH it=%d max=%d cap=%d'):format(it, max_lines, for_cap))
    print('  ops=' .. vim.inspect(ops))
    print('  got=' .. vim.inspect(got_display))
    print(' want=' .. vim.inspect(want_display))
  end
  local got_full = render.get_range_text(buf, 1, 1) or {}
  if not vim.deep_equal(got_full, want_full) then
    eq_fail = eq_fail + 1
    print(('FULLTEXT MISMATCH it=%d'):format(it))
  end
  if eq_fail > 3 then break end
end
check('equivalence_200_randomized', eq_fail, 0)

-- ---- (2) elision invariants under adversarial chunkings -------------------
local CAP = 20
local SLACK = math.max(8, math.floor(CAP / 8))  -- must match trim_slack()

local function flood(id, total, chunker)
  render.clear_all(buf)
  render.begin(buf, id, 1, 1, 0, nil, false, nil, CAP)
  chunker(function(text) render.add(buf, id, 'stdout', text) end, total)
  render.finish(buf, id)
  return render.get_range_text(buf, 1, 1) or {}
end

local function check_invariants(tag, txt, total)
  local head_n = math.floor(CAP / 2)
  -- frozen head is the exact prefix
  local head_ok = true
  for i = 1, head_n do
    if txt[i] ~= ('L%d'):format(i) then head_ok = false end
  end
  check(tag .. '_head_prefix', head_ok, true)
  -- marker with exact complement count
  local marker = txt[head_n + 1] or ''
  local d = tonumber(marker:match('(%d+) lines elided'))
  check(tag .. '_marker_present', d ~= nil, true)
  local tail_n = #txt - head_n - 1
  check(tag .. '_count_complement', (d or -1) + head_n + tail_n, total)
  -- tail is a contiguous suffix ending at the last line
  local tail_ok = tail_n > 0
  for i = 1, tail_n do
    if txt[head_n + 1 + i] ~= ('L%d'):format(total - tail_n + i) then tail_ok = false end
  end
  check(tag .. '_tail_suffix', tail_ok, true)
  -- bounded retention
  check(tag .. '_bounded', head_n + tail_n <= CAP + SLACK, true)
end

-- one line per add
check_invariants('perline', flood(1001, 100, function(add, total)
  for i = 1, total do add(('L%d\n'):format(i)) end
end), 100)

-- one mega-chunk
check_invariants('megachunk', flood(1002, 100, function(add, total)
  local t = {}
  for i = 1, total do t[#t + 1] = ('L%d\n'):format(i) end
  add(table.concat(t))
end), 100)

-- 1-byte chunks (splice torture: every line built char by char)
check_invariants('bytewise', flood(1003, 80, function(add, total)
  for i = 1, total do
    local line = ('L%d\n'):format(i)
    for k = 1, #line do add(line:sub(k, k)) end
  end
end), 80)

-- chunks straddling line boundaries ("Lk\nL(k+1)" pairs)
check_invariants('straddle', flood(1004, 100, function(add, total)
  local pend = ''
  for i = 1, total do
    local line = ('L%d\n'):format(i)
    local cut = (i % 3) + 1
    add(pend .. line:sub(1, cut))
    pend = line:sub(cut + 1)
  end
  add(pend)
end), 100)

-- ---- (3) tiny cap + boundary conditions ------------------------------------
do
  render.clear_all(buf)
  render.begin(buf, 2001, 1, 1, 0, nil, false, nil, 4)  -- slack = 8
  for i = 1, 50 do render.add(buf, 2001, 'stdout', ('T%d\n'):format(i)) end
  render.finish(buf, 2001)
  local txt = render.get_range_text(buf, 1, 1)
  check('tiny_head', { txt[1], txt[2] }, { 'T1', 'T2' })
  check('tiny_marker', txt[3]:match('lines elided') ~= nil, true)
  check('tiny_last', txt[#txt], 'T50')

  -- trigger boundary: nraw counts the open raw tail entry, so N complete
  -- lines put nraw at N+1 — no elision through N = cap+slack-1, elision once
  -- appends push past the slack.
  render.clear_all(buf)
  render.begin(buf, 2002, 1, 1, 0, nil, false, nil, CAP)
  for i = 1, CAP + SLACK - 1 do render.add(buf, 2002, 'stdout', ('B%d\n'):format(i)) end
  render.finish(buf, 2002)
  local t2 = render.get_range_text(buf, 1, 1)
  check('boundary_no_elision', #t2, CAP + SLACK - 1)
  render.add(buf, 2002, 'stdout', 'B-more1\nB-more2\n')
  render.finish(buf, 2002)
  local t3 = render.get_range_text(buf, 1, 1)
  local has_marker = false
  for _, l in ipairs(t3) do
    if l:match('lines elided') then has_marker = true end
  end
  check('boundary_elides_past_slack', has_marker, true)
end

-- ---- (4) cap=0 keeps everything -------------------------------------------
do
  render.clear_all(buf)
  render.begin(buf, 3001, 1, 1, 0, nil, false, nil, 0)
  for i = 1, 500 do render.add(buf, 3001, 'stdout', ('U%d\n'):format(i)) end
  render.finish(buf, 3001)
  local txt = render.get_range_text(buf, 1, 1)
  check('cap0_all_kept', #txt, 500)
  check('cap0_first_last', { txt[1], txt[500] }, { 'U1', 'U500' })
end

-- ---- (5) images exempt across the elided zone ------------------------------
do
  local png = vim.base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')
  render.clear_all(buf)
  render.begin(buf, 4001, 1, 1, 0, nil, false, nil, CAP)
  render.add(buf, 4001, 'stdout', 'pre\n')
  local a = img.place(png, 400, 300, 6, 2.0)
  render.add_image(buf, 4001, a)
  for i = 1, 60 do render.add(buf, 4001, 'stdout', ('M%d\n'):format(i)) end
  local b = img.place(png, 400, 300, 6, 2.0)
  render.add_image(buf, 4001, b)                    -- lands mid-flood
  for i = 61, 120 do render.add(buf, 4001, 'stdout', ('M%d\n'):format(i)) end
  render.finish(buf, 4001)

  local txt = render.get_range_text(buf, 1, 1)
  local figs = 0
  for _, l in ipairs(txt) do
    if l == '[inline figure]' then figs = figs + 1 end
  end
  check('images_survive_elision', figs, 2)
  check('images_last_line_kept', txt[#txt], 'M120')
  -- resize still finds both figures (incl. the one relocated to the head)
  check('elided_figures_resizable', render.resize_images(buf, 12, 2.0, 0), 2)
end

-- ---- (6) retention marker + display-cap notice coexist ---------------------
do
  render.clear_all(buf)
  render.begin(buf, 5001, 1, 1, 10, nil, false, nil, 30)
  for i = 1, 100 do render.add(buf, 5001, 'stdout', ('C%d\n'):format(i)) end
  render.finish(buf, 5001)
  local disp = displayed()
  check('notice_present', disp[#disp]:match('more lines') ~= nil, true)
  check('display_capped', #disp, 10)
  local full = render.get_range_text(buf, 1, 1)
  local has_marker = false
  for _, l in ipairs(full) do
    if l:match('lines elided') then has_marker = true end
  end
  check('marker_in_full_text', has_marker, true)
  -- notice count consistent: displayed 9 of the retained (trimmed) total
  local retained = #full
  local n = tonumber(disp[#disp]:match('… (%d+) more'))
  check('notice_count_exact', n, retained - 9)
end

-- ---- (6b) popup surfaces the elision visibly --------------------------------
do
  local nb = require('vimcmdline.notebook')
  vim.g.cmdline_notebook_enable = 1
  vim.cmd('set rtp^=.')
  pcall(vim.cmd, 'source plugin/vimcmdline.vim')
  render.clear_all(buf)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'loop()' })
  render.begin(buf, 5501, 2, 2, 20, 'rounded', true, nil, 40)
  for i = 1, 200 do render.add(buf, 5501, 'stdout', ('P%d\n'):format(i)) end
  render.finish(buf, 5501)
  vim.fn.cursor(2, 1)
  nb.open_output(buf, 2, 2)
  local owin = vim.api.nvim_get_current_win()
  local ob = vim.api.nvim_win_get_buf(owin)
  local plines = vim.api.nvim_buf_get_lines(ob, 0, -1, false)
  check('popup_footer_elided', plines[#plines]:match('lines elided from the middle') ~= nil, true)
  local mid = 0
  for _, l in ipairs(plines) do
    if l:match('^··· %d+ lines elided ···$') then mid = mid + 1 end
  end
  check('popup_middle_marker', mid, 1)
  local wcfg = vim.api.nvim_win_get_config(owin)
  local title = ''
  for _, part in ipairs(wcfg.title or {}) do title = title .. part[1] end
  check('popup_title_elided', title:match('lines elided') ~= nil, true)
  vim.cmd('bwipeout!')
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
end

-- ---- (7) complexity: streaming cost stays flat ------------------------------
do
  render.clear_all(buf)
  render.begin(buf, 6001, 1, 1, 20, nil, false, nil, 10000)
  local function half(from, to)
    local t0 = vim.loop.hrtime()
    for i = from, to do
      render.add(buf, 6001, 'stdout', ('F%d line of streaming output\n'):format(i))
      if i % 100 == 0 then render.finish(buf, 6001) end
    end
    render.finish(buf, 6001)
    return (vim.loop.hrtime() - t0) / 1e6
  end
  local first = half(1, 30000)
  local second = half(30001, 60000)
  print(('  flood halves: %.0fms then %.0fms'):format(first, second))
  check('flat_streaming_cost', second < first * 3 + 50, true)

  -- cap=0: the windowed redraw alone must keep redraw cost flat too
  render.clear_all(buf)
  render.begin(buf, 6002, 1, 1, 20, nil, false, nil, 0)
  local function half0(from, to)
    local t0 = vim.loop.hrtime()
    for i = from, to do
      render.add(buf, 6002, 'stdout', ('G%d\n'):format(i))
      if i % 100 == 0 then render.finish(buf, 6002) end
    end
    render.finish(buf, 6002)
    return (vim.loop.hrtime() - t0) / 1e6
  end
  local f0 = half0(1, 30000)
  local s0 = half0(30001, 60000)
  print(('  cap=0 halves: %.0fms then %.0fms'):format(f0, s0))
  check('flat_redraw_cap0', s0 < f0 * 3 + 50, true)
end

-- ---- (8) memory bounded by the cap ------------------------------------------
do
  collectgarbage('collect'); collectgarbage('collect')
  local h0 = collectgarbage('count')
  render.clear_all(buf)
  render.begin(buf, 7001, 1, 1, 20, nil, false, nil, 10000)
  for i = 1, 200000 do
    render.add(buf, 7001, 'stdout', ('mem line %d with some payload text\n'):format(i))
  end
  render.finish(buf, 7001)
  collectgarbage('collect'); collectgarbage('collect')
  local grow = collectgarbage('count') - h0
  print(('  heap growth after 200k-line flood: %.0f KB'):format(grow))
  check('memory_bounded', grow < 8192, true)  -- unbounded retention would be ~15MB+
  render.clear_all(buf)
  collectgarbage('collect'); collectgarbage('collect')
  check('memory_released', collectgarbage('count') - h0 < 4096, true)
end

img._set_tty_writer(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('RETENTION OK')
  vim.cmd('qall!')
end
