#!/usr/bin/env bash
#
# S226 fix — MODEL-FACING STAGE PROMPTS MUST NOT DESCRIBE IMPLEMENT AS AN
# ADVERSARIAL TEST-WRITER/IMPLEMENTER PAIR.
#
# The adversarial Test-Writer + Implementer split was RETIRED (PR #82) in favour
# of ONE unified TDD worker per ticket, proven by deterministic post-hoc gates
# (flip-flop, declared-edits, quality floor); a gate rejection bounces to a fresh
# worker up to 3 sessions, then parks awaiting-human.
#
# But `stages/estimate.md` still told the estimating model:
#
#   "**implement** runs, per ticket, an adversarial **Test-Writer + Implementer**
#    pair, each able to retry up to the attempt cap (5)."
#
# The model believed it and repeated it verbatim into the estimate the captain
# reads ("driven by adversarial test-writer/implementer pairs"). A stage prompt
# is fed straight into a model; a false claim there becomes a false claim shown
# to the captain. This is the S179 defect class.
#
# This suite pins the fix: NO model-facing stage prompt under
# skills/lcars-run/stages/ may describe Implement as "adversarial", nor name a
# Test-Writer/Implementer PAIR (the two coupled by +, /, →, or "and").
#
# Pure text scan — no model, no network, no tokens.
#
# Usage: bash tests/stage-prompt-hygiene.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGES_DIR="$HERE/../skills/lcars-run/stages"

pass=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

printf 'stage-prompt-hygiene: model-facing stage prompts describe the CURRENT Implement design\n'

[ -d "$STAGES_DIR" ] || { bad "stages dir exists ($STAGES_DIR)"; echo; exit 1; }

# 1. The word "adversarial" has no place in a current-design stage prompt: the
#    only thing it ever described was the retired split.
hits="$(grep -rniE 'adversarial' "$STAGES_DIR" || true)"
if [ -z "$hits" ]; then
  ok 'no stage prompt calls Implement "adversarial"'
else
  bad 'a stage prompt still says "adversarial":'
  printf '%s\n' "$hits" | sed 's/^/       /'
fi

# 2. No stage prompt names a Test-Writer/Implementer PAIR — the two roles coupled
#    by a separator (+, /, →, -, or the word "and"). The standalone noun
#    "Implementer" (naming the single worker) is fine; a COUPLED pair is the
#    retired split.
pair='test.?writer[[:space:]]*(\+|/|→|-|and)[[:space:]]*implementer|implementer[[:space:]]*(\+|/|→|-|and)[[:space:]]*test.?writer'
hits="$(grep -rniE "$pair" "$STAGES_DIR" || true)"
if [ -z "$hits" ]; then
  ok 'no stage prompt names a Test-Writer/Implementer pair'
else
  bad 'a stage prompt still names a Test-Writer/Implementer pair:'
  printf '%s\n' "$hits" | sed 's/^/       /'
fi

# 3. The estimate prompt POSITIVELY describes the current machinery — a unified
#    worker whose work is proven by post-hoc gates. Guards against a "delete the
#    lie, leave a vacuum" regression that says nothing true in its place.
est="$STAGES_DIR/estimate.md"
if grep -qiE 'unified' "$est" && grep -qiE 'gate' "$est"; then
  ok 'estimate.md describes the unified worker proven by gates'
else
  bad 'estimate.md does not describe the unified worker + post-hoc gates'
fi

echo
printf 'stage-prompt-hygiene: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
