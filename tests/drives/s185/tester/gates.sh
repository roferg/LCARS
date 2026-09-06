#!/usr/bin/env bash
# S185 TESTER — the GATE attacks: the ENOENT arms, the fail-closed ordering, and
# a ticket whose implementation never lands (through the STAGE).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/rig.sh"
WORK="$FIX_ROOT/gates"; rm -rf "$WORK"; mkdir -p "$WORK"
export npm_config_cache="${npm_config_cache:-$FIX_ROOT/npmcache}"
T="$(template_blank)"

env_is() { printf '%s' "$1" | bash "$RUN_SH" red-gate-env-detect-test; }  # rc 0 = env failure

echo "=== E. THE ENOENT ARMS (red_gate_env_failure, the shipped detector) ==="
# The exact npm diagnostic a parent commit with NO manifest produces.
NPM_ENOENT="$( cd "$WORK" && npm test 2>&1 )"
printf '%s\n' "$NPM_ENOENT" > "$WORK/npm-enoent.txt"
echo "--- real npm output on a directory with no package.json ---"; cat "$WORK/npm-enoent.txt"
if env_is "$NPM_ENOENT"; then ok "E1. the REAL npm ENOENT output is classified as an ENV FAILURE (⇒ inconclusive, never proof)"
else bad "E1. real npm ENOENT read as a genuine red — a flip-flop could be forged on it"; fi

MISSING_BIN="$(cd "$WORK" && bash -c 'node_modules/.bin/vitest' 2>&1)"
echo "--- a missing runner binary ---"; printf '%s\n' "$MISSING_BIN"
env_is "$MISSING_BIN" && ok "E2. a missing runner BINARY is an env failure" || bad "E2. missing binary not caught: $MISSING_BIN"

# The other direction: an assertion failure that merely QUOTES an ENOENT string
# must STILL be a genuine red.
QUOTED='
 FAIL  test/loader.test.js > reports a helpful message
AssertionError: expected "npm error code ENOENT" to be "npm error enoent Could not read package.json"
  - Expected: npm error enoent Could not read package.json
  + Received: npm error code ENOENT
   at test/loader.test.js:9:12

 Test Files  1 failed (1)
      Tests  1 failed (1)
'
if env_is "$QUOTED"; then bad "E3. an ASSERTION FAILURE quoting ENOENT was swallowed as an env failure — a real red would read inconclusive"
else ok "E3. an assertion failure that merely QUOTES an ENOENT string is still a genuine red"; fi

QUOTED2='
 FAIL  test/msg.test.js
AssertionError: expected "bash: node_modules/.bin/vitest: No such file or directory" to match /ok/
 Test Files  1 failed (1)
'
env_is "$QUOTED2" && bad "E4. a quoted 'No such file or directory' assertion was swallowed as env failure" \
                  || ok "E4. …same for the interpreter's own missing-binary phrasing"

echo
echo "=== F. FAIL-CLOSED: the ordering is unreadable ==="
# Driven at the SHIPPED test hook (`proof-validate-result-test --mission`) rather
# than the stage: the stage sequences tickets from the SAME waves.json, so a
# mission whose ordering is unreadable cannot reach Implement at all.
FR="$(workcopy "$T" gates-failclosed)"
FMD="$(plant_mission "$FR" init-001 t-001 t-002)"
mkdir -p "$FMD/tickets/t-001"
cat > "$WORK/res.json" <<'RJ'
{ "ticketId":"t-001","passed":true,"attempts":1,"summary":"scaffold",
  "newTests":["test/greet.test.js"],"testEdits":[],
  "flipFlop":"not-applicable","flipFlopReason":"this ticket creates the test system" }
RJ
pv() { ( cd "$FR" && bash "$RUN_SH" proof-validate-result-test --mission init-001 \
          --ticket t-001 --result "$WORK/res.json" 2>&1 ); }
echo "--- baseline (ordering intact) ---"; O="$(pv)"; printf '%s\n' "$O"
printf '%s' "$O" | grep -q 'PVRC=0' && ok "F0. with the ordering readable, t-001's waiver is GRANTED" || bad "F0. baseline waiver refused"

printf 'not json at all — truncated mid-write\n' > "$FMD/waves.json"
echo "--- waves.json corrupt, approved-plan.json intact (documented fallback) ---"; O="$(pv)"; printf '%s\n' "$O"
printf '%s' "$O" | grep -q 'PVRC=0' && ok "F1. falls back to the approved plan's row order" || note "F1. refused on the plan fallback: $O"

printf 'garbage\n' > "$FMD/approved-plan.json"; printf 'garbage\n' > "$FMD/plan.json"
echo "--- BOTH orderings unreadable ---"; O="$(pv)"; printf '%s\n' "$O"
if printf '%s' "$O" | grep -q 'PVRC=1'; then
  ok "F2. with NO readable ordering the waiver is REFUSED (fail-closed)"
  note "$(printf '%s' "$O" | grep -o 'the mission ordering could not be read[^"]*' | head -1)"
else bad "F2. FAIL-OPEN — the waiver was granted with no readable ordering: $O"; fi

echo
echo "=== L. A TICKET WHOSE IMPLEMENTATION NEVER LANDS (through the STAGE) ==="
LW="$WORK/land"; mkdir -p "$LW/behav"
cat > "$LW/behav/t-001.sh" <<'B'
#!/usr/bin/env bash
set -u
mkdir -p "$out/setup"
cat > "$out/setup/package.json" <<'PJ'
{ "name":"gf","version":"0.0.0","private":true,"scripts":{"test":"node --test"} }
PJ
printf 'node_modules/\n' > "$out/setup/.gitignore"
cat > "$out/test-setup.json" <<'TS'
{ "package":"", "gap":"no test system", "installCommand":"npm install --no-audit --no-fund" }
TS
mkdir -p src test
printf "module.exports.greet=()=>'hello';\n" > src/greet.js
cat > test/greet.test.js <<'JS'
const {test}=require('node:test');const a=require('node:assert');
const {greet}=require('../src/greet.js');
test('greet',()=>{a.strictEqual(greet(),'hello');});
JS
cat > "$out/result.json" <<'RJ'
{ "ticketId":"t-001","passed":true,"attempts":1,"summary":"scaffold",
  "newTests":["test/greet.test.js"],"testEdits":[],
  "flipFlop":"not-applicable","flipFlopReason":"this ticket creates the test system" }
RJ
B
cat > "$LW/behav/t-002.sh" <<'B'
#!/usr/bin/env bash
set -u
mkdir -p src test
# The implementation is written where it can NEVER reach the committed branch.
printf 'node_modules/\nsrc/add.js\n' > .gitignore
printf "module.exports.add=(a,b)=>a+b;\n" > src/add.js
cat > test/add.test.js <<'JS'
const {test}=require('node:test');const a=require('node:assert');
const {add}=require('../src/add.js');
test('add',()=>{a.strictEqual(add(2,2),4);});
JS
cat > "$out/result.json" <<'RJ'
{ "ticketId":"t-002","passed":true,"attempts":1,"summary":"add",
  "newTests":["test/add.test.js"],"testEdits":[],"flipFlop":"expected" }
RJ
B
chmod +x "$LW/behav"/*.sh
make_worker_shim "$LW/shim" "$LW/behav"; fuse "$LW/shim" || exit 99
LR="$(workcopy "$T" gates-noland)"; LMD="$(plant_mission "$LR" init-001 t-001 t-002)"
stage_drive "$LR" "$LW/shim" init-001
printf '%s\n' "$OUT" > "$WORK/noland.log"; tail -12 "$WORK/noland.log"
if grep -qE 'ticket_postcommit_(red|error)|ticket_postcommit_skipped' "$LMD/events.jsonl" 2>/dev/null; then
  ok "L1. the post-commit gate CAUGHT the ticket whose code never landed"
  note "$(grep -oE '"type":"ticket_postcommit_[a-z]*"' "$LMD/events.jsonl" | tail -2 | tr '\n' ' ')"
else bad "L1. NOT caught: $(grep -oE '"type":"[a-z_]*"' "$LMD/events.jsonl" | tail -6 | tr '\n' ' ')"; fi
[ -f "$LMD/tickets/t-002/result.json" ] && bad "L2. t-002 kept a green result it did not earn" || ok "L2. t-002's undeserved result was DROPPED"
grep -q '"type":"ticket_green".*t-002' "$LMD/events.jsonl" 2>/dev/null \
  && bad "L3. t-002 emitted ticket_green anyway" || ok "L3. t-002 never emitted ticket_green"
LS="$( ls "$LR/.git/lcars/test-landscape" 2>/dev/null | wc -l | tr -d ' ' )"
note "durable test-landscape records written: $LS"

printf '\nGATES: %d ok, %d FAIL   (worker sessions: %d, billable: %d)\n' "$PASS" "$FAIL" "$(spawns)" "$(billable)"
[ "$FAIL" -eq 0 ]
