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

# Shared version parse/compare (version_valid, version_cmp, running-version read):
# YYYY.M.N compared FIELD-BY-FIELD NUMERICALLY (2026.7.10 > 2026.7.2). One copy,
# also used by check.sh, so the rules can never drift between the two.
. "$SCRIPT_DIR/version-lib.sh"

die() { printf 'lcars version: %s\n' "$1" >&2; exit 1; }

hr() { printf -- '────────────────────────────────────────────────────────\n'; }

# ==========================================================================
# 1) RUNNING VERSION
# ==========================================================================
VERSION_FILE="$REPO/VERSION"
if [ -n "${LCARS_VERSION:-}" ]; then
  RUNNING="$LCARS_VERSION"
else
  RUNNING="$(lcars_version_read_running "$VERSION_FILE")"
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
