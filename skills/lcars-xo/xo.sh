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
#   lcars xo evaluate --mission <id>  the Verify LOOK: launch the build, walk it
#                                     headless, compare it to the PRD and the
#                                     drawing, and score the intent match
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
# S207 unified these: the implementations live in lcars-state.sh (sourced via
# lcars-common.sh above) as lcars_json1_get / _del / _set / _str, because
# run.sh's drive loop had copied all four verbatim into drive_xo_put and
# drive_xo_del. The four names below are this file's vocabulary, kept so its
# ~30 call sites read as they did; there is exactly ONE implementation.
obj_get() { lcars_json1_get "$1" "$2"; }        # <obj> <key> — a string value
obj_del() { lcars_json1_del "$1" "$2"; }        # <obj> <key> — obj without it
obj_set() { lcars_json1_set "${1:-}" "$2" "$3"; }  # <obj> <key> <raw-json-value>
jstr()    { lcars_json1_str "$1"; }             # a JSON string literal

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
# MISSION STATE — `numberOne`, ONE line of state.json.
#
# S201 wrote this as a copy of run.sh's state_set_raw (delete the key's line,
# re-insert after the opening brace with a hard-coded comma) and said S207
# would unify it. S207 did: the write is now lcars_state_set, the ONE writer,
# which re-derives every separator and so cannot leave a trailing comma even
# when `numberOne` is the object's last field. The value stays on ONE line —
# state_xo_block below, and run.sh's drive_xo_block, both `sed` for `{…}` on a
# single line — and lcars_state_set preserves it because it edits LINES.
# ===========================================================================
state_xo_block() { # <state.json>
  sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*\({[^}]*}\).*/\1/p' "$1" | head -1
}
state_set_xo() { # <state.json> <one-line-object>
  lcars_state_set "$1" numberOne "$2"
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
  local id="$1" optout="${2:-}" dir st obj status pid live=0
  dir="$MISSIONS_DIR/$id"
  st="$dir/state.json"
  [ -f "$st" ] || die "mission '$id' has no state.json — its state is corrupt."
  obj="$(state_xo_block "$st")"
  status="$(obj_get "$obj" status)"

  # A LIVE PID IS A LIVE SPIN (fix round 1, D1). This branch used to be gated on
  # `status = engaged` ALONE — and `evaluate` never wrote that status while it
  # spun, so the captain's stop button did nothing at all through the whole
  # Verify look: no signal, no stood-down, no note, and a browser and an app
  # left running. The RECORDED PID is the truth about whether Number One is
  # doing something; the status string is a record OF that, never the licence
  # to stop it. A pid that is gone is not a spin, so a crashed mission still
  # takes the plain opt-out path and no stand-down is ever claimed falsely.
  pid="$(head -1 "$dir/xo.pid" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then live=1; fi

  if [ "$status" = "engaged" ] || [ "$live" -eq 1 ]; then
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
    lcars_state_refusal_die "lcars xo on"
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
    # S207 fix round 1 (D2): `numberOne` is ONE write. If the writer refused the
    # mission's state.json, nothing stood down and nothing opted out — so say so
    # and exit non-zero rather than print either line.
    lcars_state_refusal_die "lcars xo off"
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
  lcars_state_refusal_die "lcars xo off"
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

# THE WORKER'S INPUT DIR IS ITS WHOLE WORLD (fix round 1, D4).
#
# gather_inputs ends with `chmod -R a-w` — which is what stops a worker editing
# the record it is judged against, and also what makes every later `cp` into
# that tree fail. Silently, because the callers all wrote `|| true`. So this is
# the ONE way anything is added after the gather: unlock the dir, copy, re-lock.
# It is safe to call repeatedly, which is how a round-three worker sees the
# shots round two took.
xo_put_inputs() { # <input-dir> <criteria.json> <shots-dir>
  local into="$1" crit="$2" from="$3" f
  [ -d "$into" ] || return 0
  chmod u+w "$into" 2>/dev/null || true
  if [ -f "$crit" ]; then
    rm -f "$into/criteria.json" 2>/dev/null || true
    cp "$crit" "$into/criteria.json" 2>/dev/null || true
    chmod a-w "$into/criteria.json" 2>/dev/null || true
  fi
  if [ -d "$from" ]; then
    chmod u+w "$into/shots" 2>/dev/null || true
    mkdir -p "$into/shots" 2>/dev/null || true
    for f in "$from"/*; do
      [ -f "$f" ] || continue
      [ -f "$into/shots/$(basename "$f")" ] && continue
      cp "$f" "$into/shots/" 2>/dev/null || true
    done
    chmod -R a-w "$into/shots" 2>/dev/null || true
  fi
  chmod a-w "$into" 2>/dev/null || true
  return 0
}

# --- the journal ------------------------------------------------------------
# One JSON line per action, beside the mission's other facts. It is what the
# living comment (wave B) renders and what the captain reads to see what his
# first officer has been doing. Append-only; nothing is ever rewritten.
journal() { # <mission-dir> <action> <one-line-json-body>
  # STAMPED WHEN IT IS WRITTEN, not when the process started (fix round 1, D6).
  # $NOW is frozen at line 82, so an evaluate that spans three minutes used to
  # record `criteria`, `launched`, `looked` and `scored` all at the same second
  # — a journal from which the captain can read neither order nor duration.
  printf '{"at": %s, "action": %s, %s}\n' \
    "$(jstr "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(jstr "$2")" "$3" >>"$1/number-one.jsonl"
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
# EVERYTHING THIS PROCESS STARTED, NAMED (fix round 1, D2). A `lcars xo evaluate`
# starts three things that outlive a careless exit: a launched app, a browser
# (inside the driver), and a read-only input tree in $TMPDIR. Before this round
# an abnormal exit left all three — a SIGTERM to xo.pid removed the pid file and
# nothing else, and the LOW paths stopped the app but not the browser.
XO_DRIVE_PID=""
XO_LAUNCH_ID=""
XO_STOP_LOG=""
XO_LAUNCH_STOPPED=0
XO_WORK_DIR=""

# Stop the app this run launched. ONE writer for every exit path — success, LOW,
# error and signal — and idempotent, so calling it twice on the way out costs a
# `return`, never a second `launch.sh --stop`.
xo_stop_launch() {
  [ -n "$XO_LAUNCH_ID" ] || return 0
  [ "$XO_LAUNCH_STOPPED" -eq 1 ] && return 0
  XO_LAUNCH_STOPPED=1
  bash "$XO_LAUNCH_SCRIPT" "$XO_LAUNCH_ID" --stop \
    >>"${XO_STOP_LOG:-/dev/null}" 2>&1 || true
  return 0
}

# Remove a gathered input tree (fix round 1, D5). gather_inputs makes it
# READ-ONLY so nothing a worker does can edit the record it is judged against —
# and a plain `rm -rf` on a read-only tree fails eight "Permission denied" lines
# at a time, straight into the captain's terminal, AND leaves the tree behind
# (1,336 of them on the tester's machine). Writable first, then removed, and
# quietly. The absolute-path guard is there because this deletes recursively.
xo_rm_work() { # <dir>
  local d="${1:-}"
  [ -n "$d" ] || return 0
  case "$d" in /*) ;; *) return 0 ;; esac
  chmod -R u+w "$d" 2>/dev/null || true
  rm -rf "$d" 2>/dev/null || true
  return 0
}

# The one teardown. Called from the EXIT trap AND from the signal trap, so there
# is no way out of this script that leaves a browser, an app or a temp tree
# behind. Deepest first: the driver (and the Chrome it owns) before the app it
# was looking at.
xo_teardown() {
  [ -n "$XO_DRIVE_PID" ] && xo_kill_tree "$XO_DRIVE_PID"
  [ -n "$XO_SPIN_PID" ] && xo_kill_tree "$XO_SPIN_PID"
  XO_DRIVE_PID=""; XO_SPIN_PID=""
  xo_stop_launch
  [ -n "$XO_WORK_DIR" ] && xo_rm_work "$XO_WORK_DIR"
  XO_WORK_DIR=""
  return 0
}

on_stand_down() {
  xo_teardown
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
  lcars_state_refusal_die "lcars xo"
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
  XO_WORK_DIR="$work"
  # THE TEMP TREE IS OWNED FROM HERE ON (fix round 1, D5). `answer` never removed
  # its read-only input copy at all; the EXIT trap does now, on every path.
  trap xo_teardown EXIT
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
  # The gate answer is recorded in `numberOne`; a refused write means Number One
  # did NOT take the conn, so it must not report that it did.
  lcars_state_refusal_die "lcars xo answer"
  journal "$dir" answered \
    "$(printf '"stage": %s, "answer": %s, "rationale": %s, "citation": {"file": %s, "quote": %s}' \
         "$(jstr "$stage")" "$(jstr "$answer_text")" "$(jstr "$rationale")" \
         "$(jstr "$cite_file")" "$(jstr "$cite_quote")")"

  printf '◈ NUMBER ONE: answered the %s gate on your behalf.\n' "${stage:-?}"
  printf '  %s\n' "$answer_text"
  printf '  Grounds: %s — "%s"\n' "${cite_file:-?}" "$cite_quote"
  return 0
}


# ===========================================================================
# EVALUATE — THE VERIFY LOOK (S203)
#
#   lcars xo evaluate --mission <id>
#
# The Mission has a PR open and is parked at Verify. Number One launches the
# build, walks it in a HEADLESS browser, compares what it sees against a
# contract written before it looked, and scores the intent match LOW / MEDIUM /
# HIGH with a per-criterion ledger behind it.
#
# IT FILES NOTHING. S203 finds and scores; S204 is the round that files logs and
# drives fixes. A HIGH finishes the Mission's first-officer work; a MEDIUM or a
# LOW leaves it engaged, with the gaps written down for that next round.
#
# THE ORDER MATTERS, AND IT IS THE ORDER OF THE BRIEF:
#
#   1. THE CONTRACT FIRST, BEFORE ANY BROWSER. criteria.json is built from the
#      PRD, the plan and the drawing while the app is still not running. A judge
#      that writes its checklist after looking writes a checklist of what it
#      noticed.
#   2. LAUNCH. If the app does not come up, that is a LOW that says so, and NO
#      BROWSER IS EVER STARTED. "Could not launch" is an honest verdict; a
#      browser pointed at nothing is not.
#   3. ROUND 0 — the standard look: the whole page, plus one clipped shot per
#      place the drawing names.
#   4. UP TO THREE WORKER ROUNDS. Each round the worker either asks to look
#      further (xo-actions.json, at most 12 actions) or writes its verdict. No
#      verdict by the end of round 3 is a LOW that lists what it saw — an
#      indecisive judge must not become a passing grade.
#   5. THE SCORE IS RECOMPUTED FROM THE LEDGER (xo-score.py). The model reasons;
#      the skill decides. A worker score that disagrees with its own ledger is
#      OVERWRITTEN and the disagreement journaled.
#   6. STOP THE APP. Always, including on every failure path.
#   7. RECORD: xo/verdict.json, the journal, numberOne.score, the status, the
#      score LABEL on the issue, and the living comment.
#
# THE CAPTAIN'S FOCUS IS NEVER TAKEN (ruling 2026-09-13). The browser is
# headless — structurally, in xo-drive.js, with no flag and no env that can
# raise a window — and nothing here opens a tab, an app window or a file for
# him. `launch.sh` is called WITHOUT any open-ish behaviour: it starts the app
# on a port and returns a url, and the only thing that ever visits that url is
# Number One's own headless Chrome.
# ===========================================================================

XO_LAUNCH_SCRIPT="${LCARS_LAUNCH_SCRIPT:-$SKILL_DIR/../lcars-launch/launch.sh}"
XO_DRIVER="${LCARS_XO_DRIVER:-$SKILL_DIR/xo-drive.js}"
XO_HOST_ADAPTER="${LCARS_HOST_ADAPTER:-$SKILL_DIR/../lcars-run/host-adapter.sh}"
XO_NODE="${LCARS_NODE_BIN:-node}"
XO_PY="${LCARS_PYTHON_BIN:-python3}"
XO_MAX_ROUNDS="${LCARS_XO_MAX_ROUNDS:-3}"
XO_MAX_ACTIONS=12

# Every score LABEL, in one place: applied by the swap below, removed by it, and
# named by init.sh's label set. `lcars:xo:` is the one prefix.
XO_SCORE_LABELS="lcars:xo:high lcars:xo:medium lcars:xo:low"

json_field() { # <file> <key> — a string value, or empty
  [ -f "$1" ] || return 0
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

# The score LABEL swap. One source per fact (ruling): the LABEL is the score, the
# COMMENT is the report — so a remote card reads the score off the listing it
# already fetched, with no extra call. Best-effort like every relabel in LCARS:
# a forge that is down leaves a note, it never loses a verdict that is already
# on disk.
# THE LABELS MUST EXIST BEFORE THE SWAP CAN LAND. `lcars init` creates the whole
# canonical set, but every repo initialized before this round has none of the
# `lcars:xo:*` family — and `gh issue edit --add-label` on a label the forge has
# never heard of fails, silently, exactly where the verdict was supposed to
# become visible. So the swap ensures its own family first, from the SAME list
# init creates from (lcars_all_labels in lcars-common.sh): one source of truth
# for names, colours and descriptions, never a second copy here.
#
# ONE listing call, then a create per missing label — so a settled repo pays one
# call and writes nothing. Best-effort throughout: a forge that is down leaves
# the verdict on disk and the label for next time.
xo_label_ensure() {
  local specs=() name color
  while IFS='|' read -r name color; do
    case "$name" in
      lcars:xo:*) specs+=("$name|$color|$(lcars_label_desc "$name")") ;;
    esac
  done <<EOF
$(lcars_all_labels)
EOF
  [ "${#specs[@]}" -gt 0 ] || return 0
  bash "$XO_HOST_ADAPTER" label-ensure "${specs[@]}" >/dev/null 2>&1 || true
  return 0
}

xo_label_score() { # <state.json> <score>
  local st="$1" score="$2" issue remove=""
  issue="$(json_field "$st" githubIssue)"
  [ -n "$issue" ] || issue="$(sed -n 's/.*"githubIssue"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$st" | head -1)"
  case "$issue" in ''|0|null) return 0 ;; esac
  local l
  for l in $XO_SCORE_LABELS; do
    [ "$l" = "lcars:xo:$score" ] && continue
    remove="${remove:+$remove,}$l"
  done
  xo_label_ensure
  bash "$XO_HOST_ADAPTER" issue-relabel "$issue" \
    --add "lcars:xo:$score" --remove "$remove" >/dev/null 2>&1 || true
  return 0
}

# The S65 living comment — created once, EDITED thereafter, keyed `number-one`.
# Re-rendered through run.sh's own mirror entry so there is exactly ONE renderer
# and one comment-id map; xo.sh never posts a comment of its own.
xo_mirror() { # <mission-id>
  bash "$XO_RUN_SCRIPT" mirror-comments --mission "$1" >/dev/null 2>&1 || true
}

# Record a finished look and stop. ONE writer for every exit path, so a LOW from
# a failed launch and a HIGH from a clean look leave the same shaped record.
xo_finish() { # <mission-dir> <score> <status> <why>
  local dir="$1" score="$2" status="$3" why="$4" st obj id
  st="$dir/state.json"; id="$(basename "$dir")"
  obj="$(state_xo_block "$st")"
  obj="$(obj_set "$obj" status "$(jstr "$status")")"
  obj="$(obj_set "$obj" score "$(jstr "$score")")"
  obj="$(obj_set "$obj" evaluatedAt "$(jstr "$NOW")")"
  obj="$(obj_set "$obj" lastAction "$(jstr "looked $NOW_LOCAL")")"
  if [ "$status" = "engaged" ]; then
    obj="$(obj_set "$obj" note "$(jstr "$why")")"
  else
    obj="$(obj_del "$obj" note)"
  fi
  state_set_xo "$st" "$obj"
  lcars_state_refusal_die "lcars xo evaluate"
  # THE REPORT ALWAYS EXISTS. xo-score.py writes it whenever there was a ledger
  # to render; the paths that never got one (a build that would not launch, a
  # browser that would not start, three rounds with no verdict, a verdict that
  # could not be read) still owe the captain a sentence on his issue, so they
  # get this one. The living comment includes whichever was written.
  if [ ! -s "$dir/xo/report.md" ]; then
    { printf '**How close this is to what you asked for: %s** — %s\n\n' \
        "$(printf '%s' "$score" | tr '[:lower:]' '[:upper:]')" "$why"
      printf 'I have nothing item-by-item for this one: %s\n' "$why"
    } >"$dir/xo/report.md"
  fi
  journal "$dir" scored \
    "$(printf '"score": %s, "why": %s, "status": %s' \
         "$(jstr "$score")" "$(jstr "$why")" "$(jstr "$status")")"
  xo_label_score "$st" "$score"
  xo_mirror "$id"
  printf '◈ NUMBER ONE: intent match %s — %s\n' "$(printf '%s' "$score" | tr '[:lower:]' '[:upper:]')" "$why"
  printf '  The report is in %s/xo/verdict.json.\n' "$dir"
}

cmd_evaluate() {
  local target=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mission)   target="${2:-}"; shift 2 || true ;;
      --mission=*) target="${1#--mission=}"; shift ;;
      -*)          die "unknown option: $1" ;;
      *)           target="$1"; shift ;;
    esac
  done
  [ -n "$target" ] || die "no mission — pass --mission <id>."
  local id dir st xodir shots
  id="$(resolve_mission "$target")" || exit $?
  dir="$MISSIONS_DIR/$id"
  st="$dir/state.json"
  xodir="$dir/xo"
  shots="$xodir/shots"

  # IDEMPOTENT ON evaluatedAt. The Verify driver can pass this way more than
  # once (a poll, a re-run, a second laptop) and a second look would spend a
  # worker and a browser to reach the same verdict.
  local seen
  seen="$(obj_get "$(state_xo_block "$st")" evaluatedAt)"
  if [ -n "$seen" ]; then
    printf '◈ NUMBER ONE: already looked at %s (%s) — nothing to do.\n' "$id" "$seen"
    return 0
  fi

  # A BUG CHILD IS NEVER EVALUATED. Its parent's PR carries the fix (Mission
  # logs' Model A); looking at a child would score the parent's build twice.
  if grep -q '"parentMission"' "$st" 2>/dev/null; then
    printf '◈ NUMBER ONE: %s is a logged bug child — its parent carries the build.\n' "$id"
    return 0
  fi

  mkdir -p "$xodir" "$shots"
  XO_MISSION_DIR="$dir"
  XO_LAUNCH_ID="$id"
  XO_STOP_LOG="$xodir/launch.log"
  # EVERY WAY OUT TEARS DOWN WHAT THIS RUN STARTED (fix round 1, D2) — the EXIT
  # trap for a `die` or a normal return, the TERM/INT trap for the captain's
  # stop button and for a parent that dies.
  trap xo_teardown EXIT
  trap on_stand_down TERM INT
  printf '%s\n' "$$" >"$dir/xo.pid"

  # NUMBER ONE IS ENGAGED FOR THE WHOLE SPIN (fix round 1, D1). Written BEFORE
  # the contract is built and replaced by xo_finish at the end, so the status
  # table, the board and `lcars xo off` all read a truthful status while the
  # look is happening rather than only after it.
  local ev_obj
  ev_obj="$(state_xo_block "$st")"
  ev_obj="$(obj_set "$ev_obj" status "$(jstr engaged)")"
  ev_obj="$(obj_set "$ev_obj" since "$(jstr "$NOW")")"
  ev_obj="$(obj_set "$ev_obj" lastAction "$(jstr "looking $NOW_LOCAL")")"
  [ -n "$ev_obj" ] && state_set_xo "$st" "$ev_obj"

  # NUMBER ONE'S ENGINE, RESOLVED ONCE, BEFORE ANYTHING IS SPAWNED (fix round 1,
  # D3). It is needed by the LAUNCH below as well as by the worker rounds, and
  # resolving it in two places is how the two could disagree.
  local xo_engine=""
  [ -n "${LCARS_WORKER_BIN:-}" ] || xo_engine="$(xo_engine_for "$st")"

  # --- 1. THE CONTRACT, BEFORE THE BROWSER --------------------------------
  local cbuilt=""
  cbuilt="$("$XO_PY" "$SKILL_DIR/xo-criteria.py" "$dir" "$xodir/criteria.json" 2>&1)" || cbuilt=""
  [ -f "$xodir/criteria.json" ] || die "could not build the criteria list for '$id' — the mission's record is unreadable."
  printf '◈ NUMBER ONE: the contract first — %s.\n' "${cbuilt:-criteria written}"
  journal "$dir" criteria "$(printf '"detail": %s' "$(jstr "${cbuilt:-criteria written}")")"

  # --- 2. LAUNCH ------------------------------------------------------------
  # Through launch.sh, the verb a human uses, with no --open-ish path anywhere
  # near it. xo.sh NEVER writes inside the launch worktree: launch.sh's own
  # checkout-clean audit dies on a dirty tree, and a first officer that dirtied
  # it would break the next launch for everyone.
  #
  # THE LAUNCH INSPECTOR RUNS ON NUMBER ONE'S ENGINE (fix round 1, D3). launch.sh
  # spawns a discovery worker of its own, and its ladder is env → state workerBin
  # → `claude`. Unpinned, a `lcars xo on --engine copilot` therefore hired a
  # CLAUDE inspector — billed spend under a Copilot first officer, and on an
  # unauthenticated machine a perfectly good build scored LOW "could not launch".
  # $LCARS_WORKER_BIN_INTERNAL=1 is the S202/S207 marker: it says LCARS set this,
  # not the captain, so the MISSION's own provenance (`env` means he typed it)
  # is untouched. Exported inside a SUBSHELL that wraps nothing but the spawn.
  printf '◈ NUMBER ONE: launching the build…\n'
  (
    if [ -n "$xo_engine" ]; then
      export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
    fi
    exec bash "$XO_LAUNCH_SCRIPT" "$id"
  ) >"$xodir/launch.log" 2>&1 || true
  local lstatus lurl lmsg
  lstatus="$(json_field "$dir/launch.json" status)"
  lurl="$(json_field "$dir/launch.json" url)"
  lmsg="$(json_field "$dir/launch.json" message)"
  if [ "$lstatus" != "running" ] || [ -z "$lurl" ]; then
    # NO BROWSER AT ALL. There is nothing to point one at, and a verdict from a
    # blank tab is worse than no verdict.
    local why="could not launch: ${lmsg:-the build did not come up (status ${lstatus:-unknown})}"
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "criteria": [],\n  "gaps": [],\n  "summary": %s\n}\n' \
      "$(jstr "$why")" "$(jstr "$why")" >"$xodir/verdict.json"
    rm -f "$dir/xo.pid"; trap - TERM INT
    xo_finish "$dir" low engaged "$why"
    return 0
  fi
  printf '  the build is up at %s\n' "$lurl"
  journal "$dir" launched "$(printf '"url": %s' "$(jstr "$lurl")")"

  # From here on the app is RUNNING and must be stopped on every path out. The
  # stopper is the FILE-LEVEL xo_stop_launch (fix round 1, D2) — the same one the
  # EXIT and TERM traps call — so an abnormal exit stops the app exactly as an
  # orderly one does. It used to be a function nested here, reachable only from
  # the paths that remembered to call it.
  XO_LAUNCH_STOPPED=0

  # --- 3. ROUND 0 — the standard look --------------------------------------
  # BACKGROUNDED AND WAITED ON (fix round 1, D2). A foreground child holds the
  # trap's first opportunity to run until it finishes, so a TERM arriving during
  # the look — which is where most of the wall clock goes — did nothing until the
  # browser was already done. Backgrounded, the stand-down lands immediately and
  # the trap kills the driver's whole tree, Chrome included.
  local drc=0
  "$XO_NODE" "$XO_DRIVER" --url "$lurl" --out "$shots" \
    --place-names "$xodir/criteria.json" --prefix "shot" \
    >"$xodir/drive-0.json" 2>"$xodir/drive-0.err" &
  XO_DRIVE_PID=$!
  wait "$XO_DRIVE_PID" || drc=$?
  XO_DRIVE_PID=""
  if [ "$drc" -eq 77 ]; then
    local why="could not look: the browser could not be started ($(head -1 "$xodir/drive-0.err" 2>/dev/null))"
    xo_stop_launch
    rm -f "$dir/xo.pid"; trap - TERM INT
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "criteria": [],\n  "gaps": [],\n  "summary": %s\n}\n' \
      "$(jstr "$why")" "$(jstr "$why")" >"$xodir/verdict.json"
    xo_finish "$dir" low engaged "$why"
    return 0
  fi
  journal "$dir" looked "$(printf '"round": 0, "shots": %s' \
    "$(ls "$shots"/*.png 2>/dev/null | grep -c . | tr -d ' ')")"

  # --- 4. THE WORKER ROUNDS ------------------------------------------------
  local work input round=1 verdict="" out=""
  work="$(mktemp -d)"; input="$work/input"
  XO_WORK_DIR="$work"
  mkdir -p "$input"
  gather_inputs "$dir" "$input"
  # THE WORKER IS HANDED ITS CONTRACT (fix round 1, D4). Number One escalated
  # this against itself: "criteria.json and xo/shots/ were not in the Number One
  # input directory. They were read from .git/lcars/… instead." Both copies were
  # meant to be here — the criteria `cp` above was failing SILENTLY, because
  # gather_inputs chmods the whole tree a-w and a read-only directory takes no
  # new files. It worked only because claude's Read is unfenced by path; on a
  # path-sandboxed engine that is the difference between a ledger and a guess.
  # So: unlock, copy, re-lock. The shots (with the .json/.txt readout beside
  # each) come too, and are re-synced every round because every round takes more.
  xo_put_inputs "$input" "$xodir/criteria.json" "$shots"

  while [ "$round" -le "$XO_MAX_ROUNDS" ]; do
    out="$work/round-$round"
    mkdir -p "$out"
    xo_put_inputs "$input" "$xodir/criteria.json" "$shots"
    printf '◈ NUMBER ONE: round %s of %s — looking…\n' "$round" "$XO_MAX_ROUNDS"
    (
      export LCARS_XO_INPUT_DIR="$input"
      # The SHOTS are granted as a second input dir: on copilot the adapter turns
      # each line into an --add-dir, which is how the worker reaches the PNGs.
      # The spike proved it reads them.
      export LCARS_WORKER_INPUT_DIRS="$input
$input/shots
$shots"
      if [ -n "$xo_engine" ]; then
        export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
      fi
      exec bash "$XO_RUN_SCRIPT" spawn-number-one \
        --mission "$id" --mode evaluate --outdir "$out"
    ) >/dev/null 2>&1 &
    XO_SPIN_PID=$!
    wait "$XO_SPIN_PID" 2>/dev/null || true
    XO_SPIN_PID=""

    if [ -s "$out/xo-verdict.json" ]; then
      verdict="$out/xo-verdict.json"
      break
    fi
    if [ -s "$out/xo-actions.json" ]; then
      # MORE LOOKING. The cap is enforced HERE as well as in the driver: the
      # driver drops the overflow, and this says so in the record, so a worker
      # that asked for twenty actions can never look like it got them.
      local nacts
      nacts="$("$XO_PY" -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    d=d if isinstance(d,list) else d.get("actions",[])
    print(len(d))
except Exception: print(0)' "$out/xo-actions.json" 2>/dev/null)"
      nacts="${nacts:-0}"
      journal "$dir" actions \
        "$(printf '"round": %s, "asked": %s, "cap": %s' "$round" "$nacts" "$XO_MAX_ACTIONS")"
      drc=0
      "$XO_NODE" "$XO_DRIVER" --url "$lurl" --out "$shots" \
        --actions "$out/xo-actions.json" --place-names "$xodir/criteria.json" \
        --max-actions "$XO_MAX_ACTIONS" --prefix "round$round" \
        >"$xodir/drive-$round.json" 2>"$xodir/drive-$round.err" &
      XO_DRIVE_PID=$!
      wait "$XO_DRIVE_PID" || drc=$?
      XO_DRIVE_PID=""
      cp "$out/xo-actions.json" "$xodir/actions-$round.json" 2>/dev/null || true
      journal "$dir" looked "$(printf '"round": %s, "driverExit": %s' "$round" "$drc")"
      round=$((round + 1))
      continue
    fi
    # Neither file. Nothing to act on and nothing to re-look at — another round
    # with identical inputs would only buy the same silence again.
    journal "$dir" silent "$(printf '"round": %s' "$round")"
    round=$((round + 1))
  done

  xo_stop_launch
  rm -f "$dir/xo.pid"; trap - TERM INT

  local shotlist
  shotlist="$(ls "$shots"/*.png 2>/dev/null | sed 's|.*/||; s|\.png$||' | tr '\n' ' ' | sed 's/ $//')"

  if [ -z "$verdict" ]; then
    # THREE ROUNDS, NO VERDICT. A judge that will not decide is not a pass.
    local why="Number One could not reach a verdict in $XO_MAX_ROUNDS rounds"
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "criteria": [],\n  "gaps": [],\n  "sawShots": %s,\n  "summary": %s\n}\n' \
      "$(jstr "$why")" "$(jstr "$shotlist")" \
      "$(jstr "$why — it looked at: ${shotlist:-nothing}")" >"$xodir/verdict.json"
    xo_finish "$dir" low engaged "$why — it looked at: ${shotlist:-nothing}"
    xo_rm_work "$work"; XO_WORK_DIR=""
    return 0
  fi

  # --- 5. THE SCORE IS RECOMPUTED FROM THE LEDGER --------------------------
  local report
  report="$("$XO_PY" "$SKILL_DIR/xo-score.py" "$verdict" "$xodir/criteria.json" \
              "$xodir/verdict.json" 2>/dev/null)" || report=""
  local score="" wscore="" disagreed="" why="" summary="" line key val
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%$'\t'*}"; val="${line#*$'\t'}"
    case "$key" in
      MALFORMED)    score=""; why="$XO_MALFORMED — $val" ;;
      SCORE)        score="$val" ;;
      WORKER_SCORE) wscore="$val" ;;
      DISAGREED)    disagreed="$val" ;;
      WHY)          why="$val" ;;
      SUMMARY)      summary="$val" ;;
      NOTE)         journal "$dir" ledger-note "$(printf '"detail": %s' "$(jstr "$val")")" ;;
    esac
  done <<< "$report"

  if [ -z "$score" ]; then
    # A verdict that cannot be read is not a verdict. It is a LOW that says so,
    # and it stays engaged — the captain looks himself.
    local mw="${why:-$XO_MALFORMED}"
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "criteria": [],\n  "gaps": [],\n  "summary": %s\n}\n' \
      "$(jstr "$mw")" "$(jstr "$mw")" >"$xodir/verdict.json"
    xo_finish "$dir" low engaged "$mw"
    xo_rm_work "$work"; XO_WORK_DIR=""
    return 0
  fi

  # THE DISAGREEMENT IS JOURNALED, ALWAYS. The ledger already won — this line is
  # how anyone can see that it did, and by how much.
  if [ "$disagreed" = "yes" ]; then
    journal "$dir" score-overruled \
      "$(printf '"workerScore": %s, "ledgerScore": %s, "derivation": %s' \
           "$(jstr "$wscore")" "$(jstr "$score")" "$(jstr "$why")")"
    printf '  Number One scored this %s; the ledger says %s, and the ledger decides.\n' \
      "$wscore" "$score"
  fi

  # --- 7. THE RECORD --------------------------------------------------------
  # A HIGH finishes the first officer's work on this Mission. Anything else
  # leaves it ENGAGED — there are gaps, and S204 is the round that acts on them.
  local status=engaged
  [ "$score" = "high" ] && status=finished
  xo_finish "$dir" "$score" "$status" "${summary:-$why}"
  xo_rm_work "$work"; XO_WORK_DIR=""
  return 0
}

case "${1:-status}" in
  on)     shift; cmd_on "$@" ;;
  off)    shift; cmd_off "$@" ;;
  status) shift; cmd_status ;;
  answer) shift; cmd_answer "$@" ;;
  evaluate) shift; cmd_evaluate "$@" ;;
  -h|--help|help)
    sed -n '3,12p' "$SELF" | sed 's/^# \{0,1\}//' ;;
  *)      die "unknown verb: $1 (want: on | off | status | answer | evaluate)" ;;
esac
