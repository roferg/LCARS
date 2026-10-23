#!/usr/bin/env bash
#
# S231 — approve lands on its own: a folded bug mission's DECLARED test edits
# count at the pre-merge drift check, and a blocked reconcile never leaves a
# `reconcile.XXXXXX` worktree behind.
#
# THE WEEKEND BUG (canvas-weekend-2026-09-26/LCARS-BUG-fold-test-drift.md, three
# recurrences): a parent Mission at Verify owns test X. A bug filed with
# `lcars log --parent` legitimately adapts X and DECLARES it in its own
# tickets/<t>/test-edits.json. `resolve-logs` folds the fix onto the parent
# branch. Then `lcars approve` → reconcile → retest_ticket_suites →
# proof_drift_declared_ok, whose allow-list (`mission_declared_edit_paths`) globs
# only "$MISSION_DIR"/tickets/*/test-edits.json — the PARENT's tickets. The
# child's declaration lives in the CHILD's mission dir, so it is invisible and
# the merge dies with "PRE-MERGE UNDECLARED TEST DRIFT". Each of the three
# recurrences also left a stale reconcile.XXXXXX worktree holding the mission
# branch, because the drift `die` is the ONE exit path reconcile_cleanup is not
# on.
#
# THE SHAPE OF THE FIX (what this file proves):
#   1. fold_one_child RECORDS the fold on the child: foldedInto / foldedAt /
#      foldCommit. Record, never infer (ORCHESTRATION.md § infer-vs-record).
#   2. mission_declared_edit_paths unions the parent's declared paths with every
#      FOLDED child's, gated on foldCommit being an ancestor of the branch tip.
#   3. reconcile_ordered_tickets appends folded children's proven tickets, so a
#      test only the child owns is re-run too — through the SAME shared helper
#      (retest_ticket_suites), never a parallel path (BUG-013's lesson).
#   4. Every exit path of reconcile_gate frees its worktree, the drift die
#      included. The refusal's detection and severity are unchanged, character
#      for character (S311 rewrote only its closing cure sentence).
#   5. A legacy child filed before the record existed still merges, via ONE
#      ancestry fallback that is LOGGED in the mission's events.
#
# WHAT MUST NOT CHANGE, and is asserted here as a negative:
#   • an UNDECLARED test edit still BLOCKS, with the same SEVERITY words
#     (S156/S157). S311 changed the closing CURE sentence and only that; see
#     the DRIFT_SEVERITY / DRIFT_CURE comment below.
#   • a child that is NOT folded does not get a vote (its declaration counts
#     only once the fold is recorded).
#
# NOT in tests/lcars-reconcile.test.sh on purpose: tests/harness.test.sh's header
# names `lcars-reconcile` as a suite that HANGS idle even with stdin closed
# (S208/S209 ledger). This file is standalone and caged:
#
#   python3 tests/lib/cage.py 300 bash tests/approve-lands.test.sh
#
# Everything but git is stubbed — no network, no gh, no worker, no tokens.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
RESOLVE_SH="$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

PID="lcars-20260930-001"      # the parent Mission
CID="lcars-20260930-002"      # the logged bug folded into it
CID2="lcars-20260930-003"     # a second logged bug (two-children case)
PBRANCH="lcars/$PID"

# The EXACT refusal the weekend saw. Character-for-character: the fix must not
# reword it.
#
# S311 SPLIT THIS PIN IN TWO, DELIBERATELY. What this suite is really guarding
# is that an undeclared test edit still BLOCKS, with undiminished severity --
# and DRIFT_SEVERITY below pins exactly that, character for character, as it
# always did. What it was ALSO pinning by accident was the old closing sentence
# "Restore the test or re-open the ticket", which named a verb that does not
# exist: there is no `lcars reopen`, so an unattended seat could only revert a
# correct adaptation or stop, and one real mission sat BLOCKED for 4h49m on it.
# S311 is chartered to change what the gates SAY (never what they refuse), so
# that sentence is now the runnable command instead, and DRIFT_CURE pins the
# command. The severity pin is UNCHANGED and is the one that matters.
DRIFT_WORDS='PRE-MERGE UNDECLARED TEST DRIFT'
DRIFT_SEVERITY='BLOCKED: the Mission cannot merge an undeclared test edit, and this is NOT a self-healable regression.'
DRIFT_CURE='implement-ticket --mission'

mdir_of() { echo "$1/.git/lcars/missions/$PID"; }
cdir_of() { echo "$1/.git/lcars/missions/${2:-$CID}"; }
aux_of()  { echo "$1.aux"; }

# --- stubs (the forge and both CLIs; no worker may run) ---------------------
setup_stubs() { # repo
  local repo="$1" a; a="$(aux_of "$repo")"; mkdir -p "$a"
  cat >"$a/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/99"
fi
exit 0
EOF
  cat >"$a/notify" <<'EOF'
#!/usr/bin/env bash
echo "NOTIFY $1 $2" >>"$NOTIFY_LOG"
exit 0
EOF
  cat >"$a/worker" <<'EOF'
#!/usr/bin/env bash
echo "WORKER ${LCARS_WORKER_ROLE:-?} $*" >>"$WORKER_LOG"
exit 0
EOF
  cat >"$a/log.sh" <<'EOF'
#!/usr/bin/env bash
echo "LOG $*" >>"$LOG_LOG"
exit 0
EOF
  cat >"$a/run" <<'EOF'
#!/usr/bin/env bash
echo "RUN $*" >>"$LOG_LOG"
exit 0
EOF
  chmod +x "$a/gh" "$a/notify" "$a/worker" "$a/log.sh" "$a/run"
  : >"$a/gh.log"; : >"$a/notify.log"; : >"$a/worker.log"; : >"$a/log.log"
  : >"$a/testx.runs"; : >"$a/testy.runs"
}

run_in() { # repo  run.sh-args…
  local repo="$1"; shift
  local a; a="$(aux_of "$repo")"
  ( cd "$repo" \
      && LCARS_GH_BIN="$a/gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" \
         LCARS_LOG_SCRIPT="$a/log.sh" \
         LCARS_RESOLVE_LOGS_SCRIPT="$a/run" \
         LCARS_WORKER_BIN="$a/worker" LCARS_WORKER_CLI="claude" \
         LCARS_WORKER_ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh" \
         LCARS_NOTIFY="$a/notify" NOTIFY_LOG="$a/notify.log" \
         GH_LOG="$a/gh.log" LOG_LOG="$a/log.log" WORKER_LOG="$a/worker.log" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RUN_SH" "$@" )
}

fold_in() { # repo — the REAL resolve-logs fold of every verified child
  local repo="$1" a; a="$(aux_of "$repo")"
  ( cd "$repo" \
      && LCARS_GH_BIN="$a/gh" LCARS_GIT_BIN="$(command -v git)" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" \
         LCARS_NOTIFY="$a/notify" NOTIFY_LOG="$a/notify.log" GH_LOG="$a/gh.log" \
         LCARS_RUN_SCRIPT="$a/run" LCARS_WORKER_BIN="$a/worker" \
         WORKER_LOG="$a/worker.log" LOG_LOG="$a/log.log" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RESOLVE_SH" complete --parent "$PID" )
}

sha_of_file() { shasum -a 256 "$1" | awk '{print $1}'; }

# ===========================================================================
# THE FIXTURE — a real repo, a real bare remote, real commits, real worktrees.
# Nothing about the mission tree that the drift check reads is faked: the
# parent's proof snapshot is taken from the real committed blob, the child's fix
# is a real commit on the parent branch, and the fold is driven by the real
# resolve-logs verb.
# ===========================================================================
#
# $1 repo   $2 declare-mode: declared | undeclared
# $3 (opt)  second-child mode: "" | two   (a second bug declaring a SECOND test)
new_fixture() { # → echoes the base branch name
  local repo="$1" mode="$2" two="${3:-}"
  local a; a="$(aux_of "$repo")"

  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'orig\n' >shared.txt && git add -A && git commit -q -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"

  # The PARENT's ticket t-001 creates and OWNS tests/test_x.sh.
  ( cd "$repo" && git checkout -q -b "$PBRANCH" \
      && mkdir -p tests \
      && printf '#!/usr/bin/env bash\necho run >>"%s/testx.runs"\nexit 0\n' "$a" >tests/test_x.sh \
      && chmod +x tests/test_x.sh \
      && git add -A && git commit -q -m "lcars($PID) t-001: own test_x" )

  local m; m="$(mdir_of "$repo")"; mkdir -p "$m/tickets/t-001"
  cat >"$m/prd.md" <<'EOF'
# Mission: Publish discussions
**Goal:** Publish a discussion thread per page.
EOF
  cat >"$m/state.json" <<EOF
{
  "id": "$PID",
  "type": "feature",
  "title": "Publish discussions",
  "stage": "verify",
  "created": "2026-09-30T10:00:00Z",
  "githubIssue": 42,
  "workerBin": "$a/worker",
  "branch": "$PBRANCH",
  "base": "$base"
}
EOF
  cat >"$m/approved-plan.json" <<'EOF'
[ { "id": "t-001", "title": "Own test_x" } ]
EOF
  # The canonical MULTI-LINE waves.json shape Schedule emits (a single-line array
  # parses to an EMPTY ordered set, which would SKIP the retest — a false green).
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
  echo '{ "passed": true, "attempts": 1 }' >"$m/tickets/t-001/result.json"
  # PROOF-TIME snapshot of the parent's owned test — taken from the real blob,
  # BEFORE the child adapts it. This is the baseline the drift check compares to.
  printf '%s  %s\n' "$(sha_of_file "$repo/tests/test_x.sh")" "tests/test_x.sh" \
    >"$m/tickets/t-001/proof-tests.sha256"

  # The testCommand runs whatever suite file(s) the retest stages/scopes.
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "testCommand": "if [ -f \"$LCARS_TESTS_DIR\" ]; then bash \"$LCARS_TESTS_DIR\"; else for f in \"$LCARS_TESTS_DIR\"/*.sh; do [ -f \"$f\" ] && bash \"$f\" || exit 1; done; fi" }
EOF

  # --- the logged bug: a REAL commit on the PARENT branch adapting test_x ----
  ( cd "$repo" && git checkout -q "$PBRANCH" \
      && printf '#!/usr/bin/env bash\necho run >>"%s/testx.runs"\n# adapted by the logged bug\nexit 0\n' "$a" >tests/test_x.sh \
      && git add -A && git commit -q -m "lcars($CID) t-001: adapt test_x for the discussions fixture" )

  local c; c="$(cdir_of "$repo" "$CID")"; mkdir -p "$c/tickets/t-001"
  cat >"$c/state.json" <<EOF
{
  "id": "$CID",
  "type": "bug",
  "title": "publish stops when the Artifacts category is missing",
  "stage": "verify",
  "created": "2026-09-30T11:00:00Z",
  "githubIssue": 51,
  "parentMission": "$PID",
  "parentIssue": 42,
  "branch": "$PBRANCH",
  "base": "$PBRANCH"
}
EOF
  echo '{ "passed": true, "attempts": 1 }' >"$c/tickets/t-001/result.json"
  ( cd "$repo" && git rev-parse HEAD ) >"$c/tickets/t-001/.commit-sha"
  # The child's OWN proof snapshot: the POST-edit blob (it proved against its own
  # adaptation), so the child's ticket shows no drift of its own.
  printf '%s  %s\n' "$(sha_of_file "$repo/tests/test_x.sh")" "tests/test_x.sh" \
    >"$c/tickets/t-001/proof-tests.sha256"
  if [ "$mode" = declared ]; then
    cat >"$c/tickets/t-001/test-edits.json" <<'EOF'
[
  { "path": "tests/test_x.sh",
    "reason": "Added the encode_discussion_response helper + DEFAULT_CATEGORIES fixture the fix needs." }
]
EOF
  fi

  # --- optional SECOND logged bug, owning a test of its OWN ------------------
  if [ "$two" = two ]; then
    ( cd "$repo" && git checkout -q "$PBRANCH" \
        && printf '#!/usr/bin/env bash\necho run >>"%s/testy.runs"\nexit 0\n' "$a" >tests/test_y.sh \
        && chmod +x tests/test_y.sh \
        && git add -A && git commit -q -m "lcars($CID2) t-001: a second logged bug's own test_y" )
    local c2; c2="$(cdir_of "$repo" "$CID2")"; mkdir -p "$c2/tickets/t-001"
    cat >"$c2/state.json" <<EOF
{
  "id": "$CID2",
  "type": "bug",
  "title": "the second logged bug",
  "stage": "verify",
  "created": "2026-09-30T11:30:00Z",
  "githubIssue": 52,
  "parentMission": "$PID",
  "parentIssue": 42,
  "branch": "$PBRANCH",
  "base": "$PBRANCH"
}
EOF
    echo '{ "passed": true, "attempts": 1 }' >"$c2/tickets/t-001/result.json"
    ( cd "$repo" && git rev-parse HEAD ) >"$c2/tickets/t-001/.commit-sha"
    printf '%s  %s\n' "$(sha_of_file "$repo/tests/test_y.sh")" "tests/test_y.sh" \
      >"$c2/tickets/t-001/proof-tests.sha256"
    cat >"$c2/tickets/t-001/test-edits.json" <<'EOF'
[ { "path": "tests/test_y.sh", "reason": "This bug's own regression test." } ]
EOF
  fi

  ( cd "$repo" && git checkout -q "$base" )
  git init -q --bare "$repo.remote.git"
  ( cd "$repo" && git remote add origin "$repo.remote.git" \
      && git push -q origin "$base" "$PBRANCH" )
  echo "$base"
}

# Move base AHEAD by a clean commit so the mission branch is behind → reconcile
# engages (a not-ahead branch returns 0 before the worktree is even cut).
advance_base() { # repo
  local repo="$1" base
  base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q "$base" \
      && printf 'newbase\n' >base-only.txt && git add -A && git commit -q -m "main moves ahead" \
      && git push -q origin "$base" )
}

new_repo() { mktemp -d "$TMPROOT/$1.XXXX"; }
runs_of()  { [ -f "$1" ] && grep -c . "$1" 2>/dev/null || echo 0; }

echo "S231 approve-lands — folded children's declared edits + reconcile cleanup"
echo

# ===========================================================================
# BEHAVIOUR 1 — a successful fold RECORDS itself on the child.
# Record, don't infer: the drift check must read a fact the producer wrote, not
# reconstruct which child folded by parsing git log.
# ===========================================================================
r1="$(new_repo b1)"; new_fixture "$r1" declared >/dev/null; setup_stubs "$r1"
fold_in "$r1" >"$(aux_of "$r1")/fold.txt" 2>&1; fold_rc1=$?
cs1="$(cdir_of "$r1" "$CID")/state.json"
check "1a. the real fold succeeded" "[ '$fold_rc1' -eq 0 ]"
check "1b. the child reached done" "grep -q '\"stage\": *\"done\"' '$cs1'"
check "1c. the fold RECORDED foldedInto = the parent mission id" \
  "grep -q '\"foldedInto\": *\"$PID\"' '$cs1'"
check "1d. the fold RECORDED foldedAt (an ISO timestamp)" \
  "grep -qE '\"foldedAt\": *\"[0-9]{4}-[0-9]{2}-[0-9]{2}T' '$cs1'"
check "1e. the fold RECORDED foldCommit (a 40-hex sha)" \
  "grep -qE '\"foldCommit\": *\"[0-9a-f]{40}\"' '$cs1'"
FC1="$(sed -n 's/.*"foldCommit"[[:space:]]*:[[:space:]]*"\([0-9a-f]*\)".*/\1/p' "$cs1" | head -1)"
check "1f. foldCommit is the child's fix tip ON the parent branch (an ancestor of it)" \
  "[ -n '$FC1' ] && (cd '$r1' && git merge-base --is-ancestor '$FC1' '$PBRANCH')"
check "1g. the recorded child state.json is still valid JSON" \
  "python3 -c \"import json,sys; json.load(open('$cs1'))\""
check "1h. the fold record did not become a second way to write state" \
  "grep -q '\"parentMission\": *\"$PID\"' '$cs1'"

echo

# ===========================================================================
# BEHAVIOUR 2 — THE WEEKEND BUG. A folded child's DECLARED edit of a
# parent-owned test lets the reconcile through, and that test's suite is re-run
# (once — a child ticket whose recorded tests are already covered must not
# double-run the same suite).
# ===========================================================================
r2="$(new_repo b2)"; new_fixture "$r2" declared >/dev/null; setup_stubs "$r2"
fold_in "$r2" >"$(aux_of "$r2")/fold.txt" 2>&1 || true
advance_base "$r2"
: >"$(aux_of "$r2")/testx.runs"
rc2=0; run_in "$r2" reconcile --mission "$PID" >"$(aux_of "$r2")/out.txt" 2>&1 || rc2=$?
m2="$(mdir_of "$r2")"
check "2a. the reconcile does NOT die on drift (rc 0 = merged, green, proceed)" \
  "[ '$rc2' -eq 0 ]"
check "2b. and it never printed the undeclared-drift refusal" \
  "! grep -q '$DRIFT_WORDS' '$(aux_of "$r2")/out.txt'"
check "2c. no tamper event was emitted against the parent" \
  "! grep -q 'ticket_locked_test_tampered' '$m2/events.jsonl'"
check "2d. the retest RAN the adapted test_x suite" \
  "[ \"\$(runs_of '$(aux_of "$r2")/testx.runs')\" -ge 1 ]"
check "2e. and ran it exactly ONCE (the child ticket does not double-run a covered suite)" \
  "[ \"\$(runs_of '$(aux_of "$r2")/testx.runs')\" -eq 1 ]"
check "2f. the merge was KEPT on the branch (green reconcile)" \
  "grep -q 'main moves ahead' <<<\"\$(cd '$r2' && git log --oneline $PBRANCH)\""
check "2g. no reconcile worktree left behind" \
  "! (cd '$r2' && git worktree list) | grep -q reconcile"
check "2h. no worker was spawned by the reconcile" \
  "! grep -q '^WORKER' '$(aux_of "$r2")/worker.log'"

echo

# ===========================================================================
# BEHAVIOUR 3 — THE NEGATIVE THAT MUST NOT BEND. Same shape, but the child
# declared NOTHING. S156/S157: an undeclared test edit BLOCKS LOUD, in the same
# words. Making the check pass "whenever the mission has children" is the wrong
# answer this case exists to catch.
# ===========================================================================
r3="$(new_repo b3)"; new_fixture "$r3" undeclared >/dev/null; setup_stubs "$r3"
fold_in "$r3" >"$(aux_of "$r3")/fold.txt" 2>&1 || true
advance_base "$r3"
rc3=0; run_in "$r3" reconcile --mission "$PID" >"$(aux_of "$r3")/out.txt" 2>&1 || rc3=$?
m3="$(mdir_of "$r3")"
check "3a. an UNDECLARED edit by a folded child STILL blocks (non-zero)" \
  "[ '$rc3' -ne 0 ]"
check "3b. the refusal headline is unchanged" \
  "grep -qF '$DRIFT_WORDS' '$(aux_of "$r3")/out.txt'"
check "3c. the refusal's SEVERITY is unchanged, character for character" \
  "grep -qF '$DRIFT_SEVERITY' '$(aux_of "$r3")/out.txt'"
check "3c2. and it closes on a RUNNABLE re-open command, not the absent 'lcars reopen'" \
  "grep -qF '$DRIFT_CURE' '$(aux_of "$r3")/out.txt' \
     && ! grep -qF 'Restore the test or re-open the ticket.' '$(aux_of "$r3")/out.txt'"
check "3d. it names the drifted path and the owning ticket" \
  "grep -q \"ticket t-001's COMMITTED test file\" '$(aux_of "$r3")/out.txt' \
     && grep -q 'tests/test_x.sh' '$(aux_of "$r3")/out.txt'"
check "3e. the tamper event is still emitted" \
  "grep -q 'ticket_locked_test_tampered' '$m3/events.jsonl'"

echo

# ===========================================================================
# BEHAVIOUR 4 — a child that was FILED but NOT FOLDED does not get a vote. Its
# declaration counts only once the fold is recorded; otherwise a bug still at
# `plan` could pre-authorise an edit nobody has accepted.
# ===========================================================================
r4="$(new_repo b4)"; new_fixture "$r4" declared >/dev/null; setup_stubs "$r4"
# Put the child back at `plan` — filed, declaring, NOT folded. No fold is run.
python3 - "$(cdir_of "$r4" "$CID")/state.json" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(re.sub(r'"stage": *"verify"', '"stage": "plan"', s))
PY
advance_base "$r4"
rc4=0; run_in "$r4" reconcile --mission "$PID" >"$(aux_of "$r4")/out.txt" 2>&1 || rc4=$?
c4="$(cdir_of "$r4" "$CID")/state.json"
check "4a. precondition: the child has NO fold record" \
  "! grep -q 'foldedInto' '$c4'"
check "4b. an UNFOLDED child's declaration does NOT count — still blocks" \
  "[ '$rc4' -ne 0 ]"
check "4c. with the same refusal words" \
  "grep -qF '$DRIFT_WORDS' '$(aux_of "$r4")/out.txt'"

echo

# ===========================================================================
# BEHAVIOUR 5 — after ANY blocked reconcile the worktree is gone and the mission
# branch is free. Each of the three weekend recurrences left a
# reconcile.XXXXXX holding the branch with a half-done merge, and the next
# `worktree add` of that branch failed until it was removed by hand.
# ===========================================================================
for b5 in r3 r4; do
  eval "R5=\$$b5"
  check "5a[$b5]. no reconcile.XXXXXX worktree survives the refusal" \
    "! (cd '$R5' && git worktree list) | grep -q reconcile"
  check "5b[$b5]. no reconcile.XXXXXX directory survives on disk" \
    "! ls -d '$R5'/.git/lcars/missions/$PID/reconcile.* >/dev/null 2>&1"
  check "5c[$b5]. the mission branch is FREE to worktree add again" \
    "(cd '$R5' && git worktree add -q '$TMPROOT/probe-$b5' '$PBRANCH' >/dev/null 2>&1 \
       && git worktree remove --force '$TMPROOT/probe-$b5' >/dev/null 2>&1)"
  check "5d[$b5]. the captain's live tree is still clean" \
    "[ -z \"\$(cd '$R5' && git status --porcelain)\" ]"
done

echo

# ===========================================================================
# BEHAVIOUR 6 — a LEGACY child (filed before the record existed) whose fix
# commits ARE ancestors of the parent tip is treated as folded, so the weekend's
# already-filed missions still merge. ONE fallback, and it is LOGGED as such in
# the mission's events — an inference the next reader can see.
# ===========================================================================
r6="$(new_repo b6)"; new_fixture "$r6" declared >/dev/null; setup_stubs "$r6"
fold_in "$r6" >"$(aux_of "$r6")/fold.txt" 2>&1 || true
# Strip the record — this is exactly a weekend child: done, linked by
# parentMission, its fix on the branch, and no foldedInto anywhere.
python3 - "$(cdir_of "$r6" "$CID")/state.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
for k in ("foldedInto","foldedAt","foldCommit"): d.pop(k, None)
open(p,'w').write(json.dumps(d, indent=2) + "\n")
PY
advance_base "$r6"
: >"$(aux_of "$r6")/testx.runs"
rc6=0; run_in "$r6" reconcile --mission "$PID" >"$(aux_of "$r6")/out.txt" 2>&1 || rc6=$?
m6="$(mdir_of "$r6")"
check "6a. precondition: the legacy child carries NO fold record" \
  "! grep -q 'foldedInto' '$(cdir_of "$r6" "$CID")/state.json'"
check "6b. the legacy child's declaration still counts (the merge is not blocked)" \
  "[ '$rc6' -eq 0 ]"
check "6c. and the refusal was never printed" \
  "! grep -q '$DRIFT_WORDS' '$(aux_of "$r6")/out.txt'"
check "6d. the FALLBACK IS LOGGED in the mission's events" \
  "grep -q 'fold_record_absent' '$m6/events.jsonl'"
check "6e. the logged event names the child it inferred" \
  "grep 'fold_record_absent' '$m6/events.jsonl' | grep -q '$CID'"
check "6f. the event says plainly that this was INFERRED from ancestry" \
  "grep 'fold_record_absent' '$m6/events.jsonl' | grep -qi 'ancestor'"

echo

# ===========================================================================
# BEHAVIOUR 7 (the round's real shape, not a listed behaviour) — TWO folded
# children, each declaring a DIFFERENT test, and the second child owns a test no
# parent ticket covers. It must be RE-RUN through the SAME shared helper, so the
# pre-merge retest actually covers what the children changed.
# ===========================================================================
r7="$(new_repo b7)"; new_fixture "$r7" declared two >/dev/null; setup_stubs "$r7"
fold_in "$r7" >"$(aux_of "$r7")/fold.txt" 2>&1 || true
advance_base "$r7"
: >"$(aux_of "$r7")/testx.runs"; : >"$(aux_of "$r7")/testy.runs"
rc7=0; run_in "$r7" reconcile --mission "$PID" >"$(aux_of "$r7")/out.txt" 2>&1 || rc7=$?
check "7a. two folded children, both declaring, both fold-recorded" \
  "grep -q foldedInto '$(cdir_of "$r7" "$CID")/state.json' \
     && grep -q foldedInto '$(cdir_of "$r7" "$CID2")/state.json'"
check "7b. the reconcile passes" "[ '$rc7' -eq 0 ]"
check "7c. the parent-owned test_x was re-run" \
  "[ \"\$(runs_of '$(aux_of "$r7")/testy.runs')\" -ge 0 ] && [ \"\$(runs_of '$(aux_of "$r7")/testx.runs')\" -ge 1 ]"
check "7d. the CHILD-owned test_y — which no parent ticket covers — was re-run too" \
  "[ \"\$(runs_of '$(aux_of "$r7")/testy.runs')\" -ge 1 ]"
check "7e. no reconcile worktree left behind" \
  "! (cd '$r7' && git worktree list) | grep -q reconcile"

echo

# ===========================================================================
# BEHAVIOUR 8 — the S97 rc-20 ENV-ESCALATE arm is untouched. A retest that goes
# red because the runner could not START is an environment fault, not a merge
# conflict: it undoes the merge, cleans up, and returns 20. A cleanup trap that
# also fires there must neither double-clean nor change that code.
# ===========================================================================
r8="$(new_repo b8)"; base8="$(new_fixture "$r8" declared)"; setup_stubs "$r8"
fold_in "$r8" >"$(aux_of "$r8")/fold.txt" 2>&1 || true
# Make the runner fail to START (the S97 demo signatures) on the parent branch.
( cd "$r8" && git checkout -q "$PBRANCH" \
    && printf '#!/usr/bin/env bash\necho "cd: packages/editor: No such file or directory" >&2\necho "vitest: not found" >&2\nexit 1\n' >tests/test_x.sh \
    && git add -A && git commit -q -m "lcars($CID) t-001: runner cannot start" \
    && git push -qf origin "$PBRANCH" && git checkout -q "$base8" )
# Re-snapshot BOTH declarations onto the new blob so this case tests the ENV arm
# and not the drift arm.
h8="$(cd "$r8" && git show "$PBRANCH:tests/test_x.sh" | shasum -a 256 | awk '{print $1}')"
printf '%s  %s\n' "$h8" "tests/test_x.sh" >"$(mdir_of "$r8")/tickets/t-001/proof-tests.sha256"
printf '%s  %s\n' "$h8" "tests/test_x.sh" >"$(cdir_of "$r8" "$CID")/tickets/t-001/proof-tests.sha256"
advance_base "$r8"
rc8=0; run_in "$r8" reconcile --mission "$PID" >"$(aux_of "$r8")/out.txt" 2>&1 || rc8=$?
s8="$(mdir_of "$r8")/state.json"
check "8a. the env-fault arm still returns 20 (unchanged)" "[ '$rc8' -eq 20 ]"
check "8b. reconcileStatus is still env-blocked" \
  "grep -q '\"reconcileStatus\": *\"env-blocked\"' '$s8'"
check "8c. it still undid the merge (the branch is still behind base)" \
  "[ \"\$(cd '$r8' && git rev-list --count $PBRANCH..refs/remotes/origin/$base8 2>/dev/null)\" -ge 1 ]"
check "8d. it still cleaned up its worktree — exactly once, no leak" \
  "! (cd '$r8' && git worktree list) | grep -q reconcile"
check "8e. and never reached the self-heal author" \
  "! grep -q '^WORKER' '$(aux_of "$r8")/worker.log'"

echo
printf 'approve-lands: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
