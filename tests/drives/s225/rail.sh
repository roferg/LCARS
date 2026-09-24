#!/usr/bin/env bash
# ============================================================================
# S225 — THE THREE-QUESTION REPORT RAIL, IN A REAL BROWSER.
#
#   bash tests/drives/s225/rail.sh
#
# WHY THIS EXISTS AND WHY IT IS NOT A UNIT TEST. On 2026-08-02 a fix round
# deleted `.then(render)` from `refresh()` and the viewscreen was a blank page
# for three fix rounds while 1,162 unit tests stayed green — because every
# harness under web/tests/ calls `render()` itself. So the rail gets driven in
# a REAL headless Chrome against a REAL daemon, and the screenshots are cropped
# to the component and shot at deviceScaleFactor 3, because the captain reads
# them on a 390px phone where a full-viewport grab lands at a quarter of life
# size.
#
# HEADLESS ONLY. A headed browser steals the captain's mouse mid-work. Headless
# is still a real browser; the ban is on the node DOM stub, not on this.
#
# ZERO SPEND. The only `claude`/`copilot` on PATH are logging shims, and the
# rig issues GETs only. It boots its OWN daemon on a free port against its OWN
# planted fixture and reaps only the two PIDs it started — never by name: the
# captain runs his own viewscreen daemon and it is not ours to touch.
#
# THE FIXTURE IS THE CAPTAIN'S REAL DATA. The verdicts planted here are copied
# verbatim off a replayed look (person 26/1/0/3 of 30, drawing 1/3/4/6 of 14,
# contract 39 of 58 with 22 backed by tests; the re-check moves person to
# 25/0/2/3 and coverage DOWN to 17 of 58). Nothing is rounded or invented.
#
# EXIT: 0 every check passed · 1 a check failed · 77 skipped/infrastructure.
# ENV: LCARS_S225_VERDICTS  dir holding verdict.json + second/verdict.json
#      LCARS_BROWSER_CHROME  the Chrome binary
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="$HERE/out"; SHOTS="$HERE/shots"
rm -rf "$OUT"; mkdir -p "$OUT" "$SHOTS"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
PY="${LCARS_PYTHON_BIN:-python3}"
NODE="${LCARS_NODE_BIN:-node}"
VERDICTS="${LCARS_S225_VERDICTS:-}"

skip() { printf '\n\033[33m════ SKIPPED — the rail was NOT checked in a browser ════\033[0m\n  %s\n' "$1"; exit 77; }
[ -x "$CHROME" ] || skip "no runnable Chrome at: $CHROME"
command -v "$NODE" >/dev/null 2>&1 || skip "node not found"
command -v "$PY" >/dev/null 2>&1 || skip "python3 not found"
[ -n "$VERDICTS" ] && [ -f "$VERDICTS/verdict.json" ] || \
  skip "LCARS_S225_VERDICTS must point at a dir with verdict.json + second/verdict.json"

DAEMON_PID=""; CHROME_PID=""
cleanup() {
  for pid in "$CHROME_PID" "$DAEMON_PID"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  sleep 1
  for pid in "$CHROME_PID" "$DAEMON_PID"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
  return 0
}
trap cleanup EXIT INT TERM

# ── zero-spend shims ────────────────────────────────────────────────────────
mkdir -p "$OUT/shim"
for b in claude copilot gh; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/shim.log"\nexit 1\n' "$b" "$OUT" >"$OUT/shim/$b"
  chmod +x "$OUT/shim/$b"
done
: >"$OUT/shim.log"
export PATH="$OUT/shim:$PATH"

# ── the fixture: four missions, one per state the rail has to survive ───────
FIX="$OUT/fixture"
mkdir -p "$FIX/.git/lcars/missions"
cat >"$FIX/.git/lcars/config.json" <<EOF
{"lcarsVersion": "$(cat "$REPO/VERSION" 2>/dev/null || echo 0.0.0)",
 "repo": "acme/s225", "testCommand": "true"}
EOF

"$PY" "$HERE/plant.py" "$FIX/.git/lcars/missions" "$VERDICTS" || skip "could not plant the fixture"

# ── the daemon, on a free port, against the fixture ──────────────────────────
( cd "$REPO/web" && exec env -u LCARS_SERVE_PORT LCARS_SERVE_NO_OPEN=1 \
    LCARS_VERSION_CHECK=0 LCARS_OWNER_WARM=0 \
    LCARS_WORKER_BIN="$OUT/shim/claude" LCARS_GH_BIN="$OUT/shim/gh" \
    "$PY" -m lcars_serve --port 0 --repo-root "$FIX" ) >"$OUT/daemon.log" 2>&1 &
DAEMON_PID=$!
URL=""
for _ in $(seq 1 150); do
  URL="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log" 2>/dev/null | head -1)"
  [ -n "$URL" ] && break
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.1
done
[ -n "$URL" ] || { echo "the daemon never came up:"; sed -n '1,25p' "$OUT/daemon.log"; exit 1; }
echo "daemon: $URL (pid $DAEMON_PID)"

# ── real Chrome, headless, its own throwaway profile and free devtools port ──
PROFILE="$OUT/chrome-profile"; mkdir -p "$PROFILE"; rm -f "$PROFILE/DevToolsActivePort"
"$CHROME" --user-data-dir="$PROFILE" --remote-debugging-port=0 --headless=new \
  --no-first-run --no-default-browser-check --no-service-autorun \
  --disable-background-networking --disable-sync --disable-extensions \
  --disable-component-update --disable-default-apps --disable-popup-blocking \
  --force-color-profile=srgb --window-size=1600,1100 \
  about:blank >"$OUT/chrome.log" 2>&1 &
CHROME_PID=$!
DEV=""
deadline=$(( $(date +%s) + 40 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -s "$PROFILE/DevToolsActivePort" ]; then
    p="$(sed -n 1p "$PROFILE/DevToolsActivePort" | tr -d '[:space:]')"
    ws="$(sed -n 2p "$PROFILE/DevToolsActivePort" | tr -d '[:space:]')"
    case "$p" in ''|*[!0-9]*) p="" ;; esac
    case "$ws" in /devtools/*) ;; *) p="" ;; esac
    if [ -n "$p" ] && curl -sf --max-time 2 "http://127.0.0.1:$p/json/version" >/dev/null 2>&1; then
      DEV="$p"; break
    fi
  fi
  kill -0 "$CHROME_PID" 2>/dev/null || break
  sleep 0.2
done
[ -n "$DEV" ] || skip "Chrome never opened a drivable devtools port; see $OUT/chrome.log"
echo "chrome: devtools :$DEV (pid $CHROME_PID)"

"$NODE" "$HERE/rail.js" --devtools-port "$DEV" --url "$URL" --out "$SHOTS" \
  >"$OUT/rail.json" 2>"$OUT/rail.err"
rc=$?
"$PY" - "$OUT/rail.json" <<'PY' || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("no rail json:", e); raise SystemExit(0)
for c in d["checks"]:
    print(("PASS " if c["ok"] else "FAIL ") + c["name"]
          + ("" if c["ok"] else "  :: " + json.dumps(c["detail"])[:600]))
print("%d/%d checks ok" % (sum(c["ok"] for c in d["checks"]), len(d["checks"])))
for s in d.get("shots", []):
    print("shot:", s)
PY
[ "$rc" -eq 0 ] || sed -n '1,40p' "$OUT/rail.err"
exit $rc
