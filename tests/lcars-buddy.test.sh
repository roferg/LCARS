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

# qgrep reads stdin ONLY when no FILE operand was given. Draining stdin first
# is what keeps a piped `grep -q` from SIGPIPE-ing a still-writing producer and
# flipping a genuine match into a phantom failure under `set -o pipefail`. But
# draining when a FILE was passed reads INHERITED stdin: from a terminal that
# blocks forever, and with stdin closed it silently returns empty and the
# assertion passes by accident. So count the non-option operands ("--" ends the
# options; no call site uses -e/-f, which take an argument) and hand the file
# form straight to grep. Output and exit status match grep in both shapes.
qgrep() {
  local _qg_a _qg_in _qg_n=0 _qg_opt=1
  for _qg_a in "$@"; do
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" = "--" ]; then _qg_opt=0; continue; fi
    if [ "$_qg_opt" = 1 ] && [ "$_qg_a" != "${_qg_a#-}" ] && [ "$_qg_a" != "-" ]; then continue; fi
    _qg_n=$((_qg_n + 1))
  done
  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi
  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_BUDDY_SCRIPT:-$REPO_ROOT/skills/lcars-buddy/buddy.sh}"


pass=0
fail=0
TMPROOT="$(mktemp -d "${TMPDIR:-.}/lcars-buddy.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd)"
trap 'rm -rf "$TMPROOT"' EXIT
# S277 — FENCE THE SECOND FARM FOR THE WHOLE FILE. buddy.sh now reports Copilot's
# plugin mount as well as Claude's skill farm, and its default is
# $HOME/.copilot/installed-plugins/_direct — the captain's REAL one, which points
# at his real checkout and would make every fixture-based verdict below read
# "STALE" for a reason that has nothing to do with the case under test. The
# header of this file already promises the deps are injected "so tests use temp
# dirs only and NEVER touch the real home dirs"; these two exports make that true
# of the new farm as well. Cases that are ABOUT the Copilot farm override them.
export LCARS_COPILOT_PLUGINS_DIR="$TMPROOT/no-copilot-plugins"
export LCARS_COPILOT_BIN="$TMPROOT/definitely-no-copilot"

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

# Paired public CLI proof using real git, not the diagnostic git stub.
for paused_stage in done implement; do
  pause_work="$(new_plain_dir)"
  git -C "$pause_work" init -q
  pause_dir="$pause_work/.git/lcars/missions/pause-$paused_stage"
  mkdir -p "$pause_dir"
  printf '{"id":"pause-%s","stage":"%s","paused":true,"awaitingHuman":true}\n' \
    "$paused_stage" "$paused_stage" >"$pause_dir/state.json"
  cp "$pause_dir/state.json" "$pause_dir/state.before"
  pause_out="$TMPROOT/pause-$paused_stage.txt"
  LCARS_REPO="$REPO_ROOT" GIT_BIN=git LCARS_BUDDY_CWD="$pause_work" \
    LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$pause_out" 2>&1
  check "4-terminal $paused_stage. mission stage and awaiting input stay visible" \
    "grep -q 'MISSION pause-$paused_stage .*stage: $paused_stage.*⚠ awaiting-human' '$pause_out'"
  if [ "$paused_stage" = done ]; then
    check "4-terminal done. finished mission has no live pause marker" \
      "! grep -q 'MISSION pause-done .*⏸ paused' '$pause_out'"
  else
    check "4-terminal implement. nonterminal mission retains live pause marker" \
      "grep -q 'MISSION pause-implement .*⏸ paused' '$pause_out'"
  fi
  check "4-terminal $paused_stage. recorded pause state is unchanged" \
    "cmp -s '$pause_dir/state.before' '$pause_dir/state.json'"
done

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
# EVERY skill the fixture checkout ships is linked: this case is about DIRECTION,
# and since S197 round 1 "in sync" also requires COMPLETENESS (a dest holding one
# correctly-aimed link out of eighteen is not a synced install — see group 15).
dest_sync="$(new_plain_dir)"
ln -snf "$LCARS/skills/lcars-run"   "$dest_sync/lcars-run"
ln -snf "$LCARS/skills/lcars-buddy" "$dest_sync/lcars-buddy"
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
# S197 fix round: a FIFTH $HOME destination turned up (the version check's
# throttle stamp). A rules file that still says "FOUR destinations ... names all
# four" is a claim a future session will trust and act on, which is the whole
# reason this file exists, so it has to move with install.sh's header.
check "8b. the install step counts FIVE destinations, not four" \
  "grep -qiE 'writes to FIVE destinations|FIVE destinations' '$ORCH' && ! grep -qF 'writes to FOUR' '$ORCH'"
# And the hang rule must name BOTH mechanisms. BUG-089's bare `cat` was one; an
# unthrottled `git fetch` blocking on a credential/askpass prompt is a second,
# independent one, and a rule that names only the first sends the next orchestrator
# looking in the wrong place.
check "8b. the hang rule names the SECOND mechanism (the version check's fetch)" \
  "grep -qiE 'git fetch|version check' '$ORCH' && grep -qiE 'askpass|GIT_TERMINAL_PROMPT' '$ORCH'"
CAGE="$REPO_ROOT/tests/lib/cage.py"
check "8b. the rule points at a cage that is actually committed" \
  "grep -qF 'tests/lib/cage.py' '$ORCH' && [ -f '$CAGE' ]"
# The cage must really cage: a probe that blocks forever comes back killed, and
# a probe that exits comes back with its exit code — both reporting ELAPSED.
cagehang="$TMPROOT/cage-hang.txt"
python3 "$CAGE" 2 bash -c 'sleep 60' >"$cagehang" 2>&1
check "8b. the committed cage KILLS a blocked probe and reports the timeout" \
  "qgrep -qi 'timed out' '$cagehang' && qgrep -q 'ELAPSED' '$cagehang'"
cagefast="$TMPROOT/cage-fast.txt"
python3 "$CAGE" 5 bash -c 'echo alive; exit 64' >"$cagefast" 2>&1
check "8b. and passes a fast probe's own exit code and output straight through" \
  "qgrep -q 'EXIT 64' '$cagefast' && qgrep -q 'alive' '$cagefast'"

# --- 9. SKILL.md points at the rules file instead of restating them -------
SKILL_MD="$REPO_ROOT/skills/lcars-buddy/SKILL.md"
# S277 — THIS ASSERTION WAS CHANGED, DELIBERATELY. It used to read:
#   check "9. SKILL.md references the rules file by its INSTALL path" \
#     "grep -qF '~/.claude/skills/lcars-buddy/ORCHESTRATION.md' '$SKILL_MD'"
# i.e. it ENFORCED the one literal that breaks the skill under Copilot, whose
# install mount is ~/.copilot/installed-plugins/_direct/lcars/skills/lcars-buddy.
# The requirement behind it is unchanged — SKILL.md must POINT at the rules file
# rather than restate it — so what is asserted now is that it points at it in a
# form that resolves in BOTH mounts. Group 17 below holds the positive form of
# this contract; group 16 holds the prohibition.
check "9. SKILL.md references the rules file by a form that works in BOTH mounts" \
  "grep -qF 'ORCHESTRATION.md' '$SKILL_MD' && grep -qF 'lcars-buddy docs orchestration' '$SKILL_MD' && ! grep -qF '~/.claude/skills/lcars-buddy/ORCHESTRATION.md' '$SKILL_MD'"
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
# Both shipped skills linked — completeness is group 15's subject, not this one.
ln -snf "$case_upper/skills/lcars-run"   "$dest_case/lcars-run"
ln -snf "$case_upper/skills/lcars-buddy" "$dest_case/lcars-buddy"
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

# --- 15. INSTALL SYNC checks COMPLETENESS, not just direction ------------
# The count printed beside "in sync" was compared to nothing, so the probe said
# the same confident thing about one correctly-linked skill as about all of them.
# The ledgered defect it was supposed to cure was literally "a partial install
# where lcars-run is linked but others are not reads as fully in sync" — and that
# survived, in its original form. A checkout that ships M skills with only N
# installed is not synced; it is an install that would silently run the OLD code
# for the M-N skills the captain never linked.
# Isolate the INSTALL SYNC section before grepping it. The whole brief mentions
# skill names for other reasons entirely (the git stub's `status --short` line is
# ` M skills/lcars-run/run.sh`), so a brief-wide grep for a skill name passes
# whatever the probe says — a vacuous assertion. These checks are about what the
# SYNC VERDICT says.
sync_section() { # sync_section <brief-file> <out-file>
  awk '/^INSTALL SYNC/{f=1} /^CURRENT REPO:/{f=0} f' "$1" >"$2"
}

c15="$(new_lcars_checkout)"                      # ships lcars-run + lcars-buddy
mkdir -p "$c15/skills/lcars-answer" "$c15/skills/lcars-status"   # ships 4 now

# 15a. ONLY lcars-run installed, correctly aimed — the ledger's exact shape.
dest15a="$(new_plain_dir)"
ln -snf "$c15/skills/lcars-run" "$dest15a/lcars-run"
out15a="$TMPROOT/out15a.txt"
LCARS_REPO="$c15" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest15a" bash "$SCRIPT" >"$out15a" 2>&1
check "15a. ONE correctly-linked skill out of four does NOT read in sync" \
  "! grep -qi 'in sync' '$out15a'"
check "15a. it reports the installed count AGAINST the shipped count (1 of 4)" \
  "grep -qE '1 of 4' '$out15a'"
sec15a="$TMPROOT/sec15a.txt"; sync_section "$out15a" "$sec15a"
check "15a. the VERDICT names a skill that is missing, so the gap is visible" \
  "grep -qE 'lcars-(answer|status|buddy)' '$sec15a'"
check "15a. and still tells them to run install.sh" "grep -qF 'install.sh' '$sec15a'"

# 15b. many skills installed and aimed here, but lcars-run MISSING.
dest15b="$(new_plain_dir)"
ln -snf "$c15/skills/lcars-buddy"  "$dest15b/lcars-buddy"
ln -snf "$c15/skills/lcars-answer" "$dest15b/lcars-answer"
ln -snf "$c15/skills/lcars-status" "$dest15b/lcars-status"
out15b="$TMPROOT/out15b.txt"
LCARS_REPO="$c15" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest15b" bash "$SCRIPT" >"$out15b" 2>&1
check "15b. three of four installed does NOT read in sync" \
  "! grep -qi 'in sync' '$out15b'"
check "15b. it reports 3 of 4" "grep -qE '3 of 4' '$out15b'"
sec15b="$TMPROOT/sec15b.txt"; sync_section "$out15b" "$sec15b"
check "15b. the VERDICT names lcars-run as the one that is missing" \
  "grep -q 'lcars-run' '$sec15b' && grep -qi 'missing' '$sec15b'"

# 15c. the FLAGSHIP bare `lcars` skill is checked too (it was globbed out).
# The probe globbed lcars-* , so the one-word `lcars` verb — the one the captain
# uses most — was invisible: a tester pointed every lcars-* link at this checkout
# and the bare `lcars` link at a DIFFERENT checkout and still got a confident
# "in sync. (17 skill(s) checked)" while 18 skills were installed.
c15c="$(new_lcars_checkout)"
mkdir -p "$c15c/skills/lcars"                     # ships lcars, lcars-run, lcars-buddy
other15c="$(new_lcars_checkout)"
mkdir -p "$other15c/skills/lcars"
dest15c="$(new_plain_dir)"
ln -snf "$c15c/skills/lcars-run"    "$dest15c/lcars-run"      # THIS checkout
ln -snf "$c15c/skills/lcars-buddy"  "$dest15c/lcars-buddy"    # THIS checkout
ln -snf "$other15c/skills/lcars"    "$dest15c/lcars"          # somewhere ELSE
out15c="$TMPROOT/out15c.txt"
LCARS_REPO="$c15c" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest15c" bash "$SCRIPT" >"$out15c" 2>&1
check "15c. a bare \`lcars\` pointing elsewhere is NOT reported as in sync" \
  "! grep -qi 'in sync' '$out15c'"
sec15c="$TMPROOT/sec15c.txt"; sync_section "$out15c" "$sec15c"
check "15c. the VERDICT names the bare \`lcars\` as the disagreeing skill" \
  "grep -qE 'e\.g\. lcars ->' '$sec15c'"

# 15d. CONTROL: a COMPLETE install of every shipped skill — bare `lcars`
# included — still reads IN SYNC, and says N of N. Without this control every
# assertion above could be satisfied by a probe that never says "in sync".
dest15d="$(new_plain_dir)"
ln -snf "$c15c/skills/lcars"       "$dest15d/lcars"
ln -snf "$c15c/skills/lcars-run"   "$dest15d/lcars-run"
ln -snf "$c15c/skills/lcars-buddy" "$dest15d/lcars-buddy"
out15d="$TMPROOT/out15d.txt"
LCARS_REPO="$c15c" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest15d" bash "$SCRIPT" >"$out15d" 2>&1
check "15d. CONTROL: a complete, correctly-aimed install reads IN SYNC" \
  "grep -qi 'in sync' '$out15d'"
check "15d. CONTROL: and reports completeness as 3 of 3" \
  "grep -qE '3 of 3' '$out15d'"
sec15d="$TMPROOT/sec15d.txt"; sync_section "$out15d" "$sec15d"
check "15d. CONTROL: no false partial/stale/missing on a complete install" \
  "! grep -qiE 'disagree|partial|stale|missing|incomplete' '$sec15d'"

# ==========================================================================
# S277 — THE BUDDY RUNS FROM EITHER CLI
#
# The three documents told the model to run `bash ~/.claude/skills/lcars-buddy/
# <script>`. `~/.claude/skills/` is CLAUDE CODE's install location; a Copilot
# user does not have it (Copilot mounts the whole plugin at
# ~/.copilot/installed-plugins/_direct/lcars/). The S277 spike put that prose in
# front of a real Copilot turn in a stranger's HOME: the model ran it verbatim,
# took exit 127, reported the error and STOPPED — it never fell back to the
# mount it had just loaded the skill from. Whatever the prose names is what gets
# run, so the prose names on-PATH commands (install.sh generates them) and the
# documents-to-READ get a mount-independent form.
# ==========================================================================
SKILL_MD277="$REPO_ROOT/skills/lcars-buddy/SKILL.md"
ORCH277="$REPO_ROOT/skills/lcars-buddy/ORCHESTRATION.md"
AUTOP277="$REPO_ROOT/skills/lcars-buddy/AUTOPILOT.md"

# --- 16. no Claude-only path survives in the three documents --------------
check "16. SKILL.md carries NO ~/.claude/skills/lcars-buddy literal" \
  "[ \"\$(grep -c '~/.claude/skills/lcars-buddy' '$SKILL_MD277')\" -eq 0 ]"
check "16. ORCHESTRATION.md carries NO ~/.claude/skills/lcars-buddy literal" \
  "[ \"\$(grep -c '~/.claude/skills/lcars-buddy' '$ORCH277')\" -eq 0 ]"
check "16. AUTOPILOT.md carries NO ~/.claude/skills/lcars-buddy literal" \
  "[ \"\$(grep -c '~/.claude/skills/lcars-buddy' '$AUTOP277')\" -eq 0 ]"
# No document may hand the model a `bash ~/.claude…` (or ~/.copilot…) command
# for ANY skill — that is the exit-127 shape, whichever skill it points at.
check "16. no document tells the model to \`bash\` a path under an install farm" \
  "! grep -qE '(bash|sh|source|\\.) +~/\\.(claude|copilot)' '$SKILL_MD277' '$ORCH277' '$AUTOP277'"
# Every ~/.claude mention that REMAINS must be describing the install farm, and
# a description of the farm names BOTH mounts. That is the CLI-neutral contract:
# a line mentioning one CLI's farm and not the other is a Claude-shaped
# instruction wearing a description's clothes.
check "16. every remaining ~/.claude line also names Copilot's mount (farm, not instruction)" \
  "[ \"\$(grep -h '~/\\.claude' '$SKILL_MD277' '$ORCH277' '$AUTOP277' | grep -vc '\\.copilot')\" -eq 0 ]"
# POSITIVE CONTROL: the two-mount phrasing is actually present, so the check
# above cannot be satisfied by deleting every mention of the farm.
check "16. CONTROL: the two-mount farm phrasing is present and names both CLIs" \
  "grep -hE '~/\\.claude/skills/' '$SKILL_MD277' '$ORCH277' | grep -q 'installed-plugins/_direct'"

# --- 17. SKILL.md names the rules file in a form that works in BOTH mounts -
# This REPLACES the old assertion "SKILL.md references the rules file by its
# INSTALL path", which enforced the very literal that broke Copilot. The new
# contract: the rules file is reached by the PATH command (`lcars-buddy docs
# orchestration`), which resolves ORCHESTRATION.md beside whichever copy of
# buddy.sh ran — Claude's per-skill symlink or Copilot's plugin mount.
check "17. SKILL.md still names ORCHESTRATION.md as the rules file" \
  "grep -qF 'ORCHESTRATION.md' '$SKILL_MD277'"
check "17. and reaches it by the mount-independent command, not a Claude path" \
  "grep -qF 'lcars-buddy docs orchestration' '$SKILL_MD277'"
check "17. SKILL.md's primary action is the on-PATH \`lcars-buddy\` command" \
  "grep -qE '^lcars-buddy *$' '$SKILL_MD277'"
check "17. SKILL.md's autopilot driver lines are the on-PATH \`lcars-autopilot\`" \
  "grep -qE '^lcars-autopilot next' '$SKILL_MD277' && grep -qE '^lcars-autopilot status' '$SKILL_MD277' && grep -qE '^lcars-autopilot playbook' '$SKILL_MD277'"
check "17. AUTOPILOT.md's own \"what do I do next\" command is on-PATH" \
  "grep -qE '^lcars-autopilot next' '$AUTOP277'"
check "17. AUTOPILOT.md reaches the four sibling scripts through a PATH command" \
  "grep -qF 'lcars-autopilot exec lcars-init/establish-vision.sh' '$AUTOP277' && grep -qF 'lcars-autopilot exec lcars-file/file.sh' '$AUTOP277' && grep -qF 'lcars-autopilot exec lcars-resolve-logs/resolve-logs.sh' '$AUTOP277' && grep -qF 'lcars-autopilot exec lcars-respond/respond.sh' '$AUTOP277'"

# --- 18. `lcars-buddy docs <name>` — the FILES-TO-READ class --------------
# A PATH launcher cannot be `cat`ed, so "read ORCHESTRATION.md" needs its own
# mount-independent answer. This subcommand prints the document (or its path),
# resolved from the script's own physical directory — proven here by invoking it
# through a SYMLINKED mount, which is exactly what both CLIs do.
docs_out="$TMPROOT/docs-orch.txt"
bash "$SCRIPT" docs orchestration >"$docs_out" 2>&1
check "18. \`docs orchestration\` prints ORCHESTRATION.md's own first line" \
  "qgrep -q 'ORCHESTRATION.md — how an LCARS orchestrator runs' '$docs_out'"
check "18. \`docs --path autopilot\` prints a path that exists" \
  "[ -f \"\$(bash '$SCRIPT' docs --path autopilot)\" ]"
check "18. an unknown document name is refused, not silently empty" \
  "! bash '$SCRIPT' docs no-such-doc >/dev/null 2>&1"
# The symlinked-mount proof: a fake plugin mount whose lcars-buddy dir is a
# symlink to the real one. Skipped when SCRIPT is not inside a skill dir.
mountdir="$TMPROOT/fake-mount"
mkdir -p "$mountdir"
ln -snf "$(cd "$(dirname "$SCRIPT")" && pwd -P)" "$mountdir/lcars-buddy"
check "18. docs resolve when buddy.sh is invoked through a SYMLINKED mount" \
  "bash '$mountdir/lcars-buddy/buddy.sh' docs --path orchestration | qgrep -q 'ORCHESTRATION.md'"

# --- 19. INSTALL SYNC reads BOTH farms ------------------------------------
# buddy.sh read only Claude's farm, so on a Copilot-only machine it announced
# "LCARS skills are not installed here — run ./install.sh" while they WERE
# installed, at the other mount. That is the one line a captain runs buddy in
# order to trust, and it was false for half the audience.
c19="$(new_lcars_checkout)"
dest19="$(new_plain_dir)"
ln -snf "$c19/skills/lcars-run"   "$dest19/lcars-run"
ln -snf "$c19/skills/lcars-buddy" "$dest19/lcars-buddy"

# 19a. the Copilot plugin link points at THIS checkout -> IN SYNC
cop19a="$(new_plain_dir)"; ln -snf "$c19" "$cop19a/lcars"
out19a="$TMPROOT/out19a.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest19" LCARS_COPILOT_PLUGINS_DIR="$cop19a" \
  bash "$SCRIPT" >"$out19a" 2>&1
check "19a. a Copilot plugin aimed at this checkout reads \"Copilot plugin: IN SYNC\"" \
  "qgrep -qF 'Copilot plugin: IN SYNC' '$out19a'"

# 19b. the Copilot plugin link points somewhere ELSE -> STALE
other19="$(new_lcars_checkout)"
cop19b="$(new_plain_dir)"; ln -snf "$other19" "$cop19b/lcars"
out19b="$TMPROOT/out19b.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest19" LCARS_COPILOT_PLUGINS_DIR="$cop19b" \
  bash "$SCRIPT" >"$out19b" 2>&1
check "19b. a Copilot plugin aimed elsewhere reads STALE and names install.sh" \
  "qgrep -qF 'Copilot plugin: STALE' '$out19b' && qgrep -qF 'install.sh' '$out19b'"

# 19c. no plugin link and no copilot CLI -> not a fault, nothing to check
out19c="$TMPROOT/out19c.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest19" LCARS_COPILOT_PLUGINS_DIR="$(new_plain_dir)" \
  LCARS_COPILOT_BIN="$TMPROOT/nope-copilot" \
  bash "$SCRIPT" >"$out19c" 2>&1
check "19c. no Copilot and no link reads \"not installed, nothing to check\"" \
  "qgrep -qF 'Copilot: not installed, nothing to check.' '$out19c'"
check "19c. and does NOT cry STALE or ABSENT about a CLI that is not there" \
  "! qgrep -qF 'Copilot plugin: STALE' '$out19c' && ! qgrep -qF 'Copilot plugin: ABSENT' '$out19c'"

# 19d. copilot IS installed but nothing is linked -> that IS a fault
copstub="$TMPROOT/copilot-stub"; printf '#!/bin/sh\nexit 0\n' >"$copstub"; chmod +x "$copstub"
out19d="$TMPROOT/out19d.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest19" LCARS_COPILOT_PLUGINS_DIR="$(new_plain_dir)" \
  LCARS_COPILOT_BIN="$copstub" \
  bash "$SCRIPT" >"$out19d" 2>&1
check "19d. copilot installed with no plugin link reads ABSENT + run install.sh" \
  "qgrep -qF 'Copilot plugin: ABSENT' '$out19d' && qgrep -qF 'install.sh' '$out19d'"

# --- 20. THE COPILOT-ONLY MACHINE (the S277 bug, end to end) --------------
# A HOME with no .claude at all, no `claude` on PATH, and the skills present at
# the Copilot mount. The brief must NOT claim the skills are missing, must
# report the Copilot mount it CAN see, and must not print a ~/.claude path —
# because the spike proved the model will obey any path it is handed.
home20="$(mktemp -d "$TMPROOT/home20.XXXX")"
c20="$(new_lcars_checkout)"
cop20="$home20/.copilot/installed-plugins/_direct"; mkdir -p "$cop20"
ln -snf "$c20" "$cop20/lcars"
out20="$TMPROOT/out20.txt"
env -u LCARS_SKILLS_DEST -u LCARS_COPILOT_PLUGINS_DIR -u LCARS_COPILOT_BIN \
  HOME="$home20" PATH="/usr/bin:/bin" \
  LCARS_REPO="$c20" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  bash "$SCRIPT" >"$out20" 2>&1
check "20. on a Copilot-only HOME it does NOT claim the skills are not installed" \
  "! qgrep -q 'LCARS skills are not installed here' '$out20'"
check "20. it says Claude Code is simply not installed, nothing to check" \
  "qgrep -qF 'Claude Code: not installed, nothing to check.' '$out20'"
check "20. it reports the Copilot mount it CAN see as IN SYNC" \
  "qgrep -qF 'Copilot plugin: IN SYNC' '$out20'"
check "20. and prints NO .claude path anywhere in the brief" \
  "! qgrep -q '/\\.claude' '$out20'"
check "20. the fix-contract pointer is a runnable command, not a dead path" \
  "qgrep -qF 'lcars-buddy docs orchestration' '$out20'"

# --- 21. the one scope sentence: the orchestrator half is Claude Code today
# The buddy's THREE halves do not have the same reach: the ride-along brief and
# the autopilot are shell + prose and run anywhere, while the fix orchestrator
# spawns sub-agents, which is a Claude Code harness feature today. Saying so
# once, in both files, is the honest version of "the buddy works on Copilot".
SENT277='The orchestrator half spawns sub-agents and is run from Claude Code today; the ride-along brief and the autopilot run from either CLI.'
check "21. ORCHESTRATION.md carries the Claude-Code-today sentence exactly once" \
  "[ \"\$(grep -cF \"\$SENT277\" '$ORCH277')\" -eq 1 ]"
check "21. SKILL.md's BODY carries the same sentence exactly once" \
  "[ \"\$(awk 'NR>1 && /^---$/{fm=1} fm' '$SKILL_MD277' | grep -cF \"\$SENT277\")\" -eq 1 ]"
check "21. SKILL.md's frontmatter DESCRIPTION does not carry it" \
  "[ \"\$(awk 'NR==1 && /^---$/{fm=1; next} fm && /^---$/{exit} fm' '$SKILL_MD277' | grep -cF \"\$SENT277\")\" -eq 0 ]"
# /tdd is a Claude Code slash command; a Copilot reader needs the discipline
# named, not the command.
check "21. ORCHESTRATION.md names /tdd as a Claude Code skill with a by-hand equivalent" \
  "grep -qF 'the \`/tdd\` skill in Claude Code' '$ORCH277' && grep -qiF 'equivalent discipline by hand' '$ORCH277'"

# --- 22. `lcars-autopilot exec <skill>/<script>` — the four sibling scripts
# AUTOPILOT.md names four scripts belonging to OTHER skills. They are not
# `lcars` verbs (lcars.sh has no file/respond/establish-vision route, and
# `lcars file` is an Align conversation, not `file.sh --prd`), so the driver the
# playbook already uses on every line resolves them from its own physical
# location instead — correct under either CLI's mount, with no stage logic
# added. These checks live here rather than in tests/lcars-buddy-autopilot
# .test.sh because that suite's heading/latitude contract is deliberately
# untouched this session.
AP277="${LCARS_AUTOPILOT_SCRIPT:-$REPO_ROOT/skills/lcars-buddy/autopilot.sh}"
ap_repo277="$(mktemp -d "$TMPROOT/aprepo.XXXX")"
( cd "$ap_repo277" && git init -q 2>/dev/null )
# respond.sh (like the driver's own usage) exits non-zero on a bare invocation,
# and this suite runs with `pipefail`, so the output is captured FIRST — piping
# it would report the producer's exit code instead of the grep's.
ex22a="$(LCARS_AUTOPILOT_CWD="$ap_repo277" bash "$AP277" exec lcars-respond/respond.sh 2>&1 || true)"
ex22b="$(LCARS_AUTOPILOT_CWD="$ap_repo277" bash "$AP277" exec lcars-respond respond.sh 2>&1 || true)"
ap22usage="$(bash "$AP277" 2>&1 || true)"
check "22. \`exec lcars-respond/respond.sh\` reaches the real sibling script" \
  "printf '%s' \"\$ex22a\" | qgrep -qi 'respond'"
check "22. the two-argument form \`exec <skill> <script>\` works too" \
  "printf '%s' \"\$ex22b\" | qgrep -qi 'respond'"
check "22. all four scripts AUTOPILOT.md names are reachable through it" \
  "for sc in lcars-init/establish-vision.sh lcars-file/file.sh lcars-resolve-logs/resolve-logs.sh lcars-respond/respond.sh; do [ -f \"$REPO_ROOT/skills/\$sc\" ] || exit 1; done"
check "22. it refuses a script that is not in this clone (no silent no-op)" \
  "! LCARS_AUTOPILOT_CWD='$ap_repo277' bash '$AP277' exec lcars-nope/nope.sh >/dev/null 2>&1"
check "22. it refuses an out-of-tree path" \
  "! LCARS_AUTOPILOT_CWD='$ap_repo277' bash '$AP277' exec ../../../etc/passwd >/dev/null 2>&1"
check "22. the driver documents \`exec\` in its own usage" \
  "printf '%s' \"\$ap22usage\" | qgrep -qF 'exec <skill>/<script>'"

# ==========================================================================
# S277 round 1 — THE THREE THINGS THE FRESH TESTER PROVED STILL BROKEN
#
# Round 0 converted the handful of lines its brief listed and covered the other
# ~59 with a NOTE at the top of AUTOPILOT.md ("a bare `autopilot.sh <verb>` is
# shorthand for `lcars-autopilot <verb>`"). A fresh tester then ran real Copilot
# turns on a copilot-only PATH and the note did not hold, FOUR times out of four
# framings — including the navigation AUTOPILOT.md itself prescribes ("ask the
# driver what to do next, then read that section"), which lands the reader in
# § 8/§ 9 having never seen line 28. Each time the model ran the bare line
# verbatim, took exit 127 and STOPPED. Prose a reader may legitimately never see
# cannot carry a correction; the only durable form is the command written out.
#
# These three groups are the regression guards for that, for the same bug in the
# DRIVER's own output (which had no note anywhere near it), and for the one
# branch of the "not installed here" sentence round 0's own fix missed.
# ==========================================================================

# --- 23. D1: no document hands the model a bare `autopilot.sh <verb>` ----
# The shape is "the word autopilot.sh, not preceded by a path separator or
# another word character, followed by a verb" — i.e. something a model would
# type as a command. A PATH-QUALIFIED mention (.../skills/lcars-buddy/
# autopilot.sh) is deliberately still allowed: that one resolves, and it is the
# documented no-PATH fallback.
D1BARE='(^|[^/[:alnum:]_.-])autopilot\.sh[[:space:]]+[a-z]'
check "23. AUTOPILOT.md hands the model NO bare \`autopilot.sh <verb>\`" \
  "! grep -qE \"\$D1BARE\" '$AUTOP277'"
check "23. SKILL.md hands the model NO bare \`autopilot.sh <verb>\`" \
  "! grep -qE \"\$D1BARE\" '$SKILL_MD277'"
check "23. ORCHESTRATION.md hands the model NO bare \`autopilot.sh <verb>\`" \
  "! grep -qE \"\$D1BARE\" '$ORCH277'"
# And no NOTE may stand in for writing the command out — that is the exact
# mechanism that failed. If a future edit reintroduces a shorthand/alias note,
# this fails even if the bare form is momentarily absent.
check "23. no \"shorthand\"/\"is short for\" note stands in for the real command" \
  "! grep -qiE 'is shorthand for|short for .lcars-autopilot|abbreviation for' '$AUTOP277' '$SKILL_MD277' '$ORCH277'"
# POSITIVE CONTROLS — the prohibition must not be satisfiable by deleting the
# commands. The playbook is ~660 lines of runnable driver calls; they are all
# written out, and the DEEPEST one (the tester reached line 657) is too.
check "23. CONTROL: AUTOPILOT.md writes \`lcars-autopilot\` out dozens of times" \
  "[ \"\$(grep -c 'lcars-autopilot ' '$AUTOP277')\" -ge 40 ]"
check "23. CONTROL: the LAST driver mention in the file is the on-PATH form" \
  "grep -n 'autopilot' '$AUTOP277' | tail -1 | qgrep -q 'lcars-autopilot'"
# The three deep sections the tester was dropped into by name, each proved to
# carry a runnable command on its own, with no reliance on the top of the file.
check "23. § 8's heartbeat line is runnable where a jumped-to reader finds it" \
  "grep -qE '^lcars-autopilot heartbeat install' '$AUTOP277'"
check "23. § 9's \`ask\` example is runnable where a jumped-to reader finds it" \
  "grep -qE '^lcars-autopilot ask ' '$AUTOP277'"
check "23. \`status\`/\`next\`, the two the driver's own PLAYBOOK sends you to, are runnable" \
  "grep -qE '^lcars-autopilot status' '$AUTOP277' && grep -qF 'lcars-autopilot next' '$AUTOP277'"
# The fallback is a FALLBACK: path-qualified, so it cannot be copied as a bare
# command, and present, so a no-PATH reader is not left with nothing.
check "23. the no-PATH fallback is named, and only in path-qualified form" \
  "grep -qF 'skills/lcars-buddy/autopilot.sh' '$AUTOP277'"

# --- 24. D2: the DRIVER's own output names a command that resolves --------
# `lcars-autopilot init` used to end with "record the answers with
# `autopilot.sh record liveTargets.host <host>`". A real Copilot turn told to
# follow it ran exactly that, took exit 127, and recorded nothing — the FIRST
# step after init on a fresh machine. `--help`'s header had the same bug, so the
# driver misnamed itself to every reader on both CLIs. No note was anywhere near
# either: these strings are produced at runtime.
AP277_D2="${LCARS_AUTOPILOT_SCRIPT:-$REPO_ROOT/skills/lcars-buddy/autopilot.sh}"
# STRUCTURAL: comments are not output, so they are excluded (and left alone on
# purpose — they document the file by its real name). Nothing else in the script
# may carry the literal.
check "24. no NON-COMMENT line in the driver carries the \`autopilot.sh\` literal" \
  "[ \"\$(grep -vE '^[[:space:]]*#' '$AP277_D2' | grep -c 'autopilot\.sh')\" -eq 0 ]"
check "24. CONTROL: the comments DO still name the file (nothing was blanket-renamed)" \
  "[ \"\$(grep -cE '^[[:space:]]*#.*autopilot\.sh' '$AP277_D2')\" -ge 1 ]"
# BEHAVIOURAL: the two surfaces the tester and the brief named, plus the whole
# of init's closing advice, must name the on-PATH command.
d24repo="$(mktemp -d "$TMPROOT/d24.XXXX")"
( cd "$d24repo" && git init -q 2>/dev/null )
printf 'M0: a thing\n' >"$d24repo/spec.md"
d24help="$(bash "$AP277_D2" --help 2>&1 || true)"
d24init="$(LCARS_AUTOPILOT_CWD="$d24repo" bash "$AP277_D2" init --spec "$d24repo/spec.md" --scope M0 2>&1 || true)"
d24bare="$(mktemp -d "$TMPROOT/d24b.XXXX")"; ( cd "$d24bare" && git init -q 2>/dev/null )
d24state="$(LCARS_AUTOPILOT_CWD="$d24bare" bash "$AP277_D2" status 2>&1 || true)"
d24ask="$(LCARS_AUTOPILOT_CWD="$d24repo" bash "$AP277_D2" ask 2>&1 || true)"
check "24. \`--help\` names the driver as the reader must TYPE it" \
  "printf '%s' \"\$d24help\" | qgrep -qE '^Usage: lcars-autopilot '"
check "24. \`init\`'s closing \"record the answers with\" step is a resolvable command" \
  "printf '%s' \"\$d24init\" | qgrep -qF 'lcars-autopilot record liveTargets.host'"
check "24. and init's output carries NO \`autopilot.sh <verb>\` anywhere" \
  "! printf '%s' \"\$d24init\" | qgrep -qE \"\$D1BARE\""
check "24. the no-state error names a resolvable command" \
  "printf '%s' \"\$d24state\" | qgrep -qF 'lcars-autopilot init --spec' && ! printf '%s' \"\$d24state\" | qgrep -qE \"\$D1BARE\""
check "24. \`ask\`'s own usage line names a resolvable command" \
  "printf '%s' \"\$d24ask\" | qgrep -qE '^ *lcars-autopilot ask ' && ! printf '%s' \"\$d24ask\" | qgrep -qE \"\$D1BARE\""
# DERIVED, NOT HARD-CODED: the printed name follows how the process was
# invoked, so it cannot drift from the front door again. $LCARS_SELF_CMD is the
# seam that proves the name is a variable and not 20 literals.
# Both producers exit 1 (usage, and a missing autopilot.json), and this suite
# runs with `pipefail`, so the output is captured FIRST — piping it live would
# report the PRODUCER's exit code and fail a passing assertion.
d24help2="$(LCARS_SELF_CMD=zzz-driver bash "$AP277_D2" --help 2>&1 || true)"
d24state2="$(LCARS_SELF_CMD=zzz-driver LCARS_AUTOPILOT_CWD="$d24bare" bash "$AP277_D2" status 2>&1 || true)"
check "24. the printed name FOLLOWS the invoked name (it is derived, not a literal)" \
  "printf '%s' \"\$d24help2\" | qgrep -qE '^Usage: zzz-driver ' && printf '%s' \"\$d24state2\" | qgrep -qF 'zzz-driver init --spec'"
# The python leg writes its own messages; it must follow the same name.
d24ans="$(LCARS_SELF_CMD=zzz-driver LCARS_AUTOPILOT_CWD="$d24repo" bash "$AP277_D2" answered q-nope "x" 2>&1 || true)"
check "24. even the python leg's messages follow the invoked name" \
  "printf '%s' \"\$d24ans\" | qgrep -qF 'zzz-driver status'"

# --- 25. D3: the "not installed" sentence is scoped to ONE farm -----------
# The tester ran the brief with Claude Code PRESENT but its farm holding no LCARS
# links, while Copilot's plugin pointed at this checkout, and got two adjacent
# contradictory lines: "LCARS skills are not installed here — run ./install.sh"
# immediately above "Copilot plugin: IN SYNC". Round 0 had already fixed the
# no-farm-at-all branch and left this one. The claim is now about the farm it was
# measured on, so the contradiction cannot be constructed.
c25="$(new_lcars_checkout)"
dest25="$(new_plain_dir)"          # Claude's farm EXISTS and is EMPTY
cop25="$(new_plain_dir)"; ln -snf "$c25" "$cop25/lcars"   # Copilot points HERE
claude25="$TMPROOT/claude-stub-25"; printf '#!/bin/sh\nexit 0\n' >"$claude25"; chmod +x "$claude25"
out25="$TMPROOT/out25.txt"
LCARS_REPO="$c25" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest25" LCARS_COPILOT_PLUGINS_DIR="$cop25" \
  LCARS_CLAUDE_BIN="$claude25" \
  bash "$SCRIPT" >"$out25" 2>&1
check "25. CONTROL: this IS the tester's case — one farm empty, the other IN SYNC" \
  "qgrep -qF 'Claude Code skills: ABSENT' '$out25' && qgrep -qF 'Copilot plugin: IN SYNC' '$out25'"
check "25. it does NOT claim LCARS is not installed while a farm is IN SYNC" \
  "! qgrep -qE 'LCARS skills are not installed|LCARS is not installed' '$out25'"
check "25. the warning it DOES print names the farm it is about" \
  "qgrep -qE 'no LCARS skills are linked into Claude Code' '$out25' && qgrep -qF 'install.sh' '$out25'"
# THE GENERAL RULE, not just this fixture: no line may make an unscoped
# "not installed" claim about the machine from inside a single farm's branch.
check "25. no unscoped \"not installed here\" sentence survives in buddy.sh at all" \
  "[ \"\$(grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -cF 'LCARS skills are not installed here')\" -eq 0 ]"
# And the honest-absence case still reports absence — the cure must not have
# silenced a true warning. Both farms empty, Claude installed: still a fault.
out25b="$TMPROOT/out25b.txt"
LCARS_REPO="$c25" GIT_BIN="$GIT_STUB" LCARS_BUDDY_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" LCARS_COPILOT_PLUGINS_DIR="$(new_plain_dir)" \
  LCARS_CLAUDE_BIN="$claude25" \
  bash "$SCRIPT" >"$out25b" 2>&1
check "25. CONTROL: with NO farm in sync it still warns, and still names install.sh" \
  "qgrep -qF 'Claude Code skills: ABSENT' '$out25b' && qgrep -qE 'no LCARS skills are linked into Claude Code' '$out25b' && qgrep -qF 'install.sh' '$out25b'"

# ==========================================================================
# S277 round 2 — the SAME exit-127 class in the two surfaces round 1 scoped out
# of its cure. Both are a command written where a model will copy it, in a form
# that resolves on neither CLI. Nothing here changes a heading, the latitude,
# the interrupt budget or the merge policy.
# ==========================================================================

# --- 26. D4: no document hands the model a bare `xo.sh <verb>` ------------
# D1 (§ 23) banned a bare `autopilot.sh <verb>`. `xo.sh` is the identical bug
# with a different script: § 6 told the reader to read Number One's verdict with
# a bare `xo.sh report`, which is exit 127 on BOTH CLIs — no LCARS script is
# ever on PATH under its own name. The cure is the driver's own `exec` seam,
# which resolves a sibling script from THIS clone under either install mount.
# Same shape as $D1BARE: a path-qualified mention (lcars-xo/xo.sh) is fine,
# because that one is an `exec` argument and not a command.
D4BARE='(^|[^/[:alnum:]_.-])xo\.sh[[:space:]]+[a-z]'
check "26. AUTOPILOT.md hands the model NO bare \`xo.sh <verb>\`" \
  "! grep -qE \"\$D4BARE\" '$AUTOP277'"
check "26. SKILL.md hands the model NO bare \`xo.sh <verb>\`" \
  "! grep -qE \"\$D4BARE\" '$SKILL_MD277'"
check "26. ORCHESTRATION.md hands the model NO bare \`xo.sh <verb>\`" \
  "! grep -qE \"\$D4BARE\" '$ORCH277'"
# POSITIVE CONTROL — the ban must not be satisfiable by DELETING the
# instruction. The reader must still be told to read the verdict, via `exec`.
check "26. CONTROL: AUTOPILOT.md still tells the reader to read the XO report" \
  "qgrep -qF 'lcars-autopilot exec lcars-xo/xo.sh report' '$AUTOP277'"
# And the form it prints must RESOLVE. `exec` refuses an out-of-tree path and
# dies on a missing script, so the path the doc names has to exist here...
check "26. the \`exec\` form the doc prints names a script that exists" \
  "[ -f '$REPO_ROOT/skills/lcars-xo/xo.sh' ]"
# ...and running it must REACH xo.sh. This is the assertion that would have
# caught the bare form: it is RUN, not grepped. It asserts POSITIVELY, on
# xo.sh's own report output — a negative ("no 127") passes vacuously whenever
# the driver dies earlier, which is exactly what a non-git cwd makes it do.
# So the cwd is a real git repo, like § 24's: the driver refuses anything else
# before it ever reaches `exec`.
d26repo="$(mktemp -d "$TMPROOT/d26.XXXX")"
( cd "$d26repo" && git init -q 2>/dev/null )
d26out="$(LCARS_AUTOPILOT_CWD="$d26repo" bash "$AP277_D2" exec lcars-xo/xo.sh report 2>&1 || true)"
check "26. running that exact form REACHES xo.sh (its OWN report output comes back)" \
  "printf '%s' \"\$d26out\" | qgrep -qE 'Since you last looked|History:'"
check "26. and it is not a not-found refusal of any kind" \
  "! printf '%s' \"\$d26out\" | qgrep -qiE 'no such script|command not found|No such file|not a git repository'"
# CONTROL — the pair must be able to FAIL, so the same form with a script that
# does not exist has to be refused by name. The refusal EXITS 1 and this suite
# runs with `pipefail`, so the output is captured FIRST (see the same note in
# § 24): piping it live would report the PRODUCER's code, not the grep's.
d26bog="$(LCARS_AUTOPILOT_CWD="$d26repo" bash "$AP277_D2" exec lcars-xo/nope.sh report 2>&1 || true)"
check "26. CONTROL: a BOGUS script in the same form IS refused (the check can fail)" \
  "printf '%s' \"\$d26bog\" | qgrep -qF 'no such script'"

# --- 27. D5: `--help`'s verb list says HOW to run what it lists -----------
# The block headed "THE VERBS THIS DRIVES" lists tokens like
# `lcars-file/file.sh --prd <path>`. NONE of them is a runnable command: each
# runs ONLY as `lcars-autopilot exec <skill>/<script>`. The header never said
# so, so a model copying a line took exit 127 — this session's whole defect,
# reproduced inside the driver's own output. The 8 tokens are deliberately NOT
# rewritten: they are the real paths `exec` expects.
d27help="$(bash "$AP277_D2" --help 2>&1 || true)"
d27hdr="$(printf '%s\n' "$d27help" | grep -F 'THE VERBS THIS DRIVES' || true)"
check "27. CONTROL: \`--help\` still prints the verb-list header at all" \
  "[ -n \"\$d27hdr\" ]"
check "27. the header tells the reader the tokens run via \`exec <skill>/<script>\`" \
  "printf '%s' \"\$d27hdr\" | qgrep -qF 'exec <skill>/<script>'"
check "27. the header names the driver as the reader must TYPE it" \
  "printf '%s' \"\$d27hdr\" | qgrep -qF 'lcars-autopilot exec'"
# DERIVED, like every other message (§ 24): the prefix follows the invoked name,
# so it cannot drift from whatever front door a future CLI installs.
d27help2="$(LCARS_SELF_CMD=zzz-driver bash "$AP277_D2" --help 2>&1 || true)"
check "27. the header's prefix FOLLOWS the invoked name (derived, not a literal)" \
  "printf '%s\n' \"\$d27help2\" | grep -F 'THE VERBS THIS DRIVES' | qgrep -qF 'zzz-driver exec'"
# CONTROL: the tokens themselves survive untouched.
check "27. CONTROL: the listed tokens are still the real script paths" \
  "printf '%s' \"\$d27help\" | qgrep -qF 'lcars-file/file.sh' && printf '%s' \"\$d27help\" | qgrep -qF 'lcars-xo/xo.sh'"
# And the header's promise must be TRUE for every token it lists: each
# <skill>/<script>.sh must exist here, or `exec` would die on it.
d27toks="$(printf '%s\n' "$d27help" | sed -n 's|^[[:space:]]*\(lcars-[a-z-]*/[a-z.-]*\.sh\).*|\1|p')"
d27miss=0
for tok in $d27toks; do
  [ -f "$REPO_ROOT/skills/$tok" ] || d27miss=$((d27miss + 1))
done
check "27. every <skill>/<script> token the block lists exists in this clone" \
  "[ $d27miss -eq 0 ]"
check "27. CONTROL: that sweep found real tokens (not a vacuous zero)" \
  "[ \"\$(printf '%s\n' \"\$d27toks\" | grep -c .)\" -ge 6 ]"

# --- 28. Unattended project-test commands stay rooted and write downward ---
d28rule="$(sed -n '/^## Unattended Copilot commands:/,/^## How to read this file/p' "$AUTOP277")"
d28line="$(grep -n '^## Unattended Copilot commands:' "$AUTOP277" | cut -d: -f1)"
d28trust="$(grep -n '^## Unattended Copilot setup:' "$AUTOP277" | cut -d: -f1)"
d28read="$(grep -n '^## How to read this file' "$AUTOP277" | cut -d: -f1)"
d28test="$(grep -n '^## 3\. Foundation' "$AUTOP277" | cut -d: -f1)"
check "28. command safety follows trust setup and precedes reading/project testing" \
  "[ -n '$d28line' ] && [ '$d28trust' -lt '$d28line' ] && [ '$d28line' -lt '$d28read' ] && [ '$d28line' -lt '$d28test' ]"
check "28. run from the repository root and write DOWNWARD" \
  "printf '%s' \"\$d28rule\" | qgrep -qF 'Run commands from the repository root and write DOWNWARD'"
check "28. never redirect through parent path components" \
  "printf '%s' \"\$d28rule\" | qgrep -qF 'Never redirect through parent path components'"
check "28. the route is refused even with blanket trust" \
  "printf '%s' \"\$d28rule\" | qgrep -qF 'route is refused even with' && printf '%s' \"\$d28rule\" | qgrep -qF 'COPILOT_ALLOW_ALL=true'"
check "28. the reason does not blame the destination or test tooling" \
  "printf '%s' \"\$d28rule\" | qgrep -qF 'not the destination, .git, Python, or the test runner'"
check "28. unattended refusal ends the run rather than inviting a retry" \
  "printf '%s' \"\$d28rule\" | qgrep -qF 'no interactive approval is possible' && printf '%s' \"\$d28rule\" | qgrep -qF 'refusal ends the run; do not retry'"
check "28. refused example is explicitly NOT a suggested command" \
  "printf '%s' \"\$d28rule\" | qgrep -qF 'REFUSED — documentation only; do not execute or copy as a suggested command'"
d28refused='cd .git/lcars/tmp/<wt> && python3 -m unittest ... > ../../autopilot/x.txt ;'
d28working='python3 -m unittest discover -s .git/lcars/tmp/<wt>/tests -v > .git/lcars/autopilot/x.txt'
check "28. exact refused and working examples appear in the early safety section" \
  "printf '%s\n' \"\$d28rule\" | qgrep -qFx \"\$d28refused\" && printf '%s\n' \"\$d28rule\" | qgrep -qFx \"\$d28working\""

# --- summary --------------------------------------------------------------
printf '\nlcars buddy: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
