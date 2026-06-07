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

# lcars_config_has_key — 0 if the config file has a top-level "key": present.
lcars_config_has_key() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 1
  grep -q "\"$key\"[[:space:]]*:" "$config"
}

# lcars_config_get — print the raw JSON value of a top-level key (no surrounding
# quotes stripped for strings beyond the obvious; used for string values like
# "created"). Empty if absent.
lcars_config_get() {
  local config="$1" key="$2"
  [ -f "$config" ] || return 0
  sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$config" | head -1
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
