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
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
