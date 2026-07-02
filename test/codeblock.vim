" Unit test for the # %% code-block (cell) logic in plugin/vimcmdline.vim.
" Exercises range computation, the last-block last-line case, the cursor-on-
" separator edge case, and literal-separator matching. Exits non-zero on
" failure.
"
"   nvim --headless -u NONE -N -S test/codeblock.vim

set rtp^=.
" This test isolates the # %% block *range* logic (which lines a cell spans);
" that computation is identical for the REPL and notebook sinks. Pin notebook
" mode OFF (it now defaults on) so ExecuteCurrentCodeBlock() routes to
" b:cmdline_source_fun (FakeSource) and the captured lines are observable.
" Auto-enable/kernel routing is covered separately by offpath.vim.
let g:cmdline_notebook_enable = 0
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
call setline(1, ['# %%', 'a = 1', 'b = 2', '# %%', 'c = 3', 'd = 4', '# %%', 'e = 5', 'f = 6'])

call cursor(2, 1)
call ExecuteCurrentCodeBlock()
call s:check('block1', g:RESULT, ['a = 1', 'b = 2'])

call cursor(5, 1)
call ExecuteCurrentCodeBlock()
call s:check('block2', g:RESULT, ['c = 3', 'd = 4'])

call cursor(8, 1)
call ExecuteCurrentCodeBlock()
call s:check('lastblock_includes_final', g:RESULT, ['e = 5', 'f = 6'])

call cursor(4, 1)
call ExecuteCurrentCodeBlock()
call s:check('on_separator_nonempty', g:RESULT, ['c = 3', 'd = 4'])

call cursor(2, 1)
call ToNextCodeBlock()
call s:check('to_next_lands_on_5', line('.'), 5)

call cursor(5, 1)
call ToLastCodeBlock()
call s:check('to_prev_lands_on_2', line('.'), 2)

" Separator with regex-special characters is matched literally.
let g:cmdline_block_sep = '#[cell]'
call setline(1, ['#[cell]', 'x = 1', 'y = 2', '#[cell]', 'z = 3'])
call deletebufline('%', 6, '$')
call cursor(2, 1)
call ExecuteCurrentCodeBlock()
call s:check('regex_literal_sep', g:RESULT, ['x = 1', 'y = 2'])

if s:fail > 0
    cquit!
else
    echo 'CODEBLOCK OK'
    qall!
endif
