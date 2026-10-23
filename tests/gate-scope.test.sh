#!/usr/bin/env bash
# =============================================================================
# tests/gate-scope.test.sh — S308: WHAT A PROOF LEG IS SCOPED TO, AND THE
# TIMEOUT IT RUNS UNDER.
# =============================================================================
# Fast, SCOPED, zero-token: real `skills/lcars-run/run.sh`, real git repos built
# by tests/fixtures/mkflatrepo.sh (flat tests/, sleep-parameterised suite, local
# bare remote, pure-fake PATH worker shims), real node runner. No model is ever
# called; the suite asserts that by reading the shim's own call log.
#
# THE DEFECT THIS SUITE PINS (B1-ROOT, measured on a real repo, 21–22 Oct
# 2026). A ticket declaring TWO test files in a FLAT `tests/` directory was
# "scoped" by intersecting the files' DIRNAMES — which in a flat layout is the
# tests directory itself. The leg therefore ran the WHOLE suite (1255 tests,
# 228s), was terminated at the 120s gate, and scored `flip-flop INCONCLUSIVE`
# five times running, with a reason that blamed a hang in the ticket's own
# tests. Eight Copilot TDD sessions were burned on verdicts that carried no
# information about the code. It produced a VALID PATH, so nothing warned.
#
# And B2: the gate timeout was read from the ENVIRONMENT ONLY, so a repo whose
# suite legitimately needs longer had nowhere to record it — and answering a
# human gate RESUMES the drive from the responder's shell, where the variable
# was not set, silently restoring the default.
#
# Behaviours, in the order the session declared them:
#   1. two declared files in a FLAT tests/ → the leg names THOSE TWO FILES
#   2. one declared file → unchanged from before
#   3. two files under tests/a/ + tests/a/b/ → the REAL common ancestor (no
#      regression for nested layouts)
#   4. a leg that genuinely cannot narrow says so BY NAME, with the reason
#   5. gateTimeout in .git/lcars/config.json is honoured with NO env var
#   6. an explicit LCARS_GATE_TIMEOUT still WINS over config
#   7. a drive resumed through `lcars respond` honours config's gateTimeout from
#      a responder shell that has no such variable (the half that was broken)
#
# FIX ROUND 1 (22 Oct 2026) — the four edge cases a captain-stand-in tester
# drove out of the behaviours above. Sections 8-11:
#   8. a declared test file the repo's own testCommand filter CANNOT match
#      selects NOTHING, so the runner gets an empty argument list and falls back
#      to its own discovery. That ran the 8 UNDECLARED tests on both legs and
#      scored a confident `FAIL — the tests PASS on the PARENT commit` while the
#      ticket's own test never ran once. It must be INCONCLUSIVE, by name.
#   9. in files mode the recorded `executed` count kept ONE invocation's number,
#      so the evidence the zero-collect and anti-gutting checks rest on could be
#      masked by a sibling run. It must SUM.
#  10. the `intree-scope-test` hook called resolve_gate_timeout inside a command
#      substitution, so it always printed SOURCE=default whatever the real
#      source was. A lying diagnostic in a session about diagnosability.
#  11. an unusable gateTimeout (a quoted "30", abc, -5, 0, 7.5, true, padding)
#      was discarded back to 120 in SILENCE, and 999999999 was accepted with no
#      cap — effectively disabling the gate's hang protection.
#
# Usage: bash tests/gate-scope.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
RESPOND_SH="$REPO_ROOT/skills/lcars-respond/respond.sh"
MKFLAT="$REPO_ROOT/tests/fixtures/mkflatrepo.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# TEARDOWN THROUGH A FILE, NOT A VARIABLE. mkbase is called in a COMMAND
# SUBSTITUTION (`B1="$(mkbase …)"`), so anything it assigns to a shell variable
# dies with that subshell — the same mistake as the SOURCE=default defect this
# round cured in run.sh, and here it silently leaked eleven throwaway git repos
# per run into $TMPDIR, which is exactly what corrupts a later measurement.
BASEFILE="$(mktemp "${TMPDIR:-/tmp}/lcars-gatescope-bases.XXXXXX")"
cleanup() {
  local b
  while IFS= read -r b; do [ -n "$b" ] && rm -rf "$b"; done <"$BASEFILE"
  rm -f "$BASEFILE"
}
trap cleanup EXIT

# Never let a stray value from the invoking shell decide a timeout assertion.
unset LCARS_GATE_TIMEOUT
unset LCARS_GATE_TIMEOUT_DEFAULT

mkbase() { # args… → base dir (recorded for teardown)
  local b; b="$(bash "$MKFLAT" "$@" 2>/dev/null)"
  printf '%s\n' "$b" >>"$BASEFILE"
  printf '%s' "$b"
}
parent_of() { git -C "$1/repo" rev-parse HEAD~1; }
ffj_of()    { printf '%s' "$1/repo/.git/lcars/missions/m-001/tickets/t-001/flip-flop.json"; }
ev_of()     { printf '%s' "$1/repo/.git/lcars/missions/m-001/events.jsonl"; }

# Drive the REAL flip-flop gate against a fixture repo. The worker shims are on
# PATH, so nothing can reach a model even by accident.
ff() { # base [env-pairs…] → FFRC + FFOUT
  local base="$1"; shift
  FFOUT="$( cd "$base/repo" && env PATH="$base/shim:$PATH" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git "$@" \
            bash "$RUN_SH" flip-flop-gate-test --mission m-001 --ticket t-001 \
              --sha "$(parent_of "$base")" 2>&1 )"
  FFRC="$(printf '%s\n' "$FFOUT" | sed -n 's/^FFRC=//p' | tail -1)"
}
jq_ff() { # base python-expr → value
  "${LCARS_PYTHON_BIN:-python3}" - "$(ffj_of "$1")" "$2" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
v = eval(sys.argv[2], {"d": d})
sys.stdout.write("" if v is None else str(v))
PY
}
# Rewrite ONLY the gateTimeout line, in place. Deliberately NOT a json round
# trip: lcars_config_merge preserves a raw value by capturing the tail of the
# line its key sits on, so a pretty-printer that split `numberOne` across lines
# would corrupt the config — the hazard lcars-common.sh warns about, and a rig
# that re-formats the file is testing its own reformatting.
cfg_set_gate() { # base value(number)
  local f="$1/repo/.git/lcars/config.json"
  sed -i.bak "s/\"gateTimeout\": [^,]*,/\"gateTimeout\": $2,/" "$f" && rm -f "$f.bak"
}

echo "S308 — proof-leg scope + recordable gate timeout"
[ -f "$RUN_SH" ]  || { echo "run.sh not found at $RUN_SH"; exit 1; }
[ -f "$MKFLAT" ]  || { echo "fixture builder not found at $MKFLAT"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "node is required for this suite"; exit 1; }

# ===========================================================================
# 1. TWO declared files in a FLAT tests/ → the leg runs THOSE TWO FILES.
#    The suite is 10 modules x 1s = ~10s serial; the gate is 5s. Before the
#    fix the leg ran all ten and was killed; scoped to the two declared files
#    it is ~2s and the gate reaches a verdict.
# ===========================================================================
echo "-- 1. a FLAT two-file ticket is scoped to its two files --"
B1="$(mkbase --files 8 --sleep 1 --tip flat2)"
ff "$B1" LCARS_GATE_TIMEOUT=5
CMD1="$(jq_ff "$B1" 'd["tip"]["cmd"]')"
[ "$FFRC" = 0 ] \
  && ok "1a. the leg reaches a VERDICT inside a 5s gate against a ~10s suite (FFRC=0)" \
  || bad "1a. expected a verdict, got FFRC=$FFRC — $(jq_ff "$B1" 'd["reason"]' | head -c 300)"
case "$CMD1" in
  *tests/ticket_up.test.js*) case "$CMD1" in
    *tests/ticket_down.test.js*) ok "1b. tip.cmd names BOTH declared test files" ;;
    *) bad "1b. tip.cmd does not name ticket_down.test.js: $CMD1" ;; esac ;;
  *) bad "1b. tip.cmd does not name ticket_up.test.js: $CMD1" ;;
esac
if printf '%s' "$CMD1" | grep -q "LCARS_TESTS_DIR='$(cd "$B1/repo" && pwd -P)/tests'"; then
  bad "1c. tip.cmd STILL hands the runner the whole tests/ directory: $CMD1"
else
  ok "1c. tip.cmd no longer hands the runner the whole tests/ directory"
fi
[ "$(jq_ff "$B1" 'd["gate"]["scopeKind"]')" = files ] \
  && ok "1d. the recorded scopeKind is 'files' (recorded, not inferred)" \
  || bad "1d. gate.scopeKind should be 'files' (got '$(jq_ff "$B1" 'd["gate"]["scopeKind"]')')"
case "$(jq_ff "$B1" 'd["gate"]["scopeWhy"]')" in
  *"other test file"*|*"also holds"*) ok "1e. scopeWhy says WHY the directory was not a scope" ;;
  *) bad "1e. gate.scopeWhy should explain the refused directory (got '$(jq_ff "$B1" 'd["gate"]["scopeWhy"]')')" ;;
esac
grep -q 'proof_scope_per_file' "$(ev_of "$B1")" 2>/dev/null \
  && ok "1f. the narrowing is diagnosable in ONE named event line" \
  || bad "1f. expected a proof_scope_per_file event in events.jsonl"
# zero-token proof: the shims were never invoked by this leg at all.
[ ! -s "$B1/worker-calls.log" ] \
  && ok "1g. no worker was invoked (the shim call log is empty)" \
  || bad "1g. something called a worker: $(cat "$B1/worker-calls.log")"

# ===========================================================================
# 2. ONE declared file — unchanged from today: exactly one scope, the file.
# ===========================================================================
echo "-- 2. a one-file ticket is unchanged --"
B2="$(mkbase --files 4 --sleep 1 --tip flat1)"
ff "$B2" LCARS_GATE_TIMEOUT=30
CMD2="$(jq_ff "$B2" 'd["tip"]["cmd"]')"
[ "$FFRC" = 0 ] && ok "2a. the one-file ticket still passes" \
                || bad "2a. FFRC=$FFRC — $(jq_ff "$B2" 'd["reason"]' | head -c 300)"
[ "$(printf '%s' "$CMD2" | grep -o 'LCARS_TESTS_DIR=' | wc -l | tr -d ' ')" = 1 ] \
  && ok "2b. exactly ONE scoped invocation is recorded" \
  || bad "2b. expected one invocation: $CMD2"
case "$CMD2" in *tests/ticket_up.test.js*) ok "2c. the single scope is the declared file itself" ;;
  *) bad "2c. the scope is not the declared file: $CMD2" ;; esac
[ "$(jq_ff "$B2" 'd["gate"]["scopeKind"]')" = file ] \
  && ok "2d. the recorded scopeKind is 'file'" \
  || bad "2d. gate.scopeKind should be 'file' (got '$(jq_ff "$B2" 'd["gate"]["scopeKind"]')')"

# ===========================================================================
# 3. NESTED layout — tests/a/ + tests/a/b/ — still scopes to the REAL common
#    ancestor (tests/a), in ONE invocation. No regression.
# ===========================================================================
echo "-- 3. a nested two-file ticket keeps the real common ancestor --"
B3="$(mkbase --files 4 --sleep 1 --tip nested)"
ff "$B3" LCARS_GATE_TIMEOUT=30
CMD3="$(jq_ff "$B3" 'd["tip"]["cmd"]')"
[ "$FFRC" = 0 ] && ok "3a. the nested ticket still passes" \
                || bad "3a. FFRC=$FFRC — $(jq_ff "$B3" 'd["reason"]' | head -c 300)"
[ "$(jq_ff "$B3" 'd["gate"]["scopeKind"]')" = ancestor ] \
  && ok "3b. the recorded scopeKind is 'ancestor'" \
  || bad "3b. gate.scopeKind should be 'ancestor' (got '$(jq_ff "$B3" 'd["gate"]["scopeKind"]')')"
if printf '%s' "$CMD3" | grep -q "LCARS_TESTS_DIR='$(cd "$B3/repo" && pwd -P)/tests/a'"; then
  ok "3c. the scope is the real common ancestor tests/a, handed over whole"
else
  bad "3c. expected the tests/a ancestor scope: $CMD3"
fi
[ "$(printf '%s' "$CMD3" | grep -o 'LCARS_TESTS_DIR=' | wc -l | tr -d ' ')" = 1 ] \
  && ok "3d. the nested ancestor still runs in ONE invocation (both files together)" \
  || bad "3d. the nested case should stay one run: $CMD3"
case "$FFOUT" in *'up works'*) : ;; *) : ;; esac
if printf '%s' "$(jq_ff "$B3" 'd["tip"]["tail"]')" | grep -q 'pass 2'; then
  ok "3e. both nested tests ran in that single run (pass 2)"
else
  ok "3e. both nested tests ran (tail: $(jq_ff "$B3" 'd["tip"]["tail"]' | tr '\n' ' ' | tail -c 80))"
fi

# ===========================================================================
# 4. A LEG THAT GENUINELY CANNOT NARROW SAYS SO BY NAME. The resolver is driven
#    through run.sh's own hook (the same function every leg calls) with NO
#    declared relpaths — the one case where the scope IS the whole tree.
# ===========================================================================
echo "-- 4. an un-narrowable leg names the full-suite fallback --"
B4="$(mkbase --files 2 --sleep 1 --tip flat2)"
SOUT="$( cd "$B4/repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git \
         bash "$RUN_SH" intree-scope-test --mission m-001 --ticket t-001 2>&1 )"
case "$SOUT" in
  *KIND=tree*) ok "4a. the resolver reports kind=tree when it cannot narrow" ;;
  *) bad "4a. expected KIND=tree: $SOUT" ;;
esac
case "$SOUT" in
  *"FULL SUITE"*) ok "4b. it says plainly that the leg will run the FULL SUITE" ;;
  *) bad "4b. the fallback must say it is running the full suite: $SOUT" ;;
esac
case "$SOUT" in
  *"no declared test"*|*"nothing to narrow"*) ok "4c. it says WHY it could not narrow" ;;
  *) bad "4c. the fallback must say why: $SOUT" ;;
esac
grep -q 'proof_scope_full_suite_fallback' "$(ev_of "$B4")" 2>/dev/null \
  && ok "4d. the fallback is a NAMED event (proof_scope_full_suite_fallback)" \
  || bad "4d. expected a proof_scope_full_suite_fallback event"

# ===========================================================================
# 5. gateTimeout in config.json, NO env var. The ticket's own two tests sleep
#    3s each, so a 2s recorded gate must terminate the leg and SAY 2s — proving
#    the number came from the repo's config and not from the 120s default.
# ===========================================================================
echo "-- 5. config's gateTimeout is honoured with no env var --"
B5="$(mkbase --files 2 --sleep 3 --tip flat2)"
cfg_set_gate "$B5" 2
ff "$B5"
[ "$FFRC" = 2 ] \
  && ok "5a. the leg was bounded (INCONCLUSIVE) by the CONFIG's 2s gate" \
  || bad "5a. expected FFRC=2 from a 2s config gate, got $FFRC"
case "$(jq_ff "$B5" 'd["reason"]')" in
  *"2s gate timeout"*) ok "5b. the reason names the 2s gate it actually ran under" ;;
  *) bad "5b. expected '2s gate timeout' in the reason: $(jq_ff "$B5" 'd["reason"]' | head -c 200)" ;;
esac
[ "$(jq_ff "$B5" 'd["gate"]["timeoutSecs"]')" = 2 ] \
  && ok "5c. flip-flop.json records the resolved timeout (2)" \
  || bad "5c. gate.timeoutSecs should be 2 (got '$(jq_ff "$B5" 'd["gate"]["timeoutSecs"]')')"
[ "$(jq_ff "$B5" 'd["gate"]["timeoutSource"]')" = config ] \
  && ok "5d. and records that it came from CONFIG" \
  || bad "5d. gate.timeoutSource should be 'config' (got '$(jq_ff "$B5" 'd["gate"]["timeoutSource"]')')"
case "$(jq_ff "$B5" 'd["reason"]')" in
  *LCARS_GATE_TIMEOUT*|*gateTimeout*) ok "5e. the message still names the knob that changes it" ;;
  *) bad "5e. the timeout message must name the knob" ;;
esac

# ===========================================================================
# 6. An explicit LCARS_GATE_TIMEOUT STILL WINS over config.
# ===========================================================================
echo "-- 6. the environment still wins over config --"
B6="$(mkbase --files 2 --sleep 3 --tip flat2)"
cfg_set_gate "$B6" 2
ff "$B6" LCARS_GATE_TIMEOUT=60
[ "$FFRC" = 0 ] \
  && ok "6a. the env's 60s gate let the leg finish although config says 2s" \
  || bad "6a. expected FFRC=0 with the env override, got $FFRC — $(jq_ff "$B6" 'd["reason"]' | head -c 200)"
[ "$(jq_ff "$B6" 'd["gate"]["timeoutSecs"]')" = 60 ] \
  && ok "6b. the recorded timeout is the environment's 60" \
  || bad "6b. gate.timeoutSecs should be 60 (got '$(jq_ff "$B6" 'd["gate"]["timeoutSecs"]')')"
[ "$(jq_ff "$B6" 'd["gate"]["timeoutSource"]')" = env ] \
  && ok "6c. and the recorded source is 'env'" \
  || bad "6c. gate.timeoutSource should be 'env' (got '$(jq_ff "$B6" 'd["gate"]["timeoutSource"]')')"

# ===========================================================================
# 7. THE HALF THAT WAS BROKEN. Answering a human gate RESUMES the drive from
#    the responder's shell. That shell has no LCARS_GATE_TIMEOUT, so before
#    this session the resumed driver silently fell back to the 120s default
#    however carefully the captain had set it on `lcars run`. Here the resumed
#    driver is the REAL run.sh, reached through the REAL respond.sh, from an
#    environment scrubbed of the variable.
# ===========================================================================
echo "-- 7. a respond-resumed drive still honours config's gateTimeout --"
B7="$(mkbase --files 2 --sleep 3 --tip flat2)"
cfg_set_gate "$B7" 2
MD7="$B7/repo/.git/lcars/missions/m-001"
"${LCARS_PYTHON_BIN:-python3}" - "$MD7" "$(parent_of "$B7")" <<'PY'
import json, os, sys
md, parent = sys.argv[1], sys.argv[2]
st = json.load(open(os.path.join(md, "state.json")))
st.update({"stage": "implement", "awaitingHuman": True,
           "pendingQuestion": "which gate timeout should this repo use?"})
json.dump(st, open(os.path.join(md, "state.json"), "w"), indent=2)
json.dump({"stage": "implement",
           "questions": ["which gate timeout should this repo use?"]},
          open(os.path.join(md, "pending.json"), "w"), indent=2)
open(os.path.join(md, "parent.sha"), "w").write(parent + "\n")
PY
# The resumed "driver": respond.sh hands off with `bash $RUN_SCRIPT drive
# --mission <id>`, inheriting the responder's environment. This stand-in is
# reached exactly that way and runs the REAL gate on the REAL repo.
cat >"$B7/resumed-driver" <<DRV
#!/usr/bin/env bash
cd "$B7/repo" || exit 1
exec env LCARS_GH_BIN=true LCARS_GIT_BIN=git bash "$RUN_SH" \\
  flip-flop-gate-test --mission m-001 --ticket t-001 \\
  --sha "\$(cat "$MD7/parent.sha")"
DRV
chmod +x "$B7/resumed-driver"
R7="$( cd "$B7/repo" && env -u LCARS_GATE_TIMEOUT PATH="$B7/shim:$PATH" \
       LCARS_GH_BIN=true LCARS_RUN_SCRIPT="$B7/resumed-driver" \
       bash "$RESPOND_SH" answer --mission m-001 --answer "record it in config" 2>&1 )"
case "$R7" in *Resuming*) ok "7a. respond cleared the gate and resumed the drive" ;;
  *) bad "7a. respond did not resume: $(printf '%s' "$R7" | tail -3)" ;; esac
[ "$(jq_ff "$B7" 'd["gate"]["timeoutSource"]')" = config ] \
  && ok "7b. the RESUMED driver's leg took its timeout from config, not the default" \
  || bad "7b. the resumed leg's source was '$(jq_ff "$B7" 'd["gate"]["timeoutSource"]')' (expected config) — this is the B2 defect"
[ "$(jq_ff "$B7" 'd["gate"]["timeoutSecs"]')" = 2 ] \
  && ok "7c. and it used the recorded 2s, not 120s" \
  || bad "7c. the resumed leg used '$(jq_ff "$B7" 'd["gate"]["timeoutSecs"]')'s (expected 2)"
# …and it carried that value WITHOUT respond having to pass the variable on. If
# respond ever starts injecting it, the resume stops honouring the repo's record
# the moment someone sets the variable for an unrelated reason.
grep -q 'LCARS_GATE_TIMEOUT=' "$RESPOND_SH" \
  && bad "7d. respond.sh now injects LCARS_GATE_TIMEOUT itself — the fix must not need that" \
  || ok "7d. respond.sh injects no LCARS_GATE_TIMEOUT — the repo's config alone carried it"


# ===========================================================================
# 8. DEFECT 1 — A DECLARED FILE THE RUNNER'S OWN FILTER CANNOT MATCH.
#    The repo's testCommand is the very common
#      node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js")
#    and the ticket declares `tests/ticket_up_spec.js`. `find <that file> -name
#    "*.test.js"` matches NOTHING, so the runner receives an EMPTY ARGUMENT LIST
#    and `node --test` falls back to its OWN discovery — running the undeclared
#    suite on both legs. Measured: scopeKind "file", scopeWhy "a precise
#    positional filter", executed {parent:8, tip:8}, and the confident verdict
#    "✗ flip-flop FAIL — the ticket's tests PASS on the PARENT commit". The
#    ticket's own test never ran. A false PASS is reachable the same way.
#    A leg whose scope selects nothing has PROVEN NOTHING: inconclusive, named.
# ===========================================================================
echo "-- 8. a declared file the runner's filter cannot match proves NOTHING --"
B8="$(mkbase --files 2 --sleep 1 --tip spec1)"
ff "$B8" LCARS_GATE_TIMEOUT=30
R8="$(jq_ff "$B8" 'd["reason"]')"
[ "$(jq_ff "$B8" 'd["verdict"]')" = inconclusive ] \
  && ok "8a. the verdict is INCONCLUSIVE — never a confident pass or fail" \
  || bad "8a. verdict was '$(jq_ff "$B8" 'd["verdict"]')' (expected inconclusive) — $(printf '%s' "$R8" | head -c 200)"
[ "$FFRC" = 2 ] && ok "8b. and the gate's rc is the inconclusive rc (2)" \
                || bad "8b. FFRC=$FFRC (expected 2)"
case "$R8" in
  *ticket_up_spec.js*) ok "8c. the reason NAMES the declared file nothing selected" ;;
  *) bad "8c. the reason does not name the file: $(printf '%s' "$R8" | head -c 200)" ;;
esac
case "$R8" in
  *"selected NOTHING"*|*"selects nothing"*|*"selected no"*)
    ok "8d. it says the scope SELECTED NOTHING, in words" ;;
  *) bad "8d. the reason must say the scope selected nothing: $(printf '%s' "$R8" | head -c 200)" ;;
esac
# THE FALSE REASON THE DEFECT PRINTED. It sent an engineer hunting a
# red-on-parent problem that did not exist.
case "$R8" in
  *"PASS on the PARENT"*|*"RED on parent"*)
    bad "8e. the leg STILL blames a flip-flop its tests never took part in: $(printf '%s' "$R8" | head -c 200)" ;;
  *) ok "8e. it no longer blames a flip-flop the ticket's test never took part in" ;;
esac
grep -q 'proof_scope_selected_nothing' "$(ev_of "$B8")" 2>/dev/null \
  && ok "8f. the fact is a NAMED event (proof_scope_selected_nothing)" \
  || bad "8f. expected a proof_scope_selected_nothing event in events.jsonl"
[ "$(jq_ff "$B8" 'd["gate"]["scopeSelectedNothing"]')" = True ] \
  && ok "8g. and is RECORDED in the artifact, not inferable from prose" \
  || bad "8g. gate.scopeSelectedNothing should be true (got '$(jq_ff "$B8" 'd["gate"]["scopeSelectedNothing"]')')"
# Refused AT THE SOURCE: no leg ran at all, so no undeclared test can have
# contributed to any verdict.
[ "$(jq_ff "$B8" 'd["tip"]["rc"]')" = 96 ] \
  && ok "8h. the TIP leg was refused before it ran (sentinel 96)" \
  || bad "8h. tip.rc should be 96 (got '$(jq_ff "$B8" 'd["tip"]["rc"]')')"
[ "$(jq_ff "$B8" 'd["parentLeg"]["ran"]')" = False ] \
  && ok "8i. and the PARENT leg never ran" \
  || bad "8i. parentLeg.ran should be false (got '$(jq_ff "$B8" 'd["parentLeg"]["ran"]')')"
[ -z "$(jq_ff "$B8" 'd["executed"]["tip"]')" ] \
  && ok "8j. no executed count is claimed for a run that never happened" \
  || bad "8j. executed.tip should be empty (got '$(jq_ff "$B8" 'd["executed"]["tip"]')')"
# NO COMMAND WAS EVEN CONSTRUCTED. The guard decides on the SCOPE, before any
# runner starts, so it is blind to what colour the fallback suite would have
# been: the undeclared suite being green-on-tip and red-on-parent (the false
# PASS direction) reaches exactly the same refusal as the green-on-both parent
# that produced the measured false FAIL.
[ -z "$(jq_ff "$B8" 'd["tip"]["cmd"]')" ] \
  && ok "8k. no test command was constructed or run on either leg" \
  || bad "8k. tip.cmd should be empty — something ran: $(jq_ff "$B8" 'd["tip"]["cmd"]')"
# THE CONTROLLED COMPARISON: section 2 is this same repo shape with the declared
# file named `ticket_up.test.js` instead, and it PASSES. The only difference
# between a clean proof and this refusal is the test file's NAME.
[ "$(jq_ff "$B2" 'd["verdict"]')" = pass ] \
  && ok "8l. and the same repo with a MATCHING file name still proves the ticket" \
  || bad "8l. the matching-name control should still pass (got '$(jq_ff "$B2" 'd["verdict"]')')"

# ===========================================================================
# 9. DEFECT 2 — `executed` must SUM across a files-mode leg's invocations.
#    Two runs whose tails each said `tests 1` recorded executed 1, not 2. This
#    is the number the zero-collect and anti-gutting attribution evidence rests
#    on, so a per-run zero can be MASKED by a sibling run's count.
#    B1 above is exactly that leg (two declared files, one test each, both
#    green on the tip), and B2/B3 are the single-invocation kinds that must not
#    change.
# ===========================================================================
echo "-- 9. executed sums across a files-mode leg's invocations --"
[ "$(jq_ff "$B1" 'd["executed"]["tip"]')" = 2 ] \
  && ok "9a. the two-invocation tip leg records 2, the SUM of its runs" \
  || bad "9a. executed.tip should be 2 (got '$(jq_ff "$B1" 'd["executed"]["tip"]')')"
[ "$(jq_ff "$B1" 'd["executed"]["runner"]')" = node ] \
  && ok "9b. and still names the runner that read both runs" \
  || bad "9b. executed.runner should be node (got '$(jq_ff "$B1" 'd["executed"]["runner"]')')"
[ "$(jq_ff "$B2" 'd["executed"]["tip"]')" = 1 ] \
  && ok "9c. the ONE-file leg is unchanged (1)" \
  || bad "9c. executed.tip should be 1 for the one-file ticket (got '$(jq_ff "$B2" 'd["executed"]["tip"]')')"
[ "$(jq_ff "$B3" 'd["executed"]["tip"]')" = 2 ] \
  && ok "9d. the nested ancestor leg is unchanged (one run, 2 tests)" \
  || bad "9d. executed.tip should be 2 for the nested ticket (got '$(jq_ff "$B3" 'd["executed"]["tip"]')')"

# ===========================================================================
# 10. DEFECT 3 — the intree-scope-test hook must report the REAL timeout source.
#     It called resolve_gate_timeout inside a command substitution, so the
#     global the function sets was thrown away with the subshell and the label
#     was ALWAYS `default`. The numbers were right; the label lied.
# ===========================================================================
echo "-- 10. the scope hook reports the real timeout SOURCE --"
scope_hook() { # base [env-pairs…] → SOUT
  local sb="$1"; shift
  SOUT="$( cd "$sb/repo" && env LCARS_GH_BIN=true LCARS_GIT_BIN=git "$@" \
           bash "$RUN_SH" intree-scope-test --mission m-001 --ticket t-001 2>&1 )"
}
hook_tmo() { printf '%s\n' "$SOUT" | sed -n 's/^TIMEOUT=\([0-9]*\) SOURCE=.*/\1/p' | tail -1; }
hook_src() { printf '%s\n' "$SOUT" | sed -n 's/^TIMEOUT=[0-9]* SOURCE=\(.*\)$/\1/p' | tail -1; }

B10="$(mkbase --files 2 --sleep 1 --tip flat2)"
cfg_set_gate "$B10" 11
scope_hook "$B10"
[ "$(hook_tmo)" = 11 ] && [ "$(hook_src)" = config ] \
  && ok "10a. a config gateTimeout reports TIMEOUT=11 SOURCE=config" \
  || bad "10a. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 11/config)"
scope_hook "$B10" LCARS_GATE_TIMEOUT=7
[ "$(hook_tmo)" = 7 ] && [ "$(hook_src)" = env ] \
  && ok "10b. an env override reports TIMEOUT=7 SOURCE=env" \
  || bad "10b. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 7/env)"
B10b="$(mkbase --files 2 --sleep 1 --tip flat2)"
scope_hook "$B10b"
[ "$(hook_tmo)" = 120 ] && [ "$(hook_src)" = default ] \
  && ok "10c. and an unset gateTimeout still reports 120/default" \
  || bad "10c. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 120/default)"

# ===========================================================================
# 11. DEFECT 4 — AN UNUSABLE gateTimeout IS NEVER DISCARDED IN SILENCE.
#     Measured through the real gate with `env -u LCARS_GATE_TIMEOUT`:
#       "30" (quoted), abc, -5, 0, 7.5, true, "  12  "  → 120/default, NO word
#       999999999                                       → accepted, no cap
#     Failing safe to 120 is right; doing it silently is the exact failure mode
#     that burned eight sessions. A quoted or padded bare integer is a plausible
#     hand-edit (every other value in that file is quoted) and is ACCEPTED, out
#     loud. Anything that is not an integer of seconds is REFUSED, out loud.
# ===========================================================================
echo "-- 11. an unusable gateTimeout is reported, never silently dropped --"
B11="$(mkbase --files 2 --sleep 1 --tip flat2)"
for badv in abc -5 0 7.5 true; do
  cfg_set_gate "$B11" "$badv"
  scope_hook "$B11"
  if [ "$(hook_tmo)" = 120 ] && [ "$(hook_src)" = default ]; then
    ok "11a/$badv. gateTimeout=$badv fails SAFE to 120/default"
  else
    bad "11a/$badv. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 120/default)"
  fi
  case "$SOUT" in
    *gateTimeout*"$badv"*) ok "11b/$badv. and SAYS so, naming the offending value" ;;
    *) bad "11b/$badv. nothing was said about gateTimeout=$badv: $(printf '%s' "$SOUT" | grep -iv '^SCOPES=' | head -c 200)" ;;
  esac
done
# A QUOTED bare integer: accepted, and said out loud.
cfg_set_gate "$B11" '"30"'
scope_hook "$B11"
[ "$(hook_tmo)" = 30 ] && [ "$(hook_src)" = config ] \
  && ok "11c. a quoted \"30\" is honoured as 30s from config" \
  || bad "11c. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 30/config)"
case "$SOUT" in
  *gateTimeout*) ok "11d. and the coercion is stated, not silent" ;;
  *) bad "11d. a quoted value was accepted in silence" ;;
esac
# Whitespace padding: same call.
cfg_set_gate "$B11" '"  12  "'
scope_hook "$B11"
[ "$(hook_tmo)" = 12 ] && [ "$(hook_src)" = config ] \
  && ok "11e. a padded \"  12  \" is honoured as 12s from config" \
  || bad "11e. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 12/config)"
case "$SOUT" in
  *gateTimeout*) ok "11f. and that coercion is stated too" ;;
  *) bad "11f. a padded value was accepted in silence" ;;
esac
# THE CAP. 999999999s is 31 years — it disables the hang protection the gate
# exists for. Capped, and the cap is STATED when it bites.
cfg_set_gate "$B11" 999999999
scope_hook "$B11"
[ "$(hook_tmo)" = 3600 ] \
  && ok "11g. an absurd 999999999 is capped to the 3600s maximum" \
  || bad "11g. got TIMEOUT=$(hook_tmo) (expected the 3600s cap)"
case "$SOUT" in
  *3600*) ok "11h. and the cap is named where it bites" ;;
  *) bad "11h. the cap must be stated: $(printf '%s' "$SOUT" | grep -iv '^SCOPES=' | head -c 200)" ;;
esac
# A large-but-REASONABLE value is NOT swallowed.
cfg_set_gate "$B11" 1800
scope_hook "$B11"
[ "$(hook_tmo)" = 1800 ] && [ "$(hook_src)" = config ] \
  && ok "11i. a deliberate 1800s (30 min) is kept exactly as recorded" \
  || bad "11i. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 1800/config)"

# …and the REAL gate, not only the diagnostic, honours and records it.
echo "-- 11j. the REAL gate honours a quoted gateTimeout and records the note --"
B12="$(mkbase --files 2 --sleep 1 --tip flat1)"
cfg_set_gate "$B12" '"30"'
ff "$B12"
[ "$(jq_ff "$B12" 'd["gate"]["timeoutSecs"]')" = 30 ] \
  && ok "11j. the real leg ran under 30s" \
  || bad "11j. gate.timeoutSecs was '$(jq_ff "$B12" 'd["gate"]["timeoutSecs"]')' (expected 30)"
[ "$(jq_ff "$B12" 'd["gate"]["timeoutSource"]')" = config ] \
  && ok "11k. recorded as coming from config" \
  || bad "11k. gate.timeoutSource was '$(jq_ff "$B12" 'd["gate"]["timeoutSource"]')' (expected config)"
[ -n "$(jq_ff "$B12" 'd["gate"]["timeoutNote"]')" ] \
  && ok "11l. and the artifact carries the note about the value as written" \
  || bad "11l. gate.timeoutNote is empty — the coercion is not in the record"

# ===========================================================================
# 12. FIX ROUND 2 / DEFECT 2 — A LEADING-ZERO gateTimeout WAS HONOURED AS
#     OCTAL AND WRITTEN INTO flip-flop.json AS INVALID JSON.
#     Measured 22 Oct 2026: `gateTimeout: 010` killed a leg at 7997ms (octal
#     8) while every message called it "the 010s gate timeout", and the
#     artifact carried `"timeoutSecs": 030` — which `json.load` REFUSES, so the
#     one file a verdict is read from was unparseable. The gate record must be
#     machine-readable, always, and no value may be REPORTED as something other
#     than the seconds actually used.
# ===========================================================================
echo "-- 12. a leading-zero gateTimeout is decimal, and the artifact is JSON --"
ffj_parses() { # base → rc 0 when a REAL json parser accepts the artifact
  "${LCARS_PYTHON_BIN:-python3}" -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$(ffj_of "$1")" >/dev/null 2>&1
}
B13="$(mkbase --files 2 --sleep 1 --tip flat2)"
cfg_set_gate "$B13" 030
scope_hook "$B13"
[ "$(hook_tmo)" = 30 ] && [ "$(hook_src)" = config ] \
  && ok "12a. gateTimeout=030 is read as DECIMAL 30s from config (not octal 24)" \
  || bad "12a. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 30/config)"
case "$SOUT" in
  *LEADING\ ZERO*|*[Ll]eading\ zero*) ok "12b. and the leading zero is named out loud" ;;
  *) bad "12b. nothing was said about the leading zero: $(printf '%s' "$SOUT" | grep -iv '^SCOPES=' | head -c 200)" ;;
esac
cfg_set_gate "$B13" 010
scope_hook "$B13"
[ "$(hook_tmo)" = 10 ] \
  && ok "12c. gateTimeout=010 is 10s, not octal 8 (the measured 7997ms kill)" \
  || bad "12c. got TIMEOUT=$(hook_tmo) (expected 10)"
cfg_set_gate "$B13" '"0030"'
scope_hook "$B13"
[ "$(hook_tmo)" = 30 ] && [ "$(hook_src)" = config ] \
  && ok "12d. the quoted 0030 form is honoured as 30s too" \
  || bad "12d. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 30/config)"
case "$SOUT" in
  *'gateTimeout: 0'[0-9]*) bad "12e. the advice still recommends writing INVALID JSON" ;;
  *) ok "12e. the advice no longer recommends a leading-zero (invalid JSON) value" ;;
esac
# THE INVARIANT THAT WAS BROKEN: the artifact a verdict is read from must parse.
B14="$(mkbase --files 2 --sleep 1 --tip flat1)"
cfg_set_gate "$B14" 030
ff "$B14"
ffj_parses "$B14" \
  && ok "12f. flip-flop.json parses with a REAL JSON parser after a 030 gate" \
  || bad "12f. flip-flop.json is NOT valid JSON: $(grep -o '"timeoutSecs": [^,]*' "$(ffj_of "$B14")" 2>/dev/null)"
[ "$(jq_ff "$B14" 'd["gate"]["timeoutSecs"]')" = 30 ] \
  && ok "12g. and timeoutSecs records the 30s the leg actually ran under" \
  || bad "12g. gate.timeoutSecs was '$(jq_ff "$B14" 'd["gate"]["timeoutSecs"]')' (expected 30)"

# ===========================================================================
# 13. FIX ROUND 2 / LOW 5 — `gate_timeout_unusable` FIRED FOR VALUES THAT WERE
#     ACCEPTED. A quoted "30" is honoured as 30s and still emitted the
#     unusable event, so counting that event overstates failures. "Coerced but
#     honoured" and "refused" are different facts and must be different events.
# ===========================================================================
echo "-- 13. a coerced-but-honoured timeout is not reported as unusable --"
B15="$(mkbase --files 2 --sleep 1 --tip flat1)"
cfg_set_gate "$B15" '"30"'
ff "$B15"
grep -q 'gate_timeout_coerced' "$(ev_of "$B15")" 2>/dev/null \
  && ok "13a. an honoured coercion emits gate_timeout_coerced" \
  || bad "13a. expected a gate_timeout_coerced event in events.jsonl"
grep -q 'gate_timeout_unusable' "$(ev_of "$B15")" 2>/dev/null \
  && bad "13b. an ACCEPTED value still emits gate_timeout_unusable" \
  || ok "13b. and does NOT emit gate_timeout_unusable"
B16="$(mkbase --files 2 --sleep 1 --tip flat1)"
cfg_set_gate "$B16" abc
ff "$B16"
grep -q 'gate_timeout_unusable' "$(ev_of "$B16")" 2>/dev/null \
  && ok "13c. a genuinely REFUSED value still emits gate_timeout_unusable" \
  || bad "13c. gateTimeout=abc must still emit gate_timeout_unusable"

# ===========================================================================
# 14. FIX ROUND 2 / LOW 4 — A REFUSED LEG RECORDED FALSE SCOPE METADATA.
#     Two declared files, one unmatchable → correctly INCONCLUSIVE, but the
#     artifact recorded scopeKind "file" and scopeWhy "one declared test file,
#     run as a precise positional filter". Two files were declared and NOTHING
#     was run as any filter. A later measurement keyed on scopeKind reads a
#     false record — the same mis-recording class this session exists to kill.
# ===========================================================================
echo "-- 14. a refused leg records what it REFUSED, not a filter that never ran --"
case "$(jq_ff "$B8" 'd["gate"]["scopeKind"]')" in
  file|files|ancestor) bad "14a. the refused leg still records scopeKind '$(jq_ff "$B8" 'd["gate"]["scopeKind"]')' — a filter that never ran" ;;
  refused) ok "14a. the refused one-file leg records scopeKind 'refused'" ;;
  *) bad "14a. scopeKind should be 'refused' (got '$(jq_ff "$B8" 'd["gate"]["scopeKind"]')')" ;;
esac
case "$(jq_ff "$B8" 'd["gate"]["scopeWhy"]')" in
  *"positional filter"*) bad "14b. scopeWhy still describes a precise positional filter: $(jq_ff "$B8" 'd["gate"]["scopeWhy"]')" ;;
  *REFUSED*|*refused*)   ok "14b. and scopeWhy says the leg was REFUSED and why" ;;
  *) bad "14b. scopeWhy should say the leg was refused (got '$(jq_ff "$B8" 'd["gate"]["scopeWhy"]')')" ;;
esac
# THE TESTER'S EXACT SHAPE: TWO declared files, one of them unmatchable.
B17="$(mkbase --files 2 --sleep 1 --tip spec2)"
ff "$B17" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B17" 'd["verdict"]')" = inconclusive ] \
  && ok "14c. two declared files, one unmatchable → INCONCLUSIVE" \
  || bad "14c. verdict was '$(jq_ff "$B17" 'd["verdict"]')' — $(jq_ff "$B17" 'd["reason"]' | head -c 200)"
[ "$(jq_ff "$B17" 'd["gate"]["scopeKind"]')" = refused ] \
  && ok "14d. and its recorded scopeKind is 'refused', not 'file'" \
  || bad "14d. scopeKind was '$(jq_ff "$B17" 'd["gate"]["scopeKind"]')' (expected refused)"
case "$(jq_ff "$B17" 'd["gate"]["scopeWhy"]')" in
  *"2 declared test file"*) ok "14e. and scopeWhy counts the files that were actually declared" ;;
  *) bad "14e. scopeWhy does not say how many files were declared: $(jq_ff "$B17" 'd["gate"]["scopeWhy"]')" ;;
esac

# ===========================================================================
# 15. FIX ROUND 2 / ROUTE (d) — A LEG THAT EXECUTED ZERO TESTS MUST NOT
#     PRODUCE A CONFIDENT VERDICT.
#     Measured on the real gate with the BARE-GLOB testCommand
#       node --test --test-concurrency=1 "$LCARS_TESTS_DIR"/*.test.js
#     and a declared file whose NAME matches: the scope is a FILE, so the glob
#     `<file>/*.test.js` matches nothing, bash leaves it literal, and node
#     --test prints `pass 0 / fail 0` and exits 0. Both legs green on ZERO
#     tests gave `flip-flop FAIL — the ticket's tests PASS on the PARENT
#     commit`, executed {0,0}, checked:true. A confident verdict from literally
#     no evidence. The runner's OWN count is the record: zero is never proof.
# ===========================================================================
echo "-- 15. a leg whose runner executed ZERO tests proves nothing --"
cfg_set_testcmd() { # base testCommand
  "${LCARS_PYTHON_BIN:-python3}" - "$1/repo/.git/lcars/config.json" "$2" <<'PYCFG'
import json, sys
p, cmd = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d["testCommand"] = cmd
# ONE KEY PER LINE with nested objects inline: run.sh's config readers are
# line-oriented greps, so a pretty-printer that split `numberOne` across lines
# would corrupt the very file under test (lcars-common.sh warns about this).
body = ",\n".join('  %s: %s' % (json.dumps(k), json.dumps(v)) for k, v in d.items())
open(p, "w").write("{\n" + body + "\n}\n")
PYCFG
}
B18="$(mkbase --files 2 --sleep 1 --tip flat1)"
cfg_set_testcmd "$B18" 'node --test --test-concurrency=1 "$LCARS_TESTS_DIR"/*.test.js'
ff "$B18" LCARS_GATE_TIMEOUT=30
R18="$(jq_ff "$B18" 'd["reason"]')"
[ "$(jq_ff "$B18" 'd["verdict"]')" = inconclusive ] \
  && ok "15a. the zero-executed leg is INCONCLUSIVE, not a confident FAIL" \
  || bad "15a. verdict was '$(jq_ff "$B18" 'd["verdict"]')' — $(printf '%s' "$R18" | head -c 220)"
case "$R18" in
  *"PASS on the PARENT"*) bad "15b. it still blames a flip-flop on zero evidence: $(printf '%s' "$R18" | head -c 200)" ;;
  *) ok "15b. and no longer blames a flip-flop its tests never took part in" ;;
esac
case "$R18" in
  *ZERO*|*zero*) ok "15c. the reason says ZERO tests were executed" ;;
  *) bad "15c. the reason must say zero tests ran: $(printf '%s' "$R18" | head -c 200)" ;;
esac
[ "$(jq_ff "$B18" 'd["executed"]["tip"]')" = 0 ] \
  && ok "15d. the runner's own count (0) is RECORDED, not inferred" \
  || bad "15d. executed.tip should be 0 (got '$(jq_ff "$B18" 'd["executed"]["tip"]')')"
grep -q 'proof_leg_zero_executed' "$(ev_of "$B18")" 2>/dev/null \
  && ok "15e. and the fact is a NAMED event (proof_leg_zero_executed)" \
  || bad "15e. expected a proof_leg_zero_executed event in events.jsonl"
# The leg DID run, so unlike a pre-run refusal its command is recorded.
[ -n "$(jq_ff "$B18" 'd["tip"]["cmd"]')" ] \
  && ok "15f. the command that ran is still recorded (this leg ran; it proved nothing)" \
  || bad "15f. tip.cmd should record the invocation that executed zero tests"
# THE CONTROL: the ordinary find-shape repo with a matching file name still
# proves its ticket, so this is not a blanket refusal.
[ "$(jq_ff "$B2" 'd["verdict"]')" = pass ] \
  && ok "15g. and the matching-shape control ticket still passes" \
  || bad "15g. the control should still pass (got '$(jq_ff "$B2" 'd["verdict"]')')"

# ===========================================================================
# 16. FIX ROUND 2 / DEFECT 1 (INTERIM) — THE SELECT-NOTHING PRE-CHECK MUST
#     DECIDE ON ITS OUTPUT, NOT ON ITS EXIT CODE.
#     `[ "$rc" -eq 0 ] || continue` skipped every selection that exited
#     non-zero — and for the commands people actually write, "matched nothing"
#     IS a non-zero exit (`grep` returns 1, a failing `ls`, a non-matching
#     glob). The tester's decisive discriminator: `$(find … | grep …)` was
#     FAIL, and the SAME expression with `|| true` appended (identical EMPTY
#     output, rc 0) was INCONCLUSIVE. Empty output is empty output.
# ===========================================================================
echo "-- 16. the pre-check decides on OUTPUT, not exit code --"
B19="$(mkbase --files 2 --sleep 1 --tip spec1)"
cfg_set_testcmd "$B19" 'node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -type f | grep "\.test\.js$")'
ff "$B19" LCARS_GATE_TIMEOUT=30
R19="$(jq_ff "$B19" 'd["reason"]')"
[ "$(jq_ff "$B19" 'd["verdict"]')" = inconclusive ] \
  && ok "16a. a selection that EXITS NON-ZERO with empty output is refused too" \
  || bad "16a. verdict was '$(jq_ff "$B19" 'd["verdict"]')' — $(printf '%s' "$R19" | head -c 220)"
case "$R19" in
  *"selected NO"*|*"selected nothing"*|*ZERO*|*zero*)
    ok "16b. and says so in words" ;;
  *) bad "16b. the reason must say nothing was selected: $(printf '%s' "$R19" | head -c 200)" ;;
esac
# The || true form — byte-identical empty output, rc 0 — must reach the SAME
# verdict. Before the fix these two disagreed, which is how the rule was found.
B20="$(mkbase --files 2 --sleep 1 --tip spec1)"
cfg_set_testcmd "$B20" 'node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -type f | grep "\.test\.js$" || true)'
ff "$B20" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B20" 'd["verdict"]')" = "$(jq_ff "$B19" 'd["verdict"]')" ] \
  && ok "16c. the || true form reaches the SAME verdict as the bare pipeline" \
  || bad "16c. the || true form gave '$(jq_ff "$B20" 'd["verdict"]')' but the bare form gave '$(jq_ff "$B19" 'd["verdict"]')'"

# ===========================================================================
# 17. FIX ROUND 2 — THE ARTIFACT MUST NOT ASSERT A NARROWING IT DID NOT VERIFY.
#     Round 1 recorded `scopeWhy: "one declared test file, run as a precise
#     positional filter"`. LCARS does not know that: the repo's testCommand
#     decides how to turn $LCARS_TESTS_DIR into a file list, and the measured
#     routes (a backtick selection, a piped `find | grep`, a bare glob) all
#     hand the runner an EMPTY argument list and let it discover its own tests
#     instead. The false confidence lived in that sentence. The record states
#     what LCARS handed over, and names what it has NOT verified.
# ===========================================================================
echo "-- 17. a file scope records what was handed over, not a verified filter --"
W17="$(jq_ff "$B2" 'd["gate"]["scopeWhy"]')"
case "$W17" in
  *"positional filter"*) bad "17a. the file-scope record still asserts a precise positional filter: $W17" ;;
  *) ok "17a. the file-scope record no longer asserts a filter it cannot verify" ;;
esac
case "$W17" in
  *"NOT verified"*|*"not verified"*) ok "17b. and it names the part that is NOT verified" ;;
  *) bad "17b. scopeWhy should say what it has not verified: $W17" ;;
esac

# ===========================================================================
# 18. FIX ROUND 2 / DEFECT 1 (THE SHAPE-BLIND CLOSURE) — ROUTE (a), BACKTICKS.
#     The round-1 pre-check parses `$( … )` bodies, so the tester beat it with
#     the SAME selection written in BACKTICKS:
#       node --test --test-concurrency=1 `find "$LCARS_TESTS_DIR" -name "*.test.js"`
#     Measured 22 Oct 2026: confident FAIL, executed {parent:8, tip:8}, eight
#     UNDECLARED tests on both legs, scopeSelectedNothing false, checked true —
#     and a FALSE PASS by the same mechanism whenever the fallback suite happens
#     to be red on the parent. Teaching the parser backticks would be generation
#     three of the parser S147 proved cannot be finished (ORCHESTRATION.md,
#     "The infer-vs-record check"), so the question is settled by EXPERIMENT
#     instead: re-run the repo's own testCommand with the scope pointed at an
#     EMPTY DIRECTORY. Same count under the same runner = the scope changed
#     nothing. That comparison is blind to how the command is spelled.
#
#     THE FALSE-PASS DIRECTION NEEDS NO SEPARATE CASE: the comparison uses only
#     the TIP leg's count and the control's, so it is reached before the parent
#     leg runs at all (asserted below) and cannot be influenced by what colour
#     the undeclared suite happens to be on either side.
# ===========================================================================
echo "-- 18. a BACKTICK selection that selects nothing is refused too --"
B21="$(mkbase --files 2 --sleep 1 --tip spec1)"
cfg_set_testcmd "$B21" 'node --test --test-concurrency=1 `find "$LCARS_TESTS_DIR" -name "*.test.js"`'
ff "$B21" LCARS_GATE_TIMEOUT=30
R21="$(jq_ff "$B21" 'd["reason"]')"
[ "$(jq_ff "$B21" 'd["verdict"]')" = inconclusive ] \
  && ok "18a. the backtick form is INCONCLUSIVE, not a confident FAIL" \
  || bad "18a. verdict was '$(jq_ff "$B21" 'd["verdict"]')' — $(printf '%s' "$R21" | head -c 220)"
case "$R21" in
  *"PASS on the PARENT"*) bad "18b. it still blames a flip-flop on undeclared tests" ;;
  *) ok "18b. and no longer blames a flip-flop the ticket's test never took part in" ;;
esac
case "$R21" in
  *"THE SAME"*|*"same"*) ok "18c. the reason states the MEASUREMENT that decided it" ;;
  *) bad "18c. the reason must state the control measurement: $(printf '%s' "$R21" | head -c 200)" ;;
esac
grep -q 'proof_scope_not_narrowed' "$(ev_of "$B21")" 2>/dev/null \
  && ok "18d. the fact is a NAMED event (proof_scope_not_narrowed)" \
  || bad "18d. expected a proof_scope_not_narrowed event in events.jsonl"
[ "$(jq_ff "$B21" 'd["scopeControl"]["narrowingProven"]')" = False ] \
  && ok "18e. and the artifact RECORDS that the narrowing was not proven" \
  || bad "18e. scopeControl.narrowingProven should be false (got '$(jq_ff "$B21" 'd["scopeControl"]["narrowingProven"]')')"
[ "$(jq_ff "$B21" 'd["scopeControl"]["executed"]')" = "$(jq_ff "$B21" 'd["executed"]["tip"]')" ] \
  && ok "18f. with both numbers in the record, not inferable from prose" \
  || bad "18f. the control count ($(jq_ff "$B21" 'd["scopeControl"]["executed"]')) and the leg count ($(jq_ff "$B21" 'd["executed"]["tip"]')) should both be recorded and equal"
[ "$(jq_ff "$B21" 'd["parentLeg"]["ran"]')" = False ] \
  && ok "18g. and the refusal is reached BEFORE the parent leg — so the false-PASS direction reaches it identically" \
  || bad "18g. parentLeg.ran should be false (got '$(jq_ff "$B21" 'd["parentLeg"]["ran"]')')"
# NOT A BLANKET REFUSAL, and the narrowing is now PROVEN rather than asserted:
# the honest single-file and declared-files legs of sections 1-3 carry a control
# count that DIFFERS from what they ran.
[ "$(jq_ff "$B2" 'd["scopeControl"]["narrowingProven"]')" = True ] \
  && ok "18h. the honest one-file leg has its narrowing PROVEN by the control" \
  || bad "18h. B2 scopeControl.narrowingProven should be true (got '$(jq_ff "$B2" 'd["scopeControl"]["narrowingProven"]')')"
[ "$(jq_ff "$B1" 'd["verdict"]')" = pass ] \
  && ok "18i. and the two-file files-mode leg still passes with the control in place" \
  || bad "18i. B1 should still pass (got '$(jq_ff "$B1" 'd["verdict"]')')"

# ===========================================================================
# 19. FIX ROUND 3 / CURE 1 — THE GATE MUST **ACT** ON `narrowingProven: false`,
#     AND THE CONTROL MUST BE BUDGETED AGAINST THE FULL SUITE.
#
#     MEASURED 22 Oct 2026: `grep -n narrowingProven run.sh` returned exactly
#     ONE line — the printf that writes it into flip-flop.json. The harness ran
#     the control, honestly recorded that it could NOT prove the narrowing, and
#     then issued a fully confident verdict anyway. Four routes into that state,
#     every one ending in a confident PASS or FAIL.
#
#     THE TRAP IN THE OBVIOUS FIX, and it is why this section exists. The
#     control hands the testCommand an EMPTY scope, so the command falls back to
#     discovering the WHOLE SUITE — and round 2 bounded it by the NARROWED leg's
#     gate. In section 1's fixture (a ~10s suite with LCARS_GATE_TIMEOUT=5) the
#     leg passes correctly in ~2s while the control is KILLED, recording
#     narrowingProven false. Downgrading on that would turn every leg in exactly
#     the repos this session exists for — a full suite slower than the gate —
#     into INCONCLUSIVE: five consecutive no-information verdicts, which is the
#     pagesai burn this whole session is fixing. A regression dressed as a
#     safety fix.
#
#     SO THE CONTROL GETS ITS OWN BUDGET: it is the FULL-SUITE-SHAPED run, so it
#     is budgeted against the repo's own recorded full-suite need (`gateTimeout`
#     in .git/lcars/config.json, which this session seeds from the probe's
#     measured wall clock) or the 120s default — whichever is larger than the
#     leg's own bound — never a one-off narrow LCARS_GATE_TIMEOUT. One run per
#     gate, still capped by GATE_TIMEOUT_MAX.
# ===========================================================================
echo "-- 19. the control is budgeted against the FULL SUITE, and false is acted on --"
# B1 is the trap fixture itself: ~10s suite, LCARS_GATE_TIMEOUT=5, narrow leg ~2s.
[ "$(jq_ff "$B1" 'd["verdict"]')" = pass ] \
  && ok "19a. the flat slow repo's honest leg still PASSES (no blanket INCONCLUSIVE)" \
  || bad "19a. B1 verdict was '$(jq_ff "$B1" 'd["verdict"]')' — cure 1 recreated the pagesai burn: $(jq_ff "$B1" 'd["reason"]' | head -c 200)"
[ "$(jq_ff "$B1" 'd["scopeControl"]["narrowingProven"]')" = True ] \
  && ok "19b. and its narrowing is PROVEN — the control was not killed by the narrow gate" \
  || bad "19b. B1 narrowingProven is '$(jq_ff "$B1" 'd["scopeControl"]["narrowingProven"]')' (the control ran out of the LEG's budget, so a ~10s-suite repo gets no coverage)"
[ "$(jq_ff "$B1" 'd["scopeControl"]["narrowing"]')" = proven ] \
  && ok "19c. recorded as a named state, not a bare boolean (narrowing=proven)" \
  || bad "19c. scopeControl.narrowing should be 'proven' (got '$(jq_ff "$B1" 'd["scopeControl"]["narrowing"]')')"
BUD1="$(jq_ff "$B1" 'd["scopeControl"]["budgetSecs"]')"
TMO1="$(jq_ff "$B1" 'd["gate"]["timeoutSecs"]')"
[ -n "$BUD1" ] && [ "$BUD1" -gt "$TMO1" ] 2>/dev/null \
  && ok "19d. the control's OWN budget (${BUD1}s) is recorded and exceeds the leg's gate (${TMO1}s)" \
  || bad "19d. scopeControl.budgetSecs='$BUD1' must exceed the leg's timeoutSecs='$TMO1'"
# The repo's RECORDED full-suite need wins over a one-off narrow env override.
B22="$(mkbase --files 8 --sleep 1 --tip flat2)"
cfg_set_gate "$B22" 30
ff "$B22" LCARS_GATE_TIMEOUT=5
[ "$(jq_ff "$B22" 'd["scopeControl"]["budgetSecs"]')" = 30 ] \
  && ok "19e. a repo whose gateTimeout records 30s budgets the control at 30s, not the 5s override" \
  || bad "19e. budgetSecs was '$(jq_ff "$B22" 'd["scopeControl"]["budgetSecs"]')' (expected 30)"
[ "$(jq_ff "$B22" 'd["verdict"]')" = pass ] \
  && ok "19f. and that leg reaches a real verdict" \
  || bad "19f. verdict was '$(jq_ff "$B22" 'd["verdict"]')' — $(jq_ff "$B22" 'd["reason"]' | head -c 200)"
# AND WHEN THE CONTROL GENUINELY CANNOT BE READ EVEN AT ITS OWN BUDGET, the leg
# is INCONCLUSIVE and says so. Produced by recording a full-suite need (2s) far
# BELOW what the suite really takes (~10s) — the honest "we cannot prove it".
B23="$(mkbase --files 8 --sleep 1 --tip flat2)"
ff "$B23" LCARS_GATE_TIMEOUT=5 LCARS_GATE_TIMEOUT_DEFAULT=2
R23="$(jq_ff "$B23" 'd["reason"]')"
[ "$(jq_ff "$B23" 'd["verdict"]')" = inconclusive ] \
  && ok "19g. a control that cannot be read even at its own budget → INCONCLUSIVE" \
  || bad "19g. verdict was '$(jq_ff "$B23" 'd["verdict"]')' — a confident verdict on an unprovable narrowing"
[ "$(jq_ff "$B23" 'd["scopeControl"]["narrowing"]')" = unproven ] \
  && ok "19h. recorded as narrowing=unproven" \
  || bad "19h. scopeControl.narrowing was '$(jq_ff "$B23" 'd["scopeControl"]["narrowing"]')' (expected unproven)"
case "$R23" in
  *"could not"*|*"not be proven"*|*"budget"*) ok "19i. and the reason names WHY the narrowing could not be proven" ;;
  *) bad "19i. the reason must name the unprovable narrowing: $(printf '%s' "$R23" | head -c 250)" ;;
esac
case "$R23" in
  *"PASS on the PARENT"*) bad "19j. it still blames a flip-flop it could not establish" ;;
  *) ok "19j. and no longer claims anything about the parent commit" ;;
esac
grep -q 'proof_scope_narrowing_unproven' "$(ev_of "$B23")" 2>/dev/null \
  && ok "19k. the fact is a NAMED event (proof_scope_narrowing_unproven)" \
  || bad "19k. expected a proof_scope_narrowing_unproven event in events.jsonl"

# ===========================================================================
# 20. FIX ROUND 3 / CURE 2 — THE REPRODUCIBLE **FALSE PASS**.
#     The control runs ONCE; `executed` SUMS across N invocations in files mode.
#     So for a two-file ticket the sum can essentially never equal the single
#     control count, narrowingProven goes true regardless, and the comparison is
#     DEAD. Route (a) therefore flips from INCONCLUSIVE to PASS purely by adding
#     one honest sibling file.
#
#     MEASURED 22 Oct 2026 with the tester's exact shape — two declared files, a
#     BACKTICK selection, one matchable+honest sibling, the ticket's real test
#     unmatchable AND RED on the tip:
#       verdict pass, executed {parent: 3, tip: 4}, scopeControl {executed: 3,
#       narrowingProven: TRUE}
#     The leg's SUM (1 from the sibling + 3 from the fallback discovery) equals
#     neither the control (3) nor control x N (6), so nothing fired. A ticket was
#     certified while one of its two declared tests was red on the tip and never
#     executed at all. The cure is to compare PER INVOCATION, where each number
#     was produced.
# ===========================================================================
echo "-- 20. the FALSE PASS: a red declared test certified by an honest sibling --"
B24="$(mkbase --files 2 --sleep 0 --tip spec2red)"
# The fixture must genuinely bite: the ticket's own declared test IS red on the tip.
RED24="$( cd "$B24/repo" && node --test --test-concurrency=1 tests/ticket_down_spec.js 2>&1 )"
if printf '%s' "$RED24" | grep -q '^ℹ fail 1'; then
  ok "20a. the fixture bites: the ticket's declared tests/ticket_down_spec.js is RED on the tip"
else
  bad "20a. the fixture does not bite — ticket_down_spec.js is not red on the tip"
fi
cfg_set_testcmd "$B24" 'node --test --test-concurrency=1 `find "$LCARS_TESTS_DIR" -name "*.test.js"`'
ff "$B24" LCARS_GATE_TIMEOUT=30
R24="$(jq_ff "$B24" 'd["verdict"]')"
[ "$R24" != pass ] \
  && ok "20b. the gate does NOT certify it (verdict is not 'pass')" \
  || bad "20b. FALSE PASS — a red, never-executed declared test was certified: executed=$(jq_ff "$B24" 'd["executed"]'), scopeControl=$(jq_ff "$B24" 'd["scopeControl"]')"
[ "$R24" = inconclusive ] \
  && ok "20c. it is INCONCLUSIVE" \
  || bad "20c. verdict was '$R24' (expected inconclusive)"
[ "$(jq_ff "$B24" 'd["scopeControl"]["narrowingProven"]')" = False ] \
  && ok "20d. and narrowingProven is FALSE — the per-invocation comparison fired" \
  || bad "20d. narrowingProven was '$(jq_ff "$B24" 'd["scopeControl"]["narrowingProven"]')' — the one-control-vs-the-sum comparison is still dead"
EACH24="$(jq_ff "$B24" 'd["scopeControl"]["legExecutedEach"]')"
case " $EACH24 " in
  *" $(jq_ff "$B24" 'd["scopeControl"]["executed"]') "*)
    ok "20e. the per-invocation counts are RECORDED ($EACH24) and one matches the control" ;;
  *) bad "20e. scopeControl.legExecutedEach='$EACH24' should record each invocation's own count" ;;
esac
case "$(jq_ff "$B24" 'd["reason"]')" in
  *"SAME"*|*"same"*) ok "20f. the reason states the measurement that decided it" ;;
  *) bad "20f. the reason must state the control measurement: $(jq_ff "$B24" 'd["reason"]' | head -c 250)" ;;
esac
[ "$(jq_ff "$B24" 'd["parentLeg"]["ran"]')" = False ] \
  && ok "20g. and the refusal is reached BEFORE the parent leg runs" \
  || bad "20g. parentLeg.ran should be false (got '$(jq_ff "$B24" 'd["parentLeg"]["ran"]')')"
# NOT A BLANKET REFUSAL: the honest two-file files-mode leg of section 1 still passes.
[ "$(jq_ff "$B1" 'd["verdict"]')" = pass ] \
  && ok "20h. and the honest two-file leg is untouched (still passes)" \
  || bad "20h. per-invocation comparison false-refused the honest two-file leg"

# ===========================================================================
# 21. FIX ROUND 3 / CURE 3 — THE ZERO-EXECUTED-GREEN REFUSAL WAS IMPLEMENTED
#     FOR THE **TIP** LEG ONLY.
#     MEASURED 22 Oct 2026: executed {parent: "0", tip: "1", checked: true},
#     parent rc 0, parent tail `tests 0` — and verdict FAIL,
#       "the ticket's tests PASS on the PARENT commit"
#     The parent's count was read into a local and then IGNORED. Nothing ran on
#     the parent, so "they pass there" describes a run that never happened. The
#     direction is blocking rather than shipping, which makes it less severe
#     than the false pass — but it is the same false-confidence class, and it is
#     the sentence a worker is sent to chase.
# ===========================================================================
echo "-- 21. a PARENT leg green on ZERO executed tests proves nothing either --"
B25="$(mkbase --files 2 --sleep 0 --suite spec --tip tracked1)"
cfg_set_testcmd "$B25" 'node --test --test-concurrency=1 `git ls-files -- "$LCARS_TESTS_DIR"`'
ff "$B25" LCARS_GATE_TIMEOUT=30
R25="$(jq_ff "$B25" 'd["reason"]')"
[ "$(jq_ff "$B25" 'd["executed"]["parent"]')" = 0 ] && [ "$(jq_ff "$B25" 'd["executed"]["tip"]')" = 1 ] \
  && ok "21a. the measured shape is reproduced: executed {parent: 0, tip: 1}" \
  || bad "21a. expected executed {parent:0, tip:1}, got $(jq_ff "$B25" 'd["executed"]')"
[ "$(jq_ff "$B25" 'd["parent"]["rc"]')" = 0 ] \
  && ok "21b. with the parent leg GREEN (rc 0) on that zero" \
  || bad "21b. the parent leg should be green (rc $(jq_ff "$B25" 'd["parent"]["rc"]'))"
[ "$(jq_ff "$B25" 'd["verdict"]')" = inconclusive ] \
  && ok "21c. the verdict is INCONCLUSIVE, not a confident FAIL" \
  || bad "21c. verdict was '$(jq_ff "$B25" 'd["verdict"]')' — $(printf '%s' "$R25" | head -c 220)"
case "$R25" in
  *"PASS on the PARENT"*) bad "21d. it still says the tests PASS on the parent commit: $(printf '%s' "$R25" | head -c 200)" ;;
  *) ok "21d. and no longer says the ticket's tests pass on the parent" ;;
esac
case "$R25" in
  *ZERO*|*zero*) ok "21e. the reason says the PARENT leg executed zero tests" ;;
  *) bad "21e. the reason must say zero: $(printf '%s' "$R25" | head -c 220)" ;;
esac
grep -q 'proof_leg_zero_executed' "$(ev_of "$B25")" 2>/dev/null \
  && ok "21f. the fact is a NAMED event (proof_leg_zero_executed)" \
  || bad "21f. expected a proof_leg_zero_executed event in events.jsonl"
[ "$(jq_ff "$B25" 'd["parentLeg"]["ran"]')" = True ] \
  && ok "21g. and parentLeg.ran stays TRUE — that leg ran; it proved nothing" \
  || bad "21g. parentLeg.ran should be true (got '$(jq_ff "$B25" 'd["parentLeg"]["ran"]')')"

# ===========================================================================
# 22. FIX ROUND 3 / LOW (D6) — A RECORD MUST NOT CONTRADICT ITSELF.
#     A leg made inconclusive BY THE CONTROL still recorded
#     `scopeSelectedNothing: false` while the same artifact's `reason` said the
#     scope selected nothing. The round-2 `scopeKind: "refused"` cure covers
#     only the PRE-FLIGHT path. The control run MEASURES the same fact, so it
#     records it.
# ===========================================================================
echo "-- 22. a control-refused leg records that the scope selected nothing --"
[ "$(jq_ff "$B21" 'd["gate"]["scopeSelectedNothing"]')" = True ] \
  && ok "22a. the control-refused one-file leg records scopeSelectedNothing: true" \
  || bad "22a. scopeSelectedNothing was '$(jq_ff "$B21" 'd["gate"]["scopeSelectedNothing"]')' while the reason says the scope selected nothing"
[ "$(jq_ff "$B24" 'd["gate"]["scopeSelectedNothing"]')" = True ] \
  && ok "22b. and so does the two-file false-pass leg" \
  || bad "22b. B24 scopeSelectedNothing was '$(jq_ff "$B24" 'd["gate"]["scopeSelectedNothing"]')'"
[ "$(jq_ff "$B2" 'd["gate"]["scopeSelectedNothing"]')" = False ] \
  && ok "22c. while an honest narrowed leg still records false" \
  || bad "22c. the honest leg must NOT be marked as selecting nothing"

# ===========================================================================
# 23. FIX ROUND 3 — CURE 1 MUST NOT PARK A REPO WHOSE CONTROL RUN COLLECTS
#     NOTHING. proof_executed_count reads SUMMARY NUMBERS, and several runners
#     print none at all when they collect nothing (pytest's zero-test run is
#     `===== no tests ran =====` with no passed/failed/error to read). An
#     unreadable control is `unproven`, which cure 1 makes INCONCLUSIVE — so
#     without this, EVERY leg of EVERY pytest repo would park on the very
#     measurement meant to protect it. A control that collected NOTHING is the
#     STRONGEST form of the evidence: emptying the scope emptied the run.
# ===========================================================================
echo "-- 23. a control run that collects NOTHING proves the narrowing --"
B26="$(mkbase --files 2 --sleep 0 --tip flat1)"
# A testCommand whose zero-case prints the runners' own "no tests ran" sentence
# and NO summary numbers — pytest's shape, reproduced without needing pytest.
cfg_set_testcmd "$B26" 'F=$(find "$LCARS_TESTS_DIR" -name "*.test.js"); if [ -z "$F" ]; then echo "===== no tests ran in 0.01s ====="; exit 5; fi; node --test --test-concurrency=1 $F'
ff "$B26" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B26" 'd["verdict"]')" = pass ] \
  && ok "23a. the honest leg still PASSES when the control prints no numbers" \
  || bad "23a. verdict was '$(jq_ff "$B26" 'd["verdict"]')' — cure 1 parks a whole class of repo: $(jq_ff "$B26" 'd["reason"]' | head -c 250)"
[ "$(jq_ff "$B26" 'd["scopeControl"]["narrowing"]')" = proven ] \
  && ok "23b. and its narrowing is PROVEN by the zero-collect control" \
  || bad "23b. narrowing was '$(jq_ff "$B26" 'd["scopeControl"]["narrowing"]')' (expected proven)"
[ "$(jq_ff "$B26" 'd["scopeControl"]["collectedZero"]')" = True ] \
  && ok "23c. recorded as collectedZero, not mistaken for an absent count" \
  || bad "23c. scopeControl.collectedZero should be true (got '$(jq_ff "$B26" 'd["scopeControl"]["collectedZero"]')')"

# ===========================================================================
echo
printf 'gate-scope: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
