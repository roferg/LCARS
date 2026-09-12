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

# --- 3b. a config/state value carrying ESCAPED QUOTES renders IN FULL ------
# buddy's json_str claimed to "mirror status.sh" but had drifted to the old
# naive sed reader whose value class is [^"]* — it stops at the FIRST escaped
# quote. That is not an exotic input: S148 makes every testCommand LCARS itself
# seeds QUOTE its $LCARS_TESTS_DIR scope, so a correctly-configured repo always
# stores \" in config.json. The brief then printed a TRUNCATED command — the
# exact value a captain runs buddy to verify — reading as if the config were
# mangled when it was fine. Same class for a mission title containing a quote.
# Expected values live in files so `check`'s eval never re-expands the $ and "
# they are made of.
work3b="$(mktemp -d "$TMPROOT/work3b.XXXX")"
mkdir -p "$work3b/.git/lcars/missions/lcars-20260627-003"
cat >"$work3b/.git/lcars/config.json" <<'JSON'
{
  "testCommand": "npx vitest run ${LCARS_TESTS_DIR:+\"${LCARS_TESTS_DIR#\"$PWD/\"}\"}",
  "worktreeSetupCommand": "if [ -d \"$MAIN/node_modules\" ]; then ln -snf \"$MAIN/node_modules\" node_modules; else npm ci; fi",
  "model": "sonnet"
}
JSON
cat >"$work3b/.git/lcars/missions/lcars-20260627-003/state.json" <<'JSON'
{
  "id": "lcars-20260627-003",
  "title": "a mission that says \"hello\" mid-sentence",
  "stage": "implement",
  "created": "2026-06-27T10:00:00Z",
  "githubIssue": 7,
  "awaitingHuman": false
}
JSON
printf '%s\n' 'npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}' >"$TMPROOT/exp-tc.txt"
printf '%s\n' 'if [ -d "$MAIN/node_modules" ]; then ln -snf "$MAIN/node_modules" node_modules; else npm ci; fi' >"$TMPROOT/exp-ws.txt"
printf '%s\n' 'a mission that says "hello" mid-sentence' >"$TMPROOT/exp-title.txt"
out3b="$TMPROOT/out3b.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$work3b" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$out3b" 2>&1
check "3b. renders a QUOTED testCommand in full (not cut at the first escaped quote)" \
  "grep -qFf '$TMPROOT/exp-tc.txt' '$out3b'"
check "3b. renders a QUOTED worktreeSetupCommand in full" \
  "grep -qFf '$TMPROOT/exp-ws.txt' '$out3b'"
check "3b. renders a mission title containing quotes in full" \
  "grep -qFf '$TMPROOT/exp-title.txt' '$out3b'"

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

# --- 8. ORCHESTRATION.md — the ONE shared orchestration rules file --------
# S197: run-session (lcars-dev), night-watch (lcars-dev) and `lcars buddy` all
# follow the SAME orchestration loop — implementor (TDD) → fresh tester → fix
# rounds → teardown → commit → readout. Until now each of the three RESTATED it,
# which is exactly how three copies drift apart (and buddy's copy had already
# lost the tester, the round counter and the regression guard). The rules MOVED
# into this file; every consumer points at
# `~/.claude/skills/lcars-buddy/ORCHESTRATION.md` — a stable path from any cwd,
# reached through the install symlink, so no installer changes.
ORCH="$REPO_ROOT/skills/lcars-buddy/ORCHESTRATION.md"
check "8. skills/lcars-buddy/ORCHESTRATION.md exists" "[ -f '$ORCH' ]"

cat >"$TMPROOT/exp-headings.txt" <<'EOF'
## Who reads this
## Pre-flight
## The loop
## The tester opens the real product first
## Every fix proves it didn't break the last
## Three fix rounds, then STOP
## Inherited defects are ledgered
## Inherit the rig
## Narrow briefs after round 1
## Time-box and verify claims
## Build contract
## Readout
## Guardrails
EOF
grep '^## ' "$ORCH" 2>/dev/null >"$TMPROOT/got-headings.txt"
check "8. carries every required H2 heading, in order" \
  "diff -q '$TMPROOT/exp-headings.txt' '$TMPROOT/got-headings.txt' >/dev/null"
# A rule without its reason gets undone — the post-mortem examples are load-bearing.
check "8. keeps the post-mortem examples that justify the rules (S156/S163/S188)" \
  "grep -q 'S156' '$ORCH' && grep -q 'S163' '$ORCH' && grep -q 'S188' '$ORCH'"

# --- 8b. the two rules the 2026-09-11 night earned ------------------------
# Both were paid for in lost session time and both go in EXISTING sections (the
# heading list above is pinned, so a new rule may never grow a new H2).
#   (a) a spot-check without a known-good control cannot detect its own
#       breakage — an orchestrator's own probe loop produced a false green while
#       verifying a HIGH hang-fix.
#   (b) `perl -e 'alarm N; exec @ARGV'` does not reliably kill a blocked probe;
#       only a process-group cage does. The reference implementation is
#       committed under tests/drives/ (see § Inherit the rig).
check "8b. § Time-box requires a known-good control in every spot-check" \
  "grep -qi 'known-good control' '$ORCH'"
check "8b. and tells the story that justifies it (the joined-argument false green)" \
  "grep -qi 'word-split' '$ORCH' && grep -qi 'literal' '$ORCH'"
check "8b. rules out the perl alarm cage and names the process-group cure" \
  "grep -qF \"perl -e 'alarm\" '$ORCH' && grep -qF 'killpg' '$ORCH' && grep -qF 'start_new_session' '$ORCH'"
check "8b. says a caged run that never returns is not proof of safety" \
  "grep -qi 'not proof of safety' '$ORCH'"
# The build contract's install step must not contradict the isolated-install rule
# the consuming skills now point at — one file saying "run ./install.sh" while
# another says "never bare" is the drift this file exists to end.
check "8b. the build contract's install step is the ISOLATED one" \
  "grep -qF 'LCARS_INSTALL_PREFIX' '$ORCH'"
CAGE="$REPO_ROOT/tests/drives/s197/cage.py"
check "8b. the rule points at a cage that is actually committed" \
  "grep -qF 'tests/drives/s197/cage.py' '$ORCH' && [ -f '$CAGE' ]"
# The cage must really cage: a probe that blocks forever comes back killed, and
# a probe that exits comes back with its exit code — both reporting ELAPSED.
cagehang="$TMPROOT/cage-hang.txt"
python3 "$CAGE" 2 bash -c 'sleep 60' >"$cagehang" 2>&1
check "8b. the committed cage KILLS a blocked probe and reports it hung" \
  "qgrep -qi 'timed out' '$cagehang' && qgrep -q 'ELAPSED' '$cagehang'"
cagefast="$TMPROOT/cage-fast.txt"
python3 "$CAGE" 5 bash -c 'echo alive; exit 64' >"$cagefast" 2>&1
check "8b. and passes a fast probe's own exit code and output straight through" \
  "qgrep -q 'EXIT 64' '$cagefast' && qgrep -q 'alive' '$cagefast'"

# --- 9. SKILL.md points at the rules file instead of restating them -------
SKILL_MD="$REPO_ROOT/skills/lcars-buddy/SKILL.md"
check "9. SKILL.md references the rules file by its INSTALL path" \
  "grep -qF '~/.claude/skills/lcars-buddy/ORCHESTRATION.md' '$SKILL_MD'"
check "9. SKILL.md no longer restates the moved rule sentences" \
  "! grep -qE 'TDD.*: write the failing|Commit only when asked' '$SKILL_MD'"
check "9. SKILL.md's fix half is an ORCHESTRATOR (brief, fix/<slug>, tester, readout)" \
  "grep -qF 'fix/<slug>' '$SKILL_MD' && grep -qi 'implementor' '$SKILL_MD' && grep -qi 'tester' '$SKILL_MD'"
check "9. SKILL.md carries the clean-and-on-main refusal" \
  "grep -qF 'will not stack a fix onto it' '$SKILL_MD'"

# --- 10. the brief stops carrying a SECOND copy of the rules --------------
# buddy.sh used to print its own five-rule block — the same five rules SKILL.md
# stated, i.e. a drift surface inside one skill. One pointer line replaces it.
check "10. the brief no longer prints the duplicated BUDDY RULES block" \
  "! grep -qiE 'BUDDY RULES|TDD: failing test first' '$out1'"
check "10. the brief prints exactly ONE pointer line naming ORCHESTRATION.md" \
  "[ \"\$(grep -c 'ORCHESTRATION.md' '$out1')\" = 1 ]"

# --- 11. INSTALL SYNC is case-TOLERANT (the S197 bug) --------------------
# buddy.sh compared the install symlink target against $REPO with a
# case-SENSITIVE `case` glob. APFS is case-insensitive but `pwd -P` preserves
# the case you TYPED, so `LCARS_REPO=~/Projects/lcars` (or a buddy invoked
# through a lowercase path) reported a perfectly in-sync install as STALE — the
# one check a captain runs buddy in order to trust.
caseroot="$(mktemp -d "$TMPROOT/case.XXXX")"
case_upper="$caseroot/Fake-LCARS"
mkdir -p "$case_upper/skills/lcars-run" "$case_upper/skills/lcars-buddy"
: >"$case_upper/vision.md"; : >"$case_upper/install.sh"
case_lower="$caseroot/fake-lcars"
# On a case-INSENSITIVE FS the lowercase spelling already resolves to the same
# dir; on a case-SENSITIVE one, make it a second spelling of the same dir.
[ -d "$case_lower" ] || ln -snf "$case_upper" "$case_lower"
dest_case="$(new_plain_dir)"
ln -snf "$case_upper/skills/lcars-run" "$dest_case/lcars-run"
out11="$TMPROOT/out11.txt"
LCARS_REPO="$case_lower" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_case" bash "$SCRIPT" >"$out11" 2>&1
check "11. IN SYNC when the symlink target and LCARS_REPO differ only by CASE" \
  "grep -qi 'in sync' '$out11'"
check "11. and does NOT cry STALE on that case-different path" \
  "! grep -qi 'stale' '$out11'"

# --- 12. default repo resolution through the install symlink -------------
# Every case above passes LCARS_REPO explicitly, so the `pwd -P` default path
# (buddy.sh's normal production path — invoked as
# ~/.claude/skills/lcars-buddy/buddy.sh) was never exercised.
defroot="$(mktemp -d "$TMPROOT/def.XXXX")"
defrepo="$defroot/LCARS"
mkdir -p "$defrepo/skills/lcars-run" "$defrepo/skills/lcars-buddy"
: >"$defrepo/vision.md"; : >"$defrepo/install.sh"
cp "$SCRIPT" "$defrepo/skills/lcars-buddy/buddy.sh"
dest_def="$(new_plain_dir)"
ln -snf "$defrepo/skills/lcars-buddy" "$dest_def/lcars-buddy"
ln -snf "$defrepo/skills/lcars-run" "$dest_def/lcars-run"
defphys="$(cd "$defrepo" && pwd -P)"
out12="$TMPROOT/out12.txt"
( unset LCARS_REPO
  GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
    LCARS_SKILLS_DEST="$dest_def" bash "$dest_def/lcars-buddy/buddy.sh" ) >"$out12" 2>&1
check "12. with NO LCARS_REPO, resolves the PHYSICAL checkout behind the symlink" \
  "grep -qF 'LCARS REPO: $defphys' '$out12'"
check "12. and that default resolution reads as IN SYNC" \
  "grep -qi 'in sync' '$out12'"

# --- 13. the build contract is complete in its own file ------------------
CONTRACT="$REPO_ROOT/CLAUDE.md"
check "13. CLAUDE.md points at the shared orchestration rules file" \
  "grep -qF 'skills/lcars-buddy/ORCHESTRATION.md' '$CONTRACT'"
check "13. CLAUDE.md scopes the FULL suite to ship-it, fixes/sessions to the scoped suite" \
  "grep -qF 'ship-it' '$CONTRACT' && grep -qiE 'scoped' '$CONTRACT'"
check "13. CLAUDE.md states the branch-naming convention and the commit trailer" \
  "grep -qF 'fix/<slug>' '$CONTRACT' && grep -qF 'Co-Authored-By' '$CONTRACT'"

# --- 14. INSTALL SYNC judges ALL installed skills, not one symlink -------
# buddy.sh resolved install sync by reading the `lcars-run` symlink ALONE, so a
# PARTIAL install — lcars-run linked to this checkout while the other skills
# still point somewhere else — reported a confident, wrong "in sync". That is
# the one line a captain runs buddy in order to trust before editing code, and a
# partial install is exactly what a half-finished `./install.sh`, a renamed
# checkout, or an isolated-dest experiment leaves behind.
other14="$(new_lcars_checkout)"
mkdir -p "$other14/skills/lcars-answer" "$LCARS/skills/lcars-answer"
dest_partial="$(new_plain_dir)"
ln -snf "$LCARS/skills/lcars-run"      "$dest_partial/lcars-run"      # THIS checkout
ln -snf "$LCARS/skills/lcars-buddy"    "$dest_partial/lcars-buddy"    # THIS checkout
ln -snf "$other14/skills/lcars-answer" "$dest_partial/lcars-answer"   # somewhere ELSE
out14="$TMPROOT/out14.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_partial" bash "$SCRIPT" >"$out14" 2>&1
check "14. a PARTIAL install does NOT report in sync" \
  "! grep -qi 'in sync' '$out14'"
check "14. it says the installed skills DISAGREE / the install is partial" \
  "grep -qiE 'disagree|partial' '$out14'"
check "14. it NAMES a disagreeing skill so the captain knows where to look" \
  "grep -q 'lcars-answer' '$out14'"
check "14. and still tells them to run install.sh" \
  "grep -qF 'install.sh' '$out14'"

# 14b. unanimity is still IN SYNC — several skills, all pointing here.
dest_all="$(new_plain_dir)"
ln -snf "$LCARS/skills/lcars-run"    "$dest_all/lcars-run"
ln -snf "$LCARS/skills/lcars-buddy"  "$dest_all/lcars-buddy"
ln -snf "$LCARS/skills/lcars-answer" "$dest_all/lcars-answer"
out14b="$TMPROOT/out14b.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_all" bash "$SCRIPT" >"$out14b" 2>&1
check "14b. every skill agreeing reads IN SYNC" "grep -qi 'in sync' '$out14b'"
check "14b. and says HOW MANY skills it checked (so 'in sync' is falsifiable)" \
  "grep -qE 'in sync.*3|3 .*(skill|checked)' '$out14b'"
check "14b. no false disagreement when they all agree" \
  "! grep -qiE 'disagree|partial|stale' '$out14b'"

# 14c. ALL of them pointing elsewhere is still plain STALE (6b's verdict, which
# must not be softened into "partial" — a wholly stale install is not partial).
dest_allstale="$(new_plain_dir)"
ln -snf "$other14/skills/lcars-run"    "$dest_allstale/lcars-run"
ln -snf "$other14/skills/lcars-answer" "$dest_allstale/lcars-answer"
out14c="$TMPROOT/out14c.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_allstale" bash "$SCRIPT" >"$out14c" 2>&1
check "14c. a wholly different checkout still reads STALE, not partial" \
  "grep -qi 'stale' '$out14c' && ! grep -qi 'in sync' '$out14c'"

# --- summary --------------------------------------------------------------
printf '\nlcars buddy: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
