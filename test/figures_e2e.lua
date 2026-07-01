-- End-to-end inline-figure test: real kernel + matplotlib_inline -> bridge
-- saves the PNG -> image.lua transmits (stubbed tty) -> placeholder grid
-- appears inside the cell's bordered virt_lines. Skips without
-- jupyter_client/ipykernel/matplotlib in $BENCH_PYTHON (or python3).
--
--   BENCH_PYTHON=/path/to/python nvim --headless -u NONE -N -l test/figures_e2e.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true

local PY = vim.env.BENCH_PYTHON or 'python3'
vim.fn.system({ PY, '-c', 'import jupyter_client, ipykernel, matplotlib, matplotlib_inline' })
if vim.v.shell_error ~= 0 then
  print('SKIP: kernel/matplotlib deps not importable by ' .. PY)
  vim.cmd('qall!')
end

local tmpdir = vim.fn.tempname()
vim.fn.mkdir(tmpdir, 'p')

vim.g.cmdline_notebook_enable = 1
vim.g.cmdline_notebook_python = PY
vim.g.cmdline_notebook_figures = 'inline'
vim.g.cmdline_notebook_figure_size = 12
vim.g.cmdline_notebook_figure_dpi = 50
vim.g.cmdline_tmp_dir = tmpdir
vim.cmd('source plugin/vimcmdline.vim')

local img = require('vimcmdline.notebook.image')
local writes = {}
img._set_tty_writer(function(bytes)
  writes[#writes + 1] = bytes
  return true
end)

vim.cmd('enew')
vim.bo.buftype = 'nofile'
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'x' })
vim.b.cmdline_filetype = 'python'
vim.b.cmdline_app = 'python3'
vim.b.cmdline_send_empty = 1
vim.b.cmdline_notebook = 1

local nb = require('vimcmdline.notebook')
local render = require('vimcmdline.notebook.render')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

nb.start(buf)
assert(vim.wait(90000, function() return nb.status(buf) == 'ready' end, 20), 'kernel not ready')

nb.execute_cell(buf, 2, {
  'import matplotlib.pyplot as plt',
  'plt.plot([1, 4, 9, 16])',
  'plt.title("inline")',
  'plt.show()',
  'print("after plot")',
})
assert(vim.wait(60000, function() return nb.pending(buf) == 0 end, 10), 'cell never finished')
vim.wait(400, function() return false end, 50)

-- The terminal got a kitty transmission (delete APC + a=T,U=1 chunks).
local tx = table.concat(writes)
check('kitty_transmission_sent', tx:find('a=T,U=1,q=2,f=100,t=d', 1, true) ~= nil, true)

-- The cell's virt_lines contain placeholder rows plus surrounding text/border.
local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
check('mark_exists', #marks >= 1, true)
local img_rows, text_after, bordered = 0, false, false
for _, m in ipairs(marks) do
  for _, line in ipairs(m[4].virt_lines or {}) do
    for _, chunk in ipairs(line) do
      if chunk[2] and tostring(chunk[2]):find('CmdlineNotebookImg_') then
        img_rows = img_rows + 1
        break
      end
    end
    for _, chunk in ipairs(line) do
      if chunk[1]:find('after plot', 1, true) then text_after = true end
      if chunk[1]:find('╭', 1, true) then bordered = true end
    end
  end
end
check('placeholder_rows_rendered', img_rows > 0, true)
check('text_after_figure', text_after, true)
check('border_present', bordered, true)

-- The bridge's temp PNG was consumed (deleted after transmission).
check('tmp_pngs_cleaned', #vim.fn.glob(tmpdir .. '/vcl_fig_*', 0, 1), 0)

nb.stop(buf)
vim.wait(400)
img._set_tty_writer(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('FIGURES-E2E OK')
  vim.cmd('qall!')
end
