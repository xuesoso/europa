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

" Navigation always lands on the top of a cell: one line below the separator,
" or the top of the buffer when there is no separator above. Cells here are
" three lines long so a landing at separator-2 (the old behavior) would be
" mid-cell and fail.
silent %delete _
call setline(1, ['# %%', 'a = 1', 'b = 2', 'c = 3', '# %%', 'd = 4', 'e = 5', 'f = 6', '# %%', 'g = 7', 'h = 8', 'i = 9'])

call cursor(7, 1)
call ToLastCodeBlock()
call s:check('to_prev_midcell_lands_on_top', line('.'), 2)

call cursor(12, 1)
call ToLastCodeBlock()
call s:check('to_prev_from_last_cell', line('.'), 6)

call cursor(6, 1)
call ToLastCodeBlock()
call s:check('to_prev_from_cell_top', line('.'), 2)

call cursor(3, 1)
call ToLastCodeBlock()
call s:check('to_prev_first_cell_goes_to_1', line('.'), 1)

call cursor(12, 1)
call ToNextCodeBlock()
call s:check('to_next_last_cell_lands_on_top', line('.'), 10)

" Leading block with no separator above it: its top is the buffer top.
silent %delete _
call setline(1, ['x = 1', 'y = 2', '# %%', 'z = 3'])

call cursor(4, 1)
call ToLastCodeBlock()
call s:check('to_prev_unmarked_first_block', line('.'), 1)

call cursor(2, 1)
call ToNextCodeBlock()
call s:check('to_next_from_unmarked_block', line('.'), 4)

call cursor(4, 1)
call ToNextCodeBlock()
call s:check('to_next_no_next_stays_on_top', line('.'), 4)

" Adjacent separators form an empty cell. PrevCell visits its top (the second
" separator line) and keeps walking up from there rather than wedging on it.
silent %delete _
call setline(1, ['# %%', 'a = 1', '# %%', '# %%', 'b = 2'])
call cursor(5, 1)
call ToLastCodeBlock()
call s:check('to_prev_adjacent_seps_first_hop', line('.'), 4)
call ToLastCodeBlock()
call s:check('to_prev_adjacent_seps_escapes', line('.'), 2)

" A count moves N cells per press; overshooting a buffer edge settles on the
" first/last cell top (and stops stepping early once the cursor stops moving).
silent %delete _
call setline(1, ['# %%', 'a = 1', 'b = 2', 'c = 3', '# %%', 'd = 4', 'e = 5', 'f = 6', '# %%', 'g = 7', 'h = 8', 'i = 9'])
nmap gJ <Plug>(cmdline-next-cell)
nmap gK <Plug>(cmdline-prev-cell)

call cursor(2, 1)
call feedkeys('2gJ', 'x')
call s:check('count_next_two_cells', line('.'), 10)

call cursor(12, 1)
call feedkeys('2gK', 'x')
call s:check('count_prev_two_cells', line('.'), 2)

call cursor(2, 1)
call feedkeys('99gJ', 'x')
call s:check('count_next_overshoot_lands_last_top', line('.'), 10)

call cursor(12, 1)
call feedkeys('99gK', 'x')
call s:check('count_prev_overshoot_lands_top', line('.'), 1)

" Separator with regex-special characters is matched literally.
let g:cmdline_block_sep = '#[cell]'
silent %delete _
call setline(1, ['#[cell]', 'x = 1', 'y = 2', '#[cell]', 'z = 3'])
call cursor(2, 1)
call ExecuteCurrentCodeBlock()
call s:check('regex_literal_sep', g:RESULT, ['x = 1', 'y = 2'])

if s:fail > 0
    cquit!
else
    echo 'CODEBLOCK OK'
    qall!
endif
