#!/usr/bin/env bash
# S203 gating micro-spike, act one: launch Chrome the way tests/drives/browser/
# smoke.sh does, drive the ALREADY-LAUNCHED app (launch.json's url) with
# spike-drive.js, and prove the PNGs are real renders. PID-recorded teardown.
#
#   bash spike.sh <url> <out-dir> [place,ids]
set -uo pipefail
URL="${1:?url}"; OUT="${2:?out dir}"; PLACES="${3:-}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
NODE_BIN="${LCARS_NODE_BIN:-node}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -x "$CHROME" ] || { echo "SKIP 77: no Chrome at $CHROME"; exit 77; }
mkdir -p "$OUT"
PROFILE="$OUT/chrome-profile"; rm -rf "$PROFILE"; mkdir -p "$PROFILE"
HEADLESS_FLAG="--headless=new"; [ "${LCARS_BROWSER_HEADED:-}" = "1" ] && HEADLESS_FLAG=""
"$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port=0 $HEADLESS_FLAG \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --window-size=1440,1000 about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!
echo "{\"chromePid\": $CHROME_PID}" > "$OUT/pids.json"
cleanup() { kill "$CHROME_PID" 2>/dev/null; sleep 1; kill -9 "$CHROME_PID" 2>/dev/null; }
trap cleanup EXIT
DEV_PORT=""
for _ in $(seq 1 80); do
  f="$PROFILE/DevToolsActivePort"
  if [ -f "$f" ]; then
    p="$(head -1 "$f")"; ws="$(sed -n '2p' "$f")"
    case "$p" in ''|*[!0-9]*) : ;; *) [ -n "$ws" ] && { DEV_PORT="$p"; break; } ;; esac
  fi
  sleep 0.25
done
[ -n "$DEV_PORT" ] || { echo "SKIP 77: chrome devtools port never appeared"; exit 77; }
echo "chrome pid $CHROME_PID, devtools port $DEV_PORT"
"$NODE_BIN" "$HERE/spike-drive.js" --devtools-port "$DEV_PORT" --url "$URL" --out "$OUT" ${PLACES:+--places "$PLACES"}
rc=$?
echo "spike-drive rc=$rc"
exit $rc
