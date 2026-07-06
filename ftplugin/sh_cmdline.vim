" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! ShellSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.sh")
    call VimCmdLineSendCmd(". " . l:tmpf)
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = "sh"
let b:cmdline_quit_cmd = "exit"
let b:cmdline_source_fun = function("ShellSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "sh"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("sh")
