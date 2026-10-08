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
suites_run=0
suites_failed=0
run_started="$(date +%s)"

for t in "$TESTS_DIR"/*.test.sh; do
  [ -f "$t" ] || continue
  suite="$(basename "$t")"
  suite_started="$(date +%s)"
  printf 'SUITE %s\n' "$suite"
  # stdin CLOSED, always: a suite that reads inherited stdin (the `qgrep`
  # bare-`cat` class, S208) would otherwise block the whole gate forever.
  # Target-directory resolution above is untouched (BUG-009).
  bash "$t" </dev/null
  suite_status=$?
  suite_elapsed=$(( $(date +%s) - suite_started ))
  suites_run=$((suites_run + 1))
  if [ "$suite_status" -ne 0 ]; then
    fail=1
    suites_failed=$((suites_failed + 1))
  fi
  printf 'RESULT %s elapsed=%ss exit=%s\n' \
    "$suite" "$suite_elapsed" "$suite_status"
  echo
done

run_elapsed=$(( $(date +%s) - run_started ))
printf 'SUITES run=%s failed=%s elapsed=%ss\n' \
  "$suites_run" "$suites_failed" "$run_elapsed"
[ "$fail" -eq 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$fail"
