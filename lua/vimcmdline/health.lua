-- :checkhealth vimcmdline — reports notebook-mode prerequisites.
local M = {}

function M.check()
  local h = vim.health
  local start = h.start or h.report_start
  local ok = h.ok or h.report_ok
  local warn = h.warn or h.report_warn
  local info = h.info or h.report_info

  start('vimcmdline notebook mode')

  if vim.fn.has('nvim-0.10') ~= 1 then
    warn('Neovim 0.10+ recommended (virt_lines invalidate is used).')
  else
    ok('Neovim ' .. tostring(vim.version()))
  end

  local cfg = require('vimcmdline.notebook.config').read()
  info('python executable: ' .. cfg.python)
  if vim.fn.executable(cfg.python) ~= 1 then
    warn('python executable not found: ' .. cfg.python)
    return
  end

  vim.fn.system({ cfg.python, '-c', 'import jupyter_client, ipykernel' })
  if vim.v.shell_error == 0 then
    ok('jupyter_client + ipykernel available')
  else
    warn('missing kernel deps — install: pip install jupyter_client ipykernel')
  end

  vim.fn.system({ cfg.python, '-c', 'import plotty' })
  if vim.v.shell_error == 0 then
    ok('plotty available (figures render in plotty pane)')
  else
    info('plotty not installed (images disabled) — install: pip install plotty')
  end

  if vim.env.TMUX and vim.env.TMUX ~= '' then
    ok('inside tmux (plotty image pane supported)')
  else
    info('not inside tmux; plotty images need tmux + a sixel/kitty terminal')
  end

  start('inline figures (cmdline_notebook_figures = "inline")')
  local image = require('vimcmdline.notebook.image')
  local sup, why = image.supported()
  if sup then
    ok('inline figure prerequisites met (terminal detected as kitty-graphics capable)')
  else
    warn(why .. ' — figures fall back to the plotty pane (in tmux, with plotty'
      .. ' installed) or a text note')
  end
  if vim.env.TMUX and vim.env.TMUX ~= '' and not image.in_nested_tmux() then
    local pt = vim.fn.system({ 'tmux', 'show', '-g', 'allow-passthrough' })
    if pt:find('on') then
      ok('tmux allow-passthrough is on')
    else
      warn('tmux allow-passthrough is off — run: tmux set -g allow-passthrough on')
    end
  end
end

return M
