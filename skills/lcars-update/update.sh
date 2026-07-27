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
DEFAULT_MODEL="${LCARS_MODEL:-claude-sonnet}"

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
VERB=""
VERB_CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --test-command)   VERB="set"; shift; VERB_CMD="${1:-}"; [ $# -gt 0 ] && shift ;;
    --test-command=*) VERB="set"; VERB_CMD="${1#--test-command=}"; shift ;;
    --probe-tests)    VERB="probe"; shift ;;
    --fix-tests)      VERB="fix"; shift ;;
    *) die "unknown option \"$1\" — usage: lcars update [--test-command '<cmd>' | --probe-tests | --fix-tests]" ;;
  esac
done

# --- the running LCARS version (what update stamps the repo current to) ----
# VERSION ships in the repo root (../.. from this skill dir; -P resolves the
# install symlink to the physical checkout). LCARS_VERSION wins so tests can pin
# it; LCARS_REPO redirects the checkout root (mirrors skills/lcars-version and
# init.sh). Empty when unresolved — the stamp is then left as-is.
lcars_running_version() {
  if [ -n "${LCARS_VERSION:-}" ]; then printf '%s' "$LCARS_VERSION"; return; fi
  local phys repo vf
  phys="$(cd "$SCRIPT_DIR" && pwd -P)"
  repo="${LCARS_REPO:-$(cd "$phys/../.." 2>/dev/null && pwd -P)}"
  vf="$repo/VERSION"
  [ -f "$vf" ] || return 0
  sed -n '/[^[:space:]]/{s/^[[:space:]]*//; s/[[:space:]]*$//; p; q;}' "$vf"
}
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

# run_probe <cmd> — run the test command ONCE from the repo root, BOUNDED by
# $LCARS_PROBE_TIMEOUT (default 120s; perl's alarm survives exec, so the timer
# rides into the spawned bash). Sets PROBE_OUTCOME (pass|fail|zero-collected|
# timeout), PROBE_RC, and PROBE_OUT (captured-output file). Zero-collected is
# its OWN honest outcome, never a pass — the signature REUSES the rg_signature
# `zerotests` + proof_zero_collected phrasings from skills/lcars-run/run.sh
# (keep the two in step).
PROBE_TIMEOUT="${LCARS_PROBE_TIMEOUT:-120}"
run_probe() {
  local cmd="$1"
  PROBE_OUT="$(mktemp "${TMPDIR:-/tmp}/lcars-probe.XXXXXX")"
  ( cd "$TOPLEVEL" && perl -e 'alarm shift; exec @ARGV or exit 127' \
      "$PROBE_TIMEOUT" bash -c "$cmd" ) >"$PROBE_OUT" 2>&1
  PROBE_RC=$?
  # S147: THREE VSTest phrasings, all exiting 0 (observed, SDK 10.0.107) — a
  # filter that matches nothing, a test project with no test methods, and a run
  # whose every discovered case was SKIPPED (`[Fact(Skip=…)]`), which prints
  # neither "no test" phrase and used to read here as "the suite ran and passed".
  # They are the dotnet green-on-nothing trap, so the probe names them too; the
  # skipped form keys on the NUMBERS (zero failed AND zero passed) so a real
  # 1-passed/1-skipped run stays a pass. Keep in step with rg_signature
  # `zerotests` + proof_zero_collected in skills/lcars-run/run.sh.
  local zero='No test files found|No test suite found in|No tests found|no tests ran|Ran 0 tests|collected 0 items|(^|[^0-9])0 examples, 0 failures$|(^|[^0-9])0 runs, 0 assertions|no tests to run|test result: ok\. 0 passed|^No test matches the given testcase filter .*\.dll|^No test is available in .*\.dll|^(Passed|Failed|Skipped)! +- +Failed: +0, +Passed: +0,'
  # S147: MSBuild never even REACHED a test run — the project/solution the
  # command names is not there. Reporting that as "the suite ran but reported
  # failures" sends the captain hunting a test failure that does not exist.
  local cantrun='^MSBUILD : error MSB100[39]:'
  if [ "$PROBE_RC" -eq 142 ]; then          # 128 + SIGALRM(14): the alarm fired
    PROBE_OUTCOME="timeout"
  elif grep -Eq "$cantrun" "$PROBE_OUT"; then
    PROBE_OUTCOME="cannot-run"
  elif grep -Eq "$zero" "$PROBE_OUT"; then  # runner finished but ran NOTHING
    PROBE_OUTCOME="zero-collected"
  elif [ "$PROBE_RC" -eq 0 ]; then
    PROBE_OUTCOME="pass"
  else
    PROBE_OUTCOME="fail"
  fi
}

# report_probe — the ship-status readout for the last run_probe.
report_probe() {
  case "$PROBE_OUTCOME" in
    pass)
      echo "  ✓ PROBE COMPLETE — test systems responding: the suite ran and passed." ;;
    fail)
      echo "  ✗ PROBE FAILED — the suite ran but reported failures (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    zero-collected)
      echo "  ⚠ PROBE INCONCLUSIVE — the runner started but collected ZERO tests."
      echo "    That is not a pass: the command may be scoped to the wrong place." ;;
    cannot-run)
      echo "  ⚠ PROBE COULD NOT RUN — the command never reached a test run: the"
      echo "    project or solution it names could not be loaded (exit $PROBE_RC)."
      tail -n 5 "$PROBE_OUT" 2>/dev/null | sed 's/^/      /' ;;
    timeout)
      echo "  ⚠ PROBE TIMED OUT — no verdict within ${PROBE_TIMEOUT}s; the suite never settled." ;;
  esac
}

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
# Engine: $LCARS_WORKER_BIN → config workerBin → claude. Toolset role `launch`
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
  [ -n "$wb" ] || wb="claude"
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
      [ "$PROBE_OUTCOME" = "pass" ] && exit 0
      exit 1
      ;;

    fix)
      lcars_test_readiness "$CONFIG"
      ORIG_STATUS="$LCARS_TESTREADY_STATUS"
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
        if [ "$PROBE_OUTCOME" = "pass" ]; then print_verdict; exit 0; fi
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
          if [ "$ORIG_STATUS" = "unknown" ]; then
            # GREENFIELD (captain ruling): no infra found AND discovery honestly
            # found nothing — this is EXPECTED status, not an error. Config
            # untouched; filing missions is unaffected.
            echo "  ◇ NO TEST SYSTEMS FOUND — discovery confirms a greenfield repo."
            echo "    The first mission's engineering crew will establish them; filing is unaffected."
            exit 0
          fi
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

DESIRED_CONFIG="model=\"$DEFAULT_MODEL\"
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
stack=$STACK_VALUE
testCommand=null
worktreeSetupCommand=$WTSETUP_VALUE
comprehensionBudget=1200$VERSION_LINE
created=\"$CREATED\""
lcars_config_merge "$CONFIG" "$DESIRED_CONFIG"
CONFIG_ADDED="$LCARS_CONFIG_ADDED_KEYS"

# Targeted schema migration: rewrite a stale copy-based vitest testCommand to the
# in-place form (S101). Runs AFTER the merge so it rewrites the preserved value.
migrate_stale_testcommand "$CONFIG"

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
    where="${GH_REPO:+ on github.com/$GH_REPO}"
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
