#!/usr/bin/env bash
#
# Tests for LCARS identity + solo ownership — Session 189.
#
# Skill sources under test:
#   skills/lcars-run/host-adapter.sh   the four new forge ops
#                                        whoami
#                                        issue-assignees <n>
#                                        issue-assign    <n> <login>
#                                        issue-unassign  <n> <login>
#   skills/lcars-run/ownership.sh      the sourced ownership library
#                                        lcars_whoami
#                                        mission_owner <issue>
#                                        owner_is_me / owner_is_other /
#                                        mission_unassigned
#                                        lcars_owner_lock_reason (the light lock)
#   the solo paths: `lcars file` assigns the captain; the WRITE verbs
#   (run / respond / approve / feedback / log) refuse a mission owned by
#   someone else; the READ verbs never do.
#
# THE TWO LOAD-BEARING CASES (recorded against real gh 2.96.0 in
# skills/lcars-run/ADOPT-RESOLUTION-SPIKE.md, LEG A):
#
#   * THE SILENT DROP (spike A.3 case 6 / failure modes 1+2). Assigning a real
#     user who lacks access to the repo returns rc=0 WITH a success-shaped issue
#     URL and simply does not assign — the REST path lies identically (HTTP 201,
#     "assignees":[]). So `issue-assign` MUST READ BACK and confirm; trusting
#     rc=0 records local ownership GitHub refused. Behaviour A5 below pins it.
#   * THE HOST PIN (spike A.5 / failure mode 7). A bare `gh api user` inside a
#     GHE checkout reads the GITHUB.COM identity. `whoami` must go through the
#     adapter's gh_api wrapper. Behaviour A2 below pins it.
#
# Everything here is stubbed — `gh` is an argv-recording script (the
# worker-adapter test pattern), no network, no model, no real forge.
#
# Usage: bash tests/ownership.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADAPTER="${LCARS_HOST_ADAPTER:-$REPO_ROOT/skills/lcars-run/host-adapter.sh}"
OWNERSHIP="${LCARS_OWNERSHIP_LIB:-$REPO_ROOT/skills/lcars-run/ownership.sh}"
FILE_SCRIPT="$REPO_ROOT/skills/lcars-file/file.sh"
RUN_SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh"
APPROVE_SCRIPT="$REPO_ROOT/skills/lcars-approve/approve.sh"
FEEDBACK_SCRIPT="$REPO_ROOT/skills/lcars-feedback/feedback.sh"
LOG_SCRIPT="$REPO_ROOT/skills/lcars-log/log.sh"
RESPOND_SCRIPT="$REPO_ROOT/skills/lcars-respond/respond.sh"
STATUS_SCRIPT="$REPO_ROOT/skills/lcars-status/status.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ==========================================================================
# The stub `gh`.
#
# Records every call to $GH_LOG (one per line) and models the REAL semantics the
# spike recorded, driven by env so each behaviour can pick its case:
#
#   GH_WHOAMI        the login `gh api … user` echoes  (empty ⇒ echoes nothing)
#   GH_API_RC        rc for `gh api … user`            (default 0)
#   GH_ASSIGN_STATE  a file holding the CURRENT assignees, one login per line —
#                    this is what `gh issue view <n> --json assignees` echoes and
#                    what `gh issue edit --add/--remove-assignee` mutates, so the
#                    read-back in the test is the real read-back.
#   GH_ASSIGN_RC     rc for an --add-assignee edit     (default 0). rc=1 is the
#                    NONEXISTENT-login case (spike A.3 case 7).
#   GH_SILENT_DROP   1 ⇒ an --add-assignee edit exits 0 and echoes the issue URL
#                    but does NOT mutate the assignee list — spike A.3 case 6.
# ==========================================================================
make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"

st="${GH_ASSIGN_STATE:-}"

if [ "${1:-}" = "api" ]; then
  # `gh api [--hostname <h>] user [--jq .login]` — the identity read.
  for a in "$@"; do
    if [ "$a" = "user" ]; then
      [ -n "${GH_WHOAMI:-}" ] && echo "$GH_WHOAMI"
      exit "${GH_API_RC:-0}"
    fi
  done
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  [ -n "$st" ] && [ -f "$st" ] && cat "$st"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  n="${3:-}"
  add=""; rem=""
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --add-assignee)    add="${2:-}"; shift 2 ;;
      --remove-assignee) rem="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [ -n "$add" ]; then
    [ "${GH_ASSIGN_RC:-0}" != "0" ] && { echo "failed to update issue" >&2; exit "${GH_ASSIGN_RC}"; }
    if [ "${GH_SILENT_DROP:-0}" != "1" ] && [ -n "$st" ]; then
      grep -qx -- "$add" "$st" 2>/dev/null || echo "$add" >>"$st"
    fi
  fi
  if [ -n "$rem" ] && [ -n "$st" ] && [ -f "$st" ]; then
    grep -vx -- "$rem" "$st" >"$st.tmp" 2>/dev/null; mv "$st.tmp" "$st"
  fi
  # gh echoes a SUCCESS-SHAPED issue URL even on the silent drop.
  echo "https://github.com/acme/repo/issues/$n"
  exit 0
fi

if [ "${1:-}" = "issue" ] && [ "${2:-}" = "create" ]; then
  echo "https://github.com/acme/repo/issues/314"
  exit 0
fi
exit 0
EOF
  chmod +x "$1"
}

# A probe that SOURCES ownership.sh and drives one function — the library is
# sourced (like comment-mirror.sh), so this is how a test reaches it.
PROBE="$TMPROOT/probe.sh"
cat >"$PROBE" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$LCARS_OWNERSHIP_LIB"
op="${1:-}"; shift 2>/dev/null || true
case "$op" in
  whoami)     rc=0; out="$(lcars_whoami)" || rc=$?; printf 'OUT=%s\nRC=%s\n' "$out" "$rc" ;;
  whoami-x2)  lcars_whoami >/dev/null 2>&1; lcars_whoami >/dev/null 2>&1; printf 'DONE\n' ;;
  owner)      printf 'OWNER=%s\n' "$(mission_owner "${1:-}")" ;;
  is-me)      if owner_is_me "${1:-}";        then printf 'YES\n'; else printf 'NO\n'; fi ;;
  is-other)   if owner_is_other "${1:-}";     then printf 'YES\n'; else printf 'NO\n'; fi ;;
  unassigned) if mission_unassigned "${1:-}"; then printf 'YES\n'; else printf 'NO\n'; fi ;;
  lock)       if r="$(lcars_owner_lock_reason "${1:-}")"; then printf 'BLOCKED=%s\n' "$r"; else printf 'ALLOWED\n'; fi ;;
esac
EOF
chmod +x "$PROBE"

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
    && git remote add origin "https://github.com/acme/repo.git" ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  # A CONFIGURED test command, so the fixture is a repo with a test FOUNDATION
  # (`lcars file` refuses a normal mission on a repo with none) — same fixture
  # shape as tests/lcars-file.test.sh's new_repo.
  cat >"$repo/.git/lcars/config.json" <<'CFG'
{ "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }
CFG
  printf '%s' "$repo"
}

# Never let a stub-remote fetch reach the network or prompt for credentials.
export GIT_TERMINAL_PROMPT=0

# ==========================================================================
echo "ownership (S189: identity, assignee ops, the light lock)"

[ -f "$ADAPTER" ] || { echo "host adapter not found at $ADAPTER"; exit 1; }

GH="$TMPROOT/gh"; make_gh_stub "$GH"
export GH_LOG="$TMPROOT/gh.log"
ASSIGNEES="$TMPROOT/assignees.txt"
export GH_ASSIGN_STATE="$ASSIGNEES"

# --------------------------------------------------------------------------
# A1. whoami echoes the login.
# --------------------------------------------------------------------------
: >"$GH_LOG"
out="$(GH_WHOAMI=roferg LCARS_GH_BIN="$GH" bash "$ADAPTER" whoami 2>/dev/null)"
check "A1. whoami echoes the login from \`gh api user\`" "[ '$out' = 'roferg' ]"
check "A1. whoami reads the \`user\` endpoint" \
  "grep -q ' user' '$GH_LOG'"

# --------------------------------------------------------------------------
# A2. THE HOST PIN (spike A.5 / failure mode 7). `gh api user` without
#     --hostname reads the DEFAULT host's identity even inside a GHE checkout,
#     so whoami must go through the adapter's gh_api wrapper. On a non-
#     github.com host the argv MUST carry --hostname; on github.com it must NOT
#     (byte-compat with today's argv).
# --------------------------------------------------------------------------
: >"$GH_LOG"
GH_WHOAMI=roferg LCARS_GH_HOST=github.ghe.com LCARS_GH_BIN="$GH" \
  bash "$ADAPTER" whoami >/dev/null 2>&1
check "A2. whoami on a GHE host PINS the host (gh api --hostname …), not a bare \`gh api\`" \
  "grep -q 'gh api --hostname github.ghe.com user' '$GH_LOG'"

repoA="$(new_repo)"
: >"$GH_LOG"
( cd "$repoA" && GH_WHOAMI=roferg LCARS_GH_BIN="$GH" bash "$ADAPTER" whoami ) >/dev/null 2>&1
check "A2. whoami on github.com emits NO --hostname (argv unchanged there)" \
  "! grep -q -- '--hostname' '$GH_LOG'"

# --------------------------------------------------------------------------
# A3. issue-assignees — one login per line; UNASSIGNED prints NOTHING at rc=0
#     (spike A.2 / failure mode 5: empty is a valid answer, never an error).
# --------------------------------------------------------------------------
: >"$ASSIGNEES"
rc=0
out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assignees 7 2>/dev/null)" || rc=$?
check "A3. issue-assignees on an UNASSIGNED issue prints nothing" "[ -z '$out' ]"
check "A3. issue-assignees on an UNASSIGNED issue returns 0 (empty is not an error)" "[ '$rc' -eq 0 ]"

printf 'roferg\nsecond\n' >"$ASSIGNEES"
out="$(LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assignees 7 2>/dev/null)"
check "A3. issue-assignees echoes one login per line" \
  "[ \"\$(printf '%s\n' '$out' | wc -l | tr -d ' ')\" = '2' ] && printf '%s' '$out' | grep -qx roferg"

# --------------------------------------------------------------------------
# A4. issue-assign happy path — today's exact argv, and the read-back confirms.
# --------------------------------------------------------------------------
: >"$ASSIGNEES"; : >"$GH_LOG"
rc=0
LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assign 7 roferg >/dev/null 2>&1 || rc=$?
check "A4. issue-assign calls \`gh issue edit <n> --add-assignee <login>\`" \
  "grep -q 'gh issue edit 7 --add-assignee roferg' '$GH_LOG'"
check "A4. issue-assign returns 0 when the read-back confirms the login" "[ '$rc' -eq 0 ]"
check "A4. issue-assign READS BACK (never trusts rc=0 alone)" \
  "grep -q 'gh issue view 7 --json assignees' '$GH_LOG'"

# idempotent: re-assigning an already-assigned login is a silent no-op (case 3).
rc=0
LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assign 7 roferg >/dev/null 2>&1 || rc=$?
check "A4. issue-assign is idempotent on an already-assigned login" "[ '$rc' -eq 0 ]"

# --------------------------------------------------------------------------
# A5. *** THE SILENT DROP *** (spike A.3 case 6, failure modes 1+2).
#     gh exits 0 and echoes a success-shaped issue URL, and the assignment
#     never happens. issue-assign MUST FAIL — and its message must NOT claim
#     the user does not exist (failure mode 4: the assignability endpoint
#     cannot tell "no access" from "no such user"; both are a bare 404).
# --------------------------------------------------------------------------
: >"$ASSIGNEES"; : >"$GH_LOG"
rc=0
err="$(GH_SILENT_DROP=1 LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assign 7 octocat 2>&1 >/dev/null)" || rc=$?
check "A5. SILENT DROP: rc=0 + success-shaped URL but an empty read-back ⇒ issue-assign FAILS" \
  "[ '$rc' -ne 0 ]"
check "A5. SILENT DROP: the failure names the login and the issue" \
  "printf '%s' \"\$err\" | grep -q 'octocat'"
check "A5. SILENT DROP: the message does NOT claim the user does not exist" \
  "! printf '%s' \"\$err\" | grep -qi 'no such user\\|does not exist\\|not a user\\|unknown user'"
check "A5. SILENT DROP: nothing was actually assigned" "[ ! -s '$ASSIGNEES' ]"

# A nonexistent login already fails loudly at rc=1 (spike A.3 case 7).
: >"$GH_LOG"
rc=0
GH_ASSIGN_RC=1 LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assign 7 nope-xyz >/dev/null 2>&1 || rc=$?
check "A5. a login gh REFUSES outright (rc=1) also fails" "[ '$rc' -ne 0 ]"

# --------------------------------------------------------------------------
# A6. issue-unassign — today's exact argv, idempotent when not assigned.
# --------------------------------------------------------------------------
printf 'roferg\n' >"$ASSIGNEES"; : >"$GH_LOG"
rc=0
LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-unassign 7 roferg >/dev/null 2>&1 || rc=$?
check "A6. issue-unassign calls \`gh issue edit <n> --remove-assignee <login>\`" \
  "grep -q 'gh issue edit 7 --remove-assignee roferg' '$GH_LOG'"
check "A6. issue-unassign returns 0" "[ '$rc' -eq 0 ]"
check "A6. issue-unassign actually removed the login" "[ ! -s '$ASSIGNEES' ]"
rc=0
LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-unassign 7 roferg >/dev/null 2>&1 || rc=$?
check "A6. issue-unassign on a login that is NOT assigned is a silent no-op" "[ '$rc' -eq 0 ]"

# --------------------------------------------------------------------------
# A7. gh ABSENT — every op soft-fails, never dies, never hangs.
# --------------------------------------------------------------------------
NOGH="$TMPROOT/not-a-real-gh"
rc=0
out="$(LCARS_GH_BIN="$NOGH" bash "$ADAPTER" whoami 2>/dev/null)" || rc=$?
check "A7. whoami with gh ABSENT echoes nothing and soft-fails" "[ -z '$out' ] && [ '$rc' -ne 0 ]"
rc=0
LCARS_GH_BIN="$NOGH" bash "$ADAPTER" issue-assign 7 roferg >/dev/null 2>&1 || rc=$?
check "A7. issue-assign with gh ABSENT soft-fails (non-zero), never dies" "[ '$rc' -ne 0 ]"

# missing args are HARD errors (a die), like every other op.
LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assign 7 >/dev/null 2>&1
check "A7. issue-assign with no login dies" "[ $? -ne 0 ]"
LCARS_GH_BIN="$GH" bash "$ADAPTER" issue-assignees >/dev/null 2>&1
check "A7. issue-assignees with no issue number dies" "[ $? -ne 0 ]"

# ==========================================================================
echo
echo "ownership.sh — the sourced library"
[ -f "$OWNERSHIP" ] || { echo "  ownership library not found at $OWNERSHIP"; bad "ownership.sh exists"; }

export LCARS_OWNERSHIP_LIB="$OWNERSHIP"

# --------------------------------------------------------------------------
# B1. LCARS_GH_USER WINS — the env override the suites use. No gh call at all.
# --------------------------------------------------------------------------
repoB="$(new_repo)"
: >"$GH_LOG"
out="$( cd "$repoB" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" GH_WHOAMI=someone-else \
        bash "$PROBE" whoami 2>/dev/null )"
check "B1. lcars_whoami: LCARS_GH_USER override WINS" "printf '%s' \"\$out\" | grep -qx 'OUT=capt'"
check "B1. lcars_whoami: the override makes NO gh call" "[ ! -s '$GH_LOG' ]"

# --------------------------------------------------------------------------
# B2. Caches — per-process AND on disk (mtime TTL). Two calls in one process,
#     and a SECOND process, must not re-ask gh.
# --------------------------------------------------------------------------
repoC="$(new_repo)"
: >"$GH_LOG"
( cd "$repoC" && LCARS_GH_BIN="$GH" GH_WHOAMI=roferg bash "$PROBE" whoami-x2 ) >/dev/null 2>&1
n1="$(grep -c ' user' "$GH_LOG" | tr -d ' ')"
check "B2. lcars_whoami caches PER PROCESS (two calls ⇒ one \`gh api user\`)" "[ '$n1' = '1' ]"
: >"$GH_LOG"
out="$( cd "$repoC" && LCARS_GH_BIN="$GH" GH_WHOAMI=roferg bash "$PROBE" whoami 2>/dev/null )"
n2="$(grep -c ' user' "$GH_LOG" | tr -d ' ')"
check "B2. lcars_whoami caches ON DISK (a second process re-uses it)" "[ '$n2' = '0' ]"
check "B2. the on-disk cache returns the right login" "printf '%s' \"\$out\" | grep -qx 'OUT=roferg'"

# The cache is HOST-SCOPED — identity is the (host, login) PAIR, never the
# numeric id, which differs per host for the same login (spike A.5 / mode 8).
: >"$GH_LOG"
out="$( cd "$repoC" && LCARS_GH_HOST=github.ghe.com LCARS_GH_BIN="$GH" GH_WHOAMI=ghe-me \
        bash "$PROBE" whoami 2>/dev/null )"
check "B2. the whoami cache is HOST-SCOPED (a different host does not reuse it)" \
  "printf '%s' \"\$out\" | grep -qx 'OUT=ghe-me'"

# --------------------------------------------------------------------------
# B3. gh ABSENT ⇒ "" at rc != 0, and NO HANG.
# --------------------------------------------------------------------------
repoD="$(new_repo)"
: >"$GH_LOG"
start="$(date +%s)"
out="$( cd "$repoD" && LCARS_GH_BIN="$NOGH" bash "$PROBE" whoami </dev/null 2>/dev/null )"
elapsed=$(( $(date +%s) - start ))
check "B3. lcars_whoami with gh ABSENT prints \"\" and returns non-zero" \
  "printf '%s' \"\$out\" | grep -qx 'OUT=' && printf '%s' \"\$out\" | grep -q 'RC=[1-9]'"
check "B3. lcars_whoami with gh ABSENT does NOT HANG (< 10s, no stdin read)" "[ '$elapsed' -lt 10 ]"

# --------------------------------------------------------------------------
# B4. mission_owner / owner_is_me / owner_is_other / mission_unassigned.
# --------------------------------------------------------------------------
repoE="$(new_repo)"
: >"$ASSIGNEES"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 2>/dev/null )"
check "B4. mission_owner on an UNASSIGNED issue is empty" "printf '%s' \"\$out\" | grep -qx 'OWNER='"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" unassigned 42 2>/dev/null )"
check "B4. mission_unassigned is true when nobody is assigned" "printf '%s' \"\$out\" | grep -qx 'YES'"

printf 'capt\n' >"$ASSIGNEES"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 2>/dev/null )"
check "B4. mission_owner is the single standing assignee" "printf '%s' \"\$out\" | grep -qx 'OWNER=capt'"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" is-me 42 2>/dev/null )"
check "B4. owner_is_me is true for my own mission" "printf '%s' \"\$out\" | grep -qx 'YES'"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" is-other 42 2>/dev/null )"
check "B4. owner_is_other is false for my own mission" "printf '%s' \"\$out\" | grep -qx 'NO'"

printf 'someone-else\n' >"$ASSIGNEES"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" is-other 42 2>/dev/null )"
check "B4. owner_is_other is true when the standing assignee is someone else" \
  "printf '%s' \"\$out\" | grep -qx 'YES'"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" unassigned 42 2>/dev/null )"
check "B4. mission_unassigned is false when someone owns it" "printf '%s' \"\$out\" | grep -qx 'NO'"

# An UNKNOWN identity must never lock the captain out of his own repo.
out="$( cd "$repoE" && LCARS_GH_BIN="$NOGH" bash "$PROBE" is-other 42 </dev/null 2>/dev/null )"
check "B4. owner_is_other is FALSE when our own identity cannot be resolved" \
  "printf '%s' \"\$out\" | grep -qx 'NO'"

# --------------------------------------------------------------------------
# B5. lcars_owner_lock_reason — the ONE plain refusal line, and the bypass.
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"
out="$( cd "$repoE" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" bash "$PROBE" lock 42 2>/dev/null )"
check "B5. the lock names the owner" "printf '%s' \"\$out\" | grep -q 'BLOCKED=assigned to someone-else'"
check "B5. the lock names the remedy" \
  "printf '%s' \"\$out\" | grep -q 'reassign it to yourself on GitHub to take command'"
check "B5. the refusal is ONE line" \
  "[ \"\$(printf '%s\n' \"\$out\" | grep -c 'BLOCKED=')\" = '1' ]"
out="$( cd "$repoE" && LCARS_OWNER_ENFORCE=0 LCARS_GH_USER=capt LCARS_GH_BIN="$GH" \
        bash "$PROBE" lock 42 2>/dev/null )"
check "B5. LCARS_OWNER_ENFORCE=0 bypasses the lock" "printf '%s' \"\$out\" | grep -qx 'ALLOWED'"

# ==========================================================================
echo
echo "the solo paths — filing assigns the captain"

# A minimal PRD the grill-first lane accepts.
make_prd() {
  cat >"$1" <<'EOF'
# Mission: Add dark mode

**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
**Out of Scope:**
- Redesigning the settings page
**Constraints:**
- Existing theming; no new dependencies
EOF
}

# --------------------------------------------------------------------------
# C1. Filing assigns the captain — the recorded argv proves it.
# --------------------------------------------------------------------------
repoF="$(new_repo)"
( cd "$repoF" && git commit -q --allow-empty -m init ) >/dev/null 2>&1
mkdir -p "$repoF/.git/lcars/missions"
make_prd "$repoF/prd.md"
: >"$GH_LOG"; : >"$ASSIGNEES"
rcF=0
( cd "$repoF" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt LCARS_RUN_BIN=/nonexistent \
    LCARS_VERSION_CHECK_BIN=/nonexistent \
    bash "$FILE_SCRIPT" --prd prd.md >file.out 2>&1 ) || rcF=$?
check "C1. filing exits 0" "[ '$rcF' -eq 0 ]"
check "C1. filing ASSIGNS the captain (gh issue edit <n> --add-assignee capt)" \
  "grep -q 'gh issue edit 314 --add-assignee capt' '$GH_LOG'"
check "C1. filing READS BACK the assignment" \
  "grep -q 'gh issue view 314 --json assignees' '$GH_LOG'"

# --------------------------------------------------------------------------
# C2. A FAILED assign WARNS but never blocks filing (best-effort posture, the
#     same as notify.sh / comment-mirror).
# --------------------------------------------------------------------------
repoG="$(new_repo)"
( cd "$repoG" && git commit -q --allow-empty -m init ) >/dev/null 2>&1
mkdir -p "$repoG/.git/lcars/missions"
make_prd "$repoG/prd.md"
: >"$GH_LOG"; : >"$ASSIGNEES"
rcG=0
( cd "$repoG" && GH_SILENT_DROP=1 LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    LCARS_RUN_BIN=/nonexistent LCARS_VERSION_CHECK_BIN=/nonexistent \
    bash "$FILE_SCRIPT" --prd prd.md >file.out 2>&1 ) || rcG=$?
check "C2. a FAILED assign still files the mission (exit 0)" "[ '$rcG' -eq 0 ]"
check "C2. a FAILED assign WARNS on the readout" \
  "grep -qi 'assign' '$repoG/file.out'"
check "C2. the mission dir was still written" \
  "[ -n \"\$(ls -d $repoG/.git/lcars/missions/lcars-* 2>/dev/null)\" ]"
check "C2. the issue number was still recorded" \
  "grep -q '\"githubIssue\": *314' $repoG/.git/lcars/missions/lcars-*/state.json"

# ==========================================================================
echo
echo "the light lock — write verbs refuse, read verbs never do"

MID="lcars-20260530-001"

new_mission_repo() { # <stage>
  local repo stage="$1" m
  repo="$(new_repo)"
  # No origin remote: the drive's base-freshness re-check must never reach out to
  # a stub remote from this suite. Ownership falls back to the github.com host.
  ( cd "$repo" && git commit -q --allow-empty -m init && git remote remove origin ) >/dev/null 2>&1
  m="$repo/.git/lcars/missions/$MID"
  mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: Add dark mode
**Type:** feature
**Goal:** Let users switch to a dark colour scheme.
**Acceptance Criteria:**
- A toggle persists the choice
EOF
  cat >"$m/state.json" <<EOF
{
  "id": "$MID",
  "type": "feature",
  "title": "Add dark mode",
  "stage": "$stage",
  "created": "2026-05-30T10:00:00Z",
  "model": "claude-sonnet",
  "githubIssue": 42,
  "prUrl": "https://github.com/acme/repo/pull/9",
  "prNumber": 9,
  "branch": "lcars/$MID",
  "base": "main"
}
EOF
  printf '%s' "$repo"
}

LOCKLINE='reassign it to yourself on GitHub to take command'
printf 'someone-else\n' >"$ASSIGNEES"

# --- run (the drive) --------------------------------------------------------
repoR="$(new_mission_repo research)"
mR="$repoR/.git/lcars/missions/$MID"
# Parked-by-the-captain, so the ENFORCE=0 bypass run halts at the pause boundary
# instead of spawning a Stage worker (this suite spends zero model tokens).
sed 's/"stage": "research",/"stage": "research",\n  "paused": true,/' \
  "$mR/state.json" >"$mR/state.tmp" && mv "$mR/state.tmp" "$mR/state.json"
rcR=0
( cd "$repoR" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$RUN_SCRIPT" drive --mission "$MID" >out.txt 2>&1 ) || rcR=$?
check "D1. \`lcars run\` REFUSES a mission owned by someone else" "[ '$rcR' -ne 0 ]"
check "D1. …with the plain line naming the owner" "grep -q 'assigned to someone-else' '$repoR/out.txt'"
check "D1. …and the remedy" "grep -q '$LOCKLINE' '$repoR/out.txt'"
rcR=0
( cd "$repoR" && LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$RUN_SCRIPT" drive --mission "$MID" >out2.txt 2>&1 ) || rcR=$?
check "D1. LCARS_OWNER_ENFORCE=0 bypasses the lock on \`lcars run\`" \
  "! grep -q '$LOCKLINE' '$repoR/out2.txt'"

# --- approve ---------------------------------------------------------------
repoP="$(new_mission_repo verify)"
rcP=0
( cd "$repoP" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$APPROVE_SCRIPT" --mission "$MID" >out.txt 2>&1 ) || rcP=$?
check "D2. \`lcars approve\` REFUSES a mission owned by someone else" "[ '$rcP' -ne 0 ]"
check "D2. …with the plain line" "grep -q 'assigned to someone-else' '$repoP/out.txt'"
check "D2. …and the remedy" "grep -q '$LOCKLINE' '$repoP/out.txt'"

# --- feedback --------------------------------------------------------------
repoB2="$(new_mission_repo verify)"
rcB=0
( cd "$repoB2" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$FEEDBACK_SCRIPT" --mission "$MID" --feedback "nope" >out.txt 2>&1 ) || rcB=$?
check "D3. \`lcars feedback\` REFUSES a mission owned by someone else" "[ '$rcB' -ne 0 ]"
check "D3. …with the plain line" "grep -q 'assigned to someone-else' '$repoB2/out.txt'"
check "D3. …and it did NOT write feedback.md" "[ ! -f '$repoB2/.git/lcars/missions/$MID/feedback.md' ]"

# --- respond ----------------------------------------------------------------
repoS="$(new_mission_repo plan-review)"
mS="$repoS/.git/lcars/missions/$MID"
sed 's/"stage": "plan-review",/"stage": "plan-review",\n  "awaitingHuman": true,/' \
  "$mS/state.json" >"$mS/state.tmp" && mv "$mS/state.tmp" "$mS/state.json"
cat >"$mS/pending.json" <<'PJ'
{
  "stage": "plan-review",
  "questions": [
    "which way?"
  ]
}
PJ
rcS=0
( cd "$repoS" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$RESPOND_SCRIPT" answer --mission "$MID" --answer "that way" >out.txt 2>&1 ) || rcS=$?
check "D4. \`lcars respond answer\` REFUSES a mission owned by someone else" "[ '$rcS' -ne 0 ]"
check "D4. …with the plain line" "grep -q 'assigned to someone-else' '$repoS/out.txt'"
# READ verb: `respond show` is never blocked.
rcS=0
( cd "$repoS" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$RESPOND_SCRIPT" show --mission "$MID" >show.txt 2>&1 ) || rcS=$?
check "D4. READ verb \`lcars respond show\` is NEVER blocked" \
  "[ '$rcS' -eq 0 ] && ! grep -q '$LOCKLINE' '$repoS/show.txt'"

# --- log --------------------------------------------------------------------
repoL="$(new_mission_repo implement)"
cat >"$repoL/bug.md" <<'BUG'
# Mission: The toggle does not persist

**Type:** bug
**Goal:** The dark-mode toggle should survive a reload.
**Acceptance Criteria:**
- The described defect no longer reproduces
**Out of Scope:**
- Unrelated refactors
**Constraints:**
- Minimal change; no new dependencies
BUG
rcL=0
( cd "$repoL" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt LCARS_RUN_BIN=/nonexistent \
    bash "$LOG_SCRIPT" --parent "$MID" --prd bug.md >out.txt 2>&1 ) || rcL=$?
check "D5. \`lcars log\` REFUSES a mission owned by someone else" "[ '$rcL' -ne 0 ]"
check "D5. …with the plain line" "grep -q 'assigned to someone-else' '$repoL/out.txt'"

# --- status: a READ verb, NEVER blocked -------------------------------------
repoT="$(new_mission_repo implement)"
rcT=0
( cd "$repoT" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$STATUS_SCRIPT" >out.txt 2>&1 ) || rcT=$?
check "D6. READ verb \`lcars status\` is NEVER blocked" "[ '$rcT' -eq 0 ]"
check "D6. …and it still shows the mission" "grep -q '$MID' '$repoT/out.txt'"
check "D6. …with no refusal line" "! grep -q '$LOCKLINE' '$repoT/out.txt'"

# --- my OWN mission is never locked -----------------------------------------
printf 'capt\n' >"$ASSIGNEES"
repoO="$(new_mission_repo verify)"
rcO=0
( cd "$repoO" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$FEEDBACK_SCRIPT" --mission "$MID" --feedback "one more pass" >out.txt 2>&1 ) || rcO=$?
check "D7. my OWN mission is not locked (feedback runs)" \
  "[ '$rcO' -eq 0 ] && [ -f '$repoO/.git/lcars/missions/$MID/feedback.md' ]"

# --- an UNASSIGNED mission is never locked ----------------------------------
: >"$ASSIGNEES"
repoU="$(new_mission_repo verify)"
rcU=0
( cd "$repoU" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$FEEDBACK_SCRIPT" --mission "$MID" --feedback "one more pass" >out.txt 2>&1 ) || rcU=$?
check "D8. an UNASSIGNED mission is not locked (empty is 'unowned', not an error)" \
  "[ '$rcU' -eq 0 ]"

# --------------------------------------------------------------------------
# D9. A drive on an UNASSIGNED mission ASSIGNS on first advance (best-effort).
# --------------------------------------------------------------------------
: >"$ASSIGNEES"; : >"$GH_LOG"
repoV="$(new_mission_repo research)"
mV="$repoV/.git/lcars/missions/$MID"
sed 's/"stage": "research",/"stage": "research",\n  "paused": true,/' \
  "$mV/state.json" >"$mV/state.tmp" && mv "$mV/state.tmp" "$mV/state.json"
( cd "$repoV" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$RUN_SCRIPT" drive --mission "$MID" >out.txt 2>&1 )
check "D9. a drive on an UNASSIGNED mission assigns the captain on first advance" \
  "grep -q 'gh issue edit 42 --add-assignee capt' '$GH_LOG'"

# ==========================================================================
# S196 / A6 — THE CLI LOCKS WHAT THE BOARD LOCKS.
#
# Ground truth measured by the S190/S191 capstone: `run`, `respond`, `approve`,
# `feedback` and `log` all consult `lcars_owner_lock_reason`; `pause` and
# `resolve-logs` did NOT. The board 403s the captain's Pause on someone else's
# mission while `lcars pause <id>` in the next terminal obeyed silently — two
# surfaces, two answers.
#
# THE CAPTAIN'S STANDING RULING (2026-09-09): "the board is just meant to be a
# UI version of the command line" — so where the two disagree the CLI comes into
# line, and the board's 403 is never relaxed to match. `pause`, `resume` (the
# same script, and a write the board locks too) and `resolve-logs` therefore
# consult the SAME one function, with the SAME posture: unassigned never locks,
# an unresolvable identity never locks, reads are never blocked.
#
# Every mutating check below PARSES state.json with python3 as well as diffing
# it: S189's suite missed a real corruption because not one check parsed it.
# ==========================================================================
echo
echo "the light lock — pause / resume / resolve-logs (S196 A6)"

PAUSE_SCRIPT="$REPO_ROOT/skills/lcars-pause/pause.sh"
RESOLVE_SCRIPT="$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh"
BOARD_JS="$REPO_ROOT/web/static/board.js"

# A `lcars run` stand-in, so `resume`'s exec and resolve-logs' drive delegation
# are OBSERVABLE without a real driver (and a lock that leaked would be visible
# as a line in this log).
RUNSTUB="$TMPROOT/runstub.sh"
cat >"$RUNSTUB" <<'RS'
#!/usr/bin/env bash
echo "run $*" >>"$RUN_LOG"
exit 0
RS
chmod +x "$RUNSTUB"

# state.json must still PARSE after any refusal — a lock that corrupted the file
# it refused to touch would pass a grep and fail a captain.
json_ok() { python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" >/dev/null 2>&1; }

# Build a parent mission with ONE linked child bug, for resolve-logs.
add_child_bug() { # <repo> <child-id> <parent-id>
  local d="$1/.git/lcars/missions/$2"
  mkdir -p "$d"
  cat >"$d/state.json" <<EOF
{
  "id": "$2",
  "type": "bug",
  "title": "Logged bug one",
  "stage": "plan",
  "githubIssue": 51,
  "parentMission": "$3",
  "parentIssue": 42,
  "branch": "lcars/$2",
  "base": "main"
}
EOF
}

CHILD="lcars-20260530-002"

# --------------------------------------------------------------------------
# D10. `lcars pause` on someone else's mission REFUSES, and changes nothing.
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoPa="$(new_mission_repo implement)"
sPa="$repoPa/.git/lcars/missions/$MID/state.json"
sumPa="$(cksum <"$sPa")"
rcPa=0
( cd "$repoPa" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$PAUSE_SCRIPT" pause "$MID" >out.txt 2>&1 ) || rcPa=$?
check "D10. \`lcars pause\` REFUSES a mission owned by someone else" "[ '$rcPa' -ne 0 ]"
check "D10. …with the plain line naming the owner and the remedy" \
  "grep -Fxq 'lcars pause: assigned to someone-else — reassign it to yourself on GitHub to take command' '$repoPa/out.txt'"
check "D10. …state.json is BYTE-IDENTICAL (no paused flag written)" \
  "[ \"\$(cksum <'$sPa')\" = '$sumPa' ]"
check "D10. …and still parses as JSON" "json_ok '$sPa'"
check "D10. …no lcars:paused label was applied on the forge" \
  "! grep -q 'add-label lcars:paused' '$GH_LOG'"
check "D10. …and no event was appended" \
  "[ ! -f '$repoPa/.git/lcars/missions/$MID/events.jsonl' ]"

# --------------------------------------------------------------------------
# D11. `lcars resume` is a write the board locks too — so the CLI locks it.
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoRe="$(new_mission_repo implement)"
sRe="$repoRe/.git/lcars/missions/$MID/state.json"
sed 's/"stage": "implement",/"stage": "implement",\n  "paused": true,/' \
  "$sRe" >"$sRe.tmp" && mv "$sRe.tmp" "$sRe"
sumRe="$(cksum <"$sRe")"
export RUN_LOG="$repoRe/run.log"; : >"$RUN_LOG"
rcRe=0
( cd "$repoRe" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt LCARS_RUN_SCRIPT="$RUNSTUB" \
    bash "$PAUSE_SCRIPT" resume "$MID" >out.txt 2>&1 ) || rcRe=$?
check "D11. \`lcars resume\` REFUSES a mission owned by someone else" "[ '$rcRe' -ne 0 ]"
check "D11. …with the SAME plain line" \
  "grep -Fq 'assigned to someone-else — reassign it to yourself on GitHub to take command' '$repoRe/out.txt'"
# S196 FIX D2. The SENTENCE was already right; the PREFIX named the sibling verb.
# `lcars resume` refused with `lcars pause: …` because pause.sh's die() hard-codes
# one verb for a script that answers to two, so the captain who typed `resume` was
# told that `pause` had failed. The sentence itself is NOT touched — D17 below
# re-proves it byte for byte — only the name in front of the colon.
check "D11. …and the refusal names the verb the captain TYPED, not its sibling" \
  "grep -Fxq 'lcars resume: assigned to someone-else — reassign it to yourself on GitHub to take command' '$repoRe/out.txt'"
check "D11. …so nothing in resume's output claims to be \`lcars pause\`" \
  "! grep -q '^lcars pause:' '$repoRe/out.txt'"
check "D11. …the paused flag SURVIVES (their mission stays parked)" \
  "[ \"\$(cksum <'$sRe')\" = '$sumRe' ]"
check "D11. …state.json still parses as JSON" "json_ok '$sRe'"
check "D11. …and the driver was never re-entered" "[ ! -s '$RUN_LOG' ]"

# --------------------------------------------------------------------------
# D12. `lcars resolve-logs` on someone else's parent REFUSES, and drives nothing.
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoRL="$(new_mission_repo implement)"
add_child_bug "$repoRL" "$CHILD" "$MID"
sRLp="$repoRL/.git/lcars/missions/$MID/state.json"
sRLc="$repoRL/.git/lcars/missions/$CHILD/state.json"
sumRLp="$(cksum <"$sRLp")"; sumRLc="$(cksum <"$sRLc")"
export RUN_LOG="$repoRL/run.log"; : >"$RUN_LOG"
rcRL=0
( cd "$repoRL" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt LCARS_RUN_SCRIPT="$RUNSTUB" \
    LCARS_VERSION_CHECK_BIN=/nonexistent LCARS_WORKER_BIN= \
    bash "$RESOLVE_SCRIPT" --parent "$MID" >out.txt 2>&1 ) || rcRL=$?
check "D12. \`lcars resolve-logs\` REFUSES a parent owned by someone else" "[ '$rcRL' -ne 0 ]"
check "D12. …with the plain line naming the owner and the remedy" \
  "grep -Fxq 'lcars resolve-logs: assigned to someone-else — reassign it to yourself on GitHub to take command' '$repoRL/out.txt'"
check "D12. …the PARENT state.json is byte-identical" \
  "[ \"\$(cksum <'$sRLp')\" = '$sumRLp' ]"
check "D12. …the CHILD bug state.json is byte-identical" \
  "[ \"\$(cksum <'$sRLc')\" = '$sumRLc' ]"
check "D12. …both still parse as JSON" "json_ok '$sRLp' && json_ok '$sRLc'"
check "D12. …and NOTHING was driven" "[ ! -s '$RUN_LOG' ]"
check "D12. …no consolidated gate was raised on the parent" \
  "[ ! -f '$repoRL/.git/lcars/missions/$MID/pending.json' ]"

# `resolve-logs complete` folds children to Done — the same lock, the same line.
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
rcRC=0
( cd "$repoRL" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt LCARS_RUN_SCRIPT="$RUNSTUB" \
    LCARS_VERSION_CHECK_BIN=/nonexistent \
    bash "$RESOLVE_SCRIPT" complete --parent "$MID" >outc.txt 2>&1 ) || rcRC=$?
check "D12. \`lcars resolve-logs complete\` is locked too" "[ '$rcRC' -ne 0 ]"
check "D12. …with the same plain line" \
  "grep -Fq 'assigned to someone-else — reassign it to yourself on GitHub to take command' '$repoRL/outc.txt'"
check "D12. …and the child bug was NOT folded to done" \
  "[ \"\$(cksum <'$sRLc')\" = '$sumRLc' ] && json_ok '$sRLc'"

# --------------------------------------------------------------------------
# D13. An UNASSIGNED mission is NEVER locked — both verbs proceed.
#      (empty is "unowned", not an error)
# --------------------------------------------------------------------------
: >"$ASSIGNEES"; : >"$GH_LOG"
repoPu="$(new_mission_repo implement)"
sPu="$repoPu/.git/lcars/missions/$MID/state.json"
rcPu=0
( cd "$repoPu" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$PAUSE_SCRIPT" pause "$MID" >out.txt 2>&1 ) || rcPu=$?
check "D13. \`lcars pause\` on an UNASSIGNED mission PROCEEDS" "[ '$rcPu' -eq 0 ]"
check "D13. …it really paused it" "grep -q '\"paused\": *true' '$sPu'"
check "D13. …and state.json still parses as JSON" "json_ok '$sPu'"

: >"$ASSIGNEES"; : >"$GH_LOG"
repoRu="$(new_mission_repo implement)"
export RUN_LOG="$repoRu/run.log"; : >"$RUN_LOG"
rcRu=0
( cd "$repoRu" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt LCARS_RUN_SCRIPT="$RUNSTUB" \
    LCARS_VERSION_CHECK_BIN=/nonexistent \
    bash "$RESOLVE_SCRIPT" --parent "$MID" >out.txt 2>&1 ) || rcRu=$?
check "D13. \`lcars resolve-logs\` on an UNASSIGNED parent PROCEEDS" "[ '$rcRu' -eq 0 ]"
check "D13. …reaching its own no-op (no open linked bugs), not a refusal" \
  "grep -q 'nothing to resolve' '$repoRu/out.txt'"
check "D13. …and the parent state.json still parses as JSON" \
  "json_ok '$repoRu/.git/lcars/missions/$MID/state.json'"

# --------------------------------------------------------------------------
# D14. An UNRESOLVABLE identity is NEVER locked — both verbs proceed.
#
#      gh is present and its `user` call FAILS: we cannot say who we are, so we
#      do not get to tell the captain he is someone else. (S190's D1 scar: the
#      rc must be captured BEFORE any pipeline, or an unreachable gh silently
#      erases the published owner. A FRESH repo per case, because the whoami
#      answer is cached on disk for 12h.)
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoPn="$(new_mission_repo implement)"
sPn="$repoPn/.git/lcars/missions/$MID/state.json"
rcPn=0
( cd "$repoPn" && GH_WHOAMI= GH_API_RC=1 LCARS_GH_BIN="$GH" \
    bash "$PAUSE_SCRIPT" pause "$MID" >out.txt 2>&1 ) || rcPn=$?
check "D14. \`lcars pause\` with an UNRESOLVABLE identity PROCEEDS" "[ '$rcPn' -eq 0 ]"
check "D14. …it really paused it" "grep -q '\"paused\": *true' '$sPn'"
check "D14. …with no refusal line at all" "! grep -q '$LOCKLINE' '$repoPn/out.txt'"
check "D14. …and state.json still parses as JSON" "json_ok '$sPn'"

printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoRn="$(new_mission_repo implement)"
export RUN_LOG="$repoRn/run.log"; : >"$RUN_LOG"
rcRn=0
( cd "$repoRn" && GH_WHOAMI= GH_API_RC=1 LCARS_GH_BIN="$GH" LCARS_RUN_SCRIPT="$RUNSTUB" \
    LCARS_VERSION_CHECK_BIN=/nonexistent \
    bash "$RESOLVE_SCRIPT" --parent "$MID" >out.txt 2>&1 ) || rcRn=$?
check "D14. \`lcars resolve-logs\` with an UNRESOLVABLE identity PROCEEDS" "[ '$rcRn' -eq 0 ]"
check "D14. …with no refusal line at all" "! grep -q '$LOCKLINE' '$repoRn/out.txt'"

# A GH THAT IS NOT THERE AT ALL — the plane case. Never locked either.
printf 'someone-else\n' >"$ASSIGNEES"
repoPz="$(new_mission_repo implement)"
rcPz=0
( cd "$repoPz" && LCARS_GH_BIN="$TMPROOT/no-such-gh" \
    bash "$PAUSE_SCRIPT" pause "$MID" >out.txt 2>&1 ) || rcPz=$?
check "D14. an ABSENT gh never locks \`lcars pause\`" "[ '$rcPz' -eq 0 ]"
check "D14. …and state.json still parses as JSON" \
  "json_ok '$repoPz/.git/lcars/missions/$MID/state.json'"

# --------------------------------------------------------------------------
# D15. LCARS_OWNER_ENFORCE=0 bypasses the new locks too (harness debugging).
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoPb="$(new_mission_repo implement)"
rcPb=0
( cd "$repoPb" && LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$PAUSE_SCRIPT" pause "$MID" >out.txt 2>&1 ) || rcPb=$?
check "D15. LCARS_OWNER_ENFORCE=0 bypasses the lock on \`lcars pause\`" \
  "[ '$rcPb' -eq 0 ] && ! grep -q '$LOCKLINE' '$repoPb/out.txt'"

printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoRb="$(new_mission_repo implement)"
export RUN_LOG="$repoRb/run.log"; : >"$RUN_LOG"
rcRb=0
( cd "$repoRb" && LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    LCARS_RUN_SCRIPT="$RUNSTUB" LCARS_VERSION_CHECK_BIN=/nonexistent \
    bash "$RESOLVE_SCRIPT" --parent "$MID" >out.txt 2>&1 ) || rcRb=$?
check "D15. LCARS_OWNER_ENFORCE=0 bypasses the lock on \`lcars resolve-logs\`" \
  "[ '$rcRb' -eq 0 ] && ! grep -q '$LOCKLINE' '$repoRb/out.txt'"

# --------------------------------------------------------------------------
# D16. A READ of a locked mission is never blocked — `lcars status` still lists
#      the mission the two new locks refuse to write.
# --------------------------------------------------------------------------
printf 'someone-else\n' >"$ASSIGNEES"; : >"$GH_LOG"
repoRd="$(new_mission_repo implement)"
rcRd=0
( cd "$repoRd" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt \
    bash "$STATUS_SCRIPT" >out.txt 2>&1 ) || rcRd=$?
check "D16. reads stay open beside the two new locks (\`lcars status\`)" \
  "[ '$rcRd' -eq 0 ] && grep -q '$MID' '$repoRd/out.txt' && ! grep -q '$LOCKLINE' '$repoRd/out.txt'"

# ==========================================================================
# D17. ONE SENTENCE — SEVEN VERBS AND THE BOARD, BYTE FOR BYTE.
#
# THE POINT OF THIS CHECK is that it retypes nothing. The sentence is READ OUT
# OF THE SHIPPING FILES — the printf in ownership.sh and the concatenation in
# board.js — and the seven verbs' REAL refusals are compared against it byte for
# byte. Anyone who edits one of the two files and not the other breaks this test
# instead of telling the captain two different stories.
#
# The daemon's 403 body is the third surface and needs no separate spelling: it
# is the raw stdout of `ownership.sh lock-reason` (Actions.owner_lock_reason
# shells exactly that op), so the executable face is checked here in its place.
# ==========================================================================
echo
echo "one sentence — seven verbs and the board"

# The format string, out of the library.
OWN_FMT="$(sed -n "s/.*printf '\(assigned to %s[^']*\)'.*/\1/p" "$OWNERSHIP" | head -1)"
check "D17. ownership.sh still carries the sentence as a printf format" \
  "[ -n \"\$OWN_FMT\" ]"
OWN_SENTENCE="${OWN_FMT/\%s/someone-else}"

# The same sentence, out of board.js's `ownerLockLine` — the tooltip the captain
# reads before he clicks. Reconstructed from the function's own literals.
JS_EXPR="$(awk '/^function ownerLockLine/,/^}/' "$BOARD_JS" | tr '\n' ' ' \
  | sed 's/.*return //; s/;.*//')"
JS_SENTENCE="$(printf '%s' "$JS_EXPR" | sed 's/ *+ *//g; s/login/someone-else/; s/"//g')"
check "D17. board.js's tooltip is the SAME BYTES as ownership.sh's refusal" \
  "[ \"\$JS_SENTENCE\" = \"\$OWN_SENTENCE\" ]"

# The executable face — what the daemon's 403 body actually is.
printf 'someone-else\n' >"$ASSIGNEES"
repoEF="$(new_repo)"
outEF="$( cd "$repoEF" && LCARS_GH_USER=capt LCARS_GH_BIN="$GH" \
  bash "$OWNERSHIP" lock-reason 42 2>/dev/null )"
check "D17. the daemon's 403 body (ownership.sh lock-reason) is the same bytes" \
  "[ \"\$outEF\" = \"\$OWN_SENTENCE\" ]"

# And now the SEVEN verbs, each refusing for real. The prefix is stripped
# GENERICALLY (`lcars <verb>:`) so this check stays about the SENTENCE: since
# S196's D2 fix pause.sh names whichever subcommand was typed, and D11 above is
# what pins that. Do not narrow this pattern to one verb.
verb_refusal() { # <outfile> -> the refusal line, prefix stripped
  sed -n 's/^lcars [a-z-]*: \(assigned to .*\)$/\1/p' "$1" | head -1
}

lineRun="$(verb_refusal "$repoR/out.txt")"
check "D17. \`lcars run\` refuses with EXACTLY that sentence" \
  "[ \"\$lineRun\" = \"\$OWN_SENTENCE\" ]"
lineApprove="$(verb_refusal "$repoP/out.txt")"
check "D17. \`lcars approve\` refuses with EXACTLY that sentence" \
  "[ \"\$lineApprove\" = \"\$OWN_SENTENCE\" ]"
lineFeedback="$(verb_refusal "$repoB2/out.txt")"
check "D17. \`lcars feedback\` refuses with EXACTLY that sentence" \
  "[ \"\$lineFeedback\" = \"\$OWN_SENTENCE\" ]"
lineRespond="$(verb_refusal "$repoS/out.txt")"
check "D17. \`lcars respond\` refuses with EXACTLY that sentence" \
  "[ \"\$lineRespond\" = \"\$OWN_SENTENCE\" ]"
lineLog="$(verb_refusal "$repoL/out.txt")"
check "D17. \`lcars log\` refuses with EXACTLY that sentence" \
  "[ \"\$lineLog\" = \"\$OWN_SENTENCE\" ]"
linePause="$(verb_refusal "$repoPa/out.txt")"
check "D17. \`lcars pause\` refuses with EXACTLY that sentence" \
  "[ \"\$linePause\" = \"\$OWN_SENTENCE\" ]"
lineResume="$(verb_refusal "$repoRe/out.txt")"
check "D17. \`lcars resume\` refuses with EXACTLY that sentence" \
  "[ \"\$lineResume\" = \"\$OWN_SENTENCE\" ]"
lineResolve="$(verb_refusal "$repoRL/out.txt")"
check "D17. \`lcars resolve-logs\` refuses with EXACTLY that sentence" \
  "[ \"\$lineResolve\" = \"\$OWN_SENTENCE\" ]"

# ==========================================================================
echo
printf 'ownership: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
