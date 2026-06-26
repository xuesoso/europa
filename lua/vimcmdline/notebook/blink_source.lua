-- A blink.cmp completion source backed by the notebook-mode Jupyter kernel.
-- Maintainer: xuesoso. Part of europa (a fork of vimcmdline). GPL-2.0-or-later.
--
-- It forwards the current line (up to the cursor) to the running kernel via a
-- Jupyter complete_request and turns the reply into completion items. Because
-- the kernel introspects the *live* namespace, this yields runtime completions
-- a static analyzer cannot know -- most usefully pandas DataFrame columns
-- (df["<TAB>"] / df.<TAB>) and dict keys, exactly as in a Jupyter notebook.
--
-- The source is only active in a python buffer that currently has a notebook
-- kernel running; otherwise it returns nothing, so it is inert when off.
--
-- Register it with blink.cmp:
--   require('blink.cmp').setup({
--     sources = {
--       default = { 'kernel', 'lsp', 'path' },
--       providers = {
--         kernel = { name = 'kernel',
--                    module = 'vimcmdline.notebook.blink_source' },
--       },
--     },
--   })

local ok_nb, notebook = pcall(require, 'vimcmdline.notebook')

local KIND_FIELD = vim.lsp.protocol.CompletionItemKind.Field

-- True when the cursor (the end of `s`) sits inside an unterminated string
-- literal. Kernel completion is limited to these subscript/string-key contexts
-- -- df["col"], d['key'], .loc["col"], groupby("col") -- where the static LSP
-- has nothing to offer. Attribute and name completion is left to the LSP
-- source, which carries signatures and docstrings.
local function ends_in_string(s)
  local quote = nil
  for i = 1, #s do
    local c = string.sub(s, i, i)
    if quote then
      if c == quote then quote = nil end
    elseif c == '"' or c == "'" then
      quote = c
    end
  end
  return quote ~= nil
end

--- @class blink.cmp.Source
local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

-- Active only for python buffers whose notebook kernel is running.
function source:enabled()
  return ok_nb and vim.bo.filetype == 'python' and notebook.is_active(0)
end

-- Trigger when a string literal opens. Inside the string, blink's default
-- identifier triggering keeps re-querying as you type the key.
function source:get_trigger_characters()
  return { '"', "'" }
end

function source:get_completions(ctx, callback)
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
  local row = ctx.cursor[1]            -- 1-based line
  local col = ctx.cursor[2]            -- 0-based byte column
  local line = ctx.line
  if line == nil then
    line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ''
  end

  -- Send the line up to the cursor; cursor_pos is then the codepoint length of
  -- that prefix. Keeping `code` == prefix makes the reply's codepoint offsets
  -- map cleanly back to byte columns on this same line.
  local prefix = string.sub(line, 1, col)

  -- Outside a string literal, defer entirely to the LSP source (attributes,
  -- methods, names -- with their descriptions). Returning no items here avoids
  -- duplicate kernel suggestions alongside the LSP ones.
  if not ends_in_string(prefix) then
    callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = true })
    return function() end
  end

  local cursor_pos = vim.fn.strchars(prefix)

  local cancelled = false

  notebook.complete(bufnr, prefix, cursor_pos, function(matches, cursor_start)
    if cancelled then
      return
    end
    if type(matches) ~= 'table' then
      matches = {}
    end

    -- The kernel tells us which span its matches replace. Map the (codepoint)
    -- start back to a byte column so the text edit replaces exactly the partial
    -- token -- correct even for dict/column keys like df["pri<TAB>.
    local start_byte = col
    if type(cursor_start) == 'number' then
      local bi = vim.fn.byteidx(prefix, cursor_start)
      if bi >= 0 then
        start_byte = bi
      end
    end

    local items = {}
    for i, m in ipairs(matches) do
      items[i] = {
        label = m,
        insertText = m,
        kind = KIND_FIELD,
        -- Preserve the kernel's ranking instead of letting it sort alphabetically.
        sortText = string.format('%05d', i),
        textEdit = {
          newText = m,
          range = {
            start = { line = row - 1, character = start_byte },
            ['end'] = { line = row - 1, character = col },
          },
        },
      }
    end

    callback({
      items = items,
      -- Kernel completion is context-sensitive, so re-query as the user types.
      is_incomplete_backward = true,
      is_incomplete_forward = true,
    })
  end)

  -- Cancellation: ignore a late reply for a superseded request.
  return function()
    cancelled = true
  end
end

return source
