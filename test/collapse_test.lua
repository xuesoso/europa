-- :CmdLineNotebookCollapse — presentation view. Collapsing must fold every
-- non-markdown cell's code down to one fold line, leave '# %% [markdown]'
-- cells fully expanded, and keep each cell's LAST line visible: the inline
-- output box is virt_lines anchored there, and a closed fold hides virt_lines
-- anchored anywhere inside it, so outputs stay visible only if the anchor
-- stays out of the fold. Toggling again must restore the user's fold setup.
--   nvim --headless -u NONE -N -l test/collapse_test.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
vim.g.cmdline_notebook_enable = 1
vim.cmd('source plugin/vimcmdline.vim')

local render = require('vimcmdline.notebook.render')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print(('FAIL %s got=%s want=%s'):format(label, tostring(got), tostring(want)))
  end
end

-- A notebook-shaped buffer: leading imports, a titled code cell, a markdown
-- cell, and a final code cell.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'import numpy as np',          -- 1  leading block (code)
  'import pandas as pd',         -- 2
  '',                            -- 3  <- leading block anchor line
  '# %% load data',              -- 4  code cell w/ title
  'a = 1',                       -- 5
  'b = 2',                       -- 6
  'a + b',                       -- 7  <- anchor line
  '# %% [markdown]',             -- 8  markdown cell: stays expanded
  '# ## Results',                -- 9
  '# The sum is shown below.',   -- 10
  '# %%',                        -- 11 code cell
  'print(a + b)',                -- 12 <- anchor line
})
vim.api.nvim_win_set_buf(0, buf)
-- Simulate the user's own fold setup (must be restored on expand).
vim.wo.foldmethod = 'indent'
local user_foldtext = vim.wo.foldtext

-- Render outputs the way execute_cell does: anchored on each cell's last line.
render.begin(buf, 1, 5, 7, 20, 'rounded', true, nil)
render.add(buf, 1, 'result', '3\n')
render.mark_done(buf, 1, 1, 'ok')
render.begin(buf, 2, 12, 12, 20, 'rounded', true, nil)
render.add(buf, 2, 'stdout', '3\n')
render.mark_done(buf, 2, 2, 'ok')

-- Whole-window display height (buffer lines + virt_lines, fold-aware): the
-- output boxes are proven visible by height accounting — collapsing folds
-- [1,2] [4,6] [11,11] turns 6 buffer lines into 3 fold lines (net -3), so if
-- the outputs' virt_lines survive, total height drops by EXACTLY 3.
local function win_height()
  return vim.api.nvim_win_text_height(0, {}).all
end
local expanded_h = win_height()
check('sanity_output_rendered', expanded_h > vim.api.nvim_buf_line_count(buf), true)

-- ---- collapse -----------------------------------------------------------
vim.cmd('CmdLineNotebookCollapse')

check('collapse_sets_manual_folds', vim.wo.foldmethod, 'manual')
-- Leading block folds 1..2; its last line (3) stays visible.
check('leading_block_folded', vim.fn.foldclosed(1) > 0, true)
check('leading_anchor_visible', vim.fn.foldclosed(3), -1)
-- Titled code cell folds 4..6; anchor line 7 visible with its output intact.
check('code_cell_folded', vim.fn.foldclosed(5) > 0, true)
check('code_cell_anchor_visible', vim.fn.foldclosed(7), -1)
check('outputs_still_rendered', win_height(), expanded_h - 3)
-- Markdown cell 8..10 fully expanded.
check('markdown_not_folded',
  vim.fn.foldclosed(8) == -1 and vim.fn.foldclosed(9) == -1
  and vim.fn.foldclosed(10) == -1, true)
-- Last code cell: separator 11 folds (single-line fold), anchor 12 visible.
check('last_cell_sep_folded', vim.fn.foldclosed(11) > 0, true)
check('last_cell_anchor_visible', vim.fn.foldclosed(12), -1)
-- Foldtext carries the cell title and a hidden-line count.
local ft = vim.fn.foldtextresult(4)
check('foldtext_has_title', ft:find('load data', 1, true) ~= nil, true)
check('foldtext_has_count', ft:find('hidden', 1, true) ~= nil, true)

-- ---- expand -------------------------------------------------------------
vim.cmd('CmdLineNotebookCollapse')
check('expand_removes_folds', vim.fn.foldclosed(5), -1)
check('expand_restores_foldmethod', vim.wo.foldmethod, 'indent')
check('expand_restores_foldtext', vim.wo.foldtext, user_foldtext)

-- ---- re-collapse after adding a cell (refresh path) ----------------------
vim.api.nvim_buf_set_lines(buf, 12, 12, false, { '# %% new cell', 'x = 9', 'x' })
vim.cmd('CmdLineNotebookCollapse')
check('recollapse_folds_new_cell', vim.fn.foldclosed(14) > 0, true)
check('recollapse_new_anchor_visible', vim.fn.foldclosed(15), -1)
vim.cmd('CmdLineNotebookCollapse')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('COLLAPSE OK')
  vim.cmd('qall!')
end
