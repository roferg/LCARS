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
    XO_STOOD_DOWN=$((XO_STOOD_DOWN + 1))
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

  # `lcars xo on <mission>` — a per-mission act: CLEAR the opt-out. It does not
  # engage anything by itself. Engaging is the driver's to do at a gate, and a
  # verb that engaged directly would be a second way in for the one thing this
  # round is trying to keep in one place.
  if [ -n "$target" ]; then
    local id st obj
    id="$(resolve_mission "$target")"
    st="$MISSIONS_DIR/$id/state.json"
    obj="$(state_xo_block "$st")"
    if [ -n "$obj" ]; then
      obj="$(obj_del "$obj" optOut)"
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

case "${1:-status}" in
  on)     shift; cmd_on "$@" ;;
  off)    shift; cmd_off "$@" ;;
  status) shift; cmd_status ;;
  -h|--help|help)
    sed -n '3,12p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *)      die "unknown verb: $1 (want: on | off | status)" ;;
esac
