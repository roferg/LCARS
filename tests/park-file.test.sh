#!/usr/bin/env bash
#
# Tests for `lcars file --park` / `--complete` (Park & Align, S136).
#
# The park lane files a mission from JUST the idea — no grill, no PRD, no
# estimate — parked at stage "align" with "prdPending": true. The complete lane
# runs the grill-completion later: validate the PRD, retitle + re-body the issue
# in place, add the type label, run the estimator, clear prdPending — landing
# byte-equivalent to a grill-first filing (idea.md the only extra artifact).
#
# All CLIs are stubbed (LCARS_GH_BIN / LCARS_GIT_BIN / LCARS_RUN_BIN); NO real
# worker is ever spawned — zero tokens.
#
# Usage: bash tests/park-file.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
# S128 — the precedence sentence a completed park's prd.md must carry, READ OUT
# OF THE DAEMON (web/lcars_serve/actions.py `_HANDOFF_PRECEDENCE`), which is its
# authority. Byte-exact pin, sourced rather than re-typed (FL-011: the two homes
# drifted and one prd.md ended up carrying both spellings).
PRECEDENCE="$(cd "$REPO_ROOT/web" 2>/dev/null && python3 -c 'import sys; sys.path.insert(0, "."); from lcars_serve.actions import _HANDOFF_PRECEDENCE as p; sys.stdout.write(p)' 2>/dev/null)"
RUN_SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh"
STATUS_SCRIPT="$REPO_ROOT/skills/lcars-status/status.sh"
LCARS_SCRIPT="$REPO_ROOT/skills/lcars/lcars.sh"
RESOLVE_SCRIPT="$REPO_ROOT/skills/lcars/resolve.sh"

# Disable the interactive version-check helper across the whole suite.
export LCARS_VERSION_CHECK_BIN="/nonexistent-version-check"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# qgrep: drain stdin fully before grepping (avoids pipefail SIGPIPE races).
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

# --- estimator stub: records its argv AND writes a minimal estimate.json ------
ESTIMATOR_STUB="$TMPROOT/estimate-run.sh"
cat >"$ESTIMATOR_STUB" <<'EOF'
#!/usr/bin/env bash
[ -n "${EST_LOG:-}" ] && echo "run.sh $*" >>"$EST_LOG"
mid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission) mid="${2:-}"; shift 2 ;;
    --mission=*) mid="${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
mdir="$gitdir/lcars/missions/$mid"
[ -d "$mdir" ] || exit 1
cat >"$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "low",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "sonnet", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
JSON
exit 0
EOF
chmod +x "$ESTIMATOR_STUB"
export LCARS_RUN_BIN="$ESTIMATOR_STUB"

# --- gh stub: records argv; `issue create` prints a URL (#42); `issue edit`
# records and exits 0. Captures a --body-file's contents to $GH_BODY when set. ---
make_gh_stub() {
  local p="$1"
  cat >"$p" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ -n "${GH_BODY:-}" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body-file" ]; then cat "$a" >"$GH_BODY"; fi
    prev="$a"
  done
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"
  exit 0
fi
exit 0
EOF
  chmod +x "$p"
}

# A git repo with .git/lcars/ scaffolded + an initial commit (so a mission can
# branch off it), matching how `lcars file` runs in a real repo.
#
# The initial commit's author/committer identity AND dates are PINNED, so every
# fixture repo's HEAD sha is byte-identical. The byte-equivalence checks below
# (park→complete vs grill-first) compare whole state.json files, and since S158
# those record the base branch's sha — an unpinned `git commit` would give two
# otherwise-identical fixtures two different shas and fail the diff for a reason
# that has nothing to do with the two lanes drifting apart.
# S196 — `cloneId` PINS THE FINGERPRINT so this suite's expected ids stay
# literal. Mission ids are now `lcars-YYYYMMDD-NNN-<fp>`, where <fp> is the
# first 4 hex of the clone's own `cloneId` (a UUID4 minted on first use, so two
# clones of one repo can never mint the same id — see lcars_clone_id in
# skills/lcars-init/lcars-common.sh). Pinning it makes <fp> the constant `c10e`;
# the lazy-acquisition and old-format-compatibility proofs live in
# tests/mission-id.test.sh.
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && GIT_AUTHOR_DATE="2026-05-30T00:00:00Z" GIT_COMMITTER_DATE="2026-05-30T00:00:00Z" \
         git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  # S183: a CONFIGURED test command, so this fixture is a repo with a test
  # FOUNDATION. `lcars file` now refuses to open a normal mission on a repo that
  # has none (greenfield/untested) and points at Establish Vision instead — so a
  # suite about the MECHANICS of filing has to file against a repo that can
  # actually be filed against. `true` resolves via `command -v`, which is all the
  # readiness verdict asks of a command. The gate itself is proven in
  # tests/foundation-gate.test.sh, against real repos in all four states.
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }
EOF
  echo "$repo"
}

write_prd() {
  cat >"$1" <<'EOF'
# Mission: Fix the broken /about route

**Type:** bug
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
- The About page renders its heading
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router; no new dependencies
EOF
}

# ==========================================================================
echo "lcars file --park / --complete"
[ -f "$FILE_SCRIPT" ] || { echo "script under test not found at $FILE_SCRIPT"; exit 1; }

# --- Behaviour 1: --park writes idea.md + prdPending state + no-type issue -----
repo1="$(new_repo)"; make_gh_stub "$repo1/gh"
export GH_LOG="$repo1/gh.log"; : >"$GH_LOG"
export GH_BODY="$repo1/gh-body.txt"; : >"$GH_BODY"
(
  cd "$repo1"
  LCARS_GH_BIN="$repo1/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --park "Make the leaderboard sortable by streak length" >out.txt 2>&1
)
M1="$repo1/.git/lcars/missions/lcars-20260530-001-c10e"
check "1. parks the mission dir"              "[ -d '$M1' ]"
check "1. writes idea.md verbatim"            "grep -qF 'Make the leaderboard sortable by streak length' '$M1/idea.md'"
check "1. state.json marks prdPending true"   "grep -q '\"prdPending\": *true' '$M1/state.json'"
check "1. state.json stage is align"          "grep -q '\"stage\": *\"align\"' '$M1/state.json'"
check "1. state.json has NO type field yet"   "! grep -q '\"type\"' '$M1/state.json'"
check "1. state.json is valid JSON"           "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M1/state.json'"
check "1. NO prd.md is written when parking"  "[ ! -f '$M1/prd.md' ]"
check "1. NO estimate.json when parking"      "[ ! -f '$M1/estimate.json' ]"
check "1. issue create labels align+mission"  "grep -q 'lcars:align,lcars:mission' '$repo1/gh.log'"
check "1. issue create adds NO type label"    "! grep -qE 'lcars:(feature|bug)' '$repo1/gh.log'"
check "1. issue body carries the idea"        "grep -qF 'Make the leaderboard sortable by streak length' '$GH_BODY'"
check "1. issue body carries a STANDBY note"  "grep -qi 'STANDBY' '$GH_BODY'"
check "1. readout names the mission id"       "grep -q 'lcars-20260530-001-c10e' '$repo1/out.txt'"
check "1. readout says how to align"          "grep -q 'lcars file lcars-20260530-001-c10e' '$repo1/out.txt'"
check "1. records the issue number"           "grep -q '\"githubIssue\": *42' '$M1/state.json'"
unset GH_BODY

# --park via --idea <file> + a positional-less idea file works too.
repo1b="$(new_repo)"; make_gh_stub "$repo1b/gh"
export GH_LOG="$repo1b/gh.log"; : >"$GH_LOG"
ideaf="$repo1b/idea-in.txt"; printf 'A dark mode toggle in the header\nwith a persisted preference\n' >"$ideaf"
(
  cd "$repo1b"
  LCARS_GH_BIN="$repo1b/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" --park --idea "$ideaf" >out.txt 2>&1
)
M1b="$repo1b/.git/lcars/missions/lcars-20260530-001-c10e"
check "1b. --idea <file> captures the idea verbatim" \
  "grep -qF 'A dark mode toggle in the header' '$M1b/idea.md'"
check "1b. issue title is the first idea line (truncated)" \
  "grep -q 'A dark mode toggle in the header' '$repo1b/gh.log'"

# --- Behaviour 2: --engine persists workerBin; omitted ⇒ no workerBin ----------
repo2="$(new_repo)"; make_gh_stub "$repo2/gh"
export GH_LOG="$repo2/gh.log"; : >"$GH_LOG"
(
  cd "$repo2"
  LCARS_GH_BIN="$repo2/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" \
    --park "A copilot-built feature" --engine copilot >out.txt 2>&1
)
M2="$repo2/.git/lcars/missions/lcars-20260530-001-c10e"
check "2. --engine copilot persists workerBin=copilot" \
  "grep -q '\"workerBin\": *\"copilot\"' '$M2/state.json'"
check "2. state.json still valid JSON with engine" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M2/state.json'"

repo2b="$(new_repo)"; make_gh_stub "$repo2b/gh"
export GH_LOG="$repo2b/gh.log"; : >"$GH_LOG"
(
  cd "$repo2b"
  unset LCARS_WORKER_BIN
  LCARS_GH_BIN="$repo2b/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" \
    --park "No engine specified" >out.txt 2>&1
)
M2b="$repo2b/.git/lcars/missions/lcars-20260530-001-c10e"
check "2b. no --engine ⇒ no workerBin field" \
  "! grep -q 'workerBin' '$M2b/state.json'"

# A bogus engine is rejected with nothing partial.
repo2c="$(new_repo)"; make_gh_stub "$repo2c/gh"
export GH_LOG="$repo2c/gh.log"; : >"$GH_LOG"
rc2c=0
(
  cd "$repo2c"
  LCARS_GH_BIN="$repo2c/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" \
    --park "bad engine" --engine gpt-9 >out.txt 2>&1
) || rc2c=$?
check "2c. a bogus --engine ⇒ non-zero exit" "[ '$rc2c' -ne 0 ]"
check "2c. a bogus --engine ⇒ no mission written" \
  "[ ! -d '$repo2c/.git/lcars/missions/lcars-20260530-001-c10e' ]"

# --- Behaviour 3: a parked mission is NOT runnable, IS offered -----------------
repo3="$(new_repo)"; make_gh_stub "$repo3/gh"
export GH_LOG="$repo3/gh.log"; : >"$GH_LOG"
(
  cd "$repo3"
  LCARS_GH_BIN="$repo3/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" --park "Parked idea to run" >/dev/null 2>&1
)
# `lcars run` (drive) refuses cleanly, naming the align command.
rc3=0
(
  cd "$repo3"
  LCARS_GH_BIN="$repo3/gh" bash "$RUN_SCRIPT" drive --mission lcars-20260530-001-c10e >driveout.txt 2>&1
) || rc3=$?
check "3. lcars run on a parked mission exits non-zero" "[ '$rc3' -ne 0 ]"
check "3. run refusal says 'parked awaiting alignment'" \
  "grep -qi 'parked awaiting alignment' '$repo3/driveout.txt'"
check "3. run refusal names the align command" \
  "grep -q 'lcars file lcars-20260530-001-c10e' '$repo3/driveout.txt'"
check "3. run refusal is not a stack trace" \
  "! grep -qi 'line [0-9]*:' '$repo3/driveout.txt'"
# the Research stage entry also refuses.
rc3r=0
(
  cd "$repo3"
  LCARS_GH_BIN="$repo3/gh" bash "$RUN_SCRIPT" research --mission lcars-20260530-001-c10e >resout.txt 2>&1
) || rc3r=$?
check "3. research stage on a parked mission refuses" \
  "[ '$rc3r' -ne 0 ] && grep -qi 'parked awaiting alignment' '$repo3/resout.txt'"

# bare `lcars` OFFERS the parked mission but never drives it.
(
  cd "$repo3"
  LCARS_GH_BIN="$repo3/gh" bash "$LCARS_SCRIPT" >bare.txt 2>&1
)
check "3. bare lcars does NOT auto-drive a parked mission" \
  "! grep -q 'ROUTE: drive' '$repo3/bare.txt'"
check "3. bare lcars offers the parked mission for alignment" \
  "grep -qi 'awaiting alignment' '$repo3/bare.txt' && grep -q 'lcars-20260530-001-c10e' '$repo3/bare.txt'"
check "3. bare lcars names the align command in the offer" \
  "grep -q 'lcars file' '$repo3/bare.txt'"
# the resolver keeps parked missions OUT of the active/drivable set.
(
  cd "$repo3"
  bash "$RESOLVE_SCRIPT" --scope active >active.txt 2>err.txt; echo "rc=$?" >>active.txt
)
check "3. resolver active scope excludes the parked mission" \
  "! grep -q 'lcars-20260530-001-c10e' '$repo3/active.txt'"
(
  cd "$repo3"
  bash "$RESOLVE_SCRIPT" --scope parked >parked.txt 2>&1
)
check "3. resolver parked scope lists the parked mission" \
  "grep -q 'lcars-20260530-001-c10e' '$repo3/parked.txt'"

# --- Behaviour 4: --complete aligns in place, byte-equivalent to grill-first ---
# 4a. A bad PRD leaves NOTHING partial: no prd.md, prdPending still true.
repo4="$(new_repo)"; make_gh_stub "$repo4/gh"
export GH_LOG="$repo4/gh.log"; : >"$GH_LOG"
(
  cd "$repo4"
  LCARS_GH_BIN="$repo4/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" --park "To be completed" >/dev/null 2>&1
)
M4="$repo4/.git/lcars/missions/lcars-20260530-001-c10e"
badprd="$repo4/bad.md"; printf '# Mission: incomplete\n\n**Type:** bug\n**Goal:** nope\n' >"$badprd"
rc4bad=0
(
  cd "$repo4"
  LCARS_GH_BIN="$repo4/gh" bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$badprd" >badout.txt 2>&1
) || rc4bad=$?
check "4a. complete with a bad PRD exits non-zero" "[ '$rc4bad' -ne 0 ]"
check "4a. bad PRD ⇒ NO prd.md written"            "[ ! -f '$M4/prd.md' ]"
check "4a. bad PRD ⇒ prdPending still true"        "grep -q '\"prdPending\": *true' '$M4/state.json'"

# 4b. A good PRD completes: issue retitled + re-bodied + type label; prdPending
# cleared; estimator invoked; state byte-equivalent to a grill-first filing.
export GH_BODY="$repo4/gh-body.txt"; : >"$GH_BODY"
export EST_LOG="$repo4/est.log"; : >"$EST_LOG"
goodprd="$repo4/good.md"; write_prd "$goodprd"
(
  cd "$repo4"
  LCARS_GH_BIN="$repo4/gh" bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$goodprd" >compout.txt 2>&1
)
check "4b. complete writes prd.md"                "[ -f '$M4/prd.md' ]"
check "4b. prd.md has the PRD content"            "grep -qF 'Fix the broken /about route' '$M4/prd.md'"
check "4b. prdPending cleared from state.json"    "! grep -q 'prdPending' '$M4/state.json'"
check "4b. state.json now carries the type"       "grep -q '\"type\": *\"bug\"' '$M4/state.json'"
check "4b. state.json title is the PRD title"     "grep -q 'Fix the broken /about route' '$M4/state.json'"
check "4b. state.json still valid JSON"           "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M4/state.json'"
check "4b. estimator was invoked (estimate --mission)" \
  "grep -q 'estimate --mission lcars-20260530-001-c10e' '$EST_LOG'"
check "4b. estimate.json now exists"              "[ -f '$M4/estimate.json' ]"
check "4b. issue is edited IN PLACE (issue edit 42)" \
  "grep -q 'issue edit 42' '$repo4/gh.log'"
check "4b. issue edit retitles to the PRD title" \
  "grep -q 'Fix the broken /about route' '$repo4/gh.log'"
check "4b. issue edit adds the type label lcars:bug" \
  "grep -q 'add-label lcars:bug' '$repo4/gh.log'"
check "4b. issue body replaced with the PRD" \
  "grep -qF 'Fix the broken /about route' '$GH_BODY'"
check "4b. readout announces the alignment" \
  "grep -qi 'Mission aligned' '$repo4/compout.txt'"
( cd "$repo4" && bash "$RESOLVE_SCRIPT" --scope active >runnable.txt 2>&1 )
check "4b. completed mission is now runnable (resolver active)" \
  "grep -q 'lcars-20260530-001-c10e' '$repo4/runnable.txt'"
unset GH_BODY EST_LOG

# Byte-equivalence: file the SAME PRD grill-first in a fresh repo (same DATE/NOW/
# config), then diff the two mission dirs. idea.md must be the ONLY extra file,
# and state.json must be byte-identical.
repoGF="$(new_repo)"; make_gh_stub "$repoGF/gh"
export GH_LOG="$repoGF/gh.log"; : >"$GH_LOG"
prdGF="$repoGF/prd.md"; write_prd "$prdGF"
(
  cd "$repoGF"
  LCARS_GH_BIN="$repoGF/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --prd "$prdGF" >/dev/null 2>&1
)
MGF="$repoGF/.git/lcars/missions/lcars-20260530-001-c10e"

# Redo the parked→completed filing in a fresh repo with the SAME pinned DATE/NOW
# so created/id/branch/base match the grill-first filing exactly.
repoPC="$(new_repo)"; make_gh_stub "$repoPC/gh"
export GH_LOG="$repoPC/gh.log"; : >"$GH_LOG"
prdPC="$repoPC/prd.md"; write_prd "$prdPC"
(
  cd "$repoPC"
  LCARS_GH_BIN="$repoPC/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --park "the raw idea before the grill" >/dev/null 2>&1
  LCARS_GH_BIN="$repoPC/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdPC" >/dev/null 2>&1
)
MPC="$repoPC/.git/lcars/missions/lcars-20260530-001-c10e"
check "4c. completed state.json is byte-identical to grill-first" \
  "diff '$MGF/state.json' '$MPC/state.json' >/dev/null"
check "4c. completed prd.md is byte-identical to grill-first" \
  "diff '$MGF/prd.md' '$MPC/prd.md' >/dev/null"
# The only extra artifact in the parked→completed dir is idea.md.
EXTRA="$(comm -13 <(cd "$MGF" && ls -1 | sort) <(cd "$MPC" && ls -1 | sort) | tr '\n' ' ')"
check "4c. idea.md is the ONLY extra artifact vs grill-first" \
  "[ \"\$(printf '%s' '$EXTRA' | tr -d ' ')\" = 'idea.md' ]"

# 4d. Completing an ALREADY-aligned (non-parked) mission is refused cleanly.
rc4d=0
(
  cd "$repoPC"
  LCARS_GH_BIN="$repoPC/gh" bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$prdPC" >dblout.txt 2>&1
) || rc4d=$?
check "4d. completing an aligned mission exits non-zero" "[ '$rc4d' -ne 0 ]"
check "4d. message says 'already aligned'" \
  "grep -qi 'already aligned' '$repoPC/dblout.txt'"

# --- Behaviour 7 (DEFECT 1): a gh issue-edit failure leaves the mission PARKED,
# exits non-zero, and a later re-run cleanly RETRIES → byte-equivalent to a
# grill-first filing. This guards the idempotency contract at file.sh:385 — the
# prdPending-clearing final state write must happen ONLY after a successful issue
# update, so a partial failure never drifts (local "aligned" vs a stale issue). --
repo7="$(new_repo)"
# A gh stub that FAILS on `issue edit` while $GH_FAIL_EDIT is set (create still
# succeeds, so the park below opens issue #42 normally).
cat >"$repo7/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
if [ -n "${GH_BODY:-}" ]; then
  prev=""
  for a in "$@"; do
    if [ "$prev" = "--body-file" ]; then cat "$a" >"$GH_BODY"; fi
    prev="$a"
  done
fi
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"; exit 0
fi
if [ "$1" = "issue" ] && [ "$2" = "edit" ] && [ -n "${GH_FAIL_EDIT:-}" ]; then
  echo "gh: could not edit issue (simulated failure)" >&2; exit 1
fi
exit 0
EOF
chmod +x "$repo7/gh"
export GH_LOG="$repo7/gh.log"; : >"$GH_LOG"
(
  cd "$repo7"
  LCARS_GH_BIN="$repo7/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --park "the raw idea before the grill" >/dev/null 2>&1
)
M7="$repo7/.git/lcars/missions/lcars-20260530-001-c10e"
prd7="$repo7/prd.md"; write_prd "$prd7"
# First --complete: the issue edit FAILS.
rc7=0
(
  cd "$repo7"
  GH_FAIL_EDIT=1 LCARS_GH_BIN="$repo7/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$prd7" >failout.txt 2>&1
) || rc7=$?
check "7. complete exits non-zero when gh issue edit fails"       "[ '$rc7' -ne 0 ]"
check "7. gh-edit failure leaves prdPending true (still parked)"  "grep -q '\"prdPending\": *true' '$M7/state.json'"
check "7. gh-edit failure leaves NO type field in state.json"     "! grep -q '\"type\"' '$M7/state.json'"
check "7. gh-edit failure makes NO drift 'aligned' claim"         "! grep -qi 'Mission aligned' '$repo7/failout.txt'"
check "7. gh-edit failure names the re-run --complete command"    "grep -q 'lcars file --complete lcars-20260530-001-c10e' '$repo7/failout.txt'"
check "7. state.json is still valid JSON after a failed complete" "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$M7/state.json'"
# Re-run with the edit NOW succeeding: it must RETRY the edit and land aligned.
(
  cd "$repo7"
  LCARS_GH_BIN="$repo7/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$prd7" >okout.txt 2>&1
)
check "7. re-run after fixing gh completes (Mission aligned)"     "grep -qi 'Mission aligned' '$repo7/okout.txt'"
check "7. re-run clears prdPending"                               "! grep -q 'prdPending' '$M7/state.json'"
check "7. re-run now carries the type"                            "grep -q '\"type\": *\"bug\"' '$M7/state.json'"
check "7. re-run RETRIES the issue edit (issue edit 42 logged)"   "grep -q 'issue edit 42' '$repo7/gh.log'"
# Byte-equivalence: a fresh grill-first filing of the SAME PRD (same pinned
# DATE/NOW) must match the retried mission exactly.
repo7GF="$(new_repo)"; make_gh_stub "$repo7GF/gh"
export GH_LOG="$repo7GF/gh.log"; : >"$GH_LOG"
prd7GF="$repo7GF/prd.md"; write_prd "$prd7GF"
(
  cd "$repo7GF"
  LCARS_GH_BIN="$repo7GF/gh" LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --prd "$prd7GF" >/dev/null 2>&1
)
M7GF="$repo7GF/.git/lcars/missions/lcars-20260530-001-c10e"
check "7. retried state.json is byte-identical to grill-first" "diff '$M7GF/state.json' '$M7/state.json' >/dev/null"
check "7. retried prd.md is byte-identical to grill-first"     "diff '$M7GF/prd.md' '$M7/prd.md' >/dev/null"

# --- Behaviour 5: status renders standby without errors -----------------------
repo5="$(new_repo)"; make_gh_stub "$repo5/gh"
export GH_LOG="$repo5/gh.log"; : >"$GH_LOG"
(
  cd "$repo5"
  LCARS_GH_BIN="$repo5/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" --park "Standby me" >/dev/null 2>&1
)
M5="$repo5/.git/lcars/missions/lcars-20260530-001-c10e"
rc5=0
( cd "$repo5" && bash "$STATUS_SCRIPT" >statout.txt 2>&1 ) || rc5=$?
check "5. status exits 0 on a parked mission"      "[ '$rc5' -eq 0 ]"
check "5. status shows the standby glyph ◇"        "grep -q '◇' '$repo5/statout.txt'"
check "5. status labels the row 'awaiting alignment'" \
  "grep -qi 'awaiting alignment' '$repo5/statout.txt'"
# DEFECT 2: the 18-char "awaiting alignment" stage cell must NOT overflow into
# the glyph/title columns — there must be whitespace between it and the ◇ glyph.
check "5. stage cell does not glue the glyph (no overflow)" \
  "! grep -q 'awaiting alignment◇' '$repo5/statout.txt'"
check "5. status still shows the mission id"        "grep -q 'lcars-20260530-001-c10e' '$repo5/statout.txt'"
# comment-mirror never drifts a parked mission: with no run, there is no
# events.jsonl, so the mirror is a structural no-op (nothing to mirror).
check "5. a parked mission has no events.jsonl (mirror no-op)" \
  "[ ! -f '$M5/events.jsonl' ]"

# --- Behaviour 6: grill-first filing is unaffected (no prdPending) ------------
repo6="$(new_repo)"; make_gh_stub "$repo6/gh"
export GH_LOG="$repo6/gh.log"; : >"$GH_LOG"
prd6="$repo6/prd.md"; write_prd "$prd6"
(
  cd "$repo6"
  LCARS_GH_BIN="$repo6/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" --prd "$prd6" >out.txt 2>&1
)
M6="$repo6/.git/lcars/missions/lcars-20260530-001-c10e"
check "6. grill-first filing writes prd.md"          "[ -f '$M6/prd.md' ]"
check "6. grill-first state has NO prdPending"        "! grep -q 'prdPending' '$M6/state.json'"
check "6. grill-first writes NO idea.md"              "[ ! -f '$M6/idea.md' ]"
check "6. grill-first labels align+type+mission"      "grep -q 'lcars:align,lcars:bug,lcars:mission' '$repo6/gh.log'"
# A bare positional argument is rejected on the grill-first path (only --prd).
rc6=0
(
  cd "$repo6"
  LCARS_GH_BIN="$repo6/gh" LCARS_DATE="20260530" bash "$FILE_SCRIPT" "just an idea with no flag" >out2.txt 2>&1
) || rc6=$?
check "6. grill-first rejects a bare positional idea" "[ '$rc6' -ne 0 ]"

# --- Behaviour 8: the engine pin on the --complete lane (S147 round-2 D3) -----
# The park lane and the grill-first lane share one validation and one precedence
# rule; --complete was left out of both. It took its engine ONLY from the parked
# state.json, so `--engine` and $LCARS_WORKER_BIN were silently dropped and a
# bogus engine exited 0.
#
# This is not a CLI-only nicety. The viewscreen's START ALIGNMENT flow lets an
# explicit engine picker beat the parked engine for the GRILL (actions.py
# align_start) and then threads that choice to `file.sh --complete` as
# $LCARS_WORKER_BIN (_complete_from_align) — which do_complete ignored. A captain
# who parked an idea and then picked copilot got a grill on copilot and a
# pipeline on the parked/host-detected engine: the original money bug on a third
# lane, and a violation of "never decouple the grill engine from the pipeline
# engine". The most recent explicit choice must win, on BOTH surfaces.
mk_parked() { # repo-var-name [park-engine] → echoes repo path, parks mission 001
  local eng="${1:-}" repo; repo="$(new_repo)"; make_gh_stub "$repo/gh"
  local args=(--park "An idea to complete later")
  [ -n "$eng" ] && args+=(--engine "$eng")
  ( cd "$repo" && GH_LOG="$repo/gh.log" LCARS_GH_BIN="$repo/gh" LCARS_DATE="20260530" \
      bash "$FILE_SCRIPT" "${args[@]}" >/dev/null 2>&1 )
  printf '%s' "$repo"
}
CM="lcars-20260530-001-c10e"

# 8a. a bogus --engine on --complete is REJECTED, and the mission stays PARKED.
r8a="$(mk_parked)"; prd8a="$r8a/prd.md"; write_prd "$prd8a"
rc8a=0
( cd "$r8a" && GH_LOG="$r8a/gh.log" LCARS_GH_BIN="$r8a/gh" \
    bash "$FILE_SCRIPT" --complete "$CM" --prd "$prd8a" --engine totally-bogus >o.txt 2>&1 ) || rc8a=$?
check "8a. bogus --engine on --complete ⇒ non-zero exit" "[ '$rc8a' -ne 0 ]"
check "8a. bogus --engine on --complete ⇒ names the engine" \
  "grep -q \"unknown engine 'totally-bogus'\" '$r8a/o.txt'"
check "8a. bogus --engine on --complete ⇒ mission LEFT PARKED (nothing partial)" \
  "grep -q '\"prdPending\": *true' '$r8a/.git/lcars/missions/$CM/state.json'"
check "8a. bogus --engine on --complete ⇒ no prd.md written" \
  "[ ! -f '$r8a/.git/lcars/missions/$CM/prd.md' ]"

# 8b. --engine on --complete is HONOURED when the mission parked with none.
r8b="$(mk_parked)"; prd8b="$r8b/prd.md"; write_prd "$prd8b"
( cd "$r8b" && GH_LOG="$r8b/gh.log" LCARS_GH_BIN="$r8b/gh" \
    bash "$FILE_SCRIPT" --complete "$CM" --prd "$prd8b" --engine copilot >o.txt 2>&1 )
check "8b. --complete --engine copilot persists workerBin=copilot" \
  "grep -q '\"workerBin\": *\"copilot\"' '$r8b/.git/lcars/missions/$CM/state.json'"

# 8c. THE VIEWSCREEN CASE: parked on claude, captain picks copilot at START
#     ALIGNMENT ⇒ the daemon threads $LCARS_WORKER_BIN=copilot ⇒ the PIPELINE
#     must run copilot too, not the parked claude.
r8c="$(mk_parked claude)"; prd8c="$r8c/prd.md"; write_prd "$prd8c"
check "8c. (precondition) parked mission recorded workerBin=claude" \
  "grep -q '\"workerBin\": *\"claude\"' '$r8c/.git/lcars/missions/$CM/state.json'"
( cd "$r8c" && GH_LOG="$r8c/gh.log" LCARS_WORKER_BIN=copilot LCARS_GH_BIN="$r8c/gh" \
    bash "$FILE_SCRIPT" --complete "$CM" --prd "$prd8c" >o.txt 2>&1 )
check "8c. an explicit picker engine BEATS the parked engine on --complete" \
  "grep -q '\"workerBin\": *\"copilot\"' '$r8c/.git/lcars/missions/$CM/state.json'"

# 8d. --engine beats $LCARS_WORKER_BIN on --complete too (same order as the
#     other two lanes).
r8d="$(mk_parked claude)"; prd8d="$r8d/prd.md"; write_prd "$prd8d"
( cd "$r8d" && GH_LOG="$r8d/gh.log" LCARS_WORKER_BIN=claude LCARS_GH_BIN="$r8d/gh" \
    bash "$FILE_SCRIPT" --complete "$CM" --prd "$prd8d" --engine copilot >o.txt 2>&1 )
check "8d. --engine beats \$LCARS_WORKER_BIN on --complete" \
  "grep -q '\"workerBin\": *\"copilot\"' '$r8d/.git/lcars/missions/$CM/state.json'"

# 8e. NO REGRESSION: with neither signal, the PARKED engine is still carried
#     forward untouched (the S136 behaviour the byte-identity test locks).
r8e="$(mk_parked copilot)"; prd8e="$r8e/prd.md"; write_prd "$prd8e"
( cd "$r8e" && GH_LOG="$r8e/gh.log" LCARS_GH_BIN="$r8e/gh" \
    bash "$FILE_SCRIPT" --complete "$CM" --prd "$prd8e" >o.txt 2>&1 )
check "8e. no explicit engine ⇒ the parked engine is preserved" \
  "grep -q '\"workerBin\": *\"copilot\"' '$r8e/.git/lcars/missions/$CM/state.json'"

# 8f. NO REGRESSION: parked with nothing and completed with nothing ⇒ still NO
#     workerBin key at all (host-detect stays in charge).
r8f="$(mk_parked)"; prd8f="$r8f/prd.md"; write_prd "$prd8f"
( cd "$r8f" && GH_LOG="$r8f/gh.log" LCARS_GH_BIN="$r8f/gh" \
    bash "$FILE_SCRIPT" --complete "$CM" --prd "$prd8f" >o.txt 2>&1 )
check "8f. no engine anywhere ⇒ completed state.json has no workerBin key" \
  "! grep -q 'workerBin' '$r8f/.git/lcars/missions/$CM/state.json'"

# --- Behaviour 9: FL-010 — the --complete lane's attachment wording ----------
# The park lane stages attachments but writes no prd.md; --complete re-lists
# them when the PRD lands. That re-listing was a SECOND copy of the heading
# `run.sh` had already made adaptive, so a holodeck mission parked-then-completed
# still read "## Attached images" over an HTML mockup — in its own PRD, which is
# also its GitHub issue body. Both lanes now derive the wording from the ONE
# shared rule (lcars_attach_prd_section in lcars-init/lcars-common.sh).

# 9a. park --attach <mockup> + <doc>, then --complete ⇒ honest heading.
r9="$(new_repo)"; make_gh_stub "$r9/gh"
mock9="$r9/mockup.html"; printf '<!doctype html>' >"$mock9"
conc9="$r9/concept.md";  printf '# concept'       >"$conc9"
(
  cd "$r9"
  GH_LOG="$r9/gh.log" LCARS_GH_BIN="$r9/gh" LCARS_DATE="20260530" \
    bash "$FILE_SCRIPT" --park "Holodeck hand-off" --attach "$mock9" --attach "$conc9" >/dev/null 2>&1
)
M9="$r9/.git/lcars/missions/lcars-20260530-001-c10e"
prd9="$r9/prd.md"; write_prd "$prd9"
(
  cd "$r9"
  GH_LOG="$r9/gh.log" LCARS_GH_BIN="$r9/gh" \
    bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$prd9" >comp9.txt 2>&1
)
check "9a. --complete wrote prd.md" "[ -f '$M9/prd.md' ]"
check "9a. --complete does NOT call an HTML mockup an image" \
  "! grep -q '## Attached images' '$M9/prd.md'"
check "9a. --complete heading names what actually arrived" \
  "grep -q '## Attached files' '$M9/prd.md'"
check "9a. --complete declares the mockup LOOK AND FLOW only" \
  "grep -q 'LOOK AND FLOW' '$M9/prd.md'"
check "9a. the daemon's precedence sentence is readable" "[ -n \"\$PRECEDENCE\" ]"
check "9a. --complete carries the precedence rule VERBATIM" \
  "[ -n \"\$PRECEDENCE\" ] && grep -qF \"\$PRECEDENCE\" '$M9/prd.md'"
check "9a. --complete still lists both by RELATIVE path" \
  "grep -q '^- attachments/attachment-01.html\$' '$M9/prd.md' && grep -q '^- attachments/attachment-02.md\$' '$M9/prd.md'"

# 9b. NO REGRESSION: park+complete with IMAGES ONLY is byte-identical to the
# pre-S128 section — the same string the grill-first lane produces.
r9b="$(new_repo)"; make_gh_stub "$r9b/gh"
imgA9="$r9b/a.png"; printf 'AAA' >"$imgA9"
imgB9="$r9b/b.jpg"; printf 'BBB' >"$imgB9"
(
  cd "$r9b"
  GH_LOG="$r9b/gh.log" LCARS_GH_BIN="$r9b/gh" LCARS_DATE="20260530" \
    bash "$FILE_SCRIPT" --park "Screenshots" --attach "$imgA9" --attach "$imgB9" >/dev/null 2>&1
)
M9B="$r9b/.git/lcars/missions/lcars-20260530-001-c10e"
prd9b="$r9b/prd.md"; write_prd "$prd9b"
(
  cd "$r9b"
  GH_LOG="$r9b/gh.log" LCARS_GH_BIN="$r9b/gh" \
    bash "$FILE_SCRIPT" --complete lcars-20260530-001-c10e --prd "$prd9b" >comp9b.txt 2>&1
)
IMG_SECTION_PC="$(printf '\n## Attached images\n\n- attachments/attachment-01.png\n- attachments/attachment-02.jpg\n')"
GOT_SECTION_PC="$(python3 - "$M9B/prd.md" <<'PY'
import sys
t = open(sys.argv[1]).read()
i = t.index('\n## Attached')
sys.stdout.write(t[i:])
PY
)"
check "9b. image-only --complete section is BYTE-IDENTICAL to the pre-S128 string" \
  "[ \"\$GOT_SECTION_PC\" = \"\$IMG_SECTION_PC\" ]"

# ==========================================================================
echo
printf 'park-file: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
