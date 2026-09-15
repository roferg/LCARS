#!/usr/bin/env python3
"""xo-score.py — validate the worker's verdict, then DERIVE the score from it.

    python3 xo-score.py <xo-verdict.json> <criteria.json> <out verdict.json>
                         [<observations.json>]

THIS IS THE HEART OF THE SESSION: the model reasons, the skill decides.

THE FOURTH ARGUMENT is optional and is S210's: `xo-observe.py`'s output, the
OBSERVATIONS pass (crowding, overlap, a misaligned row, clipped text — things
no drawing ever states, computed from the same boxes the worker looked at).
They are rendered into their own section of `report.md`, below, and NOTHING
ABOUT THEM EVER TOUCHES THE SCORE: this file's derivation reads only the
ledger and the contract, exactly as it did before observations existed, and an
`observations.json` full of findings changes not one character of `score` or
`derivation`. If it is missing, or empty, the section is simply not written —
a mission with no observations reads exactly as one with the argument omitted.

THE NO-DRAWING GUARD (S210) is the other new thing here. `criteria.json` now
carries `hasDrawing` (xo-criteria.py) — the plain fact of whether this mission
was ever handed a holodeck drawing at all. When it was not, every criterion the
plan marked `drawnAt` is forced to `untested` with one fixed sentence, WHATEVER
THE WORKER WROTE — this is the one place in this file that overrules the
worker's own rating rather than merely checking its citation, because "I could
not check this against a drawing, because there isn't one" is not a judgement
call available to get right or wrong; it is a fact about the mission's own
attachments, and the skill knows it before the worker ever looks.

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

# THE ONE SENTENCE (S210). Byte-identical wherever it is written, because it is
# a fact ("there is no drawing"), not prose a worker composed — and a test that
# wants to be sure the honest answer was given, not a paraphrase of it, can
# match this string.
NO_DRAWING_NOTE = "I could not check this against a drawing, because there isn't one"


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
def cite(g):
    """The brackets at the end of a finding: the shot the captain can open, and
    the criterion id, in that order. THE HUMAN SENTENCE COMES FIRST and the id
    goes in the brackets after it (captain's ruling, 2026-09-13) — an id is for
    a machine, and reading one first is reading the wrong thing first."""
    bits = ["see " + ", ".join(g["shots"])] if g.get("shots") else ["no shot"]
    cid = str(g.get("criterion") or "").strip()
    if cid:
        bits.append(cid)
    return "; ".join(bits)


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


def load_observations(path):
    """Best-effort: no fourth argument, a missing file, or a file with nothing
    in it are all the same case — no observations section, no thresholds
    printed, exactly as if S210 had never happened for this look."""
    if not path:
        return None
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            doc = json.load(fh)
    except Exception:
        return None
    if not isinstance(doc, dict):
        return None
    obs = doc.get("observations")
    if not isinstance(obs, list):
        obs = []
    return {
        "observations": [o for o in obs if isinstance(o, dict) and o.get("message")],
        "thresholds": doc.get("thresholds") if isinstance(doc.get("thresholds"), dict) else {},
        "elementCount": doc.get("elementCount"),
    }


def main():
    if len(sys.argv) < 4:
        sys.stderr.write("usage: xo-score.py <verdict> <criteria> <out> [<observations>]\n")
        return 2
    vpath, cpath, opath = sys.argv[1], sys.argv[2], sys.argv[3]
    obs_path = sys.argv[4] if len(sys.argv) > 4 else ""
    observations = load_observations(obs_path)

    doc = load(vpath, "verdict")
    if not isinstance(doc, dict):
        bad("the verdict is not a JSON object")

    contract = load(cpath, "criteria list")
    contract_list = contract.get("criteria") if isinstance(contract, dict) else []
    if not isinstance(contract_list, list):
        contract_list = []
    has_drawing = bool(isinstance(contract, dict) and contract.get("hasDrawing"))
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
            notes.append("I called %r a mismatch but had no picture of it, so I have moved it "
                         "to the calls-the-build-made list instead — a finding with no picture "
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
            "note": "I never got to this one, so it is unchecked", "primary": cid in primary,
        })
        notes.append("%s was on the list you gave me and I never rated it" % cid)

    # THE NO-DRAWING GUARD (S210). NEVER SILENTLY MET. A criterion the plan
    # marked `drawnAt` names a place IN A DRAWING to compare the app against —
    # and if this mission has no drawing at all, no amount of worker confidence
    # makes that comparison possible. This overrules whatever status the worker
    # gave, on purpose: the honest answer here is a fact about the mission's own
    # attachments, not something a look could ever get right by trying harder.
    if not has_drawing:
        for entry in ledger:
            row = contract_by_id.get(entry["id"]) or {}
            if not row.get("drawnAt"):
                continue
            if entry["status"] == "untested" and entry["note"] == NO_DRAWING_NOTE:
                continue
            notes.append("%s asks to be checked against the drawing, but this "
                         "mission has none, so I am marking it not-checkable "
                         "rather than trusting what the look called it"
                         % entry["id"])
            entry["status"] = "untested"
            entry["note"] = NO_DRAWING_NOTE
            entry.pop("shot", None)

    # A contradiction naming a criterion that is no longer contradicted in the
    # ledger (downgraded above for want of a shot) must not still count.
    contradicted = set(cid for cid in contradicted
                       if any(e["id"] == cid and e["status"] == "gap" for e in ledger)
                       or cid not in seen)

    met = sum(1 for e in ledger if e["status"] == "met")
    gap = sum(1 for e in ledger if e["status"] == "gap")
    untested = sum(1 for e in ledger if e["status"] == "untested")

    # --- THE DERIVATION ------------------------------------------------------
    # THE DERIVATION IS THE FIRST LINE THE CAPTAIN READS, on a phone, so it is
    # written to him: what the build does to HIM, then the machine ids in
    # brackets (captain's ruling, 2026-09-13 — "I need more plain English in my
    # report"). Plain is not vague: every id and every count stays in the line.
    #
    # AND THE THINGS HAVE NAMES (fix round 2, D2). "2 things in the build do not
    # match what you asked for (t-3-ac1, t-5-ac1)" made the captain read two
    # machine handles to learn nothing — while the gap behind each one carried a
    # title in his own words, sitting right here in this function. The names go
    # in the sentence; the ids stay, in the brackets after it.
    def named(cid):
        for g in gaps:
            if str(g.get("criterion") or "") == cid and str(g.get("title") or "").strip():
                return clip(str(g["title"]), 90)
        row = contract_by_id.get(cid) or {}
        return clip(str(row.get("text") or ""), 90) or cid

    def name_list(ids):
        names = [named(c) for c in ids]
        if len(names) < 2:
            return "".join(names)
        return ", ".join(names[:-1]) + " and " + names[-1]

    primary_hit = sorted(contradicted & primary)
    if primary_hit:
        score = "low"
        why = ("the build does not do what the PRD itself asks for — %s (%s). "
               "What you set out to get is not there yet."
               % (name_list(primary_hit), ", ".join(primary_hit)))
    elif contradicted:
        score = "medium"
        hits = sorted(contradicted)
        why = ("the main flow works. %d thing%s in the build %s not match what you asked for "
               "— %s (%s) — and none of them is from the PRD itself: worth reading before "
               "you merge."
               % (len(hits), "" if len(hits) == 1 else "s",
                  "does" if len(hits) == 1 else "do",
                  name_list(hits), ", ".join(hits)))
    elif untested:
        score = "medium"
        why = ("nothing in the build contradicts what you asked for, but there %s %d thing%s "
               "on your list I could not check. I will not call a build good on the strength "
               "of what I could not see."
               % ("is" if untested == 1 else "are", untested,
                  "" if untested == 1 else "s"))
    elif gap:
        score = "medium"
        why = ("%d thing%s I am reporting as short of the mark, but %s contradicts anything "
               "you wrote down — so I am showing you %s rather than filing %s against the "
               "build." % (gap, "" if gap == 1 else "s",
                           "it" if gap == 1 else "none of them",
                           "it" if gap == 1 else "them",
                           "it" if gap == 1 else "them"))
    else:
        score = "high"
        why = "everything you asked for is in the build, and I have a picture of each one."

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
    if observations and observations["observations"]:
        # CARRIED THROUGH, NOT RECOMPUTED. The observations were already final
        # when xo-observe.py wrote them; this file is the one place they get
        # rendered to the captain, never a second place they get decided.
        out["observations"] = observations["observations"]
        out["observationThresholds"] = observations["thresholds"]

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
        w("**How close this is to what you asked for: %s** — %s\n\n" % (score.upper(), why))
        w(summary + "\n\n")
        if out["scoreDisagreed"]:
            w("> I first called this %s. The line above is worked out again from my own\n"
              "> notes below, and those notes win.\n\n" % worker_score.upper())
        # THE TABLE STAYS MACHINE-READABLE: four columns, one row per criterion,
        # the ids and the MET/GAP/UNTESTED marks exactly as they were. Only the
        # two header words the captain reads are written to him.
        w("| What you asked for | | Verdict | What I saw |\n|---|---|---|---|\n")
        mark = {"met": "MET", "gap": "GAP", "untested": "UNTESTED"}
        for e in ledger:
            w("| %s | %s | %s | %s |\n" % (
                e["id"] + (" (PRD)" if e["primary"] else ""),
                clip(e["text"], 120).replace("|", "\\|"),
                mark[e["status"]],
                ((e.get("shot", "") + " — ") if e.get("shot") else "") +
                clip(e["note"], 160).replace("|", "\\|")))
        # ONE SENTENCE, BOTH HALVES OF THE MISMATCH. The captain asked to see
        # what his first officer sees, from where he stands: *"phrases like
        # 'wrong color or this doesn't match the mock where it was in the lower
        # right, but it's lower left here'"*. So the drawing's expectation and
        # the build's reality sit in the SAME sentence, in that order, and the
        # machine id goes in the brackets at the end with the shot.
        real = [g for g in gaps if g["kind"] == "contradiction"]
        if real:
            w("\n### Where the build does not match what you asked for\n\n")
            for g in real:
                w("- **%s** — your drawing has %s; the build has %s. *(%s)*\n" % (
                    g.get("title", "?"), unstop(g.get("expected", "?")),
                    unstop(g.get("saw", "?")), cite(g)))
        interp = [g for g in gaps if g["kind"] == "interpretation"]
        if interp:
            w("\n### Calls the build made that your drawing does not cover\n\n")
            w("I am reading these as yours, not as faults.\n\n")
            for g in interp:
                w("- **%s** — the build has %s; your drawing does not say, so I am "
                  "treating it as your call. *(%s)*\n" % (
                      g.get("title", "?"), unstop(g.get("saw", "?")), cite(g)))
        blind = [e for e in ledger if e["status"] == "untested"]
        if blind:
            w("\n### What I could not check\n\n")
            for e in blind:
                w("- %s — %s. *(%s)*\n" % (
                    clip(e["text"], 120) or "this one",
                    unstop(e["note"] or "I could not check this"), e["id"]))
        # OBSERVATIONS — THEIR OWN SECTION, NEVER THE SCORE (S210). These do not
        # come from the drawing or the PRD; they are things a person would just
        # SEE — two controls touching, a row out of line, text spilling past its
        # own box — measured from the same boxes the ledger above was judged
        # from. They never moved the score you read at the top of this report.
        if observations and observations["observations"]:
            w("\n### Things I noticed that are not on your list\n\n")
            w("None of these come from your drawing or your PRD — they never "
              "change the score above. I am just telling you what I saw.\n\n")
            for o in observations["observations"]:
                w("- %s\n" % o.get("message", ""))
            th = observations["thresholds"] or {}
            w("\n*The numbers I used: I flag two controls less than %s px "
              "apart, a row whose left edge is more than %s px off from the "
              "others, and text that needs more than %s px of room it does "
              "not have. Tell me if these are wrong for your eye — that "
              "calibration is yours to make.*\n" % (
                  th.get("gapPx", "?"), th.get("misalignPx", "?"),
                  th.get("overflowPx", "?")))
        if out["alsoChecked"]:
            w("\n**I also looked at:** " + "; ".join(out["alsoChecked"]) + "\n")
        if out["escalations"]:
            w("\n**These are yours to decide:** " + "; ".join(out["escalations"]) + "\n")
        if notes:
            w("\n<details><summary>How I put this together</summary>\n\n")
            for n in notes:
                w("- %s\n" % n)
            w("\n</details>\n")

    print("SCORE\t" + score)
    print("WORKER_SCORE\t" + worker_score)
    print("DISAGREED\t" + ("yes" if score != worker_score else "no"))
    print("WHY\t" + why)
    print("COUNTS\t%d\t%d\t%d\t%d" % (met, gap, untested, len(contradicted)))
    print("SUMMARY\t" + summary.replace("\n", " "))
    if observations is not None:
        print("OBSERVATIONS\t%d" % len(observations["observations"]))
    for n in notes:
        print("NOTE\t" + n.replace("\n", " "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
