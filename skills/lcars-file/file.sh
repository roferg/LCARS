#!/usr/bin/env bash
#
# lcars file — persist a new Mission and open its GitHub issue.
#
# This is the mechanical half of `lcars file`. The conversational half
# (Capture + Align) is driven by Claude per SKILL.md and produces a PRD on
# disk; this script takes that PRD and:
#   1. mints a mission ID            lcars-YYYYMMDD-NNN (NNN per-day sequence)
#   2. creates .git/lcars/missions/<id>/ with prd.md + state.json
#   3. opens a GitHub issue labelled lcars:align + lcars:<type> + lcars:mission
#   4. prints a confirmation summary
#
# Type and title are read from the PRD itself (the `**Type:**` and
# `# Mission:` lines), so Claude only has to hand over a well-formed PRD.
#
# Dependencies are taken via env so they can be stubbed in tests:
#   LCARS_GH_BIN   the gh binary       (default: gh)
#   LCARS_GIT_BIN  the git binary      (default: git)
#   LCARS_DATE     YYYYMMDD for the ID (default: today, UTC)
#   LCARS_NOW      ISO created stamp   (default: now, UTC)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
GIT_BIN="${LCARS_GIT_BIN:-git}"
DATE="${LCARS_DATE:-$(date -u +%Y%m%d)}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
# The lcars-run driver that owns the end-of-Align estimator (session 59). Default
# matches how SKILL.md invokes the other run.sh subcommands; overridable so tests
# can point it at a stub estimator driver. The estimator is OPTIONAL — see below.
RUN_BIN="${LCARS_RUN_BIN:-$HOME/.claude/skills/lcars-run/run.sh}"

die() { printf 'lcars file: %s\n' "$1" >&2; exit 1; }

# --- args -----------------------------------------------------------------
# --prd is REQUIRED. --adr is OPTIONAL: Align passes it ONLY for a complex
# Mission (an engineering ADR set); a trivial Mission ships no adr.md at all.
PRD_SRC=""
ADR_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prd)   PRD_SRC="${2:-}"; shift 2 ;;
    --prd=*) PRD_SRC="${1#--prd=}"; shift ;;
    --adr)   ADR_SRC="${2:-}"; shift 2 ;;
    --adr=*) ADR_SRC="${1#--adr=}"; shift ;;
    *)       die "unknown argument: $1" ;;
  esac
done

[ -n "$PRD_SRC" ] || die "no PRD given — pass --prd <path> to a PRD file."
[ -f "$PRD_SRC" ] || die "PRD file not found: $PRD_SRC"
# --adr is optional, but if given it must point at a real file.
if [ -n "$ADR_SRC" ]; then
  [ -f "$ADR_SRC" ] || die "ADR file not found: $ADR_SRC"
fi

# --- locate the repo + state dir ------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac

LCARS_DIR="$GIT_DIR/lcars"
MISSIONS_DIR="$LCARS_DIR/missions"
CONFIG="$LCARS_DIR/config.json"
mkdir -p "$MISSIONS_DIR"

# --- validate the PRD has every required section --------------------------
# Each entry is "human label|grep pattern".
require_section() {
  grep -q "$2" "$PRD_SRC" || die "PRD is missing the '$1' section — Align must produce it before filing."
}
require_section "Mission title"      '^# Mission:'
require_section "Type"               '\*\*Type:\*\*'
require_section "Goal"               '\*\*Goal:\*\*'
require_section "Acceptance Criteria" '\*\*Acceptance Criteria:\*\*'
require_section "Out of Scope"       '\*\*Out of Scope:\*\*'
require_section "Constraints"        '\*\*Constraints:\*\*'

# --- when an ADR set is provided, shape-check it ---------------------------
# SHAPE validation only — NOT depth policy. Whether a Mission is complex enough
# to warrant ADRs is Align's judgment (the prompt), not the script's. But IF
# Align hands us an adr.md, each ADR's required sections must be present:
# Context / Decision / Alternatives considered / Consequences. A malformed ADR
# stops the filing the same way a malformed PRD does (nothing is written).
if [ -n "$ADR_SRC" ]; then
  require_adr_section() {
    grep -q "$2" "$ADR_SRC" || die "ADR is missing the '$1' section — each ADR needs Context / Decision / Alternatives considered / Consequences."
  }
  require_adr_section "Context"      '\*\*Context:\*\*'
  require_adr_section "Decision"     '\*\*Decision:\*\*'
  require_adr_section "Alternatives" '\*\*Alternatives considered:\*\*'
  require_adr_section "Consequences" '\*\*Consequences:\*\*'
fi

# --- derive title + type from the PRD -------------------------------------
TITLE="$(sed -n 's/^# Mission:[[:space:]]*//p' "$PRD_SRC" | head -1)"
[ -n "$TITLE" ] || die "could not read the Mission title from the PRD."

TYPE="$(sed -n 's/.*\*\*Type:\*\*[[:space:]]*//p' "$PRD_SRC" | head -1 \
        | tr 'A-Z' 'a-z' | tr -cd 'a-z')"
case "$TYPE" in
  feature|bug) : ;;
  *) die "PRD Type must be 'feature' or 'bug' (got: '${TYPE:-empty}')." ;;
esac

# --- mint the mission ID (per-day sequence) -------------------------------
max=0
shopt -s nullglob
for d in "$MISSIONS_DIR"/lcars-"$DATE"-*; do
  n="$((10#${d##*-}))"
  [ "$n" -gt "$max" ] && max="$n"
done
shopt -u nullglob
SEQ="$((max + 1))"
ID="$(printf 'lcars-%s-%03d' "$DATE" "$SEQ")"

MISSION_DIR="$MISSIONS_DIR/$ID"
mkdir -p "$MISSION_DIR"

# --- give the Mission its own branch --------------------------------------
# The vision's rule: each Mission gets its own branch. Create it now, off the
# branch we're currently on (the base the PR will eventually target), and record
# both in state.json so Implement can commit to it and `lcars approve` can push
# it + open the PR with --head/--base. We do NOT switch to it here — the working
# tree of the captain's repo stays exactly as it was; Implement checks it out
# when it's time to commit. Branch creation is best-effort: a repo with no
# commits (nothing to branch from) just gets a warning, and Implement creates
# the branch on first commit.
BRANCH="lcars/$ID"
BASE="$("$GIT_BIN" rev-parse --abbrev-ref HEAD 2>/dev/null)"
case "$BASE" in ''|HEAD) BASE="main" ;; esac
BRANCH_NOTE=""
if "$GIT_BIN" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
  if "$GIT_BIN" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    BRANCH_NOTE="  ⚠ branch $BRANCH already exists — reusing it."
  elif ! "$GIT_BIN" branch "$BRANCH" >/dev/null 2>&1; then
    BRANCH_NOTE="  ⚠ could not create branch $BRANCH — create it before Implement."
  fi
else
  BRANCH_NOTE="  ⚠ repo has no commits yet — branch $BRANCH not created; Implement will create it on first commit."
fi

# --- write prd.md ---------------------------------------------------------
cat "$PRD_SRC" >"$MISSION_DIR/prd.md"

# --- write adr.md (complex Missions only) ---------------------------------
# Mirrors how --prd is persisted: copy the (already shape-checked) ADR set into
# the mission dir as the durable adr.md every downstream worker (EXCEPT research
# agents) may read. A trivial Mission passes no --adr, so no adr.md is written.
if [ -n "$ADR_SRC" ]; then
  cat "$ADR_SRC" >"$MISSION_DIR/adr.md"
fi

# --- resolve the model (config.json wins, else env, else default) ---------
MODEL=""
if [ -f "$CONFIG" ]; then
  MODEL="$(sed -n 's/.*"model"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
fi
[ -n "$MODEL" ] || MODEL="${LCARS_MODEL:-claude-sonnet}"

# --- open the GitHub issue ------------------------------------------------
ISSUE=""
GH_NOTE=""
if command -v "$GH_BIN" >/dev/null 2>&1; then
  # Build the issue body. PRD always comes first. For a complex Mission an
  # adr.md exists; append the ADR set after a `\n\n---\n\n` separator so the
  # board reader sees the architectural decisions too. The on-disk prd.md and
  # adr.md stay separate artifacts — only the issue BODY combines them.
  BODY_FILE="$MISSION_DIR/prd.md"
  BODY_TMP=""
  if [ -f "$MISSION_DIR/adr.md" ]; then
    BODY_TMP="$(mktemp "$MISSION_DIR/.issue-body.XXXXXX")"
    {
      cat "$MISSION_DIR/prd.md"
      printf '\n\n---\n\n'
      cat "$MISSION_DIR/adr.md"
    } >"$BODY_TMP"
    BODY_FILE="$BODY_TMP"
  fi
  [ -n "$BODY_TMP" ] && trap 'rm -f "$BODY_TMP"' EXIT
  url="$("$GH_BIN" issue create \
          --title "$TITLE" \
          --body-file "$BODY_FILE" \
          --label "lcars:align,lcars:$TYPE,lcars:mission" 2>/dev/null)"
  if [ -n "$BODY_TMP" ]; then rm -f "$BODY_TMP"; trap - EXIT; fi
  # gh prints the new issue's URL; the trailing path segment is its number.
  num="${url##*/}"
  case "$num" in
    ''|*[!0-9]*) GH_NOTE="  ⚠ gh issue create failed — mission filed locally; re-run after fixing gh." ;;
    *) ISSUE="$num" ;;
  esac
else
  GH_NOTE="  ⚠ gh CLI not found — mission filed locally without a GitHub issue."
fi

# --- write state.json -----------------------------------------------------
# Escape backslashes and quotes in the title for JSON.
title_json="${TITLE//\\/\\\\}"
title_json="${title_json//\"/\\\"}"
issue_json="${ISSUE:-null}"

cat >"$MISSION_DIR/state.json" <<EOF
{
  "id": "$ID",
  "type": "$TYPE",
  "title": "$title_json",
  "stage": "align",
  "created": "$NOW",
  "model": "$MODEL",
  "githubIssue": $issue_json,
  "branch": "$BRANCH",
  "base": "$BASE"
}
EOF

# --- run the end-of-Align estimator (session 59) --------------------------
# Now that prd.md / adr.md and state.json exist, ask the lcars-run driver to
# produce estimate.json (two criticality scores + a per-stage model map that the
# downstream stages' resolver consumes). The estimator is STRICTLY OPTIONAL and
# must NEVER block filing: it mirrors the gh-missing degradation above. If the
# run.sh driver is missing, or it produces no estimate.json (worker unavailable,
# malformed output), we print a note and STILL file the mission — every stage
# then falls back to its legacy model exactly as before this feature existed.
EST_NOTE=""
if [ -f "$RUN_BIN" ]; then
  if bash "$RUN_BIN" estimate --mission "$ID" >/dev/null 2>&1 \
       && [ -f "$MISSION_DIR/estimate.json" ]; then
    : # estimate produced — nothing to note.
  else
    EST_NOTE="  ⚠ estimator unavailable — mission filed with default per-stage models."
  fi
else
  EST_NOTE="  ⚠ estimator driver not found ($RUN_BIN) — mission filed with default per-stage models."
fi

# --- confirmation summary -------------------------------------------------
if [ -n "$ISSUE" ]; then
  issue_line="#$ISSUE"
else
  issue_line="(none — file locally only)"
fi

[ -n "$GH_NOTE" ] && echo "$GH_NOTE"
[ -n "$EST_NOTE" ] && echo "$EST_NOTE"
[ -n "$BRANCH_NOTE" ] && echo "$BRANCH_NOTE"
echo "  Mission filed: $ID"
echo "  GitHub issue:  $issue_line"
echo "  Branch:        $BRANCH (off $BASE)"
echo "  Stage:         align"
echo "  Next:          run \`lcars run $ID\` to continue"
