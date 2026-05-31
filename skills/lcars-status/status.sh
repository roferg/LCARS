#!/usr/bin/env bash
#
# lcars status — read-only command-and-control view of active Missions.
#
# Scans .git/lcars/missions/, loads each state.json, and renders the active
# Missions as a table: id, GitHub issue, stage, a status glyph (paused /
# awaiting-human), and title. Missions awaiting a human answer get their
# pending question printed below the table so the captain knows what to
# respond to. Newest Missions are listed first.
#
# This is the whole skill — `lcars status` is purely mechanical, so unlike the
# conversational skills there's no Claude-driven half. It writes nothing.
#
# A glance at the two empty states:
#   .git/lcars/ missing      -> "Not initialised. Run `lcars init`."
#   missions/ empty          -> "No active missions. Run `lcars file`."
#
set -uo pipefail

# --- locate the repo + state dir ------------------------------------------
# Mirror file.sh: resolve .git, then .git/lcars/. Anything short of a fully
# scaffolded state dir means the repo hasn't been initialised for LCARS.
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || GIT_DIR=""
if [ -n "$GIT_DIR" ]; then
  case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
fi

LCARS_DIR="${GIT_DIR:+$GIT_DIR/lcars}"
MISSIONS_DIR="${LCARS_DIR:+$LCARS_DIR/missions}"

if [ -z "$LCARS_DIR" ] || [ ! -d "$LCARS_DIR" ]; then
  echo "Not initialised. Run \`lcars init\`."
  exit 0
fi

# --- gather missions ------------------------------------------------------
# A "mission" is any subdirectory of missions/ holding a state.json. Dirs
# without one (half-written, manually poked) are skipped silently.
states=()
if [ -d "$MISSIONS_DIR" ]; then
  shopt -s nullglob
  for d in "$MISSIONS_DIR"/*/; do
    [ -f "${d}state.json" ] && states+=("${d}state.json")
  done
  shopt -u nullglob
fi

if [ "${#states[@]}" -eq 0 ]; then
  echo "No active missions. Run \`lcars file\`."
  exit 0
fi

# --- tiny JSON field readers (no jq dependency, same style as file.sh) ----
# json_str  pulls a "key": "value" string; json_raw pulls a bare token
# (number / true / false / null). Both take the first match.
json_str() { # file key
  # [^"]* (not .*) so a single-line state.json doesn't get its whole tail
  # swallowed by a greedy match — stop at the closing quote of this value.
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}
json_raw() { # file key
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- build the rows -------------------------------------------------------
# Each mission becomes one tab-separated record prefixed with a sort key
# (created\tid) so we can sort newest-first with a plain `sort -r`, breaking
# ties on id. Record fields: id, issue, stage, glyph, title.
PAUSE_GLYPH="⏸"
ASK_GLYPH="❓"

rows=()
questions=()  # "id\tissue\tquestion" for the awaiting-human footer
for s in "${states[@]}"; do
  id="$(json_str "$s" id)"
  [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
  title="$(json_str "$s" title)"
  stage="$(json_str "$s" stage)"
  created="$(json_str "$s" created)"
  issue="$(json_raw "$s" githubIssue)"
  paused="$(json_raw "$s" paused)"
  question="$(json_str "$s" pendingQuestion)"

  # issue → "#42" or "-" when none has been opened yet (ASCII dash keeps the
  # column aligned — a multibyte em-dash would throw printf's width off)
  case "$issue" in
    ''|null) issue_disp="-" ;;
    *)       issue_disp="#$issue" ;;
  esac

  # status glyph: paused and/or awaiting-human (awaiting requires a question)
  glyph=""
  [ "$paused" = "true" ] && glyph="$PAUSE_GLYPH"
  if [ -n "$question" ]; then
    glyph="${glyph:+$glyph}$ASK_GLYPH"
    questions+=("$id"$'\t'"$issue_disp"$'\t'"$question")
  fi

  rows+=("$created"$'\t'"$id"$'\t'"$id"$'\t'"$issue_disp"$'\t'"$stage"$'\t'"$glyph"$'\t'"$title")
done

# Sort newest-first by the created\tid prefix, then drop that prefix.
sorted="$(printf '%s\n' "${rows[@]}" | sort -r -t$'\t' -k1,2)"

# --- render the table -----------------------------------------------------
RULE="───────────────────────────────────────────────────────────────"

echo "LCARS — Active Missions"
echo "$RULE"
printf '%-22s%-7s%-13s%-4s%s\n' "ID" "ISSUE" "STAGE" "" "TITLE"
while IFS=$'\t' read -r _created _sortid id issue stage glyph title; do
  [ -n "$id" ] || continue
  printf '%-22s%-7s%-13s%-4s%s\n' "$id" "$issue" "$stage" "$glyph" "$title"
done <<<"$sorted"
echo "$RULE"
printf '%s paused    %s awaiting your input\n' "$PAUSE_GLYPH" "$ASK_GLYPH"

# --- awaiting-human footer ------------------------------------------------
# Spell out every pending question so the captain can respond without digging
# into state.json.
if [ "${#questions[@]}" -gt 0 ]; then
  echo
  echo "Awaiting your input:"
  for q in "${questions[@]}"; do
    IFS=$'\t' read -r qid qissue qtext <<<"$q"
    printf '  %s (%s): %s\n' "$qid" "$qissue" "$qtext"
  done
  echo
  echo "Respond with \`lcars respond <id>\`."
fi
