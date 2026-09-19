#!/usr/bin/env bash
#
# worker-guard.sh — THE ONE RULE for "may LCARS start this worker CLI?" (S217).
#
# THE HAZARD. VS Code ships its own `copilot` at
#   ~/Library/Application Support/Code/User/globalStorage/github.copilot-chat/copilotCli/copilot
# — a /bin/sh launcher for copilotCLIShim.js, and that shim re-invokes `copilot`
# BY NAME. With anything named `copilot` earlier on PATH the two call each other
# until the machine cannot fork (2026-09-14: a night lost; 2026-09-18: back
# again through a SYMLINK on a scratch PATH dir, after the first cure was one
# file). A cure in one file is a cure in one file. So every place LCARS starts a
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
# so a captain's variable prefix cannot reach it — the only true fix there is
# the daemon's PATH, which only a restart picks up. Words only: precedence is
# untouched.
lcars_worker_bin_daemon_hint() { printf 'restart the viewscreen'; }

# lcars_worker_bin_guard <bin> [<hint>] -> 0 when LCARS may start <bin>;
# otherwise ONE plain sentence on stderr — the path found and the fix — and 1.
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
# Engine-resolution precedence is untouched: this only chooses WORDS.
lcars_worker_bin_guard() {
  local bin="$1" hint="${2:-}" real dir lead tail=""
  real="$(lcars_worker_bin_resolve "$bin")" || return 0
  _lcars_worker_bin_is_shim "$real" || return 0
  dir="$(lcars_worker_bin_real_dir)"
  case "$bin" in
    */*) lead="give LCARS $dir/copilot in place of $bin wherever that path was set" ;;
    *)   lead="put $dir ahead of it on PATH so \`copilot\` finds the real CLI first" ;;
  esac
  if [ -n "$hint" ]; then
    case "$hint" in
      *[![:upper:][:digit:]_]*|[![:upper:]]*) tail=", then $hint" ;;
      *) tail=", or, when you run this from a terminal, prefix the command with $hint=$dir/copilot" ;;
    esac
  fi
  printf 'Refusing to start %s: it resolves to %s, which is VS Code'"'"'s own copilot shim, and that shim calls `copilot` back by name until the machine runs out of processes — %s%s.\n' \
    "$bin" "$real" "$lead" "$tail" >&2
  return 1
}
