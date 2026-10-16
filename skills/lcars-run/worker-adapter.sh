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
#       with trailing `|| true` semantics (never fails the caller) — but since
#       S218 the worker's exit status is RECORDED in <outdir>/.worker.rc, the
#       call in <outdir>/.worker.argv (prompt summarised as `<prompt N bytes>`,
#       never its text), and the argv builder's own warnings in .worker.warn
#       (also printed), so a caller can keep a failed attempt's record. The env handed
#       to the worker is LCARS_WORK_OUT=<outdir> and LCARS_WORKER_ROLE — the latter
#       defaults to <role> but is NOT overwritten if the caller already exported it
#       (the context-pack case: toolset-role repo-read for argv, but the worker must
#       still see LCARS_WORKER_ROLE=context-pack).
#
# `<role>` is the TOOLSET role — it selects the allowed-tools list:
#       repo-read      → Read,Grep,Glob,Write
#       repo-read-web  → Read,Grep,Glob,Write,WebSearch,WebFetch
#       repo-write     → Read,Grep,Glob,Write,Edit,Bash
#       launch         → Read,Grep,Glob,Write  (inspect to DISCOVER how to run an
#                        app, then AUTHOR its one discovery artifact; NO shell —
#                        S168 swapped the shell for a pen, see adapter_deny)
#       number-one     → Read,Grep,Glob,Write  (session 202 — the first officer
#                        READS the mission's whole record and AUTHORS exactly one
#                        file, xo-answer.json, in its own scratch dir. Same shape
#                        as `launch`, same reason: it reasons, `xo.sh` executes.
#                        This is the PAPER-GATE posture and it is unchanged: the
#                        modes that judge off the record alone — `answer`,
#                        `recheck` — have no disposable copy to run anything in.)
#       number-one-live → Read,Grep,Glob,Write,Bash  (S261 — the VERIFY LOOK.
#                        The same posture PLUS a real shell. Issued by
#                        run.sh's `spawn_number_one` ONLY when a disposable
#                        detached worktree is actually standing, and the worker's
#                        cwd is inside it; see that function and adapter_deny.)
#       default        → Read              (explicit sentinel for the old `*` case)
# An unknown <cli> or unknown <role> exits NON-ZERO with a message on stderr —
# never a silent empty argv / silent inline run. The SAME is true of the DENY
# table (`adapter_deny`): a role that has tools but no deny entry is a HARD
# ERROR, never a silent empty `--disallowedTools`.
#
# The cli binary to actually exec is taken from $LCARS_WORKER_BIN (so it matches
# run.sh's resolution and so tests can point it at a recording stub). It defaults
# to the cli id itself.
set -uo pipefail

die() { printf 'worker-adapter: %s\n' "$1" >&2; exit 1; }

# S217 — THE ONE WORKER-BIN GUARD (skills/lcars-init/worker-guard.sh): every
# cold worker is exec'd below, so this is where a `copilot` that resolves to VS
# Code's own re-invoking shim is refused, before anything is spawned. Missing
# guard = refuse to spawn, never spawn unguarded.
LCARS_WORKER_GUARD_LIB="${LCARS_WORKER_GUARD_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../lcars-init/worker-guard.sh}"
# shellcheck source=../lcars-init/worker-guard.sh
[ -f "$LCARS_WORKER_GUARD_LIB" ] && . "$LCARS_WORKER_GUARD_LIB"

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
        launch)        printf 'Read,Grep,Glob,Write' ;;
        number-one)    printf 'Read,Grep,Glob,Write' ;;
        number-one-live) printf 'Read,Grep,Glob,Write,Bash' ;;
        default)       printf 'Read' ;;
        *) die "unknown worker role '$role' for cli '$cli'" ;;
      esac
      ;;
    copilot)
      # Copilot's registered tool names. MEASURED LIVE on 2026-10-05 against
      # /opt/homebrew/bin/copilot, which self-reports 1.0.92 (it auto-updates in
      # place, so the Caskroom path can still read 1.0.89 — trust `--version`).
      #
      # HOW TO MEASURE THIS WITHOUT FOOLING YOURSELF, because the first attempt
      # at this comment did: on a dev machine `command -v copilot` can resolve to
      # VS Code's shim, which re-invokes `copilot` BACK OFF $PATH. Measured — the
      # shim landed in a fake that was first on $PATH. So call the real binary BY
      # ABSOLUTE PATH, and keep a counting fake first on $PATH that must stay at
      # zero. It stayed at zero for all four calls below.
      #
      # THE TOOL SET IS MODEL-DEPENDENT. That is the fact to carry forward, and it
      # is what makes this easy to get wrong: the SAME `--available-tools` list
      # resolves to a different surface depending on whether `--model` was sent.
      # Every other flag byte-identical to what adapter_spawn actually sends:
      #
      #   view,grep,glob,create  with NO --model
      #       → "Unable to create `nomodel.txt`: no file-writing tool is
      #          available", and NO FILE on disk.
      #   the same list  WITH --model claude-opus-4.8
      #       → "Created `withmodel.txt` containing `OK`. I used the **create**
      #          tool."
      #   view,grep  WITH a model
      #       → found the planted string: "I used the **grep** tool (ripgrep-based
      #          content search)".
      #   view,rg,glob,create  WITH a model
      #       → searched AND wrote, first try.
      #
      # So `create` EXISTS and `grep` EXISTS — on a model that offers them. There
      # is no missing tool here, and THERE WAS NO OUTAGE: separately, a tester drove
      # a real Research Stage on copilot twice and it worked first try both times,
      # writing its own artifacts.
      #
      # WHICH IS WHY S194's WRITE-TOOL FLOOR (run.sh) IS EXACTLY RIGHT, and the
      # measurement it was built on ("no --model → NO FILE") stands. The mechanism
      # is the MISSING MODEL, not a renamed tool. adapter_argv below sends
      # `--model` only when one is configured, and the floor is what configures
      # it: `run.sh resolve-stage-model numberOne` on copilot prints
      # claude-opus-4.8. Do not read this comment as a reason to touch that floor.
      #
      # `rg` BELOW IS COSMETIC. It is the modern name for the search tool, and
      # both names resolve to the same thing (measured above, each on its own
      # call), so no role gains or loses a capability by the rename.
      #
      # NOT MEASURED HERE, so not claimed: the full set of names copilot registers,
      # and how it behaves for any model other than claude-opus-4.8 and the
      # default. If you need either, measure it the way described above.
      #
      # `number-one-live` IS THE SAME ROLE WITH A SHELL (S261). On copilot
      # `--available-tools` IS the restriction, so adding `bash` is the whole
      # grant and there is no deny list to amend. No write tool is added with
      # it: the verdict still arrives through the frame, and a shell can write
      # anyway, so `create` would buy nothing and widen the list for nothing.
      #
      # `number-one` ASKS FOR NO WRITE TOOL AT ALL (S250) — and that is a design
      # choice, not a workaround. The role's whole output is one file, and a
      # reviewer that needs no write capability does not depend on the floor
      # holding at all. It says its verdict in its reply, between delimiters it is
      # asked for by name, and the HARNESS writes the file (run.sh
      # `number_one_claim_output` + number-one-channel.py). The other read roles
      # keep `create`, and `create` works.
      #
      # Role semantics mirror the claude column above:
      #   read   → view (read a file) + rg,glob (search) + create (NEW files only)
      #   web    → + web_fetch, web_search
      #   write  → + edit (mutate existing files) + bash (shell)
      # NB: a read role gets `create` but NOT `edit`/`bash`, so it can write its
      # answer artifact yet cannot overwrite/edit existing repo files — the repo
      # tree stays protected in read roles, mirroring claude's read fence.
      case "$role" in
        repo-read)     printf 'view,rg,glob,create' ;;
        repo-read-web) printf 'view,rg,glob,create,web_fetch,web_search' ;;
        repo-write)    printf 'view,rg,glob,create,edit,bash' ;;
        launch)        printf 'view,rg,glob,create' ;;
        number-one)    printf 'view,rg,glob' ;;
        number-one-live) printf 'view,rg,glob,bash' ;;
        default)       printf 'view' ;;
        *) die "unknown worker role '$role' for cli '$cli'" ;;
      esac
      ;;
    *) die "unknown worker cli '$cli' — no adapter for this CLI" ;;
  esac
}

# Map a TOOLSET role → that cli's DENY list (S168). CLAUDE ONLY: `--allowedTools`
# is a PRE-APPROVAL list, not a restriction, and `--dangerously-skip-permissions`
# waives whatever is left to ask about — MEASURED at S124: `--allowedTools
# Read,Grep,Glob --dangerously-skip-permissions` still CREATED A FILE. The flag
# that actually REFUSES is `--disallowedTools`, and its refusal survives the
# worker delegating to a subagent. So every claude posture carries BOTH lists:
# the allow list says what it may reach for, the deny list is the part that stops
# it. copilot has no such flag and needs none — its `--available-tools` IS a
# restriction (the engine's own preamble lists everything else as *Disabled*).
#
# Each entry is the COMPLEMENT of what the role above is documented to hold:
#   repo-read      keeps Write — the answer artifact IS its whole output — and
#                  loses editing, the shell, notebooks and the network.
#   repo-read-web  the same, minus the network denial (it is a research role).
#   repo-write     ⚠ HONESTY NOTE — READ THIS BEFORE TRUSTING THIS ROW. repo-write
#                  holds `Bash`. A role with a shell has EVERY capability: it can
#                  write, edit, fetch and run anything, so NO tool list can fence
#                  it and this row is NOT a fence. `NotebookEdit` is denied only
#                  because nothing in LCARS is a notebook; the entry exists so the
#                  table has no silent hole, not because it contains anything.
#                  repo-write's containment is ELSEWHERE and it is real: the
#                  isolated per-ticket worktree, the declared-edits contract, the
#                  post-commit scope check and the flip-flop gate. Do not read
#                  this row as a promise those four do not make.
#   launch         S168 SWAPPED ITS SHELL FOR A PEN. It used to hold Bash and no
#                  Write, so it authored launch-discovery.json through a SHELL
#                  inside a checkout of the captain's code while its own prompt
#                  said "do NOT modify any file in the checkout — inspection
#                  only". It now holds Write (it can author its one artifact) and
#                  has no general-purpose execution channel at all. The checkout
#                  is additionally CHECKED clean after the turn (launch.sh), so
#                  "inspection only" is verified instead of trusted.
#   number-one     S202. The `launch` posture with the NETWORK taken away as well.
#                  Number One's whole job is to decide from THE RECORD — the PRD,
#                  the ADRs, the plan, the answers already given — and the failure
#                  mode the research warned about is a judge that reasons its way
#                  past the record. A worker that can fetch is a worker that can
#                  ground a verdict in something the mission never said, so it
#                  gets no fetch. It keeps Write because xo-answer.json IS its
#                  entire output, and it is denied Bash EXPLICITLY: on claude the
#                  allow list only pre-approves, so this row is the only thing
#                  that actually takes the shell away.
#   number-one-live ⚠ HONESTY NOTE, THE SAME ONE repo-write CARRIES. This row
#                  KEEPS A SHELL, so it is NOT a fence: a role with `Bash` can
#                  write, edit and run anything, and no tool list can hold it.
#                  `WebSearch`/`WebFetch` stay denied for the S202 reason (a
#                  reviewer that can fetch can ground a verdict in something the
#                  mission never said) and that denial is real only in the sense
#                  that the tool is refused — a shell with network is a shell
#                  with network, and this row does not pretend otherwise.
#                  `Edit`/`NotebookEdit` stay denied so the table has no silent
#                  hole, not because they contain anything.
#
#                  WHERE ITS CONTAINMENT ACTUALLY IS, and it is real:
#                    1. THE DISPOSABLE COPY. `spawn_number_one` runs this worker
#                       with its cwd inside a DETACHED worktree minted by the
#                       EEH's one helper (`ech.sh worktree`, via
#                       `xo-run.py prepare`). Anything it breaks dies with the
#                       copy, and the copy is detached, so nothing it commits
#                       can reach a branch.
#                    2. THE POST-TURN FENCE AUDIT (`worker_fence_check` in
#                       run.sh) still covers this role — a worker that writes
#                       judge-critical mission state is KILLED, never repaired.
#                    3. THE ROLE IS NOT ISSUED WITHOUT (1). With no copy
#                       standing, `spawn_number_one` hands the adapter plain
#                       `number-one` and the S168 posture applies unchanged.
#                  WHY THE SHELL IS HERE AT ALL (captain's approval, 2026-10-08
#                  19:33 MDT): measured on 2026-10-08, the reviewer found 0 real
#                  defects where the captain's EEH found 4, and three of its
#                  six recorded failures were this fence — drawn parts it could
#                  not reach, a HOME store read refused, a shell action refused.
#   default        the read-only sentinel: everything but Read/Grep/Glob is gone.
#
# An unknown cli or role exits NON-ZERO, exactly like adapter_tools — and a
# claude role with tools but NO deny entry is a HARD ERROR at the call site in
# adapter_argv, never a silent empty `--disallowedTools`.
adapter_deny() { # cli role → deny list (stdout); non-zero on unknown cli/role
  local cli="$1" role="$2"
  case "$cli" in
    claude)
      case "$role" in
        repo-read)     printf 'Edit,Bash,NotebookEdit,WebSearch,WebFetch' ;;
        repo-read-web) printf 'Edit,Bash,NotebookEdit' ;;
        repo-write)    printf 'NotebookEdit' ;;
        launch)        printf 'Edit,Bash,NotebookEdit' ;;
        number-one)    printf 'Edit,Bash,NotebookEdit,WebSearch,WebFetch' ;;
        number-one-live) printf 'Edit,NotebookEdit,WebSearch,WebFetch' ;;
        default)       printf 'Write,Edit,Bash,NotebookEdit,WebSearch,WebFetch' ;;
        *) die "unknown worker role '$role' for cli '$cli'" ;;
      esac
      ;;
    copilot)
      # copilot has NO --disallowedTools: `--available-tools` already refuses
      # everything it does not name, so the deny list is legitimately EMPTY here
      # and no flag is emitted. The role is still VALIDATED so an unknown role
      # exits non-zero from BOTH tables, never just one.
      case "$role" in
        repo-read|repo-read-web|repo-write|launch|number-one|number-one-live|default) : ;;
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
      #
      # WHAT THESE THREE FLAGS ACTUALLY DELIVER (measured, S124 — the sentence
      # that used to stand here claimed a guarantee they do not deliver):
      #   --allowedTools               PRE-APPROVES. It does not restrict. A role
      #                                whose list omits Write can still write.
      #   --dangerously-skip-permissions
      #                                waives whatever is left to ask about. It
      #                                is LOAD-BEARING and stays: a headless `-p`
      #                                worker has no human to approve prompts, and
      #                                without it the Implementer's writes into
      #                                its per-ticket worktree under `.git/` are
      #                                DECLINED and the ticket flags with
      #                                everything read and nothing written.
      #   --disallowedTools            the ONLY one of the three that REFUSES —
      #                                and its refusal survives the worker
      #                                delegating to a subagent. This is the fence.
      # So the cure for the skip flag is to ADD the deny list beside it, never to
      # remove the skip.
      local deny
      deny="$(adapter_deny "$cli" "$role")" || exit 1
      # A role with tools but NO deny entry is a HARD ERROR — a silent empty
      # `--disallowedTools` would ship a role unfenced while LOOKING fenced.
      [ -n "$deny" ] || die "no deny list for cli '$cli' role '$role' — refusing to spawn an unfenced worker"
      printf '%s\n' '-p' '--allowedTools' "$tools" '--disallowedTools' "$deny" \
        '--output-format' 'text' '--dangerously-skip-permissions'
      [ -n "$model" ] && printf '%s\n' '--model' "$model"
      # USAGE CAPTURE (session 112): pin the minted correlation session-id ONLY
      # when the caller enabled capture (LCARS_WORKER_SESSION_ID non-empty). Off ⇒
      # this line emits nothing, so the argv is byte-for-byte the pre-112 lines.
      [ -n "${LCARS_WORKER_SESSION_ID:-}" ] && printf '%s\n' '--session-id' "$LCARS_WORKER_SESSION_ID"
      ;;
    copilot)
      # Copilot cold-worker call (the FLAGS were verified live against copilot
      # v1.0.60; every flag on this line still worked on 1.0.92 in the 2026-10-05
      # measurements. The TOOL NAMES are a separate claim, dated in adapter_tools
      # above, together with the model-dependence that makes them worth dating):
      #   -p                       prompt-position placeholder (spawn injects it)
      #   -s                       silent; stdout is debug-only, not parsed
      #   --available-tools <list> the fenced surface (separate token, like claude)
      #   --allow-all-tools        run headless — SAFE: the surface is already fenced
      #   --no-ask-user            never block on an interactive prompt
      #   --disable-builtin-mcps   no ambient MCP servers in a cold worker
      #   --no-custom-instructions ignore user-global instruction files
      #   --add-dir <outdir>       the answer channel — worker writes its artifact here
      #   --model <m>              ONLY when LCARS_WORKER_MODEL is non-empty
      # NO --disallowedTools: copilot has no such flag and needs none. The role is
      # still run through adapter_deny so an unknown role exits non-zero from BOTH
      # tables; it emits nothing, so this argv stays BYTE-FOR-BYTE pre-S168.
      adapter_deny "$cli" "$role" >/dev/null || exit 1
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
      #
      # S213 — `--add-dir` TAKES A DIRECTORY AND NOTHING ELSE. copilot 1.0.86
      # validates this flag before the model runs and exits at argv-parse on any
      # path that is not an existing directory ("Not a directory: …"). There is
      # no degraded mode: the worker never starts, writes no artifact, and the
      # Stage reports a downstream symptom ("produced no questions.txt after 3
      # attempts") that names neither the flag nor the path. That cost a whole
      # drive. (This flag WAS file-tolerant on copilot v1.0.60, which the argv
      # comment above was verified against — a version-drift regression, and
      # invisible on claude, which ignores input dirs entirely.)
      #
      # So the adapter — the one layer that knows a CLI's flag contract — never
      # emits an argv the CLI cannot parse. A non-directory grant is DROPPED and
      # SAID OUT LOUD on stderr, naming the path: the worker loses reach it was
      # meant to have, and a silent loss of reach is the failure we are least
      # able to see. The callers in run.sh grant directories, so on a healthy
      # repo this never fires and the argv is byte-for-byte unchanged.
      local d
      for d in ${indirs[@]+"${indirs[@]}"}; do
        if [ ! -d "$d" ]; then
          printf 'worker-adapter: NOT granting %s to the %s worker — --add-dir takes a directory and this is not one. The worker will not be able to read it.\n' \
            "$d" "$cli" >&2
          continue
        fi
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
  # S218 — the argv builder's own warnings (e.g. "NOT granting <file> …") are
  # KEPT in $outdir/.worker.warn as well as printed, so a caller that keeps a
  # failed attempt's record keeps them too instead of losing them to a stream
  # nobody captured.
  mkdir -p "$outdir"
  local warn="$outdir/.worker.warn"
  while IFS= read -r line; do flags+=("$line"); done < <(adapter_argv "$cli" "$role" "$outdir" 2>"$warn")
  if [ -s "$warn" ]; then cat "$warn" >&2; else rm -f "$warn"; fi
  # adapter_argv died (unknown cli/role) → no flags produced → refuse, non-zero.
  [ "${#flags[@]}" -gt 0 ] || die "no argv produced for cli '$cli' role '$role'"
  # The first flag MUST be the `-p` placeholder; inject the prompt right after it.
  [ "${flags[0]}" = "-p" ] || die "adapter argv for '$cli' did not start with -p"
  # S168 — REFUSE an unfenced claude spawn, at the ONE place every cold worker
  # passes through. Promoted from the holodeck's `_assert_no_bash` (web/
  # lcars_serve/actions.py), including its keying: off the ENGINE (copilot is
  # exempt because `--available-tools` IS a restriction there and the CLI has no
  # `--disallowedTools` to carry), NEVER off the presence of `--allowedTools`.
  # Keyed off that flag instead, a later session dropping `--allowedTools` from
  # the claude argv for an unrelated reason would retire the requirement
  # SILENTLY — the guard would stop guarding with nobody editing it.
  # What this cannot prove: that the CLI honours the flag. That was measured by
  # hand (S124); no argv check can see it.
  case "$cli" in
    copilot) : ;;
    *)
      local f seen_deny=0
      for f in "${flags[@]}"; do
        [ "$f" = "--disallowedTools" ] && seen_deny=1
      done
      [ "$seen_deny" -eq 1 ] || die "refusing to spawn a '$cli' worker whose argv carries no --disallowedTools — on claude \`--allowedTools\` only PRE-APPROVES and \`--dangerously-skip-permissions\` waives the rest, so the deny list is the only thing that actually takes a tool away"
      ;;
  esac
  command -v lcars_worker_bin_guard >/dev/null 2>&1 \
    || die "refusing to spawn: the worker guard ($LCARS_WORKER_GUARD_LIB) is missing, so nothing can check that '$bin' is not VS Code's copilot shim"
  # bin IS ${LCARS_WORKER_BIN:-$cli}, so that variable wins here — unless LCARS
  # set it itself (_INTERNAL=1), where a captain's prefix is overridden
  # upstream; then only the PATH fix is offered (fix round 1, D2).
  local guard_hint=""
  [ "${LCARS_WORKER_BIN_INTERNAL:-}" != "1" ] && guard_hint=LCARS_WORKER_BIN
  # S218 — started by the viewscreen: its persisted engine wins, so the fix is
  # the daemon's PATH + a restart, never a variable (lcars_worker_bin_daemon_hint).
  [ "${LCARS_VIEWSCREEN_CHILD:-}" = "1" ] && guard_hint="$(lcars_worker_bin_daemon_hint)"
  # S231 — the guard may hand back a REAL CLI to run in the shim's place (a bare
  # `copilot` that PATH-resolved to VS Code's shim, cured from a known absolute
  # location). Adopt it; empty stdout means "use $bin unchanged". A refusal is
  # rc≠0 with its sentence already on stderr.
  local guard_eff
  guard_eff="$(lcars_worker_bin_guard "$bin" "$guard_hint")" || exit 1
  [ -n "$guard_eff" ] && bin="$guard_eff"
  local rest=("${flags[@]:1}")
  # S218 — RECORD WHAT RAN AND HOW IT ENDED. The exit status used to be thrown
  # away here, so a worker that died at argv-parse (S214: copilot refusing a
  # FILE as --add-dir, rc=1, 6/6) left nothing but "produced no questions.txt".
  # .worker.argv is the call with the PROMPT SUMMARISED — never its text: the
  # prompt carries the captain's PRD, and nothing else in this argv is a secret
  # (flags, tool names, paths, a model id, a correlation id). .worker.rc is the
  # worker's own status. The spawn itself still never fails its caller — each
  # Stage decides what a failed attempt means.
  {
    printf '%q -p %s' "$bin" "<prompt $(printf '%s' "$prompt" | wc -c | tr -d ' ') bytes>"
    local a; for a in ${rest[@]+"${rest[@]}"}; do
      case "$a" in
        ''|*[!A-Za-z0-9_./:=,@+%-]*) printf ' %q' "$a" ;;   # quote only what needs it
        *) printf ' %s' "$a" ;;
      esac
    done
    printf '\n'
  } >"$outdir/.worker.argv"
  local wrc=0
  LCARS_WORK_OUT="$outdir" LCARS_WORKER_ROLE="${LCARS_WORKER_ROLE:-$role}" \
    "$bin" -p "$prompt" "${rest[@]}" \
    >"$outdir/.worker.out" 2>"$outdir/.worker.err" || wrc=$?
  printf '%s\n' "$wrc" >"$outdir/.worker.rc"
  return 0
}

cmd="${1:-}"; shift || true
case "$cmd" in
  argv)
    [ "$#" -ge 3 ] || die "usage: worker-adapter.sh argv <cli> <role> <outdir>"
    adapter_argv "$1" "$2" "$3"
    ;;
  deny)
    [ "$#" -ge 2 ] || die "usage: worker-adapter.sh deny <cli> <role>"
    adapter_deny "$1" "$2"
    ;;
  spawn)
    [ "$#" -ge 4 ] || die "usage: worker-adapter.sh spawn <cli> <role> <outdir> <prompt>"
    adapter_spawn "$1" "$2" "$3" "$4"
    ;;
  '') die "usage: worker-adapter.sh <argv|spawn> ..." ;;
  *) die "unknown subcommand '$cmd'" ;;
esac
