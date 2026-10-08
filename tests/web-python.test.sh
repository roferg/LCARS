#!/usr/bin/env bash
#
# Runs the Python viewscreen tests inside the full shell gate. The endpoint
# suite is legitimately slow, so the whole discovery run gets the measured
# 900-second budget rather than being mistaken for a hang.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
CAGE="$DIR/lib/cage.py"

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

normal_modules=()
for test_file in "$REPO_ROOT"/web/tests/test_*.py; do
  [ "$(basename "$test_file")" = "test_holodeck_endpoints.py" ] && continue
  module="$(basename "$test_file" .py)"
  normal_modules+=("tests.$module")
done

(
  cd "$REPO_ROOT/web"
  python3 "$CAGE" 900 python3 -m unittest "${normal_modules[@]}"
) >"$out" 2>&1
(
  cd "$REPO_ROOT/web"
  python3 "$CAGE" 900 python3 -m unittest tests.test_holodeck_endpoints
) >>"$out" 2>&1
cat "$out"

counts="$(python3 - "$out" <<'PY'
import re
import sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
ran = 0
failed = 0
skipped = 0
segments = re.split(r"(?=^ELAPSED )", text, flags=re.MULTILINE)
for segment in segments:
    if not segment.startswith("ELAPSED "):
        continue
    runs = re.findall(r"^Ran (\d+) tests?", segment, re.MULTILINE)
    ran += sum(int(count) for count in runs)
    segment_failed = 0
    summaries = re.findall(r"^FAILED \(([^)]*)\)$", segment, re.MULTILINE)
    for key in ("failures", "errors", "unexpected successes"):
        segment_failed += sum(
            int(match.group(1))
            for summary in summaries
            if (match := re.search(rf"{key}=(\d+)", summary))
        )
    for key in ("skipped", "expected failures"):
        skipped += sum(
            int(match.group(1))
            for summary in summaries
            if (match := re.search(rf"{key}=(\d+)", summary))
        )
    exit_match = re.search(r"^ELAPSED [^\n]* EXIT (\d+)$", segment, re.MULTILINE)
    if "TIMED OUT" in segment or not exit_match:
        segment_failed = max(segment_failed, 1)
    elif int(exit_match.group(1)) != 0 and segment_failed == 0:
        segment_failed = 1
    failed += segment_failed

print(max(0, ran - failed - skipped), failed)
PY
)"
read -r passed failed <<<"$counts"
printf 'web python: %s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
