#!/usr/bin/env bash
#
# lcars feedback — send a verified Mission back to Align with the captain's note.
#
# This is the Verify feedback loop (vision.md → Verify can send a Mission back).
# It is purely mechanical — no LLM — and does three things:
#   1. appends the feedback to feedback.md, a durable, accumulating history (so
#      a Mission bounced back more than once keeps every note), each entry
#      stamped so Align can see the order,
#   2. resets state.json's stage to "align",
#   3. moves the GitHub label to lcars:align (kept in step with the stage).
#
# Crucially it DELETES nothing: the PRD, the research findings, the validated and
# approved plans all stay on disk. So the next `lcars run <id>` re-enters Align
# with the FULL prior history — the spec, the artifacts, and every feedback note
# — rather than starting cold.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary             (default: gh)
#   LCARS_NOW      ISO stamp for the entry   (default: now, UTC)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
RELABEL_NOTE=""
PR_NOTE=""

# The host-integration adapter — the ONE place that speaks to a forge. Lives in
# the sibling lcars-run skill dir; $LCARS_HOST_ADAPTER overrides the path so
# tests can stub the whole adapter.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# --- THE state.json field writer (S207) ------------------------------------
# ONE family, in ONE place: lcars_state_set (a raw JSON token) /
# lcars_state_set_string (plain text, escaped for you) / lcars_state_unset.
# This file used to carry its own copy, as seven others did, and every copy
# corrupted the object when the field it wrote or cleared was the object's LAST
# one (S189 found it in adopt; S202 made it reachable through the gate clears).
# A MISSING library is FATAL here rather than degraded: a fallback writer is
# exactly how two ways of writing one field get back into the tree.
LCARS_STATE_LIB="${LCARS_STATE_LIB:-$SELF_DIR/../lcars-init/lcars-state.sh}"
[ -f "$LCARS_STATE_LIB" ] || {
  echo "LCARS: the state writer library is missing at $LCARS_STATE_LIB — reinstall LCARS (./install.sh)." >&2
  exit 1
}
# shellcheck source=../lcars-init/lcars-state.sh
. "$LCARS_STATE_LIB"

HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SELF_DIR/../lcars-run/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }

# S188 — the living "## Verify feedback" comment. The comment mirror is SOURCED
# (it only defines functions, exactly as run.sh sources it) so a send-back reuses
# the EXACT S65 create-then-edit idiom — comments.json as the idempotency truth,
# bodies over stdin — instead of growing a second, subtly different one here. It
# leans on this script's own MISSION_DIR / STATE / json_raw / host, which carry
# the same names run.sh gives them. Best-effort: a missing lib means no mirror,
# never a failed send-back. $LCARS_COMMENT_MIRROR overrides the path for tests.
COMMENT_MIRROR="${LCARS_COMMENT_MIRROR:-$SELF_DIR/../lcars-run/comment-mirror.sh}"
[ -f "$COMMENT_MIRROR" ] && . "$COMMENT_MIRROR"

die() { printf 'lcars feedback: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as run.sh / file.sh) -------------
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }


# --- S189: solo ownership, the light lock ----------------------------------
# A mission assigned to SOMEONE ELSE on GitHub is READ-ONLY to this laptop's
# write verbs. `lcars feedback` BOUNCES a mission back a stage and rewrites its state, so it consults the lock; the READ verbs (status,
# buddy, the viewscreen's reads) never do. The remedy is deliberately a HUMAN act
# on GitHub — the solo protocol's premise is that the captain moves ownership
# where both laptops can see it, and LCARS never takes a mission off anyone.
#
# The library lives in the sibling lcars-run skill dir (the same reach this
# script already makes for the host adapter). A MISSING library leaves the verb
# unenforced — exactly pre-S189 behaviour — rather than refusing blindly, and
# LCARS_OWNER_ENFORCE=0 bypasses the lock for harness debugging.
OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SELF_DIR/../lcars-run/ownership.sh}"
[ -f "$OWNERSHIP_LIB" ] && . "$OWNERSHIP_LIB"

# owner_lock_or_die <issue> — refuse with ONE plain line, or return.
# lcars_owner_lock_reason returns 0 (and echoes the line) ONLY when someone else
# demonstrably holds the mission: unassigned, an unreachable forge and an
# unresolvable identity all fall through to "proceed", because a lock that fires
# on uncertainty locks the captain out of his own work.
owner_lock_or_die() { # <issue>
  local r
  command -v lcars_owner_lock_reason >/dev/null 2>&1 || return 0
  r="$(lcars_owner_lock_reason "${1:-}")" || return 0
  [ -n "$r" ] && die "$r"
  return 0
}

# xo_lock_or_die <mission-dir> — refuse with ONE plain line, or return (S201).
# THE SECOND REASON ON THE SAME SEAM. Number One acts on the captain's behalf
# THROUGH these very verbs, so while it holds a mission a second hand on that
# mission is a race with his own first officer. `lcars_xo_lock_reason` returns 0
# (and echoes the line) ONLY when the mission's RECORDED state says
# numberOne.status is `engaged`; no state, no key, stood-down and finished all
# fall through to "proceed", exactly like the owner lock's posture, and
# LCARS_XO_ENFORCE=0 bypasses it. The remedy is `lcars xo off <id>`.
xo_lock_or_die() { # <mission-dir>
  local r
  command -v lcars_xo_lock_reason >/dev/null 2>&1 || return 0
  r="$(lcars_xo_lock_reason "${1:-}")" || return 0
  [ -n "$r" ] && die "$r"
  return 0
}

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

set_stage() {
  local newstage="$1" tmp; tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# Close the Mission's open PR (S75): send-back returns the Mission to Align, so
# the in-flight PR must not linger open. Best-effort — gh absent / a forge error
# leaves a note but never blocks the send-back (the stage reset is the contract).
close_open_pr() {
  local pr num branch sel_args=()
  pr="$(json_str "$STATE" prUrl)"
  case "$pr" in
    http*|*/pull/*) : ;;
    *) return 0 ;;   # no PR on file → nothing to close.
  esac
  num="$(json_raw "$STATE" prNumber)"
  branch="$(json_str "$STATE" branch)"
  case "$num" in
    ''|null) sel_args=(--head "$branch") ;;
    *)       sel_args=(--number "$num") ;;
  esac
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    host pr-close "${sel_args[@]}" \
      || PR_NOTE="  ⚠ could not close PR $pr — close it by hand."
  else
    PR_NOTE="  ⚠ gh not found — close PR $pr by hand."
  fi
  # Clear the recorded PR + review marker either way, so a re-entry to Verify
  # opens a FRESH PR rather than re-using the closed one.
  lcars_state_unset "$STATE" prUrl
  lcars_state_unset "$STATE" prNumber
  lcars_state_unset "$STATE" review
}

# --- gh relabel: best-effort, never blocks the local stage change ----------
gh_relabel() { # "add labels…"  "remove labels…"
  local add="$1" rem="$2" l
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."; return 0 ;;
  esac
  local hand="+${add// /,} -${rem// /,}"
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    local args=()
    for l in $add; do args+=(--add-label "$l"); done
    for l in $rem; do args+=(--remove-label "$l"); done
    "$GH_BIN" issue edit "$issue" "${args[@]}" >/dev/null 2>&1 \
      || RELABEL_NOTE="  ⚠ gh issue edit failed — relabel #$issue by hand ($hand)."
  else
    RELABEL_NOTE="  ⚠ gh not found — skipped relabel; do it by hand (#$issue: $hand)."
  fi
}

# --- args ------------------------------------------------------------------
MISSION_ID=""; FEEDBACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)    MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*)  MISSION_ID="${1#--mission=}"; shift ;;
    --feedback)   FEEDBACK="${2:-}"; shift 2 ;;
    --feedback=*) FEEDBACK="${1#--feedback=}"; shift ;;
    *)            die "unknown argument: $1" ;;
  esac
done
[ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>."
[ -n "$FEEDBACK" ]   || die "no feedback — pass --feedback \"<text>\" with what to fix."

locate_mission "$MISSION_ID"

# S189: the light lock. BEFORE the feedback.md append — a refusal must leave
# no trace on a mission that is not ours.
owner_lock_or_die "$(json_raw "$STATE" githubIssue)"
xo_lock_or_die "$MISSION_DIR"

# Record the stage we're bouncing back FROM so we can drop its label cleanly.
PREV_STAGE="$(json_str "$STATE" stage)"

# 1. Append the note — feedback.md grows, it is never overwritten.
{
  printf '## Feedback — %s (from %s)\n\n' "$NOW" "${PREV_STAGE:-unknown}"
  printf '%s\n\n' "$FEEDBACK"
} >>"$MISSION_DIR/feedback.md"

# 1a. Mirror the accumulated history to the issue as ONE living comment (S188).
# Done right after the append, so the comment always reflects the file — created
# on the FIRST send-back, PATCHed in place on every one after. Both send-back
# lanes below (ordinary → Align, logged bug → Plan) share this single call.
if command -v cm_mirror_verify_feedback >/dev/null 2>&1; then
  cm_mirror_verify_feedback >/dev/null 2>&1 || true
fi

# A logged bug (S76): type==bug AND a non-empty parentMission. It was fast-tracked
# straight to Plan and has NO Align stage — its Align re-entry would be an
# INTERACTIVE re-grill that a headless resolve-logs batch cannot clear, and no
# headless stage reads feedback.md. So a logged-bug send-back goes back to PLAN,
# with the correction folded into prd.md (the artifact the cold Plan worker reads).
TYPE="$(json_str "$STATE" type)"
PARENT="$(json_str "$STATE" parentMission)"

if [ "$TYPE" = "bug" ] && [ -n "$PARENT" ]; then
  # Do NOT touch any PR: a logged bug has no PR of its own (its fix rides the
  # PARENT's PR), so close_open_pr is skipped here explicitly.

  # Fold the note into prd.md as a clearly-marked correction the Plan worker reads.
  {
    printf '\n\n## Re-verify correction — %s\n\n' "$NOW"
    printf '%s\n' "$FEEDBACK"
  } >>"$MISSION_DIR/prd.md"

  # Clear the stale downstream artifacts so the re-plan regenerates cleanly
  # against the corrected PRD. Plan overwrites plan.json fresh; Plan Review writes
  # approved-plan.json; Schedule rebuilds waves.json + manifests; Implement
  # rebuilds tickets/. Best-effort. Do NOT delete prd.md (just amended) or
  # feedback.md.
  rm -f  "$MISSION_DIR/plan.json"          2>/dev/null || true
  # S178: plan-under-review.json is a PENDING REQUEST, not an artifact — it says
  # "Plan Review asked for a revision and has not got one". The captain's
  # correction supersedes that request, and plan.json (the plan it snapshots) is
  # deleted on the line above, so leaving it would have the next plan diffed
  # against a graph nobody is asking about any more.
  rm -f  "$MISSION_DIR/plan-under-review.json" 2>/dev/null || true
  rm -f  "$MISSION_DIR/approved-plan.json" 2>/dev/null || true
  rm -f  "$MISSION_DIR/waves.json"         2>/dev/null || true
  rm -rf "$MISSION_DIR/tickets"            2>/dev/null || true
  rm -rf "$MISSION_DIR/manifests"          2>/dev/null || true

  set_stage "plan"
  gh_relabel "lcars:plan" "${PREV_STAGE:+lcars:$PREV_STAGE} lcars:awaiting-human"

  # S207 fix round 1 (D2): the state writer now REFUSES a state.json it will
  # not touch, and returns non-zero. Ask before announcing anything — a verb
  # that prints success over a refused write is the `lcars pause` lie the
  # captain ruled on.
  lcars_state_refusal_die "lcars feedback"
  echo "FEEDBACK: logged bug re-staged to Plan with your correction folded into the PRD"
  echo "  Appended your note to feedback.md and folded it into prd.md."
  echo "  Stage:  plan (was ${PREV_STAGE:-unknown})"
  echo "  Cleared the stale plan/schedule/implement artifacts so Plan re-runs against the corrected PRD."
  echo "  Its fix rides the parent's PR — no PR was touched. \`lcars run $MISSION_ID\` re-plans headlessly."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
fi

# S178: the ordinary send-back KEEPS every artifact on purpose ("The prior PRD
# and artifacts are kept"), and that is right — but plan-under-review.json is a
# PENDING REQUEST, not an artifact. It means "Plan Review asked for a revision
# and has not got one", and the captain's correction supersedes that request:
# the Mission re-plans from a corrected PRD, so the next plan must not be diffed
# against, or told to patch, a plan the captain has just sent back. Normally
# already absent (a send-back comes from Verify, long after the revision landed
# and consumed it); this closes the window where it is not.
rm -f "$MISSION_DIR/plan-under-review.json" 2>/dev/null || true

# 1b. Close any open PR (S75) and clear the recorded PR/review markers, so the
# in-review PR does not linger and a re-entry to Verify opens a fresh one.
close_open_pr

# 2 + 3. Reset to Align and move the label in step. Remove whatever stage label
# the card carried (plus any awaiting-human overlay) and add lcars:align.
set_stage "align"
gh_relabel "lcars:align" "${PREV_STAGE:+lcars:$PREV_STAGE} lcars:awaiting-human"

# S207 fix round 1 (D2): the state writer now REFUSES a state.json it will
# not touch, and returns non-zero. Ask before announcing anything — a verb
# that prints success over a refused write is the `lcars pause` lie the
# captain ruled on.
lcars_state_refusal_die "lcars feedback"
echo "FEEDBACK: sent back to Align"
echo "  Appended your note to feedback.md."
echo "  Stage:  align (was ${PREV_STAGE:-unknown})"
echo "  The prior PRD and artifacts are kept — \`lcars run $MISSION_ID\` re-enters Align with the full history."
[ -n "$PR_NOTE" ] && echo "$PR_NOTE"
[ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
exit 0
