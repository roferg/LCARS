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
import hashlib
import json
import mimetypes
import os
import re
import shutil
import signal
import struct
import subprocess
import tempfile
import contextlib
import threading
import time
import unicodedata
import uuid
import zlib

from .local_adapter import LocalAdapter


class ActionError(Exception):
    """Raised on a bad request (status carries the HTTP code to return).

    S169 fix round 1 — `data` is an OPTIONAL dict of facts the refusal needs the
    page to act on, merged into the write-error body by `server._write_error`.
    It exists so a surface never has to read the message TEXT to decide what
    happened (the one live user is `sessionReset`; see `_poisoned_note`).
    """

    # S178 — THE SKILL'S OWN EXIT CODE, when this refusal came from one.
    # `_run` stamps it; the Align finalize branches on it to tell "the PRD you
    # just wrote is wrong" (3, redraftable) from "the environment is wrong" (1,
    # retrying burns tokens). A CLASS-LEVEL default, so every ActionError ever
    # constructed already answers the question — and answers it `None`, which is
    # "this did not come from a skill" rather than a number to be guessed at.
    #
    # It is deliberately NOT in `data`: `data` is merged into the HTTP body by
    # `server._write_error`, and a new key there would change the payload of
    # every existing write error. This is daemon-internal.
    skill_exit = None
    # …and WHERE THE DRAFTED PRD SURVIVED, when a dispatch persisted one before
    # failing (S178 cure 1). Empty when there is nothing to point at.
    draft_path = ""

    def __init__(self, status, message, data=None):
        super().__init__(message)
        self.status = status
        self.message = message
        self.data = dict(data or {})


# S191 fix round 1 (D5) — ADOPT'S OWN REFUSAL CHANNEL.
#
# THE DEFECT. `lcars adopt` on a mission mid-pipeline answers with one of the
# best sentences LCARS writes — it names the boundary, says why the middle of
# the pipeline is not portable, and says "Nothing was created." The daemon
# delivered it under HTTP 502. 502 means THE SERVER BROKE. Nothing broke: the
# captain asked for something this mission's own state does not allow, and the
# code for that is 409 CONFLICT. A refusal wearing a fault's status teaches the
# operator to distrust the status line, and after that every real fault is noise.
#
# HOW A REFUSAL IS RECOGNISED, AND WHY IT IS NOT PROSE-MATCHING. adopt.sh has
# exactly ONE way of saying no: `die()` at skills/lcars-adopt/adopt.sh:107 prints
# `lcars adopt: <sentence>` and exits 1. That banner is the script's own
# structured refusal channel — a marker it stamps on purpose, not wording a
# reader has to interpret — so the test is (exit code == 1) AND (the banner is
# there). S165's rule is kept: nothing here reads the SENTENCE to decide, only
# the envelope around it.
#
# A CRASH IS STILL A FAULT, deliberately and in both directions. A different
# exit status (127 for a missing binary, 2 for a bash syntax error, a signal) or
# output that never went through `die()` — a traceback, a stray stderr line —
# keeps its 502 untouched, because a broken server that answered 409 would be
# the same lie pointing the other way.
#
# NARROW ON PURPOSE. `_run` is unchanged, so every other skill dispatch in this
# daemon still maps exactly as it did. This is adopt's refusal, and adopt's only.
_ADOPT_REFUSAL_BANNER = "lcars adopt: "


# adopt.sh's `note()` writes exactly `  ⚠ <sentence>` — see its NOTES channel.
# A warning may WRAP over following lines in the terminal, but note() emits one
# line per warning, so one line is one warning.
_ADOPT_WARN_MARK = "\u26a0"


def _adopt_warnings(output):
    """The `⚠` lines adopt printed, in order, with the marker trimmed."""
    out = []
    for line in (output or "").splitlines():
        stripped = line.strip()
        if stripped.startswith(_ADOPT_WARN_MARK):
            text = stripped[len(_ADOPT_WARN_MARK):].strip()
            if text:
                out.append(text)
    return out


def _adopt_refusal(exc):
    """`exc` re-cast as a 409 when adopt.sh REFUSED, else `exc` untouched."""
    if getattr(exc, "skill_exit", None) != 1:
        return exc
    msg = getattr(exc, "message", "") or ""
    at = msg.find(_ADOPT_REFUSAL_BANNER)
    if at < 0:
        return exc
    # Everything the script said after its banner, verbatim. The prose IS the
    # refusal — the status code only stops it being read as a crash.
    line = msg[at + len(_ADOPT_REFUSAL_BANNER):].strip()
    if not line:
        return exc
    out = ActionError(409, line)
    out.skill_exit = exc.skill_exit
    return out


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
    # S183: the FOUNDATION GATE (skills/lcars-init/foundation-gate.sh) — the ONE
    # seam that decides whether a repo may take a normal mission at all. The
    # daemon SHELLS it exactly as it shells readiness.sh; it never reimplements
    # the verdict in Python (ADR-002), so the board and the CLI can never
    # disagree about whether this repo has a test foundation.
    "foundation_gate": "LCARS_FOUNDATION_GATE_BIN",
    # S184: ESTABLISH VISION (skills/lcars-init/establish-vision.sh) — the ONE
    # machinery behind both front doors. The daemon shells it for the board's
    # FOUND panel facts, for the grill's foundation brief, and to FILE the
    # initialization mission; it assembles none of those itself.
    "establish_vision": "LCARS_ESTABLISH_VISION_BIN",
    # S190: the OWNERSHIP library (skills/lcars-run/ownership.sh). The daemon
    # shells its `lock-reason` op before it lets a mission write through, so the
    # board's refusal is the SAME verdict, with the SAME posture and the SAME
    # sentence, as the one `lcars run` / `respond` / `approve` / `feedback` /
    # `log` already reach at the CLI. It never reimplements the rule (ADR-002).
    "ownership": "LCARS_OWNERSHIP_SCRIPT",
    # S191: `lcars adopt` (skills/lcars-adopt/adopt.sh) — rebuild a Mission on
    # THIS laptop from its GitHub issue alone. The board's remote card offers it
    # at the two ENDS of the pipeline; the daemon only DISPATCHES it, and every
    # refusal (wrong stage, missing envelope, no gh) stays the skill's own.
    "adopt": "LCARS_ADOPT_SCRIPT",
    # S201: `lcars xo` — the repo toggle and the stand-down.
    "xo": "LCARS_XO_SCRIPT",
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


# S178 — `file.sh`'s "the PRD ITSELF is wrong and a redraft could fix it" exit
# code (skills/lcars-file/file.sh `die_prd`). Every other refusal from file.sh
# stays 1 and means the ENVIRONMENT is wrong — no mission, no `gh`, no repo —
# which no amount of redrafting can clear, so it must never reach the heal.
#
# THIS NUMBER IS THE WHOLE CLASSIFIER. There is no message matching anywhere on
# this road: S165's ruling is that the filter keys off EXIT STATUS, because the
# refusal text is prose written for a human and prose drifts.
_PRD_REDRAFTABLE_EXIT = 3

# How many repair turns the Align finalize will spend before it stops and hands
# the captain the gate's message. Two, because the warm session already holds
# the whole grill so each is cheap — and because a worker that cannot satisfy
# the gate twice in a row is not going to on the third.
_ALIGN_HEAL_CAP = 2

# The synthetic ANSWER a repair turn feeds the warm grill. It rides the EXISTING
# continuation road (`_build_align_prompt(opening=False)` reads
# `sess.transcript[-1]["answer"]`), so there is no second prompt channel and no
# second worker posture — the same warm session, one more turn.
#
# It says three things and no more: the PRD was refused (not the captain's
# answers), here is the refusal VERBATIM (only the gate knows what it wants),
# and re-emit the whole corrected PRD rather than asking anybody anything. The
# last clause matters: SKILL.md's own rule for this situation is FIX THE PRD,
# NEVER RE-GRILL — a completed alignment must not be thrown away over a heading.
# S178 CURE 6 — AND IT IS SURGICAL, because the refusal already is.
#
# `lcars_prd_questions_gate` does not say "you dropped 5 of 14" and stop: it
# prints `Missing:` followed by EVERY question it wants, verbatim, one per line.
# Handing the worker a summary of that would throw away the only part of the
# message that is actionable and turn the repair back into the recall test that
# lost the tail in the first place. So the refusal rides in WHOLE, and the
# instruction points at its list.
#
# This is not a new procedure. `skills/lcars-file/SKILL.md` (§"If `file.sh`
# refuses the PRD — FIX THE PRD, NEVER RE-GRILL") already prescribes exactly
# this repair for the CLI lane, down to the `- STILL OPEN: <the question>`
# entry and the ruling that the gate wants the questions to SURVIVE rather than
# be answered. The daemon lane simply could not reach it — the console had no
# way to hand a refusal back to the grill. The wording below mirrors that
# section on purpose; if one changes, the other should.
_ALIGN_HEAL_ANSWER = (
    "SYSTEM — YOUR PRD WAS REFUSED BY `lcars file`. The mission was NOT filed. "
    "This is a fault in the PRD document you just emitted, not in anything the "
    "captain told you, and he is not being asked about it.\n\n"
    "The refusal, verbatim:\n\n%s\n\n"
    "FIX THE PRD — do NOT re-grill, do NOT restart the interview, and do NOT "
    "ask another question. The alignment is complete and the captain has "
    "already confirmed it.\n\n"
    "If the refusal lists questions under `Missing:`, it has listed EVERY "
    "question it wants, verbatim. Add each one — all of them, including the "
    "last — to the PRD's `## Open questions from the design session` section "
    "as its own `- STILL OPEN: <the question>` entry, copying the question "
    "text as given. A `STILL OPEN:` entry satisfies the gate completely and "
    "permanently: you do NOT need the captain, you do NOT need an answer, and "
    "carrying a question forward unanswered is the correct and expected "
    "outcome. Use `- RESOLVED with the captain: <what was decided>` only where "
    "this grill genuinely settled it. Then COUNT your section's entries "
    "against the number the refusal names.\n\n"
    "If the refusal names a MISSING SECTION instead, reformat the PRD so that "
    "label is present — that is an edit to the document, not to its content.\n\n"
    "Re-emit the COMPLETE corrected PRD now as a single JSON object with "
    "status \"done\" and the full `prd` field — the same output contract as "
    "every other turn.")


# ── S184 fix round 2 — ESTABLISH VISION's MODE OVERRIDE (D2 + D9) ─────────
#
# WHAT WAS BROKEN. The vision grill ran the ordinary Align envelope, whose
# OUTPUT CONTRACT offers exactly two statuses: `question` and `done`. The
# foundation brief (`establish-vision.sh --brief`) asks the model to hand back
# stack / reasons / slice / deferred — four things with NO JSON SLOT anywhere in
# that contract and no parser anywhere in this file. So screen 3 could not be
# reached by any output a model could legally produce: measured, 0 of 19 live
# turns, 0 missions filed from the viewscreen.
#
# AND the prompt carried TWO FENCES. `SKILL.md` is loaded whole, so its STEP 0
# ("run foundation-gate.sh; on exit 20 show the refusal and STOP") rode into a
# session whose entire purpose is to establish the foundation that gate is
# checking for. Harmless while tools are denied — but two contradictory
# instructions in one prompt is a coin toss waiting for a tools-granted day.
#
# ONE BLOCK CURES BOTH, and it is appended AFTER the skill so it is the last
# word the model reads. It is added ONLY in vision mode: a normal mission's
# prompt is byte-identical to what it was.
_ALIGN_VISION_CONTRACT = """

=== ESTABLISH VISION — MODE OVERRIDE (this session; it wins where it differs) ===

You are running this interview in ESTABLISH VISION mode, against a repo with no
test foundation. Two things differ from the skill text above.

1. STEP 0 — THE FOUNDATION GATE — DOES NOT APPLY, and you must NOT run it.
   THIS is the conversation that establishes the foundation, so a gate that
   refuses work until a foundation exists is unsatisfiable here by construction.
   The harness has already exempted this session (the filing goes through
   `lcars file --initialization`, which the gate exempts). Do not run
   `foundation-gate.sh`, do not print its refusal, and do not stop.

2. THERE IS A THIRD STATUS, and it is how this interview ENDS. When you can
   fill in the four things the FOUNDATION BRIEF asks you to hand back, do NOT
   emit status "done" and do NOT author a PRD — the harness writes the PRD and
   the project vision doc itself, from exactly these fields. Emit:

   {"status":"recommendation",
    "recommendation":{
      "stack":"<the ONE recommended stack, a short concrete name>",
      "reasons":["<a reason, in the captain's own language>", "..."],
      "slice":"<the NOUN PHRASE completing 'proves both: ______'>",
      "deferred":["<every feature he named>", "..."]}}

   `stack` is the only required field; the captain accepts or overrides it on
   his own screen, which is why you recommend rather than decide. Until you can
   name a stack and defend it, keep emitting ordinary status "question" turns.
"""

# The one-line reminder a CONTINUATION turn carries. The warm session already
# holds the block above; this exists because a model that has asked six
# questions in a row drifts back to the two statuses it saw most recently, and
# the whole interview is worthless if it cannot end.
_ALIGN_VISION_REMINDER = (
    "\n\n(ESTABLISH VISION mode: when you can name the stack, end with the "
    "{\"status\":\"recommendation\", \"recommendation\":{stack, reasons, "
    "slice, deferred}} object instead of status \"done\".)")


# The keys that mark a parsed object as a WORKER TURN rather than incidental
# JSON on stdout (a tool argument, a config blob a tool echoed, …). The Align
# grill emits status/question/prd/adr (and, in vision mode, recommendation); the
# Mission-Log split emits bugs.
_TURN_KEYS = ("status", "question", "prd", "adr", "bugs", "recommendation")


# ── reading the RECOMMENDATION off a live model's reply ───────────────────
# S175's ruling, applied: a model's output SHAPE is a lottery, and our own
# parser has refused the prose our own prompt asked for before. So the reader
# below accepts the honest shapes rather than only the ideal one — the object
# under `recommendation`, the same object hung off the `question` wrapper, the
# fields spread flat across a `status:"recommendation"` turn — and takes lists
# OR newline-separated prose OR bulleted prose for the two list fields.
_REC_BULLET = re.compile(r"^[-*\u2022\u2013]\s+")


def _vision_text(v):
    """A scalar field, however it arrived (a string, or a list a model split)."""
    if isinstance(v, (list, tuple)):
        v = " ".join(str(x) for x in v)
    return str(v if v is not None else "").strip()


def _vision_lines(v):
    """A LIST field, however it arrived: a JSON array, a newline-separated
    string, or either of those with `- ` bullets on the front. The brief asks
    for these "one per line", which is prose wording — so prose is what a real
    model hands back about as often as an array."""
    if isinstance(v, (list, tuple)):
        items = [str(x) for x in v]
    else:
        items = str(v if v is not None else "").splitlines()
    out = []
    for it in items:
        it = _REC_BULLET.sub("", str(it).strip()).strip()
        if it:
            out.append(it)
    return out


# The SAME normalisation `establish-vision.sh`'s `ev_norm_slice` and board.js's
# `frontDoorSlice` already apply — the phrase that completes "proves both: ___",
# with any restated label and any trailing full stop removed. Three copies is
# one too many already; a FOURTH opinion, formed in the daemon, would let the
# screen and the filed mission say different things, which is the exact defect
# fix round 1 cured on the other two.
_REC_SLICE_LABEL = re.compile(
    r"^[^\u2014:]*\b(?:thin(?:\s+vertical)?\s+slice|proves?\s+both)\b"
    r"[^\u2014:]*[\u2014:]\s*(\S.*)$", re.I | re.S)


def _vision_slice(v):
    t = _vision_text(v)
    m = _REC_SLICE_LABEL.match(t)
    if m:
        t = m.group(1).strip()
    return t.rstrip(". \t")


def _vision_recommendation(turn):
    """The recommendation a VISION turn is handing back, or None.

    None means "this is still an ordinary turn" — and the test for that is
    `stack`, because the stack is the entire subject of the screen this unlocks.
    A hand-back with no stack is a model still thinking out loud, and the grill
    must go on rather than present the captain an empty decision.
    """
    if not isinstance(turn, dict):
        return None
    cands = []
    if isinstance(turn.get("recommendation"), dict):
        cands.append(turn["recommendation"])
    q = turn.get("question")
    if isinstance(q, dict) and isinstance(q.get("recommendation"), dict):
        cands.append(q["recommendation"])
    if str(turn.get("status") or "").strip().lower() in (
            "recommendation", "recommend"):
        cands.append(turn)
    for c in cands:
        stack = ""
        for k in ("stack", "recommendedStack", "recommended_stack"):
            stack = _vision_text(c.get(k))
            if stack:
                break
        if not stack:
            continue
        return {
            "stack": stack,
            "reasons": _vision_lines(c.get("reasons") or c.get("why")),
            "slice": _vision_slice(c.get("slice")
                                   or c.get("verticalSlice")
                                   or c.get("thinSlice")),
            "deferred": _vision_lines(c.get("deferred")
                                      or c.get("deferredFeatures")),
        }
    return None


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
                 "last_question", "holodeck", "vision",
                 "turn_started", "finalize_started", "heal_attempts")

    def __init__(self, idea, engine, mission_id=None, holodeck=None,
                 vision=False):
        # S171 — `holodeck_missing` is gone with `_handoff_missing`; the block
        # above that constant says why, and what risk was accepted.
        self.idea = idea
        self.engine = engine
        # S127 — the holodeck PROGRAM this grill is aligning, if any. Carried so
        # the done branch can attach its `mockup.html`/`concept.md` and lock the
        # program. A SESSION ID, never a path.
        self.holodeck = holodeck
        # Park & Align (S137): when this grill completes the alignment of an
        # ALREADY-PARKED mission (filed pre-PRD via `lcars file --park`), its id
        # is carried here so the done branch dispatches `file.sh --complete <id>`
        # (grill-completion IN PLACE) instead of a fresh `--prd` filing. None ⇒ a
        # normal File-console grill that files a brand-new mission (unchanged).
        self.mission_id = mission_id
        # S184 fix round 2 — IS THIS AN ESTABLISH VISION GRILL? Set once at
        # `align_start` and read in three places, all of which used to be
        # unable to tell the two apart: the prompt (which gains the mode
        # override), the turn reader (which can then take a RECOMMENDATION off
        # the reply), and the finalize (which must file through
        # `--initialization` or be refused by the foundation gate this grill
        # exists to satisfy). False ⇒ an ordinary mission, byte-identical.
        self.vision = bool(vision)
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
        # S128 (FL-009 — the RELOAD half): WHEN the worker call currently running
        # for this session began, or None when nothing is running. `started`
        # already said "the warm session has been opened"; this says "a turn is
        # in flight RIGHT NOW", which is the only question a card that lost its
        # client memory can ask. Set and cleared by `_align_turn` around the
        # worker call — and the clearing is what keeps it honest: a turn that
        # dies takes the fact with it, so nothing can read "still scanning"
        # forever. Same posture as `_HolodeckSession.turn_started` (f667ce8).
        self.turn_started = None
        # S169 (FL-017) — WHEN THE FINALIZE BEGAN, or None. The CLOSING answer
        # POST does not end at the worker call: it then runs the cold-opus cost
        # estimator and `file.sh --complete <id>` IN PLACE, which is minutes.
        # `turn_started` is deliberately scoped to the worker call only, so it
        # is silent for that whole window — and the client filled the silence
        # with a 300s `setTimeout` that cleared its own band and re-armed the
        # card, presenting a run that was still going as one that had stopped.
        # That is FL-009's exact shape with a longer fuse, and the captain hit
        # it live ("OK the mission is costing after the grill").
        #
        # So the daemon owns this fact too. Set immediately before the file.sh
        # dispatch and cleared in its `finally`, so the guard's lifetime IS the
        # dispatch's lifetime; a dispatch that dies takes the fact with it, and
        # a daemon restarted mid-finalize has no sessions at all — the card
        # reads parked and clickable again, which is the honest answer, because
        # that finalize is gone.
        self.finalize_started = None
        # S178 — how many PRD REPAIR turns the finalize currently running has
        # spent. Reset at the top of every finalize (so a session the captain
        # resumes gets a full cap, not a spent one) and read by
        # `_align_finalizing_fields`, which is what makes a heal something the
        # captain can SEE happening rather than a silent extra minute.
        self.heal_attempts = 0
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
    # S169 fix round 2 / S170 — the hand-off DERIVATION. Read-only, and the
    # SAME posture as grounding rather than a third one invented for it: it is
    # the same kind of pass (one cold look, no write channel, the daemon owns
    # the output) and — since S170 — the same cwd too, the captain's real
    # project. Reusing the grounding posture is deliberate: the session brief
    # said reuse the precedent, do not build a second worker road.
    ("claude", "derive"): "Read,Grep,Glob",
    # `edit` is REQUIRED in the copilot design set, not optional: copilot's
    # `create` CANNOT overwrite an existing file (measured on CLI 1.0.79-1 — a
    # hard `Path already exists` tool error, zero bytes changed), and turn 2 of
    # any design chat IS an overwrite. Without `edit` the channel is one-shot
    # per path and the engine degrades to the fenced-block fallback.
    ("copilot", "design"): "view,grep,glob,create,edit",
    ("copilot", "grounding"): "view,grep,glob",
    ("copilot", "derive"): "view,grep,glob",
}

# claude only (see above): what `--disallowedTools` refuses. The DESIGN room
# keeps Write/Edit — building the mockup is its whole job — and loses the shell,
# which closes the S72 reply-channel class on claude too. GROUNDING loses every
# write channel the CLI has, because it runs in the captain's real project.
_HOLODECK_DENY = {
    ("claude", "design"): "Bash,NotebookEdit",
    ("claude", "grounding"): "Write,Edit,Bash,NotebookEdit",
    # THE DERIVATION RUNS IN THE CAPTAIN'S REAL PROJECT (S170), so it loses
    # every write channel the CLI has for exactly the reason grounding does.
    # It also reads the program's room through an `--add-dir` grant, and a
    # write channel there would let a pass that is supposed to READ the drawing
    # edit the drawing instead — the one outcome worse than no pass at all.
    ("claude", "derive"): "Write,Edit,Bash,NotebookEdit",
}

_HOLODECK_MODES = ("design", "grounding")

# copilot's MCP-discipline flags. Without them copilot re-boots its builtin MCP
# servers and re-reads custom instructions on EVERY warm turn (26s → 13s
# measured at S72, re-confirmed in the S124 spike). A chat room cannot afford it.
_COPILOT_DISCIPLINE = ("--allow-all-tools", "--no-ask-user",
                       "--disable-builtin-mcps", "--no-custom-instructions")


def _is_copilot(bin_):
    return "copilot" in os.path.basename(bin_ or "").lower()


# The engines the New Program dialog offers, in the order it offers them. It is
# the SAME pair the File console's engine picker has always offered — the two
# CLIs LCARS drives — and it exists here so the daemon can publish each one's
# tier (see `models` in the list header) without the front end owning a second
# copy of `_holodeck_model`'s mapping.
_HOLODECK_ENGINES = ("claude", "copilot")


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


# ── S128 (FL-002 / FL-004) — the words that go with an in-flight turn ───────
#
# The captain asked for the same thing twice, in two different places: "add the
# ability to close and go do other stuff while the holodeck is building", and
# "if I close the new program dialog while it's opening the deck it keeps
# working? There is no indication it's working."
#
# The walking-away half already worked — a turn runs in the daemon's request
# thread and `_commit_turn` lands its bytes on every exit path. What did not
# exist was any way for a surface to KNOW. The functions below are where the
# sentences come from, and they live in the daemon for the same reason
# `handoffBlocked` does: the deck must never invent a reason for a state it did
# not create. Both are derived from ONE elapsed number, so the working line and
# the disabled Send can never quote different clocks.


def _holodeck_elapsed_phrase(seconds):
    """Roughly how long, in words: `a few seconds` … `about 4 minutes`.

    Deliberately COARSE. The number is read off a payload that is already a
    poll old, and a spinning second-counter would be claiming a precision the
    surface does not have.
    """
    try:
        secs = max(0.0, float(seconds))
    except (TypeError, ValueError):             # pragma: no cover - defensive
        secs = 0.0
    if secs < 20:
        return "a few seconds"
    if secs < 90:
        return "about %d seconds" % int(round(secs / 10.0) * 10)
    mins = int(round(secs / 60.0))
    if mins < 60:
        return "about a minute" if mins <= 1 else "about %d minutes" % mins
    hours = int(round(secs / 3600.0))
    return "about an hour" if hours <= 1 else "about %d hours" % hours


def _english_list(items):
    """`a`, `a and b`, `a, b and c` — file names in a sentence (S169)."""
    items = [str(i) for i in (items or []) if str(i)]
    if not items:
        return ""
    if len(items) == 1:
        return items[0]
    return "%s and %s" % (", ".join(items[:-1]), items[-1])


def _turn_intent(intent):
    """NORMALISE the captain's declared turn shape — "ask" or "build" (S169).

    Everything that is not the explicit declaration is "build", which is the
    prompt branch that already carries answer-then-stop as the default. So an
    absent, misspelled or hostile value degrades to the behaviour a captain who
    never touched the control gets, and the control stays genuinely optional.
    """
    return "ask" if str(intent or "").strip().lower() == "ask" else "build"


def _holodeck_busy_copy(seconds):
    """(label, reason) for a turn that has been running `seconds`.

    label  — the deck's working strip, in place of the client's own
             "Working on the holodeck…" the moment the DAEMON is the one
             reporting it (a returning deck has no idea when it started).

    S169 (FL-015) — IT NO LONGER SAYS "RENDERING". The captain asked the deck a
    question and watched a long turn go by under a banner asserting it was
    rendering; the daemon knows a turn is RUNNING and knows nothing whatever
    about what kind of turn it is until it has written something. "Rendering" is
    a reason the daemon has not earned, and inventing a reason for a state you
    can only see the shape of is exactly what `f667ce8` cured everywhere else on
    this board. "Working" is honest for both kinds of turn.
    reason — why Send is disabled, and the one thing a captain who came back to
             a locked composer actually wants: that nothing is stuck, that
             leaving is safe, and that his work is being saved either way.
    """
    ago = _holodeck_elapsed_phrase(seconds)
    label = "Still working — this turn started %s ago" % ago
    reason = (
        "This program has been working on a turn for %s. The holodeck runs one "
        "turn at a time in a room, because two would be writing the same "
        "files, so Send comes back the moment this one lands. You can leave "
        "the deck or close the tab — the turn keeps running here, and its "
        "files and the transcript are saved either way." % ago)
    return label, reason


def _holodeck_working_message(working):
    """The board band's one sentence about programs mid-turn (off the deck).

    Names the PROGRAM, because "something is running" is not a thing a captain
    can act on and "Nav rail has been rendering for about 4 minutes" is.
    """
    if not working:                             # pragma: no cover - defensive
        return ""
    longest = max(working, key=lambda w: w.get("busyFor") or 0)
    ago = _holodeck_elapsed_phrase(longest.get("busyFor"))
    if len(working) == 1:
        return ("The holodeck is working: “%s” has been at this turn for %s. "
                "Carry on here — it keeps running and saves itself."
                % (longest.get("program") or "a program", ago))
    return ("%d holodeck programs are working — the longest, “%s”, has been "
            "at its turn for %s. Carry on here — they keep running and save "
            "themselves." % (len(working), longest.get("program")
                             or "a program", ago))


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


_SLUG_MAX = 48
# How short a word-boundary cut is allowed to leave the room name before the
# hard cut is preferred instead. Purely a LENGTH rule — it reads no prose.
_SLUG_MIN_WORD_CUT = _SLUG_MAX // 2


def _slug_base(name):
    """The dashed, lowercase, separator-free form of a program name, UNCAPPED.

    Shared by `_slug` and `_slug_legacy` so the only thing that can ever differ
    between the two is WHERE the cut lands. Everything the docstring below
    promises about safety is promised here: no separator, no `.`, nothing that
    is not `[a-z0-9-]`.
    """
    return re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")


def _slug_legacy(name):
    """`_slug` EXACTLY as it was before S128 — a hard cut at character 48.

    Kept, and kept byte-faithful, because it is the on-disk directory name of
    every program the captain made before the cure. It is never used to NAME a
    new room; it is only ever used to FIND an old one (`_program_room`).
    """
    return (_slug_base(name)[:_SLUG_MAX] or "program")


def _slug(name):
    """A filesystem-safe program directory name, derived from the program name.

    Lowercase, non-alphanumerics collapsed to `-`, trimmed, capped. Never empty
    (falls back to "program") and never a path (no separators survive), so a
    program called `../../etc` cannot become one.

    S128 / FL-005 (b): the cut lands on a WORD BOUNDARY. A program started from
    a whole idea sentence was getting
    `i-want-to-give-the-top-tool-bar-and-edit-selecti` — and that string is the
    room's permanent identity in the captain's archive, not a temporary label.
    The boundary is a `-` in the ALREADY-NORMALISED string, so this reads no
    prose and knows nothing about language: it is the same character class the
    line above produced.

    A single token longer than the cap has no boundary to fall back to and is
    still hard-cut, so the length guarantee holds for every input. So is a name
    whose only boundary is right at the start (`a <sixty-character-word>`),
    because backing up to it would name the room `a` — a truncated word reads
    better than one letter, and both are safe.
    """
    s = _slug_base(name)
    if len(s) > _SLUG_MAX and s[_SLUG_MAX] != "-":
        cut = s[:_SLUG_MAX]
        at = cut.rfind("-")
        s = cut[:at] if at >= _SLUG_MIN_WORD_CUT else cut
    else:
        s = s[:_SLUG_MAX]
    return (s.strip("-") or "program")


def _program_room(sidecar, name):
    """The room DIRECTORY NAME a program called `name` lives in, in `sidecar`.

    S128 / FL-005 (b), and the whole difficulty of that cure. `_slug`'s output
    IS the directory of every program the captain has already made, so a new
    algorithm applied blind would leave his existing rooms stranded: `start`
    with the same name would build a SECOND room beside the first, and the
    mockup, transcript and concept doc he already has would sit in a room
    nothing routes to any more. A durable-programs regression is far worse than
    an ugly name (that is S126's whole point).

    So the resolution is: the new name, UNLESS the old name is a directory that
    really exists and the new one is not. Nothing is renamed, moved or
    rewritten — an old room keeps its old name forever and simply stays
    reachable, which is also what `holodeck_open` already does (it takes the
    room off the program list and never re-slugs anything).
    """
    new = _slug(name)
    old = _slug_legacy(name)
    if old != new and not os.path.isdir(os.path.join(sidecar, new)) \
            and os.path.isdir(os.path.join(sidecar, old)):
        return old
    return new


# ── S172 fix round 1 (D1): a room that can be TOLD APART from the one it was
# copied from ───────────────────────────────────────────────────────────────
# `_slug` caps a room at `_SLUG_MAX`, and that cap is not a label — it is the
# PERMANENT identity of every room already on the captain's disk, so it cannot
# be raised for one feature. But every program he actually has is named with his
# whole idea sentence, which reaches the cap: so a differentiator written into
# the DISPLAY NAME and then slugged ("X (copy 2)") lands on the FAR SIDE of the
# cut and disappears. Measured on his real program: 500 candidate names, ONE
# distinct room, and that room was the source's own.
#
# So a duplicate's room is BUILT rather than derived — the name is trimmed to
# leave the marker room, and the marker is appended AFTER the cut where nothing
# can eat it. Short names are unaffected: "Command palette" gives
# `command-palette-copy` either way, which is what every room made before this
# fix is called.
def _trim_slug(s, cap):
    """An ALREADY-SLUGGED string cut to `cap`, by `_slug`'s own rule.

    Same word-boundary preference and same "too short a stump is worse than a
    truncated word" fallback (FL-005), at a cap the caller chooses. `_slug`
    itself is deliberately left alone: it names every existing room, and this
    round is not the place to re-derive those.
    """
    if cap < 1:
        return "program"
    if len(s) <= cap:
        return s
    cut = s[:cap]
    if s[cap] != "-":
        at = cut.rfind("-")
        if at >= cap // 2:
            cut = cut[:at]
    return cut.strip("-") or "program"


def _room_with_marker(name, marker):
    """The room for `name` with `-<marker>` appended, still inside `_SLUG_MAX`."""
    tail = "-%s" % marker
    return _trim_slug(_slug(name), _SLUG_MAX - len(tail)) + tail


def _duplicate_room(name, n):
    """The room the `n`th copy of a program called `name` lives in."""
    return _room_with_marker(name, "copy" if n <= 1 else "copy-%d" % n)


# ── S126: the program's own record, on disk ─────────────────────────────────
# THE ROOM IS THE ARCHIVE. S124 already gave every program a room at
# `<sidecar>/<slug>/` and S125 already committed it once per turn; what was
# missing is the CONVERSATION — so a room on disk was a mockup nobody could
# read the reasoning for, and a daemon restart threw the reasoning away.
#
# Deliberate divergence from the S126 brief: the room stays at
# `<sidecar>/<slug>/` and is NOT moved to `<sidecar>/programs/<slug>/`. The
# brief predates S125, which shipped the room, the jailed preview route and the
# committed browser rig against that layout; moving it would break all three to
# buy nothing.
_TRANSCRIPT = "transcript.md"
_CONCEPT = "concept.md"
# S170 — the grounding record, named ONCE. `_basis_file_in` already
# owned this literal for the header link; the derivation reads the same
# file as context, and two spellings of one filename is how a surface
# and a worker start disagreeing about which document exists.
_BASIS = "basis.md"
# S169 (FL-014) — where a pasted reference screenshot is kept. One
# subdirectory of the room, named after a mission's `attachments/` (S92)
# because it is the same idea one surface over: the input a design was built
# FROM, kept beside the design. Under the room, so the room's own per-turn
# commit, the preview jail and copilot's `--add-dir` grant all already cover it.
_ROOM_ATTACHMENTS = "attachments"

# The entry delimiter, written AND parsed here. The parse is best-effort and for
# DISPLAY only — the file itself is the record, and nothing below ever rewrites
# a line the model wrote. A reply that itself contains a line reading
# `## Turn <n> ·` would split oddly on the way back; the sequence check makes
# that need the exact next number, and the cost is a cosmetically split card,
# never a lost character.
_TURN_HEAD = re.compile(r"^## Turn (\d+) ·", re.MULTILINE)

# ── FIX ROUND 5: the engine, recorded where the NAME is recorded ─────────────
# A program did not remember which CLI built it. `holodeck_open` took `engine`
# from the caller and fell back to the daemon's default, the deck posted no
# engine at all, and nothing on disk held one — so a restart re-pointed a
# program at whatever the viewscreen happened to be started with. Measured
# live: a program designed entirely on claude reopened on copilot, and the next
# turn really ran there.
#
# The cheap direction is the one that costs: a program built on FREE copilot
# silently reopening on BILLED claude, in the room whose whole stated posture
# is "this is the cheap one".
#
# It goes in `transcript.md`'s header, beside the `# ` name heading — the ONE
# durable home a program's identity already has, written at the same moment by
# the same function and read back by the same parser. No sidecar json, no
# per-room metadata file: a second place to look is how the engine came to
# arrive from three sources with a different winner per path.
_ENGINE_LINE = re.compile(r"^_Engine: `([^`\n]+)`", re.MULTILINE)
# S169 fix round 1 — the attachments a turn carried, in the durable record.
# `_transcript_entry` writes it, `_parse_transcript` reads it; a turn written
# before this existed simply has no line and answers no attachments.
_ATTACHED_LINE = re.compile(r"^_Attached this turn: (.+?)_\s*$", re.MULTILINE)

# ── S127: the HAND-OFF, recorded in the same one durable home ────────────────
# D11's lifecycle needs two durable facts about a program: that it was SENT, and
# WHICH mission holds it. They go exactly where the engine went, for exactly the
# reason fix round 5 put the engine there — the program's identity already has
# one durable home, and a second place to look is how a value comes to arrive
# from three sources with a different winner per path.
#
# It is written INTO THE HEADER, above the first turn, and read back from the
# header only: a reply that quotes this line is the model being quoted at, and
# taking it as the program's own state would let a turn lock itself. Nothing a
# model wrote is ever rewritten — the insert lands in the block LCARS itself
# authored when the program was named.
_SENT_LINE = re.compile(
    r"^_Sent to Align: mission `([^`\n]*)`(?: at ([^_\n]*))?.*$", re.MULTILINE)


def _sent_header_line(mission_id, when):
    return ("_Sent to Align: mission `%s` at %s_ — this program was handed "
            "over and is READ-ONLY. The mission was briefed on the files "
            "exactly as they were at that moment.\n\n"
            % (mission_id or "", when))


def _parse_sent(text):
    """`{"missionId":…, "at":…}` if this program's record says it was SENT.

    HEADER ONLY, for the same reason `_parse_transcript` reads the engine from
    the header only."""
    text = (text or "").replace("\r\n", "\n")
    head = re.split(r"^## ", text, maxsplit=1, flags=re.MULTILINE)[0]
    m = _SENT_LINE.search(head)
    if not m:
        return None
    return {"missionId": (m.group(1) or "").strip(),
            "at": (m.group(2) or "").strip()}


# ── S172: the DUPLICATE's lineage, in the SAME one durable home ─────────────
# A sent program is locked forever, and the way on is a DUPLICATE that carries
# the chat — a NEW program continuing an old design. The two facts it must never
# lose are WHICH program it came from and WHICH mission that program was filed
# as, so a room can still say what it came from long after the daemon that made
# it is gone.
#
# It goes exactly where the engine (fix round 5) and the hand-off (S127) went,
# for exactly the reason those went there: `transcript.md`'s header is the ONE
# durable home a program's identity already has, and a second place to look is
# how a value comes to arrive from three sources with a different winner per
# path. HEADER ONLY on the way back, for the same reason `_parse_sent` is: a
# reply that quotes this line is the model being quoted at, and taking it as the
# program's own state would let a turn invent its own ancestry.
#
# EVERY FIELD IS BACKTICK-DELIMITED so the parse cannot be confused by prose. A
# backtick inside a program NAME would break that, so the writer replaces it —
# the name of record is the `# ` heading, and this line is lineage.
_ORIGIN_LINE = re.compile(
    r"^_Duplicated from `([^`\n]*)` · program `([^`\n]*)` · mission "
    r"`([^`\n]*)` · at `([^`\n]*)`_.*$", re.MULTILINE)


def _no_ticks(text):
    return str(text or "").replace("`", "'")


def _origin_header_line(room, program, mission_id, when):
    return ("_Duplicated from `%s` · program `%s` · mission `%s` · at `%s`_ — "
            "this is a NEW program carrying that one's conversation, so it is "
            "possible to see why the design looks the way it does. NOTHING IN "
            "THAT RECORD IS BINDING. The original is untouched and stays "
            "exactly as it was handed over.\n\n"
            % (room, _no_ticks(program), _no_ticks(mission_id), when))


def _parse_origin(text):
    """`{"room":…, "program":…, "missionId":…, "at":…}` if this program's record
    says it is a DUPLICATE of another one, else None."""
    text = (text or "").replace("\r\n", "\n")
    head = re.split(r"^## ", text, maxsplit=1, flags=re.MULTILINE)[0]
    m = _ORIGIN_LINE.search(head)
    if not m:
        return None
    return {"room": (m.group(1) or "").strip(),
            "program": (m.group(2) or "").strip(),
            "missionId": (m.group(3) or "").strip(),
            "at": (m.group(4) or "").strip()}


# ── S172, TRAP 2: the inherited grounding says so IN THE FILE ───────────────
# `basis.md` is stale BY CONSTRUCTION on a duplicate, and worse here than
# anywhere: the captain duplicates a program precisely because its mission has
# landed, which is exactly when the app it was read from has MOVED.
#
# The ruling taken is CARRY IT AND MARK IT. Re-grounding would be a live worker
# spawn on a click — money on a gesture the captain reads as "copy this" — and
# dropping it would throw away the one document that makes a design correctable.
# So the grounding comes over whole, with a banner at the top of the file the
# captain and the worker both read, and the payload the deck renders says the
# same thing in the same words.
_BASIS_INHERITED_HEAD = "> ⚠ INHERITED GROUNDING — POSSIBLY STALE"


def _basis_inherited_banner(program, when):
    return ("%s\n>\n"
            "> This is NOT a fresh look at the project. It is the grounding "
            "LCARS read for “%s” (last written %s), copied over when "
            "that program was duplicated. If that design has been built since, "
            "the app has moved and the tokens, spacing and component shapes "
            "below describe what it USED to be.\n"
            "> Treat it as history: check anything you build on it against the "
            "project as it is now.\n\n"
            % (_BASIS_INHERITED_HEAD, program or "the original program", when))


def _basis_with_inherited_mark(text, program, when):
    """The basis, banner-first. Idempotent by re-marking, never by stacking.

    A duplicate OF a duplicate would otherwise carry two banners, the older one
    naming a program two generations back — a file that says the same thing
    twice about different things is a file nobody reads.
    """
    body = (text or "").replace("\r\n", "\n").lstrip("\n")
    if body.startswith(_BASIS_INHERITED_HEAD):
        parts = body.split("\n\n", 1)
        body = parts[1] if len(parts) == 2 else ""
    return _basis_inherited_banner(program, when) + body


def _transcript_header(program, engine=None):
    out = ["# %s\n\n" % (program or "Untitled program")]
    if engine:
        out.append("_Engine: `%s`_ — the CLI this program was designed on. "
                   "LCARS picks it back up on the same one.\n\n" % engine)
    out.append("The holodeck's record of this program: one entry per turn, in "
               "the order it happened, appended by LCARS as it happens. The "
               "mockup is the picture; this is the conversation that produced "
               "it, and it is what a later session is handed when the program "
               "is picked back up.\n")
    return "".join(out)


def _transcript_entry(n, text, reply, files, grounding=False, attachments=None):
    """ONE turn, as it goes into `transcript.md`. Nothing is summarised away.

    S169 FIX ROUND 1 — `attachments` names what the captain pasted INTO this
    turn. It goes ABOVE his line rather than below it, deliberately: the parser
    reads his words from the `**Captain:**` marker to the `**Holodeck:**` one,
    so a line between the two would be silently absorbed into what he said.
    """
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    out = ["\n## Turn %d · %s\n" % (n, stamp)]
    if attachments:
        out.append("\n_Attached this turn: %s_\n" % ", ".join(attachments))
    if grounding and not text:
        out.append("\n_The opening grounding pass — one read-only look at the "
                   "project._\n")
    elif text:
        out.append("\n**Captain:** %s\n" % text)
    if reply:
        out.append("\n**Holodeck:** %s\n" % reply)
    if files:
        out.append("\n_Files this turn: %s_\n" % ", ".join(files))
    return "".join(out)


def _parse_transcript(text):
    """(program name, [{text, reply}], engine) read out of a `transcript.md`.

    Tolerant on purpose: a file it cannot make sense of yields whatever it
    could, never an exception — the captain's archive must open even if a
    future format change made half of it unfamiliar. A record with no engine
    line (every program written before fix round 5 has none) answers "" and is
    handled as UNKNOWN by the caller, never as the default.
    """
    text = (text or "").replace("\r\n", "\n")
    name = ""
    for line in text.split("\n"):
        if line.startswith("# "):
            name = line[2:].strip()
            break
        if line.startswith("## "):
            break
    # THE HEADER ONLY. A reply that happens to contain an `_Engine: `…`_` line
    # is the captain being quoted at, and repointing his program at it would be
    # the model choosing what it runs on.
    head = re.split(r"^## ", text, maxsplit=1, flags=re.MULTILINE)[0]
    em = _ENGINE_LINE.search(head)
    engine = em.group(1).strip() if em else ""
    turns = []
    heads = [m for m in _TURN_HEAD.finditer(text)]
    for i, m in enumerate(heads):
        # only a properly sequenced head opens a turn (see `_TURN_HEAD`).
        try:
            if int(m.group(1)) != len(turns) + 1:
                continue
        except ValueError:                       # pragma: no cover - defensive
            continue
        end = heads[i + 1].start() if i + 1 < len(heads) else len(text)
        block = text[m.end():end]
        said = None
        reply = None
        # S169 fix round 1 — what he ATTACHED to this turn, read back off the
        # record so a REOPENED program's chat still names the sketch it was
        # designed from. Written by `_transcript_entry`; see there for why it
        # sits above his line and not below it.
        #
        # ONLY THE PART ABOVE HIS LINE, for the same reason `_parse_transcript`
        # reads the engine from the header only: a reply that happens to quote
        # this line is the model being quoted at, and letting it name an
        # attachment would put a file that does not exist into the record's own
        # reading of itself.
        am = _ATTACHED_LINE.search(
            re.split(r"^\*\*Captain:\*\* ", block, maxsplit=1,
                     flags=re.MULTILINE)[0])
        attached = [a.strip() for a in am.group(1).split(",")
                    if a.strip()] if am else []
        cm = re.search(r"^\*\*Captain:\*\* ", block, re.MULTILINE)
        hm = re.search(r"^\*\*Holodeck:\*\* ", block, re.MULTILINE)
        if cm:
            stop = hm.start() if (hm and hm.start() > cm.end()) else len(block)
            said = block[cm.end():stop].strip()
        if hm:
            tail = block[hm.end():]
            tail = re.split(r"\n_Files this turn: ", tail)[0]
            reply = tail.strip()
        turn = {"text": said, "reply": reply}
        if attached:
            turn["attachments"] = attached
        turns.append(turn)
    return name, turns, engine


def _turn_summary(text, grounding=False):
    """The one-line turn summary that becomes the commit message.

    A commit log reading `turn 1 / turn 2 / turn 3` is a serial number, not a
    story — `git log --oneline` over the sidecar is meant to BE the program's
    audit trail (D7's "every turn is committed" made legible).
    """
    if grounding and not text:
        return "grounding pass"
    line = re.sub(r"\s+", " ", str(text or "")).strip()
    if not line:
        return "opening turn"
    return line[:72] + ("…" if len(line) > 72 else "")


# ── S126 (#3): the concept-doc contract, as the turn prompt states it ───────
# The markdown half of the output. It is the thing a Mission's Align is handed
# at S127, so its shape is DECLARED here rather than left to whatever the model
# felt like writing — and two of its sections exist because of specific captain
# rulings:
#
#   WHAT IT MUST DO (D14). The captain states functional requirements OUT LOUD
#       while designing pixels ("it remembers what you picked", "no flash of the
#       wrong theme"). Un-captured, they died in the transcript and Align was
#       handed "a light/dark theme toggle". Captured IN HIS OWN WORDS and
#       attributed to the turn, they are a brief. Behaviour only — visual
#       decisions are in the mockup, which is the whole reason for having one.
#
#   DECLARED FLOW (D4, captain ruling 2026-08-04). Screens and transitions are
#       NAMED, never inferred from the markup: inference over prose drifts
#       silently and flatters itself (the S156 lesson), and a declaration is
#       DRIVABLE — the browser walker can walk it against the mock to generate
#       the per-screen stills and to catch a concept doc that has drifted from
#       its own mockup. Kept small enough for a person to write by hand.
_CONCEPT_CONTRACT = """
ALSO KEEP `concept.md` CURRENT, in the same room, updated in the same turn you
change the mockup. It is the WRITTEN half of this design and it is what a real
Mission is handed later; the mockup carries the look, this carries the meaning.
Sections:

  # <the program>
  ## The problem — what the captain is trying to solve, in two or three lines.
  ## Decisions — what has been SETTLED, each with the turn it was settled on,
     and WHY. This is the REASONING RECORD, not the change list: what the
     mockup finally looks like is read off the mockup itself when this program
     is handed over, so an entry here earns its place by explaining a choice —
     what was decided, and the reason the captain gave for it.
     WRITE THE END STATE AND THE REASON, NEVER THE PATH. This section is a log
     of a conversation, and a conversation contains you correcting your OWN
     earlier drafts. Nobody downstream has seen those drafts. So never write an
     entry about what an earlier version of the mockup had, what was taken back
     out of it, or what you got wrong on turn 2 — "the T1 mock had a two-part
     toggle → now one button" is a note to yourself, and read later it becomes
     an instruction to go and change the captain's real app.
     ONE SUBJECT PER ENTRY: the decision as it now stands, plus the reason.
  ## Open questions — what is still undecided. Raise these in the chat too.
     ONE HOME EACH: anything the MOCKUP implies belongs in bucket 2 below and
     not here. Write each undecided thing in exactly one of the two places —
     the captain is shown both lists and must not read the same thing twice.
     THE MOMENT ONE IS SETTLED IT LEAVES THIS LIST. Delete the bullet outright
     and write the answer into `## Decisions` with the turn that settled it.
     Never annotate a question in place ("… **Settled T3: keep emerald.**")
     and never leave a tombstone behind ("(Theme default — settled T3, moved
     to Decisions.)"): this list is read as a list of things NOBODY HAS
     ANSWERED, so a settled entry left sitting in it costs the captain a
     question he has already answered — a real interruption, spent on nothing.
     An empty `## Open questions` is a correct and common state; say so.
     A VARIATION YOU ONLY PARTLY DREW BELONGS HERE, and the one-home-each rule
     does NOT send it to bucket 2. When a row, card or screen differs by state,
     source, shape or mode, cross those differences: two axes make a grid and a
     drawing rarely fills it. NAME THE AXES THIS DESIGN VARIES BY, IN THE WORDS
     OF THIS DESIGN — read them off the captain's brief and your own mockup.
     Write every cell you did NOT draw as a bullet opening with this marker,
     every slot filled from YOUR design:
       - UNDRAWN COMBINATION: <first axis> (<its values>) x <second axis>
         (<its values>) — DREW: <the cells drawn>. NOT DRAWN: <the missing
         cell>. <the question the captain has to answer>?
     WHY, ON A DIFFERENT PROGRAM WHOSE WORDS ARE NOT YOURS: a scorecard drawn
     with 3 manual rows, 11 cohort rows and ZERO that were both. Nobody said
     so; the build made every cohort read-only whether manual or not, and the
     captain got a "Manual" tag on a list he could not type into. Do not answer
     it yourself, and do not draw the missing cell to make it go away — ASK.
  ## WHAT IT MUST DO — BEHAVIOUR ONLY (visual choices live in the mockup).
     Three buckets, kept apart:
       1. Requirements — stated behaviour, numbered, in the captain's OWN WORDS,
          each attributed to the turn it was said in.
       2. Implied by the mockup, not yet settled — behaviour the mockup suggests
          that nobody has actually stated. Write each as a QUESTION, and ASK it
          in the chat: a sentence now is cheaper than a ticket later. A screen
          the mockup DRAWS but nothing WIRES UP (a status bar with no data
          behind it, a toggle that forgets) belongs here — that is exactly the
          half a builder cannot see in a picture.
       3. Out of scope — what he explicitly ruled out, kept so nobody builds it
          back by accident.
     Never invent a requirement he did not say.
     AN EMPTY BUCKET IS EMPTY — write the heading and NOTHING under it. Never a
     bullet saying there is nothing ("- (none — those were answered in T2)"),
     and never a note explaining why it is empty. The captain reads these
     buckets as a list of things he has to deal with, and a bullet that is not
     one of those is a heading, a caption and a line of his brief spent on
     nothing.
  ## DECLARED FLOW — name the screens and the transitions between them, one per
     line, small enough to write by hand:
       `board` → click `.card` → `detail` → Esc → `board`, scroll preserved
     A screen the mockup has but this section does not name is invisible to
     everything downstream, so declare every one.
  ## DATA PRECONDITIONS — what this drawing ASSUMES is already TRUE of the
     target repo's data or config. Write each as a MARKDOWN BULLET, and make it
     ONE CHECKABLE SENTENCE EACH:
       - most KPIs carry an automated collection instruction
       - at least one prior month has already been published
     IF YOU DREW A COUNT, A PROPORTION, A LIST LENGTH, A STATUS OR A TIMESTAMP
     THAT COMES FROM THE REPO, THIS SECTION IS NOT EMPTY. EMPTY IS ALLOWED, but
     it is rarely right: only a design that touches no repo data at all — a
     restyle, a spacing pass, a palette — leaves it as the heading, and NOTHING under it.
     Never a bullet saying there are none, never a line explaining why.
     THIS IS NOT bucket 2, and the ONE-HOME-EACH rule does not send it there. An
     assumption about BEHAVIOUR NOBODY HAS STATED is a bucket-2 question; an
     assumption about WHAT IS ALREADY IN THE REPO'S DATA is a precondition and
     belongs HERE, even if you also asked about it up there.
     STATED, never inferred — nothing downstream can recover an assumption you
     did not write down.
     NAME THE FIELD OR THE FILE YOU EXPECT (`aiUpdateInstructions`,
     `data/config.json`, `accents.ts`) so the check knows what to look for. A
     sentence naming nothing checkable comes back marked UNCHECKED, not answered.
     AND SAY WHAT IT ASSUMES ABOUT THE VALUES, NOT ONLY THE FIELDS — how many,
     how much, how full: "most KPIs are CURRENTLY on automatic collection", not
     merely "each KPI has a collection mode". A repo can carry every field you
     named and have none of them filled in, and the screen you drew is still
     UNREACHABLE. This is the one everybody forgets.
"""

# ── S169 (FL-015): NOT EVERY TURN IS A BUILD TURN ──────────────────────────
# The captain, on the S128 drive: *"I asked it what is it mean by the events tab
# and it's doing a long 'rendering to holodeck' turn. This was a question about
# its design, not a request to update the UI."* And, sharpening it: *"To be
# clear it answered my question, but also spent a lot of time on the events tab.
# Would be better to answer and let me guide then waste time on a render
# update."*
#
# So the answer was NOT suppressed. The model answered him AND rebuilt part of
# the mockup he had not asked it to touch — unrequested design drift, authored
# by the product, into the artifact that becomes an acceptance criterion for
# real work. This round's own theme (FL-011) one stage earlier.
#
# THE MECHANISM WAS THE PROMPT, both halves of it: the continuation was the
# unconditional "The captain says: %s — Make the change, then reply…", and the
# opening envelope frames every turn as `WHAT YOU BUILD` + `REPLY SHORT`. A
# question handed to a worker inside that frame gets exactly what it was told.
#
# WHAT IS DELIBERATELY NOT HERE: any classifier. Nothing in this daemon looks at
# the captain's sentence and decides whether it is a question. This project has
# lost whole sessions to exactly that — S156's regex classifier fell 14/14 → 5/14
# on a meaning-preserving rewording, S147 lost four generations of a source
# parser, S157 five versions of a guard — and the cure every time was DELETING
# the signals and moving the decision to a DECLARATION. There are two
# declarations here and no guesses:
#
#   1. `_ANSWER_THEN_STOP` — the default. The prompt tells the MODEL, which has
#      his actual sentence, that answer-then-stop is the right move on a turn
#      that is not a direction. The decision moves to the only reader that sees
#      what he wrote, not to a matcher that sees a pattern.
#   2. `_ASK_DECLARED` — the captain's own explicit declaration, made on the
#      composer BEFORE he sent the turn (`intent="ask"`). It is optional by
#      construction: he never has to flip it to ask a question, because (1)
#      already covers him. When he does flip it there is nothing left to infer.
#
# And the OUTCOME is published as a fact — see `_turn_outcome`. "He asked, and
# nothing was written" is read off the audit the daemon already runs, not
# inferred from his words; a turn that answered AND wrote is equally visible.
# That is the shape that would have caught this defect on the drive.
_ANSWER_THEN_STOP = """
NOT EVERY TURN IS A BUILD TURN. If the captain is ASKING rather than DIRECTING —
about your design, about a choice you made, about what something on the screen
means — then ANSWER HIM AND CHANGE NOTHING. Do not also make an improvement
while you are in there: not a tidy-up, not a small fix, not the thing you were
about to suggest anyway. Editing the mockup on a turn he did not direct puts
design he never asked for into the file that becomes the specification for real
work, and it spends his time on work he did not want.

On a turn like that, answer him properly — take as many words as the question
deserves; the short-reply rule does not apply to an answer — and if a change
follows from what you just said, OFFER it in one sentence and let him take it
next turn. He will tell you to build it if he wants it.

When he IS directing, build it. Answer-then-stop is the default only when the
turn is not a clear direction; a turn you are sure about is not ambiguous, and
handing every doubt back to him is its own failure.
"""

_ASK_DECLARED = """
THE CAPTAIN DECLARED THIS TURN A QUESTION. He set it on the composer, himself,
before he sent it — so there is nothing for you to work out. He is ASKING; he is
not directing a change.

ANSWER HIM AND CHANGE NOTHING. Do not edit `mockup.html`, do not edit
`concept.md`, do not write any file at all this turn — not even a small
improvement you are certain is right. Answer as fully as the question deserves;
there is no short-reply rule on this turn. If a change follows from your answer,
OFFER it in a sentence so he can ask for it on the next turn.
"""

# S128 — `## Hand-off summary` IS GONE FROM THE CONTRACT, deliberately.
# It used to be the one paragraph `promote` drafted the brief from, and it was
# the only section here nothing asked the model to keep CURRENT turn by turn —
# so the brief was a snapshot of an older conversation. That is FL-011, and it
# is what silently dropped a requirement the captain stated verbatim twice.
#
# The brief is now built from `## WHAT IT MUST DO` (`_handoff_brief`), which the
# contract above does demand every turn, and no reader anywhere names the
# summary at all — so as of this session NOTHING READS IT. Asking a model to
# maintain a section no code consumes is how the defect comes back: the next
# reader assumes something downstream needs it and drafts from it again. Either
# it is regenerated on the same turn as the requirements or it does not exist,
# and there is no reason for it to exist.


# ── S127: THE HAND-OFF — what a Mission is told the mockup MEANS ────────────
# The captain's requirement, in his own words, is two obligations pulling in
# opposite directions: the built product must MATCH the mockup visually, while
# LCARS must understand the mockup is NOT a working product. Carry only one and
# the round fails in one of two ways —
#
#   Failure 1, the mock is IGNORED. Cured by making visual fidelity an explicit
#       ACCEPTANCE CRITERION rather than an attachment a worker may look at.
#       This repo's own board was vendored from `kanban-vision.html` with "high
#       visual fidelity to the mockup" as the acceptance bar (S67/S68), so the
#       precedent is that it works when it is GRADED.
#   Failure 2, the mock is mistaken for THE PRODUCT. The structural half of the
#       cure is that the mockup never enters the working tree at all (it lives
#       in the sidecar and in `.git/lcars/missions/<id>/attachments/`). The
#       DECLARATION below is defence in depth for the day one does: S164
#       measured a live worker correctly refusing a decoy because SEVERAL
#       places it could not miss all said the same thing, and S166 measured a
#       live worker ignoring the same claim made in exactly ONE place.
#
# These are the words themselves, held here so the daemon is the one voice that
# says them: the deck SHOWS this block before the captain sends, and the daemon
# APPENDS this same block to the filed idea. The browser composes none of it —
# what he read and what the mission was told cannot drift.
_HANDOFF_FILES = ("mockup.html", _CONCEPT)

_HANDOFF_SCOPES = ("look+behaviour", "look-only")

# THE LOAD-BEARING SENTENCE (captain ruling, 2026-08-04). It is the one rule
# that resolves the failure this round manufactures — a worker treating the
# mockup's fake internals as the specification. Spelled once, used everywhere.
#
# ⚠ RECIPROCAL PIN: "everywhere" now includes BASH. `lcars_attach_mockup_note`
# in skills/lcars-init/lcars-common.sh ends with this sentence and cannot share
# the literal across languages, so `tests/lcars-run-attachments.test.sh` section
# 10 reads THIS constant and pins that note's last line to it byte-for-byte.
# Reword one home without the other and that check fails naming both.
#
# S128 REWORDING (FL-011, A4a). It used to read, in full, "Where the mockup and
# the brief disagree, the brief wins." That is correct as a TIE-BREAK and it was
# read as a claim of COMPLETENESS. On the S127 capstone a cold Research worker
# found a `#themeToggle` the mockup implemented and the brief never mentioned —
# because the brief had been drafted from a stale paragraph — asked exactly the
# right question, and then resolved it toward the loss because this sentence
# told it to. The override survives; the completeness claim is denied in the
# same breath, in the same string, so the two can never be separated.
#
# ── S169 FIX ROUND 1: THE OVERRIDE IS SPLIT BY DOMAIN ───────────────────────
#
# MEASURED on the tester's live copilot drive, 2026-08-06. The brief for a real
# program room carried "Turn 2 — Kept the `.brand` \"Waypoint\" label and the
# \"New trip\" button from the existing topbar" — and the mockup in the SAME
# room rebuilt both (`Way<span class="dot">•</span>point` with an accent dot; the
# button promoted to `class="primary"`, accent-filled, 700 weight). The brief is
# derived from `## Decisions`, which is an ACCOUNT OF THE CONVERSATION written
# by the same model that drew the picture, and an account can be wrong about the
# picture.
#
# The sentence above then AMPLIFIED it: an implementer reading "kept … from the
# existing topbar" leaves the top bar alone, and this rule told it the brief
# outranks the mockup that says otherwise. "Top bar unrestyled" is the captain's
# original S128 complaint, arrived at by a new route.
#
# THE CURE IS A DOMAIN SPLIT, NOT A DETECTOR. Nothing anywhere reads a line and
# decides whether it is true — that is S156's classifier (14/14 → 5/14 on a
# reworded corpus), S147's source parser, S157's guard. What is stated instead
# is a fact about the two documents that holds for every program ever made here:
#
#   the brief is an ACCOUNT of a design conversation → authoritative on WHAT IT
#       MUST DO, the half a picture cannot carry;
#   the mockup is THE ARTIFACT ITSELF → authoritative on HOW IT LOOKS, the half
#       it IS.
#
# So a false "kept" line can still be written, and still rides — the daemon
# never reads `basis.md` and cannot verify one word of it — but it can no longer
# outrank the picture it contradicts.
_HANDOFF_PRECEDENCE = (
    "Where the mockup and the brief disagree about WHAT IT MUST DO, the brief "
    "OVERRIDES the mockup. That is a TIE-BREAK, not a claim that the brief is "
    "exhaustive — the brief can be missing something the mockup has. Where they "
    "disagree about HOW IT LOOKS, it is the other way round: the mockup is the "
    "authority and OVERRIDES the brief, including any line of the brief that "
    "says a thing was kept or left unchanged. The mockup IS the design; the "
    "brief is an ACCOUNT of the conversation that drew it, written afterwards, "
    "and an account can describe the picture wrongly.")

# S128 (A4b). The second half of the same cure, and the one that changes what a
# worker DOES. A disagreement is evidence about the HAND-OFF, not a question the
# stage is equipped to settle: the brief is drafted from a design conversation
# and a conversation can lose things.
#
# HONESTY ABOUT THIS LAYER: these are words handed to a model. The suite can
# prove they exist and that they reach the mission verbatim. Whether a cold
# worker obeys them is a model choice and only a live drive measures it.
#
# S169 FIX ROUND 1 — AND IT ONLY EVER NAMED ONE DIRECTION. "If the mockup shows
# something the brief never mentions" is the OMISSION case. The defect measured
# on the 2026-08-06 drive is the other one: the brief stating, in a list titled
# as settled decisions, that something was KEPT — while the mockup plainly
# changed it. That is not a gap in the account, it is the account being WRONG,
# and a worker with no rule for it reads the confident sentence and stops.
_HANDOFF_DISAGREEMENT = """\
- A DISAGREEMENT between the mockup and the brief is EVIDENCE, not a decision \
for you to make. If the mockup shows or implements something the brief never \
mentions, treat that as a sign the hand-off may have LOST a requirement the \
human actually stated. ESCALATE it (`lcars:awaiting-human`) and name what the \
two sides say, rather than resolving it yourself. A stage that quietly picks a \
side produces work that is correct against its brief and wrong against the \
person who asked for it — and every gate downstream will pass it.
- The same applies when the brief CONTRADICTS the mockup rather than missing \
it — and one shape of that is easy to walk straight past: a brief line saying \
some element was KEPT, left UNCHANGED or carried over from the app as it is \
today, when the mockup has plainly redrawn it. The brief's change list is \
written from the design conversation, not read off the mockup, so such a line \
is the account being wrong about the picture. BUILD WHAT THE MOCKUP SHOWS \
(look is its call — see the precedence rule) and ESCALATE the contradiction so \
a human sees it; never read it as an instruction to leave that element alone."""

_HANDOFF_COMMON = _HANDOFF_DISAGREEMENT + """
- The mockup defines LOOK AND FLOW: layout, colour, spacing, wording, and the \
transitions between screens. Matching it visually is an ACCEPTANCE CRITERION of \
this work, not a suggestion.
- The mockup is NOT an implementation. Its internals are deliberately fake — \
hand-written to look right and wired to nothing. Nothing in it is code to copy, \
import, edit or ship.
- The mockup and the concept doc are REFERENCE ATTACHMENTS. They are not in \
this repository's working tree and they never enter it; they are not files this \
work may change, and a bug is never fixed by editing them.
- What a mockup CANNOT convey is feel — timing, weight, responsiveness. Named \
values (durations, easings) are in the concept doc; the rest is judged by the \
captain at the Verify gate."""

_HANDOFF_SCOPE_TEXT = {
    "look+behaviour": (
        "- HOW MUCH TO BUILD: look AND behaviour. Build it for real — backend, "
        "state, persistence, the lot. The mockup says how it LOOKS; the brief "
        "above says WHAT IT MUST DO. The mockup's own interactions are "
        "illustrative only.\n- " + _HANDOFF_PRECEDENCE),
    "look-only": (
        "- HOW MUCH TO BUILD: look ONLY. This is a reskin — match the mockup "
        "visually and make NO FUNCTIONAL CHANGE. Same data, same actions, same "
        "outcomes. \"No functional change\" is a constraint on this work, not a "
        "preference.\n- " + _HANDOFF_PRECEDENCE),
}


def _handoff_guidance(scope):
    """The guidance block, for one build scope. Shown on the deck and appended
    to the filed idea — the same string, from the same place, both times."""
    return ("## How to read the attached mockup\n\n"
            + _HANDOFF_SCOPE_TEXT[scope] + "\n" + _HANDOFF_COMMON + "\n")


# ── S128 (FL-011): the brief is drafted from what the product MAINTAINS ─────
#
# It used to be drafted from `## Hand-off summary` — "one paragraph a Mission
# can open with" is literally what that section is for, so the choice was
# reasonable and it was wrong. The turn prompt (`_CONCEPT_CONTRACT`) asks the
# model to keep `WHAT IT MUST DO` current on EVERY turn and says nothing about
# regenerating the summary, so the two drift the moment a requirement arrives
# late in a conversation — and late requirements are the norm.
#
# On the S127 capstone that drift cost the captain his theme: he asked for
# light/dark twice, `WHAT IT MUST DO` captured both in his own words, and the
# summary — written before the subject came up — still said "built strictly on
# the existing dark palette… Nothing new is coloured". The brief was that
# paragraph, so the mission's `idea.md` had ZERO theme mentions and its PRD put
# new colour explicitly out of scope.
#
# So the summary is OFF the brief path entirely. It is not demoted to a
# fallback: a section that can be arbitrarily old is not a safer draft than no
# draft at all, and a fallback is exactly how it would come back.
#
# S171 — AND NOW NEITHER IS ANY OTHER SECTION. The degradation ladder that
# followed (`## The problem`, then the doc's first paragraph) is deleted with
# `_handoff_head`, and so is the `summarySource` key that disclosed which rung
# it landed on. The brief's head is the captain's own opening description,
# which exists on every program and which nothing rewrites, so there is no rung
# to fall to. `WHAT IT MUST DO` is still READ — bucket 1 for the dedup, bucket 2
# for the implied section, bucket 3 for out-of-scope — it is simply no longer
# pasted into the brief as a numbered timeline.
_HANDOFF_REQ_HEADING = "WHAT IT MUST DO"
# Bucket 1 of that section (`_CONCEPT_CONTRACT`): "stated behaviour, numbered,
# in the captain's OWN WORDS, each attributed to the turn it was said in."
_HANDOFF_REQ_BUCKETS = ("1. Requirements", "Requirements")
_HANDOFF_QUESTION_HEADING = "Open questions"


def _md_section(text, heading, prefix=False):
    """The body of a `## <heading>` section of a markdown doc, or "".

    Matches the heading loosely (any level, case-insensitive, trailing
    punctuation ignored) because the section names come back from a language
    model, and stops at the next heading of the same or a higher level.

    `prefix=True` also accepts a heading that STARTS with the wanted words: a
    live doc writes `## WHAT IT MUST DO — behaviour only` and
    `### 1. Requirements (captain's words)`, and an exact-match rule silently
    finds neither. The boundary is a whole word, so "Requirements" does not
    match "Requirementsomething".
    """
    lines = (text or "").replace("\r\n", "\n").split("\n")
    want = re.sub(r"[^a-z0-9]+", " ", heading.lower()).strip()

    def hit(name):
        return name == want or (prefix and name.startswith(want + " "))

    out, depth = [], None
    for line in lines:
        m = re.match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if m:
            level = len(m.group(1))
            name = re.sub(r"[^a-z0-9]+", " ", m.group(2).lower()).strip()
            if depth is None:
                if hit(name):
                    depth = level
                continue
            if level <= depth:
                break
            out.append(line)
            continue
        if depth is not None:
            out.append(line)
    return "\n".join(out).strip()


# S128 fix round 1 (D4). These items are shown to the captain under the words
# "what you said, in your own words" — in the ✓/⚠ list, in the pre-drafted
# brief, and inside the amber warning band's own sentence. They were arriving
# as `**Turn 1:** "It has to have a light and a dark theme." — T1` with the
# asterisks literal. The markers are the concept DOC's markdown; they are not
# something the captain typed, and a panel making that claim must not show
# them. Normalised HERE, once, so the brief and the dialog cannot disagree and
# the client keeps rendering exactly what it is handed.
#
# STRONG-EMPHASIS DELIMITERS ONLY (`**…**`, `__…__`), and only where they
# really wrap something. Everything else is left alone, deliberately:
#   · a LONE `*` — `a*b`, `2*3`, `*.css` — is a character in his sentence far
#     more often than it is emphasis, and the pair-matching rule that would
#     find `*italic*` also spans from one literal asterisk to the next. That
#     rule was written, measured eating `a*b and 2*3`, and DELETED. No live
#     doc has been observed using single-`*` emphasis, so it buys nothing and
#     risks the exact class this repo has lost sessions to;
#   · a lone `_` — it lives inside identifiers (`snake_case`) far more often
#     than it is emphasis;
#   · backticks — a code span IS how he names a selector, and the brief is
#     markdown by the time it lands in `idea.md`.
# Nothing here reads prose: these are markdown delimiters, matched as such.
_MD_STRONG = re.compile(r"\*\*(?=\S)(.+?)(?<=\S)\*\*", re.S)
_MD_STRONG_U = re.compile(r"(?<!\w)__(?=\S)(.+?)(?<=\S)__(?!\w)", re.S)
# A markdown heading. STRUCTURE, in a list parser that otherwise only knows
# about list markers — see `_md_items`.
_MD_HEADING = re.compile(r"^\s{0,3}#{1,6}\s")


def _md_plain(text):
    """A markdown list item as a PERSON reads it — emphasis markers removed."""
    s = str(text or "")
    for _ in range(3):                     # `__**both**__` unwraps outside-in
        before = s
        s = _MD_STRONG.sub(r"\1", s)
        s = _MD_STRONG_U.sub(r"\1", s)
        if s == before:
            break
    return s.strip()


def _md_items(body):
    """A markdown list, as ONE STRING PER ITEM, markers stripped.

    Continuation lines are folded into the item they belong to. A live concept
    doc wraps at about 78 columns, so most requirements are two or three
    physical lines — splitting on newlines would shatter one requirement into
    three, and then "lose" two of them at the requirement-diff gate.

    S128 fix round 1 (D5): a HEADING is never an item and never the tail of
    one. The continuation rule used to fold `### 2. Implied by the mockup, not
    yet settled` onto the end of the last requirement, so a sub-heading became
    part of something the captain was told he had said. A heading closes the
    item above it and opens nothing.
    """
    items = []
    folding = False
    for raw in (body or "").replace("\r\n", "\n").split("\n"):
        line = raw.rstrip()
        if not line.strip():
            continue
        if _MD_HEADING.match(line):
            folding = False
            continue
        m = re.match(r"^\s{0,3}(?:[-*+]|\d+[.)])\s+(.*)$", line)
        if m:
            items.append(m.group(1).strip())
            folding = True
        elif folding:
            items[-1] = (items[-1] + " " + line.strip()).strip()
    return [i for i in (_md_plain(i) for i in items) if i]


# S128 fix round 1 (D5) — THE FALLBACK'S REGION. Two structural bugs, and a
# deliberately small fix.
#
# HOW BIG THIS IS, honestly: the live S127 doc writes
# `### 1. Requirements (captain's words)`, which `_HANDOFF_REQ_BUCKETS`
# already matches under `prefix=True`, so the fallback below is NOT what a
# measured engine takes. The defect was found on a tester-written paraphrase
# (`### 1. Stated behaviour, in the captain's own words`), and no live engine
# has been observed producing one. It is HARDENING, not a cure for something
# seen in the wild — which is exactly why it must stay small.
#
# The two bugs are real whatever the heading says:
#   · `_md_items` folded a `###` sub-heading onto the end of the item above it,
#     so bucket 2's HEADING became part of a stated requirement (fixed there);
#   · the fallback read the WHOLE section, so bucket 2 ("behaviour the mockup
#     suggests that nobody has actually stated") and bucket 3 (out of scope)
#     were displayed with a green ✓ under "What you said, in your own words".
#
# THE RULE IS STRUCTURAL: bucket 1 is the region from the top of the section
# to the SECOND sub-heading. The contract numbers its buckets and bucket 1 is
# the first of them, so document ORDER decides where stated behaviour can
# live. NO classifier, NO synonym table, NO fuzzy match — S156 lost a session
# to a regex that guessed at meaning (recall 14/14 → 5/14 on meaning-preserving
# rewordings) and the cure was deleting the signals.
#
# The one thing structure cannot catch is a doc that LOST bucket 1 and opens
# at bucket 2 — the region would then be bucket 2. So there is a second stop,
# and it matches the contract's OWN literal bucket names, exactly as
# `_HANDOFF_REQ_BUCKETS` already matches the contract's own name for bucket 1.
# A self-numbered `2.`/`3.` heading is the structural half of the same stop.
# Used ONLY TO EXCLUDE, never to include: a doc this cannot read reports NO
# stated requirements rather than promoting unsettled ones, because a
# requirement that is merely missing is one the concept doc still carries to
# the Mission as an attachment, while an invented one arrives silent and
# authoritative in the brief itself. (Until S171 a merely-missing one was also
# caught by `_handoff_missing` and carried in LOUDLY; that check is gone and
# the block above its old home says what was accepted.)
#
# S169 — READ FROM BOTH SIDES NOW. `_HANDOFF_IMPLIED_BUCKETS` reuses the first
# name below to FIND bucket 2 and carry it into the brief marked as implied.
# That is the same distinction this list draws, used for the other purpose, off
# the same literal: reword it and both readers move together.
_HANDOFF_NOT_STATED_BUCKETS = ("Implied by the mockup", "Out of scope")
_HANDOFF_NUMBERED_BUCKET = re.compile(r"^\s*[2-9][.)]\s")


def _handoff_not_stated(heading):
    """Is `heading` one of the contract's NOT-STATED buckets (2 or 3)?"""
    if _HANDOFF_NUMBERED_BUCKET.match(heading or ""):
        return True
    name = re.sub(r"[^a-z0-9]+", " ", (heading or "").lower()).strip()
    for bucket in _HANDOFF_NOT_STATED_BUCKETS:
        want = re.sub(r"[^a-z0-9]+", " ", bucket.lower()).strip()
        if name == want or name.startswith(want + " "):
            return True
    return False


def _handoff_stated_region(section):
    """The lines of `## WHAT IT MUST DO` that may hold STATED requirements.

    Everything down to the second sub-heading, or to the first sub-heading
    that is a declared not-stated bucket — whichever comes first. Heading
    lines are kept in the slice and dropped by `_md_items`, which never folds
    one into an item.
    """
    out = []
    seen = 0
    for line in (section or "").replace("\r\n", "\n").split("\n"):
        m = re.match(r"^\s{0,3}#{1,6}\s+(.*?)\s*$", line)
        if m:
            if seen or _handoff_not_stated(m.group(1)):
                break
            seen = 1
        out.append(line)
    return "\n".join(out)


def _handoff_requirements(concept_text):
    """The captain's OWN WORDS, one per item, in the order he said them.

    Bucket 1 of `## WHAT IT MUST DO`, and ONLY bucket 1. Bucket 2 ("implied by
    the mockup, not yet settled") is not a stated requirement and never
    appears here — S169 gave it its own road into the brief
    (`_handoff_implied`), MARKED as implied, which is a different thing from
    being promoted into this list. Keeping those two apart is the whole
    subject of FL-011.
    """
    section = _md_section(concept_text, _HANDOFF_REQ_HEADING, prefix=True)
    if not section:
        return []
    for bucket in _HANDOFF_REQ_BUCKETS:
        body = _md_section(section, bucket, prefix=True)
        if body:
            return _md_items(body)
    # No bucket heading MATCHED. The section is still read (a doc that keeps
    # the heading and drops the structure must not read as "he asked for
    # nothing") — but only as far as bucket 1 reaches. See below.
    return _md_items(_handoff_stated_region(section))


def _handoff_questions(concept_text):
    """`## Open questions`, as `[{"id", "text"}]` in document order.

    Maintained turn by turn and, on the S127 capstone, exactly right — it named
    all five things the captain objected to at Verify. `promote` never read it,
    so the five arrived downstream as settled decisions he never made.

    The ids are positional and are minted by the DAEMON on both roads (promote,
    and again at filing time from the same doc). Nothing the browser sends can
    name a question that is not in the concept doc.
    """
    body = _md_section(concept_text, _HANDOFF_QUESTION_HEADING, prefix=True)
    return [{"id": "q%d" % (i + 1), "text": t}
            for i, t in enumerate(_md_items(body))]


# ── S169: THE OTHER TWO THINGS THE BRIEF HAS TO CARRY ───────────────────────
#
# THE MEASUREMENT. The S128 drive filed a real mission from a real program and
# went Align→Verify hands-off, 9/9 tickets green — and the captain then found
# that the theme and the wired status bar had landed and almost NONE of the
# look had: the top bar unrestyled, the mode glyphs missing, Objects mode still
# carrying a top tab strip where the mockup has a left-hand object list. Read
# off that mission's own plan.json, the cause is one line long: NOT ONE of the
# nine tickets carried a mockup-referencing acceptance criterion. Every worker
# had a vague "match the mock" in its preamble and a precise ticket telling it
# to apply tokens and preserve behaviour, and it did the precise thing.
#
# The pattern is exact: EVERYTHING THAT SURVIVED WAS A STATED REQUIREMENT;
# EVERYTHING LOST LIVED ONLY IN THE PICTURE. It is not a plumbing gap — the
# mockup rides to every stage including `cmd_implement_ticket`. It is that the
# brief said nothing about it, so nothing downstream was graded on it.
#
# ── WHICH ROAD, AND WHY (write it down — the session brief asked for this) ──
#
# The obvious road is to DERIVE the change list by reading `mockup.html`
# against `basis.md`. It was rejected. `basis.md` is prose written by a model;
# deciding "the mock changed the top bar" out of it means guessing at meaning,
# and this project has lost whole sessions to exactly that — S156's classifier
# fell 14/14 → 5/14 when a tester reworded its own corpus preserving meaning,
# S147 lost four generations of a source parser, S157 five versions of a guard.
# The cure every time was DELETING the inference and moving the decision to a
# DECLARATION (D4 already rules that way for flows: named, never inferred).
#
# So: THE CHANGE LIST IS DECLARED, AND IT IS ALREADY WRITTEN. `## Decisions` is
# "what has been SETTLED, each with the turn it was settled on" — the contract
# has demanded it every turn since S124, the design worker maintains it, and on
# BOTH real fixtures it is precisely the mock-vs-today list. The S128 room's
# reads "Objects mode gets its own layout: left object list, centre sprite
# preview + frames, right inspector", "Nudge radii up (4→6px controls…); pills
# for mode tabs", "Reconcile the dual accent (blue=Maps, indigo=Objects) into
# one blue primary" — the exact three things the built app got wrong. The
# holodeck was not failing to KNOW them. `promote` was throwing them away.
#
# The same is true of bucket 2, `### 2. Implied by the mockup, not yet settled`
# (S128 excluded it pending a dedup rule; that exclusion is this defect). A
# status bar that is drawn but not wired is a bucket-2 item, and the captain
# only got his because he happened to type it out.
#
# NO NEW MECHANISM, THEN. Two sections the product already maintains stop being
# discarded, and `_CONCEPT_CONTRACT` asks for `## Decisions` in the sharper
# `today X → now Y` shape it was already half-written in. The failure mode is
# "says less than it could" — a doc with no `## Decisions` yields no change
# list rather than an invented one.
#
# ══ S170 — AND THAT ROAD IS NOW DELETED. READ THIS BEFORE RE-ADDING IT. ═════
#
# THE CAPTAIN DROVE S169's OUTPUT ON HIS OWN PROGRAM and the change list read
# back as *"a lot of my ramble back and forth"*. The cause is one sentence long
# and the paragraphs above walked straight past it:
#
#   `## Decisions` IS A LOG OF THE CONVERSATION — THE PATH — NOT A DESCRIPTION
#   OF THE END STATE.
#
# It is maintained faithfully, and that is the problem. It records the turns
# where the captain was CORRECTING THE MOCKUP'S OWN MISTAKES, and downstream
# those corrections read as instructions to change the real app. Measured on
# his live room (`web/tests/fixtures/s170-tile-editor/`, byte copies), 4 of 21
# bullets are mock-versus-mock —
#
#   "**T2** Theme control is a single icon button … — T1 mock had a two-segment
#       light/dark toggle → now one button."
#   "**T2** Remove the Layer-properties panel that the T1 mock added (opacity /
#       grid / tile-size) — it is gone from the sidebar."
#
# — and against the real app the second is a NO-OP: that panel never existed in
# the product, so an implementer would hunt for something to delete. The
# sharpest one is half-honest, which is worse:
#
#   "**T3** Add a Close button to the toolbar, right of Save … — today the
#       editor already has a close-project control; the mock now models it
#       correctly as a labeled "Close" button (T6: was a bare × icon → now a
#       ghost button reading "Close")."
#
# The truth is in the qualifier and THE HEADLINE IS WHAT GETS ACTED ON.
#
# ── THE INVERSION ──────────────────────────────────────────────────────────
#
# The change list is now DERIVED FROM A DIFF: one bounded read-only worker,
# standing IN THE CAPTAIN'S REPO, reporting the DIFFERENCE between the finished
# `mockup.html` and the app AS IT ACTUALLY IS. See `_HANDOFF_DERIVE_PROMPT`.
#
# WHY THAT KILLS THE DEFECT STRUCTURALLY, and why there is no detector here:
# a correction that restores today's behaviour produces NO LINE AT ALL, because
# there is no difference to report. Both of the captain's examples simply
# vanish; nothing has to recognise them. S169's own comment (above) rejected
# the derivation road on the grounds that reading `basis.md` means guessing at
# meaning — and it was RIGHT about `basis.md`, which is a prose summary written
# once at program start and stale by the end of a long session. The answer is
# not to read the summary. It is to read the REPO, which is the same posture
# `grounding` already has (D12): read-only worker, cwd = the target repo.
#
# S169's other fear — "a classifier is what this road exists to avoid" — is
# answered by the shape of the output, not by a promise: nothing in this file
# reads a change line and decides anything about it. The `ast` test
# `test_NOTHING_in_the_FILING_path_reads_the_derivation` still holds, and the
# S156/S147/S157 string-matching road is still refused.
#
# ── WHAT `## Decisions` IS FOR NOW ─────────────────────────────────────────
#
# The EXPLANATION, and only that. It is fed to the derivation worker as the
# source of WHY a change was chosen — a `because …` clause on a derived line —
# and it no longer appears in the brief as a list of anything. `promote` no
# longer publishes a `decisions` key and `_handoff_decisions` is gone; the
# heading constant survives because the derivation prompt names the section.
_HANDOFF_DECISIONS_HEADING = "Decisions"
# S171 — the concept doc's flow declarations, by the name `_CONCEPT_CONTRACT`
# asks for them under. The derivation prompt names this section because it is
# where BEHAVIOUR lives: a picture cannot show what a control is wired to, and
# `## DECLARED FLOW` states the transitions in one line each. Nothing here
# parses it — it is handed to the pass by name, exactly as `## Decisions` is.
_HANDOFF_FLOW_HEADING = "DECLARED FLOW"
# Bucket 2 of `## WHAT IT MUST DO`. `_HANDOFF_NOT_STATED_BUCKETS[0]` is the
# same literal, and it is the same rule seen from the other side: the region
# reader uses it to EXCLUDE bucket 2 from the captain's own words, and this
# uses it to FIND bucket 2. One name, two readers — reword it and both move.
_HANDOFF_IMPLIED_BUCKETS = ("2. " + _HANDOFF_NOT_STATED_BUCKETS[0],
                            _HANDOFF_NOT_STATED_BUCKETS[0])


# Bucket 3 of `## WHAT IT MUST DO`. S170 — the captain's design says
# `## Decisions` demotes to "why a change was chosen, PLUS the explicit
# out-of-scope", and the out-of-scope half is the part a derived list cannot
# produce: a diff reports differences, and "do not touch the tile canvas" is a
# statement about what must produce NO difference. It is short (two items on
# his real room) and it is the sentence that keeps an implementer out of the
# canvas, so it rides in its own named block.
_HANDOFF_SCOPE_BUCKETS = ("3. " + _HANDOFF_NOT_STATED_BUCKETS[1],
                          _HANDOFF_NOT_STATED_BUCKETS[1])


# ── S172: A BULLET THAT IS ENTIRELY AN ASIDE IS NOT AN ITEM ────────────────
#
# THE CAPTAIN, driving S171 on his own room: bucket 2 arrived in his brief as a
# heading, a caption, and one bullet reading
#
#   - (none — the dirty-state binding and the canvas-overlay ownership
#     questions from T1 were answered by the captain in T2.)
#
# Three lines of his brief saying nothing, under a heading promising something.
# It was S170-ledgered and he has now put it in his own brief for this round:
# A SECTION WITH NO REAL ITEMS SHOWS NOTHING AT ALL — no heading, no caption.
# `_handoff_section` already returns "" for an empty list, so the whole cure is
# to stop counting an aside as an item.
#
# WHAT THIS IS: a test on DELIMITERS, the same class as stripping the `-` a
# model puts in front of a good line. A bullet whose WHOLE text is wrapped in
# brackets is the writer talking ABOUT the list, not writing in it. It reads no
# words and asks no question about meaning, so it cannot be reworded past (the
# thing S156 lost 14/14 → 5/14 to) and it cannot drop a real item — a real item
# would have to be written entirely inside brackets to be lost.
#
# The other half is upstream and is the durable one: `_CONCEPT_CONTRACT` now
# tells the design worker to leave an empty bucket EMPTY. This exists because
# the captain's real room was already written the other way.
_ASIDE_ONLY = re.compile(r"^\((?:[^()]|\([^()]*\))*\)[.]?$")


def _handoff_bucket_items(body):
    """The real items of a `## WHAT IT MUST DO` bucket."""
    return [i for i in _md_items(body) if not _ASIDE_ONLY.match(i.strip())]


# ══ S178 CURE 5 — A CHECKLIST WITH A COUNT, NOT A RECALL TEST ═══════════════
#
# THE MEASUREMENT. On lcars-20260829-002 the worker carried 9 of 14 unsettled
# items into the PRD. The 5 it lost were items 10–14 — the CONTIGUOUS TAIL of
# the list, not a section and not a semantic category. It carried both `## Open
# questions` and the first 7 implied ones, then stopped. (Dropping bucket 2
# wholesale would have lost 12, so this is not a misread heading.)
#
# Tail truncation over fourteen wrapped, near-identical bullets is the failure
# mode already on record (S175 measured a model dropping the last instruction).
# The defence is not more prose about carefulness: it is A NUMBER THE WORKER CAN
# CHECK ITSELF AGAINST. The hand-off already knows all 14 verbatim, so asking it
# to RECONSTRUCT them from two headings with different framings is the expensive
# way to get the same list.
#
# WHAT THIS IS NOT: a second copy of the questions. ONE HOME EACH still holds —
# bucket 1 has its own block with its own answer boxes, bucket 2 has its section
# in the brief, and nothing here reprints either. This is an instruction and a
# count, which is the cheap half.
#
# THE COUNT MUST BE THE GATE'S COUNT. `_handoff_unsettled` reads the same two
# homes `lcars_concept_open_questions` reads, in the same order, with the same
# exact-text dedup — and the agreement is MEASURED against the shipped bash on
# real doc shapes rather than asserted here, because two implementations in two
# languages absolutely can drift (see `ClaudePromptNamesWhatRidesTest`).


def _handoff_unsettled(concept_text):
    """Every item the design session left UNSETTLED, in the gate's own terms.

    Bucket 1 (`## Open questions`) then bucket 2 (`## WHAT IT MUST DO` →
    "Implied by the mockup, not yet settled"), deduped on exact text, document
    order preserved — which is precisely what `lcars_concept_open_questions`
    (skills/lcars-init/lcars-common.sh) does and therefore precisely what
    `lcars_prd_questions_gate` will demand of the PRD.

    NOT the daemon's own carry/dedup rule (`_handoff_parts`), which drops a
    bucket-2 item CONTAINED IN something already on screen so the captain does
    not read it twice. That rule is right for a dialog and wrong for a count:
    the gate does not do containment, so a count taken through it would tell the
    worker a smaller number than the gate is about to enforce — a checklist that
    is short by one is worse than none at all.
    """
    out, seen = [], set()
    for text in ([q["text"] for q in _handoff_questions(concept_text)]
                 + list(_handoff_implied(concept_text))):
        t = (text or "").strip()
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def _handoff_carry_forward_block(concept_text):
    """The count-and-checklist instruction, or "" when nothing is unsettled.

    "" is the whole no-op case: a program whose design session settled
    everything (and every mission with no design session at all) gets a brief
    byte-identical to the one before this existed — which is also exactly when
    `lcars_prd_questions_gate` is itself a no-op.
    """
    items = _handoff_unsettled(concept_text)
    n = len(items)
    if not n:
        return ""
    n1 = len(_handoff_questions(concept_text))
    n2 = n - n1
    return (
        "## Carry all %d unsettled items into the PRD — filing checks this\n\n"
        "The design session left %d item(s) unsettled: %d under the concept "
        "doc's `## Open questions`, and %d under `## WHAT IT MUST DO` → "
        "\"Implied by the mockup, not yet settled\". BOTH sections count, and "
        "EVERY item in them must appear in your PRD's `## Open questions from "
        "the design session` section — as `- STILL OPEN: <the item>` while it "
        "is unsettled, or `- RESOLVED with the captain: <what was decided>` "
        "once the grill settles it.\n\n"
        "A `STILL OPEN:` entry satisfies the check completely and permanently. "
        "You do NOT need an answer from the captain to carry an item forward, "
        "and you must not re-open the grill to get one — carrying a question "
        "forward unanswered is the correct, expected outcome.\n\n"
        "COUNT THE ENTRIES IN THAT SECTION AGAINST %d BEFORE YOU FILE. The "
        "items that go missing are the LAST ones in a long list — measured: a "
        "PRD carried 9 of 14 and lost items 10 through 14 — and `lcars file` "
        "refuses a PRD that drops any of them." % (n, n, n1, n2, n))


def _handoff_out_of_scope(concept_text):
    """Bucket 3 — what this work must NOT touch, in the captain's own doc.

    Same structural read as bucket 2, off the same literal (`Out of scope` is
    `_HANDOFF_NOT_STATED_BUCKETS[1]`, which the region reader already uses to
    stop). Nothing judges the items; they are carried verbatim.
    """
    section = _md_section(concept_text, _HANDOFF_REQ_HEADING, prefix=True)
    if not section:
        return []
    for bucket in _HANDOFF_SCOPE_BUCKETS:
        body = _md_section(section, bucket, prefix=True)
        if body:
            return _handoff_bucket_items(body)
    return []


def _handoff_implied(concept_text):
    """Bucket 2 — behaviour the mockup implies that NOBODY HAS STATED.

    Carried, and carried MARKED (see `_handoff_brief`). The distinction is the
    entire subject of FL-011: an implied item laundered into "what he said"
    arrives silent and authoritative, which is the failure this whole hand-off
    is built against. Missing is loud; invented is not.
    """
    section = _md_section(concept_text, _HANDOFF_REQ_HEADING, prefix=True)
    if not section:
        return []
    for bucket in _HANDOFF_IMPLIED_BUCKETS:
        body = _md_section(section, bucket, prefix=True)
        if body:
            return _handoff_bucket_items(body)
    return []


# ── THE DEDUP RULE, stated once (S169) ──────────────────────────────────────
#
# WHY IT IS REQUIRED: this is why S128 deferred bucket 2 in the first place. A
# bucket-2 item can also be an `## Open question` and can also be a decision —
# and the open questions have their OWN panel in the dialog, with their own
# answer box and their own ⚠ STILL OPEN block in the filed mission. The captain
# must not skim the same sentence three times; an over-long box is how this
# whole thing gets ignored, and being ignored is the same outcome as not
# shipping it.
#
# THE RULE: everything the hand-off can show is carried by the FIRST road that
# claims it, in this order —
#     1. the captured requirements (his own words)
#     2. `## Open questions`      (its own panel, its own answer box)
#     3. `## Decisions`           (settled beats unsettled)
#     4. bucket 2, implied        (marked, never laundered)
# — and a later road drops a line whose normalised text is ALREADY CARRIED,
# either identically or as a whole-word run inside something already shown.
#
# CONTAINMENT, NEVER SIMILARITY, and only in one direction: the thing already
# on screen must say AT LEAST as much as the thing being dropped. So nothing
# can be lost — the worst case is a duplicate shown, never a real item silently
# removed, which matters because silent removal is the exact defect class this
# session exists to cure. A reworded twin ("keep the bottom status bar?" vs "is
# a bottom status bar in scope, or noise?") is NOT caught here on purpose: the
# fix for that is upstream, in the contract, which now tells the design worker
# to write each undecided thing in exactly ONE of the two lists.
_HANDOFF_DEDUP_MIN_WORDS = 4


def _handoff_norm(text):
    """Case-folded, punctuation-light, single-spaced — for the CONTAINS check.

    The dedup above is a containment test, and the two sides of it are written
    by different hands: one section is model prose, the other is a derived line.
    Re-wrapping, case and the bold markers around a turn attribution are not
    differences of meaning and must not read as ones.
    """
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


def _handoff_carry(carried, items):
    """`items` minus anything `carried` already says. See the rule above."""
    hay = [" %s " % _handoff_norm(c) for c in carried]
    kept = []
    for text in items:
        norm = _handoff_norm(text)
        if not norm:
            continue
        needle = " %s " % norm
        if len(norm.split()) >= _HANDOFF_DEDUP_MIN_WORDS:
            if any(needle in h for h in hay):
                continue
        elif any(needle == h for h in hay):
            continue
        kept.append(text)
        hay.append(needle)
    return kept


# S128 fix round 1 (D3). THE BRIEF'S FIRST LINE IS THE MISSION'S NAME. Both
# filing roads derive a mission's title from it — `_title_from_idea` here, and
# file.sh's own "the issue title = the first idea line" on the park road — so
# it is the card on the board and the title of the GitHub issue, permanently.
# The draft used to open with its own section heading, and every single
# holodeck-born mission was therefore called
# `## What it must do — in your own words`. A shim caught the `gh issue create
# --title ## What it must do…` that would have made that permanent.
#
# The title is the PROGRAM NAME: the captain typed it, it is what names his
# room and what the deck's program list already calls this design, so the card
# on the board reads as the thing he has been drawing. The first requirement
# was the other candidate and it is worse — it is a turn-attributed quote
# (`Turn 1: "It has to have a light and a dark theme." — T1`), which reads as
# a quotation rather than a name and changes identity whenever the order of
# the captured requirements does.
#
# The heading survives BELOW it, because it was doing a second job: telling
# the human who opens this box what the box is. Only its position changes.
#
# ── S171: AND IT IS ALSO THE WHOLE OF HIS OWN WORDS NOW ────────────────────
#
# The captain typed this string into ONE field — "What are we designing?" — and
# it is his opening description of the program, whole:
#
#   "Give the tile editor a more modern UI look and add a light/dark mode. I
#    don't want to touch the tile canvas at all"
#
# So it is carried BYTE-FOR-BYTE and never rewritten. The alternative on the
# table was composed prose (a model turning the captured requirements into a
# readable paragraph) and he ruled against it in one sentence: *"composed prose
# means an AI rewrites your opening words."* Nothing in this file may generate
# a sentence in his voice.
#
# `title` is the FIRST LINE of it, which is the contract above — the mission's
# name and the GitHub issue's title. Any further lines ride directly beneath,
# so a multi-line description is preserved rather than truncated to its first
# line the way this function used to.
def _handoff_titled(brief, opening):
    """`brief` under the captain's opening description, verbatim.

    Its first line is the program name, which both filing roads read as the
    mission's title — see the block above.
    """
    head = str(opening or "").strip()
    if not head:
        return brief
    return "%s\n\n%s" % (head, brief) if brief else head


# S169 — THE THREE SECTIONS, and the words above each of them.
#
# Held as constants because the browser has to be able to name them (the hint
# under the box says what the draft is made of) and the suite has to be able to
# pin them. They are SHORT on purpose: the trap this change walks into is a box
# so long nobody reads it, and every line of preamble is a line of his brief he
# does not see.
#
# ── S171: `_HANDOFF_REQ_TITLE` AND THE LIST UNDER IT ARE GONE ──────────────
#
# `## What it must do — in your own words` headed a NUMBERED, TURN-ATTRIBUTED
# list of quoted fragments read out of `## WHAT IT MUST DO` bucket 1. The
# captain, having driven S170's output on his own program:
#
#   *"The problem was the 'in my own words' list still in the text and in the
#    requirements. Those ended up being ramble bullet points that were more a
#    timeline than fact. For example, they had my whole chat about the close
#    button vs x."*
#
# It is the SAME DISEASE S170 cured one surface over. `## Decisions` was a
# transcript of the conversation; so is this, and for the same structural
# reason — bucket 1 is maintained turn by turn, in the order things were said,
# with the turn stamped on each line. His close-button-vs-× exchange is a
# conversation about how the MOCKUP got fixed. It was never a requirement of
# his app, and read back as a brief it is a timeline.
#
# WHAT REPLACES IT IS NOT PROSE. See `_handoff_titled`: his opening description
# rides verbatim, and the change list — which is a DIFF, and which he measured
# as *"great… captured most things which would clue the harness in closely
# when it builds"* — carries the work.
#
# HIS WORDS ARE NOT LOST, and this is the load-bearing fact. `concept.md` rides
# to the Mission as an attachment (`_HANDOFF_FILES`) with `## WHAT IT MUST DO`
# in it, complete and turn-attributed, and every stage reads it. What changed is
# that a timeline is no longer PASTED INTO THE BRIEF, where it read as the
# specification.
#
# S169 FIX ROUND 1 — THE CAPTION STOPS VOUCHING FOR THE LIST.
#
# It used to read "Settled while you were drawing it. Today's app does none of
# it and the built product has to match the mockup…" — printed, on the tester's
# real drive, directly above a line saying the top bar was KEPT. Two things were
# wrong with it and only one was the false line:
#
#   • "Today's app does none of it" is a claim about the captain's REPOSITORY.
#     The daemon has never opened it — it does not read `basis.md` — so it was
#     asserting something it cannot know, and a surface must not do that.
#   • It read as exhaustive. The list is `## Decisions`, an account of what the
#     conversation SETTLED; the mockup on the same drive also carried a scale
#     bar, a rail header, 6px radii and uppercase micro-labels that were drawn
#     and never discussed, so no declared list could contain them.
#
# What replaces it says what the section IS and who wins when it disagrees with
# the picture — the same rule as `_HANDOFF_PRECEDENCE`, said where he reads the
# list rather than only in the block below it.
#
# S170 — AND NOW IT NAMES THE DIFF. Fix round 1 of S169 stopped the caption
# vouching for a list it could not verify; the list has since STOPPED BEING AN
# ACCOUNT. It is read off the captain's own project and the finished drawing by
# a read-only pass that stands in the repo, so the caption may say so — and it
# must also say the one thing that makes the list readable: SOMETHING THE
# MOCKUP LEAVES ALONE PRODUCES NO LINE. That is why his corrections of the
# mockup's own mistakes are simply absent rather than reworded.
_HANDOFF_CHANGE_TITLE = "## What the mockup changes about your app as it is today"
_HANDOFF_CHANGE_NOTE = (
    "Read off your project and the finished mockup by one read-only pass — the "
    "difference between them, look and flow only. Anything the mockup leaves "
    "as your app already has it produces no line here. The mockup is what gets "
    "built: where a line here disagrees with the picture, the picture wins. "
    "Correct or delete anything that is wrong.")
_HANDOFF_IMPLIED_TITLE = "## Implied by the mockup — NOT things you said"
# S178 CURE 4 — THE BRIEF STOPPED AUTHORISING THE DELETION THE GATE FORBIDS.
#
# MEASURED on lcars-20260829-002. This note used to end "answer them, correct
# them, or delete them", and it is the text the Align worker actually reads:
# it sits in the filed `idea.md` (line 36 of his real one) directly above the
# 12 items bucket 2 carried. `lcars_prd_questions_gate` then REFUSES a PRD that
# drops any of them. So the brief offered, in writing, the one move the gate
# treats as fatal — and the mission died on the closing turn with 9 of 14
# carried. A worker obeying this prompt perfectly could still fail the gate.
#
# That is the S175 defect shape exactly: the harness refusing the prose its own
# prompt asked for. The cure is the prompt's, not the gate's.
#
# WHAT DID NOT CHANGE, deliberately. The "NOT things you said / marked as
# IMPLIED, never as your words" framing is the entire reason this section
# exists (FL-011: an implied item laundered into his words arrives silent and
# authoritative), and the title is untouched. Bucket 2 is NOT folded into
# bucket 1 — S169/FL-011 keeps those apart on purpose, one home each, so the
# captain never reads the same sentence twice.
#
# The captain can still ANSWER or CORRECT an item — those are edits to the
# line. What he cannot do is make it vanish, because the gate measures the PRD
# against the CONCEPT DOC, not against his edited brief: deleting a line here
# does not delete the question there, it only guarantees the filing is refused.
_HANDOFF_IMPLIED_NOTE = (
    "The mockup implies these; nobody has settled them. They travel marked as "
    "IMPLIED, never as your words — answer them or correct them. Do NOT delete "
    "one: every item here has to reach the Mission's PRD under "
    "`## Open questions from the design session`, carried as "
    "`- STILL OPEN: <the item>` while it is unsettled or "
    "`- RESOLVED with the captain: <what was decided>` once the Align grill "
    "settles it. Filing REFUSES a PRD that drops any of them.")
_HANDOFF_SCOPE_TITLE = "## Out of scope — do not touch these"
_HANDOFF_SCOPE_NOTE = (
    "Settled as out of scope while you were drawing. A diff cannot produce "
    "these — they are the things that must stay exactly as they are.")


def _handoff_section(title, note, items):
    """One `## heading` + one line of prose + the items, or "" for nothing."""
    if not items:
        return ""
    return "\n".join([title, "", note, ""] + ["- %s" % i for i in items])


# ── S171: `_handoff_head` IS GONE, AND SO IS THE LADDER UNDER IT ───────────
#
# It answered "where does the top of the brief come from" with three rungs —
# the captured requirements, then `## The problem`, then the concept doc's
# first paragraph — and published which rung it landed on (`summarySource`) so
# a fallback could never be passed off as the real thing. That discipline was
# right for a head DRAFTED OUT OF A MODEL-WRITTEN DOCUMENT.
#
# The head is no longer drafted. It is the captain's own opening description,
# which he typed himself and which exists on every program (`holodeck_start`
# refuses one without it), carried byte-for-byte by `_handoff_titled`. There is
# no rung below it to fall to and no source to disclose: a brief can no longer
# be composed from anything but his own words plus a diff.
#
# `## The problem` — the rung this deletes — is model-written prose ABOUT him
# ("The captain wants a cleaner, more modern chrome…"). Keeping it as a fallback
# would be exactly the thing he ruled out.


def _handoff_parts(concept_text, changes=(), asks=()):
    """(requirements, changes, implied, out-of-scope) — deduped, in the order
    the box shows them.

    ONE function decides what the hand-off carries, because `promote` (which
    draws the box) and the brief (which fills it) have to agree about every
    line: a count in the hint that does not match the box is the surface lying
    about itself. See `_handoff_carry` for the precedence.

    S170 — `changes` ARRIVES AS AN ARGUMENT and is not read out of the concept
    doc. That is the whole inversion: the list is produced by a worker standing
    in the captain's repo (`_handoff_derive_state`), and this function is a
    PURE assembler over it. Nothing here spawns anything, so every filing road
    that calls it stays token-free and cannot be blocked by a pass that never
    answered — `changes=()` is the honest degraded shape, not an error.

    S172 — AND `asks` ARRIVES THE SAME WAY, from the same reply, and joins
    BUCKET 2. It is the same kind of thing bucket 2 already holds — behaviour
    the mockup implies that nobody has settled — so it goes in the section that
    already exists and already says so, rather than under a fourth heading. The
    concept doc's own bucket 2 goes FIRST and therefore wins the dedup: a thing
    the design chat already declared as implied keeps the wording the captain
    has been reading all session.

    THE MARKING IS THE POINT AND IT STILL HOLDS. Everything in this section
    travels as IMPLIED-not-stated (`_HANDOFF_IMPLIED_NOTE` says so in the
    brief); nothing here is ever laundered into his own words, which is FL-011
    and the reason the section exists at all.
    """
    reqs = _handoff_requirements(concept_text)
    carried = list(reqs) + [q["text"] for q in _handoff_questions(concept_text)]
    changed = _handoff_carry(carried, [c for c in (changes or []) if c])
    implied = _handoff_carry(
        carried + changed,
        _handoff_implied(concept_text) + [a for a in (asks or []) if a])
    scope = _handoff_carry(carried + changed + implied,
                           _handoff_out_of_scope(concept_text))
    return reqs, changed, implied, scope


# ══ S170 — THE DERIVATION: THE CHANGE LIST IS A DIFF, NOT A TRANSCRIPT ═════
#
# THE MEASUREMENT (the captain, driving S169's output on his own real program,
# 2026-08-07): *"The text it puts in is a lot of my ramble back and forth. It
# reads with things like when I asked it to draw the undo/redo buttons closer
# to how they are today. Or it says a bare x icon needs to say close, but the
# existing one says close and I just told the holodeck to fix its mock to add
# the close button back in instead of just an x."*
#
# The root cause is stated in full at `_HANDOFF_DECISIONS_HEADING`. In one line:
# `## Decisions` is a log of the CONVERSATION, and a conversation contains the
# captain correcting the MOCKUP. Those corrections rode downstream as
# instructions to change the REAL APP.
#
# ── WHAT THIS IS, AND WHAT IT REPLACES ─────────────────────────────────────
#
# S169 fix round 2 already put a bounded, read-only, cold, fail-safe worker at
# promote time — the right posture, the right jail, the right polling, the
# right refusal to ever block a filing. IT KEEPS ALL OF THAT AND ITS JOB
# CHANGES. It used to READ A LIST BACK against the drawing and flag lines; it
# now PRODUCES THE LIST, by diffing the finished drawing against the captain's
# repository. There is deliberately no second mechanism beside it — adding one
# is the most repeated defect cause in this round's history.
#
# ── THE FOUR THINGS THAT MOVED ─────────────────────────────────────────────
#
# 1. DERIVED FROM A DIFF, NOT TRANSCRIBED. A correction that restores today's
#    behaviour produces NO LINE, because there is no difference to report.
#    Nothing detects a "mock-relative" line; the shape of the question deletes
#    the class. (S156's classifier fell 14/14 → 5/14 on a reworded corpus,
#    S147 lost four parser generations, S157 five guard versions. Not again.)
#
# 2. AGAINST THE LIVE REPO, NOT `basis.md`. `basis.md` is written ONCE at
#    program start and is a prose SUMMARY; a long design session makes it
#    stale. The pass therefore runs with the TARGET REPO as its cwd — the same
#    posture `grounding` (D12) already has — and `basis.md` rides only as
#    context, explicitly outranked by the code.
#
# 3. `## Decisions` DEMOTES TO THE EXPLANATION. It is an input to this prompt
#    for WHY a change was chosen, and it is no longer a list in the brief.
#
# 4. THE WAIT IS HONEST AND WALK-AWAY-ABLE. The pass was ALREADY 154–220s
#    measured, bounded at 420s; S169 hid that behind a spinner on a dialog.
#    It is now a state he can leave: the daemon owns it (so a page reload
#    cannot forget it) and the RESULT IS PERSISTED IN THE PROGRAM ROOM (so a
#    daemon that dies does not cost him the wait twice). See
#    `_handoff_derive_fingerprint` / `_handoff_derive_read`.
#
# ── AND IT STILL CANNOT BE A GATE ──────────────────────────────────────────
#
# Every fail-safe S169 built is kept, and the bar is unchanged: A VERIFICATION
# STEP THAT CAN BLOCK A HAND-OFF IS WORSE THAN THE DEFECT. No engine, a
# timeout, an unparseable reply, a corrupt persisted record, a repo that has
# gone away — he still gets a brief (his words, what the mockup implies, what
# is out of scope) and ▦ FILE MISSION still fires. The only thing he loses is
# the derived section, and the band SAYS SO in plain words rather than looking
# like a clean result.
#
# NAMING. "audit" is `_audit_snapshot` (the before/after file walk). "check"
# was S169's flagger and is gone — a function called `_handoff_check_spawn`
# that returns a change list is exactly the drift every comment in this file
# rails against.

# The mockup is a FICTION — fake data, invented internals, no real state — and
# the app is an implementation. Without this line pinned, the pass reports "the
# app has no renderStops()" and "the mock uses inline CSS, the app uses
# Tailwind" as changes. The round already drew this line (the mock is a visual
# reference, never shipping code); it is applied here.
_HANDOFF_DERIVE_MARKER = "=== CHANGES ==="
# ── S172: AND THE SECOND BLOCK — WHAT IT FOUND AND DID NOT REPORT ──────────
#
# THE MEASUREMENT (the captain, driving S171 on his own room, 2026-08-07). His
# mockup draws Zoom in / Zoom out / Fit buttons and a `100%` readout over the
# canvas, and a hover x/y pill. His app has zoom on the scroll wheel only, reset
# view on a middle-mouse double click, and it already COMPUTES the hover tile
# and never shows it. NEITHER REACHED THE CHANGE LIST — because his out-of-scope
# bucket says *"The tile canvas rendering — left as an untouched placeholder
# well"*, and the pass suppressed chrome drawn OVER the canvas along with the
# canvas itself.
#
# HE RULED THE SUPPRESSION FAIR: *"to be fair, I did say don't touch the canvas
# and it look like it got everything else."* That is his own calibration ruling
# working — intent-reading over literalism, the conservative mechanism, never
# escalate-on-doubt — and it is deliberately UNCHANGED. The diff is not widened
# and nothing here argues with a scope he set.
#
# WHAT HE ASKED FOR INSTEAD, verbatim: *"Let's bank that as a question it should
# have asked me in the send to align dialog."* So a difference the pass FOUND
# and then DECLINED TO REPORT comes back as a QUESTION in the brief's
# `## Implied by the mockup` section — one line, in his language, which he
# answers or deletes in a second.
#
# ── WHY THIS IS A DECLARATION AND NOT A CLASSIFIER ─────────────────────────
#
# Nothing in this file reads a change line's wording and decides whether it was
# "ambiguous". It cannot: the line does not exist — that is the entire defect.
# THE PASS IS THE PARTY THAT DECIDED NOT TO REPORT IT, so the pass declares it,
# exactly as the planner DECLARES `changesScreenAppearance` on a ticket rather
# than having a matcher guess it from the ticket text (S169). That is the one
# shape that has worked every time here, and the road that has cost this project
# four sessions (S156 14/14 → 5/14 on a reworded corpus, S147's four parser
# generations, S157's five guards) is the one not taken.
#
# ── AND IT IS NOT AN ESCALATION ────────────────────────────────────────────
#
# It is a line in a section he skims before filing. It never gates, never sets
# awaiting-human, never blocks a hand-off, and a pass that declares nothing here
# is the ordinary answer. `_handoff_derive_asks` returns [] for every reply that
# does not carry the block, including every reply written before it existed.
_HANDOFF_DERIVE_ASK_MARKER = "=== ASK ==="
# How many derived lines are carried. A bound on the box, not a judgement about
# which lines matter, and the surface says when it bites. The captain's real
# room derives well under this.
_HANDOFF_DERIVE_MAX_CHANGES = 40
# The questions are bounded HARDER than the changes, and on purpose: this is the
# section he skims, and a pass that hands back thirty questions has handed the
# work back to him — which is the failure the whole holodeck exists to prevent
# (*"if I have to spell out each change… the value is lost"*).
_HANDOFF_DERIVE_MAX_ASKS = 10
# One line, bounded. It is a model's prose going into the captain's own brief;
# a runaway paragraph is a paragraph he stops reading.
_HANDOFF_DERIVE_MAX_LINE = 400

_HANDOFF_DERIVE_PROMPT = """\
You are producing ONE list: WHAT IS DIFFERENT between a finished design mockup \
and an application as it actually is today. You write NOTHING — you have no \
write tool and nothing you say is applied to any file.

YOUR WORKING DIRECTORY IS THE REAL APPLICATION. Read it. It is the app as it \
stands right now, and it is the only authority on what "today" means.

The design and the notes that go with it are these files:

  · %(mockup)s
      THE FINISHED MOCKUP — the design that will actually be built.
  · %(concept)s
      The design chat's written record. Its `## %(decisions)s` section says WHY \
each choice was made, its `## %(flow)s` section names the screens and the \
transitions between them, its `## %(must)s` section says what the finished \
thing has to DO, and its out-of-scope list says what must not be touched. USE \
IT FOR WHY, FOR BEHAVIOUR AND FOR SCOPE — a picture cannot show you what a \
control is wired to, and those sections can. DO NOT use it as the list of \
changes: it is a log of a conversation, it records the mockup being corrected \
against ITSELF, and it is not what you are being asked for.
  · %(basis)s
      An earlier summary of the app, written before the design session started. \
It may be stale and it may be absent. It is context only, and WHERE IT \
DISAGREES WITH THE CODE IN YOUR WORKING DIRECTORY, THE CODE WINS.

── WHAT COUNTS AS A CHANGE ─────────────────────────────────────────────────

THE LINE, AND HOLD IT IN BOTH DIRECTIONS: what a thing IS, what it DOES and \
what it is CONNECTED TO are changes. HOW IT IS BUILT is not.

So compare LOOK, FLOW AND BEHAVIOUR:

  · what is on each screen, and what is not;
  · where it sits, and in what order;
  · colour, fill, border, radius, spacing, size, weight, casing;
  · labels and wording as a user reads them;
  · what a control does when it is clicked, and what the user sees next;
  · states a user can see: hover, active, selected, disabled, empty, error;
  · WHAT A THING IS WIRED TO — the real data or state it must read, and what \
must actually change in the app when it is used. A counter, a status line, an \
indicator, a toggle, a filter, a list: say what it must reflect and what must \
happen when it moves. "There is a status bar" is not the change; "the status \
bar shows the real unsaved state and flips when the document is saved" is.
  · what happens when there is nothing to show, when it is loading, and when \
it goes wrong, where the mockup draws that and the app does something else.

A thing that only LOOKS right is not built. If the mockup shows something the \
app must now DO, and the app does not do it today, that is a line — even when \
the two would look identical in a screenshot.

NEVER REPORT IMPLEMENTATION. The mockup is ONE self-contained HTML file with \
invented data and no real internals; the app is a real program. These are NOT \
changes and MUST NOT appear in your list:

  · frameworks, libraries, build tools, file or folder organisation;
  · HOW styling is expressed — inline CSS, classes, a stylesheet, utility \
classes, tokens, variables. Only the RESULT a user sees is a change;
  · HOW behaviour is implemented — state stores, hooks, events, handlers, \
props, endpoints, queries, schemas, where a value is kept or how it travels. \
Say WHAT must be reflected and WHAT must change, never how to make it so;
  · function, class, variable, component, id or selector names;
  · the mockup's fake data, placeholder text, dummy rows, stub handlers, or \
anything it hardcodes because it has no backend;
  · anything the mockup could not have implemented for real.

The mockup's OWN internals prove nothing about behaviour — it is wired to \
nothing on purpose. Where you say a thing must be connected to something real, \
that is read out of the design chat's record and out of the app; it is never \
read off the mockup's fake handlers.

── THE RULE THAT MATTERS MOST ──────────────────────────────────────────────

IF THE MOCKUP LEAVES SOMETHING AS THE APP ALREADY HAS IT, THERE IS NO LINE FOR \
IT. Not "unchanged", not "kept", not "confirmed", not "still present", not \
"matches today" — NOTHING AT ALL. This list is the DIFFERENCE and nothing \
else. A control the app already has, drawn in the mockup the way the app \
already draws it, is SILENCE. THAT RULE COVERS BEHAVIOUR EXACTLY AS IT COVERS \
LOOK: a thing the app already does, that the mockup does not change, is \
SILENCE too — never "still works", never "remains wired to", never "continues \
to reflect".

THE DESIGN CHAT ARGUED WITH ITSELF. It changed its mind, and it corrected \
earlier drafts of this same mockup. NONE OF THAT IS A CHANGE. Never write a \
line about an earlier draft, a previous version of the mockup, something that \
was removed FROM THE MOCKUP, or what was decided on some turn. The only two \
things that exist for you are THE APP IN YOUR WORKING DIRECTORY and THE \
FINISHED MOCKUP. If a line you are about to write would make no sense to \
somebody who had never seen the design chat, DELETE IT.

Before you write any line, FIND THE THING IT NAMES IN THE APP. If the app \
already has it and the mockup does not alter it, drop the line.

── WHEN THE SCOPE MAKES A DIFFERENCE AMBIGUOUS, SAY SO. DO NOT DROP IT ─────

The design chat's out-of-scope list is binding and you must honour it. Read it \
the way the captain meant it rather than word by word, take the conservative \
reading when you are unsure, and DO NOT report a change to something he ruled \
out. That judgement is yours to make and nothing here asks you to hand it back.

But when you find a REAL difference between the mockup and the app, and you \
then decide NOT to report it as a change BECAUSE what he ruled out makes it \
unclear whether he wants it, WRITE IT DOWN AS A QUESTION. You are the only one \
who will ever know you dropped it: a line you did not write leaves no trace, \
and the next person to see this work is building from your list.

Write each one as the ONE-LINE QUESTION it is, in ordinary words, so he can \
answer it in a sentence. For example: "the mockup adds zoom / fit buttons over \
the canvas - in or out?"

  · it is a QUESTION, never an argument for the change and never the change \
itself. Do not restate it in the change list as well;
  · keep it to differences you ACTUALLY FOUND in the mockup and ACTUALLY \
DECIDED to leave out. Never a guess about what he might also want, never a \
suggestion, never a design idea of your own;
  · nothing you write here stops anything or asks anyone to wait. He reads \
these beside the change list before he sends the work, and answers or deletes \
them. Write no more than %(askcap)d;
  · if nothing was ambiguous, write none. That is the ordinary answer and it \
is not a failure.

── DO THE WORK FIRST ───────────────────────────────────────────────────────

Open the mockup. Go through it screen by screen, region by region. For each \
region, find the corresponding part of the real app in your working directory \
and READ IT. Write your working out in full; take as much room as you need. A \
list produced without opening the app is worth nothing here, because every \
line of it is a claim about the app.

THEN, AT THE END of your reply, write TWO blocks, in this order and nothing \
else after them.

FIRST a line containing exactly:

  %(ask)s

and after it ONE LINE PER QUESTION — the differences you found and decided not \
to report, from the section above. If there are none, write this line and go \
straight on to the next block.

THEN a line containing exactly:

  %(marker)s

and after it ONE LINE PER CHANGE and nothing else — no headings, no code \
fence, no numbering, no summary, no closing remark. In the order a user meets \
them: top of the screen down, first screen first. NOTHING MAY FOLLOW THIS \
BLOCK: it is the last thing in your reply.

Each line is a single sentence in this shape:

  today <what the app does now> → <what the mockup does instead><, because ...>

`today ...` must be something you actually read in the working directory. The \
`because ...` clause is OPTIONAL — add it only where `## %(decisions)s` gives a \
reason worth carrying, and keep it to a few words. No line may run past %(cap)d \
characters.

If the mockup changes nothing at all about the app, write both markers and \
nothing after them.
"""


def _handoff_derive_prompt(mockup, concept, basis):
    """The one bounded pass's whole prompt.

    The three paths are ABSOLUTE and come from the daemon, because the pass's
    cwd is the CAPTAIN'S REPO — the drawing is not in the working directory and
    a bare filename would resolve to nothing (or, worse, to a same-named file
    in his project). `basis` may be a sentence saying there is none; the prompt
    already tells the pass to judge without it.
    """
    return _HANDOFF_DERIVE_PROMPT % {
        "mockup": mockup, "concept": concept, "basis": basis,
        "decisions": _HANDOFF_DECISIONS_HEADING,
        # S171 — the two sections that carry BEHAVIOUR, named off the same
        # constants `_CONCEPT_CONTRACT` asks the design worker to maintain, so
        # a reworded contract cannot leave this prompt pointing at a heading
        # that no longer exists.
        "flow": _HANDOFF_FLOW_HEADING,
        "must": _HANDOFF_REQ_HEADING,
        "marker": _HANDOFF_DERIVE_MARKER,
        # S172 — the second block, and its own bound. Named off the same
        # constants the parser reads, so a reworded prompt and a reworded
        # parser cannot drift apart.
        "ask": _HANDOFF_DERIVE_ASK_MARKER,
        "askcap": _HANDOFF_DERIVE_MAX_ASKS,
        "cap": _HANDOFF_DERIVE_MAX_LINE,
    }


# What a derived line may NOT be: a heading, a fence, a bullet-less blank. The
# leading list decoration a model reaches for anyway is stripped rather than
# refused — `- today the toolbar…` is a good line wearing a hyphen.
_HANDOFF_DERIVE_STRIP = re.compile(r"^\s*(?:[-*+•]|\d{1,3}[.)])\s+")


def _handoff_derive_parse(reply):
    """The change lines a reply really carries, or `None` for unusable.

    THE MARKER IS REQUIRED, and that is the whole fail-safe. S169's flagger
    could fall back to scanning the entire reply because a stray line either
    matched `<n>|VERDICT|…` or did not. Here EVERY line is a candidate, so a
    reply with no marker would ingest the pass's own working out and hand the
    captain a brief made of somebody thinking aloud. No marker ⇒ no answer.

    An EMPTY block after the marker is a real answer — "nothing differs" — and
    is returned as `[]`. It is vanishingly unlikely on a real program and the
    surface says so loudly rather than passing it off as a clean derivation.
    """
    text = reply or ""
    if _HANDOFF_DERIVE_MARKER not in text:
        return None
    return _handoff_derive_lines(text.rsplit(_HANDOFF_DERIVE_MARKER, 1)[1],
                                 _HANDOFF_DERIVE_MAX_CHANGES)


def _handoff_derive_lines(block, cap):
    """The readable lines of one marked block, bounded.

    Shared by the two blocks a reply carries because they are the SAME shape —
    one sentence per line, whatever list decoration a model reached for — and
    two copies of this would drift the day one of them was tightened. Nothing
    here judges MEANING; a line is dropped only when it is structurally not a
    line (a heading, a fence, a rule with no letters in it).
    """
    out = []
    for raw in block.splitlines():
        line = " ".join(raw.split())
        if not line:
            continue
        if line.startswith("#") or line.startswith("```"):
            continue
        line = _HANDOFF_DERIVE_STRIP.sub("", line).strip()
        # A model that decorates its last line with a rule (`---`, `===`) has
        # not written a change.
        if not re.search(r"[A-Za-z]", line):
            continue
        out.append(line[:_HANDOFF_DERIVE_MAX_LINE])
        if len(out) >= cap:
            break
    return out


def _handoff_derive_asks(reply):
    """S172 — the questions the pass DECLARED it was not reporting.

    ALWAYS A LIST, NEVER `None`, and that asymmetry with the change block is
    deliberate: no marker means the pass declared nothing, which is both the
    ordinary answer and what every reply written before this block existed
    says. A missing change list is an unusable reply; a missing ask list is
    silence, and silence here is normal.

    THE ASK BLOCK COMES FIRST IN THE REPLY AND THE CHANGE BLOCK IS TERMINAL —
    which is why this reads BETWEEN the last ask marker and the change marker,
    and why `_handoff_derive_parse` still reads exactly what it always read.
    The one fail-safe this whole road hangs on is "everything after the last
    change marker is the answer", and a second block was not allowed to weaken
    it.
    """
    text = reply or ""
    if _HANDOFF_DERIVE_ASK_MARKER not in text:
        return []
    block = text.rsplit(_HANDOFF_DERIVE_ASK_MARKER, 1)[1]
    if _HANDOFF_DERIVE_MARKER in block:
        block = block.split(_HANDOFF_DERIVE_MARKER, 1)[0]
    return _handoff_derive_lines(block, _HANDOFF_DERIVE_MAX_ASKS)


def _handoff_brief(concept_text, program="", changes=(), asks=()):
    """The PRE-DRAFTED writing space.

    D15: it is a writing space, not a title field, and it is pre-drafted from
    the conversation so the captain never faces an empty page. It is fully
    rewritable on the deck — this is only the draft.

    Its FIRST LINE is the mission's title, on every road (see
    `_handoff_titled`), so `program` leads every branch — including the degraded
    ones, which file a mission exactly the same way.

    S169 — THREE things, not one. His words, then what the mockup CHANGES about
    the app he has today, then what it IMPLIES and nobody has settled
    (bucket 2). The captain's framing is the bar — "if I have to spell out each
    change, I get closer to having to type it all out, the value is lost."

    S170 — AND THE MIDDLE ONE ARRIVES AS AN ARGUMENT. It used to be read out of
    `## Decisions`, which is a log of the conversation; it is now the output of
    a diff against the captain's real repo, produced by `_handoff_derive_state`
    and handed in. `changes=()` — the pass has not landed, could not run, or is
    switched off — degrades to a brief WITHOUT that section rather than to a
    stale one, which is the honest failure and never a blocked filing. Bucket 3
    (out of scope) rides last, because a diff structurally cannot produce it.

    S171 — AND THE TOP IS HIS OPENING DESCRIPTION, VERBATIM. It used to be a
    numbered list of quoted fragments with turn attributions, which is a
    timeline (see `_HANDOFF_REQ_TITLE`'s block). `concept_text` is still read —
    for bucket 2, bucket 3 and the dedup — but nothing is drafted from it in
    his voice any more, and no model prose reaches the head.

    S172 — AND THE MIDDLE SECTION HAS A SECOND SOURCE. `asks` is what the same
    pass FOUND AND DECLINED TO REPORT because the captain's own out-of-scope
    ruling made it ambiguous; it lands in bucket 2 as the question it is. See
    `_HANDOFF_DERIVE_ASK_MARKER`. Nothing here inspects a line to decide that —
    the pass declares it and this assembles it.
    """
    _reqs, changed, implied, scope = _handoff_parts(concept_text, changes,
                                                    asks)
    blocks = [b for b in (
        _handoff_section(_HANDOFF_CHANGE_TITLE, _HANDOFF_CHANGE_NOTE,
                         changed),
        _handoff_section(_HANDOFF_IMPLIED_TITLE, _HANDOFF_IMPLIED_NOTE,
                         implied),
        _handoff_section(_HANDOFF_SCOPE_TITLE, _HANDOFF_SCOPE_NOTE,
                         scope)) if b]
    return _handoff_titled("\n\n".join(blocks), program)


# ══ S171: `_handoff_missing` IS DELETED. THE RISK IS ACCEPTED, ON PURPOSE ══
#
# WHAT WAS HERE. `_handoff_missing(requirements, brief)` — a CONTAINMENT test
# on the captain's literal words, deliberately not a paraphrase detector. It
# found captured requirements that appeared nowhere in the brief, warned about
# them in the promote dialog (a ✓/⚠ checklist plus an amber band), and at
# filing time carried each one into the Mission verbatim under
# `## Captured requirements NOT IN THE BRIEF above`.
#
# WHY IT IS GONE, AND IT IS NOT BECAUSE IT WAS WRONG. It was a containment test
# ON THE BRIEF, and as of this session HIS LITERAL WORDS ARE NO LONGER IN THE
# BRIEF — the numbered `## What it must do — in your own words` list left it
# (see `_HANDOFF_REQ_TITLE`). So the check would report very nearly EVERY
# captured requirement as missing, on every single hand-off, for ever. That is
# not a safety net; it is the cry-wolf failure this very round just cured on
# the open-questions cue (S169 fix round 2: an amber ⚠ that fires at every open
# is a warning that trains you to click past it, sitting beside ▦ FILE MISSION).
#
# WHY NOTHING WAS BUILT TO REPLACE IT. A smarter coverage checker — similarity,
# a paraphrase detector, an LLM judge — is the single most repeated defect cause
# in this round's history: S156's classifier fell 14/14 → 5/14 on a rewording of
# its own corpus, S147 lost four parser generations, S157 five guard versions,
# and S125 lost two rounds to adding a mechanism beside an existing one, both
# cured by DELETION. The captain's ruling is the bar: *"As long as we capture
# most of the changes to help the harness implement along with the mock for
# reference, we're good."*
#
# ── THE ACCEPTED RISK, NAMED: FL-011 ───────────────────────────────────────
#
# FL-011 is "the hand-off brief is drafted from a STALE section, and the
# precedence rule then enforces the loss" — measured on the S127 capstone,
# where the captain asked for a light/dark theme twice, in his own words, and
# the filed mission's idea.md had ZERO theme mentions because the brief was
# drafted from `## Hand-off summary`, a paragraph written before the subject
# came up. This check was one of the three cures.
#
# ITS ORIGINAL JOB IS STRUCTURALLY GONE, and that is why deleting it is not
# re-opening FL-011:
#
#   • the brief is no longer DRAFTED from any model-written section. Its head
#     is the captain's own opening description, byte-for-byte, and it cannot go
#     stale because he wrote it and nothing rewrites it;
#   • the change list is read off his repository and the finished drawing by a
#     pass that opens both, not summarised out of a document that may be old;
#   • `concept.md` — with `## WHAT IT MUST DO` complete, numbered and
#     turn-attributed — RIDES TO THE MISSION as an attachment
#     (`_HANDOFF_FILES`), and every stage reads it. His words still reach the
#     work; they are no longer pasted into the brief as its specification.
#
# WHAT IS GENUINELY ACCEPTED: nothing now checks that a requirement he stated in
# the design chat is REFLECTED in the brief he sends, and nothing carries a
# missing one in as a marked block. If a future session finds a requirement lost
# between the deck and the Mission, this is the hole — and the answer is not to
# resurrect a literal-word containment test against a brief that no longer
# quotes him.


def _norm_name(name):
    """A program name as a PERSON reads it, for the collision check (round 2).

    `_slug` throws away everything that is not `[a-z0-9]`, so two names a
    captain cannot tell apart can still slug apart: "Tile picker sidebаr" with a
    Cyrillic `а` slugs to `tile-picker-sidebr` and opens a second card reading
    exactly like the first. NFKC + casefold + collapsed whitespace catches the
    EASY half of that — full-width characters, ligatures, odd spaces, case.

    IT DOES NOT CATCH HOMOGLYPHS, and deliberately does not try: a confusables
    table is an arms race that ends with a captain refused a name he typed
    honestly. The other half of the cure is on the surface — the program list
    names each program's ROOM, so two same-looking cards are legible even when
    this returns two different strings.
    """
    s = unicodedata.normalize("NFKC", str(name or ""))
    return re.sub(r"\s+", " ", s).strip().casefold()


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


# ── S126 (#6): what goes ON DISK is prose ────────────────────────────────────
# `_clean_reply` above is the CHAT's cleaner and deliberately keeps the engine's
# per-tool activity lines: the deck FOLDS them (`holoSegments`), so a wrong call
# there costs a click and never a character. A FILE cannot fold. `basis.md` and
# `transcript.md` are durable content — read by a person, replayed verbatim into
# a warm restart's opening prompt, and handed to Align at S127 — and a
# `└ 3 files found` in either is a durable instruction to nobody.
#
# ── THE RULE, IN ONE SENTENCE ───────────────────────────────────────────────
# The record may keep a line the captain did not write, but it may never lose a
# line he did — so when the structure is not unmistakably the CLI's own, KEEP.
#
# ── FIX ROUND 4: STOP GUESSING (the captain's word) ─────────────────────────
# Rounds 1, 1a and 3 all shipped ONE recognizer that decided which lines were
# machine plumbing from their SHAPE — did the tail look like an argument, did
# the bullet carry a sentence, did the `└` row carry a count. Each round
# narrowed the question and each round lost prose. A LIVE DRIVE ON BOTH REAL
# ENGINES (2026-08-05) measured that rule wrong in BOTH DIRECTIONS at once. The
# raw replies it produced are committed verbatim under
# `web/tests/fixtures/s126-live/`; re-measure there and never invent a fixture,
# because inventing the corpus is precisely how the old rule came to model a
# copilot version that no longer exists.
#
#   · CLAUDE EMITS NO TOOL TRACE AT ALL in this posture. Measured across a
#     107-line grounding pass and four design turns: the daemon's `raw` is
#     byte-identical to its `reply` and to what belongs on disk
#     (`claude-grounding-reply.txt`, `claude-diagram-reply.txt`,
#     `claude-checklist-reply.txt`). So every deletion the recognizer made on a
#     claude reply was PURE SUBTRACTION and could never have been a gain — and
#     it made them. Asked for a five-line next-turn checklist "one `●` per
#     line, verb then the file, nothing else", claude wrote
#         ● Read mockup.html / ● Measure mockup.html / ● Update mockup.html
#         ● Update concept.md / ● Preview mockup.html
#     and THREE of the five were deleted off the captain's transcript, silently.
#
#   · COPILOT'S CLI HAS CHANGED SHAPE since the S125 fixture was captured. It
#     now prints multi-row tool BLOCKS the one-line `●` rule never saw, so
#     58 of the 193 lines of a real grounding `basis.md` were leftover plumbing
#     (`/ Search (glob)`, `  │ "web/**/*.css"`, `  └ 18 files found`) — and the
#     run also ENDED on the `│` row, letting the `└` beneath it through too.
#
# So the shape-guessing recognizer is GONE, not narrowed: `_TRACE_LINE`,
# `_is_trace_line`, `_is_bare_tool_line`, `_is_result_row` and their token
# regexes went with it. What replaces it asks nothing about prose at all —
# it is PER-ENGINE handling of deterministic CLI output:
#
#   claude  → STRIP NOTHING. This is measured, not assumed; do not "restore"
#             a regex here. If claude ever starts emitting trace, the failure
#             is leftover noise in a file (an annoyance) and not a deleted
#             design decision (unrecoverable) — that asymmetry is the whole
#             reason this is shaped the way it is.
#   copilot → remove its tool blocks BY THEIR STRUCTURE (below). Anything that
#             does not match the CLI's own block structure is prose, and is
#             kept.
#
# The engine comes from the session, through the SAME resolution every other
# per-engine decision in the holodeck uses (`_is_copilot`, `sess.engine or
# self.worker_bin`). There is no second source of truth for it, and an engine
# nobody has measured falls to the claude side — the safe direction.
#
# This DIVERGES from the surface's `holoSegments`, which still folds on the
# looser rule. That asymmetry is the point and it runs the safe way: the chat
# folds (one click restores the text, which never left the DOM) while the file
# DELETES, so the file is held to the stricter standard.

# ── copilot's tool block, exactly as its CLI prints it ───────────────────────
# Lifted byte for byte off `copilot-grounding-reply.txt`,
# `copilot-turn-raw.txt` and `copilot-failed-edit-reply.txt`. THREE FORMS ARE
# CAPTURED; this comment claims nothing about a fourth. Round 4's version of it
# asserted "TWO FORMS AND NO THIRD", which was FALSE — a live drive printed the
# third (form 3 below) the same week, and the code was reading as authority on
# a thing nobody had measured. Every form here is a fixture you can open.
#
#   (1) a head bullet, its argument rows, and the result row that CLOSES it.
#       The continuation rows are indented EXACTLY two spaces, and searches
#       use a `/` bullet instead of `●`. Verbatim, both forms:
#
#           ● Read board.css                   / Search (glob)
#           ␣␣│ web/static/board.css           ␣␣│ "docs/**/*.css"
#           ␣␣└ L1:200 (200 lines read)        ␣␣└ 1 file found
#
#       The `└` row is REQUIRED. A head the CLI never closed is a captain
#       writing, whatever verb he opened with, and it is kept — that
#       requirement is what lets this be structural instead of clever.
#
#   (2) a write's one-line activity row, which has no continuation rows at all
#       and ends in the CLI's own diff counters:
#           ● Edit mockup.html +8 -6      ● Create mockup.html +27
#
#   (3) a FAILED tool block. Same structure as (1) with a `✗` bullet for its
#       head, captured verbatim on a live drive in
#       `copilot-failed-edit-reply.txt` and found sitting in a real
#       `transcript.md`, rendered to the captain as a design decision:
#
#           ✗ Edit mockup.html
#           ␣␣└ Multiple matches found
#
#       It is folded into (1) rather than given a recognizer of its own: same
#       verb list, same indented rows, same REQUIRED `└` close. `✗ Delete the
#       old rail (it never shipped)` has no closing row and is a captain
#       writing, so it survives — that requirement is the whole guarantee.
#
# A FENCE IS THE CAPTAIN QUOTING, NOT THE CLI SPEAKING, so nothing inside one is
# touched. Measured: both engines put their ASCII diagrams in fences, and
# copilot's own fenced diagram draws rows at the very indent its argument rows
# use. This is not a second recognizer — it is the same parser reading the one
# piece of markdown structure that says "these bytes are content".
_COPILOT_BLOCK_HEAD = re.compile(
    r"^[●✗] (?:List directory|Read|Create|Edit|Write|Delete|Fetch|Task)\b"
    r"|^/ Search \((?:glob|grep)\)\s*$")
_COPILOT_ARG_ROW = re.compile(r"^  │ \S")
_COPILOT_RESULT_ROW = re.compile(r"^  └ \S")
_COPILOT_WRITE_ROW = re.compile(r"^● (?:Create|Edit|Write) \S+(?: [+-]\d+)+$")


def _strip_copilot_tool_blocks(lines):
    """Copilot's tool blocks removed from `lines`; everything else returned
    byte for byte, in order — and the HOLE each removal leaves, closed.

    S128 / FL-005 (a), confirmed live: a real grounding pass produced a
    `basis.md` of 120 lines with 49 of them blank, the model's narration
    floating over the gaps where the blocks had been. A block is printed with a
    blank line on either side of it, so removing the block alone leaves both
    blanks behind and every removal widens the file by one more hole.

    `_close_the_hole` runs ONLY immediately after a removal this function has
    already decided on structurally, and it asks exactly one question of a
    line: is it blank. It never inspects prose, never decides anything from
    shape or wording, and can only ever drop a blank line — the S126 ruling
    ("stop guessing") is untouched, because guessing is what it does not do.

    What it deliberately does NOT do:
      · it does not collapse a blank run the model wrote where nothing was
        removed — three blank lines between two paragraphs stay three;
      · it cannot reach inside a fence, because a fence takes the branch above
        and no removal ever happens there (S125 shipped a cleverer regex that
        silently ate ASCII diagrams, and it was cured by deletion);
      · it never removes the LAST blank — a block that sat between two
        paragraphs leaves those paragraphs one blank line apart, exactly as if
        it had never been printed.
    """
    out = []
    i = 0
    n = len(lines)
    # WHICH delimiter opened the fence we are inside, or None. S128 fix round 1
    # (L-3): this used to be a bool set from ```` ``` ```` alone, so CommonMark's
    # OTHER fence — `~~~` — was not a fence here at all and the block recogniser
    # ran straight through one, deleting a captain's diagram and leaving an
    # empty `~~~ ~~~` pair behind. Recognising one more delimiter is structural
    # and asks nothing about prose; the S126 "stop guessing" ruling is untouched.
    # A fence is closed by its OWN character, so a `~~~` inside a ``` block is
    # content (and is kept, which is the direction this file always runs).
    fence = None

    def _close_the_hole(at):
        """Index past the blank lines a just-removed block left behind.

        Only when `out` already ends on a blank (or is empty): that blank is
        the separator the model's own text already had, so consuming the ones
        after the block restores the spacing to what it would have been with no
        block printed at all. With no blank before the block, the one after it
        is the model's only separator and is kept.
        """
        if out and out[-1].strip():
            return at
        while at < n and not lines[at].strip():
            at += 1
        return at

    while i < n:
        line = lines[i]
        bare = line.lstrip()
        if bare.startswith("```") or bare.startswith("~~~"):
            if fence is None:
                fence = bare[0]
            elif bare[0] == fence:
                fence = None
            out.append(line)
            i += 1
            continue
        if fence is not None:
            out.append(line)
            i += 1
            continue
        if _COPILOT_WRITE_ROW.match(line):
            i = _close_the_hole(i + 1)
            continue
        if _COPILOT_BLOCK_HEAD.match(line):
            j = i + 1
            while j < n and _COPILOT_ARG_ROW.match(lines[j]):
                j += 1
            if j < n and _COPILOT_RESULT_ROW.match(lines[j]):
                # head + its argument rows + the closing row
                i = _close_the_hole(j + 1)
                continue
        out.append(line)
        i += 1
    return out


def _strip_tool_trace(text, engine=None):
    """The engine's tool trace, removed from text about to become a FILE.

    `engine` is the CLI that produced `text` — the session's own, resolved the
    way every other per-engine decision here resolves it. Only copilot prints a
    trace to remove; on claude, and on any engine nobody has measured, this
    returns the text unchanged.
    """
    lines = (text or "").replace("\r\n", "\n").split("\n")
    if _is_copilot(engine):
        lines = _strip_copilot_tool_blocks(lines)
    return "\n".join(lines).strip("\n")


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


# The whole-document fences that mean "the engine could not save this".
# NOT a classifier and not a wording match: the tell is that the reply CONTAINS
# A WHOLE FILE. When a design turn has write tools, a complete document in the
# prose and nothing on disk is a turn whose write channel failed, whatever the
# accompanying sentence said (the measured one was "I can't write files
# (read-only, no write tool), so here is the complete mockup.html for you to
# save… Save this as mockup.html at the project root when ready" — and it came
# back `status: "ok"` with an empty preview).
_WHOLE_DOC = re.compile(r"<!doctype\s+html|<html[\s>]", re.I)


def _reply_carries_an_unsaved_file(raw):
    """True when a reply's fenced blocks contain a whole HTML document.

    Scans FENCES only — a mockup discussed in prose ("the <html> element") is
    not a file, and a turn that merely answered a question must stay a clean
    `ok` (that is the regression this narrowness protects)."""
    lines = (raw or "").replace("\r\n", "\n").split("\n")
    i, n = 0, len(lines)
    while i < n:
        if not _FENCE_ANY.match(lines[i]):
            i += 1
            continue
        i += 1
        body = []
        while i < n and not _FENCE_CLOSE.match(lines[i]):
            body.append(lines[i])
            i += 1
        i += 1
        if _WHOLE_DOC.search("\n".join(body)):
            return True
    return False


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


# ── S169 FIX ROUND 1: QUOTING AN ENGINE THAT DIED ──────────────────────────
#
# WAS: `last = (raw.strip().splitlines() or [""])[-1].strip()`, printed as
# "It said: …". MEASURED on the tester's live copilot drive and reproduced by
# hand on 2026-08-06, the whole of a real failing turn's tail:
#
#     Execution failed: CAPIError: 400 Could not process image (Request ID: …)
#
#
#     Changes    +0 -0
#     AI Credits 0 (7s)
#     Resume     copilot --resume=796ade4f-dc11-43fe-9503-1aed9883fcdb
#
# copilot ALWAYS ends with that fixed footer, so "the last line" was
# STRUCTURALLY GUARANTEED to be a resume command and could never once be the
# error. The reason sat four non-empty lines up and was thrown away — and the
# banner then looked STALE, because two failures of the same warm session
# quote the same session id.
#
# THE RULE MUST NOT KNOW THE CLI. Pattern-matching "Changes"/"AI Credits"/
# "Resume" is the same brittle road one door over: it is a per-engine corpus
# that goes stale the moment a CLI reflows its footer (S126 already lost a
# captured fixture to exactly that), and claude's failing tail looks nothing
# like this one.
#
# So the daemon stops CLAIMING to know which line is the error and shows the
# TAIL, verbatim, labelled as what it is. It is honest about its own ignorance
# — the same rule this round applies to the hand-off brief — and it is
# CLI-agnostic by construction: whatever an engine prints on the way out, the
# last few lines of it are in front of the captain.
_ENGINE_TAIL_LINES = 8
_ENGINE_TAIL_LINE_CHARS = 200
_ENGINE_TAIL_CHARS = 900


def _engine_tail(raw, lines=_ENGINE_TAIL_LINES):
    """The last few non-empty lines an engine printed, for a human to read.

    Blank lines are dropped (a CLI pads its footer and a blank line is not
    evidence), each line is bounded, and the whole is bounded — a worker that
    dies mid-stack-trace must not put a screenful into a banner.
    """
    out = []
    for line in reversed(str(raw or "").replace("\r\n", "\n").split("\n")):
        line = line.strip()
        if not line:
            continue
        if len(line) > _ENGINE_TAIL_LINE_CHARS:
            line = line[:_ENGINE_TAIL_LINE_CHARS - 1] + "…"
        out.append(line)
        if len(out) >= max(1, lines):
            break
    out.reverse()
    text = "\n".join(out)
    if len(text) > _ENGINE_TAIL_CHARS:
        text = "…" + text[-(_ENGINE_TAIL_CHARS - 1):]
    return text


# ── S169 FIX ROUND 1: A PASTED IMAGE THAT IS BROKEN NEVER REACHES A SESSION ──
#
# THE DEFECT, shipped by this session's own FL-014 work and measured live. The
# tester pasted a 78-byte PNG; copilot's API answered
# `CAPIError: 400 Could not process image`; and because a holodeck turn RESUMES
# a warm session, that image was baked into the conversation — every later turn
# died identically WITH NO ATTACHMENT AT ALL. Reproduced by hand against live
# copilot on 2026-08-06: a fresh session fed the tester's exact bytes died, and
# `--resume`ing it with a plain "Say OK." died the same way. One click, and a
# program was permanently unusable.
#
# WHAT THE FILE ACTUALLY IS — and this is why the check is not a guess. It is a
# CORRUPT PNG: `IHDR` is fine, and the single `IDAT` chunk's CRC32 is
# `7de298b7` where the file declares `f7a4b0e8`, its zlib stream is truncated,
# and the chunk walk runs off the end of the buffer. It is not "small" — a
# hand-built INTACT 2×2 PNG was measured going through live copilot fine, twice,
# and so were 4×4, 8×8, 16×16 and 32×32. A size floor would have been an
# invented threshold that the measurement had already falsified.
#
# So the rule is the FORMAT'S OWN, not a threshold and not a classifier: walk
# the container the way its specification defines it and refuse a file that
# does not hold together. PNG carries a CRC per chunk, which makes this exact.
#
# HONESTY ABOUT WHAT IT CANNOT DO: it proves a file is STRUCTURALLY INTACT, not
# that an engine will accept it. An engine may refuse a perfectly good image for
# its own reasons, which is why the recovery path (`_holodeck_turn` re-mints the
# warm session after a failed turn that carried an image) exists beside this and
# not instead of it. An unrecognised format is left ALONE — refusing what it
# cannot judge would be the surface claiming knowledge it does not have.
def _image_defect(raw):
    """"" if `raw` holds together as an image, else what is wrong with it.

    Judges only formats it can actually parse. `_IMAGE_SUFFIX`'s four types are
    all covered; anything else answers "" (not judged) rather than refused.
    """
    data = raw or b""
    if not data:
        return "it is empty — 0 bytes arrived"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return _png_defect(data)
    if data[:3] == b"\xff\xd8\xff":
        # JPEG: the End Of Image marker is the last thing in a complete file.
        # A truncated JPEG — the ordinary way a paste goes wrong — has none.
        return "" if data.rstrip(b"\x00")[-2:] == b"\xff\xd9" else (
            "the JPEG data stops before the end of the picture")
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "" if data[-1:] == b"\x3b" else (
            "the GIF data stops before the end of the picture")
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        want = struct.unpack("<I", data[4:8])[0] + 8
        return "" if len(data) >= want else (
            "the WEBP data stops before the end of the picture (%d bytes of a "
            "declared %d)" % (len(data), want))
    return ""


def _png_defect(data):
    """"" if this PNG's chunk stream is intact, else what is wrong with it.

    Every PNG chunk carries its own CRC32 over `type + payload`, so this is the
    format checking itself — no threshold is invented anywhere.
    """
    i, seen_end = 8, False
    while i < len(data):
        if i + 8 > len(data):
            return "its data is cut short %d bytes in" % i
        length = struct.unpack(">I", data[i:i + 4])[0]
        kind = data[i + 4:i + 8]
        if i + 12 + length > len(data):
            return ("its %s section says it is %d bytes long and the file ends "
                    "first" % (kind.decode("ascii", "replace"), length))
        payload = data[i + 8:i + 8 + length]
        want = struct.unpack(">I", data[i + 8 + length:i + 12 + length])[0]
        if (zlib.crc32(kind + payload) & 0xffffffff) != want:
            return ("its %s section fails its own checksum — the picture data "
                    "is damaged" % kind.decode("ascii", "replace"))
        if kind == b"IEND":
            seen_end = True
        i += 12 + length
    if not seen_end:
        return "it has no end-of-image marker — the picture is incomplete"
    return ""


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

    __slots__ = ("program", "engine", "engine_recorded", "mode", "grounded",
                 "sidecar_dir", "program_dir", "target_repo", "worker_sid",
                 "started", "turns", "files_changed", "done", "last_reply",
                 "proc", "turn_settled", "opened_at", "last_touched", "busy",
                 "turn_started", "turn_thread", "restarted")

    def __init__(self, program, engine, mode, sidecar_dir, program_dir,
                 target_repo, engine_recorded=False):
        self.program = program
        self.engine = engine
        # S126 FIX ROUND 5 — is `engine` a FACT out of this program's own
        # record, or merely what is running right now? The surface may say
        # "designed on copilot" only for the first, and every program written
        # before round 5 is the second.
        self.engine_recorded = bool(engine_recorded)
        self.mode = mode
        # S125 fix round 1 — `mode` is the posture the NEXT turn runs in, and it
        # MOVES: a grounded program runs its one read-only pass and then spends
        # the rest of its life in the design posture (see `_switch_to_design`).
        # `grounded` is the durable fact — that this program's mockup is built
        # on a basis it read out of the captain's project — and it is what the
        # header chip and `basis.md` link hang off, so the chip does not vanish
        # the moment the room becomes writable.
        self.grounded = (mode == "grounding")
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
        # S125 (D8) — the program list shows RECENCY in plain language, so the
        # two clocks it needs live on the session. `last_touched` moves on every
        # turn; a program opened and never spoken to reads from `opened_at`.
        self.opened_at = time.time()
        self.last_touched = self.opened_at
        # S126 — THE SERVER-SIDE TURN CLAIM. The deck guards overlapping sends
        # with `HOLO.busy`, which is a courtesy, not a fence: two `/say` calls
        # from two tabs (or a curl) both spawned a worker on the SAME warm
        # session id, the second overwrote `proc` so `end` could no longer stop
        # the first, and — now that every turn commits the room — two turns
        # would be staging one working tree at once. Claimed and released under
        # `_holodeck_lock`, so the check and the claim are one operation.
        self.busy = False
        # S128 (FL-002) — WHEN that claim was taken, and BY WHICH THREAD.
        # `busy` alone could only ever answer "something is happening"; a
        # captain who walked away needs "for how long", and that is a fact only
        # the daemon holds. `turn_thread` is what keeps the turn's OWN answer
        # honest: that payload is built inside `_run_turn` while the claim is
        # still held, so without it every completed `/say` would come back
        # saying the turn it is answering is still in flight.
        #
        # WRITE ORDER IS LOAD-BEARING (see `_claim_turn`/`_release_turn`):
        # these are read WITHOUT the lock, so `turn_started` is set before
        # `busy` and cleared after it — a reader that sees `busy` therefore
        # always sees a start time to go with it.
        self.turn_started = None
        self.turn_thread = None
        # S126 — this session was REBUILT from the room on disk (a warm
        # restart), so its opening prompt replays `transcript.md` and the
        # surface says plainly that the worker is a fresh one carrying the
        # history. It is NOT a resumed session and nothing may imply it is.
        self.restarted = False


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

    # ── S177: one repo scan per read request, not fourteen ──────────────────
    # `_waiting_counts → _waiting_children → _log_dispatch_is_stale →
    # _batch_short_of_its_gate → _waiting_children` is MUTUALLY RECURSIVE, and
    # every arm re-walks the missions dir. `_log_parent_ids`'s docstring shows
    # the quadratic was already foreseen ("…is itself a full scan, so asking it
    # about every mission on the board would be quadratic for no reason") and
    # guarded at the OUTER loop; the inner recursion went on re-walking. That is
    # 14 scans per board render.
    #
    # The recursion itself is a correct reading of a subtle state (S163 round 7
    # D3 — a resolver that died mid-batch must leave its bugs visible), so it is
    # not being rewritten. It is being made CHEAP: a read request opens a scope,
    # every `_linked_children` inside it answers from ONE snapshot, and the scope
    # closes on the way out.
    #
    # THREAD-LOCAL, and that is load-bearing, not caution. The daemon is a
    # ThreadingHTTPServer: two boards can render at once, and a memo kept on the
    # instance would let one request serve another request's snapshot — a defect
    # that would surface as a board that is briefly, inexplicably wrong, and
    # would be near-impossible to reproduce.
    #
    # OUTSIDE a scope there is NO memo at all (`_log_scan_memo()` → None), so
    # every write path calling `_linked_children` behaves exactly as it always
    # has: a fresh read of disk, no staleness window.
    _log_scan_state = threading.local()

    def _log_scan_memo(self):
        """The active request's snapshot dict, or None when no scope is open."""
        return getattr(LogFacts._log_scan_state, "memo", None)

    @contextlib.contextmanager
    def _log_scan_scope(self):
        """Open a read-request scope in which the missions dir is scanned once.

        Re-entrant: a nested scope joins the outer one rather than shadowing it,
        so an overlay that calls another overlay still scans once. Always
        restores the previous value — including on an exception, or a daemon
        that raised once would serve a frozen board for the rest of its life.
        """
        state = LogFacts._log_scan_state
        previous = getattr(state, "memo", None)
        if previous is None:
            state.memo = {}
        try:
            yield state.memo
        finally:
            state.memo = previous

    def _linked_children(self, parent):
        """Every logged-bug child of `parent`, as review-panel rows.

        S177 — THE ORDER OF THE TWO TESTS IS THE WHOLE PERFORMANCE STORY. This
        used to build `self._reader.mission(name)` — a FULL mission detail — for
        every mission in the repo, and only then read `parentMission` off
        state.json to decide whether it wanted it. The cheap test was already
        here; it just ran after the expensive work it gates. On a repo with 56
        missions and 4 children that is 52 detail builds thrown away, and this
        scan is reached ~14 times per board render through the
        `_waiting_children` ⇄ `_log_dispatch_is_stale` recursion, so it cost
        784 builds and 2.3 SECONDS per request. Test the key first; pay for the
        card only for a child. Same list out, element for element.
        """
        memo = self._log_scan_memo()
        if memo is not None:
            # Inside a read-request scope the dir is walked ONCE, for EVERY
            # parent at the same time — see `_children_by_parent`. Keying the
            # memo per parent instead would still cost one full walk per parent,
            # and a real repo has several (DX-Scorecard: 8 parents, 56 missions
            # = 448 state.json loads a render).
            if "byParent" not in memo:
                memo["byParent"] = self._children_by_parent()
            return memo["byParent"].get(parent, [])
        out = []
        missions_dir = self._missions_dir()
        if not os.path.isdir(missions_dir):
            return out
        for name in sorted(os.listdir(missions_dir)):
            sp = os.path.join(missions_dir, name, "state.json")
            if not os.path.isfile(sp):
                continue
            # read parentMission straight off disk (not part of the card shape).
            # FIRST: it is one small json load, against a whole detail build.
            if _read_json_key(sp, "parentMission") != parent:
                continue
            child = self._child_row(name, sp)
            if child is not None:
                out.append(child)
        return out

    def _children_by_parent(self):
        """{parent id -> [child row]} from ONE walk of the missions dir.

        S177. The scoped half of `_linked_children`: the same rows, grouped, so
        a render that asks about eight parents pays for one walk rather than
        eight. Order within a parent is `sorted(listdir)`, exactly as the
        per-parent path produces it.
        """
        out = {}
        missions_dir = self._missions_dir()
        if not os.path.isdir(missions_dir):
            return out
        for name in sorted(os.listdir(missions_dir)):
            sp = os.path.join(missions_dir, name, "state.json")
            if not os.path.isfile(sp):
                continue
            pm = _read_json_key(sp, "parentMission")
            if not pm:
                continue
            child = self._child_row(name, sp)
            if child is not None:
                out.setdefault(pm, []).append(child)
        return out

    def _child_row(self, name, sp):
        """One logged-bug child as the review panel wants it, or None.

        Lifted out of `_linked_children` unchanged (S177) so the per-parent and
        the one-walk paths cannot drift into producing different rows.
        """
        # The `card is None` guard predates S177 and stays: a child whose detail
        # cannot be built has to drop out, not crash the overlay.
        card = self._reader.mission(name)
        if card is None:
            return None
        # S74: a logged bug is a Mission whose estimate is computed from its bug
        # PRD — surface the SAME estimator readout the board card and Launch
        # panel show (ONE cost pill, TWO difficulty pills, the per-stage model
        # mix) so the Mission-Log review panel can render each bug with its
        # suggested model + cost/difficulty, REUSING the card shape (card already
        # carries `pills`/`modelMix` off the child's estimate.json via the
        # LocalAdapter). Plus the persisted captain override so the panel can
        # pre-fill its steer field.
        child = {"id": card["id"], "issue": card.get("issue"),
                 "title": card.get("title"), "stage": card.get("stage"),
                 "type": card.get("type"),
                 "pills": card.get("pills"),
                 "modelMix": card.get("modelMix"),
                 # S163 fix round 3: the two signals a DRIVER produces, carried
                 # so `_waiting_children` can tell a bug nothing has started from
                 # one resolve-logs already scheduled. (`dispatched` is
                 # deliberately NOT here — it is the ESTIMATOR's footprint and is
                 # true from birth; see `_mark_log_dispatched`.)
                 "queued": bool(card.get("queued")),
                 "running": bool(card.get("running"))}
        ov = _read_json_key(sp, "modelOverride")
        if isinstance(ov, dict) and ov.get("scope") and ov.get("tier"):
            child["override"] = "%s:%s" % (ov["scope"], ov["tier"])
        return child

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
        """S177: open the ONE repo-scan scope, then do the real work.
    
        Every `_linked_children` beneath this call — including the ones
        reached through the `_waiting_children` recursion — answers from a
        single snapshot instead of re-walking the missions dir. Purely a
        cost change: the facts published are identical.
        """
        with self._log_scan_scope():
            return self._log_overlay_body(board)

    def _log_overlay_body(self, board):
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
        """S177: open the ONE repo-scan scope, then do the real work.
    
        Every `_linked_children` beneath this call — including the ones
        reached through the `_waiting_children` recursion — answers from a
        single snapshot instead of re-walking the missions dir. Purely a
        cost change: the facts published are identical.
        """
        with self._log_scan_scope():
            return self._log_overlay_mission_body(mission)

    def _log_overlay_mission_body(self, mission):
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
        # S124 — active HOLODECK programs, keyed by sessionId. The in-memory
        # dict is now a CACHE of live conversations, not the record: S126 put
        # the record in the sidecar itself, so `holodeck_list` reads the disk
        # and a restart loses the warm worker session, never the program.
        self._holodeck = {}
        self._holodeck_lock = threading.Lock()
        # The hand-off DERIVATION's results, keyed by a fingerprint of the
        # files it read plus the repo it read them against — NEVER the session
        # id (S170: a restarted daemon mints a new one for the same room, and a
        # session-keyed record could never be found again).
        #
        # THIS DICT IS A CACHE, NOT THE RECORD. S169's was both, which was fine
        # for a hint about a list the captain already had; a finished derivation
        # is a section of his brief that cost 154–220s, so it is written into
        # the program's ROOM and read back from there when this is empty. What
        # lives here and nowhere else is the IN-FLIGHT state, deliberately: a
        # fresh daemon owns no running pass, so it must not find one.
        self._handoff_derives = {}
        self._handoff_derive_lock = threading.Lock()
        # S126 — ONE git working tree per sidecar, and `git add -A` + `commit`
        # is not re-entrant against it: two turns landing together raced on
        # `index.lock`, and a commit that fails is swallowed by `_sidecar_commit`
        # (best-effort by design) — so the LOSS was silent. Two programs may
        # still run at once; only the commit is serialised, keyed by sidecar
        # path so two different sidecars never wait on each other.
        self._sidecar_locks = {}
        self._sidecar_locks_lock = threading.Lock()
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
    # ── S183: THE FOUNDATION GATE on the board ────────────────────────────────
    # The viewscreen is a VIEWPORT, never a reimplementation (the harness-parity
    # principle): a repo the CLI refuses to file against must be refused here in
    # the same words, decided by the same seam
    # (skills/lcars-init/foundation-gate.sh), which SESSION 184 replaces with the
    # real Establish Vision flow.
    #
    # WHY IT IS ALSO HERE, and not left to file.sh's own gate: `align_start` and
    # `holodeck_start` HIRE A WORKER before file.sh is ever reached, and the whole
    # point of the gate is that nothing is hired on a repo with no foundation.
    #
    # DEGRADES TO ALLOW on anything it cannot answer — script missing, bad JSON,
    # non-zero exit, timeout — exactly like `_test_readiness`. It refuses only on
    # a positive `allowed: false`, never on an absence of information.
    def _resolve_foundation_gate(self):
        """The gate helper path: wired script → env → in-repo → installed.

        Mirrors LocalAdapter._resolve_readiness_script rung for rung."""
        wired = self.scripts.get("foundation_gate")
        if wired:
            return wired
        env = os.environ.get("LCARS_FOUNDATION_GATE_BIN")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-init", "foundation-gate.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-init",
                            "foundation-gate.sh")

    def _resolve_establish_vision(self):
        """establish-vision.sh — the ONE Establish Vision machinery, shared with
        the CLI front door. Same resolution ladder as the foundation gate."""
        wired = self.scripts.get("establish_vision")
        if wired and os.path.isfile(wired):
            return wired
        env = os.environ.get("LCARS_ESTABLISH_VISION_BIN")
        if env:
            return env
        here = os.path.dirname(os.path.abspath(__file__))
        in_repo = os.path.normpath(os.path.join(
            here, "..", "..", "skills", "lcars-init", "establish-vision.sh"))
        if os.path.isfile(in_repo):
            return in_repo
        home = os.environ.get("HOME", os.path.expanduser("~"))
        return os.path.join(home, ".claude", "skills", "lcars-init",
                            "establish-vision.sh")

    def _vision_brief(self):
        """The foundation brief for THIS repo (ADR-002: shell it, never restate
        it here — a second copy of the fence is a second fence to drift). Empty
        string when the helper cannot be reached, which degrades the grill to a
        normal Align rather than sinking the console."""
        try:
            proc = subprocess.run(
                ["bash", self._resolve_establish_vision(), "--brief"],
                cwd=self.repo_root, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
            return (proc.stdout or b"").decode("utf-8", "replace").strip()
        except Exception:
            return ""

    def vision_file(self, idea=None, stack=None, reasons=None, deferred=None,
                    slice_=None, engine=None):
        """POST /api/vision/file — file the INITIALIZATION mission.

        The viewscreen's half of BOTH FRONT DOORS, ONE FLOW: it dispatches the
        SAME `establish-vision.sh --file` the CLI runs, with the same four
        inputs, so the same answers produce a byte-identical mission whichever
        door the captain walked through. The daemon assembles no PRD and writes
        no vision doc of its own — there is one implementation and this is not
        it.

        `stack` is whatever the captain ACCEPTED — the recommendation or his
        override. That is the whole point of the override: it is what lands.

        `engine` (S195) is the CLI he picked on the front door, and it rides as
        a FLAG rather than as $LCARS_WORKER_BIN. That is not a style choice: the
        env var is injected into EVERY dispatch by `_resolve_run` (the daemon's
        own `worker_bin`), so an env-var pick would be indistinguishable from
        the daemon's default and would lose to a persisted workerBin (S159). The
        flag is the top of file.sh's one precedence, and establish-vision.sh
        hands it straight down.
        """
        stack = (stack or "").strip()
        if not stack:
            raise ActionError(400, "missing required field: stack")
        idea = (idea or "").strip()
        tmp = []

        def _tmpfile(text):
            fd, path = tempfile.mkstemp(suffix=".txt")
            with os.fdopen(fd, "w") as fh:
                fh.write(text)
            tmp.append(path)
            return path

        def _lines(v):
            if isinstance(v, (list, tuple)):
                return "\n".join(str(x).strip() for x in v if str(x).strip())
            return str(v or "").strip()

        try:
            args = ["--file", "--idea", _tmpfile(idea + "\n"), "--stack", stack]
            eng = (engine or "").strip()
            if eng:
                args += ["--engine", eng]
            r = _lines(reasons)
            if r:
                args += ["--reasons", _tmpfile(r + "\n")]
            d = _lines(deferred)
            if d:
                args += ["--deferred", _tmpfile(d + "\n")]
            sl = (slice_ or "").strip()
            if sl:
                args += ["--slice", sl]
            # Dispatched through the SAME `_run` every other skill goes
            # through (one env wiring, one failure shape), with the script
            # resolved lazily so a daemon started before this round still finds
            # it.
            if not self.scripts.get("establish_vision"):
                self.scripts["establish_vision"] = self._resolve_establish_vision()
            self._run("establish_vision", args)
        finally:
            for p in tmp:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        return self._reader.board()

    def _foundation_verdict(self):
        """{"foundation","allowed","message"} from the shared seam, or None."""
        script = self._resolve_foundation_gate()
        try:
            proc = subprocess.run(
                ["bash", script, "--json"], cwd=self.repo_root,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=20)
            blk = json.loads((proc.stdout or b"").decode("utf-8", "replace"))
            if isinstance(blk, dict) and "allowed" in blk:
                return blk
        except Exception:
            return None
        return None

    def _require_foundation(self, what="file a mission"):
        """Raise 409 with the seam's own words when this repo has no foundation.

        409 CONFLICT, not 400: nothing about the captain's REQUEST is wrong —
        the repo is in a state that cannot take one yet. `data.foundation` lets
        the front end lock the affordance without re-asking."""
        blk = self._foundation_verdict()
        if not blk or blk.get("allowed") is not False:
            return
        msg = (blk.get("message") or "").strip() or (
            "This repo has no test foundation yet, so LCARS cannot %s here. "
            "Start with Establish Vision." % what)
        raise ActionError(409, msg,
                          {"foundation": blk.get("foundation") or "greenfield",
                           "establishVision": True})

    def file_mission(self, idea, engine=None, mission_type="feature",
                     images=None, holodeck=None, holodeck_scope=None,
                     holodeck_answers=None):
        """POST /api/mission — file a new mission from a free-form idea.

        engine selects the worker CLI ($LCARS_WORKER_BIN) for this mission.
        `images` (S92) are pasted screenshots: each is staged under repo_root and
        threaded to file.sh as a repeated `--attach <path>` so file.sh persists it
        as a DURABLE mission attachment (attachments/ + prd.md ref + state.json).
        The staged temp copies are reaped here once file.sh has copied them in.
        Returns the freshly-assembled board state.

        `holodeck` (S127) is a holodeck PROGRAM's session id — never a path. The
        daemon resolves that program's room itself and rides its `mockup.html` +
        `concept.md` down this same `--attach` road, and appends the hand-off
        guidance to the idea. On success the program is LOCKED (D11).
        """
        idea = (idea or "").strip()
        if not idea:
            raise ActionError(400, "missing required field: idea")
        self._require_foundation("file a mission")
        holo, handoff = self._handoff_attach(holodeck)
        mtype = "bug" if str(mission_type).strip().lower() == "bug" else "feature"
        # The TITLE comes from what the CAPTAIN wrote, before the guidance block
        # is appended — a mission called "How to read the attached mockup" would
        # be the plumbing naming itself on his board.
        title = self._title_from_idea(idea)
        if holo is not None:
            concept = self._handoff_concept_text(handoff)
            idea = self._handoff_idea(idea, self._handoff_scope(holodeck_scope),
                                      concept, holodeck_answers)
        prd = _PRD_TEMPLATE.format(title=title, type=mtype, idea=idea)
        prd_path = self._tmp_prd(prd)
        staged = self._stage_images(images)
        env_extra = {}
        if engine:
            env_extra["LCARS_WORKER_BIN"] = engine
        args = ["--prd", prd_path]
        for p in staged + handoff:
            args += ["--attach", p]
        before = self._mission_ids() if holo is not None else set()
        try:
            self._run("file", args, env_extra=env_extra)
        finally:
            for p in [prd_path] + staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        out = {"board": self._reader.board()}
        if holo is not None:
            out["holodeck"] = self._handoff_record(holo, before)
        return out

    # -- Park & Align (S137): file a PARKED mission (pre-PRD standby) ------------
    def park_mission(self, idea, engine=None, images=None, holodeck=None,
                     holodeck_scope=None, holodeck_answers=None):
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
        self._require_foundation("file a mission")
        # S127 — a holodeck hand-off travels this road too, and it is the one
        # the deck's ▦ FILE MISSION uses: the card lands on the board instantly
        # with the mockup and the concept doc already in its attachments/, and
        # the captain drives it from there exactly as he asked for.
        holo, handoff = self._handoff_attach(holodeck)
        if holo is not None:
            concept = self._handoff_concept_text(handoff)
            idea = self._handoff_idea(idea, self._handoff_scope(holodeck_scope),
                                      concept, holodeck_answers)
        eng = (engine or "").strip()
        # write the idea to a tmp file so multi-line ideas survive intact
        # (file.sh --idea <file> reads the verbatim capture; a positional would
        # word-split on whitespace).
        idea_path = self._tmp_prd(idea + "\n")
        staged = self._stage_images(images)
        args = ["--park", "--idea", idea_path]
        if eng:
            args += ["--engine", eng]
        for p in staged + handoff:
            args += ["--attach", p]
        before = self._mission_ids() if holo is not None else set()
        try:
            self._run("file", args)
        finally:
            for p in [idea_path] + staged:
                try:
                    os.unlink(p)
                except OSError:
                    pass
        out = {"board": self._reader.board()}
        if holo is not None:
            out["holodeck"] = self._handoff_record(holo, before)
        return out

    # -- the interactive Align grilling console (S70-B) --------------------------
    def align_start(self, idea, engine=None, images=None, mission_id=None,
                    holodeck=None, holodeck_scope=None, holodeck_answers=None,
                    vision=False):
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
        # S183 — the Align console HIRES A WORKER on its very first turn, so the
        # foundation gate has to fire before the session is opened, not after
        # file.sh eventually refuses. Completing an ALREADY-PARKED mission (mid)
        # is deliberately exempt: that mission was accepted before the gate and
        # the captain is finishing work already begun, exactly as `file.sh
        # --complete` is exempt on the CLI.
        # S184 — ESTABLISH VISION runs THIS grill, not a second interviewer
        # (brief item 5): it is Align pointed at a PROJECT instead of a feature.
        # So it is exempt from the gate for the same reason `file.sh
        # --initialization` is: this is the conversation that ESTABLISHES the
        # foundation, and gating it on the foundation existing would make the
        # gate unsatisfiable. Every OTHER way into this console still hits it.
        if not mid and not vision:
            self._require_foundation("start an alignment")
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
            #
            # IMAGES ONLY (S127 blocker). A holodeck hand-off parks an HTML
            # mockup and a markdown concept doc alongside any screenshots, and
            # this seam is the IMAGE road: copilot's `--attachment` REFUSES a
            # .html outright ("must be an image or native document") so the
            # opening turn died on spawn and the mission could not be aligned at
            # all. It is the same reasoning the grill-first holodeck branch
            # below already applies to its own files — applied here too. The
            # mockup and the concept doc still reach the cold stages by absolute
            # path through `attachments_extra_block` (skills/lcars-run/run.sh),
            # the road that was actually proven for them; state.json and
            # attachments/ keep the complete record either way.
            seed_paths = [p for p in self._parked_attachment_paths(mid)
                          if _is_image_path(p)]
        idea = (idea or "").strip()
        if vision:
            # THE SCOPE FENCE, IN THE GRILL'S OWN WORDS. The brief comes from
            # `establish-vision.sh --brief` — the SAME text the CLI front door
            # prints — so the model and the captain are reading one contract and
            # a viewscreen grill cannot quietly run under a different fence than
            # a CLI one. It is prepended to the idea exactly as the holodeck
            # hand-off prepends its brief: the interview machinery below is
            # untouched.
            brief = self._vision_brief()
            if not idea and brief:
                # `untested`: the front door does NOT ask what we are building,
                # so there is no idea to send. The brief IS the opening turn.
                idea = brief
            elif brief:
                idea = brief + "\n\n=== WHAT THE CAPTAIN SAID ===\n\n" + idea
        if not idea:
            raise ActionError(400, "missing required field: idea")
        # S127 — the OTHER hand-off road: grill first, then file. The program is
        # resolved (and refused if already sent) HERE, before a worker is
        # spawned, so a locked program cannot burn a grill it can never file.
        # Its files are attached at the DONE branch, not fed to the grill turns:
        # the per-turn attachment argv is the IMAGE road (copilot's
        # `--attachment`), and an HTML mockup is not an image. What the grill
        # gets is the brief and the guidance, in the idea text.
        holo_sid = (holodeck or "").strip() or None
        if holo_sid:
            holo, paths = self._handoff_attach(holo_sid)
            concept = self._handoff_concept_text(paths)
            idea = self._handoff_idea(idea,
                                      self._handoff_scope(holodeck_scope),
                                      concept, holodeck_answers)
        sid = uuid.uuid4().hex[:12]
        sess = _AlignSession(idea=idea, engine=(engine or "").strip() or None,
                             mission_id=mid, holodeck=holo_sid,
                             vision=bool(vision))
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
        # S128 (FL-009) — the worker call IS the turn, so it is what owns the
        # in-flight fact `align_overlay` publishes. The `finally` is the honest
        # half: every exit path (a clean turn, an engine that died, a 502 on an
        # unreadable reply) withdraws it, so a card can never be left insisting a
        # turn is running when nothing is. Scoped to the worker call ONLY — the
        # done branch's file.sh dispatch that follows is the FINALIZING state,
        # which is a different surface with its own copy.
        sess.turn_started = time.time()
        try:
            out = self._worker_turn(prompt, engine=sess.engine,
                                    session_id=sess.worker_sid, opening=opening,
                                    image_paths=image_paths)
        finally:
            sess.turn_started = None
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
        # S184 fix round 2 (D2) — THE RECOMMENDATION IS AN ANSWER TO THE
        # CAPTAIN, NOT A FILING. In vision mode the interview ends by handing
        # back stack / reasons / slice / deferred; the harness does not author a
        # PRD from it here — the captain accepts or overrides the stack on
        # screen 3 and `/api/vision/file` runs `establish-vision.sh --file`,
        # which is the ONE thing that writes the PRD and the vision doc.
        #
        # It is read BEFORE the done branch on purpose. A model that emits a
        # recommendation AND `status:"done"` has decided the stack for the
        # captain, and the brief's rule is "YOU RECOMMEND, YOU DO NOT DECIDE" —
        # so the screen wins, and the session stays open behind it.
        if sess.vision:
            rec = _vision_recommendation(turn)
            if rec:
                return {"sessionId": sid, "status": "recommendation",
                        "recommendation": rec, "prd": sess.prd}
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
            #
            # S127 — a holodeck hand-off filed through the GRILL. The program's
            # files are resolved again HERE (never held as paths across the
            # grill) and ride the same `--attach` road; the lock lands only
            # after the dispatch returned.
            holo, handoff, lost = self._handoff_attach_soft(sess.holodeck)
            before = self._mission_ids() if holo is not None else set()
            # S169 (FL-017) — THE FINALIZE IS THE FACT, and the daemon is the
            # only thing that can see it. Set around the dispatch and withdrawn
            # in the `finally` on EVERY exit path (a clean file.sh, a 502, an
            # estimator that died), exactly as `turn_started` is around the
            # worker call. The session is still in `self._align` for the whole
            # of this window — it is popped below — so `align_overlay` can read
            # it off the live session with no second store.
            sess.finalize_started = time.time()
            try:
                board, turn = self._finalize_with_heal(
                    sess, turn, list(sess.image_paths) + handoff)
            except Exception:
                # S178 CURE 2 — A FAILED FINALIZE MUST LEAVE THE GRILL
                # RESUMABLE. `sess.done` was set above, BEFORE the dispatch, and
                # the only thing that used to clear it was the pop further down
                # — which a raise skips. So the session survived STRANDED: still
                # in `self._align`, still `done=True`, and therefore invisible to
                # `align_session_sid` (which requires `not sess.done`). The card
                # lost ▹ RESUME ALIGN and offered START ALIGNMENT instead, which
                # would re-grill the captain from question 1 over a PRD fault he
                # did not cause. Measured live on issue 177.
                #
                # `last_question` is untouched by the done branch, and it is the
                # CLOSING "anything else before I file?" question — so putting
                # `done` back is the whole restore: RESUME lands him exactly
                # where he was, and answering again re-files. The draft is on
                # disk (cure 1) and the refusal reaches the console (below), so
                # nothing about the failure is silent.
                sess.done = False
                raise
            finally:
                sess.finalize_started = None
            self._reap_session_images(sess)
            with self._align_lock:
                self._align.pop(sid, None)
            resp = {"sessionId": sid, "status": "done",
                    "prd": turn.get("prd", sess.prd)}
            # S178 — the filing succeeded, but not on the first try. Say so, for
            # `_align_finalizing_fields`' reason: a repair that leaves no trace
            # is a minute of the captain's life he cannot account for. Absent on
            # a clean filing, so that payload is unchanged.
            if sess.heal_attempts:
                resp["healed"] = sess.heal_attempts
            if turn.get("adr"):
                resp["adr"] = turn["adr"]
            resp["board"] = board
            if holo is not None:
                resp["holodeck"] = self._handoff_record(holo, before)
            elif lost:
                resp["holodeck"] = {
                    "status": "draft", "missionId": "", "locked": False,
                    "warning": ("The mission was filed, but its holodeck "
                                "program could not be reached, so the mockup "
                                "and the concept doc did NOT ride along with "
                                "it: %s" % lost)}
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

    # ── S178: the finalize self-heals a REDRAFTABLE PRD ─────────────────────
    # THE INCIDENT. `file.sh --complete` refused the closing turn's PRD — for a
    # correct reason: it had dropped 5 of the design brief's 14 open questions,
    # and those questions are exactly what the Plan Stage reads. The gate was
    # right. What was wrong is that the harness treated a document fault as an
    # unrecoverable one, and handed it to the captain — who did not write that
    # PRD, a worker did. His words: "I don't know how to fix this as the user.
    # This should be handled by harness for me."
    #
    # The standing rule is older than this bug: EVERY GATE SELF-HEALS FIRST, the
    # human is the backstop. So a refusal the worker can act on goes back to the
    # worker, on the WARM session that already holds the whole grill — one more
    # continuation turn, no new prompt channel, no new stage, no new gate.
    #
    # WHAT MAKES A REFUSAL ACTIONABLE IS ITS EXIT CODE, and nothing else. See
    # `_PRD_REDRAFTABLE_EXIT`.

    def _finalize_with_heal(self, sess, turn, attach):
        """Dispatch the filing, repairing a REDRAFTABLE PRD up to the cap.

        Returns `(board, turn)` — the turn is returned because a heal replaces
        the PRD in it, and the response must show the captain the document that
        was actually filed rather than the one that was refused.

        Raises on exhaustion or on any non-redraftable failure; the caller
        (`_align_turn`) is what restores the session's resumability, because
        that is true of EVERY failed finalize and not just of an exhausted heal.
        """
        # A full cap per finalize. A session the captain resumes and re-files
        # must not inherit a spent one — he is back in the loop by then, which
        # is the only thing that makes another two turns legitimate.
        sess.heal_attempts = 0
        while True:
            try:
                if sess.mission_id:
                    board = self._complete_from_align(
                        sess.mission_id, turn, engine=sess.engine,
                        image_paths=attach)
                else:
                    board = self._file_from_align(
                        turn, engine=sess.engine, image_paths=attach,
                        initialization=sess.vision)
                return board, turn
            except ActionError as exc:
                if exc.skill_exit != _PRD_REDRAFTABLE_EXIT:
                    # An ENVIRONMENT failure — no mission, `gh` unauthenticated,
                    # a repo that is not a repo. A redraft cannot clear any of
                    # those, so healing one only burns tokens to fail again.
                    raise
                if sess.heal_attempts >= _ALIGN_HEAL_CAP:
                    raise self._heal_exhausted(sess, exc)
                sess.heal_attempts += 1
                prev_draft = exc.draft_path
                turn = self._align_repair_turn(sess, turn, exc)
                # The repair SUPERSEDED that draft, so on the fresh-filing lane
                # — where every dispatch mints its own scratch file — drop the
                # older one rather than leaving a heal's worth of near-identical
                # PRDs behind. Only AFTER the repair turn has actually produced
                # something: until then that file is the only copy there is. The
                # `--complete` lane rewrites ONE `prd-draft.md` in place and so
                # never accumulates; deleting it here would just open a window
                # with no draft on disk at all.
                if prev_draft and not sess.mission_id:
                    self._discard_align_draft(prev_draft)

    def _align_repair_turn(self, sess, turn, exc):
        """ONE repair turn on the warm grill: hand back the refusal, take the
        redrafted PRD, and return the turn to re-dispatch.

        The refusal rides in as a synthetic ANSWER on the existing continuation
        road — `_build_align_prompt(sess, opening=False)` builds its prompt from
        `sess.transcript[-1]["answer"]` — so this is the same warm session, the
        same argv shape and the same output contract as every other turn.

        Only the PRD (and an ADR, if it re-emitted one) is taken from the reply.
        Everything else about the turn — the model override, the status — is
        carried forward from the turn being repaired, so a repair cannot quietly
        change the mission's contract while fixing its wording.
        """
        answer = _ALIGN_HEAL_ANSWER % exc.message
        if sess.transcript and sess.transcript[-1].get("answer") is None:
            sess.transcript[-1]["answer"] = answer
        else:
            sess.transcript.append(
                {"question": "(lcars file refused the PRD)", "answer": answer})
        out = self._worker_turn(self._build_align_prompt(sess, opening=False),
                                engine=sess.engine,
                                session_id=sess.worker_sid, opening=False)
        repaired = _extract_json(out)
        if not isinstance(repaired, dict) or not (repaired.get("prd") or "").strip():
            # The repair turn produced nothing usable. Stop here rather than
            # spending the rest of the cap on a worker that is not answering —
            # and report the GATE's refusal, which is the thing the captain
            # needs to see, not "the repair turn was unreadable".
            raise self._heal_exhausted(sess, exc)
        sess.prd = repaired["prd"]
        merged = dict(turn)
        merged["status"] = "done"
        merged["prd"] = repaired["prd"]
        if (repaired.get("adr") or "").strip():
            merged["adr"] = repaired["adr"]
        return merged

    @staticmethod
    def _heal_exhausted(sess, exc):
        """The refusal the captain finally sees — built, not raised, so the
        caller's `raise` keeps the traceback honest.

        It must carry THREE things, because between them they are the difference
        between a dead end and a next move: what is still unresolved (the gate's
        own message — only the gate knows which questions were dropped), that
        the drafted PRD is NOT lost and where it is, and that the grill is still
        open behind it. NEVER a silent failure, and never an endless retry.
        """
        msg = ("the Align worker could not produce a PRD `lcars file` will "
               "accept. %d repair turn(s) were tried and this is still "
               "unresolved:\n\n%s" % (sess.heal_attempts, exc.message))
        if exc.draft_path:
            msg += ("\n\nNothing is lost — the drafted PRD is on disk at %s, "
                    "and the alignment is still open: reopen it with ▹ RESUME "
                    "ALIGN, answer the closing question again, and it re-files."
                    % exc.draft_path)
        out = ActionError(502, msg)
        out.skill_exit = exc.skill_exit
        out.draft_path = exc.draft_path
        return out

    def _file_from_align(self, turn, engine=None, image_paths=None,
                         initialization=False):
        """Persist a finished Align turn via file.sh (ADR-002 dispatch).

        S184 fix round 2 (D4) — `initialization` carries the vision grill's ONE
        exemption to file.sh. `lcars file` refuses a repo with no test
        foundation (S183, exit 4) and exempts exactly one filing:
        `--initialization`, the mission that BUILDS that foundation. Until this,
        the only caller passing it was `establish-vision.sh --file`, so a
        vision-mode grill that reached `status:"done"` finalized through the
        ordinary lane and was refused by the gate it exists to satisfy. False on
        every other road, which is every road but this one.

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
        if initialization:
            args = ["--initialization"] + args
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
        # S178 CURE 1 (the fresh-filing half). This lane has NO mission dir to
        # persist a draft into — `file.sh --prd` is what MINTS the mission — so
        # the best it can do is stop destroying what it already wrote. The
        # unlink used to sit in a `finally`, which runs on FAILURE too, so a
        # refused PRD was deleted on its way out and the only copy left was in
        # daemon memory. Now the scratch file SURVIVES a failure (it lives under
        # `.git/lcars/tmp/`, where git cannot see it) and the refusal names it,
        # so the draft is recoverable BY PATH. On success it is cleaned up
        # exactly as before — file.sh has written the real prd.md by then.
        try:
            self._run("file", args, env_extra=env_extra)
        except ActionError as exc:
            if not exc.draft_path:
                exc.draft_path = prd_path
            raise
        else:
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
        # S178 CURE 1 — THE DRAFT GOES ON DISK BEFORE THE DISPATCH CAN REFUSE
        # IT. On this lane the mission dir already exists, so the PRD the worker
        # just spent ten of the captain's answers producing is written there as
        # `prd-draft.md` and removed only when file.sh has written the real
        # `prd.md`. Measured live (issue 177): a refused filing left the mission
        # dir holding idea.md, state.json, attachments/ and NO PRD at all — the
        # only copy died in daemon memory when the request unwound.
        draft_path = self._persist_align_draft(mid, prd + "\n")
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
        except ActionError as exc:
            if draft_path and not exc.draft_path:
                exc.draft_path = draft_path
            raise
        else:
            # The filing landed: `prd.md` is the real document now, so the draft
            # would only be a stale second copy of it.
            self._discard_align_draft(draft_path)
        finally:
            for p in (prd_path, adr_path):
                if p:
                    try:
                        os.unlink(p)
                    except OSError:
                        pass
        return self._reader.board()

    def _persist_align_draft(self, mid, text):
        """S178 CURE 1 — write the Align draft PRD into the mission dir.

        Returns the path, or "" when it could not be written (a mission dir that
        is not there, a read-only disk). BEST EFFORT BY DESIGN: this exists to
        make a failure survivable, so it must never be the thing that turns a
        working filing into a failed one.

        `.git/lcars/missions/<id>/prd-draft.md` — inside `.git/`, so the target
        repo's working tree stays clean (CLAUDE.md), beside the artifacts it
        belongs with, and named so it can never be mistaken for the filed
        `prd.md` that only file.sh writes.
        """
        if not mid:
            return ""
        try:
            d = os.path.join(self._missions_dir(), mid)
            if not os.path.isdir(d):
                return ""
            path = os.path.join(d, "prd-draft.md")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(text)
            return path
        except OSError:
            return ""

    @staticmethod
    def _discard_align_draft(path):
        """Drop a draft the filing has superseded. Never raises."""
        if not path:
            return
        try:
            os.unlink(path)
        except OSError:
            pass

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

    def _align_busy_fields(self, sess):
        """The IN-FLIGHT fact for one align session — or `{}`, which is the point.

        S128 (FL-009, the reload half). The align twin of `_busy_fields`, and
        deliberately the same discipline: the DAEMON owns "a turn is running"
        and the surface reads it, because a browser that reloaded mid-scan has
        no way to know and its predecessor's guess is exactly what FL-009 was.

        WHEN IT IS PUBLISHED — an OPENING turn only: a session that is not done,
        has a worker call in flight (`turn_started`), and has no question yet.
        That last clause is the exact complement of `align_overlay`'s condition
        below, so the two facts partition the parked card's life and can never
        both be stamped: no question yet → `alignBusy` (⊹ Scanning…), question
        landed → `alignResume` (▹ RESUME ALIGN). A CONTINUATION turn running
        under an open question is therefore silent here on purpose — the card
        already has something better and truer to say.

        WHEN IT STOPS — `_align_turn`'s `finally`. Nothing here can outlive the
        worker call that set it, so a turn that DIES re-arms the card to START
        ALIGNMENT within one poll, which is correct: nothing is running. And if
        the DAEMON itself is restarted mid-turn, `self._align` is empty (the
        sessions are in-memory by contract) — the card reads as parked and
        clickable again, which is the same honest answer, because that turn's
        worker is orphaned and its reply has nowhere to land.

        ADDITIVE BY CONSTRUCTION, like `_busy_fields`: an idle session returns
        `{}` and the key is ABSENT, so a board with nothing in flight is
        byte-identical to the one every earlier test pins.

        NO COPY IN THE PAYLOAD, unlike `_busy_fields`' `busyLabel`/`busyReason`.
        There, a returning holodeck deck had no wording of its own and would
        have had to invent one. Here `board.js` already owns the sentence — the
        SAME "⊹ Scanning the codebase… 1m 35s" it renders from its own memory —
        and a second wording shipped from here is how the card and the console
        start contradicting each other. The daemon sends the FACT (when the turn
        began, how long it has run); the client renders it through the one
        `scanningLabel` both paths share, so a reloaded tab and the tab that
        clicked read identically.
        """
        if sess is None or sess.done or sess.last_question:
            return {}
        started = sess.turn_started
        if not started:
            return {}
        elapsed = max(0.0, time.time() - started)
        # `for` is computed HERE, at read time, for `_busy_fields`' reason: the
        # client renders elapsed without ever having to agree with this daemon
        # about the wall clock. Un-prefixed names (`since`/`for` rather than
        # `busySince`/`busyFor`) because the `alignBusy` key already carries the
        # prefix — the nesting mirrors its neighbour `alignResume` on the same card.
        return {"since": started, "for": round(elapsed, 1)}

    def _align_finalizing_fields(self, sess):
        """The IN-FLIGHT FINALIZE fact for one align session — or `{}` (S169).

        FL-017, and it is FL-009's cure applied to the state FL-009's own fix
        deliberately left alone. The closing answer POST runs the cost estimator
        and `file.sh --complete` inside itself; `board.js` covered that window
        with `FINALIZING_TIMEOUT_MS = 300000` — a client-side guess about how
        long the server takes which, on expiry, cleared the band and re-armed
        the card under a run that was still going. FL-009's ruling was written
        for exactly this: *"do NOT just raise the number. A bigger constant is
        the same guess with a longer fuse."*

        WHEN IT IS PUBLISHED: a session whose `finalize_started` is set. That is
        `_align_turn`'s done branch and nowhere else, so it cannot overlap with
        `alignBusy` (which is the worker call, and is None by then) or with
        `alignResume` (which needs an open question, and a done session has
        none). One card, one true state.

        WHEN IT STOPS: the dispatch's `finally`. An EVENT — the work settling —
        never a clock. And if the daemon dies mid-finalize its sessions die with
        it, so the card re-arms; that is the safety net, and it is a fact about
        the daemon rather than a timer's opinion about one.

        ADDITIVE BY CONSTRUCTION and NO COPY IN THE PAYLOAD, both for
        `_align_busy_fields`' reasons: an idle session returns `{}` and the key
        is absent, and `board.js` already owns the sentence ("◐ FINALIZING &
        COSTING…"), so a second wording shipped from here is how the card and
        the console start contradicting each other.
        """
        if sess is None:
            return {}
        started = sess.finalize_started
        if not started:
            return {}
        elapsed = max(0.0, time.time() - started)
        out = {"since": started, "for": round(elapsed, 1)}
        # S178 — …and, when the finalize is REPAIRING a refused PRD, how many
        # repair turns it has spent. The heal has to be visible or the captain
        # reads a long finalize as a hang; it goes HERE, on the fact the card
        # already renders, rather than as a new band or a new gate. Additive by
        # construction: absent when nothing has been healed, so an ordinary
        # finalize is byte-identical to the one every earlier test pins.
        if sess.heal_attempts:
            out["heals"] = sess.heal_attempts
        return out

    def _align_finalizing_for_mission(self, mission_id):
        """The in-flight `alignFinalizing` fact for a mission, or `{}` (S169).

        The `_align_busy_for_mission` twin, and it MUST agree with
        `align_overlay`'s loop — one rule read from two places, which is how a
        card and its detail modal are kept from disagreeing.
        """
        if not mission_id:
            return {}
        with self._align_lock:
            for sess in self._align.values():
                if sess.mission_id != mission_id:
                    continue
                fields = self._align_finalizing_fields(sess)
                if fields:
                    return fields
        return {}

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
            # S128 (FL-009): …and the OTHER half of that same life — a session
            # whose OPENING turn is still running, which is precisely the window
            # RESUME is withheld for and the window a reloaded tab used to read
            # as "not scanning". See `_align_busy_fields`.
            busy_by_mission = {}
            # S169 (FL-017): …and the LAST window of that same life — the
            # closing turn's estimate + file.sh dispatch, which runs after the
            # session is `done` and is therefore invisible to both maps above.
            fin_by_mission = {}
            for sid, sess in self._align.items():
                if not sess.mission_id:
                    continue
                fin = self._align_finalizing_fields(sess)
                if fin:
                    fin_by_mission[sess.mission_id] = fin
                elif not sess.done and sess.last_question:
                    by_mission[sess.mission_id] = sid
                else:
                    fields = self._align_busy_fields(sess)
                    if fields:
                        busy_by_mission[sess.mission_id] = fields
        if not by_mission and not busy_by_mission and not fin_by_mission:
            return board  # no live sessions → byte-identical board.
        for col in cols.values():
            if not isinstance(col, list):
                continue
            for card in col:
                if not isinstance(card, dict):
                    continue
                # PRECEDENCE MATCHES THE CARD'S OWN (board.js
                # `startAlignmentControl`): finalizing outranks scanning
                # outranks resumable. They are already mutually exclusive by
                # construction above; the order here says so out loud rather
                # than relying on it.
                if card.get("id") in fin_by_mission:
                    card["alignFinalizing"] = fin_by_mission[card["id"]]
                elif card.get("id") in by_mission:
                    card["alignResume"] = {"sid": by_mission[card["id"]]}
                elif card.get("id") in busy_by_mission:
                    card["alignBusy"] = busy_by_mission[card["id"]]
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
            # S169 (FL-017) — the DETAIL modal mirrors the card, finalize
            # first, for `align_overlay`'s precedence reason: a mission that is
            # completing is not resumable, and offering RESUME ALIGN over a
            # running file.sh is the re-fire this whole entry is about.
            fin = self._align_finalizing_for_mission(mission.get("id"))
            if fin:
                mission["alignFinalizing"] = fin
                return mission
            sid = self.align_session_sid(mission.get("id"))
            if sid:
                mission["alignResume"] = {"sid": sid}
            else:
                # S128 (FL-009): the DETAIL modal mirrors the card here too, or a
                # reload with the modal open re-arms START ALIGNMENT under a
                # running turn — the same defect one click deeper (the original
                # `align_overlay_mission` lesson, applied to the new fact).
                fields = self._align_busy_for_mission(mission.get("id"))
                if fields:
                    mission["alignBusy"] = fields
        return mission

    def _align_busy_for_mission(self, mission_id):
        """The in-flight `alignBusy` fact for a mission, or `{}` (S128/FL-009).

        The `align_session_sid` twin, and it MUST agree with `align_overlay`'s
        loop — one rule (`_align_busy_fields`) read from two places, never two
        rules, which is how a card and its detail modal start disagreeing.
        """
        if not mission_id:
            return {}
        with self._align_lock:
            for sess in self._align.values():
                if sess.mission_id != mission_id:
                    continue
                fields = self._align_busy_fields(sess)
                if fields:
                    return fields
        return {}

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
            out = ("The captain's answer: %s\n\n"
                   "Produce the next turn now, as a single JSON object "
                   "(the same output contract as before)." % answer)
            if getattr(sess, "vision", False):
                out += _ALIGN_VISION_REMINDER
            return out
        skill = _load_skill(_FILE_SKILL)
        parts = [_ALIGN_ENVELOPE, skill]
        # S184 fix round 2 (D2 + D9) — AFTER the skill, so it is the last word
        # the model reads: it both cancels STEP 0 (unsatisfiable in this very
        # conversation) and opens the third status the recommendation screen is
        # reached through. Vision sessions only.
        if getattr(sess, "vision", False):
            parts.append(_ALIGN_VISION_CONTRACT)
        parts += ["\n=== the captain's idea ===\n", sess.idea,
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
                # S128 / FL-010 — the heading names WHAT ACTUALLY RIDES. An
                # HTML mockup is not an image, and telling the grill it is one
                # is the same lie the four `skills/` copies were just cured of.
                prompt = prompt + (
                    "\n\n=== %s (the captain attached these; open them with "
                    "your Read tool as relevant) ===\n" % _attach_heading(
                        image_paths)
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
        # S183 — THE HOLODECK IS LOCKED UNTIL A FOUNDATION EXISTS (captain
        # ruling, 2026-09-05). A mockup whose only road out is ▦ FILE MISSION is
        # a dead end on a repo that cannot take a mission, and a `grounding` pass
        # HIRES A WORKER to read a project that does not exist yet. The lock is
        # lifted the moment an initialization mission lands (S185, at approve).
        self._require_foundation("open the holodeck")
        if images:
            # STARTING a program from an image is not built: `start` opens the
            # room and (on `grounding`) reads the captain's project — there is
            # no turn here to attach anything to. It is refused rather than
            # silently dropped.
            #
            # S169 FIX ROUND 1 — BUT THE REFUSAL USED TO DENY THE FEATURE. It
            # said "the holodeck cannot take pasted images yet", which this
            # session's own FL-014 work made FALSE: the composer takes a pasted
            # screenshot and it reaches the engine. The captain reads one
            # product, and two surfaces four inches apart were contradicting
            # each other about it. The refusal is still a refusal; it now names
            # WHERE the road he wants actually is.
            raise ActionError(
                400, "a holodeck program cannot be STARTED from an image — "
                "open it on one of the other roads, then paste the screenshot "
                "straight into the chat on your first turn. The composer takes "
                "it and the engine sees it.")
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
        bin_ = self._resolve_holodeck_engine(engine)
        sidecar = self._ensure_sidecar(target)
        program_dir = os.path.join(sidecar, _program_room(sidecar, program))
        # ONE ROOM, ONE PROGRAM (fix round 1). Two starts with the same name
        # produced two sessions sharing one `programDir` — both writing the same
        # `mockup.html`, and two cards in the list a captain cannot tell apart.
        # Refused in plain English, because the honest answer is that the
        # program he wants is already open: silently giving the second one a
        # `-2` room would leave him designing in a room he never asked for.
        # Round 2 widened this from the ROOM to the NAME AS READ: a name that
        # normalizes the same is the same program to a captain even when it
        # slugs differently (see `_norm_name`).
        with self._holodeck_lock:
            clash = None
            for other in self._holodeck.values():
                same_room = (os.path.abspath(other.program_dir)
                             == os.path.abspath(program_dir))
                if same_room or _norm_name(other.program) == _norm_name(program):
                    clash = other
                    break
        if clash is not None:
            raise ActionError(
                409, "a program called %r is already open on this deck and it "
                "is using that room (%s). Switch to it in the program list, or "
                "start this one under a different name."
                % (clash.program, os.path.basename(clash.program_dir)))
        # THE ROOM MAY ALREADY HOLD WORK, and silence about that is the defect
        # (round 2). End a program and start one with the same name and it
        # ADOPTS the old room: `turnCount: 0` beside a `previewFile` showing the
        # previous program's mockup, before a word is typed. Refusing is wrong —
        # with in-memory programs, ending one would burn its name forever — so
        # it is DISCLOSED, and continuing in it becomes a choice.
        reuse = self._room_already_holds_work(program_dir)
        try:
            os.makedirs(program_dir, exist_ok=True)
        except OSError as exc:
            raise ActionError(502, "could not create the program's room in the "
                                   "holodeck sidecar: %s" % exc)
        # THE NAME HE TYPED IS RECORDED NOW, NOT ON THE FIRST TURN (fix round
        # 2). Same place as the engine check, and for the same reason: a room
        # LCARS cannot write the program's own record into cannot hold a mockup
        # either, so it is refused here rather than answered 200 and discovered
        # later with the name already gone.
        # ROUND 5 — AND THE ENGINE IT IS BEING BUILT ON, in the same line of the
        # same file. `bin_` is what a turn will actually spawn, so what is
        # recorded and what runs are one value, resolved once.
        #
        # THE SAME RULE HERE AS ON REOPEN, deliberately. A start ADOPTS a room
        # that already holds work (disclosed above), and that room's record
        # already names an engine — `_ensure_transcript` never rewrites it. So
        # without this, starting into a reused copilot room on a claude default
        # ran claude under a record saying copilot, and the next restart moved
        # it back: the same silent switch, one room over.
        bin_, recorded = self._program_engine(program_dir, engine)
        if self._ensure_transcript(program_dir, program, bin_):
            raise ActionError(
                502, "the program's room was created but LCARS could not write "
                "its record (transcript.md) into it, so nothing about this "
                "program — starting with the name you just typed — would be "
                "saved. Check %s is writable, then start it again."
                % program_dir)
        # A FRESH RECORD NOW NAMES EXACTLY THIS ENGINE, so ask the file rather
        # than assume: `engineRecorded` means "this program's own record says
        # so", and only the file can answer that.
        if not recorded:
            recorded = (self._recorded_engine(program_dir) == bin_)
        sid = uuid.uuid4().hex[:12]
        sess = _HolodeckSession(program=program, engine=bin_,
                                mode=mode, sidecar_dir=sidecar,
                                program_dir=program_dir, target_repo=target,
                                engine_recorded=recorded)
        with self._holodeck_lock:
            self._holodeck[sid] = sess
        if mode == "grounding":
            # The opening grounding pass IS a turn, and must be counted as one.
            # Round 0 ran it without recording it, so the sidecar got two
            # commits both labelled `turn 1` and the first follow-up filed
            # itself under `## Follow-up (turn 1)`.
            sess.turns.append({"text": None, "reply": None})
            try:
                payload = self._run_turn(sid, sess, self._build_holodeck_prompt(
                    sess, text=None, opening=True))
                if reuse:
                    payload["roomNotice"] = {"kind": "room-reused",
                                             "message": reuse}
                return payload
            finally:
                # THE PASS IS EXACTLY ONE TURN, whatever it returned. Before
                # this the posture never moved, so every later turn in the
                # DEFAULT (recommended) path kept the read-only tools and the
                # captain's project as its cwd — the engine answered "I can't
                # write files, save this yourself" and the turn returned `ok`.
                # A failed pass switches too: the captain still gets a room he
                # can design in, and re-grounding is a new program.
                self._switch_to_design(sess)
        payload = self._holodeck_meta(sid, sess)
        payload.update({"status": "standing-by", "reply": "", "raw": "",
                        "filesChanged": [],
                        "conceptAudit": self._concept_audit(sess, [])})
        if reuse:
            payload["roomNotice"] = {"kind": "room-reused", "message": reuse}
        return payload

    @staticmethod
    def _room_already_holds_work(program_dir):
        """A plain-English disclosure when a program's room is not empty, or "".

        It says WHAT is in there and HOW MUCH, because "this name is taken" is
        not what the captain needs to know — he needs to know that the mockup
        the preview is about to show him is somebody else's, and that his next
        turn builds on it.

        S128 fix round 1 (L-2): it used to say the earlier work came from "an
        earlier program OF THE SAME NAME", and that can be false. The
        word-boundary slug (FL-005 b) discards up to `_SLUG_MAX/2` characters
        of distinguishing text, so two DIFFERENT names can land in one room —
        no realistic captain-shaped pair was found that does, which is why the
        slug is not being touched, but a sentence that states something the
        code cannot know is a sentence that must not be there. It now names
        the ROOM (always true) and, when the room's own record can say who was
        here, the earlier PROGRAM (also always true).
        """
        names = []
        try:
            for root, dirs, files in os.walk(program_dir):
                dirs[:] = [d for d in dirs if d != ".git"]
                for f in sorted(files):
                    if f.startswith("."):
                        continue
                    names.append(os.path.relpath(os.path.join(root, f),
                                                 program_dir))
                    if len(names) > 50:
                        break
                if len(names) > 50:
                    break
        except OSError:
            return ""
        if not names:
            return ""
        shown = ", ".join(sorted(names)[:3])
        more = "" if len(names) <= 3 else " and %d more" % (len(names) - 3)
        # WHO was here, if the room's own record says. `transcript.md` is
        # written the moment a program is named, so it normally does.
        earlier = ""
        try:
            with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                earlier = _parse_transcript(fh.read())[0]
        except OSError:
            earlier = ""
        named = ', "%s"' % earlier if earlier else ""
        return ("This room (%s) already holds work from an earlier program%s: "
                "%d file(s) — %s%s. Nothing has been deleted, and nothing is "
                "lost: the preview you are about to see is that earlier "
                "mockup, and your next turn builds on it. Start under a "
                "different name if you wanted an empty room."
                % (os.path.basename(program_dir.rstrip(os.sep)), named,
                   len(names), shown, more))

    def holodeck_say(self, sid, text, images=None, intent=None):
        """POST /api/holodeck/<sid>/say — one warm chat turn.

        The FIRST say OPENS the warm worker session (`--session-id <uuid>`);
        every later one RESUMES it (`--resume <uuid>`) and feeds JUST what the
        captain typed — the prior context lives in the session, so the daemon
        re-feeds no transcript (the same economics as the Align grill).

        S169 (FL-014) — AND IT TAKES PASTED IMAGES. "Make it look like this"
        over a reference screenshot is the archetypal thing to ask a design
        room for, and this was the one design surface on the board that could
        not take one. The road is the S91/S92 one, already measured on both
        engines: the bytes are staged into the PROGRAM'S OWN ROOM (see
        `_stage_room_images` for why there and not the scratch dir) and
        threaded into THIS turn per engine by `_holodeck_turn`.

        THE ECONOMICS FORCE "THIS TURN". A holodeck turn RESUMES a warm session
        and feeds only what the captain typed — nothing is re-sent — so an
        image that missed its own turn would never reach the model at all.

        S169 (FL-015) — `intent` is the captain's OWN declaration of what shape
        this turn is, made on the composer before he sent it: "ask" or "build".
        It is a DECLARATION, never a reading of `text` — nothing here inspects
        what he typed. Absent/unknown values fall back to "build", which is the
        prompt branch that already tells the worker answer-then-stop is the
        default, so a captain who never touches the control loses nothing.
        """
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        text = (text or "").strip()
        if not text:
            raise ActionError(400, "missing required field: text")
        # S127 (D11) — A SENT PROGRAM IS READ-ONLY, and this is where that is
        # enforced. Checked BEFORE the turn is claimed so a locked program never
        # takes a claim it will not release.
        self._refuse_if_sent(sess)
        # S126 (#5) — CLAIM THE TURN BEFORE TOUCHING THE SESSION. The claim must
        # come before `sess.turns` is mutated: a refused racing `/say` that had
        # already appended its line would leave a phantom unanswered turn in the
        # transcript pane for a turn that never ran.
        self._claim_turn(sess)
        try:
            # INSIDE the claim, so a room that cannot take the image releases
            # it like every other failure here; and BEFORE the turn's audit
            # snapshot, so the captain's own paste is never reported back to
            # him as a file the WORKER wrote.
            image_paths = self._stage_room_images(sess, images)
            opening = not sess.started
            intent = _turn_intent(intent)
            prompt = self._build_holodeck_prompt(sess, text=text,
                                                 opening=opening,
                                                 intent=intent)
        except BaseException:
            self._release_turn(sess)
            raise
        # A RETRY IS THE SAME LINE, SAID ONCE (round 2). The captain types a
        # line, the turn dies, he presses RETRY TURN — and the transcript showed
        # him saying it twice, because both sides appended a turn. A last turn
        # that FAILED and carries exactly this text IS this turn; it is reused,
        # not repeated.
        #
        # Keyed off the turn's OUTCOME, not off an empty reply: a live drive
        # found a worker that died with `boom` on stderr, which the daemon
        # merges into stdout — so the failed turn had a perfectly non-empty
        # `reply` and the duplicate came straight back.
        last = sess.turns[-1] if sess.turns else None
        # S169 FIX ROUND 1 — THE TURN REMEMBERS WHAT HE ATTACHED.
        #
        # THE DEFECT, measured on the 2026-08-06 drive: he pasted a sketch, said
        # "This sketch is the look I want", and the turn worked — but after a
        # reload the reopened chat showed no chip, and `transcript.md`, the
        # program's PERMANENT RECORD and the thing a later session is handed,
        # never mentioned an image at all. A future session reads "this sketch
        # is the look I want" with no sketch. That is the same information-loss
        # class as the rest of this round, inside this session's own new
        # feature.
        #
        # The names are read off the STAGED PATHS, not off what the browser
        # said: those are the bytes that reached the engine and the files that
        # are in the room's `attachments/` beside the record naming them.
        names = [os.path.basename(p) for p in (image_paths or [])]
        if last and last.get("text") == text and last.get("failed"):
            last["reply"] = None
            last.pop("failed", None)
            # a RETRY is the same turn, so it is the same declaration — but he
            # may have flipped the control before retrying, and the newest
            # declaration is the one he means.
            last["intent"] = intent
            # …and the newest ATTACHMENT, for the same reason. A retry that
            # dropped the poisoned image (see `_poisoned_note`) must not leave
            # the record claiming that image was sent.
            if names:
                last["attachments"] = names
            else:
                last.pop("attachments", None)
        else:
            turn = {"text": text, "reply": None, "intent": intent}
            if names:
                turn["attachments"] = names
            sess.turns.append(turn)
        return self._run_turn(sid, sess, prompt, claimed=True,
                              image_paths=image_paths, intent=intent)

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

    # ══ S127 — THE HAND-OFF: SEND TO ALIGN ═════════════════════════════════
    # The captain's bar for this round, in his own words: "He never types a file
    # path, never juggles --attach, never copies a file, and never sees the
    # plumbing." Everything below is written to that bar, and the security
    # property it implies is the load-bearing one:
    #
    #   THE BROWSER NEVER SENDS A FILESYSTEM PATH. It sends the program's
    #   SESSION ID — a key into the daemon's own in-memory table — and the
    #   daemon re-resolves that program's room and expands it to the `--attach`
    #   arguments itself, through the SAME jail the preview route uses. A path
    #   in a request body is a path the page (or anything that can reach the
    #   daemon) gets to choose.

    def _sent_record(self, program_dir):
        """This program's hand-off record, read off disk, or None."""
        try:
            with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                return _parse_sent(fh.read())
        except (OSError, ValueError):
            return None

    def _refuse_if_sent(self, sess):
        """D11's lock, in the captain's language.

        Why a lock and not a mark: the mission received a SNAPSHOT of these
        exact files. If the mockup keeps moving afterwards, the design on screen
        and the brief the workers are building to disagree silently, and the
        disagreement surfaces at Verify as "this doesn't match" with no way to
        tell which side moved.
        """
        rec = self._sent_record(sess.program_dir)
        if not rec:
            return
        mission = rec.get("missionId") or ""
        named = ("mission %s" % mission) if mission else "a mission"
        raise ActionError(
            409, "%s was sent to Align as %s, so this program is locked. It is "
            "the exact design that mission was briefed on, and changing it now "
            "would leave the workers building to something you can no longer "
            "see. ⧉ DUPLICATE on this program's card is the way on: it opens a "
            "NEW program carrying this one's mockup, concept doc and whole "
            "conversation, editable from the first turn — and this one stays "
            "exactly as it was handed over."
            % (sess.program or "This program", named))

    def _handoff_files(self, program_dir):
        """The ABS paths of `mockup.html` + `concept.md` in a program's room.

        Resolved through `_room_file_path` — the preview route's jail — so a
        symlink inside the room pointing out of the sidecar is refused here for
        exactly the reason it is refused there. A missing file is a PLAIN
        refusal naming the file and what to do about it, never a 500.
        """
        found, missing = [], []
        for name in _HANDOFF_FILES:
            target, _parts = self._room_file_path(program_dir, name)
            if os.path.isfile(target):
                found.append(target)
            else:
                missing.append(name)
        if missing:
            what = " and ".join(missing)
            raise ActionError(
                409, "this program has no %s yet, so there is nothing to hand "
                "over. Ask for it in the chat — the holodeck writes mockup.html "
                "(the screen) and concept.md (what it must do) into the "
                "program's room as you design — then send it to Align."
                % what)
        return found

    def _handoff_scope(self, scope):
        scope = (scope or "").strip().lower() or _HANDOFF_SCOPES[0]
        if scope not in _HANDOFF_SCOPES:
            raise ActionError(
                400, "unknown build scope %r — it is either \"look+behaviour\" "
                "(build it for real) or \"look-only\" (a reskin, no functional "
                "change)" % scope)
        return scope

    # ── THE DERIVATION, as a bounded pass `promote` can afford to leave ─────
    #
    # Everything below is fail-safe by construction: every method returns a
    # dict, none of them raises, and the ONE thing `promote` does with the
    # result is draft a section of a brief the captain can rewrite or delete.
    # There is no branch anywhere in this file where a derivation outcome
    # refuses, blocks or delays a filing.

    @staticmethod
    def _handoff_derive_enabled():
        """Whether the derivation runs at all.

        `$LCARS_HOLODECK_HANDOFF_CHECK=0` turns it off — the env var keeps
        S169's name deliberately, because it is the switch a captain and every
        suite in this repo already sets, and renaming it would silently start
        spawning workers inside test runs that thought they had opted out.
        """
        raw = os.environ.get("LCARS_HOLODECK_HANDOFF_CHECK")
        return str(raw).strip().lower() not in ("0", "false", "no", "off")

    @staticmethod
    def _handoff_derive_timeout():
        """How long the one pass may run. Injectable.

        420s, AND THAT NUMBER IS MEASURED. It was 180 — a round number chosen
        before anything had been driven — and three live copilot passes over a
        real capstone room came in at 154s, 193s and 220s. A 180s bound would
        have KILLED the third and reported "it did not answer" about a pass
        that was about to. S170 makes the pass BIGGER (it now reads a whole
        repository, not one room) and the bound is left where the measurement
        put it rather than guessed upward: a pass that runs out is reported as
        exactly that, and the captain still gets his brief.

        NOTHING IS WAITING ON IT. The dialog opens instantly, the band polls,
        the result is cached against the files it read AND persisted into the
        program's room — so a slow pass costs a captain who walked away nothing
        at all.
        """
        try:
            return max(1.0, float(os.environ.get(
                "LCARS_HOLODECK_HANDOFF_CHECK_TIMEOUT") or 420))
        except ValueError:
            return 420.0

    # ── DURABILITY: the answer outlives the daemon that produced it ─────────
    #
    # THE CAPTAIN'S QUESTION, asked while this was being built: *"If the daemon
    # closes by accident while I walk away are we still good?"*
    #
    # S169's cache was in-memory and disposable, which was defensible when the
    # result was a hint about a list he already had. It is not defensible now:
    # the result IS a section of his brief, it costs 154–220s, and a walk-away
    # is precisely when nobody is watching the daemon. So a COMPLETED pass is
    # written into the program's own room — a durable git repo that S126 already
    # commits per turn, and the right home for a fact about this program. Not
    # `.git/lcars/` (that is mission state, and no mission exists yet).
    #
    # AND NOTHING EVER PERSISTS "RUNNING". A fresh daemon owns no in-flight
    # pass; a persisted "running" with no process behind it is a surface
    # asserting a state it cannot know, which is the FL-009/FL-017 family this
    # round has now cured twice. So the on-disk record has exactly two shapes —
    # a finished answer, or absent — and absent means the dialog starts a pass,
    # which is a real process he can watch. There is no timer here and no
    # staleness constant: FL-009's ruling is that a bigger constant is the same
    # guess with a longer fuse.
    _HANDOFF_DERIVE_FILE = "handoff-changes.json"

    @classmethod
    def _handoff_derive_fingerprint(cls, program_dir, target_repo):
        """What this pass would read, as one string. NO SESSION ID IN IT.

        S169's key opened with the session id, which was harmless while the
        cache died with the process. It would be fatal now: a restarted daemon
        mints a NEW session id for the same room, so a session-keyed record
        could never be found again and the durability would be theatre that
        passes its own unit test.

        `stat` of the three files the pass reads, plus the repo it stands in,
        plus a digest of the PROMPT — a reworded prompt asks a different
        question and must not reuse an old answer. Never file CONTENTS: this
        runs on every dialog open and must not read 46KB of mockup to decide it
        has nothing to do.

        WHAT IT DELIBERATELY DOES NOT COVER, said out loud: the captain's repo
        changing under a finished answer. Hashing a whole project on every
        dialog open is the 66-second walk `_audit_snapshot` already refused, and
        the case is narrow — he redraws, the mockup's mtime moves, and the pass
        re-runs. A repo edit with no mockup edit leaves a derivation describing
        the app as it was at promote time, which the band's own wording ("read
        off your project", with the time it ran) does not overclaim.
        """
        parts = [os.path.abspath(target_repo or "")]
        for name in _HANDOFF_FILES + (_BASIS,):
            try:
                st = os.stat(os.path.join(program_dir, name))
                parts.append("%s:%d:%d" % (name, st.st_size,
                                           int(st.st_mtime * 1000)))
            except OSError:
                parts.append("%s:-" % name)
        parts.append(hashlib.sha1(
            _HANDOFF_DERIVE_PROMPT.encode("utf-8")).hexdigest()[:12])
        return hashlib.sha1("\n".join(parts).encode("utf-8")).hexdigest()

    @classmethod
    def _handoff_derive_read(cls, program_dir, fingerprint):
        """The persisted answer for `fingerprint`, or None. NEVER RAISES.

        A missing, unreadable, corrupt, half-written or differently-fingered
        record all behave IDENTICALLY to no record — he gets a brief, the pass
        is offered again, and nothing is blocked. That is the fail-safe clause
        applied to durability: a bad file on disk must never be worse than no
        file on disk.
        """
        try:
            with open(os.path.join(program_dir,
                                   cls._HANDOFF_DERIVE_FILE)) as fh:
                rec = json.load(fh)
        except (OSError, ValueError, TypeError):
            return None
        if not isinstance(rec, dict):
            return None
        if rec.get("fingerprint") != fingerprint:
            return None
        changes = rec.get("changes")
        if not isinstance(changes, list):
            return None
        if not all(isinstance(c, str) for c in changes):
            return None
        # S172 — THE QUESTIONS ARE NOT LOAD-BEARING FOR THE RECORD. A record
        # written before this key existed, or one whose `asks` is the wrong
        # shape, is still a good record of a pass that ran: it degrades to no
        # questions rather than to no answer, because throwing away a 154-220s
        # change list over a missing second list would be the fail-safe clause
        # inverted. (The fingerprint digests the PROMPT, so an old record is
        # normally re-derived anyway — this is the belt to that braces.)
        asks = rec.get("asks")
        if not isinstance(asks, list) or not all(isinstance(a, str)
                                                 for a in asks):
            asks = []
        return {"state": "done", "ok": bool(rec.get("ok")),
                "changes": [c for c in changes][:_HANDOFF_DERIVE_MAX_CHANGES],
                "asks": asks[:_HANDOFF_DERIVE_MAX_ASKS],
                "why": str(rec.get("why") or ""),
                "at": rec.get("at") or 0,
                "engine": str(rec.get("engine") or ""),
                "fromDisk": True}

    @classmethod
    def _handoff_derive_write(cls, program_dir, fingerprint, result):
        """Persist a FINISHED result into the room. Best-effort, never raises.

        Written to a temp name and renamed, so a daemon killed mid-write leaves
        either the old record or the new one — never half of one, which is the
        exact input `_handoff_derive_read` is built to survive anyway.
        """
        path = os.path.join(program_dir, cls._HANDOFF_DERIVE_FILE)
        rec = {"fingerprint": fingerprint, "at": time.time(),
               "ok": bool(result.get("ok")),
               "changes": list(result.get("changes") or []),
               "asks": list(result.get("asks") or []),
               "why": str(result.get("why") or ""),
               "engine": str(result.get("engine") or "")}
        tmp = path + ".tmp"
        try:
            with open(tmp, "w") as fh:
                json.dump(rec, fh)
            os.replace(tmp, path)
            return True
        except (OSError, TypeError, ValueError):
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return False

    def _handoff_derive_state(self, sess, start=False, force=False):
        """The derivation for this program. `start=True` may spawn the pass.

        Returns the payload's `derive` block and NEVER raises. FIVE shapes, and
        the surface has to be able to tell them apart:

          {"state": "off"}                      — not running, by configuration
          {"state": "none"}                     — no answer for this draft, and
                                                  nothing is running: the deck
                                                  offers to generate one
          {"state": "running", "startedAt": …}  — a pass is in flight; ask again
          {"state": "done", "ok": true,  "changes": […]}
          {"state": "done", "ok": false, "why": …}

        `ok: false` means THE PASS DID NOT ANSWER — no engine, a timeout, an
        unusable reply, no project to compare against. It is NOT "the mockup
        changes nothing", and `why` says which.

        ── S171: READING IS NOT STARTING, AND THAT IS THE WHOLE GATE ────────
        #
        The default is a PEEK. S170 spawned the pass from `promote`, i.e. the
        moment the hand-off dialog opened — so a captain who opened it to look,
        closed it and drew one more turn had paid for a pass he never read, and
        the wait was hidden inside a dialog.

        The captain's design replaces that: *"making that step a gated wait
        that retriggers behind a wait guard if you keep chatting with the
        composer."* ▶ SEND TO ALIGN on the deck IS the button, so exactly one
        caller passes `start=True` — `holodeck_derive`, which is what that
        button posts to. Every other reader (the deck's own program payload,
        `promote`, the scope-change refetch) peeks, and a peek can never spend.

        `force=True` additionally CLEARS a finished record before starting.
        It exists for one state and it is not a convenience: a pass that FAILS
        is persisted like any other answer, and without a way to clear it a
        captain whose engine was down for one minute would be looking at "LCARS
        could not read your project" until he redrew the mockup. It is reached
        only by his explicit "try again", never automatically — a retry the
        product decides for itself is a pass he did not ask to pay for.
        """
        try:
            fp = self._handoff_derive_fingerprint(sess.program_dir,
                                                  sess.target_repo)
        except Exception:                          # noqa: BLE001 — fail safe
            return {"state": "done", "ok": False, "changes": [],
                    "why": "LCARS could not work out what to compare"}
        if force and start:
            # BOTH HOMES, or the cleared one is read straight back from the
            # other. Nothing is deleted unless a pass is about to replace it.
            with self._handoff_derive_lock:
                entry = self._handoff_derives.get(fp)
                if not entry or entry.get("state") != "running":
                    self._handoff_derives.pop(fp, None)
            self._handoff_derive_forget(sess.program_dir, fp)
        with self._handoff_derive_lock:
            entry = self._handoff_derives.get(fp)
            if entry is not None:
                return self._derive_now(entry)
        # NOTHING IN MEMORY. Before spending 154–220s of the captain's day,
        # ask the ROOM — this is where a daemon that died gives him his wait
        # back. A record that does not match the fingerprint is ignored, which
        # is the same code path as no record at all.
        disk = self._handoff_derive_read(sess.program_dir, fp)
        if disk is not None:
            with self._handoff_derive_lock:
                self._handoff_derives[fp] = disk
            return dict(disk)
        if not self._handoff_derive_enabled():
            return {"state": "off"}
        if not start:
            # THE PEEK'S HONEST ANSWER. There is no answer for this draft and
            # nothing is running — which is a real, nameable state and not a
            # failure, so it is never dressed as one. It is also the state a
            # composer turn RETURNS a program to, for free: the fingerprint
            # covers `mockup.html`, so a redraw simply stops matching the
            # record and this branch is reached again. Invalidation is a fact
            # about the files, never a flag anything has to remember to clear.
            return {"state": "none"}
        started = time.time()
        with self._handoff_derive_lock:
            entry = self._handoff_derives.get(fp)
            if entry is not None:
                return self._derive_now(entry)
            entry = {"state": "running", "startedAt": started}
            self._handoff_derives[fp] = entry
            # A HARD BOUND ON THE CACHE, because the key includes an mtime and
            # a captain who draws all afternoon mints a new one every turn.
            if len(self._handoff_derives) > 64:
                for stale in list(self._handoff_derives)[:32]:
                    if stale != fp:
                        self._handoff_derives.pop(stale, None)
        thread = threading.Thread(
            target=self._handoff_derive_run, args=(fp, sess), daemon=True)
        thread.start()
        return self._derive_now(entry)

    @classmethod
    def _handoff_derive_forget(cls, program_dir, fingerprint):
        """Drop the persisted answer for `fingerprint`. Never raises.

        Only ever removes a record that IS this draft's — a differently
        fingered file belongs to a draft this one knows nothing about and is
        left exactly where it is.
        """
        path = os.path.join(program_dir, cls._HANDOFF_DERIVE_FILE)
        try:
            with open(path) as fh:
                rec = json.load(fh)
        except (OSError, ValueError, TypeError):
            return False
        if not isinstance(rec, dict) or rec.get("fingerprint") != fingerprint:
            return False
        try:
            os.unlink(path)
            return True
        except OSError:
            return False

    @staticmethod
    def _derive_now(entry):
        """A copy of the state, with the DAEMON'S OWN reading of the clock on
        an in-flight one.

        The surface renders "started 45s ago" from `now - startedAt`, both of
        them this process's numbers — never from a timestamp the browser
        subtracts against its own clock, which is the class of bug `busyFor`
        was built to avoid (S128/FL-002). Without BOTH, the band says nothing
        about elapsed time rather than guessing.
        """
        out = dict(entry)
        if out.get("state") == "running":
            out["now"] = time.time()
        return out

    def _handoff_derive_run(self, fp, sess):
        """The pass itself, on its own thread. Catches EVERYTHING.

        This runs detached from any request. An exception escaping here would
        leave the cache entry pinned at "running" forever and the dialog would
        poll a spinner that can never resolve — so the bare `except` is the
        mechanism, not laziness, and the failure it swallows is reported.
        """
        try:
            result = self._handoff_derive_spawn(sess)
        except Exception as exc:                   # noqa: BLE001 — see above
            result = {"state": "done", "ok": False, "changes": [],
                      "why": "the pass did not complete (%s: %s)"
                             % (type(exc).__name__, exc)}
        # PERSIST FIRST, then publish. A daemon killed between the two loses
        # nothing: the room already holds the answer and the next `promote`
        # reads it back.
        self._handoff_derive_write(sess.program_dir, fp, result)
        with self._handoff_derive_lock:
            self._handoff_derives[fp] = result

    def _handoff_derive_spawn(self, sess):
        """One cold, read-only worker STANDING IN THE CAPTAIN'S PROJECT.

        COLD, and that is the point. It gets a FRESH session id and never
        `--resume`s the design chat: a warm worker would answer out of its
        memory of what it meant to draw, and what it meant is exactly the thing
        that is not being asked about.

        The cwd is the TARGET REPO — the app as it actually is, right now, not
        `basis.md`'s summary of how it was when the program started. The
        program's room rides as the one `--add-dir` grant so the drawing is
        readable; the tool surface holds no write tool, so neither directory
        can be written to.
        """
        bin_ = sess.engine or self.worker_bin
        if not bin_:
            return {"state": "done", "ok": False, "changes": [],
                    "why": "no worker engine is configured, so LCARS could not "
                           "read your project against the mockup"}
        repo = sess.target_repo
        if not repo or not os.path.isdir(repo):
            return {"state": "done", "ok": False, "changes": [],
                    "why": "LCARS could not open the project this program was "
                           "started against (%s), so there was nothing to "
                           "compare the mockup with" % (repo or "unknown")}
        try:
            paths = self._handoff_files(sess.program_dir)
        except ActionError as exc:
            return {"state": "done", "ok": False, "changes": [],
                    "why": exc.message}
        basis = os.path.join(sess.program_dir, _BASIS)
        prompt = _handoff_derive_prompt(
            paths[0], paths[1],
            basis if os.path.isfile(basis)
            else "(there is no basis file — judge on the mockup and the code)")
        cmd = ([bin_, "-p", prompt]
               + self._holodeck_args(bin_, "derive", str(uuid.uuid4()), True,
                                     sess.program_dir)
               + ["--model", _holodeck_model(bin_)])
        # The S72 guard, on this argv too. A pass with a shell is a pass that
        # can write, and `_assert_no_bash` is where that is refused.
        _assert_no_bash(cmd)
        limit = self._handoff_derive_timeout()
        try:
            proc = subprocess.Popen(cmd, cwd=repo,
                                    stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT,
                                    start_new_session=True)
        except OSError as exc:
            return {"state": "done", "ok": False, "changes": [],
                    "why": "the pass failed to start: %s" % exc}
        try:
            out, _err = proc.communicate(timeout=limit)
        except subprocess.TimeoutExpired:
            _kill_process_group(proc)
            try:
                proc.communicate(timeout=10)
            except (subprocess.TimeoutExpired, OSError, ValueError):
                pass
            return {"state": "done", "ok": False, "changes": [],
                    "why": "it did not answer within %ds and was stopped"
                           % int(limit)}
        reply = _clean_reply((out or b"").decode("utf-8", "replace"))
        changes = _handoff_derive_parse(reply)
        if changes is None:
            return {"state": "done", "ok": False, "changes": [],
                    "why": "the pass never wrote its change list, so LCARS "
                           "could not read one out of it"}
        return {"state": "done", "ok": True, "changes": changes,
                # S172 — the same reply's second block: what it found and
                # declared it was NOT reporting, because the captain's own
                # out-of-scope ruling made it ambiguous. Absent on a pass that
                # declared nothing, which is the ordinary answer.
                "asks": _handoff_derive_asks(reply),
                "engine": os.path.basename(bin_), "why": ""}

    def _handoff_changes(self, state):
        """The change lines a `derive` block yields for the brief.

        A pass that is running, off, or did not answer yields `[]` — the brief
        is drafted WITHOUT that section, which is the degraded shape
        `_handoff_brief` is built for. Read this beside the `ast` test: this is
        the only function that turns a derivation into brief text, and it is
        called from `promote` alone.
        """
        if (state or {}).get("state") != "done" or not state.get("ok"):
            return []
        return list(state.get("changes") or [])

    def _handoff_asks(self, state):
        """The questions a `derive` block yields for bucket 2 (S172).

        The SAME gate as `_handoff_changes` and for the same reason: a pass
        that is running, off or did not answer declared nothing, so the brief
        carries bucket 2 exactly as the concept doc wrote it. There is one
        reply and one road off it; this is the second field of it, not a
        second mechanism.
        """
        if (state or {}).get("state") != "done" or not state.get("ok"):
            return []
        return list(state.get("asks") or [])

    def holodeck_promote(self, sid, scope=None):
        """POST /api/holodeck/<sid>/promote — SEND TO ALIGN.

        A READ that returns the pre-seeded hand-off: the captain's own opening
        description of the program, verbatim (S171 — it used to be a numbered,
        turn-attributed list read out of `## WHAT IT MUST DO`, which is a
        timeline), PLUS what the mockup CHANGES ABOUT THE APP AS IT ACTUALLY IS
        (S170 — derived by a read-only pass standing in the captain's own repo,
        not transcribed from `## Decisions`), what the mockup implies that
        nobody has settled, and what was ruled out of scope; the requirements as
        a set, the `## Open questions` that must reach the captain before he
        files, the build-scope choice (D15), the list of what rides along BY
        NAME, and the guidance block verbatim. It writes no mission state and
        locks nothing — the lock is a fact about a mission that exists, so it
        lands when the mission is actually filed (`_holodeck_handed_over`).

        S171 — AND IT NO LONGER SPENDS A PENNY. It used to be "the one endpoint
        that may spend": opening the hand-off dialog started the bounded pass.
        The captain moved that button one surface out — ▶ SEND TO ALIGN on the
        deck is the gate, and `holodeck_derive` is what it posts to — so this
        endpoint PEEKS at the derivation and never starts one. Opening the
        dialog, changing the build scope and re-reading the draft are all free.

        Filing is never held up: a brief with no derived section is a brief he
        can send, and the deck offers exactly that road in every failed state.

        The payload deliberately carries NO PATH. The deck shows names; the
        daemon holds the paths.
        """
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        self._refuse_if_sent(sess)
        scope = self._handoff_scope(scope)
        paths = self._handoff_files(sess.program_dir)
        try:
            with open(paths[1]) as fh:
                concept = fh.read()
        except OSError as exc:
            raise ActionError(
                502, "LCARS could not read this program's concept.md, so it "
                "cannot draft the brief: %s" % exc)
        derive = self._handoff_derive_state(sess, start=False)
        changes = self._handoff_changes(derive)
        asks = self._handoff_asks(derive)
        brief = _handoff_brief(concept, sess.program, changes, asks)
        captured, changed, implied, out_of_scope = _handoff_parts(
            concept, changes, asks)
        reqs = [{"id": "r%d" % (i + 1), "text": t}
                for i, t in enumerate(captured)]
        return {
            "sessionId": sid, "program": sess.program,
            "room": os.path.basename(sess.program_dir),
            "engine": os.path.basename(sess.engine or self.worker_bin or ""),
            "brief": brief,
            # S128 — the captured requirements and the OPEN QUESTIONS, as sets.
            # The deck shows each requirement against what he has written and
            # puts the questions in front of him as the last thing before he
            # files: he is right there, they are short, and answering five
            # costs less than one wrong build.
            "requirements": reqs,
            "questions": _handoff_questions(concept),
            # The three other halves the draft carries, as sets, exactly as it
            # carries them (same helper, so the hint under the box cannot count
            # something the box does not contain). The deck names what is in
            # the draft; it never composes the draft.
            #
            # S170 — `changes` REPLACES S169's `decisions` key and is a
            # different thing, which is why the key was renamed rather than
            # refilled: `decisions` was `## Decisions`, an account of the
            # conversation, and this is the difference between the mockup and
            # the captain's repository. A client still reading `decisions`
            # should get nothing rather than something that reads the same and
            # is not.
            "changes": changed,
            "implied": implied,
            "outOfScope": out_of_scope,
            # THE CHANGE SECTION AS TEXT, exactly as `brief` carries it.
            #
            # It exists for ONE case and it is worth spelling out: the pass
            # takes minutes, and if the captain has typed into his brief while
            # it ran, the deck must NOT replace what he wrote (FL-013 is that
            # defect one dialog over). So it APPENDS this block to the end of
            # his own text instead — and it appends the DAEMON'S words, not a
            # section the browser composed, so what he reads and what a
            # Mission is told can never drift.
            "changesBlock": _handoff_section(_HANDOFF_CHANGE_TITLE,
                                             _HANDOFF_CHANGE_NOTE, changed),
            # S172 — AND THE QUESTIONS THE SAME PASS PRODUCED, as their own
            # appendable block. ONLY the pass's own lines are in it: bucket 2's
            # declared items are in his draft from the moment the dialog opens
            # and do not depend on the pass, so appending the whole section
            # would hand him a second copy of what he is already reading.
            "impliedBlock": _handoff_section(
                _HANDOFF_IMPLIED_TITLE, _HANDOFF_IMPLIED_NOTE,
                [i for i in implied if i in set(asks)]),
            # THE DERIVATION'S OWN STATE, so the deck can say what is happening
            # rather than guessing from an empty list. `{"state": "running"}`
            # means ask again in a moment — and means the `brief` above has no
            # change section YET. Anything else is final for this draft.
            "derive": derive,
            "scope": scope,
            "scopeOptions": list(_HANDOFF_SCOPES),
            "guidance": _handoff_guidance(scope),
            "rides": [
                {"name": _HANDOFF_FILES[0],
                 "what": "the look and the flow — one self-contained file"},
                {"name": _HANDOFF_FILES[1],
                 "what": "decisions, declared flows, what it must do"},
            ],
        }

    def holodeck_derive(self, sid, force=False):
        """POST /api/holodeck/<sid>/derive — GENERATE THE CHANGE LIST.

        THE ONE ENDPOINT THAT MAY SPEND, and it is reached by exactly one
        control: ▶ SEND TO ALIGN on the deck, in its "generate" state. That is
        the captain's own design — *"making that step a gated wait that
        retriggers behind a wait guard if you keep chatting with the
        composer."*

        It answers the `derive` block and nothing else. The deck renders that
        block and invents nothing: the button reads `◐ Generating change
        list…` and is disabled because THE DAEMON SAID `running`, not because
        a client set a flag or started a timer. That is FL-009/FL-017's ruling
        applied a third time (`alignBusy` / `_align_busy_fields` is the shape).

        IDEMPOTENT WHILE IT RUNS. A second post — a double click, a second tab,
        a reload — finds the in-flight entry under the same fingerprint and
        joins it. One draft, one pass, however many people are watching.

        `force` is the captain's explicit "try again", and it is offered on
        exactly one state: a pass that DID NOT ANSWER. See
        `_handoff_derive_state`.
        """
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        self._refuse_if_sent(sess)
        # THE SAME READINESS RULE THE BUTTON IS DRAWN FROM, asked of the same
        # function. There is nothing to diff against a room with no mockup in
        # it, and a spawn here would burn minutes to say so.
        self._handoff_files(sess.program_dir)
        return {"sessionId": sid,
                "derive": self._handoff_derive_state(sess, start=True,
                                                     force=bool(force))}

    # ── the hand-off, as the File/Park/Align roads consume it ───────────────
    def _handoff_attach(self, holodeck):
        """`(session, [abs paths])` for a filing that carries a holodeck program.

        `holodeck` is a SESSION ID and is looked up as one. A crafted value —
        a traversal, an absolute path, a room name — is simply not a key in the
        table, so it answers "no such holodeck program" without ever touching
        the filesystem. There is no branch here that turns a string from the
        request into a path.
        """
        sid = (holodeck or "").strip()
        if not sid:
            return None, []
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        self._refuse_if_sent(sess)
        return sess, self._handoff_files(sess.program_dir)

    def _handoff_attach_soft(self, holodeck):
        """`(session, [paths], reason)` — the same resolve, but it never raises.

        The GRILL road only. A grill that reaches `done` has produced a PRD
        that cost real tokens and real minutes of the captain's attention, and
        it exists nowhere else. If the program went away underneath it (he
        ended it from the deck mid-interview, the daemon was restarted) then
        refusing here would throw the PRD away to protect an attachment — the
        wrong trade both ways round.

        So the mission is filed regardless and the caller SAYS what did not
        ride, in the response. Nothing is silent, and nothing expensive is lost.
        """
        if not (holodeck or "").strip():
            return None, [], ""
        try:
            sess, paths = self._handoff_attach(holodeck)
            return sess, paths, ""
        except ActionError as exc:
            return None, [], exc.message

    @staticmethod
    def _handoff_concept_text(paths):
        """The concept doc's text, for the roads that only hold the paths.

        Unreadable is not fatal here: the artifacts still ride as attachments
        and the mission is still filed. The requirement/question blocks simply
        have nothing to say, which is honest — they are not invented from the
        idea text.
        """
        if len(paths or []) < 2:
            return ""
        try:
            with open(paths[1]) as fh:
                return fh.read()
        except OSError:
            return ""

    @staticmethod
    def _handoff_questions_block(concept_text, answers):
        """The `## Open questions` block, as the MISSION reads it.

        S128 (FL-011 b). These are the questions the holodeck asked itself and
        got right; on the S127 capstone all five were correct, none reached the
        captain, and every downstream stage read their silence as a decision he
        had made. An answered one arrives as HIS answer and is a requirement.
        An unanswered one arrives marked and must not be assumed settled — the
        whole point is that silence stops being an answer.

        ── S169 FIX ROUND 2: THE STAMP STOPPED ASSERTING WHAT IT CANNOT KNOW ──

        MEASURED on the 2026-08-07 capstone. Two of this program's questions
        were stamped `⚠ STILL OPEN — he was not asked, or did not answer. Treat
        as undecided.` while being SETTLED IN THEIR OWN TEXT, three words to the
        left of the stamp:

            1. Q: Is emerald/green the right brand accent? Settled T3: keep
               emerald.
               ⚠ STILL OPEN — he was not asked, or did not answer. …
            2. Q: (Theme default/persistence — settled T3, moved to Decisions.)
               ⚠ STILL OPEN — he was not asked, or did not answer. …

        The captain had answered emerald verbatim in an earlier turn. The stamp
        manufactured an Align question he had already answered — a real human
        gate, spent on nothing. It is the symmetric twin of the defect fix round
        1 cured (the daemon counting bullets without reading them), pointing the
        other way, and this one has a price.

        WHAT THE DAEMON ACTUALLY KNOWS is one fact: no answer was typed into
        that box. It does NOT know he was not asked — the promote dialog puts
        every one of these in front of him with its own answer box — and it does
        not know the question is undecided, because the only thing that could
        tell it is the line itself, which it does not read. So the stamp now
        states the fact, names the line above it as the thing to read, and stops
        ordering a human gate for a question that answers itself.

        AND NOT BY A CLASSIFIER. There is no test here for "settled", no
        keyword, no similarity: that is the road S156/S147/S157 lost. The
        structural half of the cure is upstream in `_CONCEPT_CONTRACT`, which
        now requires a settled question to be MOVED OUT of `## Open questions`
        into `## Decisions` rather than annotated where it stands — so the
        bucket means what it says and the daemon can go on counting bullets.
        """
        questions = _handoff_questions(concept_text)
        if not questions:
            return ""
        answers = answers if isinstance(answers, dict) else {}
        out = ["## Open questions from the design session", "",
               "These were raised while the design was being drawn. An answered "
               "one is the captain's own decision and is a requirement. For any "
               "marked NO ANSWER RECORDED, READ THE QUESTION'S OWN LINE FIRST — "
               "it is quoted verbatim from the design doc, and if it records "
               "its own settlement then it IS settled and must not be asked "
               "again. Raise a human gate (`lcars:awaiting-human`) only for one "
               "the line leaves genuinely undecided. Never settle one yourself "
               "by taking whatever the mockup happens to show, and never treat "
               "one as agreed because nobody objected.", ""]
        for i, q in enumerate(questions):
            said = str(answers.get(q["id"], "") or "").strip()
            out.append("%d. Q: %s" % (i + 1, q["text"]))
            if said:
                out.append("   ANSWERED by the captain: %s" % said)
            else:
                # THE FACT, AND ONLY THE FACT. It used to add "he was not asked,
                # or did not answer" — a disjunction the daemon invented, whose
                # first half the promote dialog makes false — and "Treat as
                # undecided", which is a verdict on a line it never read.
                out.append("   ⚠ NO ANSWER RECORDED at filing — he typed "
                           "nothing in the box. Read the line above before "
                           "you spend a gate on it.")
        return "\n".join(out) + "\n"

    @classmethod
    def _handoff_idea(cls, idea, scope, concept_text="", answers=None):
        """The captain's words PLUS everything the hand-off must not lose.

        The deck shows the same guidance block before he sends, from the same
        function, so what he read and what the mission is told cannot drift. It
        is not composed in the browser for that reason and for one more: a
        mission filed by anything else (a script, a later CLI verb) gets it too.

        S128 added two blocks between his brief and the guidance — the open
        questions, and any captured requirement his brief did not contain.
        S171 deleted the second (see the block above `_handoff_missing`'s old
        home); the questions block is derived HERE, from the concept doc on
        disk, so a crafted request cannot put a sentence in front of a worker.
        """
        parts = [idea]
        # S178 CURE 5 — …and, after them, the CHECKLIST over both homes. It sits
        # here rather than inside either bucket's own block for the reason the
        # buckets are split at all: it is about BOTH of them, and neither one
        # owns it. Empty (and so byte-identical to the pre-S178 idea) whenever
        # the design session left nothing unsettled.
        for block in (cls._handoff_questions_block(concept_text, answers),
                      _handoff_carry_forward_block(concept_text)):
            if block:
                parts.append(block.strip())
        parts.append(_handoff_guidance(scope))
        return "\n\n".join(parts)

    def _mission_ids(self):
        try:
            return set(os.listdir(self._missions_dir()))
        except OSError:
            return set()

    def _handoff_record(self, sess, before):
        """Lock the program that was just sent, and say which mission holds it.

        Called ONLY after the filing dispatch returned successfully: a lock is
        the claim that a mission holds this exact design, and if no mission was
        filed the claim is false — and the captain would be shut out of his
        program for nothing.

        The mission id is read by DIFFING the missions directory, because
        file.sh mints it and the daemon's dispatch is fire-and-report, not a
        conversation. Exactly one new mission is the normal case; anything else
        records the hand-off WITHOUT a number rather than guessing one.
        """
        new = sorted(self._mission_ids() - before)
        mid = new[0] if len(new) == 1 else ""
        when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        locked = self._write_sent_record(sess.program_dir, mid, when)
        out = {"sessionId": None, "program": sess.program, "status": "sent",
               "missionId": mid, "locked": locked,
               "room": os.path.basename(sess.program_dir)}
        with self._holodeck_lock:
            for k, s in self._holodeck.items():
                if s is sess:
                    out["sessionId"] = k
                    break
        warnings = []
        if not locked:
            warnings.append(
                "The mission was filed and it has the mockup and the concept "
                "doc. LCARS could not write the hand-off into this program's "
                "record, so the deck will still show it as a draft and it can "
                "still be edited — which would leave it out of step with what "
                "the mission was briefed on.")
        if warnings:
            out["warning"] = "\n\n".join(warnings)
        return out

    @staticmethod
    def _write_sent_record(program_dir, mission_id, when):
        """Put the hand-off line in `transcript.md`'s HEADER. True on success.

        Best-effort, and the caller SAYS SO when it fails: the mission is
        already filed by this point, and raising here would fail a request whose
        real work succeeded. Only the header — the block LCARS itself wrote when
        the program was named — is touched; not one line a model produced is
        rewritten or moved.
        """
        path = os.path.join(program_dir, _TRANSCRIPT)
        line = _sent_header_line(mission_id, when)
        try:
            with open(path) as fh:
                text = fh.read()
        except OSError:
            return False
        text = text.replace("\r\n", "\n")
        parts = re.split(r"(?m)^(## )", text, maxsplit=1)
        head = parts[0]
        rest = "".join(parts[1:])
        if _SENT_LINE.search(head):
            head = _SENT_LINE.sub(lambda _m: line.rstrip("\n"), head, count=1)
            if not head.endswith("\n"):
                head += "\n"
        else:
            head = head.rstrip("\n") + "\n\n" + line
        try:
            with open(path, "w") as fh:
                fh.write(head + rest)
        except OSError:
            return False
        return True

    # ══ S126 — DURABLE PROGRAMS: reopen and delete ═════════════════════════
    def _room_dir(self, sidecar, room):
        """Resolve a room NAME to its directory inside the sidecar, or refuse.

        A room is ONE path segment. Everything else — a separator, `..`, an
        absolute path, a dotfile (`.git` is the sidecar's own bookkeeping, not a
        program) — is refused by inspection, and the resolved path is then
        realpath-checked against the sidecar so a symlinked room cannot point
        `delete` at the captain's project.
        """
        r = str(room or "").strip()
        if not r:
            raise ActionError(400, "missing required field: room")
        if ("\x00" in r or "/" in r or "\\" in r or r.startswith(".")
                or r in (".", "..")):
            raise ActionError(403, "%r is not a program in this holodeck" % r)
        d = os.path.join(sidecar, r)
        real = os.path.realpath(d)
        if os.path.dirname(real) != os.path.realpath(sidecar):
            raise ActionError(403, "%r is not a program in this holodeck" % r)
        if not os.path.isdir(real):
            raise ActionError(
                404, "the holodeck has no program in a room called %r. Open the "
                "program list to see what is in this sidecar." % r)
        # …AND IT IS ONE OF LCARS'S OWN PROGRAMS (fix round 2, defect 7). The
        # sidecar is the captain's archive and he is told so; a folder he put
        # there is not a program and must never be openable — or, far worse,
        # `git rm`-able — from the deck.
        if not self._is_program_room(real):
            raise ActionError(
                403, "%r is a folder in this holodeck's archive, but it is not "
                "a program — it holds no transcript.md. LCARS only opens and "
                "removes the programs it made; anything else you keep in the "
                "archive is yours and is left alone." % r)
        return d

    def _existing_sidecar(self):
        """The sidecar, WITHOUT creating it. `open`/`delete` are operations on
        an archive that already exists; bootstrapping one to answer "no such
        program" would leave a git repo behind for a typo."""
        side = self._sidecar_path(self.repo_root)
        if not os.path.isdir(side):
            raise ActionError(404, "this project has no holodeck sidecar yet — "
                                   "start a program and one is created.")
        return side

    def _live_for_room(self, program_dir):
        """(sid, sess) for a live session holding this room, or (None, None)."""
        want = os.path.realpath(program_dir)
        with self._holodeck_lock:
            for sid, sess in self._holodeck.items():
                if os.path.realpath(sess.program_dir) == want:
                    return sid, sess
        return None, None

    def holodeck_open(self, room=None, engine=None):
        """POST /api/holodeck/open — pick a program back up from disk.

        THIS IS A WARM RESTART, NOT A RESUMED SESSION, and the payload says so
        in those words. The warm worker conversation died with whatever daemon
        (or CLI) held it; what survived is the room — the mockup, `basis.md`,
        `concept.md` and `transcript.md`. So a FRESH session-id is minted and
        the transcript is replayed into its opening prompt as context.

        Claiming otherwise would be S125's finding #2 in a new place: there, a
        non-empty `reply` was taken as proof a session existed and `RETRY TURN`
        `--resume`d an id the CLI had never created — a permanent dead end under
        a banner promising the chat was still running. A session id printed here
        would be exactly as unfounded.
        """
        sidecar = self._existing_sidecar()
        program_dir = self._room_dir(sidecar, room)
        sid, sess = self._live_for_room(program_dir)
        if sess is not None:
            # ALREADY OPEN. Hand back the live conversation rather than minting
            # a second session onto one room — two cards, one `mockup.html`.
            meta = self._holodeck_meta(sid, sess)
            meta["turns"] = self._turns_payload(sess.turns)
            return meta
        # ROUND 5 — THE ENGINE COMES FROM THE PROGRAM, not from whatever this
        # daemon was started with. See `_program_engine` for the rule.
        bin_, recorded = self._program_engine(program_dir, engine)
        name, turns = "", []
        try:
            with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                name, turns, _eng = _parse_transcript(fh.read())
        except (OSError, ValueError):
            pass
        room_name = os.path.basename(program_dir)
        if not name:
            name = room_name.replace("-", " ").strip() or room_name
        sid = uuid.uuid4().hex[:12]
        sess = _HolodeckSession(program=name, engine=bin_,
                                mode="design", sidecar_dir=sidecar,
                                program_dir=program_dir,
                                target_repo=os.path.abspath(self.repo_root),
                                engine_recorded=recorded)
        sess.turns = turns
        sess.grounded = bool(self._basis_file_in(program_dir))
        sess.restarted = True
        # "LAST WORKED" IS A FACT ABOUT DESIGN WORK, and opening a program is
        # not work. Taking the clock from the room keeps the list's recency line
        # true after a restart instead of stamping everything "now".
        when = self._room_mtime(program_dir)
        if when:
            sess.opened_at = when
            sess.last_touched = when
        with self._holodeck_lock:
            self._holodeck[sid] = sess
        meta = self._holodeck_meta(sid, sess)
        meta["turns"] = self._turns_payload(sess.turns)
        # ROUND 5 — AND WHERE THAT ENGINE CAME FROM. The banner already named
        # the CLI that answers the next turn, and on a real drive it named the
        # wrong one honestly: it was reporting the daemon's default. Naming the
        # SOURCE is what makes the sentence checkable — and a program whose
        # record predates round 5 gets told exactly that, rather than having
        # the default read as its own history.
        if recorded:
            provenance = (" It is the engine this program was designed on — "
                          "its own record says so.")
        else:
            provenance = (" This program's record does not say which engine it "
                          "was designed on, so it is running on this "
                          "viewscreen's default.")
        meta["warmRestart"] = {
            "kind": "warm-restart",
            "message": (
                "Picked this program back up from its room on disk. The "
                "conversation that built it is over — the %s that answers your "
                "next turn is a fresh one, handed the whole transcript (%d turn"
                "%s) as context. It knows what you decided; it remembers "
                "nothing itself. Nothing was lost: every turn is in "
                "transcript.md and the mockup is exactly as you left it.%s"
                % (os.path.basename(bin_), len(turns),
                   "" if len(turns) == 1 else "s", provenance)),
        }
        meta["status"] = "standing-by"
        meta["reply"] = ""
        meta["filesChanged"] = []
        return meta

    def _room_in_history(self, sidecar, room_name):
        """HEAD's sha if THIS ROOM is in HEAD's tree — otherwise "".

        The only evidence `recoverable` is allowed to be read off. Fix round 2
        read it off `committed`, which was true whenever the commit succeeded —
        and `git add -A` made it succeed on somebody ELSE's untracked files
        while the room itself had never been recorded at all.
        """
        try:
            proc = subprocess.run([self.git_bin, "-C", sidecar, "ls-tree",
                                   "--name-only", "HEAD", "--", room_name],
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
            if proc.returncode != 0 or not (proc.stdout or b"").strip():
                return ""
            head = subprocess.run([self.git_bin, "-C", sidecar, "rev-parse",
                                   "HEAD"], stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
            if head.returncode != 0:
                return ""
            return (head.stdout or b"").decode("utf-8", "replace").strip()
        except OSError:
            return ""

    def holodeck_delete(self, room=None):
        """POST /api/holodeck/delete — remove a program, KEEPING its history.

        `git rm` + a commit, never an `rm -rf`: the sidecar is a git repo
        precisely so that the answer to "I deleted the wrong one" is a checkout
        rather than an apology. The reply names the commit and the exact command
        that brings it back.

        FIX ROUND 3, DEFECT 1 — AND IT IS RECORDED BEFORE IT IS REMOVED.
        `git rm --ignore-unmatch` does nothing at all to an UNTRACKED room, and
        `shutil.rmtree` below then destroyed it; the `git add -A` afterwards
        swept up unrelated untracked files so the commit succeeded anyway, and
        the reply promised a checkout that answered `pathspec … did not match
        any file(s) known to git`. Round 2 made that the ORDINARY case rather
        than an edge: `_ensure_transcript` puts the program's record in the room
        the moment it is named and `_is_program_room` makes such a room
        deletable, so every program whose first turn has not landed — including
        the dead-first-turn one that cure was written for — was deletable and
        uncommitted.

        So the program is committed into the archive FIRST, its own room and
        nothing else, and the removal only happens once THIS ROOM is provably in
        history. If it cannot be recorded, nothing is removed and the captain is
        told so plainly. LCARS never destroys a program while calling it
        recoverable.
        """
        sidecar = self._existing_sidecar()
        program_dir = self._room_dir(sidecar, room)
        room_name = os.path.basename(program_dir)
        # THE BUSY CHECK AND THE CLOSE ARE ONE OPERATION, under the same lock
        # the turn claim uses. Checked and then popped in two steps, a turn
        # starting in between would be writing into a room this method is about
        # to `git rm` — which is the same "a smaller window is not a guard"
        # mistake the client-side `HOLO.busy` made.
        want = os.path.realpath(program_dir)
        sid, sess = None, None
        with self._holodeck_lock:
            for k, s in self._holodeck.items():
                if os.path.realpath(s.program_dir) == want:
                    sid, sess = k, s
                    break
            if sess is not None:
                if sess.busy:
                    raise ActionError(
                        409, "that program has a turn running right now, and "
                        "deleting its room out from under a worker that is "
                        "writing into it is how work gets lost. Wait for the "
                        "turn to come back, or press End Program to stop it, "
                        "then delete.")
                # claimed, so nothing can start a turn on it from here on.
                sess.busy = True
        name = sess.program if sess is not None else ""
        if not name:
            try:
                with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                    name = _parse_transcript(fh.read())[0]
            except (OSError, ValueError):
                name = ""
        name = name or room_name
        # ── RECORDED FIRST, REMOVED SECOND ──────────────────────────────────
        # ONLY THIS ROOM IS STAGED. The captain's own files in the archive are
        # his (his ruling), and leaning on them is precisely how the old commit
        # "succeeded" over a room git had never heard of.
        with self._sidecar_git_lock(sidecar):
            try:
                self._git(sidecar, ["add", "-A", "--", room_name],
                          "record the program before removing it")
                # nothing to stage means it is already recorded, and `commit`
                # says so by failing — which is the same answer.
                self._git(sidecar,
                          ["commit", "-q", "--no-gpg-sign", "-m",
                           "holodeck(%s): recorded the program before deleting "
                           "it" % name],
                          "record the program before removing it")
            except ActionError:
                pass
            base = self._room_in_history(sidecar, room_name)
        if not base:
            # NOT DESTROYED. The room is untouched and the program is still
            # openable; the captain decides what to do with something LCARS
            # cannot promise to bring back.
            if sess is not None:
                sess.busy = False
            raise ActionError(
                502, "LCARS could not record %s in the holodeck archive's git "
                "history, so removing it now would destroy it for good — and it "
                "will not do that while telling you it is recoverable. NOTHING "
                "HAS BEEN REMOVED: the program is still in its room at %s. Copy "
                "that folder somewhere safe (or fix git in the archive), then "
                "delete it again." % (room_name, program_dir))
        if sess is not None:
            with self._holodeck_lock:
                self._holodeck.pop(sid, None)
            sess.done = True
            _kill_process_group(sess.proc)
        committed = True
        with self._sidecar_git_lock(sidecar):
            try:
                self._git(sidecar,
                          ["rm", "-r", "-q", "--ignore-unmatch", "--",
                           room_name],
                          "remove the program from the holodeck archive")
            except ActionError:
                committed = False
            if os.path.isdir(program_dir):
                # whatever git did not track (a turn whose commit failed) still
                # has to leave the working tree, or the room reappears in the
                # list a second later.
                shutil.rmtree(program_dir, ignore_errors=True)
            try:
                self._git(sidecar, ["add", "-A", "--", room_name],
                          "stage the deletion")
            except ActionError:
                pass
            try:
                self._git(sidecar, ["commit", "-q", "--no-gpg-sign", "-m",
                                    "holodeck(%s): deleted the program — its "
                                    "history is kept" % name],
                          "commit the deletion")
            except ActionError:
                committed = False
            sha = ""
            try:
                proc = subprocess.run([self.git_bin, "-C", sidecar, "rev-parse",
                                       "HEAD"], stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL)
                if proc.returncode == 0:
                    sha = (proc.stdout or b"").decode("utf-8", "replace").strip()
            except OSError:
                sha = ""
        # `base` is the commit that PROVABLY holds this room — checked above,
        # by name, before a byte of it was removed. It is the sha the command
        # names, and it is the same command whether or not the removal itself
        # was committed.
        recover = ("`git -C %s checkout %s -- %s` brings every file of it back "
                   "exactly as it was." % (sidecar, base[:7], room_name))
        if committed:
            message = ("Deleted %s from the deck. It is not gone: LCARS "
                       "recorded the whole program in the archive's git history "
                       "before removing it, so %s" % (room_name, recover))
        else:
            message = ("Removed %s from the deck. Git could not commit the "
                       "removal itself, so the archive still shows it as "
                       "deleted-but-uncommitted — but the program WAS recorded "
                       "first, so %s" % (room_name, recover))
        return {"deleted": room_name, "program": name, "commit": sha,
                "committed": committed, "recoverable": True,
                "sidecar": sidecar,
                "commits": self._sidecar_commit_count(sidecar),
                "message": message}

    # ══ S172 — DUPLICATE: a NEW program carrying an old one's history ═══════
    #
    # A SENT program is locked forever (`_refuse_if_sent`) — it is the record of
    # what a mission was actually briefed on, and it must stay that. So the way
    # on is a duplicate, and the captain's ruling is that it BRINGS THE CHAT
    # OVER: "bring the original chat over for history when you duplicate it".
    # The duplicate is a CONTINUATION, not a clean copy of the outputs — a
    # worker in the new room knows WHY the mockup looks the way it does.
    #
    # It rides the roads S126 already built and adds no second copy mechanism:
    # `_existing_sidecar` + `_room_dir` resolve and police the source room, the
    # sidecar git repo records the new one exactly as `delete` records a removal,
    # and the room is then handed to `holodeck_open` — the warm-restart road,
    # whose `_replay_clause` is what puts the transcript in front of a fresh
    # worker. Nothing here mints a session or replays a transcript itself.

    # WHAT DOES NOT COME OVER. A DENY-LIST, deliberately: an allow-list of the
    # five named files would silently drop a second asset a worker wrote beside
    # the mockup, and the captain would never learn it was gone. (S124's
    # `--allowedTools` finding, one surface over: an allow-list is not a fence.)
    #
    # `handoff-changes.json` is the ONE thing that must not travel. It is a
    # derivation of the OLD draft against the captain's repo AS IT WAS at filing
    # time; the S170/S171 fingerprint would have to be wrong about the room for
    # it to ever be read back, so carrying it buys nothing and risks a change
    # list describing an app that has since moved. The duplicate starts with NO
    # derivation, the gate reads `none`, and it offers to generate one.
    def _duplicate_skips(self, name):
        if name.startswith("."):        # `.git` and friends are not the program
            return True
        return name in (self._HANDOFF_DERIVE_FILE,
                        self._HANDOFF_DERIVE_FILE + ".tmp")

    # `(copy)` / `(copy 2)` — stripped before deriving the next one, so
    # duplicating a duplicate gives `X (copy 2)` rather than `X (copy) (copy)`.
    _DUPLICATE_SUFFIX = re.compile(r"\s*\(copy(?:\s+\d+)?\)\s*$", re.IGNORECASE)

    def _claim_room(self, sidecar, room):
        """CREATE the room, and say whether this request is the one that got it.

        FIX ROUND 1 (D6). Asking `isdir` and then calling `makedirs` are two
        steps, and a second duplicate landing in the gap between them won the
        room while this one still believed it was free — which surfaced as a
        raw `FileExistsError` inside the 502 "could not create the new
        program's room", plumbing reported at the captain for an ordinary
        collision the naming loop already knows how to walk past. So the
        creation IS the claim: whoever's `makedirs` returns owns the room, and
        everybody else takes the next name.
        """
        try:
            os.makedirs(os.path.join(sidecar, room))
            return True
        except FileExistsError:
            return False
        except OSError as exc:
            raise ActionError(
                502, "could not create the new program's room in the holodeck "
                "sidecar: %s" % exc)

    def _room_program_name(self, sidecar, room):
        """The NAME of the program living in `room`, or "" if none does.

        Read out of the one durable home `_disk_program` reads it from, so a
        room the captain sees called "Command palette" is the same string this
        compares against.
        """
        try:
            with open(os.path.join(sidecar, room, _TRANSCRIPT)) as fh:
                return (_parse_transcript(fh.read())[0] or "").strip()
        except (OSError, ValueError):
            return ""

    def _named_program_room(self, sidecar, wanted):
        """The room a program ALREADY called `wanted` lives in, or "".

        FIX ROUND 2 (N1). The name guard used to ask `_program_room(wanted)` and
        look in that ONE room — which was true while every room was slugged out
        of its program's name, and stopped being true the moment fix round 1
        made a duplicate's room BUILT (`_duplicate_room`: trim, then append the
        marker where the `_SLUG_MAX` cut cannot eat it). On the whole-sentence
        names every program the captain actually has is called, the two
        disagree, so the guard was looking in a room the copy is not in and
        finding nothing: he could type back the very name the deck was showing
        him and get a second card reading it, while the refusal it skipped
        promises "two cards with one name is a pair you cannot tell apart".

        So the question is asked of the ARCHIVE rather than of the slug: every
        program room in the sidecar, by the name in its own record, the same
        string `_disk_program` puts on the card. `_program_room`'s answer is
        still tried FIRST — it is the room the name belongs in, so the common
        case still costs one read.

        The scan is a READ, and it is not atomic with the room claim that
        follows it: two duplicates typing one name in the same instant can both
        pass here, because neither has written its record yet. That race is left
        open deliberately (see `holodeck_duplicate`) — the ROOM claim below is
        atomic, so the two land in two rooms and neither is overwritten.
        """
        want = (wanted or "").strip().lower()
        if not want:
            return ""
        first = _program_room(sidecar, wanted)
        try:
            rest = [n for n in sorted(os.listdir(sidecar)) if n != first]
        except OSError:
            rest = []
        for room in [first] + rest:
            if room.startswith("."):     # `.git` and friends are not programs
                continue
            path = os.path.join(sidecar, room)
            if not os.path.isdir(path) or not self._is_program_room(path):
                continue
            if self._room_program_name(sidecar, room).lower() == want:
                return room
        return ""

    def _claim_duplicate_room(self, sidecar, source_name):
        """A (name, room) THIS REQUEST NOW OWNS, derived from the one copied.

        S172, TRAP 4, cured for real in fix round 1. Keyed off the ROOM and not
        the name, because the room is the identity — but the room is now BUILT
        (`_duplicate_room`) rather than slugged out of "X (copy N)", so the
        marker survives the `_SLUG_MAX` cut on the long, whole-sentence names
        every program the captain actually has is called. Before that, every
        candidate for such a name came back as the SOURCE room, all 500 of them,
        and the road the dialog recommends could not copy anything at all.

        FIX ROUND 2 (N1, one road over): a free room is not a free NAME. The
        walk counts ROOMS, so a copy the captain named "X (copy)" HIMSELF —
        which the `_SLUG_MAX` cut can put in a room this walk never visits —
        left the blank road free to hand the same name out again. That is the
        pair the 409 next door refuses, arrived at by the road the dialog
        RECOMMENDS, with no race and one captain. So each candidate name is
        checked against the archive before its room is claimed.
        """
        base = self._DUPLICATE_SUFFIX.sub("", str(source_name or "").strip())
        base = base or "Program"
        n = 1
        while n <= 500:
            name = "%s (copy)" % base if n == 1 else "%s (copy %d)" % (base, n)
            if self._named_program_room(sidecar, name):
                n += 1                  # that name is already a card on the deck
                continue
            if self._claim_room(sidecar, _duplicate_room(base, n)):
                return name, _duplicate_room(base, n)
            n += 1
        raise ActionError(
            409, "there are already hundreds of copies of %r in this "
            "holodeck's archive, so LCARS has run out of free names to give "
            "this one. Duplicate it under a name of your own." % base)

    def _claim_named_room(self, sidecar, wanted):
        """The room for a name THE CAPTAIN TYPED — his name, kept exactly.

        Two different names can land in one room: the ledgered unicode legacy
        collapses anything with no ASCII in it to the shared `program` room, and
        the `_SLUG_MAX` cut collapses any two long names that agree for their
        first 48 characters — which, on a duplicate, is nearly every name he
        could sensibly type, because the obvious one is the source's with a word
        added. Refusing those told him to "duplicate it under a different name"
        about a name that WAS different.

        So a taken room is walked past, not refused: his name is kept and the
        room gets a number. The ONE refusal left is a name that is already a
        program's name — a card he could not tell from the one beside it — and
        nothing is ever written into a room that is not this request's own.

        FIX ROUND 2 (N1): "already a program's name" is asked of the ARCHIVE
        (`_named_program_room`), not of the room the name slugs to. A duplicate
        does not live in that room, so the guard was blind to every copy on the
        deck — including the one the captain is looking at when he types its
        name in.
        """
        taken = self._named_program_room(sidecar, wanted)
        if taken:
            raise ActionError(
                409, "there is already a program called %r in this holodeck, "
                "in the room %r. Two cards with one name is a pair you cannot "
                "tell apart, so nothing has been copied and the original is "
                "untouched. Duplicate it under a different name — or leave the "
                "name blank and LCARS will give it a free one."
                % (wanted, taken))
        first = _program_room(sidecar, wanted)
        n = 1
        while n <= 500:
            room = first if n == 1 else _room_with_marker(wanted, "%d" % n)
            if self._claim_room(sidecar, room):
                return room
            n += 1
        raise ActionError(
            409, "there are already hundreds of rooms in this holodeck whose "
            "names land beside %r, so LCARS has run out of free ones to put "
            "this copy in. Duplicate it under a different name." % wanted)

    def holodeck_duplicate(self, room=None, program=None, engine=None):
        """POST /api/holodeck/duplicate — keep designing from a locked program.

        A NEW room in the same sidecar, in `draft` state and fully editable,
        carrying `mockup.html`, `concept.md`, `basis.md`, `attachments/` and —
        the captain's ruling — `transcript.md`. The original is NEVER mutated:
        it stays `sent`, locked, with its missionId, because it is the record of
        what was actually filed.

        The duplicate reads `draft` because it HAS NO SENT RECORD, not because
        anything special-cased it: `_write_duplicate_record` takes the hand-off
        line out of the copied header, and `_handoff_state` — the same one
        function every card's lifecycle comes from — then answers `draft` on its
        own.
        """
        sidecar = self._existing_sidecar()
        src_dir = self._room_dir(sidecar, room)
        src_room = os.path.basename(src_dir)
        src_name = ""
        try:
            with open(os.path.join(src_dir, _TRANSCRIPT)) as fh:
                src_name = _parse_transcript(fh.read())[0]
        except (OSError, ValueError):
            src_name = ""
        src_name = src_name or src_room.replace("-", " ").strip() or src_room
        mission = (self._sent_record(src_dir) or {}).get("missionId") or ""

        # A TURN IN FLIGHT IS A ROOM BEING WRITTEN INTO, and copying it would
        # take half a mockup. The same guard `delete` takes, for the same
        # reason — and read under the same lock the turn claim uses.
        want = os.path.realpath(src_dir)
        with self._holodeck_lock:
            busy = any(os.path.realpath(s.program_dir) == want and s.busy
                       for s in self._holodeck.values())
        if busy:
            raise ActionError(
                409, "that program has a turn running right now, and copying a "
                "room while a worker is writing into it would take half a "
                "mockup. Wait for the turn to come back, then duplicate it.")

        # THE ROOM IS CLAIMED, NOT MERELY CHOSEN — creating it is how this
        # request comes to own it, so nothing can be written into a room that
        # belongs to somebody else (fix round 1, D1 + D6).
        #
        # THE NAME IS CHECKED, NOT CLAIMED, and that difference is deliberate
        # (fix round 2, N1). A program's name is only on disk once its record is
        # written, at the far end of a whole-room copy, so making the name check
        # atomic would mean holding a lock across that copy and serialising
        # every duplicate in the daemon. Measured cost of leaving it: N requests
        # typing ONE name in the same instant produce N identically-named cards
        # — which needs concurrent POSTs, not a captain in a dialog. Measured
        # cost of the collision itself: none. The ROOM claim below IS atomic, so
        # they land in N rooms, nothing is overwritten, and the `⌂ room` chip on
        # the card tells them apart.
        wanted = (program or "").strip()
        if wanted:
            new_name = wanted
            new_room = self._claim_named_room(sidecar, new_name)
        else:
            new_name, new_room = self._claim_duplicate_room(sidecar, src_name)
        new_dir = os.path.join(sidecar, new_room)
        try:
            for name in sorted(os.listdir(src_dir)):
                if self._duplicate_skips(name):
                    continue
                src = os.path.join(src_dir, name)
                dst = os.path.join(new_dir, name)
                if name in (_TRANSCRIPT, _BASIS) and os.path.islink(src):
                    # …WITH ONE EXCEPTION, and it is not a policy: these are the
                    # two files this road REWRITES. `_write_duplicate_record`
                    # gives the copy its own name and lineage, and
                    # `_mark_basis_inherited` banners the grounding. Carried as
                    # a link, either write would go straight through it and edit
                    # whatever it points at — the SOURCE's record, or a file
                    # outside the room entirely, which is the one thing every
                    # other line in this loop is careful not to do. So they are
                    # materialised as bytes, which is the same content the
                    # source itself reads through the link.
                    shutil.copy2(src, dst, follow_symlinks=True)
                elif os.path.islink(src):
                    # A LINK IS COPIED AS A LINK (fix round 1, D4). It used to
                    # be dropped here, on the reasoning that copying it "would
                    # put that same escape in a second room" — but the escape is
                    # refused at READ time by `_room_file_path`, in the copy
                    # exactly as in the source, so nothing was bought; and the
                    # rule was not even applied one directory down, where
                    # `copytree(symlinks=False)` FOLLOWED the link and wrote the
                    # bytes from outside the room into the duplicate as a real
                    # file the jail then served. So the copy was at once more
                    # permissive than its source and more lossy than it — a
                    # top-level linked asset silently vanished from a room the
                    # dialog promises carries "anything you pasted in".
                    #
                    # A DUPLICATE BEHAVES EXACTLY AS ITS SOURCE DOES. Rooms all
                    # sit at one depth in the sidecar, so a relative link
                    # resolves to the same place from either of them.
                    os.symlink(os.readlink(src), dst)
                elif os.path.isdir(src):
                    shutil.copytree(src, dst, symlinks=True,
                                    ignore=shutil.ignore_patterns(".*"))
                else:
                    shutil.copy2(src, dst)
        except (OSError, shutil.Error) as exc:
            # NOTHING HALF-COPIED IS LEFT ON THE DECK. A partial room would list
            # as a program (it has a transcript) with somebody else's mockup in
            # it and no way to tell.
            shutil.rmtree(new_dir, ignore_errors=True)
            raise ActionError(
                502, "LCARS could not copy this program into its new room, so "
                "nothing was duplicated and the original is untouched: %s"
                % exc)
        when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        if not self._write_duplicate_record(new_dir, new_name, src_room,
                                            src_name, mission, when):
            shutil.rmtree(new_dir, ignore_errors=True)
            raise ActionError(
                502, "the copy was made but LCARS could not write the new "
                "program's own record into it — so it would not know its own "
                "name, and it would still read as the one that was sent to "
                "Align. Nothing has been left behind and the original is "
                "untouched. Check %s is writable, then duplicate it again."
                % sidecar)
        self._mark_basis_inherited(new_dir, src_name)
        committed = True
        with self._sidecar_git_lock(sidecar):
            try:
                # ONLY THIS ROOM IS STAGED — the captain's own files in the
                # archive are his (the rule `delete` follows for the same
                # reason: leaning on `git add -A` is how a commit "succeeds"
                # over a room git has never heard of).
                self._git(sidecar, ["add", "-A", "--", new_room],
                          "record the duplicated program")
                self._git(sidecar,
                          ["commit", "-q", "--no-gpg-sign", "-m",
                           "holodeck(%s): duplicated from %s — a new program "
                           "carrying its history" % (new_name, src_room)],
                          "record the duplicated program")
            except ActionError:
                committed = False
        # AND ONTO THE EXISTING ROAD. `holodeck_open` mints the fresh session
        # and hands the whole transcript to a fresh worker via `_replay_clause`
        # — which reads this room's own origin record and says, in its own
        # sentence, that none of that history is binding.
        meta = self.holodeck_open(room=new_room, engine=engine)
        # ONE VOICE. The warm-restart message is the account of a program being
        # PICKED BACK UP, and this is not that; the duplicate's own message says
        # everything that one said (a fresh worker, handed the whole transcript)
        # plus the two facts only this road knows.
        meta.pop("warmRestart", None)
        meta["committed"] = committed
        meta["duplicated"] = {
            "kind": "duplicated",
            "from": src_room, "fromProgram": src_name, "missionId": mission,
            "committed": committed,
            "message": (
                "Duplicated %s into a new program, %s (room %s). It carries the "
                "mockup, the concept doc%s and the WHOLE conversation — the %s "
                "answering your next turn is a fresh one, handed that "
                "transcript as context, and nothing in it is binding: this is a "
                "new program, so change whatever you like. %s%s"
                % (src_name, new_name, new_room,
                   ", the grounding"
                   if self._basis_file_in(new_dir) else "",
                   os.path.basename(meta.get("engine")
                                    or self.worker_bin or "worker"),
                   ("%s stays exactly as it was handed over to mission %s and "
                    "is untouched." % (src_name, mission)) if mission
                   else ("%s is untouched." % src_name),
                   "" if committed else
                   " Git could not commit the new room to the archive, so it is "
                   "on disk but not yet in the sidecar's history.")),
        }
        return meta

    @staticmethod
    def _write_duplicate_record(program_dir, new_name, src_room, src_program,
                                mission_id, when):
        """Make the COPIED transcript this program's own record. True on success.

        Three edits, all inside the header block LCARS itself authored when the
        original was named — not one line a model wrote is rewritten or moved:

          • the `# ` heading becomes THIS program's name;
          • the hand-off line GOES. It is the fact that a mission was briefed on
            those exact files, and it belongs to the program that was actually
            filed. Left in place it would lock the duplicate on arrival, which
            is the one thing this whole road exists to undo;
          • an older duplicate's lineage line goes too, and is replaced with
            this one — a duplicate points at ITS parent, not at its grandparent.
        """
        path = os.path.join(program_dir, _TRANSCRIPT)
        try:
            with open(path) as fh:
                text = fh.read()
        except OSError:
            return False
        text = text.replace("\r\n", "\n")
        parts = re.split(r"(?m)^(## )", text, maxsplit=1)
        head = parts[0]
        rest = "".join(parts[1:])
        lines = head.split("\n")
        for i, line in enumerate(lines):
            if line.startswith("# "):
                lines[i] = "# %s" % new_name
                break
        else:
            lines.insert(0, "# %s" % new_name)
        head = "\n".join(lines)
        head = _SENT_LINE.sub("", head)
        head = _ORIGIN_LINE.sub("", head)
        head = re.sub(r"\n{3,}", "\n\n", head).rstrip("\n") + "\n\n"
        head += _origin_header_line(src_room, src_program, mission_id, when)
        try:
            with open(path, "w") as fh:
                fh.write(head + rest)
        except OSError:
            return False
        return True

    def _mark_basis_inherited(self, program_dir, src_program):
        """TRAP 2's ruling, applied to the file itself: the grounding comes over
        WHOLE and says at the top that it may no longer be true.

        Best-effort and never fatal — a duplicate whose basis could not be
        re-marked is still a duplicate, and the payload's `basisInherited` is
        derived from the LINEAGE RECORD rather than from this write, so the deck
        says it either way.
        """
        name = self._basis_file_in(program_dir)
        if not name:
            return False
        path = os.path.join(program_dir, name)
        try:
            when = time.strftime("%Y-%m-%d",
                                 time.localtime(os.path.getmtime(path)))
            with open(path) as fh:
                body = fh.read()
            with open(path, "w") as fh:
                fh.write(_basis_with_inherited_mark(body, src_program, when))
        except OSError:
            return False
        return True

    def _origin_record(self, program_dir):
        """This program's DUPLICATE lineage, read off disk, or None. The same
        road `_sent_record` takes, reading the same one durable home."""
        try:
            with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                return _parse_origin(fh.read())
        except (OSError, ValueError):
            return None

    def _origin_fields(self, program_dir):
        """The S172 keys, for BOTH payload shapes, from ONE function.

        The live `_holodeck_meta` and the on-disk listing both call this, for
        the reason `_handoff_state` and `_busy_fields` are each one function:
        two copies of the rule is exactly how a live card and a restarted one
        start disagreeing about what a program came from.

        ADDITIVE BY CONSTRUCTION. An ordinary program gets an EMPTY DICT, so
        its payload is byte-identical to the one every S124–S171 test pins —
        and a surface reading the absence of `basisInherited` reads it
        correctly, because absence is the honest answer for a grounding that
        really was read for this program.
        """
        rec = self._origin_record(program_dir)
        if not rec:
            return {}
        out = {"duplicatedFrom": rec}
        # THE ROOM MUST SAY IT (trap 2), in the payload the deck renders as well
        # as in the file. Keyed off the LINEAGE, not off the write that marked
        # the file: a basis whose re-marking failed is still an inherited one.
        if self._basis_file_in(program_dir):
            out["basisInherited"] = True
            out["basisNotice"] = (
                "This program's basis.md came over with the duplicate: it is "
                "what LCARS read out of the project for “%s”, not a fresh look "
                "at it. If that design has been built since, the app has moved "
                "and the basis may be stale — check anything you build on it "
                "against the project as it is now."
                % (rec.get("program") or "the original program"))
        return out

    # ── the seam itself ────────────────────────────────────────────────────
    @staticmethod
    def _switch_to_design(sess):
        """Move a grounded program from its one read-only pass into the design
        posture — as a FRESH warm session, never as a mutated one.

        S124 made the two postures separate sessions on purpose: they have
        different tools AND different cwds, and resuming one warm conversation
        across that switch is a behaviour no spike has measured. So the design
        chat gets its own session-id and its own opening envelope; the grounding
        it was made of is on disk beside it as `basis.md`, which the design
        prompt points at, so nothing is lost by not carrying the conversation.
        """
        if sess.mode != "grounding":
            return
        sess.mode = "design"
        sess.worker_sid = str(uuid.uuid4())
        sess.started = False

    @staticmethod
    def _display_path(path):
        """A path as a PERSON reads it: `$HOME` folded back to `~`.

        The daemon does this because only the daemon knows the home directory —
        the board has none, and D6's empty state is the one place in the whole
        product that shows a path, so it must be the readable form."""
        path = str(path or "")
        if not path:
            return ""
        home = os.path.expanduser("~")
        if home and home != os.sep and (path == home
                                        or path.startswith(home + os.sep)):
            return "~" + path[len(home):]
        return path

    def _basis_file(self, sess):
        """`basis.md` if this program actually has one on disk (D12: the header
        links to it). Never a name the surface would then 404 on."""
        return self._basis_file_in(sess.program_dir)

    @staticmethod
    def _basis_file_in(program_dir):
        """The same question asked of a ROOM rather than a live session — S126's
        list reads rooms off disk, and a second copy of this rule is exactly how
        a live card and a restarted one start disagreeing."""
        try:
            if os.path.isfile(os.path.join(program_dir, _BASIS)):
                return _BASIS
        except OSError:
            pass
        return None

    @classmethod
    def _concept_file_in(cls, program_dir):
        """`concept.md` if this program has one WITH SOMETHING IN IT, else None.

        FIX ROUND 2. This key is what makes the deck's ▤ Intent control
        openable, and it was keyed off existence alone — so on the very turn
        the audit correctly reported "there is a file in the room with nothing
        in it", the control opened that blank file in a new tab. Same rule as
        `_basis_file_in`: never a name the surface then shows nothing for.
        The audit is unchanged; it reports the file's existence and its
        emptiness as the separate facts they are.
        """
        path = os.path.join(program_dir, _CONCEPT)
        try:
            if not os.path.isfile(path):
                return None
            with open(path) as fh:
                if not fh.read().strip():
                    return None
        except OSError:
            return None
        return _CONCEPT

    # ── S127 (D11 + D5): the two facts the hand-off adds to every card ──────
    # `status`/`missionId` are the lifecycle; `handoffReady`/`handoffBlocked`
    # are whether SEND TO ALIGN can fire and, when it cannot, the daemon's OWN
    # sentence for why. The reason is composed here rather than in the browser
    # for the one-voice rule: the deck must never invent an explanation for a
    # refusal it did not make.
    def _handoff_state(self, program_dir):
        # `status` AND `lifecycle` carry the same value, deliberately. `status`
        # is the key S126 shipped and the program list reads — but it is also
        # the key the TURN payloads use for a turn's outcome ("standing-by",
        # "ok", "refused", "ended"), and those payloads `update()` over this
        # meta. So a single-program read (`open`, a turn) would answer
        # "standing-by" for a program that is LOCKED. `lifecycle` is never
        # overwritten by anything, and is what a surface should ask.
        rec = self._sent_record(program_dir)
        life = "sent" if rec else "draft"
        out = {"status": life, "lifecycle": life,
               "missionId": (rec or {}).get("missionId") or "",
               "sentAt": (rec or {}).get("at") or ""}
        if rec:
            out["handoffReady"] = False
            out["handoffBlocked"] = ""
            return out
        missing = []
        for name in _HANDOFF_FILES:
            try:
                target, _p = self._room_file_path(program_dir, name)
            except ActionError:
                missing.append(name)
                continue
            if not os.path.isfile(target):
                missing.append(name)
        out["handoffReady"] = not missing
        out["handoffBlocked"] = "" if not missing else (
            "There is no %s in this program's room yet, so there is nothing to "
            "hand over. Keep designing in the chat — the holodeck writes the "
            "mockup and the concept doc as you go." % " or ".join(missing))
        return out

    def _busy_fields(self, sess):
        """The IN-FLIGHT fact for one program — or `{}`, which is the point.

        S128 (FL-002/FL-004). ONE function answers this for BOTH shapes: the
        live `_holodeck_meta` and the on-disk listing, which passes None
        because a room nobody is holding has no conversation and therefore
        cannot be mid-turn. Two copies of this rule is exactly how a restarted
        card and a live one start disagreeing about a lock.

        ADDITIVE BY CONSTRUCTION: an idle program gets an empty dict, so its
        payload is byte-identical to the one every S124–S127 test pins. A
        `busy: false` on every idle program would have been a new key on that
        shape — and a client that has to ask "is this key even here?" reads the
        absence correctly by accident, which is not a contract.

        DELIBERATELY LOCK-FREE. `_holodeck_lock` is a plain Lock and this is
        called from shape-builders reached on several paths; taking it here to
        read two attributes would be a deadlock waiting for the first caller
        that already holds it. The write order in `_claim_turn` /
        `_release_turn` is what makes the lock-free read safe: `busy` is set
        last and cleared first, so seeing it True guarantees a start time.
        """
        if sess is None:
            return {}
        if not sess.busy:
            return {}
        # THE TURN'S OWN ANSWER IS NOT A REPORT OF WORK IN FLIGHT. `_run_turn`
        # builds its payload while it still holds the claim, so without this
        # every completed `/say` would come back telling the client the turn it
        # is answering is still running — and by the time those bytes are read,
        # the claim is already released.
        if sess.turn_thread == threading.current_thread().ident:
            return {}
        started = sess.turn_started
        if not started:                         # pragma: no cover - defensive
            return {}
        elapsed = max(0.0, time.time() - started)
        label, reason = _holodeck_busy_copy(elapsed)
        return {"busy": True, "busySince": started,
                # computed HERE, at read time, so a client renders elapsed
                # without ever having to agree with this daemon about the wall
                # clock — the class of bug a raw timestamp alone invites.
                "busyFor": round(elapsed, 1),
                "busyLabel": label, "busyReason": reason}

    def _holodeck_meta(self, sid, sess):
        # S125 additions are all ADDITIVE (D2/D3/D6/D8): `previewFile` is what
        # the live-preview iframe points at, `sidecarName` + `commits` are the
        # program list's footer chip, and `lastTouched` is its recency line. The
        # S124 keys are untouched, so every S124 test reads the same shape.
        meta = {"sessionId": sid, "program": sess.program, "mode": sess.mode,
                # `grounded` + `basisFile` are the D12 pair: the chip says this
                # mockup is built on the project's own language, and the link
                # is what makes that grounding INSPECTABLE (a grounding you
                # cannot read is one you cannot correct). `mode` alone could not
                # carry it — it moves to "design" after the opening pass.
                "grounded": bool(sess.grounded),
                "basisFile": self._basis_file(sess),
                # S126 — this program has a live conversation, so it is not one
                # of the rooms the list read off disk.
                "onDisk": False,
                "restarted": bool(sess.restarted),
                # S126 FIX ROUND 2 — IS THERE A WARM WORKER SESSION TO RESUME?
                # `sess.started` is the daemon's own answer (the same evidence
                # N4's cure is keyed off: files or a clean exit, never a
                # reply), and the deck's `WARM · <engine>` pill was ASSERTING
                # it — two inches under the banner saying the warm conversation
                # died with the daemon that held it. One voice, one fact.
                "warm": bool(sess.started),
                "conceptFile": self._concept_file_in(sess.program_dir),
                "sidecar": sess.sidecar_dir, "programDir": sess.program_dir,
                # THE DISCRIMINATOR (round 2). Two names that read the same —
                # a homoglyph, a name the collision check cannot honestly
                # refuse — still occupy two different ROOMS, and this is what
                # lets the program list show a captain which card is which.
                "room": os.path.basename(sess.program_dir),
                "engine": sess.engine or self.worker_bin,
                # ROUND 5 — WHERE THAT ENGINE CAME FROM. The surface may say a
                # program was DESIGNED on an engine only when this is true.
                "engineRecorded": bool(sess.engine_recorded),
                "turnCount": len(sess.turns),
                # S127 (D11) — the lifecycle, read from the program's own
                # record so a live card and a restarted one cannot disagree.
                # `done` is NOT set here: it is a fact about the MISSION
                # merging, and nothing in this round reads that back.
                "previewFile": self._preview_file(sess),
                "sidecarName": os.path.basename(sess.sidecar_dir),
                "commits": self._sidecar_commit_count(sess.sidecar_dir),
                "openedAt": sess.opened_at,
                "lastTouched": sess.last_touched}
        meta.update(self._handoff_state(sess.program_dir))
        # S172 — WHAT THIS PROGRAM WAS DUPLICATED FROM, when it was. Empty for
        # every ordinary program; see `_origin_fields`.
        meta.update(self._origin_fields(sess.program_dir))
        # S128 (FL-002) — IS A TURN IN FLIGHT RIGHT NOW, and since when. Empty
        # for an idle program, so the shape above is untouched the rest of the
        # time. See `_busy_fields`.
        meta.update(self._busy_fields(sess))
        # S171 — THE GATE'S STATE, PUBLISHED, so ▶ SEND TO ALIGN is rendered
        # from a fact rather than from anything the browser worked out for
        # itself. A PEEK: reading the deck must never spend, so this is the one
        # call shape that cannot start a pass (`start` defaults to False).
        #
        # It rides only on a LIVE program. A room read off disk has no session,
        # no target repo and no send bar — and the honest answer for a card
        # that cannot be handed over is no key at all, not a guessed "none".
        meta["derive"] = self._handoff_derive_state(sess)
        return meta

    # ── S125: the surface's three reads (list · preview file · one file) ────
    #
    # These are READS, and they are the whole of what the holodeck surface adds
    # to the daemon's GET side. They never spawn a worker, never write, and are
    # wired on the LOCAL write board only (`actions is not None`) — a read-only
    # build holds no sessions, so there is nothing there to serve and the board
    # hides the affordance entirely (D7's VIEW ONLY).

    # What the preview pane renders, in preference order. `mockup.html` is the
    # name the turn prompt asks for and the name the hand-off carries (S127), so
    # it wins outright; any other html in the room is the fallback so a worker
    # that named it something else still shows SOMETHING rather than an empty
    # deck that looks broken. None ⇒ the LCARS empty state, never a dead iframe.
    _PREVIEW_PREFERRED = "mockup.html"

    def _preview_file(self, sess):
        return self._preview_file_in(sess.program_dir)

    @classmethod
    def _preview_file_in(cls, program_dir):
        """The preview choice, asked of a ROOM. One rule, used by both the live
        session and S126's on-disk listing."""
        try:
            names = sorted(os.listdir(program_dir))
        except OSError:
            return None
        if cls._PREVIEW_PREFERRED in names:
            return cls._PREVIEW_PREFERRED
        for name in names:
            if name.lower().endswith((".html", ".htm")):
                if os.path.isfile(os.path.join(program_dir, name)):
                    return name
        return None

    def _sidecar_commit_count(self, sidecar):
        """How many commits the sidecar holds (D6's program-list footer chip).

        Best-effort and never fatal: a sidecar that is somehow not a git repo
        answers 0 rather than breaking the surface that reports it."""
        try:
            proc = subprocess.run([self.git_bin, "-C", sidecar, "rev-list",
                                   "--count", "HEAD"],
                                  stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
        except OSError:
            return 0
        if proc.returncode != 0:
            return 0
        try:
            return int((proc.stdout or b"").decode("utf-8", "replace").strip())
        except ValueError:
            return 0

    # ── S126 (#2): the rooms on disk ───────────────────────────────────────
    # The sidecar IS the archive, so the program list is a read of the disk with
    # the live conversations laid over it — not the other way round. Before
    # this, `holodeck_list` returned only `_HolodeckSession`s, so a daemon
    # restart emptied a list whose contents had never left the filesystem.
    @staticmethod
    def _room_mtime(program_dir):
        """When this program was last WORKED, from the room itself.

        Reopening a program does NOT move this: "last worked" is a fact about
        design work, and resetting it on a mere open is how a list of twelve
        programs stops being able to answer "which one was that".
        """
        newest = 0.0
        try:
            newest = os.path.getmtime(program_dir)
        except OSError:
            return 0.0
        try:
            for entry in os.scandir(program_dir):
                try:
                    newest = max(newest, entry.stat().st_mtime)
                except OSError:
                    continue
        except OSError:
            pass
        return newest

    def _disk_program(self, sidecar, room, commits=None):
        """One room on disk, in the SAME shape `_holodeck_meta` produces — plus
        `onDisk`, and a `sessionId` of None because there honestly isn't one.

        `commits` is passed in by `_disk_programs` because it is a property of
        the SIDECAR, not of the room: counted per room it is one `git rev-list`
        subprocess per program on every listing, for the same number every time.
        """
        program_dir = os.path.join(sidecar, room)
        name, turns, recorded_engine = "", [], ""
        try:
            with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                name, turns, recorded_engine = _parse_transcript(fh.read())
        except (OSError, ValueError):
            pass
        if not name:
            # LAST RESORT ONLY (fix round 2). Every program's record is opened
            # with its name at the moment the captain types it, so this is
            # reached only by a transcript whose heading is gone — the slug is
            # LOSSY and reading a name back out of it is defect 4 itself.
            name = room.replace("-", " ").strip() or room
        when = self._room_mtime(program_dir)
        # ROUND 5 — THE ENGINE THIS PROGRAM WAS BUILT ON, when its own record
        # names one. The listing used to answer the daemon's default for every
        # room in the archive, which is how a claude-built program came to read
        # `engine: /opt/homebrew/bin/copilot` after a restart. It is NOT
        # resolved here (a listing must not 502 over an engine that is no
        # longer installed) — reopening does that, and says so.
        engine = recorded_engine or (self.worker_bin or "").strip()
        out = {
            "sessionId": None, "onDisk": True, "program": name,
            "mode": "design", "grounded": bool(self._basis_file_in(program_dir)),
            "basisFile": self._basis_file_in(program_dir),
            # a room on disk is by definition not a conversation, so there is
            # nothing warm about it.
            "warm": False,
            "sidecar": sidecar, "programDir": program_dir, "room": room,
            "engine": engine, "engineRecorded": bool(recorded_engine),
            "turnCount": len(turns),
            "previewFile": self._preview_file_in(program_dir),
            "conceptFile": self._concept_file_in(program_dir),
            "sidecarName": os.path.basename(sidecar),
            "commits": (self._sidecar_commit_count(sidecar)
                        if commits is None else commits),
            "openedAt": when, "lastTouched": when,
            "turns": turns,
        }
        # S127 — the SAME lifecycle rule a live card gets, from the same
        # function reading the same file. Two copies of this is exactly how a
        # restarted card and a live one start disagreeing about a lock.
        out.update(self._handoff_state(program_dir))
        # S172 — and the SAME lineage rule, from the same function reading the
        # same file, so a card read off disk and a live one cannot disagree
        # about what a program came from.
        out.update(self._origin_fields(program_dir))
        # S128 (FL-002) — and the SAME rule for the in-flight fact, asked of the
        # same function. A room on disk is not a conversation, so the honest
        # answer is always "no keys" — but it is the one function that decides
        # that, not a second reading of the same question over here.
        out.update(self._busy_fields(None))
        return out

    @staticmethod
    def _is_program_room(program_dir):
        """Is this directory one of the HOLODECK'S OWN programs?

        FIX ROUND 2, defect 7. The answer used to be "it is a directory", and
        the sidecar is advertised to the captain as HIS archive — a git repo
        beside his project that he can back up and keep things in. So a dropped
        `screenshots-i-saved/` was listed as a program called `screenshots i
        saved` with 0 turns and a working ⌫ DELETE that `git rm`'d it.

        A program is a room with the program's own record in it. That record is
        written the moment the captain names the program (`_ensure_transcript`)
        and is never removed while the program exists, so this is one question
        with one answer — not a guess about what the folder might contain.
        """
        try:
            return os.path.isfile(os.path.join(program_dir, _TRANSCRIPT))
        except OSError:                          # pragma: no cover - defensive
            return False

    def _disk_programs(self, sidecar):
        out = []
        if not sidecar or not os.path.isdir(sidecar):
            return out
        try:
            names = sorted(os.listdir(sidecar))
        except OSError:
            return out
        commits = self._sidecar_commit_count(sidecar)
        for name in names:
            if name.startswith("."):      # `.git` and friends are not programs
                continue
            path = os.path.join(sidecar, name)
            if not os.path.isdir(path):
                continue
            # THE CAPTAIN'S OWN FOLDERS ARE HIS. Anything in the archive that
            # is not a program is left alone and never listed as one.
            if not self._is_program_room(path):
                continue
            out.append(self._disk_program(sidecar, name, commits=commits))
        return out

    def holodeck_list(self):
        """GET /api/holodeck — every program in this repo's holodeck.

        THE DISK IS THE LIST; the live `_HolodeckSession`s are laid over it, so
        a program that this daemon never opened still appears, with its turn
        count read out of its own transcript.

        S127 — each entry's `status`/`lifecycle` is now REAL: `draft` until the
        program is sent to Align, `sent` (with its `missionId`) after, read out
        of the program's own record so a restart cannot lose it. `done` is not
        set by anything yet — it is a fact about the MISSION merging, and
        nothing here reads that back.
        """
        with self._holodeck_lock:
            items = list(self._holodeck.items())
        out = []
        live_rooms = set()
        for sid, sess in items:
            meta = self._holodeck_meta(sid, sess)
            meta["turns"] = self._turns_payload(sess.turns)
            meta["onDisk"] = False
            out.append(meta)
            live_rooms.add(os.path.realpath(sess.program_dir))
        try:
            sidecar_now = self._sidecar_path(self.repo_root)
        except ActionError:
            sidecar_now = ""
        for meta in self._disk_programs(sidecar_now):
            # A LIVE PROGRAM IS LISTED ONCE. Its room is on disk too, and a
            # second card for it would be two cards a captain cannot tell apart
            # — one of which cannot be typed into.
            if os.path.realpath(meta["programDir"]) in live_rooms:
                continue
            out.append(meta)
        out.sort(key=lambda m: m.get("lastTouched") or 0, reverse=True)
        # THE HEADER IS WHAT THE SURFACE NEEDS BEFORE A PROGRAM EXISTS, and both
        # halves of it were being invented by the front end until this round:
        #   • `sidecar` — D6 names the archive's FULL PATH once, in the empty
        #     state, because the reason for naming it at all is that the captain
        #     must be able to back it up. A basename is not a location, and the
        #     board could only ever guess one.
        #   • `engine`/`model` — the New Program dialog printed a HARDCODED
        #     "sonnet tier", which is simply false on copilot (`_holodeck_model`
        #     returns claude-opus-4.8 there). It now reads what will actually
        #     run, from the same function the spawn uses.
        #   • `models` (S127) — the dialog now PICKS the engine, so its footer
        #     tier follows the pick and not this daemon's default. That needs
        #     the tier of an engine the daemon is NOT running, and the one way
        #     that does not end in a second copy of the mapping drifting from
        #     `_holodeck_model` is to publish the mapping itself. It is derived
        #     here, per offered engine, from that same function — never from
        #     `self.worker_bin`, which is what would make copilot read "sonnet".
        engine = (self.worker_bin or "").strip()
        try:
            sidecar = self._sidecar_path(self.repo_root)
        except ActionError:
            sidecar = ""
        return {"programs": out,
                "sidecar": sidecar,
                "sidecarDisplay": self._display_path(sidecar),
                "sidecarName": os.path.basename(sidecar) if sidecar else "",
                "engine": engine,
                "engineName": os.path.basename(engine) if engine else "",
                "model": _holodeck_model(engine) if engine else "",
                "models": {name: _holodeck_model(name)
                           for name in _HOLODECK_ENGINES}}

    def holodeck_overlay(self, board):
        """Additively stamp `meta.holodeck` while any program is mid-turn.

        S128 (FL-002), off-deck half. `board.py` had no holodeck awareness at
        all — grep for `holo` returned nothing — so the surface a captain is
        actually looking at while he waits could say nothing about the program
        he left running. This is `align_overlay`'s shape and `align_overlay`'s
        discipline: in-memory only, never raises into the response, and a board
        with nothing in flight is returned byte-for-byte unchanged.

        It deliberately does NOT move `adapter.fingerprint()`, so it drives no
        SSE push — the band picks it up on the board's own next read, which is
        the right cost for an indicator (an in-flight turn is minutes long).

        A read-only / github build constructs the daemon with actions=None and
        holds no sessions, so this is never reached there.
        """
        if not isinstance(board, dict):
            return board
        meta = board.get("meta")
        if not isinstance(meta, dict):
            return board
        with self._holodeck_lock:
            items = list(self._holodeck.items())
        working = []
        for sid, sess in items:
            fields = self._busy_fields(sess)
            if not fields:
                continue
            entry = {"sessionId": sid, "program": sess.program,
                     "room": os.path.basename(sess.program_dir)}
            entry.update(fields)
            working.append(entry)
        if not working:
            return board            # nothing in flight → an untouched board.
        working.sort(key=lambda w: w.get("busySince") or 0)
        meta["holodeck"] = {
            "count": len(working),
            "working": working,
            # ONE sentence, from the daemon, for the band control's title. The
            # band may not compose its own — a guessed spinner with invented
            # words is the readout-honesty class in a new place.
            "message": _holodeck_working_message(working),
        }
        return board

    def holodeck_state(self, sid):
        """GET /api/holodeck/<sid> — one program, with its transcript."""
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        meta = self._holodeck_meta(sid, sess)
        meta["turns"] = self._turns_payload(sess.turns)
        return meta

    # The preview route's jail. It is the ONE place daemon-served bytes come
    # from a directory a MODEL writes into, so it is written as a fence rather
    # than as a path join with a check bolted on:
    #
    #   • a NUL byte, an absolute path, a drive letter or a `..` SEGMENT is
    #     refused by inspection, before any filesystem call;
    #   • the join is then REALPATH'd and re-checked against the realpath of the
    #     program's room — which is what catches a SYMLINK inside the room
    #     pointing out of it (the check a normpath-only jail passes);
    #   • only a regular file is served, by an extension ALLOW-list, and never
    #     larger than a cap.
    #
    # The headers matter as much as the path: the mockup is model-written HTML
    # served from the daemon's OWN origin, so `server.py` sends it `nosniff` and
    # a restrictive CSP, and the iframe around it is sandboxed WITHOUT
    # `allow-same-origin` (see board.js) — which is the half that stops it
    # reaching the board's DOM or POSTing to the write API.
    _PREVIEW_TYPES = {
        ".html": "text/html; charset=utf-8",
        ".htm": "text/html; charset=utf-8",
        ".css": "text/css; charset=utf-8",
        ".js": "application/javascript; charset=utf-8",
        ".json": "application/json; charset=utf-8",
        ".md": "text/plain; charset=utf-8",
        ".txt": "text/plain; charset=utf-8",
        ".svg": "image/svg+xml",
        ".png": "image/png",
        ".jpg": "image/jpeg",
        ".jpeg": "image/jpeg",
        ".gif": "image/gif",
        ".webp": "image/webp",
    }

    def _preview_max_bytes(self):
        try:
            return max(1, int(os.environ.get(
                "LCARS_HOLODECK_PREVIEW_MAX_BYTES") or 8 * 1024 * 1024))
        except ValueError:
            return 8 * 1024 * 1024

    @staticmethod
    def _room_file_path(program_dir, rel):
        """THE JAIL, as one function — `(abs path, [segments])` or ActionError.

        S127 extracted this from `holodeck_preview` UNCHANGED (same checks, same
        order, same words) so the hand-off resolves `mockup.html`/`concept.md`
        through the very same fence rather than growing a second one beside it.
        Two jails over one directory is two chances to get it wrong, and only
        one of them would ever be the one under test.

        Existence is NOT checked here: the preview route and the hand-off answer
        a missing file with completely different sentences, and each says its
        own.
        """
        rel = rel or ""
        if "\x00" in rel:
            raise ActionError(400, "that is not a file name the holodeck can "
                                   "serve")
        # Refuse BEFORE touching the filesystem: absolute, drive-qualified, or
        # any parent-directory segment. `..` is matched as a SEGMENT, so a file
        # honestly called `..notes.md` is still servable.
        if rel.startswith("/") or rel.startswith("\\") or ":" in rel.split("/")[0]:
            raise ActionError(403, "the holodeck preview only serves files "
                                   "inside this program's own room")
        parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
        if not parts or any(p == ".." for p in parts):
            raise ActionError(403, "the holodeck preview only serves files "
                                   "inside this program's own room")
        room = os.path.realpath(program_dir)
        target = os.path.realpath(os.path.join(room, *parts))
        # The realpath re-check: a symlink inside the room that points out of it
        # normpaths clean and only shows up here.
        if target != room and not target.startswith(room + os.sep):
            raise ActionError(403, "the holodeck preview only serves files "
                                   "inside this program's own room")
        return target, parts

    def holodeck_preview(self, sid, rel):
        """GET /api/holodeck/<sid>/preview/<path> — ONE file from the room.

        Returns `{"bytes": <bytes>, "contentType": <str>, "path": <rel>}`.
        Raises ActionError with a READABLE message; never a stack, never a
        filesystem path the captain did not already know about.
        """
        with self._holodeck_lock:
            sess = self._holodeck.get(sid)
        if sess is None:
            raise ActionError(404, "no such holodeck program: %s" % sid)
        target, parts = self._room_file_path(sess.program_dir, rel)
        if not os.path.isfile(target):
            raise ActionError(404, "the holodeck has no file called %s in this "
                                   "program yet" % "/".join(parts))
        ext = os.path.splitext(target)[1].lower()
        ctype = self._PREVIEW_TYPES.get(ext)
        if ctype is None:
            raise ActionError(415, "the holodeck preview does not serve %s "
                                   "files" % (ext or "extension-less"))
        cap = self._preview_max_bytes()
        try:
            size = os.path.getsize(target)
        except OSError as exc:
            raise ActionError(404, "could not read that file: %s" % exc)
        if size > cap:
            raise ActionError(413, "that mockup is too large to preview (%d "
                                   "bytes, limit %d)" % (size, cap))
        try:
            with open(target, "rb") as fh:
                data = fh.read(cap + 1)
        except OSError as exc:
            raise ActionError(404, "could not read that file: %s" % exc)
        return {"bytes": data, "contentType": ctype, "path": "/".join(parts)}

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
            # S170 — THE DERIVATION GETS THE GRANT TOO, and the direction is
            # the safe one. Its cwd is the CAPTAIN'S REPO and the grant is the
            # program's room inside LCARS's own sidecar, so the only directory
            # `--add-dir` could make writable is one LCARS owns — never his
            # project. And it cannot make even that writable: the derivation's
            # tool surface is `view,grep,glob`, which holds no write tool at
            # all, so the grant is a READ grant in practice. Without it the
            # pass cannot open `mockup.html`, which is half of the diff.
            if mode in ("design", "derive") and grant_dir:
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

    # ── S126: one turn at a time, per program, enforced HERE ───────────────
    # The deck's `HOLO.busy` is a courtesy that only binds the tab it runs in.
    # Two overlapping `/say` on one program both spawned a worker on the SAME
    # warm session id; the second overwrote `sess.proc`, so `end` could no
    # longer stop the first and could report a settled file list about a turn
    # that was still writing. Now that every turn also commits the room, the two
    # would additionally be staging one working tree at once.
    #
    # The check and the claim are ONE operation under `_holodeck_lock` — a
    # `if busy: … ; busy = True` outside a lock is not a guard, it is a smaller
    # window.
    def _claim_turn(self, sess):
        with self._holodeck_lock:
            if sess.busy:
                raise ActionError(
                    409,
                    "this program is already working on a turn — the holodeck "
                    "runs one at a time in a room, because two turns would be "
                    "writing the same files. Nothing was lost: what you just "
                    "typed has not been sent. Wait for the reply, or press End "
                    "Program to stop the turn that is running, then say it "
                    "again.")
            # S128 (FL-002): the clock and the owner FIRST, the flag last — a
            # lock-free reader must never see `busy` without a `turn_started`.
            sess.turn_started = time.time()
            sess.turn_thread = threading.current_thread().ident
            sess.busy = True

    def _release_turn(self, sess):
        with self._holodeck_lock:
            # …and the flag first on the way down, for the same reason.
            sess.busy = False
            sess.turn_started = None
            sess.turn_thread = None

    def _sidecar_git_lock(self, sidecar):
        key = os.path.realpath(sidecar or "")
        with self._sidecar_locks_lock:
            lock = self._sidecar_locks.get(key)
            if lock is None:
                lock = threading.Lock()
                self._sidecar_locks[key] = lock
            return lock

    def _run_turn(self, sid, sess, prompt, claimed=False, image_paths=None,
                  intent=None):
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
        if not claimed:
            self._claim_turn(sess)
        sess.turn_settled.clear()
        sess.last_touched = time.time()   # S125 (D8): the list's recency clock
        try:
            return self._holodeck_turn(sid, sess, prompt,
                                       image_paths=image_paths, intent=intent)
        except ActionError:
            # The turn did not land. Mark it, so a RETRY of the same line reuses
            # this turn instead of writing the captain's words into the
            # transcript twice (round 2).
            if sess.turns:
                sess.turns[-1]["failed"] = True
            raise
        finally:
            sess.last_touched = time.time()
            sess.turn_settled.set()
            # ALWAYS, on every exit path. A claim that leaks on the error path
            # bricks the program permanently, which is the dead-end class S125's
            # N4 fix existed to close.
            self._release_turn(sess)

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

    def _holodeck_turn(self, sid, sess, prompt, image_paths=None, intent=None):
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
        # S169 (FL-014) — THE PASTED IMAGE, ON THIS TURN'S ARGV. The same
        # per-engine road `_run_worker` uses for the Align grill and the
        # Mission-Log split (S91, measured on both live CLIs), applied here
        # rather than re-derived:
        #   • copilot: native `--attachment <path>`, repeatable. It rides into
        #     the prompt WITHOUT a tool, which matters because a holodeck turn
        #     runs on a fixed `--available-tools` list with no viewer on it.
        #   • claude (and the default): the design posture already allows Read
        #     (_HOLODECK_TOOLS[("claude","design")]), so the ABS PATH is named
        #     in the prompt and claude opens it itself. No tool exception, no
        #     stdin change.
        # The paths are inside the program's room, which is also the cwd and —
        # on copilot — the ONE `--add-dir` grant, so nothing about the sandbox
        # is widened to carry them.
        image_paths = [p for p in (image_paths or []) if p]
        # S169 FIX ROUND 1 — remembered for the failure path far below. An
        # attachment is an input that BAKES INTO the warm session, so a turn
        # that carried one and died is the one shape of failure a `--resume`
        # can never recover from. See `_poisoned_note`.
        sent = list(image_paths)
        attach_args = []
        if image_paths:
            if _is_copilot(bin_):
                for p in image_paths:
                    attach_args += ["--attachment", p]
            else:
                prompt = prompt + (
                    "\n\n=== %s (the captain attached these; open them with "
                    "your Read tool as relevant) ===\n" % _attach_heading(
                        image_paths)
                    + "\n".join(image_paths))
        cmd = ([bin_, "-p", prompt]
               + self._holodeck_args(bin_, sess.mode, sess.worker_sid, opening,
                                     sess.program_dir)
               + ["--model", _holodeck_model(bin_)]
               + attach_args)
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

        # A SESSION IS "STARTED" ONLY ONCE ONE PROVABLY EXISTS (round 2). This
        # used to be set the instant `Popen` returned, which made a RETRY a
        # PERMANENT DEAD END: if the first turn died before the CLI had opened
        # its session — a bad flag, no auth, an instant crash — the next turn
        # `--resume`d an id that never existed, failed for that reason forever,
        # and the only escape was ending the program. Both real CLIs refuse to
        # resume an unknown id, so nothing could ever recover it.
        #
        # A turn PROVES a session exists by producing FILES or a CLEAN EXIT.
        #
        # A REPLY PROVES NOTHING, and round 2 counted it (fix round 3 removed
        # the `reply or`). The daemon spawns the worker with
        # `stderr=subprocess.STDOUT`, so an engine that dies at startup —
        # `Error: authentication failed`, an expired token, a rate limit, the
        # three most ordinary engine failures there are — comes back with a
        # perfectly NON-EMPTY reply and a non-zero exit. That kept the id, and
        # the RETRY TURN control the deck puts right there `--resume`d a session
        # the CLI never created: a permanent dead end, under a banner promising
        # "the chat is still running; say it again to retry". N6's own dedupe
        # rule two hundred lines above is keyed off the turn's OUTCOME for
        # exactly this reason, measured live (`boom` on stderr).
        #
        # The heuristic is wrong in BOTH directions — a worker that HAD opened
        # its session and was then killed silently re-mints and orphans a live
        # one — but RE-MINTING IS THE SAFE DIRECTION: a fresh session always
        # works, resuming a ghost never does. So the cure is to remove the
        # unreliable evidence, never to add more evidence to the "started" side.
        # Do not put `reply or` back.
        if opening:
            if changed or (proc.returncode == 0 and not timed_out):
                sess.started = True
            else:
                sess.started = False
                sess.worker_sid = str(uuid.uuid4())

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
        # S126 (#3) — the concept-doc audit. ALWAYS present on a turn payload,
        # with the outcome named, so "the daemon audits concept.md" is a state
        # the surface can render rather than a silent pass. It never writes the
        # file it is auditing: an audit that manufactures its own clean result
        # certifies nothing (and the hand-off would then carry a document no
        # human ever agreed with).
        payload["conceptAudit"] = self._concept_audit(sess, changed)
        # S169 (FL-015) — AND WHAT THE TURN DID, from the same diff. Always
        # present, so a consumer never has to guess from the file list whether
        # a turn that says nothing wrote nothing or simply did not report.
        payload["turnOutcome"] = self._turn_outcome(sess, changed, intent)
        # …AND IT IS KEPT ON THE TURN, not just returned once. MEASURED in the
        # Chrome rig on 2026-08-06: `holoRefresh()` replaces `HOLO.programs`
        # wholesale with `GET /api/holodeck`'s list, so anything the client
        # merged onto a turn from the POST response survives exactly one render
        # and is then gone. The note said "nothing was written" for about a
        # second and vanished — which is a worse surface than not saying it,
        # because whether the captain ever sees it depends on how fast his
        # daemon answered. The daemon owns the fact, so the daemon's own turn
        # list carries it (`_turns_payload`) and a refresh RESTORES it.
        #
        # The SAME dict object as the payload's, deliberately: the branches
        # below that stand the sentence down (`refused`, `no-write`) mutate one
        # object and both readers see it. Two copies is how a card and its
        # transcript start disagreeing about one turn.
        if sess.turns:
            sess.turns[-1]["turnOutcome"] = payload["turnOutcome"]
        # A STRAY CHANGE OUTRANKS EVERY OTHER OUTCOME. Even a turn that died or
        # said nothing must surface a file that changed in the captain's project.
        if strays or bad_blocks:
            payload["status"] = "refused"
            payload["refused"] = {
                "paths": strays + list(bad_blocks),
                "message": self._write_refused_message(sess, strays, bad_blocks,
                                                       warning),
            }
            # ONE VOICE PER TURN. `refused` is a whole account of its own and
            # the deck renders that branch alone; a second note beside it about
            # what did or did not get written is the two-mechanism trap this
            # round has already lost rounds to. The FACT stays on the payload —
            # only its sentence stands down.
            payload["turnOutcome"]["message"] = ""
            self._commit_turn(sess, changed, payload)
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
            self._commit_turn(sess, changed, payload)
            return payload
        # A TURN THAT COULD NOT WRITE IS NOT A GOOD TURN (fix round 1). The
        # engine answering with the complete file and an instruction to save it
        # by hand used to come back `ok`, with an empty preview and no hint that
        # anything was wrong — the captain sat looking at NOTHING ON THE
        # HOLODECK YET while the deck said the turn succeeded. It is now a
        # first-class surfaced state, and LCARS never passes on the engine's
        # suggestion that the captain save a file into his own project.
        if sess.mode == "design" and _reply_carries_an_unsaved_file(raw):
            payload["status"] = "wrote-nothing"
            payload["warning"] = {
                "kind": "no-write",
                "message": (
                    "That turn answered with the file's contents instead of "
                    "writing it, so nothing was saved and the preview has not "
                    "moved. Your program is safe — every earlier turn is "
                    "committed — and the chat is still running. LCARS will "
                    "never ask you to save a mockup into your own project by "
                    "hand; say it again and ask for the file to be written "
                    "into the program's room."),
            }
            # ONE VOICE, again: the `no-write` warning is already the account of
            # a turn that wrote nothing, and it is a better one — it says WHY.
            payload["turnOutcome"]["message"] = ""
            # The turn still HAPPENED, and the archive is the record of what
            # happened — including the turn where the engine could not write.
            self._commit_turn(sess, changed, payload)
            return payload
        # Nothing changed and nothing to keep. HOLODECK OFFLINE (D7): lead with
        # what survived, then say what happened. Reporting either of these as
        # success is how a captain waits for a mockup that is never coming.
        if proc.returncode != 0:
            # NO EXIT CODE, NO SIGNAL NUMBER (D7, round 2). Round 1 printed
            # "(claude exited -9)" in the banner — a number that answers neither
            # of the two questions a captain has and that he cannot act on. What
            # it stopped, that his work is safe, and how to try again. The
            # engine's own words are kept because they are the engine SPEAKING
            # ("connection reset by peer"), not LCARS leaking internals.
            #
            # S169 FIX ROUND 1 — IT USED TO BE `raw.splitlines()[-1]`, and
            # against a CLI with a fixed footer that could NEVER be the error.
            # See `_engine_tail`.
            tail = _engine_tail(raw)
            note = self._poisoned_note(sess, sent)
            raise ActionError(
                502, "the %s worker stopped mid-turn — your program is safe, "
                     "every earlier turn is committed, and the chat is still "
                     "running.%s%s"
                     % (os.path.basename(bin_), note,
                        ("\n\nThe last thing it printed:\n%s" % tail)
                        if tail else ""),
                # THE FACT, not the sentence. The deck's RETRY TURN reads this
                # to drop the attachment; reading the message text instead is
                # the classifier road (see `ActionError`).
                data={"sessionReset": True} if note else None)
        if not reply:
            raise ActionError(
                502, "the holodeck worker returned nothing this turn (engine=%s)"
                     " — your program is safe and the chat is still running; "
                     "say it again to retry." % os.path.basename(bin_))
        payload["status"] = "unverified" if warning else "ok"
        # A CONVERSATIONAL TURN IS STILL A TURN. It changed no file, so before
        # S126 it was committed nowhere and lived only in daemon memory — and
        # the sentence a decision was actually made in is usually one of these.
        self._commit_turn(sess, changed, payload)
        return payload

    # ── S169 FIX ROUND 1: A POISONED WARM SESSION IS NOT A DEAD END ──────────
    #
    # THE DEFECT, shipped by this session's FL-014 work and reproduced by hand
    # against live copilot on 2026-08-06. A pasted image the engine's API
    # refuses (`CAPIError: 400 Could not process image`) is BAKED INTO THE WARM
    # SESSION, because a holodeck turn `--resume`s it: every later turn then
    # died identically WITH NO ATTACHMENT AT ALL — measured, by resuming that
    # session id by hand with a plain "Say OK.". The program was permanently
    # dead, under a banner advising "say it again to retry", which could never
    # work. The only escape was deleting the program.
    #
    # THE WAY BACK ALREADY EXISTED AND WAS ONE FLAG AWAY. S126 built the warm
    # RESTART: a fresh session id, and `_replay_clause` hands the new worker the
    # whole `transcript.md` as context. That is what `holodeck_open` does for a
    # program picked up off disk, and it is exactly what a program whose session
    # has gone bad needs. Nothing new is built here — the SAME three fields the
    # restart sets are set on the live session, so the next turn is an opening
    # turn with the record replayed into it.
    #
    # WHEN. Only after a failed turn that ACTUALLY CARRIED AN ATTACHMENT — a
    # fact off this turn's argv, not a reading of the engine's output. That is
    # the one input measured to bake in, and keeping the trigger narrow keeps a
    # transient network failure from throwing away a warm session (and paying
    # for a full replay) for nothing.
    #
    # HONESTY: re-minting is the SAFE DIRECTION and the code above already says
    # so for the opening turn — "a fresh session always works, resuming a ghost
    # never does". What is lost is the engine's own memory of the chat, and the
    # transcript replaces it. Nothing on disk is touched.
    @staticmethod
    def _poisoned_note(sess, sent):
        """Re-mint a warm session an attachment may have poisoned; say so.

        Returns the sentence for the failure banner ("" when nothing changed),
        and it is the ONLY place that sentence is written — the deck renders
        the daemon's message rather than composing a second account of it.
        """
        if not sent:
            return ""
        sess.started = False
        sess.worker_sid = str(uuid.uuid4())
        sess.restarted = True
        names = _english_list([os.path.basename(p) for p in sent])
        return (" That turn sent %s, and an image the engine refuses stays in "
                "the WORKER'S conversation — every later turn would die the "
                "same way, attachment or not. So LCARS has retired that worker "
                "session; your next turn starts a FRESH one, handed the whole "
                "transcript as context, so nothing you designed is lost. Say "
                "it again WITHOUT that image, or with a different one."
                % names)

    def _commit_turn(self, sess, changed, payload):
        """Record the turn in `transcript.md`, commit the room, then RE-READ the
        commit count into the payload.

        `_holodeck_meta` runs before the commit exists, so a turn that made the
        sidecar's second commit answered `commits: 1` — the footer self-corrected
        on the next poll, which meant the payload was quietly wrong and only a
        consumer that polled ever saw the truth."""
        failed = self._append_transcript(sess, changed)
        self._sidecar_commit(sess, changed)
        payload["commits"] = self._sidecar_commit_count(sess.sidecar_dir)
        if failed:
            self._surface_transcript_failure(payload)

    # ── FIX ROUND 1a — a transcript that could NOT be written SAYS SO ───────
    def _surface_transcript_failure(self, payload):
        """The one path where "your work is on disk" is not true.

        The append stays best-effort — a filesystem hiccup must never throw
        away a mockup that landed — but best-effort is not the same as SILENT,
        and round 1 returned a flat `ok` for a turn whose conversation was
        never recorded. The captain would find that out at S127's hand-off,
        with nothing to do about it.

        It never OVERWRITES a warning that is already there (a truncated audit
        is its own fact); it appends, so both are told under one banner.
        """
        # TRUE ON EVERY PATH IT CAN REACH, including a conversational turn that
        # wrote no file at all — "this turn's mockup is saved" would be a lie
        # about one of those.
        note = ("The mockup and everything else this program has written are "
                "safe and committed, but LCARS could not append this turn's "
                "exchange to transcript.md — the written record of the "
                "conversation is missing this turn. Check the program's room "
                "is writable; saying it again will record the turn from here.")
        warn = payload.get("warning")
        if warn:
            warn["message"] = "%s %s" % (warn.get("message", "").strip(), note)
        else:
            payload["warning"] = {"kind": "transcript-unwritten",
                                  "message": note}
        # AND ON THE ONE PATH THAT OUTRANKS THE WARNING (fix round 2). `refused`
        # is a whole account of its own and the deck renders that branch ALONE,
        # so a turn that was refused AND lost its transcript said nothing about
        # the transcript — the captain would never learn his conversation was
        # not recorded. Appended for the same reason the warning is: one banner,
        # both facts, one voice.
        ref = payload.get("refused")
        if ref:
            ref["message"] = "%s %s" % (ref.get("message", "").strip(), note)
        payload["transcriptWritten"] = False
        # `refused` already outranks everything and says its own thing; every
        # other status has just claimed more than it can.
        if payload.get("status") in (None, "ok"):
            payload["status"] = "unverified"

    # ── S126 (#1): the transcript ──────────────────────────────────────────
    @staticmethod
    def _ensure_transcript(program_dir, program, engine=None):
        """Open the program's record with the NAME THE CAPTAIN TYPED — and, as
        of fix round 5, the ENGINE IT IS BEING BUILT ON.

        FIX ROUND 2, defect 4. `transcript.md`'s `# ` heading was already the
        one durable home a program's name had — it was simply written on the
        FIRST TURN, so until a turn landed the only thing on disk was the room,
        and a room is a SLUG. A restart therefore read `Ensuite Floor Picker`
        back as `ensuite floor picker`, `holodeck_open` adopted that as the
        real name, and from the next turn on it was cemented: the transcript
        header, every commit message, and the delete confirmation. Any program
        whose first turn had not landed lost its name — including one whose
        first turn DIED, the most ordinary failure this product has.

        No second source of truth is introduced: the same file, the same
        heading, the same reader (`_parse_transcript`), written at the moment
        the name exists. `_append_transcript` only writes the header when the
        file is FRESH, so the first turn appends under this one.

        ROUND 5 puts the engine here for exactly the same reason and at exactly
        the same moment. A program whose FIRST TURN DIED — the most ordinary
        failure this product has — still knows what it was opened on, and a
        restart therefore cannot re-point it at the daemon's default.

        Returns True if it could not be written.
        """
        path = os.path.join(program_dir, _TRANSCRIPT)
        try:
            # "x" — an existing record is never rewritten. A re-created name
            # ADOPTS its old room (see `_room_already_holds_work`), and that
            # room's transcript is the earlier program's own history.
            with open(path, "x") as fh:
                fh.write(_transcript_header(program, engine))
        except FileExistsError:
            # a real record already there is exactly right; anything ELSE
            # sitting on that path (a directory, say) means the room cannot
            # hold one, and saying so beats discovering it a turn later.
            return not os.path.isfile(path)
        except OSError:
            return True
        return False

    @staticmethod
    def _room_scoped_files(changed, room):
        """The turn's changed paths that belong to THIS program's room, relative.

        One rule, two readers (S169): the durable `transcript.md` line and the
        turn's published outcome. See `_append_transcript` for why the scoping
        exists at all.
        """
        files = []
        for c in (changed or []):
            rel = c["path"] if isinstance(c, dict) else str(c)
            if not rel.startswith(room + "/"):
                continue
            rel = rel[len(room) + 1:]
            if rel and rel not in files:
                files.append(rel)
        return files

    @staticmethod
    def _turns_payload(turns):
        """The `turns` list as a consumer sees it — ONE projection, five callers.

        S169: every caller used to build `[{"text", "reply"}]` inline, and the
        deck's own refresh reads this list, so anything a turn knows about
        itself that is NOT here is lost the moment the next poll lands. Adding
        the outcome to four of five copies would have been a note that appeared
        on some screens and not others.

        ADDITIVE: a turn with no outcome (every turn replayed from
        `transcript.md`, which does not record one) omits the key entirely, so
        every payload every earlier test pins is byte-identical.
        """
        out = []
        for t in (turns or []):
            row = {"text": t.get("text"), "reply": t.get("reply")}
            if t.get("turnOutcome"):
                row["turnOutcome"] = t["turnOutcome"]
            # S169 FIX ROUND 1 — and what he ATTACHED to it. Wave 3 named this
            # function as the ONE place a projection fix goes, and this is why:
            # `holoRefresh()` replaces the program list wholesale, so a chip the
            # composer put on a turn survives exactly one render. The daemon
            # owns the fact (it staged the bytes), so the daemon's turn list
            # carries it and a refresh — or a reload, or a REOPEN days later —
            # restores it.
            if t.get("attachments"):
                row["attachments"] = list(t["attachments"])
            out.append(row)
        return out

    def _turn_outcome(self, sess, changed, intent):
        """WHAT THIS TURN DID — read off the audit, never off the reply.

        S169 (FL-015), and this is the half that would have caught the defect
        when it happened. The captain asked the holodeck a question; it answered
        him AND rebuilt part of the mockup he had not asked it to touch, and
        nothing on the screen said so. The daemon ALREADY diffs the room before
        and after every turn, so "he asked, and nothing was written" is a FACT
        it can state rather than a thing anyone has to infer — and "he asked,
        and it wrote anyway" is exactly as visible, from the same two values.

        NOTHING HERE READS HIS WORDS. `intent` is his own declaration off the
        composer; `wrote` is bytes on disk. There is no classifier in this
        method and there must never be one (see `_ANSWER_THEN_STOP`).

        THE MESSAGE IS WITHHELD ON A PLAIN BUILD TURN THAT WROTE. The chat
        already prints a file chip per file, and a note that speaks on every
        turn is a note people stop reading (the `conceptAudit` lesson, same
        idiom, same reason). It speaks when a turn wrote NOTHING — the outcome
        that had no voice at all — and when a DECLARED question wrote anyway,
        which is the drift itself.
        """
        room = os.path.basename(os.path.normpath(sess.program_dir))
        files = self._room_scoped_files(changed, room)
        wrote = bool(files)
        asked = (intent == "ask")
        if sess.mode == "grounding":
            # A GROUNDING PASS IS NOT A DESIGN TURN. It has no write tool, it
            # produces `basis.md` and nothing else, and "the mockup is exactly
            # as it was" is a sentence about a mockup that does not exist yet.
            # The fact is still published; only the sentence stands down.
            message = ""
        elif wrote and asked:
            message = (
                "You marked this turn a question, and it wrote %s anyway. The "
                "design moved on a turn you did not direct — look at the "
                "preview before you build on it." % _english_list(files))
        elif wrote:
            message = ""
        elif asked:
            message = ("Answered — nothing was written. The mockup and the "
                       "concept doc are exactly as they were.")
        else:
            message = ("Nothing was written this turn. The mockup and the "
                       "concept doc are exactly as they were.")
        return {"intent": "ask" if asked else "build", "wrote": wrote,
                "files": files, "message": message}

    def _append_transcript(self, sess, changed):
        """Append THIS turn's exchange to the program's `transcript.md`.

        Called only from the paths where a turn actually LANDED. A turn that
        died raises before this, so the retry — which reuses the same pending
        turn record (S125's N6 rule) — writes the captain's line exactly once.
        A file this appended twice would be a durable version of the defect S125
        cured in memory.

        Best-effort like the commit it precedes: the design work is already on
        disk and a filesystem hiccup must never turn a good turn into an error.
        It RETURNS whether the append failed (fix round 1a) so the caller can
        say so — best-effort, but never silent.
        """
        if not sess.turns:
            return False
        turn = sess.turns[-1]
        text = turn.get("text")
        # S126 (#6) — THE FILE GETS THE PROSE. The chat keeps the trace and
        # folds it; the durable record does not carry it, because this file is
        # replayed into the next worker's prompt and handed to Align. The
        # captain's own line is never touched by anything.
        reply = _strip_tool_trace(turn.get("reply"),
                                  sess.engine or self.worker_bin)
        grounding = (sess.mode == "grounding")
        room = os.path.basename(sess.program_dir)
        # FIX ROUND 4 — ONLY THIS PROGRAM'S OWN ROOM. `changed` is a diff of
        # the WHOLE sidecar, so with two programs open at once the other
        # room's writes land in this turn's snapshot window. Measured live:
        # the Theme Switcher's record permanently read `_Files this turn:
        # command-palette/basis.md, command-palette/transcript.md,
        # concept.md, mockup.html_` — two of those are another program's.
        # Nothing on disk was wrong (the commit is scoped, `git add --
        # <room>`); the durable record simply lied about who did what. This
        # is the SAME scoping the commit already uses, so the line names
        # exactly what the commit beneath it holds.
        #
        # S169 — and it is now ONE rule, `_room_scoped_files`, because
        # `_turn_outcome` has to answer "did this turn write anything?" about
        # the same bytes this line names. Two copies of this scoping is how the
        # record and the outcome start disagreeing about one turn.
        files = self._room_scoped_files(changed, room)
        path = os.path.join(sess.program_dir, _TRANSCRIPT)
        try:
            fresh = not os.path.exists(path)
            with open(path, "a") as fh:
                if fresh:
                    fh.write(_transcript_header(sess.program,
                                                sess.engine
                                                or self.worker_bin))
                fh.write(_transcript_entry(len(sess.turns), text, reply, files,
                                           grounding=grounding,
                                           attachments=turn.get("attachments")))
        except OSError:
            return True
        return False

    # ── S126 (#3): the concept-doc audit ───────────────────────────────────
    def _concept_audit(self, sess, changed):
        """Did this turn leave the program's written half in a legible state?

        The rule is deliberately narrow, because a check that fires on every
        turn is a check people learn to ignore: a turn that CHANGED THE MOCKUP
        must leave a `concept.md` in the room WITH SOMETHING IN IT (fix round
        1a — an empty one used to pass). Whether it also changed on this
        turn is REPORTED as a fact (`updated`) and is not a failure — a colour
        tweak needs no new prose, and calling that "stale" would be noise.
        """
        room = os.path.basename(sess.program_dir)
        touched = []
        for c in (changed or []):
            rel = c["path"] if isinstance(c, dict) else str(c)
            if rel == room or rel.startswith(room + "/"):
                touched.append(rel[len(room) + 1:] if rel != room else "")
        mockup_moved = any(t.lower().endswith((".html", ".htm"))
                           for t in touched)
        updated = _CONCEPT in touched
        # FIX ROUND 1a — EXISTENCE IS TOO LOW A BAR. A zero-byte `concept.md`
        # audited `ok`, under "concept.md was updated alongside the mockup" —
        # and that file is what S127 hands to Align. `exists` still reports the
        # plain fact (the file IS there); `has_words` is what the audit judges.
        exists = False
        has_words = False
        try:
            cpath = os.path.join(sess.program_dir, _CONCEPT)
            exists = os.path.isfile(cpath)
            if exists:
                with open(cpath) as fh:
                    has_words = bool(fh.read().strip())
        except OSError:
            pass
        if sess.mode != "design":
            return {"file": _CONCEPT, "status": "not-applicable",
                    "exists": exists, "updated": False,
                    "message": "A grounding pass builds no mockup, so there is "
                               "nothing for the concept doc to describe yet."}
        if not mockup_moved:
            return {"file": _CONCEPT, "status": "not-applicable",
                    "exists": exists, "updated": updated,
                    "message": "The mockup did not change this turn."}
        if not has_words:
            # ONE STATUS FOR BOTH, on purpose: an empty file and no file are
            # the same thing to the captain and to Align, and `missing` is the
            # only status the deck renders the notice for. The MESSAGE tells
            # the two apart, because "still has no concept.md" would be a lie
            # about a file he can see in the room.
            return {
                "file": _CONCEPT, "status": "missing", "exists": exists,
                "empty": exists, "updated": False,
                "message": (
                    ("The mockup changed and this program's concept.md is "
                     "empty — there is a file in the room with nothing in it."
                     if exists else
                     "The mockup changed but this program still has no "
                     "concept.md.")
                    + " That file is the written half of the design — "
                    "the problem, the decisions, the open questions, what it "
                    "must do, and the declared flow of its screens — and it is "
                    "what a Mission is handed at the end. LCARS will not write "
                    "it for you: ask for it in the chat and the holodeck will "
                    "keep it current from here."),
            }
        return {
            "file": _CONCEPT, "status": "ok", "exists": True, "empty": False,
            "updated": updated,
            "message": ("concept.md was updated alongside the mockup."
                        if updated else
                        "concept.md is in the program's room; this turn did "
                        "not change it."),
        }

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
        # S126 (#6) — the engine's tool trace is plumbing, and this file is the
        # design's foundation: it is linked from D12's chip, read by the
        # captain, and quoted into every design turn's prompt.
        #
        # `or reply` is the one place the strip YIELDS. A basis the recognizer
        # emptied is far likelier to be a misclassification than a grounding
        # pass that genuinely reported nothing, and an empty `basis.md` breaks
        # the chip and hands the design turns nothing at all. A wrong call must
        # cost a click, never the content.
        body = _strip_tool_trace(reply, sess.engine or self.worker_bin) or reply
        try:
            with open(path, "w") as fh:
                fh.write("# Design basis — %s\n\n"
                         "What the holodeck found by reading %s, read-only. "
                         "Correct anything wrong here: it is what the mockup "
                         "is built from.\n\n%s\n"
                         % (sess.program, sess.target_repo, body))
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
                # NEVER AN INSTRUCTION THE SURFACE CANNOT FOLLOW (fix round 1),
                # AND NEVER ONE THAT HIDES THE EASY ROAD (S127). Fix round 1
                # made this name the daemon restart, because the New Program
                # dialog had one field — a name — and no engine control at all.
                # S127 gave it an engine picker, so "stop it and restart the
                # viewscreen" became the WRONG first instruction: it sends the
                # captain to kill his board for something a control in front of
                # him now does. The picker leads; the daemon-wide default is
                # kept second, because it is still how a program gets an engine
                # without anyone picking one (a reopened program, for instance,
                # has no dialog to pick in).
                502, "the holodeck has no engine to run this on — nothing was "
                "picked for it and this viewscreen has no default engine "
                "($LCARS_WORKER_BIN is unset). Open it from ⬡ New Program and "
                "choose one in the engine picker. To give every program on this "
                "viewscreen the same engine without picking, restart it with "
                "one: `LCARS_WORKER_BIN=copilot lcars viewscreen --open`.")
        if not shutil.which(bin_):
            raise ActionError(
                502, "the holodeck cannot run %s — it is not an executable on "
                "this machine. Check the engine you picked, or the daemon's "
                "$LCARS_WORKER_BIN." % bin_)
        return bin_

    @staticmethod
    def _recorded_engine(program_dir):
        """The engine THIS PROGRAM'S OWN RECORD names, or "" if it names none.

        One read of the one file. A record written before fix round 5 has no
        engine line, and "" means UNKNOWN — never the default, which is the
        substitution the whole bug was made of."""
        try:
            with open(os.path.join(program_dir, _TRANSCRIPT)) as fh:
                return _parse_transcript(fh.read())[2]
        except (OSError, ValueError):
            return ""

    def _program_engine(self, program_dir, engine=None):
        """THE RESOLUTION RULE, in one sentence: an engine the caller asked for
        outright wins; otherwise the engine RECORDED for this program; and only
        when neither exists does the daemon's own default apply.

        Returns (bin, recorded) — `recorded` says the answer came out of the
        program's record, which is the only case the surface may describe as
        what the program was DESIGNED on.
        """
        asked = (engine or "").strip()
        if asked:
            return self._resolve_holodeck_engine(asked), False
        found = self._recorded_engine(program_dir)
        if found:
            # NEVER QUIETLY MOVED. Falling back to the default here is the bug
            # itself, so an engine that is no longer on this machine is said
            # out loud with the two things that actually fix it.
            if not shutil.which(found):
                raise ActionError(
                    502, "this program's own record says it was designed on %s,"
                    " and that is not an executable on this machine. LCARS will"
                    " not quietly move a program to a different engine — "
                    "install it, or reopen the program naming the engine you "
                    "want it to run on." % found)
            return found, True
        return self._resolve_holodeck_engine(None), False

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
        """Commit this turn. BEST-EFFORT by design: the captain's design work is
        already on disk, and a git hiccup must never turn a good turn into an
        error. It is what makes "every turn is committed" (D7) true.

        S126 changed two things here.

        1. NO EARLY RETURN ON AN EMPTY FILE LIST. A turn that only answered a
           question changed nothing the worker wrote — but it still appended the
           exchange to `transcript.md`, and it is usually the turn a decision
           was actually made in. Committing only file-writing turns left the
           conversation out of the archive that exists to hold it.

        2. THE MESSAGE IS THE TURN'S SUMMARY, not `turn 3`. `git log --oneline`
           over the sidecar is meant to BE the program's audit trail; a column
           of serial numbers is not one.

        S126 FIX ROUND 3 — LEAVE THE CAPTAIN'S FILES ALONE (his ruling). The
        staging was `git add -A` over the WHOLE sidecar, so a turn commit read
        `holodeck(Ensuite Floor Picker): turn 4 — Tighten it.` over a
        `notes/roadmap.md` he had dropped in the archive and over a SECOND
        program's `transcript.md`. The round's headline claim is that this log
        IS the program's audit trail; a log that attributes his own files to a
        design turn he never made is not one. Staging is the program's OWN ROOM
        and nothing else: his files stay untracked, in his repo, and he commits
        them when he wants.

        Serialised per sidecar: `add` + `commit` share one index, and two
        programs landing together raced on `index.lock` — a failure this method
        swallows by design, so the lost commit was silent.
        """
        n = max(1, len(sess.turns))
        turn = sess.turns[-1] if sess.turns else {}
        summary = _turn_summary(turn.get("text"),
                                grounding=(sess.mode == "grounding"))
        room = os.path.basename(os.path.normpath(sess.program_dir))
        try:
            with self._sidecar_git_lock(sess.sidecar_dir):
                self._git(sess.sidecar_dir, ["add", "-A", "--", room],
                          "stage the turn")
                self._git(sess.sidecar_dir,
                          ["commit", "-q", "--no-gpg-sign", "-m",
                           "holodeck(%s): turn %d — %s"
                           % (sess.program, n, summary)],
                          "commit the turn")
        except ActionError:
            pass

    # ── the turn prompt ────────────────────────────────────────────────────
    @staticmethod
    def _intent_clause(intent):
        """The one turn-shape declaration a design prompt carries (S169/FL-015).

        `intent` is the captain's OWN declaration off the composer, or None. It
        is never derived from his words — see the `_ANSWER_THEN_STOP` header for
        why a classifier is the one thing this must not be. Two branches, one
        home, so the opening envelope and the continuation can never carry two
        different readings of the same rule (S128's cross-language wording
        drift, applied to two prompts in one function).
        """
        return _ASK_DECLARED if intent == "ask" else _ANSWER_THEN_STOP

    def _build_holodeck_prompt(self, sess, text=None, opening=True,
                               intent=None):
        """Assemble ONE turn's prompt.

        OPENING turn: the full envelope (who you are, where you may write, the
        output contract). CONTINUATION: just what the captain said — the warm
        session already holds the rest, which is the whole cost win.

        S169 (FL-015) — BOTH shapes now carry the turn-shape declaration
        (`_intent_clause`), because both were the defect: the continuation said
        "Make the change" unconditionally, and the opening envelope frames the
        whole session as a build. A grounding turn is untouched — it has no
        write tool at all, so answer-then-stop is already the only thing it can
        do."""
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
            # S169 (FL-015) — WAS: "Make the change, then reply in a sentence or
            # two saying what you did." Unconditional, on every follow-up turn,
            # before the envelope was even considered. The declaration comes
            # FIRST and the build instruction is now conditional on his turn
            # actually being a direction.
            return ("%s\n\nThe captain says: %s\n\nIf that is a direction, make "
                    "the change and then reply in a sentence or two saying what "
                    "you did." % (self._intent_clause(intent), text or ""))
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
            "%s\n\n"
            "REPLY SHORT ON A BUILD TURN: a sentence or two on what you changed "
            "and what you want decided next. The captain reads the mockup, not "
            "your prose. (This does not apply to an answer — see below.)\n\n"
            "%s"
            "%s%s\n\n"
            "The captain says: %s" % (sess.program, sess.program_dir,
                                      _CONCEPT_CONTRACT,
                                      self._intent_clause(intent),
                                      self._basis_clause(sess),
                                      self._replay_clause(sess),
                                      text or "Start us off."))

    def _replay_clause(self, sess):
        """S126 (#2) — what a WARM RESTART hands its fresh worker.

        A rebuilt program's worker is not the one that built it and has no
        memory of a single turn, so the opening prompt carries the record. It is
        BOUNDED and says so when it truncates: a design chat that ran all
        afternoon must not turn its next opening turn into a prompt the size of
        a stylesheet, and silently dropping the front of a transcript would be
        the archive lying about itself.
        """
        if not sess.restarted:
            return ""
        # S172 — WHICH ROAD THIS ROOM CAME IN ON. A duplicate is handed the
        # same transcript by the same mechanism, and must be told something
        # completely different about it; see `_duplicate_replay_clause`.
        origin = self._origin_record(sess.program_dir)
        path = os.path.join(sess.program_dir, _TRANSCRIPT)
        try:
            with open(path) as fh:
                body = fh.read()
        except OSError:
            body = ""
        if not body.strip():
            if origin:
                return self._duplicate_replay_clause(sess, origin, "", "")
            return ("\n\nYOU ARE PICKING THIS PROGRAM BACK UP. It already has a "
                    "room on disk (the files beside you) but no transcript, so "
                    "there is no conversation to read — look at what is there "
                    "and carry on from it. You are a FRESH session: nothing "
                    "about this program is in your memory.")
        cap = self._replay_cap()
        cut = ""
        if len(body) > cap:
            body = body[-cap:]
            cut = ("\n\n(Only the most recent part of the transcript is quoted "
                   "here — read `transcript.md` in your working directory for "
                   "all of it.)")
        if origin:
            return self._duplicate_replay_clause(sess, origin, body, cut)
        return ("\n\nWHAT HAS HAPPENED SO FAR — you are picking this program "
                "back up, and you are a FRESH session: none of this is in your "
                "memory, so read it. The whole record is `transcript.md` in "
                "your working directory, and every file it mentions is already "
                "on disk beside you. Carry on from where it stops; do not start "
                "the mockup over.%s\n\n%s" % (cut, body.strip()))

    def _duplicate_replay_clause(self, sess, origin, body, cut):
        """S172, TRAP 3 — a DUPLICATE's history is CONTEXT, never a contract.

        `_replay_clause`'s reopen sentence — "carry on from where it stops; do
        not start the mockup over" — is exactly right for a program being picked
        back up and ACTIVELY WRONG here. The captain duplicated this design
        because he wants to change something about it, and a worker handed the
        old conversation with the reopen framing will treat what is in it as
        settled and argue with him out of his own transcript.

        So the duplicate gets its own sentence, and it says the three things
        only this road knows: this is a NEW program, nothing in the record binds
        it, and the original is untouched.

        IT DOES NOT SPEAK ABOUT `basis.md` (fix round 1, D2). It used to, at the
        tail of this paragraph — and `_basis_clause` was up at the top of the
        same prompt telling the worker the opposite in the imperative. The
        inherited-grounding caution belongs in the slot that talks about the
        grounding, and it is said there, once.
        """
        mission = (origin.get("missionId") or "").strip()
        filed = ("It was filed as mission `%s`, so it is already being built "
                 "somewhere else." % mission) if mission else \
                "It was never filed."
        record = ("\n\n%s" % body.strip()) if body.strip() else (
            "\n\n(There is no conversation in the record — look at the files "
            "beside you instead.)")
        return ("\n\nTHIS IS A NEW PROGRAM CONTINUING AN OLD DESIGN. It was "
                "duplicated from the program “%s” (room `%s`). %s That program "
                "is UNTOUCHED and stays exactly as it was handed over — nothing "
                "you do here changes it.\n\nWhat follows is THAT program's "
                "conversation, carried over so you can see why the design looks "
                "the way it does. You are a FRESH session and none of it is in "
                "your memory, so read it — but NOTHING IN IT IS BINDING. The "
                "captain duplicated this design precisely because he wants to "
                "change something, so where what he asks for now contradicts a "
                "decision in the history, WHAT HE ASKS FOR NOW WINS: do not "
                "argue from the record and do not tell him something was "
                "already settled.%s%s"
                % (origin.get("program") or "the original",
                   origin.get("room") or "", filed, cut, record))

    @staticmethod
    def _replay_cap():
        try:
            return max(500, int(os.environ.get(
                "LCARS_HOLODECK_REPLAY_MAX_CHARS") or 16000))
        except ValueError:
            return 16000

    def _basis_clause(self, sess):
        """The grounded program's opening design turn must be TOLD what the
        grounding pass found — otherwise the read-only look at the captain's
        project buys nothing, because it happened in a session this one never
        resumes. The basis is on disk in the room; the prompt points at it by
        name rather than inlining it, so a long basis costs one Read, not one
        prompt the size of a stylesheet.

        FIX ROUND 1 (D2) — AND ON A DUPLICATE THIS SLOT SAID THE OPPOSITE. The
        clause below is an imperative claim about the captain's project AS IT
        IS; a duplicate's basis is a record of the project as it WAS, because he
        duplicates a design once its mission has landed — exactly when the app
        it was read from has moved. The room, the deck and the file itself all
        said so, and this — the FIRST and loudest thing the worker read about
        `basis.md` — did not; the caution that followed a thousand characters
        later lost the argument on position. So a duplicated room gets this
        slot, and there is ONE voice in it.
        """
        if not self._basis_file(sess):
            return ""
        origin = self._origin_record(sess.program_dir)
        if origin:
            return ("\n\nABOUT THE GROUNDING: `basis.md`, in your working "
                    "directory, is INHERITED and MAY BE STALE. It is what "
                    "LCARS read out of the captain's real project for “%s”, "
                    "the program this one was duplicated from — NOT a fresh "
                    "look at that project. If that design has been built "
                    "since, the app has moved and the colour tokens, type "
                    "scale, spacing and component shapes in it describe what "
                    "it USED to be. Read it for what this design was built to, "
                    "and treat it as history: check anything you build on it "
                    "against the project as it is now, and say what you "
                    "assumed rather than asserting a token is still there."
                    % (origin.get("program") or "the original program"))
        if not sess.grounded:
            return ""
        return ("\n\nSTART FROM THE GROUNDING: `basis.md`, in your working "
                "directory, is what LCARS read out of the captain's real "
                "project — its actual colour tokens, type scale, spacing and "
                "component shapes. READ IT FIRST and build to it, so this "
                "arrives looking like it belongs in that product. Where the "
                "basis says something was NOT found, say what you chose "
                "instead rather than inventing a token it does not have.")

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
        # S180: respond.sh now re-enters the driver itself when it clears a gate
        # (the CLI captain had to type a second command for every answer). This
        # call is BLOCKING, and the board dispatches its own DETACHED driver a few
        # lines below, so letting the script resume here would hang the HTTP
        # handler for the length of a whole run AND race that spawn. Suppress it;
        # the "& Resume" half of this endpoint is unchanged.
        self._run("respond", ["answer", "--mission", mid, "--answer", answer],
                  env_extra={"LCARS_RESPOND_RESUME": "0"})
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
        """S177: open the ONE repo-scan scope, then do the real work.
    
        Every `_linked_children` beneath this call — including the ones
        reached through the `_waiting_children` recursion — answers from a
        single snapshot instead of re-walking the missions dir. Purely a
        cost change: the facts published are identical.
        """
        with self._log_scan_scope():
            return self._log_overlay_body(board)

    def _log_overlay_body(self, board):
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
        """S177: open the ONE repo-scan scope, then do the real work.
    
        Every `_linked_children` beneath this call — including the ones
        reached through the `_waiting_children` recursion — answers from a
        single snapshot instead of re-walking the missions dir. Purely a
        cost change: the facts published are identical.
        """
        with self._log_scan_scope():
            return self._log_overlay_mission_body(mission)

    def _log_overlay_mission_body(self, mission):
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
            # S178 — SAME status, SAME message, SAME raise. The only addition is
            # that the caller can now read the skill's exit code off the error
            # instead of having to match its prose (S165: key the filter off
            # EXIT STATUS, not the refusal wording). Every existing caller that
            # ignores the attribute is byte-identical.
            err = ActionError(
                502, "skill '%s' exited %d: %s" % (key, proc.returncode, out))
            err.skill_exit = proc.returncode
            raise err
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

    # ── S191: ADOPT A REMOTE MISSION ────────────────────────────────────────
    def adopt(self, issue, engine=None, number_one=None):
        """Rebuild the mission on issue `issue` here — `lcars adopt <n>`.

        DISPATCH ONLY. Every rule about WHEN an adopt is allowed lives in
        adopt.sh: the stage gate (the two ENDS — align and verify), the handoff
        envelope schema gate, the claim, the branch fetch, the PR resolution and
        the four honest refusals. Re-deciding any of them here would be a second
        implementation of the same verdict, which is the S168 scar this project
        already paid for once (ADR-002).

        NOT OWNER-LOCKED, deliberately, and this is the one write endpoint that
        is not. Adopting is how a captain TAKES command of a mission on this
        laptop; refusing it because he does not yet hold it would lock the door
        from the inside. adopt.sh does the claiming, and every verb that follows
        it (run / respond / approve / feedback) is locked as it was.

        BLOCKING, like `file`: adopt reads the issue and fetches a branch, which
        is seconds, and the answer the captain needs is whether it worked. A
        fire-and-forget adopt would flip the card and then fail in a spawn log.

        The argument is an ISSUE NUMBER, because that is what a remote card is
        identified by (there is no local mission id yet — minting one is exactly
        what adopt refuses to do). Validated here rather than trusted: it is
        about to become a command-line argument.
        """
        n = str(issue if issue is not None else "").strip().lstrip("#")
        if not n.isdigit():
            raise ActionError(
                400, "adopt needs the mission's GitHub issue NUMBER; got %r"
                     % (issue,))
        # S197 — THE ENGINE THE CAPTAIN PICKED, on its way to adopt.sh's own
        # `--engine`.
        #
        # WHY THIS PARAMETER EXISTS AT ALL. `lcars adopt` at a terminal ASKS
        # which CLI should drive the mission here (the captain's ruling of
        # 2026-09-09: ask and convert, because a laptop may only have one CLI
        # installed). The daemon has no tty, so adopt.sh took its documented
        # non-interactive path and REFUSED on exactly the machine the feature
        # exists for. The board could not ask because it had no way to answer.
        # Now it does: the picker asks, and the answer arrives here.
        #
        # PASSED ONLY WHEN IT IS A CHANGE (the board sends nothing when the
        # captain took the default). An adopt with no `engine` in the body is
        # byte-for-byte the dispatch this daemon has always made — same argv,
        # same non-interactive path, same `note()` when the repo config
        # disagrees. Doing nothing reproduces today's behaviour exactly.
        #
        # AND IT TRAVELS AS A CHOICE, NOT AS A CONVERSION (S197). adopt.sh
        # records three provenances and the card renders all three: `adopt-kept`
        # ("mission pin · kept at adopt"), `adopt-converted` ("converted at
        # adopt") and `adopt-chosen` ("chosen at adopt"). `--engine` alone lands
        # in the first two — both of which are LCARS's sentences for something
        # nobody was asked about — so a captain who stood at the viewscreen,
        # read that copilot is not on this laptop and picked claude ON PURPOSE
        # was told he had been converted. `--engine-source chosen` carries the
        # one fact only this caller knows: a human answered the picker. It is
        # RECORDED rather than inferred because it cannot be inferred — on a
        # two-CLI laptop with no config disagreement adopt never prompts, and
        # `--engine claude` on a claude mission is byte-identical whether a
        # human chose it or not.
        args = ["--issue", n]
        eng = self._adopt_engine(engine)
        if eng:
            args += ["--engine", eng, "--engine-source", "chosen"]
        # S201 — THE CAPTAIN'S ANSWER TO ADOPT'S VERIFY QUESTION, from a surface
        # with no tty. `lcars adopt` at a terminal asks "engage Number One on
        # this mission now?"; the daemon cannot be asked, so adopt.sh takes its
        # documented non-interactive path and answers `no`. The board's picker
        # asks instead, and the answer arrives here. ABSENT means the captain
        # left the box alone, and an absent flag dispatches the exact argv this
        # daemon has always dispatched.
        if number_one is not None:
            args += ["--number-one", "yes" if number_one else "no"]
        try:
            proc = self._run("adopt", args)
        except ActionError as exc:
            raise _adopt_refusal(exc)
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        # The board refreshes itself off the next poll — the adopted mission is
        # now a LOCAL mission dir, so the overlay stops drawing its remote card
        # and the local card takes its place. Nothing to reconcile here.
        #
        # S196 A4 — THE WARNINGS TRAVEL. adopt succeeds and still has things the
        # captain must know: no `testCommand` could be detected, attachments could
        # not follow the issue, no open PR resolves at Verify, the repo's config
        # prefers a different engine. Every one of those went into adopt's stdout
        # and the board threw the whole string away, showing only "Adopted #34 —
        # it is a local mission now." A warning nobody sees is not a warning.
        #
        # They are lifted by adopt's OWN marker, not by prose-matching: `note()`
        # in adopt.sh emits exactly `  ⚠ <sentence>` and nothing else in the verb
        # uses that glyph at the head of a line. Same discipline as
        # _ADOPT_REFUSAL_BANNER above — one script, one marker, no classifier.
        return {"adopted": int(n), "output": out,
                "warnings": _adopt_warnings(out)}

    @staticmethod
    def _adopt_engine(engine):
        """The requested engine, validated, or "" for "the board sent none".

        VALIDATED HERE RATHER THAN TRUSTED, on the same reasoning the issue
        number two lines up carries: it is about to become a command-line
        argument. The shape is the one `lcars_engine_bin` accepts — a bare
        engine id, or a custom binary NAME — so nothing that could be read as a
        flag, a path or a shell fragment survives.

        NOT AN ALLOW-LIST OF `claude`/`copilot`, deliberately. adopt.sh checks
        the engine against THIS MACHINE through the shared detector and refuses
        with its own sentence if it is not here; a second, narrower gate in
        Python would be a rule in two places (ADR-002) and the two would drift
        the day a third engine lands.
        """
        eng = str(engine if engine is not None else "").strip()
        if not eng:
            return ""
        # A LEADING DASH IS A FLAG, NOT A NAME, and it is checked first: the
        # character class below happily admits `--help`, which would have
        # travelled as a second option rather than as `--engine`'s value. Found
        # by the test that tries it.
        if (eng.startswith("-") or len(eng) > 64
                or not all(c.isalnum() or c in "-_." for c in eng)):
            raise ActionError(
                400, "adopt: %r is not an engine name" % (engine,))
        return eng

    # ── S190: THE LIGHT LOCK, SERVER-SIDE ───────────────────────────────────
    def owner_lock_reason(self, mid):
        """One plain line when this mission belongs to SOMEONE ELSE, else None.

        THE POINT OF THIS EXISTING AT ALL. S189 already refuses at the CLI, and
        every write here dispatches a skill — so why check twice? Because the
        long verbs are dispatched DETACHED and fire-and-forget (see `_spawn`):
        the child's refusal lands in a spawn log nobody is reading, seconds after
        the board has already flipped the card to "starting" and the captain has
        walked away. A refusal has to happen AT THE DOOR, with a status code, or
        it is not a refusal the operator will ever see. And a disabled button is
        not a lock: anyone with the port can POST straight past the DOM.

        IT SHELLS, IT DOES NOT DECIDE. The verdict, the posture and the sentence
        all come from `ownership.sh lock-reason` — the same code path
        `lcars run` consults — so there is exactly one implementation of "whose
        mission is this?" in LCARS (ADR-002; the S168 scar).

        LIVE, EVERY TIME. It does NOT read the board's published-owner file: that
        is a display cache, and a captain who has just reassigned a mission to
        himself on GitHub must be able to act on his very next click. As a side
        effect the shell-out republishes that cache, so the board catches up too.

        EVERY UNCERTAIN CASE ANSWERS None (allowed):
          * no `ownership` script wired            → the pre-S190 daemon
          * the mission carries no forge issue     → nobody can own it
          * gh absent, unauthenticated, unreachable→ ownership.sh exits non-zero
          * an unassigned mission                  → "nobody" is not "somebody"
          * an unresolvable identity               → we may not name the captain
                                                     as someone else
        A false lock is strictly worse than the thing the lock prevents.
        """
        script = self.scripts.get("ownership")
        if not script:
            return None
        issue = _read_json_key(
            os.path.join(self._missions_dir(), mid, "state.json"), "githubIssue")
        if isinstance(issue, str) and issue.isdigit():
            issue = int(issue)
        if not isinstance(issue, int):
            return None
        env = dict(os.environ)
        if self.gh_bin:
            env["LCARS_GH_BIN"] = self.gh_bin
        try:
            proc = subprocess.run(
                ["bash", script, "lock-reason", str(issue)],
                cwd=self.repo_root, env=env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=20)
        except Exception:
            # Script missing, un-runnable, or it hung past the bound. A forge we
            # cannot reach must never stand between the captain and his own work.
            return None
        if proc.returncode != 0:
            return None
        line = (proc.stdout or b"").decode("utf-8", "replace").strip()
        return line or None

    # ── S201: THE REPO TOGGLE AND THE STAND-DOWN ────────────────────────────
    def xo_on(self, engine=None):
        """`lcars xo on [--engine E]` — Number One takes the conn in this repo.

        DISPATCH ONLY, and BLOCKING, like `adopt`. Every rule about WHICH
        engines exist, whether the one asked for is on this machine, what the
        config block looks like and how it is written lives in `xo.sh`
        (ADR-002). Re-deciding any of it here would be a second implementation
        of the same verdict — the S168 scar this project already paid for once.

        THE ENGINE IS ALWAYS SENT. The CLI REFUSES a non-tty `on` with no
        `--engine` on purpose (the adopt precedent: picking an engine in
        silence is the defect), and the daemon has no tty — so the board's
        picker asks and the answer arrives here. A body with no engine is that
        same refusal, raised at the door where the captain can see it, rather
        than in a spawn log.
        """
        eng = self._adopt_engine(engine)
        if not eng:
            raise ActionError(
                400, "which engine should Number One use? Pick one at the "
                     "board's picker, or run `lcars xo on --engine <engine>`.")
        proc = self._run("xo", ["on", "--engine", eng])
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        return {"enabled": True, "engine": eng, "output": out}

    def xo_off(self, mid=None):
        """`lcars xo off [<mission>]` — hand the conn back.

        With no mission: the repo goes OFF and every engaged mission is stood
        down. With one: that mission alone, and it is validated against this
        laptop first — `mid` is about to become a command-line argument, and a
        mission that is not here is a 404 rather than a shell-out that fails.

        NEVER LOCKED, by anything. Standing Number One down is how the captain
        takes the conn back; refusing it because Number One holds the mission
        would lock the door from the inside — the same reasoning `adopt` sits
        outside `_OWNER_LOCKED_VERBS` on.
        """
        args = ["off"]
        if mid is not None:
            name = str(mid).strip()
            if (not name or name.startswith("-") or "/" in name
                    or name in (".", "..")):
                raise ActionError(400, "xo off: %r is not a mission id" % (mid,))
            if not os.path.isfile(os.path.join(self._missions_dir(), name,
                                               "state.json")):
                raise ActionError(404, "no such mission: %s" % name)
            args.append(name)
        proc = self._run("xo", args)
        out = (proc.stdout or b"").decode("utf-8", "replace").strip()
        return {"mission": mid, "output": out}

    def xo_seen(self):
        """`POST /api/xo/seen` — the board's ✓ Seen, the SAME mark the CLI's
        `lcars xo report --seen` writes (S205).

        DISPATCH ONLY (ADR-002): `xo-report.py` already owns the one file this
        writes (`.git/lcars/xo-seen.json`) — this only shells the verb that
        writes it. The daemon re-reads the fresh report straight off the
        adapter afterward (server.py), so a POST answers with what actually
        changed rather than this dispatch's own stdout.
        """
        self._run("xo", ["report", "--all", "--seen"])
        return {"seen": True}

    # ── S201: THE ENGAGED LOCK, SERVER-SIDE ─────────────────────────────────
    def xo_lock_reason(self, mid):
        """One plain line when Number One holds this mission, else None.

        The sibling of `owner_lock_reason`, and it works the same way: IT
        SHELLS, IT DOES NOT DECIDE. The verdict, the posture and the sentence
        all come from `ownership.sh xo-lock-reason` — the same op the CLI verbs
        consult through the sourced library — so there is exactly one
        implementation of "is Number One engaged here?" (ADR-002).

        WHAT IS PASSED IS THE MISSION DIRECTORY, not an issue number.
        Engagement is a LOCAL fact recorded in the mission's own state.json;
        the forge knows nothing about it. Handing over the resolved path also
        keeps the shell-out free of any `git rev-parse` of its own, so the
        answer cannot change with the daemon's working directory.

        EVERY UNCERTAIN CASE ANSWERS None (allowed):
          * no `ownership` script wired            → the pre-S201 daemon
          * no mission directory on this laptop    → nothing to be engaged on
          * an unreadable or keyless state.json    → nothing recorded
          * the script missing, un-runnable, slow  → a guard must not refuse
        A false lock is strictly worse than the thing the lock prevents.
        """
        script = self.scripts.get("ownership")
        if not script:
            return None
        mission_dir = os.path.join(self._missions_dir(), mid)
        if not os.path.isfile(os.path.join(mission_dir, "state.json")):
            return None
        try:
            proc = subprocess.run(
                ["bash", script, "xo-lock-reason", mission_dir],
                cwd=self.repo_root, env=dict(os.environ),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=20)
        except Exception:
            return None
        if proc.returncode != 0:
            return None
        line = (proc.stdout or b"").decode("utf-8", "replace").strip()
        return line or None

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
    @staticmethod
    def _decode_image(data_b64, name=""):
        """The base64 → bytes step, and the ONE sentence said when it is not
        base64. Extracted (S169) so the holodeck's room staging below and the
        scratch staging above cannot drift into two different refusals for the
        same bad paste.

        S169 FIX ROUND 1 — …AND THE ONE PLACE A BROKEN PICTURE IS STOPPED.
        Every road that stages a pasted image already comes through here, so the
        integrity check goes here rather than beside one caller: the holodeck
        composer, the Align grill and the Mission Log all get the same refusal,
        and the ONE poisoned-session defect cannot come back through the door
        nobody guarded. See `_image_defect` for what it checks and — just as
        important — what it does not claim.
        """
        try:
            raw = base64.b64decode((data_b64 or "").encode("ascii"),
                                   validate=True)
        except (binascii.Error, ValueError, UnicodeEncodeError):
            raise ActionError(400, "image data is not valid base64")
        defect = _image_defect(raw)
        if defect:
            raise ActionError(
                400, "%s is damaged, so LCARS did not send it: %s. Nothing was "
                     "sent and nothing has changed — say it again with a good "
                     "one. Take the screenshot again, or drag the image file "
                     "in instead of pasting it."
                     % (str(name).strip() or "that pasted image", defect))
        return raw

    def _stage_image(self, content_type, data_b64):
        """Decode one base64 image and stage it in `_scratch_dir()`; return the
        abs path. The suffix follows the (already allow-listed) content type so
        the worker's image loader recognises it. Caller owns cleanup."""
        suffix = _IMAGE_SUFFIX.get((content_type or "").strip().lower(), ".png")
        raw = self._decode_image(data_b64)
        fd, path = tempfile.mkstemp(prefix="lcars-img-", suffix=suffix,
                                    dir=self._scratch_dir())
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw)
        return path

    # ── S169 (FL-014): staging a pasted image INSIDE the program's room ───────
    # NOT `_stage_image`'s scratch dir, and the difference is the point. The
    # Align grill's images are staged under `.git/lcars/tmp` and REAPED when the
    # grill ends, because the durable copy of anything that mattered is made by
    # `file.sh` into the mission's `attachments/`. A holodeck program has no
    # mission to copy into and is itself the archive: the captain reopens a room
    # weeks later, and the reference screenshot a mockup was built FROM is part
    # of that design record.
    #
    # So the image goes in `<room>/attachments/` — the holodeck's equivalent of
    # a mission's `attachments/` (S92) — where three things are already true and
    # none had to be invented:
    #   • the room is committed after every turn (`git add -A -- <room>`), so
    #     the paste is in the archive's history without a second code path;
    #   • the room is the turn's cwd AND copilot's only `--add-dir` grant, so
    #     the worker can reach the file without widening the sandbox;
    #   • `_room_file_path` — the preview route's jail — resolves the path, so a
    #     name from the browser is fenced by the SAME check that fences every
    #     other filename the deck can influence, rather than by a second one.
    def _stage_room_images(self, sess, images):
        """Write this turn's pasted images into the program's room; return the
        abs paths in paste order. No images ⇒ nothing created and []."""
        images = [i for i in (images or [])
                  if isinstance(i, dict) and i.get("dataB64")]
        if not images:
            return []
        room = os.path.join(sess.program_dir, _ROOM_ATTACHMENTS)
        try:
            os.makedirs(room, exist_ok=True)
        except OSError as exc:
            raise ActionError(
                502, "the pasted image could not be saved into this program's "
                "room (%s): %s. Nothing was sent — say it again once that "
                "directory is writable." % (room, exc))
        out = []
        for img in images:
            name = _attachment_name(img.get("name"), img.get("type"))
            # NAMED, and refused BEFORE the bytes reach the room. A broken paste
            # must not leave a file behind in the captain's archive — and the
            # refusal has to say WHICH image when he pasted three.
            raw = self._decode_image(img.get("dataB64"), name=name)
            target, _parts = self._room_file_path(
                sess.program_dir, "%s/%s" % (_ROOM_ATTACHMENTS, name))
            # A ROOM IS REOPENED, so names collide across days. The second
            # `shot.png` becomes `shot-2.png` rather than overwriting the one a
            # previous turn was designed from.
            stem, ext = os.path.splitext(target)
            n = 2
            while os.path.exists(target):
                target = "%s-%d%s" % (stem, n, ext)
                n += 1
            try:
                with open(target, "wb") as fh:
                    fh.write(raw)
            except OSError as exc:
                raise ActionError(
                    502, "the pasted image could not be saved into this "
                    "program's room: %s. Nothing was sent — say it again once "
                    "%s is writable." % (exc, room))
            out.append(target)
        return out

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

# The extensions each allow-listed type may keep. `image/jpeg` has two spellings
# in the wild and renaming a perfectly good `shot.jpeg` to `shot.jpeg.jpg` would
# be the surface being clever at the captain's expense.
_IMAGE_EXTS = {
    "image/png": (".png",),
    "image/jpeg": (".jpg", ".jpeg"),
    "image/gif": (".gif",),
    "image/webp": (".webp",),
}

# What survives from a browser-supplied filename. Everything else becomes "-".
_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def _attachment_name(name, content_type):
    """A filename for a pasted image, kept RECOGNISABLE but never trusted.

    S169 (FL-014). The name arrives from the page, and the file is written into
    the captain's archive, so it is reduced to a bare basename over a strict
    character class and given the extension its (already allow-listed) content
    type implies. `_room_file_path` — the preview route's jail — resolves the
    result afterwards, so this is the readable half of the fence and not the
    fence itself: a name that somehow still escaped would be refused there.

    The captain's own filename is worth keeping when it survives: `kitchen-
    reference.png` in a room he reopens in a month says what a `lcars-img-
    8f2c.png` never could.
    """
    base = os.path.basename(str(name or "").replace("\\", "/")).strip()
    base = _SAFE_NAME.sub("-", base).lstrip(".-")
    if not base:
        base = "pasted-image"
    ctype = (content_type or "").strip().lower()
    ext = os.path.splitext(base)[1].lower()
    if ext not in _IMAGE_EXTS.get(ctype, ()):
        base += _IMAGE_SUFFIX.get(ctype, ".png")
    # A pathological 4kB filename is still a filename; cap it without losing the
    # extension the engine's image loader selects on.
    stem, ext = os.path.splitext(base)
    return stem[:80] + ext


def _is_image_path(path):
    """Is this file one of the image types LCARS accepts?

    S127 BLOCKER. The per-turn worker argv is the IMAGE road — copilot's
    `--attachment`, claude's "attached images" path list — and the holodeck
    hand-off parks missions whose durable attachments are an HTML mockup and a
    markdown concept doc. Seeding those into the opening grill turn killed
    copilot on spawn ("--attachment file type not supported") and, on claude,
    told the grill a design document was a screenshot.

    It reads BOTH halves of the ONE table above rather than introducing a
    second list of extensions: the suffixes LCARS itself stages (its values)
    and, through `mimetypes`, the content types it allow-lists (its keys). The
    second half is what keeps a `.jpeg` a captain attached from the CLI an
    image — LCARS only ever writes `.jpg`, so a values-only test would drop a
    real screenshot and the cure would carry a bug of its own.
    """
    ext = os.path.splitext(path or "")[1].lower()
    if ext and ext in set(_IMAGE_SUFFIX.values()):
        return True
    ctype = (mimetypes.guess_type(path or "")[0] or "").lower()
    return ctype in _IMAGE_SUFFIX


def _attach_heading(paths):
    """"attached images" or "attached files" — what is really on this list.

    S128 / FL-010, THE FIFTH HOME OF THE LIE. Four copies of "attached images"
    in `skills/` were cured and consolidated into one shared bash rule
    (`lcars_attach_heading`, skills/lcars-init/lcars-common.sh); the scan that
    guards them only reads `skills/`, so it cannot see this one — the daemon's
    own interactive Align turn, which is the FIRST thing that reads a holodeck
    program's mockup.

    IT IS THE SAME SPLIT AS THE BASH RULE: every path an image → "images",
    otherwise "files". It is not the same TABLE, and it cannot be — the bash
    rule classifies by extension alone, while the daemon's notion of an image
    is `_is_image_path`, the narrower allow-list of what LCARS actually stages
    and can pass to a CLI. Where the two differ (`.svg`, `.bmp`, `.heic`) this
    is the STRICTER one: it may call an image a file, never a file an image,
    and FL-010 only has the one direction. `test_where_they_differ_the_daemon_
    is_the_stricter_one` measures that against the shipped bash, so the two
    surfaces cannot drift past each other unnoticed.
    """
    paths = [p for p in (paths or []) if p]
    if paths and all(_is_image_path(p) for p in paths):
        return "attached images"
    return "attached files"


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
        # S183: the foundation gate — the ONE seam that decides whether this
        # repo may take a normal mission (and open the holodeck) at all.
        "foundation_gate": os.path.join(
            home, ".claude/skills/lcars-init/foundation-gate.sh"),
        # S184 — Establish Vision, resolved like every other skill.
        "establish_vision": os.path.join(
            home, ".claude/skills/lcars-init/establish-vision.sh"),
        # S190 — the ownership library's EXECUTABLE face, resolved like every
        # other skill. It lives inside lcars-run beside host-adapter.sh.
        "ownership": os.path.join(
            home, ".claude/skills/lcars-run/ownership.sh"),
        # S191 — `lcars adopt`, resolved like every other skill.
        "adopt": os.path.join(
            home, ".claude/skills/lcars-adopt/adopt.sh"),
        # S201 — `lcars xo`, the ONE writer of the numberOne config block and
        # of a mission's numberOne state. The daemon only dispatches it.
        "xo": os.path.join(
            home, ".claude/skills/lcars-xo/xo.sh"),
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
