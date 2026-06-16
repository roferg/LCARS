#!/usr/bin/env bash
#
# render.sh — the ONE rendering of a Mission's live run progress (ADR-004's
# "ONE rendering" principle). SOURCED, never executed: it only DEFINES functions
# and runs no code at source time.
#
# This is the SINGLE SOURCE OF TRUTH for the card / watch / issue-comment views.
# It was factored OUT of status.sh so that BOTH `lcars status --watch/--once`
# AND the issue-comment mirror (skills/lcars-run/comment-mirror.sh) render from
# the EXACT same primitives — the kanban card, the live watch, and the GitHub
# issue comment can never drift.
#
# Contract for a sourcing caller: set the two path globals BEFORE calling the
# event-reading functions, and (optionally) define now() to a pinnable clock:
#   EVENTS   path to the Mission's events.jsonl
#   WAVES    path to the Mission's waves.json
#   now()    a function printing a unix timestamp (overridable for tests). If
#            the caller has not defined one, we define the default below.
#
# Everything here is bash-3.2-safe, jq-free, Python-free.

# --- now() — pinnable clock, mirrors emit_event -----------------------------
# Define a default ONLY if the caller hasn't already provided one (status.sh and
# run.sh both define their own now() that honours $LCARS_NOW; sourcing this must
# not clobber it). `declare -F now` is true when a now() is already in scope.
if ! declare -F now >/dev/null 2>&1; then
  now() { if [ -n "${LCARS_NOW:-}" ]; then printf '%s' "$LCARS_NOW"; else date +%s; fi; }
fi

# --- jq-free field readers over a single JSON line --------------------------
# ev_str <line> <key>  → string value of "key":"..."  (escapes left raw; fine
#                        for our short identifiers/details)
ev_str() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
# ev_num <line> <key>  → unquoted numeric value of "key":N
ev_num() {
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}

# --- waves.json totals ------------------------------------------------------
# read_waves_totals — re-derive (waves_total, waves_tickets) from $WAVES on
# stdout as two space-separated numbers (empty fields when waves.json is absent).
# This MUST run per-frame in the live watch: Schedule writes waves.json mid-watch,
# so a value captured once at startup goes stale and the denominator never
# resolves. compute_progress calls this each frame so a waves.json that appears
# is picked up.
read_waves_totals() {
  local wt="" wk=""
  if [ -f "$WAVES" ]; then
    wt="$(awk '
      { gsub(/[[:space:]]/, ""); buf = buf $0 }
      END {
        n = gsub(/"wave":/, "&", buf)
        print n
      }' "$WAVES")"
    wk="$(awk '
      { gsub(/[[:space:]]/, ""); buf = buf $0 }
      END {
        n = gsub(/"id":/, "&", buf)
        print n
      }' "$WAVES")"
  fi
  printf '%s %s' "$wt" "$wk"
}

# --- render_human <line> — one event → one concise human line ---------------
# Reuse the event's own `detail` verbatim where it reads well; prefix with the
# stage for context. Returns the rendered line on stdout (empty = skip).
render_human() {
  local line="$1" type detail stage
  type="$(ev_str "$line" type)"
  detail="$(ev_str "$line" detail)"
  stage="$(ev_str "$line" stage)"
  case "$type" in
    stage_start)
      printf '▶ %s — %s' "$stage" "${detail:-starting}" ;;
    stage_done)
      printf '✔ %s — %s' "$stage" "$detail" ;;
    wave_start)
      printf '〜 %s' "${detail:-wave starting}" ;;
    ticket_start)
      printf '  • %s' "${detail:-ticket starting}" ;;
    ticket_attempt)
      printf '    ↻ %s' "$detail" ;;
    ticket_green)
      printf '    ✓ %s' "$detail" ;;
    ticket_flagged)
      printf '    ⚑ %s' "$detail" ;;
    gate)
      printf '⏸ %s' "$detail" ;;
    error)
      printf '✖ %s' "$detail" ;;
    *)
      [ -n "$detail" ] && printf '%s' "$detail" ;;
  esac
}

# --- fmt_elapsed <seconds> → "1m40s" / "2h3m4s" -----------------------------
fmt_elapsed() {
  local s="$1" h m sec
  h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); sec=$(( s % 60 ))
  if [ "$h" -gt 0 ]; then
    printf '%dh%dm%ds' "$h" "$m" "$sec"
  else
    printf '%dm%ds' "$m" "$sec"
  fi
}

# --- compute_progress — read $EVENTS, print the one progress/pace line -------
# Format (exact substrings asserted by the tests):
#   Wave <cur>/<tot> · ticket <id> (<k>/<n>) · attempt <a> · ~<avg>s avg/ticket · elapsed <…>
compute_progress() {
  [ -f "$EVENTS" ] || return 0

  local first_ts="" cur_wave="" cur_ticket="" cur_attempt="" total_waves_ev=""
  local greens=0 sum=0
  local tickets_ev=0 seen_waves=" "
  local st_ids=() st_ts=()

  local line type ticket ts wave attempt
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    type="$(ev_str "$line" type)"
    ts="$(ev_num "$line" ts)"
    [ -n "$first_ts" ] || first_ts="$ts"
    case "$type" in
      wave_start)
        wave="$(ev_num "$line" wave)"; [ -n "$wave" ] && cur_wave="$wave"
        local tw; tw="$(ev_num "$line" totalWaves)"; [ -n "$tw" ] && total_waves_ev="$tw"
        local tc; tc="$(ev_num "$line" ticketCount)"
        if [ -n "$wave" ] && [ -n "$tc" ]; then
          case "$seen_waves" in
            *" $wave "*) : ;;
            *) tickets_ev=$(( tickets_ev + tc )); seen_waves="$seen_waves$wave " ;;
          esac
        fi
        ;;
      ticket_start)
        ticket="$(ev_str "$line" ticket)"
        [ -n "$ticket" ] && cur_ticket="$ticket"
        cur_attempt=""
        st_ids+=("$ticket"); st_ts+=("$ts")
        ;;
      ticket_attempt)
        attempt="$(ev_num "$line" attempt)"; [ -n "$attempt" ] && cur_attempt="$attempt"
        ;;
      ticket_green)
        ticket="$(ev_str "$line" ticket)"
        greens=$(( greens + 1 ))
        local i start=""
        for (( i=${#st_ids[@]}-1; i>=0; i-- )); do
          if [ "${st_ids[$i]}" = "$ticket" ]; then start="${st_ts[$i]}"; break; fi
        done
        if [ -n "$start" ] && [ -n "$ts" ]; then
          sum=$(( sum + (ts - start) ))
        fi
        ;;
    esac
  done <"$EVENTS"

  local waves_total waves_tickets
  read -r waves_total waves_tickets < <(read_waves_totals)
  local tot_waves="$waves_total"
  [ -n "$tot_waves" ] || tot_waves="$total_waves_ev"
  [ -n "$tot_waves" ] || tot_waves="?"
  local tot_tickets="$waves_tickets"
  if [ -z "$tot_tickets" ] && [ "$tickets_ev" -gt 0 ]; then tot_tickets="$tickets_ev"; fi
  [ -n "$tot_tickets" ] || tot_tickets="?"
  [ -n "$cur_wave" ] || cur_wave="?"
  [ -n "$cur_ticket" ] || cur_ticket="-"
  [ -n "$cur_attempt" ] || cur_attempt="1"

  local avg_field
  if [ "$greens" -gt 0 ]; then
    local avg=$(( (sum + greens/2) / greens ))
    avg_field="~${avg}s avg/ticket"
  else
    avg_field="—s avg/ticket"
  fi

  local elapsed_field="elapsed —"
  if [ -n "$first_ts" ]; then
    local el=$(( $(now) - first_ts ))
    [ "$el" -lt 0 ] && el=0
    elapsed_field="elapsed $(fmt_elapsed "$el")"
  fi

  printf 'Wave %s/%s · ticket %s (%s/%s) · attempt %s · %s · %s\n' \
    "$cur_wave" "$tot_waves" "$cur_ticket" "$greens" "$tot_tickets" \
    "$cur_attempt" "$avg_field" "$elapsed_field"
}

# --- is_terminal <line> — does this event end the watch? --------------------
is_terminal() {
  local line="$1" type stage
  type="$(ev_str "$line" type)"
  stage="$(ev_str "$line" stage)"
  case "$type" in
    error) return 0 ;;
    gate)  case "$stage" in verify|done) return 0 ;; esac ;;
  esac
  return 1
}
