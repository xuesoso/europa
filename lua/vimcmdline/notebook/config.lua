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
  cfg.enable = gget('cmdline_notebook_enable', 1)
  cfg.plotty = truthy(gget('cmdline_notebook_plotty', 1))
  cfg.startup_code = gget('cmdline_notebook_startup_code', {})
  cfg.python = gget('cmdline_notebook_python', '')
  cfg.kernel_name = gget('cmdline_notebook_kernel_name', 'python3')
  cfg.max_lines = tonumber(gget('cmdline_notebook_max_lines', 20)) or 20
  cfg.max_kept = tonumber(gget('cmdline_notebook_max_kept_lines', 10000)) or 10000
  cfg.kernel_timeout = tonumber(gget('cmdline_notebook_kernel_timeout', 30)) or 30
  cfg.border = gget('cmdline_notebook_border', 'rounded')
  cfg.output_win = gget('cmdline_notebook_output_win', 'float')
  cfg.exec_marker = truthy(gget('cmdline_notebook_exec_marker', 1))
  -- Figure routing: 'inline' (kitty graphics in the cell output — the
  -- default), 'plotty' (tmux pane), or 'none'. plugin/vimcmdline.vim resolves
  -- the legacy cmdline_notebook_plotty flag into this option at load time.
  local figures = gget('cmdline_notebook_figures', 'inline')
  if figures ~= 'plotty' and figures ~= 'inline' and figures ~= 'none' then
    figures = 'inline'
  end
  cfg.figures = figures
  cfg.figure_size = tonumber(gget('cmdline_notebook_figure_size', 50)) or 50
  cfg.figure_rows = tonumber(gget('cmdline_notebook_figure_rows', 0)) or 0
  cfg.figure_dpi = tonumber(gget('cmdline_notebook_figure_dpi', 200)) or 200
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
    -- Plotly renders through its own renderer, not matplotlib, and defaults to
    -- an interactive JS mimebundle that never yields a PNG. In a terminal there
    -- is no browser for that, so point the default renderer at the static
    -- 'png' one: fig.show()/last-expr then emit display_data image/png exactly
    -- like the inline mpl backend, reusing the same save+transmit pipeline with
    -- no bridge changes.
    --
    -- Gated on BOTH probes so this never turns a figure into a hard error the
    -- user didn't have before: kaleido does the PNG export, and plotly routes
    -- every renderer through pio.show(), which raises unless nbformat>=4.2 is
    -- importable. If either is missing we leave plotly's renderer untouched and
    -- the figure falls back to the graceful non-text note.
    --
    -- cmdline_notebook_figure_dpi drives the SOURCE resolution of both backends
    -- from one knob: matplotlib's baseline dpi is 100, so figure_dpi=200 renders
    -- it at 2x; mapping plotly's render scale = figure_dpi/100 gives plotly the
    -- same multiplier over its native 700x500 (=> 1400x1000 at the default).
    -- Clamped to a positive floor so a tiny/zero dpi can't request a 0px image.
    -- The scale line runs after the default is set, so if a plotly version lacks
    -- the attribute the renderer still works at its native scale.
    table.insert(startup, table.concat({
      'try:',
      '    import kaleido as _vcl_kaleido  # probe: png export needs kaleido',
      '    import nbformat as _vcl_nbf  # probe: pio.show() needs nbformat>=4.2',
      '    import plotly.io as _vcl_pio',
      "    _vcl_pio.renderers.default = 'png'",
      "    _vcl_pio.renderers['png'].scale = max(" .. cfg.figure_dpi .. " / 100.0, 0.1)",
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
