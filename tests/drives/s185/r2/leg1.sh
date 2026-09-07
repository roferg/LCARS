#!/usr/bin/env bash
# S185 ROUND-2 TESTER — PRIORITY 1, BUILT FROM SCRATCH.
# Self-contained: does NOT source round 1's rig.sh. Its own escape-safe reader
# (python3 json), its own spend fuse, its own shim.
set -uo pipefail
LCARS_SRC=/Users/roganferguson/Projects/LCARS
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
FIX="${TMPDIR:-/tmp}lcars-s185"; FIX="${FIX%/}"
W="$FIX/r2-leg1"; rm -rf "$W"; mkdir -p "$W"
SPEND="$FIX/spend.log"; [ -f "$SPEND" ] || : > "$SPEND"
export npm_config_cache="$FIX/npmcache"
VITEST_VER="${VITEST_VER:-3.2.7}"

BEHAV="$W/behav"; SHIM="$W/shim"; mkdir -p "$BEHAV" "$SHIM"

# --- my own counting shim, BOTH binaries (the spend fuse) --------------------
for b in claude copilot; do
  cat > "$SHIM/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*) printf 'PROBE\tr2\t%s\n' "\$(basename \$0)" >> "$SPEND"; echo "0.0.0-r2-fake"; exit 0 ;;
esac
printf 'SPAWN\tr2\t%s\t%s\t%s\n' "\$(basename \$0)" "\${LCARS_WORKER_ROLE:-?}" "\$(printf '%s' "\$*" | tr '\n' ' ' | head -c 160)" >> "$SPEND"
out="\${LCARS_WORK_OUT:-}"; [ -n "\$out" ] || exit 0
prompt="\$2"
tid="\$(printf '%s\n' "\$prompt" | awk '/^## Your ticket\$/{getline; print; exit}' | grep -oE 't-[0-9]+' | head -1)"
mkdir -p "$BEHAV/prompts"; printf '%s\n' "\$prompt" > "$BEHAV/prompts/\${LCARS_WORKER_ROLE:-role}.\${tid:-none}.txt" 2>/dev/null || :
[ "\${LCARS_WORKER_ROLE:-}" = implement-tdd ] || exit 0
[ -n "\$tid" ] && [ -x "$BEHAV/\$tid.sh" ] && out="\$out" TID="\$tid" bash "$BEHAV/\$tid.sh"
exit 0
SH
  chmod +x "$SHIM/$b"
done
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "FUSE TRIPPED"; exit 99; }

# --- ticket behaviours ------------------------------------------------------
cat > "$BEHAV/t-001.sh" <<BEH
#!/usr/bin/env bash
set -u
mkdir -p "\$out/setup"
cat > "\$out/setup/package.json" <<'PJ'
{ "name": "r2-app", "version": "0.0.0", "private": true, "type": "module",
  "scripts": { "test": "vitest run" } }
PJ
printf 'node_modules/\n' > "\$out/setup/.gitignore"
cat > "\$out/test-setup.json" <<'TS'
{ "package": "",
  "gap": "this repository has no test system at all",
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
  "flipFlopReason": "this ticket CREATES the repo test system with vitest, so its parent commit has no runner for the new test to be red against; the captain watches the suite run at Verify" }
RJ
BEH
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
  "newTests": ["test/add.test.js"], "testEdits": [], "flipFlop": "expected" }
RJ
BEH
chmod +x "$BEHAV"/t-*.sh

# --- a genuinely blank repo (my own, not the shared template) ---------------
REPO="$W/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@e.x; git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
printf '# r2-blank\n\nno code, no tests.\n' > "$REPO/README.md"
printf '# ctx\nday zero.\n' > "$REPO/CONTEXT.md"
git -C "$REPO" add -A >/dev/null; git -C "$REPO" commit -qm "initial commit" >/dev/null
mkdir -p "$REPO/.git/lcars/missions"
printf '{\n  "version": 1\n}\n' > "$REPO/.git/lcars/config.json"

MID=init-r2
MD="$REPO/.git/lcars/missions/$MID"; mkdir -p "$MD/tickets" "$MD/manifests"
BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"
cat > "$MD/state.json" <<JSON
{ "id": "$MID", "missionType": "initialization", "type": "feature",
  "title": "Establish the foundation", "stage": "implement",
  "branch": "lcars/$MID", "base": "$BASE",
  "workerBin": "claude", "workerCli": "claude" }
JSON
cat > "$MD/prd.md" <<'MD2'
# Mission: Establish the foundation
**Type:** feature
**Goal:** A running skeleton with a working test system.
**Acceptance Criteria:**
- one command runs the suite
MD2
cat > "$MD/approved-plan.json" <<'PJ2'
[
  { "id": "t-001", "title": "ticket t-001", "description": "one slice",
    "acceptanceCriteria": ["it works"], "dependencies": [] },
  { "id": "t-002", "title": "ticket t-002", "description": "one slice",
    "acceptanceCriteria": ["it works"], "dependencies": [] }
]
PJ2
cp "$MD/approved-plan.json" "$MD/plan.json"
cat > "$MD/waves.json" <<'WJ'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": null
      }
    ]
  }
]
WJ
printf '## Relevant files\n- src/a.js\n' > "$MD/manifests/t-001.md"
printf '## Relevant files\n- src/b.js\n' > "$MD/manifests/t-002.md"

echo "=== R2 LEG 1 — blank repo, STAGE entry point (run.sh implement) ==="
echo "repo:    $REPO"
echo "mission: $MID"
echo "--- foundation gate BEFORE ---"
( cd "$REPO" && bash "$LCARS_SRC/skills/lcars-init/foundation-gate.sh" 2>&1; echo "GATE_RC=$?" )
echo "--- config BEFORE ---"; cat "$REPO/.git/lcars/config.json"

S0=$(grep -c '^SPAWN' "$SPEND" 2>/dev/null || echo 0)
echo "--- run.sh implement ---"
( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
    LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 LCARS_SETUP_INSTALL_TIMEOUT_SECS=900 \
    LCARS_VERSION_CHECK=0 bash "$RUN_SH" implement --mission "$MID" ) > "$W/stage.log" 2>&1
echo "stage rc=$?"
S1=$(grep -c '^SPAWN' "$SPEND" 2>/dev/null || echo 0)
echo "worker spawns this leg: $((S1-S0))"
tail -40 "$W/stage.log"
echo "--- stage now ---"; python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["stage"])' "$MD/state.json"
echo "ARTIFACTS: $W"
