#!/usr/bin/env bash
#
# lcars update — bring an ALREADY-INITIALIZED repo up to the current LCARS
# schema without clobbering the captain's customizations.
#
# Unlike `lcars init` (first-time setup), update assumes .git/lcars/ already
# exists and only fills GAPS:
#   GITHUB  create any MISSING LCARS labels, skip ones already present.
#   LOCAL   add any MISSING config.json keys with their defaults, NEVER
#           overwriting an existing value; missions/ is left completely alone.
#   OUTPUT  report what was ADDED vs ALREADY PRESENT. On an up-to-date repo it
#           changes nothing and prints "nothing to update".
#
# Dependencies are taken via env so they can be stubbed in tests:
#   LCARS_GH_BIN   the gh binary (default: gh)
#
set -uo pipefail

GH_BIN="${LCARS_GH_BIN:-gh}"
# S309 — the backfill default for an OLDER config that has no `model` key at
# all. `$LCARS_MODEL` still wins; otherwise it is resolved from the engine this
# repo actually records, once that is known (below), rather than from the
# hardcoded `claude-sonnet` that used to sit here. An EXISTING model is
# preserved by lcars_config_merge either way — that is what `--engine` /
# `--model` are for.
DEFAULT_MODEL="${LCARS_MODEL:-}"

# Shared label set + merge-preserving config writer (also used by `lcars init`).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lcars-init/lcars-common.sh"

die() { printf 'lcars update: %s\n' "$1" >&2; exit 1; }

# --- S146: argument parse — the test-readiness verbs ------------------------
# `lcars update` grew the SANCTIONED testCommand writers (config is otherwise
# never clobbered — MISSING-only seeding stands for every key):
#   --test-command '<cmd>'   manual set: validate, write, re-verdict, print
#   --probe-tests            run the stored command ONCE, bounded; report
#                            pass / fail / zero-collected / timeout
#   --fix-tests              the one-click repair: suggestion → set (no worker);
#                            none → a read-only discovery worker proposes one;
#                            then set + probe in this SAME invocation
# A verb invocation runs ONLY the verb (no label sync, no version stamp).
#
# S309 added two more sanctioned writers for the SAME reason:
#   --engine <claude|copilot>  record the engine this repo runs on, and move
#                              `model` to the one that engine actually runs
#   --model '<model>'          set `model` verbatim
# They exist because `lcars init` seeds `model` from a DETECTED engine when
# nothing records one, and a seed that turned out wrong had no verb behind it at
# all — the only cure was hand-editing .git/lcars/config.json. `--engine` and
# `--model` are the only two keys they touch; see the verb body for why that is
# enforced through the targeted single-key writers rather than the merge.
VERB=""
VERB_CMD=""
VERB_ENGINE=""
VERB_ENGINE_GIVEN=0
VERB_MODEL=""
VERB_MODEL_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    # S319 — `--test-command` READS A FLAG-SHAPED VALUE THE SAME WAY, and it is
    # the one arm S309 left out of its own rule. MEASURED at HEAD:
    # `lcars update --test-command --model` exited 0, printed
    # `✓ testCommand set: --model` and WROTE `--model` into config.json as this
    # repo's test command — a success tick over a recorded string no shell can
    # run, which is how `lcars update --test-command $CMD --model $M` reads when
    # $CMD is unset and unquoted. It is refused HERE, at parse time, because
    # nothing is written during the parse: naming the flag that lost its value
    # and stopping is strictly cheaper than letting `--model` claim the verb and
    # then refuse in its own name for a mistake that was not `--model`'s.
    --test-command)   VERB="set"; shift
                      case "${1:-}" in
                        -*) die "--test-command was given no command — \"$1\" is another option, not a command. Write --test-command '<command>'; if it came from a variable, that variable is empty. Nothing was written." ;;
                      esac
                      VERB_CMD="${1:-}"; [ $# -gt 0 ] && shift ;;
    --test-command=*) VERB="set"; VERB_CMD="${1#--test-command=}"; shift ;;
    --probe-tests)    VERB="probe"; shift ;;
    --fix-tests)      VERB="fix"; shift ;;
    # S309 fix round 1, D5 — A FLAG-SHAPED VALUE IS A MISSING VALUE.
    # `--engine --model 'zzz'` used to let `--engine` swallow `--model` as its
    # engine name and then refuse with `unknown option "zzz"` — naming the one
    # token that was NOT the mistake. A value beginning with `-` is left for the
    # loop to parse as the flag it is, and `--engine` falls through to the
    # empty-value refusal below, which names the flag the captain actually got
    # wrong.
    #
    # S309 fix round 2, D15 — AND `--model` READS IT THE SAME WAY. Round 1 gave
    # the rule to `--engine` only, so `--model --engine` (what
    # `--model $M --engine $E` collapses to when both are unset and unquoted)
    # swallowed `--engine` as the model string and WROTE it, exit 0, under
    # `✓ model set: --engine` — the engine silently dropped behind a tick. Both
    # arms now refuse a flag-shaped value as the missing value it is, so the
    # pair behaves identically whichever one the captain leaves empty.
    --engine)         VERB="engine"; VERB_ENGINE_GIVEN=1; shift
                      case "${1:-}" in
                        -*) : ;;
                        *)  VERB_ENGINE="${1:-}"; [ $# -gt 0 ] && shift ;;
                      esac ;;
    --engine=*)       VERB="engine"; VERB_ENGINE_GIVEN=1; VERB_ENGINE="${1#--engine=}"; shift ;;
    --model)          [ "$VERB" = "engine" ] || VERB="engine"; shift
                      VERB_MODEL_GIVEN=1
                      case "${1:-}" in
                        -*) : ;;
                        *)  VERB_MODEL="${1:-}"; [ $# -gt 0 ] && shift ;;
                      esac ;;
    --model=*)        [ "$VERB" = "engine" ] || VERB="engine"
                      VERB_MODEL="${1#--model=}"; VERB_MODEL_GIVEN=1; shift ;;
    *) die "unknown option \"$1\" — usage: lcars update [--test-command '<cmd>' | --probe-tests | --fix-tests | --engine <engine> | --model '<model>']" ;;
  esac
done

# --- the running LCARS version (what update stamps the repo current to) ----
# `lcars_running_version` is lcars-common.sh's (sourced above) — S207 moved the
# byte-identical copies init and update each carried into the one place all
# three stampers read, because `lcars adopt` now seeds the stamp too.
RUNNING_VERSION="$(lcars_running_version)"

# --- MIGRATION: stale copy-based vitest testCommand -> in-place form ---------
# S101 made the Test-Writer author each per-ticket test IN THE REPO at its
# convention and run the red gate IN PLACE (positional scope): a co-located test
# imports its sibling source via `./sibling`, so copying it into a `.lcars-tests`
# staging dir DETACHES it from that source and breaks the import. Repos initialized
# by an OLDER `lcars init` carry a COPY-STAGING vitest testCommand that does exactly
# that — now INCOMPATIBLE. This migration recognizes that unambiguous LCARS-generated
# fingerprint and rewrites it to the in-place equivalent, PRESERVING the runner
# invocation + its flags and any leading `cd <pkg>`. It touches ONLY that exact
# form; a genuine custom / already-in-place / non-vitest / null testCommand is left
# completely alone (config is sacred — but the .lcars-tests copy pattern is never
# hand-written).
#
# Sets MIGRATED_TESTCOMMAND=1 when it rewrote the value.
migrate_stale_testcommand() {
  local config="$1"
  MIGRATED_TESTCOMMAND=0
  [ -f "$config" ] || return 0

  local tc; tc="$(lcars_config_get "$config" testCommand)"
  [ -n "$tc" ] || return 0

  # Fingerprint — ALL markers of the LCARS copy-staging vitest form must be present
  # together. Any one absent => not our form => leave untouched.
  case "$tc" in *.lcars-tests*)               : ;; *) return 0 ;; esac
  case "$tc" in *'cp -R "${LCARS_TESTS_DIR'*)  : ;; *) return 0 ;; esac
  case "$tc" in *'--dir .lcars-tests'*)        : ;; *) return 0 ;; esac
  case "$tc" in *'else exec '*'; fi'*)         : ;; *) return 0 ;; esac

  # BASE = the base vitest invocation from the `else exec <BASE>; fi` full-suite
  # branch — preserves the runner path AND flags (e.g. --pool=forks).
  local base
  base="$(printf '%s' "$tc" | sed -n 's/.*else exec \(.*\); fi.*/\1/p')"
  base="$(printf '%s' "$base" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$base" ]; then
    echo "  ⚠ testCommand matches the stale .lcars-tests copy form but its base vitest" >&2
    echo "    invocation could not be derived; set an in-place testCommand manually" >&2
    echo "    (S101: e.g. 'exec node_modules/.bin/vitest run \${LCARS_TESTS_DIR:+\"\${LCARS_TESTS_DIR#\"\$PWD/\"}\"}')." >&2
    return 0
  fi

  # CD = the leading `cd <dir>` before the first `;`, if present.
  local cd_dir="" firstseg
  case "$tc" in
    cd\ *)
      firstseg="${tc%%;*}"
      cd_dir="${firstseg#cd}"
      cd_dir="$(printf '%s' "$cd_dir" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      ;;
  esac

  # In-place form: relativize $LCARS_TESTS_DIR to the runner's cwd (same tail init
  # emits for vitest today). Single-quoted so nothing expands here — the runtime
  # `bash -c` expands it at gate time.
  local tail='${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
  local newtc
  if [ -n "$cd_dir" ]; then
    newtc="cd $cd_dir 2>/dev/null; exec $base $tail"
  else
    newtc="exec $base $tail"
  fi

  [ "$newtc" = "$tc" ] && return 0
  lcars_config_set_string "$config" testCommand "$newtc"
  MIGRATED_TESTCOMMAND=1
}

# --- MIGRATION: UNQUOTED $LCARS_TESTS_DIR scope -> quoted (S148) -------------
# Every seeded testCommand interpolates $LCARS_TESTS_DIR as the positional scope,
# and the Implement gates export it as an ABSOLUTE path. Seeded UNQUOTED, that
# path WORD-SPLITS on IFS whitespace the moment the repo is checked out somewhere
# containing a space or a tab — the runner is handed two half-paths, finds
# neither, and the flip-flop proof gate FALSE-FAILS a perfectly honest ticket
# purely because of WHERE the repo lives (bouncing it to a fresh worker up to 3
# times, then parking it awaiting-human). lcars-common.sh now seeds the quoted
# shapes; this migration repairs the ALREADY-PERSISTED strings, which no amount
# of re-seeding would ever reach (config is merge-only: a present key is kept).
#
# NEVER-CLOBBER IS ABSOLUTE, and here that is enforced the strictest way there
# is: a WHOLE-STRING, byte-for-byte equality against a table of the exact shapes
# LCARS itself seeded. No prefix match, no substring match, no normalization. A
# command the captain hand-wrote or customised — `npm test -- ${LCARS_TESTS_DIR:-}
# --coverage`, `cd pkg && npm test -- ${LCARS_TESTS_DIR:-}`, even the same command
# with two spaces in it — does not byte-match, so it is not ours and it is not
# touched. Anything unrecognised is the captain's, full stop.
#
# Each replacement is the SAME command with the scope quoted; the shape used is
# decided by the arm's default (see the S148 note in lcars-common.sh): a NON-EMPTY
# default takes `"${LCARS_TESTS_DIR:-<default>}"`, an EMPTY one takes
# `${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}` so "no scope ⇒ no argument" survives
# byte-for-byte rather than becoming "no scope ⇒ one EMPTY argument".
#
# Sets MIGRATED_TESTCOMMAND_QUOTING=1 when it rewrote the value.
migrate_unquoted_testcommand_scope() {
  local config="$1"
  MIGRATED_TESTCOMMAND_QUOTING=0
  [ -f "$config" ] || return 0

  local tc; tc="$(lcars_config_get "$config" testCommand)"
  [ -n "$tc" ] || return 0

  local newtc=""
  case "$tc" in
    'npm test -- ${LCARS_TESTS_DIR:-}')
      newtc='npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}' ;;
    'npx jest ${LCARS_TESTS_DIR:-}')
      newtc='npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}' ;;
    'npx mocha ${LCARS_TESTS_DIR:-}')
      newtc='npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}' ;;
    'pytest ${LCARS_TESTS_DIR:-.}')
      newtc='pytest "${LCARS_TESTS_DIR:-.}"' ;;
    *) return 0 ;;                 # not a shape LCARS seeded — the captain's.
  esac

  [ "$newtc" = "$tc" ] && return 0
  lcars_config_set_string "$config" testCommand "$newtc"
  MIGRATED_TESTCOMMAND_QUOTING=1
}

# --- MIGRATION: un-guarded symlink worktreeSetupCommand -> lockfile-guarded --
#
# The JS default provisions a Stage worktree by SYMLINKING the main checkout's
# node_modules. That is right until a ticket CHANGES dependencies: the shared
# install is then the WRONG set, the ticket's own committed lockfile fix can
# never take effect, and — because the runner still STARTS — the gate reads the
# resulting red as "the implementation is not present on the committed branch".
# Observed in the field: a ticket that repaired an unrunnable suite by pinning
# vitest was rejected three times for a defect that was never in its code.
#
# Fixing detect_worktree_setup_cmd only helps repos initialized from now on, so
# repair the ALREADY-PERSISTED string here — the same job S101/S148 do for
# testCommand.
#
# FINGERPRINT-GATED, like its siblings: we rewrite only a command carrying
# LCARS's own symlink signature (`ln -snf "$nm" "$rel"`) that LACKS the guard.
# A captain's hand-written command has neither and is never touched. The
# replacement is REGENERATED from detect_worktree_setup_cmd rather than
# string-patched, so this migration cannot drift from the seed it repairs to.
#
# Sets MIGRATED_WORKTREE_SETUP=1 when it rewrote the value.
migrate_symlink_worktree_setup() {
  local config="$1"
  MIGRATED_WORKTREE_SETUP=0
  [ -f "$config" ] || return 0

  local wc; wc="$(lcars_config_get "$config" worktreeSetupCommand)"
  [ -n "$wc" ] || return 0

  # Ours? (the seeded symlink loop) — otherwise the captain's, leave it.
  case "$wc" in
    *'ln -snf "$nm" "$rel"'*) : ;;
    *) return 0 ;;
  esac
  # Already guarded ⇒ nothing to do (keeps this idempotent).
  case "$wc" in
    *'cmp -s'*) return 0 ;;
  esac

  local new; new="$(detect_worktree_setup_cmd)"
  [ -n "$new" ] || return 0          # no safe default for this repo — leave it.
  [ "$new" = "$wc" ] && return 0
  lcars_config_set_string "$config" worktreeSetupCommand "$new"
  MIGRATED_WORKTREE_SETUP=1
}

# --- locate the repo ------------------------------------------------------
GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" \
  || die "not inside a git repository — run this from a repo root."
TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null)" || TOPLEVEL="$PWD"
case "$GIT_DIR" in
  /*) : ;;
  *)  GIT_DIR="$PWD/$GIT_DIR" ;;
esac

LCARS_DIR="$GIT_DIR/lcars"
CONFIG="$LCARS_DIR/config.json"

# --- must already be initialized -----------------------------------------
if [ ! -d "$LCARS_DIR" ]; then
  die "this repo is not initialized for LCARS — run \`lcars init\` first."
fi

# ===========================================================================
# S146 TEST-READINESS VERBS — the sanctioned testCommand writers + the probe.
# Dispatched BEFORE the label/config/version flow: a verb invocation does ONLY
# its verb. Everything below is skipped on the verb path.
# ===========================================================================

# run_probe / report_probe MOVED to skills/lcars-init/lcars-common.sh (sourced
# above) so `lcars init` can run the SAME probe at setup time. `lcars update`
# calls them unchanged; keeping one copy means the two can never disagree about
# what counts as a pass, a zero-collect, or a timeout.

# print_verdict — re-verdict from the config on disk and print ONE line.
# The verb paths DO confirm ready (that is their whole point); the passive
# readouts (plain update/init/status) stay silent on ready.
print_verdict() {
  lcars_test_readiness "$CONFIG"
  if [ "$LCARS_TESTREADY_STATUS" = "ready" ]; then
    echo "  ✓ TEST SYSTEMS ONLINE — missions will be proof-gated with: $LCARS_TESTREADY_TESTCMD"
  else
    echo "  $(lcars_readiness_line)"
  fi
}

# set_test_command <cmd> — the ONE sanctioned write of config.testCommand.
set_test_command() {
  lcars_config_set_or_add_string "$CONFIG" testCommand "$1" \
    || die "could not write .git/lcars/config.json — check permissions and re-run."
}

# run_discovery — spawn ONE read-only test-discovery worker (the lcars-launch
# discovery pattern: the worker INSPECTS and proposes; this skill executes).
# Engine: $LCARS_WORKER_BIN → config workerBin → the engine INSTALLED here
# (lcars_default_engine; S274). Toolset role `launch`
# (Read/Grep/Glob/Bash — NO Write/Edit, the read fence) via the worker-adapter;
# the worker writes its {testCommand, rationale, status, message} proposal to
# $LCARS_DISCOVERY_JSON and nothing else. Sets DISC_CMD / DISC_RATIONALE /
# DISC_MSG; returns non-zero when no usable proposal came back (config is then
# left UNTOUCHED by the caller).
WORKER_ADAPTER="${LCARS_WORKER_ADAPTER:-$SCRIPT_DIR/../lcars-run/worker-adapter.sh}"
run_discovery() {
  DISC_CMD=""; DISC_RATIONALE=""; DISC_MSG=""
  local wb="${LCARS_WORKER_BIN:-}"
  [ -n "$wb" ] || wb="$(lcars_config_get "$CONFIG" workerBin)"
  # S274 — THE LAST RUNG IS WHAT IS INSTALLED, never the literal `claude`. This
  # read `[ -n "$wb" ] || wb="claude"`, so on a copilot-only laptop with no
  # config pin `lcars update --fix-tests` spawned a claude that is not there and
  # the discovery produced nothing. lcars-common.sh is already sourced at the
  # top of this file, so the shared detector — the same one `lcars init`, the
  # engine pickers, run.sh and launch.sh read — is right here.
  if [ -z "$wb" ]; then
    local _eng; _eng="$(lcars_default_engine "$CONFIG")"
    [ -n "$_eng" ] && wb="$(lcars_engine_bin "$_eng")"
  fi
  # NEITHER CLI IS HERE: say so in one sentence naming both, rather than
  # spawning a binary that is not there and reporting "the crew found nothing".
  if [ -z "$wb" ]; then
    DISC_MSG="no worker CLI found — LCARS drives missions with Claude Code (looked for '$(lcars_engine_bin claude)') or the GitHub Copilot CLI (looked for '$(lcars_engine_bin copilot)'), and neither is on this machine. Install either one and re-run: https://claude.com/claude-code or https://github.com/features/copilot/cli."
    return 1
  fi
  local cli; cli="$(basename "$wb")"
  local outdir="$LCARS_DIR/.fixtests-work"
  mkdir -p "$outdir"
  local disc="$LCARS_DIR/test-discovery.json"
  rm -f "$disc"

  # Assemble with `read -d ''` (NOT $(cat <<EOF)): parens in a heredoc inside a
  # command substitution trip bash 3.2's parser (same guard as launch.sh).
  local PROMPT
  IFS= read -r -d '' PROMPT <<EOF || true
You are the LCARS test-systems engineer. The repo checkout is at:
  $TOPLEVEL
DISCOVER the exact shell command that runs this repo's test suite. Do NOT run
the suite yourself beyond cheap inspection, and do NOT modify any file in the
checkout — inspection only. Read package manifests / Makefiles / gemfiles /
build files / READMEs as needed. Prefer a command that honours the
LCARS_TESTS_DIR environment variable when set (run only that dir), falling back
to the whole suite when unset.

Then write a JSON object to EXACTLY this path (and print nothing):
  $disc
with these fields:
  "testCommand"  the exact shell command that runs the tests
  "rationale"    one short sentence on why this is the right command
  "status"       "ready"

If this repo genuinely has NO test infrastructure at all, instead write
"status": "failed" and a "message" field saying plainly that no test systems
exist yet. Never guess a command you are unsure of.
EOF

  LCARS_DISCOVERY_JSON="$disc" LCARS_WORKER_BIN="$wb" \
    bash "$WORKER_ADAPTER" spawn "$cli" launch "$outdir" "$PROMPT" || true

  if [ ! -f "$disc" ]; then
    DISC_MSG="the discovery crew reported nothing back"
    return 1
  fi
  local st; st="$(lcars_config_get "$disc" status)"
  DISC_CMD="$(lcars_config_get "$disc" testCommand)"
  DISC_RATIONALE="$(lcars_config_get "$disc" rationale)"
  DISC_MSG="$(lcars_config_get "$disc" message)"
  DISC_CMD="$(printf '%s' "$DISC_CMD" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ "$st" != "ready" ] || [ -z "$DISC_CMD" ]; then
    [ -n "$DISC_MSG" ] || DISC_MSG="the discovery crew could not propose a test command"
    return 1
  fi
  return 0
}

if [ -n "$VERB" ]; then
  case "$VERB" in
    # =====================================================================
    # S309 — RECORD THE ENGINE, AND MOVE THE MODEL WITH IT.
    #
    # IT CHANGES EXACTLY TWO KEYS AND IT WRITES THEM ONE AT A TIME. The
    # obvious implementation — rebuild DESIRED_CONFIG and re-run
    # lcars_config_merge — would be WRONG here twice over: the merge PRESERVES
    # an existing value (so it could never move `model` at all), and it treats
    # its list as the canonical schema and DROPS every key not on it, so a verb
    # that ran it would quietly delete the captain's unlisted keys. The
    # targeted `lcars_config_set_or_add_string` writers rewrite one key's line
    # and copy every other byte through, which is what "changes only what it is
    # asked to" has to mean for a file a human also edits.
    #
    # REFUSE BEFORE WRITING. An unknown engine name or an empty model leaves
    # config.json untouched: a half-applied record is worse than no verb.
    engine)
      # S309 fix round 1, D1 — AN EMPTY `--engine` IS A REFUSAL, NOT A NO-OP.
      #
      # MEASURED: `--model ''` refused non-zero and said "Nothing was written",
      # while `--engine ''` (and a bare `--engine`) exited 0 having written
      # nothing and said nothing. Worse, `--engine '' --model 'only-model-given'`
      # exited 0, printed `✓ model set`, wrote the model and SILENTLY DROPPED
      # the engine — so a caller running `update --engine "$E" --model "$M"`
      # with $E unset read a tick and believed the engine was recorded.
      #
      # That is this session's own failure class — something did not happen and
      # nothing said so — reproduced inside the fix for it. The guard mirrors
      # `--model`'s exactly: it names the flag, it refuses non-zero, and it
      # stands BEFORE every write so a half-applied record is impossible.
      if [ "$VERB_ENGINE_GIVEN" -eq 1 ]; then
        VERB_ENGINE="$(printf '%s' "$VERB_ENGINE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$VERB_ENGINE" ] \
          || die "--engine was given no engine to record — name the engine this repo runs on, e.g. lcars update --engine copilot (it knows $(printf '%s' "$LCARS_ENGINES" | sed 's/ / and /')). Nothing was written."
      fi
      if [ "$VERB_MODEL_GIVEN" -eq 1 ]; then
        VERB_MODEL="$(printf '%s' "$VERB_MODEL" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$VERB_MODEL" ] \
          || die "an empty model names nothing — give the model string the worker should be spawned with, e.g. lcars update --model 'claude-opus-5.5'. Nothing was written."
      fi
      # EVERY MISSING VALUE IS NAMED BEFORE ANY VALUE IS JUDGED (fix round 2,
      # D15). `--model --engine zzz` has two faults — a `--model` with no value
      # and a `zzz` that is no engine — and the useful one to report is the
      # flag the captain's unset variable emptied, not the token that drifted
      # into the other flag. So both empty-value guards above run first and this
      # name check runs last.
      if [ -n "$VERB_ENGINE" ]; then
        case " $LCARS_ENGINES " in
          *" $VERB_ENGINE "*) : ;;
          *) die "'$VERB_ENGINE' is not an engine LCARS drives — it knows $(printf '%s' "$LCARS_ENGINES" | sed 's/ / and /'). Nothing was written." ;;
        esac
      fi
      # THE MODEL FOLLOWS THE ENGINE unless the captain named one, in which case
      # his wins — he is more specific than a per-engine default.
      NEW_MODEL="$VERB_MODEL"
      if [ -z "$NEW_MODEL" ] && [ -n "$VERB_ENGINE" ]; then
        NEW_MODEL="$(lcars_default_model_for_engine "$VERB_ENGINE")"
      fi
      if [ -n "$VERB_ENGINE" ]; then
        # The 4th argument is the slot (fix round 1, D6): a workerBin this
        # config does not carry yet goes immediately after `model`, where
        # `lcars init` writes it, so the next init/update reorders nothing.
        lcars_config_set_or_add_string "$CONFIG" workerBin "$VERB_ENGINE" model \
          || die "could not write .git/lcars/config.json — check permissions and re-run."
        echo "  ✓ engine recorded: $VERB_ENGINE"
        lcars_engine_available "$VERB_ENGINE" \
          || echo "    ◇ note: '$(lcars_engine_bin "$VERB_ENGINE")' is not on this machine — the record stands, but a mission cannot run here until it is installed."
      fi
      if [ -n "$NEW_MODEL" ]; then
        lcars_config_set_or_add_string "$CONFIG" model "$NEW_MODEL" \
          || die "could not write .git/lcars/config.json — check permissions and re-run."
        echo "  ✓ model set: $NEW_MODEL"
      fi
      exit 0
      ;;

    set)
      CMD="$(printf '%s' "$VERB_CMD" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$CMD" ] || die "an empty test command powers nothing — give the exact command that runs this repo's suite, e.g. lcars update --test-command 'npm test'."
      set_test_command "$CMD"
      echo "  ✓ testCommand set: $CMD"
      print_verdict
      exit 0
      ;;

    probe)
      TC="$(lcars_config_get "$CONFIG" testCommand)"
      [ -n "$TC" ] || die "no testCommand configured — nothing to probe. Set one with \`lcars update --test-command '<cmd>'\` or repair with \`lcars update --fix-tests\`."
      echo "  ▸ probing test systems: $TC"
      run_probe "$TC"
      report_probe
      # S308: the probe is the one place the whole suite is TIMED — record the
      # gate timeout it implies instead of discarding the measurement.
      [ "$PROBE_OUTCOME" = "pass" ] && lcars_seed_gate_timeout "$CONFIG" "$PROBE_SECS"
      [ "$PROBE_OUTCOME" = "pass" ] && exit 0
      die "test probe reported $PROBE_OUTCOME; test systems are not verified."
      ;;

    fix)
      lcars_test_readiness "$CONFIG"
      ORIG_STATUS="$LCARS_TESTREADY_STATUS"
      # S183 fix round 1 (D3): the SECOND axis, captured beside the first — the
      # one that can tell a `git init` from a tested monorepo.
      ORIG_FOUNDATION="${LCARS_TESTREADY_FOUNDATION:-}"
      # S299 fix round 2: and the THIRD fact, captured the same way and for the
      # same reason — a verdict read after `run_discovery` has run is a verdict
      # about whatever the crew left behind, not the repo this report is about.
      ORIG_INERT_WHY="${LCARS_TESTREADY_INERT_WHY:-}"
      if [ "$ORIG_STATUS" = "ready" ]; then
        echo "  ✓ TEST SYSTEMS ONLINE — nothing to repair (testCommand: $LCARS_TESTREADY_TESTCMD)."
        exit 0
      fi
      # S147/D8: AMBIGUOUS is a CHOICE, and the verdict line promises "LCARS will
      # not choose for you". Falling through to run_discovery broke that promise
      # twice over — it hired a PAID crew, and the crew's whole job was to choose.
      # The repair here is to SHOW the detected candidates: interactively the
      # captain picks one and it is set + probed in this same invocation;
      # non-interactively they are printed with the exact command to run. Either
      # way, ZERO tokens — no worker is ever spawned for this state.
      if [ "$ORIG_STATUS" = "ambiguous" ]; then
        echo "  ⚠ MULTIPLE TEST SYSTEMS DETECTED (${LCARS_TESTREADY_STACKS}) — this repo already"
        echo "    has test systems; LCARS will not choose between them for you."
        if [ -z "$LCARS_TESTREADY_CANDIDATES" ]; then
          echo "    Select one with:"
          echo "    lcars update --test-command '<the command for the system you want>'"
          exit 1
        fi
        AMB_N=0
        while IFS= read -r AMB_C; do
          [ -n "$AMB_C" ] || continue
          AMB_N=$((AMB_N + 1))
          printf '      [%d] %s\n' "$AMB_N" "$AMB_C"
        done <<AMB_EOF
$LCARS_TESTREADY_CANDIDATES
AMB_EOF
        if [ ! -t 0 ]; then
          echo "    Select one with:"
          echo "    lcars update --test-command '<one of the above>'"
          exit 1
        fi
        printf '    Which do the Implement gates run? [1-%d, or blank to cancel] ' "$AMB_N"
        read -r AMB_PICK || AMB_PICK=""
        case "$AMB_PICK" in
          ''|*[!0-9]*) echo "  ◇ NO SELECTION MADE — config untouched."; exit 1 ;;
        esac
        if [ "$AMB_PICK" -lt 1 ] || [ "$AMB_PICK" -gt "$AMB_N" ]; then
          echo "  ◇ NO SELECTION MADE — config untouched."; exit 1
        fi
        NEWCMD="$(printf '%s' "$LCARS_TESTREADY_CANDIDATES" | grep . | sed -n "${AMB_PICK}p")"
        set_test_command "$NEWCMD"
        echo "  ✓ testCommand set: $NEWCMD"
        echo "  ▸ probing test systems…"
        run_probe "$NEWCMD"
        report_probe
        if [ "$PROBE_OUTCOME" = "pass" ]; then
          lcars_seed_gate_timeout "$CONFIG" "$PROBE_SECS"   # S308
          print_verdict; exit 0
        fi
        echo "  ⚠ TEST SYSTEMS SET BUT UNVERIFIED — the command is configured, but the probe reported ${PROBE_OUTCOME}; not declaring ready."
        exit 1
      fi
      NEWCMD=""
      if [ -n "$LCARS_TESTREADY_SUGGESTION" ]; then
        # Detection already has the answer — no worker, no spend.
        NEWCMD="$LCARS_TESTREADY_SUGGESTION"
        echo "  ▸ detection has a candidate — no discovery crew needed."
      else
        echo "  ▸ dispatching a discovery crew to survey the test systems…"
        if ! run_discovery; then
          # S183 fix round 1 (D3): this branched on ORIG_STATUS = unknown, which
          # is the axis that CANNOT tell a `git init` from an npm-workspaces
          # monorepo whose three packages all run vitest — so a fully tested
          # monorepo was told "discovery confirms a greenfield repo" and sent to
          # Establish Vision, a flow that does not apply to it. S183 made the
          # line WORSE than it found it (it now actively misdirects), so it is
          # cured on the FOUNDATION axis, with copy that is true per verdict.
          # SCOPED to the exact line that was wrong: `unknown` is the status
          # that used to mean "greenfield" and now means three different repos.
          # Every other status keeps its shipped REPAIR INCOMPLETE report,
          # including the discovery crew's own message ($DISC_MSG).
          case "${ORIG_STATUS}:${ORIG_FOUNDATION:-}" in
            unknown:greenfield)
              # GREENFIELD (captain ruling): no infra found AND discovery
              # honestly found nothing — EXPECTED status, not an error. Config
              # untouched. "Filing is unaffected" WAS true and is not any more:
              # a normal mission is refused here (the foundation gate) and
              # replaced by Establish Vision, whose initialization mission is
              # the crew that establishes the test systems.
              echo "  ◇ NO TEST SYSTEMS FOUND — discovery confirms a greenfield repo."
              echo "    The first mission here is an initialization mission — its engineering crew will establish them."
              echo "    Start it with Establish Vision; normal missions unlock when it lands."
              exit 0 ;;
            unknown:untested)
              # Code, and nothing to prove it with. NOT greenfield — the project
              # already exists — and there is nothing here for --fix-tests to
              # repair, so it says what it found rather than inventing a repair.
              echo "  ◇ NO TEST SYSTEM FOUND — this repo has code, and nothing to prove a change with."
              echo "    There is no test system here to repair. The foundation is established by an"
              echo "    initialization mission — start it with Establish Vision; normal missions"
              echo "    unlock when it lands. If this repo DOES have a test system LCARS cannot see,"
              echo "    name it yourself: lcars update --test-command '<command>'"
              exit 0 ;;
            unknown:unconfigured)
              # S299 fix round 2 — THE THIRD SURFACE CARRYING ROUND 1'S
              # CONTRADICTION. The sentence below asserts "this repo HAS a test
              # system" on the strength of the FOUNDATION axis, which claims one
              # from the mere PRESENCE of an artifact (it feeds the filing gate,
              # where a false negative kills a mission before it starts). When
              # the detector has PROVED that same artifact runs nothing — a
              # `test:` target with no recipe, an empty tests/run.sh, npm's
              # placeholder script — this told the captain the opposite of what
              # `lcars status` and the board had just told him, and prescribed
              # `--test-command`, which is how round 1's measured captain got a
              # green "TEST SYSTEMS ONLINE" over a command that runs nothing.
              #
              # Same words as the CLI readiness line (lcars_readiness_line in
              # lcars-common.sh) — ONE wording across every surface. The EXIT
              # CODE, the "config untouched" promise and the escape hatch are
              # unchanged: this is the message, not the behaviour.
              if [ -n "${ORIG_INERT_WHY:-}" ]; then
                echo "  ✗ REPAIR INCOMPLETE — the test configuration at the repo root cannot run:"
                echo "    ${ORIG_INERT_WHY}."
                echo "    Discovery could not name a command that runs either: $DISC_MSG."
                echo "    Config untouched. Establish a test runner that actually runs — or, if one"
                echo "    is already here that LCARS missed, name it yourself:"
                echo "    lcars update --test-command '<cmd>'"
                exit 1
              fi
              # This repo HAS a test system — LCARS just has no command for it,
              # and discovery could not name one either. That is a repair that
              # did not land, never a greenfield repo.
              echo "  ✗ REPAIR INCOMPLETE — this repo HAS a test system (${LCARS_TESTREADY_FOUNDATION_WHY:-detected})"
              echo "    but neither detection nor discovery could name the command that runs it: $DISC_MSG."
              echo "    Config untouched. Set it yourself with:"
              echo "    lcars update --test-command '<cmd>'"
              exit 1 ;;
          esac
          echo "  ✗ REPAIR INCOMPLETE — $DISC_MSG."
          echo "    Config untouched. Set the command yourself with:"
          echo "    lcars update --test-command '<cmd>'"
          exit 1
        fi
        NEWCMD="$DISC_CMD"
        [ -n "$DISC_RATIONALE" ] && echo "    crew's rationale: $DISC_RATIONALE"
      fi
      set_test_command "$NEWCMD"
      echo "  ✓ testCommand set: $NEWCMD"
      echo "  ▸ probing test systems…"
      run_probe "$NEWCMD"
      report_probe
      if [ "$PROBE_OUTCOME" = "pass" ]; then
        lcars_seed_gate_timeout "$CONFIG" "$PROBE_SECS"      # S308
        print_verdict
        exit 0
      fi
      echo "  ⚠ TEST SYSTEMS SET BUT UNVERIFIED — the command is configured, but the probe reported ${PROBE_OUTCOME}; not declaring ready."
      exit 1
      ;;
  esac
fi

# --- GITHUB: create only the MISSING labels -------------------------------
GH_REPO=""
LABELS_CREATED=0
LABELS_SKIPPED=0
LABELS_CREATED_NAMES=""
GH_OK=0
if command -v "$GH_BIN" >/dev/null 2>&1; then
  GH_OK=1
  GH_REPO="$("$GH_BIN" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"
  EXISTING_LABELS="$("$GH_BIN" label list --limit 200 --json name -q '.[].name' 2>/dev/null)"
  lcars_create_labels "$GH_BIN" "$EXISTING_LABELS"
  LABELS_CREATED="$LCARS_LABELS_CREATED"
  LABELS_SKIPPED="$LCARS_LABELS_SKIPPED"
  LABELS_CREATED_NAMES="$LCARS_LABELS_CREATED_NAMES"
fi

# --- LOCAL: fill any MISSING config keys (merge, never clobber) ------------
# Recompute the same defaults init would use, so a key added to the schema since
# this repo was initialized gets its proper default. Existing values are
# preserved by lcars_config_merge — only absent keys take these defaults.
if [ -f "$TOPLEVEL/CONTEXT.md" ]; then CONTEXT_VALUE='"CONTEXT.md"'; else CONTEXT_VALUE='null'; fi
PROJECT_NAME="$(basename "$TOPLEVEL")"
CREATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"  # only used if 'created' is somehow absent

# Recompute the worktree provisioning default the SAME way init does (shared
# helper in lcars-common.sh), so an older config gets the proper ecosystem
# default backfilled. Existing values are preserved by lcars_config_merge — only
# an absent key takes this default.
WT_SETUP_CMD="$(detect_worktree_setup_cmd)"
if [ -n "$WT_SETUP_CMD" ]; then
  WTSETUP_VALUE="\"$(lcars_json_escape "$WT_SETUP_CMD")\""
else
  WTSETUP_VALUE='null'
fi

# Detect the repo's stack the SAME way init does (shared helper), so a pre-S105
# config missing the `stack` key gets it backfilled with the proper id. Existing
# values are preserved by lcars_config_merge — only an absent key takes this
# default (a captain-pinned stack survives untouched).
STACK="$(detect_stack)"
STACK_VALUE="\"$(lcars_json_escape "$STACK")\""

# The version STAMP is the one key update deliberately refreshes (that IS update's
# meaning). Read the OLD stamp BEFORE the merge so we can report old → new. Seed
# lcarsVersion in the desired schema (so an absent key is added by the merge, and
# it's never dropped as an unknown key); then, after the merge, FORCE it current
# below. Omitted from the schema only when the running version can't be resolved —
# we then leave whatever stamp exists untouched.
OLD_VERSION="$(lcars_config_get "$CONFIG" lcarsVersion)"
VERSION_LINE=""
[ -n "$RUNNING_VERSION" ] && VERSION_LINE="
lcarsVersion=\"$RUNNING_VERSION\""

# S196 — cloneId, backfilled the same way every other key is: resolved through
# the shared helper (which reads an existing value, or mints and persists one),
# then listed in the desired schema so lcars_config_merge PRESERVES it. Leaving
# it off the list would make `lcars update` DELETE the clone's identity — the
# merge treats its desired list as the canonical schema — and the next mission
# filed here would carry a different fingerprint from its siblings.
CLONE_ID="$(lcars_clone_id "$CONFIG")"

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

# S309 — `workerBin`, THE REPO'S ENGINE PIN, LISTED SO IT SURVIVES.
#
# lcars_config_merge treats its desired list as the canonical schema and DELETES
# every top-level key absent from it. `workerBin` was never on UPDATE's list
# (init has carried it since S207), so a plain `lcars update` silently un-pinned
# the repo — the exact failure S196 paid for with `cloneId` and S308 paid for
# with `gateTimeout`, and it would have thrown away the record `--engine` above
# had just written.
#
# CONDITIONAL, exactly as in init: listed only when the key is already there, so
# an unpinned repo stays unpinned and config.json gains no say in engine
# precedence it did not already have (the S196 ruling). The value supplied is
# the existing one — the merge preserves it anyway, but a default that differed
# from the record would be a trap for the next reader of this line.
WORKERBIN_LINE=""
if lcars_config_has_key "$CONFIG" workerBin; then
  WORKERBIN_LINE="
workerBin=\"$(lcars_json_escape "$(lcars_config_get "$CONFIG" workerBin)")\""
fi

# S309 — and the model BACKFILL default follows the engine this repo records,
# for an older config that has no `model` key at all. An existing value is
# preserved by the merge, so this only ever fires on a config that predates the
# key; it is here so the one case update does seed cannot seed a Claude model
# into a repo pinned to Copilot.
[ -n "$DEFAULT_MODEL" ] \
  || DEFAULT_MODEL="$(lcars_default_model_for_engine "$(lcars_default_engine "$CONFIG")")"

DESIRED_CONFIG="cloneId=\"$CLONE_ID\"
model=\"$DEFAULT_MODEL\"$WORKERBIN_LINE
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
stack=$STACK_VALUE
testCommand=null
worktreeSetupCommand=$WTSETUP_VALUE
comprehensionBudget=1200
gateTimeout=$GATE_TIMEOUT_VALUE
numberOne={\"enabled\": false}$VERSION_LINE
created=\"$CREATED\""
lcars_config_merge "$CONFIG" "$DESIRED_CONFIG"
CONFIG_ADDED="$LCARS_CONFIG_ADDED_KEYS"

# Targeted schema migrations, in order. Both run AFTER the merge so they rewrite
# the PRESERVED value, and both are fingerprint-gated so an unrecognised command
# is never touched. They are disjoint by construction: S101 owns the multi-clause
# .lcars-tests copy-staging form, S148 the four bare seeded one-liners.
migrate_stale_testcommand "$CONFIG"
migrate_unquoted_testcommand_scope "$CONFIG"
migrate_symlink_worktree_setup "$CONFIG"

# Force the version stamp CURRENT (the one deliberate overwrite update owns). The
# merge preserves an existing stamp, so refresh it to the running version here.
# Only counts as a change when the stamp actually moved — an already-current stamp
# stays byte-identical and does not flip the "nothing to update" verdict. When the
# key was freshly seeded by the merge, the merge already reports it in CONFIG_ADDED.
VERSION_STAMPED=0
if [ -n "$RUNNING_VERSION" ] && [ "$OLD_VERSION" != "$RUNNING_VERSION" ]; then
  lcars_config_set_string "$CONFIG" lcarsVersion "$RUNNING_VERSION"
  VERSION_STAMPED=1
fi
# Don't double-report lcarsVersion as an "added key" when we're already reporting
# the stamp move below — keep the config-keys-added line to genuinely new keys.
if [ "$VERSION_STAMPED" -eq 1 ]; then
  CONFIG_ADDED="$(printf '%s' "$CONFIG_ADDED" | tr ' ' '\n' | grep -vx lcarsVersion | tr '\n' ' ')"
  CONFIG_ADDED="$(printf '%s' "$CONFIG_ADDED" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
fi

# --- OUTPUT: report added vs present ---------------------------------------
changed=0

if [ "$GH_OK" -eq 1 ]; then
  if [ "$LABELS_CREATED" -gt 0 ]; then
    changed=1
    where="${GH_REPO:+ on $(lcars_gh_web_host)/$GH_REPO}"
    echo "  ✓ $LABELS_CREATED label(s) created$where: $LABELS_CREATED_NAMES"
    echo "    ($LABELS_SKIPPED already present)"
  fi
else
  echo "  ⚠ gh CLI not found — skipped GitHub label check. Install gh and re-run."
fi

if [ -n "$CONFIG_ADDED" ]; then
  changed=1
  echo "  ✓ config keys added (defaults filled, existing values preserved): $CONFIG_ADDED"
fi

if [ "${MIGRATED_TESTCOMMAND:-0}" -eq 1 ]; then
  changed=1
  echo "  ✓ testCommand migrated to in-place form (S101: co-located tests run in place; old .lcars-tests copy form is incompatible)"
fi

if [ "${MIGRATED_TESTCOMMAND_QUOTING:-0}" -eq 1 ]; then
  changed=1
  echo "  ✓ testCommand migrated to a QUOTED \$LCARS_TESTS_DIR scope (S148: unquoted, the"
  echo "    scope word-split at any repo path containing a space or tab, and the Implement"
  echo "    proof gate false-failed honest tickets). Now: $(lcars_config_get "$CONFIG" testCommand)"
fi

if [ "${MIGRATED_WORKTREE_SETUP:-0}" -eq 1 ]; then
  changed=1
  echo "  ✓ worktree setup migrated to a LOCKFILE-GUARDED form: it now reinstalls when a"
  echo "    Mission's lockfile differs from the main checkout's, instead of symlinking the"
  echo "    wrong dependency set (which made a ticket's own dependency fix un-appliable and"
  echo "    surfaced as \"the implementation is not present on the committed branch\")."
fi

if [ "$VERSION_STAMPED" -eq 1 ]; then
  changed=1
  old_render="${OLD_VERSION:-(unstamped)}"
  echo "  ✓ lcarsVersion stamped: $old_render → $RUNNING_VERSION"
fi

if [ "$changed" -eq 0 ]; then
  echo "  ✓ nothing to update — labels and config are already current."
fi

# S146: the ONE test-readiness verdict line (shared with init/status/board).
# Silent when ready; repair voice for broken/missing; bootstrap voice for a
# greenfield repo. Reported only — the update flow never writes testCommand
# (MISSING-only seeding stands); `--fix-tests` is the sanctioned repair.
lcars_test_readiness "$CONFIG"
READINESS_LINE="$(lcars_readiness_line)"
[ -n "$READINESS_LINE" ] && echo "  $READINESS_LINE"

echo "  missions/ untouched."
