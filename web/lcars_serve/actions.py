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
import atexit
import base64
import binascii
import json
import os
import re
import shutil
import signal
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
    # S109: `lcars launch` — get a mission's app running locally during Verify.
    "launch": "LCARS_LAUNCH_SCRIPT",
    # S130: the shared version helper the /api/update button shells (check.sh).
    "version_check": "LCARS_VERSION_CHECK_BIN",
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
                 "recommended":"<your lead answer>", // optional
                 "closing":true},                    // ONLY on the final turn
     "prd":"<the PARTIAL PRD markdown assembled so far>"}
  • When alignment is reached (the captain has confirmed the load-bearing
    decisions through the interview):
    {"status":"done",
     "prd":"<the FULL, well-formed PRD markdown>",
     "adr":"<the ADR markdown, or null for a trivial mission>",
     "modelOverride":"<scope:tier, or null>"}

The CLOSING turn (per the skill): when you believe alignment is reached, your
LAST question MUST be the explicit "anything else before I file?" check-in, and
that question object MUST carry "closing":true so the captain's UI can show the
"estimating & creating mission" phase when they confirm. Do NOT emit status:done
until the captain has answered that closing question affirmatively.

CLOSING-QUESTION BREVITY (UI parity, BUG-072): the captain's UI renders the
assembled PRD LIVE in a panel beside the question from your "prd" field. So the
closing question "text" must be ONLY the concise lead-in — e.g. "Perfect — the
complete PRD is on the right. Anything else before I lock it?" — and must NOT
restate or inline the PRD body (Type/Goal/Acceptance Criteria/Out of Scope/
Constraints). Put the full PRD in the "prd" field as always; never duplicate it
into the question text.

The PRD/ADR shapes and the required sections are exactly as the skill specifies.
=== lcars-file skill (the Align interview — follow it) ===
"""

_LOG_ENVELOPE = """You are running the LCARS **Mission Log** STEP-1 split as a \
HEADLESS, single-turn worker driving the lcars-log skill below. Read the \
captain's free-form bug report, split it into N DISTINCT bugs exactly as the \
skill's STEP 1 + STEP 3 specify, and author one well-formed bug PRD per bug \
(Type always `bug`, the same shape as lcars-file). This is fast intake, not a \
grilling — one invocation, no questions.

OUTPUT CONTRACT — print ONLY a single JSON object (no prose around it). Use the
per-bug object form so you can route pasted screenshots to the bug they show:
  {"bugs":[{"prd":"<full bug PRD markdown #1>","imageRefs":[1]},
           {"prd":"<full bug PRD markdown #2>","imageRefs":[2]}, ...]}
The legacy plain-string form is still accepted (each is treated as no image
refs): {"bugs":["<full bug PRD markdown #1>", ...]}

IMAGE ROUTING (only when the captain pasted screenshots): the screenshots are
shown to you numbered image 1, image 2, … in the order they were pasted. For
EACH bug, put in its "imageRefs" ONLY the 1-based numbers the report EXPLICITLY
ties to that bug (e.g. "the first screenshot shows the crash", "image 2 is the
alignment bug"). This is pure ordinal text-parsing — map the report's wording to
the numbers, do NOT try to match image content. Rules:
  • An image the report ties to NO specific bug: OMIT it everywhere (leave it out
    of every imageRefs). The harness gives such unreferenced images to ALL bugs.
  • A bug the report ties to NO image: give it an empty/absent imageRefs.
  • Ambiguous singular wording ("the screenshot" when several were pasted): treat
    it as tied to no specific bug — omit it (so it goes to all bugs).
=== lcars-log skill (the bug split — follow it) ===
"""


# BUG-073: the signal an EMPTY Submit feeds the grill — "nothing to add, accept
# the recommendation, proceed". The grill already handles "proceed"/"go ahead"
# (see the closing turn in skills/lcars-file/SKILL.md). Spelled out so the worker
# treats it as the captain's affirmative, not as a new requirement.
_PROCEED_ANSWER = ("(no additional input — accept your recommendation and "
                   "proceed)")


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


# BUG-072: markers that signal a PRD body has begun inside a question's text.
# The closing-confirm question should be just the concise lead-in; if the worker
# inlines the PRD, the text crosses into PRD territory at the FIRST of these.
_PRD_BODY_MARKERS = re.compile(
    r"(?im)^\s*(?:#\s*Mission\s*:|\*\*Type\*\*\s*:|\*\*Goal\*\*\s*:|"
    r"\*\*Acceptance\s+Criteria\*\*\s*:|\*\*Out\s+of\s+Scope\*\*\s*:|"
    r"\*\*Constraints\*\*\s*:)")


def _strip_inlined_prd(question_text, prd):
    """Return `question_text` with any inlined PRD body removed (BUG-072).

    The closing/confirm question must be a concise lead-in only — the PRD already
    flows to the live-PRD panel via the `prd` field. A worker that restates the
    PRD inside the question body crosses into PRD territory at the first PRD
    section marker (`# Mission:`, `**Type:**`, `**Goal:**`, …); truncate there and
    keep just the lead-in. If the whole question IS the PRD (no lead-in), or there
    is no marker, fall back gracefully: prefer a non-empty lead-in, else leave the
    text untouched so we never blank the question.
    """
    if not question_text:
        return question_text
    m = _PRD_BODY_MARKERS.search(question_text)
    if not m:
        return question_text
    lead = question_text[:m.start()].rstrip()
    # only strip if there's a real lead-in to keep; if the question is ALL PRD
    # (marker at the very start), leave it as-is rather than emit an empty prompt.
    return lead if lead else question_text


def _prd_title(prd):
    """Read the `# Mission: <title>` line off a PRD (the skill's source of truth)."""
    if not prd:
        return None
    m = re.search(r"^#\s*Mission:\s*(.+)$", prd, re.MULTILINE)
    return m.group(1).strip() if m else None


def _route_images(image_refs, n):
    """The ONE deterministic image-routing formula (Mission-Log per-bug images).

    Given `image_refs` (a list parallel to the bugs; each element is the 1-based
    image indices the report EXPLICITLY tied to that bug — a list, or None) and
    `n` (the number of pasted images, numbered 1..n in paste order), return
    `(orphaned, explicit, union)` where:
      • explicit[i] — sorted, de-duplicated, in-range (1..n) refs for bug i.
      • orphaned    — sorted 1..n indices NO bug referenced.
      • union[i]    — sorted(explicit[i] ∪ orphaned) = that bug's FINAL image set.

    The rule per bug is exactly union = explicit ∪ orphaned:
      • no refs anywhere → every image orphaned → every bug gets all images
        (today's all-to-all default);
      • an image tied to some bug is NOT orphaned → other bugs don't get it unless
        they reference it too;
      • a bug that referenced nothing, when all images are assigned, gets [].
    """
    refs = list(image_refs or [])
    explicit = []
    referenced = set()
    for r in refs:
        valid = sorted({k for k in (r or [])
                        if isinstance(k, int) and 1 <= k <= n})
        explicit.append(valid)
        referenced.update(valid)
    orphaned = [k for k in range(1, n + 1) if k not in referenced]
    union = [sorted(set(e) | set(orphaned)) for e in explicit]
    return orphaned, explicit, union


# ── the per-bug model-override NORMALIZER (S74 follow-up) ─────────────────────
# A MISSION's override is normalized by the Align worker — the captain says "use
# Opus the whole way" and the worker emits a structured `<scope>:<tier>` (see
# skills/lcars-file/SKILL.md:183-186). A LOGGED bug skips Align, so the web
# Mission-Log per-bug override had NO normalizer and silently dropped anything
# that wasn't already `<scope>:<tier>` — the child then ran on the wrong (default
# Sonnet) model. This gives the bug override the SAME normalization, HYBRID:
#   1. passthrough an already-structured value,
#   2. a deterministic plain-language parse (the common cases, zero tokens),
#   3. one bounded worker call applying the Align instruction (the long tail),
#   4. NEVER silent-drop — an unparseable value returns None so the caller can
#      surface an error instead of running on a wrong/default model.
_VALID_SCOPES = ("all", "reasoning", "implementation")
_VALID_TIERS = ("sonnet", "opus")
_STRUCTURED_OVERRIDE = re.compile(
    r"^(all|reasoning|implementation):(sonnet|opus)$", re.IGNORECASE)

# The SAME instruction the Align worker uses (skills/lcars-file/SKILL.md:183-186),
# narrowed to the single normalization task: plain language → `<scope>:<tier>`.
_OVERRIDE_FALLBACK_PROMPT = """You normalize a captain's free-form model steer \
for one LCARS mission into a single structured model override, EXACTLY as the \
Align stage does (lcars-file skill: "Detect that intent ('use Opus the whole \
way', 'keep it cheap') and normalize it to a single structured modelOverride").

The override has two axes:
  • scope — `all` (every stage), `reasoning` (Research/Validate/Plan/Plan Review)
    or `implementation` (Implement/Verify). Default to `all` if unstated.
  • tier  — `opus` (higher quality) or `sonnet` (cheaper).

Output ONLY the string `<scope>:<tier>` (e.g. `all:opus`) on a line by itself,
or the bare word `null` if the steer expresses no model intent. No prose.

The captain's steer:
"""


def _parse_scope_tier(text):
    """Pull a `<scope>:<tier>` out of arbitrary worker/text output (lenient).

    Returns {"scope","tier"} or None. Accepts a bare `scope:tier` token, a
    quoted/fenced one, or a JSON blob whose value is `scope:tier`.
    """
    if not text:
        return None
    t = text.strip()
    if t.lower() in ("null", '"null"', "none", ""):
        return None
    # a JSON object/string the worker may have emitted (e.g. {"modelOverride": "..."}).
    obj = _extract_json(t)
    if isinstance(obj, dict):
        for v in obj.values():
            got = _parse_scope_tier(v) if isinstance(v, str) else None
            if got:
                return got
    elif isinstance(obj, str):
        got = _parse_scope_tier(obj)
        if got:
            return got
    m = re.search(r"\b(all|reasoning|implementation)\s*:\s*(sonnet|opus)\b",
                  t, re.IGNORECASE)
    if m:
        return {"scope": m.group(1).lower(), "tier": m.group(2).lower()}
    return None


def _deterministic_override(raw):
    """Step 2: map common plain language to {scope,tier} with no worker spend.

    Detects a TIER first (opus / 4.8 / sonnet / 4.6 / cheap-family); without a
    tier the steer is inconclusive (return None → caller falls back to the LLM).
    Scope defaults to `all` unless reasoning/implementation language is present.
    """
    low = raw.lower()
    # tier
    tier = None
    if re.search(r"\bopus\b", low) or re.search(r"4[._-]?8\b", low):
        tier = "opus"
    elif (re.search(r"\bsonnet\b", low) or re.search(r"4[._-]?6\b", low)
          or re.search(r"\b(cheap|cheaper|budget|inexpensive|save|saving)\b", low)):
        tier = "sonnet"
    if tier is None:
        return None  # inconclusive → LLM fallback
    # scope (default all)
    if re.search(r"\b(reason|reasoning|think|thinking|plan|planning)\b", low):
        scope = "reasoning"
    elif re.search(r"\b(implement|implementation|impl|coding|code|build|building)\b",
                   low):
        scope = "implementation"
    else:
        scope = "all"
    return {"scope": scope, "tier": tier}


def normalize_override(raw, worker=None):
    """Normalize a captain's free-form per-bug model steer → {scope,tier}|None.

    HYBRID (S74 follow-up):
      1. blank → None (no steer, NOT an error);
      2. already `<scope>:<tier>` → passthrough (case/space-insensitive);
      3. deterministic plain-language parse (zero tokens);
      4. if inconclusive AND a `worker(raw)->str` callable is supplied, ONE
         bounded worker call applying the Align instruction; its reply is parsed.
    Returns None when nothing resolves — the caller MUST surface an error rather
    than run the child on a wrong/default model (never silent-drop).
    """
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not s:
        return None
    m = _STRUCTURED_OVERRIDE.match(s)
    if m:
        return {"scope": m.group(1).lower(), "tier": m.group(2).lower()}
    got = _deterministic_override(s)
    if got:
        return got
    if worker is None:
        return None
    try:
        reply = worker(s)
    except Exception:
        return None
    return _parse_scope_tier(reply)


def _override_error(raw):
    """The human-facing message when a steer can't be normalized (never drop)."""
    return ("couldn't understand the model steer %r — try e.g. \"use Opus\" "
            "or \"keep it cheap\"" % (raw or "").strip())


def _override_label(resolved):
    """A human steer label for the UI echo, e.g. 'Opus · all stages'."""
    if not resolved:
        return None
    tier = "Opus" if resolved.get("tier") == "opus" else "Sonnet"
    scope = {"all": "all stages", "reasoning": "reasoning stages",
             "implementation": "implementation stages"}.get(
                 resolved.get("scope"), resolved.get("scope"))
    return "%s · %s" % (tier, scope)


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
                 "worker_sid", "started", "image_paths", "mission_id")

    def __init__(self, idea, engine, mission_id=None):
        self.idea = idea
        self.engine = engine
        # Park & Align (S137): when this grill completes the alignment of an
        # ALREADY-PARKED mission (filed pre-PRD via `lcars file --park`), its id
        # is carried here so the done branch dispatches `file.sh --complete <id>`
        # (grill-completion IN PLACE) instead of a fresh `--prd` filing. None ⇒ a
        # normal File-console grill that files a brand-new mission (unchanged).
        self.mission_id = mission_id
        self.transcript = []   # list of {"question":..., "answer":...}
        self.prd = ""
        self.done = False
        # the WARM worker conversation UUID (canonical lowercase, valid for both
        # claude and copilot). Generated up front; the session is OPENED on the
        # first turn and RESUMED on every later turn.
        self.worker_sid = str(uuid.uuid4())
        self.started = False
        # S91 — every image the captain has pasted across this grill's turns,
        # staged on disk under repo_root. Accumulated (not reset per turn) so
        # claude can Read an earlier turn's image if a later turn references it;
        # reaped when the session ends (done or cancel) so nothing leaks.
        self.image_paths = []


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

    def __init__(self, repo_root, scripts, worker_bin=None, gh_bin=None,
                 check_script=None):
        self.repo_root = repo_root
        self.scripts = dict(scripts or {})
        self.worker_bin = worker_bin
        self.gh_bin = gh_bin
        # S130: the shared version helper (skills/lcars-version/check.sh) the
        # /api/update button shells in `update` mode. Falls back to a `scripts`
        # entry so a directly-constructed Actions can still wire it.
        self.check_script = check_script or self.scripts.get("version_check")
        self._reader = LocalAdapter(repo_root)
        # active Align grillings, keyed by sessionId (in-memory; ADR-006 local).
        self._align = {}
        self._align_lock = threading.Lock()
        # S109: the DAEMON OWNS launched-app lifecycles. Each `lcars launch` setsids
        # its app into its OWN process group (PGID == app pid) and RETURNS — so the
        # app is NOT a child of anything the daemon waited on; to kill it we must
        # target that process GROUP. Track mid → pgid here so daemon shutdown can
        # group-kill everything it launched (nothing orphaned). Guarded by a lock
        # (the shutdown handler may run on a signal thread).
        self._launches = {}
        self._launches_lock = threading.Lock()
        # S110: in-flight launch guard. `_launches` tracks RUNNING pgids; this is a
        # SEPARATE set of missions whose `lcars launch` dispatch is still spinning
        # up (between the POST arriving and launch.json landing). A second POST that
        # arrives in that window — e.g. the captain reopens a card before SSE has
        # propagated status:"launching" and clicks RUN again — must be an idempotent
        # no-op, NOT a second concurrent `lcars launch` of the same mission (which
        # would spawn a duplicate app). Guarded by `_launches_lock`.
        self._launching = set()
        # Kill every launched app on interpreter exit AND on SIGTERM (the daemon's
        # normal stop signal). atexit won't fire on a bare SIGTERM, so install a
        # handler that reaps launches then chains any prior handler. Best-effort:
        # a restricted environment (no signal on this thread) must not break init.
        atexit.register(self.shutdown_launches)
        try:
            prev = signal.getsignal(signal.SIGTERM)

            def _on_sigterm(signum, frame, _prev=prev):
                try:
                    self.shutdown_launches()
                finally:
                    if callable(_prev) and _prev not in (
                            signal.SIG_DFL, signal.SIG_IGN):
                        _prev(signum, frame)
            signal.signal(signal.SIGTERM, _on_sigterm)
        except (ValueError, OSError, RuntimeError):
            # e.g. not on the main thread — the atexit hook still covers a clean
            # interpreter exit; skip the signal handler in that case.
            pass

    # -- public action surface (one per endpoint) -------------------------------
    def file_mission(self, idea, engine=None, mission_type="feature",
                     images=None):
        """POST /api/mission — file a new mission from a free-form idea.

        engine selects the worker CLI ($LCARS_WORKER_BIN) for this mission.
        `images` (S92) are pasted screenshots: each is staged under repo_root and
        threaded to file.sh as a repeated `--attach <path>` so file.sh persists it
        as a DURABLE mission attachment (attachments/ + prd.md ref + state.json).
        The staged temp copies are reaped here once file.sh has copied them in.
        Returns the freshly-assembled board state.
        """
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        mtype = "bug" if str(mission_type).strip().lower() == "bug" else "feature"
        title = self._title_from_idea(idea)
        prd = _PRD_TEMPLATE.format(title=title, type=mtype, idea=idea)
        prd_path = self._tmp_prd(prd)
        staged = self._stage_images(images)
        env_extra = {}
        if engine:
            env_extra["LCARS_WORKER_BIN"] = engine
        args = ["--prd", prd_path]
        for p in staged:
            args += ["--attach", p]
        try:
            self._run("file", args, env_extra=env_extra)
        finally:
            for p in [prd_path] + staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        return {"board": self._reader.board()}

    # -- Park & Align (S137): file a PARKED mission (pre-PRD standby) ------------
    def park_mission(self, idea, engine=None, images=None):
        """POST /api/park — file a PARKED mission from a free-form idea.

        The backlog-fast lane (S136): dispatch `file.sh --park` to mint a mission
        instantly with just the idea — NO grill, NO PRD, NO estimate — parked at
        align with state.json.prdPending:true. The captain aligns it later (the
        card's START ALIGNMENT → the warm grill → `file.sh --complete <id>`), or
        via `lcars file <id>` on the CLI (identical path, S136).

        Unlike file_mission (which threads the engine via $LCARS_WORKER_BIN),
        `file.sh --park` takes the engine as the `--engine <claude|copilot>` flag
        (matching do_park's contract). `images` (S92) are staged under repo_root
        and threaded as repeated `--attach <path>` exactly like file_mission, then
        the temp copies are reaped once file.sh has copied them into the mission's
        attachments/ dir. Returns the freshly-assembled board state so the parked
        card lands on the board (SSE also nudges it).
        """
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        eng = (engine or "").strip()
        # write the idea to a tmp file so multi-line ideas survive intact
        # (file.sh --idea <file> reads the verbatim capture; a positional would
        # word-split on whitespace).
        idea_path = self._tmp_prd(idea + "\n")
        staged = self._stage_images(images)
        args = ["--park", "--idea", idea_path]
        if eng:
            args += ["--engine", eng]
        for p in staged:
            args += ["--attach", p]
        try:
            self._run("file", args)
        finally:
            for p in [idea_path] + staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        return {"board": self._reader.board()}

    # -- the interactive Align grilling console (S70-B) --------------------------
    def align_start(self, idea, engine=None, images=None, mission_id=None):
        """POST /api/align/start — open a multi-turn Align session.

        OPENS ONE warm, resumable worker session (BUG-B) driving the existing
        lcars-file Align grilling (envelope + SKILL.md prose) over the captain's
        idea, and returns the first question (or, for a trivial mission the worker
        resolves in one shot, status:"done" with the assembled PRD already filed).
        The session's worker UUID is minted on the _AlignSession and reused on
        every /answer (no per-question cold respawn, no transcript re-feed) so the
        UI Align is the SAME warm interview the CLI runs.

        Park & Align (S137): with `mission_id` set, this is the grill-completion
        of an ALREADY-PARKED mission (`lcars file --park`). The session is SEEDED
        from that mission's idea.md text + engine (state.json.workerBin, unless
        overridden) + parked attachments, `mission_id` is carried on the session,
        and the done branch dispatches `file.sh --complete <id>` IN PLACE (not a
        fresh filing). A normal (no mission_id) call is BYTE-IDENTICAL to today.
        """
        mid = (mission_id or "").strip() or None
        seed_paths = []
        if mid:
            # the parked mission must exist (404 otherwise) and still be parked.
            self._require_mission(mid)
            idea = self._parked_idea(mid) or (idea or "")
            # engine: an explicit picker wins, else the parked mission's persisted
            # engine (workerBin), so the grill runs on the CLI the captain chose
            # at park time.
            engine = (engine or "").strip() or self._persisted_worker_bin(mid)
            # the parked mission's DURABLE attachments seed the OPENING turn so the
            # grill can see the screenshots the captain parked. They are NOT added
            # to sess.image_paths (which is reaped on done) — they are permanent
            # mission files, and file.sh --complete re-lists them from disk.
            seed_paths = self._parked_attachment_paths(mid)
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        sid = uuid.uuid4().hex[:12]
        sess = _AlignSession(idea=idea, engine=(engine or "").strip() or None,
                             mission_id=mid)
        with self._align_lock:
            self._align[sid] = sess
        # the captain may paste an image on the File idea box (this first turn);
        # these ride sess.image_paths (reaped on done). Parked seed attachments are
        # passed to THIS turn's worker call too, but not accumulated for reaping.
        turn_paths = self._stage_session_images(sess, images)
        return self._align_turn(sid, sess, image_paths=seed_paths + turn_paths)

    def align_answer(self, sid, answer, images=None):
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
        # BUG-073: an EMPTY answer is NOT an error — it means "nothing to add /
        # accept the recommendation / proceed". Submit must work with a blank box
        # so the captain never has to type filler to advance. Feed the warm grill
        # a clear proceed/accept signal (the grill already handles "proceed"); the
        # recommendation it surfaced this turn stands as the captain's pick.
        if not answer:
            answer = _PROCEED_ANSWER
        if sess.done:
            raise ActionError(409, "align session already completed")
        # attach the answer to the last asked question.
        if sess.transcript and sess.transcript[-1].get("answer") is None:
            sess.transcript[-1]["answer"] = answer
        else:
            sess.transcript.append({"question": "(implicit)", "answer": answer})
        # an image pasted into THIS reply is attached to THIS turn's worker call.
        turn_paths = self._stage_session_images(sess, images)
        return self._align_turn(sid, sess, image_paths=turn_paths)

    def _align_turn(self, sid, sess, image_paths=None):
        """Run one worker turn for `sess` and shape the HTTP response.

        Returns {sessionId, status:"question", question, prd} or, on done,
        files the mission and returns {sessionId, status:"done", prd, adr?, board}.
        """
        opening = not sess.started
        prompt = self._build_align_prompt(sess, opening=opening)
        out = self._worker_turn(prompt, engine=sess.engine,
                                session_id=sess.worker_sid, opening=opening,
                                image_paths=image_paths)
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
            # S92 — the grill's accumulated staged images (sess.image_paths) become
            # DURABLE mission attachments: thread them to file.sh BEFORE they are
            # reaped just below (the reap removes the temp staged copies once
            # file.sh has copied them into the mission's attachments/ dir).
            #
            # Park & Align (S137): a parked mission (sess.mission_id set) completes
            # its alignment IN PLACE via `file.sh --complete <id>`; a fresh grill
            # files a brand-new mission via `file.sh --prd` (unchanged).
            if sess.mission_id:
                board = self._complete_from_align(
                    sess.mission_id, turn, engine=sess.engine,
                    image_paths=sess.image_paths)
            else:
                board = self._file_from_align(turn, engine=sess.engine,
                                              image_paths=sess.image_paths)
            self._reap_session_images(sess)
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
        # BUG-072: the closing/confirm question must be a CONCISE lead-in — never
        # the whole PRD inlined. The PRD already flows to the `prd` field (the
        # live "PRD · BUILDING LIVE" right panel), so a worker that restates it in
        # the question body just duplicates it. Strip any inlined PRD out of the
        # question text, keeping only the lead-in (the PRD stays in sess.prd).
        if q.get("text"):
            q["text"] = _strip_inlined_prd(q["text"], sess.prd)
        sess.transcript.append({"question": q.get("text", ""), "answer": None})
        return {"sessionId": sid, "status": "question",
                "question": q, "prd": sess.prd}

    def _file_from_align(self, turn, engine=None, image_paths=None):
        """Persist a finished Align turn via file.sh (ADR-002 dispatch).

        `engine` is the per-session chosen engine: it is threaded to file.sh as
        $LCARS_WORKER_BIN so file.sh persists it as state.json.workerBin (S67),
        making the engine survive the real browser Align console flow — not just
        the direct /api/mission endpoint. Empty/None leaves the daemon default
        (self.worker_bin, injected by _run) in charge.

        `image_paths` (S92) are the grill session's accumulated staged images;
        each is threaded to file.sh as a repeated `--attach <path>` so an image
        pasted DURING the Align grill becomes a durable mission attachment, not
        just a one-turn worker input. The caller reaps the staged copies after
        this returns (file.sh has copied them into the mission dir by then)."""
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
        for p in (image_paths or []):
            if p:
                args += ["--attach", p]
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

    def _complete_from_align(self, mid, turn, engine=None, image_paths=None):
        """Park & Align (S137): COMPLETE a parked mission's alignment via
        `file.sh --complete <id> --prd <path>` (ADR-002 dispatch).

        Mirrors `_file_from_align` but grill-completes IN PLACE: the mission
        already exists (parked, prdPending:true), so file.sh --complete validates
        the PRD, writes prd.md, derives type/title, retitles + re-bodies the
        issue, runs the estimator, and clears prdPending — landing byte-equivalent
        to a grill-first filing. `engine`/`adr`/`modelOverride` thread exactly as
        the fresh-filing path. Parked attachments are re-listed by file.sh from
        the mission's attachments/ dir; `image_paths` here are any grill-turn
        images (harmless additive `--attach`), reaped by the caller."""
        prd = (turn.get("prd") or "").strip()
        if not prd:
            raise ActionError(502, "the Align worker returned done with no PRD")
        prd_path = self._tmp_prd(prd + "\n")
        adr_path = None
        adr = (turn.get("adr") or "").strip()
        if adr and adr.lower() != "null":
            adr_path = self._tmp_prd(adr + "\n")
        args = ["--complete", mid, "--prd", prd_path]
        if adr_path:
            args += ["--adr", adr_path]
        ov = (turn.get("modelOverride") or "").strip()
        if ov and ov.lower() != "null":
            args += ["--model-override", ov]
        for p in (image_paths or []):
            if p:
                args += ["--attach", p]
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

    def _parked_idea(self, mid):
        """Park & Align (S137): the verbatim idea captured at park time (idea.md).

        Returns the file's text (stripped), or "" when absent — the caller falls
        back to any idea passed in the request body so a seed failure degrades to
        the old behaviour rather than crashing."""
        p = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                         "idea.md")
        try:
            with open(p, encoding="utf-8") as fh:
                return fh.read().strip()
        except OSError:
            return ""

    def _parked_attachment_paths(self, mid):
        """Park & Align (S137): the ABS paths of a parked mission's DURABLE
        attachments (state.json.attachments, relative to the mission dir).

        Used to SEED the opening grill turn so the worker sees the parked
        screenshots. These are permanent mission files — the caller must NOT add
        them to a grill session's reap list. Missing entries are skipped."""
        mdir = os.path.join(self.repo_root, ".git", "lcars", "missions", mid)
        sp = os.path.join(mdir, "state.json")
        rels = _read_json_key(sp, "attachments")
        out = []
        if isinstance(rels, list):
            for rel in rels:
                if not isinstance(rel, str) or not rel.strip():
                    continue
                ap = os.path.join(mdir, rel)
                if os.path.isfile(ap):
                    out.append(ap)
        return out

    def align_cancel(self, sid):
        """POST /api/align/<sid>/cancel — reap a live Align console.

        With resume-by-id there is NO subprocess to kill — reaping is dropping
        the sid→session mapping so the warm worker UUID is never resumed again
        (the CLI's stored session ages out on its own). Caps one live session per
        console; a subsequent answer to the reaped sid 404s. Idempotent.
        """
        with self._align_lock:
            sess = self._align.pop(sid, None)
        # S91 — reap any staged images for this grill so a cancelled console
        # leaks no files into the repo working tree.
        if sess is not None:
            self._reap_session_images(sess)
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
                     session_id=None, opening=True, image_paths=None):
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
        # S91 — pasted-image hand-off (the ONE shared seam carries images to the
        # conversational worker; the Align grill AND the Mission-Log split both
        # run through here). Per-engine mechanism, PROVEN by the S91 spike:
        #   • copilot: native `--attachment <path>` (repeatable, non-interactive
        #     only). The image rides into the prompt NATIVELY — NO tool needed —
        #     so the S72 tools-denied posture (`--available-tools=`) stays intact.
        #   • claude (and the default): the grill is NOT tools-denied
        #     (`_session_args` denies tools only for copilot), so REFERENCE the
        #     staged ABS PATH in the prompt text and claude views it with its Read
        #     tool. No stdin/output-format change, no scoped tools exception.
        # Selection is by basename (same idiom as `_session_args`). When
        # `image_paths` is empty the turn is BYTE-IDENTICAL to today — no argv flag
        # is appended and the prompt text is untouched (regression-tested).
        image_paths = [p for p in (image_paths or []) if p]
        attach_args = []
        if image_paths:
            base = os.path.basename(bin_ or "").lower()
            if "copilot" in base:
                for p in image_paths:
                    attach_args += ["--attachment", p]
            else:
                prompt = prompt + (
                    "\n\n=== attached images (the captain pasted these; view "
                    "them with your Read tool as relevant) ===\n"
                    + "\n".join(image_paths))
        own_outdir = outdir is None
        if own_outdir:
            outdir = tempfile.mkdtemp(prefix="lcars-worker-", dir=self.repo_root)
        env = dict(os.environ)
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        env["LCARS_WORK_OUT"] = outdir
        # S78 CHANGE 3 — Align-grill model parity. The grill used to run each
        # CLI's BARE default (no --model), so it was not at CLI parity with the
        # pipeline. Resolve the model from the mission ENGINE and pass it
        # space-form (BOTH engines use `--model <m>`, mirroring worker-adapter.sh).
        # The flag is ADDITIVE — the S72 tools-denied / session flags are untouched.
        cmd = ([bin_, "-p", prompt]
               + self._session_args(bin_, session_id, opening)
               + ["--model", _grill_model(bin_)]
               + attach_args)
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
        # S78 — NO daemon-wide model pin. The daemon must NOT depend on a
        # process-wide $LCARS_WORKER_MODEL: if it was launched with one set, it
        # would leak into EVERY mission's run (resolve_stage_model precedence (a)
        # clobbers ALL stages of ALL missions). Each run must self-resolve its OWN
        # model (engine + estimate.json + overrides), so N missions run
        # concurrently — each independently Copilot or Claude — with no shared pin.
        #   * If the mission has a persisted FROZEN model (state.json.workerModel),
        #     feed it as a PER-RUN LCARS_WORKER_MODEL (this run only).
        #   * Otherwise set it to None so _resolve_run STRIPS any inherited
        #     daemon-wide pin for this run and the mission self-resolves.
        worker_model = self._persisted_worker_model(mid)
        if worker_model:
            env_extra["LCARS_WORKER_MODEL"] = worker_model
        else:
            env_extra["LCARS_WORKER_MODEL"] = None
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

    def _persisted_worker_model(self, mid):
        """S78: the OPTIONAL per-mission frozen model (state.json.workerModel).

        When present, Start feeds it as a PER-RUN $LCARS_WORKER_MODEL so the
        mission runs that exact model regardless of the daemon's launch env.
        Absent ⇒ None (the mission self-resolves from engine + estimate.json +
        overrides, and Start strips any inherited daemon-wide pin)."""
        sp = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                          "state.json")
        wm = _read_json_key(sp, "workerModel")
        if isinstance(wm, str) and wm.strip():
            return wm.strip()
        return None

    # -- S109: launch a mission's app locally (daemon-owned lifecycle) -----------
    def launch(self, mid, hint=None):
        """POST /api/mission/<id>/launch — run the mission's app for Verify.

        Dispatches `lcars launch <mission> [hint]` BLOCKING: launch.sh discovers
        how to start the app, launches it DETACHED into its own process group, and
        writes launch.json (status running|failed) BEFORE returning — so on return
        the terminal state is already on disk (the FE's "launching" state is just
        the in-flight request spinner). A running record carries a numeric `pgid`
        (== the app pid, setsid'd into its own session); we record mid → pgid so
        the daemon can group-kill it on Stop / shutdown (the app is NOT our child).

        A FAILED launch leaves a readable status=failed launch.json (plain-English
        `message`); we surface that via the board's additive `launch` field rather
        than leaking the skill's non-zero exit as a 502 + stack (UX-33).
        """
        self._require_mission(mid)
        # In-flight guard (S110): if a launch for this mission is already spinning
        # up, a second POST is an idempotent no-op — return the (now "launching")
        # board WITHOUT dispatching a duplicate `lcars launch`. The check-and-add is
        # a SINGLE locked critical section so two threads can't both pass the check.
        with self._launches_lock:
            if mid in self._launching:
                return {"board": self._reader.board()}
            self._launching.add(mid)
        try:
            args = [mid]
            h = (hint or "").strip()
            if h:
                args += h.split()
            env_extra = {}
            engine = self._persisted_worker_bin(mid)
            if engine:
                env_extra["LCARS_WORKER_BIN"] = engine
            try:
                self._run("launch", args, env_extra=env_extra)
            except ActionError:
                # A discovery/liveness failure exits non-zero AND writes a failed
                # launch.json. If that readable record is present, swallow the exit
                # and surface the message via the board; otherwise re-raise (a
                # genuine dispatch error with no record for the FE to show).
                if not isinstance(self._read_launch_json(mid), dict):
                    raise
            rec = self._read_launch_json(mid)
            if isinstance(rec, dict) and rec.get("status") == "running":
                pgid = rec.get("pgid")
                if isinstance(pgid, int) and pgid > 0:
                    with self._launches_lock:
                        self._launches[mid] = pgid
            return {"board": self._reader.board()}
        finally:
            with self._launches_lock:
                self._launching.discard(mid)

    def launch_stop(self, mid):
        """POST /api/mission/<id>/launch/stop — stop the mission's launched app.

        Dispatches `lcars launch <mission> --stop`, which kills the app's process
        group and prunes the worktree, then drops the mission from the tracking
        table. Idempotent: a double-stop is a clean no-op (the skill's --stop is
        itself idempotent, and popping an absent key is harmless)."""
        self._require_mission(mid)
        env_extra = {}
        engine = self._persisted_worker_bin(mid)
        if engine:
            env_extra["LCARS_WORKER_BIN"] = engine
        try:
            self._run("launch", [mid, "--stop"], env_extra=env_extra)
        finally:
            with self._launches_lock:
                self._launches.pop(mid, None)
        return {"board": self._reader.board()}

    def shutdown_launches(self):
        """Kill every app this daemon launched — the daemon owns their lifecycles,
        so a shutdown must not orphan any. Each was setsid'd into its own process
        group (PGID == the recorded pgid), so we group-kill the pgid (a plain
        kill of the launch subprocess would leave the app running). Best-effort
        and safe to call more than once (atexit + SIGTERM + explicit both land
        here): the table is drained under the lock first, so a second call is a
        no-op even if a signal races the exit hook."""
        with self._launches_lock:
            items = list(self._launches.items())
            self._launches.clear()
        for _mid, pgid in items:
            if not (isinstance(pgid, int) and pgid > 0):
                continue
            try:
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, OSError):
                pass

    # `close` is an alias so a daemon can call whichever reads clearer at its
    # shutdown site; both drain the launch table.
    close = shutdown_launches

    def _read_launch_json(self, mid):
        """The mission's launch.json as a dict, or None (absent/unreadable)."""
        p = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                         "launch.json")
        try:
            with open(p) as fh:
                return json.load(fh)
        except (OSError, ValueError):
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
        """POST /api/mission/<id>/respond — answer a gate AND resume the run.

        BUG-028: the "SUBMIT & RESUME" button (gate copy: "the mission resumes
        from where it stopped") used to only record the answer + clear the gate —
        the `lcars-respond` skill is designed to need a SEPARATE `lcars run <id>`
        to resume, which the daemon never issued, so the mission sat
        answered-but-idle. After the respond call succeeds we therefore
        RE-DISPATCH the driver fire-and-forget (mirror start()'s _spawn + the
        per-mission running-lock guard) so the escalated stage actually resumes
        and consumes the answer, and we clear the stale pending.json. Make
        "& Resume" real.

          • a `parentMission`-linked bug child → resume the resolve-logs batch on
            the PARENT (it folds onto the parent + drives to the consolidated
            re-verify gate), NOT a standalone `run drive` on the child.
          • a top-level mission → `run drive --mission <id>`.
        """
        self._require_mission(mid)
        answer = (answer or "").strip()
        if not answer:
            raise ActionError(400, "missing required field: answer")
        self._run("respond", ["answer", "--mission", mid, "--answer", answer])
        # the gate is now cleared on disk; drop the stale pending.json so the
        # board stops rendering the answered question.
        self._clear_pending(mid)
        # re-dispatch the run (fire-and-forget), routed by parentage.
        parent = self._persisted_parent_mission(mid)
        if parent:
            # a logged-bug child: resume the parent's resolve-logs batch (same
            # path log_run uses) so the answered bug + the remaining bugs continue
            # to the fold + the consolidated re-verify gate. Inherit the parent's
            # engine so the batch drives on the right CLI (mirrors log_run).
            engine = self._persisted_worker_bin(parent)
            env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
            if not self._is_running(parent):
                self._spawn("resolve", ["--parent", parent], env_extra=env_extra)
        else:
            # a top-level mission: resume its own driver. Defense-in-depth with
            # run.sh's per-mission lock — skip the spawn if one is already live.
            if not self._is_running(mid):
                engine = self._persisted_worker_bin(mid)
                env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
                self._spawn("run", ["drive", "--mission", mid],
                            env_extra=env_extra)
        return self._mission_state(mid)

    def _persisted_parent_mission(self, mid):
        """The parent id of a logged-bug child (state.json.parentMission), or None."""
        sp = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                          "state.json")
        pm = _read_json_key(sp, "parentMission")
        if isinstance(pm, str) and pm.strip():
            return pm.strip()
        return None

    def _clear_pending(self, mid):
        """Remove a mission's stale pending.json after its gate is answered."""
        pp = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                          "pending.json")
        try:
            os.unlink(pp)
        except OSError:
            pass

    def verify(self, mid, decision, feedback=None):
        """POST /api/mission/<id>/verify — approve vs send-back.

        decision == "approve"   → approve.sh (open PR, mark done)
        decision == "send-back" → feedback.sh (--feedback note → back to Align)
        These route to TWO DIFFERENT skills.
        """
        self._require_mission(mid)
        decision = (decision or "").strip().lower()
        if decision == "approve":
            # BUG-030: a Mission-Log bug child has NO PR of its own — its fix
            # rides the PARENT's PR. "Accept" must therefore FOLD it to Done via
            # resolve-logs `complete` (NOT merge a per-bug PR with approve.sh,
            # which would hit the BUG-026 spurious-PR path). A top-level mission
            # still approves normally (merge its open PR).
            #
            # BUG-032: the per-bug "Verify" on a SINGLE bug card must complete
            # ONLY this one bug (mid), NOT the whole batch. The bare
            # `complete --parent` is the CONSOLIDATED accept that folds EVERY
            # logged bug of the parent to Done — wiring it here marked sibling
            # bugs Done on a single-card click. Use the single-bug mode
            # (`complete --parent <p> --bug <mid>`): it folds just this bug and
            # leaves the parent's consolidated re-verify gate up while any
            # sibling is still pending. The all-remaining accept stays on the
            # parent-gate respond path (respond → resolve-logs).
            parent = self._persisted_parent_mission(mid)
            if parent:
                engine = self._persisted_worker_bin(parent)
                env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
                self._run("resolve",
                          ["complete", "--parent", parent, "--bug", mid],
                          env_extra=env_extra)
            else:
                # BUG-040: the Merge click must be NON-BLOCKING. approve.sh merges
                # the open PR and, when main has moved ahead, runs the reconcile /
                # self-heal — which can take minutes. Blocking on it (the old
                # _run) hung the HTTP request and spun the dialog. Dispatch it
                # FIRE-AND-FORGET (_spawn, the same detached Popen start()/log_run
                # use) and return the current state promptly; the board/SSE then
                # reflects the evolving state (reconciling → escalated → done).
                self._spawn("approve", ["--mission", mid])
        elif decision in ("send-back", "sendback", "send_back"):
            note = (feedback or "").strip()
            if not note:
                raise ActionError(400, "send-back requires a 'feedback' note")
            # BUG-031: "Send Back" reaches this ONE endpoint from TWO surfaces.
            # `lcars feedback` resets its target to align + clears the PR fields,
            # so blindly running it on `mid` is destructive when `mid` is a logged
            # bug's PARENT (it would nuke the parent's verified state + PR). Route
            # by parentage, mirroring the approve branch above. The fix-pattern in
            # every linked case is: feedback-the-BUG(s) (moves them OFF verify so
            # resolve-logs re-drives them) + spawn `resolve --parent <p>` (re-fix +
            # re-fold + re-raise ONE consolidated re-verify gate), parent untouched.
            parent = self._persisted_parent_mission(mid)
            if parent:
                # Case A — `mid` is a logged-bug CHILD: re-fix THIS bug only, then
                # re-drive the parent's batch fire-and-forget. Never feedback the
                # parent; never touch its stage/PR.
                self._run("feedback", ["--mission", mid, "--feedback", note])
                engine = self._persisted_worker_bin(parent)
                env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
                self._spawn("resolve", ["--parent", parent], env_extra=env_extra)
            else:
                children = self._linked_children(mid)
                pending = [c for c in children
                           if (c.get("stage") or "").lower() != "done"]
                if pending:
                    # Case B — `mid` is the PARENT consolidated re-verify gate:
                    # apply the feedback to EACH non-done linked bug child (NOT the
                    # parent), then re-drive the batch once. The parent's verified
                    # state / PR stays intact.
                    for child in pending:
                        self._run("feedback",
                                  ["--mission", child["id"], "--feedback", note])
                    engine = self._persisted_worker_bin(mid)
                    env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
                    self._spawn("resolve", ["--parent", mid],
                                env_extra=env_extra)
                else:
                    # Case C — plain top-level mission: unchanged.
                    self._run("feedback", ["--mission", mid, "--feedback", note])
        else:
            raise ActionError(
                400, "decision must be 'approve' or 'send-back' (got %r)"
                % decision)
        return self._mission_state(mid)

    def reapprove(self, mid):
        """POST /api/mission/<id>/reapprove — the BUG-067 reapprove gate.

        After a merge self-heal converges green the engine STOPS at an
        awaiting-reapprove gate (SHARED CONTRACT: reconcileStatus ==
        "awaiting-reapprove") instead of auto-merging — the human reviews the
        reconcileNote and clicks Reapprove, which dispatches the engine's
        MERGE-ONLY path. The engine exposes that as `approve.sh --reapprove`: it
        merges the already-reconciled tip WITHOUT re-running the reconcile/heal.

        Dispatched FIRE-AND-FORGET (the same _spawn the approve / Merge click
        uses, BUG-040) so the HTTP request returns promptly and its output is
        captured per BUG-051; the board/SSE then reflects done (or, if the merge
        itself fails, the merge-failed outcome — surfaced, not silent). The
        mission's persisted engine ($LCARS_WORKER_BIN) is threaded so the
        merge-only path runs on the right CLI (mirrors start()/the approve branch).
        """
        self._require_mission(mid)
        engine = self._persisted_worker_bin(mid)
        env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
        self._spawn("approve", ["--mission", mid, "--reapprove"],
                    env_extra=env_extra)
        return self._mission_state(mid)

    def update(self):
        """POST /api/update — run the version UPDATE action (S130 board button).

        Shells the shared helper `check.sh update` (the SAME update the ask-mode
        'y' path runs) NON-interactively: it fast-forwards the source main
        checkout when safe (on main + clean + ff-able), re-installs, and restamps
        this repo — or, for an unsafe source (dirty / branched / diverged), prints
        a one-line decline reason and exits 0. Either way we return that output as
        the response line so the banner surfaces success or the decline reason;
        SSE refreshes the board (and the banner clears) after the restamp.

        LOCAL-BRIDGE only (ADR-006): the server's read-only 403 guard already
        blocks this on the github / view-only build (actions is None there).
        """
        script = self.check_script
        if not script:
            raise ActionError(500, "no version check wired ($LCARS_VERSION_CHECK_BIN)")
        env = dict(os.environ)
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        # anchor the repo-restamp on THIS board's working tree.
        env["LCARS_VERSION_CWD"] = self.repo_root
        try:
            proc = subprocess.run(
                ["bash", script, "update"], cwd=self.repo_root, env=env,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT)
        except OSError as exc:
            raise ActionError(502, "version update failed to start: %s" % exc)
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        return {"update": out, "board": self._reader.board()}

    def log_preview(self, mid, text=None, images=None):
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
        return self._log_author(mid, text, images=images)

    def _log_author(self, parent, text, images=None):
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
        # S91 — an image pasted into the Mission-Log box rides into the SAME cold
        # (session_id=None) worker turn that splits the report, so the log-split
        # worker sees it. Stage under repo_root, attach, then clean up after the
        # turn (this is a one-shot cold turn — no session to read it across).
        staged = self._stage_images(images)
        try:
            out = self._worker_turn(prompt, engine=engine, image_paths=staged)
        finally:
            for p in staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        turn = _extract_json(out)
        bugs = (turn or {}).get("bugs") if isinstance(turn, dict) else None
        if not isinstance(bugs, list) or not bugs:
            raise ActionError(
                502, "the Mission-Log worker returned no bug PRDs from the report")
        # Parse BOTH schemas: a plain string bug (legacy → no image refs) or the
        # per-bug object {"prd":..., "imageRefs":[...]} (new). Collect each bug's
        # PRD + its EXPLICIT image refs, then route the pasted images through the
        # one deterministic union formula so each child carries its FINAL image set.
        prds = []
        raw_refs = []
        for bug in bugs:
            if isinstance(bug, str):
                prd, refs = bug, []
            elif isinstance(bug, dict):
                prd = bug.get("prd")
                refs = bug.get("imageRefs")
                if not isinstance(refs, list):
                    refs = []
            else:
                continue
            if not isinstance(prd, str) or not prd.strip():
                continue
            prds.append(prd)
            raw_refs.append([k for k in refs if isinstance(k, int)])
        n = len(staged)
        _orphaned, explicit, union = _route_images(raw_refs, n)
        children = []
        for i, prd in enumerate(prds):
            children.append({"title": _prd_title(prd) or "Untitled bug",
                             "type": "bug", "prd": prd,
                             # the FINAL image set (explicit ∪ orphaned) — the FE
                             # renders a pill from this; empty when no images.
                             "images": union[i],
                             # the EXPLICIT refs — round-tripped to /log/file so
                             # _file_children recomputes the SAME union at filing.
                             "imageRefs": explicit[i]})
        return {"children": children, "count": len(children),
                "parent": parent, "authored": True}

    def _file_children(self, mid, prds, overrides, env_extra, images=None,
                       image_refs=None):
        """Persist one linked bug Mission per PRD via log.sh (blocking).

        Each PRD is paired POSITIONALLY with its captain override (S74). The
        free-form steer is NORMALIZED to `<scope>:<tier>` FIRST (S74 follow-up —
        log.sh `die`s on a bad value, so plain language must be resolved before it
        rides the flag), then threaded to log.sh through the SAME lever `lcars
        file` uses: --model-override "<scope>:<tier>" right after the --prd it
        applies to. log.sh persists it as state.json.modelOverride and runs the
        estimator on each child — so the children EXIST (with estimates) when this
        returns. A blank steer threads no flag; an UNPARSEABLE steer threads no
        flag and is reported with an error (never silent-drop). No-op for no prds.

        Returns a per-PRD override report [{index, raw, resolved, label, error}].
        """
        prds = list(prds or [])
        overrides = list(overrides or [])
        report = []
        if not prds:
            return report
        # S92 + per-bug routing — the captain's pasted screenshots are staged once
        # under repo_root and threaded to log.sh's POSITIONAL `--attach`. Each bug's
        # EXPLICIT refs (from the split-worker, round-tripped by the FE) route via
        # the SAME deterministic union: ORPHANED images (referenced by no bug) go
        # BEFORE the first --prd as GLOBAL attaches (log.sh gives globals to every
        # bug); each bug's EXPLICIT images go right AFTER its own --prd. log.sh's
        # global∪positional union then equals explicit∪orphaned. With no refs every
        # image is orphaned → all threaded as globals → byte-identical to before.
        # The staged temp copies are reaped in the finally below.
        staged = self._stage_images(images)
        n = len(staged)
        refs = [(image_refs[i] if (image_refs and i < len(image_refs)) else None)
                for i in range(len(prds))]
        orphaned, explicit, _union = _route_images(refs, n)
        tmp = []
        args = ["--parent", mid]
        for k in orphaned:                      # globals: k is 1-based
            args += ["--attach", staged[k - 1]]
        try:
            for i, prd in enumerate(prds):
                p = self._tmp_prd(prd.rstrip() + "\n")
                tmp.append(p)
                args += ["--prd", p]
                for k in explicit[i]:           # per-bug positional attaches
                    args += ["--attach", staged[k - 1]]
                ov = overrides[i] if i < len(overrides) else None
                if not (isinstance(ov, str) and ov.strip()):
                    continue
                resolved = self._normalize_override(ov, mid)
                if resolved is None:
                    report.append({"index": i, "raw": ov.strip(),
                                   "resolved": None, "label": None,
                                   "error": _override_error(ov)})
                    continue
                args += ["--model-override",
                         "%s:%s" % (resolved["scope"], resolved["tier"])]
                report.append({"index": i, "raw": ov.strip(),
                               "resolved": resolved,
                               "label": _override_label(resolved),
                               "error": None})
            self._run("log", args, env_extra=env_extra)
        finally:
            for p in tmp + staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        return report

    def log_file(self, mid, prds=None, overrides=None, images=None,
                 image_refs=None):
        """POST /api/mission/<id>/log/file — file authored bugs, return enriched.

        The file-then-review-then-run flow (S74): the captain's confirm step FILES
        the authored bugs (log.sh runs the estimator + persists each child's
        estimate.json + override), and this returns the freshly-filed children with
        their cost/difficulty pills + suggested model mix so the review panel can
        show each bug's estimate and the captain can re-steer before Run Fixes. It
        does NOT dispatch resolve-logs — "Run Fixes" (log_run) does that.
        """
        self._require_mission(mid)
        engine = self._persisted_worker_bin(mid)
        env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
        prds = [p for p in (prds or []) if isinstance(p, str) and p.strip()]
        report = self._file_children(mid, prds, overrides, env_extra,
                                     images=images, image_refs=image_refs)
        children = self._linked_children(mid)
        # map the per-PRD override report onto the freshly-filed child ids (same
        # positional order) so the review panel can echo each resolved steer /
        # surface a normalization error (S74 follow-up; never silent-drop).
        resolved = []
        for r in report:
            idx = r.get("index")
            cid = children[idx]["id"] if (idx is not None
                                          and idx < len(children)) else None
            resolved.append({"id": cid, "raw": r.get("raw"),
                             "resolved": r.get("resolved"),
                             "label": r.get("label"), "error": r.get("error")})
        return {"children": children, "count": len(children),
                "parent": mid, "filed": True, "overrides": resolved}

    def log_run(self, mid, prds=None, overrides=None, confirm=False,
                images=None, image_refs=None):
        """POST /api/mission/<id>/log/run — file authored bugs, then resolve.

        BUG-059 — the human cost-review GATE. Filing a logged bug computes its cost
        estimate (log.sh runs the estimator + persists estimate.json) but it MUST
        NOT auto-proceed into running the fix: the captain has to review the
        estimate, optionally re-steer the model, and click an explicit "Go" first.

        So the dispatch of resolve-logs is GATED behind `confirm`:
          • `prds` supplied AND NOT `confirm` ⇒ this is the FILE step. File the
            children (so the estimator runs + each estimate.json exists), return the
            estimate-enriched review, and STOP — do NOT dispatch resolve. Walking
            away here leaves the bugs parked, filed-but-idle. (Identical to the
            dedicated `log_file` step; this keeps the single-endpoint flow gated
            too, so a UI that posts prds to /log/run never auto-runs.)
          • no prds ⇒ the bugs are ALREADY filed (the captain reviewed the estimate
            in the breakdown). This IS the explicit Go: apply any edited overrides
            and dispatch resolve-logs.
          • `prds` supplied AND `confirm` ⇒ the explicit one-shot "file & go" power
            path: file the children then dispatch in one call.

        The captain overrides (S74) pair positionally with the prds and are
        persisted by log.sh.
        """
        self._require_mission(mid)
        # BUG-C: the child bug missions inherit the PARENT's persisted engine.
        # Setting LCARS_WORKER_BIN on the log.sh dispatch makes file/log.sh persist
        # workerBin=<parent engine> on each child; setting it on resolve-logs drives
        # those children on the parent's engine. Absent ⇒ leave unset (no force).
        engine = self._persisted_worker_bin(mid)
        env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
        prds = [p for p in (prds or []) if isinstance(p, str) and p.strip()]
        # BUG-059 GATE: filing must HOLD for the human. When prds are supplied
        # without an explicit confirm, this is the File step — file + return the
        # estimate review and STOP (the dispatch waits for the explicit Go, which
        # re-posts with no prds once the bugs are filed). Delegate to log_file so
        # the file-then-review contract is shared and never drifts.
        if prds and not confirm:
            return self.log_file(mid, prds=prds, overrides=overrides,
                                 images=images, image_refs=image_refs)
        file_report = self._file_children(mid, prds, overrides, env_extra,
                                          images=images, image_refs=image_refs)
        # S74 follow-up CHANGE 4: when there are NO prds the bugs are ALREADY
        # filed (the captain edited the steers in the post-File breakdown, then
        # clicked Run Fixes). _file_children no-ops on no prds, so apply the
        # post-File overrides directly to the existing linked children here —
        # persisting state.json.modelOverride, the same lever resolve-logs/run.sh
        # (active_model_override) reads. With prds present the steers already rode
        # log.sh, so this is skipped to avoid double-applying.
        if not prds:
            apply_report = self._apply_child_overrides(mid, overrides)
        else:
            # map the per-PRD file-time report onto the now-filed child ids so the
            # response shape matches the no-prds (apply) path.
            children = self._linked_children(mid)
            apply_report = []
            for r in file_report:
                idx = r.get("index")
                cid = children[idx]["id"] if (idx is not None
                                              and idx < len(children)) else None
                apply_report.append(
                    {"id": cid, "raw": r.get("raw"),
                     "resolved": r.get("resolved"),
                     "label": r.get("label"), "error": r.get("error")})
        # BUG-G: resolve-logs drives the ENTIRE batch (every logged bug → Verify +
        # the consolidated re-verify gate) — minutes. Blocking on it (the old _run)
        # hung the POST until the whole batch finished, so the dialog spun and the
        # browser reset the connection. Fire-and-forget it like start()'s `run drive`
        # (_spawn = detached Popen) so the POST returns PROMPTLY after the children
        # are filed; the board/SSE then carries the wave progress. The engine env
        # (BUG-D) is preserved — _spawn carries env_extra exactly as _run did.
        self._spawn("resolve", ["--parent", mid], env_extra=env_extra)
        state = self._mission_state(mid)
        # carry the resolved/erroring per-bug steers so the UI can echo them
        # (S74 follow-up: a steer that couldn't be normalized rides as an error
        # rather than being silently dropped onto the default model).
        state["overrides"] = apply_report
        return state

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
            # S78: an env_extra value of None means "STRIP this key from the child
            # env" — so a caller can explicitly remove an inherited daemon-wide
            # var (e.g. a leaked LCARS_WORKER_MODEL pin) for THIS run. Non-None
            # values set/override as before.
            for k, v in env_extra.items():
                if v is None:
                    env.pop(k, None)
                else:
                    env[k] = v
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

    def _spawn_log_path(self, key, args):
        """Per-run capture-log path under .git/lcars/logs/ for a fire-and-forget
        spawn. The detached approve/reconcile/driver output (BUG-051: incl. the
        die reason) lands here so it SURVIVES instead of going to /dev/null. Keyed
        by the command + its mission/parent so concurrent spawns don't clobber."""
        mid = ""
        for flag in ("--mission", "--parent"):
            if flag in args:
                try:
                    mid = args[args.index(flag) + 1]
                except IndexError:
                    mid = ""
                break
        logs_dir = os.path.join(self.repo_root, ".git", "lcars", "logs")
        os.makedirs(logs_dir, exist_ok=True)
        name = "spawn-%s%s.log" % (key, ("-" + mid) if mid else "")
        return os.path.join(logs_dir, name)

    def _spawn(self, key, args, env_extra=None):
        """Fire-and-forget dispatch — for the LONG `run drive` driver. Launches
        the skill DETACHED (Popen, never waited on) so the HTTP request returns
        promptly; the board/SSE then reflects progress and the `running` flag.

        Output is CAPTURED to a per-run log under .git/lcars/logs/ (BUG-051) — not
        discarded — so the detached approve/reconcile/driver output, including any
        hard-fail die reason, survives the fire-and-forget. We still NEVER wait on
        the child (a real file handle, not a pipe, so it can never wedge the
        daemon). start_new_session detaches the child from the daemon's process
        group, so a daemon restart / Ctrl-C doesn't take a running mission down
        with it. Returns the Popen handle (the caller does NOT wait)."""
        cmd, env = self._resolve_run(key, args, env_extra)
        try:
            log_path = self._spawn_log_path(key, args)
            logf = open(log_path, "ab", buffering=0)
        except OSError:
            # Never let a logging-path failure break the dispatch — fall back to
            # the old discard behaviour (semantics unchanged).
            logf = subprocess.DEVNULL
        try:
            return subprocess.Popen(
                cmd, cwd=self.repo_root, env=env,
                stdin=subprocess.DEVNULL,
                stdout=logf, stderr=subprocess.STDOUT,
                start_new_session=True)
        except OSError as exc:
            raise ActionError(502, "failed to launch skill '%s': %s" % (key, exc))
        finally:
            # The child inherited the fd; close our copy so the daemon holds no
            # extra handle. DEVNULL is an int sentinel — nothing to close.
            if logf is not subprocess.DEVNULL:
                try:
                    logf.close()
                except OSError:
                    pass

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
                # S74: a logged bug is a Mission whose estimate is computed from
                # its bug PRD — surface the SAME estimator readout the board card
                # and Launch panel show (ONE cost pill, TWO difficulty pills, the
                # per-stage model mix) so the Mission-Log review panel can render
                # each bug with its suggested model + cost/difficulty, REUSING the
                # card shape (card already carries `pills`/`modelMix` off the
                # child's estimate.json via the LocalAdapter). Plus the persisted
                # captain override so the panel can pre-fill its steer field.
                child = {"id": card["id"], "issue": card.get("issue"),
                         "title": card.get("title"), "stage": card.get("stage"),
                         "type": card.get("type"),
                         "pills": card.get("pills"),
                         "modelMix": card.get("modelMix")}
                ov = _read_json_key(sp, "modelOverride")
                if isinstance(ov, dict) and ov.get("scope") and ov.get("tier"):
                    child["override"] = "%s:%s" % (ov["scope"], ov["tier"])
                out.append(child)
        return out

    def _normalize_override(self, raw, parent):
        """Normalize one free-form per-bug steer, reusing the daemon worker seam.

        Deterministic-first; for the inconclusive long tail it falls back to ONE
        bounded `_worker_turn` (the SAME cold-worker seam tests stub) on the
        PARENT mission's persisted engine (BUG-C inheritance), applying the Align
        normalization instruction. Returns {scope,tier} or None.
        """
        engine = self._persisted_worker_bin(parent)

        def _worker(text):
            prompt = _OVERRIDE_FALLBACK_PROMPT + text + "\n"
            return self._worker_turn(prompt, engine=engine)

        return normalize_override(raw, worker=_worker)

    def _apply_child_overrides(self, parent, overrides):
        """Persist the post-File per-bug overrides onto ALREADY-FILED children.

        Pairs each override POSITIONALLY with the linked children in the SAME
        order the review panel renders them (_linked_children → sorted by mission
        dir name). Each non-blank steer is NORMALIZED to {scope,tier} (passthrough
        structured → deterministic parse → bounded worker fallback; S74 follow-up)
        and written to the child's state.json.modelOverride — the lever run.sh's
        active_model_override reads, so resolve-logs drives that child on the
        chosen model with zero skill changes.

        Returns a per-child report [{id, raw, resolved, label, error}] so the
        caller can echo the resolved steer / surface a normalization error.
        Blank entries are SKIPPED (no clobber of an earlier File-time steer);
        an UNPARSEABLE entry is reported with an `error` and NOT persisted — never
        a silent drop onto the default model.
        """
        overrides = list(overrides or [])
        report = []
        if not overrides:
            return report
        children = self._linked_children(parent)
        for i, child in enumerate(children):
            if i >= len(overrides):
                break
            ov = overrides[i]
            if not (isinstance(ov, str) and ov.strip()):
                continue
            resolved = self._normalize_override(ov, parent)
            if resolved is None:
                report.append({"id": child["id"], "raw": ov.strip(),
                               "resolved": None, "label": None,
                               "error": _override_error(ov)})
                continue
            self._write_child_override(
                child["id"], resolved["scope"], resolved["tier"])
            report.append({"id": child["id"], "raw": ov.strip(),
                           "resolved": resolved,
                           "label": _override_label(resolved), "error": None})
        return report

    def _write_child_override(self, mid, scope, tier):
        sp = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                          "state.json")
        try:
            with open(sp) as fh:
                state = json.load(fh)
        except (OSError, ValueError):
            return
        if not isinstance(state, dict):
            return
        state["modelOverride"] = {"scope": scope, "tier": tier}
        with open(sp, "w") as fh:
            json.dump(state, fh, indent=2)
            fh.write("\n")

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

    # ── S91: staging pasted images for the conversational worker ──────────────
    # The captain pastes/drops an image into the File idea box, the Align grill
    # reply, or the Mission-Log box; it rides the existing write body as
    # `images:[{name,type,dataB64}]`. We DECODE the base64 with the stdlib
    # `base64` module (NO Pillow/PIL — we never inspect or re-encode the pixels,
    # we just write the bytes) and stage each under repo_root, MIRRORING
    # `_tmp_prd`, so the worker can reach it: copilot via `--attachment <path>`,
    # claude via its Read tool on the abs path. The server has already enforced
    # the content-type allow-list (415) and the body cap (413) before we get here.
    def _stage_image(self, content_type, data_b64):
        """Decode one base64 image and stage it under repo_root; return the abs
        path. The suffix follows the (already allow-listed) content type so the
        worker's image loader recognises it. Caller owns cleanup."""
        suffix = _IMAGE_SUFFIX.get((content_type or "").strip().lower(), ".png")
        try:
            raw = base64.b64decode((data_b64 or "").encode("ascii"),
                                   validate=True)
        except (binascii.Error, ValueError, UnicodeEncodeError):
            raise ActionError(400, "image data is not valid base64")
        fd, path = tempfile.mkstemp(prefix="lcars-img-", suffix=suffix,
                                    dir=self.repo_root)
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw)
        return path

    def _stage_images(self, images):
        """Stage every `{name,type,dataB64}` in `images`; return the abs paths
        (in order). A blank/None list stages nothing and returns []."""
        out = []
        for img in (images or []):
            if not isinstance(img, dict):
                continue
            data = img.get("dataB64")
            if not data:
                continue
            out.append(self._stage_image(img.get("type"), data))
        return out

    def _stage_session_images(self, sess, images):
        """Stage THIS turn's images, record them on the grill session for
        end-of-session cleanup, and return THIS turn's paths to attach to THIS
        turn's worker call (the captain pasted them into THIS reply)."""
        paths = self._stage_images(images)
        if paths:
            sess.image_paths.extend(paths)
        return paths

    @staticmethod
    def _reap_session_images(sess):
        """Unlink every image staged across a grill session (done/cancel)."""
        for p in (sess.image_paths or []):
            try:
                os.unlink(p)
            except OSError:
                pass
        sess.image_paths = []


# S91 — the allow-listed image content types → the staged-file suffix. Mirrors
# the server's content-type allow-list (server.py `_ALLOWED_IMAGE_TYPES`); an
# unknown type never reaches here (the server 415s first), so the `.png` default
# is only a belt-and-braces fallback.
_IMAGE_SUFFIX = {
    "image/png": ".png",
    "image/jpeg": ".jpg",
    "image/gif": ".gif",
    "image/webp": ".webp",
}


def _grill_model(engine):
    """S78 CHANGE 3 — the Align-grill model, resolved from the mission ENGINE.

    Mirrors alias_for_tier's per-engine DEFAULT (skills/lcars-run/run.sh) so the
    grill is NOT a bare CLI default and stays at CLI parity with the pipeline:
      * copilot → "claude-opus-4.8" (OPUS-SAFE — copilot's create-tool can't
        overwrite on a non-opus tier, so the whole engine runs opus by default).
      * claude  → "sonnet" (its default reasoning tier).
    Engine is the worker bin path; selection is by basename (same idiom as
    _session_args). Stdlib only — no second resolver, no estimate read here (the
    grill predates an estimate; it follows the engine's DEFAULT tier).
    """
    base = os.path.basename(engine or "").lower()
    if "copilot" in base:
        return "claude-opus-4.8"
    return "sonnet"


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
        "launch": os.path.join(
            home, ".claude/skills/lcars-launch/launch.sh"),
        "version_check": os.path.join(
            home, ".claude/skills/lcars-version/check.sh"),
    }
    scripts = {}
    for key, default in default_dir.items():
        scripts[key] = env.get(SCRIPT_ENV[key], default)
    return Actions(repo_root=repo_root, scripts=scripts,
                   worker_bin=worker_bin, gh_bin=gh_bin,
                   check_script=scripts.get("version_check"))
