#!/usr/bin/env bash
#
# Tests for `lcars feedback` — the Verify feedback loop back to Align
# (skill source: skills/lcars-feedback/feedback.sh).
#
# `lcars feedback <id> "<feedback>"` is the captain's "send it back" at Verify.
# It is purely mechanical — no LLM:
#   1. appends the feedback to feedback.md (a durable, accumulating history),
#   2. resets state.json's stage to "align",
#   3. moves the GitHub label to lcars:align,
# so the next `lcars run <id>` re-enters Align with the full prior history
# (the PRD, the research/plan artifacts, and every feedback note) still on disk.
#
# The behaviours under test (from the build order):
#   4. lcars feedback saves the feedback and resets to the align stage
#   5. After feedback, the prior context survives so lcars run re-enters Align
#
# Dependencies are taken via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary    (default: gh)
#   LCARS_NOW      - ISO stamp for the feedback entry (default: now, UTC)
#
# Usage: bash tests/lcars-feedback.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_FEEDBACK_SCRIPT:-$REPO_ROOT/skills/lcars-feedback/feedback.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260530-001"
state_of() { echo "$1/.git/lcars/missions/$MID/state.json"; }

# A fake `gh` that records every call to $GH_LOG and otherwise succeeds. Folds
# newlines so each call is one line (the host adapter shells `gh pr close …`).
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# Build an isolated git repo with a mission parked at "verify", carrying the
# artifacts every prior stage left behind (PRD, research, validated plan,
# approved plan) — the "full history" Align must still see after a bounce-back.
new_repo_with_verify_mission() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m/research"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
EOF
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42
}
EOF
  printf '{ "question": "q", "recommendation": "r", "supporting_points": ["a"] }\n' \
    >"$m/research/1.json"
  printf '# Validated Plan: Add dark mode\n\n## Synthesis\nx\n\n## Decisions\n- y\n' \
    >"$m/validated-plan.md"
  printf '[ { "id": "t-001" } ]\n' >"$m/approved-plan.json"
  echo "$repo"
}

# ==========================================================================
echo "lcars feedback"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

repoF="$(new_repo_with_verify_mission)"; make_gh_stub "$repoF/gh"
export GH_LOG="$repoF/gh.log"; : >"$GH_LOG"
FB1="The toggle does not persist on Safari."
rcF=0
( cd "$repoF" && LCARS_GH_BIN="$repoF/gh" LCARS_NOW="2026-06-01T12:00:00Z" \
    bash "$SCRIPT" --mission "$MID" --feedback "$FB1" >out.txt 2>&1 ) || rcF=$?
sF="$(state_of "$repoF")"
FBMD="$repoF/.git/lcars/missions/$MID/feedback.md"
check "F. feedback exits 0" "[ '$rcF' -eq 0 ]"

# --- Behaviour 4: saves the feedback, resets the stage to align -------------
check "4. writes feedback.md" "[ -f '$FBMD' ]"
check "4. feedback.md carries the captain's note" \
  "grep -q 'does not persist on Safari' '$FBMD'"
check "4. resets the stage to align" "grep -q '\"stage\": *\"align\"' '$sF'"
check "4. relabels back to align (adds lcars:align)" \
  "grep -q 'add-label lcars:align' '$repoF/gh.log'"
check "4. relabels back to align (removes lcars:verify)" \
  "grep -q 'remove-label lcars:verify' '$repoF/gh.log'"

# --- Behaviour 5: the prior context survives for the re-entered Align -------
# Align re-grills with the FULL history: the PRD and every earlier artifact are
# left intact, and feedback.md is there to steer the next pass.
check "5. leaves the PRD intact for Align" \
  "[ -f '$repoF/.git/lcars/missions/$MID/prd.md' ]"
check "5. leaves the research findings intact" \
  "[ -f '$repoF/.git/lcars/missions/$MID/research/1.json' ]"
check "5. leaves the approved plan intact" \
  "[ -f '$repoF/.git/lcars/missions/$MID/approved-plan.json' ]"

# A second round of feedback APPENDS — feedback.md is a growing history, not a
# single overwritten note, so Align sees every bounce-back.
( cd "$repoF" && LCARS_GH_BIN="$repoF/gh" LCARS_NOW="2026-06-02T09:00:00Z" \
    bash "$SCRIPT" --mission "$MID" --feedback "Also the icon is wrong." >out2.txt 2>&1 )
check "5. a second feedback note is appended, not overwritten" \
  "grep -q 'does not persist on Safari' '$FBMD' && grep -q 'icon is wrong' '$FBMD'"

# --- S75: send-back CLOSES the open PR and clears the recorded PR -------------
# When a Mission bounced back from Verify has an open PR, feedback must close it
# (so it doesn't linger) and clear prUrl/prNumber/review, so a re-entry to Verify
# opens a FRESH PR. The note still lands and the stage still resets to align.
new_repo_with_open_pr() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
EOF
  cat >"$m/state.json" <<'EOF'
{
  "id": "lcars-20260530-001",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "review": "open",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "prNumber": 77,
  "created": "2026-05-30T10:00:00Z",
  "githubIssue": 42,
  "branch": "lcars/lcars-20260530-001",
  "base": "main"
}
EOF
  echo "$repo"
}
repoP="$(new_repo_with_open_pr)"; make_gh_stub "$repoP/gh"
export GH_LOG="$repoP/gh.log"; : >"$GH_LOG"
rcP=0
( cd "$repoP" && LCARS_GH_BIN="$repoP/gh" LCARS_NOW="2026-06-03T09:00:00Z" \
    bash "$SCRIPT" --mission "$MID" --feedback "Regressed on Safari." >out.txt 2>&1 ) || rcP=$?
sP="$(state_of "$repoP")"
check "S75. feedback exits 0 with an open PR" "[ '$rcP' -eq 0 ]"
check "S75. closes the open PR (gh pr close 77)" "grep -q 'pr close 77' '$repoP/gh.log'"
check "S75. clears the recorded prUrl" "! grep -q 'prUrl' '$sP'"
check "S75. clears the recorded prNumber" "! grep -q 'prNumber' '$sP'"
check "S75. clears the review marker" "! grep -q '\"review\"' '$sP'"
check "S75. still resets the stage to align" "grep -q '\"stage\": *\"align\"' '$sP'"
check "S75. still appends the feedback note" "grep -q 'Regressed on Safari' '$repoP/.git/lcars/missions/$MID/feedback.md'"

# --- Guard: a bad mission id is rejected ------------------------------------
repoFg="$(new_repo_with_verify_mission)"; make_gh_stub "$repoFg/gh"
export GH_LOG="$repoFg/gh.log"; : >"$GH_LOG"
rcFg=0
( cd "$repoFg" && LCARS_GH_BIN="$repoFg/gh" bash "$SCRIPT" \
    --mission "no-such-mission" --feedback "x" >out.txt 2>&1 ) || rcFg=$?
check "guard. rejects an unknown mission id" "[ '$rcFg' -ne 0 ]"

# --- Guard: empty feedback is rejected --------------------------------------
repoFe="$(new_repo_with_verify_mission)"; make_gh_stub "$repoFe/gh"
export GH_LOG="$repoFe/gh.log"; : >"$GH_LOG"
rcFe=0
( cd "$repoFe" && LCARS_GH_BIN="$repoFe/gh" bash "$SCRIPT" \
    --mission "$MID" --feedback "" >out.txt 2>&1 ) || rcFe=$?
check "guard. rejects empty feedback" "[ '$rcFe' -ne 0 ]"
check "guard. does not reset the stage when feedback is empty" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoFe")'"

# ==========================================================================
echo
printf 'lcars feedback: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
