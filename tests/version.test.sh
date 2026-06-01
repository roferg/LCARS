#!/usr/bin/env bash
#
# Tests for `version.sh` (repo-root version command).
#
# Drives the behaviour from ticket t-001 through the public CLI interface
# only — running `bash version.sh` and observing its stdout and exit code.
# No internals are inspected. The suite restores the VERSION file it touches
# so it leaves the working tree clean.
#
# Usage: bash tests/version.test.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_VERSION_SCRIPT:-$REPO_ROOT/version.sh}"
VERSION_FILE="$REPO_ROOT/VERSION"

pass=0
fail=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

# Snapshot VERSION so the suite leaves the tree exactly as it found it.
SAVED_VERSION=""
HAD_VERSION=0
if [ -f "$VERSION_FILE" ]; then
  HAD_VERSION=1
  SAVED_VERSION="$(cat "$VERSION_FILE")"
fi
restore_version() {
  if [ "$HAD_VERSION" -eq 1 ]; then
    printf '%s\n' "$SAVED_VERSION" >"$VERSION_FILE"
  else
    rm -f "$VERSION_FILE"
  fi
}
trap restore_version EXIT

echo "version.sh"

# --- Case 1: VERSION present -> prints exactly 'LCARS <version>', exits 0 ---
printf '0.1.0\n' >"$VERSION_FILE"
out="$(bash "$SCRIPT" 2>/dev/null)"
code=$?
if [ "$out" = "LCARS 0.1.0" ]; then
  ok "prints exactly 'LCARS 0.1.0' when VERSION contains 0.1.0"
else
  bad "expected 'LCARS 0.1.0', got '$out'"
fi
if [ "$code" -eq 0 ]; then
  ok "exits 0 when VERSION is present"
else
  bad "expected exit 0 when VERSION present, got $code"
fi

# --- Case 2: VERSION missing -> prints 'LCARS unknown', exits non-zero ---
rm -f "$VERSION_FILE"
out="$(bash "$SCRIPT" 2>/dev/null)"
code=$?
if [ "$out" = "LCARS unknown" ]; then
  ok "prints 'LCARS unknown' when VERSION is missing"
else
  bad "expected 'LCARS unknown', got '$out'"
fi
if [ "$code" -ne 0 ]; then
  ok "exits non-zero when VERSION is missing"
else
  bad "expected non-zero exit when VERSION missing, got $code"
fi

# --- Summary ---
echo
echo "  $pass passed, $fail failed"
[ "$fail" -eq 0 ]
