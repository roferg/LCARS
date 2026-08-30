#!/usr/bin/env bash
#
# comment-mirror.sh — Session 65 REDESIGN. The RICH, LIVING (edit-in-place)
# per-stage issue-comment mirror that REPLACES the rejected thin "one terse
# comment per event" stream.
#
# This file is SOURCED into run.sh (it reuses run.sh's MISSION_DIR / STATE /
# json_str / json_raw / emit_event / host / now and the SHARED renderer's
# compute_progress). It DEFINES functions and runs no code at source time.
#
# --- the model ----------------------------------------------------------------
# ONE GitHub issue comment per STAGE (research, plan, schedule, implement,
# verify), CREATED once when the stage first needs a comment — that creation is
# the per-stage notification ping — then EDITED IN PLACE as the stage progresses.
# A whole mission produces ~5-6 comments total, each self-updating, NOT dozens.
#
#   * The Implement comment is a LIVE WAVE DASHBOARD: the shared compute_progress
#     line + a ticket checklist (#-linked sub-issues, done/in-progress/pending),
#     completed waves folded into <details>. It refreshes on every ticket event
#     AND on a ~60s heartbeat so elapsed/pace advance during a long attempt.
#   * Research / Plan / Schedule / Verify carry rich, collapsed <details> bodies.
#   * A human-gate raise posts a NEW (ping) comment — editing does NOT notify on
#     GitHub, so a gate must surface as a fresh comment to ping the captain.
#
# --- the idempotency truth: comments.json -------------------------------------
# A stage→comment-id map at $MISSION_DIR/comments.json (jq-free, same style as
# the other state files). First time a stage's comment is needed: CREATE (POST
# via the host adapter's issue-comment-create, which echoes the new id) and
# record the id. Every later render: EDIT (PATCH) that id via issue-comment-edit.
# This map IS the dedup/idempotency truth — a re-run reuses stored ids and edits,
# never double-creating. (Gates record a per-gate key too, so a re-run never
# re-pings.) emit_event and the events.jsonl schema are UNTOUCHED; we READ events
# for progress.
#
# Best-effort throughout: a missing/unauthed/failing gh NEVER breaks or slows the
# run (heartbeat included). Python-free / jq-free / bash-3.2-safe.

# ===========================================================================
# comments.json — the stage→comment-id map (+ gate ping keys)
# ===========================================================================
# Shape (one flat object, jq-free, one key per line):
#   {
#     "research": 101,
#     "implement": 104,
#     "gate:3hires-t002": 109
#   }
# Stage keys map a stage to its living comment id. "gate:<key>" entries mark a
# one-time ping already posted (so a re-run never re-pings the same gate).

cm_map_file() { printf '%s' "$MISSION_DIR/comments.json"; }

# cm_get_id <key> → the recorded comment id for a key, or empty.
cm_get_id() { # key
  local f; f="$(cm_map_file)"
  [ -f "$f" ] || return 0
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$f" | head -1
}

# cm_set_id <key> <id> — record/replace a key→id pair. Creates the file if absent.
# Rewrites the whole map (it is tiny) so the key order stays stable and there is
# never a partial line. Guards against an interleaved partial write by writing a
# temp file then mv (atomic rename).
cm_set_id() { # key id
  local f tmp; f="$(cm_map_file)"; tmp="$(mktemp)"
  # Rewrite the whole map: existing pairs minus this key, then the new pair.
  # Deterministic order = first-seen; last value per key wins. Temp+mv = atomic.
  {
    printf '{\n'
    {
      if [ -f "$f" ]; then
        sed -n 's/.*"\([^"]*\)"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1 \2/p' "$f" \
          | grep -v "^$1 "
      fi
      printf '%s %s\n' "$1" "$2"
    } | awk '{ k=$1; v=$2; if(!(k in seen)){seen[k]=1;order[++n]=k} val[k]=v }
             END{ for(i=1;i<=n;i++){ k=order[i]; printf "  \"%s\": %s%s\n", k, val[k], (i<n?",":"") } }'
    printf '}\n'
  } >"$tmp" 2>/dev/null && mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
}

# ===========================================================================
# Create-then-edit: render a stage's body, CREATE on first sight or EDIT after.
# ===========================================================================
# cm_upsert <stage-key> <body>
#   First sight (no recorded id): CREATE via the adapter, record the returned id.
#   Later: EDIT (PATCH) the recorded id in place. Best-effort: a gh failure on
#   CREATE leaves no id recorded (retried next pass); a failed EDIT is swallowed.
#   Bodies pass via STDIN (the adapter POST/PATCHes `-F body=@-`) to dodge argv
#   quoting/length limits. ALWAYS returns 0 (mirroring never fails the run).
cm_upsert() { # stage-key body
  local key="$1" body="$2" issue id
  issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in ''|null|0) return 0 ;; esac

  id="$(cm_get_id "$key")"
  if [ -n "$id" ]; then
    # EDIT in place — best-effort, swallow any failure.
    printf '%s' "$body" | host issue-comment-edit "$id" >/dev/null 2>&1 || true
  else
    # CREATE — capture the new id (empty on a gh failure → retried next pass).
    local newid
    newid="$(printf '%s' "$body" | host issue-comment-create "$issue" 2>/dev/null)"
    if [ -n "$newid" ]; then
      cm_set_id "$key" "$newid"
    fi
  fi
  return 0
}

# ===========================================================================
# Per-stage body renderers — the rich, living comment bodies.
# ===========================================================================

# cm_stage_started <stage> → 0 if events.jsonl shows that stage has begun.
cm_stage_started() { # stage
  local f="$MISSION_DIR/events.jsonl"
  [ -f "$f" ] || return 1
  grep -Eq "\"stage\":\"$1\".*\"type\":\"stage_start\"" "$f"
}

# cm_blockquote <text> — render <text> as a GFM blockquote: EVERY line prefixed
# with "> ". The input may contain literal "\n" escapes (json_str leaves those
# un-decoded) and/or real newlines; both are normalised to real line breaks first
# so a multi-line answer prefixes EACH continuation line — otherwise the lazy
# blockquote breaks and the tail renders as a plain paragraph.
cm_blockquote() { # text
  printf '%s' "$1" \
    | sed 's/\\n/\
/g' \
    | sed 's/^/> /'
}

# cm_render_research → the Research comment body.
# Summary line + a <details> Q&A block listing each question and its answer/
# finding (captured from research/*.json while they exist; pending.json as a
# fallback). Degrades to the "unambiguous — 0 questions" message when absent.
#
# GFM-rendering discipline (BUG A): a `>` blockquote LAZILY CONTINUES onto the
# next non-blank line, so without a BLANK LINE between Q/A blocks **Q2.** and its
# answer get sucked into Q1's quote. Each question therefore stands on its own
# line, its answer is a blockquote directly beneath, and a BLANK LINE separates
# every Q/A block so the blockquote terminates. Multi-line answers have EVERY
# line `>`-prefixed (cm_blockquote) so continuation lines stay inside the quote.
cm_render_research() {
  local rdir="$MISSION_DIR/research" pj="$MISSION_DIR/pending.json"
  local qa="" nq=0
  # Prefer the synthesised research findings (question → recommendation).
  if [ -d "$rdir" ]; then
    local f q rec
    for f in "$rdir"/*.json; do
      [ -f "$f" ] || continue
      q="$(json_str "$f" question)"
      rec="$(json_str "$f" recommendation)"
      [ -n "$q" ] || continue
      nq=$((nq + 1))
      # A blank line BEFORE each block (after the first) terminates the previous
      # block's blockquote; the question stands alone; the answer is a blockquote
      # directly beneath with EVERY line `>`-prefixed.
      qa="$qa
**Q$nq.** $q
"
      if [ -n "$rec" ]; then
        qa="$qa
$(cm_blockquote "$rec")
"
      fi
    done
  fi
  # Fall back to pending.json's questions if no findings were captured yet.
  if [ "$nq" -eq 0 ] && [ -f "$pj" ]; then
    local line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      nq=$((nq + 1))
      # Same blank-line discipline so a future answer never lazily continues.
      qa="$qa
**Q$nq.** $line
"
    done < <(cm_pending_questions "$pj")
  fi

  printf '## 🔬 Research\n\n'
  if [ "$nq" -eq 0 ]; then
    printf '_PRD unambiguous — 0 questions._\n'
    return 0
  fi
  printf '%d question(s) researched.\n\n' "$nq"
  printf '<details><summary>Research Q&A</summary>\n%s\n\n</details>\n' "$qa"
}

# cm_pending_questions <pending.json> — bare question strings, one per line.
cm_pending_questions() { # pending.json
  grep -oE '^[[:space:]]*"[^"]*"[[:space:]]*,?[[:space:]]*$' "$1" 2>/dev/null \
    | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*,?[[:space:]]*$//'
}

# cm_render_plan → the Plan comment body.
# "N tickets across W waves" + a <details> per ticket: id — title, rationale,
# acceptance criteria. Reuses parse_plan_table (id\ttitle\tdesc\tcrit\tdeps).
cm_render_plan() {
  local plan="$MISSION_DIR/plan.json"
  [ -f "$MISSION_DIR/approved-plan.json" ] && plan="$MISSION_DIR/approved-plan.json"
  printf '## 🧩 Plan\n\n'
  if [ ! -f "$plan" ]; then
    printf '_Plan in progress._\n'
    return 0
  fi
  local n; n="$(grep -c '"id"' "$plan" 2>/dev/null)"; n="${n:-0}"
  local w=""
  [ -f "$MISSION_DIR/waves.json" ] && w="$(grep -c '"wave"' "$MISSION_DIR/waves.json" 2>/dev/null)"
  if [ -n "$w" ] && [ "$w" -gt 0 ]; then
    printf '**%s ticket(s) across %s wave(s).**\n\n' "$n" "$w"
  else
    printf '**%s ticket(s).**\n\n' "$n"
  fi
  printf '<details><summary>Tickets</summary>\n\n'
  local line id title crit
  while IFS=$'\t' read -r id title _desc crit _deps; do
    [ -n "$id" ] || continue
    printf -- '- **%s — %s**\n' "$id" "${title:-untitled}"
    if [ -n "$crit" ]; then
      local c
      printf '%s' "$crit" | tr '|' '\n' | while IFS= read -r c; do
        c="$(printf '%s' "$c" | sed 's/^ *//; s/ *$//')"
        [ -n "$c" ] && printf '  - %s\n' "$c"
      done
    fi
  done < <(parse_plan_table "$plan" 2>/dev/null)
  printf '\n</details>\n'
}

# cm_render_schedule → the Schedule comment body.
# Per-wave breakdown with #-links: **Wave 1** — #143 t-001, #144 t-002 …
cm_render_schedule() {
  local waves="$MISSION_DIR/waves.json"
  printf '## 📅 Schedule\n\n'
  if [ ! -f "$waves" ]; then
    printf '_Scheduling…_\n'
    return 0
  fi
  # Walk waves.json: one line per wave, "#<issue> <id>" comma-joined.
  awk '
    /"wave"[[:space:]]*:/ {
      if (cur!="") { printf "**Wave %s** — %s\n\n", cur, items }
      w=$0; gsub(/[^0-9]/,"",w); cur=w; items=""
    }
    /"id"[[:space:]]*:/   { n=split($0,a,"\""); if(n>=4) lastid=a[4] }
    /"issue"[[:space:]]*:/ {
      v=$0; sub(/.*"issue"[[:space:]]*:[[:space:]]*/,"",v); gsub(/[ ,}]/,"",v)
      link=(v=="null" || v=="") ? lastid : ("#" v " " lastid)
      items=(items=="") ? link : (items ", " link)
    }
    END { if (cur!="") printf "**Wave %s** — %s\n", cur, items }
  ' "$waves"
}

# cm_render_implement → the LIVE WAVE DASHBOARD body.
# Heading + the shared compute_progress line + a ticket checklist (#-linked,
# done/in-progress/pending, hire count on the in-progress ticket), completed
# waves folded into <details>, and an auto-refresh footer. Rendered from the
# SHARED renderer (compute_progress) + waves.json + ticket events.
cm_render_implement() {
  local waves="$MISSION_DIR/waves.json" ev="$MISSION_DIR/events.jsonl"

  # current wave from the last wave_start (jq-free)
  local cur_wave=""
  if [ -f "$ev" ]; then
    cur_wave="$(grep '"type":"wave_start"' "$ev" 2>/dev/null | tail -1 \
      | sed -n 's/.*"wave":\([0-9][0-9]*\).*/\1/p')"
  fi
  [ -n "$cur_wave" ] || cur_wave="1"

  # totals for the heading
  local tot_waves=""
  [ -f "$waves" ] && tot_waves="$(grep -c '"wave"' "$waves" 2>/dev/null)"
  [ -n "$tot_waves" ] && [ "$tot_waves" -gt 0 ] || tot_waves="?"

  printf '## ⚙ Implement — Wave %s/%s\n\n' "$cur_wave" "$tot_waves"

  # The shared progress/pace line (single source of truth with the card/watch).
  # compute_progress reads $EVENTS/$WAVES — point them at this mission's files
  # for the duration of the call (the env-prefix scopes them to the subshell).
  local progress
  progress="$(EVENTS="$ev" WAVES="$waves" compute_progress 2>/dev/null)"
  [ -n "$progress" ] && printf '%s\n\n' "$progress"

  # The single CURRENT ticket — the LAST ticket_start that is neither green nor
  # flagged. This is the SAME signal compute_progress uses for `ticket <id>`, so
  # the checklist's in-progress ticket AGREES with the progress line. Computed
  # ONCE here and threaded into the per-wave checklists.
  local cur_ticket; cur_ticket="$(cm_current_ticket "$ev")"

  # Build the per-wave ticket checklists from waves.json + ticket events.
  if [ -f "$waves" ]; then
    # For each wave, render a checklist. Completed waves (all green) fold into
    # <details>; the current/incomplete wave is shown open.
    local wlist; wlist="$(grep -oE '"wave"[[:space:]]*:[[:space:]]*[0-9]+' "$waves" \
      | grep -oE '[0-9]+')"
    local wnum
    for wnum in $wlist; do
      cm_render_wave_checklist "$wnum" "$waves" "$ev" "$cur_wave" "$cur_ticket"
    done
  fi

  # Footer: updated time + auto-refresh note.
  local hhmm; hhmm="$(cm_hhmm)"
  printf '\n_updated %s · auto-refreshes ~1m_\n' "$hhmm"
}

# cm_render_wave_checklist <wave> <waves.json> <events.jsonl> <cur_wave> <cur_ticket>
# One wave's ticket checklist. A fully-green wave that is NOT the current wave is
# folded into <details>; otherwise shown inline. <cur_ticket> is the single
# in-progress ticket (the last non-green/non-flagged ticket_start) — only IT
# renders "(in progress, hire N of 3)". A DONE ticket wears its hire and bounce
# counts only when there is something to say (S173 fix round).
cm_render_wave_checklist() { # wave waves events cur_wave cur_ticket
  local wave="$1" waves="$2" ev="$3" cur="$4" cur_ticket="$5"
  # Gather this wave's tickets as "id<TAB>issue" pairs.
  local pairs; pairs="$(awk -v want="$wave" '
    /"wave"[[:space:]]*:/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
    /"id"[[:space:]]*:/   { n=split($0,a,"\""); if(n>=4) lastid=a[4]; next }
    /"issue"[[:space:]]*:/ {
      if (cur==want) {
        v=$0; sub(/.*"issue"[[:space:]]*:[[:space:]]*/,"",v); gsub(/[ ,}]/,"",v)
        printf "%s\t%s\n", lastid, v
      }
    }' "$waves")"
  [ -n "$pairs" ] || return 0

  # Render each ticket's checklist line + decide if the wave is fully green.
  # FOUR states (BUG B): done | flagged | in-progress (the single cur_ticket
  # only) | pending. A flagged ticket is DISTINCT from in-progress; only the
  # current ticket ever shows "(in progress, …)".
  local body="" all_green=1 id issue mark link state
  while IFS=$'\t' read -r id issue; do
    [ -n "$id" ] || continue
    state="$(cm_ticket_state "$id" "$ev" "$cur_ticket")"
    case "$state" in
      done)  mark="x" ;;
      *)     mark=" "; all_green=0 ;;
    esac
    if [ "$issue" = "null" ] || [ -z "$issue" ]; then link="$id"; else link="#$issue · $id"; fi
    local suffix=""
    case "$state" in
      done)
        # S173 FIX ROUND: a DONE ticket used to render byte-identically whether
        # it took one hire or three hires and two bounces, so the mirror could
        # not answer "how many times did LCARS have to hire, and did anything
        # bounce?" without opening the ticket. It now carries both — and stays
        # SILENT on a clean ticket, so a counter always means something.
        local dw; dw="$(cm_wear "$(cm_ticket_sessions "$id" "$ev")" "$(cm_ticket_bounces "$id" "$ev")")"
        [ -n "$dw" ] && suffix=" _($dw)_"
        ;;
      in-progress)
        # S173: this counter has always counted HIRES (ticket_attempt events =
        # worker dispatches). It now says so. The cap is the hire cap, so the
        # captain can read "how close is this to needing me?" off the suffix —
        # and a historical stream whose index ran past the current cap drops the
        # "of N" rather than printing a nonsense ratio.
        local a; a="$(cm_ticket_sessions "$id" "$ev")"
        local cap="${MAX_WORKER_TRIES:-3}"
        if [ "$a" -le 0 ]; then suffix=" _(in progress)_"
        elif [ "$a" -le "$cap" ]; then suffix=" _(in progress, hire $a of $cap)_"
        else suffix=" _(in progress, hire $a)_"
        fi
        ;;
      flagged)
        local a b btail=""
        a="$(cm_ticket_sessions "$id" "$ev")"
        # S173 FIX ROUND: a flagged ticket is the "something went wrong" case,
        # and the bounce count is WHY. Same silence rule — nothing at 0.
        b="$(cm_ticket_bounces "$id" "$ev")"
        if [ "$b" -eq 1 ]; then btail=", 1 bounce"
        elif [ "$b" -gt 1 ]; then btail=", $b bounces"
        fi
        if [ "$a" -le 0 ]; then suffix=" _(flagged${btail})_"
        elif [ "$a" -eq 1 ]; then suffix=" _(flagged after 1 worker session${btail})_"
        else suffix=" _(flagged after $a worker sessions${btail})_"
        fi
        ;;
      pending) ;;
    esac
    body="$body- [$mark] $link$suffix
"
  done <<EOF
$pairs
EOF

  if [ "$all_green" -eq 1 ] && [ "$wave" != "$cur" ]; then
    printf '<details><summary>Wave %s — done</summary>\n\n%s\n</details>\n' "$wave" "$body"
  else
    printf '**Wave %s**\n%s\n' "$wave" "$body"
  fi
}

# cm_current_ticket <events.jsonl> → the single in-progress ticket id, or empty.
# The ticket of the LAST ticket_start that has neither a ticket_green nor a
# ticket_flagged event. This is the SAME "last ticket_start wins" signal that the
# shared compute_progress uses, so the checklist's in-progress ticket AGREES with
# the progress line's `ticket <id>`. (Tickets in a wave run SEQUENTIALLY, so at
# most one is truly in progress — an earlier started-but-superseded ticket that
# never greened/flagged is NOT current and renders as pending.)
cm_current_ticket() { # events
  local ev="$1"
  [ -f "$ev" ] || { printf ''; return 0; }
  local id
  # Walk ticket_start ids in REVERSE order; the first that is neither green nor
  # flagged is the current ticket.
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if cm_ticket_terminal "$id" "$ev"; then continue; fi
    printf '%s' "$id"; return 0
  done < <(grep '"type":"ticket_start"' "$ev" 2>/dev/null \
             | sed -n 's/.*"ticket":"\([^"]*\)".*/\1/p' | sed '1!G;h;$!d')
  printf ''
}

# cm_ticket_terminal <id> <events.jsonl> → 0 if the ticket has greened OR flagged.
cm_ticket_terminal() { # id events
  local id="$1" ev="$2"
  grep -Eq "\"type\":\"ticket_green\".*\"ticket\":\"$id\"|\"ticket\":\"$id\".*\"type\":\"ticket_green\"" "$ev" 2>/dev/null && return 0
  grep -Eq "\"type\":\"ticket_flagged\".*\"ticket\":\"$id\"|\"ticket\":\"$id\".*\"type\":\"ticket_flagged\"" "$ev" 2>/dev/null && return 0
  return 1
}

# cm_ticket_state <id> <events.jsonl> [cur_ticket] → done | flagged | in-progress | pending
#   done        — a ticket_green event exists for the id.
#   flagged     — a ticket_flagged event exists (and no green).
#   in-progress — ONLY the single CURRENT ticket (the last non-terminal
#                 ticket_start, passed in as cur_ticket so every line in a render
#                 agrees on the same current ticket).
#   pending     — everything else: no ticket_start yet, OR a started-but-
#                 superseded ticket that is neither green/flagged NOR current.
cm_ticket_state() { # id events [cur_ticket]
  local id="$1" ev="$2" cur="${3:-}"
  [ -f "$ev" ] || { printf 'pending'; return 0; }
  if grep -Eq "\"type\":\"ticket_green\".*\"ticket\":\"$id\"" "$ev" \
     || grep -Eq "\"ticket\":\"$id\".*\"type\":\"ticket_green\"" "$ev"; then
    printf 'done'; return 0
  fi
  if grep -Eq "\"type\":\"ticket_flagged\".*\"ticket\":\"$id\"" "$ev" \
     || grep -Eq "\"ticket\":\"$id\".*\"type\":\"ticket_flagged\"" "$ev"; then
    printf 'flagged'; return 0
  fi
  # If the caller did not pre-compute the current ticket, derive it now so the
  # function is correct when called standalone (e.g. the Verify build summary).
  [ -n "$cur" ] || cur="$(cm_current_ticket "$ev")"
  if [ -n "$cur" ] && [ "$id" = "$cur" ]; then
    printf 'in-progress'; return 0
  fi
  printf 'pending'
}

# cm_ticket_sessions <id> <events.jsonl> → the HIRE COUNT for the ticket, 0 if
# the stream records none. ONE derivation rule, shared with run.sh's
# ticket_hire_count(), board.js's sessionCount and lcars-status's pace line:
# the NUMBER of ticket_attempt events for the ticket, ANY phase. Every
# ticket_attempt is one real worker DISPATCH.
# S173 FIX ROUND: this used to take the highest `attempt` VALUE, which is NOT
# equivalent — a pre-S133 standoff stream numbers its dispatches PER PHASE, so
# a test-writer + implementer ticket has two events both wearing attempt=1 and
# the max under-counts it as one hire; and any gap in the indices (1, then 3)
# makes the max OVER-count. Counting the events is right on every stream.
# The event TYPE and its `attempt` data key are the WIRE and are unchanged.
cm_ticket_sessions() { # id events
  local id="$1" ev="$2" n=0
  [ -f "$ev" ] || { printf '0'; return 0; }
  n="$(grep -cE "\"type\":\"ticket_attempt\".*\"ticket\":\"$id\"|\"ticket\":\"$id\".*\"type\":\"ticket_attempt\"" "$ev" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# cm_ticket_bounces <id> <events.jsonl> → how many times a proof GATE rejected a
# hire for this ticket and LCARS re-spawned (ticket_gate_bounce events), 0 if
# none. The "something went wrong" signal, counted the same way as the hires.
cm_ticket_bounces() { # id events
  local id="$1" ev="$2" n=0
  [ -f "$ev" ] || { printf '0'; return 0; }
  n="$(grep -cE "\"type\":\"ticket_gate_bounce\".*\"ticket\":\"$id\"|\"ticket\":\"$id\".*\"type\":\"ticket_gate_bounce\"" "$ev" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# cm_wear <hires> <bounces> → the parenthesised counter a ticket line WEARS, or
# nothing at all when nothing went wrong. Same silence rule as the board chip:
# a clean ticket carries no counter, so a counter always MEANS something.
cm_wear() { # hires bounces
  local a="${1:-0}" b="${2:-0}" out=""
  [ "$a" -gt 1 ] && out="$a worker sessions"
  if [ "$b" -gt 0 ]; then
    if [ "$b" -eq 1 ]; then out="${out:+$out, }1 bounce"; else out="${out:+$out, }$b bounces"; fi
  fi
  printf '%s' "$out"
}

# cm_render_verify → the Verify comment body.
# Acceptance-criteria checklist (from the plan) + a per-wave build summary + the
# two next moves. A fresh ping-worthy comment.
cm_render_verify() {
  local plan="$MISSION_DIR/approved-plan.json"
  [ -f "$plan" ] || plan="$MISSION_DIR/plan.json"
  printf '## ✅ Verify — ready for review\n\n'

  if [ -f "$plan" ]; then
    printf '<details><summary>Acceptance criteria</summary>\n\n'
    local id title crit c
    while IFS=$'\t' read -r id title _desc crit _deps; do
      [ -n "$id" ] || continue
      [ -n "$crit" ] || continue
      printf '%s' "$crit" | tr '|' '\n' | while IFS= read -r c; do
        c="$(printf '%s' "$c" | sed 's/^ *//; s/ *$//')"
        [ -n "$c" ] && printf -- '- [x] %s\n' "$c"
      done
    done < <(parse_plan_table "$plan" 2>/dev/null)
    printf '\n</details>\n\n'
  fi

  # Per-wave build summary from waves.json + ticket events.
  local waves="$MISSION_DIR/waves.json" ev="$MISSION_DIR/events.jsonl"
  if [ -f "$waves" ]; then
    printf '**Build summary**\n'
    local wlist wnum; wlist="$(grep -oE '"wave"[[:space:]]*:[[:space:]]*[0-9]+' "$waves" | grep -oE '[0-9]+')"
    for wnum in $wlist; do
      local g=0 t=0 pairs id issue
      pairs="$(awk -v want="$wnum" '
        /"wave"[[:space:]]*:/ { w=$0; gsub(/[^0-9]/,"",w); cur=w; next }
        /"id"[[:space:]]*:/   { n=split($0,a,"\""); if(n>=4 && cur==want) print a[4] }
      ' "$waves")"
      for id in $pairs; do
        t=$((t + 1))
        [ "$(cm_ticket_state "$id" "$ev")" = "done" ] && g=$((g + 1))
      done
      printf -- '- Wave %s — %s/%s ticket(s) green\n' "$wnum" "$g" "$t"
    done
    printf '\n'
  fi

  printf 'Next: `lcars approve %s` to ship, or `lcars feedback %s` to send back.\n' \
    "$MISSION_ID" "$MISSION_ID"
}

# cm_hhmm → current time as hh:mm (honours $LCARS_NOW for tests).
cm_hhmm() {
  local t; t="$(now)"
  if [ -n "${LCARS_NOW:-}" ]; then
    # Deterministic for tests: derive hh:mm from the pinned epoch (UTC).
    date -u -r "$t" '+%H:%M' 2>/dev/null || date -u -d "@$t" '+%H:%M' 2>/dev/null || printf '%s' "$t"
  else
    date '+%H:%M' 2>/dev/null || printf '%s' "$t"
  fi
}

# ===========================================================================
# Gate ping — a NEW comment when a stage escalates to a human gate.
# ===========================================================================
# A gate must surface as a FRESH comment (editing does not notify on GitHub), so
# the captain is pinged. Idempotent: each distinct gate is keyed in comments.json
# so a re-run never re-pings. The key is a stable hash of the gate's detail.
cm_ping_gate() { # detail
  local detail="$1" issue key
  issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in ''|null|0) return 0 ;; esac
  key="gate:$(cm_hash "$detail")"
  # Already pinged this exact gate? (idempotent)
  [ -n "$(cm_get_id "$key")" ] && return 0
  local body
  body="$(printf '## 🔔 Awaiting your answer\n\n%s\n\nReply with `lcars respond %s`.\n' \
    "$detail" "$MISSION_ID")"
  local newid
  newid="$(printf '%s' "$body" | host issue-comment-create "$issue" 2>/dev/null)"
  [ -n "$newid" ] && cm_set_id "$key" "$newid"
  return 0
}

# cm_hash <text> → a short [0-9a-f]+ digest (stable gate key). Portable.
cm_hash() { # text
  local h
  if command -v shasum >/dev/null 2>&1; then h="$(printf '%s' "$1" | shasum | cut -d' ' -f1)"
  elif command -v sha256sum >/dev/null 2>&1; then h="$(printf '%s' "$1" | sha256sum | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then h="$(printf '%s' "$1" | md5)"
  else h="$(printf '%s' "$1" | cksum | tr -s ' ' '-')"; fi
  # keep it filename/key-safe and short
  printf '%s' "$h" | tr -cd '0-9a-f-' | cut -c1-16
}

# ===========================================================================
# mirror_comments — the driver step. Renders every stage that has begun,
# create-then-edit, and pings any new gate. Idempotent, best-effort, returns 0.
# ===========================================================================
mirror_comments() {
  [ -n "${MISSION_DIR:-}" ] || return 0
  local ev="$MISSION_DIR/events.jsonl"
  [ -f "$ev" ] || return 0

  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in ''|null|0) return 0 ;; esac

  # Render each stage's living comment IF that stage has begun (a stage_start for
  # it is in the log). create-then-edit keyed by stage name in comments.json.
  if cm_stage_started research; then
    cm_upsert research "$(cm_render_research)"
  fi
  if cm_stage_started plan || cm_stage_started plan-review; then
    cm_upsert plan "$(cm_render_plan)"
  fi
  if cm_stage_started schedule; then
    cm_upsert schedule "$(cm_render_schedule)"
  fi
  if cm_stage_started implement; then
    cm_upsert implement "$(cm_render_implement)"
  fi
  # Verify: the stage_done of Implement (or a verify gate) means we're at review.
  if grep -Eq '"stage":"verify"' "$ev" 2>/dev/null \
     || grep -Eq '"stage":"implement".*"type":"stage_done"' "$ev" 2>/dev/null; then
    cm_upsert verify "$(cm_render_verify)"
  fi

  # Gate pings — a NEW comment per distinct gate (idempotent by gate key).
  local line gtype gstage gdetail
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    case "$line" in *'"type":"gate"'*) : ;; *) continue ;; esac
    gdetail="$(ev_str "$line" detail)"
    [ -n "$gdetail" ] && cm_ping_gate "$gdetail"
  done <"$ev"

  return 0
}

# ===========================================================================
# Heartbeat — a bounded, best-effort ~60s ticker re-rendering the Implement
# dashboard so elapsed/pace advance during a long single attempt.
# ===========================================================================
# Lifecycle (reusing status.sh's proven trap/tick_pid discipline):
#   * cm_heartbeat_start sets a trap and spawns a background loop that, every
#     ~$LCARS_COMMENT_HEARTBEAT seconds, re-renders + PATCHes the Implement
#     comment. It records the ticker pid in CM_HEARTBEAT_PID.
#   * cm_heartbeat_stop kills the ticker (trap-safe) — call it on stage
#     exit/halt/gate so no orphan ticker outlives the run.
# The interval honours $LCARS_COMMENT_HEARTBEAT (default 60). Every failure is
# swallowed. Event-driven edits and the heartbeat both PATCH the SAME comment
# from the same on-disk truth (last-write-wins; cm_set_id's temp+mv guards the
# map against interleaved partial writes).
CM_HEARTBEAT_PID=""

cm_heartbeat_interval() {
  local v="${LCARS_COMMENT_HEARTBEAT:-60}"
  case "$v" in ''|*[!0-9]*) v=60 ;; esac
  [ "$v" -ge 1 ] 2>/dev/null || v=60
  printf '%s' "$v"
}

# cm_heartbeat_start — spawn the bounded ticker. Best-effort; no-op without a
# located mission or a githubIssue. $LCARS_COMMENT_HEARTBEAT_TICKS bounds the
# number of ticks (tests set it small; unset = effectively unbounded for a real
# run, which is killed by cm_heartbeat_stop on stage exit).
cm_heartbeat_start() {
  [ -n "${MISSION_DIR:-}" ] || return 0
  local issue; issue="$(json_raw "$STATE" githubIssue)"
  case "$issue" in ''|null|0) return 0 ;; esac

  local interval; interval="$(cm_heartbeat_interval)"
  local maxticks="${LCARS_COMMENT_HEARTBEAT_TICKS:-0}"   # 0 = unbounded

  # The ticker: sleep, re-render the Implement comment, repeat. Bounded by
  # maxticks when set. Every action best-effort (errors swallowed). Runs in a
  # subshell so the trap in the parent can kill it cleanly.
  #
  # BUG-020: the ticker MUST NOT inherit the parent's stdout/stdin. The Implement
  # stage runs inside the driver's command substitution `out="$(… implement …)"`,
  # whose stdout is a PIPE the parent shell reads. A backgrounded child that keeps
  # that pipe open holds the command substitution OPEN even after the stage's main
  # process exits — so the driver's `$(…)` blocks indefinitely behind the ticker
  # (and any `gh` it spawned), and the Implement→Verify handoff never fires. We
  # therefore detach the ticker's fds: stdin from /dev/null, stdout+stderr to
  # /dev/null. It writes nothing to the run anyway (it PATCHes GitHub), so this is
  # lossless — and it guarantees the ticker can never wedge the parent's pipe.
  (
    local i=0
    while :; do
      sleep "$interval" 2>/dev/null || break
      # Only the Implement comment is the live dashboard; refresh just it.
      if cm_stage_started implement; then
        cm_upsert implement "$(cm_render_implement)" 2>/dev/null || true
      fi
      i=$((i + 1))
      [ "$maxticks" -gt 0 ] && [ "$i" -ge "$maxticks" ] && break
    done
  ) </dev/null >/dev/null 2>&1 &
  CM_HEARTBEAT_PID=$!
  return 0
}

# cm_heartbeat_stop — kill the ticker cleanly (no orphan). Idempotent.
# BUG-020: the ticker can have its OWN children mid-tick — a `sleep` and, when it
# fires, a `gh` (via cm_upsert/host). A bare `kill <ticker-pid>` can leave those
# children alive and REPARENTED to init (PPID=1) — exactly the leaked `sleep 60`
# the bug observed. So we kill the ticker AND its children: try the whole process
# group first (the most reliable reap of any reparented descendant), then fall back
# to killing the named child pids. We TERM, give a brief grace, then KILL anything
# that survived — never leaving an orphan behind. All best-effort.
cm_heartbeat_stop() {
  if [ -n "$CM_HEARTBEAT_PID" ]; then
    local pid="$CM_HEARTBEAT_PID"
    CM_HEARTBEAT_PID=""
    # Direct children of the ticker (its current `sleep`/`gh`), captured BEFORE we
    # signal — once the ticker dies they reparent to init and `ps --ppid` loses them.
    local kids; kids="$(ps -o pid= --ppid "$pid" 2>/dev/null | tr -d ' ')"
    # Process-group kill: the ticker subshell shares the parent's pgid in this
    # shell, so we can't blanket-kill the group without killing ourselves. Instead
    # signal the ticker and its captured children explicitly.
    kill -TERM "$pid" 2>/dev/null || true
    local k; for k in $kids; do kill -TERM "$k" 2>/dev/null || true; done
    # Reap the ticker so it doesn't linger as a zombie; bounded — never block.
    wait "$pid" 2>/dev/null || true
    # Hard backstop: anything that ignored TERM gets KILLed (the ticker itself and
    # any still-living captured child). A reparented survivor is the failure mode
    # BUG-020 is about, so we are deliberately thorough here.
    kill -KILL "$pid" 2>/dev/null || true
    for k in $kids; do kill -KILL "$k" 2>/dev/null || true; done
  fi
  return 0
}
