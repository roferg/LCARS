#!/usr/bin/env bash
#
# S203 — the xo-drive.js rig. REAL headless Chrome against a REAL static page.
#
#   bash tests/drives/s203/drive-rig.sh
#
# What it proves, and why each leg exists:
#
#   1. THE SHOTS ARE REAL. A full-page PNG plus one CLIPPED PNG per place name
#      the drawing declares, each with its paired `.json` readout and `.txt`
#      caption. The readout carries the computed colour of the named elements,
#      so the worker has a second evidence channel beside the pixels (screenshots
#      do not travel between laptops — ruling, ledgered).
#   2. A NAME THE APP DOES NOT HAVE IS SAID, NOT SWALLOWED. That is the shape of
#      the finding Number One exists to make.
#   3. THE ACTION LIST DRIVES. click / type / wait / screenshot, and the cap.
#   4. THE EXIT CODES HOLD. 1 for a page that never lays out, 77 for no Chrome.
#   5. **THE CAPTAIN'S FOCUS IS NOT TAKEN** — captain's ruling 2026-09-13. The
#      frontmost application is read before and after the whole drive and must
#      be UNCHANGED, and the Chrome argv the driver builds must carry
#      `--headless` with no env able to remove it. A screenshot proves the
#      driver worked; it does not prove focus was not taken, so this leg is
#      separate and it is the one that must never be dropped.
#
# Skips (never fails) without Chrome or node, the smoke.sh precedent.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DRIVER="$ROOT/skills/lcars-xo/xo-drive.js"
TMP="$(mktemp -d)"
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

command -v node >/dev/null 2>&1 || { echo "SKIP: no node"; exit 0; }
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "SKIP: no Chrome at $CHROME"; exit 0; }
export LCARS_BROWSER_CHROME="$CHROME"

echo "S203 xo-drive.js rig"

# --- the app under the lens ------------------------------------------------
# Three identifiable elements, as the sandbox contract requires, plus one the
# drawing will name and the page deliberately does NOT have.
mkdir -p "$TMP/site"
cat >"$TMP/site/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Rig App</title>
<style>
 body{background:#0b0f14;color:#e8e8e8;font:14px system-ui;margin:0;padding:24px}
 #app-header{background:#9c6b4f;color:#000;padding:12px 16px;font-weight:700}
 #task-list{background:#122029;padding:16px;margin-top:16px}
 #task-list li{padding:4px 0}
 #add-button{background:#5aa6b8;color:#001;border:0;padding:10px 18px;margin-top:16px}
 #echo{margin-top:12px;color:#9c6b4f}
</style>
<div id="app-header">RIG APP — the header the drawing names</div>
<ul id="task-list"><li>write the driver</li><li>take the shot</li><li>read it back</li></ul>
<input id="task-input" placeholder="a new task">
<button id="add-button">ADD</button>
<div id="echo">nothing yet</div>
<script>
 document.getElementById('add-button').addEventListener('click', function(){
   document.getElementById('echo').textContent =
     'added: ' + document.getElementById('task-input').value;
 });
</script>
HTML

PORT=$(( 18200 + RANDOM % 400 ))
( cd "$TMP/site" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
SRV_PID=$!
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/index.html" >/dev/null 2>&1 && break
  sleep 0.25
done

# --- FOCUS, BEFORE -----------------------------------------------------------
frontmost() {
  [ "$(uname)" = "Darwin" ] || { printf 'n/a'; return 0; }
  osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null
}
FOCUS_BEFORE="$(frontmost)"
printf '  frontmost before: %s\n' "${FOCUS_BEFORE:-?}"

# --- the argv leg: headless is STRUCTURAL, not conditional -------------------
echo
echo "1. headless, always"
argv="$(node "$DRIVER" --url x --out "$TMP/argv" --print-chrome-argv 2>/dev/null)"
check "1. the Chrome argv carries --headless" "printf '%s' \"\$argv\" | grep -q -- '--headless'"
argv_headed="$(LCARS_BROWSER_HEADED=1 node "$DRIVER" --url x --out "$TMP/argv" --print-chrome-argv 2>/dev/null)"
check "1. LCARS_BROWSER_HEADED=1 cannot un-headless it" \
  "[ \"\$argv\" = \"\$argv_headed\" ] && printf '%s' \"\$argv_headed\" | grep -q -- '--headless'"
check "1. …and no --app / --new-window that would raise a window" \
  "! printf '%s' \"\$argv\" | grep -qE -- '--app=|--new-window'"

# --- round 0: full page + one clipped shot per place name --------------------
echo
echo "2. round 0 — the standard look"
cat >"$TMP/places.json" <<'JSON'
{"placeNames": ["app-header", "task-list", "add-button", "nowhere-panel"]}
JSON
out0="$TMP/out0"
node "$DRIVER" --url "http://127.0.0.1:$PORT/index.html" --out "$out0" \
  --place-names "$TMP/places.json" >"$TMP/r0.json" 2>"$TMP/r0.err"
rc0=$?
printf '  driver rc=%s\n' "$rc0"
check "2. it exited 3 (incomplete — one named place is genuinely absent)" "[ '$rc0' -eq 3 ]"
check "2. a full-page PNG was written" "[ -s '$out0/shot-01.png' ]"
check "2. …with its paired .json readout" "[ -s '$out0/shot-01.json' ]"
check "2. …and its one-line .txt caption" "[ -s '$out0/shot-01.txt' ]"
check "2. the full-page shot is PAINTED, not a blank frame" \
  "grep -q 'PAINTED' '$out0/shot-01.txt'"
check "2. one CLIPPED shot per place the app really has (3 more)" \
  "[ -s '$out0/shot-02.png' ] && [ -s '$out0/shot-03.png' ] && [ -s '$out0/shot-04.png' ]"
check "2. the clipped shot names its selector in the caption" \
  "grep -q 'clipped to #app-header' '$out0/shot-02.txt'"
check "2. the readout carries the page title" \
  "grep -q '\"title\": \"Rig App\"' '$out0/shot-01.json'"
check "2. …the visible text excerpt" \
  "grep -q 'write the driver' '$out0/shot-01.json'"
check "2. …and the computed colour of a named place" \
  "grep -q 'rgb(156, 107, 79)' '$out0/shot-01.json'"
check "2. a place name the app does NOT have is SAID, not swallowed" \
  "grep -q 'nowhere-panel' '$out0/readout.json' && grep -q 'no element with that id' '$out0/readout.json'"
check "2. …and no shot-05 was invented for it" "[ ! -e '$out0/shot-05.png' ]"

# --- the action round --------------------------------------------------------
echo
echo "3. the action list drives"
cat >"$TMP/actions.json" <<JSON
[
  {"type": "#task-input", "text": "polish the rim"},
  {"click": "#add-button"},
  {"wait": 300},
  {"screenshot": "after-add"},
  {"screenshot": "after-add-echo", "selector": "#echo"},
  {"click": "#no-such-thing"}
]
JSON
out1="$TMP/out1"
node "$DRIVER" --url "http://127.0.0.1:$PORT/index.html" --out "$out1" \
  --actions "$TMP/actions.json" --place-names "$TMP/places.json" >"$TMP/r1.json" 2>&1
rc1=$?
printf '  driver rc=%s\n' "$rc1"
check "3. the worker's own shot NAMES are used" \
  "[ -s '$out1/after-add.png' ] && [ -s '$out1/after-add-echo.png' ]"
check "3. the click really happened (the page changed under it)" \
  "grep -q 'added: polish the rim' '$out1/after-add.json'"
check "3. a click that matched nothing is reported" \
  "grep -q 'nothing matched #no-such-thing' '$out1/readout.json'"
check "3. …and that makes the round INCOMPLETE (rc 3), not a product failure" \
  "[ '$rc1' -eq 3 ]"

echo
echo "4. the 12-action cap"
python3 - "$TMP/over.json" <<'PY'
import json, sys
acts = [{"wait": 1} for _ in range(11)] + [{"screenshot": "capped"}] + [{"screenshot": "over-the-cap"}]
json.dump(acts, open(sys.argv[1], "w"))
PY
out2="$TMP/out2"
node "$DRIVER" --url "http://127.0.0.1:$PORT/index.html" --out "$out2" \
  --actions "$TMP/over.json" >/dev/null 2>&1
check "4. the 12th action ran" "[ -s '$out2/capped.png' ]"
check "4. the 13th did NOT" "[ ! -e '$out2/over-the-cap.png' ]"
check "4. …and the drop is stated in the readout" \
  "grep -q 'only the first 12' '$out2/readout.json'"

# --- exit codes --------------------------------------------------------------
echo
echo "5. exit codes"
printf '<!doctype html><title>blank</title><body></body>' >"$TMP/site/blank.html"
node "$DRIVER" --url "http://127.0.0.1:$PORT/blank.html" --out "$TMP/out3" \
  --timeout 4000 >/dev/null 2>&1
check "5. a page that lays out no text at all → 1 (PRODUCT)" "[ \$? -eq 1 ]"
check "5. …and the evidence is still written" "[ -s '$TMP/out3/shot-01.png' ]"
LCARS_BROWSER_CHROME=/nope/not/chrome node "$DRIVER" --url "http://127.0.0.1:$PORT/index.html" \
  --out "$TMP/out4" >/dev/null 2>&1
check "5. no Chrome → 77 (INFRASTRUCTURE, never the app's fault)" "[ \$? -eq 77 ]"
node "$DRIVER" --out "$TMP/out5" >/dev/null 2>&1
check "5. missing --url → 77" "[ \$? -eq 77 ]"

# --- FOCUS, AFTER ------------------------------------------------------------
echo
echo "6. THE CAPTAIN'S FOCUS"
FOCUS_AFTER="$(frontmost)"
printf '  frontmost after:  %s\n' "${FOCUS_AFTER:-?}"
check "6. the frontmost application is UNCHANGED across the whole drive" \
  "[ \"\$FOCUS_BEFORE\" = \"\$FOCUS_AFTER\" ]"
check "6. no Chrome process of ours survived the drive" \
  "[ -z \"\$(pgrep -f 'lcars-xo-chrome\\.' 2>/dev/null)\" ]"

echo
printf 's203 xo-drive rig: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
