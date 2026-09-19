#!/usr/bin/env bash
#
# Tests for "A PICTURE IS NOT A DRAWING" (Session 217, part A).
#
# MEASURED (S214/S215): a mission whose only design is a PNG gets
# hasDrawing false, placeNames 0 and no drawnAt — the drawing comparison
# silently never runs, and verify_unfenced_note cannot fire because it only
# speaks when a readable mockup exists. The picture fell through both guards.
#
# WHY THE CURE IS ON THE VERIFY SIDE, NOT AT FILING. Nothing on disk records
# "this image is THE design" as distinct from "this image is context": the
# holodeck hand-off rides `--attach` exactly like a pasted screenshot, and it
# always carries an .html (the daemon refuses a hand-off without one). Guessing
# the difference from a filename or the prose would be the infer-vs-record
# class this codebase has lost four rounds to. So filing is untouched, and
# Number One SAYS, in the verdict the card and the report both read, that the
# attachment is a picture and nothing was checked against a drawing.
#
# Skill source under test:
#   skills/lcars-xo/xo-criteria.py — records `pictures`, the image attachments.
#   skills/lcars-xo/xo-score.py    — leads the derivation (the card's line) and
#                                    the report with the plain sentence.
#
# ZERO SPEND. No worker, no browser.
#
# Usage: bash tests/lcars-xo-picture.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

SENTENCE="your attachment is a picture, so I could not check the build against a drawing"

# plant <name> <attachment...> — a mission dir with a PRD and the named
# attachments (an .html one carries a real id).
plant() {
  local m="$TMPROOT/$1"; shift
  mkdir -p "$m"
  printf '# T\n\n## Acceptance criteria\n- the list shows every task\n' >"$m/prd.md"
  if [ "$#" -gt 0 ]; then
    mkdir -p "$m/attachments"
    local a
    for a in "$@"; do
      case "$a" in
        *.html) printf '<div id="task-list">x</div>' >"$m/attachments/$a" ;;
        *)      printf 'PNGDATA' >"$m/attachments/$a" ;;
      esac
    done
  fi
  printf '%s' "$m"
}

cat >"$TMPROOT/worker.json" <<'WV'
{"score": "high", "summary": "The list is there.",
 "criteria": [{"id": "prd-1", "status": "met", "shot": "shot-01", "evidence": "picture", "note": "saw the list"}],
 "gaps": []}
WV

# score <mission-dir> — criteria.json then verdict.json + report.md in <m>/xo.
score() {
  mkdir -p "$1/xo"
  "$PY" "$CRITERIA" "$1" "$1/xo/criteria.json" >/dev/null
  "$PY" "$SCOREPY" "$TMPROOT/worker.json" "$1/xo/criteria.json" "$1/xo/verdict.json" \
    >"$1/xo/stdout.txt" 2>"$1/xo/stderr.txt"
}
derivation() { "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["derivation"])' "$1/xo/verdict.json"; }

echo "A1. a mission whose only design is a PNG"
m1="$(plant png-only attachment-01.png)"
score "$m1"
check "A1. criteria.json records the picture it was handed (a fact, not a guess)" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"pictures\"]==[\"attachment-01.png\"] and d[\"hasDrawing\"] is False else 1)' '$m1/xo/criteria.json'"
check "A1. the verdict's one line (the card's line) LEADS with the plain sentence" \
  "derivation '$m1' | grep -q '^$SENTENCE\\. '"
check "A1. …and the WHY the finisher records as the card headline carries it too" \
  "grep -q \"^WHY.$SENTENCE\" '$m1/xo/stdout.txt'"
check "A1. the report says it, and says how to get a drawing: an .html mock-up whose ids name the parts, a concept.md, the holodeck" \
  "grep -q '$SENTENCE' '$m1/xo/report.md' && grep -q 'attachment-01.png' '$m1/xo/report.md' \
   && grep -q '\\.html' '$m1/xo/report.md' && grep -q 'concept\\.md' '$m1/xo/report.md' \
   && grep -qi 'holodeck' '$m1/xo/report.md'"
check "A1. the verdict records the fact in its own field, not only in prose" \
  "$PY -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get(\"pictureNotDrawing\",{}).get(\"pictures\")==[\"attachment-01.png\"] else 1)' '$m1/xo/verdict.json'"
check "A1. the SCORE is not moved by it — the ledger still decides (HIGH here)" \
  "grep -q '^SCORE.high' '$m1/xo/stdout.txt'"

echo "A2. a PNG as context beside a real .html mock-up"
m2="$(plant png-and-mock attachment-01.png attachment-02.html)"
score "$m2"
check "A2. hasDrawing is TRUE — the mock-up is the drawing" \
  "grep -q '\"hasDrawing\": true' '$m2/xo/criteria.json'"
check "A2. …and nothing says 'picture' — the screenshot is just context" \
  "! grep -q 'is a picture' '$m2/xo/verdict.json' && ! grep -q 'is a picture' '$m2/xo/report.md'"

echo "A3. a mission with no attachments at all"
m3="$(plant nothing)"
score "$m3"
check "A3. no picture, no sentence — the derivation is the ledger's own, unchanged" \
  "[ \"\$(derivation '$m3')\" = 'everything you asked for is in the build, and I have a picture of each one.' ]"
check "A3. no pictureNotDrawing field at all" \
  "! grep -q 'pictureNotDrawing' '$m3/xo/verdict.json'"
check "A3. the recorded pictures list is empty" \
  "$PY -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"pictures\"]==[] else 1)' '$m3/xo/criteria.json'"

echo "A4. a written document alone is not a picture"
m4="$(plant doc-only attachment-01.md)"
score "$m4"
check "A4. a concept.md with no mock-up draws no picture sentence" \
  "! grep -q 'is a picture' '$m4/xo/verdict.json'"

echo
printf 'lcars xo-picture: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
