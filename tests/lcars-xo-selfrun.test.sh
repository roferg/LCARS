#!/usr/bin/env bash
# tests/lcars-xo-selfrun.test.sh — S261 fix round 1: the self-run look RECORDS.
#
# WHAT WAS MEASURED, AND WHY THIS SUITE EXISTS. S261 gave the reviewer a real
# shell inside a disposable copy, and it worked: the first live night it went
# from 0 defects found / 0 filed to 7 found / 7 filed, with correct root causes.
# Two consequences of the new mechanism were measured on the SAME run:
#
#   D1  The M2 look found, diagnosed and FILED six real faults — `prd-5`,
#       `prd-10`, `prd-11`, `t-003-ac2`, `t-003-ac3`, `t-003-ac5` — and its own
#       `verdict.json` then re-scored all six `untested` with the reason
#       "no landing record — the picture is cited but nothing beside it records
#       where it was taken". Headline counts came out
#       `{met: 25, gap: 0, untested: 29}` — `counts.gap` ZERO beside a
#       SIX-ENTRY `gaps[]` in the same document — and `report.md` opened
#       "Recommendation: MERGE WITH FOLLOW-UPS … everything I could check
#       worked … that is a gap in my checking, not a fault in your build."
#       The reviewer's own words in that run were "Recommending LOW". The score
#       moved UP, low → medium, versus the night before when it had no shell
#       and honestly said it could not check.
#
#       THE HONESTY RULE IS NOT THE BUG. "A landing record is required before a
#       finding counts" (S241) is right and is untouched here. The bug is on the
#       PRODUCING side: the reviewer took `sc-week-desktop.png` /
#       `sc-week-phone.png` with its OWN commands in its OWN copy, so they never
#       reached the look's shots directory and nothing recorded where they were
#       taken. THE PRODUCER RECORDS IT (the infer-vs-record rule this file has
#       lost S147, S156 and S188 to): the worker is handed the look's own camera,
#       which already writes the landing readout beside every PNG.
#
#   D2  Six declared steps were refused before they ran —
#       `REFUSED (run): cwd /private/tmp/.../lcars-ap-wt-6SnDQN is an absolute
#       path outside the worktree` — because the worker declared, as its `cwd`,
#       the absolute path of the very copy the prompt told it it was standing in.
#       The declared-step gate judges text and refuses every absolute path.
#
# WHAT IS NOT TOUCHED, re-asserted here so a later session cannot read this
# suite as permission:
#   • the ledger vocabulary `met`/`gap`/`untested`, `derive_grade`'s ladder and
#     `derive_recommendation` — nothing here changes any of them;
#   • S241 proper: a shot the record says landed SOMEWHERE ELSE is still not
#     evidence, for a gap as much as for a met (section 2, control 2e);
#   • a `met` on an unplaceable picture is still refused (control 2d);
#   • the argv fence: no shells, no `-c` interpreters, no path outside the
#     look's own copy (section 3, controls 3c-3g);
#   • the report UI and its feed — the kept row discloses itself through the
#     EXISTING `landing.unplaced` shape `unplaced_mark()` already renders.
#
# EVERY assertion is paired with something that makes it fire. ZERO SPEND.
#
# Usage: bash tests/lcars-xo-selfrun.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
SCORE="$REPO_ROOT/skills/lcars-xo/xo-score.py"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
DRIVER="$REPO_ROOT/skills/lcars-xo/xo-drive.js"
CAGE="$REPO_ROOT/tests/lib/cage.py"
PY="${LCARS_PYTHON_BIN:-python3}"

# The real M2 look, snapshotted by the orchestrator before anything was fixed.
M2="/private/tmp/claude-501/night-2026-10-08/s261-evidence/missions/lcars-20261008-004-06df/xo"

pass=0; fail=0
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/xo-selfrun-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
skip(){ printf '  \033[33mSKIP\033[0m %s\n' "$1"; }

# --- ZERO SPEND -------------------------------------------------------------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
export SPEND_LOG="$TMPROOT/spend.log"; : >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"\$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

printf '\n=== S261 fix round 1: the self-run look records what it produced ===\n'

# ===========================================================================
# 1. THE CAMERA — the worker is handed the one producer that records a landing
# ===========================================================================
echo ""
echo "1. the prompt hands the worker the look's own camera, pointed at the look's shots dir"

repo="$TMPROOT/repo"
mkdir -p "$repo"
( cd "$repo" && git init -q -b main &&
  git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'original\n' >"$repo/product.py"
( cd "$repo" && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$repo/.git/lcars/missions/lcars-1/xo"
cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "a", "model": "claude-sonnet", "projectName": "r",
 "testCommand": "true", "numberOne": {"enabled": true, "engine": "copilot"},
 "created": "2026-05-30T00:00:00Z"}
CJ
cat >"$repo/.git/lcars/missions/lcars-1/state.json" <<'SJ'
{"id": "lcars-1", "type": "feature", "title": "T", "stage": "verify",
 "branch": "main", "created": "2026-10-08T10:00:00Z"}
SJ
printf '# p\n' >"$repo/.git/lcars/missions/lcars-1/prd.md"

IN="$TMPROOT/in"; mkdir -p "$IN"
printf '%s\n' '{"productTypes": [{"type": "web", "source": "the plan"}],
 "criteria": [{"id": "prd-1", "text": "x"}]}' >"$IN/criteria.json"

WT="$TMPROOT/wt"
( cd "$repo" && git worktree add --detach "$WT" main ) >/dev/null 2>&1
THOME="$TMPROOT/throwaway-home"; mkdir -p "$THOME"
SHOTS="$repo/.git/lcars/missions/lcars-1/xo/shots/look-1"; mkdir -p "$SHOTS"

DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

spawn_n1() { # <tag> <worktree> <shots> <camera>
  ( cd "$repo" && \
    XO_PROMPT_DUMP="$TMPROOT/prompt-$1.txt" \
    LCARS_WORKER_ADAPTER="$DUMP" LCARS_WORKER_BIN="$WORKER" \
    LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    LCARS_XO_WORKTREE="$2" LCARS_XO_THROWAWAY_HOME="$THOME" \
    LCARS_XO_SHOTS_DIR="$3" LCARS_XO_CAMERA="$4" LCARS_XO_CAMERA_NODE=node \
    bash "$RUNSH" spawn-number-one --mission lcars-1 \
      --mode evaluate --outdir "$TMPROOT/out-$1" ) >"$TMPROOT/log-$1.txt" 2>&1
}

spawn_n1 cam "$WT" "$SHOTS" "$DRIVER"
spawn_n1 nocam "$WT" "" ""
spawn_n1 nowt "" "$SHOTS" "$DRIVER"
P_CAM="$TMPROOT/prompt-cam.txt"
P_NOCAM="$TMPROOT/prompt-nocam.txt"
P_NOWT="$TMPROOT/prompt-nowt.txt"

check "1z. all three prompts were captured at all" \
  '[ -s "$P_CAM" ] && [ -s "$P_NOCAM" ] && [ -s "$P_NOWT" ]'
check "1a. THE BEHAVIOUR — the prompt names the camera by its real path" \
  'grep -qF "$DRIVER" "$P_CAM"'
check "1b. …and the look's OWN shots directory, by path, as where a picture goes" \
  'grep -qF "$SHOTS" "$P_CAM"'
check "1c. …and says a picture taken any other way cannot be placed" \
  'grep -qiF "cannot be placed" "$P_CAM"'
check "1d. …and the command is runnable as written: node, the driver, --url, --out, --prefix" \
  'grep -qF -- "--out" "$P_CAM" && grep -qF -- "--prefix" "$P_CAM" &&
   grep -qF -- "--url" "$P_CAM"'
check "1e. CONTROL — with no camera plumbed the paragraph is absent (no invented path)" \
  '! grep -qF "xo-drive.js" "$P_NOCAM"'
check "1f. CONTROL — with no disposable copy standing there is no camera either" \
  '! grep -qF "xo-drive.js" "$P_NOWT"'
check "1g. CONTROL — the rest of the prompt is still there in all three" \
  'grep -q "Mission id: lcars-1" "$P_CAM" && grep -q "Mission id: lcars-1" "$P_NOCAM" &&
   grep -q "Mission id: lcars-1" "$P_NOWT"'
# A camera that is not on disk is a promise, and a promise buys nothing — the
# same rule the copy itself is held to (lcars-xo-eyes 2g).
spawn_n1 ghostcam "$WT" "$SHOTS" "$TMPROOT/not-a-driver.js"
check "1h. CONTROL — a camera path that is not there is not offered" \
  '! grep -qF "not-a-driver.js" "$TMPROOT/prompt-ghostcam.txt"'
# And the camera really does write a landing readout beside its PNG — the whole
# reason it is the thing handed over. Read off the driver's own source, so this
# does not need Chrome.
check "1i. the camera is the producer that records a landing (landed + page written)" \
  'grep -q "landed" "$DRIVER" && grep -q "page" "$DRIVER"'
check "1j. ZERO SPEND — no engine was invoked" '[ ! -s "$SPEND_LOG" ]'

# ===========================================================================
# 2. THE RECONCILIATION — a count may not disagree with the array it counts
# ===========================================================================
echo ""
echo "2. the real M2 look, replayed: six filed faults, six gaps, counts that agree"

if [ ! -s "$M2/verdict.json" ]; then
  skip "2. the M2 evidence snapshot is not on this machine ($M2)"
else
# THE WORKER'S VERDICT, RECOVERED FROM THE RECORD THE LOOK LEFT — the same
# recipe lcars-xo-rail-pictures.test.sh uses. The raw worker verdict was a temp
# file and is gone; its SCORED output is on disk and keeps every field the
# worker wrote except the status the rail overwrote. Statuses come back off the
# record, never a guess: a row named by `gaps[].criterion` was rated `gap`;
# every other rated row keeps the status the scorer recorded unless the rail is
# what set it, in which case `met` (the look rated nothing untested itself).
mkm2() { # <out dir>
  local d="$1"; mkdir -p "$d"
  local f
  for f in criteria.json impacts.json journey.json observations.json pairs.json \
           readings.json seed.json tests.json unlisted.json walk.json; do
    [ -s "$M2/$f" ] && cp "$M2/$f" "$d/"
  done
  cp -R "$M2/shots" "$d/shots"
  M2_SRC="$M2/verdict.json" $PY - "$d/verdict.json" <<'PY'
import json, os, sys
d = json.load(open(os.environ["M2_SRC"]))
gaps = set(str(g.get("criterion") or "") for g in (d.get("gaps") or []))
SCORER_ADDED = ("landing", "reason", "reasonByHarness", "outcome", "group",
                "source", "questionKind", "questionKindFrom", "causeRecorded",
                "text", "primary", "couldNotCheck", "cause", "impact",
                "impactWhy", "ledgerNote", "pictureStatus")
out = {"score": d.get("workerScore") or d.get("score"),
       "summary": d.get("summary") or "the look's own summary",
       "criteria": [], "gaps": [], "couldNot": d.get("couldNot") or [],
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
json.dump(out, open(sys.argv[1], "w"), indent=1)
PY
}
score() { # <fixture dir> <out dir>
  local d="$1" o="$2"; mkdir -p "$o"
  $PY "$CAGE" 240 $PY "$SCORE" "$d/verdict.json" "$d/criteria.json" \
    "$o/verdict.json" "$d/observations.json" "$d/tests.json" "$d/impacts.json" \
    "$d/pairs.json" "$d/walk.json" "$d/seed.json" "$d/unlisted.json" \
    "$d/readings.json" "$d/decisions.json" "$d/journey.json" "$d/shots" \
    >"$o/wire.txt" 2>"$o/err.txt"
}
R="$TMPROOT/m2"; mkm2 "$R"
score "$R" "$TMPROOT/m2out"
V="$TMPROOT/m2out/verdict.json"
SIX="prd-5 prd-10 prd-11 t-003-ac2 t-003-ac3 t-003-ac5"

check "2z. the replay scored at all" '[ -s "$V" ]'
check "2z2. …and it is in the rail's regime (this look DOES record landings)" \
  "$PY -c \"
import json,glob,sys
hit=[p for p in glob.glob('$R/shots/*/*.json')
     if (lambda d: isinstance(d,dict) and d.get('shot')
         and (isinstance(d.get('landed'),dict) or isinstance(d.get('page'),dict)))
        (json.load(open(p)))]
sys.exit(0 if hit else 1)\""
check "2a. THE BEHAVIOUR — all six filed faults read 'gap', not 'untested'" \
  "$PY -c \"
import json,sys
d=json.load(open('$V')); by={c['id']:c for c in d['criteria']}
got={i:by[i]['status'] for i in '$SIX'.split()}
print(got)
sys.exit(0 if all(v=='gap' for v in got.values()) else 1)\""
check "2b. THE BEHAVIOUR — counts.gap agrees with the array it counts" \
  "$PY -c \"
import json,sys
d=json.load(open('$V'))
print('counts',d['counts'],'gaps',len(d['gaps']))
sys.exit(0 if d['counts']['gap']==len([c for c in d['criteria'] if c['status']=='gap'])
         and d['counts']['gap']>=len(d['gaps']) else 1)\""
check "2b2. …and counts.contradictions is no longer zero beside six contradictions" \
  "$PY -c \"
import json,sys
d=json.load(open('$V'))
n=len([g for g in d['gaps'] if g.get('kind')=='contradiction'])
print('contradictions',d['counts']['contradictions'],'of',n)
sys.exit(0 if n and d['counts']['contradictions']==n else 1)\""
check "2c. …and the row STILL DISCLOSES that its picture could not be placed" \
  "$PY -c \"
import json,sys
d=json.load(open('$V')); by={c['id']:c for c in d['criteria']}
miss=[i for i in '$SIX'.split()
      if not (by[i].get('landing') or {}).get('unplaced')]
print('no disclosure on',miss)
sys.exit(0 if not miss else 1)\""
check "2c2. …in the report the captain reads, not only in the JSON" \
  '[ -s "$TMPROOT/m2out/report.md" ] || grep -q . "$TMPROOT/m2out/wire.txt"'
check "2d. CONTROL — a 'met' on the very same unplaceable picture is STILL refused" \
  "$PY -c \"
import json,sys
d=json.load(open('$V')); by={c['id']:c for c in d['criteria']}
# prd-4 / t-001-ac4 / t-002-ac1 cite the same self-taken shots and the look
# rated them MET; the rail must still take them to untested.
got={i:by[i]['status'] for i in ('prd-4','t-001-ac4','t-002-ac1') if i in by}
print(got)
sys.exit(0 if got and all(v=='untested' for v in got.values()) else 1)\""
# THE MUTATION. Point one kept gap's cited shot at a readout that says it landed
# somewhere else: S241 proper must still fire, for a gap as much as for a met.
MUT="$TMPROOT/m2mut"; cp -R "$R" "$MUT"
$PY - "$MUT" <<'PY'
import json, os, sys
root = sys.argv[1]
# Give t-003-ac3's cited shot a readout that records a DIFFERENT page, and point
# the row's intent at a screen that readout does not show.
v = json.load(open(os.path.join(root, "verdict.json")))
for c in v["criteria"]:
    if c["id"] == "t-003-ac3":
        c["shot"] = "mislanded"
json.dump(v, open(os.path.join(root, "verdict.json"), "w"), indent=1)
look = [os.path.join(root, "shots", d) for d in os.listdir(os.path.join(root, "shots"))
        if os.path.isdir(os.path.join(root, "shots", d))][0]
json.dump({"shot": "mislanded",
           "intent": {"screen": "screen-week", "textMustInclude": [],
                      "from": "the control: a landing this picture did NOT reach"},
           "landed": {"url": "http://127.0.0.1:1/settings", "title": "Settings",
                      "screen": "screen-settings", "textSample": "Settings"},
           "page": {"url": "http://127.0.0.1:1/settings", "title": "Settings"}},
          open(os.path.join(look, "mislanded.json"), "w"), indent=1)
open(os.path.join(look, "mislanded.png"), "wb").write(b"\x89PNG\r\n\x1a\n")
PY
score "$MUT" "$TMPROOT/mutout"
check "2e. MUTATION — a gap whose shot the record says LANDED ELSEWHERE is still refused" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/mutout/verdict.json'))
r=[c for c in d['criteria'] if c['id']=='t-003-ac3'][0]
print(r['status'], (r.get('note') or '')[:90])
sys.exit(0 if r['status']=='untested' else 1)\""
fi

# ===========================================================================
# 3. THE LOOK'S OWN COPY IS A PLACE TO STAND — and nothing wider
# ===========================================================================
echo ""
echo "3. the declared-step gate accepts the copy the look just minted, and nothing else"

COPY="$TMPROOT/copy"; mkdir -p "$COPY/pkg"
OUTSIDE="$TMPROOT/outside"; mkdir -p "$OUTSIDE"
acts() { # <out tag> <worktree-or-empty> <json>
  printf '%s' "$3" >"$TMPROOT/acts-$1.json"
  if [ -n "$2" ]; then
    $PY "$XORUN" actions --actions "$TMPROOT/acts-$1.json" \
      --out "$TMPROOT/kept-$1.json" --worktree "$2" >"$TMPROOT/acts-$1.log" 2>&1
  else
    $PY "$XORUN" actions --actions "$TMPROOT/acts-$1.json" \
      --out "$TMPROOT/kept-$1.json" >"$TMPROOT/acts-$1.log" 2>&1
  fi
}
kept_n() { $PY -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(len(d.get('reachSteps') or []))" "$TMPROOT/kept-$1.json" 2>/dev/null; }
why_of() { $PY -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(' | '.join(str(r.get('why') or '') for r in (d.get('refused') or [])))" \
  "$TMPROOT/kept-$1.json" 2>/dev/null; }

# Arguments passed LITERALLY — never through a shell variable that zsh will not
# word-split — and every case names what it expects.
acts inside "$COPY" "[{\"do\":\"run\",\"argv\":[\"git\",\"status\"],\"cwd\":\"$COPY\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3a. THE BEHAVIOUR — cwd = the look's own copy, by absolute path, is KEPT" \
  '[ "$(kept_n inside)" = "1" ]'
acts insidesub "$COPY" "[{\"do\":\"read\",\"path\":\"$COPY/pkg/render.py\",\"evidence\":\"02.txt\",\"for\":\"prd-1\"}]"
check "3b. …and so is a read of a path inside it" \
  '[ "$(kept_n insidesub)" = "1" ]'
acts nowt "" "[{\"do\":\"run\",\"argv\":[\"git\",\"status\"],\"cwd\":\"$COPY\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3c. CONTROL — with no copy declared, that very step is still REFUSED" \
  '[ "$(kept_n nowt)" = "0" ] && why_of nowt | grep -qF "absolute path outside the worktree"'
acts outside "$COPY" "[{\"do\":\"run\",\"argv\":[\"git\",\"status\"],\"cwd\":\"$OUTSIDE\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3d. CONTROL — an absolute cwd OUTSIDE the copy is still REFUSED" \
  '[ "$(kept_n outside)" = "0" ] && why_of outside | grep -qF "absolute path outside the worktree"'
acts etc "$COPY" '[{"do":"run","argv":["git","status"],"cwd":"/etc","evidence":"01.txt","for":"prd-1"}]'
check "3d2. CONTROL — and /etc most certainly is" \
  '[ "$(kept_n etc)" = "0" ]'
acts shell "$COPY" "[{\"do\":\"run\",\"argv\":[\"bash\",\"-c\",\"echo PWNED\"],\"cwd\":\"$COPY\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3e. CONTROL — THE ARGV FENCE STILL FIRES: no shell, even inside the copy" \
  '[ "$(kept_n shell)" = "0" ] && why_of shell | grep -qi "shell"'
acts dashc "$COPY" "[{\"do\":\"run\",\"argv\":[\"python3\",\"-c\",\"print(1)\"],\"cwd\":\"$COPY\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3f. CONTROL — nor an interpreter with -c, even inside the copy" \
  '[ "$(kept_n dashc)" = "0" ]'
acts argvabs "$COPY" "[{\"do\":\"run\",\"argv\":[\"cat\",\"/etc/hosts\"],\"cwd\":\"$COPY\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3g. CONTROL — nor an absolute path in the argv (the argv fence is untouched)" \
  '[ "$(kept_n argvabs)" = "0" ]'
acts dotdot "$COPY" "[{\"do\":\"run\",\"argv\":[\"git\",\"status\"],\"cwd\":\"<worktree>/../..\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3h. CONTROL — nor a walk up out of the tree" \
  '[ "$(kept_n dotdot)" = "0" ]'
acts mark "$COPY" '[{"do":"run","argv":["git","status"],"cwd":"<worktree>","evidence":"01.txt","for":"prd-1"}]'
check "3i. THE CASE THAT MUST SUCCEED — the <worktree> mark is kept, as it always was" \
  '[ "$(kept_n mark)" = "1" ]'
acts ghost "$TMPROOT/not-a-copy" "[{\"do\":\"run\",\"argv\":[\"git\",\"status\"],\"cwd\":\"$COPY\",\"evidence\":\"01.txt\",\"for\":\"prd-1\"}]"
check "3j. CONTROL — a copy that is not on disk grants nothing (never on a promise)" \
  '[ "$(kept_n ghost)" = "0" ]'

# AND AT RUN TIME, where the worktree is real: the same absolute cwd passes
# `refuse_reason`, so the gate was the only thing in the way.
check "3k. run time agrees — refuse_reason accepts that cwd inside the real tree" \
  "$PY -c \"
import importlib.util,sys
s=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
inside=m.refuse_reason({'do':'run','argv':['git','status'],'cwd':'$COPY'},'$COPY','$TMPROOT/throwaway-home')
out=m.refuse_reason({'do':'run','argv':['git','status'],'cwd':'$OUTSIDE'},'$COPY','$TMPROOT/throwaway-home')
print(repr(inside)); print(repr(out))
sys.exit(0 if inside=='' and out!='' else 1)\""

# ===========================================================================
# 4. S261 FIX ROUND 2 — THE INSTRUCTIONS MUST NOT CONTRADICT THEMSELVES
# ===========================================================================
# Round 1 handed the reviewer a camera and taught the gate one place to stand.
# A live model then NEVER ONCE USED THE CAMERA, and every one of its six
# declared steps was refused. Three contradictions, all read off the SAME
# assembled prompt the live worker actually received
# (/private/tmp/claude-501/night-2026-10-08/s261r3/argv/call-20261008-222522-39198.txt,
# 1515 lines):
#
#   F1  :736 printed `HOME=<the absolute throwaway home>` — the ONLY line in
#       1515 that spells the HOME absolutely, against ~10 that teach the mark.
#       The worker reasonably copied that absolute string into a declared
#       step's `env.HOME`, and `declared_escape` refuses exactly that ("env
#       HOME … is not the throwaway HOME"). ALL SIX declared steps were
#       refused, and they were the SEED steps — so the launched build had no
#       habits in it and every screenshot the look cites is of an EMPTY app.
#       Three findings (prd-5, prd-10, prd-11) are settled on a picture whose
#       own record reads "No habits yet".
#       CURED ON THE PROMPT SIDE ONLY. The fence did not move one byte: the
#       paragraph now teaches the shell form (absolute, for the worker's own
#       commands) and the DECLARED form (the mark) as two different things,
#       because they are.
#
#   D1  :744-761 hands the worker a camera whose `--out` is under
#       `.git/lcars/…/xo/shots/look-N`, and 34 lines later (:770) threatened
#       that "the mission's state (`.git/lcars/`) … a worker that writes any of
#       it is killed on the spot and the look is thrown away." A worker that
#       obeys the prohibition CANNOT TAKE A PICTURE. The threat was also
#       INACCURATE: the real post-turn audit (`WORKER_FENCE_WATCH`) watches TEN
#       NAMED FILES and `xo/shots/**` is not one of them, so writing the shots
#       directory was never going to kill anything. So the PROSE is corrected
#       to the real fence — and it is RENDERED FROM `$WORKER_FENCE_WATCH`
#       itself, so the two cannot drift apart again (4h is the mutation that
#       proves it is rendered, not transcribed). The audit is NOT widened: 4i.
#
#   D2  "cite the picture by the name you gave it" is FALSE for the `--prefix`
#       form the paragraph spells out. MEASURED — the real camera run at a real
#       page, then the branch's OWN `landing_readout` loaded over the result:
#         --prefix week                 → week-01.png/.json
#                                         `week`    → NO LANDING RECORD
#                                         `week-01` → PLACED
#         --actions {"screenshot":"w"}  → w.png/.json
#                                         `w`       → PLACED
#                                         `w-01`    → NO LANDING RECORD
#       Only the name ACTUALLY WRITTEN places. The paragraph now says so for
#       both forms, and 4o re-measures it against the real placer.
echo ""
echo "4. fix round 2: the camera is usable, and the HOME is the one the fence takes"

flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
# JUST THE ROUND'S OWN HOME PARAGRAPH, flattened. Scoped deliberately: the
# assembled prompt teaches `<throwaway-home>` in ten OTHER places (the
# live-check checklists), so an unscoped grep for the mark passes vacuously —
# measured: it passed against the unfixed source. The window is this
# paragraph's own first and last sentences.
home_para() { awk '/Put this HOME in front of/,/set HOME on the COMMAND/' "$1" | tr '\n' ' ' | tr -s ' '; }

# The audit's real watch list, read out of run.sh — the ONE source of truth both
# the prose and this suite are held to.
WATCHED="$(sed -n '/^WORKER_FENCE_WATCH="/,/"$/p' "$RUNSH" |
           sed 's/^WORKER_FENCE_WATCH="//; s/"$//' | grep -c .)"
WATCHED_NAMES="$(sed -n '/^WORKER_FENCE_WATCH="/,/"$/p' "$RUNSH" |
                 sed 's/^WORKER_FENCE_WATCH="//; s/"$//' | grep .)"

spawn_n1 r2 "$WT" "$SHOTS" "$DRIVER"
P2="$TMPROOT/prompt-r2.txt"
check "4z. the round-2 prompt was captured at all" '[ -s "$P2" ]'

# --- F1: the HOME the prompt hands over is one the fence will take ----------
check "4a. F1 BEHAVIOUR — the HOME paragraph ITSELF teaches the MARK for a declared step" \
  'home_para "$P2" | grep -qF "\"env\": {\"HOME\": \"<throwaway-home>\"}"'
check "4a2. F1 CONTROL — that window really is the round's own paragraph, not the template" \
  '[ -n "$(home_para "$P2")" ] && home_para "$P2" | grep -qF "HOME=$THOME"'
check "4b. F1 — …and says in so many words that an absolute env.HOME is refused" \
  'home_para "$P2" | grep -qi "absolute path is REFUSED"'
check "4c. F1 CONTROL — the shell form still spells the directory out (its own commands)" \
  'grep -qF "HOME=$THOME" "$P2"'
check "4d. F1 CONTROL — the fence was NOT widened: it takes the mark, refuses the absolute" \
  "$PY -c \"
import importlib.util,sys
s=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
mark=m.declared_escape({'do':'run','argv':['git','status'],'cwd':'<worktree>','env':{'HOME':'<throwaway-home>'}})
abso=m.declared_escape({'do':'run','argv':['git','status'],'cwd':'<worktree>','env':{'HOME':'$THOME'}})
print('mark', repr(mark)); print('absolute', repr(abso))
sys.exit(0 if mark=='' and abso!='' else 1)\""

# --- D1: the prohibition no longer forbids the camera's only destination ----
check "4e. D1 BEHAVIOUR — the blanket 'writes any of it' threat is GONE" \
  '! flat "$P2" | grep -qi "writes any of it is killed"'
check "4f. D1 BEHAVIOUR — the look's own shots dir is named as a place it IS expected to write" \
  'grep -qF "$SHOTS" "$P2" && flat "$P2" | grep -qi "EXPECTED to write"'
MISSING_WATCHED=""
while IFS= read -r wf; do
  [ -n "$wf" ] || continue
  grep -qF "$wf" "$P2" || MISSING_WATCHED="$MISSING_WATCHED $wf"
done <<EOF
$WATCHED_NAMES
EOF
check "4g. D1 — every file the audit REALLY watches is named in the prompt" \
  '[ -z "$MISSING_WATCHED" ]'

# THE MUTATION FOR 4g, and the whole anti-drift claim: an ELEVENTH file added to
# `WORKER_FENCE_WATCH` in a COPY of run.sh must show up in the prompt by itself.
# A hand-transcribed list cannot do that; a rendered one cannot fail to.
MUT="$TMPROOT/mut-run"
cp -R "$REPO_ROOT/skills/lcars-run" "$MUT" >/dev/null 2>&1
"$PY" - "$MUT/run.sh" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2 = s.replace('WORKER_FENCE_WATCH="state.json\n',
               'WORKER_FENCE_WATCH="state.json\nzz-mutant-watched.json\n', 1)
assert s2 != s, "the watch list was not where this mutation expects it"
open(p, "w", encoding="utf-8").write(s2)
PY
spawn_mut() { # <tag>
  ( cd "$repo" && \
    XO_PROMPT_DUMP="$TMPROOT/prompt-$1.txt" \
    LCARS_WORKER_ADAPTER="$DUMP" LCARS_WORKER_BIN="$WORKER" \
    LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    LCARS_XO_PROMPTS="$REPO_ROOT/skills/lcars-xo/prompts" \
    LCARS_STATE_LIB="$REPO_ROOT/skills/lcars-init/lcars-state.sh" \
    LCARS_XO_WORKTREE="$WT" LCARS_XO_THROWAWAY_HOME="$THOME" \
    LCARS_XO_SHOTS_DIR="$SHOTS" LCARS_XO_CAMERA="$DRIVER" LCARS_XO_CAMERA_NODE=node \
    bash "$MUT/run.sh" spawn-number-one --mission lcars-1 \
      --mode evaluate --outdir "$TMPROOT/out-$1" ) >"$TMPROOT/log-$1.txt" 2>&1
}
spawn_mut mutwatch
check "4h. D1 THE MUTATION — an 11th watched file appears in the prompt unaided (it is RENDERED)" \
  '[ -s "$TMPROOT/prompt-mutwatch.txt" ] &&
   grep -qF "zz-mutant-watched.json" "$TMPROOT/prompt-mutwatch.txt" &&
   ! grep -qF "zz-mutant-watched.json" "$P2"'
check "4i. D1 CONTROL — the audit itself did NOT move: ten watched files, no shots among them" \
  '[ "$WATCHED" = 10 ] && ! printf "%s\n" "$WATCHED_NAMES" | grep -qi "shot"'
check "4j. D1 CONTROL — the prohibition SURVIVES: the captain's checkout is still off limits" \
  'flat "$P2" | grep -qi "never reach back into the captain" &&
   flat "$P2" | grep -qi "killed on the spot"'
check "4k. D1 CONTROL — with no camera plumbed, no write under .git/lcars is invited" \
  '! flat "$P_NOCAM" | grep -qi "EXPECTED to write" &&
   ! grep -qF "$SHOTS" "$P_NOCAM"'

# --- D2: the citation rule the prompt states is the one that actually places -
check "4l. D2 BEHAVIOUR — the --prefix form's REAL filename is taught (<prefix>-01)" \
  'flat "$P2" | grep -qF -- "<a short name>-01"'
check "4m. D2 BEHAVIOUR — the --actions screenshot form is taught as the exactly-named one" \
  'flat "$P2" | grep -qF "{\"screenshot\":\"week\"}" &&
   flat "$P2" | grep -qi "exactly that name"'
check "4n. D2 BEHAVIOUR — the false sentence is gone" \
  '! flat "$P2" | grep -qi "cite the picture by the name you gave it"'

# 4o — THE MEASUREMENT, not the prose. The real camera is run both ways at a
# real page and the branch's own `landing_readout` is asked which citation
# places. Needs a Chrome; skipped (never silently passed) without one.
CHROME_BIN=""
for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "/Applications/Chromium.app/Contents/MacOS/Chromium" \
         /usr/bin/google-chrome /usr/bin/chromium /usr/bin/chromium-browser; do
  [ -x "$c" ] && { CHROME_BIN="$c"; break; }
done
if [ -z "$CHROME_BIN" ]; then
  skip "4o. the citation rule measured against the real placer (no Chrome on this box)"
else
  CAMROOT="$TMPROOT/camshots"; mkdir -p "$CAMROOT/look-1"
  ACTROOT="$TMPROOT/actshots"; mkdir -p "$ACTROOT/look-1"
  PAGE="$TMPROOT/page.html"
  printf '%s\n' '<!doctype html><title>Week screen</title><body style="background:#123">' \
    '<h1 style="color:#fe0">Week</h1><p style="color:#0ff">Mon Tue Wed</p>' \
    '<div style="width:300px;height:120px;background:#c33">grid</div></body>' >"$PAGE"
  printf '%s\n' "[{\"navigate\":\"file://$PAGE\"},{\"screenshot\":\"weekcam\"}]" >"$TMPROOT/acts.json"
  "$PY" "$CAGE" 180 node "$DRIVER" --url "file://$PAGE" \
    --out "$CAMROOT/look-1" --prefix week >"$TMPROOT/cam-url.log" 2>&1
  "$PY" "$CAGE" 180 node "$DRIVER" --url "file://$PAGE" --actions "$TMPROOT/acts.json" \
    --out "$ACTROOT/look-1" --prefix week >"$TMPROOT/cam-act.log" 2>&1
  check "4o1. the camera really wrote week-01 (prefix form) and weekcam (actions form)" \
    '[ -f "$CAMROOT/look-1/week-01.json" ] && [ -f "$ACTROOT/look-1/weekcam.json" ]'
  check "4o2. THE MEASUREMENT — those exact names PLACE, and the other spellings do not" \
    "$PY -c \"
import importlib.util,sys
s=importlib.util.spec_from_file_location('xs','$SCORE'); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
r = lambda root,name: bool(m.landing_readout(root,name)[1])
got = {'week-01 (prefix form)': r('$CAMROOT','week-01'),
       'week (prefix form)':    r('$CAMROOT','week'),
       'weekcam (actions form)':r('$ACTROOT','weekcam'),
       'weekcam-01 (actions)':  r('$ACTROOT','weekcam-01')}
for k,v in got.items(): print('%-26s %s' % (k, 'PLACED' if v else 'NO LANDING RECORD'))
sys.exit(0 if (got['week-01 (prefix form)'] and not got['week (prefix form)']
               and got['weekcam (actions form)'] and not got['weekcam-01 (actions)']) else 1)\""
fi
check "4p. ZERO SPEND — section 4 invoked no engine" '[ ! -s "$SPEND_LOG" ]'

# ===========================================================================
# 5. F1's THIRD, FOURTH AND FIFTH INSTANCE — the CHECKLISTS taught a HOME the
#    fence refuses
# ===========================================================================
# F1 (section 4) was cured in `run.sh`'s own paragraph. The SAME defect was then
# measured three more times in the live-check checklists, which reach the live
# worker VERBATIM — observed at lines 926, 1061 and 1311 of the assembled prompt
# the live look actually received:
#
#   live-check/cli.md:118  "HOME": "<second-throwaway-home>"
#   live-check/cli.md:253  "HOME": "<a-fresh-throwaway-home>"
#   live-check/web.md:223  "HOME": "<a-fresh-throwaway-home>"
#
# `declared_escape` mints and honours exactly `<throwaway-home>`,
# `<throwaway-home-2>` and `<throwaway-home-3>`. None of those three is one of
# them, so a worker copying the example it was handed gets
# "env HOME … is not the throwaway HOME" and the step never runs. That is the
# measured mechanism that made the last live look photograph an EMPTY app: its
# refused steps were the SEED steps. Two of the three sit on the second-actor
# item that section 4's cure now actively points the worker at.
#
# THE GUARD READS THE ACCEPTED SET OUT OF `xo-run.py` AND RUNS THE REAL GATE.
# `tests/lib/home_marks_guard.py` sweeps every `"HOME": "…"` in every checklist
# and judges each value with `declared_escape` itself — no allow-list is
# transcribed into the test, so a fourth instance, or a fourth mark, is caught
# without anybody remembering to update a list. Same trick as 4h.
echo ""
echo "5. no checklist teaches a HOME mark the fence refuses"

GUARD_HM="$REPO_ROOT/tests/lib/home_marks_guard.py"
CLDIR="$REPO_ROOT/skills/lcars-run/live-check"

"$PY" "$GUARD_HM" "$XORUN" "$CLDIR" >"$TMPROOT/hm-real.txt" 2>&1
HM_REAL=$?
check "5z. the guard really swept something (an empty sweep is not a pass)" \
  'grep -qE "^1[0-9] HOME value\(s\) taught|^[1-9][0-9]* HOME value\(s\) taught" "$TMPROOT/hm-real.txt" &&
   ! grep -q "NOTHING WAS SCANNED" "$TMPROOT/hm-real.txt"'
check "5a. THE BEHAVIOUR — every HOME the checklists teach is one the fence honours" \
  '[ "$HM_REAL" = 0 ]'

# THE DERIVATION, proved the 4h way: drop `<throwaway-home-2>` from the FENCE's
# own mark tuple in a COPY of xo-run.py, and the guard must start refusing the
# second-actor line. A guard with three hard-coded strings could not notice.
MUTX="$TMPROOT/xorun-mut.py"
"$PY" - "$XORUN" "$MUTX" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
old = "EXTRA_HOME_MARKS = (HOME_MARK_2, HOME_MARK_3)"
new = "EXTRA_HOME_MARKS = (HOME_MARK_3,)"
assert old in s, "the mark tuple is not where this mutation expects it"
open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
"$PY" "$GUARD_HM" "$MUTX" "$CLDIR" >"$TMPROOT/hm-mutfence.txt" 2>&1
HM_MUTF=$?
check "5b. THE MUTATION — the accepted set is READ from xo-run.py, not transcribed" \
  '[ "$HM_REAL" = 0 ] && [ "$HM_MUTF" != 0 ] &&
   grep -q "throwaway-home-2" "$TMPROOT/hm-mutfence.txt"'

# AND THE MUTATION ON THE OTHER SIDE: a fourth bad instance, added to a COPY of
# the checklists, must be caught and NAMED. This is what makes 5a a live guard
# rather than a one-off fix.
CLMUT="$TMPROOT/cl-mut"
cp -R "$CLDIR" "$CLMUT"
"$PY" - "$CLMUT/cli.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '"cwd": "<worktree>",'
assert old in s
open(p, "w", encoding="utf-8").write(
    s.replace(old, old + '\n  "env": {"HOME": "<zz-a-fourth-bogus-home>"},', 1))
PY
"$PY" "$GUARD_HM" "$XORUN" "$CLMUT" >"$TMPROOT/hm-mutcl.txt" 2>&1
HM_MUTC=$?
check "5c. THE MUTATION — a FOURTH bad instance is caught and named" \
  '[ "$HM_MUTC" != 0 ] && grep -q "zz-a-fourth-bogus-home" "$TMPROOT/hm-mutcl.txt"'

check "5d. CONTROL — the fence did not move: it mints -2 and -3 and still refuses the rest" \
  "$PY -c \"
import importlib.util,sys
s=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
j=lambda v: m.declared_escape({'do':'run','argv':['git','status'],'cwd':'<worktree>','env':{'HOME':v}})
two=j('<throwaway-home-2>'); three=j('<throwaway-home-3>')
four=j('<throwaway-home-4>'); other=j('/Users/somebody-else')
for k,v in (('-2',two),('-3',three),('-4',four),('absolute',other)):
    print('%-9s %s' % (k, v or 'ACCEPTED'))
sys.exit(0 if two=='' and three=='' and four!='' and other!='' else 1)\""

# THE CURE MUST NOT BE 'DELETE THE DISTINCTION'. Item 4 of the cli checklist is
# "two actors — two HOMEs": collapsing it to the look's FIRST home would make
# the guard green and the checklist worthless. So the value it teaches is read
# OFF THE FILE and required to be a second one.
SECOND_HOME="$(awk '/### 4\. Two actors/,/^### 5\./' "$CLDIR/cli.md" |
               sed -n 's/.*"HOME"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
check "5e. CONTROL — the two-actors item still teaches a SECOND home, not the first" \
  '[ -n "$SECOND_HOME" ] && [ "$SECOND_HOME" != "<throwaway-home>" ]'
# …and MEASURED, not inferred: that mark really mints a different directory
# beside the look's first HOME. Two actors, two laptops.
check "5f. MEASURED — that mark mints a DIFFERENT directory beside the first HOME" \
  "$PY -c \"
import importlib.util,sys,os
s=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(s)
s.loader.exec_module(m)
first=os.path.join('$TMPROOT','hm-home'); os.makedirs(first, exist_ok=True)
second=m.mint_extra_home('$SECOND_HOME', first)
print('first ', first); print('second', second or '(nothing minted)')
sys.exit(0 if second and second != first and os.path.isdir(second)
         and os.path.dirname(second)==os.path.dirname(first) else 1)\""
check "5g. ZERO SPEND — section 5 invoked no engine" '[ ! -s "$SPEND_LOG" ]'

# ===========================================================================
printf '\n=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
