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

# --- argument parse: snapshot (default) vs the live watch view -------------
# The no-arg path is the one-shot snapshot table (unchanged). `--watch [id]`
# tails a single Mission's event stream live; `--once [id]` is its deterministic,
# non-follow sibling (read a fixed events.jsonl, render, print the final progress
# line, exit) — used by tests and for a quick "where is it now?" without a tail.
MODE="snapshot"
WATCH_SEL=""
# Watch re-render cadence (seconds). The live `--watch` view re-renders the
# frame every WATCH_INTERVAL seconds so `elapsed` advances; it does NOT control
# how often we poll for `q` / honour the SIGINT trap (that stays a ~1s step —
# see the follow loop). Resolution: --interval flag > $LCARS_WATCH_INTERVAL env
# > the 60s default. The captain almost never wants a 1s busy-render; 60s keeps
# a backgrounded watch quiet while still moving the clock.
WATCH_INTERVAL_FLAG=""
# --watch / --once take an optional positional selector; --watch additionally
# accepts `--interval <secs>` anywhere after it. Parse flags in a small loop so
# order doesn't matter (`--watch --interval 5 <id>` and `--watch <id> --interval
# 5` are both fine).
case "${1:-}" in
  --watch) MODE="watch"; shift ;;
  --once)  MODE="once";  shift ;;
esac
if [ "$MODE" = "watch" ] || [ "$MODE" = "once" ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval) shift; WATCH_INTERVAL_FLAG="${1:-}"; shift ;;
      --interval=*) WATCH_INTERVAL_FLAG="${1#--interval=}"; shift ;;
      *) [ -z "$WATCH_SEL" ] && WATCH_SEL="$1"; shift ;;
    esac
  done
fi

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

# The empty-board message is a snapshot affordance; in watch/once mode the
# shared resolver decides what to do when there are no candidates (it prints its
# own "no … mission" diagnostic), so don't short-circuit here.
if [ "$MODE" = "snapshot" ] && [ "${#states[@]}" -eq 0 ]; then
  echo "No active missions. Run \`lcars file\`."
  exit 0
fi

# --- tiny JSON field readers (no jq dependency, same style as file.sh) ----
# (shared by snapshot + watch/once)
# json_str  pulls a "key": "value" string; json_raw pulls a bare token
# (number / true / false / null). Both take the first match.
json_str() { # file key
  # Scan for the first  "key": "  then read the string body up to the closing
  # quote, treating a backslash-escaped quote (\") as part of the value rather
  # than its end — and decode the common JSON escapes on the way out, so a
  # question like  Say \"Dark\"?  prints in full instead of truncating at the
  # first inner quote. POSIX awk only (no jq, no GNU-isms) so it runs on BSD awk.
  awk -v k="$2" '
    done { next }
    {
      tok = "\"" k "\""
      p = index($0, tok)
      if (p == 0) next
      rest = substr($0, p + length(tok))
      if (match(rest, /^[ \t]*:[ \t]*"/) == 0) next   # not "key": "…", keep looking
      rest = substr(rest, RLENGTH + 1)                # now at the value body
      out = ""; i = 1; n = length(rest)
      while (i <= n) {
        c = substr(rest, i, 1)
        if (c == "\\") {                              # an escape sequence
          e = substr(rest, i + 1, 1)
          if      (e == "n") out = out "\n"
          else if (e == "t") out = out "\t"
          else               out = out e              # \" \\ \/ … → the bare char
          i += 2; continue
        }
        if (c == "\"") break                          # unescaped quote ends the value
        out = out c; i += 1
      }
      print out; done = 1
    }
  ' "$1"
}
json_raw() { # file key
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1
}

if [ "$MODE" = "snapshot" ]; then
# --- build the rows -------------------------------------------------------
# Each mission becomes one tab-separated record prefixed with a sort key
# (created\tid) so we can sort newest-first with a plain `sort -r`, breaking
# ties on id. Record fields: id, issue, stage, glyph, title.
PAUSE_GLYPH="⏸"
ASK_GLYPH="❓"

rows=()
questions=()  # "id\tissue\tquestion" for the awaiting-human footer
any_glyph=0   # did any rendered row carry a status glyph? gates the legend
for s in "${states[@]}"; do
  id="$(json_str "$s" id)"
  [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
  title="$(json_str "$s" title)"
  stage="$(json_str "$s" stage)"
  created="$(json_str "$s" created)"
  issue="$(json_raw "$s" githubIssue)"
  paused="$(json_raw "$s" paused)"
  question="$(json_str "$s" pendingQuestion)"

  # When a Mission is parked behind the awaiting-human gate, state.json.stage is
  # the *resume pointer* (e.g. "align", so `lcars run` re-enters Research), not
  # the Stage the card is actually stuck in. pending.json carries the true
  # in-flight stage (e.g. "research") — the same value the board label shows.
  # Display that, so this view agrees with the Kanban column. No pending.json →
  # fall back to state.json.stage.
  awaiting="$(json_raw "$s" awaitingHuman)"
  pend="$(dirname "$s")/pending.json"
  if [ "$awaiting" = "true" ] && [ -f "$pend" ]; then
    pstage="$(json_str "$pend" stage)"
    [ -n "$pstage" ] && stage="$pstage"
  fi

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
  [ -n "$glyph" ] && any_glyph=1

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
# Only show the glyph legend when a row actually carries a glyph — otherwise a
# clean board (no paused / awaiting mission) prints a trailing "paused / awaiting"
# line that reads as if a mission has that status. "Legend:" makes it unmistakably
# a key, not state.
if [ "$any_glyph" -eq 1 ]; then
  printf 'Legend: %s paused    %s awaiting your input\n' "$PAUSE_GLYPH" "$ASK_GLYPH"
fi

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

exit 0
fi   # end snapshot mode

# ==========================================================================
# --watch / --once : the live Mission event view
#
# Both modes share one render/compute core so --once (deterministic, used by the
# tests) is correct-by-construction for --watch (live follow). The flow:
#   1. resolve the target Mission via the shared resolver (no id juggling)
#   2. read its events.jsonl + waves.json
#   3. render every event to a concise human line
#   4. compute + print the progress / pace line
# --watch additionally tails the stream, re-rendering on a ~1s tick so `elapsed`
# moves, and stops at a terminal gate / Ctrl-C / `q`.
# ==========================================================================

# --- resolve the target mission ------------------------------------------
# Shared resolver lives one dir up; tests override via $LCARS_RESOLVE_SCRIPT.
RESOLVE_SCRIPT="${LCARS_RESOLVE_SCRIPT:-$(dirname "$0")/../lcars/resolve.sh}"
if [ -x "$RESOLVE_SCRIPT" ] || [ -f "$RESOLVE_SCRIPT" ]; then
  if [ -n "$WATCH_SEL" ]; then
    MISSION_ID="$(bash "$RESOLVE_SCRIPT" --scope active --id "$WATCH_SEL")"; rc=$?
  else
    MISSION_ID="$(bash "$RESOLVE_SCRIPT" --scope active)"; rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    # 2 = ambiguous (table already printed by resolver), 3 = none. Pass through.
    exit "$rc"
  fi
  MISSION_ID="$(printf '%s' "$MISSION_ID" | head -1 | tr -d '[:space:]')"
else
  echo "lcars: resolver not found at $RESOLVE_SCRIPT" >&2
  exit 3
fi

MISSION_DIR="$MISSIONS_DIR/$MISSION_ID"
EVENTS="$MISSION_DIR/events.jsonl"
WAVES="$MISSION_DIR/waves.json"

# --- now() — pinnable clock, mirrors emit_event -----------------------------
now() { if [ -n "${LCARS_NOW:-}" ]; then printf '%s' "$LCARS_NOW"; else date +%s; fi; }

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
# Count wave objects and sum their tickets. POSIX awk; counts "wave": keys and
# "id": keys inside the tickets arrays (every ticket has an id).
#
# read_waves_totals — re-derive (waves_total, waves_tickets) from waves.json on
# stdout as two space-separated numbers (empty fields when waves.json is absent).
# This MUST run per-frame in the live watch: Schedule writes waves.json mid-watch,
# so a value captured once at startup goes stale and the denominator never
# resolves (BUG: live watch stuck at `(0/?)` even after waves.json appears).
# compute_progress calls this each frame so a waves.json that appears is picked up.
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

# --- compute_progress — read EVENTS, print the one progress/pace line --------
# Format (exact substrings asserted by the tests):
#   Wave <cur>/<tot> · ticket <id> (<k>/<n>) · attempt <a> · ~<avg>s avg/ticket · elapsed <…>
compute_progress() {
  [ -f "$EVENTS" ] || return 0

  local first_ts="" cur_wave="" cur_ticket="" cur_attempt="" total_waves_ev=""
  local greens=0 sum=0
  # Events-derived ticket-total fallback: sum ticketCount across DISTINCT
  # wave_start events (one per wave), so the denominator degrades to a best-effort
  # number rather than a bare `?` before Schedule has written waves.json.
  local tickets_ev=0 seen_waves=" "
  # ticket_start timestamps, keyed by ticket id, for green-duration math.
  # bash 3.2 has no assoc arrays → parallel arrays.
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
        # Sum ticketCount once per distinct wave number for the events fallback.
        local tc; tc="$(ev_num "$line" ticketCount)"
        if [ -n "$wave" ] && [ -n "$tc" ]; then
          case "$seen_waves" in
            *" $wave "*) : ;;                            # already counted this wave
            *) tickets_ev=$(( tickets_ev + tc )); seen_waves="$seen_waves$wave " ;;
          esac
        fi
        ;;
      ticket_start)
        ticket="$(ev_str "$line" ticket)"
        [ -n "$ticket" ] && cur_ticket="$ticket"
        cur_attempt=""   # reset attempt counter for the new ticket
        # record its start ts
        st_ids+=("$ticket"); st_ts+=("$ts")
        ;;
      ticket_attempt)
        attempt="$(ev_num "$line" attempt)"; [ -n "$attempt" ] && cur_attempt="$attempt"
        ;;
      ticket_green)
        ticket="$(ev_str "$line" ticket)"
        greens=$(( greens + 1 ))
        # find its matching start ts (last recorded for that id)
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

  # totals: re-read waves.json THIS frame (Schedule may have just written it),
  # preferring it; fall back to the events-derived numbers so the denominator is
  # a best-effort count rather than a bare `?` before Schedule.
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

  # avg/ticket: em dash before any green, else integer mean.
  local avg_field
  if [ "$greens" -gt 0 ]; then
    local avg=$(( (sum + greens/2) / greens ))   # rounded mean
    avg_field="~${avg}s avg/ticket"
  else
    avg_field="—s avg/ticket"
  fi

  # elapsed: now − first event ts
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

# --- render_all — every event's human line, then the progress line ----------
render_all() {
  if [ -f "$EVENTS" ]; then
    local line
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      local human; human="$(render_human "$line")"
      [ -n "$human" ] && printf '%s\n' "$human"
    done <"$EVENTS"
  fi
  echo
  compute_progress
}

if [ "$MODE" = "once" ]; then
  render_all
  exit 0
fi

# --- resolve the re-render interval -----------------------------------------
# flag > env > 60s default. A non-numeric / non-positive value falls back to the
# default rather than wedging the loop on a zero/garbage tick.
resolve_interval() {
  local v=""
  if [ -n "$WATCH_INTERVAL_FLAG" ]; then
    v="$WATCH_INTERVAL_FLAG"
  elif [ -n "${LCARS_WATCH_INTERVAL:-}" ]; then
    v="$LCARS_WATCH_INTERVAL"
  fi
  case "$v" in
    ''|*[!0-9]*) v=60 ;;            # empty or non-digits → default
  esac
  [ "$v" -ge 1 ] 2>/dev/null || v=60   # zero / negative → default
  printf '%s' "$v"
}
WATCH_INTERVAL="$(resolve_interval)"

# Test/debug hook: with $LCARS_WATCH_DEBUG set, print the resolved interval and
# exit before entering the (blocking) follow loop, so a test can assert the
# flag>env>default resolution deterministically without timing a real tail. This
# never fires on the user-facing path (the env var is unset in normal use), so
# the live `--watch` output is unchanged.
if [ -n "${LCARS_WATCH_DEBUG:-}" ]; then
  printf 'WATCH_INTERVAL=%s\n' "$WATCH_INTERVAL"
  exit 0
fi

# --- MODE = watch : live follow ---------------------------------------------
# Clean exit on Ctrl-C / SIGTERM and on `q`. The trap sets a stop flag rather
# than exiting inline so the loop breaks promptly at its next check even from a
# sleep-based (no-TTY) tick — a backgrounded watch must honour SIGINT, not just
# SIGTERM/SIGKILL. The flag-then-break path restores the cursor cleanly.
watch_stop=0
# Trap sets the stop flag AND kills any in-flight tick sleep, then `wait`
# (below) returns immediately — so a backgrounded / no-TTY watch honours SIGINT,
# not just SIGTERM/KILL. (A bare `sleep 1` in the loop is NOT interruptible: a
# script started with `&` ignores SIGINT around a foreground child, so the trap
# only ran between ticks — the watch outlived Ctrl-C. Backgrounding the sleep and
# `wait`ing on it makes the trap fire mid-tick.)
tick_pid=""
trap 'watch_stop=1; [ -n "$tick_pid" ] && kill "$tick_pid" 2>/dev/null' INT TERM

# Initial full render of whatever is already on disk.
clear 2>/dev/null || true
printed_lines=0
render_watch_frame() {
  clear 2>/dev/null || true
  printf 'LCARS — watching %s   (q / Ctrl-C to quit)\n\n' "$MISSION_ID"
  render_all
}
render_watch_frame

# Is stdin a real terminal? When it is, we use a 1s-timeout single-char read so
# `q` stays responsive. When it ISN'T (backgrounded / stdin redirected from a
# file or /dev/null), `read -t 1` returns IMMEDIATELY at EOF and the loop
# busy-spins — thousands of frames a second — so we sleep instead. Either way the
# loop ticks ~once/second and the SIGINT/SIGTERM trap's stop flag is honoured.
stdin_is_tty=0
[ -t 0 ] && stdin_is_tty=1

# Follow loop: poll/sleep in SMALL ~1s steps so `q` stays responsive on a TTY
# and the SIGINT/SIGTERM trap can interrupt a no-TTY tick — but only RE-RENDER
# the frame once a full WATCH_INTERVAL has elapsed (accumulate seconds, render
# when the count rolls over). This keeps signal teardown / busy-spin behaviour
# identical to the old 1s loop while letting the captain dial the visible cadence
# up to the 60s default. We do NOT use one long blocking `sleep $N` — that would
# regress the SIGINT responsiveness the DEFECT #1 test guards. Pure bash, jq-free.
elapsed_ticks=0
while :; do
  [ "$watch_stop" -eq 1 ] && break

  if [ "$stdin_is_tty" -eq 1 ]; then
    # `q` quits; read times out after ~1s so we accumulate a tick toward the
    # next re-render.
    if IFS= read -r -t 1 -n 1 key 2>/dev/null; then
      case "$key" in q|Q) watch_stop=1 ;; esac
    fi
  else
    # No TTY: never read (it'd EOF-spin). Background a 1s sleep and `wait` on it
    # so the loop paces at ~1/sec AND the trap can interrupt the wait the instant
    # SIGINT/SIGTERM arrives (the trap kills $tick_pid; wait returns; we break).
    sleep 1 & tick_pid=$!
    wait "$tick_pid" 2>/dev/null
    tick_pid=""
  fi
  [ "$watch_stop" -eq 1 ] && break

  # Accumulate elapsed seconds; only re-render once a full interval has passed.
  elapsed_ticks=$(( elapsed_ticks + 1 ))
  [ "$elapsed_ticks" -lt "$WATCH_INTERVAL" ] && continue
  elapsed_ticks=0

  # Re-render once per interval (elapsed advances) — cheap for our stream sizes.
  render_watch_frame

  # Stop following once the stream's last event is terminal.
  if [ -f "$EVENTS" ]; then
    last_line="$(tail -1 "$EVENTS" 2>/dev/null)"
    if [ -n "$last_line" ] && is_terminal "$last_line"; then
      echo
      echo "Mission reached a human gate — exiting watch."
      exit 0
    fi
  fi
done

# Clean exit path (q / SIGINT / SIGTERM): newline so the shell prompt isn't
# glued to the last frame, then a non-error exit.
printf '\n'
exit 0
