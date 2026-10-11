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
# F6 (S226). THE CRITERIA ARE THE FLOOR AND THE CEILING.
#
# THE DEFECT, measured on a real mission on 2026-09-23. The build was a single
# save-slot panel — one screen, no `screen-*` container — so screens_of found
# nothing, and the ONLY step the scraper produced was the Escape key it read
# out of the PRD prose. The journey walked ONE step. Yet the PRD had SIX
# acceptance criteria describing things a PLAYER does — open the panel, type a
# name and note and Lock, Lock-while-empty, Unlock, Preview, Back-to-map — and
# the grader reported on all of them as though it had done the work. Nothing
# anywhere asked: "did I attempt the things I am going to be graded on?"
#
# THE FIX. Every person-checkable criterion (source prd/journey, minus the
# journey-* rows that ARE the walk) gets an ATTEMPT — a walk step — or a
# recorded reason it could not be turned into one. The criteria are the FLOOR
# (six person promises ⇒ six attempts-or-reasons) and the CEILING (nothing on
# the panel that a criterion does not name gets clicked — no overkill). The
# coverage is emitted as data: attempted N of M, and per-criterion which step
# attempted it or why none could.
# ===========================================================================
echo
echo "F6. every person promise gets an attempt or a recorded reason (floor & ceiling)"

PANEL="$TMPROOT/panel"; mkdir -p "$PANEL"
cat >"$PANEL/criteria.json" <<'JSON'
{"mission":"m","hasDrawing":true,"placeNames":["lock","unlock","preview","slot-name","slot-note"],"criteria":[
 {"id":"prd-1","text":"A player can open the save-slot panel from the game screen.","source":"prd","primary":true},
 {"id":"prd-2","text":"Typing a slot name and a note, then pressing Lock slot, locks the slot.","source":"prd","primary":true},
 {"id":"prd-3","text":"Pressing Lock slot while either field is empty REFUSES and says on screen which field is still empty.","source":"prd","primary":true},
 {"id":"prd-4","text":"Pressing Unlock slot on a locked slot makes it editable again.","source":"prd","primary":true},
 {"id":"prd-5","text":"Preview shows what the slot will look like in the load list.","source":"prd","primary":true},
 {"id":"prd-6","text":"Back to the map screen returns the player to the game.","source":"prd","primary":true},
 {"id":"t-1-ac1","text":"Opening the panel calls input.suspend() so the player cannot move behind the overlay.","source":"plan","primary":false},
 {"id":"part-lock","text":"the Lock slot button matches the drawing.","source":"drawing","primary":true}]}
JSON
# The panel's parts, exactly the shape drawing-parts.json carries (pages[].parts),
# plus ONE control NO criterion names — the ceiling's tripwire.
cat >"$PANEL/drawing-parts.json" <<'JSON'
{"url":"file:///panel.html","pages":[{"url":"file:///panel.html","title":"Save slots","parts":[
 {"index":1,"id":"panel-title","name":"Save slots","tag":"h1","role":null,"interactive":false,"container":false},
 {"index":3,"id":"slot-name","name":"name this save","placeholder":"name this save","tag":"input","role":null,"interactive":true,"container":false},
 {"index":5,"id":"slot-note","name":"a line about where you are","placeholder":"a line about where you are","tag":"textarea","role":null,"interactive":true,"container":false},
 {"index":6,"id":"lock","name":"Lock slot","tag":"button","role":null,"interactive":true,"container":false},
 {"index":7,"id":"unlock","name":"Unlock","tag":"button","role":null,"interactive":true,"container":false},
 {"index":8,"id":"preview","name":"Preview","tag":"button","role":null,"interactive":true,"container":false},
 {"index":9,"id":"nuke","name":"Delete everything","tag":"button","role":null,"interactive":true,"container":false}]}]}
JSON
printf '# Goal\n\nPressing Escape reveals the save panel over the game canvas.\n' >"$PANEL/prd.md"

"$PY" "$JOURNEY" build --criteria "$PANEL/criteria.json" \
  --drawing "$PANEL/drawing-parts.json" --prd "$PANEL/prd.md" --title "Save slots" \
  --out "$PANEL/journey.json" --criteria-out "$PANEL/criteria2.json" >"$PANEL/j.out" 2>&1

# cov <journey.json> <python-body-using d and c> — d=journey, c=coverage
cov() { "$PY" -c "import json,sys
d=json.load(open(sys.argv[1]))
c=d.get('coverage') or {}
$2" "$1"; }

check "F6-1 the coverage counts the SIX person promises — floor is the acceptance list" \
  "cov '$PANEL/journey.json' 'sys.exit(0 if c.get(\"total\")==6 else 1)'"
check "F6-2 FIVE of the six were turned into an attempt (was ONE step total before)" \
  "cov '$PANEL/journey.json' 'sys.exit(0 if c.get(\"attempted\")==5 else 1)'"
check "F6-3 back-to-map is the one that could NOT be set up, recorded WITH its reason" \
  "cov '$PANEL/journey.json' 'r=[x for x in c[\"criteria\"] if x[\"id\"]==\"prd-6\"][0]
sys.exit(0 if (not r[\"attempted\"]) and r.get(\"reason\") and \"map\" in r[\"reason\"].lower() else 1)'"
check "F6-4 every ATTEMPTED promise names a real walk step that exists in the journey" \
  "cov '$PANEL/journey.json' 'keys=set(s[\"key\"] for s in d[\"steps\"])
att=[x for x in c[\"criteria\"] if x[\"attempted\"]]
sys.exit(0 if att and all(x.get(\"step\") in keys for x in att) else 1)'"
check "F6-5 the panel is now WALKED — typing, the gate both ways, and the named buttons" \
  "cov '$PANEL/journey.json' 'ds=[s[\"do\"] for s in d[\"steps\"]]
ph=[s.get(\"phase\") for s in d[\"steps\"] if s[\"do\"]==\"gate\"]
clicks=\" \".join(\" \".join(s.get(\"match\") or []) for s in d[\"steps\"] if s[\"do\"]==\"click\").lower()
sys.exit(0 if \"type\" in ds and \"blank\" in ph and \"filled\" in ph and \"unlock\" in clicks and \"preview\" in clicks else 1)'"
check "F6-6 the CEILING holds — the un-named 'Delete everything' button is NEVER clicked" \
  "cov '$PANEL/journey.json' 'blob=\" \".join(\" \".join(s.get(\"match\") or [])+\" \"+s.get(\"name\",\"\") for s in d[\"steps\"]).lower()
sys.exit(0 if \"delete everything\" not in blob and \"nuke\" not in blob else 1)'"
check "F6-7 prd-1 (open the panel) is attempted BY the Escape key step — not fabricated anew" \
  "cov '$PANEL/journey.json' 'r=[x for x in c[\"criteria\"] if x[\"id\"]==\"prd-1\"][0]
st=[s for s in d[\"steps\"] if s[\"key\"]==r.get(\"step\")]
sys.exit(0 if r[\"attempted\"] and st and st[0][\"do\"]==\"press\" else 1)'"
check "F6-8 a ticket (plan) criterion and a drawing criterion are NOT in the person floor" \
  "cov '$PANEL/journey.json' 'ids=set(x[\"id\"] for x in c[\"criteria\"])
sys.exit(0 if \"t-1-ac1\" not in ids and \"part-lock\" not in ids else 1)'"
check "F6-9 the coverage is stamped onto the contract too, for the report to read" \
  "\"\$PY\" -c 'import json,sys
c=json.load(open(sys.argv[1]))
pc=c.get(\"personCoverage\") or {}
sys.exit(0 if pc.get(\"total\")==6 and pc.get(\"attempted\")==5 else 1)' '$PANEL/criteria2.json'"

# ── THE CONTROL: a MULTI-SCREEN build must not balloon. Its person promises
# are already attempted by the scraped screen-walk, so coverage is full and NOT
# ONE extra step is invented. This is the anti-overkill half, proven on the F1
# journey built at the top of this file.
check "F6-10 the two-screen fixture is 2 of 2 attempted with NO invented steps (no balloon)" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
c=d.get(\"coverage\") or {}
named=[s for s in d[\"steps\"] if s.get(\"bornOf\")==\"named-click\"]
sys.exit(0 if c.get(\"total\")==2 and c.get(\"attempted\")==2 and not named else 1)' '$TMPROOT/journey.json'"

# ===========================================================================
# F7 (Number One). A WALK WITH NO DRAWING MUST STILL WALK.
#
# THE DEFECT, measured across six runs on 2026-09-23/24. The walk planner reads
# the DRAWING to learn what screens and controls exist. The two missions that
# had NO drawing attempted the LEAST work (1 of 4, 0 of 4) and both PASSED,
# while every defect found that round came from a mission that HAD a drawing.
# With no drawing the planner had almost nothing to build steps from, so it
# collapsed to "I couldn't set it up" for everything.
#
# THE FIX. With no drawing, the walk's steps are derived from the REQUIREMENTS
# themselves — each person promise that names something DOABLE (an action on a
# place) becomes a real step, stamped derivedFrom:"requirement". A drawing,
# when present, still wins (its steps are stamped derivedFrom:"drawing"). And
# "I couldn't set it up" now means a step was genuinely unreachable — never
# "nobody gave me a drawing".
# ===========================================================================
echo
echo "F7. no drawing? still walk — derive the steps from the requirements"

NODR="$TMPROOT/nodrawing"; mkdir -p "$NODR"
cat >"$NODR/criteria.json" <<'JSON'
{"mission":"m","hasDrawing":false,"criteria":[
 {"id":"prd-1","text":"A player can pause the game from the game screen.","source":"prd","primary":true},
 {"id":"prd-2","text":"A player can open the settings panel.","source":"prd","primary":true},
 {"id":"prd-3","text":"The header shows the project name.","source":"prd","primary":true}]}
JSON
printf '# Goal\n\nThe game can be paused and the settings opened.\n' >"$NODR/prd.md"

# NO --drawing is passed: this is the collapse case, cured.
"$PY" "$JOURNEY" build --criteria "$NODR/criteria.json" --prd "$NODR/prd.md" \
  --title "Pausable game" --out "$NODR/journey.json" \
  --criteria-out "$NODR/criteria2.json" >"$NODR/j.out" 2>&1

ncov() { "$PY" -c "import json,sys
d=json.load(open(sys.argv[1]))
c=d.get('coverage') or {}
$2" "$1"; }

check "F7-1 with NO drawing the walk still produces real steps (was empty/collapsed)" \
  "\"\$PY\" -c 'import json,sys; sys.exit(0 if len(json.load(open(sys.argv[1]))[\"steps\"])>=2 else 1)' '$NODR/journey.json'"
check "F7-2 the two DOABLE promises are each turned into an attempt, not a couldn't" \
  "ncov '$NODR/journey.json' 'sys.exit(0 if c.get(\"total\")==3 and c.get(\"attempted\")==2 else 1)'"
check "F7-3 each derived step RECORDS its source as the requirement (not the drawing)" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
st=[s for s in d[\"steps\"] if s.get(\"promiseId\")]
sys.exit(0 if st and all(s.get(\"derivedFrom\")==\"requirement\" for s in st) else 1)' '$NODR/journey.json'"
check "F7-4 every step carries derivedFrom in {drawing,requirement}" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d[\"steps\"] and all(s.get(\"derivedFrom\") in (\"drawing\",\"requirement\") for s in d[\"steps\"]) else 1)' '$NODR/journey.json'"
check "F7-5 pause and open each name a real step attempting them" \
  "ncov '$NODR/journey.json' 'keys=set(s[\"key\"] for s in d[\"steps\"])
att=[x for x in c[\"criteria\"] if x[\"id\"] in (\"prd-1\",\"prd-2\")]
sys.exit(0 if len(att)==2 and all(x[\"attempted\"] and x[\"step\"] in keys for x in att) else 1)'"
check "F7-6 a display-only promise (\"shows\") is the one NOT attempted — a genuine miss" \
  "ncov '$NODR/journey.json' 'r=[x for x in c[\"criteria\"] if x[\"id\"]==\"prd-3\"][0]
sys.exit(0 if not r[\"attempted\"] and r.get(\"reason\") else 1)'"
check "F7-7 its reason does NOT blame a missing drawing — it says what it means" \
  "ncov '$NODR/journey.json' 'r=[x for x in c[\"criteria\"] if x[\"id\"]==\"prd-3\"][0]
sys.exit(0 if \"drawing\" not in (r.get(\"reason\") or \"\").lower() else 1)'"
check "F7-8 the derived steps CLICK toward what the requirement names (pause / settings)" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
blob=\" \".join(\" \".join(s.get(\"match\") or []) for s in d[\"steps\"]).lower()
sys.exit(0 if \"pause\" in blob and \"settings\" in blob else 1)' '$NODR/journey.json'"

# ── THE DRAWING STILL WINS: the panel journey's scraped steps are stamped
# derivedFrom:"drawing", and the two-screen fixture's clicks are too. No regress.
check "F7-9 a scraped drawing step records derivedFrom:\"drawing\" (the panel walk)" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
dr=[s for s in d[\"steps\"] if s.get(\"derivedFrom\")==\"drawing\"]
sys.exit(0 if dr else 1)' '$PANEL/journey.json'"
check "F7-10 the two-screen fixture's click steps are drawing-derived, not requirement" \
  "\"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
cl=[s for s in d[\"steps\"] if s[\"do\"]==\"click\" and s.get(\"match\")]
sys.exit(0 if cl and all(s.get(\"derivedFrom\")==\"drawing\" for s in cl) else 1)' '$TMPROOT/journey.json'"

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
# F5 (S225). A REFUSAL IS A SENTENCE, NOT A SILENCE — and it is answered once.
#
# THE ROW THIS COST HIM, in his own words. He clicked "Lock month" in his app,
# read the refusal, saw it wanted three missing insights, said "I can do that
# easily", filled them, and locked it. Number One ran a fixed script instead: a
# `type-all` that filled ONE field and gave up on two KPI value boxes, then
# clicked Lock month regardless. The app correctly refused, nothing changed, and
# the record said:
#
#   "I did it and the screen was the same before and after — same address,
#    same words — so I cannot say whether it worked."
#
# It could not tell "the button is broken" from "I never got the form ready".
# Three faults, all of them the LOOK's, and one fixture per fault:
#
#   (a) `status: "refused"` was set in three places with NOTHING recorded about
#       why — while the `unreachable` case one branch above always captured a
#       reason. Refused and unreachable are siblings; only one of them talked.
#   (b) There was no retry anywhere in the driver. A person reads the refusal,
#       does what it names, and tries again. This does exactly that and no more:
#       ONLY the fields the product's own refusal named, and ONE more attempt.
#   (c) `type-all` assigned the SAME string to every empty field, so a browser
#       silently coerced it to "" in every `input[type=number]` and the read-back
#       check recorded "could not fill". Number boxes were selected and then
#       structurally unfillable.
#
# REAL HEADLESS CHROME against real local pages, as the rest of F2 is: the layer
# under test IS the browser driver and a stub of it would prove nothing.
# ===========================================================================
echo
echo "F5. a refusal carries its text, is answered once, and number boxes fill"

# --- FIXTURE A: the captain's month lock, reproduced -----------------------
# A gate that names EXACTLY what it is missing, two of the three fields being
# number boxes, and a message the page marks as a message (role=alert) the way
# a real form does.
LOCK="$TMPROOT/lock"; mkdir -p "$LOCK"
cat >"$LOCK/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Month lock</title>
<body style="font-family:sans-serif">
<h1>September readings</h1>
<div id="msg" role="alert"></div>
<textarea id="i1" placeholder="Add an insight for this KPI"></textarea>
<input id="v1" type="number" placeholder="Insight value">
<input id="v2" type="number" placeholder="Target value">
<button id="lock">Lock month</button>
<p id="out"></p>
<script>
  lock.onclick = function () {
    var miss = [];
    if (!i1.value.trim()) miss.push("an insight");
    if (!v1.value) miss.push("an insight value");
    if (!v2.value) miss.push("a target value");
    if (miss.length) {
      msg.textContent = "Add " + miss.join(", ") + " before locking the month.";
      return;
    }
    msg.textContent = "";
    out.textContent = "September is locked.";
  };
</script>
HTML

# --- (c) the whole-form fill must actually fill a number box ---------------
cat >"$TMPROOT/lockfill.json" <<'JSON'
{"steps":[
 {"key":"f1","do":"type-all","match":[],"text":"Number One typed this to see it carry",
  "name":"fill every field this screen still wants",
  "expect":"no empty field is left before the gate is tried"},
 {"key":"f2","do":"gate","phase":"filled","match":["Lock month"],
  "name":"click \"Lock month\" with the form filled","expect":"the month locks"}]}
JSON
"$NODE" "$DRIVER" --url "file://$LOCK/index.html" --out "$TMPROOT/shots5" \
  --journey "$TMPROOT/lockfill.json" --walk-out "$TMPROOT/walk5.json" --prefix n \
  >/dev/null 2>&1
check "F5-1 (c) the whole-form fill fills the NUMBER boxes too — nothing left behind" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=[x for x in w[\"steps\"] if x[\"key\"]==\"f1\"][0]
sys.exit(0 if s[\"filled\"]==3 and s[\"fieldsOnScreen\"]==3 and not s.get(\"couldNotFill\") else 1)' '$TMPROOT/walk5.json'"
check "F5-2 (c) …with a value the box will TAKE, and the record says which value went where" \
  "\"\$PY\" -c 'import json,sys,re
w=json.load(open(sys.argv[1]))
s=[x for x in w[\"steps\"] if x[\"key\"]==\"f1\"][0]
vals=dict(zip(s.get(\"filledNames\") or [], s.get(\"typedValues\") or []))
nums=[v for k,v in vals.items() if \"value\" in k]
sys.exit(0 if len(nums)==2 and all(re.match(r\"^-?[0-9.]+$\", str(v)) for v in nums) else 1)' '$TMPROOT/walk5.json'"
check "F5-3 (c) …and the gate the form feeds then goes THROUGH — the proof it is really filled" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=[x for x in w[\"steps\"] if x[\"key\"]==\"f2\"][0]
sys.exit(0 if s[\"status\"]==\"done\" and s[\"changed\"] and \"locked\" in (s.get(\"textAfter\") or \"\").lower() else 1)' '$TMPROOT/walk5.json'"

# --- (a)+(b) the gate alone: it refuses, it SAYS why, and it is answered ----
cat >"$TMPROOT/lockgate.json" <<'JSON'
{"steps":[
 {"key":"g1","do":"gate","phase":"filled","match":["Lock month"],
  "name":"click \"Lock month\"","expect":"the month locks"}]}
JSON
"$NODE" "$DRIVER" --url "file://$LOCK/index.html" --out "$TMPROOT/shots6" \
  --journey "$TMPROOT/lockgate.json" --walk-out "$TMPROOT/walk6.json" --prefix r \
  >/dev/null 2>&1
check "F5-4 (a) the refusal is RECORDED, in the screen's own words" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
t=(s.get(\"refusal\") or {}).get(\"text\") or \"\"
sys.exit(0 if \"before locking the month\" in t.lower() else 1)' '$TMPROOT/walk6.json'"
check "F5-5 (b) it did ONLY what the refusal named — those three fields, by name" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
r=s.get(\"repair\") or {}
got=sorted(f[\"name\"] for f in (r.get(\"filled\") or []))
sys.exit(0 if len(got)==3 and not r.get(\"couldNotFill\") else 1)' '$TMPROOT/walk6.json'"
check "F5-6 (b) …then tried the SAME action once more, and it went through" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
sys.exit(0 if s[\"status\"]==\"done\" and s.get(\"repaired\") is True and s.get(\"attempts\")==2 else 1)' '$TMPROOT/walk6.json'"
check "F5-7 (b) …and a repaired pass never wears the \"I cannot say whether it worked\" sentence" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
why=(s.get(\"why\") or \"\").lower()
sys.exit(0 if s[\"status\"]!=\"no-change\" and \"cannot say whether it worked\" not in why
         and not s.get(\"couldNotCheck\") else 1)' '$TMPROOT/walk6.json'"
check "F5-8 a reader can tell a REPAIRED pass from a first-try pass" \
  "\"\$PY\" -c 'import json,sys
one=json.load(open(sys.argv[1]))[\"steps\"][0]
two=[x for x in json.load(open(sys.argv[2]))[\"steps\"] if x[\"key\"]==\"f2\"][0]
sys.exit(0 if one.get(\"repaired\") and not two.get(\"repaired\")
         and two.get(\"attempts\") in (None,1) else 1)' '$TMPROOT/walk6.json' '$TMPROOT/walk5.json'"

# --- FIXTURE B: a control that refuses and names nothing actionable --------
# A disabled button with a tooltip. It is one of the three sites that set
# "refused" with nothing recorded, and there is not a single field on the page,
# so it is ALSO the narrowness guard: with nothing named, nothing is invented.
SHUT="$TMPROOT/shut"; mkdir -p "$SHUT"
cat >"$SHUT/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Closed month</title>
<body style="font-family:sans-serif">
<h1>August readings</h1>
<button id="lock" disabled title="This month is closed — reopen it before locking">Lock month</button>
</body>
HTML
cat >"$TMPROOT/shutjourney.json" <<'JSON'
{"steps":[{"key":"s1","do":"click","match":["Lock month"],
  "name":"click \"Lock month\"","expect":"the month locks"}]}
JSON
"$NODE" "$DRIVER" --url "file://$SHUT/index.html" --out "$TMPROOT/shots7" \
  --journey "$TMPROOT/shutjourney.json" --walk-out "$TMPROOT/walk7.json" --prefix s \
  >/dev/null 2>&1
check "F5-9 (a) a control that refuses carries what it told me — the tooltip, not a silence" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
t=((s.get(\"refusal\") or {}).get(\"text\") or \"\") + \" \" + (s.get(\"why\") or \"\")
sys.exit(0 if s[\"status\"]==\"refused\" and \"reopen it before locking\" in t.lower() else 1)' '$TMPROOT/walk7.json'"
check "F5-10 (b) a refusal that names nothing actionable invents NOTHING — no fill, no retry" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
sys.exit(0 if not s.get(\"repair\") and s.get(\"attempts\") in (None,1)
         and w[\"moves\"][\"typings\"]==0 and w[\"moves\"][\"clicks\"]==0 else 1)' '$TMPROOT/walk7.json'"

# --- FIXTURE C: it refuses, we do what it asked, and it refuses again ------
# The genuine fault. It must read as a fault with TWO attempts behind it, never
# as a couldn't-check and never as the look's own failure to fill the form.
STUCK="$TMPROOT/stuck"; mkdir -p "$STUCK"
cat >"$STUCK/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>Vault</title>
<body style="font-family:sans-serif">
<h1>Vault</h1>
<div id="msg" role="alert"></div>
<input id="code" type="number" placeholder="Access code">
<button id="go">Unlock</button>
<script>
  go.onclick = function () { msg.textContent = "Add an access code before unlocking."; };
</script>
HTML
cat >"$TMPROOT/stuckjourney.json" <<'JSON'
{"steps":[{"key":"v1","do":"gate","phase":"filled","match":["Unlock"],
  "name":"click \"Unlock\"","expect":"the vault opens"}]}
JSON
"$NODE" "$DRIVER" --url "file://$STUCK/index.html" --out "$TMPROOT/shots8" \
  --journey "$TMPROOT/stuckjourney.json" --walk-out "$TMPROOT/walk8.json" --prefix v \
  >/dev/null 2>&1
check "F5-11 (b) refused a SECOND time is a fault with two attempts behind it, not a shrug" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
s=w[\"steps\"][0]
sys.exit(0 if s[\"status\"]==\"refused\" and s.get(\"attempts\")==2 and s.get(\"refusedTwice\") is True
         and s.get(\"repaired\") is not True else 1)' '$TMPROOT/walk8.json'"
check "F5-12 …and it says all of it in one sentence a person can act on" \
  "\"\$PY\" -c 'import json,sys
w=json.load(open(sys.argv[1]))
why=(w[\"steps\"][0].get(\"why\") or \"\").lower()
sys.exit(0 if \"access code\" in why and \"again\" in why and \"cannot say whether it worked\" not in why else 1)' '$TMPROOT/walk8.json'"
check "F5-13 the number box the refusal named WAS filled before the second try (c feeding b)" \
  "\"\$PY\" -c 'import json,sys,re
w=json.load(open(sys.argv[1]))
f=(w[\"steps\"][0].get(\"repair\") or {}).get(\"filled\") or []
sys.exit(0 if len(f)==1 and \"access code\" in f[0][\"name\"] and re.match(r\"^-?[0-9.]+$\", str(f[0][\"value\"])) else 1)' '$TMPROOT/walk8.json'"

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
# G. THE CATCH-UP. Switching Number One ON NAMES what is already parked at
#    Verify; `--sweep` is the word that works through it.
# ===========================================================================
#
# WHAT MOVED, AND WHY (S241, the captain's ruling). G used to assert that
# `xo on --engine …` SWEPT. It did, and it said so first — but a verb that
# reads like a setting was starting real, billable work from one word: five
# missions parked meant five builds launched, five browsers driven, five
# workers hired. His ruling was "keep the catch-up, make it opt-in", so the
# DEFAULT is now the free announcement and `--sweep` runs the backlog.
#
# NONE OF THESE SEVEN WERE DELETED. Each still proves a real contract, now
# stated as two halves: the default starts NOTHING and says what is waiting,
# and the opt-in behaves exactly as the default used to — same choice of
# missions, same order, same cage, same stand-down between rounds. The opt-in
# half is deliberately the CONTROL: break `--sweep` and G-1, G-5 and G-7..G-10
# all go red.
echo
echo "G. xo on names what is waiting at Verify; --sweep works through it"

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
# THE DEFAULT — switch on with no flags at all.
( cd "$g1" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on1.out" 2>&1
default_swept="$(cat "$SWEEPLOG")"
# THE OPT-IN, same repo — and this half is the control for the whole section.
: >"$SWEEPLOG"
( cd "$g1" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot --sweep ) >"$TMPROOT/on1b.out" 2>&1
check "G-1 switching on alone starts NOTHING; --sweep takes only the mission with no score on record" \
  "[ -z '$default_swept' ] && [ \"\$(cat '$SWEEPLOG')\" = 'lcars-unscored' ]"
check "G-2 it NAMES what is waiting and the one word that starts it — and only then claims to be reviewing" \
  "grep -q '1 mission is waiting at Verify with no score of mine' '$TMPROOT/on1.out' && \
   grep -q 'lcars-unscored' '$TMPROOT/on1.out' && \
   grep -q 'lcars xo on --sweep' '$TMPROOT/on1.out' && \
   ! grep -q \"I'm reviewing\" '$TMPROOT/on1.out' && \
   grep -q \"I'm reviewing 1 mission that was waiting at Verify\" '$TMPROOT/on1b.out'"

# A verdict on disk is a score on record too — the other two places.
g2="$(new_repo)"
m="$(plant "$g2" lcars-hasverdict verify)"
mkdir -p "$m/xo"; printf '{"score":"high"}\n' >"$m/xo/verdict.json"
plant "$g2" lcars-optedout verify '{"optOut": true}' >/dev/null
: >"$SWEEPLOG"
( cd "$g2" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot ) >"$TMPROOT/on2.out" 2>&1
check "G-3 a look already on disk counts as a score; an opted-out mission is left alone" \
  "[ ! -s '$SWEEPLOG' ] && ! grep -q \"I'm reviewing\" '$TMPROOT/on2.out' && \
   ! grep -q 'waiting at Verify' '$TMPROOT/on2.out'"

# A mission stamped by ANOTHER laptop is not ours to review.
g3="$(new_repo)"
m="$(plant "$g3" lcars-remote verify)"
# A LOCAL one beside it, so this check has a positive half: the sweep must take
# ours and leave theirs. Without it, "nothing was swept" would also be true of
# a sweep that was simply broken.
plant "$g3" lcars-ours verify >/dev/null
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
# WITH `--sweep`, deliberately: under the default NOTHING is swept, so this
# would pass for free and prove nothing about the clone filter.
( cd "$g3" && LCARS_XO_SWEEP_BIN="$TMPROOT/sweepbin" LCARS_COPILOT_BIN=/usr/bin/true \
    bash "$SCRIPT" on --engine copilot --sweep ) >"$TMPROOT/on3.out" 2>&1
check "G-4 another laptop's mission is not swept, even when the sweep is asked for" \
  "[ \"\$(cat '$SWEEPLOG')\" = 'lcars-ours' ]"

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
    bash "$SCRIPT" on --engine copilot --sweep ) >"$TMPROOT/on4.out" 2>&1
check "G-5 on the opt-in path, standing down mid-round stops the chain AFTER that mission, not before it" \
  "[ \"\$(grep -c . '$SWEEPLOG')\" = '1' ] && grep -qi 'stood down' '$TMPROOT/on4.out'"
check "G-6 the opt-in sweep is journaled on each mission it takes" \
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
    bash "$SCRIPT" on --engine copilot --sweep ) >"$TMPROOT/on5.out" 2>&1
elapsed=$(( $(date +%s) - started ))
# `-gt 1` is half the point: with no sweep at all this would be instant and
# the cage would be proven by nothing. The look must really have been started.
check "G-7 a sweep look that outstays the cage is stopped, not waited on" \
  "[ '$elapsed' -lt 20 ] && [ '$elapsed' -gt 1 ]"
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
