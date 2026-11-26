#!/usr/bin/env bash
# Offline, read-only claim resolution plus mutations of disposable doc copies.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_status() {
  if [ "$2" -eq "$3" ]; then
    printf 'PASS %s: exit %s\n' "$1" "$2"
  else
    printf 'FAIL %s: expected exit %s, got %s\n' "$1" "$3" "$2"
    return 1
  fi
}

if [ "${1:-}" = "--assertion-control" ]; then
  bash "$DIR/../skills/lcars-eeh/eeh.sh" docs s357-no-such-doc >/dev/null 2>&1
  status=$?
  label="$(basename assertion-control)"
  check_status "$label" "$status" 0
  exit $?
fi

python3 "$DIR/lib/test_doc_claims.py" || exit $?
printf 'MUTATIONS: disposable document copies cleaned; source documents untouched.\n'
python3 "$DIR/lib/doc_claims.py" "$@"
status=$?
label="$(basename "$DIR")/doc-claims"
check_status "$label" "$status" 0
