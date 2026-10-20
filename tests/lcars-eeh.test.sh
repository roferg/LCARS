#!/usr/bin/env bash
#
# Tests for `lcars eeh` (skill source: skills/lcars-eeh/eeh.sh).
#
# `lcars eeh` is the GLOBAL, repo-agnostic "spin up an LCARS debugging EEH
# anywhere" skill. Invoked from ANY repo, its bundled eeh.sh prints a single
# diagnostic brief that (a) locates the LCARS checkout and reports its git state,
# (b) checks whether the INSTALLED skills actually point at that checkout (so the
# captain knows the code they edit is the code that runs), and (c) snapshots the
# CURRENT repo's LCARS mission state (the thing that is misbehaving). All logic
# lives in eeh.sh so it is exercised directly here, deps injected via env:
#   LCARS_REPO          the LCARS checkout to debug (default: resolved from the script)
#   GIT_BIN             git binary (stubbed here)
#   LCARS_EEH_CWD     the repo to inspect for active missions (default: $PWD)
#   LCARS_SKILLS_DEST   the installed-skills dir (default: ~/.claude/skills)
#
# Usage: bash tests/lcars-eeh.test.sh
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
SCRIPT="${LCARS_EEH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/eeh.sh}"


pass=0
fail=0
TMPROOT="$(mktemp -d "${TMPDIR:-.}/lcars-eeh.XXXXXX")"
TMPROOT="$(cd "$TMPROOT" && pwd)"
trap 'rm -rf "$TMPROOT"' EXIT
# S277 — FENCE THE SECOND FARM FOR THE WHOLE FILE. eeh.sh now reports Copilot's
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

# A directory that LOOKS like an LCARS checkout (the markers eeh.sh validates).
new_lcars_checkout() {
  local repo; repo="$(mktemp -d "$TMPROOT/lcars.XXXX")"
  : >"$repo/vision.md"
  : >"$repo/install.sh"
  : >"$repo/CONTEXT.md"
  : >"$repo/CLAUDE.md"
  mkdir -p "$repo/skills/lcars-run" "$repo/skills/lcars-eeh"
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

# A stub git that answers the queries eeh.sh makes (branch / HEAD / status / log).
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
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$work" \
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
# the EEH's json_str claimed to "mirror status.sh" but had drifted to the old
# naive sed reader whose value class is [^"]* — it stops at the FIRST escaped
# quote. That is not an exotic input: S148 makes every testCommand LCARS itself
# seeds QUOTE its $LCARS_TESTS_DIR scope, so a correctly-configured repo always
# stores \" in config.json. The brief then printed a TRUNCATED command — the
# exact value a captain runs the EEH to verify — reading as if the config were
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
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$work3b" \
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
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$work4" \
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
  LCARS_REPO="$REPO_ROOT" GIT_BIN=git LCARS_EEH_CWD="$pause_work" \
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
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
ln -snf "$LCARS/skills/lcars-eeh" "$dest_sync/lcars-eeh"
out6a="$TMPROOT/out6a.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_sync" bash "$SCRIPT" >"$out6a" 2>&1
check "6a. reports installed skills are IN SYNC with this checkout" \
  "qgrep -qiE 'in sync|up to date|points at' '$out6a'"

# 6b. dest symlink points at a DIFFERENT checkout -> warn + name install.sh
other="$(new_lcars_checkout)"
dest_stale="$(new_plain_dir)"
ln -snf "$other/skills/lcars-run" "$dest_stale/lcars-run"
out6b="$TMPROOT/out6b.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_stale" bash "$SCRIPT" >"$out6b" 2>&1
check "6b. WARNS when installed skills do not point at this checkout" \
  "qgrep -qiE 'stale|do not point|install\.sh' '$out6b'"

# --- 7. points the EEH at the key source docs ---------------------------
check "7. points the EEH at vision.md and CLAUDE.md" \
  "qgrep -q 'vision.md' '$out1' && qgrep -q 'CLAUDE.md' '$out1'"

# --- 8. ORCHESTRATION.md — the ONE shared orchestration rules file --------
# S197: run-session (lcars-dev), night-watch (lcars-dev) and `lcars eeh` all
# follow the SAME orchestration loop — implementor (TDD) → fresh tester → fix
# rounds → teardown → commit → readout. Until now each of the three RESTATED it,
# which is exactly how three copies drift apart (and the EEH's copy had already
# lost the tester, the round counter and the regression guard). The rules MOVED
# into this file; every consumer points at
# `~/.claude/skills/lcars-eeh/ORCHESTRATION.md` — a stable path from any cwd,
# reached through the install symlink, so no installer changes.
ORCH="$REPO_ROOT/skills/lcars-eeh/ORCHESTRATION.md"
check "8. skills/lcars-eeh/ORCHESTRATION.md exists" "[ -f '$ORCH' ]"

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
SKILL_MD="$REPO_ROOT/skills/lcars-eeh/SKILL.md"
# S277 — THIS ASSERTION WAS CHANGED, DELIBERATELY. It used to read:
#   check "9. SKILL.md references the rules file by its INSTALL path" \
#     "grep -qF '~/.claude/skills/lcars-eeh/ORCHESTRATION.md' '$SKILL_MD'"
# i.e. it ENFORCED the one literal that breaks the skill under Copilot, whose
# install mount is ~/.copilot/installed-plugins/_direct/lcars/skills/lcars-eeh.
# The requirement behind it is unchanged — SKILL.md must POINT at the rules file
# rather than restate it — so what is asserted now is that it points at it in a
# form that resolves in BOTH mounts. Group 17 below holds the positive form of
# this contract; group 16 holds the prohibition.
check "9. SKILL.md references the rules file by a form that works in BOTH mounts" \
  "grep -qF 'ORCHESTRATION.md' '$SKILL_MD' && grep -qF 'lcars-eeh docs orchestration' '$SKILL_MD' && ! grep -qF '~/.claude/skills/lcars-eeh/ORCHESTRATION.md' '$SKILL_MD'"
check "9. SKILL.md no longer restates the moved rule sentences" \
  "! grep -qE 'TDD.*: write the failing|Commit only when asked' '$SKILL_MD'"
check "9. SKILL.md's fix half is an ORCHESTRATOR (brief, fix/<slug>, tester, readout)" \
  "grep -qF 'fix/<slug>' '$SKILL_MD' && grep -qi 'implementor' '$SKILL_MD' && grep -qi 'tester' '$SKILL_MD'"
check "9. SKILL.md carries the clean-and-on-main refusal" \
  "grep -qF 'will not stack a fix onto it' '$SKILL_MD'"

# --- 10. the brief stops carrying a SECOND copy of the rules --------------
# eeh.sh used to print its own five-rule block — the same five rules SKILL.md
# stated, i.e. a drift surface inside one skill. One pointer line replaces it.
check "10. the brief no longer prints the duplicated EEH RULES block" \
  "! grep -qiE 'EEH RULES|TDD: failing test first' '$out1'"
check "10. the brief prints exactly ONE pointer line naming ORCHESTRATION.md" \
  "[ \"\$(grep -c 'ORCHESTRATION.md' '$out1')\" = 1 ]"

# --- 11. INSTALL SYNC is case-TOLERANT (the S197 bug) --------------------
# eeh.sh compared the install symlink target against $REPO with a
# case-SENSITIVE `case` glob. APFS is case-insensitive but `pwd -P` preserves
# the case you TYPED, so `LCARS_REPO=~/Projects/lcars` (or an EEH invoked
# through a lowercase path) reported a perfectly in-sync install as STALE — the
# one check a captain runs the EEH in order to trust.
caseroot="$(mktemp -d "$TMPROOT/case.XXXX")"
case_upper="$caseroot/Fake-LCARS"
mkdir -p "$case_upper/skills/lcars-run" "$case_upper/skills/lcars-eeh"
: >"$case_upper/vision.md"; : >"$case_upper/install.sh"
case_lower="$caseroot/fake-lcars"
# On a case-INSENSITIVE FS the lowercase spelling already resolves to the same
# dir; on a case-SENSITIVE one, make it a second spelling of the same dir.
[ -d "$case_lower" ] || ln -snf "$case_upper" "$case_lower"
dest_case="$(new_plain_dir)"
# Both shipped skills linked — completeness is group 15's subject, not this one.
ln -snf "$case_upper/skills/lcars-run"   "$dest_case/lcars-run"
ln -snf "$case_upper/skills/lcars-eeh" "$dest_case/lcars-eeh"
out11="$TMPROOT/out11.txt"
LCARS_REPO="$case_lower" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest_case" bash "$SCRIPT" >"$out11" 2>&1
check "11. IN SYNC when the symlink target and LCARS_REPO differ only by CASE" \
  "grep -qi 'in sync' '$out11'"
check "11. and does NOT cry STALE on that case-different path" \
  "! grep -qi 'stale' '$out11'"

# --- 12. default repo resolution through the install symlink -------------
# Every case above passes LCARS_REPO explicitly, so the `pwd -P` default path
# (eeh.sh's normal production path — invoked as
# ~/.claude/skills/lcars-eeh/eeh.sh) was never exercised.
defroot="$(mktemp -d "$TMPROOT/def.XXXX")"
defrepo="$defroot/LCARS"
mkdir -p "$defrepo/skills/lcars-run" "$defrepo/skills/lcars-eeh"
: >"$defrepo/vision.md"; : >"$defrepo/install.sh"
cp "$SCRIPT" "$defrepo/skills/lcars-eeh/eeh.sh"
dest_def="$(new_plain_dir)"
ln -snf "$defrepo/skills/lcars-eeh" "$dest_def/lcars-eeh"
ln -snf "$defrepo/skills/lcars-run" "$dest_def/lcars-run"
defphys="$(cd "$defrepo" && pwd -P)"
out12="$TMPROOT/out12.txt"
( unset LCARS_REPO
  GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
    LCARS_SKILLS_DEST="$dest_def" bash "$dest_def/lcars-eeh/eeh.sh" ) >"$out12" 2>&1
check "12. with NO LCARS_REPO, resolves the PHYSICAL checkout behind the symlink" \
  "grep -qF 'LCARS REPO: $defphys' '$out12'"
check "12. and that default resolution reads as IN SYNC" \
  "grep -qi 'in sync' '$out12'"

# --- 13. the build contract is complete in its own file ------------------
CONTRACT="$REPO_ROOT/CLAUDE.md"
check "13. CLAUDE.md points at the shared orchestration rules file" \
  "grep -qF 'skills/lcars-eeh/ORCHESTRATION.md' '$CONTRACT'"
check "13. CLAUDE.md scopes the FULL suite to ship-it, fixes/sessions to the scoped suite" \
  "grep -qF 'ship-it' '$CONTRACT' && grep -qiE 'scoped' '$CONTRACT'"
check "13. CLAUDE.md states the branch-naming convention and the commit trailer" \
  "grep -qF 'fix/<slug>' '$CONTRACT' && grep -qF 'Co-Authored-By' '$CONTRACT'"

# --- 14. INSTALL SYNC judges ALL installed skills, not one symlink -------
# eeh.sh resolved install sync by reading the `lcars-run` symlink ALONE, so a
# PARTIAL install — lcars-run linked to this checkout while the other skills
# still point somewhere else — reported a confident, wrong "in sync". That is
# the one line a captain runs the EEH in order to trust before editing code, and a
# partial install is exactly what a half-finished `./install.sh`, a renamed
# checkout, or an isolated-dest experiment leaves behind.
other14="$(new_lcars_checkout)"
mkdir -p "$other14/skills/lcars-answer" "$LCARS/skills/lcars-answer"
dest_partial="$(new_plain_dir)"
ln -snf "$LCARS/skills/lcars-run"      "$dest_partial/lcars-run"      # THIS checkout
ln -snf "$LCARS/skills/lcars-eeh"    "$dest_partial/lcars-eeh"    # THIS checkout
ln -snf "$other14/skills/lcars-answer" "$dest_partial/lcars-answer"   # somewhere ELSE
out14="$TMPROOT/out14.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
ln -snf "$LCARS/skills/lcars-eeh"  "$dest_all/lcars-eeh"
ln -snf "$LCARS/skills/lcars-answer" "$dest_all/lcars-answer"
out14b="$TMPROOT/out14b.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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

c15="$(new_lcars_checkout)"                      # ships lcars-run + lcars-eeh
mkdir -p "$c15/skills/lcars-answer" "$c15/skills/lcars-status"   # ships 4 now

# 15a. ONLY lcars-run installed, correctly aimed — the ledger's exact shape.
dest15a="$(new_plain_dir)"
ln -snf "$c15/skills/lcars-run" "$dest15a/lcars-run"
out15a="$TMPROOT/out15a.txt"
LCARS_REPO="$c15" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest15a" bash "$SCRIPT" >"$out15a" 2>&1
check "15a. ONE correctly-linked skill out of four does NOT read in sync" \
  "! grep -qi 'in sync' '$out15a'"
check "15a. it reports the installed count AGAINST the shipped count (1 of 4)" \
  "grep -qE '1 of 4' '$out15a'"
sec15a="$TMPROOT/sec15a.txt"; sync_section "$out15a" "$sec15a"
check "15a. the VERDICT names a skill that is missing, so the gap is visible" \
  "grep -qE 'lcars-(answer|status|the EEH)' '$sec15a'"
check "15a. and still tells them to run install.sh" "grep -qF 'install.sh' '$sec15a'"

# 15b. many skills installed and aimed here, but lcars-run MISSING.
dest15b="$(new_plain_dir)"
ln -snf "$c15/skills/lcars-eeh"  "$dest15b/lcars-eeh"
ln -snf "$c15/skills/lcars-answer" "$dest15b/lcars-answer"
ln -snf "$c15/skills/lcars-status" "$dest15b/lcars-status"
out15b="$TMPROOT/out15b.txt"
LCARS_REPO="$c15" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
mkdir -p "$c15c/skills/lcars"                     # ships lcars, lcars-run, lcars-eeh
other15c="$(new_lcars_checkout)"
mkdir -p "$other15c/skills/lcars"
dest15c="$(new_plain_dir)"
ln -snf "$c15c/skills/lcars-run"    "$dest15c/lcars-run"      # THIS checkout
ln -snf "$c15c/skills/lcars-eeh"  "$dest15c/lcars-eeh"    # THIS checkout
ln -snf "$other15c/skills/lcars"    "$dest15c/lcars"          # somewhere ELSE
out15c="$TMPROOT/out15c.txt"
LCARS_REPO="$c15c" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
ln -snf "$c15c/skills/lcars-eeh" "$dest15d/lcars-eeh"
out15d="$TMPROOT/out15d.txt"
LCARS_REPO="$c15c" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest15d" bash "$SCRIPT" >"$out15d" 2>&1
check "15d. CONTROL: a complete, correctly-aimed install reads IN SYNC" \
  "grep -qi 'in sync' '$out15d'"
check "15d. CONTROL: and reports completeness as 3 of 3" \
  "grep -qE '3 of 3' '$out15d'"
sec15d="$TMPROOT/sec15d.txt"; sync_section "$out15d" "$sec15d"
check "15d. CONTROL: no false partial/stale/missing on a complete install" \
  "! grep -qiE 'disagree|partial|stale|missing|incomplete' '$sec15d'"

# ==========================================================================
# S277 — THE EEH RUNS FROM EITHER CLI
#
# The three documents told the model to run `bash ~/.claude/skills/lcars-eeh/
# <script>`. `~/.claude/skills/` is CLAUDE CODE's install location; a Copilot
# user does not have it (Copilot mounts the whole plugin at
# ~/.copilot/installed-plugins/_direct/lcars/). The S277 spike put that prose in
# front of a real Copilot turn in a stranger's HOME: the model ran it verbatim,
# took exit 127, reported the error and STOPPED — it never fell back to the
# mount it had just loaded the skill from. Whatever the prose names is what gets
# run, so the prose names on-PATH commands (install.sh generates them) and the
# documents-to-READ get a mount-independent form.
# ==========================================================================
SKILL_MD277="$REPO_ROOT/skills/lcars-eeh/SKILL.md"
ORCH277="$REPO_ROOT/skills/lcars-eeh/ORCHESTRATION.md"
AUTOP277="$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"

# --- 16. no Claude-only path survives in the three documents --------------
check "16. SKILL.md carries NO ~/.claude/skills/lcars-eeh literal" \
  "[ \"\$(grep -c '~/.claude/skills/lcars-eeh' '$SKILL_MD277')\" -eq 0 ]"
check "16. ORCHESTRATION.md carries NO ~/.claude/skills/lcars-eeh literal" \
  "[ \"\$(grep -c '~/.claude/skills/lcars-eeh' '$ORCH277')\" -eq 0 ]"
check "16. HOLOGRAM-COMMAND-MODE.md carries NO ~/.claude/skills/lcars-eeh literal" \
  "[ \"\$(grep -c '~/.claude/skills/lcars-eeh' '$AUTOP277')\" -eq 0 ]"
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
# contract: the rules file is reached by the PATH command (`lcars-eeh docs
# orchestration`), which resolves ORCHESTRATION.md beside whichever copy of
# eeh.sh ran — Claude's per-skill symlink or Copilot's plugin mount.
check "17. SKILL.md still names ORCHESTRATION.md as the rules file" \
  "grep -qF 'ORCHESTRATION.md' '$SKILL_MD277'"
check "17. and reaches it by the mount-independent command, not a Claude path" \
  "grep -qF 'lcars-eeh docs orchestration' '$SKILL_MD277'"
check "17. SKILL.md's primary action is the on-PATH \`lcars-eeh\` command" \
  "grep -qE '^lcars-eeh *$' '$SKILL_MD277'"
check "17. SKILL.md's ECH driver lines are the on-PATH \`lcars-ech\`" \
  "grep -qE '^lcars-ech next' '$SKILL_MD277' && grep -qE '^lcars-ech status' '$SKILL_MD277' && grep -qE '^lcars-ech playbook' '$SKILL_MD277'"
check "17. HOLOGRAM-COMMAND-MODE.md's own \"what do I do next\" command is on-PATH" \
  "grep -qE '^lcars-ech next' '$AUTOP277'"
check "17. HOLOGRAM-COMMAND-MODE.md reaches the four sibling scripts through a PATH command" \
  "grep -qF 'lcars-ech exec lcars-init/establish-vision.sh' '$AUTOP277' && grep -qF 'lcars-ech exec lcars-file/file.sh' '$AUTOP277' && grep -qF 'lcars-ech exec lcars-resolve-logs/resolve-logs.sh' '$AUTOP277' && grep -qF 'lcars-ech exec lcars-respond/respond.sh' '$AUTOP277'"

# --- 18. `lcars-eeh docs <name>` — the FILES-TO-READ class --------------
# A PATH launcher cannot be `cat`ed, so "read ORCHESTRATION.md" needs its own
# mount-independent answer. This subcommand prints the document (or its path),
# resolved from the script's own physical directory — proven here by invoking it
# through a SYMLINKED mount, which is exactly what both CLIs do.
docs_out="$TMPROOT/docs-orch.txt"
bash "$SCRIPT" docs orchestration >"$docs_out" 2>&1
check "18. \`docs orchestration\` prints ORCHESTRATION.md's own first line" \
  "qgrep -q 'ORCHESTRATION.md — how an LCARS orchestrator runs' '$docs_out'"
check "18. \`docs --path ech\` prints a path that exists" \
  "[ -f \"\$(bash '$SCRIPT' docs --path ech)\" ]"
check "18. an unknown document name is refused, not silently empty" \
  "! bash '$SCRIPT' docs no-such-doc >/dev/null 2>&1"
# The symlinked-mount proof: a fake plugin mount whose lcars-eeh dir is a
# symlink to the real one. Skipped when SCRIPT is not inside a skill dir.
mountdir="$TMPROOT/fake-mount"
mkdir -p "$mountdir"
ln -snf "$(cd "$(dirname "$SCRIPT")" && pwd -P)" "$mountdir/lcars-eeh"
check "18. docs resolve when eeh.sh is invoked through a SYMLINKED mount" \
  "bash '$mountdir/lcars-eeh/eeh.sh' docs --path orchestration | qgrep -q 'ORCHESTRATION.md'"

# --- 19. INSTALL SYNC reads BOTH farms ------------------------------------
# eeh.sh read only Claude's farm, so on a Copilot-only machine it announced
# "LCARS skills are not installed here — run ./install.sh" while they WERE
# installed, at the other mount. That is the one line a captain runs the EEH in
# order to trust, and it was false for half the audience.
c19="$(new_lcars_checkout)"
dest19="$(new_plain_dir)"
ln -snf "$c19/skills/lcars-run"   "$dest19/lcars-run"
ln -snf "$c19/skills/lcars-eeh" "$dest19/lcars-eeh"

# 19a. the Copilot plugin link points at THIS checkout -> IN SYNC
cop19a="$(new_plain_dir)"; ln -snf "$c19" "$cop19a/lcars"
out19a="$TMPROOT/out19a.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest19" LCARS_COPILOT_PLUGINS_DIR="$cop19a" \
  bash "$SCRIPT" >"$out19a" 2>&1
check "19a. a Copilot plugin aimed at this checkout reads \"Copilot plugin: IN SYNC\"" \
  "qgrep -qF 'Copilot plugin: IN SYNC' '$out19a'"

# 19b. the Copilot plugin link points somewhere ELSE -> STALE
other19="$(new_lcars_checkout)"
cop19b="$(new_plain_dir)"; ln -snf "$other19" "$cop19b/lcars"
out19b="$TMPROOT/out19b.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$dest19" LCARS_COPILOT_PLUGINS_DIR="$cop19b" \
  bash "$SCRIPT" >"$out19b" 2>&1
check "19b. a Copilot plugin aimed elsewhere reads STALE and names install.sh" \
  "qgrep -qF 'Copilot plugin: STALE' '$out19b' && qgrep -qF 'install.sh' '$out19b'"

# 19c. no plugin link and no copilot CLI -> not a fault, nothing to check
out19c="$TMPROOT/out19c.txt"
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
LCARS_REPO="$c19" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
  LCARS_REPO="$c20" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
  "qgrep -qF 'lcars-eeh docs orchestration' '$out20'"

# --- 21. the one scope sentence: the orchestrator half is Claude Code today
# The EEH's THREE halves do not have the same reach: the ride-along brief and
# the ECH are shell + prose and run anywhere, while the fix orchestrator
# spawns sub-agents, which is a Claude Code harness feature today. Saying so
# once, in both files, is the honest version of "the EEH works on Copilot".
SENT277='The orchestrator half spawns sub-agents and is run from Claude Code today; the ride-along brief and the ECH run from either CLI.'
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

# --- 22. `lcars-ech exec <skill>/<script>` — the four sibling scripts
# HOLOGRAM-COMMAND-MODE.md names four scripts belonging to OTHER skills. They are not
# `lcars` verbs (lcars.sh has no file/respond/establish-vision route, and
# `lcars file` is an Align conversation, not `file.sh --prd`), so the driver the
# playbook already uses on every line resolves them from its own physical
# location instead — correct under either CLI's mount, with no stage logic
# added. These checks live here rather than in tests/lcars-ech
# .test.sh because that suite's heading/latitude contract is deliberately
# untouched this session.
AP277="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"
ap_repo277="$(mktemp -d "$TMPROOT/aprepo.XXXX")"
( cd "$ap_repo277" && git init -q 2>/dev/null )
# respond.sh (like the driver's own usage) exits non-zero on a bare invocation,
# and this suite runs with `pipefail`, so the output is captured FIRST — piping
# it would report the producer's exit code instead of the grep's.
ex22a="$(LCARS_ECH_CWD="$ap_repo277" bash "$AP277" exec lcars-respond/respond.sh 2>&1 || true)"
ex22b="$(LCARS_ECH_CWD="$ap_repo277" bash "$AP277" exec lcars-respond respond.sh 2>&1 || true)"
ap22usage="$(bash "$AP277" 2>&1 || true)"
check "22. \`exec lcars-respond/respond.sh\` reaches the real sibling script" \
  "printf '%s' \"\$ex22a\" | qgrep -qi 'respond'"
check "22. the two-argument form \`exec <skill> <script>\` works too" \
  "printf '%s' \"\$ex22b\" | qgrep -qi 'respond'"
check "22. all four scripts HOLOGRAM-COMMAND-MODE.md names are reachable through it" \
  "for sc in lcars-init/establish-vision.sh lcars-file/file.sh lcars-resolve-logs/resolve-logs.sh lcars-respond/respond.sh; do [ -f \"$REPO_ROOT/skills/\$sc\" ] || exit 1; done"
check "22. it refuses a script that is not in this clone (no silent no-op)" \
  "! LCARS_ECH_CWD='$ap_repo277' bash '$AP277' exec lcars-nope/nope.sh >/dev/null 2>&1"
check "22. it refuses an out-of-tree path" \
  "! LCARS_ECH_CWD='$ap_repo277' bash '$AP277' exec ../../../etc/passwd >/dev/null 2>&1"
check "22. the driver documents \`exec\` in its own usage" \
  "printf '%s' \"\$ap22usage\" | qgrep -qF 'exec <skill>/<script>'"

# ==========================================================================
# S277 round 1 — THE THREE THINGS THE FRESH TESTER PROVED STILL BROKEN
#
# Round 0 converted the handful of lines its brief listed and covered the other
# ~59 with a NOTE at the top of HOLOGRAM-COMMAND-MODE.md ("a bare `ech.sh <verb>` is
# shorthand for `lcars-ech <verb>`"). A fresh tester then ran real Copilot
# turns on a copilot-only PATH and the note did not hold, FOUR times out of four
# framings — including the navigation HOLOGRAM-COMMAND-MODE.md itself prescribes ("ask the
# driver what to do next, then read that section"), which lands the reader in
# § 8/§ 9 having never seen line 28. Each time the model ran the bare line
# verbatim, took exit 127 and STOPPED. Prose a reader may legitimately never see
# cannot carry a correction; the only durable form is the command written out.
#
# These three groups are the regression guards for that, for the same bug in the
# DRIVER's own output (which had no note anywhere near it), and for the one
# branch of the "not installed here" sentence round 0's own fix missed.
# ==========================================================================

# --- 23. D1: no document hands the model a bare `ech.sh <verb>` ----
# The shape is "the word ech.sh, not preceded by a path separator or
# another word character, followed by a verb" — i.e. something a model would
# type as a command. A PATH-QUALIFIED mention (.../skills/lcars-eeh/
# ech.sh) is deliberately still allowed: that one resolves, and it is the
# documented no-PATH fallback.
D1BARE='(^|[^/[:alnum:]_.-])ech\.sh[[:space:]]+[a-z]'
check "23. HOLOGRAM-COMMAND-MODE.md hands the model NO bare \`ech.sh <verb>\`" \
  "! grep -qE \"\$D1BARE\" '$AUTOP277'"
check "23. SKILL.md hands the model NO bare \`ech.sh <verb>\`" \
  "! grep -qE \"\$D1BARE\" '$SKILL_MD277'"
check "23. ORCHESTRATION.md hands the model NO bare \`ech.sh <verb>\`" \
  "! grep -qE \"\$D1BARE\" '$ORCH277'"
# And no NOTE may stand in for writing the command out — that is the exact
# mechanism that failed. If a future edit reintroduces a shorthand/alias note,
# this fails even if the bare form is momentarily absent.
check "23. no \"shorthand\"/\"is short for\" note stands in for the real command" \
  "! grep -qiE 'is shorthand for|short for .lcars-ech|abbreviation for' '$AUTOP277' '$SKILL_MD277' '$ORCH277'"
# POSITIVE CONTROLS — the prohibition must not be satisfiable by deleting the
# commands. The playbook is ~660 lines of runnable driver calls; they are all
# written out, and the DEEPEST one (the tester reached line 657) is too.
check "23. CONTROL: HOLOGRAM-COMMAND-MODE.md writes \`lcars-ech\` out dozens of times" \
  "[ \"\$(grep -c 'lcars-ech ' '$AUTOP277')\" -ge 40 ]"
# S301: the token this greps had to change with the rename. It used to be one
# bare word that appeared in every spelling of the driver's old name, so grepping
# it caught them all. The driver is `ech` now, and a bare `ech` would also match
# "check", "mechanism" and "echo" — so the token is the two real driver spellings
# instead. The assertion itself is unchanged: whichever way the file names the
# driver LAST, it must be the on-PATH form.
check "23. CONTROL: the LAST driver mention in the file is the on-PATH form" \
  "grep -nE 'ech\\.sh|lcars-ech' '$AUTOP277' | tail -1 | qgrep -q 'lcars-ech'"
# The three deep sections the tester was dropped into by name, each proved to
# carry a runnable command on its own, with no reliance on the top of the file.
check "23. § 8's heartbeat line is runnable where a jumped-to reader finds it" \
  "grep -qE '^lcars-ech heartbeat install' '$AUTOP277'"
check "23. § 9's \`ask\` example is runnable where a jumped-to reader finds it" \
  "grep -qE '^lcars-ech ask ' '$AUTOP277'"
check "23. \`status\`/\`next\`, the two the driver's own PLAYBOOK sends you to, are runnable" \
  "grep -qE '^lcars-ech status' '$AUTOP277' && grep -qF 'lcars-ech next' '$AUTOP277'"
# The fallback is a FALLBACK: path-qualified, so it cannot be copied as a bare
# command, and present, so a no-PATH reader is not left with nothing.
check "23. the no-PATH fallback is named, and only in path-qualified form" \
  "grep -qF 'skills/lcars-eeh/ech.sh' '$AUTOP277'"

# --- 24. D2: the DRIVER's own output names a command that resolves --------
# `lcars-ech init` used to end with "record the answers with
# `ech.sh record liveTargets.host <host>`". A real Copilot turn told to
# follow it ran exactly that, took exit 127, and recorded nothing — the FIRST
# step after init on a fresh machine. `--help`'s header had the same bug, so the
# driver misnamed itself to every reader on both CLIs. No note was anywhere near
# either: these strings are produced at runtime.
AP277_D2="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"
# STRUCTURAL: comments are not output, so they are excluded (and left alone on
# purpose — they document the file by its real name). Nothing else in the script
# may carry the literal.
check "24. no NON-COMMENT line in the driver carries the \`ech.sh\` literal" \
  "[ \"\$(grep -vE '^[[:space:]]*#' '$AP277_D2' | grep -c 'ech\.sh')\" -eq 0 ]"
check "24. CONTROL: the comments DO still name the file (nothing was blanket-renamed)" \
  "[ \"\$(grep -cE '^[[:space:]]*#.*ech\.sh' '$AP277_D2')\" -ge 1 ]"
# BEHAVIOURAL: the two surfaces the tester and the brief named, plus the whole
# of init's closing advice, must name the on-PATH command.
d24repo="$(mktemp -d "$TMPROOT/d24.XXXX")"
( cd "$d24repo" && git init -q 2>/dev/null )
printf 'M0: a thing\n' >"$d24repo/spec.md"
d24help="$(bash "$AP277_D2" --help 2>&1 || true)"
# S300: `</dev/null`, the same hygiene tests/lcars-ech.test.sh's
# `ap()` has always applied. `init` now ends by asking its setup questions on
# the terminal, and harness.test.sh runs this suite from a pty with stdin OPEN
# on purpose — so without the redirect this one line borrowed that terminal and
# took the whole suite from 5.9s to the cage's 120s kill. What is asserted below
# is unchanged; only the invocation's stdin is.
d24init="$(LCARS_ECH_CWD="$d24repo" bash "$AP277_D2" init --spec "$d24repo/spec.md" --scope M0 2>&1 </dev/null || true)"
d24bare="$(mktemp -d "$TMPROOT/d24b.XXXX")"; ( cd "$d24bare" && git init -q 2>/dev/null )
d24state="$(LCARS_ECH_CWD="$d24bare" bash "$AP277_D2" status 2>&1 || true)"
d24ask="$(LCARS_ECH_CWD="$d24repo" bash "$AP277_D2" ask 2>&1 || true)"
check "24. \`--help\` names the driver as the reader must TYPE it" \
  "printf '%s' \"\$d24help\" | qgrep -qE '^Usage: lcars-ech '"
check "24. \`init\`'s closing \"record the answers with\" step is a resolvable command" \
  "printf '%s' \"\$d24init\" | qgrep -qF 'lcars-ech record liveTargets.host'"
check "24. and init's output carries NO \`ech.sh <verb>\` anywhere" \
  "! printf '%s' \"\$d24init\" | qgrep -qE \"\$D1BARE\""
check "24. the no-state error names a resolvable command" \
  "printf '%s' \"\$d24state\" | qgrep -qF 'lcars-ech init --spec' && ! printf '%s' \"\$d24state\" | qgrep -qE \"\$D1BARE\""
check "24. \`ask\`'s own usage line names a resolvable command" \
  "printf '%s' \"\$d24ask\" | qgrep -qE '^ *lcars-ech ask ' && ! printf '%s' \"\$d24ask\" | qgrep -qE \"\$D1BARE\""
# DERIVED, NOT HARD-CODED: the printed name follows how the process was
# invoked, so it cannot drift from the front door again. $LCARS_SELF_CMD is the
# seam that proves the name is a variable and not 20 literals.
# Both producers exit 1 (usage, and a missing autopilot.json), and this suite
# runs with `pipefail`, so the output is captured FIRST — piping it live would
# report the PRODUCER's exit code and fail a passing assertion.
d24help2="$(LCARS_SELF_CMD=zzz-driver bash "$AP277_D2" --help 2>&1 || true)"
d24state2="$(LCARS_SELF_CMD=zzz-driver LCARS_ECH_CWD="$d24bare" bash "$AP277_D2" status 2>&1 || true)"
check "24. the printed name FOLLOWS the invoked name (it is derived, not a literal)" \
  "printf '%s' \"\$d24help2\" | qgrep -qE '^Usage: zzz-driver ' && printf '%s' \"\$d24state2\" | qgrep -qF 'zzz-driver init --spec'"
# The python leg writes its own messages; it must follow the same name.
d24ans="$(LCARS_SELF_CMD=zzz-driver LCARS_ECH_CWD="$d24repo" bash "$AP277_D2" answered q-nope "x" 2>&1 || true)"
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
LCARS_REPO="$c25" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
check "25. no unscoped \"not installed here\" sentence survives in eeh.sh at all" \
  "[ \"\$(grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -cF 'LCARS skills are not installed here')\" -eq 0 ]"
# And the honest-absence case still reports absence — the cure must not have
# silenced a true warning. Both farms empty, Claude installed: still a fault.
out25b="$TMPROOT/out25b.txt"
LCARS_REPO="$c25" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
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
# D1 (§ 23) banned a bare `ech.sh <verb>`. `xo.sh` is the identical bug
# with a different script: § 6 told the reader to read Number One's verdict with
# a bare `xo.sh report`, which is exit 127 on BOTH CLIs — no LCARS script is
# ever on PATH under its own name. The cure is the driver's own `exec` seam,
# which resolves a sibling script from THIS clone under either install mount.
# Same shape as $D1BARE: a path-qualified mention (lcars-xo/xo.sh) is fine,
# because that one is an `exec` argument and not a command.
D4BARE='(^|[^/[:alnum:]_.-])xo\.sh[[:space:]]+[a-z]'
check "26. HOLOGRAM-COMMAND-MODE.md hands the model NO bare \`xo.sh <verb>\`" \
  "! grep -qE \"\$D4BARE\" '$AUTOP277'"
check "26. SKILL.md hands the model NO bare \`xo.sh <verb>\`" \
  "! grep -qE \"\$D4BARE\" '$SKILL_MD277'"
check "26. ORCHESTRATION.md hands the model NO bare \`xo.sh <verb>\`" \
  "! grep -qE \"\$D4BARE\" '$ORCH277'"
# POSITIVE CONTROL — the ban must not be satisfiable by DELETING the
# instruction. The reader must still be told to read the verdict, via `exec`.
check "26. CONTROL: HOLOGRAM-COMMAND-MODE.md still tells the reader to read the XO report" \
  "qgrep -qF 'lcars-ech exec lcars-xo/xo.sh report' '$AUTOP277'"
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
d26out="$(LCARS_ECH_CWD="$d26repo" bash "$AP277_D2" exec lcars-xo/xo.sh report 2>&1 || true)"
check "26. running that exact form REACHES xo.sh (its OWN report output comes back)" \
  "printf '%s' \"\$d26out\" | qgrep -qE 'Since you last looked|History:'"
check "26. and it is not a not-found refusal of any kind" \
  "! printf '%s' \"\$d26out\" | qgrep -qiE 'no such script|command not found|No such file|not a git repository'"
# CONTROL — the pair must be able to FAIL, so the same form with a script that
# does not exist has to be refused by name. The refusal EXITS 1 and this suite
# runs with `pipefail`, so the output is captured FIRST (see the same note in
# § 24): piping it live would report the PRODUCER's code, not the grep's.
d26bog="$(LCARS_ECH_CWD="$d26repo" bash "$AP277_D2" exec lcars-xo/nope.sh report 2>&1 || true)"
check "26. CONTROL: a BOGUS script in the same form IS refused (the check can fail)" \
  "printf '%s' \"\$d26bog\" | qgrep -qF 'no such script'"

# --- 27. D5: `--help`'s verb list says HOW to run what it lists -----------
# The block headed "THE VERBS THIS DRIVES" lists tokens like
# `lcars-file/file.sh --prd <path>`. NONE of them is a runnable command: each
# runs ONLY as `lcars-ech exec <skill>/<script>`. The header never said
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
  "printf '%s' \"\$d27hdr\" | qgrep -qF 'lcars-ech exec'"
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
# S303: AND THAT SENTENCE IS THE ONLY WAY THE VARIABLE MAY APPEAR — as a fact
# about what copilot refuses, never as a thing the seat is told to arrange. The
# preflight stopped REQUIRING `COPILOT_ALLOW_ALL=true` (S303 measured a seat
# strip it from 21 child calls and still ship), because demanding it is what
# made a Claude seat's own safety classifier block the brief for instructing it
# to self-grant trust, and made a GPT seat refuse on policy. The trust section
# above the command section stays — the ordering check needs it and the fact is
# still worth explaining — but it may not hand out the export line.
d28trustsec="$(sed -n '/^## Unattended Copilot setup:/,/^## Unattended Copilot commands:/p' "$AUTOP277")"
check "28b the trust setup section does NOT instruct the seat to export the variable" \
  "! printf '%s' \"\$d28trustsec\" | qgrep -qF 'export COPILOT_ALLOW_ALL'"
check "28b it says instead that no blanket trust is required" \
  "printf '%s' \"\$d28trustsec\" | qgrep -qi 'does not require' && printf '%s' \"\$d28trustsec\" | qgrep -qi 'blanket trust'"
check "28b CONTROL: that section was really extracted (not a vacuous empty match)" \
  "[ \"\$(printf '%s\\n' \"\$d28trustsec\" | grep -c .)\" -ge 5 ]"
check "28b CONTROL: and the whole file still carries the export line nowhere at all" \
  "! qgrep -qF 'export COPILOT_ALLOW_ALL' '$AUTOP277'"
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

# ==========================================================================
# S301 — THE EMERGENCY ENGINEERING HOLOGRAM ANNOUNCEMENT
# ==========================================================================
# The EEH IS the EEH now. Its brief already opened with a one-line banner on
# STDOUT (the brief is for a human to read, so stdout is right here), so this is
# a rename of that line's prose and nothing else: same stream, same position,
# same single line. The two checks below pin the two halves the captain asked
# for — the name, and the question — so the banner cannot drift back to a
# generic title or lose the prompt.
out301="$TMPROOT/out301.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" bash "$SCRIPT" >"$out301" 2>&1
check "S301. announces itself as the Emergency Engineering Hologram" \
  "qgrep -q 'Emergency Engineering Hologram' '$out301'"
check "S301. asks the nature of the engineering emergency" \
  "qgrep -qi 'nature of the engineering emergency' '$out301'"
check "S301. the announcement is the FIRST line of the brief" \
  "head -3 '$out301' | qgrep -q 'Emergency Engineering Hologram'"
check "S301. the old EEH banner prose is gone" \
  "! qgrep -q 'ride along, get the detail' '$out301'"

# ==========================================================================
# S301 fix round 1 — AN OFF SWITCH FOR THE ANNOUNCEMENT
# ==========================================================================
# The ECH got both a tty gate and `LCARS_ECH_QUIET`; the EEH's banner had
# neither. It stays on STDOUT and in place — it was already there before the
# rename ("LCARS BUDDY — ride along…"), so moving it would be a behaviour
# change rather than a rename — but a human in a loop can now turn it off.
#
# It is a VALUE check, not a presence check, and that is the whole point of
# cases 2 and 3: `LCARS_EEH_QUIET=0` means "not quiet". A `-z`-style presence
# test would silence the banner for ANY non-empty value and hand somebody who
# wrote `=0` the exact opposite of what they asked for. Only the literal `1`
# is quiet, the same idiom `LCARS_BASE_QUIET` already uses in this repo.
qout301="$TMPROOT/qout301.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" LCARS_EEH_QUIET=1 \
  bash "$SCRIPT" >"$qout301" 2>&1
check "S301-fix1. LCARS_EEH_QUIET=1 silences the announcement" \
  "! qgrep -q 'Emergency Engineering Hologram' '$qout301'"
check "S301-fix1. LCARS_EEH_QUIET=1 still prints the brief itself" \
  "qgrep -q 'LCARS REPO:' '$qout301'"

z301="$TMPROOT/z301.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" LCARS_EEH_QUIET=0 \
  bash "$SCRIPT" >"$z301" 2>&1
check "S301-fix1. LCARS_EEH_QUIET=0 means NOT quiet (a value check, not presence)" \
  "qgrep -q 'Emergency Engineering Hologram' '$z301'"

y301="$TMPROOT/y301.txt"
LCARS_REPO="$LCARS" GIT_BIN="$GIT_STUB" LCARS_EEH_CWD="$(new_plain_dir)" \
  LCARS_SKILLS_DEST="$(new_plain_dir)" LCARS_EEH_QUIET=yes \
  bash "$SCRIPT" >"$y301" 2>&1
check "S301-fix1. only the literal 1 is quiet (=yes does not silence it)" \
  "qgrep -q 'Emergency Engineering Hologram' '$y301'"

# ==========================================================================
# S301 fix round 1 — THE SKILL DESCRIPTION IS ROUTING, NOT DECORATION
# ==========================================================================
# The rename emptied this skill's frontmatter `description:` of every natural-
# language hook it had: Hologram 0, hologram 0, Emergency 0, Engineering 0,
# buddy 0 — leaving only the bare acronym `EEH` and the literal `lcars eeh`.
# Skill routing is driven by that text, so the product announced itself as the
# Emergency Engineering Hologram on every run while a captain asking for "the
# engineering hologram" matched nothing. `buddy` matters in particular: that
# is the word he actually says, and the command rename must not take his
# phrasing away from him. `ride-along` is the other alias he uses.
#
# desc() folds the `>-` block exactly as a CLI does, so these assertions read
# the string the router sees, not the way the file is wrapped.
desc() {
  python3 - "$1" <<'DESCPY'
import io, re, sys
fm = io.open(sys.argv[1], encoding='utf-8').read().split('---')[1]
out, on = [], False
for ln in fm.splitlines():
    if re.match(r'^description:\s*>-?\s*$', ln):
        on = True
        continue
    if on:
        if ln.startswith('  '):
            out.append(ln.strip())
        elif ln.strip() == '':
            continue
        else:
            break
print(' '.join(out))
DESCPY
}

# missing_words <text> <word>... — the listed words NOT present in <text>.
# Case-sensitive on purpose: "Hologram" and "hologram" are different hooks.
missing_words() {
  local t="$1"; shift
  local w out=""
  for w in "$@"; do
    case "$t" in *"$w"*) : ;; *) out="$out $w" ;; esac
  done
  printf '%s' "$out"
}

eehd="$(desc "$REPO_ROOT/skills/lcars-eeh/SKILL.md")"
echd="$(desc "$REPO_ROOT/skills/lcars-ech/SKILL.md")"
check "S301-fix1. desc() actually read the EEH description (not vacuous)" \
  "[ \"\${#eehd}\" -gt 300 ]"
eeh_missing="$(missing_words "$eehd" Emergency Engineering Hologram hologram buddy ride-along 'lcars eeh')"
check "S301-fix1. the EEH description carries its in-character words and the buddy alias" \
  "[ -z \"\$eeh_missing\" ] || { echo \"missing:\$eeh_missing\"; false; }"
check "S301-fix1. the description reads like English, not an acronym in a noun slot" \
  "! printf '%s' \"\$eehd\" | qgrep -qF 'ride-along EEH' && ! printf '%s' \"\$eehd\" | qgrep -qF 'an EEH around'"
check "S301-fix1. the folded description stays inside the strict reader's 1024 cap" \
  "[ \"\${#eehd}\" -le 1024 ]"

# CONTROL 1 — the ECH description, which already carried these words (the
# tester graded it Hologram x4, Emergency x1). If the predicate below were
# broken, this would fail too. Its word list is the ECH's own in-character
# vocabulary, not the EEH's: the ECH spells "Hologram Command Mode" as a
# proper noun throughout and has no lower-case "hologram" to find.
ech_missing="$(missing_words "$echd" Emergency Hologram 'Hologram Command Mode' 'lcars ech')"
check "S301-fix1. CONTROL: the ECH description passes the same predicate" \
  "[ -z \"\$ech_missing\" ] || { echo \"missing:\$ech_missing\"; false; }"
# CONTROL 2 — the predicate must go RED on an acronym-only description, so a
# green run above cannot be a check that matches anything.
stripped301='Your LCARS ride-along EEH — a companion in ANY repo. Use when the captain runs `lcars eeh`.'
ctl301="$(missing_words "$stripped301" Emergency Engineering Hologram hologram buddy)"
check "S301-fix1. CONTROL: the predicate goes RED on an acronym-only description" \
  "[ -n \"\$ctl301\" ]"

# ==========================================================================
# S306 — THE FOUR PERMISSION STALLS THE PLAYBOOK ITSELF CAUSED
#
# MEASURED LIVE, 2026-10-19. One ECH seat (`copilot --model auto`) STOPPED FOUR
# TIMES on permission dialogs nothing in an unattended run can answer. All four
# causes were in HOLOGRAM-COMMAND-MODE.md, not in the product:
#
#   1. § 6.1 REQUIRES driving real headless Chrome, and the launch grant named
#      NO browser at all. The seat asked for
#      `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`, was
#      refused, and then WORKED DOWN A LIST — asking again for
#      `/Applications/Chromium.app/Contents/MacOS/Chromium`.
#   2. The seat composed its own shell command ("Inspect repository files and
#      permitted evidence directories") containing a `..` parent traversal,
#      which the shell resolves before any grant is checked, so it fell outside
#      every approved root. It came from a command the MODEL composed, which is
#      exactly why a prompt rule is the right lever.
#   3. § 6.1's live-check item said "run `--help` and bad input" and said
#      nothing about WHERE. The seat fed the product `/missing`. A path that
#      does not exist is outside every grant BY DEFINITION — no `--add-dir` can
#      ever cover it — so that item was a GUARANTEED stall. The cure is not a
#      grant; it is saying the invalid path must sit inside an ALREADY-APPROVED
#      folder, which tests the same behaviour and raises nothing.
#   4. One seat filed its mission titled literally `## Mission title` — on disk
#      AND as the public GitHub issue title. The string appears nowhere in
#      skills/, so the model pasted the playbook's own field label back as the
#      value. Six of seven seats got it right: a one-in-seven leak with a
#      public consequence.
#
# WHAT IS MEASURED HERE, and what is not. This is a DOC test, which is the
# classic "infer instead of record" trap in this repo, so it is built two ways
# against that. (a) The launch grant is not grepped for a sentence: the fenced
# block is EXTRACTED, its backslash continuations JOINED so each command is one
# real argv line, its `--add-dir` VALUES parsed out as tokens, and the block's
# own PRELUDE (the variable assignments a reader runs first) EXECUTED inside a
# throwaway `git init` repo so `$LAUNCH_ROOT`, `$LAUNCHER_DIR` and the new
# `$BROWSER_DIR` resolve to real paths, compared with `pwd -P` on both sides.
# (b) Every predicate carries a control that makes it FAIL: the prose ones are
# run against the PRE-CHANGE playbook pinned to the literal commit below (not
# HEAD — a HEAD-pinned control in the sibling suite went stale the instant its
# own change landed), and the $HOME one against a COPY with a bare `$HOME`
# grant INJECTED into it.
# WHAT IT DOES NOT ESTABLISH: that any seat stalls less. Only a seat can
# measure that; the four stalls above are that measurement, not this test.
# ==========================================================================

S306_PB="$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"
S306_BASE_SHA="2a0678f"
S306_PREV="$TMPROOT/hocm-prev-s306.md"
( cd "$REPO_ROOT" && git show "$S306_BASE_SHA:skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md" ) >"$S306_PREV" 2>/dev/null || :

# s306_sec <file> <start-re> <end-re> — one markdown section of that file.
s306_sec() { awk -v s="$2" -v e="$3" '$0 ~ s {f=1} f && $0 ~ e {exit} f' "$1"; }
# s306_fence <file> — the first fenced ```bash block of the launch-setup section.
s306_fence() {
  s306_sec "$1" '^## Unattended Copilot setup' '^## Unattended Copilot commands' \
    | awk '/^```bash$/{g=1;next} g&&/^```$/{exit} g{print}'
}
# s306_join <text> — comments dropped, backslash continuations joined, so each
# command becomes ONE logical line (real argv).
s306_join() {
  printf '%s\n' "$1" | sed 's/[[:space:]]*#.*$//' | awk '
    { line = $0
      sub(/^[[:space:]]+/, "", line)
      if (buf != "") buf = buf " " line; else buf = line
      if (buf ~ /\\$/) { sub(/[[:space:]]*\\$/, "", buf); next }
      if (buf != "") print buf
      buf = "" }'
}
# s306_add_dirs <file> <cli> — every --add-dir VALUE on that cli's launch line.
s306_add_dirs() {
  s306_join "$(s306_fence "$1")" | grep -E "^$2([[:space:]]|$)" \
    | tr ' ' '\n' | awk 'p=="--add-dir" && $0!=""{print} {p=$0}'
}
# s306_prelude <file> — the fence's lines BEFORE the first CLI invocation: the
# setup a reader runs so the grant tokens mean something.
s306_prelude() { s306_fence "$1" | awk '/^(copilot|claude)[[:space:]]/{exit} {print}'; }
# s306_resolve <file> <cli> — each --add-dir token resolved through `pwd -P`,
# with the prelude EXECUTED first inside a throwaway git repo (so nothing is
# created beside the real checkout). Placeholders (`<...>`) are skipped.
s306_resolve() {
  local f="$1" cli="$2" box scr t
  box="$(mktemp -d "$TMPROOT/s306box.XXXXXX")"
  ( cd "$box" && git init -q . >/dev/null 2>&1 ) || return 0
  scr="$TMPROOT/s306-resolve.sh"
  {
    printf 'cd %s || exit 1\n' "$box"
    s306_prelude "$f"
    while IFS= read -r t; do
      case "$t" in *'<'*|'') continue ;; esac
      printf 'p=$(printf "%%s" %s); [ -n "$p" ] && [ -d "$p" ] && ( cd "$p" && pwd -P )\n' "$t"
    done <<S306EOF
$(s306_add_dirs "$f" "$cli")
S306EOF
  } >"$scr"
  bash "$scr" 2>/dev/null
}

S306_COP="$(s306_add_dirs "$S306_PB" copilot)"
S306_CLA="$(s306_add_dirs "$S306_PB" claude)"
echo "    [S306 copilot grant] $(printf '%s' "$S306_COP" | tr '\n' ' ')"
echo "    [S306 claude  grant] $(printf '%s' "$S306_CLA" | tr '\n' ' ')"
echo "    [S306 copilot resolved] $(s306_resolve "$S306_PB" copilot | tr '\n' ' ')"

# --- S306-1. THE GRANT BLOCK NAMES A BROWSER DIRECTORY --------------------
# Structure + a load-bearing literal, not a phrase match: the token must be on
# BOTH launch lines, the prelude must ASSIGN it by a runtime CHECK (`-x`, not a
# bare path), and when the prelude is EXECUTED the token must resolve to a real
# directory. A mere mention of "Chrome" in the prose cannot satisfy any of them.
check "S306-1. the copilot launch grant carries a browser-directory token" \
  "printf '%s\n' \"\$S306_COP\" | qgrep -qxF '\"\$BROWSER_DIR\"'"
check "S306-1. the claude launch grant carries it too" \
  "printf '%s\n' \"\$S306_CLA\" | qgrep -qxF '\"\$BROWSER_DIR\"'"
check "S306-1. the prelude ASSIGNS BROWSER_DIR (so the token is not dangling)" \
  "s306_prelude '$S306_PB' | qgrep -qE '^BROWSER_DIR='"
check "S306-1. and it is resolved BY A CHECK, not a hardcoded path (-x test over a candidate list)" \
  "s306_prelude '$S306_PB' | qgrep -qF -- '-x' && s306_prelude '$S306_PB' | qgrep -qE '^(for|[[:space:]]*for) '"
check "S306-1. no grant token is a hardcoded /Applications literal" \
  "! printf '%s\n' \"\$S306_COP\" \"\$S306_CLA\" | qgrep -qE '^\"?/Applications'"
S306_RES="$(s306_resolve "$S306_PB" copilot)"
S306_BDIR="$( { printf 'cd %s\n' "$TMPROOT"; s306_prelude "$S306_PB"; printf 'printf "%%s" "$BROWSER_DIR"\n'; } | bash 2>/dev/null )"
echo "    [S306 BROWSER_DIR on this host] ${S306_BDIR:-<empty>}"
check "S306-1. BROWSER_DIR resolves to a real directory on this host" \
  "[ -n '$S306_BDIR' ] && [ -d '$S306_BDIR' ]"
check "S306-1. and the resolved browser directory is among the copilot grants" \
  "printf '%s\n' \"\$S306_RES\" | qgrep -qxF \"\$(cd '$S306_BDIR' && pwd -P)\""
# This host HAS /Applications/Google Chrome.app and has NO Chromium (measured
# 2026-10-19), so the check must pick Chrome here. Guarded, because the playbook
# ships to strangers and a machine without it must not fail this suite.
if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  check "S306-1. on a host with Google Chrome the check picks Google Chrome" \
    "[ '$S306_BDIR' = '/Applications/Google Chrome.app/Contents/MacOS' ]"
fi
# CONTROL — the PRE-CHANGE playbook granted no browser at all.
check "S306-1. CONTROL: the pre-change playbook is readable at $S306_BASE_SHA" \
  "[ -s '$S306_PREV' ]"
check "S306-1. CONTROL: and its grant is a real, non-empty slice (the slicer works on it)" \
  "[ -n \"\$(s306_add_dirs '$S306_PREV' copilot)\" ]"
check "S306-1. CONTROL: the PRE-CHANGE copilot grant names NO browser directory" \
  "! printf '%s\n' \"\$(s306_add_dirs '$S306_PREV' copilot)\" | qgrep -qxF '\"\$BROWSER_DIR\"'"
check "S306-1. CONTROL: the pre-change prelude assigns no BROWSER_DIR either" \
  "! s306_prelude '$S306_PREV' | qgrep -qE '^BROWSER_DIR='"

# --- S306-2. THE PLAYBOOK SAYS WHICH BROWSER ------------------------------
# The stall was the seat WORKING DOWN A LIST. So the prose must (a) name one
# browser, (b) tie the instruction to the grant by naming the resolved variable
# — a literal that cannot drift away from the launch block without breaking —
# and (c) say the first match wins so no second name is tried.
S306_S6="$(s306_sec "$S306_PB" '^### 6\.1' '^### 6\.2')"
check "S306-2. § 6.1 slices non-empty" "[ -n \"\$S306_S6\" ]"
check "S306-2. § 6.1's browser item names Google Chrome by name" \
  "printf '%s\n' \"\$S306_S6\" | qgrep -qF 'Google Chrome'"
check "S306-2. and points at the SAME variable the launch grant resolved" \
  "printf '%s\n' \"\$S306_S6\" | qgrep -qF 'CHROME_BIN'"
check "S306-2. the candidate list puts Google Chrome FIRST" \
  "[ \"\$(s306_prelude '$S306_PB' | grep -o 'Google Chrome\|Chromium\|google-chrome\|chromium' | head -1)\" = 'Google Chrome' ]"
check "S306-2. the prelude says the first match wins (no working down the list)" \
  "s306_prelude '$S306_PB' | qgrep -qF 'break'"
check "S306-2. § 6.1 keeps its 400 px iframe recipe (the item was reworded, not dropped)" \
  "printf '%s\n' \"\$S306_S6\" | qgrep -qF '400' && printf '%s\n' \"\$S306_S6\" | qgrep -qiF 'iframe'"
check "S306-2. CONTROL: the pre-change § 6.1 named no browser to use" \
  "! printf '%s\n' \"\$(s306_sec '$S306_PREV' '^### 6\\.1' '^### 6\\.2')\" | qgrep -qF 'CHROME_BIN'"

# --- S306-4. BAD INPUT GOES INSIDE AN ALREADY-APPROVED FOLDER ------------
# Asserted on THE ITEM, not the section: the bullet is extracted by its own
# `--help` literal and folded, so a sentence elsewhere in § 6.1 cannot satisfy
# it. It must name an in-repo approved location AND state why an out-of-tree bad
# path can never be approved.
# The item is its own bullet plus its INDENTED continuation lines, and stops at
# the next bullet — so the item after it ("two actors, two HOMEs") can never
# make one of these checks pass by accident.
S306_BAD="$(printf '%s\n' "$S306_S6" \
  | awk '/^- run `--help`/{f=1; print; next} f{ if ($0 ~ /^  /) print; else exit }' \
  | tr '\n' ' ' | tr -s ' ')"
echo "    [S306 bad-input item] $S306_BAD"
check "S306-4. the bad-input item was found" \
  "printf '%s' \"\$S306_BAD\" | qgrep -qF -- '--help'"
check "S306-4. it requires the invalid input to sit INSIDE an approved folder" \
  "printf '%s' \"\$S306_BAD\" | qgrep -qiF 'inside' && printf '%s' \"\$S306_BAD\" | qgrep -qiF 'approved'"
check "S306-4. it gives an in-repo example under the already-granted scratch dir" \
  "printf '%s' \"\$S306_BAD\" | qgrep -qF '.git/lcars/tmp/'"
check "S306-4. and says why an out-of-tree bad path can NEVER be approved" \
  "printf '%s' \"\$S306_BAD\" | qgrep -qiF 'does not exist' && printf '%s' \"\$S306_BAD\" | qgrep -qiE 'outside every grant'"
check "S306-4. it still calls a subcommand missing from --help a defect" \
  "printf '%s' \"\$S306_BAD\" | qgrep -qiF 'is a defect'"
check "S306-4. CONTROL: the pre-change item said nothing about WHERE" \
  "! printf '%s\n' \"\$(s306_sec '$S306_PREV' '^### 6\\.1' '^### 6\\.2')\" | grep -F -- '- run \`--help\`' | qgrep -qiF 'approved'"

# --- S306-5. A MISSION TITLE IS A PLAIN SENTENCE -------------------------
S306_S4="$(s306_sec "$S306_PB" '^## 4\. File a milestone' '^## 4a\.')"
S306_S4F="$(printf '%s\n' "$S306_S4" | tr '\n' ' ' | tr -s ' ')"
check "S306-5. § 4 (the mission fields) slices non-empty" \
  "[ \"\$(printf '%s\n' \"\$S306_S4\" | grep -c .)\" -ge 8 ]"
check "S306-5. it says a mission title is a plain sentence" \
  "printf '%s' \"\$S306_S4F\" | qgrep -qiF 'plain sentence'"
check "S306-5. and never a markdown heading" \
  "printf '%s' \"\$S306_S4F\" | qgrep -qiF 'never a markdown heading'"
check "S306-5. nor the field label itself" \
  "printf '%s' \"\$S306_S4F\" | qgrep -qiF 'field label'"
check "S306-5. it names the measured leak and its public consequence" \
  "printf '%s' \"\$S306_S4F\" | qgrep -qF '2026-10-19' && printf '%s' \"\$S306_S4F\" | qgrep -qiF 'GitHub issue title'"
check "S306-5. the rule sits with the six required sections it governs" \
  "printf '%s' \"\$S306_S4F\" | qgrep -qF 'Acceptance Criteria'"
# The anti-example must be quoted INLINE, never as a real heading, or the
# playbook grows the very heading it forbids.
check "S306-5. the anti-example never starts a line (it would become a real heading)" \
  "! qgrep -qE '^##[[:space:]]+Mission title' '$S306_PB'"
check "S306-5. CONTROL: the pre-change § 4 carried no title rule" \
  "! printf '%s\n' \"\$(s306_sec '$S306_PREV' '^## 4\\. File a milestone' '^## 4a\\.')\" | tr '\n' ' ' | qgrep -qiF 'plain sentence'"

# --- S306-6. REGRESSION GUARD: \$HOME IS STILL REFUSED -------------------
# S305 bought this line and it must not quietly lapse while the grant grows. Two
# independent predicates: TEXTUAL (no token is a bare $HOME / ~ / /Users/<user>
# root) and RESOLVED (with the prelude executed, no granted directory CONTAINS
# $HOME). Line 73's `LAUNCHER_DIR="${LCARS_BIN_DEST:-$HOME/.local/bin}"` is a
# SUBDIRECTORY of $HOME and is legitimate: it is granted, $HOME is not, and both
# predicates below distinguish those two cases.
S306_HOME_REAL="$(cd "$HOME" && pwd -P)"
# s306_bare_home <file> -> yes|no. A grant token that IS a $HOME-ish root.
s306_bare_home() {
  { s306_add_dirs "$1" copilot; s306_add_dirs "$1" claude; } \
    | sed 's/^"//; s/"$//' \
    | grep -qE '^(\$HOME|\$\{HOME\}|~|/Users/[^/]+|/home/[^/]+)/?$' && echo yes || echo no
}
# s306_grants_home <file> <cli> -> yes|no. A RESOLVED grant that contains $HOME.
s306_grants_home() {
  local got d
  got="$(s306_resolve "$1" "$2")"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$S306_HOME_REAL/" in "$d"/*) echo yes; return ;; esac
  done <<S306EOF2
$got
S306EOF2
  echo no
}
check "S306-6. no grant token is a bare \$HOME root (textual)" \
  "[ \"\$(s306_bare_home '$S306_PB')\" = no ]"
check "S306-6. \$HOME is NOT granted to copilot (resolved)" \
  "[ \"\$(s306_grants_home '$S306_PB' copilot)\" = no ]"
check "S306-6. \$HOME is NOT granted to claude (resolved)" \
  "[ \"\$(s306_grants_home '$S306_PB' claude)\" = no ]"
check "S306-6. the launcher dir IS still granted — a \$HOME SUBdirectory is fine" \
  "printf '%s\n' \"\$S306_COP\" | qgrep -qxF '\"\$LAUNCHER_DIR\"' && s306_prelude '$S306_PB' | qgrep -qF 'LCARS_BIN_DEST'"
check "S306-6. and the launch lines still carry no blanket switch" \
  "! s306_join \"\$(s306_fence '$S306_PB')\" | qgrep -qE -- '--allow-all-paths|COPILOT_ALLOW_ALL=true|--dangerously-skip-permissions'"
# NEGATIVE CONTROL — inject a bare $HOME grant into a COPY (never the real
# file) and both predicates must go RED. Without this the green runs above
# could be checks that match anything.
S306_INJ="$TMPROOT/hocm-inject-home.md"
sed 's|^\(        --add-dir "\$LAUNCHER_DIR" \\\)$|\1\n        --add-dir "$HOME" \\|; s|^\(       --add-dir "\$LAUNCHER_DIR" \\\)$|\1\n       --add-dir "$HOME" \\|' \
  "$S306_PB" >"$S306_INJ"
check "S306-6. NEGATIVE CONTROL: the injected copy really gained a \$HOME grant line" \
  "[ \"\$(grep -c -- '--add-dir \"\$HOME\"' '$S306_INJ')\" -ge 1 ] && ! qgrep -qF -- '--add-dir \"\$HOME\"' '$S306_PB'"
check "S306-6. NEGATIVE CONTROL: the textual predicate goes RED on it" \
  "[ \"\$(s306_bare_home '$S306_INJ')\" = yes ]"
check "S306-6. NEGATIVE CONTROL: the resolved predicate goes RED on it (copilot)" \
  "[ \"\$(s306_grants_home '$S306_INJ' copilot)\" = yes ]"
check "S306-6. NEGATIVE CONTROL: and on claude" \
  "[ \"\$(s306_grants_home '$S306_INJ' claude)\" = yes ]"
check "S306-6. NEGATIVE CONTROL: the injection changed ONLY the grant (rest of file intact)" \
  "[ \"\$(diff '$S306_PB' '$S306_INJ' | grep -c '^>')\" -eq 2 ]"

# --- S306-7. THE LOCATION FOR cli ITEM 2's "a path that does not exist" ---
# EDIT 3 reworded § 6.1's own bad-input bullet (S306-4 above). That is not
# enough in EFFECT: the seat is ALSO printed `live-check/cli.md` verbatim, and
# its item 2 says "a path that does not exist" with no location at all —
# `skills/lcars-run/` is a different skill and was out of fence, so the cure has
# to be the playbook's own "and they never say WHERE, because they cannot know
# your repo. You do." mechanism, worked through for item 2 exactly as it is
# already worked through for item 4's `<throwaway-home-2>`.
# Asserted on THE PARAGRAPH, sliced by its own lead-in, so neither the § 6.1
# bullet S306-4 pins nor the item-4 paragraph can satisfy these by accident.
S306_INV="$(s306_sec "$S306_PB" '^The .*invalid path' '^Pick .*every.* type the milestone' | tr '\n' ' ' | tr -s ' ')"
echo "    [S306 item-2 paragraph] $S306_INV"
check "S306-7. the item-2 paragraph slices non-empty" \
  "[ -n \"\$S306_INV\" ]"
check "S306-7. it names the cli checklist ITEM 2 that has the gap" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'cli checklist item 2'"
check "S306-7. and says that item's bad path has no location in the checklist (item 4's gap, again)" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'no location in the checklist'"
check "S306-7. it quotes the checklist's own words so the reader can find the item" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'a path that does not exist'"
check "S306-7. it requires the invalid path to sit INSIDE an already-approved folder" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'inside' && printf '%s' \"\$S306_INV\" | qgrep -qiF 'already-approved folder'"
check "S306-7. it gives a concrete in-repo location under the granted scratch dir" \
  "printf '%s' \"\$S306_INV\" | qgrep -qF '.git/lcars/tmp/not-a-real-path'"
check "S306-7. it states the reason: outside the repo is outside every grant BY DEFINITION" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'outside every grant' && printf '%s' \"\$S306_INV\" | qgrep -qiF 'by definition'"
check "S306-7. ...so it is not a missing grant but a request that can NEVER be granted" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'can never be granted'"
check "S306-7. and that an invalid path inside an approved folder raises nothing" \
  "printf '%s' \"\$S306_INV\" | qgrep -qiF 'same error handling' && printf '%s' \"\$S306_INV\" | qgrep -qiF 'raises nothing'"
check "S306-7. it carries the measurement (a seat stopped on exactly this, 2026-10-19)" \
  "printf '%s' \"\$S306_INV\" | qgrep -qF '2026-10-19'"
# It has to be ALONGSIDE the item-4 paragraph, in the same local region, or a
# reader of that mechanism never meets it.
S306_L4="$(grep -n '^The \*\*second actor\*\*' "$S306_PB" | head -1 | cut -d: -f1)"
S306_L2="$(grep -n '^The \*\*invalid path\*\*' "$S306_PB" | head -1 | cut -d: -f1)"
echo "    [S306 item-4 para at line] ${S306_L4:-<none>}  [item-2 para at line] ${S306_L2:-<none>}"
check "S306-7. it sits immediately alongside the item-4 paragraph (within 30 lines)" \
  "[ -n '$S306_L4' ] && [ -n '$S306_L2' ] && [ \$(( ${S306_L2:-0} - ${S306_L4:-0} )) -gt 0 ] && [ \$(( ${S306_L2:-0} - ${S306_L4:-0} )) -le 30 ]"
# CONTROLS — one per claim above, all against the playbook PINNED to the
# literal base commit (not HEAD: a HEAD-pinned control goes stale the instant
# this change lands). Each shows the predicate was FALSE before, and that the
# slice it reads is a real, non-empty one.
check "S306-7. CONTROL: the pre-change playbook is readable at $S306_BASE_SHA" \
  "[ -s '$S306_PREV' ]"
check "S306-7. CONTROL: and its § 6.1 is a real, non-empty slice (the slicer works on it)" \
  "[ \"\$(s306_sec '$S306_PREV' '^### 6\\.1' '^### 6\\.2' | grep -c .)\" -ge 20 ]"
check "S306-7. CONTROL: the pre-change file carried the item-4 paragraph (so the style existed)" \
  "qgrep -qF 'The **second actor**' '$S306_PREV' && qgrep -qiF 'cli checklist item 4' '$S306_PREV'"
check "S306-7. CONTROL: ...but named cli checklist item 2 NOWHERE in the whole file" \
  "! qgrep -qiF 'cli checklist item 2' '$S306_PREV'"
check "S306-7. CONTROL: and the item-2 paragraph slice was EMPTY before" \
  "[ -z \"\$(s306_sec '$S306_PREV' '^The .*invalid path' '^Pick .*every.* type the milestone' | tr -d '[:space:]')\" ]"
check "S306-7. CONTROL: nowhere did it require an invalid path inside an already-approved folder" \
  "! qgrep -qiF 'already-approved folder' '$S306_PREV'"
check "S306-7. CONTROL: nor give an in-repo location for one" \
  "! qgrep -qF '.git/lcars/tmp/not-a-real-path' '$S306_PREV'"

# --- S306-8. THE FIFTH STALL: `/dev/null` IN A SELF-COMPOSED COMMAND -----
# MEASURED LIVE, 2026-10-19, a SECOND unattended Copilot seat. It ran the real
# pipeline for 20 minutes and did good work (mission filed, four tickets
# planned and closed, PR opened, Verify reached) and then froze on:
#
#     Allow path access
#     This action may read or write the following path outside
#     the paths currently allowed for this session.
#        /dev/null)
#
# Note the path: `/dev/null)` — WITH the closing parenthesis. The seat had
# composed `... 2>/dev/null)` inside a subshell, and the permission layer's path
# extractor took the `)` as part of the path. `/dev` was not in the launch grant
# at all. None of the four causes above fired: the browser was never refused and
# no `..` dialog appeared. This is a FIFTH, distinct cause.
#
# The cure is DELIBERATELY TWO CHANGES, and this block asserts both, because
# together they let the next run tell two explanations apart:
#   A. `/dev` is granted — a device directory every shell redirect touches.
#   B. A prompt rule: in a self-composed command, do not discard to
#      `/dev/null`; redirect to a file under `.git/lcars/tmp/`. B does not
#      depend on Copilot's extractor being correct; A does.
# WHAT THIS DOES NOT ESTABLISH: that a seat stalls less. Only a seat measures
# that. Controls are pinned to the LITERAL commit below, never HEAD.
S306_8_BASE_SHA="16a415b"
S306_8_PREV="$TMPROOT/hocm-prev-s306-8.md"
( cd "$REPO_ROOT" && git show "$S306_8_BASE_SHA:skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md" ) >"$S306_8_PREV" 2>/dev/null || :
S306_8_PRE="$(s306_prelude "$S306_PB" | tr '\n' ' ' | tr -s ' ')"

# --- HALF A: the launch grant names the device directory ------------------
check "S306-8A. the copilot launch grant carries /dev" \
  "printf '%s\n' \"\$S306_COP\" | qgrep -qxF '/dev'"
check "S306-8A. the claude launch grant carries it too" \
  "printf '%s\n' \"\$S306_CLA\" | qgrep -qxF '/dev'"
check "S306-8A. and it RESOLVES to a real directory on this host (not just a string)" \
  "printf '%s\n' \"\$(s306_resolve '$S306_PB' copilot)\" | qgrep -qxF '/dev'"
check "S306-8A. it sits with the system-toolchain entries, which are all still granted" \
  "printf '%s\n' \"\$S306_COP\" | qgrep -qxF '/usr/bin' && printf '%s\n' \"\$S306_COP\" | qgrep -qxF '/bin' && printf '%s\n' \"\$S306_COP\" | qgrep -qxF '/usr/sbin'"
check "S306-8A. the grant block's own comment names the device file every redirect touches" \
  "printf '%s' \"\$S306_8_PRE\" | qgrep -qF '/dev/null' && printf '%s' \"\$S306_8_PRE\" | qgrep -qiF 'redirect'"
check "S306-8A. it records the MALFORMED path the seat actually froze on (trailing paren)" \
  "printf '%s' \"\$S306_8_PRE\" | qgrep -qF '/dev/null)' && printf '%s' \"\$S306_8_PRE\" | qgrep -qF 'Allow path access'"
check "S306-8A. it justifies the grant the way the toolchain entries already do" \
  "printf '%s' \"\$S306_8_PRE\" | qgrep -qiF 'root-owned' && printf '%s' \"\$S306_8_PRE\" | qgrep -qiF 'system-managed'"
check "S306-8A. and states the TRADE-OFF: this grant may not match that string, hence two halves" \
  "printf '%s' \"\$S306_8_PRE\" | qgrep -qiF 'trade-off' && printf '%s' \"\$S306_8_PRE\" | qgrep -qiF 'may not match'"
# CONTROLS — pinned to the literal pre-change commit.
check "S306-8A. CONTROL: the pre-change playbook is readable at $S306_8_BASE_SHA" \
  "[ -s '$S306_8_PREV' ]"
check "S306-8A. CONTROL: and its copilot grant is a real, non-empty slice (the slicer works on it)" \
  "[ \"\$(s306_add_dirs '$S306_8_PREV' copilot | grep -c .)\" -ge 8 ]"
check "S306-8A. CONTROL: ...as is its claude grant" \
  "[ \"\$(s306_add_dirs '$S306_8_PREV' claude | grep -c .)\" -ge 7 ]"
check "S306-8A. CONTROL: the PRE-CHANGE copilot grant named NO /dev" \
  "! s306_add_dirs '$S306_8_PREV' copilot | qgrep -qxF '/dev'"
check "S306-8A. CONTROL: nor did the claude grant" \
  "! s306_add_dirs '$S306_8_PREV' claude | qgrep -qxF '/dev'"
check "S306-8A. CONTROL: the pre-change prelude is a real, non-empty slice" \
  "[ \"\$(s306_prelude '$S306_8_PREV' | grep -c .)\" -ge 10 ]"
# The pre-change file DID contain the string `/dev/null` — three times, all of
# them its OWN discards (two `command -v` chrome probes and the holodeck derive
# poll), never a grant and never an explanation. So the controls here are the
# dialog wording and the word `parenthesis`, which appeared NOWHERE.
check "S306-8A. CONTROL: ...whose only /dev/null was its own chrome-probe discard, not a grant" \
  "s306_prelude '$S306_8_PREV' | qgrep -qF '/dev/null' && ! s306_add_dirs '$S306_8_PREV' copilot | qgrep -qxF '/dev'"
check "S306-8A. CONTROL: and the pre-change file never EXPLAINED the malformed path (no 'parenthesis')" \
  "! qgrep -qiF 'parenthesis' '$S306_8_PREV'"

# --- HALF B: the prompt rule, in the playbook's own doctrine --------------
# Sliced by its OWN lead-in and bounded by the item-4 paragraph that follows,
# so neither the grant comment nor either worked-through case can satisfy these.
S306_DEV="$(s306_sec "$S306_PB" '^.*Never discard output' '^The .*second actor' | tr '\n' ' ' | tr -s ' ')"
echo "    [S306 /dev/null rule] $S306_DEV"
check "S306-8B. the /dev/null rule slices non-empty" \
  "[ -n \"\$S306_DEV\" ]"
check "S306-8B. it forbids discarding output to /dev/null in a command the seat composes itself" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qiF 'never discard output' && printf '%s' \"\$S306_DEV\" | qgrep -qF '/dev/null' && printf '%s' \"\$S306_DEV\" | qgrep -qiF 'compose yourself'"
check "S306-8B. and directs the output to a FILE under the in-repo scratch dir instead" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qF '.git/lcars/tmp/' && printf '%s' \"\$S306_DEV\" | qgrep -qiF 'instead'"
check "S306-8B. it states the measured reason: the path arrives as /dev/null) with the paren" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qF '/dev/null)' && printf '%s' \"\$S306_DEV\" | qgrep -qiF 'parenthesis'"
check "S306-8B. ...and names the construct that does it (a subshell or a command substitution)" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qiF 'subshell'"
check "S306-8B. ...and that the malformed string matches no grant, so no --add-dir can satisfy it" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qiF 'matches no grant' && printf '%s' \"\$S306_DEV\" | qgrep -qF -- '--add-dir'"
check "S306-8B. it says a real file under the scratch dir raises nothing" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qiF 'raises nothing'"
check "S306-8B. and keeps the side benefit: the output still exists for diagnosing" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qiF 'diagnosing'"
check "S306-8B. it carries the measurement (2026-10-19, the run that was over)" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qF '2026-10-19'"
check "S306-8B. and says WHY both halves exist: the /dev grant may not match the malformed string" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qF '/dev' && printf '%s' \"\$S306_DEV\" | qgrep -qiF 'may not match'"
# It has to sit in the same doctrine region as the two worked-through cases, or
# a reader of that mechanism never meets it. Before item 4's paragraph, so the
# general rule precedes the two specific cases.
S306_8_LD="$(grep -n 'Never discard output' "$S306_PB" | head -1 | cut -d: -f1)"
echo "    [S306 /dev/null rule at line] ${S306_8_LD:-<none>}  [item-4 para at line] ${S306_L4:-<none>}"
check "S306-8B. the rule sits immediately before the item-4 paragraph (within 20 lines)" \
  "[ -n '$S306_8_LD' ] && [ \$(( ${S306_L4:-0} - ${S306_8_LD:-0} )) -gt 0 ] && [ \$(( ${S306_L4:-0} - ${S306_8_LD:-0} )) -le 20 ]"
S306_8_LE="$(grep -n 'Everything you make yourself' "$S306_PB" | head -1 | cut -d: -f1)"
check "S306-8B. and it follows the 'everything you make yourself' doctrine it extends" \
  "[ -n '$S306_8_LE' ] && [ \$(( ${S306_8_LD:-0} - ${S306_8_LE:-0} )) -gt 0 ]"
# CONTROLS — one per claim, all against the pre-change file at the literal SHA.
check "S306-8B. CONTROL: the pre-change doctrine region is a real, non-empty slice" \
  "[ \"\$(s306_sec '$S306_8_PREV' '^.*Everything you make yourself' '^Pick .*every.* type the milestone' | grep -c .)\" -ge 20 ]"
check "S306-8B. CONTROL: ...and it carried the item-4 paragraph (so the voice existed)" \
  "qgrep -qF 'The **second actor**' '$S306_8_PREV'"
check "S306-8B. CONTROL: but the /dev/null rule's slice was EMPTY before" \
  "[ -z \"\$(s306_sec '$S306_8_PREV' '^.*Never discard output' '^The .*second actor' | tr -d '[:space:]')\" ]"
check "S306-8B. CONTROL: the pre-change file nowhere forbade discarding output" \
  "! qgrep -qiF 'never discard output' '$S306_8_PREV'"
check "S306-8B. CONTROL: nor explained the malformed /dev/null) path (the word appears nowhere)" \
  "! qgrep -qiF 'parenthesis' '$S306_8_PREV' && ! qgrep -qiF 'matches no grant' '$S306_8_PREV'"
check "S306-8B. CONTROL: the pre-change doctrine already said never a > target outside the repo..." \
  "qgrep -qiF 'target outside the repo' '$S306_8_PREV'"
check "S306-8B. CONTROL: ...so this is NOT that sentence read back — /dev/null is INSIDE no repo rule" \
  "! printf '%s\n' \"\$(s306_sec '$S306_8_PREV' '^.*Everything you make yourself' '^The .*second actor')\" | qgrep -qF '/dev'"

# --- HALF B, SECOND LEG: THE FILE OBEYS ITS OWN RULE ---------------------
# FOUND WHILE WRITING THIS TEST, not predicted: the pre-change playbook handed
# the seat the very construct the rule forbids. Its holodeck derive poll (§ 5,
# a recipe the seat runs VERBATIM) read `... 2>/dev/null)"` inside a `$(...)`,
# and the launch block's own chrome probes read `$(command -v google-chrome
# 2>/dev/null)`. A rule the file breaks four lines above itself is not a rule,
# so all three discards are gone: the poll's traceback guard is its `except`
# (which was always doing the work), and `command -v` is silent anyway.
S306_8_POLL="$(s306_sec "$S306_PB" '^for i in .*seq 1 90' '^case .st. in')"
S306_8_POLLP="$(s306_sec "$S306_8_PREV" '^for i in .*seq 1 90' '^case .st. in')"
check "S306-8B. no recipe in the playbook redirects to /dev/null any more" \
  "! qgrep -qE '[0-9]*>+[[:space:]]*/dev/null' '$S306_PB'"
check "S306-8B. and the rule SAYS the file obeys it, so a reader has nothing to copy" \
  "printf '%s' \"\$S306_DEV\" | qgrep -qiF 'obeys the rule' && printf '%s' \"\$S306_DEV\" | qgrep -qiF 'nothing here to copy'"
check "S306-8B. the chrome probes still PROBE (the discard went, the check stayed)" \
  "s306_prelude '$S306_PB' | qgrep -qF 'command -v google-chrome' && s306_prelude '$S306_PB' | qgrep -qF 'command -v chromium'"
check "S306-8B. the derive poll slice is real and keeps its traceback guard (the except)" \
  "[ \"\$(printf '%s\n' \"\$S306_8_POLL\" | grep -c .)\" -ge 8 ] && printf '%s\n' \"\$S306_8_POLL\" | qgrep -qF 'except Exception' && printf '%s\n' \"\$S306_8_POLL\" | qgrep -qF 'no-answer'"
check "S306-8B. ...and a comment that says not to add the discard back" \
  "printf '%s\n' \"\$(s306_sec '$S306_PB' '^#     READ THE REPLY DEFENSIVELY' '^for i in .*seq 1 90')\" | tr '\n' ' ' | qgrep -qiF 'do not' "
check "S306-8B. CONTROL: the PRE-CHANGE file carried exactly 3 such redirects" \
  "[ \"\$(grep -cE '[0-9]*>+[[:space:]]*/dev/null' '$S306_8_PREV')\" -eq 3 ]"
check "S306-8B. CONTROL: the pre-change derive poll is a real slice that DID discard" \
  "[ \"\$(printf '%s\n' \"\$S306_8_POLLP\" | grep -c .)\" -ge 8 ] && printf '%s\n' \"\$S306_8_POLLP\" | qgrep -qF '/dev/null'"
check "S306-8B. CONTROL: and its chrome probes DID discard too" \
  "s306_prelude '$S306_8_PREV' | qgrep -qF 'command -v google-chrome 2>/dev/null'"

# --- HALF C (the line not crossed): \$HOME IS STILL REFUSED --------------
# Re-run of S306-6's two predicates AFTER the grant grew by /dev. A regression
# guard, not a new cure — so its control is the injected copy from S306-6
# (which carries a bare \$HOME grant), not the pre-change file.
check "S306-8C. no grant token is a bare \$HOME root (textual), with /dev added" \
  "[ \"\$(s306_bare_home '$S306_PB')\" = no ]"
check "S306-8C. \$HOME is STILL not granted to copilot (resolved)" \
  "[ \"\$(s306_grants_home '$S306_PB' copilot)\" = no ]"
check "S306-8C. \$HOME is STILL not granted to claude (resolved)" \
  "[ \"\$(s306_grants_home '$S306_PB' claude)\" = no ]"
check "S306-8C. /dev does not CONTAIN \$HOME (the new token widens nothing)" \
  "case \"\$HOME/\" in /dev/*) false ;; *) true ;; esac"
check "S306-8C. and the launch lines still carry no blanket switch" \
  "! s306_join \"\$(s306_fence '$S306_PB')\" | qgrep -qE -- '--allow-all-paths|COPILOT_ALLOW_ALL=true|--dangerously-skip-permissions'"
check "S306-8C. NEGATIVE CONTROL: the \$HOME predicates still go RED on an injected copy" \
  "[ \"\$(s306_bare_home '$S306_INJ')\" = yes ] && [ \"\$(s306_grants_home '$S306_INJ' copilot)\" = yes ]"

# --- summary --------------------------------------------------------------
printf '\nlcars eeh: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
