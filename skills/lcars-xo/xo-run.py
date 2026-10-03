#!/usr/bin/env python3
"""xo-run.py — RUN the declared steps a browser was never going to reach (S239).

    python3 xo-run.py run     --journey <journey.json> --out <shots-dir>
                              --repo <repo> --branch <branch> --mission-dir <dir>
    python3 xo-run.py actions --actions <xo-actions.json> --out <kept.json>
                              --mission-dir <dir> [--cap 12]

WHY THIS FILE EXISTS — THE MEASUREMENT, NOT A HUNCH.
On the Canvas weekend (26–29 Sep 2026), same product, 34 runs: Number One filed
0 of 31 bugs; the captain's buddy found all 31. All 16 of Number One's recorded
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
autopilot round's own helper — `autopilot.sh worktree --branch <br>` (wt_prepare)
— because a second implementation of "detach a worktree" is a second thing that
can be subtly wrong, and the buddy and Number One must be checking the same
tree. The workflow kind is likewise executed by `autopilot.sh workflow-run`, the
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

DEPENDENCIES ARE ENV-INJECTED (the lcars-init pattern) so tests can stub them:
    LCARS_AUTOPILOT_BIN    autopilot.sh          (default: ../lcars-buddy/)
    LCARS_GIT_BIN          git
    LCARS_XO_STEP_TIMEOUT  seconds per step      (default 120)
"""
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
AUTOPILOT = os.environ.get("LCARS_AUTOPILOT_BIN") or os.path.join(
    SKILLS_DIR, "lcars-buddy", "autopilot.sh")
GIT = os.environ.get("LCARS_GIT_BIN") or "git"

# PER-STEP, NOT PER-RUN. The whole look is already caged by XO_LOOK_TIMEOUT
# (xo.sh); one hung command must not eat that whole budget, because the steps
# after it are the ones nobody has ever reached.
STEP_TIMEOUT = int(os.environ.get("LCARS_XO_STEP_TIMEOUT") or 120)

# ONE CAP ACROSS ALL KINDS (S222's ≤12 per round, unchanged). A worker that
# asked for twenty may never look like it got them, so the overflow is recorded.
MAX_ACTIONS = int(os.environ.get("LCARS_XO_MAX_ACTIONS") or 12)

BROWSER_KINDS = ("click", "type", "gate", "press", "key", "goto", "scroll",
                 "shot", "screenshot", "wait", "hover", "select")
REACH_KINDS = ("run", "workflow", "read")
CHECKED_BY = {"run": "cli", "workflow": "workflow", "read": "test"}

WORKTREE_MARK = "<worktree>"
HOME_MARK = "<throwaway-home>"


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
# THE WORKTREE AND THE THROWAWAY HOME — the autopilot round's own helper
# ===========================================================================
def prepare(repo, branch):
    """(worktree, home) from `autopilot.sh worktree --branch <br>`, or (None, why).

    NOT A SECOND IMPLEMENTATION. `wt_prepare` in autopilot.sh is the one place
    that knows how to detach a worktree and mint a throwaway HOME, and the buddy
    uses it for the very same checklists. If it cannot, this REFUSES rather than
    quietly falling back to the checked-out tree — which is the failure it
    exists to prevent.
    """
    if not os.path.exists(AUTOPILOT):
        return None, ("no autopilot.sh at %s — the worktree helper is the one "
                      "machinery and there is no second one" % AUTOPILOT)
    env = dict(os.environ)
    env["LCARS_AUTOPILOT_CWD"] = repo
    try:
        p = subprocess.run(["bash", AUTOPILOT, "worktree", "--branch", branch],
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


def teardown(repo, worktree, home):
    """Remove what this run started — the line `wt_say` itself prints."""
    if worktree:
        subprocess.run([GIT, "-C", repo, "worktree", "remove", "--force", worktree],
                       capture_output=True, text=True)
        shutil.rmtree(worktree, ignore_errors=True)
    if home:
        shutil.rmtree(home, ignore_errors=True)
    subprocess.run([GIT, "-C", repo, "worktree", "prune"],
                   capture_output=True, text=True)


# ===========================================================================
# RESOLVING AND REFUSING A STEP
# ===========================================================================
def resolve(value, worktree, home):
    if isinstance(value, str):
        return value.replace(WORKTREE_MARK, worktree).replace(HOME_MARK, home)
    if isinstance(value, list):
        return [resolve(v, worktree, home) for v in value]
    if isinstance(value, dict):
        return {k: resolve(v, worktree, home) for k, v in value.items()}
    return value


def refuse_reason(step, worktree, home):
    """The ONE sentence saying why this step may not run, or "".

    Both fences, checked on the RESOLVED paths and never on the declared text,
    because `<worktree>/../..` resolves out and reads as if it stayed in.
    """
    cwd = resolve(step.get("cwd") or WORKTREE_MARK, worktree, home)
    if not inside(worktree, cwd):
        return ("its cwd %s is outside the detached worktree %s — a step never "
                "runs against the mission's checked-out branch" % (cwd, worktree))
    env = resolve(step.get("env") or {}, worktree, home)
    declared_home = str(env.get("HOME") or home)
    if not inside(home, declared_home):
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


def step_env(declared, home):
    """The environment a step runs in — built, not inherited.

    The real HOME never reaches a step. PATH does, because `python3` lives on it
    and a step with no PATH proves only that PATH was missing.
    """
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
           "LANG": os.environ.get("LANG", "C.UTF-8"),
           "HOME": home,
           "TMPDIR": os.path.join(home, "tmp"),
           "LCARS_XO_STEP": "1"}
    os.makedirs(env["TMPDIR"], exist_ok=True)
    for k, v in (declared or {}).items():
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


def write_evidence(outdir, name, transcript, readout):
    os.makedirs(outdir, exist_ok=True)
    base = os.path.basename(name or "99-step.txt")
    stem = os.path.splitext(base)[0]
    txt = os.path.join(outdir, stem + ".txt")
    with open(txt, "w", encoding="utf-8") as fh:
        fh.write(transcript)
    jsn = os.path.join(outdir, stem + ".json")
    readout["evidence"] = os.path.basename(txt)
    readout["readout"] = os.path.basename(jsn)
    with open(jsn, "w", encoding="utf-8") as fh:
        json.dump(readout, fh, indent=2)
        fh.write("\n")
    return txt, jsn


# ===========================================================================
# THE THREE KINDS
# ===========================================================================
def do_run(step, worktree, home, outdir):
    argv = [str(a) for a in resolve(step.get("argv") or [], worktree, home)]
    cwd = resolve(step.get("cwd") or WORKTREE_MARK, worktree, home)
    env = step_env(resolve(step.get("env") or {}, worktree, home), home)
    env["HOME"] = home if not inside(home, env.get("HOME", "")) else env["HOME"]
    rc, out, err, hung = run_cmd(argv, cwd, env, STEP_TIMEOUT)
    met, checks = verdict(step.get("expect"), exit_code=rc, stdout=out,
                          stderr=err, worktree=worktree)
    if hung:
        # A TIMEOUT IS NOT A RED TEST (the honesty rule already won, S211).
        met = None
    transcript = ("$ %s\n(cwd: %s)\n(HOME: %s)\n\n--- stdout ---\n%s\n"
                  "--- stderr ---\n%s\n--- exit: %s ---\n"
                  % (" ".join(argv), cwd, env["HOME"], out, err,
                     "killed after %ss" % STEP_TIMEOUT if hung else rc))
    readout = {"do": "run", "key": step.get("key") or "", "for": step.get("for") or "",
               "fromChecklist": step.get("fromChecklist") or "",
               "checkedBy": CHECKED_BY["run"], "argv": argv, "cwd": cwd,
               "worktree": worktree, "home": env["HOME"],
               "exit": rc, "hung": hung, "stdout": out, "stderr": err,
               "expect": step.get("expect") or {}, "checks": checks, "met": met}
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
    argv = ["bash", AUTOPILOT, "workflow-run", "-", wf, "--root", worktree,
            "--evidence-dir", outdir,
            "--evidence", os.path.basename(step.get("evidence") or "02-workflow-run.txt")]
    if step.get("job"):
        argv += ["--job", str(step["job"])]
    env = step_env({}, home)
    env["LCARS_AUTOPILOT_CWD"] = worktree
    rc, out, err, hung = run_cmd(argv, worktree, env, STEP_TIMEOUT)
    first = ""
    for line in (out or "").splitlines():
        if line.startswith("FIRST FAILING STEP: "):
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
               "stdout": out, "stderr": err,
               "expect": step.get("expect") or {}, "checks": [], "met": met}
    return transcript, readout


# ===========================================================================
# WHAT WAS NEVER BUILT — recorded by xo-journey.py, DELIVERED here (S239 fix 3)
# ===========================================================================
# THE DEFECT THIS CLOSES, observed on a live look at ec9e4c6. The console said
#
#     ◈ 3 declared step(s) reached, 0 refused; the worktree and its HOME are gone.
#
# while `journey.reachUninstantiated` held TEN items on disk, each with a good
# reason. That is not merely silence: `0 refused` is an explicit ALL-CLEAR on
# exactly the question the refusal exists to raise. The word `refused` here has
# always meant a step this file declined to EXECUTE (an escape attempt), so it
# is QUALIFIED on the line below — "declined at execution" — rather than
# redefined underneath the readout field and the journal entry that use it.
#
# AND IT MUST NOT CRY WOLF. `cli#4-8` and `web#4-6` are uninstantiated on EVERY
# healthy mission; a raw "I could not build N items" would fire on every look
# and be ignored inside a week (S212's scar). The split is READ OFF THE RECORD
# — `oneLineFix`, set by xo-journey.py where the one missing fact is one the
# captain can write in a single line — never re-derived from the prose here.
def unbuilt(journey):
    """(items a one-line record edit recovers, items the record cannot supply)."""
    un = [u for u in ((journey or {}).get("reachUninstantiated") or [])
          if isinstance(u, dict)]
    return ([u for u in un if u.get("oneLineFix")],
            [u for u in un if not u.get("oneLineFix")])


BY_DESIGN = ("  (%d further checklist item(s) want a fact the record cannot "
             "supply — a second actor, an owner-not-login pair, a non-default "
             "host, an artifact nobody named. Those go unbuilt on every healthy "
             "mission, by design; there is nothing to fix.)")


def say_unbuilt(journey):
    """The sentence xo-journey.py already wrote, said out loud."""
    fix, rest = unbuilt(journey)
    if fix:
        # One reason covers several items, so it is said once with the items
        # named beside it rather than repeated verbatim per item.
        order, by = [], {}
        for u in fix:
            why = " ".join(str(u.get("why") or "").split())
            if why not in by:
                by[why] = []
                order.append(why)
            by[why].append(str(u.get("item") or "?"))
        say("◈ %d checklist item(s) I could NOT BUILD from this record — one "
            "line in it recovers them:" % len(fix))
        for why in order:
            say("  %s — %s" % (", ".join(by[why]), why))
    if rest:
        say(BY_DESIGN % len(rest))


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
        say_unbuilt(journey)
        return 0
    if not branch:
        sys.stderr.write("xo-run.py run: --branch is required — a step runs in a "
                         "DETACHED worktree of the mission's branch, never in "
                         "the checked-out tree\n")
        return 2

    pair, why = prepare(repo, branch)
    if pair is None:
        say("◈ I could not reach past the browser: %s" % why)
        journal(mission_dir, "reach-refused", {"why": why, "branch": branch})
        return 3
    worktree, home = pair
    say("◈ %d declared step(s), in a detached worktree of %s" % (len(steps), branch))
    say("  worktree: %s" % worktree)
    say("  HOME:     %s (throwaway)" % home)

    # `declined` counts steps THIS FILE refused to execute — an escape attempt,
    # a kind the harness does not run. It is NOT the count of items the record
    # could not instantiate; those never became steps and are said separately,
    # by say_unbuilt below. Calling both "refused" is the false line this fix
    # removes.
    reached = declined = 0
    try:
        for step in steps[:MAX_ACTIONS]:
            kind = str(step.get("do") or "")
            name = os.path.basename(step.get("evidence") or ("%s.txt" % (step.get("key") or kind)))
            why = refuse_reason(step, worktree, home)
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
                transcript, readout = do_run(step, worktree, home, outdir)
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
        teardown(repo, worktree, home)
    say("◈ %d declared step(s) reached, %d declined at execution; the worktree "
        "and its HOME are gone." % (reached, declined))
    say_unbuilt(journey)
    return 0


# ===========================================================================
# actions — what the WORKER asked for, under the SAME cap
# ===========================================================================
def declared_escape(step):
    """Why a REQUESTED step may not be kept, judged on its DECLARED form.

    There is no worktree yet when a worker's round is read, so the check is on
    the text: a cwd or path that is absolute, or that walks up out of the tree,
    is refused. `<worktree>` and a plain relative path are the only forms that
    can be honoured.
    """
    for key in ("cwd", "path", "file"):
        v = step.get(key)
        if v is None:
            continue
        v = str(v)
        if v in (WORKTREE_MARK, ""):
            continue
        rest = v.replace(WORKTREE_MARK, "").lstrip("/")
        if os.path.isabs(v):
            return "%s %s is an absolute path outside the worktree" % (key, v)
        if ".." in rest.split("/"):
            return "%s %s walks up out of the worktree" % (key, v)
    env = step.get("env") or {}
    if isinstance(env, dict) and env.get("HOME"):
        h = str(env["HOME"])
        if h != HOME_MARK and not h.startswith(HOME_MARK):
            return "env HOME %s is not the throwaway HOME" % h
    return ""


def cmd_actions(opt):
    actions = load(opt("actions"), None)
    out = opt("out")
    mission_dir = opt("mission-dir") or ""
    cap = int(opt("cap") or MAX_ACTIONS)
    if isinstance(actions, dict):
        actions = actions.get("actions")
    actions = [a for a in (actions or []) if isinstance(a, dict)]
    asked = len(actions)

    kept_browser, kept_reach, refused = [], [], []
    taken = 0
    for a in actions:
        kind = str(a.get("do") or "")
        if kind in REACH_KINDS:
            why = declared_escape(a)
            if why:
                refused.append({"kind": kind, "why": why})
                journal(mission_dir, "action-refused", {"kind": kind, "why": why})
                continue
        elif kind not in BROWSER_KINDS:
            refused.append({"kind": kind, "why": "not a step kind the harness knows"})
            journal(mission_dir, "action-refused",
                    {"kind": kind, "why": "not a step kind the harness knows"})
            continue
        if taken >= cap:
            # THE OVERFLOW IS RECORDED, never silently granted (S222's rule).
            continue
        taken += 1
        (kept_reach if kind in REACH_KINDS else kept_browser).append(a)

    doc = {"asked": asked, "cap": cap, "steps": kept_browser,
           "reachSteps": kept_reach, "refused": refused,
           "overflow": max(0, asked - len(refused) - taken)}
    if out:
        os.makedirs(os.path.dirname(os.path.abspath(out)) or ".", exist_ok=True)
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
    journal(mission_dir, "actions-capped",
            {"asked": asked, "cap": cap, "kept": taken, "refused": len(refused)})
    say("%d asked, %d kept (cap %d), %d refused, %d over the cap"
        % (asked, taken, cap, len(refused), doc["overflow"]))
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
    sys.stderr.write("xo-run.py: unknown command: %s (want: run | actions)\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
