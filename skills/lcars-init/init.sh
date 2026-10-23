#!/usr/bin/env bash
#
# lcars init — prepare a repo to run LCARS.
#
# Idempotent. Does three things:
#   LOCAL   create .git/lcars/{config.json,missions/}, detect CONTEXT.md,
#           verify the Claude CLI is available.
#   GITHUB  create the LCARS label set on the current repo, skipping any
#           that already exist.
#   OUTPUT  print a readiness summary.
#
# Dependencies are taken via env so they can be stubbed in tests:
#   LCARS_CLAUDE_BIN  the claude binary (default: claude)
#   LCARS_COPILOT_BIN the copilot binary (default: copilot) — S207: init accepts
#                     EITHER engine, and both seams are lcars-common.sh's
#   LCARS_GH_BIN      the gh binary     (default: gh)
#
set -uo pipefail

die() { printf 'lcars init: %s\n' "$1" >&2; exit 1; }

# --- args -----------------------------------------------------------------
USAGE='usage: lcars init [--help|-h] [--dry-run]'
DRY_RUN=0
HELP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) HELP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -*) die "unknown option \"$1\" — $USAGE" ;;
    *) die "unexpected argument \"$1\" — $USAGE" ;;
  esac
done
if [ "$HELP" -eq 1 ]; then
  printf '%s\n' "$USAGE"
  exit 0
fi

# Kept as the named default for the header above; the engine actually verified
# (and the bin actually run) is resolved below through lcars-common.sh's shared
# detector, which reads this same $LCARS_CLAUDE_BIN seam.
CLAUDE_BIN="${LCARS_CLAUDE_BIN:-claude}"
GH_BIN="${LCARS_GH_BIN:-gh}"
DEFAULT_MODEL="${LCARS_MODEL:-claude-sonnet}"

# Shared label set + merge-preserving config writer (also used by `lcars update`).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lcars-common.sh"

# --- the running LCARS version (stamped into the repo's config) ------------
# `lcars_running_version` is lcars-common.sh's (sourced above) — S207 moved the
# byte-identical copies init and update each carried into the one place all
# three stampers read, because `lcars adopt` now seeds the stamp too.
RUNNING_VERSION="$(lcars_running_version)"

# --- locate the repo ------------------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
# Resolve GIT_DIR to an absolute path.
case "$GIT_DIR" in
  /*) : ;;
  *)  GIT_DIR="$PWD/$GIT_DIR" ;;
esac

LCARS_DIR="$GIT_DIR/lcars"
MISSIONS_DIR="$LCARS_DIR/missions"
CONFIG="$LCARS_DIR/config.json"

# --- verify a WORKER ENGINE ----------------------------------------------
# S195 — through the SHARED detector (lcars-common.sh `lcars_engine_available`),
# which is this exact `command -v "${LCARS_CLAUDE_BIN:-claude}"` check, named.
# Same binary, same env seam, same message: what changes is that the front
# door's engine picker and this check can no longer answer "is claude installed"
# differently.
#
# S207, captain's ruling 2026-09-11 — THE FRONT DOOR REQUIRES AT LEAST ONE
# ENGINE, NOT CLAUDE SPECIFICALLY. LCARS has driven missions on Copilot since
# S195, and every OTHER surface (the File console's picker, `lcars xo`, the
# board) already offers both; only init still died on a laptop that has copilot
# and not claude — refusing to set up a repo LCARS could then drive perfectly.
# `lcars_default_engine` is the S195 picker itself, so this is the same answer
# those surfaces give, in the same precedence: the repo's own pin (when it is
# installed) > the single installed engine > claude. With BOTH installed the
# answer is claude and nothing about init changes. With NEITHER it is empty,
# and THAT is the fatal case — named for both engines, since either one cures it.
ENGINE_CHOSEN="$(lcars_default_engine "$CONFIG")"
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$ENGINE_CHOSEN" ]; then
    die "no worker CLI found — LCARS drives missions with Claude Code (looked for '$(lcars_engine_bin claude)') or the GitHub Copilot CLI (looked for '$(lcars_engine_bin copilot)'). Install either one and re-run: https://claude.com/claude-code"
  fi
  ENGINE_BIN="$(lcars_engine_bin "$ENGINE_CHOSEN")"
  # Read the version of the engine we ACTUALLY picked. `$CLAUDE_BIN --version` is
  # never run when claude is absent — that shell-out was the second half of the
  # defect (it printed a resolution error into the readout).
  # S217 — and never run it at all if it is VS Code's re-invoking copilot shim
  # (lcars_worker_bin_guard, the one rule every worker start goes through).
  # The fix it names must be true HERE (fix round 1, D2): init resolves the bin
  # through LCARS_<ENGINE>_BIN / PATH — $LCARS_WORKER_BIN plays no part — so that
  # is the only variable it may offer.
  case "$ENGINE_CHOSEN" in
    copilot) GUARD_HINT=LCARS_COPILOT_BIN ;;
    claude)  GUARD_HINT=LCARS_CLAUDE_BIN ;;
    *)       GUARD_HINT="" ;;
  esac
  GUARD_ERR="$(mktemp "${TMPDIR:-/tmp}/lcars-init-guard.XXXXXX")"
  if GUARD_EFF="$(lcars_worker_bin_guard "$ENGINE_BIN" "$GUARD_HINT" 2>"$GUARD_ERR")"; then
    [ -s "$GUARD_ERR" ] && cat "$GUARD_ERR" >&2       # S231 — surface the fallback notice
    [ -n "$GUARD_EFF" ] && ENGINE_BIN="$GUARD_EFF"    # …and run the real CLI it chose
    rm -f "$GUARD_ERR"
  else
    GUARD_MSG="$(cat "$GUARD_ERR")"; rm -f "$GUARD_ERR"; die "$GUARD_MSG"
  fi
  ENGINE_VERSION="$("$ENGINE_BIN" --version 2>/dev/null | head -1)"
  # The fallback is ANNOUNCED, never silent: a captain whose laptop has no claude
  # must be told which engine his repo was set up on, at the moment it happens.
  ENGINE_FALLBACK_NOTE=""
  if [ "$ENGINE_CHOSEN" != "claude" ] && ! lcars_engine_available claude; then
    ENGINE_FALLBACK_NOTE="claude not found — using $ENGINE_CHOSEN"
  fi
fi

# --- S182: seed the first commit on an UNBORN HEAD ------------------------
# LCARS proves every ticket against its PARENT COMMIT — the ticket's tests must
# be RED on the parent and GREEN on the tip. A repo with no commits has no
# parent, so Implement used to die on it mid-ticket: one `git commit` standing
# between the captain and a working mission, discovered at the worst possible
# moment (after the Mission was filed, researched, planned and scheduled).
# Seed it HERE, at setup, where it costs nothing and can be announced.
#
# NON-DESTRUCTIVE BY CONSTRUCTION. This uses plumbing (empty tree → commit-tree
# → update-ref) rather than `git commit --allow-empty`, because on an unborn
# HEAD a captain may already have files STAGED and `git commit` would sweep them
# into a commit LCARS invented. The plumbing path never reads or writes the
# index or the working tree: the seeded commit is empty, and whatever the
# captain had staged is still staged afterwards.
#
# Idempotent: a repo that already has a HEAD is not touched at all.
SEEDED_INITIAL_COMMIT=0
if [ "$DRY_RUN" -eq 0 ] && ! git -C "$TOPLEVEL" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  SEED_TREE="$(git -C "$TOPLEVEL" hash-object -w -t tree /dev/null 2>/dev/null)"
  SEED_COMMIT=""
  [ -n "$SEED_TREE" ] && SEED_COMMIT="$(git -C "$TOPLEVEL" commit-tree "$SEED_TREE" \
      -m "initial commit (seeded by lcars init)" 2>/dev/null)"
  if [ -n "$SEED_COMMIT" ] && git -C "$TOPLEVEL" update-ref HEAD "$SEED_COMMIT" 2>/dev/null; then
    SEEDED_INITIAL_COMMIT=1
  else
    SEEDED_INITIAL_COMMIT=2   # usually a missing user.name / user.email
  fi
fi

# --- LOCAL: scaffold .git/lcars/ -----------------------------------------
[ "$DRY_RUN" -eq 1 ] || mkdir -p "$MISSIONS_DIR"

# --- detect CONTEXT.md ----------------------------------------------------
if [ -f "$TOPLEVEL/CONTEXT.md" ]; then
  CONTEXT_VALUE='"CONTEXT.md"'
  CONTEXT_HUMAN="CONTEXT.md"
else
  CONTEXT_VALUE='null'
  CONTEXT_HUMAN="none"
fi

PROJECT_NAME="$(basename "$TOPLEVEL")"

# --- detect the repo's test command --------------------------------------
# The Implement red gate (BUG-007) runs this to prove the Test Writer's suite
# FAILS before the Implementer runs — but it must evaluate the QUARANTINED tests,
# not the repo's existing suite. So the gate exports $LCARS_TESTS_DIR pointing at
# the quarantined dir and the testCommand MUST honour it (scope itself to that
# dir). We therefore emit a $LCARS_TESTS_DIR-honouring default per ecosystem:
# when the var is set the runner runs ONLY that dir; unset (a human running it by
# hand) it falls back to the whole suite. The captain can override it in
# config.json or per-run via $LCARS_TEST_CMD. Null when nothing is detected — the
# red gate then warns and skips (the pre-existing degradation), it does not block.
# S146: VITEST_RELATIVIZING_CMD, detect_workspace_runner and detect_test_cmd
# MOVED to lcars-common.sh (sourced above) so the shared test-readiness verdict
# — computed by init, update, status AND the viewscreen daemon — consults the
# SAME detector this seeding path uses. Behaviour is byte-identical.

# runner_is_local_dep — 0 if the test command's runner resolves ONLY from a
# project-local location (node_modules/.bin or a venv) rather than a binary
# guaranteed on PATH. vitest/jest/mocha (Node) and pytest (Python) are all
# project-local: they are installed as dependencies, not system tools. The npm
# default ("npm test -- …") hides the runner in package.json's "test" script, so
# inspect that too. Used only to decide whether to warn (S85) — never to gate.
runner_is_local_dep() {
  local cmd="$1"
  case "$cmd" in
    *vitest*|*jest*|*mocha*|*pytest*) return 0 ;;
  esac
  if [ -f "$TOPLEVEL/package.json" ] \
     && grep -Eq '"test"[[:space:]]*:[[:space:]]*"[^"]*(vitest|jest|mocha)' "$TOPLEVEL/package.json"; then
    return 0
  fi
  return 1
}
# --- detect the repo's STACK (S105) --------------------------------------
# Sniff the top-level markers into ONE stack id (the S104 classifier key) so every
# downstream stage knows the ecosystem. When SEVERAL stacks are present the repo is
# AMBIGUOUS: rather than silently seeding a testCommand by detection precedence
# (package.json is checked before Cargo.toml, so a Rust+JS repo used to quietly get
# `npm test`), we seed NO testCommand and warn, naming the candidate stacks. An
# explicit LCARS_TEST_CMD override still wins (the captain chose it). A single
# detected stack seeds its testCommand exactly as before (byte-equivalent).
STACK="$(detect_stack)"

case "$STACK" in
  ambiguous*)
    # Multiple stacks: only an explicit override seeds a command; otherwise null.
    TEST_CMD="${LCARS_TEST_CMD:-}"
    ;;
  *)
    TEST_CMD="${LCARS_TEST_CMD:-$(detect_test_cmd)}"
    ;;
esac

# S183 fix round 1 (D1) — DETECTION IS NOT A FOUNDATION.
#
# MEASURED: a repo whose only `test` script is npm's default
# `echo "Error: no test specified" && exit 1` was refused by the foundation gate
# BEFORE `lcars init` and ALLOWED after it. `_dtc_js` claims any package.json
# carrying a "test" key and falls back to a bare `npm test --`, so init seeded
# that placeholder into config; the readiness status axis then read `ready`
# (the command's first token resolves), and the foundation axis followed it.
# Init always precedes file, so the attack only ever failed in a repo no captain
# is ever in — and init's OWN probe printed "✗ PROBE FAILED … Error: no test
# specified" in the very run that flipped the verdict to ready.
#
# THE DISTINCTION IS PROVENANCE, NOT AUTHENTICITY. This is emphatically NOT a
# mechanical check that a runner is genuine — that question was attacked three
# ways and beaten (greenfield-dev.md, *What we are NOT changing*). It is one
# line about who chose the command:
#
#   • `$LCARS_TEST_CMD` / `lcars update --test-command` — the CAPTAIN'S RULING.
#     Honoured exactly as before, on any repo, with no evidence required.
#   • a candidate LCARS DETECTED — a guess. A guess may configure a test system
#     the repo already has; it may not MANUFACTURE one the evidence denies.
#
# So a detected candidate is dropped when, and only when, the repo carries no
# positive evidence of a test system at all (lcars_test_system_evidence — the
# same oracle the gate and the readiness line read, so they cannot disagree).
# Every repo with real test infrastructure seeds exactly what it seeded before.
if [ -n "$TEST_CMD" ] && [ -z "${LCARS_TEST_CMD:-}" ] \
   && ! lcars_test_system_evidence >/dev/null 2>&1; then
  printf '  ⚠ a `test` script is present but there is no test system behind it — no testCommand seeded.\n' >&2
  printf '    LCARS found no test files, no test framework and no runner in this repo, so the\n' >&2
  printf '    detected command would prove nothing. Establish Vision lays the foundation; if\n' >&2
  printf '    this repo DOES have a test system LCARS cannot see, name it yourself:\n' >&2
  printf '    lcars update --test-command '"'"'<command>'"'"'\n' >&2
  TEST_CMD=""
fi

if [ -n "$TEST_CMD" ]; then
  TESTCMD_VALUE="\"$(lcars_json_escape "$TEST_CMD")\""; TESTCMD_HUMAN="$TEST_CMD"
  # LOUD flag (BUG-007 invariant): the red gate can only judge the QUARANTINED
  # tests if the command honours $LCARS_TESTS_DIR. A command that ignores it runs
  # the repo's EXISTING suite, so a green result proves nothing and the gate must
  # reject it. Warn the captain at init time rather than letting it silently stall
  # Implement later. (cargo/go/make defaults can't be auto-scoped to a dir.)
  #
  # S147: SUPPRESSED for the seeded `dotnet test <proj>` command. The warning is
  # factually FALSE for a NATIVE-ISOLATION runner (stack_uses_native_isolation /
  # stack_is_native in run.sh): those never take the quarantine path at all —
  # their gate legs are scoped by the runner's OWN flags (`dotnet test --filter`,
  # `cargo test --test`, `go test -run`, an explicit spec file) — so "the red
  # gate will reject every quarantined suite" describes something that cannot
  # happen. Before S147 a dotnet repo seeded no command, so the alarm never fired
  # for it; the new seed made 7 lines of false alarm the FIRST thing a C# captain
  # sees, which is a defect this session introduced and must not ship.
  #
  # The test is on the SEEDED COMMAND'S SHAPE, not on the stack. Gating on
  # `$STACK = dotnet` was wrong: a repo with a top-level bare `App.csproj` AND a
  # Makefile `test:` target seeds `make test` — a directory-oriented runner that
  # genuinely DOES need $LCARS_TESTS_DIR — and silencing the correct warning
  # there took away something HEAD raised.
  #
  # LEDGERED, deliberately not fixed here: rust/go/ruby carry the same false
  # alarm on their own seeds. Silencing them would change init output that
  # predates this round and that this round's regression contract byte-compares
  # against pre-S147 — the brief's own instruction is to stop rather than fight
  # that lock. Same one-line cure (add their seeded command shapes here)
  # whenever a round is chartered to move those stacks' output.
  case "$TEST_CMD" in
    *LCARS_TESTS_DIR*) : ;;  # honours it — nothing to flag
    *)
      # The `dotnet test` shape, matched DIRECTLY rather than by prefix-strip.
      # The old form was `[ "dotnet test ${TEST_CMD#dotnet test }" = "$TEST_CMD" ]`,
      # which strips the prefix "dotnet test " WITH A TRAILING SPACE — a pattern a
      # BARE `dotnet test` (nothing after "test") can never match, so the most
      # obvious solution-root command a C# captain can write fell through and got
      # all 7 lines of false alarm (S147 DEFECT-5). Both arms below are anchored,
      # so `dotnet run` / `dotnet testify` / `dotnet-coverage …` still warn.
      __dn_test_shape=0
      case "$TEST_CMD" in
        "dotnet test"|"dotnet test "*) __dn_test_shape=1 ;;
      esac
      if [ "$__dn_test_shape" = 1 ] \
         && stack_uses_native_isolation "$STACK"; then : ; else
      printf '  ⚠ testCommand "%s" does not reference $LCARS_TESTS_DIR.\n' "$TEST_CMD" >&2
      printf '    The Implement red gate runs it with $LCARS_TESTS_DIR pointing at the\n' >&2
      printf '    quarantined fail-first tests; if the command ignores that var it will run\n' >&2
      printf '    the repo'"'"'s EXISTING suite instead, and the red gate will reject every\n' >&2
      printf '    quarantined suite (a green-on-nothing result proves nothing). Edit\n' >&2
      printf '    testCommand in .git/lcars/config.json to run ONLY "$LCARS_TESTS_DIR" when\n' >&2
      printf '    it is set (e.g. pytest "${LCARS_TESTS_DIR:-.}").\n' >&2
      fi
      ;;
  esac
else
  TESTCMD_VALUE='null'; TESTCMD_HUMAN="none (set testCommand to enable the Implement red gate)"
  # No testCommand was seeded. Explain WHY per the detected stack (S105), mirroring
  # the LCARS_TESTS_DIR warning voice above — an AMBIGUOUS repo needs the captain to
  # pick a stack; an UNKNOWN repo has no recognized ecosystem at all.
  case "$STACK" in
    ambiguous*)
      cands="${STACK#ambiguous(}"; cands="${cands%)}"
      printf '  ⚠ multiple stacks detected (%s) — no testCommand seeded.\n' "$cands" >&2
      printf '    LCARS will not guess which ecosystem to run tests with when several are\n' >&2
      printf '    present (it would pick one by precedence and silently ignore the others).\n' >&2
      printf '    Set testCommand in .git/lcars/config.json to the runner for the stack you\n' >&2
      printf '    want the Implement red gate to use (honouring "$LCARS_TESTS_DIR").\n' >&2
      ;;
    dotnet)
      # S147: a dotnet repo whose TEST PROJECT could not be pinned. Either
      # SEVERAL projects look like test projects (name them all — the S105
      # idiom — and let the captain choose) or none does.
      dn_projs="$(detect_dotnet_test_projects | tr '\n' ' ')"
      if [ -n "${dn_projs// /}" ]; then
        # ONE recommended verb per readout: the shared verdict line printed a few
        # lines below already points at `lcars update --fix-tests` (which, on this
        # verdict, PRESENTS these candidates to pick from and spends nothing).
        # Naming `--test-command` here too gave the captain two different answers
        # to the same question on one screen; it stays the manual override,
        # documented on the fix path itself rather than competing with it.
        printf '  ⚠ dotnet stack detected but SEVERAL test projects are present — no testCommand seeded.\n' >&2
        printf '    Candidates: %s\n' "$dn_projs" >&2
        printf '    LCARS will not choose which project the Implement gates run.\n' >&2
      else
        printf '  ⚠ dotnet stack detected but no test project was found — no testCommand seeded.\n' >&2
        printf '    A test project is a *.csproj referencing Microsoft.NET.Test.Sdk (what\n' >&2
        printf '    `dotnet new xunit` scaffolds). Add one, then re-run `lcars update`.\n' >&2
      fi
      ;;
    ruby)
      # S145: ruby stack detected but the runner could not be resolved — either an
      # rspec (spec/) AND a minitest (test/ + Rakefile) layout both look possible
      # (no decisive Gemfile rspec signal), or neither could be pinned (e.g. a bare
      # gem with only a *.gemspec). Name both candidate runners; never guess.
      printf '  ⚠ ruby stack detected but the test runner is ambiguous — no testCommand seeded.\n' >&2
      printf '    An rspec (spec/) and a minitest (test/ + Rakefile) layout both look possible,\n' >&2
      printf '    or neither could be resolved. Set testCommand in .git/lcars/config.json to the\n' >&2
      printf '    runner you want (e.g. "bundle exec rspec" or "bundle exec rake test").\n' >&2
      ;;
    # unknown (greenfield): NO warning here — a repo with no stack markers and
    # no detectable runner is EXPECTED, never an alarm (captain ruling, S146).
    # The shared bootstrap verdict line at the end of the readout
    # (lcars_readiness_line: "◇ NO TEST SYSTEMS FOUND — …") is the ONE calm
    # status for this case; anything actionable goes through
    # `lcars update --fix-tests`, never a hand-edit-config.json lecture.
  esac
fi

# --- detect a worktree provisioning command (S82) -------------------------
# `lcars run` provisions each Stage's isolated git worktree by running this once
# in the worktree. The detected default REUSES the main checkout's installed deps
# (symlinks node_modules, offline-install fallback — see detect_worktree_setup_cmd
# in lcars-common.sh) so any repo works with no hand-edit. Honour an explicit
# LCARS_WORKTREE_SETUP_CMD override (mirrors LCARS_TEST_CMD). Null when nothing is
# detected — the provisioner then warns and skips, it does not block.
WT_SETUP_CMD="${LCARS_WORKTREE_SETUP_CMD:-$(detect_worktree_setup_cmd)}"
if [ -n "$WT_SETUP_CMD" ]; then
  WTSETUP_VALUE="\"$(lcars_json_escape "$WT_SETUP_CMD")\""
else
  WTSETUP_VALUE='null'
fi

# --- warn when a LOCAL-dependency runner has nothing to provision it (S85) -----
# The Implement red/green gates run testCommand inside an ISOLATED git worktree.
# A runner that resolves only from node_modules/.bin or a venv (vitest/jest/mocha/
# pytest — not a binary guaranteed on PATH) will NOT exist in that fresh worktree
# unless worktreeSetupCommand provisions it. S82 auto-seeds that command for JS
# repos, but when it ends up null (a captain cleared it, or an ecosystem we can't
# yet provision, e.g. Python) the gate would fail with "command not found" and the
# failure misreads as a missing implementation. Flag it LOUD at init — the runner
# is detected, the provisioning is not — so the captain wires it now, not
# mid-Implement. Detection + warning only; this never gates.
if [ -n "$TEST_CMD" ] && [ "$WTSETUP_VALUE" = 'null' ] && runner_is_local_dep "$TEST_CMD"; then
  printf '  ⚠ testCommand runner is a LOCAL dependency but worktreeSetupCommand is not set.\n' >&2
  printf '    The Implement gates run "%s"\n' "$TEST_CMD" >&2
  printf '    inside an isolated git worktree; a runner resolvable only from\n' >&2
  printf '    node_modules/venv will be MISSING there unless worktreeSetupCommand\n' >&2
  printf '    provisions it. Set worktreeSetupCommand in .git/lcars/config.json (see the\n' >&2
  printf '    S82 ecosystem default) or run `lcars update` to backfill it, so the gate\n' >&2
  printf '    worktree has the test runner installed.\n' >&2
fi

# Preserve the original creation time across re-runs (idempotent).
if [ -f "$CONFIG" ] && grep -q '"created"' "$CONFIG"; then
  CREATED="$(sed -n 's/.*"created": *"\([^"]*\)".*/\1/p' "$CONFIG" | head -1)"
fi
[ -n "${CREATED:-}" ] || CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Write config.json by MERGE, never clobber: any key already present (a captain's
# customized testCommand / model / comprehensionBudget) is preserved; only
# missing keys are filled from the detected defaults below. The desired list is
# the canonical schema, in key order.
# lcarsVersion stamps the repo with the LCARS version that initialized it (MISSING-
# only, like every other key — a re-init preserves a hand-edited stamp; `lcars
# update` is what force-refreshes it). Omitted only when the running version can't
# be resolved (no VERSION file), so we never seed a bogus stamp.
VERSION_LINE=""
[ -n "$RUNNING_VERSION" ] && VERSION_LINE="
lcarsVersion=\"$RUNNING_VERSION\""
# stack is the detected ecosystem id (S105); ambiguous(...)/unknown are stored as
# their literal token so the config self-documents WHY a testCommand may be absent.
STACK_VALUE="\"$(lcars_json_escape "$STACK")\""
# S196 — cloneId is this CLONE's durable identity, and the source of the short
# fingerprint every mission id minted here carries. Resolved BEFORE the merge so
# a re-init preserves the existing one (the merge preserves any key already
# present), and so a clone that acquired its id lazily — through the
# `<lcars-dir>/clone-id` bridge file, before there was a config.json to hold it
# — hands that same value over instead of minting a second. It MUST be in the
# desired schema: lcars_config_merge drops every key absent from that list, so
# an unlisted cloneId would be silently deleted by the next `lcars init` or
# `lcars update` and the clone's ids would jump. See lcars_clone_id.
if [ "$DRY_RUN" -eq 1 ]; then
  CLONE_ID="$(lcars_clone_id "$CONFIG" --dry-run)"
else
  CLONE_ID="$(lcars_clone_id "$CONFIG")"
fi
# S207 — `workerBin`, the repo's engine pin, and it is CONDITIONAL by design.
#
# It is written when init had to fall back off claude (a copilot-only laptop:
# the repo must open on the engine it can actually run), and it is written when
# the config ALREADY carries the key — because lcars_config_merge treats this
# list as the canonical schema and DELETES every top-level key absent from it,
# so an unlisted workerBin was being WIPED by the next `lcars init` (the exact
# failure S196 paid for with cloneId, and the merge preserves the existing value
# when the key is listed).
#
# It is NOT written on a machine with claude installed and no existing pin: a
# repo with no pin keeps run.sh's historical default, and seeding `claude` into
# every config would hand config.json a say in engine precedence it has never
# had — which is the bug S196 spent a session reversing (adopt.sh:451-473).
WORKERBIN_LINE=""
if { [ -n "$ENGINE_CHOSEN" ] && [ "$ENGINE_CHOSEN" != "claude" ]; } || lcars_config_has_key "$CONFIG" workerBin; then
  WORKERBIN_LINE="
workerBin=\"$(lcars_json_escape "$ENGINE_CHOSEN")\""
fi
# S201 — `numberOne`, Number One's repo-level switch. It is in the desired
# schema for the reason cloneId is: lcars_config_merge treats this list as the
# canonical schema and DELETES every top-level key absent from it, so an
# unlisted block would be silently wiped the first time the captain ran
# `lcars update` — un-engaging his first officer without saying so (the exact
# failure S196 paid for with cloneId).
#
# THE DEFAULT IS `{"enabled": false}` and it is written on ONE LINE. The merge
# preserves an existing raw value by capturing the tail of the line the key sits
# on, so a pretty-printed object would be truncated at its first newline. Every
# writer of this key (`lcars xo`, the board's toggle) emits one line for the
# same reason.
# S308 — `gateTimeout`, the proof-gate timeout this repo needs, in SECONDS.
# It is in the desired schema for the reason cloneId and numberOne are:
# lcars_config_merge treats this list as the canonical schema and DELETES every
# top-level key absent from it, so an unlisted key would be wiped the first time
# anyone ran `lcars update` — taking the repo's recorded timeout with it and
# silently restoring the 120s default the Implement gates were killing legs at.
#
# `null` means "use the default" (120s; run.sh resolves env > config > default).
# An existing value is PRESERVED by the merge — a measurement never overwrites
# the captain's number — and the init-time probe seeds one only when it measures
# a suite slower than the default (lcars_seed_gate_timeout).
GATE_TIMEOUT_VALUE="$(lcars_config_get_raw "$CONFIG" gateTimeout)"
case "$GATE_TIMEOUT_VALUE" in ''|*[!0-9]*) GATE_TIMEOUT_VALUE=null ;; esac

DESIRED_CONFIG="cloneId=\"$CLONE_ID\"
model=\"$DEFAULT_MODEL\"$WORKERBIN_LINE
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
stack=$STACK_VALUE
testCommand=$TESTCMD_VALUE
worktreeSetupCommand=$WTSETUP_VALUE
comprehensionBudget=1200
gateTimeout=$GATE_TIMEOUT_VALUE
numberOne={\"enabled\": false}$VERSION_LINE
created=\"$CREATED\""
if [ "$DRY_RUN" -eq 1 ]; then
  printf 'lcars init: dry run — no changes made.\n'
  printf 'Would write config: %s\n' "$CONFIG"
  lcars_config_merge "$CONFIG" "$DESIRED_CONFIG" --dry-run
  printf 'Would create missions directory: %s\n' "$MISSIONS_DIR"
  if ! git -C "$TOPLEVEL" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    printf 'Would seed an empty initial commit (leaving staged files untouched).\n'
  fi
  printf 'Would verify an available worker CLI and add LCARS scratch patterns to .git/info/exclude.\n'
  printf 'Would create missing GitHub labels (name|color; existing labels are not queried):\n'
  lcars_all_labels
  exit 0
fi
lcars_config_merge "$CONFIG" "$DESIRED_CONFIG"

# The clone-id BRIDGE file has served its purpose: config.json now holds the
# value (either it always did, or the merge just wrote the one the bridge
# carried). Remove it so there is exactly ONE home for the clone's identity.
[ -f "$LCARS_DIR/clone-id" ] \
  && [ -n "$(lcars_config_get "$CONFIG" cloneId)" ] \
  && rm -f "$LCARS_DIR/clone-id"

# The readiness banner must report what ACTUALLY landed in config.json after the
# merge — not the freshly-detected defaults. On a fresh repo the persisted values
# equal the defaults; on a re-run over a captain's hand-edited config the merge
# PRESERVES their customizations, so we read them back and render those instead.
# Keep the human-friendly rendering: an absent/null value shows as "none".
PERSISTED_MODEL="$(lcars_config_get "$CONFIG" model)"
[ -n "$PERSISTED_MODEL" ] || PERSISTED_MODEL="$DEFAULT_MODEL"
PERSISTED_CONTEXT="$(lcars_config_get "$CONFIG" contextFile)"
[ -n "$PERSISTED_CONTEXT" ] || PERSISTED_CONTEXT="none"
PERSISTED_TESTCMD="$(lcars_config_get "$CONFIG" testCommand)"
[ -n "$PERSISTED_TESTCMD" ] || PERSISTED_TESTCMD="none"
PERSISTED_STACK="$(lcars_config_get "$CONFIG" stack)"
[ -n "$PERSISTED_STACK" ] || PERSISTED_STACK="unknown"

# --- LOCAL: keep the harness's scratch out of the target repo -------------
# LCARS workers leave throwaway scratch in the tree (LCARS runners, and each
# agentic CLI's own scratch dir — Claude's .claude/, Copilot's .copilot/).
# vision.md FORBIDS editing the target repo's tracked .gitignore, so we ignore
# scratch via .git/info/exclude instead — it lives inside .git/ (like
# .git/lcars/), is never tracked, and keeps scratch out of `git status` and any
# future `git add`. CLI/host-agnostic and idempotent (a glob already present is
# never re-appended). config.json `scratchGlobs` can extend this at runtime; this
# seeds the base set so the guard exists from the very first mission. Keep this
# list in step with scratch_globs() in skills/lcars-run/run.sh.
EXCLUDE_FILE="$GIT_DIR/info/exclude"
mkdir -p "$GIT_DIR/info" 2>/dev/null || true
[ -f "$EXCLUDE_FILE" ] || : >"$EXCLUDE_FILE"
for g in '.lcars-*' '*/.lcars-*' '.lcars-run-*' '*/.lcars-run-*' \
         '__lcarsq__/' '__lcarsq__/*' '*/__lcarsq__' '*/__lcarsq__/*' \
         '.claude/' '.claude/*' '*/.claude/*' \
         '.copilot/' '.copilot/*' '*/.copilot/*' \
         '.*-run.cjs' '.*-run.mjs' '.*-run.js' '.*-run.sh' '.*-run.py' \
         '*/.*-run.cjs' '*/.*-run.mjs' '*/.*-run.js' '*/.*-run.sh' '*/.*-run.py'; do
  grep -qxF -- "$g" "$EXCLUDE_FILE" 2>/dev/null || printf '%s\n' "$g" >>"$EXCLUDE_FILE"
done

# --- GITHUB: create the LCARS label set -----------------------------------
# The canonical label set and the create-if-missing logic are shared with
# `lcars update` via lcars-common.sh, so the two skills can never drift.
GH_REPO=""
EXISTING_LABELS=""
LABELS_CREATED=0
LABELS_SKIPPED=0
GH_OK=0

if command -v "$GH_BIN" >/dev/null 2>&1; then
  GH_OK=1
  GH_REPO="$("$GH_BIN" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  EXISTING_LABELS="$("$GH_BIN" label list --limit 200 --json name -q '.[].name' 2>/dev/null)"
  lcars_create_labels "$GH_BIN" "$EXISTING_LABELS"
  LABELS_CREATED="$LCARS_LABELS_CREATED"
  LABELS_SKIPPED="$LCARS_LABELS_SKIPPED"
fi

# --- OUTPUT: readiness summary --------------------------------------------
echo "  ✓ .git/lcars/ created"
case "$SEEDED_INITIAL_COMMIT" in
  1) echo "  ✓ seeded an empty initial commit — LCARS proves work against a parent commit (tests red on the parent, green on the tip); your staged/untracked files were left exactly as they were" ;;
  2) echo "  ⚠ this repo has no commits and one could not be seeded (is git user.name/user.email set?) — LCARS proves work against a parent commit, so make the first one yourself: git commit --allow-empty -m \"initial commit\"" ;;
esac
echo "  ✓ config.json written  (stack: $PERSISTED_STACK, model: $PERSISTED_MODEL, context: $PERSISTED_CONTEXT, tests: $PERSISTED_TESTCMD)"
[ -n "${LCARS_CONFIG_ADDED_KEYS:-}" ] && echo "    keys seeded: $LCARS_CONFIG_ADDED_KEYS"
case "$ENGINE_CHOSEN" in
  claude) echo "  ✓ Claude CLI verified  ($ENGINE_VERSION)" ;;
  *)      echo "  ✓ $ENGINE_CHOSEN CLI verified  ($ENGINE_VERSION)" ;;
esac
[ -n "$ENGINE_FALLBACK_NOTE" ] && echo "    $ENGINE_FALLBACK_NOTE"
if [ "$GH_OK" -eq 1 ]; then
  total=$((LABELS_CREATED + LABELS_SKIPPED))
  where="${GH_REPO:+ on $(lcars_gh_web_host)/$GH_REPO}"
  if [ "$LABELS_SKIPPED" -gt 0 ]; then
    echo "  ✓ $LABELS_CREATED labels created, $LABELS_SKIPPED already present ($total total)$where"
  else
    echo "  ✓ $LABELS_CREATED labels created$where"
  fi
else
  echo "  ⚠ gh CLI not found — skipped GitHub label setup. Install gh and re-run to finish."
fi
# S146: the ONE test-readiness verdict line (shared with update/status/board).
# Silent when ready; repair voice for broken/missing; bootstrap voice for a
# greenfield repo (unknown) — status, never an alarm.
lcars_test_readiness "$CONFIG"
READINESS_LINE="$(lcars_readiness_line)"
[ -n "$READINESS_LINE" ] && echo "  $READINESS_LINE"

# THE INIT PROBE — prove the suite RUNS, don't just prove the command resolves.
#
# lcars_test_readiness is cheap by construction: "ready" means the testCommand's
# first token is on PATH. That is a claim about the COMMAND, not the SUITE, and
# the gap is not theoretical — a repo pinned vitest 4 against vite 5 (needs
# vite >= 6), so every suite died at import and collected ZERO tests while `npx`
# resolved perfectly. init declared it mission-ready and the breakage surfaced
# days later inside a Mission, misread as a code defect.
#
# init is a ONE-TIME setup action, so unlike status/board it can afford a single
# bounded run. Probe ONLY the `ready` verdict: that is the one state that can
# lie. broken/missing/unknown/ambiguous already tell the truth and have their
# own voice above.
#
# A red suite NEVER blocks setup — init's other side effects (config, labels)
# are done and correct, and a repo whose tests are red is a normal place to
# start work. We just refuse to call it verified.
if [ "${LCARS_TESTREADY_STATUS:-}" = "ready" ] && [ -z "${LCARS_INIT_SKIP_PROBE:-}" ]; then
  echo "  … probing test systems ($LCARS_TESTREADY_TESTCMD)"
  run_probe "$LCARS_TESTREADY_TESTCMD"
  report_probe
  case "$PROBE_OUTCOME" in
    pass) echo "  ✓ TEST SYSTEMS ONLINE — verified by a live run; missions will be proof-gated with: $LCARS_TESTREADY_TESTCMD"
          # S308: the probe just TIMED this repo's whole suite. If it is slower
          # than the proof-gate timeout, record that here rather than leave every
          # Implement leg to be killed mid-run and recorded INCONCLUSIVE.
          lcars_seed_gate_timeout "$CONFIG" "$PROBE_SECS" ;;
    timeout)
          echo "    The suite did not finish inside ${PROBE_TIMEOUT}s, so LCARS cannot tell whether it is"
          echo "    SLOW or HUNG, and it will not guess. If it is simply slow, time it yourself and"
          echo "    record that in .git/lcars/config.json as \`gateTimeout\` (seconds) — the Implement"
          echo "    gates kill a proof leg at $(lcars_gate_timeout_default)s by default and record it INCONCLUSIVE."
          echo "    Missions are proof-gated on this command, so fix it before relying on the"
          echo "    Implement gates: \`lcars update --fix-tests\` repairs the common causes." ;;
    *)    echo "    Missions are proof-gated on this command, so fix it before relying on the"
          echo "    Implement gates: \`lcars update --fix-tests\` repairs the common causes." ;;
  esac
fi
# THE LAST LINE IS THE CALL TO ACTION, so it has to be true (S183 fix round 1,
# D5). It said "run `lcars file`" unconditionally — two lines after the readiness
# line had said "Start it with Establish Vision", on a repo where `lcars file` is
# now REFUSED by the foundation gate. Measured on blank, README-only and
# code-without-tests repos. Same verdict the gate reads, so they cannot diverge.
case "${LCARS_TESTREADY_FOUNDATION:-}" in
  greenfield|untested)
    echo "  LCARS ready — this repo has no test foundation yet, so start with Establish Vision;"
    echo "  normal missions (\`lcars file\`) unlock the moment the initialization mission lands."
    ;;
  *)
    echo "  LCARS ready — run \`lcars file\` to start your first Mission."
    ;;
esac
