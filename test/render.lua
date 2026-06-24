-- Unit test for the notebook render layer: re-running a cell must REPLACE its
-- captured output (the bug where OpenOutput showed a stale earlier run).
--   nvim --headless -u NONE -N -l test/render.lua
vim.opt.rtp:prepend('.')
local render = require('vimcmdline.notebook.render')

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'a', 'b', 'c' })

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end
local function out(s, e)
  local t = render.get_range_text(buf, s, e)
  return t and table.concat(t, '\n') or nil
end

-- Run 1: cell at lines [2,2] prints the "pyplot" help.
render.begin(buf, 1, 2, 2, 20, 'none')
render.add(buf, 1, 'stdout', 'help pyplot\n')
check('run1', out(2, 2), 'help pyplot')

-- Run 2: same cell grown to [2,3], a new run prints both.
render.begin(buf, 2, 2, 3, 20, 'none')
render.add(buf, 2, 'stdout', 'help pyplot\nhelp numpy\n')
check('run2_grown', out(2, 3), 'help pyplot\nhelp numpy')

-- Run 3: cell shrunk back to [2,2], a new run prints only numpy. Must NOT show
-- the stale earlier run(s).
render.begin(buf, 3, 2, 2, 20, 'none')
render.add(buf, 3, 'stdout', 'help numpy\n')
check('run3_replaces_stale', out(2, 2), 'help numpy')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('RENDER OK')
  vim.cmd('qall!')
end
