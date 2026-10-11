#!/usr/bin/env python3
"""xo-tests.py — run the project's OWN test suite, bounded, and record the facts.

    python3 xo-tests.py --out <tests.json> --cwd <worktree> --timeout <secs>
                        --cap <bytes> --command <the repo's testCommand>

WHY THIS EXISTS (S211). Number One acts only through a browser: no API call, no
terminal, no database. So a change with no UI surface is invisible to it, and a
criterion like "batches survive a restart" came back "I could not check this" on
both engines — correct, and useless.

The answer was already in the repo's own config: `testCommand`, the suite the
captain already trusts. **The SKILL runs it and hands the worker the result as
evidence.** "The worker reasons, the skill executes" (captain's ruling
2026-09-11) is untouched for THIS record: the suite is run here and its result
is handed over. S261 gave the look's worker a real shell inside a disposable
copy, so it can run the suite itself too — but what that produces is its own
evidence, not this recorded run, and the over-claiming guard reads only this
one.

WHAT THIS FILE RECORDS, AND WHAT IT DERIVES. Everything at the top of the
output is a FACT this process knew at the moment it ran: the command as it was
given to the shell, the directory it ran in, the child's exit code, whether the
timeout fired, how long it took, how many bytes came back, whether the tail was
cut and at what cap. `outcome` and `verdict` are DERIVED, here, from those
facts and nothing else — never re-read later out of prose. This project has
lost four rounds (S147, S156, S188, S212) to code that parsed back text a human
also writes; the cure every time was to record the decision where it was made.

THE TRAP THIS FILE WAS WRITTEN TO AVOID. `tests/lib/cage.py` — the
obvious thing to reach for — reports a failure and a hang on STDOUT while its
own process exit status stays **0 in all three cases**. Anything wired to a
cage's exit status reads every test run as a pass: a green that means nothing,
on a feature whose whole purpose is to answer what a screenshot cannot. So this
runner propagates the child's status itself, in two places at once:

    exit 0  the suite passed                 outcome: passed
    exit 1  the RUN failed — a red test of    outcome: failed
            the captain's, or a runner that
            never started; the exit code
            does not say which (fix round 1)
    exit 2  it HUNG — infrastructure          outcome: hung
    exit 3  nothing was run                   outcome: no-test-command | no-worktree
    exit 4  the command could not be started  outcome: could-not-run

A HANG IS NEVER A PRODUCT FAILURE. A suite that never finishes says nothing
about the build; it says the tests could not be run. It is reported that way,
in those words, and it never lands a gap against the captain's build.

THE WHOLE SUITE, NOT THE RED GATE'S SLICE. A seeded `testCommand` interpolates
`$LCARS_TESTS_DIR` so the Implement gate can scope it to one ticket's staged
copy. Number One wants the project's own suite entire, so that variable is
removed from the environment before the command runs.

THE PROCESS GROUP DIES, NOT JUST THE CHILD. `start_new_session=True` plus a
`killpg` is what stops a hung `pnpm test` leaving a detached vitest behind on
the captain's machine.
"""
import argparse
import re
import json
import os
import signal
import subprocess
import sys
import time

# Exit statuses. Named, because the shell reads them and a bare number in two
# files is how two files come to disagree.
EXIT_PASSED = 0
EXIT_FAILED = 1
EXIT_HUNG = 2
EXIT_NOT_RUN = 3
EXIT_COULD_NOT_RUN = 4

CODE_FOR = {
    "passed": EXIT_PASSED,
    "failed": EXIT_FAILED,
    "hung": EXIT_HUNG,
    "no-test-command": EXIT_NOT_RUN,
    "no-worktree": EXIT_NOT_RUN,
    "could-not-run": EXIT_COULD_NOT_RUN,
}


# THE CLAUSE THAT SAYS THE EXIT CODE SETTLED NOTHING (fix round 1, D1) — one
# string, because the report SWAPS IT OUT for its resolved twin when a checked
# failing line has settled it (fix round 2, R2-2). xo-score.py holds the same
# literal and a test asserts the two are byte-identical; if they ever drift the
# report appends rather than swaps, so the fact is never lost either way.
FAILED_AMBIGUOUS = ("A failed run can be a test of yours going red or a test runner "
                    "that never started, and the exit code does not say which, so I "
                    "have not counted it against the build on its own.")


def human_seconds(secs):
    """A duration the captain reads, not a float with six places."""
    if secs < 1:
        return "under a second"
    if secs < 90:
        return "%ds" % int(round(secs))
    return "%dm %ds" % (int(secs) // 60, int(secs) % 60)


def verdict_for(outcome, command, exit_code, duration, timeout, ran_in=None):
    """THE PLAIN VERDICT, DERIVED FROM THE RECORDED FACTS ABOVE IT. One
    sentence, in the captain's own register — it is written into the record so
    the report never has to work out what happened by reading the output."""
    # WHERE IT RAN, when that is not simply "your project". On a workspace the
    # suite lives in the packages, and a captain reading "they passed" deserves
    # to know which ones answered.
    where = ""
    if ran_in:
        where = (" in %s" % ran_in[0]) if len(ran_in) == 1 else \
                (" across %d of your packages (%s)" % (len(ran_in), ", ".join(ran_in)))
    if outcome == "passed":
        return ("I ran your tests (`%s`)%s and they passed, in %s."
                % (command, where, human_seconds(duration)))
    if outcome == "failed":
        # THE ONE SENTENCE THAT WAS BACKWARDS (S211 fix round 1, D1). A runner
        # that CRASHED before running anything — a dangling symlink where
        # `vitest` should be, `Cannot find module`, exit 1 in a tenth of a
        # second — got "I ran your tests and they FAILED", printed directly
        # under the worker's own correct "your suite crashed at startup … so
        # those two stay unchecked". The session exists to stop product failure
        # and infrastructure being confused, and this sentence confused them.
        #
        # THERE IS NO HONEST WAY TO TELL THEM APART FROM THE FACTS HERE, AND
        # IT WAS MEASURED. On the tester's own fixtures the genuine failing
        # suite exited 1 after 0.26s having printed 877 bytes; the crashed
        # runner exited 1 after 0.12s having printed 1030. Duration does not
        # separate them and neither does volume. The one thing that would —
        # stdout empty, everything on stderr — is WRONG for jest, which prints
        # its entire report to stderr, and this project does not ship a
        # heuristic that lies for a whole runner.
        #
        # So the sentence says exactly what this process knows: the RUN failed.
        # It no longer claims the TESTS ran, it names the other thing a
        # non-zero exit can mean, and it stops short of counting the number
        # against the build. What it MEANS is decided downstream, by the one
        # thing that can decide it — a quoted line from the output, checked
        # against the output. A sentence that cannot be right must not sound
        # certain.
        return ("I ran your tests (`%s`)%s and the run failed — exit %s, after %s. %s"
                % (command, where, exit_code, human_seconds(duration), FAILED_AMBIGUOUS))
    if outcome == "hung":
        return ("I started your tests (`%s`) and the run was still going after %ds, "
                "so I stopped it. That is trouble running your tests, not something "
                "wrong with the build — I have not counted it against the build."
                % (command, int(timeout)))
    if outcome == "no-test-command":
        return ("This repo has no test command set, so the only evidence I have is "
                "what I could see on the screen.")
    if outcome == "no-worktree":
        return ("I could not find the checkout the build was launched from, so I did "
                "not run your tests. The only evidence I have is what I could see on "
                "the screen.")
    return ("I tried to run your tests (`%s`) and could not start the command at all."
            % command)



# ── where the project's suite can actually be run (S213) ─────────────────────
#
# THE DEFECT. On a pnpm workspace the seeded command is `npx vitest run …` and
# the runner lives in a PACKAGE's `node_modules/.bin`, not the repo root's. Run
# from the root it is `sh: vitest: command not found`, exit 127 — measured on
# the captain's own repo — so the most decisive evidence Number One has was
# blind on every workspace repo it will ever meet. The Implement red gate
# already solved this in S87 by running the command from INSIDE the package;
# Number One has no "touched package", so it asks every package instead.
#
# WHAT IS DELIBERATELY NOT DONE HERE. The tempting fix — put every package's
# `.bin` on PATH and run from the root anyway — turns `command not found` into
# `No test files found`, because vitest roots its include globs at its cwd.
# That is a SILENT GREEN, and this project has lost rounds (S147, and the
# include-rooting gotcha before it) to exactly that trade. A loud 127 is better
# than a quiet zero, so the cure moves the cwd and never the PATH.
WORKSPACE_MANIFEST = "pnpm-workspace.yaml"


def workspace_globs(root):
    """The workspace member patterns this repo declares, from pnpm-workspace.yaml
    or package.json's `workspaces` — READ from what the repo says about itself,
    never guessed from the shape of the tree."""
    globs = []
    wsfile = os.path.join(root, WORKSPACE_MANIFEST)
    if os.path.isfile(wsfile):
        try:
            with open(wsfile, encoding="utf-8") as fh:
                inlist = False
                for line in fh:
                    st = line.strip()
                    if st.startswith("packages:"):
                        inlist = True
                        continue
                    if inlist:
                        if st.startswith("- "):
                            globs.append(st[2:].strip().strip('"\''))
                        elif st and not st.startswith("#"):
                            inlist = False
        except Exception:
            pass
    pkg = os.path.join(root, "package.json")
    if os.path.isfile(pkg):
        try:
            with open(pkg, encoding="utf-8") as fh:
                doc = json.load(fh)
            ws = doc.get("workspaces")
            if isinstance(ws, dict):
                ws = ws.get("packages")
            if isinstance(ws, list):
                globs.extend(str(g) for g in ws)
        except Exception:
            pass
    return globs


def workspace_packages(root):
    """Every workspace member that has a package.json of its own, in a stable
    order. Empty for a repo that is not a workspace, which is how the fallback
    stays off for every repo that never had this problem."""
    import glob as globmod
    out = []
    for g in workspace_globs(root):
        g = g.strip()
        if not g or g.startswith("!"):
            continue
        for d in globmod.glob(os.path.join(root, g)):
            if os.path.isfile(os.path.join(d, "package.json")) and os.path.isdir(d):
                rd = os.path.realpath(d)
                if rd != os.path.realpath(root) and rd not in out:
                    out.append(rd)
    return sorted(out)


def command_picks_its_own_directory(command):
    """True when the command starts by changing directory itself.

    THE DOUBLE-`cd` FOOTGUN, said out loud. A testCommand of the form
    `cd packages/engine && npx vitest run` is already aimed; re-running it from
    inside packages/engine makes its own `cd` land nowhere, and whether that
    ends the run or carries on in the wrong place comes down to `&&` versus
    `;`. So a command that aims itself is never re-aimed by us."""
    head = command.lstrip()
    return head.startswith("cd ") or head.startswith("cd\t")


def run_in(command, cwd, env, timeout):
    """Run <command> in <cwd> and hand back the raw facts. Used ONLY by the
    workspace fallback below; the first run is left exactly as it stood, byte
    for byte, because it is the path every repo already takes and nothing here
    is worth risking it for."""
    started = time.time()
    try:
        proc = subprocess.Popen(
            ["bash", "-c", command], cwd=cwd, env=env,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, start_new_session=True)
    except Exception as exc:
        return (str(exc).encode("utf-8", "replace"), None, False,
                time.time() - started)
    timed_out = False
    try:
        raw = proc.communicate(timeout=timeout)[0]
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            raw = proc.communicate(timeout=15)[0]
        except Exception:
            raw = b""
    return (raw or b"", (None if timed_out else proc.returncode), timed_out,
            time.time() - started)


# ── the NAMES of the test cases (S216 fix round 2, T1b) ──────────────────────
#
# THE DEFECT. vitest's default reporter prints one line per FILE —
# `✓ src/renderer/utils.test.ts  (9 tests) 2ms` — so the only thing a look could
# cite was a file and a count. Two looks at the same build read that same line
# differently (one called seven items "met by tests", the other refused them),
# and the grade moved HIGH↔MEDIUM. The scorer now accepts a test citation only
# when it names a test CASE; this is where the names come from.
#
# WHAT IS DONE, AND HOW NARROWLY. When the command's LAST step is a direct
# vitest / jest invocation (`npx vitest run …`, `pnpm exec jest`, …) and the
# command has no pipe, redirect or backtick anywhere, one flag is appended that
# makes the runner print a line per test case: vitest `--reporter=verbose`,
# jest `--verbose`. Anything else — `pnpm test`, `npm test && npm run lint`, a
# runner we do not know — is run exactly as written and its names, if it prints
# any, are read from its ordinary output.
#
# THE FLAG MUST NEVER CHANGE THE OUTCOME. If the flagged run does not pass, the
# command is run again exactly as written and ITS exit code decides; the flagged
# output is kept only when both runs exit the same way (the flag changed
# nothing). The recorded `command` is always the captain's own; the flag is
# recorded beside it in `reporterFlag`.
REPORTER_FLAGS = (
    (re.compile(r"^\s*(?:(?:npx|bunx|pnpm\s+exec|pnpm|yarn)\s+)?vitest(?:\s|$)"),
     "--reporter=verbose", "--reporter"),
    (re.compile(r"^\s*(?:(?:npx|bunx|pnpm\s+exec|pnpm|yarn)\s+)?jest(?:\s|$)"),
     "--verbose", "--verbose"),
)


def unsafe_to_append(command):
    """True when a flag appended to the end would not reach the runner as-is:
    a pipe, redirect, backtick or newline, or a `#` that COMMENTS. Read the way
    the shell reads it — inside quotes, `${…}` and `$(…)` those characters are
    data (`${LCARS_TESTS_DIR#"$PWD/"}` is parameter expansion, not a comment),
    and `#` comments only at the start of a word. A backtick or newline is
    refused anywhere."""
    if any(ch in command for ch in "`\n"):
        return True
    stack = []  # open contexts: "'", '"', "${", "$("
    prev = " "
    i, n = 0, len(command)
    while i < n:
        ch = command[i]
        top = stack[-1] if stack else ""
        if top == "'":
            if ch == "'":
                stack.pop()
        elif ch == "\\":
            i += 1  # the next character is escaped, whatever it is
        elif top == '"':
            if ch == '"':
                stack.pop()
            elif command.startswith("${", i) or command.startswith("$(", i):
                stack.append(command[i:i + 2]); i += 1
        elif ch in "'\"":
            stack.append(ch)
        elif command.startswith("${", i) or command.startswith("$(", i):
            stack.append(command[i:i + 2]); i += 1
        elif top and ch == ("}" if top == "${" else ")"):
            stack.pop()
        elif top == "$(" and ch == "(":
            stack.append("$(")  # a nested plain paren, balanced by its ")"
        elif not top:
            if ch in "|<>":
                return True
            if ch == "#" and (prev.isspace() or prev in ";&|("):
                return True
        prev = command[i]
        i += 1
    return bool(stack)  # an unclosed quote or expansion: do not guess


def reporter_flag(command):
    """The one flag to append, or "" when appending anything is not safe."""
    if not command or unsafe_to_append(command):
        return ""
    last = re.split(r"&&|;", command)[-1]
    for pat, flag, already in REPORTER_FLAGS:
        if pat.search(last) and already not in command:
            return flag
    return ""


# A CASE LINE: a pass/fail glyph, then a name. Durations are dropped off the
# end. A line whose name is only a file path and a count (vitest's per-file
# line) is not a case. Matched on the glyph a runner prints — never on prose.
CASE_GLYPHS = "✓✔√×✕✗✘✖↓"
CASE_LINE = re.compile(r"^\s*[%s]\s+(.+?)\s*$" % CASE_GLYPHS)
TRAILING_TIME = re.compile(r"\s+(?:\(\s*\d+(?:\.\d+)?\s*m?s\s*\)|\d+(?:\.\d+)?ms)\s*$")
FILE_TOKEN = re.compile(r"(?<!\S)\S*(?:/\S*|\.(?:[cm]?[jt]sx?|py|rb|go|rs|java|kt|cs|php|svelte|vue))(?!\S)")
COUNT_TAIL = re.compile(r"\s*\(\s*\d+(?:\s+\w+)?(?:\s*\|\s*\d+\s+\w+)*\s*\)\s*$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
MAX_CASES = 400


# The other case-line shapes runners print, matched on their fixed markers:
# Go's `--- PASS: TestName (0.00s)`, TAP's `ok 1 - name` / `not ok 2 - name`,
# and a `PASS name` / `FAIL name` line (vitest's failure header, a bash suite).
# A `PASS src/x.test.js` line is only a file, and the file rule below drops it.
OTHER_CASE_LINES = (
    re.compile(r"^\s*---\s+(?:PASS|FAIL|SKIP):\s+(.+?)\s*$"),
    re.compile(r"^\s*(?:not\s+)?ok\s+\d+\s*(?:-\s*)?(.+?)\s*$"),
    re.compile(r"^\s*(?:PASS|FAIL)\s+(.+?)\s*$"),
)


def test_cases(text):
    """Every test case NAME the output shows, in order, de-duplicated."""
    out, seen = [], set()
    for raw in ANSI_RE.sub("", text or "").splitlines():
        m = CASE_LINE.match(raw)
        if not m:
            for pat in OTHER_CASE_LINES:
                m = pat.match(raw)
                if m:
                    break
        if not m:
            continue
        name = TRAILING_TIME.sub("", m.group(1))
        name = COUNT_TAIL.sub("", name).strip()
        # A file on its own, with or without its count, is not a test case.
        rest = FILE_TOKEN.sub("", name).replace(">", " ").strip()
        if not re.search(r"[^\W\d_]", rest, re.UNICODE):
            continue
        name = " ".join(name.split())
        if name and name not in seen:
            seen.add(name)
            out.append(name)
            if len(out) >= MAX_CASES:
                break
    return out


def write(path, doc):
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
        fh.write("\n")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--cwd", default="")
    ap.add_argument("--command", default="")
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--cap", type=int, default=8000)
    args = ap.parse_args()

    command = (args.command or "").strip()
    cap = max(200, int(args.cap))
    timeout = float(args.timeout)
    # A WHOLE NUMBER OF SECONDS READS AS ONE. `300.0` in the record is a float
    # that leaked out of argument parsing; the captain reads this file.
    recorded_timeout = int(timeout) if timeout == int(timeout) else timeout

    # The fields every outcome carries, so a reader never has to branch on
    # which keys are present.
    doc = {
        "ran": False,
        "command": command,
        "cwd": "",
        "exitCode": None,
        "timedOut": False,
        "timeoutSeconds": recorded_timeout,
        "durationSeconds": 0,
        "outputBytes": 0,
        "truncated": False,
        "tailCapBytes": cap,
        "outputTail": "",
        "outcome": "",
        "verdict": "",
        # WHERE it ran, when that was not simply the checkout root, and what the
        # root said before we moved. Both recorded rather than inferable, so the
        # report never has to work out from the output that a fallback happened.
        "ranIn": None,
        "rootExitCode": None,
        # THE TEST CASES THE OUTPUT NAMED (S216 fix round 2), and the one flag
        # appended to get them, if any — the scorer accepts a test citation
        # only when it names one of these.
        "reporterFlag": "",
        "testCases": [],
    }

    # --- the two cases where nothing is run at all ---------------------------
    # BOTH ARE ORDINARY (the doc's own words: "if a repo has no testCommand,
    # that is the common case and the look must degrade cleanly, not fail").
    # They are recorded plainly and the look goes on without them.
    if not command:
        doc["outcome"] = "no-test-command"
    elif not args.cwd or not os.path.isdir(args.cwd):
        doc["outcome"] = "no-worktree"
        doc["cwd"] = args.cwd or ""
    if doc["outcome"]:
        doc["verdict"] = verdict_for(doc["outcome"], command, None, 0, timeout)
        write(args.out, doc)
        return CODE_FOR[doc["outcome"]]

    cwd = os.path.realpath(args.cwd)
    doc["cwd"] = cwd

    # THE ENVIRONMENT THE PROJECT'S OWN SUITE EXPECTS. $LCARS_TESTS_DIR is the
    # Implement red gate's scoping handle — a seeded testCommand interpolates it
    # to run ONE ticket's staged tests. Number One is asking a different
    # question ("does the project's suite pass?"), so the variable is removed
    # rather than passed through, and the seeded command's `${LCARS_TESTS_DIR:+…}`
    # collapses to the whole suite exactly as the captain runs it by hand.
    env = dict(os.environ)
    env.pop("LCARS_TESTS_DIR", None)

    # THE ONE FLAG THAT MAKES THE RUNNER NAME ITS TEST CASES (T1b), or none.
    flag = reporter_flag(command)
    run_command = ("%s %s" % (command, flag)) if flag else command

    started = time.time()
    try:
        # `bash -c` is the shape every other LCARS test-command invocation uses
        # (run.sh's red gate, the pre-flight probe), so a command that works
        # there works here. Its own session, so the timeout can kill the whole
        # tree rather than one shell with children still running under it.
        proc = subprocess.Popen(
            ["bash", "-c", run_command],
            cwd=cwd, env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except Exception as exc:
        doc["durationSeconds"] = round(time.time() - started, 2)
        doc["outcome"] = "could-not-run"
        doc["outputTail"] = str(exc)
        doc["outputBytes"] = len(doc["outputTail"].encode("utf-8", "replace"))
        doc["verdict"] = verdict_for("could-not-run", command, None, 0, timeout)
        write(args.out, doc)
        return EXIT_COULD_NOT_RUN

    timed_out = False
    try:
        raw = proc.communicate(timeout=timeout)[0]
    except subprocess.TimeoutExpired:
        timed_out = True
        # THE WHOLE GROUP, WITH SIGKILL. A TERM to the shell leaves the runner
        # it exec'd behind often enough that this project has a standing rule
        # about it.
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        try:
            raw = proc.communicate(timeout=15)[0]
        except Exception:
            raw = b""

    duration = time.time() - started
    text = (raw or b"").decode("utf-8", "replace")
    full_bytes = len((raw or b""))

    # THE TAIL, BECAUSE THAT IS WHERE A FAILURE LANDS. Every runner in common
    # use prints its summary and its failing assertions last; the head is
    # collection noise. The cut is STATED rather than silent — a citation the
    # worker cannot find is a citation the scorer will refuse, so the worker has
    # to be told how much it is looking at.
    truncated = len(text.encode("utf-8", "replace")) > cap
    if truncated:
        tail = text.encode("utf-8", "replace")[-cap:].decode("utf-8", "replace")
    else:
        tail = text

    doc["ran"] = True
    doc["durationSeconds"] = round(duration, 2)
    doc["timedOut"] = timed_out
    doc["outputBytes"] = full_bytes
    doc["truncated"] = truncated
    doc["outputTail"] = tail

    # THE ONE DERIVATION, MADE HERE, FROM THE TWO FACTS ABOVE IT. `timedOut`
    # wins over the exit code, because a killed process has an exit code too
    # (SIGKILL leaves -9) and reading that as "the suite failed" is exactly the
    # lie this whole file exists to prevent.
    if timed_out:
        doc["exitCode"] = None
        doc["outcome"] = "hung"
    else:
        doc["exitCode"] = proc.returncode
        doc["outcome"] = "passed" if proc.returncode == 0 else "failed"

    # THE FLAG NEVER DECIDES THE OUTCOME (T1b). A flagged run that did not
    # pass is run again exactly as the captain wrote it, with what is left of
    # the budget, and that run's exit code is the one recorded. The flagged
    # output is kept only when both exited the same way — the flag changed
    # nothing — because that output carries the test names.
    if flag and not timed_out and proc.returncode != 0:
        left = max(1.0, timeout - (time.time() - started))
        o_raw, o_code, o_hung, _d = run_in(command, cwd, env, left)
        if o_hung or o_code != proc.returncode:
            flag = ""
            text = o_raw.decode("utf-8", "replace")
            b = text.encode("utf-8", "replace")
            doc["outputBytes"] = len(b)
            doc["truncated"] = len(b) > cap
            doc["outputTail"] = b[-cap:].decode("utf-8", "replace") if doc["truncated"] else text
            timed_out = bool(o_hung)
            doc["timedOut"] = timed_out
            doc["exitCode"] = None if o_hung else o_code
            doc["outcome"] = "hung" if o_hung else ("passed" if o_code == 0 else "failed")
        duration = time.time() - started
        doc["durationSeconds"] = round(duration, 2)

    # ── THE WORKSPACE FALLBACK (S213) ───────────────────────────────────────
    # 127 from a shell is "I could not find that program". On a pnpm workspace
    # that is exactly what `npx vitest run` says at the repo root, because the
    # runner is installed in a PACKAGE, and it is why the most decisive evidence
    # Number One has came back blind on the captain's own repo.
    #
    # KEYED ON THE RECORDED EXIT CODE, NEVER ON THE TEXT. 126/127 are the
    # shell's own two words for "could not run that": not found, and found but
    # not executable. Matching the message instead would be reading back prose
    # that changes with the runner, the shell and the locale — the mistake this
    # file's header already names four times.
    #
    # It engages only where all of this is true, so every repo that never had
    # this problem takes the identical path it always did:
    #   • the run came back 126 or 127, and
    #   • the repo SAYS it is a workspace (pnpm-workspace.yaml / package.json
    #     workspaces), and
    #   • the command does not already aim itself with a `cd`.
    if (not timed_out and doc["exitCode"] in (126, 127)
            and not command_picks_its_own_directory(command)):
        members = workspace_packages(cwd)
        if members:
            # ONE BUDGET FOR THE WHOLE FALLBACK, not one per package. The
            # timeout is a bound on how long a look may spend on tests; handing
            # every package the full bound turns a 300s cap into 300s x however
            # many packages the repo has, which is not a bound at all. What is
            # left of the budget is what the next package gets, and running out
            # of it is a hang like any other.
            ran_in, results, agg = [], [], []
            budget = timeout
            for d in members:
                if budget <= 0:
                    results.append((os.path.relpath(d, cwd), None, True))
                    ran_in.append(os.path.relpath(d, cwd))
                    agg.append("=== %s ===\n(no time left in the run's budget)"
                               % os.path.relpath(d, cwd))
                    break
                m_raw, m_code, m_hung, m_dur = run_in(command, d, env, budget)
                budget -= m_dur
                if m_code in (126, 127) or (m_code is None and not m_hung):
                    continue          # this package cannot run it either
                rel = os.path.relpath(d, cwd)
                ran_in.append(rel)
                results.append((rel, m_code, m_hung))
                agg.append("=== %s ===\n%s" % (rel, m_raw.decode("utf-8", "replace")))
            if ran_in:
                # The command really did run. What it says now is what the
                # packages said, and WHERE it ran is written down rather than
                # left for a reader to work out from the output.
                doc["ranIn"] = ran_in
                doc["rootExitCode"] = doc["exitCode"]
                text = "\n".join(agg)
                b = text.encode("utf-8", "replace")
                doc["outputBytes"] = len(b)
                doc["truncated"] = len(b) > cap
                doc["outputTail"] = b[-cap:].decode("utf-8", "replace") if doc["truncated"] else text
                doc["durationSeconds"] = round(time.time() - started, 2)
                if any(h for (_r, _c, h) in results):
                    doc["exitCode"] = None
                    doc["timedOut"] = True
                    doc["outcome"] = "hung"
                else:
                    worst = 0
                    for (_r, c, _h) in results:
                        if c:
                            worst = c
                    doc["exitCode"] = worst
                    doc["outcome"] = "passed" if worst == 0 else "failed"
                duration = doc["durationSeconds"]

    doc["reporterFlag"] = flag
    doc["testCases"] = test_cases(text)
    doc["verdict"] = verdict_for(doc["outcome"], command, doc["exitCode"],
                                 duration, timeout, doc.get("ranIn"))
    write(args.out, doc)
    return CODE_FOR[doc["outcome"]]


if __name__ == "__main__":
    sys.exit(main())
