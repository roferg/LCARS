#!/usr/bin/env bash
#
# worker-guard.sh — THE ONE RULE for "may LCARS start this worker CLI?" (S217).
#
# THE HAZARD. VS Code ships its own `copilot` at
#   ~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot
# — a /bin/sh launcher for copilotCLIShim.js, which re-invokes `copilot` BY NAME.
# It cost a night (2026-09-14) and came back through a SYMLINK on a scratch PATH
# dir (2026-09-18) after the first cure was one file.
#
# WHAT THE HAZARD ACTUALLY IS, MEASURED (S238). The runaway-fork story this file
# used to tell is NOT reproducible on shim 0.0.394: driven in the worst case
# anyone could build — no real copilot anywhere on PATH, brew/npm/curl/wget all
# stubbed to refuse — it returned in 0.1s with 1240 processes against a 1219
# baseline and no recursion at all, because copilotCLIShim.js strips its own
# `__dirname` out of the child's PATH before it spawns bare `copilot`. What it
# DOES do with no real CLI behind it is print an install prompt and, under the
# stdin=DEVNULL every LCARS spawn uses, exit 0 WITH NO MODEL OUTPUT. That is why
# refusing is still right, and it is worse than the crash it replaced: a silent
# garbage turn that every caller reads as success. The refusal sentence below
# says THAT, because a refusal whose stated mechanism nobody can reproduce is a
# refusal the next person disbelieves and switches off.
#
# A cure in one file is a cure in one file. So every place LCARS starts a
# worker goes through this function — worker-adapter.sh's one exec, run.sh's
# require_worker, init.sh's version probe — and the daemon carries the same rule
# in web/lcars_serve/worker_guard.py, held to it by tests/lcars-worker-guard.test.sh.
#
# THE RULE, AND WHY IT IS THIS NARROW. Resolve the binary exactly as the spawn
# would (PATH lookup for a bare name), follow EVERY symlink to the real file,
# then refuse when either RECORDED fact about VS Code's shim holds:
#   1. the real file lives in a `github.copilot-chat/copilotCli/` directory —
#      where VS Code puts it; or
#   2. it is a script (`#!`) carrying the shim's own marker, `copilotCLIShim` —
#      a copy of the launcher, or a wrapper that hard-codes it.
# It does NOT scan scripts for the word `copilot`. The committed test stubs
# mention it, one legitimately resolves and execs the real CLI, and a word-scan
# is guessing what a script will do from its prose — the infer-not-record class
# this project has lost whole rounds to. Only the script sniff reads content, and
# only the first 64 KB of a `#!` file, so a 200 MB native binary is never read.
#
# NOTHING HERE EVER EXECUTES THE BINARY. Resolution is `command -v`, `readlink`
# and `pwd -P`; the content check is `head`. A bin that is not on PATH at all is
# not this guard's to refuse — the spawn's own "not found" says that already.
#
# Sourced by lcars-common.sh (so every skill that sources it has the guard) and
# directly by worker-adapter.sh. Defines functions only; runs nothing.

# lcars_worker_bin_resolve <bin> -> the real file <bin> would run, every symlink
# followed (the file's own and any directory's). Non-zero when not found.
lcars_worker_bin_resolve() {
  local p="$1" l d n=0
  case "$p" in
    */*) ;;
    *) p="$(command -v -- "$p" 2>/dev/null)" || return 1
       case "$p" in */*) ;; *) return 1 ;; esac ;;   # a function/builtin, not a file
  esac
  [ -e "$p" ] || return 1
  while :; do
    d="$(cd "$(dirname -- "$p")" 2>/dev/null && pwd -P)" || return 1
    p="$d/$(basename -- "$p")"
    [ -L "$p" ] || break
    n=$((n + 1)); [ "$n" -le 40 ] || return 1                # a symlink loop
    l="$(readlink -- "$p")" || return 1
    case "$l" in /*) p="$l" ;; *) p="$d/$l" ;; esac
  done
  printf '%s' "$p"
}

# _lcars_worker_bin_is_shim <real> -> 0 when the RESOLVED file is VS Code's
# shim by either recorded fact above (its directory, or its own marker).
_lcars_worker_bin_is_shim() {
  case "$1" in
    */github.copilot-chat/copilotCli/*) return 0 ;;
  esac
  [ "$(head -c 2 -- "$1" 2>/dev/null)" = '#!' ] || return 1
  head -c 65536 -- "$1" 2>/dev/null | grep -q 'copilotCLIShim'
}

# lcars_worker_bin_fallback -> STDOUT the first REAL (non-shim) `copilot` at a
# known absolute location, or non-zero when none is there. RESOLUTION ONLY —
# lcars_worker_bin_resolve + _lcars_worker_bin_is_shim, the SAME two facts the
# guard already uses; this is not a second resolver and NOTHING is executed. The
# locations are where Homebrew (/opt/homebrew/bin) and a manual / Intel install
# (/usr/local/bin) put the CLI — the real binary a VS-Code/editor PATH, which
# often omits /opt/homebrew/bin, leaves unreachable by name. $LCARS_WORKER_BIN_
# FALLBACKS overrides the list (space-separated); set-but-EMPTY means "no
# fallback", so a test can pin it off and never touch the captain's real install.
lcars_worker_bin_fallback() {
  local c r cands
  cands="${LCARS_WORKER_BIN_FALLBACKS-/opt/homebrew/bin/copilot /usr/local/bin/copilot}"
  for c in $cands; do
    [ -n "$c" ] || continue
    r="$(lcars_worker_bin_resolve "$c")" || continue
    _lcars_worker_bin_is_shim "$r" && continue      # a location that IS a shim is no fallback
    printf '%s' "$c"; return 0
  done
  return 1
}

# lcars_worker_bin_real_dir -> the first PATH directory whose `copilot` is NOT
# the shim (resolution only, never run), or /opt/homebrew/bin when PATH holds
# none — the fix the refusal names is DERIVED, never guessed when it can be found.
lcars_worker_bin_real_dir() {
  local d c r dirs=()
  IFS=: read -r -a dirs <<<"${PATH:-}"
  for d in ${dirs[@]+"${dirs[@]}"}; do
    [ -n "$d" ] || continue
    [ "$d" != "/" ] && d="${d%/}"
    c="$d/copilot"
    [ -f "$c" ] && [ -x "$c" ] || continue
    r="$(lcars_worker_bin_resolve "$c")" || continue
    _lcars_worker_bin_is_shim "$r" && continue
    printf '%s' "$d"; return 0
  done
  printf '/opt/homebrew/bin'
}

# lcars_worker_bin_daemon_hint -> the daemon's call-site hint, byte-identical
# to web/lcars_serve/worker_guard.py's DAEMON_HINT (parity-tested). S218: a run
# the viewscreen started ($LCARS_VIEWSCREEN_CHILD=1, set on everything the
# daemon dispatches) is fed the mission's PERSISTED engine as $LCARS_WORKER_BIN,
# so a captain's $LCARS_WORKER_BIN prefix cannot reach it — the daemon's PATH
# only a restart picks up. Words only: precedence is untouched.
#
# S238 FIX ROUND 1 (D2) — IT NOW NAMES $LCARS_COPILOT_BIN TOO. Every daemon-side
# refusal used to end "…ahead of it on PATH … then restart the viewscreen" and
# NEVER mention the one variable S238 added for exactly this, so an operator who
# hit it had no way to discover it. $LCARS_COPILOT_BIN does reach a
# viewscreen-started run: the daemon replaces the picker's bare `copilot` with
# the file that variable names (worker_guard.explicit_override) BEFORE it hands
# the engine to run.sh. The restart stays as the last step because the daemon
# reads the variable at start-up. Both halves are true; the sentence is still one
# sentence. The composed shape — a variable name, then plain text — is handled by
# lcars_worker_bin_guard below.
lcars_worker_bin_daemon_hint() { printf 'LCARS_COPILOT_BIN restart the viewscreen'; }

# lcars_worker_bin_prefer_real <bin> -> the engine LCARS should RECORD for
# itself: <bin> unchanged, unless it resolves to the shim, in which case the
# real CLI's absolute path (the same one the refusal above names).
#
# WHY THIS EXISTS, AND WHY IT IS NOT THE GUARD (S222). `lcars file` wrote a
# mission's engine as a BARE NAME — `"workerBin": "copilot"` — and every later
# subprocess resolved that name through PATH, in an environment nobody
# controls. On any machine with the VS Code Copilot extension installed, that
# lookup IS the shim, so the guard refused it and the captain's mission died
# with "estimator unavailable". The guard was right; the NAME was wrong. A
# late-bound PATH lookup for a value LCARS chose and persisted itself is the
# same class as the engine-override money bug — the winner depends on which
# process reads it.
#
# IT NORMALISES ONLY WHAT LCARS WROTE FOR ITSELF: the engine persisted at
# filing time, and that engine when it is read back off a mission. An engine
# the OPERATOR named — an explicit $LCARS_WORKER_BIN, config.json, a daemon
# hand-off — is NEVER rewritten here, and the guard still refuses it with its
# own sentence, because the fix belongs in the place the person set it and
# silently curing it would hide that.
#
# Like everything else in this file it only RESOLVES: nothing is executed.
lcars_worker_bin_prefer_real() {
  local bin="${1:-}" real
  [ -n "$bin" ] || { printf ''; return 0; }
  real="$(lcars_worker_bin_resolve "$bin")" || { printf '%s' "$bin"; return 0; }
  if _lcars_worker_bin_is_shim "$real"; then
    printf '%s/copilot' "$(lcars_worker_bin_real_dir)"; return 0
  fi
  printf '%s' "$bin"
}

# lcars_worker_bin_guard <bin> [<hint>] -> 0 when LCARS may start <bin>;
# otherwise ONE plain sentence on stderr — the path found and the fix — and 1.
#
# THE FALLBACK, NOT A WEAKENING (S231). A BARE `copilot` that PATH-resolves to
# VS Code's shim is not yet doomed: a GUI/editor PATH commonly omits
# /opt/homebrew/bin, so the real CLI at a known absolute location was never even
# looked for. Before refusing such a bin, this looks there (lcars_worker_bin_
# fallback) and, when a real non-shim CLI is found, does NOT refuse — it prints
# that CLI on STDOUT for the caller to run in the shim's place and one plain
# sentence on stderr saying it worked around the shim and which binary it chose.
# The protection is intact: with no real CLI anywhere it refuses exactly as
# before, and a bin someone named by ABSOLUTE path is never rescued this way (it
# "wins and is still shim-checked") — its slash sends it straight to the refusal
# so the person fixes it where they set it. On the ordinary allow path (not a
# shim, or not found) it stays silent and emits nothing, exactly as before.
#
# THE FIX MUST BE TRUE WHERE IT IS SAID (S217 fix round 1, D2). Only the PATH
# fix cures every call site: init resolves copilot through $LCARS_COPILOT_BIN
# and PATH, the daemon's picker outranks $LCARS_WORKER_BIN, and LCARS's own
# re-pins (approve, Number One) override a captain's prefix. So the sentence
# LEADS with the PATH fix — or, for an ABSOLUTE bin that PATH order cannot
# change, "use the real path in its place" — and names a variable ONLY when the
# caller passes <hint> saying that variable wins at its call site:
#   <hint> = a variable name (e.g. LCARS_COPILOT_BIN) → "…, or, when you run
#            this from a terminal, prefix the command with VAR=<dir>/copilot"
#   <hint> = any other text (e.g. "restart the viewscreen") → "…, then <hint>"
#   <hint> = a variable name THEN plain text (the daemon's own hint, S238 fix
#            round 1 D2) → both, in that order: "…, or … prefix the command with
#            VAR=<dir>/copilot, then <text>". Still ONE sentence.
# Engine-resolution precedence is untouched: this only chooses WORDS.
lcars_worker_bin_guard() {
  local bin="$1" hint="${2:-}" real dir lead tail="" fb
  real="$(lcars_worker_bin_resolve "$bin")" || return 0
  _lcars_worker_bin_is_shim "$real" || return 0
  # A bare name that hit the shim: try a real CLI at a known absolute location
  # (never for an absolute/relative bin someone named — PATH order can't cure
  # that, so it must be refused where it was set). Resolution only; no run.
  case "$bin" in
    */*) : ;;
    *) if fb="$(lcars_worker_bin_fallback)"; then
         printf '%s' "$fb"
         printf 'Worked around VS Code'"'"'s copilot shim (%s): starting the real CLI at %s in its place.\n' \
           "$real" "$fb" >&2
         return 0
       fi ;;
  esac
  dir="$(lcars_worker_bin_real_dir)"
  case "$bin" in
    */*) lead="give LCARS $dir/copilot in place of $bin wherever that path was set" ;;
    *)   lead="put $dir ahead of it on PATH so \`copilot\` finds the real CLI first" ;;
  esac
  if [ -n "$hint" ]; then
    local hvar="${hint%% *}" hrest=""
    case "$hint" in *' '*) hrest="${hint#* }" ;; esac
    case "$hvar" in
      *[![:upper:][:digit:]_]*|[![:upper:]]*) tail=", then $hint" ;;
      *) tail=", or, when you run this from a terminal, prefix the command with $hvar=$dir/copilot"
         if [ -n "$hrest" ]; then tail="$tail, then $hrest"; fi ;;
    esac
  fi
  printf 'Refusing to start %s: it resolves to %s, which is VS Code'"'"'s own copilot shim, and with no real CLI behind it that shim prints an install prompt and exits 0 with no model output, so the turn looks like a success and is silently empty — %s%s.\n' \
    "$bin" "$real" "$lead" "$tail" >&2
  return 1
}
