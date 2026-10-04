#!/usr/bin/env bash
#
# S241 — THE LANDING RECORD: a shot that landed elsewhere is not evidence.
#
# WHY THIS FILE EXISTS (measured, not a hunch). In the archived Kelmoor runs
# `shot-01.png`, `inv-full.png` and `after-battle-full.png` are the SAME FILE —
# all three hash to 14f6e16bb6d458d6000dbf9466439843 — and all three are the
# ROSTER screen. The Inventory evidence and the after-battle evidence the report
# cited were a picture of the Roster. Every run still published `high`.
#
# IDENTICAL BYTES ARE THE SYMPTOM, NOT THE TEST. Nothing in this file (or in the
# cure it drives) compares images, hashes or retries a navigation: the record
# already says where each shot was TAKEN (`page.url`, `page.title`,
# `page.textExcerpt`, `page.places`), and what was missing is where the step
# MEANT to land. The test is INTENT vs LANDING, read off the record.
#
# The six behaviours:
#   1  every journey step carries `expectLanding` — a screen/urlPattern/text
#      intent — WITH the source it was derived from.
#   2  `xo-drive.js` writes `landed` + `intent` into the readout `.json` beside
#      every PNG, so the pair sits in ONE file. Driven against a real local
#      fixture page whose "Open Inventory" button goes nowhere.
#   3  `xo-score.py`, replayed over a COPY of the archived looks, REFUSES a row
#      whose cited shot landed somewhere else: `untested (landed on …)`.
#   4  a MATCHING landing leaves the row alone (the positive control — and the
#      control is proved able to fail by inverting the recorded intent).
#   5  a cited shot with NO readout at all reads `untested (no landing record)`.
#   6  the diff computes no image hash and retries no navigation.
#   7  a PRD criterion, which declares no place of its own, INHERITS the
#      place of the ticket criteria that declare `serves: prd-N` — with the
#      provenance recorded on the row; servers that disagree are undecidable,
#      not a pick; servers that declare no place leave the row honestly blind.
#   8  `report.md` — the file the captain actually audits — SAYS on the row
#      itself when a picture could not be placed, in the recorded words, and
#      says it once for the look; a row that really was checked is untouched,
#      and a look with no landing records at all gains nothing.
#
# ZERO SPEND: a PATH shim fakes BOTH `claude` and `copilot`; the count is 0.
#
# Usage: bash tests/lcars-xo-landing.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOURNEY="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
SCORE="$REPO_ROOT/skills/lcars-xo/xo-score.py"
DRIVER="$REPO_ROOT/skills/lcars-xo/xo-drive.js"
PY="${LCARS_PYTHON_BIN:-python3}"
NODE="${LCARS_NODE_BIN:-node}"
CAGE="$REPO_ROOT/tests/lib/cage.py"
export JOURNEY_PY="$JOURNEY"
ARCHIVE="$HOME/Projects/lcars-mission-archive/groutwork/.git/lcars/missions/lcars-20260926-001-72bf"
RIG="/Users/roganferguson/Projects/lcars-dev/tests/drives/s241"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND ------------------------------------------------------------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
SPEND_LOG="$TMPROOT/spend.log"; : >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"
export LCARS_WORKER_BIN="$SHIM/claude"

[ -d "$ARCHIVE" ] || { printf 'the archive is not on this machine: %s\n' "$ARCHIVE"; exit 77; }

printf '\n\033[1m1. INTENT — every journey step says where it meant to land, and from what\033[0m\n'

# Built from the ARCHIVED criteria + drawing, read-only.
$PY - "$ARCHIVE" "$TMPROOT/journey.json" <<'PY'
import json, sys, importlib.util, os
arch, out = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("xoj", os.environ["JOURNEY_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
crit = json.load(open(os.path.join(arch, "xo-restyle-3", "criteria.json")))
draw = json.load(open(os.path.join(arch, "xo-restyle-3", "drawing-parts.json")))
prd = open(os.path.join(arch, "prd.md")).read()
j = m.build(crit, draw, title="Depths of Kelmoor", prd=prd)
json.dump(j, open(out, "w"), indent=1)
PY

check "the journey built off the archive" "[ -s '$TMPROOT/journey.json' ]"
check "EVERY step carries expectLanding" \
  "$PY -c \"import json;j=json.load(open('$TMPROOT/journey.json'));s=j['steps'];import sys;sys.exit(0 if s and all(isinstance(x.get('expectLanding'),dict) for x in s) else 1)\""
check "every expectLanding names its SOURCE" \
  "$PY -c \"import json;j=json.load(open('$TMPROOT/journey.json'));import sys;sys.exit(0 if all((x.get('expectLanding') or {}).get('from') for x in j['steps']) else 1)\""
check "the step that walks to the inventory expects screen-inventory" \
  "$PY -c \"import json;j=json.load(open('$TMPROOT/journey.json'));import sys;sys.exit(0 if any((x.get('expectLanding') or {}).get('screen')=='screen-inventory' for x in j['steps']) else 1)\""
check "an expectLanding that cannot say where it lands SAYS SO (never invents)" \
  "$PY -c \"
import json,sys
j=json.load(open('$TMPROOT/journey.json'))
for x in j['steps']:
    e=x['expectLanding']
    if not e.get('screen') and not e.get('urlPattern') and not e.get('textMustInclude'):
        sys.exit(0 if e.get('unstated') is True else 1)
sys.exit(0)\""

printf '\n\033[1m2. LANDING — the driver writes landed+intent into the readout beside the PNG\033[0m\n'

FIX="$RIG/fixture"; mkdir -p "$FIX"
cat >"$FIX/index.html" <<'HTML'
<!doctype html><html><head><title>Landing fixture</title></head><body>
<div id="screen-roster"><h2>SCREEN 1 / ROSTER</h2><p>Party Roster</p>
<button id="button-open-inventory">Open Inventory</button></div>
<div id="screen-inventory" style="display:none"><h2>SCREEN 4 / INVENTORY</h2></div>
<script>/* the button goes NOWHERE — that is the whole point of this fixture */</script>
</body></html>
HTML
cat >"$FIX/journey.json" <<'JSON'
{"entry":[],"steps":[{"key":"j1","do":"click","match":["Open Inventory"],
 "name":"from the roster screen, click \"Open Inventory\"",
 "expect":"the inventory screen",
 "expectLanding":{"screen":"screen-inventory","urlPattern":"/inventory",
   "textMustInclude":["SCREEN 4 / INVENTORY"],
   "from":"the drawing draws screen-inventory after screen-roster"}}]}
JSON
printf 'screen-roster\nscreen-inventory\n' >"$FIX/places.txt"
DOUT="$TMPROOT/drive"; mkdir -p "$DOUT"
$PY "$CAGE" 180 "$NODE" "$DRIVER" --url "file://$FIX/index.html" --out "$DOUT" \
  --journey "$FIX/journey.json" --walk-out "$TMPROOT/walk.json" \
  --place-names "$FIX/places.txt" >"$TMPROOT/drive.log" 2>&1
DRC=$?
printf '   driver rc=%s\n' "$DRC"
READOUT="$(ls "$DOUT"/*walk*j1.json 2>/dev/null | head -1)"
check "the driver took the step's shot and wrote a readout beside it" "[ -n '$READOUT' ]"
if [ -n "$READOUT" ]; then
  check "the readout carries the step's INTENT" \
    "$PY -c \"import json,sys;d=json.load(open('$READOUT'));sys.exit(0 if (d.get('intent') or {}).get('screen')=='screen-inventory' and (d.get('intent') or {}).get('urlPattern')=='/inventory' else 1)\""
  check "the readout carries where it actually LANDED" \
    "$PY -c \"import json,sys;d=json.load(open('$READOUT'));l=d.get('landed') or {};sys.exit(0 if l.get('url') and l.get('title')=='Landing fixture' and l.get('textSample') else 1)\""
  check "landed.screen is the screen the PAGE exposes, not the one hoped for" \
    "$PY -c \"import json,sys;d=json.load(open('$READOUT'));sys.exit(0 if (d.get('landed') or {}).get('screen')=='screen-roster' else 1)\""
fi

printf '\n\033[1m3. REFUSAL — replayed over a COPY of the archived looks\033[0m\n'

replay() { # <run> → $TMPROOT/<run>
  local run="$1"; local dst="$RIG/replay/$run"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -R "$ARCHIVE/$run/shots" "$dst/shots"
  for f in verdict.json criteria.json observations.json tests.json impacts.json \
           pairs.json walk.json seed.json unlisted.json readings.json decisions.json; do
    [ -f "$ARCHIVE/$run/$f" ] && cp "$ARCHIVE/$run/$f" "$dst/$f"
  done
  # The journey is REBUILT with this session's code, because the intent is what
  # the archive never recorded. Everything else is the archive, untouched.
  JOURNEY_PY="$JOURNEY" $PY - "$ARCHIVE/$run" "$ARCHIVE" "$dst/journey.json" <<'PY'
import json, sys, importlib.util, os
run, arch, out = sys.argv[1], sys.argv[2], sys.argv[3]
spec = importlib.util.spec_from_file_location("xoj", os.environ["JOURNEY_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
crit = json.load(open(os.path.join(run, "criteria.json")))
draw = json.load(open(os.path.join(run, "drawing-parts.json")))
prd = open(os.path.join(arch, "prd.md")).read()
json.dump(m.build(crit, draw, title="Depths of Kelmoor", prd=prd), open(out, "w"), indent=1)
PY
  printf '%s\n' "$dst"
}

score() { # <dir> <out>
  local d="$1" o="$2"
  $PY "$CAGE" 240 $PY "$SCORE" "$d/verdict.json" "$d/criteria.json" "$o" \
    "$d/observations.json" "$d/tests.json" "$d/impacts.json" "$d/pairs.json" \
    "$d/walk.json" "$d/seed.json" "$d/unlisted.json" "$d/readings.json" \
    "$d/decisions.json" "$d/journey.json" "$d/shots" >"$o.log" 2>&1
}

R3="$(replay xo-restyle-3)"
score "$R3" "$TMPROOT/r3.json"
check "the replay scored" "[ -s '$TMPROOT/r3.json' ]"
check "journey-j3 — clicked Attack expecting the inventory, landed on the battle screen — is REFUSED" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j3'][0]
sys.exit(0 if r['status']=='untested' and 'landed on' in (r.get('note') or '') else 1)\""
check "the refusal says WHERE it landed and what was expected — recorded, not canned" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j3'][0]
n=r.get('note') or ''
sys.exit(0 if 'screen-battle' in n and 'screen-inventory' in n else 1)\""
check "the shot stays in the record, marked mismatch" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j3'][0]
sys.exit(0 if r.get('shot') and (r.get('landing') or {}).get('mismatch') is True else 1)\""
check "it is listed under my_checking, never against the build" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
mc=d.get('myChecking') or {}
ids=[r['id'] for k in ('couldntSee','couldntSetUp') for r in (mc.get(k) or [])]
sys.exit(0 if 'journey-j3' in ids else 1)\""
check "the step is recorded as attempted-but-not-reached, with THAT reason" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
nr=(d.get('landing') or {}).get('notReached') or []
sys.exit(0 if any(x.get('step')=='j3' and 'screen-battle' in (x.get('reason') or '') for x in nr) else 1)\""
check "the person group's grade DROPS below high once the shot stops counting" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
sys.exit(0 if d['groups']['person']['grade']!='high' else 1)\""

L1="$(replay xo-look-1)"
score "$L1" "$TMPROOT/l1.json"
check "look-1: the Inventory rows evidenced on a ROSTER shot are refused" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
by={c['id']:c for c in d['criteria']}
sys.exit(0 if all(by[i]['status']=='untested' and 'landed on' in (by[i].get('note') or '')
                  for i in ('t-003-ac2','t-003-ac3')) else 1)\""

printf '\n\033[1m4. THE CONTROL — a matching landing is left alone (and CAN fail)\033[0m\n'

check "journey-j1 walked to the dungeon and landed there: still met" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j1'][0]
sys.exit(0 if r['status']=='met' and not (r.get('landing') or {}).get('mismatch') else 1)\""
check "the Roster rows, evidenced on a Roster shot, stay met" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/r3.json'))
by={c['id']:c for c in d['criteria']}
sys.exit(0 if all(by[i]['status']=='met' for i in ('t-001-ac1','t-001-ac3','t-001-ac4')) else 1)\""

# THE CONTROL IS PROVED ABLE TO FAIL. Same input, one field changed: j1's
# recorded intent is rewritten to a screen it did NOT land on. If the control
# above is vacuous this stays met.
CTL="$RIG/replay/control"; rm -rf "$CTL"; cp -R "$R3" "$CTL"
$PY -c "
import json
p='$CTL/journey.json'
j=json.load(open(p))
for s in j['steps']:
    if s['key']=='j1':
        s['expectLanding']={'screen':'screen-inventory','textMustInclude':['SCREEN 4 / INVENTORY'],
                            'from':'the control: a landing this step did NOT reach'}
json.dump(j,open(p,'w'),indent=1)
"
score "$CTL" "$TMPROOT/ctl.json"
check "with j1's intent pointed elsewhere, the control FIRES (so it was not vacuous)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/ctl.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j1'][0]
sys.exit(0 if r['status']=='untested' else 1)\""

printf '\n\033[1m5. NO READOUT AT ALL — untested (no landing record)\033[0m\n'

# ONE shot loses its readout, in a look that records them. That is the honest
# shape of "no landing record": the run WAS recording, and this picture is not
# placeable. (A run that records none at all is the next case below — the rail
# cannot place anything, so it says that once instead of downgrading every row.)
NR="$RIG/replay/no-readout"; rm -rf "$NR"; cp -R "$R3" "$NR"
find "$NR/shots" -name 'shot-walk-01-j1.json' -delete
score "$NR" "$TMPROOT/nr.json"
check "a cited shot with no readout reads 'no landing record'" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/nr.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j1'][0]
sys.exit(0 if r['status']=='untested' and 'no landing record' in (r.get('note') or '') else 1)\""
check "'no landing record' never pretends to know where it landed" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/nr.json'))
r=[c for c in d['criteria'] if c['id']=='journey-j1'][0]
sys.exit(0 if 'landed on' not in (r.get('note') or '') else 1)\""

# A WHOLE RUN THAT RECORDS NOTHING is a look from before the landing record (or
# one driven by a stub). Refusing all of it is an outage, not a measurement: it
# would rewrite the grade of every look ever taken. The rail says so ONCE.
NONE="$RIG/replay/records-nothing"; rm -rf "$NONE"; cp -R "$R3" "$NONE"
find "$NONE/shots" -name '*.json' -delete
score "$NONE" "$TMPROOT/none.json"
check "a look that records NO landings at all is not refused row by row" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/none.json'))
by={c['id']:c['status'] for c in d['criteria']}
sys.exit(0 if by.get('journey-j1')=='met' and by.get('t-001-ac1')=='met' else 1)\""
check "...and it says so, once, in its own words" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/none.json'))
l=d.get('landing') or {}
sys.exit(0 if l.get('railOn') is False and 'not one picture' in (l.get('note') or '') else 1)\""

printf '\n\033[1m7. A PRD ROW INHERITS THE DECLARED PLACE OF THE TICKET CRITERION THAT SERVES IT\033[0m\n'

# WHY THIS SECTION EXISTS. S241 cured the ticket rows and the journey steps and
# KNOWINGLY left the PRD rows blind: a PRD criterion carries no `drawnAt`, so
# the rail never engaged on it. In `xo-look-1` that left `prd-2` ("gold is shown
# on the roster, the dungeon map AND the inventory") settled `met` on `shot-01`,
# a ROSTER picture — the captain's own grievance, on the very file he was angry
# about — and `prd-4` ("the weapon … is the same weapon shown on the inventory")
# settled on `shot-09`, the Roster again.
#
# RECORD, DO NOT INFER. The link was already written down: every ticket
# criterion carries `serves: prd-N`, and the placed ones carry a `drawnAt` the
# planner wrote FROM THE DRAWING. So a PRD row INHERITS the place of the ticket
# criteria that declare they serve it. Nothing here reads a criterion's English
# text for a screen name — the probe at the end of this section proves that by
# stripping every screen word out of the prose and showing the ledger does not
# move.

L3="$(replay xo-look-3)"
score "$L3" "$TMPROOT/l3.json"
check "the look-3 replay scored" "[ -s '$TMPROOT/l3.json' ]"

# --- the three rows the captain's complaint still lived in ------------------
check "look-1 prd-4 — the Inventory claim settled on a ROSTER shot — is REFUSED" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
r=[c for c in d['criteria'] if c['id']=='prd-4'][0]
sys.exit(0 if r['status']=='untested' else 1)\""
check "...and the reason names where the shot REALLY landed and where it was meant to" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
n=([c for c in d['criteria'] if c['id']=='prd-4'][0].get('note') or '')
sys.exit(0 if 'screen-roster' in n and 'screen-inventory' in n else 1)\""
check "...and the reason names WHICH ticket criterion lent it that expectation" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
r=[c for c in d['criteria'] if c['id']=='prd-4'][0]
n=(r.get('note') or '')
exp=(r.get('landing') or {}).get('expected') or {}
sys.exit(0 if 't-003-ac3' in n and 't-003-ac3' in (exp.get('inheritedFrom') or []) else 1)\""
check "...and the row records the inheritance as its rule, not a guess" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
exp=([c for c in d['criteria'] if c['id']=='prd-4'][0].get('landing') or {}).get('expected') or {}
sys.exit(0 if exp.get('rule')=='inherited from the ticket criterion that serves it' else 1)\""

check "look-1 prd-2 — one picture for a claim about THREE places — is REFUSED" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
r=[c for c in d['criteria'] if c['id']=='prd-2'][0]
sys.exit(0 if r['status']=='untested' else 1)\""
check "...and it names the rule applied and every place its servers declared" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
r=[c for c in d['criteria'] if c['id']=='prd-2'][0]
n=(r.get('note') or '')
exp=(r.get('landing') or {}).get('expected') or {}
ok = (exp.get('rule')=='several declared places, one picture'
      and sorted(exp.get('places') or [])==['screen-dungeon','screen-inventory','screen-roster']
      and 'screen-roster' in n and 'screen-inventory' in n and 'screen-dungeon' in n)
sys.exit(0 if ok else 1)\""
check "...and it never picks one of the disagreeing places and calls it the answer" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
exp=([c for c in d['criteria'] if c['id']=='prd-2'][0].get('landing') or {}).get('expected') or {}
sys.exit(0 if not exp.get('screen') and exp.get('unplaced') is True else 1)\""
check "look-1 prd-1 — four screens exist, evidenced by one screen — is REFUSED" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
r=[c for c in d['criteria'] if c['id']=='prd-1'][0]
sys.exit(0 if r['status']=='untested' and 'screen-battle' in (r.get('note') or '') else 1)\""
check "...and all three are my blind spot, never a fault in the build" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
mc=d.get('myChecking') or {}
ids=[r['id'] for k in ('couldntSee','couldntSetUp') for r in (mc.get(k) or [])]
g=[x['id'] for x in (d.get('gaps') or [])]
sys.exit(0 if all(i in ids and i not in g for i in ('prd-1','prd-2','prd-4')) else 1)\""

printf '\n\033[1m7b. DO NOT REFUSE GOOD EVIDENCE — the positive control\033[0m\n'

# The SAME row, the SAME inherited expectation, a shot that really is of the
# Inventory: `xo-look-3` cites `inventory`, and the record says it landed on
# `screen-inventory`. It must stay met.
check "look-3 prd-4 — the same claim on a real Inventory shot — STAYS met" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l3.json'))
r=[c for c in d['criteria'] if c['id']=='prd-4'][0]
sys.exit(0 if r['status']=='met' and not (r.get('landing') or {}).get('mismatch') else 1)\""
check "look-1 prd-3 and prd-6 — inherited the Battle, taken on the Battle — STAY met" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
by={c['id']:c for c in d['criteria']}
sys.exit(0 if all(by[i]['status']=='met' and not (by[i].get('landing') or {}).get('mismatch')
                  for i in ('prd-3','prd-6')) else 1)\""
check "no ticket or appearance row is touched by the inheritance rail" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
bad=[c['id'] for c in d['criteria']
     if not c['id'].startswith('prd-')
     and ((c.get('landing') or {}).get('expected') or {}).get('inheritedFrom')]
sys.exit(0 if not bad else 1)\""

# THE CONTROL IS PROVED ABLE TO FAIL. One field changed, in the record the
# inheritance reads: the serving ticket criterion's own `drawnAt` is repointed
# at a screen prd-3's picture did NOT land on. If the control above is vacuous
# this row stays met.
SRV="$RIG/replay/served-control"; rm -rf "$SRV"; cp -R "$L1" "$SRV"
$PY -c "
import json
p='$SRV/criteria.json'
d=json.load(open(p))
for c in d['criteria']:
    if c['id']=='t-004-ac2':
        c['drawnAt']='#screen-inventory, the place this control points at instead'
json.dump(d,open(p,'w'),indent=1)
"
score "$SRV" "$TMPROOT/srv.json"
check "with the SERVING criterion repointed, prd-3 FIRES (so the control was not vacuous)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/srv.json'))
r=[c for c in d['criteria'] if c['id']=='prd-3'][0]
sys.exit(0 if r['status']=='untested' and 'screen-inventory' in (r.get('note') or '') else 1)\""

printf '\n\033[1m7c. HONESTLY BLIND — no declared place is said, never invented\033[0m\n'

# `prd-9` is served by `t-005-ac4` alone, and that criterion declares no place.
# There is nothing to inherit. The honest answer is to SAY SO on the row, not to
# invent a place and not to let the picture read as checked.
check "look-1 prd-9 — nothing serving it declares a place — says it has no declared place" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
l=([c for c in d['criteria'] if c['id']=='prd-9'][0].get('landing') or {})
exp=l.get('expected') or {}
sys.exit(0 if l.get('unplaced') is True and exp.get('rule')=='no declared place' else 1)\""
check "...and it names the criterion it asked, so nobody has to guess" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
l=([c for c in d['criteria'] if c['id']=='prd-9'][0].get('landing') or {})
sys.exit(0 if 't-005-ac4' in ((l.get('expected') or {}).get('servedBy') or []) else 1)\""
check "...and it invents no place and claims no mismatch" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
l=([c for c in d['criteria'] if c['id']=='prd-9'][0].get('landing') or {})
sys.exit(0 if not ((l.get('expected') or {}).get('screen')) and not l.get('mismatch') else 1)\""
check "...and the look's own landing block lists what it could not place" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/l1.json'))
l=d.get('landing') or {}
np=[x['criterion'] for x in (l.get('notPlaced') or [])]
sys.exit(0 if 'prd-9' in np and 'prd-4' not in np and (l.get('notPlacedNote') or '') else 1)\""

# PRECEDENCE: a row's OWN declaration always wins over what it inherits. If a
# PRD line ever does carry a `drawnAt` of its own, that is the more specific
# record and the inheritance must not override it. Planted on prd-3, whose
# inherited place (#screen-battle, from t-004-ac2) is exactly where its picture
# WAS taken — so only a rail that prefers the row's own declaration refuses.
OWN="$RIG/replay/own-wins"; rm -rf "$OWN"; cp -R "$L1" "$OWN"
$PY -c "
import json
p='$OWN/criteria.json'
d=json.load(open(p))
for c in d['criteria']:
    if c['id']=='prd-3':
        c['drawnAt']='#screen-dungeon, planted on the PRD row itself'
json.dump(d,open(p,'w'),indent=1)
"
score "$OWN" "$TMPROOT/own.json"
check "a PRD row's OWN declared place beats what it would inherit" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/own.json'))
r=[c for c in d['criteria'] if c['id']=='prd-3'][0]
exp=(r.get('landing') or {}).get('expected') or {}
sys.exit(0 if r['status']=='untested' and exp.get('screen')=='screen-dungeon'
         and not exp.get('inheritedFrom') else 1)\""

printf '\n\033[1m7d. THE EXPECTATION IS READ OFF THE LINK, NOT OUT OF THE PROSE\033[0m\n'

# The infer-vs-record error this file has paid for three times: a rail that
# finds "the inventory screen" in a criterion's English and calls that its
# intent breaks the moment a human rewords it. PROBE: strip every screen word
# out of all nine PRD criteria's text and leave the `serves` links alone. A rail
# that reads prose moves; one that reads the link does not.
WORDS="$RIG/replay/prose-probe"; rm -rf "$WORDS"; cp -R "$L1" "$WORDS"
$PY -c "
import json,re
p='$WORDS/criteria.json'
d=json.load(open(p))
for c in d['criteria']:
    if str(c.get('source'))=='prd':
        t=c.get('text') or ''
        for w in ('roster','inventory','battle','dungeon','map','screen','screens'):
            t=re.sub(w,'XXXX',t,flags=re.I)
        c['text']=t
json.dump(d,open(p,'w'),indent=1)
"
score "$WORDS" "$TMPROOT/words.json"
check "with every screen word stripped from the PRD prose, the PRD VERDICTS do not move" \
  "$PY -c \"
import json,sys
a=json.load(open('$TMPROOT/l1.json')); b=json.load(open('$TMPROOT/words.json'))
fa={c['id']:(c['status'],((c.get('landing') or {}).get('expected') or {}).get('screen'))
    for c in a['criteria'] if c['id'].startswith('prd-')}
fb={c['id']:(c['status'],((c.get('landing') or {}).get('expected') or {}).get('screen'))
    for c in b['criteria'] if c['id'].startswith('prd-')}
sys.exit(0 if fa==fb and fa else 1)\""
check "...and the probe was not vacuous — the prose really was rewritten" \
  "$PY -c \"
import json,sys
d=json.load(open('$WORDS/criteria.json'))
t=[c['text'] for c in d['criteria'] if c['id']=='prd-2'][0]
sys.exit(0 if 'XXXX' in t and 'roster' not in t.lower() else 1)\""

printf '\n\033[1m7e. THE RENDERED REPORT SAYS WHICH PICTURES IT NEVER CHECKED\033[0m\n'

# WHY THIS SECTION EXISTS. Everything above proves the FACT is recorded —
# `criteria[].landing.unplaced` on the row, `landing.notPlaced` on the look. The
# captain audits this product by READING `report.md`, and that renderer did not
# read the `landing` key at all, so `prd-9` reached him as
#   | prd-9 (PRD) | … | MET | a picture | shot-walk-02-j2 — every transition I drove … |
# a met row backed by a picture nobody ever checked was of the right screen.
# That is the quieter half of the very defect this round exists to close: a row
# that LOOKS verified and is not. The disclosure must be built from the RECORDED
# `rule`/`reason` — never a sentence invented per row — and must leave a
# genuinely-checked row alone.
#
# Its own output directory, because `xo-score.py` writes `report.md` beside the
# verdict path it is given and every earlier `score` in this file shares
# $TMPROOT — the last one to run would otherwise own the only report on disk.
MARK='I did not check this picture is of the right screen'
mkdir -p "$TMPROOT/rep" "$TMPROOT/repnone"
score "$L1" "$TMPROOT/rep/l1.json"
REP="$TMPROOT/rep/report.md"
check "the look-1 replay wrote its report beside its verdict" "[ -s '$REP' ]"
check "the fixture really does exercise the case — exactly prd-9 could not be placed" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/rep/l1.json'))
np=sorted(x['criterion'] for x in ((d.get('landing') or {}).get('notPlaced') or []))
sys.exit(0 if np==['prd-9'] else 1)\""
check "prd-9 is still MET on the table — no status, grade or count is moved" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/rep/l1.json'))
r=[c for c in d['criteria'] if c['id']=='prd-9'][0]
rows=[l for l in open('$REP') if l.startswith('| prd-9 ')]
sys.exit(0 if r['status']=='met' and rows and '| MET |' in rows[0] else 1)\""
check "...and its own row on the table says its picture was NOT checked" \
  "$PY -c \"
import sys
rows=[l for l in open('$REP') if l.startswith('| prd-9 ')]
sys.exit(0 if rows and '$MARK' in rows[0] else 1)\""
check "...and it says so in the RECORDED words — the rule, and the criterion it asked" \
  "$PY -c \"
import sys
rows=[l for l in open('$REP') if l.startswith('| prd-9 ')]
sys.exit(0 if rows and 'no declared place' in rows[0] and 't-005-ac4' in rows[0] else 1)\""
check "the look says it once as well, in the words it recorded for itself" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/rep/l1.json'))
n=' '.join(((d.get('landing') or {}).get('notPlacedNote') or '').split())
sys.exit(0 if n and n in open('$REP').read() else 1)\""
check "the rows that disclose are EXACTLY the ones the record could not place" \
  "$PY -c \"
import json,sys
rows=[l for l in open('$REP') if l.startswith('| ')]
marked=set(l.split('|')[1].strip().replace(' (PRD)','') for l in rows if '$MARK' in l)
d=json.load(open('$TMPROOT/rep/l1.json'))
rec=set(x['criterion'] for x in ((d.get('landing') or {}).get('notPlaced') or []))
sys.exit(0 if rec and marked==rec else 1)\""

# THE POSITIVE CONTROL. prd-3 and prd-6 inherited a place and their pictures
# really were taken there (section 7b); their rows must gain no new noise.
check "a genuinely-checked met row gains nothing — prd-3 and prd-6 stay clean" \
  "$PY -c \"
import sys
want=('| prd-3 ','| prd-6 ')
rows=[l for l in open('$REP') if l.startswith(want)]
sys.exit(0 if len(rows)==2 and not any('$MARK' in l for l in rows) else 1)\""

# ...AND THAT CONTROL IS PROVED ABLE TO FAIL. One field removed from the record
# the inheritance reads: prd-3's only server loses its `drawnAt`, so prd-3 has
# no declared place either. Its verdict must not move — and its row must now
# disclose. If the control above is vacuous, this row stays clean.
UNP="$RIG/replay/unplaced-control"; rm -rf "$UNP"; cp -R "$L1" "$UNP"
$PY -c "
import json
p='$UNP/criteria.json'
d=json.load(open(p))
for c in d['criteria']:
    if c['id']=='t-004-ac2':
        c.pop('drawnAt', None)
json.dump(d,open(p,'w'),indent=1)
"
mkdir -p "$TMPROOT/repunp"
score "$UNP" "$TMPROOT/repunp/unp.json"
check "with prd-3's only server unplaced, prd-3's row DOES disclose (the control can fail)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/repunp/unp.json'))
r=[c for c in d['criteria'] if c['id']=='prd-3'][0]
rows=[l for l in open('$TMPROOT/repunp/report.md') if l.startswith('| prd-3 ')]
sys.exit(0 if r['status']=='met' and rows and '$MARK' in rows[0] else 1)\""

# REQUIREMENT 4 — an older look, or one driven by a stub, records no landings at
# all. It must not sprout a warning per row; it keeps the ONE disclosure it has
# always had. This is the same `records-nothing` rig as section 5, re-scored into
# its own directory so its report survives to be read.
score "$NONE" "$TMPROOT/repnone/none.json"
check "a look that records NO landings at all sprouts no row disclosures" \
  "! grep -Fq '$MARK' '$TMPROOT/repnone/report.md'"
check "...and it still carries the single once-per-look disclosure it had before" \
  "grep -Fq 'not one picture' '$TMPROOT/repnone/report.md'"

printf '\n\033[1m6. THE FORBIDDEN CURES ARE NOT IN THE DIFF\033[0m\n'

DIFF="$TMPROOT/diff.txt"
( cd "$REPO_ROOT" && git diff -- skills/ tests/lcars-xo-landing.test.sh ) >"$DIFF" 2>/dev/null
grep -n '^+' "$DIFF" | grep -vi 'landing.test.sh' >"$TMPROOT/added.txt" || true
check "nothing added computes an image hash or a similarity" \
  "! grep -Eiq 'md5|sha1|sha256|hashlib|createHash|similarity|pixelmatch|ssim' '$TMPROOT/added.txt'"
check "nothing added retries a navigation" \
  "! grep -Eiq 'retr(y|ies|ying)' '$TMPROOT/added.txt'"

printf '\n  \033[1m%d pass, %d fail\033[0m\n' "$pass" "$fail"
SPEND="$(wc -l <"$SPEND_LOG" | tr -d ' ')"
MODELED="$(grep -c -- '--model' "$SPEND_LOG" 2>/dev/null || true)"
printf '  worker invocations: %s (with --model: %s)\n' "$SPEND" "${MODELED:-0}"
[ "$fail" -eq 0 ] || exit 1
