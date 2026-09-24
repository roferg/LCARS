#!/usr/bin/env bash
# S224 — one real-Chrome drive of the two-column verdict header, against the
# board daemon ALREADY serving the captain's DX-Scorecard repo.
#
#   bash tests/drives/s224/run.sh [<board-url>] [<regrade-mission>] [<first-look-mission>]
#
# HEADLESS ONLY — a headed browser steals the captain's mouse focus while he
# works. Headless is still a real browser; the ban is on the node DOM stub.
# This starts NOTHING but its own Chrome and reaps ONLY that PID. It never
# kills by name: the captain runs his own viewscreen daemon and the board
# daemon is not ours to touch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-http://127.0.0.1:8790/}"
MID_RE="${2:-lcars-20260920-001-8cb0}"
MID_1="${3:-lcars-20260911-001-8cb0}"
OUT="$HERE/out"; SHOTS="$HERE/shots"
mkdir -p "$OUT" "$SHOTS"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"

CHROME_PID=""
teardown() {
  [ -n "$CHROME_PID" ] && kill -0 "$CHROME_PID" 2>/dev/null && kill "$CHROME_PID" 2>/dev/null
  sleep 1
  [ -n "$CHROME_PID" ] && kill -0 "$CHROME_PID" 2>/dev/null && kill -9 "$CHROME_PID" 2>/dev/null
  return 0
}
trap teardown EXIT

profile="$OUT/chrome-profile"; mkdir -p "$profile"; rm -f "$profile/DevToolsActivePort"
"$CHROME" --user-data-dir="$profile" --remote-debugging-port=0 --headless=new \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --window-size=1600,1100 about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!
DEV_PORT=""
deadline=$(( $(date +%s) + 40 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -s "$profile/DevToolsActivePort" ]; then
    p="$(sed -n 1p "$profile/DevToolsActivePort" | tr -d '[:space:]')"
    case "$p" in ''|*[!0-9]*) p="" ;; esac
    if [ -n "$p" ] && curl -sf --max-time 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
      DEV_PORT="$p"; break
    fi
  fi
  kill -0 "$CHROME_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$DEV_PORT" ] || { echo "CHROME never opened devtools; see $OUT/chrome.log"; exit 1; }
echo "chrome pid=$CHROME_PID devtools=$DEV_PORT  board=$URL"

node "$HERE/drive.js" --devtools-port "$DEV_PORT" --url "$URL" --out "$SHOTS" \
  --regrade "$MID_RE" --first "$MID_1" >"$OUT/drive.json" 2>"$OUT/drive.err"
rc=$?
python3 - "$OUT/drive.json" <<'PY' || true
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("no drive json:", e); raise SystemExit(0)
for c in d["checks"]:
    print(("PASS " if c["ok"] else "FAIL ")+c["name"]+("" if c["ok"] else "  :: "+json.dumps(c["detail"])[:500]))
print("%d/%d checks ok" % (sum(c["ok"] for c in d["checks"]), len(d["checks"])))
for s in d.get("shots", []): print("shot:", s)
PY
[ "$rc" -eq 0 ] || sed -n '1,40p' "$OUT/drive.err"
exit $rc
