#!/usr/bin/env bash
# Full round-3 regression sweep: every planted page, one line each.
cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
for f in tests/drives/s212/pages/*.html; do
  n="$(basename "$f" .html)"
  out="$(S212_OUT=tests/drives/s212/sweep bash tests/drives/s212/probe.sh "$PWD/$f" "$n" 2>&1)"
  obs="$(printf '%s' "$out" | grep -cE '^  \*')"
  note="$(printf '%s' "$out" | grep -c '^  NOTE')"
  uns="$(printf '%s' "$out" | sed -n 's/.*unseen(skipped): \([0-9]*\).*/\1/p' | head -1)"
  hung="$(printf '%s' "$out" | grep -c 'TIMED OUT')"
  printf '%-34s obs=%-3s note=%-2s unseen=%-3s hung=%s\n' "$n" "$obs" "$note" "${uns:-?}" "$hung"
  printf '%s' "$out" | grep -E '^  \*|^  NOTE' | sed 's/^/      /'
done
