#!/usr/bin/env bash
# S205 — launch a REAL HEADED Chrome with its own throwaway profile + devtools
# port, for the tester's own eyeball drive (act.js drives it via CDP). Prints
# the devtools port on stdout and the PID on stderr; leaves chrome.pid in OUT.
#
#   bash launch-chrome.sh <OUT-DIR>
set -uo pipefail
OUT="${1:?need an OUT dir}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p "$OUT/chrome-profile"
rm -f "$OUT/chrome-profile/DevToolsActivePort"
"$CHROME" \
  --user-data-dir="$OUT/chrome-profile" \
  --remote-debugging-port=0 \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --window-size=1440,1000 \
  about:blank >"$OUT/chrome.log" 2>&1 &
CPID=$!
echo "$CPID" > "$OUT/chrome.pid"
for _ in $(seq 1 100); do
  if [ -f "$OUT/chrome-profile/DevToolsActivePort" ]; then
    PORT="$(head -1 "$OUT/chrome-profile/DevToolsActivePort")"
    if node -e '
      fetch("http://127.0.0.1:" + process.argv[1] + "/json/version", { signal: AbortSignal.timeout(2000) })
        .then(() => process.exit(0)).catch(() => process.exit(1));
    ' "$PORT" 2>/dev/null; then
      echo "$PORT"
      exit 0
    fi
  fi
  kill -0 "$CPID" 2>/dev/null || { echo "chrome died" >&2; exit 1; }
  sleep 0.1
done
echo "devtools never answered" >&2
exit 1
