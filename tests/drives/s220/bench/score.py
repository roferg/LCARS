#!/usr/bin/env python3
"""
S220 benchmark scorer — turn ONE look's output into recall, false alarms and a
grade check, by a rule stated in README.md and implemented here and nowhere
else.

  score.py <look-dir> <known-answers.json> [--kinds kinds.json] [--json out.json]

<look-dir> is a mission's `xo/` directory after a look: verdict.json,
observations.json, actions-*.json, and whatever logs were filed.

NOTHING here reads a known answer out of the look. The known answers are
declared in known-answers/*.json; this file only asks, of each declared thing,
whether the look said it.

PROVENANCE IS NOT OPTIONAL (fix round 1, D1). A look has THREE eyes: the
model's own words, the deterministic detectors LCARS runs beside it, and — fix
round 2, D-A — the sentences the HARNESS itself wrote into the verdict and
stamped `reasonByHarness` at birth. A single
number over them flatters whichever is weakest, and on 2026-09-19 it flattered
the model all the way to a perfect score while the model said NOTHING AT ALL —
every criterion muted to "met", the detectors carrying the whole 5/5. So every
finding is stamped with where it came from AT THE MOMENT IT IS PRODUCED, never
worked out afterwards from the order a list happened to be built in, and the
scoreboard prints the model's eye, the detectors', the harness's own, and the
union. A silent model scores zero in its own column, by construction — and it
cannot be credited for a sentence the verdict records the harness as writing.
"""
import argparse, json, os, re, sys, glob

# --- what counts as a FINDING ------------------------------------------------
# Three kinds of thing a look can say, and only the first is a complaint:
#
#   NEGATIVE       a criterion whose status is "gap" (the look's own word for
#                  "didn't work"), or an entry in the layout observations, or a
#                  bug it filed. These are what recall and false alarms are
#                  measured over.
#   COULDNT-CHECK  status "untested". Counted and reported, but it is neither a
#                  find nor a false alarm — saying "I could not see it" is not
#                  the same as saying "it is broken", and it must never be able
#                  to earn recall.
#   MET            status "met". Never a finding of any sort.
STATUS_NEGATIVE = "gap"
STATUS_BLIND = "untested"

# WHO SAW IT. Three provenances, and they are set where the finding is BORN.
BY_MODEL = "model"        # the look's own criterion, note, reason, filed bug
BY_DETECTOR = "detector"  # a named deterministic pass (xo-parts, xo-observe, …)
# FIX ROUND 2 (D-A). `xo-score.py` writes some criteria's `reason` ITSELF and
# stamps `reasonByHarness: true` on them at birth — the verdict's own record
# that those words are the HARNESS's, not the look's. The scorer pooled them
# with the model's prose, so the tester could silence a look completely, write
# a finding into one such reason, leave the flag standing, and be handed
# "model 1/5, 1 in its own words". The model column exists to be honest about
# exactly that, so the flag is READ — never inferred from the wording — and
# text it marks is scored as the harness's own eye, beside the model's and
# never inside it. Look D carries nine of these today; they are all
# couldn't-check, so nothing measured so far moves, which is the point of
# curing a latent inflation before it bites.
BY_HARNESS = "harness"    # a sentence the harness wrote into the verdict


def flat(s):
    return re.sub(r"\s+", " ", str(s or "")).strip()


def load(p, default=None):
    try:
        with open(p) as fh:
            return json.load(fh)
    except Exception:
        return default


def collect_findings(look):
    """-> (negatives, blinds), each a list of
       {'src','by','detector','id','text' (may name the part),
        'said' (the look's own words)}.
    A finding is scoped to ONE criterion: a sentence elsewhere in the report
    must not be able to pay for a criterion the look graded "worked"."""
    neg, blind = [], []
    v = load(os.path.join(look, "verdict.json"), {}) or {}
    for c in v.get("criteria") or []:
        # TWO TEXTS, AND THE DIFFERENCE MATTERS.
        #
        # `text` is the criterion — which, on both arms, is the PRD's own
        # sentence and therefore already contains the fault's vocabulary ("16px
        # inside a 34px control", "on one line", "red (#c0392b)"). If the kind
        # were matched against that, then merely grading a criterion "didn't
        # work" would score as having FOUND the fault, whatever the look
        # actually said — and the benchmark would be reading its own question
        # back as the answer.
        #
        # So: the part may be NAMED by the criterion (that is what a criterion
        # is for), but the COMPLAINT has to be in the look's own words — its
        # note and its reason.
        #
        # …AND `reason` IS ONLY THE LOOK'S WORDS WHEN THE RECORD SAYS IT IS.
        # `reasonByHarness` is the verdict's own at-birth stamp (D-A above):
        # where it stands, that sentence is struck out of the model's half and
        # scored as the harness's own, whatever it happens to say.
        by_harness = bool(c.get("reasonByHarness"))
        mine = ("note", "detail") if by_harness else ("note", "reason", "detail")
        name_txt = flat(" ".join(str(c.get(k) or "") for k in ("text",) + mine))
        said_txt = flat(" ".join(str(c.get(k) or "") for k in mine))
        rec = {"src": "criterion", "by": BY_MODEL, "detector": None,
               "id": c.get("id"), "text": name_txt, "said": said_txt,
               "status": c.get("status"), "impact": c.get("impact")}
        if c.get("status") == STATUS_NEGATIVE:
            neg.append(rec)
            # The struck-out sentence rides beside it as the HARNESS's own
            # finding — on the NEGATIVE side only. `blind` is a count of
            # criteria the look could not check, and a second record per
            # criterion would inflate that count without a second criterion
            # existing; the number the doc publishes stays a number of
            # criteria.
            if by_harness and flat(c.get("reason")):
                h_said = flat(c.get("reason"))
                neg.append({"src": "criterion-harness-reason", "by": BY_HARNESS,
                            "detector": None, "id": c.get("id"),
                            "text": flat("%s %s" % (c.get("text") or "", h_said)),
                            "said": h_said, "status": c.get("status"),
                            "impact": c.get("impact")})
        elif c.get("status") == STATUS_BLIND:
            blind.append(rec)
    o = load(os.path.join(look, "observations.json"), {}) or {}
    for ob in o.get("observations") or []:
        if isinstance(ob, dict):
            txt = flat(" ".join(str(x) for x in ob.values() if isinstance(x, (str, int, float))))
            oid = ob.get("id") or ob.get("kind") or ob.get("what")
            det = ob.get("kind") or "layout"
        else:
            txt, oid, det = flat(ob), None, "layout"
        # An observation IS a DETECTOR's own words — xo-parts' measurement of a
        # pair, xo-observe's layout pass, xo-journey's carry check. It is never
        # the model's eye, and the two are never pooled.
        neg.append({"src": "observation", "by": BY_DETECTOR, "detector": det,
                    "id": oid, "text": txt, "said": txt, "status": "observation"})
    # Filed bugs, wherever this version of the look puts them. A bug is written
    # by the look in its own words, so it counts on the model's side.
    for p in sorted(glob.glob(os.path.join(look, "logs", "**", "*.json"), recursive=True)):
        d = load(p)
        for b in (d if isinstance(d, list) else (d or {}).get("bugs") or []):
            if isinstance(b, dict):
                t = flat(" ".join(str(x) for x in b.values()
                                  if isinstance(x, (str, int, float))))
                neg.append({"src": "filed-bug", "by": BY_MODEL, "detector": None,
                            "id": b.get("id") or os.path.basename(p),
                            "text": t, "said": t, "status": "filed"})
    return neg, blind


def any_match(pats, text):
    return any(re.search(p, text, re.I) for p in pats)


# --- reading a finding as CLAUSES (fix round 1, D2) --------------------------
# A criterion is one lump of prose and the old rule matched over the whole
# lump: the part's name out of the question it was asked, the fault's kind out
# of ANY sentence of the answer. A note that said "all four of those controls
# render correctly — the only problem is the org-picker icon, which is 72px"
# therefore scored those four controls FOUND. Name from the question, kind from
# a sentence about something else, and nobody in the chain about the same part.
#
# So the kind is matched CLAUSE BY CLAUSE, and a clause that plainly introduces
# a different subject cannot pay for this part.
CLAUSE_SPLIT = re.compile(r"(?<=[.;!?])\s+|\s+—\s+(?=(?:the|this|its|it|and)\b)", re.I)

# A subject is "another named thing" when the clause points at it by a NAME —
# a hyphenated compound, a camelCase id or a quoted label — sitting directly in
# front of a word for a part. `single-line`, `34px-tall` and `read-only` are
# adjectives, not names, so they are excluded: a compound made of digits, or
# ending in one of the shape words below, never counts as a subject.
PART_WORD = (r"(?:icon|glyph|svg|button|control|chip|label|link|field|picker|"
             r"menu|tab|card|toggle|bar|box|panel|badge|pill|input|textarea)")
ADJ_TAIL = re.compile(r"-(line|lines|tall|wide|high|deep|sized|size|only|left|right|top|"
                      r"bottom|level|coloured|colored|width|height|px|point|case)$", re.I)
NAMED_SUBJECT = re.compile(
    r"(?:"
    r"\b([a-z]{2,}(?:-[a-z]{2,})+)\s+" + PART_WORD + r"\b"       # org-picker icon
    r"|\b([a-z]+[A-Z][A-Za-z]+)\s*" + PART_WORD + r"?\b"          # themeBtn
    r"|[\"“']([^\"”']{2,40})[\"”']\s*" + PART_WORD + r"\b"        # "Back to builder" button
    r"|\b([a-z]{2,}(?:-[a-z]{2,})*-" + PART_WORD + r")\b"         # org-picker
    r")")


def clauses(said):
    out = [c.strip() for c in CLAUSE_SPLIT.split(flat(said)) if c and c.strip()]
    return out or ([flat(said)] if flat(said) else [])


def names_another_subject(clause, names):
    """True when this clause points at a named thing that is NOT this part."""
    for m in NAMED_SUBJECT.finditer(clause):
        subj = next((g for g in m.groups() if g), "")
        if not subj:
            continue
        if re.search(r"\d", subj) or ADJ_TAIL.search(subj):
            continue          # an adjective, not a name
        if any_match(names, subj) or any_match(names, m.group(0)):
            continue          # it IS this part
        return True
    return False


# --- the KIND test (fix round 1, D3) -----------------------------------------
# The kind vocabulary is declared in known-answers/kinds.json. One kind also
# has a COMPARATOR, because the fault it names is a comparison and a regex
# cannot do a comparison: the old `oversized-icon` pattern carried a bare
# `4[0-9]|[5-9][0-9]|…px` floor, so a MEASURED 34px icon in a 32px control —
# the real Lock month button, a declared known fault — was not "oversized"
# until someone happened to write prose about it. A floor invented inside a
# regex is not a fault definition; the icon being bigger than the thing that
# holds it is.
#
# FIX ROUND 2 (D-B) — WHAT REPLACED THE FLOOR WAS STILL NOT A COMPARISON.
# Round 1's comparator read its two numbers with four overlapping regexes and
# a non-overlapping scan, so in the ONE word order a person actually writes —
# "holds a 34px icon inside a 32px control" — the icon's own 34 was swallowed
# as the HOLDER's measurement (the `34px … control` match ate the `32px
# control` that followed it), min(holders) came back 34, and 34 > 34 was
# false. Measured over 18 phrasings, six missed, including the two a person
# is most likely to write: "Back to builder has an icon taller than the
# button it sits in" and "has a 34px icon in a 32px button". What was left
# was a phrase list wearing a comparator's name.
#
# So the pair is read the way a reader reads it. EVERY measurement in the
# sentence is found once, and each is attached to the NEAREST part word —
# looking forward no further than the next measurement ("34px icon"), and
# backward no further than the previous one ("its icon is 34px"), whichever
# noun is closer. No number can then be claimed twice, and no noun on the far
# side of another number can claim one.
#
# And a comparison stated in WORDS is a comparison. "an icon taller than the
# button it sits in" states the same fact as "41px inside 30px" and must count
# the same. That is read generically — an icon word, a comparative ("<x>er
# than", "too <x> for/to fit"), a holder word — not from a list of phrases;
# the only list is of the comparatives that point the OTHER way (smaller,
# shorter, narrower…), because direction is the whole fault.
# FIX ROUND 3 (F2) — THE COMPARATOR DID NOT KNOW THE WORD "ARROW".
# The vocabulary was a short list of the words the harness itself writes, so
# the identical sentence scored 1 with "icon" in it and 0 with "arrow" — and
# this bit the REAL case: the build's Continue-to-builder icon IS an arrow,
# and the look's own words for it are "an oversized arrow icon". A person
# writing to the captain says arrow, symbol, graphic, mark or badge as
# readily as icon. They are all the thing INSIDE the control; none of them
# changes which way the comparison points, so widening the list cannot loosen
# a single must-not-fire case — an icon that FITS still fails the comparison,
# a smaller-than still fails the direction guard, and a clause about another
# named part is still another part's clause.
# The words are bounded (\b…\b) and allowed a plural, so "bookmark",
# "marked" and "remarkable" are not icons.
ICON_WORD = (r"\b(?:icon|glyph|svg|chevron|caret|logo|image|arrow|symbol|"
             r"graphic|artwork|mark|badge)s?\b")
HOLDER_WORD = r"(?:control|button|pill|chip|box|field|tab|link|cell)"
MEASURE = re.compile(r"(\d{1,4})\s*(?:px|pt)\b", re.I)
ICON_RE = re.compile(ICON_WORD, re.I)
HOLDER_RE = re.compile(HOLDER_WORD, re.I)
# "…er than" / "too big for" — the comparative itself, whatever adjective is
# used. SMALLER_STEMS is the direction guard: an icon SMALLER than its button
# is not this fault.
SMALLER_STEMS = ("small", "short", "narrow", "slim", "thin", "tini", "low",
                 "light", "tight")
BIGGER_CMP = re.compile(r"\b([a-z]{3,})er\s+than\b|\btoo\s+[a-z]{2,}\s+(?:for|to fit)\b", re.I)


def _nearest_word(text, lo, hi, at):
    """Which part word sits nearest `at` inside text[lo:hi] — 'icon', 'holder'
    or None. Distance is measured from the measurement, either side."""
    best = (None, None)
    for tag, rx in (("icon", ICON_RE), ("holder", HOLDER_RE)):
        for m in rx.finditer(text, lo, hi):
            d = (at - m.end()) if m.end() <= at else (m.start() - at)
            if best[1] is None or d < best[1]:
                best = (tag, d)
    return best[0]


def measured_pair(text):
    """-> (icon_px, holder_px) read out of the look's own sentence, or None.

    Each measurement is attached to the nearest part word, with the window
    bounded by the neighbouring measurements so no number is counted twice.
    """
    ms = list(MEASURE.finditer(text))
    if not ms:
        return None
    icons, holders = [], []
    for i, m in enumerate(ms):
        lo = ms[i - 1].end() if i else 0
        hi = ms[i + 1].start() if i + 1 < len(ms) else len(text)
        tag = _nearest_word(text, lo, hi, (m.start() + m.end()) // 2)
        if tag == "icon":
            icons.append(int(m.group(1)))
        elif tag == "holder":
            holders.append(int(m.group(1)))
    if not icons or not holders:
        return None
    return (max(icons), min(holders))


def stated_comparison(text):
    """True when the sentence SAYS the icon is bigger than what holds it,
    without measuring it — "an icon taller than the button it sits in"."""
    for m in BIGGER_CMP.finditer(text):
        stem = (m.group(1) or "").lower()
        if stem and stem.startswith(SMALLER_STEMS):
            continue
        before, after = text[:m.start()], text[m.end():]
        # the icon on one side of the comparison, the thing holding it on the
        # other — in either order ("the button is smaller than its icon" is
        # excluded by the stem guard above, not by the order).
        if ICON_RE.search(before) and HOLDER_RE.search(after):
            return True
        if HOLDER_RE.search(before) and ICON_RE.search(after):
            return True
    return False


def icon_bigger_than_its_control(text):
    """-> True when the look's own words put an icon above the thing that
    holds it — either by stating both measurements, or by saying so.

    No floor, no magic number: 34 > 32 is an oversized icon and 15 < 38 is not.
    """
    pair = measured_pair(text)
    if pair and pair[0] > pair[1]:
        return True
    if pair and pair[0] <= pair[1]:
        # The sentence measured it and the icon FITS. A stated comparison
        # cannot overrule the numbers in the same breath.
        return False
    return stated_comparison(text)


COMPARATORS = {"icon-bigger-than-its-control": icon_bigger_than_its_control}


def kind_clauses(kind_names, kinds, comparators, said):
    """Every clause of the look's own words that reads as one of these kinds.

    A comparator's measurements may straddle two sentences ("Its icon is 34px.
    The control is only 32px."), so it is asked of the WHOLE finding and its
    answer is attached to the clause that carries the icon — the clause a
    reader would point at.

    FIX ROUND 2 (D-B): that clause is found by the ICON WORD, not by a number.
    Round 1 looked for a measurement in the clause, so a finding that states
    its comparison in words — "an icon taller than the button it sits in" —
    had nowhere to attach and the comparator's answer was thrown away.
    """
    pats = [p for k in kind_names for p in kinds.get(k, [])]
    cls = clauses(said)
    hits = []
    for c in cls:
        if any_match(pats, c):
            hits.append(c)
    for k in kind_names:
        fn = COMPARATORS.get((comparators or {}).get(k) or "")
        if fn and fn(flat(said)):
            own = [c for c in cls if ICON_RE.search(c)]
            for c in (own or cls[:1]):
                if c not in hits:
                    hits.append(c)
    return hits


def judge(entry, kinds, negatives, comparators=None, require_kind=True):
    """THE RULE, in one place.

    A finding matches a declared part when BOTH halves hold in the SAME
    finding, ABOUT THE SAME PART:
       (a) it NAMES the part  — one of the entry's partNames regexes, and
       (b) it is OF THE KIND  — one of the declared kind's regexes (or that
           kind's comparator), in a clause that is about THIS part.
    Two halves, because either alone is a text search: "lock" appears in a
    dozen criteria that are nothing to do with the button, and "two lines"
    appears wherever a look talks about wrapping anything at all.

    "About this part" is the D2 fix. A clause that both names the part and
    carries the kind is the strongest possible match and is taken at once. When
    the name only comes from the criterion's QUESTION, the kind's clause must
    at least not be about some other named thing — otherwise the name is the
    question and the complaint is the answer to a different one.

    For a CORRECT control (require_kind stays True) the kind half is widened
    to the WHOLE vocabulary: flagging the tab bar for any reason at all is a
    false alarm, not just flagging it for the one fault it does not have.
    """
    names = entry.get("partNames") or [entry.get("part") or ""]
    ks = entry.get("kinds") or ([entry["kind"]] if entry.get("kind") else list(kinds))
    for f in negatives:
        if not any_match(names, f["text"]):
            continue
        if not require_kind:
            return dict(f, matchedClause=None)
        # The kind is matched against what the LOOK said, never against the
        # requirement it was handed. See collect_findings().
        hits = kind_clauses(ks, kinds, comparators, f.get("said", f["text"]))
        if not hits:
            continue
        own = [c for c in hits if any_match(names, c)]
        if own:
            return dict(f, matchedClause=own[0])
        clean = [c for c in hits if not names_another_subject(c, names)]
        if clean:
            return dict(f, matchedClause=clean[0])
    return None


def walked(look):
    """Part F: did the look move through the app's own controls, or teleport?

    Read from the RECORD — the action lists the look actually executed — and
    reported as counts, never as a verdict on its own.
    """
    navs = clicks = types = keys = 0
    for p in sorted(glob.glob(os.path.join(look, "actions-*.json"))):
        for a in load(p, []) or []:
            if not isinstance(a, dict):
                continue
            for k in a:
                if k in ("navigate", "goto", "url"):
                    navs += 1
                elif k == "click":
                    clicks += 1
                elif k in ("type", "fill"):
                    types += 1
                elif k in ("press", "key"):
                    keys += 1
    return {"navigations": navs, "clicks": clicks, "typings": types, "keypresses": keys,
            # One navigation is allowed: the front door. Every later one is a jump.
            "jumpsPastEntry": max(0, navs - 1)}


def walked_declared(look):
    """Part F's OWN walk — `walk.json`, the declared journey the HARNESS drives.

    `walked()` above reads `actions-*.json`, which is the list of moves the
    WORKER asked for. Part F added a second mover: LCARS itself walks the
    declared journey before the worker says anything, and records it in
    `walk.json` instead. Counting only the worker's list reports 0 clicks for a
    look that clicked seven times, so both are reported, separately and
    labelled — neither is folded into the other, because the baseline numbers
    in BASELINE.md were taken with the worker-list rule and have to stay
    comparable.

    A step is counted only when it actually happened: `status == "done"`. A
    step the walk could not reach (`unreachable`), one that changed nothing
    (`no-change`, fix round 1 D6) or one a control refused is a step NOT taken,
    and is counted in its own column so the two can never be confused.
    """
    w = load(os.path.join(look, "walk.json"), {}) or {}
    if not isinstance(w, dict):
        return None
    steps = w.get("steps") or []
    if not isinstance(steps, list):
        return None
    navs = clicks = types = keys = 0
    reached = nochange = unreachable = 0
    for s in steps:
        if not isinstance(s, dict):
            continue
        st = s.get("status")
        if st == "no-change":
            nochange += 1
            continue
        if st == "unreachable":
            unreachable += 1
            continue
        if st != "done":
            continue
        reached += 1
        do = s.get("do")
        if do in ("click", "gate"):
            clicks += 1
        elif do in ("type", "type-all", "fill"):
            types += 1
        elif do in ("press", "key"):
            keys += 1
        elif do in ("navigate", "goto", "url"):
            navs += 1
    return {"entry": w.get("entry"), "steps": len(steps), "stepsTaken": reached,
            "stepsNoChange": nochange, "stepsUnreachable": unreachable,
            "navigations": navs, "clicks": clicks, "typings": types, "keypresses": keys,
            # The entry is the front door and is not in `navigations`; any
            # navigate STEP is a jump past it.
            "jumpsPastEntry": navs}


def box_area(b):
    try:
        return float(b.get("w") or 0) * float(b.get("h") or 0)
    except Exception:
        return 0.0


def not_comparable(look, entry):
    """A declared-correct control with NOTHING DRAWN for it (fix round 1, D4).

    "Zero false alarms on the correct control" is only a fact if the control
    was compared at all. On the real arm the Preview button's DRAWN box is
    0x0 — the drawing has no such part — so the look had nothing to hold the
    build against and the clean sheet was imaginary. Read from pairs.json,
    which is the record of what was actually put side by side.
    """
    pairs = (load(os.path.join(look, "pairs.json"), {}) or {}).get("pairs")
    if not isinstance(pairs, list):
        return None
    names = entry.get("partNames") or [entry.get("part") or ""]
    for p in pairs:
        if not isinstance(p, dict):
            continue
        label = flat("%s %s" % (p.get("name") or "", p.get("part") or ""))
        if not (any_match(names, label) or any_match(names, label + " button")):
            continue
        drawn = (p.get("drawn") or {}).get("box") or {}
        if box_area(drawn) <= 0:
            return "nothing was drawn for it (its drawn box is 0x0), so the " \
                   "build was never compared against anything"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("look")
    ap.add_argument("answers")
    ap.add_argument("--kinds", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                    "known-answers", "kinds.json"))
    ap.add_argument("--json", dest="out")
    ap.add_argument("--label", default="")
    a = ap.parse_args()

    ka = load(a.answers)
    if ka is None:
        sys.exit("cannot read known answers: %s" % a.answers)
    kdoc = load(a.kinds) or {}
    kinds = kdoc.get("kinds") or {}
    comparators = kdoc.get("comparators") or {}
    if not os.path.isdir(a.look):
        sys.exit("no look directory at %s — nothing to score." % a.look)

    neg, blind = collect_findings(a.look)
    by_model = [f for f in neg if f["by"] == BY_MODEL]
    by_detector = [f for f in neg if f["by"] == BY_DETECTOR]
    by_harness = [f for f in neg if f["by"] == BY_HARNESS]
    verdict = load(os.path.join(a.look, "verdict.json"), {}) or {}

    # EACH EYE JUDGED ON ITS OWN, then the union. Never one pass over a pooled
    # list: `judge()` returns the FIRST match, so a pooled list credits
    # whichever provenance happened to be built first.
    faults = []
    for f in ka.get("faults") or []:
        m = judge(f, kinds, by_model, comparators)
        d = judge(f, kinds, by_detector, comparators)
        h = judge(f, kinds, by_harness, comparators)
        faults.append({**f, "byModel": m, "byDetector": d, "byHarness": h,
                       "matchedBy": m or d or h})
    found = [f for f in faults if f["matchedBy"]]
    missed = [f for f in faults if not f["matchedBy"]]
    model_found = [f for f in faults if f["byModel"]]
    det_found = [f for f in faults if f["byDetector"]]
    harness_found = [f for f in faults if f["byHarness"]]

    corrects = []
    for c in ka.get("correct") or []:
        m = judge(c, kinds, by_model, comparators)
        d = judge(c, kinds, by_detector, comparators)
        h = judge(c, kinds, by_harness, comparators)
        corrects.append({**c, "byModel": m, "byDetector": d, "byHarness": h,
                         "matchedBy": m or d or h,
                         "notComparable": not_comparable(a.look, c)})
    alarms = [c for c in corrects if c["matchedBy"]]
    model_alarms = [c for c in corrects if c["byModel"]]
    det_alarms = [c for c in corrects if c["byDetector"]]
    uncomparable = [c for c in corrects if c["notComparable"]]
    journey = []
    for j in ka.get("journey") or []:
        hit = judge(j, kinds, neg, comparators) if j.get("kind") or j.get("kinds") else None
        journey.append({**j, "matchedBy": hit})

    ladder = ka.get("gradeLadder") or ["low", "medium", "high"]
    grade = verdict.get("score")
    cap = ka.get("gradeMustBeAtMost")
    try:
        grade_ok = grade is not None and cap is not None and ladder.index(grade) <= ladder.index(cap)
    except ValueError:
        grade_ok = None

    nf = len(ka.get("faults") or [])
    nc = len(ka.get("correct") or [])

    def rate(n):
        return round(n / nf, 3) if nf else None

    res = {
        "case": ka.get("case"), "label": a.label, "look": os.path.abspath(a.look),
        "knownFaults": nf, "found": len(found),
        "recall": rate(len(found)),
        # D1 — THE THREE NUMBERS. The model's own eye, the detectors', and the
        # union that used to be reported alone as if it were one eye's work.
        "recallByModel": rate(len(model_found)), "foundByModel": len(model_found),
        "recallByDetector": rate(len(det_found)), "foundByDetector": len(det_found),
        # D-A: the harness's own sentences, counted apart from both.
        "recallByHarness": rate(len(harness_found)), "foundByHarness": len(harness_found),
        "recallUnion": rate(len(found)),
        "correctControls": nc, "falseAlarms": len(alarms),
        "falseAlarmsByModel": len(model_alarms), "falseAlarmsByDetector": len(det_alarms),
        "notComparable": len(uncomparable),
        "grade": grade, "gradeMustBeAtMost": cap, "gradeOk": grade_ok,
        # THE GRADE ON ITS OWN IS NOT THE SIGNAL, and reading it as one is how a
        # benchmark flatters. A look can grade a build LOW because it could not
        # see anything at all — which is what happened on the real case's
        # baseline — and a bare "grade is low, as required" would call that a
        # pass. So the grade only counts as EARNED when it is low enough AND at
        # least one of the declared faults is what drove it there.
        "gradeEarned": bool(grade_ok) and len(found) > 0,
        "findings": {"negative": len(neg), "couldNotCheck": len(blind),
                     "byModel": len(by_model), "byDetector": len(by_detector),
                     "byHarness": len(by_harness)},
        "walk": walked(a.look),
        "walkDeclared": walked_declared(a.look),
        "detail": {
            "found": [{"key": f["key"],
                       "by": (BY_MODEL if f["byModel"]
                              else BY_DETECTOR if f["byDetector"] else BY_HARNESS),
                       "eyes": [e for e, v in ((BY_MODEL, f["byModel"]),
                                               (BY_DETECTOR, f["byDetector"]),
                                               (BY_HARNESS, f["byHarness"])) if v],
                       "detector": (f["byDetector"] or {}).get("detector") if f["byDetector"] else None,
                       "id": (f["matchedBy"] or {}).get("id"),
                       "src": (f["matchedBy"] or {}).get("src"),
                       "quote": (f["matchedBy"] or {}).get("said", "")[:300]} for f in found],
            "missed": [{"key": f["key"], "what": f["what"]} for f in missed],
            "falseAlarms": [{"key": c["key"],
                             "by": (BY_MODEL if c["byModel"]
                                    else BY_DETECTOR if c["byDetector"] else BY_HARNESS),
                             "id": (c["matchedBy"] or {}).get("id"),
                             "quote": (c["matchedBy"] or {}).get("said", "")[:300]} for c in alarms],
            "notComparable": [{"key": c["key"], "why": c["notComparable"]} for c in uncomparable],
            "journey": [{"key": j["key"], "what": j["what"],
                         "reported": bool(j.get("matchedBy"))} for j in journey],
        },
    }

    w = res["walk"]
    print("── S220 bench · %s%s" % (res["case"], (" · " + a.label) if a.label else ""))
    print("   recall        %d/%d by the model's own eye%s"
          % (len(model_found), nf, ("  (%.0f%%)" % (100 * res["recallByModel"])) if nf else ""))
    print("                 %d/%d by the detectors%s"
          % (len(det_found), nf, ("  (%.0f%%)" % (100 * res["recallByDetector"])) if nf else ""))
    print("                 %d/%d the two together%s"
          % (len(found), nf, ("  (%.0f%%)" % (100 * res["recall"])) if nf else ""))
    print("   false alarms  %d of %d correct control(s) flagged — %d by the model, %d by a detector"
          % (len(alarms), nc, len(model_alarms), len(det_alarms)))
    for c in res["detail"]["notComparable"]:
        print("   ⚠ %-20s NOT COMPARABLE — %s" % (c["key"], c["why"]))
    print("   grade         %s (must be at most %s) → %s, %s"
          % (grade, cap, {True: "low enough", False: "TOO HIGH", None: "unknown"}[grade_ok],
             "earned by a known fault" if res["gradeEarned"]
             else "NOT earned — no declared fault drove it"))
    print("   the look said %d didn't-work (%d in its own words, %d from a detector, "
          "%d in a sentence the harness wrote), %d couldn't-check"
          % (res["findings"]["negative"], res["findings"]["byModel"],
             res["findings"]["byDetector"], res["findings"]["byHarness"],
             res["findings"]["couldNotCheck"]))
    print("   it moved by   %d click(s), %d typing(s), %d keypress(es), %d address jump(s) past the front door"
          % (w["clicks"], w["typings"], w["keypresses"], w["jumpsPastEntry"]))
    wd = res["walkDeclared"]
    if wd:
        print("   the declared journey (part F, walk.json): %d of %d step(s) taken, "
              "%d changed nothing, %d unreachable — %d click(s), %d typing(s), %d address jump(s) past the front door"
              % (wd["stepsTaken"], wd["steps"], wd["stepsNoChange"], wd["stepsUnreachable"],
                 wd["clicks"], wd["typings"], wd["jumpsPastEntry"]))
    for f in res["detail"]["found"]:
        print("   ✓ %-20s [%s] %s" % (f["key"], "+".join(f["eyes"]), f["quote"][:100]))
    for f in res["detail"]["missed"]:
        print("   ✗ %-20s MISSED — %s" % (f["key"], f["what"][:100]))
    for f in res["detail"]["falseAlarms"]:
        print("   ! %-20s FALSE ALARM [%s] — %s" % (f["key"], f["by"], f["quote"][:100]))
    for j in res["detail"]["journey"]:
        print("   %s %-20s %s" % ("✓" if j["reported"] else "·", j["key"], j["what"][:100]))

    if a.out:
        os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
        with open(a.out, "w") as fh:
            json.dump(res, fh, indent=1)
        print("   → %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
