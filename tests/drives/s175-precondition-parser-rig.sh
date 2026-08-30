#!/usr/bin/env bash
# Attack rig: feed a concept doc, print the extracted preconditions + rc + stderr.
REPO_ROOT=/Users/roganferguson/Projects/LCARS
SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh"
R="$(mktemp -d)"; mkdir -p "$R/attachments"
printf '{ "id": "t", "stage": "validate" }\n' > "$R/state.json"
cat > "$R/attachments/attachment-02.md"
OUT="$(LCARS_ATT_TEST_DIR="$R" bash "$SCRIPT" preconditions-declared-test 2>"$R/err")"; RC=$?
echo "rc=$RC"
echo "--- stdout items ---"
if [ -n "$OUT" ]; then printf '%s\n' "$OUT" | nl -ba; else echo "(none)"; fi
echo "--- stderr ---"
cat "$R/err"
rm -rf "$R"
