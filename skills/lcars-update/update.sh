#!/usr/bin/env bash
#
# lcars update — bring an ALREADY-INITIALIZED repo up to the current LCARS
# schema without clobbering the captain's customizations.
#
# Unlike `lcars init` (first-time setup), update assumes .git/lcars/ already
# exists and only fills GAPS:
#   GITHUB  create any MISSING LCARS labels, skip ones already present.
#   LOCAL   add any MISSING config.json keys with their defaults, NEVER
#           overwriting an existing value; missions/ is left completely alone.
#   OUTPUT  report what was ADDED vs ALREADY PRESENT. On an up-to-date repo it
#           changes nothing and prints "nothing to update".
#
# Dependencies are taken via env so they can be stubbed in tests:
#   LCARS_GH_BIN   the gh binary (default: gh)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
DEFAULT_MODEL="${LCARS_MODEL:-claude-sonnet}"

# Shared label set + merge-preserving config writer (also used by `lcars init`).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lcars-init/lcars-common.sh"

die() { printf 'lcars update: %s\n' "$1" >&2; exit 1; }

# --- locate the repo ------------------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
case "$GIT_DIR" in
  /*) : ;;
  *)  GIT_DIR="$PWD/$GIT_DIR" ;;
esac

LCARS_DIR="$GIT_DIR/lcars"
CONFIG="$LCARS_DIR/config.json"

# --- must already be initialized -----------------------------------------
if [ ! -d "$LCARS_DIR" ]; then
  die "this repo is not initialized for LCARS — run \`lcars init\` first."
fi

# --- GITHUB: create only the MISSING labels -------------------------------
GH_REPO=""
LABELS_CREATED=0
LABELS_SKIPPED=0
LABELS_CREATED_NAMES=""
GH_OK=0
if command -v "$GH_BIN" >/dev/null 2>&1; then
  GH_OK=1
  GH_REPO="$("$GH_BIN" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  EXISTING_LABELS="$("$GH_BIN" label list --limit 200 --json name -q '.[].name' 2>/dev/null)"
  lcars_create_labels "$GH_BIN" "$EXISTING_LABELS"
  LABELS_CREATED="$LCARS_LABELS_CREATED"
  LABELS_SKIPPED="$LCARS_LABELS_SKIPPED"
  LABELS_CREATED_NAMES="$LCARS_LABELS_CREATED_NAMES"
fi

# --- LOCAL: fill any MISSING config keys (merge, never clobber) ------------
# Recompute the same defaults init would use, so a key added to the schema since
# this repo was initialized gets its proper default. Existing values are
# preserved by lcars_config_merge — only absent keys take these defaults.
if [ -f "$TOPLEVEL/CONTEXT.md" ]; then CONTEXT_VALUE='"CONTEXT.md"'; else CONTEXT_VALUE='null'; fi
PROJECT_NAME="$(basename "$TOPLEVEL")"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # only used if 'created' is somehow absent

# Recompute the worktree provisioning default the SAME way init does (shared
# helper in lcars-common.sh), so an older config gets the proper ecosystem
# default backfilled. Existing values are preserved by lcars_config_merge — only
# an absent key takes this default.
WT_SETUP_CMD="$(detect_worktree_setup_cmd)"
if [ -n "$WT_SETUP_CMD" ]; then
  WTSETUP_VALUE="\"$(lcars_json_escape "$WT_SETUP_CMD")\""
else
  WTSETUP_VALUE='null'
fi

DESIRED_CONFIG="model=\"$DEFAULT_MODEL\"
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
testCommand=null
worktreeSetupCommand=$WTSETUP_VALUE
comprehensionBudget=1200
created=\"$CREATED\""
lcars_config_merge "$CONFIG" "$DESIRED_CONFIG"
CONFIG_ADDED="$LCARS_CONFIG_ADDED_KEYS"

# --- OUTPUT: report added vs present ---------------------------------------
changed=0

if [ "$GH_OK" -eq 1 ]; then
  if [ "$LABELS_CREATED" -gt 0 ]; then
    changed=1
    where="${GH_REPO:+ on github.com/$GH_REPO}"
    echo "  ✓ $LABELS_CREATED label(s) created$where: $LABELS_CREATED_NAMES"
    echo "    ($LABELS_SKIPPED already present)"
  fi
else
  echo "  ⚠ gh CLI not found — skipped GitHub label check. Install gh and re-run."
fi

if [ -n "$CONFIG_ADDED" ]; then
  changed=1
  echo "  ✓ config keys added (defaults filled, existing values preserved): $CONFIG_ADDED"
fi

if [ "$changed" -eq 0 ]; then
  echo "  ✓ nothing to update — labels and config are already current."
fi
echo "  missions/ untouched."
