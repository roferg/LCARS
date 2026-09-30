#!/usr/bin/env bash
#
# lcars — the one entry point. "Do the right thing" from the current state.
#
# This adds NO stage logic. It is a dispatcher: it reads mission state, ANNOUNCES
# the action it inferred (so the smart default never surprises the captain), then
# delegates to a script already built. There are three routes:
#
#   • a decision is pending      → open the inbox      (delegate: answer.sh list)
#   • work in flight, none pending → drive that mission (delegate: run.sh drive)
#   • no missions filed          → the file flow        (Claude runs the Align
#                                  conversation per the SKILL.md; this script
#                                  only announces ROUTE: file)
#
# "Pending" wins over "drivable": if anything is waiting on the captain, that
# comes first. The drivable mission is picked by the shared resolver — one
# candidate needs no id; several drop into a picker; an explicit id / partial /
# title is always honoured (`lcars <selector>`).
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_RUN_SCRIPT      run.sh    (drive)      default: ../lcars-run/run.sh
#   LCARS_ANSWER_SCRIPT   answer.sh (inbox)      default: ../lcars-answer/answer.sh
#   LCARS_RESOLVE_SCRIPT  resolve.sh (resolver)  default: ./resolve.sh
#   LCARS_XO_SCRIPT       xo.sh     (Number One)  default: ../lcars-xo/xo.sh
#
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RESOLVE="${LCARS_RESOLVE_SCRIPT:-$SKILL_DIR/resolve.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILL_DIR/../lcars-run/run.sh}"
ANSWER_SCRIPT="${LCARS_ANSWER_SCRIPT:-$SKILL_DIR/../lcars-answer/answer.sh}"
RESOLVE_LOGS_SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$SKILL_DIR/../lcars-resolve-logs/resolve-logs.sh}"
PAUSE_SCRIPT="${LCARS_PAUSE_SCRIPT:-$SKILL_DIR/../lcars-pause/pause.sh}"
XO_SCRIPT="${LCARS_XO_SCRIPT:-$SKILL_DIR/../lcars-xo/xo.sh}"

die() { printf 'lcars: %s\n' "$1" >&2; exit 1; }

# --- explicit verbs: thin delegators to a script already built -------------
# These come BEFORE the smart-default routing so a verb is never mistaken for a
# mission selector. Each one owns its own arg parsing.
case "${1:-}" in
  resolve-logs)
    shift
    exec bash "$RESOLVE_LOGS_SCRIPT" "$@" ;;
  pause)
    shift
    exec bash "$PAUSE_SCRIPT" pause "$@" ;;
  resume)
    shift
    exec bash "$PAUSE_SCRIPT" resume "$@" ;;
  # S201 — Number One. An EXPLICIT delegator, not smart-default routing: `lcars
  # xo` with no further argument is a STATUS READ, and the router below would
  # otherwise take the bare word as a mission selector and try to drive
  # something. It also runs BEFORE the interactive version check, like its
  # siblings, so a read stays a read.
  xo)
    shift
    exec bash "$XO_SCRIPT" "$@" ;;
esac

# --- version check + ask-to-update (interactive; S129) ---------------------
# `lcars` is an interactive entry point, so BEFORE routing we run the throttled
# version check in ASK mode. It is fully guarded: a missing helper, a non-zero
# exit, or the LCARS_VERSION_CHECK=0 kill switch can never sink the verb.
VERSION_CHECK="${LCARS_VERSION_CHECK_BIN:-$SKILL_DIR/../lcars-version/check.sh}"
[ -f "$VERSION_CHECK" ] && bash "$VERSION_CHECK" ask || true


json_str() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1; }

# --- locate .git/lcars/missions --------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || GIT_DIR=""
if [ -n "$GIT_DIR" ]; then
  case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
fi
MISSIONS_DIR="${GIT_DIR:+$GIT_DIR/lcars/missions}"

# --- count what's pending vs drivable --------------------------------------
# pending  = a Mission needs the captain (awaitingHuman, or parked at verify)
# drivable = a Mission the loop can advance (stage not done)
pending=0
drivable=0
parked=0
if [ -n "$MISSIONS_DIR" ] && [ -d "$MISSIONS_DIR" ]; then
  shopt -s nullglob
  for s in "$MISSIONS_DIR"/*/state.json; do
    stage="$(json_str "$s" stage)"
    awaiting="$(sed -n 's/.*"awaitingHuman"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$s" | head -1)"
    paused="$(sed -n 's/.*"paused"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$s" | head -1)"
    prdpending="$(sed -n 's/.*"prdPending"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$s" | head -1)"
    # A paused Mission (ADR-005) is neither pending nor drivable: the driver
    # would just halt at the next boundary, so bare `lcars` must not auto-pick it.
    if [ "$paused" = "true" ]; then
      :
    # A PARKED Mission (prdPending) awaits ALIGNMENT — it is NOT drivable (no PRD)
    # and NOT a pending decision. Counted on its own so bare `lcars` OFFERS it for
    # grilling but NEVER auto-drives it.
    elif [ "$prdpending" = "true" ]; then
      parked=$((parked + 1))
    elif [ "$awaiting" = "true" ] || [ "$stage" = "verify" ]; then
      pending=$((pending + 1))
    elif [ "$stage" != "done" ]; then
      drivable=$((drivable + 1))
    fi
  done
  shopt -u nullglob
fi

SELECTOR="${1:-}"

# --- explicit selector: resolve (active scope) and drive it ----------------
# `lcars <id|partial|title>` is the power path — go straight to that Mission.
if [ -n "$SELECTOR" ]; then
  out="$(bash "$RESOLVE" --scope active --id "$SELECTOR")"; rc=$?
  case "$rc" in
    0) mid="$out"
       st="$(json_str "$MISSIONS_DIR/$mid/state.json" stage)"
       printf 'Driving %s%s.\n' "$mid" "${st:+ from $st}"
       echo "ROUTE: drive $mid"
       exec bash "$RUN_SCRIPT" drive --mission "$mid" ;;
    2) echo "Several missions match \"$SELECTOR\" — pick one:"
       printf '%s\n' "$out" | while IFS=$'\t' read -r id title stage note; do
         printf '  %s  %s  (%s)\n' "$id" "$title" "$stage"
       done
       echo "ROUTE: picker"
       exit 2 ;;
    *) # Not a drivable mission. It might be PARKED (awaiting alignment) — those
       # are deliberately kept out of the active/drivable set, so name the align
       # command rather than a bare "no match".
       pout="$(bash "$RESOLVE" --scope parked --id "$SELECTOR" 2>/dev/null)"; prc=$?
       if [ "$prc" -eq 0 ]; then
         printf '%s is parked awaiting alignment — run `lcars file %s` to align it.\n' "$pout" "$pout"
         echo "ROUTE: align-offer"
         exit 0
       fi
       die "no active mission matches \"$SELECTOR\"." ;;
  esac
fi

# --- bare `lcars`: infer the route from state ------------------------------

# 1. A pending decision wins — open the inbox.
if [ "$pending" -gt 0 ]; then
  if [ "$pending" -eq 1 ]; then
    printf '1 decision waiting — opening the inbox.\n'
  else
    printf '%s decisions waiting — opening the inbox.\n' "$pending"
  fi
  echo "ROUTE: inbox"
  exec bash "$ANSWER_SCRIPT" list
fi

# 2. Work in flight, nothing pending — drive the active mission.
if [ "$drivable" -gt 0 ]; then
  out="$(bash "$RESOLVE" --scope active)"; rc=$?
  case "$rc" in
    0) mid="$out"
       st="$(json_str "$MISSIONS_DIR/$mid/state.json" stage)"
       printf 'Driving %s%s.\n' "$mid" "${st:+ from $st}"
       echo "ROUTE: drive $mid"
       exec bash "$RUN_SCRIPT" drive --mission "$mid" ;;
    2) echo "Several missions in flight — pick one to drive:"
       printf '%s\n' "$out" | while IFS=$'\t' read -r id title stage note; do
         printf '  %s  %s  (%s)\n' "$id" "$title" "$stage"
       done
       echo "Run \`lcars <id>\` to drive one."
       echo "ROUTE: picker"
       exit 2 ;;
    *) die "could not resolve an active mission." ;;
  esac
fi

# 3. Parked missions await alignment — OFFER them for grilling, never drive.
# Nothing is pending and nothing is drivable, but one or more missions are parked
# (prdPending). Bare `lcars` surfaces them as the "awaiting alignment" group and
# tells the captain how to grill each — it does NOT auto-drive any (the driver
# never runs a PRD-less mission).
if [ "$parked" -gt 0 ]; then
  if [ "$parked" -eq 1 ]; then
    echo "1 mission awaiting alignment:"
  else
    printf '%s missions awaiting alignment:\n' "$parked"
  fi
  out="$(bash "$RESOLVE" --scope parked)"; rc=$?
  # 0 = single id (print it); 2 = table (already tab-separated); 3 = none (shouldn't happen)
  case "$rc" in
    0) st="$(json_str "$MISSIONS_DIR/$out/state.json" title)"
       printf '  %s  %s  (◇ standby)\n' "$out" "$st" ;;
    2) printf '%s\n' "$out" | while IFS=$'\t' read -r id title stage note; do
         printf '  %s  %s  (◇ %s)\n' "$id" "$title" "$note"
       done ;;
  esac
  echo "Run \`lcars file <id>\` to align one (the Align grill), then it flows the pipeline."
  echo "ROUTE: align-offer"
  exit 0
fi

# 3b. NO FOUNDATION AND NOTHING ON THE BOARD — the FRONT DOOR (S184).
#
# BOTH FRONT DOORS, ONE FLOW. Before this, `lcars` in a repo with no test system
# walked the captain into `lcars file`, which refused him (S183, exit 4) and
# printed instructions. That refusal is still there and still correct — it is the
# BACKSTOP — but it is not what day zero should feel like. Here `lcars` STARTS
# THE CONVERSATION instead: the same three screens the viewscreen renders, the
# same facts, the same foundation brief, the same script filing the same
# initialization mission. There is no second implementation of any of it.
#
# THE RULE IS NARROW, and deliberately so. It fires only when the verdict locks
# AND this repo has nothing to put on a board — which is what `--facts`'
# `frontDoor` answers. An initialized repo with a real board and a `untested`
# verdict (measured: `Flappy-Bird`, two live missions) keeps its normal
# behaviour, and S183's lock keeps applying to it exactly as today. Routes 1–3
# above already exit on any pending/drivable/parked mission, so this is a
# belt-and-braces agreement with the board, not the only guard.
ESTABLISH_VISION="${LCARS_ESTABLISH_VISION_BIN:-$SKILL_DIR/../lcars-init/establish-vision.sh}"
if [ -f "$ESTABLISH_VISION" ]; then
  facts="$(bash "$ESTABLISH_VISION" --facts 2>/dev/null)" || facts=""
  case "$facts" in
    *'"frontDoor":true'*)
      fnd="$(printf '%s' "$facts" | sed -n 's/.*"foundation"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      label="$(printf '%s' "$facts" | sed -n 's/.*"stackLabel"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      nsrc="$(printf '%s' "$facts" | sed -n 's/.*"sourceFiles"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
      if [ "$fnd" = "untested" ]; then
        # SCREEN 2 — it can SEE the code, so it does not ask what we are
        # building. It REPORTS, and the first thing anyone pointing LCARS at
        # real work wants to know is answered before they ask it.
        cat <<SCREEN2
◇ NO TEST SYSTEM

  I can see the code. I can't prove a change.

  Every LCARS ticket is proven by running its tests — red on the parent commit,
  green on the tip. This project has no runner, so there is nothing to prove a
  change with yet.

  FOUND
    Stack ........... ${label:-not recognised}
    Source files .... ${nsrc:-0}
    Test runner ..... none found
    Proof ........... not possible yet

  ▸ ESTABLISH TEST FOUNDATION — scope is the foundation only: a runner, a first
    real test, and the wiring to run it. Your code is not touched.

  Already have one? Point LCARS at it:
    lcars update --test-command '<command>'
SCREEN2
      else
        # SCREEN 1 — nothing is here, so nothing is withheld: one question.
        cat <<SCREEN1
◇ NEW PROJECT

  What are we building?

  Describe it however you like. LCARS will ask a few questions, recommend a
  stack and say why, then build the foundation — a running skeleton with a
  working test system — before any feature work starts.

  ▸ ESTABLISH VISION — say what you want to build, and answer the grill.

  Already have tests LCARS can't see? Point it at them:
    lcars update --test-command '<command>'
SCREEN1
      fi
      # The brief the grill runs under, printed so the captain and the model are
      # reading the same contract (and so a CLI grill cannot quietly run under a
      # different fence than the viewscreen's).
      bash "$ESTABLISH_VISION" --brief 2>/dev/null
      echo "ROUTE: vision"
      exit 0 ;;
  esac
fi

# 4. Nothing filed — enter the file flow (Claude runs the Align conversation).
echo "No missions found — filing a new one."
echo "ROUTE: file"
exit 0
