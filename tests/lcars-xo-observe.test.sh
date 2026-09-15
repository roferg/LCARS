#!/usr/bin/env bash
#
# Tests for THE OBSERVATIONS PASS (Session 210) — the two gaps the captain
# found reading S203's own report: "buttons with no spacing between them are
# smooshed together" was literally unmeasurable, and Number One had never once
# been run without a drawing.
#
# Skill source under test:
#   skills/lcars-xo/xo-drive.js     — every VISIBLE element gets geometry now,
#                                      not just the drawing's named places.
#   skills/lcars-xo/xo-observe.py   — the OBSERVATIONS pass: crowding, overlap,
#                                      a misaligned row, clipped text — computed
#                                      by the SKILL from those boxes, never
#                                      asked of the model.
#   skills/lcars-xo/xo-score.py     — renders observations into their own
#                                      report section (never the score), and
#                                      forces every `drawnAt` criterion to
#                                      "not-checkable" when the mission has no
#                                      drawing at all, whatever the worker said.
#   skills/lcars-xo/xo-criteria.py  — `hasDrawing`, the fact xo-score.py's
#                                      no-drawing guard reads.
#
# THIS SUITE DELIBERATELY DOES NOT FAKE THE LAYER S210 CHANGES: the element
# capture is proven against REAL HEADLESS CHROME on tiny local fixture pages
# (the standing rule — "never fake the layer you are changing"), and the
# observation ARITHMETIC and the score guard are proven directly against
# crafted JSON, exactly as `xo-score.py`'s own ledger logic is already tested
# in tests/lcars-xo.test.sh (B11i) — a deterministic function does not need a
# live worker to prove its math, only real inputs of the shape it will get.
#
# THE CONTROL IS THE POINT (captain's own words, 2026-09-13): "a crowding
# check that fires on a well-spaced page would train the captain to ignore the
# whole feature." Every detector below has a positive case AND a clean-page
# control, and the clean control is asserted to produce EXACTLY ZERO
# observations — not "fewer", zero.
#
# ZERO SPEND. No worker CLI runs anywhere in this file — it never reaches
# xo.sh's worker rounds at all.
#
# Usage: bash tests/lcars-xo-observe.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
CAGE="$REPO_ROOT/tests/drives/s197/cage.py"
OBSERVE="${LCARS_XO_OBSERVE_PY:-$REPO_ROOT/skills/lcars-xo/xo-observe.py}"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
CRITERIA="${LCARS_XO_CRITERIA_PY:-$REPO_ROOT/skills/lcars-xo/xo-criteria.py}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
HAVE_CHROME=0
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$c" ] && HAVE_CHROME=1
done
[ -n "${LCARS_BROWSER_CHROME:-}" ] && [ -x "${LCARS_BROWSER_CHROME:-}" ] && HAVE_CHROME=1

# drive <fixture.html> <outdir> [extra argv...] — real headless Chrome, bounded
# by cage.py (own process group, SIGKILLed whole on a timeout — CLAUDE.md's
# rule for anything unattended; there is no portable `timeout(1)` on macOS).
drive() {
  local url="$1" out="$2"; shift 2
  "$PY" "$CAGE" 30 node "$DRIVER" --url "$url" --out "$out" "$@" >"$out.stdout" 2>"$out.stderr"
}

if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ]; then

FXDIR="$TMPROOT/fixtures"; mkdir -p "$FXDIR"

# ============================================================================
# PART 1 — EVERY VISIBLE ELEMENT GETS GEOMETRY (behaviour: item 1 of the S210
# brief), captured by the REAL driver against a REAL browser.
# ============================================================================
cat >"$FXDIR/crowded.html" <<'HTML'
<!doctype html><html><body style="margin:0">
<div style="position:absolute; left:20px; top:20px;">
  <button id="add-button" style="width:80px;height:30px;">ADD</button><button id="cancel-button" style="width:80px;height:30px;">CANCEL</button>
</div>
</body></html>
HTML
cat >"$FXDIR/clean.html" <<'HTML'
<!doctype html><html><body style="margin:0">
<div style="position:absolute; left:20px; top:20px;">
  <button id="add-button" style="width:80px;height:30px;">ADD</button>
  <div style="display:inline-block;width:60px;"></div>
  <button id="cancel-button" style="width:80px;height:30px;">CANCEL</button>
</div>
</body></html>
HTML
cat >"$FXDIR/overlap.html" <<'HTML'
<!doctype html><html><body style="margin:0">
<button id="save-btn" style="position:absolute;left:20px;top:20px;width:100px;height:40px;">SAVE</button>
<button id="cancel-btn" style="position:absolute;left:80px;top:30px;width:100px;height:40px;">CANCEL</button>
</body></html>
HTML
cat >"$FXDIR/misaligned.html" <<'HTML'
<!doctype html><html><body style="margin:0">
<div class="row" style="position:absolute;left:20px;top:10px;width:200px;height:20px;">Row one</div>
<div class="row" style="position:absolute;left:20px;top:40px;width:200px;height:20px;">Row two</div>
<div class="row" style="position:absolute;left:60px;top:70px;width:200px;height:20px;">Row three</div>
</body></html>
HTML
cat >"$FXDIR/clipped.html" <<'HTML'
<!doctype html><html><body style="margin:0">
<div id="task-title" style="position:absolute;left:10px;top:10px;width:50px;height:18px;overflow:hidden;white-space:nowrap;">This is a much longer title than the box</div>
</body></html>
HTML
cat >"$FXDIR/clean2.html" <<'HTML'
<!doctype html><html><body style="margin:0">
<button id="ok-btn" style="position:absolute;left:20px;top:20px;width:100px;height:40px;">OK</button>
<div class="row" style="position:absolute;left:20px;top:80px;width:200px;height:20px;">Row one</div>
<div class="row" style="position:absolute;left:20px;top:110px;width:200px;height:20px;">Row two</div>
<div id="wide-title" style="position:absolute;left:10px;top:150px;width:400px;height:18px;">Short title</div>
</body></html>
HTML

drive "file://$FXDIR/crowded.html" "$TMPROOT/out-crowded"
check "the driver captured elements for BOTH buttons, not just a named place" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
els=d[\"page\"][\"elements\"]
ids=set(e.get(\"id\") for e in els)
sys.exit(0 if {\"add-button\",\"cancel-button\"} <= ids else 1)' '$TMPROOT/out-crowded/readout.json'"
check "…with a box AND a computed colour for each" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
els={e[\"id\"]: e for e in d[\"page\"][\"elements\"] if e.get(\"id\")}
e=els[\"add-button\"]
ok = isinstance(e.get(\"box\"), dict) and e[\"box\"][\"w\"] > 0 and isinstance(e.get(\"color\"), str) and e[\"color\"]
sys.exit(0 if ok else 1)' '$TMPROOT/out-crowded/readout.json'"

# --- no place-names AT ALL: the driver must never attempt a per-place clip ---
drive "file://$FXDIR/crowded.html" "$TMPROOT/out-noplaces"
check "with NO place names, only the full-page shot is taken — no clip is attempted" \
  "[ \"\$(ls -1 '$TMPROOT/out-noplaces'/*.png 2>/dev/null | grep -c .)\" = '1' ]"
check "…and elements are STILL captured (geometry does not depend on a drawing)" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if len(d[\"page\"][\"elements\"]) >= 2 else 1)' '$TMPROOT/out-noplaces/readout.json'"

# ============================================================================
# PART 2 — bounded output: a dense page hits the element cap and SAYS what it
# dropped (behaviour 5).
# ============================================================================
$PY - "$FXDIR/dense.html" <<'PYGEN'
import sys
rows = []
for i in range(50):
    rows.append('<div style="position:relative;">' +
                ''.join('<button style="width:5px;height:5px;">%d</button>' % j for j in range(10)) +
                '</div>')
open(sys.argv[1], "w").write('<!doctype html><html><body style="margin:0">' + ''.join(rows) + '</body></html>')
PYGEN
drive "file://$FXDIR/dense.html" "$TMPROOT/out-dense" --element-cap 100
check "a dense page's element list is CAPPED (100 elements, not 474)" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if len(d[\"page\"][\"elements\"]) == 100 else 1)' '$TMPROOT/out-dense/readout.json'"
check "…and the readout SAYS what the cap is and how many were dropped" \
  "grep -q 'cap 100' '$TMPROOT/out-dense/readout.json' && grep -q '374 were dropped' '$TMPROOT/out-dense/readout.json'"
check "…the same note reaches the driver's own top-level notes (what the captain reads)" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if any(\"dropped\" in n for n in d[\"notes\"]) else 1)' '$TMPROOT/out-dense/readout.json'"

else
  printf '  (node or Chrome not available — PART 1/2 (real-browser element capture) skipped)\n'
fi

# ============================================================================
# PART 3 — THE FOUR DETECTORS, each with its positive case AND its clean-page
# CONTROL (behaviours 1, 2, 3). Fed crafted `readout.json`-shaped input
# directly — the same code path a real capture feeds it, proven for real in
# PART 1 above; this part proves the ARITHMETIC.
# ============================================================================
obsdir="$TMPROOT/obs"; mkdir -p "$obsdir"

mk_readout() { # <file> <elements-json-array>
  printf '{"page": {"elements": %s}}\n' "$2" >"$1"
}

observe() { # <in.json> <out.json> [extra argv]
  local in="$1" out="$2"; shift 2
  "$PY" "$OBSERVE" "$in" "$out" "$@" >/dev/null 2>&1
}

count_kind() { # <observations.json> <kind>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for o in d["observations"] if o.get("kind") == sys.argv[2]))' "$1" "$2"
}

BTN() { # <id> <text> <x> <y> <w> <h>
  printf '{"id":"%s","tag":"button","text":"%s","interactive":true,"box":{"x":%s,"y":%s,"w":%s,"h":%s},"overflowX":0,"overflowY":0}' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

# --- Behaviour 1: two buttons at 0 px -> ONE observation naming both + the number
mk_readout "$obsdir/crowd-in.json" "[$(BTN add-button ADD 20 20 80 30),$(BTN cancel-button CANCEL 100 20 80 30)]"
observe "$obsdir/crowd-in.json" "$obsdir/crowd-out.json"
check "B1 positive — 0px apart buttons: exactly one crowding observation" \
  "[ \"\$(count_kind '$obsdir/crowd-out.json' crowding)\" = '1' ]"
check "B1 positive — house style: names both elements and the number, no harness words" \
  "grep -q 'the ADD and CANCEL buttons are touching .* 0 px between them' '$obsdir/crowd-out.json' && ! grep -Eq 'bbox|#add-button|#cancel-button' '$obsdir/crowd-out.json'"

# --- Behaviour 2: comfortable gap -> NO observation. THE CONTROL.
mk_readout "$obsdir/gap-in.json" "[$(BTN add-button ADD 20 20 80 30),$(BTN cancel-button CANCEL 160 20 80 30)]"
observe "$obsdir/gap-in.json" "$obsdir/gap-out.json"
check "B2 CONTROL — a comfortable 60px gap produces ZERO observations" \
  "[ \"\$(count_kind '$obsdir/gap-out.json' crowding)\" = '0' ]"

# --- Behaviour 3a: overlap -> one observation
mk_readout "$obsdir/overlap-in.json" "[$(BTN save-btn SAVE 20 20 100 40),$(BTN cancel-btn CANCEL 80 30 100 40)]"
observe "$obsdir/overlap-in.json" "$obsdir/overlap-out.json"
check "B3a positive — overlapping buttons: exactly one overlap observation" \
  "[ \"\$(count_kind '$obsdir/overlap-out.json' overlap)\" = '1' ]"
check "B3a — house style: names both and the shared-space number" \
  "grep -q 'the SAVE and CANCEL buttons overlap' '$obsdir/overlap-out.json'"

# --- Behaviour 3b: a misaligned row -> one observation
mk_readout "$obsdir/row-in.json" '[
  {"id":null,"tag":"div","className":"row","text":"Row one","box":{"x":20,"y":10,"w":200,"h":20}},
  {"id":null,"tag":"div","className":"row","text":"Row two","box":{"x":20,"y":40,"w":200,"h":20}},
  {"id":null,"tag":"div","className":"row","text":"Row three","box":{"x":60,"y":70,"w":200,"h":20}}
]'
observe "$obsdir/row-in.json" "$obsdir/row-out.json"
check "B3b positive — a row shifted 40px right: exactly one misaligned observation" \
  "[ \"\$(count_kind '$obsdir/row-out.json' misaligned)\" = '1' ]"
check "B3b — names the row and the px it is off by" \
  "grep -q 'Row three' '$obsdir/row-out.json' && grep -q '40 px' '$obsdir/row-out.json'"

# --- Behaviour 3c: clipped text -> one observation
mk_readout "$obsdir/clip-in.json" '[
  {"id":"task-title","tag":"div","text":"This is a much longer title than the box","box":{"x":10,"y":10,"w":50,"h":18},"overflowX":201,"overflowY":0}
]'
observe "$obsdir/clip-in.json" "$obsdir/clip-out.json"
check "B3c positive — text overflowing its box: exactly one clipped observation" \
  "[ \"\$(count_kind '$obsdir/clip-out.json' clipped)\" = '1' ]"
check "B3c — names the element and how many px it needs" \
  "grep -q '201 px more room' '$obsdir/clip-out.json'"

# --- Behaviour 3, CONTROL: a page with none of the four faults -> NOTHING
mk_readout "$obsdir/clean-in.json" '[
  {"id":"ok-btn","tag":"button","text":"OK","interactive":true,"box":{"x":20,"y":20,"w":100,"h":40},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"div","className":"row","text":"Row one","box":{"x":20,"y":80,"w":200,"h":20}},
  {"id":null,"tag":"div","className":"row","text":"Row two","box":{"x":20,"y":110,"w":200,"h":20}},
  {"id":"wide-title","tag":"div","text":"Short title","box":{"x":10,"y":150,"w":400,"h":18},"overflowX":0,"overflowY":0}
]'
observe "$obsdir/clean-in.json" "$obsdir/clean-out.json"
check "B3 CONTROL — a clean page (no crowding, no overlap, aligned rows, no clipping) produces ZERO observations" \
  "[ \"\$($PY -c 'import json;d=json.load(open(\"'$obsdir'/clean-out.json\"));print(len(d[\"observations\"]))')\" = '0' ]"

# --- Behaviour 7: the thresholds are IN the observations.json (what report.md
#     quotes from) — printed, not buried.
check "the thresholds used are recorded, not just applied silently" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
t=d[\"thresholds\"]
sys.exit(0 if t.get(\"gapPx\") and t.get(\"misalignPx\") and t.get(\"overflowPx\") else 1)' '$obsdir/clean-out.json'"

# ============================================================================
# PART 4 — xo-score.py: observations NEVER move the score (behaviour 4), the
# NO-DRAWING guard (behaviour 6), and the thresholds land in the CAPTAIN'S
# COPY, report.md (behaviour 7).
# ============================================================================
scdir="$TMPROOT/score"; mkdir -p "$scdir/a" "$scdir/b"

cat >"$scdir/criteria-drawn.json" <<'CJ'
{"hasDrawing": true, "placeNames": ["#task-list"],
 "criteria": [{"id": "prd-1", "text": "the list opens with tasks", "primary": true, "source": "prd"}]}
CJ
cat >"$scdir/worker-verdict.json" <<'WV'
{"score": "high", "summary": "Everything checks out.",
 "criteria": [{"id": "prd-1", "status": "met", "shot": "shot-01", "note": "the list is there"}],
 "gaps": []}
WV

"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$scdir/a/verdict.json" \
  >"$scdir/a/stdout.txt" 2>/dev/null
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$scdir/b/verdict.json" \
  "$obsdir/crowd-out.json" >"$scdir/b/stdout.txt" 2>/dev/null

check "B4 — the score line is IDENTICAL with and without observations present" \
  "diff <(grep '^SCORE' '$scdir/a/stdout.txt') <(grep '^SCORE' '$scdir/b/stdout.txt') >/dev/null"
check "B4 — the derivation sentence is IDENTICAL too (not just the label)" \
  "diff <(grep '^WHY' '$scdir/a/stdout.txt') <(grep '^WHY' '$scdir/b/stdout.txt') >/dev/null"
check "B4 — the ledger itself is byte-identical between the two verdicts" \
  "$PY -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a[\"criteria\"] == b[\"criteria\"] and a[\"score\"] == b[\"score\"] else 1)' '$scdir/a/verdict.json' '$scdir/b/verdict.json'"
check "B4 — without an observations argument, no Observations section is written at all" \
  "! grep -q 'Things I noticed' '$scdir/a/report.md'"
check "B4 — WITH one, the section appears, in its own place, never inside the ledger table" \
  "grep -q 'Things I noticed' '$scdir/b/report.md'"
check "B7 — the thresholds are PRINTED in the captain's own report.md, not just in the JSON" \
  "grep -q '8 px apart' '$scdir/b/report.md' && grep -q 'wrong for your eye' '$scdir/b/report.md'"

# --- Behaviour 6: NO DRAWING AT ALL — a drawnAt criterion must NEVER come back
#     silently MET, however confident the worker's own verdict was.
cat >"$scdir/criteria-nodrawing.json" <<'CJ'
{"hasDrawing": false, "placeNames": [],
 "criteria": [
   {"id": "prd-1", "text": "the list opens with a status line", "primary": true, "source": "prd"},
   {"id": "t-1-ac1", "text": "the status line sits under the add row", "source": "plan", "ticket": "t-1", "drawnAt": "#status-line"},
   {"id": "t-1-ac2", "text": "adding a task clears the input", "source": "plan", "ticket": "t-1", "notDrawn": "visible but not in the mockup"}
 ]}
CJ
cat >"$scdir/worker-verdict-confident.json" <<'WV'
{"score": "high", "summary": "Looks great, everything matches the drawing perfectly.",
 "criteria": [
   {"id": "prd-1", "status": "met", "shot": "shot-01", "note": "the status line is there"},
   {"id": "t-1-ac1", "status": "met", "shot": "shot-01", "note": "I compared it to the drawing and it matches exactly"},
   {"id": "t-1-ac2", "status": "met", "shot": "shot-01", "note": "the input clears"}
 ], "gaps": []}
WV
"$PY" "$SCOREPY" "$scdir/worker-verdict-confident.json" "$scdir/criteria-nodrawing.json" \
  "$scdir/nodrawing-verdict.json" >"$scdir/nodrawing-stdout.txt" 2>/dev/null

check "B6 — a drawnAt criterion is forced to untested when there is no drawing, EVEN THOUGH the worker rated it met" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"t-1-ac1\"][0]
sys.exit(0 if e[\"status\"] == \"untested\" else 1)' '$scdir/nodrawing-verdict.json'"
check "B6 — the note is the ONE honest sentence, verbatim" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"t-1-ac1\"][0]
sys.exit(0 if e[\"note\"] == \"I could not check this against a drawing, because there isn'\"'\"'t one\" else 1)' '$scdir/nodrawing-verdict.json'"
check "B6 — a notDrawn criterion is UNAFFECTED — no drawing narrows what can be drawing-checked, not everything" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"t-1-ac2\"][0]
sys.exit(0 if e[\"status\"] == \"met\" else 1)' '$scdir/nodrawing-verdict.json'"
check "B6 — the PRD's own criterion (no drawnAt at all) is also unaffected" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"prd-1\"][0]
sys.exit(0 if e[\"status\"] == \"met\" else 1)' '$scdir/nodrawing-verdict.json'"
check "B6 — the score reflects the untested criterion (MEDIUM, not the worker's false HIGH)" \
  "grep -q '^SCORE.medium' '$scdir/nodrawing-stdout.txt'"

# --- xo-criteria.py: `hasDrawing` itself, the fact the guard above reads -----
crdir="$TMPROOT/criteria"; mkdir -p "$crdir/with-drawing/attachments" "$crdir/without-drawing"
printf '# T\n\n## Acceptance criteria\n- a thing\n' >"$crdir/with-drawing/prd.md"
printf '<div id="x">X</div>' >"$crdir/with-drawing/attachments/mock.html"
printf '# T\n\n## Acceptance criteria\n- a thing\n' >"$crdir/without-drawing/prd.md"
"$PY" "$CRITERIA" "$crdir/with-drawing" "$crdir/with-drawing/out.json" >/dev/null
"$PY" "$CRITERIA" "$crdir/without-drawing" "$crdir/without-drawing/out.json" >/dev/null
check "xo-criteria.py: hasDrawing is TRUE when attachments/ holds a mockup" \
  "grep -q '\"hasDrawing\": true' '$crdir/with-drawing/out.json'"
check "xo-criteria.py: hasDrawing is FALSE with no attachments/ at all — the no-drawing path runs, not errors" \
  "grep -q '\"hasDrawing\": false' '$crdir/without-drawing/out.json'"
check "…and the criteria list is STILL built from the PRD alone (the look still runs)" \
  "grep -q '\"text\": \"a thing\"' '$crdir/without-drawing/out.json'"

# ==========================================================================
echo
printf 'lcars xo-observe: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
