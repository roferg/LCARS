"""The LCARS serve daemon — Python 3 stdlib only (http.server), no build step.

Serves (READ — always available, adapter-neutral; ADR-003):
  GET /                     the static Kanban board (static/index.html)
  GET /<asset>              static front-end assets (board.js, lcars.css, …)
  GET /api/board            the full adapter-neutral board JSON (board.py shape)
  GET /api/mission/<id>     mission detail incl. the activity feed
  GET /api/base-freshness   this repo's live base-freshness verdict (S160) —
                            read-only, adapter-optional (404 when the adapter
                            cannot see a local checkout)
  GET /api/events           a live channel (Server-Sent Events) that pushes ONE
                            update whenever mission state changes on disk

Serves (WRITE — LOCAL-BRIDGE only; ADR-006). The write endpoints are registered
ONLY when an `actions` (Actions) is injected — the local-adapter daemon. A
github/view-only daemon is built with `actions=None`, so the GET read/render
path keeps working with the GitHub adapter ALONE and every write is declined
with 403. Each write shells out to the matching `lcars` skill (ADR-002):
  POST /api/align/start                  open an Align grilling   → worker turn
  POST /api/vision/file                  file the initialization mission (S184)
  POST /api/align/<sid>/answer           next interview turn      → worker turn
  POST /api/align/<sid>/cancel           reap the Align session   → no spend
                                         (on done → file.sh)
  POST /api/config/test-command          set testCommand         → update.sh --test-command
  POST /api/config/probe-tests           one bounded suite probe → update.sh --probe-tests
  POST /api/config/fix-tests             one-click test repair   → update.sh --fix-tests
  POST /api/mission                      file an idea            → file.sh
  POST /api/mission/<id>/start           drive the run (+override)→ run.sh drive
  POST /api/mission/<id>/pause           pause                   → pause.sh
  POST /api/mission/<id>/resume          resume                  → pause.sh
  POST /api/mission/<id>/respond         answer a gate           → respond.sh
  POST /api/mission/<id>/verify          approve | send-back     → approve|feedback.sh
  POST /api/mission/<id>/reapprove       merge-only after a heal → approve.sh --reapprove
  POST /api/mission/<id>/log             preview/author child bugs→ worker | (read)
                                         an AUTHORING preview also mints the S161
                                         daemon-side session and returns sessionId.
                                         409s when it would destroy authored bugs a
                                         live session never got onto disk, unless
                                         the body says `discardUnfiled` (R1)
  POST /api/mission/<id>/log/file        file logged bugs (+estimate) → log.sh.
                                         With `sessionId` it DISPATCHES and returns
                                         promptly (status filing→filed/failed);
                                         with `prds` in the body it BLOCKS and
                                         returns the review (the legacy form)
  GET  /api/mission/<id>/log/session     restore a reopened Mission-Log console
                                         (S161; status + children + estimates +
                                         the authored text of anything unfiled)
  POST /api/mission/<id>/log/discard     throw away an authoring session the
                                         captain is done with — abandoned, or a
                                         partial's unfiled leftover — so its card
                                         stamp clears (S161; Align /cancel parity)
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
import errno
import json
import os
import posixpath
import shutil
import subprocess
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

# S190 — the per-mission WRITE verbs the light lock refuses on a mission held by
# someone else (see _owner_gate). An ALLOW-LIST, never a deny-list: a verb added
# to this daemon later is UNLOCKED until somebody puts it here on purpose, which
# is the failure direction a solo protocol can live with. The reverse — a
# deny-list that silently locks a new verb — would refuse writes nobody meant to
# refuse, and a false lock is the worse of the two errors.
#
# `launch` and `launch/stop` are deliberately ABSENT: the launch affordance is
# S187's territory and this session changes nothing about it.
_OWNER_LOCKED_VERBS = frozenset((
    "start", "pause", "resume", "respond", "verify", "reapprove",
    "log", "log/file", "log/run", "log/discard",
))

# S191 fix round 1 (D6) — THE REMOTE REFUSAL, IN THE CARD'S OWN WORDS.
#
# A remote card's disabled controls carry this sentence as their tooltip
# (board.js `REMOTE_LINE`). A direct POST past the DOM used to answer
# `no such mission: <issue>` — because a remote mission genuinely has no local
# mission directory — so the card and the daemon told the captain TWO DIFFERENT
# STORIES about one thing: the card said "someone else is driving it", the server
# said "it does not exist". S190 spent a session making its tooltip, its 403 body
# and the CLI refusal ONE byte-identical sentence; this is the same rule applied
# to the state S191 introduced. Pinned against board.js by test_remote_overlay.
_REMOTE_LOCK_LINE = ("driven from another machine — adopt at Align/Verify to "
                     "act here")


# S197 — THE MISSION THAT IS ALREADY OVER, from somewhere else.
#
# S196's last round taught the FILING laptop that its mission had merged on the
# other machine, and WITHDREW the `✓ Review PR ▸` it had gone on offering for a
# pull request that closed minutes earlier. It left the daemon accepting a POST
# to that very verb — ledgered in its own commit message, because S190's lesson
# is that A DISABLED BUTTON IS NOT A LOCK: anyone with the port can POST straight
# past the DOM, and the tester will.
#
# TWO SENTENCES, BECAUSE THEY ARE TWO FACTS, and they are the SAME BYTES the card
# puts in the withdrawn control's tooltip (board.js `SHIPPED_LINE` / `CLOSED_LINE`).
# `shipped` is `lcars:done` — the label `lcars approve` applies at the merge and
# nowhere else. `closed` is an issue closed on the forge WITHOUT it: over, but
# NOT merged, and saying "shipped" there would invent a merge nobody performed.
# Pinned against board.js by test, read out of the shipping file, so an edit to
# either side breaks here instead of in front of the captain.
_SHIPPED_LOCK_LINE = ("already shipped from another machine — its pull request "
                      "is merged")
_CLOSED_LOCK_LINE = ("already closed on the forge from another machine — "
                     "nothing here can act on it")


# --- S187: a CIVIL refusal when the port is already taken --------------------
# Plain `lcars viewscreen` binds the fixed 8765 (only `--open` picks a free
# port), so a second board on the same machine hit `_Server((host, port), ...)`
# below and died on a raw `OSError: [Errno 48] Address already in use`
# traceback — no message, no named fix, nothing an operator could act on.
#
# The guard lives at the BIND and is PORT-AGNOSTIC: 8765 is merely the common
# case, and any occupied port (an explicit `--port`, LCARS_SERVE_PORT) deserves
# the same sentence. Only EADDRINUSE is translated; every other OSError still
# raises untouched, because a message that swallowed, say, a permission error
# would be worse than the traceback it replaced.


def port_holder(port, timeout=3.0):
    """Best-effort command name of whatever is LISTENing on `port` ("" if
    unknown). It runs `lsof` (darwin ships it at /usr/sbin/lsof, which is not on
    every PATH), and every failure mode — no lsof, a timeout, no match, a
    permission refusal — degrades to "". Naming the holder is a courtesy on top
    of the refusal, never a precondition for it.
    """
    lsof = shutil.which("lsof") or "/usr/sbin/lsof"
    if not os.path.exists(lsof):
        return ""
    try:
        out = subprocess.run([lsof, "-nP", "-sTCP:LISTEN", "-iTCP:%d" % port],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             timeout=timeout).stdout.decode("utf-8", "replace")
    except Exception:
        return ""
    for line in out.splitlines()[1:]:
        parts = line.split()
        if parts:
            return parts[0]
    return ""


class PortInUseError(OSError):
    """The daemon's port is already bound. Carries the ONE line to print."""

    def __init__(self, host, port, holder=""):
        self.host = host
        self.port = port
        self.holder = holder
        OSError.__init__(self, errno.EADDRINUSE, self.lcars_line())

    def lcars_line(self):
        """One line, in the LCARS voice: what is wrong, who is doing it, and
        BOTH ways out. One line matters — a refusal an operator has to scroll
        is the traceback again in nicer words."""
        held = " (held by %s)" % self.holder if self.holder else ""
        return ("LCARS \u2014 the viewscreen cannot take port %d%s; it is "
                "already in use. Run `lcars viewscreen --open` for a free "
                "port, or `lcars viewscreen --port N` to name another."
                % (self.port, held))


def make_server(adapter, host="127.0.0.1", port=8765, poll_interval=1.0,
                actions=None, version_provider=None, log_facts=None):
    """Build (do not start) the daemon bound to `adapter`. Caller serves it.

    `actions` is the optional LOCAL-BRIDGE write layer (an actions.Actions). When
    None the daemon is READ-ONLY — every write returns 403 (the github/view-only
    shape). When present, the POST endpoints dispatch to the `lcars` skills.

    `log_facts` (S163 fix round 4, D3) is the optional READ-ONLY Mission-Log
    durable-facts reader (an actions.LogFacts). It is used ONLY when `actions` is
    None — a view-only LOCAL board — so that the dispatch and shortfall records
    sitting in `.git/lcars/missions/<id>/` reach the card there too. Round 3 made
    those facts durable files; reading a file needs no write layer, and without
    this the two boards told different stories about the same repo at the same
    instant. Never wired for the GITHUB adapter, which cannot see a local
    `.git/lcars/` at all (see `__main__.build_log_facts`).

    `version_provider` (S130) is an optional zero-arg callable returning the
    additive `meta.version` block (or None when the install is current). It is
    injected onto GET /api/board only; when it returns None the board is
    byte-identical to the pre-S130 shape (no banner). Adapter-neutral: the banner
    shows on BOTH the local and github/view-only builds (the UPDATE BUTTON is
    LOCAL-only — it POSTs /api/update, which the read-only 403 guard blocks).
    """
    handler = _build_handler(adapter, poll_interval, actions, version_provider,
                             log_facts)

    class _Server(ThreadingHTTPServer):
        daemon_threads = True

        def __init__(self, *a, **kw):
            ThreadingHTTPServer.__init__(self, *a, **kw)
            self._lcars_stop = threading.Event()

        def shutdown(self):
            self._lcars_stop.set()   # release any in-flight SSE poll loops
            ThreadingHTTPServer.shutdown(self)

    try:
        httpd = _Server((host, port), handler)
    except OSError as exc:
        # S187: only the "someone is already there" case is translated; anything
        # else (EACCES on a privileged port, a bad host) still raises as it did.
        if getattr(exc, "errno", None) != errno.EADDRINUSE:
            raise
        raise PortInUseError(host, port, port_holder(port)) from None
    return httpd


def _build_handler(adapter, poll_interval, actions=None, version_provider=None,
                   log_facts=None):
    # S163 fix round 4 (D3): the ONE overlay source for this daemon. A write
    # board overlays from its live sessions (richer, and the durable records are
    # folded into it); a view-only LOCAL board overlays from the durable records
    # alone. Both expose the same three method names, so the GET path below has
    # one branch rather than two stories.
    overlay = actions if actions is not None else log_facts
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):  # silence default stderr noise
            pass

        # -- only GET is allowed (read-only board) ---------------------------
        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path == "/api/board":
                return self._json(self._board_with_version())
            # GET /api/mission/<id>/log/session — the live Mission-Log authoring
            # session, for RESTORING a reopened console (S161). Must be matched
            # BEFORE the mission-detail route below, which would otherwise read
            # "<id>/log/session" as a mission id — and did, answering "no such
            # mission" about a mission sitting right there on the board (N3). It is
            # the SESSION route, not the mission, that is write-board-only: a
            # read-only build (actions=None) holds no sessions, and now SAYS that.
            if (path.startswith("/api/mission/")
                    and path.endswith("/log/session")):
                mid = path[len("/api/mission/"):-len("/log/session")]
                if mid and "/" not in mid:
                    if overlay is None:
                        if adapter.mission(mid) is None:
                            return self._error(404, "no such mission")
                        return self._error(
                            404, "no mission-log session for %s — this board is "
                                 "read-only, so it holds none" % mid)
                    if actions is None and adapter.mission(mid) is None:
                        return self._error(404, "no such mission")
                    # S163 fix round 4 (D3): on a view-only LOCAL board this is
                    # `LogFacts.log_session_state`, which answers from the durable
                    # record on disk instead of asserting there is nothing to say
                    # while a shortfall sits right there. Still a read: it opens
                    # one file.
                    try:
                        return self._json(overlay.log_session_state(mid))
                    except _ActionError as exc:
                        return self._error(exc.status, exc.message)
            if path.startswith("/api/mission/"):
                mid = path[len("/api/mission/"):]
                detail = adapter.mission(mid)
                if detail is None:
                    return self._error(404, "no such mission")
                # Park & Align (F2): mirror the board's alignResume overlay onto the
                # detail payload so the DETAIL modal shows ▹ RESUME ALIGN too (it never
                # runs through align_overlay). Additive; never raises into the response.
                if actions is not None:
                    try:
                        detail = actions.align_overlay_mission(detail)
                    except Exception:
                        pass
                    # S161: same mirror for a live Mission-Log filing session, so
                    # the detail modal can show the ◐ FILING band the card shows.
                    try:
                        detail = actions.log_overlay_mission(detail)
                    except Exception:
                        pass
                elif log_facts is not None:
                    # S163 fix round 4 (D3): a view-only LOCAL board mirrors the
                    # DURABLE half onto the detail for the same reason — a card
                    # and its detail disagreeing is the defect, on either board.
                    try:
                        detail = log_facts.log_overlay_mission(detail)
                    except Exception:
                        pass
                return self._json(detail)
            # GET /api/align/<sid> — the open turn of a live Align session, for RESUME
            # (Park & Align F2). Local write board only: a read-only build has
            # actions=None, so this falls through to _static (a 404) — the resume
            # affordance is never offered there.
            if path.startswith("/api/align/") and actions is not None:
                sid = path[len("/api/align/"):].strip("/")
                if sid and "/" not in sid:
                    try:
                        return self._json(actions.align_state(sid))
                    except _ActionError as exc:
                        return self._error(exc.status, exc.message)
            # GET /api/base-freshness — this repo's live base-freshness verdict
            # (S160). A READ: the File console asks it BEFORE the captain has
            # typed a word, so a stale or dirty base is named before the idea is,
            # and the reporter behind it is read-only by construction (it never
            # moves a ref — see skills/lcars-init/base-freshness.sh).
            #
            # NOT gated on `actions`. This is not a write, so it answers on a
            # `--read-only` LOCAL board too — a captain looking at a view-only
            # board still gets the truth about the checkout it is attached to.
            # An adapter that cannot see a local checkout (the GitHub one) has no
            # such method and 404s cleanly; a reporter failure answers `null`,
            # never a 500 (the console then simply says nothing).
            # ── S125 — the HOLODECK surface's reads ────────────────────────
            # GET /api/holodeck                        the program list
            # GET /api/holodeck/<sid>                  one program + transcript
            # GET /api/holodeck/<sid>/preview/<path>   ONE file from that
            #     program's room, sidecar-JAILED (see actions.holodeck_preview).
            #
            # All three are gated on `actions is not None`, exactly like the
            # Align RESUME read above: a read-only / github build holds no
            # holodeck sessions, so there is nothing to serve and these fall
            # through to _static's 404 rather than pretending the surface is
            # there. Reads only — no holodeck write can be reached over GET.
            if path.startswith("/api/holodeck") and actions is not None:
                rest = path[len("/api/holodeck"):]
                if rest in ("", "/"):
                    return self._json(actions.holodeck_list())
                parts = rest.strip("/").split("/")
                try:
                    if len(parts) == 1 and parts[0]:
                        return self._json(actions.holodeck_state(parts[0]))
                    if len(parts) >= 3 and parts[1] == "preview":
                        got = actions.holodeck_preview(parts[0],
                                                       "/".join(parts[2:]))
                        return self._send_preview(got)
                except _ActionError as exc:
                    return self._error(exc.status, exc.message)
                return self._error(404, "no such holodeck endpoint: %s" % path)
            if path == "/api/base-freshness":
                reader = getattr(adapter, "base_freshness", None)
                if not callable(reader):
                    return self._error(
                        404, "this board cannot read base freshness (it is not "
                             "attached to a local checkout)")
                try:
                    rec = reader()
                except Exception:
                    rec = None
                return self._json({"baseFreshness": rec})
            if path == "/api/events":
                return self._sse()
            return self._static(path)

        def _board_with_version(self):
            """The board shape, plus the ADDITIVE meta.version block when stale.

            When version_provider returns None (current install) the board is
            byte-identical to the pre-S130 shape — no `version` key at all — so
            existing web tests stay green and a current board shows no banner.
            The provider is memoized/throttled (never a fetch storm) and never
            raises; a failure here degrades to the plain board.
            """
            board = adapter.board()
            # Park & Align (F2): stamp `alignResume` onto cards with a live grill
            # session so RESUME ALIGN survives a page reload. Additive + in-memory;
            # a read-only build has actions=None → no overlay (correct). Never raises
            # into the board response.
            if actions is not None:
                try:
                    board = actions.align_overlay(board)
                except Exception:
                    pass
                # S161: stamp `logFiling` on the parent card of a live Mission-Log
                # authoring/filing session, so the captain can close the console
                # and watch the card instead. Additive + in-memory; a read-only
                # build (actions=None) is never stamped. Never raises into the
                # board response.
                try:
                    board = actions.log_overlay(board)
                except Exception:
                    pass
                # S128 (FL-002): stamp `meta.holodeck` while a holodeck program
                # is mid-turn, so the ⬡ HOLODECK band control can show that the
                # program the captain walked away from is still working. Same
                # terms as the two above — additive, in-memory, local write
                # board only, and never raises into the board response.
                try:
                    board = actions.holodeck_overlay(board)
                except Exception:
                    pass
            elif log_facts is not None:
                # S163 fix round 4 (D3): the view-only LOCAL board's half of the
                # same stamp — read from `<mission>/log-dispatch.json` and
                # `<mission>/log-shortfall.json`, never from memory it does not
                # have. Additive on the same terms: a repo with no log activity
                # is returned byte-for-byte unchanged.
                try:
                    board = log_facts.log_overlay(board)
                except Exception:
                    pass
            if version_provider is not None:
                try:
                    # version_provider may be a bare callable OR a VersionChecker
                    # (object with .block()/.invalidate()); accept both.
                    call = getattr(version_provider, "block", version_provider)
                    blk = call()
                except Exception:
                    blk = None
                if blk and isinstance(board.get("meta"), dict):
                    board["meta"]["version"] = blk
            return board

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
                return self._write_error(exc.status, exc.message,
                                         getattr(exc, "data", None))
            except Exception as exc:  # never leak a stack to the client
                return self._write_error(500, "write failed: %s" % exc)
            # S130: an update moves the source/repo stamp, so drop the version
            # checker's memo — the very next /api/board (SSE-triggered) re-probes
            # and the banner clears instead of lingering for the memo window.
            if path == "/api/update" and version_provider is not None:
                inval = getattr(version_provider, "invalidate", None)
                if callable(inval):
                    try:
                        inval()
                    except Exception:
                        pass
            return self._json({"ok": True, "state": result})

        def _write_error(self, code, msg, extra=None):
            # write responses carry {ok:false,error} (the frontend's contract).
            #
            # S169 fix round 1 — …plus whatever FACT the refusal needs the page
            # to act on, ADDITIVELY. The one live case is `sessionReset`: the
            # daemon has re-minted a warm session an attachment poisoned, and
            # the deck's RETRY TURN must not re-send that attachment into the
            # fresh one. The alternative was the page reading the daemon's
            # SENTENCE to decide, which is the classifier road this round exists
            # to stay off.
            out = {"ok": False, "error": msg}
            for k, v in (extra or {}).items():
                if k not in out:
                    out[k] = v
            body = json.dumps(out).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _dispatch_write(self, path, body):
            # POST /api/update — run the S130/S129 update action (LOCAL only; the
            # read-only / github build has actions=None, so do_POST already 403'd
            # before reaching here). The response body carries the success line or
            # the decline reason; SSE naturally refreshes the board after install.
            if path == "/api/update":
                return actions.update()
            # POST /api/align/start            — open an Align grilling session
            # POST /api/align/<sid>/answer     — answer + run the next turn
            # POST /api/park — file a PARKED mission (pre-PRD standby, S137). The
            # read-only build has actions=None, so do_POST already 403'd above.
            if path == "/api/park":
                # `holodeck`/`holodeckScope` (S127): the deck's ▦ FILE MISSION
                # sends a program's SESSION ID, never a path — see /api/mission.
                return actions.park_mission(idea=body.get("idea"),
                                            engine=body.get("engine"),
                                            images=self._images(body),
                                            holodeck=body.get("holodeck"),
                                            holodeck_scope=body.get(
                                                "holodeckScope"),
                                            # S128 — `{questionId: answer}`.
                                            # The ids are the DAEMON's, minted
                                            # from the concept doc it re-reads
                                            # here, so an unknown key is simply
                                            # not a question and is dropped.
                                            holodeck_answers=body.get(
                                                "holodeckAnswers"))
            # POST /api/deploy/main[/stop] — deploy the LOCAL main HEAD, and stop
            # it (S139). NON-mission verbs (like /api/park): the read-only build
            # has actions=None, so do_POST already 403'd above.
            if path == "/api/deploy/main":
                return actions.deploy_main(hint=body.get("hint"))
            if path == "/api/deploy/main/stop":
                return actions.deploy_main_stop()
            # S146 — the test-readiness repair endpoints. NON-mission, repo-
            # level verbs (like /api/park): each dispatches the matching
            # `lcars update` verb via the SCRIPT_ENV seam (the CLI stays the
            # ONE sanctioned config writer). Blocking; the read-only build has
            # actions=None, so do_POST already 403'd above and the board hides
            # the affordances.
            if path == "/api/config/fix-tests":
                return actions.fix_tests()
            if path == "/api/config/test-command":
                return actions.set_test_command(body.get("testCommand"))
            if path == "/api/config/probe-tests":
                return actions.probe_tests()
            # POST /api/vision/file — S184: file the INITIALIZATION mission
            # from the front door. A LOCAL-adapter write like the Align family
            # (a read-only / github build has actions=None and already 403'd).
            if path == "/api/vision/file":
                return actions.vision_file(idea=body.get("idea"),
                                           stack=body.get("stack"),
                                           reasons=body.get("reasons"),
                                           deferred=body.get("deferred"),
                                           slice_=body.get("slice"),
                                           # S195 — the front door's engine
                                           # pick: it drives the mission it
                                           # files and becomes the repo default.
                                           engine=body.get("engine"))
            if path == "/api/align/start":
                return actions.align_start(idea=body.get("idea"),
                                           vision=bool(body.get("vision")),
                                           engine=body.get("engine"),
                                           images=self._images(body),
                                           mission_id=body.get("missionId"),
                                           # S127 — a SESSION ID, never a path.
                                           holodeck=body.get("holodeck"),
                                           holodeck_scope=body.get(
                                               "holodeckScope"),
                                           holodeck_answers=body.get(
                                               "holodeckAnswers"))
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
            # POST /api/holodeck/start        — open a holodeck PROGRAM (S124)
            # POST /api/holodeck/<sid>/say    — one warm chat turn
            # POST /api/holodeck/<sid>/end    — close the program
            # The holodeck is a LOCAL-adapter surface like the Align family: a
            # read-only / github build has actions=None, so do_POST already
            # 403'd above and the board hides the affordance entirely.
            if path == "/api/holodeck/start":
                return actions.holodeck_start(repo=body.get("repo"),
                                              program=body.get("program"),
                                              engine=body.get("engine"),
                                              mode=body.get("mode", "design"),
                                              images=self._images(body))
            # S126 — durable programs. Both are keyed by ROOM, not by session
            # id, because the whole point is that they work on a program THIS
            # daemon has never held: `open` warm-restarts one from disk, and
            # `delete` git-rm's it so the archive keeps the history. Declared
            # ABOVE the `<sid>/<verb>` matcher so a room can never be mistaken
            # for a session id.
            if path == "/api/holodeck/open":
                return actions.holodeck_open(room=body.get("room"),
                                             engine=body.get("engine"))
            if path == "/api/holodeck/delete":
                return actions.holodeck_delete(room=body.get("room"))
            # S172 — DUPLICATE a program, carrying its history. Keyed by ROOM
            # for the same reason `open` and `delete` are: the program it is
            # reached from is normally a LOCKED, sent one this daemon may never
            # have held. `program` is an optional name for the copy — omitted,
            # the daemon picks one whose room is free.
            if path == "/api/holodeck/duplicate":
                return actions.holodeck_duplicate(room=body.get("room"),
                                                  program=body.get("program"),
                                                  engine=body.get("engine"))
            if path.startswith("/api/holodeck/"):
                rest = path[len("/api/holodeck/"):]
                parts = [p for p in rest.split("/") if p != ""]
                if len(parts) == 2 and parts[1] == "say":
                    # S169 (FL-015): `intent` is the captain's own declaration
                    # of the turn's shape ("ask"/"build"), made on the composer.
                    # Optional — absent normalises to "build", the branch whose
                    # prompt already carries answer-then-stop as the default.
                    return actions.holodeck_say(parts[0],
                                                text=body.get("text"),
                                                images=self._images(body),
                                                intent=body.get("intent"))
                if len(parts) == 2 and parts[1] == "end":
                    return actions.holodeck_end(parts[0])
                # POST /api/holodeck/<sid>/promote — SEND TO ALIGN (S127). A
                # WRITE like its siblings (do_POST already 403'd a view-only
                # build), even though it changes nothing yet: it is the action
                # that starts a hand-off, and a read-only board must refuse it
                # by the same door, not by a second rule of its own.
                if len(parts) == 2 and parts[1] == "promote":
                    return actions.holodeck_promote(parts[0],
                                                    scope=body.get("scope"))
                # POST /api/holodeck/<sid>/derive — GENERATE THE CHANGE LIST
                # (S171). The gate the captain asked for: ▶ SEND TO ALIGN runs
                # this ON CLICK and waits on the daemon's published state, so a
                # mid-design turn no longer burns a pass. `promote` peeks; this
                # is the ONLY road that may spawn one. `force` is his explicit
                # "try again" after a pass that did not answer.
                if len(parts) == 2 and parts[1] == "derive":
                    return actions.holodeck_derive(
                        parts[0], force=bool(body.get("force")))
                raise _ActionError(404, "no such holodeck endpoint: %s" % path)
            # POST /api/mission  — file a new mission
            #
            # `holodeck` (S127) is a holodeck PROGRAM's SESSION ID, never a
            # path: the daemon re-resolves that program's room itself and
            # expands it to the `--attach` arguments. The browser has no way to
            # name a file here, which is the point.
            if path == "/api/mission":
                return actions.file_mission(
                    idea=body.get("idea"),
                    engine=body.get("engine"),
                    mission_type=body.get("type", "feature"),
                    images=self._images(body),
                    holodeck=body.get("holodeck"),
                    holodeck_scope=body.get("holodeckScope"),
                    holodeck_answers=body.get("holodeckAnswers"))
            # POST /api/mission/<id>/<verb>[/<sub>]
            if path.startswith("/api/mission/"):
                rest = path[len("/api/mission/"):]
                parts = [p for p in rest.split("/") if p != ""]
                if len(parts) >= 2:
                    mid = parts[0]
                    verb = "/".join(parts[1:])
                    return self._dispatch_verb(mid, verb, body)
            raise _ActionError(404, "no such write endpoint: %s" % path)

        def _owner_gate(self, mid, verb):
            """S190 — THE LIGHT LOCK, at the door. Raises 403, or returns.

            The board disables these controls on a mission held by someone else,
            but a disabled button is not a lock: anyone with the port can POST
            straight past the DOM, and the tester will. This is where the refusal
            actually happens — before a skill is dispatched, before a driver lock
            is taken, before a branch moves.

            The set is EXACTLY the set of verbs S189 already refuses at the CLI
            (run / respond / approve / feedback / log). Two are here that S189
            does not lock — `pause` and `resume` — deliberately: they are `run`'s
            own lifecycle from this board's point of view, and offering a live
            Pause on work driving on someone else's laptop would be a button that
            promises something LCARS cannot do. Nothing else is annexed; in
            particular `launch` / `launch/stop` stay out of it, because the launch
            affordance is S187's territory and this session changes none of it.

            The verdict comes from `Actions.owner_lock_reason`, which shells the
            same ownership.sh the CLI consults — live, on every request, so a
            reassignment made on GitHub takes effect on the next click. Every
            uncertain case allows the write (see that method).
            """
            if verb not in _OWNER_LOCKED_VERBS:
                return
            reason = getattr(actions, "owner_lock_reason", None)
            if not callable(reason):
                return          # a writer wired without the ownership seam
            try:
                line = reason(mid)
            except Exception:
                return          # never let the guard itself refuse a write
            if line:
                raise _ActionError(403, line)

        def _remote_gate(self, mid, verb):
            """S191 fix round 1 (D6) — a write on a mission driven ELSEWHERE.

            409, not 404. The mission is not missing — it is on the forge, it is
            on this board, and the captain is looking at its card. What is
            missing is this laptop's standing to write to it, and that is a
            CONFLICT WITH CURRENT STATE. `no such mission` was not merely the
            wrong number: it contradicted the very card the click came from.

            The same verbs the owner lock covers, for the same reason it uses an
            allow-list — and `adopt` is outside it on purpose, because adopting
            is how a remote mission stops being remote.

            THE VERDICT IS THE ADAPTER'S, not a second implementation of one.
            `adapter.mission()` already answers "local, remote, or neither" with
            local winning by construction, off the SAME cached forge listing the
            board was built from (no extra `gh` call, so this cannot recreate the
            S152 storm). A mission the adapter has never heard of falls through
            untouched and still gets the honest 404 it deserves.
            """
            if verb not in _OWNER_LOCKED_VERBS:
                return
            reader = getattr(adapter, "mission", None)
            if not callable(reader):
                return
            try:
                card = reader(mid)
            except Exception:
                return          # never let the guard itself refuse a write
            if isinstance(card, dict) and card.get("remote") is True:
                raise _ActionError(409, _REMOTE_LOCK_LINE)

        def _shipped_gate(self, mid, verb):
            """S197 — a write on a LOCAL mission the forge says is FINISHED.

            THE LEDGERED HALF OF S196's last round. The card already withdraws
            `✓ Review PR ▸` on a mission whose issue merged or closed on
            another laptop; the daemon went on accepting the POST behind it.
            A disabled button is not a lock — S190's own lesson, and the reason
            that round paired every withdrawn control with a server-side
            refusal.

            409, LIKE `_remote_gate` AND FOR THE SAME REASON. Nothing is
            missing and nothing is forbidden-to-this-user: the mission is over,
            and that is a CONFLICT WITH CURRENT STATE. (403 would say "not
            yours", which is the owner lock's sentence and a different fact —
            this mission IS the captain's; it has simply ended.)

            THE VERDICT IS THE ADAPTER'S, not a second implementation of one,
            and it costs NOTHING: `adapter.mission()` reads the SAME cached
            forge listing the board was built from, so this cannot re-create
            the S152 storm — pinned by an argv-counting test, not by this
            paragraph.

            AN UNREACHABLE FORGE NEVER LOCKS. `verdicts()` returns {} on any
            listing status but ok, so a card built during a bad cycle carries
            no `shippedElsewhere` key at all and the verb proceeds untouched.
            That posture is S190's D1 and it is preserved deliberately: a forge
            that did not answer must never be readable as a forge that said
            "over". The guard itself never refuses a write either — any
            exception reaching here allows it.
            """
            if verb not in _OWNER_LOCKED_VERBS:
                return
            reader = getattr(adapter, "mission", None)
            if not callable(reader):
                return
            try:
                card = reader(mid)
            except Exception:
                return          # never let the guard itself refuse a write
            if not isinstance(card, dict):
                return
            v = card.get("shippedElsewhere")
            if not isinstance(v, dict):
                return
            state = v.get("state")
            if state == "shipped":
                raise _ActionError(409, _SHIPPED_LOCK_LINE)
            if state == "closed":
                raise _ActionError(409, _CLOSED_LOCK_LINE)

        def _dispatch_verb(self, mid, verb, body):
            # REMOTE FIRST. "this mission is not driven from here" is the more
            # specific truth, and asking the ownership seam about an issue number
            # that has no local mission would only ever be able to shrug.
            self._remote_gate(mid, verb)
            # S197: …and OVER beats both of the below. "there is nothing left
            # to drive" is a more useful thing to be told than "this is someone
            # else's to drive", which is exactly the order board.js applies its
            # three sweeps in (applyShippedLock after applyOwnerLock, so its
            # sentence wins). One fact, both surfaces.
            self._shipped_gate(mid, verb)
            self._owner_gate(mid, verb)
            # S191: ADOPT — rebuild a REMOTE mission on this laptop. `mid` here is
            # the ISSUE NUMBER (a remote card has no local mission id yet), so it
            # is matched FIRST, before any verb that would try to resolve a local
            # mission dir. Deliberately NOT in _OWNER_LOCKED_VERBS: adopting is
            # how the captain takes command here, and adopt.sh does the claiming.
            if verb == "adopt":
                # S197: `engine` is the captain's answer at the board's adopt
                # picker — the question `lcars adopt` asks at a terminal and
                # this surface could not. ABSENT means he took the default (the
                # mission's own engine), and an absent key dispatches the exact
                # argv this daemon has always dispatched.
                return actions.adopt(mid, engine=body.get("engine"))
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
            # S109: launch a mission's app locally (Verify), and stop it. The
            # daemon owns the launched process group (see actions.launch). LOCAL-
            # only is automatic — a read-only build has actions=None (403'd above).
            if verb == "launch":
                return actions.launch(mid, hint=body.get("hint"))
            if verb == "launch/stop":
                return actions.launch_stop(mid)
            if verb == "log":
                # S161 fix round 3 (R1): `discardUnfiled` is the captain's explicit
                # "yes, throw away the authored bugs this session never got onto
                # disk". Absent, a preview that WOULD destroy such text is refused
                # by the daemon rather than performed — the console asks first.
                return actions.log_preview(
                    mid, text=body.get("text"), images=self._images(body),
                    discard_unfiled=bool(body.get("discardUnfiled")))
            if verb == "log/file":
                # S161: `sessionId` files the bugs the DAEMON already holds (and
                # returns promptly); the prds-in-body form is the unchanged legacy
                # path. sessionId wins when both are present.
                return actions.log_file(mid, prds=body.get("prds"),
                                        overrides=body.get("overrides"),
                                        images=self._images(body),
                                        image_refs=body.get("imageRefs"),
                                        session_id=body.get("sessionId"))
            if verb == "log/discard":
                # S161 D3 — Align's /cancel parity: throw away an ABANDONED
                # authoring session so its `logFiling` stamp stops sitting on the
                # parent card. Idempotent; refuses only mid-filing.
                return actions.log_discard(mid)
            if verb == "log/run":
                # S163 fix round 7 (D3): `resume` is the captain's "that drive
                # is gone, run these again" — the SAME endpoint and the same
                # resolve-logs spawn (no second dispatch path), granted only
                # where the daemon can see the resolver is not running.
                return actions.log_run(mid, prds=body.get("prds"),
                                       overrides=body.get("overrides"),
                                       confirm=bool(body.get("confirm")),
                                       images=self._images(body),
                                       image_refs=body.get("imageRefs"),
                                       resume=bool(body.get("resume")))
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

        # -- the holodeck preview: MODEL-WRITTEN bytes, from our own origin ----
        # Everything under this route was written by a language model into a
        # directory a language model controls, and it is served from the SAME
        # ORIGIN as the board. That is the whole reason these headers exist and
        # why they are not the ones `_send_file` sends:
        #
        #   Content-Security-Policy  the mockup may style and script ITSELF and
        #       nothing else: no network of any kind (`default-src 'none'`,
        #       `connect-src 'none'`), no plugins, no framing of other pages, and
        #       `form-action 'none'` so it cannot POST anywhere. `'unsafe-inline'`
        #       IS granted for script/style because a self-contained single-file
        #       mockup is inline by definition (ADR-007) — which is exactly why
        #       the ORIGIN isolation below, not the CSP, is the load-bearing half.
        #   X-Content-Type-Options: nosniff   a `.md` served as text/plain can
        #       never be re-read as HTML by a sniffing browser.
        #   X-Frame-Options / frame-ancestors 'self'   the board may frame it;
        #       nothing else may.
        #
        # THE LOAD-BEARING HALF IS IN THE IFRAME, NOT HERE: board.js renders this
        # route with `sandbox="allow-scripts"` and DELIBERATELY WITHOUT
        # `allow-same-origin`, which drops the frame into an opaque origin. That
        # is what stops model-written script reaching the board's DOM, its
        # cookies, or POSTing to the daemon's write API. The two flags together
        # would re-grant everything the sandbox took away, so they are never both
        # present — see the comment at the iframe.
        _PREVIEW_CSP = ("default-src 'none'; img-src 'self' data: blob:; "
                        "style-src 'self' 'unsafe-inline'; "
                        "script-src 'self' 'unsafe-inline'; "
                        "font-src 'self' data:; connect-src 'none'; "
                        "object-src 'none'; base-uri 'none'; "
                        "form-action 'none'; frame-ancestors 'self'")

        def _send_preview(self, got):
            body = got["bytes"]
            self.send_response(200)
            self.send_header("Content-Type", got["contentType"])
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", self._PREVIEW_CSP)
            self.send_header("X-Frame-Options", "SAMEORIGIN")
            self.send_header("Referrer-Policy", "no-referrer")
            # A turn rewrites the same path over and over; a cached preview is a
            # preview of the mockup you already approved (D3).
            self.send_header("Cache-Control", "no-store, must-revalidate")
            # NO Access-Control-Allow-Origin: unlike the board's own assets this
            # is untrusted content and nothing off-origin should be able to read
            # it back.
            self.end_headers()
            self.wfile.write(body)

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
            # Never let a browser heuristically cache the front-end assets: an
            # open (or soft-reloaded) tab must always fetch the CURRENT file
            # after the daemon restarts, or the captain keeps running stale JS
            # (board.js/board.css) and never receives front-end fixes without a
            # hard reload. `no-store` is the strongest directive here.
            self.send_header("Cache-Control", "no-store, must-revalidate")
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
