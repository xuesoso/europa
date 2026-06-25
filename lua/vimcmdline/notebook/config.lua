-- Reads g:cmdline_notebook_* options into a plain Lua table and builds the
-- kernel startup code (plotty enable + user startup).
local M = {}

local function gget(name, default)
  local v = vim.g[name]
  if v == nil then
    return default
  end
  return v
end

local function truthy(v)
  return v == true or v == 1
end

function M.read()
  local cfg = {}
  cfg.enable = gget('cmdline_notebook_enable', 0)
  cfg.plotty = truthy(gget('cmdline_notebook_plotty', 1))
  cfg.startup_code = gget('cmdline_notebook_startup_code', {})
  cfg.python = gget('cmdline_notebook_python', '')
  cfg.kernel_name = gget('cmdline_notebook_kernel_name', 'python3')
  cfg.max_lines = gget('cmdline_notebook_max_lines', 20)
  cfg.kernel_timeout = gget('cmdline_notebook_kernel_timeout', 30)
  cfg.border = gget('cmdline_notebook_border', 'rounded')
  cfg.output_win = gget('cmdline_notebook_output_win', 'float')
  cfg.exec_marker = truthy(gget('cmdline_notebook_exec_marker', 1))
  if type(cfg.python) ~= 'string' or cfg.python == '' then
    cfg.python = 'python3'
  end
  return cfg
end

-- Build the list of Python statements to run once at kernel start. plotty is
-- wrapped in try/except so a missing plotty never breaks the session.
function M.build_startup(cfg)
  local startup = {}
  if cfg.plotty then
    table.insert(startup, table.concat({
      'try:',
      '    import plotty as _vcl_plotty',
      '    _vcl_plotty.enable()',
      'except Exception:',
      '    pass',
    }, '\n'))
  end
  local extra = cfg.startup_code
  if type(extra) == 'table' then
    for _, line in ipairs(extra) do
      table.insert(startup, line)
    end
  elseif type(extra) == 'string' and extra ~= '' then
    table.insert(startup, extra)
  end
  return startup
end

return M
