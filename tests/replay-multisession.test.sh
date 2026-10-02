#!/usr/bin/env bash
# Fast, SCOPED test for the MULTI-SESSION TICKET COMMIT contract.
#
# A ticket that needs more than one TDD session builds in ONE per-ticket
# worktree: on a gate bounce the loop re-spawns a fresh worker but does NOT
# reset the worktree, so session N commits ON TOP of session N-1's commit
# (skills/lcars-run/run.sh — `_tdd_reject` clears result.json, never the tree).
#
# Everything downstream, however, assumes ONE commit per ticket: `commit_ticket`
# records a SINGLE `.commit-sha`, and cmd_implement's wave-end replay
# cherry-picks exactly that one commit onto the mission branch (run.sh ~:9055,
# "the parent cherry-picks those in plan order"; S133: "the ticket's tests ride
# in its ONE commit"). With N session commits, `rev-parse HEAD` names only the
# LAST one — so replay carries session N's diff and SILENTLY DROPS sessions
# 1..N-1.
#
# Observed live: a scaffold ticket took 4 sessions. Session 3 committed the whole
# app (13 files); session 4 added only package-lock.json. `.commit-sha` named
# session 4, so the wave-end replay put a lone lockfile on the mission branch and
# the entire scaffold vanished — with every gate green, because every gate ran
# against the worktree where the full tree existed. Silent work loss.
#
# The contract: after N sessions, `.commit-sha` must name ONE commit whose diff
# vs the wave base is the ticket's CUMULATIVE work. Then the existing single-
# commit cherry-pick lands all of it, unchanged.
#
# Zero tokens, real git, no worker. NOT the heavy lcars-run.test.sh.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

MISSION=m-001
TICKET=t-001

# A repo with an initial commit, a mission branch, and a mission fixture whose
# state.json names that branch (commit_ticket reads `branch` from it).
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  printf 'seed\n' > "$repo/README.md"
  ( cd "$repo" && git add -A && git commit -qm "Initial commit" )
  ( cd "$repo" && git branch "lcars/$MISSION" )
  mkdir -p "$repo/.git/lcars/missions/$MISSION/tickets/$TICKET"
  cat > "$repo/.git/lcars/missions/$MISSION/state.json" <<JSON
{ "id":"$MISSION","type":"feature","title":"t","stage":"implement","branch":"lcars/$MISSION" }
JSON
  echo "$repo"
}

# Cut the per-ticket worktree exactly as cmd_implement does: detached at the
# mission-branch tip (git forbids a 2nd checkout of a checked-out branch).
new_worktree() { # repo → worktree path
  local repo="$1" wt="$1/.git/lcars/missions/$MISSION/worktrees/$TICKET"
  ( cd "$repo" && git worktree add -q --detach "$wt" "lcars/$MISSION" )
  : > "$repo/.git/lcars/missions/$MISSION/tickets/$TICKET/.untracked-before"
  echo "$wt"
}

# One TDD session: write files into the worktree, then drive the REAL
# commit_ticket through its inert test hook, in worktree mode.
session() { # repo worktree summary
  local repo="$1" wt="$2" summary="$3"
  ( cd "$wt" && LCARS_TICKET_WORKTREE="$wt" \
      bash "$SCRIPT" commit-ticket-test --mission "$MISSION" --ticket "$TICKET" "$summary" \
      >/dev/null 2>&1 )
}

TD() { echo "$1/.git/lcars/missions/$MISSION/tickets/$TICKET"; }

printf '\nreplay multi-session commit\n'

# --- 1. the live shape: two sessions, second adds only one file -------------
repo="$(new_repo)"
wt="$(new_worktree "$repo")"

# Session 1 — the substantive build (the "scaffold").
mkdir -p "$wt/src"
printf 'export const App = () => null;\n' > "$wt/src/App.tsx"
printf '{ "name": "app" }\n'              > "$wt/package.json"
session "$repo" "$wt" "session 1: scaffold"
sha1="$(cat "$(TD "$repo")/.commit-sha" 2>/dev/null)"
check "1. session 1 records a .commit-sha" "[ -n '$sha1' ]"

# Session 2 — a bounce fix that only ADDS a lockfile (the live t-001 shape).
printf '{ "lockfileVersion": 3 }\n' > "$wt/package-lock.json"
session "$repo" "$wt" "session 2: add lockfile"
sha2="$(cat "$(TD "$repo")/.commit-sha" 2>/dev/null)"
check "1. session 2 records a .commit-sha" "[ -n '$sha2' ]"
check "1. the recorded sha ADVANCED after session 2" "[ '$sha1' != '$sha2' ]"

# THE CONTRACT: .commit-sha names ONE commit rooted at the wave base, whose OWN
# PATCH is the ticket's cumulative work. Compare the commit against its PARENT
# (not the base): a tree diff would pass even when the commit is a lone slice
# stacked on session 1, which is precisely the bug — cherry-pick applies the
# patch, not the tree.
base="$( cd "$repo" && git rev-parse "lcars/$MISSION" )"
check "1. the recorded commit is rooted AT the wave base (one commit, not a stack)" \
  "[ \"\$( cd '$repo' && git rev-parse '$sha2^' )\" = '$base' ]"
patch="$( cd "$repo" && git diff --name-only "$sha2^" "$sha2" 2>/dev/null | sort | tr '\n' ' ' )"
check "1. its own patch carries session 1's src/App.tsx" \
  "printf '%s' \"$patch\" | grep -q 'src/App.tsx'"
check "1. its own patch carries session 1's package.json" \
  "printf '%s' \"$patch\" | grep -q 'package.json'"
check "1. its own patch carries session 2's package-lock.json" \
  "printf '%s' \"$patch\" | grep -q 'package-lock.json'"

# --- 2. the real consequence: the single-commit cherry-pick lands it all ----
# This is what cmd_implement actually does at wave end. It must reproduce the
# ticket's WHOLE tree on the mission branch, not just the last session's slice.
( cd "$repo" && git checkout -q "lcars/$MISSION" && git cherry-pick -n "$sha2" >/dev/null 2>&1 \
    && git commit -qm "replayed $TICKET" )
check "2. replay lands src/App.tsx on the mission branch" \
  "( cd '$repo' && git show 'lcars/$MISSION:src/App.tsx' >/dev/null 2>&1 )"
check "2. replay lands package.json on the mission branch" \
  "( cd '$repo' && git show 'lcars/$MISSION:package.json' >/dev/null 2>&1 )"
check "2. replay lands package-lock.json on the mission branch" \
  "( cd '$repo' && git show 'lcars/$MISSION:package-lock.json' >/dev/null 2>&1 )"

# --- 3. the single-session path is UNCHANGED (no regression) ----------------
repo3="$(new_repo)"
wt3="$(new_worktree "$repo3")"
printf 'one\n' > "$wt3/only.txt"
session "$repo3" "$wt3" "single session"
sha3="$(cat "$(TD "$repo3")/.commit-sha" 2>/dev/null)"
base3="$( cd "$repo3" && git rev-parse "lcars/$MISSION" )"
check "3. a single-session ticket still records one commit" "[ -n '$sha3' ]"
check "3. its parent IS the wave base (unchanged shape)" \
  "[ \"\$( cd '$repo3' && git rev-parse '$sha3^' )\" = '$base3' ]"
check "3. it carries exactly its own file" \
  "[ \"\$( cd '$repo3' && git diff --name-only '$base3' '$sha3' | tr '\n' ' ' )\" = 'only.txt ' ]"

# --- 4. THE WORKER'S REPORT IS A COMMIT MESSAGE, NOT A COMMIT SUBJECT ------
# Observed live: every ticket commit carried its worker's whole multi-paragraph
# report on LINE 1, so `git log --oneline` (and any GitHub commit list) was one
# unreadable 200+ character wall per ticket and the body was EMPTY.
#
# Mechanism: cmd_implement hands commit_ticket `json_str "$RESULT" summary`, and
# json_str decodes only \" and \\ — never \n — so the report arrives as ONE
# physical line with literal backslash-n in it, and commit_ticket passed that
# whole string to a single `git commit -m`. Git puts a `-m` with no blank line
# in it entirely in the subject.
#
# The contract: a SHORT subject that still carries the `lcars(<id>) <ticket>:`
# prefix (child_commits_reachable / resolve-logs match on it), and the report
# WHOLE in the body with real newlines.
repo4="$(new_repo)"
wt4="$(new_worktree "$repo4")"
printf 'x\n' > "$wt4/a.txt"
# Exactly the shape json_str hands over: one line, literal \n escapes.
SUMM4='Added the dark token set and wired the toggle.\n\nThe toggle persists to localStorage and is read on boot, and the theme\nprovider moved above the router.\n\nTests: 4 added, all green.'
session "$repo4" "$wt4" "$SUMM4"
sha4="$(cat "$(TD "$repo4")/.commit-sha" 2>/dev/null)"
subj4="$( cd "$repo4" && git log -1 --format=%s "$sha4" 2>/dev/null )"
len4="${#subj4}"
check "4. the ticket still commits" "[ -n '$sha4' ]"
check "4. the subject is a SHORT line, not the whole report (<=72 chars, was 227)" \
  "[ '$len4' -le 72 ]"
check "4. the subject keeps the lcars(<id>) <ticket>: prefix" \
  "printf '%s' \"\$( cd '$repo4' && git log -1 --format=%s '$sha4' )\" | grep -q 'lcars($MISSION) $TICKET:'"
check "4. the subject opens with the report's first sentence" \
  "printf '%s' \"\$( cd '$repo4' && git log -1 --format=%s '$sha4' )\" | grep -q 'Added the dark token set'"
check "4. NO literal backslash-n survives into the subject" \
  "! printf '%s' \"\$( cd '$repo4' && git log -1 --format=%s '$sha4' )\" | grep -q '\\\\n'"
check "4. the report's LATER paragraphs land in the body (nothing lost)" \
  "printf '%s' \"\$( cd '$repo4' && git log -1 --format=%b '$sha4' )\" | grep -q 'localStorage'"
check "4. the body carries the closing paragraph too" \
  "printf '%s' \"\$( cd '$repo4' && git log -1 --format=%b '$sha4' )\" | grep -q 'Tests: 4 added'"
check "4. the body is REAL newlines, not backslash-n escapes" \
  "! printf '%s' \"\$( cd '$repo4' && git log -1 --format=%b '$sha4' )\" | grep -q '\\\\n'"
check "4. the body is genuinely multi-line" \
  "[ \"\$( cd '$repo4' && git log -1 --format=%b '$sha4' | wc -l | tr -d ' ' )\" -gt 1 ]"
check "4. git log --oneline prints ONE short line for the ticket" \
  "[ \"\$( cd '$repo4' && git log --oneline -1 '$sha4' | awk '{ print (length(\$0) <= 90) }' )\" = 1 ]"

# A report that is ONE long line with no paragraph break at all — the subject
# must be CLIPPED, and then the whole report must still be in the body.
repo4c="$(new_repo)"
wt4c="$(new_worktree "$repo4c")"
printf 'z\n' > "$wt4c/c.txt"
session "$repo4c" "$wt4c" "Rewrote the theme provider so the router can read the theme on its very first render, which it could not do before because the provider mounted underneath it."
sha4c="$(cat "$(TD "$repo4c")/.commit-sha" 2>/dev/null)"
subj4c="$( cd "$repo4c" && git log -1 --format=%s "$sha4c" 2>/dev/null )"
len4c="${#subj4c}"
check "4. an unbroken 160-char report still gets a short subject" "[ '$len4c' -le 72 ]"
check "4. the clipped subject says so (ellipsis)" \
  "printf '%s' \"\$( cd '$repo4c' && git log -1 --format=%s '$sha4c' )\" | grep -q '…'"
check "4. a CLIPPED subject keeps the whole report in the body (nothing lost)" \
  "printf '%s' \"\$( cd '$repo4c' && git log -1 --format=%b '$sha4c' )\" | grep -q 'mounted underneath it'"

# A report that ALREADY has real newlines (a test/alt caller) splits the same way.
repo4b="$(new_repo)"
wt4b="$(new_worktree "$repo4b")"
printf 'y\n' > "$wt4b/b.txt"
session "$repo4b" "$wt4b" "Short headline here
and a continuation line that belongs in the body."
sha4b="$(cat "$(TD "$repo4b")/.commit-sha" 2>/dev/null)"
check "4. a real-newline report keeps its headline as the subject" \
  "printf '%s' \"\$( cd '$repo4b' && git log -1 --format=%s '$sha4b' )\" | grep -q 'Short headline here'"
check "4. ...and its continuation in the body" \
  "printf '%s' \"\$( cd '$repo4b' && git log -1 --format=%b '$sha4b' )\" | grep -q 'belongs in the body'"
check "4. the body does NOT repeat the subject line" \
  "[ \"\$( cd '$repo4' && git log -1 --format=%b '$sha4' | head -1 )\" != \"\$( cd '$repo4' && git log -1 --format=%s '$sha4' | sed 's/^lcars([^)]*) $TICKET: //' )\" ]"
check "4. a one-line summary does NOT get a duplicated body" \
  "[ -z \"\$( cd '$repo3' && git log -1 --format=%b '$sha3' | tr -d '[:space:]' )\" ]"

printf '\nreplay multi-session: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
