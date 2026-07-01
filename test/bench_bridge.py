#!/usr/bin/env python3
"""Latency + throughput benchmark for python/vimcmdline_kernel_bridge.py.

Drives the bridge as a subprocess over NDJSON against a real kernel and
measures the paths a user feels:

  dispatch   keypress -> first event: time from writing an execute request to
             the first event for that cell arriving back (dominated by the
             bridge's request pickup + event pickup latency, since the kernel
             work for `pass` is ~1ms).
  reply      keypress -> execute_reply for the same trivial cell.
  flood      one cell printing LINES lines: wall time to reply, plus how many
             stream events the bridge emitted (fewer = better coalescing, less
             downstream JSON/render work at identical content).
  run-all    CELLS trivial cells submitted back-to-back: time to last reply.

Correctness is asserted (reply status ok, flood content complete) so a speedup
that drops or corrupts output fails the bench. Skipped when jupyter_client /
ipykernel are missing.

Run:  python test/bench_bridge.py
"""
import json
import os
import queue
import statistics
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "python", "vimcmdline_kernel_bridge.py")

DISPATCH_REPS = 30
FLOOD_LINES = 3000
RUNALL_CELLS = 50


def _deps_available():
    try:
        import jupyter_client  # noqa: F401
        import ipykernel  # noqa: F401
        return True
    except Exception:
        return False


class Driver:
    def __init__(self, python=sys.executable):
        self.p = subprocess.Popen(
            [python, BRIDGE],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self.events = queue.Queue()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.events.put((time.perf_counter(), json.loads(line)))
            except Exception:
                pass

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def wait_for(self, pred, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                ts, ev = self.events.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if pred(ev):
                return ts, ev
        return None, None

    def drain_cell(self, cell_id, timeout=90):
        """Collect events until BOTH idle status and execute_reply for cell_id."""
        deadline = time.time() + timeout
        seen, idle, reply = [], False, False
        while time.time() < deadline and not (idle and reply):
            try:
                ts, ev = self.events.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            seen.append((ts, ev))
            if ev.get("cell_id") == cell_id:
                if ev.get("type") == "status" and ev.get("state") == "idle":
                    idle = True
                elif ev.get("type") == "execute_reply":
                    reply = True
        return seen

    def close(self):
        try:
            self.send({"type": "shutdown"})
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def pctl(vals, p):
    vals = sorted(vals)
    return vals[min(int(len(vals) * p), len(vals) - 1)]


def run():
    d = Driver()
    fails = []
    try:
        d.send({"type": "hello", "startup_code": [], "kernel_name": "python3",
                "timeout": 60})
        ts, _ = d.wait_for(lambda e: e.get("type") == "kernel_ready", 90)
        assert ts, "kernel never became ready"

        # -- dispatch / reply latency ------------------------------------
        firsts, replies = [], []
        for i in range(DISPATCH_REPS):
            cid = 1000 + i
            t0 = time.perf_counter()
            d.send({"type": "execute", "cell_id": cid, "code": "pass"})
            got_first = None
            for ts_ev, ev in d.drain_cell(cid):
                if ev.get("cell_id") != cid:
                    continue
                if got_first is None:
                    got_first = ts_ev
                if ev.get("type") == "execute_reply":
                    if ev.get("status") != "ok":
                        fails.append("dispatch rep %d reply status %r" % (i, ev.get("status")))
                    replies.append((ts_ev - t0) * 1e3)
            if got_first is not None:
                firsts.append((got_first - t0) * 1e3)

        # -- stream flood --------------------------------------------------
        cid = 2000
        t0 = time.perf_counter()
        d.send({"type": "execute", "cell_id": cid,
                "code": "for i in range(%d):\n    print('line', i)" % FLOOD_LINES})
        evs = d.drain_cell(cid, timeout=180)
        t_flood = (time.perf_counter() - t0) * 1e3
        stream_evs = [e for _, e in evs
                      if e.get("type") == "stream" and e.get("cell_id") == cid]
        text = "".join(e.get("text", "") for e in stream_evs)
        nlines = text.count("\n")
        if nlines != FLOOD_LINES:
            fails.append("flood line count %d != %d" % (nlines, FLOOD_LINES))
        if not text.startswith("line 0\n"):
            fails.append("flood first line wrong")
        if ("line %d\n" % (FLOOD_LINES - 1)) not in text[-40:]:
            fails.append("flood last line wrong")

        # -- run-all -------------------------------------------------------
        t0 = time.perf_counter()
        for i in range(RUNALL_CELLS):
            d.send({"type": "execute", "cell_id": 3000 + i, "code": "x_%d = %d" % (i, i)})
        # Wait until the LAST cell has both reply and idle.
        d.drain_cell(3000 + RUNALL_CELLS - 1, timeout=180)
        t_runall = (time.perf_counter() - t0) * 1e3

        print("----------------------------------------------------------")
        print("dispatch  exec -> first event   median %7.1f ms   p90 %7.1f ms" %
              (statistics.median(firsts), pctl(firsts, 0.9)))
        print("reply     exec -> execute_reply median %7.1f ms   p90 %7.1f ms" %
              (statistics.median(replies), pctl(replies, 0.9)))
        print("flood     %d printed lines:   %8.1f ms   (%d stream events)" %
              (FLOOD_LINES, t_flood, len(stream_evs)))
        print("run-all   %d cells:            %8.1f ms" % (RUNALL_CELLS, t_runall))
        print("----------------------------------------------------------")

        for f in fails:
            print("FAIL " + f)
        if fails:
            return 1
        print("BENCH-BRIDGE OK")
        return 0
    finally:
        d.close()


if __name__ == "__main__":
    if not _deps_available():
        print("SKIP: jupyter_client/ipykernel not installed")
        sys.exit(0)
    sys.exit(run())
