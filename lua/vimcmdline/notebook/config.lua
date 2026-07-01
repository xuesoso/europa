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
  -- Figure routing: 'plotty' (tmux pane, the default), 'inline' (kitty
  -- graphics in the cell output), or 'none'. When unset, derive from the
  -- legacy cmdline_notebook_plotty flag so existing configs keep working.
  local figures = gget('cmdline_notebook_figures', '')
  if figures ~= 'plotty' and figures ~= 'inline' and figures ~= 'none' then
    figures = cfg.plotty and 'plotty' or 'none'
  end
  cfg.figures = figures
  cfg.figure_size = tonumber(gget('cmdline_notebook_figure_size', 60)) or 60
  cfg.figure_rows = tonumber(gget('cmdline_notebook_figure_rows', 0)) or 0
  cfg.figure_dpi = tonumber(gget('cmdline_notebook_figure_dpi', 100)) or 100
  cfg.figure_cell_aspect = tonumber(gget('cmdline_notebook_figure_cell_aspect', 2.0)) or 2.0
  cfg.tmp_dir = gget('cmdline_tmp_dir', '/tmp')
  if type(cfg.python) ~= 'string' or cfg.python == '' then
    cfg.python = 'python3'
  end
  return cfg
end

-- Build the list of Python statements to run once at kernel start. plotty is
-- wrapped in try/except so a missing plotty never breaks the session.
function M.build_startup(cfg)
  local startup = {}
  if cfg.figures == 'plotty' then
    table.insert(startup, table.concat({
      'try:',
      '    import plotty as _vcl_plotty',
      '    _vcl_plotty.enable()',
      'except Exception:',
      '    pass',
    }, '\n'))
  elseif cfg.figures == 'inline' then
    -- The matplotlib_inline backend (ships with ipykernel) makes figures
    -- arrive as display_data image/png; the bridge saves them and the Lua
    -- side draws them in the cell output. dpi is set after the magic since
    -- the inline backend applies its own rc overrides on activation.
    table.insert(startup, table.concat({
      'try:',
      '    from IPython import get_ipython as _vcl_gi',
      '    _vcl_ip = _vcl_gi()',
      '    if _vcl_ip is not None:',
      "        _vcl_ip.run_line_magic('matplotlib', 'inline')",
      '    import matplotlib as _vcl_mpl',
      "    _vcl_mpl.rcParams['figure.dpi'] = " .. cfg.figure_dpi,
      "    _vcl_mpl.rcParams['savefig.dpi'] = " .. cfg.figure_dpi,
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
