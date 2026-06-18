"""The LOCAL-BRIDGE write layer (S68).

Operator actions on the board — file / start / pause / resume / respond /
verify (approve|send-back) / log — are dispatched here. Each shells out to the
matching `lcars` skill script (ADR-002: dispatch, never reimplement Stage
logic). The harness scripts stay the single implementation of the pipeline; this
module is a thin HTTP→skill bridge.

ALL external dependencies are env-injected and stubbable: every skill path is a
key in `scripts`, and the worker engine is `worker_bin`. Tests point each path
at a recording stub and assert the dispatch (argv/stdin) without spending.

This is a LOCAL-BRIDGE concern only (ADR-006). The renderer/read path stays
adapter-neutral; a github/view-only daemon is built with NO Actions (the server
declines writes with 403), so the read build drops the write layer with no
rewrite. A write that changes `.git/lcars` moves the LocalAdapter fingerprint,
so the existing /api/events SSE loop carries the update — no second push path.

stdlib only; no pip/npm/build step (ADR-007).
"""
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import uuid

from .local_adapter import LocalAdapter


class ActionError(Exception):
    """Raised on a bad request (status carries the HTTP code to return)."""

    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


# The env seam names the daemon resolves each skill path from (mirrors how
# serve.sh env-injects). Used by the launcher/__main__ to build the script map.
SCRIPT_ENV = {
    "file": "LCARS_FILE_SCRIPT",
    "run": "LCARS_RUN_SCRIPT",
    "pause": "LCARS_PAUSE_SCRIPT",
    "respond": "LCARS_RESPOND_SCRIPT",
    "approve": "LCARS_APPROVE_SCRIPT",
    "feedback": "LCARS_FEEDBACK_SCRIPT",
    "log": "LCARS_LOG_SCRIPT",
    "resolve": "LCARS_RESOLVE_SCRIPT",
}


# A minimal, well-formed PRD skeleton. file.sh validates that the PRD carries
# every required section (# Mission / Type / Goal / Acceptance Criteria / Out of
# Scope / Constraints) before filing. Over HTTP the conversational Align grilling
# that normally authors a rich PRD is NOT driven (see DEFERRED in the report);
# the daemon materialises this tractable skeleton from the captain's idea so the
# mission is created and lands on the board, then Align is finished in the
# console (or a later S70 endpoint).
_PRD_TEMPLATE = """# Mission: {title}

**Type:** {type}

**Goal:** {idea}

**Acceptance Criteria:** To be refined in Align.
- The behaviour described above works end to end.

**Out of Scope:** To be refined in Align.

**Constraints:** To be refined in Align.
"""


# ── the worker-driven Align grilling + Log split (ADR-002: DRIVE the existing
# instructions, never reimplement Stage logic) ──────────────────────────────
#
# The interactive console is NEW ORCHESTRATION: the daemon owns the multi-turn
# loop, the in-memory session, and the transcript carry-forward. But the GRILLING
# ITSELF is the existing `lcars-file` Align guidance and the SPLIT is the existing
# `lcars-log` STEP-1 guidance — we load that prose verbatim from the SKILL.md
# files (never fork its wording) and wrap it in a thin JSON envelope so a headless
# worker can answer one turn at a time over HTTP.

# repo root = web/lcars_serve/ → web/ → repo/ ; the skills live under skills/.
_REPO_ROOT = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
_FILE_SKILL = os.path.join(_REPO_ROOT, "skills", "lcars-file", "SKILL.md")
_LOG_SKILL = os.path.join(_REPO_ROOT, "skills", "lcars-log", "SKILL.md")


def _load_skill(path):
    """Read a SKILL.md's body (its grilling/split prose) — the single source of
    truth for the interview. Returns "" if unreadable so the bridge degrades to
    the envelope alone rather than crashing (the worker still gets the contract).
    """
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


# The JSON envelope wraps the loaded SKILL.md prose. It does NOT restate the
# interview rules — it tells the headless worker HOW to return one turn at a time.
_ALIGN_ENVELOPE = """You are running the LCARS **Align** stage as a HEADLESS, \
single-turn worker driving the interview defined by the lcars-file skill below. \
You produce EXACTLY ONE turn per invocation and then STOP — the harness feeds \
your output back to the captain, collects their answer, and re-invokes you with \
the full transcript for the next turn. Follow the Align grilling rules verbatim \
(one question at a time, lead with your recommended answer, scale PRD/ADR depth \
to complexity, capture a model override only if the captain asks).

OUTPUT CONTRACT — print ONLY a single JSON object (no prose around it):
  • To ask the next question:
    {"status":"question",
     "question":{"text":"<the one question>",
                 "choices":["<opt>", ...],          // optional
                 "recommended":"<your lead answer>"},// optional
     "prd":"<the PARTIAL PRD markdown assembled so far>"}
  • When alignment is reached (the captain has confirmed the load-bearing
    decisions through the interview):
    {"status":"done",
     "prd":"<the FULL, well-formed PRD markdown>",
     "adr":"<the ADR markdown, or null for a trivial mission>",
     "modelOverride":"<scope:tier, or null>"}

The PRD/ADR shapes and the required sections are exactly as the skill specifies.
=== lcars-file skill (the Align interview — follow it) ===
"""

_LOG_ENVELOPE = """You are running the LCARS **Mission Log** STEP-1 split as a \
HEADLESS, single-turn worker driving the lcars-log skill below. Read the \
captain's free-form bug report, split it into N DISTINCT bugs exactly as the \
skill's STEP 1 + STEP 3 specify, and author one well-formed bug PRD per bug \
(Type always `bug`, the same shape as lcars-file). This is fast intake, not a \
grilling — one invocation, no questions.

OUTPUT CONTRACT — print ONLY a single JSON object (no prose around it):
  {"bugs":["<full bug PRD markdown #1>", "<full bug PRD markdown #2>", ...]}
=== lcars-log skill (the bug split — follow it) ===
"""


def _extract_json(text):
    """Pull the single JSON object the worker printed.

    Workers sometimes wrap output in a ```json fence or emit leading debug; be
    forgiving — find the first balanced top-level {...} and parse it. Returns the
    dict, or None if nothing parseable is found.
    """
    if not text:
        return None
    text = text.strip()
    # strip a ```json ... ``` fence if present.
    fence = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL)
    if fence:
        try:
            return json.loads(fence.group(1))
        except ValueError:
            pass
    # otherwise scan for the first balanced brace span.
    start = text.find("{")
    while start != -1:
        depth = 0
        for i in range(start, len(text)):
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    blob = text[start:i + 1]
                    try:
                        return json.loads(blob)
                    except ValueError:
                        break
        start = text.find("{", start + 1)
    return None


def _prd_title(prd):
    """Read the `# Mission: <title>` line off a PRD (the skill's source of truth)."""
    if not prd:
        return None
    m = re.search(r"^#\s*Mission:\s*(.+)$", prd, re.MULTILINE)
    return m.group(1).strip() if m else None


class _AlignSession(object):
    """In-memory state for one Align grilling, keyed by sessionId.

    Holds the idea, the running transcript (the Q/A pairs already exchanged), the
    latest partial PRD, and — the BUG-B fix — the WARM worker session UUID. The
    UI Align is ONE warm, resumable worker session (UI Align == CLI Align): turn
    1 OPENS the worker session (`--session-id <worker_sid>`) with the full grill
    (envelope + SKILL.md + idea); every later turn RESUMES that same UUID
    (`--resume <worker_sid>`) and feeds JUST the captain's latest answer — NO
    transcript re-feed, NO re-sent SKILL.md/envelope (the session already holds
    them). `started` tracks whether the worker session has been opened yet.

    Stdlib only; lives in the daemon process, dies with it (the HTTP
    request/response cycle IS the human gate — no persistence). With
    resume-by-id there is no long-lived child process to leak: "reaping" a
    session is just dropping its sid→session mapping.
    """

    __slots__ = ("idea", "engine", "transcript", "prd", "done",
                 "worker_sid", "started")

    def __init__(self, idea, engine):
        self.idea = idea
        self.engine = engine
        self.transcript = []   # list of {"question":..., "answer":...}
        self.prd = ""
        self.done = False
        # the WARM worker conversation UUID (canonical lowercase, valid for both
        # claude and copilot). Generated up front; the session is OPENED on the
        # first turn and RESUMED on every later turn.
        self.worker_sid = str(uuid.uuid4())
        self.started = False


class Actions(object):
    """Dispatch operator actions to the LCARS skill scripts.

    Parameters
    ----------
    repo_root : str
        The working tree whose .git/lcars the LocalAdapter reads. Skill scripts
        run with this as cwd so their `git rev-parse` resolves the right repo.
    scripts : dict
        key -> absolute path of the skill .sh to shell out to. Keys are those in
        SCRIPT_ENV. Tests inject recording stubs here.
    worker_bin : str | None
        The cold-worker CLI (the mission "engine"). Threaded to file/run as
        $LCARS_WORKER_BIN. None leaves the host default in place.
    gh_bin : str | None
        The gh binary, threaded to every script as $LCARS_GH_BIN.
    """

    def __init__(self, repo_root, scripts, worker_bin=None, gh_bin=None):
        self.repo_root = repo_root
        self.scripts = dict(scripts or {})
        self.worker_bin = worker_bin
        self.gh_bin = gh_bin
        self._reader = LocalAdapter(repo_root)
        # active Align grillings, keyed by sessionId (in-memory; ADR-006 local).
        self._align = {}
        self._align_lock = threading.Lock()

    # -- public action surface (one per endpoint) -------------------------------
    def file_mission(self, idea, engine=None, mission_type="feature"):
        """POST /api/mission — file a new mission from a free-form idea.

        engine selects the worker CLI ($LCARS_WORKER_BIN) for this mission.
        Returns the freshly-assembled board state.
        """
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        mtype = "bug" if str(mission_type).strip().lower() == "bug" else "feature"
        title = self._title_from_idea(idea)
        prd = _PRD_TEMPLATE.format(title=title, type=mtype, idea=idea)
        prd_path = self._tmp_prd(prd)
        env_extra = {}
        if engine:
            env_extra["LCARS_WORKER_BIN"] = engine
        try:
            self._run("file", ["--prd", prd_path], env_extra=env_extra)
        finally:
            try:
                os.unlink(prd_path)
            except OSError:
                pass
        return {"board": self._reader.board()}

    # -- the interactive Align grilling console (S70-B) --------------------------
    def align_start(self, idea, engine=None):
        """POST /api/align/start — open a multi-turn Align session.

        OPENS ONE warm, resumable worker session (BUG-B) driving the existing
        lcars-file Align grilling (envelope + SKILL.md prose) over the captain's
        idea, and returns the first question (or, for a trivial mission the worker
        resolves in one shot, status:"done" with the assembled PRD already filed).
        The session's worker UUID is minted on the _AlignSession and reused on
        every /answer (no per-question cold respawn, no transcript re-feed) so the
        UI Align is the SAME warm interview the CLI runs.
        """
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        sid = uuid.uuid4().hex[:12]
        sess = _AlignSession(idea=idea, engine=(engine or "").strip() or None)
        with self._align_lock:
            self._align[sid] = sess
        return self._align_turn(sid, sess)

    def align_answer(self, sid, answer):
        """POST /api/align/<sid>/answer — record the answer, run the next turn.

        RESUMES the same warm worker session (by its UUID) and feeds JUST the
        captain's latest answer — the prior context lives IN the session, so the
        daemon re-feeds NO transcript and NO SKILL.md/envelope (BUG-B). On done,
        dispatches file.sh.
        """
        with self._align_lock:
            sess = self._align.get(sid)
        if sess is None:
            raise ActionError(404, "no such align session: %s" % sid)
        answer = (answer or "").strip()
        if not answer:
            raise ActionError(400, "missing required field: answer")
        if sess.done:
            raise ActionError(409, "align session already completed")
        # attach the answer to the last asked question.
        if sess.transcript and sess.transcript[-1].get("answer") is None:
            sess.transcript[-1]["answer"] = answer
        else:
            sess.transcript.append({"question": "(implicit)", "answer": answer})
        return self._align_turn(sid, sess)

    def _align_turn(self, sid, sess):
        """Run one worker turn for `sess` and shape the HTTP response.

        Returns {sessionId, status:"question", question, prd} or, on done,
        files the mission and returns {sessionId, status:"done", prd, adr?, board}.
        """
        opening = not sess.started
        prompt = self._build_align_prompt(sess, opening=opening)
        out = self._worker_turn(prompt, engine=sess.engine,
                                session_id=sess.worker_sid, opening=opening)
        # the warm session is now open; every later turn resumes this UUID.
        sess.started = True
        turn = _extract_json(out)
        if not isinstance(turn, dict):
            raise ActionError(
                502, "the Align worker returned no parseable turn "
                "(engine=%s)" % (sess.engine or self.worker_bin or "default"))
        status = turn.get("status")
        if turn.get("prd"):
            sess.prd = turn["prd"]
        if status == "done":
            sess.done = True
            board = self._file_from_align(turn, engine=sess.engine)
            with self._align_lock:
                self._align.pop(sid, None)
            resp = {"sessionId": sid, "status": "done",
                    "prd": turn.get("prd", sess.prd)}
            if turn.get("adr"):
                resp["adr"] = turn["adr"]
            resp["board"] = board
            return resp
        # status == "question" (default): record the open question, return it.
        q = turn.get("question") or {}
        if isinstance(q, str):
            q = {"text": q}
        sess.transcript.append({"question": q.get("text", ""), "answer": None})
        return {"sessionId": sid, "status": "question",
                "question": q, "prd": sess.prd}

    def _file_from_align(self, turn, engine=None):
        """Persist a finished Align turn via file.sh (ADR-002 dispatch).

        `engine` is the per-session chosen engine: it is threaded to file.sh as
        $LCARS_WORKER_BIN so file.sh persists it as state.json.workerBin (S67),
        making the engine survive the real browser Align console flow — not just
        the direct /api/mission endpoint. Empty/None leaves the daemon default
        (self.worker_bin, injected by _run) in charge."""
        prd = (turn.get("prd") or "").strip()
        if not prd:
            raise ActionError(502, "the Align worker returned done with no PRD")
        prd_path = self._tmp_prd(prd + "\n")
        adr_path = None
        adr = (turn.get("adr") or "").strip()
        # 'null' string / None / empty → no ADR (trivial mission).
        if adr and adr.lower() != "null":
            adr_path = self._tmp_prd(adr + "\n")
        args = ["--prd", prd_path]
        if adr_path:
            args += ["--adr", adr_path]
        ov = (turn.get("modelOverride") or "").strip()
        if ov and ov.lower() != "null":
            args += ["--model-override", ov]
        env_extra = {}
        eng = (engine or "").strip()
        if eng:
            env_extra["LCARS_WORKER_BIN"] = eng
        try:
            self._run("file", args, env_extra=env_extra)
        finally:
            for p in (prd_path, adr_path):
                if p:
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
        return self._reader.board()

    def align_cancel(self, sid):
        """POST /api/align/<sid>/cancel — reap a live Align console.

        With resume-by-id there is NO subprocess to kill — reaping is dropping
        the sid→session mapping so the warm worker UUID is never resumed again
        (the CLI's stored session ages out on its own). Caps one live session per
        console; a subsequent answer to the reaped sid 404s. Idempotent.
        """
        with self._align_lock:
            self._align.pop(sid, None)
        return {"sessionId": sid, "status": "cancelled"}

    def _build_align_prompt(self, sess, opening=True):
        """Assemble the worker prompt for ONE turn.

        OPENING turn (opening=True): the FULL grill — envelope + the SKILL.md
        prose (the single source of truth) + the captain's idea. This OPENS the
        warm worker session.

        CONTINUATION turn (opening=False): the warm worker session already HOLDS
        the envelope, SKILL.md and the prior exchanges, so we send JUST the
        captain's latest answer plus a SHORT reminder of the output contract. We
        do NOT re-feed the accumulated transcript and do NOT resend the
        envelope/SKILL.md — that re-feed removal is the whole point of BUG-B (the
        cost win) and keeps UI Align == CLI Align (the warm CLI session carries
        context, it never re-reads it).
        """
        if not opening:
            answer = ""
            if sess.transcript:
                last = sess.transcript[-1]
                answer = last.get("answer") or ""
            return ("The captain's answer: %s\n\n"
                    "Produce the next turn now, as a single JSON object "
                    "(the same output contract as before)." % answer)
        skill = _load_skill(_FILE_SKILL)
        parts = [_ALIGN_ENVELOPE, skill,
                 "\n=== the captain's idea ===\n", sess.idea,
                 "\n\nAsk the FIRST question now, as a single JSON object."]
        return "".join(parts)

    def _worker_turn(self, prompt, engine=None, outdir=None,
                     session_id=None, opening=True):
        """The ONE injectable worker seam: run a one-shot turn and return its
        stdout. The engine is $LCARS_WORKER_BIN (overridable per-session); tests
        point it at a recording stub so a turn costs ZERO tokens.

        WARM continuation (BUG-B): when `session_id` is given, the turn is part of
        a resumable conversation. The OPENING turn (opening=True) starts it with
        `--session-id <uuid>`; every CONTINUATION turn (opening=False) RESUMES it
        with `--resume <uuid>`, so turn 2+ carry the prior context IN THE SESSION
        — the daemon re-feeds nothing. Each turn is still a short-lived `<bin> -p`
        invocation (no persistent child to leak); only the conversation is warm.

        The session-flag SYNTAX is engine-aware (per the S72 spike):
          • claude : space-form  `--session-id <uuid>` / `--resume <uuid>`
          • copilot: equals-form `--session-id=<uuid>` / `--resume=<uuid>`,
            plus `--available-tools=` (deny ALL tools — the pure-reasoning grill
            emits its JSON turn directly instead of via the bash tool; S72 fix).
        When `session_id` is None the turn is a plain cold one-shot (the Log
        worker path) — no session flags, unchanged.

        Mirrors worker-adapter.sh's `"$bin" -p "$prompt"` shape (ADR-002 — the
        same cold-worker invocation every other Stage uses); the multi-turn loop
        lives here in the daemon, NOT in the worker prompt logic.
        """
        bin_ = engine or self.worker_bin
        if not bin_:
            raise ActionError(
                502, "no worker engine configured ($LCARS_WORKER_BIN) — cannot "
                "drive the Align/Log worker")
        own_outdir = outdir is None
        if own_outdir:
            outdir = tempfile.mkdtemp(prefix="lcars-worker-", dir=self.repo_root)
        env = dict(os.environ)
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        env["LCARS_WORK_OUT"] = outdir
        cmd = [bin_, "-p", prompt] + self._session_args(
            bin_, session_id, opening)
        try:
            proc = subprocess.run(
                cmd, cwd=self.repo_root, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT)
        except OSError as exc:
            raise ActionError(502, "worker engine failed to start: %s" % exc)
        finally:
            if own_outdir:
                try:
                    shutil.rmtree(outdir, ignore_errors=True)
                except OSError:
                    pass
        return (proc.stdout or b"").decode("utf-8", "replace")

    @staticmethod
    def _session_args(bin_, session_id, opening):
        """The engine-aware warm-session CLI flags (BUG-B / S72 spike).

        Returns [] for a plain cold one-shot (session_id None). Otherwise opens
        (`--session-id`) or resumes (`--resume`) the conversation by UUID, in the
        syntax the engine's basename selects.
        """
        if not session_id:
            return []
        base = os.path.basename(bin_ or "").lower()
        is_copilot = "copilot" in base
        if is_copilot:
            flag = ("--session-id=%s" if opening else "--resume=%s") % session_id
            # The Align grill is a PURE REASONING task (idea + SKILL.md envelope
            # → JSON turn); it needs NO repo tools. Granting tools
            # (`--allow-all-tools`) made copilot EMIT the JSON turn via its `bash`
            # tool, so its final stdout message was prose-only ("Next question
            # emitted...") — the daemon found no parseable JSON and 502'd ("the
            # Align worker returned no parseable turn", S72 BUG-fix). DENY tools
            # with `--available-tools=` (ONE argv token, empty value ⇒ no tools
            # available): copilot then prints the raw JSON directly. We ALSO keep
            # the MCP-discipline flags the cold Stage workers pass
            # (skills/lcars-run/worker-adapter.sh): without them copilot re-boots
            # its builtin MCP servers + custom instructions on EVERY warm-Align
            # turn (26.3s → 13.1s/turn measured, S72). The grill needs neither.
            return [flag, "--available-tools=", "--no-ask-user",
                    "--disable-builtin-mcps", "--no-custom-instructions"]
        # claude (and the default): space-form args.
        return (["--session-id", session_id] if opening
                else ["--resume", session_id])

    def start(self, mid, override=None):
        """POST /api/mission/<id>/start — drive the run, FIRE-AND-FORGET.

        The run driver is a LONG, multi-stage process. If start() blocked on it
        (the S68 behaviour), the HTTP request hung for the whole run, the board
        never reflected "running", and the captain re-clicked Start — which spun
        up a SECOND driver racing the first (BUG-A: three concurrent drivers, real
        credit waste). So start() now SPAWNS the driver in the background and
        returns promptly; the board/SSE reflects progress + the `running` flag.

        Defense-in-depth with run.sh's per-mission driver lock: if a live driver
        already holds this mission, start() is a clean no-op (returns current
        state) rather than spawning another.
        """
        self._require_mission(mid)
        # Guard: already running ⇒ do not spawn a second driver. (run.sh's lock is
        # the authoritative single-instance guard; this avoids even the spawn.)
        if self._is_running(mid):
            return self._mission_state(mid)

        env_extra = {}
        ov = (override or "").strip()
        if ov:
            # the plain-language override is passed through to the run driver via
            # $LCARS_MODEL_OVERRIDE (run.sh's active_model_override reads it).
            env_extra["LCARS_MODEL_OVERRIDE"] = ov
        # The chosen engine (S67): read the engine the captain picked at file time
        # (persisted by file.sh as state.json.workerBin) and feed it to the run
        # driver as $LCARS_WORKER_BIN, so the WHOLE pipeline runs on that engine
        # instead of host-detecting claude. env wins over run.sh's host-detect
        # (its resolution is env > config > host-detect > claude — we don't touch
        # that precedence, just feed it the env). Config-dispatch, not Stage logic
        # (ADR-002). Empty/absent ⇒ leave it unset (host-detect stays in charge).
        engine = self._persisted_worker_bin(mid)
        if engine and "LCARS_WORKER_BIN" not in env_extra:
            env_extra["LCARS_WORKER_BIN"] = engine
        self._spawn("run", ["drive", "--mission", mid], env_extra=env_extra)
        return self._mission_state(mid)

    def _is_running(self, mid):
        """True iff a live driver lock is held for this mission (LocalAdapter)."""
        try:
            detail = self._reader.mission(mid)
        except Exception:
            return False
        return bool(detail and detail.get("running"))

    def _persisted_worker_bin(self, mid):
        """The engine the captain chose at file time (state.json.workerBin)."""
        sp = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                          "state.json")
        wb = _read_json_key(sp, "workerBin")
        if isinstance(wb, str) and wb.strip():
            return wb.strip()
        return None

    def pause(self, mid):
        """POST /api/mission/<id>/pause."""
        self._require_mission(mid)
        self._run("pause", ["pause", mid])
        return self._mission_state(mid)

    def resume(self, mid):
        """POST /api/mission/<id>/resume."""
        self._require_mission(mid)
        self._run("pause", ["resume", mid])
        return self._mission_state(mid)

    def respond(self, mid, answer):
        """POST /api/mission/<id>/respond — answer a gate."""
        self._require_mission(mid)
        answer = (answer or "").strip()
        if not answer:
            raise ActionError(400, "missing required field: answer")
        self._run("respond", ["answer", "--mission", mid, "--answer", answer])
        return self._mission_state(mid)

    def verify(self, mid, decision, feedback=None):
        """POST /api/mission/<id>/verify — approve vs send-back.

        decision == "approve"   → approve.sh (open PR, mark done)
        decision == "send-back" → feedback.sh (--feedback note → back to Align)
        These route to TWO DIFFERENT skills.
        """
        self._require_mission(mid)
        decision = (decision or "").strip().lower()
        if decision == "approve":
            self._run("approve", ["--mission", mid])
        elif decision in ("send-back", "sendback", "send_back"):
            note = (feedback or "").strip()
            if not note:
                raise ActionError(400, "send-back requires a 'feedback' note")
            self._run("feedback", ["--mission", mid, "--feedback", note])
        else:
            raise ActionError(
                400, "decision must be 'approve' or 'send-back' (got %r)"
                % decision)
        return self._mission_state(mid)

    def log_preview(self, mid, text=None):
        """POST /api/mission/<id>/log — preview the N child bug missions.

        Two modes:
          • text given → AUTHORING preview. Dispatch ONE cold worker turn driving
            the existing lcars-log STEP-1 split over the free-form report; parse
            the authored bug PRDs into a preview list WITHOUT persisting. "File &
            Run Fixes" then dispatches log.sh + resolve-logs (log_run).
          • no text → READ-ONLY preview of the bug missions ALREADY linked to this
            parent (state.json.parentMission == mid). Keeps the S68 behaviour so
            the board can show an already-filed batch with no worker spend.
        """
        self._require_mission(mid)
        text = (text or "").strip()
        if not text:
            children = self._linked_children(mid)
            return {"children": children, "count": len(children),
                    "parent": mid, "authored": False}
        return self._log_author(mid, text)

    def _log_author(self, parent, text):
        """Author N bug PRDs from a free-form report via one worker turn.

        Returns a preview {children:[{title, prd, type}], count} WITHOUT
        persisting; the authored PRDs are held in-memory on the response so the
        front end can show them and the captain confirms before log.sh runs.
        """
        skill = _load_skill(_LOG_SKILL)
        prompt = "".join([_LOG_ENVELOPE, skill,
                          "\n=== the captain's bug report ===\n", text,
                          "\n\nSplit it and author the bug PRDs now, as a single "
                          "JSON object."])
        # BUG-C: the Log dialog has no engine picker and the daemon has no default
        # engine (engine is per-mission), so the Log worker must INHERIT the
        # PARENT mission's persisted engine (state.json.workerBin). Falls back to
        # _worker_turn's default (None) when the parent has none.
        engine = self._persisted_worker_bin(parent)
        out = self._worker_turn(prompt, engine=engine)
        turn = _extract_json(out)
        bugs = (turn or {}).get("bugs") if isinstance(turn, dict) else None
        if not isinstance(bugs, list) or not bugs:
            raise ActionError(
                502, "the Mission-Log worker returned no bug PRDs from the report")
        children = []
        for prd in bugs:
            if not isinstance(prd, str) or not prd.strip():
                continue
            children.append({"title": _prd_title(prd) or "Untitled bug",
                             "type": "bug", "prd": prd})
        return {"children": children, "count": len(children),
                "parent": parent, "authored": True}

    def log_run(self, mid, prds=None):
        """POST /api/mission/<id>/log/run — file authored bugs, then resolve.

        If `prds` (the authored bug PRDs from the preview) are supplied, FIRST
        dispatch log.sh --parent <id> --prd <each> to persist one linked bug
        mission per PRD (ADR-002), THEN kick resolve-logs to drive them to the one
        consolidated re-verify gate. With no prds it just resolves whatever is
        already linked (the S68 read-only batch).
        """
        self._require_mission(mid)
        # BUG-C: the child bug missions inherit the PARENT's persisted engine.
        # Setting LCARS_WORKER_BIN on the log.sh dispatch makes file/log.sh persist
        # workerBin=<parent engine> on each child; setting it on resolve-logs drives
        # those children on the parent's engine. Absent ⇒ leave unset (no force).
        engine = self._persisted_worker_bin(mid)
        env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
        prds = [p for p in (prds or []) if isinstance(p, str) and p.strip()]
        if prds:
            tmp = []
            args = ["--parent", mid]
            try:
                for prd in prds:
                    p = self._tmp_prd(prd.rstrip() + "\n")
                    tmp.append(p)
                    args += ["--prd", p]
                self._run("log", args, env_extra=env_extra)
            finally:
                for p in tmp:
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
        # BUG-G: resolve-logs drives the ENTIRE batch (every logged bug → Verify +
        # the consolidated re-verify gate) — minutes. Blocking on it (the old _run)
        # hung the POST until the whole batch finished, so the dialog spun and the
        # browser reset the connection. Fire-and-forget it like start()'s `run drive`
        # (_spawn = detached Popen) so the POST returns PROMPTLY after the children
        # are filed; the board/SSE then carries the wave progress. The engine env
        # (BUG-D) is preserved — _spawn carries env_extra exactly as _run did.
        self._spawn("resolve", ["--parent", mid], env_extra=env_extra)
        return self._mission_state(mid)

    # -- internals --------------------------------------------------------------
    def _resolve_run(self, key, args, env_extra):
        """Shared dispatch prep: resolve the script path + build the env.

        Returns (cmd, env). The env wiring (gh bin, default worker bin, then
        env_extra overrides) is identical for the blocking _run and the
        fire-and-forget _spawn so they never drift.
        """
        script = self.scripts.get(key)
        if not script:
            raise ActionError(500, "no script wired for action '%s'" % key)
        env = dict(os.environ)
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        if self.worker_bin and "LCARS_WORKER_BIN" not in (env_extra or {}):
            env["LCARS_WORKER_BIN"] = self.worker_bin
        if env_extra:
            env.update(env_extra)
        return ["bash", script] + list(args), env

    def _run(self, key, args, env_extra=None):
        """Blocking dispatch — for the SHORT commands (file/pause/resume/respond/
        verify/log). Waits for the skill and surfaces a non-zero exit."""
        cmd, env = self._resolve_run(key, args, env_extra)
        proc = subprocess.run(cmd, cwd=self.repo_root, env=env,
                              stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            out = (proc.stdout or b"").decode("utf-8", "replace").strip()
            raise ActionError(
                502, "skill '%s' exited %d: %s" % (key, proc.returncode, out))
        return proc

    def _spawn(self, key, args, env_extra=None):
        """Fire-and-forget dispatch — for the LONG `run drive` driver. Launches
        the skill DETACHED (Popen, never waited on) so the HTTP request returns
        promptly; the board/SSE then reflects progress and the `running` flag.

        Output is discarded (the run's truth is its on-disk state + events.jsonl,
        which the SSE already carries) so a full pipe can never wedge the daemon.
        start_new_session detaches the child from the daemon's process group, so
        a daemon restart / Ctrl-C doesn't take a running mission down with it.
        Returns the Popen handle (the caller does NOT wait)."""
        cmd, env = self._resolve_run(key, args, env_extra)
        try:
            return subprocess.Popen(
                cmd, cwd=self.repo_root, env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                start_new_session=True)
        except OSError as exc:
            raise ActionError(502, "failed to launch skill '%s': %s" % (key, exc))

    def _require_mission(self, mid):
        d = os.path.join(self.repo_root, ".git", "lcars", "missions", mid)
        if not (mid and os.path.isfile(os.path.join(d, "state.json"))):
            raise ActionError(404, "no such mission: %s" % mid)

    def _mission_state(self, mid):
        detail = self._reader.mission(mid)
        if detail is None:
            # the action may have moved it (e.g. approve → done is still present);
            # fall back to the whole board so the caller always gets fresh state.
            return {"board": self._reader.board()}
        return {"mission": detail}

    def _linked_children(self, parent):
        out = []
        missions_dir = os.path.join(self.repo_root, ".git", "lcars", "missions")
        if not os.path.isdir(missions_dir):
            return out
        for name in sorted(os.listdir(missions_dir)):
            sp = os.path.join(missions_dir, name, "state.json")
            if not os.path.isfile(sp):
                continue
            card = self._reader.mission(name)
            if card is None:
                continue
            # read parentMission straight off disk (not part of the card shape).
            pm = _read_json_key(sp, "parentMission")
            if pm == parent:
                out.append({"id": card["id"], "issue": card.get("issue"),
                            "title": card.get("title"), "stage": card.get("stage"),
                            "type": card.get("type")})
        return out

    @staticmethod
    def _title_from_idea(idea):
        first = idea.splitlines()[0].strip() if idea else "New mission"
        if len(first) > 72:
            first = first[:69].rstrip() + "..."
        return first or "New mission"

    def _tmp_prd(self, content):
        fd, path = tempfile.mkstemp(prefix="lcars-prd-", suffix=".md",
                                    dir=self.repo_root)
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        return path


def _read_json_key(path, key):
    """Cheap flat reader for a top-level string key (jq-free, stdlib-only)."""
    import json
    try:
        with open(path) as fh:
            obj = json.load(fh)
    except (OSError, ValueError):
        return None
    return obj.get(key) if isinstance(obj, dict) else None


def build_actions(repo_root, worker_bin=None, gh_bin=None, env=None):
    """Resolve every skill path from its env seam and build an Actions.

    Each path defaults to the installed skill under ~/.claude/skills/<name>/ (the
    symlink install.sh creates), overridable via the SCRIPT_ENV var so tests and
    alternative installs can point elsewhere. Returns None if the script dir
    can't be located AND no overrides are set (caller then runs read-only).
    """
    env = env if env is not None else os.environ
    home = env.get("HOME", os.path.expanduser("~"))
    default_dir = {
        "file": os.path.join(home, ".claude/skills/lcars-file/file.sh"),
        "run": os.path.join(home, ".claude/skills/lcars-run/run.sh"),
        "pause": os.path.join(home, ".claude/skills/lcars-pause/pause.sh"),
        "respond": os.path.join(home, ".claude/skills/lcars-respond/respond.sh"),
        "approve": os.path.join(home, ".claude/skills/lcars-approve/approve.sh"),
        "feedback": os.path.join(home, ".claude/skills/lcars-feedback/feedback.sh"),
        "log": os.path.join(home, ".claude/skills/lcars-log/log.sh"),
        "resolve": os.path.join(
            home, ".claude/skills/lcars-resolve-logs/resolve-logs.sh"),
    }
    scripts = {}
    for key, default in default_dir.items():
        scripts[key] = env.get(SCRIPT_ENV[key], default)
    return Actions(repo_root=repo_root, scripts=scripts,
                   worker_bin=worker_bin, gh_bin=gh_bin)
