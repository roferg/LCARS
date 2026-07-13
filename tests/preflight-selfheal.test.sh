#!/usr/bin/env bash
# Fast, SCOPED test for the S133 preflight runner SELF-HEAL (skill source:
# skills/lcars-run/run.sh — preflight_runner_or_heal / worktree_setup_configured).
#
# The defect (caught live on groutwork, logged-bug lcars-20260713-003): a ticket's
# worktree provisioning silently didn't take (no node_modules → the test runner
# could not launch), so the S111 preflight parked the ticket at an un-answerable
# human gate. Answering could not conjure a runner, so it re-parked every time.
#
# The fix: before escalating a dead runner, RE-APPLY the captain's OWN declared
# `worktreeSetupCommand` ONCE and re-probe. A silent/transient miss then clears
# itself; only a runner that STILL cannot launch after honestly re-applying the
# declared provisioning escalates.
#
# Drives the REAL `preflight-heal-test` hook with an env-injected testCommand
# ($LCARS_TEST_CMD) and worktreeSetupCommand ($LCARS_WORKTREE_SETUP_CMD). A FAKE
# runner that is "dead" until a marker exists + a setup command that creates the
# marker proves the heal end to end. No real runner, no tokens.
#
# Usage: bash tests/preflight-selfheal.test.sh
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# A minimal local-only mission parked at implement.
new_mission() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions/test-001"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "bug", "title": "t", "stage": "implement", "branch": "" }
JSON
  echo "$repo"
}

# heal <repo> <posarg-dir> <env...> -> sets OUT
heal() { # repo  dir  extra-env
  local repo="$1" dir="$2" env="$3"
  OUT="$( cd "$repo" && eval "$env" LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            bash "$SCRIPT" preflight-heal-test --mission test-001 "$dir" 2>&1 )"
}

evjson() { grep -c "$1" "$2/.git/lcars/missions/test-001/events.jsonl" 2>/dev/null || echo 0; }

echo "S133 preflight self-heal — re-apply the declared worktreeSetupCommand before escalating"

# --- A: runner launches first try → PREFLIGHT=ok (no heal, byte-identical) -----
repo="$(new_mission)"
heal "$repo" "$repo" 'LCARS_TEST_CMD="exit 0"'
printf '%s' "$OUT" | grep -q "PREFLIGHT=ok" \
  && ok "A. live runner → PREFLIGHT=ok (no heal attempted)" \
  || bad "A. expected PREFLIGHT=ok (got: $OUT)"

# --- B: dead runner, NO worktree/setup → escalates (PREFLIGHT=dead) ------------
repo="$(new_mission)"
heal "$repo" "$repo" 'LCARS_TEST_CMD='\''printf "sh: vitest: command not found\n" >&2; exit 127'\'''
printf '%s' "$OUT" | grep -q "PREFLIGHT=dead" \
  && ok "B. dead runner + no declared setup → PREFLIGHT=dead (escalates, nothing to heal)" \
  || bad "B. expected PREFLIGHT=dead (got: $OUT)"

# --- C: dead runner, setup command FIXES it → self-heals (PREFLIGHT=healed) ----
# The runner is dead until a `.healed` marker exists in its dir; the declared
# worktreeSetupCommand creates it. First probe dead → re-apply → re-probe green.
repo="$(new_mission)"; wt="$repo/wt"; mkdir -p "$wt"
heal "$repo" "$wt" \
  'LCARS_TICKET_WORKTREE='"$wt"' '\
'LCARS_WORKTREE_SETUP_CMD="touch .healed" '\
'LCARS_TEST_CMD='\''[ -f .healed ] && exit 0 || { printf "sh: vitest: command not found\n" >&2; exit 127; }'\'''
printf '%s' "$OUT" | grep -q "PREFLIGHT=healed" \
  && ok "C. dead runner + setup that provisions it → PREFLIGHT=healed (no human gate)" \
  || bad "C. expected PREFLIGHT=healed (got: $OUT)"
[ -f "$wt/.healed" ] \
  && ok "C. the declared worktreeSetupCommand was actually re-applied (.healed created)" \
  || bad "C. setup command re-applied (marker missing)"
[ "$(evjson worktree_reprovision "$repo")" -ge 1 ] && [ "$(evjson worktree_reprovision_ok "$repo")" -ge 1 ] \
  && ok "C. heal is observable (worktree_reprovision + worktree_reprovision_ok breadcrumbs)" \
  || bad "C. reprovision breadcrumbs (reprovision=$(evjson worktree_reprovision "$repo") ok=$(evjson worktree_reprovision_ok "$repo"))"

# --- D: dead runner, setup command CANNOT fix it → still escalates -------------
# A declared setup exists (so the heal is attempted) but it does not cure the
# runner → after honestly re-applying it, the ticket still escalates. No infinite
# heal, no false green.
repo="$(new_mission)"; wt="$repo/wt"; mkdir -p "$wt"
heal "$repo" "$wt" \
  'LCARS_TICKET_WORKTREE='"$wt"' '\
'LCARS_WORKTREE_SETUP_CMD="true" '\
'LCARS_TEST_CMD='\''printf "sh: vitest: command not found\n" >&2; exit 127'\'''
printf '%s' "$OUT" | grep -q "PREFLIGHT=dead" \
  && ok "D. dead runner + setup that does NOT cure it → PREFLIGHT=dead (escalates, no false green)" \
  || bad "D. expected PREFLIGHT=dead (got: $OUT)"
[ "$(evjson worktree_reprovision "$repo")" -ge 1 ] \
  && ok "D. heal was ATTEMPTED before escalating (worktree_reprovision breadcrumb)" \
  || bad "D. heal attempted (no worktree_reprovision breadcrumb)"

echo
printf 'preflight-selfheal: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
