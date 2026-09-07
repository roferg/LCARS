#!/usr/bin/env bash
# S185 TESTER LEG 1 — THE VITEST LEG, END TO END, THROUGH THE STAGE.
#
# A blank repo. An initialization mission. `run.sh implement` (the STAGE, never
# implement-ticket). A REAL `npm install` of REAL vitest, done by the machinery
# under test. Then the Verify surface, then approve, then the unlock.
#
# Nothing LCARS prints about the suite is trusted: leg H re-runs the test
# command BY HAND in a FRESH WORKTREE at the mission-branch tip.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/rig.sh"

WORK="$FIX_ROOT/leg1"; rm -rf "$WORK"; mkdir -p "$WORK"
BEHAV="$WORK/behav"; mkdir -p "$BEHAV"
SHIM="$WORK/shim"
export npm_config_cache="${npm_config_cache:-$FIX_ROOT/npmcache}"

VITEST_VER="${VITEST_VER:-3.2.7}"

# ---- the scaffold ticket's behaviour ---------------------------------------
cat > "$BEHAV/t-001.sh" <<BEH
#!/usr/bin/env bash
set -u
mkdir -p "\$out/setup"
cat > "\$out/setup/package.json" <<'PJ'
{
  "name": "gf-app",
  "version": "0.0.0",
  "private": true,
  "type": "module",
  "scripts": { "test": "vitest run" }
}
PJ
printf 'node_modules/\n' > "\$out/setup/.gitignore"
cat > "\$out/test-setup.json" <<'TS'
{ "package": "",
  "gap": "this repository has no test system at all — no manifest, no runner, no way to prove anything",
  "installCommand": "npm install --no-audit --no-fund --save-dev vitest@$VITEST_VER" }
TS
mkdir -p src test
printf "export const greet = () => 'hello';\n" > src/greet.js
cat > test/greet.test.js <<'JS'
import { test, expect } from 'vitest';
import { greet } from '../src/greet.js';
test('greet says hello', () => { expect(greet()).toBe('hello'); });
JS
cat > "\$out/result.json" <<'RJ'
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "establish the project skeleton and its vitest test system",
  "newTests": ["test/greet.test.js"], "testEdits": [],
  "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the repo's test system with vitest, so its parent commit has no runner for the new test to be red against; the captain watches the suite run at Verify" }
RJ
BEH

# ---- ticket 2: a normal slice, held to the REAL gate ------------------------
cat > "$BEHAV/t-002.sh" <<'BEH'
#!/usr/bin/env bash
set -u
mkdir -p src test
printf "export const add = (a, b) => a + b;\n" > src/add.js
cat > test/add.test.js <<'JS'
import { test, expect } from 'vitest';
import { add } from '../src/add.js';
test('adds two numbers', () => { expect(add(2, 2)).toBe(4); });
JS
cat > "$out/result.json" <<'RJ'
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "add() sums two numbers",
  "newTests": ["test/add.test.js"], "testEdits": [],
  "flipFlop": "expected" }
RJ
BEH
chmod +x "$BEHAV"/t-*.sh

make_worker_shim "$SHIM" "$BEHAV"
fuse "$SHIM" || exit 99

T="$(template_blank)"
REPO="$(workcopy "$T" leg1-vitest)"
MD="$(plant_mission "$REPO" init-001 t-001 t-002)"

echo "=== S185 LEG 1: vitest, blank repo, STAGE entry point ==="
echo "repo: $REPO"
echo "vitest: $VITEST_VER   npm cache: $npm_config_cache"

# --- BEFORE: the repo is locked ---------------------------------------------
G0="$(gate "$REPO")"
echo "--- foundation gate BEFORE ---"; printf '%s\n' "$G0"
case "$G0" in *GATE_RC=20*) ok "A1. before the mission, the foundation gate REFUSES (rc 20)";;
  *) bad "A1. gate did not refuse before: $G0";; esac
if grep -q '"testCommand"' "$REPO/.git/lcars/config.json"; then
  bad "A2. repo config already has testCommand before anything ran"
else ok "A2. repo config has NO testCommand before the mission"; fi

START_SPAWNS="$(spawns)"
echo "--- driving run.sh implement ---"
time stage_drive "$REPO" "$SHIM" init-001
printf '%s\n' "$OUT" > "$WORK/stage.log"
echo "stage rc=$RC · worker sessions this leg: $(( $(spawns) - START_SPAWNS ))"
tail -30 "$WORK/stage.log"

echo "--- assertions ---"
[ -f "$MD/test-command.json" ] \
  && { ok "B1. a runner was ESTABLISHED (mission-local record)"; note "$(cat "$MD/test-command.json" | tr -d '\n')"; } \
  || bad "B1. no test-command.json — nothing established"
grep -q '"testCommand"' "$REPO/.git/lcars/config.json" \
  && bad "B2. repo config gained testCommand MID-mission (invariant broken)" \
  || ok "B2. repo config still has NO testCommand mid-mission"
grep -q '"flipFlop"[[:space:]]*:[[:space:]]*"not-applicable"' "$MD/tickets/t-001/result.json" 2>/dev/null \
  && ok "B3. t-001 exits through the waiver" || bad "B3. t-001 has no waiver"
grep -q 'flipFlopReason' "$MD/tickets/t-001/result.json" 2>/dev/null \
  && ok "B4. …with a recorded reason" || bad "B4. no flipFlopReason"

BR="lcars/init-001"
PARENT="$(cat "$MD/tickets/t-002/.commit-base" 2>/dev/null || git -C "$REPO" rev-parse "$BR^" 2>/dev/null || true)"
if [ -n "$PARENT" ] && git -C "$REPO" cat-file -e "$PARENT:package.json" 2>/dev/null; then
  ok "B5. the setup files ARE on ticket 2's parent commit ($PARENT)"
else bad "B5. package.json is NOT on t-002's parent ($PARENT)"; fi

FF="$MD/tickets/t-002/flip-flop.json"
if [ -f "$FF" ]; then
  note "t-002 flip-flop: $(tr -d '\n' < "$FF" | head -c 400)"
  grep -q '"verdict"[^"]*"pass"' "$FF" && ok "B6. t-002 passes a REAL flip-flop" || bad "B6. t-002 flip-flop not pass"
  grep -q '"ran"[[:space:]]*:[[:space:]]*true' "$FF" && ok "B7. …and the PARENT leg actually RAN" || bad "B7. parent leg did not run"
else bad "B6/B7. no flip-flop.json for t-002"; fi
grep -q 'ticket_postcommit_ok' "$MD/events.jsonl" 2>/dev/null \
  && ok "B8. the post-commit gate RAN and verified green" || bad "B8. no ticket_postcommit_ok"

STAGE_NOW="$(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$MD/state.json" | head -1)"
[ "$STAGE_NOW" = verify ] && ok "B9. the mission advanced to VERIFY" || bad "B9. stage is '$STAGE_NOW', not verify"

echo
echo "############ H. THE SUITE, BY MY OWN HAND, IN A FRESH WORKTREE ############"
HW="$WORK/handcheck"; rm -rf "$HW"
git -C "$REPO" worktree prune >/dev/null 2>&1
if git -C "$REPO" worktree add -q --detach "$HW" "$BR" 2>"$WORK/wt.err"; then
  echo "worktree at $BR tip: $(git -C "$HW" rev-parse --short HEAD)"
  echo "tracked files:"; git -C "$HW" ls-files | sed 's/^/    /'
  CMD="$(tc_of "$MD/test-command.json")"
  echo "the command LCARS recorded: $CMD"
  ( cd "$HW" && npm install --no-audit --no-fund ) > "$WORK/hand-install.log" 2>&1
  echo "npm install rc=$? (log: $WORK/hand-install.log)"
  ( cd "$HW" && eval "$CMD" ) > "$WORK/hand-test.log" 2>&1
  HRC=$?
  echo "--- MY OWN RUN OF '$CMD' (rc=$HRC) ---"
  cat "$WORK/hand-test.log"
  [ "$HRC" -eq 0 ] && ok "H1. the recorded test command RUNS AND PASSES by my own hand" \
                   || bad "H1. the recorded test command FAILED by hand (rc=$HRC)"
  grep -qE '[0-9]+ passed' "$WORK/hand-test.log" \
    && ok "H2. …and it actually COLLECTED AND RAN tests (not a vacuous zero-test pass)" \
    || bad "H2. no evidence any test was collected"
else
  bad "H. could not cut a worktree at $BR: $(cat "$WORK/wt.err")"
fi

echo
echo "############ V. THE VERIFY SURFACE, AS THE CAPTAIN ############"
run_sub "$REPO" "$SHIM" -- bash "$RUN_SH" verify-summary --mission init-001
printf '%s\n' "$OUT" | tee "$WORK/verify-summary.txt"
printf '%s' "$OUT" | grep -q 'N/A' && ok "V1. Verify names the waived ticket" || bad "V1. no waiver shown at Verify"
printf '%s' "$OUT" | grep -qi 'CREATES the repo' && ok "V2. …and prints the REASON verbatim" || bad "V2. the reason is invisible at Verify"

echo
echo "############ P. PROMOTION AT APPROVE ############"
printf '%s\n' "$WORK" > "$WORK/.marker"
echo "artifacts: $WORK"
printf '\nLEG 1: %d ok, %d FAIL   (worker sessions: %d, billable: %d)\n' \
  "$PASS" "$FAIL" "$(spawns)" "$(billable)"
[ "$FAIL" -eq 0 ]
