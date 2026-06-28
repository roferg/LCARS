#!/usr/bin/env bash
#
# Tests for `lcars resolve-logs <parent>` (source: skills/lcars-resolve-logs/resolve-logs.sh).
#
# resolve-logs is an ORCHESTRATION verb: it adds no new stage logic. Given a
# parent Mission that has N linked bug Missions (filed via `lcars log`), it
#   1. GATHERs the open linked bugs into a work set,
#   2. ORDERs them (the LLM half — the worker chooses; absent a choice it falls
#      back to filed order; rationale is recorded),
#   3. DRIVEs each one to its Verify gate by delegating to the EXISTING
#      `lcars run` driver ($LCARS_RUN_SCRIPT) — never reimplementing stages,
#   4. then raises EXACTLY ONE consolidated re-verify human gate + ONE notify
#      on the PARENT (not N).
#
# All external deps are env-injected so we can stub them:
#   LCARS_GH_BIN     the gh binary
#   LCARS_GIT_BIN    the git binary
#   LCARS_WORKER_BIN the ordering worker
#   LCARS_NOTIFY     the notify hook
#   LCARS_RUN_SCRIPT the `lcars run` driver (stubbed to simulate stage outcomes)
#
# Usage: bash tests/lcars-resolve-logs.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# drain-then-grep: under `set -o pipefail`, piping a producer into `grep -q`
# SIGPIPEs the producer and yields phantom failures. qgrep reads the whole file
# first, then greps the drained copy — never pipes into grep -q.
qgrep() {
  if [ "$1" = "-i" ]; then grep -Ei "$2" "$3" >/dev/null 2>&1
  else grep -E "$1" "$2" >/dev/null 2>&1; fi
}

# --- stubs ----------------------------------------------------------------
# gh stub: record calls, mint climbing issue numbers on `issue create`.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  n_file="${GH_LOG}.n"; n="$(cat "$n_file" 2>/dev/null || echo 44)"; n=$((n + 1))
  echo "$n" >"$n_file"; echo "https://github.com/owner/repo/issues/$n"
fi
exit 0
EOF
  chmod +x "$1"
}

# notify stub: append one line per invocation so we can count gates.
make_notify_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "notify mission=$1 gate=$2 summary=$3" >>"$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$1"
}

# worker stub: prints a fixed resolution order (+ rationale) for the bug ids.
# It writes the ORDER env so the test controls which ids come back in what order.
make_worker_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
# Emit the test-chosen order, one "<id>: <rationale>" line each.
for id in $WORKER_ORDER; do
  echo "$id: chosen because of dependency analysis"
done
exit 0
EOF
  chmod +x "$1"
}

# A worker stub that prints nothing (no choice) — exercises the filed-order fallback.
make_silent_worker_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$1"
}

# run.sh DRIVE stub. Simulates driving one mission to its Verify gate. For ids
# listed in $ESCALATE_IDS it instead parks the mission at awaiting-human (sets
# awaitingHuman + writes pending.json), the way a real escalation does.
make_run_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
# args: drive --mission <id>
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="$2"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
echo "run drive $mid" >>"$RUN_LOG"
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
sdir="$gitdir/lcars/missions/$mid"
state="$sdir/state.json"
escalate=0
for e in $ESCALATE_IDS; do [ "$e" = "$mid" ] && escalate=1; done
errored=0
for e in $ERROR_IDS; do [ "$e" = "$mid" ] && errored=1; done
if [ "$errored" -eq 1 ]; then
  # Silent failure to advance: the child does NOT reach Verify and does NOT park
  # at awaiting-human — it is left mid-flight at implement (BUG-064 scenario:
  # "driving <bug> did not reach its Verify gate (stage is now 'implement')").
  tmp="$(mktemp)"
  awk 'NR==1{print; print "  \"stage\": \"implement\","; next} /"stage"|"awaitingHuman"|"pendingQuestion"/{next} {print}' "$state" >"$tmp" && mv "$tmp" "$state"
  rm -f "$sdir/pending.json"
elif [ "$escalate" -eq 1 ]; then
  tmp="$(mktemp)"
  grep -v '"stage"\|"awaitingHuman"\|"pendingQuestion"' "$state" \
    | sed '1!b; /{/!b' >/dev/null 2>&1
  # rewrite stage->implement, add awaitingHuman + pendingQuestion
  awk 'NR==1{print; print "  \"stage\": \"implement\","; print "  \"awaitingHuman\": true,"; print "  \"pendingQuestion\": \"Ticket T1 failed after 5 attempts — needs a human.\","; next} /"stage"|"awaitingHuman"|"pendingQuestion"/{next} {print}' "$state" >"$tmp" && mv "$tmp" "$state"
  cat >"$sdir/pending.json" <<PJ
{
  "stage": "implement",
  "questions": [
    "Ticket T1 failed after 5 attempts — needs a human."
  ]
}
PJ
else
  tmp="$(mktemp)"
  awk 'NR==1{print; print "  \"stage\": \"verify\","; next} /"stage"/{next} {print}' "$state" >"$tmp" && mv "$tmp" "$state"
fi
exit 0
EOF
  chmod +x "$1"
}

# Build a repo with a parent Mission + N linked bug missions (all at stage plan).
# $1 repo path (created), $2 number of bugs.
new_repo_with_linked_bugs() {
  local repo n; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"; n="$1"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "model": "claude-sonnet", "projectName": "repo" }
EOF
  local p="$repo/.git/lcars/missions/lcars-20260601-001"
  mkdir -p "$p"
  cat >"$p/state.json" <<'EOF'
{
  "id": "lcars-20260601-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "verify",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260601-001",
  "base": "main"
}
EOF
  local i seq d
  for i in $(seq 1 "$n" 2>/dev/null); do
    [ "$i" -ge 1 ] && [ "$i" -le "$n" ] || continue
    seq="$(printf '%03d' "$((i + 1))")"
    d="$repo/.git/lcars/missions/lcars-20260601-$seq"
    mkdir -p "$d"
    cat >"$d/state.json" <<EOF
{
  "id": "lcars-20260601-$seq",
  "type": "bug",
  "title": "Logged bug number $i",
  "stage": "plan",
  "githubIssue": $((50 + i)),
  "parentMission": "lcars-20260601-001",
  "parentIssue": 42,
  "branch": "lcars/lcars-20260601-$seq",
  "base": "main"
}
EOF
  done
  echo "$repo"
}

PARENT="lcars-20260601-001"

# ==========================================================================
echo "lcars resolve-logs"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: 3 linked bugs -> all driven, ONE consolidated gate + notify
repo="$(new_repo_with_linked_bugs 3)"
make_gh_stub "$repo/gh"; make_notify_stub "$repo/notify"; make_run_stub "$repo/run"; make_worker_stub "$repo/worker"
export GH_LOG="$repo/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo/run.log"; : >"$RUN_LOG"
rc=0
(
  cd "$repo"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002 lcars-20260601-003 lcars-20260601-004" \
  LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo/notify" \
  LCARS_RUN_SCRIPT="$repo/run" LCARS_WORKER_BIN="$repo/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out.txt 2>&1
) || rc=$?
check "1. exits zero driving 3 bugs to verify" "[ '$rc' -eq 0 ]"
check "1. drives all three bug missions via the run driver" \
  "[ \"\$(grep -c 'run drive' '$RUN_LOG')\" -eq 3 ]"
check "1. each bug reached its Verify gate" \
  "qgrep '\"stage\": *\"verify\"' '$repo/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"verify\"' '$repo/.git/lcars/missions/lcars-20260601-004/state.json'"
check "1. fires EXACTLY ONE notification (not three)" \
  "[ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ]"
check "1. the single notify is on the PARENT mission" \
  "qgrep 'mission=lcars-20260601-001' '$NOTIFY_LOG'"
check "1. raises ONE consolidated awaiting-human gate on the parent" \
  "qgrep '\"awaitingHuman\": *true' '$repo/.git/lcars/missions/lcars-20260601-001/state.json'"
check "1. parent gets a pending.json with the re-verify ask" \
  "[ -f '$repo/.git/lcars/missions/lcars-20260601-001/pending.json' ]"
check "1. parent pending mentions re-verify / N resolved bugs" \
  "qgrep -i 'verif' '$repo/.git/lcars/missions/lcars-20260601-001/pending.json'"
check "1. no per-bug consolidated gate (bugs not flagged awaiting-human)" \
  "! qgrep '\"awaitingHuman\": *true' '$repo/.git/lcars/missions/lcars-20260601-002/state.json'"

# --- Behaviour 2: ordering honoured; rationale recorded; filed-order fallback
repo2="$(new_repo_with_linked_bugs 3)"
make_gh_stub "$repo2/gh"; make_notify_stub "$repo2/notify"; make_run_stub "$repo2/run"; make_worker_stub "$repo2/worker"
export GH_LOG="$repo2/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo2/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo2/run.log"; : >"$RUN_LOG"
(
  cd "$repo2"
  # Worker chooses a NON-filed order: 004 first, then 002, then 003.
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-004 lcars-20260601-002 lcars-20260601-003" \
  LCARS_GH_BIN="$repo2/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo2/notify" \
  LCARS_RUN_SCRIPT="$repo2/run" LCARS_WORKER_BIN="$repo2/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out2.txt 2>&1
)
check "2. worker order is honoured (004 driven before 002)" \
  "[ \"\$(grep -n 'lcars-20260601-004' '$RUN_LOG' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'lcars-20260601-002' '$RUN_LOG' | head -1 | cut -d: -f1)\" ]"
check "2. a rationale is recorded for the chosen order" \
  "qgrep -i 'dependency analysis' '$repo2/.git/lcars/missions/lcars-20260601-001/resolve-logs.md'"

# filed-order fallback when the worker offers nothing
repo2b="$(new_repo_with_linked_bugs 3)"
make_gh_stub "$repo2b/gh"; make_notify_stub "$repo2b/notify"; make_run_stub "$repo2b/run"; make_silent_worker_stub "$repo2b/worker"
export GH_LOG="$repo2b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo2b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo2b/run.log"; : >"$RUN_LOG"
(
  cd "$repo2b"
  ESCALATE_IDS="" \
  LCARS_GH_BIN="$repo2b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo2b/notify" \
  LCARS_RUN_SCRIPT="$repo2b/run" LCARS_WORKER_BIN="$repo2b/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out2b.txt 2>&1
)
check "2. falls back to filed order when the worker offers nothing (002 first)" \
  "[ \"\$(head -1 '$RUN_LOG')\" = 'run drive lcars-20260601-002' ]"

# --- Behaviour 3: one bug escalates mid-batch -> pause, no consolidated gate
repo3="$(new_repo_with_linked_bugs 3)"
make_gh_stub "$repo3/gh"; make_notify_stub "$repo3/notify"; make_run_stub "$repo3/run"; make_worker_stub "$repo3/worker"
export GH_LOG="$repo3/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo3/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo3/run.log"; : >"$RUN_LOG"
rc3=0
(
  cd "$repo3"
  # Order 002, 003, 004; 003 escalates. 002 resolves first, batch pauses at 003.
  ESCALATE_IDS="lcars-20260601-003" WORKER_ORDER="lcars-20260601-002 lcars-20260601-003 lcars-20260601-004" \
  LCARS_GH_BIN="$repo3/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo3/notify" \
  LCARS_RUN_SCRIPT="$repo3/run" LCARS_WORKER_BIN="$repo3/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out3.txt 2>&1
) || rc3=$?
check "3. earlier bug (002) was resolved to verify before the pause" \
  "qgrep '\"stage\": *\"verify\"' '$repo3/.git/lcars/missions/lcars-20260601-002/state.json'"
check "3. the escalating bug (003) is parked at awaiting-human" \
  "qgrep '\"awaitingHuman\": *true' '$repo3/.git/lcars/missions/lcars-20260601-003/state.json'"
check "3. its question lands where the answer inbox reads it (pending.json)" \
  "[ -f '$repo3/.git/lcars/missions/lcars-20260601-003/pending.json' ]"
check "3. NO consolidated re-verify gate on the parent yet" \
  "! qgrep '\"awaitingHuman\": *true' '$repo3/.git/lcars/missions/lcars-20260601-001/state.json'"
check "3. NO consolidated notify fired" "[ ! -s '$repo3/notify.log' ]"
check "3. the bug AFTER the escalation (004) was NOT driven" \
  "! qgrep 'run drive lcars-20260601-004' '$RUN_LOG'"
check "3. already-resolved earlier bug (002) is not rolled back" \
  "qgrep '\"stage\": *\"verify\"' '$repo3/.git/lcars/missions/lcars-20260601-002/state.json'"

# resume: human answered 003 (cleared its gate) -> resolve-logs continues the rest
# simulate the answer by clearing 003's awaiting-human + restoring stage to plan
b3="$repo3/.git/lcars/missions/lcars-20260601-003/state.json"
awk '/"awaitingHuman"|"pendingQuestion"/{next} /"stage"/{print "  \"stage\": \"plan\","; next} {print}' "$b3" >"$b3.tmp" && mv "$b3.tmp" "$b3"
rm -f "$repo3/.git/lcars/missions/lcars-20260601-003/pending.json"
: >"$RUN_LOG"; : >"$NOTIFY_LOG"
rc3b=0
(
  cd "$repo3"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-003 lcars-20260601-004" \
  LCARS_GH_BIN="$repo3/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo3/notify" \
  LCARS_RUN_SCRIPT="$repo3/run" LCARS_WORKER_BIN="$repo3/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out3b.txt 2>&1
) || rc3b=$?
check "3. resumed run drives the remaining bugs (003 + 004)" \
  "qgrep 'run drive lcars-20260601-003' '$RUN_LOG' && qgrep 'run drive lcars-20260601-004' '$RUN_LOG'"
check "3. resumed run does NOT re-drive the already-verified 002" \
  "! qgrep 'run drive lcars-20260601-002' '$RUN_LOG'"
check "3. after resume, ONE consolidated gate + ONE notify on the parent" \
  "qgrep '\"awaitingHuman\": *true' '$repo3/.git/lcars/missions/lcars-20260601-001/state.json' && [ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ]"

# --- Behaviour 4: parent with zero linked open bugs -> clean no-op ----------
repo4="$(new_repo_with_linked_bugs 0)"
make_gh_stub "$repo4/gh"; make_notify_stub "$repo4/notify"; make_run_stub "$repo4/run"; make_worker_stub "$repo4/worker"
export NOTIFY_LOG="$repo4/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo4/run.log"; : >"$RUN_LOG"
rc4=0
(
  cd "$repo4"
  LCARS_GH_BIN="$repo4/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo4/notify" \
  LCARS_RUN_SCRIPT="$repo4/run" LCARS_WORKER_BIN="$repo4/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out4.txt 2>&1
) || rc4=$?
check "4. exits zero on a clean no-op" "[ '$rc4' -eq 0 ]"
check "4. drives nothing when there are no linked open bugs" "[ ! -s '$repo4/run.log' ]"
check "4. fires no notification on a no-op" "[ ! -s '$repo4/notify.log' ]"
check "4. raises no gate on the parent" \
  "! qgrep '\"awaitingHuman\": *true' '$repo4/.git/lcars/missions/lcars-20260601-001/state.json'"
check "4. says there is nothing to resolve" "qgrep -i 'no .*linked|nothing' '$repo4/out4.txt'"

# all linked bugs already done -> also a no-op
repo4b="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo4b/gh"; make_notify_stub "$repo4b/notify"; make_run_stub "$repo4b/run"; make_worker_stub "$repo4b/worker"
export NOTIFY_LOG="$repo4b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo4b/run.log"; : >"$RUN_LOG"
for seq in 002 003; do
  s="$repo4b/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "done"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
rc4b=0
(
  cd "$repo4b"
  LCARS_GH_BIN="$repo4b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo4b/notify" \
  LCARS_RUN_SCRIPT="$repo4b/run" LCARS_WORKER_BIN="$repo4b/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out4b.txt 2>&1
) || rc4b=$?
check "4. all-done linked bugs is also a clean no-op" \
  "[ '$rc4b' -eq 0 ] && [ ! -s '$repo4b/run.log' ] && [ ! -s '$repo4b/notify.log' ]"

# --- Behaviour 5: resolver UX (id / #issue / title; ambiguous/missing) ------
# resolve by GitHub issue number
repo5="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo5/gh"; make_notify_stub "$repo5/notify"; make_run_stub "$repo5/run"; make_worker_stub "$repo5/worker"
export NOTIFY_LOG="$repo5/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo5/run.log"; : >"$RUN_LOG"
rc5=0
(
  cd "$repo5"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002" \
  LCARS_GH_BIN="$repo5/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo5/notify" \
  LCARS_RUN_SCRIPT="$repo5/run" LCARS_WORKER_BIN="$repo5/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "#42" >out5.txt 2>&1
) || rc5=$?
check "5. resolves the parent by #issue number" \
  "[ '$rc5' -eq 0 ] && qgrep 'run drive lcars-20260601-002' '$repo5/run.log'"

# resolve by title substring
repo5b="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo5b/gh"; make_notify_stub "$repo5b/notify"; make_run_stub "$repo5b/run"; make_worker_stub "$repo5b/worker"
export NOTIFY_LOG="$repo5b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo5b/run.log"; : >"$RUN_LOG"
rc5b=0
(
  cd "$repo5b"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002" \
  LCARS_GH_BIN="$repo5b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo5b/notify" \
  LCARS_RUN_SCRIPT="$repo5b/run" LCARS_WORKER_BIN="$repo5b/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "gamification" >out5b.txt 2>&1
) || rc5b=$?
check "5. resolves the parent by title substring" "[ '$rc5b' -eq 0 ]"

# missing parent selector -> refuse + list candidates
repo5c="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo5c/gh"; make_notify_stub "$repo5c/notify"; make_run_stub "$repo5c/run"; make_worker_stub "$repo5c/worker"
export RUN_LOG="$repo5c/run.log"; : >"$RUN_LOG"
rc5c=0
(
  cd "$repo5c"
  LCARS_GH_BIN="$repo5c/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo5c/notify" \
  LCARS_RUN_SCRIPT="$repo5c/run" LCARS_WORKER_BIN="$repo5c/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" >out5c.txt 2>&1
) || rc5c=$?
check "5. refuses (non-zero) when no parent is given" "[ '$rc5c' -ne 0 ]"
check "5. lists the candidate parent mission" "qgrep 'lcars-20260601-001' '$repo5c/out5c.txt'"
check "5. drives nothing when the parent is unresolved" "[ ! -s '$repo5c/run.log' ]"

# no match -> refuse
repo5d="$(new_repo_with_linked_bugs 1)"
make_run_stub "$repo5d/run"; make_worker_stub "$repo5d/worker"; make_notify_stub "$repo5d/notify"
export RUN_LOG="$repo5d/run.log"; : >"$RUN_LOG"
rc5d=0
(
  cd "$repo5d"
  LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo5d/notify" \
  LCARS_RUN_SCRIPT="$repo5d/run" LCARS_WORKER_BIN="$repo5d/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "no-such-mission-xyz" >out5d.txt 2>&1
) || rc5d=$?
check "5. refuses when no active mission matches the selector" "[ '$rc5d' -ne 0 ]"

# --- Behaviour 7: complete folds children to Done, no per-bug PR (BUG-E) -----
# Model A: logged-bug fixes fold INTO the parent. Once the consolidated re-verify
# gate is ACCEPTED, every linked child bug at Verify transitions to Done WITHOUT
# its own PR (the parent's PR carries the merged fixes). `resolve-logs complete
# --parent <id>` performs that fold: clear stage labels, apply lcars:done, move
# to the done column, and NEVER call `gh pr create` for a child.
repo7c="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo7c/gh"; make_notify_stub "$repo7c/notify"; make_run_stub "$repo7c/run"; make_worker_stub "$repo7c/worker"
export GH_LOG="$repo7c/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo7c/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo7c/run.log"; : >"$RUN_LOG"
# put both children at verify (as if resolve-logs already drove them).
for seq in 002 003; do
  s="$repo7c/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
rc7c=0
(
  cd "$repo7c"
  LCARS_GH_BIN="$repo7c/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo7c/notify" \
  LCARS_RUN_SCRIPT="$repo7c/run" LCARS_WORKER_BIN="$repo7c/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out7c.txt 2>&1
) || rc7c=$?
check "7. complete exits zero" "[ '$rc7c' -eq 0 ]"
check "7. child 002 transitions to stage done" \
  "qgrep '\"stage\": *\"done\"' '$repo7c/.git/lcars/missions/lcars-20260601-002/state.json'"
check "7. child 003 transitions to stage done" \
  "qgrep '\"stage\": *\"done\"' '$repo7c/.git/lcars/missions/lcars-20260601-003/state.json'"
check "7. each child issue is relabelled lcars:done" \
  "[ \"\$(grep -c 'add-label.*lcars:done' '$repo7c/gh.log')\" -ge 2 ]"
check "7. each child's stage label (lcars:verify) is removed" \
  "qgrep 'remove-label.*lcars:verify' '$repo7c/gh.log'"
check "7. NO per-bug PR is opened (no gh pr create for children)" \
  "! qgrep 'pr create' '$repo7c/gh.log'"
check "7. complete reports how many children it folded to Done" \
  "qgrep -i 'done|folded|2' '$repo7c/out7c.txt'"

# children's commits target the PARENT branch (branch-folding) — log.sh already
# records the parent branch on a pre-merge child; complete must NOT rewrite it.
check "7. children keep the parent branch as their working branch (folded)" \
  "qgrep '\"branch\":' '$repo7c/.git/lcars/missions/lcars-20260601-002/state.json'"

# --- Behaviour 7b: single-bug complete (BUG-032) ----------------------------
# `complete --parent <p> --bug <bug>` must fold ONLY that one child to Done and
# leave the parent's OTHER bugs pending — the per-bug "Verify" on a single card.
# Contrast the bulk `complete --parent` (Behaviour 7), which folds ALL of them.
repo7e="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo7e/gh"; make_notify_stub "$repo7e/notify"
export GH_LOG="$repo7e/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# both children at verify; the parent already carries a consolidated gate.
for seq in 002 003; do
  s="$repo7e/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
pstate="$repo7e/.git/lcars/missions/lcars-20260601-001/state.json"
sed 's/"base": "main"/"base": "main",\n  "awaitingHuman": true/' "$pstate" >"$pstate.t" && mv "$pstate.t" "$pstate"
cat >"$repo7e/.git/lcars/missions/lcars-20260601-001/pending.json" <<'EOF'
{ "stage": "verify", "questions": ["re-verify the 2 logged bugs"] }
EOF
rc7e=0
(
  cd "$repo7e"
  LCARS_GH_BIN="$repo7e/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug "lcars-20260601-002" >out7e.txt 2>&1
) || rc7e=$?
check "7b. single-bug complete exits zero" "[ '$rc7e' -eq 0 ]"
check "7b. ONLY the named bug 002 transitions to done" \
  "qgrep '\"stage\": *\"done\"' '$repo7e/.git/lcars/missions/lcars-20260601-002/state.json'"
check "7b. the SIBLING bug 003 is left pending (still verify, NOT done)" \
  "qgrep '\"stage\": *\"verify\"' '$repo7e/.git/lcars/missions/lcars-20260601-003/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo7e/.git/lcars/missions/lcars-20260601-003/state.json'"
check "7b. parent's consolidated re-verify gate STAYS up (a sibling pending)" \
  "qgrep '\"awaitingHuman\": *true' '$pstate' && [ -f '$repo7e/.git/lcars/missions/lcars-20260601-001/pending.json' ]"
check "7b. only ONE child issue relabelled lcars:done (not the whole batch)" \
  "[ \"\$(grep -c 'add-label.*lcars:done' '$repo7e/gh.log')\" -eq 1 ]"
check "7b. no per-bug PR opened" "! qgrep 'pr create' '$repo7e/gh.log'"

# Folding the LAST remaining bug clears the parent gate.
rc7f=0
(
  cd "$repo7e"
  LCARS_GH_BIN="$repo7e/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug "lcars-20260601-003" >out7f.txt 2>&1
) || rc7f=$?
check "7b. folding the last bug exits zero" "[ '$rc7f' -eq 0 ]"
check "7b. last bug 003 now done" \
  "qgrep '\"stage\": *\"done\"' '$repo7e/.git/lcars/missions/lcars-20260601-003/state.json'"
check "7b. parent gate is CLEARED once no bug remains pending" \
  "! qgrep '\"awaitingHuman\": *true' '$pstate' && [ ! -f '$repo7e/.git/lcars/missions/lcars-20260601-001/pending.json' ]"

# a --bug that is not at verify is a clean no-op (does not fold, does not error).
repo7g="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo7g/gh"; export GH_LOG="$repo7g/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
s7g="$repo7g/.git/lcars/missions/lcars-20260601-002/state.json"
sed 's/"stage": "plan"/"stage": "verify"/' "$s7g" >"$s7g.t" && mv "$s7g.t" "$s7g"
rc7g=0
(
  cd "$repo7g"
  LCARS_GH_BIN="$repo7g/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug "lcars-20260601-003" >out7g.txt 2>&1
) || rc7g=$?
check "7b. --bug not at verify is a clean no-op (exit 0, nothing folded)" \
  "[ '$rc7g' -eq 0 ] && ! qgrep '\"stage\": *\"done\"' '$repo7g/.git/lcars/missions/lcars-20260601-003/state.json'"

# idempotent / no-op safety: a parent with no children-at-verify is a clean no-op.
repo7d="$(new_repo_with_linked_bugs 0)"
make_gh_stub "$repo7d/gh"
export GH_LOG="$repo7d/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
rc7d=0
(
  cd "$repo7d"
  LCARS_GH_BIN="$repo7d/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out7d.txt 2>&1
) || rc7d=$?
check "7. complete is a clean no-op when no child is at verify" \
  "[ '$rc7d' -eq 0 ] && ! qgrep 'pr create' '$repo7d/gh.log'"

# --- Behaviour 6: children RUN on the PARENT's engine (BUG-D) ---------------
# resolve-logs delegates each child to `lcars run drive`. That child driver must
# run with LCARS_WORKER_BIN = the PARENT mission's engine (its state.json
# workerBin) so a copilot parent's bug fixes do not host-detect claude. We make
# the run stub RECORD the LCARS_WORKER_BIN it was invoked with, and assert it is
# the parent's engine — NOT the ordering worker path.
make_engine_recording_run_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="$2"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
echo "run drive $mid worker=${LCARS_WORKER_BIN:-UNSET}" >>"$RUN_LOG"
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
state="$gitdir/lcars/missions/$mid/state.json"
tmp="$(mktemp)"
awk 'NR==1{print; print "  \"stage\": \"verify\","; next} /"stage"/{next} {print}' "$state" >"$tmp" && mv "$tmp" "$state"
exit 0
EOF
  chmod +x "$1"
}

repo6e="$(new_repo_with_linked_bugs 2)"
# Give the PARENT a copilot engine. The ORDERING worker stub is a DIFFERENT path,
# so a child driven on the worker path (the pre-fix bug) would record that path
# instead of "copilot".
ps="$repo6e/.git/lcars/missions/lcars-20260601-001/state.json"
awk 'NR==1{print; print "  \"workerBin\": \"copilot\","; next} {print}' "$ps" >"$ps.t" && mv "$ps.t" "$ps"
make_gh_stub "$repo6e/gh"; make_notify_stub "$repo6e/notify"; make_engine_recording_run_stub "$repo6e/run"; make_worker_stub "$repo6e/worker"
export GH_LOG="$repo6e/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo6e/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo6e/run.log"; : >"$RUN_LOG"
rc6e=0
(
  cd "$repo6e"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002 lcars-20260601-003" \
  LCARS_GH_BIN="$repo6e/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo6e/notify" \
  LCARS_RUN_SCRIPT="$repo6e/run" LCARS_WORKER_BIN="$repo6e/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out6e.txt 2>&1
) || rc6e=$?
check "6. exits zero driving children on the parent engine" "[ '$rc6e' -eq 0 ]"
check "6. each child driver runs with LCARS_WORKER_BIN = the parent engine (copilot)" \
  "[ \"\$(grep -c 'worker=copilot' '$repo6e/run.log')\" -eq 2 ]"
check "6. no child is driven with the ordering-worker path as its engine" \
  "! grep -q \"worker=$repo6e/worker\" '$repo6e/run.log'"

# parent with NO engine set -> children driven with no engine (host-detect),
# never the ordering-worker path (regression guard).
repo6f="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo6f/gh"; make_notify_stub "$repo6f/notify"; make_engine_recording_run_stub "$repo6f/run"; make_worker_stub "$repo6f/worker"
export GH_LOG="$repo6f/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo6f/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo6f/run.log"; : >"$RUN_LOG"
(
  cd "$repo6f"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002" \
  LCARS_GH_BIN="$repo6f/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo6f/notify" \
  LCARS_RUN_SCRIPT="$repo6f/run" LCARS_WORKER_BIN="$repo6f/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out6f.txt 2>&1
)
check "6. parent without an engine drives children with no engine (UNSET, not the worker path)" \
  "grep -q 'worker=UNSET' '$repo6f/run.log' && ! grep -q \"worker=$repo6f/worker\" '$repo6f/run.log'"

# --- Behaviour 8: dependency-aware PARALLEL waves (S73) ----------------------
# resolve-logs computes a WAVE SCHEDULE over the linked children using a
# CONSERVATIVE independence signal: two bugs are independent (eligible for the
# SAME wave) ONLY when their plan.json target paths are CLEARLY disjoint AND they
# do not share a working branch. Otherwise they SERIALIZE into ordered waves.
# The schedule is recorded in resolve-logs.md (wave grouping) and a machine
# `resolve-waves.json` on the parent.

# Helper: give a child a plan.json whose tickets name $2.. target paths (recorded
# in the description so the path-extraction signal can read them).
plant_child_plan() { # child-state-dir  path1 [path2 ...]
  local d="$1"; shift
  {
    echo '['
    echo '  {'
    echo '    "id": "t-001",'
    echo '    "title": "fix it",'
    printf '    "description": "Edit'
    for p in "$@"; do printf ' %s' "$p"; done
    echo ' to fix the bug.",'
    echo '    "acceptanceCriteria": ["works"],'
    echo '    "dependencies": []'
    echo '  }'
    echo ']'
  } >"$d/plan.json"
}

# A run stub that records concurrency: writes "<id> start" immediately, sleeps so
# overlapping drivers are observable, then drives the mission to verify and writes
# "<id> end". A serial executor produces start/end/start/end; a concurrent one
# produces start/start/.../end.
make_concurrency_run_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="$2"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
# Atomic append of the start marker (so two concurrent drivers interleave safely).
echo "$mid start" >>"$RUN_LOG"
sleep 0.5
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
state="$gitdir/lcars/missions/$mid/state.json"
tmp="$(mktemp)"
awk 'NR==1{print; print "  \"stage\": \"verify\","; next} /"stage"/{next} {print}' "$state" >"$tmp" && mv "$tmp" "$state"
echo "$mid end" >>"$RUN_LOG"
exit 0
EOF
  chmod +x "$1"
}

# 8a: two INDEPENDENT bugs (disjoint plan paths) land in the SAME wave and are
# eligible to drive concurrently. With distinct branches + disjoint paths the
# executor runs them at once (two starts before any end).
repo8="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo8/gh"; make_notify_stub "$repo8/notify"; make_concurrency_run_stub "$repo8/run"; make_silent_worker_stub "$repo8/worker"
export GH_LOG="$repo8/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo8/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo8/run.log"; : >"$RUN_LOG"
# Disjoint targets → independent → same wave, distinct branches → concurrent.
plant_child_plan "$repo8/.git/lcars/missions/lcars-20260601-002" "src/alpha.py"
plant_child_plan "$repo8/.git/lcars/missions/lcars-20260601-003" "src/beta.py"
rc8=0
(
  cd "$repo8"
  ESCALATE_IDS="" LCARS_RESOLVE_CONCURRENCY=2 \
  LCARS_GH_BIN="$repo8/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo8/notify" \
  LCARS_RUN_SCRIPT="$repo8/run" LCARS_WORKER_BIN="$repo8/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out8.txt 2>&1
) || rc8=$?
check "8. exits zero scheduling 2 independent bugs into one wave" "[ '$rc8' -eq 0 ]"
check "8. schedule groups the two independent bugs in ONE wave" \
  "qgrep 'lcars-20260601-002' '$repo8/.git/lcars/missions/lcars-20260601-001/resolve-waves.json' && [ \"\$(grep -c '\"wave\"' '$repo8/.git/lcars/missions/lcars-20260601-001/resolve-waves.json')\" -eq 1 ]"
check "8. both independent bugs reach verify" \
  "qgrep '\"stage\": *\"verify\"' '$repo8/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"verify\"' '$repo8/.git/lcars/missions/lcars-20260601-003/state.json'"
check "8. two child drivers were live AT ONCE (two starts before any end)" \
  "[ \"\$(head -2 '$RUN_LOG' | grep -c start)\" -eq 2 ]"
check "8. still exactly ONE consolidated gate + ONE notify" \
  "qgrep '\"awaitingHuman\": *true' '$repo8/.git/lcars/missions/lcars-20260601-001/state.json' && [ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ]"

# 8b: two bugs sharing a target PATH are SERIALIZED into ordered waves (NOT same
# wave, NOT concurrent). With a shared path they go in separate waves and the
# executor runs them one at a time (start/end/start/end).
repo8b="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo8b/gh"; make_notify_stub "$repo8b/notify"; make_concurrency_run_stub "$repo8b/run"; make_silent_worker_stub "$repo8b/worker"
export GH_LOG="$repo8b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo8b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo8b/run.log"; : >"$RUN_LOG"
plant_child_plan "$repo8b/.git/lcars/missions/lcars-20260601-002" "src/shared.py"
plant_child_plan "$repo8b/.git/lcars/missions/lcars-20260601-003" "src/shared.py"
rc8b=0
(
  cd "$repo8b"
  ESCALATE_IDS="" LCARS_RESOLVE_CONCURRENCY=2 \
  LCARS_GH_BIN="$repo8b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo8b/notify" \
  LCARS_RUN_SCRIPT="$repo8b/run" LCARS_WORKER_BIN="$repo8b/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out8b.txt 2>&1
) || rc8b=$?
check "8. shared-path bugs land in SEPARATE waves (two wave entries)" \
  "[ \"\$(grep -c '\"wave\"' '$repo8b/.git/lcars/missions/lcars-20260601-001/resolve-waves.json')\" -eq 2 ]"
check "8. shared-path bugs run SERIALLY (start,end,start,end — no overlap)" \
  "[ \"\$(head -2 '$RUN_LOG' | grep -c start)\" -eq 1 ]"
check "8. both shared-path bugs still reach verify" \
  "qgrep '\"stage\": *\"verify\"' '$repo8b/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"verify\"' '$repo8b/.git/lcars/missions/lcars-20260601-003/state.json'"

# 8c: a child SCHEDULED-but-not-started carries a `queued` signal in state.json
# while it waits its wave; cleared once it starts/finishes. We drive a 2-bug batch
# where bug 003 is in a LATER serialized wave; a run stub that PAUSES on a fifo
# lets us inspect 003's state.json while 002 is still driving — 003 must read
# queued:true. (We then release and let the batch finish.)
repo8c="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo8c/gh"; make_notify_stub "$repo8c/notify"; make_silent_worker_stub "$repo8c/worker"
export GH_LOG="$repo8c/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo8c/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo8c/run.log"; : >"$RUN_LOG"
# Shared path → serialized waves → 003 is queued while 002 drives.
plant_child_plan "$repo8c/.git/lcars/missions/lcars-20260601-002" "src/shared.py"
plant_child_plan "$repo8c/.git/lcars/missions/lcars-20260601-003" "src/shared.py"
FIFO="$repo8c/gate.fifo"; mkfifo "$FIFO"
# Run stub for 002 blocks on the fifo so we can inspect 003 mid-batch.
cat >"$repo8c/run" <<EOF
#!/usr/bin/env bash
mid=""
while [ \$# -gt 0 ]; do case "\$1" in --mission) mid="\$2"; shift 2;; --mission=*) mid="\${1#--mission=}"; shift;; *) shift;; esac; done
echo "run drive \$mid" >>"\$RUN_LOG"
if [ "\$mid" = "lcars-20260601-002" ]; then cat "$FIFO" >/dev/null; fi
gitdir="\$(git rev-parse --git-common-dir 2>/dev/null)"
case "\$gitdir" in /*) : ;; *) gitdir="\$PWD/\$gitdir";; esac
state="\$gitdir/lcars/missions/\$mid/state.json"
tmp="\$(mktemp)"
awk 'NR==1{print; print "  \"stage\": \"verify\","; next} /"stage"/{next} {print}' "\$state" >"\$tmp" && mv "\$tmp" "\$state"
exit 0
EOF
chmod +x "$repo8c/run"
(
  cd "$repo8c"
  ESCALATE_IDS="" LCARS_RESOLVE_CONCURRENCY=1 \
  LCARS_GH_BIN="$repo8c/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo8c/notify" \
  LCARS_RUN_SCRIPT="$repo8c/run" LCARS_WORKER_BIN="$repo8c/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out8c.txt 2>&1
) &
RESOLVE_PID=$!
# Wait for 002 to enter the fifo block (it has driven), then inspect 003.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  qgrep 'run drive lcars-20260601-002' "$RUN_LOG" && break
  sleep 0.2
done
sleep 0.3
queued_seen=0
qgrep '"queued": *true' "$repo8c/.git/lcars/missions/lcars-20260601-003/state.json" && queued_seen=1
not_queued_002=1
qgrep '"queued": *true' "$repo8c/.git/lcars/missions/lcars-20260601-002/state.json" && not_queued_002=0
# Release 002 and let the batch complete.
echo go >"$FIFO"
wait "$RESOLVE_PID" 2>/dev/null || true
check "8. a scheduled-but-not-started child carries queued:true while it waits" \
  "[ '$queued_seen' -eq 1 ]"
check "8. the currently-driving child is NOT marked queued" \
  "[ '$not_queued_002' -eq 1 ]"
check "8. queued is cleared once the child has been driven (003 not queued at end)" \
  "! qgrep '\"queued\": *true' '$repo8c/.git/lcars/missions/lcars-20260601-003/state.json'"

# --- Behaviour 9 (S76): a STALE consolidated gate on the parent is CLEARED ----
# When re-driving (a previous round left a consolidated re-verify gate on the
# parent, but a linked child has since been sent back and is NOT at verify), the
# default flow must clear that stale gate BEFORE driving — so the parent shows
# "resolving", not a falsely-acceptable gate, while the re-fix is in flight. The
# gate is re-raised at the END exactly as today once every child reaches verify.
repo9="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo9/gh"; make_notify_stub "$repo9/notify"; make_run_stub "$repo9/run"; make_worker_stub "$repo9/worker"
export GH_LOG="$repo9/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo9/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo9/run.log"; : >"$RUN_LOG"
# Plant a STALE consolidated gate on the parent (pending.json + awaitingHuman).
p9="$repo9/.git/lcars/missions/lcars-20260601-001"
awk 'NR==1{print; print "  \"awaitingHuman\": true,"; print "  \"pendingQuestion\": \"old re-verify ask\","; next} {print}' \
  "$p9/state.json" >"$p9/state.json.t" && mv "$p9/state.json.t" "$p9/state.json"
cat >"$p9/pending.json" <<'EOF'
{ "stage": "verify", "questions": ["old re-verify ask"] }
EOF
# child 002 is at plan (NOT at verify) -> there IS work to drive.
rc9=0
(
  cd "$repo9"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002 lcars-20260601-003" \
  LCARS_GH_BIN="$repo9/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo9/notify" \
  LCARS_RUN_SCRIPT="$repo9/run" LCARS_WORKER_BIN="$repo9/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out9.txt 2>&1
) || rc9=$?
check "9. exits zero re-driving with a stale gate present" "[ '$rc9' -eq 0 ]"
check "9. drives the pending children" \
  "[ \"\$(grep -c 'run drive' '$RUN_LOG')\" -eq 2 ]"
# At the end the gate is RE-RAISED (the new round completed), so we assert the
# stale pending.json text was replaced — the new ask mentions re-verify of the
# resolved bugs, not the literal "old re-verify ask" we planted.
check "9. the stale pending question was cleared/replaced" \
  "! qgrep 'old re-verify ask' '$p9/pending.json'"
check "9. a fresh consolidated gate is re-raised at the end" \
  "qgrep '\"awaitingHuman\": *true' '$p9/state.json' && [ -f '$p9/pending.json' ]"
check "9. the parent's awaiting-human label is removed while resolving" \
  "qgrep 'remove-label lcars:awaiting-human' '$repo9/gh.log'"

# 9b: when GATHER finds every child ALREADY at verify (no work to drive), the
# stale-gate clear path must NOT fire a spurious early clear — the flow just
# (re)raises the gate. We assert the parent still ends with a gate and the
# children were not driven (no run.sh calls).
repo9b="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo9b/gh"; make_notify_stub "$repo9b/notify"; make_run_stub "$repo9b/run"; make_worker_stub "$repo9b/worker"
export GH_LOG="$repo9b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo9b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo9b/run.log"; : >"$RUN_LOG"
for seq in 002 003; do
  s="$repo9b/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
rc9b=0
(
  cd "$repo9b"
  ESCALATE_IDS="" WORKER_ORDER="" \
  LCARS_GH_BIN="$repo9b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo9b/notify" \
  LCARS_RUN_SCRIPT="$repo9b/run" LCARS_WORKER_BIN="$repo9b/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out9b.txt 2>&1
) || rc9b=$?
check "9b. all-at-verify re-raise drives nothing" "[ ! -s '$repo9b/run.log' ]"
check "9b. all-at-verify still (re)raises the consolidated gate" \
  "qgrep '\"awaitingHuman\": *true' '$repo9b/.git/lcars/missions/lcars-20260601-001/state.json'"

# --- Behaviour 10 (BUG-064): a child that folds to Verify STILL raises the -----
# consolidated parent gate even when a SIBLING fails to advance. Regression: a
# child that did not reach its Verify gate (left mid-flight at implement, NOT
# awaiting-human) made resolve-logs `die` and THROW AWAY the consolidated gate
# for the children that DID fold — the parent was left awaitingHuman=None with no
# pending.json (parent #46 after bug #77 folded). The folded child must still
# raise the parent's single consolidated re-verify gate; the stuck sibling is
# reported as still needing attention, not allowed to suppress the gate.
repo10="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo10/gh"; make_notify_stub "$repo10/notify"; make_run_stub "$repo10/run"; make_worker_stub "$repo10/worker"
export GH_LOG="$repo10/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo10/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repo10/run.log"; : >"$RUN_LOG"
# Force serial separate waves (shared path) so 002 folds to verify and 003 then
# errors — exercising the error path WITHOUT relying on wave ordering luck.
plant_child_plan "$repo10/.git/lcars/missions/lcars-20260601-002" "src/shared.py"
plant_child_plan "$repo10/.git/lcars/missions/lcars-20260601-003" "src/shared.py"
rc10=0
(
  cd "$repo10"
  ESCALATE_IDS="" ERROR_IDS="lcars-20260601-003" \
  WORKER_ORDER="lcars-20260601-002 lcars-20260601-003" LCARS_RESOLVE_CONCURRENCY=1 \
  LCARS_GH_BIN="$repo10/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo10/notify" \
  LCARS_RUN_SCRIPT="$repo10/run" LCARS_WORKER_BIN="$repo10/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >out10.txt 2>&1
) || rc10=$?
check "10. the folded child reached its Verify gate" \
  "qgrep '\"stage\": *\"verify\"' '$repo10/.git/lcars/missions/lcars-20260601-002/state.json'"
check "10. the stuck sibling stayed mid-flight (implement, not awaiting-human)" \
  "qgrep '\"stage\": *\"implement\"' '$repo10/.git/lcars/missions/lcars-20260601-003/state.json' && ! qgrep '\"awaitingHuman\": *true' '$repo10/.git/lcars/missions/lcars-20260601-003/state.json'"
check "10. parent STILL raises the consolidated awaiting-human gate" \
  "qgrep '\"awaitingHuman\": *true' '$repo10/.git/lcars/missions/lcars-20260601-001/state.json'"
check "10. parent STILL gets a pending.json with the re-verify ask" \
  "[ -f '$repo10/.git/lcars/missions/lcars-20260601-001/pending.json' ] && qgrep -i 'verif' '$repo10/.git/lcars/missions/lcars-20260601-001/pending.json'"
check "10. fires EXACTLY ONE notification on the parent" \
  "[ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ] && qgrep 'mission=lcars-20260601-001' '$NOTIFY_LOG'"
check "10. surfaces the stuck sibling so the captain knows it needs attention" \
  "qgrep -i 'lcars-20260601-003' '$repo10/out10.txt'"

# 10b: the captain then clears the consolidated gate BOTH ways.
#   1-by-1 — `complete --bug` folds ONLY the verified child; gate stays up because
#   the stuck sibling is still pending.
rc10b=0
(
  cd "$repo10"
  LCARS_GH_BIN="$repo10/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" complete --parent "$PARENT" --bug "lcars-20260601-002" >out10b.txt 2>&1
) || rc10b=$?
check "10b. 1-by-1 verify folds ONLY that bug to Done" \
  "[ '$rc10b' -eq 0 ] && qgrep '\"stage\": *\"done\"' '$repo10/.git/lcars/missions/lcars-20260601-002/state.json'"
check "10b. gate STAYS up while the stuck sibling is still pending" \
  "qgrep '\"awaitingHuman\": *true' '$repo10/.git/lcars/missions/lcars-20260601-001/state.json'"

# 10c: bulk-accept on the parent (complete --parent) re-checked on a 2-verify
# parent folds ALL verified children to Done in one go (the bulk path).
repo10c="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo10c/gh"; make_notify_stub "$repo10c/notify"; make_run_stub "$repo10c/run"; make_worker_stub "$repo10c/worker"
export GH_LOG="$repo10c/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
for seq in 002 003; do
  s="$repo10c/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
rc10c=0
(
  cd "$repo10c"
  LCARS_GH_BIN="$repo10c/gh" LCARS_GIT_BIN="$(command -v git)" \
    bash "$SCRIPT" complete --parent "$PARENT" >out10c.txt 2>&1
) || rc10c=$?
check "10c. bulk-accept folds ALL verified children to Done" \
  "[ '$rc10c' -eq 0 ] && qgrep '\"stage\": *\"done\"' '$repo10c/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"done\"' '$repo10c/.git/lcars/missions/lcars-20260601-003/state.json'"

# --- Behaviour 12 (completeness guard): bulk complete REFUSES + RE-RAISES the gate
# while a logged bug is still un-driven, instead of silently dropping it. Reproduces
# the real incident: 002+003 reached Verify, 004 was stranded at plan; respond.sh
# clears the consolidated gate THEN best-effort-folds (ignoring our exit), so a naive
# fold would move 002/003 to Done and lose 004. The guard must re-raise the gate.
repo12="$(new_repo_with_linked_bugs 3)"
make_gh_stub "$repo12/gh"; make_notify_stub "$repo12/notify"
export GH_LOG="$repo12/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repo12/notify.log"; : >"$NOTIFY_LOG"
# 002 & 003 reached verify; 004 LEFT at plan (the stranded straggler). The parent
# carries NO awaitingHuman — simulating respond.sh having already cleared the gate
# right before delegating the fold to us (so we must RE-RAISE it).
for seq in 002 003; do
  s="$repo12/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
p12="$repo12/.git/lcars/missions/lcars-20260601-001/state.json"
rc12=0
(
  cd "$repo12"
  LCARS_GH_BIN="$repo12/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo12/notify" \
  LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out12.txt 2>&1
) || rc12=$?
check "12. bulk complete REFUSES (non-zero) while a logged bug is un-driven" \
  "[ '$rc12' -ne 0 ]"
check "12. verified siblings are NOT folded to Done (no silent partial accept)" \
  "qgrep '\"stage\": *\"verify\"' '$repo12/.git/lcars/missions/lcars-20260601-002/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo12/.git/lcars/missions/lcars-20260601-002/state.json'"
check "12. the stranded bug 004 is named in the refusal" \
  "qgrep 'lcars-20260601-004' '$repo12/out12.txt'"
check "12. the parent gate is RE-RAISED (awaitingHuman set + pending.json written)" \
  "qgrep '\"awaitingHuman\": *true' '$p12' && [ -f '$repo12/.git/lcars/missions/lcars-20260601-001/pending.json' ]"

# ==========================================================================
echo
printf 'lcars resolve-logs: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
