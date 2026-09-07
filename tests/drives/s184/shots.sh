#!/usr/bin/env bash
# S184 — serve the REAL viewscreen against a REAL repo and screenshot it in
# REAL HEADED CHROME. Zero spend: the S182/S183 counting shim + the fuse.
#
#   bash tests/drives/s184/shots.sh <repo-path-or-fixture-name> <label> [--stub-rec]
#
# Unlike s183b/lock-drive.sh this plants NO mission — the front door's whole
# precondition is a repo with nothing on the board.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
TARGET="${1:?repo path or fixture name}"
LABEL="${2:-$(basename "$TARGET")}"
STUB="${3:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/shots/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "SKIP 77: no Chrome"; exit 77; }

# A path if it is one, otherwise a name under the shared fixture root.
if [ -d "$TARGET/.git" ]; then REPO="$TARGET"; else REPO="$FIX_ROOT/$TARGET"; fi
[ -d "$REPO/.git" ] || { echo "SKIP 77: no repo at $REPO"; exit 77; }
REPO="$(cd "$REPO" && pwd)"

LOG="$OUT/calls.log"; : > "$LOG"
SHIM="$(make_shim "$LOG")"
fuse "$SHIM" || exit 99

( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" \
    LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$SHIM/claude" LCARS_GH_BIN="$SHIM/claude" \
    python3 -m lcars_serve --port 0 --repo-root "$REPO" ) >"$OUT/daemon.log" 2>&1 &
DPID=$!
BOARD_URL=""
for _ in $(seq 1 150); do
  BOARD_URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" | head -1)"
  [ -n "$BOARD_URL" ] && break
  kill -0 "$DPID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$BOARD_URL" ] || { echo "FAIL: daemon never came up"; sed -n 1,25p "$OUT/daemon.log"; kill "$DPID" 2>/dev/null; exit 1; }
echo "daemon: $BOARD_URL (pid $DPID)  repo=$REPO"

PROFILE="${LCARS_DRIVE_PROFILE:-${TMPDIR:-/tmp}/lcars-s184-chrome/$LABEL}"
rm -rf "$PROFILE"; mkdir -p "$PROFILE"; rm -f "$PROFILE/DevToolsActivePort"
"$CHROME" --remote-debugging-port=0 --user-data-dir="$PROFILE" \
  --no-first-run --no-default-browser-check --window-size=1440,980 \
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

node "$HERE/shot-probe.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" \
     --out "$OUT" $STUB
RC=$?
echo "probe rc=$RC"
echo "WORKER SPAWNS DURING SHOT DRIVE: $(calls "$LOG")  probes=$(probes "$LOG")"
echo "artifacts: $OUT"
exit $RC
