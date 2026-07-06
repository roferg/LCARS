#!/usr/bin/env bash
#
# Tests for S76 — main-ahead reconcile + self-heal (skill source:
# skills/lcars-run/run.sh `reconcile` + the drive_verify gate; bug-PRD authoring
# template skills/lcars-run/stages/reconcile-author.md; routed through
# skills/lcars-log/log.sh + skills/lcars-resolve-logs/resolve-logs.sh).
#
# Before Verify opens the PR, the harness checks whether the mission branch's base
# (main) has moved ahead. If so it MERGES main into the branch in an ISOLATED
# worktree, re-runs the mission's own ticket suites against the combined state, and:
#   • not ahead              → no reconcile, falls through to today's open-PR path
#   • ahead + clean + green  → branch updated, round cleared, proceed to open PR
#   • ahead + conflict/red   → author DETAILED bug PRD(s) from the failure, route
#                              them through log.sh → resolve-logs → complete, halt
#                              "reconciling"; next pass re-enters
#   • still red after K      → escalate awaiting-human with the diagnosis, no PR
#
# Everything is stubbed — NO real network, gh, worker, or tokens. Only real `git`
# (local repos) is used to build the ahead/conflict conditions deterministically.
#
# Usage: bash tests/lcars-reconcile.test.sh

set -uo pipefail
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260619-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }
mdir_of()  { echo "$1/.git/lcars/missions/$MID"; }
# Stubs + logs live in a SIBLING dir, never inside the repo working tree (an
# untracked stub there would dirty `git status --porcelain` and fail the
# clean-tree assertions).
aux_of()   { echo "$1.aux"; }

# --- stubs -----------------------------------------------------------------

# notify stub: records each ping.
make_notify_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "NOTIFY $1 $2 $3" >>"$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$1"
}

# gh stub: accepts everything, records calls. NEVER opens a real PR.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/99"
fi
exit 0
EOF
  chmod +x "$1"
}

# log.sh stub: records each invocation + its --prd args, and copies each PRD it
# was handed into a known dir so the test can assert on PRD content. Also records
# whether LCARS_WORKER_BIN (the engine, BUG-D) was threaded.
make_log_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "LOG $* | WB=${LCARS_WORKER_BIN:-}" >>"$LOG_LOG"
i=0
while [ $# -gt 0 ]; do
  case "$1" in
    --prd) i=$((i+1)); cp "$2" "$PRD_CAPTURE/prd-$i.md" 2>/dev/null || true; shift 2 ;;
    --prd=*) i=$((i+1)); cp "${1#--prd=}" "$PRD_CAPTURE/prd-$i.md" 2>/dev/null || true; shift ;;
    *) shift ;;
  esac
done
echo "$i" >"$PRD_CAPTURE/count"
exit 0
EOF
  chmod +x "$1"
}

# resolve-logs.sh stub: records drive + complete invocations.
# BUG-052: when $STUB_RESOLVE_FAIL is set, the DRIVE invocation exits NON-ZERO —
# standing in for a real heal child that errored (e.g. its implement hard-failed)
# and could NOT be driven to its Verify gate (the real resolve-logs `die`s with
# WAVE_ERRORED in that case). The `complete` invocation still records + exits 0
# (there is nothing at Verify to fold), exactly as the real script does.
make_resolve_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "RESOLVE $*" >>"$RESOLVE_LOG"
case " $* " in
  *" complete "*) exit 0 ;;
esac
[ -n "${STUB_RESOLVE_FAIL:-}" ] && exit 1
exit 0
EOF
  chmod +x "$1"
}

# A worker stub standing in for the cold bug-PRD author. It is invoked through the
# worker-adapter `spawn` path; the LAST argument is the scratch output dir is NOT
# how this stub finds it — the adapter passes the outdir, but to keep the stub
# CLI-agnostic we read $LCARS_WORK_OUT if set, else scan argv for an existing dir.
# It writes N bug PRDs (default 1, or $RECONCILE_BUGS) each in the required shape.
make_worker_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
# Capture the worker prompt (the arg right after `-p`) so tests can assert what
# reached the cold worker — e.g. that a resumed self-heal carries the captain's
# recorded answer (BUG-042). Append every prompt to $WORKER_PROMPT_LOG if set.
if [ -n "${WORKER_PROMPT_LOG:-}" ]; then
  prev=""
  for a in "$@"; do
    [ "$prev" = "-p" ] && { printf '%s\n----8<----\n' "$a" >>"$WORKER_PROMPT_LOG"; }
    prev="$a"
  done
fi
# BUG-053 probe: at the MOMENT the heal author runs, record whether the reconcile
# gate's attached worktree is still registered on the mission branch. The bug was
# that reconcile_cleanup ran AFTER this dispatch, so $BRANCH stayed checked out in
# the reconcile worktree and the heal's `git checkout $BRANCH` failed. After the
# fix the worktree is freed BEFORE dispatch, so this probe must see NO reconcile.*
# worktree. Records exactly one line ("present"/"absent") per dispatch.
if [ -n "${WORKER_WT_PROBE:-}" ] && [ -n "${WORKER_WT_PROBE_REPO:-}" ]; then
  if git -C "$WORKER_WT_PROBE_REPO" worktree list 2>/dev/null | grep -q 'reconcile\.'; then
    echo "present" >>"$WORKER_WT_PROBE"
  else
    echo "absent" >>"$WORKER_WT_PROBE"
  fi
fi
# BUG-056 in-worktree RESOLVE mode: the harness dispatched the reconcile-resolve
# worker to remove the conflict markers IN the merge worktree (not author a PRD).
# The prompt lists each conflicted file as an absolute path on a "- <path>" line.
# This stub edits those files in place: removing the markers (composing both sides)
# UNLESS STUB_RESOLVE_RED is set, in which case it removes the markers but writes
# content the green suite cannot accept (simulating a resolution that stays red).
if [ "${LCARS_WORKER_ROLE:-}" = "reconcile-resolve" ]; then
  # STUB_RESOLVE_NOOP: the worker "ran" but did NOT finish — leave the conflict
  # markers in place (simulates an incomplete resolution, a prime live suspect).
  if [ -n "${STUB_RESOLVE_NOOP:-}" ]; then exit 0; fi
  prompt=""; prev=""
  for a in "$@"; do [ "$prev" = "-p" ] && prompt="$a"; prev="$a"; done
  # Pull every "- <abs path>" line under the worktree from the prompt.
  printf '%s\n' "$prompt" | sed -n 's/^- \(\/.*\)$/\1/p' | while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -Eq '^(<<<<<<< |={7}$|>>>>>>> )' "$f" || continue
    if [ -n "${STUB_RESOLVE_RED:-}" ]; then
      printf 'still-broken\n' >"$f"   # markers gone but the green suite stays red
    else
      printf 'resolved\n' >"$f"       # markers gone, combined content
    fi
  done
  exit 0
fi
# Find the scratch output dir: it is one of the argv that is an existing directory
# created by the harness (mkdir -p outdir happens before spawn). Prefer the last.
out=""
for a in "$@"; do [ -d "$a" ] && out="$a"; done
[ -n "$out" ] || out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || exit 0
# BUG-042 path: the conflict is an unresolvable DESIGN trade-off, so the author
# emits an experience-framed QUESTION (design-question.txt) instead of bug PRDs.
if [ -n "${STUB_DESIGN_QUESTION:-}" ]; then
  printf '%s\n' "${STUB_DESIGN_QUESTION_TEXT:-The best-score readout and the xN multiplier badge both render in the top-right corner and overlap — how should they be arranged? (e.g. stack them, move best-score to the top-left, shrink one)}" >"$out/design-question.txt"
  exit 0
fi
# BUG-045 path: the HARNESS deterministically decided this conflict is unresolvable
# (a heal round could not reach green) and is RE-AUTHORING the question with a
# force-design-question instruction. The stub detects that instruction in the
# captured prompt and emits an experience-framed question.
if [ -n "${STUB_FORCED_DESIGN_QUESTION_TEXT:-}" ]; then
  forced=""
  prev=""
  for a in "$@"; do
    [ "$prev" = "-p" ] && case "$a" in *FORCE-DESIGN-QUESTION*) forced=1 ;; esac
    prev="$a"
  done
  if [ -n "$forced" ]; then
    printf '%s\n' "$STUB_FORCED_DESIGN_QUESTION_TEXT" >"$out/design-question.txt"
    exit 0
  fi
fi
n="${RECONCILE_BUGS:-1}"
i=1
while [ "$i" -le "$n" ]; do
  printf '# Mission: reconcile break %s when main merged in\n' "$i" >"$out/bug-00$i.md"
  {
    printf '**Type:** bug\n'
    printf '**Conflict/failure summary:** suite t-001 went red after merging main; assertion X failed.\n'
    printf '**Affected files / tests:** src/foo.js, tickets/t-001/tests/t.sh\n'
    printf '**Root cause:** main renamed fooBar to foo_bar; our call site still uses fooBar.\n'
    printf '**Intended fix:** rename the call site in src/foo.js to foo_bar, keeping our toggle behavior.\n'
  } >>"$out/bug-00$i.md"
  i=$((i+1))
done
exit 0
EOF
  chmod +x "$1"
}

# Build a mission parked at verify with a real branch ahead of base + a green
# ticket suite on disk. $1 = repo dir. Sets up an origin to push/fetch against.
new_repo_verify() { # repo  [base-content]
  local repo="$1"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'orig\n' >shared.txt && git add -A && git commit -q -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  # mission branch: adds a file + a commit ahead of base
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'feature\n' >feature.txt && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
  # bare origin so push/fetch resolve locally
  git init -q --bare "$repo.remote.git"
  ( cd "$repo" && git remote add origin "$repo.remote.git" \
      && git push -q origin "$base" "lcars/$MID" )
  local m; m="$(mdir_of "$repo")"; mkdir -p "$m/tickets/t-001/tests"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
EOF
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "created": "2026-06-19T10:00:00Z",
  "githubIssue": 42,
  "workerBin": "$(aux_of "$repo")/worker",
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  cat >"$m/approved-plan.json" <<'EOF'
[ { "id": "t-001", "title": "Add the dark token set" } ]
EOF
  # canonical multi-line waves.json shape (parse_waves_table reads "wave"/"id" as
  # separate lines, exactly as Schedule emits them).
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
  # a green result for the ticket
  cat >"$m/tickets/t-001/result.json" <<'EOF'
{ "passed": true, "attempts": 1 }
EOF
  # config with a test command that honours LCARS_TESTS_DIR and runs the staged suite
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "testCommand": "for f in \"$LCARS_TESTS_DIR\"/*.sh; do [ -f \"$f\" ] && bash \"$f\" || exit 1; done" }
EOF
  echo "$base"
}

# Stage ticket t-001's test suite. $2 controls whether the suite is "green" (exits
# 0 against the merged tree) or "red". For green we test for the merged base file.
stage_ticket_suite() { # repo  green|red
  local m; m="$(mdir_of "$1")"
  if [ "$2" = green ]; then
    cat >"$m/tickets/t-001/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  elif [ "$2" = needs-resolved ]; then
    # GREEN only if shared.txt was resolved to the marker-free "resolved" content.
    # The resolve stub writes "resolved" on success and "still-broken" under
    # STUB_RESOLVE_RED — so this suite passes iff the resolution is the good one.
    cat >"$m/tickets/t-001/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
grep -q '^resolved$' shared.txt
EOF
  else
    cat >"$m/tickets/t-001/tests/t.sh" <<'EOF'
#!/usr/bin/env bash
# fails against the merged state (silent logical conflict)
exit 1
EOF
  fi
  chmod +x "$m/tickets/t-001/tests/t.sh"
}

# Move base AHEAD: add a new commit to base on origin (and locally), so the mission
# branch is behind. $2 = "clean" (new file, merges cleanly) or "conflict" (touch
# the same line the branch touched → textual conflict on merge).
advance_base() { # repo  clean|conflict
  local repo="$1" base
  base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q "$base" )
  if [ "$2" = conflict ]; then
    # make the branch and base both edit shared.txt's only line → real conflict
    ( cd "$repo" && git checkout -q "lcars/$MID" \
        && printf 'branch-edit\n' >shared.txt && git add -A && git commit -q -m "branch edits shared" \
        && git checkout -q "$base" \
        && printf 'main-edit\n' >shared.txt && git add -A && git commit -q -m "main edits shared" )
  else
    ( cd "$repo" && printf 'newbase\n' >base-only.txt && git add -A && git commit -q -m "main moves ahead" )
  fi
  ( cd "$repo" && git push -q origin "$base" 2>/dev/null || true )
}

# BUG-077: make the LOCAL mission branch DIVERGE from the remote PR head. Mimics a
# reconcile that was killed/parked and retried: the local branch tip is left at a
# dead attempt's commit while origin/<branch> still holds the last-pushed head. We
# add a local-only commit (NOT pushed) so `local tip != origin/<branch>` and the
# remote is NOT an ancestor of local — a true divergence. The dead commit drops a
# marker file the test asserts disappears once the gate resets to the remote head.
diverge_local_branch() { # repo
  local repo="$1" base
  base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q "lcars/$MID" \
      && printf 'dead-attempt\n' >dead-attempt.txt \
      && git add -A && git commit -q -m "dead reconcile attempt (local-only, diverged)" \
      && git checkout -q "$base" )
}

# Drive a run.sh subcommand inside a repo with all stub bins injected (from the
# sibling aux dir, never inside the repo working tree).
run_in() { # repo  subcommand-and-args…
  local repo="$1"; shift
  local a; a="$(aux_of "$repo")"
  ( cd "$repo" \
      && PRD_CAPTURE="$a/prdcap" RECONCILE_BUGS="${RECONCILE_BUGS:-1}" \
         WORKER_PROMPT_LOG="$a/worker-prompt.log" \
         WORKER_WT_PROBE="$a/wt-probe.log" WORKER_WT_PROBE_REPO="$repo" \
         STUB_DESIGN_QUESTION="${STUB_DESIGN_QUESTION:-}" \
         STUB_DESIGN_QUESTION_TEXT="${STUB_DESIGN_QUESTION_TEXT:-}" \
         STUB_FORCED_DESIGN_QUESTION_TEXT="${STUB_FORCED_DESIGN_QUESTION_TEXT:-}" \
         STUB_RESOLVE_RED="${STUB_RESOLVE_RED:-}" \
         STUB_RESOLVE_NOOP="${STUB_RESOLVE_NOOP:-}" \
         STUB_RESOLVE_FAIL="${STUB_RESOLVE_FAIL:-}" \
         LCARS_GH_BIN="$a/gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" \
         LCARS_LOG_SCRIPT="$a/log.sh" \
         LCARS_RESOLVE_LOGS_SCRIPT="$a/resolve-logs.sh" \
         LCARS_WORKER_BIN="$a/worker" LCARS_WORKER_CLI="${MISSION_ENGINE:-claude}" \
         LCARS_WORKER_ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh" \
         LCARS_NOTIFY="$a/notify" NOTIFY_LOG="$a/notify.log" \
         GH_LOG="$a/gh.log" LOG_LOG="$a/log.log" RESOLVE_LOG="$a/resolve.log" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RUN_SH" "$@" )
}

setup_stubs() { # repo
  local repo="$1" a; a="$(aux_of "$repo")"; mkdir -p "$a/prdcap"
  make_notify_stub "$a/notify"
  make_gh_stub "$a/gh"
  make_log_stub "$a/log.sh"
  make_resolve_stub "$a/resolve-logs.sh"
  make_worker_stub "$a/worker"
  : >"$a/gh.log"; : >"$a/notify.log"; : >"$a/log.log"; : >"$a/resolve.log"
  : >"$a/worker-prompt.log"; : >"$a/wt-probe.log"
}

# ==========================================================================
echo "lcars reconcile (S76)"

[ -f "$RUN_SH" ] || { echo "run.sh not found at $RUN_SH"; exit 1; }

# --- Unit: json_escape makes multi-line / control-char text JSON-string-safe --
# Extract run.sh's own json_escape() (the canonical escaper that writes
# reconcileDiagnosis) and drive it directly, then assert the output wrapped as a
# JSON string PARSES and ROUND-TRIPS. Before the fix this escaped only \ and ",
# so a newline/tab produced an Invalid-control-character JSON parse error.
JE_LIB="$TMPROOT/json_escape.lib.sh"
sed -n '/^json_escape() {/,/^}/p' "$RUN_SH" >"$JE_LIB"
( set +u
  # shellcheck source=/dev/null
  . "$JE_LIB"
  in="$(printf 'l1\nl2\twith \"quote\" and \\back\rcr ctrl\x01end')"
  esc="$(json_escape "$in")"
  IN="$in" python3 - "$esc" <<'PY'
import json, os, sys
esc = sys.argv[1]
val = json.loads('"' + esc + '"')   # raises if not JSON-string-safe
assert val == os.environ["IN"], "round-trip mismatch: %r != %r" % (val, os.environ["IN"])
PY
) && ok "U. json_escape: multi-line+tab+quote+backslash+control char → valid JSON that round-trips" \
   || bad "U. json_escape: multi-line+tab+quote+backslash+control char → valid JSON that round-trips"

# --- Behaviour 1: base NOT ahead → no reconcile, proceeds to open-PR path -----
r1="$(mktemp -d "$TMPROOT/r1.XXXX")"; new_repo_verify "$r1" >/dev/null; setup_stubs "$r1"
stage_ticket_suite "$r1" green
rc1=0; run_in "$r1" reconcile --mission "$MID" >"$r1.aux/out.txt" 2>&1 || rc1=$?
s1="$(state_of "$r1")"
check "1. reconcile exits 0 when base is not ahead" "[ '$rc1' -eq 0 ]"
check "1. no reconcileRound set (never reconciled)" "! grep -q 'reconcileRound' '$s1'"
check "1. no Mission Log dispatched" "! grep -q LOG '$r1.aux/log.log'"
check "1. reports proceed/not-ahead" "grep -qi 'not ahead\|proceed\|up to date\|up-to-date' '$r1.aux/out.txt'"
check "1. live tree stays clean" "[ -z \"\$(cd '$r1' && git status --porcelain)\" ]"
check "1. no reconcile worktree leaks" "! (cd '$r1' && git worktree list | grep -q reconcile)"

# --- Behaviour 2: ahead + clean merge + green → branch updated, no log --------
r2="$(mktemp -d "$TMPROOT/r2.XXXX")"; base2="$(new_repo_verify "$r2")"; setup_stubs "$r2"
stage_ticket_suite "$r2" green
advance_base "$r2" clean
rc2=0; run_in "$r2" reconcile --mission "$MID" >"$r2.aux/out.txt" 2>&1 || rc2=$?
s2="$(state_of "$r2")"
check "2. reconcile exits 0 on clean+green" "[ '$rc2' -eq 0 ]"
check "2. mission branch now contains base's new commit (merge happened)" \
  "(cd '$r2' && git log --oneline lcars/$MID) | qgrep -q 'main moves ahead'"
check "2. reconcileRound cleared on green" "! grep -q '\"reconcileRound\"' '$s2'"
check "2. NO Mission Log dispatched on clean+green" "! grep -q LOG '$r2.aux/log.log'"
check "2. scoped re-test ran even on clean merge (output mentions re-test/green)" \
  "grep -qi 'green\|re-test\|reconcil' '$r2.aux/out.txt'"
check "2. live tree stays clean" "[ -z \"\$(cd '$r2' && git status --porcelain)\" ]"
check "2. no reconcile worktree leaks" "! (cd '$r2' && git worktree list | grep -q reconcile)"

# --- Behaviour 2r (BUG-067): ahead + clean + green + a PR ALREADY OPEN ---------
# When a PR is already open (the `lcars approve` merge-gate flow), a self-heal that
# converges green must NOT auto-merge. The gate STOPS, persists an awaiting-reapprove
# gate keyed off the reconciled tip, and returns 30 — the captain reapproves to merge.
r2r="$(mktemp -d "$TMPROOT/r2r.XXXX")"; new_repo_verify "$r2r" >/dev/null; setup_stubs "$r2r"
# plant a prUrl/prNumber → this is the post-PR (approve) reconcile context.
sed 's#\("base": "[^"]*"\)#\1,\n  "prUrl": "https://github.com/acme/repo/pull/77",\n  "prNumber": 77#' \
  "$(state_of "$r2r")" >"$r2r.s.tmp" && mv "$r2r.s.tmp" "$(state_of "$r2r")"
stage_ticket_suite "$r2r" green
advance_base "$r2r" clean
rc2r=0; run_in "$r2r" reconcile --mission "$MID" >"$r2r.aux/out.txt" 2>&1 || rc2r=$?
s2r="$(state_of "$r2r")"
check "2r. reconcile returns 30 (awaiting-reapprove) on green when a PR is open" "[ '$rc2r' -eq 30 ]"
check "2r. reconcileStatus=awaiting-reapprove" \
  "grep -q '\"reconcileStatus\": *\"awaiting-reapprove\"' '$s2r'"
check "2r. reconcileNote is human-readable (mentions reapprove + re-tested green)" \
  "grep -qi 'reapprove' '$s2r' && grep -qi 're-tested green' '$s2r'"
check "2r. reconcileMergeSha persisted (full sha)" \
  "grep -qE '\"reconcileMergeSha\": *\"[0-9a-f]{40}\"' '$s2r'"
check "2r. awaitingHuman=true (board surfaces the gate)" \
  "grep -q '\"awaitingHuman\": *true' '$s2r'"
check "2r. one awaiting-human notification fired" \
  "[ \"\$(grep -c 'awaiting-human' '$r2r.aux/notify.log')\" -ge 1 ]"
check "2r. did NOT auto-merge (no gh pr merge)" "! grep -q 'pr merge' '$r2r.aux/gh.log'"
check "2r. branch DID advance (merge kept on the branch)" \
  "(cd '$r2r' && git log --oneline lcars/$MID) | qgrep -q 'main moves ahead'"
check "2r. live tree stays clean" "[ -z \"\$(cd '$r2r' && git status --porcelain)\" ]"

# --- Behaviour 3a: ahead + RED re-test (logical) → DETAILED log dispatched ----
r3="$(mktemp -d "$TMPROOT/r3.XXXX")"; new_repo_verify "$r3" >/dev/null; setup_stubs "$r3"
stage_ticket_suite "$r3" red
advance_base "$r3" clean
rc3=0; run_in "$r3" reconcile --mission "$MID" >"$r3.aux/out.txt" 2>&1 || rc3=$?
s3="$(state_of "$r3")"
check "3a. reconcile signals 'reconciling' (exit 10 = halt this pass)" "[ '$rc3' -eq 10 ]"
check "3a. log.sh invoked" "grep -q '^LOG' '$r3.aux/log.log'"
check "3a. log.sh invoked with at least one --prd" "grep -q -- '--prd' '$r3.aux/log.log'"
check "3a. log.sh invoked with --parent for this mission" \
  "grep -q -- \"--parent\" '$r3.aux/log.log' && grep -q '$MID' '$r3.aux/log.log'"
check "3a. each authored PRD carries '# Mission:'" \
  "grep -q '^# Mission:' '$r3.aux/prdcap/prd-1.md'"
check "3a. each authored PRD carries '**Type:** bug'" \
  "grep -q '\*\*Type:\*\* bug' '$r3.aux/prdcap/prd-1.md'"
check "3a. PRD carries Conflict/failure summary section" \
  "grep -q 'Conflict/failure summary' '$r3.aux/prdcap/prd-1.md'"
check "3a. PRD carries Root cause section" "grep -q 'Root cause' '$r3.aux/prdcap/prd-1.md'"
check "3a. PRD carries Intended fix section" "grep -q 'Intended fix' '$r3.aux/prdcap/prd-1.md'"
check "3a. mission engine (workerBin) threaded to log.sh (BUG-D)" \
  "grep -q "WB=$r3.aux/worker" '$r3.aux/log.log'"
check "3a. resolve-logs drive invoked" "grep -q '^RESOLVE' '$r3.aux/resolve.log' && ! grep -q 'complete' <(head -1 '$r3.aux/resolve.log')"
check "3a. resolve-logs complete invoked" "grep -q 'complete' '$r3.aux/resolve.log'"
check "3a. reconcileRound recorded (round 1)" "grep -q '\"reconcileRound\"' '$s3'"
check "3a. driver halts reconciling (no PR opened)" "! grep -q 'pr create' '$r3.aux/gh.log'"
check "3a. reconcileStatus persisted" "grep -q '\"reconcileStatus\"' '$s3'"
check "3a. live tree clean even after a red reconcile" \
  "[ -z \"\$(cd '$r3' && git status --porcelain)\" ]"
check "3a. no reconcile worktree leaks" "! (cd '$r3' && git worktree list | grep -q reconcile)"
# BUG-053: the reconcile gate's attached worktree (on $BRANCH) MUST be freed BEFORE
# the self-heal author/dispatch runs. The heal child cherry-picks its green commit
# by `git checkout $BRANCH` in the repo root; if the reconcile worktree still has
# $BRANCH checked out, that checkout fails ("already checked out") and the heal can
# never land → the reconcile dead-ends. The worker stub probes, at the moment it
# runs, whether a reconcile.* worktree is still registered. It must be ABSENT
# (cleanup happened before dispatch) — and never present on ANY dispatch.
check "3a. BUG-053: heal author dispatched (probe recorded at least once)" \
  "[ -s '$r3.aux/wt-probe.log' ]"
check "3a. BUG-053: reconcile worktree was ALREADY FREED before the heal dispatch" \
  "! grep -q present '$r3.aux/wt-probe.log'"

# --- Behaviour 3b: TEXTUAL conflict whose in-worktree resolution STAYS RED →
# falls through to the self-heal log dispatch (multiple PRDs supported). The
# resolve worker removes the markers but cannot reach green (STUB_RESOLVE_RED +
# the needs-resolved suite), so the gate must NOT keep the merge — it undoes it
# and self-heals exactly as before. This is the "still-red still escalates / heals,
# never silently keeps a bad merge" guard alongside the BUG-056 converge path.
r3b="$(mktemp -d "$TMPROOT/r3b.XXXX")"; new_repo_verify "$r3b" >/dev/null; setup_stubs "$r3b"
stage_ticket_suite "$r3b" needs-resolved
advance_base "$r3b" conflict
RECONCILE_BUGS=2 rc=0; STUB_RESOLVE_RED=1 RECONCILE_BUGS=2 run_in "$r3b" reconcile --mission "$MID" >"$r3b.aux/out.txt" 2>&1 || rc=$?
check "3b. textual conflict dispatches a Mission Log" "grep -q '^LOG' '$r3b.aux/log.log'"
check "3b. two clusters → two --prd args" \
  "[ \"\$(grep -o -- '--prd' '$r3b.aux/log.log' | wc -l | tr -d ' ')\" -ge 2 ]"
check "3b. no PR opened on a textual conflict" "! grep -q 'pr create' '$r3b.aux/gh.log'"
check "3b. live tree clean after a conflicting merge" \
  "[ -z \"\$(cd '$r3b' && git status --porcelain)\" ]"
check "3b. no reconcile worktree leaks after conflict" \
  "! (cd '$r3b' && git worktree list | grep -q reconcile)"

# --- BUG-056: a TEXTUAL conflict that RESOLVES green CONVERGES — keep the merge ---
# The bug: every reconcile pass re-merged base FRESH into the un-merged branch, so a
# resolved-then-undone merge re-conflicted forever → loop to escalate. The fix
# RESOLVES the markers IN the merge worktree and KEEPS the merge (commits it), so
# the branch genuinely contains base and the next pass reads "not behind" → green.
# Here the resolve worker (default stub) removes the markers and the suite goes green
# → the gate must EXIT 0, KEEP the merge (branch now an ancestor-of-base / contains
# base's commit), dispatch NO Mission Log, open NO PR itself, and leave a clean tree.
b56="$(mktemp -d "$TMPROOT/b56.XXXX")"; new_repo_verify "$b56" >/dev/null; setup_stubs "$b56"
stage_ticket_suite "$b56" needs-resolved      # green ONLY if the markers are resolved to "resolved"
advance_base "$b56" conflict                  # textual conflict on shared.txt
b56base="$(cd "$b56" && git rev-parse --abbrev-ref HEAD)"
b56base_sha="$(cd "$b56" && git rev-parse "$b56base")"
rc56=0; run_in "$b56" reconcile --mission "$MID" >"$b56.aux/out.txt" 2>&1 || rc56=$?
s56="$(state_of "$b56")"
check "B56. a resolvable textual conflict CONVERGES (exit 0, not a heal/escalate loop)" \
  "[ '$rc56' -eq 0 ]"
check "B56. the resolved merge is KEPT — the mission branch now CONTAINS base" \
  "(cd '$b56' && git merge-base --is-ancestor '$b56base_sha' lcars/$MID)"
check "B56. a re-run is now 'not behind' base (true convergence, no second round)" \
  "[ \"\$(cd '$b56' && git rev-list --count lcars/$MID..$b56base 2>/dev/null)\" = 0 ]"
check "B56. convergence dispatched NO Mission Log (no undo+re-heal)" \
  "! grep -q '^LOG' '$b56.aux/log.log'"
check "B56. convergence opened NO PR itself (reports proceed)" \
  "! grep -q 'pr create' '$b56.aux/gh.log' && grep -qi 'proceed\|RECONCILE: ok\|green' '$b56.aux/out.txt'"
check "B56. convergence did NOT escalate (no awaiting-human gate)" \
  "! grep -q '\"awaitingHuman\": *true' '$s56'"
check "B56. reconcileRound cleared on a converged resolution" \
  "! grep -q '\"reconcileRound\"' '$s56'"
check "B56. the captain's live tree stays clean after a resolved-merge convergence" \
  "[ -z \"\$(cd '$b56' && git status --porcelain)\" ]"
check "B56. no reconcile worktree leaks after convergence" \
  "! (cd '$b56' && git worktree list | grep -q reconcile)"

# B56a — the in-worktree resolve honours the captain's answers.json decision (BUG-042
# parity): when a decision has been recorded, the resolve worker's prompt must carry
# it verbatim, framed as a decision to implement (not a fresh option to weigh).
b56a="$(mktemp -d "$TMPROOT/b56a.XXXX")"; new_repo_verify "$b56a" >/dev/null; setup_stubs "$b56a"
stage_ticket_suite "$b56a" needs-resolved; advance_base "$b56a" conflict
printf '{ "answer": "Move the best-score readout to the top-left corner." }\n' \
  >"$(mdir_of "$b56a")/answers.json"
: >"$b56a.aux/worker-prompt.log"
run_in "$b56a" reconcile --mission "$MID" >"$b56a.aux/out.txt" 2>&1 || true
check "B56a. the resolve worker prompt carries the captain's recorded decision verbatim" \
  "grep -q 'top-left corner' '$b56a.aux/worker-prompt.log'"
check "B56a. the injected decision is framed as a settled choice to implement" \
  "grep -qi 'captain decided\|implement EXACTLY' '$b56a.aux/worker-prompt.log'"

# B56b — convergence under a DRIVE pass: the resolved merge is kept AND the PR opens
# (the converge path returns 0, so drive_verify proceeds to open the PR — exactly
# like the clean+green path). Proves the fix integrates end-to-end, not just in the
# bare `reconcile` subcommand.
b56d="$(mktemp -d "$TMPROOT/b56d.XXXX")"; new_repo_verify "$b56d" >/dev/null; setup_stubs "$b56d"
stage_ticket_suite "$b56d" needs-resolved; advance_base "$b56d" conflict
run_in "$b56d" drive --mission "$MID" >"$b56d.aux/out.txt" 2>&1 || true
check "B56b. drive on a resolvable textual conflict reconciles THEN opens the PR" \
  "grep -q 'pr create' '$b56d.aux/gh.log'"
check "B56b. drive kept the resolved merge on the branch (contains base's commit)" \
  "(cd '$b56d' && git log --oneline lcars/$MID) | qgrep -q 'main edits shared'"

# B56c — a STILL-RED textual resolution must NOT keep the merge: it falls through to
# the existing self-heal (round 1) and, when never green, escalates after K rounds —
# i.e. no infinite loop and no shipping a bad merge. (Companion to 3b.)
b56c="$(mktemp -d "$TMPROOT/b56c.XXXX")"; new_repo_verify "$b56c" >/dev/null; setup_stubs "$b56c"
stage_ticket_suite "$b56c" needs-resolved; advance_base "$b56c" conflict
b56cbase="$(cd "$b56c" && git rev-parse --abbrev-ref HEAD)"
LCARS_RECONCILE_MAX=2 STUB_RESOLVE_RED=1 run_in "$b56c" reconcile --mission "$MID" >"$b56c.aux/p1.txt" 2>&1 || true
LCARS_RECONCILE_MAX=2 STUB_RESOLVE_RED=1 run_in "$b56c" reconcile --mission "$MID" >"$b56c.aux/p2.txt" 2>&1 || true
LCARS_RECONCILE_MAX=2 STUB_RESOLVE_RED=1 run_in "$b56c" reconcile --mission "$MID" >"$b56c.aux/p3.txt" 2>&1 || true
s56c="$(state_of "$b56c")"
check "B56c. a never-green textual resolution does NOT keep the merge (still behind base)" \
  "[ \"\$(cd '$b56c' && git rev-list --count lcars/$MID..$b56cbase 2>/dev/null)\" -ge 1 ]"
check "B56c. a never-green textual resolution escalates (no infinite loop)" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$s56c' && grep -q '\"awaitingHuman\": *true' '$s56c'"
check "B56c. a never-green textual resolution never opens a PR" \
  "! grep -q 'pr create' '$b56c.aux/gh.log'"
check "B56c. live tree clean after the never-green resolution" \
  "[ -z \"\$(cd '$b56c' && git status --porcelain)\" ]"

# --- BUG-057: a non-green in-worktree RESOLVE records WHY, durably (BUG-051 parity) --
# In LIVE runs the cold resolve worker keeps falling through to the heal loop, but
# the reason is invisible (the worktree + retest output are ephemeral). The resolve
# path must append a timestamped record to $MISSION_DIR/reconcile-resolve.log on each
# attempt — capturing whether conflict markers REMAIN and/or which ticket suite went
# RED with its output tail — AND emit a reconcile_resolve_failed event carrying a
# NON-generic reason. Purely additive: outcomes (3b/B56c) are unchanged.
#
# B57a — the resolution is MARKER-FREE but the retest stays RED (STUB_RESOLVE_RED +
# the needs-resolved suite): the log must name the RED suite (t-001) and carry its
# output tail; the event reason must name the red suite, not a bare "failed".
b57="$(mktemp -d "$TMPROOT/b57.XXXX")"; new_repo_verify "$b57" >/dev/null; setup_stubs "$b57"
stage_ticket_suite "$b57" needs-resolved
advance_base "$b57" conflict
STUB_RESOLVE_RED=1 run_in "$b57" reconcile --mission "$MID" >"$b57.aux/out.txt" 2>&1 || true
rl57="$(mdir_of "$b57")/reconcile-resolve.log"
ev57="$(mdir_of "$b57")/events.jsonl"
check "B57a. reconcile-resolve.log is written on a non-green resolve attempt" \
  "[ -s '$rl57' ]"
check "B57a. reconcile-resolve.log names the RED ticket suite (non-generic)" \
  "grep -q 't-001' '$rl57'"
check "B57a. reconcile-resolve.log carries the failing suite's output tail" \
  "grep -Eqi 'red|fail|retest|suite' '$rl57'"
check "B57a. reconcile-resolve.log records the attempt number" \
  "grep -Eqi 'attempt' '$rl57'"
check "B57a. a reconcile_resolve_failed event is emitted" \
  "grep -q '\"type\":\"reconcile_resolve_failed\"' '$ev57'"
check "B57a. the reconcile_resolve_failed event carries a NON-generic reason (names the red suite)" \
  "grep '\"type\":\"reconcile_resolve_failed\"' '$ev57' | grep -Eq 't-001|suite|red'"
check "B57a. additive only: the still-red resolve STILL falls through to the heal/log" \
  "grep -q '^LOG' '$b57.aux/log.log'"
check "B57a. additive only: still no PR on a non-green resolve" \
  "! grep -q 'pr create' '$b57.aux/gh.log'"

# B57b — the resolution leaves conflict MARKERS in place (the worker did not finish):
# the log must record that markers REMAIN in the conflicted file, and the event reason
# must say markers-remain. Simulate a worker that does NOT clear the markers by
# pointing $LCARS_WORKER_BIN at a no-op stub for the resolve role only is awkward;
# instead use a worker stub variant that leaves the markers. We reuse the existing
# stub but with STUB_RESOLVE_NOOP to make it a no-op (markers untouched).
b57b="$(mktemp -d "$TMPROOT/b57b.XXXX")"; new_repo_verify "$b57b" >/dev/null; setup_stubs "$b57b"
stage_ticket_suite "$b57b" needs-resolved
advance_base "$b57b" conflict
STUB_RESOLVE_NOOP=1 run_in "$b57b" reconcile --mission "$MID" >"$b57b.aux/out.txt" 2>&1 || true
rl57b="$(mdir_of "$b57b")/reconcile-resolve.log"
ev57b="$(mdir_of "$b57b")/events.jsonl"
check "B57b. reconcile-resolve.log records that conflict MARKERS REMAIN" \
  "grep -Eqi 'marker' '$rl57b'"
check "B57b. reconcile-resolve.log names the file that still has markers" \
  "grep -q 'shared.txt' '$rl57b'"
check "B57b. the reconcile_resolve_failed event reason says markers-remain" \
  "grep '\"type\":\"reconcile_resolve_failed\"' '$ev57b' | grep -Eqi 'marker'"
check "B57b. additive only: markers-remain still falls through to the heal/log" \
  "grep -q '^LOG' '$b57b.aux/log.log'"

# --- Behaviour 3c: authoring runs on the COPILOT engine too (BUG-D) -----------
r3c="$(mktemp -d "$TMPROOT/r3c.XXXX")"; MISSION_ENGINE=copilot new_repo_verify "$r3c" >/dev/null
setup_stubs "$r3c"; stage_ticket_suite "$r3c" red; advance_base "$r3c" clean
MISSION_ENGINE=copilot run_in "$r3c" reconcile --mission "$MID" >"$r3c.aux/out.txt" 2>&1 || true
check "3c. copilot mission threads copilot engine to log.sh" \
  "grep -q "WB=$r3c.aux/worker" '$r3c.aux/log.log'"
check "3c. copilot mission still authored a valid bug PRD" \
  "grep -q '^# Mission:' '$r3c.aux/prdcap/prd-1.md' && grep -q '\*\*Type:\*\* bug' '$r3c.aux/prdcap/prd-1.md'"

# --- Behaviour 4: still red after K rounds → escalate awaiting-human ----------
r4="$(mktemp -d "$TMPROOT/r4.XXXX")"; new_repo_verify "$r4" >/dev/null; setup_stubs "$r4"
stage_ticket_suite "$r4" red
advance_base "$r4" clean
# K=2: pass 1 (round 1), pass 2 (round 2), pass 3 (round > K) → escalate
s4="$(state_of "$r4")"
LCARS_RECONCILE_MAX=2 run_in "$r4" reconcile --mission "$MID" >"$r4.aux/p1.txt" 2>&1 || true
check "4. round 1 recorded after pass 1" "grep -q 'reconcileRound' '$s4'"
check "4. pass 1 does not escalate" "! grep -q '\"awaitingHuman\": *true' '$s4'"
LCARS_RECONCILE_MAX=2 run_in "$r4" reconcile --mission "$MID" >"$r4.aux/p2.txt" 2>&1 || true
LCARS_RECONCILE_MAX=2 run_in "$r4" reconcile --mission "$MID" >"$r4.aux/p3.txt" 2>&1 || true
check "4. escalates awaiting-human after K rounds" "grep -q '\"awaitingHuman\": *true' '$s4'"
check "4. records a pendingQuestion (the diagnosis)" "grep -q 'pendingQuestion' '$s4'"
check "4. writes pending.json on escalation" "[ -f '$(mdir_of "$r4")/pending.json' ]"
check "4. applies lcars:awaiting-human label" "grep -q 'awaiting-human' '$r4.aux/gh.log'"
check "4. NEVER opens a PR on escalation" "! grep -q 'pr create' '$r4.aux/gh.log'"
check "4. stays at verify on escalation" "grep -q '\"stage\": *\"verify\"' '$s4'"
check "4. fires a gate notification" "grep -q NOTIFY '$r4.aux/notify.log'"
# REGRESSION (the defect): reconcile_gate writes a MULTI-LINE failure summary into
# reconcileDiagnosis. With the old json_escape (only \ and ") that produced
# INVALID JSON (Invalid control character), so the viewscreen dropped the
# escalated, awaiting-human parent entirely. state.json must be VALID JSON now.
check "4. a multi-line reconcileDiagnosis was persisted" "grep -q 'reconcileDiagnosis' '$s4'"
check "4. state.json is VALID JSON after the multi-line escalation diagnosis" \
  "python3 -c \"import json,sys; json.load(open('$s4'))\""

# --- Behaviour 5: isolation — live tree stays clean on a conflicting merge -----
# (covered above by the clean-tree checks; re-assert no worktree dir survives.)
r5="$(mktemp -d "$TMPROOT/r5.XXXX")"; new_repo_verify "$r5" >/dev/null; setup_stubs "$r5"
stage_ticket_suite "$r5" green; advance_base "$r5" conflict
run_in "$r5" reconcile --mission "$MID" >"$r5.aux/out.txt" 2>&1 || true
check "5. no reconcile.* worktree directory leaks under the mission dir" \
  "! ls -d '$(mdir_of "$r5")'/reconcile.* 2>/dev/null | grep -q reconcile"
check "5. git worktree list has no reconcile entry" \
  "! (cd '$r5' && git worktree list | grep -q reconcile)"
check "5. the captain's working tree is unmodified" \
  "[ -z \"\$(cd '$r5' && git status --porcelain)\" ]"

# --- Behaviour 7: guard — no false ready-to-merge on a non-green outcome -------
# Re-use r3 (red): open_pr / cmd_open_pr must never have been reached.
check "7. red outcome never called gh pr create" "! grep -q 'pr create' '$r3.aux/gh.log'"
check "7. red outcome left no prUrl in state" "! grep -q 'prUrl' '$s3'"
check "7. red outcome left the mission at verify" "grep -q '\"stage\": *\"verify\"' '$s3'"

# Guard: a NOT-AHEAD reconcile must report 'proceed' so drive_verify falls through
# to today's open-PR path (the open itself is exercised by lcars-verify-pr.test.sh).
check "7. not-ahead reconcile signals proceed-to-open-PR" \
  "grep -qi 'proceed\|not ahead\|RECONCILE: ok' '$r1.aux/out.txt'"

# --- DRIVE integration: the gate is wired into drive_verify (not just reconcile) --
# A full `drive` pass on a clean+green ahead repo reconciles (merges main in) THEN
# opens the PR (gate raised). A full `drive` on a red repo self-heals + HALTS
# "reconciling" without opening a PR.
rd="$(mktemp -d "$TMPROOT/rd.XXXX")"; new_repo_verify "$rd" >/dev/null; setup_stubs "$rd"
stage_ticket_suite "$rd" green; advance_base "$rd" clean
run_in "$rd" drive --mission "$MID" >"$rd.aux/out.txt" 2>&1 || true
sd="$(state_of "$rd")"
check "D. drive reconciles clean+green then OPENS the PR (gate raised)" \
  "grep -q 'pr create' '$rd.aux/gh.log'"
check "D. drive recorded the merge on the branch" \
  "(cd '$rd' && git log --oneline lcars/$MID) | qgrep -q 'main moves ahead'"

rdr="$(mktemp -d "$TMPROOT/rdr.XXXX")"; new_repo_verify "$rdr" >/dev/null; setup_stubs "$rdr"
stage_ticket_suite "$rdr" red; advance_base "$rdr" clean
run_in "$rdr" drive --mission "$MID" >"$rdr.aux/out.txt" 2>&1 || true
check "D. drive on a red reconcile NEVER opens a PR" \
  "! grep -q 'pr create' '$rdr.aux/gh.log'"
check "D. drive on a red reconcile prints the reconciling halt" \
  "grep -qi 'reconcil' '$rdr.aux/out.txt'"
check "D. drive on a red reconcile dispatched a Mission Log" \
  "grep -q '^LOG' '$rdr.aux/log.log'"

# --- BUG-038: worktree-cut failure → honest non-proceed, never false success --
# Force `git worktree add` to fail by checking the mission branch out elsewhere
# AND leaving a stale conflicting worktree dir registered, so even after a prune+
# retry the cut still cannot happen. reconcile must NOT exit 0 and must NOT leave
# state implying success — it must escalate with a clear, actionable message.
b38="$(mktemp -d "$TMPROOT/b38.XXXX")"; new_repo_verify "$b38" >/dev/null; setup_stubs "$b38"
stage_ticket_suite "$b38" green; advance_base "$b38" clean
# Occupy the mission branch in a sibling worktree so it is "checked out elsewhere"
# — git refuses to add a second worktree on the same branch.
( cd "$b38" && git worktree add -q "$b38.busywt" "lcars/$MID" >/dev/null 2>&1 ) || true
rc38=0; run_in "$b38" reconcile --mission "$MID" >"$b38.aux/out.txt" 2>&1 || rc38=$?
s38="$(state_of "$b38")"
check "B38. worktree-cut failure does NOT exit 0 (no false proceed)" "[ '$rc38' -ne 0 ]"
check "B38. worktree-cut failure prints an actionable message (checked out elsewhere / stale worktree)" \
  "grep -qi 'checked out\|another worktree\|stale worktree\|free it' '$b38.aux/out.txt'"
check "B38. worktree-cut failure NEVER reports RECONCILE: ok" \
  "! grep -q 'RECONCILE: ok' '$b38.aux/out.txt'"
check "B38. worktree-cut failure never opens a PR" "! grep -q 'pr create' '$b38.aux/gh.log'"
check "B38. no reconcileStatus implying success (merging/retesting/green not left as terminal)" \
  "! grep -q '\"reconcileStatus\": *\"green\"' '$s38'"
# clean up the busy sibling worktree so later assertions / EXIT trap stay tidy
( cd "$b38" && git worktree remove --force "$b38.busywt" >/dev/null 2>&1 ) || true

# --- BUG-054: reconcile while the MAIN tree is ON the mission branch -----------
# The NORMAL post-Implement / post-heal state leaves $REPO_ROOT checked out ON the
# mission branch (the heal's cherry-pick does `git checkout $BRANCH` in the repo
# root). An ATTACHED `git worktree add "$wt" "$BRANCH"` then fails with "already
# checked out at <repo>", which tripped the BUG-038 worktree-cut escalation and
# dead-ended a 2nd reconcile round / 2nd captain Merge click. The gate must detach
# the main tree off the branch first so the cut succeeds and the heal proceeds.
b54="$(mktemp -d "$TMPROOT/b54.XXXX")"; new_repo_verify "$b54" >/dev/null; setup_stubs "$b54"
stage_ticket_suite "$b54" red; advance_base "$b54" clean
# Put the captain's MAIN working tree ON the mission branch — the real post-heal state.
( cd "$b54" && git checkout -q "lcars/$MID" )
rc54=0; run_in "$b54" reconcile --mission "$MID" >"$b54.aux/out.txt" 2>&1 || rc54=$?
s54="$(state_of "$b54")"
check "B54. reconcile on a branch-checked-out main tree does NOT raise the worktree-cut escalation" \
  "! grep -qi 'checked out in another worktree\|stale worktree\|free it' '$b54.aux/out.txt'"
check "B54. reconcile on a branch-checked-out main tree does NOT exit 20 with the cut diagnosis" \
  "[ '$rc54' -ne 20 ]"
check "B54. reconcile on a branch-checked-out main tree still cut the worktree and ran the heal (log dispatched)" \
  "grep -q '^LOG' '$b54.aux/log.log'"
check "B54. reconcile on a branch-checked-out main tree reached the healing path (round recorded)" \
  "grep -q '\"reconcileRound\"' '$s54'"
check "B54. no reconcile worktree leaks after a branch-checked-out reconcile" \
  "! (cd '$b54' && git worktree list | grep -q reconcile)"

# --- BUG-041: a heal round that can't reach green must ESCALATE, never freeze ---
# Drive the SAME red mission RECONCILE_MAX times. The final state MUST be a clean
# terminal escalation (escalated + gate raised), NEVER a frozen reconcileStatus=
# healing with no gate (the silent dead-end).
b41="$(mktemp -d "$TMPROOT/b41.XXXX")"; new_repo_verify "$b41" >/dev/null; setup_stubs "$b41"
stage_ticket_suite "$b41" red; advance_base "$b41" clean
LCARS_RECONCILE_MAX=2 run_in "$b41" reconcile --mission "$MID" >"$b41.aux/p1.txt" 2>&1 || true
LCARS_RECONCILE_MAX=2 run_in "$b41" reconcile --mission "$MID" >"$b41.aux/p2.txt" 2>&1 || true
LCARS_RECONCILE_MAX=2 run_in "$b41" reconcile --mission "$MID" >"$b41.aux/p3.txt" 2>&1 || true
s41="$(state_of "$b41")"
check "B41. exhausted heal reaches reconcileStatus=escalated (clean terminal)" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$s41'"
check "B41. exhausted heal is NEVER left frozen at reconcileStatus=healing" \
  "! grep -q '\"reconcileStatus\": *\"healing\"' '$s41'"
check "B41. exhausted heal raises the awaiting-human gate (pending.json)" \
  "[ -f '$(mdir_of "$b41")/pending.json' ] && grep -q '\"awaitingHuman\": *true' '$s41'"
check "B41. exhausted heal fires exactly one gate notification" \
  "[ \"\$(grep -c NOTIFY '$b41.aux/notify.log')\" -eq 1 ]"
check "B41. exhausted heal never opens a PR" "! grep -q 'pr create' '$b41.aux/gh.log'"

# --- BUG-042: design-conflict → experience-framed question, then resume injects answer
# The author detects an unresolvable DESIGN trade-off and emits an experience-framed
# QUESTION instead of bug PRDs. reconcile escalates immediately with THAT question.
b42="$(mktemp -d "$TMPROOT/b42.XXXX")"; new_repo_verify "$b42" >/dev/null; setup_stubs "$b42"
stage_ticket_suite "$b42" red; advance_base "$b42" clean
DQ='The best-score readout and the xN multiplier badge both render in the top-right corner and overlap — how should they be arranged? (e.g. stack them, move best-score to the top-left, shrink one)'
STUB_DESIGN_QUESTION=1 STUB_DESIGN_QUESTION_TEXT="$DQ" \
  run_in "$b42" reconcile --mission "$MID" >"$b42.aux/p1.txt" 2>&1 || true
s42="$(state_of "$b42")"
pj42="$(mdir_of "$b42")/pending.json"
check "B42. design-conflict escalates to awaiting-human" "grep -q '\"awaitingHuman\": *true' '$s42'"
check "B42. design-conflict writes pending.json" "[ -f '$pj42' ]"
check "B42. the gate question is the experience-framed design question (player/UX language)" \
  "grep -qi 'overlap\|arranged\|top-right\|badge' '$pj42'"
check "B42. the gate question names NO CLI/code identifiers (no drawScore/refactor/t-001/function)" \
  "! grep -Eqi 'drawScore|refactor|t-001|function|\.js|\.sh' '$pj42'"
check "B42. design-conflict did NOT silently dead-end (status escalated, not healing)" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$s42' && ! grep -q '\"reconcileStatus\": *\"healing\"' '$s42'"
check "B42. design-conflict never opens a PR" "! grep -q 'pr create' '$b42.aux/gh.log'"

# Now simulate the captain answering via respond (writes answers.json + clears the
# gate), then run the NEXT reconcile pass and assert the self-heal worker prompt
# carries the captain's decision verbatim (the answer reached the heal worker).
ANS='Move the best-score readout to the top-left corner and keep the multiplier badge top-right.'
RESPOND_SH="$REPO_ROOT/skills/lcars-respond/respond.sh"
( cd "$b42" && LCARS_GH_BIN="$b42.aux/gh" \
    bash "$RESPOND_SH" answer --mission "$MID" --answer "$ANS" >/dev/null 2>&1 ) || true
check "B42. respond recorded the answer in answers.json" \
  "[ -f '$(mdir_of "$b42")/answers.json' ] && grep -q 'top-left' '$(mdir_of "$b42")/answers.json'"
: >"$b42.aux/worker-prompt.log"
run_in "$b42" reconcile --mission "$MID" >"$b42.aux/p2.txt" 2>&1 || true
check "B42. resumed self-heal injects the captain's answer into the worker prompt" \
  "grep -q 'top-left' '$b42.aux/worker-prompt.log'"
check "B42. resumed self-heal frames the injected answer as a decision to implement" \
  "grep -qi 'captain decided\|the captain decided\|implement exactly\|captain' '$b42.aux/worker-prompt.log'"

# --- BUG-045: the design-question must fire DETERMINISTICALLY on a genuinely
# unresolvable conflict — NOT only when the author guesses "trade-off" upfront.
#
# The collision shape: two features competing for the SAME experience (mutually-
# exclusive locked tests). The reconcile-author judges "I can heal this" and
# authors a self-heal (NOT a design-question) on pass 1. That heal CANNOT reach
# green (the suite stays red on the next merge). The harness must then ESCALATE
# WITH AN EXPERIENCE-FRAMED DESIGN QUESTION rather than grind heal rounds to the
# cap, regardless of the author's upfront output.

# B45a (regression guard): a heal that DOES reach green → NO design question,
# reconcile proceeds (the deterministic escalation must NOT over-fire when the
# heal actually works — simulate the heal landing its fix by flipping the suite
# green between passes).
b45a="$(mktemp -d "$TMPROOT/b45a.XXXX")"; new_repo_verify "$b45a" >/dev/null; setup_stubs "$b45a"
stage_ticket_suite "$b45a" red; advance_base "$b45a" clean
run_in "$b45a" reconcile --mission "$MID" >"$b45a.aux/p1.txt" 2>&1 || true   # round 1: red → heal
stage_ticket_suite "$b45a" green                                            # the heal "landed" a fix
run_in "$b45a" reconcile --mission "$MID" >"$b45a.aux/p2.txt" 2>&1 || true   # round 2: green → proceed
s45a="$(state_of "$b45a")"
check "B45a. a heal that reaches green never escalates a design question" \
  "! grep -q '\"reconcileStatus\": *\"escalated\"' '$s45a'"
check "B45a. a healed reconcile clears the round (green path) and never raises a gate" \
  "! grep -q '\"awaitingHuman\": *true' '$s45a'"
check "B45a. a healed reconcile reports green/proceed" \
  "grep -qi 'green\|proceed' '$b45a.aux/p2.txt'"

# B45b (the bug): a heal that CANNOT reach green on a mutually-exclusive cross-
# ticket conflict → reconcile ESCALATES WITH a design question deterministically,
# WITHOUT the author emitting design-question.txt upfront on pass 1.
#   pass 1: author writes a self-heal (no design-question.txt) → dispatched → halt.
#   pass 2: re-merge still RED (heal couldn't satisfy both) → harness re-authors
#           the question with FORCE-DESIGN-QUESTION and escalates with it.
b45b="$(mktemp -d "$TMPROOT/b45b.XXXX")"; new_repo_verify "$b45b" >/dev/null; setup_stubs "$b45b"
stage_ticket_suite "$b45b" red; advance_base "$b45b" clean
FDQ='Two features want the same top-right corner of the screen at the same moment, and only one can sit there — which should the player see there? (e.g. keep the score badge, show the timer instead, or alternate them)'
# pass 1: NO upfront design question (STUB_DESIGN_QUESTION unset) → author heals.
run_in "$b45b" reconcile --mission "$MID" >"$b45b.aux/p1.txt" 2>&1 || rc45p1=$?
s45b="$(state_of "$b45b")"
check "B45b. pass 1 (heal authored, not a design question) halts reconciling, no escalation yet" \
  "! grep -q '\"reconcileStatus\": *\"escalated\"' '$s45b'"
# pass 2: suite STILL red (the heal could not satisfy both sides) → deterministic
# design-question escalation. The re-author honours FORCE-DESIGN-QUESTION.
rc45=0
STUB_FORCED_DESIGN_QUESTION_TEXT="$FDQ" \
  run_in "$b45b" reconcile --mission "$MID" >"$b45b.aux/p2.txt" 2>&1 || rc45=$?
s45b="$(state_of "$b45b")"
pj45b="$(mdir_of "$b45b")/pending.json"
check "B45b. an unhealable conflict escalates (exit 20), never silently grinds" "[ '$rc45' -eq 20 ]"
check "B45b. reconcileStatus=escalated (clean terminal, not healing)" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$s45b' && ! grep -q '\"reconcileStatus\": *\"healing\"' '$s45b'"
check "B45b. raises the awaiting-human gate with pending.json" \
  "grep -q '\"awaitingHuman\": *true' '$s45b' && [ -f '$pj45b' ]"
check "B45b. the escalation question is the experience-framed design question" \
  "grep -qi 'top-right\|player\|screen\|corner' '$pj45b'"
check "B45b. the design question names NO code identifiers (no .js/.sh/t-001/function/refactor)" \
  "! grep -Eqi 'drawScore|refactor|t-001|function|\.js|\.sh' '$pj45b'"
check "B45b. never opens a PR on the unhealable conflict" "! grep -q 'pr create' '$b45b.aux/gh.log'"
check "B45b. fires exactly one gate notification across the escalation pass" \
  "[ \"\$(grep -c NOTIFY '$b45b.aux/notify.log')\" -ge 1 ]"
check "B45b. live tree stays clean after the unhealable reconcile" \
  "[ -z \"\$(cd '$b45b' && git status --porcelain)\" ]"
check "B45b. no reconcile worktree leaks" "! (cd '$b45b' && git worktree list | grep -q reconcile)"

# B45c (deterministic-fallback): even when the re-author yields NO question text,
# the harness must STILL escalate with an experience-framed question (over-asking
# beats grinding). Here STUB_FORCED_DESIGN_QUESTION_TEXT is UNSET so the re-author
# produces nothing; the harness falls back to its own player-facing question.
b45c="$(mktemp -d "$TMPROOT/b45c.XXXX")"; new_repo_verify "$b45c" >/dev/null; setup_stubs "$b45c"
stage_ticket_suite "$b45c" red; advance_base "$b45c" clean
run_in "$b45c" reconcile --mission "$MID" >"$b45c.aux/p1.txt" 2>&1 || true     # round 1 → heal
rc45c=0
run_in "$b45c" reconcile --mission "$MID" >"$b45c.aux/p2.txt" 2>&1 || rc45c=$? # round 2 → escalate
s45c="$(state_of "$b45c")"
pj45c="$(mdir_of "$b45c")/pending.json"
check "B45c. still escalates a design question when the re-author yields no text" \
  "[ '$rc45c' -eq 20 ] && grep -q '\"reconcileStatus\": *\"escalated\"' '$s45c'"
check "B45c. fallback question still raises pending.json and avoids code identifiers" \
  "[ -f '$pj45c' ] && ! grep -Eqi 'drawScore|t-001|\.js|\.sh' '$pj45c'"

# B45d (idempotency): once escalated, re-running the gate must NOT re-notify or
# re-escalate (protects BUG-041's 'exactly one notification' contract under the
# new earlier escalation).
b45d="$(mktemp -d "$TMPROOT/b45d.XXXX")"; new_repo_verify "$b45d" >/dev/null; setup_stubs "$b45d"
stage_ticket_suite "$b45d" red; advance_base "$b45d" clean
run_in "$b45d" reconcile --mission "$MID" >"$b45d.aux/p1.txt" 2>&1 || true   # heal
run_in "$b45d" reconcile --mission "$MID" >"$b45d.aux/p2.txt" 2>&1 || true   # escalate (notify)
run_in "$b45d" reconcile --mission "$MID" >"$b45d.aux/p3.txt" 2>&1 || true   # already escalated → no-op
check "B45d. an already-escalated reconcile does not fire a second notification" \
  "[ \"\$(grep -c NOTIFY '$b45d.aux/notify.log')\" -eq 1 ]"
check "B45d. an already-escalated reconcile never opens a PR" "! grep -q 'pr create' '$b45d.aux/gh.log'"

# --- BUG-051: a TERMINAL replay/cherry-pick failure records WHY (durable cause) --
# When a ticket's replay cherry-pick genuinely FAILS (BUG-053: green-via-serial-
# rebuild, then a cherry-pick that vanishes), the cause used to be discarded — the
# only signal was a generic "implement failed". Drive a DETERMINISTIC cherry-pick
# CONFLICT through the terminal-recording path (the same path rebuild_ticket_on_tip
# takes when its rebuilt commit still fails to cherry-pick) and assert the cause is
# captured: implement-failure.log written with the conflicted path + git error, AND
# a ticket_replay_failed event carrying a NON-generic reason. NO worker, NO tokens —
# only real local git builds the conflict, exactly like the existing replay tests.
b51="$(mktemp -d "$TMPROOT/b51.XXXX")"
( cd "$b51" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'orig\n' >shared.txt && git add -A && git commit -q -m base \
    && git branch lcars/B )
# A commit on a SIBLING branch that edits shared.txt's only line (off the SAME
# parent), so cherry-picking it onto B — which also moved that line — CONFLICTS.
sha51="$( cd "$b51" \
    && git worktree add -q --detach "$b51/.wtX" lcars/B >/dev/null 2>&1 \
    && printf 'X-from-ticket\n' >"$b51/.wtX/shared.txt" \
    && ( cd "$b51/.wtX" && git add -A >/dev/null 2>&1 && git commit -q -m 'ticket X' >/dev/null 2>&1 && git rev-parse HEAD ) \
    ; git worktree remove --force "$b51/.wtX" >/dev/null 2>&1 )"
# Move branch B's tip so the SAME line differs → the cherry-pick of sha51 conflicts.
( cd "$b51" && git checkout -q lcars/B \
    && printf 'B-from-main\n' >shared.txt && git add -A && git commit -q -m 'B tip' \
    && git checkout -q "$(git rev-parse --abbrev-ref HEAD@{-1} 2>/dev/null || echo main)" >/dev/null 2>&1 || true )
m51="$b51/.git/lcars/missions/$MID"; mkdir -p "$m51"
cat >"$m51/state.json" <<EOF
{ "id": "$MID", "type": "feature", "title": "t", "stage": "implement",
  "githubIssue": 42, "branch": "lcars/B" }
EOF
rc51=0
( cd "$b51" && LCARS_GH_BIN=true bash "$RUN_SH" replay-commit-record \
    --mission "$MID" --branch lcars/B --sha "$sha51" --ticket t-051 \
    >"$b51.out" 2>&1 ) || rc51=$?
check "B51. a genuine replay cherry-pick failure exits non-zero" "[ '$rc51' -ne 0 ]"
check "B51. implement-failure.log is written on the terminal replay failure" \
  "[ -s '$m51/implement-failure.log' ]"
check "B51. implement-failure.log names the failing ticket" \
  "grep -q 'ticket=t-051' '$m51/implement-failure.log'"
check "B51. implement-failure.log captures the conflicted path / git error (non-generic)" \
  "grep -Eq 'shared.txt|cherry-pick|conflict' '$m51/implement-failure.log'"
check "B51. a ticket_replay_failed event is emitted" \
  "grep -q '\"type\":\"ticket_replay_failed\"' '$m51/events.jsonl'"
check "B51. the ticket_replay_failed event carries a NON-generic reason (not just 'failed')" \
  "grep '\"type\":\"ticket_replay_failed\"' '$m51/events.jsonl' | grep -Eq 'shared.txt|cherry-pick|conflict'"

# --- BUG-054: a branch checked out in ANOTHER git worktree blocks the replay
# checkout — the failure must NAME the busy branch + worktree + remedy, not the
# misleading generic "cherry-pick failed onto the tip". The replay lands a green
# ticket's commit by checking out the mission branch in the MAIN tree; when that
# branch is already checked out elsewhere, `git checkout` fatals ("already checked
# out at <path>") — deliberate git behaviour, NOT a mergeable conflict. Drive the
# terminal-recording path (replay-commit-record → REPLAY_FAIL_REASON →
# implement-failure.log + ticket_replay_failed event) with a branch held in a
# SECOND worktree and assert the surfaced reason is the actionable branch-held one.
# NO worker, NO tokens — only real local git holds the branch.
b54="$(mktemp -d "$TMPROOT/b54.XXXX")"
( cd "$b54" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'orig\n' >f.txt && git add -A && git commit -q -m base \
    && git branch lcars/B )
# Any commit to (attempt to) replay — the checkout fails BEFORE the cherry-pick,
# so its content is irrelevant; use the base commit's sha.
sha54="$( cd "$b54" && git rev-parse HEAD )"
# Hold lcars/B in a SECOND, ATTACHED worktree so the MAIN tree (still on the
# default branch) cannot check it out. This is what git refuses to move.
heldwt54="$b54/.busywt"
( cd "$b54" && git worktree add -q "$heldwt54" lcars/B >/dev/null 2>&1 )
m54="$b54/.git/lcars/missions/$MID"; mkdir -p "$m54"
cat >"$m54/state.json" <<EOF
{ "id": "$MID", "type": "feature", "title": "t", "stage": "implement",
  "githubIssue": 42, "branch": "lcars/B" }
EOF
rc54=0
( cd "$b54" && LCARS_GH_BIN=true bash "$RUN_SH" replay-commit-record \
    --mission "$MID" --branch lcars/B --sha "$sha54" --ticket t-054 \
    >"$b54.out" 2>&1 ) || rc54=$?
check "B54. a branch-held replay checkout exits non-zero" "[ '$rc54' -ne 0 ]"
check "B54. implement-failure.log is written on the branch-held failure" \
  "[ -s '$m54/implement-failure.log' ]"
check "B54. the reason NAMES the busy branch and says it's checked out in another worktree" \
  "grep -q 'lcars/B is checked out in another git worktree' '$m54/implement-failure.log'"
check "B54. the reason includes the HOLDING worktree path" \
  "grep -Fq '$heldwt54' '$m54/implement-failure.log'"
check "B54. the reason states the remedy (free that worktree / re-run implement)" \
  "grep -Eq 'free that worktree|check it out detached|re-run implement' '$m54/implement-failure.log'"
check "B54. the reason does NOT fall back to the generic cherry-pick-onto-tip line" \
  "! grep -q 'failed to cherry-pick onto the tip' '$m54/implement-failure.log'"
check "B54. the ticket_replay_failed event carries the branch-held reason" \
  "grep '\"type\":\"ticket_replay_failed\"' '$m54/events.jsonl' | grep -q 'checked out in another git worktree'"

# --- BUG-043: the reconcile resume must key off a DEDICATED reconcile answer,
# NEVER the generic answers.json that respond writes for ANY awaiting-human gate.
#
# The defect: reconcile_author_and_dispatch read $MISSION_DIR/answers.json and
# (a) injected it as "the captain decided …", and (b) gated design-question
# authoring on `[ ! -f answers.json ]`. But answers.json is the GENERIC gate
# answer (research >20, validate scope, re-verify Accept, …). A STALE, UNRELATED
# answers.json from a PRIOR gate would therefore be mistaken for the design
# decision AND suppress the design question from ever being raised.
#
# After the fix the reconcile path uses a DEDICATED store (reconcile-answer.txt):
# a stale generic answers.json must NOT suppress the design question, must NOT be
# injected as the decision, and the dedicated answer (when present) is injected
# ONCE and then consumed.
RESPOND_SH="$REPO_ROOT/skills/lcars-respond/respond.sh"

# B43a — a stale GENERIC answers.json (an unrelated prior gate) must NOT suppress
# the BUG-045 deterministic design-question escalation. Drive an unhealable
# conflict to its second pass with a stale answers.json sitting on disk; the gate
# must still escalate a design question (not silently keep healing as if decided).
b43="$(mktemp -d "$TMPROOT/b43.XXXX")"; new_repo_verify "$b43" >/dev/null; setup_stubs "$b43"
stage_ticket_suite "$b43" red; advance_base "$b43" clean
FDQ43='Two readouts want the same corner of the screen and only one fits — which should the player see? (e.g. keep the score, show the timer, or alternate)'
# A STALE, UNRELATED generic answer (e.g. left from an earlier research/validate
# gate). It must NOT be treated as a reconcile design decision.
printf '{ "stage": "validate", "answer": "Use a global leaderboard." }\n' \
  >"$(mdir_of "$b43")/answers.json"
run_in "$b43" reconcile --mission "$MID" >"$b43.aux/p1.txt" 2>&1 || true   # pass 1: heal
rc43=0
STUB_FORCED_DESIGN_QUESTION_TEXT="$FDQ43" \
  run_in "$b43" reconcile --mission "$MID" >"$b43.aux/p2.txt" 2>&1 || rc43=$?
s43="$(state_of "$b43")"
pj43="$(mdir_of "$b43")/pending.json"
check "B43a. a stale generic answers.json does NOT suppress the design-question escalation" \
  "[ '$rc43' -eq 20 ] && grep -q '\"reconcileStatus\": *\"escalated\"' '$s43'"
check "B43a. the design-question gate is raised despite the stale answers.json" \
  "grep -q '\"awaitingHuman\": *true' '$s43' && [ -f '$pj43' ]"
check "B43a. the stale generic answer is NOT injected as the captain's reconcile decision" \
  "! grep -q 'global leaderboard' '$b43.aux/worker-prompt.log'"

# B43b — the resume injects ONLY the DEDICATED reconcile answer (not a stale
# generic answers.json), and CONSUMES it after one use. Set up an escalated
# reconcile design gate, answer it via respond (which writes the dedicated
# reconcile answer + resets the round), keep an unrelated stale answers.json on
# disk, then run the next reconcile pass.
b43b="$(mktemp -d "$TMPROOT/b43b.XXXX")"; new_repo_verify "$b43b" >/dev/null; setup_stubs "$b43b"
stage_ticket_suite "$b43b" red; advance_base "$b43b" clean
DQ43b='The best-score readout and the multiplier badge overlap top-right — how should they sit? (stack, move one, or shrink)'
STUB_DESIGN_QUESTION=1 STUB_DESIGN_QUESTION_TEXT="$DQ43b" \
  run_in "$b43b" reconcile --mission "$MID" >"$b43b.aux/p1.txt" 2>&1 || true
check "B43b. setup: design gate escalated" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$(state_of "$b43b")'"
# The captain answers the reconcile design gate via respond.
RA='Move the best-score readout to the top-left and keep the badge top-right.'
( cd "$b43b" && LCARS_GH_BIN="$b43b.aux/gh" \
    bash "$RESPOND_SH" answer --mission "$MID" --answer "$RA" >/dev/null 2>&1 ) || true
# Plant a stale, UNRELATED generic answers.json AFTER the respond, to prove the
# resume ignores it and uses only the dedicated reconcile answer.
printf '{ "stage": "research", "answer": "Unrelated stale decision DO-NOT-USE." }\n' \
  >"$(mdir_of "$b43b")/answers.json"
: >"$b43b.aux/worker-prompt.log"
run_in "$b43b" reconcile --mission "$MID" >"$b43b.aux/p2.txt" 2>&1 || true
check "B43b. resume injects the DEDICATED reconcile answer into the heal worker prompt" \
  "grep -q 'top-left' '$b43b.aux/worker-prompt.log'"
check "B43b. resume frames the dedicated answer as a decision to implement" \
  "grep -qi 'captain decided\|implement EXACTLY' '$b43b.aux/worker-prompt.log'"
check "B43b. resume does NOT inject the stale unrelated generic answer" \
  "! grep -q 'DO-NOT-USE' '$b43b.aux/worker-prompt.log'"
check "B43b. the dedicated reconcile answer is CONSUMED after one use" \
  "[ ! -f '$(mdir_of "$b43b")/reconcile-answer.txt' ]"

# B43c — once the dedicated reconcile answer is present (a decision is in hand),
# the resume must NOT re-raise the design question even if the merge is still red.
b43c="$(mktemp -d "$TMPROOT/b43c.XXXX")"; new_repo_verify "$b43c" >/dev/null; setup_stubs "$b43c"
stage_ticket_suite "$b43c" red; advance_base "$b43c" clean
DQ43c='Two panels overlap — which should the player see?'
STUB_DESIGN_QUESTION=1 STUB_DESIGN_QUESTION_TEXT="$DQ43c" \
  run_in "$b43c" reconcile --mission "$MID" >"$b43c.aux/p1.txt" 2>&1 || true
( cd "$b43c" && LCARS_GH_BIN="$b43c.aux/gh" \
    bash "$RESPOND_SH" answer --mission "$MID" --answer "Keep the score panel." >/dev/null 2>&1 ) || true
rc43c=0
run_in "$b43c" reconcile --mission "$MID" >"$b43c.aux/p2.txt" 2>&1 || rc43c=$?
check "B43c. with a reconcile decision in hand the resume heals (does not re-escalate a design question)" \
  "[ '$rc43c' -ne 20 ] || ! grep -q '\"awaitingHuman\": *true' '$(state_of "$b43c")'"

# --- BUG-055: answering a reconcile design question RESETS the round budget, so
# the post-answer resume gets a FRESH RECONCILE_MAX (decision-heal + re-merge
# verify) instead of carrying the pre-answer round forward and escalating early.
b55="$(mktemp -d "$TMPROOT/b55.XXXX")"; new_repo_verify "$b55" >/dev/null; setup_stubs "$b55"
stage_ticket_suite "$b55" red; advance_base "$b55" clean
DQ55='Two readouts collide — which should the player see?'
# Drive to the design-question escalation (pass1 heal → pass2 design question).
run_in "$b55" reconcile --mission "$MID" >"$b55.aux/p1.txt" 2>&1 || true
STUB_FORCED_DESIGN_QUESTION_TEXT="$DQ55" \
  run_in "$b55" reconcile --mission "$MID" >"$b55.aux/p2.txt" 2>&1 || true
# At escalation the round counter has advanced (>=2). Capture it.
round_before="$(sed -n 's/.*"reconcileRound"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$(state_of "$b55")" | head -1)"
check "B55. round advanced before the answer (>=2)" "[ \"\${round_before:-0}\" -ge 2 ]"
# The captain answers the reconcile design gate via respond.
( cd "$b55" && LCARS_GH_BIN="$b55.aux/gh" \
    bash "$RESPOND_SH" answer --mission "$MID" --answer "Keep the score." >/dev/null 2>&1 ) || true
check "B55. answering a reconcile design gate RESETS the round budget (reconcileRound cleared)" \
  "! grep -q '\"reconcileRound\"' '$(state_of "$b55")'"
check "B55. answering clears the escalated status so the resume can re-enter" \
  "! grep -q '\"reconcileStatus\": *\"escalated\"' '$(state_of "$b55")'"
# The next reconcile pass must start FRESH (round 1), not carry round_before forward.
run_in "$b55" reconcile --mission "$MID" >"$b55.aux/p3.txt" 2>&1 || true
round_after="$(sed -n 's/.*"reconcileRound"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$(state_of "$b55")" | head -1)"
check "B55. the post-answer resume restarts the budget fresh (round 1, not carried forward)" \
  "[ \"\${round_after:-0}\" -eq 1 ]"

# --- BUG-052: a HEAL DRIVE that itself FAILS must escalate, never freeze -------
# The deadlock: on the FIRST red round the harness authors + dispatches a self-heal,
# but the dispatched heal child cannot be driven to a usable state (its implement
# hard-fails → resolve-logs `die`s with WAVE_ERRORED). The OLD code ignored that
# failure and still set reconcileStatus=healing + returned 10 — leaving the parent
# FROZEN: reconcileStatus=healing, nothing running, NO awaiting-human gate, and the
# board's resolving/reconciling lock (BUG-035/039) suppressing Merge with no escape.
# The fix: a FAILED heal drive must terminate cleanly as an awaiting-human gate
# (reconcileStatus=escalated + pending.json + ONE notify, exit 20) so the board's
# gate rendering clears the lock and the captain gets an action.
b52="$(mktemp -d "$TMPROOT/b52.XXXX")"; new_repo_verify "$b52" >/dev/null; setup_stubs "$b52"
stage_ticket_suite "$b52" red; advance_base "$b52" clean
rc52=0
STUB_RESOLVE_FAIL=1 run_in "$b52" reconcile --mission "$MID" >"$b52.aux/p1.txt" 2>&1 || rc52=$?
s52="$(state_of "$b52")"
pj52="$(mdir_of "$b52")/pending.json"
check "B52. a FAILED heal drive escalates (exit 20), not a 'reconciling' halt (exit 10)" \
  "[ '$rc52' -eq 20 ]"
check "B52. a FAILED heal drive reaches reconcileStatus=escalated (clean terminal)" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$s52'"
check "B52. a FAILED heal drive is NEVER left frozen at reconcileStatus=healing" \
  "! grep -q '\"reconcileStatus\": *\"healing\"' '$s52'"
check "B52. a FAILED heal drive raises the awaiting-human gate (state + pending.json)" \
  "grep -q '\"awaitingHuman\": *true' '$s52' && [ -f '$pj52' ]"
check "B52. a FAILED heal drive fires exactly one gate notification" \
  "[ \"\$(grep -c NOTIFY '$b52.aux/notify.log')\" -eq 1 ]"
check "B52. a FAILED heal drive never opens a PR" "! grep -q 'pr create' '$b52.aux/gh.log'"
check "B52. live tree stays clean after a failed heal drive" \
  "[ -z \"\$(cd '$b52' && git status --porcelain)\" ]"
check "B52. no reconcile worktree leaks after a failed heal drive" \
  "! (cd '$b52' && git worktree list | grep -q reconcile)"

# B52b (regression guard): a SUCCESSFUL heal dispatch (drive does NOT fail) still
# halts "reconciling" (exit 10, reconcileStatus=healing) on the first red round —
# the fix must NOT over-fire on the healthy self-heal path.
b52b="$(mktemp -d "$TMPROOT/b52b.XXXX")"; new_repo_verify "$b52b" >/dev/null; setup_stubs "$b52b"
stage_ticket_suite "$b52b" red; advance_base "$b52b" clean
rc52b=0
run_in "$b52b" reconcile --mission "$MID" >"$b52b.aux/p1.txt" 2>&1 || rc52b=$?
s52b="$(state_of "$b52b")"
check "B52b. a SUCCESSFUL heal dispatch still returns 10 (reconciling halt)" \
  "[ '$rc52b' -eq 10 ]"
check "B52b. a SUCCESSFUL heal dispatch sets reconcileStatus=healing (unchanged behaviour)" \
  "grep -q '\"reconcileStatus\": *\"healing\"' '$s52b'"
check "B52b. a SUCCESSFUL heal dispatch does NOT raise an awaiting-human gate" \
  "! grep -q '\"awaitingHuman\": *true' '$s52b'"

# --- BUG-077: re-entry with an existing remote PR branch resets local to remote --
# A reconcile killed/parked and retried leaves the local mission branch DIVERGED
# from the last-pushed remote PR head. On re-entry, when a remote PR branch exists,
# the gate must reset the local branch to origin/<branch> BEFORE merging main again
# so the retry merges from the SAME base the remote has — and cannot diverge. After
# the reset+merge, the local-only dead-attempt commit must be gone, and the branch
# must descend from the remote head (origin/<branch> is an ancestor of the result).
b77="$(mktemp -d "$TMPROOT/b77.XXXX")"; new_repo_verify "$b77" >/dev/null; setup_stubs "$b77"
# this is the post-PR (approve merge-gate) re-entry context: a PR is already open.
sed 's#\("base": "[^"]*"\)#\1,\n  "prUrl": "https://github.com/acme/repo/pull/77",\n  "prNumber": 77#' \
  "$(state_of "$b77")" >"$b77.s.tmp" && mv "$b77.s.tmp" "$(state_of "$b77")"
stage_ticket_suite "$b77" green
diverge_local_branch "$b77"   # local tip now != origin/lcars/$MID (a dead attempt)
advance_base "$b77" clean      # main moves ahead → reconcile will run
# capture the remote head BEFORE the run so we can assert the local descends from it.
remote_head77="$(cd "$b77" && git rev-parse "origin/lcars/$MID")"
rc77=0; run_in "$b77" reconcile --mission "$MID" >"$b77.aux/out.txt" 2>&1 || rc77=$?
check "B77. re-entry resets local to remote head: the dead-attempt commit is GONE" \
  "! ( cd '$b77' && git log --oneline lcars/$MID | qgrep -q 'dead reconcile attempt' )"
check "B77. the reconciled branch DESCENDS from the remote PR head (no divergence)" \
  "( cd '$b77' && git merge-base --is-ancestor '$remote_head77' lcars/$MID )"
check "B77. the merge still happened (branch contains base's new commit)" \
  "( cd '$b77' && git log --oneline lcars/$MID ) | qgrep -q 'main moves ahead'"
check "B77. live tree stays clean" "[ -z \"\$(cd '$b77' && git status --porcelain)\" ]"
check "B77. no reconcile worktree leaks" "! (cd '$b77' && git worktree list | grep -q reconcile)"

# B77b (guard): a FIRST run with NO divergence (local == remote head) is UNCHANGED —
# the reset is a no-op when local already matches the remote, and the normal
# clean+green reconcile proceeds exactly as Behaviour 2/2r. Here there is no remote
# PR branch divergence; the gate must not disturb the branch beyond the merge.
b77b="$(mktemp -d "$TMPROOT/b77b.XXXX")"; new_repo_verify "$b77b" >/dev/null; setup_stubs "$b77b"
sed 's#\("base": "[^"]*"\)#\1,\n  "prUrl": "https://github.com/acme/repo/pull/77",\n  "prNumber": 77#' \
  "$(state_of "$b77b")" >"$b77b.s.tmp" && mv "$b77b.s.tmp" "$(state_of "$b77b")"
stage_ticket_suite "$b77b" green
advance_base "$b77b" clean
rc77b=0; run_in "$b77b" reconcile --mission "$MID" >"$b77b.aux/out.txt" 2>&1 || rc77b=$?
check "B77b. no-divergence re-entry still converges (awaiting-reapprove, exit 30)" \
  "[ '$rc77b' -eq 30 ]"
check "B77b. the merge still happened on a non-diverged branch" \
  "( cd '$b77b' && git log --oneline lcars/$MID ) | qgrep -q 'main moves ahead'"
check "B77b. live tree stays clean" "[ -z \"\$(cd '$b77b' && git status --porcelain)\" ]"

# ==========================================================================
echo
printf 'lcars reconcile: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
