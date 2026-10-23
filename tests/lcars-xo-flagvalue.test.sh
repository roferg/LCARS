#!/usr/bin/env bash
#
# S319 — A FLAG WITH NO VALUE IS A REFUSAL, NEVER AN INFINITE LOOP.
#
# THE DEFECT (ledgered as D13, found by S309, measured 2026-10-23). Every option
# arm in `skills/lcars-xo/xo.sh` read
#
#     --engine)   engine="${2:-}"; shift 2   # ...with its failure swallowed
#
# and with the flag LAST on the line bash's `shift 2` FAILS — it leaves "$@"
# exactly as it found it — while the swallowing `|| true` hides it. The enclosing
# `while [ $# -gt 0 ]` then re-reads the same flag FOREVER.
#
# MEASURED AT HEAD, caged at 8s: `lcars xo on --engine` with no value, `xo on
# --model`, `xo answer --mission` and `xo evaluate --mission` all pegged a core,
# printed NOTHING AT ALL, and never returned — 4 of 4. There were EIGHTEEN such
# sites across `cmd_on`, `cmd_answer`, `cmd_evaluate`, `cmd_file_logs`,
# `cmd_recheck`, `cmd_report` and the four non-captain-facing verbs (`seed`,
# `unlisted`, `claim`, `detach`).
#
# WHY IT IS THE WORST CLASS AN UNATTENDED RUN HAS. A hang is the most expensive
# failure there is, because a blocked run and a healthy quiet one look identical
# from outside. `lcars xo on --engine "$E"` with $E unset is one unset variable
# away in a command the captain types by hand.
#
# THE SHAPE OF THIS SUITE, and why the order is what it is:
#
#   SECTION A COMES FIRST AND CARRIES THE MOST WEIGHT. Eighteen edits to
#   argument parsing is a wide blast radius, and BREAKING A VALID INVOCATION is
#   a worse outcome than missing a nineteenth spin. So every control runs before
#   any refusal is asserted, and each one asserts the value REACHED THE BODY —
#   not merely that the parse loop terminated.
#
#   SECTION F's guard has a KNOWN-GOOD CONTROL. A grep that silently matches
#   nothing reads exactly like a clean result; that method defect corrupted five
#   measurements in one night (ledgered as D19). So the anti-regression sweep is
#   a FUNCTION, run twice: once over the tracked shell sources (must find
#   nothing) and once over a planted file carrying the idiom (must find it). A
#   guard nobody proved can see its own pattern is a test that can only pass.
#
# EVERY DRIVE IS CAGED (`tests/lib/cage.py`), because the defect under repair is
# a hang and an uncaged probe would wedge the shell it is run from. A timeout is
# reported as a timeout — the cage exits 124 — so "it refused" and "it refused
# in under a second" are never confused for one another.
#
# ZERO SPEND. A PATH shim fakes both `claude` and `copilot` and is proven to
# fire in section 0 before any no-spend claim is made.
#
# Usage: bash tests/lcars-xo-flagvalue.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"
UPDATE="$REPO_ROOT/skills/lcars-update/update.sh"
CAGE="$REPO_ROOT/tests/lib/cage.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

[ -f "$XO" ]     || { echo "script under test not found at $XO"; exit 1; }
[ -f "$UPDATE" ] || { echo "script under test not found at $UPDATE"; exit 1; }
[ -f "$CAGE" ]   || { echo "the cage is missing at $CAGE"; exit 1; }

# ─── THE NO-SPEND SHIM ───────────────────────────────────────────────────────
# A PATH shim, never an env var: the engine arrives from three places (a request
# body, $LCARS_WORKER_BIN, a persisted state.json workerBin) with a different
# winner per path, and an env var has been measured LOSING to a persisted
# workerBin.
SHIMBIN="$TMPROOT/shimbin"; mkdir -p "$SHIMBIN"
SHIM_LOG="$TMPROOT/shim.log"; : >"$SHIM_LOG"
for n in claude copilot; do
  cat >"$SHIMBIN/$n" <<SHIM
#!/usr/bin/env bash
m=no
for a in "\$@"; do case "\$a" in --model|--model=*) m=yes ;; esac; done
printf '%s\t%s\n' "$n" "\$m" >>"$SHIM_LOG"
exit 97
SHIM
  chmod +x "$SHIMBIN/$n"
done
export PATH="$SHIMBIN:$PATH"

MISSION=lcars-20261002-001

new_repo() { # → repo path, one mission parked at verify
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions/$MISSION/xo"
  # ONE KEY PER LINE, and `numberOne` on ONE LINE — the shape `lcars init`
  # writes. A fixture crammed onto one line is rewritten by
  # `lcars_config_set_or_add_raw` into `{ "numberOne": {...}` with its other
  # keys and its closing brace gone.
  {
    printf '{\n'
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",\n'
    printf '  "projectName": "repo",\n'
    printf '  "contextFile": null,\n'
    printf '  "testCommand": "true",\n'
    printf '  "numberOne": {"enabled": false},\n'
    printf '  "created": "2026-10-02T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$repo/.git/lcars/config.json" || { echo "FIXTURE CONFIG IS NOT VALID JSON"; exit 1; }
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$MISSION"
    printf '  "type": "feature",\n'
    printf '  "title": "A build to look at",\n'
    printf '  "stage": "verify",\n'
    printf '  "created": "2026-10-02T00:00:00Z",\n'
    printf '  "githubIssue": 7,\n'
    printf '  "branch": "lcars/%s",\n' "$MISSION"
    printf '  "base": "main",\n'
    printf '  "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e"\n'
    printf '}\n'
  } >"$repo/.git/lcars/missions/$MISSION/state.json"
  printf '%s' "$repo"
}

# ─── THE CAGED DRIVE ─────────────────────────────────────────────────────────
# Fills CAGE_RC / CAGE_ELAPSED / CAGE_TIMEDOUT / CAGE_OUT. The cage's first line
# is its contract (`ELAPSED <n>s EXIT <code>` or `... *** TIMED OUT ...`) and its
# exit status is the caged process's own, 124 for a timeout.
CAGE_RC=0; CAGE_ELAPSED=""; CAGE_TIMEDOUT=0; CAGE_OUT=""
caged() { # <seconds> <cmd...>
  local secs="$1"; shift
  local raw rc=0 first
  raw="$("$PY" "$CAGE" "$secs" "$@" 2>&1)" || rc=$?
  CAGE_RC="$rc"
  first="$(printf '%s\n' "$raw" | sed -n 1p)"
  CAGE_ELAPSED="$(printf '%s' "$first" | sed -n 's/^ELAPSED \([0-9.]*\)s.*/\1/p')"
  if printf '%s' "$first" | grep -q 'TIMED OUT'; then CAGE_TIMEDOUT=1; else CAGE_TIMEDOUT=0; fi
  CAGE_OUT="$(printf '%s\n' "$raw" | sed 1d)"
}
faster_than() { # <seconds> — true when the last caged drive beat the budget
  [ -n "$CAGE_ELAPSED" ] || return 1
  awk -v e="$CAGE_ELAPSED" -v b="$1" 'BEGIN { exit !(e < b) }'
}

echo
echo "=== lcars xo: a flag with no value is a refusal, never an infinite loop (S319) ==="
echo

# ===========================================================================
# 0. THE SHIM IS PROVEN TO FIRE, before any no-spend claim is made.
# ===========================================================================
printf -- '── 0. the shim fires ──\n'
SHIM_RC=0; copilot --probe >/dev/null 2>&1 || SHIM_RC=$?
check "0a. the copilot shim intercepts (so a later empty log means no spend)" \
  "[ '$SHIM_RC' = 97 ] && grep -q '^copilot' '$SHIM_LOG'"
SHIM_RC=0; claude --probe >/dev/null 2>&1 || SHIM_RC=$?
check "0b. the claude shim intercepts too" \
  "[ '$SHIM_RC' = 97 ] && grep -q '^claude' '$SHIM_LOG'"
: >"$SHIM_LOG"

# ===========================================================================
# A. THE CONTROL, AND IT CARRIES THE MOST WEIGHT: every valid invocation still
#    works, and the value REACHES THE BODY.
#
# Each row asserts something only a parsed-and-delivered value can produce — a
# recorded engine, a resolved mission id echoed back, a claim that printed its
# own id. A check that only asserted "exit 0" would pass against a parse loop
# that threw the value away.
# ===========================================================================
echo
printf -- '── A. the controls: every valid invocation still works ──\n'

repoA="$(new_repo)"

caged 30 bash -c "cd '$repoA' && bash '$XO' on --engine copilot"
check "A1. \`xo on --engine copilot\` engages, and the ENGINE IT WAS GIVEN is the one it reports" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'NUMBER ONE: ON · copilot'"
check "A2. ...and it is RECORDED in config.json, on one line, still valid JSON" \
  "\"\$PY\" -c 'import json,sys
c=json.load(open(sys.argv[1]))
n=c.get(\"numberOne\") or {}
sys.exit(0 if n.get(\"enabled\") is True and n.get(\"engine\")==\"copilot\" else 1)' '$repoA/.git/lcars/config.json' \
   && [ \"\$(grep -c '\"numberOne\"' '$repoA/.git/lcars/config.json')\" = 1 ]"

caged 30 bash -c "cd '$repoA' && bash '$XO' on --model a-model-string"
check "A3. \`xo on --model <m>\` takes the model it was given" \
  "[ '$CAGE_RC' = 0 ] && \"\$PY\" -c 'import json,sys
n=(json.load(open(sys.argv[1])).get(\"numberOne\") or {})
sys.exit(0 if n.get(\"model\")==\"a-model-string\" else 1)' '$repoA/.git/lcars/config.json'"

caged 30 bash -c "cd '$repoA' && bash '$XO' on --engine=copilot"
check "A4. the \`--engine=<v>\` form still works (it never had the defect; it must not acquire one)" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'ON · copilot'"

caged 30 bash -c "cd '$repoA' && bash '$XO'"
check "A5. bare \`xo\` still prints the status table with the mission in it" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'MISSION' \
   && printf '%s' \"\$CAGE_OUT\" | grep -q '$MISSION'"

caged 30 bash -c "cd '$repoA' && bash '$XO' on $MISSION"
check "A6. \`xo on <mission>\` — a POSITIONAL still reaches the body" \
  "[ '$CAGE_RC' = 0 ]"

caged 30 bash -c "cd '$repoA' && bash '$XO' off"
check "A7. \`xo off\` still stands the repo down" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'NUMBER ONE: OFF'"

# `answer` on a mission with no gate refuses — but it refuses BY NAME, which is
# proof the --mission value was parsed AND resolved through resolve_mission.
caged 30 bash -c "cd '$repoA' && bash '$XO' answer --mission $MISSION"
check "A8. \`xo answer --mission <id>\` reaches the body with the id resolved (names it back)" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q \"mission '$MISSION' has no pending question\""

caged 60 bash -c "cd '$repoA' && bash '$XO' evaluate --mission $MISSION"
check "A9. \`xo evaluate --mission <id>\` reaches the body with the id resolved" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q '$MISSION'"

caged 60 bash -c "cd '$repoA' && bash '$XO' evaluate --mission $MISSION --again --because 'the blocker cleared'"
check "A10. \`--again --because '<text>'\` reaches the body — a two-value arm in one line" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && ! printf '%s' \"\$CAGE_OUT\" | grep -q 'needs a value'"

caged 30 bash -c "cd '$repoA' && bash '$XO' file-logs --mission $MISSION"
check "A11. \`xo file-logs --mission <id>\` reaches the body with the id resolved" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q '$MISSION'"

caged 30 bash -c "cd '$repoA' && bash '$XO' recheck --mission $MISSION"
check "A12. \`xo recheck --mission <id>\` reaches the body with the id resolved" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q '$MISSION'"

caged 30 bash -c "cd '$repoA' && bash '$XO' report"
check "A13. \`xo report\` still prints the First Officer's report" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -qi 'report'"

caged 30 bash -c "cd '$repoA' && bash '$XO' report --all --seen-entry some-entry-key --seen-entry other-key"
check "A14. \`--seen-entry\` is still REPEATABLE and both keys are marked" \
  "[ '$CAGE_RC' = 0 ] && \"\$PY\" -c 'import json,sys
d=json.load(open(sys.argv[1]))
blob=json.dumps(d)
sys.exit(0 if \"some-entry-key\" in blob and \"other-key\" in blob else 1)' '$repoA/.git/lcars/xo-seen.json'"

caged 30 bash -c "cd '$repoA' && bash '$XO' report --all --seen-mission $MISSION"
check "A15. \`--seen-mission <id>\` still works" "[ '$CAGE_RC' = 0 ]"

caged 30 bash -c "cd '$repoA' && bash '$XO' claim --mission $MISSION --hold 0"
check "A16. \`xo claim --mission <id> --hold 0\` still wins and names the mission it claimed" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'CLAIMED $MISSION'"

caged 30 bash -c "cd '$repoA' && bash '$XO' seed --mission $MISSION --in '$repoA'"
check "A17. \`xo seed --mission <id> --in <dir>\` still reaches the seed" \
  "[ '$CAGE_RC' = 0 ]"

PF="$TMPROOT/detach.pid"; : >"$TMPROOT/detach.log"
caged 30 bash -c "cd '$repoA' && bash '$XO' detach --pidfile '$PF' --log '$TMPROOT/detach.log' -- bash -c 'echo detached-ok'"
check "A18. \`xo detach --pidfile <p> --log <l> -- <cmd>\` still spawns, and the pidfile is written" \
  "[ '$CAGE_RC' = 0 ] && [ -s '$PF' ]"

caged 30 bash -c "cd '$repoA' && bash '$XO' unlisted --mission $MISSION --shots '$repoA/shots' --out '$TMPROOT/unlisted.json'"
check "A19. \`xo unlisted --mission <id> --shots <d> --out <f>\` — a THREE-value arm set reaches the body" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && ! printf '%s' \"\$CAGE_OUT\" | grep -q 'needs a value'"

# The expensive control, last: the catch-up sweep drives a whole look.
repoSweep="$(new_repo)"
caged 120 bash -c "cd '$repoSweep' && bash '$XO' on --engine copilot >/dev/null 2>&1 && bash '$XO' on --sweep"
check "A20. \`xo on --sweep\` with a recorded engine still runs the catch-up to a score" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'intent match'"

caged 30 bash -c "cd '$repoA' && bash '$XO' on --engine=copilot --model=another-model"
check "A22. both \`=\` forms on one line still record what they carried" \
  "[ '$CAGE_RC' = 0 ] && \"\$PY\" -c 'import json,sys
n=(json.load(open(sys.argv[1])).get(\"numberOne\") or {})
sys.exit(0 if n.get(\"engine\")==\"copilot\" and n.get(\"model\")==\"another-model\" else 1)' \
     '$repoA/.git/lcars/config.json'"

caged 60 bash -c "cd '$repoA' && bash '$XO' evaluate --mission=$MISSION"
check "A23. \`--mission=<id>\` still resolves the mission" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q '$MISSION'"

caged 30 bash -c "cd '$repoA' && bash '$XO' report --all --seen-entry=inline-key"
check "A24. \`--seen-entry=<key>\` still marks the key it carried" \
  "[ '$CAGE_RC' = 0 ] && grep -q 'inline-key' '$repoA/.git/lcars/xo-seen.json'"

# THE REFUSAL THAT MUST NOT HAVE BEEN WEAKENED. A cure for an over-permissive
# parse must not cost the parse its existing judgement: a genuinely unknown
# option is still an unknown option, named as itself.
caged 10 bash -c "cd '$repoA' && bash '$XO' on --bogus"
check "A25. \`xo on --bogus\` still refuses as an UNKNOWN OPTION, naming itself" \
  "[ '$CAGE_RC' != 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'unknown option: --bogus'"
caged 10 bash -c "cd '$repoA' && bash '$XO' on -x"
check "A26. ...and a short unknown option too" \
  "[ '$CAGE_RC' != 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'unknown option: -x'"

# NO SILENT MUTATION. The validator must judge a value, never rewrite one: a
# parse that trimmed what it was handed would be a quieter version of the same
# failure class — the captain's string changed and nothing said so.
caged 30 bash -c "cd '$repoA' && bash '$XO' on --model '  spaced  model  '"
check "A28. CONTROL — a value with surrounding spaces is recorded BYTE FOR BYTE, not trimmed" \
  "[ '$CAGE_RC' = 0 ] && \"\$PY\" -c 'import json,sys
n=(json.load(open(sys.argv[1])).get(\"numberOne\") or {})
sys.exit(0 if n.get(\"model\")==\"  spaced  model  \" else 1)' '$repoA/.git/lcars/config.json'"

caged 60 bash -c "cd '$repoA' && bash '$XO' evaluate --mission $MISSION --again --because=-it-drifted"
check "A27. CONTROL — a flag-shaped value in the \`=\` form is a VALUE, not a mistake (that is what \`=\` is for)" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && ! printf '%s' \"\$CAGE_OUT\" | grep -q 'was given'"

check "A21. ZERO SPEND across every control — the shim log is empty" \
  "[ ! -s '$SHIM_LOG' ]"

# ===========================================================================
# B. THE EIGHTEEN SITES: a flag LAST on the line refuses, by name, fast.
#
# Three assertions per site, because they are three different claims:
#   (i)  it TERMINATED — the cage did not have to kill it (rc != 124);
#   (ii) it REFUSED — non-zero, so a caller can tell;
#   (iii) it NAMED THE FLAG the captain got wrong, and it did so in under 5s.
# ===========================================================================
echo
printf -- '── B. a flag last on the line: eighteen sites, named, non-zero, fast ──\n'

repoB="$(new_repo)"
PFB="$TMPROOT/b.pid"

# site <label> <flag> <argv...>  — the flag under test is LAST in argv.
site() {
  local label="$1" flag="$2"; shift 2
  caged 5 bash -c "cd '$repoB' && bash '$XO' $*"
  check "$label — it TERMINATES (the cage did not have to kill it)" \
    "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 124 ]"
  check "$label — it REFUSES, non-zero (and not merely because it was killed)" \
    "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 0 ] && [ '$CAGE_RC' != 124 ]"
  check "$label — it NAMES \`$flag\`, in under 5s (elapsed ${CAGE_ELAPSED:-?}s)" \
    "printf '%s' \"\$CAGE_OUT\" | grep -qF -- '$flag' && faster_than 5"
}

site "B1.  xo on --engine"                 --engine       "on --engine"
site "B2.  xo on --model"                  --model        "on --model"
site "B3.  xo answer --mission"            --mission      "answer --mission"
site "B4.  xo evaluate --mission"          --mission      "evaluate --mission"
site "B5.  xo evaluate ... --because"      --because      "evaluate --mission $MISSION --again --because"
site "B6.  xo file-logs --mission"         --mission      "file-logs --mission"
site "B7.  xo recheck --mission"           --mission      "recheck --mission"
site "B8.  xo report --seen-entry"         --seen-entry   "report --seen-entry"
site "B9.  xo report --seen-mission"       --seen-mission "report --seen-mission"
site "B10. xo seed --mission"              --mission      "seed --mission"
site "B11. xo seed ... --in"               --in           "seed --mission $MISSION --in"
site "B12. xo unlisted --mission"          --mission      "unlisted --mission"
site "B13. xo unlisted ... --shots"        --shots        "unlisted --mission $MISSION --shots"
site "B14. xo unlisted ... --out"          --out          "unlisted --mission $MISSION --out"
site "B15. xo claim --mission"             --mission      "claim --mission"
site "B16. xo claim ... --hold"            --hold         "claim --mission $MISSION --hold"
site "B17. xo detach --pidfile"            --pidfile      "detach --pidfile"
site "B18. xo detach ... --log"            --log          "detach --pidfile '$PFB' --log"

# The headline reproduction, stated the way the ledger states it.
caged 5 bash -c "cd '$repoB' && E= ; bash '$XO' on --engine \$E"
check "B19. THE LEDGERED CASE — \`lcars xo on --engine \$E\` with \$E unset refuses instead of pegging a core" \
  "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 0 ] && [ '$CAGE_RC' != 124 ] && faster_than 5 \
   && printf '%s' \"\$CAGE_OUT\" | grep -qF -- '--engine'"

check "B20. still ZERO SPEND through every refusal" "[ ! -s '$SHIM_LOG' ]"

# ===========================================================================
# C. A FLAG-SHAPED VALUE NAMES THE FLAG THAT LOST ITS VALUE, not the next token.
#
# `xo on --engine --sweep` used to refuse with "'--sweep' is not an engine" —
# naming the one token that was NOT the mistake. `--sweep` was typed correctly;
# `--engine` is what the captain's empty variable emptied.
# ===========================================================================
echo
printf -- '── C. a flag-shaped value names the flag that lost its value ──\n'

repoC="$(new_repo)"
# THE SUBJECT OF THE SENTENCE IS THE TEST. Both tokens legitimately appear in
# the refusal — the flag that lost its value, and the option that drifted into
# its place by way of explanation. What must not happen is the drifted token
# being reported as the fault, which is what "'--sweep' is not an engine" did.
# So: the lost flag is mentioned FIRST, and the message never judges the other
# token as an unknown option or a bad engine name.
first_offset() { # <text> <needle> → 0-based index, or -1
  "$PY" - "$1" "$2" <<'P'
import sys
print(sys.argv[1].find(sys.argv[2]))
P
}
shaped() { # <label> <flag-that-lost-its-value> <not-this-token> <argv...>
  local label="$1" flag="$2" wrong="$3"; shift 3
  caged 10 bash -c "cd '$repoC' && bash '$XO' $*"
  check "$label — refuses non-zero" "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 0 ]"
  check "$label — names \`$flag\`, the flag that lost its value" \
    "printf '%s' \"\$CAGE_OUT\" | grep -qF -- '$flag'"
  local at_flag at_wrong
  at_flag="$(first_offset "$CAGE_OUT" "$flag")"
  at_wrong="$(first_offset "$CAGE_OUT" "$wrong")"
  check "$label — \`$flag\` is the SUBJECT: it is named before \`$wrong\` (at $at_flag vs $at_wrong)" \
    "[ '$at_flag' -ge 0 ] && [ '$at_wrong' -gt '$at_flag' ]"
  check "$label — and \`$wrong\` is never judged the fault (no \"unknown option\", no \"is not an engine\")" \
    "! printf '%s' \"\$CAGE_OUT\" | grep -qi 'unknown option' \
     && ! printf '%s' \"\$CAGE_OUT\" | grep -qF -- \"'$wrong' is not an engine\""
}
shaped "C1. xo on --engine --sweep"   --engine  --sweep "on --engine --sweep"
shaped "C2. xo on --model --no-sweep" --model   --no-sweep "on --model --no-sweep"
shaped "C3. xo evaluate --mission --again" --mission --again "evaluate --mission --again"
shaped "C4. xo on --engine --model copilot" --engine --model "on --engine --model copilot"

# ===========================================================================
# D. AN EMPTY OR BLANK VALUE IS THE SAME MISTAKE AS A MISSING ONE.
#
# `lcars xo on --engine ""` exited 0 at HEAD, engaged on the PREVIOUSLY RECORDED
# engine and said nothing about the engine it had been asked for — the exact
# failure class S309 cured in `update.sh --engine ''` (its D1): something did not
# happen and nothing said so.
# ===========================================================================
echo
printf -- '── D. an empty or blank value is a missing value ──\n'

repoD="$(new_repo)"
blank() { # <label> <flag> <argv...>
  local label="$1" flag="$2"; shift 2
  caged 10 bash -c "cd '$repoD' && bash '$XO' $*"
  check "$label — refuses non-zero, naming \`$flag\`" \
    "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 0 ] \
     && printf '%s' \"\$CAGE_OUT\" | grep -qF -- '$flag'"
}
blank "D1. xo on --engine ''"        --engine  "on --engine ''"
blank "D2. xo on --engine '   '"     --engine  "on --engine '   '"
blank "D3. xo on --model ''"         --model   "on --model ''"
blank "D4. xo answer --mission ''"   --mission "answer --mission ''"
blank "D5. xo claim --mission '$MISSION' --hold ''" --hold "claim --mission $MISSION --hold ''"
blank "D6. xo report --seen-entry ''" --seen-entry "report --seen-entry ''"

# THE `=` FORM'S OWN HOLE, minus the hang. `xo on --engine=` cannot spin — the
# value travels with the flag — but with an engine ALREADY RECORDED it exited 0
# at HEAD, engaged on that older engine, and never mentioned the one it was
# asked for. The same silent drop, reached a different way.
repoEq="$(new_repo)"
caged 30 bash -c "cd '$repoEq' && bash '$XO' on --engine copilot" >/dev/null 2>&1
eqblank() { # <label> <flag> <argv...>
  local label="$1" flag="$2"; shift 2
  caged 10 bash -c "cd '$repoEq' && bash '$XO' $*"
  check "$label — refuses non-zero, naming \`$flag\`" \
    "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 0 ] \
     && printf '%s' \"\$CAGE_OUT\" | grep -qF -- '$flag'"
}
eqblank "D8.  xo on --engine=" --engine "on --engine="
eqblank "D9.  xo on --model=" --model "on --model="
eqblank "D10. xo answer --mission=" --mission "answer --mission="
eqblank "D11. xo report --seen-entry=" --seen-entry "report --seen-entry="
eqblank "D12. xo report --seen-mission=" --seen-mission "report --seen-mission="
eqblank "D13. xo evaluate --mission=<id> --because=" --because "evaluate --mission=$MISSION --again --because="
check "D14. an empty \`--engine=\` left the RECORDED engine exactly as it was" \
  "\"\$PY\" -c 'import json,sys
n=(json.load(open(sys.argv[1])).get(\"numberOne\") or {})
sys.exit(0 if n.get(\"engine\")==\"copilot\" else 1)' '$repoEq/.git/lcars/config.json'"

check "D7. an empty \`--engine\` CHANGED NOTHING — the repo is still stood down" \
  "\"\$PY\" -c 'import json,sys
n=(json.load(open(sys.argv[1])).get(\"numberOne\") or {})
sys.exit(0 if n.get(\"enabled\") is not True else 1)' '$repoD/.git/lcars/config.json'"

# ===========================================================================
# E. THE SAME CLASS IN `lcars update` — S309's residual.
#
# S309 gave `--engine` and `--model` the flag-shaped-value rule and left
# `--test-command` out of it. MEASURED at HEAD: `lcars update --test-command
# --model` exits 0, prints `✓ testCommand set: --model`, and WRITES `--model`
# into config.json as the repo's test command — a success tick over a recorded
# string no shell can run.
# ===========================================================================
echo
printf -- '── E. lcars update: the same class, S309 residual ──\n'

repoE="$(new_repo)"
BEFORE="$TMPROOT/before.json"
ucase() { # <label> <flag> <argv...>
  local label="$1" flag="$2"; shift 2
  cp "$repoE/.git/lcars/config.json" "$BEFORE"
  caged 25 bash -c "cd '$repoE' && bash '$UPDATE' $*"
  check "$label — refuses non-zero, naming \`$flag\`" \
    "[ '$CAGE_TIMEDOUT' = 0 ] && [ '$CAGE_RC' != 0 ] \
     && printf '%s' \"\$CAGE_OUT\" | grep -qF -- '$flag'"
  check "$label — config.json is BYTE-IDENTICAL (nothing half-applied)" \
    "cmp -s '$BEFORE' '$repoE/.git/lcars/config.json'"
}
ucase "E1. update --test-command --model" --test-command "--test-command --model"
ucase "E2. update --test-command --probe-tests" --test-command "--test-command --probe-tests"
ucase "E3. update --test-command (trailing)" --test-command "--test-command"
ucase "E4. update --model --engine (trailing, both values absent)" --engine "--model --engine"
ucase "E5. update --engine --model (trailing, both values absent)" --engine "--engine --model"
ucase "E6. update --model --engine copilot" --model "--model --engine copilot"

# The control: a VALID --test-command still records.
cp "$repoE/.git/lcars/config.json" "$BEFORE"
caged 40 bash -c "cd '$repoE' && bash '$UPDATE' --test-command 'echo ran'"
check "E7. CONTROL — a valid \`--test-command '<cmd>'\` still records the command it was given" \
  "[ '$CAGE_RC' = 0 ] && \"\$PY\" -c 'import json,sys
sys.exit(0 if json.load(open(sys.argv[1])).get(\"testCommand\")==\"echo ran\" else 1)' \
   '$repoE/.git/lcars/config.json'"
caged 40 bash -c "cd '$repoE' && bash '$UPDATE' --engine copilot"
check "E8. CONTROL — a valid \`--engine copilot\` still records" \
  "[ '$CAGE_RC' = 0 ] && printf '%s' \"\$CAGE_OUT\" | grep -q 'engine recorded: copilot'"

# ===========================================================================
# F. THE ANTI-REGRESSION GUARD, WITH A KNOWN-GOOD CONTROL.
#
# The idiom is mechanical, which is exactly what makes it worth pinning: the
# next arm someone adds will be copied from the arm above it. The sweep is a
# FUNCTION so the planted-file control runs THE SAME CODE as the real scan — a
# guard proven only against a clean tree is a test that can only pass.
# ===========================================================================
echo
printf -- '── F. the guard, and proof it can SEE the pattern ──\n'

# THE PATTERN IS ASSEMBLED FROM PIECES, so this suite is never its own hit and
# the guard needs no exclusion list — an exclusion list is exactly where a real
# hit would go to hide. (The same trick hygiene.test.sh uses on its deny-list.)
#
# And `grep -F`, never a regex: the pattern carries `|` and `$`-adjacent text,
# and a regex that silently matches nothing reads exactly like a clean result —
# the method defect that corrupted five measurements in one night (D19).
BROKEN_IDIOM="shift 2 "'||'" true"
broken_shift_hits() { # <file...> → prints "file:line: text" for each hit
  [ "$#" -gt 0 ] || return 0
  grep -n -F "$BROKEN_IDIOM" "$@" 2>/dev/null
}

# AND THE STRING IS NOT THE DEFECT — MEASURED, THIS SESSION, 2026-10-23.
#
# `|| true` was never load-bearing. None of these scripts sets `-e` (they are
# all `set -uo pipefail`), so a BARE `shift 2` in a `while [ $# -gt 0 ]` loop
# spins exactly the same way: the shift fails, "$@" is untouched, the loop
# re-reads the flag forever. The `|| true` only made it survive a later `set -e`.
#
# PROVEN by driving six OTHER captain-facing scripts, none of which ever
# contained the swallowed form — `lcars approve --mission`, `lcars feedback
# --mission`, `lcars file --idea`, `lcars respond answer --mission`, `lcars log
# --parent`, `lcars run drive --mission`, each with the flag last. 6 OF 6 HUNG
# at a 6-second cage.
#
# So a guard that only greps the string would pass over a tree full of live
# hangs — the shape of a measurement that silently matches nothing (D19). This
# matcher looks for the SHAPE instead: an option arm that steps two places
# without a validator in front of it.
SPIN_SHAPE='^[[:space:]]*--[A-Za-z0-9-]+\)[^#]*shift 2([^0-9]|$)'
spin_shaped_arms() { # <file...> → "file:line: text" per spin-shaped arm
  [ "$#" -gt 0 ] || return 0
  grep -nE "$SPIN_SHAPE" "$@" 2>/dev/null | grep -v xo_argval
}

TRACKED=()
while IFS= read -r -d '' f; do TRACKED+=("$f"); done \
  < <(cd "$REPO_ROOT" && git ls-files -z -- '*.sh')
TRACKED_N="${#TRACKED[@]}"
TRACKED_SH="$TMPROOT/tracked-sh.txt"
printf '%s\n' "${TRACKED[@]:-}" >"$TRACKED_SH"

# THE SCAN'S OWN PRECONDITION. A file list that came back empty would make the
# guard below pass for the wrong reason, which is the whole of D19.
check "F1. the scan has something to scan — $TRACKED_N tracked *.sh files, and xo.sh is one of them" \
  "[ '$TRACKED_N' -gt 20 ] && grep -qx 'skills/lcars-xo/xo.sh' '$TRACKED_SH'"

HITS="$TMPROOT/hits.txt"; : >"$HITS"
SPIN="$TMPROOT/spin.txt"; : >"$SPIN"
if [ "$TRACKED_N" -gt 0 ]; then
  ( cd "$REPO_ROOT" && broken_shift_hits "${TRACKED[@]}" ) >"$HITS" 2>/dev/null
fi
HITS_N="$(wc -l <"$HITS" | tr -d ' ')"
check "F2. NO tracked shell source carries the swallowed two-place shift (found $HITS_N)" \
  "[ '$HITS_N' = 0 ] || { echo; sed 's/^/      /' '$HITS'; false; }"

( spin_shaped_arms "$XO" ) >"$SPIN" 2>/dev/null
SPIN_N="$(wc -l <"$SPIN" | tr -d ' ')"
check "F3. NO option arm in xo.sh steps two places without the validator (found $SPIN_N)" \
  "[ '$SPIN_N' = 0 ] || { echo; sed 's/^/      /' '$SPIN'; false; }"

# THE KNOWN-GOOD CONTROLS: the same two functions, over a file that HAS the
# idiom — in BOTH the swallowed form and the bare one, because the bare one is
# the form that was measured hanging and the form a future arm will be written
# in.
PLANT="$TMPROOT/plant.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'while [ $# -gt 0 ]; do\n'
  printf '  case "$1" in\n'
  printf '    --engine) engine="${2:-}"; %s ;;\n' "$BROKEN_IDIOM"
  printf '    --model)  model="${2:-}"; shift 2 ;;\n'
  printf '  esac\n'
  printf 'done\n'
} >"$PLANT"
check "F4. KNOWN-GOOD CONTROL — the string sweep finds the swallowed form when present" \
  "[ \"\$(broken_shift_hits '$PLANT' | wc -l | tr -d ' ')\" = 1 ]"
check "F5. KNOWN-GOOD CONTROL — the shape sweep finds BOTH planted arms, bare one included" \
  "[ \"\$(spin_shaped_arms '$PLANT' | wc -l | tr -d ' ')\" = 2 ]"

# And the negative half: a file with the CURED idiom is flagged by neither.
CLEAN="$TMPROOT/clean.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf 'while [ $# -gt 0 ]; do\n'
  printf '  case "$1" in\n'
  printf '    --engine) xo_argval "$1" "${@:2:1}"; engine="$XO_ARGVAL"; shift 2 ;;\n'
  printf '  esac\n'
  printf 'done\n'
} >"$CLEAN"
check "F6. ...and neither flags the cured arm (no false positive)" \
  "[ \"\$(broken_shift_hits '$CLEAN' | wc -l | tr -d ' ')\" = 0 ] \
   && [ \"\$(spin_shaped_arms '$CLEAN' | wc -l | tr -d ' ')\" = 0 ]"

# The cure is actually APPLIED, not merely absent. 18 spin-shaped arms were
# found; 18 must call the validator, because a fix that leaves seventeen spins
# reads as done and is worse than none.
ARGVAL_DEFINED=0; grep -q '^xo_argval()' "$XO" && ARGVAL_DEFINED=1
INLINE_DEFINED=0; grep -q '^xo_argval_inline()' "$XO" && INLINE_DEFINED=1
ARGVAL_CALLS="$(grep -c 'xo_argval "\$1" "\${@:2:1}"' "$XO" | tr -d ' ')"
INLINE_CALLS="$(grep -c 'xo_argval_inline --' "$XO" | tr -d ' ')"
check "F7. the cure is present — \`xo_argval\` and \`xo_argval_inline\` are both defined" \
  "[ '$ARGVAL_DEFINED' = 1 ] && [ '$INLINE_DEFINED' = 1 ]"
check "F8. ALL EIGHTEEN spin-shaped arms call the validator (found $ARGVAL_CALLS)" \
  "[ '$ARGVAL_CALLS' -ge 18 ]"
check "F9. ...and all NINE \`=\`-form arms call the inline one (found $INLINE_CALLS)" \
  "[ '$INLINE_CALLS' -ge 9 ]"

# ───────────────────────────────────────────────────────────────────────────
# F10 — THE DEBT, NAMED, AND RATCHETED SO IT CAN ONLY SHRINK.
#
# S319 cured `xo.sh` and `update.sh --test-command`. It did NOT cure the other
# product scripts, and that is a scoping decision, not a clean result: 100
# spin-shaped arms remain across 13 files, 6 of which were MEASURED HANGING
# (see the note on spin_shaped_arms above). `ech.sh` (29), `run.sh` (20) and
# `host-adapter.sh` (19) carry two thirds of it, and they are the three files a
# session cannot verify without the full suite — which is why they were left.
#
# This row exists so the number is in the test output rather than in a ledger
# nobody greps, and so it can only go DOWN. If it trips because a NEW arm was
# written in the old shape, that is exactly its job.
# ───────────────────────────────────────────────────────────────────────────
OTHERS=()
while IFS= read -r -d '' f; do
  case "$f" in skills/lcars-xo/xo.sh) ;; *) OTHERS+=("$f") ;; esac
done < <(cd "$REPO_ROOT" && git ls-files -z -- 'skills/*.sh')
DEBT="$TMPROOT/debt.txt"; : >"$DEBT"
if [ "${#OTHERS[@]}" -gt 0 ]; then
  ( cd "$REPO_ROOT" && spin_shaped_arms "${OTHERS[@]}" ) >"$DEBT" 2>/dev/null
fi
DEBT_N="$(wc -l <"$DEBT" | tr -d ' ')"
printf '      known debt, per file (NOT cured by S319 — see the note above):\n'
cut -d: -f1 <"$DEBT" | sort | uniq -c | sort -rn | sed 's/^/        /'
check "F10. the uncured spin-shaped arms in the OTHER product scripts can only shrink from 100 (now $DEBT_N)" \
  "[ '$DEBT_N' -le 100 ] && [ '$DEBT_N' -gt 0 ]"

echo
echo "────────────────────────────────────────────────"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
