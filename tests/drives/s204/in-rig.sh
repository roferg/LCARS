#!/usr/bin/env bash
# Run a command inside an S204 rig with the rig's HOME, PATH and gh auth.
# ORDER MATTERS: GH_TOKEN must be resolved BEFORE HOME is redirected, or gh
# looks for the keyring inside the throwaway HOME and finds nothing.
#   bash in-rig.sh <tag> <cmd...>
set -uo pipefail
TAG="${1:?tag}"; shift
OUT="${TMPDIR:-/tmp}/lcars-s204-tester-$TAG"
. "$OUT/rig.env"
. "$OUT/token.env" 2>/dev/null || true
export GH_TOKEN GITHUB_TOKEN="${GH_TOKEN:-}" COPILOT_GITHUB_TOKEN="${GH_TOKEN:-}"
export HOME="$RIG_HOME" PATH="$RIG_BIN:$PATH"
cd "$RIG_FIXTURE" || exit 70
exec "$@"
