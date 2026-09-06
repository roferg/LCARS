#!/usr/bin/env bash
#
# foundation-gate.sh — THE FOUNDATION GATE (S183).
#
# ┌────────────────────────────────────────────────────────────────────────┐
# │ ⚠ SESSION 184 REPLACES `lcars_establish_vision_offer` (BELOW).         │
# │                                                                        │
# │ This file is the ONE seam between "a repo with no test foundation" and │
# │ "Establish Vision". Today the seam REFUSES and tells the captain what  │
# │ to do; S184 makes the same seam OFFER the real Establish Vision flow   │
# │ (say what you want to build → LCARS grills you → recommends a stack →  │
# │ files an INITIALIZATION mission). Nothing else needs to move: every    │
# │ caller — `lcars file` on the CLI, the viewscreen's file / park / align │
# │ endpoints, and the holodeck entry — routes through this one function,  │
# │ and the refusal wording lives here and nowhere else.                   │
# │                                                                        │
# │ See lcars-dev/greenfield-dev.md → Session 184.                          │
# └────────────────────────────────────────────────────────────────────────┘
#
# WHY THE GATE EXISTS. `lcars file` used to open a normal mission on a repo with
# no way to prove any work. S182's wall then parked the mission at Implement —
# correct, and late: the captain had already written a PRD and watched Research,
# Validate and Plan run. The captain's ruling (2026-09-05) is that the
# foundation is established BEFORE any normal mission, by an initialization
# mission launched from Establish Vision, with the captain at Verify. So the
# refusal belongs at FILING TIME, before a single worker is hired.
#
# WHAT IS AND IS NOT REFUSED — this is the whole contract:
#
#   greenfield    REFUSED   nothing is there
#   untested      REFUSED   code exists, no test system
#   unconfigured  ALLOWED   a test system EXISTS; LCARS just has no command for
#                           it. That is the `lcars update --test-command` /
#                           `--fix-tests` case and it must keep working exactly
#                           as it does today.
#   ready         ALLOWED   unchanged
#   (no verdict)  ALLOWED   not a git repo, not an LCARS repo, helper missing or
#                           broken — the gate DEGRADES TO ALLOW. It refuses only
#                           on a POSITIVE greenfield/untested verdict, never on
#                           an absence of information.
#
# The verdict is the shared one (lcars_test_readiness → LCARS_TESTREADY_FOUNDATION
# in lcars-common.sh), so the gate, the readiness line, `lcars status`, the
# board and run.sh's implement wall can never tell the captain different stories.
#
# Usage:
#   foundation-gate.sh            refuse (message on stdout, exit 20) or exit 0
#   foundation-gate.sh --check    same, but silent — the exit status IS the answer
#   foundation-gate.sh --json     {"foundation","foundationWhy","allowed","message"}
#                                 — exit 0 always; the daemon reads `allowed`.
#
# Exit: 0 allowed · 20 refused · 1 bad usage.
set -uo pipefail

MODE="gate"
case "${1:-}" in
  --json)  MODE="json" ;;
  --check) MODE="check" ;;
  --gate|'') MODE="gate" ;;
  *) printf 'lcars foundation-gate: unknown option "%s" — use --check or --json.\n' "$1" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lcars-common.sh
. "$SCRIPT_DIR/lcars-common.sh"

REFUSAL_EXIT=20

# --- resolve the repo (the SAME resolution readiness.sh / init / update use) --
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || GIT_DIR=""
FOUNDATION=""
FOUNDATION_WHY=""
if [ -n "$GIT_DIR" ]; then
  case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
  CONFIG="$GIT_DIR/lcars/config.json"
  lcars_test_readiness "$CONFIG" >/dev/null 2>&1 || true
  FOUNDATION="${LCARS_TESTREADY_FOUNDATION:-}"
  FOUNDATION_WHY="${LCARS_TESTREADY_FOUNDATION_WHY:-}"
fi

# ---------------------------------------------------------------------------
# lcars_establish_vision_offer — ⚠ THE S184 REPLACEMENT POINT (see the header).
# ---------------------------------------------------------------------------
# Today: the plain-English refusal, in the captain's language, naming Establish
# Vision as what to do instead. It says what LCARS found, why that stops a normal
# mission, and what happens next — and it never blames the captain for a repo
# that is simply new.
#
# S184: this becomes the entry to the real flow. Keep the SHAPE — one block of
# prose on stdout, and the caller decides — so the CLI, the board and the
# holodeck all inherit the change at once.
#
# S183 fix round 1 (D6): the untested arm STUTTERED — "This repo has code, but
# no test system: this repo has code and no test system." — because it pasted
# `$why` after a colon that had already said it. The `untested` why-string is a
# whole sentence, unlike the `unconfigured` ones ("a Makefile `test:` target"),
# and the gate is the only surface that pastes it. This string is also the
# daemon's 409 body, so it is read by the captain twice over. `$why` stays in the
# signature — the --json mode reports it as its own field — it just is not
# spliced into a sentence that already carries it.
lcars_establish_vision_offer() { # foundation why → the refusal text
  local f="$1" why="$2" what
  : "$why"
  case "$f" in
    untested)
      what="This repo has code, but no test system — nothing here can prove that a change works." ;;
    *)
      what="This repo is empty — there is no code and no test system here yet." ;;
  esac
  cat <<REFUSAL
◇ NO TEST FOUNDATION — this repo cannot run a normal mission yet.

$what

Every LCARS ticket is proven by RUNNING its tests — red on the parent commit,
green on the tip. With no test system there is no way to prove any work, so a
mission filed here would burn its Research, Validate and Plan stages and then
stop dead at Implement with nothing to show for it.

WHAT TO DO INSTEAD — Establish Vision. Say what you want to build; LCARS grills
you, recommends a stack with its reasons (yours to override), and files an
INITIALIZATION mission whose whole job is the foundation: a running skeleton
with a working test system, and you at Verify to watch the suite actually run.
Normal missions unlock the moment that lands.

If this repo DOES already have a test system and LCARS just cannot see it, point
LCARS at it instead:  lcars update --test-command '<command>'
REFUSAL
}

# lcars_foundation_allowed — 0 when filing may proceed. The ONE decision.
lcars_foundation_allowed() {
  case "$FOUNDATION" in
    greenfield|untested) return 1 ;;
    *) return 0 ;;   # ready · unconfigured · no verdict at all → allow
  esac
}

if [ "$MODE" = "json" ]; then
  allowed=true
  lcars_foundation_allowed || allowed=false
  msg=""
  [ "$allowed" = false ] && msg="$(lcars_establish_vision_offer "$FOUNDATION" "$FOUNDATION_WHY")"
  fnd='null'; [ -n "$FOUNDATION" ] && fnd="\"$(lcars_json_escape "$FOUNDATION")\""
  fwhy='null'; [ -n "$FOUNDATION_WHY" ] && fwhy="\"$(lcars_json_escape "$FOUNDATION_WHY")\""
  m='null'; [ -n "$msg" ] && m="\"$(lcars_json_escape "$msg")\""
  printf '{"foundation":%s,"foundationWhy":%s,"allowed":%s,"message":%s}\n' \
    "$fnd" "$fwhy" "$allowed" "$m"
  exit 0
fi

if lcars_foundation_allowed; then exit 0; fi
[ "$MODE" = "check" ] || lcars_establish_vision_offer "$FOUNDATION" "$FOUNDATION_WHY"
exit "$REFUSAL_EXIT"
