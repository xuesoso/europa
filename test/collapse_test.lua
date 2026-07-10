-- :CmdLineNotebookCollapse — presentation view. Collapsing must fold every
-- non-markdown cell's code, leave '# %% [markdown]' cells fully expanded, and
-- keep the lines that anchor rendered output boxes visible WHEREVER they are:
-- outputs anchor to the line the cell ended on WHEN IT RAN (drifting with
-- edits), which is NOT necessarily the cell's last line — e.g. blank lines
-- added after running (the ~/Downloads/test.py regression). A closed fold
-- hides virt_lines anchored anywhere inside it, so folds must wrap AROUND
-- the live anchors. Cells with no output fold entirely. Toggling again must
-- restore the user's fold setup.
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

-- A notebook-shaped buffer: leading imports (never run), a titled code cell,
-- a markdown cell, a plain code cell, and a cell with trailing blank lines
-- whose output anchor sits MID-region (ran before the blanks were added).
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'import numpy as np',          -- 1  leading block: code, no output
  'import pandas as pd',         -- 2
  '',                            -- 3
  '# %% load data',              -- 4  code cell w/ title
  'a = 1',                       -- 5
  'b = 2',                       -- 6
  'a + b',                       -- 7  <- anchor (cell 1)
  '# %% [markdown]',             -- 8  markdown cell: stays expanded
  '# ## Results',                -- 9
  '# The sum is shown below.',   -- 10
  '# %%',                        -- 11 code cell
  'print(a + b)',                -- 12 <- anchor (cell 2)
  '# %% trailing blanks',        -- 13 the regression: cell ends in blanks
  'z = 5',                       -- 14
  'z',                           -- 15 <- anchor (cell 3, ran before blanks)
  '',                            -- 16
  '',                            -- 17
})
vim.api.nvim_win_set_buf(0, buf)
-- Simulate the user's own fold setup (must be restored on expand).
vim.wo.foldmethod = 'indent'
local user_foldtext = vim.wo.foldtext

-- Render outputs the way execute_cell does, anchored where each cell ended
-- at run time.
render.begin(buf, 1, 5, 7, 20, 'rounded', true, nil)
render.add(buf, 1, 'result', '3\n')
render.mark_done(buf, 1, 1, 'ok')
render.begin(buf, 2, 12, 12, 20, 'rounded', true, nil)
render.add(buf, 2, 'stdout', '3\n')
render.mark_done(buf, 2, 2, 'ok')
render.begin(buf, 3, 14, 15, 20, 'rounded', true, nil)
render.add(buf, 3, 'result', '5\n')
render.mark_done(buf, 3, 3, 'ok')

-- Whole-window display height (buffer lines + virt_lines, fold-aware): the
-- output boxes are proven visible by height accounting — collapsing folds
-- [1,3] [4,6] [11,11] [13,14] [16,17] turns 11 buffer lines into 5 fold
-- lines (net -6), so if every output's virt_lines survive, total height
-- drops by EXACTLY 6.
local function win_height()
  return vim.api.nvim_win_text_height(0, {}).all
end
local expanded_h = win_height()
check('sanity_output_rendered', expanded_h > vim.api.nvim_buf_line_count(buf), true)

-- ---- collapse -----------------------------------------------------------
vim.cmd('CmdLineNotebookCollapse')

check('collapse_sets_manual_folds', vim.wo.foldmethod, 'manual')
-- Leading block has no output: folds ENTIRELY (header foldtext only).
check('leading_block_folds_fully',
  vim.fn.foldclosed(1) > 0 and vim.fn.foldclosed(3) > 0, true)
-- Titled code cell folds 4..6; anchor line 7 visible with its output intact.
check('code_cell_folded', vim.fn.foldclosed(5) > 0, true)
check('code_cell_anchor_visible', vim.fn.foldclosed(7), -1)
check('outputs_still_rendered', win_height(), expanded_h - 6)
-- Markdown cell 8..10 fully expanded.
check('markdown_not_folded',
  vim.fn.foldclosed(8) == -1 and vim.fn.foldclosed(9) == -1
  and vim.fn.foldclosed(10) == -1, true)
-- Plain code cell: separator 11 folds (single-line fold), anchor 12 visible.
check('cell2_sep_folded', vim.fn.foldclosed(11) > 0, true)
check('cell2_anchor_visible', vim.fn.foldclosed(12), -1)
-- The regression: anchor mid-region stays visible, code above AND the
-- trailing blanks below both fold.
check('midanchor_code_folded', vim.fn.foldclosed(14) > 0, true)
check('midanchor_visible', vim.fn.foldclosed(15), -1)
check('midanchor_trailing_blanks_folded',
  vim.fn.foldclosed(16) > 0 and vim.fn.foldclosed(17) > 0, true)
-- Foldtext carries the cell title and a hidden-line count.
local ft = vim.fn.foldtextresult(4)
check('foldtext_has_title', ft:find('load data', 1, true) ~= nil, true)
check('foldtext_has_count', ft:find('hidden', 1, true) ~= nil, true)

-- ---- expand -------------------------------------------------------------
vim.cmd('CmdLineNotebookCollapse')
check('expand_removes_folds', vim.fn.foldclosed(5), -1)
check('expand_restores_foldmethod', vim.wo.foldmethod, 'indent')
check('expand_restores_foldtext', vim.wo.foldtext, user_foldtext)

-- ---- re-collapse after adding an unrun cell (refresh path) ----------------
vim.api.nvim_buf_set_lines(buf, 17, 17, false, { '# %% new cell', 'x = 9', 'x' })
vim.cmd('CmdLineNotebookCollapse')
check('recollapse_folds_new_cell_fully',
  vim.fn.foldclosed(19) > 0 and vim.fn.foldclosed(20) > 0, true)
vim.cmd('CmdLineNotebookCollapse')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('COLLAPSE OK')
  vim.cmd('qall!')
end
