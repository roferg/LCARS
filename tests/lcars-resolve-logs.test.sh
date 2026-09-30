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

# S180 — respond.sh now HANDS BACK TO THE DRIVER when it clears a gate (the
# captain had to type a second command for every answer he gave). This suite
# exercises respond.sh itself, not the pipeline, so it opts out: without this
# every `answer` here would launch a real `run.sh drive` in a fixture repo,
# mutating the state the assertions below read and — with a worker binary on the
# box — spending real money. The resume itself is covered, with a stubbed driver,
# in tests/settled-decisions.test.sh.
export LCARS_RESPOND_RESUME=0

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
# --- S204: THE GATE RECORDS WHAT IT IS -------------------------------------
# `lcars xo answer` routes a re-verify gate to Number One's re-check, and it
# routes on THIS field — not on the shape of the sentence above it. The prose is
# free to change; the marker is the contract. (The consumer side of this pact is
# pinned in tests/lcars-xo.test.sh B12h, where a REWORDED gate still routes and
# an ordinary Verify park that talks about logged bugs does not.)
check "1. the consolidated gate RECORDS its kind (reverify) for the consumer" \
  "qgrep '\"kind\": *\"reverify\"' '$repo/.git/lcars/missions/lcars-20260601-001/pending.json'"
check "1. …and the gate is still valid JSON with it" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repo/.git/lcars/missions/lcars-20260601-001/pending.json'"

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
# S222-B REVERSES THE TWO ASSERTIONS THAT USED TO LIVE HERE. They read
#   "NO consolidated re-verify gate on the parent yet"  (awaitingHuman absent)
#   "NO consolidated notify fired"                      (notify.log empty)
# and they were pinning the silence that cost the captain a night: one log stuck,
# seven queued behind it, nothing shipped and nothing said so. The consolidated
# RE-VERIFY gate must still not be raised — nothing is ready to re-verify — but
# the parent must not go quiet either. It gets the `reverify-blocked` gate and
# ONE ping, exactly as the stranded-log path has since S204. Proven in full at
# S222-B below; kept here so the old silence cannot come back by this door.
check "3. still NO consolidated re-verify gate (nothing is ready for one)" \
  "! qgrep '\"kind\": *\"reverify\",' '$repo3/.git/lcars/missions/lcars-20260601-001/pending.json'"
check "3. but the parent is NOT silent — it gets the reverify-blocked gate" \
  "qgrep '\"awaitingHuman\": *true' '$repo3/.git/lcars/missions/lcars-20260601-001/state.json' \
   && qgrep '\"kind\": *\"reverify-blocked\"' '$repo3/.git/lcars/missions/lcars-20260601-001/pending.json'"
check "3. and exactly ONE notify fired (never one per bug)" \
  "[ \"\$(wc -l <'$repo3/notify.log' | tr -d ' ')\" -eq 1 ]"
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
# S204: a re-raised gate is a BLOCKED re-verify, and it says so. Number One must
# never mistake it for the ordinary one and go re-look at a build: nothing it can
# do clears a stranded child, a failed push or a missing branch. It reads this
# marker and hands the gate straight back.
check "12. the re-raised gate records kind reverify-BLOCKED, not reverify" \
  "qgrep '\"kind\": *\"reverify-blocked\"' '$repo12/.git/lcars/missions/lcars-20260601-001/pending.json'"
check "12. …and it is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repo12/.git/lcars/missions/lcars-20260601-001/pending.json'"

# --- Behaviour 13 (S89, push-on-accept): the BULK consolidated accept PUSHES the
# parent branch to origin so the open PR reflects the accepted logged-bug fixes,
# and BLOCKS the accept until that push succeeds. The fix commits already live on
# the parent branch (fold only flips child stage/labels), so pushing the parent
# branch ships them. Push BEFORE folding: on a push failure NOTHING is folded
# (nothing reads as shipped) and a re-run RETRIES the push.

# git push stub: intercept `push` (record argv to $GIT_PUSH_LOG, exit 0; OR exit
# non-zero simulating a real rejection when $PUSH_FAIL=1). Any OTHER subcommand
# execs real git so `rev-parse --git-common-dir` / `remote get-url` still work.
make_git_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "push" ]; then
  echo "git $*" >>"$GIT_PUSH_LOG"
  if [ "${PUSH_NONFF:-0}" = "1" ]; then
    # A GENUINE non-fast-forward rejection: the remote head diverged from local.
    echo " ! [rejected]        ${3:-b} -> ${3:-b} (non-fast-forward)" >&2
    echo "error: failed to push some refs to 'origin'" >&2
    echo "hint: Updates were rejected because the tip of your current branch is behind" >&2
    exit 1
  fi
  if [ "${PUSH_FAIL:-0}" = "1" ]; then
    echo "! [remote rejected] (simulated push failure)" >&2
    exit 1
  fi
  exit 0
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$1"
}

# 13a HAPPY: parent + all linked bugs at verify, parent has branch + reachable
# (stubbed) origin → bulk accept folds all to done AND pushes the parent branch
# EXACTLY ONCE; exit 0.
repo13="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo13/gh"; make_notify_stub "$repo13/notify"; make_git_stub "$repo13/git"
export GH_LOG="$repo13/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export GIT_PUSH_LOG="$repo13/push.log"; : >"$GIT_PUSH_LOG"
( cd "$repo13" && git remote add origin https://example.invalid/r.git )
for seq in 002 003; do
  s="$repo13/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
rc13=0
(
  cd "$repo13"
  REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13/push.log" \
  LCARS_GH_BIN="$repo13/gh" LCARS_GIT_BIN="$repo13/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13.txt 2>&1
) || rc13=$?
check "13. push-on-accept: bulk complete exits zero" "[ '$rc13' -eq 0 ]"
check "13. both children fold to Done" \
  "qgrep '\"stage\": *\"done\"' '$repo13/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"done\"' '$repo13/.git/lcars/missions/lcars-20260601-003/state.json'"
check "13. pushed the parent branch EXACTLY ONCE" \
  "[ \"\$(wc -l <'$repo13/push.log' | tr -d ' ')\" -eq 1 ]"
check "13. the push targets origin <parent branch>" \
  "qgrep 'push origin lcars/lcars-20260601-001' '$repo13/push.log'"

# 13b PUSH FAILS: the accept is BLOCKED (non-zero), folds NOTHING, and the parent
# gate is RE-RAISED VISIBLY (awaitingHuman + pending.json naming the branch and a
# push failure). Then a RE-RUN (push now succeeds) RETRIES the push and folds.
repo13b="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo13b/gh"; make_notify_stub "$repo13b/notify"; make_git_stub "$repo13b/git"
export GH_LOG="$repo13b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
( cd "$repo13b" && git remote add origin https://example.invalid/r.git )
for seq in 002 003; do
  s="$repo13b/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
p13b="$repo13b/.git/lcars/missions/lcars-20260601-001/state.json"
pj13b="$repo13b/.git/lcars/missions/lcars-20260601-001/pending.json"
rc13b=0
(
  cd "$repo13b"
  PUSH_FAIL=1 REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13b/push.log" \
  LCARS_GH_BIN="$repo13b/gh" LCARS_GIT_BIN="$repo13b/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13b.txt 2>&1
) || rc13b=$?
check "13. a failed push BLOCKS the accept (non-zero)" "[ '$rc13b' -ne 0 ]"
check "13. a failed push folds NOTHING (children stay at verify, not done)" \
  "qgrep '\"stage\": *\"verify\"' '$repo13b/.git/lcars/missions/lcars-20260601-002/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo13b/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"verify\"' '$repo13b/.git/lcars/missions/lcars-20260601-003/state.json'"
check "13. a failed push RE-RAISES the parent gate (awaitingHuman + pending.json)" \
  "qgrep '\"awaitingHuman\": *true' '$p13b' && [ -f '$pj13b' ]"
check "13. the re-raised ask names the branch AND indicates a push failure" \
  "qgrep 'lcars/lcars-20260601-001' '$pj13b' && qgrep -i 'push' '$pj13b'"
check "13. nothing reads as shipped — no child is Done after a failed push" \
  "! qgrep '\"stage\": *\"done\"' '$repo13b/.git/lcars/missions/lcars-20260601-002/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo13b/.git/lcars/missions/lcars-20260601-003/state.json'"
check "13. the failed push was actually attempted (logged once)" \
  "[ \"\$(wc -l <'$repo13b/push.log' | tr -d ' ')\" -eq 1 ]"

# re-run: push now succeeds → retries the push AND folds to done.
: >"$repo13b/push.log"
rc13c=0
(
  cd "$repo13b"
  REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13b/push.log" \
  LCARS_GH_BIN="$repo13b/gh" LCARS_GIT_BIN="$repo13b/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13c.txt 2>&1
) || rc13c=$?
check "13. a re-run after a failed push RETRIES the push (logged once)" \
  "[ \"\$(wc -l <'$repo13b/push.log' | tr -d ' ')\" -eq 1 ]"
check "13. the retry folds all children to Done, exit 0" \
  "[ '$rc13c' -eq 0 ] && qgrep '\"stage\": *\"done\"' '$repo13b/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"done\"' '$repo13b/.git/lcars/missions/lcars-20260601-003/state.json'"

# 13d IDEMPOTENT: a second bulk accept when everything is already done+pushed is a
# clean no-op — exit 0, NO push attempted (a stub-fail-on-push would NOT fire).
: >"$repo13b/push.log"
rc13d=0
(
  cd "$repo13b"
  PUSH_FAIL=1 REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13b/push.log" \
  LCARS_GH_BIN="$repo13b/gh" LCARS_GIT_BIN="$repo13b/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13d.txt 2>&1
) || rc13d=$?
check "13. idempotent re-accept (all already done) is a clean no-op (exit 0)" \
  "[ '$rc13d' -eq 0 ]"
check "13. idempotent re-accept attempts NO push (so stub-fail-on-push never fires)" \
  "[ ! -s '$repo13b/push.log' ]"

# 13e: the --bug SINGLE complete must NOT push (it folds one card; the bulk accept
# is the ship point). PUSH_FAIL is armed to prove the single path never pushes.
repo13e="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo13e/gh"; make_notify_stub "$repo13e/notify"; make_git_stub "$repo13e/git"
export GH_LOG="$repo13e/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
( cd "$repo13e" && git remote add origin https://example.invalid/r.git )
for seq in 002 003; do
  s="$repo13e/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
rc13e=0
(
  cd "$repo13e"
  PUSH_FAIL=1 REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13e/push.log" \
  LCARS_GH_BIN="$repo13e/gh" LCARS_GIT_BIN="$repo13e/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug "lcars-20260601-002" >out13e.txt 2>&1
) || rc13e=$?
check "13. --bug single complete exits zero" "[ '$rc13e' -eq 0 ]"
check "13. --bug single complete folds only that bug to Done" \
  "qgrep '\"stage\": *\"done\"' '$repo13e/.git/lcars/missions/lcars-20260601-002/state.json'"
check "13. --bug single complete does NOT push (zero pushes logged)" \
  "[ ! -s '$repo13e/push.log' ]"

# 13f NON-FAST-FORWARD (S90 GAP 1, lock-in): a GENUINE non-ff rejection — the
# remote PR head diverged from the local branch — must BLOCK the accept, fold
# NOTHING, and re-raise the gate. resolve-logs does NOT classify or force-push:
# ANY push failure blocks, which is CORRECT here. The local branch is expected to
# be a fast-forward of the PR head (we hold the committed fixes), so a non-ff means
# the remote genuinely diverged and the human must reconcile it — we never force.
repo13f="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo13f/gh"; make_notify_stub "$repo13f/notify"; make_git_stub "$repo13f/git"
export GH_LOG="$repo13f/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
( cd "$repo13f" && git remote add origin https://example.invalid/r.git )
for seq in 002 003; do
  s="$repo13f/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
p13f="$repo13f/.git/lcars/missions/lcars-20260601-001/state.json"
pj13f="$repo13f/.git/lcars/missions/lcars-20260601-001/pending.json"
rc13f=0
(
  cd "$repo13f"
  PUSH_NONFF=1 REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13f/push.log" \
  LCARS_GH_BIN="$repo13f/gh" LCARS_GIT_BIN="$repo13f/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13f.txt 2>&1
) || rc13f=$?
check "13f. a non-fast-forward rejection BLOCKS the accept (non-zero)" "[ '$rc13f' -ne 0 ]"
check "13f. a non-ff rejection folds NOTHING (children stay at verify, none done)" \
  "qgrep '\"stage\": *\"verify\"' '$repo13f/.git/lcars/missions/lcars-20260601-002/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo13f/.git/lcars/missions/lcars-20260601-002/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo13f/.git/lcars/missions/lcars-20260601-003/state.json'"
check "13f. a non-ff rejection RE-RAISES the parent gate naming the branch + push" \
  "qgrep '\"awaitingHuman\": *true' '$p13f' && [ -f '$pj13f' ] && qgrep 'lcars/lcars-20260601-001' '$pj13f' && qgrep -i 'push' '$pj13f'"
check "13f. the non-ff push was attempted exactly once (we never force-push)" \
  "[ \"\$(wc -l <'$repo13f/push.log' | tr -d ' ')\" -eq 1 ]"

# 13g MISSING BRANCH + ORIGIN (S90 GAP 2, the real hole): a parent whose state.json
# records NO branch, with an origin configured, must BLOCK — folding would silently
# ship nothing to the open PR. Assert non-zero, NOTHING folded, gate re-raised with
# a message indicating no branch / cannot bring the PR current, and ZERO pushes (the
# push is never reached — there is nothing to push).
repo13g="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo13g/gh"; make_notify_stub "$repo13g/notify"; make_git_stub "$repo13g/git"
export GH_LOG="$repo13g/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
( cd "$repo13g" && git remote add origin https://example.invalid/r.git )
for seq in 002 003; do
  s="$repo13g/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
# Strip the parent's branch line → no branch recorded.
p13g="$repo13g/.git/lcars/missions/lcars-20260601-001/state.json"
grep -v '"branch"' "$p13g" >"$p13g.t" && mv "$p13g.t" "$p13g"
pj13g="$repo13g/.git/lcars/missions/lcars-20260601-001/pending.json"
rc13g=0
(
  cd "$repo13g"
  PUSH_FAIL=1 REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13g/push.log" \
  LCARS_GH_BIN="$repo13g/gh" LCARS_GIT_BIN="$repo13g/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13g.txt 2>&1
) || rc13g=$?
check "13g. missing-branch + origin BLOCKS the accept (non-zero)" "[ '$rc13g' -ne 0 ]"
check "13g. missing-branch + origin folds NOTHING (children stay at verify)" \
  "! qgrep '\"stage\": *\"done\"' '$repo13g/.git/lcars/missions/lcars-20260601-002/state.json' && ! qgrep '\"stage\": *\"done\"' '$repo13g/.git/lcars/missions/lcars-20260601-003/state.json'"
check "13g. missing-branch + origin RE-RAISES the parent gate (awaitingHuman + pending.json)" \
  "qgrep '\"awaitingHuman\": *true' '$p13g' && [ -f '$pj13g' ]"
check "13g. the missing-branch ask indicates no branch / cannot bring PR current" \
  "qgrep -i 'branch' '$pj13g' && qgrep -i 'cannot|current' '$pj13g'"
check "13g. ZERO push attempts (the push is never reached)" \
  "[ ! -s '$repo13g/push.log' ]"

# 13h MISSING BRANCH + NO ORIGIN (S90 escape hatch preserved): the same empty-branch
# parent but with NO origin remote folds the batch to Done — the local/test path is
# untouched (no remote ⇒ nothing to keep current). Exit 0, zero pushes.
repo13h="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo13h/gh"; make_notify_stub "$repo13h/notify"; make_git_stub "$repo13h/git"
export GH_LOG="$repo13h/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
# NO `git remote add origin` here — that is the point of the escape hatch.
for seq in 002 003; do
  s="$repo13h/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s" >"$s.t" && mv "$s.t" "$s"
done
p13h="$repo13h/.git/lcars/missions/lcars-20260601-001/state.json"
grep -v '"branch"' "$p13h" >"$p13h.t" && mv "$p13h.t" "$p13h"
rc13h=0
(
  cd "$repo13h"
  PUSH_FAIL=1 REAL_GIT="$(command -v git)" GIT_PUSH_LOG="$repo13h/push.log" \
  LCARS_GH_BIN="$repo13h/gh" LCARS_GIT_BIN="$repo13h/git" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out13h.txt 2>&1
) || rc13h=$?
check "13h. missing-branch + NO origin FOLDS the batch to Done (escape hatch intact), exit 0" \
  "[ '$rc13h' -eq 0 ] && qgrep '\"stage\": *\"done\"' '$repo13h/.git/lcars/missions/lcars-20260601-002/state.json' && qgrep '\"stage\": *\"done\"' '$repo13h/.git/lcars/missions/lcars-20260601-003/state.json'"
check "13h. missing-branch + NO origin attempts ZERO pushes" \
  "[ ! -s '$repo13h/push.log' ]"

# --- Behaviour 14: the fold's PREMISE CHECK, both directions -----------------
#
# The 2026-07-28 fix made fold_one_child verify that a logged bug's fix is ACTUALLY
# on the parent branch before calling it Done (three DX-Scorecard fixes had vanished
# while the board read green). It shipped with NO test: nothing in this suite ever
# planted a `.commit-sha`, so `child_recorded_a_commit` was always false and the
# check never ran. Every existing fold test passes it vacuously.
#
# It was inverted. `child_fix_on_branch` piped `git log` into `grep -q`; under this
# script's `set -o pipefail`, grep -q exits on first match, git dies of SIGPIPE, and
# pipefail returns 141 — so the ONE case that matters (the fix IS on the branch)
# reported "not on branch" and every legitimate fold was REFUSED with a false alarm
# about missing code.
#
# So: exercise the check for real, in both directions.
new_repo_premise() { # <bug-fix-on-parent-branch: yes|no>
  local onbranch="$1" repo; repo="$(mktemp -d "$TMPROOT/repoP.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  # a REAL parent branch ref, carrying the parent's ticket commit — and, when the
  # case calls for it, the child's fix commit with its `lcars(<bug-id>)` subject.
  ( cd "$repo" && git checkout -q -b "lcars/lcars-20260601-001" \
      && echo a >a.txt && git add -A \
      && git commit -q -m "lcars(lcars-20260601-001) t-001: parent work" )
  if [ "$onbranch" = "yes" ]; then
    ( cd "$repo" && echo b >b.txt && git add -A \
        && git commit -q -m "lcars(lcars-20260601-002) t-001: the logged bug fix" )
  fi
  ( cd "$repo" && git checkout -q master 2>/dev/null || git checkout -q main )
  mkdir -p "$repo/.git/lcars/missions"
  printf '{ "model": "claude-sonnet" }\n' >"$repo/.git/lcars/config.json"
  local p="$repo/.git/lcars/missions/lcars-20260601-001"
  mkdir -p "$p"
  cat >"$p/state.json" <<'EOF'
{
  "id": "lcars-20260601-001",
  "type": "feature",
  "title": "Add gamification",
  "stage": "verify",
  "awaitingHuman": true,
  "githubIssue": 42,
  "branch": "lcars/lcars-20260601-001",
  "base": "main"
}
EOF
  printf '{ "stage": "verify", "questions": ["re-verify"] }\n' >"$p/pending.json"
  # the child: at verify, folded onto the PARENT branch, and it RECORDED a commit —
  # so the premise check actually runs for it.
  local c="$repo/.git/lcars/missions/lcars-20260601-002"
  mkdir -p "$c/tickets/t-001"
  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" >"$c/tickets/t-001/.commit-sha"
  cat >"$c/state.json" <<'EOF'
{
  "id": "lcars-20260601-002",
  "type": "bug",
  "title": "Logged bug one",
  "stage": "verify",
  "githubIssue": 51,
  "parentMission": "lcars-20260601-001",
  "parentIssue": 42,
  "branch": "lcars/lcars-20260601-001",
  "base": "lcars/lcars-20260601-001"
}
EOF
  echo "$repo"
}

# 14a. the fix IS on the parent branch → the fold must go through.
repo14a="$(new_repo_premise yes)"
make_gh_stub "$repo14a/gh"; export GH_LOG="$repo14a/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
rc14a=0
( cd "$repo14a" && LCARS_GH_BIN="$repo14a/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_NOTIFY_NO_DESKTOP=1 bash "$SCRIPT" complete --parent "$PARENT" \
    --bug lcars-20260601-002 >out.txt 2>&1 ) || rc14a=$?
check "14a. a child whose fix IS on the parent branch folds to done" \
  "qgrep '\"stage\": *\"done\"' '$repo14a/.git/lcars/missions/lcars-20260601-002/state.json'"
check "14a. exits zero (no false refusal)" "[ '$rc14a' -eq 0 ]"
check "14a. says nothing about a missing fix" \
  "! qgrep -i 'NOT on the parent branch' '$repo14a/out.txt'"

# 14b. the fix is NOT on the parent branch → REFUSE, and never mark it Done.
repo14b="$(new_repo_premise no)"
make_gh_stub "$repo14b/gh"; export GH_LOG="$repo14b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
rc14b=0
( cd "$repo14b" && LCARS_GH_BIN="$repo14b/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_NOTIFY_NO_DESKTOP=1 bash "$SCRIPT" complete --parent "$PARENT" \
    --bug lcars-20260601-002 >out.txt 2>&1 ) || rc14b=$?
check "14b. a child whose fix is NOT on the branch is REFUSED (non-zero)" \
  "[ '$rc14b' -ne 0 ]"
check "14b. it STAYS at verify — never a false Done" \
  "qgrep '\"stage\": *\"verify\"' '$repo14b/.git/lcars/missions/lcars-20260601-002/state.json'"
check "14b. the refusal explains that the fix is not on the parent branch" \
  "qgrep -i 'NOT on the parent branch' '$repo14b/out.txt'"
check "14b. applies no lcars:done label to the refused child" \
  "! qgrep 'add-label lcars:done' '$repo14b/gh.log'"

# --- Behaviour 15 (S165): a folded child's ISSUE IS CLOSED -------------------
#
# BUG (DX-Scorecard, 2026-07-30): mission lcars-20260730-005 merged as PR #77 with
# SEVEN logged-bug children. All 14 commits reached origin/main, the parent issue
# #69 closed — and all seven bug issues (#78–84) stayed OPEN, each correctly
# carrying `lcars:done`. The labels are the proof this is not a forge problem: the
# relabel landed perfectly. Nothing anywhere CLOSES a folded child.
#
# Two mechanisms combined. `open_pr()` builds the PR's `Closes` list from the
# parent plus the TICKET sub-issues Schedule opened — a logged-bug child is a
# separate Mission linked by `lcars:linked`, so it never lands in the PR body and
# GitHub never auto-closes it on merge. And fold_one_child relabelled the child's
# issue and stopped. `host-adapter.sh` has had the `issue-close` verb all along;
# it was simply never called for a folded child.
#
# So: the fold closes the child's issue, through the HOST ADAPTER (the one forge
# seam), best-effort and never fatal, and NEVER for a child the premise check
# refused.
#
# host-adapter stub: records every op, and mimics real `gh issue close` on an
# already-closed issue (warn on stderr, exit 0 — cli/cli returns nil there).
# $HOST_RC forces a forge failure.
make_host_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "host $*" >>"$HOST_LOG"
op="${1:-}"; shift 2>/dev/null || true
if [ "$op" = "issue-close" ]; then
  n="${1:-}"; cl="${HOST_LOG}.closed"
  if grep -qxF "$n" "$cl" 2>/dev/null; then
    echo "! Issue #$n is already closed" >&2
    exit 0
  fi
  echo "$n" >>"$cl"
fi
exit "${HOST_RC:-0}"
EOF
  chmod +x "$1"
}

# 15a. the bulk fold closes every folded child's issue — after the relabel,
# through the adapter, and never the parent's own issue.
# ONE combined log (HOST_LOG == GH_LOG) so relabel-then-close ordering is provable.
repo15="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repo15/gh"; make_host_stub "$repo15/host"
export GH_LOG="$repo15/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export HOST_LOG="$repo15/gh.log"
for seq in 002 003; do
  s15="$repo15/.git/lcars/missions/lcars-20260601-$seq/state.json"
  sed 's/"stage": "plan"/"stage": "verify"/' "$s15" >"$s15.t" && mv "$s15.t" "$s15"
done
rc15=0
( cd "$repo15" && LCARS_GH_BIN="$repo15/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15/host" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" >out15.txt 2>&1 ) || rc15=$?
check "15a. the bulk complete still exits zero" "[ '$rc15' -eq 0 ]"
check "15a. folded child #51's issue is CLOSED" \
  "qgrep 'host issue-close 51' '$repo15/gh.log'"
check "15a. folded child #52's issue is CLOSED" \
  "qgrep 'host issue-close 52' '$repo15/gh.log'"
check "15a. the close goes through the HOST ADAPTER, never a raw \$GH_BIN close" \
  "! qgrep 'gh issue close' '$repo15/gh.log'"
check "15a. the relabel is kept on its existing path (close does not replace it)" \
  "qgrep 'gh issue edit 51 .*add-label lcars:done' '$repo15/gh.log'"
check "15a. the close comes AFTER the relabel for that child" \
  "[ \"\$(grep -n 'issue edit 51' '$repo15/gh.log' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'issue-close 51' '$repo15/gh.log' | head -1 | cut -d: -f1)\" ]"
check "15a(7). the PARENT's own issue #42 is NOT closed by the fold (it rides the PR)" \
  "! qgrep 'issue-close 42' '$repo15/gh.log'"

# 15b. a close FAILURE is non-fatal: the fold still succeeds, with a legible note.
# A logged bug whose fix is really on the branch is never held hostage to a hiccup.
repo15f="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo15f/gh"; make_host_stub "$repo15f/host"
export GH_LOG="$repo15f/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export HOST_LOG="$repo15f/host.log"; : >"$HOST_LOG"
s15f="$repo15f/.git/lcars/missions/lcars-20260601-002/state.json"
sed 's/"stage": "plan"/"stage": "verify"/' "$s15f" >"$s15f.t" && mv "$s15f.t" "$s15f"
rc15f=0
( cd "$repo15f" && LCARS_GH_BIN="$repo15f/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15f/host" HOST_RC=1 LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug lcars-20260601-002 \
    >out15f.txt 2>&1 ) || rc15f=$?
check "15b. a FAILED close is non-fatal — the fold still exits zero" \
  "[ '$rc15f' -eq 0 ]"
check "15b. the child is still folded to done despite the failed close" \
  "qgrep '\"stage\": *\"done\"' '$s15f'"
check "15b. a failed close leaves a legible note naming the issue" \
  "qgrep -i 'could not close.*#?51' '$repo15f/out15f.txt'"

# 15c. idempotent: an ALREADY-CLOSED issue is a clean no-op, and a re-run of the
# fold does not thrash the issue with a second close.
repo15i="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo15i/gh"; make_host_stub "$repo15i/host"
export GH_LOG="$repo15i/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export HOST_LOG="$repo15i/host.log"; : >"$HOST_LOG"
echo 51 >"$HOST_LOG.closed"          # the issue is ALREADY closed on the forge
s15i="$repo15i/.git/lcars/missions/lcars-20260601-002/state.json"
sed 's/"stage": "plan"/"stage": "verify"/' "$s15i" >"$s15i.t" && mv "$s15i.t" "$s15i"
rc15i=0
( cd "$repo15i" && LCARS_GH_BIN="$repo15i/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15i/host" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug lcars-20260601-002 \
    >out15i.txt 2>&1 ) || rc15i=$?
check "15c. closing an ALREADY-CLOSED issue exits zero" "[ '$rc15i' -eq 0 ]"
check "15c. …and reports no failure" \
  "! qgrep -i 'could not close' '$repo15i/out15i.txt'"
rc15j=0
( cd "$repo15i" && LCARS_GH_BIN="$repo15i/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15i/host" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug lcars-20260601-002 \
    >out15j.txt 2>&1 ) || rc15j=$?
check "15c. re-folding an already-done child exits zero" "[ '$rc15j' -eq 0 ]"
check "15c. …and makes NO second close call (no thrash)" \
  "[ \"\$(grep -c 'issue-close 51' '$repo15i/host.log')\" -eq 1 ]"

# 15d. a child with NO githubIssue (local-only mission) folds fine and attempts
# no close at all — the same guard the relabel already has.
repo15n="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo15n/gh"; make_host_stub "$repo15n/host"
export GH_LOG="$repo15n/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export HOST_LOG="$repo15n/host.log"; : >"$HOST_LOG"
s15n="$repo15n/.git/lcars/missions/lcars-20260601-002/state.json"
sed -e 's/"stage": "plan"/"stage": "verify"/' -e 's/"githubIssue": 51/"githubIssue": null/' \
  "$s15n" >"$s15n.t" && mv "$s15n.t" "$s15n"
rc15n=0
( cd "$repo15n" && LCARS_GH_BIN="$repo15n/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15n/host" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug lcars-20260601-002 \
    >out15n.txt 2>&1 ) || rc15n=$?
check "15d. a child with NO githubIssue still folds to done" \
  "[ '$rc15n' -eq 0 ] && qgrep '\"stage\": *\"done\"' '$s15n'"
check "15d. …and attempts no close whatsoever" \
  "! qgrep 'issue-close' '$repo15n/host.log'"
check "15d. …and reports no close failure" \
  "! qgrep -i 'could not close' '$repo15n/out15n.txt'"

# 15e. a REFUSED fold (the premise check: the fix is NOT on the parent branch)
# closes NOTHING. Closing an issue whose fix does not exist is exactly the
# "green board, no code" failure 2026.7.18 closed.
repo15r="$(new_repo_premise no)"
make_gh_stub "$repo15r/gh"; make_host_stub "$repo15r/host"
export GH_LOG="$repo15r/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export HOST_LOG="$repo15r/host.log"; : >"$HOST_LOG"
rc15r=0
( cd "$repo15r" && LCARS_GH_BIN="$repo15r/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15r/host" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug lcars-20260601-002 \
    >out15r.txt 2>&1 ) || rc15r=$?
check "15e. a refused fold is still non-zero (premise check intact)" \
  "[ '$rc15r' -ne 0 ]"
check "15e. a REFUSED child's issue is NEVER closed" \
  "! qgrep 'issue-close' '$repo15r/host.log'"
check "15e. the refused child stays at verify with its issue open" \
  "qgrep '\"stage\": *\"verify\"' '$repo15r/.git/lcars/missions/lcars-20260601-002/state.json'"

# 15f. the fold's close survives a real host-adapter that is simply MISSING —
# it must note it, not abort the fold.
repo15m="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repo15m/gh"
export GH_LOG="$repo15m/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
s15m="$repo15m/.git/lcars/missions/lcars-20260601-002/state.json"
sed 's/"stage": "plan"/"stage": "verify"/' "$s15m" >"$s15m.t" && mv "$s15m.t" "$s15m"
rc15m=0
( cd "$repo15m" && LCARS_GH_BIN="$repo15m/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$repo15m/no-such-adapter.sh" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" complete --parent "$PARENT" --bug lcars-20260601-002 \
    >out15m.txt 2>&1 ) || rc15m=$?
check "15f. a missing host adapter does not abort the fold" \
  "[ '$rc15m' -eq 0 ] && qgrep '\"stage\": *\"done\"' '$s15m'"

# --- S207 item 2: a DIRECT `lcars resolve-logs` keeps engine provenance -----
# run_child_driver re-pins the mission's OWN engine through $LCARS_WORKER_BIN so
# the child drive inherits it. run.sh reads a BARE $LCARS_WORKER_BIN as an
# OPERATOR act and records `engineSource: env` — destroying the richer
# adopt-chosen / adopt-converted / mission answer. approve.sh was cured in
# 3055874 by exporting $LCARS_WORKER_BIN_INTERNAL=1 beside the pin ("LCARS set
# this, re-asserting THIS mission's engine"); reached THROUGH approve the marker
# is inherited and resolve-logs is incidentally fine, so the defect only shows
# when resolve-logs is run DIRECTLY. One line, the same cure.
#
# S207 FIX ROUND 1 (D1) — THE STUB NO LONGER PARAPHRASES THE RULE; IT RUNS IT.
# The original stub re-implemented run.sh's provenance rule in twelve lines, and
# it PASSED while the defect was live: it asserted at the PARENT level (that the
# marker was exported) and its hand-written copy of the rule had no idea what the
# real resolver does with an internal pin on a mission that records no engine of
# its own. That is exactly the case a child bug mission is in — `lcars log` files
# it with no engine in scope, so it carries no `workerBin` — and the real run.sh
# degraded the attribution to `env`, the CAPTAIN's source, for a pin LCARS set.
#
# So this stub now shells out to the REAL run.sh `resolve-worker --mission <id>`
# (a mission-aware, LLM-free, spawn-free surface over resolve_worker_bin +
# record_engine_provenance — the same two functions the drive's stage subprocess
# runs), and then does the stage flip the drive would have done. The rule under
# test is run.sh's own, and the assertions below read the CHILD's state.json.
make_run_stub_provenance() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
REAL_RUN="$REPO_ROOT/skills/lcars-run/run.sh"
EOF
  cat >>"$1" <<'EOF'
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="$2"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
echo "run drive $mid" >>"$RUN_LOG"
printf 'env %s WORKER_BIN=%s INTERNAL=%s\n' "$mid" \
  "${LCARS_WORKER_BIN:-<unset>}" "${LCARS_WORKER_BIN_INTERNAL:-<unset>}" >>"$RUN_LOG"
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
state="$gitdir/lcars/missions/$mid/state.json"
# THE REAL RESOLVER, on the CHILD, with whatever environment resolve-logs handed
# us. Host markers are scrubbed so nothing passes for the wrong reason.
env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION -u COPILOT_CLI   bash "$REAL_RUN" resolve-worker --mission "$mid" >>"$RUN_LOG" 2>&1
tmp="$(mktemp)"
awk 'NR==1{print; print "  \"stage\": \"verify\","; next} /"stage"/{next} {print}' "$state" >"$tmp" && mv "$tmp" "$state"
exit 0
EOF
  chmod +x "$1"
}

repoEP="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repoEP/gh"; make_notify_stub "$repoEP/notify"
make_run_stub_provenance "$repoEP/run"; make_worker_stub "$repoEP/worker"
export GH_LOG="$repoEP/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoEP/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoEP/run.log"; : >"$RUN_LOG"
# The PARENT carries the engine (that is where run_child_driver reads it), and
# the CHILD carries the adopt provenance the drive must not erase.
pEP="$repoEP/.git/lcars/missions/lcars-20260601-001/state.json"
cEP="$repoEP/.git/lcars/missions/lcars-20260601-002/state.json"
awk 'NR==1{print; print "  \"workerBin\": \"copilot\","; next} {print}' "$pEP" >"$pEP.t" && mv "$pEP.t" "$pEP"
# All THREE fields, exactly as adopt.sh writes them (workerBin + engineResolved
# + engineSource). The old fixture wrote only two, which was fine against a
# hand-written stub and is not fine against the real recorder: its "adopt said
# this better, keep it" rule compares the RECORDED engineResolved with the bin it
# just resolved, so a fixture missing engineResolved would fail for a reason that
# has nothing to do with this defect.
awk 'NR==1{print; print "  \"workerBin\": \"copilot\",";
           print "  \"engineResolved\": \"copilot\",";
           print "  \"engineSource\": \"adopt-chosen\","; next} {print}' "$cEP" >"$cEP.t" && mv "$cEP.t" "$cEP"
check "S207-2: the fixture really starts at adopt-chosen (a control)" \
  "qgrep '\"engineSource\": *\"adopt-chosen\"' '$cEP'"
rcEP=0
(
  cd "$repoEP"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002" \
  LCARS_GH_BIN="$repoEP/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoEP/notify" \
  LCARS_RUN_SCRIPT="$repoEP/run" LCARS_WORKER_BIN="$repoEP/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >outEP.txt 2>&1
) || rcEP=$?
check "S207-2: a direct resolve-logs drives the child" \
  "qgrep 'run drive lcars-20260601-002' '$RUN_LOG'"
check "S207-2: it pins the parent's engine for the child drive" \
  "qgrep 'WORKER_BIN=copilot' '$RUN_LOG'"
check "S207-2: and MARKS the pin internal (\$LCARS_WORKER_BIN_INTERNAL=1)" \
  "qgrep 'INTERNAL=1' '$RUN_LOG'"
check "S207-2: so the child KEEPS engineSource: adopt-chosen" \
  "qgrep '\"engineSource\": *\"adopt-chosen\"' '$cEP'"
check "S207-2: and it is not rewritten to the operator source 'env'" \
  "! qgrep '\"engineSource\": *\"env\"' '$cEP'"
check "S207-2: the child's state.json still PARSES" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cEP'"

# --- S207 fix round 1 (D1): THE CHILD THAT RECORDS NO ENGINE OF ITS OWN ------
# THIS is the case a fresh tester measured going wrong, on both engines, and the
# case the block above could not see. A bug child filed by `lcars log` with no
# engine in scope carries NO `workerBin`. resolve-logs pins the PARENT's engine
# with the internal marker; run.sh's "an internal pin with nothing behind it"
# arm held the ENGINE (right) but recorded the source as `env` (wrong) — `env`
# means the captain typed $LCARS_WORKER_BIN himself, and he did not. It now
# records `internal`.
#
# The assertion is on the CHILD's own state.json, written by the REAL resolver.
repoEU="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repoEU/gh"; make_notify_stub "$repoEU/notify"
make_run_stub_provenance "$repoEU/run"; make_worker_stub "$repoEU/worker"
export GH_LOG="$repoEU/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoEU/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoEU/run.log"; : >"$RUN_LOG"
pEU="$repoEU/.git/lcars/missions/lcars-20260601-001/state.json"
cEU="$repoEU/.git/lcars/missions/lcars-20260601-002/state.json"
# The PARENT carries the engine; the CHILD carries NOTHING — no workerBin, no
# engineSource. That is what `lcars log` leaves behind.
awk 'NR==1{print; print "  \"workerBin\": \"copilot\","; next} {print}' "$pEU" >"$pEU.t" && mv "$pEU.t" "$pEU"
check "S207-D1: the fixture child really records NO engine (a control)" \
  "! qgrep '\"workerBin\"' '$cEU' && ! qgrep '\"engineSource\"' '$cEU'"
rcEU=0
(
  cd "$repoEU"
  ESCALATE_IDS="" WORKER_ORDER="lcars-20260601-002" \
  LCARS_GH_BIN="$repoEU/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoEU/notify" \
  LCARS_RUN_SCRIPT="$repoEU/run" LCARS_WORKER_BIN="$repoEU/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
    bash "$SCRIPT" "$PARENT" >outEU.txt 2>&1
) || rcEU=$?
check "S207-D1: the child drive really ran the REAL resolver" \
  "qgrep 'WORKER-RESOLVED' '$RUN_LOG'"
check "S207-D1: the ENGINE does not move — the parent's copilot holds" \
  "[ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(\"engineResolved\",\"\"))' '$cEU')\" = 'copilot' ]"
check "S207-D1: the CHILD records \`internal\`, not the captain's \`env\`" \
  "[ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(\"engineSource\",\"\"))' '$cEU')\" = 'internal' ]"
check "S207-D1: the child's state.json PARSES after the write" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$cEU'"

# ==========================================================================
# S204-D1. THE ENGAGED LOCK EXEMPTS NUMBER ONE'S OWN DRIVE, AND NOTHING ELSE.
#
# Number One starts this drive itself and stays `engaged` on the parent for the
# whole of it, which is precisely the state the lock refuses. The exemption is a
# marker NAMING the mission — never a global switch.
# ==========================================================================
echo
echo "S204-D1. the engaged lock vs Number One's own drive"

engage_parent_rl() { # <repo>
  local st="$1/.git/lcars/missions/lcars-20260601-001/state.json"
  python3 - "$st" <<'EOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
out = {}
for k, v in d.items():
    out[k] = v
    if k == "stage":
        out["numberOne"] = {"status": "engaged", "engine": "copilot"}
keys = list(out)
lines = ["{"]
for i, k in enumerate(keys):
    lines.append('  %s: %s%s' % (json.dumps(k), json.dumps(out[k]),
                                 "," if i < len(keys) - 1 else ""))
lines.append("}")
open(p, "w").write("\n".join(lines) + "\n")
EOF
}
RL_REFUSAL="Number One is engaged on this mission on your behalf — stand it down (lcars xo off lcars-20260601-001) to act yourself"

run_rl() { # <repo> <outfile> [env…]
  local repo="$1" out="$2"; shift 2
  ( cd "$repo" \
    && LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repo/notify" \
       LCARS_RUN_SCRIPT="$repo/run" LCARS_WORKER_BIN="$repo/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
       LCARS_XO_SCRIPT=/nonexistent/xo.sh "$@" \
       bash "$SCRIPT" "$PARENT" >"$out" 2>&1 )
}

# CONTROL — not engaged ⇒ the drive runs. Without a row that must PASS the two
# refusals below cannot tell a real lock from a broken fixture.
repoD1a="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repoD1a/gh"; make_notify_stub "$repoD1a/notify"; make_run_stub "$repoD1a/run"; make_worker_stub "$repoD1a/worker"
export GH_LOG="$repoD1a/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD1a/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD1a/run.log"; : >"$RUN_LOG"
rcD1a=0
ESCALATE_IDS="" ERROR_IDS="" run_rl "$repoD1a" "$repoD1a/oD1a.txt" || rcD1a=$?
check "S204-D1. CONTROL: not engaged ⇒ the drive runs" \
  "[ '$rcD1a' -eq 0 ] && ! qgrep 'Number One is engaged' '$repoD1a/oD1a.txt'"

# The CAPTAIN's own `lcars resolve-logs` is still refused — byte for byte.
repoD1b="$(new_repo_with_linked_bugs 1)"; engage_parent_rl "$repoD1b"
make_gh_stub "$repoD1b/gh"; make_notify_stub "$repoD1b/notify"; make_run_stub "$repoD1b/run"; make_worker_stub "$repoD1b/worker"
export GH_LOG="$repoD1b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD1b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD1b/run.log"; : >"$RUN_LOG"
rcD1b=0
ESCALATE_IDS="" ERROR_IDS="" run_rl "$repoD1b" "$repoD1b/oD1b.txt" || rcD1b=$?
check "S204-D1. engaged ⇒ the CAPTAIN's own drive is refused" "[ '$rcD1b' -ne 0 ]"
check "S204-D1. …with the same sentence, byte for byte" \
  "grep -Fqx \"lcars resolve-logs: \$RL_REFUSAL\" '$repoD1b/oD1b.txt'"
check "S204-D1. …and nothing was driven" "[ ! -s '$repoD1b/run.log' ]"

# Number One's own call — the marker names THIS parent.
repoD1c="$(new_repo_with_linked_bugs 1)"; engage_parent_rl "$repoD1c"
make_gh_stub "$repoD1c/gh"; make_notify_stub "$repoD1c/notify"; make_run_stub "$repoD1c/run"; make_worker_stub "$repoD1c/worker"
export GH_LOG="$repoD1c/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD1c/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD1c/run.log"; : >"$RUN_LOG"
rcD1c=0
ESCALATE_IDS="" ERROR_IDS="" LCARS_XO_INTERNAL="$PARENT" \
  run_rl "$repoD1c" "$repoD1c/oD1c.txt" || rcD1c=$?
check "S204-D1. engaged + the marker naming THIS parent ⇒ the drive runs" \
  "[ '$rcD1c' -eq 0 ] && ! qgrep 'Number One is engaged' '$repoD1c/oD1c.txt'"
check "S204-D1. …and it really drove the child" "[ -s '$repoD1c/run.log' ]"

# A marker naming ANOTHER mission exempts nothing.
repoD1d="$(new_repo_with_linked_bugs 1)"; engage_parent_rl "$repoD1d"
make_gh_stub "$repoD1d/gh"; make_notify_stub "$repoD1d/notify"; make_run_stub "$repoD1d/run"; make_worker_stub "$repoD1d/worker"
export GH_LOG="$repoD1d/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD1d/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD1d/run.log"; : >"$RUN_LOG"
rcD1d=0
ESCALATE_IDS="" ERROR_IDS="" LCARS_XO_INTERNAL="lcars-20260601-999" \
  run_rl "$repoD1d" "$repoD1d/oD1d.txt" || rcD1d=$?
check "S204-D1. a marker naming ANOTHER mission does NOT exempt this parent" \
  "[ '$rcD1d' -ne 0 ] && qgrep 'Number One is engaged' '$repoD1d/oD1d.txt'"

# ==========================================================================
# S204-D2. A DRIVE THAT ENDS WITH A STRANDED LOG HANDS THE MISSION BACK.
#
# A child hit its implement cap and parked mid-flight. The drive printed
# "did not reach its Verify gate … resolve it manually" and exited — into
# `xo/resolve.log`, which nobody opens, because Number One starts this drive
# DETACHED. Wave 2 never started and the parent card went on saying work was
# happening, with no gate and no note.
#
# It must raise the parent's existing `reverify-blocked` gate instead, naming
# the log that stopped and what is waiting behind it, and ping once.
# ==========================================================================
echo
echo "S204-D2. a stranded drive hands the mission back"

repoD2="$(new_repo_with_linked_bugs 2)"
make_gh_stub "$repoD2/gh"; make_notify_stub "$repoD2/notify"; make_run_stub "$repoD2/run"; make_worker_stub "$repoD2/worker"
export GH_LOG="$repoD2/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD2/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD2/run.log"; : >"$RUN_LOG"
plant_child_plan "$repoD2/.git/lcars/missions/lcars-20260601-002" "src/shared.py"
plant_child_plan "$repoD2/.git/lcars/missions/lcars-20260601-003" "src/shared.py"
rcD2=0
(
  cd "$repoD2"
  ESCALATE_IDS="" ERROR_IDS="lcars-20260601-002" \
  WORKER_ORDER="lcars-20260601-002 lcars-20260601-003" LCARS_RESOLVE_CONCURRENCY=1 \
  LCARS_GH_BIN="$repoD2/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoD2/notify" \
  LCARS_RUN_SCRIPT="$repoD2/run" LCARS_WORKER_BIN="$repoD2/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT=/nonexistent/xo.sh \
    bash "$SCRIPT" "$PARENT" >outD2.txt 2>&1
) || rcD2=$?
pD2="$repoD2/.git/lcars/missions/lcars-20260601-001"
check "S204-D2. the first log really did strand (mid-flight at implement)" \
  "qgrep '\"stage\": *\"implement\"' '$repoD2/.git/lcars/missions/lcars-20260601-002/state.json'"
check "S204-D2. nothing reached Verify, so the drive still fails loudly" "[ '$rcD2' -ne 0 ]"
check "S204-D2. the PARENT is now awaiting the captain (it was silent before)" \
  "qgrep '\"awaitingHuman\": *true' '$pD2/state.json'"
check "S204-D2. …through the EXISTING reverify-blocked path, not a new one" \
  "[ -f '$pD2/pending.json' ] && qgrep '\"kind\": *\"reverify-blocked\"' '$pD2/pending.json'"
check "S204-D2. the ask NAMES the log that needs him" \
  "qgrep 'lcars-20260601-002' '$pD2/pending.json'"
check "S204-D2. …says where it stopped" \
  "qgrep 'implement' '$pD2/pending.json'"
check "S204-D2. …says what is waiting behind it" \
  "qgrep '1 more log' '$pD2/pending.json'"
check "S204-D2. …and is plain: no 'resolve it manually', no harness words" \
  "! qgrep 'resolve it manually' '$pD2/pending.json'"
check "S204-D2. it says plainly that nothing was folded or shipped" \
  "qgrep -i 'nothing has been folded' '$pD2/pending.json'"
check "S204-D2. the captain is pinged ONCE, on the parent" \
  "[ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ] && qgrep 'mission=lcars-20260601-001' '$NOTIFY_LOG'"
check "S204-D2. the awaiting-human label went on the parent issue" \
  "qgrep 'lcars:awaiting-human' '$GH_LOG'"
check "S204-D2. the parent's state.json still PARSES" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$pD2/state.json'"

# S204-D2b. …AND NUMBER ONE IS TOLD, so the mission stops reading as engaged.
# The gate alone is not enough: while `numberOne.status` is `engaged` the very
# commands the ask names are refused by the engaged lock. resolve-logs hands
# back through `lcars xo answer`, which routes `reverify-blocked` to escalate.
XO_HANDBACK="$TMPROOT/xo-handback.sh"
cat >"$XO_HANDBACK" <<'XH'
#!/usr/bin/env bash
printf 'xo %s\n' "$*" >>"$XO_HANDBACK_LOG"
exit 0
XH
chmod +x "$XO_HANDBACK"

repoD2b="$(new_repo_with_linked_bugs 1)"; engage_parent_rl "$repoD2b"
make_gh_stub "$repoD2b/gh"; make_notify_stub "$repoD2b/notify"; make_run_stub "$repoD2b/run"; make_worker_stub "$repoD2b/worker"
export GH_LOG="$repoD2b/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD2b/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD2b/run.log"; : >"$RUN_LOG"
export XO_HANDBACK_LOG="$repoD2b/xo.log"; : >"$XO_HANDBACK_LOG"
rcD2b=0
(
  cd "$repoD2b"
  ESCALATE_IDS="" ERROR_IDS="lcars-20260601-002" \
  LCARS_GH_BIN="$repoD2b/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoD2b/notify" \
  LCARS_RUN_SCRIPT="$repoD2b/run" LCARS_WORKER_BIN="$repoD2b/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT="$XO_HANDBACK" LCARS_XO_INTERNAL="$PARENT" \
    bash "$SCRIPT" "$PARENT" >outD2b.txt 2>&1
) || rcD2b=$?
check "S204-D2b. Number One is told its drive ended — through its OWN verb" \
  "qgrep '^xo answer --mission lcars-20260601-001\$' '$XO_HANDBACK_LOG'"
check "S204-D2b. …exactly once" \
  "[ \"\$(wc -l <'$XO_HANDBACK_LOG' | tr -d ' ')\" -eq 1 ]"

# S204-D2c. A CAPTAIN RUNNING THIS BY HAND NEVER HIRES HIS FIRST OFFICER.
repoD2c="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repoD2c/gh"; make_notify_stub "$repoD2c/notify"; make_run_stub "$repoD2c/run"; make_worker_stub "$repoD2c/worker"
export GH_LOG="$repoD2c/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoD2c/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoD2c/run.log"; : >"$RUN_LOG"
export XO_HANDBACK_LOG="$repoD2c/xo.log"; : >"$XO_HANDBACK_LOG"
rcD2c=0
(
  cd "$repoD2c"
  ESCALATE_IDS="" ERROR_IDS="lcars-20260601-002" \
  LCARS_GH_BIN="$repoD2c/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoD2c/notify" \
  LCARS_RUN_SCRIPT="$repoD2c/run" LCARS_WORKER_BIN="$repoD2c/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT="$XO_HANDBACK" \
    bash "$SCRIPT" "$PARENT" >outD2c.txt 2>&1
) || rcD2c=$?
check "S204-D2c. no Number One on the mission ⇒ nothing is hired" \
  "[ ! -s '$XO_HANDBACK_LOG' ]"
check "S204-D2c. …but the captain still gets the gate" \
  "qgrep '\"kind\": *\"reverify-blocked\"' '$repoD2c/.git/lcars/missions/lcars-20260601-001/pending.json'"

# ==========================================================================
# S222-A. THE SUCCESS PATH TELLS NUMBER ONE TOO — AND DOES NOT WAIT FOR IT.
#
# THE DEFECT. The captain switches Number One on and walks away. It looks, it
# files the bugs, this drive fixes them and raises the parent's consolidated
# re-verify gate — and then stops dead. Nothing tells the first officer, so the
# single re-grade the captain was promised never fires and the mission sits at a
# gate he has to answer himself. The only automatic road into the re-grade is
# `lcars xo answer` on a `reverify` gate, and nothing was calling it: the drive
# that raises the gate is a DETACHED process that exits the moment it has, and
# no `lcars run` is alive on the parent to notice.
#
# The FAILURE path has handed back since S204 (D2b above). This is the same
# hand-back on the success path — with two differences that matter:
#   * it is DETACHED. A re-check relaunches the build, drives a browser and runs
#     a live worker: minutes. Handing back inline would hold this process open
#     for all of it.
#   * its output is KEPT, beside the mission's other Number One logs, instead of
#     going to /dev/null. `xo/recheck.log` is where the morning's questions get
#     answered from.
# ==========================================================================
echo
echo "S222-A. the success path hands back too — detached, and logged"

# A SLOW stub. The sleep is the whole point: if the hand-back were inline,
# resolve-logs could not possibly have returned before this finishes.
XO_SLOW="$TMPROOT/xo-slow.sh"
cat >"$XO_SLOW" <<'XS'
#!/usr/bin/env bash
sleep 3
printf 'xo %s\n' "$*" >>"$XO_HANDBACK_LOG"
printf 'NUMBER ONE: re-checking\n'
exit 0
XS
chmod +x "$XO_SLOW"

repoA="$(new_repo_with_linked_bugs 1)"; engage_parent_rl "$repoA"
make_gh_stub "$repoA/gh"; make_notify_stub "$repoA/notify"; make_run_stub "$repoA/run"; make_worker_stub "$repoA/worker"
export GH_LOG="$repoA/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoA/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoA/run.log"; : >"$RUN_LOG"
export XO_HANDBACK_LOG="$repoA/xo.log"; : >"$XO_HANDBACK_LOG"
pA="$repoA/.git/lcars/missions/lcars-20260601-001"
rcA=0
(
  cd "$repoA"
  ESCALATE_IDS="" ERROR_IDS="" \
  LCARS_GH_BIN="$repoA/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoA/notify" \
  LCARS_RUN_SCRIPT="$repoA/run" LCARS_WORKER_BIN="$repoA/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT="$XO_SLOW" LCARS_XO_INTERNAL="$PARENT" \
    bash "$SCRIPT" "$PARENT" >outA.txt 2>&1
) || rcA=$?

# THE DETACHMENT PROOF, taken the instant the drive returns: the hand-back has
# NOT finished yet. (Read before anything else below, so nothing can wait for it
# by accident.)
still_running_A=0; [ ! -s "$XO_HANDBACK_LOG" ] && still_running_A=1

check "S222-A. the drive still exits clean" "[ '$rcA' -eq 0 ]"
check "S222-A. REGRESSION: the consolidated re-verify gate is still raised" \
  "qgrep '\"awaitingHuman\": *true' '$pA/state.json' && qgrep '\"kind\": *\"reverify\"' '$pA/pending.json'"
check "S222-A. …and the captain is still pinged exactly once" \
  "[ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ]"
check "S222-A. the drive did NOT block on the re-grade (it was still running)" \
  "[ '$still_running_A' -eq 1 ]"

# …and now let the detached hand-back land.
waitedA=0
while [ ! -s "$XO_HANDBACK_LOG" ] && [ "$waitedA" -lt 30 ]; do sleep 1; waitedA=$((waitedA + 1)); done

check "S222-A. Number One IS told, through its OWN verb" \
  "qgrep '^xo answer --mission lcars-20260601-001\$' '$XO_HANDBACK_LOG'"
check "S222-A. …exactly once" \
  "[ \"\$(wc -l <'$XO_HANDBACK_LOG' | tr -d ' ')\" -eq 1 ]"
check "S222-A. its output is KEPT, beside the mission's other xo logs" \
  "[ -s '$pA/xo/recheck.log' ] && qgrep 'NUMBER ONE: re-checking' '$pA/xo/recheck.log'"

# CONTROL — the captain running this by hand never hires his first officer on
# the success path either. Same stub, same fixture, no engagement on record.
repoAc="$(new_repo_with_linked_bugs 1)"
make_gh_stub "$repoAc/gh"; make_notify_stub "$repoAc/notify"; make_run_stub "$repoAc/run"; make_worker_stub "$repoAc/worker"
export GH_LOG="$repoAc/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoAc/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoAc/run.log"; : >"$RUN_LOG"
export XO_HANDBACK_LOG="$repoAc/xo.log"; : >"$XO_HANDBACK_LOG"
pAc="$repoAc/.git/lcars/missions/lcars-20260601-001"
rcAc=0
(
  cd "$repoAc"
  ESCALATE_IDS="" ERROR_IDS="" \
  LCARS_GH_BIN="$repoAc/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoAc/notify" \
  LCARS_RUN_SCRIPT="$repoAc/run" LCARS_WORKER_BIN="$repoAc/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT="$XO_SLOW" \
    bash "$SCRIPT" "$PARENT" >outAc.txt 2>&1
) || rcAc=$?
sleep 5
check "S222-A. CONTROL: no Number One on the mission ⇒ nothing is hired" \
  "[ ! -s '$XO_HANDBACK_LOG' ] && [ ! -e '$pAc/xo/recheck.log' ]"
check "S222-A. CONTROL: …but the captain still gets his consolidated gate" \
  "qgrep '\"kind\": *\"reverify\"' '$pAc/pending.json'"

# ==========================================================================
# S222-B. A STUCK LOG RAISES A REAL GATE — IT DOES NOT JUST PRINT.
#
# THE INCIDENT (2026-09-19). One logged bug parked at implement asking a
# question; SEVEN were queued behind it. The batch stopped, `pause_at` echoed
# three lines into `xo/resolve.log` — a file nobody opens, because this drive is
# DETACHED — and exited 0. No gate, no label, no ping, no hand-back. The parent
# card went on showing Number One engaged with work in flight. Nothing shipped
# and nothing said so.
#
# The cure is the gate that already exists for the sibling failure:
# `reverify-blocked` — the ONE kind Number One is allowed to hand straight back
# to the captain, because it cannot clear a fold that could not happen. The
# sentence names the log, its question, AND how many are queued behind it: that
# last number is the thing that was invisible on the night.
# ==========================================================================
echo
echo "S222-B. a stuck log raises a real gate"

repoB="$(new_repo_with_linked_bugs 3)"; engage_parent_rl "$repoB"
make_gh_stub "$repoB/gh"; make_notify_stub "$repoB/notify"; make_run_stub "$repoB/run"; make_worker_stub "$repoB/worker"
export GH_LOG="$repoB/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoB/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoB/run.log"; : >"$RUN_LOG"
export XO_HANDBACK_LOG="$repoB/xo.log"; : >"$XO_HANDBACK_LOG"
plant_child_plan "$repoB/.git/lcars/missions/lcars-20260601-002" "src/shared.py"
plant_child_plan "$repoB/.git/lcars/missions/lcars-20260601-003" "src/shared.py"
plant_child_plan "$repoB/.git/lcars/missions/lcars-20260601-004" "src/shared.py"
pB="$repoB/.git/lcars/missions/lcars-20260601-001"
rcB=0
(
  cd "$repoB"
  ESCALATE_IDS="lcars-20260601-003" \
  WORKER_ORDER="lcars-20260601-002 lcars-20260601-003 lcars-20260601-004" \
  LCARS_RESOLVE_CONCURRENCY=1 \
  LCARS_GH_BIN="$repoB/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoB/notify" \
  LCARS_RUN_SCRIPT="$repoB/run" LCARS_WORKER_BIN="$repoB/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT="$XO_HANDBACK" LCARS_XO_INTERNAL="$PARENT" \
    bash "$SCRIPT" "$PARENT" >outB.txt 2>&1
) || rcB=$?
check "S222-B. the batch really did stop at the parked log" \
  "qgrep '\"awaitingHuman\": *true' '$repoB/.git/lcars/missions/lcars-20260601-003/state.json' \
   && ! qgrep 'run drive lcars-20260601-004' '$RUN_LOG'"
check "S222-B. the PARENT is now awaiting the captain (it was silent before)" \
  "qgrep '\"awaitingHuman\": *true' '$pB/state.json'"
check "S222-B. …through the EXISTING reverify-blocked path, not a new kind" \
  "[ -f '$pB/pending.json' ] && qgrep '\"kind\": *\"reverify-blocked\"' '$pB/pending.json'"
check "S222-B. …and NOT the consolidated re-verify gate (nothing is ready)" \
  "! qgrep '\"kind\": *\"reverify\",' '$pB/pending.json'"
check "S222-B. the ask NAMES the log that needs him" \
  "qgrep 'lcars-20260601-003' '$pB/pending.json'"
check "S222-B. …carries the question that log is actually asking" \
  "qgrep 'Ticket T1 failed' '$pB/pending.json'"
check "S222-B. …and says how many are QUEUED BEHIND IT (the invisible number)" \
  "qgrep '1 more log .*queued behind it' '$pB/pending.json'"
check "S222-B. it says plainly that nothing was folded or shipped" \
  "qgrep -i 'nothing has been folded' '$pB/pending.json'"
check "S222-B. the captain is pinged ONCE, on the parent" \
  "[ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ] && qgrep 'mission=lcars-20260601-001' '$NOTIFY_LOG'"
check "S222-B. the awaiting-human label went on the parent issue" \
  "qgrep 'lcars:awaiting-human' '$GH_LOG'"
check "S222-B. Number One is told its drive is over, through its OWN verb" \
  "qgrep '^xo answer --mission lcars-20260601-001\$' '$XO_HANDBACK_LOG'"
check "S222-B. the parent's state.json still PARSES" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$pB/state.json'"
check "S222-B. the not-yet-started log keeps its queued flag (the board shows it waiting)" \
  "qgrep '\"queued\": *true' '$repoB/.git/lcars/missions/lcars-20260601-004/state.json'"

# --- S222-B2. THE TWIN: a log ALREADY parked, found by the pre-check --------
# Same silence, a different door. `resolve-logs` gathers the linked bugs and
# finds one already at awaiting-human from a previous round: it printed the same
# three lines and exited 0, having driven nothing at all.
repoB2="$(new_repo_with_linked_bugs 3)"; engage_parent_rl "$repoB2"
make_gh_stub "$repoB2/gh"; make_notify_stub "$repoB2/notify"; make_run_stub "$repoB2/run"; make_worker_stub "$repoB2/worker"
export GH_LOG="$repoB2/gh.log"; : >"$GH_LOG"; : >"$GH_LOG.n"
export NOTIFY_LOG="$repoB2/notify.log"; : >"$NOTIFY_LOG"
export RUN_LOG="$repoB2/run.log"; : >"$RUN_LOG"
export XO_HANDBACK_LOG="$repoB2/xo.log"; : >"$XO_HANDBACK_LOG"
# 002 arrives already parked, asking something.
b2s="$repoB2/.git/lcars/missions/lcars-20260601-002/state.json"
awk 'NR==1{print; print "  \"awaitingHuman\": true,"; print "  \"pendingQuestion\": \"Which of the two toolbars did you mean?\","; next} {print}' \
  "$b2s" >"$b2s.tmp" && mv "$b2s.tmp" "$b2s"
pB2="$repoB2/.git/lcars/missions/lcars-20260601-001"
rcB2=0
(
  cd "$repoB2"
  ESCALATE_IDS="" ERROR_IDS="" \
  LCARS_GH_BIN="$repoB2/gh" LCARS_GIT_BIN="$(command -v git)" LCARS_NOTIFY="$repoB2/notify" \
  LCARS_RUN_SCRIPT="$repoB2/run" LCARS_WORKER_BIN="$repoB2/worker" LCARS_NOTIFY_NO_DESKTOP=1 \
  LCARS_XO_SCRIPT="$XO_HANDBACK" LCARS_XO_INTERNAL="$PARENT" \
    bash "$SCRIPT" "$PARENT" >outB2.txt 2>&1
) || rcB2=$?
check "S222-B2. the pre-check really did stop the batch (nothing was driven)" \
  "[ ! -s '$RUN_LOG' ]"
check "S222-B2. the PARENT gets the same reverify-blocked gate" \
  "qgrep '\"awaitingHuman\": *true' '$pB2/state.json' \
   && qgrep '\"kind\": *\"reverify-blocked\"' '$pB2/pending.json'"
check "S222-B2. …naming the parked log and its question" \
  "qgrep 'lcars-20260601-002' '$pB2/pending.json' && qgrep 'two toolbars' '$pB2/pending.json'"
check "S222-B2. …and the 2 waiting behind it" \
  "qgrep '2 more logs .*queued behind it' '$pB2/pending.json'"
check "S222-B2. pinged ONCE" \
  "[ \"\$(wc -l <'$NOTIFY_LOG' | tr -d ' ')\" -eq 1 ]"
check "S222-B2. Number One is told" \
  "qgrep '^xo answer --mission lcars-20260601-001\$' '$XO_HANDBACK_LOG'"
check "S222-B2. the parent's state.json still PARSES" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$pB2/state.json'"

# ==========================================================================
echo
printf 'lcars resolve-logs: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
