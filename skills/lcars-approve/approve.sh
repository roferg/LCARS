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
# add or replace a BARE field (true/false/number, unquoted) — mirrors
# run.sh:state_set_raw / pause.sh. BUG-068: the merge-failed paths call this to
# set `awaitingHuman true`; it was undefined here so those lines errored
# ("command not found") and the gate flag never got set.
state_set_raw() { # key token
  state_del "$1"
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'NR==1{print; printf "  \"%s\": %s,\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- append-only mission event (BUG-071) -----------------------------------
# Mirrors run.sh / pause.sh emit_event: one short single-line JSON record per
# milestone, written in APPEND mode (atomic under PIPE_BUF) to the mission's
# events.jsonl so the card timeline shows the ship. approve had NO emit_event,
# so a merge never recorded a `merged` milestone. NO-OP-SAFE: no MISSION_DIR →
# returns 0. Timestamp overridable via $LCARS_NOW for deterministic tests.
emit_event() { # type stage detail
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ts type stage detail mid
  ts="${LCARS_NOW:-$(date +%s)}"
  type="$(json_escape "${1:-}")"; stage="$(json_escape "${2:-}")"
  detail="$(json_escape "${3:-}")"; mid="$(json_escape "${MISSION_ID:-}")"
  printf '{"ts":%s,"mission":"%s","stage":"%s","type":"%s","detail":"%s"}\n' \
    "$ts" "$mid" "$stage" "$type" "$detail" >>"$MISSION_DIR/events.jsonl"
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
          # A non-fast-forward push: the remote PR head diverged from our local
          # branch. BUG-077: a reconcile that was killed/parked and retried leaves
          # the local mission branch at the dead attempt's merge commit, so the
          # retry's reconciled tip DIVERGES from the last-pushed remote PR head.
          # When the local branch tip IS the freshly-reconciled green tip
          # (reconcileMergeSha) AND it already CONTAINS current origin/main, the
          # local IS the authoritative resolution → auto-recover with a
          # --force-with-lease push and proceed to merge. STALENESS GUARD
          # (BUG-075): if origin/main advanced PAST the heal (local no longer
          # contains it) we must NOT force over a remote that legitimately moved —
          # surface merge-failed asking the captain to re-reconcile. And a local
          # tip that is not the known green reconcileMergeSha is never forced.
          local sha local_tip recovered=0
          sha="$(json_str "$STATE" reconcileMergeSha)"
          local_tip="$("$GIT_BIN" rev-parse "$BRANCH" 2>/dev/null)"
          if [ -n "$sha" ] && [ "$local_tip" = "$sha" ]; then
            # Refresh remote-tracking refs, then check the local branch still
            # contains current origin/$BASE (the heal incorporates current main).
            "$GIT_BIN" fetch origin "$BASE" >/dev/null 2>&1 || true
            if "$GIT_BIN" merge-base --is-ancestor "origin/$BASE" "$BRANCH" >/dev/null 2>&1; then
              # Authoritative + still on top of current main → force-with-lease.
              if "$GIT_BIN" push --force-with-lease origin "$BRANCH" >/dev/null 2>&1; then
                recovered=1
              else
                local fnote="Could not force-update the PR branch (\`git push --force-with-lease origin $BRANCH\`) — the remote lease was stale (someone else pushed). Re-run the reconcile, then reapprove."
                state_set_str reconcileStatus "merge-failed"
                state_set_str reconcileNote "$fnote"
                state_set_raw awaitingHuman true
                state_set_str pendingQuestion "$fnote"
                die "$fnote Mission stays at verify."
              fi
            else
              # STALENESS GUARD: main moved past the heal → never force.
              local mnote="main moved since the heal — re-reconcile required. origin/$BASE advanced past the reconciled tip ($sha); the heal no longer incorporates current main. Re-run \`lcars approve $MISSION_ID\` to reconcile against the new base, then reapprove."
              state_set_str reconcileStatus "merge-failed"
              state_set_str reconcileNote "$mnote"
              state_set_raw awaitingHuman true
              state_set_str pendingQuestion "$mnote"
              die "$mnote Mission stays at verify."
            fi
          fi
          if [ "$recovered" -ne 1 ]; then
            # Not the authoritative tip (or no recorded green tip) — do NOT force;
            # surface the divergence for the captain to resolve, as before.
            local note="Could not update the PR branch: non-fast-forward (the remote PR branch diverged) and the local tip is not the recorded reconciled green tip. The heal is green at ${sha:-the reconciled tip} — re-run the reconcile (\`lcars approve $MISSION_ID\`) or push manually (\`git push --force-with-lease origin $BRANCH\`), then reapprove."
            state_set_str reconcileStatus "merge-failed"
            state_set_str reconcileNote "$note"
            state_set_raw awaitingHuman true
            state_set_str pendingQuestion "$note"
            die "$note Mission stays at verify."
          fi
          # recovered: fall through to gh pr merge below.
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

  # BUG-069: right after a push GitHub needs a few seconds to RECOMPUTE the PR's
  # mergeability, so the FIRST `gh pr merge` can spuriously fail with a transient
  # "not mergeable yet" even though nothing is wrong. RETRY the merge with a
  # short bounded backoff before falling into the merge-failed path. A real
  # CONFLICTING/DIRTY state simply keeps failing and surfaces after the retries
  # exhaust — we never paper over a true conflict, only ride out the post-push
  # lag. Tunable via env so the test drives it with zero real sleep.
  local merge_tries="${LCARS_MERGE_RETRIES:-6}"        # up to ~6 attempts …
  local merge_sleep="${LCARS_MERGE_RETRY_SLEEP:-5}"    # … ~5s apart (~30s total)
  local attempt=1 merged_ok=0
  while [ "$attempt" -le "$merge_tries" ]; do
    if host pr-merge "${MERGE_ARGS[@]}"; then
      merged_ok=1; break
    fi
    # The attempt failed. It may be the post-push lag (retry) or a real conflict
    # (will keep failing). If the PR has ALREADY merged out from under us (a
    # prior attempt that reported failure but actually landed), treat as success.
    if host pr-view "${MERGE_ARGS[@]}" 2>/dev/null | grep -qi $'state\tMERGED'; then
      merged_ok=1; break
    fi
    if [ "$attempt" -lt "$merge_tries" ]; then
      [ "$merge_sleep" = "0" ] || sleep "$merge_sleep"
    fi
    attempt=$((attempt + 1))
  done

  if [ "$merged_ok" -ne 1 ]; then
    local note="gh pr merge failed for $PR_URL after $merge_tries attempt(s) — resolve it (conflicts/checks/auth) and re-run \`lcars approve $MISSION_ID\` (or \`--reapprove\`), or merge on GitHub. Mission stays at verify."
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

  # BUG-071: record the ship on the mission timeline so the card shows the
  # `merged` milestone (and a terminal `mission_done`), not just stdout.
  emit_event merged verify "PR merged — $PR_URL"
  emit_event mission_done done "Mission shipped — the PR is merged"

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
  emit_event reapprove verify "captain reapproved a converged self-heal — merging $PR_URL"
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
