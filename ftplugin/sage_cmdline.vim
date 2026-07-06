" Ensure that plugin/vimcmdline.vim was sourced
if !exists('g:cmdline_job')
    runtime plugin/vimcmdline.vim
endif

function! SageSourceLines(lines)
    call VimCmdLineSendCmd('%cpaste -q')
    " Only the tmux paste-buffer path races the interpreter; a Neovim job
    " channel delivers input in order, so skip the UI-blocking sleep there.
    if !(has('nvim') && get(g:cmdline_job, get(b:, 'cmdline_filetype', 'sage'), 0))
        sleep 100m " Wait for IPython to read stdin
    endif
    call VimCmdLineSendCmd(join(add(a:lines, '--'), b:cmdline_nl))
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = 'sage'
let b:cmdline_quit_cmd = 'exit'
let b:cmdline_source_fun = function('SageSourceLines')
let b:cmdline_send_empty = 1
let b:cmdline_filetype = 'sage'

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'

call VimCmdLineSetApp('sage')
