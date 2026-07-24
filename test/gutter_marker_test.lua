-- exec_marker = 'left': run status drawn in the LEFT gutter — a colored bar
-- (sign column) spanning the cell, the separator line's sign showing the
-- execution count (status = color) — instead of the below-cell rule / border
-- marker. Invariants:
--   * gutter marks live in render.gutter_ns, NEVER render.ns: anchor_rows()
--     treats every render.ns mark as an output anchor and the collapse view
--     would pin every bar line visible;
--   * everything stays in the sign column — NO virtual text in the text area,
--     so the separator line never shifts;
--   * a finished no-output cell draws NO rule line in 'left' mode (that is
--     the vertical space this mode buys); a cell WITH output additionally
--     embeds "✓ [N]" in the box's top border — free, the line exists anyway —
--     but never when the border style draws no box (a title there would cost
--     a leading line);
--   * running → ● (run hl); ok → count digits (ok hl); error → digits
--     (err hl); aborted (count=nil) → ✗; counts past 99 → '++' (sign_text is
--     capped at 2 cells);
--   * priority 9: legacy :sign place (bookmark plugins) defaults to 10, so
--     user signs win a 1-slot 'signcolumn' and coexist under auto:2;
--   * bar covers the separator line when the cell has one, else the cell's
--     first line; marks drift with edits; reruns and the clear paths remove
--     them.
--   nvim --headless -u NONE -N -l test/gutter_marker_test.lua
vim.opt.rtp:prepend('.')
vim.g.cmdline_notebook_enable = 1
vim.cmd('source plugin/vimcmdline.vim')
local plugin_default_marker = vim.g.cmdline_notebook_exec_marker

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

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  'import numpy as np',   -- 1  leading cell: no separator above
  'x = 1',                -- 2
  '# %% titled cell',     -- 3  separator
  'a = 1',                -- 4
  'a + b',                -- 5
  '# %%',                 -- 6  separator
  'z = 5',                -- 7
})
vim.api.nvim_win_set_buf(0, buf)

-- Gutter mark for a line: {sign, hl, priority, virt} (virt = any virt_text,
-- which must always be nil — the gutter never draws in the text area).
local function gutter_at(lnum)
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.gutter_ns,
    { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
  if #marks == 0 then
    return nil
  end
  local d = marks[1][4]
  -- nvim pads sign_text to the sign column's 2 cells; compare it trimmed.
  return { sign = (d.sign_text or ''):gsub('%s+$', ''),
           hl = d.sign_hl_group, prio = d.priority, virt = d.virt_text }
end

local function nmarks(ns)
  return #vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
end

-- Does any rendered output (virt_lines) contain `text`?
local function virt_has(text)
  local mk = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
  for _, m in ipairs(mk) do
    for _, line in ipairs(m[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do
        if chunk[1]:find(text, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

-- ---- running state, cell with separator (lines 4..5, sep 3) ---------------
render.begin(buf, 1, 4, 5, 20, 'rounded', 'left', nil)
check('running_badge_on_separator', gutter_at(3).sign, '●')
check('running_bar_covers_body',
  gutter_at(4).sign == '▎' and gutter_at(5).sign == '▎', true)
check('running_hl', gutter_at(3).hl, 'CmdlineNotebookGutterRun')
check('no_text_area_virt_text',
  gutter_at(3).virt == nil and gutter_at(4).virt == nil, true)
check('below_bookmark_priority', gutter_at(3).prio, 9)
check('gutter_not_in_output_ns', nmarks(render.ns), 0)

-- ---- success: badge becomes the count, everything green -------------------
render.add(buf, 1, 'result', '3\n')
render.mark_done(buf, 1, 3, 'ok')
check('ok_badge_is_count', gutter_at(3).sign, '3')
check('ok_badge_hl', gutter_at(3).hl, 'CmdlineNotebookGutterOk')
check('ok_bar_hl_body', gutter_at(5).hl, 'CmdlineNotebookGutterOk')
-- The output box still renders (one anchor mark in the output namespace),
-- and since its top border exists anyway, the "✓ [N]" marker rides it for
-- free — 'left' + output shows BOTH gutter and border marker.
check('output_box_rendered', nmarks(render.ns), 1)
check('border_marker_embedded', virt_has('✓ [3]'), true)
-- ...and anchor_rows sees ONLY it — the bar marks must not leak into the
-- collapse view's visible-line set.
local rows = render.anchor_rows(buf)
check('anchor_rows_only_output', #rows == 1 and rows[1] == 5, true)

-- ---- no-output cell buys back the rule line -------------------------------
render.begin(buf, 2, 7, 7, 20, 'rounded', 'left', nil)
render.mark_done(buf, 2, 4, 'ok')
check('no_output_no_rule_line', nmarks(render.ns), 1)  -- still just cell 1's
check('no_output_bar_present', gutter_at(6) ~= nil and gutter_at(7) ~= nil, true)
check('no_output_badge', gutter_at(6).sign, '4')

-- ---- failed cell: count in red --------------------------------------------
render.begin(buf, 3, 7, 7, 20, 'rounded', 'left', nil)
render.add(buf, 3, 'error', 'NameError\n')
render.mark_done(buf, 3, 12, 'error')
check('err_badge_two_digits', gutter_at(6).sign, '12')
check('err_badge_hl', gutter_at(6).hl, 'CmdlineNotebookGutterErr')
check('err_hl_body', gutter_at(7).hl, 'CmdlineNotebookGutterErr')
check('err_border_marker_embedded', virt_has('✗ [12]'), true)

-- ---- aborted cell: execution_count arrives as vim.NIL → ✗ -----------------
render.begin(buf, 4, 7, 7, 20, 'rounded', 'left', nil)
render.mark_done(buf, 4, vim.NIL, 'aborted')
check('aborted_badge_cross', gutter_at(6).sign, '✗')
check('aborted_badge_hl', gutter_at(6).hl, 'CmdlineNotebookGutterErr')

-- ---- counts past two digits degrade (sign_text is 2 cells max) ------------
render.begin(buf, 5, 7, 7, 20, 'rounded', 'left', nil)
render.mark_done(buf, 5, 100, 'ok')
check('count_over_99_degrades', gutter_at(6).sign, '++')

-- ---- borderless output: no border line to embed into → no title line ------
render.begin(buf, 51, 7, 7, 20, 'none', 'left', nil)
render.add(buf, 51, 'stdout', 'hello\n')
render.mark_done(buf, 51, 55, 'ok')
check('borderless_output_rendered', virt_has('hello'), true)
check('borderless_no_title_line', virt_has('[55]'), false)

-- ---- leading cell without separator: badge on its own first line ----------
render.begin(buf, 6, 1, 2, 20, 'rounded', 'left', nil)
render.mark_done(buf, 6, 6, 'ok')
check('leading_badge_on_first_line', gutter_at(1).sign, '6')
check('leading_bar_body', gutter_at(2).sign, '▎')

-- ---- edits drift the bar; repaint keeps live positions --------------------
render.begin(buf, 7, 4, 5, 20, 'rounded', 'left', nil)
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# comment above' })
-- separator is now line 4; badge must have moved with it
check('drift_badge_follows_edit', gutter_at(4).sign, '●')
render.mark_done(buf, 7, 7, 'ok')
check('drift_paint_at_live_pos', gutter_at(4).sign, '7')
check('drift_hl_updated', gutter_at(5).hl, 'CmdlineNotebookGutterOk')
vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})

-- ---- rerun replaces the old gutter (no stacking) --------------------------
local before = nmarks(render.gutter_ns)
render.begin(buf, 8, 4, 5, 20, 'rounded', 'left', nil)
check('rerun_no_mark_stacking', nmarks(render.gutter_ns) <= before, true)
render.mark_done(buf, 8, 8, 'ok')

-- ---- 'below' mode is untouched: rule line yes, gutter no ------------------
render.clear_all(buf)
check('clear_all_clears_gutter', nmarks(render.gutter_ns), 0)
render.begin(buf, 9, 7, 7, 20, 'rounded', true, nil)
render.mark_done(buf, 9, 9, 'ok')
check('below_mode_rule_line', nmarks(render.ns), 1)
check('below_mode_no_gutter', nmarks(render.gutter_ns), 0)

-- ---- clear_range drops the gutter of cells in range -----------------------
render.begin(buf, 10, 4, 5, 20, 'rounded', 'left', nil)
render.mark_done(buf, 10, 10, 'ok')
check('clear_range_pre', nmarks(render.gutter_ns) > 0, true)
render.clear_range(buf, 4, 5)
check('clear_range_clears_gutter', nmarks(render.gutter_ns), 0)

-- ---- config resolution ----------------------------------------------------
package.loaded['vimcmdline.notebook.config'] = nil
local config = require('vimcmdline.notebook.config')
vim.g.cmdline_notebook_exec_marker = 'left'
check('cfg_left', config.read().exec_marker, 'left')
vim.g.cmdline_notebook_exec_marker = 1
check('cfg_legacy_on', config.read().exec_marker, 'below')
vim.g.cmdline_notebook_exec_marker = 'below'
check('cfg_below', config.read().exec_marker, 'below')
vim.g.cmdline_notebook_exec_marker = 0
check('cfg_off', config.read().exec_marker, false)
-- 'left' is the default at BOTH default sites: config.lua's fallback (unset
-- global) and the plugin's materialized g: value (captured at source time,
-- before this section mutated it).
vim.g.cmdline_notebook_exec_marker = nil
check('cfg_default_left', config.read().exec_marker, 'left')
check('plugin_materialized_default', plugin_default_marker, 'left')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('GUTTER OK')
  vim.cmd('qall!')
end
