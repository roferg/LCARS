#!/usr/bin/env bash
# S185 TESTER — REGRESSION. A repo that ALREADY has a foundation is untouched,
# end to end, on a NORMAL mission — including that a normal mission's waiver
# (comment-only refactor) still WORKS.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/rig.sh"
WORK="$FIX_ROOT/regress"; rm -rf "$WORK"; mkdir -p "$WORK/behav"
export npm_config_cache="${npm_config_cache:-$FIX_ROOT/npmcache}"

# --- a REAL repo that already runs tests -----------------------------------
READY="$FIX_ROOT/gf-ready"
if [ ! -d "$READY/.git" ]; then
  mkdir -p "$READY/src" "$READY/test"
  git -C "$READY" init -q 2>/dev/null || (cd "$READY" && git init -q)
  git -C "$READY" config user.email t@e.x; git -C "$READY" config user.name t
  git -C "$READY" config commit.gpgsign false
  cat > "$READY/package.json" <<'PJ'
{ "name":"ready","version":"1.0.0","private":true,"scripts":{"test":"node --test"} }
PJ
  printf 'node_modules/\n' > "$READY/.gitignore"
  printf '# ctx\n' > "$READY/CONTEXT.md"
  printf "// a helper\nmodule.exports.greet=()=>'hi';\n" > "$READY/src/greet.js"
  cat > "$READY/test/greet.test.js" <<'JS'
const {test}=require('node:test');const a=require('node:assert');
const {greet}=require('../src/greet.js');
test('greet',()=>{a.strictEqual(greet(),'hi');});
JS
  git -C "$READY" add -A >/dev/null 2>&1; git -C "$READY" commit -qm init >/dev/null 2>&1
  mkdir -p "$READY/.git/lcars/missions"
  cat > "$READY/.git/lcars/config.json" <<'CJ'
{
  "version": 1,
  "testCommand": "npm test"
}
CJ
fi
R="$(workcopy "$READY" reg-ready)"
CFG_BEFORE="$(cat "$R/.git/lcars/config.json")"

# a NORMAL mission — no missionType key at all
MD="$(plant_mission "$R" lcars-20260906-900 t-001 t-002)"
python3 - "$MD/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.pop("missionType",None)
d["title"]="A normal mission"; d["githubIssue"]=7
json.dump(d,open(p,"w"),indent=2)
PY
grep -q missionType "$MD/state.json" && bad "R0. fixture still says initialization" || ok "R0. the mission is a NORMAL mission (no missionType)"

cat > "$WORK/behav/t-001.sh" <<'B'
#!/usr/bin/env bash
set -u
mkdir -p src test
printf "module.exports.add=(a,b)=>a+b;\n" > src/add.js
cat > test/add.test.js <<'JS'
const {test}=require('node:test');const a=require('node:assert');
const {add}=require('../src/add.js');
test('add',()=>{a.strictEqual(add(2,2),4);});
JS
cat > "$out/result.json" <<'RJ'
{ "ticketId":"t-001","passed":true,"attempts":1,"summary":"add",
  "newTests":["test/add.test.js"],"testEdits":[],"flipFlop":"expected" }
RJ
B
# THE NORMAL WAIVER: a comment-only refactor. No new tests, nothing to flip.
cat > "$WORK/behav/t-002.sh" <<'B'
#!/usr/bin/env bash
set -u
printf "// a helper that greets\n// (comment-only refactor: no behaviour change)\nmodule.exports.greet=()=>'hi';\n" > src/greet.js
cat > "$out/result.json" <<'RJ'
{ "ticketId":"t-002","passed":true,"attempts":1,
  "summary":"comment-only refactor of the greet helper",
  "newTests":[],"testEdits":[],
  "flipFlop":"not-applicable",
  "flipFlopReason":"comment-only change: no behaviour is added or altered, so no test can be red on the parent and green on the tip" }
RJ
B
chmod +x "$WORK/behav"/*.sh
make_worker_shim "$WORK/shim" "$WORK/behav"; fuse "$WORK/shim" || exit 99

echo "=== driving a NORMAL mission on a repo that already has a foundation ==="
stage_drive "$R" "$WORK/shim" lcars-20260906-900
printf '%s\n' "$OUT" > "$WORK/stage.log"; tail -20 "$WORK/stage.log"

grep -q 'test_setup_invited' "$MD/events.jsonl" 2>/dev/null \
  && bad "R1. the scaffold door OPENED on a normal mission" || ok "R1. the scaffold door never opened"
[ -f "$MD/test-command.json" ] && bad "R2. a mission-local runner record was written" || ok "R2. no mission-local runner record"
[ "$(cat "$R/.git/lcars/config.json")" = "$CFG_BEFORE" ] \
  && ok "R3. repo config.json is byte-identical after the whole mission" || bad "R3. repo config CHANGED: $(cat "$R/.git/lcars/config.json")"
[ -f "$MD/tickets/t-001/result.json" ] && ok "R4. t-001 (a real flip-flop) passed" || bad "R4. t-001 did not pass"
if [ -f "$MD/tickets/t-002/result.json" ]; then
  ok "R5. THE NORMAL WAIVER STILL WORKS — a comment-only refactor passes on not-applicable"
else
  bad "R5. the normal waiver was REJECTED on a normal mission: $(python3 -c "
import json,sys
try: print(json.load(open('$MD/pending.json'))['technicalDetail'][:400])
except Exception as e: print(e)")"
fi
S="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["stage"])' "$MD/state.json")"
[ "$S" = verify ] && ok "R6. the normal mission advanced to verify" || bad "R6. stage=$S"

echo "--- Verify readout for the NORMAL mission ---"
run_sub "$R" "$WORK/shim" bash "$RUN_SH" verify-summary --mission lcars-20260906-900
printf '%s\n' "$OUT"

echo "--- approve on a NORMAL mission must NOT promote anything ---"
GH="$WORK/gh"; cat > "$GH" <<'GHS'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = create ]; then echo "https://github.com/acme/r/pull/9"; fi
exit 0
GHS
chmod +x "$GH"
cat > "$WORK/recon.sh" <<'X'
#!/usr/bin/env bash
exit 0
X
chmod +x "$WORK/recon.sh"
python3 - "$MD/state.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["prUrl"]="https://github.com/acme/r/pull/9";d["prNumber"]=9
json.dump(d,open(p,"w"),indent=2)
PY
AO="$( cd "$R" && env PATH="$WORK/shim:$PATH" LCARS_GH_BIN="$GH" LCARS_VERSION_CHECK=0 \
    LCARS_GIT_BIN="$(command -v git)" LCARS_RUN_SCRIPT="$WORK/recon.sh" \
    bash "$APPROVE_SH" --mission lcars-20260906-900 2>&1 )"
printf '%s\n' "$AO"
printf '%s' "$AO" | grep -q 'FOUNDATION ESTABLISHED' && bad "R7. approve promoted on a NORMAL mission" || ok "R7. approve promoted nothing on a normal mission"
printf '%s' "$AO" | grep -qi 'recorded no established test command' && bad "R8. approve nagged a normal mission about a test command" || ok "R8. …and said nothing about foundations"
[ "$(cat "$R/.git/lcars/config.json")" = "$CFG_BEFORE" ] \
  && ok "R9. repo config still byte-identical after approve" || bad "R9. repo config changed at approve"

printf '\nREGRESSION: %d ok, %d FAIL   (worker sessions: %d, billable: %d)\n' "$PASS" "$FAIL" "$(spawns)" "$(billable)"
[ "$FAIL" -eq 0 ]
