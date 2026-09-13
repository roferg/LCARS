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
# --- THE state.json field writer (S207) ------------------------------------
# ONE family, in ONE place: lcars_state_set (a raw JSON token) /
# lcars_state_set_string (plain text, escaped for you) / lcars_state_unset.
# This file used to carry its own copy, as seven others did, and every copy
# corrupted the object when the field it wrote or cleared was the object's LAST
# one (S189 found it in adopt; S202 made it reachable through the gate clears).
# A MISSING library is FATAL here rather than degraded: a fallback writer is
# exactly how two ways of writing one field get back into the tree.
LCARS_STATE_LIB="${LCARS_STATE_LIB:-$SKILL_DIR/../lcars-init/lcars-state.sh}"
[ -f "$LCARS_STATE_LIB" ] || {
  echo "LCARS: the state writer library is missing at $LCARS_STATE_LIB — reinstall LCARS (./install.sh)." >&2
  exit 1
}
# shellcheck source=../lcars-init/lcars-state.sh
. "$LCARS_STATE_LIB"

GH_BIN="${LCARS_GH_BIN:-gh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILL_DIR/../lcars-run/run.sh}"
RELABEL_NOTE=""

# One script, TWO verbs — so the name in front of the colon is a VARIABLE, set
# from the subcommand at dispatch. It used to be hard-coded `lcars pause`, and
# `lcars resume <id>` on someone else's mission answered `lcars pause: assigned
# to …`: the sentence was right and the verb named was one the captain had not
# typed. The SENTENCE itself is a shared contract (ownership.sh owns those bytes,
# and tests/ownership.test.sh D17 compares eight verbs' refusals against it) and
# is NOT touched here — only the prefix. `pause` stays the default so a failure
# raised before the subcommand is known still has a name.
DIE_VERB="pause"
die() { printf 'lcars %s: %s\n' "$DIE_VERB" "$1" >&2; exit 1; }

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

# --- emit an append-only event (same line shape + atomicity as run.sh) ------
# NEW event type only (append-only); never touches the existing schema.
emit_event() { # type stage detail
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ts type stage detail mid
  ts="${LCARS_NOW:-$(date +%s)}"
  # JSON-string-safe escape: backslash/quote via bash, then awk escapes every
  # control char (newline/tab/CR → \n \t \r, rest \u00XX) so any multi-line
  # value yields VALID JSON. jq-free. Order: backslash first.
  json_escape() {
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
    printf '%s' "$s" | awk '
      BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
      { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
          if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
          else if (c=="\r") printf "\\r"
          else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
  }
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

# --- S189/S196: solo ownership, the light lock -----------------------------
# A mission assigned to SOMEONE ELSE on GitHub is READ-ONLY to this laptop's
# write verbs. `lcars pause` and `lcars resume` both REWRITE state.json and move
# the `lcars:paused` label on someone's issue, so they consult the lock; the READ
# verbs (status, buddy, the viewscreen's reads) never do. The remedy is
# deliberately a HUMAN act on GitHub — the solo protocol's premise is that the
# captain moves ownership where both laptops can see it, and LCARS never takes a
# mission off anyone.
#
# WHY THIS ARRIVED A ROUND LATE (S196 A6). S189 wired the lock into run /
# respond / approve / feedback / log but not here, while the viewscreen's write
# endpoints 403 pause AND resume — so the board refused the captain's Pause on
# someone else's mission and `lcars pause <id>` in the next terminal obeyed
# silently. The captain's standing ruling is that the board is a UI version of
# the command line: where the two disagree the CLI comes into line, and the
# board's 403 is never relaxed to match.
#
# The library lives in the sibling lcars-run skill dir (the same reach this
# script already makes for run.sh). A MISSING library leaves the verb unenforced
# — exactly pre-S189 behaviour — rather than refusing blindly, and
# LCARS_OWNER_ENFORCE=0 bypasses the lock for harness debugging.
OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SKILL_DIR/../lcars-run/ownership.sh}"
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

# === subcommand: pause ======================================================
cmd_pause() {
  locate_mission "$MISSION_ID"
  # S196: the light lock, before a single field is touched. Pausing someone
  # else's mission is a write to their work.
  owner_lock_or_die "$(json_raw "$STATE" githubIssue)"
  xo_lock_or_die "$MISSION_DIR"
  local stage; stage="$(json_str "$STATE" stage)"; stage="${stage:-unknown}"

  # Idempotent: lcars_state_set "$STATE" replaces (deletes-then-adds) so a double-pause
  # leaves exactly ONE paused=true field. Only emit the event on the transition.
  local was; was="$(json_raw "$STATE" paused)"
  lcars_state_set "$STATE" paused true
  # S207 fix round 1 (D2) — THE WRITE IS THE PAUSE. A tester handed this verb a
  # valid but COMPACT state.json: the writer refused (correctly, loudly, on
  # stderr) and this function went on to print "PAUSE: paused …" and exit 0 for
  # a mission that was still running. Ask the writer whether it actually wrote,
  # BEFORE the label, the event and the success line — a refusal is a failure of
  # the verb, not a cosmetic warning.
  lcars_state_refusal_die "lcars pause"
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
  # S196: resuming somebody else's parked mission starts a driver on their work
  # — the board 403s it, so the CLI refuses it, with the same sentence.
  owner_lock_or_die "$(json_raw "$STATE" githubIssue)"
  xo_lock_or_die "$MISSION_DIR"
  local stage; stage="$(json_str "$STATE" stage)"; stage="${stage:-unknown}"

  # Clear the flag (idempotent — lcars_state_unset "$STATE" is a no-op when absent) and drop the
  # label (gh tolerates removing a label that isn't applied).
  local was; was="$(json_raw "$STATE" paused)"
  lcars_state_unset "$STATE" paused
  # The same rule the other way round (S207 fix round 1, D2): if the flag could
  # not be cleared the mission is still paused, so never announce a resume — and
  # never `exec` the driver into a mission that will stop again immediately.
  lcars_state_refusal_die "lcars resume"
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
# Name the verb the captain typed BEFORE anything can die (the usage errors
# below are raised by this script for that subcommand, not for its sibling).
case "$SUB" in resume) DIE_VERB="resume" ;; esac
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
