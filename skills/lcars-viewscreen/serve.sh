#!/usr/bin/env bash
#
# lcars serve — power-alias shim for `lcars viewscreen` (the LCARS bridge
# viewscreen / Kanban web board).
#
# The board verb was renamed to `lcars viewscreen`; `lcars serve` stays as a
# documented power alias (the LCARS "old verbs stay as power aliases" pattern),
# so any script or muscle-memory that calls `serve.sh` keeps launching the exact
# same daemon. This shim does nothing but exec the real launcher next to it,
# forwarding every argument and the full environment (LCARS_SERVE_* etc.)
# unchanged — there is a single implementation (viewscreen.sh), never a fork.
#
set -uo pipefail
SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
exec bash "$SKILL_DIR/viewscreen.sh" "$@"
