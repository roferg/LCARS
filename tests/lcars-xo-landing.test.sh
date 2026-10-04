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
