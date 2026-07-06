" Ensure that plugin/vimcmdline.vim was sourced
if !exists("g:cmdline_job")
    runtime plugin/vimcmdline.vim
endif

function! JavaScriptSourceLines(lines)
    let l:tmpf = VimCmdLineWriteTmp(a:lines, "lines.js")
    " Need to delete the cache for this tmp file if it exists, otherwise the
    " file won't be loaded again.
    let clear_cache_command = "delete require.cache[require.resolve('" . l:tmpf . "')]; "
    let source_file_command = "require('" . l:tmpf . "');"
    call VimCmdLineSendCmd(clear_cache_command . source_file_command)
endfunction

let b:cmdline_nl = "\n"
let b:cmdline_app = "node"
let b:cmdline_quit_cmd = ".exit"
let b:cmdline_source_fun = function("JavaScriptSourceLines")
let b:cmdline_send_empty = 0
let b:cmdline_filetype = "javascript"

exe 'nmap <buffer><silent> ' . g:cmdline_map_start . ' :call VimCmdLineStartApp()<CR>'


call VimCmdLineSetApp("javascript")
