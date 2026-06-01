#!/usr/bin/env bash
# Behavioural test for tagline.sh — exercises the public interface (running the
# script) only. No knowledge of the implementation's internals.
set -u

# Resolve the repo root: this test lives in tests/, so the root is one level up.
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$test_dir/.." && pwd)"

expected='LCARS -- idea to merged PR'
fail=0

# 1. stdout must be exactly the tagline plus a trailing newline.
actual="$(bash "$repo_root/tagline.sh")"
if [ "$actual" != "$expected" ]; then
  echo "FAIL: stdout was [$actual], expected [$expected]"
  fail=1
fi

# 2. The script must emit a trailing newline (printf '%s\n').
raw="$(bash "$repo_root/tagline.sh"; printf 'X')"
if [ "$raw" != "${expected}"$'\n'"X" ]; then
  echo "FAIL: output did not end in exactly one trailing newline"
  fail=1
fi

# 3. Exit status must be 0.
bash "$repo_root/tagline.sh" >/dev/null
status=$?
if [ "$status" -ne 0 ]; then
  echo "FAIL: exit status was $status, expected 0"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "PASS: tagline.test.sh"
fi
exit "$fail"
