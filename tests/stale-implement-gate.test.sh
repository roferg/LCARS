#!/usr/bin/env bash
# S345: real feedback / Implement / PR boundaries on a temporary flat Git fixture.
set -uo pipefail

ROOT="$PWD"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
fixture="$scratch/fix"
repo="$fixture/repo"
m="$repo/.git/lcars/missions/m-001"
pass=0
fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

[ -d "$repo/.git" ] || {
  bash tests/fixtures/mkflatrepo.sh --dir "$fixture" --files 1 --sleep 0 --tip flat1
}
python3 - "$m/state.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(json.dumps(json.loads(path.read_text()), indent=2) + "\n")
PY
. skills/lcars-init/lcars-state.sh

cat >"$scratch/gh" <<'SH'
#!/usr/bin/env bash
cd "$TEST_ROOT" || exit 1
printf 'gh %s\n' "$*" | tr '\n' ' ' >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case "$*" in *"pr create"*) echo https://github.com/fixture/local/pull/77 ;; esac
exit 0
SH
cat >"$scratch/claude" <<'SH'
#!/usr/bin/env bash
cd "$TEST_ROOT" || exit 1
printf 'dispatch\n' >>"$WORKER_LOG"
echo 'Pure fake: no result and no commit.'
SH
cat >"$scratch/open-pr.sh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
. "$TEST_ROOT/skills/lcars-init/lcars-state.sh"
. "$TEST_ROOT/skills/lcars-approve/pr-lib.sh"
MISSION_ID=m-001
MISSION_DIR=.git/lcars/missions/m-001
STATE="$MISSION_DIR/state.json"
GIT_BIN="${LCARS_GIT_BIN:-git}"
GH_BIN="$LCARS_GH_BIN"
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }
die() { printf 'open_pr: %s\n' "$1" >&2; exit 1; }
host() { bash "$TEST_ROOT/skills/lcars-run/host-adapter.sh" "$@"; }
open_pr
printf 'open_pr passed: %s\n' "$PR_URL"
SH
cat >"$scratch/rebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
wt="$PWD"
out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || { echo 'No scratch output directory in prompt.' >&2; exit 1; }
for path in "$wt" "$out"; do
  case "$path" in
    "$TEST_SCRATCH/"*) ;;
    *) printf 'Fixture path must stay in its temp directory: %s\n' "$path" >&2; exit 1 ;;
  esac
done
printf 'rebuild\n' >>"$WORKER_LOG"
cat >"$wt/tests/s345-feedback.test.js" <<'JS'
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { up } = require('../src/up.js');
test('feedback requires the suffix on up', () => {
  assert.equal(up('hi'), 'HI!');
});
JS
if node --test "$wt/tests/s345-feedback.test.js"; then
  echo 'Fixture must be red before its implementation.' >&2
  exit 1
fi
printf "exports.up = (s) => String(s).toUpperCase() + '!';\n" >"$wt/src/up.js"
node --test "$wt/tests/s345-feedback.test.js"
cat >"$out/result.json" <<'JSON'
{
  "ticketId": "t-001",
  "passed": true,
  "attempts": 1,
  "summary": "Implement the feedback suffix",
  "newTests": ["tests/s345-feedback.test.js"],
  "testEdits": [],
  "flipFlop": "expected"
}
JSON
SH
chmod +x "$scratch/rebuild"
chmod +x "$scratch/gh" "$scratch/claude"
cp "$scratch/claude" "$scratch/copilot"
export TEST_MKTEMP_BIN="$(command -v mktemp)"
cat >"$scratch/mktemp" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
template=0
for arg in "$@"; do
  case "$arg" in -*) ;; *) template=1 ;; esac
done
[ "$template" -eq 1 ] || args+=("$TMPDIR/tmp.XXXXXX")
exec "$TEST_MKTEMP_BIN" "${args[@]}"
SH
cat >"$scratch/age-git" <<'SH'
#!/usr/bin/env bash
if [ "${GIT_FAIL_TIP_READ:-0}" = 1 ]; then
  case "$*" in 'rev-parse --verify refs/heads/'*) exit 98 ;; esac
fi
case "$*" in 'show -s --format=%ar '*) exit 97 ;; esac
exec /usr/bin/git "$@"
SH
chmod +x "$scratch/age-git"
chmod +x "$scratch/mktemp" "$scratch/copilot"
export TEST_ROOT="$ROOT" GH_LOG="$scratch/gh.log" WORKER_LOG="$scratch/worker.log"
export TEST_SCRATCH="$scratch"
export LCARS_GH_BIN="$scratch/gh" LCARS_WORKER_BIN="$scratch/claude"
export LCARS_WORKER_CLI=claude LCARS_OWNER_ENFORCE=0 LCARS_XO_ENFORCE=0
export LCARS_NOTIFY_NO_DESKTOP=1
mkdir -p "$scratch/tmp"
export TMPDIR="$scratch/tmp"
export PATH="$scratch:$PATH"

in_repo() {
  python3 - "$repo" "$1" "${@:2}" <<'PY'
import subprocess, sys
from pathlib import Path
sys.exit(subprocess.call(["bash", str(Path(sys.argv[2]).resolve()), *sys.argv[3:]],
                         cwd=sys.argv[1]))
PY
}
state() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' \
    "$m/state.json" "$1"
}
prepare() {
  if [ ! -d "$fixture/pristine" ]; then
    git -C "$repo" branch s345-base HEAD^
    git -C "$repo" branch lcars/m-001 HEAD
    lcars_state_set_string "$m/state.json" branch lcars/m-001
    lcars_state_set_string "$m/state.json" base s345-base
    lcars_state_set "$m/state.json" githubIssue 42
    cp -R "$m" "$fixture/pristine"
  fi
  rm -rf "$m/tickets" "$m/manifests"
  cp -R "$fixture/pristine/." "$m/"
  for key in prUrl prNumber review awaitingHuman pendingQuestion rejectedTip rejectedTipAt parentMission; do
    lcars_state_unset "$m/state.json" "$key"
  done
  rm -f "$m/feedback.md" "$m/events.jsonl" "$m/comments.json" "$m/pending.json"
  lcars_state_set_string "$m/state.json" stage implement
  lcars_state_set_string "$m/state.json" type feature
  git -C "$repo" remote set-url origin "$fixture/remote.git"
  if ! git --git-dir="$fixture/remote.git" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
    git -C "$repo" push -q origin s345-base:main
  fi
  if [ ! -f "$m/approved-plan.json" ]; then
    cat >"$m/approved-plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Implement feedback",
    "dependencies": []
  }
]
JSON
  fi
  cat >"$m/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 101
      }
    ]
  }
]
JSON
  mkdir -p "$m/manifests" "$m/research"
  printf '# t-001\nRebuild the rejected up implementation.\n' >"$m/manifests/t-001.md"
  printf '# Mission: flat-slow fixture mission\n' >"$m/prd.md"
  printf 'preserved research\n' >"$m/research/s345-history.txt"
  cp "$m/approved-plan.json" "$m/plan.json"
  printf '# Fixture context\nFlat JavaScript repo.\n' >"$repo/.git/lcars/context-pack.md"
  : >"$GH_LOG"
  : >"$WORKER_LOG"
}
feedback() {
  lcars_state_set_string "$m/state.json" stage verify
  lcars_state_set_string "$m/state.json" prUrl https://github.com/fixture/local/pull/76
  lcars_state_set "$m/state.json" prNumber 76
  feedback_rc=0
  in_repo skills/lcars-feedback/feedback.sh --mission m-001 \
    --feedback 'S345: reject the existing tip' >"$scratch/feedback.out" 2>&1 || feedback_rc=$?
}
reschedule() {
  cp "$scratch/waves.json" "$m/waves.json"
  mkdir -p "$m/manifests"
  cp "$scratch/manifest.md" "$m/manifests/t-001.md"
  lcars_state_set_string "$m/state.json" stage implement
}

echo 'stale implement gate'
prepare
cp "$m/waves.json" "$scratch/waves.json"
cp "$m/manifests/t-001.md" "$scratch/manifest.md"
cp "$m/prd.md" "$scratch/prd.md"
cp "$m/plan.json" "$scratch/plan.json"
cp "$m/approved-plan.json" "$scratch/approved-plan.json"
tip="$(git -C "$repo" rev-parse lcars/m-001)"
feedback
check '1. top-level send-back clears only implement results' \
  "[ '$feedback_rc' -eq 0 ] && [ ! -e '$m/tickets' ] && [ ! -e '$m/manifests' ] && [ ! -e '$m/waves.json' ]"
check '1. S178 history survives byte-for-byte' \
  "cmp -s '$scratch/prd.md' '$m/prd.md' && cmp -s '$scratch/plan.json' '$m/plan.json' && cmp -s '$scratch/approved-plan.json' '$m/approved-plan.json' && [ -f '$m/research/s345-history.txt' ] && [ -f '$m/feedback.md' ]"
reschedule
implement_rc=0
in_repo skills/lcars-run/run.sh implement --mission m-001 \
  >"$scratch/implement.out" 2>&1 || implement_rc=$?
dispatches="$(wc -l <"$WORKER_LOG" | tr -d ' ')"
check '1. re-entered Implement dispatches for the scheduled ticket' \
  "[ '$implement_rc' -eq 0 ] && [ '$dispatches' -eq 3 ] && [ '$(state stage)' = implement ]"
printf 'EVIDENCE 1: feedback rc=%s; implement rc=%s; tickets=1 dispatches=%s; tip=%s; stage=%s\n' \
  "$feedback_rc" "$implement_rc" "$dispatches" "$tip" "$(state stage)"

prepare
cp "$m/tickets/t-001/result.json" "$scratch/result.json"
git -C "$repo" checkout -q s345-base
feedback
check '2. send-back records the mission branch tip, not ambient HEAD' \
  "[ '$feedback_rc' -eq 0 ] && [ '$(state rejectedTip)' = '$tip' ] && [ '$(git -C "$repo" rev-parse HEAD)' != '$tip' ]"
git -C "$repo" checkout -q lcars/m-001
reschedule
# A fresh success claim without a new commit reproduces the production bypass.
mkdir -p "$m/tickets/t-001"
cp "$scratch/result.json" "$m/tickets/t-001/result.json"
advance_rc=0
in_repo skills/lcars-run/run.sh impl-advance --mission m-001 \
  >"$scratch/advance.out" 2>&1 || advance_rc=$?
check '2. unchanged rejected tip cannot leave Implement' \
  "[ '$advance_rc' -eq 1 ] && [ '$(state stage)' = implement ]"
check '2. refusal names the SHA, its age, and one remedy' \
  "grep -Fxq \"lcars run: tip $tip (committed $(git -C "$repo" show -s --format=%ar "$tip")) is unchanged since send-back — implement the feedback and commit new work on 'lcars/m-001'. Mission stays at implement.\" '$scratch/advance.out'"
printf 'EVIDENCE 2: feedback rc=%s; recorded=%s; tip=%s; advance rc=%s stage=%s; dispatches=%s\n' \
  "$feedback_rc" "$(state rejectedTip)" "$(git -C "$repo" rev-parse lcars/m-001)" \
  "$advance_rc" "$(state stage)" "$(wc -l <"$WORKER_LOG" | tr -d ' ')"
cat "$scratch/advance.out"

unknown_age_rc=0
LCARS_GIT_BIN="$scratch/age-git" in_repo skills/lcars-run/run.sh impl-advance --mission m-001 \
  >"$scratch/unknown-age.out" 2>&1 || unknown_age_rc=$?
check '2. unknown commit age stays an explicit actionable refusal' \
  "[ '$unknown_age_rc' -eq 1 ] && grep -Fq 'tip $tip (age unknown' '$scratch/unknown-age.out' && grep -Fq \"implement the feedback and commit new work on 'lcars/m-001'\" '$scratch/unknown-age.out'"
lcars_state_set_string "$m/state.json" branch s345-missing
missing_rc=0
in_repo skills/lcars-run/run.sh impl-advance --mission m-001 \
  >"$scratch/missing.out" 2>&1 || missing_rc=$?
check '2. unreadable branch names the recorded tip and unknown age' \
  "[ '$missing_rc' -eq 1 ] && grep -Fq 'tip $tip (age unknown' '$scratch/missing.out' && grep -Fq \"restore mission branch 's345-missing' before retrying\" '$scratch/missing.out'"
cat "$scratch/unknown-age.out" "$scratch/missing.out"
lcars_state_set_string "$m/state.json" branch ""
empty_rc=0
in_repo skills/lcars-run/run.sh impl-advance --mission m-001 \
  >"$scratch/empty-advance.out" 2>&1 || empty_rc=$?
check '2. empty branch refuses with the rejected SHA and a recorded-branch remedy, never empty quotes' \
  "[ '$empty_rc' -eq 1 ] && [ '$(state stage)' = implement ] && grep -Fq 'rejected tip $tip (age unknown: mission has no branch recorded) cannot be checked' '$scratch/empty-advance.out' && grep -Fq 'restore the branch in state.json before retrying' '$scratch/empty-advance.out' && ! grep -Fq \"''\" '$scratch/empty-advance.out'"
printf 'EVIDENCE FIX1 impl-advance: rc=%s\n' "$empty_rc"
cat "$scratch/empty-advance.out"
lcars_state_set_string "$m/state.json" branch lcars/m-001

# Clear prUrl before EVERY precondition probe; otherwise idempotency hides it.
lcars_state_unset "$m/state.json" prUrl
lcars_state_unset "$m/state.json" rejectedTip
lcars_state_set_string "$m/state.json" base lcars/m-001
control_rc=0
in_repo "$scratch/open-pr.sh" >"$scratch/pr-control.out" 2>&1 || control_rc=$?
check '3. harness sees a real zero-ahead precondition refusal' \
  "[ '$control_rc' -eq 1 ] && grep -q 'no commits .* ahead' '$scratch/pr-control.out' && [ -z '$(state prUrl)' ]"
lcars_state_set_string "$m/state.json" base s345-base
lcars_state_set_string "$m/state.json" rejectedTip "$tip"
lcars_state_unset "$m/state.json" prUrl
: >"$GH_LOG"
remote_before="$(git --git-dir="$fixture/remote.git" show-ref)"
pr_rc=0
in_repo "$scratch/open-pr.sh" >"$scratch/pr.out" 2>&1 || pr_rc=$?
ahead="$(git -C "$repo" rev-list --count s345-base..lcars/m-001)"
remote_after="$(git --git-dir="$fixture/remote.git" show-ref)"
check '3. no second PR or push over an unchanged rejected tip with old commits ahead' \
  "[ '$pr_rc' -eq 1 ] && [ '$ahead' -gt 0 ] && [ -z '$(state prUrl)' ] && ! grep -q 'pr create' '$GH_LOG' && [ '$remote_before' = '$remote_after' ]"
check '3. PR refusal names the SHA, age and one remedy' \
  "grep -Fxq \"open_pr: tip $tip (committed $(git -C "$repo" show -s --format=%ar "$tip")) is unchanged since send-back — implement the feedback and commit new work on 'lcars/m-001'. Mission stays at verify.\" '$scratch/pr.out'"
printf 'EVIDENCE 3: zero-ahead control rc=%s; open_pr rc=%s; ahead=%s tip=%s; prUrl=%s; remote before=%s after=%s\n' \
  "$control_rc" "$pr_rc" "$ahead" "$tip" "$(state prUrl)" "$remote_before" "$remote_after"
cat "$scratch/pr.out"

unknown_pr_rc=0
LCARS_GIT_BIN="$scratch/age-git" in_repo "$scratch/open-pr.sh" \
  >"$scratch/unknown-pr-age.out" 2>&1 || unknown_pr_rc=$?
check '3. unknown PR tip age stays an explicit actionable refusal' \
  "[ '$unknown_pr_rc' -eq 1 ] && grep -Fq 'tip $tip (age unknown' '$scratch/unknown-pr-age.out' && grep -Fq \"implement the feedback and commit new work on 'lcars/m-001'\" '$scratch/unknown-pr-age.out'"
missing_pr_rc=0
GIT_FAIL_TIP_READ=1 LCARS_GIT_BIN="$scratch/age-git" in_repo "$scratch/open-pr.sh" \
  >"$scratch/missing-pr.out" 2>&1 || missing_pr_rc=$?
check '3. PR branch-read failure names the rejected tip and unknown age' \
  "[ '$missing_pr_rc' -eq 1 ] && grep -Fq 'tip $tip (age unknown' '$scratch/missing-pr.out' && grep -Fq \"restore mission branch 'lcars/m-001' before retrying\" '$scratch/missing-pr.out'"
cat "$scratch/unknown-pr-age.out" "$scratch/missing-pr.out"
lcars_state_set_string "$m/state.json" branch ""
empty_pr_rc=0
in_repo "$scratch/open-pr.sh" >"$scratch/empty-pr.out" 2>&1 || empty_pr_rc=$?
check '3. empty PR branch refuses with the rejected SHA and a recorded-branch remedy, never empty quotes' \
  "[ '$empty_pr_rc' -eq 1 ] && [ -z '$(state prUrl)' ] && ! grep -q 'pr create' '$GH_LOG' && grep -Fq 'rejected tip $tip (age unknown: mission has no branch recorded) cannot be checked' '$scratch/empty-pr.out' && grep -Fq 'restore the branch in state.json before retrying' '$scratch/empty-pr.out' && ! grep -Fq \"''\" '$scratch/empty-pr.out'"
printf 'EVIDENCE FIX1 open_pr: rc=%s\n' "$empty_pr_rc"
cat "$scratch/empty-pr.out"
lcars_state_set_string "$m/state.json" branch lcars/m-001
lcars_state_set_string "$m/state.json" prUrl https://github.com/fixture/local/pull/77
existing_rc=0
in_repo "$scratch/open-pr.sh" >"$scratch/existing-pr.out" 2>&1 || existing_rc=$?
check '3. an already-recorded PR remains idempotent even at the rejected tip' \
  "[ '$existing_rc' -eq 0 ] && [ '$(state prUrl)' = https://github.com/fixture/local/pull/77 ] && ! grep -q 'pr create' '$GH_LOG'"
lcars_state_unset "$m/state.json" prUrl

prepare
positive_branch="s345-positive-${scratch##*.}"
git -C "$repo" branch "$positive_branch" lcars/m-001
lcars_state_set_string "$m/state.json" branch "$positive_branch"
feedback
reschedule
positive_rc=0
LCARS_WORKER_BIN="$scratch/rebuild" in_repo skills/lcars-run/run.sh implement --mission m-001 \
  >"$scratch/positive.out" 2>&1 || positive_rc=$?
positive_tip="$(git -C "$repo" rev-parse "$positive_branch")"
check '4. a real successful rebuild moves the tip and advances to Verify' \
  "[ '$positive_rc' -eq 0 ] && [ '$positive_tip' != '$tip' ] && [ '$(state stage)' = verify ]"
positive_pr_rc=0
lcars_state_unset "$m/state.json" prUrl
in_repo "$scratch/open-pr.sh" >"$scratch/positive-pr.out" 2>&1 || positive_pr_rc=$?
check '4. rebuilt mission opens its PR exactly once' \
  "[ '$positive_pr_rc' -eq 0 ] && [ '$(state prUrl)' = https://github.com/fixture/local/pull/77 ] && [ '$(grep -c 'pr create' "$GH_LOG")' -eq 1 ]"
printf 'EVIDENCE 4: rejected=%s; new tip=%s; implement rc=%s stage=%s; open_pr rc=%s; dispatches=%s; branch=%s\n' \
  "$tip" "$positive_tip" "$positive_rc" "$(state stage)" "$positive_pr_rc" \
  "$(wc -l <"$WORKER_LOG" | tr -d ' ')" "$positive_branch"
cat "$scratch/positive.out" "$scratch/positive-pr.out"

prepare
cp "$m/state.json" "$scratch/expected-state.json"
lcars_state_set_string "$scratch/expected-state.json" stage verify
first_rc=0
in_repo skills/lcars-run/run.sh impl-advance --mission m-001 \
  >"$scratch/first.out" 2>&1 || first_rc=$?
printf 'IMPLEMENT: advanced\n  Every ticket passed across all waves. Stage:  verify\n' \
  >"$scratch/expected-advance.out"
check '5. never-sent-back advance is byte-for-byte unchanged' \
  "[ '$first_rc' -eq 0 ] && cmp -s '$scratch/expected-advance.out' '$scratch/first.out' && cmp -s '$scratch/expected-state.json' '$m/state.json' && [ ! -e '$m/feedback.md' ] && [ -z '$(state rejectedTip)' ]"
first_pr_rc=0
in_repo "$scratch/open-pr.sh" >"$scratch/first-pr.out" 2>&1 || first_pr_rc=$?
printf 'open_pr passed: https://github.com/fixture/local/pull/77\n' \
  >"$scratch/expected-pr.out"
check '5. never-sent-back PR succeeds without any new refusal or dispatch' \
  "[ '$first_pr_rc' -eq 0 ] && cmp -s '$scratch/expected-pr.out' '$scratch/first-pr.out' && [ ! -s '$WORKER_LOG' ] && [ -z '$(state rejectedTip)' ]"
printf 'EVIDENCE 5: advance rc=%s; open_pr rc=%s; tip=%s; dispatches=%s; stdout and advance state match baseline bytes\n' \
  "$first_rc" "$first_pr_rc" "$(git -C "$repo" rev-parse lcars/m-001)" \
  "$(wc -l <"$WORKER_LOG" | tr -d ' ')"

prepare
lcars_state_set_string "$m/state.json" type bug
lcars_state_set_string "$m/state.json" parentMission m-parent
feedback
check '6. logged-bug send-back keeps its Plan reset and artifact invalidation' \
  "[ '$feedback_rc' -eq 0 ] && [ '$(state stage)' = plan ] && [ ! -e '$m/tickets' ] && [ ! -e '$m/manifests' ] && [ ! -e '$m/waves.json' ] && [ ! -e '$m/plan.json' ] && [ ! -e '$m/approved-plan.json' ] && grep -q 'S345: reject' '$m/prd.md' && [ -z '$(state rejectedTip)' ] && ! grep -q 'pr close' '$GH_LOG'"
reschedule
cp "$scratch/approved-plan.json" "$m/approved-plan.json"
mkdir -p "$m/tickets/t-001"
cp "$scratch/result.json" "$m/tickets/t-001/result.json"
bug_rc=0
in_repo skills/lcars-run/run.sh impl-advance --mission m-001 \
  >"$scratch/bug-advance.out" 2>&1 || bug_rc=$?
bug_pr_rc=0
in_repo skills/lcars-run/run.sh open-pr --mission m-001 \
  >"$scratch/bug-pr.out" 2>&1 || bug_pr_rc=$?
check '6. logged bug gains no unchanged-tip refusal or per-bug PR' \
  "[ '$bug_rc' -eq 0 ] && [ '$(state stage)' = verify ] && [ '$bug_pr_rc' -eq 0 ] && grep -q 'OPEN-PR: skipped' '$scratch/bug-pr.out' && ! grep -q 'pr create' '$GH_LOG'"
printf 'EVIDENCE 6: feedback rc=%s -> plan; advance rc=%s -> %s; open-pr rc=%s skipped; rejectedTip absent; tip=%s\n' \
  "$feedback_rc" "$bug_rc" "$(state stage)" "$bug_pr_rc" "$(git -C "$repo" rev-parse lcars/m-001)"

echo
printf 'stale implement gate: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
