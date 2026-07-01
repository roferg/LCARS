#!/usr/bin/env bash
# Fast, SCOPED test for run.sh's validate_plan_json (plan-save subcommand).
#
# Regression for the demo-day Plan bug: the awk validator only recognised an
# INLINE single-line `acceptanceCriteria` array (`["a","b"]`). A Plan worker that
# emitted the SAME array pretty-printed across multiple lines was wrongly rejected
# with "needs at least one acceptance criterion", deadlocking the Plan stage.
#
# This file is deliberately NOT the heavy tests/lcars-run.test.sh — it stands up a
# minimal local-only mission (no githubIssue → gh_relabel is a no-op) and drives
# the REAL validator through `run.sh plan-save`. Runs in well under a second.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# Stand up a fresh git repo with one mission parked at stage "plan".
new_mission() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan" }
JSON
  echo "$repo"
}

run_plan_save() { # repo planfile -> sets RC + OUT
  OUT="$( cd "$1" && bash "$SCRIPT" plan-save --mission test-001 --plan "$2" 2>&1 )"
  RC=$?
}

ticket() { # acceptanceCriteria-block -> full one-ticket plan.json on stdout
  cat <<JSON
[
  {
    "id": "t-001",
    "title": "Do the thing",
    "description": "Build the thing end to end.",
$1
    "estimatedReadLoc": 10,
    "estimatedTestLoc": 10,
    "estimatedNewLoc": 10,
    "dependencies": [],
    "rationale": "It is the foundation."
  }
]
JSON
}

# --- case 1: INLINE array still accepted (regression guard) -----------------
repo="$(new_mission)"; pf="$repo/inline.json"
ticket '    "acceptanceCriteria": ["the thing works"],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "inline acceptanceCriteria advances" \
  || bad "inline acceptanceCriteria advances (rc=$RC: $OUT)"

# --- case 2: MULTI-LINE array accepted (the fix) ----------------------------
repo="$(new_mission)"; pf="$repo/multiline.json"
ticket '    "acceptanceCriteria": [
      "the thing works",
      "the other thing works"
    ],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q "advanced"; } \
  && ok "multi-line acceptanceCriteria advances" \
  || bad "multi-line acceptanceCriteria advances (rc=$RC: $OUT)"

# --- case 3: genuinely EMPTY array still rejected (gate not loosened) --------
repo="$(new_mission)"; pf="$repo/empty.json"
ticket '    "acceptanceCriteria": [
    ],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "acceptance criterion"; } \
  && ok "empty multi-line acceptanceCriteria rejected" \
  || bad "empty multi-line acceptanceCriteria rejected (rc=$RC: $OUT)"

# --- case 4: empty INLINE array still rejected ------------------------------
repo="$(new_mission)"; pf="$repo/emptyinline.json"
ticket '    "acceptanceCriteria": [],' > "$pf"
run_plan_save "$repo" "$pf"
{ [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "acceptance criterion"; } \
  && ok "empty inline acceptanceCriteria rejected" \
  || bad "empty inline acceptanceCriteria rejected (rc=$RC: $OUT)"

echo
printf 'plan-validator: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
