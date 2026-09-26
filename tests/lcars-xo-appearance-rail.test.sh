#!/usr/bin/env bash
#
# Tests for APPEARANCE CLAIMS BELONG ON THE LOOK RAIL, NOT THE PERSON RAIL
# (the captain, 2026-09-25).
#
# THE DEFECT, MEASURED (2026-09-24). A mission's DRAWING was restyled — card
# colour, button colour, text colour and corner radius changed — and the BUILD
# WAS NEVER TOUCHED. No part was added, removed or renamed, so every drawn part
# still paired (3/3). The drawing rail did its job: it dropped HIGH 3/3 ->
# MEDIUM 2/3 and `measuredDifferences` went 0 -> 2. But the PERSON rail — "Can a
# person do what it promises?" — fell from 100% (7/7) to 57% (4/7). The build
# never changed, so nothing about what a person can DO could have got worse. The
# only cause: appearance claims were being graded on the person rail, so
# restyling the drawing made the FUNCTIONAL rail start demanding the new colours.
#
# THE RULING. An appearance claim belongs on the LOOK (drawing) rail. An
# appearance claim is one BOTH producers declared to be settled by comparing the
# built screen to the DRAWING — it takes both, because neither alone means
# "appearance": a DRAWN requirement can be functional ("the board shows every
# open task" is drawn yet a person promise), and a LOOKS-question can be a
# person promise with no drawing tie ("the header shows the app name" is settled
# by a photo yet is graded on the person rail). Only a criterion declared drawn
# (`drawnAt`, at derivation) AND stamped a `looks`-question (by the eye) is
# "does the built appearance match the drawn appearance", and only that is
# lifted off the person rail onto the drawing rail. The headline (the person
# rail) is then unmoved by a difference that is only about how the thing looks.
#
# RECORD, DO NOT INFER — the seam this codebase has lost sessions to. Nothing
# here reads a criterion's ENGLISH (colour words, "looks like", style
# vocabulary) to decide it is an appearance claim. TWO PRODUCER STAMPS decide
# it: `drawnAt` (declared where the per-part requirement is derived from the
# drawing) and the eye's `kind: looks` (stamped beside its verdict as it judges,
# prompts/evaluate.md). The grouping READS those stamps and nothing else.
#
# Skill source under test:
#   skills/lcars-xo/xo-score.py — group_of() lifts a claim declared drawn
#                                 (`drawnAt`) AND judged a `looks`-question off
#                                 the person rail onto the drawing rail.
#
# ZERO SPEND. No worker, no browser.
#
# Usage: bash tests/lcars-xo-appearance-rail.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# THE CONTRACT — written before a pixel is seen. Genuine functional
# requirements (source prd + journey, "can a person do what it promises"), one
# APPEARANCE claim, and two DECISIVE CONTROLS proving neither producer signal
# ALONE reroutes a row:
#   prd-1      functional (works), NOT drawn          -> person
#   journey-1  functional (works), NOT drawn          -> person
#   prd-2      looks-question AND drawnAt (appearance) -> drawing   [the defect]
#   prd-3      functional (works) AND drawnAt          -> person    [drawn-but-
#              functional: a drawn requirement that is NOT an appearance claim,
#              the "board shows every open task" class — drawnAt ALONE must not
#              move it]
#   prd-4      looks-question, NOT drawn               -> person    [a person
#              promise settled by a photo, the "header shows the app name"
#              class — kind:looks ALONE must not move it]
# A drawing exists, so the look rail is a real rail.
cat >"$TMPROOT/criteria.json" <<'CJ'
{"hasDrawing": true,
 "placeNames": ["#save", "#header", "#board"],
 "criteria": [
  {"id": "prd-1",     "text": "Save persists the item across a restart",
   "source": "prd", "primary": true},
  {"id": "journey-1", "text": "Walking the flow: open the board — it opens.",
   "source": "journey", "primary": true},
  {"id": "prd-2",     "text": "the header shows the title in the brand colour",
   "source": "prd", "primary": true, "drawnAt": "#header"},
  {"id": "prd-3",     "text": "the board shows every open task in one list",
   "source": "prd", "primary": true, "drawnAt": "#board"},
  {"id": "prd-4",     "text": "the header shows the app name",
   "source": "prd", "primary": true}
 ]}
CJ

# A worker row. <id> <status> <kind> <extra-json>. Every row cites a shot, so no
# row is thrown out for a missing picture. A works-row also carries an `action`,
# so a met works-question is EXERCISED and not downgraded for resting on a photo.
functional_met() {  # <id>
  printf '{"id":"%s","status":"met","evidence":"picture","shot":"shot-%s",' "$1" "$1"
  printf '"kind":"works","action":"performed the action and saw it take effect",' 
  printf '"note":"it did what it promises"}'
}
functional_gap() {  # <id>
  printf '{"id":"%s","status":"gap","evidence":"picture","shot":"shot-%s",' "$1" "$1"
  printf '"kind":"works","action":"performed the action; it did NOT take effect",'
  printf '"impact":"high","note":"the build does not do this"}'
}
looks_met() {  # <id>
  printf '{"id":"%s","status":"met","evidence":"picture","shot":"shot-%s",' "$1" "$1"
  printf '"kind":"looks","note":"it looks as drawn"}'
}
looks_gap() {  # <id>
  printf '{"id":"%s","status":"gap","evidence":"picture","shot":"shot-%s",' "$1" "$1"
  printf '"kind":"looks","impact":"high","note":"the colour is not as drawn"}'
}

# verdict <criteria-rows-joined> -> a full worker verdict.
verdict() {
  printf '{"score":"high","summary":"a run.","criteria":[%s],' "$1"
  printf '"gaps":[],"alsoChecked":[],"escalations":[]}'
}

# score <verdict-body> <outdir>
score() {
  mkdir -p "$2"
  printf '%s\n' "$1" >"$2/in.json"
  "$PY" "$SCOREPY" "$2/in.json" "$TMPROOT/criteria.json" "$2/verdict.json" \
        >"$2/out.tsv" 2>"$2/err.txt"
}

# READERS — arguments passed LITERALLY at each call site, never via a variable.
lgroup()   { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"]==sys.argv[2]: print(e.get("group","<none>")); break
else: print("<absent>")' "$1" "$2" 2>/dev/null; }
headline() { "$PY" -c 'import json,sys
print(json.load(open(sys.argv[1])).get("score","<none>"))' "$1" 2>/dev/null; }
ggrade()   { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(((d.get("groups",{}) or {}).get(sys.argv[2],{}) or {}).get("grade","<none>"))' "$1" "$2" 2>/dev/null; }
gtotal()   { "$PY" -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(((d.get("groups",{}) or {}).get(sys.argv[2],{}) or {}).get("total",-1))' "$1" "$2" 2>/dev/null; }

# ── THREE VERDICTS, ALL ON THE SAME UNCHANGED CONTRACT ──────────────────────
# Every run keeps prd-3 (drawn functional) and prd-4 (undrawn looks) MET, so any
# movement is attributable to the one row that changes.
# BASELINE  — everything works and everything looks right.
score "$(verdict "$(functional_met prd-1),$(functional_met journey-1),$(looks_met prd-2),$(functional_met prd-3),$(looks_met prd-4)")" \
  "$TMPROOT/base"
# RESTYLED  — the BUILD is identical (every functional row still met); ONLY the
#             appearance claim now differs, exactly as restyling the drawing did.
score "$(verdict "$(functional_met prd-1),$(functional_met journey-1),$(looks_gap prd-2),$(functional_met prd-3),$(looks_met prd-4)")" \
  "$TMPROOT/restyle"
# BROKEN    — a genuine FUNCTIONAL failure: Save no longer persists. Looks fine.
score "$(verdict "$(functional_gap prd-1),$(functional_met journey-1),$(looks_met prd-2),$(functional_met prd-3),$(looks_met prd-4)")" \
  "$TMPROOT/broken"

echo
echo "=== lcars xo: an appearance claim is graded on the look rail (2026-09-25) ==="
echo

# ==========================================================================
echo "PRE-FLIGHT — the readers work, and the fixture is the shape it claims"
# ==========================================================================
check "P0. the scorer ran on the restyle verdict (no crash)" \
  "[ -s '$TMPROOT/restyle/verdict.json' ]"
# A KNOWN-GOOD CONTROL FOR THE lgroup READER ITSELF: a functional prd row is on
# the person rail. If this ever fails, the reader is broken and nothing below
# can be trusted.
check "P1. lgroup reads a real group (prd-1 is on the person rail)" \
  "[ \"\$(lgroup '$TMPROOT/base/verdict.json' prd-1)\" = person ]"

# ==========================================================================
echo "(a) THE APPEARANCE CLAIM IS GRADED ON THE DRAWING RAIL"
# ==========================================================================
check "a1. the looks-question prd-2 lands on the drawing rail, not person" \
  "[ \"\$(lgroup '$TMPROOT/restyle/verdict.json' prd-2)\" = drawing ]"
# KNOWN-GOOD CONTROLS — the two genuine functional rows STAY on the person rail.
# Without these, a1 could pass simply by shovelling everything to drawing.
check "a2. CONTROL — the functional prd-1 stays on the person rail" \
  "[ \"\$(lgroup '$TMPROOT/restyle/verdict.json' prd-1)\" = person ]"
check "a3. CONTROL — the functional journey-1 stays on the person rail" \
  "[ \"\$(lgroup '$TMPROOT/restyle/verdict.json' journey-1)\" = person ]"
check "a4. the drawing rail actually caught the appearance fault (its grade is not HIGH)" \
  "[ \"\$(ggrade '$TMPROOT/restyle/verdict.json' drawing)\" != high ]"
# THE CONJUNCTION, PROVEN — neither producer signal ALONE reroutes a row. These
# two controls are the guard against hollowing the person rail with a blanket
# rule (which regresses the coverage-floor and headline rulings the evidence
# suite pins down).
check "a5. CONTROL — a DRAWN but FUNCTIONAL row (prd-3, drawnAt + works) STAYS on person" \
  "[ \"\$(lgroup '$TMPROOT/restyle/verdict.json' prd-3)\" = person ]"
check "a6. CONTROL — a LOOKS row with NO drawing tie (prd-4, looks + no drawnAt) STAYS on person" \
  "[ \"\$(lgroup '$TMPROOT/restyle/verdict.json' prd-4)\" = person ]"

# ==========================================================================
echo "(b) THE PERSON RAIL IS UNMOVED BY AN APPEARANCE-ONLY DIFFERENCE"
# ==========================================================================
check "b1. baseline headline is HIGH" \
  "[ \"\$(headline '$TMPROOT/base/verdict.json')\" = high ]"
check "b2. restyle headline is STILL HIGH — the build never changed" \
  "[ \"\$(headline '$TMPROOT/restyle/verdict.json')\" = high ]"
check "b3. the person rail's own grade is unmoved (HIGH both runs)" \
  "[ \"\$(ggrade '$TMPROOT/base/verdict.json' person)\" = \"\$(ggrade '$TMPROOT/restyle/verdict.json' person)\" ] && \
   [ \"\$(ggrade '$TMPROOT/base/verdict.json' person)\" = high ]"
# KNOWN-GOOD CONTROL — the difference was REAL and the look rail DID move. If the
# drawing grade were identical too, b2/b3 would prove nothing (the run could be
# blind to the restyle entirely).
check "b4. CONTROL — the drawing rail DID move between the two runs" \
  "[ \"\$(ggrade '$TMPROOT/base/verdict.json' drawing)\" != \"\$(ggrade '$TMPROOT/restyle/verdict.json' drawing)\" ]"
# The person rail must NOT have been quietly emptied — the functional rows are
# still on it. A rail hollowed to zero rows would also read "unmoved".
check "b5. the person rail still carries its functional rows (4 of them)" \
  "[ \"\$(gtotal '$TMPROOT/base/verdict.json' person)\" -eq 4 ] && \
   [ \"\$(gtotal '$TMPROOT/restyle/verdict.json' person)\" -eq 4 ]"

# ==========================================================================
echo "(c) A GENUINE FUNCTIONAL FAILURE STILL LANDS ON PERSON AND MOVES THE HEADLINE"
#     — THIS is the control that proves the person rail was not merely hollowed
#       out. If it fails, everything above is a fix that detects nothing.
# ==========================================================================
check "c1. the broken functional prd-1 is on the person rail" \
  "[ \"\$(lgroup '$TMPROOT/broken/verdict.json' prd-1)\" = person ]"
check "c2. the functional failure MOVED the headline off HIGH" \
  "[ \"\$(headline '$TMPROOT/broken/verdict.json')\" != high ]"
# THE DECISIVE CONTRAST — an appearance-only gap keeps the headline HIGH (b2),
# a functional gap does not (c2). Same contract, same reader; only the KIND of
# the failing row differs. This is the whole ruling, in one line.
check "c3. CONTRAST — appearance-gap headline (HIGH) differs from functional-gap headline" \
  "[ \"\$(headline '$TMPROOT/restyle/verdict.json')\" != \"\$(headline '$TMPROOT/broken/verdict.json')\" ]"

echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
