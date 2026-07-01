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
