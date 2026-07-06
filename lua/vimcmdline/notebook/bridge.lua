-- Spawns and talks to the Python kernel bridge over NDJSON.
local M = {}

-- This file lives at <root>/lua/vimcmdline/notebook/bridge.lua, so the plugin
-- root is four directories up.
local function plugin_root()
  local src = debug.getinfo(1, 'S').source:sub(2)
  return vim.fn.fnamemodify(src, ':h:h:h:h')
end

function M.script_path()
  return plugin_root() .. '/python/vimcmdline_kernel_bridge.py'
end

-- Spawn the bridge. on_event(ev_table) and on_exit(code) are invoked in a
-- normal (scheduled) context, safe to call the Neovim API from.
-- Returns handle{job, send(tbl), stop()} or nil, errmsg.
function M.spawn(python, on_event, on_exit)
  local script = M.script_path()
  if vim.fn.filereadable(script) ~= 1 then
    return nil, 'kernel bridge script not found: ' .. script
  end

  -- A newline-less writer on the protocol channel (a foreign fd inherited by
  -- some subprocess) must not grow the carry buffer without bound, each chunk
  -- re-concatenating it on the main loop.
  local CARRY_MAX = 1024 * 1024

  local carry = ''
  local dropped = 0
  local drop_warned = false
  local function note_drop(n)
    dropped = dropped + n
    if not drop_warned and dropped > 0 then
      drop_warned = true
      vim.schedule(function()
        vim.notify(('europa: dropped %d undecodable line(s) on the kernel'
          .. ' bridge channel (further drops suppressed)'):format(dropped),
          vim.log.levels.WARN)
      end)
    end
  end

  local function on_stdout(_, data)
    if not data then
      return
    end
    -- Canonical jobstart reassembly: data[1] continues the previous carry,
    -- data[#data] is the new (possibly partial) carry.
    data[1] = carry .. data[1]
    carry = data[#data]
    if #carry > CARRY_MAX then
      carry = ''
      note_drop(1)
    end
    data[#data] = nil
    local events = {}
    for _, line in ipairs(data) do
      if line ~= '' then
        local ok, obj = pcall(vim.json.decode, line)
        if ok and type(obj) == 'table' then
          events[#events + 1] = obj
        else
          note_drop(1)
        end
      end
    end
    if #events > 0 then
      vim.schedule(function()
        for _, ev in ipairs(events) do
          on_event(ev)
        end
      end)
    end
  end

  -- Keep the tail of the bridge's stderr: it carries the failure reason when
  -- the process dies before it can emit a bridge_error (import error in the
  -- script, zmq-level crash), and discarding it made such exits report only
  -- "exited (code 1)".
  local STDERR_KEEP = 15
  local stderr_tail = {}
  local function on_stderr(_, data)
    if not data then
      return
    end
    for _, line in ipairs(data) do
      if line ~= '' then
        if #stderr_tail >= STDERR_KEEP then
          table.remove(stderr_tail, 1)
        end
        stderr_tail[#stderr_tail + 1] = line
      end
    end
  end

  local jobid = vim.fn.jobstart({ python, script }, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = function(_, code)
      vim.schedule(function()
        on_exit(code, stderr_tail)
      end)
    end,
  })
  if jobid <= 0 then
    return nil, 'failed to start kernel bridge process'
  end

  local handle = { job = jobid }
  -- Returns true when the payload was accepted by the channel. chansend on a
  -- closing channel returns 0 (and can throw for a freed one); callers must
  -- not count work as submitted in that case.
  function handle.send(obj)
    local ok, sent = pcall(vim.fn.chansend, jobid, vim.json.encode(obj) .. '\n')
    return ok and sent ~= 0
  end
  function handle.stop()
    pcall(vim.fn.jobstop, jobid)
  end
  return handle
end

return M
