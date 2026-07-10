# europa

[![CI](https://github.com/xuesoso/europa/actions/workflows/ci.yml/badge.svg)](https://github.com/xuesoso/europa/actions/workflows/ci.yml)
![version](https://img.shields.io/badge/version-2.5.1-blue)
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

Plots are drawn **inline in the cell output** via the kitty graphics protocol
(works over tmux and SSH), or in **[plotty]**'s tmux pane (sixel/kitty) —
europa itself stays terminal-only. It is built on top of
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

  - **Notebook mode by default** (Neovim + Python) — run `# %%` cells through a
    Jupyter kernel and see text output inline, in a rounded, colorable box
    ([details](#notebook-mode-neovim--python)).
  - **Inline image output** — matplotlib **and plotly** figures render inline
    under the cell via the kitty graphics protocol, and keep working **over SSH
    and inside tmux** ([details](#inline-figures-kitty-graphics)).
  - **Runaway-output guard** — a cell that floods output cannot grow memory or
    stutter the editor; output is capped and elided with an exact marker
    ([details](#runaway-output-protection)).
  - **Live column/key completion** — in notebook mode, feed pandas DataFrame
    columns and dict keys from the running kernel into [blink.cmp]
    ([details](#column--key-completion)).
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

## Quick start (inline images)

Notebook mode is **on by default** on Neovim, so for Python there is nothing to
enable — open a file, write a `# %%` cell, and press `,c`. For **inline
figures** you need a terminal with kitty-graphics *virtual placement* support
(**kitty** or **ghostty** — see
[terminal compatibility](#terminal-compatibility-for-inline-figures); on other
terminals figures fall back to the plotty pane or a text note automatically)
and, if you use tmux, one setting:

```vim
" ~/.vimrc / init.vim
set termguicolors                 " required for inline figures
" let cmdline_notebook_python = '/path/to/venv/bin/python'  " only to override $PATH python3
" let cmdline_notebook_enable = 0                           " opt out: classic REPL only
```

```tmux
# ~/.tmux.conf — only if you work inside tmux (≥ 3.3)
set -g allow-passthrough on
```

Install the kernel once with `pip install jupyter_client ipykernel`, then run
`:checkhealth europa` to confirm. Inline images work **over SSH** with no extra
setup — the escape sequences ride the same connection. Inside tmux they pass
through with the setting above; for **sixel** terminals or **nested tmux**, use
[plotty] (`let cmdline_notebook_figures = 'plotty'`).

## Usage

For **Python on Neovim**, europa treats the file as a notebook: split it into
`# %%` cells and run them through a Jupyter kernel, with each cell's output
shown inline underneath. Running a cell the first time starts the kernel for
you — no `,s`, no manual toggle. (Other languages — and Python, if you start a
REPL with `,s` first — use the *same keys* to send code to an interpreter
instead; see [Notebook mode](#notebook-mode-neovim--python).)

Cells are delimited by a separator line, `# %%` by default (the Jupyter/VSCode
convention; a markdown cell is `# %% [markdown]`). Set it with `cmdline_block_sep`.

In **Normal mode**:

  - `,c` — run the current cell (starts the kernel the first time).
  - `,n` — run the current cell and jump to the next.
  - `,e` — run from the cursor to the end of the cell.
  - `,]` / `,[` — jump to the next / previous cell.
  - `<Space>` — send the current line (and move down).
  - `,<Space>` — send the current line, keeping the cursor put.
  - `,p` — send to the end of the paragraph.
  - `,b` — send the block between the two closest marks.
  - `,f` — send the whole file.
  - `,i` — interrupt the running cell (e.g. to stop a runaway loop).
  - `,K` — clear the current cell's output; `,o` — open its full output in a popup.
  - `,z` — collapse all code (presentation view): every non-markdown cell folds
    to one line, leaving `# %% [markdown]` cells and the rendered outputs
    visible; press again to restore.
  - `,k` — toggle notebook mode; `,s` — start a classic REPL; `,q` — quit it.

In **Visual mode**, `<Space>` sends the selection.

`<Space>`, the paragraph/block/file keys, and the Visual send route to the
**kernel** while notebook mode is active for the buffer and to the **REPL**
otherwise. `,p`, `,b`, `,f`, and the Visual send apply to languages that can
source chunks of code (Python among them).

> The default prefix is `,`. Set `let cmdline_default_keybindings = 1` to use the
> original `<LocalLeader>` prefix instead. Every mapping is individually
> remappable — see [Key mappings](#key-mappings).

## Notebook mode (Neovim & Python)

Notebook mode is **on by default** on Neovim for Python: the code in a buffer is
treated like the cells of a Jupyter notebook, each cell run by a **headless
[Jupyter] kernel** with its **text output shown inline, directly under the
cell** in a rounded box instead of in a separate terminal. Matplotlib figures
render **inline in the same output box** by default (kitty graphics — see
[Inline figures](#inline-figures-kitty-graphics)); set
`cmdline_notebook_figures = 'plotty'` to route them to **[plotty]**'s tmux pane
instead (sixel/kitty, works over SSH). It is Neovim-only and (for now)
Python-only.

**Prefer a classic REPL?** Start one with `,s` before running any cell — a live
REPL takes over the buffer's send and cell keys, so notebook mode stays out of
the way. To turn the feature off entirely, set `let cmdline_notebook_enable = 0`
in your vimrc; the plugin then behaves exactly like classic vimcmdline.

### Requirements

| Component | Status | Install |
|---|---|---|
| Neovim ≥ 0.10 | required | — |
| [`jupyter_client`] + [`ipykernel`] (a **Jupyter kernel**) | **required** | `pip install jupyter_client ipykernel` |
| [plotty] (terminal image display) | **optional** | `pip install plotty` (needs `tmux` ≥ 3.4 + a sixel/kitty terminal) |
| [blink.cmp] (live column/key completion) | optional | via your plugin manager |

The Jupyter kernel is what executes your code and returns structured output.
plotty is only needed if you want plots rendered in the terminal — without it,
text output still works and image output is simply skipped. Run
`:checkhealth europa` to verify what's available.

### Using it

Notebook mode is on by default and needs **no extra configuration**: as long as
the `python3` on your `$PATH` — e.g. the interpreter of the virtualenv or conda
env you launched Neovim from — has `jupyter_client` and `ipykernel` installed,
just open a Python buffer and run a cell (`,c`) and the kernel starts
automatically. `,k` toggles it by hand. The statusline shows ` ⏳ kernel` while
starting and ` ● kernel` once ready.

You only need to set anything if you want a **different** interpreter than the
environment's `python3`, or to turn the feature off entirely — otherwise skip
this:

```vim
" Optional — ONLY to override the environment's python3 (e.g. a specific venv
" whose python has jupyter_client + ipykernel):
let cmdline_notebook_python = '/path/to/venv/bin/python'
" Classic REPL only (disable notebook mode):
" let cmdline_notebook_enable = 0
```

All the cell and send keys — `,c` / `,n` / `,e`, `<Space>`, Visual `<Space>`,
`,p` / `,b` / `,f` — run through the kernel while notebook mode is active (see
[Usage](#usage) for the full list), plus the notebook-only keys `,K` (clear the
cell's output), `,o` (open its full output in a popup), and `,i` (interrupt the
running cell).

Each executed cell is marked with `✓ [N]` (or `✗ [N]` on error), where `N` is
the kernel execution count — embedded in the output box's top border, or shown
as a single rule line (`─── ✓ [N] ───`) for cells with no output, so they still
show that they ran. Disable with `cmdline_notebook_exec_marker = 0`.

### Inline figures (kitty graphics)

**By default**, both **matplotlib** and **plotly** figures are drawn **inside
the cell's output box** using the kitty graphics protocol (the same
Unicode-placeholder mechanism as plotty's kitty renderer, so it survives tmux
and SSH). This needs a terminal that implements kitty-graphics **virtual
placements** — **kitty** or **ghostty**; see
[terminal compatibility](#terminal-compatibility-for-inline-figures) — plus
`:set termguicolors`. Adjust or change the routing in your vimrc:

```vim
let cmdline_notebook_figures     = 'inline'   " default ('plotty' = tmux pane, 'none' = off)
let cmdline_notebook_figure_size = 50     " WIDTH in terminal columns
let cmdline_notebook_figure_rows = 0      " HEIGHT in rows; 0 = keep the image's aspect ratio
let cmdline_notebook_figure_dpi  = 200    " render resolution
let cmdline_notebook_kitty_terms = ['kitty', 'ghostty']  " terminal names treated as kitty-capable
```

**Plotly** works alongside matplotlib with no extra configuration: in inline
mode europa points plotly's default renderer at its static **`png`** renderer,
so `fig.show()` (or a bare figure as the last line of a cell) lands in the same
output box. This needs [`kaleido`] (plotly's static-image engine) and
`nbformat` importable in the kernel's Python — both ship with a normal Jupyter
install. If either is missing, europa leaves plotly's renderer untouched (so
plotly behaves exactly as it would outside europa) and matplotlib is unaffected.
`cmdline_notebook_figure_dpi` drives the **source resolution of both backends**:
it is matplotlib's dpi, and it also sets plotly's render scale to `dpi / 100`
(matplotlib's baseline dpi), so the default `200` renders plotly at 2× its
native 700×500. On-screen size is still governed by `cmdline_notebook_figure_size`.

Width and height are **separate** settings: `cmdline_notebook_figure_size` is
the width (columns) and `cmdline_notebook_figure_rows` is the height (rows; `0`
derives it from the figure's aspect ratio). To set both at once — and live —
use `:CmdLineNotebookFigureSize {width} [{height}]` (see below); the single
variable does not take a `width height` pair.

Inline uses the kitty protocol only. **For sixel**, or to display images in
**nested tmux**, route figures to [plotty]'s dedicated tmux pane instead:

```vim
let cmdline_notebook_figures = 'plotty'   " sixel or kitty, in a tmux pane
```

| Figure display | Protocol | In tmux | Nested tmux | Over SSH | SSH + tmux |
|---|---|---|---|---|---|
| **Inline** (default) | kitty only | ✅ (`allow-passthrough on`) | ❌ | ✅ | ✅ |
| **[plotty] pane** | sixel *or* kitty | ✅ (tmux required) | ✅ (sixel only) | ✅ | ✅ |

> **⚠ Not on kitty or ghostty?** europa detects the terminal at kernel start
> and figures fall back automatically — to the [plotty] pane, or to a
> `[figure not displayed: …]` note — never raw escape data. See the
> compatibility table below. Nested tmux carries images only over **sixel**,
> so it needs the plotty pane too. `:checkhealth europa` reports what your
> setup supports.

#### Terminal compatibility for inline figures

Inline display uses a specific **subset** of the kitty graphics protocol:
*virtual placements* (`U=1`) with **Unicode placeholder** cells. The
placeholders are plain text living in Neovim `virt_lines`, which is what lets
figures sit inside the output box, survive scrolling and redraws, and pass
through tmux — but far fewer terminals implement this subset than the base
protocol. "Speaks kitty graphics" is **not** sufficient:

| Terminal | Inline figures | Figures still work via |
|---|---|---|
| **kitty** | ✅ | — |
| **Ghostty** | ✅ | — |
| **WezTerm** | ❌ base kitty protocol only, no virtual placements | [plotty] pane (sixel) |
| **Konsole** | ❌ partial kitty protocol, no placeholders | [plotty] pane (sixel) |
| **iTerm2** | ❌ own image protocol | [plotty] pane (sixel) |
| **foot** | ❌ sixel only | [plotty] pane |
| **xterm** | ❌ sixel only (when enabled) | [plotty] pane |
| **Alacritty**, **Terminal.app** | ❌ no terminal graphics | text note only |

europa detects which case you are in at kernel start — inside tmux it asks
tmux for the **attached client's** terminal (`#{client_termname}`), so
re-attaching from a different terminal is judged by what is actually attached;
otherwise it checks `KITTY_WINDOW_ID`/`GHOSTTY_*` and `TERM` (forwarded by
ssh) — and **falls back automatically**: to the plotty pane when inside tmux
with [plotty] installed for the kernel's python, else to a
`[figure not displayed: …]` note. Two overrides:

```vim
" A terminal that ships virtual-placement support the default list cannot
" know about (REPLACES the list; matched as substrings):
let cmdline_notebook_kitty_terms = ['kitty', 'ghostty', 'myterm']
" Skip the detection entirely and force inline:
let cmdline_notebook_figures = 'inline'
```

Figure size can be changed **live**: `:CmdLineNotebookFigureSize {width}
[{height}]` (height in rows; omit it to keep the image's aspect ratio)
re-transmits every figure already on screen at the new size and redraws it —
text output is untouched. Assigning `g:cmdline_notebook_figure_size` /
`g:cmdline_notebook_figure_rows` / `g:cmdline_notebook_figure_cell_aspect`
directly has the same effect.

`,o` (`:CmdLineNotebookOpenOutput`) on a cell with a figure shows a **larger
version of the plot** in the output popup (sized to ~85% of the editor width,
same rendered resolution), alongside the cell's full text output; it is freed
when the popup closes.

Terminals cap their graphics memory (kitty: ~320MB, oldest images evicted), so
after many large plots the **oldest figures can turn into blank rectangles**.
The PNGs are retained on the editor side — run `:CmdLineNotebookFigureRefresh`
to re-transmit them at their current size. Figures are sent in
**cursor-priority order** (other buffers first, then the current buffer,
nearest-to-cursor last), so when the retained set is *larger than the
terminal's quota* the figures around your cursor are the ones that survive —
the terminal physically cannot hold more than its quota, so far-away figures
blank out first. To keep everything visible at once, lower
`cmdline_notebook_figure_dpi`, use smaller figures, or clear cells you no
longer need (`,K` / `:CmdLineNotebookClearAll`).

Requirements for inline: a terminal with kitty-graphics **virtual placement**
support (**kitty**, **ghostty** — see the
[compatibility table](#terminal-compatibility-for-inline-figures) above),
`:set termguicolors`, and inside
tmux ≥ 3.3 `set -g allow-passthrough on`. Sixel cannot be used here — it cannot
be anchored to buffer cells, which is
exactly why plotty renders sixel in a dedicated pane. **Nested tmux is not
supported** (the passthrough envelope survives only one tmux hop); europa
detects nesting, warns once at kernel start, and shows a text note instead of
a blank figure — use `cmdline_notebook_figures = 'plotty'` there (plotty's
sixel pane works in nested tmux with `terminal-features ',*:sixel'` on both
layers). When inline display is unavailable for any reason the cell shows a
text note instead. Check `:checkhealth europa`.

You don't have to toggle notebook mode on by hand: any cell-exec command
(`ExecCell`, `ExecCellJumpNext`, `ExecAllCells`, `ExecAllCellsBelow`)
auto-enables it and starts the kernel when the feature is on, the filetype has
an interpreter, and no classic REPL is already running (a live REPL wins). If
notebook mode is already on but no kernel is attached (never started, stopped,
or crashed), the same commands start one before sending; cells submitted while
it boots are queued and run once ready. Repeated exec commands — including
key-repeat — never launch a second kernel.

Commands: `:CmdLineNotebookToggle`, `:CmdLineNotebookStart`,
`:CmdLineNotebookStop`, `:CmdLineNotebookRestart`, `:CmdLineNotebookInterrupt`,
`:CmdLineNotebookClear`, `:CmdLineNotebookClearAll`,
`:CmdLineNotebookOpenOutput` (opens the cell's full retained output in a
read-only floating popup — `q` or `<Esc>` closes it; use a split instead with
`cmdline_notebook_output_win`), and `:CmdLineNotebookCollapse` (`,z`).

`:CmdLineNotebookCollapse` toggles a **presentation view**: every non-markdown
cell's code folds down to a single line (the `# %%` separator with its title
and a hidden-line count), while `# %% [markdown]` cells and the rendered
inline outputs stay visible — the buffer reads like a report. The lines that
anchor output boxes stay unfolded wherever they actually are (outputs anchor
to the line the cell ended on when it ran); cells with no output fold
entirely. Folds track edits; run it twice to refresh after adding cells. Your
window's own fold settings (`'foldmethod'`, `'foldtext'`, …) are restored
when toggled off.

### Runaway output protection

A cell that floods output — the classic `while True: print(True)` — cannot
grow memory or stutter the editor: each cell **retains at most
`cmdline_notebook_max_kept_lines` lines of output** (default `10000`). When a
cell overflows the cap, europa keeps the **first half** (how the output
started) and the **last half** (what it is doing now), with an exact marker at
the elision point:

```
P1
P2
···
··· 184332 lines elided ···
···
P199999
P200000
```

What you'll see when it triggers:

  - a one-time warning suggesting `,i` (`:CmdLineNotebookInterrupt`) to stop
    the cell;
  - the inline box renders normally (it was already capped at
    `cmdline_notebook_max_lines` for display — retention additionally bounds
    what is *kept*);
  - `,o` shows the retained output with the marker at the elision point, the
    elided count in the **popup title**, and a footer note at the **end** of
    the buffer — so the truncation is visible without scrolling to the middle.

Figures are never elided. Redraw cost while a cell streams is flat regardless
of how much output has accumulated. Tune or disable in your vimrc:

```vim
let cmdline_notebook_max_kept_lines = 10000  " default; lines kept per cell
let cmdline_notebook_max_kept_lines = 0      " unlimited (pre-2.x behavior:
                                             " memory grows with the output)
```

### Column & key completion

In notebook mode, europa can feed completions from the **running kernel** into
[blink.cmp]. Because the kernel introspects the *live* namespace, it suggests
things a static analyzer cannot know — most usefully **pandas DataFrame columns**
and **dict keys** (`df["price"]`, `d['key']`), plus names bound in earlier cells.

It is wired as a blink source and is **active only while a notebook kernel is
running** in the current Python buffer. In plain REPL mode, or with notebook mode
off, it is inert and needs no Jupyter kernel. It fires **only inside string
subscripts** (`df["…`, `.loc["…`, `groupby("…`); attribute and method completion
is left to your LSP, which carries signatures and docstrings, so there are no
duplicate suggestions. Completions are fetched asynchronously, so typing is never
blocked.

Register the source with [blink.cmp]:

```lua
require('blink.cmp').setup({
  sources = {
    default = { 'kernel', 'lsp', 'path' },
    providers = {
      kernel = { name = 'kernel', module = 'vimcmdline.notebook.blink_source' },
    },
  },
})
```

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
| `cmdline_map_notebook_collapse` | `,z` | Toggle presentation view: fold all code cells, show only markdown cells + rendered outputs (`:CmdLineNotebookCollapse`) |
| `cmdline_map_notebook_interrupt` | `,i` | Interrupt the running cell (`:CmdLineNotebookInterrupt`) — e.g. to stop a runaway loop |

```vim
" Example: keep the original <LocalLeader> bindings, but remap one action
let cmdline_default_keybindings = 1
let cmdline_map_exec_block      = '<F5>'
```

Cell execution/navigation is also reachable as commands and `<Plug>` mappings,
so you don't have to hardcode `:call Func()<CR>` to bind your own keys:

| Command | `<Plug>` mapping | Action |
|---|---|---|
| `:CmdLineExecCell` | `<Plug>(cmdline-exec-cell)` | Execute the current cell |
| `:CmdLineExecCellJumpNext` | `<Plug>(cmdline-exec-cell-jump-next)` | Execute the current cell, jump to the next |
| `:CmdLineExecAllCells` | `<Plug>(cmdline-exec-all-cells)` | Execute all cells, top to bottom |
| `:CmdLineExecAllCellsBelow` | `<Plug>(cmdline-exec-all-cells-below)` | Execute the current cell and every cell below it |
| `:CmdLineExecToEnd` | `<Plug>(cmdline-exec-to-end)` | Execute from the cursor to the end of the cell |
| `:CmdLineNextCell` | `<Plug>(cmdline-next-cell)` | Jump to the top of the next cell |
| `:CmdLinePrevCell` | `<Plug>(cmdline-prev-cell)` | Jump to the top of the previous cell |

`ExecAllCells` runs every cell top to bottom; `ExecAllCellsBelow` runs the cell
under the cursor and every cell below it. Both skip whitespace-only cells and
restore the cursor when done. Neither has a default key mapping — bind the
`<Plug>` mappings above if you want one.

`NextCell`/`PrevCell` always land on the top of a cell: the line just below
the cell's `# %%` marker, or the top of the buffer for a leading block with
no marker above it. `NextCell` in the last cell settles on that cell's top.

A count prefix (e.g. `3<Plug>(cmdline-next-cell)`) moves/executes N cells for
`ExecCellJumpNext`/`NextCell`/`PrevCell`; `ExecCell`/`ExecToEnd`/`ExecAllCells`/
`ExecAllCellsBelow` always run once regardless of a count, since re-running the
same cells N times would just duplicate their side effects.

### General options

| Variable | Default | Description |
|---|---|---|
| `cmdline_vsplit` | `0` | Split the interpreter window vertically |
| `cmdline_split_topleft` | `0` | Place the vertical split on the top left |
| `cmdline_esc_term` | `1` | Remap `<Esc>` to `:stopinsert` in Neovim's terminal |
| `cmdline_in_buffer` | `1` (Neovim) | Run the interpreter in a Neovim terminal buffer (else tmux) |
| `cmdline_term_height` | `15` | Initial height of the interpreter window/pane |
| `cmdline_term_width` | `40` | Initial width of the interpreter window/pane |
| `cmdline_tmp_dir` | _(private per-session dir)_ | Temp directory for files sourced by the interpreter. The default derives from `tempname()` (unique, mode `0700`, removed on exit); a user-set dir is left in place, with only its `lines.*` interchange files cleaned up |
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
| `cmdline_notebook_enable` | `1` | Master switch (Neovim). When `0`, no notebook commands/maps exist and behavior is classic REPL only |
| `cmdline_notebook_python` | `'python3'` | Python executable that runs the kernel bridge (needs `jupyter_client` + `ipykernel`) |
| `cmdline_notebook_kernel_name` | `'python3'` | Jupyter kernelspec name to launch |
| `cmdline_notebook_plotty` | _(unset)_ | **Legacy** (pre-`figures`). Only read when `cmdline_notebook_figures` is unset: `1` routes figures to the plotty pane, `0` turns figure display off. Prefer `cmdline_notebook_figures` |
| `cmdline_notebook_startup_code` | `[]` | Extra Python lines run once at kernel start |
| `cmdline_notebook_max_lines` | `20` | Inline output line cap per cell (`:CmdLineNotebookOpenOutput` shows the rest) |
| `cmdline_notebook_max_kept_lines` | `10000` | Retention cap per cell: at most this many output lines are kept (first + last halves with a `··· N lines elided ···` marker), so a runaway `while True: print(...)` cannot grow memory or stutter the UI. `0` = unlimited |
| `cmdline_notebook_kernel_timeout` | `30` | Seconds to wait for the kernel to become ready |
| `cmdline_notebook_border` | `'rounded'` | Output box border: `rounded`, `single`, `double`, or `none` |
| `cmdline_notebook_border_color` | `'#005faf'` | Border color: `#rrggbb` hex, a cterm number, or a full `:highlight` spec (default dark blue) |
| `cmdline_notebook_statusline` | `1` | Show a kernel-status segment in `'statusline'` and in vim-airline |
| `cmdline_notebook_airline_section` | `'x'` | vim-airline section to put the kernel status in (`'a'`…`'z'`) |
| `cmdline_notebook_output_win` | `'float'` | `:CmdLineNotebookOpenOutput` window: `'float'` (popup) or `'split'` |
| `cmdline_notebook_exec_marker` | `1` | Mark each executed cell with `✓ [N]` (`✗ [N]` on error) in the output border / as a rule line, where `N` is the execution count |
| `cmdline_notebook_figures` | `'inline'` | Figure routing: `'inline'` (kitty graphics drawn inside the cell output), `'plotty'` (tmux pane), or `'none'`. An explicit legacy `cmdline_notebook_plotty` still wins when this is unset. Setting `'inline'` explicitly skips the terminal detection |
| `cmdline_notebook_kitty_terms` | `['kitty', 'ghostty']` | Terminal-name substrings the inline-figure gate treats as kitty-graphics capable (matched against `$TERM`, or tmux's `#{client_termname}` inside tmux). Setting it **replaces** the list — see [terminal compatibility](#terminal-compatibility-for-inline-figures) |
| `cmdline_notebook_figure_size` | `50` | Inline figure width in terminal columns (capped to the window); applies live |
| `cmdline_notebook_figure_rows` | `0` | Explicit inline figure height in rows; `0` keeps the image's aspect ratio; applies live |
| `cmdline_notebook_figure_dpi` | `200` | Source resolution the kernel renders figures at: matplotlib dpi, and plotly's render scale (`dpi / 100`, so `200` → plotly scale 2×) |
| `cmdline_notebook_figure_cell_aspect` | `2.0` | Terminal cell height/width ratio used to keep the figure's aspect; applies live |

```vim
let cmdline_notebook_enable       = 1
let cmdline_notebook_border       = 'rounded'
let cmdline_notebook_border_color = '#5fafff'      " or 39, or 'guifg=#5fafff gui=bold'
```

The border uses the `CmdlineNotebookBorder` highlight group, so you can also
style it directly (e.g. `hi link CmdlineNotebookBorder FloatBorder`). To
customize plotty (e.g. its pane size), turn europa's own figure routing off
and enable plotty with your options via the startup hook:

```vim
let cmdline_notebook_figures      = 'none'
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
[blink.cmp]: https://github.com/saghen/blink.cmp
[`jupyter_client`]: https://github.com/jupyter/jupyter_client
[`ipykernel`]: https://github.com/ipython/ipykernel
[`kaleido`]: https://github.com/plotly/Kaleido
