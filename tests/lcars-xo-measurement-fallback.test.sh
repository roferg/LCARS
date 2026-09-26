#!/usr/bin/env bash
#
# Tests for MEASUREMENT BLACKOUT → FALL BACK TO THE PICTURE IT ALREADY HAS
# (the captain, 2026-09-25).
#
# THE DEFECT. A `measurement` may lower an outcome or raise a fault, but it may
# never make a row `met` — a good rule (xo-score.py, the discard branch), and it
# stays. But it had NO fallback: on a real 106-criterion run the eye cited
# measurements for 8 of 14 drawing checks, ALL EIGHT were discarded to
# `untested`, the other six were unreachable, and the whole look rail then read
# `nothing-checked` — half the review vanished on a coin-flip about which
# evidence word the model happened to name. And the screenshot was on disk the
# whole time: the discard branch deliberately keeps the `shot`.
#
# THE RULING. When a measurement is thrown out, SETTLE THE ROW FROM THE PHOTO IT
# ALREADY HAS instead of discarding it — the rule stays intact (a measurement
# still settles nothing) and half the review stops vanishing.
#
# THE DESIGN, AND THE TRAP IT AVOIDS. The rail is deterministic Python and
# CANNOT look at a photograph, so "settle it from the picture" cannot mean the
# rail judges the image. Nor may the rail INFER a settlement from the shot's
# mere presence, or from prose — "a shot exists, so call it met" would credit a
# row nobody looked at and manufacture the exact false confidence the rule
# exists to prevent (this codebase has lost four sessions to infer-vs-record).
# So the PRODUCER records the judgement: when the eye reaches for a measurement
# on a `looks` row it ALSO looks at the shot and stamps `pictureStatus`
# (`met`/`gap`) — its own picture verdict for that same shot. The rail, on
# discarding the measurement, reads that EXPLICIT field and settles the row from
# the picture (`evidence: picture`). A row where the eye recorded NO picture
# verdict still reads `untested` — the honest "nobody settled it".
#
# THE RISK THIS DESIGN CARRIES is VANISHING, not blind credit: an eye that cites
# a measurement and forgets `pictureStatus` still blacks its row out. It adds NO
# new blind-credit surface — `pictureStatus` is exactly as forgeable as
# `status:met, evidence:picture` already is; a dishonest eye could always have
# cited a picture directly. That is why every case below that lacks an explicit,
# shot-backed picture verdict MUST still read unchecked.
#
# Skill source under test:
#   skills/lcars-xo/xo-score.py     — the discard branch's picture fallback.
#   skills/lcars-xo/prompts/evaluate.md — instructs the eye to stamp it.
#
# ZERO SPEND. No worker, no browser.
#
# Usage: bash tests/lcars-xo-measurement-fallback.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
EVALMD="${LCARS_XO_EVALUATE_MD:-$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# The CONTRACT: one person row and FIVE drawing-part rows, exactly the shape
# xo-parts.py emits — `source: drawing`, so they form the look rail (the
# "Does it look like your drawing?" group), each carrying `drawnAt`.
cat >"$TMPROOT/criteria.json" <<'CJ'
{"hasDrawing": true,
 "placeNames": ["#save", "#view", "#cancel", "#discard", "#preview"],
 "criteria": [
  {"id": "prd-1", "text": "the board shows every open task in one list",
   "source": "prd", "primary": true},
  {"id": "part-save",    "text": "the Save button matches the drawing",
   "source": "drawing", "primary": true, "drawnAt": "#save",    "drawnPart": "#save"},
  {"id": "part-view",    "text": "the View button matches the drawing",
   "source": "drawing", "primary": true, "drawnAt": "#view",    "drawnPart": "#view"},
  {"id": "part-cancel",  "text": "the Cancel button matches the drawing",
   "source": "drawing", "primary": true, "drawnAt": "#cancel",  "drawnPart": "#cancel"},
  {"id": "part-discard", "text": "the Discard button matches the drawing",
   "source": "drawing", "primary": true, "drawnAt": "#discard", "drawnPart": "#discard"},
  {"id": "part-preview", "text": "the Preview button matches the drawing",
   "source": "drawing", "primary": true, "drawnAt": "#preview", "drawnPart": "#preview"}
 ]}
CJ

# part_row <id> <shot> <extra-json> — a worker ledger line for a drawing part,
# rated MET on a MEASUREMENT (the coin-flip evidence word). <extra-json> adds
# whatever the case is testing (e.g. a pictureStatus stamp).
part_row() {
  printf '{"id":"%s","text":"a button matches the drawing","status":"met",' "$1"
  printf '"evidence":"measurement","shot":"%s","note":"the icon sits on the button, amber, as drawn"%s}' "$2" "$3"
}

# verdict <part-rows-joined> — a full worker verdict. The person row is settled
# cleanly on a picture so the HEADLINE group is never the thing under test; the
# drawing group is.
verdict() {
  printf '{"score":"high","summary":"It looks like the drawing.","criteria":['
  printf '{"id":"prd-1","status":"met","evidence":"picture","shot":"shot-00","note":"every open task is in one list"},'
  printf '%s' "$1"
  printf '],"gaps":[],"alsoChecked":[],"escalations":[]}'
}

# score <verdict-body> <outdir>
score() {
  mkdir -p "$2"
  printf '%s\n' "$1" >"$2/in.json"
  "$PY" "$SCOREPY" "$2/in.json" "$TMPROOT/criteria.json" "$2/verdict.json" \
        >"$2/out.tsv" 2>"$2/err.txt"
}

lstatus()   { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"]==sys.argv[2]: print(e.get("status","")); break' "$1" "$2" 2>/dev/null; }
levidence() { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"]==sys.argv[2]: print(e.get("evidence","<none>")); break' "$1" "$2" 2>/dev/null; }
grule()     { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(((d.get("groups",{}) or {}).get("drawing",{}) or {}).get("rule",""))' "$1" 2>/dev/null; }
gchecked()  { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
b=(d.get("groups",{}) or {}).get("drawing",{}) or {}
print(int(b.get("met",0))+int(b.get("gap",0)))' "$1" 2>/dev/null; }

echo
echo "=== lcars xo: measurement blackout falls back to the picture (2026-09-25) ==="
echo

# ==========================================================================
echo "A. THE REAL SHAPE — five drawing parts, all cited as measurements"
# ==========================================================================

# A1. WITH the eye's picture verdict stamped on each: the rail settles them all
# from their pictures, and the look rail STOPS reading nothing-checked. This is
# the whole defect, cured.
score "$(verdict "$(part_row part-save shot-01 ',"pictureStatus":"met"'),$(part_row part-view shot-02 ',"pictureStatus":"met"'),$(part_row part-cancel shot-03 ',"pictureStatus":"met"'),$(part_row part-discard shot-04 ',"pictureStatus":"met"'),$(part_row part-preview shot-05 ',"pictureStatus":"met"')")" \
  "$TMPROOT/a1"
check "A1. the look rail no longer blacks out — its rule is NOT nothing-checked" \
  "[ \"\$(grule '$TMPROOT/a1/verdict.json')\" != nothing-checked ]"
check "A1. …all five drawing parts are actually checked (settled either way)" \
  "[ \"\$(gchecked '$TMPROOT/a1/verdict.json')\" -eq 5 ]"
check "A1. …part-save settled MET" \
  "[ \"\$(lstatus '$TMPROOT/a1/verdict.json' part-save)\" = met ]"
check "A1. …and it names the PICTURE as what settled it, never the measurement" \
  "[ \"\$(levidence '$TMPROOT/a1/verdict.json' part-save)\" = picture ]"
check "A1. …the measurement did NOT stand as the source on any settled part" \
  "! grep -q '\"evidence\": \"measurement\", \"' '$TMPROOT/a1/verdict.json' || true; \
   [ \"\$(levidence '$TMPROOT/a1/verdict.json' part-preview)\" = picture ]"
check "A1. …the record SAYS it fell back to the picture, not to the box" \
  "grep -qi 'settled instead from the eye' '$TMPROOT/a1/out.tsv' '$TMPROOT/a1/verdict.json'"

# ==========================================================================
echo "B. THE RULE IS INTACT — no picture verdict, no settlement"
# ==========================================================================

# B1. THE KNOWN-GOOD CONTROL THAT CANNOT PASS IF THE FIX OVER-CREDITS. The SAME
# five rows, same measurements, same retained shots — but the eye stamped NO
# picture verdict on any of them. Nobody looked; nobody settled. The rail MUST
# still black the whole rail out, exactly as before the fix. If this ever reads
# anything but nothing-checked, the fix is crediting rows blind from the shot's
# mere presence — the trap — and this case is here to catch that.
score "$(verdict "$(part_row part-save shot-01 ''),$(part_row part-view shot-02 ''),$(part_row part-cancel shot-03 ''),$(part_row part-discard shot-04 ''),$(part_row part-preview shot-05 '')")" \
  "$TMPROOT/b1"
check "B1. no picture verdict anywhere → the look rail STILL reads nothing-checked" \
  "[ \"\$(grule '$TMPROOT/b1/verdict.json')\" = nothing-checked ]"
check "B1. …not one part is checked" \
  "[ \"\$(gchecked '$TMPROOT/b1/verdict.json')\" -eq 0 ]"
check "B1. …part-save is untested" \
  "[ \"\$(lstatus '$TMPROOT/b1/verdict.json' part-save)\" = untested ]"
check "B1. …and names no source at all (a measurement settled nothing)" \
  "[ \"\$(levidence '$TMPROOT/b1/verdict.json' part-save)\" = none ]"
check "B1. …the record still says a measurement cannot settle a criterion" \
  "grep -qi 'measurement cannot settle a criterion' '$TMPROOT/b1/verdict.json'"

# B2. A picture verdict with NO shot behind it is not a picture — a measurement
# `met` stamped `pictureStatus:met` but carrying no `shot` must NOT settle. This
# guards the field-existence trap directly: the STAMP alone is not the credit;
# the credit is a stamped verdict AGAINST A NAMED SHOT.
score "$(verdict "$(printf '{"id":"part-save","text":"the Save button matches the drawing","status":"met","evidence":"measurement","pictureStatus":"met","note":"amber, as drawn"}')")" \
  "$TMPROOT/b2"
check "B2. pictureStatus with no shot does NOT settle — the part stays untested" \
  "[ \"\$(lstatus '$TMPROOT/b2/verdict.json' part-save)\" = untested ]"
check "B2. …and it names no source" \
  "[ \"\$(levidence '$TMPROOT/b2/verdict.json' part-save)\" = none ]"

# ==========================================================================
echo "C. A MEASUREMENT STILL NEVER SETTLES — the rule is not weakened"
# ==========================================================================

# C1. A part MET on a measurement ALONE (evidence measurement, a shot, but no
# picture verdict) is the exact case the original rule discards, and it still
# discards. The fix adds a fallback; it does not touch the rule.
score "$(verdict "$(part_row part-save shot-09 '')")" "$TMPROOT/c1"
check "C1. a lone measurement MET, shot but no picture verdict, is still discarded" \
  "[ \"\$(lstatus '$TMPROOT/c1/verdict.json' part-save)\" = untested ]"
check "C1. …recorded with no source, not the measurement" \
  "[ \"\$(levidence '$TMPROOT/c1/verdict.json' part-save)\" = none ]"

# C2. THE IMPOSSIBLE CONTROL. A picture fallback lifts a row to the eye's OWN
# picture verdict — never past it. An eye whose picture verdict is `gap` cannot
# have its row read `met`: the measurement is gone and the picture says fault.
# A check that asserted "met" here could not pass under any honest fix, so its
# passing would mean the harness detects nothing.
score "$(verdict "$(part_row part-save shot-07 ',"pictureStatus":"gap"')")" "$TMPROOT/c2"
check "C2. a picture verdict of gap settles the row a GAP, never met" \
  "[ \"\$(lstatus '$TMPROOT/c2/verdict.json' part-save)\" = gap ]"
check "C2. …the row can never read met when the picture says fault (impossible control)" \
  "[ \"\$(lstatus '$TMPROOT/c2/verdict.json' part-save)\" != met ]"

# ==========================================================================
echo "D. THE EYE IS TOLD TO STAMP IT — the producer records the judgement"
# ==========================================================================

check "D1. evaluate.md tells the eye to record a picture verdict when it measures" \
  "grep -qi 'pictureStatus' '$EVALMD'"
check "D1. …and keeps the rule it never weakens in the same breath" \
  "grep -qi 'may never make a row .met.' '$EVALMD'"

echo
printf 'lcars xo-measurement-fallback: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
