#!/usr/bin/env bash
#
# lcars approve — ship a verified Mission: open its PR and mark it Done.
#
# This is the captain's go-ahead after reviewing a Mission parked at "verify".
# It is purely mechanical — no LLM — and does four things:
#   1. opens the PR with `gh pr create`, titled from the PRD's `# Mission:` line
#      and bodied with a summary of the waves and tickets the Mission shipped,
#   2. clears the stage labels and marks the Mission's issue lcars:done,
#   3. moves state.json's stage to "done" (kept in step with the label),
#   4. prints the new PR URL.
#
# The on-disk stage and the GitHub label always agree — both land on "done", so
# the board shows the card in the Done column. Approve only runs on a Mission at
# "verify"; every other stage is refused so a half-built Mission can't be shipped.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary  (default: gh)
#   LCARS_GIT_BIN  the git binary (default: git)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
RELABEL_NOTE=""

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

# --- PR title: the PRD's `# Mission:` line, falling back to state.json title --
pr_title() {
  local t=""
  [ -f "$MISSION_DIR/prd.md" ] \
    && t="$(sed -n 's/^# Mission:[[:space:]]*//p' "$MISSION_DIR/prd.md" | head -1)"
  [ -n "$t" ] || t="$(json_str "$STATE" title)"
  printf '%s' "${t:-$MISSION_ID}"
}

# --- PR body: a per-wave summary of the tickets the Mission shipped ----------
# Reads waves.json (wave/id, in order) and looks each ticket's title up in
# approved-plan.json. Line-oriented and jq-free, like the rest of LCARS.
pr_body() {
  local waves="$MISSION_DIR/waves.json" plan="$MISSION_DIR/approved-plan.json"
  printf '## Summary\n\n'
  printf 'Mission **%s** — implemented across its scheduled waves.\n' "$(pr_title)"
  [ -f "$waves" ] || return 0

  awk -v plan="$plan" '
    BEGIN {
      # Map ticket id -> title from approved-plan.json (canonical one-field-per-line).
      while ((getline line < plan) > 0) {
        n = split(line, a, "\"")
        if (n >= 4 && a[2] == "id")    cid = a[4]
        if (n >= 4 && a[2] == "title") title[cid] = a[4]
      }
      close(plan)
    }
    /"wave"[[:space:]]*:/ { w=$0; gsub(/[^0-9]/,"",w); printf "\n### Wave %s\n", w; next }
    /"id"[[:space:]]*:/   { n=split($0,a,"\""); if (n>=4) { id=a[4]; printf "- `%s` — %s\n", id, (id in title ? title[id] : "") } }
  ' "$waves"
}

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

# --- the branch the Mission was built on -----------------------------------
# `lcars file` records the Mission's branch (and the base it forked from);
# Implement committed every green ticket to it. Without a branch there is
# nothing to open a PR from, so refuse — and, crucially, stay at verify.
BRANCH="$(json_str "$STATE" branch)"
BASE="$(json_str "$STATE" base)"; BASE="${BASE:-main}"
[ -n "$BRANCH" ] || die "mission has no branch on file — re-file it so it gets a branch. Mission stays at verify."

# --- make the PR deterministic: checkout, require commits, push -------------
# Everything below is a precondition for a real PR. Any failure BLOCKS: it dies
# (exit non-zero) without relabelling or advancing, so a Mission never lands in
# Done with no PR behind it — a card in the Done column with no pull request is
# a false signal.

# Ensure the mission branch is the one checked out.
cur="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ "$cur" != "$BRANCH" ]; then
  "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BRANCH" \
    || die "mission branch '$BRANCH' does not exist — Implement never committed to it. Mission stays at verify."
  "$GIT_BIN" checkout "$BRANCH" >/dev/null 2>&1 \
    || die "could not checkout '$BRANCH'. Mission stays at verify."
fi

# Require commits ahead of the base — no content, no PR.
ahead="$("$GIT_BIN" rev-list --count "$BASE..$BRANCH" 2>/dev/null)"
case "$ahead" in
  ''|0) die "no commits on '$BRANCH' ahead of '$BASE' — nothing to open a PR for. Mission stays at verify." ;;
esac

# Push the branch so the PR has a head to point at.
command -v "$GIT_BIN" >/dev/null 2>&1 \
  || die "git not found — cannot push '$BRANCH'. Mission stays at verify."
"$GIT_BIN" push -u origin "$BRANCH" >/dev/null 2>&1 \
  || die "could not push '$BRANCH' to origin — push it and re-run \`lcars approve\`. Mission stays at verify."

# --- open the PR from the mission branch into the base ----------------------
TITLE="$(pr_title)"
BODY="$(pr_body)"
command -v "$GH_BIN" >/dev/null 2>&1 \
  || die "gh not found — cannot open the PR for '$BRANCH'. Mission stays at verify."
PR_URL="$("$GH_BIN" pr create --title "$TITLE" --body "$BODY" --head "$BRANCH" --base "$BASE" 2>/dev/null | tail -1)"
case "$PR_URL" in
  http*|*/pull/*) : ;;
  *) die "gh pr create did not return a PR URL for '$BRANCH' — open the PR by hand, then re-run. Mission stays at verify." ;;
esac

# --- PR captured — only NOW flip the Mission to Done ------------------------
gh_relabel "lcars:done" "lcars:verify lcars:awaiting-human"
set_stage "done"

echo "APPROVE: shipped — $TITLE"
echo "  Opened PR: $PR_URL"
echo "  Branch:    $BRANCH → $BASE"
echo "  Stage:     done"
[ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
exit 0
