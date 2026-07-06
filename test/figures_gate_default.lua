-- Regression: the inline-figure gate must refuse an incapable terminal in the
-- DEFAULT configuration, sourcing the REAL plugin so the globals are
-- materialized exactly as they are at startup.
--
-- The bug this guards: plugin/vimcmdline.vim sets
-- cmdline_notebook_figures='inline' for every user who did not choose a route,
-- and the gate's "explicit inline overrides detection" escape hatch keyed on
-- that VALUE — so the materialized default looked like a deliberate override,
-- the gate never refused, and WezTerm/iTerm2/… got inline escape garbage
-- instead of the plotty/text fallback. Earlier gate tests set the global to
-- nil (a state that never exists at runtime) and so missed it entirely.
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

-- Re-source the plugin from a clean slate so it re-materializes its defaults.
local function resource_plugin()
  vim.g.did_cmdline = nil
  vim.cmd('runtime plugin/vimcmdline.vim')
end

-- Case A — DEFAULT install (user set nothing about figures).
vim.g.cmdline_notebook_figures = nil
vim.g.cmdline_notebook_figures_explicit = nil
resource_plugin()
check('default_materializes_inline', vim.g.cmdline_notebook_figures, 'inline')
check('default_explicit_flag_is_0', vim.g.cmdline_notebook_figures_explicit, 0)

non_kitty_env()
local ok, why = image.supported()
check('default_gate_refuses_non_kitty', ok, false)  -- the bug: was true
check('default_gate_reason_helpful',
  why ~= nil and why:find('kitty', 1, true) ~= nil, true)

-- The escape hatch still works end-to-end: flipping the explicit flag (as the
-- plugin would when the user pre-set the option) forces inline past detection.
vim.g.cmdline_notebook_figures_explicit = 1
check('explicit_flag_forces_inline', (image.supported()), true)

-- Case B — user EXPLICITLY chose inline before the plugin loaded.
vim.g.cmdline_notebook_figures = 'inline'
vim.g.cmdline_notebook_figures_explicit = nil
resource_plugin()
check('explicit_user_inline_sets_flag', vim.g.cmdline_notebook_figures_explicit, 1)
non_kitty_env()
check('explicit_user_inline_forces_gate', (image.supported()), true)

-- Case C — user chose plotty: explicit flag set, but value is not inline, so
-- the inline gate is never forced (routing sends figures to the pane instead).
vim.g.cmdline_notebook_figures = 'plotty'
vim.g.cmdline_notebook_figures_explicit = nil
resource_plugin()
check('explicit_plotty_sets_flag', vim.g.cmdline_notebook_figures_explicit, 1)
check('explicit_plotty_keeps_value', vim.g.cmdline_notebook_figures, 'plotty')
non_kitty_env()
check('explicit_plotty_does_not_force_inline', (image.supported()), false)

if fail > 0 then
  vim.cmd('cquit!')
else
  print('FIGURES GATE DEFAULT OK')
  vim.cmd('qall!')
end
