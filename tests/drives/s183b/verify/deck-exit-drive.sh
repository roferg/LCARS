#!/usr/bin/env bash
# S183b — serve the REAL viewscreen against a REAL fixture repo and drive it in
# REAL HEADED CHROME. Zero spend: PATH shim + LCARS_WORKER_BIN both point at the
# counting fake, and the probe issues GETs plus ONE click that must not spawn.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../rig.sh"
REPO_NAME="${1:?fixture repo name}"
LABEL="${2:-$REPO_NAME}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LCARS_REPO="$LCARS_SRC"
OUT="$HERE/verify/shots/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "SKIP 77: no Chrome"; exit 77; }
FIX="$FIX_ROOT/$REPO_NAME"
[ -d "$FIX/.git" ] || { echo "SKIP 77: no fixture $FIX"; exit 77; }

LOG="$OUT/calls.log"; : > "$LOG"
SHIM="$(make_shim "$LOG")"
fuse "$SHIM" || exit 99

# Plant ONE mission so the board has a card to paint (proves it rendered at all).
M="$FIX/.git/lcars/missions/lcars-20260905-900"
mkdir -p "$M"
cat > "$M/state.json" <<J
{ "id": "lcars-20260905-900", "type": "feature", "title": "S183b board probe",
  "stage": "align", "created": "2026-09-05T00:00:00Z", "model": "claude-sonnet",
  "githubIssue": null, "branch": "lcars/x", "base": "main" }
J

( cd "$LCARS_REPO/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$SHIM/claude" LCARS_GH_BIN="$SHIM/claude" \
    python3 -m lcars_serve --port 0 --repo-root "$FIX" ) >"$OUT/daemon.log" 2>&1 &
DPID=$!
BOARD_URL=""
for _ in $(seq 1 150); do
  BOARD_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" | head -1)"
  [ -n "$BOARD_URL" ] && break
  kill -0 "$DPID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$BOARD_URL" ] || { echo "FAIL: daemon never came up"; sed -n 1,20p "$OUT/daemon.log"; kill "$DPID" 2>/dev/null; exit 1; }
echo "daemon: $BOARD_URL (pid $DPID)  repo=$FIX"

PROFILE="$(mktemp -d "${TMPDIR:-/tmp}/s183chrome.XXXXXX")"; mkdir -p "$PROFILE"; rm -f "$PROFILE/DevToolsActivePort"
"$CHROME" --remote-debugging-port=0 --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=1440,900 \
  --disable-features=Translate,MediaRouter about:blank >"$OUT/chrome.log" 2>&1 &
CPID=$!
DEV_PORT=""
for _ in $(seq 1 150); do
  [ -f "$PROFILE/DevToolsActivePort" ] && { DEV_PORT="$(head -1 "$PROFILE/DevToolsActivePort")"; break; }
  sleep 0.1
done
cleanup() { kill "$CPID" 2>/dev/null; kill "$DPID" 2>/dev/null; }
trap cleanup EXIT
[ -n "$DEV_PORT" ] || { echo "SKIP 77: chrome never became drivable"; exit 77; }
echo "chrome: devtools $DEV_PORT (pid $CPID, HEADED)"

node "$HERE/verify/deck-exit-probe.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" --out "$OUT"
RC=$?
echo "probe rc=$RC"
echo "WORKER SPAWNS DURING BOARD DRIVE: $(calls "$LOG")  probes=$(probes "$LOG")"
echo "screenshots: $OUT"
exit $RC
