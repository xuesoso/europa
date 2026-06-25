# europa

[![CI](https://github.com/xuesoso/europa/actions/workflows/ci.yml/badge.svg)](https://github.com/xuesoso/europa/actions/workflows/ci.yml)
![version](https://img.shields.io/badge/version-2.0.4-blue)
[![License: GPL v2](https://img.shields.io/badge/License-GPL%20v2-blue.svg)](https://www.gnu.org/licenses/old-licenses/gpl-2.0.en.html)

**europa** runs your code like a Jupyter notebook inside Neovim: split a file
into `# %%` cells, run them through a headless [Jupyter] kernel, and see each
cell's text output rendered **inline, directly under the cell**:

```
╭─────────────╮
│ hello world │
│ 42          │
╰─────────────╯
```

Plots and other images are drawn in the terminal by **[plotty]** (sixel/kitty,
works over SSH) — europa itself stays terminal-only. It is built on top of
[vimcmdline]'s REPL engine, so it is also a plain **send-to-interpreter** plugin
for Clojure, Golang, Haskell, JavaScript, Julia, Jupyter, Lisp, Macaulay2,
Matlab, Prolog, Python, Ruby, Sage, Scala, Shell script, and Swift, in either
[Vim] or [Neovim].

> europa is a fork of [vimcmdline] by Jakson Alves de Aquino, extended with code
> cells, notebook mode, and a comma-prefixed keymap. It keeps vimcmdline's
> `cmdline_*` settings and mappings, so existing configs keep working.
> Licensed GPL-2.0-or-later.

The interpreter may run in a Neovim built-in terminal, an external terminal
emulator, or a tmux pane. Running it in a Neovim terminal colorizes the output
(different colors for general output, numbers, and the prompt).

## Highlights

  - **Notebook mode** — run cells through a Jupyter kernel and see text output
    inline, in a rounded, colorable box ([details](#notebook-mode-neovim--python)).
  - **Code blocks / cells** — execute and navigate `# %%`-delimited cells.
  - **Multi-language REPL** — send lines/paragraphs/files to 18 interpreters.
  - **`,` key prefix** by default; set [`cmdline_default_keybindings`](#key-mappings)
    to keep the original `<LocalLeader>` prefix.

## How to install

Use a plugin manager such as [Vim-Plug], or copy the directories `ftplugin`,
`plugin`, and `syntax` (and, for notebook mode, `lua` and `python`) and their
files to your `~/.vim` or `~/.config/nvim` directory.

```vim
Plug 'xuesoso/europa'
```

## Usage

If you are editing one of the supported file types, in Normal mode do:

  - `,s` to start the interpreter.

  - `<Space>` to send the current line to the interpreter.

  - `,<Space>` to send the current line and keep the cursor on the current line.

  - `,q` to send the quit command to the interpreter.

For languages that can source chunks of code:

  - In Visual mode, press `<Space>` to send the selection.

  - In Normal mode, press:

    - `,p` to send from the current line to the end of the paragraph.

    - `,b` to send the block of code between the two closest marks.

    - `,f` to send the entire file to the interpreter.

> The default key prefix is `,`. To use the original `<LocalLeader>` prefix
> instead, set `let cmdline_default_keybindings = 1` (see [Key mappings](#key-mappings)).
> Every individual mapping can also be remapped — see the options below.

### Code blocks (cells)

Files can be divided into code blocks (also called "cells") delimited by a
separator line, by default `# %%`, matching the convention used by Jupyter and
VSCode (a markdown cell is just `# %% [markdown]`). The separator is set with
`cmdline_block_sep`. For languages that can source chunks of code, the
following Normal-mode mappings operate on these blocks:

  - `,c` to execute the current code block.

  - `,n` to execute the current code block and jump to the next one.

  - `,e` to execute from the current line to the end of the block.

  - `,]` to jump to the next block.

  - `,[` to jump to the previous block.

## Notebook mode (Neovim & Python)

Notebook mode is an optional, toggleable alternative to the REPL transports. In
this mode the code in a buffer is treated like the cells of a Jupyter notebook:
each cell is run by a **headless [Jupyter] kernel** and its **text output is
shown inline, directly under the cell** in a rounded box, instead of in a
separate terminal. Plots and other images are rendered by **[plotty]** in its
own tmux pane (sixel/kitty, works over SSH). The mode is off by default, is
Neovim-only and (for now) Python-only, and does not change any existing
behavior.

### Requirements

| Component | Status | Install |
|---|---|---|
| Neovim ≥ 0.10 | required | — |
| [`jupyter_client`] + [`ipykernel`] (a **Jupyter kernel**) | **required** | `pip install jupyter_client ipykernel` |
| [plotty] (terminal image display) | **optional** | `pip install plotty` (needs `tmux` ≥ 3.4 + a sixel/kitty terminal) |

The Jupyter kernel is what executes your code and returns structured output.
plotty is only needed if you want plots rendered in the terminal — without it,
text output still works and image output is simply skipped. Run
`:checkhealth europa` to verify what's available.

### Enabling and using it

Opt in once in your `vimrc`:

```vim
let cmdline_notebook_enable = 1
" Optional: point at the Python that has jupyter_client / ipykernel / plotty
let cmdline_notebook_python = 'python3'
```

Then, in a Python buffer:

  - `,k` toggles notebook mode on/off (starts/stops the kernel). The statusline
    shows ` ⏳ kernel` while starting and ` ● kernel` once ready.

While notebook mode is on, the cell and send mappings run through the kernel
and render output inline instead of to a REPL:

  - `,c` run the current cell, `,n` run it and jump to the next, `,e` run to the
    end of the cell.
  - `<Space>` / visual `<Space>` / `,p` / `,b` / `,f` also run through the kernel.
  - `,K` clears the output under the current cell; `,o` opens the current
    cell's full output in a popup.

Each executed cell is marked with `✓ [N]` (or `✗ [N]` on error), where `N` is
the kernel execution count — embedded in the output box's top border, or shown
as a single rule line (`─── ✓ [N] ───`) for cells with no output, so they still
show that they ran. Disable with `cmdline_notebook_exec_marker = 0`.

Commands: `:CmdLineNotebookToggle`, `:CmdLineNotebookStart`,
`:CmdLineNotebookStop`, `:CmdLineNotebookRestart`, `:CmdLineNotebookInterrupt`,
`:CmdLineNotebookClear`, `:CmdLineNotebookClearAll`, and
`:CmdLineNotebookOpenOutput` (opens the cell's full, untruncated output in a
read-only floating popup — `q` or `<Esc>` closes it; use a split instead with
`cmdline_notebook_output_win`).

## Options

Set these variables in your `vimrc`. All are optional; defaults are shown. The
settings keep the `cmdline_*` prefix for compatibility with vimcmdline configs.

### Key mappings

`,` is the default prefix for all `<LocalLeader>`-style actions (`<Space>` for
sending lines is unchanged).

| Variable | Default | Action |
|---|---|---|
| `cmdline_default_keybindings` | `0` | When `1`, use the original `<LocalLeader>` prefix instead of `,` |
| `cmdline_map_start` | `,s` | Start the interpreter |
| `cmdline_map_send` | `<Space>` | Send the current line (and move down) / send the visual selection |
| `cmdline_map_send_and_stay` | `,<Space>` | Send the current line, keep the cursor |
| `cmdline_map_source_fun` | `,f` | Send the whole file |
| `cmdline_map_send_paragraph` | `,p` | Send to the end of the paragraph |
| `cmdline_map_send_block` | `,b` | Send the block between the two closest marks |
| `cmdline_map_quit` | `,q` | Send the quit command |
| `cmdline_map_exec_block` | `,c` | Execute the current cell |
| `cmdline_map_exec_block_and_jump` | `,n` | Execute the current cell, jump to the next |
| `cmdline_map_exec_to_end` | `,e` | Execute from the cursor to the end of the cell |
| `cmdline_map_next_block` | `,]` | Jump to the next cell |
| `cmdline_map_prev_block` | `,[` | Jump to the previous cell |
| `cmdline_map_notebook_toggle` | `,k` | Toggle notebook mode |
| `cmdline_map_notebook_clear` | `,K` | Clear the current cell's output (notebook mode) |
| `cmdline_map_notebook_output` | `,o` | Open the current cell's full output in a popup (notebook mode) |

```vim
" Example: keep the original <LocalLeader> bindings, but remap one action
let cmdline_default_keybindings = 1
let cmdline_map_exec_block      = '<F5>'
```

### General options

| Variable | Default | Description |
|---|---|---|
| `cmdline_vsplit` | `0` | Split the interpreter window vertically |
| `cmdline_split_topleft` | `0` | Place the vertical split on the top left |
| `cmdline_esc_term` | `1` | Remap `<Esc>` to `:stopinsert` in Neovim's terminal |
| `cmdline_in_buffer` | `1` (Neovim) | Run the interpreter in a Neovim terminal buffer (else tmux) |
| `cmdline_term_height` | `15` | Initial height of the interpreter window/pane |
| `cmdline_term_width` | `40` | Initial width of the interpreter window/pane |
| `cmdline_tmp_dir` | `/tmp/cmdline_<time>_<user>` | Temp directory for files sourced by the interpreter |
| `cmdline_outhl` | `1` | Syntax-highlight the interpreter output (Neovim) |
| `cmdline_auto_scroll` | `1` | Keep the cursor at the end of the terminal (Neovim) |
| `cmdline_block_sep` | `'# %%'` | Separator line delimiting code blocks/cells |
| `cmdline_app` | _(unset)_ | Dict mapping filetype → interpreter command (see below) |
| `cmdline_external_term_cmd` | _(unset)_ | Run the interpreter in an external terminal (see below) |
| `cmdline_follow_colorscheme` | _(unset)_ | Highlight output with your current `colorscheme` |
| `cmdline_color_*` | _(unset)_ | Per-token output colors (see [Output colors](#output-colors)) |

```vim
let cmdline_vsplit      = 1       " Split the window vertically
let cmdline_split_topleft = 1     " ...and place it on the top left
let cmdline_term_width  = 80      " Initial width of the interpreter pane
let cmdline_block_sep   = '# %%'  " Separator delimiting code blocks
```

You can define which application runs as the interpreter for each supported
file type with the `cmdline_app` dictionary (filetype → command):

```vim
let cmdline_app           = {}
let cmdline_app['python'] = 'ptipython3'
let cmdline_app['ruby']   = 'pry'
let cmdline_app['sh']     = 'bash'
```

### Notebook-mode options

| Variable | Default | Description |
|---|---|---|
| `cmdline_notebook_enable` | `0` | Master switch. When `0`, no notebook commands/maps exist and behavior is unchanged |
| `cmdline_notebook_python` | `'python3'` | Python executable that runs the kernel bridge (needs `jupyter_client` + `ipykernel`) |
| `cmdline_notebook_kernel_name` | `'python3'` | Jupyter kernelspec name to launch |
| `cmdline_notebook_plotty` | `1` | Run `import plotty; plotty.enable()` at kernel start (skipped if plotty is absent) |
| `cmdline_notebook_startup_code` | `[]` | Extra Python lines run once at kernel start |
| `cmdline_notebook_max_lines` | `20` | Inline output line cap per cell (`:CmdLineNotebookOpenOutput` shows the rest) |
| `cmdline_notebook_kernel_timeout` | `30` | Seconds to wait for the kernel to become ready |
| `cmdline_notebook_border` | `'rounded'` | Output box border: `rounded`, `single`, `double`, or `none` |
| `cmdline_notebook_border_color` | `'#005faf'` | Border color: `#rrggbb` hex, a cterm number, or a full `:highlight` spec (default dark blue) |
| `cmdline_notebook_statusline` | `1` | Show a kernel-status segment in `'statusline'` and in vim-airline |
| `cmdline_notebook_airline_section` | `'x'` | vim-airline section to put the kernel status in (`'a'`…`'z'`) |
| `cmdline_notebook_output_win` | `'float'` | `:CmdLineNotebookOpenOutput` window: `'float'` (popup) or `'split'` |
| `cmdline_notebook_exec_marker` | `1` | Mark each executed cell with `✓ [N]` (`✗ [N]` on error) in the output border / as a rule line, where `N` is the execution count |

```vim
let cmdline_notebook_enable       = 1
let cmdline_notebook_border       = 'rounded'
let cmdline_notebook_border_color = '#5fafff'      " or 39, or 'guifg=#5fafff gui=bold'
```

The border uses the `CmdlineNotebookBorder` highlight group, so you can also
style it directly (e.g. `hi link CmdlineNotebookBorder FloatBorder`). To
customize plotty (e.g. its pane size), disable the auto-enable and do it via
the startup hook:

```vim
let cmdline_notebook_plotty       = 0
let cmdline_notebook_startup_code = ['import plotty', 'plotty.enable(size=60)']
```

The status segment (` ⏳ kernel` starting, ` ● kernel` ready, ` ⟳ running +N`
while executing, where `N` is the number of cells queued behind the running one)
works with a plain `'statusline'` and with **vim-airline** automatically — it is added
to `airline_section_x` by default, configurable with
`cmdline_notebook_airline_section`. For a Lua statusline such as lualine, add a
component that calls `vim.fn.VimCmdLineNotebookStatus()` (or
`require('vimcmdline.notebook').status(0)`). Set `cmdline_notebook_statusline = 0`
to place the `VimCmdLineNotebookStatus()` segment entirely yourself.

### Output colors

If you are using Neovim, you can colorize the interpreter output. Each
`cmdline_color_*` option accepts (1) a hex foreground color, (2) an ANSI/cterm
number, or (3) a complete highlighting specification.

```vim
if has('gui_running') || &termguicolors
    let cmdline_color_input    = '#9e9e9e'
    let cmdline_color_normal   = '#00afff'
    let cmdline_color_number   = '#00ffff'
    let cmdline_color_string   = '#5fd7af'
    let cmdline_color_error    = '#ff0000'
    let cmdline_color_warn     = '#c0ffff'
    " ... (see :help vimcmdline_colors for the full set)
elseif &t_Co == 256
    let cmdline_color_input    = 247
    let cmdline_color_normal   =  39
    " ... (cterm numbers for the same set of options)
endif
```

A value can also be a complete highlighting specification, or you can follow
your current `colorscheme`:

```vim
let cmdline_color_error = 'ctermfg=1 ctermbg=15 guifg=#c00000 guibg=#ffffff gui=underline'
let cmdline_follow_colorscheme = 1
```

### External terminal

To run the interpreter in an external terminal emulator, define the command to
run it (`%s` is replaced with the tmux command that runs the REPL):

```vim
let cmdline_external_term_cmd = "gnome-terminal -e '%s'"
let cmdline_external_term_cmd = "xterm -e '%s' &"
```

`gnome-terminal` does not require an `&` at the end because it forks
immediately after startup.

Your `~/.inputrc` should not include `set keymap vi`, because it would cause
some applications to start in vi's edit mode (you would then have to press `a`
or `i` in the interpreter console before using it).

## How to add support for a new language

  1. Copy the script in `ftplugin/` supporting the language closest to the one
     you want, and save it as "filetype\_cmdline.vim" where "filetype" is the
     output of `echo &filetype` when editing a script of that language.

  2. Edit the new script and change the values of its variables as necessary.

  3. Copy the closest script in `syntax/` and save it as "cmdlineoutput\_app.vim"
     where "app" is the interpreter name (for the "matlab" file-type the
     interpreter is "octave").

  4. Edit the new syntax script's patterns for the input line and for errors.

  5. Test by running your application in a Neovim built-in terminal or a tmux
     split pane.

## Development

Run the test suite (off-path Vimscript checks, code-block unit tests, and a
Jupyter-kernel round-trip):

```sh
bash test/run.sh                          # uses python3 + nvim on PATH
PYTHON=/path/to/python NVIM=nvim bash test/run.sh
```

The kernel round-trip is skipped automatically if `jupyter_client`/`ipykernel`
are not installed. CI runs the suite across Python 3.7 → current with the
latest compatible Jupyter kernel for each version.

## Credits & license

europa is maintained by **xuesoso** and is a fork of [vimcmdline] by Jakson
Alves de Aquino, with code cells, notebook mode, and the comma-prefixed keymap
added. Licensed under **GPL-2.0-or-later** (see [LICENSE](LICENSE)).

## See also

Plugins with similar functionality are [vimcmdline] (upstream), [neoterm],
[vim-slime], [iron.nvim], and [repl.nvim].

[vimcmdline]: https://github.com/jalvesaq/vimcmdline
[neoterm]: https://github.com/kassio/neoterm
[Vim]: http://www.vim.org
[Neovim]: https://github.com/neovim/neovim
[Vim-Plug]: https://github.com/junegunn/vim-plug
[vim-slime]: https://github.com/jpalardy/vim-slime
[iron.nvim]: https://github.com/Vigemus/iron.nvim
[repl.nvim]: https://gitlab.com/HiPhish/repl.nvim
[Jupyter]: https://jupyter.org
[plotty]: https://github.com/xuesoso/plotty
[`jupyter_client`]: https://github.com/jupyter/jupyter_client
[`ipykernel`]: https://github.com/ipython/ipykernel
