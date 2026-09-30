#!/usr/bin/env bash
#
# S214 fix round 1, D2 — A FAILURE NAMES THE STAGE THAT FAILED, AND SAYS THE
# WHOLE SENTENCE.
#
# Measured verbatim on the captain's board:
#
#   ✖ align failed: ars-20260918-001-fea3' @ fd4e952 in an isolated worktree
#   (your checkout is untouched) lcars run: the question-generator worker
#   produced no questions.txt after 3 attempt(s) — Stage stopped, no advance.
#
# Two untruths in one line.
#
#   a. THE WRONG STAGE. The question-generator belongs to RESEARCH. A freshly
#      filed Mission SITS at `align` while Research runs — `$stage` is where it
#      sits, `$action` is what ran — and the driver's error arm used `$stage`
#      for both the event's own field and the word in the sentence. So the
#      card read "align failed", the board banded it ALIGN, and the captain
#      was told a Stage failed that had never started.
#
#   b. THE BEHEADED SENTENCE. The cause was the LAST 200 CHARACTERS of the
#      whole stage output. On any Mission that enters a worktree the banner
#      ("⌂ mission tree — … in an isolated worktree …") is printed ahead of
#      the reason, so the 200-character window opened INSIDE the branch name
#      and the captain's sentence began mid-word, on a dangling quote.
#
# The Stage's own reason for stopping is the line `die` writes. Take THAT,
# whole. It is a record, not a window onto one.
#
# Everything is stubbed — no network, no gh, no worker, no tokens. Only real
# local `git`.
#
# Usage: bash tests/stage-failure-name.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../skills/lcars-run/run.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/lcars-sfn.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0; fail=0
check() { # <name> <shell-expr>
  if eval "$2" >/dev/null 2>&1; then
    pass=$((pass+1)); printf '  ✓ %s\n' "$1"
  else
    fail=$((fail+1)); printf '  ✗ %s\n' "$1"
  fi
}

MID="lcars-20260918-001-fea3"

# A worker that answers, logs, and CREATES NOTHING — the measured copilot
# failure that produced no questions.txt.
make_silent_worker() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf 'role=%s\n' "${LCARS_WORKER_ROLE:-}" >>"$WORKER_LOG"
printf 'ok\n'
exit 0
EOF
  chmod +x "$1"
}

make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  *"issue view"*) printf '{"number":1,"title":"t","body":"b","labels":[]}\n' ;;
  *"issue create"*) printf 'https://github.com/o/r/issues/1\n' ;;
  *) printf '\n' ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# A repo with a real commit and a real mission BRANCH, so the Stage genuinely
# enters a worktree and prints the banner that did the beheading. Without the
# branch the defect does not reproduce.
new_repo_with_mission() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" \
      && git init -q -b main && git config user.email t@t && git config user.name t \
      && echo hello > README.md && git add README.md && git commit -qm init \
      && git branch "lcars/$MID" ) >/dev/null 2>&1
  local m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$repo/.git/lcars/config.json" <<'JSON'
{ "testCommand": "true", "contextSource": "none" }
JSON
  cat >"$m/prd.md" <<'EOF'
# Mission: Editor shell UI audit
**Type:** feature
**Goal:** Confirm the tile editor's existing left-rail panels paint on load.
**Acceptance Criteria:**
- The LAYERS list is present and legible on first paint
**Out of Scope:**
- Any new editor behaviour
**Constraints:**
- Do not change the existing shell
EOF
  cat >"$m/state.json" <<JSON
{
  "id": "$MID",
  "type": "feature",
  "title": "Editor shell UI audit",
  "stage": "align",
  "githubIssue": 1,
  "branch": "lcars/$MID",
  "base": "main"
}
JSON
  echo "$repo"
}

REPO="$(new_repo_with_mission)"
BIN="$REPO.bin"; mkdir -p "$BIN"
make_silent_worker "$BIN/worker"; make_gh_stub "$BIN/gh"
export WORKER_LOG="$BIN/worker.log"; : >"$WORKER_LOG"
export GH_LOG="$BIN/gh.log"; : >"$GH_LOG"

OUT="$BIN/drive.txt"
( cd "$REPO" && LCARS_WORKER_BIN="$BIN/worker" LCARS_GH_BIN="$BIN/gh" \
    LCARS_GIT_BIN="$(command -v git)" LCARS_WORKER_TRIES=1 LCARS_NOTIFY=true \
    bash "$SCRIPT" drive --mission "$MID" ) >"$OUT" 2>&1

EVENTS="$REPO/.git/lcars/missions/$MID/events.jsonl"

# The DEFECT'S OWN SHAPE first — if the Stage did not fail this way the rest of
# the suite is measuring nothing.
printf '\n  -- the failure reproduced --\n'
check "0a. an error event was recorded at all" \
  "grep -q '\"type\": *\"error\"' '$EVENTS'"
check "0b. …and it is the question-generator failure the captain saw" \
  "grep -q 'produced no questions.txt' '$EVENTS'"

ERRLINE="$(grep '"type": *"error"' "$EVENTS" | tail -1)"
DETAIL="$(printf '%s' "$ERRLINE" | sed -n 's/.*"detail":"\(.*\)"}.*/\1/p')"
# The captain's line, verbatim, so a failure here shows WHAT he would read
# rather than only that an assertion went red.
printf '\n  the captain would read: ✖ %s\n' "$DETAIL"

printf '\n  -- a. the stage that actually failed --\n'
check "1a. the event's own stage field says research, not align" \
  "printf '%s' \"\$ERRLINE\" | grep -q '\"stage\":\"research\"'"
check "1b. …and the sentence names research, not align" \
  "printf '%s' \"\$DETAIL\" | grep -q '^research failed'"
check "1c. the word 'align' appears nowhere in the failure the captain reads" \
  "! printf '%s' \"\$DETAIL\" | grep -q 'align'"

printf '\n  -- b. the whole sentence, not a window onto one --\n'
check "2a. the cause is the Stage's own reason, complete from its first word" \
  "printf '%s' \"\$DETAIL\" | grep -q 'research failed: the question-generator worker produced no questions.txt'"
check "2b. …and it runs to the end of that reason" \
  "printf '%s' \"\$DETAIL\" | grep -q 'Stage stopped, no advance'"
# The banner is what ate the 200-character budget. Its presence in the cause is
# the beheading's fingerprint: it can only be there if the cause is a blind
# tail of the whole output rather than the reason itself.
check "2c. the worktree banner is NOT carried as the cause" \
  "! printf '%s' \"\$DETAIL\" | grep -q 'isolated worktree'"
check "2d. no beheaded branch name, and no dangling quote, in the captain's line" \
  "! printf '%s' \"\$DETAIL\" | grep -q \"ars-20260918-001-fea3'\""
# House style: the captain is reading about HIS product, not about a script.
check "2e. no harness vocabulary ('lcars run:') is left in the sentence" \
  "! printf '%s' \"\$DETAIL\" | grep -q 'lcars run:'"

printf '\n  -- and the line printed to the terminal agrees with the board --\n'
check "3a. the terminal also names research, not align" \
  "grep -q '⏹ stopped: research failed' '$OUT'"

echo
printf 'stage failure name: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
