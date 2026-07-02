-- Leak / dangling-resource checks for inline figures and the kernel bridge.
--
--   placements   every kitty placement transmitted during cell re-run /
--                clear / popup cycles is explicitly freed (delete APC).
--   lua heap     repeated figure + text cycles do not grow the Lua heap
--                beyond cache caps (a retained-PNG leak would show: the
--                synthetic PNG is ~200KB and 60 cycles would leak ~12MB).
--   render state cells table does not accumulate across re-runs.
--   processes    the bridge process (and its kernel child) exit after a
--                graceful shutdown (skipped when jupyter deps are missing).
--
--   BENCH_PYTHON=... nvim --headless -u NONE -N -l test/leak_check.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
vim.o.columns = 120
vim.o.lines = 60
vim.g.cmdline_notebook_enable = 1
vim.cmd('source plugin/vimcmdline.vim')

local img = require('vimcmdline.notebook.image')
local render = require('vimcmdline.notebook.render')
local nb = require('vimcmdline.notebook')
local bridge = require('vimcmdline.notebook.bridge')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

-- Track transmitted vs freed placement ids through the stubbed writer.
local transmitted, freed = {}, {}
img._set_tty_writer(function(bytes)
  local tid = bytes:match('a=T,U=1,q=2,f=100,t=d,i=(%d+)')
  if tid then
    transmitted[tid] = true
  else
    for did in bytes:gmatch('a=d,d=I,i=(%d+)') do
      freed[did] = true
    end
  end
  return true
end)

-- Realistic-size PNG stand-in (~200KB; place() treats bytes opaquely).
local png = string.rep('PNGDATA\1\2\3\4\5\6\7\8', 16000)

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'plot()' })

collectgarbage('collect'); collectgarbage('collect')
local heap0 = collectgarbage('count')

-- 60 cell re-runs, each with a figure + streaming text (begin overlap frees
-- the previous run's placement), plus a popup open/close every 10th cycle.
local CYCLES = 60
for i = 1, CYCLES do
  render.begin(buf, i, 2, 2, 20, 'rounded', true, nil)
  render.add(buf, i, 'stdout', ('run %d line one\nrun %d line two\n'):format(i, i))
  local placed = img.place(png, 800, 600, 30, 2.0)
  assert(placed, 'place failed')
  render.add_image(buf, i, placed)
  render.add(buf, i, 'stdout', 'after figure\n')
  render.mark_done(buf, i, i, 'ok')
  if i % 10 == 0 then
    nb.open_output(buf, 2, 2)
    vim.cmd('bwipeout!')
  end
end
render.clear_all(buf)

collectgarbage('collect'); collectgarbage('collect')
local heap1 = collectgarbage('count')
local growth_kb = heap1 - heap0

-- Placement balance: every transmitted id was explicitly freed.
local n_tx, n_unfreed = 0, 0
for id in pairs(transmitted) do
  n_tx = n_tx + 1
  if not freed[id] then
    n_unfreed = n_unfreed + 1
  end
end
check('placements_transmitted', n_tx, CYCLES + CYCLES / 10)
check('placements_all_freed', n_unfreed, 0)

-- Render state does not accumulate.
check('render_state_empty', render.get_range_text(buf, 2, 2), nil)
check('no_figures_left_to_resize', render.resize_all_images(40, 2.0, 0), 0)

-- Heap growth stays within cache caps (a retained-PNG leak would be ~12MB).
print(('  lua heap growth: %.0f KB over %d cycles'):format(growth_kb, CYCLES))
check('heap_growth_bounded', growth_kb < 4096, true)

img._set_tty_writer(nil)

-- Process hygiene: bridge + kernel exit after a graceful shutdown.
local PY = vim.env.BENCH_PYTHON or 'python3'
vim.fn.system({ PY, '-c', 'import jupyter_client, ipykernel' })
if vim.v.shell_error ~= 0 then
  print('SKIP process check: jupyter deps not importable by ' .. PY)
else
  local ready = false
  local h = bridge.spawn(PY, function(ev)
    if ev.type == 'kernel_ready' then ready = true end
  end, function() end)
  assert(h, 'bridge spawn failed')
  local bpid = vim.fn.jobpid(h.job)
  h.send({ type = 'hello', startup_code = {}, kernel_name = 'python3', timeout = 60 })
  check('bridge_kernel_ready', vim.wait(90000, function() return ready end, 50), true)
  local kids = vim.fn.systemlist({ 'pgrep', '-P', tostring(bpid) })
  check('kernel_child_running', #kids >= 1, true)
  h.send({ type = 'shutdown' })
  local gone = vim.wait(15000, function()
    return vim.fn.systemlist({ 'ps', '-p', tostring(bpid), '-o', 'pid=' })[1] == nil
  end, 100)
  check('bridge_exits_on_shutdown', gone, true)
  local kids_left = 0
  for _, kpid in ipairs(kids) do
    if vim.fn.systemlist({ 'ps', '-p', kpid, '-o', 'pid=' })[1] ~= nil then
      kids_left = kids_left + 1
    end
  end
  check('kernel_child_exits', kids_left, 0)
end

if fail > 0 then
  vim.cmd('cquit!')
else
  print('LEAK-CHECK OK')
  vim.cmd('qall!')
end
