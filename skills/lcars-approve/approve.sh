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

# The host-integration adapter — the ONE place that speaks to a forge. It lives
# in the sibling lcars-run skill dir; after ./install.sh both skills are
# symlinked siblings under ~/.claude/skills/, so a path off this script's own
# location → ../lcars-run/host-adapter.sh resolves it. $LCARS_HOST_ADAPTER
# overrides that path (tests stub the whole adapter regardless of layout). The
# adapter picks its host via $LCARS_HOST_BIN (default "github"); the github host
# shells out to ${LCARS_GH_BIN:-gh}.
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

# --- gh relabel: best-effort, never blocks the local stage change ----------
gh_relabel() { # "add labels…"  "remove labels…"
  local add="$1" rem="$2" l
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."; return 0 ;;
  esac
  local hand="+${add// /,} -${rem// /,}"
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    # The adapter performs the relabel (best-effort, never blocks); keep the
    # local note only if its forge call signals failure.
    host issue-relabel "$issue" --add "$add" --remove "$rem" \
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

# --- user-facing summary: PRD Goal + Acceptance Criteria --------------------
# Reads prd.md and renders what changed from the user's point of view: the one
# `**Goal:**` sentence plus the `- ` bullets under `**Acceptance Criteria:**`
# (up to the next `**…:**` header). jq-free, line-oriented. Emits nothing when
# prd.md is absent or yields neither a goal nor criteria, so callers can detect
# "no summary" and fall back to the thin body.
user_summary() {
  local prd="$MISSION_DIR/prd.md"
  [ -f "$prd" ] || return 0
  local goal crit
  goal="$(sed -n 's/^\*\*Goal:\*\*[[:space:]]*//p' "$prd" | head -1)"
  crit="$(awk '
    /^\*\*Acceptance Criteria:\*\*/ { grab=1; next }
    grab && /^\*\*[^*]*:\*\*/       { grab=0 }
    grab && /^-[[:space:]]/         { print }
  ' "$prd")"
  [ -n "$goal" ] || [ -n "$crit" ] || return 0
  printf '## User-facing summary\n\n'
  [ -n "$goal" ] && printf '%s\n' "$goal"
  [ -n "$crit" ] && printf '\nAcceptance criteria:\n\n%s\n' "$crit"
}

# --- technical summary: ADRs (preferred) or commit subjects (fallback) ------
# Primary source is adr.md — each `## ADR-NNN: <title>` paired with its
# `**Decision:**` line. With no adr.md it degrades to the mission branch's
# commit subjects (`$BASE..$BRANCH`, via $GIT_BIN so tests can stub it). Emits
# nothing when neither source yields content. jq-free, line-oriented.
tech_summary() {
  local adr="$MISSION_DIR/adr.md" body=""
  if [ -f "$adr" ]; then
    body="$(awk '
      /^## ADR-/ { sub(/^##[[:space:]]*/,""); titles[++n]=$0; next }
      /^\*\*Decision:\*\*/ {
        d=$0; sub(/^\*\*Decision:\*\*[[:space:]]*/,"",d)
        if (n>0 && decisions[n]=="") decisions[n]=d
        next
      }
      END {
        for (i=1;i<=n;i++)
          if (decisions[i] != "") printf "- **%s** — %s\n", titles[i], decisions[i]
          else                    printf "- **%s**\n", titles[i]
      }
    ' "$adr")"
  fi
  if [ -z "$body" ] && [ -n "${BRANCH:-}" ]; then
    local range="$BRANCH"
    [ -n "${BASE:-}" ] && range="$BASE..$BRANCH"
    body="$("$GIT_BIN" log --no-merges --format='- %s' "$range" 2>/dev/null)"
  fi
  [ -n "$body" ] || return 0
  printf '## Technical summary\n\n'
  printf '%s\n' "$body"
}

# --- PR body: user + technical summaries, then a per-wave ticket manifest ----
# Leads with what changed for the user (PRD-derived) and the notable
# implementation approach (ADR-/commit-derived), then keeps the existing
# per-wave ticket list as the detail tail. Reads waves.json (wave/id, in order)
# and looks each ticket's title up in approved-plan.json. Line-oriented and
# jq-free, like the rest of LCARS. With no PRD to summarise it falls back to the
# thin one-line summary the body used before BUG-014.
pr_body() {
  local waves="$MISSION_DIR/waves.json" plan="$MISSION_DIR/approved-plan.json"
  local us ts
  us="$(user_summary)"
  ts="$(tech_summary)"

  if [ -n "$us" ]; then
    printf '%s\n' "$us"
  else
    printf '## Summary\n\n'
    printf 'Mission **%s** — implemented across its scheduled waves.\n' "$(pr_title)"
  fi
  [ -n "$ts" ] && printf '\n%s' "$ts"

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

# --- the sub-issue numbers Schedule opened, one per line --------------------
# Reads waves.json and echoes every non-null ticket "issue" number. These are the
# per-ticket sub-issues; Rule A closes each on GREEN during Implement, but that
# is best-effort, so approve re-includes them in the PR's Closes directives to
# RECONCILE any Rule A missed (closing an already-closed issue via Closes is a
# harmless no-op). Line-oriented and jq-free, like pr_body.
sub_issues() {
  local waves="$MISSION_DIR/waves.json"
  [ -f "$waves" ] || return 0
  awk '
    /"issue"[[:space:]]*:/ {
      v=$0; sub(/.*"issue"[[:space:]]*:[[:space:]]*/,"",v); gsub(/[ ,}]/,"",v)
      if (v != "" && v != "null") print v
    }
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

# RULE B (issue-close lifecycle): the PR — not approve — closes the issues, on
# MERGE. The adapter renders host-portable `Closes #<n>` directives into the PR
# body (GitHub & GitLab both honour them), so the merge auto-closes the PARENT
# Mission issue plus any still-open per-ticket sub-issue (Rule A's reconciliation
# — see sub_issues). approve itself issues NO close call against the parent: the
# stage LABEL flipping to lcars:done below is the board COLUMN; the issue's
# open/closed LIFECYCLE is decoupled from it and stays OPEN until the human
# merges. A local-only mission (no parent issue) simply passes no parent --closes.
CLOSES=()
PARENT="$(json_raw "$STATE" githubIssue)"
case "$PARENT" in ''|null) : ;; *) CLOSES+=(--closes "$PARENT") ;; esac
while IFS= read -r sub; do
  [ -n "$sub" ] && CLOSES+=(--closes "$sub")
done < <(sub_issues)

PR_URL="$(host pr-create --head "$BRANCH" --base "$BASE" --title "$TITLE" --body "$BODY" "${CLOSES[@]}")"
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
