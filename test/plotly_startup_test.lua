-- Startup-code contract test for figure backends (config.build_startup).
--
-- Inline figure mode must arrange for BOTH matplotlib AND plotly figures to
-- arrive as display_data image/png so they flow through the one save+transmit
-- pipeline. matplotlib gets there via `%matplotlib inline`; plotly gets there
-- by pointing its default renderer at the static 'png' one (gated on kaleido).
-- This test pins that contract, guards against a matplotlib regression, and
-- confirms the emitted snippets are valid Python. No kernel/deps required.
--
--   nvim --headless -u NONE -N -l test/plotly_startup_test.lua
vim.opt.rtp:prepend('.')

local config = require('vimcmdline.notebook.config')

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print('FAIL ' .. label .. ' got=' .. vim.inspect(got) .. ' want=' .. vim.inspect(want))
  end
end

local function join(cfg)
  return table.concat(config.build_startup(cfg), '\n')
end

local function has(hay, needle)
  return hay:find(needle, 1, true) ~= nil
end

-- Base cfg fields build_startup reads: figures, figure_dpi, startup_code.
local function cfg_for(figures, extra)
  return { figures = figures, figure_dpi = 200, startup_code = extra or {} }
end

-- inline: matplotlib inline backend (regression) + plotly png renderer (new).
local inline = join(cfg_for('inline'))
check('inline_has_mpl_magic', has(inline, "run_line_magic('matplotlib', 'inline')"), true)
check('inline_has_mpl_dpi', has(inline, "rcParams['figure.dpi'] = 200"), true)
check('inline_has_plotly_kaleido_probe', has(inline, 'import kaleido'), true)
-- pio.show() raises without nbformat even under the png renderer, so the probe
-- must gate on it too — else a minimal env gains a fig.show() error it lacked.
check('inline_has_plotly_nbformat_probe', has(inline, 'import nbformat'), true)
check('inline_has_plotly_renderer', has(inline, "_vcl_pio.renderers.default = 'png'"), true)
-- One knob: cmdline_notebook_figure_dpi drives plotly's render scale too, as
-- figure_dpi/100 (matplotlib's baseline dpi) with a positive floor.
check('inline_has_plotly_scale', has(inline, "renderers['png'].scale = max(200 / 100.0, 0.1)"), true)
local inline300 = join({ figures = 'inline', figure_dpi = 300, startup_code = {} })
check('inline_plotly_scale_tracks_dpi', has(inline300, "renderers['png'].scale = max(300 / 100.0, 0.1)"), true)
-- The plotly probe must be its own try/except so a matplotlib failure (or a
-- missing kaleido) can't skip the other backend's setup.
local _, mpl_trys = inline:gsub('\ntry:', '')
local _, all_trys = ('\n' .. inline):gsub('\ntry:', '')
check('inline_two_independent_try_blocks', all_trys >= 2, true)

-- plotty: routes figures to a tmux pane; must NOT touch the plotly renderer or
-- the matplotlib inline backend.
local plotty = join(cfg_for('plotty'))
check('plotty_has_enable', has(plotty, '_vcl_plotty.enable()'), true)
check('plotty_no_plotly_renderer', has(plotty, 'renderers.default'), false)
check('plotty_no_mpl_inline', has(plotty, "run_line_magic('matplotlib'"), false)

-- none: no figure plumbing at all for either backend.
local none = join(cfg_for('none'))
check('none_no_plotly_renderer', has(none, 'renderers.default'), false)
check('none_no_mpl_inline', has(none, "run_line_magic('matplotlib'"), false)

-- User startup_code is appended after the figure setup, in order.
local withuser = join(cfg_for('inline', { 'import os', 'X = 1' }))
check('user_startup_appended', has(withuser, 'import os') and has(withuser, 'X = 1'), true)
check('user_startup_after_figures',
  withuser:find('import os', 1, true) > withuser:find("renderers.default", 1, true), true)

-- Every emitted snippet must be syntactically valid Python (compile only, no
-- imports executed) so a bad edit to the startup strings is caught here.
local py = vim.env.BENCH_PYTHON or 'python3'
if vim.fn.executable(py) == 1 then
  for _, mode in ipairs({ 'inline', 'plotty', 'none' }) do
    local snippets = config.build_startup(cfg_for(mode, { 'import os' }))
    local src = table.concat(snippets, '\n\n')
    local tmp = vim.fn.tempname() .. '.py'
    vim.fn.writefile(vim.split(src, '\n', { plain = true }), tmp)
    vim.fn.system({ py, '-c', 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")', tmp })
    check('python_compiles_' .. mode, vim.v.shell_error, 0)
    vim.fn.delete(tmp)
  end
else
  print('SKIP python compile check: ' .. py .. ' not executable')
end

if fail > 0 then
  vim.cmd('cquit!')
else
  print('PLOTLY-STARTUP OK')
  vim.cmd('qall!')
end
