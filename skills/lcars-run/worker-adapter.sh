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
#       launch         → Read,Grep,Glob,Bash  (inspect + shell to DISCOVER how to
#                        run an app; NO Write/Edit — must not touch the checkout)
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
        launch)        printf 'Read,Grep,Glob,Bash' ;;
        default)       printf 'Read' ;;
        *) die "unknown worker role '$role' for cli '$cli'" ;;
      esac
      ;;
    copilot)
      # Copilot's registered tool names (verified live against copilot v1.0.60).
      # Role semantics mirror the claude column above:
      #   read   → view (read a file) + grep,glob (search) + create (NEW files only)
      #   web    → + web_fetch, web_search
      #   write  → + edit (mutate existing files) + bash (shell)
      # NB: a read role gets `create` but NOT `edit`/`bash`, so it can write its
      # answer artifact yet cannot overwrite/edit existing repo files — the repo
      # tree stays protected in read roles, mirroring claude's read fence.
      case "$role" in
        repo-read)     printf 'view,grep,glob,create' ;;
        repo-read-web) printf 'view,grep,glob,create,web_fetch,web_search' ;;
        repo-write)    printf 'view,grep,glob,create,edit,bash' ;;
        launch)        printf 'view,grep,glob,bash' ;;
        default)       printf 'view' ;;
        *) die "unknown worker role '$role' for cli '$cli'" ;;
      esac
      ;;
    *) die "unknown worker cli '$cli' — no adapter for this CLI" ;;
  esac
}

# Print the argv FLAGS (one per line) for <cli> <role>. Leading `-p` is the
# prompt-position placeholder (see header). The prompt itself is NOT emitted.
#
# Model selection is CLI-SPECIFIC, so it lives HERE, not in run.sh. The resolved
# model arrives via the env var $LCARS_WORKER_MODEL (run.sh's resolve_worker_model
# sets it). When it is EMPTY/UNSET the argv is byte-for-byte the session-18 lines
# — no `--model` flag at all — so an unmodelled run is unchanged. When non-empty
# the cli's model flag is APPENDED (claude: `--model <m>`), never reordered.
#
# INPUT READ-DIRS (session 76): a worker whose cwd is an ISOLATED git worktree
# (the Implement-stage Implementer) must still READ its ticket inputs — the
# failing tests, manifests, approved-plan.json, repo-map.md, context-pack.md —
# which live under .git/lcars/, OUTSIDE the worktree. The CLI-AGNOSTIC caller
# (run.sh) supplies those dirs via the env var $LCARS_WORKER_INPUT_DIRS, ONE
# absolute dir PER LINE (newline-separated; empty/unset ⇒ none). The PER-CLI
# translation lives HERE:
#   • copilot — emit one EXTRA `--add-dir <dir>` per input dir so copilot's hard
#               path sandbox grants READ of each. Appended AFTER the scratch
#               outdir grant; this only widens READ access — it never weakens
#               WRITE isolation (no --allow-all-paths), so the Implementer still
#               writes only inside its worktree + scratch.
#   • claude  — IGNORED: claude's `-p --allowedTools` spawn has no per-path
#               sandbox, so absolute input reads already work. Adding the dirs is
#               unnecessary, so its argv stays byte-for-byte unchanged.
# When the var is empty/unset the argv is byte-for-byte the pre-session-76 lines
# for BOTH CLIs, so research/validate/plan and every claude spawn are unchanged.
adapter_argv() { # cli role outdir
  local cli="$1" role="$2" outdir="${3:-}" tools model="${LCARS_WORKER_MODEL:-}"
  tools="$(adapter_tools "$cli" "$role")" || exit 1
  # Collect the caller-supplied INPUT read-dirs (one per line; blank lines skipped).
  local indirs=() iline
  while IFS= read -r iline; do
    [ -n "$iline" ] && indirs+=("$iline")
  done <<< "${LCARS_WORKER_INPUT_DIRS:-}"
  case "$cli" in
    claude)
      # claude has no per-path sandbox — input dirs are irrelevant; argv unchanged.
      # --dangerously-skip-permissions: a cold `-p` worker is already fenced by
      # --allowedTools and runs headless with NO human to approve interactive
      # permission prompts, so it must skip that gate (the claude equivalent of
      # the copilot branch's `--allow-all-tools --no-ask-user`). Without it, the
      # Implementer's writes into the mission's per-ticket worktree under `.git/`
      # are DECLINED (claude treats `.git/`-segment paths as protected) and the
      # ticket flags with everything read but nothing written.
      printf '%s\n' '-p' '--allowedTools' "$tools" '--output-format' 'text' \
        '--dangerously-skip-permissions'
      [ -n "$model" ] && printf '%s\n' '--model' "$model"
      # USAGE CAPTURE (session 112): pin the minted correlation session-id ONLY
      # when the caller enabled capture (LCARS_WORKER_SESSION_ID non-empty). Off ⇒
      # this line emits nothing, so the argv is byte-for-byte the pre-112 lines.
      [ -n "${LCARS_WORKER_SESSION_ID:-}" ] && printf '%s\n' '--session-id' "$LCARS_WORKER_SESSION_ID"
      ;;
    copilot)
      # Copilot cold-worker call (verified live against copilot v1.0.60):
      #   -p                       prompt-position placeholder (spawn injects it)
      #   -s                       silent; stdout is debug-only, not parsed
      #   --available-tools <list> the fenced surface (separate token, like claude)
      #   --allow-all-tools        run headless — SAFE: the surface is already fenced
      #   --no-ask-user            never block on an interactive prompt
      #   --disable-builtin-mcps   no ambient MCP servers in a cold worker
      #   --no-custom-instructions ignore user-global instruction files
      #   --add-dir <outdir>       the answer channel — worker writes its artifact here
      #   --model <m>              ONLY when LCARS_WORKER_MODEL is non-empty
      printf '%s\n' \
        '-p' \
        '-s' \
        '--available-tools' "$tools" \
        '--allow-all-tools' \
        '--no-ask-user' \
        '--disable-builtin-mcps' \
        '--no-custom-instructions' \
        '--add-dir' "$outdir"
      # READ grants for the ticket's out-of-worktree inputs (session 76). One
      # extra --add-dir per supplied dir; none supplied ⇒ exactly the old argv.
      local d
      for d in ${indirs[@]+"${indirs[@]}"}; do
        printf '%s\n' '--add-dir' "$d"
      done
      [ -n "$model" ] && printf '%s\n' '--model' "$model"
      # USAGE CAPTURE (session 112): pin the minted correlation session-id ONLY
      # when capture is enabled (see the claude branch); off ⇒ argv unchanged.
      [ -n "${LCARS_WORKER_SESSION_ID:-}" ] && printf '%s\n' '--session-id' "$LCARS_WORKER_SESSION_ID"
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
  while IFS= read -r line; do flags+=("$line"); done < <(adapter_argv "$cli" "$role" "$outdir")
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
