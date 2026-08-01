#!/usr/bin/env bash
#
# base-freshness.sh — report this repo's BASE-freshness verdict, READ-ONLY (S160).
#
# A THIN wrapper over the ONE shared guard in lcars-common.sh
# (`ensure_base_current` + `lcars_base_state_json`), the sibling of readiness.sh:
# every surface — `lcars file`'s file-time block, `lcars run`'s drive-time
# re-check, and the viewscreen's File-console pre-flight line — reaches the same
# verdict from the same code, and none of them composes its own sentence about
# git state. The board DISPLAYS this record's `reason` and `fix`; it never
# derives copy of its own.
#
# WHY IT EXISTS. S158/S159 print their warning to stdout, and the daemon
# dispatches file.sh through a pipe — so a captain filing from the board sees
# nothing at all. This is what the board can safely ask BEFORE the idea is typed.
#
# READ-ONLY BY CONSTRUCTION, not by convention. It exports
# LCARS_BASE_CHECK_ONLY=1 ITSELF, overriding whatever the caller's environment
# carries, so the guard's one writing step — the local fast-forward — cannot run
# from here. The daemon inherits the captain's whole environment; a board render
# must never be able to fast-forward the captain's checkout as a side effect.
# (A `git fetch` still happens: it writes only into refs/remotes/, provably
# cannot touch a working tree, and without one there is nothing to measure.)
#
# Usage:
#   base-freshness.sh            print the human ⚠ block (EMPTY when all is well)
#   base-freshness.sh --line     same as above, explicit
#
# "EMPTY when all is well" is a promise about STDOUT, and it is now kept: the
# guard's ⟳ progress line — which prints on every path, because measuring
# freshness always costs a fetch — goes to STDERR (see `_lcars_base_announce`).
# The captain running this in a terminal still sees the ⟳; a consumer testing
# stdout for emptiness gets the answer the contract promises.
#   base-freshness.sh --json     print the record as ONE JSON object —
#                                {verdict, loud, reason, fix, fixNote, blocker,
#                                 behindBy, aheadBy, baseSha, checkedAt,
#                                 missionBranchAtBase}.
#                                The daemon parses this and surfaces the line
#                                only when `loud` is true. `fix` is ONE runnable
#                                command or nothing; `fixNote` is the prose
#                                beside it; `blocker` names what stopped the
#                                update, and the board's badge headline is built
#                                from it rather than from the commit count.
#
# Exit 0 always (it is a report, never a gate) — except on an unknown option,
# which must not read as "all clear".
set -uo pipefail

MODE="line"
case "${1:-}" in
  --json) MODE="json" ;;
  --line|'') MODE="line" ;;
  *) printf 'lcars base-freshness: unknown option "%s" — use --line or --json.\n' "$1" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lcars-common.sh
. "$SCRIPT_DIR/lcars-common.sh"

# The flag the whole script is about. Set here, not by the caller: see above.
export LCARS_BASE_CHECK_ONLY=1

# --json is a machine surface, so the human ⚠ block is silenced — the record it
# prints carries the same words, and printing both would put un-parseable prose
# in front of the JSON.
[ "$MODE" = "json" ] && export LCARS_BASE_QUIET=1

# The base a Mission filed right now would be cut from — resolved through the
# SAME function `lcars file` uses, so this never reports on a branch the captain
# is not about to file against.
BASE="$(lcars_base_current_branch)"

ensure_base_current "$BASE"

if [ "$MODE" = "json" ]; then
  # `lcars_base_state_json` prints nothing when no check ran, and the guard
  # ALWAYS sets a verdict (it has an `unknown` lane for "not a git repo at all"),
  # so this branch is belt-and-braces: a board that receives no JSON must still
  # receive JSON. No mission branch is named — this is a question about the repo,
  # not about any Mission — so `missionBranchAtBase` is null.
  REC="$(lcars_base_state_json)"
  [ -n "$REC" ] || REC='{ "verdict": "unknown", "loud": false, "reason": "the base-freshness check produced no verdict.", "fix": "", "fixNote": "", "blocker": "", "behindBy": null, "aheadBy": null, "baseSha": null, "checkedAt": "", "missionBranchAtBase": null }'
  printf '%s\n' "$REC"
fi
exit 0
