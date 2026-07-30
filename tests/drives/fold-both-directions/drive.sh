#!/usr/bin/env bash
# ============================================================================
# COPILOT STAND-IN-CAPTAIN PROOF DRIVE
#
# Proves BOTH directions of the Mission-Log fold at once, on a real drive:
#   (A) a logged bug's fix ACTUALLY reaches main when the parent merges
#   (B) the logged bug's CARD actually reaches done
# The 2026-07-28 incident was (A) failing while (B) passed (green board, no code).
# Today's incident was (B) failing while (A) passed (code merged, cards stranded).
#
# Everything here is real except the forge: real copilot workers driving Research →
# … → Implement with real TDD and real commits, the real fold, the real approve.
# `origin` is a local bare repo and the host adapter is a local stub whose
# `pr-merge` performs a genuine fast-forward of origin/main to the mission branch —
# so "did the code make it?" is answered by reading origin/main, not by a mock.
#
# copilot plays the CAPTAIN twice, non-interactively: once to author the feature
# PRD, once to author a bug report against the delivered code.
# ============================================================================
set -uo pipefail

LCARS="${LCARS_REPO:-$HOME/Projects/LCARS}"
ROOT="${DRIVE_ROOT:?DRIVE_ROOT not set}"
export DRIVE_STATE="$ROOT/state"
export DRIVE_ORIGIN="$ROOT/origin.git"
export DRIVE_REPO="$ROOT/repo"
STUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$DRIVE_STATE"
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }

# --- a no-op gh (fold_one_child + init call gh directly) --------------------
cat >"$ROOT/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$DRIVE_STATE/gh.log"
case "${1:-}" in
  issue) case "${2:-}" in create) echo "https://example.invalid/acme/repo/issues/1";; esac ;;
esac
exit 0
EOF
chmod +x "$ROOT/gh"

export LCARS_GH_BIN="$ROOT/gh"
export LCARS_HOST_ADAPTER="$STUB_DIR/host-stub.sh"
export LCARS_WORKER_BIN=copilot
export LCARS_NOTIFY_NO_DESKTOP=1

# ============================================================================
say "1. throwaway repo + local origin"
git init -q --bare "$DRIVE_ORIGIN"
mkdir -p "$DRIVE_REPO"
cd "$DRIVE_REPO"
git init -q -b main
git config user.email drive@test
git config user.name "Proof Drive"
git remote add origin "$DRIVE_ORIGIN"

# A dead-simple, hermetic Python project: stdlib unittest, no install step, so a
# per-ticket worktree needs no setup command and the flip-flop gate is fast.
mkdir -p src tests
cat >src/tally.py <<'EOF'
"""A tiny tally helper."""


def total(items):
    """Sum an iterable of numbers."""
    return sum(items)
EOF
cat >tests/test_tally.py <<'EOF'
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from tally import total


class TotalTest(unittest.TestCase):
    def test_sums(self):
        self.assertEqual(total([1, 2, 3]), 6)

    def test_empty(self):
        self.assertEqual(total([]), 0)
EOF
cat >README.md <<'EOF'
# tally

A tiny Python tally library. Tests: `python3 -m unittest discover -s tests`.
EOF
git add -A && git commit -q -m "init: tally library + tests"
git push -q origin main
note "repo at $DRIVE_REPO, origin at $DRIVE_ORIGIN"

# --- LCARS config (hermetic test command, no worktree setup) ----------------
mkdir -p .git/lcars/missions
# lcarsVersion MUST be stamped: without it the version check treats the repo as
# pre-versioning and blocks on an interactive "RUN lcars update? [y/N]" prompt.
LV="$(cat "$LCARS/VERSION")"
cat >.git/lcars/config.json <<EOF
{
  "model": "claude-sonnet",
  "projectName": "tally",
  "contextFile": null,
  "stack": "python",
  "testCommand": "python3 -m unittest discover -s tests -t .",
  "worktreeSetupCommand": "",
  "comprehensionBudget": 400,
  "lcarsVersion": "$LV",
  "created": "2026-07-29T00:00:00Z"
}
EOF
note "testCommand: python3 -m unittest discover -s tests -t . (stamped $LV)"

# ============================================================================
say "2. copilot as CAPTAIN — author the feature PRD"
CAPTAIN_PRD="$ROOT/captain-prd.md"
copilot -p "You are the CAPTAIN of a software project, writing a work order.

The repo is a tiny Python library at src/tally.py with one function total(items)
that sums an iterable. Tests live in tests/ and run with
\`python3 -m unittest discover -s tests -t .\`.

Write a PRD for ONE SMALL feature: add a function \`average(items)\` to
src/tally.py that returns the arithmetic mean, returning 0.0 for an empty input.
Keep it genuinely small — one or two tickets of work at most.

Output ONLY the PRD markdown, no preamble and no code fences. Use exactly this
shape:

# Mission: <title>

**Type:** feature
**Goal:** <one sentence>

**Acceptance Criteria:**
- <criterion>
- <criterion>

**Out of Scope:**
- <item>

**Constraints:**
- Python 3 standard library only; no new dependencies.
- The existing test suite must stay green.
" --available-tools= --no-ask-user --disable-builtin-mcps \
  --no-custom-instructions --model claude-sonnet-4.5 >"$CAPTAIN_PRD" 2>"$DRIVE_STATE/captain1.err"
note "PRD authored: $(wc -l <"$CAPTAIN_PRD") lines"
head -3 "$CAPTAIN_PRD" | sed 's/^/     /'
grep -q '^# Mission:' "$CAPTAIN_PRD" || { echo "FATAL: captain PRD has no '# Mission:' line"; exit 1; }

# ============================================================================
say "3. lcars file — open the mission"
bash "$LCARS/skills/lcars-file/file.sh" </dev/null --prd "$CAPTAIN_PRD" --engine copilot \
  2>&1 | tee "$DRIVE_STATE/file.out" | sed 's/^/   /'
MID="$(ls -1 .git/lcars/missions | head -1)"
[ -n "$MID" ] || { echo "FATAL: no mission filed"; exit 1; }
note "mission: $MID"

# ============================================================================
say "4. lcars run — drive the mission to Verify (real workers)"
bash "$LCARS/skills/lcars-run/run.sh" </dev/null drive --mission "$MID" \
  >"$DRIVE_STATE/run-parent.out" 2>&1
note "run rc=$? — tail:"
tail -12 "$DRIVE_STATE/run-parent.out" | sed 's/^/     /'
PSTAGE="$(python3 -c "import json;print(json.load(open('.git/lcars/missions/$MID/state.json')).get('stage'))")"
PPR="$(python3 -c "import json;print(json.load(open('.git/lcars/missions/$MID/state.json')).get('prUrl'))")"
note "parent stage=$PSTAGE prUrl=$PPR"
[ "$PSTAGE" = "verify" ] || { echo "FATAL: parent did not reach verify (stage=$PSTAGE)"; exit 1; }

# ============================================================================
say "5. copilot as CAPTAIN — log a bug against the delivered code"
git --no-pager log --oneline "lcars/$MID" -5 | sed 's/^/     /'
CAPTAIN_BUG="$ROOT/captain-bug.md"
copilot -p "You are the CAPTAIN reviewing a just-delivered change, filing a bug.

The library src/tally.py now has average(items). You want ONE more small,
concrete, testable behaviour change filed as a BUG: average() should raise a
TypeError with a clear message when handed a non-iterable (for example a single
int), instead of failing with an unclear built-in error.

Output ONLY the bug PRD markdown, no preamble and no code fences, in exactly
this shape:

# Mission: <short bug title>

**Type:** bug
**Goal:** <one sentence>

**Acceptance Criteria:**
- <criterion>

**Out of Scope:**
- <item>

**Constraints:**
- Python 3 standard library only.
- The existing test suite must stay green.
" --available-tools= --no-ask-user --disable-builtin-mcps \
  --no-custom-instructions --model claude-sonnet-4.5 >"$CAPTAIN_BUG" 2>"$DRIVE_STATE/captain2.err"
note "bug PRD authored: $(wc -l <"$CAPTAIN_BUG") lines"
head -3 "$CAPTAIN_BUG" | sed 's/^/     /'
grep -q '^# Mission:' "$CAPTAIN_BUG" || { echo "FATAL: captain bug PRD has no '# Mission:' line"; exit 1; }

say "6. lcars log — file the bug against the parent"
bash "$LCARS/skills/lcars-log/log.sh" </dev/null --parent "$MID" --prd "$CAPTAIN_BUG" \
  2>&1 | tee "$DRIVE_STATE/log.out" | sed 's/^/   /'
BID="$(ls -1 .git/lcars/missions | grep -v "^$MID$" | head -1)"
[ -n "$BID" ] || { echo "FATAL: no bug mission filed"; exit 1; }
note "bug mission: $BID"

# ============================================================================
say "7. lcars resolve-logs — drive the bug and fold it onto the parent branch"
bash "$LCARS/skills/lcars-resolve-logs/resolve-logs.sh" </dev/null "$MID" \
  >"$DRIVE_STATE/resolve.out" 2>&1
note "resolve-logs rc=$? — tail:"
tail -10 "$DRIVE_STATE/resolve.out" | sed 's/^/     /'
BSTAGE="$(python3 -c "import json;print(json.load(open('.git/lcars/missions/$BID/state.json')).get('stage'))")"
note "bug stage after resolve: $BSTAGE"

# ============================================================================
say "8. lcars approve — merge the parent (THE FIX UNDER TEST)"
bash "$LCARS/skills/lcars-approve/approve.sh" </dev/null --mission "$MID" \
  >"$DRIVE_STATE/approve.out" 2>"$DRIVE_STATE/approve.err"
note "approve rc=$?"
cat "$DRIVE_STATE/approve.out" | sed 's/^/     /'
[ -s "$DRIVE_STATE/approve.err" ] && { note "stderr:"; sed 's/^/     /' "$DRIVE_STATE/approve.err"; }

# ============================================================================
say "9. VERDICT"
fails=0
v() { # v <label> <condition-desc> <0|1 result>
  if [ "$3" -eq 0 ]; then printf '   \033[32mPASS\033[0m %s\n' "$1"
  else printf '   \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails+1)); fi
}

# (A) THE CODE: is the bug's fix commit on origin/main?
git -C "$DRIVE_REPO" fetch -q origin main 2>/dev/null
MAIN_SUBJECTS="$(git -C "$DRIVE_REPO" log --format=%s FETCH_HEAD 2>/dev/null)"
echo "$MAIN_SUBJECTS" | grep -qF "lcars($BID)"; v "(A) the logged bug's fix commit is on origin/main" "" $?
echo "$MAIN_SUBJECTS" | grep -qF "lcars($MID)"; v "(A) the parent mission's commits are on origin/main" "" $?

# the feature AND the bug fix are really in the merged tree
git -C "$DRIVE_REPO" show FETCH_HEAD:src/tally.py >"$DRIVE_STATE/merged-tally.py" 2>/dev/null
grep -q "def average" "$DRIVE_STATE/merged-tally.py"; v "(A) average() is in the merged src/tally.py" "" $?

# (B) THE CARDS: parent done, bug child done
PS="$(python3 -c "import json;print(json.load(open('$DRIVE_REPO/.git/lcars/missions/$MID/state.json')).get('stage'))")"
BS="$(python3 -c "import json;print(json.load(open('$DRIVE_REPO/.git/lcars/missions/$BID/state.json')).get('stage'))")"
[ "$PS" = "done" ]; v "(B) parent mission card reads done (is: $PS)" "" $?
[ "$BS" = "done" ]; v "(B) logged bug card reads done (is: $BS)" "" $?

# the fold was reported, not silent
grep -q "Folded logged bug: $BID" "$DRIVE_STATE/approve.out"; v "approve reported the fold" "" $?

echo
echo "--- subjects on merged main ---"
echo "$MAIN_SUBJECTS" | sed 's/^/     /'
echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mDRIVE PASSED — both directions hold.\033[0m\n'
else
  printf '\033[31mDRIVE FAILED — %d check(s) red.\033[0m\n' "$fails"
fi
echo "artifacts: $DRIVE_STATE"
exit "$fails"
