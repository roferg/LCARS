#!/usr/bin/env bash
# tests/lcars-xo-told.test.sh — S264: THE REVIEWER IS TOLD, AND ITS OWN WORK COUNTS.
#
# WHAT WAS MEASURED, AND WHY THIS SUITE EXISTS (2026-10-09 spike, over the
# S262 night's real looks):
#
#   1. THE REVIEWER WAS NEVER TOLD ITS STEPS WERE REFUSED. All five assembled
#      round prompts for one milestone were pulled off disk and diffed: round 1
#      is 61,740 bytes, rounds 2–5 are 61,845 each, and round 1 vs round 5
#      differ ONLY in the round number in two paths and the list of files now
#      present. Occurrences of "a step has no shell": 0. Of "declined": 0. Of
#      "previous round": 0. It asked for 12 steps, 10 vanished, and round 2
#      handed it an all-but-identical prompt. Then 8, then 6, then 10 —
#      34 of 36 refused. It changed shape in round 5 only BY INFERENCE.
#      Consequence: all 22 criteria on that milestone cite the SAME transcript.
#
#   2. AND THE PROMPT POINTED THE WRONG WAY. "real shell" appears 4 times in
#      run.sh and 0 times in prompts/evaluate.md — all four in the per-round
#      block ("you have a real shell", "you are expected to use it"). NOWHERE
#      did it say a DECLARED step may not be a shell invocation. The same
#      prompt-versus-fence drift S261's own fix round 2 cured elsewhere.
#
#   3. THE OVER-CLAIMING GUARD PUNISHED THE REVIEWER FOR DOING THE RIGHT THING.
#      It noticed `tests.json` had `testCases: []` and an `outputTail` of seven
#      dots, so it RAN THE SUITE ITSELF verbosely and placed
#      `10-suite-verbose.txt` with seven fully-named cases. `tests_settle`
#      checked the quote ONLY against `tests.json`'s recorded `outputTail`:
#      three rows demoted, the reviewer's own notes overwritten by a machine
#      sentence, coverage pushed to 71% against an 80% floor, grade held
#      HIGH → MEDIUM. `xo-tests.py` admits the gap in its own docstring.
#
#   4. A LOOK THAT FAILED FOR AN INFRASTRUCTURE REASON COULD NEVER BE RETAKEN.
#      `drive_number_one_verify` refuses a second evaluate once `evaluatedAt`
#      is set, so a look that ended because the build would not start, or there
#      was nothing to look at, was stuck. S262's foundation hit exactly this on
#      a greenfield repo.
#
# WHAT IS NOT TOUCHED, re-asserted here so a later session cannot read this
# suite as permission:
#   • THE ARGV FENCE. `_shell_refusal`, `argv_refusal`, `refuse_reason` and
#     `declared_escape` stay closed — this session changes what is REPORTED,
#     never what is ALLOWED (section 5 pins it).
#   • `prompts/evaluate.md` and its 688-line ceiling (section 2f).
#   • `skills/lcars-eeh/` — read, never edited.
#   • A BARE TALLY STILL SETTLES NOTHING (section 3, controls 3c/3d/3e).
#
# EVERY assertion is paired with something that makes it fire. ZERO SPEND: both
# `claude` and `copilot` are PATH shims and the suite asserts they were never
# called (an env var alone has been measured losing to a persisted workerBin).
#
# Usage: bash tests/lcars-xo-told.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
XOSH="$REPO_ROOT/skills/lcars-xo/xo.sh"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
XOJOUR="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
SCORE="$REPO_ROOT/skills/lcars-xo/xo-score.py"
EVALMD="$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md"
CAGE="$REPO_ROOT/tests/lib/cage.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0; fail=0
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/xo-told-XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND: BOTH engines shimmed on PATH ------------------------------
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
# AND THE ZERO-SPEND CLAIM HAS A CONTROL. "0 engine calls" is also what a shim
# that was never on PATH reports, so the shim is proved live once, here, and the
# probe line is then taken back out of the log the suite asserts is empty.
copilot --version >/dev/null 2>&1 || true
SHIM_PROVED=0; [ -s "$SPEND_LOG" ] && SHIM_PROVED=1
: >"$SPEND_LOG"

printf '\n=== S264: the reviewer is told what was refused, and its own work counts ===\n'

# ===========================================================================
# 0. THE RIG — one repo, one mission at verify, and a prompt-dumping adapter
# ===========================================================================
repo="$TMPROOT/repo"
mkdir -p "$repo"
( cd "$repo" && git init -q -b main &&
  git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'original\n' >"$repo/product.py"
( cd "$repo" && git add -A && git commit -qm init ) >/dev/null 2>&1
MDIR="$repo/.git/lcars/missions/lcars-1"
mkdir -p "$MDIR/xo"
cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "a", "model": "claude-sonnet", "projectName": "r",
 "testCommand": "true", "numberOne": {"enabled": true, "engine": "copilot"},
 "created": "2026-05-30T00:00:00Z"}
CJ
cat >"$MDIR/state.json" <<'SJ'
{"id": "lcars-1", "type": "feature", "title": "T", "stage": "verify",
 "branch": "main", "created": "2026-10-09T10:00:00Z"}
SJ
printf '# p\n' >"$MDIR/prd.md"

IN="$TMPROOT/in"; mkdir -p "$IN"
printf '%s\n' '{"productTypes": [{"type": "web", "source": "the plan"}],
 "criteria": [{"id": "prd-1", "text": "x"}]}' >"$IN/criteria.json"

WT="$TMPROOT/wt"
( cd "$repo" && git worktree add --detach "$WT" main ) >/dev/null 2>&1
THOME="$TMPROOT/throwaway-home"; mkdir -p "$THOME"
SHOTS="$MDIR/xo/shots/look-1"; mkdir -p "$SHOTS"

DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

# THE PRODUCT'S OWN WRITER lays both halves down. A test that hand-rolls the
# format proves the old format the moment the format moves, so `write_evidence`
# — the ONE door every step artifact goes through — is called directly.
place_step() { # <dir> <stem> <key> <transcript text>
  DIR="$1" STEM="$2" KEY="$3" BODY="$4" XORUN_PY="$XORUN" $PY - <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("xr", os.environ["XORUN_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.write_evidence(os.environ["DIR"], os.environ["STEM"] + ".txt",
                 os.environ["BODY"],
                 {"do": os.environ.get("VERB") or "run",
                  "key": os.environ["KEY"], "for": "prd-1",
                  "argv": [] if os.environ.get("NOARGV") else ["pytest", "-v"],
                  "checkedBy": "exit 0", "met": True})
PY
}
# A DECLARED `read` STEP, written by the SAME door (S264 fix round 2, FIX 6).
# `do_read`'s readout carries a `path` and no `argv`; this is the shape the
# fix-round-1 tester drove end to end — the reviewer writes a file with its own
# shell, declares one sanctioned `read` step on it, and the file's own contents
# come back as a transcript the harness genuinely recorded producing.
place_read() { # <dir> <stem> <key> <transcript text>
  VERB=read NOARGV=1 place_step "$1" "$2" "$3" "$4"
}
# AND THE OTHER KIND OF PAIR, written the way `xo-drive.js` writes it beside
# every PNG: a caption, and a SHOT readout that records where the page was.
place_caption() { # <dir> <stem> <caption text>
  printf '%s\n' "$3" >"$1/$2.txt"
  printf '%s\n' "{\"shot\": \"$2\", \"file\": \"$1/$2.png\",
   \"pixels\": {\"painted\": true, \"width\": 1200},
   \"landed\": {\"url\": \"http://x/\"}, \"intent\": null}" >"$1/$2.json"
}


# ===========================================================================
# THE FOUR PRODUCTION-WIRING DRIVES (S264 fix round 2, FIX 1)
#
# THE MEASURED DEFECT IN THIS SUITE, not in the product. The fix-round-1 tester
# mutated full source copies and counted red checks:
#
#   scope reverted (xo.sh's 17th scorer argument back to the root of every
#   look — the exact bug round 1 cured)         → 1 red, and it was a GREP
#   scope reverted AND the grep satisfied       → 0 red. 100/100 green WITH the
#                                                 measured bug back in.
#   retake stamp removed                        → 0 red. It then drove the real
#                                                 gate 3x for 3 model looks
#                                                 against a baseline of 1 — an
#                                                 unbounded loop, invisible.
#   crash baton removed                         → 1 red, a grep
#   delivery export removed                     → 1 red, a grep
#
# WHY THEY WERE BLIND: every behavioural check was handed the thing under test
# BY THE TEST. `placed_transcripts` was called with a look dir the TEST chose,
# so it passed identically whichever directory the real caller passed; the baton
# was passed in; `lookBlockedBy` and `retakenAt` were seeded by hand.
#
# SO THE HELPERS BELOW TAKE THE PRODUCTION TEXT AND RUN IT. A fragment of
# `xo.sh` is lifted verbatim, sourced into a shell with sentinel values, and the
# argv / the environment / the record it produces is read back. A check that
# passes for a reason unrelated to the property it names is how fix round 1's
# bug shipped in the first place.
# ===========================================================================

# A stand-in for python3 at the scorer call site that records the argv it was
# handed, one argument per line, and runs nothing.
RECORDER="$TMPROOT/argv-recorder.sh"
cat >"$RECORDER" <<'RC'
#!/usr/bin/env bash
: >"$ARGV_OUT"
for a in "$@"; do printf '%s\n' "$a" >>"$ARGV_OUT"; done
exit 0
RC
chmod +x "$RECORDER"

# THE PRODUCTION CALL SITE, LIFTED VERBATIM. `$1` is the shell variable the
# assignment targets (`report` = the first score, `rep2` = the re-check's).
frag_of() { # <report|rep2> → path to a sourceable fragment of xo.sh
  local which="$1" frag
  frag="$TMPROOT/frag-$which.sh"
  [ -s "$frag" ] || WHICH="$which" FRAG="$frag" $PY - "$XOSH" <<'PY'
import os, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
w = os.environ["WHICH"]
m = re.search(r"^[ \t]*" + w + r'="\$\(LCARS_XO_ENGINE=.*?2>/dev/null\)"[^\n]*',
              t, re.M | re.S)
if not m:
    raise SystemExit("no %s call site in xo.sh" % w)
open(os.environ["FRAG"], "w", encoding="utf-8").write(
    m.group(0).replace("local ", "") + "\n")
PY
  printf '%s\n' "$frag"
}

# DRIVE A — the argv the REAL call site builds, read back positionally.
scorer_argv() { # <report|rep2> → the argv, one per line (line 1 = the script)
  local which="$1" frag rec
  frag="$(frag_of "$which")"
  rec="$TMPROOT/argv-$which.txt"; : >"$rec"
  ( XO_PY="$RECORDER" ARGV_OUT="$rec" SKILL_DIR=SKILLDIR \
    xodir=XODIR shots=LOOKDIR dir=MDIR verdict=RAWVERDICT \
    obsfile=OBS testsfile=TESTS rwalk=RWALK out=OUT st=ST \
    bash -c 'xo_engine_for() { printf "stub"; }; xo_engine=""; src=0
             source "'"$frag"'"' ) >/dev/null 2>&1
  cat "$rec"
}
nth_arg() { # <report|rep2> <n> — the Nth argument AFTER the script path
  scorer_argv "$1" | sed -n "$(( $2 + 1 ))p"
}
n_args() { # <report|rep2> — how many arguments after the script path
  local n; n="$(scorer_argv "$1" | wc -l | tr -d ' ')"; printf '%s\n' "$(( n - 1 ))"
}

# DRIVE D — the look's own export region, lifted verbatim and SOURCED, so the
# values `run.sh` receives are the ones the production code computes.
FRAG_EXPORTS="$TMPROOT/frag-exports.sh"
FRAG="$FRAG_EXPORTS" $PY - "$XOSH" <<'PY'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.find('      export LCARS_XO_INPUT_DIR="$input"')
j = t.find('      if [ -n "$xo_engine" ]; then', i)
if i < 0 or j <= i:
    raise SystemExit("could not find the look's export region in xo.sh")
open(os.environ["FRAG"], "w", encoding="utf-8").write(t[i:j])
PY
# DRIVE A, END TO END — the REAL scorer, handed the argv the REAL call site
# builds. No test writes those 17 arguments: `xo.sh`'s own `report=` line is
# sourced, so a mutation to the 17th argument changes what the scorer SEES and
# the end-to-end checks go red behaviourally rather than by a grep.
# The rig's contract: the worker's raw verdict at <d>/verdict.json, the criteria
# at <d>/xo/criteria.json, the recorded run at <d>/tests.json. The scored
# verdict lands where the look puts it (<d>/xo/verdict.json) and is copied to
# <d>/out.json for the checks.
run_prod_scorer() { # <d> <look-subdir-name>
  local d="$1" look="$2" frag
  frag="$(frag_of report)"
  ( env XO_PY="$PY" SKILL_DIR="$REPO_ROOT/skills/lcars-xo" \
        xodir="$d/xo" shots="$d/xo/shots/$look" dir="$d" \
        verdict="$d/verdict.json" obsfile="" testsfile="$d/tests.json" st="ST" \
        D="$d" FRAG="$frag" \
      $PY "$CAGE" 240 bash -c '
        xo_engine_for() { printf ""; }; xo_engine=""; src=0
        source "$FRAG"
        printf "%s" "$report" >"$D/wire.txt"
        printf "%s\n" "$src"  >"$D/src.txt"
        cp "$D/xo/verdict.json" "$D/out.json" 2>/dev/null || true' ) \
    >"$d/scorer-log.txt" 2>&1
}

look_exports() { # <xodir> <round> → every LCARS_XO_* the real region exports
  ( input="$IN" shots="$SHOTS" xodir="$1" round="$2" \
    XO_DRIVER="" XO_NODE="" \
    bash -c 'source "'"$FRAG_EXPORTS"'" >/dev/null 2>&1; env' ) \
    | grep '^LCARS_XO_' | sort
}
export_val() { # <xodir> <round> <NAME>
  look_exports "$1" "$2" | sed -n "s/^$3=//p" | head -1
}

# The one road to an assembled prompt. $1 is a tag; the rest is environment
# the real look exports — nothing here is hand-written prompt text.
spawn_n1() { # <tag> [NAME=VALUE ...]
  local tag="$1"; shift
  ( cd "$repo" && env \
    XO_PROMPT_DUMP="$TMPROOT/prompt-$tag.txt" \
    LCARS_WORKER_ADAPTER="$DUMP" LCARS_WORKER_BIN="$WORKER" \
    LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
    LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
    LCARS_XO_WORKTREE="$WT" LCARS_XO_THROWAWAY_HOME="$THOME" \
    LCARS_XO_SHOTS_DIR="$SHOTS" \
    "$@" \
    bash "$RUNSH" spawn-number-one --mission lcars-1 \
      --mode evaluate --outdir "$TMPROOT/out-$tag" ) >"$TMPROOT/log-$tag.txt" 2>&1
}

# ===========================================================================
# 1. TELL IT — the previous round's refusals reach the next round's prompt,
#    BUILT FROM THE RECORD THE HARNESS ALREADY WRITES (never re-derived).
# ===========================================================================
echo ""
echo "1. the refusal record the harness wrote in round 1 reaches round 2's prompt"

# THE PRODUCER'S OWN RECORD, MADE BY THE REAL CODE. The worker asks for three
# steps; one is the measured 34-times refusal (a shell), one walks out of the
# tree, one is fine. `xo-run.py actions` is the gate that refuses, and
# `xo-journey.py reach-record` is where the harness already files the refusals
# per round. Nothing below is hand-written.
ACTS="$TMPROOT/xo-actions-r1.json"
cat >"$ACTS" <<'AJ'
{"actions": [
  {"do": "run", "key": "suite-verbose", "for": "prd-1",
   "argv": ["bash", "-c", "pytest -v | tail -40"]},
  {"do": "run", "key": "peek-at-home", "for": "prd-1",
   "argv": ["cat", "/etc/passwd"]},
  {"do": "run", "key": "plain-suite", "for": "prd-1",
   "argv": ["pytest", "-v"]}
]}
AJ
KEPT="$MDIR/xo/actions-kept-1.json"
$PY "$XORUN" actions --actions "$ACTS" --out "$KEPT" \
  --mission-dir "$MDIR" --cap 12 --worktree "$WT" >"$TMPROOT/actions-r1.txt" 2>&1
JOURNEY="$MDIR/xo/journey.json"
printf '{}\n' >"$JOURNEY"
$PY "$XOJOUR" reach-record --journey "$JOURNEY" --steps "$KEPT" --round 1 \
  >"$TMPROOT/reach-r1.txt" 2>&1

check "1z. the real gate refused two of the three steps and kept one" \
  "grep -q '3 asked, 1 kept' '$TMPROOT/actions-r1.txt'"
check "1z2. …and the refusal record on disk NAMES the step the worker named" \
  "$PY -c \"
import json,sys
d=json.load(open('$KEPT'))
r=d['refused']
sys.exit(0 if len(r)==2 and {x.get('key') for x in r}=={'suite-verbose','peek-at-home'} else 1)\""
check "1z3. …and journey.json carries them with their round, keys and reasons" \
  "$PY -c \"
import json,sys
j=json.load(open('$JOURNEY'))
rs=j.get('refusedSteps') or []
sys.exit(0 if len(rs)==2 and all(x.get('round')=='1' for x in rs)
         and {x.get('key') for x in rs}=={'suite-verbose','peek-at-home'}
         and all(x.get('why') for x in rs) else 1)\""

spawn_n1 r2 LCARS_XO_JOURNEY="$JOURNEY" LCARS_XO_ROUND=2
P_R2="$TMPROOT/prompt-r2.txt"
check "1y. round 2's prompt was captured at all" '[ -s "$P_R2" ]'
check "1a. THE BEHAVIOUR — round 2's prompt NAMES the step round 1 refused" \
  'grep -qF "suite-verbose" "$P_R2" && grep -qF "peek-at-home" "$P_R2"'
check "1b. …and says WHY, in the harness's own refusal words" \
  'grep -qF "a step has no shell" "$P_R2"'
check "1c. …and says which round it was, and that nothing of it ran" \
  'grep -qiF "round 1" "$P_R2" && grep -qiF "did not run" "$P_R2"'
check "1d. …and the step the gate KEPT is not reported as refused" \
  '! grep -qF "plain-suite" "$P_R2"'
check "1e. …and it names what was asked for, not only the verb" \
  'grep -qF "pytest -v | tail -40" "$P_R2"'

# CONTROL 1 — nothing refused, no section at all.
CLEAN="$TMPROOT/journey-clean.json"
printf '%s\n' '{"refusedSteps": []}' >"$CLEAN"
spawn_n1 clean LCARS_XO_JOURNEY="$CLEAN" LCARS_XO_ROUND=2
P_CLEAN="$TMPROOT/prompt-clean.txt"
check "1f. CONTROL — with NO refusals on the record the section is absent entirely" \
  '[ -s "$P_CLEAN" ] && ! grep -qi "the harness refused" "$P_CLEAN"'
check "1g. CONTROL — and the rest of the prompt is unchanged (mission still named)" \
  'grep -q "Mission id: lcars-1" "$P_CLEAN" && grep -q "Mission id: lcars-1" "$P_R2"'

# CONTROL 2 — round 1 itself has no previous round, so nothing is reported even
# though the record holds round 1's refusals.
spawn_n1 r1 LCARS_XO_JOURNEY="$JOURNEY" LCARS_XO_ROUND=1
check "1h. CONTROL — on round 1 there is no previous round, so no section" \
  '! grep -qF "suite-verbose" "$TMPROOT/prompt-r1.txt"'
# CONTROL 3 — no journey exported at all (a hand-run spawn): nothing invented.
spawn_n1 nojourney
check "1i. CONTROL — with no refusal record exported, nothing is claimed" \
  '! grep -qi "the harness refused" "$TMPROOT/prompt-nojourney.txt"'

# AND THE LOOK ITSELF EXPORTS WHAT run.sh READS — otherwise this is a message
# nobody receives, which is the whole defect.
# AND THE LOOK ITSELF EXPORTS WHAT run.sh READS — DRIVEN, not grepped (S264 fix
# round 2, FIX 1). The look's own export region is lifted out of `xo.sh` and
# SOURCED, so what is read back is what the production code computes. The grep
# that used to stand here passed on the mere PRESENCE of the two names anywhere
# in the file, which is why "delivery export removed" cost the fix-round-1
# tester exactly one red check and nothing behavioural.
EXP_J="$(export_val XODIR 7 LCARS_XO_JOURNEY)"
EXP_R="$(export_val XODIR 7 LCARS_XO_ROUND)"
check "1j. the look's own export region really sets the journey path, to its own record" \
  '[ "$EXP_J" = "XODIR/journey.json" ]'
check "1j2. …and really sets the round it is on, to the round it is on" \
  '[ "$EXP_R" = 7 ]'
# AND THE WHOLE CHAIN, with nothing hand-written in between: the environment the
# PRODUCTION region computes is handed to the real spawn, and the refusal comes
# out the other end in the prompt.
WJ="$(export_val "$MDIR/xo" 2 LCARS_XO_JOURNEY)"
WR="$(export_val "$MDIR/xo" 2 LCARS_XO_ROUND)"
spawn_n1 wired LCARS_XO_JOURNEY="$WJ" LCARS_XO_ROUND="$WR"
check "1j3. END TO END — the values the look's own code exports carry the refusal into the prompt" \
  '[ -s "$TMPROOT/prompt-wired.txt" ] &&
   grep -qF "suite-verbose" "$TMPROOT/prompt-wired.txt" &&
   grep -qF "a step has no shell" "$TMPROOT/prompt-wired.txt"'
check "1j4. CONTROL — the same spawn with nothing exported claims nothing" \
  '! grep -qi "the harness refused" "$TMPROOT/prompt-nojourney.txt"'

check "1k. CONTROL — the engine shim IS live (so \"0 calls\" means something)" \
  '[ "$SHIM_PROVED" = 1 ]'
check "1l. ZERO SPEND so far — no engine was invoked" '[ ! -s "$SPEND_LOG" ]'

# ===========================================================================
# 2. NAME THE FENCE — a declared step is a program, not a shell, said where
#    the "you have a real shell" paragraphs are.
# ===========================================================================
echo ""
echo "2. the prompt states the fence beside the shell it grants"

check "2a. THE BEHAVIOUR — the prompt says a DECLARED step is not a shell" \
  'grep -qiF "a declared step is not a shell" "$P_R2"'
check "2b. …and names the shapes the harness refuses, so the fence is actionable" \
  'grep -qF -- "-c" "$P_R2" && grep -qiF "program" "$P_R2"'
check "2c. …and says what to do instead (run it in your own shell, save the output)" \
  'grep -qiF "your own shell" "$P_R2"'
check "2d. CONTROL — the \"you have a real shell\" paragraphs are STILL there" \
  'grep -qF "GO AND LOOK YOURSELF — you have a real shell" "$P_R2" &&
   grep -qF "You have a real shell here, and you are expected to use it." "$P_R2"'
check "2e. CONTROL — and the fence sentence sits in the SAME section as them" \
  "$PY -c \"
import sys
t=open('$P_R2',encoding='utf-8').read()
a=t.find('GO AND LOOK YOURSELF')
b=t.lower().find('a declared step is not a shell')
c=t.find('## The mission')
sys.exit(0 if a>=0 and b>a else 1)\""
check "2f. CONTROL — prompts/evaluate.md and its ceiling are untouched" \
  "[ \"\$(wc -l <'$EVALMD' | tr -d ' ')\" -lt 689 ]"
check "2g. CONTROL — the fence sentence is NOT in evaluate.md (prompt text stays in run.sh)" \
  "! grep -qi 'a declared step is not a shell' '$EVALMD'"

# ===========================================================================
# 3. BELIEVE ITS OWN WORK — a named case in a transcript the reviewer placed
#    settles a named-case criterion. A bare tally still does not.
# ===========================================================================
echo ""
echo "3. tests_settle reads the reviewer's OWN placed suite transcript"

# The MEASURED shape: `testCases: []` and an outputTail of seven dots, beside a
# verbose transcript the reviewer ran and placed itself.
TESTS_J="$TMPROOT/tests.json"
cat >"$TESTS_J" <<'TJ'
{"ran": true, "outcome": "passed", "command": "pytest", "exit": 0,
 "testCases": [], "outputTail": "tests/test_app.py .......\n7 passed\n",
 "truncated": false, "tailCapBytes": 4096}
TJ
VERBOSE="$TMPROOT/10-suite-verbose.txt"
cat >"$VERBOSE" <<'VB'
$ python3 -m pytest -v
tests/test_app.py::test_duplicate_name_is_refused PASSED
tests/test_app.py::test_week_grid_renders PASSED
tests/test_app.py::test_today_command_lists_due PASSED
7 passed in 0.41s
VB

settle() { # <quote> <placed-or-empty> → prints SETTLED / NO<tab>why
  QUOTE="$1" PLACED="$2" TESTS="$TESTS_J" $PY - <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("xoscore", os.environ["SCORE_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tests = json.load(open(os.environ["TESTS"]))
placed = []
if os.environ["PLACED"]:
    placed = [{"name": os.path.basename(os.environ["PLACED"]),
               "text": open(os.environ["PLACED"], encoding="utf-8").read()}]
try:
    okd, why = m.tests_settle(tests, os.environ["QUOTE"], placed)
except TypeError:
    print("NO\ttests_settle does not take a placed transcript at all")
    raise SystemExit(0)
print("SETTLED" if okd else "NO\t%s" % why)
PY
}
export SCORE_PY="$SCORE"

check "3a. THE BEHAVIOUR — a named case in the reviewer's own placed transcript SETTLES" \
  '[ "$(settle "test_duplicate_name_is_refused PASSED" "$VERBOSE")" = SETTLED ]'
check "3b. …and a second named case from the same transcript settles too" \
  '[ "$(settle "test_week_grid_renders PASSED" "$VERBOSE")" = SETTLED ]'
check "3c. CONTROL — a BARE TALLY still settles nothing, placed or not" \
  '[ "$(settle "7 passed" "$VERBOSE" | cut -f1)" = NO ]'
check "3d. CONTROL — a file-level line with a dot run still names no case" \
  '[ "$(settle "tests/test_app.py ......." "$VERBOSE" | cut -f1)" = NO ]'
check "3e. CONTROL — a line in NO transcript at all is still refused" \
  '[ "$(settle "test_nothing_like_this PASSED" "$VERBOSE" | cut -f1)" = NO ]'
check "3f. CONTROL — with no placed transcript the row is demoted exactly as today" \
  '[ "$(settle "test_duplicate_name_is_refused PASSED" "" | cut -f1)" = NO ]'
check "3g. CONTROL — a repo with NO test command is still not settled by a tally" \
  "$PY -c \"
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('x', '$SCORE'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
got = m.tests_settle({'ran': False}, '7 passed',
                     [{'name': 'v.txt', 'text': '7 passed'}])
sys.exit(0 if not got[0] else 1)\""

echo ""
echo "3h-3m. the same thing END TO END, through the real scorer"

# One shots dir holding the transcript the reviewer placed itself, and a ledger
# citing a named case from it. Today this row is demoted and the note overwritten.
e2e() { # <dir> <quote> [--no-placed]
  local d="$1" quote="$2" nop="${3:-}"
  mkdir -p "$d/xo/shots/look-1"
  cp "$TESTS_J" "$d/tests.json"
  # LAID DOWN BY THE PRODUCT'S OWN WRITER, in the look's own directory —
  # transcript AND the sibling readout that records the harness produced it.
  [ "$nop" = "--no-placed" ] ||
    place_step "$d/xo/shots/look-1" 10-suite-verbose suite-verbose "$(cat "$VERBOSE")"
  printf '%s\n' '{"criteria": [{"id": "prd-1", "text": "duplicate names are refused",
    "impact": "high"}]}' >"$d/xo/criteria.json"
  QUOTE="$quote" $PY - "$d/verdict.json" <<'PY'
import json, os, sys
json.dump({"score": "high", "summary": "s",
           "criteria": [{"id": "prd-1", "status": "met", "evidence": "tests",
                         "testQuote": os.environ["QUOTE"],
                         "note": "the reviewer's own note, which must survive"}],
           "gaps": []}, open(sys.argv[1], "w"), indent=1)
PY
  # THROUGH THE LOOK'S OWN CALL SITE (S264 fix round 2, FIX 1) — the 17
  # arguments are the production ones, not seventeen written out here.
  run_prod_scorer "$d" look-1
}
status_of() { $PY -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d.get('criteria') or [] if x.get('id')=='prd-1']
print((c[0].get('status') if c else 'MISSING'))" "$1"; }
note_of() { $PY -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d.get('criteria') or [] if x.get('id')=='prd-1']
print((c[0].get('note') if c else ''))" "$1"; }

E_GOOD="$TMPROOT/e2e-good"; e2e "$E_GOOD" "test_duplicate_name_is_refused PASSED"
E_TALLY="$TMPROOT/e2e-tally"; e2e "$E_TALLY" "7 passed"
E_NONE="$TMPROOT/e2e-none"; e2e "$E_NONE" "test_duplicate_name_is_refused PASSED" --no-placed

check "3h. the scorer ran in all three cases" \
  '[ -s "$E_GOOD/out.json" ] && [ -s "$E_TALLY/out.json" ] && [ -s "$E_NONE/out.json" ]'
check "3i. THE BEHAVIOUR — the row cited to the placed transcript STANDS as met" \
  '[ "$(status_of "$E_GOOD/out.json")" = met ]'
check "3j. …and the reviewer's own note is NOT overwritten by a machine sentence" \
  '[ "$(note_of "$E_GOOD/out.json")" = "the reviewer'"'"'s own note, which must survive" ]'
check "3j2. …and the captain is TOLD which placed file the row stands on" \
  "$PY -c \"
import json,sys
d=json.load(open('$E_GOOD/out.json'))
n=' '.join(d.get('ledgerNotes') or [])
sys.exit(0 if '10-suite-verbose.txt' in n else 1)\""
check "3k. CONTROL — a bare tally is still demoted to untested" \
  '[ "$(status_of "$E_TALLY/out.json")" = untested ]'
check "3l. CONTROL — with the transcript absent the row is demoted exactly as today" \
  '[ "$(status_of "$E_NONE/out.json")" = untested ]'
check "3m. …and that demotion still says why, in the captain's words" \
  "$PY -c \"
import sys
n='''$(note_of "$E_NONE/out.json")'''
sys.exit(0 if n.strip() else 1)\""

# ===========================================================================
# 4. THE RETAKE — a look that ended for an INFRASTRUCTURE reason can be taken
#    again; one that reached a real verdict still cannot.
# ===========================================================================
echo ""
echo "4. the retake, after an infra-only outcome only"

# A stub `xo.sh` that records its argv. The driver must call the EXISTING
# `evaluate --again --because` verb — never a second recheck path.
XOSTUB="$TMPROOT/xo-stub.sh"
cat >"$XOSTUB" <<'XS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$XO_STUB_LOG"
exit 0
XS
chmod +x "$XOSTUB"

retake() { # <tag> <numberOne-json>
  local tag="$1" blk="$2"
  local d="$TMPROOT/rt-$tag"
  rm -rf "$d"; cp -R "$repo" "$d" 2>/dev/null
  local md="$d/.git/lcars/missions/lcars-1"
  BLK="$blk" $PY - "$md/state.json" <<'PY'
import json, os, sys
s = json.load(open(sys.argv[1]))
s["numberOne"] = json.loads(os.environ["BLK"])
json.dump(s, open(sys.argv[1], "w"), indent=2)
PY
  rm -f "$TMPROOT/stub-$tag.log"; : >"$TMPROOT/stub-$tag.log"
  ( cd "$d" && env XO_STUB_LOG="$TMPROOT/stub-$tag.log" \
      LCARS_XO_SCRIPT="$XOSTUB" LCARS_GH_BIN=/usr/bin/true \
      bash "$RUNSH" number-one-verify-test --mission lcars-1 ) \
    >"$TMPROOT/rt-$tag.out" 2>&1
  # THE SPAWN IS DETACHED BY DESIGN (the captain never loses his terminal to a
  # look), so the stub's argv lands a moment after the hook returns. Waited for
  # ONLY where a spawn was expected — a refusal is asserted on an EMPTY log and
  # a wait there would just be a wait.
  if grep -q "NVRC=0" "$TMPROOT/rt-$tag.out" 2>/dev/null; then
    local i=0
    while [ "$i" -lt 60 ] && [ ! -s "$TMPROOT/stub-$tag.log" ]; do
      sleep 0.1; i=$((i + 1))
    done
  fi
}

NOLOOK="I never got to look at your build, so nothing on your list is vouched for either way"
retake infra "{\"status\":\"engaged\",\"score\":\"low\",\"evaluatedAt\":\"2026-10-09T01:00:00Z\",\"meaning\":\"$NOLOOK\",\"headline\":\"your build did not start — nothing came up\",\"lookBlockedBy\":\"your build did not start — nothing came up\"}"
retake real  '{"status":"engaged","score":"medium","evaluatedAt":"2026-10-09T01:00:00Z","meaning":"the primary flow works","headline":"most of it works"}'
retake fresh '{"status":"engaged"}'

check "4z. the test hook ran in all three cases" \
  'grep -q NVRC "$TMPROOT/rt-infra.out" && grep -q NVRC "$TMPROOT/rt-real.out" &&
   grep -q NVRC "$TMPROOT/rt-fresh.out"'
check "4a. THE BEHAVIOUR — after an infra-only look the retake RUNS" \
  'grep -q "NVRC=0" "$TMPROOT/rt-infra.out"'
check "4b. …through the EXISTING verb, with --again and a --because off the record" \
  'grep -q -- "--again" "$TMPROOT/stub-infra.log" &&
   grep -q -- "--because" "$TMPROOT/stub-infra.log" &&
   grep -qF "your build did not start" "$TMPROOT/stub-infra.log"'
check "4c. CONTROL — after a REAL verdict the retake is refused, exactly as today" \
  'grep -q "NVRC=1" "$TMPROOT/rt-real.out" && [ ! -s "$TMPROOT/stub-real.log" ]'
check "4d. CONTROL — a never-looked mission still takes the ordinary first look" \
  'grep -q "NVRC=0" "$TMPROOT/rt-fresh.out" &&
   grep -q "evaluate" "$TMPROOT/stub-fresh.log" &&
   ! grep -q -- "--again" "$TMPROOT/stub-fresh.log"'
# NOT A LOOP. A blocked look that is retaken and blocks AGAIN is not retaken a
# second time by the driver — the captain's own `--again` stays his.
retake twice "{\"status\":\"engaged\",\"score\":\"low\",\"evaluatedAt\":\"2026-10-09T01:00:00Z\",\"meaning\":\"$NOLOOK\",\"lookBlockedBy\":\"your build did not start\",\"retakenAt\":\"2026-10-09T02:00:00Z\"}"
check "4e. CONTROL — a retake already taken is not taken again (no loop)" \
  'grep -q "NVRC=1" "$TMPROOT/rt-twice.out" && [ ! -s "$TMPROOT/stub-twice.log" ]'
# NOT A LOOP — DRIVEN, three passes of the real gate over ONE mission (S264 fix
# round 2, FIX 1). The source-order regex that used to stand here went red for
# the fix-round-1 tester's "retake stamp removed" mutation NOT AT ALL: it
# counted ZERO red checks while the real gate span up 3 model looks where the
# baseline gives 1. `4e` seeded `retakenAt` by hand, so it never asked whether
# the gate writes one.
retake_pass() { # <tag> — run the real hook AGAIN in the same copy
  ( cd "$TMPROOT/rt-$1" && env XO_STUB_LOG="$TMPROOT/stub-$1.log" \
      LCARS_XO_SCRIPT="$XOSTUB" LCARS_GH_BIN=/usr/bin/true \
      bash "$RUNSH" number-one-verify-test --mission lcars-1 ) \
    >>"$TMPROOT/rt-$1.out" 2>&1
  local i=0
  while [ "$i" -lt 40 ]; do sleep 0.1; i=$((i + 1)); done
}
retake_pass infra
retake_pass infra
SPAWNS_INFRA="$(grep -c . "$TMPROOT/stub-infra.log" 2>/dev/null | tr -d ' ')"
check "4f. THREE passes of the real gate over one blocked look spawn exactly ONE retake" \
  '[ "$SPAWNS_INFRA" = 1 ]'
check "4f2. …and the gate wrote the stamp that makes it one (nothing seeded it)" \
  "$PY -c \"
import json,sys
d=json.load(open('$TMPROOT/rt-infra/.git/lcars/missions/lcars-1/state.json'))
sys.exit(0 if (d.get('numberOne') or {}).get('retakenAt') else 1)\""
# CONTROL — a never-looked mission has nothing to stamp and SHOULD take a look
# on every pass, so "exactly one" above is a property of the stamp and not of
# this rig being unable to spawn twice.
retake_pass fresh
check "4f3. CONTROL — an unlooked mission is not stamped, and looks on each pass" \
  '[ "$(grep -c . "$TMPROOT/stub-fresh.log" 2>/dev/null | tr -d " ")" = 2 ]'
# THE EEH, AND PROOF GIT IS REALLY ANSWERING (S264 fix round 2, FIX 7;
# control replaced S265 fix round 1). The check was once
# `[ -z "$(… git diff … lcars-eeh)" ]`, which is TRUE when git fails, is
# missing, or is run outside a repo — so it needed a control proving git spoke.
# S264's control was "`skills/lcars-xo` is dirty", which was true only while
# THAT session had uncommitted work there: on a clean tree, or any later
# session that does not happen to edit `skills/lcars-xo`, 4g went red for no
# reason, and a guard that fires on correct behaviour teaches you to ignore it.
# The control is now a property of ANY clone of this repo rather than of one
# session's working tree: git must SUCCEED (exit status checked, never
# discarded) and must report a NON-EMPTY list of tracked files under
# `skills/lcars-eeh`. That is true in every clone and false whenever git is
# broken, absent, or run outside a repo — and it is positive evidence about
# the very path the clean-half asserts on.
eeh_clean_and_git_answered() {
  local tracked eeh_diff
  # (1) git answered: it exited 0 AND named the EEH's tracked files.
  tracked="$(cd "$REPO_ROOT" && git ls-files -- skills/lcars-eeh)" || return 1
  [ -n "$tracked" ] || return 1
  # (2) the EEH is clean: the diff exited 0 (so silence is an answer, not a
  #     swallowed failure) and was empty.
  eeh_diff="$(cd "$REPO_ROOT" && git diff --name-only HEAD -- skills/lcars-eeh)" || return 1
  [ -z "$eeh_diff" ]
}
check "4g. the EEH was NOT edited — and git really answered (control: git lists the EEH's tracked files)" \
  'eeh_clean_and_git_answered'

# ===========================================================================
# 5. THE INVARIANT — the argv fence did not move, and the mutation fires
# ===========================================================================
echo ""
echo "5. the fence stayed closed, and removing the telling turns section 1 red"

check "5a. argv_refusal is byte-identical to the measured baseline" \
  "[ \"\$($PY -c \"
import re,hashlib
s=open('$XORUN',encoding='utf-8').read()
m=re.search(r'^def argv_refusal\\(.*?(?=^def |^class |\\Z)', s, re.M|re.S).group(0)
print(hashlib.md5(m.encode()).hexdigest())\")\" = 82278f1b3bf34f8b6a667b493b0cfbcc ]"
check "5b. the fence still refuses a shell, a -c interpreter and an absolute path" \
  "$PY -c \"
import importlib.util, sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
bad=[['bash','-c','x'],['sh','-c','x'],['python3','-c','x'],['env','bash','x'],['cat','/etc/passwd']]
good=[['pytest','-v'],['bash','run-tests.sh']]
sys.exit(0 if all(m.argv_refusal(a) for a in bad) and not any(m.argv_refusal(a) for a in good) else 1)\""

# MUTATION — take the refusal rendering out of a COPY of run.sh and watch
# section 1's behaviour go red. Without this, 1a could be passing vacuously.
MUT="$TMPROOT/mut-run/run.sh"
cp -R "$REPO_ROOT/skills/lcars-run" "$TMPROOT/mut-run" >/dev/null 2>&1
$PY - "$MUT" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
n = t.count("$refused_line\n")
t = t.replace("$refused_line\n", "", 1)
open(p, "w", encoding="utf-8").write(t)
sys.exit(0 if n else 3)
PY
MUTRC=$?
check "5c. the mutation found the one line that delivers the refusals" '[ "$MUTRC" = 0 ]'
( cd "$repo" && env \
  XO_PROMPT_DUMP="$TMPROOT/prompt-mut.txt" \
  LCARS_WORKER_ADAPTER="$DUMP" LCARS_WORKER_BIN="$WORKER" \
  LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
  LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
  LCARS_XO_WORKTREE="$WT" LCARS_XO_THROWAWAY_HOME="$THOME" \
  LCARS_XO_SHOTS_DIR="$SHOTS" \
  LCARS_XO_PROMPTS="$REPO_ROOT/skills/lcars-xo/prompts" \
  LCARS_STATE_LIB="$REPO_ROOT/skills/lcars-init/lcars-state.sh" \
  LCARS_XO_JOURNEY="$JOURNEY" LCARS_XO_ROUND=2 \
  bash "$MUT" spawn-number-one --mission lcars-1 \
    --mode evaluate --outdir "$TMPROOT/out-mut" ) >"$TMPROOT/log-mut.txt" 2>&1
check "5d. MUTATION — with the delivery removed the refusal does NOT reach the prompt" \
  '[ -s "$TMPROOT/prompt-mut.txt" ] && ! grep -qF "suite-verbose" "$TMPROOT/prompt-mut.txt"'
check "5e. …and the prompt is otherwise intact, so 5d is about the one line" \
  'grep -q "Mission id: lcars-1" "$TMPROOT/prompt-mut.txt"'

# MUTATION — take the placed-transcript read out of a COPY of xo-score.py.
SMUT="$TMPROOT/xo-score-mut.py"
cp "$SCORE" "$SMUT"
$PY - "$SMUT" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
import re
m = re.search(r"^def placed_transcripts\(.*\):$", t, re.M)
if not m:
    sys.exit(3)
t = t[:m.end()] + "\n    return []  # MUTATED" + t[m.end():]
open(p, "w", encoding="utf-8").write(t)
PY
SMUTRC=$?
check "5f. the mutation found the placed-transcript reader" '[ "$SMUTRC" = 0 ]'
D="$TMPROOT/e2e-mut"; mkdir -p "$D/shots/look-1"
cp "$TESTS_J" "$D/tests.json"
place_step "$D/shots/look-1" 10-suite-verbose suite-verbose "$(cat "$VERBOSE")"
printf '%s\n' '{"criteria": [{"id": "prd-1", "text": "duplicate names are refused",
  "impact": "high"}]}' >"$D/criteria.json"
QUOTE="test_duplicate_name_is_refused PASSED" $PY - "$D/verdict.json" <<'PY'
import json, os, sys
json.dump({"score": "high", "summary": "s",
           "criteria": [{"id": "prd-1", "status": "met", "evidence": "tests",
                         "testQuote": os.environ["QUOTE"], "note": "mine"}],
           "gaps": []}, open(sys.argv[1], "w"), indent=1)
PY
$PY "$CAGE" 240 $PY "$SMUT" "$D/verdict.json" "$D/criteria.json" "$D/out.json" \
  "" "$D/tests.json" "" "" "" "" "" "" "" "" "$D/shots" "" "" "$D/shots/look-1" \
  >"$D/wire.txt" 2>"$D/err.txt"
check "5g. MUTATION — with the reader gone the row is demoted again" \
  '[ -s "$D/out.json" ] && [ "$(status_of "$D/out.json")" = untested ]'

check "5h. ZERO SPEND — neither engine was ever invoked" '[ ! -s "$SPEND_LOG" ]'
check "5i. …and not one call carried a --model (nothing was billable)" \
  '[ "$(grep -F -- "--model" "$SPEND_LOG" 2>/dev/null | wc -l | tr -d " ")" = 0 ]'

# ===========================================================================
# 6. FIX ROUND 1 / FIX 1 — THE HAYSTACK IS THIS LOOK'S OWN RECORD, AND ONLY
#    WHAT THE HARNESS RECORDED PRODUCING.
#
# TWO MEASURED DEFECTS in the round-0 widening, both confirmed in source and
# then driven on the live record:
#
#   (a) IT READ EVERY LOOK'S EVIDENCE. `xo.sh` handed the scorer `$xodir/shots`
#       — the ROOT of every look, which the landing rail needs — and
#       `placed_transcripts` walked it recursively. On the live record that
#       admitted 42 files, 37 of them from `look-1`, the SUPERSEDED look, and 5
#       from the current `look-2`: 88% of the test-evidence haystack was a
#       previous look's leftovers. The dangerous sequence is file-logs → fix →
#       recheck, where a PRE-FIX transcript settles a POST-FIX row. `SKILL.md`
#       already records this exact class as fixed once before.
#
#   (b) IT ADMITTED TEXT THE REVIEWER MERELY TYPED. Any `.txt`/`.log`/`.out`
#       not starting with `REFUSED: ` was admitted. The prompt tells the
#       reviewer to run things in its own shell and save output to this
#       directory, the directory is 0755 and the worker has `bash` — so a
#       one-line file with no run behind it settled a row. "Nothing is read out
#       of a model's prose" was not true: a file the model wrote with its own
#       shell IS model prose, in a file instead of a JSON field.
#
# THE CURE IS THE PROVENANCE THE PRODUCER ALREADY RECORDS. `write_evidence`
# writes BOTH halves of a harness step: `<stem>.txt` and a sibling `<stem>.json`
# readout naming its `do`/`key`/`met` and its own `evidence` file. A
# reviewer-authored file has no such readout, and a per-PNG caption's sibling
# (`xo-drive.js`) is a SHOT readout — `shot`/`landed`/`pixels`, no `do`. So the
# rule is "the harness recorded producing this file", never "the text looks like
# test output": judged by RECORD, not by reading meaning out of prose, which is
# the infer-vs-record failure that burned S147, S156 and S188.
# ===========================================================================
echo ""
echo "6. the placed-transcript haystack is scoped, and demands recorded provenance"

PLACE="$TMPROOT/place"
mkdir -p "$PLACE/look-1" "$PLACE/look-2"

PREV_CASE="test_from_the_previous_look PASSED"
CUR_CASE="test_duplicate_name_is_refused PASSED"
place_step "$PLACE/look-1" 10-suite-verbose prev-suite \
  "\$ pytest -v
tests/test_app.py::$PREV_CASE
7 passed in 0.4s"
place_step "$PLACE/look-2" 10-suite-verbose suite-verbose \
  "\$ pytest -v
tests/test_app.py::$CUR_CASE
7 passed in 0.4s"
# A FILE THE REVIEWER TYPED. No run behind it, no readout beside it, and a
# quote naming a case — the exact probe that settled a row before this fix.
printf 'tests/test_app.py::test_typed_by_hand_with_no_run PASSED\n' \
  >"$PLACE/look-2/by-hand.txt"
# …AND ITS TWIN: the same one-line shape, in the same directory, naming a case
# the same way — differing ONLY in that the harness RECORDED producing this one.
# (Not the same case NAME: the recorded twin would then settle the typed one's
# quote and 6c could never fail.)
place_step "$PLACE/look-2" 11-recorded typed-but-recorded \
  "tests/test_app.py::test_typed_text_but_recorded_run PASSED"
place_caption "$PLACE/look-2" n1-03 \
  "n1-03 — full page of http://x/ (1200x800 px at 2x), 42 distinct colours, PAINTED, note test_caption_only_case PASSED"
place_step "$PLACE/look-2" 09-refused shell-step \
  "REFUSED: its argv asks for a shell — a step has no shell

The command was NOT run.
tests/test_app.py::test_inside_a_refused_step PASSED"

settle_scoped() { # <look-dir> <quote> → SETTLED<tab>by | NO<tab>why
  LOOK="$1" QUOTE="$2" TESTS="$TESTS_J" $PY - <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("xs", os.environ["SCORE_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tests = json.load(open(os.environ["TESTS"]))
try:
    placed = m.placed_transcripts(os.environ["LOOK"])
except TypeError as e:
    print("NO\tplaced_transcripts signature: %s" % e); raise SystemExit(0)
by = []
okd, why = m.tests_settle(tests, os.environ["QUOTE"], placed, by)
print("SETTLED\t%s" % (by[0] if by else "?") if okd else "NO\t%s" % why)
PY
}

check "6a. THE BEHAVIOUR — a PREVIOUS look's transcript does NOT settle this look's row" \
  '[ "$(settle_scoped "$PLACE/look-2" "$PREV_CASE" | cut -f1)" = NO ]'
check "6b. CONTROL — the very same transcript DOES settle the look it belongs to" \
  '[ "$(settle_scoped "$PLACE/look-1" "$PREV_CASE" | cut -f1)" = SETTLED ]'
check "6c. THE BEHAVIOUR — a file the reviewer TYPED, with no recorded run, settles nothing" \
  '[ "$(settle_scoped "$PLACE/look-2" "test_typed_by_hand_with_no_run PASSED" | cut -f1)" = NO ]'
check "6d. CONTROL — its twin, identical but RECORDED by the harness, settles" \
  '[ "$(settle_scoped "$PLACE/look-2" "test_typed_text_but_recorded_run PASSED" | cut -f2)" = 11-recorded.txt ]'
check "6e. a per-PNG CAPTION is not test output, whatever it quotes" \
  '[ "$(settle_scoped "$PLACE/look-2" "test_caption_only_case PASSED" | cut -f1)" = NO ]'
check "6f. CONTROL (unchanged) — a REFUSED step's evidence still settles nothing" \
  '[ "$(settle_scoped "$PLACE/look-2" "test_inside_a_refused_step PASSED" | cut -f1)" = NO ]'
check "6g. CONTROL (unchanged) — this look's own recorded step still settles" \
  '[ "$(settle_scoped "$PLACE/look-2" "$CUR_CASE" | cut -f2)" = 10-suite-verbose.txt ]'
# AND THE READER IS TOLD WHICH FILE. Disclosed trust, not silent trust.
check "6h. the name of the file that settled it is handed back to the caller" \
  '[ -n "$(settle_scoped "$PLACE/look-2" "$CUR_CASE" | cut -f2)" ]'

# THE SCOPE NOTE FROM THE BRIEF, kept green: with `testCases` NON-EMPTY the
# named-case rule still rejects a case that exists only in a placed transcript.
check "6i. CONTROL — with recorded testCases, a case only in a transcript is NOT_NAMED" \
  "$PY -c \"
import importlib.util, sys
spec=importlib.util.spec_from_file_location('xs','$SCORE'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tests={'ran':True,'outcome':'passed','command':'pytest','exit':0,
       'testCases':['test_only_recorded_case'],
       'outputTail':'test_only_recorded_case PASSED\\n1 passed\\n'}
placed=m.placed_transcripts('$PLACE/look-2')
got=m.tests_settle(tests,'$CUR_CASE',placed)
sys.exit(0 if not got[0] else 1)\""

# AND THE WALK ITSELF: handed the look's own directory it reads that look only.
check "6j. placed_transcripts reads the directory it is given and no sibling look" \
  "$PY -c \"
import importlib.util, sys
spec=importlib.util.spec_from_file_location('xs','$SCORE'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
two={d['name'] for d in m.placed_transcripts('$PLACE/look-2')}
one={d['name'] for d in m.placed_transcripts('$PLACE/look-1')}
sys.exit(0 if '10-suite-verbose.txt' in one and 'by-hand.txt' not in two
         and 'n1-03.txt' not in two and '09-refused.txt' not in two else 1)\""
# ── 6k — AND THE LOOK'S OWN DIRECTORY IS WHAT THE LOOK REALLY HANDS IT ──────
#
# DRIVEN, POSITIONALLY (S264 fix round 2, FIX 1). What used to stand here was a
# grep for `$shots` somewhere in a 1400-character window of the call site. The
# fix-round-1 tester reverted the 17th argument to `$xodir/shots` — the root of
# every look, the EXACT bug round 1 cured — and this was the ONLY check that
# went red; satisfying the grep elsewhere in the window took the suite to
# 100/100 GREEN WITH THE BUG BACK IN.
#
# So the real call site is lifted out of `xo.sh` verbatim, sourced with sentinel
# values, and the argv it builds is read back ARGUMENT BY ARGUMENT from a
# recorder standing in for python3. `$shots` (the look) and `$xodir/shots` (the
# root) are DIFFERENT sentinels, so the two cannot be confused, and the POSITION
# is asserted rather than the presence of a name.
A_REPORT="$(scorer_argv report)"
check "6k0. the real call site was lifted and really ran (an argv was recorded)" \
  '[ -n "$A_REPORT" ] &&
   [ "$(printf "%s\n" "$A_REPORT" | sed -n 1p)" = "SKILLDIR/xo-score.py" ]'
check "6k. the 17th argument the LOOK passes is THIS look's own directory, not the root" \
  '[ "$(nth_arg report 17)" = LOOKDIR ]'
check "6k2. …and the 14th is still the ROOT of every look, which the landing rail needs" \
  '[ "$(nth_arg report 14)" = "XODIR/shots" ]'
check "6k3. …and the look passes all 17, so nothing downstream silently defaults" \
  '[ "$(n_args report)" = 17 ]'
check "6k4. CONTROL — the two scopes are distinct values, so 6k can fail" \
  '[ "$(nth_arg report 17)" != "$(nth_arg report 14)" ]'
check "6k5. and the SCORER reads its 17th argument as the look's own directory" \
  "$PY -c \"
import re,sys
t=open('$SCORE',encoding='utf-8').read()
m=re.search(r'look_dir = sys\.argv\[(\d+)\]', t)
sys.exit(0 if m and m.group(1)=='17' else 1)\""

echo ""
echo "6l-6p. the same thing END TO END, with a previous look sitting right there"

e2e_looks() { # <dir> <quote> <where: look-1|look-2>
  local d="$1" quote="$2" where="$3"
  mkdir -p "$d/xo/shots/look-1" "$d/xo/shots/look-2"
  cp "$TESTS_J" "$d/tests.json"
  place_step "$d/xo/shots/$where" 10-suite-verbose suite-verbose \
    "\$ pytest -v
tests/test_app.py::$CUR_CASE
7 passed in 0.4s"
  printf '%s\n' '{"criteria": [{"id": "prd-1", "text": "duplicate names are refused",
    "impact": "high"}]}' >"$d/xo/criteria.json"
  QUOTE="$quote" $PY - "$d/verdict.json" <<'PY'
import json, os, sys
json.dump({"score": "high", "summary": "s",
           "criteria": [{"id": "prd-1", "status": "met", "evidence": "tests",
                         "testQuote": os.environ["QUOTE"],
                         "note": "the reviewer's own note, which must survive"}],
           "gaps": []}, open(sys.argv[1], "w"), indent=1)
PY
  # THE WHOLE POINT OF THIS SECTION, NOW WIRED THROUGH THE PRODUCT (S264 fix
  # round 2, FIX 1). `look-2` is the current look and `look-1` is sitting right
  # there beside it; which of the two the scorer is handed is decided by
  # `xo.sh`'s own call site, lifted verbatim — not by this test. Revert the
  # 17th argument to the root of every look and 6m goes red on BEHAVIOUR.
  run_prod_scorer "$d" look-2
}
L_STALE="$TMPROOT/e2e-stale"; e2e_looks "$L_STALE" "$CUR_CASE" look-1
L_CUR="$TMPROOT/e2e-cur";     e2e_looks "$L_CUR"   "$CUR_CASE" look-2

check "6l. the scorer ran in both cases" \
  '[ -s "$L_STALE/out.json" ] && [ -s "$L_CUR/out.json" ]'
check "6m. THE BEHAVIOUR — the row cited to a PREVIOUS look's transcript is demoted" \
  '[ "$(status_of "$L_STALE/out.json")" = untested ]'
check "6n. CONTROL — the identical transcript under THIS look settles the row" \
  '[ "$(status_of "$L_CUR/out.json")" = met ]'
check "6o. …and the captain is TOLD which file the row stands on" \
  "$PY -c \"
import json,sys
d=json.load(open('$L_CUR/out.json'))
n=' '.join(d.get('ledgerNotes') or [])
sys.exit(0 if '10-suite-verbose.txt' in n else 1)\""
check "6p. …and the reviewer's own note still survives on that row" \
  '[ "$(note_of "$L_CUR/out.json")" = "the reviewer'"'"'s own note, which must survive" ]'

# ===========================================================================
# 7. FIX 2 — THE STEP IS NAMED, with whatever the worker used to label it.
#
# MEASURED on the one live look: the refusal section said "an unnamed run step"
# FOUR TIMES. `refusal_row` copied `key`/`for`/`fromChecklist`, but the real
# worker labels its steps with `evidence` (`seed-01-add-exercise.txt`) — the
# same field `cmd_run` derives each transcript's name from — and that was not
# carried. The headline promise ("the step you called `suite-verbose` did not
# run") could not be kept on the only live look there was.
# ===========================================================================
echo ""
echo "7. the refusal section names the step the way the worker labelled it"

ACTS7="$TMPROOT/xo-actions-r7.json"
cat >"$ACTS7" <<'AJ'
{"actions": [
  {"do": "run", "evidence": "seed-01-add-exercise.txt", "for": "prd-2",
   "argv": ["bash", "-c", "./app add one && ./app list"]},
  {"do": "run", "argv": ["sh", "-c", "true"]}
]}
AJ
KEPT7="$MDIR/xo/actions-kept-7.json"
$PY "$XORUN" actions --actions "$ACTS7" --out "$KEPT7" \
  --mission-dir "$MDIR" --cap 12 --worktree "$WT" >"$TMPROOT/actions-r7.txt" 2>&1
J7="$TMPROOT/journey-7.json"; printf '{}\n' >"$J7"
$PY "$XOJOUR" reach-record --journey "$J7" --steps "$KEPT7" --round 7 \
  >"$TMPROOT/reach-r7.txt" 2>&1
check "7z. the real gate refused both, and recorded the worker's own label" \
  "$PY -c \"
import json,sys
r=json.load(open('$KEPT7'))['refused']
sys.exit(0 if len(r)==2 and any(x.get('evidence')=='seed-01-add-exercise.txt' for x in r) else 1)\""
check "7y. …and that label reached journey.json" \
  "grep -q 'seed-01-add-exercise.txt' '$J7'"
spawn_n1 r8 LCARS_XO_JOURNEY="$J7" LCARS_XO_ROUND=8
P_R8="$TMPROOT/prompt-r8.txt"
check "7a. THE BEHAVIOUR — the prompt NAMES the step by the worker's own label" \
  'grep -qF "seed-01-add-exercise.txt" "$P_R8"'
check "7b. …and says what that step was for, so it knows which check is still open" \
  'grep -qF "prd-2" "$P_R8"'
check "7c. CONTROL — a step the worker labelled with nothing still reads as unnamed" \
  'grep -qF "an unnamed" "$P_R8"'
check "7d. CONTROL — exactly ONE of the two is unnamed (the labelled one is named)" \
  '[ "$(grep -cF "an unnamed" "$P_R8")" = 1 ]'

# ===========================================================================
# 8. FIX 3 — A STEP DROPPED AT THE CAP IS A STEP THE HARNESS REFUSED TO RUN,
#    and it is now reported as what it is.
#
# DRIVEN LIVE: 14 asked, 12 kept, 2 SILENTLY DROPPED, `refusedSteps` = 0.
# `cmd_actions` put the overflow in `doc["overflow"]` — a COUNT, not rows — so
# it reached no prompt and no report. A drop and a refusal are different facts
# and the reviewer must act differently on them: a refused step needs a
# different SHAPE, a dropped one needs a shorter LIST.
# ===========================================================================
echo ""
echo "8. a step dropped for the cap reaches the reviewer, as a drop"

ACTS8="$TMPROOT/xo-actions-r8.json"
$PY - "$ACTS8" <<'PY'
import json, sys
json.dump({"actions": [{"do": "run", "key": "step-%02d" % i, "for": "prd-1",
                        "argv": ["pytest", "-v"]} for i in range(1, 15)]},
          open(sys.argv[1], "w"), indent=1)
PY
KEPT8="$MDIR/xo/actions-kept-8.json"
$PY "$XORUN" actions --actions "$ACTS8" --out "$KEPT8" \
  --mission-dir "$MDIR" --cap 12 --worktree "$WT" >"$TMPROOT/actions-r8.txt" 2>&1
check "8z. the real gate kept 12 of 14 and refused none on shape" \
  "grep -q '14 asked, 12 kept' '$TMPROOT/actions-r8.txt' &&
   $PY -c \"
import json,sys
d=json.load(open('$KEPT8'))
sys.exit(0 if d['overflow']==2 and not d['refused'] else 1)\""
check "8a. THE BEHAVIOUR — the two dropped steps are recorded as ROWS, by name" \
  "$PY -c \"
import json,sys
d=json.load(open('$KEPT8'))
rows=d.get('dropped') or []
sys.exit(0 if len(rows)==2 and {r.get('key') for r in rows}=={'step-13','step-14'}
         and all(r.get('why') for r in rows) else 1)\""
J8="$TMPROOT/journey-8.json"; printf '{}\n' >"$J8"
$PY "$XOJOUR" reach-record --journey "$J8" --steps "$KEPT8" --round 9 \
  >"$TMPROOT/reach-r8.txt" 2>&1
check "8b. …and they reach the one record the next round's prompt reads" \
  "$PY -c \"
import json,sys
j=json.load(open('$J8'))
rows=j.get('droppedSteps') or []
sys.exit(0 if len(rows)==2 and all(r.get('round')=='9' for r in rows) else 1)\""
check "8c. CONTROL — a DROP is not filed as a refusal (different facts, kept apart)" \
  "$PY -c \"
import json,sys
j=json.load(open('$J8'))
sys.exit(0 if not (j.get('refusedSteps') or []) else 1)\""
spawn_n1 r10 LCARS_XO_JOURNEY="$J8" LCARS_XO_ROUND=10
P_R10="$TMPROOT/prompt-r10.txt"
check "8d. THE BEHAVIOUR — the prompt names the dropped steps" \
  'grep -qF "step-13" "$P_R10" && grep -qF "step-14" "$P_R10"'
check "8e. …and says plainly it was the CAP, not the step's shape" \
  'grep -qiF "cap" "$P_R10" && grep -qiF "dropped" "$P_R10"'
check "8f. …and does not call them refused, which would send it rewriting a fine step" \
  '! grep -qiF "the harness refused" "$P_R10"'
check "8g. CONTROL — a round that fitted under the cap reports no drop at all" \
  '! grep -qi "dropped for the cap" "$P_CLEAN"'

# ===========================================================================
# 9. FIX 4 — THE RETAKE MISSES THE HARNESS'S OWN CRASH, and now does not.
#
# MEASURED IN SOURCE: `xo_finish` stamped `lookBlockedBy` only on the two
# `$XO_NOLOOK` arms. A look that ends "my own scorer failed (exit N)" or "I
# could not read back my own verdict" stamped `evaluatedAt` + LOW with NO
# `lookBlockedBy`, so the driver never retook it — and that is purely our own
# code failing, squarely the class change 4 exists for. (Those two sentences are
# the previous session's own honesty fix, so this is its natural partner.)
#
# DRIVEN, not asserted at source level: `xo.sh` dispatches on load, so the half
# above its dispatch is sourced into a shell and `xo_finish` is CALLED.
# ===========================================================================
echo ""
echo "9. a look our own code ended is marked retakeable, by the code that knows"

XOLIB="$TMPROOT/xo-lib.sh"
sed '/^case "${1:-status}" in/,$d' "$XOSH" >"$XOLIB"
LREPO="$TMPROOT/lrepo"; mkdir -p "$LREPO"
( cd "$LREPO" && git init -q -b main && git config user.email t@t &&
  git config user.name t ) >/dev/null 2>&1
LMD="$LREPO/.git/lcars/missions/lcars-1"; mkdir -p "$LMD/xo"
printf '{\n  "cloneId": "a"\n}\n' >"$LREPO/.git/lcars/config.json"
fresh_state() { printf '{\n  "id": "lcars-1",\n  "stage": "verify"\n}\n' >"$LMD/state.json"; }
# ONE DOOR: every case below calls the REAL `xo_finish` with the REAL arguments
# its caller passes, and reads back the record it wrote.
fin() { # <baton> <meaning> → prints lookBlockedBy, or EMPTY
  fresh_state
  ( cd "$LREPO" && env BATON="$1" MEANING="$2" \
    LCARS_COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh" \
    LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
    bash -c '
      source "'"$XOLIB"'" || exit 9
      XO_LOOK_BLOCKED="${BATON:-}"
      xo_finish ".git/lcars/missions/lcars-1" low engaged "w" "h" "$MEANING" \
        >/dev/null 2>&1
      '"$PY"' -c "
import json,sys
d=json.load(open(\".git/lcars/missions/lcars-1/state.json\")).get(\"numberOne\") or {}
print(d.get(\"lookBlockedBy\") or \"EMPTY\")"' )
}
NOLOOK_FIN="$(fin "" "$NOLOOK")"
CRASH_FIN="$(fin "my own scorer failed (exit 1)" \
  "My own scorer failed, so nothing here was graded or filed — look yourself")"
REAL_FIN="$(fin "" "the primary flow works")"

check "9z. the library half of xo.sh really sourced and xo_finish really ran" \
  '[ "$NOLOOK_FIN" != EMPTY ] && [ -n "$NOLOOK_FIN" ]'
check "9a. CONTROL (unchanged) — an infra-only ending is still marked blocked" \
  '[ "$NOLOOK_FIN" = h ]'
check "9b. THE BEHAVIOUR — a look OUR OWN SCORER killed is marked blocked too" \
  '[ "$CRASH_FIN" = "my own scorer failed (exit 1)" ]'
check "9c. CONTROL — a look that reached a REAL verdict carries no such mark" \
  '[ "$REAL_FIN" = EMPTY ]'
check "9d. …and a stale mark from an earlier look is CLEARED by a real verdict" \
  "$PY -c \"
import sys
t=open('$XOSH',encoding='utf-8').read()
sys.exit(0 if 'obj_del \\\"\\\$obj\\\" lookBlockedBy' in t else 1)\""
# THE SITES. The baton is set by BOTH sentences the previous session added —
# read off the source because they sit inside `cmd_evaluate`'s own control flow.
# ── 9e — THE ARM ITSELF, RUN (S264 fix round 2, FIX 1) ──────────────────────
#
# DRIVEN, not grepped. What stood here was a source-text search for
# `XO_LOOK_BLOCKED` inside the arm's own window — and it was the ONLY check that
# went red when the fix-round-1 tester deleted the baton line; nothing
# behavioural noticed, because `9b` and `9g` were handed the baton BY THE TEST.
# (It also ran `crashed` as a command every single run: the word sat in
# backticks inside a double-quoted `eval` string. That is gone with it.)
#
# So the arm is lifted out of `xo.sh` verbatim — from its own `local mw=` to the
# `xo_finish` call it makes — wrapped in a function, and executed against the
# REAL `xo_finish` from the sourced library half. Nothing is handed in but the
# two things the arm's own control flow gives it: `$crashed`, and the mission.
FRAG_ARM="$TMPROOT/frag-crash-arm.sh"
FRAG="$FRAG_ARM" $PY - "$XOSH" <<'PY'
import os, sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.find('    local mw="${why:-$XO_MALFORMED}"')
j = t.find('xo_finish "$dir" low engaged "$mw" "$mw" "$unreadable"', i)
if i < 0 or j <= i:
    raise SystemExit("could not find the unreadable-verdict arm in xo.sh")
j = t.find("\n", j)
open(os.environ["FRAG"], "w", encoding="utf-8").write(
    "no_verdict_arm() {\n" + t[i:j] + "\n}\n")
PY
run_arm() { # <crashed> → the lookBlockedBy the arm+xo_finish really recorded
  fresh_state
  ( cd "$LREPO" && env CRASHED="$1" \
    LCARS_COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh" \
    LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
    bash -c '
      source "'"$XOLIB"'" || exit 9
      source "'"$FRAG_ARM"'" || exit 9
      dir=".git/lcars/missions/lcars-1"; xodir="$dir/xo"; mkdir -p "$xodir"
      id=lcars-1; score=""; why=""; crashed="${CRASHED:-}"
      no_verdict_arm >/dev/null 2>&1
      '"$PY"' -c "
import json,sys
d=json.load(open(\".git/lcars/missions/lcars-1/state.json\")).get(\"numberOne\") or {}
print(d.get(\"lookBlockedBy\") or \"EMPTY\")"' )
}
ARM_CRASH="$(run_arm "my own scorer failed (exit 7)")"
ARM_UNREAD="$(run_arm "")"
check "9e0. the arm was lifted out of xo.sh and really ran" \
  '[ -s "$FRAG_ARM" ] && [ -n "$ARM_CRASH" ] && [ "$ARM_CRASH" != EMPTY ]'
check "9e. THE ARM ITSELF hands the baton over — a scorer crash is marked retakeable" \
  '[ "$ARM_CRASH" = "my own scorer failed (exit 7)" ]'
check "9e2. …and so is a verdict it could not read back (the other ending of the same arm)" \
  '[ "$ARM_UNREAD" = "I could not read back my own verdict" ]'
check "9e3. CONTROL — the two endings are told apart, so 9e is not matching anything" \
  '[ "$ARM_CRASH" != "$ARM_UNREAD" ]'
check "9e4. CONTROL — and the arm really wrote a LOW verdict beside the mark" \
  "$PY -c \"
import json,sys
d=json.load(open('$LREPO/.git/lcars/missions/lcars-1/xo/verdict.json'))
sys.exit(0 if d.get('score')=='low' else 1)\""
check "9f. …and the comment no longer counts three arms where there are two" \
  "! grep -q 'the three arms that set it' '$XOSH' &&
   [ \"\$(grep -c 'xo_finish \"\$dir\" low engaged .*XO_NOLOOK' '$XOSH')\" = 2 ]"
# AND THE WHOLE WAY THROUGH: the block the crash arm now writes is retaken.
retake crash "{\"status\":\"engaged\",\"score\":\"low\",\"evaluatedAt\":\"2026-10-09T01:00:00Z\",\"meaning\":\"My own scorer failed, so nothing here was graded or filed — look yourself\",\"headline\":\"the verdict could not be read\",\"lookBlockedBy\":\"my own scorer failed (exit 1)\"}"
check "9g. THE BEHAVIOUR END TO END — the driver retakes a look our scorer killed" \
  'grep -q "NVRC=0" "$TMPROOT/rt-crash.out" &&
   grep -q -- "--again" "$TMPROOT/stub-crash.log" &&
   grep -qF "my own scorer failed" "$TMPROOT/stub-crash.log"'

# ===========================================================================
# 10. FIX 5 — THE FENCE SENTENCE STATES THE REAL RULE.
#
# MEASURED: the round-0 fence said "any absolute path" is refused. But S261
# deliberately ACCEPTS an absolute path inside the standing disposable copy, and
# the prompt hands the worker that absolute path in bold; the fence never
# mentioned the `<worktree>` mark, which is the shape that WOULD have worked. On
# the live look all four of the reviewer's seeding steps were refused with
# "cwd … is an absolute path outside the worktree" — the prompt told it the
# wrong rule and it paid a round for it.
#
# THE RULE IS TAKEN FROM `declared_escape` AND `argv_refusal`, and every
# sentence of the new fence is paired below with the gate behaviour it
# describes. This changes the PROSE only; section 5 pins the gate itself.
# ===========================================================================
echo ""
echo "10. the fence describes the rule the gate actually applies"

check "10a. the prompt names the mark that works for a step's cwd" \
  '"$PY" -c "
import sys
t=open('"'"'$P_R2'"'"',encoding=\"utf-8\").read()
i=t.lower().find(\"a declared step is not a shell\")
sys.exit(0 if i>=0 and \"<worktree>\" in t[i:i+1400] else 1)"'
check "10b. …and no longer claims a bare \"any absolute path\" rule" \
  '! grep -qF "and any absolute path." "$P_R2"'
check "10c. …and says the copy's own absolute path is accepted for cwd" \
  'grep -qiF "absolute path" "$P_R2" &&
   "$PY" -c "
import sys
t=open('"'"'$P_R2'"'"',encoding=\"utf-8\").read().lower()
i=t.find(\"a declared step is not a shell\")
seg=t[i:i+1400]
sys.exit(0 if (\"copy\" in seg or \"worktree\" in seg) and \"cwd\" in seg else 1)"'
check "10d. …and still says the argv itself takes no absolute path" \
  '"$PY" -c "
import sys
t=open('"'"'$P_R2'"'"',encoding=\"utf-8\").read().lower()
i=t.find(\"a declared step is not a shell\")
seg=t[i:i+1400]
sys.exit(0 if \"argv\" in seg else 1)"'
# THE GATE, DRIVEN, one case per sentence above.
check "10e. the gate really ACCEPTS the <worktree> mark as a cwd" \
  "$PY -c \"
import importlib.util,sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if not m.declared_escape({'do':'run','argv':['pytest','-v'],'cwd':'<worktree>'},'run','$WT') else 1)\""
check "10f. …really ACCEPTS the standing copy's own absolute path as a cwd" \
  "$PY -c \"
import importlib.util,sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if not m.declared_escape({'do':'run','argv':['pytest','-v'],'cwd':'$WT'},'run','$WT') else 1)\""
check "10g. …really REFUSES an absolute cwd outside it (the live refusal's words)" \
  "$PY -c \"
import importlib.util,sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
w=m.declared_escape({'do':'run','argv':['pytest','-v'],'cwd':'/etc'},'run','$WT')
sys.exit(0 if 'absolute path outside the worktree' in w else 1)\""
check "10h. …and really REFUSES an absolute path in the ARGV, copy or not" \
  "$PY -c \"
import importlib.util,sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if m.declared_escape({'do':'run','argv':['pytest','$WT/t_x.py']},'run','$WT')
         and not m.declared_escape({'do':'run','argv':['pytest','<worktree>/t_x.py']},'run','$WT') else 1)\""

# ===========================================================================
# 11. FIX ROUND 2 — the seven things the fresh tester held this round on.
#     Every one was CONFIRMED by it (or by the captain) before it was cured,
#     and every check below drives the thing it names.
# ===========================================================================
echo ""
echo "11a-11e. FIX 2 — the fence prose states the rule the gate really applies"

# MEASURED BY THE CAPTAIN HIMSELF: the round-1 prose told the reviewer a pipe, a
# redirect, `&&`, `$(…)` and `;` are REFUSED. He drove `argv_refusal` with
# controls that behaved correctly and all five are ACCEPTED — passed through as
# literal argv words. This session exists to close prompt-versus-fence drift, so
# the prose now says what happens instead.
check "11a. the prompt says a metacharacter is NOT refused" \
  'grep -qF "is NOT refused" "$P_R2"'
check "11b. …and says it is handed to the program as a literal word instead" \
  'grep -qiF "literal word" "$P_R2"'
check "11c. …and the old, false sentence is gone" \
  '! grep -qF "a \`&&\` or a \`\$(…)\` is not." "$P_R2" &&
   ! grep -qF "a pipe, a redirect, a \`&&\` or a \`\$(…)\` is not" "$P_R2"'
check "11d. THE GATE, DRIVEN — all five forms really are accepted, with controls" \
  "$PY -c \"
import importlib.util, sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
meta=[['pytest','-v','|','tee','out.txt'],['pytest','>','out.txt'],
      ['pytest','&&','echo','ok'],['echo','\\\$(whoami)'],['pytest','-v',';','ls']]
ctrl_bad=[['bash','-c','x'],['sh','-c','x']]
ctrl_ok=[['pytest','-v'],['bash','run-tests.sh']]
sys.exit(0 if not any(m.argv_refusal(a) for a in meta)
         and all(m.argv_refusal(a) for a in ctrl_bad)
         and not any(m.argv_refusal(a) for a in ctrl_ok) else 1)\""
# FIX 2b — and the `..` clause. MEASURED: `cwd: \"sub/../sub\"` is refused with
# \"walks up out of the worktree\", which is itself untrue; ANY `..` component in
# a RELATIVE cwd/path/file is refused, walking out or not — while an ABSOLUTE
# `..` path that resolves inside the copy is accepted by the `inside()` branch.
# The two halves genuinely disagree, so the prose describes what the code does.
check "11e. the prompt states the real \`..\` rule, both halves" \
  'grep -qiF "whether or not it leaves the copy" "$P_R2" &&
   grep -qF "sub/../sub" "$P_R2"'
check "11e2. THE GATE, DRIVEN — a relative \`..\` that stays inside is refused anyway" \
  "$PY -c \"
import importlib.util, sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
w=m.declared_escape({'do':'run','argv':['pytest'],'cwd':'sub/../sub'},'run','$WT')
sys.exit(0 if 'walks up out of the worktree' in w else 1)\""
check "11e3. CONTROL — and an ABSOLUTE \`..\` resolving inside the copy is accepted" \
  "$PY -c \"
import importlib.util, sys
spec=importlib.util.spec_from_file_location('xr','$XORUN'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
sys.exit(0 if not m.declared_escape({'do':'run','argv':['pytest'],'cwd':'$WT/sub/..'},'run','$WT')
         and not m.declared_escape({'do':'run','argv':['pytest'],'cwd':'sub'},'run','$WT') else 1)\""

echo ""
echo "11f-11g. FIX 3 — a retake stamp that did not land does not spawn"

# MEASURED by the fresh tester: a mission whose `state.json` makes `drive_xo_put`
# REFUSE to write gave THREE spawns across three driver passes where a
# well-formed one gives one. The stamp is what makes one retake one, so it is
# now checked. The record below is valid JSON that the one-field-per-line writer
# refuses (its closing brace is not alone on the last line) — the same refusal
# the tester hit, built by the product's own rule rather than by corrupting it.
BADREC="$TMPROOT/rt-badrec"
rm -rf "$BADREC"; cp -R "$repo" "$BADREC"
$PY - "$BADREC/.git/lcars/missions/lcars-1/state.json" "$NOLOOK" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["numberOne"] = {"status": "engaged", "score": "low",
                  "evaluatedAt": "2026-10-09T01:00:00Z", "meaning": sys.argv[2],
                  "headline": "your build did not start — nothing came up",
                  "lookBlockedBy": "your build did not start — nothing came up"}
rows = ["  %s: %s" % (json.dumps(k), json.dumps(v)) for k, v in d.items()]
# VALID JSON, and NOT the shape the writer will touch: the closing brace rides
# the last field's line, so both the json and the awk writer defer/refuse.
open(p, "w").write("{\n" + ",\n".join(rows) + " }\n")
PY
: >"$TMPROOT/stub-badrec.log"
for _i in 1 2 3; do
  ( cd "$BADREC" && env XO_STUB_LOG="$TMPROOT/stub-badrec.log" \
      LCARS_XO_SCRIPT="$XOSTUB" LCARS_GH_BIN=/usr/bin/true \
      bash "$RUNSH" number-one-verify-test --mission lcars-1 ) \
    >>"$TMPROOT/rt-badrec.out" 2>&1
  _j=0; while [ "$_j" -lt 20 ]; do sleep 0.1; _j=$((_j + 1)); done
done
check "11f0. CONTROL — the rig really is a blocked look the gate would retake" \
  "$PY -c \"
import json,sys
d=json.load(open('$BADREC/.git/lcars/missions/lcars-1/state.json'))
n=d.get('numberOne') or {}
sys.exit(0 if n.get('lookBlockedBy') and n.get('evaluatedAt') and not n.get('retakenAt') else 1)\""
check "11f. a stamp the writer REFUSED spawns nothing, three passes running" \
  '[ ! -s "$TMPROOT/stub-badrec.log" ]'
check "11f2. …and the gate refused rather than looping (rc 1 on every pass)" \
  '[ "$(grep -c "NVRC=1" "$TMPROOT/rt-badrec.out")" = 3 ]'
check "11g. …and it says so, pointing at the verb that is still the captain's" \
  'grep -qiF "could not record that I am retaking" "$TMPROOT/rt-badrec.out" &&
   grep -qF -- "--again" "$TMPROOT/rt-badrec.out"'
check "11g2. CONTROL — the writer really did refuse (nothing was stamped)" \
  "$PY -c \"
import json,sys
d=json.load(open('$BADREC/.git/lcars/missions/lcars-1/state.json'))
sys.exit(0 if not (d.get('numberOne') or {}).get('retakenAt') else 1)\""

echo ""
echo "11h-11j. FIX 4 — the cure reaches the RE-CHECK's score too"

# MEASURED: `xo.sh`'s re-check called the scorer with THIRTEEN arguments and
# stopped, so `placed` was empty there and a criterion the re-check settled on a
# transcript it had just recorded itself re-scored as "recorded as not-checked".
# That is the live defect's exact shape, displaced to the second score. Driven
# positionally off the real call site, exactly as 6k is.
check "11h0. the re-check call site was lifted and really ran" \
  '[ "$(scorer_argv rep2 | sed -n 1p)" = "SKILLDIR/xo-score.py" ]'
check "11h. the RE-CHECK passes 17 arguments too, not 13" '[ "$(n_args rep2)" = 17 ]'
check "11i. …and its 17th is THIS re-check's own look directory" \
  '[ "$(nth_arg rep2 17)" = LOOKDIR ]'
check "11i2. CONTROL — the three slots the re-check has never used are still empty" \
  '[ -z "$(nth_arg rep2 14)" ] && [ -z "$(nth_arg rep2 15)" ] &&
   [ -z "$(nth_arg rep2 16)" ]'
check "11i3. CONTROL — and its first three arguments are the re-check's own files" \
  '[ "$(nth_arg rep2 1)" = "OUT/xo-recheck.json" ] &&
   [ "$(nth_arg rep2 3)" = "XODIR/second/verdict.json" ]'

# AND THE RE-CHECK DRIVEN END TO END, through its own call site: a criterion the
# re-check settles on a transcript the harness recorded in the RE-CHECK's look.
rc_e2e() { # <dir> <where: recheck-1|look-1>
  local d="$1" where="$2" frag
  frag="$(frag_of rep2)"
  mkdir -p "$d/xo/shots/recheck-1" "$d/xo/shots/look-1" "$d/out" "$d/xo/second"
  cp "$TESTS_J" "$d/tests.json"
  place_step "$d/xo/shots/$where" 10-suite-verbose suite-verbose \
    "\$ pytest -v
tests/test_app.py::$CUR_CASE
7 passed in 0.4s"
  printf '%s\n' '{"criteria": [{"id": "prd-1", "text": "duplicate names are refused",
    "impact": "high"}]}' >"$d/xo/criteria.json"
  QUOTE="$CUR_CASE" $PY - "$d/out/xo-recheck.json" <<'PY'
import json, os, sys
json.dump({"score": "high", "summary": "s",
           "criteria": [{"id": "prd-1", "status": "met", "evidence": "tests",
                         "testQuote": os.environ["QUOTE"],
                         "note": "the reviewer's own note, which must survive"}],
           "gaps": []}, open(sys.argv[1], "w"), indent=1)
PY
  ( env XO_PY="$PY" SKILL_DIR="$REPO_ROOT/skills/lcars-xo" \
        xodir="$d/xo" shots="$d/xo/shots/recheck-1" dir="$d" out="$d/out" \
        rwalk="$d/xo/walk-recheck-1.json" obsfile="" testsfile="$d/tests.json" \
        st="ST" D="$d" FRAG="$frag" \
      $PY "$CAGE" 240 bash -c '
        xo_engine_for() { printf ""; }; xo_engine=""; rep2=""
        source "$FRAG"
        printf "%s" "$rep2" >"$D/wire.txt"
        cp "$D/xo/second/verdict.json" "$D/out.json" 2>/dev/null || true' ) \
    >"$d/scorer-log.txt" 2>&1
}
RC_CUR="$TMPROOT/rc-cur";     rc_e2e "$RC_CUR"   recheck-1
RC_STALE="$TMPROOT/rc-stale"; rc_e2e "$RC_STALE" look-1
check "11j0. the re-check's scorer ran in both cases" \
  '[ -s "$RC_CUR/out.json" ] && [ -s "$RC_STALE/out.json" ]'
check "11j. THE BEHAVIOUR — the re-check now believes its OWN recorded transcript" \
  '[ "$(status_of "$RC_CUR/out.json")" = met ]'
check "11j2. CONTROL — and still not a previous look's (the scope travelled too)" \
  '[ "$(status_of "$RC_STALE/out.json")" = untested ]'

echo ""
echo "11k-11l. FIX 5 — a dropped step reaches the CAPTAIN, not only the reviewer"

# MEASURED by the fresh tester: the gate printed "14 asked, 12 kept (cap 12),
# 0 refused, 2 over the cap"; `xo_reach_actions` sent that to /dev/null,
# `xo_say_refusals` printed ZERO bytes (it returned early on an empty `refused`)
# and `grep -c droppedSteps xo-score.py` was 0 — so the captain's report had no
# drop section at all. Additive on both surfaces; the refusal sentence a suite
# pins is byte-for-byte unchanged.
CAPJ="$TMPROOT/journey-dropped.json"
$PY - "$CAPJ" <<'PY'
import json, sys
json.dump({"droppedSteps": [
    {"kind": "run", "key": "seed-01-add-exercise", "for": "prd-1", "round": "2",
     "why": "the harness runs at most 12 step(s) a round and this one came "
            "after the 12th, so it was DROPPED for the cap"}]},
          open(sys.argv[1], "w"), indent=1)
PY
cap_report() { # <dir> <journey|"">
  local d="$1" j="$2"
  mkdir -p "$d/xo"
  printf '%s\n' '{"criteria": [{"id": "prd-1", "text": "x", "impact": "high"}]}' \
    >"$d/criteria.json"
  printf '%s\n' '{"score": "medium", "summary": "s",
    "criteria": [{"id": "prd-1", "status": "untested", "evidence": "none",
                  "note": "n"}], "gaps": []}' >"$d/verdict.json"
  $PY "$CAGE" 240 $PY "$SCORE" "$d/verdict.json" "$d/criteria.json" \
    "$d/out.json" "" "" "" "" "" "" "" "" "" "$j" >"$d/wire.txt" 2>&1
}
CAP_D="$TMPROOT/cap-drop"; cap_report "$CAP_D" "$CAPJ"
CAP_N="$TMPROOT/cap-none"; cap_report "$CAP_N" ""
check "11k0. the scorer ran and wrote the captain's report in both cases" \
  '[ -s "$CAP_D/report.md" ] && [ -s "$CAP_N/report.md" ]'
check "11k. THE BEHAVIOUR — the captain's report has a drop section, naming the step" \
  'grep -qiF "no room to run" "$CAP_D/report.md" &&
   grep -qF "seed-01-add-exercise" "$CAP_D/report.md"'
check "11k2. …and does NOT call it refused, which would send a fine step back" \
  "$PY -c \"
import sys
t=open('$CAP_D/report.md',encoding='utf-8').read()
i=t.find('no room to run')
seg=t[i:i+700]
sys.exit(0 if 'refused' not in seg.replace('not refused','') else 1)\""
check "11l. CONTROL — a look with nothing dropped has no such section at all" \
  '! grep -qiF "no room to run" "$CAP_N/report.md"'
# AND THE CONSOLE, driven through the real `xo_say_refusals`.
say_drop() { # <kept.json>
  ( cd "$LREPO" && env LCARS_COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh" \
      LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
      bash -c 'source "'"$XOLIB"'" || exit 9; xo_say_refusals "'"$1"'" 2' ) 2>&1
}
K_DROP="$TMPROOT/kept-drop.json"
printf '%s\n' '{"asked": 14, "cap": 12, "steps": [], "reachSteps": [],
  "refused": [], "dropped": [{"kind": "run", "key": "seed-01-add-exercise",
  "why": "it came after the 12th, so it was DROPPED for the cap"}]}' >"$K_DROP"
K_REF="$TMPROOT/kept-ref.json"
printf '%s\n' '{"asked": 3, "cap": 12, "steps": [], "reachSteps": [],
  "refused": [{"kind": "run", "why": "its argv asks for a shell"}],
  "dropped": []}' >"$K_REF"
SAY_DROP="$(say_drop "$K_DROP")"; SAY_REF="$(say_drop "$K_REF")"
check "11l2. THE BEHAVIOUR — the console says a step was dropped for the cap" \
  '[ -n "$SAY_DROP" ] &&
   printf "%s" "$SAY_DROP" | grep -qF "DROPPED FOR THE CAP" &&
   printf "%s" "$SAY_DROP" | grep -qF "seed-01-add-exercise"'
check "11l3. CONTROL — the refusal sentence a suite pins is byte-for-byte unchanged" \
  'printf "%s" "$SAY_REF" |
   grep -qF "round 2 asked for 3 step(s); 1 were refused before anything ran, 0 went ahead"'
check "11l4. CONTROL — and a refusal-only round says nothing about a cap" \
  '! printf "%s" "$SAY_REF" | grep -qF "DROPPED FOR THE CAP"'

echo ""
echo "11m-11q. FIX 6 — a transcript must be the output of a RUN, and this look's"

# THE THREE PATHS THE FRESH TESTER GOT IN ON WITHOUT FORGING ANYTHING:
#   1. a declared `read` step on a file the reviewer wrote with its own shell
#   2. a `run` step whose program just echoes (`cat`/`printf`/`echo`/`head`/`tee`
#      all pass the argv fence)
#   3. clobbering a recorded transcript's `.txt`, sibling untouched
# …plus a symlink out of the look dir, and an uppercase `.TXT`.
# THE CURE IS MORE RECORD CHECKS, never a judgement about the text.
P6="$TMPROOT/place6"; mkdir -p "$P6/look-2" "$P6/outside"
READ_CASE="test_declared_read_step PASSED"
RUN_CASE="test_declared_run_step PASSED"
place_read "$P6/look-2" 20-read-step read-the-file \
  "tests/test_app.py::$READ_CASE"
place_step "$P6/look-2" 21-run-step suite-verbose \
  "tests/test_app.py::$RUN_CASE"
settle6() { # <quote>
  LOOK="$P6/look-2" QUOTE="$1" TESTS="$TESTS_J" SCORE_PY="$SCORE" $PY - <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("xs", os.environ["SCORE_PY"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
tests = json.load(open(os.environ["TESTS"]))
placed = m.placed_transcripts(os.environ["LOOK"])
by = []
okd, why = m.tests_settle(tests, os.environ["QUOTE"], placed, by)
print("SETTLED\t%s" % (by[0] if by else "?") if okd else "NO\t%s" % why)
PY
}
check "11m. a declared \`read\` step's transcript settles NOTHING (vector 1)" \
  '[ "$(settle6 "$READ_CASE" | cut -f1)" = NO ]'
check "11m2. CONTROL — the same shape as a \`run\` step, with an argv, settles" \
  '[ "$(settle6 "$RUN_CASE" | cut -f2)" = 21-run-step.txt ]'
# VECTOR 3 — the transcript is overwritten, the sibling readout left alone.
CLOB_CASE="test_clobbered_in_place PASSED"
place_step "$P6/look-2" 22-clobber suite-verbose "tests/test_app.py::$RUN_CASE"
CLOB_BEFORE="$(settle6 "$RUN_CASE" | cut -f1)"
printf 'tests/test_app.py::%s\n' "$CLOB_CASE" >"$P6/look-2/22-clobber.txt"
check "11n0. CONTROL — before the clobber that pair really did settle" \
  '[ "$CLOB_BEFORE" = SETTLED ]'
check "11n. a CLOBBERED transcript settles nothing, sibling intact (vector 3)" \
  '[ "$(settle6 "$CLOB_CASE" | cut -f1)" = NO ]'
check "11n2. CONTROL — and the sibling readout is still sitting right there" \
  '[ -s "$P6/look-2/22-clobber.json" ]'
# A SYMLINK OUT OF THE LOOK, with a genuine pair at the other end.
SNEAK_CASE="test_symlinked_in_from_outside PASSED"
place_step "$P6/outside" sneak suite-verbose "tests/test_app.py::$SNEAK_CASE"
ln -s "$P6/outside/sneak.txt" "$P6/look-2/sneak.txt"
ln -s "$P6/outside/sneak.json" "$P6/look-2/sneak.json"
check "11o. a transcript SYMLINKED in from outside the look settles nothing" \
  '[ "$(settle6 "$SNEAK_CASE" | cut -f1)" = NO ]'
check "11o2. CONTROL — the link really resolves, so 11o is the containment rule" \
  '[ -s "$P6/look-2/sneak.txt" ] &&
   grep -qF "test_symlinked_in_from_outside" "$P6/look-2/sneak.txt"'
# AN UPPERCASE SUFFIX, which the round-1 reader matched case-insensitively.
UP_CASE="test_uppercase_suffix PASSED"
place_step "$P6/outside" 23-upper suite-verbose "tests/test_app.py::$UP_CASE"
cp "$P6/outside/23-upper.txt" "$P6/look-2/23-UPPER.TXT"
UPJ="$P6/look-2/23-UPPER.json" $PY - "$P6/outside/23-upper.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
d["evidence"] = "23-UPPER.TXT"
json.dump(d, open(os.environ["UPJ"], "w"), indent=2)
PY
check "11p. an uppercase .TXT is not read as a transcript at all" \
  '[ "$(settle6 "$UP_CASE" | cut -f1)" = NO ]'
check "11p2. CONTROL — the identical bytes under a lower-case .txt DO settle" \
  'cp "$P6/outside/23-upper.txt" "$P6/look-2/24-lower.txt" &&
   $PY -c "
import json,sys
d=json.load(open(\"$P6/outside/23-upper.json\"))
d[\"evidence\"]=\"24-lower.txt\"
json.dump(d, open(\"$P6/look-2/24-lower.json\", \"w\"), indent=2)" &&
   [ "$(settle6 "$UP_CASE" | cut -f2)" = 24-lower.txt ]'
# VECTOR 2 — an echo-only program still passes the fence, and the cure for THAT
# is that the record shows exactly what ran. Visible, not silently believed.
check "11q. an echo-only run step is still admitted — but its argv is ON the record" \
  "$PY -c \"
import importlib.util, json, sys
spec=importlib.util.spec_from_file_location('xs','$SCORE'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
doc=m.harness_wrote('$P6/look-2/21-run-step.txt', '$P6/look-2')
sys.exit(0 if doc and doc.get('argv') and doc.get('do')=='run' else 1)\""
check "11q2. CONTROL — and a readout with an EMPTY argv is refused" \
  "$PY -c \"
import importlib.util, json, os, sys
spec=importlib.util.spec_from_file_location('xs','$SCORE'); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d=json.load(open('$P6/look-2/21-run-step.json'))
d['argv']=[]
json.dump(d, open('$P6/look-2/21-run-step.json','w'), indent=2)
sys.exit(0 if m.harness_wrote('$P6/look-2/21-run-step.txt', '$P6/look-2') is None else 1)\""

echo ""
echo "11r. FIX 7 — a placed-settled gap is disclosed, the way a criterion is"

# MEASURED: `xo-score.py` passed `placed` at both gap call sites and collected no
# `settled_by` and emitted no note, so a criterion settled on a transcript the
# reviewer placed said so while a CONTRADICTION kept alive on the very same
# evidence was silent.
gap_e2e() { # <dir> <quote> [--recorded]
  local d="$1" quote="$2" rec="${3:-}"
  mkdir -p "$d/xo/shots/look-1"
  cp "$TESTS_J" "$d/tests.json"
  # THE CONTROL'S ONLY DIFFERENCE: the same quote is ALSO in the run
  # `xo-tests.py` recorded, so `tests_settle` finds it there first and the row
  # stands on the ordinary evidence. Everything else — the placed transcript,
  # the verdict, the gap — is identical.
  if [ "$rec" = "--recorded" ]; then
    QUOTE="$quote" $PY - "$d/tests.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
d["outputTail"] = "tests/test_app.py::%s\n7 passed\n" % os.environ["QUOTE"]
json.dump(d, open(sys.argv[1], "w"), indent=1)
PY
  fi
  place_step "$d/xo/shots/look-1" 10-suite-verbose suite-verbose \
    "\$ pytest -v
tests/test_app.py::$CUR_CASE
7 passed in 0.4s"
  printf '%s\n' '{"criteria": [{"id": "prd-1", "text": "duplicate names are refused",
    "impact": "high"}]}' >"$d/xo/criteria.json"
  QUOTE="$quote" $PY - "$d/verdict.json" <<'PY'
import json, os, sys
json.dump({"score": "low", "summary": "s",
           "criteria": [{"id": "prd-1", "status": "gap", "evidence": "tests",
                         "testQuote": os.environ["QUOTE"], "note": "n"}],
           "gaps": [{"criterion": "prd-1", "kind": "contradiction",
                     "title": "duplicate names are accepted",
                     "evidence": "tests",
                     "testQuote": os.environ["QUOTE"],
                     "why": "the suite says so"}]},
          open(sys.argv[1], "w"), indent=1)
PY
  run_prod_scorer "$d" look-1
}
G_PLACED="$TMPROOT/gap-placed"; gap_e2e "$G_PLACED" "$CUR_CASE"
G_REC="$TMPROOT/gap-recorded"; gap_e2e "$G_REC" "$CUR_CASE" --recorded
check "11r0. the scorer ran in both cases" \
  '[ -s "$G_PLACED/out.json" ] && [ -s "$G_REC/out.json" ]'
check "11r. THE BEHAVIOUR — a contradiction kept alive on a PLACED transcript says so" \
  "$PY -c \"
import json,sys
d=json.load(open('$G_PLACED/out.json'))
n=' '.join(d.get('ledgerNotes') or [])
sys.exit(0 if '10-suite-verbose.txt' in n and 'contradiction' in n else 1)\""
check "11r2. CONTROL — one standing on the RECORDED run adds no such sentence" \
  "$PY -c \"
import json,sys
d=json.load(open('$G_REC/out.json'))
n=' '.join(d.get('ledgerNotes') or [])
sys.exit(0 if '10-suite-verbose.txt' not in n else 1)\""
check "11r3. CONTROL — and the contradiction really did survive in both" \
  "$PY -c \"
import json,sys
for f in ('$G_PLACED/out.json','$G_REC/out.json'):
    d=json.load(open(f))
    g=[x for x in (d.get('gaps') or []) if x.get('kind')=='contradiction']
    if not g: sys.exit(1)
sys.exit(0)\""

check "11s. ZERO SPEND, after everything above — neither engine was invoked" \
  '[ ! -s "$SPEND_LOG" ]'

printf '\n=== %s passed, %s failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
