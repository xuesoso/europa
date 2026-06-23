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

  local carry = ''
  local function on_stdout(_, data)
    if not data then
      return
    end
    -- Canonical jobstart reassembly: data[1] continues the previous carry,
    -- data[#data] is the new (possibly partial) carry.
    data[1] = carry .. data[1]
    carry = data[#data]
    data[#data] = nil
    local events = {}
    for _, line in ipairs(data) do
      if line ~= '' then
        local ok, obj = pcall(vim.json.decode, line)
        if ok and type(obj) == 'table' then
          events[#events + 1] = obj
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

  local jobid = vim.fn.jobstart({ python, script }, {
    on_stdout = on_stdout,
    on_stderr = function() end, -- diagnostics only; ignored by default
    on_exit = function(_, code)
      vim.schedule(function()
        on_exit(code)
      end)
    end,
  })
  if jobid <= 0 then
    return nil, 'failed to start kernel bridge process'
  end

  local handle = { job = jobid }
  function handle.send(obj)
    vim.fn.chansend(jobid, vim.json.encode(obj) .. '\n')
  end
  function handle.stop()
    pcall(vim.fn.jobstop, jobid)
  end
  return handle
end

return M
