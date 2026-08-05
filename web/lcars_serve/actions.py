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
import time
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
    # S146: `lcars update` — the /api/config/* endpoints shell its test-
    # readiness verbs (--test-command / --probe-tests / --fix-tests). The CLI
    # verbs stay the ONE sanctioned config writer; the daemon only dispatches.
    "update": "LCARS_UPDATE_SCRIPT",
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


# The keys that mark a parsed object as a WORKER TURN rather than incidental
# JSON on stdout (a tool argument, a config blob a tool echoed, …). The Align
# grill emits status/question/prd/adr; the Mission-Log split emits bugs.
_TURN_KEYS = ("status", "question", "prd", "adr", "bugs")


def _json_objects(text):
    """Every top-level JSON OBJECT in `text` that parses, in order of appearance.

    Both the fenced form (```json { … } ```) and bare balanced brace spans are
    collected. A span that does not parse is skipped and the scan resumes at the
    next `{`; a span that DOES parse is consumed whole (the scan resumes after
    it) so nested objects are never double-reported.
    """
    found = []
    for m in re.finditer(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.DOTALL):
        try:
            obj = json.loads(m.group(1))
        except ValueError:
            continue
        if isinstance(obj, dict):
            found.append(obj)
    start = text.find("{")
    while start != -1:
        depth = 0
        end = -1
        for i in range(start, len(text)):
            c = text[i]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end == -1:
            break  # unbalanced tail — nothing further can close.
        try:
            obj = json.loads(text[start:end + 1])
        except ValueError:
            start = text.find("{", start + 1)
            continue
        if isinstance(obj, dict):
            found.append(obj)
        start = text.find("{", end + 1)
    return found


def _extract_json(text):
    """Pull the worker's TURN object out of its stdout.

    Workers wrap output in a ```json fence, emit leading debug — and, when their
    tools-denied posture slips, print TOOL ACTIVITY around the turn. That last
    case is why this cannot simply take the first balanced `{...}` that parses
    (BUG — the Align console blanked mid-interview, 2026-07-29): a copilot
    continuation turn that used its builtin `view` tool printed the tool's own
    argument object — `{"path": "..."}`, perfectly valid JSON — ahead of the real
    turn. Taking that first blob yielded a turn with no `question` and no `prd`,
    which the console rendered as an empty, unrecoverable grill.

    So: collect EVERY parseable top-level object, and prefer the LAST one that
    carries turn keys. The turn is the worker's final message, so the last
    turn-shaped object is the turn; tool noise is never turn-shaped. With no
    turn-shaped candidate at all, fall back to the first parseable object (the
    long-standing behaviour) and let the caller judge it. Returns the dict, or
    None if nothing parseable is found.
    """
    if not text:
        return None
    found = _json_objects(text.strip())
    if not found:
        return None
    turns = [o for o in found if any(k in o for k in _TURN_KEYS)]
    return turns[-1] if turns else found[0]


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

# S161 fix round 3 (R2) — how a retired Mission-Log session ended, in words. Only
# ever reached for a sid the daemon RECORDED retiring: the point of the ledger is
# that an unknown sid gets no story at all (see _missing_log_session_message).
_LOG_RETIRED_COPY = {
    "replaced": "was replaced by a newer preview",
    "discarded": "was discarded",
    "driven": "was consumed by the captain's Go",
}
# How many retirements to remember. A courtesy for stale clients, so forgetting the
# oldest just softens a message — nothing depends on it.
_LOG_RETIRED_MAX = 64
# S163 fix round 1 (D1): the DURABLE "this parent's logged-bug Go was
# dispatched" record, written into the PARENT mission's own directory under
# `.git/lcars/missions/<id>/`. It lives there for the same reason every other
# piece of mission state does (CLAUDE.md: inside `.git/`, so the target repo's
# working tree stays clean and git never tracks it), and next to the mission it
# is about so it is discoverable by anyone reading that mission.
_LOG_DISPATCH_FILE = "log-dispatch.json"
# S163 fix round 3 (D4) — the DURABLE SHORTFALL, beside the dispatch record and
# for the same reason. CAPTAIN'S RULING (2026-08-01): "save it to disk".
#
# A `partial` lived only in daemon memory: `kill -9`, relaunch, and a batch where
# 1 of 2 bugs was dropped became indistinguishable from a clean 1-bug batch — the
# card lost the "of 2", `/log/session` 404'd, and the authored text of the bug
# that never filed (a ~25s split the captain had already paid for) was gone.
# S161 made "the unfiled text is preserved verbatim and can be retried" a
# ship-blocker-grade promise; without this file the promise lasted exactly as
# long as the process.
#
# DELIBERATELY NARROW. What is written is the SHORTFALL FACT — the two counts,
# which child ids landed, and the unfiled rows' authored text — not the session.
# Durable sessions (the v2 story for BOTH consoles at once) stay out of scope.
_LOG_SHORTFALL_FILE = "log-shortfall.json"
# S163 fix round 4 (D4) — what a restarted daemon is allowed to say about a
# filing it did not do. Names the two counts FIRST (the card's "1 of 2"), then
# why they are what they are, then S161's still-standing promise about the text.
# It deliberately does NOT claim the missing bugs failed: the orphaned `log.sh`
# may still be running, and `_reconcile_interrupted` re-measures until it is not.
_INTERRUPTED_FILING_COPY = (
    "the board restarted while these bugs were being filed — %d of %d authored "
    "bug%s are on disk and %d %s not confirmed; that filing's own daemon is "
    "gone, so their authored text is still held here and File again retries "
    "just those (no second split).")
# ("is"/"are" for the un-confirmed count — a sentence that says "1 are" is a
#  small lie in the same family as the big ones this round is about.)


def _utc_now_iso():
    """The stamp format the skills write (`date -u +%Y-%m-%dT%H:%M:%SZ`)."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
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


# S163 fix round 4 (D1) — model families LCARS has no tier for.
#
# The tester typed "use haiku" and the daemon spent a worker turn discovering it
# could not resolve it, then dropped it silently. `haiku` is a real model and a
# perfectly reasonable thing for a captain to ask for; what it is not is one of
# the two tiers LCARS chooses between. That is knowable from the word alone, so
# it is answered from the word alone — deterministically, with a message that
# says WHICH word and WHAT the choices are, and without paying for a turn that
# could only ever come back empty.
_UNSUPPORTED_TIER = re.compile(
    r"\b(haiku|gpt|gpt-?[0-9.]+|o[134](?:-mini)?|gemini|grok|llama|mistral|"
    r"deepseek|qwen|codex)\b", re.IGNORECASE)


def unsupported_tier(raw):
    """The model name in `raw` that LCARS cannot pick, or None.

    Only consulted for a steer nothing else resolved — a steer that names both
    ("opus, not haiku") has already been answered by the deterministic parse,
    and second-guessing a resolution is how a working instruction gets refused.
    """
    if not isinstance(raw, str):
        return None
    m = _UNSUPPORTED_TIER.search(raw)
    return m.group(0) if m else None


def _override_error(raw):
    """The human-facing message when a steer can't be normalized (never drop)."""
    named = unsupported_tier(raw)
    if named:
        return ("%r is not a model tier LCARS can choose — it picks between "
                "Opus (higher quality) and Sonnet (cheaper), so try e.g. "
                "\"use Opus\" or \"keep it cheap\"" % named)
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
                 "worker_sid", "started", "image_paths", "mission_id",
                 "last_question")

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
        # Park & Align (F2 — resume mid-grill): the FULL open question dict of the
        # turn currently awaiting an answer (text + choices + recommended + closing).
        # Stored so GET /api/align/<sid> can restore the console at the exact question
        # — choice buttons and all — when the captain reopens a backgrounded grill.
        # In-memory only (dies with the daemon); None until the first question turn.
        self.last_question = None
        # S91 — every image the captain has pasted across this grill's turns,
        # staged on disk under repo_root. Accumulated (not reset per turn) so
        # claude can Read an earlier turn's image if a later turn references it;
        # reaped when the session ends (done or cancel) so nothing leaks.
        self.image_paths = []


# ══ S124 — THE HOLODECK SEAM ═══════════════════════════════════════════════
# A SECOND conversational worker posture, sitting beside the Align grill and
# sharing NONE of its argv. The grill is a pure-reasoning, tools-DENIED turn; a
# holodeck turn WRITES mockup files. Everything below is the S124 spike record
# (18 live turns across both engines, 2026-08-04) expressed as code — the align
# machinery (`_session_args`, `_worker_turn`) is COPIED in shape and never
# mutated, so the grill's behaviour stays byte-identical.
#
# THE ONE RULE THAT IS NOT NEGOTIABLE: **no `bash` tool, ever.** The S72
# bash-dump ("copilot emits its reply via the bash tool, stdout is prose-only,
# the daemon 502s") was never caused by tools in general — it was caused by
# `bash` specifically being available as a reply channel. With bash denied and
# write tools granted, BOTH engines returned clean parseable prose on every one
# of the spike's 18 turns. `_assert_no_bash` below enforces that at the argv,
# not in a comment.

# Per (engine family, mode) → the exact tool surface. Two modes:
#   design    — WRITE posture, cwd = the program dir inside the sidecar.
#   grounding — READ-ONLY posture (D12), cwd = the TARGET repo. The DAEMON
#               writes basis.md; the worker is denied every write channel.
#
# WHAT THESE FLAGS ACTUALLY DO — measured against the live binaries 2026-08-04,
# after the round-0 comment here claimed a guarantee the flags did not deliver:
#
#   copilot `--available-tools` IS a restriction. The engine's own preamble
#       lists everything else — `bash, create, edit` included — as *Disabled*.
#       Plus `--add-dir` is a real per-path sandbox grant. Nothing more needed.
#
#   claude `--allowedTools` is a PRE-APPROVAL list, NOT a restriction, and
#       `--dangerously-skip-permissions` waives whatever is left to ask about.
#       MEASURED: `--allowedTools Read,Grep,Glob --dangerously-skip-permissions`
#       → claude CREATED A FILE. Omitting Write/Edit fences nothing.
#       `--disallowedTools` is the flag that actually refuses. MEASURED: adding
#       `--disallowedTools Write,Edit,Bash,NotebookEdit` to that same argv →
#       "BLOCKED — I have no file-writing capability… no Write tool and no
#       Bash/shell tool available (confirmed via ToolSearch and by delegating to
#       a subagent, which hit the same restriction)", and no file was created.
#
# So each claude posture carries BOTH lists: the allow list says what it may
# reach for, the DENY list is the part that stops it. That is also what turns
# `_assert_no_bash` from a comment about the S72 reply channel into a mechanism:
# before this, denying `bash` meant only that the daemon never NAMED it, while
# the worker had a shell regardless.
_HOLODECK_TOOLS = {
    ("claude", "design"): "Read,Grep,Glob,Write,Edit",
    ("claude", "grounding"): "Read,Grep,Glob",
    # `edit` is REQUIRED in the copilot design set, not optional: copilot's
    # `create` CANNOT overwrite an existing file (measured on CLI 1.0.79-1 — a
    # hard `Path already exists` tool error, zero bytes changed), and turn 2 of
    # any design chat IS an overwrite. Without `edit` the channel is one-shot
    # per path and the engine degrades to the fenced-block fallback.
    ("copilot", "design"): "view,grep,glob,create,edit",
    ("copilot", "grounding"): "view,grep,glob",
}

# claude only (see above): what `--disallowedTools` refuses. The DESIGN room
# keeps Write/Edit — building the mockup is its whole job — and loses the shell,
# which closes the S72 reply-channel class on claude too. GROUNDING loses every
# write channel the CLI has, because it runs in the captain's real project.
_HOLODECK_DENY = {
    ("claude", "design"): "Bash,NotebookEdit",
    ("claude", "grounding"): "Write,Edit,Bash,NotebookEdit",
}

_HOLODECK_MODES = ("design", "grounding")

# copilot's MCP-discipline flags. Without them copilot re-boots its builtin MCP
# servers and re-reads custom instructions on EVERY warm turn (26s → 13s
# measured at S72, re-confirmed in the S124 spike). A chat room cannot afford it.
_COPILOT_DISCIPLINE = ("--allow-all-tools", "--no-ask-user",
                       "--disable-builtin-mcps", "--no-custom-instructions")


def _is_copilot(bin_):
    return "copilot" in os.path.basename(bin_ or "").lower()


def _holodeck_model(engine):
    """The holodeck's per-engine model tier.

    The holodeck is the CHEAP room, so this deliberately follows the same
    per-engine DEFAULT the Align grill uses (`_grill_model`) rather than reading
    a mission estimate — but it is its OWN function, because the two are free to
    diverge and a later session dropping copilot to `claude-sonnet-4.6` must not
    silently re-tier every grill in the product.

    claude  → "sonnet"           (the captain's pre-authorized S124 tier)
    copilot → "claude-opus-4.8"  (free; kept for output quality)

    NB the spike REFUTED the old justification for the copilot opus pin: on CLI
    1.0.79-1 `claude-sonnet-4.6` created AND edited files fine, and `create`
    cannot overwrite on opus either. The pin is a quality choice now, not a
    capability one.
    """
    return "claude-opus-4.8" if _is_copilot(engine) else "sonnet"


def _assert_no_bash(cmd):
    """Refuse any holodeck argv that does not actually deny the worker a shell.

    This is the S72 root-cause guard, enforced at the ONE place every holodeck
    turn passes through, and it has TWO halves — because on claude the first
    half alone proves nothing:

      1. no GRANT list names a shell. Every token is inspected EXCEPT the binary
         path (which may live under a .../bin/bash-shaped path), the prompt body
         (which may legitimately *discuss* bash) and the DENY list (where naming
         `Bash` is the point), split on the separators a tool list can use so
         `--available-tools view,bash` is caught as surely as a bare `Bash`.

      2. a claude argv MUST also carry a `--disallowedTools` that names `Bash`.
         Round 0 had only half 1, which is satisfied by an argv that hands the
         worker a shell anyway: `--allowedTools` is a pre-approval list and
         `--dangerously-skip-permissions` waives the rest. Half 2 is the half
         that makes this function a mechanism instead of a naming convention.

         It is keyed off the ENGINE (copilot / not-copilot), never off the
         PRESENCE of `--allowedTools` (D3, round 1). Keyed off the flag, a later
         session dropping `--allowedTools` from the claude argv for an unrelated
         reason would have retired the requirement silently — the guard would
         stop guarding with nobody editing it. copilot is exempt because
         `--available-tools` IS a restriction there and the CLI has no
         `--disallowedTools` to carry.

    What it still cannot prove: that the CLI honours the flag. That was measured
    by hand (see the `_HOLODECK_TOOLS` block); no argv check can see it.
    """
    denied = ""
    grants = []
    skip_next = False
    for i, tok in enumerate(cmd):
        if i == 0:
            continue
        tok = str(tok)
        if skip_next:
            skip_next = False
            continue
        if tok in ("-p", "--disallowedTools"):
            if tok == "--disallowedTools" and i + 1 < len(cmd):
                denied = str(cmd[i + 1])
            skip_next = True
            continue
        if tok.startswith("--disallowedTools="):
            denied = tok.split("=", 1)[1]
            continue
        grants.append(tok)
    for tok in grants:
        for piece in tok.replace("=", ",").replace(" ", ",").split(","):
            if piece.strip().lower() == "bash":
                raise ActionError(
                    500, "refused to spawn a holodeck turn with a shell tool — "
                    "the holodeck never gets `bash` (that was the S72 reply-"
                    "channel failure, and a chat room has no business running "
                    "commands)")
    if not _is_copilot(cmd[0] if cmd else ""):
        if "bash" not in [p.strip().lower() for p in denied.split(",")]:
            raise ActionError(
                500, "refused to spawn a holodeck turn that does not DENY the "
                "shell — on claude `--allowedTools` only pre-approves and "
                "`--dangerously-skip-permissions` waives the rest, so a "
                "`--disallowedTools` naming Bash is the only thing that "
                "actually takes it away")


def _slug(name):
    """A filesystem-safe program directory name, derived from the program name.

    Lowercase, non-alphanumerics collapsed to `-`, trimmed, capped. Never empty
    (falls back to "program") and never a path (no separators survive), so a
    program called `../../etc` cannot become one.
    """
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")
    return (s[:48] or "program")


# ── reply parsing: NEVER assume stdout starts at byte 0 ──────────────────────
# Measured in the spike: claude prefixes a `Warning: no stdin data received in
# 3s…` line unless stdin is DEVNULL (we DO pass DEVNULL — this is belt and
# braces for a version that warns anyway); copilot emits a ~30-line
# `Disabled tools:` preamble on EVERY turn (`--disable-builtin-mcps` does NOT
# suppress it) plus a `Changes / duration / AI Credits / Tokens / Resume`
# footer. The footer's credit figure is CUMULATIVE PER SESSION, not per turn —
# do not read it as a per-turn cost.
#
# The cleaned text is what the captain sees and what `basis.md` is written from.
# The RAW text is kept on the payload and is what the fenced-block parser reads,
# so noise can never hide a file block.
_NOISE_LINE = re.compile(
    r"^\s*Warning:\s*no stdin data received\b.*$", re.IGNORECASE)

# THE PREAMBLE, as captured (copilot CLI 1.0.79-1, 2026-08-04):
#
#     ● Disabled tools: Kusto-acr, Kusto-advisor, Kusto-aks, Kusto-appconfig,
#       Kusto-applicationinsights, Kusto-appservice, …           (~35 rows)
#       workiq-search_paths, workiq-update_entity, write_agent
#
# The list starts INLINE on the head line, after a `●` bullet. Round 0 matched
# `^\s*Disabled tools:\s*$` — a bare head line with the list beneath it — which
# is a shape copilot has never emitted, so the whole cleaner was a NO-OP on real
# output and the tool dump went into `basis.md`.
_DISABLED_TOOLS_HEAD = re.compile(
    r"^\s*(?:[●•*]\s*)?Disabled tools:", re.IGNORECASE)

# THE FOOTER, as captured — COLUMN-ALIGNED, NO COLONS, values at column 12:
#
#     Changes    +27 -0
#     AI Credits 7.86 (29s)
#     Tokens     ↑ 16.6k (7.9k cached, 8.7k written) • ↓ 811 (36 reasoning)
#     Resume     copilot --resume=a3a5ad9b-…
#
# Round 0 required colons (`AI Credits:`, `Tokens:`, `Resume:\s`), so every
# pattern missed every real line. Note `AI Credits` is padded with a SINGLE
# space, so a `\s{2,}` rule misses that row too.
#
# The key must NOT be followed by a colon: that is what separates the footer
# from the shape MEASURED being eaten on claude — an ordinary sentence beginning
# `Tokens:` / `Total duration:` / `Resume:` as the LAST line of a short reply,
# which the turn prompt ("REPLY SHORT: a sentence or two") makes near-inevitable.
_FOOTER_ROW = re.compile(r"^(Changes|AI Credits|Tokens|Resume)(?!:)\s+\S")
# `Resume` is always the LAST line of the block. Requiring it anchors the cut to
# a real footer rather than to any line that happens to start with a footer word.
_FOOTER_LAST = re.compile(r"^Resume(?!:)\s+\S")


def _cut_footer(lines):
    """Drop copilot's trailing `Changes / AI Credits / Tokens / Resume` block.

    Walks BACKWARDS and cuts ONLY a complete, contiguous, trailing footer: the
    last non-blank line must be the `Resume` row, and at least two footer rows
    must run up to it. Anything else — a footer-shaped sentence anywhere, a lone
    `Changes` line, a reply that merely ends on the word Resume — is left
    exactly as the model wrote it. A cleaner that silently deletes what the
    model said is worse than no cleaner at all.
    """
    i = len(lines)
    while i > 0 and not lines[i - 1].strip():
        i -= 1
    if i == 0 or not _FOOTER_LAST.match(lines[i - 1]):
        return lines
    cut = i - 1
    rows = 1
    j = i - 1
    while j > 0:
        prev = lines[j - 1]
        if not prev.strip():
            j -= 1
            continue
        if _FOOTER_ROW.match(prev):
            cut = j - 1
            rows += 1
            j -= 1
            continue
        break
    return lines[:cut] if rows >= 2 else lines


def _clean_reply(raw):
    """Strip the per-engine stdout noise from a holodeck turn's reply.

    Two things only: claude's stdin warning + copilot's `Disabled tools`
    preamble, and copilot's trailing credit footer. Copilot's per-tool activity
    lines (`● Create mockup.html +27`) are KEPT — they are the engine's own
    short account of what it did, and a rule that eats lines starting with `●`
    is a rule that eats prose starting with a bullet.
    """
    lines = (raw or "").replace("\r\n", "\n").split("\n")
    out = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if _NOISE_LINE.match(line):
            i += 1
            continue
        if _DISABLED_TOOLS_HEAD.match(line):
            # consume the head (the list starts ON it) plus its indented
            # continuation rows. A blank line or an unindented line ends it.
            i += 1
            while i < n and lines[i].strip() and lines[i][:1] in (" ", "\t"):
                i += 1
            continue
        out.append(line)
        i += 1
    return "\n".join(_cut_footer(out)).strip("\n")


# ── the fenced-block fallback (a DEGRADATION PATH, not the default) ──────────
# Both engines write natively (spike record). But when a write tool cannot do
# the job — measured: copilot's `create` refusing to overwrite on turn 2 — the
# engine degrades ON ITS OWN, emitting the complete file as a fenced block and
# asking for an edit tool. Rather than lose that turn, the DAEMON writes those
# blocks, producing the SAME `filesChanged` contract as a native write.
#
# THE BLOCK FORMAT (documented in the turn prompt, parsed here):
#
#     ```file:relative/path.html
#     …complete file content…
#     ```
#
# The language hint may precede it (```html file:mockup.html), and `path=` /
# `file=` are accepted spellings. A fence with NO declared path is ordinary
# markdown and writes NOTHING — the holodeck never invents a filename.
_FENCE_OPEN_DECLARED = re.compile(
    r"^```[ \t]*(?:([A-Za-z0-9_.+-]+)[ \t]+)?(?:file|path)[ \t]*[:=][ \t]*"
    r"[\"']?([^\"'\r\n]+?)[\"']?[ \t]*$")
_FENCE_ANY = re.compile(r"^```")
_FENCE_CLOSE = re.compile(r"^```[ \t]*$")


def _parse_file_blocks(raw):
    """Pull declared file blocks out of a reply.

    Returns (blocks, bad) where `blocks` is [(relpath, content)] in order and
    `bad` is the declared paths that were REFUSED as unsafe (absolute, or
    escaping the program dir via `..`). Undeclared fences are skipped whole, so
    a declared block nested inside a plain markdown fence is not harvested.
    """
    lines = (raw or "").replace("\r\n", "\n").split("\n")
    blocks = []
    bad = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        if not _FENCE_ANY.match(line):
            i += 1
            continue
        m = _FENCE_OPEN_DECLARED.match(line)
        body = []
        i += 1
        while i < n and not _FENCE_CLOSE.match(lines[i]):
            body.append(lines[i])
            i += 1
        i += 1  # step past the closing fence (or off the end)
        if not m:
            continue
        declared = (m.group(2) or "").strip()
        rel = _safe_rel(declared)
        if rel is None:
            bad.append(declared)
            continue
        content = "\n".join(body)
        if content and not content.endswith("\n"):
            content += "\n"
        blocks.append((rel, content))
    return blocks, bad


def _safe_rel(declared):
    """Normalize a declared block path to a program-dir-relative path, or None.

    Absolute paths and anything that climbs out with `..` are REFUSED — a
    fenced block is a fallback write channel, not a way around the fence."""
    p = (declared or "").strip().strip("\"'")
    if not p or os.path.isabs(p) or p.startswith("~"):
        return None
    norm = os.path.normpath(p)
    if norm.startswith("..") or os.path.isabs(norm) or norm == ".":
        return None
    return norm


# ── the post-turn filesystem audit: the ONLY real fence on claude ────────────
# Measured in the spike: `claude -p` has NO per-path sandbox. Given ONE ordinary
# sentence of authorization ("I own that repo and I'm authorizing it") it wrote
# into a DIFFERENT git repo by absolute path, no error and no prompt. Its
# refusals, when they came, proved nothing about the fence. So the fence is a
# before/after walk of real bytes on disk, and the model's own account of what
# it wrote is never consulted.
#
# copilot IS sandboxed (cwd + `--add-dir` grants), but `--add-dir` grants WRITE,
# not just read — which is exactly why grounding never grants the target repo.
def _audit_snapshot(root, skip=(), max_files=20000):
    """Walk `root` recording path → (size, mtime_ns, inode).

    STAT-ONLY, and deliberately so. The first cut hashed every file's contents;
    MEASURED on a real 9,420-file project that cost **66 seconds per walk** —
    two walks a turn, so over two minutes of pure overhead on a chat that is
    supposed to be the cheap, fast room. Stat-only is 0.2s for the same tree
    (300x), and size+mtime_ns moves on every real write, which is the thing
    being detected.

    What that trades away, stated plainly: a process that wrote a file AND
    restored its original size and nanosecond mtime would slip past. That is a
    deliberate cover-up, not the failure this fence exists for — the failure is
    a well-meaning model writing a good file in the wrong place, which always
    moves the mtime.

    `.git` is skipped: it is git's own bookkeeping, not the captain's files, and
    it churns on every commit the holodeck itself makes. Symlinked directories
    are not descended (their targets are audited by whoever owns them).

    Returns (snapshot, complete). `complete` is False when the walk hit
    `max_files` — a truncated audit is REPORTED, never quietly passed off as a
    clean one.
    """
    snap = {}
    if not root or not os.path.isdir(root):
        return snap, True
    skip_real = set(os.path.realpath(s) for s in skip if s)
    stack = [root]
    while stack:
        d = stack.pop()
        try:
            it = os.scandir(d)
        except OSError:
            continue
        with it:
            for entry in it:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        if entry.name == ".git":
                            continue
                        if os.path.realpath(entry.path) in skip_real:
                            continue
                        stack.append(entry.path)
                        continue
                    if len(snap) >= max_files:
                        return snap, False
                    st = entry.stat(follow_symlinks=False)
                    snap[entry.path] = (st.st_size, st.st_mtime_ns, st.st_ino)
                except OSError:
                    continue
    return snap, True


# ── stopping a turn that is not coming back ──────────────────────────────────
# A holodeck turn had no timeout and no cancel: `POST /end` returned ok while
# the worker stayed alive and kept writing into the sidecar of a session that no
# longer existed, and the `/say` that started it hung forever. Both cures need
# the same primitive — kill the process GROUP, because killing the worker alone
# leaves the children that are doing the writing.
def _kill_process_group(proc):
    """SIGKILL a worker and everything it spawned. True if there was one alive.

    Falls back to killing just the process when the group is gone (or when the
    platform has no process groups). Never raises: this runs on the way out of a
    turn and on `end`, and neither may fail because of a reaping race.
    """
    if proc is None or proc.poll() is not None:
        return False
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        return True
    except (OSError, AttributeError):
        try:
            proc.kill()
            return True
        except OSError:
            return False


def _audit_incomplete_message(repo_cap=None, sidecar_cap=None):
    """What a captain is told when a post-turn audit walk could not finish.

    Pass the cap of whichever walk truncated; `None` means that walk completed.

    THE TWO WALKS FAIL DIFFERENTLY AND THE COPY MUST NOT CONFLATE THEM (D1,
    round 1). Losing the walk over the captain's project costs the STRAY check —
    LCARS can no longer promise nothing was written outside the holodeck — and
    says nothing at all about the turn's own output, which is walked under its
    own separate bound and committed either way. Round 1 printed ONE sentence
    for both, and it ended "everything the turn wrote in the holodeck is
    listed" — which was the exact opposite of what happened when the same cap
    truncated the sidecar walk and `filesChanged` came back empty.
    """
    parts = []
    if repo_cap is not None:
        parts.append("LCARS could not fully check your project for stray "
                     "writes this turn — it stopped after %d %s, so it cannot "
                     "promise nothing was written outside the holodeck."
                     % (repo_cap, "file" if repo_cap == 1 else "files"))
    if sidecar_cap is None:
        parts.append("Your program's own files are listed and saved.")
    else:
        parts.append("The holodeck's own room holds more than %d %s, so this "
                     "turn's file list may be short — anything missing from it "
                     "is still on disk in the program's room."
                     % (sidecar_cap, "file" if sidecar_cap == 1 else "files"))
    if repo_cap is not None:
        parts.append("Raise $LCARS_HOLODECK_AUDIT_MAX_FILES to check the whole "
                     "project.")
    if sidecar_cap is not None:
        parts.append("Raise $LCARS_HOLODECK_SIDECAR_MAX_FILES to walk the whole "
                     "sidecar.")
    return " ".join(parts)


def _duration_words(seconds):
    """A duration rendered in the unit that does not round the difference away.

    Round 1 used `"%.0f minutes" % (limit / 60.0)`, so a 90-second limit and a
    150-second limit BOTH printed as "2 minutes" — two settings a captain would
    have chosen for different reasons, read back as the same sentence.
    """
    secs = int(round(float(seconds)))
    if secs < 120:
        return "%d %s" % (secs, "second" if secs == 1 else "seconds")
    mins = secs / 60.0
    if abs(mins - round(mins)) < 0.005:
        return "%d minutes" % int(round(mins))
    return "%.1f minutes" % mins


def _stopped_turn_error(bin_, limit, timed_out, changed):
    """(status, message) for a turn LCARS stopped — timeout or `end`.

    Leads with what survived, says plainly that the turn did not finish, and
    never leaves the captain (or S125's browser) waiting on a spinner.
    """
    kept = ("" if not changed else
            " The %d file(s) it had already written are saved and committed."
            % len({c["path"] for c in changed}))
    if not timed_out:
        return (409, "you closed this program while a turn was running, so "
                     "LCARS stopped the worker.%s" % kept)
    return (504, "the holodeck turn ran for %s without finishing, so LCARS "
                 "stopped the %s worker. Your program is safe and the chat is "
                 "still running — say it again to retry, or raise "
                 "$LCARS_HOLODECK_TURN_TIMEOUT if this program's turns really "
                 "do take that long.%s"
                 % (_duration_words(limit), os.path.basename(bin_), kept))


def _audit_diff(before, after):
    """[(abs path, status)] for every add/modify/delete between two snapshots."""
    rows = []
    for p, meta in sorted(after.items()):
        old = before.get(p)
        if old is None:
            rows.append((p, "added"))
        elif old != meta:
            rows.append((p, "modified"))
    for p in sorted(before):
        if p not in after:
            rows.append((p, "deleted"))
    return rows


class _HolodeckSession(object):
    """In-memory state for ONE holodeck PROGRAM, keyed by sessionId.

    Deliberately the same v1 contract as `_AlignSession`: stdlib only, lives in
    the daemon process, dies with it (durable programs are S126). What it adds
    over the grill session is everything the holodeck's fence needs —

    sidecar_dir : the sidecar git repo (`<reponame>-holodeck`). THE FENCE: any
        write landing outside this tree is refused and surfaced, whatever the
        engine claims it did.
    program_dir : `<sidecar>/<slug>` — this program's own room, and the turn's
        cwd + the only `--add-dir` grant copilot receives. Per-program so two
        programs cannot collide on `mockup.html`.
    target_repo : the captain's real project. Audited every turn (it is the
        thing the sidecar exists to protect) and, in GROUNDING mode only, the
        turn's read-only cwd.
    mode : "design" (write posture) or "grounding" (read-only, D12).
    files_changed : every sidecar-relative path this program has touched, in
        first-touch order — the program's own manifest.

    `worker_sid` + `started` are the same warm-session idiom as the grill: turn 1
    OPENS the conversation by uuid, every later turn RESUMES it, and the daemon
    re-feeds no transcript.
    """

    __slots__ = ("program", "engine", "mode", "sidecar_dir", "program_dir",
                 "target_repo", "worker_sid", "started", "turns",
                 "files_changed", "done", "last_reply", "proc", "turn_settled")

    def __init__(self, program, engine, mode, sidecar_dir, program_dir,
                 target_repo):
        self.program = program
        self.engine = engine
        self.mode = mode
        self.sidecar_dir = sidecar_dir
        self.program_dir = program_dir
        self.target_repo = target_repo
        self.worker_sid = str(uuid.uuid4())
        self.started = False
        self.turns = []          # [{"text": <captain>, "reply": <cleaned>}]
        self.files_changed = []  # sidecar-relative paths, first-touch order
        self.done = False
        self.last_reply = ""
        # the worker process WHILE a turn is in flight, so `end` can actually
        # stop it (and its whole process group) instead of returning ok while it
        # keeps running and writing. None between turns.
        self.proc = None
        # SET whenever no turn is in flight — and set again as soon as an
        # in-flight turn's audit AND commit have landed. `end` waits on it so
        # its file list and the turn's own answer describe the same bytes (D2).
        self.turn_settled = threading.Event()
        self.turn_settled.set()


class _LogSession(object):
    """S161 — in-memory state for ONE Mission-Log authoring flow, keyed by sid.

    The DAEMON's answer to the console-is-a-trap bug: before S161 the authored
    bug PRDs lived only in `board.js` openLog's `var authored = {...}`, arrived
    ONLY on the Preview response and were sent ONLY by the File POST. Closing the
    console between the two threw them away, so the captain had to re-run — and
    re-pay for — the split worker. Holding them here means Preview → (close) →
    reopen → File costs nothing extra.

    Deliberately the SAME v1 contract as `_AlignSession`: stdlib only, lives in
    the daemon process, dies with it. No persistence, no TTL — the durable-v2
    story is a separate, later piece of work for BOTH consoles at once.

    Fields
    ------
    parent : the parent Mission id the bugs are logged against.
    prds : the authored bug PRD bodies, in split order (the thing that used to
        evaporate). Paired POSITIONALLY with `overrides` and `image_refs`.
    children : the preview rows (title/prd/images/imageRefs) the console renders.
    image_refs / overrides : the per-bug explicit image refs and the captain's
        per-bug model steers, positional with `prds`.
    images : the RAW `{name,type,dataB64}` pastes from the report box, held in
        memory (NOT staged on disk). Filing re-stages them through the SAME
        `_file_children(images=...)` path the legacy body uses, so the log.sh
        dispatch is identical — and a previewed-but-never-filed session leaks no
        file into the repo (the S91 no-leak invariant the preview already holds).
    status : "previewed" → "filing" → "filed" | "partial" | "failed".
        DECIDED BY A POST-CONDITION CHECK, never by log.sh's exit code (D1 —
        `log.sh` runs `file_one_bug` inside a command substitution, so its `die`
        exits only the SUBSHELL and a batch that filed NOTHING still exits 0):
          filed    every authored bug is on disk.
          partial  SOME are. Not `filed` — the batch as requested did not happen,
                   and `error` names what landed and what did not.
          failed   none are.
    error : on "partial"/"failed", the plain-English shortfall + the script's own
        reason (never a stack).
    filed_map : per authored bug (positional with `prds`), the child mission id it
        became — or None while it is not on disk. THE recovery ledger (N1): the
        difference between "which bugs exist" and "which authored text is still
        only held here" is exactly this list, so a `partial` can hand back the
        words of the bugs that did not land instead of losing them. Filled in from
        the measured before/after delta around each log.sh call, so an earlier
        report's children can never be miscounted as this batch's.
    overrides_report : the per-bug resolved/errored steer report from filing.

    Three counts, three names (D2 + N1). `bug_count` is how many bugs the batch
    IS; `filed_count` how many of them reached disk; `unfiled_count` how many are
    still only held here. They are reported under those exact names on the session
    payload (and the first two on the board stamp), so a card can never say 2 while
    the truth on disk is 0. There is deliberately NO `count` — a name that means
    "authored bugs" at one status and "filed children" at another IS the defect.
    """

    # S163 fix round 4 (D4) — two fields that exist ONLY for a filing this
    # daemon did not finish. `interrupted` marks a session rebuilt from a durable
    # record that was still `filing` when it was written (i.e. the daemon that
    # was doing the filing died); `before_ids` is the set of linked children that
    # existed when that filing STARTED, which is the same before/after delta
    # `_log_file_worker` measures — so a restarted daemon can measure what the
    # ORPHANED log.sh landed afterwards instead of guessing.
    __slots__ = ("parent", "prds", "children", "image_refs", "overrides",
                 "images", "status", "error", "overrides_report", "filed_map",
                 "interrupted", "before_ids")

    def __init__(self, parent, prds, children=None, image_refs=None,
                 overrides=None, images=None):
        self.parent = parent
        self.prds = list(prds or [])
        self.children = list(children or [])
        self.image_refs = list(image_refs or [])
        self.overrides = list(overrides or [])
        self.images = list(images or [])
        self.status = "previewed"
        self.error = None
        self.overrides_report = []
        self.filed_map = [None] * len(self.prds)
        self.interrupted = False
        self.before_ids = None

    @property
    def bug_count(self):
        """How many bugs this batch is (the authored PRDs)."""
        return len(self.prds)

    @property
    def filed_ids(self):
        """The child mission ids this batch has on disk, in authored order."""
        return [c for c in self.filed_map if c]

    @property
    def filed_count(self):
        """How many of them are on disk right now."""
        return len(self.filed_ids)

    @property
    def unfiled_indices(self):
        """The authored bugs that are NOT on disk — what a File still has to do."""
        return [i for i in range(len(self.prds))
                if i >= len(self.filed_map) or not self.filed_map[i]]

    @property
    def unfiled_count(self):
        return len(self.unfiled_indices)

    def unfiled_rows(self):
        """The AUTHORED ROWS (title + full PRD text + image refs) not on disk.

        N1 — the recovery surface. A `partial` used to report only the children
        that landed, so the split worker's words for the bug that did NOT land
        existed nowhere a client could reach: the console's advice ("log the ones
        that failed as a new report") meant retyping the bug and paying for a
        second ~25s split. These rows are that text, carried on every session
        response, so a reopened console can rebuild it — or File can retry it.
        """
        rows = []
        for i in self.unfiled_indices:
            row = dict(self.children[i]) if i < len(self.children) else {}
            row["index"] = i
            row["prd"] = self.prds[i]
            if not row.get("title"):
                row["title"] = _prd_title(self.prds[i]) or "Untitled bug"
            rows.append(row)
        return rows

    def stamp(self, sid):
        """The `logFiling` shape — the ONE readout both surfaces publish (D2).

        S162 adds `error`, and only where there IS one — a shortfall or a refusal.
        The card is the surface a captain who closed the console is left with, so
        "some of your bugs did not file" has to arrive with the reason attached;
        the client cannot know it and must not invent one. Condition-gated, so a
        `previewed`/`filing`/`filed` stamp is byte-identical to its S161 self.
        """
        out = {"sessionId": sid, "status": self.status,
               "bugCount": self.bug_count, "filedCount": self.filed_count}
        if self.error:
            out["error"] = str(self.error)
        return out


def _session_from_log_record(rec):
    """(sid, `_LogSession`) rebuilt from ONE durable Mission-Log record.

    S163 fix round 3 wrote `<mission>/log-shortfall.json`; round 4 also writes it
    when a filing STARTS (D4) and reads it from a board with no write layer at
    all (D3). Three call sites, one rebuild — because the moment there are two,
    the read-only board and the restarted daemon start telling slightly
    different stories about the same file, which is the class of defect this
    whole round is about.

    Returns (None, None) for a record too damaged to mean anything: the point of
    the file is to carry a fact, and half a fact is not one.

    Reusing the ORIGINAL sid matters twice over: a client still holding it is not
    told a story about a replaced session, and `_log_dispatch_stamps`' "is this
    the session my Go consumed?" test still answers correctly across a restart.
    """
    if not isinstance(rec, dict):
        return None, None
    sid = rec.get("sessionId") or uuid.uuid4().hex[:12]
    try:
        n = int(rec.get("bugCount") or 0)
    except (TypeError, ValueError):
        return None, None
    rows = [r for r in rec.get("unfiled") or [] if isinstance(r, dict)]
    if n <= 0 or not rows:
        return None, None
    prds, children = [""] * n, [{} for _ in range(n)]
    for r in rows:
        try:
            i = int(r.get("index"))
        except (TypeError, ValueError):
            continue
        if 0 <= i < n:
            prds[i] = r.get("prd") or ""
            children[i] = {"title": r.get("title") or "Untitled bug",
                           "imageRefs": r.get("imageRefs") or []}
    sess = _LogSession(rec.get("parent"), prds, children=children)
    for k, cid in (rec.get("filed") or {}).items():
        try:
            i = int(k)
        except (TypeError, ValueError):
            continue
        if 0 <= i < n:
            sess.filed_map[i] = cid
    sess.status = rec.get("status") or "partial"
    sess.error = rec.get("error")
    # D4: a record still saying `filing` was written by a daemon that never got
    # to settle it. `before` is the linked-children snapshot that filing started
    # from, kept so the reconciliation later can be a MEASUREMENT rather than an
    # inference. `interrupted` is deliberately not persisted as its own flag —
    # "the record still says filing" IS the flag, and one fact beats two.
    if sess.status == "filing" or rec.get("interrupted"):
        sess.interrupted = True
        before = rec.get("before")
        sess.before_ids = set(before) if isinstance(before, list) else set()
    return sid, sess


class LogFacts(object):
    """The DURABLE Mission-Log facts, read straight off disk. Never a write.

    S163 fix round 4 (D3). S161/S162 built `logFiling` and `logDispatch` out of
    IN-MEMORY sessions, and a view-only board is constructed with `actions=None`
    — a DELIBERATE decision, and the right one while the state was in memory: a
    board with no write layer has no sessions to publish, so publishing nothing
    was exactly honest.

    Round 3 changed the premise. The dispatch record (`log-dispatch.json`) and
    the shortfall (`log-shortfall.json`) are now FILES under
    `.git/lcars/missions/<id>/`, and reading a file needs no write capability at
    all. Without this class the tester's two boards disagreed about the same
    repo at the same instant: a dispatched batch read "⚙ FIX 4 FILED BUGS" (work
    waiting) on the view-only board while it was already running, and two
    shortfalls were invisible there.

    So the read-only LOCAL board gets the durable half — and only the durable
    half. Two bounds, stated rather than hidden:

      • a live, never-filed PREVIEW is in-memory by construction. A read-only
        board cannot see one, so it goes on reporting the last durable dispatch
        where a read-write daemon would let the fresh preview outrank it. It is
        reporting what the disk says, which is the most it can know.
      • the GITHUB adapter is not wired to this at all (`build_log_facts`). It
        cannot see a local `.git/lcars/`, and a board claiming durable facts it
        has no access to is round 1's refused children-reading again.

    `Actions` INHERITS from this: the disk readers, `_linked_children` and
    `_waiting_children` are the same code on both boards by construction, and
    the richer in-memory overlays simply override the three public methods.
    """

    def __init__(self, repo_root, reader=None):
        self.repo_root = repo_root
        self._reader = reader if reader is not None else LocalAdapter(repo_root)

    # ── where mission state lives ────────────────────────────────────────────
    def _missions_dir(self):
        """`.git/lcars/missions` — where ALL per-repo mission state lives
        (CLAUDE.md). The one place the path is spelled out."""
        return os.path.join(self.repo_root, ".git", "lcars", "missions")

    def _linked_children(self, parent):
        out = []
        missions_dir = self._missions_dir()
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
                         "modelMix": card.get("modelMix"),
                         # S163 fix round 3: the two signals a DRIVER produces,
                         # carried so `_waiting_children` can tell a bug nothing
                         # has started from one resolve-logs already scheduled.
                         # (`dispatched` is deliberately NOT here — it is the
                         # ESTIMATOR's footprint and is true from birth; see
                         # `_mark_log_dispatched`.)
                         "queued": bool(card.get("queued")),
                         "running": bool(card.get("running"))}
                ov = _read_json_key(sp, "modelOverride")
                if isinstance(ov, dict) and ov.get("scope") and ov.get("tier"):
                    child["override"] = "%s:%s" % (ov["scope"], ov["tier"])
                out.append(child)
        return out

    # ── S163 fix round 3 — "show me everything that will run" ────────────────
    #
    # CAPTAIN'S RULING (2026-08-01), and it REVERSES a deliberate decision taken
    # one session earlier on this same unmerged branch. S161 filtered the review
    # panel to `filed_ids` — "THIS batch's children only (the measured delta), so
    # a parent that already carried bug children from an earlier report can't
    # inflate it" — which was the right defence against a lying COUNT and the
    # wrong defence against a lying REVIEW. `Go ▸` has ALWAYS spawned
    # `resolve-logs --parent <mid>`, which takes a parent and drives all of it to
    # one consolidated gate. So on a parent holding two reports the panel showed
    # list A while the dispatch acted on list B, and the round-3 tester measured
    # the consequences: a card counting 1 while 3 bugs waited, a review that
    # showed one of the three, a steer typed against the third written onto the
    # first, and a Go that ran all three anyway.
    #
    # The panel now lists every bug on the mission still waiting to be fixed,
    # whatever report it came from. What the captain sees is exactly what Go
    # runs. S161's inflated-count risk is answered by making the count HONEST for
    # the new meaning — `waitingCount`, "N bugs waiting to be fixed on this
    # mission", a differently-named fact beside the batch's own `bugCount` /
    # `filedCount`, which keep meaning exactly what they meant — rather than by
    # hiding bugs the Go is going to drive regardless.
    def _waiting_children(self, parent):
        """Every logged bug on `parent` still WAITING to be fixed.

        The review panel's list, the card's count and (by construction, since
        resolve-logs is parent-scoped) what the Go will drive.

        Excluded, and only these:
          done / verify   the fix has landed — `verify` is the consolidated
                          re-verify gate, i.e. work already done, and it is the
                          same boundary `isResolvingLocked` uses on the client.
          queued/running  a driver has it. Those are the signals resolve-logs and
                          the run lock produce; re-offering such a bug for review
                          would invite a second driver over it.
          already dispatched  a Go has taken this bug (S163 fix round 6, D3).

        That last one is the round-6 correction, and it exists because the two
        signals above are produced by the DRIVER — seconds to minutes after the
        Go — while the window this whole session is about is the gap before the
        driver has touched anything. The round-6 tester dispatched two bugs,
        logged a third against the same parent, and got all three back in the
        panel with a Go that ran them: `queued`/`running` were both still false
        on bugs a resolve-logs was already driving, and the only durable
        evidence that a Go had happened was being discarded by the fresh
        preview. The record now names the children it covered, and this is where
        that fact is spent.
        """
        # S163 fix round 7 (D3): a dispatch subtracts its children only while it
        # is a drive that EXISTS. Round 6 subtracted unconditionally, so a
        # resolver that died mid-batch left its bugs permanently invisible to the
        # review — which is what made the card's dead end total: the panel had
        # nothing in it, the count was 0, and the only control said work was in
        # flight. When the record is stale those bugs are waiting again, because
        # a resume is going to run them and the panel's one promise is that it
        # lists what runs.
        driven = (set() if self._log_dispatch_is_stale(parent)
                  else self._dispatched_child_ids(parent))
        out = []
        for c in self._linked_children(parent):
            stage = str(c.get("stage") or "").lower()
            if stage in ("done", "verify"):
                continue
            if c.get("queued") or c.get("running"):
                continue
            if c.get("id") in driven:
                continue
            out.append(c)
        return out

    # ── S163 fix round 7 (D2) — the ONE count, published for EVERY parent ────
    def _waiting_counts(self):
        """{parent id -> N} for every parent with at least one waiting bug.

        The round-7 tester read card 2 / panel 1 / Go 1 off one repo at one
        instant, having driven one of two filed bugs to `verify` by hand. Two
        things had to be true at once for that: the client was counting for
        itself with a looser rule (cured in `waitingChildren`), and it was
        counting AT ALL — because the daemon published `waitingCount` only on a
        live session's stamp, and a clean `filed` batch leaves no durable
        record, so a restarted daemon published nothing and the card had no
        choice.

        So the measurement now rides EVERY parent card that has waiting bugs,
        session or no session, on both boards. It is the same
        `_waiting_children` call the review panel and the Go make — one
        function, three surfaces, so they cannot drift apart again.

        Additive by construction: a parent with nothing waiting is absent from
        this map and its card is untouched, so a repo that never logged a bug
        still renders byte-identically to pre-158.
        """
        out = {}
        for parent in self._log_parent_ids():
            n = len(self._waiting_children(parent))
            if n:
                out[parent] = n
        return out

    def _log_parent_ids(self):
        """Every mission id named as a `parentMission` by something on disk.

        One listdir + one small key read per mission, and only then do we pay
        for `_waiting_children` — which is itself a full scan, so asking it
        about every mission on the board would be quadratic for no reason. A
        parent nothing points at can have nothing waiting.
        """
        out = set()
        missions = self._missions_dir()
        try:
            names = os.listdir(missions)
        except OSError:
            return out
        for name in names:
            sp = os.path.join(missions, name, "state.json")
            if not os.path.isfile(sp):
                continue
            pm = _read_json_key(sp, "parentMission")
            if pm:
                out.add(pm)
        return out

    def _stamp_waiting(self, board_or_card, counts=None):
        """Write `logWaitingCount` onto one card dict, if it has bugs waiting.

        Deliberately a separate top-level key rather than another field inside
        `logFiling`: the stamp describes a SESSION (S161's D2 rule — one place
        shapes that readout), and "how many bugs are waiting on this mission" is
        a fact about the mission that outlives every session it was measured
        during. Naming it apart is what lets the client read exactly one number.
        """
        if not isinstance(board_or_card, dict):
            return board_or_card
        mid = board_or_card.get("id")
        if not mid:
            return board_or_card
        if counts is None:
            counts = self._waiting_counts()
        if mid in counts:
            board_or_card["logWaitingCount"] = counts[mid]
        return board_or_card

    # ── S163 fix round 6 (D3) — what a Go TOOK, and whether it is still going ──
    def _dispatched_child_ids(self, parent):
        """The child bug missions some Go on `parent` has already dispatched.

        Cumulative across Gos (`_mark_log_dispatched` unions), so a second,
        legitimate Go for a newly-logged bug cannot make the daemon forget what
        the first one took. An old record with no `dispatched` key names none —
        it predates the field, and inventing members for it would be worse than
        the empty set (`_live_log_dispatch` covers that case the safe way).
        """
        rec = self._read_log_dispatch(parent)
        if not isinstance(rec, dict):
            return set()
        ids = rec.get("dispatched")
        return set(str(i) for i in ids) if isinstance(ids, list) else set()

    def _resolver_alive(self, rec):
        """Is the resolve-logs process this record names STILL RUNNING?

        S163 fix round 7 (D3). Round 6 answered "is a drive live?" from the
        CHILDREN's stages, and wrote its own price down: a resolver that dies
        mid-batch leaves them short of `verify` for ever, so the card asserted a
        drive in flight when there was none and the 409 pointed at a gate that
        could never be reached. A claim about right now has to be checked
        against right now, and there is exactly one authority on whether a
        process is running.

        Returns True (alive), False (provably gone), or None (this record cannot
        be checked — a pre-round-7 record with no `pid`). `None` is a real third
        answer and is treated as "not evidenced", not as "alive": a card that
        cannot evidence a drive must not assert one, which is the whole finding.
        The other direction is guarded elsewhere — the resume path re-checks and
        refuses on True, so an unevidenced record can never dispatch over a live
        drive it merely failed to recognise.

        Known bound, stated rather than hidden: after a daemon restart all we
        have is a pid, and a pid can be reused by an unrelated process. That
        would read as "still running" — the safe direction (it keeps the round-6
        refusal), and vanishingly unlikely inside one batch's life.
        """
        pid = rec.get("pid") if isinstance(rec, dict) else None
        if not isinstance(pid, int) or pid <= 0:
            return None
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False            # ESRCH — gone.
        except PermissionError:
            return True             # EPERM — alive, owned by someone else.
        except OSError:
            return None
        return True

    def _log_dispatch_is_stale(self, parent, rec=None):
        """Does `parent` hold a dispatch record whose drive is NOT running?

        Both halves must be true: the resolver is not evidenced as alive AND the
        batch has not reached its gate. A finished drive is not stale — it is
        finished, and `_live_log_dispatch` already returns None for it, which is
        what re-arms an ordinary Go for whatever was logged since.
        """
        if rec is None:
            rec = self._read_log_dispatch(parent)
        if not isinstance(rec, dict):
            return False
        if self._resolver_alive(rec) is True:
            return False
        return self._batch_short_of_its_gate(parent, rec)

    def _batch_short_of_its_gate(self, parent, rec):
        """Has any child this dispatch took NOT reached `verify`/`done` yet?

        Round 6's reading, lifted out unchanged so the liveness question and the
        progress question are asked separately and can be reasoned about apart.
        """
        ids = self._dispatched_child_ids(parent)
        kids = self._linked_children(parent)
        if not ids:
            ids = set(c["id"] for c in kids)
        stages = dict((c["id"], str(c.get("stage") or "").lower()) for c in kids)
        for cid in ids:
            stage = stages.get(cid)
            if stage is None:
                continue            # a child that has vanished is not waited on
            if stage not in ("verify", "done"):
                return True
        return False

    def _live_log_dispatch(self, parent):
        """The dispatch record for `parent` IF the drive it records is STILL ON.

        The round-3 mark answered "has a Go been taken?" and was spent by the
        next preview, which is how a new report re-armed the Go over a batch
        mid-drive. This answers the question that actually matters — "is a
        resolve-logs still working on this parent?" — and it is a MEASUREMENT,
        not a mark: a drive is over when every child it took has reached its
        `verify` gate (the consolidated re-verify gate resolve-logs raises) or
        `done`. Nothing a later preview does can change that answer.

        A child that has vanished is not something to wait for. A record naming
        no children at all (pre-round-6) falls back to the same reading over
        every linked child, which errs towards "still going" — the safe
        direction, since the other way round is the double dispatch.

        S163 fix round 7 (D3) — what this NO LONGER claims. It used to read the
        children alone, and round 6 wrote the price down: "a resolve-logs that
        dies mid-batch leaves its children short of verify and the Go stays
        refused until they are driven by hand". The tester paid it and returned
        the finding this round is about — a card asserting a drive that did not
        exist, with the only stated route forward an event that could not occur.

        So the progress reading is now ANDed with a liveness reading
        (`_resolver_alive`): a batch short of its gate is a live drive only while
        the process driving it is actually there. When it is not, this returns
        None and `_log_dispatch_is_stale` returns True — which is what puts an
        honest, working control back on the card. The plain Go is still refused
        (`log_run` keeps its own guard on the RECORD, not on this), so nothing
        round 6 built is loosened by accident; the resume is the one deliberate
        door, and it re-checks liveness before it opens.
        """
        rec = self._read_log_dispatch(parent)
        if not isinstance(rec, dict):
            return None
        if not self._batch_short_of_its_gate(parent, rec):
            return None
        if self._resolver_alive(rec) is False:
            return None             # provably gone — see _log_dispatch_is_stale
        return rec

    # ── the durable DISPATCH record ──────────────────────────────────────────
    def _log_dispatch_path(self, parent):
        return os.path.join(self._missions_dir(), parent, _LOG_DISPATCH_FILE)

    def _read_log_dispatch(self, parent):
        """The durable dispatch record for `parent`, or None. Never raises —
        an unreadable/garbled record is simply not a record."""
        try:
            with open(self._log_dispatch_path(parent)) as fh:
                rec = json.load(fh)
        except (OSError, ValueError):
            return None
        if not isinstance(rec, dict) or rec.get("status") != "dispatched":
            return None
        return rec

    def _disk_log_dispatches(self):
        """{parent id -> record} for every durable dispatch record on disk.

        One listdir + one small read per mission that HAS a record, on a board
        that already stats every mission dir to build a card.
        """
        out = {}
        missions = self._missions_dir()
        try:
            names = os.listdir(missions)
        except OSError:
            return out
        for name in names:
            if not os.path.isfile(os.path.join(missions, name,
                                               _LOG_DISPATCH_FILE)):
                continue
            rec = self._read_log_dispatch(name)
            if rec is not None:
                out[name] = rec
        return out

    # ── the durable FILING/SHORTFALL record ──────────────────────────────────
    def _log_shortfall_path(self, parent):
        return os.path.join(self._missions_dir(), parent, _LOG_SHORTFALL_FILE)

    def _disk_log_shortfalls(self):
        """{parent id -> record} for every durable filing record on disk."""
        out = {}
        missions = self._missions_dir()
        try:
            names = os.listdir(missions)
        except OSError:
            return out
        for name in names:
            p = os.path.join(missions, name, _LOG_SHORTFALL_FILE)
            if not os.path.isfile(p):
                continue
            try:
                with open(p) as fh:
                    rec = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(rec, dict) and rec.get("unfiled"):
                out[name] = rec
        return out

    # ── the read-only overlays (the write board overrides all three) ─────────
    def _durable_stamps(self):
        """{parent id -> the `logFiling` stamp} from the durable records.

        Shaped by `_LogSession.stamp` — the ONE place the readout is built (the
        S161-D2 rule) — plus `waitingCount`, so a view-only card and a
        read-write card carry byte-identical keys off the same disk state.
        """
        out = {}
        for parent, rec in self._disk_log_shortfalls().items():
            sid, sess = _session_from_log_record(rec)
            if sess is None:
                continue
            stamp = sess.stamp(sid)
            stamp["waitingCount"] = len(self._waiting_children(parent))
            out[parent] = stamp
        return out

    def log_overlay(self, board):
        """Stamp the DURABLE `logFiling`/`logDispatch` facts onto board cards.

        Same additive contract as the write board's overlay: with nothing on
        disk the board is returned byte-for-byte unchanged, so a repo that never
        logged a bug renders exactly as it did before this round.
        """
        if not isinstance(board, dict):
            return board
        cols = board.get("columns")
        if not isinstance(cols, dict):
            return board
        stamps = self._durable_stamps()
        marks = self._disk_log_dispatches()
        # S163 fix round 7 (D2): the waiting count rides the card whether or not
        # a record exists — a clean `filed` batch leaves none, and that is
        # exactly the case where the client was left counting for itself.
        waiting = self._waiting_counts()
        if not stamps and not marks and not waiting:
            return board
        for col in cols.values():
            if not isinstance(col, list):
                continue
            for card in col:
                if not isinstance(card, dict):
                    continue
                if card.get("id") in stamps:
                    card["logFiling"] = stamps[card["id"]]
                if card.get("id") in marks:
                    # S163 fix round 7 (D3): the same liveness flag the
                    # read-write board publishes, from the same reader on the
                    # same disk — a view-only board that went on claiming a dead
                    # drive would be the round-2 "one repo, two answers" defect
                    # wearing a different hat.
                    mark = dict(marks[card["id"]])
                    if self._log_dispatch_is_stale(card["id"], mark):
                        mark["stale"] = True
                    card["logDispatch"] = mark
                self._stamp_waiting(card, waiting)
        return board

    def log_overlay_mission(self, mission):
        """The same two stamps on a mission DETAIL dict — because the detail
        never runs through the board overlay (the `align_overlay_mission`
        lesson), and a card and its detail disagreeing is the very defect."""
        if not isinstance(mission, dict):
            return mission
        mid = mission.get("id")
        if not mid:
            return mission
        stamp = self._durable_stamps().get(mid)
        if stamp is not None:
            mission["logFiling"] = stamp
        mark = self._disk_log_dispatches().get(mid)
        if mark is not None:
            mark = dict(mark)
            if self._log_dispatch_is_stale(mid, mark):
                mark["stale"] = True
            mission["logDispatch"] = mark
        # the detail must count the same bugs the card does, or D2 simply moves
        # one click deeper (the `align_overlay_mission` lesson again).
        return self._stamp_waiting(mission)

    def log_session_state(self, mid):
        """GET .../log/session on a board with NO write layer.

        There is no session here and there never will be — but the durable
        record holds the same facts the console would restore from, so answering
        with them beats "this board is read-only, so it holds none" while a
        shortfall sits on disk. Read-only by construction: it opens one file.
        """
        rec = self._disk_log_shortfalls().get(mid)
        sid, sess = _session_from_log_record(rec) if rec else (None, None)
        if sess is None:
            raise ActionError(
                404, "no mission-log session for %s — this board is read-only, "
                     "so it holds none" % mid)
        waiting = self._waiting_children(mid)
        out = {"sessionId": sid, "parent": mid, "status": sess.status,
               "authored": False, "filed": False,
               "children": waiting, "overrides": [],
               "bugCount": sess.bug_count, "filedCount": sess.filed_count,
               "unfiled": sess.unfiled_rows(),
               "unfiledCount": sess.unfiled_count,
               "waiting": waiting, "waitingCount": len(waiting),
               "readOnly": True}
        if sess.error:
            out["error"] = sess.error
        return out


class Actions(LogFacts):
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
                 check_script=None, holodeck_root=None, git_bin=None):
        # S163 fix round 4 (D3): the durable-facts reader is now the BASE, so
        # `_linked_children`, `_waiting_children` and the two on-disk record
        # readers are literally the same code the view-only board runs.
        LogFacts.__init__(self, repo_root)
        self.scripts = dict(scripts or {})
        self.worker_bin = worker_bin
        self.gh_bin = gh_bin
        # S130: the shared version helper (skills/lcars-version/check.sh) the
        # /api/update button shells in `update` mode. Falls back to a `scripts`
        # entry so a directly-constructed Actions can still wire it.
        self.check_script = check_script or self.scripts.get("version_check")
        # active Align grillings, keyed by sessionId (in-memory; ADR-006 local).
        self._align = {}
        self._align_lock = threading.Lock()
        # S124 — active HOLODECK programs, keyed by sessionId. Same in-memory /
        # dies-with-the-daemon contract as `_align` (durable programs are S126).
        self._holodeck = {}
        self._holodeck_lock = threading.Lock()
        # S124 — the two injectable seams the holodeck adds. BOTH default from
        # the environment so a test (and an alternative install) can point them
        # somewhere harmless: `holodeck_root` is the directory the sidecar repo
        # is created IN (default: beside the target repo), `git_bin` is the git
        # used to init/commit it. Tests inject a tmpdir root so nothing can ever
        # reach the captain's real ~/Projects.
        self.holodeck_root = (holodeck_root
                              or os.environ.get("LCARS_HOLODECK_ROOT") or "")
        self.git_bin = (git_bin or os.environ.get("LCARS_GIT_BIN") or "git")
        # S161: active Mission-Log authoring sessions, keyed by sessionId. Same
        # in-memory / dies-with-the-daemon contract as `_align` above; one live
        # session per parent mission (a fresh preview replaces the old one).
        self._log_sessions = {}
        self._log_lock = threading.Lock()
        # S163: parents whose filed batch the captain's Go HAS dispatched, as
        # {parent id -> {"sessionId", "status"}}. Not a session and not a ledger —
        # a single fact the card needs and cannot derive: `log_run` spawns
        # resolve-logs fire-and-forget, and it is resolve-logs (seconds later)
        # that marks the children `queued`, so in between the board looks
        # identical to the pre-Go board. Same in-memory contract as the sessions;
        # cleared by a fresh preview for that parent. See `_log_dispatch_stamps`.
        self._log_dispatched = {}
        # S163 fix round 4 (D2): parents whose Go is being dispatched RIGHT NOW —
        # the in-flight half of the same fact. `_log_dispatched` is only true
        # after the spawn; this covers the window between the request winning the
        # race and the record existing, which is precisely where five concurrent
        # Gos all passed round 3's check.
        self._log_dispatching = set()
        # S163 fix round 7 (D3): {parent id -> the resolve-logs Popen handle}.
        # NOT a record — the record is on disk and carries the pid. This exists
        # only so THIS daemon can `poll()` the child it spawned rather than
        # signalling a zombie it never reaped, which would report a finished
        # drive as running for as long as the daemon lives. Bounded by the number
        # of parents that have ever been dispatched in one daemon's life.
        self._log_procs = {}
        # S163 fix round 3 (D4): have the durable SHORTFALL records on disk been
        # read back into `_log_sessions` yet? Done ONCE, lazily, on the first
        # surface that needs a session — nothing else in the product writes those
        # files, so after the first scan memory is authoritative and a per-board
        # re-scan would only cost a listdir to learn nothing.
        self._log_rehydrated = False
        # S161 fix round 3 (R2): sids this daemon HAS held and how each one ended
        # ({sid: {"parent","reason","by"}}, insertion-ordered, capped). Without it
        # an unknown sid could only be GUESSED at, and the guess on offer — "it was
        # replaced by a newer preview" — is a claim about a session the daemon may
        # never have seen. Remembering the retirement is what makes "replaced"
        # sayable exactly when it is true, and nothing more.
        self._log_retired = {}
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
        #
        # pre-165 Fix A — THE HANDLER MUST ALSO TERMINATE, or installing it DISABLES the
        # signal. At daemon start `prev` is SIG_DFL, which is neither callable
        # nor chainable, so the original handler reaped the launches and simply
        # RETURNED — and returning from a Python signal handler resumes the
        # interrupted call, so `serve_forever()` carried straight on. `kill
        # <daemon-pid>` did nothing; only `kill -9` stopped the board, and every
        # session leaked an orphaned daemon holding its port. Installing a
        # handler had converted SIGTERM from "terminate" into "reap the launches
        # and keep running".
        #
        # So: reap, then either hand over to a REAL prior handler (it owns the
        # exit — that was, and stays, the contract for an embedder that wanted
        # SIGTERM) or restore the DEFAULT disposition and re-raise to ourselves,
        # so the process dies by the conventional signal with the conventional
        # status. Not os._exit(): the re-raise keeps the exit status honest
        # (128+15) for anything waiting on the daemon. The OS releases the bound
        # port either way, so a restart binds it again immediately.
        atexit.register(self.shutdown_launches)
        try:
            prev = signal.getsignal(signal.SIGTERM)

            def _on_sigterm(signum, frame, _prev=prev):
                try:
                    self.shutdown_launches()
                finally:
                    if callable(_prev) and _prev not in (
                            signal.SIG_DFL, signal.SIG_IGN):
                        # someone else already owned SIGTERM (including an
                        # earlier Actions in this process, which chains on to
                        # ITS predecessor — a finite nesting, never recursion).
                        _prev(signum, frame)
                    else:
                        signal.signal(signal.SIGTERM, signal.SIG_DFL)
                        os.kill(os.getpid(), signal.SIGTERM)
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
        # A question with no text is DEAD ON SCREEN: the console renders its
        # "What would you like to refine?" fallback over an empty PRD panel, with
        # no error to say the turn was lost — and the falsy question it records
        # also strips the mission's RESUME ALIGN affordance (align_overlay needs a
        # truthy last_question). Never ship one. Raising HERE, before the session
        # is mutated, leaves the grill exactly as it was: the console shows the
        # error and re-arms Submit, the previous question and the assembled PRD
        # survive, and the captain simply answers again.
        if not (q.get("text") or "").strip():
            raise ActionError(
                502, "the Align worker's reply could not be read as a question "
                "(engine=%s) — the grill is unchanged; answer again to retry."
                % (sess.engine or self.worker_bin or "default"))
        sess.transcript.append({"question": q.get("text", ""), "answer": None})
        # Park & Align (F2): remember the full open question so a backgrounded grill
        # can be RESUMED at this exact turn (choices included) via GET /api/align/<sid>.
        sess.last_question = q
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

    def align_state(self, sid):
        """GET /api/align/<sid> — the session's current OPEN turn, for RESUME.

        Park & Align (F2 — resume mid-grill): the captain backgrounded an Align
        console; this returns the same {sessionId, status:"question", question, prd}
        shape a turn returns, restoring the console at the exact open question (choice
        buttons and all) when they reopen it. The stored `last_question` is the full
        question dict; if the session somehow has none yet, fall back to the last
        transcript question text. Unknown/aged-out sid → 404 (the client falls back to
        a fresh grill). In-memory only — a daemon restart drops every session.
        """
        with self._align_lock:
            sess = self._align.get(sid)
        if sess is None:
            raise ActionError(404, "no such align session: %s" % sid)
        q = sess.last_question
        if not q:
            text = ""
            if sess.transcript:
                text = sess.transcript[-1].get("question") or ""
            q = {"text": text}
        return {"sessionId": sid, "status": "question",
                "question": q, "prd": sess.prd}

    def align_overlay(self, board):
        """Additively mark parked cards that have a LIVE resumable align session.

        Park & Align (F2): so RESUME ALIGN survives a page reload (a fresh tab has no
        client-side RESUMABLE map), stamp `card["alignResume"] = {"sid": <sid>}` onto
        the board card of every mission that owns a live, un-done grill session. Purely
        in-memory and ADDITIVE — a board with no live sessions is returned byte-for-byte
        unchanged. This overlay does NOT move `adapter.fingerprint()`, so it never
        drives an SSE push (correct — the client marks its own close instantly; the
        safety poll re-fetches /api/board for other tabs / after a reload).

        A read-only / github build constructs the daemon with actions=None, so this is
        never reached there — the resume affordance is a local-write-board feature only.
        """
        if not isinstance(board, dict):
            return board
        cols = board.get("columns")
        if not isinstance(cols, dict):
            return board
        with self._align_lock:
            # one live session per mission expected; last wins on the odd duplicate.
            # Only advertise RESUME once the session has a CONCRETE open question to
            # restore (last_question set). A freshly-created session whose opening
            # worker turn is still in flight has no question yet — offering RESUME then
            # reopens an empty console ("What would you like to refine?" fallback), so
            # it stays scanning/parked until the first question lands.
            by_mission = {}
            for sid, sess in self._align.items():
                if sess.mission_id and not sess.done and sess.last_question:
                    by_mission[sess.mission_id] = sid
        if not by_mission:
            return board  # no live sessions → byte-identical board.
        for col in cols.values():
            if not isinstance(col, list):
                continue
            for card in col:
                if isinstance(card, dict) and card.get("id") in by_mission:
                    card["alignResume"] = {"sid": by_mission[card["id"]]}
        return board

    def align_session_sid(self, mission_id):
        """The live, un-done grill session id for a mission, or None (Park & Align F2)."""
        if not mission_id:
            return None
        with self._align_lock:
            for sid, sess in self._align.items():
                # match align_overlay: only resumable once a real question exists.
                if (sess.mission_id == mission_id and not sess.done
                        and sess.last_question):
                    return sid
        return None

    def align_overlay_mission(self, mission):
        """Stamp `alignResume` onto a SINGLE mission-DETAIL dict (Park & Align F2).

        The `/api/mission/<id>` detail payload must mirror the board card so the DETAIL
        modal shows ▹ RESUME ALIGN too — not just the card. Without this the detail
        (which never runs through `align_overlay`) falls back to the client-only
        RESUMABLE map, which is empty after a page reload. Additive + in-memory: a
        mission with no live session is returned unchanged.
        """
        if isinstance(mission, dict):
            sid = self.align_session_sid(mission.get("id"))
            if sid:
                mission["alignResume"] = {"sid": sid}
        return mission

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
            # Same rule as `_tmp_prd`/`_stage_image`: an LCARS-owned directory in
            # the captain's working tree is dirt the freshness guard will blame
            # on them, so it lives under `.git/` where git cannot see it.
            outdir = tempfile.mkdtemp(prefix="lcars-worker-",
                                      dir=self._scratch_dir())
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

    # ══ S124 — THE HOLODECK ════════════════════════════════════════════════
    # `/api/holodeck/start|say|end`: warm, resumable, cheap chat turns that
    # write mockup files into a SIDECAR git repo. It mirrors the Align family's
    # SHAPE and shares none of its argv (see the module block above). Three
    # invariants hold here and are worth stating where they are enforced:
    #   • the holodeck never spawns a Stage and never writes mission state;
    #   • writes go ONLY inside the sidecar — proven by a post-turn filesystem
    #     audit, never by the model's account of what it did;
    #   • the Align grill's tools-denied warm turn is untouched.

    def holodeck_start(self, repo=None, program=None, engine=None,
                       mode="design", images=None):
        """POST /api/holodeck/start — open a holodeck PROGRAM.

        `program` is the subject being designed (D8) and names the program's own
        room inside the sidecar. `repo` is the target project (default: this
        daemon's repo) — it names the sidecar and is the read-only cwd of a
        GROUNDING pass. `engine` picks the CLI; `mode` picks the posture:

          design    (default) — opens the room and SPENDS NOTHING. The warm
              worker session is opened by the FIRST `say`, so a captain who
              opens a program and walks away has paid for nothing.
          grounding (D12) — runs ONE cheap read-only pass over the target repo
              right now and writes `basis.md` from the reply. It is a SEPARATE
              session from the design chat by design: the two postures have
              different tools AND different cwds, and resuming one warm session
              across that switch is a behaviour no spike has measured.
        """
        if images:
            # The image-paste road (S91/S92) is measured on both engines, but
            # threading it through a HOLODECK turn is untested here — say so
            # rather than accept the paste and silently drop it.
            raise ActionError(
                400, "the holodeck cannot take pasted images yet — start the "
                "program without one and describe what you want in words")
        program = (program or "").strip()
        if not program:
            raise ActionError(400, "missing required field: program")
        mode = (mode or "design").strip().lower()
        if mode not in _HOLODECK_MODES:
            raise ActionError(
                400, "unknown holodeck mode %r — it is either \"design\" (chat "
                "and build the mockup) or \"grounding\" (one read-only look at "
                "the project first)" % mode)
        target = os.path.abspath((repo or "").strip() or self.repo_root)
        if not os.path.isdir(target):
            raise ActionError(404, "no such repo: %s" % target)
        # THE ENGINE IS CHECKED BEFORE ANYTHING IS CREATED. Round 0 built the
        # sidecar git repo and the program's room, answered 200 with
        # `"engine": null`, and only failed on the first `say` — leaving a
        # directory tree behind for a program that could never have run.
        self._resolve_holodeck_engine(engine)
        sidecar = self._ensure_sidecar(target)
        program_dir = os.path.join(sidecar, _slug(program))
        try:
            os.makedirs(program_dir, exist_ok=True)
        except OSError as exc:
            raise ActionError(502, "could not create the program's room in the "
                                   "holodeck sidecar: %s" % exc)
        sid = uuid.uuid4().hex[:12]
        sess = _HolodeckSession(program=program,
                                engine=(engine or "").strip() or None,
                                mode=mode, sidecar_dir=sidecar,
                                program_dir=program_dir, target_repo=target)
        with self._holodeck_lock:
            self._holodeck[sid] = sess
        if mode == "grounding":
            # The opening grounding pass IS a turn, and must be counted as one.
            # Round 0 ran it without recording it, so the sidecar got two
            # commits both labelled `turn 1` and the first follow-up filed
            # itself under `## Follow-up (turn 1)`.
            sess.turns.append({"text": None, "reply": None})
            return self._run_turn(sid, sess, self._build_holodeck_prompt(
                sess, text=None, opening=True))
        payload = self._holodeck_meta(sid, sess)
        payload.update({"status": "standing-by", "reply": "", "raw": "",
                        "filesChanged": []})
        return payload

    def holodeck_say(self, sid, text, images=None):
        """POST /api/holodeck/<sid>/say — one warm chat turn.

        The FIRST say OPENS the warm worker session (`--session-id <uuid>`);
        every later one RESUMES it (`--resume <uuid>`) and feeds JUST what the
        captain typed — the prior context lives in the session, so the daemon
        re-feeds no transcript (the same economics as the Align grill).
        """
        if images:
            raise ActionError(
                400, "the holodeck cannot take pasted images yet — describe "
                "what you want in words")
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        text = (text or "").strip()
        if not text:
            raise ActionError(400, "missing required field: text")
        opening = not sess.started
        prompt = self._build_holodeck_prompt(sess, text=text, opening=opening)
        sess.turns.append({"text": text, "reply": None})
        return self._run_turn(sid, sess, prompt)

    def holodeck_end(self, sid):
        """POST /api/holodeck/<sid>/end — close the program.

        Drops the in-memory session (and with it the warm worker conversation)
        and STOPS A TURN THAT IS STILL RUNNING — the whole process group, so a
        worker's own children go with it. Round 0 returned `{"ok": true}` while
        the process stayed alive and kept writing into the sidecar of a session
        that no longer existed, and the `/say` that started it hung forever.

        The FILES ARE NOT TOUCHED: they are the captain's design archive, they
        live in his own git repo, and they outlive both the program and this
        daemon (D6). Idempotent-ish: a second end 404s, like a second cancel.

        It also WAITS for a turn it stopped to finish its audit and its commit
        before answering, so the file list `end` prints and the one that turn's
        own reply prints describe the same bytes (D2).
        """
        with self._holodeck_lock:
            sess = self._holodeck.pop(sid, None)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        sess.done = True
        stopped = _kill_process_group(sess.proc)
        # `end` MUST NOT UNDER-REPORT (D2, round 1). A stopped turn does its
        # audit and its commit AFTER the kill lands, so answering immediately
        # printed a confident `files: []` about work that was on disk — and
        # committed — a second later. `end` is the surface a captain who walked
        # away is left with, so it waits for the turn to settle; and when it
        # cannot, it SAYS its list may be short instead of passing an empty one
        # off as the whole truth.
        settled = sess.turn_settled.wait(self._end_settle_timeout())
        payload = self._holodeck_meta(sid, sess)
        payload.update({"status": "ended", "files": list(sess.files_changed),
                        "turns": len(sess.turns), "stoppedTurn": stopped,
                        "filesSettled": settled})
        if not settled:
            payload["warning"] = {
                "kind": "end-audit-pending",
                "message": ("LCARS stopped a turn that was still running and "
                            "its file check had not finished in time, so this "
                            "list may be missing files that turn had already "
                            "written. Nothing is lost — they are on disk in "
                            "the program's room at %s." % sess.program_dir),
            }
        return payload

    # ── the seam itself ────────────────────────────────────────────────────
    def _holodeck_meta(self, sid, sess):
        return {"sessionId": sid, "program": sess.program, "mode": sess.mode,
                "sidecar": sess.sidecar_dir, "programDir": sess.program_dir,
                "engine": sess.engine or self.worker_bin,
                "turnCount": len(sess.turns)}

    @staticmethod
    def _holodeck_args(bin_, mode, session_id, opening, grant_dir):
        """The per-engine holodeck argv (the S124 spike record, as code).

        A COPY of `_session_args`' shape, never a call into it: the grill's warm
        turn is tools-DENIED and must stay byte-identical, and the two postures
        share only the idea of a resumable uuid.
        """
        tools = _HOLODECK_TOOLS[("copilot" if _is_copilot(bin_) else "claude",
                                 mode)]
        if _is_copilot(bin_):
            # copilot is a REAL sandbox: cwd plus `--add-dir` grants, and
            # nothing else. Since `--add-dir` grants WRITE (measured), the ONLY
            # grant is the program's room — and a GROUNDING turn gets none at
            # all, so it structurally cannot write to the captain's project.
            args = [("--session-id=%s" if opening else "--resume=%s")
                    % session_id, "--available-tools", tools]
            args += list(_COPILOT_DISCIPLINE)
            if mode == "design" and grant_dir:
                args += ["--add-dir", grant_dir]
            return args
        # claude: space-form session flags, and NO per-path sandbox exists —
        # `--add-dir` is not a claude flag and is never passed, so WHERE it may
        # write is fenced only by the prompt contract plus the post-turn audit.
        # WHAT it may use is fenced by `--disallowedTools`, which is the half
        # `--allowedTools` cannot do (it only pre-approves).
        args = (["--session-id", session_id] if opening
                else ["--resume", session_id])
        args += ["--allowedTools", tools,
                 "--disallowedTools", _HOLODECK_DENY[("claude", mode)],
                 "--output-format", "text",
                 "--dangerously-skip-permissions"]
        return args

    def _run_turn(self, sid, sess, prompt):
        """Run one turn with the session marked UNSETTLED for its duration.

        The event is the handshake `end` waits on (D2, round 1). `holodeck_end`
        popped the session and built its payload from `sess.files_changed`
        BEFORE the in-flight turn's audit had run, so it answered `files: []`
        about a turn whose own 409 — a second later, about the same bytes —
        correctly reported one file saved and committed.

        Cleared before the turn and set in a `finally`, so EVERY exit path
        (payload, ActionError, unexpected exception) releases it and no `end`
        can be left waiting on a turn that already died.
        """
        sess.turn_settled.clear()
        try:
            return self._holodeck_turn(sid, sess, prompt)
        finally:
            sess.turn_settled.set()

    def _end_settle_timeout(self):
        """How long `end` waits for an in-flight turn's audit + commit to land
        before answering anyway (and saying its list may be short).

        Injectable via `$LCARS_HOLODECK_END_SETTLE_TIMEOUT` (seconds). By the
        time this is waited on, the worker has already been SIGKILLed and all
        that remains is a stat-only walk plus a git commit — so the default is a
        ceiling nobody should reach, not an expected wait.
        """
        raw = os.environ.get("LCARS_HOLODECK_END_SETTLE_TIMEOUT")
        try:
            val = 20.0 if raw in (None, "") else float(raw)
        except ValueError:
            val = 20.0
        return max(0.0, val)

    def _holodeck_turn(self, sid, sess, prompt):
        """Run ONE holodeck turn and shape its response.

        The order matters and is the whole fence: snapshot → spawn → apply any
        fenced-block fallback → snapshot → diff. Everything the payload says
        about files comes from that diff of real bytes on disk.

        A turn that LCARS STOPS — its own timeout, or the captain closing the
        program while it ran — still goes through the audit and still commits
        whatever landed, then ends as an error rather than a spinner.
        """
        bin_ = sess.engine or self.worker_bin
        if not bin_:
            raise ActionError(
                502, "no worker engine configured ($LCARS_WORKER_BIN) — the "
                "holodeck has nothing to talk to")
        opening = not sess.started
        cwd = sess.program_dir if sess.mode == "design" else sess.target_repo
        cmd = ([bin_, "-p", prompt]
               + self._holodeck_args(bin_, sess.mode, sess.worker_sid, opening,
                                     sess.program_dir)
               + ["--model", _holodeck_model(bin_)])
        # THE S72 GUARD, at the one place every holodeck turn passes through.
        _assert_no_bash(cmd)

        # TWO BOUNDS, NOT ONE (D1). The project cap bounds the STRAY check; the
        # sidecar — the program's own room — has its own, so a cap chosen for
        # somebody's monorepo can never truncate the audit of this turn's own
        # output and drop it out of `filesChanged` (and out of the commit).
        cap = self._audit_cap()
        side_cap = self._sidecar_audit_cap()
        before_side, ok_a = _audit_snapshot(sess.sidecar_dir,
                                            max_files=side_cap)
        before_repo, ok_b = _audit_snapshot(sess.target_repo,
                                            skip=[sess.sidecar_dir],
                                            max_files=cap)
        env = dict(os.environ)
        limit = self._turn_timeout()
        try:
            # `start_new_session` puts the worker in its OWN process group, so a
            # timeout or an `end` can take down the worker AND anything it
            # spawned. Without it, killing the worker leaves its children
            # running — and they are what keep writing into the sidecar.
            proc = subprocess.Popen(cmd, cwd=cwd, env=env,
                                    stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT,
                                    start_new_session=True)
        except OSError as exc:
            raise ActionError(502, "the holodeck worker failed to start: %s"
                              % exc)
        # the warm conversation is open from here on, whatever the turn returned
        # — a later turn must RESUME it, never re-open the same uuid.
        sess.started = True
        sess.proc = proc
        timed_out = False
        try:
            out, _err = proc.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            timed_out = True
            _kill_process_group(proc)
            try:
                out, _err = proc.communicate(timeout=15)
            except (subprocess.TimeoutExpired, OSError, ValueError):
                out = b""
        finally:
            sess.proc = None
        raw = (out or b"").decode("utf-8", "replace")
        reply = _clean_reply(raw)

        # A STOPPED TURN IS NOT A TURN. Its stdout is truncated mid-stream, so
        # neither the fenced-block fallback nor the basis is written from it —
        # but whatever it had already put on disk is audited and committed
        # below, because those bytes are the captain's.
        stopped = timed_out or sess.done
        # the fenced-block FALLBACK (a degradation path, not the default), and
        # a DESIGN-mode affordance only: a grounding turn's one output is the
        # basis, so a file block in a read-only reply is not a write channel the
        # daemon should honour.
        blocks, bad_blocks = ([], [])
        if sess.mode == "design" and not stopped:
            blocks, bad_blocks = _parse_file_blocks(raw)
            for rel, content in blocks:
                self._write_block(sess, rel, content)
        # GROUNDING (D12): the worker has NO write tool at all, so the DAEMON
        # writes the basis — and ONLY on the opening pass (see `_write_basis`).
        if sess.mode == "grounding" and reply and not stopped:
            self._write_basis(sess, reply, opening=opening)

        after_side, ok_c = _audit_snapshot(sess.sidecar_dir, max_files=side_cap)
        after_repo, ok_d = _audit_snapshot(sess.target_repo,
                                           skip=[sess.sidecar_dir],
                                           max_files=cap)
        repo_complete = ok_b and ok_d
        side_complete = ok_a and ok_c
        audit_complete = repo_complete and side_complete

        changed = []
        for path, status in _audit_diff(before_side, after_side):
            rel = os.path.relpath(path, sess.sidecar_dir)
            changed.append({"path": rel, "status": status})
            if rel not in sess.files_changed:
                sess.files_changed.append(rel)
        strays = [p for p, _ in _audit_diff(before_repo, after_repo)]

        sess.last_reply = reply
        if sess.turns and sess.turns[-1].get("reply") is None:
            sess.turns[-1]["reply"] = reply

        payload = self._holodeck_meta(sid, sess)
        payload.update({"reply": reply, "raw": raw, "filesChanged": changed,
                        "auditComplete": audit_complete,
                        "exitCode": proc.returncode})
        # A DEGRADED FENCE IS NEVER A SILENT PASS (round 0 shipped
        # `auditComplete: false` as a bare boolean under a normal `status: "ok"`
        # — a state in which a stray write is simply not detected, and nothing
        # said so). It is a first-class, human-legible surface AND a status a
        # consumer that only knows "ok" cannot mistake for a clean turn.
        warning = None if audit_complete else {
            "kind": "audit-incomplete",
            # each walk speaks for ITSELF: the message names the check that
            # actually degraded and claims nothing about the other one.
            "message": _audit_incomplete_message(
                None if repo_complete else cap,
                None if side_complete else side_cap),
        }
        payload["warning"] = warning
        # A STRAY CHANGE OUTRANKS EVERY OTHER OUTCOME. Even a turn that died or
        # said nothing must surface a file that changed in the captain's project.
        if strays or bad_blocks:
            payload["status"] = "refused"
            payload["refused"] = {
                "paths": strays + list(bad_blocks),
                "message": self._write_refused_message(sess, strays, bad_blocks,
                                                       warning),
            }
            self._sidecar_commit(sess, changed)
            return payload
        if stopped:
            # a turn LCARS stopped: keep what landed, then say plainly that the
            # turn did not finish. Never an endless spinner (S125 puts a browser
            # in front of this) and never a silent success.
            self._sidecar_commit(sess, changed)
            raise ActionError(*_stopped_turn_error(bin_, limit, timed_out,
                                                   changed))
        if changed:
            # Work landed. Keep it, whatever the exit code said.
            payload["status"] = "unverified" if warning else "ok"
            self._sidecar_commit(sess, changed)
            return payload
        # Nothing changed and nothing to keep. HOLODECK OFFLINE (D7): lead with
        # what survived, then say what happened. Reporting either of these as
        # success is how a captain waits for a mockup that is never coming.
        if proc.returncode != 0:
            last = (raw.strip().splitlines() or [""])[-1].strip()
            raise ActionError(
                502, "the holodeck worker stopped mid-turn (%s exited %d) — "
                     "your program is safe, every earlier turn is committed, "
                     "and the chat is still running; say it again to retry.%s"
                     % (os.path.basename(bin_), proc.returncode,
                        (" It said: %s" % last) if last else ""))
        if not reply:
            raise ActionError(
                502, "the holodeck worker returned nothing this turn (engine=%s)"
                     " — your program is safe and the chat is still running; "
                     "say it again to retry." % os.path.basename(bin_))
        payload["status"] = "unverified" if warning else "ok"
        return payload

    def _turn_timeout(self):
        """How long ONE holodeck turn may run before LCARS stops it.

        Injectable via `$LCARS_HOLODECK_TURN_TIMEOUT` (seconds). The default is
        deliberately generous: the longest REAL turn measured in the S124 drives
        was 9m49s (a copilot design turn that hit a refusal and retried), so a
        limit near that would kill good work. 20 minutes is "this is not coming
        back", not "this is slow".
        """
        try:
            return max(1.0, float(os.environ.get(
                "LCARS_HOLODECK_TURN_TIMEOUT") or 1200))
        except ValueError:
            return 1200.0

    @staticmethod
    def _write_refused_message(sess, strays, bad_blocks, warning=None):
        """The banner for a turn LCARS could not certify, in LCARS voice (D7).

        Leads with the two questions a person actually has — did I lose my work,
        is it still running — then names the exact paths.

        IT REPORTS, IT DOES NOT ACCUSE. The detection is a before/after walk of
        the whole project across the turn, so it sees a CHANGE, never an author:
        the captain's editor autosaving, a linter, a running dev server, or an
        `npm install` in the very project being designed for all look exactly
        like a worker writing where it shouldn't. Round 0 said "A turn wrote
        outside the holodeck… LCARS did not put them there", which was measured
        false — a control write from a separate shell produced it. Say what
        changed, say what LCARS can and cannot tell, and let the captain judge.

        Nothing is deleted either way: removing files from the captain's real
        project is a bigger hazard than an unwanted one sitting there.
        """
        parts = ["Your program is safe — everything in the holodeck sidecar is "
                 "intact%s."
                 % ("" if sess.done else " and the chat is still running")]
        if strays:
            parts.append(
                "While that turn was running, %d file(s) changed in your "
                "project, outside the holodeck: %s. The holodeck writes only "
                "inside %s, so nothing that changed out there is part of your "
                "program. LCARS watches the files, not who touched them — it "
                "cannot tell whether the holodeck went outside its room or "
                "something else on your machine did (an editor saving, a "
                "linter, a dev server, an install). Nothing has been changed "
                "or removed: take a look and decide."
                % (len(strays), ", ".join(strays), sess.sidecar_dir))
        if bad_blocks:
            parts.append(
                "The turn also asked LCARS to write outside the program's room "
                "(%s); those were refused and nothing was written."
                % ", ".join(bad_blocks))
        if warning:
            parts.append(warning["message"])
        return " ".join(parts)

    def _write_block(self, sess, rel, content):
        """Write ONE fenced fallback block into the program's room.

        Skipped when the file already holds exactly this content, so an engine
        that wrote natively AND echoed the file back does not show up as a
        second, phantom change."""
        path = os.path.join(sess.program_dir, rel)
        real = os.path.realpath(path)
        room = os.path.realpath(sess.program_dir)
        if real != room and not real.startswith(room + os.sep):
            # belt and braces: `_safe_rel` already refused this shape.
            return
        try:
            if os.path.exists(path):
                with open(path) as fh:
                    if fh.read() == content:
                        return
            d = os.path.dirname(path)
            if d:
                os.makedirs(d, exist_ok=True)
            with open(path, "w") as fh:
                fh.write(content)
        except OSError as exc:
            raise ActionError(502, "could not write the mockup file %s: %s"
                              % (rel, exc))

    def _write_basis(self, sess, reply, opening=True):
        """D12 — the DAEMON writes `basis.md` from the OPENING grounding pass.

        Only the opening pass. Round 0 appended EVERY grounding reply, so a
        refusal — real text, no grounding content in it — became a permanent
        `## Follow-up` section of the captain's durable design archive. The
        daemon cannot tell a grounding answer from conversation about one, and a
        classifier that guesses is worse than a rule that doesn't: later turns
        are chat, the captain reads them in the reply, and the archive keeps the
        grounding it was made of. Re-grounding the same program rewrites it (the
        sidecar is a git repo — the previous basis is a commit away).
        """
        if not opening:
            return
        path = os.path.join(sess.program_dir, "basis.md")
        try:
            with open(path, "w") as fh:
                fh.write("# Design basis — %s\n\n"
                         "What the holodeck found by reading %s, read-only. "
                         "Correct anything wrong here: it is what the mockup "
                         "is built from.\n\n%s\n"
                         % (sess.program, sess.target_repo, reply))
        except OSError as exc:
            raise ActionError(502, "could not write the grounding basis: %s"
                              % exc)

    def _resolve_holodeck_engine(self, engine):
        """The CLI a program will run on, resolved BEFORE anything is created.

        A start with no engine (or one that is not on this machine) can never
        run a single turn, so it fails here — with a message that says what to
        do — instead of building a sidecar git repo and a program room and then
        502-ing on the first `say`.
        """
        bin_ = (engine or "").strip() or (self.worker_bin or "").strip()
        if not bin_:
            raise ActionError(
                502, "the holodeck has no worker engine to talk to — no engine "
                "was chosen for this program and the daemon was started "
                "without one ($LCARS_WORKER_BIN). Pick an engine when you open "
                "the program, or restart the viewscreen with one.")
        if not shutil.which(bin_):
            raise ActionError(
                502, "the holodeck cannot run %s — it is not an executable on "
                "this machine. Check the engine you picked, or the daemon's "
                "$LCARS_WORKER_BIN." % bin_)
        return bin_

    def _audit_cap(self):
        """How many files the walk over the CAPTAIN'S PROJECT will look at
        before reporting itself INCOMPLETE. A truncated audit is surfaced
        (`auditComplete: false`), never passed off as a clean one.

        THIS CAP IS THE TARGET REPO'S ALONE (D1, round 1). It exists because a
        captain's project can be tens of thousands of files; feeding it to the
        SIDECAR walk as well meant a low cap silently dropped the turn's OWN
        output from `filesChanged` — and, since `_sidecar_commit` no-ops on an
        empty list, left the captain's mockup uncommitted, under a warning that
        said everything the turn wrote was listed."""
        try:
            return max(1, int(os.environ.get(
                "LCARS_HOLODECK_AUDIT_MAX_FILES") or 20000))
        except ValueError:
            return 20000

    def _sidecar_audit_cap(self):
        """The SEPARATE bound on the walk over the holodeck sidecar.

        The sidecar is the program's own small room — a README and a handful of
        mockups — not the captain's project, so it gets its own knob
        (`$LCARS_HOLODECK_SIDECAR_MAX_FILES`) and a bound set to protect a walk
        over somebody's monorepo can never truncate the audit of the turn's own
        work. A bound remains (an unbounded walk is a hang waiting to happen),
        but when THIS one truncates the captain is told THAT, not the other
        thing."""
        try:
            return max(1, int(os.environ.get(
                "LCARS_HOLODECK_SIDECAR_MAX_FILES") or 20000))
        except ValueError:
            return 20000

    # ── the sidecar ────────────────────────────────────────────────────────
    def _holodeck_root_dir(self, repo):
        """Where sidecars live: `$LCARS_HOLODECK_ROOT` (injected — tests point
        it at a tmpdir) or, by default, BESIDE the target repo, which is where
        the captain already keeps his projects (D6)."""
        root = (self.holodeck_root or "").strip()
        if not root:
            root = os.path.dirname(os.path.abspath(repo.rstrip(os.sep)))
        return os.path.abspath(root)

    def _sidecar_path(self, repo):
        """`<root>/<reponame>-holodeck`, refusing anything that would land
        outside the root (the injected root is a fence too)."""
        root = self._holodeck_root_dir(repo)
        name = os.path.basename(os.path.abspath(repo.rstrip(os.sep)))
        if not name or name in (".", ".."):
            raise ActionError(400, "could not work out a holodeck name for %s"
                              % repo)
        side = os.path.abspath(os.path.join(root, name + "-holodeck"))
        if os.path.dirname(side) != root:
            raise ActionError(500, "refused to put a holodeck sidecar outside "
                                   "%s" % root)
        return side

    def _ensure_sidecar(self, repo):
        """Create the sidecar git repo if it isn't there. IDEMPOTENT: an
        existing sidecar is returned untouched — never re-inited, never
        re-committed over."""
        side = self._sidecar_path(repo)
        try:
            os.makedirs(side, exist_ok=True)
        except OSError as exc:
            raise ActionError(502, "could not create the holodeck sidecar at "
                                   "%s: %s" % (side, exc))
        if os.path.isdir(os.path.join(side, ".git")):
            return side
        readme = os.path.join(side, "README.md")
        try:
            if not os.path.exists(readme):
                with open(readme, "w") as fh:
                    fh.write(
                        "# %s — the holodeck sidecar\n\n"
                        "Design work for `%s`: mockups, concept notes and the "
                        "grounding basis, one directory per program.\n\n"
                        "This is a normal local git repo and it is YOURS. "
                        "Nothing here is shipping code, nothing here is pushed "
                        "anywhere unless you push it, and LCARS never writes "
                        "outside this directory.\n"
                        % (os.path.basename(side), os.path.abspath(repo)))
        except OSError as exc:
            raise ActionError(502, "could not seed the holodeck sidecar: %s"
                              % exc)
        self._git(side, ["init", "-q"], "start the holodeck sidecar's git repo")
        self._git(side, ["add", "-A"], "stage the holodeck sidecar")
        self._git(side, ["commit", "-q", "--no-gpg-sign", "-m",
                         "holodeck: sidecar created"],
                  "make the holodeck sidecar's first commit")
        return side

    def _git(self, cwd, args, what):
        """Run git in `cwd` with an LCARS identity, so a sidecar commit works on
        a machine with no global git identity configured."""
        cmd = [self.git_bin, "-C", cwd,
               "-c", "user.name=LCARS Holodeck",
               "-c", "user.email=holodeck@lcars.local",
               "-c", "commit.gpgsign=false"] + list(args)
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        except OSError as exc:
            raise ActionError(502, "could not %s (is git installed?): %s"
                              % (what, exc))
        if proc.returncode != 0:
            said = (proc.stdout or b"").decode("utf-8", "replace").strip()
            last = said.splitlines()[-1].strip() if said else ""
            raise ActionError(502, "could not %s: %s"
                              % (what, last or "git exited %d"
                                 % proc.returncode))
        return proc

    def _sidecar_commit(self, sess, changed):
        """Commit this turn's files. BEST-EFFORT by design: the captain's design
        work is already on disk, and a git hiccup must never turn a good turn
        into an error. It is what makes "every turn is committed" (D7) true."""
        if not changed:
            return
        try:
            self._git(sess.sidecar_dir, ["add", "-A"], "stage the turn")
            self._git(sess.sidecar_dir,
                      ["commit", "-q", "--no-gpg-sign", "-m",
                       "holodeck(%s): turn %d" % (sess.program,
                                                  max(1, len(sess.turns)))],
                      "commit the turn")
        except ActionError:
            pass

    # ── the turn prompt ────────────────────────────────────────────────────
    def _build_holodeck_prompt(self, sess, text=None, opening=True):
        """Assemble ONE turn's prompt.

        OPENING turn: the full envelope (who you are, where you may write, the
        output contract). CONTINUATION: just what the captain said — the warm
        session already holds the rest, which is the whole cost win."""
        if sess.mode == "grounding":
            if not opening:
                return ("The captain asks: %s\n\nAnswer from what you can READ "
                        "in this repository. You have no write tool; reply in "
                        "markdown." % (text or ""))
            return (
                "You are the LCARS HOLODECK, grounding a new design program "
                "called %r in an EXISTING project.\n\n"
                "Read this repository (your working directory) and report the "
                "design language it ALREADY has: colour tokens with their "
                "actual values, the type scale, spacing and radius, and the "
                "shape of its existing components. Report REAL values you read "
                "in the files — never plausible-looking ones — and name the "
                "file each came from.\n\n"
                "Say what you did NOT find as clearly as what you did (\"no "
                "light theme — the project is dark-only today\"); that half is "
                "often the more useful one.\n\n"
                "You are READ-ONLY: you have no write tool and you must not "
                "attempt to change one byte of this project. Reply with the "
                "basis as markdown — LCARS saves your reply as the program's "
                "basis.md." % sess.program)
        if not opening:
            return ("The captain says: %s\n\nMake the change, then reply in a "
                    "sentence or two saying what you did." % (text or ""))
        return (
            "You are the LCARS HOLODECK: a fast, cheap design room where the "
            "captain talks and you build a mockup as you go. This is a "
            "CONVERSATION, not a harness task — no plans, no tickets, no tests.\n\n"
            "THE PROGRAM: %s\n\n"
            "WHERE YOU WORK: your working directory, %s, is the program's own "
            "room inside the captain's holodeck sidecar. You may create and "
            "edit files THERE and nowhere else. Never write to the project "
            "being designed for, never write anywhere by absolute path, and "
            "never write outside this directory even if asked to — LCARS "
            "audits the filesystem after every turn and shows the captain any "
            "write that escapes.\n\n"
            "WHAT YOU BUILD: `mockup.html` — ONE self-contained HTML file, "
            "inline CSS and JS, no build step and no external dependencies "
            "beyond web fonts. Open it with a short comment saying it is a "
            "VISUAL REFERENCE and not shipping code, with fake internals. "
            "Revise that same file on later turns rather than making a new one.\n\n"
            "IF A WRITE TOOL FAILS you: do not give up the turn. Emit the "
            "COMPLETE file in a fenced block whose info string declares the "
            "path, and LCARS will write it for you:\n"
            "```file:mockup.html\n<!doctype html> ...\n```\n"
            "The path is relative to your working directory. A fence with no "
            "declared path is treated as ordinary markdown and written nowhere.\n\n"
            "REPLY SHORT: a sentence or two on what you changed and what you "
            "want decided next. The captain reads the mockup, not your prose.\n\n"
            "The captain says: %s" % (sess.program, sess.program_dir,
                                      text or "Start us off."))

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

    # -- S139: deploy the LOCAL main HEAD (daemon-owned lifecycle) ---------------
    def deploy_main(self, hint=None):
        """POST /api/deploy/main — deploy the local default-branch HEAD.

        The WEB face of `lcars launch --main` (S138): dispatches
        `lcars launch --main [hint]` BLOCKING — launch.sh resolves the local main
        branch tip (NO fetch, ever), checks it out DETACHED, discovers how to
        start the app, spawns it into its OWN process group, and writes
        `.git/lcars/main/launch.json` (status running|failed) BEFORE returning —
        so on return the terminal state is already on disk. A running record
        carries a numeric `pgid` (== the app pid); we track it under the RESERVED
        key "@main" so the daemon can group-kill the deploy on Stop / shutdown
        (the app is NOT our child).

        Unlike launch(), there is NO mission: NO _require_mission, and NO
        _persisted_worker_bin (the main deploy has no state.json — the skill
        resolves its own engine, so we pass no LCARS_WORKER_BIN). A FAILED deploy
        leaves a readable status=failed record whose message rides the board's
        additive `meta.mainLaunch`, rather than a 502 + stack (UX-33).
        """
        # In-flight guard (mirror launch()): a second POST arriving WHILE the
        # first deploy is still spinning up is an idempotent no-op — return the
        # (now "launching") board WITHOUT a duplicate dispatch. The check-and-add
        # is a SINGLE locked critical section so two threads can't both pass.
        with self._launches_lock:
            if "@main" in self._launching:
                return {"board": self._reader.board()}
            self._launching.add("@main")
        try:
            args = ["--main"]
            h = (hint or "").strip()
            if h:
                args += h.split()
            try:
                self._run("launch", args)
            except ActionError:
                # A discovery/liveness failure exits non-zero AND writes a failed
                # main/launch.json. If that readable record is present, swallow
                # the exit and surface the message via the board; otherwise
                # re-raise (a genuine dispatch error with no record to show).
                if not isinstance(self._read_main_launch_json(), dict):
                    raise
            rec = self._read_main_launch_json()
            if isinstance(rec, dict) and rec.get("status") == "running":
                pgid = rec.get("pgid")
                if isinstance(pgid, int) and pgid > 0:
                    with self._launches_lock:
                        self._launches["@main"] = pgid
            return {"board": self._reader.board()}
        finally:
            with self._launches_lock:
                self._launching.discard("@main")

    def deploy_main_stop(self):
        """POST /api/deploy/main/stop — stop the running main deploy.

        Dispatches `lcars launch --main --stop`, which group-kills the deploy's
        process group and prunes the @main worktree, then drops the "@main" entry
        from the tracking table. Idempotent: a double-stop is a clean no-op (the
        skill's --stop is itself idempotent, and popping an absent key is
        harmless)."""
        try:
            self._run("launch", ["--main", "--stop"])
        finally:
            with self._launches_lock:
                self._launches.pop("@main", None)
        return {"board": self._reader.board()}

    def _read_main_launch_json(self):
        """The local main deploy's launch.json as a dict, or None.

        The main-deploy record lives BESIDE the missions dir — at
        `.git/lcars/main/launch.json` — not under a mission (the analog of
        `_read_launch_json(mid)` for the `--main` target)."""
        p = os.path.join(self.repo_root, ".git", "lcars", "main", "launch.json")
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

    # -- S146: test-readiness config actions (/api/config/*) -------------------
    # Each shells the matching `lcars update` verb — the ONE sanctioned
    # testCommand writer (ADR-002: dispatch, never reimplement config logic in
    # Python). Blocking on purpose: set is instant, probe is bounded by
    # $LCARS_PROBE_TIMEOUT, and fix's discovery worker is a single one-shot
    # turn — the File console's ⚡ FIX shows a busy state while this runs. A
    # non-zero exit surfaces the script's OWN legible report as the error
    # message (plain English on the board, never a stack trace / raw exit code).
    def set_test_command(self, test_command):
        """POST /api/config/test-command — the manual override setter."""
        cmd = (test_command or "").strip()
        if not cmd:
            raise ActionError(400, "an empty test command powers nothing — "
                              "type the exact command that runs this repo's "
                              "suite.")
        return self._config_verb(["--test-command", cmd])

    def probe_tests(self):
        """POST /api/config/probe-tests — one bounded run of the stored
        command. Captain-triggered only; nothing runs it automatically."""
        return self._config_verb(["--probe-tests"])

    def fix_tests(self):
        """POST /api/config/fix-tests — the ONE-CLICK repair: suggest-or-
        discover → set → probe → verdict, all inside one CLI invocation."""
        return self._config_verb(["--fix-tests"])

    def _config_verb(self, args):
        """Shared dispatch for the config verbs: run `update.sh <args>`
        blocking, return {output, board} on success, raise the script's own
        plain-English report on failure."""
        cmd, env = self._resolve_run("update", args, None)
        try:
            proc = subprocess.run(cmd, cwd=self.repo_root, env=env,
                                  stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        except OSError as exc:
            raise ActionError(502, "could not reach the update skill: %s" % exc)
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        if proc.returncode != 0:
            # The verbs print ship-status lines (⚠ SET BUT UNVERIFIED, ✗ REPAIR
            # INCOMPLETE, …) — surface THOSE, verbatim, as the board message.
            raise ActionError(502, out or "the test-systems repair failed with "
                              "no report — check the daemon log.")
        # the fresh board carries the re-verdicted meta.testReadiness (or its
        # absence, when the repair brought the systems online).
        return {"output": out, "board": self._reader.board()}

    def log_preview(self, mid, text=None, images=None, discard_unfiled=False):
        """POST /api/mission/<id>/log — preview the N child bug missions.

        Two modes:
          • text given → AUTHORING preview. Dispatch ONE cold worker turn driving
            the existing lcars-log STEP-1 split over the free-form report; parse
            the authored bug PRDs into a preview list WITHOUT persisting. "File &
            Run Fixes" then dispatches log.sh + resolve-logs (log_run).
          • no text → READ-ONLY preview of the bug missions ALREADY linked to this
            parent (state.json.parentMission == mid). Keeps the S68 behaviour so
            the board can show an already-filed batch with no worker spend.

        R1 — an AUTHORING preview replaces the parent's live session, so it can
        destroy authored text the daemon is the only copy of. `_guard_stranded_
        preview` decides whether it is allowed to; `discard_unfiled` is the
        captain saying "yes, throw the leftover away" on purpose. The read-only
        mode authors nothing and replaces nothing, so it is never guarded.
        """
        self._require_mission(mid)
        text = (text or "").strip()
        if not text:
            children = self._linked_children(mid)
            waiting = self._waiting_children(mid)
            # S163 fix round 3: `children` keeps its S68 meaning (every bug
            # linked to this parent) so nothing that reads it changes; `waiting`
            # is added beside it because this response is ALSO the daemon-restart
            # fallback the "Fix Filed Bugs" review is rebuilt from, and there the
            # panel must be the list `Go ▸` will actually drive.
            return {"children": children, "count": len(children),
                    "parent": mid, "authored": False,
                    "waiting": waiting, "waitingCount": len(waiting)}
        # BEFORE the worker: a refusal that had already spent the ~25s split would
        # be its own version of this defect.
        self._guard_stranded_preview(mid, discard_unfiled)
        return self._log_author(mid, text, images=images)

    def _guard_stranded_preview(self, mid, discard_unfiled=False):
        """Refuse a re-preview that would SILENTLY destroy held authored text (R1).

        The defect: at `partial` the daemon held the authored PRD of a bug that
        never reached disk — the last copy of a ~25s split the captain had already
        paid for — and a brand-new preview replaced the session and dropped it,
        with no warning anywhere. "Discard Unfiled" beside it warned; the door that
        actually lost the text did not.

        So the loss becomes INTENTIONAL instead of incidental, and it is decided
        HERE rather than in the console, because a client can always be bypassed
        (the tester reached this by posting straight at the HTTP API):

          previewed          replace, silently — nothing is stranded. The captain
                             is re-splitting an un-committed report and is paying
                             for that split on purpose; this is the ordinary case
                             and it must not grow a confirmation.
          filed              replace, silently — every authored bug is on disk, so
                             the session holds no text that only exists here.
          partial | failed   REFUSED while any authored bug is still unfiled,
                             naming the bugs at stake and both ways forward (File
                             them, or discard them deliberately). `discard_unfiled`
                             is that deliberate choice arriving, and passes.
          filing             REFUSED outright — the same one refusal `log_discard`
                             makes. A filing thread is mid-flight and settles onto
                             THIS sid; replacing the session now would orphan it and
                             hide the work the parent card is advertising.

        Raises ActionError(409); returns None when the preview may proceed.

        Known narrow window, deliberately left open: the check runs BEFORE the split
        worker (a refusal must not cost a ~25s turn), so a File that turns the same
        parent's session `partial` DURING those seconds is not seen, and the swap in
        `_new_log_session` still replaces it. It needs a File and a Preview racing on
        one parent, and either resolution there loses one of two paid-for splits, so
        closing it is its own design decision rather than a tightening.
        """
        # S163 fix round 3 (D4): a shortfall that survived a restart is text this
        # guard exists to protect, so it must be in memory before we decide.
        self._rehydrate_log_sessions()
        with self._log_lock:
            _sid, sess = self._live_log_session(mid)
            if sess is None:
                return
            if sess.status == "filing":
                raise ActionError(
                    409, "these logged bugs are being filed right now — wait for "
                         "the filing to finish before previewing a new report")
            if sess.status == "previewed" or not sess.unfiled_indices:
                return
            if discard_unfiled:
                return
            titles = [(r.get("title") or "Untitled bug")
                      for r in sess.unfiled_rows()]
        raise ActionError(409, self._stranded_preview_message(titles))

    @staticmethod
    def _stranded_preview_message(titles):
        """Why a re-preview was refused: what is at stake, and both ways out."""
        n = len(titles)
        shown = titles[:3]
        named = ", ".join('"%s"' % t for t in shown)
        if n > len(shown):
            named += " and %d more" % (n - len(shown))
        return ("this mission-log session still holds %d authored bug%s that never "
                "reached disk (%s) — a new preview would throw that text away, and "
                "the split worker that wrote it has already been paid for. File the "
                "%d remaining bug%s to keep %s, or discard the unfiled text "
                "deliberately (\"Discard Unfiled\", or re-send this preview with "
                "discardUnfiled)."
                % (n, "" if n == 1 else "s", named, n, "" if n == 1 else "s",
                   "it" if n == 1 else "them"))

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
        # S161 — the DAEMON now owns these authored PRDs. Mint a session holding
        # them (plus the per-bug refs, the blank steers, and the raw pastes) so a
        # console closed between Preview and File loses NOTHING: reopening restores
        # from `GET .../log/session` and filing needs only the sessionId. Purely
        # ADDITIVE to the response — an older client that ignores `sessionId` still
        # posts the full prds body and takes the unchanged legacy path.
        sid = self._new_log_session(
            parent, prds, children=children, image_refs=explicit,
            overrides=[""] * len(prds), images=images)
        return {"children": children, "count": len(children),
                "parent": parent, "authored": True, "sessionId": sid}

    def _file_children(self, mid, prds, overrides, env_extra, images=None,
                       image_refs=None, output=None):
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

        `output` — pass a LIST to collect log.sh's combined stdout+stderr. D1: the
        script prints its per-bug validation refusals and then exits 0 anyway, so
        those lines are the only place its own reason for filing nothing survives.
        Default None keeps the legacy call sites byte-identical.
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
            proc = self._run("log", args, env_extra=env_extra)
            if output is not None:
                output.append((getattr(proc, "stdout", b"") or b"")
                              .decode("utf-8", "replace"))
        finally:
            for p in tmp + staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        return report

    def log_file(self, mid, prds=None, overrides=None, images=None,
                 image_refs=None, session_id=None):
        """POST /api/mission/<id>/log/file — file authored bugs, return enriched.

        The file-then-review-then-run flow (S74): the captain's confirm step FILES
        the authored bugs (log.sh runs the estimator + persists each child's
        estimate.json + override), and this returns the freshly-filed children with
        their cost/difficulty pills + suggested model mix so the review panel can
        show each bug's estimate and the captain can re-steer before Run Fixes. It
        does NOT dispatch resolve-logs — "Run Fixes" (log_run) does that.

        TWO forms, and they are deliberately different in shape:

        * `session_id` (S161, the one the board uses now) — the authored PRDs are
          already held by the daemon, so the body carries only the sid (plus any
          edited per-bug steers). The file+estimate work is DISPATCHED onto a
          worker thread and this returns PROMPTLY with status "filing"; the
          session then walks to "filed" or "failed" and
          `GET .../log/session` (or the board's `logFiling` stamp) carries it.
        * `prds` in the body (the pre-S161 legacy form) — UNCHANGED and
          byte-identical: it BLOCKS until every child is filed and estimated and
          returns exactly the keys it always did. An older client keeps working.

        Neither form ever dispatches resolve-logs (BUG-059's hold).
        """
        if session_id:
            return self._log_file_session(mid, session_id, overrides=overrides)
        self._require_mission(mid)
        engine = self._persisted_worker_bin(mid)
        env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
        prds = [p for p in (prds or []) if isinstance(p, str) and p.strip()]
        report = self._file_children(mid, prds, overrides, env_extra,
                                     images=images, image_refs=image_refs)
        children, resolved = self._map_override_report(mid, report)
        return {"children": children, "count": len(children),
                "parent": mid, "filed": True, "overrides": resolved}

    def _map_override_report(self, mid, report, children=None, child_ids=None):
        """Map the per-PRD override report onto the freshly-filed child ids.

        Same positional order, so the review panel can echo each resolved steer /
        surface a normalization error (S74 follow-up; never silent-drop). Shared by
        the legacy blocking file path and the S161 session filing thread so the two
        can never drift.

        `children` — pass THIS batch's children to map against those alone.
        Omitted (and no `child_ids`) ⇒ every linked child, the legacy behaviour.
        `child_ids` — the ATTRIBUTED child id per dispatched PRD (or None where the
        bug did not land). The session path passes this: positional indexing into
        "whatever landed" silently mis-attributes a steer as soon as one bug of the
        batch fails, and after a retry the dispatch is a SUBSET of the batch.
        """
        if children is None and child_ids is None:
            children = self._linked_children(mid)
        resolved = []
        for r in (report or []):
            idx = r.get("index")
            if child_ids is not None:
                cid = (child_ids[idx] if (idx is not None
                                          and idx < len(child_ids)) else None)
            else:
                cid = children[idx]["id"] if (idx is not None
                                              and idx < len(children)) else None
            resolved.append({"id": cid, "raw": r.get("raw"),
                             "resolved": r.get("resolved"),
                             "label": r.get("label"), "error": r.get("error")})
        return (children if children is not None else []), resolved

    # ── S161: the daemon-side Mission-Log session ─────────────────────────────
    def _new_log_session(self, parent, prds, children=None, image_refs=None,
                         overrides=None, images=None):
        """Mint a `_LogSession` for `parent` and return its sid.

        ONE live session per parent mission: a fresh authoring preview REPLACES
        the previous one (the captain re-split the report — the old PRDs are the
        ones they just discarded), so the board can never carry two competing
        `logFiling` stamps for the same card.
        """
        sid = uuid.uuid4().hex[:12]
        sess = _LogSession(parent, prds, children=children,
                           image_refs=image_refs, overrides=overrides,
                           images=images)
        with self._log_lock:
            for old, s in list(self._log_sessions.items()):
                if s.parent == parent:
                    del self._log_sessions[old]
                    # R2: remember that THIS sid was the one replaced, so a client
                    # still holding it can be told so truthfully — and an sid we
                    # never saw cannot be told the same story.
                    self._retire_log_session(old, parent, "replaced")
            self._log_sessions[sid] = sess
            # S163: a fresh report against this parent is a NEW batch, so any
            # "the Go for the last one is dispatched" mark is spent. Dropping it
            # here (rather than letting the live session merely out-rank it) keeps
            # ONE answer per parent instead of two competing ones.
            # S163 fix round 6 (D3) — the mark is NO LONGER SPENT HERE.
            #
            # It used to be, and round 3 said why: "a fresh preview spends the
            # mark, so a NEW report re-arms the Go — this closes the repeat, not
            # the road." The round-6 tester measured what that road led to. A
            # parent with two bugs mid-drive, one more bug logged against it,
            # and the Go answered 200 over all three — a SECOND
            # `resolve-logs --parent` racing the first over the same children
            # and the same branch. Logging a report is not evidence that a drive
            # has ended; only the drive ending is. So the record stays, and
            # `_live_log_dispatch` decides when it stops meaning anything.
        # ...and the same for a durable shortfall the replaced session was the
        # only holder of (S163 fix round 3, D4). Reaching here means
        # `_guard_stranded_preview` already made that loss the captain's explicit
        # choice, so the record must not outlive the text it describes.
        self._clear_log_shortfall(parent)
        return sid

    def _retire_log_session(self, sid, parent, reason):
        """Record HOW a session this daemon held ended (R2). Call under the lock.

        The only reason `_missing_log_session_message` can say "replaced" without
        inventing anything. Bounded (oldest entry falls off) — it is a courtesy
        ledger for stale clients, not state anything depends on, so forgetting the
        distant past just degrades a message back to "not one I am holding".

        Deliberately records the reason and NOT which sid superseded this one: the
        message names what is live NOW, which is both the actionable fact and one
        this cannot go stale about.
        """
        self._log_retired[sid] = {"parent": parent, "reason": reason}
        while len(self._log_retired) > _LOG_RETIRED_MAX:
            self._log_retired.pop(next(iter(self._log_retired)))

    def _drop_log_session(self, parent, keep_unfiled=False):
        """Consume (drop) the live session for `parent` — the explicit Go ran.

        Once resolve-logs is driving the batch the authored PRDs are spent: the
        bugs are real Missions on the board with their own cards. Dropping the
        session clears the `logFiling` stamp, so the parent card stops advertising
        a filing that is already history.

        `keep_unfiled` (N1) — EXCEPT when some of the batch never reached disk. The
        Go drives the children that landed; this session is still the only copy of
        the authored text of the ones that did not, so consuming it here would
        destroy exactly what S161 exists to protect. Such a session is kept (its
        status still reads `partial`, which is true) until the captain discards it.
        """
        with self._log_lock:
            for sid, s in list(self._log_sessions.items()):
                if s.parent != parent:
                    continue
                if keep_unfiled and s.prds and s.unfiled_indices:
                    continue
                del self._log_sessions[sid]
                self._retire_log_session(sid, parent, "driven")

    def _mark_log_dispatched(self, parent, sid=None, proc=None):
        """S163 — record that `parent`'s logged-bug Go HAS been dispatched.

        The one fact the parent card cannot derive for itself. Between the Go and
        resolve-logs stamping the children `queued` the board is byte-identical to
        the pre-Go board: filed children, none driven. Without this, a tab
        reloaded in that window would render the "⚙ FIX N FILED BUGS" control
        again and invite a SECOND resolve-logs driver over the same children.

        S163 fix round 1 (D1) — the record is now written to DISK as well as
        held in memory, because in-memory was exactly the failing case. The
        original reasoning ("a restart may drop it; by then the children's own
        `dispatched` flag says the same thing") was wrong on its second clause:
        `local_adapter._card` computes `dispatched = bool(events) or running`,
        and the File & Cost step runs `run.sh estimate` on each bug, whose
        `usage_capture` hook appends a `worker_usage` event to that child. Every
        filed child is `dispatched: True` from birth, so it never distinguished
        anything — and a restarted daemon put the captain straight back in the
        pre-S163 dead end. The tester MEASURED that; see the fix-round tests.

        So the record lives next to the mission it is about
        (`<mission>/log-dispatch.json`, inside `.git/lcars/` where all mission
        state lives and nothing tracks it), and both halves carry the SAME dict
        so memory and disk can never disagree about what was said.

        Known bound, stated rather than hidden: this records the daemon's
        DISPATCH, not resolve-logs' successful boot. A spawn that dies before
        touching a child leaves a record of a batch nothing is driving, and the
        card keeps S77's lock until the captain previews a new report. That is
        the same bound the in-memory mark had within a daemon's life, and it is
        the safe direction — the other way round re-offers a Go over a batch
        that may already be mid-drive.
        """
        # S163 fix round 2 — what `sessionId: null` MEANS, said out loud.
        #
        # The tester read a record with a null sessionId and could not join it to
        # anything, which looks like a dropped field. It is not: a Go taken
        # through the DISK FALLBACK (the daemon restarted, its in-memory session
        # went with it, and the review was rebuilt from the linked children) has
        # no session to name, and inventing one would be worse than the null.
        # So the record states its PROVENANCE instead — the true fact that was
        # missing — and the null stops reading as an omission. Diagnostic only,
        # exactly like `children` below: nothing decides on it.
        rec = {"sessionId": sid, "status": "dispatched",
               "source": "session" if sid else "children",
               "at": _utc_now_iso(),
               # diagnostic, deliberately NOT part of the decision: the control
               # is suppressed by the record's EXISTENCE, never by matching
               # children against it. A batch dispatched, then added to, is
               # still a batch in flight, and re-offering a Go over it is the
               # double-dispatch this record exists to prevent.
               "children": [c["id"] for c in self._linked_children(parent)],
               # S163 fix round 6 (D3) — LOAD-BEARING, unlike `children` above.
               # The child bug missions THIS Go covered, unioned with everything
               # earlier Gos on this parent took. `_waiting_children` subtracts
               # it (so a dispatched bug is never re-offered) and
               # `_live_log_dispatch` measures its stages (so the Go re-arms
               # when the batch reaches its gate, not when a new report
               # arrives). The union is the part that took a tester to find: a
               # second Go for a newly-logged bug used to overwrite the record,
               # and with it the only evidence of what the first Go was driving.
               "dispatched": sorted(
                   self._dispatched_child_ids(parent)
                   | set(c["id"] for c in self._waiting_children(parent)))}
        # S163 fix round 7 (D3) — the field that makes "a drive is running" a
        # question with an answer. Everything else in this record describes what
        # was TRUE AT DISPATCH; a card that claims a drive is in flight is making
        # a claim about NOW, and the round-7 tester found the gap between them:
        # a resolver that exited instantly left a permanently disabled
        # "◐ RESOLVING 3 LOGGED BUGS…" over three bugs nothing was driving, and a
        # 409 whose only advice was to wait for a gate that could never arrive.
        # With the pid on disk a RESTARTED daemon can ask the OS too.
        if proc is not None and getattr(proc, "pid", None):
            rec["pid"] = int(proc.pid)
        with self._log_lock:
            self._log_dispatched[parent] = rec
            if proc is not None:
                self._log_procs[parent] = proc
        try:
            path = self._log_dispatch_path(parent)
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(rec, fh)
            os.replace(tmp, path)
        except OSError:
            # telemetry-grade: a repo we cannot write leaves the in-memory mark
            # doing what it always did. Never fail a dispatch that succeeded.
            pass

    def _resolver_alive(self, rec):
        """`LogFacts._resolver_alive`, but ask the HANDLE first.

        S163 fix round 7 (D3). The resolver is this daemon's own detached child
        and is deliberately never waited on, so once it exits it lingers as a
        zombie and `os.kill(pid, 0)` keeps returning success — the pid check
        that is right for a restarted daemon is exactly wrong for the one that
        did the spawning. `Popen.poll()` reaps and answers truthfully, so the
        board a captain is actually looking at gets the honest reading.

        Falls through to the pid check for a record this daemon did not make
        (it restarted, or a view-only board is reading the same disk).
        """
        # Deliberately NOT taken under `_log_lock` — the same rule, and the same
        # reason, as `_read_log_dispatch` right below: these readers are called
        # BOTH from inside the lock (`_log_dispatch_stamps_locked` marks a stale
        # record while holding it; the Go's guard asks under it) and from
        # outside, and `threading.Lock` is not reentrant. Measured, in a real
        # browser against a real daemon: taking it here wedged `/api/board`
        # permanently the moment a dispatch record existed. Iterating a dict of
        # Popen handles needs no lock to be safe here.
        pid = rec.get("pid") if isinstance(rec, dict) else None
        if pid:
            for proc in list(self._log_procs.values()):
                if getattr(proc, "pid", None) == pid:
                    return proc.poll() is None
        return LogFacts._resolver_alive(self, rec)

    def _read_log_dispatch(self, parent):
        """The dispatch record — this daemon's own memory FIRST, then disk.

        `LogFacts` reads only the file, which is all a view-only board has. A
        write board also holds the record it just made, and `_mark_log_dispatched`
        writes the disk copy best-effort (a repo it cannot write degrades to
        memory, deliberately). Overriding here is what keeps the round-6 readers
        — `_waiting_children` and `_live_log_dispatch`, both defined on the base
        so BOTH boards run the same code — correct on a daemon whose disk write
        failed, without either of them knowing there are two stores.

        Deliberately NOT taken under `_log_lock`: these readers are called from
        inside the lock (the Go's guard) and from outside it (every board
        build), and `dict.get` needs no lock to be safe here.
        """
        rec = self._log_dispatched.get(parent)
        if isinstance(rec, dict) and rec.get("status") == "dispatched":
            return rec
        return LogFacts._read_log_dispatch(self, parent)

    def _log_dispatch_stamps(self):
        """{parent id -> the `logDispatch` stamp} for every dispatched batch.

        Memory first, then the durable records on disk (S163 fix round 1 — the
        stamp has to survive the restart it exists to describe). They carry the
        same dict, so the merge order only matters for a record this daemon has
        already rewritten.

        A parent holding a NEWER live session is excluded — from BOTH sources:
        that session is the more recent, more detailed fact, and it is what lets
        a captain log a new report against a parent whose last batch was
        dispatched (the fresh preview outranks the old record without erasing
        it).

        S163 fix round 3 (D3) — "newer" is the whole correction. The rule used to
        be "any live session at all", and the Go on a PARTIAL deliberately KEEPS
        its session (N1: it holds the only copy of the unfiled bug's authored
        text). So the retained session hid the mark of the Go that had just
        consumed it: the card went on offering "⚙ FIX 1 OF 2 FILED BUGS" while
        resolve-logs was already driving the batch, and a restarted daemon —
        same disk, no memory — read "◐ resolving 1 logged bug…". One repo state,
        two answers, decided by how long the daemon had been up.

        The record already names the session it consumed, so the comparison is
        exact: a live session whose sid IS the recorded one is that consumed
        session and the dispatch wins; any other session is a genuinely new batch
        and outranks the record as before. (A record whose `sessionId` is null
        came from the disk-fallback Go and has no session to match, so any live
        session is by definition newer — the old behaviour, unchanged.)
        """
        with self._log_lock:
            return self._log_dispatch_stamps_locked()

    def _log_dispatch_stamps_locked(self):
        """`_log_dispatch_stamps` with `_log_lock` ALREADY HELD.

        S163 fix round 4 (D2) — the split exists so the Go's refusal can be
        decided inside the same lock acquisition that claims the dispatch.
        `threading.Lock` is not reentrant, so a guard that called the public
        method under the lock would deadlock; and a guard that called it OUTSIDE
        the lock is check-then-act, which is the defect: five simultaneous Gos
        all passed the check and spawned five resolve-logs drivers over the same
        parent (staggered by 100 ms it was correct, which is how it survived a
        round). The disk read stays inside — it is a listdir over the mission
        dirs the board already stats, and correctness outranks lock duration on
        a path taken once per batch.
        """
        live = dict((s.parent, sid)
                    for sid, s in self._log_sessions.items())
        marks = dict((p, dict(v)) for p, v in self._log_dispatched.items())
        for parent, rec in self._disk_log_dispatches().items():
            marks.setdefault(parent, rec)
        out = {}
        for p, v in marks.items():
            if p not in live or (v.get("sessionId") is not None
                                 and v.get("sessionId") == live[p]):
                out[p] = v
            elif self._live_log_dispatch(p) is not None:
                # S163 fix round 6 (D3) — a LIVE drive out-ranks any session.
                #
                # "A newer session is the more recent, more detailed fact" holds
                # for a batch that has finished; it is false while resolve-logs
                # is still working. The tester logged a bug against a parent
                # mid-drive and the fresh preview hid the mark, so the card
                # re-offered "⚙ FIX N FILED BUGS" over bugs already being
                # driven and the Go spawned a second driver. A settled record
                # still yields to the new session exactly as it did — this
                # clause only ever fires while a drive is genuinely on.
                out[p] = v
        # S163 fix round 7 (D3): say, on the stamp, whether the drive it records
        # is still there. The client renders `◐ RESOLVING N…` off this stamp's
        # mere presence, so without the flag the card asserts a running drive on
        # the strength of a record — a claim about the past standing in for a
        # claim about the present, which is exactly what the tester caught.
        for p, v in out.items():
            if self._log_dispatch_is_stale(p, v):
                v["stale"] = True
        return out

    # ── S163 fix round 3 (D4) — the DURABLE SHORTFALL ────────────────────────
    # (its path + the disk reader live on `LogFacts`, the base a view-only board
    # runs too — S163 fix round 4 D3.)
    def _write_log_shortfall(self, sid, sess, before=None):
        """Persist (or clear) `sess`'s shortfall beside its parent mission.

        Written whenever a settled batch left authored text un-filed; DELETED the
        moment nothing is missing, so a completed retry cannot leave a stale
        record telling a restarted daemon a bug is still owed.

        What goes in is the minimum a restart needs to keep S161's promise:
          bugCount / filedCount   the two numbers the card says ("1 of 2")
          filed                   {authored index -> child id}, so the counts can
                                  be rebuilt without guessing which slots landed
          unfiled                 the authored ROWS — title + full PRD text —
                                  i.e. the ~25s split the captain already paid
                                  for, which is the whole point
          sessionId               the ORIGINAL sid, so the rehydrated session is
                                  the same session by name. That is what keeps
                                  `_log_dispatch_stamps`' "is this the session my
                                  Go consumed?" comparison working across a
                                  restart (D3) instead of re-opening the review.

        S163 fix round 4 (D4) — WRITTEN WHEN THE FILING STARTS TOO, not only
        when it settles. The tester `kill -9`'d the daemon 8 s into a 2-bug
        filing and restarted: with nothing on disk yet, the restarted daemon
        could only count the children it happened to find, so a 2-bug report
        rendered as a settled `⚙ FIX 1 FILED BUG` — and a Go in that window
        would have dispatched the batch with the second bug's cost review never
        shown, which is the one thing this session exists to prevent. So the
        fact "a filing of N bugs started" is recorded BEFORE it starts (status
        `filing`), with `before` — the linked children that already existed —
        so a restarted daemon can MEASURE what the orphaned log.sh landed
        afterwards rather than infer completeness.

        Never raises: a repo we cannot write degrades to the pre-S163 behaviour
        (memory only), which is what it always did.
        """
        path = self._log_shortfall_path(sess.parent)
        if not sess.unfiled_indices or not sess.prds:
            try:
                os.unlink(path)
            except OSError:
                pass
            return
        rec = {"parent": sess.parent, "sessionId": sid, "status": sess.status,
               "bugCount": sess.bug_count, "filedCount": sess.filed_count,
               "error": sess.error, "at": _utc_now_iso(),
               "filed": dict((str(i), c)
                             for i, c in enumerate(sess.filed_map) if c),
               "unfiled": sess.unfiled_rows()}
        # Only meaningful while the record says `filing`; carried then so the
        # reconciliation after a restart is the SAME before/after delta the
        # filing itself measures (`_log_file_worker`), never a title guess over
        # every child the parent has ever had.
        if before is not None:
            rec["before"] = sorted(before)
            # ...and say so in a word, because after the first reconciliation the
            # status is `partial`/`failed` and `status == "filing"` would no
            # longer identify it. One flag, one meaning: this filing has no
            # daemon behind it and its outcome is still being measured.
            rec["interrupted"] = True
        try:
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(rec, fh)
            os.replace(tmp, path)
        except OSError:
            pass

    def _clear_log_shortfall(self, parent):
        try:
            os.unlink(self._log_shortfall_path(parent))
        except OSError:
            pass

    def _rehydrate_log_sessions(self):
        """Read the durable filing records back into `_log_sessions`. Once.

        The narrowness is deliberate and worth stating, because the next session
        will be tempted to read this as durable-sessions-v2: what comes back is a
        session that holds the SHORTFALL and nothing else — the unfiled bugs'
        text in their original authored slots, the ids of the ones that landed,
        the status and the error. No images, no per-bug steers, no PRDs of the
        bugs that filed. It exists so that after a restart the card can still say
        "1 of 2 filed", the console can still show the words the split worker
        wrote, and File can still retry exactly the missing bug — which is the
        promise S161 made and the ruling that sent it to disk.

        S163 fix round 4 (D4) — a record still reading `filing` is a filing this
        daemon did NOT do and cannot finish: the process that was doing it is
        gone. Such a record is RECONCILED against disk on the way in (below) and
        then settled to `partial`/`failed` with an error that says the filing was
        interrupted, so it can never re-read as a clean, complete batch.
        """
        if self._log_rehydrated:
            return
        # set FIRST: a scan that raises must not re-run on every board build.
        self._log_rehydrated = True
        for parent, rec in self._disk_log_shortfalls().items():
            sid, sess = _session_from_log_record(rec)
            if sess is None:
                continue
            with self._log_lock:
                if any(s.parent == parent for s in self._log_sessions.values()):
                    continue          # this daemon already holds a live one
                self._log_sessions[sid] = sess
            if sess.interrupted:
                self._reconcile_interrupted(sid, sess)

    def _reconcile_interrupted(self, sid, sess):
        """Settle an INTERRUPTED filing against what is actually on disk (D4).

        The orphaned `log.sh` outlives the daemon that spawned it — the tester
        measured the second bug landing 35 s after the restart — so "what did
        that filing achieve?" is a question only disk can answer, and it answers
        it differently as time passes. This is the SAME measurement
        `_log_file_worker` takes at the end of a filing it owned: everything
        linked to the parent that was not there when the filing started is what
        this filing landed, and `_attribute_landed` says which authored bug each
        one is (title first, then positionally).

        Bounded by construction: it runs only while a session carries
        `interrupted` AND still has unfiled bugs, and the moment the last one is
        accounted for the record is deleted and the session settles `filed` —
        which is what stops a retry from duplicating a bug that simply arrived
        late.
        """
        with self._log_lock:
            if not sess.interrupted or not sess.unfiled_indices:
                return
            before = sess.before_ids or set()
            pending = list(sess.unfiled_indices)
            prds = [sess.prds[i] for i in pending]
            claimed = set(sess.filed_ids)
        landed = [c for c in self._linked_children(sess.parent)
                  if c["id"] not in before and c["id"] not in claimed]
        attributed = self._attribute_landed(pending, prds, landed)
        with self._log_lock:
            for i, cid in attributed.items():
                while len(sess.filed_map) <= i:
                    sess.filed_map.append(None)
                sess.filed_map[i] = cid
            if not sess.unfiled_indices:
                sess.status, sess.error = "filed", None
                sess.interrupted = False
            else:
                sess.status = "partial" if sess.filed_ids else "failed"
                sess.error = _INTERRUPTED_FILING_COPY % (
                    sess.filed_count, sess.bug_count,
                    "" if sess.bug_count == 1 else "s",
                    sess.unfiled_count,
                    "is" if sess.unfiled_count == 1 else "are")
        # Outside the lock (file I/O). A batch the orphan completed clears the
        # record; one it did not rewrites it with the reconciled truth — still
        # carrying `before`, so a SECOND restart re-measures rather than
        # freezing today's answer into the file.
        self._write_log_shortfall(
            sid, sess, before=(sess.before_ids if sess.interrupted else None))
        if not sess.interrupted and not sess.unfiled_indices:
            # nothing is owed: the session has no story left to tell, and
            # leaving it would keep a `filed` stamp on a card whose children
            # already say the same thing.
            with self._log_lock:
                if self._log_sessions.get(sid) is sess:
                    del self._log_sessions[sid]

    def _log_file_session(self, mid, sid, overrides=None):
        """File the bugs a `_LogSession` holds that are NOT on disk yet.

        The estimator runs once per child inside log.sh, which is the long step
        (BUG-G's lesson on the run side). Holding the POST for it is what made the
        console feel like a trap, so the work goes onto a daemon thread and the
        POST returns the accepted "filing" status immediately. Re-posting while a
        dispatch is already in flight is an IDEMPOTENT no-op — never a second
        log.sh (that would duplicate every bug child and re-spend the estimator).

        ONE RULE decides what a File does (N1): it dispatches exactly the authored
        bugs that are not on disk. From `previewed`/`failed` that is all of them;
        from `partial` it is the missing ones ONLY — so a shortfall is RETRYABLE
        rather than a dead end, and the children that already landed can never be
        duplicated. Nothing left to file ⇒ a refusal, because the next step from a
        complete batch is the captain's Go.
        """
        self._require_mission(mid)
        # S163 fix round 3 (D4): a retry may be the FIRST thing a restarted
        # daemon is asked to do (the console got its sid from /log/session).
        self._rehydrate_log_sessions()
        with self._log_lock:
            sess = self._log_sessions.get(sid)
            if sess is None:
                # D4: say only what is KNOWN. The old copy blamed a daemon restart
                # for every miss, which was flatly false for the common case — a
                # second Preview REPLACES the session, so the console's old sid is
                # stale while the daemon has been up the whole time.
                raise ActionError(404, self._missing_log_session_message(mid, sid))
            if sess.parent != mid:
                raise ActionError(
                    409, "mission-log session %s belongs to %s, not %s"
                    % (sid, sess.parent, mid))
            # The captain may have edited the per-bug steers in the console since
            # the preview; those ride the file POST and land on the session — but
            # ONLY when the list is parallel to the authored batch. At `partial` the
            # console's steer inputs are indexed by the children that LANDED, so
            # adopting such a list would silently move a steer onto another bug.
            if isinstance(overrides, list) and len(overrides) == len(sess.prds):
                sess.overrides = [o if isinstance(o, str) else ""
                                  for o in overrides]
            if sess.status == "filing":
                return self._log_dispatch_payload(mid, sid, sess)
            if not sess.prds:
                raise ActionError(
                    400, "this mission-log session holds no authored bug PRDs "
                         "to file")
            pending = sess.unfiled_indices
            if not pending:
                # every authored bug is on disk. Re-running log.sh over them would
                # duplicate every child and re-spend the estimator.
                raise ActionError(
                    409, "these logged bugs are already filed — the next step is "
                         "the captain's Go")
            sess.status = "filing"
            sess.error = None
            # S163 fix round 4 (D4): a retry re-arms the measurement. Whatever
            # an earlier interrupted pass concluded, THIS pass is one this daemon
            # owns and will settle itself.
            sess.interrupted = False
            sess.before_ids = None
            args = (mid, sid) + self._log_pass_args(sess, pending)
            # snapshot the response BEFORE the thread can move the status, so the
            # POST always reports the dispatch it just accepted (never a racy
            # "filed" that depends on how fast log.sh happened to be).
            payload = self._log_dispatch_payload(mid, sid, sess)
        # S163 fix round 4 (D4) — RECORD THE START, then start. The snapshot of
        # what is already linked to the parent is taken here, once, and handed to
        # BOTH the durable record and the worker, so "what did this filing land?"
        # is the same question with the same baseline whether it is answered by
        # the daemon that ran it or by one that booted afterwards.
        before = set(c["id"] for c in self._linked_children(mid))
        self._write_log_shortfall(sid, sess, before=before)
        threading.Thread(target=self._log_file_worker, args=args + (before,),
                         daemon=True).start()
        return payload

    @staticmethod
    def _log_pass_args(sess, pending):
        """The (indices, prds, overrides, image_refs, images) for ONE filing pass.

        A FIRST pass covers the whole batch, and hands the session's images and
        per-bug refs over VERBATIM so the log.sh argv is exactly what the legacy
        prds-in-body dispatch builds.

        A RETRY covers a SUBSET, which means the images have to be re-routed as
        well: `_route_images` treats an image referenced by none of the bugs it is
        given as ORPHANED and attaches it to every one of them, so an image tied
        only to an already-filed bug would otherwise land on the retried ones. We
        resolve each retried bug's FINAL image set (explicit ∪ orphaned — the one
        routing formula) from the ORIGINAL refs, keep only those images, renumber
        them, and hand each bug its own set explicitly. Same attachments per bug,
        nothing borrowed from a bug that is not in this pass.
        """
        idx = list(pending)
        prds = [sess.prds[i] for i in idx]
        steers = [sess.overrides[i] if i < len(sess.overrides) else ""
                  for i in idx]
        if len(idx) == len(sess.prds):
            return idx, prds, steers, list(sess.image_refs), list(sess.images)
        refs = [(sess.image_refs[i] if i < len(sess.image_refs) else None)
                for i in range(len(sess.prds))]
        _orphaned, _explicit, union = _route_images(refs, len(sess.images))
        keep = sorted(set(k for i in idx for k in union[i]))
        pos = dict((k, j + 1) for j, k in enumerate(keep))
        return (idx, prds, steers,
                [[pos[k] for k in union[i]] for i in idx],
                [sess.images[k - 1] for k in keep])

    @staticmethod
    def _log_dispatch_payload(mid, sid, sess):
        """The accepted-dispatch response for a file-by-sessionId POST.

        No `count` (N2): a key that means "authored bugs" here and "filed children"
        on the next response is the lie itself. The three self-describing counts —
        and `unfiled`, the authored text of what is still missing — are the payload.
        """
        return {"sessionId": sid, "parent": mid, "status": sess.status,
                "authored": True, "filed": False,
                "children": [dict(c) for c in sess.children],
                "bugCount": sess.bug_count, "filedCount": sess.filed_count,
                "unfiled": sess.unfiled_rows(),
                "unfiledCount": sess.unfiled_count}

    @staticmethod
    def _attribute_landed(indices, prds, landed):
        """{authored index -> child id} for the bugs this pass put on disk.

        The measured delta says HOW MANY landed; this says WHICH — the difference
        between reporting a shortfall and being able to hand back the right bug's
        authored text (N1), and between echoing a steer on the right child and the
        wrong one.

        Title first: log.sh derives each child's title from its PRD's `# Mission:`
        line (`_prd_title` reads the same line), so that is a real identity, not a
        guess. Whatever is left over is then filled in POSITIONALLY, so the
        attribution always accounts for every landed child and can never contradict
        `filedCount` — a title the script rewrote degrades the choice of which bug
        is unfiled, never the count of what exists.
        """
        remaining = list(landed)
        out = {}
        for pos, i in enumerate(indices):
            title = _prd_title(prds[pos]) if pos < len(prds) else None
            if not title:
                continue
            for c in remaining:
                if (c.get("title") or "") == title:
                    out[i] = c["id"]
                    remaining.remove(c)
                    break
        for i in indices:
            if i in out or not remaining:
                continue
            out[i] = remaining.pop(0)["id"]
        return out

    def _log_file_worker(self, mid, sid, indices, prds, overrides, image_refs,
                         images, before=None):
        """The dispatched filing: log.sh per bug (estimator included), then mark.

        BUG-059's HOLD LIVES HERE: this NEVER dispatches resolve-logs. Reaching
        "filed" is the end of the road until the captain's explicit Go posts to
        /log/run.

        D1 — THE STATUS IS A MEASUREMENT, NOT A REPORT. `log.sh` cannot be trusted
        to tell us whether it worked: `file_one_bug` runs inside a command
        substitution, so its `die` exits the SUBSHELL and the batch still ends
        `exit 0` having filed nothing (it even prints ``Run `lcars run ` to begin``
        with an EMPTY id). So we do not ask the script — we count the linked bug
        children on disk BEFORE and AFTER, and the delta decides:

            every authored bug landed → filed
            some landed               → partial   (NEVER `filed`)
            none landed               → failed

        A non-zero exit is folded into the SAME check, because a script that dies
        halfway has still put children on disk. Whatever we end up saying, a human
        reading the status is never misled about what exists.

        `indices` are the AUTHORED positions this pass is filing (all of them on a
        first pass; only the missing ones on a retry — N1), so what landed is
        attributed back onto the session's `filed_map` and the status is recomputed
        for the WHOLE batch: a retry that fills the last gap reads `filed`.
        """
        engine = self._persisted_worker_bin(mid)
        env_extra = {"LCARS_WORKER_BIN": engine} if engine else None
        # S163 fix round 4 (D4): the caller took this snapshot when it wrote the
        # in-flight record, so the durable baseline and this one are the same
        # measurement. Re-taken here only for a direct call with none supplied.
        if before is None:
            before = set(c["id"] for c in self._linked_children(mid))
        said = []
        report, fault = [], None
        try:
            report = self._file_children(mid, prds, overrides, env_extra,
                                         images=images, image_refs=image_refs,
                                         output=said)
        except ActionError as exc:
            fault = exc.message
        except Exception as exc:   # never leak a traceback into the console
            fault = "filing the logged bugs failed: %s" % exc
        # ── the post-condition check ─────────────────────────────────────────
        landed = [c for c in self._linked_children(mid)
                  if c["id"] not in before]
        attributed = self._attribute_landed(indices, prds, landed)
        try:
            _c, resolved = self._map_override_report(
                mid, report,
                child_ids=[attributed.get(i) for i in indices])
        except Exception:
            resolved = []
        self._settle_log_session(sid, attributed, resolved, said, fault)

    def _settle_log_session(self, sid, attributed, resolved, said, fault):
        """Merge ONE filing pass into the session and re-measure its status.

        The status describes the WHOLE batch, never one pass: after a retry that
        files the last missing bug the session reads `filed`, and after one that
        files none of them it stays `partial` with the shortfall restated. The
        per-bug steer report is merged by child id, so an earlier pass's entries
        survive a retry instead of being replaced by the subset's.
        """
        with self._log_lock:
            sess = self._log_sessions.get(sid)
            if sess is None:
                return
            for i, cid in attributed.items():
                while len(sess.filed_map) <= i:
                    sess.filed_map.append(None)
                sess.filed_map[i] = cid
            if resolved:
                fresh = set(r.get("id") for r in resolved if r.get("id"))
                sess.overrides_report = [
                    r for r in sess.overrides_report if r.get("id") not in fresh
                ] + list(resolved)
            filed = sess.filed_ids
            if not sess.unfiled_indices:
                sess.status, sess.error = "filed", None
            else:
                sess.status = "partial" if filed else "failed"
                sess.error = self._log_shortfall_message(sess.bug_count, filed,
                                                        said, fault)
        # S163 fix round 3 (D4): the settled shortfall goes to DISK, outside the
        # lock (it is file I/O). Written here rather than at the call sites so
        # every path that can settle a session — first pass, retry, the retry
        # that completes the batch — updates (or clears) the record by
        # construction. `_write_log_shortfall` deletes it when nothing is
        # missing, so a completed batch leaves no stale claim behind.
        self._write_log_shortfall(sid, sess)

    @staticmethod
    def _log_shortfall_message(want, filed_ids, said, fault):
        """Plain English for a batch that did not fully land (D1 + N1).

        Names the shortfall FIRST — how many were asked for, how many are on disk,
        and which ones — then says the missing bugs' authored text is STILL HELD
        (round 1 sent the captain off to "log the ones that failed as a new report",
        which meant retyping a bug and paying for a second split worker, and it said
        so while quietly discarding that very text), then appends whatever reason the
        script itself gave, since that is the only place a swallowed `die` survives.
        Never a stack trace.
        """
        if filed_ids:
            head = ("only %d of %d authored bug%s filed (%s) — %d did not reach "
                    "disk; their authored text is still held, so File again "
                    "retries just those (no second split)"
                    % (len(filed_ids), want, "" if want == 1 else "s",
                       ", ".join(filed_ids), want - len(filed_ids)))
        else:
            head = ("nothing was filed — none of the %d authored bug%s reached "
                    "disk; the authored text is still held, so File again retries "
                    "them (no second split)" % (want, "" if want == 1 else "s"))
        reason = Actions._log_fault_reason(said, fault)
        return "%s. %s" % (head, reason) if reason else head + "."

    @staticmethod
    def _log_fault_reason(said, fault):
        """The script's OWN words for why, from its combined output (D1).

        log.sh's swallowed refusals are printed, not returned, so its stdout+stderr
        is the only witness. Prefer its `lcars log:` / `log.sh:` lines, then a
        non-zero exit's message, then the last thing it said at all.
        """
        blob = "\n".join([s for s in (said or []) if s])
        lines = [ln.strip() for ln in blob.splitlines() if ln.strip()]
        spoke = [ln for ln in lines
                 if ln.startswith("lcars log:") or ln.startswith("log.sh:")]
        if spoke:
            return " ".join(spoke[:3])
        if fault:
            return fault
        return lines[-1] if lines else ""

    def _missing_log_session_message(self, mid, sid):
        """Why a sid is unknown — told apart, not guessed (D4, then R2).

        Call under `_log_lock` (it reads `_live_log_session` + `_log_retired`).

        D4 killed the invented "the daemon was restarted". R2 is the SAME class one
        door along: with a live session for the parent, EVERY unknown sid was told
        it "was replaced by a newer preview" — including a sid that never existed,
        which the daemon cannot possibly know was replaced (the tester posted
        `deadbeefcafe` and was told a story about it). A reason is only stated when
        the retirement ledger actually recorded it:

          in the ledger      say how it ended — replaced / discarded / consumed by
                             the Go. Knowable, because we wrote it down.
          not in the ledger  say only that it is not a session we hold, plus what
                             IS live (or that nothing is). No reason offered.

        Either way the remedy follows from what is true, which is the part D4 got
        right and this keeps.
        """
        live_sid, live = self._live_log_session(mid)
        known = self._log_retired.get(sid)
        if known is not None and known.get("parent") != mid:
            known = None          # a sid from another parent's flow proves nothing
        if live is not None:
            tail = (" — the live one for %s is %s; reopen the Mission Log to pick "
                    "up the current one" % (mid, live_sid))
        else:
            tail = (" — nothing is being held for %s now; preview the report again"
                    % mid)
        if known is not None:
            how = _LOG_RETIRED_COPY.get(known.get("reason"),
                                        "is no longer being held")
            return "mission-log session %s %s%s" % (sid, how, tail)
        if live is not None:
            return ("mission-log session %s is not one this daemon is holding%s"
                    % (sid, tail))
        return ("no live mission-log session %s for %s — nothing is being held "
                "for it; preview the report again" % (sid, mid))

    def log_discard(self, mid):
        """POST /api/mission/<id>/log/discard — throw away a live log session.

        D3 — Align's `POST /api/align/<sid>/cancel` parity for the Mission Log. A
        previewed-then-abandoned session used to stamp `logFiling` on the parent
        card until the daemon restarted, with no way to clear it; once S162 renders
        that stamp as a band, an abandoned preview would read as a filing
        permanently in flight. So the console dismisses its session explicitly.

        IDEMPOTENT and never a 404 (Align answers 200 for a bogus sid too), so a
        stale card can always clear itself — including for a mission that no longer
        exists. Dispatches nothing and touches no filed work: it drops a session,
        not the bug missions a session already put on disk.

        A `partial` is discardable too (N1) — that is how the captain says "I am
        done with the leftover". It is the only way to clear the card once the Go
        has driven what landed, since the Go deliberately KEEPS a session that still
        holds unfiled authored text. The console labels that dismissal for what it
        destroys ("Discard Unfiled"), because it is the last copy of those words.

        The ONE refusal: while a filing is actually IN FLIGHT, since clearing the
        band then would hide the very thing the band exists to show.
        """
        self._rehydrate_log_sessions()
        with self._log_lock:
            sid, sess = self._live_log_session(mid)
            if sess is not None and sess.status == "filing":
                raise ActionError(
                    409, "these logged bugs are being filed right now — wait for "
                         "the filing to finish before discarding it")
            if sid is not None:
                del self._log_sessions[sid]
                self._retire_log_session(sid, mid, "discarded")
        # S163 fix round 3 (D4): "I am done with the leftover" has to reach DISK
        # too, or the next restart would rehydrate the shortfall the captain just
        # threw away and the card would resurrect a note about it.
        self._clear_log_shortfall(mid)
        return {"parent": mid, "sessionId": sid, "status": "discarded"}

    def log_session_state(self, mid):
        """GET /api/mission/<id>/log/session — restore a reopened console.

        Mirrors `align_state`: the captain backgrounded the Mission-Log console,
        and this hands back EXACTLY what they left — the authored bugs while the
        session is `previewed`/`filing`/`failed`, and the children that actually
        landed, with their estimate pills, once it is `filed`/`partial`. Read-only:
        it dispatches nothing.

        A mission with no live session 404s (the console then opens fresh).
        `filed` is reported ONLY when the post-condition check found every authored
        bug on disk — a mid-flight session reads `filing`, and a short one reads
        `partial` (with `filed: false`), never `filed` (D1).

        Counts (D2 + N2): `bugCount` = how many bugs the batch is, `filedCount` =
        how many of them are on disk, `unfiledCount` = how many are not — three
        names, three meanings, the first two identical to what the board stamp
        publishes, so the card and the console can never contradict each other.
        S163 fix round 3 adds a FOURTH, deliberately named apart from all of
        them: `waitingCount` = how many bugs are waiting to be fixed on this
        MISSION, across every report. That is the review panel's length and the
        card's count; the batch's own three are untouched, so a shortfall is
        still told exactly as it was.
        There is NO `count`: it equalled `bugCount` at four statuses and
        `filedCount` at `partial` (because `children` itself changes meaning once
        only part of a batch lands), and one key that means two things IS the defect.
        `/log/session` is new in S161, so nothing depended on it — the pre-S161
        `/log` and `/log/file` payloads keep their own `count` untouched.

        `unfiled` (N1) — the authored rows, WITH their full PRD text, of every bug
        that is not on disk. Present at every status and always meaning that one
        thing. This is what makes a shortfall recoverable: the split worker's words
        for the bug that failed are still here, so the console can show them and
        File can retry just those, instead of the captain retyping the bug and
        paying for a second ~25s split.
        """
        self._require_mission(mid)
        # S163 fix round 3 (D4): a restarted daemon still has a shortfall to
        # report — read the durable records back before deciding there is no
        # session (idempotent, and a no-op after the first call).
        self._rehydrate_log_sessions()
        with self._log_lock:
            sid, sess = self._live_log_session(mid)
            if sess is None:
                raise ActionError(404, "no mission-log session for %s" % mid)
            status, error = sess.status, sess.error
            children = [dict(c) for c in sess.children]
            report = list(sess.overrides_report)
            steers = list(sess.overrides)
            bug_count, filed_ids = sess.bug_count, list(sess.filed_ids)
            unfiled = sess.unfiled_rows()
        # S163 fix round 3 — THE REVIEW IS THE MISSION, NOT THE BATCH. Present at
        # EVERY status, always meaning the one thing: the bugs on this mission
        # still waiting to be fixed, which is exactly what `Go ▸` will drive
        # (see `_waiting_children`). Carried alongside the authoring payload too,
        # because a second report being authored must not HIDE the bugs an
        # earlier one already put on disk — D1: the captain clicked "⚙ FIX 2
        # FILED BUGS" and landed in a failed session's console with no pills, no
        # steer boxes and a Go that could only refuse, whose only exit destroyed
        # the unfiled text. Both facts are real; neither may erase the other.
        waiting = self._waiting_children(mid)
        counts = {"bugCount": bug_count, "filedCount": len(filed_ids),
                  "unfiled": unfiled, "unfiledCount": len(unfiled),
                  "waiting": waiting, "waitingCount": len(waiting)}
        if status in ("filed", "partial"):
            out = {"sessionId": sid, "parent": mid, "status": status,
                   "authored": False, "filed": status == "filed",
                   # the review list IS the waiting list here — at these statuses
                   # this batch's children are part of it, and so is anything an
                   # earlier report left undispatched.
                   "children": waiting, "overrides": report}
            out.update(counts)
            if status == "partial":
                out["error"] = error or (
                    "only %d of %d authored bugs filed — the rest are still held "
                    "here" % (len(filed_ids), bug_count))
            return out
        # S163 fix round 4 (D1): `overrides` rides at EVERY status now, not just
        # the two that show a filed batch. A Go is legitimate from a `failed`
        # session too (round 3: the panel lists every waiting bug, whatever
        # report it came from), so a Go REFUSED there has verdicts to echo — and
        # this was the one branch that dropped them, measured on the live daemon.
        out = {"sessionId": sid, "parent": mid, "status": status,
               "authored": True, "filed": False,
               "children": children, "steers": steers, "overrides": report}
        out.update(counts)
        if status == "failed":
            out["error"] = error or "filing the logged bugs failed"
        return out

    def _live_log_session(self, mid):
        """(sid, session) for `mid`, or (None, None). Call under `_log_lock`."""
        found = (None, None)
        for sid, s in self._log_sessions.items():
            if s.parent == mid:
                found = (sid, s)
        return found

    def _log_stamp_for(self, mid, sid, sess):
        """The `logFiling` stamp for one session, plus S163's `waitingCount`.

        The session cannot count the mission's waiting bugs (it knows only its
        own batch), and the card must not be handed a number the console does
        not publish — so the one extra field is added HERE, in the single place
        both surfaces go through, exactly as `_LogSession.stamp` is the single
        place the rest of the readout is shaped (S161 D2).
        """
        out = sess.stamp(sid)
        out["waitingCount"] = len(self._waiting_children(mid))
        return out

    def _log_stamps(self):
        """{parent id -> the `logFiling` stamp} for every live log session.

        D2: the stamp is built by `_LogSession.stamp`, the ONE place the readout is
        shaped, so the card cannot drift from what `log_session_state` reports.
        """
        # S163 fix round 3 (D4): a durable shortfall becomes a session on the
        # first board build after a restart, so the card keeps saying "1 of 2".
        self._rehydrate_log_sessions()
        out = {}
        with self._log_lock:
            live = list(self._log_sessions.items())
        # S163 fix round 4 (D4): an INTERRUPTED filing is re-measured on every
        # board build until it settles. The orphaned `log.sh` genuinely does land
        # its remaining bugs (35 s later, in the tester's run), and a card frozen
        # on the first answer would go on offering a retry of a bug that had
        # already arrived — the one way this cure could create a duplicate.
        # Costs one `_linked_children` scan, and only while something is unsettled.
        for sid, sess in live:
            if sess.interrupted:
                self._reconcile_interrupted(sid, sess)
        with self._log_lock:
            live = list(self._log_sessions.items())
        for sid, s in live:
            out[s.parent] = self._log_stamp_for(s.parent, sid, s)
        return out

    def log_overlay(self, board):
        """Additively stamp `logFiling` on the parent card of a live log session.

        The `align_overlay` shape, for the Mission-Log half: so a filing survives a
        page reload (a fresh tab has no client state), stamp
        `card["logFiling"] = {"sessionId","status","bugCount","filedCount"}` onto the PARENT
        mission's board card while its session is live and un-consumed. Purely
        in-memory and ADDITIVE — with no live session the board is returned
        byte-for-byte unchanged. It does NOT move `adapter.fingerprint()`, so it
        never drives an SSE push; the safety poll picks it up.

        A read-only / github build constructs the daemon with actions=None, so this
        is never reached there — the parent card is never stamped.
        """
        if not isinstance(board, dict):
            return board
        cols = board.get("columns")
        if not isinstance(cols, dict):
            return board
        stamps = self._log_stamps()
        # S163: the second, mutually exclusive stamp — a batch whose Go this
        # daemon has already dispatched (see _mark_log_dispatched). Same additive
        # contract: nothing live and nothing dispatched ⇒ the board is returned
        # byte-for-byte unchanged.
        marks = self._log_dispatch_stamps()
        # S163 fix round 7 (D2): and the mission-level waiting count, published
        # for every parent that has one — the read-write board and the view-only
        # board take the SAME measurement from the SAME function (`LogFacts.
        # _waiting_counts`), which is what makes "card, panel and Go are one
        # reading" a property of the code rather than of three call sites
        # agreeing by luck.
        waiting = self._waiting_counts()
        if not stamps and not marks and not waiting:
            return board          # no live sessions → byte-identical board.
        for col in cols.values():
            if not isinstance(col, list):
                continue
            for card in col:
                if not isinstance(card, dict):
                    continue
                self._stamp_waiting(card, waiting)
                # S163 fix round 3 (D3): two INDEPENDENT ifs, not an elif. After
                # a Go on a partial both facts are true at once and the card
                # needs both — `logDispatch` withdraws the Fix control and
                # restores the honest "◐ resolving N…", `logFiling` keeps S162's
                # "only 1 of 2 filed" note underneath it. The elif made the card
                # pick one, and it picked the one that hid the dispatch.
                # `_log_dispatch_stamps` decides WHICH marks survive a live
                # session, so this can never resurrect a spent record.
                if card.get("id") in stamps:
                    card["logFiling"] = stamps[card["id"]]
                if card.get("id") in marks:
                    card["logDispatch"] = marks[card["id"]]
        return board

    def log_overlay_mission(self, mission):
        """Stamp `logFiling` onto a SINGLE mission-DETAIL dict.

        The detail payload must mirror the board card (the `align_overlay_mission`
        lesson: the detail modal never runs through the board overlay, so without
        this it falls back to client state that is empty after a reload). Additive
        + in-memory: a mission with no live session is returned unchanged.

        Same `_LogSession.stamp` shape as the board card, by construction (D2).
        """
        if not isinstance(mission, dict):
            return mission
        mid = mission.get("id")
        if not mid:
            return mission
        # S163 fix round 3 (D4): the same durable-shortfall read the card gets.
        self._rehydrate_log_sessions()
        with self._log_lock:
            sid, sess = self._live_log_session(mid)
        if sess is not None:
            mission["logFiling"] = self._log_stamp_for(mid, sid, sess)
        # S163: same two-stamp rule as the board card, so the detail and the card
        # cannot disagree about whether the Go has been taken — and, since fix
        # round 3, the SAME "does a live session outrank this record?" rule,
        # taken from the one place that decides it. Reading `_log_dispatched`
        # directly here is what let the detail keep a mark the board had
        # (correctly) dropped, and vice versa.
        mark = self._log_dispatch_stamps().get(mid)
        if mark is not None:
            mission["logDispatch"] = dict(mark)
        # S163 fix round 7 (D2): the card counts it, so the detail counts it —
        # from the same call, so the two doors onto a mission cannot show
        # different numbers.
        return self._stamp_waiting(mission)

    def log_run(self, mid, prds=None, overrides=None, confirm=False,
                images=None, image_refs=None, resume=False):
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

        The captain overrides (S74) pair positionally with the prds at FILE time
        (the bugs have no ids yet, so position is all there is) and are persisted
        by log.sh. On the Go path they are KEYED BY CHILD MISSION ID — see
        `_override_pairs` for why that changed in S163 fix round 3.
        """
        self._require_mission(mid)
        # S163 fix round 3 (D3) — ONE Go per batch, and say so.
        #
        # The tester pressed Go twice on an already-dispatched parent and got
        # `ok:true` both times, with the durable record's timestamp quietly
        # rewritten. No duplicate driver appeared (resolve-logs' own lock caught
        # it) but the daemon had agreed to something it did not do, which is the
        # same class of lie the rest of this round is about. The mark is spent by
        # a fresh preview (`_new_log_session`), so a NEW report re-arms the Go —
        # this closes the repeat, not the road.
        #
        # S163 fix round 4 (D2) — ...and the refusal is now ATOMIC. Round 3's
        # version read the persisted record, which `_mark_log_dispatched` only
        # writes AFTER the spawn, so at true simultaneity every request passed:
        # the tester fired five Gos at once and got `200 200 200 200 200` and
        # FIVE resolve-logs drivers racing over the same bug missions and the
        # same parent branch. The winner is now decided BEFORE any spawn, by
        # claiming `mid` in `_log_dispatching` inside the one lock acquisition
        # that also tests the record — so a loser cannot slip between the test
        # and the claim. The claim is released in the `finally` below; by then
        # the winner's durable record exists and refuses the next Go on its own.
        #
        # S163 fix round 6 (D3) — ...and the question changed. Round 3/4 asked
        # `_log_dispatch_stamps_locked`, which applies the DISPLAY rule "a newer
        # session out-ranks the record" — so a captain who logged one more bug
        # against a parent mid-drive was answered "no dispatch here", got a 200,
        # and got a second resolve-logs over the first one's children. The guard
        # now asks the only question that can be answered honestly: is a drive
        # on this parent STILL RUNNING? (`_live_log_dispatch` — measured from
        # the dispatched children's own stages, not from a mark a preview can
        # spend.) A batch that has reached its consolidated gate re-arms the Go
        # for whatever was logged since, which is the road round 3 wanted to
        # keep open, opened at the moment it is actually safe.
        #
        # S163 fix round 7 (D3) — ...and the refusal grew a DOOR. Round 6's price
        # was written down and then paid: a resolve-logs that dies mid-batch
        # leaves its children short of `verify`, so the guard below refused for
        # ever and its advice ("it becomes runnable as soon as this batch reaches
        # its gate") named an event that could not occur. `resume=True` is the
        # captain saying "that drive is gone; run these again" — and it is not
        # taken on trust: it is granted only where the daemon can SEE the drive
        # is not running (`_log_dispatch_is_stale`, which is false whenever the
        # resolver process answers), so it can never become the double dispatch
        # in disguise. The un-flagged Go is refused exactly as it was; what
        # changed is that its message now names something that can be done.
        claimed = False
        if not prds:
            with self._log_lock:
                stale = self._log_dispatch_is_stale(mid)
                if mid in self._log_dispatching:
                    raise ActionError(
                        409, "a run on %s is being dispatched right now — wait "
                             "for it to land, then read the card." % mid)
                if resume and not stale:
                    # the captain asked to re-run a drive the daemon can still
                    # see. Refuse in the words of what is actually true.
                    raise ActionError(
                        409, "resolve-logs is still running on %s — there is "
                             "nothing to resume. It is taking the logged bugs "
                             "to the consolidated re-verify gate; the card will "
                             "offer the Go again when it gets there." % mid)
                if not resume and self._live_log_dispatch(mid) is not None:
                    raise ActionError(
                        409, "the logged bugs on %s are already being driven — "
                             "resolve-logs is taking them to the consolidated "
                             "re-verify gate, and a second run would drive the "
                             "same bugs on the same branch. Anything logged "
                             "since is filed and waiting; it becomes runnable "
                             "as soon as this batch reaches its gate — or, if "
                             "that drive is no longer running, use the card's "
                             "resume control to run these bugs again." % mid)
                if not resume and stale:
                    # a record stands over a drive that is gone. Say so, and name
                    # the control that fixes it rather than a gate that cannot
                    # arrive. (The card offers exactly this control; a plain Go
                    # reaching here came from an older tab or a scripted client.)
                    raise ActionError(
                        409, "a run was dispatched on %s but the resolve-logs "
                             "driving it is no longer running, and its bugs "
                             "never reached the consolidated re-verify gate. "
                             "Nothing is in flight — use the card's resume "
                             "control (or post this run with resume:true) to "
                             "run them again." % mid)
                self._log_dispatching.add(mid)
                claimed = True
        try:
            return self._log_run_claimed(mid, prds, overrides, confirm,
                                         images, image_refs)
        finally:
            if claimed:
                with self._log_lock:
                    self._log_dispatching.discard(mid)

    def _log_run_claimed(self, mid, prds, overrides, confirm, images,
                         image_refs):
        """The body of `log_run`, with this parent's dispatch already claimed.

        Split out purely so the claim can be released by ONE `finally` no matter
        which of the many returns/raises below fires (S163 fix round 4, D2).
        """
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
            apply_report, blocked = self._apply_child_overrides(mid, overrides)
            # ── S163 fix round 4 (D1): NEVER accepted-then-dropped ────────────
            #
            # The tester typed four overrides into a 4-bug review and pressed
            # Go. Two resolved. Two — "use haiku" and "be really thorough on
            # this one" — were accepted, echoed as pending, posted, and then
            # dropped: `modelOverride` null on disk, the raw words nowhere under
            # `.git/lcars/`, and the batch dispatched anyway. The captain's
            # instruction was gone and their bug ran on the default model.
            #
            # The unknown-BUG-ID case (below, and untouched) can be reported and
            # waved through, because a steer for a bug the Go is not running
            # cannot send anything to the wrong model. A steer for a bug the Go
            # IS about to run has no such escape: after the dispatch there is no
            # console left to report into and the bug is already moving. So the
            # dispatch is REFUSED. Nothing spawns, no record is written, and the
            # message names each bug and each reason.
            #
            # The verdicts are merged onto the live session FIRST, so a reopened
            # console echoes the error against the right bug through the same
            # `overrides` channel the File step already uses — the captain's
            # words come back editable rather than remembered.
            self._merge_override_report(mid, apply_report)
            if blocked:
                raise ActionError(
                    400, "the logged bugs were NOT dispatched — %s. Fix or "
                         "clear %s in the review and press Go again; nothing "
                         "has been run and nothing has been changed."
                         % ("; ".join("%s: %s" % (r["id"], r["error"])
                                      for r in blocked),
                            "that steer" if len(blocked) == 1
                            else "those steers"))
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
        # S163 fix round 7 (D3): keep the handle. A card that says a drive is
        # running has to be able to prove it, and the pid alone cannot inside
        # THIS daemon's life — the resolver is our own detached child, never
        # waited on, so after it exits it stays a zombie and `os.kill(pid, 0)`
        # goes on succeeding. `Popen.poll()` reaps it and answers honestly.
        proc = self._spawn("resolve", ["--parent", mid], env_extra=env_extra)
        # S161: the explicit Go CONSUMES the authoring session — the bugs are real
        # Missions being driven now, so the parent card must stop advertising a
        # filing. (Reached only on the Go paths; the file-then-hold branch above
        # returns before this and deliberately leaves the session live.) N1: a
        # session still holding bugs that never reached disk is KEPT — the Go drives
        # what landed, and dropping it would destroy the rest's authored text.
        with self._log_lock:
            live_sid, _live = self._live_log_session(mid)
        self._drop_log_session(mid, keep_unfiled=True)
        # S163: and RECORD that this daemon dispatched the Go, so a card rendered
        # by a tab that never clicked (a reload) does not re-offer a review that
        # has already been taken. Written AFTER the spawn, so it can never claim a
        # dispatch that did not happen.
        self._mark_log_dispatched(mid, live_sid, proc=proc)
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
        d = os.path.join(self._missions_dir(), mid)
        if not (mid and os.path.isfile(os.path.join(d, "state.json"))):
            raise ActionError(404, "no such mission: %s" % mid)

    def _mission_state(self, mid):
        detail = self._reader.mission(mid)
        if detail is None:
            # the action may have moved it (e.g. approve → done is still present);
            # fall back to the whole board so the caller always gets fresh state.
            return {"board": self._reader.board()}
        return {"mission": detail}

    def _normalize_override(self, raw, parent):
        """Normalize one free-form per-bug steer, reusing the daemon worker seam.

        Deterministic-first; for the inconclusive long tail it falls back to ONE
        bounded `_worker_turn` (the SAME cold-worker seam tests stub) on the
        PARENT mission's persisted engine (BUG-C inheritance), applying the Align
        normalization instruction. Returns {scope,tier} or None.
        """
        engine = self._persisted_worker_bin(parent)

        def _worker(text):
            # S163 fix round 4 (D1): a steer naming a model LCARS has no tier for
            # is settled by the word, not by a turn. The bounded fallback is for
            # the plain-language long tail ("keep it cheap"), not for teaching a
            # worker that `haiku` is not on the menu.
            if unsupported_tier(text):
                return ""
            prompt = _OVERRIDE_FALLBACK_PROMPT + text + "\n"
            return self._worker_turn(prompt, engine=engine)

        return normalize_override(raw, worker=_worker)

    @staticmethod
    def _override_pairs(overrides, panel):
        """(child id, raw steer) pairs from whatever shape the client sent.

        S163 fix round 3 (D2) — THE STEER IS TIED TO THE BUG, NOT TO A SLOT.

        Until this round the post-File steers were a LIST, paired positionally
        against `_linked_children(parent)` — every child of the parent, sorted by
        mission directory name — while the review panel rendered a different,
        batch-filtered list. On a parent holding two reports the tester typed
        `all:opus` into the only box on screen ("second report bug three") and
        the daemon wrote it onto "first report bug one", a bug that had never
        been displayed. Neither list was wrong on its own; pairing two different
        lists by INDEX is what made a steer land on a stranger.

        So the wire shape is now KEYED, and the key is the child's mission id:

            {"m-bug3": "all:opus"}            preferred (what the console sends)
            [{"id": "m-bug3", "steer": ...}]  the same thing, as rows
            ["all:opus", ""]                  LEGACY positional

        The legacy list is kept because it is the shape `log.sh` is handed at
        FILE time (where the bugs have no ids yet, so position is all there is)
        and because an older client may still post one. It now pairs against the
        PANEL — the waiting children — so even a positional client is aligned
        with the rows a captain can actually see.

        Returns `(pairs, keyed)`: [(id_or_None, raw)] plus whether the client
        addressed its bugs BY NAME. A keyed entry whose id is not on the panel
        comes back with the id it named, so the caller can REPORT it rather than
        drop it (S161 fixed the positional version of that silent drop once
        already; a keyed scheme must make it impossible, not merely unlikely).

        S163 fix round 6 (D1) — `keyed` exists because an EMPTY steer means two
        different things in the two shapes, and only one of them can be a
        retraction. In a keyed map the console sends one entry per box it
        rendered, so `""` is the captain having emptied that box. In the legacy
        positional list — the shape `log.sh` is handed at FILE time, where the
        bugs have no ids yet — a blank has only ever meant "no steer for this
        slot". One flag, decided at the one place that can see the shape.
        """
        if isinstance(overrides, dict):
            return [(str(k), v) for k, v in overrides.items()], True
        pairs = []
        rows = list(overrides or [])
        if rows and all(isinstance(r, dict) for r in rows):
            for r in rows:
                pairs.append((r.get("id"),
                              r.get("steer", r.get("raw", r.get("override")))))
            return pairs, True
        for i, raw in enumerate(rows):
            pairs.append((panel[i]["id"] if i < len(panel) else None, raw))
        return pairs, False

    def _apply_child_overrides(self, parent, overrides):
        """Persist the post-File per-bug overrides onto ALREADY-FILED children.

        Each steer is matched to its bug BY MISSION ID (see `_override_pairs`),
        normalized to {scope,tier} (passthrough structured → deterministic parse
        → bounded worker fallback; S74 follow-up) and written to that child's
        state.json.modelOverride — the lever run.sh's active_model_override
        reads, so resolve-logs drives that child on the chosen model with zero
        skill changes.

        Returns `(report, blocked)`:
          report   [{id, raw, resolved, label, error}] so the caller can echo the
                   resolved steer / surface a normalization error.
          blocked  the subset of `report` that failed to resolve FOR A BUG THIS
                   MISSION IS ABOUT TO RUN — the caller's cue to refuse the Go.

        Blank entries are SKIPPED (no clobber of an earlier File-time steer); a
        steer naming a bug that is not waiting on this mission is reported and
        NOT persisted — never a silent write onto somebody else's bug.

        S163 fix round 4 (D1) — RESOLVE EVERYTHING, THEN WRITE, AND ONLY IF
        NOTHING IS BLOCKED. The first cut of the refusal resolved and wrote in
        one pass, so a good steer typed beside a bad one was already persisted
        by the time the bad one was reached — and the refusal then said "nothing
        has been changed", which was the very kind of sentence this round exists
        to delete. Measured on the live daemon before it shipped. One worker pass
        either way (the resolutions are computed once and only then committed),
        so the honesty costs nothing.
        """
        report = []
        if not overrides:
            return report, []
        panel = self._waiting_children(parent)
        known = set(c["id"] for c in panel)
        pairs, keyed = self._override_pairs(overrides, panel)
        for cid, ov in pairs:
            if not (isinstance(ov, str) and ov.strip()):
                # ── S163 fix round 6 (D1): CLEARING A STEER MEANS CLEARING IT ──
                #
                # A blank used to be skipped outright, which made an emptied box
                # indistinguishable from a bug the captain never touched — so a
                # steer the daemon had recorded (and echoed back into the box)
                # could not be taken away. The tester deleted an unusable steer,
                # pressed Go, watched the refusal correctly stop naming that bug
                # — and then watched the panel put the deleted words straight
                # back and the next Go re-send them. There was no way to return
                # a bug to "no steer" at all.
                #
                # So a blank against a bug ON THE PANEL, in a payload that named
                # its bugs (see `_override_pairs`), is an instruction: retract
                # everything recorded about this bug — the verdict the console
                # echoes AND the `modelOverride` on disk. It carries no error,
                # so it can never block the Go; it is the edit that UNBLOCKS one.
                #
                # A blank in the legacy positional list, or against a bug this
                # payload never showed, still means nothing at all.
                if keyed and cid in known:
                    report.append({"id": cid, "raw": "", "resolved": None,
                                   "label": None, "error": None,
                                   "cleared": True})
                continue
            raw = ov.strip()
            if cid is None or cid not in known:
                report.append({
                    "id": cid, "raw": raw, "resolved": None, "label": None,
                    "error": ("no logged bug %s is waiting to be fixed on this "
                              "mission — the steer was not applied"
                              % (cid if cid else "(unnamed)"))})
                continue
            resolved = self._normalize_override(raw, parent)
            if resolved is None:
                report.append({"id": cid, "raw": raw,
                               "resolved": None, "label": None,
                               "error": _override_error(ov)})
                continue
            report.append({"id": cid, "raw": raw, "resolved": resolved,
                           "label": _override_label(resolved), "error": None})
        blocked = [r for r in report if r.get("error") and r.get("id") in known]
        if blocked:
            # Nothing is committed. The caller refuses the dispatch, and the
            # promise it makes while doing so — "nothing has been run and
            # nothing has been changed" — is then literally true.
            return report, blocked
        for r in report:
            if r.get("cleared"):
                self._clear_child_override(r["id"])
            elif r.get("resolved"):
                self._write_child_override(r["id"], r["resolved"]["scope"],
                                           r["resolved"]["tier"])
        return report, []

    def _merge_override_report(self, parent, report):
        """Keep a Go's per-bug steer verdicts on the parent's live session (D1).

        `_settle_log_session` already merges the FILE step's verdicts by child id
        so a reopened console can echo each resolved label / normalization error
        beside its bug. A Go-time verdict had nowhere to live: it rode the HTTP
        response of a POST whose client had already closed the console, so an
        error the daemon correctly produced was never seen by anyone.

        Same merge, same key, so the console needs no new channel: reopening
        after a refused Go shows the red line against the bug it belongs to, with
        the captain's own words in `raw`.

        A parent with no live session (the daemon restarted and the review was
        rebuilt from the linked children) has nowhere to keep it — there the
        refusal message is the whole report. Stated, not hidden.
        """
        rows = [r for r in (report or []) if r.get("id")]
        # S163 fix round 6 (D1): a CLEARED bug leaves no verdict behind. The
        # merge below replaces a bug's row; a clear must DELETE it, because the
        # console re-seeds an emptied box from exactly this channel and "the
        # panel must never show a steer the last Go did not send". Computed
        # BEFORE the empty-check: a Go whose only edit was a clear still has
        # something to say to the session, and it is a removal.
        dropped = set(r["id"] for r in rows if r.get("cleared"))
        rows = [r for r in rows if not r.get("cleared")]
        if not rows and not dropped:
            return
        # A daemon that has just booted has not read its durable records yet
        # (the scan is lazy — first surface that needs a session). Without this,
        # the FIRST Go after a restart merged its verdicts into nothing and the
        # reason vanished: measured live on the round-4 fixture, where the very
        # console the captain would reopen is the rehydrated one.
        self._rehydrate_log_sessions()
        with self._log_lock:
            _sid, sess = self._live_log_session(parent)
            if sess is None:
                return
            fresh = set(r["id"] for r in rows) | dropped
            sess.overrides_report = [
                r for r in sess.overrides_report if r.get("id") not in fresh
            ] + [dict(r) for r in rows]

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

    def _clear_child_override(self, mid):
        """Retract a bug's persisted steer (S163 fix round 6, D1).

        The mirror of `_write_child_override`, onto the same lever run.sh's
        `active_model_override` reads. Dropping only the console's verdict would
        have left the box re-filling from `c.override` on the next repaint and
        the bug still running on a model the captain had retracted — the same
        defect one surface deeper. A child with no override is a clean no-op, so
        clearing an already-clear bug rewrites nothing.
        """
        sp = os.path.join(self.repo_root, ".git", "lcars", "missions", mid,
                          "state.json")
        try:
            with open(sp) as fh:
                state = json.load(fh)
        except (OSError, ValueError):
            return
        if not isinstance(state, dict) or state.get("modelOverride") is None:
            return
        state.pop("modelOverride", None)
        with open(sp, "w") as fh:
            json.dump(state, fh, indent=2)
            fh.write("\n")

    @staticmethod
    def _title_from_idea(idea):
        first = idea.splitlines()[0].strip() if idea else "New mission"
        if len(first) > 72:
            first = first[:69].rstrip() + "..."
        return first or "New mission"

    # ── S160 fix-loop: LCARS's own scratch NEVER lands in the working tree ────
    # The daemon materialises the captain's idea, their pasted images and a
    # worker output dir as files on disk before it dispatches. Those used to be
    # written into the REPO ROOT, and the consequence was not cosmetic: the
    # base-freshness guard reads `git status --porcelain`, counted LCARS's own
    # `lcars-prd-<rand>.md` as the captain's untracked work, refused the
    # fast-forward it was standing right in front of, and stamped a permanent
    # `loud: true` record telling a pristine clone it was dirty — while the
    # Mission really was cut from the stale base. The same class S157 found: the
    # harness's own provisioning artifacts are never the user's changes.
    #
    # THE CURE IS THE LOCATION, NOT A RULE ABOUT NAMES. Under `.git/` the
    # scratch is invisible to `git status` BY CONSTRUCTION — there is no ignore
    # list to keep in sync with the filenames, no "take the reading before you
    # write" ordering for a future writer to forget, and no filename special
    # case for the guard to get wrong. It is also exactly where CLAUDE.md says
    # per-repo LCARS state belongs, for the same stated reason: the target
    # repo's working tree stays clean.
    #
    # It stays INSIDE the repo directory, so everything that made repo_root the
    # original choice still holds — a worker sandboxed to the repo can still
    # read the staged image by absolute path (copilot `--attachment`, claude's
    # Read tool), which a system tempdir would have broken.
    def _scratch_dir(self):
        """LCARS's own per-repo scratch space, created on demand."""
        d = os.path.join(self._git_dir(), "lcars", "tmp")
        os.makedirs(d, exist_ok=True)
        return d

    def _git_dir(self):
        """This repo's git directory. Normally `<repo_root>/.git`; in a LINKED
        WORKTREE that path is a FILE holding `gitdir: <real path>`, and writing
        scratch "into" it would fail — so the pointer is followed."""
        p = os.path.join(self.repo_root, ".git")
        if os.path.isfile(p):
            try:
                with open(p) as fh:
                    for line in fh:
                        if line.startswith("gitdir:"):
                            g = line.split(":", 1)[1].strip()
                            if not os.path.isabs(g):
                                g = os.path.join(self.repo_root, g)
                            return os.path.normpath(g)
            except OSError:
                pass
        return p

    def _tmp_prd(self, content):
        fd, path = tempfile.mkstemp(prefix="lcars-prd-", suffix=".md",
                                    dir=self._scratch_dir())
        with os.fdopen(fd, "w") as fh:
            fh.write(content)
        return path

    # ── S91: staging pasted images for the conversational worker ──────────────
    # The captain pastes/drops an image into the File idea box, the Align grill
    # reply, or the Mission-Log box; it rides the existing write body as
    # `images:[{name,type,dataB64}]`. We DECODE the base64 with the stdlib
    # `base64` module (NO Pillow/PIL — we never inspect or re-encode the pixels,
    # we just write the bytes) and stage each in the scratch dir, MIRRORING
    # `_tmp_prd`, so the worker can reach it: copilot via `--attachment <path>`,
    # claude via its Read tool on the abs path. The server has already enforced
    # the content-type allow-list (415) and the body cap (413) before we get here.
    def _stage_image(self, content_type, data_b64):
        """Decode one base64 image and stage it in `_scratch_dir()`; return the
        abs path. The suffix follows the (already allow-listed) content type so
        the worker's image loader recognises it. Caller owns cleanup."""
        suffix = _IMAGE_SUFFIX.get((content_type or "").strip().lower(), ".png")
        try:
            raw = base64.b64decode((data_b64 or "").encode("ascii"),
                                   validate=True)
        except (binascii.Error, ValueError, UnicodeEncodeError):
            raise ActionError(400, "image data is not valid base64")
        fd, path = tempfile.mkstemp(prefix="lcars-img-", suffix=suffix,
                                    dir=self._scratch_dir())
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
        # S146: the update skill carries the sanctioned test-readiness verbs.
        "update": os.path.join(home, ".claude/skills/lcars-update/update.sh"),
    }
    scripts = {}
    for key, default in default_dir.items():
        scripts[key] = env.get(SCRIPT_ENV[key], default)
    return Actions(repo_root=repo_root, scripts=scripts,
                   worker_bin=worker_bin, gh_bin=gh_bin,
                   check_script=scripts.get("version_check"),
                   # S124 — the holodeck's two seams. Empty/unset leaves the
                   # defaults in charge (sidecar beside the repo, plain `git`).
                   holodeck_root=env.get("LCARS_HOLODECK_ROOT"),
                   git_bin=env.get("LCARS_GIT_BIN"))
