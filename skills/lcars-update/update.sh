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

# --- the running LCARS version (what update stamps the repo current to) ----
# VERSION ships in the repo root (../.. from this skill dir; -P resolves the
# install symlink to the physical checkout). LCARS_VERSION wins so tests can pin
# it; LCARS_REPO redirects the checkout root (mirrors skills/lcars-version and
# init.sh). Empty when unresolved — the stamp is then left as-is.
lcars_running_version() {
  if [ -n "${LCARS_VERSION:-}" ]; then printf '%s' "$LCARS_VERSION"; return; fi
  local phys repo vf
  phys="$(cd "$SCRIPT_DIR" && pwd -P)"
  repo="${LCARS_REPO:-$(cd "$phys/../.." 2>/dev/null && pwd -P)}"
  vf="$repo/VERSION"
  [ -f "$vf" ] || return 0
  sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}' "$vf"
}
RUNNING_VERSION="$(lcars_running_version)"

# --- MIGRATION: stale copy-based vitest testCommand -> in-place form ---------
# S101 made the Test-Writer author each per-ticket test IN THE REPO at its
# convention and run the red gate IN PLACE (positional scope): a co-located test
# imports its sibling source via `./sibling`, so copying it into a `.lcars-tests`
# staging dir DETACHES it from that source and breaks the import. Repos initialized
# by an OLDER `lcars init` carry a COPY-STAGING vitest testCommand that does exactly
# that — now INCOMPATIBLE. This migration recognizes that unambiguous LCARS-generated
# fingerprint and rewrites it to the in-place equivalent, PRESERVING the runner
# invocation + its flags and any leading `cd <pkg>`. It touches ONLY that exact
# form; a genuine custom / already-in-place / non-vitest / null testCommand is left
# completely alone (config is sacred — but the .lcars-tests copy pattern is never
# hand-written).
#
# Sets MIGRATED_TESTCOMMAND=1 when it rewrote the value.
migrate_stale_testcommand() {
  local config="$1"
  MIGRATED_TESTCOMMAND=0
  [ -f "$config" ] || return 0

  local tc; tc="$(lcars_config_get "$config" testCommand)"
  [ -n "$tc" ] || return 0

  # Fingerprint — ALL markers of the LCARS copy-staging vitest form must be present
  # together. Any one absent => not our form => leave untouched.
  case "$tc" in *.lcars-tests*)               : ;; *) return 0 ;; esac
  case "$tc" in *'cp -R "${LCARS_TESTS_DIR'*)  : ;; *) return 0 ;; esac
  case "$tc" in *'--dir .lcars-tests'*)        : ;; *) return 0 ;; esac
  case "$tc" in *'else exec '*'; fi'*)         : ;; *) return 0 ;; esac

  # BASE = the base vitest invocation from the `else exec <BASE>; fi` full-suite
  # branch — preserves the runner path AND flags (e.g. --pool=forks).
  local base
  base="$(printf '%s' "$tc" | sed -n 's/.*else exec \(.*\); fi.*/\1/p')"
  base="$(printf '%s' "$base" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$base" ]; then
    echo "  ⚠ testCommand matches the stale .lcars-tests copy form but its base vitest" >&2
    echo "    invocation could not be derived; set an in-place testCommand manually" >&2
    echo "    (S101: e.g. 'exec node_modules/.bin/vitest run \${LCARS_TESTS_DIR:+\"\${LCARS_TESTS_DIR#\"\$PWD/\"}\"}')." >&2
    return 0
  fi

  # CD = the leading `cd <dir>` before the first `;`, if present.
  local cd_dir="" firstseg
  case "$tc" in
    cd\ *)
      firstseg="${tc%%;*}"
      cd_dir="${firstseg#cd}"
      cd_dir="$(printf '%s' "$cd_dir" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      ;;
  esac

  # In-place form: relativize $LCARS_TESTS_DIR to the runner's cwd (same tail init
  # emits for vitest today). Single-quoted so nothing expands here — the runtime
  # `bash -c` expands it at gate time.
  local tail='${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
  local newtc
  if [ -n "$cd_dir" ]; then
    newtc="cd $cd_dir 2>/dev/null; exec $base $tail"
  else
    newtc="exec $base $tail"
  fi

  [ "$newtc" = "$tc" ] && return 0
  lcars_config_set_string "$config" testCommand "$newtc"
  MIGRATED_TESTCOMMAND=1
}

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

# The version STAMP is the one key update deliberately refreshes (that IS update's
# meaning). Read the OLD stamp BEFORE the merge so we can report old → new. Seed
# lcarsVersion in the desired schema (so an absent key is added by the merge, and
# it's never dropped as an unknown key); then, after the merge, FORCE it current
# below. Omitted from the schema only when the running version can't be resolved —
# we then leave whatever stamp exists untouched.
OLD_VERSION="$(lcars_config_get "$CONFIG" lcarsVersion)"
VERSION_LINE=""
[ -n "$RUNNING_VERSION" ] && VERSION_LINE="
lcarsVersion=\"$RUNNING_VERSION\""

DESIRED_CONFIG="model=\"$DEFAULT_MODEL\"
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
testCommand=null
worktreeSetupCommand=$WTSETUP_VALUE
comprehensionBudget=1200$VERSION_LINE
created=\"$CREATED\""
lcars_config_merge "$CONFIG" "$DESIRED_CONFIG"
CONFIG_ADDED="$LCARS_CONFIG_ADDED_KEYS"

# Targeted schema migration: rewrite a stale copy-based vitest testCommand to the
# in-place form (S101). Runs AFTER the merge so it rewrites the preserved value.
migrate_stale_testcommand "$CONFIG"

# Force the version stamp CURRENT (the one deliberate overwrite update owns). The
# merge preserves an existing stamp, so refresh it to the running version here.
# Only counts as a change when the stamp actually moved — an already-current stamp
# stays byte-identical and does not flip the "nothing to update" verdict. When the
# key was freshly seeded by the merge, the merge already reports it in CONFIG_ADDED.
VERSION_STAMPED=0
if [ -n "$RUNNING_VERSION" ] && [ "$OLD_VERSION" != "$RUNNING_VERSION" ]; then
  lcars_config_set_string "$CONFIG" lcarsVersion "$RUNNING_VERSION"
  VERSION_STAMPED=1
fi
# Don't double-report lcarsVersion as an "added key" when we're already reporting
# the stamp move below — keep the config-keys-added line to genuinely new keys.
if [ "$VERSION_STAMPED" -eq 1 ]; then
  CONFIG_ADDED="$(printf '%s' "$CONFIG_ADDED" | tr ' ' '\n' | grep -vx lcarsVersion | tr '\n' ' ')"
  CONFIG_ADDED="$(printf '%s' "$CONFIG_ADDED" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
fi

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

if [ "${MIGRATED_TESTCOMMAND:-0}" -eq 1 ]; then
  changed=1
  echo "  ✓ testCommand migrated to in-place form (S101: co-located tests run in place; old .lcars-tests copy form is incompatible)"
fi

if [ "$VERSION_STAMPED" -eq 1 ]; then
  changed=1
  old_render="${OLD_VERSION:-(unstamped)}"
  echo "  ✓ lcarsVersion stamped: $old_render → $RUNNING_VERSION"
fi

if [ "$changed" -eq 0 ]; then
  echo "  ✓ nothing to update — labels and config are already current."
fi
echo "  missions/ untouched."
