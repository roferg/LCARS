#!/usr/bin/env bash
#
# ownership.sh — Session 189. WHO YOU ARE, AND WHAT IS YOURS.
#
# This file is SOURCED (like comment-mirror.sh beside it) into `lcars file`,
# `lcars run`, `lcars approve`, `lcars feedback`, `lcars log` and
# `lcars respond`. Sourcing only DEFINES functions and touches nothing — no
# network call, no cache write, no state change happens until a caller asks.
#
# --- why this exists ----------------------------------------------------------
# A mission's real, portable home is its GitHub issue: the second laptop has no
# `.git/lcars` at all. So "whose mission is this?" cannot be answered from local
# state — it has to be answered by the FORGE. The forge's answer is the issue's
# ASSIGNEE, and the captain changes it the way he changes anything else about an
# issue: on GitHub.
#
# --- IDENTITY IS THE (host, login) PAIR — NEVER THE NUMERIC ID ----------------
# Measured against real gh 2.96.0 (skills/lcars-run/ADOPT-RESOLUTION-SPIKE.md,
# A.5): the SAME login `roferg` has `.id` 40493721 on github.com and 97261 on
# the enterprise host. An id is meaningless across forges, `.name` is nullable,
# and the same user's `.avatar_url` differs in its query string between the
# `user` payload and an issue payload. `.login` is the ONLY thing that is both
# stable and the string the assignee API takes. Everything here therefore keys
# on the login, and every cache key is HOST-SCOPED so a login read on one forge
# can never be handed back on another.
#
# --- the shape is deliberately TIEBREAK-COMPATIBLE ----------------------------
# The solo protocol assumes assignment changes are made by HUMANS on GitHub, not
# contended for by CLIs, so there is NO tiebreak and NO claim-race handling here
# — deliberately, per the round's boundary. `mission_owner` is defined as "the
# single standing assignee", which is a question the team round can answer
# DIFFERENTLY (the event-timeline winner among several assignees) by replacing
# ONE function body, with no caller changed. Do not let a caller start reading
# an assignee LIST, or that swap stops being free.
#
# --- the light lock -----------------------------------------------------------
# `lcars_owner_lock_reason` is the one place the lock is decided. It is a LIGHT
# lock on purpose:
#   * only the WRITE verbs consult it (run / respond / approve / feedback / log)
#     — the READ verbs (status, buddy, the viewscreen's reads) are NEVER blocked;
#   * an UNASSIGNED mission is never locked (empty is "unowned", not an error);
#   * an UNRESOLVABLE identity is never locked — if we cannot say who we are, we
#     do not get to tell the captain he is someone else;
#   * LCARS_OWNER_ENFORCE=0 bypasses it entirely (harness debugging).
#
# Env:
#   LCARS_GH_USER        overrides the identity outright (the suites use this)
#   LCARS_OWNER_ENFORCE  0 ⇒ the light lock never blocks
#   LCARS_WHOAMI_TTL     seconds the on-disk whoami cache stays fresh (12h)
#   LCARS_OWNER_CACHE_DIR  where the whoami cache lives (default .git/lcars/cache)
#   LCARS_HOST_ADAPTER / LCARS_GH_BIN   the usual stubbable forge deps
#
# jq-free, bash-3.2-safe, no side effects on source.

# The host adapter — the ONE place that speaks to a forge. It sits beside this
# file; $LCARS_HOST_ADAPTER overrides the path so tests can stub it. Resolved at
# SOURCE time (BASH_SOURCE is only meaningful here), invoked lazily.
_LCARS_OWN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LCARS_OWN_ADAPTER="${LCARS_HOST_ADAPTER:-$_LCARS_OWN_DIR/host-adapter.sh}"

# _lcars_own_host_call — the adapter, with stdin CLOSED.
#
# </dev/null is not decoration: these calls run inside headless drives and inside
# `lcars file`'s interactive flow, and a gh that decides to prompt (auth, a
# confirmation) would otherwise stall a walk-away run forever with no output.
# Ownership is best-effort everywhere; it may fail, it may not hang.
_lcars_own_host_call() {
  LCARS_GH_BIN="${LCARS_GH_BIN:-gh}" bash "$_LCARS_OWN_ADAPTER" "$@" </dev/null
}

# _lcars_own_is_login — does this string look like a forge login at all?
#
# A guard against garbage becoming an identity. GitHub logins are alphanumerics
# and hyphens, ≤39 chars — so a URL, a JSON fragment, an error message or a
# stub's stray echo is rejected rather than assigned to an issue or compared
# against an owner. Anything that is not a login is treated as "no answer",
# which every caller already handles.
_lcars_own_is_login() { # candidate
  case "${1:-}" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
    -*) return 1 ;;
  esac
  [ "${#1}" -le 39 ] || return 1
  return 0
}

# _lcars_own_host — the forge host this repo lives on, for CACHE SCOPING.
# The adapter's gh-host op is a pure read of the origin remote (no gh, no
# network) and echoes NOTHING on github.com, so we name that case explicitly:
# a cache key must never be empty, and "github.com" is what empty means.
_lcars_own_host() {
  local h; h="$(_lcars_own_host_call gh-host 2>/dev/null)"
  [ -n "$h" ] || h="github.com"
  # Keep it filename-safe (a host is already tame, but the key is a path).
  printf '%s' "$h" | tr -c 'A-Za-z0-9._-' '_'
}

# _lcars_own_cache_dir — where the on-disk whoami cache lives. Inside .git so it
# is never committed and dies with the clone; falls back to the temp dir when we
# are not in a repo (then the on-disk layer is simply cold every time).
_lcars_own_cache_dir() {
  if [ -n "${LCARS_OWNER_CACHE_DIR:-}" ]; then printf '%s' "$LCARS_OWNER_CACHE_DIR"; return 0; fi
  local gitdir
  gitdir="$("${LCARS_GIT_BIN:-git}" rev-parse --git-common-dir 2>/dev/null)" || gitdir=""
  if [ -n "$gitdir" ]; then
    case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
    printf '%s' "$gitdir/lcars/cache"
    return 0
  fi
  printf '%s' "${TMPDIR:-/tmp}/lcars-ownership"
}

# _lcars_own_cache_fresh <file> — is the cache file younger than the TTL?
# mtime-based, portable across BSD (`stat -f %m`) and GNU (`stat -c %Y`) stat.
_lcars_own_cache_fresh() { # file
  local f="${1:-}" ttl mt now
  [ -f "$f" ] || return 1
  ttl="${LCARS_WHOAMI_TTL:-43200}"
  case "$ttl" in ''|*[!0-9]*) ttl=43200 ;; esac
  [ "$ttl" -gt 0 ] || return 1
  mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)"
  case "$mt" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s 2>/dev/null)"
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - mt)) -lt "$ttl" ]
}

# ===========================================================================
# lcars_whoami — the login LCARS is acting as. Echoes it, or "" at non-zero.
# ===========================================================================
# Resolution order, first hit wins:
#   1. $LCARS_GH_USER — the env override. It WINS over every cache and makes no
#      forge call at all (this is how the suites pin an identity).
#   2. the per-process memo — one resolution per process, however many callers.
#   3. the on-disk cache, HOST-SCOPED, valid for LCARS_WHOAMI_TTL seconds.
#   4. the forge: the adapter's host-pinned `whoami` op.
#
# gh absent or failing → echoes NOTHING and returns non-zero, and CANNOT HANG
# (the adapter call runs with stdin closed). A caller that cannot learn who it
# is degrades — it never blocks and never guesses.
lcars_whoami() {
  if [ -n "${LCARS_GH_USER:-}" ]; then
    printf '%s' "$LCARS_GH_USER"
    return 0
  fi
  # Per-process memo. _LCARS_WHOAMI_TRIED is set even on failure, so a process
  # that cannot resolve an identity asks the forge exactly ONCE.
  if [ -n "${_LCARS_WHOAMI_TRIED:-}" ]; then
    printf '%s' "${_LCARS_WHOAMI:-}"
    [ -n "${_LCARS_WHOAMI:-}" ]
    return $?
  fi
  _LCARS_WHOAMI_TRIED=1
  _LCARS_WHOAMI=""

  local dir cache login
  dir="$(_lcars_own_cache_dir)"
  cache="$dir/whoami-$(_lcars_own_host)"
  if _lcars_own_cache_fresh "$cache"; then
    login="$(head -1 "$cache" 2>/dev/null)"
    if _lcars_own_is_login "$login"; then
      _LCARS_WHOAMI="$login"
      printf '%s' "$login"
      return 0
    fi
  fi

  login="$(_lcars_own_host_call whoami 2>/dev/null | head -1)"
  if ! _lcars_own_is_login "$login"; then
    return 1
  fi
  _LCARS_WHOAMI="$login"
  # Best-effort cache write — a read-only .git must not fail a resolution.
  mkdir -p "$dir" 2>/dev/null && printf '%s\n' "$login" >"$cache" 2>/dev/null
  printf '%s' "$login"
  return 0
}

# ===========================================================================
# mission_owner <issue> — THE SINGLE STANDING ASSIGNEE, or "".
# ===========================================================================
# THE definition of ownership, and the ONE function the team round replaces to
# introduce a tiebreak. Today: the issue's standing assignee. With several
# assignees (which the solo protocol does not produce) we take the first the
# forge reports rather than inventing a rule — resolving a genuine contention is
# precisely the team round's job, and guessing here would pre-empt it.
#
# Empty output means UNOWNED — never an error. A forge that cannot be reached
# also yields empty, and that is the same answer on purpose: an unreachable
# forge must not lock the captain out of his own missions.
#
# Memoised per process AND per issue: a write verb asks "who owns this?" from
# two or three places in one run, and each of those must not be a round trip.
mission_owner() { # <issue>
  local issue="${1:-}"
  case "$issue" in ''|null|*[!0-9]*) return 0 ;; esac
  local key val
  key="_LCARS_OWNER_MEMO_$issue"
  eval "val=\"\${$key-__lcars_unset__}\""
  if [ "$val" = "__lcars_unset__" ]; then
    val="$(_lcars_own_host_call issue-assignees "$issue" 2>/dev/null | head -1)"
    _lcars_own_is_login "$val" || val=""
    eval "$key=\"\$val\""
  fi
  printf '%s' "$val"
  return 0
}

# mission_unassigned <issue> — true when NOBODY holds this mission.
mission_unassigned() { # <issue>
  [ -z "$(mission_owner "${1:-}")" ]
}

# owner_is_me <issue> — true when the standing assignee is this account.
# False when the mission is unassigned, and false when we cannot resolve our own
# identity (we do not claim a mission we cannot prove is ours).
owner_is_me() { # <issue>
  local owner me
  owner="$(mission_owner "${1:-}")"
  [ -n "$owner" ] || return 1
  me="$(lcars_whoami)" || return 1
  [ -n "$me" ] || return 1
  [ "$owner" = "$me" ]
}

# owner_is_other <issue> — true ONLY when someone ELSE demonstrably holds it.
#
# Every uncertain case answers FALSE: unassigned, an unreachable forge, an
# unresolvable identity. The light lock is built on this function, so a false
# TRUE would lock the captain out of his own work on a flaky network — which is
# strictly worse than the thing the lock prevents.
owner_is_other() { # <issue>
  local owner me
  owner="$(mission_owner "${1:-}")"
  [ -n "$owner" ] || return 1
  me="$(lcars_whoami)" || return 1
  [ -n "$me" ] || return 1
  [ "$owner" != "$me" ]
}

# ===========================================================================
# lcars_owner_lock_reason <issue> — THE LIGHT LOCK, in one place.
# ===========================================================================
# Echoes ONE plain line naming the owner and the remedy, and returns 0, when
# this mission belongs to someone else. Returns 1 (echoing nothing) when the
# verb may proceed. Callers read like this:
#
#   if _r="$(lcars_owner_lock_reason "$issue")"; then die "$_r"; fi
#
# Reassignment is NOT something LCARS does for you: the solo protocol's whole
# premise is that the captain moves ownership on GitHub, where both laptops can
# see it, so the remedy names that and nothing else.
lcars_owner_lock_reason() { # <issue>
  [ "${LCARS_OWNER_ENFORCE:-1}" = "0" ] && return 1
  local issue="${1:-}" owner
  owner_is_other "$issue" || return 1
  owner="$(mission_owner "$issue")"
  [ -n "$owner" ] || return 1
  printf 'assigned to %s — reassign it to yourself on GitHub to take command' "$owner"
  return 0
}

# ===========================================================================
# lcars_claim_mission <issue> — assign this mission to me, BEST-EFFORT.
# ===========================================================================
# The solo paths call this: filing assigns the captain, and a drive on an
# UNASSIGNED mission assigns on its first advance. It echoes a warning LINE (no
# leading/trailing newline handling needed by callers — they print it) and
# returns non-zero when the claim did not land, and echoes nothing at 0 when it
# did or when there was nothing to do.
#
# BEST-EFFORT IS THE POSTURE, exactly like notify.sh and the comment mirror: a
# forge that will not take the assignment must never stop a mission being filed
# or advanced. The warning is how the captain finds out; the work still happens.
#
# The adapter's issue-assign does the read-back, so a `0` here means GitHub
# really shows the assignment — never that the request was merely accepted.
lcars_claim_mission() { # <issue>
  local issue="${1:-}" me err
  case "$issue" in ''|null|*[!0-9]*) return 0 ;; esac
  me="$(lcars_whoami)" || {
    printf '  ⚠ could not read your GitHub identity — #%s was not assigned to you (assign it by hand to take command).' "$issue"
    return 1
  }
  [ -n "$me" ] || {
    printf '  ⚠ could not read your GitHub identity — #%s was not assigned to you (assign it by hand to take command).' "$issue"
    return 1
  }
  # Already mine → nothing to do, no forge write.
  [ "$(mission_owner "$issue")" = "$me" ] && return 0
  # $err SWALLOWS the adapter's own stderr on purpose: the adapter explains the
  # silent-drop case in its own words, and a caller printing BOTH would put two
  # messages on a readout whose contract is one warning line. The rc is the
  # signal; the wording below is this layer's.
  if err="$(_lcars_own_host_call issue-assign "$issue" "$me" 2>&1 >/dev/null)"; then
    # The memo is now stale — this process just changed the answer.
    eval "_LCARS_OWNER_MEMO_$issue=\"\$me\""
    return 0
  fi
  printf '  ⚠ could not assign #%s to %s on GitHub — assign it by hand to take command.' "$issue" "$me"
  return 1
}
