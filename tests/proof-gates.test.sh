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
#       PARENT leg: scratch worktree at <parent-sha>, scoped run must be RED (a
#       compile/resolution red from the change's new symbols COUNTS, kind
#       recorded). S157: a test file NEW at the parent is STAGED IN; one that
#       ALREADY EXISTED there runs the PARENT'S OWN copy (so an honest repair is
#       provable), and on that path the file may not SHRINK. ZERO tests collected
#       on either leg = INCONCLUSIVE, never a pass (the green-on-nothing trap).
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

# --- S157 provenance readers ------------------------------------------------
# flip-flop.json records WHICH COPY of each test file the parent leg ran, so no
# reader has to infer it from the verdict prose. These pull it back out.
ff_field() { # flip-flop.json  python-expr over `d` → the value, "" on any error
  python3 - "$1" "$2" 2>/dev/null <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
try:
    sys.stdout.write(str(eval(sys.argv[2], {}, {"d": d})))
except Exception:
    sys.exit(1)
PY
}
ff_mode()   { ff_field "$1" 'd["parentLeg"]["mode"]'; }
ff_ran()    { ff_field "$1" 'd["parentLeg"]["ran"]'; }
ff_reason() { ff_field "$1" 'd["reason"]'; }
ff_source_of() { # flip-flop.json rel → the recorded source for that path
  ff_field "$1" '[s["source"] for s in d["parentLeg"]["sources"] if s["path"]=="'"$2"'"][0]'
}

# The PRE-S157 green-parent rejection sentence, verbatim. Pinned as a constant
# because the NEW-test path must stay BYTE-IDENTICAL: if a future change reworded
# it (or routed a new test down the repair path), these assertions fail loudly
# rather than the difference being noticed by nobody.
LEGACY_GREEN_PARENT_REASON="the ticket's tests PASS on the PARENT commit — red-on-parent is not proven (a test that asserts pre-existing behavior is not proof of work)"

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
# S147 DEFECT-2: the artifact must SELF-EVIDENCE the scoping — record the actual
# command each leg ran. Without it a captain auditing the gate cannot tell from
# the artifact whether the scoping was applied at all (on dotnet the scoped and
# unscoped invocations print byte-identical output), and has to reconstruct and
# re-run the command by hand to prove it.
python3 - "$ffj" <<'PY' && ok "B2c. flip-flop.json records the command BOTH legs ran" \
                        || bad "B2c. flip-flop.json should record tip.cmd + parent.cmd ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tc = d.get("tip", {}).get("cmd") or ""
pc = d.get("parent", {}).get("cmd") or ""
sys.exit(0 if (tc.strip() and pc.strip()) else 1)
PY
python3 - "$ffj" <<'PY' && ok "B2d. the staged/generic leg's recorded cmd names the scope it ran under" \
                        || bad "B2d. generic leg cmd should carry the LCARS_TESTS_DIR scope ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tc = d.get("tip", {}).get("cmd") or ""
# the js/py lane scopes via LCARS_TESTS_DIR — the record must show it, else the
# reader cannot tell a scoped run from a whole-suite run.
sys.exit(0 if "LCARS_TESTS_DIR=" in tc and "calc.test.js" in tc else 1)
PY

grep -q '"type":"flip_flop_pass"' "$(EV "$repo")" 2>/dev/null \
  && ok "B3. flip_flop_pass event emitted" \
  || bad "B3. flip_flop_pass event missing from events.jsonl"
no_scratch_left "$repo" \
  && ok "B4. parent scratch worktree pruned after PASS" \
  || bad "B4. scratch worktree leaked after pass"
# S157: this ticket's test file is NEW at the parent (and it changes product
# source too), so the parent leg STAGES it in — today's behaviour, recorded.
[ "$(ff_mode "$ffj")" = staged ] \
  && ok "B6a. parent leg recorded mode 'staged' for a NEW test file" \
  || bad "B6a. expected parentLeg.mode=staged (got '$(ff_mode "$ffj")')"
[ "$(ff_source_of "$ffj" src/calc.test.js)" = staged ] \
  && ok "B6b. per-file provenance records src/calc.test.js as staged" \
  || bad "B6b. expected source=staged for src/calc.test.js"
[ "$(ff_ran "$ffj")" = True ] \
  && ok "B6c. parentLeg.ran records that the parent leg actually executed" \
  || bad "B6c. expected parentLeg.ran=true (got '$(ff_ran "$ffj")')"
case "$(ff_reason "$ffj")" in
  "tests GREEN on tip, RED on parent (exit"*"— a compile/resolution red from the change's new symbols counts as proof)")
    ok "B6d. NEW-test PASS reason is the pre-S157 sentence, unchanged" ;;
  *) bad "B6d. new-test pass reason changed: $(ff_reason "$ffj")" ;;
esac

# --------------------------------------------------------------------------
# B5 (S147 round-2 D1). THE RE-RUN TEST. Presence of a substring in `cmd` is
# NOT correctness — the whole point of recording the command is that a captain
# can PASTE IT and reproduce the gate's scoped result. So paste it.
#
# The trap this catches: `LCARS_TESTS_DIR=<scope> <cmd>` records an assignment
# PREFIX, but a pasting shell expands the `$LCARS_TESTS_DIR` inside <cmd>
# BEFORE the prefix takes effect — to EMPTY. The recorded string then runs the
# runner with no path argument, i.e. the WHOLE suite, and on a compound
# testCommand the prefix binds only to the first element anyway. The repo below
# carries a pre-existing RED test that the ticket never touches, so an unscoped
# re-run goes RED while the gate went GREEN — the artifact would be telling the
# captain the exact opposite of what the gate did.
repo="$(new_js_repo)"
# a RED test that predates the ticket and is NOT in its diff — the gate must
# never run it, and a faithful re-run must not either.
printf 'const { test } = require("node:test");\nconst assert = require("node:assert");\ntest("decoy is red", () => { assert.strictEqual(1, 2); });\n' \
  > "$repo/src/other.test.js"
( cd "$repo" && git add -A && git commit -qm decoy )
P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 0 ] && ok "B5a. gate PASSES while a pre-existing red test sits beside the ticket" \
                || bad "B5a. gate should scope past the decoy red (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
TIPCMD="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tip"]["cmd"])' "$ffj" 2>/dev/null)"
prc=0
( cd / && bash -c "$TIPCMD" ) >/dev/null 2>&1 || prc=$?
[ "$prc" = 0 ] \
  && ok "B5b. RE-RUNNING the recorded tip cmd reproduces the gate's GREEN (rc 0)" \
  || bad "B5b. recorded tip cmd re-ran to rc=$prc, NOT the gate's pass — the artifact lies about the scoping. cmd: $TIPCMD"
# …and it must have been the SCOPE that kept it green, not luck: the decoy must
# not appear in the re-run's output at all.
POUT="$( cd / && bash -c "$TIPCMD" 2>&1 )" || :
printf '%s' "$POUT" | grep -q 'other.test.js' \
  && bad "B5c. the re-run executed the decoy test — the recorded cmd is NOT scoped" \
  || ok "B5c. the re-run never touched the decoy — the recorded cmd is genuinely scoped"

# B5d. the same faithfulness on a COMPOUND testCommand, where an assignment
# prefix binds only to the FIRST element of the list.
repo="$(new_js_repo)"
printf 'const { test } = require("node:test");\nconst assert = require("node:assert");\ntest("decoy is red", () => { assert.strictEqual(1, 2); });\n' \
  > "$repo/src/other.test.js"
( cd "$repo" && git add -A && git commit -qm decoy )
P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
COMPOUND='grep -q "exports.mul" src/calc.js || { echo "missing impl" >&2; exit 9; }; node --test $LCARS_TESTS_DIR'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$COMPOUND"
[ "$FFRC" = 0 ] && ok "B5d. gate PASSES on a compound testCommand" \
                || bad "B5d. compound testCommand should pass (FFRC=$FFRC: $OUT)"
ffj="$(TD "$repo")/flip-flop.json"
TIPCMD2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tip"]["cmd"])' "$ffj" 2>/dev/null)"
prc2=0
( cd / && bash -c "$TIPCMD2" ) >/dev/null 2>&1 || prc2=$?
[ "$prc2" = 0 ] \
  && ok "B5e. RE-RUNNING the recorded COMPOUND cmd reproduces the gate's GREEN" \
  || bad "B5e. recorded compound cmd re-ran to rc=$prc2, not the gate's pass. cmd: $TIPCMD2"

# B5g. proof_shq is the quoting the whole re-run contract rests on, so round-trip
# it directly against the characters a real repo path / testCommand can contain.
# The first cut escaped apostrophes through a double-quoted replacement, which
# bash re-processes — every `'` came out mangled and the command was unpasteable
# (a path like /Users/o'brien). Asserted here so it cannot regress silently.
SHQLIB="$TMPROOT/shq.sh"
sed -n "/^proof_shq() {/,/^}/p" "$SCRIPT" > "$SHQLIB"
shq_rt() { # string → 0 if proof_shq round-trips it exactly
  bash -c '. "$1"; s="$2"; q="$(proof_shq "$s")"; got="$(eval "printf %s $q")"; [ "$got" = "$s" ]' \
    _ "$SHQLIB" "$1" 2>/dev/null
}
shq_fails=0
for s in "plain" "with space" "it's" 'has "quotes"' 'dollar $HOME' 'back`tick`' \
         'back\slash' "tab	here" "uni✖code" "two''quotes" '$(rm -rf /)' ';| &&' \
         "/Users/o'brien/my repo"; do
  shq_rt "$s" || { shq_fails=$((shq_fails + 1)); printf '      ↳ shq mangled: [%s]\n' "$s"; }
done
[ "$shq_fails" -eq 0 ] \
  && ok "B5g. proof_shq round-trips every shell-hostile character" \
  || bad "B5g. proof_shq mangled $shq_fails input(s) — recorded commands are not pasteable"

# B5f (SMELL 7). A repo path containing a SPACE must still yield a pasteable
# recorded command — an unquoted `cd` splits the path and the paste dies.
repo="$(mktemp -d "$TMPROOT/js sp.XXXX")"
( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
printf '{ "name": "fix", "private": true }\n' > "$repo/package.json"
mkdir -p "$repo/src"
printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
( cd "$repo" && git add -A && git commit -qm parent )
scaffold_mission "$repo"
P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
TIPCMD3="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tip"]["cmd"])' "$ffj" 2>/dev/null)"
if [ "$FFRC" = 0 ] && [ -n "$TIPCMD3" ]; then
  prc3=0; ( cd / && bash -c "$TIPCMD3" ) >/dev/null 2>&1 || prc3=$?
  [ "$prc3" = 0 ] \
    && ok "B5f. a repo path WITH A SPACE still yields a pasteable recorded cmd" \
    || bad "B5f. spaced-path cmd re-ran to rc=$prc3 — the cd path is not quoted. cmd: $TIPCMD3"
else
  # the gate itself cannot survive a spaced path (LEDGERED, pre-existing) — the
  # recording contract is still asserted below on the quoting alone.
  printf '%s' "$TIPCMD3" | grep -Eq "cd ('|\")" \
    && ok "B5f. spaced-path cd is SHELL-QUOTED in the record (gate itself ledgered)" \
    || bad "B5f. spaced-path cd must be shell-quoted ($TIPCMD3)"
fi

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
# S157 REGRESSION GUARD. This cheat's diff is TEST-ONLY (it writes no product
# source), which is the same shape as a repair — but the file is NEW at the
# parent, so it must still be STAGED IN and rejected with the pre-S157 sentence,
# word for word. This is the case most at risk of being swept into the repair path.
[ "$(ff_mode "$ffj")" = staged ] \
  && ok "C5a. a NEW test file in a test-ONLY diff is still staged into the parent" \
  || bad "C5a. expected parentLeg.mode=staged (got '$(ff_mode "$ffj")')"
[ "$(ff_reason "$ffj")" = "$LEGACY_GREEN_PARENT_REASON" ] \
  && ok "C5b. the staged-path rejection reason is byte-identical to pre-S157" \
  || bad "C5b. staged rejection reason changed: $(ff_reason "$ffj")"

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

# J9-J12 (S147 DEFECT-4): the timeout message must NAME THE REAL CAUSE. The
# timeout exists to bound a suite that never settles, but a leg can also run out
# of clock while still fetching/compiling dependencies — a first run on a cold
# package cache. Those are opposite problems with opposite fixes (a hang is a bug
# in the tests; a slow restore just needs a warmer cache or a bigger budget), and
# the old single sentence — "a suite that never settles cannot prove anything" —
# asserted the first no matter which had happened. A captain who hits it must be
# able to tell which one it was WITHOUT re-running anything.

# J9. killed while still resolving/downloading dependencies ⇒ says so, and does
#     NOT assert the suite hung.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
RCMD='echo "Determining projects to restore..."; echo "Downloading xunit 2.9.2"; sleep 694'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$RCMD" LCARS_GATE_TIMEOUT=2
ffj="$(TD "$repo")/flip-flop.json"
[ "$FFRC" = 2 ] && ok "J9. a restore-phase timeout is still INCONCLUSIVE (rc 2)" \
                || bad "J9. restore-phase timeout should be inconclusive (FFRC=$FFRC)"
grep -qi 'depend' "$ffj" 2>/dev/null \
  && ok "J10. the reason names DEPENDENCY resolution as the observed phase" \
  || bad "J10. restore-phase timeout should name dependencies ($(cat "$ffj" 2>/dev/null))"
grep -qi 'never settles' "$ffj" 2>/dev/null \
  && bad "J10b. a restore-phase timeout must NOT assert the suite never settled" \
  || ok "J10b. a restore-phase timeout does not mis-blame the suite"

# J11. a leg that reached test EXECUTION and then stalled is still called a hang
#      — the discrimination must not soften the real hang case.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
HCMD2='echo "Starting test execution, please wait..."; sleep 695'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$HCMD2" LCARS_GATE_TIMEOUT=2
ffj="$(TD "$repo")/flip-flop.json"
grep -qi 'never settles' "$ffj" 2>/dev/null \
  && ok "J11. a stall AFTER tests started still reads as a hung suite" \
  || bad "J11. post-start stall should still name a hang ($(cat "$ffj" 2>/dev/null))"

# J12. every timeout message must name the knob, whichever cause it reports.
grep -q 'LCARS_GATE_TIMEOUT' "$ffj" 2>/dev/null \
  && ok "J12. the timeout message names LCARS_GATE_TIMEOUT" \
  || bad "J12. timeout message should name the LCARS_GATE_TIMEOUT knob"
pgrep -f 'sleep 694' >/dev/null 2>&1 || pgrep -f 'sleep 695' >/dev/null 2>&1 \
  && bad "J13. a runaway runner survived the group-kill (J9/J11)" \
  || ok "J13. both cause-discrimination legs were still group-killed (bound intact)"

# J14-J17 (S147 round-2 D2): the cause classifier must NEVER absolve the suite
# against output that shows a test EXECUTING. The first cut matched bare tokens
# like "Downloading " anywhere in the buffer, so a genuine never-settling test
# that happened to print "Downloading rate-table.json from the fixture server"
# was reported as a cold-cache restore — "the tests themselves are not
# implicated" — while the SAME buffer carried node's own `✖ … (4874ms)`,
# `ℹ tests 1`, `ℹ cancelled 1`. The harness held the falsifying evidence and
# still told the captain to warm the cache and raise the timeout, which only
# makes them wait longer for the same hang. Confident-and-wrong is the failure
# mode; honest ambiguity is acceptable.

# J14. a hanging test whose OWN STDOUT contains a dep-ish word, with real
#      test-execution evidence in the buffer ⇒ HANG, never "not implicated".
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
DECOY='echo "Downloading rate-table.json from the fixture server"; echo "✖ src/calc.test.js (4874.773166ms)"; echo "ℹ tests 1"; echo "ℹ cancelled 1"; sleep 696'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$DECOY" LCARS_GATE_TIMEOUT=2
ffj="$(TD "$repo")/flip-flop.json"
grep -qi 'not implicated\|cold-cache' "$ffj" 2>/dev/null \
  && bad "J14. a HANGING test was absolved as a cold-cache restore ($(grep -o '"reason": "[^"]*"' "$ffj" 2>/dev/null | head -c 400))" \
  || ok "J14. a test's own 'Downloading …' line no longer absolves a hang"
grep -qi 'never settles\|STARTED running' "$ffj" 2>/dev/null \
  && ok "J15. the reason names the hang the evidence actually shows" \
  || bad "J15. buffer showed a test executing — reason must call it a hang ($(grep -o '"reason": "[^"]*"' "$ffj" 2>/dev/null | head -c 400))"

# J16. a test printing a dep-ish word with NO execution evidence at all must not
#      be confidently called a cold restore either — ambiguity is the honest read.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
VAGUE='echo "Downloading rate-table.json from the fixture server"; sleep 697'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$VAGUE" LCARS_GATE_TIMEOUT=2
ffj="$(TD "$repo")/flip-flop.json"
grep -qi 'not implicated' "$ffj" 2>/dev/null \
  && bad "J16. an app's own download line must not be read as a package restore" \
  || ok "J16. a non-restore 'Downloading' line does not assert a cold cache"

# J17. a REAL restore banner (package + version, the shape a package manager
#      prints) with no execution evidence still classifies as the restore phase —
#      the useful half of the discrimination must survive the tightening.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
REST='echo "  Determining projects to restore..."; echo "  Downloading xunit 2.9.2"; sleep 698'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$REST" LCARS_GATE_TIMEOUT=2
ffj="$(TD "$repo")/flip-flop.json"
grep -qi 'depend' "$ffj" 2>/dev/null \
  && ok "J17. a genuine restore banner still reads as the dependency phase" \
  || bad "J17. real restore output must still be recognised ($(grep -o '"reason": "[^"]*"' "$ffj" 2>/dev/null | head -c 400))"

# J18/J19 (MINOR 1 + MINOR 2) on one PARENT-leg timeout whose output exists but
# matches no known marker. MINOR 1: the undetermined wording must not claim the
# leg "produced no output" when it plainly produced some. MINOR 2: the parent
# scratch worktree is pruned before the verdict, so inviting the captain to
# re-run the recorded command points at a directory that no longer exists.
repo="$(new_js_repo)"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
: > "$repo/tip-marker"
PCMD='if [ -f tip-marker ]; then node --test $LCARS_TESTS_DIR; else echo "some output"; sleep 699; fi'
ff_gate "$repo" "$P" LCARS_TEST_CMD="$PCMD" LCARS_GATE_TIMEOUT=2
ffj="$(TD "$repo")/flip-flop.json"
grep -q 'produced no output' "$ffj" 2>/dev/null \
  && bad "J18. must not claim 'produced no output' when output existed" \
  || ok "J18. the undetermined branch does not overclaim about missing output"
grep -q 'nothing the harness recognised' "$ffj" 2>/dev/null \
  && ok "J18b. it says nothing was RECOGNISED, which is what actually happened" \
  || bad "J18b. expected the 'nothing the harness recognised' wording"
grep -qi 'pruned\|no longer exists\|re-cut' "$ffj" 2>/dev/null \
  && ok "J19. a PARENT-leg timeout says its scratch worktree is gone" \
  || bad "J19. parent timeout must warn the scratch is pruned ($(grep -o '"reason": "[^"]*"' "$ffj" 2>/dev/null | head -c 500))"
pgrep -f 'sleep 696' >/dev/null 2>&1 || pgrep -f 'sleep 699' >/dev/null 2>&1 \
  && bad "J20. a runaway runner survived the group-kill (J14/J19)" \
  || ok "J20. the D2 legs were still group-killed (bound intact)"

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
  # S147 DEFECT-2: the ruby leg must record its SCOPED rspec invocation, so the
  # artifact itself proves the run was narrowed to the ticket's spec file.
  python3 - "$ffj" <<'PY' && ok "L4b. flip-flop.json records the scoped rspec command for BOTH legs" \
                          || bad "L4b. ruby legs should record their rspec cmd ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tc = d.get("tip", {}).get("cmd") or ""
pc = d.get("parent", {}).get("cmd") or ""
sys.exit(0 if ("rspec" in tc and "mul_spec.rb" in tc
               and "rspec" in pc and "mul_spec.rb" in pc) else 1)
PY

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
  # S147 DEFECT-2 — THE CASE THAT MOTIVATED THIS. On dotnet the scoped
  # (`--filter …`) and unscoped invocations produce BYTE-IDENTICAL output, so
  # rc + a 20-line tail can NEVER show a reader whether the filter was applied.
  # The capstone captain had to dig `native_scoped_cmd` out of run.sh and re-run
  # it by hand to prove the scoping was real. Recording the actual command makes
  # the gate self-evidencing: the --filter terms are right there in the artifact.
  python3 - "$ffj" <<'PY' && ok "M4b. flip-flop.json records each dotnet leg's --filter terms" \
                          || bad "M4b. dotnet legs should record their --filter cmd ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tc = d.get("tip", {}).get("cmd") or ""
pc = d.get("parent", {}).get("cmd") or ""
for c in (tc, pc):
    if "dotnet test" not in c or "--filter" not in c or "Mul" not in c:
        sys.exit(1)
sys.exit(0)
PY
  # The recorded string must be the REAL command, not a pretty label: the
  # per-project `cd` leg the dotnet runner needs has to be visible too.
  python3 - "$ffj" <<'PY' && ok "M4c. the recorded dotnet cmd carries its per-project leg" \
                          || bad "M4c. dotnet cmd should show the per-project invocation"
import json, sys
d = json.load(open(sys.argv[1]))
tc = d.get("tip", {}).get("cmd") or ""
sys.exit(0 if ("App.Tests" in tc and "cd " in tc) else 1)
PY

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
# N (S148). THE REPO LIVES AT A PATH CONTAINING WHITESPACE.
#
# The seeded testCommands hand the gate's scope over through $LCARS_TESTS_DIR.
# Interpolated UNQUOTED, that scope WORD-SPLITS as soon as the checkout path
# contains a space/tab: the runner gets two half-paths, finds neither, and the
# TIP leg goes red — so the gate FALSE-FAILS a perfectly honest ticket purely
# because of WHERE the repo lives, bouncing it to a fresh worker (≤3 sessions)
# and then parking it awaiting-human.
#
# These are END-TO-END drives, not string assertions, and the command they drive
# is the one `lcars init` ACTUALLY SEEDS — asked of the real detector, never a
# copy — so the section fails against an unquoted seeder and passes against a
# quoted one.
#
# Every drive plants a pre-existing RED DECOY test beside the ticket's, outside
# its diff. A green here therefore proves TWO things at once: the command stopped
# erroring AND the scoping still holds. If the fix had merely widened the run,
# the decoy would fail the leg.
# ==========================================================================
echo "== N. whitespace in the repo path (S148) =="

seeded_cmd_for() { # repo-dir → the testCommand `lcars init` would seed there
  ( . "$REPO_ROOT/skills/lcars-init/lcars-common.sh"; TOPLEVEL="$1" detect_test_cmd )
}

WS_SPACE='ws space'
WS_TAB="$(printf 'ws\ttab')"

ws_js_repo() { # container-name → repo dir (parent commit: src + RED decoy)
  local repo="$TMPROOT/$1/repo"
  mkdir -p "$repo/src"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '{ "name": "fix", "private": true, "scripts": { "test": "node --test" } }\n' > "$repo/package.json"
  printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
  cat > "$repo/src/other.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('DECOY must never run', () => { assert.strictEqual(1, 2); });
JS
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  printf '%s' "$repo"
}

ws_py_repo() { # container-name → repo dir (parent commit: src + RED decoy)
  local repo="$TMPROOT/$1/repo"
  mkdir -p "$repo/src"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '[tool.pytest.ini_options]\n' > "$repo/pyproject.toml"
  printf 'def add(a, b):\n    return a + b\n' > "$repo/src/calc.py"
  printf 'def test_decoy_must_never_run():\n    assert 1 == 2\n' > "$repo/src/test_decoy.py"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  printf '%s' "$repo"
}

# --- N1/N2: js at a SPACED path, driven by the SEEDED command ---------------
repo="$(ws_js_repo "$WS_SPACE")"; P="$(head_sha "$repo")"
WS_JS_CMD="$(seeded_cmd_for "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$WS_JS_CMD"
[ "$FFRC" = 0 ] \
  && ok "N1. js repo at a SPACED path → flip-flop PASS with the seeded command ($WS_JS_CMD)" \
  || bad "N1. FALSE FAIL at a spaced path (FFRC=$FFRC): $OUT"
ffj="$(TD "$repo")/flip-flop.json"
python3 - "$ffj" <<'PY' && ok "N2. the DECOY never ran — the scope still narrowed to the ticket's test" \
                        || bad "N2. decoy ran / tip did not run exactly the ticket's test ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tail = (d.get("tip", {}).get("tail") or "")
sys.exit(0 if ("DECOY" not in tail and "mul multiplies" in tail and "tests 1" in tail) else 1)
PY
no_scratch_left "$repo" && ok "N2b. scratch pruned (spaced path)" \
                        || bad "N2b. scratch leaked at a spaced path"

# --- N3: THE PASTE-BACK. The recorded cmd must reproduce the verdict ---------
# Recording a command is only worth something if it re-runs faithfully. Paste
# tip.cmd back into a shell: it must go GREEN and must still not touch the decoy.
WS_TIPCMD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tip"]["cmd"])' "$ffj" 2>/dev/null)"
WS_RERUN_RC=0
WS_RERUN_OUT="$(bash -c "$WS_TIPCMD" 2>&1)" || WS_RERUN_RC=$?
[ "$WS_RERUN_RC" = 0 ] \
  && ok "N3a. the recorded tip.cmd re-runs GREEN when pasted back (spaced path)" \
  || bad "N3a. recorded cmd does not reproduce the verdict (rc=$WS_RERUN_RC): $WS_RERUN_OUT"
case "$WS_RERUN_OUT" in
  *DECOY*) bad "N3b. the pasted-back command widened the run — it hit the decoy" ;;
  *)       ok  "N3b. the pasted-back command never touches the decoy either" ;;
esac

# --- N4: a TAB in the path (the same word-splitting class) ------------------
repo="$(ws_js_repo "$WS_TAB")"; P="$(head_sha "$repo")"
write_honest_js_tip "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$(seeded_cmd_for "$repo")"
[ "$FFRC" = 0 ] \
  && ok "N4. js repo at a TABBED path → flip-flop PASS" \
  || bad "N4. FALSE FAIL at a tabbed path (FFRC=$FFRC): $OUT"

# --- N5: THE GATE STILL FAILS WHEN IT SHOULD, at a spaced path --------------
# A fix that makes everything pass is worse than the bug. The test-after cheat
# (green on BOTH legs) must still be caught at a whitespace path.
repo="$(ws_js_repo "$WS_SPACE/cheat")"; P="$(head_sha "$repo")"
write_cheat_js_tip "$repo"
write_result "$(TD "$repo")" '["src/calc.test.js"]' '[]' expected
ff_gate "$repo" "$P" LCARS_TEST_CMD="$(seeded_cmd_for "$repo")"
[ "$FFRC" = 1 ] \
  && ok "N5. test-after cheat at a SPACED path is still caught (rc 1, not a false green)" \
  || bad "N5. the cheat should still FAIL at a spaced path (FFRC=$FFRC): $OUT"
# …and for the RIGHT reason. Pre-fix this same rc 1 came from a SPLIT PATH the
# runner could not open — the correct verdict reached by the wrong road. The
# recorded reason must name the parent leg going green, i.e. the actual cheat.
ffj="$(TD "$repo")/flip-flop.json"
python3 - "$ffj" <<'PY' && ok "N5b. the cheat FAILS for the right reason (parent leg GREEN), not a broken path" \
                        || bad "N5b. cheat's recorded reason is not the parent-green cheat ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
reason = (d.get("reason") or "")
par = d.get("parent", {}) or {}
sys.exit(0 if (par.get("rc") == 0 and "PASS on the PARENT" in reason) else 1)
PY

# --- N6: python at a SPACED path, driven by the SEEDED pytest command -------
if ! have pytest && ! python3 -c 'import pytest' >/dev/null 2>&1; then
  skip "PYTHON: pytest not installed — SKIPPING the spaced-path python drive LOUDLY"
else
  have pytest && WS_PYBIN=pytest || WS_PYBIN='python3 -m pytest'
  repo="$(ws_py_repo "$WS_SPACE/py")"; P="$(head_sha "$repo")"
  # The seeded shape, with whatever pytest entry point exists here.
  WS_PY_CMD="$(seeded_cmd_for "$repo")"
  WS_PY_CMD="$WS_PYBIN${WS_PY_CMD#pytest}"
  cat > "$repo/src/test_calc.py" <<'PY'
import calc


def test_mul_multiplies():
    assert calc.mul(2, 3) == 6
PY
  printf 'def add(a, b):\n    return a + b\n\n\ndef mul(a, b):\n    return a * b\n' > "$repo/src/calc.py"
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_TEST_CMD="$WS_PY_CMD"
  [ "$FFRC" = 0 ] \
    && ok "N6. python repo at a SPACED path → flip-flop PASS with the seeded command ($WS_PY_CMD)" \
    || bad "N6. FALSE FAIL at a spaced path, python (FFRC=$FFRC): $OUT"
  ffj="$(TD "$repo")/flip-flop.json"
  python3 - "$ffj" <<'PY' && ok "N7. python DECOY never ran — the pytest scope still narrowed" \
                          || bad "N7. python decoy ran / wrong collection ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tail = (d.get("tip", {}).get("tail") or "")
sys.exit(0 if ("decoy" not in tail and "1 passed" in tail) else 1)
PY
  no_scratch_left "$repo" && ok "N7b. scratch pruned (python, spaced path)" \
                          || bad "N7b. scratch leaked (python, spaced path)"

  # N7c: intree_scope_for's COMMON-ANCESTOR arm at a spaced path. A ticket whose
  # tests span two dirs resolves the scope to their shared parent — a DIRECTORY
  # carrying the whitespace, which the runner must still receive whole. The decoy
  # sits OUTSIDE that ancestor, so it must still not run.
  repo="$(ws_py_repo "$WS_SPACE/pyspan")"
  rm -f "$repo/src/test_decoy.py"
  mkdir -p "$repo/src/a" "$repo/src/b" "$repo/other"
  printf 'def test_decoy_must_never_run():\n    assert 1 == 2\n' > "$repo/other/test_decoy.py"
  # The subject modules EXIST on the parent but lack the ticket's functions, so
  # the parent leg is a clean runtime red (2 collected, 2 failed) rather than an
  # import-time collection error — this case is about the SCOPE, not about how
  # pytest reports a greenfield module.
  printf 'def existing():\n    return None\n' > "$repo/src/a/mod_a.py"
  printf 'def existing():\n    return None\n' > "$repo/src/b/mod_b.py"
  ( cd "$repo" && git add -A && git commit -qm decoy-moved )
  P="$(head_sha "$repo")"
  printf 'def existing():\n    return None\n\n\ndef up(s):\n    return str(s).upper()\n' > "$repo/src/a/mod_a.py"
  printf 'import mod_a\n\n\ndef test_up_upcases():\n    assert mod_a.up("hi") == "HI"\n' > "$repo/src/a/test_up.py"
  printf 'def existing():\n    return None\n\n\ndef down(s):\n    return str(s).lower()\n' > "$repo/src/b/mod_b.py"
  printf 'import mod_b\n\n\ndef test_down_downcases():\n    assert mod_b.down("HI") == "hi"\n' > "$repo/src/b/test_down.py"
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_TEST_CMD="$WS_PY_CMD"
  [ "$FFRC" = 0 ] \
    && ok "N7c. multi-dir ticket at a SPACED path → common-ancestor scope survives whole" \
    || bad "N7c. common-ancestor scope broke at a spaced path (FFRC=$FFRC): $OUT"
  ffj="$(TD "$repo")/flip-flop.json"
  python3 - "$ffj" <<'PY' && ok "N7d. both spanning tests ran, and the out-of-scope decoy did not" \
                          || bad "N7d. wrong collection for the spanning ticket ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tail = (d.get("tip", {}).get("tail") or "")
sys.exit(0 if ("decoy" not in tail and "2 passed" in tail) else 1)
PY
fi

# --- N8: a NATIVE stack at a spaced path — no regression --------------------
# The native lanes (rust/go/ruby/dotnet) scope with relative, already-quoted
# arguments rather than $LCARS_TESTS_DIR, so they were never expected to break.
# VERIFY that rather than assume it.
if ! command -v rspec >/dev/null 2>&1; then
  for d in "$HOME/.gem/ruby"/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
  export PATH
fi
if ! have rspec || ! ruby -e 'require "rspec"' >/dev/null 2>&1; then
  skip "RUBY: rspec not usable — SKIPPING the spaced-path native drive LOUDLY"
else
  repo="$TMPROOT/$WS_SPACE/rb/repo"
  mkdir -p "$repo/lib" "$repo/spec"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf 'module Existing; end\n' > "$repo/lib/existing.rb"
  cat > "$repo/spec/decoy_spec.rb" <<'RB'
RSpec.describe "DECOY" do
  it "must never run" do
    expect(1).to eq(2)
  end
end
RB
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
  printf 'module Mul\n  def self.call(a, b); a * b; end\nend\n' > "$repo/lib/mul.rb"
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=ruby
  [ "$FFRC" = 0 ] \
    && ok "N8. ruby (native lane) at a SPACED path → flip-flop PASS (no regression)" \
    || bad "N8. native lane broke at a spaced path (FFRC=$FFRC): $OUT"
  ffj="$(TD "$repo")/flip-flop.json"
  python3 - "$ffj" <<'PY' && ok "N9. ruby DECOY never ran at the spaced path (native scoping holds)" \
                          || bad "N9. ruby decoy ran ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
tail = (d.get("tip", {}).get("tail") or "")
sys.exit(0 if ("DECOY" not in tail and "1 example, 0 failures" in tail) else 1)
PY
fi

# ==========================================================================
# O (S148). THE REPO LIVES AT A PATH CONTAINING A GLOB METACHARACTER.
#
# Sibling class to N, and NOT a quoting bug — the shell delivers the scope
# byte-perfect and the RUNNER re-globs it. Since Node 22, `node --test <path>`
# treats its positional as a GLOB PATTERN, so an absolute scope carrying the
# checkout's own path is re-interpreted. Observed on node v25.6.1:
#   `\`  → glob-unescaped → "Could not find '<path>'" while the file exists → a
#          FALSE FAIL on honest work;
#   `*`  → EXPANDS across sibling directories → the leg runs test files the
#          ticket never touched. That is not merely a false fail: it is a FALSE
#          PROOF. Constructed and observed — a test-after cheat (green on BOTH
#          legs, correctly FAILED by the gate) is recorded as a PASS as soon as a
#          ride-along in a glob-matched sibling supplies the parent-leg red. O3
#          below is that experiment, kept as a regression.
#   `?`  → same single-char expansion, same widening;
#   `[`  → a CLOSED class (`br[a-c]k`) matched a sibling INSTEAD of the real dir —
#          one test collected, from the wrong repo, silently. (A lone unclosed `[`
#          is literal today, but closure is runner-internal parsing state, so the
#          opener is what we refuse.)
#   `{`  → `{a,b}` brace-expands the same way (a lone `{` is literal today — same
#          reasoning as `[`).
# No quoting can fix this, and glob-ESCAPING the scope would corrupt it for every
# runner that takes the path literally (pytest and rspec both do). So the generic
# lane REFUSES to run: INCONCLUSIVE, naming the real cause, per GUARD 1's
# principle — never toward a pass, never toward a baffling red.
#
# THE OVER-PARK SIDE IS THE HARDER HALF. Every character guarded is a repo shape
# LCARS will not run, so O5 drives the whole ordinary-punctuation set end-to-end
# and requires a normal GREEN. Parking those would be a worse bug than the one
# this closes.
# ==========================================================================
echo "== O. glob metacharacters in the repo path (S148) =="

gl_drive() { # container-name → sets FFRC/OUT for an HONEST js ticket at that path
  repo="$(ws_js_repo "$1")"; P="$(head_sha "$repo")"
  write_honest_js_tip "$repo"
  ff_gate "$repo" "$P" LCARS_TEST_CMD="$(seeded_cmd_for "$repo")"
}

# --- O1/O2: `*` → parked, with an honest, actionable message ----------------
gl_drive 'gl*ob'
[ "$FFRC" = 2 ] \
  && ok "O1. repo path containing '*' → INCONCLUSIVE (rc 2), never a pass and never a mystery red" \
  || bad "O1. a '*' in the repo path must park the leg (FFRC=$FFRC): $OUT"
ffj="$(TD "$repo")/flip-flop.json"
python3 - "$ffj" <<'PY' && ok "O2. the reason names the offending character, blames the LOCATION, and says what to do" \
                        || bad "O2. unhelpful park message ($(cat "$ffj" 2>/dev/null))"
import json, sys
d = json.load(open(sys.argv[1]))
r = (d.get("reason") or "")
low = r.lower()
sys.exit(0 if (d.get("verdict") == "inconclusive"
               and "*" in r
               and "glob" in low
               and ("move" in low or "rename" in low)) else 1)
PY

# --- O3: THE FALSE-PROOF REGRESSION -----------------------------------------
# The cheat below is green on BOTH legs and MUST fail the gate. Pre-guard, a
# ride-along test in a sibling directory that the `re*po` glob also matches
# supplied the parent-leg red and the gate recorded verdict "pass" — a silent
# green sourced from a file the ticket never touched. The guard must make that
# unreachable, and must not reach it by luck: rc 2 (refused), not rc 0.
GLB="$TMPROOT/fp"
mkdir -p "$GLB"
repo="$GLB/re*po"; mkdir -p "$repo/src"
( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
printf '{ "name": "fix", "private": true, "scripts": { "test": "node --test" } }\n' > "$repo/package.json"
printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
( cd "$repo" && git add -A && git commit -qm parent )
scaffold_mission "$repo"
P="$(head_sha "$repo")"
write_cheat_js_tip "$repo"
write_result "$(TD "$repo")" '["src/calc.test.js"]' '[]' expected
# the ride-along: a FAILING test the ticket never touched, in a sibling checkout,
# at exactly the path the PARENT leg's widened glob reaches.
GLD="$GLB/reXXpo/.git/lcars/missions/m-001/proof-worktrees/t-001-parent/src"
mkdir -p "$GLD"
cat > "$GLD/calc.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('RIDEALONG the ticket never touched', () => { assert.strictEqual(1, 2); });
JS
ff_gate "$repo" "$P" LCARS_TEST_CMD='node --test $LCARS_TESTS_DIR'
[ "$FFRC" = 2 ] \
  && ok "O3. a ride-along in a glob-matched SIBLING can no longer manufacture the parent-leg red (no false PROOF)" \
  || bad "O3. FALSE PROOF reachable — the cheat scored FFRC=$FFRC off a file it never touched: $OUT"

# --- O4: the rest of the refused set ----------------------------------------
gl_drive 'back\slash'
[ "$FFRC" = 2 ] \
  && ok "O4a. repo path containing '\\' → INCONCLUSIVE, not the runner's baffling \"Could not find\" red" \
  || bad "O4a. a '\\' in the repo path must park the leg (FFRC=$FFRC): $OUT"
python3 - "$(TD "$repo")/flip-flop.json" <<'PY' && ok "O4b. the '\\' park names that character too" \
                        || bad "O4b. the backslash park does not name the character ($FFRC)"
import json, sys
r = (json.load(open(sys.argv[1])).get("reason") or "")
sys.exit(0 if "\\" in r and "glob" in r.lower() else 1)
PY
for ch in 'qu?st' 'br[ack' 'br{ace'; do
  gl_drive "$ch"
  [ "$FFRC" = 2 ] \
    && ok "O4c. repo path '$ch' → INCONCLUSIVE" \
    || bad "O4c. '$ch' must park the leg (FFRC=$FFRC): $OUT"
done

# --- O5: THE OVER-PARK REGRESSION -------------------------------------------
# Ordinary punctuation that a real machine really has in its paths. Every one of
# these is verified LITERAL to the runner, so every one must still drive a normal
# flip-flop PASS. (Space and tab — the S148 quoting fix — are re-proven here as
# well as in N, because parking them would silently undo that fix.)
for ch in 'plain' 'sp ace' "$(printf 'ta\tb')" "o'brien" 'sa"y' 'a$b' 'a`b' 'a;b' \
          'a#b' 'a~b' 'a+b' 'a(b)c' 'répö-日本' 'a&b' 'a=b' 'a!b'; do
  gl_drive "ok/$ch"
  [ "$FFRC" = 0 ] \
    && ok "O5. ordinary path '$ch' still runs normally (flip-flop PASS)" \
    || bad "O5. OVER-PARK: '$ch' is literal to the runner and must not be refused (FFRC=$FFRC): $OUT"
done

# ==========================================================================
# P. S157 — THE PARENT-LEG SOURCE RULE (provable repairs)
#
# GROUND TRUTH (live mission lcars-20260727-001, 2026-07-27). A sibling ticket
# landed a vite.config that broke how an EXISTING test file resolved the repo
# root; the file threw at import and its 13 tests stopped running. Self-heal
# produced the correct, honestly-declared one-line repair — and flip_flop_gate
# rejected it three times, because the parent leg copied the ticket's FIXED file
# into the parent worktree, where the docs it asserts about were already correct.
# Both legs green. Red-on-parent was unprovable BY CONSTRUCTION for any repair.
#
# THE RULE: a test file that already existed at the parent runs the PARENT'S OWN
# committed copy. The cheat still dies because you can only repair what was
# broken — see P2, which is the acceptance bar for the whole session.
# ==========================================================================
echo "== P. parent-leg source rule / provable repairs (S157) =="

# The test file at the centre of the fixture: it reads a doc off disk through a
# repo-root expression. Pass the BROKEN expression to reproduce the 2026-07-27
# shape (it throws before asserting), or the working one for a green file. The
# ASSERTION is identical in both — only the resolution differs, exactly like the
# real repair (`fileURLToPath(new URL('..', import.meta.url))` → `process.cwd()`).
docs_test() { # root-expr
  cat <<JS
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const repoRoot = $1;
test('the ADR is on disk', () => {
  assert.ok(fs.readFileSync(repoRoot + 'docs/ADR.md', 'utf8').includes('Decision'));
});
JS
}
BROKEN_ROOT="'/nonexistent-lcars-s157-root/'"
WORKING_ROOT="process.cwd() + '/'"

repair_repo() { # parent-root-expr → repo dir (the test file is COMMITTED at the parent)
  local repo; repo="$(mktemp -d "$TMPROOT/rep.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '{ "name": "fix", "private": true }\n' > "$repo/package.json"
  mkdir -p "$repo/src" "$repo/docs" "$repo/tests"
  printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
  printf '# ADR-001\n\nDecision: keep it.\n' > "$repo/docs/ADR.md"
  docs_test "$1" > "$repo/tests/docs.test.js"
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  echo "$repo"
}

# --- P1: THE HONEST REPAIR -> PASS -----------------------------------------
# Pre-existing test file, genuinely BROKEN on the parent, fixed on the tip, no
# product source touched. Before S157 this was the 3-rejection / 8-session loop.
repo="$(repair_repo "$BROKEN_ROOT")"; P="$(head_sha "$repo")"
docs_test "$WORKING_ROOT" > "$repo/tests/docs.test.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
[ "$FFRC" = 0 ] && ok "P1a. honest repair of a pre-existing BROKEN test → flip-flop PASS" \
                || bad "P1a. honest repair should pass (FFRC=$FFRC: $OUT)"
grep -q '"verdict": "pass"' "$ffj" 2>/dev/null \
  && ok "P1b. flip-flop.json records verdict pass for the repair" \
  || bad "P1b. expected verdict pass ($(cat "$ffj" 2>/dev/null))"
[ "$(ff_mode "$ffj")" = parent-own ] \
  && ok "P1c. parent leg recorded mode 'parent-own' (it ran the parent's copy)" \
  || bad "P1c. expected parentLeg.mode=parent-own (got '$(ff_mode "$ffj")')"
[ "$(ff_source_of "$ffj" tests/docs.test.js)" = parent-own ] \
  && ok "P1d. per-file provenance records tests/docs.test.js as parent-own" \
  || bad "P1d. expected source=parent-own for tests/docs.test.js"
# The PASS reason must be a LEDGER, not a verdict on intent. An earlier cut said
# "so this is a certified REPAIR" — and printed that identical sentence over a
# gutting and over a deletion (both now rejected by R, but the copy was wrong
# regardless: the gate cannot see intent).
case "$(ff_reason "$ffj")" in
  *"ESTABLISHED:"*"parent's OWN committed copy"*"NOT established:"*)
    ok "P1e. the PASS reason separates what was ESTABLISHED from what was not" ;;
  *) bad "P1e. repair pass reason does not ledger its facts: $(ff_reason "$ffj")" ;;
esac
case "$(ff_reason "$ffj")" in
  *"certified REPAIR"*)
    bad "P1f. the reason still claims to certify intent: $(ff_reason "$ffj")" ;;
  *"never the ticket's edited one"*)
    ok "P1f. it names which copy ran and claims nothing about intent" ;;
  *) bad "P1f. reason should name which copy ran: $(ff_reason "$ffj")" ;;
esac
no_scratch_left "$repo" \
  && ok "P1g. scratch worktree pruned after the repair PASS" \
  || bad "P1g. scratch worktree leaked after the repair pass"

# --- P2: THE CHEAT MUST STILL DIE ------------------------------------------
# THE ACCEPTANCE BAR. The pre-existing file PASSES on the parent; the worker
# guts the assertion so it passes on the tip too. The parent's own copy is green,
# so no red exists to prove anything, and the ticket is rejected — with a reason
# that describes THIS failure (nothing was broken), not the new-test one.
repo="$(repair_repo "$WORKING_ROOT")"; P="$(head_sha "$repo")"
# The weakening keeps the file the SAME SIZE (same test count, same assertion
# lines) so it slips past the D1 shrink guard and is judged by the parent leg
# itself — which is the branch under test here. R1 covers the shrinking variant.
cat > "$repo/tests/docs.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const repoRoot = process.cwd() + '/';
test('the ADR is on disk', () => {
  assert.ok(true || fs.existsSync(repoRoot + 'docs/ADR.md'));
});
JS
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
CHEAT_OUT="$OUT"
[ "$FFRC" = 1 ] && ok "P2a. WEAKENING an existing PASSING test → flip-flop FAIL (rc 1)" \
                || bad "P2a. THE CHEAT MUST DIE — expected rc 1 (FFRC=$FFRC: $OUT)"
grep -q '"verdict": "fail"' "$ffj" 2>/dev/null \
  && ok "P2b. flip-flop.json records verdict fail for the weakened test" \
  || bad "P2b. expected verdict fail ($(cat "$ffj" 2>/dev/null))"
case "$(ff_reason "$ffj")" in
  *"PARENT'S OWN copy"*"PASSES on the parent commit"*"no repair to make"*)
    ok "P2c. the rejection reason is ACCURATE for the repair path" ;;
  *) bad "P2c. cheat rejection reason is wrong/borrowed: $(ff_reason "$ffj")" ;;
esac
case "$(ff_reason "$ffj")" in
  *"asserts pre-existing behavior"*)
    bad "P2d. the repair path must NOT reuse the new-test wording: $(ff_reason "$ffj")" ;;
  *) ok "P2d. it does NOT reuse the new-test 'asserts pre-existing behavior' wording" ;;
esac
[ "$(ff_mode "$ffj")" = parent-own ] \
  && ok "P2e. provenance shows the parent's own copy was what ran" \
  || bad "P2e. expected parentLeg.mode=parent-own (got '$(ff_mode "$ffj")')"
grep -q '"type":"flip_flop_fail"' "$(EV "$repo")" 2>/dev/null \
  && ok "P2f. flip_flop_fail event emitted for the cheat" \
  || bad "P2f. flip_flop_fail event missing for the cheat"
no_scratch_left "$repo" \
  && ok "P2g. scratch worktree pruned after the cheat FAIL" \
  || bad "P2g. scratch worktree leaked after the cheat fail"
# The OTHER shape of the same cheat — gutting rather than weakening in place — is
# rejected too, one gate earlier (the D1 guard, before either leg runs). Both
# doors on a PASSING pre-existing file, pinned together.
repo="$(repair_repo "$WORKING_ROOT")"; P="$(head_sha "$repo")"
cat > "$repo/tests/docs.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
test('the ADR is on disk', () => { assert.ok(true); });
JS
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 1 ] && ok "P2h. GUTTING a passing pre-existing test is rejected as well" \
                || bad "P2h. the gutting variant of the cheat survived (FFRC=$FFRC: $OUT)"

# --- P3: MIXED DIFF (repair + product source) -> THE NORMAL GATE ------------
# A repair is TEST-INFRASTRUCTURE ONLY. The same honest repair, but the ticket
# also edits product source: every file is staged as before, so the FIXED copy
# runs at the parent, passes there, and the ticket is rejected with the pre-S157
# sentence. Intended: product behaviour never rides in under "I only fixed a test".
repo="$(repair_repo "$BROKEN_ROOT")"; P="$(head_sha "$repo")"
docs_test "$WORKING_ROOT" > "$repo/tests/docs.test.js"
printf 'exports.add = (a, b) => a + b;\nexports.sub = (a, b) => a - b;\n' > "$repo/src/calc.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
[ "$(ff_mode "$ffj")" = staged ] \
  && ok "P3a. a diff that also touches product source takes the NORMAL (staged) gate" \
  || bad "P3a. expected parentLeg.mode=staged for a mixed diff (got '$(ff_mode "$ffj")')"
[ "$(ff_source_of "$ffj" tests/docs.test.js)" = staged ] \
  && ok "P3b. the pre-existing test file is staged when product source moved too" \
  || bad "P3b. expected source=staged for tests/docs.test.js in a mixed diff"
[ "$FFRC" = 1 ] && ok "P3c. mixed diff → the normal gate's verdict (rc 1 here)" \
                || bad "P3c. expected the normal gate verdict (FFRC=$FFRC: $OUT)"
# The legacy sentence must still OPEN the rejection byte for byte — but on its
# own it reads as "your genuinely-broken test passes on the parent", which is the
# unexitable-loop shape this session exists to kill. A clause naming what
# disabled the repair path is appended (S157 P4).
case "$(ff_reason "$ffj")" in
  "$LEGACY_GREEN_PARENT_REASON"*)
    ok "P3d. the pre-S157 rejection wording still OPENS it, byte for byte" ;;
  *) bad "P3d. mixed diff lost the legacy opening: $(ff_reason "$ffj")" ;;
esac
case "$(ff_reason "$ffj")" in
  *"REPAIR path was not available"*"src/calc.js"*)
    ok "P3e. and it says the repair path was withdrawn, naming the path that did it" ;;
  *) bad "P3e. no explanation of the lost repair path: $(ff_reason "$ffj")" ;;
esac
[ -n "$(ff_field "$ffj" 'd["parentLeg"]["repairPathRefused"]')" ] \
  && ok "P3f. flip-flop.json records repairPathRefused as durable provenance" \
  || bad "P3f. parentLeg.repairPathRefused should carry the reason"

# --- P4: BOTH KINDS IN ONE TEST-ONLY DIFF (mixed sources) -------------------
# The ticket repairs the broken pre-existing file AND adds a new test file. Each
# file takes its own source; the reason states the bound (the red is the run's,
# not attributed to one file).
repo="$(repair_repo "$BROKEN_ROOT")"; P="$(head_sha "$repo")"
docs_test "$WORKING_ROOT" > "$repo/tests/docs.test.js"
cat > "$repo/tests/extra.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('../src/calc.js');
test('add adds', () => { assert.strictEqual(add(2, 2), 4); });
JS
commit_all "$repo"
# Two files → intree_scope_for's common-ancestor arm hands the runner the `tests`
# DIR, and `node --test <dir>` does not recurse (see K) — the find form stands in
# for a real js runner's directory collection on BOTH legs.
ff_gate "$repo" "$P" LCARS_TEST_CMD='node --test $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
ffj="$(TD "$repo")/flip-flop.json"
[ "$(ff_mode "$ffj")" = mixed ] \
  && ok "P4a. per-file sources: repaired file parent-own, new file staged (mode mixed)" \
  || bad "P4a. expected parentLeg.mode=mixed (got '$(ff_mode "$ffj")')"
[ "$(ff_source_of "$ffj" tests/docs.test.js)" = parent-own ] \
  && [ "$(ff_source_of "$ffj" tests/extra.test.js)" = staged ] \
  && ok "P4b. each file's provenance is recorded individually" \
  || bad "P4b. wrong per-file sources ($(cat "$ffj" 2>/dev/null))"
[ "$FFRC" = 0 ] && ok "P4c. the repair's red on the parent still certifies the ticket" \
                || bad "P4c. expected pass (FFRC=$FFRC: $OUT)"
case "$(ff_reason "$ffj")" in
  *"did not attribute it to one file"*)
    ok "P4d. the reason states the real bound instead of overclaiming per-file proof" ;;
  *) bad "P4d. mixed pass reason should state its bound: $(ff_reason "$ffj")" ;;
esac

# --- P5: PROVENANCE IS ALWAYS PRINTED, INCLUDING WHEN THE LEG NEVER RAN -----
# The tip is still broken, so the gate fails before the parent leg. The record
# must still say which copy WOULD have run, and say plainly that it did not run.
repo="$(repair_repo "$BROKEN_ROOT")"; P="$(head_sha "$repo")"
docs_test "'/still-broken-lcars-s157/'" > "$repo/tests/docs.test.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
[ "$FFRC" = 1 ] && ok "P5a. a still-red TIP fails, repair path or not" \
                || bad "P5a. expected the tip-red fail (FFRC=$FFRC: $OUT)"
[ "$(ff_ran "$ffj")" = False ] \
  && ok "P5b. parentLeg.ran=false when the gate finished before the parent leg" \
  || bad "P5b. expected parentLeg.ran=false (got '$(ff_ran "$ffj")')"
[ "$(ff_source_of "$ffj" tests/docs.test.js)" = parent-own ] \
  && ok "P5c. the source it WOULD have used is still recorded" \
  || bad "P5c. provenance missing on the early-exit path ($(cat "$ffj" 2>/dev/null))"

# --- P6: THE OTHER GATES STILL APPLY TO A REPAIR ---------------------------
# S157 changed where the flip-flop reads its evidence — nothing else. A repair is
# still an EDIT of an existing test file, so it must be declared, and it still
# has to assert something.
repo="$(repair_repo "$BROKEN_ROOT")"; P="$(head_sha "$repo")"
docs_test "$WORKING_ROOT" > "$repo/tests/docs.test.js"
commit_all "$repo"
write_result "$(TD "$repo")" '[]' '[]' expected
de_guard "$repo" "$P"
[ "$DERC" = 1 ] && ok "P6a. an UNDECLARED repair is still rejected by the declared-edits guard" \
                || bad "P6a. undeclared repair should fail the guard (DERC=$DERC: $OUT)"
write_result "$(TD "$repo")" '[]' \
  '[{ "path": "tests/docs.test.js", "reason": "repo-root resolution broke; no assertion weakened" }]' expected
de_guard "$repo" "$P"
[ "$DERC" = 0 ] && ok "P6b. a DECLARED repair passes the declared-edits guard" \
                || bad "P6b. declared repair should pass (DERC=$DERC: $OUT)"
q_floor "$repo" "$P"
[ "$QFRC" = 0 ] && ok "P6c. the quality floor still runs over the repaired file" \
                || bad "P6c. quality floor should pass for the repair (QFRC=$QFRC: $OUT)"

# ==========================================================================
# T. S157 — THE REPAIR PATH ON A NON-NODE STACK (go)
#
# Every other end-to-end fixture here is node. This drives the parent-own leg
# through go's real toolchain, so the claim that a repair is certifiable outside
# js rests on more than one runner.
# ==========================================================================
echo "== T. repair path end-to-end on go =="
if ! have go; then
  skip "GO: go not installed — SKIPPING the non-node repair-path drive LOUDLY"
else
  new_go_repair_repo() { # → repo whose committed TestPrecise FAILS at the parent
    local repo; repo="$(mktemp -d "$TMPROOT/gorep.XXXX")"
    ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
    printf 'module fix\n\ngo 1.21\n' > "$repo/go.mod"
    printf 'package fix\n\nfunc Add(a, b float64) float64 { return a + b }\n' > "$repo/math.go"
    cat > "$repo/math_test.go" <<'GO'
package fix

import "testing"

func TestAdds(t *testing.T) {
	if Add(1, 1) != 2 {
		t.Fatal("adds is wrong")
	}
}

func TestPrecise(t *testing.T) {
	if Add(0.1, 0.2) != 0.3 {
		t.Fatal("precise is wrong")
	}
}
GO
    ( cd "$repo" && git add -A && git commit -qm parent )
    scaffold_mission "$repo"
    echo "$repo"
  }
  # T1: the honest go repair — fix HOW the test compares, keep both test names.
  repo="$(new_go_repair_repo)"; P="$(head_sha "$repo")"
  cat > "$repo/math_test.go" <<'GO'
package fix

import (
	"math"
	"testing"
)

func TestAdds(t *testing.T) {
	if Add(1, 1) != 2 {
		t.Fatal("adds is wrong")
	}
}

func TestPrecise(t *testing.T) {
	if math.Abs(Add(0.1, 0.2)-0.3) > 1e-9 {
		t.Fatal("precise is wrong")
	}
}
GO
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=go
  ffj="$(TD "$repo")/flip-flop.json"
  [ "$FFRC" = 0 ] && ok "T1a. go: an honest repair of a pre-existing failing test PASSES" \
                  || bad "T1a. go honest repair should pass (FFRC=$FFRC: $OUT)"
  [ "$(ff_mode "$ffj")" = parent-own ] \
    && ok "T1b. go: it went down the parent-own path, not the staged one" \
    || bad "T1b. expected mode=parent-own on go (got '$(ff_mode "$ffj")')"
fi

# ==========================================================================
# U. S157 — THE ONE ANTI-GUTTING CHECK, AND WHAT IT CANNOT SEE
#
# The source-reading guard that used to live here (name sets, skip markers, an
# assertion floor, and a character-level lexer under them) was broken at a new
# token by five successive reviewers and was false-failing honest repairs. The
# captain ruled it out. What remains reads NO source: the two runners report how
# many tests each leg executed, and the tip may not execute fewer than the
# parent. Its blind spots are pinned below rather than described.
# ==========================================================================
echo "== U. the runner-count check + its pinned blind spots (S157) =="

lex_repo() { # → repo with src/calc.js exporting add() and docs()
  local repo; repo="$(mktemp -d "$TMPROOT/lex.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '{ "name": "fix", "private": true }\n' > "$repo/package.json"
  mkdir -p "$repo/src" "$repo/tests"
  printf 'exports.add = (a, b) => a + b;\nexports.docs = () => "Decision";\n' > "$repo/src/calc.js"
  scaffold_mission "$repo"
  echo "$repo"
}

# --- U5: THE RUNNER-COUNT CHECK -- the one non-source mechanism -------------
# `describe.skip` disables every test inside it while each `it(...)` is still
# declared, by name, on both sides: four characters of diff, invisible to any
# name set. The runners see it instantly (3 executed → 0).
u5_repo() { # → repo whose committed suite has one FAILING test inside a describe
  local repo; repo="$(lex_repo)"
  cat > "$repo/tests/blk.test.js" <<'JS'
const { describe, it } = require('node:test');
const assert = require('node:assert');
const { add } = require('../src/calc.js');
describe('calc', () => {
  it('a', () => { assert.strictEqual(add(1, 1), 2); });
  it('b', () => { assert.strictEqual(add(0.1, 0.2), 0.3); });
  it('c', () => { assert.strictEqual(add(2, 2), 4); });
});
JS
  ( cd "$repo" && git add -A && git commit -qm parent )
  echo "$repo"
}
U5_FIXED='const { describe, it } = require("node:test");
const assert = require("node:assert");
const { add } = require("../src/calc.js");
describe("calc", () => {
  it("a", () => { assert.strictEqual(add(1, 1), 2); });
  it("b", () => { assert.ok(Math.abs(add(0.1, 0.2) - 0.3) < 1e-9); });
  it("c", () => { assert.strictEqual(add(2, 2), 4); });
});
'
# U5a: the honest repair of that same file must still pass, counts equal.
repo="$(u5_repo)"; P="$(head_sha "$repo")"
printf '%s' "$U5_FIXED" > "$repo/tests/blk.test.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
[ "$FFRC" = 0 ] && ok "U5a. the honest repair passes — the runner executed as many tests as before" \
                || bad "U5a. runner-count check false-failed an honest repair (FFRC=$FFRC: $OUT)"
if [ "$(ff_field "$ffj" 'd["executed"]["parent"]')" = 3 ] \
   && [ "$(ff_field "$ffj" 'd["executed"]["tip"]')" = 3 ]; then
  ok "U5b. and both counts are recorded as provenance (3 → 3)"
else
  bad "U5b. executed counts not recorded: $(ff_field "$ffj" 'd["executed"]')"
fi
# U5c: describe.skip — the source is identical apart from four characters, so
# nothing that reads it can tell the two apart. The runners can: 3 → 0.
repo="$(u5_repo)"; P="$(head_sha "$repo")"
printf '%s' "$U5_FIXED" | sed 's/^describe(/describe.skip(/' > "$repo/tests/blk.test.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
[ "$FFRC" = 1 ] && ok "U5c. describe.skip around the whole block → FAIL" \
                || bad "U5c. describe.skip was certified (FFRC=$FFRC: $OUT)"
case "$(ff_reason "$ffj")" in
  *"RUNNER executed FEWER tests on the tip than on the parent"*)
    ok "U5d. and the reason quotes the two counts — no source claim is made" ;;
  *) bad "U5d. wrong rejection for describe.skip: $(ff_reason "$ffj")" ;;
esac
# U5e: the same trick with an if(false) wrapper — also a count drop.
repo="$(u5_repo)"; P="$(head_sha "$repo")"
printf '%s' "$U5_FIXED" | sed 's/^describe(/if (false) describe(/' > "$repo/tests/blk.test.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
[ "$FFRC" = 1 ] && ok "U5e. a block hidden behind if (false) is caught the same way" \
                || bad "U5e. if(false) block was certified (FFRC=$FFRC: $OUT)"
case "$(ff_reason "$ffj")" in
  *"RUNNER executed FEWER tests on the tip than on the parent"*)
    ok "U5e2. and that reason quotes the two counts, not a source claim" ;;
  *) bad "U5e2. if(false) should be a count rejection: $(ff_reason "$ffj")" ;;
esac
# U5f: an early return inside the block.
repo="$(u5_repo)"; P="$(head_sha "$repo")"
printf '%s' "$U5_FIXED" | sed 's|^  it("a"|  return;\n  it("a"|' > "$repo/tests/blk.test.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 1 ] && ok "U5f. an early return that skips the rest of a block is caught too" \
                || bad "U5f. early-return block was certified (FFRC=$FFRC: $OUT)"

# --- U6/U7: the runner check's OWN blind spots, pinned ----------------------
# U6: KNOWN LIMIT — a parent copy DEAD AT IMPORT executes nothing, so
# `tip < parent` can never fire. That is the flagship ground-truth class (a
# config change made the file throw before registering anything), i.e. the check
# is vacuous exactly where it would be most wanted; there the source name-set is
# the only guard. Pinned so the asymmetry is on the record.
repo="$(lex_repo)"
cat > "$repo/tests/imp.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
const { nope } = require('../src/missing.js');
test('a', () => { assert.ok(nope); });
test('b', () => { assert.ok(true); });
JS
( cd "$repo" && git add -A && git commit -qm parent )
P="$(head_sha "$repo")"
cat > "$repo/tests/imp.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
test('a', () => { assert.ok(true); });
test('b', () => { assert.ok(true); });
JS
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
if [ "$FFRC" = 0 ] && [ "$(ff_field "$ffj" 'd["executed"]["parent"]')" -le 1 ]; then
  ok "U6. KNOWN LIMIT: a parent dead at import executes ~nothing — the count check is VACUOUS there"
else
  bad "U6. KNOWN LIMIT changed — import-dead parent now FFRC=$FFRC exec=$(ff_field "$ffj" 'd["executed"]["parent"]'); update the ledger deliberately"
fi

# U7: KNOWN LIMIT — a runner whose output carries no count. go prints `ok pkg`,
# so the check is UNAVAILABLE there and only the source rules apply. Recorded in
# the artifact as checked:false rather than silently assumed to have passed.
if ! have go; then
  skip "GO: go not installed — SKIPPING the no-count-available pin"
else
  repo="$(mktemp -d "$TMPROOT/gou7.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf 'module fix\n\ngo 1.21\n' > "$repo/go.mod"
  printf 'package fix\n\nfunc Add(a, b float64) float64 { return a + b }\n' > "$repo/math.go"
  cat > "$repo/math_test.go" <<'GO'
package fix

import "testing"

func TestAdds(t *testing.T) {
	if Add(1, 1) != 2 {
		t.Fatal("adds is wrong")
	}
}

func TestPrecise(t *testing.T) {
	if Add(0.1, 0.2) != 0.3 {
		t.Fatal("precise is wrong")
	}
}
GO
  ( cd "$repo" && git add -A && git commit -qm parent )
  scaffold_mission "$repo"
  P="$(head_sha "$repo")"
  cat > "$repo/math_test.go" <<'GO'
package fix

import (
	"math"
	"testing"
)

func TestAdds(t *testing.T) {
	if Add(1, 1) != 2 {
		t.Fatal("adds is wrong")
	}
}

func TestPrecise(t *testing.T) {
	if math.Abs(Add(0.1, 0.2)-0.3) > 1e-9 {
		t.Fatal("precise is wrong")
	}
}
GO
  commit_all "$repo"
  ff_gate "$repo" "$P" LCARS_STACK=go
  ffj="$(TD "$repo")/flip-flop.json"
  [ "$FFRC" = 0 ] && ok "U7a. go: the honest repair still passes with no count available" \
                  || bad "U7a. go repair failed (FFRC=$FFRC: $OUT)"
  [ "$(ff_field "$ffj" 'd["executed"]["checked"]')" = False ] \
    && ok "U7b. KNOWN LIMIT: go carries no count — the check is recorded as NOT made" \
    || bad "U7b. expected executed.checked=false on go (got $(ff_field "$ffj" 'd["executed"]'))"
fi

# --- U14–U16: the other residuals of the TRIMMED gate, pinned ---------------
# The source-reading guard is gone, so these are simply true now. Each is a
# passing assertion of CURRENT behaviour, so it fails loudly if that changes.

# U14: KNOWN LIMIT — a test that keeps its name AND its place in the run while
# checking less. The runner still executes it, so the count holds; nothing reads
# the source any more. This is the shape the deleted guard chased for five
# rounds; the protection now is the declared edit and the human at Verify.
repo="$(lex_repo)"
cat > "$repo/tests/hollow.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
const { add } = require('../src/calc.js');
function checkAll() {
  assert.strictEqual(add(1, 1), 2);
  assert.strictEqual(add(0.1, 0.2), 0.3);
}
test('everything', () => { checkAll(); });
JS
( cd "$repo" && git add -A && git commit -qm parent )
P="$(head_sha "$repo")"
cat > "$repo/tests/hollow.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
const { add } = require('../src/calc.js');
function checkAll() {
  assert.strictEqual(add(1, 1), 2);
  assert.strictEqual(add(0.1, 0.2), 0.3);
}
test('everything', () => { assert.ok(true); });
JS
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 0 ] \
  && ok "U14. KNOWN LIMIT: a test that keeps its name and still RUNS, checking less, is NOT caught" \
  || bad "U14. KNOWN LIMIT changed — hollowed test now FFRC=$FFRC; update the ledger deliberately"

# U15: KNOWN LIMIT — a repair-only ticket satisfies this gate with no feature
# work of its own. Inherent to the carve-out; whether a ticket did its JOB is the
# acceptance criteria, Verify and the full-suite gate, never this gate.
repo="$(lex_repo)"
cat > "$repo/tests/legacy.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
test('legacy', () => { assert.strictEqual(process.env.LCARS_NOPE_XYZ, 'set'); });
JS
( cd "$repo" && git add -A && git commit -qm parent )
P="$(head_sha "$repo")"
cat > "$repo/tests/legacy.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
test('legacy', () => { assert.strictEqual(process.env.LCARS_NOPE_XYZ || 'set', 'set'); });
JS
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
[ "$FFRC" = 0 ] \
  && ok "U15. KNOWN LIMIT: a repair-only ticket satisfies flip-flop with no feature work" \
  || bad "U15. KNOWN LIMIT changed — repair-only now FFRC=$FFRC; update the ledger deliberately"

# U16: KNOWN LIMIT — renaming a whole test file makes the new path new-at-the-
# parent, so the ticket is STAGED and never reaches the repair path at all.
repo="$(lex_repo)"
cat > "$repo/tests/a.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
const { add } = require('../src/calc.js');
test('broken', () => { assert.strictEqual(add(0.1, 0.2), 0.3); });
test('valuable', () => { assert.strictEqual(add(1, 1), 2); });
JS
( cd "$repo" && git add -A && git commit -qm parent )
P="$(head_sha "$repo")"
rm "$repo/tests/a.test.js"
cat > "$repo/tests/renamed.test.js" <<'JS'
const assert = require('node:assert');
const { test } = require('node:test');
const { add } = require('../src/calc.js');
test('valuable', () => { assert.strictEqual(add(1, 1), 2); });
JS
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD='node --test $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
ffj="$(TD "$repo")/flip-flop.json"
if [ "$(ff_mode "$ffj")" = staged ] && [ "$FFRC" = 1 ]; then
  ok "U16. KNOWN LIMIT: a renamed test file is STAGED — it never reaches the repair path"
else
  bad "U16. KNOWN LIMIT changed — rename now mode=$(ff_mode "$ffj") FFRC=$FFRC; update the ledger deliberately"
fi

# --- U13: the runner-count reader, per runner grammar -----------------------
# EXECUTED, not COLLECTED. vitest/jest/VSTest totals include skipped tests, so
# reading the total made the check vacuous on three of seven runners. NOTE these
# are DOCUMENTED summary formats fed to the pure reader — only the node arm is
# additionally exercised against a live runner (U5).
exec_of() { EXEC_OUT="$(printf '%s\n' "$1" | bash "$SCRIPT" executed-count-test 2>&1)"; }
while IFS='|' read -r label want line; do
  [ -n "$label" ] || continue
  exec_of "$line"
  [ "$EXEC_OUT" = "$want" ] \
    && ok "U13. $label → $want" \
    || bad "U13. $label expected '$want', got '$EXEC_OUT'"
done <<'CASES'
vitest ran 2 of 3|vitest 3| Tests  1 failed | 2 passed (3)
vitest all skipped|vitest 0| Tests  3 skipped (3)
jest ran 3|jest 3|Tests:       1 failed, 2 passed, 3 total
jest all skipped|jest 0|Tests:       3 skipped, 3 total
rspec all pending|rspec 0|3 examples, 0 failures, 3 pending
minitest all skipped|minitest 0|3 runs, 6 assertions, 0 failures, 0 errors, 3 skips
vstest ran 3|vstest 3|Failed: 1, Passed: 2, Skipped: 0, Total: 3
vstest all skipped|vstest 0|Failed: 0, Passed: 0, Skipped: 3, Total: 3
CASES
exec_of "ok  	fix	0.2s"
[ -z "$EXEC_OUT" ] \
  && ok "U13b. a runner with no executed figure yields nothing (the check is skipped, not assumed)" \
  || bad "U13b. go output produced a count: '$EXEC_OUT'"

# --- U8: the two provenance-only exit paths, now pinned (C4) ----------------
# Every other exit path asserts its provenance; these two only wrote it.
repo="$(lex_repo)"
printf 'const { test } = require("node:test");\ntest("x", () => {});\n' > "$repo/tests/na.test.js"
( cd "$repo" && git add -A && git commit -qm parent )
P="$(head_sha "$repo")"
printf 'const { test } = require("node:test");\ntest("x", () => {});\ntest("y", () => {});\n' > "$repo/tests/na.test.js"
commit_all "$repo"
write_result "$(TD "$repo")" '[]' '[]' not-applicable "pure config"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
if [ "$FFRC" = 0 ] && [ "$(ff_mode "$ffj")" = none ] && [ "$(ff_ran "$ffj")" = False ] \
   && [ "$(ff_field "$ffj" 'd["executed"]["checked"]')" = False ]; then
  ok "U8a. a declared not-applicable skip records complete, honest provenance"
else
  bad "U8a. not-applicable provenance wrong: mode=$(ff_mode "$ffj") ran=$(ff_ran "$ffj") exec=$(ff_field "$ffj" 'd["executed"]')"
fi
repo="$(lex_repo)"
printf 'exports.add = (a, b) => a + b;\n' > "$repo/src/calc.js"
( cd "$repo" && git add -A && git commit -qm parent )
P="$(head_sha "$repo")"
printf 'exports.add = (a, b) => a + b;\nexports.sub = (a, b) => a - b;\n' > "$repo/src/calc.js"
commit_all "$repo"
ff_gate "$repo" "$P" LCARS_TEST_CMD="$NODE_CMD"
ffj="$(TD "$repo")/flip-flop.json"
if [ "$FFRC" = 2 ] && [ "$(ff_mode "$ffj")" = none ]; then
  ok "U8b. a diff with NO test file is inconclusive, with provenance saying nothing ran"
else
  bad "U8b. no-test-file path: FFRC=$FFRC mode=$(ff_mode "$ffj")"
fi

# ==========================================================================
# Q. S157 — HONEST REGRESSOR ATTRIBUTION
#
# GROUND TRUTH: the same mission attributed a regression in t-012's test file to
# t-011, whose only distinction was landing last, and handed a worker a reconcile
# brief built on a false premise. The gate already knows who OWNS a failing suite
# — retest_ticket_suites re-runs each ticket's OWN recorded tests.
# ==========================================================================
echo "== Q. regressor attribution (S157) =="

sh_regressor() { # failing ordered → sets SHR_ID + SHR_BASIS
  local line
  line="$( env LCARS_SHR_FAILING="$1" LCARS_SHR_ORDERED="$2" \
           bash "$SCRIPT" selfheal-regressor-test 2>&1 | head -1 )"
  SHR_ID="$(printf '%s' "$line" | cut -f1)"
  SHR_BASIS="$(printf '%s' "$line" | cut -f2)"
}
sh_note() { # id basis → sets NOTE
  NOTE="$( env LCARS_SHR_ID="$1" LCARS_SHR_BASIS="$2" \
           bash "$SCRIPT" selfheal-attribution-test 2>&1 )"
}

# Q1: THE LIVE SHAPE. t-012 (wave 1) authored the failing file; t-011 landed last.
sh_regressor "t-012" "t-001 t-012 t-002 t-011"
[ "$SHR_ID" = t-012 ] && [ "$SHR_BASIS" = authored-failing-suite ] \
  && ok "Q1. the AUTHOR of the failing suite is chosen, not the last ticket to land" \
  || bad "Q1. expected t-012/authored-failing-suite (got '$SHR_ID'/'$SHR_BASIS')"

# Q2: several failing suites → the EARLIEST in plan order, and the failing list's
# own order is irrelevant (it is passed reversed here).
sh_regressor "t-003 t-002" "t-001 t-002 t-003"
[ "$SHR_ID" = t-002 ] && [ "$SHR_BASIS" = authored-failing-suite ] \
  && ok "Q2a. several failing suites → the earliest in WAVE order (deterministic)" \
  || bad "Q2a. expected t-002 (got '$SHR_ID'/'$SHR_BASIS')"
sh_regressor "t-002 t-003" "t-001 t-002 t-003"
[ "$SHR_ID" = t-002 ] \
  && ok "Q2b. same answer whichever order the failing ids arrive in" \
  || bad "Q2b. attribution is order-dependent (got '$SHR_ID')"

# Q3: ownership UNRESOLVED — say so plainly; the last-built ticket is labelled as
# exactly that, never as a culprit.
sh_regressor "" "t-001 t-002 t-003"
[ "$SHR_ID" = t-003 ] && [ "$SHR_BASIS" = unresolved-last-built ] \
  && ok "Q3a. with no owner resolvable the basis is unresolved-last-built" \
  || bad "Q3a. expected t-003/unresolved-last-built (got '$SHR_ID'/'$SHR_BASIS')"
sh_note t-003 unresolved-last-built
case "$NOTE" in
  *"UNRESOLVED"*"could NOT determine"*"NOT a proven culprit"*)
    ok "Q3b. the brief SAYS SO — no guessed culprit" ;;
  *) bad "Q3b. unresolved brief must state it plainly: $NOTE" ;;
esac

# Q4: nothing to pick from at all.
sh_regressor "" ""
[ -z "$SHR_ID" ] && [ "$SHR_BASIS" = none ] \
  && ok "Q4. no tickets at all → basis 'none', no invented id" \
  || bad "Q4. expected empty/none (got '$SHR_ID'/'$SHR_BASIS')"

# Q5: a failing id outside the ordered list is still honest ownership.
sh_regressor "t-099" "t-001 t-002"
[ "$SHR_ID" = t-099 ] && [ "$SHR_BASIS" = authored-failing-suite ] \
  && ok "Q5. a failing id missing from plan order is still attributed to its author" \
  || bad "Q5. expected t-099/authored-failing-suite (got '$SHR_ID'/'$SHR_BASIS')"

# Q6: the AUTHORED brief must not overclaim — owning the broken test is not proof
# of having caused the break.
sh_note t-012 authored-failing-suite
case "$NOTE" in
  *"AUTHORED the failing test"*"NOT proof"*)
    ok "Q6. the authored brief states ownership WITHOUT claiming fault" ;;
  *) bad "Q6. authored brief overclaims or omits the bound: $NOTE" ;;
esac

# --- Q6b/Q6c (D9/D10): hostile and malformed inputs -------------------------
# The id lists are split on whitespace ON PURPOSE, but they must NOT be
# glob-expanded: a `*` in a failing list used to return a FILENAME from the CWD
# as the culprit ticket.
( cd "$REPO_ROOT" && env LCARS_SHR_FAILING='*' LCARS_SHR_ORDERED='t-001 t-002' \
    bash "$SCRIPT" selfheal-regressor-test 2>&1 | head -1 ) > "$TMPROOT/glob.out"
case "$(cat "$TMPROOT/glob.out")" in
  '*'*) ok "Q6b. a glob in the failing list is NOT expanded against the cwd" ;;
  *) bad "Q6b. glob expansion leaked a filename into the pick: $(cat "$TMPROOT/glob.out")" ;;
esac
# The note must degrade legibly on inputs the picker never emits, rather than
# dropping the id it is holding or printing a sentence with a hole in it.
sh_note t-007 bogus-basis
case "$NOTE" in
  *UNRECOGNISED*t-007*UNVERIFIED*) ok "Q6c. an unknown basis still names the id, flagged UNVERIFIED" ;;
  *) bad "Q6c. unknown basis dropped the id or invented a claim: $NOTE" ;;
esac
sh_note "" authored-failing-suite
case "$NOTE" in
  *"could not name any ticket"*) ok "Q6d. an empty id degrades to 'no ticket resolved', not a garbled sentence" ;;
  *) bad "Q6d. empty id produced a malformed brief: $NOTE" ;;
esac

# --- Q7: END-TO-END through the REAL full-suite gate ------------------------
# Not the pure picker this time: the actual gate re-runs each ticket's recorded
# suite, records the ids it attributed the regression to, and the pick follows
# from that. Three tickets; the MIDDLE one's suite is the broken one, and the
# last one is green — pre-S157 the reconcile went to the last one regardless.
fs_repo() { # → repo dir with 3 ticket suites, t-002's failing
  local repo; repo="$(mktemp -d "$TMPROOT/fs.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf '{ "name": "fs", "private": true }\n' > "$repo/package.json"
  mkdir -p "$repo/tests" "$repo/.git/lcars/missions/m-001/tickets"
  # state.json WITHOUT a branch → the gate's documented in-tree retest path.
  printf '{ "id":"m-001","type":"feature","title":"t","stage":"implement" }\n' \
    > "$repo/.git/lcars/missions/m-001/state.json"
  # Canonical (line-oriented) waves.json — parse_waves_table reads one "wave" /
  # "id" per line, exactly as the Schedule stage emits it.
  cat > "$repo/.git/lcars/missions/m-001/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001", "issue": null },
        { "id": "t-002", "issue": null }
      ] },
    { "wave": 2,
      "tickets": [
        { "id": "t-003", "issue": null }
      ] }
  ]
}
JSON
  local i
  for i in 001 002 003; do
    mkdir -p "$repo/.git/lcars/missions/m-001/tickets/t-$i"
    if [ "$i" = 002 ]; then
      printf 'const { test } = require("node:test");\nconst assert = require("node:assert");\ntest("t-%s", () => { assert.strictEqual(1, 2); });\n' "$i" \
        > "$repo/tests/t-$i.test.js"
    else
      printf 'const { test } = require("node:test");\nconst assert = require("node:assert");\ntest("t-%s", () => { assert.ok(true); });\n' "$i" \
        > "$repo/tests/t-$i.test.js"
    fi
    # the proof-time snapshot the gate re-runs from (hash must match in-tree)
    printf '%s  tests/t-%s.test.js\n' \
      "$(shasum -a 256 "$repo/tests/t-$i.test.js" | awk '{print $1}')" "$i" \
      > "$repo/.git/lcars/missions/m-001/tickets/t-$i/proof-tests.sha256"
  done
  ( cd "$repo" && git add -A && git commit -qm base )
  echo "$repo"
}
if ! have shasum; then
  skip "Q7: shasum absent — SKIPPING the end-to-end full-suite attribution drive"
else
  repo="$(fs_repo)"
  OUT="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git LCARS_TEST_CMD="$NODE_CMD" \
          bash "$SCRIPT" full-suite-gate-test --mission m-001 2>&1 )"
  FSRC="$(printf '%s\n' "$OUT" | sed -n 's/^FSRC=//p' | tail -1)"
  FSREG="$(printf '%s\n' "$OUT" | sed -n 's/^FSREG=//p' | tail -1)"
  FSPICK="$(printf '%s\n' "$OUT" | sed -n 's/^FSPICK=//p' | tail -1)"
  [ "$FSRC" = 1 ] && ok "Q7a. the full-suite gate fails on the broken suite" \
                  || bad "Q7a. expected FSRC=1 (got '$FSRC': $OUT)"
  [ "$FSREG" = t-002 ] \
    && ok "Q7b. the gate records the OWNER of the failing suite (t-002)" \
    || bad "Q7b. expected FSREG=t-002 (got '$FSREG': $OUT)"
  [ "$FSPICK" = "t-002|authored-failing-suite" ] \
    && ok "Q7c. self-heal would be handed t-002 — NOT t-003, the last built" \
    || bad "Q7c. expected t-002|authored-failing-suite (got '$FSPICK')"
  case "$OUT" in
    *"a LATER ticket's produced code REGRESSED"*)
      bad "Q7d. the regression detail still asserts an unproven premise: $OUT" ;;
    *"WHICH change is NOT established by this gate"*)
      ok "Q7d. the human-facing detail states what is proven, and what is not" ;;
    *) bad "Q7d. the regression detail's premise copy is missing: $OUT" ;;
  esac
fi

# --- Q8: THE WIRING, through the REAL self-heal loop (stub worker, 0 tokens) --
# Q7 exercises the picker; this exercises the PRODUCTION LINE — impl-advance →
# full_suite_gate → self_heal_full_suite → the reconcile brief actually handed to
# a worker. It also pins the per-round refresh: the fixture's failing set CHANGES
# between rounds (t-002's suite is repaired by the stub, which flips a phase file
# that makes t-003's suite start failing), so a regressor picked ONCE before the
# loop would name t-002 in round 2 above a failure belonging to t-003 — measured,
# not assumed: with the pick hoisted out of the loop this fixture emits
# "ATTRIBUTION: t-002" in BOTH rounds.
echo "== Q8. self-heal attribution end-to-end (stub worker) =="
if ! have shasum; then
  skip "Q8: shasum absent — SKIPPING the end-to-end self-heal drive"
else
  e2e="$(mktemp -d "$TMPROOT/e2e.XXXX")"; MID=m-001
  m="$e2e/.git/lcars/missions/$MID"
  ( cd "$e2e" && git init -q -b main && git config user.email t@t && git config user.name t )
  mkdir -p "$m/tickets" "$e2e/tests"
  printf '# ctx\n' > "$e2e/CONTEXT.md"          # pre-seed context → no context-pack spawn
  printf '{ "name":"e", "private":true }\n' > "$e2e/package.json"
  cat > "$m/state.json" <<EOF
{ "id":"$MID","type":"feature","title":"t","stage":"implement","githubIssue":42,"branch":"lcars/$MID","base":"main" }
EOF
  cat > "$m/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001", "issue": 101 },
        { "id": "t-002", "issue": 102 }
      ] },
    { "wave": 2,
      "tickets": [
        { "id": "t-003", "issue": 103 }
      ] }
  ]
}
JSON
  cat > "$m/approved-plan.json" <<'JSON'
{ "tickets": [
  { "id": "t-001", "title": "one",   "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" },
  { "id": "t-002", "title": "two",   "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" },
  { "id": "t-003", "title": "three", "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" } ] }
JSON
  for i in 001 002 003; do
    mkdir -p "$m/tickets/t-$i"
    if [ "$i" = 002 ]; then
      printf 'const { test }=require("node:test");const a=require("node:assert");\ntest("t2",()=>{a.strictEqual(1,2);});\n' > "$e2e/tests/t-$i.test.js"
    else
      printf 'const { test }=require("node:test");const a=require("node:assert");\ntest("t%s",()=>{a.ok(true);});\n' "$i" > "$e2e/tests/t-$i.test.js"
    fi
    printf '%s  tests/t-%s.test.js\n' \
      "$(shasum -a 256 "$e2e/tests/t-$i.test.js" | awk '{print $1}')" "$i" \
      > "$m/tickets/t-$i/proof-tests.sha256"
    cat > "$m/tickets/t-$i/result.json" <<JSON
{ "ticketId": "t-$i", "passed": true, "attempts": 1, "summary": "s", "newTests": ["tests/t-$i.test.js"], "testEdits": [], "flipFlop": "expected" }
JSON
  done
  ( cd "$e2e" && git add -A && git commit -qm base && git branch "lcars/$MID" )

  E2E_PHASE="$e2e/PHASE2"
  # The stub does an HONEST repair of t-002's pre-existing test (same test count,
  # declared) — which is exactly what the S157 parent-own path is for — and then
  # flips the phase file so the NEXT gate run fails on t-003 instead.
  cat > "$e2e/worker" <<'STUB'
#!/usr/bin/env bash
prompt=""; while [ $# -gt 0 ]; do case "$1" in -p) prompt="${2:-}"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "$prompt" | grep -o 'ATTRIBUTION: [^ ]*' | head -1 >> "$WLOG"
[ "${LCARS_WORKER_ROLE:-}" = implement-tdd ] || exit 0
printf 'const { test }=require("node:test");const a=require("node:assert");\ntest("t2",()=>{a.strictEqual(1,1);});\n' > tests/t-002.test.js
cat > "${LCARS_WORK_OUT:?}/result.json" <<JSON
{ "ticketId": "t-002", "passed": true, "attempts": 1, "summary": "repair",
  "newTests": [], "testEdits": [{ "path": "tests/t-002.test.js", "reason": "the assertion was inverted; restored" }],
  "flipFlop": "expected" }
JSON
: > "$PHASE"
exit 0
STUB
  chmod +x "$e2e/worker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$e2e/gh"; chmod +x "$e2e/gh"
  : > "$e2e/worker.log"
  E2E_CMD='if [ -f '"$E2E_PHASE"' ] && printf %s "$LCARS_TESTS_DIR" | grep -q t-003; then exit 1; fi; if [ -d "$LCARS_TESTS_DIR" ]; then node --test "$LCARS_TESTS_DIR"/*.test.js; else node --test "$LCARS_TESTS_DIR"; fi'
  E2E_OUT="$( cd "$e2e" && env WLOG="$e2e/worker.log" PHASE="$E2E_PHASE" \
      LCARS_SELFHEAL_CAP=2 LCARS_WORKER_BIN="$e2e/worker" LCARS_WORKER_CLI=claude \
      LCARS_TEST_CMD="$E2E_CMD" LCARS_GH_BIN="$e2e/gh" LCARS_NOTIFY=true \
      bash "$SCRIPT" impl-advance --mission "$MID" 2>&1 )"
  E2E_EV="$m/events.jsonl"
  # The gate must have named the AUTHOR of each round's failing suite.
  if printf '%s' "$E2E_OUT" | grep -q 'fully-built repo: t-002' \
     && printf '%s' "$E2E_OUT" | grep -q 'fully-built repo: t-003'; then
    ok "Q8a. the fixture really did change owners between rounds (t-002 then t-003)"
  else
    bad "Q8a. fixture did not produce two different failing owners: $(printf '%s' "$E2E_OUT" | grep -o 'fully-built repo: t-00[0-9]' | tr '\n' ' ')"
  fi
  grep -q '"type":"selfheal_attribution".*round 1.*attributed to t-002 (authored-failing-suite)' "$E2E_EV" 2>/dev/null \
    && ok "Q8b. round 1's reconcile went to t-002 — the AUTHOR, not t-003 the last built" \
    || bad "Q8b. round 1 attribution wrong: $(grep -o 'attributed to [^"]*' "$E2E_EV" 2>/dev/null | tr '\n' ' ')"
  grep -q '"type":"selfheal_attribution".*round 2.*attributed to t-003 (authored-failing-suite)' "$E2E_EV" 2>/dev/null \
    && ok "Q8c. round 2 RE-PICKED from that round's failing set (t-003), not round 1's" \
    || bad "Q8c. round 2 attribution is stale: $(grep -o 'attributed to [^"]*' "$E2E_EV" 2>/dev/null | tr '\n' ' ')"
  # The brief the WORKER actually received — the production string, not a helper.
  grep -q 'ATTRIBUTION: t-003' "$e2e/worker.log" 2>/dev/null \
    && ok "Q8d. the worker's own prompt carried the CURRENT round's attribution" \
    || bad "Q8d. worker prompt attribution: $(sort -u "$e2e/worker.log" 2>/dev/null | tr '\n' ' ')"
  # D5: the escalation's culprit and its victims must come from the same round.
  if printf '%s' "$E2E_OUT" | grep -q 'no longer passes on the branch — .*t-003.*attempt went to .*t-003'; then
    ok "Q8e. the human escalation names one consistent round (culprit == the failing owner)"
  else
    bad "Q8e. escalation culprit/victims diverge: $(printf '%s' "$E2E_OUT" | grep -o 'A test that was green[^.]*\.[^.]*\.' | head -1)"
  fi
fi

# ==========================================================================
# V. THE S157 × #93 MERGE SEAM — a toolchain fault accuses no ticket
#
# #93 taught full_suite_gate to recognise a STALE DEPENDENCY ENVIRONMENT: the
# gate worktree was symlinked to a shared node_modules that no longer matches
# the branch's own committed lockfile, so every suite re-ran against the wrong
# packages. That is a toolchain fault, and no earlier ticket regressed anything.
# S157 taught the same function to record WHICH tickets' suites failed, in
# $FULL_SUITE_REGRESSED, which self-heal reads to choose who gets the reconcile.
#
# Neither change knew about the other. They agree only because the stale-env
# block returns BEFORE the assignment — pinned as ORDERING in
# tests/gate-stale-env-classify.test.sh section 9 (that suite owns the classifier
# and its wiring assertions, and is deliberately pure-filesystem so it cannot
# drive a gate). This section owns the BEHAVIOURAL half, because it already has
# the mission fixtures and the full-suite-gate hook.
# ==========================================================================
echo "== V. stale dependency environment × regressor attribution (merge seam) =="

stale_seam_repo() { # symlink-shared-deps? → repo dir (t-002's suite is the red one)
  local shared="$1" repo mm
  repo="$(mktemp -d "$TMPROOT/seam.XXXX")"; mm="$repo/.git/lcars/missions/m-001"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t )
  mkdir -p "$mm/tickets" "$repo/tests" "$repo/node_modules"
  printf '{ "name":"e", "private":true }\n' > "$repo/package.json"
  cat > "$mm/state.json" <<'JSON'
{ "id":"m-001","type":"feature","title":"t","stage":"implement","githubIssue":42,
  "branch":"lcars/m-001","base":"main" }
JSON
  cat > "$mm/waves.json" <<'JSON'
{
  "waves": [
    { "wave": 1,
      "tickets": [
        { "id": "t-001", "issue": 101 },
        { "id": "t-002", "issue": 102 }
      ] },
    { "wave": 2,
      "tickets": [
        { "id": "t-003", "issue": 103 }
      ] }
  ]
}
JSON
  local i
  for i in 001 002 003; do
    mkdir -p "$mm/tickets/t-$i"
    if [ "$i" = 002 ]; then
      printf 'const { test }=require("node:test");const a=require("node:assert");\ntest("t2",()=>{a.strictEqual(1,2);});\n' > "$repo/tests/t-$i.test.js"
    else
      printf 'const { test }=require("node:test");const a=require("node:assert");\ntest("t%s",()=>{a.ok(true);});\n' "$i" > "$repo/tests/t-$i.test.js"
    fi
    printf '%s  tests/t-%s.test.js\n' \
      "$(shasum -a 256 "$repo/tests/t-$i.test.js" | awk '{print $1}')" "$i" \
      > "$mm/tickets/t-$i/proof-tests.sha256"
    cat > "$mm/tickets/t-$i/result.json" <<JSON
{ "ticketId": "t-$i", "passed": true, "attempts": 1, "summary": "s",
  "newTests": ["tests/t-$i.test.js"], "testEdits": [], "flipFlop": "expected" }
JSON
  done
  # The lockfile the BRANCH commits — this is what the gate worktree carries.
  printf 'FEATURE\n' > "$repo/package-lock.json"
  ( cd "$repo" && git add -A && git commit -qm base && git branch lcars/m-001 )
  # …and the DIFFERENT one in the shared checkout the deps are symlinked from.
  # That divergence IS the stale-dependency evidence. With `shared` off, the
  # worktree gets its own node_modules and there is no evidence at all.
  [ "$shared" = shared ] && printf 'MAIN\n' > "$repo/package-lock.json"
  echo "$repo"
}
seam_gate() { # repo setup-cmd → SEAM_RC / SEAM_REG / SEAM_PICK / SEAM_SIG
  local repo="$1" setup="$2" out
  out="$( cd "$repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          LCARS_TEST_CMD="$NODE_CMD" LCARS_WORKTREE_SETUP_CMD="$setup" \
          LCARS_FS_SIGNAL_OUT="$repo/sig.txt" \
          bash "$SCRIPT" full-suite-gate-test --mission m-001 2>&1 )"
  SEAM_RC="$(printf '%s\n' "$out"   | sed -n 's/^FSRC=//p'   | tail -1)"
  SEAM_REG="$(printf '%s\n' "$out"  | sed -n 's/^FSREG=//p'  | tail -1)"
  SEAM_PICK="$(printf '%s\n' "$out" | sed -n 's/^FSPICK=//p' | tail -1)"
  SEAM_SIG="$(cat "$repo/sig.txt" 2>/dev/null)"
}

if ! have shasum; then
  skip "SEAM: shasum absent — SKIPPING the stale-env × attribution drive"
else
  # --- V1: a stale dependency environment accuses NOBODY --------------------
  repo="$(stale_seam_repo shared)"
  seam_gate "$repo" "ln -sfn '$repo/node_modules' node_modules"
  [ "$SEAM_RC" = 1 ] \
    && ok "V1a. the gate still FAILS on a stale dependency environment (rc 1)" \
    || bad "V1a. expected FSRC=1 (got '$SEAM_RC')"
  case "$SEAM_SIG" in
    *"STALE DEPENDENCY ENVIRONMENT"*)
      ok "V1b. and reports it as a toolchain fault, not a regression" ;;
    *) bad "V1b. expected the stale-env diagnosis, got: $(printf '%s' "$SEAM_SIG" | cut -c1-140)" ;;
  esac
  [ -z "$SEAM_REG" ] \
    && ok "V1c. FULL_SUITE_REGRESSED is EMPTY — no ticket is attributed the break" \
    || bad "V1c. a toolchain fault attributed tickets: '$SEAM_REG'"
  case "$SEAM_SIG" in
    *t-001*|*t-002*|*t-003*) bad "V1d. the signal names a ticket for a toolchain fault: $SEAM_SIG" ;;
    *) ok "V1d. and the signal names no ticket at all" ;;
  esac
  case "$SEAM_PICK" in
    *authored-failing-suite*)
      bad "V1e. a toolchain fault produced an AUTHORED attribution: $SEAM_PICK" ;;
    *) ok "V1e. so nothing can be picked as the author of a failing suite" ;;
  esac

  # --- V2: the genuine regression is UNAFFECTED by any of this --------------
  # Same fixture, same red suite — but the worktree owns its dependencies, so
  # there is no staleness evidence and the ordinary attribution must run.
  repo="$(stale_seam_repo owned)"
  seam_gate "$repo" "mkdir -p node_modules"
  [ "$SEAM_RC" = 1 ] && [ "$SEAM_REG" = t-002 ] \
    && ok "V2a. a real regression with no stale evidence still attributes to t-002" \
    || bad "V2a. expected FSRC=1 FSREG=t-002 (got '$SEAM_RC' / '$SEAM_REG')"
  [ "$SEAM_PICK" = "t-002|authored-failing-suite" ] \
    && ok "V2b. and self-heal is still handed the AUTHORING ticket, not the last built" \
    || bad "V2b. expected t-002|authored-failing-suite (got '$SEAM_PICK')"
  case "$SEAM_SIG" in
    *"STALE DEPENDENCY ENVIRONMENT"*)
      bad "V2c. a genuine regression was misreported as a toolchain fault" ;;
    *"no longer pass against the fully-built repo: t-002"*)
      ok "V2c. and the detail is the ordinary regression wording, naming t-002" ;;
    *) bad "V2c. unexpected detail: $(printf '%s' "$SEAM_SIG" | cut -c1-140)" ;;
  esac

  # --- V3: an ENVIRONMENT FAULT dispatches NO worker at all ------------------
  # This was a KNOWN GAP one commit ago: the gate attributed nothing, but
  # selfheal_regressor fell back to the LAST-BUILT ticket and self-heal spent
  # worker sessions on a toolchain fault — sessions that cannot possibly clear a
  # stale environment, which is the exact failure #93 exists to end. Now the
  # self-heal loop is skipped outright and the mission escalates with the
  # diagnosis the gate already produced.
  #
  # Driven end-to-end through the REAL impl-advance with a stub worker that
  # simply records that it ran, so "no worker was dispatched" is measured, not
  # inferred from a code path.
  v3="$(stale_seam_repo shared)"
  printf '#!/usr/bin/env bash\nprintf "DISPATCHED role=%%s\\n" "${LCARS_WORKER_ROLE:-}" >> "$WLOG"\nexit 0\n' > "$v3/worker"
  chmod +x "$v3/worker"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$v3/gh"; chmod +x "$v3/gh"
  : > "$v3/worker.log"
  cat > "$v3/.git/lcars/missions/m-001/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-001", "title": "one", "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" },
               { "id": "t-002", "title": "two", "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" },
               { "id": "t-003", "title": "three", "description": "d", "acceptanceCriteria": ["a"], "rationale": "r" } ] }
JSON
  V3_OUT="$( cd "$v3" && env WLOG="$v3/worker.log" LCARS_SELFHEAL_CAP=3 \
      LCARS_WORKER_BIN="$v3/worker" LCARS_WORKER_CLI=claude \
      LCARS_TEST_CMD="$NODE_CMD" LCARS_WORKTREE_SETUP_CMD="ln -sfn '$v3/node_modules' node_modules" \
      LCARS_GH_BIN="$v3/gh" LCARS_NOTIFY=true \
      bash "$SCRIPT" impl-advance --mission m-001 2>&1 )"
  V3_EV="$v3/.git/lcars/missions/m-001/events.jsonl"
  [ ! -s "$v3/worker.log" ] \
    && ok "V3a. an environment fault dispatches NO worker (the log is empty)" \
    || bad "V3a. a worker ran on a toolchain fault: $(cat "$v3/worker.log")"
  grep -q '"type":"selfheal_skipped"' "$V3_EV" 2>/dev/null \
    && ok "V3b. and the skip is recorded as an event, not silent" \
    || bad "V3b. no selfheal_skipped event: $(grep -o '"type":"selfheal[a-z_]*"' "$V3_EV" 2>/dev/null | tr '\n' ' ')"
  grep -q '"type":"selfheal_attribution"' "$V3_EV" 2>/dev/null \
    && bad "V3c. a ticket was attributed the break on a toolchain fault" \
    || ok "V3c. no ticket is attributed — the self-heal loop never starts"
  case "$V3_OUT" in
    *"TOOLCHAIN fault, not broken code"*"lcars update"*)
      ok "V3d. the human is parked with an ACTIONABLE toolchain diagnosis" ;;
    *) bad "V3d. escalation copy misleads: $(printf '%s' "$V3_OUT" | grep -i 'IMPLEMENT:' | head -1)" ;;
  esac
  case "$V3_OUT" in
    *"self-heal exhausted"*)
      bad "V3e. it claims self-heal was exhausted when it never ran: $V3_OUT" ;;
    *) ok "V3e. and it does not claim a self-heal that never ran was exhausted" ;;
  esac
  grep -q '"awaitingHuman": *true' "$v3/.git/lcars/missions/m-001/state.json" 2>/dev/null \
    && ok "V3f. the mission is parked for the human, not advanced" \
    || bad "V3f. mission not parked: $(cat "$v3/.git/lcars/missions/m-001/state.json" 2>/dev/null | tr -d '\n' | cut -c1-120)"

  # V4: the OTHER empty-set case is untouched. A regression whose OWNER cannot be
  # resolved leaves the failing set empty too, and must still reach the healer on
  # its `unresolved-last-built` basis — the fix keys on the environment FAULT,
  # not on emptiness, so the two stay distinguishable (see also Q3a).
  sh_regressor "" "t-001 t-002 t-003"
  [ "$SHR_ID" = t-003 ] && [ "$SHR_BASIS" = unresolved-last-built ] \
    && ok "V4. an unresolvable-owner regression still yields a healable pick (not conflated)" \
    || bad "V4. the unresolved-owner path broke: '$SHR_ID'/'$SHR_BASIS'"
fi

# ==========================================================================
echo
printf 'proof-gates: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
