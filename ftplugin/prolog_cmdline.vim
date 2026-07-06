" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! PrologSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.pl")
    call VimCmdLineSendCmd("consult('" . l:tmpf . "').")
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = "swipl"
let b:cmdline_quit_cmd = "halt."
let b:cmdline_source_fun = function("PrologSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "prolog"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("prolog")
