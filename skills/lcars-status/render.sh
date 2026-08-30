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
    # S173 FIX ROUND — the S133 proof-gate family. Without these arms every one
    # of them hit the `*)` default and printed with NO glyph and NO indent,
    # flush-left among the indented ticket lines, indistinguishable from noise:
    # `lcars status` literally could not show the captain a BOUNCE. Glyphs match
    # the board's proof accents (⊕ accept, ⊗ reject, ⊘ waived, ⤫ bounce).
    ticket_gate_bounce)
      printf '    ⤫ %s' "$detail" ;;
    flip_flop_pass)
      printf '    ⊕ %s' "$detail" ;;
    flip_flop_fail|flip_flop_inconclusive)
      printf '    ⊗ %s' "$detail" ;;
    flip_flop_skipped)
      printf '    ⊘ %s' "$detail" ;;
    # S173 FIX ROUND 2 (N3): the last two survivors of the `*)` default. Once
    # the arms above landed, these were the ONLY ticket-level lines still
    # flush-left — sandwiched between indented neighbours they read as a
    # rendering fault mid-timeline rather than as a category. Same glyph family:
    # ⊕ verified-on-branch (a pass, like flip_flop_pass), ⊜ contract amendment
    # (the declarations reconciled against the diff).
    ticket_postcommit_ok)
      printf '    ⊕ %s' "$detail" ;;
    ticket_test_edits)
      printf '    ⊜ %s' "$detail" ;;
    base_stale)
      # S159 — this drive began against a base that was behind origin. It gets
      # the same ⟳ the guard prints on the CLI, so the timeline reads the way the
      # drive did; the detail already carries the distance and what was done.
      printf '⟳ %s' "$detail" ;;
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

# --- fmt_quiet <seconds> → "8s" / "4m" (coarse, LCARS-voice liveness tail) ---
fmt_quiet() {
  local s="$1"
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  if [ "$s" -lt 60 ]; then printf '%ds' "$s"; else printf '%dm' "$(( s / 60 ))"; fi
}

# --- driver_lock_alive — is a LIVE run driver holding this mission's lock? -----
# Mirrors the web adapter's local_adapter._driver_running() and run.sh's
# acquire_driver_lock reclaim rule EXACTLY: the lock is $MISSION_DIR/driver.lock
# (a directory whose `pid` file names the live driver). Alive iff that pid file
# exists and names a running process (kill -0, no signal sent). A dead/absent lock
# (SIGKILL, crash, OOM, closed terminal) reads NOT alive — the same signal run.sh
# uses to reclaim a stale lock and the web adapter uses to gate `running`.
# SELF-CONTAINED: render.sh is sourced by BOTH status.sh and comment-mirror.sh, so
# this must not depend on run.sh's pid_alive being in scope. Crash-proof: any
# read/parse/probe failure ⇒ not alive (never raises).
driver_lock_alive() { # mission_dir
  local pidf="$1/driver.lock/pid" raw
  [ -f "$pidf" ] || return 1
  raw="$(cat "$pidf" 2>/dev/null | tr -d '[:space:]')"
  case "$raw" in ''|*[!0-9]*) return 1 ;; esac
  [ "$raw" -gt 0 ] 2>/dev/null || return 1
  kill -0 "$raw" 2>/dev/null
}

# --- liveness_tail — the S114 REAL liveness signal for the live watch line ----
# run.sh's hang guard maintains $MISSION_DIR/worker-liveness.json for the CURRENT
# cold worker and REMOVES it on its normal AND hung exits, so its presence means a
# worker is live. Echo a short LCARS-voice phrase describing the worker's output
# activity, with quiet seconds computed HERE from lastOutputTs (mirrors the
# server-side staleness). No file ⇒ prints nothing (the watch line is byte-
# identical to before this round).
#
# S114 HONESTY GATE: a HARD driver death (SIGKILL/crash/OOM/closed terminal) never
# runs the sidecar finalize, and release_driver_lock does NOT remove the sidecar —
# so file-presence ALONE would print "WRITING OUTPUT" for a producing sidecar left
# by a DEAD worker (a flat lie the climbing quiet-seconds never reveals). So we
# gate on the SAME running signal the web adapter's _liveness() uses: a LIVE driver
# lock. When the lock is dead/absent, surface NOTHING — byte-identical to the
# no-file path, mirroring _liveness() returning None. jq-free: the sidecar is a
# single JSON line, parsed with the ev_str/ev_num readers.
liveness_tail() {
  local lf="${LIVENESS:-}"
  [ -n "$lf" ] || lf="$(dirname "$EVENTS")/worker-liveness.json"
  [ -f "$lf" ] || return 0
  # Only a LIVE driver lock (beside the sidecar in the mission dir) may show a
  # pulse; a dead/absent lock means the worker is gone — say nothing.
  driver_lock_alive "$(dirname "$lf")" || return 0
  local line; line="$(cat "$lf" 2>/dev/null)"
  [ -n "$line" ] || return 0
  local state lastout q qh
  state="$(ev_str "$line" state)"
  [ -n "$state" ] || return 0
  lastout="$(ev_num "$line" lastOutputTs)"
  q=0
  if [ -n "$lastout" ]; then q=$(( $(now) - lastout )); [ "$q" -lt 0 ] && q=0; fi
  qh="$(fmt_quiet "$q")"
  case "$state" in
    producing) printf 'WRITING OUTPUT' ;;
    thinking)
      if [ "$q" -ge 3 ]; then printf 'THINKING (quiet %s)' "$qh"; else printf 'THINKING'; fi ;;
    quiet)
      if [ "$q" -ge 240 ]; then printf 'QUIET %s — hang guard watching' "$qh"
      else printf 'QUIET %s' "$qh"; fi ;;
  esac
}

# --- compute_progress — read $EVENTS, print the one progress/pace line -------
# Format (exact substrings asserted by the tests):
#   Wave <cur>/<tot> · ticket <id> (<k>/<n>)[ · hire <a>][ · <b> bounces] · ~<avg>s avg/ticket · elapsed <…>
# S173: <a> is the HIRE count for the CURRENT ticket — how many times LCARS
# cold-spawned a worker for it — and <b> the bounce count, present only when a
# gate actually rejected a hire (silence when nothing went wrong, the same rule
# the board chip and the comment mirror use).
# S173 FIX ROUND: <a> is derived by the ONE shared rule — the NUMBER of
# ticket_attempt events for the ticket, ANY phase (run.sh ticket_hire_count,
# comment-mirror cm_ticket_sessions, board.js sessionCount all agree). It used
# to be the max `attempt` VALUE, which is NOT the same number: a pre-S133
# standoff stream numbers its dispatches per phase (two events, both attempt=1)
# and any gap in the indices makes the max over-count.
compute_progress() {
  [ -f "$EVENTS" ] || return 0

  local first_ts="" cur_wave="" cur_ticket="" total_waves_ev=""
  local greens=0 sum=0 bounces=0
  local tickets_ev=0 seen_waves=" "
  local st_ids=() st_ts=()
  # per-ticket HIRE tallies, parallel arrays (bash 3.2: no associative arrays).
  local hr_ids=() hr_n=()

  local line type ticket ts wave
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
        st_ids+=("$ticket"); st_ts+=("$ts")
        ;;
      ticket_attempt)
        # ONE hire per ticket_attempt EVENT, any phase — tallied per ticket id so
        # a re-entered ticket keeps counting up instead of restarting, and a
        # second ticket_start never resets it.
        local at j found=0
        at="$(ev_str "$line" ticket)"; [ -n "$at" ] || at="$cur_ticket"
        for (( j=0; j<${#hr_ids[@]}; j++ )); do
          if [ "${hr_ids[$j]}" = "$at" ]; then hr_n[$j]=$(( ${hr_n[$j]} + 1 )); found=1; break; fi
        done
        [ "$found" -eq 0 ] && { hr_ids+=("$at"); hr_n+=(1); }
        ;;
      ticket_gate_bounce)
        bounces=$(( bounces + 1 ))
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

  # The current ticket's HIRE count, by the shared rule. ZERO means the stream
  # records no dispatch for it, so the count is UNKNOWN and the field is OMITTED
  # — never floored to a number nobody counted. (In a live run the dispatch
  # event is written before the worker starts, so this is only ever pre-dispatch
  # or a pre-S134 stream.)
  local cur_hires=0 k
  for (( k=0; k<${#hr_ids[@]}; k++ )); do
    if [ "${hr_ids[$k]}" = "$cur_ticket" ]; then cur_hires="${hr_n[$k]}"; break; fi
  done
  local hire_field=""
  [ "$cur_hires" -gt 0 ] && hire_field=" · hire $cur_hires"

  # SILENCE when nothing went wrong: the bounce field appears only when a gate
  # actually rejected a hire.
  local bounce_field=""
  if [ "$bounces" -eq 1 ]; then bounce_field=" · 1 bounce"
  elif [ "$bounces" -gt 1 ]; then bounce_field=" · $bounces bounces"
  fi

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

  # S114: append the REAL liveness tail when a live worker's sidecar exists (no
  # file ⇒ empty ⇒ the line is byte-identical to before this round).
  local live_tail; live_tail="$(liveness_tail)"
  local live_suffix=""
  [ -n "$live_tail" ] && live_suffix=" · ◇ $live_tail"

  printf 'Wave %s/%s · ticket %s (%s/%s)%s%s · %s · %s%s\n' \
    "$cur_wave" "$tot_waves" "$cur_ticket" "$greens" "$tot_tickets" \
    "$hire_field" "$bounce_field" "$avg_field" "$elapsed_field" "$live_suffix"
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
