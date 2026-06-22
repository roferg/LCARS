#!/usr/bin/env bash
#
# lcars approve — ship a verified Mission: MERGE its open PR and mark it Done.
#
# S75 changed approve's job. Verify now AUTO-OPENS the PR (the driver, reusing
# the shared pr-lib.sh open_pr) and parks the Mission "in review — PR open".
# `lcars approve` is the captain's MERGE signal: on a Mission at "verify" WITH an
# open PR (prUrl recorded in state.json), it merges the PR via the host adapter,
# then — and ONLY on a successful merge — clears the stage labels, marks the
# issue lcars:done, moves state.json's stage to "done", and prints the result.
#
# It is purely mechanical — no LLM. It NEVER marks a Mission Done without a real
# merge: if the merge call fails (auth, conflicts, gh absent) it stays at verify
# with a clear message. Approve REQUIRES an open PR to merge — Verify opens it.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary  (default: gh)
#   LCARS_GIT_BIN  the git binary (default: git)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
RELABEL_NOTE=""

# The host-integration adapter — the ONE place that speaks to a forge. It lives
# in the sibling lcars-run skill dir; $LCARS_HOST_ADAPTER overrides that path.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SELF_DIR/../lcars-run/host-adapter.sh}"
# The sibling run.sh — its `reconcile` subcommand is the S76 self-heal engine the
# merge gate runs BEFORE merging (BUG-037). Override the path for tests.
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SELF_DIR/../lcars-run/run.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }

die() { printf 'lcars approve: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as run.sh / file.sh) -------------
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# --- locate the mission (mirrors run.sh) -----------------------------------
locate_mission() {
  local id="$1" gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSION_DIR="$gitdir/lcars/missions/$id"
  STATE="$MISSION_DIR/state.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$id' under .git/lcars/missions/ — check the id."
  [ -f "$STATE" ]       || die "mission '$id' has no state.json — its state is corrupt."
}

require_stage() {
  local stage; stage="$(json_str "$STATE" stage)"
  [ "$stage" = "$1" ] || die "mission is at stage '${stage:-unknown}', not '$1' — approve only ships a verified mission."
}

set_stage() {
  local newstage="$1" tmp; tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# add or replace a string field (used by pr-lib's open_pr to record prUrl).
state_del() { local tmp; tmp="$(mktemp)"; grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"; }
# JSON-string-safe escape (no surrounding quotes): backslash/quote, then awk
# escapes every control char (newline/tab/CR → \n \t \r, rest \u00XX) so any
# multi-line value yields VALID JSON. jq-free. Order: backslash first.
json_escape() {
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}
state_set_str() {
  state_del "$1"
  local esc tmp; esc="$(json_escape "$2")"; tmp="$(mktemp)"
  K="$1" V="$esc" awk 'NR==1{print; printf "  \"%s\": \"%s\",\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- gh relabel: best-effort, never blocks the local stage change ----------
gh_relabel() { # "add labels…"  "remove labels…"
  local add="$1" rem="$2"
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."; return 0 ;;
  esac
  local hand="+${add// /,} -${rem// /,}"
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    host issue-relabel "$issue" --add "$add" --remove "$rem" \
      || RELABEL_NOTE="  ⚠ gh issue edit failed — relabel #$issue by hand ($hand)."
  else
    RELABEL_NOTE="  ⚠ gh not found — skipped relabel; do it by hand (#$issue: $hand)."
  fi
}

# The shared PR-open/builders library (title/body/manifest/open_pr). approve
# no longer OPENS a PR (Verify does), but sources the lib so a captain who runs
# approve on a verify mission with NO PR yet gets a graceful, consistent message
# rather than a crash — and so the lib has one home both surfaces share.
# shellcheck source=skills/lcars-approve/pr-lib.sh
. "$SELF_DIR/pr-lib.sh"

# --- args ------------------------------------------------------------------
# --reapprove (or LCARS_REAPPROVE=1, the flag the web layer invokes) runs ONLY
# the merge step on an ALREADY-reconciled, already-green branch — the human's
# sign-off after a self-heal converged (reconcileStatus=awaiting-reapprove). It
# skips the reconcile/self-heal engine entirely and goes straight to the
# push-then-merge path, with the push result CAPTURED (BUG-066) so a rejected
# push surfaces as merge-failed instead of a silent revert.
MISSION_ID=""
REAPPROVE="${LCARS_REAPPROVE:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)   MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*) MISSION_ID="${1#--mission=}"; shift ;;
    --reapprove) REAPPROVE=1; shift ;;
    *)           die "unknown argument: $1" ;;
  esac
done
[ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>."

locate_mission "$MISSION_ID"
require_stage verify

BRANCH="$(json_str "$STATE" branch)"
BASE="$(json_str "$STATE" base)"; BASE="${BASE:-main}"

# --- the open PR approve is here to MERGE ------------------------------------
# Verify auto-opens the PR and records prUrl/prNumber. approve REQUIRES that PR
# to merge. With no recorded PR, the Mission was not driven through the new
# Verify auto-open (e.g. an old mission) — refuse, staying at verify, with an
# actionable message. We never silently open-and-merge in one shot.
PR_URL="$(json_str "$STATE" prUrl)"
PR_NUM="$(json_raw "$STATE" prNumber)"
case "$PR_URL" in
  http*|*/pull/*) : ;;
  *) die "no open PR recorded for this mission — run \`lcars run $MISSION_ID\` so Verify opens the PR, then approve to merge it. Mission stays at verify." ;;
esac

# --- the merge step (shared by the normal flow + the reapprove flow) ---------
# Push the (possibly reconciled) branch to origin with its result CAPTURED
# (BUG-066), then `gh pr merge`. On a clean push → merge → Done. On a push that
# was REJECTED (non-fast-forward / diverged) we do NOT proceed to merge: we set
# reconcileStatus=merge-failed with the real reason and KEEP awaitingHuman so the
# gate stays visible — never a silent revert. A benign push miss (no remote / not
# configured, the test-repo case) is distinguished from a real rejection and is
# allowed to fall through to gh pr merge (the real gate). On a gh-pr-merge failure
# we likewise surface the real reason via reconcileStatus=merge-failed.
do_merge() {
  command -v "$GH_BIN" >/dev/null 2>&1 \
    || die "gh not found — cannot merge PR $PR_URL. Mission stays at verify (merge it by hand)."

  # Push the branch so the remote PR head reflects any reconciled/healed tree.
  # Capture stderr + exit code; classify rejection (must block) vs benign miss.
  if [ -n "$BRANCH" ] && command -v "$GIT_BIN" >/dev/null 2>&1; then
    local push_out push_rc=0
    push_out="$("$GIT_BIN" push origin "$BRANCH" 2>&1)" || push_rc=$?
    if [ "$push_rc" -ne 0 ]; then
      case "$push_out" in
        *'[rejected]'*|*'non-fast-forward'*|*'! [remote rejected]'*|*'fetch first'*|*'tip of your current branch is behind'*)
          # A real divergence — the remote PR branch moved on. Do NOT merge.
          local sha; sha="$(json_str "$STATE" reconcileMergeSha)"
          local note="Could not update the PR branch: non-fast-forward (the remote PR branch diverged). The heal is green at ${sha:-the reconciled tip} — force-update the PR branch (\`git push --force-with-lease origin $BRANCH\`) or push manually, then reapprove."
          state_set_str reconcileStatus "merge-failed"
          state_set_str reconcileNote "$note"
          state_set_raw awaitingHuman true
          state_set_str pendingQuestion "$note"
          die "$note Mission stays at verify."
          ;;
        *'does not appear to be a git repository'*|*'No configured push destination'*|*'No such remote'*|*'Could not read from remote'*|*'Authentication failed'*|*'Permission denied'*|*'could not read Username'*)
          # Benign in a test/local repo (no remote / no auth): the PR branch is
          # the local branch. Fall through to gh pr merge — the real gate.
          : ;;
        *)
          # Unknown push failure — fall through to gh pr merge, which is the
          # authoritative gate and will fail loudly if the branch is stale.
          : ;;
      esac
    fi
  fi

  # A merge selector: prefer the recorded PR number, else the branch.
  local MERGE_ARGS=()
  case "$PR_NUM" in
    ''|null) MERGE_ARGS=(--head "$BRANCH") ;;
    *)       MERGE_ARGS=(--number "$PR_NUM") ;;
  esac

  if ! host pr-merge "${MERGE_ARGS[@]}"; then
    local note="gh pr merge failed for $PR_URL — resolve it (conflicts/checks/auth) and re-run \`lcars approve $MISSION_ID\` (or \`--reapprove\`), or merge on GitHub. Mission stays at verify."
    state_set_str reconcileStatus "merge-failed"
    state_set_str reconcileNote "$note"
    state_set_raw awaitingHuman true
    state_set_str pendingQuestion "$note"
    die "$note"
  fi

  # Merge landed — clear the reconcile gate state and flip the Mission to Done.
  state_del reconcileStatus
  state_del reconcileNote
  state_del reconcileMergeSha
  state_del awaitingHuman
  state_del pendingQuestion
  gh_relabel "lcars:done" "lcars:verify lcars:awaiting-human"
  set_stage "done"
  state_set_str review "merged"

  echo "APPROVE: merged — $(pr_title)"
  echo "  Merged PR: $PR_URL"
  echo "  Branch:    $BRANCH → $BASE"
  echo "  Stage:     done"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- REAPPROVE: merge-only on an already-reconciled-green branch -------------
# The web/inbox layer (or `lcars approve --reapprove`) invokes this AFTER the
# captain has signed off on a self-heal that converged green (state set by the
# reconcile gate: reconcileStatus=awaiting-reapprove). Skip the reconcile engine
# entirely and run ONLY the merge step.
if [ -n "$REAPPROVE" ]; then
  rstat="$(json_str "$STATE" reconcileStatus)"
  case "$rstat" in
    awaiting-reapprove|merge-failed) : ;;  # the expected gate to clear.
    *) : ;;  # tolerate a reapprove with no recorded gate — still just merges.
  esac
  do_merge
fi

# --- self-heal-before-escalate: reconcile a possibly-behind base FIRST -------
# Before merging, run the S76 reconcile/self-heal engine (the sibling run.sh
# `reconcile` subcommand) so a PR that fell behind a moved base is merged into
# the mission branch, re-tested, and self-healed to green — instead of letting
# `gh pr merge` hit a conflict and escalate. It is a cheap no-op (exit 0) when
# the base is not ahead. Pin the mission engine so a copilot mission heals on
# copilot (a CLAUDECODE-tagged env would otherwise host-detect claude).
engine="$(json_str "$STATE" workerBin)"
rcode=0
# The mission engine is plumbed via the environment (an assignment prefix built
# by expansion is parsed as a command, not a var — export into the subshell).
( export LCARS_GH_BIN="$GH_BIN" LCARS_GIT_BIN="$GIT_BIN"
  [ -n "$engine" ] && export LCARS_WORKER_BIN="$engine"
  bash "$RUN_SCRIPT" reconcile --mission "$MISSION_ID" ) || rcode=$?
case "$rcode" in
  0)  : ;;  # up to date (base not ahead) → proceed to merge directly below.
  10) echo "APPROVE: reconciling with the updated base — self-heal in flight. Mission stays at verify; re-run \`lcars approve $MISSION_ID\` once it's green."; exit 0 ;;
  20) echo "APPROVE: the base moved ahead and the self-heal was escalated to you (awaiting your answer). Mission stays at verify."; exit 0 ;;
  30) # BUG-067: the self-heal CONVERGED GREEN — do NOT auto-merge. The reconcile
      # gate persisted reconcileStatus=awaiting-reapprove + reconcileNote and
      # raised the awaiting-human gate. STOP here; the captain reapproves to merge.
      note="$(json_str "$STATE" reconcileNote)"
      echo "APPROVE: ${note:-the base moved ahead and the self-heal converged green.} Mission stays at verify awaiting your reapprove — run \`lcars approve $MISSION_ID --reapprove\` (or reapprove from the board) to merge."
      exit 0 ;;
  *)  echo "lcars approve: reconcile failed (rc=$rcode). Mission stays at verify." >&2; exit 1 ;;
esac

# --- merge — only a SUCCESSFUL merge flips the Mission to Done ----------------
# base not ahead (rc=0): the recorded PR is already up to date — merge directly.
do_merge
