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
CAGE="$REPO_ROOT/tests/lib/cage.py"
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
<div>heldms: <span id="heldms">0</span></div>
<div>peakms: <span id="peakms">0</span></div>
<div>ups: <span id="ups">0</span></div>
<script>
var steps = 0, trusted = 0;
/* S221 — HOW LONG THE KEY WAS ACTUALLY DOWN. The whole `hold` defect is that a
   perfectly well-formed key event carried no TIME with it, and a page that
   only counts keydowns cannot tell a tap from a walk. So this one measures the
   wall clock between a trusted keydown and its keyup, which is the only thing
   a build that moves while a key is held can possibly respond to. */
var downAt = 0;
document.addEventListener("keydown", function (e) {
  document.getElementById("last").textContent = e.key;
  if (!e.isTrusted) return;               // a synthetic event moves nothing
  if (!downAt) downAt = performance.now();
  trusted++;
  document.getElementById("trusted").textContent = trusted;
  if (e.shiftKey) document.getElementById("shift").textContent = "yes";
  if (e.key === "ArrowRight") {
    steps++;
    document.getElementById("steps").textContent = steps;
  }
});
document.addEventListener("keyup", function (e) {
  if (!e.isTrusted) return;
  document.getElementById("ups").textContent =
    +document.getElementById("ups").textContent + 1;
  if (!downAt) return;
  var ms = Math.round(performance.now() - downAt);
  downAt = 0;
  document.getElementById("heldms").textContent = ms;
  if (ms > +document.getElementById("peakms").textContent)
    document.getElementById("peakms").textContent = ms;
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

# ==========================================================================
# B2 (S221) — HOLDING THE KEY DOWN.
#
# THE DEFECT. `press` sent keyDown and keyUp in the same breath, so nothing
# that moves WHILE a key is down could be checked at all. The example game
# walks its character at 128 px/s: a tap moves it about two pixels, a
# sixteenth of one tile, and Number One — reading a coordinate readout that
# has not changed — reports a DIDN'T-WORK against a build that is correct.
# The prompt has been telling it to "walk the character with the arrows"
# since S220; this is the capability that sentence promised.
#
# A COUNTER OF KEYDOWNS CANNOT SEE THIS DEFECT, which is why the fixture above
# now measures the wall clock the key spent DOWN. (The end-to-end proof — the
# real driver walking a real character a real 34px against a 2px tap — is
# tests/drives/s221/hold-run.sh; this is the fast row that guards it.)
# ==========================================================================
printf '\n  -- B2: the key stays DOWN for as long as it was asked to --\n'
RC7="$(drive '[{"press":"ArrowRight","hold":300},{"wait":150},{"screenshot":"held"}]' "$TMPROOT/held")"
check "B2a a 300ms hold really keeps the key down for ~300ms" \
  "[ \"\$(saw '$TMPROOT/held' heldms)\" -ge 250 ] 2>/dev/null"
check "B2b …and it is still ONE key event, not a repeat storm" \
  "[ \"\$(saw '$TMPROOT/held' trusted)\" = '1' ] && [ \"\$(saw '$TMPROOT/held' ups)\" = '1' ]"
check "B2c …and the round is a clean look, not an incomplete one" "[ \"$RC7\" = '0' ]"
check "B2d the evidence says it was HELD and for how long" \
  "grep -q 'held down 300ms' '$TMPROOT/held/readout.json'"

# THE CONTROL, and it is the whole point: the SAME action without `hold` is
# down for a moment. A rig that only ever measured the hold would have passed
# on the broken code too.
RC8="$(drive '[{"press":"ArrowRight"},{"wait":150},{"screenshot":"tap"}]' "$TMPROOT/tap")"
check "B2e CONTROL — the same press with no hold is down for under 100ms" \
  "[ \"\$(saw '$TMPROOT/tap' heldms)\" -lt 100 ] 2>/dev/null"
check "B2f CONTROL — …and its evidence line says nothing about holding" \
  "! grep -q 'held down' '$TMPROOT/tap/readout.json'"

# `times` composes as SEPARATE holds — three deliberate steps, not one long
# one. Three downs, three ups, each about 150ms.
RC9="$(drive '[{"press":"ArrowRight","hold":150,"times":3},{"wait":150},{"screenshot":"three"}]' "$TMPROOT/three")"
check "B2g times composes with hold as SEPARATE holds — three downs and three ups" \
  "[ \"\$(saw '$TMPROOT/three' trusted)\" = '3' ] && [ \"\$(saw '$TMPROOT/three' ups)\" = '3' ]"
check "B2h …each one held for its own 150ms, never merged into one long press" \
  "[ \"\$(saw '$TMPROOT/three' peakms)\" -ge 120 ] && [ \"\$(saw '$TMPROOT/three' peakms)\" -lt 400 ]" 
check "B2i …and the step count went up by three, the way a walk does" \
  "[ \"\$(saw '$TMPROOT/three' steps)\" = '3' ]"

# THE CLAMPS. A look runs under a 45-minute cage now; no action list may wedge
# it, and no trim may happen in silence.
RC10="$(drive '[{"press":"ArrowRight","hold":99999},{"wait":100},{"screenshot":"clamp"}]' "$TMPROOT/clamp")"
check "B2j an absurd hold is CLAMPED, not obeyed (the key came back up quickly)" \
  "[ \"\$(saw '$TMPROOT/clamp' heldms)\" -le 2500 ] 2>/dev/null"
check "B2k …and the trim is SAID, with both numbers" \
  "grep -q '99999ms hold is longer than this driver allows' '$TMPROOT/clamp/readout.json'"

RC11="$(drive '[{"press":"ArrowRight","hold":2000,"times":20},{"screenshot":"budget"}]' "$TMPROOT/budget")"
check "B2l a whole action may not hold a key forever — the repeats are cut to fit" \
  "[ \"\$(saw '$TMPROOT/budget' trusted)\" = '5' ]"
check "B2m …the cut is SAID, naming what was asked and what was done" \
  "grep -q 'did 5 of them' '$TMPROOT/budget/readout.json'"
check "B2n …and the round is marked incomplete, never a clean look" "[ \"$RC11\" = '3' ]"

printf '\nlcars xo-press: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
