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

-- expr folds, not manual: mkview persists 'foldexpr', making the collapsed
-- state recognizable (and expandable) even in a later session that restored
-- it via loadview with no buffer-local toggle state left.
check('collapse_sets_expr_folds', vim.wo.foldmethod, 'expr')
check('collapse_foldexpr_signature',
  vim.wo.foldexpr:find('VimCmdLineNotebookFoldExpr', 1, true) ~= nil, true)
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

-- ---- new cell added WHILE collapsed folds itself --------------------------
-- The foldexpr recomputes its map per buffer change, so the view tracks
-- edits live — no re-toggle needed.
vim.cmd('CmdLineNotebookCollapse')
vim.api.nvim_buf_set_lines(buf, 17, 17, false, { '# %% new cell', 'x = 9', 'x' })
check('new_cell_folds_live',
  vim.fn.foldclosed(19) > 0 and vim.fn.foldclosed(20) > 0, true)
-- Contiguous fold ranges stay SEPARATE folds (the '>1' range starts): the
-- trailing-blanks chunk [16,17] touches the new cell's range [18,20].
check('adjacent_cells_not_merged', vim.fn.foldclosed(18), 18)
vim.cmd('CmdLineNotebookCollapse')

-- ---- collapse never persists across sessions ------------------------------
-- mkview/loadview (viewoptions containing "folds") can restore fdm=expr and
-- our foldexpr into a session with no buffer-local toggle state. The plugin's
-- BufWinEnter autocmd (which runs after a vimrc loadview autocmd) must
-- dissolve that orphaned state back to the GLOBAL fold options — the user's
-- own folding, not the presentation view, is what persists.
-- NB: set the restored state with :setlocal exactly like a real view file —
-- vim.wo assignment would clobber the GLOBAL option value too, corrupting
-- the very setting the dissolve falls back to.
vim.go.foldmethod = 'indent'         -- the user's vimrc-level setting
vim.cmd('setlocal foldmethod=expr')  -- what loadview restores
vim.cmd([[setlocal foldexpr=VimCmdLineNotebookFoldExpr(v:lnum)]])
vim.b[buf].cmdline_code_collapsed = nil
vim.b[buf].cmdline_code_fold_save = nil
check('viewrestore_folds_present', vim.fn.foldclosed(5) > 0, true)
vim.cmd('doautocmd BufWinEnter')     -- what re-showing the buffer fires
check('viewrestore_dissolved_foldmethod', vim.wo.foldmethod, 'indent')
check('viewrestore_dissolved_folds', vim.fn.foldclosed(5), -1)

-- ...but an ACTIVE in-session collapse survives re-entering the window.
vim.cmd('CmdLineNotebookCollapse')
check('insession_collapsed', vim.fn.foldclosed(5) > 0, true)
vim.cmd('doautocmd BufWinEnter')
check('insession_survives_bufwinenter', vim.fn.foldclosed(5) > 0, true)
vim.cmd('CmdLineNotebookCollapse')
check('insession_expand_still_works', vim.wo.foldmethod, 'indent')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('COLLAPSE OK')
  vim.cmd('qall!')
end
