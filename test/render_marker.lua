-- Unit test for the notebook run marker (the "✓ [N]" / "✗ [N]" badge).
--
-- Regression: when a cell is queued behind one that errors, the kernel ABORTS
-- it — the execute_reply carries status "aborted" and execution_count null.
-- vim.json.decode turns that null into vim.NIL (a userdata), which is truthy in
-- Lua, so a plain `if count` guard let it reach string.format('%d', ...) and
-- crashed redraw with "bad argument #1 to 'format' (number expected, got
-- userdata)". mark_done must normalise it away, never crash, and never show an
-- aborted/errored cell as a success.
--   nvim --headless -u NONE -N -l test/render_marker.lua
vim.opt.rtp:prepend('.')
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
local function check_has(label, hay, needle)
  if type(hay) == 'string' and hay:find(needle, 1, true) then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' hay=' .. vim.inspect(hay) .. ' needle=' .. vim.inspect(needle))
  end
end
local function check_lacks(label, hay, needle)
  if type(hay) == 'string' and not hay:find(needle, 1, true) then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' hay=' .. vim.inspect(hay) .. ' must_not_have=' .. vim.inspect(needle))
  end
end

-- Concatenate every chunk of every virt_line of this buffer's render extmarks.
local function virt_string(bufnr)
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, render.ns, 0, -1, { details = true })
  local parts = {}
  for _, m in ipairs(marks) do
    local vl = m[4] and m[4].virt_lines
    if vl then
      for _, line in ipairs(vl) do
        for _, chunk in ipairs(line) do
          parts[#parts + 1] = chunk[1]
        end
      end
    end
  end
  return table.concat(parts, '')
end

-- A fresh single-line buffer + cell, marker enabled, with the given border.
local function fresh(border, with_output)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
  render.begin(buf, 1, 1, 1, 20, border, true)
  if with_output then
    render.add(buf, 1, 'stdout', 'hello\n')
  end
  return buf
end

-- The faithful repro: execution_count null decoded from JSON is vim.NIL.
local NIL_COUNT = vim.json.decode('{"execution_count":null}').execution_count
check('decoded null is userdata', type(NIL_COUNT), 'userdata')

-- 1. Successful cell: ✓ with its execution count.
local buf = fresh('none', true)
render.mark_done(buf, 1, 5, 'ok')
check_has('ok_shows_check', virt_string(buf), '✓')
check_has('ok_shows_count', virt_string(buf), '[5]')

-- 2. Errored cell (the one that raised): ✗ with its count.
buf = fresh('none', true)
render.mark_done(buf, 1, 3, 'error')
check_has('error_shows_cross', virt_string(buf), '✗')
check_has('error_shows_count', virt_string(buf), '[3]')

-- 3. Aborted cell, no output: must NOT crash, must be ✗, must omit "[N]".
buf = fresh('none', false)
local ok = pcall(render.mark_done, buf, 1, NIL_COUNT, 'aborted')
check('aborted_no_crash', ok, true)
check_has('aborted_shows_cross', virt_string(buf), '✗')
check_lacks('aborted_no_count', virt_string(buf), '[')
check_lacks('aborted_not_success', virt_string(buf), '✓')

-- 4. Aborted cell WITH output, bordered: exercises the embedded-title border
--    path (a different string.format branch) — must also not crash.
buf = fresh('rounded', true)
ok = pcall(render.mark_done, buf, 1, NIL_COUNT, 'aborted')
check('aborted_bordered_no_crash', ok, true)
check_has('aborted_bordered_cross', virt_string(buf), '✗')

-- 5. Aborted cell, no output, bordered: exercises the single-rule-line path.
buf = fresh('rounded', false)
ok = pcall(render.mark_done, buf, 1, NIL_COUNT, 'aborted')
check('aborted_rule_no_crash', ok, true)

if fail > 0 then
  vim.cmd('cquit!')
else
  print('RENDER MARKER OK')
  vim.cmd('qall!')
end
