#!/usr/bin/env bash
#
# lcars answer — the inbox. One list of every pending decision across ALL
# Missions, and one place to clear each. It adds NO stage logic; it lists the
# union and delegates each action to a script already built.
#
# The union of "what needs me" is two kinds of card:
#   • an escalation (awaitingHuman): Research >20, a Validate scope change, a
#     Plan-Review stand-off, a blocked Implement ticket — answered by recording
#     a free-form reply (delegate: respond.sh answer).
#   • the Verify gate (stage = verify): ship it (delegate: approve.sh) or send it
#     back with a note (delegate: feedback.sh).
#
# Subcommands:
#   list                          Read-only. Every pending decision + its actions.
#                                 (the default — bare `lcars answer` lists.)
#   respond  [--mission <sel>] --answer "<text>"
#                                 Record the captain's answer to an escalation.
#   approve  [--mission <sel>]    Ship a Verify card — open the PR, mark Done.
#   send-back [--mission <sel>] --feedback "<text>"
#                                 Send a Verify card back to Align with a note.
#
# --mission is optional: with exactly one pending decision the resolver picks it;
# a partial id / title also resolves. Several → the resolver prints a picker.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_RESPOND_SCRIPT   respond.sh    default: ../lcars-respond/respond.sh
#   LCARS_APPROVE_SCRIPT   approve.sh    default: ../lcars-approve/approve.sh
#   LCARS_FEEDBACK_SCRIPT  feedback.sh   default: ../lcars-feedback/feedback.sh
#   LCARS_RESOLVE_SCRIPT   resolve.sh    default: ../lcars/resolve.sh
#
set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"
RESOLVE="${LCARS_RESOLVE_SCRIPT:-$SKILL_DIR/../lcars/resolve.sh}"
RESPOND_SCRIPT="${LCARS_RESPOND_SCRIPT:-$SKILL_DIR/../lcars-respond/respond.sh}"
APPROVE_SCRIPT="${LCARS_APPROVE_SCRIPT:-$SKILL_DIR/../lcars-approve/approve.sh}"
FEEDBACK_SCRIPT="${LCARS_FEEDBACK_SCRIPT:-$SKILL_DIR/../lcars-feedback/feedback.sh}"

die() { printf 'lcars answer: %s\n' "$1" >&2; exit 1; }

# --- tiny JSON readers (no jq; same decoding awk as status.sh / respond.sh) --
json_str() { # file key
  awk -v k="$2" '
    done { next }
    {
      tok = "\"" k "\""
      p = index($0, tok); if (p == 0) next
      rest = substr($0, p + length(tok))
      if (match(rest, /^[ \t]*:[ \t]*"/) == 0) next
      rest = substr(rest, RLENGTH + 1)
      out = ""; i = 1; n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c == "\\") { e = substr(rest, i + 1, 1)
          if (e == "n") out = out "\n"; else if (e == "t") out = out "\t"; else out = out e
          i += 2; continue }
        if (c == "\"") break
        out = out c; i += 1
      }
      print out; done = 1
    }' "$1"
}
json_raw() { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# Read pending.json's questions, one per line (same line-oriented awk as respond.sh).
read_questions() { # pending.json
  awk '
    /"questions"[[:space:]]*:[[:space:]]*\[/ { inq=1; next }
    inq && /^[[:space:]]*\]/ { inq=0; next }
    inq {
      s=$0; sub(/^[[:space:]]*/,"",s); sub(/[[:space:]]*$/,"",s); sub(/,$/,"",s)
      sub(/^"/,"",s); sub(/"$/,"",s); gsub(/\\"/,"\"",s); gsub(/\\\\/,"\\",s)
      if (s != "") print s
    }' "$1"
}

locate_missions_dir() {
  local gitdir
  gitdir="$(git rev-parse --git-dir 2>/dev/null)" \
    || die "not inside a git repository — run this from a repo root."
  case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
  MISSIONS_DIR="$gitdir/lcars/missions"
}

# Resolve a target Mission from the pending set (escalations + verify gates).
# Sets RESOLVED_MID and returns the resolver's rc — it must NOT exit/die here,
# because callers invoke it directly (not in $(...)), so a die/exit 2 inside a
# command substitution would only kill the subshell and let the caller exec the
# delegate with an empty --mission. The caller branches on the return code at the
# top level (see cmd_respond/cmd_approve/cmd_send_back).
#   0 → RESOLVED_MID set;  2 → picker printed to stderr;  3 → "none" printed.
RESOLVED_MID=""
resolve_pending() { # selector(optional)
  local out rc
  out="$(bash "$RESOLVE" --scope pending ${1:+--id "$1"})"; rc=$?
  case "$rc" in
    0) RESOLVED_MID="$out"; return 0 ;;
    2) echo "Several decisions match — pick one with --mission <id>:" >&2
       printf '%s\n' "$out" | while IFS=$'\t' read -r id title stage note; do
         printf '  %s  %s  (%s)\n' "$id" "$title" "$stage" >&2
       done
       return 2 ;;
    *) printf 'lcars answer: no pending decision%s — `lcars answer` to see the inbox.\n' \
         "${1:+ matches \"$1\"}" >&2
       return 3 ;;
  esac
}

# === subcommand: list =======================================================
cmd_list() {
  locate_missions_dir
  if [ ! -d "$MISSIONS_DIR" ]; then
    echo "Inbox empty — nothing is waiting on you."
    exit 0
  fi

  local found=0 s id title stage awaiting issue pend pq q
  shopt -s nullglob
  for s in "$MISSIONS_DIR"/*/state.json; do
    id="$(json_str "$s" id)"; [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
    title="$(json_str "$s" title)"
    stage="$(json_str "$s" stage)"
    awaiting="$(json_raw "$s" awaitingHuman)"
    issue="$(json_raw "$s" githubIssue)"
    case "$issue" in ''|null) issue="-" ;; *) issue="#$issue" ;; esac
    pend="$(dirname "$s")/pending.json"

    if [ "$awaiting" = "true" ]; then
      # An escalation. pending.json holds the true in-flight stage + question(s).
      [ -f "$pend" ] && { pq="$(json_str "$pend" stage)"; [ -n "$pq" ] && stage="$pq"; }
      found=$((found + 1)); [ "$found" -eq 1 ] && echo "LCARS — Inbox (decisions waiting on you)"
      echo
      printf '  %s (%s) — %s, awaiting your answer\n' "$id" "$issue" "${stage:-unknown}"
      printf '    %s\n' "$title"
      if [ -f "$pend" ]; then
        while IFS= read -r q; do [ -n "$q" ] && echo "      • $q"; done < <(read_questions "$pend")
      else
        pq="$(json_str "$s" pendingQuestion)"; [ -n "$pq" ] && echo "      • $pq"
      fi
      # S202 — NUMBER ONE ALREADY LOOKED AT THIS ONE. When the first officer
      # handed a gate back it recorded why, and what it would do. The inbox is
      # where the captain meets the gate, so it is where that has to be: without
      # it he reads "awaiting your answer" with no idea anyone had already read
      # the record. Both values are READ off state.numberOne — the inbox works
      # nothing out for itself.
      local xo_blk xo_status xo_note
      xo_blk="$(sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$s" | head -1)"
      xo_status="$(printf '%s' "$xo_blk" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      xo_note="$(printf '%s' "$xo_blk" | sed -n 's/.*"note"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      if [ "$xo_status" = "escalated" ] && [ -n "$xo_note" ]; then
        printf '    ◈ Number One handed this one back to you: %s\n' "$xo_note"
      fi
      printf '    → answer:  lcars answer respond --mission %s --answer "…"\n' "$id"
    elif [ "$stage" = "verify" ]; then
      # The Verify gate — ship or send back.
      found=$((found + 1)); [ "$found" -eq 1 ] && echo "LCARS — Inbox (decisions waiting on you)"
      echo
      printf '  %s (%s) — verify, ready for your review\n' "$id" "$issue"
      printf '    %s\n' "$title"
      printf '    → approve:   lcars answer approve --mission %s\n' "$id"
      printf '    → send back: lcars answer send-back --mission %s --feedback "…"\n' "$id"
    fi
  done
  shopt -u nullglob

  if [ "$found" -eq 0 ]; then
    echo "Inbox empty — nothing is waiting on you."
    exit 0
  fi
  echo
  exit 0
}

# === subcommand: respond ====================================================
cmd_respond() {
  [ -n "$ANSWER" ] || die "no answer — pass --answer \"<your answer>\"."
  resolve_pending "$MISSION_SEL" || exit $?
  exec bash "$RESPOND_SCRIPT" answer --mission "$RESOLVED_MID" --answer "$ANSWER"
}

# === subcommand: approve ====================================================
cmd_approve() {
  resolve_pending "$MISSION_SEL" || exit $?
  exec bash "$APPROVE_SCRIPT" --mission "$RESOLVED_MID"
}

# === subcommand: send-back ==================================================
cmd_send_back() {
  [ -n "$FEEDBACK" ] || die "no feedback — pass --feedback \"<what to fix>\"."
  resolve_pending "$MISSION_SEL" || exit $?
  exec bash "$FEEDBACK_SCRIPT" --mission "$RESOLVED_MID" --feedback "$FEEDBACK"
}

# --- dispatch --------------------------------------------------------------
SUB="${1:-list}"; [ $# -gt 0 ] && shift

MISSION_SEL=""; ANSWER=""; FEEDBACK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mission)    MISSION_SEL="${2:-}"; shift 2 ;;
    --mission=*)  MISSION_SEL="${1#--mission=}"; shift ;;
    --answer)     ANSWER="${2:-}"; shift 2 ;;
    --answer=*)   ANSWER="${1#--answer=}"; shift ;;
    --feedback)   FEEDBACK="${2:-}"; shift 2 ;;
    --feedback=*) FEEDBACK="${1#--feedback=}"; shift ;;
    *)            die "unknown argument: $1" ;;
  esac
done

case "$SUB" in
  list)             cmd_list ;;
  respond)          cmd_respond ;;
  approve)          cmd_approve ;;
  send-back|sendback) cmd_send_back ;;
  *) die "unknown subcommand '$SUB'. Usage: answer.sh list | respond --answer \"…\" | approve | send-back --feedback \"…\" (each with optional --mission <id>)." ;;
esac
