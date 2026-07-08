#!/usr/bin/env bash
# Fast, SCOPED test for the S111 test-setup robustness round (Phase 1a/1b):
#
#   1a. RED-GATE TRIAGE — a runner that cannot LAUNCH must never be misread as
#       "testCommand IGNORES $LCARS_TESTS_DIR" (the S110 example-game 127 case:
#       `sh: vitest: command not found` is IDENTICAL with or without tests, so
#       the ignored-var verdict fired first and the Test-Writer was retried for
#       something no retry can fix). Env failures now triage FIRST and return a
#       DISTINCT rc 3 ("cannot run tests here" — escalate, don't retry); the
#       ignored-var signal now carries the runner output tail.
#   1a′. PREFLIGHT — implement-ticket probes the runner BEFORE spawning any
#       Test Writer; a dead runner parks the mission awaiting-human with the
#       package named and spawns NOTHING.
#   1b. make_ticket_worktree must NEVER silently fall back to the in-tree
#       (clone-root) build when the mission branch exists: it self-heals a stale
#       registration via `git worktree prune` + retry, and a still-failing add is
#       LOUD (non-zero + stderr), never an empty-string fallback.
#
# Zero tokens: fake testCommands + a recording stub worker. Mirrors the
# greenfield-stubs.test.sh fixture pattern. Safe to run directly.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# === Part A: env-failure signature covers npx's no-binary phrasing ==========
LIB="$(mktemp "$TMPROOT/lib.XXXX")"
sed -n '/^rg_signature() {/,/^}/p' "$SCRIPT" >"$LIB"
sed -n '/^red_gate_env_failure() {/,/^}/p' "$SCRIPT" >>"$LIB"
# shellcheck source=/dev/null
. "$LIB"

if red_gate_env_failure 'npm error could not determine executable to run'; then
  ok "A1. npx 'npm error could not determine executable to run' → env failure"
else
  bad "A1. npx no-binary phrasing (npm error) not detected as env failure"
fi
if red_gate_env_failure 'npm ERR! could not determine executable to run'; then
  ok "A2. legacy 'npm ERR!' no-binary phrasing → env failure"
else
  bad "A2. npx no-binary phrasing (npm ERR!) not detected as env failure"
fi
# An assertion QUOTING the phrase mid-line must NOT match (anchored arm).
if red_gate_env_failure "AssertionError: expected 'npm error could not determine executable to run' to be ok"; then
  bad "A3. quoted npx phrase inside an assertion falsely matched env failure"
else
  ok "A3. quoted npx phrase inside an assertion does not match"
fi

# === shared fixture helpers (greenfield-stubs pattern) =======================
new_mission() { # -> echoes repo dir; mission test-001 parked at implement
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions/test-001/tickets/t-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "implement" }
JSON
  echo "$repo"
}

write_test() { # tests-dir
  mkdir -p "$1"
  cat > "$1/t-001.test.ts" <<'TS'
import { area } from '../src/canvas/utils';
test('area multiplies', () => {
  expect(area(2, 3)).toBe(6);
});
TS
}

run_save() { # repo tests fake-cmd -> sets RC + OUT
  local repo="$1" tests="$2" cmd="$3"
  OUT="$( cd "$repo" && LCARS_TEST_CMD="$cmd" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            bash "$SCRIPT" impl-save-tests --mission test-001 --ticket t-001 \
            --tests "$tests" 2>&1 )"
  RC=$?
}

# === Part B: red_gate_ok verdict routing =====================================

# B1. TOTAL launch failure — identical output with or without tests (the S110
# example-game shape). Must be rc 3 + "cannot run" wording, NOT the misleading
# ignored-var blame, and the runner's own line must be quoted in the output.
repo="$(new_mission)"; tdir="$repo/_t"; write_test "$tdir"
cat > "$repo/dead.sh" <<'SH'
#!/usr/bin/env bash
echo "sh: vitest: command not found"
exit 127
SH
run_save "$repo" "$tdir" "bash $repo/dead.sh"
if [ "$RC" -eq 3 ]; then
  ok "B1a. total launch failure → distinct rc 3 (escalate, not retry)"
else
  bad "B1a. total launch failure rc (expected 3, got $RC: $(printf '%s' "$OUT" | tail -3))"
fi
if printf '%s' "$OUT" | grep -q 'IGNORES \$LCARS_TESTS_DIR'; then
  bad "B1b. total launch failure still misblamed as ignored-var"
else
  ok "B1b. no misleading ignored-var blame on a dead runner"
fi
if printf '%s' "$OUT" | grep -q "vitest: command not found"; then
  ok "B1c. the runner's own error line is quoted in the verdict"
else
  bad "B1c. runner output missing from the verdict"
fi
sig="$repo/.git/lcars/missions/test-001/tickets/t-001/red-gate-signal.txt"
if [ -f "$sig" ] && grep -q "cannot run" "$sig"; then
  ok "B1d. signal file persists with the cannot-run marker"
else
  bad "B1d. signal file missing or lacks cannot-run marker"
fi

# B2. Env failure where the probe DIFFERS (runner ok on empty dir, dead with
# tests) — still env, still rc 3, keeps the provisioning wording.
repo="$(new_mission)"; tdir="$repo/_t"; write_test "$tdir"
cat > "$repo/halfdead.sh" <<'SH'
#!/usr/bin/env bash
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
echo "vitest: command not found"
exit 1
SH
run_save "$repo" "$tdir" "bash $repo/halfdead.sh"
if [ "$RC" -eq 3 ] && printf '%s' "$OUT" | grep -q "environment not provisioned"; then
  ok "B2. differing-probe env failure → rc 3, provisioning wording kept"
else
  bad "B2. differing-probe env failure (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi

# B3. Ignored-var on a LIVE runner (non-env, identical fixed red) — still the
# retryable rc 1 verdict, and the signal NOW carries the runner output tail.
repo="$(new_mission)"; tdir="$repo/_t"; write_test "$tdir"
cat > "$repo/fixed.sh" <<'SH'
#!/usr/bin/env bash
echo "FAIL src/app.test.ts > renders — 2 failed"
exit 1
SH
run_save "$repo" "$tdir" "bash $repo/fixed.sh"
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'IGNORES \$LCARS_TESTS_DIR'; then
  ok "B3a. live-runner fixed-target red → still the ignored-var rc 1 verdict"
else
  bad "B3a. ignored-var verdict changed (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi
if printf '%s' "$OUT" | grep -q "2 failed"; then
  ok "B3b. ignored-var verdict now quotes the runner output tail"
else
  bad "B3b. ignored-var verdict lacks the runner output tail"
fi

# B4. Regression: a genuine reactive assertion red is still ACCEPTED.
repo="$(new_mission)"; tdir="$repo/_t"; write_test "$tdir"
cat > "$repo/react.sh" <<'SH'
#!/usr/bin/env bash
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
echo "AssertionError: expected 5 to be defined, got undefined"
exit 1
SH
run_save "$repo" "$tdir" "bash $repo/react.sh"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "tests saved"; then
  ok "B4. genuine assertion red still accepted"
else
  bad "B4. genuine red regressed (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi

# === Part C: implement-ticket PREFLIGHT — dead runner spawns NO worker =======
new_impl_mission() { # -> echoes repo dir; adds approved-plan.json
  local repo; repo="$(new_mission)"
  cat > "$repo/.git/lcars/missions/test-001/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-001", "title": "t", "description": "d",
                 "acceptanceCriteria": ["a"] } ] }
JSON
  echo "$repo"
}

make_stub_worker() { # calls-log -> echoes stub path
  local stub="$TMPROOT/stub-worker.sh"
  cat > "$stub" <<SH
#!/usr/bin/env bash
echo called >> "$1"
exit 0
SH
  chmod +x "$stub"
  echo "$stub"
}

# C1. Dead runner → awaiting-human BEFORE any worker spawn.
repo="$(new_impl_mission)"
cat > "$repo/dead.sh" <<'SH'
#!/usr/bin/env bash
echo "sh: vitest: command not found"
exit 127
SH
CALLS="$TMPROOT/calls-c1"; : > "$CALLS"
STUB="$(make_stub_worker "$CALLS")"
OUT="$( cd "$repo" && LCARS_TEST_CMD="bash $repo/dead.sh" \
          LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          LCARS_WORKER_BIN="$STUB" LCARS_WORKER_CLI=claude \
          bash "$SCRIPT" implement-ticket --mission test-001 --ticket t-001 2>&1 )"
RC=$?
state="$repo/.git/lcars/missions/test-001/state.json"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$state"; then
  ok "C1a. dead runner → mission parked awaiting-human (rc 0)"
else
  bad "C1a. dead runner park (rc=$RC, state=$(cat "$state" 2>/dev/null | tr -d '\n' | head -c 200))"
fi
if grep -q '"pendingQuestion"' "$state" \
   && grep -qi "runner" "$state"; then
  ok "C1b. pending question names the test-runner problem"
else
  bad "C1b. pending question missing or does not name the runner"
fi
if [ ! -s "$CALLS" ]; then
  ok "C1c. NO worker was spawned (preflight fired before Phase 1)"
else
  bad "C1c. a worker was spawned despite the dead runner ($(wc -l < "$CALLS") call(s))"
fi

# C2. Healthy (reactive) runner → preflight passes, Phase 1 DOES spawn.
repo="$(new_impl_mission)"
cat > "$repo/react.sh" <<'SH'
#!/usr/bin/env bash
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
echo "AssertionError: expected"
exit 1
SH
CALLS="$TMPROOT/calls-c2"; : > "$CALLS"
STUB="$(make_stub_worker "$CALLS")"
OUT="$( cd "$repo" && LCARS_TEST_CMD="bash $repo/react.sh" \
          LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          LCARS_WORKER_BIN="$STUB" LCARS_WORKER_CLI=claude \
          LCARS_EMPTY_WORKER_TRIES=1 LCARS_WORKER_TRIES=1 \
          bash "$SCRIPT" implement-ticket --mission test-001 --ticket t-001 2>&1 )"
RC=$?
if [ -s "$CALLS" ]; then
  ok "C2. healthy runner → preflight passes and Phase 1 spawns the worker"
else
  bad "C2. healthy runner blocked by preflight (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi

# === Part D: make_ticket_worktree — self-heal + loud failure =================
new_wt_mission() { # -> echoes repo dir with a real mission branch
  local repo; repo="$(new_mission)"
  ( cd "$repo" && git branch lcars/test-001 )
  # state.json with the branch recorded
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "implement",
  "branch": "lcars/test-001" }
JSON
  echo "$repo"
}

# D1. Stale registration self-heals: pre-register a worktree at the exact target
# path, delete its dir (the S110 manual-reset shape), then cut again.
repo="$(new_wt_mission)"
wtbase="$repo/.git/lcars/missions/test-001/wt-test"
( cd "$repo" && git worktree add -q --detach "$wtbase/all" lcars/test-001 )
rm -rf "$wtbase/all"     # stale registration left behind — no prune
OUT="$( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" provision-worktree-test --mission test-001 2>&1 )"
RC=$?
WT="$(printf '%s' "$OUT" | sed -n 's/^WT=//p')"
if [ "$RC" -eq 0 ] && [ -n "$WT" ] && [ -d "$WT" ]; then
  ok "D1. stale worktree registration self-heals (prune + retry → real worktree)"
else
  bad "D1. stale registration not healed (rc=$RC, WT='$WT': $(printf '%s' "$OUT" | tail -2))"
fi

# D2. Unrecoverable add failure is LOUD: base path occupied by a FILE.
repo="$(new_wt_mission)"
rm -rf "$repo/.git/lcars/missions/test-001/wt-test"
touch "$repo/.git/lcars/missions/test-001/wt-test"   # file blocks mkdir -p
OUT="$( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" provision-worktree-test --mission test-001 2>&1 )"
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "D2a. unrecoverable worktree-add failure exits non-zero (no silent fallback)"
else
  bad "D2a. worktree-add failure fell back silently (rc=0: $(printf '%s' "$OUT" | tail -2))"
fi
if printf '%s' "$OUT" | grep -qi "worktree"; then
  ok "D2b. the failure names the worktree cut"
else
  bad "D2b. failure message does not mention the worktree"
fi

# D3. Branch-less mission still falls back quietly (legit in-tree path).
repo="$(new_mission)"   # state.json has NO branch
OUT="$( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" provision-worktree-test --mission test-001 2>&1 )"
RC=$?
WT="$(printf '%s' "$OUT" | sed -n 's/^WT=//p')"
if [ "$RC" -eq 0 ] && [ -z "$WT" ]; then
  ok "D3. branch-less mission keeps the quiet empty fallback"
else
  bad "D3. branch-less fallback changed (rc=$RC, WT='$WT')"
fi

# === Part E: stray_edit_note — the post-commit gate names the wrong tree =====
# Extract the pure helper and drive it against a fixture: a clone whose MAIN
# working tree carries uncommitted edits while the gate evaluates from a mission
# worktree (the S110 002 shape). It must NAME the main checkout + the dirty
# paths; a clean main tree (or a non-isolated run) yields nothing.
LIB2="$(mktemp "$TMPROOT/lib2.XXXX")"
sed -n '/^stray_edit_note() {/,/^}/p' "$SCRIPT" >"$LIB2"
# shellcheck source=/dev/null
. "$LIB2"
if ! type stray_edit_note >/dev/null 2>&1; then
  bad "E0. stray_edit_note not extractable from run.sh"
else
  GIT_BIN=git
  repo="$(new_wt_mission)"
  ( cd "$repo" && printf 'tracked\n' > f.txt && git add f.txt && git commit -qm add )
  ( cd "$repo" && git worktree add -q --detach "$TMPROOT/wt-e" lcars/test-001 )
  # E1. main tree dirty → note names the main checkout and the dirty path.
  printf 'stray implementer edit\n' >> "$repo/f.txt"
  NOTE="$(REPO_ROOT="$TMPROOT/wt-e" stray_edit_note)"
  if printf '%s' "$NOTE" | grep -q "WRONG-TREE" \
     && printf '%s' "$NOTE" | grep -q "f.txt"; then
    ok "E1. dirty main tree → wrong-tree note names checkout + paths"
  else
    bad "E1. wrong-tree note missing or unnamed (got: '$NOTE')"
  fi
  # E2. clean main tree → empty note.
  ( cd "$repo" && git checkout -q -- f.txt )
  NOTE="$(REPO_ROOT="$TMPROOT/wt-e" stray_edit_note)"
  if [ -z "$NOTE" ]; then
    ok "E2. clean main tree → no note"
  else
    bad "E2. clean main tree produced a note: '$NOTE'"
  fi
  # E3. non-isolated run (REPO_ROOT IS the main tree) → empty even when dirty.
  printf 'stray again\n' >> "$repo/f.txt"
  NOTE="$(REPO_ROOT="$repo" stray_edit_note)"
  if [ -z "$NOTE" ]; then
    ok "E3. non-isolated run → no note (main tree edits are the build itself)"
  else
    bad "E3. non-isolated run produced a note: '$NOTE'"
  fi
fi

echo
printf 'red-gate-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
