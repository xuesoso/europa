"  This program is free software; you can redistribute it and/or modify
"  it under the terms of the GNU General Public License as published by
"  the Free Software Foundation; either version 2 of the License, or
"  (at your option) any later version.
"
"  This program is distributed in the hope that it will be useful,
"  but WITHOUT ANY WARRANTY; without even the implied warranty of
"  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
"  GNU General Public License for more details.
"
"  A copy of the GNU General Public License is available at
"  http://www.r-project.org/Licenses/

"==========================================================================
" europa: run Jupyter-notebook cells and send code to interpreters.
" Maintainer: xuesoso <xuesoso@gmail.com>  (https://github.com/xuesoso/europa)
" A fork of vimcmdline by Jakson Alves de Aquino <jalvesaq@gmail.com>.
" Original author: Jakson Alves de Aquino <jalvesaq@gmail.com>
" Version: 2.5.1
"==========================================================================

if exists("g:did_cmdline")
    finish
endif
let g:did_cmdline = 1
let g:cmdline_version = "2.5.1"

" Set option
if has("nvim")
    let g:cmdline_in_buffer = get(g:, 'cmdline_in_buffer', 1)
else
    let g:cmdline_in_buffer = 0
endif

" Set other options
let g:cmdline_vsplit = get(g:, 'cmdline_vsplit', 0)
let g:cmdline_split_topleft = get(g:, 'cmdline_split_topleft', 0)
let g:cmdline_esc_term = get(g:, 'cmdline_esc_term', 1)
let g:cmdline_term_width = get(g:, 'cmdline_term_width', 40)
let g:cmdline_term_height = get(g:, 'cmdline_term_height', 15)
" Temp dir for interchange files (REPL source loads, notebook figure PNGs).
" The default derives from tempname(): unique per session and created 0700
" under the user's private temp tree — a fixed /tmp/cmdline_<epoch>_<user>
" was predictable (symlink attacks), world-visible, and collided between two
" sessions started within the same second. Only the derived default is
" cleaned up recursively at exit; a user-provided dir is left in place.
if exists('g:cmdline_tmp_dir')
    let s:tmp_dir_owned = 0
else
    let g:cmdline_tmp_dir = tempname() . '_cmdline'
    let s:tmp_dir_owned = 1
endif
augroup VimCmdLineCleanup
    autocmd!
    if s:tmp_dir_owned
        autocmd VimLeave * if isdirectory(g:cmdline_tmp_dir) | call delete(g:cmdline_tmp_dir, 'rf') | endif
    else
        autocmd VimLeave * for s:tf in glob(g:cmdline_tmp_dir . '/lines.*', 0, 1) | call delete(s:tf) | endfor
    endif
augroup END
let g:cmdline_outhl = get(g:, 'cmdline_outhl', 1)
let g:cmdline_auto_scroll = get(g:, 'cmdline_auto_scroll', 1)
let g:cmdline_block_sep = get(g:, 'cmdline_block_sep', '# %%')

" Notebook mode options (Neovim only; see :help vimcmdline-notebook)
" On by default: running a cell (,c) in Neovim starts a Jupyter kernel and
" renders output inline. Set to 0 for classic REPL-only behavior. A live REPL
" still wins per buffer, so `,s` then the send keys stay pure REPL.
let g:cmdline_notebook_enable = get(g:, 'cmdline_notebook_enable', 1)
" Figure routing: 'inline' (default; kitty graphics in the cell output —
" needs kitty/ghostty + termguicolors), 'plotty' (tmux pane), or 'none'.
"
" Deliberately NOT materialized into a global here: lua/vimcmdline/notebook/
" config.lua resolves the effective route and honors the legacy
" g:cmdline_notebook_plotty (1 => 'plotty', 0 => 'none') when the user set it
" but not figures. Leaving g:cmdline_notebook_figures unset unless the user
" actually chose a route is what lets the inline-figure gate read it as
" intent: an explicit 'inline' overrides terminal detection, while the default
" 'inline' falls through to detection (and to the plotty/text fallback on an
" incapable terminal). g:cmdline_notebook_plotty is likewise left unset so
" config.lua can tell a real user choice from the default.
let g:cmdline_notebook_startup_code = get(g:, 'cmdline_notebook_startup_code', [])
let g:cmdline_notebook_python = get(g:, 'cmdline_notebook_python', '')
let g:cmdline_notebook_kernel_name = get(g:, 'cmdline_notebook_kernel_name', 'python3')
let g:cmdline_notebook_max_lines = get(g:, 'cmdline_notebook_max_lines', 20)
" Retention cap per cell: at most this many output lines are KEPT (first and
" last halves, with an elision marker between) so a runaway `while True:
" print(...)` cannot grow memory or redraw cost without bound. 0 = unlimited.
let g:cmdline_notebook_max_kept_lines = get(g:, 'cmdline_notebook_max_kept_lines', 10000)
let g:cmdline_notebook_kernel_timeout = get(g:, 'cmdline_notebook_kernel_timeout', 30)
let g:cmdline_notebook_border = get(g:, 'cmdline_notebook_border', 'rounded')
let g:cmdline_notebook_statusline = get(g:, 'cmdline_notebook_statusline', 1)
let g:cmdline_notebook_output_win = get(g:, 'cmdline_notebook_output_win', 'float')
let g:cmdline_notebook_exec_marker = get(g:, 'cmdline_notebook_exec_marker', 1)
let g:cmdline_notebook_figure_size = get(g:, 'cmdline_notebook_figure_size', 50)
let g:cmdline_notebook_figure_dpi = get(g:, 'cmdline_notebook_figure_dpi', 200)
let g:cmdline_notebook_figure_cell_aspect = get(g:, 'cmdline_notebook_figure_cell_aspect', 2.0)
" Explicit inline-figure height in rows; 0 (default) derives the height from
" the image's aspect ratio. Both size options apply live: changing them (or
" running :CmdLineNotebookFigureSize) re-renders figures already on screen.
let g:cmdline_notebook_figure_rows = get(g:, 'cmdline_notebook_figure_rows', 0)
" Terminal-name substrings treated as kitty-graphics capable by the inline
" figure gate (matched against $TERM, or tmux's #{client_termname} inside
" tmux). Extend for terminals that ship Unicode-placeholder support the
" default list cannot know about.
let g:cmdline_notebook_kitty_terms = get(g:, 'cmdline_notebook_kitty_terms', ['kitty', 'ghostty'])
let g:cmdline_notebook_airline_section = get(g:, 'cmdline_notebook_airline_section', 'x')

" Internal variables
let g:cmdline_job = {}
let g:cmdline_termbuf = {}
let g:cmdline_tmuxsname = {}
" glob() as a LIST: split() on the string form breaks on any whitespace, so an
" install path containing a space produced garbage filetype keys (and E716 on
" every state-dict access thereafter).
let s:ftlist = glob(expand('<sfile>:h:h') . '/ftplugin/*', 0, 1)

if has('win32')
    " on windows
    call map(s:ftlist, "substitute(v:val, '.*\\', '', '')")
    call map(s:ftlist, "substitute(v:val, '_cmdline.vim', '', '')")
else
    call map(s:ftlist, "substitute(v:val, '.*/\\(.*\\)_.*', '\\1', '')")
endif

for s:ft in s:ftlist
    let g:cmdline_job[s:ft] = 0
    let g:cmdline_termbuf[s:ft] = ''
    let g:cmdline_tmuxsname[s:ft] = ''
endfor
unlet s:ftlist
unlet s:ft
" tmux-pane mode state, one pane per filetype (a single shared pane conflated
" concurrently running REPLs of different languages).
let s:cmdline_app_pane = {}

" State dicts are seeded from the shipped ftplugins above; a user-defined
" ftplugin following the same contract (setting b:cmdline_filetype) gets its
" entries created here instead of E716-ing on first access.
function s:EnsureFtState(ftype)
    if !has_key(g:cmdline_job, a:ftype)
        let g:cmdline_job[a:ftype] = 0
    endif
    if !has_key(g:cmdline_termbuf, a:ftype)
        let g:cmdline_termbuf[a:ftype] = ''
    endif
    if !has_key(g:cmdline_tmuxsname, a:ftype)
        let g:cmdline_tmuxsname[a:ftype] = ''
    endif
endfunction

" Write `lines` to a fresh temp file for ONE dispatch and return its path.
" ftplugin source functions used a fixed per-language name, which raced
" run-all-cells: the interpreter reads the file asynchronously, by which time
" a later cell had already overwritten it (cells ran twice or not at all).
let s:tmpfile_seq = 0
function VimCmdLineWriteTmp(lines, name, ...)
    let s:tmpfile_seq += 1
    let l:path = g:cmdline_tmp_dir . '/' . a:name . '.' . s:tmpfile_seq
    call writefile(a:lines, l:path, a:0 > 0 ? a:1 : '')
    return l:path
endfunction

" Skip empty lines
function VimCmdLineDown()
    let i = line(".") + 1
    call cursor(i, 1)
    if b:cmdline_send_empty
        return
    endif
    let curline = substitute(getline("."), '^\s*', "", "")
    let lastLine = line("$")
    while i < lastLine && strlen(curline) == 0
        let i = i + 1
        call cursor(i, 1)
        let curline = substitute(getline("."), '^\s*', "", "")
    endwhile
endfunction

" Adapted from screen plugin:
function GetTmuxActivePane()
  let line = system("tmux list-panes | grep \'(active)$'")
  let paneid = matchstr(line, '\v\%\d+ \(active\)')
  if !empty(paneid)
    return matchstr(paneid, '\v^\%\d+')
  else
    return matchstr(line, '\v^\d+')
  endif
endfunction

function VimCmdLineStart_ExTerm(app)
    " Check if the REPL application is already running
    if g:cmdline_tmuxsname[b:cmdline_filetype] != ""
        let tout = system("tmux -L VimCmdLine has-session -t " . g:cmdline_tmuxsname[b:cmdline_filetype])
        if tout =~ "VimCmdLine" || tout =~ g:cmdline_tmuxsname[b:cmdline_filetype]
            unlet g:cmdline_tmuxsname[b:cmdline_filetype]
        else
            echohl WarningMsg
            echo 'Tmux session with "' . b:cmdline_app . '" is already running.'
            echohl Normal
            return
        endif
    endif

    " The filetype in the session name keeps two REPLs started within the
    " same second (different languages) from fighting over one tmux session.
    let g:cmdline_tmuxsname[b:cmdline_filetype] = "vcl" . b:cmdline_filetype . localtime()

    let cnflines = ['set-option -g prefix C-a',
                \ 'unbind-key C-b',
                \ 'bind-key C-a send-prefix',
                \ 'set-window-option -g mode-keys vi',
                \ 'set -g status off',
                \ 'set -g default-terminal "screen-256color"',
                \ "set -g terminal-overrides 'xterm*:smcup@:rmcup@'" ]
    if g:cmdline_external_term_cmd =~ "rxvt" || g:cmdline_external_term_cmd =~ "urxvt"
        let cnflines = cnflines + [
                    \ "set terminal-overrides 'rxvt*:smcup@:rmcup@'" ]
    endif
    call writefile(cnflines, g:cmdline_tmp_dir . "/tmux.conf")


    let cmd = printf(g:cmdline_external_term_cmd,
                \ 'tmux -2 -f "' . g:cmdline_tmp_dir . '/tmux.conf' .
                \ '" -L VimCmdLine new-session -s ' . g:cmdline_tmuxsname[b:cmdline_filetype] . ' ' . a:app)
    call system(cmd)
    if v:shell_error
        " A bad g:cmdline_external_term_cmd or missing terminal emulator used
        " to fail silently, leaving a session name that every send would then
        " trip over.
        echohl WarningMsg
        echomsg 'europa: failed to launch the external terminal: ' . cmd
        echohl Normal
        let g:cmdline_tmuxsname[b:cmdline_filetype] = ''
    endif
endfunction

" Run the interpreter in a Tmux panel
function VimCmdLineStart_Tmux(app)
    " Check if Tmux is running
    if $TMUX == ""
        echohl WarningMsg
        echomsg "Cannot start interpreter because not inside a Tmux session."
        echohl Normal
        return
    endif

    let g:cmdline_vim_pane = GetTmuxActivePane()
    let tcmd = "tmux split-window "
    if g:cmdline_vsplit
        if g:cmdline_term_width == -1
            let tcmd .= "-h"
        else
            let tcmd .= "-h -l " . g:cmdline_term_width
        endif
    else
        let tcmd .= "-l " . g:cmdline_term_height
    endif
    let tcmd .= " " . a:app
    let slog = system(tcmd)
    if v:shell_error
        " echoerr the VALUE: `exe 'echoerr ' . slog` parsed tmux's stderr as a
        " Vim expression, yielding E121 garbage instead of the message.
        echoerr slog
        return
    endif
    let s:cmdline_app_pane[b:cmdline_filetype] = GetTmuxActivePane()
    let slog = system("tmux select-pane -t " . g:cmdline_vim_pane)
    if v:shell_error
        echoerr slog
        return
    endif
endfunction

" Run the interpreter in a Neovim terminal buffer
function VimCmdLineStart_Nvim(app)
    let quitcmd = b:cmdline_quit_cmd
    let thisft = b:cmdline_filetype
    let cmd_app = b:cmdline_app
    let cmdline_nl = b:cmdline_nl
    " Buffer NUMBER, not name: an unnamed buffer's name is '' and
    " `sbuffer ''` splits the terminal buffer instead of returning to it.
    let edbuf = bufnr("%")
    if g:cmdline_job[b:cmdline_filetype]
        return
    endif
    " Scoped, not global: `set switchbuf=useopen` silently clobbered the
    " user's option for the whole session.
    let sb_save = &switchbuf
    set switchbuf=useopen
    if g:cmdline_vsplit
        if g:cmdline_term_width > 16 && g:cmdline_term_width < (winwidth(0) - 16)
            if g:cmdline_split_topleft
                silent exe "topleft " . g:cmdline_term_width . "vnew"
            else
                silent exe "belowright " . g:cmdline_term_width . "vnew"
            endif
        else
            if g:cmdline_split_topleft
                silent topleft vnew
            else
                silent belowright vnew
            endif
        endif
    else
        if g:cmdline_term_height > 6 && g:cmdline_term_height < (winheight(0) - 6)
            silent exe "belowright " . g:cmdline_term_height . "new"
        else
            silent belowright new
        endif
    endif
    let g:cmdline_job[thisft] = termopen(a:app, {'on_exit': function('s:VimCmdLineJobExit')})
    let g:cmdline_termbuf[thisft] = bufname("%")
    let b:cmdline_filetype = thisft
    let b:cmdline_quit_cmd = quitcmd
    let b:cmdline_app = cmd_app
    let b:cmdline_nl = cmdline_nl
    if g:cmdline_esc_term
        tnoremap <buffer> <Esc> <C-\><C-n>
    endif
    if g:cmdline_outhl
        " Key on the app's base name (the configured app may carry arguments
        " or a full path), falling back to the filetype so e.g. 'gomacro' and
        " 'lein repl' still load their language's output syntax file.
        let outhl_name = fnamemodify(split(a:app)[0], ':t')
        if empty(globpath(&rtp, 'syntax/cmdlineoutput_' . outhl_name . '.vim'))
            let outhl_name = thisft
        endif
        exe 'runtime syntax/cmdlineoutput_' . outhl_name . '.vim'
    endif
    normal! G
    exe "sbuffer " . edbuf
    let &switchbuf = sb_save
    stopinsert
endfunction

function VimCmdLineCreateMaps()
    " noremap for maps whose rhs is a direct :call — a user remap of ':' or
    " of any rhs key must not break them. The cell maps below stay `nmap`:
    " a <Plug> rhs only resolves through remapping.
    exe 'nnoremap <silent><buffer> ' . g:cmdline_map_send . ' :call VimCmdLineSendLine()<CR>'
    exe 'nnoremap <silent><buffer> ' . g:cmdline_map_send_and_stay . ' :call VimCmdLineSendLineAndStay()<CR>'
    exe 'xnoremap <silent><buffer> ' . g:cmdline_map_send .
                \ ' <Esc>:call VimCmdLineSendSelection()<CR>'
    if exists("b:cmdline_source_fun")
        exe 'nnoremap <silent><buffer> ' . g:cmdline_map_source_fun .
                    \ ' :call b:cmdline_source_fun(getline(1, "$"))<CR>'
        exe 'nnoremap <silent><buffer> ' . g:cmdline_map_send_paragraph .
                    \ ' :call VimCmdLineSendParagraph()<CR>'
        exe 'nnoremap <silent><buffer> ' . g:cmdline_map_send_block .
                    \ ' :call VimCmdLineSendMBlock()<CR>'
        " Code-block (g:cmdline_block_sep, default '# %%') mappings
        exe 'nmap <silent><buffer> ' . g:cmdline_map_exec_block .
                    \ ' <Plug>(cmdline-exec-cell)'
        exe 'nmap <silent><buffer> ' . g:cmdline_map_exec_block_and_jump .
                    \ ' <Plug>(cmdline-exec-cell-jump-next)'
        exe 'nmap <silent><buffer> ' . g:cmdline_map_exec_to_end .
                    \ ' <Plug>(cmdline-exec-to-end)'
        exe 'nmap <silent><buffer> ' . g:cmdline_map_next_block .
                    \ ' <Plug>(cmdline-next-cell)'
        exe 'nmap <silent><buffer> ' . g:cmdline_map_prev_block .
                    \ ' <Plug>(cmdline-prev-cell)'
    endif
    if exists("b:cmdline_quit_cmd")
        exe 'nnoremap <silent><buffer> ' . g:cmdline_map_quit . ' :call VimCmdLineQuit("' . b:cmdline_filetype . '")<CR>'
    endif
endfunction

" Common procedure to start the interpreter
function VimCmdLineStartApp()
    if !exists("b:cmdline_app")
        echomsg 'There is no application defined to be executed for file of type "' . b:cmdline_filetype . '".'
        return
    endif
    call s:EnsureFtState(b:cmdline_filetype)

    call VimCmdLineCreateMaps()

    if !isdirectory(g:cmdline_tmp_dir)
        try
            " 'p' + 0700: create intermediate dirs, keep interchange files
            " (source loads, figure PNGs) private to the user.
            call mkdir(g:cmdline_tmp_dir, 'p', 0700)
        catch
            echohl WarningMsg
            echomsg 'europa: cannot create temp dir ' . g:cmdline_tmp_dir
            echohl Normal
            return
        endtry
    endif

    if get(b:, 'cmdline_notebook', 0)
        call v:lua.require'vimcmdline.notebook'.start(bufnr('%'))
        return
    endif

    if exists("g:cmdline_external_term_cmd")
        call VimCmdLineStart_ExTerm(b:cmdline_app)
    else
        if g:cmdline_in_buffer
            call VimCmdLineStart_Nvim(b:cmdline_app)
        else
            call VimCmdLineStart_Tmux(b:cmdline_app)
        endif
    endif
endfunction

" Send a single line to the interpreter
function VimCmdLineSendCmd(...)
    if g:cmdline_job[b:cmdline_filetype]
        if g:cmdline_auto_scroll && (!exists('b:cmdline_quit_cmd') || a:1 != b:cmdline_quit_cmd)
            " win_execute scrolls the terminal window WITHOUT a focus round
            " trip: the old sb/wincmd-w dance ran every other plugin's
            " WinEnter/WinLeave/BufEnter autocmds twice per line sent. When
            " the terminal is not visible in any window there is nothing to
            " scroll (sending no longer yanks a window open).
            let termwin = bufwinid(g:cmdline_termbuf[b:cmdline_filetype])
            if termwin > 0
                call win_execute(termwin, 'normal! G')
            endif
        endif
        if exists('*chansend')
            call chansend(g:cmdline_job[b:cmdline_filetype], a:1 . b:cmdline_nl)
        else
            call jobsend(g:cmdline_job[b:cmdline_filetype], a:1 . b:cmdline_nl)
        endif
    else
        let str = substitute(a:1, "'", "'\\\\''", "g")
        if str =~ '^-'
            let str = ' ' . str
        endif
        if exists("g:cmdline_external_term_cmd") && g:cmdline_tmuxsname[b:cmdline_filetype] != ""
            let scmd = "tmux -L VimCmdLine set-buffer '" . str .
                        \ "\<C-M>' && tmux -L VimCmdLine paste-buffer -t " . g:cmdline_tmuxsname[b:cmdline_filetype] . '.0'
            call system(scmd)
            if v:shell_error
                echohl WarningMsg
                echomsg 'Failed to send command. Is "' . b:cmdline_app . '" running?'
                echohl Normal
                " Assign '', never :unlet — removing the KEY made every later
                " access (the next send, restart, even loading another file
                " of this filetype) throw E716.
                let g:cmdline_tmuxsname[b:cmdline_filetype] = ''
            endif
        elseif get(s:cmdline_app_pane, b:cmdline_filetype, '') != ''
            let scmd = "tmux set-buffer '" . str . "\<C-M>' && tmux paste-buffer -t "
                        \ . s:cmdline_app_pane[b:cmdline_filetype]
            call system(scmd)
            if v:shell_error
                echohl WarningMsg
                echomsg 'Failed to send command. Is "' . b:cmdline_app . '" running?'
                echohl Normal
                let s:cmdline_app_pane[b:cmdline_filetype] = ''
            endif
        endif
    endif
endfunction

" Send current line to the interpreter and go down to the next non empty line
function VimCmdLineSendLine()
    if get(b:, 'cmdline_notebook', 0)
        call s:CmdLineCellSink([getline(".")], line("."))
        call VimCmdLineDown()
        return
    endif
    if exists('*b:cmdline_send')
        call b:cmdline_send()
        return
    endif
    let line = getline(".")
    if strlen(line) > 0 || b:cmdline_send_empty
        call VimCmdLineSendCmd(line)
    endif
    call VimCmdLineDown()
endfunction

" Send current line to the interpreter and but keep cursor on current line
function VimCmdLineSendLineAndStay()
    if get(b:, 'cmdline_notebook', 0)
        call s:CmdLineCellSink([getline(".")], line("."))
        return
    endif
    let line = getline(".")
    if strlen(line) > 0 || b:cmdline_send_empty
        call VimCmdLineSendCmd(line)
    endif
endfunction

function VimCmdLineSendSelection()
    if line("'<") == line("'>")
        let i = col("'<") - 1
        let l = getline("'<")
        " col("'>") is the byte index of the FIRST byte of the last selected
        " character; extend by that character's full byte length so a
        " selection ending on a multibyte char is not cut mid-sequence.
        let lastc = matchstr(l[col("'>") - 1:], '.')
        let j = col("'>") - i + strlen(lastc) - 1
        let line = strpart(l, i, j)
        if get(b:, 'cmdline_notebook', 0)
            call s:CmdLineCellSink([line], line("'>"))
        else
            call VimCmdLineSendCmd(line)
        endif
    elseif exists("b:cmdline_source_fun")
        call s:CmdLineCellSink(getline("'<", "'>"), line("'>"))
    endif
endfunction

function VimCmdLineSendParagraph()
    let i = line(".")
    let c = col(".")
    let max = line("$")
    let j = i
    let gotempty = 0
    while j < max
        let j += 1
        let line = getline(j)
        if line =~ '^\s*$'
            break
        endif
    endwhile
    let lines = getline(i, j)
    call s:CmdLineCellSink(lines, j)
    if j < max
        call cursor(j, 1)
    else
        call cursor(max, 1)
    endif
endfunction

let s:all_marks = "abcdefghijklmnopqrstuvwxyz"

function VimCmdLineSendMBlock()
    let curline = line(".")
    let lineA = 1
    let lineB = line("$")
    let maxmarks = strlen(s:all_marks)
    let n = 0
    while n < maxmarks
        let c = strpart(s:all_marks, n, 1)
        let lnum = line("'" . c)
        if lnum != 0
            if lnum <= curline && lnum > lineA
                let lineA = lnum
            elseif lnum > curline && lnum < lineB
                let lineB = lnum
            endif
        endif
        let n = n + 1
    endwhile
    if lineA == 1 && lineB == (line("$"))
        echo "The file has no mark!"
        return
    endif
    if lineB < line("$")
        let lineB -= 1
    endif
    let lines = getline(lineA, lineB)
    call s:CmdLineCellSink(lines, lineB)
endfunction

" Quit the interpreter
function VimCmdLineQuit(ftype)
    if exists("b:cmdline_quit_cmd")
        call VimCmdLineSendCmd(b:cmdline_quit_cmd)
        " bufexists guard: the REPL process can end on its own (user typed
        " quit() in the terminal) and the buffer be wiped afterwards — a
        " stale name here made `sb` throw E94.
        if g:cmdline_termbuf[a:ftype] != "" && bufexists(g:cmdline_termbuf[a:ftype])
            let sb_save = &switchbuf
            set switchbuf=useopen
            exe "sb " . g:cmdline_termbuf[a:ftype]
            let &switchbuf = sb_save
            startinsert
        endif
        let g:cmdline_termbuf[a:ftype] = ""
        let g:cmdline_tmuxsname[a:ftype] = ""
        let s:cmdline_app_pane[a:ftype] = ''
    else
        echomsg 'Quit command not defined for file of type "' . a:ftype . '".'
    endif
endfunction

" Register that the job no longer exists
function s:VimCmdLineJobExit(job_id, data, etype)
    for ftype in keys(g:cmdline_job)
        if a:job_id == g:cmdline_job[ftype]
            let g:cmdline_job[ftype] = 0
            " The terminal buffer name must go too: Quit would otherwise
            " jump into a dead "[Process exited]" terminal (or E94 once the
            " buffer is wiped).
            let g:cmdline_termbuf[ftype] = ''
        endif
    endfor
endfunction

" Replace default application with custom one
function VimCmdLineSetApp(ftype)
    if exists("g:cmdline_app")
        for key in keys(g:cmdline_app)
            if key == a:ftype
                let b:cmdline_app = g:cmdline_app[a:ftype]
            endif
        endfor
    endif
    call s:EnsureFtState(b:cmdline_filetype)
    if g:cmdline_job[b:cmdline_filetype] || g:cmdline_tmuxsname[b:cmdline_filetype] != ""
                \ || get(s:cmdline_app_pane, b:cmdline_filetype, '') != ''
        call VimCmdLineCreateMaps()
    endif
endfunction

" Convenient functions to execute code block
" Code block is assumed to be separated by the string defined in
" g:cmdline_block_sep (default: '# %%'). The separator is matched literally
" (\V) so that special characters in it are not treated as a regex.

function! s:BlockSepPattern()
    return '\V' . escape(g:cmdline_block_sep, '\')
endfunction

" Line of the next separator at or below the cursor (0 if none). The cursor
" line itself is not accepted, so when the cursor sits on a separator we find
" the *next* one below rather than matching the current line.
function! NextCodeBlock()
    return search(s:BlockSepPattern(), 'Wn')
endfunction

" Line of the nearest separator at or above the cursor (0 if none).
function! LastCodeBlock()
    return search(s:BlockSepPattern(), 'bcWn')
endfunction

" First line of the cell containing the cursor: one line below the nearest
" separator at or above the cursor, or the top of the buffer when there is no
" separator above. Clamped so a separator on the last buffer line does not
" yield a line past the end.
function! s:CurrentBlockTop()
    let l:lastblock = LastCodeBlock()
    return l:lastblock == 0 ? 1 : min([l:lastblock + 1, line("$")])
endfunction

" Single-step cursor moves, with no notion of a count. Used both by the
" count-aware ToNextCodeBlock()/ToLastCodeBlock() below and internally by
" ExecuteCurrentCodeBlockJumpNext(), which must NOT let its internal jump
" re-read v:count1: that variable stays set to the outer command's count for
" the whole duration of the command (it is not reset per nested function
" call), so calling the count-aware wrapper from inside a count-aware caller
" would compound the count instead of taking one step per loop iteration.
"
" Both steps always land on the top of a cell: one line below the cell's
" separator, or the top of the buffer for a leading block with no separator
" above it.
function! s:StepNextCodeBlock()
    let l:nextblock = NextCodeBlock()
    if l:nextblock == 0
        " No cell below: settle on the top of the current (last) cell.
        exe s:CurrentBlockTop()
    else
        exe min([l:nextblock + 1, line("$")])
    endif
endfunction

function! s:StepLastCodeBlock()
    let l:cursep = LastCodeBlock()
    " The landing must be strictly above both the cursor and the top of the
    " current cell (cursep + 1). Bounding by the cursor line matters when the
    " cursor sits ON a separator: adjacent separators would otherwise make
    " the separator line its own landing target, wedging the motion there
    " instead of walking on up.
    let l:bound = min([line('.'), l:cursep + 1])
    if l:cursep == 0 || l:bound <= 2
        " First cell (unmarked, or marked on line 1): the top of the buffer
        " is as far up as a cell top goes.
        exe 1
        return
    endif
    " Nearest separator at or above bound-2 opens the previous cell one line
    " below it; no separator there means the previous cell is the leading
    " unmarked block. LastCodeBlock() searches from the cursor, so hop there
    " (end of line, so an indented separator on that line still matches) and
    " restore afterwards.
    let l:save = getpos('.')
    call cursor(l:bound - 2, col([l:bound - 2, '$']))
    let l:prevsep = LastCodeBlock()
    call setpos('.', l:save)
    exe l:prevsep == 0 ? 1 : l:prevsep + 1
endfunction

" A count moves N cells forward/back instead of just one. A step that leaves
" the cursor on the same line has reached a fixed point (the first or last
" cell): every further step would rescan the buffer only to stay put — in a
" separator-less buffer each of those is a full-buffer search() — so stop as
" soon as a step stops moving.
function! ToNextCodeBlock()
    let l:n = v:count1
    while l:n > 0
        let l:before = line('.')
        call s:StepNextCodeBlock()
        if line('.') == l:before
            break
        endif
        let l:n -= 1
    endwhile
endfunction

function! ToLastCodeBlock()
    let l:n = v:count1
    while l:n > 0
        let l:before = line('.')
        call s:StepLastCodeBlock()
        if line('.') == l:before
            break
        endif
        let l:n -= 1
    endwhile
endfunction

" Last line of the current block: the line before the next separator, or the
" last line of the buffer when there is no separator below.
function! s:CurrentBlockEnd()
    let l:nextblock = NextCodeBlock()
    return l:nextblock == 0 ? line("$") : l:nextblock - 1
endfunction

" Route a cell's lines to its sink: the inline notebook kernel when notebook
" mode is on for this buffer, otherwise the classic REPL via b:cmdline_source_fun.
" a:endline is the buffer line the output is anchored under in notebook mode.
" Whether a cell should auto-enable notebook mode when it is currently off:
" the notebook feature is enabled, the filetype has an interpreter defined, and
" no classic REPL is already running for it (a live REPL wins — we don't yank
" the buffer out from under it).
function! s:ShouldAutoNotebook()
    if !(has('nvim') && get(g:, 'cmdline_notebook_enable', 0))
        return 0
    endif
    if !exists('b:cmdline_app')
        return 0
    endif
    if exists('b:cmdline_filetype') && has_key(g:cmdline_job, b:cmdline_filetype)
                \ && g:cmdline_job[b:cmdline_filetype] != 0
        return 0
    endif
    return 1
endfunction

function! s:CmdLineCellSink(lines, endline)
    " Notebook mode off but nothing else is claiming this buffer: opt in
    " automatically so a bare :CmdLineExecCell brings up the kernel instead of
    " erroring, no manual toggle required. start() below (or set_flag on
    " failure) keeps b:cmdline_notebook honest.
    if !get(b:, 'cmdline_notebook', 0) && s:ShouldAutoNotebook()
        let b:cmdline_notebook = 1
        " Auto-enable bypasses VimCmdLineStartApp(), so bind the buffer's cmdline
        " maps here too — otherwise the send maps (cmdline_map_send etc.) never
        " get created and only the exec-cell command works.
        call VimCmdLineCreateMaps()
    endif
    if get(b:, 'cmdline_notebook', 0)
        " Notebook mode is on but no kernel is attached (never started, stopped,
        " or crashed): bring one up before sending. start() is idempotent — it
        " returns early when a handle already exists — so rapid key-repeat exec
        " commands can never spawn a second kernel. Cells submitted while the
        " kernel is still booting are queued by execute_cell() and flushed on
        " kernel_ready, so nothing is lost.
        if !v:lua.require'vimcmdline.notebook'.is_active(bufnr('%'))
            call v:lua.require'vimcmdline.notebook'.start(bufnr('%'))
        endif
        call v:lua.require'vimcmdline.notebook'.execute_cell(bufnr('%'), a:endline, a:lines)
    else
        " The cell commands are defined globally; in a buffer with no cmdline
        " ftplugin there is no source function — say so instead of E121.
        if exists('b:cmdline_source_fun')
            call b:cmdline_source_fun(a:lines)
        else
            echohl WarningMsg
            echomsg 'europa: no interpreter configured for filetype "' . &filetype . '".'
            echohl Normal
        endif
    endif
endfunction

" Executes exactly once no matter what count preceded the mapping/command: a
" "run this cell" action has no sane meaning repeated blindly N times (it
" would just re-queue/re-run the same cell and duplicate side effects), so
" any count is intentionally ignored here.
function! ExecuteCurrentCodeBlock()
    let l:start = LastCodeBlock() + 1
    let l:end = s:CurrentBlockEnd()
    let l:lines = getline(l:start, l:end)
    call s:CmdLineCellSink(l:lines, l:end)
endfunction

" Same rationale as ExecuteCurrentCodeBlock(): always run once, count ignored.
function! ExecuteToEndCodeBlock()
    let l:end = s:CurrentBlockEnd()
    let l:lines = getline(line("."), l:end)
    call s:CmdLineCellSink(l:lines, l:end)
endfunction

" Unlike ExecuteCurrentCodeBlock(), a count here has an unambiguous meaning:
" "execute this cell and the next N-1 cells", so v:count1 is honored.
function! ExecuteCurrentCodeBlockJumpNext()
    let l:n = v:count1
    while l:n > 0
        let l:start = LastCodeBlock() + 1
        let l:end = s:CurrentBlockEnd()
        let l:lines = getline(l:start, l:end)
        call s:CmdLineCellSink(l:lines, l:end)
        call s:StepNextCodeBlock()
        let l:n -= 1
    endwhile
endfunction

" Execute every cell from a:startline's block down to the end of the buffer,
" top to bottom. Cursor is parked back where it started when done. Whitespace-
" only cells are skipped so an empty leading/trailing block is not sent to the
" kernel. Any count is ignored: "run everything" has one meaning. In notebook
" mode all cells are dispatched immediately and run in submission order (the
" kernel queues them); the classic REPL receives them back to back.
function! s:ExecuteCodeBlocksFrom(startline)
    let l:save = getpos('.')
    call cursor(a:startline, 1)
    while 1
        let l:start = LastCodeBlock() + 1
        let l:end = s:CurrentBlockEnd()
        let l:lines = getline(l:start, l:end)
        if join(l:lines, '') !~ '^\s*$'
            call s:CmdLineCellSink(l:lines, l:end)
        endif
        if l:end >= line('$')
            break
        endif
        call s:StepNextCodeBlock()
    endwhile
    call setpos('.', l:save)
endfunction

" Run all cells in the buffer, top to bottom.
function! ExecuteAllCodeBlocks()
    call s:ExecuteCodeBlocksFrom(1)
endfunction

" Run the cell under the cursor and every cell below it.
function! ExecuteAllCodeBlocksBelow()
    call s:ExecuteCodeBlocksFrom(line('.'))
endfunction

" :command! entry points, so cell exec/navigation is reachable without a raw
" ":call Func()<CR>" and shows up in ":CmdLine<Tab>" completion.
command! CmdLineExecCell         call ExecuteCurrentCodeBlock()
command! CmdLineExecCellJumpNext call ExecuteCurrentCodeBlockJumpNext()
command! CmdLineExecAllCells     call ExecuteAllCodeBlocks()
command! CmdLineExecAllCellsBelow call ExecuteAllCodeBlocksBelow()
command! CmdLineExecToEnd        call ExecuteToEndCodeBlock()
command! CmdLineNextCell         call ToNextCodeBlock()
command! CmdLinePrevCell         call ToLastCodeBlock()

" <Plug> mappings for the same entry points, so users can bind their own keys
" (e.g. `nmap <buffer> <F5> <Plug>(cmdline-exec-cell)`) instead of hardcoding
" ":call Func()<CR>". Built with <Cmd> rather than plain ":...<CR>" so a count
" typed before the key (e.g. "3<key>") reaches the function as v:count/
" v:count1 instead of Vim silently rewriting it into a ".,.+2" cmdline range
" and invoking the function once per line in that range.
nnoremap <silent> <Plug>(cmdline-exec-cell)           <Cmd>call ExecuteCurrentCodeBlock()<CR>
nnoremap <silent> <Plug>(cmdline-exec-cell-jump-next) <Cmd>call ExecuteCurrentCodeBlockJumpNext()<CR>
nnoremap <silent> <Plug>(cmdline-exec-all-cells)      <Cmd>call ExecuteAllCodeBlocks()<CR>
nnoremap <silent> <Plug>(cmdline-exec-all-cells-below) <Cmd>call ExecuteAllCodeBlocksBelow()<CR>
nnoremap <silent> <Plug>(cmdline-exec-to-end)         <Cmd>call ExecuteToEndCodeBlock()<CR>
nnoremap <silent> <Plug>(cmdline-next-cell)           <Cmd>call ToNextCodeBlock()<CR>
nnoremap <silent> <Plug>(cmdline-prev-cell)           <Cmd>call ToLastCodeBlock()<CR>

" Default mappings
" Key-mapping prefix. By default ',' prefixes all cmdline actions. Set
" g:cmdline_default_keybindings = 1 to use the original '<LocalLeader>' prefix.
if get(g:, 'cmdline_default_keybindings', 0)
    let s:p = '<LocalLeader>'
else
    let s:p = ','
endif

if !exists("g:cmdline_map_start")
    let g:cmdline_map_start = s:p . "s"
endif
if !exists("g:cmdline_map_send")
    let g:cmdline_map_send = "<Space>"
endif
if !exists("g:cmdline_map_send_and_stay")
    let g:cmdline_map_send_and_stay = s:p . "<Space>"
endif
if !exists("g:cmdline_map_source_fun")
    let g:cmdline_map_source_fun = s:p . "f"
endif
if !exists("g:cmdline_map_send_paragraph")
    let g:cmdline_map_send_paragraph = s:p . "p"
endif
if !exists("g:cmdline_map_send_block")
    let g:cmdline_map_send_block = s:p . "b"
endif
if !exists("g:cmdline_map_quit")
    let g:cmdline_map_quit = s:p . "q"
endif
if !exists("g:cmdline_map_exec_block")
    let g:cmdline_map_exec_block = s:p . "c"
endif
if !exists("g:cmdline_map_exec_block_and_jump")
    let g:cmdline_map_exec_block_and_jump = s:p . "n"
endif
if !exists("g:cmdline_map_exec_to_end")
    let g:cmdline_map_exec_to_end = s:p . "e"
endif
if !exists("g:cmdline_map_next_block")
    let g:cmdline_map_next_block = s:p . "]"
endif
if !exists("g:cmdline_map_prev_block")
    let g:cmdline_map_prev_block = s:p . "["
endif
if !exists("g:cmdline_map_notebook_toggle")
    let g:cmdline_map_notebook_toggle = s:p . "k"
endif
if !exists("g:cmdline_map_notebook_clear")
    let g:cmdline_map_notebook_clear = s:p . "K"
endif
if !exists("g:cmdline_map_notebook_output")
    let g:cmdline_map_notebook_output = s:p . "o"
endif
if !exists("g:cmdline_map_notebook_interrupt")
    let g:cmdline_map_notebook_interrupt = s:p . "i"
endif
unlet s:p

" Notebook mode (Neovim only, opt-in via g:cmdline_notebook_enable). When the
" gate below is false, none of the commands/functions/highlights are defined
" and the inert get(b:, 'cmdline_notebook', 0) guards keep classic behavior.
if has('nvim') && g:cmdline_notebook_enable
    " Notebook output highlight groups. The content groups are overridable
    " links; the border defaults to dark blue but can be set with
    " g:cmdline_notebook_border_color (a #rrggbb hex, a cterm color number, or
    " a full :highlight argument string). Re-applied on ColorScheme because
    " :colorscheme clears highlight groups.
    function! s:CmdLineNotebookHl()
        hi default link CmdlineNotebookStdout Normal
        hi default link CmdlineNotebookStderr WarningMsg
        hi default link CmdlineNotebookError  ErrorMsg
        hi default link CmdlineNotebookResult Identifier
        hi default link CmdlineNotebookPrompt Comment
        hi default link CmdlineNotebookOk     DiagnosticOk
        if exists('g:cmdline_notebook_border_color') && !empty(g:cmdline_notebook_border_color)
            let l:c = g:cmdline_notebook_border_color
            if l:c =~? '^#[a-f0-9]\{6}$'
                exe 'hi CmdlineNotebookBorder guifg=' . l:c
            elseif l:c =~# '^[0-9]\+$'
                exe 'hi CmdlineNotebookBorder ctermfg=' . l:c
            else
                exe 'hi CmdlineNotebookBorder ' . l:c
            endif
        elseif &t_Co == 256
            hi default CmdlineNotebookBorder ctermfg=25 guifg=#005faf
        else
            hi default CmdlineNotebookBorder ctermfg=darkblue guifg=#005faf
        endif
    endfunction
    call s:CmdLineNotebookHl()
    augroup CmdLineNotebookHl
        autocmd!
        autocmd ColorScheme * call s:CmdLineNotebookHl()
    augroup END

    " Line range of the cell under the cursor (after the separator above to the
    " line before the next separator, or end of buffer).
    function! s:NotebookCellRange()
        let l:start = LastCodeBlock() + 1
        let l:next = NextCodeBlock()
        let l:end = l:next == 0 ? line('$') : l:next - 1
        return [l:start, l:end]
    endfunction

    " Guarded enable, shared by the toggle and :CmdLineNotebookStart. The
    " b:cmdline_notebook flag is set only AFTER the checks pass, so a refusal
    " (no app, live REPL) cannot leave a stale flag/statusline behind.
    function! s:NotebookEnable()
        if !exists("b:cmdline_app")
            echohl WarningMsg | echomsg 'europa: notebook mode is not supported for this filetype.' | echohl Normal
            return
        endif
        if has_key(g:cmdline_job, b:cmdline_filetype) && g:cmdline_job[b:cmdline_filetype] != 0
            echohl WarningMsg | echomsg 'europa: quit the running REPL (' . g:cmdline_map_quit . ') before enabling notebook mode.' | echohl Normal
            return
        endif
        let b:cmdline_notebook = 1
        call VimCmdLineStartApp()
    endfunction

    function! VimCmdLineNotebookToggle()
        if get(b:, 'cmdline_notebook', 0)
            let b:cmdline_notebook = 0
            call v:lua.require'vimcmdline.notebook'.stop(bufnr('%'))
            echomsg 'europa: notebook mode off'
            return
        endif
        call s:NotebookEnable()
    endfunction

    function! VimCmdLineNotebookStart()
        if get(b:, 'cmdline_notebook', 0)
            return
        endif
        call s:NotebookEnable()
    endfunction

    function! VimCmdLineNotebookClear()
        let l:r = s:NotebookCellRange()
        call v:lua.require'vimcmdline.notebook'.clear_cell(bufnr('%'), l:r[0], l:r[1])
    endfunction

    function! VimCmdLineNotebookOpenOutput()
        let l:r = s:NotebookCellRange()
        call v:lua.require'vimcmdline.notebook'.open_output(bufnr('%'), l:r[0], l:r[1])
    endfunction

    command! CmdLineNotebookToggle     call VimCmdLineNotebookToggle()
    " Through the same guards as the toggle: the old inline `let b:...=1 |
    " StartApp` bypassed the running-REPL check, attaching a kernel while the
    " classic REPL still ran (silently diverting every send to the kernel).
    command! CmdLineNotebookStart      call VimCmdLineNotebookStart()
    command! CmdLineNotebookStop       call v:lua.require'vimcmdline.notebook'.stop(bufnr('%'))
    command! CmdLineNotebookRestart    call v:lua.require'vimcmdline.notebook'.restart(bufnr('%'))
    command! CmdLineNotebookInterrupt  call v:lua.require'vimcmdline.notebook'.interrupt(bufnr('%'))
    command! CmdLineNotebookClear      call VimCmdLineNotebookClear()
    command! CmdLineNotebookClearAll   call v:lua.require'vimcmdline.notebook'.clear_all_output(bufnr('%'))
    command! CmdLineNotebookOpenOutput call VimCmdLineNotebookOpenOutput()

    " Change the inline-figure display size live: width in columns, optional
    " height in rows (omitted/0 = keep the image's aspect ratio). Figures
    " already on screen are re-transmitted and redrawn at the new size.
    let s:fig_watch_suppress = 0
    function! VimCmdLineNotebookFigureSize(width, ...) abort
        let l:w = str2nr(a:width)
        if l:w <= 0
            echohl WarningMsg | echomsg 'europa: usage :CmdLineNotebookFigureSize {width} [{height}]' | echohl Normal
            return
        endif
        " Suppress the var watchers while setting both values, then refresh
        " once (avoids a transient resize between the two assignments).
        let s:fig_watch_suppress = 1
        let g:cmdline_notebook_figure_size = l:w
        let g:cmdline_notebook_figure_rows = a:0 > 0 ? str2nr(a:1) : 0
        let s:fig_watch_suppress = 0
        call v:lua.require'vimcmdline.notebook'.refresh_figures()
    endfunction
    command! -nargs=+ CmdLineNotebookFigureSize call VimCmdLineNotebookFigureSize(<f-args>)

    " Re-transmit every retained figure at its current size — restores plots
    " the terminal evicted from its graphics memory (blank rectangles).
    command! CmdLineNotebookFigureRefresh call v:lua.require'vimcmdline.notebook'.retransmit_figures()

    " Also react to direct `let g:cmdline_notebook_figure_*` assignments so
    " the options behave live without the command. Refresh is idempotent:
    " figures whose geometry does not change are left untouched.
    function! s:CmdLineNotebookFigureWatch(...) abort
        if !s:fig_watch_suppress
            call v:lua.require'vimcmdline.notebook'.refresh_figures()
        endif
    endfunction
    silent! call dictwatcheradd(g:, 'cmdline_notebook_figure_size', function('s:CmdLineNotebookFigureWatch'))
    silent! call dictwatcheradd(g:, 'cmdline_notebook_figure_rows', function('s:CmdLineNotebookFigureWatch'))
    silent! call dictwatcheradd(g:, 'cmdline_notebook_figure_cell_aspect', function('s:CmdLineNotebookFigureWatch'))

    " Statusline segment: empty unless notebook mode is on for this buffer.
    " A plain b: read — the segment string is PUSHED by the Lua side whenever
    " the kernel state changes. The previous implementation ran one or two
    " luaeval() string-compiles inside every statusline redraw (i.e. on every
    " cursor move in a notebook buffer).
    function! VimCmdLineNotebookStatus() abort
        return get(b:, 'cmdline_nb_status', '')
    endfunction

    " Add the segment to the statusline (default on). A statusline manager such
    " as vim-airline owns &statusline and overwrites it, so we also register an
    " airline section below; the plain &statusline append covers everyone else.
    if g:cmdline_notebook_statusline
        if &statusline !~# 'VimCmdLineNotebookStatus'
            if empty(&statusline)
                let &statusline = '%<%f %h%m%r%=%-14.(%l,%c%V%) %P'
            endif
            let &statusline .= '%{VimCmdLineNotebookStatus()}'
        endif

        " vim-airline: append the segment to a section on every (re)init,
        " idempotently (airline rebuilds the section, so re-add when missing).
        function! s:CmdLineAirlineInit() abort
            let l:var = 'airline_section_' . get(g:, 'cmdline_notebook_airline_section', 'x')
            let l:seg = '%{VimCmdLineNotebookStatus()}'
            if stridx(get(g:, l:var, ''), l:seg) < 0
                let g:{l:var} = get(g:, l:var, '') . l:seg
            endif
        endfunction
        augroup CmdLineAirline
            autocmd!
            autocmd User AirlineAfterInit call s:CmdLineAirlineInit()
        augroup END
    endif
endif
