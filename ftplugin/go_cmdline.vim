" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! GoSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.go")
    call VimCmdLineSendCmd(". " . l:tmpf)
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = "gomacro"
let b:cmdline_quit_cmd = ":quit"
let b:cmdline_source_fun = function("GoSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "go"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("go")
