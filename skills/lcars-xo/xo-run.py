#!/usr/bin/env python3
"""xo-run.py — RUN the declared steps a browser was never going to reach (S239).

    python3 xo-run.py run      --journey <journey.json> --out <shots-dir>
                               --repo <repo> --branch <branch> --mission-dir <dir>
                               [--worktree <wt> --home <home>]
    python3 xo-run.py actions  --actions <xo-actions.json> --out <kept.json>
                               --mission-dir <dir> [--cap 12]
    python3 xo-run.py prepare  --repo <repo> --branch <branch>
    python3 xo-run.py teardown --repo <repo> --worktree <wt> --home <home>

ONE TREE AND ONE HOME FOR THE WHOLE LOOK (S246). `prepare` mints them once,
`run --worktree … --home …` reuses them for every round, and `teardown` removes
them at the end of the look. Without that, every `run` minted its own and a
worker could not file a record in round 1 and read it back in round 2 — which is
most of what the captain's buddy does by hand. Given no `--worktree/--home`,
`run` still mints and removes its own, for the callers that really are one
process long (recheck, and the unit tests that drive this file head-on).

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
# A SECOND ACTOR IS A SECOND HOME (S246). The cli checklist's item 4 — "two
# actors, two HOMEs, two laptops" — was the one item a single HOME could never
# instantiate, and the buddy does it by hand every time. A step may now declare
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
# prompts/evaluate.md says in bold "You have no shell, and you are not getting
# one." — this is the code that makes that sentence true.
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
    # THE SECOND LAPTOP IS ON THE RECORD (S246). Without this the captain reads
    # two transcripts of "no records yet" and has no way to tell a second actor
    # from a product that stores nothing at all.
    for mark in EXTRA_HOME_MARKS:
        path = _EXTRA_HOMES.get(mark)
        if path and inside(path, env["HOME"]):
            readout["home2"] = path
            readout["homeMark"] = mark
            break
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
    try:
        for step in steps[:MAX_ACTIONS]:
            kind = str(step.get("do") or "")
            name = os.path.basename(step.get("evidence") or ("%s.txt" % (step.get("key") or kind)))
            # BEFORE THE FENCE READS IT: a step that asked for a second laptop
            # gets one minted, so `refuse_reason` is judging a real directory
            # rather than an unresolved mark it would have to refuse.
            ensure_extra_homes(step, home)
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
# is the ONE road to `autopilot.sh worktree` and `teardown()` is the ONE road
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
    # The SAME two lines `autopilot.sh worktree` prints, so there is one shape to
    # parse wherever a caller reads this back.
    say("WORKTREE: %s" % worktree)
    say("HOME: %s" % home)
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
def declared_escape(step):
    """Why a REQUESTED step may not be kept, judged on its DECLARED form.

    There is no worktree yet when a worker's round is read, so the check is on
    the text: a cwd or path that is absolute, or that walks up out of the tree,
    is refused. `<worktree>` and a plain relative path are the only forms that
    can be honoured.

    THE SAME ARGV FENCE AS THE JOURNEY GATE. A worker asked for `["bash","-c",…]`
    and it was KEPT into reachSteps; a step is now refused whether it was
    declared in the journey or requested by the worker.
    """
    if str(step.get("do") or "") == "run":
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
    if cmd == "prepare":
        return cmd_prepare(opt)
    if cmd == "teardown":
        return cmd_teardown(opt)
    sys.stderr.write("xo-run.py: unknown command: %s "
                     "(want: run | actions | prepare | teardown)\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
