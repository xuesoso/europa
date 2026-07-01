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

echo "== notebook render: re-run refreshes inline output (regression) =="
"$NVIM" --headless -u NONE -N -l test/render_rerun.lua || rc=1

echo "== notebook render: perf benchmark + output correctness =="
"$NVIM" --headless -u NONE -N -l test/bench_render.lua || rc=1

echo "== inline figures: kitty encoder unit + plotty golden comparison =="
"$NVIM" --headless -u NONE -N -l test/image_test.lua || rc=1

echo "== inline figures: end-to-end (kernel + matplotlib) =="
BENCH_PYTHON="$PYTHON" "$NVIM" --headless -u NONE -N -l test/figures_e2e.lua || rc=1

echo "== bridge round-trip ($PYTHON) =="
"$PYTHON" test/bridge_test.py || rc=1

echo "== bridge latency/throughput benchmark ($PYTHON) =="
"$PYTHON" test/bench_bridge.py || rc=1

echo "== end-to-end latency benchmark =="
BENCH_PYTHON="$PYTHON" "$NVIM" --headless -u NONE -N -l test/bench_e2e.lua || rc=1

if [ "$rc" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
fi
exit "$rc"
