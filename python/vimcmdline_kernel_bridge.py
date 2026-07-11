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
    {"type":"hello","startup_code":[...],"kernel_name":"python3","timeout":30,
     "inline_images":false,"image_dir":"/tmp/..."}
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
        ... with "image_path","image_w","image_h" added when inline_images is
        on and the payload carried an image/png the bridge saved to image_dir.
    {"type":"error","ename":"...","evalue":"...","traceback":[...],"cell_id":<int>}
    {"type":"execute_reply","status":"ok"|"error","execution_count":<int|null>,"cell_id":<int>}
    {"type":"complete_reply","req_id":<int>,"matches":[...],"cursor_start":<int>,"cursor_end":<int>,"status":"ok"|"error"}
    {"type":"bridge_error","fatal":<bool>,"message":"...","cell_id":<int|null>}
"""

import json
import os
import re
import signal
import sys
import threading
import time
from collections import OrderedDict
from queue import Empty, Queue

# Matches CSI escape sequences (colors etc.) AND OSC sequences (terminated by
# BEL or ST) so output renders as plain text: rich and modern pip emit OSC-8
# hyperlinks, which would otherwise land in the output box as raw "]8;;url"
# garbage around the link text. The link TEXT itself sits between the two OSC
# envelopes and survives the strip. An OSC split across stream chunks can
# leave an unterminated fragment; requiring the terminator keeps the regex
# from eating legitimate text after it.
_ANSI_RE = re.compile(r"\x1b(?:\[[0-9;?]*[ -/]*[@-~]|\][^\x07\x1b]*(?:\x07|\x1b\\))")

# Per-event text cap. The Lua side's retention is line/byte based on what
# arrives; a single print('x' * 10**9) is ONE event, and forwarding it verbatim
# would balloon both processes before retention can elide anything.
_MAX_TEXT = 1 << 20

_stdout_lock = threading.Lock()


def strip_ansi(text):
    return _ANSI_RE.sub("", text or "")


def cap_text(text):
    """Bound one event's text; keeps the head with an explicit marker."""
    if len(text) <= _MAX_TEXT:
        return text
    return (text[:_MAX_TEXT]
            + "\n··· [europa: %d bytes truncated] ···\n" % (len(text) - _MAX_TEXT))


def text_repr(data, has_image):
    """The text/plain repr of a result/display data bundle — or, when the
    bundle carries NO text/plain, an explicit note naming the mimetypes it
    does carry. An HTML-only repr must never render as silent nothing: that
    is the worst read-out failure mode (the user concludes "no output").
    Image-bearing bundles are exempt — the figure pipeline displays those."""
    text = data.get("text/plain", "")
    if text or not data or has_image:
        return text
    return "[no text representation: %s]" % ", ".join(sorted(data))


def png_size(data):
    """(width, height) from a PNG IHDR header, or None. (From plotty.)"""
    import struct
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", data[16:24])


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
        # Inline figures: when on, image/png display_data payloads are decoded
        # and written to image_dir; the event carries the file path + pixel
        # size instead of shipping pixels through NDJSON.
        self.inline_images = False
        self.image_dir = None
        self._image_seq = 0
        # parent msg_id -> cell_id; only the kernel thread touches this.
        self._cell_by_msgid = OrderedDict()
        # Cells whose execute_reply already arrived: moved out of the live map
        # (so it cannot evict a still-running cell at the 500 cap) but kept
        # resolvable for a while, since iopub traffic (the trailing idle
        # status) can race past the shell reply across the two sockets.
        self._done_by_msgid = OrderedDict()
        # parent msg_id -> completion req_id (for complete_request round-trips).
        self._complete_by_msgid = OrderedDict()
        # Coalescing buffer for consecutive same-target stream chunks within
        # one drain pass: [name, [texts], cell_id, nbytes] or None.
        self._pending_stream = None
        # Kernel liveness probe throttle (see kernel_loop).
        self._last_alive_check = 0.0
        self._req_q = Queue()
        self._stop = threading.Event()
        # Wakeup pipe: the stdin thread pokes the kernel thread out of its
        # channel poll the moment a request arrives, so dispatch latency is
        # bounded by the pipe (~0) instead of the poll timeout (~50ms).
        self._wake_r, self._wake_w = os.pipe()
        os.set_blocking(self._wake_w, False)
        # zmq poller over both channel sockets + the wakeup pipe. Built lazily
        # (and rebuilt after restart) by _poll_channels; None => try to build,
        # False => unavailable, fall back to the timeout-based drain.
        self._poller = None

    # -- threads ---------------------------------------------------------

    def _wake(self):
        try:
            os.write(self._wake_w, b"\0")
        except (BlockingIOError, OSError):
            pass  # pipe full = a wakeup is already pending; that is enough

    def stdin_loop(self):
        """Read NDJSON requests from stdin and enqueue them. EOF => shutdown."""
        try:
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
                self._wake()
        finally:
            # stdin closed (Neovim went away) OR the reader died on an
            # exception: either way, ask the kernel thread to shut down —
            # without this a reader crash left the bridge + kernel running
            # forever with nothing reading stdin.
            self._req_q.put({"type": "shutdown"})
            self._wake()

    def _check_kernel_alive(self):
        """Fatal-error out when the kernel process died (segfault/OOM-kill):
        the zmq sockets just go quiet in that case, no reply ever arrives, and
        the Lua side would show 'busy' forever. Throttled to ~1/s."""
        now = time.monotonic()
        if now - self._last_alive_check < 1.0:
            return True
        self._last_alive_check = now
        try:
            if self.km is None or self.km.is_alive():
                return True
        except Exception:
            return True  # cannot probe: do not fabricate a death
        emit({"type": "bridge_error", "fatal": True,
              "message": "kernel process died unexpectedly", "cell_id": None})
        self._stop.set()
        return False

    def kernel_loop(self):
        """Single owner of the kernel client: dispatch requests + poll channels."""
        try:
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

                # Sleep until a channel has traffic or a request arrives
                # (wakeup pipe), then drain everything currently available on
                # both channels without blocking.
                self._wait_traffic()
                if not self._check_kernel_alive():
                    break
                self._drain(self.kc.get_iopub_msg, self._handle_iopub)
                self._drain(self.kc.get_shell_msg, self._handle_shell)
        finally:
            # Plain fallthrough would skip kernel shutdown when anything above
            # raises (or SIGTERM's SystemExit lands); a finally never does.
            self._do_shutdown()

    def _build_poller(self):
        """zmq poller over both channel sockets + the wakeup pipe, or False
        when the socket internals are not available (fall back to timed
        drains). Rebuilt after (re)start since channel sockets can change."""
        if os.name != "posix":
            return False  # zmq cannot poll a pipe fd on Windows
        try:
            import zmq
            iopub = self.kc.iopub_channel.socket
            shell = self.kc.shell_channel.socket
            if iopub is None or shell is None:
                return False
            poller = zmq.Poller()
            poller.register(iopub, zmq.POLLIN)
            poller.register(shell, zmq.POLLIN)
            poller.register(self._wake_r, zmq.POLLIN)
            return poller
        except Exception as exc:
            log("zmq poller unavailable, using timed polls:", exc)
            return False

    def _wait_traffic(self):
        """Block until one of {iopub, shell, request pipe} is readable."""
        if self._poller is None:
            self._poller = self._build_poller()
        if self._poller is False:
            # Fallback: the pre-poller behaviour (adds up to ~50ms latency).
            self._drain_first(self.kc.get_iopub_msg, self._handle_iopub)
            return
        try:
            self._poller.poll(250)
        except Exception as exc:
            if not self._stop.is_set():
                log("poll failed, falling back to timed polls:", exc)
            self._poller = False  # permanent fallback; avoids a busy loop
            return
        # Swallow pending wakeup bytes; the request queue is drained by the
        # caller's next loop iteration.
        try:
            os.set_blocking(self._wake_r, False)
            while os.read(self._wake_r, 4096):
                pass
        except (BlockingIOError, OSError):
            pass

    def _drain_first(self, getter, handler):
        """Fallback-only: block briefly for one message, used when no poller."""
        try:
            handler(getter(timeout=0.05))
        except Empty:
            return
        except Exception as exc:
            if not self._stop.is_set():
                log("channel poll error:", exc)

    def _drain(self, getter, handler):
        # Drain whatever is available right now without blocking. Buffered
        # stream chunks are flushed when the pass ends so coalescing never
        # delays output beyond the current batch.
        while not self._stop.is_set():
            try:
                handler(getter(timeout=0))
            except Empty:
                break
            except Exception as exc:
                if not self._stop.is_set():
                    log("channel drain error:", exc)
                # A getter that raises without consuming the socket event
                # would otherwise make _wait_traffic return immediately and
                # spin this loop at full CPU with unbounded stderr spam.
                time.sleep(0.05)
                break
        self._flush_stream()

    # -- stream coalescing -------------------------------------------------
    # Consecutive stream chunks for the same (name, cell) within one drain
    # pass merge into a single event: one json.dumps + write + downstream
    # vim.json.decode/render call instead of one per print(). Any other event
    # type flushes first, so relative ordering is preserved.

    def _buffer_stream(self, name, text, cell_id):
        p = self._pending_stream
        if p is not None and p[0] == name and p[2] == cell_id:
            p[1].append(text)
            p[3] += len(text)
        else:
            self._flush_stream()
            self._pending_stream = [name, [text], cell_id, len(text)]
        if self._pending_stream[3] > _MAX_TEXT:
            self._flush_stream()

    def _flush_stream(self):
        p = self._pending_stream
        if p is None:
            return
        self._pending_stream = None
        text = "".join(p[1])
        if "\x1b" in text:
            text = strip_ansi(text)
        emit({"type": "stream", "name": p[0], "text": cap_text(text),
              "cell_id": p[2]})

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
            # The one kernel call that had no guard: an interrupt_kernel()
            # exception here would unwind kernel_loop for a non-fatal event.
            if self.km is not None:
                try:
                    self.km.interrupt_kernel()
                except Exception as exc:
                    emit({"type": "bridge_error", "fatal": False,
                          "message": "interrupt failed: %s" % exc,
                          "cell_id": None})
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
        self.inline_images = bool(req.get("inline_images"))
        self.image_dir = req.get("image_dir") or None
        try:
            from jupyter_client import KernelManager
        except Exception as exc:
            emit({"type": "bridge_error", "fatal": True,
                  "message": "jupyter_client not importable: %s"
                             " — install with: pip install jupyter_client"
                             " ipykernel" % exc,
                  "cell_id": None})
            self._stop.set()
            return
        try:
            self.km = KernelManager(kernel_name=self.kernel_name)
            # The kernel child must NOT inherit our stdout: that fd carries
            # protocol NDJSON, and a user cell spawning a subprocess would
            # write raw bytes straight onto it. Route the kernel's stdout to
            # our stderr instead; fall back for provisioners that reject
            # Popen kwargs.
            try:
                self.km.start_kernel(stdout=sys.stderr.fileno())
            except TypeError:
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
        self._poller = None  # (re)build over the fresh channel sockets
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
        self._done_by_msgid.clear()
        self._complete_by_msgid.clear()
        self._pending_stream = None
        self._poller = None  # channel sockets may have changed across restart
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

    def _save_png(self, b64, cell_id):
        """Decode a base64 image/png payload to image_dir; returns
        (path, width, height) or None. Never raises."""
        try:
            import base64
            png = base64.standard_b64decode(b64)
            size = png_size(png)
            if not size:
                return None
            os.makedirs(self.image_dir, exist_ok=True)
            self._image_seq += 1
            path = os.path.join(self.image_dir,
                                "vcl_fig_%d_%d.png" % (cell_id, self._image_seq))
            with open(path, "wb") as f:
                f.write(png)
            return path, size[0], size[1]
        except Exception as exc:
            log("saving inline image failed:", exc)
            return None

    def _cell_for(self, parent_id):
        cell_id = self._cell_by_msgid.get(parent_id)
        if cell_id is None:
            cell_id = self._done_by_msgid.get(parent_id)
        return cell_id

    def _clean_text(self, text):
        # ANSI colour escapes render as literal garbage in the inline box
        # (rich/colorama/pip output) and pollute the Lua width/highlight
        # caches; '\r' survives for the renderer's progress-bar collapse.
        if "\x1b" in text:
            text = strip_ansi(text)
        return cap_text(text)

    def _handle_iopub(self, msg):
        parent = msg.get("parent_header", {}).get("msg_id")
        cell_id = self._cell_for(parent)
        if cell_id is None:
            return  # not one of our tracked cells (startup, autosave, etc.)
        mtype = msg.get("msg_type") or msg.get("header", {}).get("msg_type")
        content = msg.get("content", {})
        if mtype == "stream":
            self._buffer_stream(content.get("name", "stdout"),
                                content.get("text", ""), cell_id)
            return
        # Any other event flushes buffered stream chunks first so per-cell
        # ordering (stream before result/error/status) is preserved.
        self._flush_stream()
        if mtype == "status":
            emit({"type": "status",
                  "state": content.get("execution_state"),
                  "cell_id": cell_id})
        elif mtype == "execute_result":
            data = content.get("data", {})
            emit({"type": "execute_result",
                  "text": self._clean_text(text_repr(data, False)),
                  "execution_count": content.get("execution_count"),
                  "cell_id": cell_id})
        elif mtype == "display_data":
            data = content.get("data", {})
            has_image = any(k.startswith("image/") for k in data)
            ev = {"type": "display_data",
                  "text": self._clean_text(text_repr(data, has_image)),
                  "has_image": has_image,
                  "cell_id": cell_id}
            if self.inline_images and self.image_dir and "image/png" in data:
                saved = self._save_png(data["image/png"], cell_id)
                if saved:
                    ev["image_path"], ev["image_w"], ev["image_h"] = saved
            emit(ev)
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
            self._flush_stream()
            emit({"type": "execute_reply",
                  "status": content.get("status"),
                  "execution_count": content.get("execution_count"),
                  "cell_id": cell_id})
            # Retire the finished cell from the live map so the 500-entry cap
            # can never evict a still-RUNNING cell behind a deep queue. Keep
            # it briefly resolvable: the trailing iopub idle status can arrive
            # after the shell reply (separate sockets, no cross-ordering).
            if self._cell_by_msgid.pop(parent, None) is not None:
                self._done_by_msgid[parent] = cell_id
                while len(self._done_by_msgid) > 50:
                    self._done_by_msgid.popitem(last=False)


def main():
    # Undecodable bytes on the line protocol must never kill a loop or drop an
    # event: a UnicodeEncodeError raised inside a drain handler is swallowed
    # there, silently losing the event (an execute_reply lost that way leaves
    # the cell 'busy' forever on the Lua side).
    try:
        sys.stdin.reconfigure(errors="replace")
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(errors="replace")
    except Exception:
        pass
    bridge = Bridge()
    # jobstop() SIGTERMs the bridge ~300ms after the graceful shutdown request;
    # if the kernel thread is still blocked in wait_for_ready (up to
    # kernel_timeout) that request was never dispatched. Turn SIGTERM into
    # SystemExit so kernel_loop's finally still runs _do_shutdown() and the
    # kernel is not orphaned (non-ipykernel kernels have no parent poller).
    try:
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    except Exception:
        pass
    reader = threading.Thread(target=bridge.stdin_loop, daemon=True)
    reader.start()
    bridge.kernel_loop()


if __name__ == "__main__":
    main()
