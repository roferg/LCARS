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
if [ "$escalate" -eq 1 ]; then
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

# ==========================================================================
echo
printf 'lcars resolve-logs: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
