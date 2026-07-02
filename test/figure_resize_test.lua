-- Live figure-resize tests: changing g:cmdline_notebook_figure_size (or the
-- :CmdLineNotebookFigureSize command) re-transmits displayed figures at the
-- new size under the SAME image id and redraws the cell, while text output is
-- byte-for-byte unchanged.
--
--   nvim --headless -u NONE -N -l test/figure_resize_test.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
vim.o.columns = 200
vim.o.lines = 60
vim.g.cmdline_notebook_enable = 1
vim.g.cmdline_notebook_figure_size = 20
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

-- A tiny valid PNG; declared 400x300 to fit().
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

local orig_id = shown.id
local orig_rows = #shown.rows
check('initial_cols', shown.cols, 20)

-- Collect the rendered lines, split into text vs figure rows.
local function snapshot()
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
  local text, imgrows = {}, 0
  for _, m in ipairs(marks) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      local is_img = false
      local joined = {}
      for _, chunk in ipairs(line) do
        if tostring(chunk[2] or ''):find('CmdlineNotebookImg_') then
          is_img = true
        end
        joined[#joined + 1] = chunk[1]
      end
      if is_img then
        imgrows = imgrows + 1
      else
        text[#text + 1] = table.concat(joined)
      end
    end
  end
  return text, imgrows
end

local text_before, imgrows_before = snapshot()
check('figure_rendered', imgrows_before, orig_rows)

-- 1) Resize via the g: variable watcher (direct `let`).
writes = {}
vim.g.cmdline_notebook_figure_size = 40
vim.wait(200, function() return false end, 20)  -- let the watcher fire
local text_after, imgrows_after = snapshot()

check('watcher_retransmitted', #writes >= 1, true)
check('watcher_same_id',
  writes[1] and writes[1]:find('i=' .. orig_id, 1, true) ~= nil, true)
check('watcher_new_cols', shown.cols, 40)
check('watcher_rows_grew', imgrows_after > imgrows_before, true)

-- The requirement: text output is untouched by figure resizes. Extract the
-- text payload of every content row (between the box verticals, trailing pad
-- stripped) and require byte-identical content in the same order; the border
-- rows may only change in width.
local function payload(t)
  local out, borders = {}, 0
  for _, l in ipairs(t) do
    local m = l:match('^│ (.-)%s*│$')
    if m then
      out[#out + 1] = m
    else
      borders = borders + 1
    end
  end
  return out, borders
end
local pay_b, borders_b = payload(text_before)
local pay_a, borders_a = payload(text_after)
check('text_unchanged', vim.deep_equal(pay_b, pay_a), true)
check('border_rows_unchanged', borders_b, borders_a)

-- 2) Resize via the command, with an explicit height.
writes = {}
vim.cmd('CmdLineNotebookFigureSize 30 9')
vim.wait(100, function() return false end, 20)
check('cmd_cols', shown.cols, 30)
check('cmd_rows', #shown.rows, 9)
check('cmd_gvar_size', vim.g.cmdline_notebook_figure_size, 30)
check('cmd_gvar_rows', vim.g.cmdline_notebook_figure_rows, 9)
check('cmd_single_retransmit', #writes, 1)

-- 3) No-op resize (same geometry) transmits nothing and redraws nothing new.
writes = {}
vim.cmd('CmdLineNotebookFigureSize 30 9')
vim.wait(100, function() return false end, 20)
check('noop_no_retransmit', #writes, 0)

-- 3b) FigureRefresh re-transmits at the CURRENT geometry (restores terminal-
-- evicted placements): same id, same size, and repeatable — unlike the
-- same-size FigureSize call above, which is deliberately a no-op.
writes = {}
vim.cmd('CmdLineNotebookFigureRefresh')
check('refresh_retransmits', #writes, 1)
check('refresh_same_id',
  writes[1] ~= nil and writes[1]:find('i=' .. orig_id, 1, true) ~= nil, true)
check('refresh_same_geometry',
  writes[1] ~= nil and writes[1]:find(',c=30,r=9', 1, true) ~= nil, true)
writes = {}
vim.cmd('CmdLineNotebookFigureRefresh')
check('refresh_repeatable', #writes, 1)

-- 3c) Refresh order is quota-aware: with a second figure in a far-away cell,
-- the figure NEAREST the cursor is transmitted LAST (terminals evict oldest
-- first, so the nearest survives when over quota).
vim.api.nvim_set_current_buf(buf)  -- priority ordering keys off the current buffer
vim.api.nvim_buf_set_lines(buf, 0, -1, false,
  { '# %%', 'plot()', '# %%', 'far()', '', '', '', '', '', '# %%', 'near()' })
render.begin(buf, 50, 4, 4, 50, 'rounded', true, nil)
local pf3 = vim.fn.tempname()
local f3 = io.open(pf3, 'wb'); f3:write(png); f3:close()
local far_fig = img.show(pf3, 400, 300, 10, 2.0)
render.add_image(buf, 50, far_fig)
vim.fn.cursor(2, 1)  -- cursor at the first cell => its figure is "near"
writes = {}
vim.cmd('CmdLineNotebookFigureRefresh')
check('refresh_order_count', #writes, 2)
check('refresh_far_first',
  writes[1] ~= nil and writes[1]:find('i=' .. far_fig.id, 1, true) ~= nil, true)
check('refresh_near_last',
  writes[2] ~= nil and writes[2]:find('i=' .. orig_id, 1, true) ~= nil, true)
render.clear_range(buf, 4, 4)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'plot()' })

-- 4) OpenOutput text is still the figure note + text (no placeholders).
local txt = render.get_range_text(buf, 2, 2)
check('open_output_intact', vim.deep_equal(txt,
  { 'text before', '[inline figure]', 'text after' }), true)

img._set_tty_writer(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('FIGURE-RESIZE OK')
  vim.cmd('qall!')
end
