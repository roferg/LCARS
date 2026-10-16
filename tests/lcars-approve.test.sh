#!/usr/bin/env bash
#
# Tests for `lcars approve` — the captain's MERGE signal at the end of Verify
# (skill source: skills/lcars-approve/approve.sh).
#
# S75 changed approve's job. Verify now AUTO-OPENS the PR; `lcars approve <id>`
# MERGES that open PR and marks the Mission Done. It is purely mechanical — no
# LLM:
#   1. requires an open PR recorded in state.json (prUrl/prNumber) — Verify
#      opened it; with no PR approve refuses and stays at verify,
#   2. merges the PR via the host adapter (gh pr merge),
#   3. ONLY on a successful merge: clears the stage labels, marks lcars:done,
#      moves state.json's stage to "done", and prints the merged PR URL.
#
# A failed merge NEVER flips the Mission to Done (no false Done).
#
# The script takes its deps via env so we can stub them:
#   LCARS_GH_BIN   - the `gh` binary (default: gh)
#
# Usage: bash tests/lcars-approve.test.sh

set -uo pipefail

# S180 — respond.sh now HANDS BACK TO THE DRIVER when it clears a gate (the
# captain had to type a second command for every answer he gave). This suite
# exercises respond.sh itself, not the pipeline, so it opts out: without this
# every `answer` here would launch a real `run.sh drive` in a fixture repo,
# mutating the state the assertions below read and — with a worker binary on the
# box — spending real money. The resume itself is covered, with a stubbed driver,
# in tests/settled-decisions.test.sh.
export LCARS_RESPOND_RESUME=0

# qgrep: drain stdin fully before grepping (see host-adapter.test.sh for why).
# qgrep reads stdin ONLY when no FILE operand was given. Draining stdin first
# is what keeps a piped `grep -q` from SIGPIPE-ing a still-writing producer and
# flipping a genuine match into a phantom failure under `set -o pipefail`. But
# draining when a FILE was passed reads INHERITED stdin: from a terminal that
# blocks forever, and with stdin closed it silently returns empty and the
# assertion passes by accident. So count the non-option operands ("--" ends the
# options; no call site uses -e/-f, which take an argument) and hand the file
# form straight to grep. Output and exit status match grep in both shapes.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

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

# A fake `gh` that records every call to $GH_LOG (one line each) and succeeds.
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

# Like make_gh_stub, but `gh pr merge` FAILS (exit 1) — stands in for a merge
# conflict / failing required check / auth error.
make_gh_stub_merge_fail() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "merge" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$1"
}

# BUG-069: a gh stub that mimics the post-push mergeability LAG — the FIRST
# `gh pr merge` fails ("not mergeable yet" — GitHub is still recomputing), then
# a later attempt SUCCEEDS. Counts attempts in $GH_LOG so a bounded retry in
# approve recovers without ever falling into the merge-failed path. <fail_n> =
# how many leading merge attempts fail before one succeeds.
make_gh_stub_merge_transient() { # <path> <fail_n>
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "gh \$*" | tr '\n' ' ' >>"\$GH_LOG"; echo >>"\$GH_LOG"
if [ "\${1:-}" = "pr" ] && [ "\${2:-}" = "merge" ]; then
  n="\$(grep -c 'pr merge' "\$GH_LOG")"
  if [ "\$n" -le $2 ]; then
    echo "Pull request is not mergeable: the merge commit cannot be created yet." >&2
    exit 1
  fi
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

# A fake reconcile (sibling run.sh) injected via LCARS_RUN_SCRIPT: it records its
# args to $RECON_LOG and exits with a chosen code. It NEVER touches the real
# run.sh, so no real model worker is ever spawned. The recorded line also
# captures LCARS_WORKER_BIN so a test can assert the mission engine was pinned.
make_reconcile_stub() { # <path> <exit_code>
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "reconcile [WORKER_BIN=\${LCARS_WORKER_BIN:-}] \$*" >>"\$RECON_LOG"
exit $2
EOF
  chmod +x "$1"
}

# Build an isolated git repo with one mission parked at "verify" WITH an open PR
# recorded (prUrl/prNumber) — the shape the new Verify auto-open leaves behind.
new_repo_with_open_pr_mission() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'export const theme = "dark";\n' >theme.js \
      && git add -A && git commit -q -m "lcars($MID) t-001" \
      && git checkout -q "$base" )
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
  "review": "open",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "prNumber": 77,
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  echo "$repo"
}

# ==========================================================================
echo "lcars approve"

[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

# --- Behaviour 1: approve MERGES the recorded open PR -----------------------
repoA="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoA/gh"
make_reconcile_stub "$repoA/recon.sh" 0
export GH_LOG="$repoA/gh.log"; : >"$GH_LOG"
export RECON_LOG="$repoA/recon.log"; : >"$RECON_LOG"
rcA=0
( cd "$repoA" && LCARS_GH_BIN="$repoA/gh" LCARS_RUN_SCRIPT="$repoA/recon.sh" \
    RECON_LOG="$repoA/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcA=$?
sA="$(state_of "$repoA")"
check "1. approve exits 0 on a verify mission with an open PR" "[ '$rcA' -eq 0 ]"
check "1. calls gh pr merge (the new ship action)" "grep -q 'pr merge' '$GH_LOG'"
check "1. merges the recorded PR number (77)" "grep -q 'pr merge 77' '$GH_LOG'"
check "1. opens NO new PR (Verify opened it; approve only merges)" \
  "! grep -q 'pr create' '$GH_LOG'"
check "1. prints the merged PR URL" "grep -q 'pull/77' '$repoA/out.txt'"

# --- Behaviour 2: a successful merge flips the Mission to Done ---------------
check "2. advances the stage to done" "grep -q '\"stage\": *\"done\"' '$sA'"
check "2. adds the lcars:done label" "grep -q 'add-label lcars:done' '$GH_LOG'"
check "2. removes the lcars:verify stage label" \
  "grep -q 'remove-label lcars:verify' '$GH_LOG'"

# --- Completion releases only the pause recorded by Number One -------------
savedMID="$MID"; MID="lcars-20261015-295"
repoXO="$(new_repo_with_open_pr_mission)"
make_gh_stub "$repoXO/gh"; make_reconcile_stub "$repoXO/recon.sh" 0
sXO="$(state_of "$repoXO")"; mXO="${sXO%/state.json}"
xoChild="lcars-20261015-296"; ownChild="lcars-20261015-297"
mkdir -p "$mXO/xo" "${mXO%/*}/$xoChild" "${mXO%/*}/$ownChild"
printf '{"filed":[{"mission":"%s"},{"mission":"%s"}]}\n' "$xoChild" "$ownChild" >"$mXO/xo/logs.json"
for child in "$xoChild" "$ownChild"; do
  printf '{\n  "id": "%s",\n  "type": "bug",\n  "parentMission": "%s",\n  "stage": "done"\n}\n' \
    "$child" "$MID" >"${mXO%/*}/$child/state.json"
done
(
  . "$REPO_ROOT/skills/lcars-init/lcars-state.sh"
  lcars_state_set "$sXO" numberOne '{"status":"engaged","engine":"copilot"}'
  lcars_state_set "${mXO%/*}/$ownChild/state.json" paused true
)
rcXO=0
( cd "$repoXO" && LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN=true \
    bash "$REPO_ROOT/skills/lcars-xo/xo.sh" off "$MID" >off.txt 2>&1 ) || rcXO=$?
check "2xo. unfinished xo off still pauses and records ownership" \
  "[ '$rcXO' -eq 0 ] && grep -q '\"paused\": *true' '$sXO' &&
   grep -q '^self paused-by-us$' '$mXO/xo-stop' &&
   grep -q '\"stage\": *\"verify\"' '$sXO'"
check "2xo. stop distinguishes its child pause from a captain-owned child pause" \
  "grep -q '^child $xoChild paused-by-us$' '$mXO/xo-stop' &&
   grep -q '^child $ownChild already-paused$' '$mXO/xo-stop'"
rcXO=0
( cd "$repoXO" && GH_LOG="$repoXO/gh.log" RECON_LOG="$repoXO/recon.log" \
    LCARS_GH_BIN="$repoXO/gh" LCARS_RUN_SCRIPT="$repoXO/recon.sh" \
    bash "$SCRIPT" --mission "$MID" >out.txt 2>&1 ) || rcXO=$?
check "2xo. merged mission releases its xo-owned pause and stop marker" \
  "[ '$rcXO' -eq 0 ] &&
   python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s[\"stage\"]==\"done\"; assert s[\"review\"]==\"merged\"; assert not s.get(\"paused\",False)' '$sXO' &&
   [ ! -e '$mXO/xo-stop' ]"
check "2xo. completion releases the owned child pause, not the captain's pause" \
  "python3 -c 'import json,sys; assert not json.load(open(sys.argv[1])).get(\"paused\",False); assert json.load(open(sys.argv[2]))[\"paused\"] is True' '${mXO%/*}/$xoChild/state.json' '${mXO%/*}/$ownChild/state.json'"

for stopMode in own-pause already-paused marker-only; do
  repoControl="$(new_repo_with_open_pr_mission)"
  printf '{\n  "numberOne": {"enabled": true, "engine": "copilot"}\n}\n' >"$repoControl/.git/lcars/config.json"
  make_gh_stub "$repoControl/gh"; make_reconcile_stub "$repoControl/recon.sh" 0
  sControl="$(state_of "$repoControl")"; mControl="${sControl%/state.json}"
  (
    . "$REPO_ROOT/skills/lcars-init/lcars-state.sh"
    lcars_state_set "$sControl" paused true
    lcars_state_set "$sControl" numberOne '{"status":"engaged","engine":"copilot"}'
  )
  case "$stopMode" in
    already-paused)
      ( cd "$repoControl" && LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN=true \
          bash "$REPO_ROOT/skills/lcars-xo/xo.sh" off "$MID" >off.txt 2>&1 )
      check "2xo. control stop records an already-paused mission" \
        "grep -q '^self already-paused$' '$mControl/xo-stop'" ;;
    marker-only)
      ( cd "$repoControl" && LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN=true \
          bash "$REPO_ROOT/skills/lcars-xo/xo.sh" off >off.txt 2>&1 )
      check "2xo. repo-wide control records no ownership of the captain's pause" \
        "grep -q '^self left-running$' '$mControl/xo-stop'" ;;
  esac
  rcControl=0
  ( cd "$repoControl" && GH_LOG="$repoControl/gh.log" RECON_LOG="$repoControl/recon.log" \
      LCARS_GH_BIN="$repoControl/gh" LCARS_RUN_SCRIPT="$repoControl/recon.sh" \
      bash "$SCRIPT" --mission "$MID" >out.txt 2>&1 ) || rcControl=$?
  check "2xo. $stopMode control completes but keeps its own pause" \
    "[ '$rcControl' -eq 0 ] &&
     python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s[\"stage\"]==\"done\"; assert s[\"paused\"] is True' '$sControl' &&
     [ ! -e '$mControl/xo-stop' ]"
done
MID="$savedMID"

# --- Behaviour 3: a FAILED merge must NOT flip the Mission to Done -----------
# No false Done: when `gh pr merge` fails, approve stays at verify, applies no
# lcars:done, and exits non-zero with an actionable message.
repoF="$(new_repo_with_open_pr_mission)"; make_gh_stub_merge_fail "$repoF/gh"
make_reconcile_stub "$repoF/recon.sh" 0
(
  . "$REPO_ROOT/skills/lcars-init/lcars-state.sh"
  lcars_state_set "$(state_of "$repoF")" paused true
)
printf 'mission %s\nself paused-by-us\n' "$MID" >"${repoF}/.git/lcars/missions/$MID/xo-stop"
export GH_LOG="$repoF/gh.log"; : >"$GH_LOG"
rcF=0
( cd "$repoF" && LCARS_GH_BIN="$repoF/gh" LCARS_RUN_SCRIPT="$repoF/recon.sh" \
    RECON_LOG="$repoF/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcF=$?
check "3. exits non-zero when gh pr merge fails" "[ '$rcF' -ne 0 ]"
check "3. stays at verify (does NOT advance to done) on a failed merge" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoF")'"
check "3. applies NO lcars:done label on a failed merge" \
  "! grep -q 'add-label lcars:done' '$repoF/gh.log'"
check "3. prints an actionable error mentioning verify" \
  "grep -qi 'verify' '$repoF/out.txt'"
check "3. failed merge keeps Number One's pause and ownership record" \
  "grep -q '\"paused\": *true' '$(state_of "$repoF")' &&
   grep -q '^self paused-by-us$' '$repoF/.git/lcars/missions/$MID/xo-stop'"

# --- Behaviour 4: approve REQUIRES an open PR (none recorded → refuse) -------
# A verify mission with NO prUrl was never driven through the Verify auto-open;
# approve must refuse, stay at verify, and never invent a merge.
repoN="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoN/gh"
# strip the prUrl/prNumber/review lines to simulate "no PR yet".
grep -v 'prUrl\|prNumber\|"review"' "$(state_of "$repoN")" >"$repoN/s.tmp" \
  && mv "$repoN/s.tmp" "$(state_of "$repoN")"
make_reconcile_stub "$repoN/recon.sh" 0
export GH_LOG="$repoN/gh.log"; : >"$GH_LOG"
rcN=0
( cd "$repoN" && LCARS_GH_BIN="$repoN/gh" LCARS_RUN_SCRIPT="$repoN/recon.sh" \
    RECON_LOG="$repoN/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcN=$?
check "4. exits non-zero with no open PR recorded" "[ '$rcN' -ne 0 ]"
check "4. makes NO merge call with no open PR" "! grep -q 'pr merge' '$repoN/gh.log'"
check "4. does NOT advance to done with no open PR" \
  "! grep -q '\"stage\": *\"done\"' '$(state_of "$repoN")'"

# --- Guard: approve refuses a mission that is not at verify ------------------
repoG="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoG/gh"
make_reconcile_stub "$repoG/recon.sh" 0
export GH_LOG="$repoG/gh.log"; : >"$GH_LOG"
sed 's/"verify"/"implement"/' "$(state_of "$repoG")" >"$repoG/s.tmp" \
  && mv "$repoG/s.tmp" "$(state_of "$repoG")"
rcG=0
( cd "$repoG" && LCARS_GH_BIN="$repoG/gh" LCARS_RUN_SCRIPT="$repoG/recon.sh" \
    RECON_LOG="$repoG/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcG=$?
check "guard. approve refuses a non-verify mission" "[ '$rcG' -ne 0 ]"
check "guard. merges nothing on a non-verify mission" \
  "! grep -q 'pr merge' '$repoG/gh.log'"

# --- Guard: a bad mission id is rejected ------------------------------------
repoB="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoB/gh"
make_reconcile_stub "$repoB/recon.sh" 0
export GH_LOG="$repoB/gh.log"; : >"$GH_LOG"
rcB=0
( cd "$repoB" && LCARS_GH_BIN="$repoB/gh" LCARS_RUN_SCRIPT="$repoB/recon.sh" \
    RECON_LOG="$repoB/recon.log" bash "$SCRIPT" \
    --mission "no-such-mission" >out.txt 2>&1 ) || rcB=$?
check "guard. rejects an unknown mission id" "[ '$rcB' -ne 0 ]"

# --- BUG-037: approve self-heals (reconciles) BEFORE merging ----------------
# The merge gate must reconcile a possibly-behind-base PR first. The reconcile
# engine lives in the sibling run.sh `reconcile` subcommand, injected here via
# LCARS_RUN_SCRIPT. We branch on its exit code; only exit 0 proceeds to merge.

# Reconcile 10 (self-heal in flight): approve must NOT merge, stay at verify,
# exit 0, and say it is reconciling.
repoR10="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoR10/gh"
make_reconcile_stub "$repoR10/recon.sh" 10
export GH_LOG="$repoR10/gh.log"; : >"$GH_LOG"
rcR10=0
( cd "$repoR10" && LCARS_GH_BIN="$repoR10/gh" LCARS_RUN_SCRIPT="$repoR10/recon.sh" \
    RECON_LOG="$repoR10/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcR10=$?
check "r10. exits 0 (soft halt — self-heal took over, not an error)" "[ '$rcR10' -eq 0 ]"
check "r10. ran the reconcile gate" "grep -q 'reconcile' '$repoR10/recon.log'"
check "r10. does NOT call gh pr merge while reconciling" "! grep -q 'pr merge' '$repoR10/gh.log'"
check "r10. stays at verify (does NOT advance to done)" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoR10")'"
check "r10. applies NO lcars:done label" "! grep -q 'add-label lcars:done' '$repoR10/gh.log'"
check "r10. message mentions reconciling" "grep -qi 'reconcil' '$repoR10/out.txt'"

# Reconcile 20 (escalated): approve must NOT merge, stay at verify, exit 0.
repoR20="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoR20/gh"
make_reconcile_stub "$repoR20/recon.sh" 20
export GH_LOG="$repoR20/gh.log"; : >"$GH_LOG"
rcR20=0
( cd "$repoR20" && LCARS_GH_BIN="$repoR20/gh" LCARS_RUN_SCRIPT="$repoR20/recon.sh" \
    RECON_LOG="$repoR20/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcR20=$?
check "r20. exits 0 (soft halt — escalation took over, not an error)" "[ '$rcR20' -eq 0 ]"
check "r20. does NOT call gh pr merge after an escalation" "! grep -q 'pr merge' '$repoR20/gh.log'"
check "r20. stays at verify (does NOT advance to done)" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoR20")'"
check "r20. applies NO lcars:done label" "! grep -q 'add-label lcars:done' '$repoR20/gh.log'"

# Reconcile 0 (up to date / healed green): approve PROCEEDS and merges.
repoR0="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoR0/gh"
make_reconcile_stub "$repoR0/recon.sh" 0
export GH_LOG="$repoR0/gh.log"; : >"$GH_LOG"
rcR0=0
( cd "$repoR0" && LCARS_GH_BIN="$repoR0/gh" LCARS_RUN_SCRIPT="$repoR0/recon.sh" \
    RECON_LOG="$repoR0/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcR0=$?
check "r0. exits 0 (proceeds)" "[ '$rcR0' -eq 0 ]"
check "r0. ran the reconcile gate BEFORE merging" "grep -q 'reconcile' '$repoR0/recon.log'"
check "r0. proceeds to gh pr merge on a green/up-to-date reconcile" \
  "grep -q 'pr merge' '$repoR0/gh.log'"
check "r0. advances the stage to done" "grep -q '\"stage\": *\"done\"' '$(state_of "$repoR0")'"

# Engine pinning: a copilot mission must heal on copilot — approve passes the
# recorded workerBin to the reconcile via LCARS_WORKER_BIN.
repoEng="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoEng/gh"
make_reconcile_stub "$repoEng/recon.sh" 0
# plant workerBin:"copilot" in state.json.
sed 's/\("base": "[^"]*"\)/\1,\n  "workerBin": "copilot"/' "$(state_of "$repoEng")" \
  >"$repoEng/s.tmp" && mv "$repoEng/s.tmp" "$(state_of "$repoEng")"
export GH_LOG="$repoEng/gh.log"; : >"$GH_LOG"
rcEng=0
( cd "$repoEng" && LCARS_GH_BIN="$repoEng/gh" LCARS_RUN_SCRIPT="$repoEng/recon.sh" \
    RECON_LOG="$repoEng/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcEng=$?
check "eng. ran the reconcile gate before merge" "grep -q 'reconcile' '$repoEng/recon.log'"
check "eng. pinned the mission engine (LCARS_WORKER_BIN=copilot) on the reconcile" \
  "grep -q 'WORKER_BIN=copilot' '$repoEng/recon.log'"

# --- BUG-067: self-heal converges green → DO NOT auto-merge; gate for reapprove
# When the reconcile gate converges green AFTER a PR is open it returns 30 and
# persists reconcileStatus=awaiting-reapprove + reconcileNote + reconcileMergeSha
# + awaitingHuman. approve must STOP: no gh pr merge, stay at verify, and tell the
# captain to reapprove. (The reconcile gate raises the board gate itself.)
make_reconcile_stub_reapprove() { # <path>  — exits 30 AND writes the gate state
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "reconcile [WORKER_BIN=${LCARS_WORKER_BIN:-}] $*" >>"$RECON_LOG"
# mimic the real gate's awaiting-reapprove persistence on the mission state.
mid=""; while [ $# -gt 0 ]; do case "$1" in --mission) mid="$2"; shift 2;; *) shift;; esac; done
st=".git/lcars/missions/$mid/state.json"
tmp="$(mktemp)"
grep -v '"reconcileStatus"\|"reconcileNote"\|"reconcileMergeSha"\|"awaitingHuman"' "$st" >"$tmp"
awk 'NR==1{print; print "  \"reconcileStatus\": \"awaiting-reapprove\","; print "  \"reconcileNote\": \"Reconciled main into the branch (abc1234) and re-tested green (1/1). Reapprove to merge.\","; print "  \"reconcileMergeSha\": \"abc1234def5678abc1234def5678abc1234def56\","; print "  \"awaitingHuman\": true,"; next} {print}' "$tmp" >"$st"
rm -f "$tmp"
exit 30
EOF
  chmod +x "$1"
}

repoRA="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoRA/gh"
make_reconcile_stub_reapprove "$repoRA/recon.sh"
export GH_LOG="$repoRA/gh.log"; : >"$GH_LOG"
rcRA=0
( cd "$repoRA" && LCARS_GH_BIN="$repoRA/gh" LCARS_RUN_SCRIPT="$repoRA/recon.sh" \
    RECON_LOG="$repoRA/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>&1 ) || rcRA=$?
sRA="$(state_of "$repoRA")"
check "ra. exits 0 (soft halt — gated for reapprove, not an error)" "[ '$rcRA' -eq 0 ]"
check "ra. does NOT auto-merge on a green self-heal" "! grep -q 'pr merge' '$repoRA/gh.log'"
check "ra. stays at verify (does NOT advance to done)" \
  "grep -q '\"stage\": *\"verify\"' '$sRA'"
check "ra. reconcileStatus stays awaiting-reapprove" \
  "grep -q '\"reconcileStatus\": *\"awaiting-reapprove\"' '$sRA'"
check "ra. message tells the captain to reapprove" "grep -qi 'reapprove' '$repoRA/out.txt'"

# --- BUG-067: --reapprove with a CLEAN push → merges -------------------------
# A reapprove on an already-reconciled-green branch skips the reconcile engine and
# runs ONLY the merge step. With a clean push (the local test repo has no remote →
# benign push miss → falls through to gh pr merge) it merges and marks Done.
repoRC="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoRC/gh"
make_reconcile_stub "$repoRC/recon.sh" 99   # must NOT be called on reapprove
# seed the awaiting-reapprove gate state.
awk 'NR==1{print; print "  \"reconcileStatus\": \"awaiting-reapprove\","; print "  \"awaitingHuman\": true,"; next} {print}' \
  "$(state_of "$repoRC")" >"$repoRC/s.tmp" && mv "$repoRC/s.tmp" "$(state_of "$repoRC")"
export GH_LOG="$repoRC/gh.log"; : >"$GH_LOG"
rcRC=0
( cd "$repoRC" && LCARS_GH_BIN="$repoRC/gh" LCARS_RUN_SCRIPT="$repoRC/recon.sh" \
    RECON_LOG="$repoRC/recon.log" bash "$SCRIPT" \
    --mission "$MID" --reapprove >out.txt 2>&1 ) || rcRC=$?
sRC="$(state_of "$repoRC")"
check "rc. reapprove exits 0" "[ '$rcRC' -eq 0 ]"
check "rc. reapprove does NOT run the reconcile engine" "! grep -q 'reconcile' '$repoRC/recon.log' 2>/dev/null || [ ! -s '$repoRC/recon.log' ]"
check "rc. reapprove calls gh pr merge" "grep -q 'pr merge' '$repoRC/gh.log'"
check "rc. reapprove advances to done" "grep -q '\"stage\": *\"done\"' '$sRC'"
check "rc. reapprove clears the awaiting-reapprove status" \
  "! grep -q '\"reconcileStatus\": *\"awaiting-reapprove\"' '$sRC'"

# --- BUG-066/067: --reapprove with a REJECTED push → merge-failed, no merge ---
# A non-fast-forward push rejection must surface (reconcileStatus=merge-failed +
# a specific reconcileNote), NOT silently revert, and must NOT attempt gh pr merge.
# Inject a git stub whose `push` rejects non-ff; all other git calls pass through.
make_git_stub_push_reject() { # <path>
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "push" ]; then
  echo "To origin" >&2
  echo " ! [rejected]        lcars/x -> lcars/x (non-fast-forward)" >&2
  echo "error: failed to push some refs" >&2
  exit 1
fi
exec git "$@"
EOF
  chmod +x "$1"
}
repoRR="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoRR/gh"
make_git_stub_push_reject "$repoRR/git"
make_reconcile_stub "$repoRR/recon.sh" 99
awk 'NR==1{print; print "  \"reconcileStatus\": \"awaiting-reapprove\","; print "  \"reconcileMergeSha\": \"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\","; print "  \"awaitingHuman\": true,"; next} {print}' \
  "$(state_of "$repoRR")" >"$repoRR/s.tmp" && mv "$repoRR/s.tmp" "$(state_of "$repoRR")"
export GH_LOG="$repoRR/gh.log"; : >"$GH_LOG"
rcRR=0
( cd "$repoRR" && LCARS_GH_BIN="$repoRR/gh" LCARS_GIT_BIN="$repoRR/git" \
    LCARS_RUN_SCRIPT="$repoRR/recon.sh" RECON_LOG="$repoRR/recon.log" bash "$SCRIPT" \
    --mission "$MID" --reapprove >out.txt 2>&1 ) || rcRR=$?
sRR="$(state_of "$repoRR")"
check "rr. exits non-zero on a rejected push" "[ '$rcRR' -ne 0 ]"
check "rr. sets reconcileStatus=merge-failed" \
  "grep -q '\"reconcileStatus\": *\"merge-failed\"' '$sRR'"
check "rr. reconcileNote names the non-fast-forward reason" \
  "grep -qi 'non-fast-forward\|force-update\|push manually' '$sRR'"
check "rr. does NOT attempt gh pr merge after a rejected push" \
  "! grep -q 'pr merge' '$repoRR/gh.log'"
check "rr. does NOT advance to done (no silent revert to a clean state)" \
  "! grep -q '\"stage\": *\"done\"' '$sRR'"
check "rr. keeps awaitingHuman true (gate stays visible)" \
  "grep -q '\"awaitingHuman\": *true' '$sRR'"
check "rr. prints a surfaced, actionable reason (not a generic die)" \
  "grep -qi 'non-fast-forward\|force-update\|push manually' '$repoRR/out.txt'"

# --- BUG-077: auto-recover a non-ff push of the AUTHORITATIVE reconciled tip --
# When a reconcile is killed/parked and retried, the local mission branch is left
# at the dead attempt's merge commit; a retry merges main onto THAT so the local
# reconciled tip DIVERGES from the last-pushed remote PR head. A plain `git push`
# is then rejected non-fast-forward, and the old code told the human to
# force-with-lease by hand (no in-flow recovery). The fix: in the non-ff push
# branch of do_merge, if the local branch tip == the freshly-reconciled green tip
# (reconcileMergeSha) AND the local branch CONTAINS origin/main (the heal already
# incorporates current main), the local IS the authoritative resolution → do a
# `git push --force-with-lease` and, on success, proceed to gh pr merge. With a
# STALENESS GUARD: if origin/main advanced PAST the heal (local no longer contains
# origin/main) → do NOT force; set merge-failed "main moved — re-reconcile". And a
# local tip that is NOT the reconcileMergeSha is not authoritative → never force.
#
# A configurable git stub drives all three cases from env, deterministically:
#   STUB_LOCAL_SHA      what `git rev-parse <branch>` returns (the local tip)
#   STUB_CONTAINS_MAIN  1 ⇒ `git merge-base --is-ancestor origin/<base> <branch>`
#                       succeeds (local contains current main); 0 ⇒ fails (main
#                       advanced past the heal)
#   STUB_FORCE_OK       1 ⇒ `git push --force-with-lease` succeeds; 0 ⇒ fails
# A plain `git push` (no --force-with-lease) ALWAYS rejects non-ff. Pushes are
# recorded to $GIT_LOG so a test can assert whether a force-with-lease was issued.
make_git_stub_recover() { # <path>
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >>"$GIT_LOG"
case "${1:-}" in
  push)
    shift
    forced=0
    for a in "$@"; do case "$a" in --force-with-lease*) forced=1 ;; esac; done
    if [ "$forced" = 1 ]; then
      [ "${STUB_FORCE_OK:-1}" = 1 ] && exit 0
      echo "error: failed to force-push (stale lease)" >&2; exit 1
    fi
    # a plain push always rejects non-fast-forward
    echo "To origin" >&2
    echo " ! [rejected]        b -> b (non-fast-forward)" >&2
    echo "error: failed to push some refs" >&2
    exit 1 ;;
  fetch) exit 0 ;;
  rev-parse)
    # `git rev-parse <branch>` → the configured local tip; anything else passes.
    printf '%s\n' "${STUB_LOCAL_SHA:-localsha}"; exit 0 ;;
  merge-base)
    # `git merge-base --is-ancestor origin/<base> <branch>` → contains-main check.
    [ "${STUB_CONTAINS_MAIN:-1}" = 1 ] && exit 0 || exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$1"
}

# Helper: seed the awaiting-reapprove gate with a chosen reconcileMergeSha.
seed_reapprove_gate() { # <state-path> <merge-sha>
  awk -v SHA="$2" 'NR==1{print; print "  \"reconcileStatus\": \"awaiting-reapprove\",";
    printf "  \"reconcileMergeSha\": \"%s\",\n", SHA; print "  \"awaitingHuman\": true,";
    next} {print}' "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# Case 77a: local tip == reconcileMergeSha AND contains origin/main → the local
# IS the authoritative resolution → force-with-lease, then gh pr merge succeeds.
repo77a="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repo77a/gh"
make_git_stub_recover "$repo77a/git"
make_reconcile_stub "$repo77a/recon.sh" 99
seed_reapprove_gate "$(state_of "$repo77a")" "abc123authoritative"
export GH_LOG="$repo77a/gh.log"; : >"$GH_LOG"
export GIT_LOG="$repo77a/git.log"; : >"$GIT_LOG"
rc77a=0
( cd "$repo77a" && LCARS_GH_BIN="$repo77a/gh" LCARS_GIT_BIN="$repo77a/git" \
    STUB_LOCAL_SHA="abc123authoritative" STUB_CONTAINS_MAIN=1 STUB_FORCE_OK=1 \
    GIT_LOG="$repo77a/git.log" \
    LCARS_RUN_SCRIPT="$repo77a/recon.sh" RECON_LOG="$repo77a/recon.log" bash "$SCRIPT" \
    --mission "$MID" --reapprove >out.txt 2>&1 ) || rc77a=$?
s77a="$(state_of "$repo77a")"
check "77a. exits 0 — authoritative tip force-pushed then merged" "[ '$rc77a' -eq 0 ]"
check "77a. issued a force-with-lease push of the authoritative tip" \
  "grep -q 'push --force-with-lease' '$repo77a/git.log'"
check "77a. proceeds to gh pr merge after the force-with-lease" \
  "grep -q 'pr merge' '$repo77a/gh.log'"
check "77a. advances to done" "grep -q '\"stage\": *\"done\"' '$s77a'"
check "77a. does NOT set merge-failed (recovered in-flow)" \
  "! grep -q '\"reconcileStatus\": *\"merge-failed\"' '$s77a'"

# Case 77b STALENESS GUARD (BUG-075): origin/main advanced PAST the heal (local no
# longer contains origin/main) → do NOT force-push; set merge-failed "main moved —
# re-reconcile required". Never force over a remote that legitimately advanced.
repo77b="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repo77b/gh"
make_git_stub_recover "$repo77b/git"
make_reconcile_stub "$repo77b/recon.sh" 99
seed_reapprove_gate "$(state_of "$repo77b")" "abc123authoritative"
export GH_LOG="$repo77b/gh.log"; : >"$GH_LOG"
export GIT_LOG="$repo77b/git.log"; : >"$GIT_LOG"
rc77b=0
( cd "$repo77b" && LCARS_GH_BIN="$repo77b/gh" LCARS_GIT_BIN="$repo77b/git" \
    STUB_LOCAL_SHA="abc123authoritative" STUB_CONTAINS_MAIN=0 STUB_FORCE_OK=1 \
    GIT_LOG="$repo77b/git.log" \
    LCARS_RUN_SCRIPT="$repo77b/recon.sh" RECON_LOG="$repo77b/recon.log" bash "$SCRIPT" \
    --mission "$MID" --reapprove >out.txt 2>&1 ) || rc77b=$?
s77b="$(state_of "$repo77b")"
check "77b. exits non-zero when main moved past the heal" "[ '$rc77b' -ne 0 ]"
check "77b. does NOT force-push over a remote that legitimately advanced" \
  "! grep -q 'push --force-with-lease' '$repo77b/git.log'"
check "77b. sets reconcileStatus=merge-failed" \
  "grep -q '\"reconcileStatus\": *\"merge-failed\"' '$s77b'"
check "77b. note says main moved / re-reconcile" \
  "grep -qi 'main moved\|re-reconcile' '$s77b'"
check "77b. does NOT attempt gh pr merge" "! grep -q 'pr merge' '$repo77b/gh.log'"
check "77b. stays at verify (no false done)" \
  "grep -q '\"stage\": *\"verify\"' '$s77b'"

# Case 77c: local tip != reconcileMergeSha (NOT the authoritative reconciled tip)
# → must NOT force-push; surfaces as merge-failed exactly as before. (This mirrors
# the existing `rr.` case: never force when the local is not the known green tip.)
repo77c="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repo77c/gh"
make_git_stub_recover "$repo77c/git"
make_reconcile_stub "$repo77c/recon.sh" 99
seed_reapprove_gate "$(state_of "$repo77c")" "abc123authoritative"
export GH_LOG="$repo77c/gh.log"; : >"$GH_LOG"
export GIT_LOG="$repo77c/git.log"; : >"$GIT_LOG"
rc77c=0
( cd "$repo77c" && LCARS_GH_BIN="$repo77c/gh" LCARS_GIT_BIN="$repo77c/git" \
    STUB_LOCAL_SHA="something-else-entirely" STUB_CONTAINS_MAIN=1 STUB_FORCE_OK=1 \
    GIT_LOG="$repo77c/git.log" \
    LCARS_RUN_SCRIPT="$repo77c/recon.sh" RECON_LOG="$repo77c/recon.log" bash "$SCRIPT" \
    --mission "$MID" --reapprove >out.txt 2>&1 ) || rc77c=$?
s77c="$(state_of "$repo77c")"
check "77c. exits non-zero (not the authoritative tip → surfaces)" "[ '$rc77c' -ne 0 ]"
check "77c. does NOT force-push when local != reconcileMergeSha" \
  "! grep -q 'push --force-with-lease' '$repo77c/git.log'"
check "77c. sets reconcileStatus=merge-failed" \
  "grep -q '\"reconcileStatus\": *\"merge-failed\"' '$s77c'"
check "77c. does NOT attempt gh pr merge" "! grep -q 'pr merge' '$repo77c/gh.log'"

# --- BUG-067: a FAILED self-heal stays escalated AND is surfaced -------------
# reconcile exit 20 = escalated; approve must stay at verify, not merge, and the
# failure must be surfaced (reconcile_escalate already persisted reconcileNote).
repoFS="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoFS/gh"
cat >"$repoFS/recon.sh" <<'EOF'
#!/usr/bin/env bash
mid=""; while [ $# -gt 0 ]; do case "$1" in --mission) mid="$2"; shift 2;; *) shift;; esac; done
st=".git/lcars/missions/$mid/state.json"
tmp="$(mktemp)"; grep -v '"reconcileStatus"\|"awaitingHuman"' "$st" >"$tmp"
awk 'NR==1{print; print "  \"reconcileStatus\": \"escalated\","; print "  \"awaitingHuman\": true,"; next} {print}' "$tmp" >"$st"
rm -f "$tmp"; exit 20
EOF
chmod +x "$repoFS/recon.sh"
export GH_LOG="$repoFS/gh.log"; : >"$GH_LOG"
rcFS=0
( cd "$repoFS" && LCARS_GH_BIN="$repoFS/gh" LCARS_RUN_SCRIPT="$repoFS/recon.sh" \
    RECON_LOG="$repoFS/recon.log" bash "$SCRIPT" --mission "$MID" >out.txt 2>&1 ) || rcFS=$?
sFS="$(state_of "$repoFS")"
check "fs. exits 0 (soft halt — escalation owns the gate)" "[ '$rcFS' -eq 0 ]"
check "fs. does NOT merge on a failed self-heal" "! grep -q 'pr merge' '$repoFS/gh.log'"
check "fs. stays at verify" "grep -q '\"stage\": *\"verify\"' '$sFS'"
check "fs. reconcileStatus stays escalated (surfaced)" \
  "grep -q '\"reconcileStatus\": *\"escalated\"' '$sFS'"

# --- BUG-068: the merge-failed path sets awaitingHuman with NO "command not found"
# approve called an UNDEFINED state_set_raw on the merge-failed paths, so the line
# errored ("command not found") and awaitingHuman never got set. A failed merge
# must set awaitingHuman=true cleanly, with no command-not-found on stderr.
repo68="$(new_repo_with_open_pr_mission)"; make_gh_stub_merge_fail "$repo68/gh"
make_reconcile_stub "$repo68/recon.sh" 0
export GH_LOG="$repo68/gh.log"; : >"$GH_LOG"
rc68=0
( cd "$repo68" && LCARS_GH_BIN="$repo68/gh" LCARS_RUN_SCRIPT="$repo68/recon.sh" \
    RECON_LOG="$repo68/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rc68=$?
s68="$(state_of "$repo68")"
check "068. exits non-zero on a failed merge" "[ '$rc68' -ne 0 ]"
check "068. sets awaitingHuman true on a failed merge" \
  "grep -q '\"awaitingHuman\": *true' '$s68'"
check "068. NO 'command not found' on stderr (state_set_raw is defined)" \
  "! grep -qi 'command not found' '$repo68/err.txt'"
check "068. sets reconcileStatus=merge-failed" \
  "grep -q '\"reconcileStatus\": *\"merge-failed\"' '$s68'"

# --- BUG-069: post-push mergeability LAG → approve RETRIES, then merges -------
# Right after a push GitHub needs a few seconds to recompute mergeability, so the
# first `gh pr merge` can spuriously fail. approve must RETRY a bounded number of
# times and succeed on a later attempt — no spurious merge-failed.
repo69="$(new_repo_with_open_pr_mission)"
make_gh_stub_merge_transient "$repo69/gh" 1   # 1 transient failure, then success
make_reconcile_stub "$repo69/recon.sh" 0
export GH_LOG="$repo69/gh.log"; : >"$GH_LOG"
rc69=0
( cd "$repo69" && LCARS_GH_BIN="$repo69/gh" LCARS_RUN_SCRIPT="$repo69/recon.sh" \
    LCARS_MERGE_RETRY_SLEEP=0 RECON_LOG="$repo69/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rc69=$?
s69="$(state_of "$repo69")"
check "069. exits 0 — the transient not-mergeable was retried, not surfaced" \
  "[ '$rc69' -eq 0 ]"
check "069. retried gh pr merge (more than one attempt)" \
  "[ \"\$(grep -c 'pr merge' '$repo69/gh.log')\" -gt 1 ]"
check "069. advances to done after the retry succeeds" \
  "grep -q '\"stage\": *\"done\"' '$s69'"
check "069. does NOT set merge-failed on a transient lag" \
  "! grep -q '\"reconcileStatus\": *\"merge-failed\"' '$s69'"

# A PERSISTENT failure (conflict) must still surface merge-failed AFTER the
# bounded retries exhaust — the retry must not paper over a real conflict.
repo69p="$(new_repo_with_open_pr_mission)"
make_gh_stub_merge_transient "$repo69p/gh" 99   # never succeeds
make_reconcile_stub "$repo69p/recon.sh" 0
export GH_LOG="$repo69p/gh.log"; : >"$GH_LOG"
rc69p=0
( cd "$repo69p" && LCARS_GH_BIN="$repo69p/gh" LCARS_RUN_SCRIPT="$repo69p/recon.sh" \
    LCARS_MERGE_RETRY_SLEEP=0 RECON_LOG="$repo69p/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rc69p=$?
s69p="$(state_of "$repo69p")"
check "069p. exits non-zero when merge never becomes mergeable" "[ '$rc69p' -ne 0 ]"
check "069p. surfaces merge-failed after the retries exhaust" \
  "grep -q '\"reconcileStatus\": *\"merge-failed\"' '$s69p'"
check "069p. stays at verify (no false done)" \
  "grep -q '\"stage\": *\"verify\"' '$s69p'"
check "069p. tried gh pr merge more than once before giving up" \
  "[ \"\$(grep -c 'pr merge' '$repo69p/gh.log')\" -gt 1 ]"

# --- BUG-071: a successful merge emits a `merged` event to events.jsonl -------
# The mission timeline never recorded the ship. A landed merge must append a
# `merged` event so the card shows the milestone.
repo71="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repo71/gh"
make_reconcile_stub "$repo71/recon.sh" 0
export GH_LOG="$repo71/gh.log"; : >"$GH_LOG"
rc71=0
( cd "$repo71" && LCARS_GH_BIN="$repo71/gh" LCARS_RUN_SCRIPT="$repo71/recon.sh" \
    RECON_LOG="$repo71/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rc71=$?
ev71="$repo71/.git/lcars/missions/$MID/events.jsonl"
check "071. emits a merged event to events.jsonl on a successful merge" \
  "[ -f '$ev71' ] && grep -q '\"type\":\"merged\"' '$ev71'"

# --- S90: a GENUINE up-to-date push (rc 0, REAL remote) → merge PROCEEDS ------
# After S89's push-on-accept the parent branch is ALREADY on origin, so approve's
# final `git push origin <branch>` is a CLEAN no-op: git prints "Everything
# up-to-date" and returns rc 0. The contract: an up-to-date push is SUCCESS and
# must fall straight through to `gh pr merge` → done — it must NEVER be mis-read
# as a merge-failure. The pre-S90 tests only exercised the "no remote → benign
# push miss → merge" path (rc != 0, classified benign); they never proved a
# genuine rc-0 up-to-date push against a REAL remote. This fills that gap with a
# real local bare remote already at the branch tip (the strongest proof).
add_bare_remote_uptodate() { # <repo>  — push lcars/$MID so remote head == local
  local repo="$1" bare
  bare="$(mktemp -d "$TMPROOT/bare.XXXX")"
  ( cd "$bare" && git init -q --bare )
  ( cd "$repo" && git remote add origin "$bare" && git push -q origin "lcars/$MID" )
}

repoUTD="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoUTD/gh"
add_bare_remote_uptodate "$repoUTD"
make_reconcile_stub "$repoUTD/recon.sh" 0
export GH_LOG="$repoUTD/gh.log"; : >"$GH_LOG"
rcUTD=0
( cd "$repoUTD" && LCARS_GH_BIN="$repoUTD/gh" LCARS_RUN_SCRIPT="$repoUTD/recon.sh" \
    LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 RECON_LOG="$repoUTD/recon.log" \
    bash "$SCRIPT" --mission "$MID" >out.txt 2>err.txt ) || rcUTD=$?
sUTD="$(state_of "$repoUTD")"
check "utd. exits 0 on a genuine up-to-date push (Everything up-to-date, rc 0)" \
  "[ '$rcUTD' -eq 0 ]"
check "utd. proceeds to gh pr merge after the no-op push (merges PR 77)" \
  "grep -q 'pr merge 77' '$repoUTD/gh.log'"
check "utd. advances the stage to done" "grep -q '\"stage\": *\"done\"' '$sUTD'"
check "utd. does NOT mis-read up-to-date as merge-failed" \
  "! grep -q '\"reconcileStatus\": *\"merge-failed\"' '$sUTD'"
check "utd. does NOT raise awaitingHuman on an up-to-date push" \
  "! grep -q '\"awaitingHuman\": *true' '$sUTD'"
check "utd. marks the review merged" "grep -q '\"review\": *\"merged\"' '$sUTD'"

# --- S90: DISTINCTNESS — a genuine non-ff push (NO reconcileMergeSha) surfaces
# merge-failed + stays at verify. Proves the up-to-date SUCCESS path is DISTINCT
# from the rejection path, and that the force-with-lease / staleness guards are
# UNTOUCHED: with no recorded reconciled green tip the branch is never forced —
# the divergence is surfaced for the captain. (Sibling of `rr.`, but on the NORMAL
# flow with NO reconcileMergeSha recorded — the post-S89 default shape.)
repoNFF="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoNFF/gh"
make_git_stub_push_reject "$repoNFF/git"
make_reconcile_stub "$repoNFF/recon.sh" 0
export GH_LOG="$repoNFF/gh.log"; : >"$GH_LOG"
rcNFF=0
( cd "$repoNFF" && LCARS_GH_BIN="$repoNFF/gh" LCARS_GIT_BIN="$repoNFF/git" \
    LCARS_RUN_SCRIPT="$repoNFF/recon.sh" LCARS_MERGE_RETRY_SLEEP=0 \
    RECON_LOG="$repoNFF/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rcNFF=$?
sNFF="$(state_of "$repoNFF")"
check "nff. exits non-zero on a genuine non-fast-forward push" "[ '$rcNFF' -ne 0 ]"
check "nff. sets reconcileStatus=merge-failed" \
  "grep -q '\"reconcileStatus\": *\"merge-failed\"' '$sNFF'"
check "nff. does NOT attempt gh pr merge after a rejected push" \
  "! grep -q 'pr merge' '$repoNFF/gh.log'"
check "nff. stays at verify (no false done)" \
  "grep -q '\"stage\": *\"verify\"' '$sNFF'"
check "nff. keeps awaitingHuman true (gate stays visible)" \
  "grep -q '\"awaitingHuman\": *true' '$sNFF'"

# --- Behaviour FOLD: approving the parent CLOSES OUT its folded bug children --
#
# BUG (DX-Scorecard, 2026-07-29): a Mission-Log bug child folds its fix onto the
# PARENT's branch and gets NO PR of its own, so the ONLY path that marks it Done
# is accepting the parent's consolidated re-verify gate (respond.sh → resolve-logs
# complete). `lcars approve <parent>` merged the parent's PR, DELETED that gate
# (state_del awaitingHuman/pendingQuestion) and marked the parent done — folding
# nothing. The children were then unreachable forever: approve refuses them (no
# PR of their own) and resolve-logs can no longer resolve a `done` parent (its
# active_table skips done missions). Four real bug missions stranded at verify
# with their fixes already merged in main.
#
# approve must therefore fold the verified children as part of the merge — and it
# must do so through resolve-logs, which owns the fold and its PREMISE CHECK. That
# check is the 2026-07-28 fix for the OPPOSITE failure (cards read Done while the
# code was gone); both directions have to hold at once.

# A parent at verify with an open PR + three linked bug children. The children are
# SIBLING ids (lcars-<date>-002/003/004), exactly as `lcars log` files them — never
# suffixes of the parent id, which would collide with resolve-logs' substring parent
# matcher and make this fixture test the matcher instead of the fold.
#   BUG_OK   → fix commit IS on the parent branch  → must fold to done
#   BUG_GONE → NO commit on the parent branch      → must be REFUSED (premise check)
#   BUG_WIP  → stage plan                          → must be untouched
BUG_OK="lcars-20260530-002"
BUG_GONE="lcars-20260530-003"
BUG_WIP="lcars-20260530-004"
# $1 = "recorded" -> every child also carries S231's fold record (foldedInto),
# which is what SATISFIES S232's pre-merge open-children gate. Without it approve
# now REFUSES to merge at all (proved in FOLD-GATE below) and
# fold_logged_children -- which keys on the child's STAGE, not on the record --
# is never reached.
new_repo_with_folded_children() {
  local recorded="${1:-}"
  local repo; repo="$(mktemp -d "$TMPROOT/repofold.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  # the parent branch carries the parent's ticket AND the real child's fix
  # (subject prefix `lcars(<id>)` — the signal child_fix_on_branch greps for).
  ( cd "$repo" && git checkout -q -b "lcars/$MID" \
      && printf 'export const theme = "dark";\n' >theme.js \
      && git add -A && git commit -q -m "lcars($MID) t-001" \
      && printf 'export const gap = 18;\n' >gap.js \
      && git add -A && git commit -q -m "lcars($BUG_OK) t-001: spacing fix" \
      && git checkout -q "$base" )
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "verify",
  "review": "open",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "prNumber": 77,
  "awaitingHuman": true,
  "pendingQuestion": "3 logged bugs folded onto this Mission — re-inspect, then accept.",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "branch": "lcars/$MID",
  "base": "$base"
}
EOF
  # the consolidated re-verify gate resolve-logs raises on the parent.
  printf '{"question":"3 logged bugs folded — accept?"}\n' >"$m/pending.json"

  local bid stage
  for spec in "$BUG_OK:verify:91" "$BUG_GONE:verify:92" "$BUG_WIP:plan:93"; do
    bid="${spec%%:*}"; stage="$(echo "$spec" | cut -d: -f2)"
    local issue; issue="${spec##*:}"
    local c="$repo/.git/lcars/missions/$bid"
    mkdir -p "$c/tickets/t-001"
    # every child recorded a commit, so the premise check actually runs for each
    # (a child with no recorded commit folds unchecked by design).
    echo "deadbeef" >"$c/tickets/t-001/.commit-sha"
    cat >"$c/state.json" <<EOF
{
  "id": "$bid",
  "type": "bug",
  "title": "logged bug $bid",
  "stage": "$stage",
  "parentMission": "$MID",
  "parentIssue": 42,
  "created": "2026-05-30T11:00:00Z",
  "githubIssue": $issue,
  "branch": "lcars/$MID",
  "base": "lcars/$MID"
}
EOF
    if [ "$recorded" = recorded ]; then
      python3 - "$c/state.json" "$MID" <<'FOLDREC'
import json,sys
d=json.load(open(sys.argv[1]))
d["foldedInto"]=sys.argv[2]; d["foldedAt"]="2026-05-30T11:30:00Z"
json.dump(d, open(sys.argv[1],"w"), indent=2)
FOLDREC
    fi
  done
  echo "$repo"
}

# --- Behaviour FOLD-GATE (S232): an OPEN logged bug REFUSES the merge ---------
#
# THE WEEKEND DEFECT (evidence/lcars-feedback.jsonl #6). The block below proves
# what approve does with children it has been ALLOWED to ship. This proves it is
# not allowed to ship a parent whose bugs are still open in the first place: the
# warning that used to be the only response ("their fixes are NOT in this PR")
# arrived AFTER `gh pr merge` had landed, by which time nothing could carry those
# fixes -- the parent was `done` and outside resolve-logs' reach. Same fixture,
# WITHOUT the fold record: all three children are open, so approve refuses and
# merges nothing. Note that BUG_GONE is exactly the case that makes this matter --
# its fix is NOT on the branch at all.
repoFG="$(new_repo_with_folded_children)"; make_gh_stub "$repoFG/gh"
make_reconcile_stub "$repoFG/recon.sh" 0
export GH_LOG="$repoFG/gh.log"; : >"$GH_LOG"
export RECON_LOG="$repoFG/recon.log"; : >"$RECON_LOG"
rcFG=0
( cd "$repoFG" && LCARS_GH_BIN="$repoFG/gh" LCARS_RUN_SCRIPT="$repoFG/recon.sh" \
    RECON_LOG="$repoFG/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rcFG=$?
check "foldG. approve REFUSES a parent with open logged bugs" "[ '$rcFG' -ne 0 ]"
check "foldG. and merges nothing" "! grep -q 'pr merge' '$repoFG/gh.log'"
check "foldG. and never runs the reconcile pre-step" "[ ! -s '$repoFG/recon.log' ]"
check "foldG. the parent stays at verify" \
  "grep -q '\"stage\": *\"verify\"' '$(state_of "$repoFG")'"
check "foldG. it names every open child" \
  "cat '$repoFG/out.txt' '$repoFG/err.txt' | qgrep -q '$BUG_OK' \
     && cat '$repoFG/out.txt' '$repoFG/err.txt' | qgrep -q '$BUG_GONE' \
     && cat '$repoFG/out.txt' '$repoFG/err.txt' | qgrep -q '$BUG_WIP'"
check "foldG. it names the one command that clears it" \
  "cat '$repoFG/out.txt' '$repoFG/err.txt' | qgrep -q 'lcars resolve-logs $MID'"
check "foldG. no child issue was closed on the refusal" \
  "! grep -q 'issue close' '$repoFG/gh.log'"
check "foldG. there is no --force escape hatch" \
  "! grep -qE -- '[-][-]force[)=]' '$SCRIPT'"

repoFD="$(new_repo_with_folded_children recorded)"; make_gh_stub "$repoFD/gh"
make_reconcile_stub "$repoFD/recon.sh" 0
export GH_LOG="$repoFD/gh.log"; : >"$GH_LOG"
export RECON_LOG="$repoFD/recon.log"; : >"$RECON_LOG"
rcFD=0
( cd "$repoFD" && LCARS_GH_BIN="$repoFD/gh" LCARS_RUN_SCRIPT="$repoFD/recon.sh" \
    RECON_LOG="$repoFD/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rcFD=$?
sFD="$(state_of "$repoFD")"
cFD() { echo "$repoFD/.git/lcars/missions/$1/state.json"; }

check "fold. the parent still merges and reaches done" \
  "grep -q '\"stage\": *\"done\"' '$sFD'"
check "fold. a verified child whose fix IS on the parent branch is folded to done" \
  "grep -q '\"stage\": *\"done\"' '$(cFD "$BUG_OK")'"
check "fold. the folded child gets lcars:done on its own issue" \
  "grep -q 'add-label lcars:done' '$GH_LOG' && grep -q 'issue edit 91' '$GH_LOG'"
check "fold. a verified child whose fix is NOT on the branch is REFUSED, not folded" \
  "grep -q '\"stage\": *\"verify\"' '$(cFD "$BUG_GONE")'"
check "fold. the refusal is reported, naming the child" \
  "cat '$repoFD/out.txt' '$repoFD/err.txt' | qgrep -q '$BUG_GONE'"
check "fold. a child still mid-flight is left untouched" \
  "grep -q '\"stage\": *\"plan\"' '$(cFD "$BUG_WIP")'"
check "fold. approve still exits 0 — the merge landed, the parent ships" \
  "[ '$rcFD' -eq 0 ]"

# The captain must be able to SEE what happened without reading state.json.
check "fold. names the folded child in the output" \
  "qgrep -q 'Folded logged bug: $BUG_OK' <'$repoFD/out.txt'"
check "fold. warns that the mid-flight child's fix is NOT in this PR" \
  "qgrep -q '$BUG_WIP' <'$repoFD/err.txt'"

# S165 — the fold must also CLOSE the child's issue. A logged-bug child is not a
# ticket sub-issue, so it never lands in the PR's `Closes` list and GitHub never
# auto-closes it on merge: relabelling it `lcars:done` and leaving it OPEN is how
# seven DX-Scorecard bug issues (#78–84) sat open forever after PR #77 merged.
# approve is the SECOND caller of fold_one_child (via resolve-logs complete
# --bug), so the close has to fire from here too, not just the resolve-logs CLI.
check "fold. the folded child's issue is CLOSED, not merely relabelled" \
  "grep -q 'issue close 91' '$GH_LOG'"
check "fold. the REFUSED child's issue is NOT closed (no fix ⇒ no close)" \
  "! grep -q 'issue close 92' '$GH_LOG'"
check "fold. the mid-flight child's issue is NOT closed" \
  "! grep -q 'issue close 93' '$GH_LOG'"
check "fold. the PARENT's issue is NOT closed by the fold (it rides the PR's Closes)" \
  "! grep -q 'issue close 42' '$GH_LOG'"

# …and a close the forge refuses must never turn a landed merge into a failure.
make_gh_stub_close_fail() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "close" ]; then exit 1; fi
exit 0
EOF
  chmod +x "$1"
}
repoFC="$(new_repo_with_folded_children recorded)"; make_gh_stub_close_fail "$repoFC/gh"
make_reconcile_stub "$repoFC/recon.sh" 0
export GH_LOG="$repoFC/gh.log"; : >"$GH_LOG"
export RECON_LOG="$repoFC/recon.log"; : >"$RECON_LOG"
rcFC=0
( cd "$repoFC" && LCARS_GH_BIN="$repoFC/gh" LCARS_RUN_SCRIPT="$repoFC/recon.sh" \
    RECON_LOG="$repoFC/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rcFC=$?
check "foldC. a failed issue close does NOT fail the approve" "[ '$rcFC' -eq 0 ]"
check "foldC. the child is still folded to done" \
  "grep -q '\"stage\": *\"done\"' '$repoFC/.git/lcars/missions/$BUG_OK/state.json'"
check "foldC. the captain sees a legible note about the issue it could not close" \
  "cat '$repoFC/out.txt' '$repoFC/err.txt' | qgrep -qi 'could not close.*91'"

# --- Behaviour FOLD-2: no children ⇒ byte-identical to today ------------------
# A plain feature mission with no logged bugs must not gain any fold chatter.
repoND="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoND/gh"
make_reconcile_stub "$repoND/recon.sh" 0
export GH_LOG="$repoND/gh.log"; : >"$GH_LOG"
export RECON_LOG="$repoND/recon.log"; : >"$RECON_LOG"
rcND=0
( cd "$repoND" && LCARS_GH_BIN="$repoND/gh" LCARS_RUN_SCRIPT="$repoND/recon.sh" \
    RECON_LOG="$repoND/recon.log" bash "$SCRIPT" \
    --mission "$MID" >out.txt 2>err.txt ) || rcND=$?
check "fold2. a mission with no logged bugs approves exactly as before" \
  "[ '$rcND' -eq 0 ] && grep -q '\"stage\": *\"done\"' '$(state_of "$repoND")'"
check "fold2. prints no fold line when there is nothing to fold" \
  "! qgrep -qi 'logged bug' <'$repoND/out.txt'"

# ==========================================================================
# --- S196 fix round: APPROVE MUST NOT DESTROY THE ENGINE'S PROVENANCE -------
# ==========================================================================
# Measured THREE times in one day's live runs (tests/drives/s196-capstone/):
#   • adopt asked which engine to use here, the captain answered, the card read
#     `copilot · chosen at adopt` (engineSource: adopt-chosen);
#   • `lcars approve` merged it, and the card read `copilot · $LCARS_WORKER_BIN`
#     (engineSource: env);
#   • and with no adopt at all, a mission pinned `workerBin: copilot` with
#     $LCARS_WORKER_BIN unset in every shell ALSO ended up `env`, while approve
#     printed `worker: copilot (bin: env)`.
#
# WHY: approve deliberately pins the mission's engine for its reconcile leg
# (`export LCARS_WORKER_BIN="$engine"`, so a copilot mission heals on copilot
# rather than host-detecting claude). That pin is correct and stays. run.sh's
# recorder then saw an env var win the precedence race and overwrote the more
# specific truth. The ENGINE was always right; only the ATTRIBUTION was wrong —
# and the attribution is the entire point of the feature.
#
# THE CURE approve carries here is a STATEMENT, not a hint: alongside the pin it
# exports $LCARS_WORKER_BIN_INTERNAL=1, saying "this is LCARS re-asserting this
# mission's own engine, not an operator act". The producer records; the recorder
# does not infer from a value comparison. (The resolver half is pinned in
# tests/worker-resolve.test.sh 3s-3x.)
#
# THESE RUN THE **REAL** run.sh — not the reconcile stub the rest of this suite
# uses — because the defect lives in the handshake BETWEEN the two scripts and a
# stub cannot have it. It is free: the fixture's base is never ahead of the
# mission branch, so reconcile_gate returns at its not-ahead check before any
# worker exists. Both engines are shimmed on $PATH anyway, argv-recording, and
# the counts are asserted ZERO — so a future change that does reach for a worker
# from here is caught as a count, not as a bill.
REAL_RUN="$REPO_ROOT/skills/lcars-run/run.sh"

# Both engines as argv-recording shims. Nothing here may spend money.
PROV_BIN="$TMPROOT/prov-bin"; mkdir -p "$PROV_BIN"
for _e in claude copilot; do
  cat >"$PROV_BIN/$_e" <<EOF
#!/usr/bin/env bash
echo "$_e \$*" >>"$TMPROOT/prov-$_e.log"
exit 0
EOF
  chmod +x "$PROV_BIN/$_e"
done
: >"$TMPROOT/prov-claude.log"; : >"$TMPROOT/prov-copilot.log"
prov_count() { [ -f "$TMPROOT/prov-$1.log" ] && wc -l <"$TMPROOT/prov-$1.log" | tr -d ' ' || echo 0; }

# Seed the engine fields the way every LCARS state writer does — one field per
# line, inserted after line 1, `base` left LAST (the only shape the house
# field-writer breaks on).
seed_engine() { # state-file  workerBin  [engineSource]
  local s="$1" wb="$2" src="${3:-}"
  { head -1 "$s"
    [ -n "$wb" ] && printf '  "workerBin": "%s",\n' "$wb"
    if [ -n "$src" ]; then
      printf '  "engineResolved": "%s",\n' "$wb"
      printf '  "engineSource": "%s",\n' "$src"
    fi
    tail -n +2 "$s"
  } >"$s.tmp" && mv "$s.tmp" "$s"
}
jok_()   { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }
jget_()  { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));v=d.get(sys.argv[2]);sys.stdout.write("" if v is None else str(v))' "$1" "$2" 2>/dev/null; }
jlast_() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));sys.stdout.write(list(d.keys())[-1] if d else "")' "$1" 2>/dev/null; }

# Run the REAL approve with the REAL run.sh as its reconcile, both engines
# shimmed, and the host markers scrubbed so this session's own CLAUDECODE=1 can
# never be the reason a test passes.
approve_real() { # repo  [extra env assignments...]
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDECODE -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_BIN_INTERNAL -u LCARS_WORKER_MODEL \
      PATH="$PROV_BIN:$PATH" \
      LCARS_GH_BIN="$repo/gh" LCARS_RUN_SCRIPT="$REAL_RUN" \
      "$@" bash "$SCRIPT" --mission "$MID" >out.txt 2>&1 )
}

# --- prov1: THE HEADLINE — the captain's answer at the adopt prompt ---------
repoP1="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoP1/gh"
export GH_LOG="$repoP1/gh.log"; : >"$GH_LOG"
sP1="$(state_of "$repoP1")"
seed_engine "$sP1" copilot adopt-chosen
rcP1=0; approve_real "$repoP1" || rcP1=$?
check "prov1. approve still ships the mission (the cure changes nothing else)" \
  "[ '$rcP1' -eq 0 ] && [ \"\$(jget_ '$sP1' stage)\" = 'done' ]"
check "prov1. THE HEADLINE: \`adopt-chosen\` SURVIVES approve" \
  "[ \"\$(jget_ '$sP1' engineSource)\" = 'adopt-chosen' ]"
check "prov1. it is NOT rewritten to env by approve's own pin" \
  "[ \"\$(jget_ '$sP1' engineSource)\" != 'env' ]"
check "prov1. the engine the card names is unchanged" \
  "[ \"\$(jget_ '$sP1' engineResolved)\" = 'copilot' ]"
check "prov1. the mission's own pin is untouched" \
  "[ \"\$(jget_ '$sP1' workerBin)\" = 'copilot' ]"
check "prov1. state.json is VALID JSON after approve" "jok_ '$sP1'"
check "prov1. and \`base\` is still the LAST field" "[ \"\$(jlast_ '$sP1')\" = 'base' ]"

# --- prov2: the --engine conversion path ------------------------------------
repoP2="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoP2/gh"
export GH_LOG="$repoP2/gh.log"; : >"$GH_LOG"
sP2="$(state_of "$repoP2")"
seed_engine "$sP2" claude adopt-converted
rcP2=0; approve_real "$repoP2" || rcP2=$?
check "prov2. \`adopt-converted\` survives approve too" \
  "[ \"\$(jget_ '$sP2' engineSource)\" = 'adopt-converted' ]"
check "prov2. the mission still merges" \
  "[ '$rcP2' -eq 0 ] && [ \"\$(jget_ '$sP2' stage)\" = 'done' ]"
check "prov2. state.json PARSES, \`base\` last" \
  "jok_ '$sP2' && [ \"\$(jlast_ '$sP2')\" = 'base' ]"

# --- prov3: a plain mission pin, NO adopt anywhere --------------------------
# The third sighting. Nothing external pinned anything; approve's own pin was
# the only $LCARS_WORKER_BIN in the world, and it claimed the credit.
repoP3="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoP3/gh"
export GH_LOG="$repoP3/gh.log"; : >"$GH_LOG"
sP3="$(state_of "$repoP3")"
seed_engine "$sP3" copilot            # workerBin only — no adopt record
rcP3=0; approve_real "$repoP3" || rcP3=$?
check "prov3. a bare mission pin records \`mission\`, never \`env\`" \
  "[ \"\$(jget_ '$sP3' engineSource)\" = 'mission' ]"
check "prov3. the resolved engine is the pinned one" \
  "[ \"\$(jget_ '$sP3' engineResolved)\" = 'copilot' ]"
# approve's OWN printed line is part of the defect: it said `bin: env` while the
# mission was pinned. What it prints and what it persists must be one answer.
check "prov3. approve's printed line says the pin resolved it" \
  "qgrep -q 'bin: mission' <'$repoP3/out.txt'"
check "prov3. approve never prints \`bin: env\` for its own internal pin" \
  "! qgrep -q 'bin: env' <'$repoP3/out.txt'"
check "prov3. state.json PARSES, \`base\` last" \
  "jok_ '$sP3' && [ \"\$(jlast_ '$sP3')\" = 'base' ]"

# --- prov4: a GENUINE external $LCARS_WORKER_BIN still records `env` --------
# The cure must not make the env source unrecordable. This mission records NO
# engine of its own, so approve pins nothing and the captain's own shell variable
# is the real and only reason this run used copilot.
repoP4="$(new_repo_with_open_pr_mission)"; make_gh_stub "$repoP4/gh"
export GH_LOG="$repoP4/gh.log"; : >"$GH_LOG"
sP4="$(state_of "$repoP4")"
rcP4=0; approve_real "$repoP4" LCARS_WORKER_BIN=copilot || rcP4=$?
check "prov4. a real operator env var is still recorded as \`env\`" \
  "[ \"\$(jget_ '$sP4' engineSource)\" = 'env' ]"
check "prov4. with the engine it actually named" \
  "[ \"\$(jget_ '$sP4' engineResolved)\" = 'copilot' ]"
check "prov4. and approve says so out loud" "qgrep -q 'bin: env' <'$repoP4/out.txt'"
check "prov4. state.json PARSES, \`base\` last" \
  "jok_ '$sP4' && [ \"\$(jlast_ '$sP4')\" = 'base' ]"

# --- prov5: THE COUNT — none of that spent a penny --------------------------
check "prov5. THE COUNT: the claude shim was invoked ZERO times" \
  "[ \"\$(prov_count claude)\" -eq 0 ]"
check "prov5. THE COUNT: the copilot shim was invoked ZERO times" \
  "[ \"\$(prov_count copilot)\" -eq 0 ]"

# ==========================================================================
echo
printf 'lcars approve: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
