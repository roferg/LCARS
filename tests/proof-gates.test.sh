#!/usr/bin/env bash
# Fast, SCOPED test for the S132 PROOF-OF-WORK gates — STANDALONE (no live
# implement path calls these yet; the path flips in S133).
#
# The unified-TDD-worker design moves proof AFTER implementation: the PARENT
# commit is the snapshot (git), and fail-on-parent / pass-on-tip is the proof.
# Three deterministic post-hoc gates + one validator are exercised here via
# inert test hooks (house style: worker-empty-detect-test, slice-pressure-test):
#
#   flip_flop_gate <ticket> <parent-sha> <worktree>
#       TIP leg: scoped run of the ticket's new/changed tests must be GREEN.
#       PARENT leg: scratch worktree at <parent-sha>, SAME tests staged in,
#       scoped run must be RED (a compile/resolution red from the change's new
#       symbols COUNTS, kind recorded). ZERO tests collected on either leg =
#       INCONCLUSIVE, never a pass (the S85/S106 green-on-nothing trap).
#       Artifacts: tickets/<id>/flip-flop.json + flip_flop_pass/fail/
#       inconclusive/skipped events. Scratch worktree pruned on EVERY path.
#   declared_edits_guard <ticket> <parent-sha> <worktree>
#       test-classified diff paths minus result.json newTests ∪ testEdits[].path
#       must be EMPTY (deletions count). Declared → tickets/<id>/test-edits.json
#       + a ticket_test_edits event.
#   proof_validate_result <result-file> <ticket>
#       result.json v2 shape; v1 REJECTS legibly naming the missing keys.
#   proof_quality_floor <ticket> <parent-sha> <worktree>
#       suite_has_assertions over the new/changed tests in-tree; ≥1 new/changed
#       test required unless flipFlop=not-applicable (then waived).
#
# Zero tokens: real git + real node/go/cargo runners on tiny fixtures (rust/go
# skip-with-notice when the runner is absent). NOT the heavy lcars-run.test.sh.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

NODE_CMD='node --test $LCARS_TESTS_DIR'

# --- fixture builders -------------------------------------------------------
scaffold_mission() { # repo
  mkdir -p "$1/.git/lcars/missions/m-001/tickets/t-001"
  printf '{ "id":"m-001","type":"feature","title":"t","stage":"implement" }\n' \
    > "$1/.git/lcars/missions/m-001/state.json"
}

new_js_repo() { # → echoes repo dir; parent commit = package.json + src/calc.js (add only)
  local repo; repo="$(mktemp -d "$TMPROOT/js.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '{ "name": "fix", "private": true }\n' > "$repo/package.json"
  mkdir -p "$repo/src"
  printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  echo "$repo"
}

head_sha() { ( cd "$1" && git rev-parse HEAD ); }

commit_all() { ( cd "$1" && git add -A && git commit -qm tip ); }

write_honest_js_tip() { # repo — new co-located test + the impl it needs
  cat > "$1/src/calc.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { mul } = require('./calc.js');
test('mul multiplies', () => { assert.strictEqual(mul(2, 3), 6); });
JS
  printf 'exports.add = (a, b) => a + b;\nexports.mul = (a, b) => a * b;\n' > "$1/src/calc.js"
  commit_all "$1"
}

write_cheat_js_tip() { # repo — test asserts PARENT behavior (green on both legs)
  cat > "$1/src/calc.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('./calc.js');
test('add adds', () => { assert.strictEqual(add(2, 2), 4); });
JS
  commit_all "$1"
}

write_result() { # dir newTests-json testEdits-json flipFlop [reason]
  local extra=""
  [ -n "${5:-}" ] && extra=", \"flipFlopReason\": \"$5\""
  cat > "$1/result.json" <<JSON
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": $2, "testEdits": $3, "flipFlop": "$4"$extra }
JSON
}

TD() { echo "$1/.git/lcars/missions/m-001/tickets/t-001"; }
EV() { echo "$1/.git/lcars/missions/m-001/events.jsonl"; }

ff_gate() { # repo parent-sha [env-pairs...] → sets FFRC + OUT
  local repo="$1" parent="$2"; shift 2
  OUT="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git "$@" \
          bash "$SCRIPT" flip-flop-gate-test --mission m-001 --ticket t-001 --sha "$parent" 2>&1 )"
  FFRC="$(printf '%s\n' "$OUT" | sed -n 's/^FFRC=//p' | tail -1)"
}
de_guard() { # repo parent-sha → sets DERC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" declared-edits-guard-test --mission m-001 --ticket t-001 --sha "$2" 2>&1 )"
  DERC="$(printf '%s\n' "$OUT" | sed -n 's/^DERC=//p' | tail -1)"
}
q_floor() { # repo parent-sha → sets QFRC + OUT
  OUT="$( cd "$1" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" proof-quality-floor-test --mission m-001 --ticket t-001 --sha "$2" 2>&1 )"
  QFRC="$(printf '%s\n' "$OUT" | sed -n 's/^QFRC=//p' | tail -1)"
}
pv_result() { # result-file → sets PVRC + OUT
  OUT="$( env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" proof-validate-result-test --ticket t-001 --result "$1" 2>&1 )"
  PVRC="$(printf '%s\n' "$OUT" | sed -n 's/^PVRC=//p' | tail -1)"
}

no_scratch_left() { # repo → 0 if the parent scratch worktree is fully pruned
  [ ! -e "$1/.git/lcars/missions/m-001/proof-worktrees/t-001-parent" ] \
    && ! ( cd "$1" && git worktree list 2>/dev/null | grep -q 'proof-worktrees' )
}

# ==========================================================================
# A. result.json v2 validation (behavior 7)
# ==========================================================================
echo "== A. result.json v2 validation =="
rd="$(mktemp -d "$TMPROOT/res.XXXX")"

cat > "$rd/v1.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s" }
JSON
pv_result "$rd/v1.json"
[ "$PVRC" = 1 ] && ok "A1a. v1 result REJECTED (rc 1)" \
                || bad "A1a. v1 result should reject (PVRC=$PVRC: $OUT)"
if printf '%s' "$OUT" | grep -q 'newTests' && printf '%s' "$OUT" | grep -q 'testEdits' \
   && printf '%s' "$OUT" | grep -q 'flipFlop'; then
  ok "A1b. rejection NAMES the missing v2 keys"
else
  bad "A1b. rejection should name newTests/testEdits/flipFlop (got: $OUT)"
fi

cat > "$rd/v2.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 2, "summary": "s",
  "newTests": ["src/calc.test.js"],
  "testEdits": [{ "path": "src/other.test.js", "reason": "updated import" }],
  "flipFlop": "expected" }
JSON
pv_result "$rd/v2.json"
[ "$PVRC" = 0 ] && ok "A2. valid v2 result ACCEPTED" \
                || bad "A2. valid v2 should accept (PVRC=$PVRC: $OUT)"

cat > "$rd/na-noreason.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": [], "testEdits": [], "flipFlop": "not-applicable" }
JSON
pv_result "$rd/na-noreason.json"
if [ "$PVRC" = 1 ] && printf '%s' "$OUT" | grep -q 'flipFlopReason'; then
  ok "A3. not-applicable WITHOUT flipFlopReason rejects, naming the field"
else
  bad "A3. not-applicable without reason should reject (PVRC=$PVRC: $OUT)"
fi

cat > "$rd/bogus-ff.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": [], "testEdits": [], "flipFlop": "maybe" }
JSON
pv_result "$rd/bogus-ff.json"
[ "$PVRC" = 1 ] && ok "A4. flipFlop outside expected|not-applicable rejects" \
                || bad "A4. bogus flipFlop should reject (PVRC=$PVRC)"

# S133: the internal-attempts cap is RETIRED — attempts is the worker's own
# honest iteration count, informational and uncapped (the enforced cap is the
# 3-session gate-bounce loop). attempts 6 must now be ACCEPTED; 0 still rejects.
cat > "$rd/overcap.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 6, "summary": "s",
  "newTests": [], "testEdits": [], "flipFlop": "expected" }
JSON
pv_result "$rd/overcap.json"
[ "$PVRC" = 0 ] && ok "A5a. attempts above the old 5 cap ACCEPTED (uncapped-but-reported, S133)" \
                || bad "A5a. attempts 6 should accept now (PVRC=$PVRC: $OUT)"
cat > "$rd/zeroattempts.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 0, "summary": "s",
  "newTests": [], "testEdits": [], "flipFlop": "expected" }
JSON
pv_result "$rd/zeroattempts.json"
[ "$PVRC" = 1 ] && ok "A5b. attempts 0 still rejects" \
                || bad "A5b. attempts 0 should reject (PVRC=$PVRC)"

cat > "$rd/badedit.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": [], "testEdits": [{ "path": "src/other.test.js" }], "flipFlop": "expected" }
JSON
pv_result "$rd/badedit.json"
[ "$PVRC" = 1 ] && ok "A6. testEdits entry without a reason rejects" \
                || bad "A6. reason-less testEdits entry should reject (PVRC=$PVRC)"

# ==========================================================================
# B. honest ticket → flip-flop PASS (behavior 1) + prune (behavior 9)
# ==========================================================================
echo "== B. honest ticket (js) =="
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 0 ] && ok "B1. honest ticket → flip-flop PASS (rc 0)" \
                || bad "B1. honest ticket should pass (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
if [ -f "$ffj" ] && grep -q '"verdict": "pass"' "$ffj"; then
  ok "B2a. flip-flop.json records verdict pass"
else
  bad "B2a. flip-flop.json missing / wrong verdict ($(cat "$ffj" 2>/dev/null))"
fi
grep -q 'src/calc.test.js' "$ffj" 2>/dev/null \
  && ok "B2b. flip-flop.json names the ticket's test file" \
  || bad "B2b. flip-flop.json should list src/calc.test.js"
grep -q '"type":"flip_flop_pass"' "$(EV "$repo")" 2>/dev/null \
  && ok "B3. flip_flop_pass event emitted" \
  || bad "B3. flip_flop_pass event missing from events.jsonl"
no_scratch_left "$repo" \
  && ok "B4. parent scratch worktree pruned after PASS" \
  || bad "B4. scratch worktree leaked after pass"

# ==========================================================================
# C. test-after cheat → FAIL (behavior 2) + prune on failure (behavior 9)
# ==========================================================================
echo "== C. test-after cheat (green on both legs) =="
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_cheat_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 1 ] && ok "C1. cheat ticket → flip-flop FAIL (rc 1)" \
                || bad "C1. cheat should fail (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
grep -q '"verdict": "fail"' "$ffj" 2>/dev/null \
  && ok "C2. flip-flop.json records verdict fail" \
  || bad "C2. flip-flop.json should record fail"
grep -q '"type":"flip_flop_fail"' "$(EV "$repo")" 2>/dev/null \
  && ok "C3. flip_flop_fail event emitted" \
  || bad "C3. flip_flop_fail event missing"
no_scratch_left "$repo" \
  && ok "C4. parent scratch worktree pruned after FAIL" \
  || bad "C4. scratch worktree leaked after fail"

# ==========================================================================
# D. zero-collected → INCONCLUSIVE, never a pass (behavior 4)
# ==========================================================================
echo "== D. zero-collected legs =="
# D1: parent leg collects zero (the go no-match shape, driven deterministically:
# the tip-only untracked marker makes the SAME cmd run real tests on tip but
# report the runner's own zero-tests phrase on the parent scratch).
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
: > "$repo/tip-marker"
ZCMD='if [ -f tip-marker ]; then node --test $LCARS_TESTS_DIR; else echo "no tests to run"; fi'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$ZCMD"
[ "$FFRC" = 2 ] && ok "D1a. zero-collected on PARENT → INCONCLUSIVE (rc 2)" \
                || bad "D1a. parent zero-collect should be inconclusive (FFRC=$FFRC: $OUT)"
grep -q '"verdict": "inconclusive"' "$(TD "$repo")/flip-flop.json" 2>/dev/null \
  && ok "D1b. flip-flop.json records inconclusive" \
  || bad "D1b. flip-flop.json should record inconclusive"
grep -q '"type":"flip_flop_inconclusive"' "$(EV "$repo")" 2>/dev/null \
  && ok "D1c. flip_flop_inconclusive event emitted" \
  || bad "D1c. flip_flop_inconclusive event missing"
no_scratch_left "$repo" \
  && ok "D1d. scratch pruned on the inconclusive path" \
  || bad "D1d. scratch worktree leaked on inconclusive"

# D2: tip leg collects zero (vitest's own phrase) → inconclusive, never a pass.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD='echo "No test files found"'
[ "$FFRC" = 2 ] && ok "D2. zero-collected on TIP → INCONCLUSIVE (rc 2)" \
                || bad "D2. tip zero-collect should be inconclusive (FFRC=$FFRC: $OUT)"

# ==========================================================================
# E/F. native stacks: a test that can't COMPILE on parent is PROOF (behavior 3)
# ==========================================================================
echo "== E. go: compile-red on parent counts, kind recorded =="
if ! have go; then
  skip "GO: go not installed — SKIPPING the go compile-on-parent proof LOUDLY"
else
  repo="$(mktemp -d "$TMPROOT/go.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf 'module fix\n\ngo 1.21\n' > "$repo/go.mod"
  printf 'package fix\n\nfunc Add(a, b int) int { return a + b }\n' > "$repo/math.go"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  P="$(head_sha "$repo")"
  cat > "$repo/mul_test.go" <<'GO'
package fix

import "testing"

func TestMul(t *testing.T) {
	if Mul(2, 3) != 6 {
		t.Fatal("mul is wrong")
	}
}
GO
  printf 'package fix\n\nfunc Mul(a, b int) int { return a * b }\n' > "$repo/mul.go"
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=go
  [ "$FFRC" = 0 ] && ok "E1. go ticket whose test can't compile on parent → PASS" \
                  || bad "E1. go compile-red should pass (FFRC=$FFRC: $OUT)"
  grep -q '"kind": "compile-failure"' "$(TD "$repo")/flip-flop.json" 2>/dev/null \
    && ok "E2. parent-leg kind recorded as compile-failure" \
    || bad "E2. expected compile-failure kind ($(cat "$(TD "$repo")/flip-flop.json" 2>/dev/null))"
  grep -q '"type":"flip_flop_pass"' "$(EV "$repo")" 2>/dev/null \
    && ok "E3. flip_flop_pass event emitted for the go ticket" \
    || bad "E3. flip_flop_pass event missing (go)"
  no_scratch_left "$repo" \
    && ok "E4. go scratch worktree pruned" \
    || bad "E4. go scratch worktree leaked"
fi

echo "== F. rust: compile-red on parent counts, kind recorded =="
if ! have cargo; then
  skip "RUST: cargo not installed — SKIPPING the rust compile-on-parent proof LOUDLY"
else
  repo="$(mktemp -d "$TMPROOT/rs.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '[package]\nname = "fix"\nversion = "0.1.0"\nedition = "2021"\n' > "$repo/Cargo.toml"
  mkdir -p "$repo/src"
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$repo/src/lib.rs"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  P="$(head_sha "$repo")"
  mkdir -p "$repo/tests"
  cat > "$repo/tests/mul.rs" <<'RS'
#[test]
fn mul_multiplies() { assert_eq!(fix::mul(2, 3), 6); }
RS
  printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\npub fn mul(a: i32, b: i32) -> i32 { a * b }\n' > "$repo/src/lib.rs"
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=rust
  [ "$FFRC" = 0 ] && ok "F1. rust ticket whose test can't compile on parent → PASS" \
                  || bad "F1. rust compile-red should pass (FFRC=$FFRC: $OUT)"
  grep -q '"kind": "compile-failure"' "$(TD "$repo")/flip-flop.json" 2>/dev/null \
    && ok "F2. parent-leg kind recorded as compile-failure (rust)" \
    || bad "F2. expected compile-failure kind ($(cat "$(TD "$repo")/flip-flop.json" 2>/dev/null))"
  no_scratch_left "$repo" \
    && ok "F3. rust scratch worktree pruned" \
    || bad "F3. rust scratch worktree leaked"
fi

# ==========================================================================
# G. declared-edits guard (behaviors 5 + 6)
# ==========================================================================
echo "== G. declared-edits guard =="
# G repo A: a committed pre-existing test EDITED + a new test ADDED.
repo="$(new_js_repo)"
cat > "$repo/src/other.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('exists', () => { assert.ok(true); });
JS
( cd "$repo" && git add -A && git commit -qm parent2 )
P="$(head_sha "$repo")"
printf '// touched by the ticket\n' >> "$repo/src/other.test.js"
write_honest_js_tip "$repo"

write_result "$(TD "$repo")" '["src/calc.test.js"]' '[]' expected
de_guard "$repo" "$P"
if [ "$DERC" = 1 ] && printf '%s' "$OUT" | grep -q 'src/other.test.js'; then
  ok "G1a. UNDECLARED edit of an existing test FAILS, naming the file"
else
  bad "G1a. undeclared edit should fail naming src/other.test.js (DERC=$DERC: $OUT)"
fi

write_result "$(TD "$repo")" '[]' '[{ "path": "src/other.test.js", "reason": "r" }]' expected
de_guard "$repo" "$P"
if [ "$DERC" = 1 ] && printf '%s' "$OUT" | grep -q 'src/calc.test.js'; then
  ok "G1b. a NEW test file not in newTests is also undeclared (fails, named)"
else
  bad "G1b. undeclared new test should fail naming src/calc.test.js (DERC=$DERC: $OUT)"
fi

write_result "$(TD "$repo")" '["src/calc.test.js"]' \
  '[{ "path": "src/other.test.js", "reason": "updated import" }]' expected
de_guard "$repo" "$P"
[ "$DERC" = 0 ] && ok "G2a. declared edits (same diff + testEdits entry) PASS" \
                || bad "G2a. declared edits should pass (DERC=$DERC: $OUT)"
tej="$(TD "$repo")/test-edits.json"
if [ -f "$tej" ] && grep -q 'src/other.test.js' "$tej" && grep -q 'updated import' "$tej"; then
  ok "G2b. test-edits.json written with {path, reason}"
else
  bad "G2b. test-edits.json missing / incomplete ($(cat "$tej" 2>/dev/null))"
fi
grep -q '"type":"ticket_test_edits"' "$(EV "$repo")" 2>/dev/null \
  && ok "G2c. ticket_test_edits event emitted" \
  || bad "G2c. ticket_test_edits event missing"

# G repo B: a DELETED test file counts as an edit.
repo="$(new_js_repo)"
cat > "$repo/src/dead.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('dead', () => { assert.ok(true); });
JS
( cd "$repo" && git add -A && git commit -qm parent2 )
P="$(head_sha "$repo")"
( cd "$repo" && git rm -q src/dead.test.js && git commit -qm tip )
write_result "$(TD "$repo")" '[]' '[]' 'not-applicable' 'no behavior change'
de_guard "$repo" "$P"
if [ "$DERC" = 1 ] && printf '%s' "$OUT" | grep -q 'src/dead.test.js'; then
  ok "G3. UNDECLARED test deletion FAILS, naming the file"
else
  bad "G3. undeclared deletion should fail naming src/dead.test.js (DERC=$DERC: $OUT)"
fi
write_result "$(TD "$repo")" '[]' \
  '[{ "path": "src/dead.test.js", "reason": "superseded by suite X" }]' 'not-applicable' 'no behavior change'
de_guard "$repo" "$P"
if [ "$DERC" = 0 ] && grep -q 'src/dead.test.js' "$(TD "$repo")/test-edits.json" 2>/dev/null; then
  ok "G4. DECLARED deletion passes and is recorded in test-edits.json"
else
  bad "G4. declared deletion should pass + record (DERC=$DERC: $OUT)"
fi

# ==========================================================================
# H. not-applicable + quality floor (behavior 8 + the floor itself)
# ==========================================================================
echo "== H. not-applicable + quality floor =="
# H repo A: no test changes at all, flipFlop=not-applicable (with reason).
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
printf 'exports.add = (a, b) => a + b; // refactor\n' > "$repo/src/calc.js"
commit_all "$repo"
write_result "$(TD "$repo")" '[]' '[]' 'not-applicable' 'comment-only refactor, existing suite covers it'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 0 ] && ok "H1a. not-applicable → flip-flop SKIPPED (rc 0)" \
                || bad "H1a. not-applicable should skip (FFRC=$FFRC: $OUT)"
grep -q '"verdict": "skipped"' "$(TD "$repo")/flip-flop.json" 2>/dev/null \
  && ok "H1b. flip-flop.json records verdict skipped" \
  || bad "H1b. flip-flop.json should record skipped"
grep -q '"type":"flip_flop_skipped"' "$(EV "$repo")" 2>/dev/null \
  && ok "H1c. flip_flop_skipped event emitted" \
  || bad "H1c. flip_flop_skipped event missing"
q_floor "$repo" "$P"
[ "$QFRC" = 0 ] && ok "H2. quality floor WAIVED for not-applicable (rc 0)" \
                || bad "H2. floor should be waived (QFRC=$QFRC: $OUT)"

# H repo B: not-applicable does NOT waive declared-edits (an undeclared edit still fails).
repo="$(new_js_repo)"
cat > "$repo/src/other.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('exists', () => { assert.ok(true); });
JS
( cd "$repo" && git add -A && git commit -qm parent2 )
P="$(head_sha "$repo")"
printf '// sneaky edit\n' >> "$repo/src/other.test.js"
commit_all "$repo"
write_result "$(TD "$repo")" '[]' '[]' 'not-applicable' 'covered elsewhere'
de_guard "$repo" "$P"
[ "$DERC" = 1 ] && ok "H3. declared-edits STILL enforced under not-applicable" \
                || bad "H3. undeclared edit should fail even when not-applicable (DERC=$DERC: $OUT)"

# H repo C: flipFlop=expected but NO new/changed test → floor fails; flip-flop inconclusive.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
printf 'exports.add = (a, b) => a + b; // touch\n' > "$repo/src/calc.js"
commit_all "$repo"
write_result "$(TD "$repo")" '[]' '[]' expected
q_floor "$repo" "$P"
[ "$QFRC" = 1 ] && ok "H4. floor FAILS: no new/changed test and flipFlop=expected" \
                || bad "H4. floor should fail with no tests (QFRC=$QFRC: $OUT)"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 2 ] && ok "H5. flip-flop with NO test files in the diff → INCONCLUSIVE, never pass" \
                || bad "H5. no-test diff should be inconclusive (FFRC=$FFRC: $OUT)"

# H repo D: a new "test" with NO assertions → floor fails.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
printf 'console.log("hi");\n' > "$repo/src/noop.test.js"
commit_all "$repo"
write_result "$(TD "$repo")" '["src/noop.test.js"]' '[]' expected
q_floor "$repo" "$P"
[ "$QFRC" = 1 ] && ok "H6. floor FAILS: the new test file makes no recognizable claim" \
                || bad "H6. assertion-free test should fail the floor (QFRC=$QFRC: $OUT)"

# H repo E: honest ticket → floor passes.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
write_result "$(TD "$repo")" '["src/calc.test.js"]' '[]' expected
q_floor "$repo" "$P"
[ "$QFRC" = 0 ] && ok "H7. floor passes on an honest asserting test" \
                || bad "H7. honest test should pass the floor (QFRC=$QFRC: $OUT)"

# ==========================================================================
# I. adversarial regressions (S132 fix round)
# ==========================================================================
echo "== I. adversarial regressions =="
# I repo A: a git RENAME of an existing test must not collapse to just the new
# path — with only the new name declared, the old path is an UNDECLARED edit
# (effectively a deletion). Guard against git's rename detection eating it.
repo="$(new_js_repo)"
cat > "$repo/src/old.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('old', () => { assert.ok(true); });
JS
( cd "$repo" && git add -A && git commit -qm parent2 )
P="$(head_sha "$repo")"
( cd "$repo" && git mv src/old.test.js src/renamed.test.js && git commit -qm tip )
write_result "$(TD "$repo")" '["src/renamed.test.js"]' '[]' 'not-applicable' 'pure rename'
de_guard "$repo" "$P"
if [ "$DERC" = 1 ] && printf '%s' "$OUT" | grep -q 'src/old.test.js'; then
  ok "I1. rename with only the NEW name declared FAILS, naming the old path"
else
  bad "I1. undeclared rename source should fail naming src/old.test.js (DERC=$DERC: $OUT)"
fi
write_result "$(TD "$repo")" '["src/renamed.test.js"]' \
  '[{ "path": "src/old.test.js", "reason": "renamed to renamed.test.js" }]' 'not-applicable' 'pure rename'
de_guard "$repo" "$P"
if [ "$DERC" = 0 ] && grep -q 'src/old.test.js' "$(TD "$repo")/test-edits.json" 2>/dev/null; then
  ok "I2. rename declared on BOTH ends passes and records the old path"
else
  bad "I2. fully-declared rename should pass + record (DERC=$DERC: $OUT)"
fi

# I result files: flipFlop=not-applicable while DECLARING new tests is a
# contradiction — a cheater's plausible-green test must not skip the flip-flop.
rd2="$(mktemp -d "$TMPROOT/res2.XXXX")"
cat > "$rd2/na-contradiction.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": ["src/sneaky.test.js"], "testEdits": [],
  "flipFlop": "not-applicable", "flipFlopReason": "no behavior change" }
JSON
pv_result "$rd2/na-contradiction.json"
if [ "$PVRC" = 1 ] && printf '%s' "$OUT" | grep -q 'declares new tests yet claims flip-flop' ; then
  ok "I3. not-applicable + non-empty newTests REJECTS, naming the contradiction"
else
  bad "I3. contradictory not-applicable should reject legibly (PVRC=$PVRC: $OUT)"
fi
cat > "$rd2/na-clean.json" <<'JSON'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": [], "testEdits": [],
  "flipFlop": "not-applicable", "flipFlopReason": "comment-only refactor" }
JSON
pv_result "$rd2/na-clean.json"
[ "$PVRC" = 0 ] && ok "I4. not-applicable with EMPTY newTests still accepted" \
                || bad "I4. clean not-applicable should accept (PVRC=$PVRC: $OUT)"

# ==========================================================================
echo
printf 'proof-gates: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
