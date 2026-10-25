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
[ "$(hook_tmo)" = 500 ] && [ "$(hook_src)" = default ] \
  && ok "10c. and an unset gateTimeout reports 500/default" \
  || bad "10c. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 500/default)"

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
  if [ "$(hook_tmo)" = 500 ] && [ "$(hook_src)" = default ]; then
    ok "11a/$badv. gateTimeout=$badv fails SAFE to 500/default"
  else
    bad "11a/$badv. got TIMEOUT=$(hook_tmo) SOURCE=$(hook_src) (expected 500/default)"
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
#     measured live-run burn this whole session is fixing. A regression dressed as a
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
  || bad "19a. B1 verdict was '$(jq_ff "$B1" 'd["verdict"]')' — cure 1 recreated the measured live-run burn: $(jq_ff "$B1" 'd["reason"]' | head -c 200)"
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
# 24. S318 / D9 — A LEG THAT CANNOT ACCOUNT FOR THE TICKET'S DECLARED TESTS
#     MAY NOT PASS IT.
#
#     MEASURED on the committed tip BEFORE this section existed: a ticket
#     declaring TWO test files, one of them named `_spec.js` in a `*.test.js`
#     world and GENUINELY RED, was certified
#
#       verdict  : pass
#       declared : ['tests/ticket_down_spec.js', 'tests/ticket_up.test.js']
#       executed : {parent: 1, tip: 1, runner: node, checked: true}
#       tip tail : up works            <- the RED declared test is ABSENT
#
#     in FOUR separate narrowing states — `ancestor`, `moot`, `uncountable` and
#     `tree`/`not-narrowed`. S308's per-invocation control closed `files` mode
#     only, because that is the ONLY state carrying per-file evidence. Nothing
#     anywhere compared `testFiles` (the DECLARATION) against what executed.
#
#     THE MEASUREMENT, not a parser (ORCHESTRATION.md § infer-vs-record): the
#     repo's OWN testCommand is re-run once per declared file with the scope
#     pointed at THAT FILE, and the leg may only conclude when it executed at
#     least as many tests as those per-file runs sum to. In `files` mode the leg
#     ALREADY ran one invocation per declared file, so its own
#     `legExecutedEach` IS the measurement and nothing extra runs.
#
#     FAIL SAFE IN ONE DIRECTION ONLY: extra INCONCLUSIVE is acceptable, a
#     confident verdict on tests that did not run is not. 24m-24t are the
#     CONTROLS and they matter more than the four refusals.
# ===========================================================================
echo "-- 24. a leg that cannot account for the declared tests may not pass it --"

# Rewrite the tip's result.json newTests list, in place.
set_declared() { # base json-array
  local f="$1/repo/.git/lcars/missions/m-001/tickets/t-001/result.json"
  "${LCARS_PYTHON_BIN:-python3}" - "$f" "$2" <<'SDPY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["newTests"] = json.loads(sys.argv[2])
open(p, "w").write(json.dumps(d, indent=1) + "\n")
SDPY
}
# The D9 tip: TWO declared test files, the second one UNDISCOVERABLE by the
# repo's own `*.test.js` selection AND RED. Built by AMENDING the fixture's tip
# commit, so HEAD~1 is still the flat-slow parent the gate is driven against.
d9_tip() { # base dir-of-the-red-file requires-prefix
  local base="$1" dir="$2" req="$3"
  ( cd "$base/repo" || exit 1
    rm -f "$dir/ticket_down.test.js"
    cat >"$dir/ticket_down_spec.js" <<JSRED
const { test } = require('node:test');
const assert = require('node:assert');
const { down } = require('$req/src/down.js');
// THE TICKET'S REAL TEST, AND IT IS RED. If it ever executes the leg goes red;
// the false PASS is that it never executes at all.
test('down works', () => { assert.strictEqual(down('HI'), 'DEFINITELY NOT THIS'); });
JSRED
    git add -A && git commit -q --amend -m "t-001: two declared files, one undiscoverable AND RED" ) >/dev/null 2>&1
}

# --- 24a-e. ANCESTOR scope. The normal nested layout. ----------------------
B27="$(mkbase --files 2 --sleep 0 --tip nested)"
d9_tip "$B27" tests/a/b '../../..'
set_declared "$B27" '["tests/a/ticket_up.test.js","tests/a/b/ticket_down_spec.js"]'
RED27="$( cd "$B27/repo" && node --test --test-concurrency=1 tests/a/b/ticket_down_spec.js 2>&1 )"
printf '%s' "$RED27" | grep -q 'fail 1' \
  && ok "24a. the fixture bites: the declared tests/a/b/ticket_down_spec.js is RED on the tip" \
  || bad "24a. the fixture does not bite — the declared _spec file is not red on the tip"
ff "$B27" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B27" 'd["gate"]["scopeKind"]')" = ancestor ] \
  && ok "24b. the leg really is in the ANCESTOR narrowing state" \
  || bad "24b. scopeKind was '$(jq_ff "$B27" 'd["gate"]["scopeKind"]')' (expected ancestor)"
[ "$(jq_ff "$B27" 'd["verdict"]')" = inconclusive ] \
  && ok "24c. ancestor: INCONCLUSIVE, not a certified pass" \
  || bad "24c. FALSE PASS (ancestor) — verdict '$(jq_ff "$B27" 'd["verdict"]')', executed $(jq_ff "$B27" 'd["executed"]')"
case "$(jq_ff "$B27" 'd["reason"]')" in
  *ticket_down_spec.js*) ok "24d. and the reason NAMES the file it could not account for" ;;
  *) bad "24d. the reason must name tests/a/b/ticket_down_spec.js: $(jq_ff "$B27" 'd["reason"]' | head -c 220)" ;;
esac
case "$(jq_ff "$B27" 'd["declaredRan"]["unaccounted"]')" in
  *ticket_down_spec.js*) ok "24e. the artifact RECORDS the unaccounted file" ;;
  *) bad "24e. declaredRan.unaccounted was '$(jq_ff "$B27" 'd["declaredRan"]["unaccounted"]')'" ;;
esac

# --- 24f-g. MOOT: every tracked test file IS declared. --------------------
# The precondition round 2 added: its premise is TRUE (a fallback to discovery
# can only run DECLARED tests) and the inference drawn from it is wrong — that
# says nothing about whether EACH of them ran.
B28="$(mkbase --files 0 --sleep 0 --tip spec2red)"
ff "$B28" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B28" 'd["verdict"]')" = inconclusive ] \
  && ok "24f. moot: INCONCLUSIVE, not a certified pass" \
  || bad "24f. FALSE PASS (moot) — verdict '$(jq_ff "$B28" 'd["verdict"]')', narrowing $(jq_ff "$B28" 'd["scopeControl"]["narrowing"]'), executed $(jq_ff "$B28" 'd["executed"]')"
case "$(jq_ff "$B28" 'd["declaredRan"]["unaccounted"]')" in
  *ticket_down_spec.js*) ok "24g. and the moot leg names the file it could not account for" ;;
  *) bad "24g. declaredRan.unaccounted was '$(jq_ff "$B28" 'd["declaredRan"]["unaccounted"]')'" ;;
esac

# --- 24h-j. UNCOUNTABLE: an ordinary quiet CI wrapper prints no count. ----
B29="$(mkbase --files 0 --sleep 0 --tip spec2red)"
cfg_set_testcmd "$B29" 'if node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js") >/dev/null 2>&1; then echo "ALL GREEN"; else echo "SUITE FAILED"; exit 1; fi'
ff "$B29" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B29" 'd["scopeControl"]["narrowing"]')" = uncountable ] \
  && ok "24h. the leg really is in the UNCOUNTABLE narrowing state" \
  || bad "24h. narrowing was '$(jq_ff "$B29" 'd["scopeControl"]["narrowing"]')' (expected uncountable)"
[ "$(jq_ff "$B29" 'd["verdict"]')" = inconclusive ] \
  && ok "24i. uncountable: INCONCLUSIVE — no count can ever account for a file" \
  || bad "24i. FALSE PASS (uncountable) — verdict '$(jq_ff "$B29" 'd["verdict"]')'"
case "$(jq_ff "$B29" 'd["reason"]')" in
  *"no test count"*|*"no count"*) ok "24j. and it names the unreadable runner as the reason" ;;
  *) bad "24j. the reason must say the runner prints no count: $(jq_ff "$B29" 'd["reason"]' | head -c 220)" ;;
esac

# --- 24k-l. TREE / not-narrowed: the testCommand ignores the scope. -------
B30="$(mkbase --files 2 --sleep 0 --tip spec2red)"
cfg_set_testcmd "$B30" 'node --test --test-concurrency=1 $(find tests -name "*.test.js")'
ff "$B30" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B30" 'd["scopeControl"]["narrowing"]')" = not-narrowed ] \
  && ok "24k. the leg really is in the NOT-NARROWED state (an unscoped testCommand)" \
  || bad "24k. narrowing was '$(jq_ff "$B30" 'd["scopeControl"]["narrowing"]')' (expected not-narrowed)"
[ "$(jq_ff "$B30" 'd["verdict"]')" = inconclusive ] \
  && ok "24l. tree: INCONCLUSIVE — a full-suite run cannot show a declared file ran" \
  || bad "24l. FALSE PASS (tree) — verdict '$(jq_ff "$B30" 'd["verdict"]')', executed $(jq_ff "$B30" 'd["executed"]')"

# === THE CONTROLS — these matter more than the four refusals above. ========
# --- 24m-o. AN HONEST TWO-FILE ANCESTOR TICKET STILL PASSES. --------------
B31="$(mkbase --files 2 --sleep 0 --tip nested)"
ff "$B31" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B31" 'd["verdict"]')" = pass ] \
  && ok "24m. CONTROL: an honest TWO-file ancestor ticket still PASSES" \
  || bad "24m. the guard PARKED an honest two-file ancestor ticket — verdict '$(jq_ff "$B31" 'd["verdict"]')': $(jq_ff "$B31" 'd["reason"]' | head -c 250)"
[ "$(jq_ff "$B31" 'd["declaredRan"]["unaccounted"]')" = "[]" ] \
  && ok "24n. with BOTH declared files accounted for" \
  || bad "24n. declaredRan.unaccounted was '$(jq_ff "$B31" 'd["declaredRan"]["unaccounted"]')' on an honest ticket"
case "$(jq_ff "$B31" 'd["declaredRan"]["each"]')" in
  *ticket_up.test.js=*) ok "24o. and the per-file measurement is RECORDED, file by file" ;;
  *) bad "24o. declaredRan.each should carry each declared file's own count: '$(jq_ff "$B31" 'd["declaredRan"]["each"]')'" ;;
esac
# --- 24p-q. AN HONEST TWO-FILE FLAT (files-mode) TICKET STILL PASSES, and the
#            accounting costs it NO extra run: the leg already ran per file.
[ "$(jq_ff "$B1" 'd["verdict"]')" = pass ] \
  && ok "24p. CONTROL: the honest FLAT two-file (files-mode) ticket still passes" \
  || bad "24p. the guard parked the honest flat two-file ticket"
[ "$(jq_ff "$B1" 'd["declaredRan"]["method"]')" = leg-invocations ] \
  && ok "24q. and files mode is accounted from the leg's OWN invocations (no extra run)" \
  || bad "24q. declaredRan.method was '$(jq_ff "$B1" 'd["declaredRan"]["method"]')' (expected leg-invocations)"
# --- 24r. AN HONEST SINGLE-FILE TICKET IS UNCHANGED. ----------------------
B32="$(mkbase --files 2 --sleep 0 --tip flat1)"
ff "$B32" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B32" 'd["verdict"]')" = pass ] \
  && ok "24r. CONTROL: an honest SINGLE-file ticket still passes" \
  || bad "24r. the guard parked an honest single-file ticket: $(jq_ff "$B32" 'd["reason"]' | head -c 250)"
# --- 24s. A REPO WHOSE ONLY TEST IS THE DECLARED ONE (the moot shape that
#          parked five honest tickets in S308 round 2) STILL PASSES.
B33="$(mkbase --files 0 --sleep 0 --tip flat1)"
ff "$B33" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B33" 'd["verdict"]')" = pass ] \
  && ok "24s. CONTROL: a repo whose WHOLE suite is the ticket's one declared file passes" \
  || bad "24s. the guard parked the moot one-file shape: $(jq_ff "$B33" 'd["reason"]' | head -c 250)"
# --- 24t. The zero-numbers control repo of section 23 still passes. --------
[ "$(jq_ff "$B26" 'd["verdict"]')" = pass ] \
  && ok "24t. CONTROL: the repo whose zero-run prints no numbers still passes" \
  || bad "24t. the guard parked the no-numbers repo of section 23"

# ===========================================================================
# 25. S318 FIX ROUND 1 — THE HONEST SHAPES THE FIRST CUT PARKED, AND THE TWO
#     WAYS ITS ACCOUNTING COULD STILL BE SATISFIED FALSELY.
#
#     A captain-stand-in tester drove 50 real fixtures against section 24's
#     guard. The four refusals held, but:
#
#     D1  FALSE REFUSAL. A ticket with >=2 declared files in a repo whose test
#         count the harness cannot parse was refused EVEN WHEN BOTH FILES RAN
#         GREEN — measured on THREE independent runners (python unittest's
#         `Ran 3 tests in 0.000s`/`OK`, TAP's `1..2`/`ok 1`, and a bare
#         `N passed, 0 failed`). The committed code says `pass`. A SINGLE-file
#         ticket on the same repo passed, so the refusal was purely a function
#         of file count: every multi-file ticket on such a repo, forever.
#     D2  FALSE REFUSAL. An honest multi-file ticket was refused when the
#         repo's test command always runs a FIXED EXTRA SUITE alongside the
#         scope (a global smoke suite, a jest `projects` config, a Makefile
#         target). Measured `tests 6 / pass 6` with both declared files
#         executing, but each per-file run carried the same fixed 4-test
#         overhead, so `5 + 5 > 6` and the gate said "the leg cannot have run
#         all of them" — which is FALSE.
#     D3  FALSE PASS. A per-file run was credited to a file it never touched: a
#         declared file that is unmatchable AND genuinely RED was credited `=1`
#         by a SIBLING file's output, because the file's own run selected
#         nothing and the runner fell back to its own discovery.
#     D4  FALSE PASS. A ZERO-BYTE declared test file was certified as
#         "executed at least one test" because `node --test` counts an empty
#         file as one test. (The all-`test.skip` equivalent was already
#         correctly refused, which is what made this an oversight.)
#     D6  a per-file run that TIMED OUT was stored as `unreadable` and
#         described as "no run executed a single test out of <file>" — a
#         timeout reported as a zero.
#     D7  a genuinely RED tip leg reported only "could not account for the
#         declared files", masking the real cause.
#
#     THE CURE, and why it is a MEASUREMENT and not a parser: the per-file
#     re-run is replaced by an ABLATION. The repo's own testCommand is re-run
#     with the LEG'S OWN SCOPE and the declared file MOVED ASIDE, and the file's
#     CONTRIBUTION is `legExecuted - thatRun`. A fixed extra suite is present in
#     both numbers and CANCELS (D2). A file the selection cannot see changes
#     nothing when it is removed, so its contribution is 0 and no sibling's
#     output can be credited to it (D3) — with no identity check and no command
#     shape recognised. D1 is cured where its cause actually is: the harness was
#     missing three ordinary runner grammars, so the count it called unreadable
#     was printed right there in the output.
# ===========================================================================
echo "-- 25. the honest shapes, and the two false satisfactions --"

# A repo whose runner output the harness could not count at all. Three real
# grammars, each wrapped around the same honest node run so the TESTS are
# identical and only the SUMMARY LINE differs.
UNREAD_UNITTEST='o=$(node --test --test-reporter=tap --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js") 2>&1); r=$?; n=$(printf "%s\n" "$o" | grep -cE "^(not )?ok "); echo "Ran $n tests in 0.000s"; if [ $r = 0 ]; then echo OK; else echo "FAILED (failures=1)"; fi; exit $r'
UNREAD_TAP='o=$(node --test --test-reporter=tap --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js") 2>&1); r=$?; n=$(printf "%s\n" "$o" | grep -cE "^(not )?ok "); echo "1..$n"; i=1; while [ $i -le $n ]; do echo "ok $i - t"; i=$((i+1)); done; exit $r'
UNREAD_BARE='o=$(node --test --test-reporter=tap --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js") 2>&1); r=$?; n=$(printf "%s\n" "$o" | grep -cE "^(not )?ok "); echo "$n passed, 0 failed"; exit $r'

# --- 25a-f. D1: an honest TWO-file ancestor ticket on a repo whose count the
#            harness could not read. Measured `inconclusive` on all three.
B34="$(mkbase --files 2 --sleep 0 --tip nested)"
cfg_set_testcmd "$B34" "$UNREAD_UNITTEST"
ff "$B34" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B34" 'd["gate"]["scopeKind"]')" = ancestor ] \
  && ok "25a. the unittest-grammar repo really is in the ANCESTOR state" \
  || bad "25a. scopeKind was '$(jq_ff "$B34" 'd["gate"]["scopeKind"]')'"
[ "$(jq_ff "$B34" 'd["verdict"]')" = pass ] \
  && ok "25b. D1: an honest 2-file ticket PASSES on a python-unittest-grammar repo" \
  || bad "25b. FALSE REFUSAL (unittest grammar) — verdict '$(jq_ff "$B34" 'd["verdict"]')': $(jq_ff "$B34" 'd["reason"]' | head -c 220)"
B35="$(mkbase --files 2 --sleep 0 --tip nested)"
cfg_set_testcmd "$B35" "$UNREAD_TAP"
ff "$B35" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B35" 'd["verdict"]')" = pass ] \
  && ok "25c. D1: an honest 2-file ticket PASSES on a TAP-grammar repo" \
  || bad "25c. FALSE REFUSAL (TAP) — verdict '$(jq_ff "$B35" 'd["verdict"]')': $(jq_ff "$B35" 'd["reason"]' | head -c 220)"
B36="$(mkbase --files 2 --sleep 0 --tip nested)"
cfg_set_testcmd "$B36" "$UNREAD_BARE"
ff "$B36" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B36" 'd["verdict"]')" = pass ] \
  && ok "25d. D1: an honest 2-file ticket PASSES on a bare 'N passed, N failed' repo" \
  || bad "25d. FALSE REFUSAL (bare passed/failed) — verdict '$(jq_ff "$B36" 'd["verdict"]')': $(jq_ff "$B36" 'd["reason"]' | head -c 220)"
# And the SAME repo still refuses the D9 shape, so curing D1 did not open it.
B37="$(mkbase --files 2 --sleep 0 --tip nested)"
d9_tip "$B37" tests/a/b '../../..'
set_declared "$B37" '["tests/a/ticket_up.test.js","tests/a/b/ticket_down_spec.js"]'
cfg_set_testcmd "$B37" "$UNREAD_UNITTEST"
ff "$B37" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B37" 'd["verdict"]')" = inconclusive ] \
  && ok "25e. and the D9 shape on that SAME countable-now repo is STILL refused" \
  || bad "25e. FALSE PASS — curing D1 opened the D9 shape: verdict '$(jq_ff "$B37" 'd["verdict"]')'"
# A genuinely countless runner (the quiet CI wrapper) is still refused BY NAME.
[ "$(jq_ff "$B29" 'd["declaredRan"]["method"]')" = unreadable-runner ] \
  && ok "25f. a genuinely countless runner is still refused by name" \
  || bad "25f. declaredRan.method was '$(jq_ff "$B29" 'd["declaredRan"]["method"]')'"

# --- 25g-i. D2: the repo whose test command always runs a FIXED EXTRA SUITE.
# The FIXED EXTRA SUITE is the fixture's own four-module flat suite, which lives
# in the PARENT commit and is therefore not in the ticket's diff: the leg's scope
# is tests/a, and the testCommand ALWAYS appends the four slow modules on top of
# whatever the scope selects — a global smoke suite, a jest `projects` config, a
# Makefile `test` target. Both declared files run, and each ablation run carries
# the SAME fixed 4-test overhead, which is what defeated round 1.
B38="$(mkbase --files 4 --sleep 0 --tip nested)"
cfg_set_testcmd "$B38" 'node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js") $(find tests -maxdepth 1 -name "slow_*.test.js")'
ff "$B38" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B38" 'd["executed"]["tip"]')" = 6 ] \
  && ok "25g. the fixture bites: the leg executes 6 (2 declared + the fixed 4)" \
  || bad "25g. the leg executed '$(jq_ff "$B38" 'd["executed"]["tip"]')' (expected 6)"
[ "$(jq_ff "$B38" 'd["verdict"]')" = pass ] \
  && ok "25h. D2: the fixed-extra-suite repo's honest 2-file ticket PASSES" \
  || bad "25h. FALSE REFUSAL (fixed extra suite) — verdict '$(jq_ff "$B38" 'd["verdict"]')': $(jq_ff "$B38" 'd["reason"]' | head -c 260)"
case "$(jq_ff "$B38" 'd["declaredRan"]["each"]')" in
  *ticket_up.test.js=1*) ok "25i. and each file's CONTRIBUTION is recorded net of the fixed overhead" ;;
  *) bad "25i. declaredRan.each was '$(jq_ff "$B38" 'd["declaredRan"]["each"]')' (expected a contribution of 1 per file)" ;;
esac

# --- 25j-l. D3: a per-file run credited to a file it never touched. A sibling
#            emits runner-shaped lines; the unmatchable RED file must NOT be
#            credited with them.
B39="$(mkbase --files 2 --sleep 0 --tip nested)"
d9_tip "$B39" tests/a/b '../../..'
set_declared "$B39" '["tests/a/ticket_up.test.js","tests/a/b/ticket_down_spec.js"]'
( cd "$B39/repo" && cat >tests/a/forge.test.js <<'JSFORGE'
const { test } = require('node:test');
// THE FORGERY: runner-shaped lines emitted only when the scope is a DIRECTORY,
// so a per-file run of a sibling could be credited with this file's numbers.
if (process.env.LCARS_TESTS_DIR) {
  try {
    if (require('node:fs').statSync(process.env.LCARS_TESTS_DIR).isDirectory()) {
      console.log('ℹ tests 99'); console.log('ℹ pass 99'); console.log('ℹ fail 0');
    }
  } catch (e) {}
}
test('forge', () => {});
JSFORGE
  git add -A && git commit -q --amend --no-edit ) >/dev/null 2>&1
set_declared "$B39" '["tests/a/ticket_up.test.js","tests/a/b/ticket_down_spec.js","tests/a/forge.test.js"]'
RED39="$( cd "$B39/repo" && node --test --test-concurrency=1 tests/a/b/ticket_down_spec.js 2>&1 )"
printf '%s' "$RED39" | grep -q 'fail 1' \
  && ok "25j. the fixture bites: the unmatchable declared file is RED on the tip" \
  || bad "25j. the fixture does not bite — the declared _spec file is not red"
ff "$B39" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B39" 'd["verdict"]')" != pass ] \
  && ok "25k. D3: the forged sibling cannot buy a PASS for the unmatchable RED file" \
  || bad "25k. FALSE PASS (D3) — verdict pass, each=$(jq_ff "$B39" 'd["declaredRan"]["each"]')"
case "$(jq_ff "$B39" 'd["declaredRan"]["each"]')" in
  *ticket_down_spec.js=[1-9]*) bad "25l. the unmatchable RED file was CREDITED with a contribution: $(jq_ff "$B39" 'd["declaredRan"]["each"]')" ;;
  *) ok "25l. and the unmatchable RED file is never CREDITED with a contribution" ;;
esac

# --- 25m-n. D4: a ZERO-BYTE declared test file is not a test that ran.
B40="$(mkbase --files 2 --sleep 0 --tip nested)"
( cd "$B40/repo" && : >tests/a/b/ticket_down.test.js \
  && git add -A && git commit -q --amend --no-edit ) >/dev/null 2>&1
[ ! -s "$B40/repo/tests/a/b/ticket_down.test.js" ] \
  && ok "25m. the fixture bites: the declared tests/a/b/ticket_down.test.js is ZERO BYTES" \
  || bad "25m. the declared file is not empty"
ff "$B40" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B40" 'd["verdict"]')" != pass ] \
  && ok "25n. D4: an EMPTY declared test file cannot be certified as having run a test" \
  || bad "25n. FALSE PASS (D4) — an empty declared file was credited: each=$(jq_ff "$B40" 'd["declaredRan"]["each"]')"

# --- 25o-p. D7: a genuinely RED tip leg says so, instead of "could not
#            account for the declared files".
B41="$(mkbase --files 2 --sleep 0 --tip nested)"
( cd "$B41/repo" && cat >tests/a/b/ticket_down.test.js <<'JSREDTIP'
const { test } = require('node:test');
const assert = require('node:assert');
// A HONEST, DISCOVERABLE declared test that is simply RED on the tip.
test('down works', () => { assert.strictEqual(1, 2); });
JSREDTIP
  git add -A && git commit -q --amend --no-edit ) >/dev/null 2>&1
ff "$B41" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B41" 'd["verdict"]')" = fail ] \
  && ok "25o. D7: a genuinely RED tip leg is a FAIL, not an accounting refusal" \
  || bad "25o. verdict was '$(jq_ff "$B41" 'd["verdict"]')' on a genuinely red tip leg"
case "$(jq_ff "$B41" 'd["reason"]')" in
  *"TIP leg is RED"*) ok "25p. and the reason is the REAL red, not the accounting" ;;
  *) bad "25p. the reason masked the real red: $(jq_ff "$B41" 'd["reason"]' | head -c 200)" ;;
esac

# --- 25q-s. D5: the remediation advice is KEYED TO THE REASON. The `_spec.js`
#            rename advice must not be appended to a refusal it cannot explain.
case "$(jq_ff "$B29" 'd["reason"]')" in
  *"the way the existing selection expects"*) bad "25q. the countless-runner refusal still tells him to rename correct files" ;;
  *) ok "25q. D5: the countless-runner refusal does NOT advise renaming files" ;;
esac
case "$(jq_ff "$B29" 'd["reason"]')" in
  *"print its runner's own summary"*) bad "25r. it still advises printing a summary the command already prints" ;;
  *) ok "25r. and it does not advise printing a summary the command already prints" ;;
esac
case "$(jq_ff "$B30" 'd["reason"]')" in
  *"the way the existing selection expects"*) bad "25s. the unscoped-command refusal still advises renaming files" ;;
  *) ok "25s. and the unscoped-command refusal does not advise renaming files either" ;;
esac
# --- 25t. the ancestor refusal — the one the rename advice DOES explain —
#          still carries it.
case "$(jq_ff "$B27" 'd["reason"]')" in
  *"the way the existing selection expects"*) ok "25t. the refusal the rename advice DOES explain still carries it" ;;
  *) bad "25t. the ancestor refusal lost its remediation: $(jq_ff "$B27" 'd["reason"]' | head -c 220)" ;;
esac

# --- 25u. D6: a per-file ablation that TIMED OUT is reported as a timeout,
#          never as "no run executed a single test out of <file>".
B42="$(mkbase --files 2 --sleep 0 --tip nested)"
cfg_set_testcmd "$B42" 'if [ -f "$LCARS_TESTS_DIR/ticket_up.test.js" ] && [ ! -f "$LCARS_TESTS_DIR/b/ticket_down.test.js" ]; then sleep 600; fi; node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
# The ablation's budget is proof_control_budget, i.e. the repo's recorded
# gateTimeout — so record a SMALL one, or this row alone costs the suite 120s.
cfg_set_gate "$B42" 8
ff "$B42" LCARS_GATE_TIMEOUT=8
case "$(jq_ff "$B42" 'd["reason"]')$(jq_ff "$B42" 'd["declaredRan"]["each"]')" in
  *timed*out*|*timeout*) ok "25u. D6: an ablation run that TIMED OUT is reported as a timeout" ;;
  *) bad "25u. a timed-out ablation was not reported as one: each='$(jq_ff "$B42" 'd["declaredRan"]["each"]')' reason='$(jq_ff "$B42" 'd["reason"]' | head -c 240)'" ;;
esac

# --- 25v-y. THE HONEST SHAPES THE TESTER DROVE, re-driven here as controls.
B43="$(mkbase --files 2 --sleep 0 --tip nested)"
( cd "$B43/repo" && mkdir -p "tests/a/deep nest" \
  && git mv tests/a/b/ticket_down.test.js "tests/a/deep nest/ticket down.test.js" \
  && "${LCARS_PYTHON_BIN:-python3}" - .git/lcars/missions/m-001/tickets/t-001/result.json <<'SPPY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["newTests"] = ["tests/a/ticket_up.test.js", "tests/a/deep nest/ticket down.test.js"]
open(p, "w").write(json.dumps(d, indent=1) + "\n")
SPPY
  sed -i.bak 's#\.\./\.\./\.\./src/down\.js#../../../src/down.js#' "tests/a/deep nest/ticket down.test.js"
  rm -f "tests/a/deep nest/ticket down.test.js.bak"
  git add -A && git commit -q --amend --no-edit ) >/dev/null 2>&1
# A SPACE-SAFE testCommand, because the fixture's default one word-splits an
# unquoted substitution and so cannot run ANY path with a space in it — that is
# the command's limit, not the guard's. (`-print0 | xargs -0` is space-safe but
# its EMPTY-scope control output is unreadable, so S308's own narrowing refusal
# fires before this check is ever asked — measured, and also not this guard.)
cfg_set_testcmd "$B43" 'node --test --test-concurrency=1 "$LCARS_TESTS_DIR"'
ff "$B43" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B43" 'd["verdict"]')" = pass ] \
  && ok "25v. CONTROL: a declared filename WITH SPACES in a deep subdirectory passes" \
  || bad "25v. the guard parked a filename with spaces: $(jq_ff "$B43" 'd["reason"]' | head -c 240)"
# A repo whose WHOLE suite is the two declared files.
B44="$(mkbase --files 0 --sleep 0 --tip nested)"
ff "$B44" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B44" 'd["verdict"]')" = pass ] \
  && ok "25w. CONTROL: a repo whose WHOLE suite is the two declared files passes" \
  || bad "25w. the guard parked the whole-suite-is-the-ticket shape: $(jq_ff "$B44" 'd["reason"]' | head -c 240)"
# THREE declared files sharing an ancestor.
B45="$(mkbase --files 2 --sleep 0 --tip nested)"
( cd "$B45/repo" && printf 'exports.side = (s) => String(s).trim();\n' >src/side.js \
  && cat >tests/a/ticket_side.test.js <<'JS3'
const { test } = require('node:test');
const assert = require('node:assert');
const { side } = require('../../src/side.js');
test('side works', () => { assert.strictEqual(side(' x '), 'x'); });
JS3
  git add -A && git commit -q --amend --no-edit ) >/dev/null 2>&1
set_declared "$B45" '["tests/a/ticket_up.test.js","tests/a/b/ticket_down.test.js","tests/a/ticket_side.test.js"]'
ff "$B45" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B45" 'd["verdict"]')" = pass ] \
  && ok "25x. CONTROL: THREE declared files sharing an ancestor pass" \
  || bad "25x. the guard parked a three-file ticket: $(jq_ff "$B45" 'd["reason"]' | head -c 240)"
# The ablation RESTORES the tree it measured on — nothing is left moved aside.
( cd "$B45/repo" && git status --porcelain ) 2>/dev/null | grep -q . \
  && bad "25y. the ablation left the worktree DIRTY: $( cd "$B45/repo" && git status --porcelain | head -5 | tr '\n' ' ')" \
  || ok "25y. and the ablation left the worktree exactly as it found it"

# --- 25z-ac. S318 FIX ROUND 2 — THE DATA-LOSS WINDOW ON THE CAPTAIN'S OWN
#             WORKING TREE.
# The ablation COPIES a declared test file aside, REMOVES it from the real
# worktree, re-runs the repo's own test command (minutes, on the slow-suite repo
# class this whole feature exists for), and only then puts it back. There was no
# `trap`. For the whole of that window the captain's file existed ONLY in
# $TMPDIR — and this laptop idle-sleeps after one minute on mains, an
# orchestrator dying mid-run is a recurring event here, and `rm -f` on a test
# file the worker has only just written on the tip is NOT recoverable from git.
# So: kill the gate while an ablation is in flight and the file must come back.
abl_dirs() { # → how many lcars-ablate.* holding dirs exist right now
  ls -d "${TMPDIR:-/tmp}"/lcars-ablate.* 2>/dev/null | grep -c . | tr -d ' '
}
# A KNOWN-GOOD CONTROL FOR THE COUNTER ITSELF. A glob that matches nothing reads
# exactly like a clean result, so prove the counter can SEE such a directory
# before any row trusts it to report zero.
ABL_BASE="$(abl_dirs)"
ABL_DECOY="$(mktemp -d "${TMPDIR:-/tmp}/lcars-ablate.XXXXXX")"
[ "$(abl_dirs)" -gt "$ABL_BASE" ] \
  && ok "25z. CONTROL: the holding-dir counter can see an lcars-ablate.* directory" \
  || bad "25z. the holding-dir counter is blind — it reported $(abl_dirs) with a decoy at $ABL_DECOY present"
rm -rf "$ABL_DECOY"
[ "$(abl_dirs)" = "$ABL_BASE" ] \
  || bad "25z. the holding-dir baseline is not stable: $(abl_dirs) != $ABL_BASE"

# An HONEST two-file ancestor ticket, driven to completion AFTER the baseline
# was taken: the holding dir must not be left behind.
B46="$(mkbase --files 2 --sleep 0 --tip nested)"
ff "$B46" LCARS_GATE_TIMEOUT=30
[ "$(jq_ff "$B46" 'd["verdict"]')" = pass ] \
  && ok "25aa. CONTROL: an honest two-file ancestor ticket still passes" \
  || bad "25aa. the honest two-file ticket stopped passing: $(jq_ff "$B46" 'd["reason"]' | head -c 240)"
( cd "$B46/repo" && git status --porcelain ) 2>/dev/null | grep -q . \
  && bad "25ab. the completed ablation left the worktree DIRTY: $( cd "$B46/repo" && git status --porcelain | head -5 | tr '\n' ' ')" \
  || ok "25ab. and it left the worktree exactly as it found it"
[ "$(abl_dirs)" = "$ABL_BASE" ] \
  && ok "25ac. a COMPLETED ablation leaves no lcars-ablate.* holding directory behind" \
  || bad "25ac. a completed ablation leaked $(( $(abl_dirs) - ABL_BASE )) holding dir(s): $(ls -d "${TMPDIR:-/tmp}"/lcars-ablate.* 2>/dev/null | tail -3 | tr '\n' ' ')"

# THE ROW THAT MATTERS. The testCommand sleeps ONLY while the first declared
# file is absent — i.e. only inside the ablation window — so the window is wide
# and the timing is reliable. The gate is started in its OWN SESSION (the same
# perl/setsid trick run.sh itself uses) so the test can TERM the whole process
# group, which is what a dying orchestrator, a Ctrl-C and a sleeping laptop all
# do.
B47="$(mkbase --files 2 --sleep 0 --tip nested)"
# The sleep is keyed to the EXACT tree the first ablation makes — up gone, down
# still there — so neither the leg (both present) nor the empty-scope control
# (neither present) is slowed by it. Keying it to `up` alone would hang the
# control instead and the gate would refuse before any ablation ran: measured.
cfg_set_testcmd "$B47" 'if [ ! -f "$LCARS_TESTS_DIR/ticket_up.test.js" ] && [ -f "$LCARS_TESTS_DIR/b/ticket_down.test.js" ]; then sleep 30; fi; node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
cfg_set_gate "$B47" 25
VICTIM="$B47/repo/tests/a/ticket_up.test.js"
cp -p "$VICTIM" "$B47/victim.orig"
( cd "$B47/repo" && exec env PATH="$B47/shim:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN=git \
    LCARS_GATE_TIMEOUT=25 \
    perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- \
    bash "$RUN_SH" flip-flop-gate-test --mission m-001 --ticket t-001 \
      --sha "$(parent_of "$B47")" ) >"$B47/kill.out" 2>&1 &
KPID=$!
# Wait for the ablation to actually take the file out of the tree.
KW=0; KSAW=
while [ "$KW" -lt 60 ]; do
  if [ ! -f "$VICTIM" ]; then KSAW=1; break; fi
  kill -0 "$KPID" 2>/dev/null || break
  sleep 0.5; KW=$((KW + 1))
done
if [ -z "$KSAW" ]; then
  bad "25ad. the rig never observed the ablation window (the declared file was never moved aside) — nothing was proven"
  kill -TERM -"$KPID" 2>/dev/null || kill -TERM "$KPID" 2>/dev/null || true
else
  ok "25ad. CONTROL: the ablation really does remove the declared file from the real worktree"
  # KILL IT, exactly as a dying orchestrator would.
  kill -TERM -"$KPID" 2>/dev/null || kill -TERM "$KPID" 2>/dev/null || true
  KW=0
  while [ "$KW" -lt 40 ] && kill -0 "$KPID" 2>/dev/null; do sleep 0.5; KW=$((KW + 1)); done
  wait "$KPID" 2>/dev/null || true
  # Give the restore a moment to land, then judge.
  KW=0
  while [ "$KW" -lt 20 ] && [ ! -f "$VICTIM" ]; do sleep 0.5; KW=$((KW + 1)); done
  if [ ! -f "$VICTIM" ]; then
    bad "25ae. DATA LOSS: the gate was killed mid-ablation and the captain's declared test file tests/a/ticket_up.test.js is GONE from the working tree"
  elif cmp -s "$VICTIM" "$B47/victim.orig"; then
    ok "25ae. a gate killed mid-ablation puts the declared test file BACK, byte for byte"
  else
    bad "25ae. the declared test file came back CHANGED after a mid-ablation kill: $(diff "$B47/victim.orig" "$VICTIM" | head -4 | tr '\n' ' ')"
  fi
  ( cd "$B47/repo" && git status --porcelain ) 2>/dev/null | grep -q . \
    && bad "25af. a killed ablation left the worktree DIRTY: $( cd "$B47/repo" && git status --porcelain | head -5 | tr '\n' ' ')" \
    || ok "25af. and the worktree it was killed in is exactly as it was found"
  [ "$(abl_dirs)" = "$ABL_BASE" ] \
    && ok "25ag. a KILLED ablation leaves no lcars-ablate.* holding directory behind either" \
    || bad "25ag. a killed ablation leaked $(( $(abl_dirs) - ABL_BASE )) holding dir(s): $(ls -d "${TMPDIR:-/tmp}"/lcars-ablate.* 2>/dev/null | tail -3 | tr '\n' ' ')"
fi

# --- 25ah-aj. A RESTORE THAT GENUINELY FAILS still aborts by name, and the
#              held copy is STILL THERE afterwards. The rescue handler removes
#              the holding directory on every other path, and this is the one
#              path where that would BE the data loss: the abort's own reason
#              hands the captain that path as his way back.
# Forced by making the scope directory read-only from inside the testCommand,
# at the exact moment the first declared file is out of the tree — so the `cp`
# back cannot land.
B48="$(mkbase --files 2 --sleep 0 --tip nested)"
cfg_set_testcmd "$B48" 'if [ ! -f "$LCARS_TESTS_DIR/ticket_up.test.js" ] && [ -f "$LCARS_TESTS_DIR/b/ticket_down.test.js" ]; then chmod 500 "$LCARS_TESTS_DIR"; fi; node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
ff "$B48" LCARS_GATE_TIMEOUT=30
AB_REASON="$(jq_ff "$B48" 'd["reason"]')"
[ "$(jq_ff "$B48" 'd["declaredRan"]["method"]')" = ablation-aborted ] \
  && ok "25ah. a failed restore still aborts the accounting BY NAME (ablation-aborted)" \
  || bad "25ah. a failed restore did not abort by name: method='$(jq_ff "$B48" 'd["declaredRan"]["method"]')' reason='$(printf '%s' "$AB_REASON" | head -c 240)'"
AB_HELD="$(printf '%s' "$AB_REASON" | sed -n 's/.*the file is held at \([^ ]*\).*/\1/p' | head -1)"
case "$AB_HELD" in
  */lcars-ablate.*/held.*) ok "25ai. and it names the exact holding path the captain can recover from" ;;
  *) bad "25ai. the abort named no holding path: reason='$(printf '%s' "$AB_REASON" | head -c 300)'" ;;
esac
[ -n "$AB_HELD" ] && [ -f "$AB_HELD" ] \
  && ok "25aj. and that held copy SURVIVES the gate exiting — the rescue does not delete the only copy" \
  || bad "25aj. the held copy named in the refusal is GONE: '$AB_HELD'"
# Hand the fixture back its write bit so teardown can remove it, and drop the
# holding directory this row deliberately preserved.
chmod 700 "$B48/repo/tests/a" 2>/dev/null || true
[ -n "$AB_HELD" ] && rm -rf "$(dirname "$AB_HELD")" 2>/dev/null || true
[ "$(abl_dirs)" = "$ABL_BASE" ] \
  || bad "25ak. the abort row left extra holding dirs behind: $(ls -d "${TMPDIR:-/tmp}"/lcars-ablate.* 2>/dev/null | tail -3 | tr '\n' ' ')"

# --- 25al-at. S318 FIX ROUND 3 — A SYMLINKED DECLARED TEST FILE IS NOT
#              ABLATED, SO A PASSING GATE CANNOT DESTROY IT.
# MEASURED (twice, reproduction preserved): the ablation's `cp -p` FOLLOWS a
# symlink, the `rm` removes the link, and the restore writes a REGULAR FILE in
# its place. A completely normal, successful, signal-free gate run therefore
# turned `tests/a/linked.test.js -> ticket_up.test.js` into a 306-byte regular
# file, left the tree `T tests/a/linked.test.js`, and returned a PASS verdict
# with no mention of it anywhere in the artifact. Tree damage on a PASS, silent
# — the exact combination this session exists to prevent. Content survived only
# because the file was TRACKED; an untracked symlink has no way back at all.
mk_symlink_base() { # → base dir with tests/a/linked.test.js as a committed symlink
  local b; b="$(mkbase --files 2 --sleep 0 --tip nested)"
  ( cd "$b/repo" && ln -s ticket_up.test.js tests/a/linked.test.js \
    && git add -A && git commit -q --amend --no-edit ) >/dev/null 2>&1
  set_declared "$b" '["tests/a/ticket_up.test.js","tests/a/b/ticket_down.test.js","tests/a/linked.test.js"]'
  printf '%s' "$b"
}
B49="$(mk_symlink_base)"
LINK="$B49/repo/tests/a/linked.test.js"
# A KNOWN-GOOD CONTROL FOR EVERY CHECK THIS SECTION MAKES. A `[ -L ]` on a path
# that is not there, or a `git ls-files -s` that matches nothing, reads exactly
# like a clean result — so prove the fixture really holds a committed symlink,
# and that the mode reader can SEE its 120000, before any row trusts them.
LINK_MODE_BEFORE="$( cd "$B49/repo" && git ls-files -s tests/a/linked.test.js | awk '{print $1}' )"
if [ -L "$LINK" ] && [ "$LINK_MODE_BEFORE" = 120000 ]; then
  ok "25al. CONTROL: the fixture holds a COMMITTED symlink and the mode reader sees its 120000"
else
  bad "25al. the symlink fixture was not built — [ -L ]=$( [ -L "$LINK" ] && echo yes || echo no ) git-mode='$LINK_MODE_BEFORE' (nothing below proves anything)"
fi
( cd "$B49/repo" && git status --porcelain ) 2>/dev/null | grep -q . \
  && bad "25al. the symlink fixture started DIRTY: $( cd "$B49/repo" && git status --porcelain | head -3 | tr '\n' ' ')" \
  || ok "25al2. CONTROL: and it starts from a clean tree"
LINK_TARGET_BEFORE="$(readlink "$LINK" 2>/dev/null)"
ff "$B49" LCARS_GATE_TIMEOUT=40
# THE DEFECT, STATED AS THE TREE. Whatever the verdict, the gate may not have
# changed what this path IS.
if [ -L "$LINK" ]; then
  ok "25am. a declared SYMLINK is still a symlink after the gate ran"
else
  bad "25am. TREE DAMAGE: the gate turned the declared symlink tests/a/linked.test.js into a $( [ -f "$LINK" ] && printf 'regular file of %s bytes' "$(wc -c <"$LINK" | tr -d ' ')" || printf 'non-existent path')"
fi
[ "$(readlink "$LINK" 2>/dev/null)" = "$LINK_TARGET_BEFORE" ] \
  && ok "25an. and it still points at the same target ($LINK_TARGET_BEFORE)" \
  || bad "25an. the link target changed: '$LINK_TARGET_BEFORE' -> '$(readlink "$LINK" 2>/dev/null)'"
[ "$( cd "$B49/repo" && git ls-files -s tests/a/linked.test.js | awk '{print $1}' )" = 120000 ] \
  && ok "25ao. git still records it at mode 120000" \
  || bad "25ao. git now records mode '$( cd "$B49/repo" && git ls-files -s tests/a/linked.test.js | awk '{print $1}' )' for the declared symlink"
( cd "$B49/repo" && git status --porcelain ) 2>/dev/null | grep -q . \
  && bad "25ap. the gate left the worktree DIRTY: $( cd "$B49/repo" && git status --porcelain | head -5 | tr '\n' ' ') / $( cd "$B49/repo" && git diff --summary | head -3 | tr '\n' ' ')" \
  || ok "25ap. and the worktree is exactly as it was found (git status empty)"
# AND IT IS NOT SILENT. The artifact must SAY the link was not measured, in
# words, rather than quietly crediting or quietly damaging it.
SYM_REASON="$(jq_ff "$B49" 'd["reason"]')$(jq_ff "$B49" 'd["declaredRan"]["why"]')"
case "$SYM_REASON" in
  *"symbolic link"*|*symlink*) ok "25aq. and the artifact SAYS a symbolic link was not measured" ;;
  *) bad "25aq. the symlink is nowhere in the artifact's own words: verdict='$(jq_ff "$B49" 'd["verdict"]')' reason='$(printf '%s' "$SYM_REASON" | head -c 300)'" ;;
esac
[ "$(jq_ff "$B49" 'd["verdict"]')" = pass ] \
  && bad "25ar. a ticket with an UNMEASURED declared test file PASSED — the refusal was weakened" \
  || ok "25ar. and the leg is not a pass (verdict '$(jq_ff "$B49" 'd["verdict"]')') — an unmeasured declared file is never credited"

# THE SAME, KILLED MID-ABLATION. The regular declared file is still ablated, so
# the trap path is live while a symlink sits in the same scope: a signal must
# leave the regular file back byte-for-byte AND the symlink still a symlink.
B50="$(mk_symlink_base)"
cfg_set_testcmd "$B50" 'if [ ! -f "$LCARS_TESTS_DIR/ticket_up.test.js" ] && [ -f "$LCARS_TESTS_DIR/b/ticket_down.test.js" ]; then sleep 30; fi; node --test --test-concurrency=1 $(find "$LCARS_TESTS_DIR" -name "*.test.js")'
cfg_set_gate "$B50" 25
SVICTIM="$B50/repo/tests/a/ticket_up.test.js"
SLINK="$B50/repo/tests/a/linked.test.js"
cp -p "$SVICTIM" "$B50/victim.orig"
( cd "$B50/repo" && exec env PATH="$B50/shim:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN=git \
    LCARS_GATE_TIMEOUT=25 \
    perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- \
    bash "$RUN_SH" flip-flop-gate-test --mission m-001 --ticket t-001 \
      --sha "$(parent_of "$B50")" ) >"$B50/kill.out" 2>&1 &
SPID=$!
SW=0; SSAW=
while [ "$SW" -lt 60 ]; do
  if [ ! -f "$SVICTIM" ] && [ ! -L "$SVICTIM" ]; then SSAW=1; break; fi
  kill -0 "$SPID" 2>/dev/null || break
  sleep 0.5; SW=$((SW + 1))
done
if [ -z "$SSAW" ]; then
  bad "25as. the rig never observed the ablation window on the symlink repo — nothing was proven"
  kill -TERM -"$SPID" 2>/dev/null || kill -TERM "$SPID" 2>/dev/null || true
else
  ok "25as. CONTROL: the ablation window really opens on a repo holding a symlinked declared file"
  kill -TERM -"$SPID" 2>/dev/null || kill -TERM "$SPID" 2>/dev/null || true
  SW=0
  while [ "$SW" -lt 40 ] && kill -0 "$SPID" 2>/dev/null; do sleep 0.5; SW=$((SW + 1)); done
  wait "$SPID" 2>/dev/null || true
  SW=0
  while [ "$SW" -lt 20 ] && [ ! -f "$SVICTIM" ]; do sleep 0.5; SW=$((SW + 1)); done
  if [ -L "$SLINK" ] && [ "$(readlink "$SLINK")" = ticket_up.test.js ]; then
    ok "25at. a gate KILLED mid-ablation leaves the declared symlink a symlink"
  else
    bad "25at. a killed ablation destroyed the declared symlink: [ -L ]=$( [ -L "$SLINK" ] && echo yes || echo no ) target='$(readlink "$SLINK" 2>/dev/null)'"
  fi
  cmp -s "$SVICTIM" "$B50/victim.orig" \
    && ok "25au. and the regular declared file still comes back byte for byte" \
    || bad "25au. the regular declared file did not come back after the kill: $( [ -f "$SVICTIM" ] && diff "$B50/victim.orig" "$SVICTIM" | head -3 | tr '\n' ' ' || echo GONE)"
  ( cd "$B50/repo" && git status --porcelain ) 2>/dev/null | grep -q . \
    && bad "25av. the killed symlink repo was left DIRTY: $( cd "$B50/repo" && git status --porcelain | head -5 | tr '\n' ' ')" \
    || ok "25av. and that tree is exactly as it was found too"
  [ "$(abl_dirs)" = "$ABL_BASE" ] \
    || bad "25aw. the killed symlink row leaked $(( $(abl_dirs) - ABL_BASE )) holding dir(s)"
fi

# ===========================================================================
echo
printf 'gate-scope: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
