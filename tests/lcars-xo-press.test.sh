#!/usr/bin/env bash
#
# Tests for PRESSING A KEY (Session 213, claim B1).
#
# Source under test: skills/lcars-xo/xo-drive.js — the action vocabulary.
#
# THE GAP THIS CLOSES. Number One could navigate, click, type into a selector,
# wait and screenshot. It could not send a key. No arrows, no Enter, no Escape,
# no Tab, no WASD, no modifiers. So anything the keyboard drives was simply
# unverifiable, and every accessibility path that needs tab order walked was
# invisible to it.
#
# It bit a real mission. The game moves on the keyboard, so Number One could
# confirm a step-count readout EXISTED and never that the number GOES UP as you
# walk — which was the whole of what the captain asked for.
#
# WHY A REAL BROWSER AND NOTHING LESS. The failure this must not ship is a
# "press" that assigns a value or dispatches a synthetic event: the page's own
# handlers would run, a test would go green, and a real key would still never
# have been pressed. Only a real browser can tell the two apart, and it tells
# them apart by `event.isTrusted` — false for anything script-made, true only
# for an event the browser itself generated. So the fixture counts TRUSTED
# keydowns, and the control is a page that moves ONLY on a trusted key.
#
# ZERO SPEND. No worker CLI runs here at all.
#
# Usage: bash tests/lcars-xo-press.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
CAGE="$REPO_ROOT/tests/drives/s197/cage.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

HAVE_NODE=0; command -v node >/dev/null 2>&1 && HAVE_NODE=1
HAVE_CHROME=0
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$c" ] && HAVE_CHROME=1
done
[ -n "${LCARS_BROWSER_CHROME:-}" ] && [ -x "${LCARS_BROWSER_CHROME:-}" ] && HAVE_CHROME=1

echo "lcars xo — pressing a key (S213 B1)"

if [ "$HAVE_NODE" -ne 1 ] || [ "$HAVE_CHROME" -ne 1 ]; then
  printf '  (node or Chrome not available — B1 cannot be proved without a real browser; SKIPPED)\n'
  printf 'lcars xo-press: %d passed, %d failed\n' "$pass" "$fail"
  exit 0
fi

FX="$TMPROOT/fx"; mkdir -p "$FX"

# A walker that moves ONLY on a trusted key event, and shows its own counters.
# `#steps` is the number the captain asked about on the real mission; `#trusted`
# is how many of the keydowns the BROWSER itself generated.
cat >"$FX/walker.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:16px system-ui;padding:24px;background:#eef2f7;color:#12263a">
<h3 style="background:#2563eb;color:#fff;padding:8px 12px;border-radius:6px">Walker</h3>
<div style="height:60px;background:linear-gradient(90deg,#f97316,#22c55e,#0ea5e9);border-radius:6px;margin:8px 0"></div>
<div>steps: <span id="steps">0</span></div>
<div>trusted: <span id="trusted">0</span></div>
<div>last key: <span id="last">none</span></div>
<div>shift seen: <span id="shift">no</span></div>
<input id="box" style="width:200px" />
<div>typed into box: <span id="boxkeys">0</span></div>
<script>
var steps = 0, trusted = 0;
document.addEventListener("keydown", function (e) {
  document.getElementById("last").textContent = e.key;
  if (!e.isTrusted) return;               // a synthetic event moves nothing
  trusted++;
  document.getElementById("trusted").textContent = trusted;
  if (e.shiftKey) document.getElementById("shift").textContent = "yes";
  if (e.key === "ArrowRight") {
    steps++;
    document.getElementById("steps").textContent = steps;
  }
});
document.getElementById("box").addEventListener("keydown", function (e) {
  if (!e.isTrusted) return;
  var n = +document.getElementById("boxkeys").textContent + 1;
  document.getElementById("boxkeys").textContent = n;
});
</script>
</body></html>
HTML

drive() { # <actions-json> <outdir>
  local acts="$2/actions.json" out="$2"
  mkdir -p "$out"
  printf '%s\n' "$1" >"$acts"
  # cage.py always exits 0 and PRINTS the caged process's status, so the
  # driver's own exit code has to be read out of its line rather than $?.
  "$PY" "$CAGE" 40 node "$DRIVER" --url "file://$FX/walker.html" --out "$out" \
    --actions "$acts" >"$out/stdout.txt" 2>"$out/stderr.txt"
  sed -n 's/^ELAPSED .* EXIT \([0-9][0-9]*\)$/\1/p' "$out/stdout.txt" | head -1
}

# The page's OWN numbers, read back out of the readout the driver wrote. Not the
# driver's account of what it did — the page's account of what reached it.
saw() { # <outdir> <id>
  "$PY" -c 'import json,sys,re
d=json.load(open(sys.argv[1]))
t=d["page"].get("textExcerpt","")
m=re.search(sys.argv[2]+r":\s*(\S+)", t)
print(m.group(1) if m else "MISSING")' "$1/readout.json" "$2"
}

# ==========================================================================
# B1 — ArrowRight five times delivers FIVE REAL key events to the page.
# ==========================================================================
printf '\n  -- B1: five presses, five key events --\n'
RC1="$(drive '[{"press":"ArrowRight","times":5},{"wait":200},{"screenshot":"walked"}]' "$TMPROOT/five")"
check "B1a the driver accepted {\"press\":…} as a legal action (it did not call it unknown)" \
  "! grep -q 'unknown action' '$TMPROOT/five/readout.json'"
check "B1b the page counted FIVE trusted keydowns — real key events, not script-made" \
  "[ \"\$(saw '$TMPROOT/five' trusted)\" = '5' ]"
check "B1c …and the number the captain asked about WENT UP by five" \
  "[ \"\$(saw '$TMPROOT/five' steps)\" = '5' ]"
check "B1d …and the key that arrived was the one that was asked for" \
  "[ \"\$(saw '$TMPROOT/five' key)\" = 'ArrowRight' ]"
check "B1e the round still produced its picture" \
  "[ -f '$TMPROOT/five/walked.png' ]"
check "B1f what was pressed is WRITTEN DOWN in the evidence, not left to be inferred" \
  "grep -q 'ArrowRight' '$TMPROOT/five/readout.json'"

# ==========================================================================
# CONTROLS — the silence has to be earned here too.
# ==========================================================================
printf '\n  -- B1 CONTROLS --\n'
RC2="$(drive '[{"press":"Enter"},{"wait":150},{"screenshot":"one"}]' "$TMPROOT/one")"
check "B1g CONTROL — ONE press is one key event, not five and not none" \
  "[ \"\$(saw '$TMPROOT/one' trusted)\" = '1' ] && [ \"\$(saw '$TMPROOT/one' key)\" = 'Enter' ]"
check "B1h CONTROL — …and a press that is not ArrowRight does NOT move the step count" \
  "[ \"\$(saw '$TMPROOT/one' steps)\" = '0' ]"

RC3="$(drive '[{"click":"#box"},{"wait":150},{"screenshot":"none"}]' "$TMPROOT/nokey")"
check "B1i CONTROL — a round with no press at all delivers NO key events" \
  "[ \"\$(saw '$TMPROOT/nokey' trusted)\" = '0' ]"

RC4="$(drive '[{"press":"a","selector":"#box","times":3},{"wait":150},{"screenshot":"box"}]' "$TMPROOT/sel")"
check "B1j a press aimed at a selector reaches THAT element — three keys into the box" \
  "[ \"\$(saw '$TMPROOT/sel' box)\" = '3' ]"

RC5="$(drive '[{"press":"Tab","modifiers":["Shift"]},{"wait":150},{"screenshot":"mod"}]' "$TMPROOT/mod")"
check "B1k a modifier actually rides along — the page saw Shift held" \
  "[ \"\$(saw '$TMPROOT/mod' seen)\" = 'yes' ]"

RC6="$(drive '[{"press":"NotARealKeyAtAll"},{"wait":100},{"screenshot":"bad"}]' "$TMPROOT/bad")"
check "B1l a key nobody can press is SAID OUT LOUD, not silently swallowed" \
  "grep -q 'NotARealKeyAtAll' '$TMPROOT/bad/readout.json'"
check "B1m …and the round is marked incomplete rather than passing as a clean look" \
  "[ \"$RC6\" = '3' ]"

printf '\nlcars xo-press: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
