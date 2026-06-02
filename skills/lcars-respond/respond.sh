#!/usr/bin/env bash
#
# lcars respond — answer a Mission's awaiting-human gate, walk-away style.
#
# When a stage escalates (Research >20 questions, Validate scope change, Plan
# Review's 3-round limit, Implement's 5-attempt cap) it parks the Mission behind
# an awaiting-human gate: awaitingHuman=true in state.json, the question(s) in
# pending.json, and the lcars:awaiting-human label on the issue. This is the
# command the captain uses to answer that gate. It has three subcommands:
#
#   list                       Read-only. Every Mission with awaitingHuman=true
#                              and its pending question(s) — mirrors how
#                              `lcars status` surfaces them. Says so if none.
#
#   show   --mission <id>      Read-only. That Mission's pending question(s)
#                              from pending.json.
#
#   answer --mission <id> --answer "<text>"
#                              Persist the captain's free-form answer next to the
#                              question(s) in answers.json, clear the awaiting-
#                              human gate in state.json (the STAGE IS UNCHANGED —
#                              the Mission stays at the stage that escalated),
#                              and remove the lcars:awaiting-human label. A plain
#                              `lcars run <id>` then re-enters that same stage and
#                              consumes the answer instead of re-asking.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_GH_BIN   the gh binary           (default: gh)
#   LCARS_NOW      ISO stamp for the answer (default: now, UTC)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
NOW="${LCARS_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
RELABEL_NOTE=""

die() { printf 'lcars respond: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same style as run.sh / status.sh) -----------
# json_str decodes the common escapes so a question carrying an inner \" prints
# in full (same awk reader as status.sh); json_raw pulls a bare token.
json_str() { # file key
  awk -v k="$2" '
    done { next }
    {
      tok = "\"" k "\""
      p = index($0, tok)
      if (p == 0) next
      rest = substr($0, p + length(tok))
      if (match(rest, /^[ \t]*:[ \t]*"/) == 0) next
      rest = substr(rest, RLENGTH + 1)
      out = ""; i = 1; n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c == "\\") {
          e = substr(rest, i + 1, 1)
          if      (e == "n") out = out "\n"
          else if (e == "t") out = out "\t"
          else               out = out e
          i += 2; continue
        }
        if (c == "\"") break
        out = out c; i += 1
      }
      print out; done = 1
    }
  ' "$1"
}
json_raw() { # file key
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

# --- escape a string for embedding in JSON (printed) -----------------------
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }

# --- read pending.json's questions, one per line (decoded) -----------------
# The canonical pending.json (run.sh's write_pending) puts one "question" per
# line inside the "questions": [ … ] array, so a line-oriented awk pass is
# enough — same jq-free spirit as the rest of LCARS.
read_questions() { # pending.json
  awk '
    /"questions"[[:space:]]*:[[:space:]]*\[/ { inq=1; next }
    inq && /^[[:space:]]*\]/ { inq=0; next }
    inq {
      s=$0
      sub(/^[[:space:]]*/, "", s); sub(/[[:space:]]*$/, "", s)
      sub(/,$/, "", s)
      sub(/^"/, "", s); sub(/"$/, "", s)
      gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s)
      if (s != "") print s
    }
  ' "$1"
}

# --- locate .git/lcars/missions (mirrors run.sh / status.sh) ----------------
locate_missions_dir() {
  local gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSIONS_DIR="$gitdir/lcars/missions"
}

# --- locate a single mission ------------------------------------------------
locate_mission() { # id
  locate_missions_dir
  MISSION_DIR="$MISSIONS_DIR/$1"
  STATE="$MISSION_DIR/state.json"
  PENDING="$MISSION_DIR/pending.json"
  [ -d "$MISSION_DIR" ] || die "no mission '$1' under .git/lcars/missions/ — check the id."
  [ -f "$STATE" ]       || die "mission '$1' has no state.json — its state is corrupt."
}

# --- state.json field editing (one-field-per-line; same as run.sh) ----------
state_del() { # key — drop the field's line if present
  local tmp; tmp="$(mktemp)"
  grep -v "\"$1\"[[:space:]]*:" "$STATE" >"$tmp" && mv "$tmp" "$STATE"
}

# --- gh: remove the awaiting-human overlay, best-effort ---------------------
# Tolerant by design: gh is happy to remove a label that isn't applied, and a
# missing gh / failed edit never blocks the local clear — it just leaves a note.
# We never pre-query the issue's labels to "fix" the not-applied case.
gh_remove_awaiting() {
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in
    ''|null) RELABEL_NOTE="  ⚠ no GitHub issue on file — skipped label drop (local-only mission)."; return 0 ;;
  esac
  if command -v "$GH_BIN" >/dev/null 2>&1; then
    "$GH_BIN" issue edit "$issue" --remove-label "lcars:awaiting-human" >/dev/null 2>&1 \
      || RELABEL_NOTE="  ⚠ gh issue edit failed — drop lcars:awaiting-human on #$issue by hand."
  else
    RELABEL_NOTE="  ⚠ gh not found — drop lcars:awaiting-human on #$issue by hand."
  fi
}

# === subcommand: list =======================================================
# Scan every mission; print the ones awaiting a human with their question(s).
cmd_list() {
  locate_missions_dir
  if [ ! -d "$MISSIONS_DIR" ]; then
    echo "No missions awaiting your input."
    exit 0
  fi

  local found=0 s id stage issue pend
  shopt -s nullglob
  for s in "$MISSIONS_DIR"/*/state.json; do
    [ "$(json_raw "$s" awaitingHuman)" = "true" ] || continue
    found=$((found + 1))
    id="$(json_str "$s" id)"; [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
    stage="$(json_str "$s" stage)"
    issue="$(json_raw "$s" githubIssue)"
    case "$issue" in ''|null) issue="-" ;; *) issue="#$issue" ;; esac

    # state.json.stage is the resume pointer (e.g. "align"); pending.json holds
    # the true in-flight stage the card is stuck in (e.g. "research"), matching
    # the board label. Show that so this view agrees with the Kanban column.
    pend="$(dirname "$s")/pending.json"
    if [ -f "$pend" ]; then
      pstage="$(json_str "$pend" stage)"
      [ -n "$pstage" ] && stage="$pstage"
    fi

    [ "$found" -eq 1 ] && echo "LCARS — Missions awaiting your input"
    echo
    printf '  %s (%s) — stage: %s\n' "$id" "$issue" "${stage:-unknown}"
    if [ -f "$pend" ]; then
      while IFS= read -r q; do
        [ -n "$q" ] && echo "    • $q"
      done < <(read_questions "$pend")
    else
      local pq; pq="$(json_str "$s" pendingQuestion)"
      [ -n "$pq" ] && echo "    • $pq"
    fi
  done
  shopt -u nullglob

  if [ "$found" -eq 0 ]; then
    echo "No missions awaiting your input."
    exit 0
  fi
  echo
  echo "Answer one with \`lcars respond <id>\`."
  exit 0
}

# === subcommand: show =======================================================
# Print one Mission's pending question(s).
cmd_show() {
  locate_mission "$MISSION_ID"
  [ -f "$PENDING" ] || die "mission '$MISSION_ID' has no pending question — nothing to answer."

  local stage; stage="$(json_str "$PENDING" stage)"
  echo "LCARS — pending question(s) for $MISSION_ID (stage: ${stage:-unknown})"
  echo
  local any=0 q
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    any=1; echo "  • $q"
  done < <(read_questions "$PENDING")
  [ "$any" -eq 1 ] || die "pending.json for '$MISSION_ID' lists no questions — its gate is malformed."
  echo
  echo "Answer with \`lcars respond $MISSION_ID\` (or pass --answer \"…\")."
  exit 0
}

# === subcommand: answer =====================================================
# Persist the answer next to the question(s), clear the gate (stage unchanged),
# drop the awaiting-human label.
cmd_answer() {
  locate_mission "$MISSION_ID"
  [ -n "$ANSWER" ] || die "no answer — pass --answer \"<your answer>\" with the captain's response."

  # Only a Mission actually waiting on a human can be answered.
  [ "$(json_raw "$STATE" awaitingHuman)" = "true" ] \
    || die "mission '$MISSION_ID' is not awaiting a human — there is nothing to answer."
  [ -f "$PENDING" ] || die "mission '$MISSION_ID' has awaitingHuman set but no pending.json — its gate is corrupt."

  local stage; stage="$(json_str "$PENDING" stage)"; stage="${stage:-unknown}"

  # Persist the answer next to the question(s) so the resuming stage consumes
  # it. answers.json mirrors pending.json's stage + questions and adds the
  # captain's free-form answer; the resuming stage deletes it once used.
  local esc; esc="$(json_escape "$ANSWER")"
  {
    echo '{'
    printf '  "stage": "%s",\n' "$stage"
    printf '  "answeredAt": "%s",\n' "$NOW"
    printf '  "answer": "%s",\n' "$esc"
    echo '  "questions": ['
    awk 'NF{ gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); q[++n]=$0 }
         END{ for(i=1;i<=n;i++) printf "    \"%s\"%s\n", q[i], (i<n?",":"") }' \
      < <(read_questions "$PENDING")
    echo '  ]'
    echo '}'
  } >"$MISSION_DIR/answers.json"

  # Clear the gate — but DO NOT touch the stage. The Mission stays parked at the
  # stage that escalated; `lcars run` re-enters it and consumes answers.json.
  state_del awaitingHuman
  state_del pendingQuestion

  gh_remove_awaiting

  echo "RESPOND: answered $MISSION_ID"
  echo "  Recorded your answer in answers.json (stage unchanged)."
  echo "  Stage:  $stage"
  echo "  Run \`lcars run $MISSION_ID\` to resume $stage — it will consume your answer, not re-ask."
  [ -n "$RELABEL_NOTE" ] && echo "$RELABEL_NOTE"
  exit 0
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-}"; [ $# -gt 0 ] && shift

MISSION_ID=""; ANSWER=""; ANSWER_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)   MISSION_ID="${2:-}"; shift 2 ;;
    --mission=*) MISSION_ID="${1#--mission=}"; shift ;;
    --answer)    ANSWER="${2:-}"; ANSWER_SET=1; shift 2 ;;
    --answer=*)  ANSWER="${1#--answer=}"; ANSWER_SET=1; shift ;;
    *)           die "unknown argument: $1" ;;
  esac
done

case "$SUB" in
  show|answer) [ -n "$MISSION_ID" ] || die "no mission id — pass --mission <id>." ;;
esac

case "$SUB" in
  list)   cmd_list ;;
  show)   cmd_show ;;
  answer) cmd_answer ;;
  ''|*)   die "unknown subcommand '${SUB:-}'. Usage: respond.sh list | show --mission <id> | answer --mission <id> --answer \"<text>\"." ;;
esac
