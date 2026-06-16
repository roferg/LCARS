"""The LCARS serve daemon — Python 3 stdlib only (http.server), no build step.

Serves:
  GET /                     the static read-only Kanban board (static/index.html)
  GET /<asset>              static front-end assets (board.js, lcars.css, …)
  GET /api/board            the full adapter-neutral board JSON (board.py shape)
  GET /api/mission/<id>     mission detail incl. the activity feed
  GET /api/events           a live channel (Server-Sent Events) that pushes ONE
                            update whenever mission state changes on disk

Read-only — there are NO write endpoints this session; any non-GET is rejected.
The renderer/front end depends only on the board shape, never on which adapter
served it (ADR-003) — the adapter is injected here.
"""
import json
import os
import posixpath
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "static")
STATIC_DIR = os.path.normpath(STATIC_DIR)

# Where the shared LCARS token stylesheet lives (docs/lcars.css at the repo root,
# two levels up from this module: web/lcars_serve/ → web/ → repo/). We share it
# rather than fork the palette (ADR-007).
_REPO_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
_SHARED_CSS = os.path.join(_REPO_ROOT, "docs", "lcars.css")

_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
}


def make_server(adapter, host="127.0.0.1", port=8765, poll_interval=1.0):
    """Build (do not start) the daemon bound to `adapter`. Caller serves it."""
    handler = _build_handler(adapter, poll_interval)

    class _Server(ThreadingHTTPServer):
        daemon_threads = True

        def __init__(self, *a, **kw):
            ThreadingHTTPServer.__init__(self, *a, **kw)
            self._lcars_stop = threading.Event()

        def shutdown(self):
            self._lcars_stop.set()   # release any in-flight SSE poll loops
            ThreadingHTTPServer.shutdown(self)

    httpd = _Server((host, port), handler)
    return httpd


def _build_handler(adapter, poll_interval):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):  # silence default stderr noise
            pass

        # -- only GET is allowed (read-only board) ---------------------------
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/api/board":
                return self._json(adapter.board())
            if path.startswith("/api/mission/"):
                mid = path[len("/api/mission/"):]
                detail = adapter.mission(mid)
                if detail is None:
                    return self._error(404, "no such mission")
                return self._json(detail)
            if path == "/api/events":
                return self._sse()
            return self._static(path)

        def _reject(self):
            self._error(405, "read-only: only GET is supported")

        do_POST = _reject
        do_PUT = _reject
        do_DELETE = _reject
        do_PATCH = _reject

        # -- JSON + error helpers --------------------------------------------
        def _json(self, obj):
            body = json.dumps(obj).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _error(self, code, msg):
            body = json.dumps({"error": msg}).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        # -- static assets ----------------------------------------------------
        def _static(self, path):
            if path in ("/", ""):
                path = "/index.html"
            # the shared token stylesheet is served from docs/lcars.css (ADR-007)
            if path == "/lcars.css":
                return self._send_file(_SHARED_CSS, ".css")
            # safe-join under STATIC_DIR; reject traversal.
            rel = posixpath.normpath(path).lstrip("/")
            target = os.path.normpath(os.path.join(STATIC_DIR, rel))
            if not target.startswith(STATIC_DIR) or not os.path.isfile(target):
                return self._error(404, "not found")
            ext = os.path.splitext(target)[1]
            return self._send_file(target, ext)

        def _send_file(self, target, ext):
            try:
                with open(target, "rb") as fh:
                    body = fh.read()
            except OSError:
                return self._error(404, "not found")
            self.send_response(200)
            self.send_header("Content-Type",
                             _CONTENT_TYPES.get(ext, "application/octet-stream"))
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        # -- the live channel: SSE, one push per state change -----------------
        def _sse(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            # Emit ONE initial frame, then exactly one frame per LOGICAL state
            # change. A single logical change (e.g. filing a mission) writes
            # several files — state.json, estimate.json, events.jsonl, … — and
            # those writes land across more than one poll tick. Pushing on every
            # differing tick produced a storm (~4 `update`s for one filing).
            #
            # Coalesce with a QUIET-PERIOD debounce: when the fingerprint moves,
            # hold the push until the fingerprint has been stable for a quiet
            # window (`quiet`). Any further change inside the window restarts the
            # window — so a burst of writes that keeps moving the fingerprint
            # collapses to ONE `update` carrying the settled value, while two
            # genuinely separate changes a quiet window apart still emit two
            # pushes. The window must exceed the inter-write gap of a burst; it's
            # a small multiple of the poll interval, floored so a fast test poll
            # (50ms) still spans a realistic multi-file write burst.
            quiet = max(poll_interval * 3.0, 0.3)
            try:
                last = adapter.fingerprint()
                self._sse_send("ready", last)
                stop = getattr(self.server, "_lcars_stop", None)
                pending = None      # latest fingerprint seen mid-burst
                quiet_since = None  # monotonic time pending last changed
                while not (stop and stop.is_set()):
                    threading.Event().wait(poll_interval)
                    cur = adapter.fingerprint()
                    if cur != last and pending is None:
                        pending = cur               # burst started
                        quiet_since = time.monotonic()
                    elif pending is not None and cur != pending:
                        pending = cur               # burst still moving — restart
                        quiet_since = time.monotonic()
                    elif pending is not None and cur == pending:
                        # Stable this tick — has it been quiet long enough?
                        if time.monotonic() - quiet_since >= quiet:
                            if pending != last:
                                last = pending
                                self._sse_send("update", last)
                            pending = None
                            quiet_since = None
            except (BrokenPipeError, ConnectionResetError, OSError):
                return

        def _sse_send(self, event, data):
            payload = "event: %s\ndata: %s\n\n" % (event, json.dumps(data))
            self.wfile.write(payload.encode("utf-8"))
            self.wfile.flush()

    return Handler
