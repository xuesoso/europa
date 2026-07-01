-- Unit tests for the inline-figure kitty encoder (lua/vimcmdline/notebook/
-- image.lua) and its render integration.
--
-- The encoder is a port of plotty's _kitty_bytes; when the plotty source tree
-- is available (PLOTTY_SRC or ~/GitRepositories/plotty/src) the APC stream and
-- placeholder grid are compared BYTE-FOR-BYTE against the Python original.
-- Structural and render-integration checks run regardless.
--
--   nvim --headless -u NONE -N -l test/image_test.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true
local img = require('vimcmdline.notebook.image')
local render = require('vimcmdline.notebook.render')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. '\n  got=' .. vim.inspect(got) .. '\n want=' .. vim.inspect(want))
  end
end

-- A tiny valid 1x1 PNG (the encoder treats content opaquely).
local png = vim.base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==')

-- ---- structural checks ------------------------------------------------

-- tmux passthrough wrapping doubles ESCs and wraps in the envelope.
do
  local plain = img.delete_bytes(7, false)
  local wrapped = img.delete_bytes(7, true)
  check('delete_apc', plain, '\27_Ga=d,d=I,i=7,q=2\27\\')
  check('tmux_wrap', wrapped,
    '\27Ptmux;' .. plain:gsub('\27', '\27\27') .. '\27\\')
end

-- Transmission stream: delete APC, then chunked a=T APC(s) with U=1 virtual
-- placement, id, and geometry.
do
  local bytes = img.transmission_bytes(42, png, 7, 3, false)
  check('tx_starts_with_delete', bytes:sub(1, #'\27_Ga=d,d=I,i=42,q=2\27\\'),
    '\27_Ga=d,d=I,i=42,q=2\27\\')
  check('tx_has_virtual_placement',
    bytes:find('a=T,U=1,q=2,f=100,t=d,i=42,c=7,r=3,m=0', 1, true) ~= nil, true)
  check('tx_payload_roundtrip',
    bytes:match(';([A-Za-z0-9+/=]+)\27\\$') == vim.base64.encode(png), true)
end

-- Placeholder rows: `cols` cells of U+10EEEE + row diacritic + col diacritic,
-- display width == cols, and distinct rows differ only in the row diacritic.
do
  local r0 = img.placeholder_row(0, 5)
  local r1 = img.placeholder_row(1, 5)
  check('row_width', vim.fn.strdisplaywidth(r0), 5)
  check('row_cells', vim.fn.strchars(r0), 15) -- 3 codepoints per cell
  check('rows_differ', r0 ~= r1, true)
  check('row_base_char', vim.fn.strcharpart(r0, 0, 1), vim.fn.nr2char(0x10EEEE))
end

-- fit(): aspect math and clamping.
do
  vim.o.columns = 120
  vim.o.lines = 40
  local c, r = img.fit(800, 600, 60, 2.0)
  check('fit_cols', c, 60)
  check('fit_rows', r, 23) -- 60 * (600/800) / 2 = 22.5 -> 23
  local c2 = img.fit(800, 600, 999, 2.0)
  check('fit_caps_cols', c2 <= 120 - 6, true)
end

-- Highlight group encodes the id in the RGB foreground.
do
  local group = img.hl_for_id(0x00ABCD)
  local hl = vim.api.nvim_get_hl(0, { name = group })
  check('hl_fg_is_id', hl.fg, 0x00ABCD)
end

-- Nested tmux: supported() must refuse (blank-figure prevention) and show()
-- must fail with the reason, so the caller renders a text note instead.
do
  img._set_nested(true)
  local sup, why = img.supported()
  check('nested_unsupported', sup, false)
  check('nested_reason', why and why:find('nested tmux', 1, true) ~= nil, true)
  local shown, serr = img.show('/nonexistent.png', 100, 100, 10, 2.0)
  check('nested_show_fails', shown, nil)
  check('nested_show_reason', serr and serr:find('nested tmux', 1, true) ~= nil, true)
  img._set_nested(false)
  check('unnested_supported', (img.supported()), true)
end

-- ---- golden comparison against plotty's Python encoder -----------------

local plotty_src = vim.env.PLOTTY_SRC or (vim.env.HOME .. '/GitRepositories/plotty/src')
if vim.fn.filereadable(plotty_src .. '/plotty.py') == 1 and vim.fn.executable('python3') == 1 then
  local pngfile = vim.fn.tempname()
  local f = io.open(pngfile, 'wb'); f:write(png); f:close()
  local py = table.concat({
    'import sys, os',
    'sys.path.insert(0, ' .. string.format('%q', plotty_src) .. ')',
    'import plotty',
    'plotty._kitty_id = lambda: 42',
    'png = open(' .. string.format('%q', pngfile) .. ', "rb").read()',
    'sys.stdout.buffer.write(plotty._kitty_bytes(png, 7, 3, wrap=True))',
  }, '\n')
  local golden = vim.fn.system({ 'python3', '-c', py })
  if vim.v.shell_error == 0 and #golden > 0 then
    -- plotty's stream = [wrapped APCs][SGR fg id][grid rows \r\n][SGR reset].
    local sgr = '\27[38;5;42m'
    local cut = golden:find(sgr, 1, true)
    check('golden_found_sgr', cut ~= nil, true)
    if cut then
      local ours = img.transmission_bytes(42, png, 7, 3, true)
      check('golden_apc_stream', ours, golden:sub(1, cut - 1))
      local gridpart = golden:sub(cut + #sgr):gsub('\27%[39m\r\n$', '')
      local rows = vim.split(gridpart, '\r\n', { plain = true })
      check('golden_row_count', #rows, 3)
      for i = 1, 3 do
        check('golden_row_' .. i, img.placeholder_row(i - 1, 7), rows[i])
      end
    end
  else
    print('SKIP golden: plotty not importable by python3')
  end
  os.remove(pngfile)
else
  print('SKIP golden: plotty source not found at ' .. plotty_src)
end

-- ---- render integration (stubbed tty) ----------------------------------

do
  local writes = {}
  img._set_tty_writer(function(bytes)
    writes[#writes + 1] = bytes
    return true
  end)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# %%', 'plot()' })

  -- Save a PNG "from the bridge" and show it through the real code path.
  local pngfile = vim.fn.tempname()
  local f = io.open(pngfile, 'wb'); f:write(png); f:close()

  render.begin(buf, 1, 2, 2, 20, 'rounded', true, nil)
  render.add(buf, 1, 'stdout', 'before figure\n')
  local shown = img.show(pngfile, 400, 300, 10, 2.0)
  check('show_returns_img', shown ~= nil, true)
  check('show_removed_tmpfile', vim.fn.filereadable(pngfile), 0)
  check('show_transmitted', #writes >= 1, true)
  render.add_image(buf, 1, shown)
  render.mark_done(buf, 1, 1, 'ok')

  -- Rendered virt_lines: border + text + placeholder rows with the image hl.
  local marks = vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })
  check('mark_exists', #marks, 1)
  local vl = marks[1][4].virt_lines
  local text_found, img_rows = false, 0
  for _, line in ipairs(vl) do
    for _, chunk in ipairs(line) do
      if chunk[1]:find('before figure', 1, true) then
        text_found = true
      end
      if chunk[2] == shown.hl then
        img_rows = img_rows + 1
      end
    end
  end
  check('virt_has_text', text_found, true)
  check('virt_img_rows', img_rows, #shown.rows)

  -- OpenOutput text substitutes a single figure note.
  local txt = render.get_range_text(buf, 2, 2)
  local note = 0
  for _, l in ipairs(txt) do
    if l == '[inline figure]' then note = note + 1 end
  end
  check('open_output_note_once', note, 1)

  -- Clearing the cell frees the terminal-side placement (a delete APC).
  local before = #writes
  render.clear_all(buf)
  check('clear_frees_image', #writes > before, true)
  check('delete_apc_sent',
    writes[#writes]:find(string.format('i=%d', shown.id), 1, true) ~= nil, true)

  img._set_tty_writer(nil)
end

if fail > 0 then
  vim.cmd('cquit!')
else
  print('IMAGE OK')
  vim.cmd('qall!')
end
