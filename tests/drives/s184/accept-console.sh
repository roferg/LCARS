#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/verify/accept-console2"; rm -rf "$OUT"; mkdir -p "$OUT"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
REPO="$(newrepo "s184-accept-console")"
LOG="$OUT/calls.log"; : > "$LOG"; SHIM="$(make_shim "$LOG")"; fuse "$SHIM" || exit 99
( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" LCARS_SERVE_NO_OPEN=1 \
   LCARS_VERSION_CHECK=0 LCARS_WORKER_BIN="$SHIM/claude" LCARS_GH_BIN="$SHIM/claude" \
   python3 -m lcars_serve --port 0 --repo-root "$REPO" ) >"$OUT/daemon.log" 2>&1 &
DPID=$!
U=""; for _ in $(seq 1 200); do U="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log"|head -1)"; [ -n "$U" ] && break; sleep 0.1; done
PROFILE="${TMPDIR:-/tmp}/lcars-s184-ac"; rm -rf "$PROFILE"; mkdir -p "$PROFILE"
"$CHROME" --remote-debugging-port=0 --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  --window-size=1440,980 about:blank >"$OUT/chrome.log" 2>&1 &
CPID=$!; DEV=""
for _ in $(seq 1 200); do [ -f "$PROFILE/DevToolsActivePort" ] && { DEV="$(head -1 "$PROFILE/DevToolsActivePort")"; break; }; sleep 0.1; done
trap 'kill $CPID $DPID 2>/dev/null' EXIT
node "$HERE/accept-console-probe.js" --devtools-port "$DEV" --url "$U" --out "$OUT" 
echo "missions: $(ls "$REPO/.git/lcars/missions" 2>/dev/null)"
echo "SPAWNS: $(calls "$LOG")"
