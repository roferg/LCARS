#!/usr/bin/env bash
#
# Tests for S146 — Stack-Readiness legibility + the one-click file-time fix.
#
# Covers, with ZERO model spend (discovery workers are recording stubs):
#   1. the four-state verdict matrix (ready/missing/broken/unknown) via the
#      shared readiness.sh (--json + --line), incl. the two VOICES: repair
#      (⚠ TEST SYSTEMS OFFLINE) vs bootstrap (greenfield status) — never blurred
#   2. `lcars update --test-command` — the sanctioned manual setter: writes the
#      config, re-verdicts, rejects empty/whitespace legibly
#   3. `lcars update --probe-tests` — bounded one-shot probe reporting all four
#      outcomes (pass / fail / zero-collected / timeout); zero-collected is its
#      own honest outcome, never a pass
#   4. `lcars update --fix-tests` — suggestion path (NO worker spawned),
#      discovery path (worker argv recorded, BOTH engines), garbage/failure ⇒
#      config untouched, probe-fails-after-set ⇒ honestly unverified,
#      greenfield nothing-found ⇒ bootstrap outcome with exit 0
#   5. the status/init/update verdict lines per state; ready silent everywhere
#
# Usage: bash tests/test-readiness.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$REPO_ROOT/skills/lcars-update/update.sh"
INIT="$REPO_ROOT/skills/lcars-init/init.sh"
STATUS="$REPO_ROOT/skills/lcars-status/status.sh"
READINESS="$REPO_ROOT/skills/lcars-init/readiness.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
md5f() { md5 -q "$1" 2>/dev/null || md5sum "$1" | awk '{print $1}'; }

# --- fixtures ---------------------------------------------------------------
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions"
  echo "$repo"
}

# Write a canonical config.json with the given testCommand JSON value (a quoted
# string, or the literal null).
write_config() { # repo testcmd-jsonvalue
  cat >"$1/.git/lcars/config.json" <<JSON
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "stack": "unknown",
  "testCommand": $2,
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "lcarsVersion": "2099.1.1",
  "created": "2020-01-01T00:00:00Z"
}
JSON
}

# A one-mission state so `lcars status` renders a board.
plant_mission() { # repo
  local m="$1/.git/lcars/missions/lcars-20260101-001"
  mkdir -p "$m"
  printf '{"id":"lcars-20260101-001","title":"T","stage":"plan","created":"2026-01-01T00:00:00Z","githubIssue":7}\n' >"$m/state.json"
}

# gh + claude stubs for init.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "view" ]; then echo "owner/repo"; fi
exit 0
EOF
  chmod +x "$1"
}
make_claude_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "2.0.44 (Claude Code)"
EOF
  chmod +x "$1"
}

# A discovery-worker stub dir: file named after the cli (claude|copilot) that
# records its argv (one per line) and writes the canned proposal named in
# $STUB_PROPOSAL_FILE (empty ⇒ writes nothing — the silent worker) to
# $LCARS_DISCOVERY_JSON.
make_worker_stub() { # cli argvfile → echoes the worker path
  local d; d="$(mktemp -d "$TMPROOT/wk.XXXX")"
  cat >"$d/$1" <<EOF
#!/usr/bin/env bash
: >"$2"
for a in "\$@"; do printf '%s\n' "\$a" >>"$2"; done
printf 'ENV_DISCOVERY_JSON=%s\n' "\${LCARS_DISCOVERY_JSON:-}" >>"$2"
if [ -n "\${STUB_PROPOSAL_FILE:-}" ] && [ -f "\${STUB_PROPOSAL_FILE}" ]; then
  cp "\$STUB_PROPOSAL_FILE" "\$LCARS_DISCOVERY_JSON"
fi
exit 0
EOF
  chmod +x "$d/$1"
  printf '%s/%s\n' "$d" "$1"
}

echo "S146 test readiness"

[ -f "$READINESS" ] || { echo "readiness.sh not found at $READINESS"; exit 1; }

# ==========================================================================
# 1. THE VERDICT MATRIX
# ==========================================================================

# ready — testCommand whose first token resolves (echo is everywhere).
repoR="$(new_repo)"
write_config "$repoR" '"echo suite-ok"'
( cd "$repoR" && bash "$READINESS" --json >j.txt 2>&1; bash "$READINESS" --line >l.txt 2>&1 )
check "1. ready: json status is ready"        "grep -q '\"status\":\"ready\"' '$repoR/j.txt'"
check "1. ready: json carries the testCommand" "grep -q 'echo suite-ok' '$repoR/j.txt'"
check "1. ready: line output is EMPTY (silent)" "[ ! -s '$repoR/l.txt' ]"

# broken — testCommand set but the runner does not exist.
repoB="$(new_repo)"
write_config "$repoB" '"no-such-runner-xyz-146 test"'
( cd "$repoB" && bash "$READINESS" --json >j.txt 2>&1; bash "$READINESS" --line >l.txt 2>&1 )
check "1. broken: json status is broken"      "grep -q '\"status\":\"broken\"' '$repoB/j.txt'"
check "1. broken: no suggestion carried"      "grep -q '\"suggestion\":null' '$repoB/j.txt'"
check "1. broken: line uses the REPAIR voice (TEST SYSTEMS OFFLINE)" \
  "grep -q 'TEST SYSTEMS OFFLINE' '$repoB/l.txt'"
check "1. broken: line names the one-click fix verb" \
  "grep -q 'fix-tests' '$repoB/l.txt'"

# missing — no testCommand, detection has a candidate (Makefile test target).
repoM="$(new_repo)"
write_config "$repoM" 'null'
printf 'test:\n\t@echo 1 passed\n' >"$repoM/Makefile"
( cd "$repoM" && bash "$READINESS" --json >j.txt 2>&1; bash "$READINESS" --line >l.txt 2>&1 )
check "1. missing: json status is missing"    "grep -q '\"status\":\"missing\"' '$repoM/j.txt'"
check "1. missing: suggestion carries the detected candidate (make test)" \
  "grep -q '\"suggestion\":\"make test\"' '$repoM/j.txt'"
check "1. missing: line uses the REPAIR voice" \
  "grep -q 'TEST SYSTEMS OFFLINE' '$repoM/l.txt'"

# unknown — no testCommand, no markers at all (greenfield).
repoU="$(new_repo)"
write_config "$repoU" 'null'
( cd "$repoU" && bash "$READINESS" --json >j.txt 2>&1; bash "$READINESS" --line >l.txt 2>&1 )
check "1. unknown: json status is unknown"    "grep -q '\"status\":\"unknown\"' '$repoU/j.txt'"
check "1. unknown: line uses the BOOTSTRAP voice (engineering crew)" \
  "grep -qi 'engineering crew' '$repoU/l.txt'"
check "1. unknown: bootstrap line is NOT an alarm (no OFFLINE, no ⚠)" \
  "! grep -q 'OFFLINE' '$repoU/l.txt' && ! grep -q '⚠' '$repoU/l.txt'"
check "1. the two unready voices differ (repair ≠ bootstrap)" \
  "! cmp -s '$repoB/l.txt' '$repoU/l.txt'"

# ambiguous stack (rust + js) — no candidate ⇒ unknown, never a guessed pick.
repoA="$(new_repo)"
write_config "$repoA" 'null'
printf '[package]\nname="x"\n' >"$repoA/Cargo.toml"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoA/package.json"
( cd "$repoA" && bash "$READINESS" --json >j.txt 2>&1 )
check "1. ambiguous stack: verdict is unknown (no guessed suggestion)" \
  "grep -q '\"status\":\"unknown\"' '$repoA/j.txt'"

# ==========================================================================
# 2. --test-command : the sanctioned manual setter
# ==========================================================================
repoS="$(new_repo)"
write_config "$repoS" 'null'
( cd "$repoS" && bash "$UPDATE" --test-command 'echo my-suite' >outS.txt 2>&1 )
rcS=$?
cfgS="$repoS/.git/lcars/config.json"
check "2. set: exits zero"                    "[ '$rcS' -eq 0 ]"
check "2. set: writes the command into config.json" \
  "grep -q '\"testCommand\": \"echo my-suite\"' '$cfgS'"
check "2. set: config stays VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cfgS'"
check "2. set: other keys preserved (model untouched)" \
  "grep -q '\"model\": \"claude-sonnet\"' '$cfgS'"
check "2. set: prints the command it set"     "grep -q 'echo my-suite' '$repoS/outS.txt'"
check "2. set: re-verdicts to ONLINE (first token resolves)" \
  "grep -q 'TEST SYSTEMS ONLINE' '$repoS/outS.txt'"

# set to a broken runner → verdict line is honest (broken, not online).
repoS2="$(new_repo)"
write_config "$repoS2" 'null'
( cd "$repoS2" && bash "$UPDATE" --test-command 'no-such-runner-xyz-146 go' >outS2.txt 2>&1 )
check "2. set(broken runner): value written anyway (captain's explicit order)" \
  "grep -q 'no-such-runner-xyz-146' '$repoS2/.git/lcars/config.json'"
check "2. set(broken runner): verdict line reports OFFLINE, never ONLINE" \
  "grep -q 'TEST SYSTEMS OFFLINE' '$repoS2/outS2.txt' && ! grep -q 'TEST SYSTEMS ONLINE' '$repoS2/outS2.txt'"

# empty / whitespace-only rejected legibly, config untouched.
repoE="$(new_repo)"
write_config "$repoE" '"echo original"'
cfgE_before="$(md5f "$repoE/.git/lcars/config.json")"
rcE=0
( cd "$repoE" && bash "$UPDATE" --test-command '   ' >outE.txt 2>&1 ) || rcE=$?
check "2. empty set: exits non-zero"          "[ '$rcE' -ne 0 ]"
check "2. empty set: message is legible (names the flag usage)" \
  "grep -qi 'test command' '$repoE/outE.txt' && grep -q 'test-command' '$repoE/outE.txt'"
check "2. empty set: config untouched byte-for-byte" \
  "[ \"\$(md5f '$repoE/.git/lcars/config.json')\" = '$cfgE_before' ]"

# an OLD config with NO testCommand line: the setter ADDS the key (valid JSON).
repoOld="$(new_repo)"
cat >"$repoOld/.git/lcars/config.json" <<'JSON'
{
  "model": "claude-sonnet",
  "projectName": "p",
  "created": "2019-01-01T00:00:00Z"
}
JSON
( cd "$repoOld" && bash "$UPDATE" --test-command 'echo added' >outOld.txt 2>&1 )
check "2. old config without the key: setter ADDS testCommand" \
  "grep -q '\"testCommand\": \"echo added\"' '$repoOld/.git/lcars/config.json'"
check "2. old config: result is VALID JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repoOld/.git/lcars/config.json'"

# ==========================================================================
# 3. --probe-tests : bounded one-shot probe, four outcomes
# ==========================================================================

# pass
repoP1="$(new_repo)"
write_config "$repoP1" '"true"'
rcP1=0
( cd "$repoP1" && bash "$UPDATE" --probe-tests >outP1.txt 2>&1 ) || rcP1=$?
check "3. probe pass: exits zero"             "[ '$rcP1' -eq 0 ]"
check "3. probe pass: reports the suite ran and passed" \
  "grep -qi 'ran and passed' '$repoP1/outP1.txt'"

# fail
repoP2="$(new_repo)"
write_config "$repoP2" '"bash -c \"echo 2 failed; exit 1\""'
rcP2=0
( cd "$repoP2" && bash "$UPDATE" --probe-tests >outP2.txt 2>&1 ) || rcP2=$?
check "3. probe fail: exits non-zero"         "[ '$rcP2' -ne 0 ]"
check "3. probe fail: reports failures plainly" \
  "grep -qi 'PROBE FAILED' '$repoP2/outP2.txt'"
check "3. probe fail: includes the runner's tail output" \
  "grep -q '2 failed' '$repoP2/outP2.txt'"

# zero-collected — runner exits 0 but collected nothing (the honest non-pass).
repoP3="$(new_repo)"
write_config "$repoP3" '"echo No test files found"'
rcP3=0
( cd "$repoP3" && bash "$UPDATE" --probe-tests >outP3.txt 2>&1 ) || rcP3=$?
check "3. probe zero-collected: exits non-zero (not a pass)" "[ '$rcP3' -ne 0 ]"
check "3. probe zero-collected: reports INCONCLUSIVE / zero tests" \
  "grep -qi 'ZERO tests' '$repoP3/outP3.txt'"
check "3. probe zero-collected: never claims the suite passed" \
  "! grep -qi 'ran and passed' '$repoP3/outP3.txt'"

# timeout — bounded by LCARS_PROBE_TIMEOUT (perl select = no sleep binary).
repoP4="$(new_repo)"
write_config "$repoP4" '"perl -e \"select(undef,undef,undef,5)\""'
rcP4=0
( cd "$repoP4" && LCARS_PROBE_TIMEOUT=1 bash "$UPDATE" --probe-tests >outP4.txt 2>&1 ) || rcP4=$?
check "3. probe timeout: exits non-zero"      "[ '$rcP4' -ne 0 ]"
check "3. probe timeout: reports the bound (never settled)" \
  "grep -qi 'TIMED OUT' '$repoP4/outP4.txt'"

# no testCommand → legible refusal.
repoP5="$(new_repo)"
write_config "$repoP5" 'null'
rcP5=0
( cd "$repoP5" && bash "$UPDATE" --probe-tests >outP5.txt 2>&1 ) || rcP5=$?
check "3. probe with no command: refuses legibly (points at the setters)" \
  "[ '$rcP5' -ne 0 ] && grep -qi 'no testCommand' '$repoP5/outP5.txt' && grep -q 'fix-tests' '$repoP5/outP5.txt'"

# ==========================================================================
# 4. --fix-tests : suggestion path, discovery path, garbage, greenfield
# ==========================================================================

# 4a. suggestion present ⇒ set + probe in ONE invocation, NO worker spawned.
repoF1="$(new_repo)"
write_config "$repoF1" 'null'
printf 'test:\n\t@echo 1 passed\n' >"$repoF1/Makefile"
argvF1="$repoF1/worker-argv.txt"
wkF1="$(make_worker_stub claude "$argvF1")"
rcF1=0
( cd "$repoF1" && LCARS_WORKER_BIN="$wkF1" bash "$UPDATE" --fix-tests >outF1.txt 2>&1 ) || rcF1=$?
check "4a. suggestion path: exits zero"       "[ '$rcF1' -eq 0 ]"
check "4a. suggestion path: NO discovery worker spawned" "[ ! -s '$argvF1' ]"
check "4a. suggestion path: sets the detected candidate" \
  "grep -q '\"testCommand\": \"make test\"' '$repoF1/.git/lcars/config.json'"
check "4a. suggestion path: probes in the SAME invocation" \
  "grep -qi 'ran and passed' '$repoF1/outF1.txt'"
check "4a. suggestion path: final verdict is ONLINE" \
  "grep -q 'TEST SYSTEMS ONLINE' '$repoF1/outF1.txt'"

# 4b. probe fails after set ⇒ honestly SET BUT UNVERIFIED, never ready.
repoF2="$(new_repo)"
write_config "$repoF2" 'null'
printf 'test:\n\t@exit 1\n' >"$repoF2/Makefile"
rcF2=0
( cd "$repoF2" && bash "$UPDATE" --fix-tests >outF2.txt 2>&1 ) || rcF2=$?
check "4b. probe-fails-after-set: exits non-zero" "[ '$rcF2' -ne 0 ]"
check "4b. probe-fails-after-set: command IS set (the sanctioned write happened)" \
  "grep -q '\"testCommand\": \"make test\"' '$repoF2/.git/lcars/config.json'"
check "4b. probe-fails-after-set: verdict is SET BUT UNVERIFIED" \
  "grep -qi 'SET BUT UNVERIFIED' '$repoF2/outF2.txt'"
check "4b. probe-fails-after-set: never declares ONLINE/ready" \
  "! grep -q 'TEST SYSTEMS ONLINE' '$repoF2/outF2.txt'"

# 4c. no suggestion ⇒ discovery worker (argv recorded), proposal set + probed.
#     Run on BOTH engines (claude + copilot) — the worker-adapter owns the argv.
for engine in claude copilot; do
  repoF3="$(new_repo)"
  write_config "$repoF3" 'null'
  printf '#!/usr/bin/env bash\necho 3 passed\nexit 0\n' >"$repoF3/mytests.sh"
  chmod +x "$repoF3/mytests.sh"
  argvF3="$repoF3/worker-argv.txt"
  wkF3="$(make_worker_stub "$engine" "$argvF3")"
  propF3="$repoF3/proposal.json"
  printf '{\n  "testCommand": "bash mytests.sh",\n  "rationale": "repo ships a bespoke runner script",\n  "status": "ready"\n}\n' >"$propF3"
  rcF3=0
  ( cd "$repoF3" && STUB_PROPOSAL_FILE="$propF3" LCARS_WORKER_BIN="$wkF3" \
      bash "$UPDATE" --fix-tests >outF3.txt 2>&1 ) || rcF3=$?
  check "4c[$engine]. discovery path: exits zero" "[ '$rcF3' -eq 0 ]"
  check "4c[$engine]. discovery worker argv recorded (stub spawned)" \
    "[ -s '$argvF3' ]"
  check "4c[$engine]. worker got the discovery answer path via env" \
    "grep -q 'ENV_DISCOVERY_JSON=.*test-discovery.json' '$argvF3'"
  check "4c[$engine]. worker argv carries the -p prompt naming the answer path" \
    "grep -q 'test-discovery.json' '$argvF3'"
  check "4c[$engine]. proposal set into config" \
    "grep -q '\"testCommand\": \"bash mytests.sh\"' '$repoF3/.git/lcars/config.json'"
  check "4c[$engine]. proposal probed + ONLINE in the same invocation" \
    "grep -qi 'ran and passed' '$repoF3/outF3.txt' && grep -q 'TEST SYSTEMS ONLINE' '$repoF3/outF3.txt'"
  check "4c[$engine]. the crew's rationale is surfaced" \
    "grep -qi 'bespoke runner' '$repoF3/outF3.txt'"
done

# 4d. worker garbage (status failed) on a repo that HAS infra (broken command)
#     ⇒ config untouched + repair voice + non-zero.
repoF4="$(new_repo)"
write_config "$repoF4" '"no-such-runner-xyz-146 test"'
cfgF4_before="$(md5f "$repoF4/.git/lcars/config.json")"
argvF4="$repoF4/worker-argv.txt"
wkF4="$(make_worker_stub claude "$argvF4")"
propF4="$repoF4/proposal.json"
printf '{\n  "status": "failed",\n  "message": "could not identify a runner"\n}\n' >"$propF4"
rcF4=0
( cd "$repoF4" && STUB_PROPOSAL_FILE="$propF4" LCARS_WORKER_BIN="$wkF4" \
    bash "$UPDATE" --fix-tests >outF4.txt 2>&1 ) || rcF4=$?
check "4d. broken repo + failed discovery: exits non-zero" "[ '$rcF4' -ne 0 ]"
check "4d. broken repo + failed discovery: config UNTOUCHED byte-for-byte" \
  "[ \"\$(md5f '$repoF4/.git/lcars/config.json')\" = '$cfgF4_before' ]"
check "4d. broken repo + failed discovery: repair voice, legible report" \
  "grep -qi 'REPAIR INCOMPLETE' '$repoF4/outF4.txt' && grep -qi 'could not identify a runner' '$repoF4/outF4.txt'"
check "4d. broken repo + failed discovery: NOT the bootstrap voice" \
  "! grep -qi 'engineering crew' '$repoF4/outF4.txt'"

# 4e. SILENT worker (writes nothing) on a greenfield repo ⇒ bootstrap OUTCOME,
#     exit 0, config untouched — the happy path, not an error.
repoF5="$(new_repo)"
write_config "$repoF5" 'null'
cfgF5_before="$(md5f "$repoF5/.git/lcars/config.json")"
argvF5="$repoF5/worker-argv.txt"
wkF5="$(make_worker_stub claude "$argvF5")"
rcF5=0
( cd "$repoF5" && LCARS_WORKER_BIN="$wkF5" bash "$UPDATE" --fix-tests >outF5.txt 2>&1 ) || rcF5=$?
check "4e. greenfield + nothing found: exits ZERO (expected, not an error)" \
  "[ '$rcF5' -eq 0 ]"
check "4e. greenfield + nothing found: bootstrap voice as the OUTCOME" \
  "grep -qi 'engineering crew' '$repoF5/outF5.txt'"
check "4e. greenfield + nothing found: filing named unaffected" \
  "grep -qi 'filing' '$repoF5/outF5.txt'"
check "4e. greenfield + nothing found: config untouched" \
  "[ \"\$(md5f '$repoF5/.git/lcars/config.json')\" = '$cfgF5_before' ]"
check "4e. greenfield + nothing found: NOT the repair-failure voice" \
  "! grep -qi 'REPAIR INCOMPLETE' '$repoF5/outF5.txt'"

# 4f. garbage proposal (ready but empty command) ⇒ config untouched.
repoF6="$(new_repo)"
write_config "$repoF6" '"no-such-runner-xyz-146 t"'
cfgF6_before="$(md5f "$repoF6/.git/lcars/config.json")"
argvF6="$repoF6/worker-argv.txt"
wkF6="$(make_worker_stub claude "$argvF6")"
propF6="$repoF6/proposal.json"
printf '{\n  "testCommand": "   ",\n  "status": "ready"\n}\n' >"$propF6"
rcF6=0
( cd "$repoF6" && STUB_PROPOSAL_FILE="$propF6" LCARS_WORKER_BIN="$wkF6" \
    bash "$UPDATE" --fix-tests >outF6.txt 2>&1 ) || rcF6=$?
check "4f. garbage proposal: exits non-zero + config untouched" \
  "[ '$rcF6' -ne 0 ] && [ \"\$(md5f '$repoF6/.git/lcars/config.json')\" = '$cfgF6_before' ]"

# 4g. already ready ⇒ nothing to repair, exit 0, no worker.
repoF7="$(new_repo)"
write_config "$repoF7" '"echo fine"'
argvF7="$repoF7/worker-argv.txt"
wkF7="$(make_worker_stub claude "$argvF7")"
rcF7=0
( cd "$repoF7" && LCARS_WORKER_BIN="$wkF7" bash "$UPDATE" --fix-tests >outF7.txt 2>&1 ) || rcF7=$?
check "4g. already ready: exit 0 + ONLINE + no worker" \
  "[ '$rcF7' -eq 0 ] && grep -q 'TEST SYSTEMS ONLINE' '$repoF7/outF7.txt' && [ ! -s '$argvF7' ]"

# ==========================================================================
# 5. SURFACE LINES — status / init / update, per state; ready silent
# ==========================================================================

# status: broken repo → repair header; ready repo → silent; greenfield → bootstrap.
repoH1="$(new_repo)"
write_config "$repoH1" '"no-such-runner-xyz-146 t"'
plant_mission "$repoH1"
( cd "$repoH1" && bash "$STATUS" >outH1.txt 2>&1 )
check "5. status(broken): shows the OFFLINE repair header" \
  "grep -q 'TEST SYSTEMS OFFLINE' '$repoH1/outH1.txt'"
check "5. status(broken): the board still renders (mission row present)" \
  "grep -q 'lcars-20260101-001' '$repoH1/outH1.txt'"

repoH2="$(new_repo)"
write_config "$repoH2" '"echo fine"'
plant_mission "$repoH2"
( cd "$repoH2" && bash "$STATUS" >outH2.txt 2>&1 )
check "5. status(ready): NO readiness line at all (silent)" \
  "! grep -q 'TEST SYSTEMS' '$repoH2/outH2.txt' && ! grep -qi 'engineering crew' '$repoH2/outH2.txt'"

repoH3="$(new_repo)"
write_config "$repoH3" 'null'
plant_mission "$repoH3"
( cd "$repoH3" && bash "$STATUS" >outH3.txt 2>&1 )
check "5. status(greenfield): bootstrap voice, not the alarm" \
  "grep -qi 'engineering crew' '$repoH3/outH3.txt' && ! grep -q 'OFFLINE' '$repoH3/outH3.txt'"

# update readout: broken → OFFLINE line; ready → silent.
repoH4="$(new_repo)"
write_config "$repoH4" '"no-such-runner-xyz-146 t"'
make_gh_stub "$repoH4/gh"
( cd "$repoH4" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repoH4/gh" bash "$UPDATE" >outH4.txt 2>&1 )
check "5. update(broken): readout carries the OFFLINE line" \
  "grep -q 'TEST SYSTEMS OFFLINE' '$repoH4/outH4.txt'"
repoH5="$(new_repo)"
write_config "$repoH5" '"echo fine"'
make_gh_stub "$repoH5/gh"
( cd "$repoH5" && LCARS_VERSION="2099.1.1" LCARS_GH_BIN="$repoH5/gh" bash "$UPDATE" >outH5.txt 2>&1 )
check "5. update(ready): silent — no readiness chatter" \
  "! grep -q 'TEST SYSTEMS' '$repoH5/outH5.txt' && ! grep -qi 'engineering crew' '$repoH5/outH5.txt'"

# plain update NEVER writes testCommand (fix is the only writer).
check "5. plain update never clobbers/wrote testCommand (broken repo keeps its value)" \
  "grep -q 'no-such-runner-xyz-146' '$repoH4/.git/lcars/config.json'"

# init readout: greenfield → bootstrap voice; ready-ish repo → silent.
repoH6="$(new_repo)"
make_gh_stub "$repoH6/gh"; make_claude_stub "$repoH6/claude"
( cd "$repoH6" && LCARS_CLAUDE_BIN="$repoH6/claude" LCARS_GH_BIN="$repoH6/gh" bash "$INIT" >outH6.txt 2>&1 )
check "5. init(greenfield): bootstrap voice in the readout" \
  "grep -qi 'engineering crew' '$repoH6/outH6.txt'"
check "5. init(greenfield): not the alarm voice" \
  "! grep -q 'TEST SYSTEMS OFFLINE' '$repoH6/outH6.txt'"
# D1 (S146 fix loop): a greenfield repo is EXPECTED — the readout must be ONE
# calm bootstrap status, never the legacy '⚠ no known stack' alarm + a
# hand-edit-config.json lecture stacked on top of the bootstrap line.
check "5. init(greenfield): NO alarm-glyph line at all (one calm status)" \
  "! grep -q '⚠' '$repoH6/outH6.txt'"
check "5. init(greenfield): no legacy 'no known stack' config lecture" \
  "! grep -qi 'no known stack' '$repoH6/outH6.txt'"
check "5. init(greenfield): never tells the captain to hand-edit config.json" \
  "! grep -q 'set testCommand in' '$repoH6/outH6.txt'"
# …while the S105 AMBIGUOUS-stack warning (repair-adjacent, names the candidate
# stacks) is PRESERVED — only the greenfield voice was re-ruled.
repoH8="$(new_repo)"
make_gh_stub "$repoH8/gh"; make_claude_stub "$repoH8/claude"
printf '[package]\nname="x"\n' >"$repoH8/Cargo.toml"
printf '{ "scripts": { "test": "jest" } }\n' >"$repoH8/package.json"
( cd "$repoH8" && LCARS_CLAUDE_BIN="$repoH8/claude" LCARS_GH_BIN="$repoH8/gh" bash "$INIT" >outH8.txt 2>&1 )
check "5. init(ambiguous stack): the S105 warning naming candidates is PRESERVED" \
  "grep -q 'multiple stacks detected' '$repoH8/outH8.txt' && grep -qi 'rust' '$repoH8/outH8.txt'"

repoH7="$(new_repo)"
make_gh_stub "$repoH7/gh"; make_claude_stub "$repoH7/claude"
printf 'test:\n\t@echo ok\n' >"$repoH7/Makefile"
( cd "$repoH7" && LCARS_CLAUDE_BIN="$repoH7/claude" LCARS_GH_BIN="$repoH7/gh" bash "$INIT" >outH7.txt 2>&1 )
check "5. init(make repo, runner resolves): silent — no OFFLINE, no crew line" \
  "! grep -q 'TEST SYSTEMS OFFLINE' '$repoH7/outH7.txt' && ! grep -qi 'engineering crew' '$repoH7/outH7.txt'"

# ==========================================================================
echo
printf 'S146 test readiness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
