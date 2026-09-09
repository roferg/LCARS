#!/usr/bin/env bash
#
# Tests for the S190 additions to skills/lcars-run/ownership.sh — the two seams
# the VIEWSCREEN needs, and nothing else.
#
# S189 made ownership a question the WRITE VERBS ask the forge. S190 has to put
# the answer on a board that re-renders several times a minute, and the daemon
# has a standing rule (local_adapter._meta, base_freshness): A BOARD BUILD DOES
# NO NETWORK I/O. So the daemon cannot ask the forge on a render, and it must
# not grow a second Python implementation of "who owns this" either (ADR-002 —
# the daemon SHELLS the skill; the S168 scar is two implementations of one
# verdict drifting apart).
#
# The two seams:
#
#   1. A PUBLISHED ANSWER. `mission_owner` WRITES what the forge told it to a
#      host-scoped cache file under .git/lcars/cache/. The daemon READS that file
#      — a pure disk read on the render path, no subprocess, no network.
#
#      IT WRITES BUT NEVER READS. Reading it would change S189's own freshness:
#      a write verb's lock would start answering from a cache, and a captain who
#      had just reassigned a mission to himself on GitHub would stay locked out
#      by a file. The forge stays the CLI's only source of truth; the cache is a
#      one-way publication for a read-only surface.
#
#   2. AN EXECUTABLE FACE. Sourced, ownership.sh is unchanged. EXECUTED, it
#      dispatches three read ops (whoami / owner / lock-reason) so the daemon's
#      server-side re-check runs the SAME lcars_owner_lock_reason the CLI runs,
#      with the same posture — unassigned never locks, unresolvable never locks.
#
# Everything is stubbed: `gh` is the argv-recording script from
# tests/ownership.test.sh (the worker-adapter pattern). No network, no model, no
# real forge.
#
# Usage: bash tests/ownership-viewscreen.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OWNERSHIP="${LCARS_OWNERSHIP_LIB:-$REPO_ROOT/skills/lcars-run/ownership.sh}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# The stub `gh` — the same semantics tests/ownership.test.sh models (identity via
# `gh api … user`, assignees via `gh issue view --json assignees`, assignment via
# `gh issue edit --add-assignee`, mutating $GH_ASSIGN_STATE so the read-back is a
# real read-back).
GH="$TMPROOT/gh"
cat >"$GH" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
st="${GH_ASSIGN_STATE:-}"
if [ "${1:-}" = "api" ]; then
  for a in "$@"; do
    if [ "$a" = "user" ]; then
      [ -n "${GH_WHOAMI:-}" ] && echo "$GH_WHOAMI"
      exit "${GH_API_RC:-0}"
    fi
  done
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "view" ]; then
  # $GH_VIEW_RC models a gh that IS on PATH and FAILS (no auth, no network, a
  # 5xx). The FIX-ROUND-1 cases below need "the call failed" to be a different
  # observable event from "the forge answered: nobody", and this is the only
  # place that difference is born.
  [ "${GH_VIEW_RC:-0}" = "0" ] || exit "${GH_VIEW_RC}"
  [ -n "$st" ] && [ -f "$st" ] && cat "$st"
  exit 0
fi
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "edit" ]; then
  n="${3:-}"; add=""
  shift 3 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in --add-assignee) add="${2:-}"; shift 2 ;; *) shift ;; esac
  done
  if [ -n "$add" ] && [ -n "$st" ]; then
    grep -qx -- "$add" "$st" 2>/dev/null || echo "$add" >>"$st"
  fi
  echo "https://github.com/acme/repo/issues/$n"
  exit 0
fi
exit 0
EOF
chmod +x "$GH"

# A probe that SOURCES ownership.sh (the library's normal reach) and drives one
# function — used to prove the SOURCED behaviour is unchanged.
PROBE="$TMPROOT/probe.sh"
cat >"$PROBE" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$LCARS_OWNERSHIP_LIB"
op="${1:-}"; shift 2>/dev/null || true
case "$op" in
  owner) printf 'OWNER=%s\n' "$(mission_owner "${1:-}")" ;;
  claim) lcars_claim_mission "${1:-}" >/dev/null 2>&1; printf 'DONE\n' ;;
  # Sourcing must DEFINE and do nothing else — no dispatch, no output.
  quiet) printf 'SOURCED_QUIET\n' ;;
esac
EOF
chmod +x "$PROBE"

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
    && git remote add origin "https://github.com/acme/repo.git" ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  printf '%s' "$repo"
}

export GIT_TERMINAL_PROMPT=0
export GH_LOG="$TMPROOT/gh.log"
ASSIGNEES="$TMPROOT/assignees.txt"
export GH_ASSIGN_STATE="$ASSIGNEES"
export LCARS_OWNERSHIP_LIB="$OWNERSHIP"

echo "ownership → viewscreen (S190: the published answer + the executable face)"

[ -f "$OWNERSHIP" ] || { echo "ownership library not found at $OWNERSHIP"; exit 1; }

# The cache path the daemon reads. github.com is the empty gh-host case, which
# _lcars_own_host names explicitly, so the key is `owner-github.com-<issue>`.
cache_of() { printf '%s/.git/lcars/cache/owner-github.com-%s' "$1" "$2"; }

# ==========================================================================
# V1. mission_owner PUBLISHES the standing assignee where the daemon can read it.
# ==========================================================================
: >"$ASSIGNEES"; printf 'roferg\n' >"$ASSIGNEES"
repo1="$(new_repo)"
( cd "$repo1" && LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 >out.txt 2>&1 )
c1="$(cache_of "$repo1" 42)"
check "V1. mission_owner publishes the owner to .git/lcars/cache/owner-<host>-<issue>" \
  "[ -f '$c1' ] && [ \"\$(cat '$c1')\" = 'roferg' ]"
check "V1. …and still ECHOES the owner to its caller (S189 behaviour unchanged)" \
  "grep -qx 'OWNER=roferg' '$repo1/out.txt'"

# ==========================================================================
# V2. An UNASSIGNED issue publishes an EMPTY file — "nobody" is an ANSWER.
#     An absent file means "we have never asked"; those are different, and the
#     board must be able to tell them apart (it locks on neither, but a card
#     that HAS been asked about and has no owner is honestly unowned).
# ==========================================================================
: >"$ASSIGNEES"
repo2="$(new_repo)"
( cd "$repo2" && LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 >/dev/null 2>&1 )
c2="$(cache_of "$repo2" 42)"
check "V2. an UNASSIGNED issue publishes an EMPTY cache file (an answer, not an absence)" \
  "[ -f '$c2' ] && [ ! -s '$c2' ]"

# ==========================================================================
# V3. THE ONE-WAY RULE. mission_owner WRITES the cache and NEVER READS it. A
#     stale file naming someone else must not change what the CLI's lock sees —
#     otherwise a captain who has just reassigned a mission to himself on GitHub
#     stays locked out by a file.
# ==========================================================================
printf 'roferg\n' >"$ASSIGNEES"
repo3="$(new_repo)"
mkdir -p "$repo3/.git/lcars/cache"
printf 'someone-else\n' >"$(cache_of "$repo3" 42)"
out3="$( cd "$repo3" && LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 2>/dev/null )"
check "V3. a STALE cache does not answer for the forge (mission_owner never reads it)" \
  "[ '$out3' = 'OWNER=roferg' ]"
check "V3. …and the stale entry is overwritten with what the forge said" \
  "[ \"\$(cat '$(cache_of "$repo3" 42)')\" = 'roferg' ]"

# ==========================================================================
# V4. A successful claim republishes the cache — the mission the captain just
#     took is HIS on the board, without waiting for the next forge read.
# ==========================================================================
: >"$ASSIGNEES"
repo4="$(new_repo)"
( cd "$repo4" && LCARS_GH_BIN="$GH" LCARS_GH_USER=capt bash "$PROBE" claim 42 >/dev/null 2>&1 )
c4="$(cache_of "$repo4" 42)"
check "V4. lcars_claim_mission republishes the cache after a confirmed claim" \
  "[ -f '$c4' ] && [ \"\$(cat '$c4')\" = 'capt' ]"

# ==========================================================================
# V5. The cache lives under .git — never committed, dies with the clone.
# ==========================================================================
check "V5. the published answer lives under .git (never committed, dies with the clone)" \
  "case '$c1' in */.git/lcars/cache/*) true ;; *) false ;; esac"

# ==========================================================================
# V6-V13. THE EXECUTABLE FACE. `bash ownership.sh <op>` — how the daemon asks.
#
# A FRESH REPO PER IDENTITY, deliberately. S189's whoami answer is cached on
# disk for 12h, so re-using one repo under a second GH_WHOAMI would be answered
# by the first run's cache and the case would silently not be the case it claims
# (this suite made exactly that mistake once — the product was right).
# ==========================================================================
printf 'roferg\n' >"$ASSIGNEES"
repo6="$(new_repo)"
out6="$( cd "$repo6" && GH_WHOAMI=roferg LCARS_GH_BIN="$GH" bash "$OWNERSHIP" whoami 2>/dev/null )"
check "V6. executed \`ownership.sh whoami\` echoes the login" "[ '$out6' = 'roferg' ]"

repo7="$(new_repo)"
out7="$( cd "$repo7" && GH_WHOAMI=roferg LCARS_GH_BIN="$GH" bash "$OWNERSHIP" owner 42 2>/dev/null )"
check "V7. executed \`ownership.sh owner <n>\` echoes the standing assignee" \
  "[ '$out7' = 'roferg' ]"

# Someone ELSE holds it → the plain line, at rc 0. Same sentence the CLI dies
# with; the daemon's 403 must not invent a second wording.
repo8="$(new_repo)"
rc8=0
out8="$( cd "$repo8" && GH_WHOAMI=capt LCARS_GH_BIN="$GH" bash "$OWNERSHIP" lock-reason 42 2>/dev/null )" || rc8=$?
check "V8. lock-reason on SOMEONE ELSE's mission returns 0 with the plain line" \
  "[ '$rc8' -eq 0 ] && [ '$out8' = 'assigned to roferg — reassign it to yourself on GitHub to take command' ]"

repo9="$(new_repo)"
rc9=0
out9="$( cd "$repo9" && GH_WHOAMI=roferg LCARS_GH_BIN="$GH" bash "$OWNERSHIP" lock-reason 42 2>/dev/null )" || rc9=$?
check "V9. lock-reason on MY OWN mission returns non-zero and says nothing" \
  "[ '$rc9' -ne 0 ] && [ -z '$out9' ]"

: >"$ASSIGNEES"
repo10="$(new_repo)"
rc10=0
out10="$( cd "$repo10" && GH_WHOAMI=capt LCARS_GH_BIN="$GH" bash "$OWNERSHIP" lock-reason 42 2>/dev/null )" || rc10=$?
check "V10. an UNASSIGNED mission is NEVER locked" \
  "[ '$rc10' -ne 0 ] && [ -z '$out10' ]"

# UNRESOLVABLE identity — gh cannot say who we are. We do not get to tell the
# captain he is someone else.
printf 'roferg\n' >"$ASSIGNEES"
repo11="$(new_repo)"
rc11=0
out11="$( cd "$repo11" && GH_WHOAMI= GH_API_RC=1 LCARS_GH_BIN="$GH" bash "$OWNERSHIP" lock-reason 42 2>/dev/null )" || rc11=$?
check "V11. an UNRESOLVABLE identity is NEVER locked" \
  "[ '$rc11' -ne 0 ] && [ -z '$out11' ]"

# LCARS_OWNER_ENFORCE=0 still bypasses everything (harness debugging).
printf 'roferg\n' >"$ASSIGNEES"
repo12="$(new_repo)"
rc12=0
out12="$( cd "$repo12" && GH_WHOAMI=capt LCARS_OWNER_ENFORCE=0 LCARS_GH_BIN="$GH" \
  bash "$OWNERSHIP" lock-reason 42 2>/dev/null )" || rc12=$?
check "V12. LCARS_OWNER_ENFORCE=0 bypasses the executable face too" \
  "[ '$rc12' -ne 0 ] && [ -z '$out12' ]"

# An unknown op is a hard, LOUD error — never a silent 0 the daemon would read
# as "not locked".
rc13=0
( cd "$repo6" && LCARS_GH_BIN="$GH" bash "$OWNERSHIP" no-such-op >/dev/null 2>&1 ) || rc13=$?
rc13b=0
( cd "$repo6" && LCARS_GH_BIN="$GH" bash "$OWNERSHIP" >/dev/null 2>&1 ) || rc13b=$?
check "V13. an unknown op fails loudly (a silent 0 would read as 'not locked')" \
  "[ '$rc13' -ne 0 ] && [ '$rc13b' -ne 0 ]"

# ==========================================================================
# V14. SOURCING IS STILL INERT. The dispatcher must not run when the library is
#      sourced into `lcars file` / `lcars run` — that would print, or exit, in
#      the middle of somebody else's verb.
# ==========================================================================
out14="$( cd "$repo6" && LCARS_GH_BIN="$GH" bash "$PROBE" quiet 2>&1 )"
check "V14. sourcing ownership.sh runs no dispatcher and prints nothing extra" \
  "[ '$out14' = 'SOURCED_QUIET' ]"

# ==========================================================================
# V15. The cache write is BEST-EFFORT: an unwritable cache dir must not fail the
#      resolution (same posture as the S189 whoami cache).
# ==========================================================================
printf 'roferg\n' >"$ASSIGNEES"
repo15="$(new_repo)"
mkdir -p "$repo15/.git/lcars/cache"
chmod 500 "$repo15/.git/lcars/cache"
out15="$( cd "$repo15" && LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 2>/dev/null )"
chmod 700 "$repo15/.git/lcars/cache"
check "V15. an unwritable cache dir does not fail the resolution (best-effort)" \
  "[ '$out15' = 'OWNER=roferg' ]"

# ==========================================================================
# FIX ROUND 1 — D1. A FAILED FORGE CALL IS NOT THE ANSWER "NOBODY".
#
# The defect: `mission_owner` piped the adapter's output into `head -1`, so the
# adapter's return code — the ONE thing that separates "gh could not be asked"
# from "gh says this issue is unassigned" — was thrown away by the pipeline, and
# an empty $val was published either way. Measured: owner files holding real
# logins (8/7/31 bytes) were TRUNCATED TO 0 the moment gh was absent, and every
# `lcars run` on a plane did it too. That collapses `_published_owner`'s three
# documented states into two and makes the board forget whose work is whose for
# no better reason than a dropped connection.
#
# The contract these pin, in the docstring's own words: "a daemon whose forge is
# unreachable simply serves the board it served before this round."
# ==========================================================================
printf 'roferg\n' >"$ASSIGNEES"
repo16="$(new_repo)"
mkdir -p "$repo16/.git/lcars/cache"
printf 'roferg\n' >"$(cache_of "$repo16" 42)"
out16="$( cd "$repo16" && LCARS_GH_BIN="$TMPROOT/no-such-gh" bash "$PROBE" owner 42 2>/dev/null )"
check "V16. an ABSENT gh leaves an already-published owner UNTOUCHED" \
  "[ \"\$(cat '$(cache_of "$repo16" 42)')\" = 'roferg' ]"
check "V16. …and the caller still gets '' — an unreachable forge never locks" \
  "[ '$out16' = 'OWNER=' ]"

repo17="$(new_repo)"
mkdir -p "$repo17/.git/lcars/cache"
printf 'roferg\n' >"$(cache_of "$repo17" 42)"
( cd "$repo17" && GH_VIEW_RC=1 LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 >/dev/null 2>&1 )
check "V17. a gh that is PRESENT and FAILS leaves the published owner UNTOUCHED" \
  "[ \"\$(cat '$(cache_of "$repo17" 42)')\" = 'roferg' ]"

repo18="$(new_repo)"
( cd "$repo18" && GH_VIEW_RC=1 LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 >/dev/null 2>&1 )
check "V18. a FAILED call publishes NOTHING — 'never asked' stays never asked" \
  "[ ! -e '$(cache_of "$repo18" 42)' ]"

# The positive control, and the reason the cure is "publish nothing on failure"
# rather than "never shrink the file": the forge saying NOBODY must still be
# recorded, even over a file that named someone. Without this, V16-V18 would
# also pass a cure that simply stopped publishing empties, and the board could
# never learn that a mission had been UNASSIGNED on GitHub.
: >"$ASSIGNEES"
repo19="$(new_repo)"
mkdir -p "$repo19/.git/lcars/cache"
printf 'roferg\n' >"$(cache_of "$repo19" 42)"
( cd "$repo19" && LCARS_GH_BIN="$GH" bash "$PROBE" owner 42 >/dev/null 2>&1 )
check "V19. a forge that ANSWERS 'nobody' still empties the file (unassigned is an answer)" \
  "[ -f '$(cache_of "$repo19" 42)' ] && [ ! -s '$(cache_of "$repo19" 42)' ]"

echo
printf 'ownership-viewscreen: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
