-- Prerequisite probing for notebook mode. Used by the toggle to fail fast and
-- by :checkhealth vimcmdline.
local M = {}

-- Cache the (expensive) python import probe per interpreter. Only SUCCESSES
-- are cached: a user who sees "missing Python deps", pip-installs them, and
-- retries must get a fresh probe, not the session-long stale failure.
local _dep_cache = {}

-- Returns ok(bool), errmsg(string|nil). opts.skip_dep_probe skips the
-- synchronous import probe (a ~0.5-1s UI freeze); the kernel bridge reports
-- missing deps itself via a fatal bridge_error, so start paths can skip it
-- while :checkhealth keeps the full check.
function M.check(cfg, opts)
  if vim.fn.has('nvim-0.10') ~= 1 then
    return false, 'notebook mode requires Neovim 0.10+'
  end
  local py = cfg.python
  if vim.fn.executable(py) ~= 1 then
    return false, 'python executable not found: ' .. py
  end
  if opts and opts.skip_dep_probe then
    return true, nil
  end
  if _dep_cache[py] ~= true then
    vim.fn.system({ py, '-c', 'import jupyter_client, ipykernel' })
    if vim.v.shell_error == 0 then
      _dep_cache[py] = true
    else
      return false, 'missing Python deps for "' .. py ..
        '" — install with: pip install jupyter_client ipykernel plotty'
    end
  end
  return true, nil
end

-- Probe plotty importability per interpreter, caching successes only (same
-- rationale as the dep probe above: install-and-retry must re-probe). Used
-- by the inline→plotty figure fallback at kernel start.
local _plotty_cache = {}

function M.has_plotty(cfg)
  local py = cfg.python
  if _plotty_cache[py] ~= true then
    vim.fn.system({ py, '-c', 'import plotty' })
    if vim.v.shell_error ~= 0 then
      return false
    end
    _plotty_cache[py] = true
  end
  return true
end

return M
