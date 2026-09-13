#!/usr/bin/env bash
#
# lcars xo — Number One's verb. Engage, stand down, and see who has the conn.
#
#   lcars xo                          the status table
#   lcars xo on [--engine E] [--model M]
#                                     engage Number One for THIS REPO
#   lcars xo on <mission>             clear a per-mission opt-out
#   lcars xo off                      stand the repo down (and every engaged mission)
#   lcars xo off <mission>            opt ONE mission out, standing it down
#   lcars xo answer --mission <id>    take the park: read the record, then ANSWER
#                                     through `lcars respond` or ESCALATE with a
#                                     note and a recommendation (exit 1)
#
# THE DIVISION OF LABOUR (captain ruling, 2026-09-11): the worker REASONS, the
# skill EXECUTES. Nothing in this file asks a model anything. It writes two
# recorded facts and reads them back:
#
#   config.json  "numberOne": {"enabled": true, "engine": "copilot"}   — ONE LINE
#   state.json   "numberOne": {"status": …, "engine": …, "since": …}   — AT THE TOP
#
# WHY ONE LINE IN config.json. `lcars_config_merge` preserves an existing raw
# value by capturing the tail of the line its key sits on (lcars-common.sh), so
# a pretty-printed object would be truncated by the next `lcars update` and the
# config left invalid. `numberOne` is in DESIRED_CONFIG for the matching reason:
# a key absent from that list is DELETED by the merge — the failure S196 paid
# for with cloneId.
#
# WHY AT THE TOP OF state.json. The S189 rule. A last-key corruption bug is
# latent in the state writers; keeping every new key off the end keeps it latent.
#
# WHY NOTHING HERE INFERS. The status table reads `state.numberOne.status` and
# prints it. It never works out what Number One is doing by reading a readout, a
# log or a comment — the producer records, the surface displays.
#
# Dependencies are taken via env so tests can stub them:
#   LCARS_CLAUDE_BIN / LCARS_COPILOT_BIN   the engine probes (lcars-common.sh)
#   LCARS_ASSUME_TTY=1                     force the interactive picker branch
#
# Usage: bash xo.sh [on|off|status] [args]

set -uo pipefail

SELF="${BASH_SOURCE[0]}"
SKILL_DIR="$(cd "$(dirname "$SELF")" && pwd)"

die() { printf 'lcars xo: %s\n' "$1" >&2; exit 1; }

# The shared library: the engine detector (S195) and the config primitives. A
# MISSING library is fatal here and deliberately so — unlike the light lock,
# which degrades to "unenforced", this verb's whole job is to write the config
# correctly, and a fallback writer is exactly how two ways of writing one key
# get into the tree.
COMMON="${LCARS_COMMON_LIB:-$SKILL_DIR/../lcars-init/lcars-common.sh}"
[ -f "$COMMON" ] || die "the shared library is missing at $COMMON — reinstall LCARS (./install.sh)."
# shellcheck disable=SC1090
. "$COMMON"

OWNERSHIP_LIB="${LCARS_OWNERSHIP_LIB:-$SKILL_DIR/../lcars-run/ownership.sh}"

# --- locate .git/lcars ------------------------------------------------------
GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PWD/$GIT_DIR" ;; esac
LCARS_DIR="$GIT_DIR/lcars"
CONFIG="$LCARS_DIR/config.json"
MISSIONS_DIR="$LCARS_DIR/missions"
[ -d "$LCARS_DIR" ] || die "this repo is not initialized for LCARS — run \`lcars init\` first."

# TWO CLOCKS, ON PURPOSE (fix round 1, D4).
#
#   NOW        the RECORD — UTC, ISO-8601, machine-readable, what `since` gets.
#              Two laptops compare these, so they can never be local.
#   NOW_LOCAL  the COPY — the captain's own wall clock, and only ever what a
#              human reads. The stand-down note used to be rendered with
#              `date -u`, so a stand-down at 21:05 read "stood down 04:05" on
#              the card, in the board's `.xo-note` and in this table — all
#              three quote the one stored note, so all three were adrift.
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW_LOCAL="$(date +%H:%M)"

# ===========================================================================
# ONE-LINE JSON OBJECT PRIMITIVES.
#
# Both records this verb owns are single-line objects of flat scalar fields, so
# these four functions are the whole of its JSON handling. They are deliberately
# not a general JSON library: the moment a value could contain a `{`, a `}` or a
# quote these stop being correct, so every WRITER below controls its own values.
# ===========================================================================
obj_get() { # <obj> <key> — a string value, or empty
  printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}
obj_del() { # <obj> <key> — the object without that key
  printf '%s' "$1" \
    | sed -E "s/\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|[^,}]+)[[:space:]]*,?[[:space:]]*//" \
    | sed -E 's/,[[:space:]]*\}/}/; s/\{[[:space:]]*,[[:space:]]*/{/'
}
obj_set() { # <obj> <key> <raw-json-value> — replace or append, order-stable
  local obj="${1:-}" inner
  [ -n "$obj" ] || obj='{}'
  inner="$(obj_del "$obj" "$2")"
  inner="${inner#\{}"; inner="${inner%\}}"
  inner="$(printf '%s' "$inner" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/,$//')"
  if [ -n "$inner" ]; then printf '{%s, "%s": %s}' "$inner" "$2" "$3"
  else printf '{"%s": %s}' "$2" "$3"; fi
}
jstr() { # a JSON string literal for a value this script controls
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

# ===========================================================================
# COLUMN PADDING, BY DISPLAY WIDTH (fix round 1, D5).
#
# `printf '%-12s'` pads to twelve BYTES. The placeholder this file prints for
# "nothing recorded" is an em dash — ONE column, THREE bytes — so every row
# carrying one came out two columns short and the header's NOTE stopped sitting
# above the notes. The header and the rows call `col` now, so a width can only
# be wrong in both places at once, which is a table that still lines up.
#
# WHAT IT COUNTS. UTF-8 continuation bytes (0x80–0xBF) are not columns; every
# other byte is one. That is exact for the characters this table prints —
# ASCII, the em dash, the middle dot — and it does NOT know about double-width
# CJK or combining marks, which nothing here emits. `printf %d "'c"` reads the
# character's value whether bash is handing out bytes (C locale) or whole
# characters (UTF-8 locale), so the count is the same under both.
# ===========================================================================
col_width() { # <string> — its width in terminal columns
  local s="${1:-}" i n=0 v
  for (( i = 0; i < ${#s}; i++ )); do
    printf -v v '%d' "'${s:i:1}"
    # SIGNED on a byte-locale bash (macOS answers -30 for 0xE2), so bring it
    # back into 0–255 before testing the range. Found by running this suite
    # under LC_ALL=C, which is the locale a cron job or a CI box brings.
    [ "$v" -lt 0 ] && v=$((v + 256))
    { [ "$v" -ge 128 ] && [ "$v" -le 191 ]; } && continue
    n=$((n + 1))
  done
  printf '%s' "$n"
}
col() { # <string> <width> — the string padded to <width> display columns
  local s="${1:-}" w="${2:-0}" n
  n="$(col_width "$s")"
  printf '%s' "$s"
  while [ "$n" -lt "$w" ]; do printf ' '; n=$((n + 1)); done
}

# --- the repo's recorded numberOne block ------------------------------------
cfg_block() { lcars_config_get_raw "$CONFIG" numberOne; }
cfg_enabled() {
  case "$(cfg_block)" in *'"enabled"'*'true'*) return 0 ;; esac
  return 1
}
cfg_engine() { obj_get "$(cfg_block)" engine; }
cfg_model()  { obj_get "$(cfg_block)" model; }

# ===========================================================================
# NUMBER ONE'S ENGINE — A REAL PIN, NOT A LABEL (fix round 1, D1).
#
# `numberOne.engine` was recorded by `lcars xo on --engine …`, copied onto the
# mission by the driver at engage, printed on the banner, shown on the card and
# rendered in the living comment — and CONSULTED BY NOTHING. Engine selection
# fell straight through to run.sh's resolve_worker_bin, where the MISSION's own
# `workerBin` wins, so a repo pinned to claude spawned the copilot binary with
# the copilot argv while every surface said claude. The report named an engine
# that did not run.
#
# WHERE THE VALUE COMES FROM. The MISSION's recorded `numberOne.engine` first,
# then the repo's. That order is not a preference — it is the requirement that
# the engine which RUNS is the engine the record SAYS: the banner, the state
# block and the living comment all read the mission's copy, so anything else
# would leave exactly the gap this defect is.
#
# WHAT STILL OUTRANKS IT: the captain's own $LCARS_WORKER_BIN. It is
# per-invocation and unmistakably deliberate — the way he moves one spin by
# hand — and Number One's engine is repo config. So the pin is only exported
# when he has not set one (see cmd_answer).
# ===========================================================================
xo_engine_for() { # <state.json> — Number One's engine, or empty
  local st="${1:-}" e=""
  [ -n "$st" ] && [ -f "$st" ] && e="$(obj_get "$(state_xo_block "$st")" engine)"
  [ -n "$e" ] || e="$(cfg_engine)"
  printf '%s' "$e"
}

# ===========================================================================
# MISSION STATE — the writer, at the TOP of the file (the S189 rule).
#
# Modelled on run.sh's state_set_raw (run.sh:470-484): delete the key's line,
# then re-insert it immediately after the opening brace. S207's aftercare will
# unify the copies of that pair; until it does, this one matches run.sh's shape
# exactly so the unification has nothing to reconcile.
# ===========================================================================
state_xo_block() { # <state.json>
  sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*\({[^}]*}\).*/\1/p' "$1" | head -1
}
state_set_xo() { # <state.json> <one-line-object>
  local st="$1" obj="$2" tmp
  tmp="$(mktemp)"
  grep -v '"numberOne"[[:space:]]*:' "$st" >"$tmp" && mv "$tmp" "$st"
  tmp="$(mktemp)"
  V="$obj" awk 'NR==1{print; printf "  \"numberOne\": %s,\n", ENVIRON["V"]; next} {print}' \
    "$st" >"$tmp" && mv "$tmp" "$st"
}
mission_stage() { sed -n 's/.*"stage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1; }

all_missions() { # every mission id, one per line
  local d
  [ -d "$MISSIONS_DIR" ] || return 0
  for d in "$MISSIONS_DIR"/*/; do
    [ -f "${d}state.json" ] || continue
    basename "${d%/}"
  done
}

# resolve_mission <selector> — an exact id, else a UNIQUE partial. Deliberately
# small: `lcars xo` names one mission at a time and a wrong guess here would
# stand the wrong mission down.
resolve_mission() {
  local sel="$1" hits
  [ -d "$MISSIONS_DIR/$sel" ] && { printf '%s' "$sel"; return 0; }
  hits="$(all_missions | grep -F -- "$sel")"
  case "$(printf '%s\n' "$hits" | grep -c .)" in
    0) die "no mission matching '$sel' under .git/lcars/missions/ — check the id." ;;
    1) printf '%s' "$hits" ;;
    *) die "'$sel' matches more than one mission:
$(printf '%s\n' "$hits" | sed 's/^/  /')
Name one of them exactly." ;;
  esac
}

# ===========================================================================
# STAND DOWN — one mission.
#
# Order matters: SIGNAL FIRST, then record. A worker killed after the state said
# stood-down would be a live process the board swears is gone; a worker killed
# before the record is written is, at worst, a stale `engaged` this same call
# then corrects.
#
# The signal is best-effort and always TERM: a pid file can be stale, the
# process can already be gone, and neither is a reason to refuse to hand the
# conn back. Nothing is ever KILLed — a worker gets to finish its own cleanup.
# ===========================================================================
stand_down() { # <mission-id> [--opt-out]
  local id="$1" optout="${2:-}" dir st obj status pid
  dir="$MISSIONS_DIR/$id"
  st="$dir/state.json"
  [ -f "$st" ] || die "mission '$id' has no state.json — its state is corrupt."
  obj="$(state_xo_block "$st")"
  status="$(obj_get "$obj" status)"

  if [ "$status" = "engaged" ]; then
    pid="$(head -1 "$dir/xo.pid" 2>/dev/null | tr -dc '0-9')"
    if [ -n "$pid" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      rm -f "$dir/xo.pid"
    fi
    obj="$(obj_set "$obj" status "$(jstr stood-down)")"
    obj="$(obj_set "$obj" note "$(jstr "Number One stood down $NOW_LOCAL · you have the conn")")"
    obj="$(obj_set "$obj" since "$(jstr "$NOW")")"
    # THE GATE COMES BACK WITH THE CONN (fix round 1, D4). `lastPending` is the
    # cksum of the gate Number One took, written BEFORE the spin so that a crash
    # cannot buy a second worker. A spin killed HERE never answered anything, so
    # leaving the stamp would lock the first officer out of that gate for ever —
    # it would see its own memory of a question it never got to read. Clearing it
    # is what makes `lcars xo on <id>` able to pick the gate up again.
    obj="$(obj_del "$obj" lastPending)"
    XO_STOOD_DOWN=$((XO_STOOD_DOWN + 1))
    # EVERY ACTION IS JOURNALLED (SKILL.md), and aborting a spin is an action.
    # Without this line the only trace of a mid-spin stand-down was the state
    # note, so the living comment — which renders this journal — had no record
    # that a spin had been stopped at all. Written only on the branch that
    # actually stood something down: the file records what happened.
    journal "$dir" stood-down \
      "$(printf '"stage": %s, "detail": %s' \
           "$(jstr "$(mission_stage "$st")")" \
           "$(jstr "the captain took the conn back")")"
  fi
  [ "$optout" = "--opt-out" ] && obj="$(obj_set "$obj" optOut true)"
  [ -n "$obj" ] && state_set_xo "$st" "$obj"
  return 0
}

# ===========================================================================
# THE ENGINE PICKER.
#
# It NAMES ENGINES AND NOTHING ELSE: `copilot` / `claude`, each installed or
# not installed. No pricing words — not "free", not "billed", not "costs"
# (captain ruling, 2026-09-11). Not everyone's situation is the captain's, and
# a product that prices a choice for you is making the choice for you.
#
# NO TTY AND NO --engine IS A LOUD REFUSAL — the adopt precedent. Picking an
# engine in silence is the defect; failing loudly is the cure.
# ===========================================================================
# engine_at_row <n> — the engine drawn on row <n> of the picker, or rc 1. The
# rows are numbered by their position in $LCARS_ENGINES, so the list the
# captain reads and the list this resolves against are the same list.
engine_at_row() {
  local want="${1:-}" i=0 e
  for e in $LCARS_ENGINES; do
    i=$((i + 1))
    [ "$i" = "$want" ] && { printf '%s' "$e"; return 0; }
  done
  return 1
}

pick_engine() {
  local tty=0 avail def ans e mark n row
  { [ -t 0 ] || [ "${LCARS_ASSUME_TTY:-}" = "1" ]; } && tty=1
  avail="$(lcars_available_engines)"
  if [ "$tty" -eq 0 ]; then
    die "no terminal to ask at, and no \`--engine\` given — Number One is not engaged. Re-run as \`lcars xo on --engine <engine>\`$( [ -n "$avail" ] && printf ' (installed here: %s)' "$(printf '%s' "$avail" | tr '\n' ' ' | sed 's/ *$//')")."
  fi
  # THE DEFAULT IS NOT DECIDED HERE. `lcars_xo_default_engine` (lcars-common.sh)
  # is the one place it is decided, and the daemon spawns the same function to
  # tell the board's picker which row to open on — so pressing Enter at this
  # prompt and pressing ◈ Engage on the board engage the same officer. They did
  # not, before fix round 1: this prompt answered claude and the board answered
  # copilot.
  def="$(lcars_xo_default_engine "$CONFIG")"
  [ -n "$def" ] || die "neither engine is installed on this machine — install the Claude CLI or the Copilot CLI, then run \`lcars xo on\` again."
  printf '\n  ◈ NUMBER ONE — which engine should it use?\n\n' >&2
  n=0
  for e in $LCARS_ENGINES; do
    n=$((n + 1))
    if lcars_engine_available "$e"; then mark="installed"; else mark="not installed"; fi
    if [ "$e" = "$def" ]; then
      printf '    %d. (•) %-8s  %s\n' "$n" "$e" "$mark" >&2
    else
      printf '    %d. ( ) %-8s  %s\n' "$n" "$e" "$mark" >&2
    fi
  done
  printf '\n  Engine [%s]: ' "$def" >&2
  read -r ans || ans=""
  ans="$(printf '%s' "$ans" | tr -d '[:space:]')"
  [ -n "$ans" ] || ans="$def"
  # A ROW NUMBER IS AN ANSWER (fix round 1, D6). The list above is drawn as
  # numbered rows, so `1` is a thing the screen invited — it used to be refused
  # with "'1' is not an engine on this machine", a true sentence about a
  # question nobody asked. The NAME still works, and an empty answer still
  # takes the default; only the reading of a bare digit is new.
  case "$ans" in
    ''|*[!0-9]*) : ;;
    *) row="$(engine_at_row "$ans")" \
         || die "there is no row $ans on that list — answer with 1–$n, or name the engine. Nothing was engaged."
       ans="$row" ;;
  esac
  lcars_engine_available "$ans" \
    || die "'$ans' is not an engine on this machine (installed: ${avail:-none}). Nothing was engaged."
  printf '%s' "$ans"
}

# ===========================================================================
# THE VERBS
# ===========================================================================
XO_STOOD_DOWN=0

write_config_block() { # <enabled true|false> [engine] [model]
  local enabled="$1" engine="${2:-}" model="${3:-}" obj
  obj="{\"enabled\": $enabled}"
  [ -n "$engine" ] && obj="$(obj_set "$obj" engine "$(jstr "$engine")")"
  [ -n "$model" ]  && obj="$(obj_set "$obj" model  "$(jstr "$model")")"
  lcars_config_set_or_add_raw "$CONFIG" numberOne "$obj" \
    || die "could not write .git/lcars/config.json."
}

cmd_on() {
  local engine="" model="" target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --engine)   engine="${2:-}"; shift 2 || true ;;
      --engine=*) engine="${1#--engine=}"; shift ;;
      --model)    model="${2:-}";  shift 2 || true ;;
      --model=*)  model="${1#--model=}"; shift ;;
      -*)         die "unknown option: $1" ;;
      *)          target="$1"; shift ;;
    esac
  done

  # `lcars xo on <mission>` — a per-mission act: PUT THE MISSION BACK IN SCOPE.
  # It does not engage anything by itself. Engaging is the driver's to do at a
  # gate, and a verb that engaged directly would be a second way in for the one
  # thing this round is trying to keep in one place.
  #
  # BACK IN SCOPE MEANS BOTH HALVES (fix round 2). `lcars xo off <mission>`
  # writes TWO facts — the `optOut` flag and the `stood-down` status — and this
  # verb used to undo only the first. `drive_engage_number_one` returns on
  # EITHER, so the mission stayed locked out: the banner never printed, no spin
  # happened, no journal line was written, and the captain had been told in
  # plain words that the mission was back in scope. Fix round 1 cured this same
  # lock-out at `lastPending`; it had not gone away, it had moved to `status`.
  #
  # THE RESTING STATE IS "NEVER STOOD DOWN", NOT A NEW WORD. No status value is
  # invented here: the stand-down's own three fields — `status`, its `note`
  # ("you have the conn") and the `since` that timestamps them — are REMOVED, so
  # what engage-at-drive-start reads is exactly what it reads on a mission that
  # was never stood down, and the status table prints the same `—`. What Number
  # One DID is not erased: `lastAction` and the engine pin stay.
  #
  # ONLY A STAND-DOWN IS UNDONE. `escalated` is a different fact — the captain
  # still has that gate — and clearing it here would re-open the downgrade D9
  # closed. So the status is touched only when it is the one this verb's own
  # counterpart wrote.
  if [ -n "$target" ]; then
    local id st obj
    id="$(resolve_mission "$target")"
    st="$MISSIONS_DIR/$id/state.json"
    obj="$(state_xo_block "$st")"
    if [ -n "$obj" ]; then
      obj="$(obj_del "$obj" optOut)"
      if [ "$(obj_get "$obj" status)" = "stood-down" ]; then
        obj="$(obj_del "$obj" status)"
        obj="$(obj_del "$obj" note)"
        obj="$(obj_del "$obj" since)"
      fi
      state_set_xo "$st" "$obj"
    fi
    printf '◈ NUMBER ONE: %s is back in scope — the opt-out is cleared.\n' "$id"
    cfg_enabled || printf '  Number One is OFF for this repo; run `lcars xo on` to engage it.\n'
    return 0
  fi

  [ -n "$engine" ] || engine="$(pick_engine)" || exit $?
  lcars_engine_available "$engine" \
    || die "'$engine' is not an engine on this machine — nothing was engaged."
  [ -n "$model" ] || model="$(cfg_model)"
  write_config_block true "$engine" "$model"
  printf '◈ NUMBER ONE: ON · %s\n' "$engine"
  [ -n "$model" ] && printf '  model: %s\n' "$model"
  printf '  It takes the conn at a gate and hands it back with a report.\n'
  printf '  Stand it down any time with `lcars xo off`.\n'
}

cmd_off() {
  local target="${1:-}" id
  if [ -n "$target" ]; then
    id="$(resolve_mission "$target")"
    stand_down "$id" --opt-out
    if [ "$XO_STOOD_DOWN" -gt 0 ]; then
      printf '◈ NUMBER ONE: stood down on %s — you have the conn.\n' "$id"
    else
      printf '◈ NUMBER ONE: %s is opted out — it will not be engaged there.\n' "$id"
    fi
    return 0
  fi

  # Repo-level OFF. The ENGINE IS KEPT: the captain turned Number One off, he
  # did not un-choose the engine, and asking him again next time would be the
  # picker becoming theatre (the S196 reasoning, applied here).
  write_config_block false "$(cfg_engine)" "$(cfg_model)"
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    stand_down "$m"
  done <<< "$(all_missions)"
  printf '◈ NUMBER ONE: OFF\n'
  if [ "$XO_STOOD_DOWN" -gt 0 ]; then
    printf '  %d engaged mission(s) stood down — you have the conn.\n' "$XO_STOOD_DOWN"
  fi
}

# The status table. FOUR RECORDED COLUMNS — mission, stage, Number One's status,
# its note. Every one of them is read off disk; none is derived from prose.
cmd_status() {
  if cfg_enabled; then
    printf '◈ NUMBER ONE: ON · %s\n' "$(cfg_engine)"
    [ -n "$(cfg_model)" ] && printf '  model: %s\n' "$(cfg_model)"
  else
    printf '◈ NUMBER ONE: OFF\n'
    printf '  Engage it with `lcars xo on`.\n'
  fi

  local any=0 m st obj status note stage
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    st="$MISSIONS_DIR/$m/state.json"
    [ -f "$st" ] || continue
    if [ "$any" -eq 0 ]; then
      printf '\n  %s %s %s %s\n' "$(col MISSION 26)" "$(col STAGE 13)" \
        "$(col 'NUMBER ONE' 12)" NOTE
      any=1
    fi
    obj="$(state_xo_block "$st")"
    status="$(obj_get "$obj" status)"
    note="$(obj_get "$obj" note)"
    case "$obj" in *'"optOut": true'*) [ -n "$status" ] || status="opted-out" ;; esac
    stage="$(mission_stage "$st")"
    printf '  %s %s %s %s\n' "$(col "$m" 26)" "$(col "${stage:-?}" 13)" \
      "$(col "${status:-—}" 12)" "${note:-—}"
  done <<< "$(all_missions)"
  [ "$any" -eq 1 ] || printf '\n  No missions in this repo yet.\n'
}


# ===========================================================================
# THE ANSWER PATH (S202) — Number One at a park.
# ===========================================================================
#
# THE DIVISION OF LABOUR (captain ruling, 2026-09-11). The worker REASONS; this
# script EXECUTES. Everything below is the executing half: gather the record,
# hire one cold worker through the SAME chokepoint every Stage uses, read its
# one file, CHECK it, and then either answer the gate through `respond.sh` — the
# ordinary verb, the one a human uses — or leave the gate exactly where it was
# and write down why. Nothing here asks a model anything, and nothing here
# writes pending.json, plan.json or a ticket by hand.
#
# WHY THE VERDICT IS CHECKED AND NOT TRUSTED. The prior-art research on
# LLM judges says the failure to expect is not a judge that refuses too often —
# it is a judge that REASONS ITS WAY PAST THE RECORD: a chain of sensible
# inferences, landing somewhere the mission never said, stated with confidence.
# The guard against that is the citation, and a citation is only a guard if
# somebody checks it. So an ANSWER must carry at least one quote that OCCURS,
# verbatim, in the file it names. A verdict that cannot show its line is not a
# verdict: it becomes an escalation, and the captain decides.
#
# THE OTHER DIRECTION IS A REAL COST TOO. Escalating a question the PRD answers
# in one plain sentence wastes the captain's evening, which is the whole thing
# Number One exists to prevent. That is why the check is "is this quote really
# in that file", not "do I agree with the reasoning".
#
# WHAT ALWAYS GOES TO THE CAPTAIN, whatever the worker decided: a gate whose
# `escalationType` is `scope`. Scope and spend are his by ruling, not by
# heuristic — a mission that grows is a decision about his time and his money,
# and no amount of citation makes that Number One's to take.

XO_RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$SKILL_DIR/../lcars-run/run.sh}"
XO_RESPOND_SCRIPT="${LCARS_RESPOND_SCRIPT:-$SKILL_DIR/../lcars-respond/respond.sh}"

# The malformed-verdict note, in ONE place: it is asserted by the suite and read
# by the captain off the card, so the two must be the same string.
XO_MALFORMED="Number One could not decide — malformed verdict"

pending_field() { # <pending.json> <key>
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# --- the read-only INPUT dir -----------------------------------------------
# COPIES, not the originals, and every one of them chmod a-w. Number One is
# reading the record of a mission it must not be able to change; the worker role
# has no shell and no Edit (worker-adapter.sh), and this is the second fence
# behind that one. A copy also means a mid-flight Stage writing to the mission
# cannot move the ground under a verdict half-formed.
gather_inputs() { # <mission-dir> <input-dir>
  local dir="$1" into="$2" f
  mkdir -p "$into"
  for f in prd.md adr.md plan.json validated-plan.md approved-plan.json \
           plan-under-review.json pending.json answers.json estimate.json \
           claim-check.txt reconcile-design-question.txt feedback.md; do
    [ -f "$dir/$f" ] && cp "$dir/$f" "$into/$f"
  done
  if [ -d "$dir/research" ]; then
    mkdir -p "$into/research"
    for f in "$dir"/research/*.json; do
      [ -f "$f" ] && cp "$f" "$into/research/"
    done
  fi
  # The attachments the captain filed WITH the mission — the holodeck drawing and
  # its concept. They are part of what a human at this gate would be looking at.
  if [ -d "$dir/attachments" ]; then
    mkdir -p "$into/attachments"
    for f in "$dir"/attachments/*; do
      [ -f "$f" ] && cp "$f" "$into/attachments/"
    done
  fi
  # THE LAST 200 EVENTS, not all of them. A long mission's events.jsonl is tens
  # of thousands of lines of machinery; the tail is the part that explains why
  # this gate is up, and the head is context the PRD already carries better.
  [ -f "$dir/events.jsonl" ] && tail -200 "$dir/events.jsonl" >"$into/events.jsonl"
  chmod -R a-w "$into" 2>/dev/null || true
  return 0
}

# --- the journal ------------------------------------------------------------
# One JSON line per action, beside the mission's other facts. It is what the
# living comment (wave B) renders and what the captain reads to see what his
# first officer has been doing. Append-only; nothing is ever rewritten.
journal() { # <mission-dir> <action> <one-line-json-body>
  printf '{"at": %s, "action": %s, %s}\n' \
    "$(jstr "$NOW")" "$(jstr "$2")" "$3" >>"$1/number-one.jsonl"
}

# --- the worker's process tree ---------------------------------------------
# `lcars xo off <id>` TERMs the pid in xo.pid (S201). That pid is THIS script,
# because the CLI is a grandchild — run.sh spawns the adapter, the adapter execs
# the CLI — and a TERM to this script alone would leave a live worker the board
# swears is gone. So the trap walks down and TERMs the whole tree, deepest
# first, and nothing is ever KILLed: a worker gets to run its own cleanup.
xo_kill_tree() { # <pid>
  local p="${1:-}" c
  [ -n "$p" ] || return 0
  for c in $(pgrep -P "$p" 2>/dev/null); do xo_kill_tree "$c"; done
  kill -TERM "$p" 2>/dev/null || true
}

XO_SPIN_PID=""
XO_MISSION_DIR=""
on_stand_down() {
  [ -n "$XO_SPIN_PID" ] && xo_kill_tree "$XO_SPIN_PID"
  [ -n "$XO_MISSION_DIR" ] && rm -f "$XO_MISSION_DIR/xo.pid"
  # NOTHING IS RECORDED HERE. `lcars xo off` has already written stood-down, and
  # a second writer racing it is how a stand-down ends up reading `escalated`.
  printf '◈ NUMBER ONE: stood down mid-spin — you have the conn.\n' >&2
  exit 143
}

# Record an escalation and stop. The gate is NOT touched: it is already up, and
# leaving it exactly as the stage raised it is the whole point — the captain
# sees the question the pipeline asked, plus Number One's note beside it.
escalate() { # <mission-dir> <stage> <note> <journal-body>
  local dir="$1" stage="$2" note="$3" body="$4" st obj
  st="$dir/state.json"
  obj="$(state_xo_block "$st")"
  obj="$(obj_set "$obj" status "$(jstr escalated)")"
  obj="$(obj_set "$obj" note "$(jstr "$note")")"
  obj="$(obj_set "$obj" lastAction "$(jstr "escalated $stage $NOW_LOCAL")")"
  obj="$(obj_set "$obj" since "$(jstr "$NOW")")"
  state_set_xo "$st" "$obj"
  journal "$dir" escalated "$body"
  printf '◈ NUMBER ONE: escalated — this one is yours.\n'
  printf '  %s\n' "$note"
  printf '  The gate is still up. Answer it with `lcars respond --mission %s`.\n' \
    "$(basename "$dir")"
  exit 1
}

cmd_answer() {
  local target="" id dir st pending stage etype
  while [ $# -gt 0 ]; do
    case "$1" in
      --mission)   target="${2:-}"; shift 2 || true ;;
      --mission=*) target="${1#--mission=}"; shift ;;
      -*)          die "unknown option: $1" ;;
      *)           target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || die "no mission — pass --mission <id>."
  id="$(resolve_mission "$target")" || exit $?
  dir="$MISSIONS_DIR/$id"
  st="$dir/state.json"
  pending="$dir/pending.json"

  # NO GATE, NO SPIN. Refusing here is the cheapest defence there is against
  # hiring a worker to answer a question nobody asked.
  [ -f "$pending" ] || die "mission '$id' has no pending question — there is no gate for Number One to take."
  stage="$(pending_field "$pending" stage)"
  [ -n "$stage" ] || stage="$(mission_stage "$st")"
  etype="$(pending_field "$pending" escalationType)"

  local work input out
  work="$(mktemp -d)"
  input="$work/input"; out="$work/out"
  mkdir -p "$input" "$out"
  gather_inputs "$dir" "$input"

  XO_MISSION_DIR="$dir"
  trap on_stand_down TERM INT
  printf '%s\n' "$$" >"$dir/xo.pid"

  printf '◈ NUMBER ONE: reading the record for %s (%s gate)…\n' "$id" "${stage:-?}"

  # ONE cold worker, through run.sh's chokepoint — the same road every Stage
  # takes (role → stage key → the pinned model → the fenced argv → the S168
  # fence snapshot → usage capture). Backgrounded and waited on so the TERM trap
  # above can actually fire: bash runs a trap at the first opportunity, and a
  # foreground child would hold that opportunity until the worker finished.
  #
  # THE ENGINE PIN RIDES ALONG (fix round 1, D1). $LCARS_WORKER_BIN carries the
  # engine and $LCARS_WORKER_BIN_INTERNAL=1 says LCARS set it, not the captain —
  # which is what keeps the MISSION's own engineSource/engineResolved/workerBin
  # untouched on the far side. Number One's engine is Number One's.
  #
  # Exported inside a SUBSHELL that wraps nothing but the spawn, so the `lcars
  # respond` call further down still runs with the captain's own environment.
  # (A `VAR=… cmd` prefix cannot do it: the pin is conditional, and a prefix
  # with an empty value would still SET the variable.) The `exec` keeps
  # $XO_SPIN_PID naming the run.sh process itself, so the stand-down trap's
  # kill-tree walk reaches the worker exactly as it did before.
  #
  # An ambient $LCARS_WORKER_BIN the captain set himself wins: the pin is left
  # empty and the ladder over there answers `env`, exactly as today.
  local xo_engine=""
  [ -n "${LCARS_WORKER_BIN:-}" ] || xo_engine="$(xo_engine_for "$st")"
  (
    export LCARS_XO_INPUT_DIR="$input" LCARS_WORKER_INPUT_DIRS="$input"
    if [ -n "$xo_engine" ]; then
      export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
    fi
    exec bash "$XO_RUN_SCRIPT" spawn-number-one \
      --mission "$id" --mode answer --outdir "$out"
  ) >/dev/null 2>&1 &
  XO_SPIN_PID=$!
  wait "$XO_SPIN_PID" 2>/dev/null || true
  XO_SPIN_PID=""
  trap - TERM INT
  rm -f "$dir/xo.pid"

  # --- read the verdict, and CHECK it --------------------------------------
  # THE READER LIVES IN A FILE, not in a heredoc inside `$( … )`. The bash this
  # harness targets (3.2, the one macOS ships) mis-parses a here-document nested
  # in a command substitution, and the failure is a syntax error hundreds of
  # lines away from the cause. Writing the script out first is the cheap cure.
  local verdict="$out/xo-answer.json" report reader="$work/read-verdict.py"
  cat >"$reader" <<'XO_PY'
import json, os, re, sys

path = os.environ.get("LCARS_XO_VERDICT", "")
indir = os.environ.get("LCARS_XO_INPUT", "")

def bad(why):
    print("MALFORMED\t" + why)
    sys.exit(0)

try:
    with open(path) as fh:
        raw = fh.read()
except Exception:
    bad("no verdict file was written")

# A worker that wraps its JSON in a fenced block has still answered; unwrap the
# ONE outermost object rather than refuse over punctuation. Anything else is a
# genuine malformation.
try:
    doc = json.loads(raw)
except Exception:
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        bad("the verdict file is not JSON")
    try:
        doc = json.loads(m.group(0))
    except Exception:
        bad("the verdict file is not JSON")

if not isinstance(doc, dict):
    bad("the verdict is not a JSON object")

decision = (doc.get("decision") or "").strip().lower()
if decision not in ("answer", "escalate"):
    bad("the verdict names no decision")

answer = doc.get("answer") or ""
rationale = (doc.get("rationale") or "").strip()
recommendation = (doc.get("recommendation") or "").strip()
confidence = (doc.get("confidence") or "").strip().lower()
cites = doc.get("citations")
cites = [c for c in cites if isinstance(c, dict)] if isinstance(cites, list) else []

def norm(s):
    return re.sub(r"\s+", " ", s or "").strip().lower()

if decision == "answer":
    if not answer.strip():
        bad("it decided to answer but wrote no answer")
    if not cites:
        bad("it decided to answer but cited nothing")
    # AT LEAST ONE QUOTE MUST REALLY BE THERE. Not all of them: a worker that
    # gets one citation right and paraphrases a second has still shown its line,
    # and refusing that is the over-rejection this round is trying not to do.
    grounded = None
    for c in cites:
        f = str(c.get("file") or "").strip()
        q = str(c.get("quote") or "").strip()
        if not f or not q:
            continue
        # The worker cites by the name it was shown; accept the input-dir path,
        # a bare name, or an absolute path it read.
        cands = [os.path.join(indir, f), os.path.join(indir, os.path.basename(f)), f]
        body = None
        for cand in cands:
            try:
                with open(cand) as fh:
                    body = fh.read()
                break
            except Exception:
                continue
        if body is None:
            continue
        if norm(q) and norm(q) in norm(body):
            grounded = (f, q)
            break
    if grounded is None:
        bad("no citation quote occurs in the file it names")
    # THE JUDGE'S UNSURE EXIT IS HONOURED. The prompt tells Number One to
    # escalate when it is unsure; a verdict that answers while declaring low
    # confidence is it saying so, and taking the answer anyway would be arguing
    # with the one honest signal it gave us.
    if confidence == "low":
        print("ESCALATE\tNumber One was not confident enough to answer for you")
        print("RATIONALE\t" + rationale)
        print("RECOMMENDATION\t" + (recommendation or answer.strip()))
        sys.exit(0)
    print("ANSWER\t" + answer.replace("\n", " ").strip())
    print("RATIONALE\t" + rationale)
    print("CITE_FILE\t" + grounded[0])
    print("CITE_QUOTE\t" + grounded[1].replace("\n", " "))
    sys.exit(0)

print("ESCALATE\t" + (rationale.split("\n")[0] if rationale else "Number One did not find the answer in the record"))
print("RATIONALE\t" + rationale)
print("RECOMMENDATION\t" + recommendation)
XO_PY
  report="$(LCARS_XO_VERDICT="$verdict" LCARS_XO_INPUT="$input" \
            "${LCARS_PYTHON_BIN:-python3}" "$reader" 2>/dev/null)" || report=""

  local kind="" answer_text="" rationale="" recommendation="" why="" cite_file="" cite_quote=""
  local line key val
  while IFS= read -r line; do
    key="${line%%$'\t'*}"; val="${line#*$'\t'}"
    case "$key" in
      MALFORMED)      kind=malformed; why="$val" ;;
      ANSWER)         kind=answer;   answer_text="$val" ;;
      ESCALATE)       kind=escalate; why="$val" ;;
      RATIONALE)      rationale="$val" ;;
      RECOMMENDATION) recommendation="$val" ;;
      CITE_FILE)      cite_file="$val" ;;
      CITE_QUOTE)     cite_quote="$val" ;;
    esac
  done <<< "$report"
  [ -n "$kind" ] || { kind=malformed; why="the verdict could not be read"; }

  # --- SCOPE AND SPEND ARE THE CAPTAIN'S, ALWAYS ---------------------------
  # Checked AFTER the worker ran, on purpose: the escalation the captain reads
  # should carry Number One's recommendation, and a recommendation needs a
  # worker to have thought about it. What the check refuses is the DECISION,
  # never the reading.
  if [ "$etype" = "scope" ]; then
    local rec="${recommendation:-$answer_text}"
    escalate "$dir" "$stage" \
      "this gate is a scope decision, and scope is yours — ${rec:-Number One read the record but did not decide}" \
      "$(printf '"stage": %s, "reason": "scope", "recommendation": %s' \
           "$(jstr "$stage")" "$(jstr "${rec:-}")")"
  fi

  case "$kind" in
    malformed)
      escalate "$dir" "$stage" "$XO_MALFORMED — ${why:-unreadable}" \
        "$(printf '"stage": %s, "reason": "malformed", "detail": %s' \
             "$(jstr "$stage")" "$(jstr "${why:-unreadable}")")" ;;
    escalate)
      escalate "$dir" "$stage" \
        "${why:-Number One did not find the answer in the record} — ${recommendation:-no recommendation}" \
        "$(printf '"stage": %s, "reason": "escalated", "rationale": %s, "recommendation": %s' \
             "$(jstr "$stage")" "$(jstr "$rationale")" "$(jstr "$recommendation")")" ;;
  esac

  # --- THE ANSWER PATH -----------------------------------------------------
  # Through `respond.sh answer`, the verb a human uses — never by writing
  # answers.json here. Two env pins ride along:
  #   LCARS_RESPOND_RESUME=0   respond.sh RE-EXECS the driver by default. Number
  #                            One is called FROM the driver, so letting it
  #                            re-exec would put two drivers on one mission.
  #                            The daemon already uses this pin for the same
  #                            reason (actions.py).
  #   LCARS_ANSWERED_BY        the attribution. The record must say who answered.
  #   LCARS_XO_ENFORCE=0       the engaged lock is there to stop a SECOND hand on
  #                            the mission. This IS the first officer's hand —
  #                            locking it out of its own verb would be the lock
  #                            refusing the thing it was built to permit.
  local rrc=0 rout
  rout="$(LCARS_RESPOND_RESUME=0 LCARS_ANSWERED_BY=number-one LCARS_XO_ENFORCE=0 \
          bash "$XO_RESPOND_SCRIPT" answer \
            --mission "$id" --answer "$answer_text" 2>&1)" || rrc=$?
  if [ "$rrc" -ne 0 ]; then
    # The verb refused. That is a fact about the mission, not a verdict to
    # override: leave the gate up and say what happened.
    escalate "$dir" "$stage" \
      "Number One had an answer but \`lcars respond\` refused it — $(printf '%s' "$rout" | head -1)" \
      "$(printf '"stage": %s, "reason": "respond-refused", "detail": %s' \
           "$(jstr "$stage")" "$(jstr "$(printf '%s' "$rout" | head -1)")")"
  fi

  # STILL ENGAGED. Answering a gate is the job, not the end of it — the mission
  # carries on with Number One holding the conn, and the card keeps its badge.
  local obj
  obj="$(state_xo_block "$st")"
  obj="$(obj_set "$obj" status "$(jstr engaged)")"
  obj="$(obj_del "$obj" note)"
  obj="$(obj_set "$obj" lastAction "$(jstr "answered $stage $NOW_LOCAL")")"
  state_set_xo "$st" "$obj"
  journal "$dir" answered \
    "$(printf '"stage": %s, "answer": %s, "rationale": %s, "citation": {"file": %s, "quote": %s}' \
         "$(jstr "$stage")" "$(jstr "$answer_text")" "$(jstr "$rationale")" \
         "$(jstr "$cite_file")" "$(jstr "$cite_quote")")"

  printf '◈ NUMBER ONE: answered the %s gate on your behalf.\n' "${stage:-?}"
  printf '  %s\n' "$answer_text"
  printf '  Grounds: %s — "%s"\n' "${cite_file:-?}" "$cite_quote"
  return 0
}

case "${1:-status}" in
  on)     shift; cmd_on "$@" ;;
  off)    shift; cmd_off "$@" ;;
  status) shift; cmd_status ;;
  answer) shift; cmd_answer "$@" ;;
  -h|--help|help)
    sed -n '3,12p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *)      die "unknown verb: $1 (want: on | off | status | answer)" ;;
esac
