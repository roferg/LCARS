#!/usr/bin/env python3
"""xo-run.py — RUN the declared steps a browser was never going to reach (S239).

    python3 xo-run.py run      --journey <journey.json> --out <shots-dir>
                               --repo <repo> --branch <branch> --mission-dir <dir>
                               [--worktree <wt> --home <home>]
    python3 xo-run.py actions  --actions <xo-actions.json> --out <kept.json>
                               --mission-dir <dir> [--cap 12]
    python3 xo-run.py prepare  --repo <repo> --branch <branch>
    python3 xo-run.py teardown --repo <repo> --worktree <wt> --home <home>
    python3 xo-run.py consent  --repo <repo> [--mission-dir <dir>]

ONE TREE AND ONE HOME FOR THE WHOLE LOOK (S246). `prepare` mints them once,
`run --worktree … --home …` reuses them for every round, and `teardown` removes
them at the end of the look. Without that, every `run` minted its own and a
worker could not file a record in round 1 and read it back in round 2 — which is
most of what the captain's EEH does by hand. Given no `--worktree/--home`,
`run` still mints and removes its own, for the callers that really are one
process long (recheck, and the unit tests that drive this file head-on).

WHY THIS FILE EXISTS — THE MEASUREMENT, NOT A HUNCH.
On the Canvas weekend (26–29 Sep 2026), same product, 34 runs: Number One filed
0 of 31 bugs; the captain's EEH found all 31. All 16 of Number One's recorded
misses (lcars-dev/canvas-weekend-2026-09-26/evidence/number-one-misses.jsonl)
are REACH errors and not one is a judgement error:

    "CLI argument handling and env-var behaviour had no test and no screen, so
     nothing looked at them."
    "The tests assert the workflow file is committed, not that it deploys
     anything. Nothing ran the workflow."
    "Every test and every one of my live checks ran the scripts from the repo
     checkout, never through the installed symlink the product ships with."

Its judgement and its honesty were fine wherever it could reach. This file is
the reach.

THE FENCE IT KEEPS — read this before changing anything here.
The worker role stays `repo-read`. It NEVER gets a shell. Giving it
`repo-write` "so it can run the CLI" reopens the S168 fence (read roles have no
shell; the launch role "swapped its shell for a pen") and turns the look back
into the lottery S222 removed ("a model left to walk freely is a LOTTERY, and a
lottery is not a proof"). So the design is, permanently:

    THE STEP IS DECLARED (xo-journey.py, from the record and the live-check
    checklists). THE HARNESS EXECUTES IT (here). THE MODEL READS THE READOUT.

TWO THINGS A STEP MAY NEVER TOUCH, and both are refusals, not warnings:

  * the mission's CHECKED-OUT branch. Every step runs in a DETACHED worktree.
    On the modelled weekend a whole round was verified against the wrong tree
    because the orchestrator forgot.
  * the captain's real HOME. Every step runs with a THROWAWAY HOME. A config
    written earlier makes a product that cannot be configured look configured.

ONE MACHINERY, NOT TWO. The worktree and the throwaway HOME come from the
ECH round's own helper — `ech.sh worktree --branch <br>` (wt_prepare)
— because a second implementation of "detach a worktree" is a second thing that
can be subtly wrong, and the EEH and Number One must be checking the same
tree. The workflow kind is likewise executed by `ech.sh workflow-run`, the
minimal step runner S234 built precisely so a package module invoked as a FILE
still fails the way CI fails it.

WHERE THE EVIDENCE GOES. Beside the browser shots, under `xo/shots/<look>/`,
with the checklist's own `NN-` naming — so the First Officer's report UI serves
a CLI transcript exactly as it already serves a PNG, with no new surface
anywhere (S205, and the report contract this round does not change). Each step
writes BOTH:

    NN-name.txt    the command, then its exact output — what a bug PRD quotes
    NN-name.json   the readout: exit, stdout, stderr, the expect verdict,
                   `checkedBy`, and the worktree + HOME it actually used

A READOUT IS A RECORD, NOT A JUDGEMENT. `met` is set only from the MECHANICAL
parts of `expect` (an exit code, a string that must appear). The checklists say
so themselves: "`expect` is prose for a model, not a matcher — the judgement
stays with the reader". A step with nothing mechanical to check records
`met: null`, which reads as "ran, not judged", never as "passed".

A STEP MAY REACH A REAL HOST, AND ONLY BY THE RECORD'S CONSENT (S249).
Until this session `step_env` built PATH, LANG, HOME and TMPDIR and nothing else,
so NO CREDENTIAL HAS EVER REACHED A STEP and a real publish was impossible — 5 of
the 29 bugs the captain's EEH found on the weekend needed one. That fence was
"no credentials" BY ACCIDENT and not by record. It is now a record: a `run` step
may declare

    "live": {"host": "<h>", "owner": "<o>"[, "repo": "<r>"]}

and the harness grants it `GH_HOST`, a `GH_TOKEN` IT LOOKS UP ITSELF, and
`LCARS_XO_LIVE=1` — but ONLY when the consent the captain wrote names that host
and owner (`.git/lcars/autopilot.json liveTargets`, else `config.json
numberOne.liveTargets`). Four rules make that a fence rather than a switch:

  * CONSENT COMES FROM THE RECORD AND NOWHERE ELSE. Not from the environment,
    not from the step, not from the worker. An empty record is NO consent.
  * THE CREDENTIAL IS THE HARNESS'S. `gh auth token -h <host>` is run here; the
    value is never written to disk, never journaled, and every artifact this
    file writes is SCRUBBED of it (`scrub`), so a careless product that echoes
    its own token still cannot leak one into a transcript.
  * A WORKER-DECLARED CREDENTIAL IS STRIPPED (`CRED_ENV_KEYS`). A step cannot
    smuggle a token in its `env`, and cannot point `gh` at another host.
  * A REFUSAL NAMES THE MISSING CONSENT: "needs a live target: <h>/<o> is not in
    liveTargets", recorded like any other refusal, so the criterion it was for
    reads `untested (needs a live target)` and the report asks for infrastructure
    rather than sending the captain's build back.

EVERY LIVE EFFECT IS LEDGERED. `xo/live.json` accumulates the repos, branches,
runs, deployments and discussions a consented step DECLARED it might create, so
the report can say what it touched and a later teardown has a list to work from.

THE REST OF THE FENCE DID NOT MOVE. The argv fence (`_shell_refusal`,
`argv_refusal`, `refuse_reason`, `declared_escape`) is untouched, byte for byte:
a consented step asking for a shell is still refused for being a shell.

DEPENDENCIES ARE ENV-INJECTED (the lcars-init pattern) so tests can stub them:
    LCARS_ECH_BIN    ech.sh          (default: ../lcars-eeh/)
    LCARS_GIT_BIN          git
    LCARS_GH_BIN           gh                    (the credential lookup, S249)
    LCARS_XO_STEP_TIMEOUT  seconds per step      (default 120)
"""
import fnmatch
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

SELF_DIR = os.path.dirname(os.path.abspath(__file__))
SKILLS_DIR = os.path.dirname(SELF_DIR)
ECH = os.environ.get("LCARS_ECH_BIN") or os.path.join(
    SKILLS_DIR, "lcars-eeh", "ech.sh")
GIT = os.environ.get("LCARS_GIT_BIN") or "git"
# The credential lookup, and the ONLY program that is ever asked for a token.
GH = os.environ.get("LCARS_GH_BIN") or "gh"

# PER-STEP, NOT PER-RUN. The whole look is already caged by XO_LOOK_TIMEOUT
# (xo.sh); one hung command must not eat that whole budget, because the steps
# after it are the ones nobody has ever reached.
STEP_TIMEOUT = int(os.environ.get("LCARS_XO_STEP_TIMEOUT") or 120)

# ONE CAP ACROSS ALL KINDS (S222's ≤12 per round, unchanged). A worker that
# asked for twenty may never look like it got them, so the overflow is recorded.
MAX_ACTIONS = int(os.environ.get("LCARS_XO_MAX_ACTIONS") or 12)

# `viewport` (S266) IS A BROWSER VERB AND NOTHING MORE. The reviewer's own
# embedded checklist tells it to look at phone width; `{"viewport": {"width":
# 400}}` is how it asks, and xo-drive.js applies it with
# `Emulation.setDeviceMetricsOverride` in the browser it already has open. It
# reaches nothing, runs nothing and names no path, so the argv fence
# (`declared_escape` / `refuse_reason`) is not involved and is unchanged: a verb
# on neither allow-list is still refused BY NAME, as the `teleport` case proves.
BROWSER_KINDS = ("navigate", "click", "type", "gate", "press", "key", "goto",
                 "scroll", "shot", "screenshot", "wait", "hover", "select",
                 "viewport")
# The two line prefixes `ech.sh workflow-run` prints, and the one place
# this file names them. `  SKIP: ` is its notice that a step was NOT executed
# (a packaged `uses:` action, a step with no `run:`, a shell it does not drive)
# and that the step is UNPROVEN, not passed.
WF_STEP = "STEP "
WF_SKIP = "  SKIP: "
REACH_KINDS = ("run", "workflow", "read")
CHECKED_BY = {"run": "cli", "workflow": "workflow", "read": "test"}

# THE VERB IS THE KEY, NOT A `do` FIELD (S257 fault 2).
#
# THE DEFECT THIS CLOSES, measured on the 2026-10-06 drive: `cmd_actions` read
# the step kind out of `a["do"]`, and the action schema HAS NO `do` FIELD for a
# browser step — the verb is the key. `{"click":"#submit"}`, `{"navigate":URL}`,
# `{"type":"#guess","text":"1234"}`, `{"press":"Enter"}` is what
# prompts/evaluate.md teaches and what xo-drive.js dispatches on (its `a.click`
# / `a.navigate` / `a.press` chain). So `kind` came back "" for every real
# browser action and EVERY ONE WAS REFUSED before anything ran — 12 then 14
# refusals a round, `actions-kept-N.json` holding `refused: 12 x {"kind": ""}`,
# while the same run's drive notes proved the worker had asked for real clicks.
#
# `do` is still honoured and still wins: `run` / `workflow` / `read` are
# declared that way. NOTHING HERE WIDENS THE FENCE — a verb that is on neither
# allow-list is still refused, `declared_escape` still vets every reach step,
# and the refusal now NAMES the verb it refused instead of saying nothing.
ACTION_KINDS = REACH_KINDS + BROWSER_KINDS


def action_kind(a):
    """(kind, what-to-call-it) for one action, READ off the record.

    The declared `do` first; otherwise the first key that is a kind the harness
    knows. The second value is for the refusal message — the keys the action
    actually carried — so an unknown step is refused BY NAME.
    """
    declared = str(a.get("do") or "").strip()
    if declared:
        return declared, declared
    for k in a.keys():
        if str(k) in ACTION_KINDS:
            return str(k), str(k)
    named = ", ".join("`%s`" % k for k in a.keys())
    return "", (named or "an action with no verb at all")

WORKTREE_MARK = "<worktree>"
HOME_MARK = "<throwaway-home>"
# A SECOND ACTOR IS A SECOND HOME (S246). The cli checklist's item 4 — "two
# actors, two HOMEs, two laptops" — was the one item a single HOME could never
# instantiate, and the EEH does it by hand every time. A step may now declare
# `<throwaway-home-2>` (or `-3`) and the harness MINTS it, beside the look's
# first HOME and under the same parent, on first use.
#
# THE FENCE DID NOT MOVE FURTHER THAN THAT. An arbitrary HOME is still refused:
# the allowed set is exactly the look's OWN marks, resolved to dirs this process
# created. `/Users/somebody-else` is refused by `refuse_reason` as it always was,
# and `declared_escape` refuses it at the request gate too.
HOME_MARK_2 = "<throwaway-home-2>"
HOME_MARK_3 = "<throwaway-home-3>"
EXTRA_HOME_MARKS = (HOME_MARK_2, HOME_MARK_3)
# mark → the directory minted for it, for THIS process. Populated on first use
# by `mint_extra_home`, read by `resolve`, `refuse_reason` and `teardown`.
_EXTRA_HOMES = {}

# ── CREDENTIALS FOR AN ALLOW-LISTED HOST, AND NOTHING ELSE (S249) ───────────
#
# The ONE sentence a refusal for want of consent begins with. It is a contract
# string: `xo-score.py` turns the criterion the step was for into
# `untested (needs a live target)` off `xo/live.json`, and the recommendation
# treats it as OUR infrastructure rather than a fault in the build.
NEEDS_LIVE = "needs a live target"
# The kinds of live effect a worker may declare it might create. Not a fence —
# the ledger records whatever it declares — but the five words the prompt, the
# report and a later teardown all use for the same things.
LIVE_EFFECT_KINDS = ("repo", "branch", "run", "deployment", "discussion")
# ENV KEYS A STEP MAY NEVER DECLARE FOR ITSELF. Every one of them either IS a
# credential or decides which credential `gh` picks up, so a worker that declared
# one would be granting itself the reach this session put behind a record. They
# are stripped from every step, live or not, and the readout says so.
CRED_ENV_KEYS = ("GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN",
                 "GITHUB_ENTERPRISE_TOKEN", "GH_HOST", "GH_CONFIG_DIR")
# Every secret this process has looked up, so nothing it writes can carry one.
# Values only live here and in the env handed to a consented step's Popen.
_SECRETS = set()
# host → token, so one look asks `gh` once per host.
_TOKEN_CACHE = {}


def remember_secret(value):
    """Register a value as unprintable. Short strings are ignored on purpose: a
    two-character "token" would scrub half the transcript."""
    v = str(value or "")
    if len(v) >= 8:
        _SECRETS.add(v)


REDACTED = "<redacted>"
# A CREDENTIAL'S OWN SHAPE. The known-secret pass below covers every token this
# harness looked up; these marks cover one it never saw — a second credential the
# product under review holds and prints for itself. A mark followed by a long run
# of token characters is a credential whatever its value turns out to be.
CRED_MARKS = ("ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_")
# How many token characters must follow a mark before it counts as one: short
# enough that a real credential always clears it, long enough that the word
# `ghp_` in a sentence of prose is left alone.
CRED_MARK_RUN = 8


def _token_char(ch):
    """True for a character a GitHub credential is spelled with."""
    return ch.isalnum() or ch == "_"


def _spread_span(text, i, s):
    """How many characters at text[i:] spell <s> with only whitespace between
    them — and 0 when they do not.

    THE LEAK THIS EXISTS TO CLOSE. The first cut of `scrub` compared exact
    substrings, so the very thing its docstring names as the threat defeated it:
    a verbose client echoes the request, the terminal FOLDS the line, and the
    credential lands in the saved transcript in order with a newline through the
    middle of it. A fold inserts whitespace and nothing else, so whitespace is
    what this steps over. The span is CAPPED, because a token folded at twenty
    columns is still a token while the same characters spelled one per line down
    half a transcript are not.
    """
    n = len(text)
    limit = i + 4 * len(s) + 8
    j = i
    for ch in s:
        while j < n and j < limit and text[j].isspace():
            j += 1
        if j >= n or text[j] != ch:
            return 0
        j += 1
    return j - i


def _redact_spread(text, s):
    """(text, count) with every spelling of the secret <s> — whole, or broken by
    a fold — replaced by the redaction mark."""
    if not s or len(s) < 8:
        return text, 0
    first = s[0]
    n = len(text)
    out = []
    count = 0
    i = 0
    while i < n:
        if text[i] == first:
            w = _spread_span(text, i, s)
            if w:
                out.append(REDACTED)
                i += w
                count += 1
                continue
        out.append(text[i])
        i += 1
    return "".join(out), count


def _redact_shaped(text):
    """(text, count) with anything SHAPED like a credential replaced, whatever
    its value — the backstop for a token this process never looked up and so
    could not have registered as a secret. The run is CONTIGUOUS on purpose: one
    that stepped over a newline would swallow the `GITHUB_TOKEN=` on the line
    below it, and over-redacting a credential's neighbours is its own kind of
    lying about what the product printed."""
    count = 0
    for mark in CRED_MARKS:
        n = len(text)
        out = []
        i = 0
        while True:
            k = text.find(mark, i)
            if k < 0:
                out.append(text[i:])
                break
            j = k + len(mark)
            while j < n and _token_char(text[j]):
                j += 1
            # AT A BOUNDARY, OR IT IS NOT A CREDENTIAL. A mark can fall inside an
            # ordinary word — `highs_checked` ends up carrying `ghs_` — and a
            # redaction there would blank a word the product really printed.
            at_edge = k == 0 or not _token_char(text[k - 1])
            if at_edge and j - (k + len(mark)) >= CRED_MARK_RUN:
                out.append(text[i:k])
                out.append(REDACTED)
                count += 1
            else:
                out.append(text[i:j])
            i = j
        text = "".join(out)
    return text, count


def scrub(text):
    """(text with every known secret replaced by <redacted>, how many times).

    THE LAST LINE OF DEFENCE, AND THE REASON IT IS NOT OPTIONAL. The product
    under review is not ours: `relay publish` may print its own environment, a
    stack trace may carry a header, a verbose client echoes the request. So every
    artifact this file writes goes through here, and the readout says how many
    redactions it made — "GH_TOKEN=<redacted>" is a RECORD that a credential was
    there, which is what the captain needs to read, rather than a silence.

    A SECRET IS MATCHED THROUGH A FOLD, NOT AS A SUBSTRING. `_spread_span` says
    why: ordinary line wrapping used to be enough to carry a whole credential
    into an artifact under `xo/`. The count is kept across both passes, because a
    redaction nobody counted reads exactly like nothing having been there.
    """
    out = str(text if text is not None else "")
    n = 0
    # LONGEST FIRST, so a secret that contains a shorter one is redacted whole —
    # and in a fixed order, because an artifact that depends on set ordering is
    # one nobody can reproduce.
    for s in sorted(_SECRETS, key=lambda v: (-len(v), v)):
        out, k = _redact_spread(out, s)
        n += k
    out, k = _redact_shaped(out)
    n += k
    return out, n


def scrub_json(doc):
    """The same scrub, over a readout about to be written. Returns (doc, count)."""
    if isinstance(doc, str):
        return scrub(doc)
    if isinstance(doc, list):
        total = 0
        out = []
        for v in doc:
            v2, n = scrub_json(v)
            total += n
            out.append(v2)
        return out, total
    if isinstance(doc, dict):
        total = 0
        out = {}
        for k, v in doc.items():
            v2, n = scrub_json(v)
            total += n
            out[k] = v2
        return out, total
    return doc, 0


def lcars_dir(repo, mission_dir):
    """Where `.git/lcars` is — from the mission dir when there is one.

    A mission dir IS `<git-dir>/lcars/missions/<id>`, so walking up to the `lcars`
    directory that holds `missions/` is exact and needs no git call. Without a
    mission dir (a unit test driving this file head-on) the repo's own common git
    dir answers it, the same way `xo.sh:82-87` does.
    """
    p = os.path.abspath(mission_dir) if mission_dir else ""
    while p and p != os.path.dirname(p):
        head, tail = os.path.split(p)
        if tail == "lcars" and os.path.isdir(os.path.join(p, "missions")):
            return p
        p = head
    gd = ""
    try:
        r = subprocess.run([GIT, "-C", repo, "rev-parse", "--git-common-dir"],
                           capture_output=True, text=True, timeout=30)
        if r.returncode == 0:
            gd = (r.stdout or "").strip()
    except Exception:
        gd = ""
    if gd:
        if not os.path.isabs(gd):
            gd = os.path.join(repo, gd)
        return os.path.join(gd, "lcars")
    return os.path.join(repo, ".git", "lcars")


def load_consent(ldir):
    """The CONSENT RECORD — {host, owners[], repos[], source}. Empty = none.

    TWO PLACES, IN ONE ORDER, AND NEITHER OF THEM IS THE ENVIRONMENT.
      1  `autopilot.json liveTargets` — what the captain answered at the
         ECH's alignment round (`ech.sh:606`, `HOLOGRAM-COMMAND-MODE.md:75,133`).
         The EEH has read it since S232; this is the first time the first
         officer does, which is the whole point of the session.
      2  `config.json numberOne.liveTargets` — the same shape, for a repo with no
         the ECH run behind it.
    A record with no host, or with no owners, is NOT consent: an empty allow-list
    allows nothing. `source` is carried so a readout can say which file said yes.
    """
    def shape(raw, source):
        if not isinstance(raw, dict):
            return None
        host = str(raw.get("host") or "").strip()
        owners = [str(o).strip() for o in (raw.get("owners") or []) if str(o).strip()]
        repos = [str(r).strip() for r in (raw.get("repos") or []) if str(r).strip()]
        if not host or not owners:
            return None
        return {"host": host, "owners": owners, "repos": repos, "source": source}

    ap = load(os.path.join(ldir, "autopilot.json"), {})
    if isinstance(ap, dict):
        got = shape(ap.get("liveTargets"), "autopilot.json liveTargets")
        if got:
            return got
    cfg = load(os.path.join(ldir, "config.json"), {})
    if isinstance(cfg, dict):
        n1 = cfg.get("numberOne")
        if isinstance(n1, dict):
            got = shape(n1.get("liveTargets"), "config.json numberOne.liveTargets")
            if got:
                return got
    return {"host": "", "owners": [], "repos": [], "source": ""}


def live_block(step):
    """The step's declared live target, or None when it asked for nothing live."""
    live = step.get("live")
    if not isinstance(live, dict):
        return None
    out = {"host": str(live.get("host") or "").strip(),
           "owner": str(live.get("owner") or "").strip(),
           "repo": str(live.get("repo") or "").strip()}
    if not (out["host"] or out["owner"] or out["repo"]):
        return None
    return out


def live_refusal(live, consent):
    """The ONE sentence saying why this step may not reach a live host, or "".

    SEPARATE FROM `refuse_reason` ON PURPOSE. The argv fence judges the SHAPE of a
    step and is pinned symbol-for-symbol by `tests/lcars-xo-refusal.test.sh`; this
    judges a step against a RECORD the captain wrote. Two different questions, two
    functions, and the fence this session did not widen stays exactly where it was.
    """
    if not live:
        return ""
    h, o, r = live["host"], live["owner"], live["repo"]
    if not h or not o:
        return ("%s: a live step names the host AND the owner it is for, and this "
                "one names only %s" % (NEEDS_LIVE, h or o or "neither"))
    named = "%s/%s" % (h, o)
    ch = consent.get("host") or ""
    owners = [str(x).lower() for x in (consent.get("owners") or [])]
    if not ch or not owners:
        return ("%s: %s is not in liveTargets — nothing in this repo's record "
                "consents to a live host, so no credential was looked up"
                % (NEEDS_LIVE, named))
    if h.lower() != ch.lower() or o.lower() not in owners:
        return ("%s: %s is not in liveTargets, which names %s/%s"
                % (NEEDS_LIVE, named, ch, ",".join(consent.get("owners") or [])))
    pats = consent.get("repos") or []
    # SILENCE FAILS CLOSED. A record that narrows consent to named repos used to
    # bind only an HONEST declaration: a step that named host and owner and no
    # repo at all ran, and was handed the credential. The step list is written by
    # a worker, not by the captain, so the careless shape is the one that matters.
    if pats and not r:
        return ("%s: %s names no repo, and liveTargets allows only the repos %s"
                % (NEEDS_LIVE, named, ", ".join(pats)))
    if r and pats and not any(fnmatch.fnmatch(r, p) for p in pats):
        return ("%s: %s/%s is not in liveTargets, whose repos are %s"
                % (NEEDS_LIVE, named, r, ", ".join(pats)))
    return ""


def live_token(host):
    """The credential for <host>, looked up BY THE HARNESS. "" when there is none.

    Run with this process's own environment, because `gh` authenticates from the
    captain's real HOME — the same standing rule that keeps the look's Chrome on
    the real one. The value is registered as a secret the moment it exists, so
    everything this file writes from then on is scrubbed of it.
    """
    if host in _TOKEN_CACHE:
        return _TOKEN_CACHE[host]
    tok = ""
    try:
        p = subprocess.run([GH, "auth", "token", "-h", host],
                           capture_output=True, text=True, timeout=STEP_TIMEOUT,
                           env=dict(os.environ))
        if p.returncode == 0:
            lines = [ln.strip() for ln in (p.stdout or "").splitlines() if ln.strip()]
            tok = lines[0] if lines else ""
    except Exception:
        tok = ""
    _TOKEN_CACHE[host] = tok
    remember_secret(tok)
    return tok


def live_effects_of(step, live, consent):
    """The live effects a step DECLARED it might create, normalised for the ledger.

    The worker declares them; nothing is inferred from what a command did, because
    a teardown that works off a guess is a teardown that deletes the wrong thing.
    A bare string is accepted ("branch xo-probe") so a declaration is never thrown
    away for its shape.
    """
    out = []
    for raw in (step.get("liveEffects") or []):
        kind = name = ""
        if isinstance(raw, dict):
            kind = str(raw.get("kind") or "").strip().lower()
            name = str(raw.get("name") or raw.get("ref") or raw.get("id") or "").strip()
        elif isinstance(raw, str):
            bits = raw.strip().split(None, 1)
            if bits and bits[0].lower() in LIVE_EFFECT_KINDS:
                kind, name = bits[0].lower(), (bits[1].strip() if len(bits) > 1 else "")
            else:
                name = raw.strip()
        if not (kind or name):
            continue
        out.append({"kind": kind or "other", "name": name,
                    "host": live["host"], "owner": live["owner"],
                    "repo": live["repo"], "step": str(step.get("key") or ""),
                    "for": str(step.get("for") or ""),
                    "consentedBy": consent.get("source") or "",
                    "declared": True,
                    "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    return out


def live_path(mission_dir):
    """`xo/live.json` — beside the look's shots, inside the mission's own dir."""
    return os.path.join(mission_dir, "xo", "live.json") if mission_dir else ""


def load_live(mission_dir):
    path = live_path(mission_dir)
    doc = load(path, None) if path else None
    if not isinstance(doc, dict):
        doc = {}
    doc.setdefault("consent", {})
    for key in ("effects", "refused"):
        if not isinstance(doc.get(key), list):
            doc[key] = []
    return doc


def save_live(mission_dir, doc):
    """ACCUMULATED, NEVER REPLACED — a second round's effects do not erase the
    first's, and S250's teardown reads the whole list. Scrubbed on the way out
    like every other artifact."""
    path = live_path(mission_dir)
    if not path:
        return ""
    clean, _ = scrub_json(doc)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(clean, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        return ""
    return path


def say(msg):
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def journal(mission_dir, action, body):
    """Append to the mission's own feed — the ONE journal the report reads.

    A refusal that is not journaled is a refusal nobody can audit, which is how
    a dropped action looked like an action that ran.
    """
    if not mission_dir:
        return
    row = {"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "action": action}
    row.update(body or {})
    # SCRUBBED LIKE EVERY OTHER ARTIFACT (S249). The journal is the feed the
    # report and the board read, so a credential must not reach it either.
    row, _ = scrub_json(row)
    try:
        with open(os.path.join(mission_dir, "number-one.jsonl"), "a",
                  encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:
        pass


def load(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return default


def inside(parent, child):
    """Whether `child` really resolves inside `parent` — symlinks and all."""
    try:
        p = os.path.realpath(parent)
        c = os.path.realpath(child)
    except Exception:
        return False
    return c == p or c.startswith(p.rstrip(os.sep) + os.sep)


# ===========================================================================
# THE WORKTREE AND THE THROWAWAY HOME — the ECH round's own helper
# ===========================================================================
def prepare(repo, branch):
    """(worktree, home) from `ech.sh worktree --branch <br>`, or (None, why).

    NOT A SECOND IMPLEMENTATION. `wt_prepare` in ech.sh is the one place
    that knows how to detach a worktree and mint a throwaway HOME, and the EEH
    uses it for the very same checklists. If it cannot, this REFUSES rather than
    quietly falling back to the checked-out tree — which is the failure it
    exists to prevent.
    """
    if not os.path.exists(ECH):
        return None, ("no ech.sh at %s — the worktree helper is the one "
                      "machinery and there is no second one" % ECH)
    env = dict(os.environ)
    env["LCARS_ECH_CWD"] = repo
    try:
        p = subprocess.run(["bash", ECH, "worktree", "--branch", branch],
                           cwd=repo, env=env, capture_output=True, text=True,
                           timeout=STEP_TIMEOUT)
    except Exception as exc:
        return None, "the worktree helper did not run: %s" % exc
    out = (p.stdout or "") + (p.stderr or "")
    wt = home = ""
    for line in out.splitlines():
        if line.startswith("WORKTREE: "):
            wt = line[len("WORKTREE: "):].strip()
        elif line.startswith("HOME: "):
            home = line[len("HOME: "):].strip()
    if not wt or not home or not os.path.isdir(wt):
        return None, ("the worktree helper refused: %s"
                      % (out.strip().splitlines()[-1] if out.strip() else "no output"))
    return (wt, home), ""


# WHAT A DYING LOOK MUST STILL CLEAN UP.
# `teardown` used to run ONLY in a `finally`, which a signal does not honour.
# Observed 2 Oct 2026: after killing a look, the target repo still had a
# REGISTERED worktree in its .git/worktrees/, the worktree dir and throwaway
# HOME survived on disk, and an orphan child was still running. So the state
# teardown needs lives here, where a signal handler can reach it.
_LIVE = {"repo": "", "worktree": "", "home": ""}
# The process GROUP of every step child still in flight. A step child is given
# its OWN group on purpose (`start_new_session=True`) so the timeout cage can
# `killpg` it without killing the look itself — which also means a dying look
# does NOT take it along, so the look kills these groups explicitly.
_STEP_GROUPS = set()


def _reap_step_children():
    for pgid in list(_STEP_GROUPS):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except Exception:
            pass
        _STEP_GROUPS.discard(pgid)


def teardown(repo, worktree, home):
    """Remove what this run started — the line `wt_say` itself prints.

    IDEMPOTENT AND RE-RUNNABLE. It is called from the `finally` AND from a
    signal handler, so it may run twice on the same paths; every step below is
    already a no-op the second time (`--force`, `ignore_errors`, `prune`), and
    nothing here raises.
    """
    _reap_step_children()
    try:
        if worktree:
            subprocess.run([GIT, "-C", repo, "worktree", "remove", "--force",
                            worktree], capture_output=True, text=True)
            shutil.rmtree(worktree, ignore_errors=True)
        if home:
            shutil.rmtree(home, ignore_errors=True)
        # AND THE SECOND LAPTOP (S246). Minted beside the first, so it goes with
        # it — a throwaway HOME that outlives its look is exactly the leftover
        # config that makes the NEXT look's product look configured. Also swept
        # by sibling name, so a teardown that never saw the mint still finds it.
        for mark in EXTRA_HOME_MARKS:
            extra = _EXTRA_HOMES.get(mark)
            if not extra and home:
                extra = home.rstrip(os.sep) + (mark[len("<throwaway-home"):-1] or "")
            if extra:
                shutil.rmtree(extra, ignore_errors=True)
            _EXTRA_HOMES.pop(mark, None)
        if repo:
            subprocess.run([GIT, "-C", repo, "worktree", "prune"],
                           capture_output=True, text=True)
    except Exception:
        pass
    _LIVE.update({"repo": "", "worktree": "", "home": ""})


def _teardown_on_signal(signum, _frame):
    """SIGTERM/SIGINT/SIGHUP tear down, then exit — a `finally` cannot.

    SIGKILL CANNOT BE CAUGHT, so a SIGKILLed look still leaks; `teardown` being
    re-runnable is what lets the next look's `worktree prune` recover it.
    """
    teardown(_LIVE.get("repo") or "", _LIVE.get("worktree") or "",
             _LIVE.get("home") or "")
    os._exit(128 + int(signum))


def _reap_and_exit(signum, _frame):
    """A signal when the tree is the LOOK's, not this process's (S246).

    The step children are still ours to kill — they are in their own groups by
    design, so a dying look does not take them along — but the worktree and the
    throwaway HOME belong to `xo.sh evaluate`, which tears them down in its own
    TERM trap. Removing them here would pull the ground out from under the next
    round of a look that is merely being interrupted.
    """
    _reap_step_children()
    os._exit(128 + int(signum))


def arm_teardown(repo, worktree, home):
    """Make the live worktree reachable from a signal handler, and install them."""
    _LIVE.update({"repo": repo, "worktree": worktree, "home": home})
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(sig, _teardown_on_signal)
        except Exception:
            pass


# ===========================================================================
# RESOLVING AND REFUSING A STEP
# ===========================================================================
def mint_extra_home(mark, home):
    """The dir for `<throwaway-home-2|3>`, minted on first use beside `home`.

    BESIDE THE FIRST, NEVER SOMEWHERE ELSE: a sibling under the same parent, so
    the look's teardown (which already knows that parent) takes it with it, and
    so the readout's two HOME paths read as two laptops rather than two machines.
    """
    if mark in _EXTRA_HOMES:
        return _EXTRA_HOMES[mark]
    suffix = mark[len("<throwaway-home"):-1] or "-2"   # "-2" / "-3"
    path = home.rstrip(os.sep) + suffix
    try:
        os.makedirs(path, exist_ok=True)
        os.makedirs(os.path.join(path, "tmp"), exist_ok=True)
    except Exception:
        return ""
    _EXTRA_HOMES[mark] = path
    return path


def ensure_extra_homes(step, home):
    """Mint whatever extra-HOME marks this step names, before anything resolves.

    Read off the step's own JSON text, so a mark in `env`, in `cwd` or inside an
    `argv` element is all the same question: did this step ask for a second
    laptop? Nothing is minted for a step that did not ask.
    """
    try:
        blob = json.dumps(step)
    except Exception:
        return
    for mark in EXTRA_HOME_MARKS:
        if mark in blob:
            mint_extra_home(mark, home)


def allowed_homes(home):
    """Every HOME a step of THIS look may run under — the look's own marks."""
    return [h for h in ([home] + list(_EXTRA_HOMES.values())) if h]


def resolve(value, worktree, home):
    if isinstance(value, str):
        out = value.replace(WORKTREE_MARK, worktree)
        # The extra marks FIRST: they are distinct strings (`<throwaway-home-2>`
        # does not contain `<throwaway-home>`), but resolving them first keeps
        # the order of substitution from ever being load-bearing.
        for mark, path in _EXTRA_HOMES.items():
            out = out.replace(mark, path)
        return out.replace(HOME_MARK, home)
    if isinstance(value, list):
        return [resolve(v, worktree, home) for v in value]
    if isinstance(value, dict):
        return {k: resolve(v, worktree, home) for k, v in value.items()}
    return value


# --- THE ARGV FENCE --------------------------------------------------------
# WHY THIS EXISTS. Until 2 Oct 2026 both gates below inspected "cwd", "env",
# "file" and "path" and NEITHER EVER INSPECTED "argv". The harness refused the
# declared DESTINATION while handing the COMMAND ITSELF to Popen unexamined, so
# `["bash","-c",…]` got a real shell running as the captain, `["cat","<a path
# outside>"]` read a sentinel outside both fences, and `["sh","-c","… > …"]`
# wrote outside the sandbox. All three were KEPT by the worker-request gate too.
# prompts/evaluate.md used to say in bold "You have no shell, and you are not
# getting one." — this is the code that made that sentence true FOR A DECLARED
# STEP, and it still does. S261 (captain's amendment to S168, 2026-10-08) gave
# the WORKER ITSELF a shell inside a disposable detached worktree, and expressly
# did NOT open this fence: a step the worker DECLARES for the harness to execute
# is still refused a shell, an inline-code interpreter and an absolute path.
# The two paths coexist, and that is deliberate — the harness-executed path is
# what records a transcript beside every screenshot.
#
# THIS IS A NARROWING, NOT AN ALLOW-LIST. An allow-list of permitted programs is
# the stronger design and is NOT built here; the captain has not chosen it. What
# is here refuses the two shapes that turn a declared step into a command line:
# a shell (or an interpreter asked for inline code), and an absolute path.
SHELLS = ("sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish")
# `env` is refused outright: its whole job is to launder what comes next past a
# check on argv[0] (`env bash -c …`), and a step already declares its env.
LAUNDERERS = ("env",)
# A `-c`/`-e` form makes any of these a shell in another coat.
INTERPRETERS = ("python", "python2", "python3", "perl", "ruby", "node",
                "nodejs", "php", "lua", "deno", "bun", "osascript")
SHELL_FLAG_LETTERS = set("csi")      # sh -c, sh -s, sh -i all read a command
INLINE_FLAG_LETTERS = set("ce")      # python -c, perl -e, node -e, ruby -e
INLINE_LONG = ("--eval", "--command", "--eval-script")


def _shell_refusal(argv):
    """One sentence why this argv IS a shell (or a shell in a coat), or "".

    Matched on the BASENAME of argv[0], so `/bin/bash` and `bash` are the same
    thing. `bash run-tests.sh` is NOT refused — running a test script through
    bash is a legitimate step, and the checklists generate it. `bash -c` is.
    """
    if not argv:
        return "its argv is empty — a step names the program it runs"
    prog = os.path.basename(str(argv[0]).strip())
    args = [str(a) for a in argv[1:]]
    flags, rest = [], []
    for i, a in enumerate(args):
        if a == "--":
            rest.extend(args[i + 1:])
            break
        (flags if a.startswith("-") and a != "-" else rest).append(a)

    def letters():
        out = set()
        for f in flags:
            if f.startswith("--"):
                if f.split("=")[0] in INLINE_LONG:
                    out |= INLINE_FLAG_LETTERS
            else:
                out |= set(f[1:])
        return out

    if prog in LAUNDERERS:
        return ("its argv runs through `%s`, which hides what would actually be "
                "executed — a step names the program it runs, so the harness "
                "refuses it rather than resolving it at run time" % prog)
    if prog in SHELLS:
        if letters() & SHELL_FLAG_LETTERS or not rest:
            return ("its argv asks for a shell (`%s` %s) — a step has no shell, "
                    "so the harness refuses the command instead of handing one a "
                    "command line"
                    % (prog, ("with %s" % " ".join(flags)) if flags
                       else "with no script to run"))
        return ""
    if prog in INTERPRETERS:
        if letters() & INLINE_FLAG_LETTERS or not rest:
            return ("its argv runs `%s` on inline code (%s), which is a shell in "
                    "another coat — a step runs a program inside the worktree, "
                    "not a snippet the harness never sees"
                    % (prog, " ".join(flags) if flags
                       else "no script, so it would read one from stdin"))
    return ""


def argv_refusal(argv, worktree=None, home=None):
    """The ONE sentence saying why this argv may not run, or "".

    `worktree is None` judges the DECLARED form (a worker's request, before any
    worktree exists); otherwise the marks are resolved and the real paths tested.
    """
    argv = list(argv or [])
    why = _shell_refusal(argv)
    if why:
        return why
    marks = (WORKTREE_MARK, HOME_MARK) + EXTRA_HOME_MARKS
    for raw in argv:
        s = str(raw)
        if any(m in s for m in marks):
            # The honourable form: inside the sandbox once resolved, or refused.
            if worktree is None:
                bare = s
                for m in marks:
                    bare = bare.replace(m, "")
                if ".." in bare.split("/"):
                    return ("its argv names %s, which walks up out of the "
                            "worktree — a step addresses only what is inside "
                            "the sandbox" % s)
                continue
            r = resolve(s, worktree, home)
            if not (inside(worktree, r)
                    or any(inside(h, r) for h in allowed_homes(home))):
                return ("its argv names %s, which resolves to %s outside the "
                        "detached worktree — a step addresses only what is "
                        "inside the sandbox" % (s, r))
            continue
        if os.path.isabs(s):
            return ("its argv names the absolute path %s — a step addresses "
                    "only what is inside the sandbox, so an absolute path is "
                    "refused wherever it appears in the command" % s)
        if "/" in s and ".." in s.split("/"):
            return ("its argv names %s, which walks up out of the worktree — a "
                    "step addresses only what is inside the sandbox" % s)
    return ""


def refuse_reason(step, worktree, home):
    """The ONE sentence saying why this step may not run, or "".

    Both fences, checked on the RESOLVED paths and never on the declared text,
    because `<worktree>/../..` resolves out and reads as if it stayed in.
    """
    if step.get("do") == "run":
        why = argv_refusal(step.get("argv") or [], worktree, home)
        if why:
            return why
    cwd = resolve(step.get("cwd") or WORKTREE_MARK, worktree, home)
    if not inside(worktree, cwd):
        return ("its cwd %s is outside the detached worktree %s — a step never "
                "runs against the mission's checked-out branch" % (cwd, worktree))
    env = resolve(step.get("env") or {}, worktree, home)
    declared_home = str(env.get("HOME") or home)
    # ONE OF THE LOOK'S OWN MARKS, AND NOTHING ELSE (S246). The look's first
    # HOME, or a `<throwaway-home-2|3>` this process minted beside it. A literal
    # path — the captain's real HOME, somebody else's — is refused exactly as it
    # has always been: that is the whole difference between a second laptop and a
    # config written earlier that makes an unconfigurable product look configured.
    if not any(inside(h, declared_home) for h in allowed_homes(home)):
        return ("its HOME %s is outside the throwaway HOME %s — a config written "
                "earlier makes an unconfigurable product look configured"
                % (declared_home, home))
    if step.get("do") == "read":
        path = resolve(step.get("path") or "", worktree, home)
        if not os.path.isabs(path):
            path = os.path.join(worktree, path)
        if not inside(worktree, path):
            return ("the artifact it reads, %s, is outside the detached worktree"
                    % path)
    if step.get("do") == "workflow":
        wf = resolve(step.get("file") or "", worktree, home)
        if not os.path.isabs(wf):
            wf = os.path.join(worktree, wf)
        if not inside(worktree, wf):
            return "the workflow it runs, %s, is outside the detached worktree" % wf
    return ""


def verdict(expect, *, exit_code=None, stdout="", stderr="", content="",
            worktree=""):
    """(met, checks) — the MECHANICAL half of `expect`, and only that half.

    `met` is None when there was nothing mechanical to check: "ran, not judged".
    Anything else would turn the checklists' prose ("outputMatchesReality") into
    a matcher, and the judgement belongs to the reader (README, live-check/).
    """
    checks = []
    mechanical = 0
    ok = True

    def record(key, want, got, passed):
        nonlocal mechanical, ok
        mechanical += 1
        checks.append({"key": key, "mechanical": True, "want": want,
                       "got": got, "passed": bool(passed)})
        if not passed:
            ok = False

    for key, want in (expect or {}).items():
        if key == "exit" and isinstance(want, int):
            record(key, want, exit_code, exit_code == want)
        elif key in ("exitNonZero",) and want:
            record(key, "non-zero", exit_code, exit_code not in (0, None))
        elif key == "stdoutIncludes" and isinstance(want, str):
            record(key, want, None, want in (stdout or ""))
        elif key == "stderrIncludes" and isinstance(want, str):
            record(key, want, None, want in (stderr or ""))
        elif key == "includes" and isinstance(want, str):
            record(key, want, None, want in ((content or "") + (stdout or "")))
        elif key == "fileExists" and isinstance(want, str):
            target = want if os.path.isabs(want) else os.path.join(worktree, want)
            record(key, want, None, os.path.exists(target))
        else:
            # PROSE FOR A MODEL. Carried through so the worker reads it; never
            # matched, never counted, never allowed to make a step look passed.
            checks.append({"key": key, "mechanical": False, "want": want})
    return (ok if mechanical else None), checks


def step_env(declared, home, live_env=None, stripped=None):
    """The environment a step runs in — built, not inherited.

    The real HOME never reaches a step. PATH does, because `python3` lives on it
    and a step with no PATH proves only that PATH was missing.

    AND A CREDENTIAL IS THE HARNESS'S TO ADD (S249). Every key in
    `CRED_ENV_KEYS` is STRIPPED out of what the step declared — a worker cannot
    hand itself a token, and cannot point `gh` at a host the record never named —
    and `live_env` is applied LAST, so the only credential that can reach a step
    is one this process looked up against a consented host. `stripped`, when a
    list is passed in, collects the keys that were refused so the readout can say
    what it took away.
    """
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
           "LANG": os.environ.get("LANG", "C.UTF-8"),
           "HOME": home,
           "TMPDIR": os.path.join(home, "tmp"),
           "LCARS_XO_STEP": "1"}
    os.makedirs(env["TMPDIR"], exist_ok=True)
    for k, v in (declared or {}).items():
        if str(k) in CRED_ENV_KEYS:
            if stripped is not None and str(k) not in stripped:
                stripped.append(str(k))
            continue
        env[str(k)] = str(v)
    for k, v in (live_env or {}).items():
        env[str(k)] = str(v)
    return env


def run_cmd(argv, cwd, env, timeout):
    """Run one command, caged, and kill its WHOLE process group on a timeout.

    There is no `timeout` binary on the captain's laptop (it silently becomes
    "command not found"), so the cage is here: a new session per step, and
    killpg — a child that outlived its parent is how a look became a hang.
    """
    try:
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, start_new_session=True)
    except Exception as exc:
        return None, "", "xo-run: could not start %r: %s" % (argv[:1], exc), False
    # REGISTERED so a dying look can reap it. Its own group survives the look's
    # death by design (see `_STEP_GROUPS`), which is how an orphan was left.
    pgid = None
    try:
        pgid = os.getpgid(p.pid)
        _STEP_GROUPS.add(pgid)
    except Exception:
        pass
    try:
        out, err = p.communicate(timeout=timeout)
        return p.returncode, out.decode("utf-8", "replace"), \
            err.decode("utf-8", "replace"), False
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(p.pid), signal.SIGKILL)
        except Exception:
            pass
        out, err = b"", b""
        try:
            out, err = p.communicate(timeout=10)
        except Exception:
            pass
        return None, out.decode("utf-8", "replace"), \
            err.decode("utf-8", "replace"), True
    finally:
        # A finished child's group is forgotten, so a later teardown never
        # signals a group the OS has since handed to somebody else.
        if pgid is not None:
            _STEP_GROUPS.discard(pgid)


def write_evidence(outdir, name, transcript, readout):
    """Both artifacts for one step — and the ONE door every one of them goes
    through, which is why the scrub (S249) lives here and not at each call site.
    A credential the product itself printed is replaced by `<redacted>` in the
    transcript AND in the readout, and the readout says how many times."""
    os.makedirs(outdir, exist_ok=True)
    base = os.path.basename(name or "99-step.txt")
    stem = os.path.splitext(base)[0]
    transcript, n_txt = scrub(transcript)
    clean, n_json = scrub_json(readout)
    # IN PLACE, so the caller's own copy of the readout is the scrubbed one too —
    # it journals off this dict, and a second cleaned copy is a second thing to
    # remember to clean.
    readout.clear()
    readout.update(clean)
    if n_txt or n_json:
        readout["redactions"] = int(readout.get("redactions") or 0) + n_txt + n_json
    txt = os.path.join(outdir, stem + ".txt")
    blob = transcript.encode("utf-8")
    with open(txt, "wb") as fh:
        fh.write(blob)
    jsn = os.path.join(outdir, stem + ".json")
    readout["evidence"] = os.path.basename(txt)
    readout["readout"] = os.path.basename(jsn)
    # ── AND WHAT WAS IN IT WHEN WE WROTE IT (S264 fix round 2, FIX 6) ────────
    #
    # MEASURED BY THE FIX-ROUND-1 TESTER: a transcript the harness really did
    # record producing could be CLOBBERED afterwards — overwrite the `.txt`,
    # leave the sibling readout untouched, and the over-claiming guard still
    # read the readout as proof that a run produced this content. The readout
    # proved "the harness wrote a file at this path", never "a run produced
    # these bytes".
    #
    # So the producer records the bytes it wrote: their length and their digest,
    # taken from the exact blob that just went to disk. A reader can then ask
    # whether the file it is holding is the one the run produced. This is a
    # RECORD CHECK, not a judgement about the text — nothing here reads what the
    # transcript says, which is the infer-vs-record line (S147, S156, S188).
    readout["bytes"] = len(blob)
    readout["sha256"] = hashlib.sha256(blob).hexdigest()
    with open(jsn, "w", encoding="utf-8") as fh:
        json.dump(readout, fh, indent=2)
        fh.write("\n")
    return txt, jsn


# ===========================================================================
# THE THREE KINDS
# ===========================================================================
def do_run(step, worktree, home, outdir, live=None, live_env=None, consent=None):
    argv = [str(a) for a in resolve(step.get("argv") or [], worktree, home)]
    cwd = resolve(step.get("cwd") or WORKTREE_MARK, worktree, home)
    stripped = []
    env = step_env(resolve(step.get("env") or {}, worktree, home), home,
                   live_env=live_env, stripped=stripped)
    # The declared HOME is kept only when it is one of the look's own marks
    # (S246 — `refuse_reason` has already refused anything else); otherwise the
    # look's first HOME stands in, so a step can never run as the captain.
    if not any(inside(h, env.get("HOME", "")) for h in allowed_homes(home)):
        env["HOME"] = home
    env["TMPDIR"] = os.path.join(env["HOME"], "tmp")
    os.makedirs(env["TMPDIR"], exist_ok=True)
    rc, out, err, hung = run_cmd(argv, cwd, env, STEP_TIMEOUT)
    met, checks = verdict(step.get("expect"), exit_code=rc, stdout=out,
                          stderr=err, worktree=worktree)
    if hung:
        # A TIMEOUT IS NOT A RED TEST (the honesty rule already won, S211).
        met = None
    # WHAT THE STEP RAN WITH, SAID OUT LOUD AND REDACTED (S249). The captain has
    # to be able to tell "it published for real" from "it published to nothing",
    # and the only honest way to show a credential was present is to show the NAME
    # with the value replaced. `GH_TOKEN=<redacted>` is the record.
    live_line = ""
    if live_env:
        live_line = "(live: %s)\n" % ", ".join(
            "%s=%s" % (k, "<redacted>" if k in CRED_ENV_KEYS and k != "GH_HOST" else v)
            for k, v in sorted(live_env.items()))
    stripped_line = ""
    if stripped:
        stripped_line = ("(stripped from the step's own env, a credential is the "
                         "harness's to add: %s)\n" % ", ".join(sorted(stripped)))
    transcript = ("$ %s\n(cwd: %s)\n(HOME: %s)\n%s%s\n--- stdout ---\n%s\n"
                  "--- stderr ---\n%s\n--- exit: %s ---\n"
                  % (" ".join(argv), cwd, env["HOME"], live_line, stripped_line,
                     out, err,
                     "killed after %ss" % STEP_TIMEOUT if hung else rc))
    readout = {"do": "run", "key": step.get("key") or "", "for": step.get("for") or "",
               "fromChecklist": step.get("fromChecklist") or "",
               "checkedBy": CHECKED_BY["run"], "argv": argv, "cwd": cwd,
               "worktree": worktree, "home": env["HOME"],
               "exit": rc, "hung": hung, "stdout": out, "stderr": err,
               "expect": step.get("expect") or {}, "checks": checks, "met": met}
    # THE SECOND LAPTOP IS ON THE RECORD (S246). Without this the captain reads
    # two transcripts of "no records yet" and has no way to tell a second actor
    # from a product that stores nothing at all.
    for mark in EXTRA_HOME_MARKS:
        path = _EXTRA_HOMES.get(mark)
        if path and inside(path, env["HOME"]):
            readout["home2"] = path
            readout["homeMark"] = mark
            break
    # THE CREDENTIAL KEYS THIS STEP ASKED FOR AND DID NOT GET — on the record, so
    # a worker reading its own readout learns the rule instead of guessing.
    if stripped:
        readout["strippedEnv"] = sorted(stripped)
    # AND WHO SAID YES. The host, the owner, the file the consent was read from,
    # and the credential as a NAME with no value — which is the whole shape of
    # this session: the reach is on the record, the secret is not.
    if live:
        readout["live"] = {
            "host": live["host"], "owner": live["owner"], "repo": live["repo"],
            "consentedBy": (consent or {}).get("source") or "",
            "credential": "GH_TOKEN=<redacted>" if (live_env or {}).get("GH_TOKEN")
                          else "GH_TOKEN=<none looked up>",
            "env": {k: ("<redacted>" if k in CRED_ENV_KEYS and k != "GH_HOST" else v)
                    for k, v in (live_env or {}).items()},
            "effects": live_effects_of(step, live, consent or {}),
        }
    return transcript, readout


def do_read(step, worktree, home, outdir):
    path = resolve(step.get("path") or "", worktree, home)
    if not os.path.isabs(path):
        path = os.path.join(worktree, path)
    content, why = "", ""
    if os.path.isdir(path):
        try:
            content = "\n".join(sorted(os.listdir(path)))
        except Exception as exc:
            why = str(exc)
    else:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                content = fh.read()
        except Exception as exc:
            why = str(exc)
    met, checks = verdict(step.get("expect"), content=content, worktree=worktree)
    if why:
        # NOT THERE IS A RECORD, NOT A PASS. "deploy succeeded" is the thing
        # this item exists to stop being believed.
        met = False
        checks.append({"key": "readable", "mechanical": True, "want": path,
                       "got": why, "passed": False})
    transcript = ("$ read %s\n\n--- content ---\n%s\n"
                  % (path, content if content else "(not readable: %s)" % why))
    readout = {"do": "read", "key": step.get("key") or "", "for": step.get("for") or "",
               "fromChecklist": step.get("fromChecklist") or "",
               "checkedBy": CHECKED_BY["read"], "path": path,
               "worktree": worktree, "home": home, "content": content,
               "unreadable": why, "expect": step.get("expect") or {},
               "checks": checks, "met": met}
    return transcript, readout


def do_workflow(step, worktree, home, outdir, mission_dir):
    """Executed by S234's `workflow-run` — the ONE real runner, not a copy.

    It runs the job's steps the way CI runs them (the step's own command, from
    the step's own cwd) and NAMES THE FIRST FAILING STEP, which is the line that
    caught `python3 pkg/render.py` on the modelled weekend.
    """
    wf = resolve(step.get("file") or "", worktree, home)
    if not os.path.isabs(wf):
        wf = os.path.join(worktree, wf)
    argv = ["bash", ECH, "workflow-run", "-", wf, "--root", worktree,
            "--evidence-dir", outdir,
            "--evidence", os.path.basename(step.get("evidence") or "02-workflow-run.txt")]
    if step.get("job"):
        argv += ["--job", str(step["job"])]
    env = step_env({}, home)
    env["LCARS_ECH_CWD"] = worktree
    rc, out, err, hung = run_cmd(argv, worktree, env, STEP_TIMEOUT)
    first = ""
    # ── WHAT THE LOCAL RUNNER DID NOT RUN, WRITTEN DOWN (S250 fix round 1, D1)
    #
    # THE MEASURED DEFECT. `workflow-run` executes `run:` steps only; a packaged
    # `uses:` action is printed as `SKIP: … It is UNPROVEN, not passed.` and the
    # tail says `(1 run, 2 skipped)`. On the S250 live drive the SAME transcript
    # settled two criteria about the same push: one row read UNTESTED because the
    # look read that notice, and one read MET because it did not. The notice was
    # therefore a fact nobody could enforce — it lived in prose only.
    #
    # So it is recorded here, as a FIELD, beside the exit code: the labels of the
    # steps this run did not execute. `xo-score.py` reads it and refuses to let a
    # local stand-in settle a row whose proof it skipped. Read the SAME way
    # `firstFailingStep` has always been read — by the runner's own line prefixes,
    # off its own output — not by interpreting anybody's English.
    unproven, label = [], ""
    for line in (out or "").splitlines():
        if line.startswith(WF_STEP) and ": " in line:
            label = line.split(": ", 1)[1].strip()
        elif line.startswith(WF_SKIP):
            # EXACTLY the runner's own two-space notice. A step's OWN output is
            # printed four spaces in, so a build that prints the word "SKIP:"
            # itself can never be mistaken for a step the runner declined.
            unproven.append(label or line[len(WF_SKIP):].strip())
        elif line.startswith("FIRST FAILING STEP: "):
            first = line[len("FIRST FAILING STEP: "):].strip()
            break
    met = None if hung else (rc == 0)
    transcript = out if out else ("$ %s\n%s\n" % (" ".join(argv), err))
    readout = {"do": "workflow", "key": step.get("key") or "",
               "for": step.get("for") or "",
               "fromChecklist": step.get("fromChecklist") or "",
               "checkedBy": CHECKED_BY["workflow"], "file": wf,
               "job": step.get("job") or "", "worktree": worktree, "home": home,
               "exit": rc, "hung": hung, "firstFailingStep": first,
               "unproven": unproven, "skippedSteps": len(unproven),
               "stdout": out, "stderr": err,
               "expect": step.get("expect") or {}, "checks": [], "met": met}
    return transcript, readout


# ===========================================================================
# run — the whole walk beyond the browser, in one caged pass
# ===========================================================================
def cmd_run(opt):
    journey_path = opt("journey")
    outdir = opt("out")
    repo = os.path.abspath(opt("repo") or ".")
    branch = opt("branch") or ""
    mission_dir = opt("mission-dir") or ""
    if not journey_path or not outdir:
        sys.stderr.write("xo-run.py run: --journey and --out are required\n")
        return 2
    journey = load(journey_path, {}) or {}
    steps = [s for s in (journey.get("reachSteps") or []) if isinstance(s, dict)]
    if not steps:
        say("◈ nothing in the record declared a step beyond the browser.")
        return 0
    if not branch:
        sys.stderr.write("xo-run.py run: --branch is required — a step runs in a "
                         "DETACHED worktree of the mission's branch, never in "
                         "the checked-out tree\n")
        return 2

    # ONE TREE AND ONE HOME FOR THE WHOLE LOOK (S246). When the caller has
    # already prepared them — `xo.sh evaluate` does, once, before the first
    # round — they are handed in and this process neither mints nor removes
    # them. That is what lets a worker file a record in round 1 and read it
    # back in round 2: the state it wrote is still there.
    #
    # Minting its own is the FALLBACK, for the callers that are genuinely one
    # process long (recheck, and every unit test that drives this file head-on).
    worktree = opt("worktree") or ""
    home = opt("home") or ""
    owned = not (worktree and home and os.path.isdir(worktree))
    if owned:
        pair, why = prepare(repo, branch)
        if pair is None:
            say("◈ I could not reach past the browser: %s" % why)
            journal(mission_dir, "reach-refused", {"why": why, "branch": branch})
            return 3
        worktree, home = pair
        # BEFORE the first step: a `finally` does not run on a signal, and a look
        # that was killed left a REGISTERED worktree in the captain's repo.
        arm_teardown(repo, worktree, home)
    else:
        # The step children are still this process's to reap on a signal, even
        # though the tree is not this process's to remove.
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            try:
                signal.signal(sig, _reap_and_exit)
            except Exception:
                pass
    say("◈ %d declared step(s), in a detached worktree of %s" % (len(steps), branch))
    say("  worktree: %s" % worktree)
    say("  HOME:     %s (throwaway)" % home)

    # `declined` counts steps THIS FILE refused to execute — an escape attempt,
    # or a kind the harness does not run. It is the ONLY refusal there is now
    # (S247): nothing instantiates steps from the record any more, so there is no
    # second class of "items I could not build" to be confused with it.
    reached = declined = 0
    # THE CONSENT RECORD, READ ONCE, FROM DISK (S249). Not from the environment and
    # not from the journey: the only thing that can say yes to a live host is the
    # file the captain wrote. An empty record refuses every live step, by name.
    ldir = lcars_dir(repo, mission_dir)
    consent = load_consent(ldir)
    live_doc = load_live(mission_dir)
    live_doc["consent"] = {k: consent[k] for k in ("host", "owners", "repos", "source")}
    live_doc["recordedIn"] = ldir
    # ── AN EMPTY LIVE LEDGER IS STILL A LEDGER (S250 fix round 1, D4) ───────
    #
    # THE MEASURED DEFECT. `live_touched` only went True when a step DECLARED a
    # `live:` block, so the S250 drive — which had the captain's written consent,
    # printed it to the console every round, and then took zero live hops — wrote
    # no `xo/live.json` at all. The report's "What I touched live" section
    # therefore VANISHED instead of saying "nothing", and no teardown, and no
    # reader, could tell "it reached nothing" from "nobody ever asked it to".
    #
    # So the ledger is opened by the CONSENT, which is a record the captain wrote,
    # and not by the first step that happens to use it. Consent with no live step
    # behind it is exactly the fact worth writing down.
    live_touched = bool(consent.get("host"))
    live_doc["liveSteps"] = int(live_doc.get("liveSteps") or 0)
    if consent.get("host"):
        say("  live:     %s, owners: %s (consented in %s)"
            % (consent["host"], ", ".join(consent["owners"]), consent["source"]))
    try:
        for step in steps[:MAX_ACTIONS]:
            kind = str(step.get("do") or "")
            name = os.path.basename(step.get("evidence") or ("%s.txt" % (step.get("key") or kind)))
            # BEFORE THE FENCE READS IT: a step that asked for a second laptop
            # gets one minted, so `refuse_reason` is judging a real directory
            # rather than an unresolved mark it would have to refuse.
            ensure_extra_homes(step, home)
            why = refuse_reason(step, worktree, home)
            # THE CONSENT GATE, AFTER THE ARGV FENCE AND NEVER INSTEAD OF IT. A
            # step that asked for a shell is refused for being a shell whatever the
            # record says; only a step the old fence already allows is asked
            # whether anybody consented to the host it names.
            live = live_block(step) if kind == "run" else None
            live_env = None
            if not why and live:
                live_touched = True
                live_doc["liveSteps"] = int(live_doc.get("liveSteps") or 0) + 1
                why = live_refusal(live, consent)
                if not why:
                    tok = live_token(live["host"])
                    if tok:
                        live_env = {"GH_HOST": live["host"], "GH_TOKEN": tok,
                                    "LCARS_XO_LIVE": "1"}
                    else:
                        # NOT A SILENT UNAUTHENTICATED RUN. A consented step with no
                        # credential behind it would reach the host as nobody and
                        # read as a product failure, which is the "green but wrong"
                        # class this whole round exists to close.
                        why = ("%s: I have no credential for %s — `gh auth token "
                               "-h %s` returned nothing, so the step was not run"
                               % (NEEDS_LIVE, live["host"], live["host"]))
                if why:
                    live_doc["refused"].append(
                        {"criterion": str(step.get("for") or ""),
                         "step": str(step.get("key") or ""),
                         "host": live["host"], "owner": live["owner"],
                         "repo": live["repo"], "why": why, "evidence": name,
                         "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
            if why or kind not in REACH_KINDS:
                why = why or "`%s` is not a step the harness executes" % kind
                declined += 1
                write_evidence(outdir, name,
                               "REFUSED: %s\n\nThe command was NOT run.\n" % why,
                               {"do": kind, "key": step.get("key") or "",
                                "for": step.get("for") or "",
                                "fromChecklist": step.get("fromChecklist") or "",
                                "refused": True, "why": why,
                                "worktree": worktree, "home": home, "met": None})
                journal(mission_dir, "step-refused",
                        {"step": step.get("key") or "", "kind": kind, "why": why,
                         "evidence": name})
                say("  REFUSED %s — %s" % (name, why))
                continue
            if kind == "run":
                transcript, readout = do_run(step, worktree, home, outdir,
                                             live=live, live_env=live_env,
                                             consent=consent)
                # LEDGERED ONLY ONCE IT RAN. A refused step created nothing, so
                # nothing it declared belongs on the list a teardown works from.
                for eff in ((readout.get("live") or {}).get("effects") or []):
                    eff = dict(eff)
                    eff["evidence"] = name
                    live_doc["effects"].append(eff)
            elif kind == "read":
                transcript, readout = do_read(step, worktree, home, outdir)
            else:
                transcript, readout = do_workflow(step, worktree, home, outdir,
                                                  mission_dir)
            write_evidence(outdir, name, transcript, readout)
            reached += 1
            journal(mission_dir, "step-ran",
                    {"step": readout["key"], "kind": kind,
                     "checkedBy": readout["checkedBy"], "met": readout["met"],
                     "for": readout["for"], "evidence": name})
            say("  %s %s (%s)" % ("ran" if readout["met"] is not False else "FAILED",
                                  name, readout["checkedBy"]))
    finally:
        # THE LEDGER IS WRITTEN WHATEVER HAPPENED, before the tree goes away: a
        # look that died after creating a branch on a real host is exactly the look
        # whose list somebody needs.
        if live_touched:
            where = save_live(mission_dir, live_doc)
            if where:
                n = len(live_doc.get("effects") or [])
                if n or live_doc.get("liveSteps"):
                    say("◈ %d live effect(s) on the record in %s" % (n, where))
                else:
                    # SAID OUT LOUD, NOT LEFT BLANK (S250 D4). Consent was on the
                    # record and not one step asked to use it — which is the thing
                    # the console went quiet about for six rounds.
                    say("◈ nothing was touched live: %s was consented and no step "
                        "asked to reach it. The empty ledger is in %s."
                        % (consent.get("host") or "a live host", where))
        if owned:
            teardown(repo, worktree, home)
    if owned:
        say("◈ %d declared step(s) reached, %d declined at execution; the worktree "
            "and its HOME are gone." % (reached, declined))
    else:
        # THE TREE STAYS UP BETWEEN ROUNDS (S246), and the line says so, because
        # "the worktree and its HOME are gone" was the sentence a reader used to
        # conclude that nothing could carry from one round to the next.
        say("◈ %d declared step(s) reached, %d declined at execution; the look's "
            "worktree and HOME are still standing for the next round."
            % (reached, declined))
    return 0


# ===========================================================================
# prepare / teardown — the LOOK's own tree and HOME, minted ONCE (S246)
# ===========================================================================
# WHY THESE ARE SUBCOMMANDS AND NOT A SECOND HELPER IN xo.sh. `prepare()` above
# is the ONE road to `ech.sh worktree` and `teardown()` is the ONE road
# back; a look that minted its tree with its own shell would be the second
# implementation this file's header refuses. So `xo.sh evaluate` calls these.
def cmd_prepare(opt):
    repo = os.path.abspath(opt("repo") or ".")
    branch = opt("branch") or ""
    if not branch:
        sys.stderr.write("xo-run.py prepare: --branch is required — a look runs "
                         "in a DETACHED worktree of the mission's branch\n")
        return 2
    pair, why = prepare(repo, branch)
    if pair is None:
        sys.stderr.write("xo-run.py prepare: %s\n" % why)
        return 3
    worktree, home = pair
    # The SAME two lines `ech.sh worktree` prints, so there is one shape to
    # parse wherever a caller reads this back.
    say("WORKTREE: %s" % worktree)
    say("HOME: %s" % home)
    return 0


def cmd_consent(opt):
    """What the RECORD consents to, printed for the prompt — one reader, not two.

    `xo.sh` needs to tell the worker what is consented, and the one thing that must
    never happen is a second place that decides it. So the shell asks THIS file,
    which is the file that will refuse the step, and prints what it is handed:

        HOST: github.com
        OWNERS: roferg
        SOURCE: autopilot.json liveTargets

    Nothing at all when the record is empty, which is what "no consent" looks like
    everywhere else in this file too.
    """
    repo = os.path.abspath(opt("repo") or ".")
    ldir = opt("lcars-dir") or lcars_dir(repo, opt("mission-dir") or "")
    c = load_consent(ldir)
    if not c.get("host"):
        return 0
    say("HOST: %s" % c["host"])
    say("OWNERS: %s" % ", ".join(c["owners"]))
    if c.get("repos"):
        say("REPOS: %s" % ", ".join(c["repos"]))
    say("SOURCE: %s" % c["source"])
    return 0


def cmd_teardown(opt):
    repo = os.path.abspath(opt("repo") or ".")
    worktree = opt("worktree") or ""
    home = opt("home") or ""
    teardown(repo, worktree, home)
    say("◈ the look's worktree and its throwaway HOME(s) are gone.")
    return 0


# ===========================================================================
# actions — what the WORKER asked for, under the SAME cap
# ===========================================================================
def declared_escape(step, kind=None, copy=""):
    """Why a REQUESTED step may not be kept, judged on its DECLARED form.

    Without a `copy` there is no worktree yet when a worker's round is read, so
    the check is on the text: a cwd or path that is absolute, or that walks up
    out of the tree, is refused. `<worktree>` and a plain relative path are the
    only forms that can be honoured.

    `copy` IS THE LOOK'S OWN STANDING TREE, AND IT IS A PLACE TO STAND (S261 fix
    round 1). MEASURED: on the first live look with a shell, SIX declared steps
    were refused before they ran — `REFUSED (run): cwd
    /private/tmp/.../lcars-ap-wt-6SnDQN is an absolute path outside the
    worktree` — because the prompt tells the worker, by absolute path, the
    disposable copy it is standing in, and it then quite reasonably named that
    path as the step's `cwd`. The report said "I asked for 6 steps that the
    harness refused before they ran." The tree was the look's own; nothing was
    escaping anywhere. `refuse_reason` — the gate that judges the SAME step once
    the tree is real — has always accepted it, so this gate was the only thing in
    the way.

    SO IT IS A PATH CHECK THAT LEARNED ONE PLACE, NOT AN OPENING OF THE ARGV
    FENCE. The copy must be a DIRECTORY THAT EXISTS (a promised one grants
    nothing, the same rule the shell itself is held to), and the only thing it
    buys is: an absolute `cwd`/`path`/`file` that really resolves INSIDE it reads
    as the `<worktree>` mark would. Everything else is byte-for-byte unchanged —
    no shell, no interpreter with `-c`, no absolute path in the argv, no `..`,
    and no absolute path anywhere but inside that one tree.

    THE SAME ARGV FENCE AS THE JOURNEY GATE. A worker asked for `["bash","-c",…]`
    and it was KEPT into reachSteps; a step is now refused whether it was
    declared in the journey or requested by the worker.

    THE FENCE JUDGES THE VERB THE GATE RESOLVED (S257 fix round 1). This line
    read `step["do"] == "run"` while `action_kind` had just been widened to read
    the verb off the step's KEY — the action schema is `{"click": "#sel"}`, not
    `{"do": "click"}` — so a REACH verb written in key form reached this gate
    with its kind resolved and then skipped the argv check entirely:

        {"do":  "run", "argv": ["sh","-c","echo PWNED"]}  → refused
        {"run": "x",   "argv": ["sh","-c","echo PWNED"]}  → KEPT

    Nothing ever ran — `cmd_journey` refuses a key-form step outright — so it
    was a FALSE RECORD, which is the fault class this session exists to close:
    the ledger and the console said a shell request had been GRANTED, the
    refusal stopped naming the shell, and the 12-action cap counted it as spent.
    So the kind is whatever the gate resolved, `do` or key, and the argv fence
    is applied to EVERY reach verb that carried an argv. Nothing about
    `argv_refusal` or the refusal sentences moved: they were simply unreachable.
    """
    if kind is None:
        kind, _named = action_kind(step)
    kind = str(kind or "")
    # `run` is always argv-judged (an empty argv is itself a refusal: a run step
    # names the program it runs). `workflow` and `read` name a file, not a
    # program, so they are judged only when they DID carry an argv — which is
    # the shape the hole above was walked through.
    if kind == "run" or (kind in REACH_KINDS and step.get("argv")):
        why = argv_refusal(step.get("argv") or [])
        if why:
            return why
    for key in ("cwd", "path", "file"):
        v = step.get(key)
        if v is None:
            continue
        v = str(v)
        if v in (WORKTREE_MARK, ""):
            continue
        rest = v.replace(WORKTREE_MARK, "").lstrip("/")
        if os.path.isabs(v):
            # The look's own copy, and nothing wider. `inside` resolves symlinks,
            # so `<copy>/../..` spelled absolutely does not slip through here any
            # more than it does at run time.
            if copy and os.path.isdir(copy) and inside(copy, v):
                continue
            return "%s %s is an absolute path outside the worktree" % (key, v)
        if ".." in rest.split("/"):
            return "%s %s walks up out of the worktree" % (key, v)
    env = step.get("env") or {}
    if isinstance(env, dict) and env.get("HOME"):
        h = str(env["HOME"])
        # S246 — a SECOND actor is allowed, an arbitrary HOME is not. The marks
        # are the only honourable form; `/Users/somebody-else` still never gets
        # past this gate, which is the control the suite keeps beside this line.
        if not any(h == m or h.startswith(m)
                   for m in (HOME_MARK,) + EXTRA_HOME_MARKS):
            return "env HOME %s is not the throwaway HOME" % h
    return ""


# ── A REFUSAL THE NEXT ROUND CAN ACT ON (S264 change 1) ─────────────────────
#
# THE MEASURED DEFECT. Over one milestone's five rounds the worker asked for 36
# steps and 34 were refused — and all five assembled prompts were pulled off
# disk and diffed: round 1 is 61,740 bytes, rounds 2-5 are 61,845 each, and
# round 1 vs round 5 differ ONLY in the round number in two paths and the list
# of files now present. "a step has no shell" appears 0 times. "declined": 0.
# "previous round": 0. The reviewer changed shape in round 5 BY INFERENCE, the
# single signal being that its own evidence directory was still nearly empty,
# and all 22 criteria on that milestone ended up citing the SAME transcript.
#
# The refusals were always RECORDED — `{"kind": ..., "why": ...}` here, carried
# onto `journey.json.refusedSteps` by `xo-journey.py reach-record`, printed by
# `xo_say_refusals`. What the record could not say was WHICH STEP: the worker
# names its steps (`key`) and says which criterion each is for (`for`), and
# neither reached the record, so nothing downstream could tell the reviewer
# "the step you called `suite-verbose` did not run". So the producer records
# them, HERE, at the moment it refuses — never read back out of a finished
# transcript, which is the infer-vs-record failure that cost S147, S156 and
# S188 whole rounds each.
#
# THIS CHANGES WHAT IS REPORTED AND NOTHING ABOUT WHAT IS ALLOWED. The verdict
# is `declared_escape`'s, unchanged and unconsulted here; `argv_refusal`,
# `refuse_reason` and `_shell_refusal` are untouched.
def refusal_row(step, kind, why):
    """The record of ONE refused step: what was asked, in the worker's own
    words for it, and the one sentence saying why it will not run."""
    row = {"kind": str(kind or ""), "why": why}
    # WHATEVER THE WORKER LABELLED IT WITH (S264 fix round 1, FIX 2). MEASURED
    # on the one live look: the refusal section said "an unnamed run step" FOUR
    # TIMES, because the real worker labels its steps with `evidence`
    # (`seed-01-add-exercise.txt`) — the very field `cmd_run` derives each
    # transcript's name from — and only `key` was carried. The headline promise
    # ("the step you called `suite-verbose` did not run") could not be kept on
    # the only live look there was. Both labels are copied verbatim off the step
    # the worker wrote; nothing is reconstructed from a finished transcript.
    for field in ("key", "evidence", "for", "fromChecklist"):
        val = str((step or {}).get(field) or "").strip()
        if val:
            row[field] = val
    # WHAT WAS ASKED FOR, as the worker wrote it — the command line for a `run`,
    # the file for a `read`/`workflow`. One line, so a prompt can print it.
    asked = ""
    argv = (step or {}).get("argv")
    if isinstance(argv, (list, tuple)) and argv:
        asked = " ".join(str(a) for a in argv)
    else:
        for field in ("path", "file"):
            if str((step or {}).get(field) or "").strip():
                asked = str((step or {}).get(field)).strip()
                break
    if asked:
        row["asked"] = " ".join(asked.split())
    # SCRUBBED LIKE EVERY OTHER ARTIFACT (S249): this row is printed into the
    # next round's prompt and journaled, so a credential must not ride it.
    row, _ = scrub_json(row)
    return row


# ── A STEP DROPPED AT THE CAP IS A STEP THAT DID NOT RUN (S264 fix round 1,
#    FIX 3) ─────────────────────────────────────────────────────────────────
#
# MEASURED, DRIVEN LIVE: 14 asked, 12 kept, 2 SILENTLY DROPPED, `refusedSteps`
# = 0. The overflow was recorded as a COUNT in `doc["overflow"]` and nothing
# else, so it reached no prompt and no report: the reviewer could not tell a
# step it must RESHAPE from a step it must simply ask for next round.
#
# So the drop is recorded the same way a refusal is — one row per step, with the
# worker's own label on it — and kept in its OWN list, because a drop and a
# refusal are different facts the reviewer must act differently on. Nothing here
# grants anything: the cap is exactly where it was.
def cap_row(step, kind, cap):
    """The record of ONE step dropped for the cap — not refused on its shape."""
    return refusal_row(step, kind,
                       "the harness runs at most %d step(s) a round and this one "
                       "came after the %dth, so it was DROPPED for the cap — "
                       "nothing about its shape was refused" % (cap, cap))


# ── A STEP THAT WAS KEPT AND THEN NEVER RAN (S266 fix round 2, FIX 1) ───────
#
# THE MEASURED DEFECT, on one real review. `lcars launch` died —
# "Could not start the server on port 8765: [Errno 48] Address already in use"
# — so `xo.sh` set `nopage=1` and skipped every browser leg of the look. The
# reviewer's 11 declared browser steps were recorded `asked: 11, refused: [],
# dropped: [], overflow: 0`: KEPT, and not one of them executed. Nothing was
# refused and nothing was dropped, so the two sections that now reach the next
# round's prompt could not fire, and rounds 2 and 3 still opened by telling the
# reviewer it was looking at pictures. It graded phone-width rows `met` off unit
# tests and recommended MERGE.
#
# This is a THIRD fact, and it needs a third list. A refusal says "reshape the
# request"; a drop says "ask for fewer"; this says "the build never came up —
# nothing you ask for through a browser can run at all this round". Calling it
# a refusal would send the reviewer rewriting a step that was perfectly good.
#
# RECORDED WHERE THE PRODUCER KNOWS IT. `xo.sh` knows the launch failed before
# a single step is classified, and it says so with `--no-page "<why>"`; the row
# is written at the moment the step is kept. Nothing downstream re-derives
# "there were no pictures" from an empty evidence directory — that infer-vs-
# record shortcut is what cost S147, S156 and S188 whole fix rounds each.
#
# NOTHING HERE GRANTS OR WITHHOLDS ANYTHING. The step is still kept, still
# counted against the cap, and `steps` still lists it: the harness really did
# keep it. The only new thing on disk is the record that it did not run.
def unrun_row(step, kind, why):
    """The record of ONE kept browser step that could not run for want of a page."""
    return refusal_row(step, kind,
                       "the build never came up in a browser for this look, so this "
                       "step was KEPT and then never executed and wrote no evidence "
                       "- nothing about its shape was refused (%s)" % why)


def cmd_actions(opt):
    actions = load(opt("actions"), None)
    out = opt("out")
    mission_dir = opt("mission-dir") or ""
    cap = int(opt("cap") or MAX_ACTIONS)
    # THE LOOK'S OWN STANDING COPY, PASSED IN BY THE CALLER THAT MINTED IT
    # (`xo.sh`'s `xo_reach_actions` hands over `$XO_REACH_WT`). Read from argv
    # rather than the environment so the one caller that knows is the one that
    # says, and validated as a real directory here so `declared_escape` is never
    # handed a promise. Absent → the gate judges the declared text exactly as it
    # always did.
    copy = opt("worktree") or ""
    if not (copy and os.path.isdir(copy)):
        copy = ""
    if isinstance(actions, dict):
        actions = actions.get("actions")
    actions = [a for a in (actions or []) if isinstance(a, dict)]
    asked = len(actions)

    # THE LAUNCH'S OWN ANSWER, PASSED IN BY THE CALLER THAT KNOWS IT (S266 fix
    # round 2). Non-empty means `xo.sh` has already decided there is no page
    # this look, so every browser step it keeps below is a step that will not
    # run. Read from argv, never the environment, so the one caller that knows
    # is the one that says.
    nopage_why = " ".join(str(opt("no-page") or "").split())

    kept_browser, kept_reach, refused = [], [], []
    dropped, unrun = [], []
    taken = 0
    for a in actions:
        kind, named = action_kind(a)
        if kind in REACH_KINDS:
            why = declared_escape(a, kind, copy)
            if why:
                refused.append(refusal_row(a, kind, why))
                journal(mission_dir, "action-refused", refusal_row(a, kind, why))
                continue
        elif kind not in BROWSER_KINDS:
            # SAY WHAT WAS REFUSED. A refusal that names nothing is a refusal
            # nobody can act on, and it is how a schema mismatch hid for a
            # whole round of looks.
            why = "%s is not a step kind the harness knows" % named
            row = refusal_row(a, kind, why)
            row["verb"] = named
            refused.append(row)
            journal(mission_dir, "action-refused", dict(row))
            continue
        if taken >= cap:
            # THE OVERFLOW IS RECORDED, never silently granted (S222's rule) —
            # and since S264 it is recorded as ROWS and not only as a count, so
            # it can reach the reviewer the way a refusal now does.
            dropped.append(cap_row(a, kind, cap))
            journal(mission_dir, "action-dropped", dict(dropped[-1]))
            continue
        taken += 1
        (kept_reach if kind in REACH_KINDS else kept_browser).append(a)
        # KEPT, AND — with no page — NEVER GOING TO RUN. Recorded here, beside
        # the decision, and only for the BROWSER steps: a `run`/`read`/
        # `workflow` step reaches a command line and still executes with no
        # page, which is exactly why `xo.sh` keeps calling this on that path.
        if nopage_why and kind in BROWSER_KINDS and kind not in REACH_KINDS:
            unrun.append(unrun_row(a, kind, nopage_why))
            journal(mission_dir, "action-unrun", dict(unrun[-1]))

    doc = {"asked": asked, "cap": cap, "steps": kept_browser,
           "reachSteps": kept_reach, "refused": refused, "dropped": dropped,
           "unrun": unrun,
           "overflow": max(0, asked - len(refused) - taken)}
    if nopage_why:
        doc["noPage"] = nopage_why
    if out:
        os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
    journal(mission_dir, "actions-capped",
            {"asked": asked, "cap": cap, "kept": taken, "refused": len(refused)})
    say("%d asked, %d kept (cap %d), %d refused, %d over the cap%s"
        % (asked, taken, cap, len(refused), doc["overflow"],
           (", %d kept but NOT RUN (no page)" % len(unrun)) if unrun else ""))
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__.split("WHY THIS FILE")[0])
        return 2
    cmd = argv[1]

    def opt(name, default=None):
        try:
            return argv[argv.index("--" + name) + 1]
        except (ValueError, IndexError):
            return default

    if cmd == "run":
        return cmd_run(opt)
    if cmd == "actions":
        return cmd_actions(opt)
    if cmd == "prepare":
        return cmd_prepare(opt)
    if cmd == "teardown":
        return cmd_teardown(opt)
    if cmd == "consent":
        return cmd_consent(opt)
    sys.stderr.write("xo-run.py: unknown command: %s "
                     "(want: run | actions | prepare | teardown | consent)\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
