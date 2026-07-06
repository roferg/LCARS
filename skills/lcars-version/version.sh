#!/usr/bin/env bash
#
# lcars version — print the full version picture.
#
# Three things the captain wants to know at a glance:
#   1. The RUNNING version — what this LCARS clone actually is (its VERSION file).
#   2. The SOURCE — where that clone lives and its git state (branch, clean/dirty),
#      so "is my checkout current?" has an answer.
#   3. THIS repo's stamp — when the current working dir is an LCARS-initialized
#      repo, the lcarsVersion recorded in its config.json, plus a one-line verdict:
#      current / needs `lcars update` / unknown (predates versioning).
#
# READ-ONLY: it scans and prints, changing nothing. In particular it NEVER runs a
# `git fetch` (this path has no network) — ahead/behind is out of scope; branch +
# clean/dirty is the source git baseline.
#
# Dependencies + inputs are env-injected so tests can stub them and pin fixtures:
#   LCARS_REPO         the LCARS checkout (default: resolved from this script's
#                      real path — works through the install symlink)
#   LCARS_VERSION      override the running version string (default: read VERSION)
#   GIT_BIN            git binary                    (default: git)
#   LCARS_VERSION_CWD  repo to inspect for a stamp   (default: $PWD)
set -uo pipefail

GIT_BIN="${GIT_BIN:-git}"
CWD="${LCARS_VERSION_CWD:-$PWD}"

# --- locate the LCARS checkout (mirrors buddy.sh) -------------------------
# This script ships at <repo>/skills/lcars-version/version.sh but is invoked
# through the install symlink; `pwd -P` resolves the symlinked dir to its
# PHYSICAL path, so ../.. lands on the real checkout. An explicit LCARS_REPO wins.
SELF="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
DEFAULT_REPO="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd -P)"
REPO="${LCARS_REPO:-$DEFAULT_REPO}"

# Shared jq-free config reader (lcars_config_get).
COMMON="$REPO/skills/lcars-init/lcars-common.sh"
[ -f "$COMMON" ] && . "$COMMON"

die() { printf 'lcars version: %s\n' "$1" >&2; exit 1; }

# --- version parsing: YYYY.M.N, compared FIELD-BY-FIELD NUMERICALLY --------
# String compare is wrong (2026.7.2 vs 2026.7.10 — 10 > 2 numerically), so parse
# the three integer fields and compare each. version_valid guards every read so a
# malformed / empty VERSION yields a readable error, never an arithmetic blow-up.
version_valid() {
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;                       # empty or non-[0-9.] chars
  esac
  # exactly three dot-separated, non-empty, numeric fields
  local IFS=.; set -f; set -- $1; set +f
  [ "$#" -eq 3 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ]
}

# version_cmp A B -> echoes -1 (A<B), 0 (A==B), 1 (A>B). Assumes both valid.
version_cmp() {
  local a="$1" b="$2" ai bi i
  local -a af bf
  local IFS=.; set -f; af=($a); bf=($b); set +f; unset IFS
  for i in 0 1 2; do
    ai=$((10#${af[i]})); bi=$((10#${bf[i]}))
    if [ "$ai" -lt "$bi" ]; then echo -1; return; fi
    if [ "$ai" -gt "$bi" ]; then echo 1;  return; fi
  done
  echo 0
}

hr() { printf -- '────────────────────────────────────────────────────────\n'; }

# ==========================================================================
# 1) RUNNING VERSION
# ==========================================================================
VERSION_FILE="$REPO/VERSION"
if [ -n "${LCARS_VERSION:-}" ]; then
  RUNNING="$LCARS_VERSION"
elif [ -f "$VERSION_FILE" ]; then
  # first non-empty line, whitespace-trimmed
  RUNNING="$(sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}' "$VERSION_FILE")"
else
  RUNNING=""
fi

if ! version_valid "$RUNNING"; then
  if [ -z "$RUNNING" ]; then
    die "running VERSION is missing or empty (expected $VERSION_FILE with a YYYY.M.N line)."
  fi
  die "running VERSION '$RUNNING' is malformed (expected YYYY.M.N, e.g. 2026.7.1)."
fi

hr
echo "LCARS VERSION"
hr
echo "running version: $RUNNING"

# ==========================================================================
# 2) SOURCE — where this clone lives + its git state (NO fetch)
# ==========================================================================
echo "source path:     $REPO"
branch="$("$GIT_BIN" -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
dirty="$("$GIT_BIN" -C "$REPO" status --short 2>/dev/null)"
if [ -n "$dirty" ]; then
  state="dirty"
else
  state="clean"
fi
echo "source git:      branch ${branch:-<unknown>} — $state"

# ==========================================================================
# 3) THIS repo's stamp + verdict (only when LCARS-initialized)
# ==========================================================================
CONFIG="$CWD/.git/lcars/config.json"
echo
echo "current repo:    $CWD"
if [ ! -f "$CONFIG" ]; then
  echo "  (not LCARS-initialized — no .git/lcars/config.json here. Run \`lcars init\`.)"
  exit 0
fi

STAMPED=""
if command -v lcars_config_get >/dev/null 2>&1; then
  STAMPED="$(lcars_config_get "$CONFIG" lcarsVersion)"
fi

if [ -z "$STAMPED" ]; then
  echo "  stamped version: (unstamped)"
  echo "  verdict:         unknown — repo predates versioning."
elif ! version_valid "$STAMPED"; then
  echo "  stamped version: $STAMPED"
  echo "  verdict:         unknown — stamped version is malformed."
else
  echo "  stamped version: $STAMPED"
  cmp="$(version_cmp "$STAMPED" "$RUNNING")"
  case "$cmp" in
    0)  echo "  verdict:         current" ;;
    -1) echo "  verdict:         repo needs \`lcars update\`" ;;
    1)  echo "  verdict:         ahead of the running clone ($STAMPED > $RUNNING)" ;;
  esac
fi
exit 0
