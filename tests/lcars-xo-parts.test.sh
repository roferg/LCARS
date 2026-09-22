#!/usr/bin/env bash
#
# Tests for SIDE BY SIDE, PART BY PART (Session 220, parts B, C and D) — the
# four buttons Number One graded "worked" on 2026-09-19 with the oversized
# icons in its own frame.
#
# Skill source under test:
#   skills/lcars-xo/xo-drive.js   — `--parts-out`: every interactive/labelled
#                                    part of a page, wherever it sits on it,
#                                    with its icon box and its label's LINE
#                                    COUNT, and a 2x crop of each.
#   skills/lcars-xo/xo-parts.py   — the pairing and the cheap measurements:
#                                    which handle matched, icon ÷ control,
#                                    lines vs the drawing's; and one criterion
#                                    per drawn part, retiring the catch-all.
#   skills/lcars-xo/xo-score.py   — a part the build has not got can never be
#                                    "worked", and a measured difference the
#                                    look overrules is journaled with its reason.
#   skills/lcars-xo/xo-observe.py — the layout pass runs on EVERY screen and
#                                    every finding names the screen it is on.
#
# WHAT IS REAL HERE. The browser layer (the parts reader) is proven against
# REAL HEADLESS CHROME on a tiny fixture page, exactly as S210's element
# capture is; the pairing, the measurements and the guards are arithmetic and
# are proven directly against crafted JSON of the shape the browser writes.
#
# THE CONTROL IS THE POINT. Every detector has a positive case AND a correct
# control that must NOT fire — a label the drawing itself wraps, and a control
# whose only difference is its width (the spike measured a size delta firing on
# the CORRECT control hardest of all, so it is recorded and never fires).
#
# ZERO SPEND. No worker CLI runs anywhere in this file.
#
# Usage: bash tests/lcars-xo-parts.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
PARTS="${LCARS_XO_PARTS_PY:-$REPO_ROOT/skills/lcars-xo/xo-parts.py}"
OBSERVE="${LCARS_XO_OBSERVE_PY:-$REPO_ROOT/skills/lcars-xo/xo-observe.py}"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
PY="${LCARS_PYTHON_BIN:-python3}"
NODE="${LCARS_NODE_BIN:-node}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ── the fixtures ───────────────────────────────────────────────────────────
# A drawing and a build of the same two controls. In the build the save
# button's icon is far taller than the button and its label has wrapped onto
# three lines; the notice is two lines in BOTH (the drawing wraps too); the
# tab bar is 16% wider than drawn and otherwise correct.
mk_parts() { # <file> <url> <json array of parts>
  "$PY" - "$1" "$2" "$3" <<'PY'
import json, sys
open(sys.argv[1], "w").write(json.dumps({
    "url": sys.argv[2], "title": "fixture", "parts": json.loads(sys.argv[3])}, indent=2))
PY
}

DRAWN='[
 {"index":1,"id":"saveBtn","testid":null,"name":"Save reading","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":120,"h":34},"iconBox":{"x":14,"y":19,"w":16,"h":16},"lines":1,
  "color":"rgb(0,0,0)","background":"rgb(255,255,255)","crop":"drawn-01"},
 {"index":2,"id":"notice","testid":null,"name":"Two readings are stale, check the tide gauge","role":null,"tag":"p",
  "interactive":false,"container":false,"box":{"x":10,"y":60,"w":230,"h":40},"iconBox":null,"lines":2,
  "color":"rgb(0,0,0)","background":"rgba(0,0,0,0)","crop":"drawn-02"},
 {"index":3,"id":"tabBar","testid":null,"name":"Readings","role":"tab","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":120,"w":100,"h":30},"iconBox":null,"lines":1,
  "color":"rgb(0,0,0)","background":"rgb(240,240,240)","crop":"drawn-03"},
 {"index":4,"id":"exportBtn","testid":null,"name":"Export CSV","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":140,"y":10,"w":110,"h":34},"iconBox":null,"lines":1,
  "color":"rgb(0,0,0)","background":"rgb(255,255,255)","crop":"drawn-04"}
]'

BUILT='[
 {"index":1,"id":null,"testid":"save-reading","name":"Save reading","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":74,"h":41},"iconBox":{"x":14,"y":8,"w":44,"h":44},"lines":3,
  "color":"rgb(0,0,0)","background":"rgb(255,255,255)","crop":"built-01"},
 {"index":2,"id":null,"testid":null,"name":"Two readings are stale, check the tide gauge","role":null,"tag":"p",
  "interactive":false,"container":false,"box":{"x":10,"y":60,"w":230,"h":40},"iconBox":null,"lines":2,
  "color":"rgb(0,0,0)","background":"rgba(0,0,0,0)","crop":"built-02"},
 {"index":3,"id":null,"testid":null,"name":"Readings","role":"tab","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":120,"w":116,"h":30},"iconBox":null,"lines":1,
  "color":"rgb(0,0,0)","background":"rgb(240,240,240)","crop":"built-03"}
]'

D="$TMPROOT/pairs"; mkdir -p "$D"
mk_parts "$D/drawing.json" "file:///drawing.html" "$DRAWN"
mk_parts "$D/build.json"   "http://127.0.0.1:5173/#home" "$BUILT"
"$PY" "$PARTS" pair --drawing "$D/drawing.json" --build "$D/build.json" \
      --out "$D/pairs.json" >"$D/pair.log" 2>&1
prc=$?

printf '\n\033[1mB · the pair, and what was measured on it\033[0m\n'
check "the pairing runs" "[ $prc -eq 0 ] && [ -s '$D/pairs.json' ]"

q() { "$PY" - "$D/pairs.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d, "json": json}))
PY
}

check "every drawn part is accounted for (4 in, 4 out)" \
  "[ \"\$(q 'len(d[\"pairs\"])')\" = 4 ]"
check "the save button matched, and the record says by WHICH handle" \
  "q 'next(p[\"handle\"] for p in d[\"pairs\"] if p[\"part\"]==\"saveBtn\")' | grep -qi 'testid\|accessible name'"
check "both crops are on the pair — what was drawn and what was built" \
  "q 'next(bool(p[\"drawn\"][\"crop\"]) and bool(p[\"built\"][\"crop\"]) for p in d[\"pairs\"] if p[\"part\"]==\"saveBtn\")' | grep -q True"
check "B1 · the oversized icon is MEASURED and fires" \
  "q 'next(m[\"fires\"] for p in d[\"pairs\"] if p[\"part\"]==\"saveBtn\" for m in p[\"measurements\"] if m[\"id\"]==\"icon-bigger-than-its-control\")' | grep -q True"
check "B1 · and it says so in numbers a person can read" \
  "q 'next(m[\"says\"] for p in d[\"pairs\"] if p[\"part\"]==\"saveBtn\" for m in p[\"measurements\"] if m[\"id\"]==\"icon-bigger-than-its-control\")' | grep -q '44'"
check "B2 · the label wrapped where the drawing has one line — fires" \
  "q 'next(m[\"fires\"] for p in d[\"pairs\"] if p[\"part\"]==\"saveBtn\" for m in p[\"measurements\"] if m[\"id\"]==\"label-wraps-more-than-drawn\")' | grep -q True"
check "B2 CONTROL · a notice the drawing ALSO wraps does NOT fire" \
  "q 'any(m[\"fires\"] for p in d[\"pairs\"] if p[\"part\"]==\"notice\" for m in p[\"measurements\"])' | grep -q False"
check "CONTROL · the 16% wider tab bar is RECORDED and never fires" \
  "q 'any(m[\"fires\"] for p in d[\"pairs\"] if p[\"part\"]==\"tabBar\" for m in p[\"measurements\"])' | grep -q False"
check "CONTROL · …but the size delta IS on the record as information" \
  "q 'any(m[\"id\"]==\"size-delta\" for p in d[\"pairs\"] if p[\"part\"]==\"tabBar\" for m in p[\"measurements\"])' | grep -q True"
check "B3 · a drawn part the build has not got is couldn't check (unreachable)" \
  "q 'next(p[\"outcome\"] for p in d[\"pairs\"] if p[\"part\"]==\"exportBtn\")' | grep -q 'unreachable'"
check "B3 · and it is never reported as reachable" \
  "q 'next(p[\"reachable\"] for p in d[\"pairs\"] if p[\"part\"]==\"exportBtn\")' | grep -q False"

# A zero-size drawn part is couldn't check, not a crop error (the spike's pullBar).
ZERO='[{"index":1,"id":"pullBar","testid":null,"name":"Pulling data","role":null,"tag":"div",
  "interactive":false,"container":false,"box":{"x":0,"y":0,"w":300,"h":6},"iconBox":null,"lines":1,"crop":null}]'
ZB='[{"index":1,"id":"pullBar","testid":null,"name":"Pulling data","role":null,"tag":"div",
  "interactive":false,"container":false,"box":{"x":0,"y":0,"w":0,"h":6},"iconBox":null,"lines":1,"crop":null}]'
mk_parts "$D/z-drawing.json" "file:///d.html" "$ZERO"
mk_parts "$D/z-build.json" "http://x/#a" "$ZB"
"$PY" "$PARTS" pair --drawing "$D/z-drawing.json" --build "$D/z-build.json" --out "$D/z.json" >/dev/null 2>&1
check "a zero-size drawn part is couldn't check, not a crop error" \
  "$PY -c \"import json;d=json.load(open('$D/z.json'));print(d['pairs'][0]['outcome'])\" | grep -q 'unreachable'"

printf '\n\033[1mB7 · the drawing draws one control twice (S224 item 1)\033[0m\n'
# MEASURED ON THE S222 CAPSTONE, mission lcars-20260920-001-8cb0. A holodeck
# drawing is ONE long page showing every screen stacked, so "Cancel", "View",
# "Lock month" and "Discard draft" are each drawn TWICE. The first instance
# paired; the second could find nothing left to claim and became
# `couldn't check (unreachable)` — and because pairs are keyed by part name,
# the LAST entry won, so four criteria about controls that are right there
# read "your drawing names this part and I could not find it in the build".
# One drawn part key is ONE pair entry, and the entry that FOUND something
# is the one that survives.
DUP='[
 {"index":1,"id":null,"testid":null,"name":"Cancel","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-01"},
 {"index":2,"id":null,"testid":null,"name":"Cancel","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":400,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-02"},
 {"index":3,"id":null,"testid":null,"name":"Ghost control","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":800,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-03"}
]'
DUPB='[{"index":1,"id":null,"testid":null,"name":"Cancel","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"b-01"}]'
mk_parts "$D/dup-drawing.json" "file:///drawing.html" "$DUP"
mk_parts "$D/dup-build.json" "http://127.0.0.1:5173/#home" "$DUPB"
"$PY" "$PARTS" pair --drawing "$D/dup-drawing.json" --build "$D/dup-build.json" \
      --out "$D/dup-pairs.json" >/dev/null 2>&1
dq() { "$PY" -c "import json,sys;d=json.load(open('$D/dup-pairs.json'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "B7 · a part the drawing draws twice is ONE entry, not two" \
  "[ \"\$(dq '[p[\"part\"] for p in d[\"pairs\"]].count(\"cancel\")')\" = 1 ]"
check "B7 · and that entry FOUND the control (it is in the build)" \
  "dq 'next(p[\"reachable\"] for p in d[\"pairs\"] if p[\"part\"]==\"cancel\")' | grep -q True"
check "B7 CONTROL · a part the build genuinely has NOT got is still unreachable" \
  "dq 'next(p[\"reachable\"] for p in d[\"pairs\"] if p[\"part\"]==\"ghost control\")' | grep -q False"
check "B7 CONTROL · …and it still says so in the captain's words" \
  "dq 'next(p[\"outcome\"] for p in d[\"pairs\"] if p[\"part\"]==\"ghost control\")' | grep -q unreachable"
# END TO END: the guard in xo-score must no longer overrule a met criterion
# about a control the build HAS, and must still overrule one it has not.
cat >"$D/dup-criteria.json" <<'JSON'
{"mission":"m","builtBeforeLaunch":true,"hasDrawing":true,"placeNames":[],"pictures":[],
 "criteria":[
  {"id":"part-cancel","text":"the Cancel button matches the drawing","source":"drawing",
   "primary":true,"drawnPart":"cancel"},
  {"id":"part-ghost control","text":"the Ghost control matches the drawing","source":"drawing",
   "primary":true,"drawnPart":"ghost control"}]}
JSON
cat >"$D/dup-verdict-in.json" <<'JSON'
{"score":"high","summary":"looked at both",
 "criteria":[
  {"id":"part-cancel","status":"met","note":"Cancel renders as a single-line pill","shot":"shot-01"},
  {"id":"part-ghost control","status":"met","note":"looked fine to me","shot":"shot-01"}]}
JSON
"$PY" "$SCOREPY" "$D/dup-verdict-in.json" "$D/dup-criteria.json" "$D/dup-verdict-out.json" \
      "" "" "" "$D/dup-pairs.json" >"$D/dup-score.out" 2>&1
sq() { "$PY" -c "import json,sys;d=json.load(open('$D/dup-verdict-out.json'));print([c['status'] for c in d['criteria'] if c['id']==sys.argv[1]])" "$1"; }
check "B7 · a criterion about a twice-drawn control the build HAS is not blanked" \
  "sq 'part-cancel' | grep -q met"
check "B7 CONTROL · the criterion about the missing control IS still blanked" \
  "sq 'part-ghost control' | grep -q untested"

printf '\n\033[1mB8 · the build names a control one way, the drawing another\033[0m\n'
# MEASURED ON THE SAME CAPSTONE. The build gives its selects and textareas an
# `aria-label` ("Status for LTC P75"); the holodeck drawing has none, so the
# drawing names the same control by what is PRINTED on it ("On trackWatchOff
# track") or by its placeholder ("Add an insight for this KPI…"). Both ends
# read the accessible name, so they never met — five status selects and five
# insight boxes, all in the build, all reported missing.
ALTD='[
 {"index":1,"id":null,"testid":null,"name":"On trackWatchOff track","role":null,"tag":"select",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":120,"h":28},"iconBox":null,"lines":1,"crop":"d-01"},
 {"index":2,"id":null,"testid":null,"name":"Add an insight for this KPI","role":null,"tag":"textarea",
  "interactive":true,"container":false,"box":{"x":10,"y":50,"w":300,"h":60},"iconBox":null,"lines":1,"crop":"d-02"},
 {"index":3,"id":null,"testid":null,"name":"Toggle theme","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":120,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-03"}
]'
ALTB='[
 {"index":1,"id":null,"testid":null,"name":"Status for LTC P75","text":"On trackWatchOff track",
  "placeholder":null,"value":null,"role":null,"tag":"select",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":120,"h":28},"iconBox":null,"lines":1,"crop":"b-01"},
 {"index":2,"id":null,"testid":null,"name":"Insight for LTC P75","text":"",
  "placeholder":"Add an insight for this KPI","value":null,"role":null,"tag":"textarea",
  "interactive":true,"container":false,"box":{"x":10,"y":50,"w":300,"h":60},"iconBox":null,"lines":1,"crop":"b-02"},
 {"index":3,"id":null,"testid":null,"name":"Switch to light mode","text":"M","placeholder":null,
  "value":null,"role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":120,"w":34,"h":30},"iconBox":null,"lines":1,"crop":"b-03"}
]'
mk_parts "$D/alt-drawing.json" "file:///drawing.html" "$ALTD"
mk_parts "$D/alt-build.json" "http://127.0.0.1:5173/#mbr/build" "$ALTB"
"$PY" "$PARTS" pair --drawing "$D/alt-drawing.json" --build "$D/alt-build.json" \
      --out "$D/alt-pairs.json" >/dev/null 2>&1
aq() { "$PY" -c "import json,sys;d=json.load(open('$D/alt-pairs.json'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "B8 · a select the drawing names by its printed options pairs with the build's" \
  "aq 'next(p[\"reachable\"] for p in d[\"pairs\"] if p[\"part\"]==\"on trackwatchoff track\")' | grep -q True"
check "B8 · and the record says WHICH handle found it" \
  "aq 'next(p[\"handle\"] for p in d[\"pairs\"] if p[\"part\"]==\"on trackwatchoff track\")' | grep -qi 'text\|placeholder\|label'"
check "B8 · a textarea the drawing names by its placeholder pairs too" \
  "aq 'next(p[\"reachable\"] for p in d[\"pairs\"] if p[\"part\"]==\"add an insight for this kpi\")' | grep -q True"
check "B8 CONTROL · a control whose build label shares NO words stays unreachable" \
  "aq 'next(p[\"reachable\"] for p in d[\"pairs\"] if p[\"part\"]==\"toggle theme\")' | grep -q False"

printf '\n\033[1mB10 · the drawn name is a whole-word run of the built label\033[0m\n'
# THE CAPTAIN'S WORDS. His drawing names a part "Unlock"; his build labels that
# same button "Unlock month". Name matching was exact-only, so it came out
# "Unlock -> couldn't check", and an icon fault he photographed on that button
# had no row to land in. The exact-only rule was there for a reason — it stops
# a button reading "Switch to light mode" answering for a drawn "Toggle theme"
# — but it was too blunt. The rule now: a drawn name that is a WHOLE-WORD RUN
# inside the built label may pair; a name that merely SHARES a word may not.
# Each case below is its OWN pairing so exactly one thing is under test.
wr_pair() { # <slug> <drawn json> <build json>
  mk_parts "$D/$1-d.json" "file:///drawing.html" "$2"
  mk_parts "$D/$1-b.json" "http://127.0.0.1:5173/#cal" "$3"
  "$PY" "$PARTS" pair --drawing "$D/$1-d.json" --build "$D/$1-b.json" \
        --out "$D/$1-p.json" >/dev/null 2>&1
}
wq() { "$PY" -c "import json,sys;d=json.load(open(sys.argv[2]));print(eval(sys.argv[1],{'d':d}))" "$1" "$2"; }

# POSITIVE. The build has TWO controls whose labels begin with the letters
# "unlock": "Unlock month" (the one he drew) and "Unlocked reads" (a decoy).
# The literal char-prefix handle sees both and abstains — exactly how his real
# capstone reported the button missing. Word BOUNDARIES tell them apart:
# "unlock" is a whole word in "Unlock month" but not in "Unlocked reads", so
# the run is UNIQUE and pairs.
wr_pair unlk \
 '[{"index":1,"id":null,"testid":null,"name":"Unlock","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":{"x":14,"y":14,"w":16,"h":16},"lines":1,"crop":"d-01"}]' \
 '[{"index":1,"id":null,"testid":null,"name":"Unlock month","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":140,"h":30},"iconBox":{"x":14,"y":12,"w":26,"h":26},"lines":1,"crop":"b-01"},
  {"index":2,"id":null,"testid":null,"name":"Unlocked reads","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":50,"w":150,"h":30},"iconBox":null,"lines":1,"crop":"b-02"}]'
check "B10 · a drawn 'Unlock' pairs with the built 'Unlock month'" \
  "wq 'd[\"pairs\"][0][\"reachable\"]' '$D/unlk-p.json' | grep -q True"
check "B10 · it is the whole-word 'Unlock month', not the char-prefix 'Unlocked reads'" \
  "wq 'd[\"pairs\"][0][\"built\"][\"crop\"]' '$D/unlk-p.json' | grep -q b-01"
check "B10 · and the record says BY WHICH RULE it matched — a whole-word run" \
  "wq 'd[\"pairs\"][0][\"handle\"]' '$D/unlk-p.json' | grep -qi 'run\|whole.word'"

# POSITIVE, MIDDLE/END. The run sits at the END of the label, so the literal
# prefix handle can never find it — only the new rule can. Build is a LINK so
# the role fence cannot answer instead.
wr_pair mid \
 '[{"index":1,"id":null,"testid":null,"name":"unlock month","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":140,"h":30},"iconBox":null,"lines":1,"crop":"d-01"}]' \
 '[{"index":1,"id":null,"testid":null,"name":"Confirm unlock month","role":"link","tag":"a",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":190,"h":30},"iconBox":null,"lines":1,"crop":"b-01"}]'
check "B10 · a run in the MIDDLE/END of the label pairs too (not just a prefix)" \
  "wq 'd[\"pairs\"][0][\"reachable\"]' '$D/mid-p.json' | grep -q True"

# CONTROL — MERELY SHARES A WORD. "Month view" and "Unlock month" share
# "month", but "Month view" is not a contiguous run of whole words inside
# "Unlock month". Build is a LINK so only the name rule can decide.
wr_pair shr \
 '[{"index":1,"id":null,"testid":null,"name":"Month view","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":110,"h":30},"iconBox":null,"lines":1,"crop":"d-01"}]' \
 '[{"index":1,"id":null,"testid":null,"name":"Unlock month","role":"link","tag":"a",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":140,"h":30},"iconBox":null,"lines":1,"crop":"b-01"}]'
check "B10 CONTROL · a drawn 'Month view' that merely SHARES the word 'month' does NOT pair" \
  "wq 'd[\"pairs\"][0][\"reachable\"]' '$D/shr-p.json' | grep -q False"

# CONTROL — SUBSTRING INSIDE A WORD. "Lock" is letters inside "Unlock", not a
# whole word of "Unlock month". It must not pair.
wr_pair sub \
 '[{"index":1,"id":null,"testid":null,"name":"Lock","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-01"}]' \
 '[{"index":1,"id":null,"testid":null,"name":"Unlock month","role":"link","tag":"a",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":140,"h":30},"iconBox":null,"lines":1,"crop":"b-01"}]'
check "B10 CONTROL · a drawn 'Lock' does NOT match the letters inside 'Unlock'" \
  "wq 'd[\"pairs\"][0][\"reachable\"]' '$D/sub-p.json' | grep -q False"

# CONTROL — AMBIGUITY GUARD. The run "unlock" is a whole word in BOTH
# "Unlock month" and "Unlock week"; pairing an arbitrary one is worse than not
# pairing, so it must abstain — the same caution the len==1 gates already keep.
wr_pair amb \
 '[{"index":1,"id":null,"testid":null,"name":"Unlock","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-01"}]' \
 '[{"index":1,"id":null,"testid":null,"name":"Unlock month","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":10,"w":140,"h":30},"iconBox":null,"lines":1,"crop":"b-01"},
  {"index":2,"id":null,"testid":null,"name":"Unlock week","role":"button","tag":"button",
   "interactive":true,"container":false,"box":{"x":10,"y":50,"w":140,"h":30},"iconBox":null,"lines":1,"crop":"b-02"}]'
check "B10 CONTROL · a run in TWO labels equally does NOT coin-toss a pair" \
  "wq 'd[\"pairs\"][0][\"reachable\"]' '$D/amb-p.json' | grep -q False"

printf '\n\033[1mB9 · the copy of the control that is actually on screen\033[0m\n'
# MEASURED IN REAL HEADLESS CHROME (tests/drives/s224/parts-reach): an SPA
# that hides its screens with display:none records 72 of its 100 parts with a
# 0x0 box, because the computed display of a button INSIDE a hidden section
# is still inline-flex — only the section itself reads "none". Those come
# first in document order, so the hidden "Cancel" claimed the name and the
# real one, two clicks into the walk, was never reached.
HID='[{"index":1,"id":null,"testid":null,"name":"Cancel","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"d-01"}]'
HIDB='[
 {"index":1,"id":null,"testid":null,"name":"Cancel","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":0,"y":0,"w":0,"h":0},"iconBox":null,"lines":1,"crop":null},
 {"index":2,"id":null,"testid":null,"name":"Cancel","role":"button","tag":"button",
  "interactive":true,"container":false,"box":{"x":10,"y":10,"w":90,"h":30},"iconBox":null,"lines":1,"crop":"b-02"}
]'
mk_parts "$D/hid-drawing.json" "file:///drawing.html" "$HID"
mk_parts "$D/hid-build.json" "http://127.0.0.1:5173/#mbr/collect" "$HIDB"
"$PY" "$PARTS" pair --drawing "$D/hid-drawing.json" --build "$D/hid-build.json" \
      --out "$D/hid-pairs.json" >/dev/null 2>&1
hq() { "$PY" -c "import json,sys;d=json.load(open('$D/hid-pairs.json'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "B9 · the laid-out copy answers, not the one on a screen that is hidden" \
  "hq 'd[\"pairs\"][0][\"reachable\"]' | grep -q True"
check "B9 · and it is the crop of the one you can see" \
  "hq 'd[\"pairs\"][0][\"built\"][\"crop\"]' | grep -q b-02"
# THE CONTROL is the zero-size case already above: when the ONLY copy in the
# build has no box, it is still couldn't-check, with that reason.
check "B9 CONTROL · when the only copy has no box it is STILL couldn't check" \
  "$PY -c \"import json;d=json.load(open('$D/z.json'));print(d['pairs'][0]['outcome'],d['pairs'][0]['why'])\" | grep -q 'no laid-out box'"

printf '\n\033[1mC · one requirement per drawn part\033[0m\n'
cat >"$D/criteria.json" <<'JSON'
{"mission":"m","builtBeforeLaunch":true,"hasDrawing":true,"placeNames":["saveBtn"],
 "pictures":[],"criteria":[
  {"id":"prd-1","text":"The board matches the mock-up.","source":"prd","primary":true},
  {"id":"prd-2","text":"A reading can be saved and shows in the list.","source":"prd","primary":true}]}
JSON
"$PY" "$PARTS" criteria --drawing "$D/drawing.json" --criteria "$D/criteria.json" \
      --out "$D/criteria2.json" >"$D/crit.log" 2>&1
cq() { "$PY" - "$D/criteria2.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2], {"d": d}))
PY
}
check "C · each named part became its own requirement" \
  "[ \"\$(cq 'len([c for c in d[\"criteria\"] if c.get(\"source\")==\"drawing\"])')\" = 4 ]"
check "C · the requirement names the part in the captain's words" \
  "cq '[c[\"text\"] for c in d[\"criteria\"] if c.get(\"drawnPart\")==\"saveBtn\"]' | grep -q 'Save reading'"
check "C · the catch-all 'matches the mock-up' row is retired, with its reason" \
  "cq '[(c[\"id\"], c[\"retired\"]) for c in d.get(\"retiredCriteria\", [])]' | grep -q 'prd-1'"
check "C · a retired row is not left on the list to be rated" \
  "cq '[c[\"id\"] for c in d[\"criteria\"]]' | grep -qv \"'prd-1',\" "
check "C · a requirement that is NOT a catch-all is untouched" \
  "cq '[c[\"id\"] for c in d[\"criteria\"] if c[\"id\"]==\"prd-2\" and not c.get(\"retired\")]' | grep -q prd-2"
check "C · with no drawing the contract is unchanged" \
  "$PY '$PARTS' criteria --criteria '$D/criteria.json' --out '$D/criteria3.json' >/dev/null 2>&1; \
   $PY -c \"import json;a=json.load(open('$D/criteria.json'));b=json.load(open('$D/criteria3.json'));import sys;sys.exit(0 if a==b else 1)\""

printf '\n\033[1mB4/B6 · the guards in the ledger\033[0m\n'
# A part the build has not got, which the look nevertheless called met.
cat >"$D/c-part.json" <<'JSON'
{"mission":"m","builtBeforeLaunch":true,"hasDrawing":true,"placeNames":[],"pictures":[],
 "criteria":[
  {"id":"part-exportBtn","text":"the Export CSV button matches the drawing","source":"drawing",
   "primary":true,"drawnPart":"exportBtn"},
  {"id":"part-saveBtn","text":"the Save reading button matches the drawing","source":"drawing",
   "primary":true,"drawnPart":"saveBtn"}]}
JSON
cat >"$D/verdict-in.json" <<'JSON'
{"score":"high","summary":"it all looks right to me",
 "criteria":[
  {"id":"part-exportBtn","status":"met","note":"the Export CSV button is there and correct","shot":"shot-01"},
  {"id":"part-saveBtn","status":"met","note":"the save button looks the same as the drawing","shot":"shot-01"}]}
JSON
"$PY" "$SCOREPY" "$D/verdict-in.json" "$D/c-part.json" "$D/verdict-out.json" "" "" "" "$D/pairs.json" >"$D/score.out" 2>"$D/score.err"
check "B4 · a part the build has not got is never 'worked', whatever the look said" \
  "$PY -c \"import json;d=json.load(open('$D/verdict-out.json'));print([c['status'] for c in d['criteria'] if c['id']=='part-exportBtn'])\" | grep -q untested"
check "B4 · and it says unreachable in plain words" \
  "$PY -c \"import json;d=json.load(open('$D/verdict-out.json'));print([c.get('note') for c in d['criteria'] if c['id']=='part-exportBtn'])\" | grep -qi 'could not\|unreachable\|not there'"
check "B6 · a measured difference the look overruled is journaled, with its reason" \
  "grep -qi 'overrul' '$D/score.out'"
check "B6 · the journaled line carries the look's own reason" \
  "grep -i 'overrul' '$D/score.out' | grep -q 'looks the same as the drawing'"

printf '\n\033[1mD · the layout pass on every screen\033[0m\n'
# Two readouts: the landing screen is clean, the second screen has a row of
# buttons jammed together. One observations.json, and each finding says WHERE.
mkr() { "$PY" - "$1" "$2" "$3" <<'PY'
import json, sys
url, kind = sys.argv[2], sys.argv[3]
els = []
def el(i, x, y, w, h, text, tag="button"):
    return {"id": None, "tag": tag, "className": None, "inputType": None, "ariaLabel": None,
            "text": text, "box": {"x": x, "y": y, "w": w, "h": h},
            "color": "rgb(0,0,0)", "background": "rgb(255,255,255)", "interactive": True,
            "overflowX": 0, "overflowY": 0, "overflowStyleX": "visible", "overflowStyleY": "visible",
            "textOverflow": "clip", "whiteSpace": "normal", "segment": "", "display": "block",
            "flexDirection": "row", "alignItems": "normal", "alignSelf": "auto",
            "path": "0.1.%d" % i, "seen": True, "hiddenBy": None}
if kind == "clean":
    els = [el(1, 20, 20, 100, 30, "One"), el(2, 160, 20, 100, 30, "Two")]
else:
    # Two buttons jammed against each other, and a third well clear of them —
    # so the tight gap BREAKS the row's rhythm instead of being it.
    els = [el(1, 20, 20, 100, 30, "Pull data"), el(2, 121, 20, 100, 30, "Cancel"),
           el(3, 300, 20, 100, 30, "Continue")]
json.dump({"url": url, "page": {"url": url, "title": "app", "elements": els}}, open(sys.argv[1], "w"))
PY
}
O="$TMPROOT/obs"; mkdir -p "$O"
mkr "$O/r0.json" "http://127.0.0.1:5173/#home" clean
mkr "$O/r1.json" "http://127.0.0.1:5173/#mbr/collect" crowded
"$PY" "$OBSERVE" "$O/r0.json" "$O/obs.json" >/dev/null 2>&1
check "D · round 0's clean screen finds nothing (the control)" \
  "$PY -c \"import json;print(json.load(open('$O/obs.json'))['foundCount'])\" | grep -q '^0$'"
"$PY" "$OBSERVE" "$O/r1.json" "$O/obs.json" --merge --screen "http://127.0.0.1:5173/#mbr/collect" >/dev/null 2>&1
oq() { "$PY" -c "import json,sys;d=json.load(open('$O/obs.json'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
check "D · a later screen's findings are ADDED to the same record" \
  "[ \"\$(oq 'd[\"foundCount\"]')\" != 0 ]"
check "D · every finding names the screen it is on" \
  "oq 'all(o.get(\"screen\") for o in d[\"observations\"])' | grep -q True"
check "D · and the screen is the one it was seen on" \
  "oq '[o.get(\"screen\") for o in d[\"observations\"]]' | grep -q 'mbr/collect'"
check "D · the record lists every screen the pass ran on" \
  "oq 'd.get(\"screens\")' | grep -q '#home'"

printf '\n\033[1mThe browser layer, for real\033[0m\n'
FIX="$TMPROOT/fixture"; mkdir -p "$FIX"
cat >"$FIX/page.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>parts fixture</title>
<style>body{font:14px system-ui;margin:0;padding:20px}
button{display:inline-flex;align-items:center;gap:4px;height:34px;padding:0 8px;border:1px solid #888}
#saveBtn{width:74px;height:41px}
#saveBtn .ico{width:44px;height:44px;background:#333;display:inline-block}
#okBtn .ico{width:16px;height:16px;background:#333;display:inline-block}
#spacer{height:1400px}</style>
<button id="saveBtn" data-testid="save-reading"><span class="ico"></span>Save reading</button>
<button id="okBtn">< span class="ico"></span>OK</button>
<select id="statusSel" aria-label="Status for LTC P75"><option>On track</option><option>Watch</option></select>
<textarea id="insightBox" aria-label="Insight for LTC P75" placeholder="Add an insight for this KPI"></textarea>
<div id="spacer"></div>
<button id="belowFold" aria-label="Way down here">Way down here</button>
HTML
PARTSOUT="$TMPROOT/partsout"; mkdir -p "$PARTSOUT"
"$NODE" "$DRIVER" --url "file://$FIX/page.html" --out "$PARTSOUT" --parts-out "$PARTSOUT/parts.json" \
   --prefix drawn >"$PARTSOUT/drive.json" 2>"$PARTSOUT/drive.err"
drc=$?
if [ "$drc" -eq 77 ] || [ ! -s "$PARTSOUT/parts.json" ]; then
  printf '  \033[33mSKIP\033[0m no usable Chrome here (%s)\n' "$(head -1 "$PARTSOUT/drive.err" 2>/dev/null)"
else
  pq() { "$PY" -c "import json,sys;d=json.load(open('$PARTSOUT/parts.json'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
  check "the parts reader finds the page's controls" "[ \"\$(pq 'len(d[\"parts\"])')\" -ge 3 ]"
  check "a control's icon is measured, in its own box" \
    "pq 'next(p[\"iconBox\"][\"h\"] for p in d[\"parts\"] if p[\"id\"]==\"saveBtn\")' | grep -q 44"
  check "the label's LINE COUNT is measured, not guessed" \
    "[ \"\$(pq 'next(p[\"lines\"] for p in d[\"parts\"] if p[\"id\"]==\"saveBtn\")')\" -ge 2 ]"
  check "a one-line label reads as one line" \
    "[ \"\$(pq 'next(p[\"lines\"] for p in d[\"parts\"] if p[\"id\"]==\"okBtn\")')\" = 1 ]"
  check "data-testid is recorded when the project uses it" \
    "pq '[p[\"testid\"] for p in d[\"parts\"] if p[\"id\"]==\"saveBtn\"]' | grep -q save-reading"
  check "a part BELOW THE FOLD is still a part (the drawing is one long page)" \
    "pq '[p[\"id\"] for p in d[\"parts\"]]' | grep -q belowFold"
  check "each part got its own 2x crop" \
    "ls '$PARTSOUT'/*.png >/dev/null 2>&1"
  # S224 item 1: the accessible name is not the only name a control has. A
  # holodeck drawing has no aria-labels, so it names the same control by what
  # is PRINTED on it, or by its placeholder. The reader has to write both
  # down or the two records can never meet.
  check "B8 · the reader records the text PRINTED on a control, beside its name" \
    "pq 'next(p.get(\"text\") for p in d[\"parts\"] if p[\"id\"]==\"statusSel\")' | grep -qi 'on track'"
  check "B8 · the accessible name is still recorded, and is the different one" \
    "pq 'next(p[\"name\"] for p in d[\"parts\"] if p[\"id\"]==\"statusSel\")' | grep -q 'Status for LTC P75'"
  check "B8 · a placeholder is recorded as the name it is" \
    "pq 'next(p.get(\"placeholder\") for p in d[\"parts\"] if p[\"id\"]==\"insightBox\")' | grep -qi 'Add an insight'"
fi

printf '\n\033[1mE · the crop budget reaches the screens the look WALKED (S224 fix round 2)\033[0m\n'
# MEASURED ON THE S222 CAPSTONE: the look came back holding exactly sixteen
# `shot-s0-part-*.png` — every one of them from the LANDING screen — and not a
# single part crop from any of the four screens it then walked to. The counter
# was one running total and `snapScreen("s0")` runs before `walkTheJourney()`,
# so the first screen spent the whole budget before the walk began. The comment
# in the driver claimed the opposite and nothing implemented it.
#
# REAL HEADLESS CHROME, over a hash-routed app of four screens walked by its own
# controls — a node DOM harness cannot prove where a crop was taken.
WALK="$TMPROOT/walkfix"; mkdir -p "$WALK"
cat >"$WALK/app.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>four screens</title>
<style>body{font:14px system-ui;margin:0;padding:16px}
.screen{display:none}.screen.on{display:block}
button{height:30px;padding:0 10px;border:1px solid #888;margin-right:6px}</style>
<section id="s-one" class="screen on"><h2>Screen one</h2>
  <button id="one-a" data-go="two">Go to two</button>
  <button id="one-b">Reset one</button><button id="one-c">Help one</button>
  <button id="one-d">Export one</button><button id="one-e">Print one</button></section>
<section id="s-two" class="screen"><h2>Screen two</h2>
  <button id="two-a" data-go="three">Go to three</button>
  <button id="two-b">Reset two</button><button id="two-c">Help two</button>
  <button id="two-d">Export two</button><button id="two-e">Print two</button></section>
<section id="s-three" class="screen"><h2>Screen three</h2>
  <button id="three-a" data-go="four">Go to four</button>
  <button id="three-b">Reset three</button><button id="three-c">Help three</button>
  <button id="three-d">Export three</button><button id="three-e">Print three</button></section>
<section id="s-four" class="screen"><h2>Screen four</h2>
  <button id="four-a">Done</button>
  <button id="four-b">Reset four</button><button id="four-c">Help four</button>
  <button id="four-d">Export four</button><button id="four-e">Print four</button></section>
<script>
 function show(k){for(const s of document.querySelectorAll('.screen'))s.classList.remove('on');
   document.getElementById('s-'+k).classList.add('on');location.hash='#'+k;}
 for(const b of document.querySelectorAll('button[data-go]'))
   b.addEventListener('click',()=>show(b.dataset.go));
</script>
HTML
cat >"$WALK/journey.json" <<'JSON'
{"entry": null,
 "steps": [
  {"key":"j1","name":"click \"Go to two\"","do":"click","match":["Go to two"],"expect":"screen two"},
  {"key":"j2","name":"click \"Go to three\"","do":"click","match":["Go to three"],"expect":"screen three"},
  {"key":"j3","name":"click \"Go to four\"","do":"click","match":["Go to four"],"expect":"screen four"}
 ]}
JSON
WOUT="$TMPROOT/walkout"; mkdir -p "$WOUT"
"$NODE" "$DRIVER" --url "file://$WALK/app.html" --out "$WOUT" \
  --parts-out "$WOUT/parts.json" --journey "$WALK/journey.json" \
  --walk-out "$WOUT/walk.json" --prefix shot >"$WOUT/drive.json" 2>"$WOUT/drive.err"
wrc=$?
if [ "$wrc" -eq 77 ] || [ ! -s "$WOUT/parts.json" ]; then
  printf '  \033[33mSKIP\033[0m no usable Chrome here (%s)\n' "$(head -1 "$WOUT/drive.err" 2>/dev/null)"
else
  wq() { "$PY" -c "import json,sys;d=json.load(open('$WOUT/parts.json'));print(eval(sys.argv[1],{'d':d}))" "$1"; }
  # How many DISTINCT screen tags the crops on disk carry. `shot-<tag>-part-NN`
  # — counted from the files themselves, not from anything the driver says
  # about itself.
  crop_tags() { ls "$WOUT"/shot-*-part-*.png 2>/dev/null |
                  sed 's|.*/shot-||; s|-part-.*||' | sort -u; }
  check "E · the walk really did reach four screens" \
    "[ \"\$(wq 'len(d[\"screens\"])')\" -ge 4 ]"
  check "E · part crops come back from MORE THAN ONE screen" \
    "[ \"\$(crop_tags | grep -c .)\" -ge 2 ]"
  check "E · …from every screen the look stood on, not just the landing page" \
    "[ \"\$(crop_tags | grep -c .)\" -ge 4 ]"
  # THE LAST SCREEN IS THE ONE THE OLD COUNTER ALWAYS STARVED: measured on this
  # very fixture, the cap ran out on the third screen and the fourth — the one
  # the walk worked hardest to reach — came back with nothing at all.
  check "E · the LAST screen the walk reached is photographed too" \
    "[ \"\$(ls '$WOUT'/shot-w3-part-*.png 2>/dev/null | grep -c .)\" -ge 1 ]"
  # THE CONTROL — a budget that no longer bounds anything is a different bug.
  check "E CONTROL · the total is still bounded by the cap" \
    "[ \"\$(ls '$WOUT'/shot-*-part-*.png 2>/dev/null | grep -c .)\" -le \"\$(wq 'd[\"cropCap\"]')\" ]"
  check "E CONTROL · …and the record's own count agrees with the files on disk" \
    "[ \"\$(wq 'd[\"cropped\"]')\" = \"\$(ls '$WOUT'/shot-*-part-*.png 2>/dev/null | grep -c . | tr -d ' ')\" ]"
  check "E CONTROL · the record says how many screens were photographed" \
    "[ \"\$(wq 'd[\"croppedScreens\"]')\" -ge 4 ]"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
