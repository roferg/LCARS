"""The LCARS serve daemon — Python 3 stdlib only (http.server), no build step.

Serves (READ — always available, adapter-neutral; ADR-003):
  GET /                     the static Kanban board (static/index.html)
  GET /<asset>              static front-end assets (board.js, lcars.css, …)
  GET /api/board            the full adapter-neutral board JSON (board.py shape)
  GET /api/mission/<id>     mission detail incl. the activity feed
  GET /api/events           a live channel (Server-Sent Events) that pushes ONE
                            update whenever mission state changes on disk

Serves (WRITE — LOCAL-BRIDGE only; ADR-006). The write endpoints are registered
ONLY when an `actions` (Actions) is injected — the local-adapter daemon. A
github/view-only daemon is built with `actions=None`, so the GET read/render
path keeps working with the GitHub adapter ALONE and every write is declined
with 403. Each write shells out to the matching `lcars` skill (ADR-002):
  POST /api/align/start                  open an Align grilling   → worker turn
  POST /api/align/<sid>/answer           next interview turn      → worker turn
  POST /api/align/<sid>/cancel           reap the Align session   → no spend
                                         (on done → file.sh)
  POST /api/mission                      file an idea            → file.sh
  POST /api/mission/<id>/start           drive the run (+override)→ run.sh drive
  POST /api/mission/<id>/pause           pause                   → pause.sh
  POST /api/mission/<id>/resume          resume                  → pause.sh
  POST /api/mission/<id>/respond         answer a gate           → respond.sh
  POST /api/mission/<id>/verify          approve | send-back     → approve|feedback.sh
  POST /api/mission/<id>/reapprove       merge-only after a heal → approve.sh --reapprove
  POST /api/mission/<id>/log             preview/author child bugs→ worker | (read)
  POST /api/mission/<id>/log/file        file logged bugs (+estimate), return review → log.sh
  POST /api/mission/<id>/log/run         drive ALREADY-FILED logged bugs (the
                                         explicit Go) → resolve-logs.sh. Posting
                                         prds WITHOUT confirm:true is gated — it
                                         files+estimates and HOLDS (BUG-059); only
                                         confirm:true file-and-runs in one call.

The Align console is multi-turn: each POST spawns ONE cold worker turn (engine
$LCARS_WORKER_BIN) driving the EXISTING lcars-file grilling instructions with the
accumulated transcript; the daemon owns the loop + in-memory session (ADR-002 —
it DRIVES the align prompt, never reimplements it). The HTTP request/response
cycle IS the human gate (no server-side timeout).

A write that changes `.git/lcars` moves the LocalAdapter fingerprint, so the
existing /api/events SSE poll loop emits ONE coalesced `update` the board
consumes — no second push path is needed.
"""
import json
import os
import posixpath
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .actions import ActionError as _ActionError

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

# S91 — guards on the write body now that it can carry a pasted image as base64.
#  • _MAX_BODY_BYTES caps the whole JSON body (Content-Length) so a giant paste
#    can't exhaust memory. 12 MB leaves room for a ~9 MB image (base64 inflates
#    ~33%) plus the surrounding JSON; the front end pre-checks at a tighter ~8 MB
#    per image. Rejected BEFORE the body is read → 413.
#  • _ALLOWED_IMAGE_TYPES is the image content-type allow-list — an `images[]`
#    entry of any other type is rejected → 415, before it can reach the worker.
_MAX_BODY_BYTES = 12 * 1024 * 1024
_ALLOWED_IMAGE_TYPES = ("image/png", "image/jpeg", "image/gif", "image/webp")


def make_server(adapter, host="127.0.0.1", port=8765, poll_interval=1.0,
                actions=None):
    """Build (do not start) the daemon bound to `adapter`. Caller serves it.

    `actions` is the optional LOCAL-BRIDGE write layer (an actions.Actions). When
    None the daemon is READ-ONLY — every write returns 403 (the github/view-only
    shape). When present, the POST endpoints dispatch to the `lcars` skills.
    """
    handler = _build_handler(adapter, poll_interval, actions)

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


def _build_handler(adapter, poll_interval, actions=None):
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

        # -- writes (LOCAL-BRIDGE only) --------------------------------------
        def do_POST(self):
            if actions is None:
                # read-only / view-only build: the write layer is not active.
                return self._write_error(403, "read-only: write actions are "
                                         "disabled (this is a view-only board)")
            path = self.path.split("?", 1)[0]
            try:
                body = self._read_json_body()
                result = self._dispatch_write(path, body)
            except _ActionError as exc:
                return self._write_error(exc.status, exc.message)
            except Exception as exc:  # never leak a stack to the client
                return self._write_error(500, "write failed: %s" % exc)
            return self._json({"ok": True, "state": result})

        def _write_error(self, code, msg):
            # write responses carry {ok:false,error} (the frontend's contract).
            body = json.dumps({"ok": False, "error": msg}).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _dispatch_write(self, path, body):
            # POST /api/align/start            — open an Align grilling session
            # POST /api/align/<sid>/answer     — answer + run the next turn
            if path == "/api/align/start":
                return actions.align_start(idea=body.get("idea"),
                                           engine=body.get("engine"),
                                           images=self._images(body))
            if path.startswith("/api/align/"):
                rest = path[len("/api/align/"):]
                parts = [p for p in rest.split("/") if p != ""]
                if len(parts) == 2 and parts[1] == "answer":
                    return actions.align_answer(parts[0],
                                                answer=body.get("answer"),
                                                images=self._images(body))
                if len(parts) == 2 and parts[1] == "cancel":
                    return actions.align_cancel(parts[0])
                raise _ActionError(404, "no such align endpoint: %s" % path)
            # POST /api/mission  — file a new mission
            if path == "/api/mission":
                return actions.file_mission(
                    idea=body.get("idea"),
                    engine=body.get("engine"),
                    mission_type=body.get("type", "feature"),
                    images=self._images(body))
            # POST /api/mission/<id>/<verb>[/<sub>]
            if path.startswith("/api/mission/"):
                rest = path[len("/api/mission/"):]
                parts = [p for p in rest.split("/") if p != ""]
                if len(parts) >= 2:
                    mid = parts[0]
                    verb = "/".join(parts[1:])
                    return self._dispatch_verb(mid, verb, body)
            raise _ActionError(404, "no such write endpoint: %s" % path)

        def _dispatch_verb(self, mid, verb, body):
            if verb == "start":
                return actions.start(mid, override=body.get("override"))
            if verb == "pause":
                return actions.pause(mid)
            if verb == "resume":
                return actions.resume(mid)
            if verb == "respond":
                return actions.respond(mid, answer=body.get("answer"))
            if verb == "verify":
                return actions.verify(mid, decision=body.get("decision"),
                                      feedback=body.get("feedback"))
            if verb == "reapprove":
                return actions.reapprove(mid)
            if verb == "log":
                return actions.log_preview(mid, text=body.get("text"),
                                           images=self._images(body))
            if verb == "log/file":
                return actions.log_file(mid, prds=body.get("prds"),
                                        overrides=body.get("overrides"),
                                        images=self._images(body),
                                        image_refs=body.get("imageRefs"))
            if verb == "log/run":
                return actions.log_run(mid, prds=body.get("prds"),
                                       overrides=body.get("overrides"),
                                       confirm=bool(body.get("confirm")),
                                       images=self._images(body),
                                       image_refs=body.get("imageRefs"))
            raise _ActionError(404, "no such action: %s" % verb)

        def _read_json_body(self):
            length = int(self.headers.get("Content-Length") or 0)
            # S91 — reject an oversize body BEFORE reading it (a runaway image
            # paste must not be slurped into memory). Close the connection so the
            # unread request body can't corrupt a keep-alive socket.
            if length > _MAX_BODY_BYTES:
                self.close_connection = True
                raise _ActionError(
                    413, "request body too large (%d bytes; limit is %d MB) — an "
                    "attached image may exceed the cap"
                    % (length, _MAX_BODY_BYTES // (1024 * 1024)))
            if length <= 0:
                return {}
            raw = self.rfile.read(length)
            if not raw:
                return {}
            try:
                obj = json.loads(raw.decode("utf-8"))
            except ValueError:
                raise _ActionError(400, "request body is not valid JSON")
            if not isinstance(obj, dict):
                raise _ActionError(400, "request body must be a JSON object")
            return obj

        def _images(self, body):
            """S91 — validate + return the body's `images[]` (or None).

            Enforces the image content-type allow-list HERE, before any image can
            reach the worker: an entry whose `type` is not in _ALLOWED_IMAGE_TYPES
            is rejected with 415. The base64 decode + on-disk staging happen in
            the Actions layer (it owns repo_root + cleanup); this gate only blocks
            an unknown type from getting that far.
            """
            images = body.get("images")
            if images in (None, []):
                return None
            if not isinstance(images, list):
                raise _ActionError(400, "images must be a JSON array")
            for img in images:
                if not isinstance(img, dict):
                    raise _ActionError(400, "each image must be a JSON object")
                ctype = (img.get("type") or "").strip().lower()
                if ctype not in _ALLOWED_IMAGE_TYPES:
                    raise _ActionError(
                        415, "unsupported image type %r — allowed: %s"
                        % (ctype, ", ".join(_ALLOWED_IMAGE_TYPES)))
            return images

        def _reject(self):
            self._error(405, "method not supported")

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
