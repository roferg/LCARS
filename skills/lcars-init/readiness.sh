#!/usr/bin/env bash
#
# readiness.sh — report the repo's test-readiness verdict (S146).
#
# A THIN, read-only wrapper over the ONE shared verdict in lcars-common.sh
# (lcars_test_readiness), so every surface — `lcars status`, the init/update
# readouts, and the viewscreen daemon's meta.testReadiness — computes readiness
# from the SAME code and can never disagree. CHEAP by construction: no test run,
# no network, no worker; it inspects config.json + the top-level stack markers
# only. It writes NOTHING.
#
# Usage:
#   readiness.sh            print the ONE human status line (EMPTY when ready)
#   readiness.sh --line     same as above, explicit
#   readiness.sh --json     print {"status","suggestion","testCommand"} —
#                           status ∈ ready|missing|broken|unknown; suggestion /
#                           testCommand are null when absent. S183 adds
#                           `foundation` (greenfield|untested|unconfigured|
#                           ready) + `foundationWhy` — the SECOND axis. The daemon parses
#                           this and OMITS meta.testReadiness when ready.
#
# Exit 0 always (it is a report, never a gate).
set -uo pipefail

MODE="line"
case "${1:-}" in
  --json) MODE="json" ;;
  --line|'') MODE="line" ;;
  *) printf 'lcars readiness: unknown option "%s" — use --line or --json.\n' "$1" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lcars-common.sh"

# --- locate the repo (same resolution init/update use) ---------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || GIT_DIR=""
if [ -z "$GIT_DIR" ]; then
  # not a git repo — nothing to report on; stay silent (a report, not a gate).
  # Not a repo — nothing to classify, and NOTHING is refused on this answer:
  # `foundation` is null, which every consumer reads as "no verdict", never as
  # "greenfield". (The gate's refusal requires a POSITIVE greenfield/untested.)
  [ "$MODE" = "json" ] && printf '{"status":"unknown","suggestion":null,"testCommand":null,"foundation":null,"foundationWhy":null}\n'
  exit 0
fi
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
CONFIG="$GIT_DIR/lcars/config.json"

lcars_test_readiness "$CONFIG"

if [ "$MODE" = "json" ]; then
  sug='null'
  [ -n "$LCARS_TESTREADY_SUGGESTION" ] \
    && sug="\"$(lcars_json_escape "$LCARS_TESTREADY_SUGGESTION")\""
  tc='null'
  [ -n "$LCARS_TESTREADY_TESTCMD" ] \
    && tc="\"$(lcars_json_escape "$LCARS_TESTREADY_TESTCMD")\""
  # S147: `stacks` names the candidates behind an `ambiguous` verdict so the
  # board can speak the same CHOOSE voice the CLI line does, and `candidates`
  # carries the PICKABLE commands so the board's fix affordance can offer a
  # choice instead of dispatching a paid discovery worker. Both null for every
  # other status — the daemon only forwards them when set, so missing/broken/
  # unknown payloads stay byte-identical to S146.
  st='null'
  [ -n "${LCARS_TESTREADY_STACKS:-}" ] \
    && st="\"$(lcars_json_escape "$LCARS_TESTREADY_STACKS")\""
  cands='null'
  if [ -n "${LCARS_TESTREADY_CANDIDATES:-}" ]; then
    cands='['; sep=''
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      cands="$cands$sep\"$(lcars_json_escape "$c")\""; sep=','
    done <<CANDS
$LCARS_TESTREADY_CANDIDATES
CANDS
    cands="$cands]"
  fi
  # S183: the FOUNDATION axis rides alongside the status one, ALWAYS present
  # (unlike stacks/candidates, which are verdict-specific) so the board and the
  # filing gate never have to re-derive it. Purely additive — every existing key
  # keeps its exact meaning and shape.
  fnd='null'
  [ -n "${LCARS_TESTREADY_FOUNDATION:-}" ] \
    && fnd="\"$(lcars_json_escape "$LCARS_TESTREADY_FOUNDATION")\""
  fwhy='null'
  [ -n "${LCARS_TESTREADY_FOUNDATION_WHY:-}" ] \
    && fwhy="\"$(lcars_json_escape "$LCARS_TESTREADY_FOUNDATION_WHY")\""
  printf '{"status":"%s","suggestion":%s,"testCommand":%s,"stacks":%s,"candidates":%s,"foundation":%s,"foundationWhy":%s}\n' \
    "$LCARS_TESTREADY_STATUS" "$sug" "$tc" "$st" "$cands" "$fnd" "$fwhy"
else
  lcars_readiness_line
fi
exit 0
