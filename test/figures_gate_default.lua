-- Regression: the inline-figure gate must refuse an incapable terminal in the
-- DEFAULT configuration, sourcing the REAL plugin so the globals are in the
-- exact state they are at startup.
--
-- The bug this guards: the plugin used to materialize
-- cmdline_notebook_figures='inline' for every user who did not choose a route,
-- and the gate's "explicit inline overrides detection" escape hatch keyed on
-- that VALUE — so the materialized default looked like a deliberate override,
-- the gate never refused, and WezTerm/iTerm2/… got inline escape garbage
-- instead of the plotty/text fallback. The fix stops materializing the global:
-- it is set ONLY when the user chose a route, so the gate reads it as intent
-- and config.lua supplies the default. Earlier gate tests set the global to
-- 'inline' (mimicking the old materialization) and so could not see the bug.
--   nvim --headless -u NONE -N -l test/figures_gate_default.lua
vim.opt.rtp:prepend('.')
vim.o.termguicolors = true

local fail = 0
local function check(label, got, want)
  if got == want then
    print('PASS ' .. label)
  else
    fail = fail + 1
    print(('FAIL %s got=%s want=%s'):format(label, tostring(got), tostring(want)))
  end
end

local image = require('vimcmdline.notebook.image')
local config = require('vimcmdline.notebook.config')
image._set_nested(false)

-- A non-kitty terminal, outside tmux (env sniff decides), no user overrides.
local function non_kitty_env()
  vim.env.KITTY_WINDOW_ID = ''
  vim.env.GHOSTTY_RESOURCES_DIR = ''
  vim.env.GHOSTTY_BIN_DIR = ''
  vim.env.TERM = 'xterm-256color'   -- e.g. WezTerm's default TERM
  vim.env.TMUX = ''
  image._set_client_termname(nil)
end

-- Re-source the plugin from a clean slate.
local function resource_plugin()
  vim.g.did_cmdline = nil
  vim.cmd('runtime plugin/vimcmdline.vim')
end

-- Case A — DEFAULT install (user set nothing about figures).
vim.g.cmdline_notebook_figures = nil
vim.g.cmdline_notebook_plotty = nil
resource_plugin()
-- The plugin must NOT materialize the global; config.lua supplies the default.
check('default_global_unset', vim.g.cmdline_notebook_figures, nil)
check('default_resolves_inline', config.read().figures, 'inline')

non_kitty_env()
local ok, why = image.supported()
check('default_gate_refuses_non_kitty', ok, false)  -- the bug: was true
check('default_gate_reason_helpful',
  why ~= nil and why:find('kitty', 1, true) ~= nil, true)

-- The escape hatch: an explicit inline choice (the user setting the global)
-- forces inline past detection.
vim.g.cmdline_notebook_figures = 'inline'
check('explicit_inline_forces_gate', (image.supported()), true)

-- Case B — user EXPLICITLY chose inline before the plugin loaded: the plugin
-- leaves their value untouched and the gate honors it.
vim.g.cmdline_notebook_figures = 'inline'
resource_plugin()
check('explicit_user_inline_kept', vim.g.cmdline_notebook_figures, 'inline')
non_kitty_env()
check('explicit_user_inline_forces_gate', (image.supported()), true)

-- Case C — user chose plotty (value not inline): config routes to the pane and
-- the inline gate is never forced.
vim.g.cmdline_notebook_figures = 'plotty'
resource_plugin()
check('explicit_plotty_kept', vim.g.cmdline_notebook_figures, 'plotty')
check('explicit_plotty_resolves_plotty', config.read().figures, 'plotty')
non_kitty_env()
check('explicit_plotty_does_not_force_inline', (image.supported()), false)

-- Case D — LEGACY cmdline_notebook_plotty (set, figures unset) still resolves,
-- for back-compat with pre-figures configs.
vim.g.cmdline_notebook_figures = nil
vim.g.cmdline_notebook_plotty = 1
resource_plugin()
check('legacy_plotty_on_resolves_plotty', config.read().figures, 'plotty')
vim.g.cmdline_notebook_plotty = 0
check('legacy_plotty_off_resolves_none', config.read().figures, 'none')
vim.g.cmdline_notebook_plotty = nil

if fail > 0 then
  vim.cmd('cquit!')
else
  print('FIGURES GATE DEFAULT OK')
  vim.cmd('qall!')
end
