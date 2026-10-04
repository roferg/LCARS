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
#   lcars xo file-logs --mission <id> file ONE ordinary mission log per gap the
#                                     look found, with its shots, and let LCARS
#                                     drive them
#   lcars xo recheck --mission <id>   after the fixes land: relaunch, look again
#                                     gap by gap, accept what holds, re-score
#   lcars xo report [#n] [--all] [--seen]
#                                     the First Officer's report: what is new
#                                     since you last looked, then history,
#                                     folded per mission — nothing is ever
#                                     deleted. `#n` (or a mission id) scopes
#                                     it to one mission's own journal; --all
#                                     shows every entry, not just the recent
#                                     ones; --seen marks it read
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

# The git binary — stubbable, same convention as run.sh (S205 ruling 2:
# `xo recheck` must not silently trust a stale local branch — see
# `xo_recheck_sync_branch` below).
GIT_BIN="${LCARS_GIT_BIN:-git}"

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
#
# READ WHITESPACE-INSENSITIVELY, BECAUSE THE PRODUCT INVITES THE HAND EDIT
# (S240 fix round 1, D1). `cfg_block` called `lcars_config_get_raw`, which is a
# single-line `sed` taking THE REST OF THE LINE after the key. MEASURED, on a
# config saying `{"enabled": true, "engine": "copilot", "filesBugs": false}`:
#
#   pretty-printed (what any editor writes)    ->  `{`
#   one line       (what `lcars xo on` writes) ->  the object AND the next key
#
# So on a pretty-printed config `cfg_enabled` read OFF for a captain who had set
# it ON, and `cfg_files_bugs` read FILES for a captain who had set no-file — two
# switches silently ignored, in OPPOSITE directions. And the refusal message in
# file_logs_for ("Turn it back on in .git/lcars/config.json") is the product
# telling him to open that file in an editor, so the style that breaks both
# switches is the style it asks him for.
#
# THE ROOT CAUSE IS `lcars_config_get_raw` (lcars-init/lcars-common.sh:3853) and
# it is NOT changed here, deliberately: it is shared code with callers well
# beyond Number One (lcars-common.sh:2251 among them), and its line-greed also
# swallows the NEXT key on a one-line config, so a correct fix there is wider
# than this round can prove. It is ledgered as the root cause.
#
# What changes is the READERS. They now use `lcars_state_get_raw` — the
# JSON-AWARE top-level scanner S223 wrote for exactly this problem, documented
# for state.json AND config.json — so BOTH styles return the real object.
# `cfg_engine`/`cfg_model` keep reading it through `obj_get`, which answers
# correctly on a multi-line object (measured).
cfg_block() {
  local raw
  raw="$(lcars_state_get_raw "$CONFIG" numberOne)"
  case "$raw" in '{'*'}') printf '%s' "$raw" ;; esac
}
# cfg_flag <key> — the RAW token recorded for `numberOne.<key>`, or empty. The
# newlines are flattened first so a key and its value can be matched on one
# line, and the character class excludes a quote ON PURPOSE: `"enabled": "true"`
# is a STRING where this switch is a boolean, and it reads as ABSENT — which is
# the documented default, not a guess at what was meant.
cfg_flag() {
  printf '%s' "$(cfg_block)" | tr '\n\t' '  ' \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\([A-Za-z0-9.+-]*\).*/\1/p" | head -1
}
# ABSENT MEANS OFF — Number One is opt-in per repo (`lcars xo on`).
cfg_enabled() {
  [ "$(cfg_flag enabled)" = true ]
}
# ─── FILING IS A SWITCH, AND ITS DEFAULT IS ON (S240) ───────────────────────
# `numberOne.filesBugs` in the repo's config. ABSENT MEANS TRUE: a repo that
# predates this switch files its bugs, because that is what S240 is for. Only an
# explicit `false` turns it off, and when it is off the gaps are still on the
# report — the captain loses the filing, never the finding.
cfg_files_bugs() {
  [ "$(cfg_flag filesBugs)" != false ]
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
# S223: READ BY THE JSON-AWARE SCANNER, never `{[^}]*}` — that regex stopped at
# the first `}` inside a headline and `lcars xo off` wrote the truncation back
# over the captain's real state.json.
state_xo_block() { # <state.json>
  lcars_state_xo_block "$1"
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
# conn back.
#
# ── AMENDED S240 fix round 5, BY THE ORCHESTRATOR — NOT YET THE CAPTAIN'S ─────
# This block used to end "Nothing is ever KILLed — a worker gets to finish its
# own cleanup." THAT IS NO LONGER TRUE of the resolve chain, and leaving the
# sentence here would be a comment that contradicts its own code — the very
# defect S238 cured (one rule in a shell copy and a Python copy, drifted to
# OPPOSITE verdicts, with a test holding their wording identical while their
# behaviour diverged).
#
# WHAT IS TRUE NOW: `xo_stop_tree` TERMs the driver alone first so its own trap
# runs, then TERMs every owned group, and only then KILLs whatever is left —
# after TERM has had two bounded chances, and only ever within the enumerated
# resolve chain. `xo_kill_tree` (the LOOK's trap, far below) is still TERM-only
# and that comment still holds.
# WHY: a measured live incident. The TERM-only stop left a worker alive in its
# own process group, printed "you have the conn", deleted its own pidfile, and
# 25s later the survivor spawned a FRESH PAID assistant. A worker's right to
# clean up cannot outrank the captain's right to stop spending his money.
# THE CAPTAIN HAS NOT RULED ON THIS — he is asked in the morning readout, and
# it is reversible by dropping the KILL escalation in `xo_stop_tree`.
# ===========================================================================
# ── a pid file that says WHO, not just which number (S213) ──────────────────
#
# A pid is a number the operating system hands out again. By the time anyone
# reads one back, it may belong to something else entirely — and this machine
# runs the captain's own viewscreen, his own Copilot sessions, and long-lived
# sessions of its own. Signalling a number we merely found is how a stop button
# kills the wrong thing.
#
# So a pid file written here records the process's IDENTITY as well: the group
# it leads (when it leads one) and the instant it started, both read from the OS
# at the moment we spawned it. Nothing downstream has to work out who a pid
# belongs to by looking at its NAME or matching a PATTERN — that is the one
# thing we never do — because the fact was written down when it was still known.
#
# The first line is still the bare pid, so every existing reader (`head -1`) is
# unaffected.
xo_write_pidfile() { # <pid> <file>
  local pid="$1" file="$2" pgid started
  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -dc '0-9')"
  started="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')"
  # A BORROWED GROUP IS NOT AN IDENTITY (fix round 4, D3). MEASURED: with no
  # `setsid` on this machine the detached chain inherited the LOOK's process
  # group, and this writer copied that number down as if it were the chain's
  # own. A reader handed it could kill the look, the viewscreen, or the
  # captain's shell. So the group is recorded ONLY where the process genuinely
  # LEADS it (pgid == pid); anything else is recorded as absent, and
  # `xo_signal_pidfile` then reaches exactly the one process it can name.
  [ -n "$pgid" ] && [ "$pgid" != "$pid" ] && pgid=""
  { printf '%s\n' "$pid"; printf '%s\n' "${pgid:-}"; printf '%s\n' "${started:-}"; } >"$file"
}

# ── A STOP THAT CROSSES A PROCESS GROUP, AND NEVER LIES (S240 fix round 5, D1)
#
# THE DEFECT, MEASURED LIVE. `lcars xo off <mission>` printed
# "stood down on <mission> — you have the conn" and exited 0. In fact it had
# killed the driver's group LEADER and nothing else. `ps -eo pid,ppid,pgid`
# immediately after:
#
#   pid     ppid  pgid    what
#   31634   1     30311   run.sh drive --mission …           ← orphaned to init
#   36323   31634 30311   run.sh validate …
#   36610   36610 36610   worker-adapter.sh spawn copilot …  ← OWN group
#   36662   36610 36610   copilot -p …                       ← THE PAID ASSISTANT
#
# 25 seconds later the surviving driver had advanced a bug align→research→
# validate→plan and started a FRESH paid assistant. And the stop had DELETED
# `xo-resolve.pid`, so the product had no handle left to try again with; a human
# killed the tree by hand.
#
# WHY A pgid CAN NEVER BE ENOUGH, and why the grouping is not the thing to fix:
# `skills/lcars-run/run.sh` launches every worker as its own session/group
# leader on purpose (`perl -e 'use POSIX qw(setsid); … exec @ARGV'`, at
# run.sh:10000, :20068 and :20221). That is BUG-048's cure — nested workers that
# reparent, and the forked test pools vitest/jest spawn, must not be able to
# outlive a stop. So a worker is BY DESIGN in a different group from its driver,
# and a stop has to ENUMERATE the tree rather than name one group.
#
# AND THE ORDER MATTERED. The old stop signalled the recorded GROUP, which took
# the driver's leader out from under the chain, orphaned the rest to ppid 1, and
# so the driver's own trap never ran and its worker was simply abandoned.
#
# THE THREE RULES THIS IMPLEMENTS:
#   1. ENUMERATE BEFORE SIGNALLING. `xo-tree.py` closes the chain over
#      parenthood AND the groups the chain leads, to a fixpoint, from the real
#      process table. Taken BEFORE the first signal, because a signal orphans
#      the survivors and after that no walk down from the recorded pid can find
#      them — which is precisely how the live stop lost a worker.
#   2. GENTLE FIRST, THEN ESCALATE. A plain TERM to the driver alone, so its own
#      teardown gets to run; then TERM every group the chain owns; then KILL
#      whatever is left. This is the one place in Number One that escalates to
#      KILL, and it does so only after the gentle signal has been given its
#      bound and the process is still there.
#   3. CONFIRM BEFORE CLAIMING. The process table is re-read after signalling.
#      Anything still there is NAMED and the stop reports failure. A stop that
#      cannot confirm death must never say "you have the conn".
#
# $LCARS_XO_KILL_BIN exists so a test can swallow every signal while the rig
# stays genuinely alive, and prove that rule 3 is a real check and not a
# sentence. It defaults to the shell's own `kill`. THE LIVENESS CHECKS BELOW DO
# NOT GO THROUGH IT — they use the builtin directly, so no stub can fake a
# death.
XO_KILL="${LCARS_XO_KILL_BIN:-kill}"
XO_TREE_PY="$SKILL_DIR/xo-tree.py"
# The pids a stop signalled and then found STILL RUNNING. Read by `stand_down`
# and `cmd_off`; the empty string means the tree was confirmed gone.
XO_STOP_SURVIVORS=""
XO_STOP_SET=""

xo_tree_set() { # <pid> [recorded-pgid] — "PID n" / "GROUP n" lines for the chain
  local pid="${1:-}" pgid="${2:-}"
  [ -n "$pid" ] || return 0
  if [ -f "$XO_TREE_PY" ] && command -v "${XO_PY:-python3}" >/dev/null 2>&1; then
    "${XO_PY:-python3}" "$XO_TREE_PY" closure "$pid" "${pgid:-0}" "$$" 2>/dev/null \
      && return 0
  fi
  # NO WALKER. Then say only what is known for certain — the one process, and
  # its group ONLY where the pidfile recorded one it genuinely leads. A stop
  # that cannot enumerate must under-claim, never over-kill; the confirmation
  # step then reports the survivors instead of inventing a success.
  printf 'PID %s\n' "$pid"
  [ -n "$pgid" ] && [ "$pgid" = "$pid" ] && printf 'GROUP %s\n' "$pgid"
  return 0
}

# A zombie is gone for our purposes: it cannot run, and nothing in this process
# will ever reap it. Counting one as alive is how a correct stop reports a
# false failure.
xo_pid_gone() { # <pid> — 0 when it is gone or defunct
  local p="${1:-}" st
  [ -n "$p" ] || return 0
  kill -0 "$p" 2>/dev/null || return 0
  st="$(ps -o state= -p "$p" 2>/dev/null | tr -d ' ')"
  case "$st" in Z*) return 0 ;; esac
  return 1
}

xo_stop_alive() { # — the pids in XO_STOP_SET still on the process table
  local p out=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    xo_pid_gone "$p" || out="$out $p"
  done <<EOF
$(printf '%s\n' "$XO_STOP_SET" | sed -n 's/^PID //p' | sort -un)
EOF
  printf '%s' "${out# }"
}

# Union a fresh enumeration into the set. Called on every poll, so a worker the
# dying driver starts WHILE we are stopping it still gets stopped — live, a
# fresh paid assistant appeared 25 seconds after the stop.
xo_stop_refresh() { # <pid> <pgid>
  XO_STOP_SET="$(printf '%s\n%s\n' "$XO_STOP_SET" "$(xo_tree_set "$1" "$2")" \
                   | sed '/^$/d' | sort -u)"
}

xo_stop_wait() { # <polls> <pid> <pgid> — 0 when the set is empty within the bound
  local n="$1" i=0
  while :; do
    xo_stop_refresh "$2" "$3"
    [ -z "$(xo_stop_alive)" ] && return 0
    i=$((i + 1))
    [ "$i" -ge "$n" ] && return 1
    "${XO_PY:-python3}" -c 'import time; time.sleep(0.2)' 2>/dev/null || sleep 1
  done
}

# Stop the WHOLE chain and confirm it. 0 confirmed gone, 3 survivors (named in
# $XO_STOP_SURVIVORS), 1 nothing there to stop.
xo_stop_tree() { # <pid> [recorded-pgid] [gentle-signal]
  local pid="${1:-}" pgid="${2:-}" gentle="${3:-TERM}" round sig g p
  XO_STOP_SURVIVORS=""; XO_STOP_SET=""
  [ -n "$pid" ] || return 1
  xo_stop_refresh "$pid" "$pgid"
  # THE WALKER IS ALLOWED TO REFUSE, AND A REFUSAL IS NOT A DEATH. `xo-tree.py`
  # returns NOTHING when the recorded pid is the asking process or one of its
  # ancestors — a stop must never shoot the look, the shell or the viewscreen it
  # is running inside. That is the right call and it is MEASURED (an asker inside
  # the chain's own group gets an empty closure where a neutral asker gets four
  # lines). But "I declined to touch it" and "it is already gone" are different
  # facts, and reporting the first as the second is how a note ends up saying a
  # live chain is "no longer running". So it is reported as rc 2 — alive, not
  # signalled — which every caller already renders as "could not confirm".
  if ! printf '%s\n' "$XO_STOP_SET" | grep -qx "PID $pid"; then
    xo_pid_gone "$pid" && return 1
    return 2
  fi
  [ -z "$(xo_stop_alive)" ] && return 1

  # 1. THE DRIVER ALONE, GENTLY, so its own trap can tear its worker down.
  "$XO_KILL" -"$gentle" "$pid" 2>/dev/null || true
  xo_stop_wait 10 "$pid" "$pgid" && return 0

  # 2. EVERY GROUP THE CHAIN OWNS — including the ones it does not lead — then
  #    every loose pid besides. TERM, then KILL.
  for round in 1 2; do
    sig=TERM; [ "$round" -eq 2 ] && sig=KILL
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      "$XO_KILL" -"$sig" "-$g" 2>/dev/null || true
    done <<EOF
$(printf '%s\n' "$XO_STOP_SET" | sed -n 's/^GROUP //p' | sort -un)
EOF
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      "$XO_KILL" -"$sig" "$p" 2>/dev/null || true
    done <<EOF
$(printf '%s\n' "$XO_STOP_SET" | sed -n 's/^PID //p' | sort -un)
EOF
    xo_stop_wait 15 "$pid" "$pgid" && return 0
  done

  # 3. STILL THERE. Say which, and fail.
  XO_STOP_SURVIVORS="$(xo_stop_alive)"
  [ -z "$XO_STOP_SURVIVORS" ] && return 0
  printf '◈ NUMBER ONE: I signalled the chain and it is STILL RUNNING — pid(s) %s. Nothing was confirmed stopped.\n' \
    "$XO_STOP_SURVIVORS" >&2
  return 3
}

# Stop EXACTLY the chain a pid file was written about — or refuse.
#   0  the recorded chain was stopped, AND confirmed gone from the process table
#   1  there is nothing there any more (no pid, or it has already gone)
#   2  the pid is alive but is NOT the process this file was written about, or
#      the file never recorded who it was. WE DO NOT SIGNAL IT. A stop button
#      that stops the wrong process is worse than one that admits it cannot.
#   3  it was signalled and something is STILL ALIVE. The survivors are named in
#      $XO_STOP_SURVIVORS. The caller must NOT claim a stop, and must NOT drop
#      the pid file — that handle is the captain's only way to try again.
xo_signal_pidfile() { # <file> [signal]
  local file="$1" sig="${2:-TERM}" pid pgid started now
  XO_STOP_SURVIVORS=""
  pid="$(sed -n '1p' "$file" 2>/dev/null | tr -dc '0-9')"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  pgid="$(sed -n '2p' "$file" 2>/dev/null | tr -dc '0-9')"
  started="$(sed -n '3p' "$file" 2>/dev/null | sed 's/^ *//; s/ *$//')"
  [ -n "$started" ] || return 2
  now="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')"
  [ -n "$now" ] || return 1
  [ "$now" = "$started" ] || return 2
  xo_stop_tree "$pid" "$pgid" "$sig"
  return $?
}

# ===========================================================================
# ONE LOOK AT A TIME, ON ONE MISSION (S240 fix round 4, D1)
# ===========================================================================
#
# THE DEFECT, MEASURED on a live mission 2026-10-02: two Number One looks ran
# CONCURRENTLY on ONE mission and nothing refused, warned, or noticed. Both
# wrote the same `xo/` directory. `number-one.jsonl` came out interleaved. And
# the SECOND look overwrote `verdict.json` and `report.md` AFTER the first had
# already filed its bugs — so the record the captain reads is not the record
# the bugs were filed from. That is the worst thing a reviewer can do: hand him
# a verdict and a set of tickets that disagree, with no sign that they do.
#
# WHY `xo.pid` DID NOT STOP IT. It is not a lock and never was. It is written
# AFTER the decision to proceed, it is a plain overwrite (the second writer
# simply replaces the first's number), and it was EMPTY throughout the measured
# incident because each look removes it on its way out — so every reader asking
# "is a look running" got "no" from a file one of two live looks had just
# deleted. A record of what is happening cannot double as the permission to
# make it happen.
#
# WHY `lcars_xo_lock_reason` DID NOT STOP IT EITHER. That lock reads the
# mission's RECORDED `numberOne.status`, and it guards the captain's write
# verbs (approve, respond, pause, log, feedback) against racing a look. It is
# a STATE check, read-then-act, with a window between the two — and
# `cmd_evaluate` never consulted it at all.
#
# SO THE CLAIM IS A DIRECTORY. `mkdir` is the one filesystem primitive that is
# atomic and that FAILS when the thing already exists, on every filesystem
# this runs on, with no dependency to install. Exactly one of any number of
# concurrent `mkdir`s wins; every loser learns it lost from the syscall, not
# from a file it read a moment earlier.
#
# A DEAD OWNER IS NOT AN OWNER. A look killed outright — a laptop asleep, a
# SIGKILL, a crashed session — cannot run a trap, so its claim stays on disk
# with nothing behind it. If that deadlocked the mission the cure would be
# worse than the defect: the captain would be left running `rm -rf` inside
# `.git/` to get his own mission back. So a claim records WHO holds it the same
# way `xo_write_pidfile` does (pid + the instant it started, both read from the
# OS while they were still known), and a claim whose owner is gone — or whose
# pid has been recycled onto a different process — is RECLAIMED, out loud.
XO_CLAIM_DIR=""

# xo_claim_or_die <mission-dir> <what> — take the mission, or refuse in one line.
xo_claim_or_die() { # <mission-dir> <what>
  local dir="$1" what="${2:-a look}"
  # A SEPARATE STATEMENT, ON PURPOSE. `local a="$1" b="$a/x"` expands every
  # word before any assignment lands, so `$a` is still unset — which under
  # `set -u` is not a wrong path but an outright crash.
  local lock="$dir/xo.claim" owner=""
  local held_pid held_started held_what held_when now tries=0
  mkdir -p "$dir" 2>/dev/null || true
  while [ "$tries" -lt 3 ]; do
    tries=$((tries + 1))
    if mkdir "$lock" 2>/dev/null; then
      # WE OWN IT. The identity goes in only after the atomic win, so a reader
      # can never see a half-written owner file as a valid claim — an owner
      # file that is not there yet reads as "unknown", which is handled below.
      { printf '%s\n' "$$"
        printf '%s\n' "$(ps -o lstart= -p "$$" 2>/dev/null | sed 's/^ *//; s/ *$//')"
        printf '%s\n' "$what"
        printf '%s\n' "${NOW_LOCAL:-$(date '+%Y-%m-%d %H:%M')}"
      } >"$lock/owner" 2>/dev/null || true
      XO_CLAIM_DIR="$lock"
      return 0
    fi
    # Somebody holds it. Is anybody actually there?
    #
    # THE OWNER FILE MAY NOT BE THERE YET, AND THAT IS NOT STALE. There is a
    # real window between the winner's `mkdir` and its write of `owner`, and a
    # loser that read the directory inside that window found no pid, took the
    # stale branch, and DELETED THE WINNER'S CLAIM. MEASURED: one run in four
    # of the two-process race refused with "clearing a stale claim" instead of
    # "already looking at", which is the mutual exclusion failing open —
    # exactly the defect this function exists to stop, one millisecond wide.
    #
    # So an empty owner is WAITED for, briefly, before it is believed. A claim
    # whose owner never appears at all really is debris and still gets cleared
    # on the next pass.
    owner="$lock/owner"
    local ow=0
    while [ "$ow" -lt 30 ] && [ ! -s "$owner" ]; do
      ow=$((ow + 1))
      "${XO_PY:-python3}" -c 'import time; time.sleep(0.05)' 2>/dev/null || sleep 1
    done
    held_pid="$(sed -n '1p' "$owner" 2>/dev/null | tr -dc '0-9')"
    held_started="$(sed -n '2p' "$owner" 2>/dev/null | sed 's/^ *//; s/ *$//')"
    held_what="$(sed -n '3p' "$owner" 2>/dev/null)"
    held_when="$(sed -n '4p' "$owner" 2>/dev/null)"
    if [ -n "$held_pid" ] && kill -0 "$held_pid" 2>/dev/null; then
      now="$(ps -o lstart= -p "$held_pid" 2>/dev/null | sed 's/^ *//; s/ *$//')"
      if [ -z "$held_started" ] || [ "$held_started" = "$now" ]; then
        # ALIVE AND GENUINELY THE SAME PROCESS. ONE PLAIN LINE, naming the look
        # that has the mission and what to do about it. No second look starts.
        die "Number One is already looking at $(basename "$dir") — ${held_what:-a look} started${held_when:+ $held_when} (pid $held_pid). I will not run a second look on the same mission; that is how one verdict ends up overwriting the other's. Wait for it, or stop it with \`lcars xo off $(basename "$dir")\`."
      fi
      # The pid is alive but is NOT who the claim was written about — it has
      # been recycled. The claim is stale.
    fi
    # STALE. Nobody is there (or the pid belongs to something else now), so the
    # mission is reclaimable. Said out loud, because a captain who sees a look
    # start where he expected a refusal deserves to know why.
    printf '◈ NUMBER ONE: clearing a stale claim on %s — its look (pid %s) is gone.\n' \
      "$(basename "$dir")" "${held_pid:-unknown}" >&2
    rm -rf "$lock" 2>/dev/null || true
  done
  die "could not take $(basename "$dir") — something keeps re-claiming it. Nothing was looked at."
}

# ── A DETACHED CHAIN IN A SESSION OF ITS OWN (S240 fix round 4, D3) ────────
#
# `file_logs_for` hands the logged bugs to `resolve-logs.sh` detached: it files
# issues, cuts branches and runs a worker per stage per bug, unattended, for a
# long time. `lcars xo off` must be able to stop ALL of that with one signal.
#
# THE CODE CLAIMED `setsid` GAVE IT ITS OWN PROCESS GROUP. MEASURED with
# `ps -o pid,pgid,ppid` (never from the man page):
#
#   setsid on PATH: ABSENT          ← macOS ships none; the nohup fallback ran
#   LOOK    pid=25669 pgid=25654
#   DRIVER  pid=25680 pgid=25654    ← the LOOK's group, not its own
#   WORKER  pid=25692 pgid=25654    ← same group again
#   xo-resolve.pid:  pid=25680 pgid=25654
#
# Two measured consequences: a kill of the recorded group would have taken the
# look down with it, and the guard that (correctly) refused to do that stopped
# ONE process — "DRIVER gone / WORKER STILL ALIVE". One billed worker left
# running with nothing watching it, and no second verb to stop it.
#
# So the session is made properly. `setsid(1)` where there is one; otherwise
# `os.setsid()` through the shipped two-line `setsid.py` — the same syscall, on
# every machine that has python3, and `execvp` keeps the pid so `$!` still
# names the command after the new session exists. $LCARS_XO_SETSID=none forces
# the bare fallback, which is how the no-session-maker case is proven.
XO_SETSID_PY="$SKILL_DIR/setsid.py"

# xo_spawn_detached <pidfile> <logfile> <cmd...> — start it detached, in its own
# session where that is possible, record WHO it is, and echo its pid.
# ONE implementation: `file_logs_for` and the `detach` test seam both call this,
# so a proof about one is a proof about the other.
xo_spawn_detached() { # <pidfile> <logfile> <cmd...>
  local pidfile="$1" log="$2"; shift 2
  local child="" mode="${LCARS_XO_SETSID:-auto}"
  if [ "$mode" != "none" ] && command -v setsid >/dev/null 2>&1; then
    setsid "$@" </dev/null >>"$log" 2>&1 &
    child=$!
  elif [ "$mode" != "none" ] && [ -f "$XO_SETSID_PY" ] \
       && command -v "$XO_PY" >/dev/null 2>&1; then
    "$XO_PY" "$XO_SETSID_PY" "$@" </dev/null >>"$log" 2>&1 &
    child=$!
  else
    # NO WAY TO MAKE A SESSION. It still runs — a stop verb is never a reason
    # not to do the work — and xo_write_pidfile records no group for it, so
    # nothing can kill the wrong one.
    nohup "$@" </dev/null >>"$log" 2>&1 &
    child=$!
  fi
  disown "$child" 2>/dev/null || disown 2>/dev/null || true
  # WAIT FOR THE SESSION TO EXIST BEFORE WRITING IT DOWN. There is a real race
  # here and it was MEASURED, not imagined: `&` returns the moment the fork
  # happens, and `os.setsid()` runs a few milliseconds LATER inside the child —
  # so reading `ps -o pgid=` immediately caught the child still in its parent's
  # group, xo_write_pidfile's borrowed-group guard (correctly) recorded nothing,
  # and the session the child DID go on to lead was never written down. The
  # whole group kill then had nothing to aim at.
  #
  # So this waits, briefly and boundedly, for the child to actually lead a
  # group. It stops the instant it does, the instant the child is gone, or
  # after the bound — and on the fallback path (no session-maker at all) it
  # simply spends the bound and records no group, which is the right answer.
  if [ "$mode" != "none" ]; then
    local w=0 cur=""
    while [ "$w" -lt 40 ]; do
      kill -0 "$child" 2>/dev/null || break
      cur="$(ps -o pgid= -p "$child" 2>/dev/null | tr -dc '0-9')"
      [ "$cur" = "$child" ] && break
      w=$((w + 1))
      "${XO_PY:-python3}" -c 'import time; time.sleep(0.05)' 2>/dev/null || sleep 1
    done
  fi
  # WHO it is, not just which number — so a stop can never mistake a recycled
  # pid for it. Both facts are read from `ps` at the same instant, so what is
  # recorded is self-consistent.
  xo_write_pidfile "$child" "$pidfile"
  printf '%s' "$child"
}

# Give it back. ONLY if we are the recorded owner: a process that lost the race
# must never delete the winner's claim on its way out.
xo_release_claim() {
  [ -n "$XO_CLAIM_DIR" ] || return 0
  local held
  held="$(sed -n '1p' "$XO_CLAIM_DIR/owner" 2>/dev/null | tr -dc '0-9')"
  if [ -z "$held" ] || [ "$held" = "$$" ]; then
    rm -rf "$XO_CLAIM_DIR" 2>/dev/null || true
  fi
  XO_CLAIM_DIR=""
  return 0
}

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

  # ===========================================================================
  # TWO PIDS, AND BOTH OF THEM STOP (S213 — this REVERSES the S204 rule).
  #
  #   xo.pid          the first officer's OWN chain — the worker, the browser,
  #                   the launch.
  #   xo-resolve.pid  the `lcars resolve-logs` driver working the logged bugs:
  #                   a detached chain that files issues, cuts branches and runs
  #                   a worker per stage per bug, for a long time, unattended.
  #
  # S204 signalled the first and deliberately left the second running, reasoning
  # that the logged bugs are ordinary Missions the captain never asked to stop.
  # That reasoning is sound about the WORK and wrong about the BUTTON. What it
  # produced in practice was a stop button that did not stop: the only way to
  # halt a chain in flight was to find its pid and kill it by hand, which is not
  # something the product should ever ask of anybody, and is exactly what a
  # person does at the moment they least want to be careful about pids.
  #
  # So the chain stops. What it has already done is untouched — every child
  # Mission keeps its issue, its branch and whatever stage it reached, and the
  # captain picks any of them up himself. Nothing is deleted and nothing is
  # rolled back; only the driving stops.
  local rpid rlive=0 nlogs=0
  rpid="$(head -1 "$dir/xo-resolve.pid" 2>/dev/null | tr -dc '0-9')"
  if [ -n "$rpid" ] && kill -0 "$rpid" 2>/dev/null; then rlive=1; fi
  if [ -f "$dir/xo/logs.json" ]; then
    nlogs="$(grep -o '"mission"' "$dir/xo/logs.json" 2>/dev/null | grep -c . | tr -d ' ')"
    nlogs="${nlogs:-0}"
  fi

  # A LIVE RESOLVE CHAIN IS ALSO A LIVE SPIN (fix round 5, D1). This branch was
  # gated on the look's status and the look's pid alone, so once a FAILED stop
  # had written `stood-down`, a second `lcars xo off` fell straight through to
  # the opt-out path and signalled nothing at all — the captain's retry was a
  # no-op over a tree that was still billing. The recorded resolve pid is the
  # truth about whether a chain is running, so it is a reason to act.
  if [ "$status" = "engaged" ] || [ "$live" -eq 1 ] || [ "$rlive" -eq 1 ]; then
    if [ -n "$pid" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      rm -f "$dir/xo.pid"
    fi
    # THE CHAIN STOPS TOO — the WHOLE chain, across the process groups its
    # workers deliberately lead (see xo_stop_tree), and only ever a chain the
    # pid file was genuinely written about. A pid that is alive but is no longer
    # that process is left strictly alone and said out loud below.
    local rstopped=0 runsure=0 sfail=0 survivors=""
    if [ "$rlive" -eq 1 ]; then
      xo_signal_pidfile "$dir/xo-resolve.pid"
      case $? in
        0) rstopped=1; rm -f "$dir/xo-resolve.pid" ;;
        2) runsure=1 ;;
        # SIGNALLED AND STILL RUNNING. The pid file STAYS — it is the captain's
        # only handle on the tree, and a failed stop that erases its own handle
        # was the worst part of the measured defect. Nothing claims a stand-down
        # from here: not the status, not the note, not the CLI, not the exit
        # status.
        3) runsure=1; sfail=1; survivors="$XO_STOP_SURVIVORS"
           XO_STOP_FAILED=$((XO_STOP_FAILED + 1))
           XO_STOP_FAILED_PIDS="$XO_STOP_FAILED_PIDS $survivors"
           XO_STOP_FAILED_ON="$XO_STOP_FAILED_ON $id" ;;
      esac
    fi
    if [ "$sfail" -eq 0 ]; then
      obj="$(obj_set "$obj" status "$(jstr stood-down)")"
    fi
    local sd_note="Number One stood down $NOW_LOCAL · you have the conn"
    if [ "$rlive" -eq 1 ] && [ "$nlogs" -gt 0 ]; then
      # THE NOTE SAYS WHAT IS STILL HAPPENING. A captain who stands his first
      # officer down mid-fix-round has two things he needs to know and cannot
      # see: the fixes are still going, and the gate at the end of them is now
      # his. Both in one sentence, on the card, the CLI and the comment.
      # SINGULAR OR PLURAL, PROPERLY (S204 fix round 1, D5). "1 logs still
      # driving" on the card is the kind of small wrongness that makes a
      # captain distrust the numbers beside it.
      local lognoun="logs"; [ "$nlogs" -eq 1 ] && lognoun="log"
      if [ "$rstopped" -eq 1 ]; then
        # WHAT HAPPENED TO HIM, in his words: the fixes have stopped where they
        # got to, and nothing they had already done was thrown away.
        sd_note="Number One stood down $NOW_LOCAL · the $nlogs $lognoun it was driving stopped where they got to · you have the conn"
      elif [ "$runsure" -eq 1 ]; then
        sd_note="Number One stood down $NOW_LOCAL · it could not confirm the $nlogs $lognoun it was driving have stopped · you have the conn"
      else
        sd_note="Number One stood down $NOW_LOCAL · the $nlogs $lognoun it was driving are no longer running · you have the conn"
      fi
    fi
    # AND THE LAST WORD BELONGS TO WHAT WAS OBSERVED (fix round 5, D1). Written
    # after every other note so nothing downstream can overwrite it: no "stood
    # down", no "you have the conn". A card that hands the captain the conn
    # while a paid worker is still running is the same lie as the CLI line, on
    # the surface he trusts more.
    if [ "$sfail" -eq 1 ]; then
      sd_note="Number One could NOT stop what it was driving — still running: ${survivors:-unknown} · nobody has the conn yet · run \`lcars xo off $id\` again"
    fi
    obj="$(obj_set "$obj" note "$(jstr "$sd_note")")"
    obj="$(obj_set "$obj" since "$(jstr "$NOW")")"
    # THE GATE COMES BACK WITH THE CONN (fix round 1, D4). `lastPending` is the
    # cksum of the gate Number One took, written BEFORE the spin so that a crash
    # cannot buy a second worker. A spin killed HERE never answered anything, so
    # leaving the stamp would lock the first officer out of that gate for ever —
    # it would see its own memory of a question it never got to read. Clearing it
    # is what makes `lcars xo on <id>` able to pick the gate up again.
    obj="$(obj_del "$obj" lastPending)"
    # THE COUNTER IS WHAT THE CLI SAYS OUT LOUD, so a stop that did not happen
    # must not reach it (fix round 5, D1) — and the journal records what was
    # OBSERVED, which on this branch is a stop that failed, not a stand-down.
    if [ "$sfail" -eq 1 ]; then
      journal "$dir" stop-failed \
        "$(printf '"stage": %s, "detail": %s' \
             "$(jstr "$(mission_stage "$st")")" \
             "$(jstr "signalled the chain and it is still running: ${survivors:-unknown}")")"
    else
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
# STOPS THAT DID NOT STOP (fix round 5, D1). Counted and NAMED, so the verb can
# refuse to print a stand-down and can exit non-zero — the two things the
# measured defect got wrong after it had already missed the paid worker.
XO_STOP_FAILED=0
XO_STOP_FAILED_PIDS=""
XO_STOP_FAILED_ON=""

write_config_block() { # <enabled true|false> [engine] [model]
  local enabled="$1" engine="${2:-}" model="${3:-}" obj
  obj="{\"enabled\": $enabled}"
  [ -n "$engine" ] && obj="$(obj_set "$obj" engine "$(jstr "$engine")")"
  [ -n "$model" ]  && obj="$(obj_set "$obj" model  "$(jstr "$model")")"
  lcars_config_set_or_add_raw "$CONFIG" numberOne "$obj" \
    || die "could not write .git/lcars/config.json."
}

cmd_on() {
  # DEFAULT 0 — SWITCHING NUMBER ONE ON STARTS NOTHING (S241, the captain's
  # ruling). The catch-up is KEPT, in full, but it is now its own word. See the
  # note at the sweep call below for the whole reasoning.
  #
  # EMPTY, NOT 0, so an explicit flag can be told apart from the default and
  # outrank the environment: `--sweep` is the captain at the terminal,
  # $LCARS_XO_SWEEP_ON_START is a machine's standing preference, and the person
  # present wins.
  local engine="" model="" target="" sweep=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --engine)   engine="${2:-}"; shift 2 || true ;;
      --engine=*) engine="${1#--engine=}"; shift ;;
      --model)    model="${2:-}";  shift 2 || true ;;
      --model=*)  model="${1#--model=}"; shift ;;
      # SPENDING, ASKED FOR OR DECLINED (S240 fix round 4, D1). Since S241
      # `--sweep` is the OPT-IN that starts the catch-up, and `--no-sweep` is
      # the default said out loud. Both still work, in both directions.
      --sweep)     sweep=1; shift ;;
      --no-sweep)  sweep=0; shift ;;
      -*)         die "unknown option: $1" ;;
      *)          target="$1"; shift ;;
    esac
  done
  # THE ESCAPE HATCH, both directions, no code edit either way: `lcars xo on
  # --sweep` — or $LCARS_XO_SWEEP_ON_START=1 for an autopilot with no argv to
  # change — restores the pre-S241 behaviour exactly: switch on AND work the
  # backlog. A flag on the command line beats the variable.
  if [ -z "$sweep" ]; then
    case "${LCARS_XO_SWEEP_ON_START:-0}" in
      1|true|yes|on) sweep=1 ;;
      *)             sweep=0 ;;
    esac
  fi

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
  # AND IT PICKS UP WHAT IS ALREADY WAITING (part G). Switching it on is the
  # captain saying "I have to step out"; a first officer who ignored the two
  # missions already parked at Verify would not be taking the conn at all.
  #
  # ── THE MEASURED SURPRISE, AND WHY THE DEFAULT IS NOW "ANNOUNCE" ─────────
  # (S240 fix round 4, D1 measured it; S241 is the captain's ruling on it.)
  #
  # `lcars xo on --engine copilot` reads, in every word of it, like changing a
  # setting — and it used to sweep every scoreless mission at Verify into a
  # real look: launching builds, driving a browser, hiring workers, filing
  # bugs. Five missions parked meant five reviews from one word, and the
  # captain's money spent as the side effect of a config change. It was never
  # secret — it announced itself first — but announcing real work is not the
  # same as being asked to do it.
  #
  # HIS RULING: KEEP THE CATCH-UP, MAKE IT OPT-IN. So the default path is
  # `xo_sweep_announce` — it names every mission waiting and the one command
  # that starts them, for free, and returns. Nothing is launched, nothing is
  # billed, and the verb exits in the time it takes to read some state files.
  #
  # IT NEVER ASKS. There is no prompt here and there must never be one: this
  # product's whole point is the unattended overnight run, and a verb that
  # waited for a keystroke would hang it until morning. Announce and exit, or
  # run because a flag said to. Those are the only two shapes.
  #
  # WHAT DID NOT CHANGE. The opt-in path is the SAME `xo_sweep_verify` as
  # before — same cage per look, same one-at-a-time order, same stand-down
  # check between missions. And the gate hook is untouched: a mission that
  # ARRIVES at Verify later is still engaged by the driver, which is where that
  # decision has always belonged. `xo on` picking up the backlog was only ever
  # about missions already parked when the switch was thrown.
  if [ "$sweep" -eq 1 ]; then
    xo_sweep_verify
  else
    xo_sweep_announce
  fi
}

# xo_sweep_announce — THE DEFAULT PATH of `lcars xo on` since S241, and the
# FREE half of the sweep: name what is waiting and the one command that starts
# it. No launch, no browser, no worker, no spend, and NO PROMPT — it returns
# instead of asking, so an unattended run can never block here. It shares
# `xo_sweepable` with the sweep itself, so the two can never disagree about
# which missions are in scope.
xo_sweep_announce() {
  [ "${LCARS_XO_SWEEP:-1}" = "0" ] && return 0
  local id n=0 names=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    xo_sweepable "$id" || continue
    n=$((n + 1))
    names="${names:+$names, }$id"
  done <<< "$(all_missions)"
  [ "$n" -gt 0 ] || return 0
  if [ "$n" -eq 1 ]; then
    printf '  1 mission is waiting at Verify with no score of mine: %s.\n' "$names"
  else
    printf '  %d missions are waiting at Verify with no score of mine: %s.\n' "$n" "$names"
  fi
  printf '  Reviewing them launches each build and spends a worker, so it is its own word:\n'
  printf '    lcars xo on --sweep\n'
  return 0
}

# ===========================================================================
# PART G (S220) — SWITCHING NUMBER ONE ON PICKS UP WHAT IS ALREADY WAITING
# ===========================================================================
#
# THE DEFECT THIS EXISTS FOR, in the captain's own words (2026-09-19): *"a
# captain having missions at verify, they go 'I have to step out' and turn
# Number One on. I'd expect it to see missions in verify it hasn't done and
# work on evaluating and filing bugs."* Until now `lcars xo on` only armed the
# hook that fires when a run ARRIVES at Verify, so switching it on beside two
# missions already parked there did nothing at all to them.
#
# HIS RULING ON SCOPE, the same morning: **"Review everyone at verify that
# doesn't have a previous Number One score."** So the sweep's question is not
# "has it been looked at recently" or "does it look stale" — it is one recorded
# fact: is there a score on record?
#
# READ FROM THE RECORD, NEVER INFERRED. Three places carry a score, and all
# three are read: `numberOne.score` (and `score2`, the recheck's), and the
# look's own `xo/verdict.json`. A mission with any of them is left alone.
#
# LEFT ALONE, ALSO: a mission the captain opted out (`lcars xo off <id>`), a
# mission that is not at Verify, a bug child (it has no build of its own — the
# same rule the Verify hook obeys), and a mission from ANOTHER LAPTOP: a remote
# mission's build is not here to look at and its owner is not us.
xo_has_score() { # <mission-dir> — 0 when a score is ON RECORD
  local m="$1" st="$m/state.json" obj
  [ -f "$m/xo/verdict.json" ] && return 0
  obj="$(state_xo_block "$st" 2>/dev/null)"
  [ -n "$(obj_get "$obj" score)" ] && return 0
  [ -n "$(obj_get "$obj" score2)" ] && return 0
  return 1
}

xo_sweepable() { # <mission-id> — 0 when this one is the sweep's to take
  local id="$1" m="$MISSIONS_DIR/$id" st="$MISSIONS_DIR/$id/state.json" obj
  [ -f "$st" ] || return 1
  [ "$(mission_stage "$st")" = "verify" ] || return 1
  obj="$(state_xo_block "$st" 2>/dev/null)"
  case "$obj" in *'"optOut"'*true*) return 1 ;; esac
  # A bug child folds onto its parent's branch and has no build of its own.
  grep -q '"parentMission"[[:space:]]*:[[:space:]]*"' "$st" 2>/dev/null && return 1
  # ANOTHER LAPTOP'S. `cloneId` is stamped by the clone that filed it; a
  # mission stamped with a different one is not ours to review.
  local mine theirs
  mine="$(lcars_config_get "$CONFIG" cloneId 2>/dev/null)"
  theirs="$(sed -n 's/.*"cloneId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$st" 2>/dev/null | head -1)"
  [ -n "$mine" ] && [ -n "$theirs" ] && [ "$mine" != "$theirs" ] && return 1
  xo_has_score "$m" && return 1
  return 0
}

# THE SWEEP ITSELF. One mission at a time, in filing order, and it asks two
# questions BETWEEN missions — is Number One still on, and is this one still
# in scope — so standing it down stops the chain where the captain expects it
# to stop: after the round in flight, never in the middle of one (S213).
#
# `$LCARS_XO_SWEEP_BIN` is how a test drives it without spending: it is the
# command run per mission in place of this script's own `evaluate`.
xo_sweep_verify() {
  [ "${LCARS_XO_SWEEP:-1}" = "0" ] && return 0
  local ids="" id n=0 names=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    xo_sweepable "$id" || continue
    ids="$ids$id
"
    n=$((n + 1))
    names="${names:+$names, }$id"
  done <<< "$(all_missions)"
  [ "$n" -gt 0 ] || return 0
  # IN PLAIN WORDS, on the way in — the captain is walking away and this is the
  # last thing he reads.
  if [ "$n" -eq 1 ]; then
    printf "  I'm reviewing 1 mission that was waiting at Verify with no score of mine: %s.\n" "$names"
  else
    printf "  I'm reviewing %d missions that were waiting at Verify with no score of mine: %s.\n" "$n" "$names"
  fi
  printf '  One at a time. `lcars xo off` stops it after the one in flight.\n'
  local sweepbin="${LCARS_XO_SWEEP_BIN:-}"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    # BETWEEN MISSIONS, both questions again: the captain may have stood it
    # down while the last round was running, and that has to stop the chain.
    cfg_enabled || { printf '  Stood down — I stopped before %s.\n' "$id"; break; }
    xo_sweepable "$id" || continue
    journal "$MISSIONS_DIR/$id" swept '"why": "at Verify with no score of mine when Number One was switched on"'
    printf '◈ NUMBER ONE: taking %s — it was waiting at Verify.\n' "$id"
    # CAGED, LIKE EVERY OTHER LOOK (S221, captain 2026-09-20). This path used to
    # spawn a look with no time limit at all, so one build that would not answer
    # could hold the sweep — and every mission queued behind it — open all night
    # while he was out. The cage is `xo_cage`, the SAME helper the declared seed
    # and the project's own suite are run under, and 124 is its "it outstayed
    # the limit" exit.
    local rc=0
    if [ -n "$sweepbin" ]; then
      xo_cage "$XO_LOOK_TIMEOUT" "$sweepbin" "$id" </dev/null || rc=$?
    else
      xo_cage "$XO_LOOK_TIMEOUT" bash "$SELF" evaluate --mission "$id" </dev/null || rc=$?
    fi
    # LOUDLY, AND IN THE RECORD. A look that was stopped part-way has not scored
    # anything, and the one thing this must never do is let a half-look read as
    # a quiet success — so it is said on his screen AND journaled on the mission
    # that hit it, which is where the next reader will look.
    if [ "$rc" -eq 124 ]; then
      printf '◈ NUMBER ONE: %s was still looking after %s, so I stopped it — it scored nothing.\n' \
        "$id" "$(xo_dur_words "$XO_LOOK_TIMEOUT")"
      printf '  Run `lcars xo evaluate --mission %s` yourself to see where it got stuck.\n' "$id"
      journal "$MISSIONS_DIR/$id" sweep-timeout \
        "$(printf '"limitSeconds": %s, "why": "the look outstayed its cage and was stopped — nothing was scored"' "$XO_LOOK_TIMEOUT")"
    fi
  done <<< "$ids"
  return 0
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
    # THE FAILED STOP SPEAKS FIRST, AND NOTHING AFTER IT CLAIMS THE CONN
    # (fix round 5, D1). The measured defect printed "stood down … you have the
    # conn" and exited 0 over a live paid assistant, and had already deleted the
    # handle that would have let the captain try again. All three are refused
    # here: no stand-down line, the surviving pids named, non-zero exit — and
    # `stand_down` keeps `xo-resolve.pid` on disk so the retry below is real.
    if [ "$XO_STOP_FAILED" -gt 0 ]; then
      xo_say_stop_failed "$id"
      return 1
    fi
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
  # Same rule repo-wide: the switch is off, but a tree that is still running is
  # said out loud and the verb fails. "OFF" above is a fact about the config;
  # it is not, and must not read as, a claim about what has stopped.
  if [ "$XO_STOP_FAILED" -gt 0 ]; then
    xo_say_stop_failed "$(printf '%s' "$XO_STOP_FAILED_ON" | sed 's/^ *//')"
    return 1
  fi
  return 0
}

# ONE writer for the failed-stop sentence, so the single-mission and repo-wide
# verbs cannot drift into saying different things about the same situation.
xo_say_stop_failed() { # <mission(s)>
  local who="${1:-}" pids
  pids="$(printf '%s' "$XO_STOP_FAILED_PIDS" | tr ' ' '\n' | sed '/^$/d' \
            | sort -un | tr '\n' ' ' | sed 's/ *$//')"
  printf '◈ NUMBER ONE: I could NOT stop everything on %s. Still running: pid(s) %s.\n' \
    "${who:-the mission}" "${pids:-unknown}" >&2
  printf '  YOU DO NOT HAVE THE CONN — one of those is a worker that bills.\n' >&2
  printf '  I kept the handle, so try again: `lcars xo off %s`. If it survives that too, `kill -9 %s`.\n' \
    "${who%% *}" "${pids:-<those pids>}" >&2
  return 0
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
      # S205: SCORE, between NUMBER ONE and NOTE — the latest look's intent
      # match (score2 once a recheck has run, else the first score), so the
      # table answers "how close is it" without opening a card. Inserted, not
      # appended: NOTE stays the last, un-padded column exactly as before.
      printf '\n  %s %s %s %s %s\n' "$(col MISSION 26)" "$(col STAGE 13)" \
        "$(col 'NUMBER ONE' 12)" "$(col SCORE 8)" NOTE
      any=1
    fi
    obj="$(state_xo_block "$st")"
    status="$(obj_get "$obj" status)"
    note="$(obj_get "$obj" note)"
    case "$obj" in *'"optOut": true'*) [ -n "$status" ] || status="opted-out" ;; esac
    stage="$(mission_stage "$st")"
    score="$(obj_get "$obj" score2)"
    [ -n "$score" ] || score="$(obj_get "$obj" score)"
    printf '  %s %s %s %s %s\n' "$(col "$m" 26)" "$(col "${stage:-?}" 13)" \
      "$(col "${status:-—}" 12)" "$(col "${score:-—}" 8)" "${note:-—}"
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
# S213 fix round 1, D4 — what a LOW means when the look never happened at all.
XO_NOLOOK="I never got to look at your build, so nothing on your list is vouched for either way"

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
xo_put_inputs() { # <input-dir> <criteria.json> <shots-dir> [observations.json] [tests.json] [walk.json]
  local into="$1" crit="$2" from="$3" obs="${4:-}" tst="${5:-}" walk="${6:-}" f
  [ -d "$into" ] || return 0
  chmod u+w "$into" 2>/dev/null || true
  if [ -f "$crit" ]; then
    rm -f "$into/criteria.json" 2>/dev/null || true
    cp "$crit" "$into/criteria.json" 2>/dev/null || true
    chmod a-w "$into/criteria.json" 2>/dev/null || true
  fi
  # OBSERVATIONS ARE PART OF WHAT THE WORKER SEES, NEVER PART OF WHAT IT WRITES
  # (S210). Handed over the same read-only door as criteria.json, so it can
  # cite one as evidence for a real gap — the prompt is what stops it inventing
  # a criterion from one, not the absence of the file.
  if [ -n "$obs" ] && [ -s "$obs" ]; then
    rm -f "$into/observations.json" 2>/dev/null || true
    cp "$obs" "$into/observations.json" 2>/dev/null || true
    chmod a-w "$into/observations.json" 2>/dev/null || true
  fi
  # THE PROJECT'S OWN TEST RESULT (S211) — through the same read-only door, for
  # the same reason. The worker may CITE it; it can never run it, and it can
  # never edit the record it is judged against.
  if [ -n "$tst" ] && [ -s "$tst" ]; then
    rm -f "$into/tests.json" 2>/dev/null || true
    cp "$tst" "$into/tests.json" 2>/dev/null || true
    chmod a-w "$into/tests.json" 2>/dev/null || true
  fi
  # THE PAIRS, AND THE DRAWING'S OWN CROPS (S220 part B). The pair file names
  # a crop of what was DRAWN and a crop of what was BUILT for every part, so
  # both sets of pictures have to be on the worker's side of the door — a pair
  # the worker cannot open is not a side-by-side, it is a sentence about one.
  local xodir_of="${crit%/criteria.json}"
  # THE WALK RECORD IS THIS LOOK'S, NOT THE LOOK BEFORE'S (S222 fix round 1).
  # A re-check writes its walk under its own look's name, and the caller says
  # which file that is; only a first look leaves it at `walk.json`. Handed the
  # wrong one, the S222 re-check worker read a walk that had not happened —
  # "walk.json shows the relaunched build walked that flow end to end" — beside
  # pictures that proved it had not. The journey is the PLAN and does not
  # change between looks, so it is always the one on record.
  [ -n "$walk" ] || walk="$xodir_of/walk.json"
  if [ -s "$walk" ]; then
    rm -f "$into/walk.json" 2>/dev/null || true
    cp "$walk" "$into/walk.json" 2>/dev/null || true
    chmod a-w "$into/walk.json" 2>/dev/null || true
  fi
  # THE SAME PLACE AT EVERY MOMENT (S224 fix round 3). Computed from the walk
  # record beside it, never declared by anyone: which strips of a screen read
  # differently from one moment of the walk to the next. It goes through this
  # same read-only door because a criterion about something that is on screen
  # the whole way through has SEVERAL moments it could be judged at, and the
  # look was settling those on whichever picture it reached for.
  if [ -s "$xodir_of/readings.json" ]; then
    rm -f "$into/readings.json" 2>/dev/null || true
    cp "$xodir_of/readings.json" "$into/readings.json" 2>/dev/null || true
    chmod a-w "$into/readings.json" 2>/dev/null || true
  fi
  if [ -s "$xodir_of/journey.json" ]; then
    rm -f "$into/journey.json" 2>/dev/null || true
    cp "$xodir_of/journey.json" "$into/journey.json" 2>/dev/null || true
    chmod a-w "$into/journey.json" 2>/dev/null || true
  fi
  if [ -s "$xodir_of/pairs.json" ]; then
    rm -f "$into/pairs.json" 2>/dev/null || true
    cp "$xodir_of/pairs.json" "$into/pairs.json" 2>/dev/null || true
    chmod a-w "$into/pairs.json" 2>/dev/null || true
  fi
  if [ -d "$xodir_of/drawing" ]; then
    chmod -R u+w "$into/drawing" 2>/dev/null || true
    mkdir -p "$into/drawing" 2>/dev/null || true
    for f in "$xodir_of/drawing"/*; do
      [ -f "$f" ] || continue
      [ -f "$into/drawing/$(basename "$f")" ] && continue
      cp "$f" "$into/drawing/" 2>/dev/null || true
    done
    chmod -R a-w "$into/drawing" 2>/dev/null || true
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

# --- ONE LOOK, ONE SHOTS DIRECTORY (S204 fix round 2, D1) -------------------
#
# THE DEFECT. `xo/shots` was ONE directory for the life of a mission. Every look
# wrote into it and nothing ever cleared it, so a second look was handed the
# first look's pictures as well as its own — and when the second look took FEWER
# shots than the first, the leftovers of the first were still sitting there under
# names the second never wrote. Number One then reasoned about them as if they
# were current and told the captain a flicker story about a line that was simply
# gone. It reached the right verdict that time only because the stale shot
# happened to be the last-numbered one; reverse the order and the identical
# mechanism argues a gap was FIXED when it was not.
#
# THE CURE. Every look gets its OWN directory — `xo/shots/look-1`,
# `xo/shots/recheck-1`, `xo/shots/recheck-2` — and the worker is handed that one
# and no other. NAMESPACED, NOT DELETED: the captain's walkthrough is built out
# of these pictures, and a `rm -rf` at the top of a look would destroy the
# evidence of the look before it (which is exactly what the overwrite-in-place
# already cost the tester once). Which directory a verdict was reasoned from
# goes in the journal, beside the look that reasoned from it.
xo_look_dir() { # <xo-dir> <look-name> — the dir for THIS look, created
  local d="$1/shots/$2"
  mkdir -p "$d" 2>/dev/null || true
  printf '%s' "$d"
}

# The first free `<stem>-<n>`. A look never reuses a directory, not even after a
# crash that left one half-written: a half-written look's shots are exactly the
# stale pictures this whole fix exists to keep out of the next look's evidence.
xo_next_look_name() { # <xo-dir> <stem>
  local x="$1" stem="$2" n=1
  while [ -d "$x/shots/$stem-$n" ]; do n=$((n + 1)); done
  printf '%s-%s' "$stem" "$n"
}

# WHERE THE LOOK THAT PRODUCED verdict.json PUT ITS PICTURES. `evaluate` records
# it in `xo/look.txt` as it opens the directory; `file-logs` reads it back so the
# shots it attaches to a bug are the ones the verdict actually cites. A mission
# from before this fix (or a test fixture that plants shots flat) has no pointer
# and no per-look dir — it falls back to the flat `xo/shots`, which is exactly
# where its pictures are.
xo_verdict_shots_dir() { # <xo-dir>
  local x="$1" rel=""
  [ -f "$x/look.txt" ] && rel="$(head -1 "$x/look.txt" 2>/dev/null)"
  if [ -n "$rel" ] && [ -d "$x/$rel" ]; then printf '%s' "$x/$rel"; return 0; fi
  printf '%s' "$x/shots"
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

# xo_journal_impact <mission-dir> <IMPACT_KEPT|IMPACT_MISMATCH> <tab fields> —
# S216 fix round 1 (D5). A later look that re-guessed a recorded impact
# (`impact-kept`: id, the recorded impact that won, the look's ignored one), or
# two near-identical requirements rated differently (`impact-mismatch`).
xo_journal_impact() {
  local dir="$1" kind="$2" a b c d
  IFS=$'\t' read -r a b c d <<<"$3"
  if [ "$kind" = IMPACT_KEPT ]; then
    journal "$dir" impact-kept "$(printf '"criterion": %s, "recorded": %s, "thisLook": %s' \
      "$(jstr "$a")" "$(jstr "$b")" "$(jstr "$c")")"
  elif [ "$kind" = TEST_DEMOTED ]; then
    # S216 fix round 2 (T1): a row rated on a test line that names no test case.
    journal "$dir" test-citation-demoted "$(printf '"criterion": %s, "rated": %s, "quote": %s' \
      "$(jstr "$a")" "$(jstr "$b")" "$(jstr "$c")")"
  else
    journal "$dir" impact-mismatch "$(printf '"criteria": [%s, %s], "impacts": [%s, %s]' \
      "$(jstr "$a")" "$(jstr "$b")" "$(jstr "$c")" "$(jstr "$d")")"
  fi
}

# WHAT THE LOOK LEFT FOR THE CAPTAIN, SAID OUT LOUD (S222 fix round 1). One
# line per escalation, in the look's own words — the same list that is
# journaled, so the terminal and the report can never disagree about what was
# put aside for him. Nothing at all when the list is empty.
xo_say_escalations() { # <newline-separated list>
  local line
  [ -n "${1:-}" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '◈ NUMBER ONE: this one is yours to decide — %s\n' "$line"
  done <<< "$1"
  return 0
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
# …and, since S211, a FOURTH: the project's own test suite, which may legitimately
# run for the whole five-minute bound.
XO_TESTS_PID=""
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
  # ONE LAST TIDY, with the app stopped so nothing can autosave behind us
  # (S221). Every exit path goes through here — success, LOW, error and signal —
  # so there is no way out of a look that leaves the captain's build dirty, and
  # launch.sh's own clean-tree audit still passes for the next launch.
  xo_tree_restore "$XO_MISSION_DIR"
  return 0
}

# ── THE BUILD IS LEFT AS IT WAS FOUND (S221) ────────────────────────────────
#
# THE DEFECT, in the captain's words (2026-09-20): walking a build means TYPING
# into it. On the groutwork build Number One typed an insight, the app autosaved
# it into the LAUNCHED WORKTREE'S OWN `data/` — which is where the project's
# snapshot tests read from — and six of the captain's own tests went red on a
# build that was fine. Number One correctly refused to blame the build; but
# unattended, the next round would have spent itself chasing red tests the look
# itself caused.
#
# WHY CLEANUP AND NOT A REDIRECT. A redirect would be the better fix and it is
# not available: nothing in LCARS knows where an arbitrary app keeps its data.
# `launch.sh` has no data-directory lever of any kind, there is no env var every
# stack honours, and inventing one would mean every project must adopt it before
# its Verify look is safe — exactly the "the harness works if you change your
# app" contract LCARS refuses. What IS universal is git: the launched build is a
# worktree, so what the walk changed is measurable, and measurably undoable.
#
# SURGICAL, NEVER A `git checkout -- .`. The mark is taken AFTER the declared
# seed has run (the seed's writes are wanted) and immediately before the first
# drive; the restore touches ONLY paths whose status differs from that mark. A
# file the launch itself left dirty, a build artefact, an ignored `node_modules`
# — none of them are this function's business, and a blunt reset would eat them.
XO_TREE_MARK=""
XO_TREE_WT=""

xo_tree_mark() { # <worktree> <markfile> — remember the tree before the walk
  local wt="${1:-}" out="${2:-}"
  XO_TREE_MARK=""; XO_TREE_WT=""
  [ -n "$wt" ] && [ -n "$out" ] && [ -d "$wt" ] && [ -e "$wt/.git" ] || return 0
  git -C "$wt" status --porcelain -z >"$out" 2>/dev/null || : >"$out"
  XO_TREE_MARK="$out"; XO_TREE_WT="$wt"
  return 0
}

# Undo exactly what changed since the mark, and say how much. Best-effort like
# every other aftercare here: a worktree that has gone away, a git that will not
# answer, a path it may not write — each leaves the look alone rather than
# failing it. Never fatal: tidying up must not be why the captain loses a look.
xo_tree_restore() { # <mission-dir> — reverts the walk's writes in the launched build
  local dir="${1:-}" n=0
  [ -n "$XO_TREE_WT" ] && [ -n "$XO_TREE_MARK" ] || return 0
  [ -d "$XO_TREE_WT" ] && [ -f "$XO_TREE_MARK" ] || return 0
  n="$("$XO_PY" - "$XO_TREE_WT" "$XO_TREE_MARK" 2>/dev/null <<'PY'
import os, shutil, subprocess, sys

wt, mark = sys.argv[1], sys.argv[2]

# `git status --porcelain -z` is the ONLY safe reading of this. The plain form
# C-quotes any path with a space, a quote or a non-ASCII byte in it (and
# core.quotePath can turn an ordinary name into `"caf\303\251.json"`), which is
# how a previous round in this repo got a path no `[ -e ]` would match. -z emits
# the raw bytes and separates records with NUL, so nothing is escaped.
def parse(text):
    seen, parts, i = {}, text.split("\0"), 0
    while i < len(parts):
        e = parts[i]
        if len(e) >= 4:
            code, path = e[:2], e[3:]
            seen[path] = code
            if "R" in code or "C" in code:
                i += 1          # a rename/copy spends a second record on its source
        i += 1
    return seen

def now():
    try:
        r = subprocess.run(["git", "-C", wt, "status", "--porcelain", "-z"],
                           capture_output=True, text=True, timeout=120)
        return parse(r.stdout)
    except Exception:
        return None

before = parse(open(mark, encoding="utf-8", errors="surrogateescape").read())
after = now()
if after is None:
    print(0); raise SystemExit(0)

root = os.path.realpath(wt)
changed = [(p, c) for p, c in sorted(after.items()) if before.get(p) != c]

def inside(p):
    # This deletes. Anything that does not resolve under the worktree — a
    # symlink out, a `..`, an absolute path — is not ours to touch.
    try:
        full = os.path.realpath(os.path.join(wt, p))
    except Exception:
        return None
    return full if full == root or full.startswith(root + os.sep) else None

undone = 0
restore = []
for p, c in changed:
    full = inside(p)
    if not full:
        continue
    if c.startswith("??"):
        try:
            if os.path.isdir(full) and not os.path.islink(full):
                shutil.rmtree(full)
            else:
                os.remove(full)
            undone += 1
        except Exception:
            pass
    else:
        restore.append(p)
if restore:
    try:
        # One call, paths after `--`, so a name that starts with a dash is a
        # path and never a flag.
        r = subprocess.run(["git", "-C", wt, "checkout", "--"] + restore,
                           capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            undone += len(restore)
    except Exception:
        pass
print(undone)
PY
)"
  n="${n:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  if [ "$n" -gt 0 ]; then
    printf '◈ NUMBER ONE: I typed into your build, so I put the %s file(s) I changed back as they were.\n' "$n"
    [ -n "$dir" ] && journal "$dir" tidied \
      "$(printf '"restored": %s, "why": "what the walk typed into the launched build, undone"' "$n")"
  fi
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
  [ -n "$XO_TESTS_PID" ] && xo_kill_tree "$XO_TESTS_PID"
  XO_DRIVE_PID=""; XO_SPIN_PID=""; XO_TESTS_PID=""
  xo_stop_launch
  [ -n "$XO_WORK_DIR" ] && xo_rm_work "$XO_WORK_DIR"
  XO_WORK_DIR=""
  # AND THE MISSION GOES BACK. The claim is held for the WHOLE process, not
  # just the looking part, because the measured defect was a second look
  # overwriting the verdict AFTER the first had filed its bugs from it. It is
  # released here, on the EXIT trap, so every way out of a look gives it back.
  xo_release_claim
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

  # =========================================================================
  # WHICH GATE IS THIS? READ THE RECORD, NEVER THE PROSE (S204).
  #
  # `resolve-logs.sh` raises ONE consolidated re-verify gate on a parent when
  # every logged bug has reached its Verify gate, and it RECORDS what that gate
  # is: `"kind": "reverify"` in pending.json. That recorded field is the only
  # thing this routing reads.
  #
  # WHY NOT THE QUESTION TEXT. Because the question text is prose, it is written
  # by people, and it changes. This project has paid for matching on prose three
  # times — S147's source parser (four generations, each beaten), S156's regex
  # classifier (recall 14/14 → 5/14 when the tester REWORDED its own corpus
  # preserving meaning), S188 — and every one of them was cured the same way:
  # record the fact at the producer instead of inferring it at the consumer.
  # A Verify park that happens to say "logged bugs" and "re-verify" is an
  # ordinary question about the captain's product, and answering it by
  # relaunching a browser would be this defect's fourth outing.
  #
  # `reverify-blocked` is the same producer saying the OPPOSITE thing: the fold
  # could not happen (a straggler, a push that failed, no branch). Number One
  # cannot clear any of those — they are the captain's — so it hands the gate
  # straight back rather than hiring a worker to think about it.
  # =========================================================================
  local pkind; pkind="$(pending_field "$pending" kind)"
  case "$pkind" in
    reverify)
      cmd_recheck --mission "$id"
      return $? ;;
    reverify-blocked)
      escalate "$dir" "$stage" \
        "the logged fixes could not be folded in, and unblocking it is yours — $(pending_first_question "$pending")" \
        "$(printf '"stage": %s, "reason": "reverify-blocked", "detail": %s' \
             "$(jstr "$stage")" "$(jstr "$(pending_first_question "$pending")")")" ;;
  esac

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
  # ONE AT A TIME, ON ONE MISSION (fix round 4, D1). Taken BEFORE the pidfile,
  # because the pidfile is a RECORD of a look and this is the PERMISSION for
  # one. The EXIT trap above gives it back on every path out.
  xo_claim_or_die "$dir" "a look at the ${stage:-?} gate"
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
  #   LCARS_XO_INTERNAL=<id>   the engaged lock is there to stop a SECOND hand on
  #                            the mission. This IS the first officer's hand —
  #                            locking it out of its own verb would be the lock
  #                            refusing the thing it was built to permit. The
  #                            marker NAMES this mission (S204 fix round 1, D1)
  #                            and exempts this call against THIS mission only,
  #                            where the old LCARS_XO_ENFORCE=0 switched the
  #                            lock off wholesale for everything it spawns.
  local rrc=0 rout
  rout="$(LCARS_RESPOND_RESUME=0 LCARS_ANSWERED_BY=number-one LCARS_XO_INTERNAL="$id" \
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
#      place the drawing names. `xo-drive.js` also records geometry for EVERY
#      VISIBLE element now, not only the named ones (S210) — capped, and the
#      cap and the drop count are said, never silent.
#   3b. THE OBSERVATIONS PASS (S210) — `xo-observe.py`, computed by the SKILL
#      from those same boxes: crowding, overlap, a misaligned row, clipped
#      text. NOT a gap, NEVER moves the score; its own section of the report,
#      and the worker may cite one as evidence but may not invent a criterion
#      from one.
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
# HOW MANY TIMES IT MAY GO BACK AND LOOK AGAIN — TWO (captain's ruling,
# 2026-09-20; it was three). This is a CEILING, not a quota: the worker writes
# its verdict the moment it has seen enough, and measured over five real-arm
# runs on the same benchmark the third round bought nothing at all — 3 rounds
# scored 4/5, 2 scored 3/5, 2 scored 5/5, 1 scored 5/5, 1 scored 5/5. Lowering
# it takes an unused hour off the worst case and cannot cost a look that was
# going to finish anyway.
#
# THE NUMBER LIVES HERE AND NOWHERE ELSE. The console line ("round 1 of 2"), the
# refusal a look with no verdict writes, and the budget the WORKER is told about
# in its prompt all read this one variable — the prompt's copy through
# $LCARS_XO_MAX_ROUNDS, which the round loop exports for the spawn. A second
# hard-coded 3 in prose is exactly how the two drift apart.
XO_MAX_ROUNDS="${LCARS_XO_MAX_ROUNDS:-2}"
# THE RECORD SEPARATOR FOR EVERY PLAN THIS SCRIPT READS BACK (fix round 1, D2).
# ASCII US (0x1f), never a tab. TAB IS IFS WHITESPACE, so `IFS=$'\t' read -r …`
# COLLAPSES a run of them: a record with an EMPTY field loses it and every later
# field shifts left. That is how a gap with no shot — newly reachable once a
# failing test could stand in for a picture — filed `{"criterion": "batches do
# not survive a restart", "title": ""}` into `xo/logs.json`, and how the
# captain's filing readout printed `log #2` with no title at all. `lcars status`
# took the identical cure for the identical class in S207 R4. Both producers
# (`xo-logs.py`, `xo-held.py`) carry the same constant.
XO_RS=$'\037'
XO_MAX_ACTIONS=12
XO_OBSERVE_PY="${LCARS_XO_OBSERVE_PY:-$SKILL_DIR/xo-observe.py}"
XO_TESTS_PY="${LCARS_XO_TESTS_PY:-$SKILL_DIR/xo-tests.py}"
# THE BOUND ON THE PROJECT'S OWN SUITE (S211). Five minutes is a long test run
# and a short wait; past it the look says the tests could not be run and gets on
# with itself rather than holding the captain's Verify gate open all night.
XO_TEST_TIMEOUT="${LCARS_XO_TEST_TIMEOUT:-300}"
# S239/S243 — THE BOUND THE REPO MEASURED, when it has measured one. S243 writes
# `.git/lcars/suite-timing.json` from real runs of this project's own suite; a
# repo whose suite honestly takes eleven minutes should not have its Verify read
# "your tests were still running after 300s" forever. The env var remains the
# answer when there is no measurement, and a file with no timing in it falls
# back rather than to 0 — a zero timeout would report every suite as hung.
xo_test_timeout() {
  local f="$LCARS_DIR/suite-timing.json" n=""
  if [ -f "$f" ]; then
    n="$("$XO_PY" -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(0)
for k in ("testTimeout", "suiteSeconds", "seconds"):
    v = d.get(k) if isinstance(d, dict) else None
    if isinstance(v, (int, float)) and v > 0:
        print(int(v)); break' "$f" 2>/dev/null)"
  fi
  printf '%s\n' "${n:-$XO_TEST_TIMEOUT}"
}
# How much of the output the worker is handed. The tail, because that is where
# every runner in common use puts its summary and its failures — and the cut is
# STATED in the record, because a line the worker cannot find is a line the
# scorer will refuse to accept as a citation.
XO_TEST_TAIL_CAP="${LCARS_XO_TEST_TAIL_CAP:-8000}"

# THE OBSERVATIONS PASS (S210) — computed by the SKILL, from the boxes the
# driver just recorded, never asked of the model. ONE writer, called from every
# place a look happens (round 0 and a recheck's relaunch alike), so a look that
# skipped this call is not a look that could have observations to report.
# Best-effort: a broken/missing readout.json yields an empty observations.json
# (xo-observe.py's own load() degrades the same way), never a hard failure —
# an OBSERVATIONS pass going missing must never be why a look cannot finish.
xo_observe() { # <shots-dir> <out observations.json> [--merge]
  local shots="$1" out="$2" merge="${3:-}"
  # EVERY SCREEN, NOT JUST THE LANDING PAGE (S220 part D). The pass used to run
  # once, on round 0, and never again — so on the real benchmark it reported
  # "112 elements, 0 findings" from the Default view and never looked at the six
  # MBR screens the look walked to. Now every round's readout is passed through
  # it and MERGED, and each finding carries the screen it was seen on.
  # EVERY SCREEN THE DRIVER STOOD ON. `readouts.json` is one reading per
  # screen; `readout.json` is only the last one. The pass prefers the first and
  # falls back to the second, so a driver too old to write it still works.
  local src="$shots/readout.json"
  [ -s "$shots/readouts.json" ] && src="$shots/readouts.json"
  local screen=""
  screen="$("$XO_PY" -c 'import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(d.get("url") or (d.get("page") or {}).get("url") or "")
except Exception: print("")' "$shots/readout.json" 2>/dev/null)"
  if [ -n "$merge" ]; then
    "$XO_PY" "$XO_OBSERVE_PY" "$src" "$out" --merge --screen "$screen" >/dev/null 2>&1 || true
  else
    "$XO_PY" "$XO_OBSERVE_PY" "$src" "$out" --screen "$screen" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── THE DRAWING AND THE BUILD, SIDE BY SIDE (S220 part B) ──────────────────
#
# THE DEFECT THIS EXISTS FOR. Number One asked "is there a button with that
# label?" and answered from the build alone. Four buttons whose icon spilled
# past the control and whose label wrapped onto three lines were graded
# "worked", in shots it took itself. Nobody ever put the drawing's button next
# to the build's button at the same scale.
#
# So: `xo_read_drawing` renders the mission's own drawing in the same headless
# browser at the same 2x and reads its PARTS, with a crop of each; every round
# of the look reads the build's parts the same way; and `xo_pair_parts` pairs
# them, records WHICH handle matched (test id, id, accessible name, label,
# role) and takes the two measurements the S220 spike proved separate faults
# from correct controls. Everything it produces is EVIDENCE handed to the
# look — the outcome is still the look's, and an overrule is journaled with
# its reason (xo-score.py).
XO_PARTS_PY="${LCARS_XO_PARTS_PY:-$SKILL_DIR/xo-parts.py}"

xo_drawing_file() { # <mission-dir> — the first drawing on disk, or nothing
  local dir="$1" f
  for f in "$dir"/attachments/*.html "$dir"/attachments/*.htm; do
    [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 0
}

xo_read_drawing() { # <mission-dir> <xodir>
  local dir="$1" xodir="$2" draw=""
  draw="$(xo_drawing_file "$dir")"
  [ -n "$draw" ] || return 0
  mkdir -p "$xodir/drawing" 2>/dev/null || true
  "$XO_NODE" "$XO_DRIVER" --url "file://$draw" --out "$xodir/drawing" \
    --parts-out "$xodir/drawing-parts.json" --prefix "drawn" \
    >"$xodir/drawing.json" 2>"$xodir/drawing.err" || true
  [ -s "$xodir/drawing-parts.json" ] || {
    journal "$dir" drawing-parts '"read": 0, "detail": "the drawing would not render"'
    return 0
  }
  local n
  n="$("$XO_PY" -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("parts") or []))
except Exception: print(0)' "$xodir/drawing-parts.json" 2>/dev/null)"
  # ONE REQUIREMENT PER DRAWN PART (part C), written into the contract before
  # the look ever starts, so every part has its own importance and its own
  # outcome — and the catch-all is retired where the parts now cover it.
  local said=""
  said="$("$XO_PY" "$XO_PARTS_PY" criteria --drawing "$xodir/drawing-parts.json" \
        --criteria "$xodir/criteria.json" --out "$xodir/criteria.new.json" 2>/dev/null)" || said=""
  if [ -s "$xodir/criteria.new.json" ]; then
    mv "$xodir/criteria.new.json" "$xodir/criteria.json"
  else
    rm -f "$xodir/criteria.new.json" 2>/dev/null || true
  fi
  printf '◈ NUMBER ONE: I read your drawing — %s part(s); %s.\n' "${n:-0}" "${said:-nothing added}"
  journal "$dir" drawing-parts "$(printf '"read": %s, "detail": %s' \
    "${n:-0}" "$(jstr "${said:-}")")"
  return 0
}

xo_pair_parts() { # <mission-dir> <xodir> [baseline-matched] — pair the drawing with every screen seen
  local dir="$1" xodir="$2" baseline="${3:-}" f nbuild=0
  [ -s "$xodir/drawing-parts.json" ] || return 0
  set --
  for f in "$xodir"/build-parts-*.json; do
    [ -s "$f" ] || continue
    set -- "$@" --build "$f"; nbuild=$((nbuild + 1))
  done
  [ "$nbuild" -gt 0 ] || return 0
  # THE BASELINE THIS RE-CHECK IS MEASURED AGAINST (S222 round 2). A number the
  # PRIOR look recorded, handed in so the pairing can say whether this look went
  # blind on the thing it is confirming. Absent on a first look — then no
  # visibility block is written and nothing false is flagged.
  [ -n "$baseline" ] && set -- "$@" --baseline-matched "$baseline"
  local said=""
  said="$("$XO_PY" "$XO_PARTS_PY" pair --drawing "$xodir/drawing-parts.json" \
        "$@" --out "$xodir/pairs.json" 2>/dev/null)" || said=""
  [ -n "$said" ] && printf '  side by side: %s\n' "$said"
  journal "$dir" paired "$(printf '"detail": %s' "$(jstr "${said:-}")")"
  return 0
}

xo_touch_criteria() { # <mission-dir> <xodir> [walk.json] — file a row per CLICKED control
  # EVERY CONTROL THE WALK CLICKED gets a second question, drawn or not (S225).
  # The pairing above is keyed entirely off the DRAWING's `id=` vocabulary, so
  # a control the walk clicked that the drawing never named had no criterion to
  # be held to — the gap that let his three-line "Back to builder" button score
  # "met". This joins walk.json (the controls actually clicked) to the same
  # build inventory the pairing reads, and files a fault against a touched
  # control WHETHER OR NOT THE DRAWING NAMED IT. It runs after the walk and
  # before the look is handed its criteria, so the enriched contract is what
  # gets graded and scored.
  local dir="$1" xodir="$2" walk="${3:-$xodir/walk.json}" f said=""
  [ -s "$walk" ] || return 0
  [ -s "$xodir/criteria.json" ] || return 0
  set --
  for f in "$xodir"/build-parts-*.json; do
    [ -s "$f" ] || continue
    set -- "$@" --build "$f"
  done
  [ "$#" -gt 0 ] || return 0
  said="$("$XO_PY" "$XO_PARTS_PY" touched --walk "$walk" "$@" \
        --criteria "$xodir/criteria.json" --out "$xodir/criteria.new.json" 2>/dev/null)" || said=""
  if [ -s "$xodir/criteria.new.json" ]; then
    mv "$xodir/criteria.new.json" "$xodir/criteria.json"
  else
    rm -f "$xodir/criteria.new.json" 2>/dev/null || true
  fi
  [ -n "$said" ] && printf '  touched: %s\n' "$said"
  journal "$dir" touched "$(printf '"detail": %s' "$(jstr "${said:-}")")"
  return 0
}

# ── SEEDABLE DATA FOR THE LOOK (S220 part E) ───────────────────────────────
#
# THE DEFECT THIS EXISTS FOR. Half of the MBR builder only appears once there
# is DATA in it: with no automated KPI on record the automate button and the
# bulk bar never render at all, and a look that never sees them can only ever
# say "I could not check that". There was no way to give a build its sample
# data, so there was no way to see those screens.
#
# DECLARED, NEVER GUESSED. A worker inventing rows in somebody's app is a
# worker writing data into a build nobody asked it to write. So the seed comes
# from the RECORD, in two places and no others:
#
#   1. `verifySeed` in .git/lcars/config.json — a command, this repo's own;
#   2. `.lcars/verify-seed.sh` in the project — the documented file a project
#      can ship so that a look can see its data-backed screens.
#
# It runs in the LAUNCHED BUILD'S OWN WORKTREE, never the captain's checkout,
# and it is caged. When neither is declared, nothing is invented and nothing is
# blamed: the report says, in one plain sentence, which screens it could not
# see for want of data.
XO_SEED_TIMEOUT="${LCARS_XO_SEED_TIMEOUT:-300}"

# THE CAGE. `timeout` is not on a stock macOS, so this is it, written once: run
# it, watch it, and kill the process WE started (never by name — the captain
# runs his own daemons) if it outstays the limit. 124 is the exit `timeout`
# itself would give, so a caller can tell a cage from a failure.
# THE CAGE ON A WHOLE LOOK (S221). 45 minutes, the same limit the benchmark rig
# has always put round a live look (tests/drives/s220/bench/run.sh) — and until
# this round the ONLY place that limit existed. It bounds a look launched by the
# `lcars xo on` sweep, which is the one the captain is not sitting in front of:
# he switched Number One on because he is stepping out, so a build that will not
# answer must cost one mission's cage, not the whole night.
#
# A look is volume, not thinking: a 9-criteria fixture lands near 7 minutes and a
# 101-criteria build takes 18–32, so 2700s is a ceiling nothing healthy reaches.
XO_LOOK_TIMEOUT="${LCARS_XO_LOOK_TIMEOUT:-2700}"

xo_dur_words() { # <seconds> — "45 minutes" / "90s", for a sentence he reads
  local secs="$1"
  if [ "$secs" -ge 120 ] 2>/dev/null; then printf '%s minutes' "$((secs / 60))"
  else printf '%ss' "$secs"; fi
}

xo_cage() { # <seconds> <command…>
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      # THE WHOLE TREE, TERM FIRST (S221). A `kill -9` on the direct child alone
      # was enough when the cage only ever held a seed command; it now holds a
      # WHOLE LOOK, which owns a launched app and a headless Chrome. Killing
      # just the top of that leaves both running for the rest of the night. So:
      # TERM down the tree — which is how xo.sh's own traps get the chance to
      # stop the launch and the browser properly — then KILL anything that has
      # not gone. Only pids descended from the one WE started; never by name.
      xo_kill_tree "$pid"
      local grace=0
      while kill -0 "$pid" 2>/dev/null && [ "$grace" -lt 10 ]; do
        sleep 0.5; grace=$((grace + 1))
      done
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
  return $?
}

xo_seed_declared() { # <repo-root> — prints "source<TAB>command", or nothing
  local root="$1" cmd=""
  cmd="$(lcars_config_get "$CONFIG" verifySeed 2>/dev/null)" || cmd=""
  if [ -n "$cmd" ] && [ "$cmd" != "null" ]; then
    printf 'the repo declares one in .git/lcars/config.json (verifySeed)\t%s\n' "$cmd"
    return 0
  fi
  if [ -x "$root/.lcars/verify-seed.sh" ]; then
    printf 'the project ships one at .lcars/verify-seed.sh\t%s\n' "bash .lcars/verify-seed.sh"
    return 0
  fi
  if [ -f "$root/.lcars/verify-seed.sh" ]; then
    printf 'the project ships one at .lcars/verify-seed.sh\t%s\n' "bash .lcars/verify-seed.sh"
    return 0
  fi
  return 0
}

xo_seed() { # <mission-dir> <xodir> <where-to-run> — load the declared sample data
  local dir="$1" xodir="$2" where="$3" line src cmd rc=0
  line="$(xo_seed_declared "${where:-$PWD}")"
  src="${line%%$'\t'*}"; cmd="${line#*$'\t'}"
  if [ -z "$line" ]; then
    "$XO_PY" -c 'import json,sys; json.dump({"declared": False}, open(sys.argv[1], "w"), indent=2)' \
      "$xodir/seed.json" 2>/dev/null || true
    printf '◈ NUMBER ONE: no sample data is declared for this repo — screens that need data may be unseeable.\n'
    journal "$dir" seed '"declared": false'
    return 0
  fi
  printf '◈ NUMBER ONE: loading the sample data — %s.\n' "$src"
  ( cd "$where" 2>/dev/null && xo_cage "$XO_SEED_TIMEOUT" bash -c "$cmd" ) \
    >"$xodir/seed.log" 2>&1 || rc=$?
  "$XO_PY" -c 'import json,sys
json.dump({"declared": True, "source": sys.argv[2], "command": sys.argv[3],
           "exit": int(sys.argv[4]), "ranIn": sys.argv[5]},
          open(sys.argv[1], "w"), indent=2)' \
    "$xodir/seed.json" "$src" "$cmd" "$rc" "$where" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    printf '  the seed came back rc=%s — see %s\n' "$rc" "$xodir/seed.log"
  fi
  journal "$dir" seed "$(printf '"declared": true, "exit": %s, "detail": %s' "$rc" "$(jstr "$src")")"
  return 0
}

# ── THE JOURNEY, WALKED (S220 part F) ───────────────────────────────────────
#
# THE DEFECT THIS EXISTS FOR. On 2026-09-19 Number One "looked at" a six-screen
# build by typing four addresses into the bar. It never clicked a control,
# never typed an insight, never watched a value carry from one screen to the
# next — and then graded the flow. Two later runs of the identical code
# differed from each other: one clicked, one teleported. A walk left to the
# model is a LOTTERY, and a lottery is not a proof.
#
# So the journey is DECLARED from the record (xo-journey.py reads the drawing's
# screen order, the PRD's own steps and the fields and gates the screens carry)
# and the DRIVER executes it. Each step is its own requirement, so a step that
# could not be taken reads as "couldn't check (unreachable)" BY NAME.
XO_JOURNEY_PY="${LCARS_XO_JOURNEY_PY:-$SKILL_DIR/xo-journey.py}"

xo_build_journey() { # <mission-dir> <xodir>
  local dir="$1" xodir="$2" draw="" said=""
  draw="$(xo_drawing_file "$dir")"
  # THE PRD ITSELF, not just what survived into the contract (S221 fix 7).
  # The captain says how a build is USED in the Goal — "walk the character
  # around the village with the arrow keys" — and none of that reaches
  # criteria.json, which is why a keyboard-driven build produced an empty
  # journey. The planner drops the Out-of-Scope section itself.
  said="$("$XO_PY" "$XO_JOURNEY_PY" build --criteria "$xodir/criteria.json" \
        ${draw:+--drawing-html "$draw"} \
        ${draw:+--drawing "$xodir/drawing-parts.json"} \
        $([ -f "$dir/prd.md" ] && printf -- '--prd\n%s' "$dir/prd.md") \
        --title "$(json_field "$dir/state.json" title)" \
        $([ -f "$dir/number-one.jsonl" ] && printf -- '--records\n%s' "$dir/number-one.jsonl") \
        --out "$xodir/journey.json" --criteria-out "$xodir/criteria.new.json" 2>/dev/null)" || said=""
  if [ -s "$xodir/criteria.new.json" ]; then
    mv "$xodir/criteria.new.json" "$xodir/criteria.json"
  else
    rm -f "$xodir/criteria.new.json" 2>/dev/null || true
  fi
  printf '◈ NUMBER ONE: the journey I will walk — %s.\n' "${said:-nothing in the record described a flow}"
  journal "$dir" journey "$(printf '"detail": %s' "$(jstr "${said:-}")")"
  return 0
}

# ===========================================================================
# S239 — THE WALK BEYOND THE BROWSER. Declared steps, HARNESS-executed.
# ===========================================================================
# The reason, measured: on the Canvas weekend (34 looks, same product) Number
# One filed 0 of 31 bugs, and all sixteen of its recorded misses were REACH
# errors — no screen for a CLI, nothing seeded, a stub that made the seam
# untestable. Its judgement was never the problem.
#
# THIS RUNS WHETHER OR NOT THE LAUNCH WORKED, and on purpose. Four of the
# weekend's misses were "the launched page doesn't match any mockup" / "nothing
# serves site/" — a stale launch target meant the look reached NOTHING. A CLI
# does not need a server to be up, so the reach is not held hostage to one.
XO_RUN_PY="${LCARS_XO_RUN_PY:-$SKILL_DIR/xo-run.py}"

xo_reach_count() { # <journey.json> → how many steps the harness would run
  "$XO_PY" -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    print(len([s for s in (d.get("reachSteps") or []) if isinstance(s, dict)]))
except Exception:
    print(0)' "$1" 2>/dev/null || printf '0\n'
}

xo_run_reach() { # <mission-dir> <xodir> <shots> [journey-file]
  local dir="$1" xodir="$2" shots="$3" jfile="${4:-$xodir/journey.json}"
  local n br said rc=0 top
  [ -s "$jfile" ] || return 0
  n="$(xo_reach_count "$jfile")"
  [ "${n:-0}" -gt 0 ] || return 0
  br="$(json_field "$dir/state.json" branch)"
  if [ -z "$br" ]; then
    # HONEST, NOT SILENT. Without a branch there is no tree to detach, and a
    # step run against the CHECKED-OUT branch is the failure this refuses.
    printf '◈ NUMBER ONE: %s declared step(s) I could not run — the mission records no branch to detach a worktree from.\n' "$n"
    journal "$dir" reach-refused "$(printf '"why": %s, "steps": %s' \
      "$(jstr "the mission records no branch")" "$n")"
    return 0
  fi
  top="$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] || top="$PWD"
  said="$("$XO_PY" "$XO_RUN_PY" run --journey "$jfile" --out "$shots" \
        --repo "$top" --branch "$br" --mission-dir "$dir" 2>&1)" || rc=$?
  [ -n "$said" ] && printf '%s\n' "$said"
  journal "$dir" reached "$(printf '"steps": %s, "exit": %s, "branch": %s' \
    "$n" "${rc:-0}" "$(jstr "$br")")"
  return 0
}

# The worker's OWN requested steps, split from its browser actions and held to
# the SAME cap of 12 across all kinds (S222's rule, unchanged). A request that
# tries to leave the worktree is refused by xo-run.py and journaled there.
xo_reach_actions() { # <mission-dir> <xodir> <shots> <xo-actions.json> <round>
  local dir="$1" xodir="$2" shots="$3" acts="$4" round="$5" kept n
  [ -s "$acts" ] || return 0
  kept="$xodir/actions-kept-$round.json"
  "$XO_PY" "$XO_RUN_PY" actions --actions "$acts" --out "$kept" \
    --mission-dir "$dir" --cap "$XO_MAX_ACTIONS" >/dev/null 2>&1 || true
  [ -s "$kept" ] || return 0
  n="$(xo_reach_count "$kept")"
  [ "${n:-0}" -gt 0 ] || return 0
  xo_run_reach "$dir" "$xodir" "$shots" "$kept"
}

# WHAT THE WALK MEASURED, added to what the layout pass measured. Two readings
# no picture-pair can take: a control holding an icon bigger than itself (true
# with no drawing at all, and the only way to reach a button on a screen the
# drawing never drew), and a value that does not CARRY from the screen a person
# came from to the screen they arrived at. Both are EVIDENCE, shown to the
# look beside everything else; neither is a verdict.
xo_measure_walk() { # <mission-dir> <xodir> <observations.json> [walk.json]
  # THE WALK IT READS IS NAMED BY THE CALLER (S222 fix round 1). A re-check
  # walks the same journey again and writes its OWN record; handed the file
  # name rather than assuming `walk.json`, this pass measures the look that
  # just happened instead of the look before it.
  local dir="$1" xodir="$2" obs="$3" walk="${4:-$xodir/walk.json}" f
  set --
  for f in "$xodir"/build-parts-*.json; do
    [ -s "$f" ] || continue
    set -- "$@" --build "$f"
  done
  if [ "$#" -gt 0 ]; then
    "$XO_PY" "$XO_PARTS_PY" scan "$@" --out "$xodir/scan.json" >/dev/null 2>&1 || true
    xo_add_observations "$obs" "$xodir/scan.json"
  fi
  if [ -s "$walk" ]; then
    "$XO_PY" "$XO_JOURNEY_PY" carry --walk "$walk" \
      --out "$xodir/carry.json" >/dev/null 2>&1 || true
    xo_add_observations "$obs" "$xodir/carry.json"
  fi
  return 0
}

# One place that adds a fragment's findings to the observations file, so a
# finding cannot be recorded twice and the counts stay honest.
xo_add_observations() { # <observations.json> <fragment.json>
  [ -s "$2" ] || return 0
  "$XO_PY" -c '
import json, sys
obs_path, frag_path = sys.argv[1], sys.argv[2]
def load(p, d):
    try:
        with open(p) as fh: return json.load(fh)
    except Exception: return d
doc = load(obs_path, {}) or {}
frag = load(frag_path, {}) or {}
have = doc.get("observations") or []
keys = set(json.dumps(o, sort_keys=True) for o in have if isinstance(o, dict))
added = 0
seen_says = set(str(o.get("says") or "") for o in have if isinstance(o, dict))
for o in frag.get("observations") or []:
    if not isinstance(o, dict): continue
    if json.dumps(o, sort_keys=True) in keys or str(o.get("says") or "") in seen_says: continue
    have.append(o); added += 1
    seen_says.add(str(o.get("says") or ""))
doc["observations"] = have
doc["foundCount"] = int(doc.get("foundCount") or 0) + added
screens = [s for s in (doc.get("screens") or []) if s]
for o in have:
    sc = str(o.get("screen") or "")
    if sc and sc not in screens: screens.append(sc)
doc["screens"] = screens
with open(obs_path, "w") as fh:
    json.dump(doc, fh, indent=2); fh.write("\n")
' "$1" "$2" >/dev/null 2>&1 || true
  return 0
}

# THE PROJECT'S OWN TESTS (S211) — run by the SKILL, never by the worker.
#
# Number One acts only through a browser, so a change with no UI surface is
# invisible to it. `config.json` already carries `testCommand`: the suite the
# captain trusts. This runs it ONCE per look, in the LAUNCHED BUILD'S worktree
# (so it is the built code being tested, not the captain's own checkout), and
# writes `xo/tests.json` — the command, the exit code, the duration, the tail of
# the output, and a plain verdict, all recorded where they were known.
#
# THE FENCE IS UNCHANGED. "The worker reasons, the skill executes" (captain's
# ruling 2026-09-11). Nothing here gives the worker a shell; it is handed the
# RESULT, as a read-only file, exactly as it is handed the screenshots.
#
# BEST-EFFORT, LIKE THE OBSERVATIONS PASS. A repo with no testCommand, a
# worktree the launch did not record, a runner that will not start — each is
# recorded plainly by xo-tests.py and the look carries on. A missing suite must
# never be why the captain does not get his Verify look.
xo_run_tests() { # <launch.json> <out tests.json> — writes the record, nothing else
  local launch="$1" out="$2" cmd="" wt=""
  cmd="$(lcars_config_get "$CONFIG" testCommand 2>/dev/null)" || cmd=""
  wt="$(json_field "$launch" worktree)"
  # BACKGROUNDED AND WAITED ON, exactly as the driver is (S204 fix round 1, D2).
  # A foreground child holds the trap's first opportunity to run until it
  # finishes, and this one may legitimately take the whole five minutes — five
  # minutes in which the captain's stop button would have done nothing.
  # Backgrounded, a stand-down lands at once and xo_teardown kills this tree,
  # the test runner and its children included.
  "$XO_PY" "$XO_TESTS_PY" --out "$out" --cwd "$wt" \
    --timeout "$(xo_test_timeout)" --cap "$XO_TEST_TAIL_CAP" \
    --command "$cmd" >/dev/null 2>&1 &
  XO_TESTS_PID=$!
  wait "$XO_TESTS_PID" 2>/dev/null || true
  XO_TESTS_PID=""
  return 0
}

# === THE PASS WITH NO LIST IN ITS HAND (S224 item 2) ========================
#
# Number One reviews what the captain wrote down. Measured on the S222 capstone:
# every fault an acceptance criterion named was filed, and every fault none
# named was missed or demoted — one faulty line of text was quoted VERBATIM in
# the verdict and its row still passed, and a control missing something all its
# neighbours had was passed outright, because the comparator asks whether a
# thing OVERFLOWS and has no way to ask whether it is ABSENT.
#
# So one more pass runs, over THE PICTURES THE WALK ALREADY TOOK — no second
# browser, no second walk, no extra look. What makes it different is not a
# cleverer prompt: it is that **the criteria are removed from its context**. Its
# input directory holds the shots and nothing else. No criteria.json, no PRD, no
# plan, no drawing, no journey, no pairs, no observations. A reviewer holding a
# list finds what is on the list; this one has no list.
#
# WHERE IT GOES: `escalations`, the channel S222 built — the console line, the
# journal, `lcars xo report`. NOT the score, not a criterion, not a gap, and NOT
# a second surface. An unlisted finding is evidence for the captain, not a
# criterion he wrote. xo-score.py's merge_unlisted is the fence.
#
# BEST-EFFORT, like every other pass here. No shots, a worker that writes
# nothing, a malformed file — each leaves `unlisted.json` absent and the look
# finishes exactly as it would have. This must never be why a verdict does not
# reach him.
XO_UNLISTED="${LCARS_XO_UNLISTED:-1}"

# THE PICTURES, AND ONLY THE PICTURES. An explicit ALLOW-list of what a shot
# directory holds, never "copy the directory minus the things I remembered to
# exclude" — the day a look writes one more file in there, a deny-list silently
# hands the criteria-free pass something it was built not to see.
xo_unlisted_inputs() { # <shots-dir> <into>
  local from="$1" into="$2" f base n=0
  [ -d "$from" ] || return 1
  mkdir -p "$into" || return 1
  for f in "$from"/*.png; do
    [ -f "$f" ] || continue
    base="${f##*/}"; base="${base%.png}"
    cp "$f" "$into/$base.png" 2>/dev/null || continue
    [ -f "$from/$base.json" ] && cp "$from/$base.json" "$into/$base.json" 2>/dev/null
    [ -f "$from/$base.txt" ]  && cp "$from/$base.txt"  "$into/$base.txt"  2>/dev/null
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || return 1
  # Read-only, for the same reason gather_inputs is: the worker is looking at a
  # record it must not be able to change.
  chmod -R a-w "$into" 2>/dev/null || true
  printf '%s' "$n"
  return 0
}

# Run the pass and write `<xodir>/unlisted.json`. Always returns 0.
xo_unlisted_pass() { # <mission-id> <shots-dir> <out unlisted.json> [<engine>]
  local id="$1" shots="$2" out="$3" engine="${4:-}"
  [ "$XO_UNLISTED" = "1" ] || return 0
  local work indir n
  work="$(mktemp -d)" || return 0
  indir="$work/input"
  n="$(xo_unlisted_inputs "$shots" "$indir")" || { rm -rf "$work"; return 0; }
  printf '◈ NUMBER ONE: and one more look at those %s picture(s) with your list put away…\n' "$n"
  (
    export LCARS_XO_INPUT_DIR="$indir"
    export LCARS_WORKER_INPUT_DIRS="$indir"
    if [ -n "$engine" ]; then
      export LCARS_WORKER_BIN="$engine" LCARS_WORKER_BIN_INTERNAL=1
    fi
    exec bash "$XO_RUN_SCRIPT" spawn-number-one \
      --mission "$id" --mode unlisted --outdir "$work/out"
  ) >/dev/null 2>&1 &
  XO_SPIN_PID=$!
  wait "$XO_SPIN_PID" 2>/dev/null || true
  XO_SPIN_PID=""
  # THE INVENTORY IS STAMPED BY THE PRODUCER, NEVER DECLARED BY THE MODEL.
  # This function knows exactly which pictures it put on the worker's side of
  # the door; the worker does not get to say what it was shown. That is what
  # makes xo-score.py's citation guard checkable at all — a finding naming a
  # picture nobody took is an invention, and it is dropped there.
  "$XO_PY" -c 'import json, os, sys
src, shots, dst = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(src, encoding="utf-8", errors="replace") as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(1)
found = doc.get("findings") if isinstance(doc, dict) else None
if not isinstance(found, list):
    sys.exit(1)
names = sorted(f[:-4] for f in os.listdir(shots) if f.endswith(".png"))
with open(dst, "w", encoding="utf-8") as fh:
    json.dump({"shots": names, "findings": found}, fh, indent=2)
' "$work/out/xo-unlisted.json" "$indir" "$out" 2>/dev/null || rm -f "$out"
  chmod -R u+w "$indir" 2>/dev/null || true
  rm -rf "$work"
  return 0
}

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
# THE HEADLINE (S213). One line, for the board card, which no longer carries the
# whole verdict. It is the LEDGER'S OWN DERIVATION — the sentence xo-score.py
# writes in the same breath as the score, from the same ledger, by the same
# rule — so the line on the card and the score beside it cannot disagree. It is
# never a cut-down of the worker's prose: a truncation is this harness deciding
# what Number One meant, which is exactly the fault S213 exists to kill.
# Omitted (and any stale one deleted) when there is no derivation to record.
xo_finish() { # <mission-dir> <score> <status> <why> [<headline>] [<meaning>] [<why-this-grade>] [<recommendation>] [<rec-why>]
  local dir="$1" score="$2" status="$3" why="$4" headline="${5:-}" meaning="${6:-}" st obj id
  local gradewhy="${7:-}" recommendation="${8:-}" recwhy="${9:-}"
  st="$dir/state.json"; id="$(basename "$dir")"
  obj="$(state_xo_block "$st")"
  obj="$(obj_set "$obj" status "$(jstr "$status")")"
  obj="$(obj_set "$obj" score "$(jstr "$score")")"
  if [ -n "$headline" ]; then
    obj="$(obj_set "$obj" headline "$(jstr "$headline")")"
  else
    obj="$(obj_del "$obj" headline)"
  fi
  # S213 fix round 1, D4 — WHAT THE SCORE WORD MEANS, as the ledger decided it.
  # The board used to explain MEDIUM with one fixed sentence about a primary
  # flow working, and said it over a mission where nothing could be tested at
  # all. The sentence is now recorded beside the score it belongs to, by the
  # code that decided the score, so no surface has to guess.
  if [ -n "$meaning" ]; then
    obj="$(obj_set "$obj" meaning "$(jstr "$meaning")")"
  else
    obj="$(obj_del "$obj" meaning)"
  fi
  # S240 — THE ACTION, MIRRORED. `numberOne.recommendation` is what the board,
  # the living comment and the autopilot's `policy` read; it is the word the
  # SCORER decided, never re-derived from `score` by a surface (that hand-mapping
  # is the defect S240 exists to remove).
  if [ -n "$recommendation" ]; then
    obj="$(obj_set "$obj" recommendation "$(jstr "$recommendation")")"
    if [ -n "$recwhy" ]; then
      obj="$(obj_set "$obj" recommendationWhy "$(jstr "$recwhy")")"
    else
      obj="$(obj_del "$obj" recommendationWhy)"
    fi
  else
    obj="$(obj_del "$obj" recommendation)"
    obj="$(obj_del "$obj" recommendationWhy)"
  fi
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
  # S216 — WHY THIS GRADE rides the journal entry too, so the First Officer's
  # report leads with the table walked in words. Absent when there is none.
  local gradefield=""
  [ -n "$gradewhy" ] && gradefield="$(printf ', "whyThisGrade": %s' "$(jstr "$gradewhy")")"
  # S240 — the recommendation rides the SAME journal entry as the grade, as an
  # ADDITIVE key, so the First Officer's report shows it with no board.js change.
  local recfield=""
  [ -n "$recommendation" ] && recfield="$(printf ', "recommendation": %s, "recommendationWhy": %s' \
    "$(jstr "$recommendation")" "$(jstr "$recwhy")")"
  journal "$dir" scored \
    "$(printf '"score": %s, "why": %s, "status": %s%s%s' \
         "$(jstr "$score")" "$(jstr "$why")" "$(jstr "$status")" "$gradefield" "$recfield")"
  xo_label_score "$st" "$score"
  xo_mirror "$id"
  printf '◈ NUMBER ONE: intent match %s — %s\n' "$(printf '%s' "$score" | tr '[:lower:]' '[:upper:]')" "$why"
  printf '  The report is in %s/xo/verdict.json.\n' "$dir"
}

cmd_evaluate() {
  local target="" again=0 because=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mission)   target="${2:-}"; shift 2 || true ;;
      --mission=*) target="${1#--mission=}"; shift ;;
      # S239 — THE RE-LOOK. Feedback #5: "with no logs filed, there is no way to
      # re-score". A mission scored LOW only because no testCommand was recorded
      # (miss #1) could never be looked at again once the blocker was cleared,
      # because `cmd_recheck` needs FILED LOGS and `cmd_evaluate` is idempotent
      # on evaluatedAt. That is the catch-22 this flag ends. It needs NO logs.
      --again)     again=1; shift ;;
      --because)   because="${2:-}"; shift 2 || true ;;
      --because=*) because="${1#--because=}"; shift ;;
      -*)          die "unknown option: $1" ;;
      *)           target="$1"; shift ;;
    esac
  done
  # A SUPERSESSION STATES ITS REASON. Making `--again` bypass the idempotence
  # silently would leave two verdicts in the record with nothing saying which
  # one is current or why — so the reason is required, and it is journaled.
  if [ "$again" = 1 ] && [ -z "$because" ]; then
    die "--again needs --because \"<why this verdict is being superseded>\" — a second look that does not say why leaves two verdicts and no reason."
  fi
  [ "$again" = 1 ] || [ -z "$because" ] || die "--because only means something with --again."
  [ -n "$target" ] || die "no mission — pass --mission <id>."
  local id dir st xodir shots look
  id="$(resolve_mission "$target")" || exit $?
  dir="$MISSIONS_DIR/$id"
  st="$dir/state.json"
  xodir="$dir/xo"

  # IDEMPOTENT ON evaluatedAt. The Verify driver can pass this way more than
  # once (a poll, a re-run, a second laptop) and a second look would spend a
  # worker and a browser to reach the same verdict.
  local seen
  seen="$(obj_get "$(state_xo_block "$st")" evaluatedAt)"
  if [ -n "$seen" ] && [ "$again" != 1 ]; then
    printf '◈ NUMBER ONE: already looked at %s (%s) — nothing to do.\n' "$id" "$seen"
    printf '  if the thing that blocked me has been cleared: lcars xo evaluate --mission %s --again --because "<what changed>"\n' "$id"
    return 0
  fi
  # ── EVERY REFUSAL COMES BEFORE THE SUPERSESSION (fix round 5, D2) ─────────
  # MEASURED: `evaluate --again --because "<why>"` on a logged bug child printed
  # "the verdict of <ts> (low) is superseded: <reason>" — and journaled it —
  # and THEN refused the re-look. The verdict itself was never mutated, but the
  # captain had just been told his verdict was replaced by a run that went on to
  # do nothing, and the mission's own journal said the same. So the two refusals
  # below are hoisted ABOVE the supersession: nothing announces or records a
  # supersession until the re-look is genuinely going to happen.
  #
  # A BUG CHILD IS NEVER EVALUATED. Its parent's PR carries the fix (Mission
  # logs' Model A); looking at a child would score the parent's build twice.
  if grep -q '"parentMission"' "$st" 2>/dev/null; then
    printf '◈ NUMBER ONE: %s is a logged bug child — its parent carries the build.\n' "$id"
    return 0
  fi

  # ONE LOOK AT A TIME, ON ONE MISSION (fix round 4, D1). This is the verb the
  # measured incident ran twice at once: it took no lock of any kind, and the
  # second look overwrote the first's verdict.json and report.md after the
  # first had already filed bugs from them.
  #
  # TAKEN BEFORE THE LOOK'S DIRECTORY IS TOUCHED, not after. A claim placed
  # below the `mkdir`/`look.txt` lines would let the loser name a look and
  # repoint `look.txt` at it before being refused — which is the same class of
  # mess, one file smaller. The EXIT trap is armed FIRST, so a refusal here
  # still tears down cleanly and gives nothing back that it does not own.
  trap xo_teardown EXIT
  trap on_stand_down TERM INT
  xo_claim_or_die "$dir" "a Verify look"

  # THE SUPERSESSION IS A RECORD BEFORE IT IS A RE-RUN (S239). The prior score,
  # when it was taken and the captain's reason go into the mission's own journal
  # FIRST, so a re-look that then dies still leaves an auditable trail of why a
  # finished verdict stopped being the current one. It is written here — past
  # every refusal, before the look's own directory exists — so the trail is only
  # ever written about a look that is actually starting.
  if [ "$again" = 1 ] && [ -n "$seen" ]; then
    local prior_score prior_rec
    prior_score="$(obj_get "$(state_xo_block "$st")" score)"
    prior_rec="$(obj_get "$(state_xo_block "$st")" recommendation)"
    journal "$dir" superseded "$(printf '"priorScore": %s, "priorRecommendation": %s, "priorAt": %s, "because": %s' \
      "$(jstr "$prior_score")" "$(jstr "$prior_rec")" "$(jstr "$seen")" "$(jstr "$because")")"
    printf '◈ NUMBER ONE: looking again at %s — the verdict of %s (%s) is superseded: %s\n' \
      "$id" "$seen" "${prior_score:-no grade}" "$because"
  fi

  # THIS LOOK'S OWN DIRECTORY (fix round 2, D1), and the pointer `file-logs`
  # reads to find the pictures this verdict was reasoned from.
  mkdir -p "$xodir"
  look="$(xo_next_look_name "$xodir" look)"
  shots="$(xo_look_dir "$xodir" "$look")"
  printf 'shots/%s\n' "$look" >"$xodir/look.txt"
  XO_MISSION_DIR="$dir"
  XO_LAUNCH_ID="$id"
  XO_STOP_LOG="$xodir/launch.log"
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

  # --- 1b. THE DRAWING, READ AS PARTS (S220 part B/C) -----------------------
  # Before the build is even up: render the mission's drawing in the same
  # headless browser, at the same 2x, and read every named/labelled part of it
  # with a crop of each. Then every one of those parts becomes its own
  # requirement — because on 2026-09-19 "matches the mock-up" was ONE row
  # covering twelve parts, and one holistic "looks right" hid four broken
  # buttons. Best-effort: a mission with no drawing, or a drawing the browser
  # will not open, leaves the contract exactly as it was.
  xo_read_drawing "$dir" "$xodir"

  # --- 1c. THE JOURNEY (S220 part F) ---------------------------------------
  # Declared from the record before the build is up, so the walk cannot be
  # invented while looking.
  xo_build_journey "$dir" "$xodir"

  # --- 1d. THE REACH BEYOND THE BROWSER (S239) -----------------------------
  # Run BEFORE the launch, because a CLI and a workflow do not need a server up
  # and four of the weekend's misses were looks that reached nothing because the
  # launch target was stale.
  xo_run_reach "$dir" "$xodir" "$shots"

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
    #
    # TWO DIFFERENT THINGS, AND THEY MUST NOT SHARE A SENTENCE (S213). This arm
    # fires on two quite separate situations, and it used to glue its own
    # failure prefix onto whatever `launch.json` said — so a desktop build that
    # started perfectly well but serves no web address produced, verbatim, on
    # the captain's own board card:
    #
    #     could not launch: the app is running.
    #
    # which contradicts itself in six words and tells him nothing he can act on.
    # So the two cases say what actually happened to HIS build:
    #   • it is running, but at no address a browser can open — a desktop app,
    #     say. Nothing failed; there was simply nothing to look at.
    #   • it never came up at all.
    local why
    if [ "$lstatus" = "running" ]; then
      why="your build started, but not at a web address I can open — so there was nothing for me to look at"
    else
      why="your build did not start — ${lmsg:-nothing came up (status ${lstatus:-unknown})}"
    fi
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "scoreMeaning": %s,\n  "criteria": [],\n  "gaps": [],\n  "summary": %s\n}\n' \
      "$(jstr "$why")" "$(jstr "$XO_NOLOOK")" "$(jstr "$why")" >"$xodir/verdict.json"
    rm -f "$dir/xo.pid"; trap - TERM INT
    xo_finish "$dir" low engaged "$why" "$why" "$XO_NOLOOK"
    return 0
  fi
  printf '  the build is up at %s\n' "$lurl"
  journal "$dir" launched "$(printf '"url": %s' "$(jstr "$lurl")")"

  # --- 2b. THE SAMPLE DATA (S220 part E) ------------------------------------
  # Before the first picture: a screen that only exists once there is data in
  # it cannot be photographed into existence afterwards. Declared seeds only —
  # see xo_seed — and run in the LAUNCHED worktree, never this checkout.
  local lwork=""
  lwork="$(json_field "$dir/launch.json" worktree)"
  xo_seed "$dir" "$xodir" "${lwork:-$PWD}"
  # AND THE TREE IS REMEMBERED, HERE (S221). After the seed — whose writes are
  # wanted — and before the first drive, which is the first thing that types.
  xo_tree_mark "$lwork" "$xodir/tree-mark"

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
    --parts-out "$xodir/build-parts-0.json" \
    --journey "$xodir/journey.json" --walk-out "$xodir/walk.json" \
    >"$xodir/drive-0.json" 2>"$xodir/drive-0.err" &
  XO_DRIVE_PID=$!
  wait "$XO_DRIVE_PID" || drc=$?
  XO_DRIVE_PID=""
  if [ "$drc" -eq 77 ]; then
    local why="could not look: the browser could not be started ($(head -1 "$xodir/drive-0.err" 2>/dev/null))"
    xo_stop_launch
    rm -f "$dir/xo.pid"; trap - TERM INT
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "scoreMeaning": %s,\n  "criteria": [],\n  "gaps": [],\n  "summary": %s\n}\n' \
      "$(jstr "$why")" "$(jstr "$XO_NOLOOK")" "$(jstr "$why")" >"$xodir/verdict.json"
    xo_finish "$dir" low engaged "$why" "$why" "$XO_NOLOOK"
    return 0
  fi
  # WHAT THE WALK TYPED, PUT BACK (S221). Before the project's own suite runs —
  # the whole point is that it must not read the insight Number One typed.
  xo_tree_restore "$dir"
  # THE DIRECTORY IS PART OF THE RECORD (fix round 2, D1): a verdict is only as
  # good as the pictures behind it, so which pictures those were is written down.
  journal "$dir" looked "$(printf '"round": 0, "shots": %s, "shotsDir": %s' \
    "$(ls "$shots"/*.png 2>/dev/null | grep -c . | tr -d ' ')" \
    "$(jstr "${shots#$dir/}")")"

  # --- 3b. THE OBSERVATIONS PASS — computed by the SKILL, from these same
  # boxes, before the worker ever looks (S210). Crowding, overlap, a
  # misaligned row, clipped text: things no drawing states, so nothing has
  # ever asked the model to notice them. It journals even when it found
  # nothing — a clean page is a fact worth recording too.
  local obsfile="$xodir/observations.json" obsn=0
  xo_observe "$shots" "$obsfile"
  local obsfound=0
  [ -s "$obsfile" ] && obsn="$("$XO_PY" -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("observations") or []))
except Exception: print(0)' "$obsfile" 2>/dev/null)"
  # WHAT IT FOUND, beside what it PRINTED. Past a handful the pass keeps only
  # the worst few (S212), and a record that logged the short list as the whole
  # story would make a busy page look like a quiet one for ever after.
  [ -s "$obsfile" ] && obsfound="$("$XO_PY" -c 'import json,sys
try:
  d = json.load(open(sys.argv[1]))
  print(d.get("foundCount", len(d.get("observations") or [])))
except Exception: print(0)' "$obsfile" 2>/dev/null)"
  obsn="${obsn:-0}"; obsfound="${obsfound:-0}"
  journal "$dir" observed "$(printf '"count": %s, "found": %s' "${obsn:-0}" "${obsfound:-0}")"

  # --- 3b-ii. SIDE BY SIDE (S220 part B) — the drawing's parts against what
  # round 0 actually built, with the two measurements beside each pair.
  xo_pair_parts "$dir" "$xodir"
  xo_touch_criteria "$dir" "$xodir"
  xo_measure_walk "$dir" "$xodir" "$obsfile"

  # --- 3b-iii. THE SAME PLACE, READ AT EVERY MOMENT (S224 fix round 3) ------
  # A walk is a sequence of pictures, and a criterion about something that is
  # on screen the whole way through therefore has several moments it could be
  # judged at. Measured on the captain's own build: a row was graded on a late
  # picture while the walk's own record showed that strip of the page reading
  # differently at its first three moments. This writes those moments down, from
  # the driver's record and nothing else. It judges NONE of them — a value that
  # changes is usually a value doing its job — it only makes sure the eye is
  # looking at all of them instead of one.
  "$XO_PY" "$SKILL_DIR/xo-readings.py" "$xodir/walk.json" "$xodir/readings.json" \
    >/dev/null 2>&1 || true

  # --- 3c. THE PROJECT'S OWN TESTS (S211) — run by the SKILL, between the
  # capture and the worker round. A screenshot cannot answer "batches survive a
  # restart"; the captain's own suite can. Run ONCE, here, in the launched
  # build's worktree, so however many rounds of looking follow, they are all
  # reasoning from the same one run.
  local testsfile="$xodir/tests.json" test_outcome=""
  xo_run_tests "$dir/launch.json" "$testsfile"
  test_outcome="$(json_field "$testsfile" outcome)"
  case "${test_outcome:-}" in
    passed)          printf '◈ NUMBER ONE: your tests pass — I can use them as evidence.\n' ;;
    # NOT "your tests FAIL" (fix round 1, D1). A non-zero exit is a red test of
    # his OR a runner that never started, and nothing here can tell which — see
    # the measurement in xo-tests.py. The banner says what is known and leaves
    # the meaning to the line the look has to quote.
    failed)          printf '◈ NUMBER ONE: your test run came back FAILED — a red test of yours, or a runner that never started.\n'
                     printf '  I am not counting that against the build on its own.\n' ;;
    hung)            printf '◈ NUMBER ONE: your tests were still running after %ss, so I stopped them.\n' "$(xo_test_timeout)" ;;
    no-test-command) printf '◈ NUMBER ONE: no test command for this repo — going on what I can see.\n' ;;
    *)               printf '◈ NUMBER ONE: could not run your tests — going on what I can see.\n' ;;
  esac
  journal "$dir" tested "$(printf '"outcome": %s' "$(jstr "${test_outcome:-unknown}")")"

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
  xo_put_inputs "$input" "$xodir/criteria.json" "$shots" "$obsfile" "$testsfile"

  while [ "$round" -le "$XO_MAX_ROUNDS" ]; do
    out="$work/round-$round"
    mkdir -p "$out"
    xo_put_inputs "$input" "$xodir/criteria.json" "$shots" "$obsfile" "$testsfile"
    printf '◈ NUMBER ONE: round %s of %s — looking…\n' "$round" "$XO_MAX_ROUNDS"
    (
      export LCARS_XO_INPUT_DIR="$input"
      # The SHOTS are granted as a second input dir: on copilot the adapter turns
      # each line into an --add-dir, which is how the worker reaches the PNGs.
      # The spike proved it reads them.
      export LCARS_WORKER_INPUT_DIRS="$input
$input/shots
$input/drawing
$shots"
      if [ -n "$xo_engine" ]; then
        export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
      fi
      # THE WORKER IS TOLD ITS REAL BUDGET, not a number written into the
      # prompt. `evaluate.md` used to say "three rounds in total"; the day the
      # ceiling came down that sentence became a lie the model would have
      # planned against. run.sh prints whatever this says.
      export LCARS_XO_MAX_ROUNDS="$XO_MAX_ROUNDS"
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
        --parts-out "$xodir/build-parts-$round.json" \
        --walk-out "$xodir/walk.json" \
        >"$xodir/drive-$round.json" 2>"$xodir/drive-$round.err" &
      XO_DRIVE_PID=$!
      wait "$XO_DRIVE_PID" || drc=$?
      XO_DRIVE_PID=""
      cp "$out/xo-actions.json" "$xodir/actions-$round.json" 2>/dev/null || true
      # S239: the same round may have asked for a command, a workflow or an
      # artifact read. Same cap, same worktree, same evidence directory.
      xo_reach_actions "$dir" "$xodir" "$shots" "$out/xo-actions.json" "$round"
      # …and again after EVERY round that drove the build (S221): each round of
      # looking is another round of typing.
      xo_tree_restore "$dir"
      journal "$dir" looked "$(printf '"round": %s, "driverExit": %s' "$round" "$drc")"
      # THE SCREEN IT JUST WALKED TO IS A SCREEN THE LAYOUT PASS MUST SEE
      # (part D), and its parts are parts to pair with the drawing (part B).
      # Both run after EVERY round now, not only round 0.
      xo_observe "$shots" "$obsfile" --merge
      xo_pair_parts "$dir" "$xodir"
      xo_touch_criteria "$dir" "$xodir"
      xo_measure_walk "$dir" "$xodir" "$obsfile"
      obsfound="$("$XO_PY" -c 'import json,sys
try:
  d = json.load(open(sys.argv[1]))
  print(d.get("foundCount", len(d.get("observations") or [])))
except Exception: print(0)' "$obsfile" 2>/dev/null)"
      journal "$dir" observed "$(printf '"round": %s, "found": %s' "$round" "${obsfound:-0}")"
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
    # EVERY ROUND SPENT, NO VERDICT. A judge that will not decide is not a
    # pass. The sentence quotes $XO_MAX_ROUNDS rather than a number of its own,
    # so lowering the ceiling can never leave the captain reading "three".
    local why="Number One could not reach a verdict in $XO_MAX_ROUNDS rounds"
    local nodecide="I looked but never reached a verdict, so nothing on your list is vouched for either way"
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "scoreMeaning": %s,\n  "criteria": [],\n  "gaps": [],\n  "sawShots": %s,\n  "summary": %s\n}\n' \
      "$(jstr "$why")" "$(jstr "$nodecide")" "$(jstr "$shotlist")" \
      "$(jstr "$why — it looked at: ${shotlist:-nothing}")" >"$xodir/verdict.json"
    xo_finish "$dir" low engaged "$why — it looked at: ${shotlist:-nothing}" "$why" "$nodecide"
    xo_rm_work "$work"; XO_WORK_DIR=""
    return 0
  fi

  # --- 4b. WHAT NOBODY ASKED ABOUT (S224 item 2) ---------------------------
  # AFTER the verdict exists and BEFORE it is scored. After, because this pass
  # must not be able to influence the look — it is a second reader of the same
  # pictures, not a hint to the first. Before, because what it finds travels to
  # the captain on the wire xo-score.py already prints, and nowhere else.
  xo_unlisted_pass "$id" "$shots" "$xodir/unlisted.json" "$xo_engine"

  # --- 5. THE SCORE IS RECOMPUTED FROM THE LEDGER --------------------------
  # S241 — THE SHOTS ROOT, not this look's own directory. The eye cites a shot
  # by bare name and may cite one an EARLIER look took, so the landing rail is
  # handed the whole `shots/` tree and searches the newest look first. Handing
  # it one look's folder would make every earlier look's picture read as "no
  # landing record", which is a refusal the record does not support.
  local report
  # S216 fix round 1 (D5): importance is RECORDED in the mission's own
  # xo/impacts.json on the first look and reused by every later one.
  report="$(LCARS_XO_ENGINE="${xo_engine:-$(xo_engine_for "$st")}" \
            "$XO_PY" "$SKILL_DIR/xo-score.py" "$verdict" "$xodir/criteria.json" \
              "$xodir/verdict.json" "$obsfile" "$testsfile" "$xodir/impacts.json" \
              "$xodir/pairs.json" "$xodir/walk.json" "$xodir/seed.json" \
              "$xodir/unlisted.json" "$xodir/readings.json" "$dir/decisions.json" \
              "$xodir/journey.json" "$xodir/shots" 2>/dev/null)" || report=""
  local score="" wscore="" disagreed="" why="" summary="" meaning="" gradewhy="" line key val
  # S240 — THE ACTION, READ OFF THE WIRE. `xo-score.py` decided it beside the
  # grade; nothing here re-derives it and nothing reads it back out of the
  # report's prose.
  local recommendation="" recwhy=""
  local escalations=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%$'\t'*}"; val="${line#*$'\t'}"
    case "$key" in
      MALFORMED)    score=""; why="$XO_MALFORMED — $val" ;;
      SCORE)        score="$val" ;;
      WORKER_SCORE) wscore="$val" ;;
      DISAGREED)    disagreed="$val" ;;
      WHY)          why="$val" ;;
      MEANING)      meaning="$val" ;;
      GRADE_WHY)    gradewhy="$val" ;;
      RECOMMENDATION)     recommendation="$val" ;;
      RECOMMENDATION_WHY) recwhy="$val" ;;
      SUMMARY)      summary="$val" ;;
      NOTE)         journal "$dir" ledger-note "$(printf '"detail": %s' "$(jstr "$val")")" ;;
      # WHAT THE LOOK PUT ASIDE FOR HIM (S222 fix round 1) — journaled like any
      # other finding, so the board, `lcars xo report` and the console all show
      # it off the ONE record, and collected for the line printed below.
      ESCALATION)   journal "$dir" escalation "$(printf '"detail": %s' "$(jstr "$val")")"
                    escalations="${escalations}${val}
" ;;
      IMPACT_KEPT|IMPACT_MISMATCH|TEST_DEMOTED) xo_journal_impact "$dir" "$key" "$val" ;;
    esac
  done <<< "$report"
  xo_say_escalations "$escalations"

  if [ -z "$score" ]; then
    # A verdict that cannot be read is not a verdict. It is a LOW that says so,
    # and it stays engaged — the captain looks himself.
    local mw="${why:-$XO_MALFORMED}"
    local unreadable="I could not read back my own verdict, so there is nothing here to go on — look yourself"
    printf '{\n  "score": "low",\n  "derivation": %s,\n  "scoreMeaning": %s,\n  "criteria": [],\n  "gaps": [],\n  "summary": %s\n}\n' \
      "$(jstr "$mw")" "$(jstr "$unreadable")" "$(jstr "$mw")" >"$xodir/verdict.json"
    xo_finish "$dir" low engaged "$mw" "$mw" "$unreadable"
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
  xo_finish "$dir" "$score" "$status" "${summary:-$why}" "$why" "$meaning" "$gradewhy" \
    "$recommendation" "$recwhy"
  xo_rm_work "$work"; XO_WORK_DIR=""

  # --- 8. THE FIX ROUND (S204) ---------------------------------------------
  # A gap that CONTRADICTS something the captain wrote down is a bug, and a bug
  # gets an ordinary mission log — the same verb he would use. A HIGH has none
  # by construction, so nothing is filed; an interpretation is never filed at
  # all (it is a call the build made, reported on the report). `file_logs_for`
  # is the one implementation, shared with the hand-run `lcars xo file-logs`,
  # and it enforces the one-round marker itself.
  if [ "$status" != "finished" ]; then
    file_logs_for "$id" "$dir"
  fi
  return 0
}


# ===========================================================================
# THE FIX ROUND (S204)
#
#   lcars xo file-logs --mission <id>    file one mission log per contradiction
#   lcars xo recheck   --mission <id>    re-look after the fixes, accept or hand back
#
# WHAT THIS ROUND IS. After the Verify look scores MEDIUM or LOW, Number One
# does what the captain would: it files an ordinary mission log for each place
# the build contradicts something he wrote down, with the picture attached, and
# lets LCARS drive them. When they reach their Verify gates `resolve-logs` parks
# the PARENT on ONE consolidated re-verify ask; Number One relaunches the build,
# looks again, and either accepts the set through the ordinary verb or hands the
# gate back with the list of what still does not hold.
#
# EVERY ACTION IS AN EXISTING VERB. `log.sh` files, `resolve-logs.sh` drives,
# `respond.sh answer` answers, and answering is what triggers `resolve-logs
# complete`'s fold. Nothing here writes pending.json, plan.json or a ticket by
# hand, and nothing here opens or merges a PR.
#
# ONE ROUND, BY RULING. `numberOne.round` is set to 1 when the logs are filed and
# is never incremented: a fix that does not hold goes to the captain, not round
# two. A judge that keeps filing against its own findings is a judge with no
# stopping rule, and the third round is always the expensive one.
#
# THE CAP IS TEN. Eleven gaps file ten and JOURNAL the overflow — never a silent
# drop, because the captain reads the journal to know what his officer did.
# ===========================================================================

XO_LOG_SCRIPT="${LCARS_LOG_SCRIPT:-$SKILL_DIR/../lcars-log/log.sh}"
XO_RESOLVE_SCRIPT="${LCARS_RESOLVE_LOGS_SCRIPT:-$SKILL_DIR/../lcars-resolve-logs/resolve-logs.sh}"
XO_LOG_CAP="${LCARS_XO_LOG_CAP:-10}"

# The first question on a gate, for a note the captain reads. Deliberately small
# — the value was written by an LCARS writer that escaped it.
pending_first_question() { # <pending.json>
  [ -f "$1" ] || return 0
  sed -n '/"questions"/,$p' "$1" \
    | sed -n 's/^[[:space:]]*"\(.*\)"[,]*$/\1/p' | head -1
}

# --- the filed-logs record --------------------------------------------------
# `xo/logs.json` is the map from a gap to the child Mission that carries its
# fix. It is the ONLY thing `recheck` uses to know what it filed — not the
# mission table, not a label, not the issue text. The producer records; the
# consumer reads.
# NO HEREDOC. The bash this harness targets (3.2, the one macOS ships)
# mis-parses a here-document nested in a command substitution, and this function
# is only ever called as `x="$(xo_logs_field …)"`. A single-quoted `-c` program
# with no apostrophes in it is the shape the rest of this file already uses.
xo_logs_field() { # <logs.json> <n> <key> — a string value off entry n
  "$XO_PY" -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
    for f in d.get("filed") or []:
        if str(f.get("n")) == str(sys.argv[2]):
            print(str(f.get(sys.argv[3]) or ""))
            break
except Exception:
    pass' "$1" "$2" "$3" 2>/dev/null
}

# WHY `lcars log` DID NOT FINISH, IN WORDS (S240 fix round 2, D-A).
#
# This used to be `printf '%s' "$lout" | head -1` — the FIRST line of a chatty
# run's combined output — inlined at BOTH the message and the journal `detail`.
# MEASURED on the first live look: `lcars log` came back non-zero having printed
# nothing on stdout (its per-bug stdout is swallowed by the `$(file_one_bug …)`
# command substitution inside it), so `head -1` was the EMPTY STRING. The captain
# was handed "Number One had 7 gaps to file but `lcars log` refused them — " —
# a sentence ending on a dash with nothing after it — and the journal recorded
# `"detail": ""`. Seven gaps unfiled and not one word of why.
#
# WHAT IS ACTUALLY WORTH CARRYING, in order:
#   1. `log.sh` says why on STDERR, every line prefixed `lcars log: `. The LAST
#      such line is the one that stopped the batch, and it carries how many bugs
#      were filed BEFORE it — the one fact a re-run needs.
#   2. Failing that, the first line that reads like an error at all.
#   3. Failing that, the LAST non-empty line (never the first: a run that talks
#      fails at the end).
#   4. NO OUTPUT AT ALL is itself the finding, and it must be said: a status
#      above 128 is a signal, which means the verb was KILLED and refused
#      nothing — so some bugs may already be filed and a blind re-run doubles
#      them. That is a completely different thing from a validation refusal and
#      the captain cannot tell them apart from an empty dash.
# This function never returns an empty string, so no sentence built from it can
# end on a dangling dash.
xo_log_refusal_why() { # <combined-output> <exit-status>
  local out="$1" rc="$2" line=""
  line="$(printf '%s\n' "$out" | grep '^lcars log: ' | tail -1)"
  [ -n "$line" ] || line="$(printf '%s\n' "$out" \
      | grep -iE 'error|refus|fatal|not found|missing|must |cannot|no such' | head -1)"
  [ -n "$line" ] || line="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
  if [ -n "$line" ]; then printf '%s' "$line"; return 0; fi
  if [ "${rc:-0}" -gt 128 ] 2>/dev/null; then
    printf 'it printed nothing and exit status %d means it was KILLED by signal %d — it refused nothing, so some of the bugs may already be filed and a blind re-run would file them twice.' \
      "$rc" "$((rc - 128))"
  else
    printf 'it printed nothing and exited with status %s.' "${rc:-?}"
  fi
}

# file_logs_for <mission-id> <mission-dir>
#
# Called by `lcars xo file-logs` and, directly, by the end of `evaluate` — one
# implementation, so the wired path and the hand-run verb can never differ.
# Returns 0 on every ordinary outcome, including "there was nothing to file":
# a clean look is not a failure.
file_logs_for() { # <id> <dir>
  local id="$1" dir="$2" st xodir shots
  st="$dir/state.json"
  xodir="$dir/xo"
  # THE LOOK THAT PRODUCED THE VERDICT, not "the shots directory" (fix round 2,
  # D1). The gaps being filed here cite that look's pictures by name, and a
  # later look's directory would hold different ones under the same names.
  shots="$(xo_verdict_shots_dir "$xodir")"

  [ -s "$xodir/verdict.json" ] || {
    printf '◈ NUMBER ONE: no verdict on %s yet — there is nothing to file.\n' "$id"
    return 0
  }

  # ONE ROUND ONLY (captain ruling). The marker is READ, never inferred from the
  # presence of children or of a logs.json a half-finished run might have left.
  local round
  round="$(obj_get "$(state_xo_block "$st")" round)"
  if [ -n "$round" ]; then
    printf '◈ NUMBER ONE: %s has already had its fix round (round %s) — one round only.\n' \
      "$id" "$round"
    printf '  Anything still short of the mark is on the report, and it is yours.\n'
    return 0
  fi

  # THE SWITCH (S240). Off means nothing is FILED; the gaps are still on the
  # report and in the verdict, and the captain is told which switch did it.
  if ! cfg_files_bugs; then
    printf '◈ NUMBER ONE: filing is off for this repo (numberOne.filesBugs: false) — nothing filed.\n'
    printf '  What I found is on the report either way. Turn it back on in .git/lcars/config.json.\n'
    journal "$dir" filed-logs '"filed": 0, "detail": "filing is off (numberOne.filesBugs: false)"'
    return 0
  fi

  mkdir -p "$xodir/logs"
  local plan overflow=0 n=0
  # THE SIXTH ARGUMENT IS THE RECORD OF WHAT IS ALREADY FILED (S240). A criterion
  # already in `logs.json` is skipped and said out loud, so a second look can
  # never file the same bug twice — and an already-filed bug does not eat one of
  # the ten.
  plan="$("$XO_PY" "$SKILL_DIR/xo-logs.py" "$xodir/verdict.json" "$xodir/criteria.json" \
            "$xodir/logs" "$shots" "$XO_LOG_CAP" \
            "$([ -s "$xodir/logs.json" ] && printf '%s' "$xodir/logs.json")" 2>/dev/null)" || plan=""

  # THE ARGUMENTS ARE BUILT AS AN ARRAY AND PASSED LITERALLY. Never assembled in
  # a string and expanded: a `VAR=value` word inside an expanded "$@" RUNS AS A
  # COMMAND instead of setting anything, and this project has been bitten by
  # that twice, both times as a silent false green.
  local args=(--parent "$id")
  local line key num prd shotcsv crit title s
  local -a gap_crit=() gap_title=() gap_shots=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key="${line%%$XO_RS*}"
    case "$key" in
      OVERFLOW) overflow="${line#*$XO_RS}" ;;
      # ALREADY FILED, SAID OUT LOUD (S240). Never silently dropped: a gap the
      # captain can see on the report and cannot see a bug for would read as the
      # first officer having quietly decided not to mention it.
      ALREADY)
        IFS="$XO_RS" read -r key crit title <<< "$line"
        printf '  already filed: %s — %s\n' "$crit" "$title"
        ;;
      GAP)
        # GAP <n> <prd> <shots-csv> <criterion> <title> <attach-csv>
        # US, NOT TAB — <shots-csv> is EMPTY for a gap the project's own tests
        # found, and a tab would eat it and shift the title into nothing.
        #
        # TWO LISTS, ON PURPOSE (fix round 4, D5). <shots-csv> is what the LOOK
        # CITED and is what goes into `xo/logs.json` for `xo recheck` to
        # re-take; <attach-csv> is the WIDER list of files to hang on the
        # issue, which may include a fallback picture for a gap that cited
        # none. Writing the wider list into the record turned a shotless gap's
        # `"shots": []` into `["shot-01"]` — a fallback attachment rewriting
        # the gap's own evidence. A record and an attachment are not one fact.
        # An older xo-logs.py emitting six fields leaves <attach-csv> empty,
        # and the `:-$shotcsv` below falls back to the old behaviour exactly.
        IFS="$XO_RS" read -r key num prd shotcsv crit title attachcsv <<< "$line"
        [ -f "$prd" ] || continue
        n=$((n + 1))
        args+=(--prd "$prd")
        # TWO EXPANSIONS, NOT ONE. Bash cannot do `:-` and `//,/ ` in the same
        # parameter expansion, and `${attachcsv:-$shotcsv}` alone silently
        # dropped the comma-to-space split — one argument of
        # "a.png,b.png" that no `[ -f ]` would ever match.
        local attachlist="${attachcsv:-$shotcsv}"
        for s in ${attachlist//,/ }; do
          # A SHOT THAT IS NOT THERE IS NOT PASSED. `log.sh` validates every
          # attachment before it files ANYTHING, so one missing PNG would refuse
          # the whole filing — and a gap is worth filing with a name for its
          # shot even when the file has been swept.
          [ -f "$s" ] && args+=(--attach "$s")
        done
        gap_crit+=("$crit"); gap_title+=("$title"); gap_shots+=("$shotcsv")
        ;;
    esac
  done <<< "$plan"

  if [ "$n" -eq 0 ]; then
    printf '◈ NUMBER ONE: nothing on %s contradicts what you wrote down — no logs filed.\n' "$id"
    journal "$dir" filed-logs '"filed": 0, "detail": "no contradictions to file"'
    return 0
  fi

  # --- ONE call to the ordinary verb ---------------------------------------
  # Exactly the invocation run.sh already makes (`LCARS_WORKER_BIN=<engine> bash
  # log.sh --parent … --prd …`), with the engine pinned the way every other
  # Number One spawn pins it. The mockup is NOT attached here: `log.sh` inherits
  # the parent's drawing itself (S174), and a second copy would land twice.
  local xo_engine=""
  [ -n "${LCARS_WORKER_BIN:-}" ] || xo_engine="$(xo_engine_for "$st")"
  local lout lrc=0
  lout="$(
    if [ -n "$xo_engine" ]; then
      export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
    fi
    # $LCARS_XO_INTERNAL=<this mission> — Number One's own hand on its own
    # verb (S204 fix round 1, D1). `log.sh` takes the engaged lock on the
    # PARENT dir, and the parent is this mission; without the marker the
    # first officer's filing is refused by the lock that protects its work.
    # It names THIS mission only: a reach for any other mission still locks.
    LCARS_XO_INTERNAL="$id" bash "$XO_LOG_SCRIPT" "${args[@]}" 2>&1
  )" || lrc=$?

  if [ "$lrc" -ne 0 ]; then
    # THE REASON IS CARRIED, NOT DROPPED (S240 fix round 2, D-A). See
    # `xo_log_refusal_why` above: one answer, used for BOTH the sentence the
    # captain reads and the journal's `detail`, and never empty.
    local lwhy
    lwhy="$(xo_log_refusal_why "$lout" "$lrc")"
    escalate "$dir" verify \
      "Number One had $n gaps to file but \`lcars log\` did not finish: $lwhy" \
      "$(printf '"stage": "verify", "reason": "log-refused", "exit": %s, "detail": %s' \
           "$lrc" "$(jstr "$lwhy")")"
  fi

  # --- the child ids, read off the verb's own summary ----------------------
  # `log.sh` prints one indented `<id>  <#issue|(local)>  <title>` row per bug,
  # in the order the --prd arguments were given. That order is the binding.
  local -a kid=() kissue=()
  while IFS= read -r line; do
    case "$line" in
      '  lcars-'*)
        set -- $line
        kid+=("$1"); kissue+=("${2#\#}")
        ;;
    esac
  done <<< "$lout"

  # --- logs.json: the map recheck reads ------------------------------------
  local i items=""
  i=0
  while [ "$i" -lt "$n" ]; do
    local sj="" sn
    for sn in ${gap_shots[$i]//,/ }; do
      sn="$(basename "$sn")"; sn="${sn%.png}"
      sj="${sj:+$sj, }$(jstr "$sn")"
    done
    items="${items:+$items,}$(printf '{"n": %d, "mission": %s, "issue": %s, "criterion": %s, "title": %s, "shots": [%s]}' \
      "$((i + 1))" "$(jstr "${kid[$i]:-}")" "$(jstr "${kissue[$i]:-}")" \
      "$(jstr "${gap_crit[$i]}")" "$(jstr "${gap_title[$i]}")" "$sj")"
    i=$((i + 1))
  done
  printf '{"round": 1, "filedAt": %s, "overflow": %s, "filed": [%s]}\n' \
    "$(jstr "$NOW")" "${overflow:-0}" "$items" >"$xodir/logs.json"

  # --- the record ----------------------------------------------------------
  local obj
  obj="$(state_xo_block "$st")"
  obj="$(obj_set "$obj" round "$(jstr 1)")"
  obj="$(obj_set "$obj" status "$(jstr engaged)")"
  # Singular or plural, properly (S204 fix round 1, D5).
  local filednoun="logs"; [ "$n" -eq 1 ] && filednoun="log"
  obj="$(obj_set "$obj" lastAction "$(jstr "filed $n $filednoun $NOW_LOCAL")")"
  # THE NOTE IS NOT TOUCHED. It carries the LOOK's own sentence — what is short
  # of the mark and why — which is the thing the captain reads off the card and
  # the one thing filing a log does not change. What was filed is in the journal
  # and in `xo/logs.json`, where the surfaces already read it from.
  state_set_xo "$st" "$obj"
  lcars_state_refusal_die "lcars xo file-logs"

  journal "$dir" filed-logs \
    "$(printf '"filed": %d, "detail": %s' "$n" \
         "$(jstr "$n log(s) filed against $id: $(printf '%s ' "${kid[@]:-}" | sed 's/ $//')")")"
  # THE OVERFLOW IS SAID OUT LOUD. Ten is the cap; an eleventh gap that is never
  # mentioned is the first officer quietly deciding what the captain gets to see.
  if [ "${overflow:-0}" -gt 0 ] 2>/dev/null; then
    journal "$dir" overflow \
      "$(printf '"detail": %s' "$(jstr "$overflow more gaps not filed — cap $XO_LOG_CAP")")"
    printf '  %s more gap(s) were NOT filed — the cap is %s. They are on the report.\n' \
      "$overflow" "$XO_LOG_CAP"
  fi
  xo_mirror "$id"

  printf '◈ NUMBER ONE: filed %d mission log(s) against %s.\n' "$n" "$id"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf '  log #%d  %s  %s\n' "$((i + 1))" "${kid[$i]:-?}" "${gap_title[$i]}"
    i=$((i + 1))
  done

  # --- THE SEND-BACK NAMES WHAT IT IS ABOUT (fix round 4, D4) --------------
  # `xo-score.py` decides the send-back as DATA and writes `blockers[]` for it,
  # with its own comment saying `filedAs` is "stamped onto them later, by
  # whoever files them". Nothing ever stamped it — a grep for the name found
  # two comments promising it and no writer. So the captain was handed a
  # SEND-BACK naming no bug id and no command, three lines under a list of the
  # very bug ids it was decided from.
  #
  # THE FILER RECORDS IT. This is the producer: it knows the criterion and the
  # mission id it got for that criterion, so it writes the pair down once, on
  # the row the decision was made from. No surface ever parses a bug id back
  # out of finished prose.
  if [ -f "$xodir/verdict.json" ] && [ -f "$SKILL_DIR/xo-filed.py" ]; then
    local -a filedargs=()
    i=0
    while [ "$i" -lt "$n" ]; do
      [ -n "${kid[$i]:-}" ] && filedargs+=("${gap_crit[$i]:-}=${kid[$i]}")
      i=$((i + 1))
    done
    local sendback=""
    if [ "${#filedargs[@]}" -gt 0 ]; then
      sendback="$("$XO_PY" "$SKILL_DIR/xo-filed.py" "$xodir/verdict.json" "$id" \
                    "${filedargs[@]}" 2>/dev/null)" || sendback=""
    fi
    # Printed only when the verdict really says send-back — the helper returns
    # nothing otherwise, so this is one line either way and never a guess.
    [ -n "$sendback" ] && printf '  %s\n' "$sendback"
  fi

  # --- hand them to LCARS's own driver, DETACHED ---------------------------
  # `resolve-logs` orders them, drives each to its Verify gate and raises ONE
  # consolidated re-verify ask on this parent. It takes a long time and it is
  # Its pid goes in `xo-resolve.pid`, WITH the identity that lets
  # `lcars xo off` stop this exact process later (see xo_write_pidfile).
  mkdir -p "$xodir"
  local rchild=""
  # $LCARS_XO_INTERNAL=<this mission> — same marker, same reason (S204 fix
  # round 1, D1): `resolve-logs.sh` takes the engaged lock on the PARENT, and
  # the parent is this mission. It names ONLY this mission, so the child bug
  # missions this drive works — and the workers it spawns for them — are
  # exempted by nothing and locked exactly as they were.
  #
  # DETACHED THROUGH THE ONE HELPER (fix round 4, D3) — which makes the chain
  # its own session so a single group kill reaches the driver AND the worker it
  # spawns, and records WHO it is. See xo_spawn_detached for the measurement
  # that made this necessary: `setsid` is absent on macOS, the nohup fallback
  # left the chain in the LOOK's group, and the stop killed the driver while
  # its worker went on running.
  rchild="$(LCARS_XO_INTERNAL="$id" xo_spawn_detached \
    "$dir/xo-resolve.pid" "$xodir/resolve.log" \
    bash "$XO_RESOLVE_SCRIPT" --parent "$id")"
  printf '  LCARS is driving them now. I will re-check the build when they land.\n'
  return 0
}

cmd_file_logs() {
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
  local id dir
  id="$(resolve_mission "$target")" || exit $?
  dir="$MISSIONS_DIR/$id"
  XO_MISSION_DIR="$dir"
  file_logs_for "$id" "$dir"
}

# xo_recheck_branch_report <state.json> — S205 ruling 2, 2026-09-14.
#
# `xo recheck` used to relaunch straight from whatever the LOCAL checkout
# happened to hold, and never fetched — so a branch that had moved anywhere
# else (a fix pushed from another machine, a captain who force-pushed a
# rebase) got a confident, WRONG "every fix held". S204's own round-3 tester
# had to `git fetch origin` BY HAND before its sabotage even reached the
# product. A false "held" is the same family of defect as the evidence-
# contamination bug S204 cured: both make Number One certify something it did
# not actually see.
#
# Sets two globals the caller prints and journals:
#   XO_RECHECK_SHA    the short commit this look is ABOUT to examine
#   XO_RECHECK_NOTE   one plain sentence: what the fetch found (or why it
#                     could not happen), always true, never a guess
#
# Best-effort throughout — a repo with no `origin`, no network, or no
# recorded branch never blocks the look; it just means this can only say
# which LOCAL commit it examined, honestly, rather than pretending to have
# checked upstream.
#
# ONLY EVER FAST-FORWARDS. When origin has moved PAST the local branch with
# no local-only work, the local ref is brought up to date (the ordinary case
# S204 hit — a fix pushed elsewhere). When the local branch carries commits
# origin does not have, or the two have diverged, this NEVER force-resets —
# that is exactly the data-loss `reconcile_sync_local_branch` (run.sh) was
# written to stop — it says so instead, by name, so the report is honest
# about what it is (and is not) looking at.
xo_recheck_branch_report() {
  local st="$1" branch local_before local_after remote
  XO_RECHECK_SHA=""
  XO_RECHECK_NOTE=""
  branch="$(json_field "$st" branch)"
  if [ -z "$branch" ]; then
    XO_RECHECK_NOTE="no branch is recorded for this mission — looking at whatever this checkout resolves to locally."
    XO_RECHECK_SHA="$("$GIT_BIN" rev-parse --short HEAD 2>/dev/null)"
    return 0
  fi
  local_before="$("$GIT_BIN" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)"
  if "$GIT_BIN" fetch origin "$branch" --quiet 2>/dev/null; then
    remote="$("$GIT_BIN" rev-parse --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null)"
    if [ -z "$remote" ]; then
      XO_RECHECK_NOTE="fetched origin, but it has no '$branch' branch — looking at the local commit only."
    elif [ "$remote" = "$local_before" ]; then
      XO_RECHECK_NOTE="fetched origin/$branch — already up to date."
    elif [ -n "$local_before" ] \
         && "$GIT_BIN" merge-base --is-ancestor "$local_before" "$remote" 2>/dev/null; then
      "$GIT_BIN" update-ref "refs/heads/$branch" "$remote" 2>/dev/null
      XO_RECHECK_NOTE="fetched origin/$branch — it had moved, so I brought the local branch up to date before looking again."
    else
      XO_RECHECK_NOTE="origin/$branch and the local branch have diverged — looking at the LOCAL commit; if the fix was pushed somewhere else, land it on this branch before asking me to look again."
    fi
  else
    XO_RECHECK_NOTE="could not reach origin to fetch '$branch' — looking at the local commit only."
  fi
  local_after="$("$GIT_BIN" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null)"
  [ -n "$local_after" ] || local_after="${local_before:-HEAD}"
  XO_RECHECK_SHA="$("$GIT_BIN" rev-parse --short "$local_after" 2>/dev/null)"
}

# ===========================================================================
# RECHECK — the second look, after the logged fixes landed.
# ===========================================================================
cmd_recheck() {
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
  local id dir st xodir shots look
  id="$(resolve_mission "$target")" || exit $?
  dir="$MISSIONS_DIR/$id"
  st="$dir/state.json"
  xodir="$dir/xo"

  # AN ACCEPT IS FINAL (S205 ruling 1, captain, 2026-09-14). Checked FIRST,
  # before a look name is even minted: once Number One has handed a mission
  # back — `status: finished`, the terminal state both a clean first look and
  # a successful recheck record — asking it to look again is refused, in the
  # captain's own words, not re-run. S204's round-3 defects were all
  # downstream of running another look with nowhere to put the answer (the
  # mission's own comment kept the earlier "held" verdict while the
  # escalation contradicted it; the escalation pointed at a gate that no
  # longer existed; `verdict-2.json` / `second/report.md` were overwritten,
  # losing the record of what was accepted). Refusing DELETES all three by
  # removing the state rather than defining a re-check-after-accept flow.
  # Wanting a fresh opinion after changing the branch is a deliberate
  # restart — stand it down and re-engage — never this verb again on a
  # mission it already closed out.
  [ "$(obj_get "$(state_xo_block "$st")" status)" = "finished" ] \
    && die "I've already handed this one back — the PR is yours."

  # THIS re-check's own directory (fix round 2, D1) — `recheck-1`, then
  # `recheck-2`. The name is resolved here and the directory is opened below, so
  # a re-check that escalates before it ever launches leaves no empty shell of a
  # look behind for the next one to skip over.
  look="$(xo_next_look_name "$xodir" recheck)"
  shots="$xodir/shots/$look"
  [ -s "$xodir/logs.json" ] \
    || die "mission '$id' has no record of any logs Number One filed — there is nothing to re-check."

  XO_MISSION_DIR="$dir"

  # --- 1. A CHILD THAT NEEDS THE CAPTAIN BLOCKS EVERYTHING -----------------
  # Checked FIRST, before a launch, a browser or a worker is spent on it. A
  # parked child cannot be folded (resolve-logs' completeness guard refuses the
  # whole batch), so re-looking at the build would buy a verdict nobody can act
  # on. The gate goes back to the captain naming the log that needs him.
  local nlogs i cmid cst blocked="" blocked_kind=""
  nlogs="$(grep -o '"mission"' "$xodir/logs.json" | grep -c . | tr -d ' ')"
  i=1
  while [ "$i" -le "${nlogs:-0}" ]; do
    cmid="$(xo_logs_field "$xodir/logs.json" "$i" mission)"
    if [ -n "$cmid" ] && [ -f "$MISSIONS_DIR/$cmid/state.json" ]; then
      cst="$MISSIONS_DIR/$cmid/state.json"
      if grep -q '"awaitingHuman"[[:space:]]*:[[:space:]]*true' "$cst" 2>/dev/null; then
        blocked="${blocked:+$blocked, }log #$i needs you ($cmid)"
        blocked_kind=parked
      else
        case "$(mission_stage "$cst")" in
          verify|done) : ;;
          *) blocked="${blocked:+$blocked, }log #$i has not reached its Verify gate ($cmid, stage $(mission_stage "$cst"))"
             [ -n "$blocked_kind" ] || blocked_kind=undriven ;;
        esac
      fi
    fi
    i=$((i + 1))
  done
  if [ -n "$blocked" ]; then
    escalate "$dir" verify \
      "I cannot accept the fixes yet — $blocked. Answer that one and I will have another look." \
      "$(printf '"stage": "verify", "reason": %s, "detail": %s' \
           "$(jstr "child-$blocked_kind")" "$(jstr "$blocked")")"
  fi

  # --- 1b. DO NOT TRUST THE LOCAL BRANCH (S205 ruling 2, 2026-09-14) -------
  # `xo_recheck_branch_report` fetches the mission's branch from origin
  # (best-effort — never fatal) and, when that is a clean fast-forward, brings
  # the LOCAL branch ref up to date before the relaunch below ever reads it.
  # When it cannot (no remote, no network, or the histories have diverged and
  # forcing would destroy real local work) it never pretends otherwise: it
  # says, plainly, which commit it is about to look at and why. Either way the
  # captain never gets a confident "every fix held" against a branch this
  # process never actually looked at.
  xo_recheck_branch_report "$st"

  # --- 2. THE SECOND LOOK ---------------------------------------------------
  mkdir -p "$xodir" "$shots"
  # WHERE THIS RE-CHECK'S PICTURES LIVE, recorded the moment the directory is
  # opened — the exact idiom `evaluate` uses for `look.txt` (line 2187), and
  # for the same reason: the board must be able to find the pictures a verdict
  # cites without guessing which directory they went into. `look.txt` itself is
  # NOT re-pointed — it belongs to the first look, and the filed gaps' shots
  # (`file-logs`, `xo_verdict_shots_dir`) are still that look's.
  mkdir -p "$xodir/second"
  printf 'shots/%s\n' "$look" >"$xodir/second/look.txt"
  XO_LAUNCH_ID="$id"
  XO_STOP_LOG="$xodir/launch.log"
  trap xo_teardown EXIT
  trap on_stand_down TERM INT
  printf '%s\n' "$$" >"$dir/xo.pid"

  local rc_obj
  rc_obj="$(state_xo_block "$st")"
  rc_obj="$(obj_set "$rc_obj" status "$(jstr engaged)")"
  rc_obj="$(obj_set "$rc_obj" lastAction "$(jstr "re-checking $NOW_LOCAL")")"
  [ -n "$rc_obj" ] && state_set_xo "$st" "$rc_obj"

  local xo_engine=""
  [ -n "${LCARS_WORKER_BIN:-}" ] || xo_engine="$(xo_engine_for "$st")"

  printf '◈ NUMBER ONE: the fixes are on the branch — relaunching the build…\n'
  printf '  looking at commit %s. %s\n' "${XO_RECHECK_SHA:-unknown}" "${XO_RECHECK_NOTE:-}"
  (
    if [ -n "$xo_engine" ]; then
      export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
    fi
    exec bash "$XO_LAUNCH_SCRIPT" "$id"
  ) >>"$xodir/launch.log" 2>&1 || true
  local lstatus lurl lmsg
  lstatus="$(json_field "$dir/launch.json" status)"
  lurl="$(json_field "$dir/launch.json" url)"
  lmsg="$(json_field "$dir/launch.json" message)"
  if [ "$lstatus" != "running" ] || [ -z "$lurl" ]; then
    # NO BROWSER, AND NO ACCEPT. A build that will not come up is not evidence
    # that the fixes held — it is the captain's to look at.
    rm -f "$dir/xo.pid"; trap - TERM INT
    escalate "$dir" verify \
      "the fixes are in, but I could not relaunch the build to check them: ${lmsg:-status ${lstatus:-unknown}}" \
      "$(printf '"stage": "verify", "reason": "relaunch-failed", "detail": %s' \
           "$(jstr "${lmsg:-status ${lstatus:-unknown}}")")"
  fi
  XO_LAUNCH_STOPPED=0
  printf '  the build is up at %s\n' "$lurl"
  journal "$dir" relaunched \
    "$(printf '"url": %s, "commit": %s, "branchNote": %s' \
         "$(jstr "$lurl")" "$(jstr "${XO_RECHECK_SHA:-}")" "$(jstr "${XO_RECHECK_NOTE:-}")")"
  # THE RELAUNCHED TREE IS REMEMBERED TOO (S221). A recheck drives the build the
  # same way a look does, and it runs the project's suite afterwards — so it
  # gets the same guarantee: whatever the browser leaves behind is put back.
  xo_tree_mark "$(json_field "$dir/launch.json" worktree)" "$xodir/tree-mark"

  # --- 2a. THE SAME JOURNEY, WALKED AGAIN (S222 fix round 1) ---------------
  #
  # THE DEFECT. This drive was called with neither `--journey` nor
  # `--walk-out`, so a re-check photographed whatever the build opens on and
  # nothing else. Measured on the captain's own repo on 2026-09-20: the look
  # left 30 walk artefacts in `shots/look-1`, the re-check left NOT ONE in
  # `shots/recheck-1`; the look's shot was of `…#mbr`, the re-check's of the
  # landing page. Every side-by-side then read "42 drawn part(s): 0 matched,
  # 42 unreachable" against 4 / 7 / 8 on the looks — so three times out of
  # three the fixes held and Number One still had to hand the mission back,
  # because it could not see them. It said so exactly: "a new test passes, but
  # that is code, not the button on screen." That refusal is right. This is
  # the missing half of it.
  #
  # THE PLAN IS RE-USED, NEVER RE-PLANNED. `journey.json` was declared from the
  # record before the first look ever launched, and it is still on disk.
  # Re-planning here would invite a second, differently-shaped journey — and
  # then the before and after pictures are not of the same thing. When there is
  # no journey on record (a mission first looked at before this existed), that
  # is said in one plain sentence and the re-check carries on seeing what it
  # can, rather than inventing a flow.
  #
  # AND ITS OWN RECORD. `walk-<look>.json`, not `walk.json`: the driver MERGES
  # into whatever it finds at `--walk-out`, so writing there would glue this
  # walk onto the first look's and leave neither readable.
  local rwalk="$xodir/walk-$look.json"
  local -a jargs=()
  if [ -s "$xodir/journey.json" ]; then
    jargs=(--journey "$xodir/journey.json" --walk-out "$rwalk")
    printf '◈ NUMBER ONE: walking the same journey I walked the first time.\n'
  else
    printf '◈ NUMBER ONE: the first look left no journey on record, so I can only see the screen your build opens on.\n'
    journal "$dir" journey \
      '"detail": "no journey was on record from the first look, so this re-check could not walk one"'
  fi

  local drc=0
  "$XO_NODE" "$XO_DRIVER" --url "$lurl" --out "$shots" \
    --place-names "$xodir/criteria.json" --prefix "recheck" \
    --parts-out "$xodir/build-parts-recheck.json" \
    ${jargs[@]+"${jargs[@]}"} \
    >"$xodir/drive-recheck.json" 2>"$xodir/drive-recheck.err" &
  XO_DRIVE_PID=$!
  wait "$XO_DRIVE_PID" || drc=$?
  XO_DRIVE_PID=""
  if [ "$drc" -eq 77 ]; then
    xo_stop_launch
    rm -f "$dir/xo.pid"; trap - TERM INT
    escalate "$dir" verify \
      "the fixes are in, but the browser would not start, so I have no picture of them ($(head -1 "$xodir/drive-recheck.err" 2>/dev/null))" \
      "$(printf '"stage": "verify", "reason": "browser-failed", "detail": %s' \
           "$(jstr "$(head -1 "$xodir/drive-recheck.err" 2>/dev/null)")")"
  fi
  xo_tree_restore "$dir"
  journal "$dir" looked "$(printf '"round": %s, "shots": %s, "shotsDir": %s' \
    "$(jstr "$look")" \
    "$(ls "$shots"/*.png 2>/dev/null | grep -c . | tr -d ' ')" \
    "$(jstr "${shots#$dir/}")")"

  # --- 2b. THE OBSERVATIONS PASS, AGAIN (S210). A recheck is a look too — the
  # fixes may have moved things — so it gets its own fresh pass over the
  # relaunched build's boxes, exactly as round 0 does.
  local obsfile="$xodir/observations.json" obsn=0
  xo_observe "$shots" "$obsfile"
  local obsfound=0
  [ -s "$obsfile" ] && obsn="$("$XO_PY" -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("observations") or []))
except Exception: print(0)' "$obsfile" 2>/dev/null)"
  # WHAT IT FOUND, beside what it PRINTED. Past a handful the pass keeps only
  # the worst few (S212), and a record that logged the short list as the whole
  # story would make a busy page look like a quiet one for ever after.
  [ -s "$obsfile" ] && obsfound="$("$XO_PY" -c 'import json,sys
try:
  d = json.load(open(sys.argv[1]))
  print(d.get("foundCount", len(d.get("observations") or [])))
except Exception: print(0)' "$obsfile" 2>/dev/null)"
  obsn="${obsn:-0}"; obsfound="${obsfound:-0}"
  journal "$dir" observed "$(printf '"count": %s, "found": %s' "${obsn:-0}" "${obsfound:-0}")"

  # --- 2b-ii. AND THE DRAWING, BESIDE THE FIXED BUILD (S220 part B). A recheck
  # is where "did the fix actually make it look like the drawing" is answered,
  # so the pairs are recomputed from the relaunched build's own parts. The
  # drawing itself has not changed; its parts were read at the first look.
  #
  # BUT FIRST, RECORD WHAT THE PRIOR LOOK COULD SEE (S222 round 2). At this
  # instant `pairs.json` is still the FIRST look's, so its `matched` is the
  # part-match count the look this re-check confirms actually saw. Read that
  # RECORDED number now, before we overwrite it, and hand it to the pairing as
  # the baseline — the re-check reads the number, it never re-derives it from
  # prose. If the re-check then sees far fewer, the pairing flags a visibility
  # collapse and the accept below refuses to grade HIGH on what it could not see.
  local vis_baseline=""
  if [ -s "$xodir/pairs.json" ]; then
    vis_baseline="$("$XO_PY" -c 'import json,sys
try: print(int(json.load(open(sys.argv[1])).get("matched")))
except Exception: pass' "$xodir/pairs.json" 2>/dev/null)"
  fi
  rm -f "$xodir"/build-parts-[0-9]*.json 2>/dev/null || true
  xo_pair_parts "$dir" "$xodir" "$vis_baseline"
  xo_touch_criteria "$dir" "$xodir" "$rwalk"
  # AND WHAT THE WALK MEASURED (S222 fix round 1) — the icon bigger than its
  # own control, the value that does not carry from one screen to the next.
  # Those are the readings the fixes filed against, and until this ran on the
  # re-check too the second look had no measurement of them at all.
  xo_measure_walk "$dir" "$xodir" "$obsfile" "$rwalk"

  # --- 2c. AND THE PROJECT'S OWN TESTS, AGAIN (S211). A recheck relaunches the
  # build from the FIXED branch, so the first look's test run is about code that
  # no longer exists. Re-running it here is the same reason the observations
  # pass re-runs: this is a look, and a look reasons from what is in front of it
  # today. Handing the recheck stale evidence is the S204 stale-shots defect in
  # another costume — it reached the right verdict once by luck and the wrong
  # one the time after.
  local testsfile="$xodir/tests.json" test_outcome2=""
  xo_run_tests "$dir/launch.json" "$testsfile"
  test_outcome2="$(json_field "$testsfile" outcome)"
  journal "$dir" tested "$(printf '"outcome": %s, "round": "recheck"' "$(jstr "${test_outcome2:-unknown}")")"

  # --- 3. ONE worker round, with the FIRST verdict in front of it ----------
  # No second round of looking and no actions file: the question here is narrow
  # ("did each filed gap's fix hold?") and a judge that can ask for more looking
  # on a narrow question is a judge that can spend its way to an answer.
  local work input out
  work="$(mktemp -d)"; input="$work/input"; out="$work/recheck"
  XO_WORK_DIR="$work"
  mkdir -p "$input" "$out"
  gather_inputs "$dir" "$input"
  xo_put_inputs "$input" "$xodir/criteria.json" "$shots" "$obsfile" "$testsfile" "$rwalk"
  # The first verdict, the filed logs and their PRDs — the record of what this
  # re-check is ABOUT. Copied through the same unlock/copy/re-lock door
  # everything else in the input tree goes through.
  chmod u+w "$input" 2>/dev/null || true
  mkdir -p "$input/xo" 2>/dev/null || true
  cp "$xodir/verdict.json" "$input/xo/verdict.json" 2>/dev/null || true
  cp "$xodir/logs.json" "$input/xo/logs.json" 2>/dev/null || true
  if [ -d "$xodir/logs" ]; then
    mkdir -p "$input/xo/logs" 2>/dev/null || true
    cp "$xodir"/logs/*.md "$input/xo/logs/" 2>/dev/null || true
  fi
  chmod -R a-w "$input" 2>/dev/null || true

  printf '◈ NUMBER ONE: looking again, gap by gap…\n'
  (
    export LCARS_XO_INPUT_DIR="$input"
    export LCARS_WORKER_INPUT_DIRS="$input
$input/shots
$input/drawing
$shots"
    if [ -n "$xo_engine" ]; then
      export LCARS_WORKER_BIN="$xo_engine" LCARS_WORKER_BIN_INTERNAL=1
    fi
    exec bash "$XO_RUN_SCRIPT" spawn-number-one \
      --mission "$id" --mode recheck --outdir "$out"
  ) >/dev/null 2>&1 &
  XO_SPIN_PID=$!
  wait "$XO_SPIN_PID" 2>/dev/null || true
  XO_SPIN_PID=""

  xo_stop_launch
  rm -f "$dir/xo.pid"; trap - TERM INT

  # --- 4. DID EACH FIX HOLD? ----------------------------------------------
  local held_out
  held_out="$("$XO_PY" "$SKILL_DIR/xo-held.py" "$out/xo-recheck.json" "$xodir/logs.json" 2>/dev/null)" \
    || held_out=""
  local kind num mission crit title why line
  local held_list="" not_list="" nheld=0 nnot=0 malformed=""
  # THE THING FIRST, THE IDS IN BRACKETS AFTER IT (fix round 2, D2). This line
  # goes onto the card and into the escalation the captain reads on his phone;
  # `log #1 (t-3-ac1) — …` is two machine handles and a colour of nothing. The
  # title is the name Number One itself gave the gap when it filed the log, so
  # nothing here is invented — and every number, shot name and quoted line the
  # worker gave stays exactly where it was.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # US, NOT TAB (fix round 1, D2) — `mission` and `criterion` both come off a
    # filed-logs record that can carry either of them empty.
    IFS="$XO_RS" read -r kind num mission crit title why <<< "$line"
    case "$kind" in
      MALFORMED) malformed="$num" ;;
      HELD)    nheld=$((nheld + 1)); held_list="${held_list:+$held_list; }${title:-log #$num} — $why (log #$num, $crit)" ;;
      NOTHELD) nnot=$((nnot + 1));  not_list="${not_list:+$not_list; }${title:-log #$num} — $why (log #$num, $crit)"
               journal "$dir" fix-did-not-hold \
                 "$(printf '"log": %s, "mission": %s, "criterion": %s, "detail": %s' \
                      "$(jstr "$num")" "$(jstr "$mission")" "$(jstr "$crit")" \
                      "$(jstr "fix did not hold: $why")")" ;;
    esac
  done <<< "$held_out"

  if [ -n "$malformed" ]; then
    escalate "$dir" verify \
      "$XO_MALFORMED — $malformed" \
      "$(printf '"stage": "verify", "reason": "malformed", "detail": %s' "$(jstr "$malformed")")"
  fi

  # --- 5. THE SECOND SCORE, FROM THE LEDGER, EXACTLY AS THE FIRST ----------
  # Run BEFORE the accept so the report exists whichever way this ends: an
  # escalation owes the captain the same ledger an acceptance does.
  local score2="" why2="" summary2="" escalations2=""
  if [ -s "$out/xo-recheck.json" ]; then
    mkdir -p "$xodir/second"
    [ -s "$xodir/report.md" ] && cp "$xodir/report.md" "$xodir/report-1.md" 2>/dev/null
    local rep2 key val
    rep2="$(LCARS_XO_ENGINE="${xo_engine:-$(xo_engine_for "$st")}" \
            "$XO_PY" "$SKILL_DIR/xo-score.py" "$out/xo-recheck.json" "$xodir/criteria.json" \
              "$xodir/second/verdict.json" "$obsfile" "$testsfile" "$xodir/impacts.json" \
              "$xodir/pairs.json" "$rwalk" "$xodir/seed.json" "" "" "$dir/decisions.json" \
              "$xodir/journey.json" 2>/dev/null)" || rep2=""
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      key="${line%%$'\t'*}"; val="${line#*$'\t'}"
      case "$key" in
        SCORE)   score2="$val" ;;
        WHY)     why2="$val" ;;
        SUMMARY) summary2="$val" ;;
        ESCALATION) journal "$dir" escalation "$(printf '"detail": %s' "$(jstr "$val")")"
                    escalations2="${escalations2}${val}
" ;;
        IMPACT_KEPT|IMPACT_MISMATCH|TEST_DEMOTED) xo_journal_impact "$dir" "$key" "$val" ;;
      esac
    done <<< "$rep2"
    xo_say_escalations "$escalations2"
    if [ -n "$score2" ]; then
      cp "$xodir/second/verdict.json" "$xodir/verdict-2.json" 2>/dev/null || true
      # ONE REPORT, TWO LOOKS, IN ORDER. The captain asked to see the fix beside
      # the finding; the living comment renders `report.md` verbatim, so the
      # before and the after have to live in that one file.
      {
        printf '### After the fixes\n\n'
        cat "$xodir/second/report.md" 2>/dev/null
        if [ -s "$xodir/report-1.md" ]; then
          printf '\n<details>\n<summary>The first look, before the fixes</summary>\n\n'
          cat "$xodir/report-1.md"
          printf '\n</details>\n'
        fi
      } >"$xodir/report.md"
    fi
  fi

  # --- 6. ACCEPT, OR HAND IT BACK ------------------------------------------
  # DID THE RE-CHECK GO BLIND? (S222 round 2). Before anything else, read the
  # visibility comparison the pairing RECORDED against the prior look's part-match
  # count. A sharp fall — the button it was re-checking gone from view — is "I
  # could not check whether this was fixed", not "resolved": a look that saw
  # nothing has not earned a pass, so this may never accept or grade HIGH on it.
  # `escalate` exits, so this stops before the accept and before HIGH is labelled.
  if [ -s "$xodir/pairs.json" ]; then
    local vis_says=""
    vis_says="$("$XO_PY" -c 'import json,sys
try:
  v = json.load(open(sys.argv[1])).get("visibility") or {}
  if v.get("collapsed"): sys.stdout.write(str(v.get("says") or ""))
except Exception: pass' "$xodir/pairs.json" 2>/dev/null)" || vis_says=""
    if [ -n "$vis_says" ]; then
      local vis_b vis_n
      vis_b="$("$XO_PY" -c 'import json,sys
try: print(int((json.load(open(sys.argv[1])).get("visibility") or {}).get("baseline")))
except Exception: print(0)' "$xodir/pairs.json" 2>/dev/null)"
      vis_n="$("$XO_PY" -c 'import json,sys
try: print(int((json.load(open(sys.argv[1])).get("visibility") or {}).get("now")))
except Exception: print(0)' "$xodir/pairs.json" 2>/dev/null)"
      journal "$dir" visibility-collapse \
        "$(printf '"baseline": %s, "now": %s, "detail": %s' \
             "${vis_b:-0}" "${vis_n:-0}" "$(jstr "$vis_says")")"
      escalate "$dir" verify "$vis_says" \
        "$(printf '"stage": "verify", "reason": "visibility-collapse", "baseline": %s, "now": %s, "detail": %s' \
             "${vis_b:-0}" "${vis_n:-0}" "$(jstr "$vis_says")")"
    fi
  fi

  if [ "$nnot" -gt 0 ] || [ "$nheld" -eq 0 ]; then
    # NEVER A SECOND ROUND (captain ruling). The gate stays exactly where
    # resolve-logs raised it, with the list of what still does not hold beside
    # it, and the captain decides.
    local note="the fixes are in but $nnot of them did not hold — $not_list"
    [ "$nheld" -eq 0 ] && [ "$nnot" -eq 0 ] \
      && note="I could not tell whether the fixes held — nothing in the re-check named a single one of them"
    escalate "$dir" verify "$note" \
      "$(printf '"stage": "verify", "reason": "fixes-did-not-hold", "held": %d, "notHeld": %d, "detail": %s' \
           "$nheld" "$nnot" "$(jstr "$not_list")")"
  fi

  # EVERY FIX HELD. Answer the consolidated gate through the ordinary verb — the
  # one a human uses — which is what triggers `resolve-logs complete`'s fold of
  # each child to Done and the push of the parent branch. Number One never folds
  # anything itself and never touches the PR.
  local answer_text="Accepted. I re-checked each logged fix against the criterion it was filed for and every one holds: $held_list"
  local rrc=0 rout
  rout="$(LCARS_RESPOND_RESUME=0 LCARS_ANSWERED_BY=number-one LCARS_XO_INTERNAL="$id" \
          bash "$XO_RESPOND_SCRIPT" answer \
            --mission "$id" --answer "$answer_text" 2>&1)" || rrc=$?
  if [ "$rrc" -ne 0 ]; then
    escalate "$dir" verify \
      "every fix held, but \`lcars respond\` refused the accept — $(printf '%s' "$rout" | head -1)" \
      "$(printf '"stage": "verify", "reason": "respond-refused", "detail": %s' \
           "$(jstr "$(printf '%s' "$rout" | head -1)")")"
  fi

  # THE FOLD CAN REFUSE AFTER THE GATE IS CLEARED. `resolve-logs complete` never
  # blocks the answer: when it cannot fold (a straggler, a push that failed, no
  # branch) it RE-RAISES the parent's gate, recording `reverify-blocked`. That is
  # a fact about the mission, not a verdict to override — so if the gate is back,
  # it goes to the captain with the reason the fold gave, and nothing here claims
  # the fixes were accepted.
  if [ -f "$dir/pending.json" ] \
     && [ "$(pending_field "$dir/pending.json" kind)" = "reverify-blocked" ]; then
    escalate "$dir" verify \
      "every fix held, but LCARS could not fold them: $(pending_first_question "$dir/pending.json")" \
      "$(printf '"stage": "verify", "reason": "fold-blocked", "detail": %s' \
           "$(jstr "$(pending_first_question "$dir/pending.json")")")"
  fi

  # --- 7. THE RECORD --------------------------------------------------------
  local obj
  obj="$(state_xo_block "$st")"
  obj="$(obj_set "$obj" status "$(jstr finished)")"
  obj="$(obj_set "$obj" score2 "$(jstr "${score2:-unknown}")")"
  obj="$(obj_set "$obj" recheckedAt "$(jstr "$NOW")")"
  obj="$(obj_set "$obj" lastAction "$(jstr "re-checked $NOW_LOCAL")")"
  obj="$(obj_del "$obj" note)"
  state_set_xo "$st" "$obj"
  lcars_state_refusal_die "lcars xo recheck"

  journal "$dir" rescored \
    "$(printf '"score": %s, "held": %d, "detail": %s' \
         "$(jstr "${score2:-unknown}")" "$nheld" \
         "$(jstr "${summary2:-${why2:-every filed fix held}}")")"
  [ -n "$score2" ] && xo_label_score "$st" "$score2"
  xo_mirror "$id"

  printf '◈ NUMBER ONE: every fix held — I accepted the %d logged bug(s) on your behalf.\n' "$nheld"
  printf '  Intent match after the fixes: %s.\n' \
    "$(printf '%s' "${score2:-unknown}" | tr '[:lower:]' '[:upper:]')"
  printf '  The PR is yours. I do not merge.\n'
  xo_rm_work "$work"; XO_WORK_DIR=""
  return 0
}

# ===========================================================================
# REPORT — the First Officer's report, on the CLI (S205). ONE builder shared
# with the daemon's `GET /api/xo/report`: xo-report.py. Neither surface
# re-derives the since/history split — both call the same function, so a
# board and a terminal reading the same repo can never disagree (behaviour 6).
# ===========================================================================
XO_REPORT_SCRIPT="$SKILL_DIR/xo-report.py"

cmd_report() {
  local target="" show_all=0 mark=0 seen_mission=""
  local seen_entries=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)  show_all=1; shift ;;
      --seen) mark=1; shift ;;
      # S213: ✓ Seen on ONE entry, named by the key the report itself hands
      # out. Marking one thing dealt with is not the same act as saying "I
      # have read the whole report", so it is not the same flag.
      # S223 fix round 1 (D5): REPEATABLE — ✓ Seen all N names its N keys.
      --seen-entry)   [ -n "${2:-}" ] && seen_entries+=("$2"); shift 2 || true ;;
      --seen-entry=*) seen_entries+=("${1#--seen-entry=}"); shift ;;
      # S223: ✓ Seen all N — every entry of ONE mission still in the news.
      --seen-mission)   seen_mission="${2:-}"; shift 2 || true ;;
      --seen-mission=*) seen_mission="${1#--seen-mission=}"; shift ;;
      -*)     die "unknown option: $1" ;;
      *)      target="$1"; shift ;;
    esac
  done
  local mission_filter=""
  if [ -n "$target" ]; then
    mission_filter="$(resolve_mission "$target")" || exit $?
  fi
  local seen_file="$LCARS_DIR/xo-seen.json"
  local args=("$MISSIONS_DIR" "$seen_file" --format text)
  [ -n "$mission_filter" ] && args+=(--mission "$mission_filter")
  [ "$show_all" -eq 1 ] && args+=(--all)
  [ "$mark" -eq 1 ] && args+=(--mark-seen)
  local k
  for k in ${seen_entries[@]+"${seen_entries[@]}"}; do args+=(--seen-entry "$k"); done
  if [ -n "$seen_mission" ]; then
    seen_mission="$(resolve_mission "$seen_mission")" || exit $?
    args+=(--seen-mission "$seen_mission")
  fi
  "$XO_PY" "$XO_REPORT_SCRIPT" "${args[@]}"
}

case "${1:-status}" in
  on)     shift; cmd_on "$@" ;;
  off)    shift; cmd_off "$@" ;;
  status) shift; cmd_status ;;
  answer) shift; cmd_answer "$@" ;;
  evaluate) shift; cmd_evaluate "$@" ;;
  test-timeout)
    # NOT A CAPTAIN-FACING VERB. It prints the bound the look would use, so the
    # resolution (a measured suite-timing.json, else the env var) is provable
    # without running a suite.
    shift; xo_test_timeout ;;
  file-logs) shift; cmd_file_logs "$@" ;;
  recheck)   shift; cmd_recheck "$@" ;;
  report)    shift; cmd_report "$@" ;;
  seed)
    # NOT A CAPTAIN-FACING VERB. It exists so the seed step can be exercised
    # (and a project's own seed script tried) through the product's code path
    # rather than a copy of it in a test.
    shift
    _sm=""; _sw="$PWD"
    while [ $# -gt 0 ]; do
      case "$1" in
        --mission) _sm="${2:-}"; shift 2 || true ;;
        --in) _sw="${2:-}"; shift 2 || true ;;
        *) shift ;;
      esac
    done
    _sm="$(resolve_mission "$_sm")"
    mkdir -p "$MISSIONS_DIR/$_sm/xo"
    xo_seed "$MISSIONS_DIR/$_sm" "$MISSIONS_DIR/$_sm/xo" "$_sw" ;;
  unlisted)
    # NOT A CAPTAIN-FACING VERB, and deliberately absent from the usage block.
    # Same reason `seed` exists: the criteria-free pass can be driven over a
    # directory of pictures — a test's, or a look's own recording — through the
    # PRODUCT's code path rather than a copy of it beside the product. It is
    # also how this pass is proven against a look that already happened, at no
    # extra spend and with no second walk.
    shift
    _um=""; _ushots=""; _uout=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --mission) _um="${2:-}"; shift 2 || true ;;
        --shots)   _ushots="${2:-}"; shift 2 || true ;;
        --out)     _uout="${2:-}"; shift 2 || true ;;
        *) shift ;;
      esac
    done
    _um="$(resolve_mission "$_um")" || exit $?
    [ -n "$_ushots" ] || _ushots="$MISSIONS_DIR/$_um/xo/shots"
    [ -n "$_uout" ] || _uout="$MISSIONS_DIR/$_um/xo/unlisted.json"
    _ust="$MISSIONS_DIR/$_um/state.json"
    _uengine=""
    [ -n "${LCARS_WORKER_BIN:-}" ] || _uengine="$(xo_engine_for "$_ust")"
    xo_unlisted_pass "$_um" "$_ushots" "$_uout" "$_uengine" ;;
  claim)
    # NOT A CAPTAIN-FACING VERB, and deliberately absent from the usage block.
    # Same reason `seed`, `unlisted` and `record-pid` exist: it drives
    # `xo_claim_or_die` — the EXACT call `evaluate` and `answer` make — through
    # the product's own code path, so the mutual exclusion can be proven by
    # starting TWO REAL PROCESSES AT ONCE against one mission. A test that
    # calls the function twice in sequence proves nothing about a race: the
    # second call sees a finished first one.
    #
    # `--hold <secs>` keeps the claim for that long so the overlap is real.
    # It prints CLAIMED when it wins; a loser never reaches this printf,
    # because xo_claim_or_die dies.
    shift
    _cm=""; _ch=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --mission) _cm="${2:-}"; shift 2 || true ;;
        --hold)    _ch="${2:-0}"; shift 2 || true ;;
        *) shift ;;
      esac
    done
    _cm="$(resolve_mission "$_cm")" || exit $?
    trap xo_release_claim EXIT
    xo_claim_or_die "$MISSIONS_DIR/$_cm" "a look"
    printf 'CLAIMED %s by %s\n' "$_cm" "$$"
    [ "$_ch" -gt 0 ] 2>/dev/null && sleep "$_ch"
    exit 0 ;;
  detach)
    # NOT A CAPTAIN-FACING VERB, and deliberately absent from the usage block.
    # It drives `xo_spawn_detached` — the EXACT spawn `file_logs_for` makes —
    # so the process groups of a detached chain can be MEASURED through the
    # product's own code path instead of a copy of it in a test.
    shift
    _dpf=""; _dlog="/dev/null"
    while [ $# -gt 0 ]; do
      case "$1" in
        --pidfile) _dpf="${2:-}"; shift 2 || true ;;
        --log)     _dlog="${2:-/dev/null}"; shift 2 || true ;;
        --)        shift; break ;;
        *)         break ;;
      esac
    done
    [ -n "$_dpf" ] || die "detach needs --pidfile <path>."
    [ $# -gt 0 ]   || die "detach needs a command after --."
    xo_spawn_detached "$_dpf" "$_dlog" "$@" >/dev/null
    exit 0 ;;
  signal-pidfile)
    # NOT A CAPTAIN-FACING VERB. Same reason: it drives `xo_signal_pidfile`,
    # the one `lcars xo off` calls, so what a stop actually reaches is provable.
    # Exit status is the function's own: 0 signalled, 1 nothing there, 2 alive
    # but not who the file was written about (and so NOT signalled).
    shift
    [ -n "${1:-}" ] || die "signal-pidfile needs a pid file."
    xo_signal_pidfile "$1" "${2:-TERM}"
    exit $? ;;
  record-pid)
    # NOT A CAPTAIN-FACING VERB, and deliberately absent from the usage block.
    # It exists so a TEST can plant a pid file the way the product plants one,
    # through the product's own writer, instead of hand-rolling the format
    # beside it. A test that writes its own copy of a format drifts from the
    # format the moment the format changes, and then proves the old one.
    shift; xo_write_pidfile "$1" "$2" ;;
  -h|--help|help)
    # THE WHOLE USAGE BLOCK, NOT A COUNTED RANGE (fix round 2, D5). A hand-
    # counted `sed -n '3,18p'` truncated mid-sentence the moment a verb was
    # added — `recheck` was in the source and undiscoverable from the CLI, and
    # widening the range in fix round 1 only moved the cliff. The block runs from
    # line 3 to the blank comment line that ends it, and awk stops there, so the
    # next verb somebody adds prints itself.
    awk 'NR < 3 { next } NR > 4 && /^#$/ { exit } { sub(/^# ?/, ""); print }' "$SELF" ;;
  *)      die "unknown verb: $1 (want: on | off | status | answer | evaluate | file-logs | recheck | report)" ;;
esac
