-- :CmdLineNotebookFigureRefresh (retransmit_figures) re-sends every retained
-- figure AND defers the repaint to a later event-loop tick.
--
-- The deferral is load-bearing, and this is the bug the test guards: image APCs
-- are written to v:stderr (queued by libuv) while :redraw! flushes nvim's frame
-- on stdout. A synchronous redraw! re-emits the placeholder cells BEFORE the
-- queued transmission reaches the terminal, so the terminal re-composes nothing
-- and the refreshed figure stays blank. retransmit_figures must therefore
-- schedule the repaint (never redraw inline) so the transmission flushes first.
-- No kernel required — the figure is built directly from a PNG.
--
--   nvim --headless -u NONE -N -l test/figure_refresh_test.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
vim.o.columns = 200
vim.o.lines = 60
vim.g.cmdline_notebook_enable = 1
vim.cmd('source plugin/vimcmdline.vim')

local img = require('vimcmdline.notebook.image')
local render = require('vimcmdline.notebook.render')
local nb = require('vimcmdline.notebook')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

local writes = {}
img._set_tty_writer(function(bytes)
  writes[#writes + 1] = bytes
  return true
end)

-- Spy on vim.schedule so we can prove the repaint is deferred, not inline.
local scheduled = 0
local real_schedule = vim.schedule
vim.schedule = function(cb)
  scheduled = scheduled + 1
  return real_schedule(cb)
end

-- A tiny valid PNG declared 400x300 to fit().
local png = vim.base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'plot()' })
render.begin(buf, 1, 2, 2, 50, 'rounded', true, nil)
render.add(buf, 1, 'stdout', 'text before\n')
local pngfile = vim.fn.tempname()
local f = io.open(pngfile, 'wb'); f:write(png); f:close()
local shown = img.show(pngfile, 400, 300, 20, 2.0)
assert(shown, 'show failed')
render.add_image(buf, 1, shown)
render.add(buf, 1, 'stdout', 'text after\n')
render.mark_done(buf, 1, 1, 'ok')
vim.api.nvim_set_current_buf(buf)

-- 1) Refresh re-transmits the figure and defers exactly one repaint.
writes = {}
scheduled = 0
local n = nb.retransmit_figures()
check('refresh_count', n, 1)
check('refresh_retransmitted', #writes, 1)
check('refresh_same_id',
  writes[1] ~= nil and writes[1]:find('i=' .. shown.id, 1, true) ~= nil, true)
-- The load-bearing assertion: the repaint was SCHEDULED (deferred a tick), not
-- run inline. A regression to a synchronous redraw! drops this to 0.
check('refresh_deferred_repaint', scheduled, 1)

-- 2) Deferred callback is UI-guarded: running the scheduled work headless (no
-- UI) must not error / crash.
local ok = pcall(vim.wait, 50, function() return false end, 10)
check('scheduled_repaint_safe_headless', ok, true)

-- 3) With no figures retained, nothing is transmitted and nothing is scheduled.
render.clear_all(buf)
writes = {}
scheduled = 0
local n2 = nb.retransmit_figures()
check('norefresh_count', n2, 0)
check('norefresh_no_transmit', #writes, 0)
check('norefresh_no_schedule', scheduled, 0)

vim.schedule = real_schedule
img._set_tty_writer(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('FIGURE-REFRESH OK')
  vim.cmd('qall!')
end
