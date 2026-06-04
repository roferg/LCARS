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
#
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RESOLVE="${LCARS_RESOLVE_SCRIPT:-$SKILL_DIR/resolve.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILL_DIR/../lcars-run/run.sh}"
ANSWER_SCRIPT="${LCARS_ANSWER_SCRIPT:-$SKILL_DIR/../lcars-answer/answer.sh}"

die() { printf 'lcars: %s\n' "$1" >&2; exit 1; }

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
if [ -n "$MISSIONS_DIR" ] && [ -d "$MISSIONS_DIR" ]; then
  shopt -s nullglob
  for s in "$MISSIONS_DIR"/*/state.json; do
    stage="$(json_str "$s" stage)"
    awaiting="$(sed -n 's/.*"awaitingHuman"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$s" | head -1)"
    if [ "$awaiting" = "true" ] || [ "$stage" = "verify" ]; then
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
    *) die "no active mission matches \"$SELECTOR\"." ;;
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

# 3. Nothing filed — enter the file flow (Claude runs the Align conversation).
echo "No missions found — filing a new one."
echo "ROUTE: file"
exit 0
