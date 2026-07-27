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
# J. hang timeout (DEFECT-2): a scoped leg that never settles is INCONCLUSIVE,
#    NOT a silent hang — the runner's process group is reaped, no orphan.
# ==========================================================================
echo "== J. flip-flop leg hang timeout =="

# J1-J4: the TIP leg's runner never settles → INCONCLUSIVE, reason names the
# timeout + the TIP leg, scratch pruned, no runaway runner left behind.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD='sleep 691' LCARS_GATE_TIMEOUT=2
[ "$FFRC" = 2 ] && ok "J1. a hanging TIP runner → flip-flop INCONCLUSIVE (rc 2), not a hang" \
                || bad "J1. hanging runner should be inconclusive (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
if grep -q '"verdict": "inconclusive"' "$ffj" 2>/dev/null \
   && grep -qi 'timeout' "$ffj" 2>/dev/null && grep -qi 'TIP leg' "$ffj" 2>/dev/null; then
  ok "J2. flip-flop.json reason NAMES the timeout and the TIP leg"
else
  bad "J2. inconclusive reason should name the timeout + TIP leg ($(cat "$ffj" 2>/dev/null))"
fi
no_scratch_left "$repo" && ok "J3. no scratch worktree survives the TIP timeout" \
                        || bad "J3. scratch worktree leaked after a TIP timeout"
if pgrep -f 'sleep 691' >/dev/null 2>&1; then
  bad "J4. a runaway runner (sleep 691) survived the group-kill"
else
  ok "J4. the hung runner's process group was reaped (no orphan)"
fi

# J5-J6: the SAME wrapper guards the PARENT leg. Tip-only untracked marker makes
# the tests GREEN on tip but the runner SLEEP on the parent scratch → the PARENT
# leg times out → INCONCLUSIVE naming the PARENT leg (not a false pass).
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
: > "$repo/tip-marker"
HCMD='if [ -f tip-marker ]; then node --test $LCARS_TESTS_DIR; else sleep 693; fi'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$HCMD" LCARS_GATE_TIMEOUT=2
[ "$FFRC" = 2 ] && ok "J5. a hanging PARENT runner → flip-flop INCONCLUSIVE (rc 2)" \
                || bad "J5. hanging parent leg should be inconclusive (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
if grep -qi 'timeout' "$ffj" 2>/dev/null && grep -qi 'PARENT leg' "$ffj" 2>/dev/null; then
  ok "J6. flip-flop.json reason names the timeout + the PARENT leg"
else
  bad "J6. parent-timeout reason should name the timeout + PARENT leg ($(cat "$ffj" 2>/dev/null))"
fi
no_scratch_left "$repo" && ok "J7. no scratch worktree survives the PARENT timeout" \
                        || bad "J7. scratch worktree leaked after a PARENT timeout"
pgrep -f 'sleep 693' >/dev/null 2>&1 \
  && bad "J8. a runaway parent-leg runner (sleep 693) survived the group-kill" \
  || ok "J8. the parent-leg hung runner's process group was reaped (no orphan)"

# ==========================================================================
# K. multi-dir ticket (DEFECT-3): the flip-flop legs must collect tests SPANNING
#    two directories — intree_scope_for's common-ancestor arm, live but untested.
# ==========================================================================
echo "== K. multi-dir flip-flop scoping (js) =="
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
mkdir -p "$repo/src/a" "$repo/src/b"
printf 'exports.up = (s) => String(s).toUpperCase();\n' > "$repo/src/a/up.js"
cat > "$repo/src/a/up.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { up } = require('./up.js');
test('up upcases', () => { assert.strictEqual(up('hi'), 'HI'); });
JS
printf 'exports.down = (s) => String(s).toLowerCase();\n' > "$repo/src/b/down.js"
cat > "$repo/src/b/down.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { down } = require('./down.js');
test('down downcases', () => { assert.strictEqual(down('HI'), 'hi'); });
JS
commit_all "$repo"
write_result "$(TD "$repo")" '["src/a/up.test.js","src/b/down.test.js"]' '[]' expected
# intree_scope_for's common-ancestor arm resolves LCARS_TESTS_DIR to `src` (the
# span of both dirs). A dir-recursing runner (vitest/jest/pytest — the real js
# defaults) collects both; `node --test <dir>` does NOT recurse in every node, so
# the fixture stands in for that recursion with an explicit find over the scope.
MULTI_CMD='node --test $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$MULTI_CMD"
[ "$FFRC" = 0 ] && ok "K1. multi-dir ticket → flip-flop PASS (tests across two dirs collected on both legs)" \
                || bad "K1. multi-dir honest ticket should pass (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
if grep -q 'src/a/up.test.js' "$ffj" 2>/dev/null && grep -q 'src/b/down.test.js' "$ffj" 2>/dev/null; then
  ok "K2. flip-flop.json names BOTH spanning test files"
else
  bad "K2. flip-flop.json should name both dirs' test files ($(cat "$ffj" 2>/dev/null))"
fi
# The tip tail must show BOTH spanning tests actually RAN (not just one) — proof
# the common-ancestor scope collected across both dirs, not a single-dir subset.
if grep -q 'up upcases' "$ffj" 2>/dev/null && grep -q 'down downcases' "$ffj" 2>/dev/null; then
  ok "K3. both spanning tests executed (tip tail shows up + down, tests 2)"
else
  bad "K3. tip tail should show BOTH dirs' tests ran ($(cat "$ffj" 2>/dev/null))"
fi
no_scratch_left "$repo" && ok "K4. scratch pruned on the multi-dir pass path" \
                        || bad "K4. scratch worktree leaked (multi-dir)"

# ==========================================================================
# L. ruby (S145): native rspec isolation — greenfield load-red on parent is
#    PROOF (not swallowed as zero-collect), and a zero-example spec reads
#    INCONCLUSIVE, never a pass.
# ==========================================================================
echo "== L. ruby: rspec native flip-flop (greenfield red + zero-collect) =="
# rspec is often installed under the user gem bin, off the default PATH.
if ! command -v rspec >/dev/null 2>&1; then
  for d in "$HOME/.gem/ruby"/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
  export PATH
fi
if ! have rspec || ! ruby -e 'require "rspec"' >/dev/null 2>&1; then
  skip "RUBY: rspec not usable — SKIPPING the ruby native flip-flop proof LOUDLY"
else
  # H1. greenfield: a new spec require_relative's a NEW lib file. On the parent
  # scratch that file is absent → LoadError (a real red, resolution kind); on tip
  # it exists → green. rspec ALSO prints "0 examples" on the LoadError — the gate
  # must NOT read that as zero-collect, or this legit red becomes inconclusive.
  repo="$(mktemp -d "$TMPROOT/rb.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/lib" "$repo/spec"
  printf 'module Existing; end\n' > "$repo/lib/existing.rb"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  P="$(head_sha "$repo")"
  cat > "$repo/spec/mul_spec.rb" <<'RB'
require_relative "../lib/mul"
RSpec.describe "mul" do
  it "multiplies" do
    expect(Mul.call(2, 3)).to eq(6)
  end
end
RB
  cat > "$repo/lib/mul.rb" <<'RB'
module Mul
  def self.call(a, b); a * b; end
end
RB
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=ruby
  [ "$FFRC" = 0 ] && ok "L1. ruby greenfield spec (LoadError on parent) → flip-flop PASS" \
                  || bad "L1. ruby greenfield should PASS, not be swallowed (FFRC=$FFRC: $OUT)"
  ffj="$(TD "$repo")/flip-flop.json"
  grep -Eq '"kind": "(missing-new-module|bad-import-path)"' "$ffj" 2>/dev/null \
    && ok "L2. parent-leg red kind recorded as a resolution red (not zero-collect)" \
    || bad "L2. expected a resolution kind ($(cat "$ffj" 2>/dev/null))"
  grep -q '"type":"flip_flop_pass"' "$(EV "$repo")" 2>/dev/null \
    && ok "L3. flip_flop_pass event emitted for the ruby ticket" \
    || bad "L3. flip_flop_pass event missing (ruby)"
  no_scratch_left "$repo" \
    && ok "L4. ruby scratch worktree pruned" \
    || bad "L4. ruby scratch worktree leaked"

  # H5. zero-collect: a new spec with NO examples runs green (exit 0) on tip but
  # collects nothing → INCONCLUSIVE (rc 2), never a pass.
  repo2="$(mktemp -d "$TMPROOT/rbz.XXXX")"
  ( cd "$repo2" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo2/lib" "$repo2/spec"
  printf 'module Existing; end\n' > "$repo2/lib/existing.rb"
  ( cd "$repo2" && git add -A && git commit -qm parent )
  scaffold_mission "$repo2"
  P2="$(head_sha "$repo2")"
  cat > "$repo2/spec/empty_spec.rb" <<'RB'
RSpec.describe "nothing" do
end
RB
  commit_all "$repo2"
  ff_gate "$repo2" "$P2" LCARS_STACK=ruby
  [ "$FFRC" = 2 ] && ok "L5. zero-example ruby spec on TIP → INCONCLUSIVE (rc 2), never a pass" \
                  || bad "L5. zero-example spec should be inconclusive (FFRC=$FFRC: $OUT)"
  no_scratch_left "$repo2" \
    && ok "L6. ruby scratch pruned on the inconclusive path" \
    || bad "L6. ruby scratch leaked on inconclusive"
fi

# ==========================================================================
# M. dotnet (S147): native --filter isolation END TO END through the real
#    gate. Proves (a) a greenfield C# test whose subject does not exist on the
#    parent is a REAL red (CS0246 compile), not a swallowed zero-collect;
#    (b) a test class with no [Fact] exits 0 under the filter — VSTest's
#    silent-green trap — and must read INCONCLUSIVE; (c) the scratch worktree
#    is pruned on BOTH the pass and the inconclusive exit path (staging
#    hygiene, identical to the go/ruby legs).
# ==========================================================================
echo "== M. dotnet: dotnet test --filter native flip-flop (greenfield red + zero-collect) =="
if ! have dotnet || [ -z "$(dotnet --list-sdks 2>/dev/null)" ]; then
  skip "DOTNET: no usable SDK — SKIPPING the dotnet native flip-flop proof LOUDLY"
else
  export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
  # M1. greenfield: the staged test calls a NEW class. On the parent scratch
  # that class does not exist → CS0246, a real compile red; on tip it does →
  # green. dotnet's zero phrasings must NOT swallow that red.
  # The realistic C# layout the seeder targets: src/App (the subject, a class
  # library) + tests/App.Tests (the test project, referencing it). The staged
  # test lives in the TEST project; the subject does NOT — so only the test is
  # staged into the parent leg, exactly as a real ticket behaves.
  dn_scaffold() { # repo-dir
    local r="$1"
    mkdir -p "$r/src/App" "$r/tests/App.Tests"
    printf 'bin/\nobj/\n' > "$r/.gitignore"
    cat > "$r/src/App/App.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
</Project>
XML
    printf 'namespace App;\npublic static class Existing { public static int Zero() => 0; }\n' \
      > "$r/src/App/Existing.cs"
    cat > "$r/tests/App.Tests/App.Tests.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.4" />
  </ItemGroup>
  <ItemGroup><Using Include="Xunit" /></ItemGroup>
  <ItemGroup><ProjectReference Include="../../src/App/App.csproj" /></ItemGroup>
</Project>
XML
    # a pre-existing sibling test so the project is never empty on the parent
    cat > "$r/tests/App.Tests/SiblingTests.cs" <<'CS'
namespace App.Tests;
public class SiblingCases { [Fact] public void Sib() { Assert.True(true); } }
CS
  }
  repo="$(mktemp -d "$TMPROOT/dn.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  P="$(head_sha "$repo")"
  cat > "$repo/tests/App.Tests/MulTests.cs" <<'CS'
namespace App.Tests.Staged;
public class MulCases
{
    [Fact] public void Multiplies() { Assert.Equal(6, App.Mul.Call(2, 3)); }
}
CS
  cat > "$repo/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=dotnet
  [ "$FFRC" = 0 ] && ok "M1. dotnet greenfield test (CS0246 on parent) → flip-flop PASS" \
                  || bad "M1. dotnet greenfield should PASS, not be swallowed (FFRC=$FFRC: $OUT)"
  ffj="$(TD "$repo")/flip-flop.json"
  grep -q '"kind": "compile-failure"' "$ffj" 2>/dev/null \
    && ok "M2. parent-leg red kind recorded as a compile red (not zero-collect)" \
    || bad "M2. expected compile-failure kind ($(cat "$ffj" 2>/dev/null))"
  # only the TEST file is staged — the subject in src/App is never a test path
  grep -q '"testFiles": \["tests/App.Tests/MulTests.cs"\]' "$ffj" 2>/dev/null \
    && ok "M2'. only the test file was staged (the src/ subject is not a test path)" \
    || bad "M2'. unexpected staged test set ($(grep testFiles "$ffj" 2>/dev/null))"
  grep -q 'Sib' "$ffj" 2>/dev/null \
    && bad "M3. the pre-existing sibling test RAN — the filter did not scope the leg" \
    || ok "M3. the pre-existing sibling test never ran (filter scoped both legs)"
  no_scratch_left "$repo" \
    && ok "M4. dotnet scratch worktree pruned on the PASS path" \
    || bad "M4. dotnet scratch worktree leaked"

  # M5. THE SILENT-GREEN TRAP through the real gate: a staged class with NO
  # [Fact] makes the filter match nothing — `dotnet test` exits 0 — so the TIP
  # leg looks green while proving nothing. It must read INCONCLUSIVE (rc 2).
  repo2="$(mktemp -d "$TMPROOT/dnz.XXXX")"
  ( cd "$repo2" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo2"
  ( cd "$repo2" && git add -A && git commit -qm parent )
  scaffold_mission "$repo2"
  P2="$(head_sha "$repo2")"
  cat > "$repo2/tests/App.Tests/EmptyTests.cs" <<'CS'
namespace App.Tests.Staged;
public class EmptyCases { public void NotATest() { } }
CS
  commit_all "$repo2"
  ff_gate "$repo2" "$P2" LCARS_STACK=dotnet
  [ "$FFRC" = 2 ] \
    && ok "M5. no-[Fact] dotnet class on TIP → INCONCLUSIVE (rc 2), never a pass" \
    || bad "M5. zero-match dotnet filter should be inconclusive (FFRC=$FFRC: $OUT)"
  no_scratch_left "$repo2" \
    && ok "M6. dotnet scratch pruned on the inconclusive path" \
    || bad "M6. dotnet scratch leaked on inconclusive"

  # M7. THE ALL-SKIPPED SILENT GREEN, through the real gate (D1). Unlike M5 the
  # staged class IS discovered — `[Fact(Skip="wip")]` — so VSTest prints neither
  # "no test matches" nor "no test is available"; it prints a `Skipped!` summary
  # with Passed: 0 and exits 0. The TIP leg therefore looked GREEN while running
  # nothing, and with a parent leg red for unrelated (compile) reasons the gate
  # read a clean flip-flop and PASSED a ticket that proved nothing.
  repo3="$(mktemp -d "$TMPROOT/dnskip.XXXX")"
  ( cd "$repo3" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo3"
  ( cd "$repo3" && git add -A && git commit -qm parent )
  scaffold_mission "$repo3"
  P3="$(head_sha "$repo3")"
  cat > "$repo3/tests/App.Tests/SkipTests.cs" <<'CS'
namespace App.Tests.Staged;
public class SkipCases
{
    [Fact(Skip = "wip")] public void NeverRuns() { Assert.Equal(6, App.Mul.Call(2, 3)); }
}
CS
  cat > "$repo3/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo3"
  ff_gate "$repo3" "$P3" LCARS_STACK=dotnet
  [ "$FFRC" = 2 ] \
    && ok "M7. an ALL-SKIPPED staged class → INCONCLUSIVE (rc 2), never a pass" \
    || bad "M7. SILENT GREEN: all-skipped dotnet leg gave FFRC=$FFRC: $OUT"
  grep -q 'ZERO tests' "$(TD "$repo3")/flip-flop.json" 2>/dev/null \
    && ok "M7'. the recorded reason names the zero-collect, not a fake green" \
    || bad "M7'. flip-flop.json should record the zero-collect reason"
  no_scratch_left "$repo3" || bad "M7''. scratch leaked on the all-skipped path"

  # M8. TWO TEST PROJECTS (D3). Staged files land in BOTH; the SECOND project's
  # staged test must FAIL on tip. Taking the project from the first staged .cs
  # while OR-ing every FQN meant the second project was never built or run — the
  # gate PASSED and flip-flop.json recorded BOTH files as proven.
  repo4="$(mktemp -d "$TMPROOT/dn2p.XXXX")"
  ( cd "$repo4" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo4"
  # a SECOND test project beside the first
  mkdir -p "$repo4/tests/Other.Tests"
  sed 's#\.\./\.\./src/App/App\.csproj#../../src/App/App.csproj#' \
    "$repo4/tests/App.Tests/App.Tests.csproj" > "$repo4/tests/Other.Tests/Other.Tests.csproj"
  cat > "$repo4/tests/Other.Tests/OtherSibling.cs" <<'CS'
namespace Other.Tests;
public class OtherSiblingCases { [Fact] public void OS() { Assert.True(true); } }
CS
  ( cd "$repo4" && git add -A && git commit -qm parent )
  scaffold_mission "$repo4"
  P4="$(head_sha "$repo4")"
  cat > "$repo4/tests/App.Tests/FirstTests.cs" <<'CS'
namespace App.Tests.Staged;
public class FirstCases { [Fact] public void Ok() { Assert.Equal(6, App.Mul.Call(2, 3)); } }
CS
  # the SECOND project's staged test is deliberately WRONG — it must fail on tip
  cat > "$repo4/tests/Other.Tests/SecondTests.cs" <<'CS'
namespace Other.Tests.Staged;
public class SecondCases { [Fact] public void Wrong() { Assert.Equal(7, App.Mul.Call(2, 3)); } }
CS
  cat > "$repo4/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo4"
  ff_gate "$repo4" "$P4" LCARS_STACK=dotnet
  [ "$FFRC" != 0 ] \
    && ok "M8. a RED staged test in the SECOND project fails the gate (it really ran)" \
    || bad "M8. SILENT PASS: the second test project was never executed: $OUT"
  grep -q 'SecondCases' "$(TD "$repo4")/flip-flop.json" 2>/dev/null \
    && ok "M8'. the second project's test appears in the recorded leg output (it ran)" \
    || bad "M8'. no trace of the second project in flip-flop.json: $(cat "$(TD "$repo4")/flip-flop.json" 2>/dev/null)"
  no_scratch_left "$repo4" || bad "M8''. scratch leaked on the two-project path"

  # M9. TWO TEST CLASSES ON ONE LINE, through the real gate. A scanner that
  # matched the `class` keyword once per line dropped the SECOND class: it never
  # entered the filter, never ran, and was still recorded proven. Here the second
  # class asserts 999 == 6 — if it runs, the gate MUST NOT pass.
  repo5="$(mktemp -d "$TMPROOT/dn1l.XXXX")"
  ( cd "$repo5" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo5"
  ( cd "$repo5" && git add -A && git commit -qm parent )
  scaffold_mission "$repo5"
  P5="$(head_sha "$repo5")"
  cat > "$repo5/tests/App.Tests/OneLineTests.cs" <<'CS'
namespace App.Tests.OneLine;
public class AlphaCases { [Fact] public void X() { Assert.Equal(6, App.Mul.Call(2, 3)); } } public class BetaCases { [Fact] public void Y() { Assert.Equal(999, App.Mul.Call(2, 3)); } }
CS
  cat > "$repo5/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo5"
  ff_gate "$repo5" "$P5" LCARS_STACK=dotnet
  [ "$FFRC" != 0 ] \
    && ok "M9. a SECOND class on the same line really runs (its red fails the gate)" \
    || bad "M9. SILENT PASS: the second one-line class was never run: $OUT"
  grep -q 'BetaCases' "$(TD "$repo5")/flip-flop.json" 2>/dev/null \
    && ok "M9'. the second one-line class appears in the recorded leg output" \
    || bad "M9'. no trace of BetaCases in flip-flop.json"
  no_scratch_left "$repo5" || bad "M9''. scratch leaked on the one-line path"

  # M10. A `record` TEST CLASS, through the real gate (N3). The scanner knew
  # only the literal `class` keyword, so an xUnit record test class was dropped
  # from the filter — never run, still recorded proven. The SDK's own discovery
  # lists these as real tests, so there is nothing exotic about them.
  repo6="$(mktemp -d "$TMPROOT/dnrec.XXXX")"
  ( cd "$repo6" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo6"
  ( cd "$repo6" && git add -A && git commit -qm parent )
  scaffold_mission "$repo6"
  P6="$(head_sha "$repo6")"
  cat > "$repo6/tests/App.Tests/RecordTests.cs" <<'CS'
namespace App.Tests.Rec;
public record RecordCases { [Fact] public void MustFail() { Assert.Equal(999, App.Mul.Call(2, 3)); } }
CS
  cat > "$repo6/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo6"
  ff_gate "$repo6" "$P6" LCARS_STACK=dotnet
  # rc 1 specifically — the record test RAN and was RED. rc 2 would mean the
  # scan produced no target at all, which is the pre-fix behaviour once the
  # record keyword is unknown: safe, but not proof that records work.
  [ "$FFRC" = 1 ] \
    && ok "M10. a record test class really RUNS (rc 1 = its red, not rc 2 = no target)" \
    || bad "M10. the record test class did not run (FFRC=$FFRC): $OUT"
  grep -q 'RecordCases' "$(TD "$repo6")/flip-flop.json" 2>/dev/null \
    && ok "M10'. the record test appears in the recorded leg output" \
    || bad "M10'. no trace of RecordCases in flip-flop.json"
  no_scratch_left "$repo6" || bad "M10''. scratch leaked on the record path"

  # M11. A MULTI-LINE VERBATIM STRING, through the real gate (N4). Its body was
  # scanned as code, so a net-negative brace run inside it popped the namespace
  # depth and the NEXT class came out BARE — an unqualified contains-term that
  # rode along on a pre-existing test elsewhere in the assembly and let a staged
  # file with NO test of its own read as a pass.
  repo7="$(mktemp -d "$TMPROOT/dnraw.XXXX")"
  ( cd "$repo7" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo7"
  # a pre-existing test elsewhere, with the name a bare term would collide with
  cat > "$repo7/tests/App.Tests/ElsewhereTests.cs" <<'CS'
namespace App.Tests.Elsewhere;
public class VictimCases { [Fact] public void PreExisting() { Assert.True(true); } }
CS
  ( cd "$repo7" && git add -A && git commit -qm parent )
  scaffold_mission "$repo7"
  P7="$(head_sha "$repo7")"
  cat > "$repo7/tests/App.Tests/RawTests.cs" <<'CS'
namespace App.Tests.Raw
{
    public class RawCases
    {
        const string Fixture = @"
json-ish payload with closing braces: } } }
";
    }
    public class VictimCases { }
}
CS
  commit_all "$repo7"
  ff_gate "$repo7" "$P7" LCARS_STACK=dotnet
  [ "$FFRC" = 2 ] \
    && ok "M11. a staged file with NO test of its own ⇒ INCONCLUSIVE, no ride-along" \
    || bad "M11. SILENT PASS via a bare contains-term (FFRC=$FFRC): $OUT"
  grep -q 'PreExisting' "$(TD "$repo7")/flip-flop.json" 2>/dev/null \
    && bad "M11'. a PRE-EXISTING test elsewhere rode along on the staged file" \
    || ok "M11'. the pre-existing test elsewhere never ran"
  no_scratch_left "$repo7" || bad "M11''. scratch leaked on the verbatim-string path"

  # M12. GUARD 2 through the real gate: a staged file declaring TWO tests where
  # the harness can only NAME one of them for --filter. A generic test class is
  # rendered `Ns.GenCases`1` by VSTest, so the scan's `~Ns.GenCases.` term
  # selects NOTHING — one test runs, one silently does not. Before the guard the
  # leg was green (the one test that ran passed) and the ticket was certified on
  # a test that never executed. The count cross-check parks it instead.
  repo8="$(mktemp -d "$TMPROOT/dncnt.XXXX")"
  ( cd "$repo8" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo8"
  ( cd "$repo8" && git add -A && git commit -qm parent )
  scaffold_mission "$repo8"
  P8="$(head_sha "$repo8")"
  cat > "$repo8/tests/App.Tests/CountTests.cs" <<'CS'
namespace App.Tests.Cnt;
public class RunsCases { [Fact] public void Runs() { Assert.Equal(6, App.Mul.Call(2, 3)); } }
public class NeverCases<T> { [Fact] public void NeverRuns() { Assert.Equal(6, App.Mul.Call(2, 3)); } }
CS
  cat > "$repo8/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo8"
  ff_gate "$repo8" "$P8" LCARS_STACK=dotnet
  [ "$FFRC" = 2 ] \
    && ok "M12. a GENERIC test class ⇒ INCONCLUSIVE, never a partial-run pass" \
    || bad "M12. SILENT PASS: an unrunnable declared test was certified (FFRC=$FFRC): $OUT"
  grep -q 'NeverCases' "$(TD "$repo8")/flip-flop.json" 2>/dev/null \
    && ok "M12'. the recorded reason NAMES the type it refused to run" \
    || bad "M12'. flip-flop.json should name the refused type"
  # …and guard 2 must NOT false-fire on a THEORY, which legitimately expands to
  # MORE collected tests than declared attributes.
  repo9="$(mktemp -d "$TMPROOT/dnthy.XXXX")"
  ( cd "$repo9" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo9"
  ( cd "$repo9" && git add -A && git commit -qm parent )
  scaffold_mission "$repo9"
  P9="$(head_sha "$repo9")"
  cat > "$repo9/tests/App.Tests/TheoryTests.cs" <<'CS'
namespace App.Tests.Thy;
public class ThyCases
{
    [Theory] [InlineData(2, 3, 6)] [InlineData(4, 5, 20)] [InlineData(0, 9, 0)]
    public void Multiplies(int a, int b, int want) { Assert.Equal(want, App.Mul.Call(a, b)); }
    [Fact] public void Simple() { Assert.Equal(6, App.Mul.Call(2, 3)); }
}
CS
  cat > "$repo9/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo9"
  ff_gate "$repo9" "$P9" LCARS_STACK=dotnet
  [ "$FFRC" = 0 ] \
    && ok "M12''. a [Theory] expanding to 3 cases still PASSES (guard 2 is an inequality)" \
    || bad "M12''. guard 2 false-fired on a legitimate theory (FFRC=$FFRC): $OUT"
  no_scratch_left "$repo9" || bad "M12'''. scratch leaked on the theory path"

  # M13. THE THEORY-MASK EXPLOIT (R1) — the regression lock for why the
  # unnameable shapes are REFUSED rather than left to GUARD 2. A [Theory]
  # contributes 1 to the declared floor but N to the observed count, and that
  # N-1 slack is exactly enough to hide three dropped nested classes: declared=4,
  # collected=4, every number checks out, and three tests asserting 999 == 6
  # never ran. GUARD 2 alone cannot see this; refusing the nested types can.
  repo10="$(mktemp -d "$TMPROOT/dnmask.XXXX")"
  ( cd "$repo10" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo10"
  ( cd "$repo10" && git add -A && git commit -qm parent )
  scaffold_mission "$repo10"
  P10="$(head_sha "$repo10")"
  cat > "$repo10/tests/App.Tests/MaskTests.cs" <<'CS'
namespace App.Tests.Mask2;
public class ThyCases { [Theory][InlineData(1)][InlineData(2)][InlineData(3)][InlineData(4)] public void Expands(int x) { Assert.Equal(6, App.Mul.Call(2,3)); } }
public class Outer {
  public class A1Cases { [Fact] public void F1() { Assert.Equal(999, App.Mul.Call(2,3)); } }
  public class A2Cases { [Fact] public void F2() { Assert.Equal(999, App.Mul.Call(2,3)); } }
  public class A3Cases { [Fact] public void F3() { Assert.Equal(999, App.Mul.Call(2,3)); } }
}
CS
  cat > "$repo10/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo10"
  ff_gate "$repo10" "$P10" LCARS_STACK=dotnet
  [ "$FFRC" != 0 ] \
    && ok "M13. the THEORY-MASK exploit cannot reach a pass (nested tests refused)" \
    || bad "M13. SILENT PASS: 3 nested tests hid in the theory's slack: $OUT"
  no_scratch_left "$repo10" || bad "M13'. scratch leaked on the theory-mask path"

  # M14. A [Fact] inside a DISABLED #if must not park a legitimate green run
  # (R2). `#if DEBUG` / `#if NET8_0` / `#if WINDOWS` around a test is routine
  # C#, and over-counting the floor bounces a CORRECT ticket to a fresh worker
  # up to three times before parking it awaiting-human.
  repo11="$(mktemp -d "$TMPROOT/dnpp.XXXX")"
  ( cd "$repo11" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo11"
  ( cd "$repo11" && git add -A && git commit -qm parent )
  scaffold_mission "$repo11"
  P11="$(head_sha "$repo11")"
  cat > "$repo11/tests/App.Tests/PPTests.cs" <<'CS'
namespace App.Tests.PP;
public class PPCases {
#if NEVER_DEFINED
    [Fact] public void Disabled() { Assert.True(false); }
#endif
    [Fact] public void Enabled() { Assert.Equal(6, App.Mul.Call(2,3)); }
}
CS
  cat > "$repo11/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo11"
  ff_gate "$repo11" "$P11" LCARS_STACK=dotnet
  [ "$FFRC" = 0 ] \
    && ok "M14. a test inside a DISABLED #if leaves a legitimate green GREEN" \
    || bad "M14. FALSE PARK: #if-disabled test bounced a correct ticket (FFRC=$FFRC): $OUT"
  no_scratch_left "$repo11" || bad "M14'. scratch leaked on the #if path"

  # M15. GUARD 2 still backstops the UNKNOWN-UNKNOWNS. An ABSTRACT test class is
  # a shape the scan happily names (it is neither generic nor nested) but xUnit
  # never discovers directly — verified against the SDK: `--list-tests` lists the
  # concrete class only. Declared 2, collected 1 ⇒ the shortfall parks it.
  repo12="$(mktemp -d "$TMPROOT/dnabs.XXXX")"
  ( cd "$repo12" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo12"
  ( cd "$repo12" && git add -A && git commit -qm parent )
  scaffold_mission "$repo12"
  P12="$(head_sha "$repo12")"
  cat > "$repo12/tests/App.Tests/AbsTests.cs" <<'CS'
namespace App.Tests.Abs;
public abstract class NeverDiscovered { [Fact] public void NeverRuns() { Assert.Equal(999, App.Mul.Call(2,3)); } }
public class RunsCases { [Fact] public void Runs() { Assert.Equal(6, App.Mul.Call(2,3)); } }
CS
  cat > "$repo12/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo12"
  ff_gate "$repo12" "$P12" LCARS_STACK=dotnet
  [ "$FFRC" = 2 ] \
    && ok "M15. GUARD 2 still catches an unknown-unknown (abstract class ⇒ shortfall)" \
    || bad "M15. SILENT PASS: an undiscoverable declared test was certified (FFRC=$FFRC): $OUT"
  grep -q 'declare 2' "$(TD "$repo12")/flip-flop.json" 2>/dev/null \
    && ok "M15'. …and the reason names the collected/declared shortfall" \
    || bad "M15'. flip-flop.json should name the shortfall"
  no_scratch_left "$repo12" || bad "M15''. scratch leaked on the abstract path"

  # M16. THE COMPOSITION BUG (D1) — a defect in neither guard alone. The R1
  # carve-out only refuses a bad-shape type that DECLARED tests, and the R2 fix
  # stopped counting attributes inside `#if`. Compose them and a nested (or
  # generic) type whose every attribute is #if-guarded looks TEST-FREE: nothing
  # refuses it, nothing emits it, nothing counts it — invisible to both guards,
  # while `dotnet test` (which defaults to Debug, so DEBUG is defined) really
  # does discover `…Outer+InnerCases.MustFail`. A test class wholly guarded by
  # `#if NET8_0` / `#if !NETFRAMEWORK` is ordinary in multi-targeted C#.
  repo13="$(mktemp -d "$TMPROOT/dnnif.XXXX")"
  ( cd "$repo13" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo13"
  ( cd "$repo13" && git add -A && git commit -qm parent )
  scaffold_mission "$repo13"
  P13="$(head_sha "$repo13")"
  cat > "$repo13/tests/App.Tests/NestIfTests.cs" <<'CS'
namespace App.Tests.NestIf;
public class Outer {
    public class InnerCases {
#if DEBUG
        [Fact] public void MustFail() { Assert.Equal(999, App.Mul.Call(2,3)); }
#endif
    }
}
public class NormalCases { [Fact] public void Ok() { Assert.Equal(6, App.Mul.Call(2,3)); } }
CS
  cat > "$repo13/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo13"
  ff_gate "$repo13" "$P13" LCARS_STACK=dotnet
  [ "$FFRC" != 0 ] \
    && ok "M16. a NESTED type whose only [Fact] is #if-guarded cannot reach a pass" \
    || bad "M16. SILENT PASS: #if-guarded nested test invisible to both guards: $OUT"
  no_scratch_left "$repo13" || bad "M16'. scratch leaked on the nested-#if path"

  # M16''. the GENERIC variant of the same composition.
  repo14="$(mktemp -d "$TMPROOT/dngif.XXXX")"
  ( cd "$repo14" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo14"
  ( cd "$repo14" && git add -A && git commit -qm parent )
  scaffold_mission "$repo14"
  P14="$(head_sha "$repo14")"
  cat > "$repo14/tests/App.Tests/GenIfTests.cs" <<'CS'
namespace App.Tests.GenIf;
public class GenCases<T> {
#if DEBUG
    [Fact] public void MustFail() { Assert.Equal(999, App.Mul.Call(2,3)); }
#endif
}
public class NormalCases { [Fact] public void Ok() { Assert.Equal(6, App.Mul.Call(2,3)); } }
CS
  cat > "$repo14/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo14"
  ff_gate "$repo14" "$P14" LCARS_STACK=dotnet
  [ "$FFRC" != 0 ] \
    && ok "M16''. …and the GENERIC variant cannot either" \
    || bad "M16''. SILENT PASS: #if-guarded generic test invisible to both guards: $OUT"
  no_scratch_left "$repo14" || bad "M16'''. scratch leaked on the generic-#if path"

  # M17. THE CARVE-OUT MUST SURVIVE the D1 cure — do not trade D1 back for R2.
  # A file with real tests plus PURE helper types (nested, generic, and one whose
  # body is entirely #if-guarded) must still PASS: helpers declare no tests, so
  # nothing may refuse on their account.
  repo15="$(mktemp -d "$TMPROOT/dnhelp.XXXX")"
  ( cd "$repo15" && git init -q && git config user.email t@t && git config user.name t )
  dn_scaffold "$repo15"
  ( cd "$repo15" && git add -A && git commit -qm parent )
  scaffold_mission "$repo15"
  P15="$(head_sha "$repo15")"
  cat > "$repo15/tests/App.Tests/HelperTests.cs" <<'CS'
namespace App.Tests.Help;
public class HelpCases
{
    [Fact] public void Ok() { Assert.Equal(6, App.Mul.Call(2,3)); }
    private class Fixture {
#if DEBUG
        public int Seed;
#endif
    }
    private sealed class Builder<T> { public T V; }
}
CS
  cat > "$repo15/src/App/Mul.cs" <<'CS'
namespace App;
public static class Mul { public static int Call(int a, int b) => a * b; }
CS
  commit_all "$repo15"
  ff_gate "$repo15" "$P15" LCARS_STACK=dotnet
  [ "$FFRC" = 0 ] \
    && ok "M17. nested/generic HELPER types still leave a legitimate green GREEN" \
    || bad "M17. FALSE PARK: the D1 cure broke the helper carve-out (FFRC=$FFRC): $OUT"
  no_scratch_left "$repo15" || bad "M17'. scratch leaked on the helper path"
fi

# ==========================================================================
echo
printf 'proof-gates: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
