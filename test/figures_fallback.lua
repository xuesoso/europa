-- Figure-route fallback at kernel start: when figures='inline' (the default)
-- but the terminal gate refuses, M.start downgrades to the plotty tmux pane
-- when that can actually work (inside tmux + plotty importable), else to the
-- text note. The decision is observable in the hello request: startup_code
-- carries plotty.enable() exactly when downgraded, and inline_images is only
-- true when inline survived.
--   nvim --headless -u NONE -N -l test/figures_fallback.lua
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

-- Stub the bridge BEFORE notebook/init is required: capture what would be
-- sent to the kernel bridge instead of spawning a process.
local sent = {}
package.loaded['vimcmdline.notebook.bridge'] = {
  spawn = function(_, _, _)
    return {
      job = 1,
      send = function(obj)
        sent[#sent + 1] = obj
        return true
      end,
      stop = function() end,
    }
  end,
}

local plotty_installed = true
local health = require('vimcmdline.notebook.health')
health.check = function() return true, nil end
health.has_plotty = function() return plotty_installed end

local image = require('vimcmdline.notebook.image')
image._set_nested(false)

local nb = require('vimcmdline.notebook')

-- Force a non-kitty terminal by default.
vim.env.KITTY_WINDOW_ID = ''
vim.env.GHOSTTY_RESOURCES_DIR = ''
vim.env.GHOSTTY_BIN_DIR = ''
vim.env.TERM = 'xterm-256color'
vim.g.cmdline_notebook_figures = nil

local function start_session()
  sent = {}
  local buf = vim.api.nvim_create_buf(false, true)
  nb.start(buf)
  local hello = sent[1]
  local startup = hello and table.concat(hello.startup_code or {}, '\n') or ''
  return hello, startup
end

-- A. In tmux, non-kitty client, plotty installed: downgrade to the pane.
vim.env.TMUX = '/tmp/tmux-test/default,1,0'
image._set_client_termname('xterm-256color')
plotty_installed = true
local hello, startup = start_session()
check('plotty_fallback_hello_sent', hello ~= nil and hello.type, 'hello')
check('plotty_fallback_no_inline_images', hello and hello.inline_images, false)
check('plotty_fallback_enables_plotty', startup:find('plotty.enable', 1, true) ~= nil, true)

-- B. Same, but plotty is not importable: text fallback (inline startup kept,
--    the bridge just never saves PNGs).
plotty_installed = false
hello, startup = start_session()
check('text_fallback_no_inline_images', hello and hello.inline_images, false)
check('text_fallback_no_plotty', startup:find('plotty.enable', 1, true) ~= nil, false)

-- C. Outside tmux the pane cannot work even with plotty installed.
vim.env.TMUX = ''
image._set_client_termname(nil)
plotty_installed = true
hello, startup = start_session()
check('no_tmux_no_plotty_fallback', startup:find('plotty.enable', 1, true) ~= nil, false)

-- D. Kitty-capable client in tmux: inline survives, no downgrade.
vim.env.TMUX = '/tmp/tmux-test/default,1,0'
image._set_client_termname('xterm-kitty')
hello, startup = start_session()
check('kitty_client_keeps_inline', hello and hello.inline_images, true)
check('kitty_client_no_plotty', startup:find('plotty.enable', 1, true) ~= nil, false)
check('kitty_client_mpl_inline_startup', startup:find('matplotlib', 1, true) ~= nil, true)

image._set_client_termname(nil)
if fail > 0 then
  vim.cmd('cquit!')
else
  print('FIGURES FALLBACK OK')
  vim.cmd('qall!')
end
