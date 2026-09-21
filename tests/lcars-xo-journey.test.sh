#!/usr/bin/env bash
#
# Tests for S220 parts E, F and G — WALK THE JOURNEY, SEEDABLE DATA, and the
# SWEEP OF WHAT IS ALREADY WAITING AT VERIFY.
#
# THE DEFECTS THESE EXIST FOR, all three measured on 2026-09-19:
#
#   F  Number One "looked at" a six-screen build by typing four addresses into
#      the bar. It never clicked a control, never typed anything, never watched
#      a value carry from one screen to the next — and graded the flow anyway.
#      Two later runs of the IDENTICAL code differed from each other: one
#      clicked, one teleported. A walk left to the model is a lottery, so the
#      journey is declared from the record and the driver executes it.
#   E  Half the build only renders once there is data in it, and there was no
#      way to give a build sample data. A look that cannot see a screen must
#      say so in one plain sentence, not call it broken and not call it fine.
#   G  Switching Number One on beside two missions already parked at Verify did
#      nothing at all to them. The captain's ruling: "review everyone at verify
#      that doesn't have a previous Number One score."
#
# WHAT IS NOT FAKED HERE. The walk is driven through REAL HEADLESS CHROME
# against real local fixture pages — the layer part F changes is the browser
# driver, and a stub of it would prove nothing (the standing rule). The
# deterministic arithmetic either side of it (the journey built from a record,
# the carry check, the sweep's choice of missions) is proven against crafted
# inputs of the shape the real ones have.
#
# ZERO SPEND. No worker CLI runs anywhere in this file.
#
# Usage: bash tests/lcars-xo-journey.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-xo/xo.sh"
DRIVER="$REPO_ROOT/skills/lcars-xo/xo-drive.js"
JOURNEY="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
PARTS="$REPO_ROOT/skills/lcars-xo/xo-parts.py"
OBSERVE="$REPO_ROOT/skills/lcars-xo/xo-observe.py"
PY="${LCARS_PYTHON_BIN:-python3}"
NODE="${LCARS_NODE_BIN:-node}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "lcars xo — the walk (F), the seed (E), the sweep (G)"

# ===========================================================================
# THE FIXTURE — a two-screen flow with a gate, in the shape the real one has:
# the second screen is reachable ONLY by clicking, the month on screen one is
# NOT the month on screen two (a carry fault), and the gate refuses while the
# note is blank.
# ===========================================================================
APP="$TMPROOT/app"; mkdir -p "$APP"
cat >"$APP/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Tides</title>
<body style="font-family:sans-serif">
<div id="one">
  <h1>Readings</h1>
  <h2>August 2026</h2>
  <button id="startBtn">Pull data &amp; start</button>
  <button id="helpBtn">Help</button>
</div>
<div id="two" style="display:none">
  <h2>Pulling data · September 2026</h2>
  <textarea id="note" placeholder="Add a note for this reading…"></textarea>
  <button id="lockBtn">Lock month</button>
  <p id="out"></p>
</div>
<script>
  startBtn.onclick = function () { one.style.display = "none"; two.style.display = "block"; };
  lockBtn.onclick = function () {
    if (!note.value.trim()) { out.textContent = "Add a note first."; return; }
    out.textContent = "Locked: " + note.value;
  };
</script>
HTML
cat >"$APP/drawing.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>drawing</title>
<div id="screen-one"><h1>Readings</h1><button>Pull data &amp; start</button><button>Help</button></div>
<div id="screen-two"><h2>Collect</h2><textarea placeholder="Add a note for this reading…"></textarea>
<button>Lock month</button></div>
HTML
cat >"$TMPROOT/criteria.json" <<'JSON'
{"mission":"m","hasDrawing":true,"placeNames":[],"criteria":[
 {"id":"prd-1","text":"The reading screen offers the month and a Pull data & start button.","primary":true},
 {"id":"prd-2","text":"Lock month refuses while the note is blank.","primary":true}]}
JSON

# ===========================================================================
# F1. THE JOURNEY IS BUILT FROM THE RECORD, and each step is its own row.
# ===========================================================================
echo
echo "F1. the journey comes from the record — screen order, fields, the gate"

"$PY" "$JOURNEY" build --criteria "$TMPROOT/criteria.json" \
  --drawing-html "$APP/drawing.html" --title "Tides" \
  --out "$TMPROOT/journey.json" --criteria-out "$TMPROOT/criteria2.json" >"$TMPROOT/j.out" 2>&1
check "F1-1 the drawing's screen order becomes the first step, by its own forward control" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
s=d[\"steps\"][0]
sys.exit(0 if s[\"do\"]==\"click\" and \"pull data\" in \" \".join(s[\"match\"]).lower() else 1)' '$TMPROOT/journey.json'"
check "F1-2 the gate is a step BOTH ways — blank first, filled last" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
ph=[s.get(\"phase\") for s in d[\"steps\"] if s[\"do\"]==\"gate\"]
sys.exit(0 if ph==[\"blank\",\"filled\"] else 1)' '$TMPROOT/journey.json'"
check "F1-3 every step is its OWN requirement in the contract" \
  "\"\$PY\" -c 'import json,sys
c=json.load(open(sys.argv[1]))
rows=[x for x in c[\"criteria\"] if str(x[\"id\"]).startswith(\"journey-\")]
j=json.load(open(sys.argv[2]))
sys.exit(0 if len(rows)==len(j[\"steps\"]) and all(r.get(\"journeyStep\") for r in rows) else 1)' \
     '$TMPROOT/criteria2.json' '$TMPROOT/journey.json'"
check "F1-5 the journey fills the WHOLE form before it tries the gate's filled phase (D6)" \
  "\"\$PY\" -c 'import json,sys
j=json.load(open(sys.argv[1]))
ds=[s[\"do\"] for s in j[\"steps\"]]
g=[i for i,s in enumerate(j[\"steps\"]) if s[\"do\"]==\"gate\" and s.get(\"phase\")==\"filled\"]
f=[i for i,s in enumerate(j[\"steps\"]) if s[\"do\"]==\"type-all\"]
sys.exit(0 if f and g and f[0]<g[0] else 1)' '$TMPROOT/journey.json'"
check "F1-4 a mission whose record describes no flow gets no journey (and no walk)" \
  "\"\$PY\" '$JOURNEY' build --criteria /dev/null --out '$TMPROOT/empty.json' | grep -qi 'nothing in the record' && \
   \"\$PY\" -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"steps\"]==[] else 1)' '$TMPROOT/empty.json'"

# ===========================================================================
# F4 (S221 fix 7). A KEY IS A CONTROL.
#
# THE DEFECT. This planner read a PRD that says, twice and in plain English,
# "walk the character around the village with the arrow keys" and "updates live
# as they walk" — and emitted `"steps": []`. All three of its sources were
# about CLICKING; a canvas game has no named controls, no screens and no
# fields, so it found nothing by a definition of flow that never imagined a
# keyboard. The walk that night happened because the model improvised, and a
# guarantee that depends on the model's willingness is not a guarantee.
#
# THE RISK IN THE FIX, which is why half these rows are MISSES: the captain
# writes PRDs ABOUT the things being parsed, and three rounds in this repo have
# been lost to a regex reading his prose (S147, S156, S188). A pattern that
# matched every mention of a key would look like a triumph on the row below and
# invent walks out of sentences that say the opposite. So the misses are pinned
# here, where a loosened rule cannot quietly pass.
# ===========================================================================
echo
echo "F4. a key is a control — the record names one, the planner walks it"

kj() { # <criteria-json-text> [prd-text] — prints the journey json path
  local dir="$TMPROOT/kj$RANDOM"; mkdir -p "$dir"
  printf '%s' "$1" >"$dir/criteria.json"
  if [ $# -gt 1 ]; then printf '%s' "$2" >"$dir/prd.md"; fi
  "$PY" "$JOURNEY" build --criteria "$dir/criteria.json" \
    ${2:+--prd "$dir/prd.md"} --out "$dir/journey.json" >/dev/null 2>&1
  printf '%s' "$dir/journey.json"
}
# what keys a journey presses, in order, as "KEY:HOLD" pairs
keys_of() {
  "$PY" -c 'import json,sys
j=json.load(open(sys.argv[1]))
print(" ".join("%s:%s" % (s["pressKey"], s["hold"]) for s in j["steps"] if s["do"]=="press"))' "$1"
}

C_NONE='{"criteria":[{"id":"c1","text":"The header shows the project name."}]}'

# --- THE HIT: the record names the keys, so the journey presses them --------
J1="$(kj "$C_NONE" 'When I run the example game I can walk the character around
the village with the arrow keys, and the readout updates live as they walk.')"
check "F4-1 \"walk … with the arrow keys\" becomes press steps on BOTH axes" \
  "[ \"\$(keys_of '$J1')\" = 'ArrowRight:250 ArrowDown:250' ]"
check "F4-2 …and a movement key is HELD, not tapped (a tap moves a game ~2px)" \
  "\"\$PY\" -c 'import json,sys
j=json.load(open(sys.argv[1]))
p=[s for s in j[\"steps\"] if s[\"do\"]==\"press\"]
sys.exit(0 if p and all(s[\"hold\"]==250 and s[\"times\"]==3 for s in p) else 1)' '$J1'"
check "F4-3 …each step says what it expects to be DIFFERENT afterwards" \
  "\"\$PY\" -c 'import json,sys
j=json.load(open(sys.argv[1]))
p=[s for s in j[\"steps\"] if s[\"do\"]==\"press\"]
sys.exit(0 if p and all(\"different\" in (s.get(\"expect\") or \"\") for s in p) else 1)' '$J1'"
check "F4-4 …and each is its OWN requirement in the contract, by name" \
  "\"\$PY\" -c 'import json,sys
j=json.load(open(sys.argv[1]))
sys.exit(0 if any(s[\"do\"]==\"press\" and s.get(\"key\",\"\").startswith(\"j\") for s in j[\"steps\"]) else 1)' '$J1'"
check "F4-5 the source SAYS where the steps came from" \
  "grep -q 'the keys the record names' '$J1'"

# A TOGGLE IS TAPPED, NOT HELD. Holding F3 or Enter is not what a person does.
J2="$(kj '{"criteria":[{"id":"c1","text":"The debug overlay is toggled by F3 and its visibility does not depend on the readout."}]}')"
check "F4-6 a NON-movement key is tapped, never held" \
  "[ \"\$(keys_of '$J2')\" = 'F3:0' ]"
J3="$(kj '{"criteria":[{"id":"c1","text":"Pressing the Escape key closes the dialog."}]}')"
check "F4-7 \"the Escape key\" + a response verb is a step, tapped" \
  "[ \"\$(keys_of '$J3')\" = 'Escape:0' ]"

# ===========================================================================
# THE KNOWN MISSES. Every one of these NAMES a key. None of them is the record
# saying the build responds to one, and a widened pattern makes them all pass.
# ===========================================================================
echo
echo "F4 MISSES. named keys that must NOT become steps"

# THIS MISSION'S OWN TRAP, verbatim from its PRD. It contains "pressing" and
# "key" and sits two lines from a sentence that does name the arrow keys.
J4="$(kj "$C_NONE" 'It should be on by default when the game runs in dev mode,
so you see it without pressing any key.')"
check "F4-M1 \"without pressing any key\" invents nothing (the PRD's own trap)" \
  "[ -z \"\$(keys_of '$J4')\" ]"

# OUT OF SCOPE is about what NOT to touch. Every key it names is a key to leave
# alone — and this PRD names F3 there, in a sentence with "toggle" in it.
J5="$(kj "$C_NONE" '## Goal
Show the tile readout.

## Out of Scope
The existing F3 debug overlay — leave its contents and its F3 toggle exactly as
they are. Do not change how the arrow keys move the player.')"
check "F4-M2 a key named under \"Out of Scope\" is NOT a step" \
  "[ -z \"\$(keys_of '$J5')\" ]"

# A KEY WITH NO RESPONSE VERB is a mention, not a flow.
J6="$(kj '{"criteria":[{"id":"c1","text":"The keyboard shortcuts, including F3 and the Enter key, are listed in README.md."}]}')"
check "F4-M3 a key MENTIONED with no response verb is not a step" \
  "[ -z \"\$(keys_of '$J6')\" ]"

# ORDINARY ENGLISH. "return", "space", "tab" and "delete" are words long before
# they are keys; only "the X key" or "press X" makes them one.
J7="$(kj '{"criteria":[{"id":"c1","text":"The user can return to the dashboard, and the delete control removes the row; white space is preserved when the table moves."}]}')"
check "F4-M4 the words return/delete/space are not keys just because they appear" \
  "[ -z \"\$(keys_of '$J7')\" ]"

# A DENIAL. The build explicitly does not answer the key.
J8="$(kj '{"criteria":[{"id":"c1","text":"The panel does not respond to the arrow keys; it must not move when they are pressed."}]}')"
check "F4-M5 a sentence that DENIES the build answers the key is not a step" \
  "[ -z \"\$(keys_of '$J8')\" ]"

# THE UNCHANGED BASELINE. A record that names no key at all is exactly what it
# was — this is the row that catches a pattern matching everything.
J9="$(kj "$C_NONE" 'The header shows the project name and the footer shows the version.')"
check "F4-M6 a record with no key in it produces no journey at all, as before" \
  "\"\$PY\" -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"steps\"]==[] else 1)' '$J9'"

# --- THE CAP: keys never push the click-driven journey out ------------------
check "F4-8 at most 3 key steps, so a chatty record cannot fill the journey" \
  "\"\$PY\" -c 'import json,sys
j=json.load(open(sys.argv[1]))
sys.exit(0 if len([s for s in j[\"steps\"] if s[\"do\"]==\"press\"]) <= 3 else 1)' \
   \"\$(kj '{\"criteria\":[{\"id\":\"c1\",\"text\":\"Pressing the Enter key submits; the Escape key closes it; the Tab key moves focus; F3 toggles the overlay; F4 toggles the grid; the arrow keys walk the player.\"}]}')\""

# ===========================================================================
# F4-REAL. THE REGRESSION THAT WOULD HAVE CAUGHT THIS: the mission's OWN
# record, on disk, the exact input that produced `"steps": []` last night.
# Read-only — the capstone checkout is never written to.
# ===========================================================================
echo
echo "F4-REAL. the mission's own record now emits a walk"
REALM="$HOME/Projects/groutwork-capstone/.git/lcars/missions/lcars-20260920-001-fea3"
if [ -s "$REALM/xo/criteria.json" ] && [ -s "$REALM/prd.md" ]; then
  "$PY" "$JOURNEY" build --criteria "$REALM/xo/criteria.json" --prd "$REALM/prd.md" \
    --title "Example game: show the player's live tile coordinates on screen in dev mode" \
    --out "$TMPROOT/real-journey.json" >/dev/null 2>&1
  check "F4-R1 the real mission's record now produces press steps (it produced NONE)" \
    "\"\$PY\" -c 'import json,sys
j=json.load(open(sys.argv[1]))
sys.exit(0 if [s for s in j[\"steps\"] if s[\"do\"]==\"press\"] else 1)' '$TMPROOT/real-journey.json'"
  check "F4-R2 …the arrow keys, HELD, on both axes — the walk it had to improvise" \
    "[ \"\$(keys_of '$TMPROOT/real-journey.json')\" = 'F3:0 ArrowRight:250 ArrowDown:250' ]"
  check "F4-R3 …and its own F3 criterion is walked too, as a tap" \
    "grep -q '\"pressKey\": \"F3\"' '$TMPROOT/real-journey.json'"
else
  printf '  (the S221 mission record is not on this machine — F3-REAL SKIPPED)\n'
fi

# ===========================================================================
# F2. THE WALK ITSELF — real headless Chrome, real clicks, real typing.
# ===========================================================================
echo
echo "F2. it walks: clicks in, types, tries the gate both ways (real browser)"

OUT="$TMPROOT/shots"; mkdir -p "$OUT"
"$NODE" "$DRIVER" --url "file://$APP/index.html" --out "$OUT" \
  --journey "$TMPROOT/journey.json" --walk-out "$TMPROOT/walk.json" \
  --parts-out "$TMPROOT/build-parts.json" --prefix t >"$TMPROOT/drive.json" 2>"$TMPROOT/drive.err"
check "F2-0 the driver ran and wrote the walk record" "[ -s '$TMPROOT/walk.json' ]"
check "F2-1 it reached the second screen by CLICKING — no address jumps at all" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
m=w[\"moves\"]
sys.exit(0 if m[\"clicks\"]>=1 and m[\"addressJumps\"]==0 else 1)' '$TMPROOT/walk.json'"
check "F2-2 it TYPED into the field and the page read the text back" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
t=[s for s in w[\"steps\"] if s[\"do\"]==\"type\" and s[\"status\"]==\"done\"]
sys.exit(0 if t and t[0].get(\"readBack\") else 1)' '$TMPROOT/walk.json'"
check "F2-3 the gate was tried BLANK (and refused) and again once filled" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
g=[s for s in w[\"steps\"] if s[\"do\"]==\"gate\"]
blank=[s for s in g if s.get(\"phase\")==\"blank\"]
sys.exit(0 if len(g)==2 and blank and blank[0][\"status\"]==\"done\"
         and blank[0].get(\"urlAfter\")==blank[0].get(\"urlBefore\") else 1)' '$TMPROOT/walk.json'"
check "F2-4 every screen it stood on has its own reading for the layout pass" \
  "[ -s '$OUT/readouts.json' ] && \"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if len(d[\"pages\"])>=2 else 1)' '$OUT/readouts.json'"

# A STEP IT CANNOT TAKE IS NAMED, NEVER SKIPPED.
cat >"$TMPROOT/ghost.json" <<'JSON'
{"steps":[{"key":"g1","do":"click","match":["Summon the kraken"],
           "name":"click \"Summon the kraken\"","expect":"the deep"}]}
JSON
"$NODE" "$DRIVER" --url "file://$APP/index.html" --out "$TMPROOT/shots2" \
  --journey "$TMPROOT/ghost.json" --walk-out "$TMPROOT/walk2.json" --prefix g \
  >/dev/null 2>&1
check "F2-5 a step whose control is not there is 'unreachable', BY NAME, with what WAS on screen" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
sys.exit(0 if s[\"status\"]==\"unreachable\" and s[\"couldNotCheck\"]==\"unreachable\"
         and \"kraken\" in s[\"name\"].lower() and s.get(\"onScreen\") else 1)' '$TMPROOT/walk2.json'"

# A LATER ADDRESS JUMP IS RECORDED AS ONE, AND LABELLED.
cat >"$TMPROOT/actions.json" <<JSON
[{"navigate":"file://$APP/index.html"},{"screenshot":"jumped"}]
JSON
"$NODE" "$DRIVER" --url "file://$APP/index.html" --out "$TMPROOT/shots3" \
  --actions "$TMPROOT/actions.json" --walk-out "$TMPROOT/walk3.json" --prefix j \
  >/dev/null 2>"$TMPROOT/drive3.err"
check "F2-6 a URL jump past the front door is counted AND labelled 'reached by address'" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
sys.exit(0 if w[\"moves\"][\"addressJumps\"]==1 and w.get(\"jumps\") else 1)' '$TMPROOT/walk3.json' && \
   grep -q 'reached by address, not by the flow' '$TMPROOT/shots3/readout.json'"

# --- FIX ROUND 1, D6 -------------------------------------------------------
# TWO LIES THE RECORD COULD TELL, both measured on the real benchmark on
# 2026-09-19: the walk filled 2 of 19 insight fields and then claimed the
# gate's "now everything is filled" phase had been taken, and two steps that
# came back byte-identical (same address, same words, changed:false) were both
# counted among "9 of 9 steps taken".
echo
echo "F2b. a step that changed nothing was not taken; a form is filled ALL the way"

FORM="$TMPROOT/form"; mkdir -p "$FORM"
cat >"$FORM/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Insights</title>
<body style="font-family:sans-serif">
<h1>Insights</h1>
<textarea id="a" placeholder="Insight one"></textarea>
<textarea id="b" placeholder="Insight two"></textarea>
<textarea id="c" placeholder="Insight three"></textarea>
<input id="d" type="text" placeholder="Locked field">
<button id="dead">Do nothing at all</button>
<script>
  dead.onclick = function () {};
  d.addEventListener("input", function () { d.value = ""; });
</script>
HTML
cat >"$TMPROOT/deadjourney.json" <<'JSON'
{"steps":[
 {"key":"d1","do":"click","match":["Do nothing at all"],
  "name":"click \"Do nothing at all\"","expect":"something, anything"},
 {"key":"d2","do":"type-all","match":[],"text":"Number One typed this to see it carry",
  "name":"fill every field this screen still wants",
  "expect":"no empty field is left before the gate is tried"}]}
JSON
"$NODE" "$DRIVER" --url "file://$FORM/index.html" --out "$TMPROOT/shots4" \
  --journey "$TMPROOT/deadjourney.json" --walk-out "$TMPROOT/walk4.json" --prefix d \
  >/dev/null 2>&1
check "F2-7 a click that leaves the screen byte-identical is 'no-change', BY NAME — never taken" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=[x for x in w[\"steps\"] if x[\"key\"]==\"d1\"][0]
sys.exit(0 if s[\"status\"]==\"no-change\" and s[\"couldNotCheck\"]==\"nothing changed\"
         and \"nothing at all\" in s[\"name\"].lower() and s.get(\"why\") else 1)' '$TMPROOT/walk4.json'"
check "F2-8 the whole-form fill types into EVERY empty field, not the two the drawing drew" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=[x for x in w[\"steps\"] if x[\"key\"]==\"d2\"][0]
sys.exit(0 if s[\"do\"]==\"type-all\" and s[\"filled\"]==3 and s[\"fieldsOnScreen\"]==4 else 1)' '$TMPROOT/walk4.json'"
check "F2-9 …and the one it could not fill is named, in plain words, not left silent" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=[x for x in w[\"steps\"] if x[\"key\"]==\"d2\"][0]
left=s.get(\"couldNotFill\") or []
sys.exit(0 if len(left)==1 and \"locked\" in \" \".join(left).lower() and \"could not fill\" in (s.get(\"why\") or \"\") else 1)' '$TMPROOT/walk4.json'"
check "F2-10 a no-change step is NOT counted as a typing or a click that got somewhere" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
done=[x for x in w[\"steps\"] if x[\"status\"]==\"done\"]
sys.exit(0 if len(done)==1 and done[0][\"key\"]==\"d2\" and w[\"moves\"][\"typings\"]==3 else 1)' '$TMPROOT/walk4.json'"

# ===========================================================================
# F3. WHAT THE WALK MEASURED — a value that did not carry, and a control that
#     does not fit itself (the only route to a button on an undrawn screen).
# ===========================================================================
echo
echo "F3. the two measurements a pair of pictures cannot take"

"$PY" "$JOURNEY" carry --walk "$TMPROOT/walk.json" --out "$TMPROOT/carry.json" >/dev/null 2>&1
check "F3-1 a month that changes between the screen you came from and the one you land on" \
  "\"\$PY\" -c 'import json,sys
o=json.load(open(sys.argv[1]))[\"observations\"]
hit=[x for x in o if \"august\" in x[\"says\"].lower() and \"september\" in x[\"says\"].lower()]
sys.exit(0 if hit and hit[0].get(\"screen\") else 1)' '$TMPROOT/carry.json'"

# The scan, against crafted parts of the shape the browser writes: one control
# whose icon is taller than itself, one correct control with a two-line label
# (the fixture's deliberate trap), one with a hairline of rounding.
cat >"$TMPROOT/bp.json" <<'JSON'
{"url":"http://app/preview","parts":[
 {"index":1,"id":null,"name":"Back to builder","tag":"button","role":null,"interactive":true,
  "container":false,"box":{"x":0,"y":0,"w":107,"h":30},"iconBox":{"x":0,"y":0,"w":41,"h":41},"lines":3,
  "screen":"http://app/preview"},
 {"index":2,"id":"notice","name":"Two readings are stale, check the tide gauge","tag":"p","role":null,
  "interactive":false,"container":false,"box":{"x":0,"y":40,"w":230,"h":40},"iconBox":null,"lines":2,
  "screen":"http://app/preview"},
 {"index":3,"id":null,"name":"Preview","tag":"button","role":null,"interactive":true,
  "container":false,"box":{"x":0,"y":90,"w":90,"h":30},"iconBox":{"x":0,"y":90,"w":16,"h":31},"lines":1,
  "screen":"http://app/preview"}]}
JSON
"$PY" "$PARTS" scan --build "$TMPROOT/bp.json" --out "$TMPROOT/scan.json" >/dev/null 2>&1
check "F3-2 a control holding an icon bigger than itself is measured, and NAMES its screen" \
  "\"\$PY\" -c 'import json,sys
o=json.load(open(sys.argv[1]))[\"observations\"]
sys.exit(0 if len(o)==1 and \"Back to builder\" in o[0][\"says\"] and o[0][\"screen\"]==\"http://app/preview\"
         and o[0][\"measured\"][\"iconHeightPx\"]==41 else 1)' '$TMPROOT/scan.json'"
check "F3-3 FALSE ALARM — a two-line label and a 1px rounding are NOT findings" \
  "! grep -qi 'notice\|stale\|\"Preview\"' '$TMPROOT/scan.json'"

# ===========================================================================
# D-CARRY-OVER. The layout pass runs on EVERY screen the look stood on, and
# every finding names the screen it was seen on.
# ===========================================================================
echo
echo "D. the layout pass names every visited screen"

"$PY" - "$TMPROOT/readouts.json" <<'PY'
import json, sys
def el(x, t):
    return {"tag": "button", "text": t, "box": {"x": x, "y": 0, "w": 60, "h": 30},
            "interactive": True, "seen": True, "color": "rgb(0,0,0)",
            "background": "rgb(255,255,255)", "overflowX": 0, "overflowY": 0,
            "display": "inline-block"}
pages = [{"url": "http://app/one", "page": {"url": "http://app/one",
          "elements": [el(0, "ADD"), el(62, "CANCEL")]}},
         {"url": "http://app/two", "page": {"url": "http://app/two",
          "elements": [el(0, "SAVE"), el(61, "DELETE")]}}]
json.dump({"pages": pages}, open(sys.argv[1], "w"))
PY
"$PY" "$OBSERVE" "$TMPROOT/readouts.json" "$TMPROOT/obs.json" >/dev/null 2>&1
check "D-1 both screens are measured, and each finding carries its own screen" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
seen=sorted(set(o.get(\"screen\") for o in d[\"observations\"]))
sys.exit(0 if seen==[\"http://app/one\",\"http://app/two\"] and len(d[\"screens\"])==2 else 1)' '$TMPROOT/obs.json'"

# ===========================================================================
# E. THE DECLARED SEED. It is loaded BEFORE the look, from the record — and
#    when there is none, nothing is invented.
# ===========================================================================
echo
echo "E. sample data is declared, never guessed"

new_repo() { # [extra config line] -> repo path
  local repo extra="${1:-}"
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  {
    printf '{\n'
    printf '  "cloneId": "aaaaaaaa",\n'
    printf '  "projectName": "repo",\n'
    printf '  "testCommand": "true",\n'
    [ -n "$extra" ] && printf '  %s,\n' "$extra"
    printf '  "created": "2026-09-19T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$repo/.git/lcars/config.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$repo"
}

plant() { # <repo> <id> <stage> [numberOne raw]
  local repo="$1" id="$2" stage="$3" xo="${4:-}" m="$1/.git/lcars/missions/$2"
  mkdir -p "$m"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    [ -n "$xo" ] && printf '  "numberOne": %s,\n' "$xo"
    printf '  "title": "A mission",\n'
    printf '  "stage": "%s",\n' "$stage"
    printf '  "githubIssue": 7\n'
    printf '}\n'
  } >"$m/state.json"
  "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

seedrepo="$(new_repo '"verifySeed": "echo seeded > '"$TMPROOT"'/seed-ran.txt"')"
plant "$seedrepo" lcars-1 verify >/dev/null
( cd "$seedrepo" && bash "$SCRIPT" seed --mission lcars-1 --in "$seedrepo" ) >"$TMPROOT/seed.out" 2>&1
check "E-1 a seed the RECORD declares is run, and said out loud" \
  "[ -f '$TMPROOT/seed-ran.txt' ] && grep -qi 'loading the sample data' '$TMPROOT/seed.out'"
check "E-2 what ran is recorded — source, command and exit status" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d[\"declared\"] and d[\"exit\"]==0 and \"verifySeed\" in d[\"source\"] else 1)' \
     '$seedrepo/.git/lcars/missions/lcars-1/xo/seed.json'"

bare="$(new_repo)"
plant "$bare" lcars-2 verify >/dev/null
( cd "$bare" && bash "$SCRIPT" seed --mission lcars-2 --in "$bare" ) >"$TMPROOT/seed2.out" 2>&1
check "E-3 with nothing declared it invents nothing and says so" \
  "grep -qi 'no sample data is declared' '$TMPROOT/seed2.out' && \
   \"\$PY\" -c 'import json,sys
sys.exit(0 if json.load(open(sys.argv[1]))[\"declared\"] is False else 1)' \
     '$bare/.git/lcars/missions/lcars-2/xo/seed.json'"

mkdir -p "$bare/.lcars"
printf '#!/usr/bin/env bash\ntouch "%s/project-seed-ran.txt"\n' "$TMPROOT" >"$bare/.lcars/verify-seed.sh"
chmod +x "$bare/.lcars/verify-seed.sh"
( cd "$bare" && bash "$SCRIPT" seed --mission lcars-2 --in "$bare" ) >"$TMPROOT/seed3.out" 2>&1
check "E-4 a project that SHIPS .lcars/verify-seed.sh is honoured too" \
  "[ -f '$TMPROOT/project-seed-ran.txt' ] && grep -q '.lcars/verify-seed.sh' '$TMPROOT/seed3.out'"

# The one plain sentence, rendered by the report when nothing was declared.
cat >"$TMPROOT/v.json" <<'JSON'
{"score":"medium","criteria":[
 {"id":"prd-1","text":"The automated KPI row appears","impact":"high",
  "impactWhy":"the automated KPI row is high because the mission is for it.",
  "status":"untested","couldNotCheck":"unreachable","note":"no data to show it",
  "reason":"Impact high because the mission depends on it. I tried twice; I saw nothing (evidence: none). Outcome: couldn't check."}],
 "gaps":[],"escalations":[],"alsoChecked":[],"summary":"Not enough data to see it."}
JSON
cat >"$TMPROOT/c.json" <<'JSON'
{"mission":"m","hasDrawing":true,"criteria":[
 {"id":"prd-1","text":"The automated KPI row appears","primary":true,"drawnAt":"the automation bar"}]}
JSON
printf '{"declared": false}\n' >"$TMPROOT/seedno.json"
"$PY" "$REPO_ROOT/skills/lcars-xo/xo-score.py" "$TMPROOT/v.json" "$TMPROOT/c.json" \
  "$TMPROOT/report.md" "" "" "" "" "" "$TMPROOT/seedno.json" >/dev/null 2>&1
check "E-5 the report says, in one plain sentence, which screens it could not see" \
  "grep -qi 'Nothing in this repo declares sample data' '$TMPROOT/report.md' && \
   grep -qi 'the automation bar' '$TMPROOT/report.md'"

# ===========================================================================
# G. THE SWEEP. Switching Number One ON picks up what is already at Verify.
# ===========================================================================
echo
echo "G. xo on sweeps the unscored missions waiting at Verify"

SWEEPLOG="$TMPROOT/swept.txt"
cat >"$TMPROOT/sweepbin" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$SWEEPLOG"
EOF
chmod +x "$TMPROOT/sweepbin"

g1="$(new_repo)"
plant "$g1" lcars-unscored verify >/dev/null
plant "$g1" lcars-scored   verify '{"status": "engaged", "score": "medium"}' >/dev/null
plant "$g1" lcars-building implement >/dev/null
: >"$SWEEPLOG"
( cd "$g1" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on1.out" 2>&1
check "G-1 only the mission with NO score on record is swept" \
  "[ \"\$(cat '$SWEEPLOG')\" = 'lcars-unscored' ]"
check "G-2 it says what it picked up, in plain words" \
  "grep -q \"I'm reviewing 1 mission that was waiting at Verify\" '$TMPROOT/on1.out' && \
   grep -q 'lcars-unscored' '$TMPROOT/on1.out'"

# A verdict on disk is a score on record too — the other two places.
g2="$(new_repo)"
m="$(plant "$g2" lcars-hasverdict verify)"
mkdir -p "$m/xo"; printf '{"score":"high"}\n' >"$m/xo/verdict.json"
plant "$g2" lcars-optedout verify '{"optOut": true}' >/dev/null
: >"$SWEEPLOG"
( cd "$g2" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on2.out" 2>&1
check "G-3 a look already on disk counts as a score; an opted-out mission is left alone" \
  "[ ! -s '$SWEEPLOG' ] && ! grep -q \"I'm reviewing\" '$TMPROOT/on2.out'"

# A mission stamped by ANOTHER laptop is not ours to review.
g3="$(new_repo)"
m="$(plant "$g3" lcars-remote verify)"
"$PY" - "$m/state.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
out = {"id": d["id"], "cloneId": "zzzzzzzz"}
out.update(d)
out["cloneId"] = "zzzzzzzz"
json.dump(out, open(p, "w"), indent=1)
PY
: >"$SWEEPLOG"
( cd "$g3" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on3.out" 2>&1
check "G-4 another laptop's mission is not swept" "[ ! -s '$SWEEPLOG' ]"

# STANDING DOWN STOPS THE CHAIN — between missions, never mid-round.
g4="$(new_repo)"
plant "$g4" lcars-a1 verify >/dev/null
plant "$g4" lcars-a2 verify >/dev/null
plant "$g4" lcars-a3 verify >/dev/null
cat >"$TMPROOT/standdownbin" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$SWEEPLOG"
# The captain stands it down WHILE the first round is running.
"$PY" - "$g4/.git/lcars/config.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["numberOne"] = {"enabled": False}
json.dump(d, open(p, "w"), indent=1)
PY
EOF
chmod +x "$TMPROOT/standdownbin"
: >"$SWEEPLOG"
( cd "$g4" && LCARS_XO_SWEEP_BIN="$TMPROOT/standdownbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on4.out" 2>&1
check "G-5 standing down mid-round stops the chain AFTER that mission, not before it" \
  "[ \"\$(grep -c . '$SWEEPLOG')\" = '1' ] && grep -qi 'stood down' '$TMPROOT/on4.out'"
check "G-6 the sweep is journaled on each mission it takes" \
  "grep -q 'swept' '$g1/.git/lcars/missions/lcars-unscored/journal.jsonl' 2>/dev/null || \
   grep -rq 'swept' '$g1/.git/lcars/missions/lcars-unscored/' 2>/dev/null"

# ---------------------------------------------------------------------------
# G-7..G-10 — THE SWEEP'S LOOK IS CAGED, like every other look (S221).
#
# THE DEFECT (captain, 2026-09-20): the bench caps a look at 45 minutes; the
# look `lcars xo on` launched had no time limit at all, so one build that would
# not answer could hold the sweep — and every mission queued behind it — open
# all night. His words: it should "limit the time like the normal pathway does".
# The cage is xo_cage, the same helper the seed and the project's own suite use.
# ---------------------------------------------------------------------------
g5="$(new_repo)"
plant "$g5" lcars-slow verify >/dev/null
plant "$g5" lcars-next verify >/dev/null
cat >"$TMPROOT/hangbin" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$SWEEPLOG"
sleep 30
EOF
chmod +x "$TMPROOT/hangbin"
: >"$SWEEPLOG"
started="$(date +%s)"
( cd "$g5" && LCARS_XO_SWEEP_BIN="$TMPROOT/hangbin" LCARS_XO_LOOK_TIMEOUT=2 \
    LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on5.out" 2>&1
elapsed=$(( $(date +%s) - started ))
check "G-7 a sweep look that outstays the cage is stopped, not waited on" \
  "[ '$elapsed' -lt 20 ]"
check "G-8 …and it says so LOUDLY, naming the mission and the limit" \
  "grep -qi 'lcars-slow' '$TMPROOT/on5.out' && \
   grep -qi 'still looking after' '$TMPROOT/on5.out'"
check "G-9 …it is journaled on that mission, so a half-verdict cannot pass for a look" \
  "grep -q 'sweep-timeout' '$g5/.git/lcars/missions/lcars-slow/number-one.jsonl'"
check "G-10 …and the sweep carries on to the next mission" \
  "grep -q 'lcars-next' '$SWEEPLOG'"

# The cage's DEFAULT is the same 45 minutes the bench pathway uses, and the
# override is the only place the number may come from.
check "G-11 the default cage is 45 minutes (2700s), stated once" \
  "grep -q 'XO_LOOK_TIMEOUT=\"\${LCARS_XO_LOOK_TIMEOUT:-2700}\"' '$REPO_ROOT/skills/lcars-xo/xo.sh'"

echo
printf '  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
