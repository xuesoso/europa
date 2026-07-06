" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! HaskellSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.hs")
    call VimCmdLineSendCmd(":load " . l:tmpf)
endfunction

let b:cmdline_nl = "\n"
if executable("stack")
    let b:cmdline_app = "stack ghci"
else
    let b:cmdline_app = "ghci"
endif
let b:cmdline_quit_cmd = ":quit"
let b:cmdline_source_fun = function("HaskellSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "haskell"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("haskell")
