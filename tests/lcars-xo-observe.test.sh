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

# ============================================================================
# PART 5 — SESSION 212: THE LOOK STOPS CRYING WOLF.
#
# S210's pass worked and, driven live, it fired on CORRECT UI: a chip's own
# embedded remove button read as "touching", a notification badge on a button
# corner read as "overlap", a box that is MEANT to scroll read as "clipped",
# and a tidy five-row list produced FIVE separate notes.
#
# EVERY CASE BELOW IS A PAIR — the false alarm that must go QUIET and the
# control that must STILL FIRE. A guard quietened into uselessness is worse
# than a noisy one, so a half-tested pair is not a tested pair.
#
# THESE ARE PERMANENT REGRESSION TESTS. If a future change makes the chip, the
# badge, the scrollable box or the tidy list fire again, this suite goes RED.
#
# AND THEY ARE DRIVEN THROUGH REAL HEADLESS CHROME. Ancestry, computed
# overflow and occlusion DO NOT EXIST in a crafted JSON fixture unless the
# fixture author put them there — a green synthetic test would prove only that
# the author agreed with themselves. The browser plants the page; the real
# driver records; xo-observe.py reads. (The COPY of the collapsed and capped
# notes is additionally pinned against crafted input in PART 6, where the
# counts can be made exact.)
# ============================================================================
if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ]; then
echo
echo "PART 5 — real headless Chrome: the four false alarms, and the controls"

S212FX="$TMPROOT/s212-fixtures"; mkdir -p "$S212FX"

# drive_observe <fixture.html> <tag> — real Chrome, then the real pass.
drive_observe() {
  local fx="$1" tag="$2" out="$TMPROOT/s212-$2"
  drive "file://$S212FX/$fx" "$out"
  "$PY" "$OBSERVE" "$out/readout.json" "$out/observations.json" >"$out/observe.stdout" 2>&1
}

count_all() { # <observations.json>
  "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(len(d["observations"]))' "$1"
}

# --------------------------------------------------------------------------
# 1. A CHIP AND ITS OWN EMBEDDED REMOVE BUTTON — and, on the same page, a
#    genuinely crowded pair of SIBLINGS at 0 px that must still be caught.
# --------------------------------------------------------------------------
cat >"$S212FX/chip.html" <<'HTML'
<!doctype html><html><body style="margin:0;height:900px">
<span id="tag-chip" class="chip" tabindex="0"
      style="position:absolute;left:20px;top:20px;display:inline-block;width:120px;height:28px;background:#ddd;">
  design
  <span id="chip-remove" role="button" class="chip-x"
        style="position:absolute;right:-4px;top:0;width:28px;height:28px;background:#bbb;">x</span>
</span>
<div style="position:absolute;left:20px;top:300px;">
  <button id="add-button" style="width:80px;height:30px;">ADD</button><button id="cancel-button" style="width:80px;height:30px;">CANCEL</button>
</div>
</body></html>
HTML
drive_observe chip.html chip
check "S212-1 FALSE ALARM — a chip and its OWN remove button produce nothing about the chip" \
  "! grep -qi 'chip\|design' '$TMPROOT/s212-chip/observations.json'"
check "S212-1 CONTROL — the genuinely crowded SIBLING pair on the same page STILL fires, exactly once" \
  "[ \"\$(count_all '$TMPROOT/s212-chip/observations.json')\" = '1' ] && grep -q 'the ADD and CANCEL buttons are touching' '$TMPROOT/s212-chip/observations.json'"

# --------------------------------------------------------------------------
# 2. A NOTIFICATION BADGE INSIDE A BUTTON — and two genuinely overlapping
#    SIBLING buttons that must still be caught.
# --------------------------------------------------------------------------
cat >"$S212FX/badge.html" <<'HTML'
<!doctype html><html><body style="margin:0;height:900px">
<button id="inbox-button" style="position:absolute;left:20px;top:20px;width:120px;height:40px;">
  INBOX
  <span id="unread-badge" role="button"
        style="position:absolute;right:-8px;top:-8px;width:20px;height:20px;background:#c33;">3</span>
</button>
<button id="save-btn" style="position:absolute;left:20px;top:300px;width:100px;height:40px;">SAVE</button>
<button id="cancel-btn" style="position:absolute;left:80px;top:310px;width:100px;height:40px;">CANCEL</button>
</body></html>
HTML
drive_observe badge.html badge
check "S212-2 FALSE ALARM — a badge INSIDE its button produces nothing about the badge" \
  "! grep -qi 'badge\|INBOX' '$TMPROOT/s212-badge/observations.json'"
check "S212-2 CONTROL — the genuinely overlapping SIBLING buttons STILL fire, exactly once" \
  "[ \"\$(count_all '$TMPROOT/s212-badge/observations.json')\" = '1' ] && grep -q 'the SAVE and CANCEL buttons overlap' '$TMPROOT/s212-badge/observations.json'"

# --------------------------------------------------------------------------
# 3. A BOX THAT IS MEANT TO SCROLL vs A BOX THAT TRUNCATES. Same excess
#    content, same pixel spill; only the computed overflow tells them apart,
#    and only because the browser wrote it down.
# --------------------------------------------------------------------------
cat >"$S212FX/scrollbox.html" <<'HTML'
<!doctype html><html><body style="margin:0;height:900px">
<div id="scrolling-notes" style="position:absolute;left:20px;top:20px;width:200px;height:60px;overflow-y:auto;">These are notes that run on and on and on and are meant to be scrolled through, which is exactly why the box was given a scrollbar in the first place, and they keep going for a while yet so that there is plenty more of them than the box can show at once.</div>
<div id="truncated-title" style="position:absolute;left:20px;top:300px;width:50px;height:18px;overflow:hidden;white-space:nowrap;">This is a much longer title than the box</div>
</body></html>
HTML
drive_observe scrollbox.html scrollbox
check "S212-3 FALSE ALARM — an overflow:auto box with more content than fits is NOT clipped" \
  "! grep -q 'These are notes' '$TMPROOT/s212-scrollbox/observations.json'"
check "S212-3 CONTROL — an overflow:hidden box with the same excess STILL reports clipped, once" \
  "[ \"\$(count_kind '$TMPROOT/s212-scrollbox/observations.json' clipped)\" = '1' ] && grep -q 'much longer title' '$TMPROOT/s212-scrollbox/observations.json'"

# --------------------------------------------------------------------------
# 4. A ROW SCROLLED OUT OF ITS OWN CONTAINER. It has a box, it is inside the
#    viewport, and it CANNOT BE SEEN. Its twin, scrolled into view, is
#    measured exactly as before.
# --------------------------------------------------------------------------
cat >"$S212FX/scrolled-away.html" <<'HTML'
<!doctype html><html><body style="margin:0;height:1200px">
<div id="list-box" style="position:absolute;left:20px;top:20px;width:300px;height:120px;overflow-y:auto;">
  <div class="row" style="height:40px;margin-left:0px;">Row one</div>
  <div class="row" style="height:40px;margin-left:0px;">Row two</div>
  <div class="row" style="height:40px;margin-left:0px;">Row three</div>
  <div class="row" id="stray-row" style="height:40px;margin-left:80px;">Row four</div>
</div>
<script>document.getElementById("list-box").scrollTop = SCROLLTOP;</script>
</body></html>
HTML
sed 's/SCROLLTOP/0/' "$S212FX/scrolled-away.html" >"$S212FX/scrolled-out.html"
sed 's/SCROLLTOP/40/' "$S212FX/scrolled-away.html" >"$S212FX/scrolled-in.html"
drive_observe scrolled-out.html scrolled-out
drive_observe scrolled-in.html scrolled-in
check "S212-4 the driver RECORDS whether an element can be seen (it does not infer it later)" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
els={e.get(\"id\"): e for e in d[\"page\"][\"elements\"]}
sys.exit(0 if els.get(\"stray-row\", {}).get(\"seen\") is False else 1)' '$TMPROOT/s212-scrolled-out/readout.json'"
check "S212-4 FALSE ALARM — a row scrolled OUT of its container is not measured at all" \
  "[ \"\$(count_all '$TMPROOT/s212-scrolled-out/observations.json')\" = '0' ]"
check "S212-4 CONTROL — the SAME row scrolled INTO view is measured normally, once" \
  "[ \"\$(count_kind '$TMPROOT/s212-scrolled-in/observations.json' misaligned)\" = '1' ] && grep -q 'Row four' '$TMPROOT/s212-scrolled-in/observations.json'"

# --------------------------------------------------------------------------
# 5. A BUTTON BEHIND AN OPAQUE MODAL BACKDROP — paint order, the same root
#    cause as the scroll case and cured in the same place.
# --------------------------------------------------------------------------
cat >"$S212FX/modal.html" <<'HTML'
<!doctype html><html><body style="margin:0;height:900px">
<div style="position:absolute;left:20px;top:200px;">
  <button id="add-button" style="width:80px;height:30px;">ADD</button><button id="cancel-button" style="width:80px;height:30px;">CANCEL</button>
</div>
<div id="backdrop" style="position:absolute;left:0;top:0;width:2000px;height:2000px;background:#000;z-index:9;DISPLAY"></div>
</body></html>
HTML
sed 's/DISPLAY//' "$S212FX/modal.html" >"$S212FX/modal-up.html"
sed 's/DISPLAY/display:none;/' "$S212FX/modal.html" >"$S212FX/modal-down.html"
drive_observe modal-up.html modal-up
drive_observe modal-down.html modal-down
check "S212-5 FALSE ALARM — buttons behind an opaque modal backdrop are not measured" \
  "[ \"\$(count_all '$TMPROOT/s212-modal-up/observations.json')\" = '0' ]"
check "S212-5 CONTROL — with the modal dismissed, the same buttons are measured, once" \
  "[ \"\$(count_all '$TMPROOT/s212-modal-down/observations.json')\" = '1' ] && grep -q 'the ADD and CANCEL buttons are touching' '$TMPROOT/s212-modal-down/observations.json'"

# --------------------------------------------------------------------------
# 5b. THE TWO WAYS THIS SESSION COULD HAVE GONE TOO QUIET, both driven rather
#     than argued about. A box may scroll on ONE axis and genuinely truncate on
#     the other, and a full-page decorative scrim may lie over everything
#     without hiding a thing. Neither may buy silence.
# --------------------------------------------------------------------------
cat >"$S212FX/mixed.html" <<'HTML'
<!doctype html><html><body style="margin:0;height:900px">
<div id="mixed-box" style="position:absolute;left:20px;top:20px;width:80px;height:40px;overflow-x:hidden;overflow-y:auto;white-space:nowrap;">A line that is far too wide for eighty pixels of box</div>
<div id="scrim" style="position:absolute;left:0;top:0;width:2000px;height:2000px;background:rgba(0,0,0,.4);pointer-events:none;"></div>
<div style="position:absolute;left:20px;top:400px;">
  <button id="add-button" style="width:80px;height:30px;">ADD</button><button id="cancel-button" style="width:80px;height:30px;">CANCEL</button>
</div>
</body></html>
HTML
drive_observe mixed.html mixed
check "S212-5b a box that scrolls one way and TRUNCATES the other still reports the truncation" \
  "[ \"\$(count_kind '$TMPROOT/s212-mixed/observations.json' clipped)\" = '1' ] && grep -q '237 px more room' '$TMPROOT/s212-mixed/observations.json'"
check "S212-5b a decorative full-page scrim you cannot click does NOT hide what is under it" \
  "grep -q 'the ADD and CANCEL buttons are touching' '$TMPROOT/s212-mixed/observations.json'"

# --------------------------------------------------------------------------
# 6. FIVE ROWS 6 PX APART — ONE note, naming the count, in his words.
# --------------------------------------------------------------------------
$PY - "$S212FX/tidy-list.html" <<'PYGEN'
import sys
rows = "".join(
    '<div class="row" tabindex="0" style="position:absolute;left:20px;top:%dpx;width:200px;height:30px;">Row %d</div>'
    % (20 + i * 30, i + 1) for i in range(5))
open(sys.argv[1], "w").write('<!doctype html><html><body style="margin:0;height:900px">' + rows + '</body></html>')
PYGEN
drive_observe tidy-list.html tidy
check "S212-6 five touching rows collapse to EXACTLY ONE note, not five" \
  "[ \"\$(count_all '$TMPROOT/s212-tidy/observations.json')\" = '1' ]"
check "S212-6 …and the note NAMES THE COUNT, in the captain's own words" \
  "grep -q 'five rows in this list are touching' '$TMPROOT/s212-tidy/observations.json'"
check "S212-6 …and the SENTENCE he reads carries no harness vocabulary" \
  "$PY -c 'import json,re,sys
d=json.load(open(sys.argv[1]))
words = re.compile(r\"bbox|selector|overflow|css|px apart.*px apart|element\[|threshold|querySelector|DOM|node\", re.I)
sys.exit(1 if any(words.search(o[\"message\"]) for o in d[\"observations\"]) else 0)' '$TMPROOT/s212-tidy/observations.json'"

# --------------------------------------------------------------------------
# 7. A PAGE WITH A LOT GOING ON — capped, and it SAYS how many it held back.
# --------------------------------------------------------------------------
$PY - "$S212FX/busy.html" <<'PYGEN'
import sys
parts = []
# eight unrelated crowded sibling PAIRS, each its own little group, each a
# different gap so nothing collapses them together.
for i in range(8):
    y = 20 + i * 90
    w = 60
    gap = i  # 0..7 px, all under the 8 px threshold
    parts.append('<button id="b%da" class="g%da" style="position:absolute;left:20px;top:%dpx;width:%dpx;height:30px;">A%d</button>' % (i, i, y, w, i))
    parts.append('<button id="b%db" class="g%db" style="position:absolute;left:%dpx;top:%dpx;width:%dpx;height:30px;">B%d</button>' % (i, i, 20 + w + gap, y, w, i))
open(sys.argv[1], "w").write('<!doctype html><html><body style="margin:0;height:1200px">' + "".join(parts) + '</body></html>')
PYGEN
drive_observe busy.html busy
check "S212-7 a busy page is CAPPED to the three worst, not a wall of notes" \
  "[ \"\$(count_all '$TMPROOT/s212-busy/observations.json')\" = '3' ]"
check "S212-7 …and it SAYS so, in his words, naming how many it held back" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
n=\" \".join(d[\"notes\"])
sys.exit(0 if (\"a lot going on\" in n and \"three worst\" in n and \"held back 5\" in n) else 1)' '$TMPROOT/s212-busy/observations.json'"
check "S212-7 …and the three it kept are the WORST (the tightest gaps: 0, 1 and 2 px)" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if sorted(o[\"px\"] for o in d[\"observations\"]) == [0,1,2] else 1)' '$TMPROOT/s212-busy/observations.json'"

# ==========================================================================
# S212 FIX ROUND 1 — the opposite failure. The four false alarms above went
# quiet, and so did a great deal that should not have. A fresh tester drove
# real pages through real Chrome and found the guard quietened into
# uselessness: ANYTHING laid over the page bought TOTAL SILENCE.
#
# Same discipline as PART 5: every case is a PAIR. The thing that must be
# heard again, and the control that must still be silent.
# ==========================================================================

# --------------------------------------------------------------------------
# F1. A SEE-THROUGH COVER BUYS NO SILENCE — but a solid one still does.
#     One planted pair of touching buttons, four different things laid over
#     them. Before this, all four silenced the whole page (the heading too):
#     the only escape hatch was pointer-events:none, and a bare
#     `position:fixed; inset:0` click-catcher is hit-testable, wins the hit
#     test, and so recorded every element beneath it as unseen.
# --------------------------------------------------------------------------
PAIR='<button id="save-btn" style="position:absolute;left:40px;top:100px;width:120px;height:36px;">SAVE</button><button id="cancel-btn" style="position:absolute;left:160px;top:100px;width:120px;height:36px;">CANCEL</button>'

over() { # <file> <the overlay html>
  printf '<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px"><h3>cover</h3>%s%s</body></html>\n' \
    "$PAIR" "$2" >"$S212FX/$1"
}

over cover-none.html ''
over cover-catcher.html '<div id="cover" style="position:fixed;inset:0;"></div>'
over cover-scrim2.html '<div id="cover" style="position:fixed;inset:0;background:rgba(255,255,255,0.02);"></div>'
over cover-modal35.html '<div id="cover" style="position:fixed;inset:0;background:rgba(0,0,0,0.35);"></div>'
over cover-opaque.html '<div id="cover" style="position:fixed;inset:0;background:rgba(0,0,0,1);"></div>'
over cover-veil.html '<div id="cover" style="position:fixed;inset:0;pointer-events:none;background:rgba(255,255,255,0.08);"></div>'
over cover-inherited.html '<div style="opacity:0.35;"><div id="cover" style="position:fixed;inset:0;background:rgb(0,0,0);"></div></div>'

for c in none catcher scrim2 modal35 opaque veil inherited; do
  drive_observe "cover-$c.html" "cover-$c"
done

check "S212F1 BASELINE — with nothing over them, the touching pair is reported" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-none/observations.json')\" = '1' ] && grep -q 'the SAVE and CANCEL buttons are touching' '$TMPROOT/s212-cover-none/observations.json'"
check "S212F1 an INVISIBLE click-catcher (fixed, inset:0, no background) hides NOTHING — the pair is still reported" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-catcher/observations.json')\" = '1' ] && grep -q 'the SAVE and CANCEL buttons are touching' '$TMPROOT/s212-cover-catcher/observations.json'"
check "S212F1 a 2% scrim hides nothing either" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-scrim2/observations.json')\" = '1' ]"
check "S212F1 a 35% modal backdrop DIMS the page, it does not hide it — still reported" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-modal35/observations.json')\" = '1' ]"
check "S212F1 …and not one element under any of those went unseen" \
  "$PY -c 'import json,sys
for p in sys.argv[1:]:
    if json.load(open(p))[\"unseenCount\"] != 0: sys.exit(1)' \
  '$TMPROOT/s212-cover-catcher/observations.json' '$TMPROOT/s212-cover-scrim2/observations.json' '$TMPROOT/s212-cover-modal35/observations.json'"
check "S212F1 CONTROL — a FULLY OPAQUE backdrop really does hide the page, and is still silent" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-opaque/observations.json')\" = '0' ]"
check "S212F1 CONTROL — the pointer-events:none veil still buys no silence (the S212 cure, kept)" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-veil/observations.json')\" = '1' ]"
check "S212F1 OPACITY IS INHERITED — an opaque cover inside a 35%-faded wrapper is 35% of a cover, and hides nothing" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-inherited/observations.json')\" = '1' ]"

# The DISTINCTION, recorded rather than implied: an ancestor winning the hit
# test is an element CLIPPED AWAY by its own scroll container; a solid
# non-ancestor on top is an element COVERED. Two different causes. Only one of
# them may ever be bought by something see-through, so they are written down
# apart — in the driver, where the browser is still open to be asked.
check "S212F1 the driver records WHY it cannot be seen, not just that it cannot — 'covered' under a solid backdrop" \
  "$PY -c 'import json,sys
els=json.load(open(sys.argv[1]))[\"page\"][\"elements\"]
b=[e for e in els if e.get(\"id\")==\"save-btn\"]
sys.exit(0 if b and b[0][\"seen\"] is False and b[0].get(\"hiddenBy\")==\"covered\" else 1)' '$TMPROOT/s212-cover-opaque/readout.json'"
check "S212F1 …and 'clipped' for a row its own scroll container has carried away — NOT the same fact" \
  "$PY -c 'import json,sys
els=json.load(open(sys.argv[1]))[\"page\"][\"elements\"]
gone=[e for e in els if e.get(\"seen\") is False]
sys.exit(0 if gone and all(e.get(\"hiddenBy\")==\"clipped\" for e in gone) else 1)' '$TMPROOT/s212-scrolled-out/readout.json'"

# --------------------------------------------------------------------------
# F2. THE COLLAPSED SENTENCE MUST NOT INVENT A PLACE. A three-tab bar and a
#     separate segmented control 60 px below it are five `button`s with
#     nothing in common but their tag — and they collapsed into "five buttons
#     in this row are touching". There is no such row on the page.
# --------------------------------------------------------------------------
cat >"$S212FX/tabs-and-segments.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">
<div id="tabs" style="position:absolute;left:24px;top:80px;display:flex;">
  <button style="height:34px;padding:0 16px;">Overview</button><button style="height:34px;padding:0 16px;">Activity</button><button style="height:34px;padding:0 16px;">Settings</button>
</div>
<div id="seg" style="position:absolute;left:24px;top:140px;display:inline-flex;">
  <button style="height:30px;padding:0 12px;">Day</button><button style="height:30px;padding:0 12px;">Week</button>
</div>
</body></html>
HTML
drive_observe tabs-and-segments.html tabs-seg
check "S212F2 two SEPARATE controls 60 px apart never become one row of five" \
  "! grep -q 'five buttons in this row' '$TMPROOT/s212-tabs-seg/observations.json'"
check "S212F2 …and no note claims a place that is not on the page" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(1 if any(\"five buttons\" in o[\"message\"] or \"eight buttons\" in o[\"message\"] for o in d[\"observations\"]) else 0)' '$TMPROOT/s212-tabs-seg/observations.json'"

# The count in the record and the number in the sentence are ONE fact. They
# used to be computed twice and disagree: "five rows" beside `count: 4`.
check "S212F2 the number the captain reads and the count in the JSON are the SAME number" \
  "$PY -c 'import json,re,sys
WORD={\"one\":1,\"two\":2,\"three\":3,\"four\":4,\"five\":5,\"six\":6,\"seven\":7,\"eight\":8,\"nine\":9,\"ten\":10}
d=json.load(open(sys.argv[1]))
for o in d[\"observations\"]:
    if \"count\" not in o: continue
    m=re.match(r\"^(\\w+) \", o[\"message\"])
    said=WORD.get(m.group(1)) if m else None
    if said is None: said=int(m.group(1)) if m and m.group(1).isdigit() else None
    if said is not None and said != o[\"count\"]: sys.exit(1)
sys.exit(0)' '$TMPROOT/s212-tidy/observations.json'"

# --------------------------------------------------------------------------
# F3. "THE THREE WORST" HAS TO BE EARNED. A realistic tracker: six list rows
#     whose names are cut off mid-word, one row indented 40 px out of line,
#     and three trivial toolbar pairs. The cap printed the three trivia and
#     held back the only two things a person notices in the screenshot,
#     because it ranked by a FIXED CATEGORY ORDER in which clipped text and a
#     crooked row are last in the queue by construction.
# --------------------------------------------------------------------------
$PY - "$S212FX/tracker.html" <<'PYGEN'
import sys
rows = []
for i, name in enumerate(["September kitchen backsplash", "September bathroom floor",
                          "October porch repair", "October hallway tiles",
                          "November utility room", "November garage floor"]):
    indent = "margin-left:40px;" if i == 4 else ""
    rows.append('<div class="batch" style="border:1px solid #ccc;padding:8px;'
                'margin-bottom:6px;%swidth:60px;overflow:hidden;white-space:nowrap;">'
                'B-100%d %s</div>' % (indent, i, name))
open(sys.argv[1], "w").write(
  '<!doctype html><html><body style="margin:0;font:14px system-ui">'
  '<div style="padding:20px;">'
  '<div id="tb1"><button style="height:34px;padding:0 14px;">ADD BATCH</button>'
  '<button style="height:34px;padding:0 14px;">EXPORT</button></div>'
  '<div id="list" style="width:420px;margin-top:18px;">' + "".join(rows) + '</div>'
  '<div id="tb2" style="margin-top:20px;"><a href="#" style="display:inline-block;padding:6px 10px;">Help</a>'
  '<a href="#" style="display:inline-block;padding:6px 10px;">About</a></div>'
  '<input style="position:absolute;left:520px;top:80px;width:120px;height:26px;">'
  '<input style="position:absolute;left:638px;top:80px;width:120px;height:26px;">'
  '<select style="position:absolute;left:520px;top:130px;width:110px;"><option>All</option></select>'
  '<select style="position:absolute;left:630px;top:130px;width:110px;"><option>Mine</option></select>'
  '</div></body></html>')
PYGEN
drive_observe tracker.html tracker
check "S212F3 the six names cut off mid-word are PRINTED, not held back" \
  "grep -q 'have text clipped by their own boxes' '$TMPROOT/s212-tracker/observations.json'"
check "S212F3 the row 40 px out of line is PRINTED, not held back" \
  "grep -q 'does not line up' '$TMPROOT/s212-tracker/observations.json'"
check "S212F3 …and the cap still holds — three printed, and it still says how many it kept back" \
  "[ \"\$(count_all '$TMPROOT/s212-tracker/observations.json')\" = '3' ] && grep -q 'held back' '$TMPROOT/s212-tracker/observations.json'"
check "S212F3 CONTROL — foundCount still records everything it found, cap or no cap" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d[\"foundCount\"] > len(d[\"observations\"]) else 1)' '$TMPROOT/s212-tracker/observations.json'"

# --------------------------------------------------------------------------
# F4. THE ELLIPSIS IDIOM IS CORRECT UI. `overflow:hidden; text-overflow:
#     ellipsis` is how every app in the world shortens a long name in a narrow
#     column, and the "…" is the author saying so out loud. It always fired.
#     `overflow:hidden` with NO ellipsis is the control and must still fire.
# --------------------------------------------------------------------------
cat >"$S212FX/ellipsis.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">
<div id="named" style="position:absolute;left:40px;top:40px;width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">Shortened on purpose with a trailing ellipsis</div>
<div id="cut" style="position:absolute;left:40px;top:140px;width:180px;overflow:hidden;white-space:nowrap;">Chopped off mid word with nothing to say so</div>
</body></html>
HTML
drive_observe ellipsis.html ellipsis
check "S212F4 the driver records text-overflow, so the pass never has to guess" \
  "$PY -c 'import json,sys
els=json.load(open(sys.argv[1]))[\"page\"][\"elements\"]
e=[x for x in els if x.get(\"id\")==\"named\"]
sys.exit(0 if e and e[0].get(\"textOverflow\")==\"ellipsis\" else 1)' '$TMPROOT/s212-ellipsis/readout.json'"
check "S212F4 FALSE ALARM — a name deliberately shortened with an ellipsis is NOT clipped" \
  "! grep -q 'Shortened on purpose' '$TMPROOT/s212-ellipsis/observations.json'"
check "S212F4 CONTROL — the SAME overflow with NO ellipsis still reports clipped, exactly once, and names the right one" \
  "[ \"\$(count_kind '$TMPROOT/s212-ellipsis/observations.json' clipped)\" = '1' ] && grep -q 'Chopped off mid word' '$TMPROOT/s212-ellipsis/observations.json'"

# --------------------------------------------------------------------------
# F5. A COVER THAT PAINTS NOTHING MUST SILENCE NOTHING (S212 fix round 2).
#     Fix round 1 read ANY background-image and ANY backdrop-filter as solid.
#     Every one of those covers is `position:fixed; inset:0` in real UI, so
#     "it only silences what is under THAT" meant "it silences the whole
#     application". A gradient STATES its own colour stops and can be
#     measured; a no-op filter has no visual effect at all.
# --------------------------------------------------------------------------
cover_page() { # <file> <the cover's style>
  cat >"$S212FX/$1" <<HTML
<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">
<button id="save-behind" style="position:absolute;left:40px;top:100px;width:120px;height:36px;">SAVE</button>
<button id="cancel-behind" style="position:absolute;left:160px;top:100px;width:120px;height:36px;">CANCEL</button>
<div style="position:fixed;inset:0;$2"></div>
</body></html>
HTML
}
cover_page invisible-gradient.html "background-image:linear-gradient(rgba(0,0,0,0),rgba(0,0,0,0));"
cover_page blur-zero.html          "backdrop-filter:blur(0px);"
cover_page vignette.html           "background-image:radial-gradient(circle at 50% 40%, rgba(0,0,0,0) 55%, rgba(0,0,0,0.25) 100%);"
cover_page glass.html              "backdrop-filter:blur(8px);background:rgba(255,255,255,0.1);"
cover_page painted-gradient.html   "background-image:linear-gradient(rgba(0,0,0,1),rgba(0,0,0,1));"
drive_observe invisible-gradient.html cover-invisible-gradient
drive_observe blur-zero.html          cover-blur-zero
drive_observe vignette.html           cover-vignette
drive_observe glass.html              cover-glass
drive_observe painted-gradient.html   cover-painted-gradient

check "S212F5 a gradient with every stop at alpha 0 paints NOTHING and hides nothing" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-invisible-gradient/observations.json')\" = '1' ]"
check "S212F5 …and nothing under it is written off as unseen" \
  "$PY -c 'import json,sys
sys.exit(0 if json.load(open(sys.argv[1]))[\"unseenCount\"] == 0 else 1)' '$TMPROOT/s212-cover-invisible-gradient/observations.json'"
check "S212F5 backdrop-filter: blur(0px) has no visual effect, so it hides nothing" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-blur-zero/observations.json')\" = '1' ]"
check "S212F5 a decorative vignette (worst stop 0.25) is a decoration, not a lid" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-vignette/observations.json')\" = '1' ]"
check "S212F5 CONTROL — a REAL blur(8px) glass panel does hide the page, and stays silent" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-glass/observations.json')\" = '0' ]"
check "S212F5 CONTROL — a gradient whose stops are FULLY OPAQUE still hides the page" \
  "[ \"\$(count_all '$TMPROOT/s212-cover-painted-gradient/observations.json')\" = '0' ]"

# --------------------------------------------------------------------------
# F6. THE COMMONEST REPEAT THERE IS — a list where every row carries its own
#     Edit/Delete pair. Fix round 1 put the PAIR's container into the group
#     key, so twenty rows could never fold: each pair's direct parent is its
#     own row div. The captain read a cap line followed by three byte-
#     identical sentences. A group shares a place when the WHOLE GROUP's
#     lowest common ancestor is a real container — the table — not when every
#     pair happens to share a direct parent.
# --------------------------------------------------------------------------
$PY - "$S212FX/twenty-rows.html" <<'PYGEN'
import sys
rows = "".join(
    '<div class="row" style="padding:6px 0;">'
    '<span style="display:inline-block;width:200px;">Batch B-10%02d</span>'
    '<button style="height:28px;padding:0 10px;">Edit</button>'
    '<button style="height:28px;padding:0 10px;">Delete</button></div>' % i
    for i in range(20))
open(sys.argv[1], "w").write(
    '<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">'
    '<div id="list" style="position:absolute;left:24px;top:70px;">' + rows +
    '</div></body></html>')
PYGEN
drive_observe twenty-rows.html twenty-rows
check "S212F6 twenty per-row Edit/Delete pairs are ONE fact, said once" \
  "[ \"\$(count_kind '$TMPROOT/s212-twenty-rows/observations.json' crowding)\" = '1' ]"
# The count is every button the one sentence stands for — not the number of
# PAIRS, and not a handful. (It is 38, not 40: the twentieth row is below the
# fold and is correctly never measured, which is the off-screen rule working.)
# ROUND 4 MOVED THE NUMBER OUT OF THE SENTENCE. "38 buttons in this list are
# touching" is arithmetic nobody can picture; the shape — every row's own
# Edit and Delete pair — is what he would recognise. The count stays in the
# RECORD, where the ranking reads it, and is asserted there instead.
check "S212F6 …and the one note stands for every button it folded" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
o=[x for x in d[\"observations\"] if x.get(\"kind\")==\"crowding\"][0]
sys.exit(0 if o.get(\"count\") >= 30 else 1)' '$TMPROOT/s212-twenty-rows/observations.json'"
check "S212F6 …and it names the place that IS on the screen, not 'different parts of the page'" \
  "! grep -q 'different parts of the page' '$TMPROOT/s212-twenty-rows/observations.json'"

# THE INVARIANT, not just this page: two notes that would read the same word
# for word are proof they should have folded. The captain must never be handed
# the same sentence twice.
no_repeat_sentence() { # <observations.json>
  "$PY" -c 'import json,sys
msgs=[o["message"] for o in json.load(open(sys.argv[1]))["observations"]]
sys.exit(1 if len(msgs) != len(set(msgs)) else 0)' "$1"
}
check "S212F6 no two notes on this page read the same, word for word" \
  "no_repeat_sentence '$TMPROOT/s212-twenty-rows/observations.json'"

# Three touching pairs under ONE container, each button wrapped in its own
# sub-div: no two of them share a direct parent, and they are still one fact.
cat >"$S212FX/split-subdivs.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">
<div id="holder" style="position:absolute;left:24px;top:80px;">
<div style="display:inline-block"><button style="width:100px;height:32px;">L0</button></div><div style="display:inline-block"><button style="width:100px;height:32px;">R0</button></div>
<div style="height:8px"></div>
<div style="display:inline-block"><button style="width:100px;height:32px;">L1</button></div><div style="display:inline-block"><button style="width:100px;height:32px;">R1</button></div>
<div style="height:8px"></div>
<div style="display:inline-block"><button style="width:100px;height:32px;">L2</button></div><div style="display:inline-block"><button style="width:100px;height:32px;">R2</button></div>
</div>
</body></html>
HTML
drive_observe split-subdivs.html split-subdivs
check "S212F6 three pairs in one holder, each button in its own sub-div, are still ONE note" \
  "[ \"\$(count_kind '$TMPROOT/s212-split-subdivs/observations.json' crowding)\" = '1' ]"
check "S212F6 CONTROL — the tab bar and the segmented control still refuse to become one row of five" \
  "! grep -q 'five buttons in this row' '$TMPROOT/s212-tabs-seg/observations.json'"
check "S212F6 CONTROL — and still invent no place at all" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(1 if any(\"five buttons\" in o[\"message\"] for o in d[\"observations\"]) else 0)' '$TMPROOT/s212-tabs-seg/observations.json'"

# --------------------------------------------------------------------------
# F7. AN ELLIPSIS ONLY BUYS SILENCE WHERE IT CAN ACTUALLY RENDER (S212 fix
#     round 2). `text-overflow: ellipsis` does nothing at all on wrapping
#     text — and a base class that sets it on everything, which is how people
#     write CSS, bought silence for every box that wraps. Here a long
#     unbreakable word is chopped with NO "…" anywhere and the text is
#     genuinely lost.
# --------------------------------------------------------------------------
cat >"$S212FX/ellipsis-no-nowrap.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">
<div id="w" style="position:absolute;left:40px;top:100px;width:60px;height:22px;overflow:hidden;text-overflow:ellipsis;white-space:normal;border:1px solid #999;">Supercalifragilisticexpialidocious</div>
</body></html>
HTML
drive_observe ellipsis-no-nowrap.html ellipsis-nowrap
check "S212F7 the driver records white-space too, so the pass can tell whether the ellipsis can render" \
  "$PY -c 'import json,sys
els=json.load(open(sys.argv[1]))[\"page\"][\"elements\"]
e=[x for x in els if x.get(\"id\")==\"w\"]
sys.exit(0 if e and e[0].get(\"whiteSpace\")==\"normal\" else 1)' '$TMPROOT/s212-ellipsis-nowrap/readout.json'"
check "S212F7 an ellipsis that CANNOT render buys no silence — the lost word is reported" \
  "[ \"\$(count_kind '$TMPROOT/s212-ellipsis-nowrap/observations.json' clipped)\" = '1' ]"
check "S212F7 CONTROL — the real ellipsis idiom (nowrap) is STILL silent" \
  "! grep -q 'Shortened on purpose' '$TMPROOT/s212-ellipsis/observations.json'"
check "S212F7 CONTROL — overflow:hidden with no ellipsis at all STILL fires" \
  "grep -q 'Chopped off mid word' '$TMPROOT/s212-ellipsis/observations.json'"

else
  printf '  (node or Chrome not available — PART 5 (the S212 cry-wolf regression pack) skipped)\n'
fi

# ============================================================================
# PART 6 — the collapse and the cap as COPY, plus S210's invariant re-proven.
# Crafted input, because the exact counts and the exact sentence are the point.
# ============================================================================
echo
echo "PART 6 — the captain's copy for the collapse and the cap; the score invariant"

s212dir="$TMPROOT/s212-unit"; mkdir -p "$s212dir"

ROW() { # <n> <x> <y> — a focusable list row, with a recorded DOM path
  printf '{"id":null,"tag":"div","className":"row","text":"Row %s","interactive":true,"path":"0.1.%s","seen":true,"box":{"x":%s,"y":%s,"w":200,"h":30},"overflowX":0,"overflowY":0}' \
    "$1" "$1" "$2" "$3"
}

mk_readout "$s212dir/list-in.json" "[$(ROW 0 20 20),$(ROW 1 20 50),$(ROW 2 20 80),$(ROW 3 20 110),$(ROW 4 20 140)]"
observe "$s212dir/list-in.json" "$s212dir/list-out.json"
check "S212-6u five touching rows -> ONE note (arithmetic, exact)" \
  "[ \"\$($PY -c 'import json;print(len(json.load(open(\"'$s212dir'/list-out.json\"))[\"observations\"]))')\" = '1' ]"
check "S212-6u the sentence is the captain's, word for word" \
  "grep -q 'five rows in this list are touching' '$s212dir/list-out.json'"
# THE SAME NUMBER, TWICE OVER (S212 fix round 1). This used to expect 4 — the
# number of crowded PAIRS — beside a sentence that says "five rows". One fact
# computed two ways, disagreeing with itself in the captain's own record.
check "S212-6u the collapsed note records how many it stands for — the SAME number its sentence says" \
  "$PY -c 'import json,sys
d=json.load(open(sys.argv[1]))
o=d[\"observations\"][0]
sys.exit(0 if o.get(\"count\") == 5 and o[\"message\"].startswith(\"five rows\") else 1)' '$s212dir/list-out.json'"

# two of a kind do NOT collapse — a collapse that eats a genuine second fault
# is the quietening failure mode this session exists to avoid.
mk_readout "$s212dir/two-in.json" "[$(ROW 0 20 20),$(ROW 1 20 50)]"
observe "$s212dir/two-in.json" "$s212dir/two-out.json"
check "S212-6u CONTROL — a single crowded pair is NOT collapsed away, it is still reported plainly" \
  "[ \"\$(count_kind '$s212dir/two-out.json' crowding)\" = '1' ] && grep -q '0 px between them' '$s212dir/two-out.json'"

# --- the cap's copy, and the score invariant with a capped file -------------
scdir2="$TMPROOT/s212-score"; mkdir -p "$scdir2/a" "$scdir2/b"
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$scdir2/a/verdict.json" \
  >"$scdir2/a/stdout.txt" 2>/dev/null
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$scdir2/b/verdict.json" \
  "$s212dir/list-out.json" >"$scdir2/b/stdout.txt" 2>/dev/null
check "S212-8 SCORE identical with a collapsed observations file present" \
  "diff <(grep '^SCORE' '$scdir2/a/stdout.txt') <(grep '^SCORE' '$scdir2/b/stdout.txt') >/dev/null"
check "S212-8 the ledger is byte-identical too" \
  "$PY -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a[\"criteria\"] == b[\"criteria\"] and a[\"score\"] == b[\"score\"] else 1)' '$scdir2/a/verdict.json' '$scdir2/b/verdict.json'"
check "S212-8 the collapsed sentence reaches report.md — the captain's copy" \
  "grep -q 'five rows in this list are touching' '$scdir2/b/report.md'"

# a capped file's "I held back N" note must reach report.md too — a cap the
# captain cannot see is a cap that lies to him about how much it found.
BTN2() { printf '{"id":"%s","tag":"button","text":"%s","interactive":true,"path":"0.1.%s","seen":true,"box":{"x":%s,"y":%s,"w":60,"h":30},"overflowX":0,"overflowY":0}' "$1" "$2" "$3" "$4" "$5"; }
{
  printf '['
  for i in 0 1 2 3 4 5 6 7; do
    [ "$i" -gt 0 ] && printf ','
    y=$((20 + i * 90))
    printf '{"id":"b%sa","tag":"button","className":"g%sa","text":"A%s","interactive":true,"path":"0.1.%s0","seen":true,"box":{"x":20,"y":%s,"w":60,"h":30},"overflowX":0,"overflowY":0},' "$i" "$i" "$i" "$i" "$y"
    printf '{"id":"b%sb","tag":"button","className":"g%sb","text":"B%s","interactive":true,"path":"0.1.%s1","seen":true,"box":{"x":%s,"y":%s,"w":60,"h":30},"overflowX":0,"overflowY":0}' "$i" "$i" "$i" "$i" "$((80 + i))" "$y"
  done
  printf ']'
} >"$s212dir/busy-els.json"
printf '{"page": {"elements": %s}}\n' "$(cat "$s212dir/busy-els.json")" >"$s212dir/busy-in.json"
observe "$s212dir/busy-in.json" "$s212dir/busy-out.json"
scdir3="$TMPROOT/s212-score-cap"; mkdir -p "$scdir3"
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$scdir3/verdict.json" \
  "$s212dir/busy-out.json" >"$scdir3/stdout.txt" 2>/dev/null
check "S212-7u a busy page is capped to three" \
  "[ \"\$($PY -c 'import json;print(len(json.load(open(\"'$s212dir'/busy-out.json\"))[\"observations\"]))')\" = '3' ]"
check "S212-7u the 'held back' line reaches the captain's report.md, not just the JSON" \
  "grep -q 'a lot going on' '$scdir3/report.md' && grep -q 'held back 5' '$scdir3/report.md'"


# ==========================================================================
# PART 7 — SILENCE MUST BE EARNED (S212 ROUND 4). NOT another fix round: the
# RULE CHANGED, on the captain's own ruling, after three rounds sprang the
# same leak in three different places.
#
#   round 1: no alpha was measured at all, so ANY overlay silenced the page.
#   round 2: any background-image was assumed solid, so ANY gradient did.
#   round 3: any colour the regex could not read was assumed solid, so
#            oklch() / lab() / color-mix() / color(srgb …) did.
#
# Each author believed their remaining fallback was unreachable. Each was
# wrong. So the fallback itself is now the other way round:
#
#   AN ELEMENT MAY BE RECORDED AS NOT-SEEN ONLY WHEN HIDING WAS POSITIVELY
#   ESTABLISHED — an ancestor won the hit test (clipped), or a non-ancestor
#   cover was MEASURED opaque (covered). Everything else is SEEN.
#
# The captain accepted the cost knowingly: a wrong complaint is on the screen
# where he can see it and say it is wrong; going quiet means he never finds
# out it did not look.
# ==========================================================================

scrim() { # <tag> <the cover's style>
  over "r4-$1.html" "<div id=\"cover\" style=\"position:fixed;inset:0;$2\"></div>"
  drive_observe "r4-$1.html" "r4-$1"
}

# --- THE HEADLINE: six visually identical 30% dims, six colour syntaxes ----
# Every one of these paints the same grey wash over the same two buttons. A
# person cannot tell them apart by looking. Number One must not be able to
# either — and before this round, four of the six bought total silence.
for s in rgba hsl oklch colormix lab colorfn; do :; done
scrim rgba     'background-color:rgba(0,0,0,0.3);'
scrim hsl      'background-color:hsl(0 0% 0% / 0.3);'
scrim oklch    'background-color:oklch(0 0 0 / 0.3);'
scrim colormix 'background-color:color-mix(in srgb, black 30%, transparent);'
scrim lab      'background-color:lab(0 0 0 / 0.3);'
scrim colorfn  'background-color:color(srgb 0 0 0 / 0.3);'

for s in rgba hsl oklch colormix lab colorfn; do
  check "S212R4 a 30% dim written in $s is MEASURED — the pair under it is reported" \
    "[ \"\$(count_all '$TMPROOT/s212-r4-$s/observations.json')\" = '1' ] && grep -q 'the SAVE and CANCEL buttons are touching' '$TMPROOT/s212-r4-$s/observations.json'"
  check "S212R4 …and nothing under the $s dim was written off as unseen" \
    "[ \"\$($PY -c 'import json,sys;print(json.load(open(sys.argv[1]))[\"unseenCount\"])' '$TMPROOT/s212-r4-$s/observations.json')\" = '0' ]"
done

check "S212R4 THE HEADLINE — all six 30% dims read IDENTICALLY, word for word" \
  "$PY -c 'import json,sys
say=[[o[\"message\"] for o in json.load(open(p))[\"observations\"]] for p in sys.argv[1:]]
sys.exit(0 if len(set(map(tuple,say))) == 1 else 1)' \
  '$TMPROOT/s212-r4-rgba/observations.json' '$TMPROOT/s212-r4-hsl/observations.json' \
  '$TMPROOT/s212-r4-oklch/observations.json' '$TMPROOT/s212-r4-colormix/observations.json' \
  '$TMPROOT/s212-r4-lab/observations.json' '$TMPROOT/s212-r4-colorfn/observations.json'"

# --- AND THE ALPHA IS REALLY PARSED, not merely given up on ----------------
# If "cannot read it" were the only cure, an OPAQUE oklch backdrop would be
# measured too — and it genuinely does hide the page. These controls are what
# separate a parser from a shrug.
scrim opaque-oklch   'background-color:oklch(0 0 0 / 1);'
scrim opaque-colorfn 'background-color:color(srgb 0 0 0);'
scrim oklch-086      'background-color:oklch(0 0 0 / 0.86);'
scrim oklch-080      'background-color:oklch(0 0 0 / 0.80);'
check "S212R4 CONTROL — an OPAQUE oklch backdrop really hides the page, and is silent" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-opaque-oklch/observations.json')\" = '0' ]"
check "S212R4 CONTROL — color(srgb …) with no alpha channel at all is opaque, and is silent" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-opaque-colorfn/observations.json')\" = '0' ]"
check "S212R4 the 0.85 break holds in the new syntax too — 0.86 hides" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-oklch-086/observations.json')\" = '0' ]"
check "S212R4 …and 0.80 does not — the pair under it is reported" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-oklch-080/observations.json')\" = '1' ]"

# --- gradients, same rule, same two directions -----------------------------
scrim grad-fade  'background-image:linear-gradient(to bottom, oklch(0 0 0 / 0), oklch(0 0 0 / 0.1));'
scrim grad-solid 'background-image:linear-gradient(to bottom, oklch(0 0 0 / 1), oklch(0 0 0 / 1));'
check "S212R4 a fade-to-nothing gradient in oklch paints almost nothing and hides nothing" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-grad-fade/observations.json')\" = '1' ]"
check "S212R4 CONTROL — a FULLY OPAQUE oklch gradient still hides the page (the stops are really read)" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-grad-solid/observations.json')\" = '0' ]"

# --- and the paint the browser will not describe ---------------------------
# `paint(...)` is a Houdini worklet nobody registered: it paints not one
# pixel, and computed style cannot say what it would paint if it did. That is
# the "cannot be bounded" case, live, in a real browser — it must now mean
# LOOK ANYWAY, where before it meant silence.
scrim paint-worklet 'background-image:paint(nothingIsRegistered);'
check "S212R4 a background-image whose paint cannot be bounded means LOOK, not silence" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-paint-worklet/observations.json')\" = '1' ]"

# --- filters: the judgement call, reversed to match the rule ---------------
scrim filt-unknown 'backdrop-filter:drop-shadow(0 4px 4px rgba(0,0,0,0.5));'
scrim filt-blur8   'backdrop-filter:blur(8px);'
scrim filt-svg     'backdrop-filter:url(#nosuchfilter);'
check "S212R4 an UNRECOGNISED backdrop-filter no longer buys silence — the pair is reported" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-filt-unknown/observations.json')\" = '1' ]"
check "S212R4 CONTROL — a real blur(8px) glass panel still hides the page" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-filt-blur8/observations.json')\" = '0' ]"
check "S212R4 CONTROL — an SVG url(#…) filter is still read as hiding (documented exception)" \
  "[ \"\$(count_all '$TMPROOT/s212-r4-filt-svg/observations.json')\" = '0' ]"

# --------------------------------------------------------------------------
# A PLACE MUST BE EARNED TOO — the same shape of mistake, one file along.
#
# Round 2 made the place the LOWEST COMMON ANCESTOR of the whole group. But
# every real application has a wrapper — #app, #root, .container, <main> — so
# the LCA always finds something and a place was always asserted. A tab bar, a
# segmented control and a pager, three plainly separate things 60 px apart,
# all inside one #app, read as "seven buttons in this list are touching".
# There is no list of seven buttons on that screen.
# --------------------------------------------------------------------------
cat >"$S212FX/wrapped-tabs.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;">
<div id="app" style="padding:24px">
<h3>the same tab bar and segmented control, now inside one #app wrapper</h3>
<div id="tabs" style="position:absolute;left:24px;top:80px;display:flex;">
  <button style="height:34px;padding:0 16px;">Overview</button><button style="height:34px;padding:0 16px;">Activity</button><button style="height:34px;padding:0 16px;">Settings</button>
</div>
<div id="seg" style="position:absolute;left:24px;top:140px;display:inline-flex;">
  <button style="height:30px;padding:0 12px;">Day</button><button style="height:30px;padding:0 12px;">Week</button>
</div>
</div>
</body></html>
HTML
drive_observe wrapped-tabs.html wrapped-tabs
check "S212R4 a WRAPPER is not a place — wrapping the tab bar and segmented control in #app changes nothing" \
  "[ \"\$(count_kind '$TMPROOT/s212-wrapped-tabs/observations.json' crowding)\" = '3' ]"
check "S212R4 …and the three notes are the honest ones, naming the pairs that really touch" \
  "grep -q 'the Overview and Activity buttons are touching' '$TMPROOT/s212-wrapped-tabs/observations.json' && grep -q 'the Day and Week buttons are touching' '$TMPROOT/s212-wrapped-tabs/observations.json'"
check "S212R4 …and no note invents a row or a list that is not on the screen" \
  "! grep -qE 'five buttons in this (row|list)' '$TMPROOT/s212-wrapped-tabs/observations.json'"

cat >"$S212FX/wrapped-three-groups.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;">
<div id="app" style="padding:24px">
<h3>a tab bar, a segmented control and a pager — three separate things in one #app</h3>
<div id="tabs" style="position:absolute;left:24px;top:80px;display:flex;">
  <button style="height:34px;padding:0 16px;">Overview</button><button style="height:34px;padding:0 16px;">Activity</button><button style="height:34px;padding:0 16px;">Settings</button>
</div>
<div id="seg" style="position:absolute;left:24px;top:140px;display:inline-flex;">
  <button style="height:30px;padding:0 12px;">Day</button><button style="height:30px;padding:0 12px;">Week</button>
</div>
<div id="pager" style="position:absolute;left:24px;top:200px;display:inline-flex;">
  <button style="height:30px;padding:0 12px;">Prev</button><button style="height:30px;padding:0 12px;">Next</button>
</div>
</div>
</body></html>
HTML
drive_observe wrapped-three-groups.html wrapped-three
check "S212R4 THE TESTER'S FIXTURE — three separate groups in one #app never become one list of seven" \
  "! grep -q 'seven buttons in this' '$TMPROOT/s212-wrapped-three/observations.json'"
check "S212R4 …they stay four honest pair notes, one per pair that really touches" \
  "[ \"\$(count_kind '$TMPROOT/s212-wrapped-three/observations.json' crowding)\" = '4' ]"

# THE OTHER DIRECTION, which is the whole reason a place exists at all: a
# genuinely repeated family IS one list, and must still fold to one note.
check "S212R4 CONTROL — twenty rows each with its own Edit/Delete pair are STILL one note" \
  "[ \"\$(count_kind '$TMPROOT/s212-twenty-rows/observations.json' crowding)\" = '1' ]"
check "S212R4 CONTROL — three pairs each in its own sub-div are STILL one note" \
  "[ \"\$(count_kind '$TMPROOT/s212-split-subdivs/observations.json' crowding)\" = '1' ]"

# And a group scattered across the page has no place at all — it says so.
cat >"$S212FX/scattered-pairs.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:14px system-ui;padding:24px">
<h3>three crowded pairs scattered across the page</h3>
<div style="position:absolute;left:40px;top:100px;"><button style="width:110px;height:34px;">P0</button><button style="width:110px;height:34px;">Q0</button></div>
<div style="position:absolute;left:600px;top:300px;"><button style="width:110px;height:34px;">P1</button><button style="width:110px;height:34px;">Q1</button></div>
<div style="position:absolute;left:1000px;top:600px;"><button style="width:110px;height:34px;">P2</button><button style="width:110px;height:34px;">Q2</button></div>
</body></html>
HTML
drive_observe scattered-pairs.html scattered
check "S212R4 CONTROL — three pairs scattered across the page stay three separate notes" \
  "[ \"\$(count_kind '$TMPROOT/s212-scattered/observations.json' crowding)\" = '3' ]"
check "S212R4 CONTROL — and none of them claims a row or a list" \
  "! grep -qE 'in this (row|list)' '$TMPROOT/s212-scattered/observations.json'"

# --------------------------------------------------------------------------
# A NUMBER WITH NO STORY. "38 buttons in this list are touching" is arithmetic
# the captain cannot picture. It was TWENTY ROWS, each with its own Edit and
# Delete. A person would say so.
# --------------------------------------------------------------------------
# (the file is ASCII-escaped JSON, so the em dash is matched by its halves)
check "S212R4 the repeated-family sentence describes the SHAPE, in his words" \
  "$PY -c 'import json,sys
o=[x for x in json.load(open(sys.argv[1]))[\"observations\"] if x.get(\"kind\")==\"crowding\"][0]
want = \"every row\u2019s Edit and Delete buttons are touching \u2014 0 px between them\".replace(\"\u2019\", chr(39))
sys.exit(0 if o[\"message\"] == want else 1)' '$TMPROOT/s212-twenty-rows/observations.json'"
check "S212R4 …and the record still carries the count the sentence no longer needs to say" \
  "$PY -c 'import json,sys
o=[x for x in json.load(open(sys.argv[1]))[\"observations\"] if x.get(\"kind\")==\"crowding\"][0]
sys.exit(0 if o.get(\"count\") == 38 else 1)' '$TMPROOT/s212-twenty-rows/observations.json'"


# ==========================================================================
# PART 8 — "EVERY" HAS TO BE ESTABLISHED, NOT ASSUMED (S212 round 5), and the
# ONE SILENCE THAT IS LEFT has to reach his copy.
#
# THE DEFECT THE TESTER FOUND, on a page it built for the purpose: eight list
# rows, the first three with their Edit and Delete touching and the last five
# comfortably spaced. It read "every row's Edit and Delete buttons are
# touching — 0 px between them" while five well-spaced rows sat on the screen
# in the same glance. The guard in front of "every" checked that the AFFECTED
# units look alike — same column, same names, same order — and never once
# checked that every unit of the family IS affected.
#
# A number with no story ("38 buttons in this list are touching") was the
# round-4 defect. A STORY WITH A FALSE NUMBER is worse: it is the kind of
# error the captain catches himself, standing in front of the screen, and it
# costs him confidence in everything else the feature says.
# ==========================================================================
$PY - "$S212FX/some-rows-touching.html" <<'PYGEN'
import sys
def row(i, gap):
    return ('<div class="row" style="padding:5px 0">'
            '<span style="display:inline-block;width:160px;">Batch B-20%02d</span>'
            '<button style="height:26px;padding:0 10px;%s">Edit</button>'
            '<button style="height:26px;padding:0 10px;">Delete</button></div>'
            % (i, "margin-right:12px;" if gap else ""))
rows = "".join(row(i, i >= 3) for i in range(8))
open(sys.argv[1], "w").write(
    '<!doctype html><html><body style="margin:0;font:14px system-ui;padding:20px">'
    '<div id="list" style="position:absolute;left:24px;top:70px;">' + rows +
    '</div></body></html>')
PYGEN
drive_observe some-rows-touching.html some-rows
check "S212R5 three of eight rows touching is still ONE fact, said once" \
  "[ \"\$(count_kind '$TMPROOT/s212-some-rows/observations.json' crowding)\" = '1' ]"
check "S212R5 THE TESTER'S PAGE — it does NOT claim every row when five rows are fine" \
  "! grep -q 'every row' '$TMPROOT/s212-some-rows/observations.json'"
check "S212R5 …and what it says instead is true, and still a sentence a person would say" \
  "$PY -c 'import json,sys
o=[x for x in json.load(open(sys.argv[1]))[\"observations\"] if x.get(\"kind\")==\"crowding\"][0]
want = \"three rows’ Edit and Delete buttons are touching — 0 px between them\".replace(\"’\", chr(39))
sys.exit(0 if o[\"message\"] == want else 1)' '$TMPROOT/s212-some-rows/observations.json'"
check "S212R5 …and the count in the record is still every button the note stands for" \
  "$PY -c 'import json,sys
o=[x for x in json.load(open(sys.argv[1]))[\"observations\"] if x.get(\"kind\")==\"crowding\"][0]
sys.exit(0 if o.get(\"count\") == 6 else 1)' '$TMPROOT/s212-some-rows/observations.json'"
# THE OTHER DIRECTION, and the reason the word exists at all: when every row
# really is affected, "every row's" is both true and the sentence he would
# say. (Asserted verbatim above as well; this is the pairing that makes the
# new guard a guard rather than a mute.)
check "S212R5 CONTROL — a page where every row IS affected still says so" \
  "grep -q \"every row's Edit and Delete buttons are touching\" '$TMPROOT/s212-twenty-rows/observations.json'"

# --------------------------------------------------------------------------
# THE ONE SILENCE THAT IS LEFT. The flip narrowed "I did not look at that" to
# POSITIVELY established hiding — a real opaque lid over a real element — so
# what is left is rare and legitimate. It was written into the record and
# never into his copy, which means the one thing the look admits it could not
# see was the one thing he could not read.
# --------------------------------------------------------------------------
unseendir="$TMPROOT/s212-unseen"; mkdir -p "$unseendir/none" "$unseendir/some" "$unseendir/one"
$PY -c 'import json,sys
d=json.load(open(sys.argv[1])); d["unseenCount"]=int(sys.argv[3]); json.dump(d,open(sys.argv[2],"w"))' \
  "$obsdir/crowd-out.json" "$unseendir/three.json" 3
$PY -c 'import json,sys
d=json.load(open(sys.argv[1])); d["unseenCount"]=int(sys.argv[3]); json.dump(d,open(sys.argv[2],"w"))' \
  "$obsdir/crowd-out.json" "$unseendir/one.json" 1
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$unseendir/some/verdict.json" \
  "$unseendir/three.json" >"$unseendir/some/stdout.txt" 2>/dev/null
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$unseendir/one/verdict.json" \
  "$unseendir/one.json" >"$unseendir/one/stdout.txt" 2>/dev/null
"$PY" "$SCOREPY" "$scdir/worker-verdict.json" "$scdir/criteria-drawn.json" "$unseendir/none/verdict.json" \
  "$obsdir/crowd-out.json" >"$unseendir/none/stdout.txt" 2>/dev/null
check "S212R5 what was hidden from it reaches HIS report, in his words" \
  "grep -q 'Three things on this page were behind something solid, so I could not look at them.' '$unseendir/some/report.md'"
check "S212R5 …and one of them is one thing, not '1 things'" \
  "grep -q 'One thing on this page was behind something solid, so I could not look at it.' '$unseendir/one/report.md'"
check "S212R5 CONTROL — nothing hidden, nothing said: no sentence about it at all" \
  "! grep -q 'behind something solid' '$unseendir/none/report.md'"
check "S212R5 CONTROL — and saying it still never moves the score" \
  "diff <(grep '^SCORE' '$unseendir/none/stdout.txt') <(grep '^SCORE' '$unseendir/some/stdout.txt') >/dev/null && diff <(grep '^WHY' '$unseendir/none/stdout.txt') <(grep '^WHY' '$unseendir/some/stdout.txt') >/dev/null"
check "S212R5 CONTROL — and the ledger is byte-identical with it and without it" \
  "$PY -c 'import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
sys.exit(0 if a[\"criteria\"] == b[\"criteria\"] and a[\"score\"] == b[\"score\"] else 1)' '$unseendir/none/verdict.json' '$unseendir/some/verdict.json'"

# ==========================================================================
# PART 9 — SESSION 213: THE TWO DETECTOR BUGS THE REAL EDITOR FOUND.
#
# S212 taught the look not to say the same true thing five times. It did not
# teach it to stop saying things that were never true. Driven against a real
# tile-map editor (RECON-2026-09-16), the observations pass produced FIVE
# faults and ALL FIVE were wrong. They are TWO code defects, not five:
#
#   detect_crowding  fired on the New/Open toolbar pair (4 px), the Maps/Objects
#                    tab bar (4 px) and the layer rows (2 px, seven of them).
#                    One 8 px floor, four surfacings. Real interfaces use 2-6 px
#                    between neighbours ON PURPOSE; an absolute floor cannot tell
#                    deliberate spacing from a mistake and never could.
#   detect_misaligned read the New/Open pair — two buttons SIDE BY SIDE — as one
#                    of them being 90 px out of line with a column. There is no
#                    column. It was the most confidently worded sentence in the
#                    report and there was nothing there at all.
#
# THE CAPTAIN'S RULING, 2026-09-17, not open to re-litigation: a flush tab bar /
# segmented control is NOT a crowding fault; sibling controls touching there are
# deliberate design.
#
# EVERY BEHAVIOUR BELOW SHIPS AS A PAIR — the false alarm that must now be
# SILENT, and beside it the known-good positive control that MUST STILL FIRE.
# That pairing is the point. The failure mode of this work is quietening the
# guard into uselessness, and a guard that cannot fire is worse than the noise
# it replaced.
#
# The geometry is not invented: the boxes, classes and DOM paths below are the
# ones the driver actually recorded off that editor (turntwo/readout.json), fed
# in directly so the arithmetic is the only thing under test — the same way this
# suite has always proved the observation arithmetic. The same shapes are then
# driven through REAL headless Chrome further down, so nothing rests on crafted
# input alone.
# ==========================================================================
echo
echo "PART 9 — S213: the two detector bugs the real editor found"

s213dir="$TMPROOT/s213"; mkdir -p "$s213dir"

# --- the real editor's header: New Project beside Open Project, 4 px apart ---
# (classes and paths verbatim from the readout; gap = 102 - (12+86) = 4)
# It is a TOOLBAR and it says so — `segment` is what xo-drive.js records off a
# `role="toolbar"` container, and that declaration is the whole reason these two
# are allowed to sit 4 px apart. FIX ROUND 1: the round before this one tried to
# earn the same silence by comparing the gap with its neighbours' rhythm and
# INVERTED the detector — on a uniformly tight page the tightness became its own
# excuse, so crowding fired at 0 px and essentially nowhere else. A declaration
# cannot invert like that.
mk_readout "$s213dir/toolbar-in.json" '[
  {"id":null,"tag":"button","className":"rounded px-2 py-1 text-xs font-medium","text":"New Project","interactive":true,"segment":"0.1.0.0.0|toolbar","path":"0.1.0.0.0.0","box":{"x":12,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"rounded px-2 py-1 text-xs font-medium","text":"Open Project","interactive":true,"segment":"0.1.0.0.0|toolbar","path":"0.1.0.0.0.1","box":{"x":102,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0}
]'
observe "$s213dir/toolbar-in.json" "$s213dir/toolbar-out.json"
check "S213-B2 a DECLARED toolbar pair 4 px apart is SPACING — no crowding complaint" \
  "[ \"\$(count_kind '$s213dir/toolbar-out.json' crowding)\" = '0' ]"
check "S213-B3 …and the pair sits SIDE BY SIDE, so it is no misaligned column either" \
  "[ \"\$(count_kind '$s213dir/toolbar-out.json' misaligned)\" = '0' ]"
check "S213-B3 …the invented sentence is gone by name: nothing claims 90 px out of line" \
  "! grep -q '90 px' '$s213dir/toolbar-out.json'"
check "S213 …and that page produces NO observation of any kind" \
  "[ \"\$($PY -c 'import json;print(len(json.load(open(\"'$s213dir'/toolbar-out.json\"))[\"observations\"]))')\" = '0' ]"

# --- the tab bar, 4 px apart, and the two tabs carry DIFFERENT classes -------
# (selected vs unselected — which is why they escaped every family-based guard.
# They do NOT escape the declaration: the bar says `role="tablist"`, and both
# tabs carry the same `segment` because they are in the same declared bar.)
mk_readout "$s213dir/tabs-in.json" '[
  {"id":null,"tag":"button","className":"rounded px-3 py-1 bg-blue-600 text-white transition-colors","text":"Maps","interactive":true,"segment":"0.1.0.0.1|tablist","path":"0.1.0.0.1.0","box":{"x":8,"y":50,"w":56,"h":26},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"rounded px-3 py-1 text-slate-300 transition-colors","text":"Objects","interactive":true,"segment":"0.1.0.0.1|tablist","path":"0.1.0.0.1.1","box":{"x":68,"y":50,"w":66,"h":26},"overflowX":0,"overflowY":0}
]'
observe "$s213dir/tabs-in.json" "$s213dir/tabs-out.json"
check "S213-B2/C9 a declared tab bar 4 px apart is a tab bar — no crowding complaint" \
  "[ \"\$(count_kind '$s213dir/tabs-out.json' crowding)\" = '0' ]"

# THE CAPTAIN'S RULING C9, AT ITS HARDEST: a tab bar whose tabs actually TOUCH.
# Zero is the one gap the old rule could never forgive, which is why the ruling
# fired on exactly the case he had exempted.
mk_readout "$s213dir/tabs-flush-in.json" '[
  {"id":null,"tag":"button","className":"tab on","text":"Maps","interactive":true,"segment":"0.1.0.0.1|tablist","path":"0.1.0.0.1.0","box":{"x":8,"y":50,"w":56,"h":26},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"tab","text":"Objects","interactive":true,"segment":"0.1.0.0.1|tablist","path":"0.1.0.0.1.1","box":{"x":64,"y":50,"w":66,"h":26},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"tab","text":"Tiles","interactive":true,"segment":"0.1.0.0.1|tablist","path":"0.1.0.0.1.2","box":{"x":130,"y":50,"w":50,"h":26},"overflowX":0,"overflowY":0}
]'
observe "$s213dir/tabs-flush-in.json" "$s213dir/tabs-flush-out.json"
check "S213-C9 a declared tab bar whose tabs TOUCH is silent — 0 px and deliberate" \
  "[ \"\$(count_kind '$s213dir/tabs-flush-out.json' crowding)\" = '0' ]"

# --- the layer rail: SEVEN rows at 2 px, exactly as the editor draws them ----
# This is the fourth of the four real-world false alarms, and the one fix round
# 1 put back by deleting the rhythm rule outright. A list every row of which
# sits 2 px from the next is the spacing that list was WRITTEN with — six
# identical gaps are not six mistakes — and no absolute floor can see that.
# It is not declared and it never will be: a list is not a segmented control,
# so the declaration check cannot save it. Its own rhythm is the only evidence
# there is, and it is enough.
LROW() { # <n> <y>
  printf '{"id":null,"tag":"button","className":"flex items-center gap-2 rounded px-2 py-1.5","text":"","interactive":true,"path":"0.1.0.0.2.0.0.%s","box":{"x":8,"y":%s,"w":264,"h":28},"overflowX":0,"overflowY":0}' "$1" "$2"
}
mk_readout "$s213dir/rail-in.json" "[$(LROW 1 109),$(LROW 2 139),$(LROW 3 169),$(LROW 4 199),$(LROW 5 229),$(LROW 6 259),$(LROW 7 289)]"
observe "$s213dir/rail-in.json" "$s213dir/rail-out.json"
check "S213-B2 the real editor's SEVEN-ROW layer rail at 2 px is that rail's own rhythm — silent" \
  "[ \"\$(count_kind '$s213dir/rail-out.json' crowding)\" = '0' ]"
check "S213-B2 …and nothing claims seven buttons sit on top of each other" \
  "! grep -q 'seven buttons' '$s213dir/rail-out.json'"

# …and the comfortable version of the same list, which must also stay silent.
mk_readout "$s213dir/rail-wide-in.json" "[$(LROW 1 109),$(LROW 2 147),$(LROW 3 185),$(LROW 4 223),$(LROW 5 261),$(LROW 6 299),$(LROW 7 337)]"
observe "$s213dir/rail-wide-in.json" "$s213dir/rail-wide-out.json"
check "S213-B2 a list with roomy spacing between its rows says nothing either" \
  "[ \"\$(count_kind '$s213dir/rail-wide-out.json' crowding)\" = '0' ]"

# ==========================================================================
# THE CONTROLS. Each is the SAME SHAPE as a silence above with ONE thing
# changed, so the silence cannot be coming from the detector being switched
# off. If any of these stops firing, the cure has become a mute.
# ==========================================================================
printf '\n  -- S213 CONTROLS: what must STILL fire --\n'

# CONTROL 0 — THE SAME BAR, UNDECLARED. One field removed from the fixture
# above and the silence is gone: nothing about the boxes bought it, the
# page SAYING it did. This is the pair the whole cure turns on.
mk_readout "$s213dir/bar-plain-in.json" '[
  {"id":null,"tag":"button","className":"btn","text":"ADD","interactive":true,"path":"0.1.0.0.0.0","box":{"x":12,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"btn","text":"CANCEL","interactive":true,"path":"0.1.0.0.0.1","box":{"x":98,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0}
]'
observe "$s213dir/bar-plain-in.json" "$s213dir/bar-plain-out.json"
check "S213-B2 CONTROL — the SAME two buttons TOUCHING with nothing declared STILL fires" \
  "[ \"\$(count_kind '$s213dir/bar-plain-out.json' crowding)\" = '1' ]"
check "S213-B2 CONTROL — …in the captain's own complaint, naming both" \
  "grep -q 'the ADD and CANCEL buttons are touching' '$s213dir/bar-plain-out.json'"

# THE LIMIT, STATED OUT LOUD RATHER THAN HIDDEN — and it is a limit, not a
# defect. A run every one of whose neighbours sits at 1 px reads as that run's
# rhythm and goes SILENT, exactly as the 2 px layer rail above does, because
# uniformity genuinely cannot tell "tight on purpose" from "wrong everywhere"
# without a declaration to read. Fix round 1 answered that by deleting the
# rhythm rule; deleting it brought the layer rail's false alarm back. The trade
# is accepted on the record (orchestrator, S213 fix round 2) and pinned here so
# that if anyone ever changes it they change it deliberately.
TIGHT() { # <n> <x> — a run of three evenly-spaced buttons in one container
  printf '{"id":null,"tag":"button","className":"b","text":"B%s","interactive":true,"path":"0.1.0.%s","box":{"x":%s,"y":10,"w":60,"h":24},"overflowX":0,"overflowY":0}' "$1" "$1" "$2"
}
# One page per gap: the observations pass HOLDS BACK the quieter findings when a
# page has many (S212), so three tight runs on one page would prove nothing
# about the third.
for g in 1 3 6; do
  mk_readout "$s213dir/tight-$g-in.json" \
    "[$(TIGHT 0 10),$(TIGHT 1 $((70 + g))),$(TIGHT 2 $((130 + g + g)))]"
  observe "$s213dir/tight-$g-in.json" "$s213dir/tight-$g-out.json"
  check "S213-B2 KNOWN LIMIT — an evenly ${g} px run is read as rhythm and stays silent" \
    "[ \"\$(count_kind '$s213dir/tight-$g-out.json' crowding)\" = '0' ]"
done

# CONTROL 1 — the SAME three buttons with the rhythm BROKEN: one pair tight,
# the other roomy. There is a rhythm here and this pair is not in it, so the
# guard speaks. This is the live half of the limit above — the run's evenness
# is doing the forgiving, and nothing else is.
mk_readout "$s213dir/tight-odd-in.json" \
  "[$(TIGHT 0 10),$(TIGHT 1 71),$(TIGHT 2 143)]"
observe "$s213dir/tight-odd-in.json" "$s213dir/tight-odd-out.json"
check "S213-B2 CONTROL — one 1 px pair in a run whose other gap is 12 px FIRES" \
  "[ \"\$(count_kind '$s213dir/tight-odd-out.json' crowding)\" = '1' ]"
check "S213-B2 CONTROL — …and it names the number it measured" \
  "grep -q '1 px' '$s213dir/tight-odd-out.json'"

# CONTROL 1b — and an evenly-spaced run of three UNDECLARED buttons that
# actually TOUCH still fires. Zero is not a spacing anybody chooses; it is the
# absence of one, so no amount of evenness buys it silence. Only a declaration
# does, and these have none. The captain's original complaint, at its hardest.
mk_readout "$s213dir/tight-0-in.json" \
  "[$(TIGHT 0 10),$(TIGHT 1 70),$(TIGHT 2 130)]"
observe "$s213dir/tight-0-in.json" "$s213dir/tight-0-out.json"
check "S213-B2 CONTROL — three UNDECLARED buttons evenly TOUCHING at 0 px STILL fire" \
  "[ \"\$(count_kind '$s213dir/tight-0-out.json' crowding)\" -ge '1' ]"

# CONTROL 2 — a list whose rows sit 12 px apart except for ONE pair at 2 px.
# The list has a rhythm and that pair is not in it. This is the shape the real
# editor's BROKEN rail has, and it is what separates a tight list from a
# mistake in a roomy one.
mk_readout "$s213dir/rail-tight-in.json" \
  "[$(LROW 1 109),$(LROW 2 149),$(LROW 3 189),$(LROW 4 219),$(LROW 5 259),$(LROW 6 299),$(LROW 7 339)]"
observe "$s213dir/rail-tight-in.json" "$s213dir/rail-tight-out.json"
check "S213-B2 CONTROL — one pair at 2 px in a list whose other rows sit 12 px apart STILL fires" \
  "[ \"\$(count_kind '$s213dir/rail-tight-out.json' crowding)\" -ge '1' ]"
check "S213-B2 CONTROL — …and it names the number it measured" \
  "grep -q '2 px' '$s213dir/rail-tight-out.json'"

# CONTROL 3 — two controls from DIFFERENT containers nearly colliding.
mk_readout "$s213dir/collide-in.json" '[
  {"id":null,"tag":"button","className":"a","text":"Save","interactive":true,"path":"0.1.0.0","box":{"x":12,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"b","text":"Delete","interactive":true,"path":"0.2.0.0","box":{"x":101,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0}
]'
observe "$s213dir/collide-in.json" "$s213dir/collide-out.json"
check "S213-B2 CONTROL — two controls from different containers 3 px apart STILL fires" \
  "[ \"\$(count_kind '$s213dir/collide-out.json' crowding)\" = '1' ]"

# CONTROL 4 — the misaligned detector has not been switched off: a real COLUMN
# with one row out of line still reports, and still says by how much.
mk_readout "$s213dir/column-in.json" '[
  {"id":null,"tag":"button","className":"rounded px-2 py-1 text-xs font-medium","text":"New Project","interactive":true,"path":"0.1.0.0.0.0","box":{"x":12,"y":12,"w":86,"h":24},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"rounded px-2 py-1 text-xs font-medium","text":"Open Project","interactive":true,"path":"0.1.0.0.0.1","box":{"x":12,"y":60,"w":86,"h":24},"overflowX":0,"overflowY":0},
  {"id":null,"tag":"button","className":"rounded px-2 py-1 text-xs font-medium","text":"Save Project","interactive":true,"path":"0.1.0.0.0.2","box":{"x":102,"y":108,"w":86,"h":24},"overflowX":0,"overflowY":0}
]'
observe "$s213dir/column-in.json" "$s213dir/column-out.json"
check "S213-B3 CONTROL — a REAL column with one row 90 px out of line STILL fires" \
  "[ \"\$(count_kind '$s213dir/column-out.json' misaligned)\" = '1' ]"
check "S213-B3 CONTROL — …and it is the offending row it names, with the number" \
  "grep -q 'Save Project' '$s213dir/column-out.json' && grep -q '90 px' '$s213dir/column-out.json'"

# CONTROL 5 — FIX ROUND 1's OWN DEFECT: a HORIZONTAL ROW with one item 90 px
# low drew NOTHING. is_a_column killed the false positive by looking only
# inside vertical stacks, and went blind to every row in the product doing it.
# A row lines up on the edge its container NAMES (`align-items`), and the
# member that misses that edge is the fault.
ROWDECL() { # <n> <x> <y> <h> <text>
  printf '{"id":null,"tag":"button","className":"btn","text":"%s","interactive":true,"path":"0.1.0.%s","alignSelf":"auto","box":{"x":%s,"y":%s,"w":88,"h":%s},"overflowX":0,"overflowY":0}' "$5" "$1" "$2" "$3" "$4"
}
BAR() { # <alignItems>
  printf '{"id":"bar","tag":"div","className":"bar","interactive":false,"path":"0.1.0","display":"flex","flexDirection":"row","alignItems":"%s","box":{"x":0,"y":0,"w":600,"h":135}}' "$1"
}
mk_readout "$s213dir/row-low-in.json" \
  "[$(BAR normal),$(ROWDECL 0 12 12 24 'New Project'),$(ROWDECL 1 108 102 24 'Open Project')]"
observe "$s213dir/row-low-in.json" "$s213dir/row-low-out.json"
check "S213-B3 CONTROL — one item 90 px low in a HORIZONTAL row now fires" \
  "[ \"\$(count_kind '$s213dir/row-low-out.json' misaligned)\" = '1' ]"
check "S213-B3 CONTROL — …naming the item, the edge and the number" \
  "grep -q 'Open Project' '$s213dir/row-low-out.json' && grep -q 'top edge is 90 px lower' '$s213dir/row-low-out.json'"

# …AND ITS SILENT HALF: the same declared row, correctly laid out. This is the
# original false positive — the 90 px between two side-by-side buttons read as
# one of them being out of line — and it must stay dead.
mk_readout "$s213dir/row-ok-in.json" \
  "[$(BAR normal),$(ROWDECL 0 12 12 24 'New Project'),$(ROWDECL 1 108 12 24 'Open Project')]"
observe "$s213dir/row-ok-in.json" "$s213dir/row-ok-out.json"
check "S213-B3 a correct horizontal New/Open pair says nothing at all" \
  "[ \"\$($PY -c 'import json;print(len(json.load(open(\"'$s213dir'/row-ok-out.json\"))[\"observations\"]))')\" = '0' ]"

# …and a row that lines up on a DIFFERENT edge is judged on THAT edge, because
# the row says which: a bottom-aligned row of different-height controls is a
# correct row, and the old top-edge assumption would have called it broken.
mk_readout "$s213dir/row-bottom-in.json" \
  "[$(BAR flex-end),$(ROWDECL 0 12 12 60 'Panel'),$(ROWDECL 1 108 48 24 'Go')]"
observe "$s213dir/row-bottom-in.json" "$s213dir/row-bottom-out.json"
check "S213-B3 a bottom-aligned row of different-height controls is correct — silent" \
  "[ \"\$(count_kind '$s213dir/row-bottom-out.json' misaligned)\" = '0' ]"
mk_readout "$s213dir/row-bottom-bad-in.json" \
  "[$(BAR flex-end),$(ROWDECL 0 12 12 60 'Panel'),$(ROWDECL 1 108 12 24 'Go')]"
observe "$s213dir/row-bottom-bad-in.json" "$s213dir/row-bottom-bad-out.json"
check "S213-B3 CONTROL — …and the same row with one control off that edge fires" \
  "[ \"\$(count_kind '$s213dir/row-bottom-bad-out.json' misaligned)\" = '1' ]"

# --- and through a REAL browser, so none of this rests on crafted input -----
# The declarations below are the ones a real accessible editor carries, and the
# `segment` / `display` / `align-items` facts the driver reads off them are the
# same facts the crafted fixtures above state by hand.
if [ "$HAVE_NODE" -eq 1 ] && [ "$HAVE_CHROME" -eq 1 ]; then
cat >"$S212FX/real-editor.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:12px system-ui;background:#0f172a;color:#e2e8f0">
<div id="app">
  <div id="header" role="toolbar" style="position:absolute;left:12px;top:12px;">
    <button style="height:24px;width:120px;margin-right:4px;">New Project</button><button style="height:24px;width:120px;">Open Project</button>
  </div>
  <div id="tabbar" role="tablist" style="position:absolute;left:8px;top:50px;">
    <button role="tab" aria-selected="true" style="height:26px;width:80px;background:#2563eb;color:#fff;">Maps</button><button role="tab" aria-selected="false" style="height:26px;width:90px;color:#cbd5e1;">Objects</button>
  </div>
  <div id="rail" style="position:absolute;left:8px;top:109px;">
    <button style="display:block;height:28px;width:264px;margin-bottom:2px;">Ground</button>
    <button style="display:block;height:28px;width:264px;margin-bottom:2px;">Surface</button>
    <button style="display:block;height:28px;width:264px;margin-bottom:2px;">Overhead</button>
    <button style="display:block;height:28px;width:264px;margin-bottom:2px;">Entities</button>
  </div>
</div>
</body></html>
HTML
drive_observe real-editor.html s213-editor
check "S213 REAL BROWSER — a DECLARED toolbar (4 px), a DECLARED tab bar FLUSH and a 2 px layer rail produce ZERO observations" \
  "[ \"\$(count_all '$TMPROOT/s212-s213-editor/observations.json')\" = '0' ]"

cat >"$S212FX/real-editor-broken.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:12px system-ui;background:#0f172a;color:#e2e8f0">
<div id="app">
  <div id="rail" style="position:absolute;left:8px;top:109px;">
    <button style="display:block;height:28px;width:264px;margin-bottom:12px;">Ground</button>
    <button style="display:block;height:28px;width:264px;margin-bottom:12px;">Surface</button>
    <button style="display:block;height:28px;width:264px;margin-bottom:1px;">Overhead</button>
    <button style="display:block;height:28px;width:264px;margin-bottom:12px;">Entities</button>
  </div>
</div>
</body></html>
HTML
drive_observe real-editor-broken.html s213-editor-broken
check "S213 REAL BROWSER CONTROL — the SAME list with one row out of step STILL fires" \
  "[ \"\$(count_kind '$TMPROOT/s212-s213-editor-broken/observations.json' crowding)\" -ge '1' ]"

# THE UNDECLARED HALF, in a real browser: the same two buttons, no role on the
# bar, touching. Nothing about the pixels changed — only whether the page said
# what the bar was.
cat >"$S212FX/real-plain-bar.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:12px system-ui">
<div id="bar" style="position:absolute;left:12px;top:12px;">
  <button style="height:24px;width:120px;">ADD</button><button style="height:24px;width:120px;">CANCEL</button>
</div>
</body></html>
HTML
drive_observe real-plain-bar.html s213-plain-bar
check "S213-B2 REAL BROWSER CONTROL — two UNDECLARED buttons touching fires" \
  "[ \"\$(count_kind '$TMPROOT/s212-s213-plain-bar/observations.json' crowding)\" -ge '1' ]"

cat >"$S212FX/real-flush-tabs.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:12px system-ui">
<div id="tabs" role="tablist" style="position:absolute;left:12px;top:12px;">
  <button role="tab" aria-selected="true" style="height:26px;width:90px;">Maps</button><button role="tab" aria-selected="false" style="height:26px;width:90px;">Objects</button><button role="tab" aria-selected="false" style="height:26px;width:90px;">Tiles</button>
</div>
</body></html>
HTML
drive_observe real-flush-tabs.html s213-flush-tabs
check "S213-C9 REAL BROWSER — a canonical ARIA tab bar with TOUCHING tabs is silent" \
  "[ \"\$(count_all '$TMPROOT/s212-s213-flush-tabs/observations.json')\" = '0' ]"

# THE ROW THE DETECTOR WENT BLIND TO, in a real browser — both the way a flex
# row lays out when the buttons size themselves, and when they carry a height.
cat >"$S212FX/real-row-low.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:12px system-ui">
<div id="bar" style="display:flex;gap:8px;padding:12px">
  <button id="new" style="height:24px">New Project</button>
  <button id="open" style="height:24px;margin-top:90px">Open Project</button>
</div>
</body></html>
HTML
drive_observe real-row-low.html s213-row-low
check "S213-B3 REAL BROWSER CONTROL — one button 90 px low in a flex ROW fires" \
  "[ \"\$(count_kind '$TMPROOT/s212-s213-row-low/observations.json' misaligned)\" -ge '1' ]"
check "S213-B3 REAL BROWSER CONTROL — …and it names the button that is low" \
  "grep -q 'Open Project' '$TMPROOT/s212-s213-row-low/observations.json'"

cat >"$S212FX/real-row-ok.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:12px system-ui">
<div id="bar" style="display:flex;gap:20px;padding:12px">
  <button id="new" style="height:24px">New Project</button>
  <button id="open" style="height:24px">Open Project</button>
</div>
</body></html>
HTML
drive_observe real-row-ok.html s213-row-ok
check "S213-B3 REAL BROWSER — the correct New/Open row says nothing at all" \
  "[ \"\$(count_all '$TMPROOT/s212-s213-row-ok/observations.json')\" = '0' ]"
else
  printf '  (node or Chrome not available — the S213 real-browser pairs skipped)\n'
fi

# ==========================================================================
echo
printf 'lcars xo-observe: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
