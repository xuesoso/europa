-- Performance benchmark for the inline-figure path.
--
--   grid       building the Unicode placeholder grid for many figures (the
--              per-figure CPU cost of image.show besides transmission).
--   transmit   encoding a realistic PNG into the kitty APC stream.
--   redraw     steady-state redraws of a cell holding a figure plus streaming
--              text under it (the shape of "plot, then keep printing").
--
-- Asserts grid content correctness so a speedup that changes bytes fails.
--
--   nvim --headless -u NONE -N -l test/bench_image.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
local img = require('vimcmdline.notebook.image')
local render = require('vimcmdline.notebook.render')

img._set_tty_writer(function() return true end)

local function ns() return vim.loop.hrtime() end
local function ms(dt) return dt / 1e6 end

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

-- Reference row built the obvious way, to pin the grid bytes.
local DIA = { 0x0305, 0x030D, 0x030E, 0x0310 }  -- first four diacritics
local function ref_row(row, cols)
  local out = {}
  for col = 0, cols - 1 do
    -- only valid for row/col < 4 in this reference
    out[#out + 1] = vim.fn.nr2char(0x10EEEE) .. vim.fn.nr2char(DIA[row + 1])
      .. vim.fn.nr2char(DIA[col + 1])
  end
  return table.concat(out)
end
check('grid_bytes_pinned', img.placeholder_row(2, 4), ref_row(2, 4))

-- grid: 100 figures of 60x23.
local GRIDS, COLS, ROWS = 100, 60, 23
local t0 = ns()
local total_rows = 0
for _ = 1, GRIDS do
  for r = 0, ROWS - 1 do
    local row = img.placeholder_row(r, COLS)
    total_rows = total_rows + (row and 1 or 0)
  end
end
local d_grid = ns() - t0
check('grid_rows_built', total_rows, GRIDS * ROWS)

-- transmit: 20 transmissions of a ~300KB pseudo-PNG.
local png = string.rep('\137PNG pixel data \001\002\003\004', 16384)  -- ~300KB
local TX = 20
t0 = ns()
local total_len = 0
for i = 1, TX do
  total_len = total_len + #img.transmission_bytes(i, png, COLS, ROWS, true)
end
local d_tx = ns() - t0
check('tx_nonempty', total_len > TX * #png, true)

-- redraw: one cell holding a figure + text lines streaming under it.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'x = 1' })
render.begin(buf, 1, 1, 1, 200, 'rounded', true, nil)
local pngfile = vim.fn.tempname()
local f = io.open(pngfile, 'wb'); f:write(png); f:close()
local shown = img.show(pngfile, 800, 600, COLS, 2.0)
check('bench_show_ok', shown ~= nil, true)
render.add_image(buf, 1, shown)
local REDRAWS = 200
t0 = ns()
for i = 1, REDRAWS do
  render.add(buf, 1, 'stdout', 'streamed line ' .. i .. '\n')
  render.finish(buf, 1)  -- force synchronous redraw, as bench_render does
end
local d_redraw = ns() - t0
local txt = render.get_range_text(buf, 1, 1)
check('redraw_figure_note', txt[1], '[inline figure]')
check('redraw_text_intact', txt[#txt], 'streamed line ' .. REDRAWS)

print('----------------------------------------')
print(string.format('grid      %d figures x %dx%d rows:  %8.1f ms', GRIDS, COLS, ROWS, ms(d_grid)))
print(string.format('transmit  %d x ~300KB PNG:           %8.1f ms', TX, ms(d_tx)))
print(string.format('redraw    figure + %d streamed:     %8.1f ms', REDRAWS, ms(d_redraw)))
print('----------------------------------------')

img._set_tty_writer(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('BENCH-IMAGE OK')
  vim.cmd('qall!')
end
