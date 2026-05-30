#!/usr/bin/env bash
#
# Runs every *.test.sh in this directory. Exits non-zero if any suite fails.
# Each skill added to LCARS must ship a matching tests/<name>.test.sh.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

for t in "$DIR"/*.test.sh; do
  [ -f "$t" ] || continue
  bash "$t" || fail=1
  echo
done

[ "$fail" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$fail"
