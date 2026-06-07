#!/usr/bin/env bash
#
# worker-adapter.sh — the ONE place that knows how to drive a specific cold-worker
# CLI. run.sh (the stage driver) is CLI-agnostic: it knows a *role keyword* and a
# *cli id* (the basename of $LCARS_WORKER_BIN) and nothing about flag names or
# tool names. All of that lives here, keyed by cli. Today there is exactly one
# adapter — `claude` — a regression lock on the flags/tool-lists run.sh used to
# hardcode. A future `copilot` adapter slots in as another case with zero changes
# to run.sh: a `copilot` worker binary makes its basename "copilot" and routes
# here automatically.
#
# Two subcommands:
#
#   argv  <cli> <role> <outdir>
#       Print, ONE PER LINE, the exact argv FLAGS (never the prompt) the CLI needs
#       for that role. Deterministic and side-effect-free — this is the unit-test
#       surface. The FIRST line is the literal `-p` token: it is a PLACEHOLDER
#       marking "the prompt goes immediately after this flag". `spawn` injects the
#       prompt right after that `-p` so the resulting call is byte-for-byte the
#       call run.sh used to make inline. Keeping `-p` in `argv` (rather than the
#       prompt itself) is what lets `argv` stay purely about flags while still
#       pinning the prompt's POSITION.
#
#   spawn <cli> <role> <outdir> <prompt>
#       Build argv via `argv`, inject <prompt> after the leading `-p`, then run the
#       CLI one-shot capturing stdout→<outdir>/.worker.out and stderr→.worker.err,
#       with trailing `|| true` semantics (never fails the caller). The env handed
#       to the worker is LCARS_WORK_OUT=<outdir> and LCARS_WORKER_ROLE — the latter
#       defaults to <role> but is NOT overwritten if the caller already exported it
#       (the context-pack case: toolset-role repo-read for argv, but the worker must
#       still see LCARS_WORKER_ROLE=context-pack).
#
# `<role>` is the TOOLSET role — it selects the allowed-tools list:
#       repo-read      → Read,Grep,Glob,Write
#       repo-read-web  → Read,Grep,Glob,Write,WebSearch,WebFetch
#       repo-write     → Read,Grep,Glob,Write,Edit,Bash
#       default        → Read              (explicit sentinel for the old `*` case)
# An unknown <cli> or unknown <role> exits NON-ZERO with a message on stderr —
# never a silent empty argv / silent inline run.
#
# The cli binary to actually exec is taken from $LCARS_WORKER_BIN (so it matches
# run.sh's resolution and so tests can point it at a recording stub). It defaults
# to the cli id itself.
set -uo pipefail

die() { printf 'worker-adapter: %s\n' "$1" >&2; exit 1; }

# Map a TOOLSET role → that cli's allowed-tools list. Unknown role → non-zero.
# (This is the table that used to be worker_tools() in run.sh, now keyed by cli.)
adapter_tools() { # cli role → tool list (stdout); non-zero on unknown role
  local cli="$1" role="$2"
  case "$cli" in
    claude)
      case "$role" in
        repo-read)     printf 'Read,Grep,Glob,Write' ;;
        repo-read-web) printf 'Read,Grep,Glob,Write,WebSearch,WebFetch' ;;
        repo-write)    printf 'Read,Grep,Glob,Write,Edit,Bash' ;;
        default)       printf 'Read' ;;
        *) die "unknown worker role '$role' for cli '$cli'" ;;
      esac
      ;;
    *) die "unknown worker cli '$cli' — no adapter for this CLI" ;;
  esac
}

# Print the argv FLAGS (one per line) for <cli> <role>. Leading `-p` is the
# prompt-position placeholder (see header). The prompt itself is NOT emitted.
adapter_argv() { # cli role outdir
  local cli="$1" role="$2" tools
  tools="$(adapter_tools "$cli" "$role")" || exit 1
  case "$cli" in
    claude)
      printf '%s\n' '-p' '--allowedTools' "$tools" '--output-format' 'text'
      ;;
    *) die "unknown worker cli '$cli' — no adapter for this CLI" ;;
  esac
}

# Run the worker one-shot. Inject <prompt> after the leading `-p` so the call is
# byte-for-byte the old inline `"$BIN" -p "$prompt" --allowedTools <list> ...`.
adapter_spawn() { # cli role outdir prompt
  local cli="$1" role="$2" outdir="$3" prompt="$4"
  local bin="${LCARS_WORKER_BIN:-$cli}"
  # Read argv flags into an array.
  local flags=() line
  while IFS= read -r line; do flags+=("$line"); done < <(adapter_argv "$cli" "$role")
  # adapter_argv died (unknown cli/role) → no flags produced → refuse, non-zero.
  [ "${#flags[@]}" -gt 0 ] || die "no argv produced for cli '$cli' role '$role'"
  # The first flag MUST be the `-p` placeholder; inject the prompt right after it.
  [ "${flags[0]}" = "-p" ] || die "adapter argv for '$cli' did not start with -p"
  local rest=("${flags[@]:1}")
  mkdir -p "$outdir"
  LCARS_WORK_OUT="$outdir" LCARS_WORKER_ROLE="${LCARS_WORKER_ROLE:-$role}" \
    "$bin" -p "$prompt" "${rest[@]}" \
    >"$outdir/.worker.out" 2>"$outdir/.worker.err" || true
}

cmd="${1:-}"; shift || true
case "$cmd" in
  argv)
    [ "$#" -ge 3 ] || die "usage: worker-adapter.sh argv <cli> <role> <outdir>"
    adapter_argv "$1" "$2" "$3"
    ;;
  spawn)
    [ "$#" -ge 4 ] || die "usage: worker-adapter.sh spawn <cli> <role> <outdir> <prompt>"
    adapter_spawn "$1" "$2" "$3" "$4"
    ;;
  '') die "usage: worker-adapter.sh <argv|spawn> ..." ;;
  *) die "unknown subcommand '$cmd'" ;;
esac
