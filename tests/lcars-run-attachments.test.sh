#!/usr/bin/env bash
#
# Focused test for `attachments_extra_block` (skill source: skills/lcars-run/run.sh).
#
# S92: a mission's durable image attachments (staged under
# $MISSION_DIR/attachments/) must be threaded into the cold Stage workers as a
# block of ABSOLUTE paths so Research/Validate/Plan/Implement can READ them by
# path. This exercises the block in ISOLATION via run.sh's `attachments-block-test`
# hook (MISSION_DIR is taken from $LCARS_ATT_TEST_DIR — no locate_mission, no
# worker spawn, zero tokens):
#   1. dir with files  -> block carries the header + each ABSOLUTE path
#   2. dir absent/empty -> block is EMPTY (no-attachment missions byte-identical)
#
# Usage: bash tests/lcars-run-attachments.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "attachments_extra_block"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

block_for() { # mission-dir
  LCARS_ATT_TEST_DIR="$1" bash "$SCRIPT" attachments-block-test 2>/dev/null
}

# 1. a mission dir WITH attachments → block carries the header + each abs path.
M1="$TMPROOT/m1"; mkdir -p "$M1/attachments"
printf 'AAA' >"$M1/attachments/attachment-01.png"
printf 'BBB' >"$M1/attachments/attachment-02.jpg"
out1="$(block_for "$M1")"
check "1. emits the Attached images header" \
  "printf '%s' \"\$out1\" | grep -q 'Attached images'"
check "1. emits the FIRST attachment's ABSOLUTE path" \
  "printf '%s' \"\$out1\" | grep -qF '$M1/attachments/attachment-01.png'"
check "1. emits the SECOND attachment's ABSOLUTE path" \
  "printf '%s' \"\$out1\" | grep -qF '$M1/attachments/attachment-02.jpg'"

# 2. a mission dir with NO attachments/ dir → empty block.
M2="$TMPROOT/m2"; mkdir -p "$M2"
out2="$(block_for "$M2")"
check "2. absent attachments dir ⇒ empty block" "[ -z \"\$out2\" ]"

# 3. an EMPTY attachments/ dir → empty block (no stray header).
M3="$TMPROOT/m3"; mkdir -p "$M3/attachments"
out3="$(block_for "$M3")"
check "3. empty attachments dir ⇒ empty block" "[ -z \"\$out3\" ]"

# ==========================================================================
echo
printf 'attachments_extra_block: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
