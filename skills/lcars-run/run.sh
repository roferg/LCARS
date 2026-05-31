#!/usr/bin/env bash
#
# lcars run — advance a Mission one Stage. This build implements the Research
# stage only (align → research → stage pointer set to validate).
#
# `lcars run <id>` dispatches on state.json.stage. A mission filed by
# `lcars file` sits at stage "align" (Align already happened conversationally),
# so the next Stage to execute is Research. Research has two halves:
#
#   • Claude (per SKILL.md) reads prd.md, generates 0–20 research questions,
#     and spawns one STATELESS subagent per question. Each agent gets only its
#     question text and returns { question, recommendation, supporting_points }.
#   • This script does the mechanical, testable parts, via two subcommands:
#
#       gate  --mission <id> --questions <file>
#             Branch on the question count BEFORE any agent runs:
#               0          → skip Research, advance the mission (prints GATE: skip)
#               1..20      → dispatch that many agents       (prints GATE: dispatch N)
#               >20        → stop and ask the human          (prints GATE: too-many N, exit 3)
#
#       save  --mission <id> --responses <dir>
#             Persist the agents' response JSON to research/<n>.json, then
#             advance the mission.
#
# "Advance the mission" means: set state.json.stage to "validate" AND move the
# GitHub label from lcars:align to lcars:validate, so the on-disk state and the
# board's label always agree on one answer — the Stage `lcars run` will execute
# next. A freshly filed mission sits at "align" (Align already happened in
# `lcars file`), so `lcars run` treats "align" as the signal to run Research and
# lands the card in the Validate column when it's done.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary (default: gh)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
MAX_QUESTIONS=20
RELABEL_NOTE=""

die() { printf 'lcars run: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as file.sh / status.sh) ----------
json_str() { # file key  → first matching "key": "value"
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
json_raw() { # file key  → first matching bare token (number/null/bool)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- locate the mission ----------------------------------------------------
# Resolves MISSION_DIR / STATE for the given id, mirroring file.sh's .git
# resolution. Dies if the mission or its state.json is absent.
locate_mission() {
  local id="$1" gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSION_DIR="$gitdir/lcars/missions/$id"
  STATE="$MISSION_DIR/state.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$id' under .git/lcars/missions/ — check the id (or run \`lcars file\` first)."
  [ -f "$STATE" ]       || die "mission '$id' has no state.json — its state is corrupt."
}

# Research only runs on an align-stage mission. Anything else is a no-op error
# so we never relabel or overwrite a mission mid-flight.
require_align_stage() {
  local stage; stage="$(json_str "$STATE" stage)"
  [ "$stage" = "align" ] || die "mission is at stage '${stage:-unknown}', not 'align' — Research only runs on a freshly-aligned mission."
}

# --- rewrite state.json's stage field in place (portable sed) --------------
set_stage() {
  local newstage="$1" tmp
  tmp="$(mktemp)"
  sed "s/\(\"stage\"[[:space:]]*:[[:space:]]*\"\)[^\"]*\(\"\)/\1$newstage\2/" "$STATE" >"$tmp" \
    && mv "$tmp" "$STATE"
}

# --- advance: stage pointer → validate, GitHub label align → research ------
advance() {
  set_stage "validate"

  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null)
      RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped relabel (local-only mission)."
      return 0 ;;
  esac

  if command -v "$GH_BIN" >/dev/null 2>&1; then
    if ! "$GH_BIN" issue edit "$issue" \
           --add-label "lcars:validate" \
           --remove-label "lcars:align" >/dev/null 2>&1; then
      RELABEL_NOTE="  ⚠ gh issue edit failed — relabel #$issue by hand (-lcars:align +lcars:validate)."
    fi
  else
    RELABEL_NOTE="  ⚠ gh not found — skipped relabel; do it by hand (#$issue: -lcars:align +lcars:validate)."
  fi
}

# --- subcommand: gate ------------------------------------------------------
cmd_gate() {
  locate_mission "$MISSION_ID"
  require_align_stage

  local n=0
  if [ -n "$QFILE" ] && [ -f "$QFILE" ]; then
    n="$(grep -cve '^[[:space:]]*$' "$QFILE")"
  fi

  if [ "$n" -eq 0 ]; then
    advance
    echo "GATE: skip"
    echo "  No research questions — the PRD is unambiguous. Skipping Research."
    echo "  Stage:  validate"
    [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
    exit 0
  fi

  if [ "$n" -gt "$MAX_QUESTIONS" ]; then
    echo "GATE: too-many $n"
    echo "  Research wants $n questions — over the cap of $MAX_QUESTIONS. That"
    echo "  many open questions usually means the PRD is underspecified."
    echo "  Nothing has changed. Choose how to proceed:"
    echo "    • override         — run all $n research agents anyway"
    echo "    • return-to-align  — re-run \`lcars file\` with this context appended"
    echo "                         so the PRD can be sharpened"
    exit 3
  fi

  echo "GATE: dispatch $n"
  echo "  Dispatching $n stateless research agent(s) — one per question."
  exit 0
}

# --- subcommand: save ------------------------------------------------------
cmd_save() {
  locate_mission "$MISSION_ID"
  require_align_stage

  [ -n "$RESPONSES" ]   || die "no responses dir — pass --responses <dir>."
  [ -d "$RESPONSES" ]   || die "responses dir not found: $RESPONSES"

  local research_dir="$MISSION_DIR/research"
  mkdir -p "$research_dir"

  # Persist each response as research/<n>.json, renumbered 1..N in the input's
  # lexical order. Every response must carry the three required fields — a
  # malformed agent reply stops the save so we never advance on bad data.
  local n=0 f
  shopt -s nullglob
  for f in "$RESPONSES"/*.json; do
    grep -q '"question"'          "$f" || die "response $f is missing \"question\"."
    grep -q '"recommendation"'    "$f" || die "response $f is missing \"recommendation\"."
    grep -q '"supporting_points"' "$f" || die "response $f is missing \"supporting_points\"."
    n=$((n + 1))
    cp "$f" "$research_dir/$n.json"
  done
  shopt -u nullglob

  [ "$n" -gt 0 ] || die "no *.json responses in $RESPONSES — nothing to save."

  advance
  echo "SAVE: $n responses"
  echo "  Saved $n research response(s) to research/."
  echo "  Stage:  validate"
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift

MISSION_ID=""; QFILE=""; RESPONSES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)     MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*)   MISSION_ID="${1#--mission=}"; shift ;;
    --questions)   QFILE="${2:-}"; shift 2 ;;
    --questions=*) QFILE="${1#--questions=}"; shift ;;
    --responses)   RESPONSES="${2:-}"; shift 2 ;;
    --responses=*) RESPONSES="${1#--responses=}"; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$SUB" in
  gate|save) [ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>." ;;
esac

case "$SUB" in
  gate) cmd_gate ;;
  save) cmd_save ;;
  ''|*) die "unknown subcommand '${SUB:-}'. Usage: run.sh gate|save --mission <id> [--questions <f>|--responses <d>]." ;;
esac
