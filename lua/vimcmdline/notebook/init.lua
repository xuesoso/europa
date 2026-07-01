-- europa notebook mode: public API + per-buffer kernel state.
-- Maintainer: xuesoso. Part of europa (a fork of vimcmdline). GPL-2.0-or-later.
local config = require('vimcmdline.notebook.config')
local health = require('vimcmdline.notebook.health')
local bridge = require('vimcmdline.notebook.bridge')
local render = require('vimcmdline.notebook.render')
local image = require('vimcmdline.notebook.image')

local M = {}

-- bufnr -> { handle, ready, queue, cell_seq, cfg }
local buffers = {}

local function notify(msg, level)
  vim.notify('europa: ' .. msg, level or vim.log.levels.INFO)
end

-- Resolve nil/0 ("current buffer") to a concrete buffer number so the same
-- buffer is always used as the state key.
local function resolve(bufnr)
  if not bufnr or bufnr == 0 then
    return vim.api.nvim_get_current_buf()
  end
  return bufnr
end

local function set_flag(bufnr, value)
  pcall(vim.api.nvim_buf_set_var, bufnr, 'cmdline_notebook', value)
end

function M.is_active(bufnr)
  bufnr = resolve(bufnr)
  local b = buffers[bufnr]
  return b ~= nil and b.handle ~= nil
end

-- 'off' | 'starting' | 'ready' | 'busy', for the statusline.
function M.status(bufnr)
  local b = buffers[resolve(bufnr)]
  if not b or not b.handle then
    return 'off'
  end
  if not b.ready then
    return 'starting'
  end
  if b.busy_visible and b.pending > 0 then
    return 'busy'
  end
  return 'ready'
end

-- Number of cells in flight (the one running plus any queued at the kernel).
function M.pending(bufnr)
  local b = buffers[resolve(bufnr)]
  return b and b.pending or 0
end

-- Coalesce statusline redraws: a run-all burst delivers many replies in one
-- event-loop tick and each used to trigger its own :redrawstatus!; one redraw
-- after the tick shows the same final state.
local status_dirty = false

local function refresh_status()
  if status_dirty then
    return
  end
  status_dirty = true
  vim.schedule(function()
    status_dirty = false
    pcall(vim.cmd, 'redrawstatus!')
  end)
end

-- Track the busy state with a short debounce so cells that finish quickly do
-- not flicker the statusline busy/idle.
local function note_busy_change(bufnr)
  local b = buffers[bufnr]
  if not b then
    return
  end
  if b.pending > 0 then
    if b.busy_visible then
      refresh_status() -- still busy, queue count changed
    elseif not b.busy_timer then
      b.busy_timer = true
      vim.defer_fn(function()
        local bb = buffers[bufnr]
        if bb then
          bb.busy_timer = false
          if bb.pending > 0 then
            bb.busy_visible = true
            refresh_status()
          end
        end
      end, 150)
    end
  elseif b.busy_visible then
    b.busy_visible = false
    refresh_status()
  end
end

local function setup_autocmds(bufnr)
  local grp = vim.api.nvim_create_augroup('vimcmdline_notebook_' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = grp,
    buffer = bufnr,
    callback = function() M.stop(bufnr) end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = grp,
    callback = function() M.stop(bufnr) end,
  })
end

function M.start(bufnr)
  bufnr = resolve(bufnr)
  if buffers[bufnr] and buffers[bufnr].handle then
    return true
  end
  local cfg = config.read()
  local ok, err = health.check(cfg)
  if not ok then
    notify(err, vim.log.levels.WARN)
    set_flag(bufnr, 0)
    return false
  end
  local b = { ready = false, queue = {}, cell_seq = 0, cfg = cfg,
              pending = 0, busy_visible = false, busy_timer = false,
              complete_seq = 0, completions = {} }
  buffers[bufnr] = b
  local handle, serr = bridge.spawn(
    cfg.python,
    function(ev) M._on_event(bufnr, ev) end,
    function(code) M._on_exit(bufnr, code) end
  )
  if not handle then
    notify(serr or 'failed to start kernel bridge', vim.log.levels.ERROR)
    buffers[bufnr] = nil
    set_flag(bufnr, 0)
    return false
  end
  b.handle = handle
  local inline_ok = cfg.figures == 'inline' and image.supported() or false
  if cfg.figures == 'inline' and not inline_ok then
    local _, why = image.supported()
    notify((why or 'inline figures unavailable') .. ' — falling back to text', vim.log.levels.WARN)
  end
  handle.send({
    type = 'hello',
    startup_code = config.build_startup(cfg),
    kernel_name = cfg.kernel_name,
    timeout = cfg.kernel_timeout,
    inline_images = inline_ok,
    image_dir = cfg.tmp_dir,
  })
  notify('starting Python kernel…')
  setup_autocmds(bufnr)
  refresh_status()
  return true
end

function M.stop(bufnr)
  bufnr = resolve(bufnr)
  local b = buffers[bufnr]
  buffers[bufnr] = nil
  if b and b.handle then
    pcall(b.handle.send, { type = 'shutdown' })
    local handle = b.handle
    vim.defer_fn(function() handle.stop() end, 300)
  end
  render.clear_all(bufnr)
  set_flag(bufnr, 0)
  pcall(vim.api.nvim_del_augroup_by_name, 'vimcmdline_notebook_' .. bufnr)
  refresh_status()
end

function M.restart(bufnr)
  bufnr = resolve(bufnr)
  local b = buffers[bufnr]
  if not b or not b.handle then
    notify('no kernel to restart', vim.log.levels.WARN)
    return
  end
  b.ready = false
  b.queue = {}
  b.pending = 0
  b.busy_visible = false
  b.completions = {}  -- drop callbacks waiting on the pre-restart kernel
  render.clear_all(bufnr)
  b.handle.send({ type = 'restart' })
  notify('restarting kernel…')
  refresh_status()
end

function M.interrupt(bufnr)
  bufnr = resolve(bufnr)
  local b = buffers[bufnr]
  if b and b.handle then
    b.handle.send({ type = 'interrupt' })
  end
end

function M.execute_cell(bufnr, end_line, lines)
  bufnr = resolve(bufnr)
  local b = buffers[bufnr]
  if not b or not b.handle then
    notify('notebook kernel not running; toggle it on first', vim.log.levels.WARN)
    return
  end
  if type(lines) ~= 'table' or #lines == 0 then
    return
  end
  b.cell_seq = b.cell_seq + 1
  local cell_id = b.cell_seq
  local start_line = math.max(end_line - #lines + 1, 1)
  render.begin(bufnr, cell_id, start_line, end_line, b.cfg.max_lines, b.cfg.border, b.cfg.exec_marker,
               vim.bo[bufnr].filetype)
  local req = { type = 'execute', cell_id = cell_id, code = table.concat(lines, '\n') }
  if b.ready then
    b.handle.send(req)
  else
    table.insert(b.queue, req)
  end
  b.pending = b.pending + 1
  note_busy_change(bufnr)
end

-- Ask the live kernel to complete `code` with the cursor at `cursor_pos`
-- (a 0-based offset in Unicode codepoints into `code`). `cb` is invoked exactly
-- once with (matches, cursor_start, cursor_end); matches is a list of strings
-- and the cursor offsets are codepoint offsets into `code`. When no kernel is
-- running/ready, `cb` fires immediately with an empty match list so callers
-- (e.g. a completion source) never hang waiting on a reply.
function M.complete(bufnr, code, cursor_pos, cb)
  bufnr = resolve(bufnr)
  local b = buffers[bufnr]
  if not b or not b.handle or not b.ready then
    cb({}, cursor_pos, cursor_pos)
    return
  end
  b.complete_seq = b.complete_seq + 1
  local req_id = b.complete_seq
  b.completions[req_id] = cb
  b.handle.send({ type = 'complete', req_id = req_id,
                  code = code, cursor_pos = cursor_pos })
end

function M._flush_queue(bufnr)
  local b = buffers[bufnr]
  if not b or not b.handle then
    return
  end
  for _, req in ipairs(b.queue) do
    b.handle.send(req)
  end
  b.queue = {}
end

function M._on_event(bufnr, ev)
  local b = buffers[bufnr]
  if not b then
    return
  end
  local t = ev.type
  if t == 'kernel_ready' then
    b.ready = true
    notify('kernel ready')
    M._flush_queue(bufnr)
    refresh_status()
  elseif t == 'stream' then
    render.add(bufnr, ev.cell_id, ev.name == 'stderr' and 'stderr' or 'stdout', ev.text or '')
  elseif t == 'execute_result' then
    if ev.text and ev.text ~= '' then
      render.add(bufnr, ev.cell_id, 'result', ev.text)
    end
  elseif t == 'display_data' then
    if ev.image_path then
      -- Inline figure: the bridge saved the PNG; transmit it via the kitty
      -- graphics protocol and place its placeholder grid in the cell output.
      local img, ierr = image.show(ev.image_path, ev.image_w, ev.image_h,
                                   b.cfg.figure_size, b.cfg.figure_cell_aspect,
                                   b.cfg.figure_rows)
      if img then
        render.add_image(bufnr, ev.cell_id, img)
      else
        render.add(bufnr, ev.cell_id, 'info',
                   '[figure not displayed: ' .. (ierr or 'unknown error') .. ']')
      end
    elseif ev.text and ev.text ~= '' then
      render.add(bufnr, ev.cell_id, 'result', ev.text)
    elseif ev.has_image then
      -- Only claim the plotty pane when that is actually the configured
      -- route; otherwise (e.g. inline requested but unsupported) be honest.
      local note = b.cfg.figures == 'plotty' and '[matplotlib figure → plotty pane]'
        or '[figure not displayed inline]'
      render.add(bufnr, ev.cell_id, 'info', note)
    end
  elseif t == 'error' then
    local tb = ev.traceback or {}
    local text
    if #tb > 0 then
      text = table.concat(tb, '\n')
    else
      text = (ev.ename or '') .. ': ' .. (ev.evalue or '')
    end
    render.add(bufnr, ev.cell_id, 'error', text)
  elseif t == 'status' then
    if ev.state == 'idle' then
      render.finish(bufnr, ev.cell_id)
    end
  elseif t == 'execute_reply' then
    render.mark_done(bufnr, ev.cell_id, ev.execution_count, ev.status)
    b.pending = math.max(b.pending - 1, 0)
    note_busy_change(bufnr)
  elseif t == 'complete_reply' then
    local cb = b.completions[ev.req_id]
    if cb then
      b.completions[ev.req_id] = nil
      cb(ev.matches or {}, ev.cursor_start, ev.cursor_end)
    end
  elseif t == 'bridge_error' then
    if ev.fatal then
      notify(ev.message or 'kernel error', vim.log.levels.ERROR)
      M.stop(bufnr)
    elseif ev.cell_id then
      render.add(bufnr, ev.cell_id, 'error', ev.message or 'error')
    end
  end
end

function M._on_exit(bufnr, code)
  if not buffers[bufnr] then
    return
  end
  buffers[bufnr] = nil
  if code and code ~= 0 then
    notify('kernel bridge exited (code ' .. tostring(code) .. ')', vim.log.levels.WARN)
  end
  set_flag(bufnr, 0)
  refresh_status()
end

-- Apply the CURRENT g:cmdline_notebook_figure_* values to every active
-- notebook buffer: displayed figures are re-transmitted at the new size and
-- their cells redrawn (text output untouched); future figures use the new
-- values too. Called by :CmdLineNotebookFigureSize and the g: var watchers.
function M.refresh_figures()
  local cfg = config.read()
  -- Future figures in active kernels pick up the new values...
  for _, b in pairs(buffers) do
    b.cfg.figure_size = cfg.figure_size
    b.cfg.figure_rows = cfg.figure_rows
    b.cfg.figure_cell_aspect = cfg.figure_cell_aspect
  end
  -- ...and every figure already on screen is re-fitted (render.lua tracks
  -- them independently of kernel lifetime).
  local n = render.resize_all_images(cfg.figure_size, cfg.figure_cell_aspect,
                                     cfg.figure_rows)
  if n > 0 then
    notify(('resized %d figure%s'):format(n, n == 1 and '' or 's'))
  end
  return n
end

function M.clear_cell(bufnr, start_line, end_line)
  render.clear_range(resolve(bufnr), start_line, end_line)
end

function M.clear_all_output(bufnr)
  render.clear_all(resolve(bufnr))
end

-- Map our border style names to nvim_open_win() border values.
local WIN_BORDER = { rounded = 'rounded', single = 'single', double = 'double', none = 'none' }

local function close_keys(obuf, win)
  local function close()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    else
      pcall(vim.cmd, 'close')
    end
  end
  local opts = { buffer = obuf, nowait = true, silent = true }
  vim.keymap.set('n', 'q', close, opts)
  vim.keymap.set('n', '<Esc>', close, opts)
end

function M.open_output(bufnr, start_line, end_line)
  bufnr = resolve(bufnr)
  local text = render.get_range_text(bufnr, start_line, end_line)
  if not text or #text == 0 then
    notify('no output for this cell')
    return
  end
  local cfg = config.read()
  local parent_ft = vim.bo[bufnr].filetype

  local obuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(obuf, 0, -1, false, text)
  vim.bo[obuf].buftype = 'nofile'
  vim.bo[obuf].bufhidden = 'wipe'
  vim.bo[obuf].swapfile = false
  vim.bo[obuf].modifiable = false   -- read-only display
  vim.bo[obuf].readonly = true
  if parent_ft and parent_ft ~= '' then
    vim.bo[obuf].filetype = parent_ft   -- match parent file's syntax
  end
  pcall(vim.api.nvim_buf_set_name, obuf, 'vimcmdline-output')

  if cfg.output_win == 'split' then
    vim.cmd('botright sbuffer ' .. obuf)
    local swin = vim.api.nvim_get_current_win()
    vim.wo[swin].foldenable = false   -- do not fold output
    close_keys(obuf, nil)
    return
  end

  -- Floating popup (default), centered and sized to the content.
  local cols, lns = vim.o.columns, vim.o.lines
  local maxw = 0
  for _, l in ipairs(text) do
    maxw = math.max(maxw, vim.fn.strdisplaywidth(l))
  end
  local width = math.max(math.min(maxw + 2, math.floor(cols * 0.9)), 20)
  local height = math.max(math.min(#text, math.floor(lns * 0.8)), 1)
  local win = vim.api.nvim_open_win(obuf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((lns - height) / 2 - 1),
    col = math.floor((cols - width) / 2),
    style = 'minimal',
    border = WIN_BORDER[cfg.border] or 'rounded',
    title = ' cell output ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].foldenable = false   -- do not fold output
  vim.wo[win].winhighlight = 'FloatBorder:CmdlineNotebookBorder,FloatTitle:CmdlineNotebookBorder'
  close_keys(obuf, win)
end

return M
