#!/usr/bin/env bash
#
# lcars pause / resume — user-initiated pause/resume (ADR-005, PRD §5.10).
#
# A real `lcars pause <id>` halts a running Mission at a SAFE boundary: it sets a
# `paused` flag in state.json and applies the existing `lcars:paused` label. The
# driver (run.sh) honours the flag at boundaries ONLY — between Stages (top of
# cmd_drive's loop) and between waves/tickets in Implement (top of cmd_implement's
# loop) — and NEVER hard-kills a worker mid-step. So a paused Mission simply stops
# advancing at the next clean boundary and stays put until resumed.
#
#   pause  <id>   set paused=true in state.json, apply lcars:paused. Idempotent —
#                 a double-pause re-applies the flag/label at most once-effectively.
#
#   resume <id>   clear the paused flag, remove lcars:paused, and re-enter the
#                 driver from the recorded stage. Idempotent — resuming a Mission
#                 that is not paused is a clean no-op that still drives.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN     the gh binary                 (default: gh)
#   LCARS_RUN_SCRIPT run.sh, for resume's re-entry  (default: ../lcars-run/run.sh)
#   LCARS_NOW        unix stamp for the event       (default: now)
#
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
GH_BIN="${LCARS_GH_BIN:-gh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILL_DIR/../lcars-run/run.sh}"
RELABEL_NOTE=""

die() { printf 'lcars pause: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as run.sh / respond.sh) ----------
json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# --- locate a single mission (mirrors run.sh's --git-common-dir resolution) --
locate_mission() { # id
  local gitdir
  gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSION_DIR="$gitdir/lcars/missions/$1"
  STATE="$MISSION_DIR/state.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$1' under .git/lcars/missions/ — check the id."
  [ -f "$STATE" ]       || die "mission '$1' has no state.json — its state is corrupt."
}

# --- state.json field editing (one-field-per-line; same as run.sh) ----------
state_del() { # key — drop the field's line if present
  local tmp; tmp="$(mktemp)"
  grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}
state_set_raw() { # key token — add or replace a bare field (true/false/number)
  state_del "$1"
  local tmp; tmp="$(mktemp)"
  K="$1" V="$2" awk 'NR==1{print; printf "  \"%s\": %s,\n", ENVIRON["K"], ENVIRON["V"]; next} {print}' \
    "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- emit an append-only event (same line shape + atomicity as run.sh) ------
# NEW event type only (append-only); never touches the existing schema.
emit_event() { # type stage detail
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ts type stage detail mid
  ts="${LCARS_NOW:-$(date +%s)}"
  json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
  type="$(json_escape "${1:-}")"; stage="$(json_escape "${2:-}")"
  detail="$(json_escape "${3:-}")"; mid="$(json_escape "${MISSION_ID:-}")"
  printf '{"ts":%s,"mission":"%s","stage":"%s","type":"%s","detail":"%s"}\n' \
    "$ts" "$mid" "$stage" "$type" "$detail" >>"$MISSION_DIR/events.jsonl"
}

# --- gh relabel, best-effort (same tolerant spirit as run.sh's gh_relabel) --
# A missing gh / failed edit never blocks the local flag change — it leaves a
# note so the captain can fix the label by hand.
gh_label() { # "--add-label X" | "--remove-label X"  (verb + label as one string)
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped label change (local-only mission)."; return 0 ;;
  esac
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    "$GH_BIN" issue edit "$issue" $1 >/dev/null 2>&1 \
      || RELABEL_NOTE="  ⚠ gh issue edit failed — apply the label change on #$issue by hand ($1)."
  else
    RELABEL_NOTE="  ⚠ gh not found — apply the label change on #$issue by hand ($1)."
  fi
}

# === subcommand: pause ======================================================
cmd_pause() {
  locate_mission "$MISSION_ID"
  local stage; stage="$(json_str "$STATE" stage)"; stage="${stage:-unknown}"

  # Idempotent: state_set_raw replaces (deletes-then-adds) so a double-pause
  # leaves exactly ONE paused=true field. Only emit the event on the transition.
  local was; was="$(json_raw "$STATE" paused)"
  state_set_raw paused true
  [ "$was" = "true" ] || emit_event paused "$stage" "captain paused the Mission at the $stage boundary"

  # Apply the existing lcars:paused label (adds; removes nothing). gh tolerates
  # a label that is already applied, so a double-pause is safe.
  gh_label "--add-label lcars:paused"

  echo "PAUSE: paused $MISSION_ID"
  echo "  ⏸ Mission will stop at the next safe boundary (between Stages, or between"
  echo "     waves/tickets in Implement) — no worker is killed mid-step."
  echo "  Stage:  $stage"
  echo "  Resume with \`lcars resume $MISSION_ID\`."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# === subcommand: resume =====================================================
cmd_resume() {
  locate_mission "$MISSION_ID"
  local stage; stage="$(json_str "$STATE" stage)"; stage="${stage:-unknown}"

  # Clear the flag (idempotent — state_del is a no-op when absent) and drop the
  # label (gh tolerates removing a label that isn't applied).
  local was; was="$(json_raw "$STATE" paused)"
  state_del paused
  [ "$was" = "true" ] && emit_event resumed "$stage" "captain resumed the Mission at the $stage stage"
  gh_label "--remove-label lcars:paused"

  echo "RESUME: resuming $MISSION_ID"
  echo "  Cleared the paused flag and dropped lcars:paused."
  echo "  Stage:  $stage — re-entering the driver."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"

  # Re-enter the driver from the recorded stage. The driver itself no longer sees
  # paused=true, so it advances normally. (If gh/run is stubbed in a test, this is
  # the delegation under assertion.)
  exec bash "$RUN_SCRIPT" drive --mission "$MISSION_ID"
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift
MISSION_ID="${1:-}"; [ $# -gt 0 ] && shift
[ $# -eq 0 ] || die "unexpected argument: $1"

case "$SUB" in
  pause|resume) [ -n "$MISSION_ID" ] || die "no mission id — usage: pause.sh $SUB <id>." ;;
esac

case "$SUB" in
  pause)  cmd_pause ;;
  resume) cmd_resume ;;
  ''|*)   die "unknown subcommand '${SUB:-}'. Usage: pause.sh pause <id> | resume <id>." ;;
esac
