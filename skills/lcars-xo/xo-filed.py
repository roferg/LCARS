#!/usr/bin/env python3
"""Stamp `filedAs` onto the verdict's blockers, and say what to do about them.

    xo-filed.py <verdict.json> <parent-mission-id> <criterion>=<mission-id> ...

WHY THIS EXISTS (S240 fix round 4, D4). `xo-score.py` already writes the
send-back decision as DATA: `recommendation`, `because`, and `blockers[]` — the
rows that forced the send-back, each carrying its recorded evidence kind. Its
own comment at the blockers docstring says `filedAs` is "stamped onto them
later, by whoever files them", and the note beside `recommendation` says the
same. NOBODY EVER STAMPED IT. Nothing in the tree writes `filedAs` — a grep for
the name finds two comments promising it and no writer.

The consequence the captain sees: a SEND-BACK that names no bug id and no
command. He is told to send his own work back and handed nothing to act on,
while the bugs that justify it exist, with ids, three lines further up the same
output.

THE INFER-VS-RECORD RULE. The fix is NOT for a surface to parse bug ids back
out of finished prose. The PRODUCER records the fact: the filer knows the
criterion it filed and the mission id it got, so it writes that pair down, once,
on the row the send-back was decided from.

Prints one plain send-back sentence on stdout (empty when the recommendation is
not a send-back, so a caller can print it unconditionally).
"""
import json
import os
import sys


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: xo-filed.py <verdict.json> <parent-id> "
                         "<criterion>=<mission-id> ...\n")
        return 2
    vpath, parent = sys.argv[1], sys.argv[2]
    filed = {}
    order = []
    for arg in sys.argv[3:]:
        if "=" not in arg:
            continue
        cid, mid = arg.split("=", 1)
        cid, mid = cid.strip(), mid.strip()
        if not mid:
            continue
        # AN UNCONTRACTED FINDING IS NEVER A REASON TO SEND THE BUILD BACK (S251).
        # `xo-logs.py` files a `volunteered[]` entry under `volunteered-<k>`
        # BECAUSE there is no criterion for it (see VOL_ID_PREFIX there, which is
        # the other half of this one contract). It is a real bug with real
        # evidence and it is filed like any other — but the send-back sentence
        # below names the bugs the VERDICT blocked on, and a fault nobody wrote
        # down did not move the grade, the recommendation or `blockers[]`. Naming
        # it here would make a volunteered find the verdict, which is exactly what
        # the contract-first rule forbids. It stamps nothing and it is not counted.
        if cid.startswith("volunteered-"):
            continue
        if cid:
            filed[cid] = mid
        if mid not in order:
            order.append(mid)

    try:
        with open(vpath, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        # A verdict that cannot be read is not a reason to lose the ids: the
        # sentence is still printed from what the filer passed in.
        doc = None

    if isinstance(doc, dict) and filed:
        touched = 0
        for key in ("blockers", "gaps", "followUps"):
            rows = doc.get(key)
            if not isinstance(rows, list):
                continue
            for row in rows:
                if not isinstance(row, dict):
                    continue
                # A blocker is keyed by the LEDGER id; a gap names the
                # criterion it contradicts. Both are read, neither is guessed.
                cid = str(row.get("id") or row.get("criterion") or "").strip()
                if cid and cid in filed:
                    row["filedAs"] = filed[cid]
                    touched += 1
        if touched:
            tmp = vpath + ".filed.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(doc, fh, indent=2)
                fh.write("\n")
            os.replace(tmp, vpath)

    rec = ""
    if isinstance(doc, dict):
        rec = str(doc.get("recommendation") or "").strip()
    if rec != "send-back":
        return 0
    if not order:
        return 0
    noun = "bug" if len(order) == 1 else "bugs"
    sys.stdout.write(
        "SEND-BACK: this build goes back for %d %s — %s. "
        "Work them with `lcars resolve-logs %s`.\n"
        % (len(order), noun, ", ".join(order), parent))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
