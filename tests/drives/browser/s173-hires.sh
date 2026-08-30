#!/usr/bin/env bash
# S173 TESTER RIG — real headed/headless Chrome against the four-wave hire fixture.
# Boots the SHIPPING daemon on the s173 fixture, opens the mission detail, expands
# every activity band, and prints/screenshots what the captain actually reads.
#   bash tests/drives/browser/s173-hires.sh
# ZERO tokens — GETs only, both engines shimmed to refuse.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="${LCARS_BROWSER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/lcars-s173.XXXXXX")}"
mkdir -p "$OUT"
DAEMON_PID=""; CHROME_PID=""
cleanup() { local rc=$?; for p in "$CHROME_PID" "$DAEMON_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  sleep 1; for p in "$CHROME_PID" "$DAEMON_PID"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done; return $rc; }
trap cleanup EXIT INT TERM

mkdir -p "$OUT/shim"
for e in claude copilot; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/worker-shim.log"\nexit 1\n' "$e" "$OUT" >"$OUT/shim/$e"
  chmod +x "$OUT/shim/$e"
done
: >"$OUT/worker-shim.log"
export PATH="$OUT/shim:$PATH"

FIX="$OUT/fixture"; mkdir -p "$FIX"
( cd "$FIX" && git init -q . && git config user.email t@t && git config user.name t )
bash "$HERE/s173-fixture.sh" "$FIX"

( cd "$REPO/web" && exec env -u LCARS_SERVE_PORT LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$OUT/shim/claude" LCARS_GH_BIN="$OUT/shim/claude" \
    python3 -m lcars_serve --port 0 --repo-root "$FIX" ) >"$OUT/daemon.log" 2>&1 &
DAEMON_PID=$!
URL=""
for _ in $(seq 1 150); do
  URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" 2>/dev/null | head -1)"
  [ -n "$URL" ] && break; sleep 0.1
done
[ -n "$URL" ] || { echo "daemon never came up"; sed -n 1,20p "$OUT/daemon.log"; exit 77; }
echo "daemon: $URL (pid $DAEMON_PID)"
echo "api:    curl -s ${URL}api/mission/lcars-20260830-001"

PROFILE="$OUT/chrome-profile"; mkdir -p "$PROFILE"; rm -f "$PROFILE/DevToolsActivePort"
HEADLESS="--headless=new"; [ "${LCARS_BROWSER_HEADED:-}" = "1" ] && HEADLESS=""
"$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port=0 $HEADLESS \
  --no-first-run --no-default-browser-check --disable-background-networking \
  --disable-sync --disable-extensions --disable-component-update \
  --window-size=1500,1000 about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!
DEV=""
for _ in $(seq 1 150); do
  p="$(sed -n 1p "$PROFILE/DevToolsActivePort" 2>/dev/null | tr -d '[:space:]')"
  w="$(sed -n 2p "$PROFILE/DevToolsActivePort" 2>/dev/null | tr -d '[:space:]')"
  case "$w" in /devtools/*) DEV="$p"; break ;; esac
  sleep 0.2
done
[ -n "$DEV" ] || { echo "chrome devtools never came up"; exit 77; }
echo "chrome: devtools :$DEV (pid $CHROME_PID)"
node "$HERE/s173-drive.js" --devtools-port "$DEV" --url "$URL" --out "$OUT"
RC=$?
echo "worker shim invocations: $(wc -l <"$OUT/worker-shim.log" | tr -d ' ') (expected 0)"
echo "artifacts: $OUT"
exit $RC
