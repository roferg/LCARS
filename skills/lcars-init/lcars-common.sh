#!/usr/bin/env bash
#
# lcars-common.sh — shared, sourceable helpers used by both `lcars init` and
# `lcars update`. Keeping the canonical label set and the merge-preserving
# config writer in ONE place means update can extend an already-initialized repo
# with exactly the same labels/keys init would create — no drift, no duplication.
#
# This file defines functions and data only; it runs nothing on its own. Source
# it:
#
#     . "$(dirname "$0")/lcars-common.sh"
#
# Dependencies are read from the caller's environment so tests can stub them:
#   GH_BIN   the gh binary (callers set this from ${LCARS_GH_BIN:-gh})
#
# ---------------------------------------------------------------------------
# CANONICAL LABEL SET
# ---------------------------------------------------------------------------
# One source of truth for the LCARS GitHub labels: their names, group colours,
# and descriptions. Both init (first-time setup) and update (fill-the-gaps)
# create from this list, skipping any label already present on the repo.

LCARS_STAGE_COLOR="FF9900"
LCARS_TYPE_COLOR="4499FF"
LCARS_STATUS_COLOR="FF3344"
LCARS_REL_COLOR="9977FF"
LCARS_ROLE_COLOR="00B894"

LCARS_STAGE_LABELS="align research validate plan plan-review schedule implement verify done"
LCARS_TYPE_LABELS="feature bug"
LCARS_STATUS_LABELS="paused awaiting-human"
LCARS_REL_LABELS="linked"
LCARS_ROLE_LABELS="mission ticket"

lcars_label_desc() {
  case "$1" in
    lcars:align)          echo "Stage: aligning on the mission goal with the captain" ;;
    lcars:research)       echo "Stage: exploring the codebase and constraints" ;;
    lcars:validate)       echo "Stage: confirming research with the captain" ;;
    lcars:plan)           echo "Stage: drafting the implementation plan" ;;
    lcars:plan-review)    echo "Stage: captain reviewing the plan" ;;
    lcars:schedule)       echo "Stage: breaking the plan into tasks" ;;
    lcars:implement)      echo "Stage: executing the tasks" ;;
    lcars:verify)         echo "Stage: confirming the work meets the goal" ;;
    lcars:done)           echo "Stage: mission complete" ;;
    lcars:feature)        echo "Type: a feature mission" ;;
    lcars:bug)            echo "Type: a bug mission" ;;
    lcars:paused)         echo "Status: mission paused" ;;
    lcars:awaiting-human) echo "Status: waiting on the captain's orders" ;;
    lcars:linked)         echo "Relationship: linked to another mission" ;;
    lcars:mission)        echo "Role: a Mission's own command-and-control issue" ;;
    lcars:ticket)         echo "Role: an implementation sub-issue spun up by Schedule" ;;
    *)                    echo "LCARS label" ;;
  esac
}

# Emit every canonical "lcars:<name>|<color>" pair, one per line. Callers iterate
# this so the ordering/colours stay defined in exactly one place.
lcars_all_labels() {
  local n
  for n in $LCARS_STAGE_LABELS;  do echo "lcars:$n|$LCARS_STAGE_COLOR";  done
  for n in $LCARS_TYPE_LABELS;   do echo "lcars:$n|$LCARS_TYPE_COLOR";   done
  for n in $LCARS_STATUS_LABELS; do echo "lcars:$n|$LCARS_STATUS_COLOR"; done
  for n in $LCARS_REL_LABELS;    do echo "lcars:$n|$LCARS_REL_COLOR";    done
  for n in $LCARS_ROLE_LABELS;   do echo "lcars:$n|$LCARS_ROLE_COLOR";   done
}

# lcars_create_labels — create any MISSING canonical labels on the current repo.
#
# Args:
#   $1  gh binary
#   $2  newline-separated list of labels already on the repo (may be empty)
#
# Sets these globals for the caller to report on:
#   LCARS_LABELS_CREATED   count created this run
#   LCARS_LABELS_SKIPPED   count already present (skipped)
#   LCARS_LABELS_CREATED_NAMES  space-separated names created
#
# A label already present is skipped (never re-created), so this is idempotent
# and shared identically by init and update.
lcars_create_labels() {
  local gh="$1" existing="$2"
  LCARS_LABELS_CREATED=0
  LCARS_LABELS_SKIPPED=0
  LCARS_LABELS_CREATED_NAMES=""

  local line name color
  while IFS='|' read -r name color; do
    [ -n "$name" ] || continue
    if printf '%s\n' "$existing" | grep -Fxq "$name"; then
      LCARS_LABELS_SKIPPED=$((LCARS_LABELS_SKIPPED + 1))
      continue
    fi
    if "$gh" label create "$name" --color "$color" \
         --description "$(lcars_label_desc "$name")" >/dev/null 2>&1; then
      LCARS_LABELS_CREATED=$((LCARS_LABELS_CREATED + 1))
      LCARS_LABELS_CREATED_NAMES="${LCARS_LABELS_CREATED_NAMES:+$LCARS_LABELS_CREATED_NAMES }$name"
    else
      # Treat "already exists" races and other soft failures as skips.
      LCARS_LABELS_SKIPPED=$((LCARS_LABELS_SKIPPED + 1))
    fi
  done <<EOF
$(lcars_all_labels)
EOF
}

# ---------------------------------------------------------------------------
# FORGE HOST (GitHub Enterprise support)
# ---------------------------------------------------------------------------
# lcars_gh_web_host — the host to put in a link the captain will CLICK, derived
# from the repo's own origin remote. Falls back to github.com when there is no
# remote or it cannot be parsed, so a repo with no origin reads exactly as it
# always did.
#
# init/update used to print a hardcoded "on github.com/<owner>/<repo>", which on
# an enterprise repo links to a repository that does not exist. Unlike the
# adapter's gh_hostname (which returns EMPTY for github.com so the `gh api` argv
# stays byte-for-byte historic), this one ALWAYS yields a host — it is for
# display, where "github.com" is the right thing to actually print.
#
# LCARS_GH_HOST overrides, matching the adapter.
lcars_gh_web_host() {
  if [ -n "${LCARS_GH_HOST:-}" ]; then printf '%s' "$LCARS_GH_HOST"; return 0; fi
  local url h
  url="$("${LCARS_GIT_BIN:-git}" remote get-url origin 2>/dev/null)" \
    || { printf 'github.com'; return 0; }
  [ -n "$url" ] || { printf 'github.com'; return 0; }
  h="${url#*://}"    # drop scheme (https://, ssh://, git://)
  h="${h#*@}"        # drop user@ (scp-style git@host:owner/repo)
  h="${h%%/*}"       # drop the path
  h="${h%%:*}"       # drop :port, and the scp-style ":owner/repo"
  [ -n "$h" ] || h="github.com"
  printf '%s' "$h"
}

# ---------------------------------------------------------------------------
# BASE FRESHNESS (S158)
# ---------------------------------------------------------------------------
# A Mission filed off a base branch that is behind origin makes every downstream
# Stage reason about a tree that no longer exists. Observed 2026-07-30: a mission
# cut from a `main` 19 commits behind origin had Research truthfully report that a
# file "does not exist" — true of the stale tree, false of the deployed app — and
# the mission shipped 10 lines into a decoy.
#
# `ensure_base_current <base>` measures that base against origin BEFORE the
# Mission's branch is cut, brings it up to date when it safely can, and records an
# honest verdict either way. It ALWAYS returns 0 — a freshness check must never be
# the thing that stops a filing — and it is BEST-EFFORT: it declines to act in a
# dozen conditions, and in every one the Mission is still filed against whatever
# the captain has.
#
# THE CAPTAIN'S CLONE IS SACRED. It may fast-forward a clean, checked-out base and
# nothing else: never reset/force/stash/clean/switch/checkout, and never a write
# into a dirty tree. It DOES fetch on a dirty tree — a fetch writes only to
# refs/remotes/ — because "you are 19 behind" is a warning a captain acts on where
# "you might be behind" is one they dismiss.
#
# THE NETWORK HALF AND THE REF-MOVING HALF ARE SEPARATE, AND ONLY THE FIRST IS
# BOUNDED. A `git pull` is a fetch AND a checkout, so bounding it lets a kill land
# MID-CHECKOUT: a 1s bound against a commit adding 20,000 files wrote 8,455 of
# them into a tester's tree while the block said "nothing was pulled". So: (1) a
# narrow, bounded `git fetch` — killable, and provably unable to touch the working
# tree; then (2) an UNBOUNDED, local `git merge --ff-only <already-fetched sha>` —
# no network, and nothing that may kill it part-way. `--ff-only` is git's own
# refusal-by-default. Do not re-introduce LCARS_BASE_PULL_TIMEOUT_SECS: no
# ref-moving step is bounded any more, deliberately.
#
# THE VOCABULARY IS FOUR WORDS. It was fifteen — one name per situation, each with
# its own bespoke Why/Means/Fix prose — and across two captain-stand-in tester
# rounds EVERY defect was either a wrong git decision or copy that lied about one.
# The name count WAS the lying surface. The verdict now answers only the question
# a consumer acts on; the situation lives in ONE sentence beside it:
#
#   current   the base is up to date; nothing to do. This INCLUDES a base that is
#             merely AHEAD of origin (the everyday unpushed commit): the only
#             question this guard asks is whether the base is MISSING something
#             origin has, and an ahead-only base is missing nothing.
#   updated   LCARS brought it up to date; the mission is cut from the fresh tip.
#   stale     the base is behind and LCARS could NOT fix it — dirty tree, diverged
#             base, a fast-forward that would clobber an ignored file, a base that
#             is not checked out, a refused fast-forward, or an unpushed branch
#             behind the trunk it was cut from.
#   unknown   freshness could NOT be determined — no remote, unreachable, too slow
#             to wait for, no resolvable trunk, no such local branch, guard off,
#             or not a git repo at all.
#
# S159 ADDS EXACTLY ONE MORE, AND IT IS NOT A SHADE OF STALENESS:
#
#   child-base  the base is ANOTHER MISSION's branch, so the question does not
#               apply. A logged bug's base is its parent's `lcars/<parent-id>`
#               branch: "bring it up to date from origin" would mean moving the
#               fix onto code it was never written against — the exact "fix the
#               bug child by rebasing it onto main" hazard. The guard takes no
#               network call and moves no ref; it says so and stops.
#
# LOUDNESS IS CARRIED, NOT DERIVED: `unknown` covers both the silent everyday
# no-remote case and the loud unreachable one, so which outcomes shout is its own
# field, set with the verdict and never inferred from it. "Badge or no badge" is
# that one field.
#
# Exported globals — the record a caller persists (see lcars_base_state_line):
#     LCARS_BASE_VERDICT      current | updated | stale | unknown
#     LCARS_BASE_LOUD         1 when this outcome prints the ⚠ block, else 0
#     LCARS_BASE_REASON       one sentence naming what actually happened
#     LCARS_BASE_FIX          the exact command that fixes it (may be empty)
#     LCARS_BASE_BEHIND       commits origin has that the base does not, measured
#                             PRE-pull. EMPTY = NOT MEASURED, persisted as JSON
#                             `null`; `0` is reserved for a measured zero, because
#                             a reassuring 0 from a check that measured nothing is
#                             the one lie a consumer cannot detect.
#     LCARS_BASE_AHEAD        commits the base has that origin does not, same
#                             doctrine. Without it a consumer cannot tell "3
#                             behind and 2 ahead, genuinely diverged, act now"
#                             from "0 behind, 1 unpushed commit, perfectly fine".
#     LCARS_BASE_SHA          the base branch's sha AFTER the attempt — and
#                             NOTHING when there is no such branch. It never
#                             substitutes HEAD: a detached HEAD with no local
#                             `main` reported a real-looking sha for a branch that
#                             does not exist.
#     LCARS_BASE_CHECKED_AT   ISO stamp (honours $LCARS_NOW so callers can pin it)
#     LCARS_BASE_BRANCH       the base branch it was asked about
#     LCARS_BASE_TRUNK        origin's default branch, when one was resolved

# The ONE consequence sentence, printed under every ⚠ block. It is a CONSTANT on
# purpose: the per-verdict `Means:` prose it replaces is exactly where the copy
# lied twice — a `no-base` block that talked about "your LOCAL main" when there
# was no local main, and a detached HEAD told it was filed against `main`. A
# sentence that does not vary cannot describe the wrong situation.
LCARS_BASE_IMPACT="a Stage reasons about the tree it is handed — an out-of-date one makes it confidently wrong about code that already exists."

# lcars_base_is_mission_branch <name> — is this branch name an LCARS MISSION
# branch rather than a trunk or topic branch?
#
# THE RULE IS THE `lcars/` NAMESPACE, and it is complete because LCARS mints
# mission branches in exactly ONE shape and nowhere else: `lcars/<mission-id>`
# (skills/lcars-file/file.sh `BRANCH="lcars/$ID"`, and skills/lcars-log/log.sh,
# which bases each bug child on its parent's branch — `lcars/<parent-id>` — or
# falls back to that literal name). Nothing else in LCARS creates a branch a
# Mission can be based on.
#
# Deliberately ONE rule, not two. A second, weaker heuristic (scan the missions
# on disk for one that claims this branch) would answer the same question a
# different way, and two answers is one more surface that can disagree — the
# S158 lesson about name count applies just as much to detection rules.
lcars_base_is_mission_branch() {
  case "${1:-}" in
    lcars/?*) return 0 ;;
    *)        return 1 ;;
  esac
}

# _lcars_base_git — the git binary, env-injected so tests can stub it.
_lcars_base_git() { printf '%s' "${LCARS_GIT_BIN:-${GIT_BIN:-git}}"; }

# _lcars_base_count <from> <to> — commits in from..to. EMPTY on any failure, so a
# caller can tell "not measured" from a measured zero.
_lcars_base_count() {
  local g c; g="$(_lcars_base_git)"
  c="$("$g" rev-list --count "$1..$2" 2>/dev/null)"
  case "$c" in ''|*[!0-9]*) c="" ;; esac
  printf '%s' "$c"
}

# THE RECORD IS ESCAPED BY `lcars_json_escape`, THE SIBLING IN THIS FILE — there
# is deliberately no bespoke escaper here any more. The one this section used to
# own stripped only \n\r\t and escaped only `\` and `"`, so every OTHER control
# byte went into state.json verbatim: a gitignored collider named
# `dist/ctl<0x01>name.txt` produced a record `python3 -m json.tool` refused
# ("Invalid control character at: line 9 column 282"). state.json is the record
# SKILL.md documents as consumable. `lcars file` writes it and S159's drive-time
# re-check (`cmd_drive` in skills/lcars-run/run.sh) both READS and REWRITES it;
# S160's board badge is specified to read it and is not built yet. It must ALWAYS
# parse, whatever byte a captain happens to have in a filename. Round 4, D2.

# _lcars_base_visible <string> — make control characters VISIBLE, and touch
# NOTHING else. This is the DISPLAY escaper, and it is deliberately not
# `lcars_json_escape`: that one also escapes `\` and `"`, which would mangle the
# perfectly ordinary paths `build/back\slash.txt` and `build/quo"te.txt` in a
# warning the captain has to compare against their own `ls` output.
#
# It exists because a colliding path holding a NEWLINE was flattened to a space
# by `tr '\n' ' '`, so `dist/two\nline.txt` printed as `dist/two line.txt` —
# indistinguishable from a genuine space in a name, and from two separate files.
# The file was protected and named correctly; only the rendering was lossy.
_lcars_base_visible() {
  printf '%s' "${1:-}" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\x%02x",b; else printf "%s",c } } }'
}

# _lcars_base_render_paths <newline-separated paths> — one space-joined list with
# every path in its own quotes. The quotes are the point: without a delimiter,
# `a b.txt` and the two files `a` + `b.txt` render identically.
#
# A path may contain the DELIMITER ITSELF, and that re-opened the very ambiguity
# the quoting exists to close: `dist/it's.txt` + `dist/plain.txt` came out as
# `'dist/it's.txt' 'dist/plain.txt'`, which reads just as well as `dist/it` +
# `s.txt'`. So an apostrophe is escaped the one way that is unambiguous inside
# single quotes — close, escape, re-open (`'it'\''s.txt'`) — which is also
# exactly what a shell would accept back. Nothing ELSE is touched: `\` and `"`
# stay verbatim (behaviour 33) so the captain can compare the warning against
# their own `ls`, and control characters are already made visible upstream by
# `_lcars_base_visible` (behaviour 41). Every check that DECIDES anything —
# `[ -e ]`, `ls-files`, `show | cmp` — still runs on the RAW path; this is
# display only. Round 5, D1.
_lcars_base_render_paths() {
  # bash 3.2 mangles a backslash-escaped apostrophe in a substitution's
  # replacement text (`${p//\'/\'\\\'\'}` yields `it\'\\'\'s`), so the delimiter
  # is carried in a variable and the replacement built from it.
  local out="" p q sq="'"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    q="${p//$sq/$sq\\$sq$sq}"
    [ -n "$out" ] && out="$out "
    out="$out'$q'"
  done <<EOF
${1:-}
EOF
  printf '%s' "$out"
}

# _lcars_base_run_bounded <secs> <outfile> <cmd…> — run a command with a HARD
# wall-clock bound, returning its status (or 124 on timeout). `lcars file` against
# a blackholed remote once printed NOTHING for 75 seconds; filing must never be
# held hostage by the network. `timeout(1)` is not reliably present on macOS, so
# this is run.sh's background-and-poll technique (perl setsid, so the whole process
# GROUP dies and no stray git is left running), copied rather than depended on.
#
# Three details are load-bearing. The poll-and-kill runs in a SUBSHELL with its
# own stderr on /dev/null, because bash reports a killed background job as
# "… line 248: 92631 Terminated: 15  perl -e …" — which reads like a crash and
# lands in whatever captures the CLI's output, the viewscreen daemon included (the
# command's own output is untouched: it goes to $outfile). The wait is a wall-clock
# deadline and the TERM→KILL grace is 0.2s, so "(up to Ns)" is a ceiling the code
# really honours. $SECONDS' 1s granularity can only make the kill land EARLY.
_lcars_base_run_bounded() {
  local secs="$1" outfile="$2"; shift 2
  case "$secs" in ''|*[!0-9]*) secs=8 ;; esac
  local rc=0
  (
    local pid t0="$SECONDS"
    if command -v perl >/dev/null 2>&1; then
      perl -e 'use POSIX qw(setsid); eval { setsid(); }; exec @ARGV' -- "$@" >"$outfile" 2>&1 &
    else
      "$@" >"$outfile" 2>&1 &
    fi
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$((SECONDS - t0))" -ge "$secs" ]; then
        kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 0.2 2>/dev/null || true
        kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 124
      fi
      sleep 0.2 2>/dev/null || sleep 1 2>/dev/null || true
    done
    wait "$pid"; exit $?
  ) 2>/dev/null
  rc=$?
  return "$rc"
}

# _lcars_base_fetch_secs — the ONE bound, overridable. It covers each bounded
# NETWORK call; the fast-forward that follows is local and unbounded.
#
# It SANITISES exactly as `_lcars_base_run_bounded` does, and that is the whole
# point of it existing rather than reading the env var inline: the announcement
# and the runner must never be able to disagree. `LCARS_BASE_FETCH_TIMEOUT_SECS=abc`
# printed "(up to abcs)…" over a call the runner had quietly clamped to 8 — an
# announced bound that is not the bound is a lie the captain has no way to catch.
# Round 4, D3.
_lcars_base_fetch_secs() {
  local s="${LCARS_BASE_FETCH_TIMEOUT_SECS:-8}"
  case "$s" in ''|*[!0-9]*) s=8 ;; esac
  printf '%s' "$s"
}

# _lcars_base_envp — populate LCARS_BASE_ENVP, the argv prefix that makes git
# INCAPABLE of stopping to ask a human anything. Without it, a machine with no
# cached credentials pops a bare `Username for 'https://github.com':` in the
# middle of a filing, with no context at all. It is an ARRAY (not a string)
# because GIT_SSH_COMMAND legitimately contains spaces.
_lcars_base_envp() {
  LCARS_BASE_ENVP=(env
    GIT_TERMINAL_PROMPT=0
    GIT_ASKPASS=echo
    SSH_ASKPASS=echo
    "GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes")
}

# _lcars_base_announce <what> — one legible line BEFORE EACH bounded network
# call, so a slow remote reads as a slow remote and not as a hang. Every bounded
# call announces itself, so the stated bound is the truth about the call the
# captain is waiting on rather than about only the first of several.
_lcars_base_announce() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  printf '  ⟳ base freshness — %s (up to %ss)…\n' "$1" "$(_lcars_base_fetch_secs)"
  return 0
}

# _lcars_base_fetch_ref <branch> — a NARROW, tagless, bounded fetch of exactly ONE
# branch into its own remote-tracking ref. Returns git's status (124 on timeout).
# A bare `git fetch origin` turned a tester's clone from 2 remote-tracking refs and
# 0 tags into 62 refs and 1 tag after a SINGLE `lcars file`: not destructive, but a
# filing command has no business restructuring the captain's remote refs, and on a
# monorepo a whole-remote fetch is the likeliest way to blow the bound and
# manufacture a false `unknown`. The trunk, when needed, is fetched just as
# narrowly.
_lcars_base_fetch_ref() {
  local g rc=0; g="$(_lcars_base_git)"
  [ -n "${1:-}" ] || return 1
  _lcars_base_envp
  _lcars_base_announce "fetching origin/$1"
  _lcars_base_run_bounded "$(_lcars_base_fetch_secs)" /dev/null \
    "${LCARS_BASE_ENVP[@]}" "$g" fetch --no-tags --quiet origin \
    "+refs/heads/$1:refs/remotes/origin/$1" || rc=$?
  return "$rc"
}

# _lcars_base_probe [branch] — ask origin ONE bounded, read-only question:
# `ls-remote --symref origin HEAD [refs/heads/<branch>]`. It answers two things a
# failed fetch cannot distinguish on its own:
#   • is origin ALIVE? (a fetch that ran out of its bound against a remote that
#     answers instantly is SLOW, not unreachable, and saying "LCARS could not
#     reach origin" about it is simply false)
#   • does origin have a branch by that name at all? (the everyday unpushed topic
#     branch, which must not read as a failure)
# Sets LCARS_BASE_PROBE_RC (0 = origin answered), LCARS_BASE_PROBE_TRUNK (origin's
# default branch, when HEAD resolves) and LCARS_BASE_PROBE_HASBASE (0 = yes).
_lcars_base_probe() {
  local g out rc=0 ref="${1:-}"; g="$(_lcars_base_git)"
  LCARS_BASE_PROBE_TRUNK=""; LCARS_BASE_PROBE_HASBASE=1; LCARS_BASE_PROBE_RC=1
  out="$(mktemp 2>/dev/null)" || return 0
  _lcars_base_envp
  _lcars_base_announce "asking origin what it has"
  if [ -n "$ref" ]; then
    _lcars_base_run_bounded "$(_lcars_base_fetch_secs)" "$out" \
      "${LCARS_BASE_ENVP[@]}" "$g" ls-remote --symref origin HEAD "refs/heads/$ref" || rc=$?
  else
    _lcars_base_run_bounded "$(_lcars_base_fetch_secs)" "$out" \
      "${LCARS_BASE_ENVP[@]}" "$g" ls-remote --symref origin HEAD || rc=$?
  fi
  LCARS_BASE_PROBE_RC="$rc"
  if [ "$rc" -eq 0 ]; then
    LCARS_BASE_PROBE_TRUNK="$(sed -n 's|^ref: refs/heads/\([^[:space:]]*\)[[:space:]].*|\1|p' "$out" 2>/dev/null | head -1)"
    if [ -n "$ref" ]; then
      awk -v r="refs/heads/$ref" '$2==r { found=1 } END { exit found?0:1 }' "$out" 2>/dev/null \
        && LCARS_BASE_PROBE_HASBASE=0
    fi
  fi
  rm -f "$out"
  return 0
}

# _lcars_base_resolve_trunk [hint] — resolve origin's DEFAULT branch name into
# LCARS_BASE_TRUNK_NAME (empty when it cannot be resolved honestly). A hint from a
# probe that already ran wins, so the trunk never costs a second network call;
# otherwise refs/remotes/origin/HEAD (present in every real clone), and only if
# that is missing is origin asked. It answers in a VARIABLE, never on stdout,
# because it may make a network call and every network call ANNOUNCES itself —
# inside a `$(…)` that announcement gets captured as part of the trunk NAME, and
# a real drive printed `⟳ … fetching origin/  ⟳ … asking origin what it has…`.
_lcars_base_resolve_trunk() {
  local g ref hint="${1:-}" probed="${2:-0}"; g="$(_lcars_base_git)"
  LCARS_BASE_TRUNK_NAME=""
  if [ -n "$hint" ]; then LCARS_BASE_TRUNK_NAME="$hint"; return 0; fi
  ref="$("$g" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  if [ -n "$ref" ]; then LCARS_BASE_TRUNK_NAME="${ref#origin/}"; return 0; fi
  # A probe that already ran asked for `--symref HEAD` too, so if it came back
  # without a trunk, asking again cannot produce one — and the empty-remote path
  # really did print "asking origin what it has" twice, under a comment claiming
  # the trunk "never costs a second network call".
  [ "$probed" = "1" ] && return 0
  _lcars_base_probe ""
  LCARS_BASE_TRUNK_NAME="${LCARS_BASE_PROBE_TRUNK:-}"
  return 0
}

# _lcars_base_clobber_paths <from-sha> <to-sha> — paths the incoming commits add
# that ALREADY EXIST locally as files git is not tracking (untracked or, the
# dangerous case, gitignored). `git status --porcelain` reads CLEAN with a
# gitignored `dist/bundle.js` sitting there, so without this check an
# LCARS-initiated fast-forward silently destroys a file the captain never asked
# anyone to touch. A file whose local content is BYTE-IDENTICAL to the incoming
# one has nothing to lose, so refusing over it would warn about a harm that
# cannot happen — compare, and let it through.
#
# THE ENUMERATION IS NUL-SEPARATED, AND THAT IS LOAD-BEARING. `core.quotePath` is
# git's DEFAULT, so plain `--name-only` C-QUOTES any path holding a non-ASCII
# byte, a `"` or a `\` — `"build/caf\303\251.txt"` — and the literal quoted
# string fails `[ -e ]`, so the collider was silently DROPPED and the pull went
# through with a ✓ over the captain's file. With a mixed set only the ASCII
# sibling was named, so obeying the printed fix and re-filing destroyed the rest.
# `-z` applies no quoting or escaping at all (and survives newlines in names too),
# where `-c core.quotePath=false` would still escape `"` and `\`.
#
# It EMITS one path per line with control characters made visible
# (`_lcars_base_visible`), which is what makes "one line = one path" true even for
# a name that contains a newline. Every check above it — `[ -e ]`, `ls-files`,
# `show | cmp` — runs against the RAW byte-for-byte path; only the OUTPUT is
# rendered. Round 4, D2 (smell).
_lcars_base_clobber_paths() {
  local g root; g="$(_lcars_base_git)"
  root="$("$g" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  (
    cd "$root" 2>/dev/null || exit 0
    "$g" diff --name-only -z "$1" "$2" 2>/dev/null | while IFS= read -r -d '' p; do
      [ -n "$p" ] || continue
      [ -e "$p" ] || continue
      "$g" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && continue
      if [ -f "$p" ] && "$g" show "$2:$p" 2>/dev/null | cmp -s - "$p" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$(_lcars_base_visible "$p")"
    done
  )
}

# _lcars_base_dirt <porcelain> — describe what `git status --porcelain` is
# ACTUALLY showing, and pick a stash that would actually move it. Untracked-only
# dirt was once reported as "N uncommitted change(s)" with the fix `git stash` —
# which does not touch untracked files at all, so the captain ran it, was told
# "No local changes to save", and got nowhere. The copy must match the KIND of
# dirt. Sets LCARS_BASE_DIRT_DESC and LCARS_BASE_DIRT_STASH.
_lcars_base_dirt() {
  local porc="$1" line x y staged=0 unstaged=0 untracked=0 parts=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '??'*) untracked=$((untracked + 1)); continue ;;
    esac
    x="${line:0:1}"; y="${line:1:1}"
    [ -n "$x" ] && [ "$x" != " " ] && staged=$((staged + 1))
    [ -n "$y" ] && [ "$y" != " " ] && unstaged=$((unstaged + 1))
  done <<EOF
$porc
EOF
  [ "$staged"    -gt 0 ] && parts="$staged staged change(s)"
  if [ "$unstaged" -gt 0 ]; then
    [ -n "$parts" ] && parts="$parts and "
    parts="$parts$unstaged unstaged change(s)"
  fi
  if [ "$untracked" -gt 0 ]; then
    [ -n "$parts" ] && parts="$parts and "
    parts="$parts$untracked untracked file(s)"
  fi
  [ -n "$parts" ] || parts="uncommitted change(s)"
  LCARS_BASE_DIRT_DESC="$parts"
  # `git stash` leaves untracked files exactly where they are; -u is the only
  # form that moves them. Naming the wrong one is what made the old fix a no-op.
  if [ "$untracked" -gt 0 ]; then
    LCARS_BASE_DIRT_STASH="git stash -u"
  else
    LCARS_BASE_DIRT_STASH="git stash"
  fi
  return 0
}

# _lcars_base_set <verdict> <loud> <reason> [fix] — record the outcome + resolve
# the base's post-attempt sha. Deliberately does NOT touch LCARS_BASE_BEHIND /
# LCARS_BASE_AHEAD, which callers set before calling when they measured them.
#
# `baseSha` is the BASE BRANCH's sha or NOTHING. It used to fall back to HEAD,
# which meant a detached HEAD with no local `main` recorded a real-looking sha for
# a branch that does not exist, and a consumer reading it believed local `main`
# sat there. That is the same substitution `behindBy` refuses when it reports
# `null` rather than a reassuring `0` — an invented value a consumer cannot
# detect. No base branch, no sha.
_lcars_base_set() {
  local g; g="$(_lcars_base_git)"
  LCARS_BASE_VERDICT="$1"
  LCARS_BASE_LOUD="$2"
  LCARS_BASE_REASON="$3"
  LCARS_BASE_FIX="${4:-}"
  LCARS_BASE_SHA="$("$g" rev-parse --verify -q "refs/heads/$LCARS_BASE_BRANCH" 2>/dev/null)" || LCARS_BASE_SHA=""
  return 0
}

# lcars_base_report — say one legible thing about the outcome. A quiet outcome says
# NOTHING (a local-only or already-current repo must read exactly as it did before
# this guard existed); `updated` gets one ✓ line; a LOUD one gets the block.
# LCARS_BASE_QUIET=1 silences all of it. The ✓ line claims only what this function
# can know — that the BASE moved. Whether the MISSION sits on it is a different
# fact, owned by lcars_base_branch_note: with a leftover `lcars/<id>` at an old sha
# the two are opposites, and printing both claims side by side was a lie.
lcars_base_report() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  [ -n "${LCARS_BASE_VERDICT:-}" ] || return 0
  if [ "${LCARS_BASE_LOUD:-0}" != "1" ]; then
    [ "$LCARS_BASE_VERDICT" = "updated" ] && \
      printf '  ✓ base %s fast-forwarded %s commit(s) from origin.\n' \
        "$LCARS_BASE_BRANCH" "${LCARS_BASE_BEHIND:-?}"
    # S159 — a skipped check still says it skipped. `child-base` is not a warning
    # (it is the CORRECT state for every logged bug), so it gets one quiet line
    # rather than the ⚠ block: silence here would read as "checked, all fine",
    # which is a different claim from "did not check, and here is why".
    [ "$LCARS_BASE_VERDICT" = "child-base" ] && \
      printf '  ⊘ base %s is a Mission branch — left exactly as it is (nothing fetched, nothing moved).\n' \
        "$LCARS_BASE_BRANCH"
    return 0
  fi
  printf '\n'
  if [ "$LCARS_BASE_VERDICT" = "stale" ]; then
    printf "  ⚠ BASE FRESHNESS — '%s' is out of date and LCARS could not fix it [%s]\n" \
      "$LCARS_BASE_BRANCH" "$LCARS_BASE_VERDICT"
  elif [ -z "${LCARS_BASE_SHA:-}" ] \
    && ! "$(_lcars_base_git)" rev-parse --verify -q "refs/heads/$LCARS_BASE_BRANCH" >/dev/null 2>&1; then
    # There IS no branch by that name. `file.sh` falls back to the literal string
    # `main` for a detached HEAD, so in a `master`-only repo the old header asked
    # whether 'main' was out of date — a question about a branch that exists
    # nowhere. The header must not assert the thing the reason is about to deny.
    printf "  ⚠ BASE FRESHNESS — there is no local branch named '%s' to check [%s]\n" \
      "$LCARS_BASE_BRANCH" "$LCARS_BASE_VERDICT"
  else
    printf "  ⚠ BASE FRESHNESS — LCARS could not tell whether '%s' is out of date [%s]\n" \
      "$LCARS_BASE_BRANCH" "$LCARS_BASE_VERDICT"
  fi
  printf '    Why:    %s\n' "$LCARS_BASE_REASON"
  [ -n "${LCARS_BASE_FIX:-}" ] && printf '    Fix:    %s\n' "$LCARS_BASE_FIX"
  printf '    Impact: %s\n' "$LCARS_BASE_IMPACT"
  printf '\n'
  return 0
}

# lcars_base_branch_note [mission-branch] [base] [how] — the truth about the
# MISSION's OWN branch: is it sitting on the base this check just judged? Two
# places need it — filing, where a leftover `lcars/<id>` at an old sha must not be
# papered over by the base's ✓ line, and `--complete`, where the branch was cut at
# park time and the base has since moved (it must NOT be re-cut, so say so with the
# command that fixes it). `how` is `reused` or `new`, because hard-coding "already
# existed at <sha>" is a flat untruth about a branch this filing just created from
# a detached HEAD; an empty `how` claims neither.
lcars_base_branch_note() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  local g mb="${1:-}" base="${2:-${LCARS_BASE_BRANCH:-}}" how="${3:-}" tip basesha behind ahead tipshort hb
  g="$(_lcars_base_git)"
  [ -n "$mb" ] && [ -n "$base" ] || return 0
  tip="$("$g" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)" || tip=""
  basesha="$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" || basesha=""
  # No branch yet (an empty repo) or no local base: the caller's own warnings
  # already cover those, and inventing a second one would just add noise.
  [ -n "$tip" ] && [ -n "$basesha" ] || return 0
  behind="$(_lcars_base_count "$tip" "$basesha")"
  if [ "${behind:-0}" = "0" ]; then
    # The mission branch DOES contain the base tip. Only say so when something
    # actually moved — an already-current repo stays silent, as it always has.
    [ "${LCARS_BASE_VERDICT:-}" = "updated" ] \
      && printf '  ✓ %s is cut from the CURRENT tree.\n' "$mb"
    return 0
  fi
  ahead="$(_lcars_base_count "$basesha" "$tip")"
  tipshort="$("$g" rev-parse --short "$tip" 2>/dev/null)"
  # The branch HEAD is on right now — empty when detached. Two things need it:
  # the `new` Why: line, and the way back offered under the rebase fix.
  hb="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || hb=""
  printf '\n'
  printf '  ⚠ MISSION BRANCH — %s is %s commit(s) behind %s\n' "$mb" "$behind" "$base"
  case "$how" in
    new)
      # Name the commit the mission branch is REALLY on, once — a detached HEAD's
      # description already IS that sha, so repeating it read as a stutter.
      if [ -n "$hb" ]; then
        printf "    Why:    %s was cut by this filing from '%s', at %s — LCARS cuts a mission\n" "$mb" "$hb" "$tipshort"
      else
        printf '    Why:    %s was cut by this filing from the detached commit %s — LCARS cuts a\n' "$mb" "$tipshort"
      fi
      printf '            mission branch from HEAD, and never moves your HEAD to do it.\n'
      ;;
    reused)
      printf '    Why:    %s already existed at %s, and LCARS never moves a branch that\n' "$mb" "$tipshort"
      printf '            may already carry work — so it was reused exactly as it was.\n'
      ;;
    *)
      printf '    Why:    %s sits at %s, and LCARS never moves a branch that may already\n' "$mb" "$tipshort"
      printf '            carry work — so it was left exactly as it was.\n'
      ;;
  esac
  printf '    Means:  this mission does NOT contain the latest %s commit(s) on %s. Every\n' "$behind" "$base"
  printf '            Stage works from %s, so they will reason about that older tree.\n' "$mb"
  if [ "${ahead:-0}" = "0" ]; then
    # A pure fast-forward of the pointer: no commit can be lost, and saying so is
    # the difference between an instruction and a gamble. It is still a CHOICE —
    # a branch deliberately cut at an older commit was cut there on purpose.
    printf '    Fix:    git branch -f %s %s   (a fast-forward: %s has no commits of its own,\n' "$mb" "$base" "$mb"
    printf '            so nothing is lost — do this only if you meant to base this mission\n'
    printf '            on %s rather than %s)\n' "$base" "$tipshort"
  else
    # NEVER `git branch -f` here: it would silently discard commits that exist
    # nowhere else. The command is right and its RESULT is right, but it CHECKS
    # THE MISSION BRANCH OUT and leaves the captain there — a silent relocation,
    # in a guard whose own doctrine is "LCARS will not check out another branch".
    # The command does not change; it just stops being coy about what it does.
    printf '    Fix:    git rebase %s %s   (%s carries %s commit(s) of its own, which\n' "$base" "$mb" "$mb" "$ahead"
    printf '            forcing the branch pointer would DESTROY — so rebase, and do NOT\n'
    printf '            force it. Note it leaves you on %s: git checkout %s\n' "$mb" "${hb:--}"
    printf '            brings you back)\n'
  fi
  printf '\n'
  return 0
}

# ---------------------------------------------------------------------------
# THE DRIVE-TIME MISSION-BRANCH ADVANCE (S159, captain ruling 2026-07-31)
# ---------------------------------------------------------------------------
# BRINGING THE BASE UP TO DATE IS NOT THE GOAL. `mission_branch_block` in
# skills/lcars-run/run.sh pins every Research / Validate / Plan / Plan Review
# worker to `lcars/<id>` and tells it, in those words, to IGNORE the ambient
# checkout — so a drive that fast-forwards `main` and leaves the mission branch on
# its filing-time tip still hands every Stage the stale tree. The captain's ruling
# is that the drive must move the MISSION BRANCH too.
#
# IT MOVES IT ONLY WHEN THAT IS LOSSLESS: zero commits of its own relative to the
# base (`git rev-list --count <base>..<mb>` = 0), which is exactly the case S158's
# own file-time reporter already describes as "a fast-forward: no commits of its
# own, so nothing is lost". One commit of its own and the branch is left where it
# is, with the loud ⚠ block and its `git rebase` fix — forcing the pointer there
# would DESTROY work that exists nowhere else.
#
# FILE TIME IS UNCHANGED. `lcars_base_branch_note` above is the file-time voice
# and keeps every word of it: at filing, "a branch cut at an older commit was cut
# there on purpose" (S158), so it reports and offers `git branch -f` as a CHOICE.
# The drive-time voice is `lcars_base_branch_note_drive`, a SEPARATE function, for
# the reason the two must not blur: once LCARS really does move the branch, the
# file-time sentence "LCARS never moves a branch that may already carry work" is
# false of a drive, and its `git branch -f` Fix line is an instruction to do a
# thing already done. Two situations, two functions, no shared prose.
#
# THREE LANES, AND THE LANE IS DECIDED BY WHERE THE BRANCH IS CHECKED OUT —
# `git worktree list --porcelain`, never a guess:
#
#   not checked out anywhere       `git branch -f <mb> <base-sha>`. A pure pointer
#                                  move; given ahead == 0 it is a fast-forward by
#                                  construction, and it touches no working tree.
#   checked out, tree CLEAN        `git -C <worktree> merge --ff-only <base-sha>`.
#                                  `git branch -f` FAILS outright on a checked-out
#                                  branch ("cannot force update the branch …
#                                  checked out at …"), including in a worktree
#                                  whose directory is gone. A real fast-forward in
#                                  place is the only move that works, and it
#                                  leaves that checkout on the SAME branch — no
#                                  checkout, no detach, no HEAD relocation.
#   checked out, tree DIRTY        REFUSE. S158's doctrine is absolute: LCARS
#                                  never writes into a dirty tree. Say which
#                                  checkout, what kind of dirt, and give the one
#                                  command that clears it.
#
# `git merge --ff-only` will HAPPILY run in a dirty tree when the incoming commits
# do not touch the modified files — verified — so the dirty refusal is LCARS's own
# check, not something git can be relied on to make for it.
#
# A `child-base` Mission is out of scope by the same ruling: a logged bug's base is
# its parent's branch, LCARS takes no position on it, and the parent's branch is
# never moved. `drive_base_recheck` does not call this at all for that verdict.
#
# Exported globals (deliberately NOT part of the verdict vocabulary — the verdict
# stays the five names, and "did the mission branch move" is a different question
# with its own field, `missionBranchAtBase`):
#     LCARS_MB_MOVE     moved | refused | ''   ('' = nothing to decide)
#     LCARS_MB_BEHIND   commits the base has that the mission branch does not
#     LCARS_MB_AHEAD    commits of its own — the number that decides losslessness
#     LCARS_MB_REASON   one sentence naming what actually happened
#     LCARS_MB_FIX      ONE runnable command (may be empty), gloss after 3 spaces
#     LCARS_MB_WT       the checkout it found, when there was one

# _lcars_base_worktree_of <branch> — the worktree path where refs/heads/<branch> is
# checked out, or EMPTY. Sets LCARS_MB_WT.
#
# `git worktree list --porcelain` is asked, not guessed: the ambient tree and every
# linked mission worktree appear in the same list, so "checked out in the captain's
# own clone" and "checked out in a mission worktree" are one lane, decided by one
# question. `-z` is used because a worktree path may contain any byte — a newline
# included — and the line format would split one path into two records; the line
# format is the fallback for a git too old for `-z`.
_lcars_base_worktree_of() {
  local g want rec path="" hits=0
  g="$(_lcars_base_git)"
  LCARS_MB_WT=""
  [ -n "${1:-}" ] || return 0
  want="branch refs/heads/$1"
  while IFS= read -r -d '' rec; do
    hits=$((hits + 1))
    case "$rec" in
      "worktree "*) path="${rec#worktree }" ;;
    esac
    [ "$rec" = "$want" ] && LCARS_MB_WT="$path"
  done < <("$g" worktree list --porcelain -z 2>/dev/null)
  [ "$hits" -gt 0 ] && return 0
  path=""
  while IFS= read -r rec; do
    case "$rec" in
      "worktree "*) path="${rec#worktree }" ;;
    esac
    [ "$rec" = "$want" ] && LCARS_MB_WT="$path"
  done < <("$g" worktree list --porcelain 2>/dev/null)
  return 0
}

# lcars_base_advance_mission_branch <mission-branch> <base> — the move itself.
# ALWAYS returns 0: like everything else in this guard it is best-effort and never
# the thing that stops a drive.
lcars_base_advance_mission_branch() {
  local g mb="${1:-}" base="${2:-}" tip basesha behind ahead wt dirty out rc q stashargs clob
  g="$(_lcars_base_git)"
  LCARS_MB_MOVE=""; LCARS_MB_BEHIND=""; LCARS_MB_AHEAD=""
  LCARS_MB_REASON=""; LCARS_MB_FIX=""; LCARS_MB_WT=""
  [ -n "$mb" ] && [ -n "$base" ] || return 0
  # A Mission whose branch IS the base has nothing to reconcile.
  [ "$mb" != "$base" ] || return 0
  tip="$("$g" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)" || tip=""
  basesha="$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" || basesha=""
  # No branch (an empty repo) or no local base: `ensure_base_current`'s own
  # warnings already cover those, and a second one would be noise.
  [ -n "$tip" ] && [ -n "$basesha" ] || return 0

  behind="$(_lcars_base_count "$tip" "$basesha")"
  # EMPTY means NOT MEASURED, and the whole record's doctrine is that an
  # unmeasured number is never substituted with a reassuring one. Say nothing.
  case "$behind" in ''|*[!0-9]*) return 0 ;; esac
  LCARS_MB_BEHIND="$behind"
  # Already contains the base — the ordinary in-flight state. Nothing to do.
  [ "$behind" = "0" ] && return 0

  ahead="$(_lcars_base_count "$basesha" "$tip")"
  case "$ahead" in
    ''|*[!0-9]*)
      LCARS_MB_MOVE="refused"
      LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base', but LCARS could not measure how many commits of its own it carries — and it only fast-forwards a mission branch when that is provably lossless, so nothing was moved."
      return 0 ;;
  esac
  LCARS_MB_AHEAD="$ahead"

  # --- lane 0: the branch carries WORK. Never move it. ---------------------
  if [ "$ahead" != "0" ]; then
    local hb; hb="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || hb=""
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' carries $ahead commit(s) of its own. LCARS fast-forwards a mission branch onto its base ONLY when that is lossless — no commits of its own — and forcing this pointer would DESTROY those $ahead commit(s), so nothing was moved."
    LCARS_MB_FIX="git rebase $base $mb   (rebase, and do NOT force it. It leaves you on $mb: git checkout ${hb:--} brings you back)"
    return 0
  fi

  # --- from here the move is LOSSLESS: `$mb` is an ancestor of `$base`. ----
  _lcars_base_worktree_of "$mb"
  wt="$LCARS_MB_WT"

  # --- lane 1: not checked out anywhere → a pure pointer fast-forward ------
  if [ -z "$wt" ]; then
    rc=0; out="$("$g" branch -f "$mb" "$basesha" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
      LCARS_MB_MOVE="moved"
      LCARS_MB_REASON="It carried no commits of its own and is not checked out anywhere, so its branch pointer was fast-forwarded onto '$base' — nothing was lost and no working tree was written to."
    else
      # No Fix line: the only command that would clear this is the one that just
      # failed, and a Fix that cannot succeed is not a Fix (S158, seven of them).
      LCARS_MB_MOVE="refused"
      LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but git refused to move it: $(printf '%s' "$out" | head -1)"
    fi
    return 0
  fi

  q="$(_lcars_base_render_paths "$wt")"

  # --- the checkout is registered but GONE (a removed worktree dir). -------
  # `git branch -f` refuses for THIS branch even then ("cannot force update the
  # branch … checked out at …"), and `git -C` cannot run there at all — verified.
  if [ ! -d "$wt" ] || ! "$g" -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but git still has it registered as checked out at $q — a directory that is no longer there — and it refuses to move a checked-out branch, so nothing was moved."
    LCARS_MB_FIX="git worktree prune   (drops the dead registration; the next drive then fast-forwards $mb for you)"
    return 0
  fi

  # --- lane 2: checked out with a DIRTY tree → refuse ----------------------
  # `git merge --ff-only` really does run in a dirty tree when the incoming
  # commits happen not to touch the modified files, so this refusal is LCARS's,
  # not git's. The captain's uncommitted work is never a thing a drive writes over.
  dirty="$("$g" -C "$wt" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    _lcars_base_dirt "$dirty"
    stashargs="${LCARS_BASE_DIRT_STASH#git }"
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but it is checked out at $q whose working tree has ${LCARS_BASE_DIRT_DESC:-uncommitted change(s)} — LCARS never writes into a dirty tree, so your uncommitted work is untouched and the branch was left where it was."
    LCARS_MB_FIX="git -C $q $stashargs && git -C $q merge --ff-only $base   (your work is stashed, not lost — git -C $q stash pop restores it)"
    return 0
  fi

  # --- would the fast-forward EAT an untracked/gitignored file? ------------
  # Same bar as the base's own step 8: `git status` reads clean with a gitignored
  # build artifact sitting there, and a fast-forward LCARS chose is held higher
  # than one the captain typed. The helper judges the tree it is standing in.
  clob="$( cd "$wt" 2>/dev/null && _lcars_base_clobber_paths "$tip" "$basesha" )"
  if [ -n "$clob" ]; then
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but fast-forwarding it in its checkout at $q would OVERWRITE local file(s) git is not tracking, whose content differs from the incoming one — so nothing was moved and your file(s) are intact: $(_lcars_base_render_paths "$clob")"
    LCARS_MB_FIX="move or delete those file(s), then   git -C $q merge --ff-only $base"
    return 0
  fi

  # --- lane 3: checked out and CLEAN → advance it in place ----------------
  rc=0; out="$("$g" -C "$wt" merge --ff-only "$basesha" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    LCARS_MB_MOVE="moved"
    LCARS_MB_REASON="It carried no commits of its own and is checked out at $q with a clean tree, so it was fast-forwarded there — nothing was lost, that checkout is still on $mb, and no HEAD was moved."
  else
    LCARS_MB_MOVE="refused"
    LCARS_MB_REASON="'$mb' is $behind commit(s) behind '$base' and carries no commits of its own, but the local fast-forward in its checkout at $q failed ($(printf '%s' "$out" | head -1)) — the ref was not moved and nothing was written."
  fi
  return 0
}

# lcars_base_branch_note_drive — the DRIVE-TIME voice, and ONLY that. It reports
# what `lcars_base_advance_mission_branch` just did; it decides nothing itself, so
# the words and the git operation cannot drift apart. Style follows
# `lcars_base_report` (one long line per field) rather than the file-time note's
# hand-wrapped prose — deliberately, so the two are not mistakable for each other
# and so every `Fix:` is one copyable command with its gloss after three spaces.
lcars_base_branch_note_drive() {
  [ "${LCARS_BASE_QUIET:-0}" = "1" ] && return 0
  local mb="${1:-}" base="${2:-}"
  case "${LCARS_MB_MOVE:-}" in
    moved)
      printf '  ✓ MISSION BRANCH — %s fast-forwarded %s commit(s) onto %s.\n' \
        "$mb" "${LCARS_MB_BEHIND:-?}" "$base"
      printf '    %s\n' "$LCARS_MB_REASON"
      ;;
    refused)
      printf '\n'
      printf '  ⚠ MISSION BRANCH — %s is %s commit(s) behind %s, and LCARS did not move it\n' \
        "$mb" "${LCARS_MB_BEHIND:-?}" "$base"
      printf '    Why:    %s\n' "$LCARS_MB_REASON"
      [ -n "${LCARS_MB_FIX:-}" ] && printf '    Fix:    %s\n' "$LCARS_MB_FIX"
      printf '    Means:  every Stage in this drive reads %s, so it will reason about that older tree.\n' "$mb"
      printf '    Impact: %s\n' "$LCARS_BASE_IMPACT"
      printf '\n'
      ;;
  esac
  return 0
}

# lcars_base_state_line [mission-branch] — the ONE-LINE state.json field (with its
# trailing comma), or nothing when no check has run. One line on purpose: run.sh's
# state_set_*/state_del editors are line-oriented, so a multi-line object would not
# survive a later stage's write. `behindBy` is `null` unless staleness was really
# measured. `missionBranchAtBase` answers what `baseSha` alone cannot — baseSha is
# the BASE's sha, and a reused `lcars/<id>` may not be on it — and is `null` when
# no mission branch was named. An unknown sha is `null` too: an empty string is a
# value a consumer cannot tell from a real one.
lcars_base_state_line() {
  [ -n "${LCARS_BASE_VERDICT:-}" ] || return 0
  local behind="${LCARS_BASE_BEHIND:-}" ahead="${LCARS_BASE_AHEAD:-}" atbase="null" mb="${1:-}" g tip shaj="null" loud="false"
  case "$behind" in ''|*[!0-9]*) behind="null" ;; esac
  case "$ahead"  in ''|*[!0-9]*) ahead="null"  ;; esac
  if [ -n "$mb" ]; then
    g="$(_lcars_base_git)"
    tip="$("$g" rev-parse --verify -q "refs/heads/$mb" 2>/dev/null)" || tip=""
    if [ -n "$tip" ] && [ -n "${LCARS_BASE_SHA:-}" ]; then
      if [ "$tip" = "$LCARS_BASE_SHA" ]; then atbase="true"; else atbase="false"; fi
    fi
  fi
  [ -n "${LCARS_BASE_SHA:-}" ] && shaj="\"$LCARS_BASE_SHA\""
  [ "${LCARS_BASE_LOUD:-0}" = "1" ] && loud="true"
  printf '  "baseFreshness": { "verdict": "%s", "loud": %s, "reason": "%s", "fix": "%s", "behindBy": %s, "aheadBy": %s, "baseSha": %s, "checkedAt": "%s", "missionBranchAtBase": %s },' \
    "$LCARS_BASE_VERDICT" "$loud" \
    "$(lcars_json_escape "${LCARS_BASE_REASON:-}")" "$(lcars_json_escape "${LCARS_BASE_FIX:-}")" \
    "$behind" "$ahead" "$shaj" "${LCARS_BASE_CHECKED_AT:-}" "$atbase"
  return 0
}

# ensure_base_current <base-branch> — the guard itself. ALWAYS returns 0.
ensure_base_current() {
  local base="${1:-main}"
  local g dirty n remote_sha local_sha head_branch head_desc ahead behind
  local trunk trunk_sha frc clob first fsecs how mergeout nofix unborn
  local remote_missing=0 probe_alive="" probe_trunk="" probe_ran=0
  g="$(_lcars_base_git)"
  fsecs="$(_lcars_base_fetch_secs)"
  _lcars_base_envp

  LCARS_BASE_BRANCH="$base"
  LCARS_BASE_VERDICT=""
  LCARS_BASE_LOUD=0
  LCARS_BASE_BEHIND=""          # "" = NOT MEASURED (persisted as JSON null)
  LCARS_BASE_AHEAD=""           # same doctrine: "" = NOT MEASURED
  LCARS_BASE_SHA=""
  LCARS_BASE_REASON=""
  LCARS_BASE_FIX=""
  LCARS_BASE_TRUNK=""
  LCARS_BASE_CHECKED_AT="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)}"

  # Kill switch, mirroring LCARS_VERSION_CHECK=0: zero network, zero output. The
  # sha is still resolved — it costs one local rev-parse and an empty baseSha
  # would be a hole in the record for no reason.
  if [ "${LCARS_BASE_FRESHNESS:-1}" = "0" ]; then
    _lcars_base_set unknown 0 \
      "the base-freshness guard is switched off (LCARS_BASE_FRESHNESS=0), so nothing was checked."
    lcars_base_report
    return 0
  fi

  # 0 — not a git repo at all. The caller already handles this; stay silent.
  if ! "$g" rev-parse --git-dir >/dev/null 2>&1; then
    _lcars_base_set unknown 0 "not inside a git repository — nothing to check."
    lcars_base_report
    return 0
  fi

  # 0b — the base is ANOTHER MISSION's branch (S159). Checked before ANY network
  #      call and before any ref is looked at, because there is no version of
  #      this question worth asking: a logged bug is based on its parent's
  #      `lcars/<parent-id>` branch, and origin's trunk is not what that branch
  #      is supposed to contain. Bringing it "up to date" would move the fix onto
  #      code it was never written against — the failure this lane exists to
  #      prevent. Take no network call, move no ref, and say so.
  if lcars_base_is_mission_branch "$base"; then
    _lcars_base_set child-base 0 \
      "'$base' is an LCARS Mission branch, not a trunk — this Mission is based on another Mission's work (a logged bug's fix belongs on its parent's branch), so there is nothing to bring down from origin. Nothing was fetched and no ref was moved."
    lcars_base_report
    return 0
  fi

  # 1 — no `origin`. The everyday local-only repo: there is nothing to be stale
  #     against, so this must be indistinguishable from pre-S158 behaviour.
  if ! "$g" config --get remote.origin.url >/dev/null 2>&1; then
    _lcars_base_set unknown 0 \
      "this repo has no 'origin' remote — there is nothing to be stale against."
    lcars_base_report
    return 0
  fi

  # 2 — is the tree dirty? Noted now, acted on LATER. A dirty tree forbids the
  #     fast-forward, not the measurement: a fetch writes only into refs/remotes/
  #     and provably cannot touch the working tree, and "you are 19 behind" is a
  #     warning a captain can act on where "you might be behind" is one they
  #     dismiss.
  dirty="$("$g" status --porcelain 2>/dev/null)"
  LCARS_BASE_DIRT_DESC=""; LCARS_BASE_DIRT_STASH="git stash"
  if [ -n "$dirty" ]; then
    _lcars_base_dirt "$dirty"
  fi
  n="${LCARS_BASE_DIRT_DESC:-}"

  # 3 — fetch: NARROW, ANNOUNCED, BOUNDED and INCAPABLE of prompting. One branch,
  #     no tags, into one remote-tracking ref.
  frc=0
  _lcars_base_fetch_ref "$base" || frc=$?
  remote_missing=0
  probe_alive=""
  if [ "$frc" -ne 0 ]; then
    # A narrow fetch fails for two very different reasons, and the difference
    # matters to every sentence printed below. Ask origin one bounded question.
    _lcars_base_probe "$base"
    probe_ran=1
    probe_alive="$LCARS_BASE_PROBE_RC"
    if [ "$LCARS_BASE_PROBE_RC" -eq 0 ] && [ "$LCARS_BASE_PROBE_HASBASE" -ne 0 ]; then
      # Origin is fine and simply has no branch by that name: the everyday
      # unpushed topic branch. Not a failure — fall through to the trunk lane.
      remote_missing=1
      frc=0
      probe_trunk="$LCARS_BASE_PROBE_TRUNK"
    fi
  fi
  if [ "$frc" -ne 0 ]; then
    # Nothing could be measured on any of these paths, so the verdict is
    # `unknown` — including when the tree is also dirty. Saying `stale` would
    # assert a staleness LCARS never established.
    if [ "$frc" -eq 124 ] && [ "${probe_alive:-1}" -eq 0 ]; then
      # ORIGIN ANSWERED — instantly — it was the fetch that ran long. Calling
      # this "unreachable" was false.
      first="fetching origin/$base timed out after ${fsecs}s (set LCARS_BASE_FETCH_TIMEOUT_SECS to change that), but origin ANSWERED a plain ref listing straight away — it is reachable, just slower than LCARS is willing to make you wait, so '$base' was not measured."
      if [ -n "$dirty" ]; then
        _lcars_base_set unknown 1 \
          "the working tree has $n, and $first Nothing was written to your tree." \
          "$LCARS_BASE_DIRT_STASH   (or commit your work)   then   git pull --ff-only origin $base   — or raise LCARS_BASE_FETCH_TIMEOUT_SECS and re-file"
      else
        _lcars_base_set unknown 1 "$first" \
          "git fetch origin $base   (or raise LCARS_BASE_FETCH_TIMEOUT_SECS and re-file)"
      fi
    else
      if [ "$frc" -eq 124 ]; then
        first="fetching origin/$base timed out after ${fsecs}s (set LCARS_BASE_FETCH_TIMEOUT_SECS to change that), and origin did not answer a plain ref listing either — LCARS could not check whether '$base' is behind."
      else
        first="could not fetch from origin (offline, auth, or the remote is unreachable) — LCARS could not check whether '$base' is behind."
      fi
      if [ -n "$dirty" ]; then
        # The old fix was `git stash … then git pull`, and a tester verified the
        # pull fails from here ("Please make sure you have the correct access
        # rights"). A fix that cannot succeed is not a fix — origin has to come
        # back first, and the copy must say so.
        _lcars_base_set unknown 1 \
          "the working tree has $n, and $first Nothing was written to your tree, and until origin answers no command can bring '$base' up to date." \
          "reach origin first (VPN / network / auth) — then   $LCARS_BASE_DIRT_STASH   (or commit your work)   then   git pull --ff-only origin $base"
      else
        _lcars_base_set unknown 1 "$first" \
          "reach origin first (VPN / network / auth) — then   git fetch origin $base"
      fi
    fi
    lcars_base_report
    return 0
  fi

  local_sha="$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" || local_sha=""
  if [ "$remote_missing" -eq 1 ]; then
    # Origin told us it has no such branch. A stale remote-tracking ref left over
    # from an older clone must not be allowed to contradict that.
    remote_sha=""
  else
    remote_sha="$("$g" rev-parse --verify -q "refs/remotes/origin/$base" 2>/dev/null)" || remote_sha=""
  fi

  # 4 — the base has NO counterpart on origin. This is the captain doing the
  #     ordinary thing — `git checkout -b my-wip`, or working in a linked worktree
  #     on an unpushed branch — and calling it "nothing to be stale against" is
  #     false: a topic branch is stale against the trunk it was cut from; that is
  #     the whole concept. So measure against origin's DEFAULT branch and shout
  #     when it is behind. NEVER pull the trunk into a topic branch — that is a
  #     merge, which this guard is forbidden to make. Measure and warn only.
  if [ -z "$remote_sha" ]; then
    # The trunk is resolved from the probe's answer when one was taken (no second
    # network call), and its objects are fetched just as narrowly as the base's.
    _lcars_base_resolve_trunk "$probe_trunk" "$probe_ran"
    trunk="$LCARS_BASE_TRUNK_NAME"
    trunk_sha=""
    if [ -n "$trunk" ]; then
      _lcars_base_fetch_ref "$trunk" || true
      trunk_sha="$("$g" rev-parse --verify -q "refs/remotes/origin/$trunk" 2>/dev/null)" || trunk_sha=""
    fi
    if [ -z "$trunk_sha" ]; then
      # The fix must be a command that can SUCCEED from here. The old one —
      # `git remote set-head origin <name>` — cannot: set-head requires
      # refs/remotes/origin/<name> to exist locally, and on the very fixture that
      # produces this verdict (an EMPTY origin) it never does; `--auto` fails too
      # ("Cannot determine remote HEAD"). What actually ends this condition is
      # giving origin a branch to be measured against.
      if [ -n "$("$g" rev-parse --verify -q "refs/heads/$base" 2>/dev/null)" ]; then
        nofix="git push -u origin $base   (origin has no branch to measure '$base' against — pushing it gives LCARS one)"
      elif "$g" rev-parse --verify -q HEAD >/dev/null 2>&1; then
        nofix="git branch $base && git push -u origin $base   (neither this repo nor origin has a '$base' branch yet)"
      else
        # NO COMMITS AT ALL. `$base` is not to be trusted here: `git rev-parse
        # --abbrev-ref HEAD` FAILS on an unborn HEAD, so file.sh falls back to
        # the literal string `main` — while the branch the captain's first commit
        # will actually land on is whatever `init.defaultBranch` says, and git's
        # stock default is `master`. The old fix named `main` and obeying it
        # errored outright ("error: src refspec main does not match any").
        # `symbolic-ref --short HEAD` DOES answer on an unborn HEAD: it is the
        # honest name of the branch the captain is already on. Round 4, D1.
        unborn="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || unborn=""
        [ -n "$unborn" ] || unborn="$base"
        nofix="make your first commit, then   git push -u origin $unborn   (this repo has no commits and origin has no branches)"
      fi
      _lcars_base_set unknown 1 \
        "origin has no '$base' branch, and origin's DEFAULT branch could not be resolved either — so LCARS could not measure whether '$base' is out of date at all." \
        "$nofix"
      lcars_base_report
      return 0
    fi
    LCARS_BASE_TRUNK="$trunk"
    if [ -z "$local_sha" ]; then
      _lcars_base_set unknown 1 \
        "there is no local '$base' branch, and origin has none either — nothing to compare or move, and this mission's branch is cut from HEAD as it stands." \
        "git fetch origin $trunk:$base"
      lcars_base_report
      return 0
    fi
    behind="$(_lcars_base_count "$local_sha" "$trunk_sha")"
    LCARS_BASE_BEHIND="$behind"
    LCARS_BASE_AHEAD="$(_lcars_base_count "$trunk_sha" "$local_sha")"
    if [ "${behind:-0}" = "0" ]; then
      _lcars_base_set current 0 \
        "origin has no '$base' branch (an unpushed local branch), and it already contains everything on origin/$trunk."
      lcars_base_report
      return 0
    fi
    _lcars_base_set stale 1 \
      "origin has no '$base' branch, so LCARS measured against origin/$trunk: '$base' is $behind commit(s) behind it. LCARS will not merge a trunk into a topic branch — that is a real merge, not a fast-forward — so nothing was moved." \
      "git merge origin/$trunk   (or git rebase origin/$trunk), then re-file"
    lcars_base_report
    return 0
  fi

  if [ -z "$local_sha" ]; then
    _lcars_base_set unknown 1 \
      "there is no local '$base' branch to compare against origin/$base — this mission's branch is cut from HEAD as it stands." \
      "git fetch origin $base:$base"
    lcars_base_report
    return 0
  fi

  if [ "$local_sha" = "$remote_sha" ]; then
    LCARS_BASE_BEHIND=0
    LCARS_BASE_AHEAD=0
    _lcars_base_set current 0 "local '$base' is exactly origin's '$base'."
    lcars_base_report
    return 0
  fi

  # Both distances, measured once, before any verdict is chosen. This guard cares
  # about exactly one of them: whether the base is MISSING something origin has.
  LCARS_BASE_BEHIND="$(_lcars_base_count "$local_sha" "$remote_sha")"
  LCARS_BASE_AHEAD="$(_lcars_base_count "$remote_sha" "$local_sha")"
  behind="${LCARS_BASE_BEHIND:-?}"
  ahead="${LCARS_BASE_AHEAD:-?}"

  # 5a — AHEAD ONLY: the most ordinary state there is — an unpushed local commit.
  #      The base contains everything origin has, which is the whole question this
  #      guard asks, so it is CURRENT and SILENT. It used to be shouted at as
  #      `stale` while the same record said `behindBy: 0`, under a fix
  #      (`git pull --rebase`) that is a literal no-op here, so re-filing
  #      reproduced the identical warning forever and only `git push` cleared it.
  if [ "${LCARS_BASE_BEHIND:-}" = "0" ]; then
    _lcars_base_set current 0 \
      "local '$base' already contains everything on origin/$base, and carries $ahead commit(s) origin does not yet have (unpushed) — nothing to bring down."
    lcars_base_report
    return 0
  fi

  # 5b — DIVERGED: behind AND ahead, so there is no fast-forward to make. Refuse
  #      and say so; never rebase, never merge. Reconciling really does clear this
  #      (afterwards the base is ahead-only, which 5a calls current).
  if ! "$g" merge-base --is-ancestor "$local_sha" "$remote_sha" >/dev/null 2>&1; then
    _lcars_base_set stale 1 \
      "local '$base' has $ahead commit(s) origin does not and is $behind commit(s) behind origin — a fast-forward is impossible, so nothing was moved." \
      "git pull --rebase origin $base   (or reconcile '$base' by hand), then re-file"
    lcars_base_report
    return 0
  fi

  # 6 — behind and fast-forwardable. Now the dirty tree matters: it forbids the
  #     fast-forward (and only the fast-forward).
  if [ -n "$dirty" ]; then
    _lcars_base_set stale 1 \
      "the working tree has $n — LCARS never writes into a dirty tree, so your own uncommitted work was not touched and '$base' was left $behind commit(s) behind origin." \
      "$LCARS_BASE_DIRT_STASH   (or commit your work)   then   git pull --ff-only origin $base"
    lcars_base_report
    return 0
  fi

  # 7 — only move the ref when HEAD actually IS that branch; LCARS will not check
  #     out another branch to do it. `rev-parse --abbrev-ref HEAD` answers the
  #     literal string "HEAD" when detached (never empty), so the detached case is
  #     detected with symbolic-ref instead of a fallback that could never fire —
  #     the captain was reading "HEAD is on 'HEAD'".
  head_branch="$("$g" symbolic-ref -q --short HEAD 2>/dev/null)" || head_branch=""
  if [ "$head_branch" != "$base" ]; then
    if [ -n "$head_branch" ]; then head_desc="'$head_branch'"; else head_desc="a detached commit"; fi
    _lcars_base_set stale 1 \
      "local '$base' is $behind commit(s) behind origin, but HEAD is on $head_desc — LCARS will not check out another branch, so nothing was moved." \
      "git checkout $base && git pull --ff-only origin $base"
    lcars_base_report
    return 0
  fi

  # 8 — would the fast-forward EAT something? `git status` reads clean with a
  #     gitignored build artifact sitting in the tree, and a pull the captain did
  #     not type would overwrite it without a word. A pull LCARS chose is held to
  #     a higher bar than one the captain typed: refuse, name the files, and let
  #     them decide.
  clob="$(_lcars_base_clobber_paths "$local_sha" "$remote_sha")"
  if [ -n "$clob" ]; then
    _lcars_base_set stale 1 \
      "'$base' is $behind commit(s) behind origin, but fast-forwarding it would OVERWRITE local file(s) git is not tracking, whose content differs from the incoming one — so nothing was moved and your file(s) are intact: $(_lcars_base_render_paths "$clob")" \
      "move or delete those file(s), then   git pull --ff-only origin $base"
    lcars_base_report
    return 0
  fi

  # 9 — the move itself: a purely LOCAL fast-forward onto the sha we ALREADY
  #     fetched. No network, and — deliberately — no bound. The only way this
  #     guard could ever leave a half-written tree was a timeout landing
  #     mid-checkout, and there is now nothing to time out.
  frc=0
  mergeout="$("$g" merge --ff-only "$remote_sha" 2>&1)" || frc=$?
  if [ "$frc" -eq 0 ]; then
    _lcars_base_set updated 0 "fast-forwarded '$base' $behind commit(s) from origin."
  else
    how="$(printf '%s' "$mergeout" | head -1)"
    [ -n "$how" ] || how="git gave no reason"
    _lcars_base_set stale 1 \
      "'$base' is $behind commit(s) behind origin and the LOCAL fast-forward onto the already-fetched origin/$base failed ($how) — the ref was not moved and your tree was not written to." \
      "git merge --ff-only origin/$base   (local only — origin has already been fetched)"
  fi
  lcars_base_report
  return 0
}
# ---------------------------------------------------------------------------
# MERGE-PRESERVING CONFIG WRITE
# ---------------------------------------------------------------------------
# config.json is written by MERGE, never by clobber: existing values for keys
# already present are preserved untouched; only MISSING keys are filled in with
# the supplied defaults. This makes re-running init (and running update)
# idempotent — a captain's customized testCommand / model / comprehensionBudget
# survives. Both init and update call this so the behaviour cannot drift.

# lcars_json_escape — escape a string for embedding inside a JSON string literal.
# Backslashes are escaped FIRST, then double-quotes (the standard order — mirrors
# json_escape in skills/lcars-run/run.sh), then awk escapes every control char
# (newline/tab/CR → \n \t \r, the rest \u00XX) so ANY value yields VALID JSON.
# The result is safe to wrap in quotes. jq-free.
lcars_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"   # backslashes first…
  s="${s//\"/\\\"}"   # …then double-quotes
  printf '%s' "$s" | awk '
    BEGIN { RS="\034"; ORS=""; MAP=""; for (k=1;k<32;k++) MAP=MAP sprintf("%c",k) }
    { n=length($0); for (i=1;i<=n;i++){ c=substr($0,i,1)
        if (c=="\n") printf "\\n"; else if (c=="\t") printf "\\t"
        else if (c=="\r") printf "\\r"
        else { b=index(MAP,c); if (b>0) printf "\\u%04x",b; else printf "%s",c } } }'
}

# lcars_config_has_key — 0 if the config file has a top-level "key": present.
lcars_config_has_key() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 1
  grep -q "\"$key\"[[:space:]]*:" "$config"
}

# lcars_config_get — print the JSON value of a top-level string key, with the
# standard JSON escapes un-escaped (\" → ", \\ → \). Mirrors json_str in
# skills/lcars-run/run.sh so both jq-free readers agree on a value written with
# embedded quotes (e.g. a testCommand referencing "${LCARS_TESTS_DIR:-tests}").
# Empty if absent.
lcars_config_get() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 0
  sed -En "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$config" \
    | head -1 \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}

# lcars_config_set_string — overwrite the JSON value of ONE top-level key with a
# (JSON-escaped) string, preserving every other line, key order, and the file's
# trailing-comma structure. jq-free, line-oriented (relies on the one-key-per-line
# layout lcars_config_merge writes). Unlike lcars_config_merge this DELIBERATELY
# replaces an existing value — use it only for targeted, fingerprinted migrations.
lcars_config_set_string() {
  local config="$1" key="$2" value="$3"
  [ -f "$config" ] || return 1
  local esc; esc="$(lcars_json_escape "$value")"
  local tmp="$config.tmp.$$"
  local line indent comma
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"\"$key\""*:*)
        comma=""; case "$line" in *,) comma="," ;; esac
        indent="${line%%\"*}"
        printf '%s"%s": "%s"%s\n' "$indent" "$key" "$esc" "$comma"
        ;;
      *)
        printf '%s\n' "$line"
        ;;
    esac
  done <"$config" >"$tmp"
  mv "$tmp" "$config"
}

# lcars_config_merge — write config.json preserving existing keys.
#
# Args:
#   $1  path to config.json (may not yet exist)
#   $2  newline-separated "key=jsonvalue" desired pairs, in the canonical key
#       order. Each jsonvalue is already JSON-formatted (quoted string, number,
#       null) by the caller.
#
# For each desired key: if the existing config already has it, the EXISTING raw
# JSON value is preserved; otherwise the supplied default jsonvalue is written.
# Keys present in the file but not in the desired list are dropped (the desired
# list is the canonical schema) — but every current key IS in the schema, so in
# practice nothing the captain set is lost.
#
# Sets for the caller to report on:
#   LCARS_CONFIG_ADDED_KEYS    space-separated keys newly added this write
#   LCARS_CONFIG_PRESENT_KEYS  space-separated keys preserved from existing
lcars_config_merge() {
  local config="$1" desired="$2"
  LCARS_CONFIG_ADDED_KEYS=""
  LCARS_CONFIG_PRESENT_KEYS=""

  local existing=""
  [ -f "$config" ] && existing="$(cat "$config")"

  local body="" key default rawval
  while IFS='=' read -r key default; do
    [ -n "$key" ] || continue
    if [ -n "$existing" ] && printf '%s' "$existing" | grep -q "\"$key\"[[:space:]]*:"; then
      # Preserve the existing raw value verbatim (string, number, or null).
      rawval="$(printf '%s' "$existing" \
        | sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\(.*\)/\1/p" | head -1)"
      # Strip a trailing comma and surrounding whitespace from the captured tail.
      rawval="${rawval%,}"
      rawval="$(printf '%s' "$rawval" | sed 's/[[:space:]]*$//')"
      LCARS_CONFIG_PRESENT_KEYS="${LCARS_CONFIG_PRESENT_KEYS:+$LCARS_CONFIG_PRESENT_KEYS }$key"
    else
      rawval="$default"
      LCARS_CONFIG_ADDED_KEYS="${LCARS_CONFIG_ADDED_KEYS:+$LCARS_CONFIG_ADDED_KEYS }$key"
    fi
    body="${body:+$body,$'\n'}  \"$key\": $rawval"
  done <<EOF
$desired
EOF

  printf '{\n%s\n}\n' "$body" >"$config"
}

# ---------------------------------------------------------------------------
# WORKTREE PROVISIONING DEFAULT (ecosystem detection)
# ---------------------------------------------------------------------------
# `lcars run` provisions each Stage's isolated git worktree by running the
# config's `worktreeSetupCommand` ONCE with the worktree as CWD (via `bash -c`).
# A fresh worktree shares the object store but NOT the main checkout's
# uncommitted/gitignored installed deps (node_modules, venv), so a Stage that
# needs the test runner installed would otherwise break. This emits a sensible
# per-ecosystem default that REUSES what the main checkout already has —
# symlinking its node_modules (root + each pnpm-workspace package) into the
# worktree, falling back to an OFFLINE, lockfile-frozen install when the main
# checkout has none. No network, no special cache.
#
# Shared by BOTH `lcars init` (seed on first setup) and `lcars update` (backfill
# the key into an older config) so the default can never drift between them.
# Reads $TOPLEVEL (the repo root) from the caller's environment, exactly like
# init's detect_test_cmd.
#
# IMPORTANT: the emitted string is a SINGLE shell command whose `$MAIN` / `$(…)`
# must be evaluated AT PROVISION TIME in the worktree — NOT now. It is therefore
# emitted as a single-quoted literal (no expansion here); the caller stores it
# via lcars_json_escape (valid JSON) and the runtime `bash -c` expands it. Empty
# when LCARS can't infer a safe default (Python/Rust/Go/Make/bash/none) — the
# provisioner then warns and skips rather than running a command that errors.
detect_worktree_setup_cmd() {
  # JS/TS: symlink the main checkout's node_modules (root + every pnpm workspace
  # package's own, which nests its .bin), else an offline lockfile-frozen install.
  if [ -f "$TOPLEVEL/package.json" ]; then
    local install lock
    if [ -f "$TOPLEVEL/pnpm-lock.yaml" ] || [ -f "$TOPLEVEL/pnpm-workspace.yaml" ]; then
      install='pnpm install --frozen-lockfile --prefer-offline --silent'
      lock='pnpm-lock.yaml'
    elif [ -f "$TOPLEVEL/yarn.lock" ]; then
      install='yarn install --immutable'
      lock='yarn.lock'
    else
      install='npm ci'
      lock='package-lock.json'
    fi
    # THE LOCKFILE GUARD comes first: reusing the main checkout's node_modules is
    # only correct while this worktree wants the SAME dependencies. A ticket that
    # changes the lockfile makes the shared install the WRONG set by definition,
    # and symlinking it would test the ticket against packages its own commit
    # replaced — a failure no committed change could ever repair, which then reads
    # downstream as "the implementation is not present". Diverged ⇒ real install.
    #
    # find symlinks EVERY node_modules that is not nested inside another one
    # (-prune halts the descent at each match), recreating its path relative to
    # the main checkout inside the worktree. Generic across npm/yarn/pnpm.
    printf '%s\n' 'MAIN="$(git rev-parse --path-format=absolute --git-common-dir)"; MAIN="${MAIN%/.git}"; if [ -d "$MAIN/node_modules" ] && [ -f '"$lock"' ] && [ -f "$MAIN/'"$lock"'" ] && ! cmp -s '"$lock"' "$MAIN/'"$lock"'"; then '"$install"'; elif [ -d "$MAIN/node_modules" ]; then find "$MAIN" -path "$MAIN/.git" -prune -o -name node_modules -type d -prune -print | while IFS= read -r nm; do rel="${nm#$MAIN/}"; mkdir -p "$(dirname "$rel")"; ln -snf "$nm" "$rel"; done; else '"$install"'; fi'
    return
  fi
  # Python and everything else: no single offline-safe string we can guarantee —
  # emit empty and let the provisioner warn (never emit a command that errors).
  echo ""
}

# ---------------------------------------------------------------------------
# TEST-COMMAND DETECTION (S146: moved here from init.sh so the readiness
# verdict below — shared by init, update, status AND the viewscreen daemon —
# can consult the SAME detector. Byte-identical logic; init.sh still calls it.)
# ---------------------------------------------------------------------------
# The Implement red gate (BUG-007) runs testCommand to prove the fail-first
# suite FAILS before the Implementer runs — scoped to $LCARS_TESTS_DIR. We emit
# a $LCARS_TESTS_DIR-honouring default per ecosystem. Reads $TOPLEVEL from the
# caller's environment. Empty when nothing can be detected.
# The vitest test command must RELATIVIZE $LCARS_TESTS_DIR to the runner's cwd
# (vitest's positional filter is package-root-relative; the gate exports an
# ABSOLUTE path) — stripping a leading "$PWD/" turns it package-relative.
VITEST_RELATIVIZING_CMD='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
#
# S148 — QUOTE THE SCOPE. Every seeded command interpolates $LCARS_TESTS_DIR as
# the positional scope, and the gate exports it as an ABSOLUTE path. Interpolated
# UNQUOTED, that path WORD-SPLITS on IFS whitespace the moment the repo is checked
# out somewhere containing a space or a tab: `node --test ${LCARS_TESTS_DIR:-}`
# with a scope of `/x/sp test/src/calc.test.js` hands the runner TWO arguments,
# `/x/sp` and `test/src/calc.test.js`, and the flip-flop proof gate then FALSE-
# FAILS a perfectly honest ticket purely because of WHERE the repo lives (which
# bounces it to a fresh worker up to 3 times and then parks it awaiting-human).
#
# The two quoting shapes below are NOT interchangeable, and which one an arm takes
# is decided by its DEFAULT, not by taste:
#   `"${LCARS_TESTS_DIR:-<default>}"`   when the default is NON-EMPTY (pytest's
#       `.`, the bash runner's `tests`) — always exactly one argument either way.
#   `${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}`  when the default is EMPTY. Writing
#       `"${LCARS_TESTS_DIR:-}"` here would quote it but ALSO hand the runner an
#       EMPTY positional argument when the scope is unset — a different run (mocha
#       errors on it, npm forwards it to the script), i.e. a behaviour change
#       smuggled in under a quoting fix. `:+` keeps "no scope ⇒ no argument"
#       byte-for-byte and is the idiom VITEST_RELATIVIZING_CMD above already uses.
# Every seeded command is otherwise unchanged; the only delta is the quoting.
# `lcars update` migrates the already-persisted unquoted strings (update.sh).

# detect_workspace_runner — name the local test runner a monorepo actually uses,
# so the workspace fallback emits a runner-SCOPED command instead of a bare
# `npm test` fan-out. Inspects (in order) a runner config at the workspace root,
# the pnpm lockfile, then every sub-package's package.json devDependencies.
# Echoes vitest|jest|mocha (empty when none found).
detect_workspace_runner() {
  local r
  for r in vitest jest mocha; do
    ls "$TOPLEVEL/$r.config".* >/dev/null 2>&1 && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -qs -- "$r" "$TOPLEVEL/pnpm-lock.yaml" 2>/dev/null && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -rqs --include='package.json' --exclude-dir='node_modules' -- "\"$r\"" "$TOPLEVEL" 2>/dev/null \
      && { echo "$r"; return; }
  done
  echo ""
}

# detect_dotnet_test_projects (S147) — echo every TEST project in the repo, one
# $TOPLEVEL-relative *.csproj path per line (LC_ALL=C sorted, so the "exactly
# one" decision is deterministic). A project counts as a TEST project when it
# either references `Microsoft.NET.Test.Sdk` (the real signal — every xunit /
# nunit / mstest template adds it) OR carries the `*Tests*.csproj` naming
# convention (a hand-rolled project that inherits the ref from Directory.Build
# .props still reads as a test project). `bin/` and `obj/` are EXCLUDED: a build
# leaves copies of the csproj under obj/, and counting those would make every
# already-built repo look "ambiguous". Reads $TOPLEVEL like its siblings.
detect_dotnet_test_projects() {
  find "$TOPLEVEL" -type d \( -name bin -o -name obj -o -name .git \) -prune -o \
       -type f -name '*.csproj' -print 2>/dev/null \
  | LC_ALL=C sort \
  | while IFS= read -r p; do
      [ -n "$p" ] || continue
      dotnet_csproj_is_test "$p" && printf '%s\n' "${p#"$TOPLEVEL/"}"
    done
}

# dotnet_csproj_is_test — is this *.csproj a TEST project? It either references
# `Microsoft.NET.Test.Sdk` (the real signal — every xunit / nunit / mstest
# template adds it) or carries the `*Tests*.csproj` naming convention (a
# hand-rolled project inheriting the ref from Directory.Build.props still reads
# as a test project). The ONE predicate both the marker probe and the seed
# enumeration use, so they can never disagree about what a test system is.
# The Test.Sdk match is CASE-INSENSITIVE: NuGet package ids are, so a hand-
# written `microsoft.net.test.sdk` reference is a perfectly valid test project
# and used to fall through to the greenfield "no test systems found" voice.
dotnet_csproj_is_test() { # abs csproj path
  case "${1##*/}" in *Tests*.csproj) return 0 ;; esac
  grep -qi 'Microsoft\.NET\.Test\.Sdk' "$1" 2>/dev/null
}

# detect_dotnet_markers (S147) — does this repo look like a .NET repo at all?
# 0 = yes. TWO rules, deliberately different in strength:
#
#   TOP LEVEL — any *.csproj / *.sln / *.slnx counts, whatever it contains.
#     This is the pre-147 rule, kept BYTE-IDENTICAL: a repo whose root is a C#
#     project is a C# repo, full stop.
#
#   BELOW IT — a bounded scan that counts a project ONLY when it is an actual
#     TEST SYSTEM. The recursion exists for one reason: the single most common
#     C# layout on earth, `dotnet new xunit -o MyApp.Tests`, puts the only
#     project ONE DIRECTORY DOWN and writes no root solution, so a top-level-only
#     glob read it as stack:unknown and told the captain the repo was greenfield.
#     Counting *any* nested csproj overshot badly: a vendored C# sample or a
#     `tools/` helper flipped a healthy js/python/rust repo to `ambiguous` and
#     REMOVED its working seed — and the verdict contradicted itself, offering
#     one candidate while insisting it would not choose between them. A bare
#     .csproj with no test SDK reference is not a test system, so it is not a
#     signal; a nested *Tests* project still is. Nested solutions do not count
#     at all (a .sln says nothing about tests).
#
# Bounded and cheap: `$DOTNET_MARKER_MAXDEPTH`, `bin`/`obj`/`.git`/`node_modules`
# pruned (a build leaves csproj copies under obj/), stops at the first hit.
#
# WHERE EACH SCAN LOOKS, stated once, because the two scans deliberately differ:
#   • THIS probe is bounded, because it runs on EVERY repo — including every
#     js/python/rust one that will never be .NET — on every detection and every
#     board render. It is a hot path and must stay cheap.
#   • detect_dotnet_test_projects is EXHAUSTIVE (no maxdepth), because it runs
#     only once a repo is already known to be .NET, and a solution may legitimately
#     nest its test projects deeper than this bound. Bounding it too would make a
#     repo detect as dotnet and then seed nothing, which is strictly worse.
# The two agree on WHAT a test system is (dotnet_csproj_is_test, the single
# predicate); they differ on WHERE only, for the reason above.
#
# LEDGERED (recorded, not fixed): a test project deeper than the bound, in a repo
# with no top-level marker, still reads as greenfield — the surface asserts
# absence ("no test systems found") rather than admitting it only looked
# `$DOTNET_MARKER_MAXDEPTH` levels down. Raising the bound trades that for a
# slower scan on every board render; revisit with a real repo that needs it.
#
# KEEP IN STEP with `_DETECT_MARKER_GLOBS`/`_DETECT_MARKER_RGLOBS` in
# web/lcars_serve/local_adapter.py — the board's memo must move when these do,
# or CLI and board drift apart (the S146 D2 contract).
DOTNET_MARKER_MAXDEPTH=3
detect_dotnet_markers() {
  local f p
  for f in "$TOPLEVEL"/*.csproj "$TOPLEVEL"/*.sln "$TOPLEVEL"/*.slnx; do
    [ -e "$f" ] && return 0
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    dotnet_csproj_is_test "$p" && return 0
  done <<DN_MARK
$(find "$TOPLEVEL" -maxdepth "$DOTNET_MARKER_MAXDEPTH" \
    -type d \( -name bin -o -name obj -o -name .git -o -name node_modules \) -prune -o \
    -type f -name '*.csproj' -print 2>/dev/null)
DN_MARK
  return 1
}

# ---------------------------------------------------------------------------
# The per-stack seed ARMS (S147). detect_test_cmd used to be one long if-chain;
# each ecosystem's rule now lives in its own `_dtc_<stack>` helper and the chain
# just walks them IN THE SAME ORDER, so behaviour is unchanged for every stack.
# The split exists so ONE stack's rule can be asked in isolation
# (detect_test_cmd_for_stack) — which is how an AMBIGUOUS repo can offer the
# captain a real command per candidate instead of hiring a discovery worker.
#
# CONTRACT: an arm returns 0 when it CLAIMS the repo (stdout = the command,
# possibly EMPTY when that stack is internally ambiguous and must not be
# guessed) and 1 when it does not apply, letting the chain continue. That
# distinction is what lets dotnet-with-no-test-project fall THROUGH to the
# generic Makefile / tests/run.sh fallbacks it always used to reach.
# ---------------------------------------------------------------------------
_dtc_js() {
  [ -f "$TOPLEVEL/package.json" ] && grep -q '"test"[[:space:]]*:' "$TOPLEVEL/package.json" || return 1
    # Monorepo (a pnpm workspace, or a "workspaces" field): a bare `npm test` /
    # `pnpm -r test` here FANS OUT across every package, so the red gate can never
    # scope itself to the touched package's quarantined tests. Prefer a command
    # scoped to the local runner that STILL honours $LCARS_TESTS_DIR — LCARS points
    # the var at the touched package (it knows it from the plan/manifests). When the
    # root "test" script doesn't name the runner, DETECT it from the sub-packages
    # (lockfile / config / devDependencies) rather than emitting a fan-out.
    if [ -f "$TOPLEVEL/pnpm-workspace.yaml" ] || grep -q '"workspaces"[[:space:]]*:' "$TOPLEVEL/package.json"; then
      local script runner
      script="$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)"
      case "$script" in
        *vitest*) echo "$VITEST_RELATIVIZING_CMD";              return ;;
        *jest*)   echo 'npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';         return ;;
        *mocha*)  echo 'npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';        return ;;
        *)
          runner="$(detect_workspace_runner)"
          case "$runner" in
            vitest) echo "$VITEST_RELATIVIZING_CMD";            return ;;
            jest)   echo 'npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';       return ;;
            mocha)  echo 'npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';      return ;;
            *)      echo 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}';    return ;;
          esac ;;
      esac
    fi
    # Single package: a vitest runner needs the RELATIVIZING positional (same abs-
    # path bug as the monorepo); jest/mocha/other keep the `npm test --` positional
    # default (empty runs the suite).
    case "$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)" in
      *vitest*) echo "$VITEST_RELATIVIZING_CMD"; return ;;
    esac
    echo 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'; return 0
}

_dtc_python() {
  [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/pytest.ini" ] || [ -f "$TOPLEVEL/tox.ini" ] || return 1
  echo 'pytest "${LCARS_TESTS_DIR:-.}"'
}

_dtc_rust() { [ -f "$TOPLEVEL/Cargo.toml" ] || return 1; echo "cargo test"; }
_dtc_go()   { [ -f "$TOPLEVEL/go.mod" ]     || return 1; echo "go test ./..."; }

# dotnet/C# (S147): `dotnet test` is project-oriented, not directory-oriented —
# it wants the TEST PROJECT, so the seed names it explicitly (a bare `dotnet
# test` from the root either finds nothing or fans out across the solution).
# Exactly ONE test project seeds; SEVERAL is internally AMBIGUOUS — emit NO
# command (the caller warns, naming them all, per the S105 idiom) rather than
# pick one by sort order.
#
# The arm CLAIMS the repo only when a dotnet TEST PROJECT was actually found.
# Claiming on the mere presence of a marker was a regression: a repo with
# `App.csproj` plus a Makefile `test:` target seeded `make test` before S147 and
# suddenly seeded nothing — S147 is supposed to ADD dotnet's missing legs, never
# to take an existing arm's answer away. With no test project it returns 1 and
# the chain falls through to the pre-existing fallbacks exactly as it always did.
_dtc_dotnet() {
  detect_dotnet_markers || return 1
  local dn_projs dn_n
  dn_projs="$(detect_dotnet_test_projects | grep . || :)"
  # NB: `grep -c` exits 1 on a zero count, hence the `|| :` and the numeric guard.
  dn_n="$(printf '%s' "$dn_projs" | grep -c . || :)"
  case "$dn_n" in ''|*[!0-9]*) dn_n=0 ;; esac
  [ "$dn_n" -ge 1 ] || return 1
  [ "$dn_n" -eq 1 ] && { echo "dotnet test $dn_projs"; return 0; }
  echo ""   # several → claimed, but deliberately no command
}

# Ruby (S145): pick the runner from the layout. rspec when the Gemfile names it
# or a spec/ dir exists; minitest via `rake test` when a test/ dir + Rakefile are
# present. A Gemfile prefixes `bundle exec`. When BOTH an rspec (spec/) and a
# minitest (test/ + Rakefile) layout are present WITHOUT a decisive Gemfile rspec
# signal, the runner is internally AMBIGUOUS: emit NO command (the caller warns,
# naming both) rather than guess. A gem library with only a *.gemspec/Rakefile and
# no spec//test/ also emits nothing. Reached only for a single-stack ruby repo.
_dtc_ruby() {
  [ -f "$TOPLEVEL/Gemfile" ] || [ -f "$TOPLEVEL/Rakefile" ] || [ -f "$TOPLEVEL/config.ru" ] \
    || [ -d "$TOPLEVEL/spec" ] || ls "$TOPLEVEL"/*.gemspec >/dev/null 2>&1 || return 1
  local rb_prefix="" rb_rspec=0 rb_mini=0 rb_gem_rspec=0
  [ -f "$TOPLEVEL/Gemfile" ] && rb_prefix="bundle exec "
  { [ -f "$TOPLEVEL/Gemfile" ] && grep -q 'rspec' "$TOPLEVEL/Gemfile"; } && rb_gem_rspec=1
  { [ "$rb_gem_rspec" = 1 ] || [ -d "$TOPLEVEL/spec" ]; } && rb_rspec=1
  { [ -d "$TOPLEVEL/test" ] && [ -f "$TOPLEVEL/Rakefile" ]; } && rb_mini=1
  # A Gemfile explicitly naming rspec is decisive even if a test/ dir also exists.
  [ "$rb_gem_rspec" = 1 ] && rb_mini=0
  if [ "$rb_rspec" = 1 ] && [ "$rb_mini" = 1 ]; then echo ""; return 0; fi
  if [ "$rb_rspec" = 1 ]; then echo "${rb_prefix}rspec"; return 0; fi
  if [ "$rb_mini" = 1 ];  then echo "${rb_prefix}rake test"; return 0; fi
  echo ""
}

# The generic runners, checked LAST so a real ecosystem always wins. A bash test
# runner (LCARS dogfoods its own tests/run.sh) already resolves a positional dir
# / $LCARS_TESTS_DIR (BUG-009), so scope it to the quarantined tests when the var
# is set, else the whole `tests` dir for a human.
_dtc_generic() {
  if [ -f "$TOPLEVEL/Makefile" ] && grep -q '^test:' "$TOPLEVEL/Makefile"; then
    echo "make test"; return 0; fi
  if [ -f "$TOPLEVEL/tests/run.sh" ]; then
    echo 'bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'; return 0; fi
  return 1
}

# The arm ORDER — the pre-147 if-chain order, preserved exactly.
DETECT_TEST_CMD_ARMS="js python rust go dotnet ruby generic"

detect_test_cmd() {
  local arm out
  for arm in $DETECT_TEST_CMD_ARMS; do
    if out="$("_dtc_$arm")"; then printf '%s\n' "$out"; return 0; fi
  done
  echo ""
}

# detect_test_cmd_for_stack <stack> — ONE stack's seed rule, asked in isolation.
# Used to offer a real command per candidate on an AMBIGUOUS repo, so choosing
# never costs a discovery worker. Empty when that stack has no rule here or
# cannot pin a runner.
detect_test_cmd_for_stack() {
  case " $DETECT_TEST_CMD_ARMS " in
    *" $1 "*) "_dtc_$1" 2>/dev/null || printf '' ;;
    *)        printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# STACK DETECTION (S105 — multi-stack breadth)
# ---------------------------------------------------------------------------
# detect_stack — inspect the repo's TOP LEVEL for language/build markers and echo
# ONE stack id. The id is the classifier key the S104 `lcars run` arms are keyed
# by (rust/go/python/js/dotnet/jvm), so seeding it into config.json lets every
# downstream stage know the mission's ecosystem without re-sniffing.
#
# Marker → id:
#   Cargo.toml                                   → rust
#   go.mod                                       → go
#   pyproject.toml / setup.py                    → python
#   package.json                                 → js
#   *.csproj / *.sln                             → dotnet
#   pom.xml / build.gradle / build.gradle.kts    → jvm
#   Gemfile / *.gemspec / Rakefile / config.ru   → ruby
#
# Several DISTINCT stacks present   → ambiguous(<comma-list, in detection order>)
# NONE present                      → unknown
#
# Reads $TOPLEVEL (the repo root) from the caller's environment, exactly like
# detect_worktree_setup_cmd / init's detect_test_cmd. POSIX/bash-3.2 portable and
# nullglob-safe: glob markers (*.csproj, build.gradle*) are probed with a
# `for f in …; do [ -e "$f" ]` guard so an UNMATCHED glob (which stays a literal
# under bash-3.2) can never false-positive. Shared by BOTH `lcars init` and
# `lcars update` so the two can never disagree on a repo's stack.
detect_stack() {
  local candidates="" f matched

  [ -f "$TOPLEVEL/Cargo.toml" ] && candidates="$candidates rust"
  [ -f "$TOPLEVEL/go.mod" ]     && candidates="$candidates go"
  { [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/setup.py" ]; } \
    && candidates="$candidates python"
  [ -f "$TOPLEVEL/package.json" ] && candidates="$candidates js"

  # dotnet — any *.csproj, *.sln or *.slnx, at the top level or within the
  # bounded marker depth (detect_dotnet_markers). S147: `.slnx` is the XML
  # solution format .NET 10's `dotnet new sln` now emits by default, and the
  # canonical `dotnet new xunit -o MyApp.Tests` layout keeps its only project one
  # directory down with no root solution at all — both OBSERVED in-session with
  # SDK 10.0.107, and both read as `unknown` under a top-level-only glob. Purely
  # ADDITIVE: every path that matched before still matches.
  detect_dotnet_markers && candidates="$candidates dotnet"

  # jvm — Maven (pom.xml) or Gradle (build.gradle / build.gradle.kts).
  matched=0
  for f in "$TOPLEVEL"/pom.xml "$TOPLEVEL"/build.gradle "$TOPLEVEL"/build.gradle.kts; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates jvm"

  # ruby (S145) — Gemfile / *.gemspec / Rakefile / config.ru (nullglob-safe probe;
  # an unmatched *.gemspec glob stays literal under bash-3.2, so the -e guard keeps
  # it from false-positiving). A spec/ or test/ dir is runner evidence (seed side),
  # never a stack marker on its own.
  matched=0
  for f in "$TOPLEVEL"/Gemfile "$TOPLEVEL"/*.gemspec "$TOPLEVEL"/Rakefile "$TOPLEVEL"/config.ru; do
    [ -e "$f" ] && { matched=1; break; }
  done
  [ "$matched" -eq 1 ] && candidates="$candidates ruby"

  # Strip the leading space and split on whitespace to count distinct stacks.
  # shellcheck disable=SC2086
  set -- $candidates
  case $# in
    0) echo "unknown" ;;
    1) echo "$1" ;;
    *) echo "ambiguous($(echo "$candidates" | sed 's/^ *//; s/ /,/g'))" ;;
  esac
}

# ---------------------------------------------------------------------------
# TEST PROBE — the ONE live run (shared by `lcars update` and `lcars init`)
# ---------------------------------------------------------------------------
# lcars_test_readiness (below) is CHEAP: it never runs anything, so "ready"
# means the COMMAND resolves, not that the SUITE works. This is the other half
# — an actual bounded run — for the one-off callers that can afford it.

# run_probe <cmd> — run the test command ONCE from the repo root, BOUNDED by
# $LCARS_PROBE_TIMEOUT (default 120s; perl's alarm survives exec, so the timer
# rides into the spawned bash). Sets PROBE_OUTCOME (pass|fail|zero-collected|
# timeout), PROBE_RC, and PROBE_OUT (captured-output file). Zero-collected is
# its OWN honest outcome, never a pass — the signature REUSES the rg_signature
# `zerotests` + proof_zero_collected phrasings from skills/lcars-run/run.sh
# (keep the two in step).
PROBE_TIMEOUT="${LCARS_PROBE_TIMEOUT:-120}"
run_probe() {
  local cmd="$1"
  PROBE_OUT="$(mktemp "${TMPDIR:-/tmp}/lcars-probe.XXXXXX")"
  ( cd "$TOPLEVEL" && perl -e 'alarm shift; exec @ARGV or exit 127' \
      "$PROBE_TIMEOUT" bash -c "$cmd" ) >"$PROBE_OUT" 2>&1
  PROBE_RC=$?
  # S147: THREE VSTest phrasings, all exiting 0 (observed, SDK 10.0.107) — a
  # filter that matches nothing, a test project with no test methods, and a run
  # whose every discovered case was SKIPPED (`[Fact(Skip=…)]`), which prints
  # neither "no test" phrase and used to read here as "the suite ran and passed".
  # They are the dotnet green-on-nothing trap, so the probe names them too; the
  # skipped form keys on the NUMBERS (zero failed AND zero passed) so a real
  # 1-passed/1-skipped run stays a pass. Keep in step with rg_signature
  # `zerotests` + proof_zero_collected in skills/lcars-run/run.sh.
  local zero='No test files found|No test suite found in|No tests found|no tests ran|Ran 0 tests|collected 0 items|(^|[^0-9])0 examples, 0 failures$|(^|[^0-9])0 runs, 0 assertions|no tests to run|test result: ok\. 0 passed|^No test matches the given testcase filter .*\.dll|^No test is available in .*\.dll|^(Passed|Failed|Skipped)! +- +Failed: +0, +Passed: +0,'
  # S147: MSBuild never even REACHED a test run — the project/solution the
  # command names is not there. Reporting that as "the suite ran but reported
  # failures" sends the captain hunting a test failure that does not exist.
  local cantrun='^MSBUILD : error MSB100[39]:'
  if [ "$PROBE_RC" -eq 142 ]; then          # 128 + SIGALRM(14): the alarm fired
    PROBE_OUTCOME="timeout"
  elif grep -Eq "$cantrun" "$PROBE_OUT"; then
    PROBE_OUTCOME="cannot-run"
  elif grep -Eq "$zero" "$PROBE_OUT"; then  # runner finished but ran NOTHING
    PROBE_OUTCOME="zero-collected"
  elif [ "$PROBE_RC" -eq 0 ]; then
    PROBE_OUTCOME="pass"
  else
    PROBE_OUTCOME="fail"
  fi
}

# report_probe — the ship-status readout for the last run_probe.
report_probe() {
  case "$PROBE_OUTCOME" in
    pass)
      echo "  ✓ PROBE COMPLETE — test systems responding: the suite ran and passed." ;;
    fail)
      echo "  ✗ PROBE FAILED — the suite ran but reported failures (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    zero-collected)
      echo "  ⚠ PROBE INCONCLUSIVE — the runner started but collected ZERO tests."
      echo "    That is not a pass: the command may be scoped to the wrong place." ;;
    cannot-run)
      echo "  ⚠ PROBE COULD NOT RUN — the command never reached a test run: the"
      echo "    project or solution it names could not be loaded (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    timeout)
      echo "  ⚠ PROBE TIMED OUT — no verdict within ${PROBE_TIMEOUT}s; the suite never settled." ;;
  esac
}

# ---------------------------------------------------------------------------
# TEST READINESS — the ONE verdict (S146)
# ---------------------------------------------------------------------------
# lcars_test_readiness — compute the repo's test-readiness verdict, CHEAP by
# construction: no test run, no network, no worker. The four states:
#
#   ready    testCommand set AND its first token resolves via `command -v`
#   missing  testCommand null/absent, detection has a candidate (suggestion)
#   broken   testCommand set but its first token does NOT resolve
#   unknown  testCommand null/absent AND no candidate, with NO stack detected —
#            the greenfield state: EXPECTED, not an alarm.
#   ambiguous  (S147) testCommand null/absent because SEVERAL test systems are
#            present and LCARS refuses to guess. NOT greenfield: this repo HAS
#            test systems, LCARS just cannot pick one — it needs the captain to
#            choose. Given its own voice so the bootstrap ("the crew will
#            establish them") and repair voices never blur on a repo that
#            already has real test infrastructure. TWO shapes reach it:
#              • several STACKS (rust + js …), and
#              • one stack that cannot pin its runner because it has several
#                candidates — today a dotnet repo with two test projects, which
#                warned and NAMED both projects and then declared the repo
#                greenfield on the very next line.
#
# Shared by `lcars init`/`lcars update`/`lcars status` (they source this file)
# and by the viewscreen daemon (via skills/lcars-init/readiness.sh), so CLI and
# board can never disagree. It NEVER writes anything — the sanctioned writers
# are `lcars update --test-command|--fix-tests` alone.
#
# Args: $1 = path to config.json. Reads $TOPLEVEL (repo root) for detection and
# for resolving a relative runner path. Sets, for the caller:
#   LCARS_TESTREADY_STATUS      ready|missing|broken|unknown|ambiguous
#   LCARS_TESTREADY_TESTCMD     the stored testCommand ("" when null/absent)
#   LCARS_TESTREADY_SUGGESTION  the detected candidate ("" unless status=missing)
#   LCARS_TESTREADY_STACKS      the ambiguity's candidate LABELS, comma-separated
#                               — stack ids for a multi-stack repo, test-project
#                               paths for one stack that cannot pin its runner
#                               ("" unless status=ambiguous)
#   LCARS_TESTREADY_CANDIDATES  one candidate COMMAND per line, so the captain
#                               can PICK instead of hiring a discovery worker
#                               ("" unless status=ambiguous)
lcars_test_readiness() {
  local config="$1"
  LCARS_TESTREADY_STATUS=""
  LCARS_TESTREADY_TESTCMD=""
  LCARS_TESTREADY_SUGGESTION=""
  LCARS_TESTREADY_STACKS=""
  LCARS_TESTREADY_CANDIDATES=""

  local tc=""
  [ -f "$config" ] && tc="$(lcars_config_get "$config" testCommand)"

  if [ -n "$tc" ]; then
    LCARS_TESTREADY_TESTCMD="$tc"
    # First token of the command (no glob expansion — `read` splits safely).
    local first rest
    read -r first rest <<EOF2
$tc
EOF2
    # Resolve from the repo root so a relative runner (node_modules/.bin/…)
    # resolves the way the gate would run it.
    if ( cd "${TOPLEVEL:-.}" 2>/dev/null && command -v "$first" >/dev/null 2>&1 ); then
      LCARS_TESTREADY_STATUS="ready"
    else
      LCARS_TESTREADY_STATUS="broken"
    fi
    return 0
  fi

  # No command stored: does detection have a candidate? Mirror init's seeding
  # rule EXACTLY (S105): only an AMBIGUOUS multi-stack repo refuses to guess;
  # an unknown stack still consults detect_test_cmd (Makefile / tests/run.sh
  # repos have a perfectly detectable runner without a stack id).
  local stack cand="" s
  stack="$(detect_stack)"
  case "$stack" in
    # S147: an AMBIGUOUS repo is its OWN state, not greenfield. It has test
    # systems — several — and LCARS refuses to guess between them; calling that
    # "no test systems found" (and promising the first mission's crew would
    # establish them) was a lie on a repo that already has real infrastructure.
    ambiguous*)
      LCARS_TESTREADY_STATUS="ambiguous"
      LCARS_TESTREADY_STACKS="${stack#ambiguous(}"
      LCARS_TESTREADY_STACKS="${LCARS_TESTREADY_STACKS%)}"
      # A real command per candidate stack, so `--fix-tests` can offer a PICK
      # instead of hiring a paid discovery crew to choose (which is exactly what
      # the "LCARS will not choose for you" line promised it would not do).
      for s in $(printf '%s' "$LCARS_TESTREADY_STACKS" | tr ',' ' '); do
        cand="$(detect_test_cmd_for_stack "$s")"
        [ -n "$cand" ] && LCARS_TESTREADY_CANDIDATES="${LCARS_TESTREADY_CANDIDATES}${cand}
"
      done
      return 0 ;;
    *)          cand="$(detect_test_cmd)" ;;
  esac
  if [ -n "$cand" ]; then
    LCARS_TESTREADY_STATUS="missing"
    LCARS_TESTREADY_SUGGESTION="$cand"
    return 0
  fi
  # No command AND no candidate. Before calling this greenfield, ask whether the
  # single detected stack is ambiguous WITHIN ITSELF — a dotnet repo with two
  # test projects has real test infrastructure and simply needs the captain to
  # choose. Folding that into `unknown` made init warn "SEVERAL test projects are
  # present", name both, and then declare the repo greenfield on the next line.
  local alt; alt="$(lcars_stack_alternatives "$stack")"
  if [ -n "$alt" ]; then
    LCARS_TESTREADY_STATUS="ambiguous"
    LCARS_TESTREADY_CANDIDATES="$alt"
    LCARS_TESTREADY_STACKS="$(printf '%s' "$alt" | sed 's/^dotnet test //' | tr '\n' ',' | sed 's/,$//')"
    return 0
  fi
  LCARS_TESTREADY_STATUS="unknown"
  return 0
}

# stack_uses_native_isolation <stack> — 0 when this stack's Implement gate legs
# are scoped by the RUNNER's own flags rather than by pointing it at an external
# $LCARS_TESTS_DIR quarantine (`cargo test --test <stem>`, `go test -run`, an
# explicit rspec/minitest file, `dotnet test --filter`). These runners are
# compiled/loaded per crate/package/project and simply cannot be aimed at a
# detached directory, which is why they took the native path in the first place.
#
# MUST STAY IN STEP with `stack_is_native` in skills/lcars-run/run.sh — that is
# the gate-side authority; this is the init/update-side reader of the same fact
# (run.sh does not source this file). Adding a stack to one means adding it to
# the other.
stack_uses_native_isolation() { # stack → 0 = native isolation
  case "${1:-}" in rust|go|ruby|dotnet) return 0 ;; *) return 1 ;; esac
}

# lcars_stack_alternatives <stack> — the candidate COMMANDS when a SINGLE stack
# is present but cannot pin ONE runner, newline-separated; empty when the stack
# has no such shape (which is every stack that never reaches here with a real
# choice to make). Today: dotnet with several test projects.
#
# Ruby has the same disease — an rspec (spec/) AND a minitest (test/ + Rakefile)
# layout without a decisive Gemfile signal also seeds nothing and reads as
# greenfield — and is deliberately LEDGERED rather than changed here: S145's
# shipped init/update output is regression-locked by tests/stack-ruby.test.sh and
# the S147 brief scopes this fix to the dotnet path. Same cure when it is due.
lcars_stack_alternatives() { # stack → candidate commands, one per line
  case "${1:-}" in
    dotnet)
      local projs n p
      projs="$(detect_dotnet_test_projects | grep . || :)"
      n="$(printf '%s' "$projs" | grep -c . || :)"
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      [ "$n" -ge 2 ] || return 0
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        printf 'dotnet test %s\n' "$p"
      done <<DN_ALT
$projs
DN_ALT
      ;;
    *) : ;;
  esac
}

# lcars_readiness_line — render the ONE human status line for the verdict the
# globals above carry. Ship-status voice (never a config lecture):
#   ready    → EMPTY (ready repos are silent everywhere — zero chrome drift)
#   broken/  → the REPAIR voice: ⚠ TEST SYSTEMS OFFLINE + the one-click fix verb
#   missing
#   unknown  → the BOOTSTRAP voice: a greenfield repo is EXPECTED, not an alarm —
#              reads as status, never an action item.
#   ambiguous→ (S147) the CHOOSE voice: this repo HAS test systems, several of
#              them, and LCARS will not pick for the captain. Never the
#              bootstrap voice (it is not greenfield) and never the bare repair
#              voice (nothing is broken) — it points at the same ⚡ fix verb.
# The unready voices must NEVER blur (captain ruling, S146).
lcars_readiness_line() {
  case "${LCARS_TESTREADY_STATUS:-}" in
    broken)
      printf '⚠ TEST SYSTEMS OFFLINE — testCommand runner "%s" not operational; missions cannot be proof-gated. Repair: lcars update --fix-tests\n' \
        "$(printf '%s' "$LCARS_TESTREADY_TESTCMD" | awk '{print $1}')"
      ;;
    missing)
      printf '⚠ TEST SYSTEMS OFFLINE — no test command configured (detected candidate: %s); missions cannot be proof-gated. Repair: lcars update --fix-tests\n' \
        "$LCARS_TESTREADY_SUGGESTION"
      ;;
    unknown)
      printf '◇ NO TEST SYSTEMS FOUND — a greenfield repo; the first mission%s engineering crew will establish them.\n' "'s"
      ;;
    # LEDGERED (recorded, not fixed): `$LCARS_TESTREADY_STACKS` is a list of
    # STACK IDS for a multi-stack repo — "(rust,js)" reads perfectly — but a list
    # of .csproj PATHS when one stack cannot pin its runner, and
    # "MULTIPLE TEST SYSTEMS DETECTED (One.Tests/One.Tests.csproj,…)" reads
    # awkwardly. It is accurate and it is what the captain must choose between,
    # so it ships; a per-shape phrasing (stacks vs projects) is the tidier fix
    # whenever this line is next opened.
    ambiguous)
      printf '⚠ MULTIPLE TEST SYSTEMS DETECTED (%s) — LCARS will not choose for you; missions cannot be proof-gated until one is selected. Select: lcars update --fix-tests\n' \
        "$LCARS_TESTREADY_STACKS"
      ;;
    *) : ;;  # ready (or uncomputed) → silent
  esac
}

# lcars_config_set_or_add_string — the sanctioned-writer primitive: overwrite a
# top-level string key IN PLACE (lcars_config_set_string), or — when the key is
# absent from an older config — INSERT it as the first key after the opening
# brace. Line-oriented and jq-free like its siblings; every other line is
# preserved byte-for-byte.
lcars_config_set_or_add_string() {
  local config="$1" key="$2" value="$3"
  [ -f "$config" ] || return 1
  if lcars_config_has_key "$config" "$key"; then
    lcars_config_set_string "$config" "$key" "$value"
    return $?
  fi
  local esc; esc="$(lcars_json_escape "$value")"
  local tmp="$config.tmp.$$" line inserted=0
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    if [ "$inserted" -eq 0 ]; then
      case "$line" in
        '{'*)
          printf '  "%s": "%s",\n' "$key" "$esc"
          inserted=1
          ;;
      esac
    fi
  done <"$config" >"$tmp"
  mv "$tmp" "$config"
}
