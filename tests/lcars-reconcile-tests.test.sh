#!/usr/bin/env bash
#
# Focused test for BUG-058 — the test-reconciliation step in the Mission-Log
# bug-fix Implement path (skill source: skills/lcars-run/run.sh reconcile_tests()
# + the `reconcile-tests` subcommand; template skills/lcars-run/stages/reconcile-tests.md).
#
# A logged bug that CHANGES existing behaviour must have the PARENT mission's
# existing locked tests RECONCILED to the new reality BEFORE the bug's own Test
# Writer/Implementer run — otherwise the suite becomes self-contradictory (the
# bug's new test asserts the small X while the parent's locked test still asserts
# the old big X, and the immutable-tests guardrail forbids the implementer from
# touching it).
#
# Everything is STUBBED — the cold reconciliation worker is a stub pointed at via
# LCARS_WORKER_BIN, gh is a stub. NO real model worker, NO network, NO tokens.
# Run ONLY this file:  bash tests/lcars-reconcile-tests.test.sh
#
# ⚠ This file NEVER drives tests/lcars-run.test.sh and spawns NO real worker.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"
WORKER_ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

BUG="lcars-20260622-bug"
PARENT="lcars-20260622-parent"

# --- gh stub: records calls, returns success ------------------------------
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
{ echo "gh $*"; } >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# --- the cold reconciliation worker stub ----------------------------------
# Finds its scratch outdir ($LCARS_WORK_OUT, else last existing dir in argv).
# Its behaviour is driven by env:
#   STUB_DECISION=reconciled → edit the parent test in place (shrink the X) and
#                              write a result.json with a "changed" list.
#   STUB_DECISION=reconciled_expr → BUG-060: edit the parent test in place to a
#                              COMPUTED/RELATIVE assertion ('(digitDisplayH / 3)px')
#                              instead of a guessed literal, and report it verbatim.
#   STUB_DECISION=reconciled_observed → BUG-063: edit the parent test in place to an
#                              assertion anchored on the OBSERVED render output
#                              ('(observedDigitHeight / 3)px', read from the recording
#                              ctx) — NOT a static input constant — and report it
#                              verbatim, proving the harness relays observed-value
#                              expressions intact (no flatten, no input-constant rewrite).
#   STUB_DECISION=noop       → edit nothing, result.json says noop.
#   STUB_DECISION=defer      → edit nothing, result.json carries a question.
# It also records the role + that it saw the parent test path in its prompt.
make_worker_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "ROLE=${LCARS_WORKER_ROLE:-} DECISION=${STUB_DECISION:-}" >>"$WORKER_LOG"
prompt=""; prev=""
for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
printf '%s\n----8<----\n' "$prompt" >>"$WORKER_PROMPT_LOG"
out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || for a in "$@"; do [ -d "$a" ] && out="$a"; done
[ -n "$out" ] || exit 0
case "${STUB_DECISION:-noop}" in
  reconciled)
    # Edit the parent's locked test in place: the bug shrank the X, so update the
    # size assertion from the old "bold 32px" to "numberHeight/3".
    if [ -n "${PARENT_TEST_FILE:-}" ] && [ -f "$PARENT_TEST_FILE" ]; then
      sed -i.bak 's/bold 32px/numberHeight\/3/' "$PARENT_TEST_FILE" 2>/dev/null \
        || sed -i '' 's/bold 32px/numberHeight\/3/' "$PARENT_TEST_FILE" 2>/dev/null || true
      rm -f "$PARENT_TEST_FILE.bak" 2>/dev/null || true
    fi
    cat >"$out/result.json" <<JSON
{
  "decision": "reconciled",
  "changed": [
    { "file": "${PARENT_TEST_FILE:-}", "change": "X size assertion: bold 32px -> numberHeight/3" }
  ]
}
JSON
    ;;
  reconciled_expr)
    # BUG-060: the bug defines the new value as a RELATIONSHIP ("⅓ of the digit
    # height"). The worker must rewrite the assertion to a COMPUTED EXPRESSION over
    # the test's own setup value — NOT a guessed literal. This stub edits the parent
    # test in place to exactly that relative expression and reports it verbatim in
    # the "change" field, to prove the harness applies/relays the expression as-is
    # (never flattens it to a literal).
    if [ -n "${PARENT_TEST_FILE:-}" ] && [ -f "$PARENT_TEST_FILE" ]; then
      sed -i.bak "s|bold 32px|' + (digitDisplayH / 3) + 'px|" "$PARENT_TEST_FILE" 2>/dev/null \
        || sed -i '' "s|bold 32px|' + (digitDisplayH / 3) + 'px|" "$PARENT_TEST_FILE" 2>/dev/null || true
      rm -f "$PARENT_TEST_FILE.bak" 2>/dev/null || true
    fi
    cat >"$out/result.json" <<JSON
{
  "decision": "reconciled",
  "changed": [
    { "file": "${PARENT_TEST_FILE:-}", "change": "X size assertion: bold 32px -> computed (digitDisplayH / 3)px (relative, not a guessed literal)" }
  ]
}
JSON
    ;;
  reconciled_observed)
    # BUG-063: the bug defines the new value as a RELATIONSHIP to a quantity the test
    # OBSERVES in its own render output ("⅓ of the digit's DRAWN height"). The code may
    # scale inputs, so the durable assertion reads the OBSERVED drawn height back from
    # the recording context and computes from THAT — never a static input constant. This
    # stub edits the parent test in place to exactly that observed-value expression and
    # reports it verbatim, proving the harness applies/relays it as-is.
    if [ -n "${PARENT_TEST_FILE:-}" ] && [ -f "$PARENT_TEST_FILE" ]; then
      sed -i.bak "s|bold 32px|' + (observedDigitHeight / 3) + 'px|" "$PARENT_TEST_FILE" 2>/dev/null \
        || sed -i '' "s|bold 32px|' + (observedDigitHeight / 3) + 'px|" "$PARENT_TEST_FILE" 2>/dev/null || true
      rm -f "$PARENT_TEST_FILE.bak" 2>/dev/null || true
    fi
    cat >"$out/result.json" <<JSON
{
  "decision": "reconciled",
  "changed": [
    { "file": "${PARENT_TEST_FILE:-}", "change": "X size assertion: bold 32px -> computed (observedDigitHeight / 3)px (anchored on OBSERVED render output, not a static input constant)" }
  ]
}
JSON
    ;;
  defer)
    cat >"$out/result.json" <<JSON
{
  "decision": "defer",
  "question": "The bug shrinks the score, but the high-score readout shares that corner — should it move?"
}
JSON
    ;;
  *)
    printf '{ "decision": "noop" }\n' >"$out/result.json"
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# --- build a logged-bug mission parked at implement, linked to a parent ----
# $1 = repo dir. The parent has one ticket with a locked test asserting the OLD
# behaviour ("bold 32px"). The bug's PRD intends to shrink the X.
new_bug_mission() { # repo  [bug-type override]
  local repo="$1" btype="${2:-bug}" parent="${3:-$PARENT}"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'orig\n' >f.txt && git add -A && git commit -q -m init )
  local mroot="$repo/.git/lcars/missions"
  mkdir -p "$mroot/$PARENT/tickets/t-002/tests"
  mkdir -p "$mroot/$BUG"
  # Parent's locked test — asserts the OLD behaviour.
  cat >"$mroot/$PARENT/tickets/t-002/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
# asserts the multiplier renders at bold 32px (the OLD, too-large size)
grep -q 'bold 32px' src/hud.js
EOF
  chmod +x "$mroot/$PARENT/tickets/t-002/tests/t.sh"
  cat >"$mroot/$PARENT/state.json" <<EOF
{
  "id": "$PARENT",
  "type": "feature",
  "title": "Score multiplier",
  "stage": "verify",
  "githubIssue": 46
}
EOF
  # The bug mission's PRD — intent + Out-of-Scope.
  cat >"$mroot/$BUG/prd.md" <<'EOF'
# Mission: the multiplier X is too large
**Type:** bug
**Goal:** shrink the multiplier's X so it is sized to numberHeight/3 instead of bold 32px.
**Out-of-Scope:** do NOT change the multiplier's value, position, or colour — only its size.
EOF
  cat >"$mroot/$BUG/state.json" <<EOF
{
  "id": "$BUG",
  "type": "$btype",
  "title": "the multiplier X is too large",
  "stage": "implement",
  "githubIssue": 53,
  "parentMission": "$([ "$btype" = bug ] && echo "$parent")",
  "branch": "lcars/$BUG",
  "base": "main"
}
EOF
  # minimal config + approved-plan so require_worker / locate are happy
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "testCommand": "true" }
EOF
  cat >"$mroot/$BUG/approved-plan.json" <<'EOF'
[ { "id": "b-001", "title": "shrink the X" } ]
EOF
}

# Run the reconcile-tests subcommand in the repo with the stub bins injected.
run_rt() { # repo  [extra-env...]  -- handled via caller env
  local repo="$1"; shift
  ( cd "$repo" \
      && WORKER_LOG="$repo.worker.log" WORKER_PROMPT_LOG="$repo.prompt.log" \
         GH_LOG="$repo.gh.log" \
         PARENT_TEST_FILE="$repo/.git/lcars/missions/$PARENT/tickets/t-002/tests/t.sh" \
         STUB_DECISION="${STUB_DECISION:-noop}" \
         LCARS_GH_BIN="$repo.gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" \
         LCARS_WORKER_BIN="$repo.worker" LCARS_WORKER_CLI="claude" \
         LCARS_WORKER_ADAPTER="$WORKER_ADAPTER" \
         bash "$RUN_SH" reconcile-tests --mission "$BUG" "$@" )
}

setup() { # repo
  make_gh_stub "$1.gh"; make_worker_stub "$1.worker"
  : >"$1.gh.log"; : >"$1.worker.log"; : >"$1.prompt.log"
}

state_of() { echo "$1/.git/lcars/missions/$BUG/state.json"; }
events_of() { echo "$1/.git/lcars/missions/$BUG/events.jsonl"; }
parent_test() { echo "$1/.git/lcars/missions/$PARENT/tickets/t-002/tests/t.sh"; }

echo "lcars reconcile-tests (BUG-058)"
[ -f "$RUN_SH" ] || { echo "run.sh not found at $RUN_SH"; exit 1; }

# === Case 1: a bug whose intent INVALIDATES a parent test → ADAPT + event + gh,
#             no gate. ====================================================
r1="$TMPROOT/r1"; mkdir -p "$r1"; new_bug_mission "$r1"; setup "$r1"
rc1=0; STUB_DECISION=reconciled run_rt "$r1" >"$r1.out" 2>&1 || rc1=$?
check "1. reconcile-tests exits 0 on a clean reconciliation" "[ '$rc1' -eq 0 ]"
check "1. the worker ran as role reconcile-tests" "grep -q 'ROLE=reconcile-tests' '$r1.worker.log'"
check "1. the worker's prompt referenced the parent's test suite path" \
  "grep -q '$PARENT/tickets/t-002/tests' '$r1.prompt.log'"
check "1. the parent's locked test was ADAPTED in place (old assertion gone)" \
  "! grep -q 'bold 32px' '$(parent_test "$r1")'"
check "1. the parent's locked test now asserts the new reality (numberHeight/3)" \
  "grep -q 'numberHeight/3' '$(parent_test "$r1")'"
check "1. a tests_reconciled event was emitted" \
  "grep -q '\"type\":\"tests_reconciled\"' '$(events_of "$r1")'"
check "1. the tests_reconciled event names the changed assertion" \
  "grep '\"type\":\"tests_reconciled\"' '$(events_of "$r1")' | grep -q 'numberHeight/3'"
check "1. a GitHub issue comment was posted (audit trail)" \
  "grep -q 'issue comment' '$r1.gh.log'"
check "1. the gh comment lists the reconciled test + why" \
  "grep -q 'numberHeight/3' '$r1.gh.log'"
check "1. NO awaiting-human gate was raised" \
  "! grep -q '\"awaitingHuman\": *true' '$(state_of "$r1")'"
check "1. NO pending.json was written" \
  "[ ! -f '$r1/.git/lcars/missions/$BUG/pending.json' ]"

# === Case 2: a bug that ADDS behaviour (nothing to reconcile) → no edits, no gate.
r2="$TMPROOT/r2"; mkdir -p "$r2"; new_bug_mission "$r2"; setup "$r2"
rc2=0; STUB_DECISION=noop run_rt "$r2" >"$r2.out" 2>&1 || rc2=$?
check "2. reconcile-tests exits 0 on a no-op" "[ '$rc2' -eq 0 ]"
check "2. the parent's locked test is UNCHANGED (still asserts the old behaviour)" \
  "grep -q 'bold 32px' '$(parent_test "$r2")'"
check "2. NO tests_reconciled event (nothing was reconciled)" \
  "! grep -q '\"type\":\"tests_reconciled\"' '$(events_of "$r2")'"
check "2. a tests_reconcile_noop event records the no-op" \
  "grep -q '\"type\":\"tests_reconcile_noop\"' '$(events_of "$r2")'"
check "2. NO GitHub comment on a no-op" "! grep -q 'issue comment' '$r2.gh.log'"
check "2. NO awaiting-human gate on a no-op" \
  "! grep -q '\"awaitingHuman\": *true' '$(state_of "$r2")'"

# === Case 3: design-ambiguity / beyond-parent-scope → raise awaiting-human gate.
r3="$TMPROOT/r3"; mkdir -p "$r3"; new_bug_mission "$r3"; setup "$r3"
rc3=0; STUB_DECISION=defer run_rt "$r3" >"$r3.out" 2>&1 || rc3=$?
s3="$(state_of "$r3")"
check "3. reconcile-tests exits 0 (stops cleanly at the gate)" "[ '$rc3' -eq 0 ]"
check "3. the parent's locked test was NOT edited on a defer" \
  "grep -q 'bold 32px' '$(parent_test "$r3")'"
check "3. an awaiting-human gate was raised" \
  "grep -q '\"awaitingHuman\": *true' '$s3'"
check "3. pending.json was written" \
  "[ -f '$r3/.git/lcars/missions/$BUG/pending.json' ]"
check "3. pending.json is tagged for the reconcile-tests stage" \
  "grep -q 'reconcile-tests' '$r3/.git/lcars/missions/$BUG/pending.json'"
check "3. a pendingQuestion was recorded" "grep -q 'pendingQuestion' '$s3'"
check "3. the lcars:awaiting-human label was applied" \
  "grep -q 'awaiting-human' '$r3.gh.log'"
check "3. a tests_reconcile_deferred event was emitted" \
  "grep -q '\"type\":\"tests_reconcile_deferred\"' '$(events_of "$r3")'"
check "3. NO tests_reconciled event on a defer" \
  "! grep -q '\"type\":\"tests_reconciled\"' '$(events_of "$r3")'"

# === Case 4: a TOP-LEVEL mission → reconciliation does NOT run (gating). ====
# The bug mission's state has type=feature + no parentMission → the step no-ops
# WITHOUT spawning any worker (the worker log stays empty).
r4="$TMPROOT/r4"; mkdir -p "$r4"; new_bug_mission "$r4" feature ""; setup "$r4"
rc4=0; STUB_DECISION=reconciled run_rt "$r4" >"$r4.out" 2>&1 || rc4=$?
check "4. reconcile-tests exits 0 for a top-level mission" "[ '$rc4' -eq 0 ]"
check "4. NO reconciliation worker was spawned for a top-level mission" \
  "[ ! -s '$r4.worker.log' ]"
check "4. the (parent-shaped) test is untouched for a top-level mission" \
  "grep -q 'bold 32px' '$(parent_test "$r4")'"
check "4. NO tests_reconciled / noop / deferred events for a top-level mission" \
  "! grep -Eq 'tests_reconcile' '$(events_of "$r4")' 2>/dev/null"

# === Case 5 (BUG-060): a RELATIVE/computed assertion the worker returns is applied
#     VERBATIM — the harness must NOT flatten the expression to a literal. ======
# The bug defines the new value as "⅓ of the digit height" (a relationship). The
# worker rewrites the parent assertion to a computed expression over the test's own
# mock value. The harness applies the worker's in-place edit as-is and relays the
# expression intact through the event + gh audit comment.
r5="$TMPROOT/r5"; mkdir -p "$r5"; new_bug_mission "$r5"; setup "$r5"
rc5=0; STUB_DECISION=reconciled_expr run_rt "$r5" >"$r5.out" 2>&1 || rc5=$?
check "5. reconcile-tests exits 0 on a relative reconciliation" "[ '$rc5' -eq 0 ]"
check "5. the old literal assertion is gone from the parent test" \
  "! grep -q 'bold 32px' '$(parent_test "$r5")'"
check "5. the parent test now holds the COMPUTED expression VERBATIM (not a literal)" \
  "grep -qF '(digitDisplayH / 3)' '$(parent_test "$r5")'"
check "5. the parent test did NOT get a guessed numeric literal substituted" \
  "! grep -Eq 'bold (12|5\.4)px' '$(parent_test "$r5")'"
check "5. a tests_reconciled event was emitted" \
  "grep -q '\"type\":\"tests_reconciled\"' '$(events_of "$r5")'"
check "5. the tests_reconciled event relays the relative expression intact" \
  "grep '\"type\":\"tests_reconciled\"' '$(events_of "$r5")' | grep -qF '(digitDisplayH / 3)'"
check "5. the gh audit comment relays the relative expression intact" \
  "grep -qF '(digitDisplayH / 3)' '$r5.gh.log'"

# === Case 6 (BUG-063): an OBSERVED-OUTPUT-anchored assertion is applied VERBATIM —
#     the durable answer for a relationship whose anchor the code SCALES/transforms.
# The bug defines the new value as "⅓ of the digit's DRAWN height". The worker rewrites
# the parent assertion to compute from the OBSERVED drawn height (read back from the
# recording context), NOT a static input sprite-size constant the code would scale. The
# harness must apply the in-place edit as-is and relay the observed expression intact
# through the event + gh audit comment — never flattening it to a literal nor swapping
# in a raw input constant.
r6="$TMPROOT/r6"; mkdir -p "$r6"; new_bug_mission "$r6"; setup "$r6"
rc6=0; STUB_DECISION=reconciled_observed run_rt "$r6" >"$r6.out" 2>&1 || rc6=$?
check "6. reconcile-tests exits 0 on an observed-output reconciliation" "[ '$rc6' -eq 0 ]"
check "6. the old literal assertion is gone from the parent test" \
  "! grep -q 'bold 32px' '$(parent_test "$r6")'"
check "6. the parent test now holds the OBSERVED-value expression VERBATIM" \
  "grep -qF '(observedDigitHeight / 3)' '$(parent_test "$r6")'"
check "6. the parent test did NOT get a guessed numeric literal substituted" \
  "! grep -Eq 'bold (12|5\.4)px' '$(parent_test "$r6")'"
check "6. the parent test did NOT fall back to a static input constant" \
  "! grep -q 'SPRITE_SIZES' '$(parent_test "$r6")'"
check "6. a tests_reconciled event was emitted" \
  "grep -q '\"type\":\"tests_reconciled\"' '$(events_of "$r6")'"
check "6. the tests_reconciled event relays the observed-value expression intact" \
  "grep '\"type\":\"tests_reconciled\"' '$(events_of "$r6")' | grep -qF '(observedDigitHeight / 3)'"
check "6. the gh audit comment relays the observed-value expression intact" \
  "grep -qF '(observedDigitHeight / 3)' '$r6.gh.log'"

echo
echo "  ---- $pass passed, $fail failed ----"
[ "$fail" -eq 0 ]
