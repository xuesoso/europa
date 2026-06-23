#!/usr/bin/env python3
"""Round-trip test for python/vimcmdline_kernel_bridge.py.

Drives the bridge as a subprocess over NDJSON and asserts it produces the
expected events for a normal execution and an error. Skipped automatically if
jupyter_client / ipykernel are not importable.

Run directly:   python test/bridge_test.py
Or with pytest: pytest test/bridge_test.py
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRIDGE = os.path.join(ROOT, "python", "vimcmdline_kernel_bridge.py")


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
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.events = queue.Queue()
        self._t = threading.Thread(target=self._reader, daemon=True)
        self._t.start()

    def _reader(self):
        for line in self.p.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                self.events.put(json.loads(line))
            except Exception:
                pass

    def send(self, obj):
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    def wait_for(self, pred, timeout=60):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                ev = self.events.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if pred(ev):
                return ev
        return None

    def collect_cell(self, cell_id, timeout=60):
        """Collect events until the cell is fully done: BOTH the iopub idle
        status and the shell execute_reply have been seen (their relative order
        across channels is not guaranteed)."""
        deadline = time.time() + timeout
        seen = []
        got_idle = False
        got_reply = False
        while time.time() < deadline and not (got_idle and got_reply):
            try:
                ev = self.events.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            seen.append(ev)
            if ev.get("cell_id") == cell_id:
                if ev.get("type") == "status" and ev.get("state") == "idle":
                    got_idle = True
                elif ev.get("type") == "execute_reply":
                    got_reply = True
        return seen

    def close(self):
        try:
            self.send({"type": "shutdown"})
        except Exception:
            pass
        try:
            self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def run():
    d = Driver()
    try:
        d.send({"type": "hello", "startup_code": [], "kernel_name": "python3",
                "timeout": 60})
        assert d.wait_for(lambda e: e.get("type") == "kernel_ready", 60), \
            "kernel never became ready"

        # Normal execution: stdout + result.
        d.send({"type": "execute", "cell_id": 1, "code": "print('hi')\n21 * 2"})
        evs = d.collect_cell(1, 60)
        streams = [e for e in evs if e.get("type") == "stream" and e["cell_id"] == 1]
        results = [e for e in evs if e.get("type") == "execute_result" and e["cell_id"] == 1]
        reply = [e for e in evs if e.get("type") == "execute_reply" and e["cell_id"] == 1]
        assert any("hi" in e.get("text", "") for e in streams), \
            "stdout 'hi' missing: %r" % evs
        assert any("42" in e.get("text", "") for e in results), \
            "result '42' missing: %r" % evs
        assert reply and reply[0]["status"] == "ok", "reply not ok: %r" % reply

        # Error execution: traceback + error reply, ANSI stripped.
        d.send({"type": "execute", "cell_id": 2, "code": "1 / 0"})
        evs = d.collect_cell(2, 60)
        errs = [e for e in evs if e.get("type") == "error" and e["cell_id"] == 2]
        reply = [e for e in evs if e.get("type") == "execute_reply" and e["cell_id"] == 2]
        assert errs and errs[0]["ename"] == "ZeroDivisionError", \
            "ZeroDivisionError missing: %r" % evs
        assert reply and reply[0]["status"] == "error", "error reply missing: %r" % reply
        joined = "".join("".join(e.get("traceback", [])) for e in errs)
        assert "\x1b[" not in joined, "ANSI escapes not stripped from traceback"

        print("ALL BRIDGE TESTS PASSED")
        return 0
    finally:
        d.close()


def test_bridge_roundtrip():
    if not _deps_available():
        import pytest
        pytest.skip("jupyter_client/ipykernel not installed")
    assert run() == 0


if __name__ == "__main__":
    if not _deps_available():
        print("SKIP: jupyter_client/ipykernel not installed")
        sys.exit(0)
    sys.exit(run())
