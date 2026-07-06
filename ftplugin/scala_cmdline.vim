" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! ScalaSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.scala")
    call VimCmdLineSendCmd(':load "' . l:tmpf . '"')
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = "scala"
let b:cmdline_quit_cmd = "sys.exit"
let b:cmdline_source_fun = function("ScalaSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "scala"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("scala")

