#!/usr/bin/env bash
#
# comment-mirror.sh — ADR-004: mirror a Mission's run progress onto its GitHub
# issue as ordered, human-readable comments derived from the EXISTING
# append-only events.jsonl, idempotently.
#
# This file is SOURCED into run.sh (it reuses run.sh's MISSION_DIR / STATE /
# json_raw / event_seen / event_count / emit_event / host()). It defines two
# things and DELIBERATELY runs no code at source time:
#
#   render_comment <event-jsonl-line>
#       The ONE rendering. Maps a single events.jsonl line to a human-readable
#       comment body, OR to the empty string for an event type we deliberately
#       do NOT surface. This is the single source of truth for "what a run event
#       reads like to a human" — Session 68's in-app activity feed reuses THIS
#       same mapping so the issue comments and the in-app feed never drift.
#
#   mirror_comments
#       The driver step. Walks events.jsonl in order; for each not-yet-mirrored
#       SURFACED event, posts ONE comment to the Mission's issue via the host
#       adapter's `issue-comment` op, then appends a `comment_mirrored` marker
#       BACK INTO events.jsonl so a re-run never double-posts. Best-effort: a
#       missing/unauthed/failing gh NEVER aborts the run (it just leaves the
#       marker unwritten, so the post is retried on the next pass).
#
# --- the surfaced set, and WHY -------------------------------------------------
# We surface the events that read as meaningful run milestones to the captain
# watching the issue, and SKIP the high-volume internal chatter:
#
#   SURFACED                  reads as
#   --------                  --------
#   stage_start               "▶ Research started"          (stage transitions)
#   stage_done                "✅ Research done — <detail>"
#   gate                      "🔔 Awaiting your answer …"    (a human gate raised)
#   wave_start                "🌊 Wave N started (k tickets)"(wave progress)
#   ticket_start              "• Ticket t-001 started"
#   ticket_green              "✅ Ticket t-001 passed …"
#   ticket_flagged            "⚠️ Ticket t-002 needs attention …"
#
#   SKIPPED (too noisy / not human-meaningful on an issue):
#   ticket_attempt            per-try test-writer/implementer churn (up to 5×/ticket)
#   ticket_postcommit_ok      an internal green re-check that reads as a dup of green
#   ticket_postcommit_red     internal; the human-facing signal is ticket_flagged
#   ticket_replay_conflict    internal rebuild plumbing
#   ticket_rebuild_empty      internal rebuild plumbing
#   error                     surfaced via the notify/gate path, not the feed
#   comment_mirrored          OUR OWN marker — never mirror the mirror
#
# --- per-event vs rolled-up ----------------------------------------------------
# We post ONE COMMENT PER SURFACED EVENT (the simplest correct default ADR-004
# names). Rationale: it is the only shape that stays trivially idempotent and
# incremental against an append-only log — each source line maps to exactly one
# marker and one comment, so "what is not yet mirrored" is a pure per-line test
# (no comment needs to be located and EDITED, which gh cannot do idempotently
# from a stateless re-run). The surfaced set above is already pruned to the
# meaningful milestones, so volume stays low (a handful of stage transitions, a
# wave line, and one line per ticket) — well under the threshold where ADR-004
# would call for per-stage compaction. If a future Mission proves chatty, the
# surfaced set is the single knob to tighten, here, in one place.

# --- the dedup key for a source event -----------------------------------------
# Each surfaced source line gets a stable key recorded in its comment_mirrored
# marker's detail, so the next pass can tell "already posted" from "new":
#       sha<hash-of-rendered-body>
# We key on the SEMANTIC IDENTITY of the comment — a stable hash of the rendered
# body — NOT the physical line number. Why: the harness legitimately RE-EMITS
# certain milestones across invocations. On a real Stage RE-ENTRY (a mission
# halts mid-Implement and the operator re-runs `lcars run <id>`), a FRESH
# stage_start (and, by the same path, stage_done / gate) line is appended to
# events.jsonl with a NEW line number and a NEW ts. A line-number key treats
# that new line as never-seen and double-posts a byte-identical comment
# (BUG #185/#186). The rendered body, by contrast, is IDENTICAL for a re-emitted
# milestone (the heading/detail are the same) → it is correctly skipped, while
# genuinely-distinct events (different stage names, ticket ids, wave numbers are
# all carried IN the body) hash differently → each still posts exactly once. The
# key is matched back with event_seen on the comment_mirrored type, so
# events.jsonl stays the SINGLE dedup truth (no sidecar state, and bash-3.2-safe
# — no associative arrays). emit_event and the event schema are UNTOUCHED.

# Extract a top-level string/number field from one compact JSON line, jq-free.
# (events.jsonl lines are single-line compact JSON, so a line-scoped sed is safe
# here — unlike the multi-line state.json that json_str/json_raw handle.)
cm_field() { # field  line
  local v
  # Try the quoted-string form first (portable BSD/GNU sed — no labels).
  v="$(printf '%s' "$2" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" | head -1)"
  if [ -z "$v" ]; then
    # Fall back to a bare numeric value (e.g. "ts":1000, "wave":1).
    v="$(printf '%s' "$2" | sed -n "s/.*\"$1\":\\([0-9][0-9]*\\).*/\\1/p" | head -1)"
  fi
  printf '%s' "$v"
}

# cm_bodyhash <body> → a stable, single-token hex digest of a comment body.
# This is the dedup key: identical bodies (a re-emitted milestone) hash the
# same; distinct bodies hash differently. Portable — prefers shasum/sha256sum/
# md5, falls back to cksum (always present in POSIX). Output is [0-9a-f]+ only,
# so it embeds safely in a marker detail and in an event_seen regex.
cm_bodyhash() { # body
  local h
  if command -v shasum >/dev/null 2>&1; then
    h="$(printf '%s' "$1" | shasum | cut -d' ' -f1)"
  elif command -v sha256sum >/dev/null 2>&1; then
    h="$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then
    h="$(printf '%s' "$1" | md5)"
  else
    # cksum gives "<crc> <bytes>"; squash whitespace to keep one token.
    h="$(printf '%s' "$1" | cksum | tr -s ' ' '-')"
  fi
  printf '%s' "$h"
}

# render_comment <event-jsonl-line> → a human-readable body, or "" to skip.
# The ONE rendering (S68 reuses it). Pure: reads only the passed line.
render_comment() { # event-line
  local line="$1" type detail data
  type="$(cm_field type "$line")"
  detail="$(cm_field detail "$line")"
  case "$type" in
    stage_start)
      printf '▶️ **%s** started' "$(cm_titlecase "$(cm_field stage "$line")")" ;;
    stage_done)
      printf '✅ **%s** done — %s' \
        "$(cm_titlecase "$(cm_field stage "$line")")" "$detail" ;;
    gate)
      printf '🔔 **Awaiting your answer** — %s' "$detail" ;;
    wave_start)
      printf '🌊 %s' "$detail" ;;
    ticket_start)
      printf '• %s' "$detail" ;;
    ticket_green)
      printf '✅ %s' "$detail" ;;
    ticket_flagged)
      printf '⚠️ Needs attention — %s' "$detail" ;;
    *)
      # Not surfaced (ticket_attempt, *_postcommit_*, replay/rebuild, error,
      # comment_mirrored, anything unknown). Empty body = skip.
      printf '' ;;
  esac
}

# Title-case a stage id for the comment heading (research → Research,
# plan-review → Plan-Review). Pure string munging, no external deps beyond awk.
cm_titlecase() { # word
  printf '%s' "$1" | awk '{
    n=split($0,a,"-"); out="";
    for(i=1;i<=n;i++){ s=a[i];
      out=out (i>1?"-":"") toupper(substr(s,1,1)) substr(s,2) }
    print out }'
}

# mirror_comments — the driver step. Idempotent, append-only, best-effort.
# Requires MISSION_DIR/STATE/json_raw/event_seen/emit_event/host from run.sh.
# ALWAYS returns 0 (mirroring must never fail the run).
mirror_comments() {
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ev="$MISSION_DIR/events.jsonl"
  [ -f "$ev" ] || return 0

  # No issue on file (local-only mission) → nothing to comment on. Quiet no-op.
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in ''|null|0) return 0 ;; esac

  # Walk the log in order. Each surfaced line's dedup key is a stable hash of
  # its RENDERED BODY (the comment's semantic identity), not its physical line
  # number — so a re-emitted milestone (a Stage RE-ENTRY appends a fresh
  # stage_start/stage_done/gate line, new line number + new ts, identical body)
  # is recognised as already-mirrored, while genuinely-distinct events still
  # hash uniquely. We also dedup WITHIN a single pass (a re-emit could appear
  # twice in one already-grown log) by remembering bodies posted this pass.
  local line type body key posted_this_pass="|"
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    type="$(cm_field type "$line")"
    # Our own markers are never mirrored.
    [ "$type" = "comment_mirrored" ] && continue
    body="$(render_comment "$line")"
    [ -n "$body" ] || continue          # not a surfaced type

    # This body's stable dedup key: sha<hash-of-rendered-body>.
    key="sha$(cm_bodyhash "$body")"

    # Already mirrored? events.jsonl IS the dedup truth — ask it. The marker
    # detail is "mirrored sha<hash>", anchored on the body hash, so a re-emitted
    # identical milestone matches and is skipped. Also skip if we already posted
    # this exact body earlier IN THIS pass (markers are appended after, so the
    # log lookup alone wouldn't catch a same-pass re-emit).
    case "$posted_this_pass" in *"|$key|"*) continue ;; esac
    if event_seen comment_mirrored "mirrored $key\""; then
      continue
    fi

    # Post the comment (best-effort). Only on a SUCCESSFUL post do we record the
    # marker — so a transient gh failure leaves the source un-mirrored and the
    # next pass retries it (no lost comments, no double posts).
    if host issue-comment "$issue" --body "$body"; then
      emit_event comment_mirrored "$(cm_field stage "$line")" "mirrored $key"
      posted_this_pass="$posted_this_pass$key|"
    fi
    # On failure: swallow, leave unmarked, keep going. The run proceeds.
  done <"$ev"
  return 0
}
