#!/usr/bin/env python3
"""THE VERDICT CHANNEL — Number One's file, handed over by SPEAKING it.

WHY THIS EXISTS. `evaluate.md` tells the first officer: "You do not write code.
You do not fix anything. You do not merge. You look, you judge against the
record, and you write one file." That one file is the ONLY reason the role ever
needed a write capability at all — so the cheapest way to stop depending on one
is to stop needing one.

On copilot a write tool is MODEL-DEPENDENT: the same `--available-tools` list
has `create` with `--model claude-opus-4.8` and no file-writing tool whatsoever
without one (measured 2026-10-05 against copilot 1.0.92; see `adapter_tools` in
worker-adapter.sh for the numbers and for how to measure it without landing in
VS Code's PATH shim). S194's write-tool floor in run.sh is what guarantees that
model, and it holds. This channel does not fix a bug and there was no outage —
`create` works on the model LCARS sends, and the other read roles still use it.
What it buys is INDEPENDENCE: a reviewer that needs no write capability cannot
be broken by anything that ever happens to one.

So for this one role the write tool is RETIRED, not replaced. The worker says
its file in its reply; the harness writes it. Both paths are accepted and the
one that was used is RECORDED, because "the file is now ignored" and "the fix
works" look identical from the outside otherwise.

A RECORD, NOT AN INFERENCE — the rule ORCHESTRATION.md states and this round has
already paid for three times (S147, S156, S188). Scraping the first `{` out of a
model's reply would be an inference twice over: it guesses which brace-run is the
answer, and on the `evaluate` round — which may write EITHER a verdict OR a
request to look further — it cannot even tell WHICH file it is holding. So the
prompt (assembled in run.sh, beside the round's other facts) asks the worker to
FRAME its answer and to NAME the file on the opening line:

    ===LCARS-XO-BEGIN xo-verdict.json===
    { … }
    ===LCARS-XO-END===

This reader reads exactly that frame. The boundaries are the worker's own; the
filename is the worker's own; nothing about either is deduced from shape,
position or wording. A reply with no frame, an unclosed frame, a frame around
something that is not JSON, a frame naming a file this round may not write, or
two frames where one was asked for are each REFUSED BY NAME — never quietly
turned into an empty verdict, which is the one wrong answer a judge must never
be made to give.

    number-one-channel.py <capture-file> <outdir> <name> [<name> …]

<capture-file> is the worker's captured stdout (`<outdir>/.worker.out`, written
by worker-adapter.sh). <name>s are the files THIS round is allowed to write, in
the order spawn_number_one declares them. Writes `<outdir>/xo-channel.json` on
every path, prints one sentence for a human, and exits 0 always: a channel that
can fail its caller is a channel that can stop a look.
"""

import json
import os
import sys

BEGIN = "===LCARS-XO-BEGIN "
END = "===LCARS-XO-END==="
CLOSE = "==="


def quoted(names):
    return ", ".join("`%s`" % n for n in names)


def record(outdir, via, name, why, sentence):
    """The producer writes down which path was used, so no reader has to guess."""
    doc = {"via": via, "file": name or "", "why": why or ""}
    try:
        os.makedirs(outdir, exist_ok=True)
        with open(os.path.join(outdir, "xo-channel.json"), "w",
                  encoding="utf-8") as fh:
            json.dump(doc, fh, indent=2)
            fh.write("\n")
    except Exception:
        pass
    sys.stdout.write("  " + sentence + "\n")
    return 0


def frames(text):
    """Every CLOSED frame the worker drew, plus the name of one it left open.

    Plain string work on whole lines — no pattern matching over prose, which is
    the thing this file exists not to do.
    """
    found = []
    open_name = None
    body = []
    for line in text.splitlines():
        stripped = line.strip()
        if open_name is None:
            if stripped.startswith(BEGIN) and stripped.endswith(CLOSE):
                open_name = stripped[len(BEGIN):-len(CLOSE)].strip()
                body = []
            continue
        if stripped == END:
            found.append((open_name, "\n".join(body)))
            open_name = None
            body = []
            continue
        body.append(line)
    return found, open_name


def main(argv):
    if len(argv) < 4:
        sys.stderr.write("usage: number-one-channel.py <capture> <outdir> "
                         "<name> [<name> …]\n")
        return 0
    capture, outdir = argv[1], argv[2]
    names = [n for n in argv[3:] if n]

    # THE FILE THE WORKER WROTE WINS, and it is never reshaped. An engine that
    # still has a write tool (and claude, which has `Write`) is unaffected by any
    # of this: its artifact is used byte for byte and its reply is not read at
    # all. That is the control that tells a working channel from a file nobody
    # looks at any more.
    for name in names:
        path = os.path.join(outdir, name)
        try:
            if os.path.getsize(path) > 0:
                return record(outdir, "worker-file", name, "",
                              "◈ Number One wrote %s itself." % name)
        except OSError:
            continue

    try:
        with open(capture, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except Exception:
        text = ""

    found, open_name = frames(text)

    if not found and open_name is not None:
        why = ("Number One opened a `%s%s%s` frame in its reply and never closed "
               "it with `%s`, so the file it meant to hand over has no end and "
               "cannot be read." % (BEGIN, open_name, CLOSE, END))
        return record(outdir, "none", "", why, "◈ " + why)

    if not found:
        why = ("Number One wrote none of %s, and its reply carried no "
               "`%s<file>%s` … `%s` frame around one either, so it handed over "
               "nothing this round can read."
               % (quoted(names), BEGIN, CLOSE, END))
        return record(outdir, "none", "", why, "◈ " + why)

    allowed = [(n, b) for (n, b) in found if n in names]
    if not allowed:
        said = ", ".join("`%s`" % n for n in dict.fromkeys(n for n, _ in found))
        why = ("Number One framed %s in its reply, which is not a file this round "
               "may write (it may write %s), so nothing was written."
               % (said, quoted(names)))
        return record(outdir, "none", "", why, "◈ " + why)

    if len(allowed) > 1:
        said = ", ".join("`%s`" % n for n, _ in allowed)
        why = ("Number One framed more than one file in its reply (%s); this "
               "round writes exactly one, so there is no way to tell which of "
               "them is its answer." % said)
        return record(outdir, "none", "", why, "◈ " + why)

    name, body = allowed[0]
    try:
        json.loads(body)
    except Exception as exc:
        why = ("Number One framed `%s` in its reply, but what is between the two "
               "markers is not valid JSON (%s), so it cannot be used as its %s."
               % (name, exc, name))
        return record(outdir, "none", "", why, "◈ " + why)

    # Written as the worker said it — validated, never reformatted, so what lands
    # on disk is the worker's own text and nothing of ours.
    try:
        os.makedirs(outdir, exist_ok=True)
        with open(os.path.join(outdir, name), "w", encoding="utf-8") as fh:
            fh.write(body)
            if not body.endswith("\n"):
                fh.write("\n")
    except Exception as exc:
        why = ("Number One framed `%s` in its reply, but the harness could not "
               "write it to the scratch output directory (%s)." % (name, exc))
        return record(outdir, "none", "", why, "◈ " + why)

    return record(outdir, "stdout", name, "",
                  "◈ Number One framed %s on stdout — it had no file-writing "
                  "tool, so the harness wrote the file." % name)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
