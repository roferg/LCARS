#!/usr/bin/env bash
#
# Tests for S75 — Verify auto-opens the PR, then drives the in-review → merge
# lifecycle (skill source: skills/lcars-run/run.sh `open-pr` + the `drive`
# verify path; shared PR builders in skills/lcars-approve/pr-lib.sh).
#
# Behaviours under test (the ones run.sh owns; approve/feedback/host-adapter have
# their own suites):
#   1. Verify all-green opens exactly ONE PR (gh pr create with head/base/title/
#      body); a re-run is IDEMPOTENT (no second PR — prUrl already recorded).
#   2. The Mission lands "in review — PR open": prUrl recorded in state.json,
#      review="open", EXACTLY ONE notification fired, stage still verify (NOT done).
#   3. The driver detects a merge (here or on GitHub via gh pr view) → marks Done;
#      an UNMERGED/open PR never → Done (stays in review, no repeat notification).
#
# Everything is stubbed — NO real gh/git/network. The driver lock makes `drive`
# single-instance; each case uses a fresh repo so locks never collide.
#
# Usage: bash tests/lcars-verify-pr.test.sh

set -uo pipefail
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
PR_LIB="$REPO_ROOT/skills/lcars-approve/pr-lib.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260530-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }

# A notify stub that records each ping (one line per call) so we can count them.
make_notify_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "NOTIFY $1 $2 $3" >>"$NOTIFY_LOG"
exit 0
EOF
  chmod +x "$1"
}

# A gh stub. `pr create` echoes a PR URL; `pr view` echoes a merge-state JSON
# driven by $GH_PR_STATE (OPEN|MERGED); everything else records + succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/77"
fi
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  if [ "${GH_PR_STATE:-OPEN}" = "MERGED" ]; then
    echo '{"state":"MERGED","mergedAt":"2026-06-19T10:00:00Z"}'
  else
    echo '{"state":"OPEN","mergedAt":null}'
  fi
fi
exit 0
EOF
  chmod +x "$1"
}

# Build a repo with one mission parked at verify, all tickets green — the shape
# Implement leaves behind (real branch ahead of base + an origin to push to).
new_repo_verify() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'x\n' >f.js && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
  git init -q --bare "$repo.remote.git"
  ( cd "$repo" && git remote add origin "$repo.remote.git" )
  local m="$repo/.git/lcars/missions/$MID"; mkdir -p "$m"
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
  "created": "2026-05-30T10:00:00Z",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  cat >"$m/approved-plan.json" <<'EOF'
[ { "id": "t-001", "title": "Add the dark token set" } ]
EOF
  cat >"$m/waves.json" <<'EOF'
[ { "wave": 1, "tickets": [ { "id": "t-001", "issue": 101 } ] } ]
EOF
  echo "$repo"
}

# Drive a run.sh subcommand inside a repo with all the stub bins injected.
run_in() { # repo  subcommand-and-args…
  local repo="$1"; shift
  ( cd "$repo" \
      && LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="git" \
         LCARS_HOST_ADAPTER="$HOST_ADAPTER" LCARS_PR_LIB="$PR_LIB" \
         LCARS_NOTIFY="$repo/notify" NOTIFY_LOG="$repo/notify.log" \
         GH_LOG="$repo/gh.log" GH_PR_STATE="${GH_PR_STATE:-OPEN}" \
         LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RUN_SH" "$@" )
}

# ==========================================================================
echo "lcars verify-pr (S75)"

[ -f "$RUN_SH" ] || { echo "run.sh not found at $RUN_SH"; exit 1; }
[ -f "$PR_LIB" ] || { echo "pr-lib.sh not found at $PR_LIB"; exit 1; }

# --- Behaviour 1: open-pr opens exactly one PR; re-run is idempotent ----------
r1="$(new_repo_verify)"; make_gh_stub "$r1/gh"; make_notify_stub "$r1/notify"
: >"$r1/gh.log"; : >"$r1/notify.log"
rc1=0; run_in "$r1" open-pr --mission "$MID" >"$r1/out.txt" 2>&1 || rc1=$?
s1="$(state_of "$r1")"
check "1. open-pr exits 0 on an all-green verify mission" "[ '$rc1' -eq 0 ]"
check "1. calls gh pr create" "grep -q 'pr create' '$r1/gh.log'"
check "1. opens the PR from the mission branch (--head)" \
  "grep -q -- '--head lcars/$MID' '$r1/gh.log'"
check "1. targets the base (--base)" "grep -q -- '--base ' '$r1/gh.log'"
check "1. titles the PR from the PRD" "grep -q 'Add dark mode' '$r1/gh.log'"
check "1. PR body summarises the ticket" "grep -q 't-001' '$r1/gh.log'"
check "1. records prUrl in state.json" "grep -q 'pull/77' '$s1'"
check "1. records the review=open sub-state" "grep -q '\"review\": *\"open\"' '$s1'"
check "1. stays at the verify stage (NOT done)" "grep -q '\"stage\": *\"verify\"' '$s1'"
# Idempotent: a second open-pr opens NO new PR.
: >"$r1/gh.log"
run_in "$r1" open-pr --mission "$MID" >"$r1/out2.txt" 2>&1
check "1. a re-run opens NO second PR (idempotent)" "! grep -q 'pr create' '$r1/gh.log'"

# --- Behaviour 2: drive lands "in review — PR open" with ONE notification -----
r2="$(new_repo_verify)"; make_gh_stub "$r2/gh"; make_notify_stub "$r2/notify"
: >"$r2/gh.log"; : >"$r2/notify.log"
GH_PR_STATE=OPEN
rc2=0; run_in "$r2" drive --mission "$MID" >"$r2/out.txt" 2>&1 || rc2=$?
s2="$(state_of "$r2")"
check "2. drive exits 0 (stops in review)" "[ '$rc2' -eq 0 ]"
check "2. drive opened the PR (prUrl recorded)" "grep -q 'pull/77' '$s2'"
check "2. records review=open" "grep -q '\"review\": *\"open\"' '$s2'"
check "2. stays at verify, NOT done" "grep -q '\"stage\": *\"verify\"' '$s2'"
check "2. fired EXACTLY ONE notification" \
  "[ \"\$(grep -c NOTIFY '$r2/notify.log')\" -eq 1 ]"
check "2. the notification says PR open — review & merge" \
  "grep -qi 'review' '$r2/notify.log' && grep -q 'pull/77' '$r2/notify.log'"
check "2. the banner shows the in-review state" \
  "grep -qi 'in review' '$r2/out.txt'"
# A SECOND drive pass on the open PR must NOT re-notify (one ping at open time).
: >"$r2/notify.log"
run_in "$r2" drive --mission "$MID" >"$r2/out3.txt" 2>&1
check "2. a heartbeat on an open PR does NOT re-notify" \
  "[ \"\$(grep -c NOTIFY '$r2/notify.log')\" -eq 0 ]"
check "2. the heartbeat still reports in review (no false done)" \
  "grep -q '\"stage\": *\"verify\"' '$s2'"

# --- Behaviour 3: a merged PR (on GitHub) → Done; unmerged never → Done -------
r3="$(new_repo_verify)"; make_gh_stub "$r3/gh"; make_notify_stub "$r3/notify"
: >"$r3/gh.log"; : >"$r3/notify.log"
# First pass: open the PR (state OPEN), in review.
GH_PR_STATE=OPEN run_in "$r3" drive --mission "$MID" >"$r3/o1.txt" 2>&1
s3="$(state_of "$r3")"
check "3. opened + in review on first pass" \
  "grep -q 'pull/77' '$s3' && grep -q '\"stage\": *\"verify\"' '$s3'"
# Now the PR is merged on GitHub: the next heartbeat detects it → Done.
GH_PR_STATE=MERGED run_in "$r3" drive --mission "$MID" >"$r3/o2.txt" 2>&1
check "3. a merged-on-GitHub PR is detected → stage done" \
  "grep -q '\"stage\": *\"done\"' '$s3'"
check "3. records review=merged on a detected merge" \
  "grep -q '\"review\": *\"merged\"' '$s3'"
check "3. relabels to lcars:done on a detected merge" \
  "grep -q 'add-label lcars:done' '$r3/gh.log'"

# Contrast: an UNMERGED PR never flips to done (re-uses r2 from above).
check "3. an unmerged/open PR never reaches done" \
  "! grep -q '\"stage\": *\"done\"' '$(state_of "$r2")'"

# --- Behaviour 4 (S111 root-tree sovereignty): open-pr NEVER moves HEAD -------
# The old open_pr checked the mission branch out in the shared checkout before
# pushing — the last site that yanked the captain's working tree onto a mission
# branch (caught live at 002's Verify boundary in the S111 proof drive). Push +
# pr-create are ref-based; the checkout must stay wherever the captain left it.
r4="$(new_repo_verify)"; make_gh_stub "$r4/gh"; make_notify_stub "$r4/notify"
head4_before="$(cd "$r4" && git rev-parse --abbrev-ref HEAD)"
run_in "$r4" open-pr --mission "$MID" >"$r4/out.txt" 2>&1 || :
head4_after="$(cd "$r4" && git rev-parse --abbrev-ref HEAD)"
check "4. open-pr leaves the captain's checkout exactly where it was" \
  "[ '$head4_before' = '$head4_after' ]"
check "4. open-pr still opened the PR without the checkout" \
  "grep -q 'pull/77' '$(state_of "$r4")'"

# ==========================================================================
echo
printf 'lcars verify-pr: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
