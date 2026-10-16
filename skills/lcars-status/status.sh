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

# --- S146: the ONE repo-level test-readiness header line --------------------
# Snapshot mode only. Computed by the SHARED verdict in lcars-common.sh (the
# same one init/update/the board use), so this view can never disagree with
# them. Silent when ready — a ready board is byte-identical to before. Repair
# voice (⚠ TEST SYSTEMS OFFLINE + the fix verb) for broken/missing; bootstrap
# voice for a greenfield repo (status, never an alarm). Purely a header — it
# never gates: filing/running missions proceeds regardless.
if [ "$MODE" = "snapshot" ]; then
  COMMON_LIB="${LCARS_COMMON_LIB:-$(dirname "$0")/../lcars-init/lcars-common.sh}"
  if [ -f "$COMMON_LIB" ]; then
    TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
    # shellcheck source=skills/lcars-init/lcars-common.sh
    . "$COMMON_LIB"
    lcars_test_readiness "$LCARS_DIR/config.json"
    READINESS_LINE="$(lcars_readiness_line)"
    [ -n "$READINESS_LINE" ] && printf '%s\n' "$READINESS_LINE"
  fi
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
# S207 R4 — THE RECORD SEPARATOR IS NOT A TAB, and that is the whole of the
# "TITLE header skew". These records were tab-separated and read back with
# `IFS=$'\t' read -r …`; TAB IS IFS WHITESPACE, so bash COLLAPSES a run of them
# and drops empty leading/trailing fields. A row with no status glyph therefore
# lost that field entirely and every later field shifted left by one: the TITLE
# was printed into the 4-wide glyph column, four columns off its own header, on
# every ordinary (unpaused, ungated) mission — i.e. on almost every row LCARS
# has ever printed. A non-whitespace separator has no such rule: empty fields
# survive, and the split is positional. US (0x1f) is the ASCII unit separator,
# is not legal unescaped inside a JSON string, and cannot appear in a title.
RS=$'\037'
PAUSE_GLYPH="⏸"
ASK_GLYPH="❓"
STANDBY_GLYPH="◇"
FAILED_GLYPH="✖"

# S218 fix round 1 (F2) — the Stage failure the drive RECORDED: the last
# `error` event in events.jsonl not superseded by a later stage_start (a new
# run), stage_done (a Stage finished) or gate (the run stopped on a question).
# The SAME fact the board card reads (local_adapter._stage_failure). Prints
# "<stage>\t<log>" (log may be empty), or nothing. Reads the event's TYPE and
# fields — emit_event's own one-line shape — never the sentence's words.
stage_failure() { # events.jsonl
  [ -f "$1" ] || return 0
  awk '
    function field(k,   p, r) {
      p = index($0, "\"" k "\":\"")
      if (p == 0) return ""
      r = substr($0, p + length(k) + 4)
      sub(/".*/, "", r)
      return r
    }
    {
      t = field("type")
      # (fix round 2, D2: only an error the drive MARKED — "stageFailure":1 —
      # counts; unmarked pre-S214 history is never surfaced.)
      if (t == "error" && index($0, "\"stageFailure\":1") > 0) { st = field("stage"); lg = field("log"); f = 1 }
      else if (t == "stage_start" || t == "stage_done" || t == "gate") f = 0
    }
    END { if (f) printf "%s\t%s\n", st, lg }
  ' "$1"
}
# A live driver holds <mission>/driver.lock/pid — a new run is under way, so
# the last failure is not the news (mirrors local_adapter._driver_running).
driver_live() { # mission-dir
  local pid; pid="$(cat "$1/driver.lock/pid" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

rows=()
questions=()  # "id\tissue\tquestion" for the awaiting-human footer
# S188 fix round 2. A refresh that cannot BUILD a part of the issue body (an
# interrupted re-grill left a 0-byte prd.md; estimate.json went missing and
# there is no record of the last pushed body to carry the section forward)
# refuses the push and drops a breadcrumb in the mission dir. Both call sites
# are `>/dev/null 2>&1 || true`, so that refusal reached NOBODY — the file had
# zero readers anywhere in skills/ or web/, which is how an honest scope cut
# could be refused at five consecutive transfer points in silence while the
# issue quietly kept the old spec. This view is where the captain already looks
# for "what is wrong with my missions", so it reads it. Cheap: one file read per
# mission, no gh call, no new file.
refusals=()   # "id\tissue\tpart\twhy\tfix"
failures=()   # "id\tissue\tstage\tlog" — S218: a Stage that stopped on a failure
carried=()    # "id\tissue\tlabel\tfix" — parts a push CARRIED rather than rebuilt
any_glyph=0   # did any rendered row carry a status glyph? gates the legend
any_paused=0  # did any row carry the live pause glyph?
any_standby=0 # did any row carry the standby (parked / awaiting-alignment) glyph?
any_failed=0  # did any row carry the failed glyph? (S218)
for s in "${states[@]}"; do
  id="$(json_str "$s" id)"
  [ -n "$id" ] || id="$(basename "$(dirname "$s")")"
  title="$(json_str "$s" title)"
  stage="$(json_str "$s" stage)"
  state_stage="$stage"
  created="$(json_str "$s" created)"
  issue="$(json_raw "$s" githubIssue)"
  paused="$(json_raw "$s" paused)"
  question="$(json_str "$s" pendingQuestion)"
  # A PARKED mission (`lcars file --park`) sits at stage "align" but has no PRD
  # yet — it is on STANDBY, awaiting the Align grill. It reads as a distinct
  # row state (a ◇ glyph + an "awaiting alignment" stage cell), never as a
  # runnable align card.
  prdpending="$(json_raw "$s" prdPending)"

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
  # S207 R2 — `0` IS NOT AN ISSUE NUMBER. GitHub numbers issues from 1, so a
  # `"githubIssue": 0` is the absence of one written down (a shell arithmetic
  # default that reached disk). Rendered `#0` it read as a real issue and the
  # footer offered it too — a link to nothing.
  case "$issue" in
    ''|null|0) issue_disp="-" ;;
    *)         issue_disp="#$issue" ;;
  esac

  # status glyph: paused and/or awaiting-human (awaiting requires a question)
  glyph=""
  if [ "$paused" = "true" ] && [ "$state_stage" != "done" ]; then
    glyph="$PAUSE_GLYPH"
    any_paused=1
  fi
  if [ -n "$question" ]; then
    glyph="${glyph:+$glyph}$ASK_GLYPH"
    questions+=("$id"$'\t'"$issue_disp"$'\t'"$question")
  fi
  # A parked mission carries the standby glyph and its stage cell reads
  # "awaiting alignment" (rather than the bare "align" of a runnable card).
  if [ "$prdpending" = "true" ]; then
    glyph="${glyph:+$glyph}$STANDBY_GLYPH"
    stage="awaiting alignment"
    any_standby=1
  fi
  # S218 fix round 1 (F2): a Stage that FAILED. The STAGE cell stays the
  # label's (stage from the label, S191) — the row wears ✖ and the footer
  # below says which Stage failed and where its log is.
  sfail=""
  driver_live "$(dirname "$s")" || sfail="$(stage_failure "$(dirname "$s")/events.jsonl")"
  if [ -n "$sfail" ]; then
    IFS=$'\t' read -r fstage flog <<<"$sfail"
    glyph="${glyph:+$glyph}$FAILED_GLYPH"
    any_failed=1
    failures+=("$id"$'\t'"$issue_disp"$'\t'"${fstage:-a stage}"$'\t'"${flog:-}")
  fi
  [ -n "$glyph" ] && any_glyph=1

  # the issue-body refusal breadcrumb, if this mission has one standing
  refused_file="$(dirname "$s")/.issue-body.refused"
  if [ -s "$refused_file" ]; then
    IFS=$'\t' read -r _rts _rissue rpart rwhy rfix <"$refused_file"
    [ -n "${rpart:-}" ] && refusals+=("$id"$'\t'"$issue_disp"$'\t'"$rpart"$'\t'"${rwhy:-}"$'\t'"${rfix:-}")
  fi

  # the carry-forward breadcrumb: the issue IS current, but one of its parts was
  # reused verbatim because its source had gone. Without this the captain got no
  # signal at all that his board pills were a fossil rather than a rebuild — the
  # carry path was completely silent while only the refusal path was loud.
  # One line per carried part, so a body that carried two says so twice.
  carried_file="$(dirname "$s")/.issue-body.carried"
  if [ -s "$carried_file" ]; then
    while IFS=$'\t' read -r _cts _cissue clabel cfix; do
      [ -n "${clabel:-}" ] || continue
      carried+=("$id"$'\t'"$issue_disp"$'\t'"$clabel"$'\t'"${cfix:-}")
    done <"$carried_file"
  fi

  rows+=("$created$RS$id$RS$id$RS$issue_disp$RS$stage$RS$glyph$RS$title")
done

# Sort newest-first by the created+id prefix, then drop that prefix.
sorted="$(printf '%s\n' "${rows[@]}" | sort -r -t"$RS" -k1,2)"

# --- render the table -----------------------------------------------------
RULE="───────────────────────────────────────────────────────────────"

echo "LCARS — Active Missions"
echo "$RULE"
# STAGE column is 19 wide so the longest stage label — the parked "awaiting
# alignment" (18 chars) — still gets a separating space before the glyph column
# instead of gluing into it (e.g. "awaiting alignment◇ Title").
#
# S196 — the ID column is 27, not 22. A mission id gained a 5-character
# per-clone suffix (`lcars-YYYYMMDD-NNN-<fp>`, 23 chars against the old 18), and
# at 22 the id would have run straight into the ISSUE column with no separating
# space. 27 keeps the same 4-space gutter the old width gave, and a legacy
# 18-char id simply pads further. The SORT above is unaffected: it keys on
# created\tid, and everything up to NNN is still fixed-width, so `…-001-c10e`
# still sorts before `…-002-c10e`.
#
# S207 R1 — the ISSUE column is 9, not 7. `#123456` is SEVEN characters and the
# field was seven wide, so a repo that reached six-digit issue numbers printed
# `#123456implement` with no separating space at all. 9 restores the same
# 2-space gutter a 5-digit issue had, and still fits a 7-digit `#1234567`.
#
# S207 R5 — THE GLYPH CELL IS PADDED BY CHARACTER COUNT, not by `%-4s`. printf
# pads to a BYTE width, and each glyph here is a 3-byte UTF-8 character: one
# glyph got 1 pad byte instead of 3, and TWO glyphs (⏸❓, a paused mission that
# is also awaiting the captain) overflowed the field and printed `⏸❓Title` with
# no space at all. Counting characters guarantees the separating space, and
# leaves a glyphless row exactly 4 cells so it lines up with the TITLE header.
# (A terminal that renders these glyphs double-width still shifts that row by
# the extra cell — a cell LCARS cannot measure from bash; what it can promise,
# and now does, is that the title is never glued to the glyph.)
GLYPH_COL=4
glyph_cell() { # glyph -> the glyph plus its padding, never fewer than one space
  local g="${1:-}" pad=$((GLYPH_COL - ${#1}))
  [ "$pad" -lt 1 ] && pad=1
  printf '%s%*s' "$g" "$pad" ""
}
printf '%-27s%-9s%-19s%s%s\n' "ID" "ISSUE" "STAGE" "$(glyph_cell "")" "TITLE"
while IFS="$RS" read -r _created _sortid id issue stage glyph title; do
  [ -n "$id" ] || continue
  printf '%-27s%-9s%-19s%s%s\n' "$id" "$issue" "$stage" "$(glyph_cell "$glyph")" "$title"
done <<<"$sorted"
echo "$RULE"
# Only show the glyph legend when a row actually carries a glyph — otherwise a
# clean board (no paused / awaiting mission) prints a trailing "paused / awaiting"
# line that reads as if a mission has that status. "Legend:" makes it unmistakably
# a key, not state.
if [ "$any_glyph" -eq 1 ]; then
  legend="Legend: "
  [ "$any_paused" -eq 1 ] && legend="$legend$PAUSE_GLYPH paused    "
  legend="$legend$ASK_GLYPH awaiting your input"
  [ "$any_standby" -eq 1 ] && legend="$legend    $STANDBY_GLYPH awaiting alignment"
  [ "$any_failed" -eq 1 ] && legend="$legend    $FAILED_GLYPH stage failed"
  printf '%s\n' "$legend"
fi

# --- S218 fix round 1 (F2): Stages that stopped on a failure ---------------
# One line per mission whose last run stopped on a Stage failure: which Stage,
# the log that run wrote, and where the whole sentence is.
if [ "${#failures[@]}" -gt 0 ]; then
  echo
  echo "Stopped on a failure:"
  for fl in "${failures[@]}"; do
    IFS=$'\t' read -r xid xissue xstage xlog <<<"$fl"
    xname="$(printf '%s' "$xstage" | awk '{ n = split($0, w, "-"); o = ""; for (i = 1; i <= n; i++) o = o (i > 1 ? " " : "") toupper(substr(w[i], 1, 1)) substr(w[i], 2); print o }')"
    if [ -n "$xlog" ]; then
      printf '  %s (%s): %s failed — log: %s\n' "$xid" "$xissue" "$xname" "$xlog"
    else
      printf '  %s (%s): %s failed.\n' "$xid" "$xissue" "$xname"
    fi
    printf '      → the whole sentence: lcars status --once %s\n' "$xid"
  done
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

# --- issue-body refusals ---------------------------------------------------
# One plain line per mission whose GitHub issue body is NOT current, naming the
# part the composer could not build and what to do about it. Nothing here gates
# anything: the pipeline ran, the mission advanced, only the issue body is
# behind — and it heals itself at the next transfer point once the source is back.
if [ "${#refusals[@]}" -gt 0 ]; then
  echo
  echo "Issue body NOT updated (the mission ran; its GitHub issue is behind):"
  for rf in "${refusals[@]}"; do
    IFS=$'\t' read -r fid fissue fpart fwhy ffix <<<"$rf"
    printf '  %s (%s): could not build %s — %s\n' "$fid" "$fissue" "$fpart" "$fwhy"
    [ -n "$ffix" ] && printf '      → %s\n' "$ffix"
  done
fi

# --- issue-body carry-forwards ---------------------------------------------
# The counterpart of the block above, and the quieter half of the same story:
# the issue IS current, but a part of it could not be rebuilt and was reused
# from the last body this repo pushed. Nothing is wrong and nothing is gated —
# but the captain should know that (say) his board pills are the ones last
# pushed rather than a fresh estimate, and how to make them a rebuild again.
if [ "${#carried[@]}" -gt 0 ]; then
  echo
  echo "Issue body pushed with CARRIED-FORWARD parts (a source was missing, so the part the issue already carried was reused):"
  for cf in "${carried[@]}"; do
    IFS=$'\t' read -r cid cissue clabel cfix <<<"$cf"
    printf '  %s (%s): %s\n' "$cid" "$cissue" "$clabel"
    [ -n "$cfix" ] && printf '      → %s\n' "$cfix"
  done
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

# --- the ONE rendering (ADR-004) --------------------------------------------
# now() / ev_str / ev_num / read_waves_totals / render_human / fmt_elapsed /
# compute_progress / is_terminal are FACTORED into the sourced shared renderer
# beside this script, so `lcars status --watch/--once`, the kanban card, AND the
# issue-comment mirror all render from the SAME primitives and can never drift
# (ADR-004's "ONE rendering" principle). The functions read the EVENTS / WAVES
# path globals set just above. $LCARS_RENDER_LIB overrides the path for tests.
RENDER_LIB="${LCARS_RENDER_LIB:-$(dirname "$0")/render.sh}"
# shellcheck source=skills/lcars-status/render.sh
. "$RENDER_LIB"

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
