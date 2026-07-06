" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! OctaveSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.m")
    if b:cmdline_app =~? "^matlab"
        call VimCmdLineSendCmd('run("' . l:tmpf . '"); clear lines.m;')
    else
        call VimCmdLineSendCmd('source("' . l:tmpf . '");')
    endif
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = "octave"
let b:cmdline_quit_cmd = "exit"
let b:cmdline_source_fun = function("OctaveSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "matlab"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("matlab")
