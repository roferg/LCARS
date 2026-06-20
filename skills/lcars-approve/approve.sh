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
MISSION_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)   MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*) MISSION_ID="${1#--mission=}"; shift ;;
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

# A merge selector: prefer the recorded PR number, else the branch.
MERGE_ARGS=()
case "$PR_NUM" in
  ''|null) MERGE_ARGS=(--head "$BRANCH") ;;
  *)       MERGE_ARGS=(--number "$PR_NUM") ;;
esac

command -v "$GH_BIN" >/dev/null 2>&1 \
  || die "gh not found — cannot merge PR $PR_URL. Mission stays at verify (merge it by hand)."

# --- merge — only a SUCCESSFUL merge flips the Mission to Done ----------------
if ! host pr-merge "${MERGE_ARGS[@]}"; then
  die "gh pr merge failed for $PR_URL — resolve it (conflicts/checks/auth) and re-run \`lcars approve $MISSION_ID\`, or merge on GitHub. Mission stays at verify."
fi

# Merge landed — NOW flip the Mission to Done.
gh_relabel "lcars:done" "lcars:verify lcars:awaiting-human"
set_stage "done"
state_set_str review "merged"

echo "APPROVE: merged — $(pr_title)"
echo "  Merged PR: $PR_URL"
echo "  Branch:    $BRANCH → $BASE"
echo "  Stage:     done"
[ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
exit 0
