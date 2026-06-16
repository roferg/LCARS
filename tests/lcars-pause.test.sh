#!/usr/bin/env bash
#
# Tests for `lcars pause` / `lcars resume` — user-initiated pause/resume
# (ADR-005, PRD §5.10). Skill source: skills/lcars-pause/pause.sh.
#
# `lcars pause <id>` halts a running Mission at a SAFE boundary: it sets
# paused=true in state.json and applies the existing lcars:paused label. The
# driver (run.sh) honours the flag at boundaries ONLY — between Stages
# (top of cmd_drive's loop) and between waves/tickets in Implement (top of
# cmd_implement's loop) — never a mid-step worker kill. `lcars resume <id>`
# clears the flag, removes the label, and re-enters the driver from the
# recorded stage. Both verbs are idempotent.
#
# Behaviours under test:
#   1. pause sets state.json.paused=true and applies lcars:paused via gh
#   2. the driver (cmd_drive), seeing paused=true, halts at the boundary and
#      does NOT spawn a stage subprocess / advance the stage
#   2b. the Implement loop (cmd_implement), seeing paused=true, halts at the
#      between-wave boundary and does NOT advance to verify or build tickets
#   3. resume clears the flag, removes the label, and drives from the stage
#   4. pause is idempotent (double-pause safe)
#   4b. resume is idempotent (resuming a non-paused mission is a clean no-op
#      that still drives)
#
# Dependencies are taken via env so we can stub them — tests stay OFFLINE and
# spend NO tokens:
#   LCARS_GH_BIN       - the `gh` binary (default: gh)
#   LCARS_RUN_SCRIPT   - run.sh, for resume's driver re-entry
#   LCARS_WORKER_BIN   - the cold-worker bin (stubbed; never invoked here)
#
# Usage: bash tests/lcars-pause.test.sh

set -uo pipefail

# qgrep: drain stdin FULLY before grepping. A piped `grep -q` short-circuits on
# the first match and SIGPIPEs the writer — under `set -o pipefail` that turns a
# successful match into a pipeline failure. Draining via `cat` first avoids it.
qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_PAUSE_SCRIPT:-$REPO_ROOT/skills/lcars-pause/pause.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

MID="lcars-20260601-001"
state_of()   { echo "$1/.git/lcars/missions/$MID/state.json"; }
events_of()  { echo "$1/.git/lcars/missions/$MID/events.jsonl"; }

# A fake `gh` that records every call to $GH_LOG and otherwise succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# A worker stub that, if EVER invoked, records the call so a test can assert it
# was NOT spawned while paused. (cmd_drive shells `bash $SELF <action>`, which is
# run.sh re-entrant — that in turn would require_worker. We stub the worker bin
# so even an accidental advance is observable + offline.)
make_worker_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "worker $*" >>"$WORKER_LOG"
exit 0
EOF
  chmod +x "$1"
}

# Build an isolated git repo with a Mission at the `plan` stage (a between-Stages
# boundary the driver would normally advance from), issue #7.
new_repo_with_mission() { # [stage]
  local stage="${1:-plan}"
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add gamification",
  "stage": "$stage",
  "created": "2026-06-01T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 7
}
EOF
  echo "$repo"
}

# ==========================================================================
echo "lcars pause / resume"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: pause sets paused=true + applies lcars:paused -------------
repo1="$(new_repo_with_mission)"; make_gh_stub "$repo1/gh"
export GH_LOG="$repo1/gh.log"; : >"$GH_LOG"
rc1=0
( cd "$repo1" && LCARS_GH_BIN="$repo1/gh" bash "$SCRIPT" pause "$MID" >out.txt 2>&1 ) || rc1=$?
s1="$(state_of "$repo1")"
check "1. pause exits 0" "[ '$rc1' -eq 0 ]"
check "1. sets paused=true in state.json" \
  "grep -q '\"paused\": *true' '$s1'"
check "1. applies the lcars:paused label via gh" \
  "qgrep -q 'add-label lcars:paused' '$repo1/gh.log'"
check "1. does NOT remove any label on pause" \
  "! qgrep -qi 'remove-label' '$repo1/gh.log'"
check "1. leaves the stage UNCHANGED (still plan)" \
  "grep -q '\"stage\": *\"plan\"' '$s1'"

# --- Behaviour 2: the driver, seeing paused, halts at the boundary ---------
# A paused Mission at `plan` must NOT advance: no stage subprocess, the stage
# unchanged, and a clear paused readout. We stub the worker bin so any
# accidental advance would be observable AND offline.
repo2="$(new_repo_with_mission)"; make_gh_stub "$repo2/gh"; make_worker_stub "$repo2/worker"
export GH_LOG="$repo2/gh.log"; : >"$GH_LOG"
export WORKER_LOG="$repo2/worker.log"; : >"$WORKER_LOG"
( cd "$repo2" && LCARS_GH_BIN="$repo2/gh" bash "$SCRIPT" pause "$MID" >/dev/null 2>&1 )
rc2=0
( cd "$repo2" && LCARS_GH_BIN="$repo2/gh" LCARS_GIT_BIN=git \
    LCARS_WORKER_BIN="$repo2/worker" \
    bash "$RUN_SCRIPT" drive --mission "$MID" >out2.txt 2>&1 ) || rc2=$?
s2="$(state_of "$repo2")"
check "2. driver on a paused mission exits 0 (clean stop)" "[ '$rc2' -eq 0 ]"
check "2. driver prints a paused readout" \
  "qgrep -qi 'paused' '$repo2/out2.txt'"
check "2. driver did NOT advance the stage (still plan)" \
  "grep -q '\"stage\": *\"plan\"' '$s2'"
check "2. driver spawned NO cold worker while paused" \
  "[ ! -s '$repo2/worker.log' ]"

# --- Behaviour 2b: the Implement loop halts at the between-wave boundary ----
# A paused Mission at `implement` must NOT advance to verify or build tickets.
# cmd_implement's loop must check paused at its top, before impl-status decides.
repo2b="$(new_repo_with_mission implement)"; make_gh_stub "$repo2b/gh"; make_worker_stub "$repo2b/worker"
export GH_LOG="$repo2b/gh.log"; : >"$GH_LOG"
export WORKER_LOG="$repo2b/worker.log"; : >"$WORKER_LOG"
( cd "$repo2b" && LCARS_GH_BIN="$repo2b/gh" bash "$SCRIPT" pause "$MID" >/dev/null 2>&1 )
rc2b=0
( cd "$repo2b" && LCARS_GH_BIN="$repo2b/gh" LCARS_GIT_BIN=git \
    LCARS_WORKER_BIN="$repo2b/worker" \
    bash "$RUN_SCRIPT" implement --mission "$MID" >out2b.txt 2>&1 ) || rc2b=$?
s2b="$(state_of "$repo2b")"
check "2b. implement on a paused mission exits 0 (clean stop)" "[ '$rc2b' -eq 0 ]"
check "2b. implement prints a paused readout" \
  "qgrep -qi 'paused' '$repo2b/out2b.txt'"
check "2b. implement did NOT advance to verify (still implement)" \
  "grep -q '\"stage\": *\"implement\"' '$s2b'"
check "2b. implement spawned NO cold worker while paused" \
  "[ ! -s '$repo2b/worker.log' ]"

# --- Behaviour 3: resume clears the flag, drops the label, and drives -------
# We stub the driver re-entry (LCARS_RUN_SCRIPT) so we can assert resume DELEGATES
# to `drive --mission <id>` after clearing the flag — offline, no real stages.
make_run_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "run $*" >>"$RUN_LOG"
exit 0
EOF
  chmod +x "$1"
}
repo3="$(new_repo_with_mission)"; make_gh_stub "$repo3/gh"; make_run_stub "$repo3/run"
export GH_LOG="$repo3/gh.log"; : >"$GH_LOG"
export RUN_LOG="$repo3/run.log"; : >"$RUN_LOG"
( cd "$repo3" && LCARS_GH_BIN="$repo3/gh" bash "$SCRIPT" pause "$MID" >/dev/null 2>&1 )
: >"$repo3/gh.log"
rc3=0
( cd "$repo3" && LCARS_GH_BIN="$repo3/gh" LCARS_RUN_SCRIPT="$repo3/run" \
    bash "$SCRIPT" resume "$MID" >out3.txt 2>&1 ) || rc3=$?
s3="$(state_of "$repo3")"
check "3. resume exits 0" "[ '$rc3' -eq 0 ]"
check "3. clears the paused flag in state.json" \
  "! grep -q '\"paused\": *true' '$s3'"
check "3. removes the lcars:paused label via gh" \
  "qgrep -q 'remove-label lcars:paused' '$repo3/gh.log'"
check "3. re-enters the driver from the recorded stage (drive --mission)" \
  "qgrep -q 'drive --mission $MID' '$repo3/run.log'"

# --- Behaviour 4: pause is idempotent (double-pause safe) -------------------
repo4="$(new_repo_with_mission)"; make_gh_stub "$repo4/gh"
export GH_LOG="$repo4/gh.log"; : >"$GH_LOG"
( cd "$repo4" && LCARS_GH_BIN="$repo4/gh" bash "$SCRIPT" pause "$MID" >/dev/null 2>&1 )
rc4=0
( cd "$repo4" && LCARS_GH_BIN="$repo4/gh" bash "$SCRIPT" pause "$MID" >out4.txt 2>&1 ) || rc4=$?
s4="$(state_of "$repo4")"
check "4. double-pause exits 0 (idempotent)" "[ '$rc4' -eq 0 ]"
check "4. double-pause leaves exactly one paused=true field" \
  "[ \"\$(grep -c '\"paused\": *true' '$s4')\" -eq 1 ]"

# --- Behaviour 4b: resume is idempotent (resuming a non-paused is a no-op +drive)
repo4b="$(new_repo_with_mission)"; make_gh_stub "$repo4b/gh"; make_run_stub "$repo4b/run"
export GH_LOG="$repo4b/gh.log"; : >"$GH_LOG"
export RUN_LOG="$repo4b/run.log"; : >"$RUN_LOG"
rc4b=0
( cd "$repo4b" && LCARS_GH_BIN="$repo4b/gh" LCARS_RUN_SCRIPT="$repo4b/run" \
    bash "$SCRIPT" resume "$MID" >out4b.txt 2>&1 ) || rc4b=$?
s4b="$(state_of "$repo4b")"
check "4b. resuming a non-paused mission exits 0 (clean no-op)" "[ '$rc4b' -eq 0 ]"
check "4b. resuming a non-paused mission has no paused=true" \
  "! grep -q '\"paused\": *true' '$s4b'"
check "4b. resuming a non-paused mission still drives" \
  "qgrep -q 'drive --mission $MID' '$repo4b/run.log'"

# --- Guards -----------------------------------------------------------------
# pause of an unknown mission is rejected (touches nothing)
repoG="$(new_repo_with_mission)"; make_gh_stub "$repoG/gh"
export GH_LOG="$repoG/gh.log"; : >"$GH_LOG"
rcG=0
( cd "$repoG" && LCARS_GH_BIN="$repoG/gh" bash "$SCRIPT" pause "no-such" >out.txt 2>&1 ) || rcG=$?
check "guard. pause rejects an unknown mission id" "[ '$rcG' -ne 0 ]"

# resume of an unknown mission is rejected
rcGr=0
( cd "$repoG" && LCARS_GH_BIN="$repoG/gh" bash "$SCRIPT" resume "no-such" >out.txt 2>&1 ) || rcGr=$?
check "guard. resume rejects an unknown mission id" "[ '$rcGr' -ne 0 ]"

# ==========================================================================
echo
printf 'lcars pause / resume: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
