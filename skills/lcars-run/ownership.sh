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
# --- S190: the two seams the VIEWSCREEN needs ---------------------------------
# The board re-renders several times a minute, and the daemon has a standing rule
# (see local_adapter._meta): A BOARD BUILD DOES NO NETWORK I/O. It also must not
# grow a second Python implementation of "who owns this" (ADR-002, and the S168
# scar: two implementations of one verdict drift apart, and then one surface is
# honest and the other is blind). So this file grows two things and nothing else:
#
#   1. A PUBLISHED ANSWER. `mission_owner` WRITES what the forge told it to a
#      host-scoped file under the cache dir; the daemon READS that file on the
#      render path — pure disk, no subprocess, no network.
#
#      IT WRITES BUT NEVER READS. Reading it here would change S189's own
#      freshness: a write verb's lock would start answering from a file, and a
#      captain who had just reassigned a mission to himself on GitHub would stay
#      locked out by a cache. The forge stays the CLI's only source of truth. The
#      published file is a ONE-WAY publication for a read-only surface, and the
#      daemon re-asks THIS library (live) before it lets any write through — so
#      nothing authoritative is ever decided from the cache.
#
#   2. AN EXECUTABLE FACE (the dispatcher at the very bottom). SOURCED, this file
#      behaves exactly as it did. EXECUTED, it answers three read ops so the
#      daemon's server-side re-check runs the SAME lcars_owner_lock_reason the
#      CLI runs — same posture, same sentence, one implementation.
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

# _lcars_own_publish_owner <issue> <login> — S190. PUBLISH one resolved owner
# where the viewscreen daemon can read it without touching the network.
#
# The file is HOST-SCOPED for exactly the reason the whoami cache is: the same
# issue NUMBER exists on both forges and means different work, so a key that did
# not carry the host could hand a github.com answer back on the enterprise host.
#
# EMPTY CONTENT IS AN ANSWER, not a failure: it means the forge said "nobody".
# An ABSENT file means "never asked". The board must be able to tell those apart
# — it locks on neither, but a mission it has genuinely asked about and found
# unowned is honestly unowned, and one it has never asked about is unknown.
#
# BEST-EFFORT, exactly like the whoami cache write: a read-only .git, a missing
# directory, a full disk — none of them may fail a resolution the caller needs.
# The write goes to a temp file and is MOVED into place so a daemon reading the
# file concurrently never sees a half-written login.
_lcars_own_publish_owner() { # <issue> <login-or-empty>
  local issue="${1:-}" login="${2:-}" dir f tmp
  case "$issue" in ''|null|*[!0-9]*) return 0 ;; esac
  dir="$(_lcars_own_cache_dir)"
  f="$dir/owner-$(_lcars_own_host)-$issue"
  mkdir -p "$dir" 2>/dev/null || return 0
  tmp="$f.$$"
  if [ -n "$login" ]; then
    printf '%s\n' "$login" >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  else
    : >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  fi
  mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
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
    # ANSWERED, or NOT ANSWERED AT ALL — and the difference is the RETURN CODE.
    # The adapter is explicit about it: `issue-assignees` returns 1 when gh is
    # missing or the call fails, and 0 PRINTING NOTHING when the issue is simply
    # unassigned. So the rc is captured on its own line, BEFORE any pipeline: a
    # `… | head -1` reports head's status, which is 0 whatever the forge did,
    # and that dropped rc is what let a dead gh publish an empty owner over a
    # real one (fix round 1, D1). The first line is then taken with parameter
    # expansion rather than a second process.
    local raw rc=0
    raw="$(_lcars_own_host_call issue-assignees "$issue" 2>/dev/null)" || rc=$?
    val="${raw%%$'\n'*}"
    _lcars_own_is_login "$val" || val=""
    eval "$key=\"\$val\""
    # S190: PUBLISH what the forge just said, for the viewscreen. Inside the
    # memo branch on purpose — one publication per process per issue, on the one
    # pass that actually reached the forge. The publication is one-way: nothing
    # here ever reads it back (see the header).
    #
    # ONLY WHEN THE FORGE ACTUALLY ANSWERED. `_published_owner`'s three states —
    # absent (never asked), empty (the forge said nobody), a login — are only
    # three if a FAILED call publishes nothing at all. Publishing on rc≠0 would
    # write "nobody" every time gh was unreachable, erasing an owner LCARS had
    # already been told about, so a captain on a plane would watch his board
    # forget whose work is whose. Unanswered is not an answer: we leave whatever
    # was published standing, and the caller still gets "" (which never locks).
    if [ "$rc" -eq 0 ]; then
      _lcars_own_publish_owner "$issue" "$val"
    fi
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
# lcars_xo_lock_reason <mission-dir | mission-id> — THE ENGAGED LOCK (S201).
# ===========================================================================
# A SECOND REASON ON THE SAME SEAM, not a second mechanism. Number One acts on
# the captain's behalf THROUGH the ordinary verbs; while it holds a mission, a
# captain writing to that same mission from another terminal (or from the board)
# is racing his own first officer. So the write verbs refuse — with ONE sentence,
# at the same call sites, with the same posture the owner lock has kept since
# S189:
#
#   • rc 0 + one plain line  ⇒  refuse
#   • rc 1 + silence         ⇒  proceed
#   • EVERY UNCERTAIN CASE PROCEEDS. No mission dir, no state.json, no
#     `numberOne` key, an unreadable file: all of them are "not engaged". A
#     false lock shuts the captain out of his own work, which is strictly worse
#     than the thing the lock prevents.
#   • LCARS_XO_ENFORCE=0 bypasses it, exactly like LCARS_OWNER_ENFORCE=0.
#
# THE FACT IS RECORDED, NEVER INFERRED. The only thing consulted is
# `state.numberOne.status`, written by `lcars xo` and by the driver. Nothing
# here parses prose, a readout, or a log to work out whether Number One is
# engaged — the producer records it (the standing rule this round).
#
# WHY THE ARGUMENT IS THE MISSION, NOT AN ISSUE NUMBER. `lcars_owner_lock_reason`
# takes an <issue> because ownership is a FORGE fact and the issue is its name
# there. Engagement is a LOCAL fact living in the mission's own state.json, so
# the thing that names it is the mission. The shape is otherwise identical: one
# positional identifier, resolved inside, one sentence out. A path to the
# mission directory is accepted as-is (what the verbs and the daemon both
# already hold); a bare id is resolved against this checkout's
# .git/lcars/missions.
_xo_mission_state() { # <mission-dir | mission-id> → path to state.json, or rc 1
  local m="${1:-}" gitdir
  [ -n "$m" ] || return 1
  case "$m" in
    */*)
      [ -f "$m/state.json" ] || return 1
      printf '%s/state.json' "$m"
      return 0 ;;
  esac
  gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  [ -f "$gitdir/lcars/missions/$m/state.json" ] || return 1
  printf '%s/lcars/missions/%s/state.json' "$gitdir" "$m"
}

# The RECORDED status, or empty. Reads the one-line `numberOne` object the
# writers emit; a missing key, a malformed value and an unreadable file all
# answer empty, which every caller reads as "not engaged".
lcars_xo_status() { # <mission-dir | mission-id>
  local st obj
  st="$(_xo_mission_state "${1:-}")" || return 0
  obj="$(sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$st" | head -1)"
  [ -n "$obj" ] || return 0
  printf '%s' "$obj" \
    | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

lcars_xo_lock_reason() { # <mission-dir | mission-id>
  [ "${LCARS_XO_ENFORCE:-1}" = "0" ] && return 1
  local m="${1:-}" id status
  [ -n "$m" ] || return 1
  status="$(lcars_xo_status "$m")"
  [ "$status" = "engaged" ] || return 1
  # The remedy names THIS mission, so the captain can paste it. A dir argument
  # carries the id as its basename; an id argument is already the id.
  id="$(basename "$m")"
  printf 'Number One is engaged on this mission on your behalf — stand it down (lcars xo off %s) to act yourself' "$id"
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
    # S190: …and so is the published answer. The adapter's issue-assign READ IT
    # BACK before returning 0, so this is a confirmed fact, not an optimistic
    # one — the mission the captain just took reads as HIS on the board without
    # waiting for the next forge read.
    _lcars_own_publish_owner "$issue" "$me"
    return 0
  fi
  printf '  ⚠ could not assign #%s to %s on GitHub — assign it by hand to take command.' "$issue" "$me"
  return 1
}

# ===========================================================================
# THE EXECUTABLE FACE (S190) — how a NON-BASH caller asks these questions.
# ===========================================================================
# Everything above is a library. This block runs ONLY when the file is EXECUTED
# (`bash ownership.sh <op>`), never when it is sourced into `lcars file` /
# `lcars run` / the other write verbs — a dispatcher that fired on `source`
# would print, or exit, in the middle of somebody else's verb.
#
# WHY IT EXISTS. The viewscreen daemon must re-check ownership SERVER-SIDE
# before it lets a write through: a disabled button is not a lock, and anyone can
# POST straight past the DOM. That re-check has to be the SAME verdict the CLI
# reaches — same posture (unassigned never locks, unresolvable never locks,
# LCARS_OWNER_ENFORCE=0 bypasses) and the same sentence. So the daemon SHELLS
# this (ADR-002) instead of reimplementing the rule in Python.
#
# READ OPS ONLY. There is deliberately no `assign` op here: claiming is a write
# the CLI verbs own, and the daemon has no business minting one from a browser
# request.
#
# The guard: when SOURCED, BASH_SOURCE[0] is this file while $0 is the sourcing
# script — they differ. When EXECUTED they are the same string.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    # The login LCARS is acting as. Empty output + non-zero when gh cannot say.
    whoami)
      lcars_whoami
      ;;
    # The standing assignee of an issue, or nothing. ALWAYS rc=0 — "nobody" is
    # an answer, and the caller reads the output, not the status.
    owner)
      mission_owner "${2:-}"
      ;;
    # THE LIGHT LOCK. rc=0 + one plain line ⇒ this mission belongs to someone
    # else and the verb must refuse. rc=1 + silence ⇒ proceed.
    lock-reason)
      lcars_owner_lock_reason "${2:-}"
      ;;
    # S201 — THE ENGAGED LOCK, same contract. rc=0 + one plain line ⇒ Number One
    # holds this mission and the verb must refuse. rc=1 + silence ⇒ proceed. The
    # argument is the MISSION (a directory path, or an id resolved against this
    # checkout) because engagement is recorded in the mission's own state.json.
    xo-lock-reason)
      lcars_xo_lock_reason "${2:-}"
      ;;
    # The RECORDED status itself, for a surface that shows it rather than gates
    # on it. ALWAYS rc=0 — "nothing recorded" is an answer.
    xo-status)
      lcars_xo_status "${2:-}"
      ;;
    # An unknown op is a HARD, LOUD error. A silent 0 would be read by the
    # daemon as "not locked", which is precisely the failure this file exists to
    # prevent — so a typo must never look like permission.
    *)
      printf 'ownership.sh: unknown op: %s (want: whoami | owner <n> | lock-reason <n> | xo-lock-reason <mission> | xo-status <mission>)\n' \
        "${1:-}" >&2
      exit 2
      ;;
  esac
  exit $?
fi
