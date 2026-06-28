#!/usr/bin/env bash
#
# Tests for `lcars buddy` (skill source: skills/lcars-buddy/buddy.sh).
#
# `lcars buddy` is the GLOBAL, repo-agnostic "spin up an LCARS debugging buddy
# anywhere" skill. Invoked from ANY repo, its bundled buddy.sh prints a single
# diagnostic brief that (a) locates the LCARS checkout and reports its git state,
# (b) checks whether the INSTALLED skills actually point at that checkout (so the
# captain knows the code they edit is the code that runs), and (c) snapshots the
# CURRENT repo's LCARS mission state (the thing that is misbehaving). All logic
# lives in buddy.sh so it is exercised directly here, deps injected via env:
#   LCARS_REPO          the LCARS checkout to debug (default: resolved from the script)
#   GIT_BIN             git binary (stubbed here)
#   LCARS_BUDDY_CWD     the repo to inspect for active missions (default: $PWD)
#   LCARS_SKILLS_DEST   the installed-skills dir (default: ~/.claude/skills)
#
# Usage: bash tests/lcars-buddy.test.sh
set -uo pipefail

qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_BUDDY_SCRIPT:-$REPO_ROOT/skills/lcars-buddy/buddy.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- helpers --------------------------------------------------------------

# A directory that LOOKS like an LCARS checkout (the markers buddy.sh validates).
new_lcars_checkout() {
  local repo; repo="$(mktemp -d "$TMPROOT/lcars.XXXX")"
  : >"$repo/vision.md"
  : >"$repo/install.sh"
  : >"$repo/CONTEXT.md"
  : >"$repo/CLAUDE.md"
  mkdir -p "$repo/skills/lcars-run" "$repo/skills/lcars-buddy"
  echo "$repo"
}

# A plain directory that is NOT an LCARS checkout.
new_plain_dir() { mktemp -d "$TMPROOT/plain.XXXX"; }

# A git repo with an LCARS mission at a given stage (+ optional awaiting flag).
# new_repo_with_mission <id> <stage> [awaiting]
new_repo_with_mission() {
  local id="$1" stage="$2" awaiting="${3:-false}"
  local repo; repo="$(mktemp -d "$TMPROOT/work.XXXX")"
  local dir="$repo/.git/lcars/missions/$id"
  mkdir -p "$dir"
  cat >"$repo/.git/lcars/config.json" <<JSON
{
  "testCommand": "npx vitest run \${LCARS_TESTS_DIR:-}",
  "worktreeSetupCommand": "ln -snf ../node_modules node_modules",
  "model": "sonnet"
}
JSON
  cat >"$dir/state.json" <<JSON
{
  "id": "$id",
  "title": "a misbehaving mission",
  "stage": "$stage",
  "created": "2026-06-27T10:00:00Z",
  "githubIssue": 42,
  "workerBin": "copilot",
  "awaitingHuman": $awaiting
}
JSON
  printf '%s\n' \
    '{"ts":"2026-06-27T10:00:00Z","type":"stage_enter","detail":"research"}' \
    '{"ts":"2026-06-27T10:01:00Z","type":"worker_error","detail":"vitest: not found"}' \
    >"$dir/events.jsonl"
  echo "$repo"
}

# A stub git that answers the queries buddy.sh makes (branch / HEAD / status / log).
make_git_stub() {
  local stub="$TMPROOT/git-stub-$$-$RANDOM"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"rev-parse --abbrev-ref"*) echo "feat/some-branch" ;;
  *"rev-parse HEAD"*)         echo "abc1234deadbeef" ;;
  *"status --short"*)         echo " M skills/lcars-run/run.sh" ;;
  *log*)                      echo "abc1234 fix(run): a recent commit" ;;
  *)                          : ;;
esac
exit 0
EOF
  chmod +x "$stub"
  echo "$stub"
}

GIT_STUB="$(make_git_stub)"
LCARS="$(new_lcars_checkout)"

# --- 1. locates and reports the LCARS checkout ----------------------------
out1="$TMPROOT/out1.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$out1" 2>&1
check "1. reports the LCARS checkout path" \
  "qgrep -q '$LCARS' '$out1'"
check "1. reports the LCARS git branch via GIT_BIN" \
  "qgrep -q 'feat/some-branch' '$out1'"

# --- 2. errors when LCARS_REPO is not an LCARS checkout --------------------
plain="$(new_plain_dir)"
err2="$TMPROOT/err2.txt"
LCARS_REPO="$plain" GIT_BIN="$GIT_STUB" bash "$SCRIPT" >/dev/null 2>"$err2"
rc2=$?
check "2. exits non-zero when LCARS_REPO is not an LCARS checkout" "[ $rc2 -ne 0 ]"
check "2. the error names the missing LCARS checkout" \
  "qgrep -qiE 'lcars|checkout|vision' '$err2'"

# --- 3. snapshots the current repo's mission + stage ----------------------
work="$(new_repo_with_mission lcars-20260627-001 research)"
out3="$TMPROOT/out3.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$work" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$out3" 2>&1
check "3. lists the active mission id" \
  "qgrep -q 'lcars-20260627-001' '$out3'"
check "3. shows the mission stage" \
  "qgrep -q 'research' '$out3'"
check "3. surfaces recent mission events (the failing breadcrumb)" \
  "qgrep -q 'vitest: not found' '$out3'"
check "3. surfaces the current repo's worktreeSetupCommand/testCommand config" \
  "qgrep -qi 'testCommand' '$out3'"

# --- 4. flags an awaiting-human mission -----------------------------------
work4="$(new_repo_with_mission lcars-20260627-002 implement true)"
out4="$TMPROOT/out4.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$work4" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$out4" 2>&1
check "4. flags an awaiting-human mission" \
  "qgrep -qi 'awaiting' '$out4'"

# --- 5. graceful when the current repo is not LCARS-initialized ------------
out5="$TMPROOT/out5.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$out5" 2>&1
rc5=$?
check "5. exits 0 even when the current repo has no LCARS missions" "[ $rc5 -eq 0 ]"
check "5. says the current repo is not LCARS-initialized (not an error)" \
  "qgrep -qiE 'no .*mission|not .*initial' '$out5'"

# --- 6. install staleness check (the code-you-edit-is-the-code-that-runs) --
# 6a. dest symlink points at THIS checkout -> in sync
dest_sync="$(new_plain_dir)"
ln -snf "$LCARS/skills/lcars-run" "$dest_sync/lcars-run"
out6a="$TMPROOT/out6a.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_sync" bash "$SCRIPT" >"$out6a" 2>&1
check "6a. reports installed skills are IN SYNC with this checkout" \
  "qgrep -qiE 'in sync|up to date|points at' '$out6a'"

# 6b. dest symlink points at a DIFFERENT checkout -> warn + name install.sh
other="$(new_lcars_checkout)"
dest_stale="$(new_plain_dir)"
ln -snf "$other/skills/lcars-run" "$dest_stale/lcars-run"
out6b="$TMPROOT/out6b.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_stale" bash "$SCRIPT" >"$out6b" 2>&1
check "6b. WARNS when installed skills do not point at this checkout" \
  "qgrep -qiE 'stale|do not point|install\.sh' '$out6b'"

# --- 7. points the buddy at the key source docs ---------------------------
check "7. points the buddy at vision.md and CLAUDE.md" \
  "qgrep -q 'vision.md' '$out1' && qgrep -q 'CLAUDE.md' '$out1'"

# --- summary --------------------------------------------------------------
printf '\nlcars buddy: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
