#!/usr/bin/env python3
"""xo-held.py — did each filed gap's fix HOLD?

    python3 xo-held.py <xo-recheck.json> <logs.json>

The re-check worker looks at the relaunched build with the previous verdict and
the filed logs in front of it, and writes one `held: true|false` per gap it was
asked about, plus the full ledger again (which xo-score.py re-scores).

THIS FILE DECIDES NOTHING ABOUT THE BUILD. It answers one narrow question for
the shell: for every log Number One filed, did the worker say its gap is fixed?
The shell then either accepts the whole set through the ordinary verb or hands
the gate back — never a mixture, and never a second round.

A GAP THE WORKER DID NOT RATE IS NOT HELD. Silence is not a pass: the worker
was handed the list and asked about each one, so a missing entry is a gap
nobody looked at, and accepting it would fold a child to Done on the strength of
an omission. That is the same rule xo-score.py applies to an unrated criterion.

Output on stdout, one TAB-separated record per line:

    HELD     <n> <mission> <criterion> <title> <why>
    NOTHELD  <n> <mission> <criterion> <title> <why>

The fields are separated by ASCII US (0x1f), not a tab — `mission` and
`criterion` can both come back empty off a filed-logs record, and a tab is IFS
whitespace, so `read` would eat the empty one and shift every field after it
left. See xo-logs.py's docstring for the whole of that story.
    MALFORMED <why>

THE TITLE IS CARRIED (S204 fix round 2, D2), because the line the shell builds
out of these records is a line the CAPTAIN reads. "log #1 (t-3-ac1) — …" told
him nothing about his own product; the thing has a name — the one Number One
gave it when it filed the log, recorded in `logs.json` — and that name goes
first, with the id in brackets after it.
"""
import json
import sys


# The record separator: US (0x1f), never a tab. See the docstring.
RS = "\x1f"


def clean(s):
    return " ".join(str(s or "").split())


def main():
    if len(sys.argv) < 3:
        print("usage: xo-held.py <xo-recheck.json> <logs.json>", file=sys.stderr)
        return 2
    rpath, lpath = sys.argv[1], sys.argv[2]

    try:
        with open(lpath, encoding="utf-8") as fh:
            logs = json.load(fh)
        filed = [f for f in (logs.get("filed") or []) if isinstance(f, dict)]
    except Exception as exc:
        print("MALFORMED" + RS + "the filed-logs record could not be read (%s)" % exc)
        return 0
    if not filed:
        print("MALFORMED" + RS + "no logs were filed, so there is nothing to re-check")
        return 0

    try:
        with open(rpath, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:
        print("MALFORMED" + RS + "the re-check verdict could not be read (%s)" % exc)
        return 0
    if not isinstance(doc, dict):
        print("MALFORMED" + RS + "the re-check verdict is not a JSON object")
        return 0

    # The worker's answers, keyed BOTH ways a worker might name a gap: by the
    # criterion id it was judged against, and by the log number it was given.
    # Neither is inferred from prose — both are ids this skill handed it.
    by_crit, by_n = {}, {}
    held = doc.get("held")
    if not isinstance(held, list):
        print("MALFORMED" + RS + "the re-check verdict has no `held` list")
        return 0
    for h in held:
        if not isinstance(h, dict):
            continue
        cid = clean(h.get("criterion"))
        if cid:
            by_crit[cid] = h
        n = h.get("log") if h.get("log") is not None else h.get("n")
        try:
            by_n[int(n)] = h
        except Exception:
            pass

    for f in filed:
        n = f.get("n")
        cid = clean(f.get("criterion"))
        mission = clean(f.get("mission"))
        title = clean(f.get("title")) or ("log #%s" % n)
        h = by_crit.get(cid)
        if h is None:
            try:
                h = by_n.get(int(n))
            except Exception:
                h = None
        if h is None:
            print(RS.join([
                "NOTHELD", str(n), mission, cid, title,
                "it did not say whether this one is fixed, and silence is not a pass"]))
            continue
        why = clean(h.get("why") or h.get("note")) or "no reason given"
        shots = [clean(s) for s in (h.get("shots") or []) if clean(s)]
        if shots:
            why = "%s (see %s)" % (why, ", ".join(shots))
        print(RS.join([
            "HELD" if h.get("held") is True else "NOTHELD",
            str(n), mission, cid, title, why]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
