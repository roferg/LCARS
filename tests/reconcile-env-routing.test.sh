#!/usr/bin/env bash
#
# S97 — reconcile retest ENV parity + env-failure routing (skill source:
# skills/lcars-run/run.sh: reconcile_gate + the new reconcile_retest_env_blocked /
# reconcile_retest_env_escalate helpers, plus provision_worktree reuse in the
# reconcile merge worktree).
#
# THE DEMO BUG: `lcars approve` → reconcile cut its merge worktree WITHOUT
# provisioning (no node_modules / no worktreeSetupCommand), so every ticket suite
# errored at startup (`cd: packages/editor: No such file or directory`,
# `vitest: not found`). The reconcile read that ALL-SUITES-RED as a LOGICAL
# conflict and auto-authored a `reconcile-bug-*.md` PRD + filed a phantom self-heal
# bug — chasing a ghost of its own broken ENVIRONMENT. The merge was CLEAN; only
# the retest environment was broken.
#
# TWO FIXES under test:
#   FIX 1 — ENV PARITY: the reconcile merge worktree is provisioned (provision_worktree,
#           the SAME primitive the Implement gates use) BEFORE the retest runs.
#   FIX 2 — ENV-FAILURE ROUTING: when the retest goes RED because the runner could
#           not START (env-failure / runner-startup), the reconcile STOPS at an
#           actionable env-blocked awaiting-human gate — it NEVER self-heals and
#           NEVER files a phantom reconcile-bug PRD. Only a GENUINE red (real
#           assertion failures on a provisioned run) may enter self-heal.
#
# Everything is stubbed — NO real network, gh, worker, or tokens. Only real `git`
# (local repos) is used to build the ahead condition deterministically.
#
# Usage: bash tests/reconcile-env-routing.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260701-097"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }
mdir_of()  { echo "$1/.git/lcars/missions/$MID"; }
aux_of()   { echo "$1.aux"; }

# --- stubs -----------------------------------------------------------------
make_notify_stub() { cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "NOTIFY $1 $2 $3" >>"$NOTIFY_LOG"
exit 0
EOF
chmod +x "$1"; }

make_gh_stub() { cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/99"
fi
exit 0
EOF
chmod +x "$1"; }

# log.sh stub: records each invocation. Its mere presence in the log proves the
# phantom self-heal PRD path was reached — which the env-blocked route MUST avoid.
make_log_stub() { cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "LOG $* | WB=${LCARS_WORKER_BIN:-}" >>"$LOG_LOG"
exit 0
EOF
chmod +x "$1"; }

make_resolve_stub() { cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "RESOLVE $*" >>"$RESOLVE_LOG"
exit 0
EOF
chmod +x "$1"; }

# worker stub: the cold bug-PRD author. If the reconcile ever reaches self-heal it
# writes a bug PRD into the scratch outdir (which reconcile_author_and_dispatch then
# copies to $MISSION_DIR/reconcile-bug-*.md). In the env-blocked case it must NEVER
# be invoked — so we also record every invocation.
make_worker_stub() { cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "WORKER $LCARS_WORKER_ROLE" >>"$WORKER_LOG" 2>/dev/null || echo "WORKER" >>"$WORKER_LOG"
out=""
for a in "$@"; do [ -d "$a" ] && out="$a"; done
[ -n "$out" ] || out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || exit 0
printf '# Mission: reconcile break when main merged in\n' >"$out/bug-001.md"
{
  printf '**Type:** bug\n'
  printf '**Conflict/failure summary:** suite t-001 went red after merging main.\n'
  printf '**Affected files / tests:** src/foo.js\n'
  printf '**Root cause:** main renamed a symbol.\n'
  printf '**Intended fix:** rename the call site.\n'
} >>"$out/bug-001.md"
exit 0
EOF
chmod +x "$1"; }

# Build a mission parked at verify with a real branch ahead of base + a ticket suite
# on disk. $1 = repo dir. Echoes the base branch name.
new_repo_verify() { # repo
  local repo="$1"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'orig\n' >shared.txt && git add -A && git commit -q -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'feature\n' >feature.txt && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
  git init -q --bare "$repo.remote.git"
  ( cd "$repo" && git remote add origin "$repo.remote.git" \
      && git push -q origin "$base" "lcars/$MID" )
  local m; m="$(mdir_of "$repo")"; mkdir -p "$m/tickets/t-001/tests"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Goal:** Let users switch to a dark colour scheme.
EOF
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "created": "2026-07-01T10:00:00Z",
  "githubIssue": 42,
  "workerBin": "$(aux_of "$repo")/worker",
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  cat >"$m/approved-plan.json" <<'EOF'
[ { "id": "t-001", "title": "Add the dark token set" } ]
EOF
  # canonical MULTI-LINE waves.json shape (parse_waves_table reads "wave"/"id" as
  # separate lines, exactly as Schedule emits them — a single-line array yields an
  # EMPTY ordered set, which would SKIP the retest and read as a false green).
  cat >"$m/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      { "id": "t-001", "issue": 101 }
    ]
  }
]
EOF
  cat >"$m/tickets/t-001/result.json" <<'EOF'
{ "passed": true, "attempts": 1 }
EOF
  # testCommand runs each staged suite file; behaviour is controlled by t.sh content.
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "testCommand": "for f in \"$LCARS_TESTS_DIR\"/*.sh; do [ -f \"$f\" ] && bash \"$f\" || exit 1; done" }
EOF
  echo "$base"
}

# Stage ticket t-001's suite. $2 ∈ {green, env, assert}.
#   green  → exits 0
#   env    → prints the DEMO env-failure signatures, exits 1 (runner could not start)
#   assert → prints a REAL assertion failure, exits 1 (genuine logical red)
stage_ticket_suite() { # repo  green|env|assert
  local m; m="$(mdir_of "$1")"
  case "$2" in
    green)  cat >"$m/tickets/t-001/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    ;;
    env)    cat >"$m/tickets/t-001/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "cd: packages/editor: No such file or directory" >&2
echo "vitest: not found" >&2
exit 1
EOF
    ;;
    assert) cat >"$m/tickets/t-001/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
echo "FAIL src/theme.test.ts > applies dark by default"
echo "AssertionError: expected 3 to be 4"
echo "Tests: 1 failed, 2 passed"
exit 1
EOF
    ;;
  esac
  chmod +x "$m/tickets/t-001/tests/t.sh"
}

# Move base AHEAD by a clean commit so the mission branch is behind (merges cleanly).
advance_base() { # repo
  local repo="$1" base
  base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q "$base" \
      && printf 'newbase\n' >base-only.txt && git add -A && git commit -q -m "main moves ahead" \
      && git push -q origin "$base" 2>/dev/null || true )
}

run_in() { # repo  subcommand-and-args…
  local repo="$1"; shift
  local a; a="$(aux_of "$repo")"
  ( cd "$repo" \
      && LCARS_GH_BIN="$a/gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" \
         LCARS_LOG_SCRIPT="$a/log.sh" \
         LCARS_RESOLVE_LOGS_SCRIPT="$a/resolve-logs.sh" \
         LCARS_WORKER_BIN="$a/worker" LCARS_WORKER_CLI="claude" \
         LCARS_WORKER_ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh" \
         LCARS_WORKTREE_SETUP_CMD="${LCARS_WORKTREE_SETUP_CMD:-}" \
         LCARS_NOTIFY="$a/notify" NOTIFY_LOG="$a/notify.log" \
         GH_LOG="$a/gh.log" LOG_LOG="$a/log.log" RESOLVE_LOG="$a/resolve.log" \
         WORKER_LOG="$a/worker.log" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RUN_SH" "$@" )
}

setup_stubs() { # repo
  local repo="$1" a; a="$(aux_of "$repo")"; mkdir -p "$a"
  make_notify_stub "$a/notify"
  make_gh_stub "$a/gh"
  make_log_stub "$a/log.sh"
  make_resolve_stub "$a/resolve-logs.sh"
  make_worker_stub "$a/worker"
  : >"$a/gh.log"; : >"$a/notify.log"; : >"$a/log.log"; : >"$a/resolve.log"; : >"$a/worker.log"
}

# ==========================================================================
echo "S97 reconcile env-routing — pure verdict helper"

# The verdict helper is exposed via an inert test hook (mirrors classify-impl-failure-test):
#   reconcile-retest-env-blocked-test  → reads a captured retest log on stdin,
#   exits 0 (env-blocked: the runner could not start) or 1 (a genuine red).
verdict() { printf '%s' "$1" | ( cd "$REPO_ROOT" && bash "$RUN_SH" reconcile-retest-env-blocked-test ); }

# U1. the DEMO capture (all suites errored at startup) → env-blocked
DEMO="$(printf 'cd: packages/editor: No such file or directory\nvitest: not found\n')"
if verdict "$DEMO"; then ok "U1. demo unprovisioned capture → env-blocked (verdict 0)"; \
  else bad "U1. demo unprovisioned capture → env-blocked (verdict 0)"; fi

# U2. a real assertion red on a provisioned run → NOT env-blocked
ASSERT="$(printf 'FAIL src/theme.test.ts\nAssertionError: expected 3 to be 4\n1 failed\n')"
if verdict "$ASSERT"; then bad "U2. genuine assertion red → NOT env-blocked (verdict 1)"; \
  else ok "U2. genuine assertion red → NOT env-blocked (verdict 1)"; fi

# U3. a lone 'command not found' also reads as env-blocked
if verdict "$(printf 'sh: vitest: command not found\n')"; then \
  ok "U3. 'command not found' → env-blocked"; else bad "U3. 'command not found' → env-blocked"; fi

echo
echo "S97 reconcile env-routing — integration (real git, all CLIs stubbed)"

# --- Behaviour 1: unprovisioned retest (env-failure) → env-blocked STOP, NO phantom bug
r1="$(mktemp -d "$TMPROOT/r1.XXXX")"; base1="$(new_repo_verify "$r1")"; setup_stubs "$r1"
stage_ticket_suite "$r1" env
advance_base "$r1"
rc1=0; run_in "$r1" reconcile --mission "$MID" >"$r1.aux/out.txt" 2>&1 || rc1=$?
s1="$(state_of "$r1")"; m1="$(mdir_of "$r1")"
check "1. env-failure retest exits 20 (awaiting-human, not a heal signal)" "[ '$rc1' -eq 20 ]"
check "1. reconcileStatus=env-blocked" "grep -q '\"reconcileStatus\": *\"env-blocked\"' '$s1'"
check "1. awaitingHuman=true (board surfaces the gate)" "grep -q '\"awaitingHuman\": *true' '$s1'"
check "1. a pendingQuestion was recorded" "grep -q 'pendingQuestion' '$s1'"
check "1. pending.json written for the gate" "[ -f '$m1/pending.json' ]"
check "1. NO phantom reconcile-bug PRD authored" "! ls '$m1'/reconcile-bug-*.md >/dev/null 2>&1"
check "1. log.sh (Mission Log) was NEVER invoked" "! grep -q '^LOG' '$r1.aux/log.log'"
check "1. the self-heal AUTHOR worker was NEVER spawned" "! grep -q '^WORKER' '$r1.aux/worker.log'"
check "1. NO PR opened" "! grep -q 'pr create' '$r1.aux/gh.log'"
check "1. a distinct reconcile_env_blocked event was emitted" \
  "grep -q 'reconcile_env_blocked' '$m1/events.jsonl'"
check "1. the gate message names worktreeSetupCommand (actionable)" \
  "grep -qi 'worktreeSetupCommand' '$s1'"
check "1. the raw captured retest output is preserved in the pending question" \
  "grep -qi 'vitest: not found\|No such file or directory' '$m1/pending.json'"
undo1="$(cd "$r1" && git rev-list --count "lcars/$MID..$base1" 2>/dev/null)"
check "1. the merge was UNDONE (branch still behind base → a re-run re-tests)" \
  "[ '${undo1:-0}' -ge 1 ]"
check "1. live tree stays clean" "[ -z \"\$(cd '$r1' && git status --porcelain)\" ]"
check "1. no reconcile worktree leaks" "! (cd '$r1' && git worktree list | grep -q reconcile)"

# --- Behaviour 2: GENUINE red (real assertion) → self-heal STILL fires (regression) ---
r2="$(mktemp -d "$TMPROOT/r2.XXXX")"; new_repo_verify "$r2" >/dev/null; setup_stubs "$r2"
stage_ticket_suite "$r2" assert
advance_base "$r2"
rc2=0; run_in "$r2" reconcile --mission "$MID" >"$r2.aux/out.txt" 2>&1 || rc2=$?
s2="$(state_of "$r2")"; m2="$(mdir_of "$r2")"
check "2. genuine red signals reconciling (exit 10 = self-heal dispatched)" "[ '$rc2' -eq 10 ]"
check "2. the self-heal author worker WAS spawned" "grep -q '^WORKER' '$r2.aux/worker.log'"
check "2. log.sh (Mission Log) WAS invoked" "grep -q '^LOG' '$r2.aux/log.log'"
check "2. a reconcile-bug PRD WAS authored" "ls '$m2'/reconcile-bug-*.md >/dev/null 2>&1"
check "2. reconcileStatus is NOT env-blocked on a genuine red" \
  "! grep -q '\"reconcileStatus\": *\"env-blocked\"' '$s2'"
check "2. genuine red never opens a PR" "! grep -q 'pr create' '$r2.aux/gh.log'"

# --- Behaviour 3: clean merge + GREEN retest → proceeds (no false self-heal) ---
r3="$(mktemp -d "$TMPROOT/r3.XXXX")"; new_repo_verify "$r3" >/dev/null; setup_stubs "$r3"
stage_ticket_suite "$r3" green
advance_base "$r3"
rc3=0; run_in "$r3" reconcile --mission "$MID" >"$r3.aux/out.txt" 2>&1 || rc3=$?
s3="$(state_of "$r3")"; m3="$(mdir_of "$r3")"
check "3. clean+green exits 0 (proceed to open PR)" "[ '$rc3' -eq 0 ]"
check "3. green never self-heals (no log.sh)" "! grep -q '^LOG' '$r3.aux/log.log'"
check "3. green never files a phantom bug PRD" "! ls '$m3'/reconcile-bug-*.md >/dev/null 2>&1"
check "3. green is NOT env-blocked" "! grep -q '\"reconcileStatus\": *\"env-blocked\"' '$s3'"
# NB: grep via a here-string, NOT a pipe — under `set -o pipefail`, `grep -q` closes
# the pipe on its first match and `git log` then dies with SIGPIPE (141), which
# pipefail would propagate as a false FAIL even though the match succeeded.
check "3. green kept the merge on the branch" \
  "grep -q 'main moves ahead' <<<\"\$(cd '$r3' && git log --oneline lcars/$MID)\""

# --- Behaviour 4: provisioning parity — worktreeSetupCommand runs BEFORE the retest ---
# LCARS_WORKTREE_SETUP_CMD (provision_worktree's highest-precedence source) writes a
# marker + a nanosecond timestamp; the retest (green) also stamps a timestamp. Assert
# the marker exists (provision RAN in the reconcile path) AND provision preceded the
# retest (ordering), proving the merge worktree is provisioned before suites run.
r4="$(mktemp -d "$TMPROOT/r4.XXXX")"; base4="$(new_repo_verify "$r4")"; setup_stubs "$r4"
a4="$(aux_of "$r4")"
# green suite that records WHEN the retest ran (into the sibling aux dir, absolute path)
cat >"$(mdir_of "$r4")/tickets/t-001/tests/t.sh" <<EOF
#!/usr/bin/env bash
date +%s%N > "$a4/retest.ts"
exit 0
EOF
chmod +x "$(mdir_of "$r4")/tickets/t-001/tests/t.sh"
advance_base "$r4"
LCARS_WORKTREE_SETUP_CMD="touch '$a4/provisioned.marker'; date +%s%N > '$a4/provision.ts'" \
  run_in "$r4" reconcile --mission "$MID" >"$r4.aux/out.txt" 2>&1 || true
check "4. provision_worktree RAN in the reconcile path (marker present)" \
  "[ -f '$a4/provisioned.marker' ]"
check "4. provisioning happened BEFORE the retest (provision.ts <= retest.ts)" \
  "[ -f '$a4/provision.ts' ] && [ -f '$a4/retest.ts' ] && [ \"\$(cat '$a4/provision.ts')\" -le \"\$(cat '$a4/retest.ts')\" ]"

echo
printf 'reconcile-env-routing: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
