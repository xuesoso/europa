" Off-path regression test for notebook mode.
"
" Run with notebook mode either disabled or enabled-but-not-toggled; in BOTH
" cases cell execution must fall through to b:cmdline_source_fun exactly as it
" did before notebook mode existed. The caller sets g:cmdline_notebook_enable
" via -c before sourcing this file. Exits non-zero on any failure.
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

call cursor(2, 1)
call ExecuteCurrentCodeBlock()
call s:check('exec_block1', g:RESULT, ['a = 1', 'b = 2'])

call cursor(5, 1)
call ExecuteCurrentCodeBlock()
call s:check('exec_block2', g:RESULT, ['c = 3', 'd = 4'])

call cursor(6, 1)
call ExecuteToEndCodeBlock()
call s:check('exec_to_end', g:RESULT, ['d = 4'])

" Marked-block / paragraph senders also route through the sink unchanged.
call cursor(2, 1)
call ExecuteCurrentCodeBlockJumpNext()
call s:check('exec_jump_next', g:RESULT, ['a = 1', 'b = 2'])

" The notebook flag is never set on the off path.
call s:check('flag_unset', get(b:, 'cmdline_notebook', -1), -1)

if s:fail > 0
    cquit!
else
    echo 'OFFPATH OK (enable=' . g:cmdline_notebook_enable . ')'
    qall!
endif
