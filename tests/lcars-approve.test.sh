#!/usr/bin/env bash
#
# Tests for `lcars approve` — the human "ship it" gate at the end of Verify
# (skill source: skills/lcars-approve/approve.sh).
#
# `lcars approve <id>` is the captain's go-ahead after reviewing a verified
# Mission. It is purely mechanical — no LLM:
#   1. opens the PR with `gh pr create`, titled from the PRD and bodied with a
#      summary of the waves/tickets,
#   2. clears the stage labels and marks the Mission lcars:done,
#   3. moves state.json's stage to "done",
#   4. prints the new PR URL.
#
# The behaviours under test (from the build order):
#   2. lcars approve creates a PR with the correct title and body
#   3. lcars approve updates the labels and stage correctly
#
# The script takes its `gh` dependency via env so we can stub it:
#   LCARS_GH_BIN   - the `gh` binary (default: gh)
#
# Usage: bash tests/lcars-approve.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_APPROVE_SCRIPT:-$REPO_ROOT/skills/lcars-approve/approve.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260530-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }

# A fake `gh` that records every call to $GH_LOG (newlines folded so each call
# is one line) and, for `gh pr create`, echoes a PR URL the way real gh does.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/pull/77"
fi
exit 0
EOF
  chmod +x "$1"
}

# Like make_gh_stub, but `gh pr create` FAILS (exit 1, no URL) — stands in for a
# real PR-creation failure (auth, no remote on the forge, API error, …).
make_gh_stub_fail() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "create" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$1"
}

# Build an isolated git repo with one mission parked at "verify" — the exact
# shape `lcars file` → … → Implement leaves behind: a base commit, the Mission's
# own branch (lcars/<id>) carrying a real commit ahead of the base, an `origin`
# remote to push to, and the mission artifacts (PRD, approved plan, wave graph,
# a green result per ticket) with branch + base recorded in state.json.
write_result() { # file ticketId attempts
  cat >"$1" <<EOF
{
  "ticketId": "$2",
  "passed": true,
  "attempts": $3,
  "summary": "Implemented the slice; suite green."
}
EOF
}
new_repo_with_verify_mission() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  # The Mission's branch with a real commit ahead of base (Implement's output).
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'export const theme = "dark";\n' >theme.js \
      && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
  # A bare repo as `origin` so `git push -u origin <branch>` actually works.
  local remote="$repo.remote.git"
  git init -q --bare "$remote"
  ( cd "$repo" && git remote add origin "$remote" )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Type:** feature
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
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  cat >"$m/approved-plan.json" <<'EOF'
[
  {
    "id": "t-001",
    "title": "Add the data-theme attribute and dark token set",
    "description": "Flip data-theme on <html> and wire the dark tokens.",
    "acceptanceCriteria": ["Setting data-theme=dark recolours the page"],
    "estimatedLoc": 120,
    "dependencies": []
  },
  {
    "id": "t-002",
    "title": "Add the theme toggle control",
    "description": "Render a toggle in the nav.",
    "acceptanceCriteria": ["Clicking the toggle flips the active theme"],
    "estimatedLoc": 70,
    "dependencies": []
  },
  {
    "id": "t-003",
    "title": "Persist the theme choice across reloads",
    "description": "Write to localStorage and restore on load.",
    "acceptanceCriteria": ["Choice survives a reload"],
    "estimatedLoc": 80,
    "dependencies": ["t-001"]
  }
]
EOF
  cat >"$m/waves.json" <<'EOF'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 101
      },
      {
        "id": "t-002",
        "issue": 102
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-003",
        "issue": 103
      }
    ]
  }
]
EOF
  local tid
  for tid in t-001 t-002 t-003; do
    mkdir -p "$m/tickets/$tid/tests"; printf 'stub\n' >"$m/tickets/$tid/tests/$tid.test"
    write_result "$m/tickets/$tid/result.json" "$tid" 2
  done
  echo "$repo"
}

# ==========================================================================
echo "lcars approve"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

repoA="$(new_repo_with_verify_mission)"; make_gh_stub "$repoA/gh"
export GH_LOG="$repoA/gh.log"; : >"$GH_LOG"
rcA=0
( cd "$repoA" && LCARS_GH_BIN="$repoA/gh" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcA=$?
sA="$(state_of "$repoA")"
check "A. approve exits 0 on a verified mission" "[ '$rcA' -eq 0 ]"

# --- Behaviour 2: opens a PR with the correct title and a wave/ticket body ---
check "2. calls gh pr create" "grep -q 'pr create' '$GH_LOG'"
check "2. titles the PR from the PRD (Add dark mode)" \
  "grep -q -- '--title Add dark mode' '$GH_LOG' || grep -q 'Add dark mode' '$GH_LOG'"
check "2. PR body summarises the tickets" \
  "grep -q 't-001' '$GH_LOG' && grep -q 't-003' '$GH_LOG'"
check "2. PR body summarises the waves" "grep -qi 'wave' '$GH_LOG'"
check "2. opens the PR from the recorded mission branch (--head)" \
  "grep -q -- '--head lcars/lcars-20260530-001' '$GH_LOG'"
check "2. targets the base branch (--base)" "grep -q -- '--base ' '$GH_LOG'"
check "2. pushes the mission branch to origin" \
  "( cd '$repoA' && git ls-remote --heads origin 'lcars/$MID' | grep -q 'lcars/$MID' )"
check "2. prints the new PR URL" "grep -q 'pull/77' '$repoA/out.txt'"

# --- Behaviour 3: clears the stage labels, marks done, advances the stage ----
check "3. advances the stage to done" \
  "grep -q '\"stage\": *\"done\"' '$sA'"
check "3. adds the lcars:done label" "grep -q 'add-label lcars:done' '$GH_LOG'"
check "3. removes the lcars:verify stage label" \
  "grep -q 'remove-label lcars:verify' '$GH_LOG'"

# --- Behaviour 4: a PR-creation failure must NOT flip the mission to done -----
# A card in the Done column with no PR behind it is a false signal. When
# `gh pr create` fails, approve stays at verify, applies no lcars:done, and
# exits non-zero with an actionable message.
repoAf="$(new_repo_with_verify_mission)"; make_gh_stub_fail "$repoAf/gh"
export GH_LOG="$repoAf/gh.log"; : >"$GH_LOG"
rcAf=0
( cd "$repoAf" && LCARS_GH_BIN="$repoAf/gh" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcAf=$?
check "4. exits non-zero when gh pr create fails" "[ '$rcAf' -ne 0 ]"
check "4. stays at the verify stage (does NOT advance to done)" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoAf")'"
check "4. applies NO lcars:done label on a failed PR" \
  "! grep -q 'add-label lcars:done' '$repoAf/gh.log'"
check "4. prints an actionable error" \
  "grep -qi 'verify' '$repoAf/out.txt'"

# --- Guard: approve refuses a mission that is not at verify -----------------
repoAg="$(new_repo_with_verify_mission)"; make_gh_stub "$repoAg/gh"
export GH_LOG="$repoAg/gh.log"; : >"$GH_LOG"
sed 's/"verify"/"implement"/' "$(state_of "$repoAg")" >"$repoAg/s.tmp" \
  && mv "$repoAg/s.tmp" "$(state_of "$repoAg")"
rcAg=0
( cd "$repoAg" && LCARS_GH_BIN="$repoAg/gh" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcAg=$?
check "guard. approve refuses a non-verify mission" "[ '$rcAg' -ne 0 ]"
check "guard. creates no PR on a non-verify mission" \
  "! grep -q 'pr create' '$repoAg/gh.log'"
check "guard. does not advance a non-verify mission" \
  "! grep -q '\"stage\": *\"done\"' '$(state_of "$repoAg")'"

# --- Guard: a bad mission id is rejected ------------------------------------
repoAb="$(new_repo_with_verify_mission)"; make_gh_stub "$repoAb/gh"
export GH_LOG="$repoAb/gh.log"; : >"$GH_LOG"
rcAb=0
( cd "$repoAb" && LCARS_GH_BIN="$repoAb/gh" bash "$SCRIPT" \
    --mission "no-such-mission" >out.txt 2>&1 ) || rcAb=$?
check "guard. rejects an unknown mission id" "[ '$rcAb' -ne 0 ]"

# ==========================================================================
echo
printf 'lcars approve: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
