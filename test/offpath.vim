" Routing test for the cell-exec sink (s:CmdLineCellSink) in plugin/vimcmdline.vim.
"
" The caller sets g:cmdline_notebook_enable via -c before sourcing this file.
" Two contracts are checked:
"
"   * Classic path — cell execution falls through to b:cmdline_source_fun
"     exactly as it did before notebook mode existed. This holds whenever the
"     notebook feature is off, OR it is on but a classic REPL is already
"     running for the filetype (a live REPL wins).
"
"   * Auto-enable path — when the feature is on and no classic REPL is running,
"     a bare :CmdLineExecCell auto-enables notebook mode (sets b:cmdline_notebook)
"     and routes the cell to the kernel instead of the classic REPL. The kernel
"     is stubbed here so the test needs no jupyter.
"
" Exits non-zero on any failure.
"
"   nvim --headless -u NONE -N -c 'let g:cmdline_notebook_enable=0' -S test/offpath.vim
"   nvim --headless -u NONE -N -c 'let g:cmdline_notebook_enable=1' -S test/offpath.vim

set rtp^=.
source plugin/vimcmdline.vim
let g:cmdline_block_sep = '# %%'

let s:fail = 0
function! s:check(label, got, want) abort
    if a:got ==# a:want
        echo 'PASS ' . a:label
    else
        echo 'FAIL ' . a:label . ' got=' . string(a:got) . ' want=' . string(a:want)
        let s:fail += 1
    endif
endfunction

let g:RESULT = []
function! FakeSource(lines) abort
    let g:RESULT = a:lines
endfunction

enew
setlocal buftype=nofile
let b:cmdline_source_fun = function('FakeSource')
let b:cmdline_filetype = 'python'
let b:cmdline_app = 'python3'
let b:cmdline_send_empty = 1
call setline(1, ['# %%', 'a = 1', 'b = 2', '# %%', 'c = 3', 'd = 4'])

" Every cell-exec entry point must route through the classic REPL and leave the
" notebook flag unset. Run for each scenario where classic behaviour applies.
function! s:ClassicAsserts(tag) abort
    silent! unlet b:cmdline_notebook
    let g:RESULT = []
    call cursor(2, 1)
    call ExecuteCurrentCodeBlock()
    call s:check(a:tag . '_block1', g:RESULT, ['a = 1', 'b = 2'])

    call cursor(5, 1)
    call ExecuteCurrentCodeBlock()
    call s:check(a:tag . '_block2', g:RESULT, ['c = 3', 'd = 4'])

    call cursor(6, 1)
    call ExecuteToEndCodeBlock()
    call s:check(a:tag . '_to_end', g:RESULT, ['d = 4'])

    call cursor(2, 1)
    call ExecuteCurrentCodeBlockJumpNext()
    call s:check(a:tag . '_jump_next', g:RESULT, ['a = 1', 'b = 2'])

    call s:check(a:tag . '_flag_unset', get(b:, 'cmdline_notebook', -1), -1)
endfunction

if !g:cmdline_notebook_enable
    " Feature off: always classic, flag never set.
    call s:ClassicAsserts('exec')
else
    " Feature on, but a classic REPL is already running: it wins, exec stays
    " classic and never flips the notebook flag.
    let g:cmdline_job['python'] = 42
    call s:ClassicAsserts('repl_wins')
    let g:cmdline_job['python'] = 0

    " Feature on and no REPL: exec auto-enables notebook mode and routes to the
    " kernel, not the classic REPL. Stub the notebook module so no real kernel
    " is spawned; capture what execute_cell() would have received.
    silent! unlet b:cmdline_notebook
    let g:RESULT = []
    let g:NB_LINES = []
lua << EOF
package.loaded['vimcmdline.notebook'] = {
  is_active = function() return false end,
  start = function() return true end,
  execute_cell = function(_, _, lines) vim.g.NB_LINES = lines end,
  status = function() return 'off' end,
  pending = function() return 0 end,
}
EOF
    call cursor(2, 1)
    call ExecuteCurrentCodeBlock()
    call s:check('auto_enable_flag_set', get(b:, 'cmdline_notebook', -1), 1)
    call s:check('auto_enable_routes_kernel', g:NB_LINES, ['a = 1', 'b = 2'])
    call s:check('auto_enable_skips_classic', g:RESULT, [])
endif

if s:fail > 0
    cquit!
else
    echo 'OFFPATH OK (enable=' . g:cmdline_notebook_enable . ')'
    qall!
endif
