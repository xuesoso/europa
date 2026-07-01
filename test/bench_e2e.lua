-- End-to-end latency/throughput benchmark inside Neovim: real bridge + kernel
-- + render, measuring what the user sees.
--
--   first-paint   execute_cell() -> the cell's output extmark first appears
--                 (includes bridge dispatch, kernel, event pickup, and the
--                 render debounce -- the full keypress-to-pixels path).
--   run-all       N trivial cells submitted back-to-back -> all marked done.
--
-- Needs jupyter_client/ipykernel in $BENCH_PYTHON (or python3); exits 0 with
-- SKIP when missing.
--
--   BENCH_PYTHON=/path/to/python nvim --headless -u NONE -N -l test/bench_e2e.lua
vim.opt.rtp:prepend('.')

local PY = vim.env.BENCH_PYTHON or 'python3'
vim.fn.system({ PY, '-c', 'import jupyter_client, ipykernel' })
if vim.v.shell_error ~= 0 then
  print('SKIP: jupyter_client/ipykernel not importable by ' .. PY)
  vim.cmd('qall!')
end

vim.g.cmdline_notebook_enable = 1
vim.g.cmdline_notebook_python = PY
vim.g.cmdline_notebook_plotty = 0
vim.cmd('source plugin/vimcmdline.vim')

vim.cmd('enew')
vim.bo.buftype = 'nofile'
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'print("x")' })
vim.b.cmdline_filetype = 'python'
vim.b.cmdline_app = 'python3'
vim.b.cmdline_send_empty = 1
vim.b.cmdline_notebook = 1

local nb = require('vimcmdline.notebook')
local render = require('vimcmdline.notebook.render')
local ns = render.ns

nb.start(buf)
assert(vim.wait(90000, function() return nb.status(buf) == 'ready' end, 20),
  'kernel never became ready')

local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

local function ms(dt) return dt / 1e6 end
local fail = 0

-- Warm one execution through the whole stack (first-run syntax load etc.).
nb.execute_cell(buf, 2, { 'print("warm")' })
vim.wait(30000, function() return nb.pending(buf) == 0 end, 5)
vim.wait(200, function() return false end, 50)

-- first-paint: median over reps. Clear marks, execute, poll (1ms) until the
-- extmark exists.
local REPS = 15
local lat = {}
for _ = 1, REPS do
  render.clear_all(buf)
  local t0 = vim.loop.hrtime()
  nb.execute_cell(buf, 2, { 'print("x")' })
  local ok = vim.wait(10000, function() return #marks() > 0 end, 1)
  local dt = ms(vim.loop.hrtime() - t0)
  if not ok then fail = fail + 1; print('FAIL first-paint timeout') end
  lat[#lat + 1] = dt
  vim.wait(10000, function() return nb.pending(buf) == 0 end, 5)
end
table.sort(lat)
local med = lat[math.ceil(#lat / 2)]
local p90 = lat[math.max(math.ceil(#lat * 0.9), 1)]

-- slow-cell first-paint: the cell prints immediately but keeps running, so the
-- reply cannot force the paint -- this isolates the render debounce on top of
-- dispatch latency (a fast cell's reply-driven redraw masks it).
local slat = {}
for _ = 1, 8 do
  render.clear_all(buf)
  local t0 = vim.loop.hrtime()
  nb.execute_cell(buf, 2, { 'print("early", flush=True); import time; time.sleep(0.25)' })
  local ok = vim.wait(10000, function() return #marks() > 0 end, 1)
  local dt = ms(vim.loop.hrtime() - t0)
  if not ok then fail = fail + 1; print('FAIL slow first-paint timeout') end
  slat[#slat + 1] = dt
  vim.wait(10000, function() return nb.pending(buf) == 0 end, 5)
end
table.sort(slat)
local smed = slat[math.ceil(#slat / 2)]

-- run-all: N trivial cells back-to-back, until all replies drained.
local N = 50
render.clear_all(buf)
local t0 = vim.loop.hrtime()
for _ = 1, N do
  nb.execute_cell(buf, 2, { 'y = 1' })
end
local ok = vim.wait(120000, function() return nb.pending(buf) == 0 end, 2)
local t_runall = ms(vim.loop.hrtime() - t0)
if not ok then fail = fail + 1; print('FAIL run-all timeout') end

-- Correctness: the last run-all cell must show a success marker.
vim.wait(300, function() return false end, 50)
local mk = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
local seen_ok = false
for _, m in ipairs(mk) do
  local vl = m[4] and m[4].virt_lines
  if vl then
    for _, line in ipairs(vl) do
      for _, chunk in ipairs(line) do
        if chunk[1]:find('✓') then seen_ok = true end
      end
    end
  end
end
if not seen_ok then fail = fail + 1; print('FAIL no success marker after run-all') end

print('----------------------------------------------------------')
print(string.format('first-paint  exec -> extmark   median %7.1f ms   p90 %7.1f ms', med, p90))
print(string.format('slow-paint   exec -> extmark   median %7.1f ms  (cell still running)', smed))
print(string.format('run-all      %d cells e2e:            %8.1f ms', N, t_runall))
print('----------------------------------------------------------')

nb.stop(buf)
vim.wait(400)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('BENCH-E2E OK')
  vim.cmd('qall!')
end
