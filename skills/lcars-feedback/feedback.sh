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
HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SELF_DIR/../lcars-run/host-adapter.sh}"
host() { LCARS_GH_BIN="$GH_BIN" bash "$HOST_ADAPTER" "$@"; }

die() { printf 'lcars feedback: %s\n' "$1" >&2; exit 1; }

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

set_stage() {
  local newstage="$1" tmp; tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# drop a field's line if present (no-op otherwise) — clears the recorded PR so a
# re-entry to Verify opens a fresh PR.
state_del() { local tmp; tmp="$(mktemp)"; grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"; }

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
  state_del prUrl
  state_del prNumber
  state_del review
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

# Record the stage we're bouncing back FROM so we can drop its label cleanly.
PREV_STAGE="$(json_str "$STATE" stage)"

# 1. Append the note — feedback.md grows, it is never overwritten.
{
  printf '## Feedback — %s (from %s)\n\n' "$NOW" "${PREV_STAGE:-unknown}"
  printf '%s\n\n' "$FEEDBACK"
} >>"$MISSION_DIR/feedback.md"

# 1b. Close any open PR (S75) and clear the recorded PR/review markers, so the
# in-review PR does not linger and a re-entry to Verify opens a fresh one.
close_open_pr

# 2 + 3. Reset to Align and move the label in step. Remove whatever stage label
# the card carried (plus any awaiting-human overlay) and add lcars:align.
set_stage "align"
gh_relabel "lcars:align" "${PREV_STAGE:+lcars:$PREV_STAGE} lcars:awaiting-human"

echo "FEEDBACK: sent back to Align"
echo "  Appended your note to feedback.md."
echo "  Stage:  align (was ${PREV_STAGE:-unknown})"
echo "  The prior PRD and artifacts are kept — \`lcars run $MISSION_ID\` re-enters Align with the full history."
[ -n "$PR_NOTE" ] && echo "$PR_NOTE"
[ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
exit 0
