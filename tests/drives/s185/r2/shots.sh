#!/usr/bin/env bash
# S185 — the three screens, on a REAL daemon + REAL repo + REAL headed Chrome.
# Zero spend: the counting shim + the fuse.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../tester/rig.sh"
SHOTS="/private/tmp/claude-501/-Users-roganferguson-Projects-lcars-dev/2c448f19-3d03-4296-926a-b442ce6c195f/scratchpad/s185-shots"; rm -rf "$SHOTS"; mkdir -p "$SHOTS"
WORK="$FIX_ROOT/r2-shots"; rm -rf "$WORK"; mkdir -p "$WORK/behav"
export npm_config_cache="${npm_config_cache:-$FIX_ROOT/npmcache}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "SKIP 77: no Chrome"; exit 77; }

# ---- drive a REAL initialization mission to VERIFY (vitest, the captain's case)
cat > "$WORK/behav/t-001.sh" <<'B'
#!/usr/bin/env bash
set -u
mkdir -p "$out/setup"
cat > "$out/setup/package.json" <<'PJ'
{ "name":"gf-app","version":"0.0.0","private":true,"type":"module","scripts":{"test":"vitest run"} }
PJ
printf 'node_modules/\n' > "$out/setup/.gitignore"
cat > "$out/test-setup.json" <<'TS'
{ "package":"", "gap":"this repository has no test system at all",
  "installCommand":"npm install --no-audit --no-fund --save-dev vitest@3.2.7" }
TS
mkdir -p src test
printf "export const greet = () => 'hello';\n" > src/greet.js
cat > test/greet.test.js <<'JS'
import { test, expect } from 'vitest';
import { greet } from '../src/greet.js';
test('greet says hello', () => { expect(greet()).toBe('hello'); });
JS
cat > "$out/result.json" <<'RJ'
{ "ticketId":"t-001","passed":true,"attempts":1,
  "summary":"establish the project skeleton and its vitest test system",
  "newTests":["test/greet.test.js"],"testEdits":[],
  "flipFlop":"not-applicable",
  "flipFlopReason":"this ticket CREATES the repo's test system with vitest, so its parent commit has no runner for the new test to be red against; the captain watches the suite run at Verify" }
RJ
B
chmod +x "$WORK/behav/t-001.sh"
make_worker_shim "$WORK/shim" "$WORK/behav"; fuse "$WORK/shim" || exit 99

T="$(template_blank)"
REPO="$(workcopy "$T" r2-shots-init)"
MD="$(plant_mission "$REPO" init-001 t-001)"
python3 - "$MD/state.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["githubIssue"]=42
d["title"]="Establish the foundation"; json.dump(d,open(p,"w"),indent=2)
PY
echo "driving the initialization mission to verify…"
stage_drive "$REPO" "$WORK/shim" init-001
echo "stage rc=$RC"; printf '%s\n' "$OUT" | tail -6

ORIGIN="$WORK/origin.git"; git init -q --bare "$ORIGIN"
git -C "$REPO" remote add origin "$ORIGIN"
BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"
git -C "$REPO" push -q origin "$BASE" lcars/init-001

GH="$WORK/gh"; cat > "$GH" <<GHS
#!/usr/bin/env bash
if [ "\${1:-}" = pr ] && [ "\${2:-}" = create ]; then echo "https://github.com/acme/gf/pull/7"; exit 0; fi
if [ "\${1:-}" = pr ] && [ "\${2:-}" = merge ]; then
  git -C "$REPO" merge --no-ff -q -m merge lcars/init-001 || exit 1
  git -C "$REPO" push -q origin HEAD 2>/dev/null || :
fi
exit 0
GHS
chmod +x "$GH"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/recon.sh"; chmod +x "$WORK/recon.sh"
run_sub "$REPO" "$WORK/shim" LCARS_GH_BIN="$GH" bash "$RUN_SH" open-pr --mission init-001
printf '%s\n' "$OUT"

# the approve the PROBE will run while the board is open
cat > "$WORK/approve-now.sh" <<AS
#!/usr/bin/env bash
cd "$REPO" || exit 1
export PATH="$WORK/shim:\$PATH" LCARS_VERSION_CHECK=0
exec env LCARS_GH_BIN="$GH" LCARS_GIT_BIN="$(command -v git)" \
     LCARS_RUN_SCRIPT="$WORK/recon.sh" bash "$APPROVE_SH" --mission init-001
AS
chmod +x "$WORK/approve-now.sh"

echo "repo config BEFORE the shots:"; cat "$REPO/.git/lcars/config.json"

# ---- the REAL daemon on the REAL repo --------------------------------------
( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$WORK/shim:$PATH" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$WORK/shim/claude" LCARS_GH_BIN="$WORK/shim/claude" \
    python3 -m lcars_serve --port 0 --repo-root "$REPO" ) >"$SHOTS/daemon.log" 2>&1 &
DPID=$!
BOARD_URL=""
for _ in $(seq 1 150); do
  BOARD_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$SHOTS/daemon.log" | head -1)"
  [ -n "$BOARD_URL" ] && break
  kill -0 "$DPID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$BOARD_URL" ] || { echo "FAIL: daemon never came up"; sed -n 1,25p "$SHOTS/daemon.log"; kill "$DPID" 2>/dev/null; exit 1; }
echo "daemon: $BOARD_URL (pid $DPID) repo=$REPO"

PROFILE="${TMPDIR:-/tmp}/lcars-s185-chrome"; rm -rf "$PROFILE"; mkdir -p "$PROFILE"
"$CHROME" --remote-debugging-port=0 --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=1440,980 \
  --disable-features=Translate,MediaRouter about:blank >"$SHOTS/chrome.log" 2>&1 &
CPID=$!
DEV_PORT=""
for _ in $(seq 1 150); do
  [ -f "$PROFILE/DevToolsActivePort" ] && { DEV_PORT="$(head -1 "$PROFILE/DevToolsActivePort")"; break; }
  sleep 0.1
done
cleanup(){ kill "$CPID" 2>/dev/null; kill "$DPID" 2>/dev/null; }
trap cleanup EXIT
[ -n "$DEV_PORT" ] || { echo "SKIP 77: chrome never became drivable"; exit 77; }
echo "chrome: devtools $DEV_PORT (pid $CPID, HEADED)"

node "$HERE/../tester/shot-probe.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" \
     --out "$SHOTS" --approve-cmd "$WORK/approve-now.sh"
PRC=$?
echo "probe rc=$PRC"
echo "repo config AFTER the shots:"; cat "$REPO/.git/lcars/config.json"
echo "WORKER SPAWNS TOTAL: $(spawns)  billable: $(billable)"
echo "artifacts: $SHOTS"
exit $PRC
