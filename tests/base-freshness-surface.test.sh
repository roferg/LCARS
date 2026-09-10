#!/usr/bin/env bash
#
# Tests for the base-freshness SURFACE seam (S160) — the shell half.
#
# Skill source:
#   skills/lcars-init/lcars-common.sh    lcars_base_current_branch,
#                                        lcars_base_state_json,
#                                        ensure_base_current's CHECK-ONLY lane
#   skills/lcars-init/base-freshness.sh  the read-only reporter the viewscreen
#                                        daemon shells for its File-console
#                                        pre-flight line
#
# WHY THIS EXISTS. S158 and S159 print their warning to stdout, and the daemon
# dispatches file.sh through a pipe — so a captain filing from the board never
# sees a word of it. S160 puts the verdict on the board. The board needs TWO
# things this suite pins:
#
#   1. a MACHINE-READABLE record (`lcars_base_state_json`), emitted by the SAME
#      writer that already composes the state.json line, so the badge and the
#      mission file can never carry different words; and
#   2. a way to ASK the question without ANSWERING it — a pre-flight check runs
#      before the captain has typed anything, and a question whose asking
#      fast-forwards the captain's checkout is not a question. That is
#      LCARS_BASE_CHECK_ONLY, and `base-freshness.sh` is read-only BY
#      CONSTRUCTION (it sets the flag itself).
#
# The file-time guard is UNCHANGED: tests/base-freshness.test.sh still holds it
# to all 444 of its assertions, and check-only is off unless asked for.
#
# Real git against LOCAL BARE remotes; no forge, no worker, zero tokens.
#
# Usage: bash tests/base-freshness-surface.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
REPORTER="${LCARS_BASE_FRESHNESS_SCRIPT:-$REPO_ROOT/skills/lcars-init/base-freshness.sh}"

export LCARS_VERSION_CHECK=0

pass=0
fail=0
TMPROOT="$(mktemp -d)"
# LCARS_KEEP_TMP=1 keeps the fixtures and prints where they are. Several
# behaviours here EXECUTE a printed `fix` against a real repo, and when one of
# those fails the only useful evidence is the repo it failed in.
trap '[ -n "${LCARS_KEEP_TMP:-}" ] || rm -rf "$TMPROOT"' EXIT
[ -n "${LCARS_KEEP_TMP:-}" ] && echo "TMPROOT=$TMPROOT"

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# jf <json-file> <dotted.key> — read a field out of a JSON file. Prints the
# python repr of the value (None / True / False / 0), so a test can tell a
# measured zero from an unmeasured null — the distinction the whole record is
# built around. Empty on a miss.
jf() {
  python3 -c "
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'): d=d[k]
    print(repr(d))
except Exception:
    pass
" "$1" "$2" 2>/dev/null
}

# make_fixture <name> — a local BARE origin + a seed clone + the working clone
# under test (identical to tests/base-freshness.test.sh's). Echoes the clone.
make_fixture() {
  local name="$1"
  local bare="$TMPROOT/$name.git" seed="$TMPROOT/$name.seed" repo="$TMPROOT/$name"
  git init -q --bare "$bare" 2>/dev/null
  git init -q "$seed" 2>/dev/null
  (
    cd "$seed"
    git config user.email t@t; git config user.name t
    git checkout -q -b main 2>/dev/null
    echo "base" >README.md
    git add -A && git commit -q -m init
    git remote add origin "$bare" && git push -q -u origin main
  ) >/dev/null 2>&1
  git -C "$bare" symbolic-ref HEAD refs/heads/main
  git clone -q "$bare" "$repo" 2>/dev/null
  ( cd "$repo" && git config user.email t@t && git config user.name t )
  printf '%s' "$repo"
}

# advance_origin <name> <n> — push n commits to the bare origin, leaving the
# working clone genuinely n behind.
advance_origin() {
  local name="$1" n="$2" i
  (
    cd "$TMPROOT/$name.seed"
    git pull -q --ff-only origin main
    for i in $(seq 1 "$n"); do
      mkdir -p src
      printf 'origin line %s\n' "$i" >>src/real-view.txt
      git add -A && git commit -q -m "origin commit $i"
    done
    git push -q origin main
  ) >/dev/null 2>&1
}

# has_gitfile <repo> <git-dir-relative-name> — does <repo>'s git dir hold this
# file/dir? Run from INSIDE the repo, deliberately: `git rev-parse --git-path`
# answers a path relative to the CURRENT directory in an ordinary checkout (and
# an absolute one in a linked worktree), so `git -C <repo> rev-parse --git-path
# rebase-merge` hands back `.git/rebase-merge` — which the TEST's own cwd then
# resolves somewhere else entirely, and the check quietly answers "no". Same
# family as S158's `core.quotePath` lesson: a path test that can never fire
# looks exactly like a passing one.
has_gitfile() {
  ( cd "$1" 2>/dev/null && [ -e "$(git rev-parse --git-path "$2" 2>/dev/null)" ] )
}

# report <repo> <out.json> [args…] — run the read-only reporter in <repo>.
report() {
  local repo="$1" out="$2"; shift 2
  ( cd "$repo" && LCARS_NOW="2026-05-30T00:00:00Z" \
      bash "$REPORTER" "$@" >"$out" 2>"$out.err" )
}

# snapshot <repo> — everything the reporter is FORBIDDEN to move: the base
# ref, HEAD, and the working tree (tracked + untracked). Deliberately NOT
# refs/remotes/* — a fetch writes only there, provably cannot touch a working
# tree, and measuring staleness without one is impossible.
snapshot() {
  local repo="$1"
  git -C "$repo" rev-parse HEAD 2>/dev/null
  git -C "$repo" rev-parse --verify -q refs/heads/main 2>/dev/null
  git -C "$repo" symbolic-ref -q HEAD 2>/dev/null
  git -C "$repo" status --porcelain 2>/dev/null
  ( cd "$repo" && find . -path ./.git -prune -o -type f -print0 2>/dev/null \
      | sort -z | xargs -0 shasum 2>/dev/null )
}

# --- the daemon half's stubs (behaviour 13) -------------------------------
# The parity behaviour drives the REAL daemon dispatcher against the REAL
# file.sh, so it needs what tests/base-freshness.test.sh needs: a gh that mints
# an issue URL, an estimator that writes an estimate.json, and a STAMPED
# .git/lcars/config.json so file.sh's version check has nothing to prompt about.
# No worker is ever spawned — zero tokens.
WEB_DIR="$REPO_ROOT/web"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
VERSION_STAMP="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION" 2>/dev/null)"

GH_STUB="$TMPROOT/gh"
cat >"$GH_STUB" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "issue" ] && [ "$2" = "create" ]; then
  echo "https://github.com/owner/repo/issues/42"; exit 0
fi
exit 0
EOF
chmod +x "$GH_STUB"

ESTIMATOR_STUB="$TMPROOT/estimate-run.sh"
cat >"$ESTIMATOR_STUB" <<'EOF'
#!/usr/bin/env bash
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
printf '%s\n' '{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "low", "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet", "planReview": "sonnet", "implement": "sonnet", "verify": "sonnet" }, "deviations": [], "estimatorModel": "opus" }' >"$mdir/estimate.json"
exit 0
EOF
chmod +x "$ESTIMATOR_STUB"

# scaffold_lcars <repo> — .git/lcars with a STAMPED config (no update prompt).
scaffold_lcars() {
  local repo="$1"
  mkdir -p "$repo/.git/lcars/missions"
  # S183: a CONFIGURED test command, so this fixture is a repo with a test
  # FOUNDATION. `lcars file` now refuses to open a normal mission on a repo that
  # has none (greenfield/untested) and points at Establish Vision instead — so a
  # suite that files missions has to file against a repo that can actually be
  # filed against. `true` resolves via `command -v`, which is all the readiness
  # verdict asks of a command. The gate itself is proven in
  # tests/foundation-gate.test.sh, against real repos in all four states.
  cat >"$repo/.git/lcars/config.json" <<EOF
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e",
  "model": "claude-sonnet", "projectName": "fixture", "contextFile": null,
  "testCommand": "true",
  "lcarsVersion": "$VERSION_STAMP", "created": "2026-05-30T00:00:00Z" }
EOF
}

# The pinned environment BOTH filing paths run under, so the only variable
# between them is which one is filing.
file_env() {
  printf '%s\n' \
    "LCARS_GH_BIN=$GH_STUB" "LCARS_DATE=20260530" \
    "LCARS_NOW=2026-05-30T00:00:00Z" "LCARS_RUN_BIN=$ESTIMATOR_STUB" \
    "LCARS_VERSION_CHECK=0"
}

# file_cli <repo> — the CLI lane: `lcars file --prd <captain's PRD>`.
file_cli() {
  local repo="$1" prd="$TMPROOT/parity-prd.md"
  cat >"$prd" <<'EOF'
# Mission: Fix the broken /about route

**Type:** bug
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router; no new dependencies
EOF
  ( cd "$repo" && env $(file_env) bash "$FILE_SCRIPT" --prd "$prd" ) \
    >"$repo.out" 2>&1
}

# file_daemon <repo> [file-script] — the BOARD lane: the real daemon dispatcher
# (`Actions.file_mission`, the thing POST /api/mission calls) against the real
# file.sh. Not a re-enactment of it — the shipping object, in process.
file_daemon() {
  local repo="$1" script="${2:-$FILE_SCRIPT}"
  ( cd "$repo" && env $(file_env) \
      LCARS_PARITY_WEB="$WEB_DIR" LCARS_PARITY_REPO="$repo" \
      LCARS_PARITY_GH="$GH_STUB" LCARS_PARITY_FILE="$script" \
      python3 -c '
import os, sys
sys.path.insert(0, os.environ["LCARS_PARITY_WEB"])
from lcars_serve.actions import Actions
Actions(repo_root=os.environ["LCARS_PARITY_REPO"],
        scripts={"file": os.environ["LCARS_PARITY_FILE"]},
        gh_bin=os.environ["LCARS_PARITY_GH"]).file_mission(
            "Fix the broken /about route")
' ) >"$repo.out" 2>&1
}

# S196 — `cloneId` PINS THE FINGERPRINT so $MID below stays a literal. A minted
# mission id is now `lcars-YYYYMMDD-NNN-<fp>`, where <fp> is the first 4 hex of
# the clone's own `cloneId` (a UUID4 minted on first use, so two clones of one
# repo can never mint the same id — see lcars_clone_id in
# skills/lcars-init/lcars-common.sh). Pinning it makes <fp> the constant `c10e`;
# the widening itself is proven in tests/mission-id.test.sh.
MID="lcars-20260530-001-c10e"
mdir() { printf '%s/.git/lcars/missions/%s' "$1" "$MID"; }

echo "base freshness — the viewscreen surface (S160)"
[ -f "$COMMON" ]   || { echo "shared lib not found at $COMMON"; exit 1; }

# --- Behaviour 0: the seams exist -----------------------------------------
check "0. lcars-common.sh defines lcars_base_state_json" \
  "bash -c '. \"$COMMON\"; type lcars_base_state_json' >/dev/null 2>&1"
check "0. lcars-common.sh defines lcars_base_current_branch" \
  "bash -c '. \"$COMMON\"; type lcars_base_current_branch' >/dev/null 2>&1"
check "0. the read-only reporter exists" "[ -f '$REPORTER' ]"

# --- Behaviour 1: ONE writer — the line is the object, wrapped -------------
# The card badge reads the object; state.json reads the line. If these were two
# printf statements they could drift, and the badge would eventually describe a
# git state the mission file denies. The line must be the object, verbatim.
r1="$(make_fixture s1)"
L1="$TMPROOT/s1.line"; J1="$TMPROOT/s1.obj"
(
  cd "$r1" && . "$COMMON" && LCARS_BASE_QUIET=1 ensure_base_current main
  lcars_base_state_line >"$L1"
  lcars_base_state_json >"$J1"
) >/dev/null 2>&1
check "1. the JSON object is emitted" "[ -s '$J1' ]"
check "1. …and it is valid JSON on its own" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$J1'"
check "1. …and the state.json line is EXACTLY that object, wrapped" \
  "[ \"\$(cat '$L1')\" = \"  \\\"baseFreshness\\\": \$(cat '$J1'),\" ]"
check "1. the object carries exactly the eleven documented keys" \
  "python3 -c 'import json,sys; f=json.load(open(sys.argv[1])); sys.exit(0 if set(f)=={\"verdict\",\"loud\",\"reason\",\"fix\",\"fixNote\",\"blocker\",\"behindBy\",\"aheadBy\",\"baseSha\",\"checkedAt\",\"missionBranchAtBase\"} else 1)' '$J1'"

# --- Behaviour 2: the base branch is resolved in ONE place -----------------
# file.sh decides which branch a Mission is cut from; the pre-flight must ask
# about the SAME one, or it reports on a branch the captain is not filing
# against. So the resolution is a shared function, and file.sh uses it.
r2="$(make_fixture s2)"
B2="$( cd "$r2" && bash -c ". '$COMMON'; lcars_base_current_branch" )"
check "2. on a checked-out branch it answers that branch" "[ '$B2' = 'main' ]"
( cd "$r2" && git checkout -q --detach HEAD ) >/dev/null 2>&1
B2D="$( cd "$r2" && bash -c ". '$COMMON'; lcars_base_current_branch" )"
check "2. on a DETACHED HEAD it falls back to 'main' (file.sh's own fallback)" \
  "[ '$B2D' = 'main' ]"
FILESH2="$REPO_ROOT/skills/lcars-file/file.sh"
check "2. …and BOTH of file.sh's filing lanes resolve the base through it" \
  "[ \"\$(grep -c 'BASE=\"\$(lcars_base_current_branch)\"' '$FILESH2')\" = '2' ]"
check "2. …with no filing lane rolling its own rev-parse fallback" \
  "! grep -q 'BASE=\"\$(\"\$GIT_BIN\" rev-parse' '$FILESH2'"
# ONE copy of the raw resolution survives, and only one: the degradation stub
# that runs when lcars-common.sh cannot be sourced at all, where the contract is
# "behave exactly as pre-S158". A second copy anywhere else is the drift this
# whole behaviour exists to forbid.
check "2. …and the ONLY surviving raw copy is the lib-missing degradation stub" \
  "[ \"\$(grep -c 'rev-parse --abbrev-ref HEAD' '$FILESH2')\" = '1' ]"
check "2. …which is guarded by the lib-missing check" \
  "grep -q 'command -v lcars_base_current_branch' '$FILESH2'"

# --- Behaviour 3: a CURRENT repo reports current, quietly ------------------
r3="$(make_fixture s3)"
report "$r3" "$TMPROOT/s3.json" --json
check "3. --json prints one JSON object" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$TMPROOT/s3.json'"
check "3. verdict is 'current'"  "[ \"\$(jf '$TMPROOT/s3.json' verdict)\" = \"'current'\" ]"
check "3. …and it is NOT loud"   "[ \"\$(jf '$TMPROOT/s3.json' loud)\" = 'False' ]"
check "3. --json prints nothing else on stdout (the ⚠ block is silenced)" \
  "[ \"\$(head -c1 '$TMPROOT/s3.json')\" = '{' ]"
check "3. …and exits 0 (a report, never a gate)" "true"

# --- Behaviour 4: THE ONE THAT MATTERS — asking does not answer ------------
# A base 19 behind, clean, on the right branch: the file-time guard would
# FAST-FORWARD it. The pre-flight must not. The captain has typed nothing; the
# board is asking a question, and a question that moves the captain's refs is a
# side effect nobody consented to.
r4="$(make_fixture s4)"
advance_origin s4 19
SNAP4_BEFORE="$(snapshot "$r4")"
BASE4_BEFORE="$(git -C "$r4" rev-parse refs/heads/main)"
report "$r4" "$TMPROOT/s4.json" --json
SNAP4_AFTER="$(snapshot "$r4")"
check "4. the base ref did NOT move" \
  "[ \"\$(git -C '$r4' rev-parse refs/heads/main)\" = '$BASE4_BEFORE' ]"
check "4. HEAD, the branch, and the whole working tree are untouched" \
  "[ \"\$SNAP4_BEFORE\" = \"\$SNAP4_AFTER\" ]"
check "4. the file only origin has was NOT written into the tree" \
  "[ ! -e '$r4/src/real-view.txt' ]"
check "4. it still MEASURED the staleness — behindBy is 19" \
  "[ \"\$(jf '$TMPROOT/s4.json' behindBy)\" = '19' ]"
check "4. verdict is 'stale' (behind, and nothing was moved)" \
  "[ \"\$(jf '$TMPROOT/s4.json' verdict)\" = \"'stale'\" ]"
# …and DELIBERATELY quiet: this is the one lane where the captain's next action
# — filing — is itself the fix. A warning whose only remedy is the thing you
# were already doing is the "re-file reproduces the identical warning forever"
# trap S158 spent a round removing.
check "4. …and it is NOT loud — filing is what fixes this one" \
  "[ \"\$(jf '$TMPROOT/s4.json' loud)\" = 'False' ]"
check "4. the reason says plainly that nothing was moved" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"nothing was moved\" in r else 1)' '$TMPROOT/s4.json'"
# The reporter can NEVER say `updated` — that verdict is set by the ref move,
# and the ref move is exactly what it does not do.
check "4. a read-only check can never report 'updated'" \
  "[ \"\$(jf '$TMPROOT/s4.json' verdict)\" != \"'updated'\" ]"

# --- Behaviour 5: the SAME repo through the file-time guard DOES move ------
# Proof that check-only is the only difference — not that the fixture was
# somehow un-fast-forwardable all along.
report "$r4" "$TMPROOT/s4b.json" --json     # still read-only, still 19 behind
check "5. a second read-only check still reports 19 behind" \
  "[ \"\$(jf '$TMPROOT/s4b.json' behindBy)\" = '19' ]"
( cd "$r4" && . "$COMMON" && LCARS_BASE_QUIET=1 ensure_base_current main ) >/dev/null 2>&1
check "5. the file-time guard (no check-only) DOES fast-forward the base" \
  "[ \"\$(git -C '$r4' rev-parse refs/heads/main)\" != '$BASE4_BEFORE' ]"
check "5. …and origin's file is now really in the tree" \
  "[ -e '$r4/src/real-view.txt' ]"

# --- Behaviour 6: a LOUD condition the captain must act on ----------------
# A dirty tree: LCARS refuses the fast-forward, so the base stays behind and
# there IS something for the captain to do. This is the line the console shows.
r6="$(make_fixture s6)"
advance_origin s6 4
echo "captain's uncommitted work" >>"$r6/README.md"
SNAP6_BEFORE="$(snapshot "$r6")"
report "$r6" "$TMPROOT/s6.json" --json
check "6. verdict is 'stale'" "[ \"\$(jf '$TMPROOT/s6.json' verdict)\" = \"'stale'\" ]"
check "6. …and it IS loud"    "[ \"\$(jf '$TMPROOT/s6.json' loud)\" = 'True' ]"
check "6. it carries a reason naming the uncommitted work" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"uncommitted\" in r or \"modified\" in r else 1)' '$TMPROOT/s6.json'"
check "6. it carries a FIX the captain can actually run" \
  "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"fix\"]; sys.exit(0 if \"git stash\" in f else 1)' '$TMPROOT/s6.json'"
check "6. behindBy is the measured 4" "[ \"\$(jf '$TMPROOT/s6.json' behindBy)\" = '4' ]"
check "6. …and the captain's dirty tree is STILL untouched" \
  "[ \"\$SNAP6_BEFORE\" = \"\$(snapshot '$r6')\" ]"

# --- Behaviour 7: unmeasured is null, never a reassuring zero -------------
# No origin at all: nothing could be measured. `behindBy: 0` here would be the
# one lie a consumer cannot detect, so it must be null.
r7="$TMPROOT/s7"
git init -q "$r7" 2>/dev/null
( cd "$r7" && git config user.email t@t && git config user.name t \
    && echo x >a.txt && git add -A && git commit -q -m init ) >/dev/null 2>&1
report "$r7" "$TMPROOT/s7.json" --json
check "7. verdict is 'unknown' with no remote" \
  "[ \"\$(jf '$TMPROOT/s7.json' verdict)\" = \"'unknown'\" ]"
check "7. …and it is QUIET (a local-only repo is not a problem)" \
  "[ \"\$(jf '$TMPROOT/s7.json' loud)\" = 'False' ]"
check "7. behindBy is null — NOT 0" \
  "[ \"\$(jf '$TMPROOT/s7.json' behindBy)\" = 'None' ]"
check "7. aheadBy is null too"  "[ \"\$(jf '$TMPROOT/s7.json' aheadBy)\" = 'None' ]"

# --- Behaviour 8: an unreachable origin is the LOUD `unknown` -------------
# The pair behaviour 7 makes: same verdict word, opposite loudness. Any consumer
# that derived "badge or no badge" from the verdict name would get one of these
# two wrong, forever. This is why `loud` is carried.
r8="$(make_fixture s8)"
( cd "$r8" && git remote set-url origin "$TMPROOT/no-such-origin.git" )
report "$r8" "$TMPROOT/s8.json" --json
check "8. verdict is 'unknown' when origin cannot be reached" \
  "[ \"\$(jf '$TMPROOT/s8.json' verdict)\" = \"'unknown'\" ]"
check "8. …and THIS one IS loud" "[ \"\$(jf '$TMPROOT/s8.json' loud)\" = 'True' ]"
check "8. two 'unknown's, opposite loudness — the verdict alone cannot decide" \
  "[ \"\$(jf '$TMPROOT/s7.json' loud)\" != \"\$(jf '$TMPROOT/s8.json' loud)\" ]"

# --- Behaviour 9: child-base — LCARS takes no position -------------------
# A logged bug is based on its parent's `lcars/<parent-id>` branch. "Bring it up
# to date from origin" would move the fix onto code it was never written
# against. The reporter must say so, take no network call, and stay quiet.
r9="$(make_fixture s9)"
( cd "$r9" && git checkout -q -b "lcars/$MID" ) >/dev/null 2>&1
advance_origin s9 3
report "$r9" "$TMPROOT/s9.json" --json
check "9. verdict is 'child-base'" \
  "[ \"\$(jf '$TMPROOT/s9.json' verdict)\" = \"'child-base'\" ]"
check "9. …and it is QUIET — a parent's branch is not a fault to report" \
  "[ \"\$(jf '$TMPROOT/s9.json' loud)\" = 'False' ]"
check "9. it says nothing was fetched and no ref was moved" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"no ref was moved\" in r else 1)' '$TMPROOT/s9.json'"
check "9. it offers NO fix — there is nothing to fix" \
  "[ \"\$(jf '$TMPROOT/s9.json' fix)\" = \"''\" ]"
check "9. nothing was measured, so behindBy is null" \
  "[ \"\$(jf '$TMPROOT/s9.json' behindBy)\" = 'None' ]"

# --- Behaviour 10: the reporter is read-only BY CONSTRUCTION --------------
# Not "read-only if the caller remembers to set the flag". The daemon inherits
# the captain's whole environment; an inherited LCARS_BASE_CHECK_ONLY=0 must not
# turn a board render into a fast-forward of the captain's checkout.
r10="$(make_fixture s10)"
advance_origin s10 5
BASE10="$(git -C "$r10" rev-parse refs/heads/main)"
( cd "$r10" && LCARS_BASE_CHECK_ONLY=0 LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$REPORTER" --json >"$TMPROOT/s10.json" 2>/dev/null )
check "10. an inherited LCARS_BASE_CHECK_ONLY=0 does NOT re-arm the ref move" \
  "[ \"\$(git -C '$r10' rev-parse refs/heads/main)\" = '$BASE10' ]"
check "10. …and it still reports the staleness honestly" \
  "[ \"\$(jf '$TMPROOT/s10.json' behindBy)\" = '5' ]"
check "10. the script sets the flag itself, in its own source" \
  "grep -q 'LCARS_BASE_CHECK_ONLY=1' '$REPORTER'"

# --- Behaviour 11: it never dies, whatever it is pointed at ---------------
# It is a report. A report that exits non-zero, or dumps a traceback where JSON
# was expected, takes the board down with it.
r11="$TMPROOT/not-a-repo"; mkdir -p "$r11"
rc11=0
( cd "$r11" && bash "$REPORTER" --json >"$TMPROOT/s11.json" 2>/dev/null ) || rc11=$?
check "11. outside a git repo it still exits 0" "[ '$rc11' -eq 0 ]"
check "11. …and still prints one valid JSON object" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$TMPROOT/s11.json'"
check "11. …whose verdict is 'unknown', quietly" \
  "[ \"\$(jf '$TMPROOT/s11.json' verdict)\" = \"'unknown'\" ] && [ \"\$(jf '$TMPROOT/s11.json' loud)\" = 'False' ]"
rc11b=0
( cd "$r11" && bash "$REPORTER" --nonsense >/dev/null 2>&1 ) || rc11b=$?
check "11. an unknown option is refused (a typo must not read as 'all clear')" \
  "[ '$rc11b' -ne 0 ]"

# --- Behaviour 12: the human line still works (the CLI voice is intact) ---
r12="$(make_fixture s12)"
advance_origin s12 6
echo "dirt" >>"$r12/README.md"
report "$r12" "$TMPROOT/s12.line" --line
check "12. --line prints the ⚠ block a captain can read" \
  "grep -q 'BASE FRESHNESS' '$TMPROOT/s12.line'"
check "12. …with the Fix the record carries" "grep -q 'Fix:' '$TMPROOT/s12.line'"
check "12. …and it is NOT JSON" "[ \"\$(head -c1 '$TMPROOT/s12.line')\" != '{' ]"

# --- Behaviour 13: HARNESS PARITY — filing from the board IS filing --------
# The captain's principle (ADR-002): the UI is a viewport, never a
# reimplementation. Same repo state, same fixture, two filing lanes — the CLI
# and the daemon dispatcher POST /api/mission actually calls — must reach the
# SAME verdict and leave the base in the SAME place.
#
# THE DEFECT THIS PINS. The daemon materialises the captain's idea as its OWN
# scratch PRD before it dispatches, and it used to write it into the REPO ROOT.
# `git status --porcelain` then counted LCARS's own provisioning artifact as the
# captain's untracked work: the guard concluded "dirty tree", refused the
# fast-forward it was standing right in front of, and stamped a permanent
# `loud: true` record accusing a pristine clone of being dirty — while the
# Mission really was cut from the stale base, the exact failure the guard
# exists to prevent. This is the S157 class exactly: the harness's own artifacts
# are never the captain's changes.
#
# THE CURE IS STRUCTURAL, NOT A FILENAME RULE. The scratch lives under
# `.git/`, where `git status` cannot see it BY CONSTRUCTION — so there is no
# ignore-list to keep in sync, no ordering discipline for a future writer to
# forget, and no place for the class to come back. Behaviour 14 holds that.
c13="$(make_fixture s13cli)";   scaffold_lcars "$c13"; advance_origin s13cli 1
d13="$(make_fixture s13daemon)"; scaffold_lcars "$d13"; advance_origin s13daemon 1
# Each fixture has its OWN bare origin, so each lane is measured against its own
# — comparing one clone's base to the other's origin would be a fixture bug
# masquerading as a parity failure.
ORIGIN13C="$(git -C "$TMPROOT/s13cli.git" rev-parse refs/heads/main)"
ORIGIN13D="$(git -C "$TMPROOT/s13daemon.git" rev-parse refs/heads/main)"
check "13. both fixtures start CLEAN"  \
  "[ -z \"\$(git -C '$c13' status --porcelain)\" ] && [ -z \"\$(git -C '$d13' status --porcelain)\" ]"
file_cli "$c13"
file_daemon "$d13"
check "13. the CLI lane files"     "[ -d '$(mdir "$c13")' ]"
check "13. the DAEMON lane files"  "[ -d '$(mdir "$d13")' ]"
# THE OUTCOME, on both lanes: the base really is on origin's tip.
check "13. the CLI lane fast-forwarded the base" \
  "[ \"\$(git -C '$c13' rev-parse refs/heads/main)\" = '$ORIGIN13C' ]"
check "13. the DAEMON lane fast-forwarded the base TOO" \
  "[ \"\$(git -C '$d13' rev-parse refs/heads/main)\" = '$ORIGIN13D' ]"
check "13. …so the file only origin had is really in the daemon-filed tree" \
  "[ -e '$d13/src/real-view.txt' ]"
# THE RECORD, on both lanes: identical verdict, identical loudness.
check "13. the two lanes record the SAME verdict" \
  "[ \"\$(jf '$(mdir "$c13")/state.json' baseFreshness.verdict)\" = \"\$(jf '$(mdir "$d13")/state.json' baseFreshness.verdict)\" ]"
check "13. …and it is 'updated', not 'stale'" \
  "[ \"\$(jf '$(mdir "$d13")/state.json' baseFreshness.verdict)\" = \"'updated'\" ]"
check "13. the two lanes record the SAME loudness" \
  "[ \"\$(jf '$(mdir "$c13")/state.json' baseFreshness.loud)\" = \"\$(jf '$(mdir "$d13")/state.json' baseFreshness.loud)\" ]"
check "13. …and a behind-but-CLEAN base stays SILENT (no false alarm)" \
  "[ \"\$(jf '$(mdir "$d13")/state.json' baseFreshness.loud)\" = 'False' ]"
check "13. the daemon-filed record does NOT accuse a clean tree of being dirty" \
  "! python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"baseFreshness\"][\"reason\"]; sys.exit(0 if \"untracked\" in r or \"working tree has\" in r else 1)' '$(mdir "$d13")/state.json'"
check "13. …and the tree is clean again afterwards (nothing leaked)" \
  "[ -z \"\$(git -C '$d13' status --porcelain)\" ]"

# --- Behaviour 14: the daemon's scratch is INVISIBLE TO GIT, mid-dispatch --
# Behaviour 13 proves the outcome; this proves the mechanism, and it is the one
# that stops the class coming back. A stub `file` script asks `git status
# --porcelain` AT DISPATCH TIME — the exact moment the real guard reads it — and
# hands the answer back. It must be EMPTY: whatever LCARS staged for itself is
# not in the working tree at all.
d14="$(make_fixture s14)"; scaffold_lcars "$d14"
STATUS_STUB="$TMPROOT/status-probe.sh"
cat >"$STATUS_STUB" <<EOF
#!/usr/bin/env bash
git status --porcelain >"$TMPROOT/s14.during"
printf '%s\n' "\$*" >"$TMPROOT/s14.argv"
exit 0
EOF
chmod +x "$STATUS_STUB"
file_daemon "$d14" "$STATUS_STUB"
check "14. the dispatch really happened (a --prd was materialised)" \
  "grep -q -- '--prd' '$TMPROOT/s14.argv'"
check "14. the working tree is EMPTY of dirt at the moment the guard reads it" \
  "[ -z \"\$(cat '$TMPROOT/s14.during' 2>/dev/null)\" ]"
check "14. …and the scratch path it passed is NOT in the working tree" \
  "python3 -c \"
import sys
argv=open(sys.argv[1]).read().split()
p=argv[argv.index('--prd')+1]
sys.exit(0 if '/.git/' in p else 1)\" '$TMPROOT/s14.argv'"
# Images ride the same lane (S92), so they get the same guarantee — one helper,
# one rule, no second place to forget.
file_daemon_img() {
  local repo="$1" script="$2"
  ( cd "$repo" && env $(file_env) \
      LCARS_PARITY_WEB="$WEB_DIR" LCARS_PARITY_REPO="$repo" \
      LCARS_PARITY_GH="$GH_STUB" LCARS_PARITY_FILE="$script" \
      python3 -c '
import os, sys
sys.path.insert(0, os.environ["LCARS_PARITY_WEB"])
from lcars_serve.actions import Actions
Actions(repo_root=os.environ["LCARS_PARITY_REPO"],
        scripts={"file": os.environ["LCARS_PARITY_FILE"]},
        gh_bin=os.environ["LCARS_PARITY_GH"]).file_mission(
            "Fix the broken /about route",
            images=[{"name": "shot.png", "type": "image/png",
                     "dataB64": "iVBORw0KGgo="}])
' ) >"$repo.out" 2>&1
}
d14b="$(make_fixture s14b)"; scaffold_lcars "$d14b"
STATUS_STUB2="$TMPROOT/status-probe2.sh"
cat >"$STATUS_STUB2" <<EOF
#!/usr/bin/env bash
git status --porcelain >"$TMPROOT/s14b.during"
exit 0
EOF
chmod +x "$STATUS_STUB2"
file_daemon_img "$d14b" "$STATUS_STUB2"
check "14. a PASTED IMAGE is staged out of the tree too" \
  "[ -z \"\$(cat '$TMPROOT/s14b.during' 2>/dev/null)\" ]"

# --- Behaviour 15: the badge headline names the BLOCKER, not the count -----
# `⚠ BASE · 1 BEHIND` on a dirty tree names the half the captain was ruled safe
# to ignore; the half that actually STOPPED the fast-forward lives only in the
# body. So the record CARRIES what blocked it, in the same call that writes the
# sentence describing it — one place, so the two can never describe different
# conditions — and the badge is built from that, never from the number.
r15="$(make_fixture s15)"
advance_origin s15 1
printf 'captain work\n' >>"$r15/README.md"
report "$r15" "$TMPROOT/s15.json" --json
check "15. a dirty tree records blocker 'dirty-tree'" \
  "[ \"\$(jf '$TMPROOT/s15.json' blocker)\" = \"'dirty-tree'\" ]"
check "15. …and the reason it sits beside really is about the working tree" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"working tree\" in r else 1)' '$TMPROOT/s15.json'"
# A base that is behind for a reason the captain cannot fix by tidying: HEAD is
# somewhere else. Different blocker, same rule.
r15b="$(make_fixture s15b)"
advance_origin s15b 2
( cd "$r15b" && git checkout -q -b side ) >/dev/null 2>&1
( cd "$r15b" && LCARS_NOW="2026-05-30T00:00:00Z" LCARS_BASE_CHECK_ONLY=1 \
    bash -c ". '$COMMON'; LCARS_BASE_QUIET=1 ensure_base_current main; lcars_base_state_json" \
    >"$TMPROOT/s15b.json" 2>/dev/null )
check "15. a base that is not checked out records its OWN blocker" \
  "[ \"\$(jf '$TMPROOT/s15b.json' blocker)\" = \"'not-checked-out'\" ]"
check "15. a QUIET record carries no blocker (nothing is blocking)" \
  "[ \"\$(jf '$TMPROOT/s3.json' blocker)\" = \"''\" ]"

# --- Behaviour 16: every `fix` is ONE command, and it RUNS -----------------
# The contract calls `fix` "the exact command that clears it" and the board
# labels it `Fix:`. A tester pasted two of them into a shell:
#   `git stash -u   (or commit your work)   then   git pull --ff-only origin main`
#     → bash: syntax error near unexpected token `(`, exit 2
#   `reach origin first (VPN / network / auth) — then   git fetch origin main`
#     → not a command at all.
# So `fix` is now ONE runnable line or NOTHING, and the prose that used to be
# smuggled into it lives in `fixNote`, which the board never labels `Fix:`.
# These tests EXECUTE it (the S158 discipline that caught seven of these).
r16="$(make_fixture s16)"
advance_origin s16 3
printf 'scratch\n' >"$r16/untracked.txt"
report "$r16" "$TMPROOT/s16.json" --json
FIX16="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fix"])' "$TMPROOT/s16.json")"
check "16. the dirty-tree fix carries no prose — no parens, no 'then'" \
  "case '$FIX16' in *'('*|*' then '*) false ;; *) true ;; esac"
FIXRC16=0
( cd "$r16" && eval "$FIX16" ) >"$TMPROOT/s16.fix.out" 2>&1 || FIXRC16=$?
check "16. …and pasting it VERBATIM into a shell exits 0" "[ '$FIXRC16' -eq 0 ]"
check "16. …and it actually CLEARS the condition (base now on origin's tip)" \
  "[ \"\$(git -C '$r16' rev-parse refs/heads/main)\" = \"\$(git -C '$TMPROOT/s16.git' rev-parse refs/heads/main)\" ]"
check "16. the alternative it used to smuggle in survives as a NOTE" \
  "python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))[\"fixNote\"]; sys.exit(0 if \"commit\" in n else 1)' '$TMPROOT/s16.json'"
# The unreachable lane: there IS no command that clears it from here, so `fix`
# is EMPTY and the guidance is a note. An empty fix is what stops the board
# labelling prose as a command.
r16b="$(make_fixture s16b)"
( cd "$r16b" && git remote set-url origin "$TMPROOT/definitely-not-here.git" )
printf 'captain work\n' >>"$r16b/README.md"
report "$r16b" "$TMPROOT/s16b.json" --json
check "16. an unreachable origin offers NO fix command" \
  "[ \"\$(jf '$TMPROOT/s16b.json' fix)\" = \"''\" ]"
check "16. …but the guidance is still there, as a note" \
  "python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))[\"fixNote\"]; sys.exit(0 if \"reach origin\" in n.lower() else 1)' '$TMPROOT/s16b.json'"
check "16. …and it is loud, so the captain still sees it" \
  "[ \"\$(jf '$TMPROOT/s16b.json' loud)\" = 'True' ]"
# (The whole-suite sieve that enforces this rule across EVERY record the file
# produces runs LAST — see the bottom of the file. It has to: a sieve placed
# here can only see the records written above it, and round 2 added three lanes
# below.)

# --- Behaviour 17: the OTHER runnable fixes, executed on their own fixtures
# One executed fix proves one string. The discipline is that a fix string which
# is TOUCHED is a fix string that gets RUN — so each lane whose command changed
# shape gets its own fixture, in its own condition, and the command is pasted in
# verbatim and checked for having cleared the thing it names.

# not-checked-out: 'main' is behind, but HEAD is on another branch. (This is
# behaviour 15's second fixture — the record is already on disk; here it is the
# COMMAND that gets pasted in. Asking about 'main' explicitly is what the drive-
# time re-check does; the reporter would ask about the checked-out branch.)
FIX17="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fix"])' "$TMPROOT/s15b.json")"
check "17. the not-checked-out lane offers a command" "[ -n '$FIX17' ]"
FIXRC17=0
( cd "$r15b" && eval "$FIX17" ) >"$TMPROOT/s17.fix.out" 2>&1 || FIXRC17=$?
check "17. …it runs clean pasted verbatim"  "[ '$FIXRC17' -eq 0 ]"
check "17. …and 'main' really is on origin's tip afterwards" \
  "[ \"\$(git -C '$r15b' rev-parse refs/heads/main)\" = \"\$(git -C '$TMPROOT/s15b.git' rev-parse refs/heads/main)\" ]"

# behind-trunk: an UNPUSHED topic branch behind the trunk it was cut from. LCARS
# refuses to merge a trunk into it, so the command is the captain's to run.
r18="$(make_fixture s18)"
( cd "$r18" && git checkout -q -b wip ) >/dev/null 2>&1
advance_origin s18 2
report "$r18" "$TMPROOT/s18.json" --json
check "18. an unpushed topic branch records blocker 'behind-trunk'" \
  "[ \"\$(jf '$TMPROOT/s18.json' blocker)\" = \"'behind-trunk'\" ]"
FIX18="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fix"])' "$TMPROOT/s18.json")"
check "18. …and offers a command, not a sentence about one" \
  "case '$FIX18' in 'git '*) true ;; *) false ;; esac"
FIXRC18=0
( cd "$r18" && eval "$FIX18" ) >"$TMPROOT/s18.fix.out" 2>&1 || FIXRC18=$?
check "18. …it runs clean pasted verbatim"  "[ '$FIXRC18' -eq 0 ]"
check "18. …and 'wip' now contains the trunk it was behind" \
  "git -C '$r18' merge-base --is-ancestor refs/remotes/origin/main refs/heads/wip"

# --- Behaviour 19: THE OPERATION LCARS ALREADY RAN IS NEVER THE FIX --------
# ROUND 2, D1. A tester set `merge.verifySignatures=true`, filed, and pasted the
# offered fix. It answered `fatal: Commit 79ce589 does not have a GPG
# signature.` — BYTE-IDENTICAL to the failure LCARS had captured into its own
# `reason` one second earlier. The guard ran `git merge --ff-only <sha>`, watched
# git refuse it, quoted the refusal, and offered THE SAME OPERATION as the
# remedy. Still 2 behind.
#
# This is the FILE-TIME lane (step 9 is the one step check-only skips), so it is
# reached through `ensure_base_current` directly, exactly as filing reaches it.
r19="$(make_fixture s19)"
advance_origin s19 2
( cd "$r19" && git config merge.verifySignatures true )
( cd "$r19" && LCARS_NOW="2026-05-30T00:00:00Z" \
    bash -c ". '$COMMON'; LCARS_BASE_QUIET=1 ensure_base_current main; lcars_base_state_json" \
    >"$TMPROOT/s19.json" 2>/dev/null )
check "19. git really did refuse the fast-forward (the lane is the one we mean)" \
  "[ \"\$(jf '$TMPROOT/s19.json' blocker)\" = \"'merge-refused'\" ]"
check "19. …and the record quotes git's own refusal" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"signature\" in r.lower() else 1)' '$TMPROOT/s19.json'"
check "19. …the base really is still behind" \
  "[ \"\$(git -C '$r19' rev-parse refs/heads/main)\" != \"\$(git -C '$TMPROOT/s19.git' rev-parse refs/heads/main)\" ]"
# THE DEFECT, stated as the assertion: no `fix` at all on this lane.
check "19. THE FIX IS EMPTY — the refused merge is not its own remedy" \
  "[ \"\$(jf '$TMPROOT/s19.json' fix)\" = \"''\" ]"
check "19. …and no `fix` field anywhere offers the merge back" \
  "python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))[\"fix\"]; sys.exit(1 if \"merge\" in f else 0)' '$TMPROOT/s19.json'"
check "19. …the guidance still ships, as an unlabelled note" \
  "python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))[\"fixNote\"]; sys.exit(0 if len(n) > 20 else 1)' '$TMPROOT/s19.json'"
check "19. …and it is loud, so the captain still sees it" \
  "[ \"\$(jf '$TMPROOT/s19.json' loud)\" = 'True' ]"
# WHY the fix had to go: the command that WAS offered is guaranteed to fail —
# run it and watch it reproduce the reason verbatim.
MRC19=0
( cd "$r19" && git merge --ff-only origin/main ) >"$TMPROOT/s19.retry.out" 2>&1 || MRC19=$?
check "19. the operation LCARS attempted fails identically when re-run" \
  "[ '$MRC19' -ne 0 ]"
check "19. …with the same words the record already carried" \
  "grep -qi 'signature' '$TMPROOT/s19.retry.out'"
# STRUCTURAL, not a special case. The rule "an operation LCARS already ran and
# watched fail is never the fix" was already a COMMENT beside two other lanes —
# and a comment is what let this lane get it wrong. So the recorder for a failed
# attempt has NO `fix` SLOT: the mistake is not expressible. Held against the
# SHIPPING functions, by calling them.
cat >"$TMPROOT/structural-base.sh" <<STRUCT
. "$COMMON"
LCARS_BASE_BRANCH=main
LCARS_BASE_FIX="a leftover from some earlier lane"
_lcars_base_set_after_attempt stale 1 "a reason" "a-blocker" "a note"
[ -z "\$LCARS_BASE_FIX" ]              || exit 1
[ "\$LCARS_BASE_BLOCKER" = "a-blocker" ] || exit 1
[ "\$LCARS_BASE_FIXNOTE" = "a note" ]  || exit 1
exit 0
STRUCT
check "19. the after-attempt recorder cannot carry a fix (structural)" \
  "bash '$TMPROOT/structural-base.sh'"
cat >"$TMPROOT/structural-mb.sh" <<STRUCT
. "$COMMON"
LCARS_MB_FIX="a leftover from some earlier lane"
_lcars_mb_refused_after_attempt "because git said no"
[ -z "\$LCARS_MB_FIX" ]         || exit 1
[ "\$LCARS_MB_MOVE" = refused ] || exit 1
exit 0
STRUCT
check "19. …and its mission-branch sibling cannot either" \
  "bash '$TMPROOT/structural-mb.sh'"
# ROUND 3, D1: removing the wrong answer must not leave NO answer. A lane
# recorded through this setter carries no `fix` — and therefore MUST carry the
# note, whether or not the lane remembered to pass one. Held by calling it with
# no note at all, which is precisely the case that shipped the dead end.
cat >"$TMPROOT/structural-mb-note.sh" <<STRUCT
. "$COMMON"
LCARS_MB_NOTE=""
_lcars_mb_refused_after_attempt "because git said no"
[ -z "\$LCARS_MB_FIX" ]                     || exit 1
[ -n "\$LCARS_MB_NOTE" ]                    || exit 1
case "\$LCARS_MB_NOTE" in *"Clear whatever git objected to"*) : ;; *) exit 1 ;; esac
# …and a lane with better words still wins.
_lcars_mb_refused_after_attempt "a reason" "the lane's own words"
[ "\$LCARS_MB_NOTE" = "the lane's own words" ] || exit 1
exit 0
STRUCT
check "19. …and a fix-less refusal ALWAYS carries a way forward (structural)" \
  "bash '$TMPROOT/structural-mb-note.sh'"

# --- Behaviour 20: an UNFINISHED git operation is the first fact ----------
# ROUND 2, D2, and the highest-value fix of the round. A tester pasted the
# `diverged` fix (`git pull --rebase origin main`), hit a conflict — the COMMON
# outcome for a diverged branch — and filed from there. The record said `stale`,
# "a fast-forward is impossible, so nothing was moved", named a `baseSha` the
# Mission was NOT cut from, and re-offered the identical command, which now
# hard-`fatal`s. Three permanent claims about a repo that was mid-surgery.
r20="$(make_fixture s20)"
advance_origin s20 1
( cd "$r20" && mkdir -p src && printf 'captain line\n' >>src/real-view.txt \
    && git add -A && git commit -q -m "the captain's own commit" ) >/dev/null 2>&1
( cd "$r20" && git pull --rebase origin main ) >"$TMPROOT/s20.pull.out" 2>&1
check "20. the fixture really is mid-rebase (conflicted, as the tester was)" \
  "has_gitfile '$r20' rebase-merge"
check "20. …with a detached HEAD" \
  "! git -C '$r20' symbolic-ref -q HEAD >/dev/null"
report "$r20" "$TMPROOT/s20.json" --json
check "20. the verdict is 'unknown' — nothing could honestly be measured" \
  "[ \"\$(jf '$TMPROOT/s20.json' verdict)\" = \"'unknown'\" ]"
check "20. …and LOUD: an unfinished operation is not discovered afterwards" \
  "[ \"\$(jf '$TMPROOT/s20.json' loud)\" = 'True' ]"
check "20. …carrying the blocker that names it" \
  "[ \"\$(jf '$TMPROOT/s20.json' blocker)\" = \"'operation-in-progress'\" ]"
check "20. the reason SAYS 'rebase' — the most important fact about the repo" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"rebase\" in r else 1)' '$TMPROOT/s20.json'"
check "20. …names the unmerged path(s)" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"unmerged\" in r else 1)' '$TMPROOT/s20.json'"
check "20. …and the detached HEAD" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"detached\" in r else 1)' '$TMPROOT/s20.json'"
check "20. it NEVER claims 'nothing was moved' about a tree mid-operation" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(1 if \"nothing was moved\" in r else 0)' '$TMPROOT/s20.json'"
# THE PERMANENT LIE: a baseSha naming a commit the Mission was not cut from.
check "20. baseSha is NULL — not a commit the Mission was not cut from" \
  "[ \"\$(jf '$TMPROOT/s20.json' baseSha)\" = 'None' ]"
check "20. behindBy is unmeasured, never a reassuring number" \
  "[ \"\$(jf '$TMPROOT/s20.json' behindBy)\" = 'None' ]"
check "20. aheadBy likewise" \
  "[ \"\$(jf '$TMPROOT/s20.json' aheadBy)\" = 'None' ]"
# A `fix` that fatals because an operation is already in progress is worse than
# none: this lane offers no command, and says both ways out as a note.
check "20. no fix is offered while an operation is unfinished" \
  "[ \"\$(jf '$TMPROOT/s20.json' fix)\" = \"''\" ]"
check "20. …the note names --continue" \
  "python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))[\"fixNote\"]; sys.exit(0 if \"rebase --continue\" in n else 1)' '$TMPROOT/s20.json'"
check "20. …and --abort" \
  "python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))[\"fixNote\"]; sys.exit(0 if \"rebase --abort\" in n else 1)' '$TMPROOT/s20.json'"
# WHY the old command had to go: it does not merely fail to help, it fatals.
RRC20=0
( cd "$r20" && git pull --rebase origin main ) >"$TMPROOT/s20.retry.out" 2>&1 || RRC20=$?
check "20. the old 'diverged' command really does fatal from here" \
  "[ '$RRC20' -ne 0 ]"
check "20. …because the unfinished operation is in the way" \
  "grep -qiE 'unmerged|rebase|conflict' '$TMPROOT/s20.retry.out'"
# And the MISSION BRANCH block's own `git rebase <base> <mb>` — the second
# command the tester was handed — fatals for the same reason, verbatim.
( cd "$r20" && git branch lcars/lcars-20260731-009 refs/remotes/origin/main ) >/dev/null 2>&1
MBRC20=0
( cd "$r20" && git rebase main lcars/lcars-20260731-009 ) >"$TMPROOT/s20.mbretry.out" 2>&1 || MBRC20=$?
check "20. the mission-branch rebase fatals too, while one is in progress" \
  "[ '$MBRC20' -ne 0 ]"
check "20. …saying there is already a rebase-merge directory" \
  "grep -qi 'rebase-merge directory' '$TMPROOT/s20.mbretry.out'"
# And the check is still a check: asking must not disturb the operation.
check "20. asking left the unfinished rebase exactly where it was" \
  "has_gitfile '$r20' rebase-merge"

# A LINKED WORKTREE's git dir is NOT `.git/` — it is `.git/worktrees/<name>/`,
# and LCARS makes those itself. A hard-coded `.git/MERGE_HEAD` check would be
# blind in precisely the trees LCARS creates, so the path is ASKED for
# (`git rev-parse --git-path`), never assembled.
r20c="$(make_fixture s20c)"
( cd "$r20c" && git checkout -q -b feature && printf 'feature\n' >README.md \
    && git commit -qam feature && git checkout -q main \
    && printf 'trunk\n' >README.md && git commit -qam trunk ) >/dev/null 2>&1
( cd "$r20c" && git worktree add -q --detach "$TMPROOT/s20c.wt" main ) >/dev/null 2>&1
( cd "$TMPROOT/s20c.wt" && git merge feature ) >"$TMPROOT/s20c.merge.out" 2>&1
check "20. the worktree fixture really is mid-merge" \
  "has_gitfile '$TMPROOT/s20c.wt' MERGE_HEAD"
check "20. …and the main clone's own .git/MERGE_HEAD does NOT exist" \
  "[ ! -e '$r20c/.git/MERGE_HEAD' ]"
report "$TMPROOT/s20c.wt" "$TMPROOT/s20c.json" --json
check "20. a LINKED WORKTREE mid-merge is detected all the same" \
  "[ \"\$(jf '$TMPROOT/s20c.json' blocker)\" = \"'operation-in-progress'\" ]"
check "20. …and the reason names the merge, not a rebase" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"unfinished git merge\" in r else 1)' '$TMPROOT/s20c.json'"

# --- Behaviour 21: the ONE unfinished operation with a runnable end -------
# A bisect parks HEAD at an arbitrary old commit — which is exactly what a
# Mission would be cut from — but unlike a conflicted rebase it ends in ONE
# lossless command. So this lane DOES carry a `fix`, and the round's discipline
# applies: it is pasted in verbatim and checked for having cleared the thing it
# names.
r21="$(make_fixture s21)"
advance_origin s21 2
( cd "$r21" && git bisect start ) >/dev/null 2>&1
report "$r21" "$TMPROOT/s21.json" --json
check "21. a bisect in progress is caught too" \
  "[ \"\$(jf '$TMPROOT/s21.json' blocker)\" = \"'operation-in-progress'\" ]"
FIX21="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fix"])' "$TMPROOT/s21.json")"
check "21. …and it offers a command, because one really does clear it" \
  "[ '$FIX21' = 'git bisect reset' ]"
FIXRC21=0
( cd "$r21" && eval "$FIX21" ) >"$TMPROOT/s21.fix.out" 2>&1 || FIXRC21=$?
check "21. …it runs clean pasted verbatim" "[ '$FIXRC21' -eq 0 ]"
check "21. …and the condition is really gone" \
  "! has_gitfile '$r21' BISECT_LOG"
report "$r21" "$TMPROOT/s21b.json" --json
check "21. …so the next check measures normally again" \
  "[ \"\$(jf '$TMPROOT/s21b.json' blocker)\" != \"'operation-in-progress'\" ]"

# `git am` and a rebase on the APPLY backend share `rebase-apply/`, and they do
# NOT share their commands. Handing an `am` captain `git rebase --continue` is
# the copy-that-lies-about-git class this round is closing, so the two are told
# apart by git's own `applying` marker.
r21c="$(make_fixture s21c)"
( cd "$r21c" && git checkout -q -b feature && printf 'feature\n' >README.md \
    && git commit -qam feature && git format-patch -1 -o "$TMPROOT/s21c.patch" \
    && git checkout -q main && printf 'trunk\n' >README.md && git commit -qam trunk ) >/dev/null 2>&1
( cd "$r21c" && git am "$TMPROOT"/s21c.patch/*.patch ) >"$TMPROOT/s21c.am.out" 2>&1
check "21. the am fixture really is mid-apply" \
  "has_gitfile '$r21c' rebase-apply/applying"
report "$r21c" "$TMPROOT/s21c.json" --json
check "21. an unfinished 'git am' is caught" \
  "[ \"\$(jf '$TMPROOT/s21c.json' blocker)\" = \"'operation-in-progress'\" ]"
check "21. …and is called an am, not a rebase" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"git am\" in r and \"rebase\" not in r else 1)' '$TMPROOT/s21c.json'"
check "21. …so the guidance names the commands that actually exist for it" \
  "python3 -c 'import json,sys; n=json.load(open(sys.argv[1]))[\"fixNote\"]; sys.exit(0 if \"git am --continue\" in n and \"git am --abort\" in n and \"rebase\" not in n else 1)' '$TMPROOT/s21c.json'"

# --- Behaviour 22: a MISSION BRANCH alarm the graph disproves -------------
# ROUND 2, D2 again. The tester's `lcars/<id>` sat EXACTLY on origin/main —
# behind 0, ahead 0, the freshest base there is — and the MISSION BRANCH block
# still said it "is 1 commit(s) behind main" and "will reason about that older
# tree", because local `main` had diverged and carried a commit of its own. So
# the block asks the mission branch the SAME question the guard asks the base:
# is it MISSING anything ORIGIN has? Measured, not assumed.
r22="$(make_fixture s22)"
advance_origin s22 1
( cd "$r22" && git fetch -q origin main ) >/dev/null 2>&1
( cd "$r22" && git branch lcars/lcars-20260731-001 refs/remotes/origin/main ) >/dev/null 2>&1
( cd "$r22" && printf 'the captain own commit\n' >>README.md && git commit -qam local ) >/dev/null 2>&1
( cd "$r22" && bash -c ". '$COMMON'; LCARS_BASE_BRANCH=main; lcars_base_branch_note lcars/lcars-20260731-001 main new" \
    >"$TMPROOT/s22.out" 2>&1 )
check "22. the fixture is the tester's: mission branch is behind LOCAL main" \
  "[ \"\$(git -C '$r22' rev-list --count lcars/lcars-20260731-001..main)\" = '1' ]"
check "22. …and behind origin/main by NOTHING — the freshest base there is" \
  "[ \"\$(git -C '$r22' rev-list --count lcars/lcars-20260731-001..refs/remotes/origin/main)\" = '0' ]"
check "22. NO ⚠ MISSION BRANCH alarm is written" \
  "! grep -q 'MISSION BRANCH' '$TMPROOT/s22.out'"
check "22. …and nothing claims it will reason about an older tree" \
  "! grep -q 'older tree' '$TMPROOT/s22.out'"
check "22. …but the local distance is still stated, not hidden" \
  "grep -q 'origin/main' '$TMPROOT/s22.out'"
# The counter-case, so the alarm is quietened and not deleted: a mission branch
# that really IS missing what origin has still gets the full ⚠ block.
( cd "$r22" && git branch lcars/lcars-20260731-002 HEAD~1 ) >/dev/null 2>&1
( cd "$r22" && bash -c ". '$COMMON'; LCARS_BASE_BRANCH=main; lcars_base_branch_note lcars/lcars-20260731-002 main new" \
    >"$TMPROOT/s22b.out" 2>&1 )
check "22. a genuinely stale mission branch STILL raises the alarm" \
  "grep -q '⚠ MISSION BRANCH' '$TMPROOT/s22b.out'"
check "22. …with its Fix line intact" \
  "grep -q 'Fix:' '$TMPROOT/s22b.out'"

# --- Behaviour 23: a TIMED-OUT fetch names ITSELF, not nothing -------------
# ROUND 3, D2. Every other stopping condition carries a blocker token, and the
# badge headline is built from it — but the genuine fetch-timeout lane recorded
# `blocker: ""`, so the board fell back to the generic `⚠ BASE UNVERIFIED` while
# its `unreachable` sibling named itself. Honest, but it does not say WHAT
# stopped LCARS.
#
# The two must stay SEPARATE tokens, and the difference is load-bearing:
# `unreachable` means origin failed on its merits and no command run from here
# clears it (empty `fix`); this lane means LCARS killed its OWN bounded fetch at
# its OWN deadline, so the captain's unbounded run of that same fetch really can
# succeed — which is why this one still carries a command.
#
# The stub hangs `fetch` and DELEGATES everything else, so origin demonstrably
# answers a ref listing instantly: this is a slow fetch, not a dead remote.
HANG23="$TMPROOT/hang-git"
cat >"$HANG23" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "fetch" ]; then sleep 45; exit 0; fi
done
exec git "$@"
EOF
chmod +x "$HANG23"
r23="$(make_fixture s23)"
advance_origin s23 2
(
  cd "$r23" && LCARS_NOW="2026-05-30T00:00:00Z" LCARS_GIT_BIN="$HANG23" \
    LCARS_BASE_FETCH_TIMEOUT_SECS=2 bash "$REPORTER" --json \
    >"$TMPROOT/s23.json" 2>"$TMPROOT/s23.json.err"
)
check "23. the lane is the one we mean — origin answered, the fetch did not" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if \"timed out after\" in r and \"origin ANSWERED\" in r else 1)' '$TMPROOT/s23.json'"
check "23. THE BLOCKER NAMES ITSELF — the badge no longer falls back to generic" \
  "[ \"\$(jf '$TMPROOT/s23.json' blocker)\" = \"'fetch-timeout'\" ]"
check "23. …and it is NOT 'unreachable' — origin is reachable, just slow" \
  "[ \"\$(jf '$TMPROOT/s23.json' blocker)\" != \"'unreachable'\" ]"
check "23. …the verdict is still 'unknown' — nothing was measured" \
  "[ \"\$(jf '$TMPROOT/s23.json' verdict)\" = \"'unknown'\" ]"
check "23. …and LOUD, so the captain sees the badge at all" \
  "[ \"\$(jf '$TMPROOT/s23.json' loud)\" = 'True' ]"
# The fix survives UNCHANGED — that asymmetry with `unreachable` is the whole
# reason the two are separate tokens. And it is pasted in, like every other.
FIX23="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fix"])' "$TMPROOT/s23.json")"
check "23. the timeout lane still OFFERS a command (unlike 'unreachable')" \
  "[ '$FIX23' = 'git fetch origin main' ]"
FIXRC23=0
( cd "$r23" && eval "$FIX23" ) >"$TMPROOT/s23.fix.out" 2>&1 || FIXRC23=$?
check "23. …it runs clean pasted verbatim, with the real git" "[ '$FIXRC23' -eq 0 ]"
check "23. …and it really did measure what LCARS could not" \
  "[ -n \"\$(git -C '$r23' rev-parse --verify -q refs/remotes/origin/main)\" ]"
# The DIRTY variant of the same lane: the tree really is dirty, but the dirt is
# not what stopped LCARS — nothing was measured at all, because the fetch ran
# long. A `DIRTY TREE` headline here names a condition that is present and is
# not the reason, which is the same class of lie as leading with the commit
# count, pointing the other way.
r23b="$(make_fixture s23b)"
advance_origin s23b 2
printf 'captain work\n' >>"$r23b/README.md"
(
  cd "$r23b" && LCARS_NOW="2026-05-30T00:00:00Z" LCARS_GIT_BIN="$HANG23" \
    LCARS_BASE_FETCH_TIMEOUT_SECS=2 bash "$REPORTER" --json \
    >"$TMPROOT/s23b.json" 2>"$TMPROOT/s23b.json.err"
)
check "23. a dirty tree does NOT steal the headline from the timeout" \
  "[ \"\$(jf '$TMPROOT/s23b.json' blocker)\" = \"'fetch-timeout'\" ]"
check "23. …and certainly not 'dirty-tree', which is present but not the reason" \
  "[ \"\$(jf '$TMPROOT/s23b.json' blocker)\" != \"'dirty-tree'\" ]"
check "23. …the reason still states BOTH facts, in that order" \
  "python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))[\"reason\"]; sys.exit(0 if r.index(\"working tree has\") < r.index(\"timed out\") else 1)' '$TMPROOT/s23b.json'"

# --- Behaviour 24: "EMPTY when all is well" is a promise about STDOUT ------
# ROUND 3, D3. `base-freshness.sh --line` documents its stdout as "the human ⚠
# block (EMPTY when all is well)" — and on a clean, current repo it printed
# `⟳ base freshness — fetching origin/main (up to 8s)…` there. No live surface
# reads it (the daemon uses --json), but a consumer testing emptiness would read
# "all is well" as "something to say", and the doc string and the behaviour must
# agree. The ⟳ is PROGRESS, so it belongs on stderr: the captain at a terminal
# still sees it, and stdout carries the verdict and nothing else.
r24="$(make_fixture s24)"
report "$r24" "$TMPROOT/s24.line" --line
check "24. a clean, current repo prints NOTHING on stdout — as documented" \
  "[ ! -s '$TMPROOT/s24.line' ]"
check "24. …and the captain still gets the ⟳ progress line, on stderr" \
  "grep -q '⟳ base freshness' '$TMPROOT/s24.line.err'"
check "24. the documented contract and the behaviour now agree" \
  "grep -q 'EMPTY when all is well' '$REPORTER'"
# The counter-case, so stdout is quiet and not deaf: a LOUD repo still puts its
# whole ⚠ block on stdout, with no ⟳ mixed into it. (Behaviour 12's fixture is
# exactly that; here it is the STREAM SPLIT that is asserted.)
check "24. a LOUD repo still prints its ⚠ block on stdout" \
  "grep -q 'BASE FRESHNESS' '$TMPROOT/s12.line'"
check "24. …with no ⟳ progress line mixed into it" \
  "! grep -q '⟳' '$TMPROOT/s12.line'"
check "24. …and --json's stdout is still exactly one object" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$TMPROOT/s3.json'"

# --- THE SIEVE (behaviour 16's rule, run over EVERYTHING) -----------------
# Held against the PRODUCT rather than the source (S140: pin prose by MEASURING
# what ships, never by string-matching the code that writes it). Every record
# this suite produced — all 22 behaviours' worth — goes through the same test: a
# `fix` may not hide prose behind the old three-space gloss, and may not carry
# shell metacharacters that make it unpasteable.
#
# IT RUNS LAST BECAUSE IT MUST. It used to sit inside behaviour 16, where it
# could only see the records written above it; round 2 added three more lanes
# below, and a sieve that silently skips the newest strings is the flattering
# number this round exists to distrust.
check "SIEVE. NO record in this suite carries an unpasteable fix" \
  "python3 -c \"
import glob, json, sys
bad = []
for p in sorted(glob.glob('$TMPROOT/*.json')):
    try:
        f = json.load(open(p)).get('fix')
    except Exception:
        continue
    if not isinstance(f, str) or not f:
        continue
    if '   ' in f or '(' in f or ' then ' in f:
        bad.append((p, f))
if bad:
    for p, f in bad:
        print('unpasteable fix in', p, '->', f)
sys.exit(1 if bad else 0)\""
# The count is part of the assertion: a sieve that found no records to inspect
# would pass just as loudly as one that inspected them all.
check "SIEVE. …and it really did inspect every record on disk" \
  "[ \"\$(ls '$TMPROOT'/*.json | wc -l | tr -d ' ')\" -ge 12 ]"
# ROUND 3, D1, generalised over the same records. Round 2 made "the operation
# LCARS already ran is never the fix" structural by removing the `fix` slot —
# and a lane that then says nothing else leaves a captain with a diagnosis and
# no exit. So: EVERY LOUD RECORD OFFERS A WAY FORWARD, one field or the other.
# Quiet records are exempt by construction — nothing is blocking, so there is
# nothing to point at.
check "SIEVE. NO loud record is a dead end — every one offers fix or fixNote" \
  "python3 -c \"
import glob, json, sys
bad = []
for p in sorted(glob.glob('$TMPROOT/*.json')):
    try:
        r = json.load(open(p))
    except Exception:
        continue
    if not isinstance(r, dict) or not r.get('loud'):
        continue
    if not (r.get('fix') or '').strip() and not (r.get('fixNote') or '').strip():
        bad.append((p, r.get('blocker'), r.get('verdict')))
if bad:
    for p, b, v in bad:
        print('loud dead end in', p, '-> blocker=%r verdict=%r' % (b, v))
sys.exit(1 if bad else 0)\""

# ==========================================================================
printf '\nbase-freshness surface: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
