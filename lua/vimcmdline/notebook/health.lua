-- Prerequisite probing for notebook mode. Used by the toggle to fail fast and
-- by :checkhealth vimcmdline.
local M = {}

-- Cache the (expensive) python import probe per interpreter.
local _dep_cache = {}

-- Returns ok(bool), errmsg(string|nil).
function M.check(cfg)
  if vim.fn.has('nvim-0.10') ~= 1 then
    return false, 'notebook mode requires Neovim 0.10+'
  end
  local py = cfg.python
  if vim.fn.executable(py) ~= 1 then
    return false, 'python executable not found: ' .. py
  end
  if _dep_cache[py] == nil then
    vim.fn.system({ py, '-c', 'import jupyter_client, ipykernel' })
    _dep_cache[py] = (vim.v.shell_error == 0)
  end
  if not _dep_cache[py] then
    return false, 'missing Python deps for "' .. py ..
      '" — install with: pip install jupyter_client ipykernel plotty'
  end
  return true, nil
end

function M.has_plotty(cfg)
  vim.fn.system({ cfg.python, '-c', 'import plotty' })
  return vim.v.shell_error == 0
end

return M
