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
    local install
    if [ -f "$TOPLEVEL/pnpm-lock.yaml" ] || [ -f "$TOPLEVEL/pnpm-workspace.yaml" ]; then
      install='pnpm install --frozen-lockfile --prefer-offline --silent'
    elif [ -f "$TOPLEVEL/yarn.lock" ]; then
      install='yarn install --immutable'
    else
      install='npm ci'
    fi
    # find symlinks EVERY node_modules that is not nested inside another one
    # (-prune halts the descent at each match), recreating its path relative to
    # the main checkout inside the worktree. Generic across npm/yarn/pnpm.
    printf '%s\n' 'MAIN="$(git rev-parse --path-format=absolute --git-common-dir)"; MAIN="${MAIN%/.git}"; if [ -d "$MAIN/node_modules" ]; then find "$MAIN" -name node_modules -type d -prune -print | while IFS= read -r nm; do rel="${nm#$MAIN/}"; mkdir -p "$(dirname "$rel")"; ln -snf "$nm" "$rel"; done; else '"$install"'; fi'
    return
  fi
  # Python and everything else: no single offline-safe string we can guarantee —
  # emit empty and let the provisioner warn (never emit a command that errors).
  echo ""
}
