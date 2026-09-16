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
evidence.** The worker still reasons and still has no shell — "the worker
reasons, the skill executes" (captain's ruling 2026-09-11) is untouched.

WHAT THIS FILE RECORDS, AND WHAT IT DERIVES. Everything at the top of the
output is a FACT this process knew at the moment it ran: the command as it was
given to the shell, the directory it ran in, the child's exit code, whether the
timeout fired, how long it took, how many bytes came back, whether the tail was
cut and at what cap. `outcome` and `verdict` are DERIVED, here, from those
facts and nothing else — never re-read later out of prose. This project has
lost four rounds (S147, S156, S188, S212) to code that parsed back text a human
also writes; the cure every time was to record the decision where it was made.

THE TRAP THIS FILE WAS WRITTEN TO AVOID. `tests/drives/s197/cage.py` — the
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


def verdict_for(outcome, command, exit_code, duration, timeout):
    """THE PLAIN VERDICT, DERIVED FROM THE RECORDED FACTS ABOVE IT. One
    sentence, in the captain's own register — it is written into the record so
    the report never has to work out what happened by reading the output."""
    if outcome == "passed":
        return ("I ran your tests (`%s`) and they passed, in %s."
                % (command, human_seconds(duration)))
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
        return ("I ran your tests (`%s`) and the run failed — exit %s, after %s. %s"
                % (command, exit_code, human_seconds(duration), FAILED_AMBIGUOUS))
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

    started = time.time()
    try:
        # `bash -c` is the shape every other LCARS test-command invocation uses
        # (run.sh's red gate, the pre-flight probe), so a command that works
        # there works here. Its own session, so the timeout can kill the whole
        # tree rather than one shell with children still running under it.
        proc = subprocess.Popen(
            ["bash", "-c", command],
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

    doc["verdict"] = verdict_for(doc["outcome"], command, doc["exitCode"],
                                 duration, timeout)
    write(args.out, doc)
    return CODE_FOR[doc["outcome"]]


if __name__ == "__main__":
    sys.exit(main())
