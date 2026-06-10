#!/usr/bin/env bash
#
# Runs every *.test.sh in a directory. Exits non-zero if any suite fails.
# Each skill added to LCARS must ship a matching tests/<name>.test.sh.
#
# Target directory resolution (BUG-009): a positional $1, else $LCARS_TESTS_DIR
# when non-empty, else this script's own directory. LCARS dogfoods this runner as
# its `testCommand`, and the Implement red gate runs it with $LCARS_TESTS_DIR
# pointing at the quarantined fail-first tests (and probes with an EMPTY dir to
# prove the command reacted). Honouring the var lets the gate scope the runner to
# those tests. With NO var/arg a human gets the full repo suite, exactly as before.
#
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" != "" ]; then
  TESTS_DIR="$1"
elif [ -n "${LCARS_TESTS_DIR:-}" ]; then
  TESTS_DIR="$LCARS_TESTS_DIR"
else
  TESTS_DIR="$DIR"
fi

fail=0

for t in "$TESTS_DIR"/*.test.sh; do
  [ -f "$t" ] || continue
  bash "$t" || fail=1
  echo
done

[ "$fail" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$fail"
