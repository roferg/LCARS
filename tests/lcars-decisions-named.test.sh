#!/usr/bin/env bash
#
# THE CHOICES LCARS MADE FOR HIM, NAMED IN THE REPORT (2026-09-25).
#
# The defect, measured: a Mission was filed whose PRD could not be built without
# making a PRODUCT decision (several tell-apart-able saves, but never ask the
# player to name anything). Research NOTICED — it enumerated the defensible
# options in question 5 — then answered its own question, built three fixed
# slots, and drove to Verify. No gate, no escalation, and NOTHING in the report
# said a choice had been made on the captain's behalf.
#
# The ruling: "Decide, but tell me it decided." It keeps deciding — no gate —
# and the report NAMES every call made on his behalf and the alternatives it
# passed over. Two producers feed one section:
#   1. Research's recorded product decisions        → decisions.json
#   2. The scoring system's OWN assumed-impact call → ledger e.impactAssumed
#
# The design constraint that matters most: RECORD, DO NOT INFER. The report
# reads STRUCTURED FIELDS from decisions.json; it never scans prose to work out
# that a decision was taken. So this suite feeds decisions.json as fields and
# proves the render — it does NOT test any text classifier, because there must
# not be one.
#
# Skill source under test:
#   skills/lcars-xo/xo-score.py  — THE REPORT, rendered here and nowhere else.
#
# ZERO SPEND. No worker, no browser — pure Python over fixture JSON.
#
# Usage: bash tests/lcars-decisions-named.test.sh

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

# A two-item primary contract; both met with a shot so citation guards leave
# them alone and the report renders cleanly.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "the player can save and resume a run", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "saved runs are shown in a list", "source": "prd", "primary": true}
 ]}
C

# row <id> <impact|-> <status> — one ledger row. impact "-" omits impact, so
# take_impact() stamps HIGH and impactAssumed (the scoring system's own call).
row() {
  local id="$1" imp="$2" st="$3"
  local s='"shot": "shot-01", "evidence": "picture",'
  local i=""
  [ "$imp" != "-" ] && i="\"impact\": \"$imp\", \"impactWhy\": \"it is why $id exists\","
  printf '{"id": "%s", %s "status": "%s", %s "note": "saw it", "reason": "Outcome: %s."}' \
    "$id" "$i" "$st" "$s" "$st"
}

# verdict <name> <worker-score> <row>... — write a worker verdict file.
verdict() {
  local name="$1" ws="$2"; shift 2
  local rows="" r
  for r in "$@"; do rows="${rows:+$rows, }$r"; done
  printf '{"score": "%s", "summary": "What I found.", "criteria": [%s], "gaps": []}\n' \
    "$ws" "$rows" >"$TMPROOT/$name.worker.json"
}

# run <name> [decisions.json] — score it with the FULL positional arg set so the
# decisions path lands at argv[12] exactly as xo.sh passes it. Args are passed
# LITERALLY (never through a word-splitting variable — the 2026-09-11 lesson).
run() {
  local name="$1" decisions="${2:-}"
  mkdir -p "$TMPROOT/$name"
  "$PY" "$SCOREPY" \
    "$TMPROOT/$name.worker.json" \
    "$TMPROOT/criteria.json" \
    "$TMPROOT/$name/verdict.json" \
    "" "" "" "" "" "" "" "" \
    "$decisions" \
    >"$TMPROOT/$name/out.txt" 2>"$TMPROOT/$name/err.txt"
}
report() { cat "$TMPROOT/$1/report.md"; }

# ─── Case A: Research recorded product decisions → section names each ────────
cat >"$TMPROOT/decisions.json" <<'D'
{"decisions": [
  {"question": "What metadata lets the player tell their saves apart",
   "options": ["a timestamp on each slot", "the current map name", "an auto-generated run label"],
   "chose": "a timestamp on each slot",
   "why": "it needs no naming step and is unique per save",
   "where": "the save/load menu"},
  {"question": "How many save slots are there",
   "options": ["three fixed slots", "unlimited slots"],
   "chose": "three fixed slots",
   "why": "it bounds the storage and the menu size",
   "where": "the save/load menu"}
]}
D
verdict a high "$(row prd-1 high met)" "$(row prd-2 high met)"
run a "$TMPROOT/decisions.json"

check "A. the report opens the new section" \
  "grep -q '### Choices I made for you' '$TMPROOT/a/report.md'"
check "A. it names the first product decision, verbatim question" \
  "grep -q 'What metadata lets the player tell their saves apart' '$TMPROOT/a/report.md'"
check "A. it names the choice it made" \
  "grep -q 'a timestamp on each slot' '$TMPROOT/a/report.md'"
check "A. it names an ALTERNATIVE it passed over (auto-generated run label)" \
  "grep -q 'auto-generated run label' '$TMPROOT/a/report.md'"
check "A. it names the OTHER alternative it passed over (the current map name)" \
  "grep -q 'the current map name' '$TMPROOT/a/report.md'"
check "A. it names the second decision too (how many save slots)" \
  "grep -q 'How many save slots are there' '$TMPROOT/a/report.md'"
# CONTROL that MUST hold whatever else happens: the report always carries the
# grade line. If this fails the harness itself is broken, not the feature.
check "A. [control] the report still carries the grade line" \
  "grep -q 'How close this is to what you asked for' '$TMPROOT/a/report.md'"

# ─── Case B: no product decisions AND no assumed impact → section ABSENT ─────
# An empty section reads as 'nothing was decided'; that is a DIFFERENT fact from
# 'these were decided'. So when there is nothing, the heading must not appear.
verdict b high "$(row prd-1 high met)" "$(row prd-2 high met)"
run b ""     # no decisions.json path
check "B. with no decisions and no assumed impact, the section is ABSENT" \
  "! grep -q '### Choices I made for you' '$TMPROOT/b/report.md'"
check "B. [control] the report was still produced" \
  "grep -q 'How close this is to what you asked for' '$TMPROOT/b/report.md'"

# ─── Case C: the SCORING system's own call (impactAssumed) → section names it ─
# prd-2 arrives with NO impact ("-"), so take_impact() stamps it high + assumed.
# That is the machine deciding on his behalf too, and it belongs in the SAME
# section even when Research recorded nothing (no decisions.json).
verdict c high "$(row prd-1 high met)" "$(row prd-2 - met)"
run c ""
check "C. an assumed-impact call opens the section with no decisions.json at all" \
  "grep -q '### Choices I made for you' '$TMPROOT/c/report.md'"
check "C. the section names the criterion whose importance was assumed" \
  "grep -q 'how much .* counts.*(prd-2)' '$TMPROOT/c/report.md'"

echo
echo "  decisions-named: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
