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
#   LCARS_GH_BIN      the gh binary     (default: gh)
#
set -uo pipefail

CLAUDE_BIN="${LCARS_CLAUDE_BIN:-claude}"
GH_BIN="${LCARS_GH_BIN:-gh}"
DEFAULT_MODEL="${LCARS_MODEL:-claude-sonnet}"

# Shared label set + merge-preserving config writer (also used by `lcars update`).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lcars-common.sh"

die() { printf 'lcars init: %s\n' "$1" >&2; exit 1; }

# --- the running LCARS version (stamped into the repo's config) ------------
# The VERSION file ships in the repo root (../.. from this skill dir; -P resolves
# the install symlink to the physical checkout). An explicit LCARS_VERSION wins so
# tests can pin it; LCARS_REPO redirects the checkout root (mirrors the resolution
# in skills/lcars-version/version.sh). Empty when unresolved — the key is then
# simply omitted rather than seeding a bogus stamp.
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

# --- verify the Claude CLI ------------------------------------------------
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  die "Claude CLI not found (looked for '$CLAUDE_BIN'). Install it from https://claude.com/claude-code and re-run."
fi
CLAUDE_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -1)"

# --- LOCAL: scaffold .git/lcars/ -----------------------------------------
mkdir -p "$MISSIONS_DIR"

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
# The vitest test command must RELATIVIZE $LCARS_TESTS_DIR to the runner's cwd:
# vitest's positional test filter is matched RELATIVE to the package root the
# runner runs from, but the Implement gates export $LCARS_TESTS_DIR as an ABSOLUTE
# path (and, for a monorepo, the gate cd's into the touched package). Stripping a
# leading "$PWD/" turns the absolute quarantine path into the package-relative
# positional vitest expects, so the staged tests are discovered & filtered; unset
# (a human running it by hand) it falls back to the whole suite. This abs-positional
# bug bites BOTH single-package AND monorepo vitest, so both emit this form.
VITEST_RELATIVIZING_CMD='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'

# detect_workspace_runner — name the local test runner a monorepo actually uses, so
# the workspace fallback emits a runner-SCOPED command instead of a bare `npm test`
# fan-out across every package. Inspects (in order) a runner config at the workspace
# root (vitest.config.*/jest.config.*), the pnpm lockfile, then every sub-package's
# package.json devDependencies. Echoes vitest|jest|mocha (empty when none found).
detect_workspace_runner() {
  local r
  for r in vitest jest mocha; do
    ls "$TOPLEVEL/$r.config".* >/dev/null 2>&1 && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -qs -- "$r" "$TOPLEVEL/pnpm-lock.yaml" 2>/dev/null && { echo "$r"; return; }
  done
  for r in vitest jest mocha; do
    grep -rqs --include='package.json' --exclude-dir='node_modules' -- "\"$r\"" "$TOPLEVEL" 2>/dev/null \
      && { echo "$r"; return; }
  done
  echo ""
}

detect_test_cmd() {
  if [ -f "$TOPLEVEL/package.json" ] && grep -q '"test"[[:space:]]*:' "$TOPLEVEL/package.json"; then
    # Monorepo (a pnpm workspace, or a "workspaces" field): a bare `npm test` /
    # `pnpm -r test` here FANS OUT across every package, so the red gate can never
    # scope itself to the touched package's quarantined tests. Prefer a command
    # scoped to the local runner that STILL honours $LCARS_TESTS_DIR — LCARS points
    # the var at the touched package (it knows it from the plan/manifests). When the
    # root "test" script doesn't name the runner, DETECT it from the sub-packages
    # (lockfile / config / devDependencies) rather than emitting a fan-out.
    if [ -f "$TOPLEVEL/pnpm-workspace.yaml" ] || grep -q '"workspaces"[[:space:]]*:' "$TOPLEVEL/package.json"; then
      local script runner
      script="$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)"
      case "$script" in
        *vitest*) echo "$VITEST_RELATIVIZING_CMD";              return ;;
        *jest*)   echo 'npx jest ${LCARS_TESTS_DIR:-}';         return ;;
        *mocha*)  echo 'npx mocha ${LCARS_TESTS_DIR:-}';        return ;;
        *)
          runner="$(detect_workspace_runner)"
          case "$runner" in
            vitest) echo "$VITEST_RELATIVIZING_CMD";            return ;;
            jest)   echo 'npx jest ${LCARS_TESTS_DIR:-}';       return ;;
            mocha)  echo 'npx mocha ${LCARS_TESTS_DIR:-}';      return ;;
            *)      echo 'npm test -- ${LCARS_TESTS_DIR:-}';    return ;;
          esac ;;
      esac
    fi
    # Single package: a vitest runner needs the RELATIVIZING positional (same abs-
    # path bug as the monorepo); jest/mocha/other keep the `npm test --` positional
    # default (empty runs the suite).
    case "$(grep -Eo '"test"[[:space:]]*:[[:space:]]*"[^"]*"' "$TOPLEVEL/package.json" | head -1)" in
      *vitest*) echo "$VITEST_RELATIVIZING_CMD"; return ;;
    esac
    echo 'npm test -- ${LCARS_TESTS_DIR:-}'; return; fi
  if [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/pytest.ini" ] || [ -f "$TOPLEVEL/tox.ini" ]; then
    echo 'pytest ${LCARS_TESTS_DIR:-.}'; return; fi
  if [ -f "$TOPLEVEL/Cargo.toml" ]; then echo "cargo test"; return; fi
  if [ -f "$TOPLEVEL/go.mod" ]; then echo "go test ./..."; return; fi
  # Ruby (S145): pick the runner from the layout. rspec when the Gemfile names it
  # or a spec/ dir exists; minitest via `rake test` when a test/ dir + Rakefile are
  # present. A Gemfile prefixes `bundle exec`. When BOTH an rspec (spec/) and a
  # minitest (test/ + Rakefile) layout are present WITHOUT a decisive Gemfile rspec
  # signal, the runner is internally AMBIGUOUS: emit NO command (the caller warns,
  # naming both) rather than guess. A gem library with only a *.gemspec/Rakefile and
  # no spec//test/ also emits nothing. Reached only for a single-stack ruby repo.
  if [ -f "$TOPLEVEL/Gemfile" ] || [ -f "$TOPLEVEL/Rakefile" ] || [ -f "$TOPLEVEL/config.ru" ] \
     || [ -d "$TOPLEVEL/spec" ] || ls "$TOPLEVEL"/*.gemspec >/dev/null 2>&1; then
    local rb_prefix="" rb_rspec=0 rb_mini=0 rb_gem_rspec=0
    [ -f "$TOPLEVEL/Gemfile" ] && rb_prefix="bundle exec "
    { [ -f "$TOPLEVEL/Gemfile" ] && grep -q 'rspec' "$TOPLEVEL/Gemfile"; } && rb_gem_rspec=1
    { [ "$rb_gem_rspec" = 1 ] || [ -d "$TOPLEVEL/spec" ]; } && rb_rspec=1
    { [ -d "$TOPLEVEL/test" ] && [ -f "$TOPLEVEL/Rakefile" ]; } && rb_mini=1
    # A Gemfile explicitly naming rspec is decisive even if a test/ dir also exists.
    [ "$rb_gem_rspec" = 1 ] && rb_mini=0
    if [ "$rb_rspec" = 1 ] && [ "$rb_mini" = 1 ]; then echo ""; return; fi
    if [ "$rb_rspec" = 1 ]; then echo "${rb_prefix}rspec"; return; fi
    if [ "$rb_mini" = 1 ];  then echo "${rb_prefix}rake test"; return; fi
    echo ""; return
  fi
  if [ -f "$TOPLEVEL/Makefile" ] && grep -q '^test:' "$TOPLEVEL/Makefile"; then echo "make test"; return; fi
  # A bash test runner (LCARS dogfoods its own tests/run.sh). It already resolves
  # a positional dir / $LCARS_TESTS_DIR (BUG-009), so scope it to the quarantined
  # tests when the var is set, else the whole `tests` dir for a human. Checked LAST
  # so a real ecosystem (npm/pytest/…) always wins when both are present.
  if [ -f "$TOPLEVEL/tests/run.sh" ]; then
    echo 'bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'; return; fi
  echo ""
}

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

if [ -n "$TEST_CMD" ]; then
  TESTCMD_VALUE="\"$(lcars_json_escape "$TEST_CMD")\""; TESTCMD_HUMAN="$TEST_CMD"
  # LOUD flag (BUG-007 invariant): the red gate can only judge the QUARANTINED
  # tests if the command honours $LCARS_TESTS_DIR. A command that ignores it runs
  # the repo's EXISTING suite, so a green result proves nothing and the gate must
  # reject it. Warn the captain at init time rather than letting it silently stall
  # Implement later. (cargo/go/make defaults can't be auto-scoped to a dir.)
  case "$TEST_CMD" in
    *LCARS_TESTS_DIR*) : ;;  # honours it — nothing to flag
    *)
      printf '  ⚠ testCommand "%s" does not reference $LCARS_TESTS_DIR.\n' "$TEST_CMD" >&2
      printf '    The Implement red gate runs it with $LCARS_TESTS_DIR pointing at the\n' >&2
      printf '    quarantined fail-first tests; if the command ignores that var it will run\n' >&2
      printf '    the repo'"'"'s EXISTING suite instead, and the red gate will reject every\n' >&2
      printf '    quarantined suite (a green-on-nothing result proves nothing). Edit\n' >&2
      printf '    testCommand in .git/lcars/config.json to run ONLY "$LCARS_TESTS_DIR" when\n' >&2
      printf '    it is set (e.g. pytest "${LCARS_TESTS_DIR:-.}").\n' >&2
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
    unknown)
      printf '  ⚠ no known stack detected (no Cargo.toml/go.mod/pyproject.toml/setup.py/\n' >&2
      printf '    package.json/*.csproj/*.sln/pom.xml/build.gradle/Gemfile/*.gemspec) — no\n' >&2
      printf '    testCommand seeded. The Implement red gate needs one; set testCommand in\n' >&2
      printf '    .git/lcars/config.json (honouring "$LCARS_TESTS_DIR") to enable it.\n' >&2
      ;;
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
DESIRED_CONFIG="model=\"$DEFAULT_MODEL\"
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
stack=$STACK_VALUE
testCommand=$TESTCMD_VALUE
worktreeSetupCommand=$WTSETUP_VALUE
comprehensionBudget=1200$VERSION_LINE
created=\"$CREATED\""
lcars_config_merge "$CONFIG" "$DESIRED_CONFIG"

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
echo "  ✓ config.json written  (stack: $PERSISTED_STACK, model: $PERSISTED_MODEL, context: $PERSISTED_CONTEXT, tests: $PERSISTED_TESTCMD)"
[ -n "${LCARS_CONFIG_ADDED_KEYS:-}" ] && echo "    keys seeded: $LCARS_CONFIG_ADDED_KEYS"
echo "  ✓ Claude CLI verified  ($CLAUDE_VERSION)"
if [ "$GH_OK" -eq 1 ]; then
  total=$((LABELS_CREATED + LABELS_SKIPPED))
  where="${GH_REPO:+ on github.com/$GH_REPO}"
  if [ "$LABELS_SKIPPED" -gt 0 ]; then
    echo "  ✓ $LABELS_CREATED labels created, $LABELS_SKIPPED already present ($total total)$where"
  else
    echo "  ✓ $LABELS_CREATED labels created$where"
  fi
else
  echo "  ⚠ gh CLI not found — skipped GitHub label setup. Install gh and re-run to finish."
fi
echo "  LCARS ready — run \`lcars file\` to start your first Mission."
