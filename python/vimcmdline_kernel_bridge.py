#!/usr/bin/env python3
# europa notebook mode. Maintainer: xuesoso <xuesoso@gmail.com>.
# Part of europa (a fork of vimcmdline). Licensed GPL-2.0-or-later.
"""europa notebook-mode kernel bridge.

Drives a headless Jupyter (ipykernel) kernel via ``jupyter_client`` and speaks
newline-delimited JSON (NDJSON) on stdin/stdout so the Neovim Lua side can run
code cells and receive their text output.

IMPORTANT: only protocol JSON is ever written to stdout (one object per line).
All diagnostics go to stderr. A single thread (the "kernel thread") owns every
interaction with the kernel client; a separate thread only reads stdin and
enqueues requests. This keeps all zmq socket access single-threaded.

Requests (stdin, one JSON object per line):
    {"type":"hello","startup_code":[...],"kernel_name":"python3","timeout":30}
    {"type":"execute","cell_id":<int>,"code":"<source>"}
    {"type":"complete","req_id":<int>,"code":"<source>","cursor_pos":<int>}
    {"type":"interrupt"}
    {"type":"restart"}
    {"type":"shutdown"}

``cursor_pos`` is a 0-based offset in Unicode codepoints into ``code``; the
reply's ``cursor_start``/``cursor_end`` are codepoint offsets in the same units.

Events (stdout, one JSON object per line):
    {"type":"kernel_ready"}
    {"type":"status","state":"busy"|"idle","cell_id":<int>}
    {"type":"stream","name":"stdout"|"stderr","text":"...","cell_id":<int>}
    {"type":"execute_result","text":"...","execution_count":<int|null>,"cell_id":<int>}
    {"type":"display_data","text":"...","has_image":<bool>,"cell_id":<int>}
    {"type":"error","ename":"...","evalue":"...","traceback":[...],"cell_id":<int>}
    {"type":"execute_reply","status":"ok"|"error","execution_count":<int|null>,"cell_id":<int>}
    {"type":"complete_reply","req_id":<int>,"matches":[...],"cursor_start":<int>,"cursor_end":<int>,"status":"ok"|"error"}
    {"type":"bridge_error","fatal":<bool>,"message":"...","cell_id":<int|null>}
"""

import json
import re
import sys
import threading
from collections import OrderedDict
from queue import Empty, Queue

# Matches CSI escape sequences (colors etc.) so tracebacks render as plain text.
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")

_stdout_lock = threading.Lock()


def strip_ansi(text):
    return _ANSI_RE.sub("", text or "")


def emit(obj):
    """Write one protocol event to stdout (thread-safe)."""
    line = json.dumps(obj, ensure_ascii=False)
    with _stdout_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(*args):
    print("[vimcmdline-bridge]", *args, file=sys.stderr, flush=True)


class Bridge:
    def __init__(self):
        self.km = None
        self.kc = None
        self.kernel_name = "python3"
        self.timeout = 30
        self.startup_code = []
        # parent msg_id -> cell_id; only the kernel thread touches this.
        self._cell_by_msgid = OrderedDict()
        # parent msg_id -> completion req_id (for complete_request round-trips).
        self._complete_by_msgid = OrderedDict()
        self._req_q = Queue()
        self._stop = threading.Event()

    # -- threads ---------------------------------------------------------

    def stdin_loop(self):
        """Read NDJSON requests from stdin and enqueue them. EOF => shutdown."""
        for raw in iter(sys.stdin.readline, ""):
            raw = raw.strip()
            if not raw:
                continue
            try:
                req = json.loads(raw)
            except Exception as exc:  # malformed line, ignore
                log("bad request json:", exc)
                continue
            self._req_q.put(req)
        # stdin closed (Neovim went away): ask the kernel thread to shut down.
        self._req_q.put({"type": "shutdown"})

    def kernel_loop(self):
        """Single owner of the kernel client: dispatch requests + poll channels."""
        while not self._stop.is_set():
            if self.kc is None:
                # Wait (blocking) for the hello that starts the kernel.
                try:
                    req = self._req_q.get(timeout=0.5)
                except Empty:
                    continue
                if not self._dispatch(req):
                    break
                continue

            # Kernel is live: drain any pending requests without blocking.
            try:
                while True:
                    if not self._dispatch(self._req_q.get_nowait()):
                        self._stop.set()
                        break
            except Empty:
                pass
            if self._stop.is_set():
                break

            # Drain everything currently available on both channels.
            self._drain(self.kc.get_iopub_msg, self._handle_iopub)
            self._drain(self.kc.get_shell_msg, self._handle_shell)

        self._do_shutdown()

    def _drain(self, getter, handler):
        # Block briefly for the first message, then drain the rest non-blocking
        # so a chatty cell does not lag one message per loop iteration.
        try:
            handler(getter(timeout=0.05))
        except Empty:
            return
        except Exception as exc:
            if not self._stop.is_set():
                log("channel poll error:", exc)
            return
        while not self._stop.is_set():
            try:
                handler(getter(timeout=0))
            except Empty:
                return
            except Exception:
                return

    # -- request dispatch ------------------------------------------------

    def _dispatch(self, req):
        rtype = req.get("type")
        if rtype == "hello":
            self._handle_hello(req)
        elif rtype == "execute":
            self._do_execute(req.get("cell_id"), req.get("code", ""))
        elif rtype == "complete":
            self._do_complete(req)
        elif rtype == "interrupt":
            if self.km is not None:
                self.km.interrupt_kernel()
        elif rtype == "restart":
            self._do_restart()
        elif rtype == "shutdown":
            return False
        else:
            log("unknown request type:", rtype)
        return True

    def _handle_hello(self, req):
        if self.kc is not None:
            return
        self.startup_code = req.get("startup_code", []) or []
        self.kernel_name = req.get("kernel_name", "python3") or "python3"
        self.timeout = req.get("timeout", 30) or 30
        try:
            from jupyter_client import KernelManager
        except Exception as exc:
            emit({"type": "bridge_error", "fatal": True,
                  "message": "jupyter_client not importable: %s" % exc,
                  "cell_id": None})
            self._stop.set()
            return
        try:
            self.km = KernelManager(kernel_name=self.kernel_name)
            self.km.start_kernel()
            self.kc = self.km.client()
            self.kc.start_channels()
            self.kc.wait_for_ready(timeout=self.timeout)
        except Exception as exc:
            emit({"type": "bridge_error", "fatal": True,
                  "message": "kernel failed to start: %s" % exc,
                  "cell_id": None})
            self._stop.set()
            return
        # Submit startup BEFORE announcing ready: the kernel executes requests
        # FIFO, so startup (e.g. plotty.enable()) always runs before user cells.
        self._submit_startup()
        emit({"type": "kernel_ready"})

    def _submit_startup(self):
        if not self.startup_code:
            return
        code = "\n".join(self.startup_code)
        try:
            # Untracked + silent: its iopub/shell messages resolve to cell None
            # and are dropped, so startup never renders inline.
            self.kc.execute(code, silent=True, store_history=False,
                            allow_stdin=False)
        except Exception as exc:
            log("startup submit failed:", exc)

    def _do_execute(self, cell_id, code):
        try:
            msg_id = self.kc.execute(code, store_history=True, allow_stdin=False)
        except Exception as exc:
            emit({"type": "bridge_error", "fatal": False,
                  "message": "execute failed: %s" % exc, "cell_id": cell_id})
            return
        self._cell_by_msgid[msg_id] = cell_id
        while len(self._cell_by_msgid) > 500:
            self._cell_by_msgid.popitem(last=False)

    def _do_complete(self, req):
        # A code/cursor_pos completion request (Jupyter complete_request). The
        # reply, matched back to req_id, carries the kernel's own completions —
        # including IPython runtime completions such as DataFrame/dict keys.
        req_id = req.get("req_id")
        code = req.get("code", "")
        cursor_pos = req.get("cursor_pos")
        if cursor_pos is None:
            cursor_pos = len(code)
        if self.kc is None:
            emit({"type": "complete_reply", "req_id": req_id, "matches": [],
                  "cursor_start": cursor_pos, "cursor_end": cursor_pos,
                  "status": "error"})
            return
        try:
            msg_id = self.kc.complete(code, cursor_pos)
        except Exception as exc:
            emit({"type": "complete_reply", "req_id": req_id, "matches": [],
                  "cursor_start": cursor_pos, "cursor_end": cursor_pos,
                  "status": "error"})
            log("complete failed:", exc)
            return
        self._complete_by_msgid[msg_id] = req_id
        while len(self._complete_by_msgid) > 200:
            self._complete_by_msgid.popitem(last=False)

    def _do_restart(self):
        if self.km is None:
            return
        try:
            self.km.restart_kernel(now=True)
            self.kc.wait_for_ready(timeout=self.timeout)
        except Exception as exc:
            emit({"type": "bridge_error", "fatal": True,
                  "message": "restart failed: %s" % exc, "cell_id": None})
            self._stop.set()
            return
        self._cell_by_msgid.clear()
        self._complete_by_msgid.clear()
        self._submit_startup()
        emit({"type": "kernel_ready"})

    def _do_shutdown(self):
        try:
            if self.kc is not None:
                self.kc.stop_channels()
        except Exception:
            pass
        try:
            if self.km is not None:
                self.km.shutdown_kernel(now=True)
        except Exception:
            pass

    # -- message handling ------------------------------------------------

    def _cell_for(self, parent_id):
        return self._cell_by_msgid.get(parent_id)

    def _handle_iopub(self, msg):
        parent = msg.get("parent_header", {}).get("msg_id")
        cell_id = self._cell_for(parent)
        if cell_id is None:
            return  # not one of our tracked cells (startup, autosave, etc.)
        mtype = msg.get("msg_type") or msg.get("header", {}).get("msg_type")
        content = msg.get("content", {})
        if mtype == "status":
            emit({"type": "status",
                  "state": content.get("execution_state"),
                  "cell_id": cell_id})
        elif mtype == "stream":
            emit({"type": "stream",
                  "name": content.get("name", "stdout"),
                  "text": content.get("text", ""),
                  "cell_id": cell_id})
        elif mtype == "execute_result":
            data = content.get("data", {})
            emit({"type": "execute_result",
                  "text": data.get("text/plain", ""),
                  "execution_count": content.get("execution_count"),
                  "cell_id": cell_id})
        elif mtype == "display_data":
            data = content.get("data", {})
            emit({"type": "display_data",
                  "text": data.get("text/plain", ""),
                  "has_image": any(k.startswith("image/") for k in data),
                  "cell_id": cell_id})
        elif mtype == "error":
            emit({"type": "error",
                  "ename": content.get("ename", ""),
                  "evalue": content.get("evalue", ""),
                  "traceback": [strip_ansi(t) for t in content.get("traceback", [])],
                  "cell_id": cell_id})
        # execute_input / clear_output / comm_* are ignored for v1.

    def _handle_shell(self, msg):
        parent = msg.get("parent_header", {}).get("msg_id")
        mtype = msg.get("msg_type") or msg.get("header", {}).get("msg_type")
        content = msg.get("content", {})
        # complete_reply is not tied to a cell; route it via its own msgid map
        # BEFORE the cell lookup, otherwise it is dropped as an untracked reply.
        if mtype == "complete_reply":
            req_id = self._complete_by_msgid.pop(parent, None)
            if req_id is None:
                return
            emit({"type": "complete_reply",
                  "req_id": req_id,
                  "matches": content.get("matches", []),
                  "cursor_start": content.get("cursor_start"),
                  "cursor_end": content.get("cursor_end"),
                  "status": content.get("status", "ok")})
            return
        cell_id = self._cell_for(parent)
        if cell_id is None:
            return
        if mtype == "execute_reply":
            emit({"type": "execute_reply",
                  "status": content.get("status"),
                  "execution_count": content.get("execution_count"),
                  "cell_id": cell_id})


def main():
    bridge = Bridge()
    reader = threading.Thread(target=bridge.stdin_loop, daemon=True)
    reader.start()
    bridge.kernel_loop()


if __name__ == "__main__":
    main()
