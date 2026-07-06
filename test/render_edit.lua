-- Regression: cell output must FOLLOW its cell when the buffer is edited.
-- The extmark drifts with insertions/deletions, but the stored
-- start_line/end_line used to be frozen at begin() time, so (a) the next
-- streaming redraw re-pinned the mark back at the stale row, and (b) a re-run
-- after edits missed the overlap test, leaking the old run and duplicating
-- output boxes. Both must stay fixed.
--   nvim --headless -u NONE -N -l test/render_edit.lua
vim.opt.rtp:prepend('.')
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

local function marks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false,
  { '# %%', 'a = 1', '# %%', 'b = 2' })

-- Run the cell on lines 3-4 (1-based); output anchors under line 4.
render.begin(buf, 1, 3, 4, 50, 'rounded', true, nil)
render.add(buf, 1, 'stdout', 'first chunk\n')
check('anchor_row_initial', marks(buf)[1][2], 3)  -- 0-based row of line 4

-- Insert three lines at the top; the extmark drifts to row 6.
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# prelude', 'x = 0', '' })
check('anchor_drifts_with_edit', marks(buf)[1][2], 6)

-- A later streaming chunk redraws the cell. The redraw must keep the mark at
-- the drifted row, not snap it back to the stale stored row 3.
render.add(buf, 1, 'stdout', 'second chunk\n')
render.finish(buf, 1)
check('anchor_kept_after_redraw', marks(buf)[1][2], 6)

-- Re-run the same cell at its NEW coordinates (lines 6-7 now). The overlap
-- test must drop the old run: exactly one extmark remains, and the stored
-- output is the new run's, not a merge.
render.begin(buf, 2, 6, 7, 50, 'rounded', true, nil)
render.add(buf, 2, 'stdout', 'rerun output\n')
render.mark_done(buf, 2, 1, 'ok')
check('rerun_after_edit_single_mark', #marks(buf), 1)
local text = table.concat(render.get_range_text(buf, 6, 7) or {}, '\n')
check('rerun_after_edit_replaces_stored', text, 'rerun output')

-- Deleting lines above shifts everything up; the popup lookup must find the
-- cell at its current position, not its begin()-time position.
vim.api.nvim_buf_set_lines(buf, 0, 3, false, {})
check('anchor_after_delete', marks(buf)[1][2], 3)
local found = render.get_range_text(buf, 3, 4)
check('find_cell_tracks_delete', found and table.concat(found, '\n') or nil,
      'rerun output')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('RENDER EDIT OK')
  vim.cmd('qall!')
end
