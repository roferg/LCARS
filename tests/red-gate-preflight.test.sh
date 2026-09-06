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
  # PRETTY-PRINTED, `{` alone on line 1 — the shape lcars-file/file.sh actually
  # writes. state_set_str/state_set_raw insert their field after NR==1, so a
  # ONE-LINE fixture turns every park into INVALID JSON; the suites never noticed
  # because they grep rather than parse (Part H5 now parses).
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "implement"
}
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

# === Part G: S182 — the HONEST WALL in front of a repo that cannot prove work ==
#
# Two facts LCARS knows BEFORE it hires anybody, and used to discover only after
# paying for it:
#
#   G1/G2  NO testCommand AT ALL. resolve_test_cmd returns empty, so
#          runner_preflight_env_failure bails ("no env failure detected") and the
#          whole preflight escalation was SKIPPED — execution fell through to
#          spawning workers, the proof gates then refused for want of a test
#          command, that refusal read as "the worker did bad work", and up to
#          MAX_WORKER_TRIES fresh workers were hired before the mission parked
#          talking about proof, not about the missing runner. Now it parks FIRST,
#          naming the real problem, having spawned nothing.
#   G4     NO COMMITS AT ALL. The flip-flop gate proves fail-on-parent, and an
#          unborn HEAD has no parent — that used to be a hard `die`. Now it is an
#          actionable park (and `lcars init` seeds the commit up front; see
#          tests/lcars-init.test.sh).
#
# G3 is the invariant that matters most: a repo that HAS a runner is untouched.
#
# ZERO WORKER SPEND: every case here is pinned with a PATH SHIM faking BOTH
# `claude` and `copilot` and counting invocations — NOT $LCARS_WORKER_BIN, which
# a persisted state.json workerBin can beat. If the wall ever regresses, these
# counters are what notices.

make_cli_shim_dir() { # calls-log → echoes a dir holding counting claude+copilot
  local d b
  d="$(mktemp -d "$TMPROOT/shim.XXXX")"
  for b in claude copilot; do
    cat > "$d/$b" <<SH
#!/usr/bin/env bash
echo "\$(basename "\$0") \$*" >> "$1"
exit 0
SH
    chmod +x "$d/$b"
  done
  echo "$d"
}

run_impl_shimmed() { # repo shim-dir [env pairs…] → sets RC + OUT
  local r="$1" sh="$2"; shift 2
  # SPEND FUSE. A shim dir that is empty/unset would put the REAL `claude` back
  # on PATH and bill this test suite. Refuse to run rather than find out.
  [ -n "$sh" ] && [ -x "$sh/claude" ] && [ -x "$sh/copilot" ] \
    || { bad "shim fuse: no counting claude/copilot at '${sh:-<empty>}' — REFUSING to run (would bill)"; RC=99; OUT=""; return 0; }
  OUT="$( cd "$r" && env PATH="$sh:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" "$@" \
          bash "$SCRIPT" implement-ticket --mission test-001 --ticket t-001 2>&1 )"
  RC=$?
}

mdir()  { echo "$1/.git/lcars/missions/test-001"; }
gsay()  { cat "$(mdir "$1")/pending.json" "$(mdir "$1")/state.json" 2>/dev/null; }

# --- G1. greenfield repo, no testCommand → park BEFORE any worker -----------
repo="$(new_impl_mission)"
CALLS="$TMPROOT/calls-g1"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM"
st="$(mdir "$repo")/state.json"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$st"; then
  ok "G1a. no testCommand → mission parked awaiting-human (rc 0, not a die)"
else
  bad "G1a. no-testCommand park (rc=$RC, out=$(printf '%s' "$OUT" | tail -4))"
fi
if [ ! -s "$CALLS" ]; then
  ok "G1b. ZERO worker invocations — the PATH-shimmed claude/copilot never ran"
else
  bad "G1b. a worker was hired despite there being no test command: $(cat "$CALLS")"
fi
if gsay "$repo" | grep -q 'testCommand'; then
  ok "G1c. the park names the real problem (no testCommand is configured)"
else
  bad "G1c. the park never says testCommand: $(gsay "$repo" | tr -d '\n' | head -c 300)"
fi
if { gsay "$repo"; printf '%s' "$OUT"; } | grep -qi 'inconclusive'; then
  bad "G1d. the park still talks about proof being inconclusive"
else
  ok "G1d. the park never says 'inconclusive' — it names the missing runner"
fi
if gsay "$repo" | grep -q 'NO TEST SYSTEMS FOUND'; then
  ok "G1e. greenfield stack (readiness 'unknown') → the readiness verdict is CITED"
else
  bad "G1e. greenfield verdict not cited: $(gsay "$repo" | tr -d '\n' | head -c 400)"
fi
if gsay "$repo" | grep -q 'lcars update'; then
  ok "G1f. and it says what to do next (establish a runner / lcars update)"
else
  bad "G1f. the park gives the captain no next step"
fi

# --- G2. NOT greenfield (readiness 'missing') → the plain no-runner wording --
# A repo with a detectable ecosystem but no testCommand is not greenfield: the
# bootstrap voice would be a lie ("no test systems found" on a repo that has one).
repo="$(new_impl_mission)"
printf '{ "name":"g2", "private":true, "scripts": { "test": "vitest run" } }\n' > "$repo/package.json"
CALLS="$TMPROOT/calls-g2"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM"
st="$(mdir "$repo")/state.json"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$st" && [ ! -s "$CALLS" ]; then
  ok "G2a. non-greenfield repo with no testCommand also parks with ZERO spend"
else
  bad "G2a. non-greenfield park (rc=$RC, calls=$(wc -l < "$CALLS"))"
fi
if gsay "$repo" | grep -q 'NO TEST SYSTEMS FOUND'; then
  bad "G2b. a repo WITH a test system was told it is greenfield"
else
  ok "G2b. plain no-runner wording — the greenfield verdict is NOT cited"
fi
if gsay "$repo" | grep -q 'testCommand' && gsay "$repo" | grep -q 'lcars update'; then
  ok "G2c. and it still names the missing testCommand + the way to set it"
else
  bad "G2c. plain wording lost the problem or the next step"
fi

# --- G3. THE INVARIANT: a repo that HAS a runner is untouched ---------------
repo="$(new_impl_mission)"
cat > "$repo/react.sh" <<'SH'
#!/usr/bin/env bash
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
echo "AssertionError: expected"
exit 1
SH
CALLS="$TMPROOT/calls-g3"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM" LCARS_TEST_CMD="bash $repo/react.sh" \
  LCARS_EMPTY_WORKER_TRIES=1 LCARS_WORKER_TRIES=1
if [ -s "$CALLS" ]; then
  ok "G3a. a configured testCommand still reaches the worker (no new wall)"
else
  bad "G3a. the S182 wall blocked a repo that HAS a runner (rc=$RC: $(printf '%s' "$OUT" | tail -4))"
fi
if gsay "$repo" | grep -q 'no test command is configured'; then
  bad "G3b. a repo with a runner was given the no-runner park message"
else
  ok "G3b. and it is never given the no-runner park message"
fi

# --- G4. unborn HEAD → an actionable park, not a hard die -------------------
repo="$(mktemp -d "$TMPROOT/unborn.XXXX")"
( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
mkdir -p "$repo/.git/lcars/missions/test-001/tickets/t-001"
cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{
  "id": "test-001",
  "type": "feature",
  "title": "t",
  "stage": "implement"
}
JSON
cat > "$repo/.git/lcars/missions/test-001/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-001", "title": "t", "description": "d",
                 "acceptanceCriteria": ["a"] } ] }
JSON
CALLS="$TMPROOT/calls-g4"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM" LCARS_TEST_CMD=true \
  LCARS_EMPTY_WORKER_TRIES=1 LCARS_WORKER_TRIES=1
st="$(mdir "$repo")/state.json"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$st"; then
  ok "G4a. a repo with NO commits parks awaiting-human instead of dying"
else
  bad "G4a. unborn HEAD did not park (rc=$RC, out=$(printf '%s' "$OUT" | tail -4))"
fi
if gsay "$repo" | grep -qi 'no commits'; then
  ok "G4b. and the park names the real problem (the repo has no commits)"
else
  bad "G4b. unborn-HEAD park does not name the missing commit: $(gsay "$repo" | tr -d '\n' | head -c 300)"
fi
if gsay "$repo" | grep -q 'git commit --allow-empty'; then
  ok "G4c. and it hands the captain the exact command that unblocks it"
else
  bad "G4c. unborn-HEAD park gives no next step"
fi
if [ ! -s "$CALLS" ]; then
  ok "G4d. ZERO worker invocations on the unborn-HEAD path"
else
  bad "G4d. a worker was hired against a repo with no parent commit"
fi

# === Part H: S182 fix round 1 — three defects the fresh tester found =========
#
# H1/H2  DEFECT 2. A `testCommand` of "   " passed the `[ -z … ]` emptiness
#        check, so the wall did not fire and the OLD burn reproduced exactly
#        (workers hired, no park). Blankness must be tested AFTER trimming — and
#        trimming must NOT change anything for a real command that merely
#        carries padding: that command still RUNS.
# H3     DEFECT 3. On a repo that HAS runners (an npm-workspaces monorepo whose
#        every package can run tests) the readiness verdict is STILL `unknown` —
#        lcars_test_readiness returns `unknown` whenever detect_test_cmd finds no
#        candidate, regardless of how much test infrastructure exists. So the
#        park may REPORT that verdict, but it must not CONCLUDE "greenfield" from
#        it and must not advise "add a test framework" to a repo with three.
# H4     DEFECT 1. `lcars run` drives the implement STAGE, and the stage hires a
#        Context-Pack worker BEFORE it ever reaches a ticket. The wall lived only
#        in the ticket entry point, so the stage still spent ONE paid hire while
#        the park told the captain "No worker was hired". The wall is hoisted
#        into the stage driver ahead of that hire, so the sentence is TRUE.
#
# Every case below runs behind the same counting PATH shim + SPEND FUSE as Part G.

run_stage_shimmed() { # repo shim-dir [env pairs…] → sets RC + OUT
  local r="$1" sh="$2"; shift 2
  [ -n "$sh" ] && [ -x "$sh/claude" ] && [ -x "$sh/copilot" ] \
    || { bad "shim fuse: no counting claude/copilot at '${sh:-<empty>}' — REFUSING to run (would bill)"; RC=99; OUT=""; return 0; }
  OUT="$( cd "$r" && env PATH="$sh:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" "$@" \
          bash "$SCRIPT" implement --mission test-001 2>&1 )"
  RC=$?
}

# --- H1. a WHITESPACE-ONLY testCommand is blank — the wall must still fire ---
repo="$(new_impl_mission)"
printf '{\n  "testCommand": "   "\n}\n' > "$repo/.git/lcars/config.json"
CALLS="$TMPROOT/calls-h1"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM"
st="$(mdir "$repo")/state.json"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$st" && [ ! -s "$CALLS" ]; then
  ok "H1a. a whitespace-only testCommand parks with ZERO spend (not a slipped wall)"
else
  bad "H1a. whitespace testCommand slipped the wall (rc=$RC, hires=$(wc -l < "$CALLS" | tr -d ' '))"
fi
# tabs + newlines are whitespace too — the trim must not be space-only.
repo="$(new_impl_mission)"
printf '{\n  "testCommand": " \t "\n}\n' > "$repo/.git/lcars/config.json"
CALLS="$TMPROOT/calls-h1b"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM"
if [ "$RC" -eq 0 ] && [ ! -s "$CALLS" ] && grep -q '"awaitingHuman": *true' "$(mdir "$repo")/state.json"; then
  ok "H1b. a TAB-only testCommand is blank too"
else
  bad "H1b. tab-only testCommand slipped the wall (rc=$RC, hires=$(wc -l < "$CALLS" | tr -d ' '))"
fi

# --- H2. INVARIANT: a REAL command with padding still RUNS -------------------
repo="$(new_impl_mission)"
cat > "$repo/react.sh" <<'SH'
#!/usr/bin/env bash
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
echo "AssertionError: expected"
exit 1
SH
CALLS="$TMPROOT/calls-h2"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM" LCARS_TEST_CMD="  bash $repo/react.sh  " \
  LCARS_EMPTY_WORKER_TRIES=1 LCARS_WORKER_TRIES=1
if [ -s "$CALLS" ]; then
  ok "H2a. a padded but REAL test command still reaches the worker (trim ≠ park)"
else
  bad "H2a. padding around a real command wrongly parked it (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi
if gsay "$repo" | grep -q 'no test command is configured'; then
  bad "H2b. a padded real command was given the no-runner park message"
else
  ok "H2b. and it is never given the no-runner park message"
fi

# --- H3. a repo that HAS runners must not be told to "add a test framework" --
# npm workspaces: three packages, each with a working `test` script. The ROOT
# has none, so detect_test_cmd finds no candidate and the readiness verdict is
# `unknown` — the very verdict that used to be read as "greenfield".
repo="$(new_impl_mission)"
printf '{ "name":"mono", "private":true, "workspaces": ["packages/*"] }\n' > "$repo/package.json"
for p in a b c; do
  mkdir -p "$repo/packages/$p"
  printf '{ "name":"%s", "scripts": { "test": "vitest run" } }\n' "$p" > "$repo/packages/$p/package.json"
done
CALLS="$TMPROOT/calls-h3"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_impl_shimmed "$repo" "$SHIM"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$(mdir "$repo")/state.json" && [ ! -s "$CALLS" ]; then
  ok "H3a. monorepo with no root testCommand parks with ZERO spend"
else
  bad "H3a. monorepo park (rc=$RC, hires=$(wc -l < "$CALLS" | tr -d ' '))"
fi
if gsay "$repo" | grep -qi 'add a test framework'; then
  bad "H3b. a repo with three working runners was told to add a test framework"
else
  ok "H3b. never advises 'add a test framework' — the signal cannot support it"
fi
if gsay "$repo" | grep -qi 'This reads as a greenfield repo'; then
  bad "H3c. the park still CONCLUDES greenfield from a verdict that cannot prove it"
else
  ok "H3c. the park does not conclude greenfield in LCARS's own voice"
fi
# S183 UPDATED THIS LEG ON PURPOSE. S182 locked the CITATION here, and the
# verdict it happened to cite on this repo was "◇ NO TEST SYSTEMS FOUND — a
# greenfield repo" — the lie S183 was commissioned to cure. The citation
# contract is unchanged and still asserted; what the verdict SAYS about a
# monorepo with three working runners is now the truth (the foundation axis
# reads it as `unconfigured`), so the assertion tracks the truth, not the string.
if gsay "$repo" | grep -q 'test-readiness verdict' \
   && gsay "$repo" | grep -q 'TEST SYSTEMS OFFLINE'; then
  ok "H3d. the readiness verdict is still CITED, attributed as a verdict (S183 keeps it)"
else
  bad "H3d. the readiness verdict citation was lost: $(gsay "$repo" | tr -d '\n' | head -c 400)"
fi
if gsay "$repo" | grep -qi 'greenfield'; then
  bad "H3d2. the monorepo is STILL being called greenfield in the park message"
else
  ok "H3d2. the monorepo is never called greenfield (S183 — the oracle's cure)"
fi
if gsay "$repo" | grep -qi 'point LCARS at' && gsay "$repo" | grep -qi 'establish a test runner'; then
  ok "H3e. and BOTH next steps are offered (establish one, or point LCARS at one it has)"
else
  bad "H3f. only one next step offered: $(gsay "$repo" | tr -d '\n' | head -c 400)"
fi

# --- H4. THE STAGE spends ZERO — "No worker was hired" must be TRUE ----------
# `lcars run` invokes the implement STAGE, which resolves the durable context
# source (hiring a Context-Pack worker) before it reaches any ticket. Measured
# A/B before this cure: main 3 paid hires, this branch 1 — not 0.
repo="$(new_impl_mission)"
CALLS="$TMPROOT/calls-h4"; : > "$CALLS"
SHIM="$(make_cli_shim_dir "$CALLS")"
run_stage_shimmed "$repo" "$SHIM"
st="$(mdir "$repo")/state.json"
if [ "$RC" -eq 0 ] && grep -q '"awaitingHuman": *true' "$st"; then
  ok "H4a. the implement STAGE parks awaiting-human on a repo with no runner"
else
  bad "H4a. stage-level park (rc=$RC, out=$(printf '%s' "$OUT" | tail -4))"
fi
if [ ! -s "$CALLS" ]; then
  ok "H4b. ZERO worker hires at the STAGE level — not even the context-pack worker"
else
  bad "H4b. the stage hired $(wc -l < "$CALLS" | tr -d ' ') worker(s) before the wall: $(head -1 "$CALLS" | head -c 80)"
fi
if gsay "$repo" | grep -q 'No worker was hired'; then
  ok "H4c. and the park's 'No worker was hired' sentence is now TRUE stage-wide"
else
  bad "H4c. the park no longer states the (now true) zero-hire fact"
fi
if [ ! -f "$repo/.git/lcars/context-pack.md" ]; then
  ok "H4d. no context pack was generated — the wall is genuinely ahead of the spend"
else
  bad "H4d. a context pack was generated before the wall fired"
fi

# --- H5. state.json stays PARSEABLE JSON after a park -----------------------
# The fixture used to write a ONE-LINE state.json while state_set_raw inserts
# after NR==1, so every park produced invalid JSON and no suite noticed (they
# grep, they do not parse).
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$st" >/dev/null 2>&1; then
    ok "H5. state.json is still valid JSON after a park (fixture shape fixed)"
  else
    bad "H5. the park left state.json unparseable: $(tr -d '\n' < "$st" | head -c 200)"
  fi
fi

echo
printf 'red-gate-preflight: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
