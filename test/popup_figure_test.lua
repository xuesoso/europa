-- Output-popup figure tests: :CmdLineNotebookOpenOutput shows a LARGER
-- placement of the cell's figure (fresh image id, same retained PNG), frees
-- it when the popup closes, and leaves the inline placement untouched.
--
--   nvim --headless -u NONE -N -l test/popup_figure_test.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
vim.o.columns = 120
vim.o.lines = 60
vim.g.cmdline_notebook_enable = 1
vim.g.cmdline_notebook_figure_size = 20
vim.cmd('source plugin/vimcmdline.vim')

local img = require('vimcmdline.notebook.image')
local render = require('vimcmdline.notebook.render')
local nb = require('vimcmdline.notebook')
local config = require('vimcmdline.notebook.config')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

-- Inline is the RESOLVED default figure mode when nothing figure-related is
-- set (the plugin no longer materializes it into a global; config.lua supplies
-- the default). Check the resolved value BEFORE opting in below.
check('default_figures_inline', config.read().figures, 'inline')

-- Explicit opt-in forces inline past terminal detection so the figure
-- transmits on the headless CI runner (a non-kitty terminal).
vim.g.cmdline_notebook_figures = 'inline'

local writes = {}
img._set_tty_writer(function(bytes)
  writes[#writes + 1] = bytes
  return true
end)

local png = vim.base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
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

local inline_id = shown.id
local inline_cols = shown.cols

-- Open the popup: expect ONE new transmission under a fresh id at a larger
-- geometry (fig target = 85% of 120 cols = 102).
writes = {}
vim.fn.cursor(2, 1)
nb.open_output(buf, 2, 2)
local obuf = vim.api.nvim_get_current_buf()
check('popup_opened_new_buf', obuf ~= buf, true)
check('popup_one_transmission', #writes, 1)
local popup_id = writes[1]:match('a=T,U=1,q=2,f=100,t=d,i=(%d+)')
check('popup_fresh_id', popup_id ~= nil and tonumber(popup_id) ~= inline_id, true)
local pcols = tonumber(writes[1]:match(',c=(%d+),'))
check('popup_larger_cols', pcols ~= nil and pcols > inline_cols, true)
check('popup_cols_target', pcols, 102)

-- Buffer content: text intact, placeholder rows present with the id hl.
local lines = vim.api.nvim_buf_get_lines(obuf, 0, -1, false)
check('popup_first_text', lines[1], 'text before')
check('popup_last_text', lines[#lines], 'text after')
local expected_rows = #lines - 2
check('popup_has_fig_rows', expected_rows > 0, true)
local marks = vim.api.nvim_buf_get_extmarks(obuf, render.ns, 0, -1, { details = true })
local hl_rows = 0
for _, m in ipairs(marks) do
  if tostring(m[4].hl_group or ''):find('CmdlineNotebookImg_') then
    hl_rows = hl_rows + 1
  end
end
check('popup_hl_rows', hl_rows, expected_rows)
check('popup_readonly', vim.bo[obuf].modifiable, false)

-- Closing the popup frees the popup placement — and ONLY that one.
writes = {}
vim.cmd('bwipeout!')
local freed = table.concat(writes)
check('popup_freed_on_close', freed:find('a=d,d=I,i=' .. popup_id, 1, true) ~= nil, true)
check('inline_not_freed', freed:find('a=d,d=I,i=' .. inline_id, 1, true), nil)

-- Inline placement untouched by the popup round-trip.
check('inline_cols_unchanged', shown.cols, inline_cols)

-- Tall figure must fit WHOLLY inside the popup viewport: with a short editor,
-- the height budget binds and fit() scales the width down to keep the aspect.
do
  vim.o.lines = 30   -- popup_max_h = 30*0.9-2 = 25
  render.begin(buf, 10, 2, 2, 50, 'rounded', true, nil)
  local pf2 = vim.fn.tempname()
  local f2 = io.open(pf2, 'wb'); f2:write(png); f2:close()
  local tall = img.show(pf2, 400, 300, 20, 2.0)
  render.add_image(buf, 10, tall)
  render.mark_done(buf, 10, 10, 'ok')

  writes = {}
  nb.open_output(buf, 2, 2)
  local owin = vim.api.nvim_get_current_win()
  local obuf3 = vim.api.nvim_win_get_buf(owin)
  local win_h = vim.api.nvim_win_get_height(owin)
  local prows = tonumber(writes[1]:match(',r=(%d+)'))
  check('tall_fig_rows_capped', prows ~= nil and prows <= 25, true)
  check('tall_fig_fits_viewport', prows ~= nil and prows <= win_h, true)
  -- aspect preserved under the height cap: cols scaled down, not full width
  local pcols2 = tonumber(writes[1]:match(',c=(%d+),'))
  check('tall_fig_aspect_scaled', pcols2 ~= nil and pcols2 < math.floor(120 * 0.85), true)
  check('tall_fig_rows_in_buffer', #vim.api.nvim_buf_get_lines(obuf3, 0, -1, false), prows)
  vim.cmd('bwipeout!')
  vim.o.lines = 60
end

-- Regression: a text-only cell opens with no transmissions and plain text.
render.begin(buf, 2, 2, 2, 50, 'rounded', true, nil)
render.add(buf, 2, 'stdout', 'only text\n')
render.mark_done(buf, 2, 2, 'ok')
writes = {}
nb.open_output(buf, 2, 2)
local obuf2 = vim.api.nvim_get_current_buf()
check('textonly_no_transmission', #writes, 0)
check('textonly_content', vim.api.nvim_buf_get_lines(obuf2, 0, -1, false)[1], 'only text')
vim.cmd('bwipeout!')

img._set_tty_writer(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('POPUP-FIGURE OK')
  vim.cmd('qall!')
end
