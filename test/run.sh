#!/usr/bin/env bash
# Test runner for vimcmdline.
#
#   test/run.sh            # off-path Vimscript tests (always) + bridge test
#   PYTHON=/path/to/python test/run.sh   # use a specific python for the bridge
#
# The bridge test is skipped automatically if jupyter_client/ipykernel are not
# importable by the chosen python.
set -u
cd "$(dirname "$0")/.."

NVIM="${NVIM:-nvim}"
PYTHON="${PYTHON:-python3}"
rc=0

echo "== off-path: notebook disabled =="
"$NVIM" --headless -u NONE -N -c 'let g:cmdline_notebook_enable=0' -S test/offpath.vim || rc=1

echo "== off-path: notebook enabled but not toggled =="
"$NVIM" --headless -u NONE -N -c 'let g:cmdline_notebook_enable=1' -S test/offpath.vim || rc=1

echo "== code-block unit behaviour (regression) =="
"$NVIM" --headless -u NONE -N -S test/codeblock.vim || rc=1

echo "== notebook render: re-run replaces output (regression) =="
"$NVIM" --headless -u NONE -N -l test/render.lua || rc=1

echo "== notebook render: run marker / aborted cell (regression) =="
"$NVIM" --headless -u NONE -N -l test/render_marker.lua || rc=1

echo "== bridge round-trip ($PYTHON) =="
"$PYTHON" test/bridge_test.py || rc=1

if [ "$rc" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$rc"
