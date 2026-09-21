#!/usr/bin/env bash
#
# Tests for THE RENDER GATE (Session 221, fix 6).
#
# Source under test: skills/lcars-xo/xo-drive.js — the one decision it makes
# before it will look at a build at all.
#
# THE DEFECT. The gate used to ask "is there TEXT on this page", and answer a
# page with none by exiting 1 — an accusation against the app — BEFORE a single
# action in the list ran. A canvas game is exactly that page: a <title>, a
# <canvas>, an empty body. So the captain's example game, rendering a whole
# world, was scored LOW for "rendering nothing" and never had a key pressed at
# it. Measured on the real build: both runs exit 1, walk.json never written.
#
# WHAT MUST NOT BREAK, and it is the entire risk of the fix: the gate still
# exists to fail FAST on a genuinely blank app. Widening it to "always proceed"
# would turn an honest finding into a look that wanders a dead page for
# forty-five minutes. So this file proves BOTH directions, and the negative
# case is the one that matters — a test that only shows the canvas passing
# could not tell that the gate had been deleted.
#
# THIS GATE HAD NO TEST AT ALL before this file. That is why it is here rather
# than bolted onto a neighbouring suite: it is the row a future session will
# accidentally break.
#
# WHY A REAL BROWSER. The question is "did this page actually paint", answered
# from the PIXELS of a real screenshot. A stub of that layer would be asserting
# the very thing under test.
#
# ZERO SPEND. No worker CLI runs here at all.
#
# Usage: bash tests/lcars-xo-render-gate.test.sh

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

echo "lcars xo — the render gate (S221 fix 6)"

if [ "$HAVE_NODE" -ne 1 ] || [ "$HAVE_CHROME" -ne 1 ]; then
  printf '  (node or Chrome not available — this cannot be proved without a real browser; SKIPPED)\n'
  printf 'lcars xo-render-gate: %d passed, %d failed\n' "$pass" "$fail"
  exit 0
fi

FX="$TMPROOT/fx"; mkdir -p "$FX"

# ── THE FIXTURES ───────────────────────────────────────────────────────────
# 1. GENUINELY BLANK. No text, nothing drawn. This is the case the gate is for.
cat >"$FX/blank.html" <<'HTML'
<!doctype html><html><head><title>Nothing At All</title></head>
<body style="margin:0;width:100vw;height:100vh;background:#ffffff"></body></html>
HTML

# 2. ONE FLAT FILL and nothing else. No text either. The captain's boundary
#    case: this is far closer to blank than to a game, and it is meant to FAIL.
cat >"$FX/flat.html" <<'HTML'
<!doctype html><html><head><title>One Colour</title></head>
<body style="margin:0;width:100vw;height:100vh;background:#3a6ea5"></body></html>
HTML

# 3. A CANVAS APP. No text anywhere — the whole world is painted pixels, the
#    exact shape of the example game — and it MOVES ON A HELD KEY, so this
#    fixture proves the two fixes of this session together: the gate lets it
#    through, and the key that walks it is the one fix 5 added.
cat >"$FX/canvas.html" <<'HTML'
<!doctype html><html><head><title>Canvas World</title></head>
<body style="margin:0;background:#101820">
<canvas id="c" width="600" height="400"></canvas>
<script>
var cx = document.getElementById("c").getContext("2d");
var px = 40, py = 200, held = false, last = 0;
// A world with plenty of ink in it: a sky, ground, and a scatter of colour.
function draw() {
  cx.fillStyle = "#1b4f72"; cx.fillRect(0, 0, 600, 240);
  cx.fillStyle = "#145a32"; cx.fillRect(0, 240, 600, 160);
  for (var i = 0; i < 120; i++) {
    cx.fillStyle = "rgb(" + (60 + i) + "," + (200 - i) + "," + (120 + (i % 90)) + ")";
    cx.fillRect((i * 37) % 590, (i * 53) % 390, 6, 6);
  }
  cx.fillStyle = "#f4d03f"; cx.fillRect(px, py, 24, 24);
}
// It moves WHILE the key is down, 128px/s, exactly like the real game.
function tick(t) {
  var dt = last ? (t - last) / 1000 : 0; last = t;
  if (held) px += 128 * dt;
  draw();
  requestAnimationFrame(tick);
}
document.addEventListener("keydown", function (e) { if (e.isTrusted && e.code === "ArrowRight") held = true; });
document.addEventListener("keyup", function (e) { if (e.isTrusted && e.code === "ArrowRight") held = false; });
requestAnimationFrame(tick);
</script>
</body></html>
HTML

# 4. AN ORDINARY TEXT APP — the control that proves nothing about the existing
#    path moved. Its shots must still be named the way they always were.
cat >"$FX/text.html" <<'HTML'
<!doctype html><html><body style="margin:0;font:16px system-ui;padding:24px;background:#eef2f7;color:#12263a">
<h3 style="background:#2563eb;color:#fff;padding:8px 12px;border-radius:6px">An ordinary app</h3>
<div style="height:60px;background:linear-gradient(90deg,#f97316,#22c55e,#0ea5e9);border-radius:6px;margin:8px 0"></div>
<p id="line">the quick brown fox jumps over the lazy dog</p>
</body></html>
HTML

# 5. A DEAF CANVAS — the same painted world, but it ignores the keyboard and
#    nothing animates. The control for the press step: a build that does not
#    answer the key must read as couldn't-check, never as taken.
cat >"$FX/canvas-deaf.html" <<'HTML'
<!doctype html><html><head><title>Deaf Canvas</title></head>
<body style="margin:0;background:#101820">
<canvas id="c" width="600" height="400"></canvas>
<script>
var cx = document.getElementById("c").getContext("2d");
cx.fillStyle = "#1b4f72"; cx.fillRect(0, 0, 600, 240);
cx.fillStyle = "#145a32"; cx.fillRect(0, 240, 600, 160);
for (var i = 0; i < 120; i++) {
  cx.fillStyle = "rgb(" + (60 + i) + "," + (200 - i) + "," + (120 + (i % 90)) + ")";
  cx.fillRect((i * 37) % 590, (i * 53) % 390, 6, 6);
}
cx.fillStyle = "#f4d03f"; cx.fillRect(40, 200, 24, 24);
</script>
</body></html>
HTML

# 6. THE BUILD THIS SESSION EXISTS FOR (S222 fix 1) — A CANVAS THAT ANIMATES
#    ON ITS OWN AND ALSO ANSWERS ONE KEY. The captain's example game does
#    exactly this: the character breathes on the spot in a small patch whether
#    or not anybody touches the keyboard, and it walks when ArrowRight is held.
#    Measured by the tester on 2026-09-20: pressing `q` — a key that build
#    ignores completely — came back "done, something answered the key", and the
#    only differing pixels were a 42x58 patch of that breathing. So this
#    fixture reproduces the rubber stamp: any before/after pair on it differs.
#    The patch here is the same size as the measured one, and it is drawn in a
#    fixed spot so it cannot be mistaken for the character moving.
cat >"$FX/canvas-live.html" <<'HTML'
<!doctype html><html><head><title>Living Canvas</title></head>
<body style="margin:0;background:#101820">
<canvas id="c" width="600" height="400"></canvas>
<script>
var cx = document.getElementById("c").getContext("2d");
var px = 40, py = 200, held = false, last = 0, phase = 0;
function draw() {
  cx.fillStyle = "#1b4f72"; cx.fillRect(0, 0, 600, 240);
  cx.fillStyle = "#145a32"; cx.fillRect(0, 240, 600, 160);
  for (var i = 0; i < 120; i++) {
    cx.fillStyle = "rgb(" + (60 + i) + "," + (200 - i) + "," + (120 + (i % 90)) + ")";
    cx.fillRect((i * 37) % 590, (i * 53) % 390, 6, 6);
  }
  // THE IDLE ANIMATION: a 42x58 patch that never stops changing, in a fixed
  // place. This is the whole hazard — it is present in EVERY pair of shots,
  // and it has to be busy enough to move the picture statistics, because on
  // the real build it did: `q` came back "changed" off this patch alone.
  for (var j = 0; j < 58; j += 2) {
    var v = Math.floor(128 + 127 * Math.sin(phase + j * 0.4));
    cx.fillStyle = "rgb(" + v + "," + ((255 - v + j) % 256) + "," + ((v * 3 + j * 7) % 256) + ")";
    cx.fillRect(500, 300 + j, 42, 2);
  }
  cx.fillStyle = "#f4d03f"; cx.fillRect(px, py, 24, 24);
}
function tick(t) {
  var dt = last ? (t - last) / 1000 : 0; last = t;
  phase += dt * 6;
  if (held) px += 128 * dt;
  draw();
  requestAnimationFrame(tick);
}
document.addEventListener("keydown", function (e) { if (e.isTrusted && e.code === "ArrowRight") held = true; });
document.addEventListener("keyup", function (e) { if (e.isTrusted && e.code === "ArrowRight") held = false; });
requestAnimationFrame(tick);
</script>
</body></html>
HTML

drive() { # <page> <actions-json> <outdir> — prints the driver's exit code
  local page="$1" out="$3" acts="$3/actions.json"
  mkdir -p "$out"
  printf '%s\n' "$2" >"$acts"
  # cage.py always exits 0 and PRINTS the caged process's status, so the
  # driver's own exit code has to be read out of its line rather than $?.
  # `--walk-out` is how the walk record reaches disk at all; xo.sh always
  # passes it, so a test that omits it is testing a shape the product never
  # runs. stderr is captured too, but cage.py merges streams, so anything
  # asserted about the driver's own words is looked for in BOTH.
  "$PY" "$CAGE" 40 node "$DRIVER" --url "file://$FX/$page" --out "$out" \
    --actions "$acts" --walk-out "$out/walk.json" \
    >"$out/stdout.txt" 2>"$out/stderr.txt"
  sed -n 's/^ELAPSED .* EXIT \([0-9][0-9]*\)$/\1/p' "$out/stdout.txt" | head -1
}

# ==========================================================================
# C1 — THE NEGATIVE CASE. A genuinely blank app still fails, fast and loudly.
#      Without this row the fix is unfalsifiable: deleting the gate outright
#      would make every other row in this file pass.
# ==========================================================================
printf '\n  -- C1: a blank app still exits 1 --\n'
RC1="$(drive blank.html '[{"press":"ArrowRight","hold":300},{"screenshot":"never"}]' "$TMPROOT/blank")"
check "C1a a page that laid out nothing is still the PRODUCT's failure (exit 1)" \
  "[ \"$RC1\" = '1' ]"
check "C1b …with the same sentence it always gave, naming the url" \
  "cat '$TMPROOT/blank/stderr.txt' '$TMPROOT/blank/stdout.txt' | grep -q 'never laid out any text at'"
check "C1c …and the same picture-of-the-nothing, written anyway" \
  "[ -f '$TMPROOT/blank/shot-01.png' ] && grep -q '\"painted\": false' '$TMPROOT/blank/readout.json'"
check "C1d …and it stopped BEFORE the action list ran — no walk, no key" \
  "! grep -q 'pressed ArrowRight' '$TMPROOT/blank/readout.json' && [ ! -f '$TMPROOT/blank/never.png' ]"

# ==========================================================================
# C2 — THE BOUNDARY the captain asked about. One flat fill is not a render.
#      `distinctColours > 8` cannot be reached by a single colour, whatever
#      colour it is, so this fails for the same reason white does.
# ==========================================================================
printf '\n  -- C2: one flat fill is still blank --\n'
RC2="$(drive flat.html '[{"screenshot":"never"}]' "$TMPROOT/flat")"
check "C2a a page that is one solid colour and nothing else still exits 1" \
  "[ \"$RC2\" = '1' ]"
check "C2b …and the measurement says why: one colour, no ink" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/flat/readout.json'))
px=(d['shots'][0] or {}).get('pixels') or {}
sys.exit(0 if px.get('distinctColours',99) <= 8 and px.get('painted') is False else 1)\""

# ==========================================================================
# C3 — THE POSITIVE CASE. A canvas app has no text and renders a world: it
#      goes through, its actions run, and the HELD key (fix 5) walks it.
# ==========================================================================
printf '\n  -- C3: a canvas app is looked at, not accused --\n'
RC3="$(drive canvas.html '[{"press":"ArrowRight","hold":300},{"wait":200},{"screenshot":"walked"}]' "$TMPROOT/canvas")"
check "C3a a page with no text but a painted world is NOT called a failure" \
  "[ \"$RC3\" = '0' ]"
check "C3b …the action list actually ran" \
  "grep -q 'held down 300ms' '$TMPROOT/canvas/readout.json'"
check "C3c …and the shot the actions asked for exists" \
  "[ -f '$TMPROOT/canvas/walked.png' ]"
check "C3d …the walk record carries the keypress" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/canvas/walk.json'))
a=d.get('actions') or []
sys.exit(0 if any(x.get('press')=='ArrowRight' and x.get('holdMs')==300 for x in a) else 1)\" 2>/dev/null \
   || grep -q 'ArrowRight' '$TMPROOT/canvas/readout.json'"
# ONE full-page shot, not two: the gate's picture IS round 0's picture.
check "C3e the gate's picture is reused, not duplicated (one shot-01, no shot-02)" \
  "[ -f '$TMPROOT/canvas/shot-01.png' ] && [ ! -f '$TMPROOT/canvas/shot-02.png' ]"
# THE HONESTY NOTE. Every deterministic pass here reads the DOM, and on this
# page they all come back empty. An empty measurement is not a finding of
# absence, and the record has to say so or a look will read "0 findings" as
# "nothing wrong".
check "C3f the record SAYS the measurements are blind here, so an empty pass is not read as evidence" \
  "grep -q 'Every measurement pass here is blind' '$TMPROOT/canvas/readout.json'"
check "C3g …and the walk record carries the same fact for the report" \
  "grep -q '\"canvasOnly\": true' '$TMPROOT/canvas/walk.json'"

# ==========================================================================
# C4 — THE UNTOUCHED PATH. An ordinary text app behaves exactly as before.
# ==========================================================================
printf '\n  -- C4: an ordinary text app is unchanged --\n'
RC4="$(drive text.html '[{"press":"ArrowRight"},{"screenshot":"shot"}]' "$TMPROOT/text")"
check "C4a a text app still looks clean" "[ \"$RC4\" = '0' ]"
check "C4b …and says nothing about drawing itself" \
  "! grep -q 'Every measurement pass here is blind' '$TMPROOT/text/readout.json'"
check "C4c …and its shot naming did not shift" \
  "[ -f '$TMPROOT/text/shot.png' ]"

# ==========================================================================
# C5 (S221 fix 7) — THE DRIVER EXECUTES A DECLARED PRESS STEP.
#
# The planner can now emit `{"do":"press"}` steps; this is the other half —
# the driver has to press them, and has to judge them honestly. On a canvas
# build the url and the page TEXT are identical before and after however far
# the character walked, so the existing change-check calls every key press
# "nothing changed". The press step is judged on its two PICTURES instead.
#
# The control is the row that matters: a build that ignores the key must come
# back couldn't-check, or this machinery would vouch for anything.
# ==========================================================================
printf '\n  -- C5: a declared press step, walked and judged --\n'
journey() { # <page> <journey-json> <outdir> — prints the driver's exit code
  local page="$1" out="$3"
  mkdir -p "$out"
  printf '%s\n' "$2" >"$out/journey.json"
  "$PY" "$CAGE" 40 node "$DRIVER" --url "file://$FX/$page" --out "$out" \
    --journey "$out/journey.json" --walk-out "$out/walk.json" \
    >"$out/stdout.txt" 2>"$out/stderr.txt"
  sed -n 's/^ELAPSED .* EXIT \([0-9][0-9]*\)$/\1/p' "$out/stdout.txt" | head -1
}
STEP='{"steps":[{"key":"j1","do":"press","pressKey":"ArrowRight","hold":250,"times":3,"match":[],"name":"hold ArrowRight and watch what changes","expect":"the screen answers the key"}],"entry":[]}'

RC5="$(journey canvas.html "$STEP" "$TMPROOT/jwalk")"
check "C5a the driver ran the declared press step" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/jwalk/walk.json'))
st=(d.get('steps') or [{}])[0]
sys.exit(0 if st.get('do')=='press' and st.get('pressed')=='ArrowRight' and st.get('holdMs')==250 and st.get('times')==3 else 1)\""
check "C5b …it HELD the key, and the walk's keypress counter says so" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/jwalk/walk.json'))
sys.exit(0 if (d.get('moves') or {}).get('keypresses')==3 else 1)\""
check "C5c …the picture moved, so the step is TAKEN on a build with no text at all" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jwalk/walk.json'))['steps'][0]
sys.exit(0 if st.get('pictureMoved') is True and st.get('status')!='no-change' and not st.get('couldNotCheck') else 1)\""
check "C5d …and BOTH pictures are on disk, which is what a before/after is for" \
  "ls '$TMPROOT/jwalk' | grep -q -- '-before.png' && ls '$TMPROOT/jwalk' | grep -qE 'walk-01.*\\.png'"

# THE CONTROL. Same picture, no key handler, nothing animating.
RC6="$(journey canvas-deaf.html "$STEP" "$TMPROOT/jdeaf")"
check "C5e CONTROL — a build that IGNORES the key is couldn't-check, never taken" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jdeaf/walk.json'))['steps'][0]
sys.exit(0 if st.get('status')=='no-change' and st.get('couldNotCheck')=='nothing changed' and st.get('pictureMoved') is False else 1)\""
check "C5f …and it says so in words the captain can read" \
  "grep -q 'same words AND the same picture' '$TMPROOT/jdeaf/walk.json'"

# A key nobody can press is named, not silently skipped.
RC7="$(journey canvas.html '{"steps":[{"key":"j1","do":"press","pressKey":"NotAKey","match":[],"name":"press NotAKey"}],"entry":[]}' "$TMPROOT/jbad")"
check "C5g a declared key this browser cannot press is SAID, not swallowed" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jbad/walk.json'))['steps'][0]
sys.exit(0 if st.get('status')=='unreachable' and 'NotAKey' in (st.get('why') or '') else 1)\""

# ==========================================================================
# C6 (S221 fix 8) — THE RECORD MUST NOT CONTRADICT ITSELF, AND MUST NOT CLAIM
#      MORE THAN IT MEASURED.
#
# 8a THE CONTRADICTION. For the two steps that demonstrably walked the
#    character, the notes said the step "changed nothing at all, so it is
#    couldn't-check, not taken" while walk.json said `done`. The note was
#    pushed during the TEXT comparison and never retracted when the picture
#    pair upgraded the status a few lines later. BOTH go to the worker.
#
# 8b THE OVERCLAIM. Pressing `q` — a key this game ignores — came back
#    "something answered the key". The only differing pixels were the
#    character's own idle animation. On an animating build the picture always
#    differs, so a changed picture can say a step RAN and can never say a key
#    was ANSWERED. The strings have to say that.
# ==========================================================================
printf '\n  -- C6: one story, and no claim the mechanism cannot support --\n'

RC8="$(journey canvas.html "$STEP" "$TMPROOT/jsay")"
check "C6a 8a — the notes and the walk record tell ONE story, not two" \
  "$PY -c \"
import json,sys
w=json.load(open('$TMPROOT/jsay/walk.json'))
st=w['steps'][0]
r=json.load(open('$TMPROOT/jsay/readout.json'))
notes=' '.join(r.get('notes') or [])
# the step was taken; so nothing anywhere may call it couldn't-check
bad = st.get('status')=='done' and 'couldn' in notes and 'not taken' in notes
sys.exit(1 if bad else 0)\""
check "C6b …the note that IS there says the step was taken" \
  "grep -q 'was taken and its picture changed' '$TMPROOT/jsay/readout.json'"
check "C6c 8b — nothing claims the key was answered" \
  "! grep -q 'something answered the key' '$TMPROOT/jsay/walk.json' && \
   ! grep -q 'something answered the key' '$TMPROOT/jsay/readout.json'"
check "C6d …and it says IN WORDS that a changed picture is not that evidence" \
  "grep -q 'NOT evidence the key was answered' '$TMPROOT/jsay/readout.json' && \
   $PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jsay/walk.json'))['steps'][0]
w=st.get('why') or ''
sys.exit(0 if 'NOT evidence the key was answered' in w and 'judge it by eye' in w else 1)\""
# UPDATED BY S222 fix 1. The row's point is unchanged — the record must name
# WHAT THE EVIDENCE ACTUALLY IS — but the evidence itself got stronger. This
# fixture is still when no key is held, so ArrowRight now beats the un-keyed
# control shot, and calling that `picture-only` would understate it by exactly
# the amount this session added. `picture-only` is still what a press with no
# usable control shot records, and C8 owns the new marker's two directions.
check "C6e …and the record marks what the evidence actually is" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jsay/walk.json'))['steps'][0]
sys.exit(0 if st.get('changeEvidence')=='picture-beat-idle-control' else 1)\""

# THE CONTROL for 8a's other half: a build that really did not answer still
# gets its couldn't-check note — retracting the contradiction must not have
# silenced the honest case.
RC9="$(journey canvas-deaf.html "$STEP" "$TMPROOT/jsay2")"
check "C6f CONTROL — a step that changed NOTHING still says so, once" \
  "grep -q 'changed nothing at all' '$TMPROOT/jsay2/readout.json' && \
   $PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jsay2/walk.json'))['steps'][0]
sys.exit(0 if st.get('status')=='no-change' else 1)\""

# ==========================================================================
# C7 (S221 fix 8c) — THE DRIVER CAN PRESS A FUNCTION KEY.
#      The planner emits F3 (this session's mission has a criterion about its
#      F3 overlay); the driver used to refuse it, so one of three planned
#      steps was dead on arrival and that criterion read "couldn't check" for
#      ever.
# ==========================================================================
printf '\n  -- C7: F3 is a key this browser can press --\n'
F3STEP='{"steps":[{"key":"j1","do":"press","pressKey":"F3","hold":0,"times":1,"match":[],"name":"press F3 and watch what changes","expect":"the overlay answers"}],"entry":[]}'
RC10="$(journey canvas.html "$F3STEP" "$TMPROOT/jf3")"
check "C7a a declared F3 step is PRESSED, not refused as unpressable" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jf3/walk.json'))['steps'][0]
sys.exit(0 if st.get('pressed')=='F3' and st.get('status')!='unreachable' else 1)\""
check "C7b …and nothing says F3 is a key it cannot press" \
  "! grep -q 'not a key I can press' '$TMPROOT/jf3/walk.json'"
# The ends of the family, driven — F1 and F12 — so "F3 happens to work" can
# never be mistaken for "the function keys are known".
RC11="$(drive canvas.html '[{"press":"F1"},{"press":"F12"},{"screenshot":"fk"}]' "$TMPROOT/jfk")"
check "C7c …and so are the ends of the family, F1 and F12" \
  "[ \"$RC11\" = '0' ] && grep -q 'pressed F1' '$TMPROOT/jfk/readout.json' && \
   grep -q 'pressed F12' '$TMPROOT/jfk/readout.json' && \
   ! grep -q 'is not a key this browser can press' '$TMPROOT/jfk/readout.json'"

# ==========================================================================
# C8 (S222 fix 1) — THE IDLE CONTROL. A PRESS STEP MUST BE ABLE TO FAIL ON A
#      BUILD THAT ANIMATES BY ITSELF.
#
# S221 fix 8b made the WORDING honest — the record stopped claiming a changed
# picture meant the key was answered — but left the MECHANISM unable to fail.
# Measured by the tester on 2026-09-20 on the captain's real game: pressing
# `q`, a key it ignores completely, came back `status: done`; the readout said
# `Tile 10, 10` before AND after, and the only differing pixels were a 42x58
# patch of the character breathing on the spot. Comparing a before shot to an
# after shot on a build that animates is a rubber stamp.
#
# THE CURE: a THIRD shot with NO key pressed, over a window the same length as
# the keyed one. That shot measures how much this build changes ON ITS OWN, and
# the keyed change has to EXCEED it.
#
# BOTH HALVES ARE PROVED HERE, on ONE fixture, because a fixture that only
# showed the failing half could be satisfied by breaking press steps outright:
#   - a key this build IGNORES (`q`)          must come back no-change
#   - a key this build HONOURS (ArrowRight)   must still come back taken
# ==========================================================================
printf '\n  -- C8: the idle control — a key this build ignores cannot pass --\n'
QSTEP='{"steps":[{"key":"j1","do":"press","pressKey":"q","hold":250,"times":3,"match":[],"name":"hold q and watch what changes","expect":"the screen answers the key"}],"entry":[]}'

RC12="$(journey canvas-live.html "$QSTEP" "$TMPROOT/jlivedeaf")"
check "C8a a key this ANIMATING build IGNORES comes back no-change, not taken" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jlivedeaf/walk.json'))['steps'][0]
sys.exit(0 if st.get('status')=='no-change' and st.get('couldNotCheck') else 1)\""
check "C8b …and the reason given is the idle control, by its numbers" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jlivedeaf/walk.json'))['steps'][0]
k=st.get('keyedDistance'); idle=st.get('idleDistance')
sys.exit(0 if isinstance(k,(int,float)) and isinstance(idle,(int,float)) \
             and st.get('beatIdle') is False else 1)\""
check "C8c …and it says in words that the build changes this much on its own" \
  "grep -q 'as much as it changes on its own' '$TMPROOT/jlivedeaf/walk.json'"
check "C8d …and the THIRD, un-keyed picture is on disk beside the other two" \
  "$PY -c \"
import json,os,sys
st=json.load(open('$TMPROOT/jlivedeaf/walk.json'))['steps'][0]
n=st.get('shotIdle')
sys.exit(0 if n and os.path.exists(os.path.join('$TMPROOT/jlivedeaf', n + '.png')) else 1)\""

# THE OTHER HALF, on the SAME animating fixture: the key it really does answer.
RC13="$(journey canvas-live.html "$STEP" "$TMPROOT/jliveheard")"
check "C8e the key this same build HONOURS is still TAKEN" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jliveheard/walk.json'))['steps'][0]
sys.exit(0 if st.get('status')=='done' and st.get('pressed')=='ArrowRight' \
             and not st.get('couldNotCheck') else 1)\""
check "C8f …because it moved MORE than the build moves on its own" \
  "$PY -c \"
import json,sys
st=json.load(open('$TMPROOT/jliveheard/walk.json'))['steps'][0]
sys.exit(0 if st.get('beatIdle') is True \
             and st.get('keyedDistance') > st.get('idleDistance') else 1)\""

printf '\nlcars xo-render-gate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
