-- Inline figure rendering via the kitty graphics protocol, ported from
-- plotty's built-in kitty encoder (github.com/xuesoso/plotty, src/plotty.py).
--
-- The PNG is transmitted to the terminal once as a *virtual* placement
-- (kitty APC `a=T,U=1`), then drawn as ordinary Unicode placeholder text:
-- U+10EEEE cells carrying row/column diacritics, with the image id encoded in
-- the cells' foreground color. Because the placeholders are plain text, they
-- can live inside extmark virt_lines — the terminal composes the image
-- wherever Neovim happens to draw those cells, and the image survives
-- scrolling, redraws and (with `set -g allow-passthrough on`) tmux.
--
-- Differences from plotty: plotty shows ONE figure per process (id = pid) and
-- prints the placeholder grid straight to the tty; here every figure gets its
-- own id (24-bit, random base + counter — requires 'termguicolors' so the id
-- rides the RGB foreground color) and the grid is returned as virt_lines rows
-- for render.lua to place inside the cell's output border.
--
-- Requires a kitty-graphics terminal (kitty, ghostty). Inside tmux the
-- transmission APCs are passthrough-wrapped (tmux >= 3.3 with
-- `allow-passthrough on`); the placeholder text needs no wrapping.
local M = {}

local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

-- kitty's rowcolumn-diacritics table (verbatim from plotty / the kitty spec).
local DIACRITICS = {
  0x0305, 0x030D, 0x030E, 0x0310, 0x0312, 0x033D, 0x033E, 0x033F, 0x0346,
  0x034A, 0x034B, 0x034C, 0x0350, 0x0351, 0x0352, 0x0357, 0x035B, 0x0363,
  0x0364, 0x0365, 0x0366, 0x0367, 0x0368, 0x0369, 0x036A, 0x036B, 0x036C,
  0x036D, 0x036E, 0x036F, 0x0483, 0x0484, 0x0485, 0x0486, 0x0487, 0x0592,
  0x0593, 0x0594, 0x0595, 0x0597, 0x0598, 0x0599, 0x059C, 0x059D, 0x059E,
  0x059F, 0x05A0, 0x05A1, 0x05A8, 0x05A9, 0x05AB, 0x05AC, 0x05AF, 0x05C4,
  0x0610, 0x0611, 0x0612, 0x0613, 0x0614, 0x0615, 0x0616, 0x0617, 0x0657,
  0x0658, 0x0659, 0x065A, 0x065B, 0x065D, 0x065E, 0x06D6, 0x06D7, 0x06D8,
  0x06D9, 0x06DA, 0x06DB, 0x06DC, 0x06DF, 0x06E0, 0x06E1, 0x06E2, 0x06E4,
  0x06E7, 0x06E8, 0x06EB, 0x06EC, 0x0730, 0x0732, 0x0733, 0x0735, 0x0736,
  0x073A, 0x073D, 0x073F, 0x0740, 0x0741, 0x0743, 0x0745, 0x0747, 0x0749,
  0x074A, 0x07EB, 0x07EC, 0x07ED, 0x07EE, 0x07EF, 0x07F0, 0x07F1, 0x07F3,
  0x0816, 0x0817, 0x0818, 0x0819, 0x081B, 0x081C, 0x081D, 0x081E, 0x081F,
  0x0820, 0x0821, 0x0822, 0x0823, 0x0825, 0x0826, 0x0827, 0x0829, 0x082A,
  0x082B, 0x082C, 0x082D, 0x0951, 0x0953, 0x0954, 0x0F82, 0x0F83, 0x0F86,
  0x0F87, 0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
  0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D, 0x1B6E,
  0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1, 0x1CD2, 0x1CDA,
  0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4, 0x1DC5, 0x1DC6, 0x1DC7,
  0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1, 0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5,
  0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9, 0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE,
  0x1DDF, 0x1DE0, 0x1DE1, 0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE,
  0x20D0, 0x20D1, 0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1,
  0x20E7, 0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
  0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA, 0x2DEB,
  0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2, 0x2DF3, 0x2DF4,
  0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA, 0x2DFB, 0x2DFC, 0x2DFD,
  0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D, 0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1,
  0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5, 0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA,
  0xA8EB, 0xA8EC, 0xA8ED, 0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2,
  0xAAB3, 0xAAB7, 0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22,
  0xFE23, 0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186,
  0x1D187, 0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242,
  0x1D243, 0x1D244,
}
M.MAX_CELLS = #DIACRITICS  -- placeholder addressing limit per axis

-- 24-bit image ids from a random per-session base so concurrent sessions (and
-- plotty's own pid-based 8-bit ids) do not collide. Wraps within 24 bits and
-- never allocates 0.
math.randomseed(vim.loop.hrtime() % 2 ^ 31)
local id_counter = math.random(0, 0xFFFF) * 256
local function next_id()
  id_counter = (id_counter + 1) % 0x1000000
  if id_counter == 0 then
    id_counter = 1
  end
  return id_counter
end

-- Writable handle to the terminal. Overridable for tests (M._set_tty_writer).
--
-- Primary path: nvim_chan_send(v:stderr) — the TUI's stderr IS the terminal,
-- writes bypass Neovim's renderer, and it works even though Lua may run in a
-- server process with no controlling terminal (where open("/dev/tty") fails
-- with ENXIO — the bug this replaced). /dev/tty is kept as a fallback.
-- Returns ok, errmsg.
local tty_writer = nil
local function write_tty(bytes)
  if tty_writer then
    return tty_writer(bytes)
  end
  local ok = pcall(vim.api.nvim_chan_send, vim.v.stderr, bytes)
  if ok then
    return true
  end
  local fd, oerr = vim.loop.fs_open('/dev/tty', 'w', 438)
  if not fd then
    return false, 'cannot reach terminal (v:stderr channel failed; /dev/tty: '
      .. tostring(oerr) .. ')'
  end
  vim.loop.fs_write(fd, bytes, -1)
  vim.loop.fs_close(fd)
  return true
end

function M._set_tty_writer(fn)
  tty_writer = fn
end

-- tmux passthrough envelope: ESCs doubled inside \ePtmux; ... \e\\ (plotty's
-- _wrap_tmux). Only the APCs are wrapped, never the placeholder text.
local function wrap_tmux(seq)
  return '\27Ptmux;' .. seq:gsub('\27', '\27\27') .. '\27\\'
end

-- Standard base64 (same as Python's base64.standard_b64encode, which plotty
-- uses). vim.base64 is core since Neovim 0.10, which supported() requires.
local function b64encode(data)
  return vim.base64.encode(data)
end

-- Kitty-graphics APC stream for transmitting `png` as a virtual placement of
-- cols x rows cells under image id `iid` (plotty's _kitty_bytes, minus the
-- placeholder grid — that goes into virt_lines instead of the tty).
function M.transmission_bytes(iid, png, cols, rows, wrap)
  local apcs = { string.format('\27_Ga=d,d=I,i=%d,q=2\27\\', iid) }
  local payload = b64encode(png)
  local head = string.format('a=T,U=1,q=2,f=100,t=d,i=%d,c=%d,r=%d', iid, cols, rows)
  local n = math.max(math.ceil(#payload / 4096), 1)
  for k = 1, n do
    local chunk = payload:sub((k - 1) * 4096 + 1, k * 4096)
    local more = k < n and 1 or 0
    local keys = (k == 1) and (head .. ',m=' .. more) or ('m=' .. more)
    apcs[#apcs + 1] = '\27_G' .. keys .. ';' .. chunk .. '\27\\'
  end
  local out = {}
  for _, apc in ipairs(apcs) do
    out[#out + 1] = wrap and wrap_tmux(apc) or apc
  end
  return table.concat(out)
end

-- APC that frees a transmitted image in the terminal.
function M.delete_bytes(iid, wrap)
  local apc = string.format('\27_Ga=d,d=I,i=%d,q=2\27\\', iid)
  return wrap and wrap_tmux(apc) or apc
end

-- Diacritic codepoints pre-encoded to UTF-8 once at load (nr2char is a
-- vim.fn crossing; a 60x23 grid would otherwise make ~2800 of them).
local DIA_CHARS = {}
for i, cp in ipairs(DIACRITICS) do
  DIA_CHARS[i] = vim.fn.nr2char(cp)
end

-- One row of the Unicode placeholder grid: `cols` cells of
-- PLACEHOLDER + diacritic(row) + diacritic(col). Plain text; the image id is
-- conveyed by the row's highlight group foreground color. Rows depend only on
-- (row, cols), which recur across figures of the same width — memoised.
local row_cache = {}

function M.placeholder_row(row, cols)
  local key = row * 1024 + cols
  local hit = row_cache[key]
  if hit then
    return hit
  end
  local rd = DIA_CHARS[row + 1]
  local parts = {}
  for col = 1, cols do
    parts[col] = PLACEHOLDER .. rd .. DIA_CHARS[col]
  end
  local text = table.concat(parts)
  row_cache[key] = text
  return text
end

-- Highlight group whose RGB foreground encodes the image id (how kitty knows
-- which image a placeholder cell belongs to when 'termguicolors' is set).
function M.hl_for_id(iid)
  local group = string.format('CmdlineNotebookImg_%06X', iid)
  vim.api.nvim_set_hl(0, group, { fg = string.format('#%06x', iid) })
  return group
end

-- Fit an image of iw x ih pixels into `want_cols` columns (terminal-capped),
-- assuming a cell is `cell_aspect` times taller than wide. A positive
-- `want_rows` overrides the aspect-derived height (the terminal scales the
-- image into the cols x rows box, so an explicit height may distort).
-- `max_rows` optionally tightens the height budget below the screen-derived
-- cap (e.g. to the height of the window the figure must fit inside); when the
-- aspect-derived height exceeds it, the width is scaled down to preserve the
-- aspect. Returns cols, rows.
function M.fit(iw, ih, want_cols, cell_aspect, want_rows, max_rows)
  local max_cols = math.min(math.max((vim.o.columns or 80) - 6, 4), M.MAX_CELLS)
  local cap_rows = math.min(math.max((vim.o.lines or 24) - 2, 1), M.MAX_CELLS)
  if max_rows and max_rows > 0 then
    cap_rows = math.max(1, math.min(cap_rows, max_rows))
  end
  local cols = math.max(1, math.min(want_cols, max_cols))
  if want_rows and want_rows > 0 then
    return cols, math.max(1, math.min(want_rows, cap_rows))
  end
  local rows = math.max(1, math.floor(cols * (ih / iw) / cell_aspect + 0.5))
  if rows > cap_rows then
    cols = math.max(1, math.floor(cols * cap_rows / rows + 0.5))
    rows = cap_rows
  end
  return cols, rows
end

-- Nested-tmux detection: the passthrough envelope survives exactly ONE tmux
-- hop — the inner tmux unwraps it and the outer tmux then discards the bare
-- APC, so the placeholder grid would render as a blank rectangle. From inside
-- the inner session, `#{client_termname}` is the terminal the inner tmux is
-- attached to: a tmux/screen TERM there means that client is itself a
-- multiplexer. Cached per session; overridable for tests.
local nested_cache = nil

function M._set_nested(v)
  nested_cache = v
end

function M.in_nested_tmux()
  -- Cache first: it doubles as the test override, which must win even when
  -- TMUX is unset (CI runs outside tmux).
  if nested_cache ~= nil then
    return nested_cache
  end
  if (vim.env.TMUX or '') == '' then
    return false
  end
  local out = vim.fn.system({ 'tmux', 'display-message', '-p', '#{client_termname}' })
  nested_cache = vim.v.shell_error == 0
    and (out:match('^tmux') ~= nil or out:match('^screen') ~= nil)
    or false
  return nested_cache
end

-- Capability gate for inline figures. Placeholders need the id in the RGB
-- foreground, hence 'termguicolors'. The terminal itself must speak the kitty
-- graphics protocol (kitty/ghostty) — not probeable without a tty round-trip,
-- so that part is the user's opt-in via cmdline_notebook_figures='inline'.
function M.supported()
  if vim.fn.has('nvim-0.10') ~= 1 then
    return false, 'inline figures need Neovim 0.10+'
  end
  if not vim.o.termguicolors then
    return false, 'inline figures need :set termguicolors'
  end
  if M.in_nested_tmux() then
    return false, 'inline figures cannot pass through nested tmux'
        .. " (use cmdline_notebook_figures='plotty')"
  end
  return true, nil
end

-- Show `png_path` inline: allocate an id, transmit to the terminal, delete the
-- temp PNG, and return {id=..., rows={row_text...}, cols=..., hl=..., png=...,
-- iw=..., ih=...} for render.lua to place as virt_lines, or nil, errmsg. The
-- PNG bytes are kept on the handle so the figure can be re-transmitted at a
-- different size later (live resize).
function M.show(png_path, iw, ih, want_cols, cell_aspect, want_rows)
  local ok, err = M.supported()
  if not ok then
    return nil, err
  end
  local f = io.open(png_path, 'rb')
  if not f then
    return nil, 'cannot read figure: ' .. png_path
  end
  local png = f:read('*a')
  f:close()
  os.remove(png_path)  -- transmitted from memory; the temp file is done
  return M.place(png, iw, ih, want_cols, cell_aspect, want_rows)
end

-- Transmit PNG bytes as a fresh placement (new id) of want_cols columns and
-- return the placeholder handle. Used by show() for the inline placement and
-- by the output popup for its independent, larger placement of the same
-- figure (a placement's geometry is fixed at transmission, so the popup must
-- NOT reuse the inline id — resizing it would corrupt the inline copy).
function M.place(png, iw, ih, want_cols, cell_aspect, want_rows, max_rows)
  local ok, err = M.supported()
  if not ok then
    return nil, err
  end
  local cols, rows = M.fit(iw, ih, want_cols, cell_aspect, want_rows, max_rows)
  local iid = next_id()
  local wrap = (vim.env.TMUX or '') ~= ''
  local sent, serr = write_tty(M.transmission_bytes(iid, png, cols, rows, wrap))
  if not sent then
    return nil, serr or 'cannot write to the terminal'
  end
  local grid = {}
  for r = 0, rows - 1 do
    grid[#grid + 1] = M.placeholder_row(r, cols)
  end
  return { id = iid, rows = grid, cols = cols, hl = M.hl_for_id(iid),
           png = png, iw = iw, ih = ih }
end

-- Re-transmit an already-shown figure at a new size, reusing its image id
-- (the transmission stream starts with a delete APC for that id, so the
-- terminal replaces the placement). Mutates img.rows/cols in place; returns
-- true when the geometry changed.
function M.resize(img, want_cols, cell_aspect, want_rows)
  if not (img and img.png) then
    return false
  end
  local cols, rows = M.fit(img.iw, img.ih, want_cols, cell_aspect, want_rows)
  if cols == img.cols and rows == #img.rows then
    return false
  end
  local wrap = (vim.env.TMUX or '') ~= ''
  if not write_tty(M.transmission_bytes(img.id, img.png, cols, rows, wrap)) then
    return false
  end
  local grid = {}
  for r = 0, rows - 1 do
    grid[#grid + 1] = M.placeholder_row(r, cols)
  end
  img.rows = grid
  img.cols = cols
  return true
end

-- Re-transmit an already-shown figure at its CURRENT geometry: restores a
-- placement the terminal evicted to stay within its graphics quota (kitty
-- deletes oldest images past ~320MB, leaving the placeholder grid blank).
-- The PNG bytes are retained on the handle, so nothing is recomputed.
function M.retransmit(img)
  if not (img and img.png) then
    return false
  end
  local wrap = (vim.env.TMUX or '') ~= ''
  local ok = write_tty(M.transmission_bytes(img.id, img.png, img.cols, #img.rows, wrap))
  return ok == true
end

-- Free a transmitted image in the terminal (cell cleared / re-run / wiped).
function M.free(iid)
  if not iid then
    return
  end
  local wrap = (vim.env.TMUX or '') ~= ''
  pcall(write_tty, M.delete_bytes(iid, wrap))
end

return M
