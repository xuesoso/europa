-- Regression: re-running the SAME cell region with DIFFERENT output must
-- refresh the inline rendered extmark — showing the new output and dropping the
-- old — not just the stored (OpenOutput) text. Exercised with ft='python' so
-- the highlight cache (keyed by text) is on the path: a stale cache or a stale
-- extmark would show the previous run's content.
--   nvim --headless -u NONE -N -l test/render_rerun.lua
vim.opt.rtp:prepend('.')
local render = require('vimcmdline.notebook.render')

local fail = 0
local function check(label, cond)
  if cond then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label)
  end
end

-- All text across every virt_line chunk of this buffer's render extmarks: what
-- is actually drawn inline.
local function virt_string(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })
  local parts = {}
  for _, m in ipairs(marks) do
    local vl = m[4] and m[4].virt_lines
    if vl then
      for _, ln in ipairs(vl) do
        for _, chunk in ipairs(ln) do
          parts[#parts + 1] = chunk[1]
        end
      end
    end
  end
  return table.concat(parts, '')
end

local function has(bufnr, needle) return virt_string(bufnr):find(needle, 1, true) ~= nil end
-- The stored (OpenOutput) text for the cell region.
local function stored(bufnr, s, e)
  local t = render.get_range_text(bufnr, s, e)
  return t and table.concat(t, '\n') or ''
end

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'run()' })
local seq = 0
-- Re-run the cell at region [2,2]: fresh cell_id each time (as execute_cell
-- does), then feed the run's output and finalize with a synchronous redraw.
local function run(output)
  seq = seq + 1
  render.begin(buf, seq, 2, 2, 50, 'rounded', true, 'python')
  render.add(buf, seq, 'stdout', output)
  render.mark_done(buf, seq, seq, 'ok')  -- forces redraw
end

-- 1. First run.
run('alpha_value = 111\n')
check('run1_inline_shows_new', has(buf, 'alpha_value = 111'))
check('run1_stored', stored(buf, 2, 2) == 'alpha_value = 111')

-- 2. Re-run, different content: inline shows new, old is gone (both inline and
--    stored).
run('beta_value = 222\n')
check('rerun_inline_shows_new', has(buf, 'beta_value = 222'))
check('rerun_inline_drops_old', not has(buf, 'alpha_value'))
check('rerun_inline_drops_old_num', not has(buf, '111'))
check('rerun_stored_replaced', stored(buf, 2, 2) == 'beta_value = 222')

-- 3. Same identifier, different value (the exact cache-key concern: text keyed
--    on the whole line, so '= 1' must not linger when it becomes '= 2').
run('gamma = 1\n')
check('rerun_same_ident_v1', has(buf, 'gamma = 1'))
run('gamma = 2\n')
check('rerun_same_ident_v2_new', has(buf, 'gamma = 2'))
check('rerun_same_ident_v2_no_old', not has(buf, 'gamma = 1'))

-- 4. Output shrinks: a 3-line run followed by a 1-line run leaves no stale lines.
run('l1 = 1\nl2 = 2\nl3 = 3\n')
check('multiline_all_present', has(buf, 'l1 = 1') and has(buf, 'l2 = 2') and has(buf, 'l3 = 3'))
run('only = 9\n')
check('shrink_shows_new', has(buf, 'only = 9'))
check('shrink_drops_l2', not has(buf, 'l2 = 2'))
check('shrink_drops_l3', not has(buf, 'l3 = 3'))
check('shrink_stored', stored(buf, 2, 2) == 'only = 9')

-- 5. Output grows again: new lines appear, prior single line gone.
run('g1 = 1\ng2 = 2\n')
check('grow_shows_all', has(buf, 'g1 = 1') and has(buf, 'g2 = 2'))
check('grow_drops_prev', not has(buf, 'only = 9'))

if fail > 0 then
  vim.cmd('cquit!')
else
  print('RENDER RERUN OK')
  vim.cmd('qall!')
end
