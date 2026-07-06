#!/usr/bin/env bash
#
# check.sh — the ONE shared LCARS version check + ask-to-update helper.
#
# Interactive entry points (`lcars`, `lcars file`, the run start, the viewscreen
# launcher) call this in `ask` mode BEFORE their real work; headless paths
# (`run.sh drive`, `resolve-logs`) call it in `warn` mode. Either way it NEVER
# fails the calling verb — every path returns 0, and the callers guard it with
# `|| true` on top of that. The walk-away principle is inviolate: `warn` mode
# never prompts and never reads stdin.
#
# It is THROTTLED. A user-level stamp file records the last fetch epoch + the
# last-seen remote VERSION, so at most one `git fetch` runs per TTL window; a
# call inside the window reports from that cache with zero network. A fetch that
# cannot reach origin degrades to a one-line warning and continues.
#
# Verdicts (MULTIPLE can hold at once — every one that holds is emitted):
#   SOURCE_BEHIND  remote VERSION > running               → offer the full update
#   REPO_STALE     this repo's config lcarsVersion < running → offer `lcars update`.
#                  ALSO holds when the repo is LCARS-initialized but UNSTAMPED
#                  (no lcarsVersion key at all) — that repo predates versioning, so
#                  it definitely needs `lcars update` (REPO_PREDATES: a clean
#                  "predates" message, not "stamp () is behind"). A non-empty but
#                  MALFORMED stamp stays UNKNOWN (no nag); an uninitialized cwd is
#                  silent.
#   DRIFT          origin/main tip is ahead of the commit that last touched
#                  VERSION ("main has unversioned changes") → warn, name `lcars release`
#   CURRENT        none of the above                        → say nothing
#
# The full update touches ONLY the source's MAIN checkout, ONLY via
# `git pull --ff-only`, ONLY when it is on main AND clean AND fast-forwardable;
# every unsafe case (dirty / on a branch / a worktree holds main / diverged)
# prints a one-line reason and CONTINUES.
#
# Usage:  check.sh [ask|warn|report|update]   (default: warn — the safe one)
#   ask     interactive: prompt to update (default ENTER = No)
#   warn    headless: one human line per verdict, no prompt, no stdin
#   report  machine-readable KEY=VALUE verdict lines (the viewscreen daemon reads
#           these into meta.version); cache/throttle-identical to warn
#   update  run the update action non-interactively (the viewscreen button);
#           unsafe cases print their reason and exit 0
#
# Everything external is env-injected so tests stub every binary and pin time:
#   LCARS_VERSION_CHECK   "0" = global kill switch (no output, ZERO git calls)
#   LCARS_REPO            source root (default: resolved from this script's path)
#   LCARS_VERSION         running version (default: read $REPO/VERSION)
#   LCARS_VERSION_CWD     repo to inspect for its stamp (default: $PWD)
#   LCARS_GIT_BIN/GIT_BIN git binary                   (default: git)
#   LCARS_VERSION_STAMP   throttle stamp file  (default: ~/.claude/lcars-version-check)
#   LCARS_VERSION_TTL     throttle window seconds       (default: 86400)
#   LCARS_NOW_EPOCH       "now" in epoch seconds        (default: date +%s)
#   LCARS_INSTALL_BIN     the installer            (default: $REPO/install.sh)
#   LCARS_UPDATE_BIN      the `lcars update` script (default: installed update.sh)
#   LCARS_GH_BIN          gh (forwarded to `lcars update`)
#
set -uo pipefail

MODE="${1:-warn}"

# --- global kill switch: zero output, ZERO git calls ----------------------
[ "${LCARS_VERSION_CHECK:-1}" = "0" ] && exit 0

# --- locate the LCARS checkout (mirrors version.sh / buddy.sh) ------------
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
DEFAULT_REPO="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P)"
REPO="${LCARS_REPO:-$DEFAULT_REPO}"

. "$SCRIPT_DIR/version-lib.sh"
COMMON="$REPO/skills/lcars-init/lcars-common.sh"
[ -f "$COMMON" ] && . "$COMMON"

GIT_BIN="${LCARS_GIT_BIN:-${GIT_BIN:-git}}"
CWD="${LCARS_VERSION_CWD:-$PWD}"
STAMP="${LCARS_VERSION_STAMP:-$HOME/.claude/lcars-version-check}"
TTL="${LCARS_VERSION_TTL:-86400}"
NOW="${LCARS_NOW_EPOCH:-$(date +%s 2>/dev/null || echo 0)}"
INSTALL_BIN="${LCARS_INSTALL_BIN:-$REPO/install.sh}"
UPDATE_BIN="${LCARS_UPDATE_BIN:-$HOME/.claude/skills/lcars-update/update.sh}"

say() { printf '%s\n' "$1"; }

# --- running version ------------------------------------------------------
if [ -n "${LCARS_VERSION:-}" ]; then
  RUNNING="$LCARS_VERSION"
else
  RUNNING="$(lcars_version_read_running "$REPO/VERSION")"
fi
# A missing/malformed running version can't anchor a comparison — degrade
# silently (a version check must NEVER be the thing that stops the verb).
version_valid "$RUNNING" || exit 0

# --- throttle: at most one `git fetch` per TTL window ---------------------
last_epoch=0; last_remote=""
if [ -f "$STAMP" ]; then
  last_epoch="$(sed -n '1p' "$STAMP" 2>/dev/null)"
  last_remote="$(sed -n '2p' "$STAMP" 2>/dev/null)"
  case "$last_epoch" in ''|*[!0-9]*) last_epoch=0 ;; esac
fi

REMOTE=""; FETCH_FAILED=0
age=$(( NOW - last_epoch ))
if [ -f "$STAMP" ] && [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ]; then
  # Fresh within the window — report from cache, NO fetch.
  REMOTE="$last_remote"
else
  # Stale (or first run) — fetch once, then restamp.
  if "$GIT_BIN" -C "$REPO" fetch origin main >/dev/null 2>&1; then
    REMOTE="$("$GIT_BIN" -C "$REPO" show origin/main:VERSION 2>/dev/null \
              | sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}')"
    mkdir -p "$(dirname "$STAMP")" 2>/dev/null || true
    printf '%s\n%s\n' "$NOW" "$REMOTE" >"$STAMP" 2>/dev/null || true
  else
    # Unreachable origin → degrade to a warning; fall back to any cached remote.
    FETCH_FAILED=1
    REMOTE="$last_remote"
  fi
fi

# --- verdicts (all that hold) ---------------------------------------------
SOURCE_BEHIND=0; DRIFT=0; REPO_STALE=0; REPO_PREDATES=0

if version_valid "$REMOTE" && [ "$(version_cmp "$REMOTE" "$RUNNING")" = "1" ]; then
  SOURCE_BEHIND=1
fi

# DRIFT: origin/main's tip is ahead of the commit that last touched VERSION —
# i.e. main moved without a version bump. Computed from the local origin/main ref
# (populated by the throttled fetch), so a cached call still evaluates it with no
# network. Skipped when origin/main is unknown.
if "$GIT_BIN" -C "$REPO" rev-parse --verify -q origin/main >/dev/null 2>&1; then
  vcommit="$("$GIT_BIN" -C "$REPO" rev-list -n1 origin/main -- VERSION 2>/dev/null)"
  if [ -n "$vcommit" ]; then
    ahead="$("$GIT_BIN" -C "$REPO" rev-list --count "${vcommit}..origin/main" 2>/dev/null)"
    case "$ahead" in ''|0|*[!0-9]*) : ;; *) DRIFT=1 ;; esac
  fi
fi

# REPO_STALE: this repo IS LCARS-initialized (config.json exists) but its stamp
# is behind — OR absent. An initialized repo whose config carries NO lcarsVersion
# key predates the versioning round, so it DEFINITELY needs `lcars update`
# (REPO_PREDATES → a clean "predates" message, not "stamp () is behind"). A
# non-empty but MALFORMED stamp stays UNKNOWN — never nag on garbage. An
# UNINITIALIZED cwd (no config.json) is silent (the `[ -f "$CONFIG" ]` guard).
STAMPED=""
CONFIG="$CWD/.git/lcars/config.json"
if [ -f "$CONFIG" ] && command -v lcars_config_get >/dev/null 2>&1; then
  STAMPED="$(lcars_config_get "$CONFIG" lcarsVersion)"
  if [ -z "$STAMPED" ]; then
    # initialized but never stamped ⇒ predates versioning ⇒ needs update.
    REPO_STALE=1; REPO_PREDATES=1
  elif version_valid "$STAMPED" && [ "$(version_cmp "$STAMPED" "$RUNNING")" = "-1" ]; then
    REPO_STALE=1
  fi
  # a non-empty but malformed stamp is intentionally left as unknown (no nag).
fi

# --- update actions (interactive only; each is a NO-FAIL, warn-and-continue) --
run_install() {
  say "  Reinstalling skills (./install.sh)…"
  if bash "$INSTALL_BIN" >/dev/null 2>&1; then
    say "  ✓ skills reinstalled."
  else
    say "  ⚠ install.sh failed — your skills may be stale; re-run ./install.sh by hand."
  fi
}

run_repo_update() {
  [ -d "$CWD/.git/lcars" ] || return 0
  say "  Restamping this repo (lcars update)…"
  if (
       cd "$CWD" || exit 1
       export LCARS_VERSION="$RUNNING"
       [ -n "${LCARS_GH_BIN:-}" ] && export LCARS_GH_BIN
       bash "$UPDATE_BIN" >/dev/null 2>&1
     ); then
    say "  ✓ repo restamped to $RUNNING."
  else
    say "  ⚠ lcars update failed — run \`lcars update\` here by hand."
  fi
}

do_full_update() {
  # The captain's clones are sacred: touch ONLY a clean main checkout, ONLY
  # fast-forward. Any unsafe state declines with a reason and continues.
  local branch dirty
  branch="$("$GIT_BIN" -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "main" ]; then
    say "  ⚠ source checkout is on '${branch:-?}', not main (main may be checked out in another worktree) — skipping the pull. Continuing on $RUNNING."
    return 0
  fi
  dirty="$("$GIT_BIN" -C "$REPO" status --porcelain 2>/dev/null)"
  if [ -n "$dirty" ]; then
    say "  ⚠ source main checkout is dirty — skipping the pull to protect your changes. Continuing on $RUNNING."
    return 0
  fi
  if ! "$GIT_BIN" -C "$REPO" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    say "  ⚠ source main has diverged from origin (no fast-forward possible) — resolve it by hand. Continuing on $RUNNING."
    return 0
  fi
  say "  Pulling LCARS source (ff-only)…"
  if ! "$GIT_BIN" -C "$REPO" pull --ff-only origin main >/dev/null 2>&1; then
    say "  ⚠ git pull --ff-only failed — continuing on $RUNNING."
    return 0
  fi
  say "  ✓ source updated."
  # The pull moved the source forward, so the running version is now the remote
  # one — re-read it so the reinstall + repo restamp land on the NEW version.
  RUNNING="$(lcars_version_read_running "$REPO/VERSION")"
  version_valid "$RUNNING" || RUNNING="$REMOTE"
  run_install
  run_repo_update
}

# --- REPORT mode: machine-readable verdicts (the viewscreen daemon's source) --
# Cache/throttle semantics IDENTICAL to warn (no prompt, no stdin; the git fetch
# is bounded by the stamp file). Emits KEY=VALUE lines the daemon parses into
# meta.version — so the board's banner can NEVER drift from the CLI's verdicts,
# and the daemon never re-implements the check. Always exits 0.
if [ "$MODE" = "report" ]; then
  printf 'running=%s\n' "$RUNNING"
  [ -n "$REMOTE" ] && printf 'remote=%s\n' "$REMOTE"
  [ "$FETCH_FAILED" = 1 ] && printf 'fetch_failed=1\n'
  [ "$SOURCE_BEHIND" = 1 ] && printf 'verdict=source_behind\n'
  if [ "$REPO_STALE" = 1 ]; then
    if [ "$REPO_PREDATES" = 1 ]; then printf 'verdict=repo_predates\n'
    else printf 'verdict=repo_stale\n'; fi
  fi
  [ "$DRIFT" = 1 ] && printf 'verdict=drift\n'
  exit 0
fi

# --- UPDATE mode: run the update action non-interactively (the board button) --
# Same actions the ask-mode 'y' path runs, but WITHOUT a prompt (the daemon
# already captured the captain's click). Unsafe cases (dirty / branched /
# diverged) print their one-line reason and exit 0, so the button surfaces the
# decline reason rather than failing. The captain's clones stay sacred.
if [ "$MODE" = "update" ]; then
  [ "$FETCH_FAILED" = 1 ] && \
    say "⚠ could not reach origin — continuing on the current version ($RUNNING)."
  if [ "$SOURCE_BEHIND" = 1 ]; then
    do_full_update
  elif [ "$REPO_STALE" = 1 ]; then
    run_repo_update
  else
    say "Already current ($RUNNING) — nothing to update."
  fi
  exit 0
fi

# --- report / act ---------------------------------------------------------
# A fetch failure is reported in BOTH modes (informational; never blocks).
[ "$FETCH_FAILED" = 1 ] && \
  say "⚠ LCARS version check: could not reach origin — continuing on the current version ($RUNNING)."

# CURRENT — nothing more to say.
if [ "$SOURCE_BEHIND" = 0 ] && [ "$REPO_STALE" = 0 ] && [ "$DRIFT" = 0 ]; then
  exit 0
fi

# --- WARN mode: one line per verdict, no prompt, no stdin -----------------
if [ "$MODE" != "ask" ]; then
  [ "$SOURCE_BEHIND" = 1 ] && \
    say "⚠ LCARS $REMOTE available (running $RUNNING) — run \`lcars\` interactively to update."
  if [ "$REPO_STALE" = 1 ]; then
    if [ "$REPO_PREDATES" = 1 ]; then
      say "⚠ this repo predates LCARS versioning — run \`lcars update\`."
    else
      say "⚠ this repo's LCARS stamp ($STAMPED) is behind the running version ($RUNNING) — run \`lcars update\`."
    fi
  fi
  [ "$DRIFT" = 1 ] && \
    say "⚠ LCARS main has unversioned changes — see \`lcars release\`."
  exit 0
fi

# --- ASK mode: themed one-line prompt; default ENTER = No -----------------
# DRIFT is informational even here (the repair, `lcars release`, is manual — S130).
[ "$DRIFT" = 1 ] && \
  say "⚠ LCARS main has unversioned changes — see \`lcars release\`."

if [ "$SOURCE_BEHIND" = 1 ]; then
  # The full update also restamps this repo, so it subsumes any REPO_STALE.
  printf 'LCARS %s AVAILABLE — ENGAGE UPDATE? [y/N] ' "$REMOTE"
  reply=""; read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES|Yes) do_full_update ;;
    *) say "Holding at $RUNNING." ;;
  esac
elif [ "$REPO_STALE" = 1 ]; then
  # Source is current; only this repo's stamp trails — offer JUST `lcars update`.
  if [ "$REPO_PREDATES" = 1 ]; then
    printf 'LCARS REPO PREDATES VERSIONING — RUN lcars update? [y/N] '
  else
    printf 'LCARS REPO STAMP %s BEHIND RUNNING %s — RUN lcars update? [y/N] ' "$STAMPED" "$RUNNING"
  fi
  reply=""; read -r reply || reply=""
  case "$reply" in
    y|Y|yes|YES|Yes) run_repo_update ;;
    *) say "Holding this repo at ${STAMPED:-unstamped}." ;;
  esac
fi

exit 0
