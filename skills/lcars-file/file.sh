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
# Captain model override (session 62). A natural-language override the Align
# session normalized to a structured "<scope>:<tier>" string. scope ∈
# {all,reasoning,implementation}; tier ∈ {sonnet,opus}. Empty = no override.
MODEL_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prd)   PRD_SRC="${2:-}"; shift 2 ;;
    --prd=*) PRD_SRC="${1#--prd=}"; shift ;;
    --adr)   ADR_SRC="${2:-}"; shift 2 ;;
    --adr=*) ADR_SRC="${1#--adr=}"; shift ;;
    --model-override)   MODEL_OVERRIDE="${2:-}"; shift 2 ;;
    --model-override=*) MODEL_OVERRIDE="${1#--model-override=}"; shift ;;
    *)       die "unknown argument: $1" ;;
  esac
done

[ -n "$PRD_SRC" ] || die "no PRD given — pass --prd <path> to a PRD file."
[ -f "$PRD_SRC" ] || die "PRD file not found: $PRD_SRC"

# --- validate the model override (session 62) ------------------------------
# Format is "<scope>:<tier>" with scope ∈ {all,reasoning,implementation} and
# tier ∈ {sonnet,opus}. A malformed value stops filing BEFORE anything is
# written (nothing partial), the same way a malformed PRD does.
OV_SCOPE=""
OV_TIER=""
if [ -n "$MODEL_OVERRIDE" ]; then
  OV_SCOPE="${MODEL_OVERRIDE%%:*}"
  OV_TIER="${MODEL_OVERRIDE#*:}"
  case "$MODEL_OVERRIDE" in
    *:*) : ;;
    *) die "malformed --model-override '$MODEL_OVERRIDE' — expected <scope>:<tier> (e.g. all:opus)." ;;
  esac
  case "$OV_SCOPE" in
    all|reasoning|implementation) : ;;
    *) die "invalid --model-override scope '$OV_SCOPE' — must be one of: all, reasoning, implementation." ;;
  esac
  case "$OV_TIER" in
    sonnet|opus) : ;;
    *) die "invalid --model-override tier '$OV_TIER' — must be one of: sonnet, opus." ;;
  esac
fi
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

# --- write state.json (session 61: BEFORE the estimator + issue) -----------
# The estimator (run.sh `estimate`) resolves the mission via locate_mission, which
# REQUIRES state.json to exist. To render the estimate INTO the issue body we must
# run the estimator before the issue is created — so state.json has to be written
# first too. We write it now with githubIssue=null, then patch in the real issue
# number after gh creates the issue (state_set_issue, below). Every other field is
# final here. `write_state <issue-or-null>` emits the file.
title_json="${TITLE//\\/\\\\}"
title_json="${title_json//\"/\\\"}"
# The captain model override object (session 62), emitted only when set. The
# downstream S58 resolver reads modelOverride.scope / modelOverride.tier and pins
# the in-scope stages to that tier (above the estimate, below the env pin).
OVERRIDE_LINE=""
if [ -n "$OV_SCOPE" ]; then
  OVERRIDE_LINE="  \"modelOverride\": { \"scope\": \"$OV_SCOPE\", \"tier\": \"$OV_TIER\" },"
fi
# The chosen engine (S67). When the captain picks an engine in the File modal the
# daemon threads it to file.sh as $LCARS_WORKER_BIN. Persist it as state.json's
# `workerBin` so the board can show it and `lcars run` can be fed it on Start —
# the engine survives file→persist→start→run. Empty/unset ⇒ no field (no
# regression / host-detect stays in charge). JSON-escape the value so an odd
# engine string can never break the JSON.
WORKER_BIN_LINE=""
if [ -n "${LCARS_WORKER_BIN:-}" ]; then
  wb_json="${LCARS_WORKER_BIN//\\/\\\\}"
  wb_json="${wb_json//\"/\\\"}"
  WORKER_BIN_LINE="  \"workerBin\": \"$wb_json\","
fi
write_state() { # issue-json (a number or the literal `null`)
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$ID"
    printf '  "type": "%s",\n' "$TYPE"
    printf '  "title": "%s",\n' "$title_json"
    printf '  "stage": "align",\n'
    printf '  "created": "%s",\n' "$NOW"
    printf '  "model": "%s",\n' "$MODEL"
    [ -n "$OVERRIDE_LINE" ] && printf '%s\n' "$OVERRIDE_LINE"
    [ -n "$WORKER_BIN_LINE" ] && printf '%s\n' "$WORKER_BIN_LINE"
    printf '  "githubIssue": %s,\n' "${1:-null}"
    printf '  "branch": "%s",\n' "$BRANCH"
    printf '  "base": "%s"\n' "$BASE"
    printf '}\n'
  } >"$MISSION_DIR/state.json"
}
write_state null

# --- run the end-of-Align estimator (session 59) --------------------------
# REORDERED in session 61 to run BEFORE the issue is created, so estimate.json
# exists when the issue body is composed and the estimate can be rendered into
# BOTH captain surfaces (the issue body + the CLI readout). cmd_estimate resolves
# the mission via locate_mission (needs state.json — written just above) and reads
# prd.md (already written). The estimator is STRICTLY OPTIONAL and must NEVER block
# filing: it mirrors the gh-missing degradation below. If run.sh is missing, or it
# produces no estimate.json (worker unavailable, malformed output), we print a note
# and STILL file the mission — every stage then falls back to its legacy model
# exactly as before this feature existed, and no "## Estimate" section is rendered
# (an absent estimate.json is treated exactly like an absent adr.md).
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

# --- render the estimate's "## Estimate" section for the issue body (S61) --
# Ask the lcars-run driver to format estimate.json into the issue-surface markdown
# block, in the ACTIVE CLI's native cost unit. render-estimate prints NOTHING and
# exits non-zero when estimate.json is absent, so EST_ISSUE stays empty and the
# body is prd[+adr] only — same degradation pattern as an absent adr.md.
EST_ISSUE=""
if [ -f "$RUN_BIN" ] && [ -f "$MISSION_DIR/estimate.json" ]; then
  EST_ISSUE="$(bash "$RUN_BIN" render-estimate --mission "$ID" --surface issue 2>/dev/null)"
fi

# --- open the GitHub issue ------------------------------------------------
ISSUE=""
GH_NOTE=""
if command -v "$GH_BIN" >/dev/null 2>&1; then
  # Build the issue body. PRD always comes first. For a complex Mission an
  # adr.md exists; append the ADR set after a `\n\n---\n\n` separator so the
  # board reader sees the architectural decisions too. When an estimate exists,
  # append its "## Estimate" section last, after another `\n\n---\n\n` rule. The
  # on-disk prd.md and adr.md stay separate artifacts — only the issue BODY
  # combines them. Order is always prd → adr → Estimate.
  BODY_FILE="$MISSION_DIR/prd.md"
  BODY_TMP=""
  if [ -f "$MISSION_DIR/adr.md" ] || [ -n "$EST_ISSUE" ]; then
    BODY_TMP="$(mktemp "$MISSION_DIR/.issue-body.XXXXXX")"
    {
      cat "$MISSION_DIR/prd.md"
      if [ -f "$MISSION_DIR/adr.md" ]; then
        printf '\n\n---\n\n'
        cat "$MISSION_DIR/adr.md"
      fi
      if [ -n "$EST_ISSUE" ]; then
        printf '\n\n---\n\n'
        printf '%s\n' "$EST_ISSUE"
      fi
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

# --- record the issue number in state.json --------------------------------
# state.json was written with githubIssue=null before the estimator (so
# locate_mission could resolve the mission). Now that gh has (maybe) created the
# issue, rewrite it with the real number — or leave null when gh was missing/failed.
write_state "${ISSUE:-null}"

# --- render the estimate's compact summary for the CLI readout (S61) -------
# Same render-estimate driver, the cli surface this time: a compact, two-space-
# indented block (Estimate summary + model mix + one-line rationale) in the active
# CLI's native cost unit. Absent estimate.json ⇒ empty (no readout block), exactly
# the degradation parity the EST_NOTE already covers.
EST_CLI=""
if [ -f "$RUN_BIN" ] && [ -f "$MISSION_DIR/estimate.json" ]; then
  EST_CLI="$(bash "$RUN_BIN" render-estimate --mission "$ID" --surface cli 2>/dev/null)"
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
# The estimate readout (S61): the compact Estimate summary + model mix + rationale,
# in the active CLI's native cost unit. Empty when no estimate.json was produced.
[ -n "$EST_CLI" ] && printf '%s\n' "$EST_CLI"
echo "  Next:          run \`lcars run $ID\` to continue"
