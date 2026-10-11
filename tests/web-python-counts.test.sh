#!/usr/bin/env bash
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAGE="$DIR/lib/cage.py"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/tests/lib" "$TMPROOT/web/tests"
cp "$DIR/web-python.test.sh" "$TMPROOT/tests/"
cp "$CAGE" "$TMPROOT/tests/lib/"
touch "$TMPROOT/web/tests/__init__.py"
cat >"$TMPROOT/web/tests/test_normal.py" <<'PY'
import os
import unittest

class Controls(unittest.TestCase):
    def test_passes(self):
        self.assertNotEqual(os.environ.get("WEB_COUNTS_CONTROL"), "failure")

    @unittest.skip("deliberate skip")
    def test_skips(self):
        self.fail("unreachable")

    @unittest.expectedFailure
    def test_expected_failure(self):
        self.assertEqual(os.environ.get("WEB_COUNTS_CONTROL"), "xpass")
PY
cat >"$TMPROOT/web/tests/test_holodeck_endpoints.py" <<'PY'
import unittest

class EndpointControl(unittest.TestCase):
    def test_passes(self):
        self.assertTrue(True)
PY

pass=0; fail=0
check() {
  if grep -qxF "$2" <<<"$out" && grep -Eq "^ELAPSED [0-9.]+s EXIT $3$" <<<"$out"; then
    echo "PASS $1"; pass=$((pass + 1))
  else
    echo "FAIL $1"; printf '%s\n' "$out"; fail=$((fail + 1))
  fi
}
out="$(WEB_COUNTS_CONTROL=normal python3 "$CAGE" 30 bash "$TMPROOT/tests/web-python.test.sh" 2>&1)"
check "OK distinguishes passes, skips and expected failures" \
  "web python: 2 passed, 0 failed, 1 skipped, 1 expected failures" 0
out="$(WEB_COUNTS_CONTROL=xpass python3 "$CAGE" 30 bash "$TMPROOT/tests/web-python.test.sh" 2>&1)"
check "an unexpected success is a failure, not an ordinary pass" \
  "web python: 2 passed, 1 failed, 1 skipped, 0 expected failures" 1
out="$(WEB_COUNTS_CONTROL=failure python3 "$CAGE" 30 bash "$TMPROOT/tests/web-python.test.sh" 2>&1)"
check "FAILED also separates skips and expected failures" \
  "web python: 1 passed, 1 failed, 1 skipped, 1 expected failures" 1
printf 'web python counts: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
