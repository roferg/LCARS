#!/usr/bin/env bash
#
# S254 — THE LANDING RAIL IS FOR PICTURES ONLY.
#
# WHY THIS FILE EXISTS (measured on a live look, not a hunch). A real Copilot
# look over the `relay` fixture ran 8 declared steps, proved four defects and
# filed five bug Missions. Its report then headlined
#   **How close this is to what you asked for: LOW** — checked 1 of 6 (17%)
# and listed TEN "could not check" entries, every one of them carrying the SAME
# sentence:
#   "no landing record — the picture is cited but nothing beside it records
#    where it was taken, so it cannot be shown to be of the right screen."
# The "pictures" were `01-help.txt`, `02-empty.txt`, `04-list.txt`,
# `07-publish.txt`, `08-workflow.txt` — COMMAND-LINE AND WORKFLOW TRANSCRIPTS,
# which can never carry a screen landing. The look's own `couldNot` was EMPTY
# and its own wire said "attempted 6 of 6".
#
# THE CONTROL THAT ISOLATES IT. The same product over the same fixture with NO
# url reads `landing.railOn: false`, `checked 6 of 6 (100%)` and keeps 15/15
# rows. A look that can photograph the app threw its command-line evidence
# away; a look that could photograph nothing kept it. That is backwards.
#
# RECORD, DO NOT INFER — the rule this file's subject has lost four sessions to.
# The cure asks "was this a picture?" off a RECORDED field and never off a
# filename or an extension: `xo-run.py` writes `checkedBy` into the step readout
# beside every transcript (`01-help.json` → `"checkedBy": "cli"`), while
# `xo-drive.js` writes `landed`/`page` beside every PNG and no `checkedBy` at
# all. That is the producer's own record of which instrument took the evidence.
# The look's own `checkedBy` on the ledger row is the fallback when a step left
# no readout. Nothing here reads `.txt`, `.png`, or any name.
#
# S241 IS NOT WEAKENED. A row citing a GENUINE picture keeps the rail exactly as
# it was: a mis-landed screenshot is still refused, and a screenshot with no
# landing record at all is still refused. Both are asserted below.
#
# ZERO SPEND: a PATH shim fakes BOTH `claude` and `copilot`; the count is 0.
#
# Usage: bash tests/lcars-xo-rail-pictures.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCORE="$REPO_ROOT/skills/lcars-xo/xo-score.py"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$REPO_ROOT/tests/lib/cage.py"
DEV="${LCARS_DEV_ROOT:-/Users/roganferguson/Projects/lcars-dev}"
# The exact failing live look, preserved whole: the mission's own artifacts and
# its own shots directory, readouts and all.
LIVE="$DEV/tests/drives/s247/target/.git/lcars/missions/lcars-20261005-s247-relay/xo"
# A genuine, UNSCORED worker verdict from the S246 Claude look over the same
# fixture — the one that wrote FOUR honest `couldNot` entries.
PRESERVED="$DEV/tests/drives/s246/preserved/tmp.RuCBdZ6YV5-round-3--xo-verdict.json"

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
  cat >"$SHIM/$eng" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"$SPEND_LOG"
exit 0
EOF
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"
export LCARS_WORKER_BIN="$SHIM/claude"

[ -d "$LIVE/shots" ] && [ -f "$PRESERVED" ] || {
  printf 'the preserved live look is not on this machine: %s\n' "$LIVE"; exit 77; }

score() { # <fixture dir> <out dir>
  local d="$1" o="$2"; mkdir -p "$o"
  $PY "$CAGE" 240 $PY "$SCORE" "$d/verdict.json" "$d/criteria.json" \
    "$o/verdict.json" "$d/observations.json" "$d/tests.json" "$d/impacts.json" \
    "$d/pairs.json" "$d/walk.json" "$d/seed.json" "$d/unlisted.json" \
    "$d/readings.json" "$d/decisions.json" "$d/journey.json" "$d/shots" \
    >"$o/wire.txt" 2>"$o/err.txt"
}

# ── THE WORKER'S VERDICT, RECOVERED FROM THE RECORD THE LOOK LEFT ───────────
# The run's raw worker verdict was a temp file and is gone; its SCORED output
# is on disk and keeps every field the worker wrote except the status the rail
# overwrote. The statuses come back off the record, never a guess: a row named
# by `gaps[].criterion` was rated `gap`, every other rated row was `met` (the
# look's own wire says it attempted 6 of 6 and rated nothing untested). The
# fields the SCORER added are stripped, so what is replayed is a worker verdict.
mklive() { # <out dir> [--couldnot]
  local d="$1" cn="${2:-}"
  mkdir -p "$d"
  local f
  for f in criteria.json impacts.json journey.json observations.json pairs.json \
           readings.json seed.json tests.json unlisted.json walk.json; do
    cp "$LIVE/$f" "$d/"
  done
  cp -R "$LIVE/shots" "$d/shots"
  LIVE_SRC="$LIVE/verdict.json" PRESERVED_SRC="$PRESERVED" CN="$cn" $PY - "$d/verdict.json" <<'PY'
import json, os, sys
d = json.load(open(os.environ["LIVE_SRC"]))
gaps = set(str(g.get("criterion") or "") for g in (d.get("gaps") or []))
SCORER_ADDED = ("landing", "reason", "reasonByHarness", "outcome", "group",
                "source", "questionKind", "questionKindFrom", "causeRecorded",
                "text", "primary", "couldNotCheck", "cause")
out = {"score": d.get("workerScore") or d.get("score"),
       "summary": d.get("summary") or "the look's own summary",
       "criteria": [], "gaps": [], "couldNot": [],
       "alsoChecked": d.get("alsoChecked") or []}
for c in d.get("criteria") or []:
    r = {k: v for k, v in c.items() if k not in SCORER_ADDED}
    r["status"] = "gap" if c["id"] in gaps else "met"
    r["evidence"] = ("picture"
                     if str(c.get("checkedBy") or "").lower() == "browser"
                     else "transcript")
    r["note"] = ""
    out["criteria"].append(r)
for g in d.get("gaps") or []:
    out["gaps"].append({k: v for k, v in g.items() if k != "filedAs"})
if os.environ.get("CN") == "--couldnot":
    # THE FOUR HONEST ONES, verbatim from the S246 Claude look's own verdict.
    out["couldNot"] = json.load(open(os.environ["PRESERVED_SRC"]))["couldNot"]
json.dump(out, open(sys.argv[1], "w"), indent=1)
PY
}

printf '\n\033[1m1. THE REPLAY — the live look that threw its own transcripts away\033[0m\n'

L="$TMPROOT/live"; mklive "$L"
score "$L" "$TMPROOT/out-live"
check "the replay scored" "[ -s '$TMPROOT/out-live/verdict.json' ]"
# THE REGIME, PROVED OFF THE RECORDS. `landing.railOn` is reported only when
# the rail had something to refuse, so once the cure lands a clean look says
# nothing there — which is right, and is no use as a regime check. What puts
# this fixture in the rail's regime is that its own shots DO record landings
# (so `landing_records_exist` is true), and section 3 below proves the rail
# really does still fire on this very fixture.
check "the rail IS on for this look (so the test is in the right regime)" \
  "$PY -c \"
import json,sys
d=json.load(open('$LIVE/shots/look-1/shot-02.json'))
o=json.load(open('$TMPROOT/out-live/verdict.json'))
sys.exit(0 if isinstance(d.get('landed'),dict) and d.get('shot')
         and (o.get('landing') or {}).get('railOn') is not False else 1)\""
check "ZERO rows carry 'no landing record' — the ten manufactured ones are gone" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-live/verdict.json'))
n=[c['id'] for c in d['criteria'] if 'no landing record' in (c.get('note') or '')]
print(n)
sys.exit(0 if not n else 1)\""
check "the five transcript-evidenced PRD rows keep the verdict the look gave them" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-live/verdict.json'))
by={c['id']:c for c in d['criteria']}
want={'prd-1':'gap','prd-2':'met','prd-3':'met','prd-5':'gap','prd-6':'gap'}
got={k:by[k]['status'] for k in want}
print(got)
sys.exit(0 if got==want else 1)\""
check "the headline no longer says 'I could not check anything on your list'" \
  "grep -qv x /dev/null; ! grep -q 'could not check anything on your list' '$TMPROOT/out-live/report.md'"
check "coverage reflects the steps that ran — 6 of 6, not 1 of 6" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-live/verdict.json'))
print(d.get('coverageLine'))
sys.exit(0 if 'checked 6 of 6' in (d.get('coverageLine') or '') else 1)\""
check "nothing is listed under 'What I could not check' — the look named nothing" \
  "$PY -c \"
import io,sys
txt=io.open('$TMPROOT/out-live/report.md',encoding='utf-8').read()
import re
m=re.search(r'### What I could not check\n(.*?)(\n### |\Z)',txt,re.S)
rows=[l for l in (m.group(1).splitlines() if m else []) if l.startswith('- ')]
print(len(rows),rows[:3])
sys.exit(0 if not rows else 1)\""
check "the four real defects still read as faults against the build, not as my blindness" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-live/verdict.json'))
by={c['id']:c for c in d['criteria']}
sys.exit(0 if by['prd-1']['status']=='gap' and by['prd-4']['status']=='gap'
         and by['prd-5']['status']=='gap' and by['prd-6']['status']=='gap' else 1)\""

printf '\n\033[1m2. THE CONTROL — the worker'"'"'s OWN couldNot still reaches the captain\033[0m\n'

# If the cure had reached the "What I could not check" section instead of the
# rail, these four would have vanished with the ten. They are the look's own
# words about what IT could not get to, and they are not criteria.
C="$TMPROOT/live-cn"; mklive "$C" --couldnot
score "$C" "$TMPROOT/out-cn"
check "all FOUR of the look's own couldNot entries are printed" \
  "$PY -c \"
import io,re,json,sys
txt=io.open('$TMPROOT/out-cn/report.md',encoding='utf-8').read()
m=re.search(r'### What I could not check\n(.*?)(\n### |\Z)',txt,re.S)
rows=[l for l in (m.group(1).splitlines() if m else []) if l.startswith('- ')]
print(len(rows))
sys.exit(0 if len(rows)==4 and all('I could not get to this' in r for r in rows) else 1)\""
check "each one is the look's own item text, verbatim" \
  "$PY -c \"
import io,json,sys
txt=io.open('$TMPROOT/out-cn/report.md',encoding='utf-8').read()
want=json.load(open('$PRESERVED'))['couldNot']
miss=[w['item'][:40] for w in want if w['item'][:40] not in txt]
print(miss)
sys.exit(0 if not miss else 1)\""

printf '\n\033[1m3. A PICTURE IS STILL A PICTURE — S241 is not weakened\033[0m\n'

# prd-4 / t-2-ac* / part-* cite `shot-02`, a real PNG with a real readout. The
# rail still runs on them. Prove it BOTH ways on this same live fixture:
#   a) strip shot-02's readout -> the picture cannot be placed -> REFUSED.
#   b) point shot-02's recorded landing at another screen -> REFUSED.
# Neither row has a recorded non-camera instrument, so neither is excused.
#
# ── WHICH ROW LEG (a) ASKS, AND WHY IT MOVED (S261 fix round 1) ─────────────
# Leg (a) used to ask `prd-4`. `prd-4` is a row the look rated a FAULT and ALSO
# declared as a `contradiction` in its own `gaps[]`, and since S261 fix round 1
# such a row KEEPS its gap when the only complaint is that nothing recorded the
# landing — it discloses the unplaced picture instead of being re-scored "a hole
# in my checking". (Measured: the first live look with a shell filed six real
# Week-screen faults and its own verdict then reported `counts.gap = 0` beside a
# six-entry `gaps[]`, headlined MERGE WITH FOLLOW-UPS, and graded UP from the
# night before. See `xo-score.py`'s `_landed is None` branch.)
#
# S241'S INVARIANT IS UNCHANGED AND IS STILL ASSERTED HERE, on this same
# fixture and this same mutilation — it is asked of `t-2-ac1`, one of the three
# rows citing `shot-02` that the look rated MET. A picture that cannot be placed
# still cannot SETTLE a criterion, which is what S241 measured and what leg (a)
# exists for. What a missing landing record may no longer do is erase a fault the
# look positively recorded, ran the steps for, and filed. Both halves are
# asserted, so neither can drift.
NR="$TMPROOT/live-noreadout"; mklive "$NR"
rm -f "$NR/shots/look-1/shot-02.json"
score "$NR" "$TMPROOT/out-nr"
check "a REAL screenshot with NO landing record STILL cannot settle a MET (S241)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-nr/verdict.json'))
by={c['id']:c for c in d['criteria']}
r=by['t-2-ac1']
print(r['status'],repr(r.get('note'))[:90])
sys.exit(0 if r['status']=='untested' and 'no landing record' in (r.get('note') or '') else 1)\""
check "…and so for every MET row citing that same unplaceable picture" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-nr/verdict.json'))
by={c['id']:c for c in d['criteria']}
got={i:by[i]['status'] for i in ('t-2-ac1','t-2-ac2','part-board-title')}
print(got)
sys.exit(0 if all(v=='untested' for v in got.values()) else 1)\""
check "but a FAULT the look declared in its own gaps KEEPS its gap, and says the picture is unplaced" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-nr/verdict.json'))
by={c['id']:c for c in d['criteria']}
r=by['prd-4']
print(r['status'], (r.get('landing') or {}).get('unplaced'))
sys.exit(0 if r['status']=='gap' and (r.get('landing') or {}).get('unplaced') else 1)\""
check "…and the count agrees with the array it counts (the defect that drove this)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-nr/verdict.json'))
n=len([c for c in d['criteria'] if c['status']=='gap'])
print('counts.gap',d['counts']['gap'],'rows',n,'gaps[]',len(d['gaps']))
sys.exit(0 if d['counts']['gap']==n and n>0 else 1)\""
check "and only the picture rows are refused — the transcript rows are untouched" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-nr/verdict.json'))
by={c['id']:c for c in d['criteria']}
sys.exit(0 if all('no landing record' not in (by[i].get('note') or '')
                  for i in ('prd-1','prd-2','prd-3','prd-5','prd-6')) else 1)\""

MIS="$TMPROOT/live-mislanded"; mklive "$MIS"
$PY -c "
import json
p='$MIS/shots/look-1/shot-02.json'
d=json.load(open(p))
d['intent']={'screen':'screen-somewhere-else','textMustInclude':['NOT THIS PAGE'],
             'from':'the control: a landing this shot did NOT reach'}
json.dump(d,open(p,'w'),indent=1)
"
score "$MIS" "$TMPROOT/out-mis"
check "a MIS-LANDED screenshot is STILL REFUSED (the control fires, so it is not vacuous)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-mis/verdict.json'))
by={c['id']:c for c in d['criteria']}
r=by['prd-4']
print(r['status'],repr(r.get('note'))[:120])
sys.exit(0 if r['status']=='untested' and (r.get('landing') or {}).get('mismatch') is True else 1)\""
check "the picture rows WITH a good landing record still pass (leg a/b were not vacuous)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-live/verdict.json'))
by={c['id']:c for c in d['criteria']}
r=by['prd-4']
sys.exit(0 if not (r.get('landing') or {}).get('mismatch') else 1)\""

printf '\n\033[1m4. THE RULE IS KEYED ON A RECORD, NEVER ON A NAME\033[0m\n'

check "the cure reads no filename and no extension" \
  "! grep -nE \"endswith\\\\(['\\\"]\\\\.|\\\\.txt['\\\"]|\\\\.png['\\\"]|splitext.*lower\" '$SCORE' | grep -v '^[0-9]*: *#' | grep -qi 'rail\\|picture\\|camera'"
check "the step readout's own checkedBy is what the rail reads" \
  "grep -q 'checkedBy' '$SCORE' && $PY -c \"
import json,sys
d=json.load(open('$LIVE/shots/look-1/01-help.json'))
sys.exit(0 if d.get('checkedBy')=='cli' and 'landed' not in d else 1)\""

# A row whose step left NO readout at all, but whose LOOK recorded the
# instrument, is still scored on its transcript — the fallback record.
FB="$TMPROOT/live-fallback"; mklive "$FB"
rm -f "$FB/shots/look-1/01-help.json" "$FB/shots/look-1/08-workflow.json"
score "$FB" "$TMPROOT/out-fb"
check "with the step readout gone, the look's OWN recorded checkedBy still excuses it" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/out-fb/verdict.json'))
by={c['id']:c for c in d['criteria']}
sys.exit(0 if all('no landing record' not in (by[i].get('note') or '')
                  for i in ('prd-1','prd-5')) else 1)\""

printf '\n\033[1m5. ZERO SPEND\033[0m\n'
check "no engine was invoked" "[ ! -s '$SPEND_LOG' ]"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
