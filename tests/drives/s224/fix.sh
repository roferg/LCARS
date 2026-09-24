#!/usr/bin/env bash
# S224 FIX ROUND 1 — one real-Chrome drive of the captain's four notes.
#
#   bash tests/drives/s224/fix.sh [<board-url>] [<mission>]
#
# HEADLESS ONLY — a headed browser steals the captain's focus while he works.
# This starts NOTHING but its own Chrome and reaps ONLY that PID. It never
# kills by name: the captain runs his own viewscreen daemon and the board
# daemon is not ours to touch.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
URL="${1:-http://127.0.0.1:8799/}"
MID="${2:-lcars-20260920-001-8cb0}"
OUT="$HERE/out"; SHOTS="$HERE/fix-shots"
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

profile="$OUT/fix-profile"; mkdir -p "$profile"; rm -f "$profile/DevToolsActivePort"
"$CHROME" --user-data-dir="$profile" --remote-debugging-port=0 --headless=new \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --window-size=1700,1100 about:blank >"$OUT/fix-chrome.log" 2>&1 &
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
[ -n "$DEV_PORT" ] || { echo "CHROME never opened devtools; see $OUT/fix-chrome.log"; exit 1; }
echo "chrome pid=$CHROME_PID devtools=$DEV_PORT  board=$URL  mission=$MID"

node "$HERE/fix.js" --devtools-port "$DEV_PORT" --url "$URL" --out "$SHOTS" \
  --mission "$MID" >"$OUT/fix.json" 2>"$OUT/fix.err"
rc=$?
python3 - "$OUT/fix.json" <<'PY' || true
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("no drive json:", e); raise SystemExit(0)
for c in d["checks"]:
    print(("PASS " if c["ok"] else "FAIL ")+c["name"]+("" if c["ok"] else "  :: "+json.dumps(c["detail"])[:500]))
print("%d/%d checks ok" % (sum(c["ok"] for c in d["checks"]), len(d["checks"])))
m=d.get("m",{})
for k in ("1280","1440","1690","400","sideBySide"):
    b=m.get(k)
    if not b or b.get("missing"): continue
    print("  %-11s win=%-5s header[%s..%s] items[%s..%s] gap=%s (to card %s) lede=%s disp=%s" % (
        k, b.get("win"), b["headContent"]["l"], b["headContent"]["r"],
        b["items"]["l"], b["items"]["r"], b.get("gapShowMeToFirstCard"),
        b.get("gapShowMeToFirstItemCard"), b.get("ledeWidth"),
        (b.get("gapParts") or {}).get("paneDisplay")))
    for t in (b.get("text") or []):
        if t.get("missing"): continue
        print("      %-34s el=%-5s inner=%-5s widestLine=%-5s lines=%-3s cap=%s" % (
            t["sel"].replace(".xo-pane ",""), t["el"], t["inner"],
            t["widestLine"], t["lines"], t["cap"]))
p=m.get("pictures")
if p: print("  pictures: %d/%d load, gone-sentences=%d, measured-sentences=%d, gaps %d/%d"
            % (p["loaded"],p["n"],p["goneSentences"],p["measuredSentences"],
               p["gapLoaded"],p["gapThumbs"]))
for s in d.get("shots", []): print("shot:", s)
PY
[ "$rc" -eq 0 ] || sed -n '1,40p' "$OUT/fix.err"
exit $rc
