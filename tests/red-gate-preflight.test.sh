#!/usr/bin/env bash
# Fast, SCOPED test for the S111 ENV-TRUTH that survives the S133 path flip:
#
#   A.  the env-failure signature set (npx no-binary phrasings, anchored).
#   C.  PREFLIGHT — implement-ticket probes the runner BEFORE spawning any
#       worker; a dead runner parks the mission awaiting-human with the package
#       named and spawns NOTHING (unchanged under the unified TDD worker).
#   D.  make_ticket_worktree must NEVER silently fall back to the in-tree
#       (clone-root) build when the mission branch exists: it self-heals a stale
#       registration via `git worktree prune` + retry, and a still-failing add is
#       LOUD (non-zero + stderr), never an empty-string fallback.
#   E.  stray_edit_note — the post-commit gate names the wrong tree.
#
# (The old Part B — red_gate_ok's rc-3 triage inside impl-save-tests — is gone
# WITH impl-save-tests: fail-first is proven post-hoc by the flip-flop gate now.)
# Zero tokens: fake testCommands + a recording stub worker. Safe to run directly.
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

# === Part F: ROOT-TREE SOVEREIGNTY — replay never touches the main checkout ==
# Drive the REAL replay_ticket_commit via the replay-test hook: the commit must
# land on the mission branch via the ephemeral landing worktree while the main
# checkout's HEAD, working tree, and worktree list stay byte-identical.
mk_detached_commit() { # repo branch → echoes sha of a commit made on a detached wt
  local repo="$1" branch="$2" wt="$TMPROOT/detwt.$$"
  ( cd "$repo" && git worktree add -q --detach "$wt" "$branch" ) || return 1
  ( cd "$wt" && printf 'landed change\n' >> f.txt && git add f.txt \
      && git commit -qm "ticket change" && git rev-parse HEAD )
  local sha_rc=$?
  ( cd "$repo" && git worktree remove --force "$wt" >/dev/null 2>&1 ) || rm -rf "$wt"
  return $sha_rc
}

repo="$(new_wt_mission)"
( cd "$repo" && printf 'base\n' > f.txt && git add f.txt && git commit -qm base \
    && git branch -f lcars/test-001 HEAD )
SHA="$(mk_detached_commit "$repo" lcars/test-001)"
HEAD_BEFORE="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
STATUS_BEFORE="$(cd "$repo" && git status --porcelain)"
OUT="$( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" replay-test --mission test-001 --ticket t-001 "$SHA" 2>&1 )"
RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "REPLAY-OK"; then
  ok "F1a. replay lands the commit (REPLAY-OK)"
else
  bad "F1a. replay failed (rc=$RC: $OUT)"
fi
if ( cd "$repo" && git log --oneline lcars/test-001 | grep -q "ticket change" ); then
  ok "F1b. the commit is on the mission branch"
else
  bad "F1b. commit missing from the mission branch"
fi
HEAD_AFTER="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
STATUS_AFTER="$(cd "$repo" && git status --porcelain)"
if [ "$HEAD_BEFORE" = "$HEAD_AFTER" ] && [ "$STATUS_BEFORE" = "$STATUS_AFTER" ]; then
  ok "F1c. main checkout HEAD + working tree byte-identical (sovereignty)"
else
  bad "F1c. main checkout mutated (HEAD $HEAD_BEFORE→$HEAD_AFTER, status changed)"
fi
if ( cd "$repo" && git worktree list | grep -q "landing" ); then
  bad "F1d. landing worktree leaked into git worktree list"
else
  ok "F1d. no landing worktree left behind"
fi

# F2. The CAPTAIN holds the mission branch in the main checkout → replay fails
# LOUD naming the holder, and still never touches their checkout.
repo="$(new_wt_mission)"
( cd "$repo" && printf 'base\n' > f.txt && git add f.txt && git commit -qm base \
    && git branch -f lcars/test-001 HEAD )
SHA="$(mk_detached_commit "$repo" lcars/test-001)"
( cd "$repo" && git checkout -q lcars/test-001 )
OUT="$( cd "$repo" && LCARS_GH_BIN=true LCARS_GIT_BIN=git \
          bash "$SCRIPT" replay-test --mission test-001 --ticket t-001 "$SHA" 2>&1 )"
RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "checked out at"; then
  ok "F2a. captain-held branch → loud failure naming the holder"
else
  bad "F2a. captain-held branch handling (rc=$RC: $OUT)"
fi
if [ "$(cd "$repo" && git rev-parse --abbrev-ref HEAD)" = "lcars/test-001" ]; then
  ok "F2b. the captain's checkout was left exactly where they put it"
else
  bad "F2b. the captain's checkout was moved"
fi

echo
printf 'red-gate-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
