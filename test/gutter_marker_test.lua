-- Run-marker styles (cmdline_notebook_exec_marker) and the separator icon.
-- Three sections:
--
-- 'left': a colored bar (sign column) spans the cell, the separator line's
-- sign is the execution count (status = color). Invariants: everything stays
-- in the sign column (no virt_text, nothing shifts); no rule line for
-- no-output cells, but cells WITH output embed "✓ [N]" in the box's top
-- border (free — never when the border style draws no box); running → ● /
-- ok → digits / error → digits / aborted → ✗ / past 99 → '++' (sign_text is
-- capped at 2 cells); priority 9 so bookmark signs (legacy default 10) win a
-- 1-slot 'signcolumn' and coexist under auto:2.
--
-- 'separator' (the DEFAULT): a "✓ [N]" badge as virt_text on the cell's own
-- LAST line — see that section's header for its invariants.
--
-- Separator icon: '# %%' displayed as a horizontal bar — see that section.
--
-- Shared invariants: all marker decorations live in render.gutter_ns, NEVER
-- render.ns — anchor_rows() treats every render.ns mark as an output anchor
-- and the collapse view would pin every decorated line visible; marks drift
-- with edits; reruns and the clear paths remove them.
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

-- Marker decoration for a line: sign fields ('left' style: sign/hl/prio;
-- virt must be nil there — that style never draws in the text area) and
-- virt_text fields ('separator' style: virt/vcol/vpos).
local function gutter_at(lnum)
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.gutter_ns,
    { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
  if #marks == 0 then
    return nil
  end
  local d = marks[1][4]
  -- nvim pads sign_text to the sign column's 2 cells; compare it trimmed.
  return { sign = (d.sign_text or ''):gsub('%s+$', ''),
           hl = d.sign_hl_group, prio = d.priority, virt = d.virt_text,
           vcol = d.virt_text_win_col, vpos = d.virt_text_pos }
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

-- ==== 'separator' style (the DEFAULT): badge on the cell's LAST line =====
-- A "✓ [N]" badge as right-aligned virt_text on the cell's own last executed
-- line — the row just above the next '# %%', and simply the cell's end for
-- the final block (one uniform rule, no last-cell special case). Separator
-- lines never carry a badge. Unrun cells get NOTHING drawn — a plain
-- comment-colored '# %%' is the not-run state — and the border-embedded
-- marker is suppressed in this style (the badge sits right above the output
-- box; embedding would duplicate it). Err is orange (CmdlineNotebookSepErr),
-- not red, per the style's design.
render.clear_all(buf)
render.begin(buf, 20, 4, 5, 20, 'rounded', 'separator', nil)
local sb = gutter_at(5)
check('sep_running_badge_on_end_line', sb and sb.virt[1][1], '●')
check('sep_running_hl', sb and sb.virt[1][2], 'CmdlineNotebookSepRun')
-- Default column: right-aligned to the window edge
-- (g:cmdline_notebook_marker_col = 'right'); numbers opt into a fixed
-- column, tested further below.
check('sep_badge_right_aligned', sb and sb.vpos, 'right_align')
check('sep_badge_no_fixed_col', sb and sb.vcol, nil)
check('sep_no_sign_column_use', sb and sb.sign, '')
check('sep_separator_line_untouched', gutter_at(6), nil)
check('sep_unrun_cells_undecorated', nmarks(render.gutter_ns), 1)
render.add(buf, 20, 'result', '3\n')
render.mark_done(buf, 20, 3, 'ok')
sb = gutter_at(5)
check('sep_ok_badge', sb.virt[1][1], '✓ [3]')
check('sep_ok_hl', sb.virt[1][2], 'CmdlineNotebookSepOk')
-- No border embed in this style: the badge is directly above the box.
check('sep_output_box_rendered', nmarks(render.ns), 1)
check('sep_no_border_embed', virt_has('✓ [3]'), false)

-- error → orange ✗ [N]
render.begin(buf, 21, 4, 5, 20, 'rounded', 'separator', nil)
render.add(buf, 21, 'error', 'boom\n')
render.mark_done(buf, 21, 4, 'error')
sb = gutter_at(5)
check('sep_err_badge', sb.virt[1][1], '✗ [4]')
check('sep_err_hl', sb.virt[1][2], 'CmdlineNotebookSepErr')

-- no-output cell: badge only — nothing rendered below the cell
render.begin(buf, 22, 4, 5, 20, 'rounded', 'separator', nil)
render.mark_done(buf, 22, 5, 'ok')
check('sep_no_output_badge', gutter_at(5).virt[1][1], '✓ [5]')
check('sep_no_output_no_rule_line', nmarks(render.ns), 0)

-- LAST cell (no '# %%' below): same rule, badge on its end line — running,
-- with output, and the once-swallowed no-output case all show the same way
render.begin(buf, 23, 7, 7, 20, 'rounded', 'separator', nil)
check('sep_last_cell_running', gutter_at(7).virt[1][1], '●')
render.add(buf, 23, 'stdout', 'done\n')
render.mark_done(buf, 23, 9, 'ok')
check('sep_last_cell_badge', gutter_at(7).virt[1][1], '✓ [9]')
check('sep_last_cell_no_border_embed', virt_has('✓ [9]'), false)
render.begin(buf, 24, 7, 7, 20, 'rounded', 'separator', nil)
render.mark_done(buf, 24, 10, 'ok')
check('sep_last_cell_no_output_badge', gutter_at(7).virt[1][1], '✓ [10]')
check('sep_last_cell_no_output_hl', gutter_at(7).virt[1][2], 'CmdlineNotebookSepOk')

-- edits drift the badge with its line
vim.api.nvim_buf_set_lines(buf, 0, 0, false, { '# comment above' })
check('sep_drift_follows_edit', gutter_at(8).virt[1][1], '✓ [10]')
vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})

-- a numeric g:cmdline_notebook_marker_col opts into a fixed column — a
-- fraction of the window's text width (tracking layout changes via the
-- VimResized/WinResized repaint) or an absolute column when > 1
vim.g.cmdline_notebook_marker_col = 0.5
vim.cmd('doautocmd VimResized')
local wi = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
local full = math.floor((wi.width - wi.textoff) * 0.5)
check('sep_badge_fraction_col', gutter_at(7).vcol, full)
vim.cmd('vsplit')
vim.cmd('doautocmd WinResized')
local swi = vim.fn.getwininfo(vim.fn.bufwinid(buf))[1]
local shalf = math.floor((swi.width - swi.textoff) * 0.5)
check('sep_badge_tracks_resize',
  gutter_at(7).vcol == shalf and shalf < full, true)
vim.cmd('only')
vim.cmd('doautocmd WinResized')
check('sep_badge_restores_width', gutter_at(7).vcol, full)
vim.g.cmdline_notebook_marker_col = 45
vim.cmd('doautocmd VimResized')
check('sep_badge_absolute_col', gutter_at(7).vcol, 45)
-- back to the default: right-aligned again
vim.g.cmdline_notebook_marker_col = nil
vim.cmd('doautocmd VimResized')
check('sep_badge_back_to_right', gutter_at(7).vpos, 'right_align')

-- clearing the cell clears its badge
render.clear_range(buf, 4, 5)
check('sep_clear_range_clears_badge', gutter_at(5), nil)
render.clear_all(buf)

-- ==== separator icon: '# %%' displayed as a horizontal bar, zero shift =====
-- Ephemeral decoration-provider overlays exist only during a redraw, so this
-- is asserted at the SCREEN level. The overlay is sized to the token's exact
-- width — the default single-char '━' REPEATS to fill it, multi-char icons
-- pad with spaces — so the title after '# %%' must stay at its original
-- column. The cursor line stays literal for editing; '' disables the icon.
local ibuf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(ibuf, 0, -1, false, {
  '# %% alpha',   -- 1
  'a = 1',        -- 2
  '# %% beta',    -- 3
  'b = 2',        -- 4
})
vim.api.nvim_win_set_buf(0, ibuf)
vim.b[ibuf].cmdline_notebook = 1
vim.api.nvim_win_set_cursor(0, { 2, 0 })
local function srow(r)
  local s = {}
  for c = 1, 24 do s[#s + 1] = vim.fn.screenstring(r, c) end
  return (table.concat(s):gsub('%s+$', ''))
end
vim.cmd('redraw!')
check('icon_bar_fills_token', srow(1):find('━━━━', 1, true), 1)
check('icon_covers_whole_token', srow(1):find('%%', 1, true), nil)
-- same SCREEN column as the literal text (col 6): the 4-cell bar covers
-- '# %%' exactly. srow() concatenates per-cell strings, so the byte offset
-- is 4*#'━' + 2
check('icon_title_not_shifted', srow(1):find('alpha', 1, true), 4 * #'━' + 2)
check('icon_on_every_separator', srow(3):find('━━━━', 1, true), 1)
-- the cursor line keeps the literal separator for editing
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd('redraw!')
check('icon_cursor_line_literal', srow(1):find('# %%', 1, true), 1)
check('icon_other_lines_still_iconed', srow(3):find('━━━━', 1, true), 1)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
-- multi-char icons are left-aligned + space-padded, not repeated
vim.g.cmdline_notebook_sep_icon = '>>'
vim.cmd('redraw!')
check('icon_multichar_padded',
  srow(1):sub(1, 2) == '>>' and srow(1):find('alpha', 1, true) == 6, true)
-- inactive buffers (no b:cmdline_notebook) and '' both keep the literal text
vim.g.cmdline_notebook_sep_icon = ''
vim.cmd('redraw!')
check('icon_empty_disables', srow(1):find('# %%', 1, true), 1)
vim.g.cmdline_notebook_sep_icon = nil
vim.b[ibuf].cmdline_notebook = nil
vim.cmd('redraw!')
check('icon_needs_active_notebook', srow(1):find('# %%', 1, true), 1)
vim.b[ibuf].cmdline_notebook = 1
-- an icon WIDER than the token would cover the title: overlay disabled
vim.g.cmdline_notebook_sep_icon = '>>>>>'
vim.cmd('redraw!')
check('icon_wider_than_token_disabled', srow(1):find('# %%', 1, true), 1)
vim.g.cmdline_notebook_sep_icon = nil
vim.api.nvim_win_set_buf(0, buf)

-- ---- config resolution ----------------------------------------------------
package.loaded['vimcmdline.notebook.config'] = nil
local config = require('vimcmdline.notebook.config')
vim.g.cmdline_notebook_exec_marker = 'separator'
check('cfg_separator', config.read().exec_marker, 'separator')
vim.g.cmdline_notebook_exec_marker = 'left'
check('cfg_left', config.read().exec_marker, 'left')
vim.g.cmdline_notebook_exec_marker = 1
check('cfg_legacy_on', config.read().exec_marker, 'below')
vim.g.cmdline_notebook_exec_marker = 'below'
check('cfg_below', config.read().exec_marker, 'below')
vim.g.cmdline_notebook_exec_marker = 0
check('cfg_off', config.read().exec_marker, false)
-- 'separator' is the default at BOTH default sites: config.lua's fallback
-- (unset global) and the plugin's materialized g: value (captured at source
-- time, before this section mutated it).
vim.g.cmdline_notebook_exec_marker = nil
check('cfg_default_separator', config.read().exec_marker, 'separator')
check('plugin_materialized_default', plugin_default_marker, 'separator')

if fail > 0 then
  vim.cmd('cquit!')
else
  print('GUTTER OK')
  vim.cmd('qall!')
end
