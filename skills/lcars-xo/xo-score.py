#!/usr/bin/env python3
"""xo-score.py — validate the worker's verdict, then DERIVE the score from it.

    python3 xo-score.py <xo-verdict.json> <criteria.json> <out verdict.json>

THIS IS THE HEART OF THE SESSION: the model reasons, the skill decides.

Number One writes a ledger — one line per criterion, met / gap / untested, each
citing the shot that shows it — and a score of its own. **The score it wrote is
a recommendation.** The score that gets recorded, labelled and shown to the
captain is recomputed HERE, from the ledger, by a rule anyone can check:

    a CONTRADICTED PRIMARY criterion         → LOW     the stated goal is not met
    any other contradiction                  → MEDIUM  the flow works; file the gap
    any UNTESTED criterion, everything else  → MEDIUM  not HIGH. "I could not see
      met                                              it" is not "it is fine".
    every criterion MET                      → HIGH    ship as is

If the worker's score disagrees with its own ledger, the LEDGER WINS and the
disagreement is recorded (xo.sh journals it). A free-floating score is the one
thing an LLM judge is worst at and a rule is best at; a per-criterion ledger is
the opposite. So each does the half it is good at.

TWO CITATION GUARDS, both of them anti-OVER-REJECTION:

  * A `met` or `gap` with NO SHOT is not evidence of anything. It is downgraded
    to `untested` with a note. The tester brief calls a gap without a shot a
    DEFECT; this is what makes producing one impossible rather than merely
    discouraged.
  * A CONTRADICTION with no shot is demoted to an INTERPRETATION — reported to
    the captain, not filed against the build. The known failure in this seat is
    reasoning past the record into confident faults, and a picture is the cheap
    guard against it.

A criterion in the contract the worker never rated is `untested` too, with a
note saying so. It is never silently dropped: the contract was written before
the look, and a look that skipped part of it is a look with a hole in it.

Output on stdout, one TAB-separated record per line, for the shell to read:
  MALFORMED <why>                 | SCORE <s> / WORKER_SCORE <s> / DISAGREED yes|no
  WHY <the derivation, in words>  | COUNTS <met> <gap> <untested> <contradictions>
"""
import json
import os
import re
import sys

VALID_SCORES = ("high", "medium", "low")
VALID_STATUS = ("met", "gap", "untested")


# A CELL THE CAPTAIN CAN READ (fix round 1, D7). A hard `[:160]` cut the
# evidence mid-word and landed on an open quote — `…and no '` — which reads as a
# rendering bug, not as a finding. Cut at the last word boundary inside the
# budget instead and SAY that it was cut, with one ellipsis.
def clip(text, n):
    t = " ".join((text or "").split())
    if len(t) <= n:
        return t
    head = t[:n]
    cut = head.rfind(" ")
    if cut < n // 2:          # one very long token: there is no boundary to find
        cut = n
    return t[:cut].rstrip(" ,;:-") + "…"


# ONE FULL STOP, NOT TWO (fix round 1, D7). The gap bullet appends its own `.`
# after the worker's `saw` text, and a worker that ended its sentence produced
# `…(readout)..`. Strip a trailing stop from the fragment; the template adds it.
def unstop(text):
    return (text or "").rstrip().rstrip(".")


def bad(why):
    print("MALFORMED\t" + why)
    sys.exit(0)


def load(path, what):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            raw = fh.read()
    except Exception:
        bad("no %s was written" % what)
    try:
        return json.loads(raw)
    except Exception:
        # A worker that fenced its JSON has still answered; unwrap the one
        # outermost object rather than refuse over punctuation (the S202
        # precedent). Anything else is a genuine malformation.
        m = re.search(r"\{.*\}", raw, re.S)
        if not m:
            bad("the %s is not JSON" % what)
        try:
            return json.loads(m.group(0))
        except Exception:
            bad("the %s is not JSON" % what)


def main():
    if len(sys.argv) < 4:
        sys.stderr.write("usage: xo-score.py <verdict> <criteria> <out>\n")
        return 2
    vpath, cpath, opath = sys.argv[1], sys.argv[2], sys.argv[3]

    doc = load(vpath, "verdict")
    if not isinstance(doc, dict):
        bad("the verdict is not a JSON object")

    contract = load(cpath, "criteria list")
    contract_list = contract.get("criteria") if isinstance(contract, dict) else []
    if not isinstance(contract_list, list):
        contract_list = []
    primary = set(str(c.get("id")) for c in contract_list
                  if isinstance(c, dict) and c.get("primary"))
    contract_by_id = {str(c.get("id")): c for c in contract_list if isinstance(c, dict)}

    worker_score = str(doc.get("score") or "").strip().lower()
    if worker_score not in VALID_SCORES:
        bad("the verdict names no score (want high|medium|low)")
    summary = str(doc.get("summary") or "").strip()
    if not summary:
        bad("the verdict has no summary")
    rated = doc.get("criteria")
    if not isinstance(rated, list) or not rated:
        bad("the verdict rates no criteria")

    gaps_in = doc.get("gaps") if isinstance(doc.get("gaps"), list) else []
    notes = []

    # --- the gaps, checked for their pictures --------------------------------
    gaps = []
    for g in gaps_in:
        if not isinstance(g, dict):
            continue
        kind = str(g.get("kind") or "").strip().lower()
        if kind not in ("contradiction", "interpretation"):
            bad("a gap names no kind (want contradiction|interpretation)")
        shots = [str(s) for s in g.get("shots") or [] if str(s).strip()]
        if kind == "contradiction" and not shots:
            notes.append("the gap %r was filed as a contradiction with no shot behind it; "
                         "recorded as an interpretation instead — a finding with no picture "
                         "is not evidence" % (str(g.get("title") or g.get("criterion") or "?")))
            kind = "interpretation"
        gg = dict(g)
        gg["kind"] = kind
        gg["shots"] = shots
        gaps.append(gg)

    contradicted = set(str(g.get("criterion") or "") for g in gaps
                       if g["kind"] == "contradiction" and g.get("criterion"))

    # --- the ledger, checked for its pictures --------------------------------
    ledger = []
    seen = set()
    for c in rated:
        if not isinstance(c, dict):
            continue
        cid = str(c.get("id") or "").strip()
        if not cid:
            continue
        status = str(c.get("status") or "").strip().lower()
        if status not in VALID_STATUS:
            bad("criterion %r has no valid status (want met|gap|untested)" % cid)
        shot = str(c.get("shot") or "").strip()
        if status in ("met", "gap") and not shot:
            notes.append("criterion %s was rated %s with no shot cited; recorded as "
                         "untested — a judgement with no picture behind it is not a "
                         "judgement" % (cid, status))
            status = "untested"
        entry = {
            "id": cid,
            "text": str(c.get("text") or (contract_by_id.get(cid, {}) or {}).get("text") or ""),
            "status": status,
            "note": str(c.get("note") or ""),
            "primary": cid in primary,
        }
        if shot:
            entry["shot"] = shot
        ledger.append(entry)
        seen.add(cid)

    # A criterion the contract carried and the look never rated. Never dropped.
    for cid, c in contract_by_id.items():
        if cid in seen:
            continue
        ledger.append({
            "id": cid, "text": str(c.get("text") or ""), "status": "untested",
            "note": "Number One did not rate this criterion", "primary": cid in primary,
        })
        notes.append("criterion %s was in the contract and was never rated" % cid)

    # A contradiction naming a criterion that is no longer contradicted in the
    # ledger (downgraded above for want of a shot) must not still count.
    contradicted = set(cid for cid in contradicted
                       if any(e["id"] == cid and e["status"] == "gap" for e in ledger)
                       or cid not in seen)

    met = sum(1 for e in ledger if e["status"] == "met")
    gap = sum(1 for e in ledger if e["status"] == "gap")
    untested = sum(1 for e in ledger if e["status"] == "untested")

    # --- THE DERIVATION ------------------------------------------------------
    primary_hit = sorted(contradicted & primary)
    if primary_hit:
        score = "low"
        why = ("a criterion the PRD itself states is contradicted by the build (%s) — "
               "the stated goal is not met" % ", ".join(primary_hit))
    elif contradicted:
        score = "medium"
        why = ("%d criteri%s contradicted (%s) but no PRD criterion is — the primary flow "
               "works, the gaps are worth reading"
               % (len(contradicted), "on is" if len(contradicted) == 1 else "a are",
                  ", ".join(sorted(contradicted))))
    elif untested:
        score = "medium"
        why = ("%d criteri%s could not be verified; nothing is contradicted. Not HIGH: "
               "\"could not see it\" is not \"it is fine\""
               % (untested, "on" if untested == 1 else "a"))
    elif gap:
        score = "medium"
        why = ("%d criteri%s reported as a gap, none of them a contradiction of the record "
               "— reported, not filed against the build" % (gap, "on" if gap == 1 else "a"))
    else:
        score = "high"
        why = "every criterion met, each with the shot that shows it"

    out = {
        "score": score,
        "workerScore": worker_score,
        "scoreDisagreed": score != worker_score,
        "derivation": why,
        "counts": {"met": met, "gap": gap, "untested": untested,
                   "contradictions": len(contradicted)},
        "criteria": ledger,
        "gaps": gaps,
        "escalations": [str(e) for e in (doc.get("escalations") or []) if str(e).strip()],
        "alsoChecked": [str(e) for e in (doc.get("alsoChecked") or []) if str(e).strip()],
        "summary": summary,
    }
    if notes:
        out["ledgerNotes"] = notes

    os.makedirs(os.path.dirname(os.path.abspath(opath)), exist_ok=True)
    with open(opath, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
        fh.write("\n")

    # THE REPORT, RENDERED HERE AND NOWHERE ELSE. The living comment (S65, one
    # comment per key, edited in place) includes this fragment verbatim, so the
    # ledger the captain reads on the issue and the ledger on disk cannot drift
    # apart into two renderings of one fact. Shot NAMES, never images: GitHub has
    # no comment-image upload API and the PNGs stay on the laptop that took them
    # (ruling, ledgered), so the report names each shot and says what it showed.
    with open(os.path.join(os.path.dirname(os.path.abspath(opath)), "report.md"),
              "w", encoding="utf-8") as fh:
        w = fh.write
        w("**Intent match: %s** — %s\n\n" % (score.upper(), why))
        w(summary + "\n\n")
        if out["scoreDisagreed"]:
            w("> Number One scored this %s. The score above is recomputed from its own\n"
              "> ledger, and the ledger decides.\n\n" % worker_score.upper())
        w("| Criterion | | Verdict | Evidence |\n|---|---|---|---|\n")
        mark = {"met": "MET", "gap": "GAP", "untested": "UNTESTED"}
        for e in ledger:
            w("| %s | %s | %s | %s |\n" % (
                e["id"] + (" (PRD)" if e["primary"] else ""),
                clip(e["text"], 120).replace("|", "\\|"),
                mark[e["status"]],
                ((e.get("shot", "") + " — ") if e.get("shot") else "") +
                clip(e["note"], 160).replace("|", "\\|")))
        real = [g for g in gaps if g["kind"] == "contradiction"]
        if real:
            w("\n### Gaps — the record says one thing, the build shows another\n\n")
            for g in real:
                w("- **%s** — expected %s; saw %s. *(%s)*\n" % (
                    g.get("title", "?"), unstop(g.get("expected", "?")),
                    unstop(g.get("saw", "?")),
                    ", ".join(g["shots"]) or "no shot"))
        interp = [g for g in gaps if g["kind"] == "interpretation"]
        if interp:
            w("\n### Interpretations — the record is silent, the build chose\n\n")
            w("Reported, not filed against the build.\n\n")
            for g in interp:
                w("- **%s** — %s *(%s)*\n" % (
                    g.get("title", "?"), unstop(g.get("saw", "?")),
                    ", ".join(g["shots"]) or "no shot"))
        blind = [e for e in ledger if e["status"] == "untested"]
        if blind:
            w("\n### What it could not see\n\n")
            for e in blind:
                w("- %s — %s\n" % (e["id"], e["note"] or "not verified"))
        if out["alsoChecked"]:
            w("\n**Also checked:** " + "; ".join(out["alsoChecked"]) + "\n")
        if out["escalations"]:
            w("\n**For you:** " + "; ".join(out["escalations"]) + "\n")
        if notes:
            w("\n<details><summary>Ledger notes</summary>\n\n")
            for n in notes:
                w("- %s\n" % n)
            w("\n</details>\n")

    print("SCORE\t" + score)
    print("WORKER_SCORE\t" + worker_score)
    print("DISAGREED\t" + ("yes" if score != worker_score else "no"))
    print("WHY\t" + why)
    print("COUNTS\t%d\t%d\t%d\t%d" % (met, gap, untested, len(contradicted)))
    print("SUMMARY\t" + summary.replace("\n", " "))
    for n in notes:
        print("NOTE\t" + n.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
