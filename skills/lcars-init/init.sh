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
detect_test_cmd() {
  if [ -f "$TOPLEVEL/package.json" ] && grep -q '"test"[[:space:]]*:' "$TOPLEVEL/package.json"; then
    # jest/mocha/vitest take a path positional after `--`; empty runs the suite.
    echo 'npm test -- ${LCARS_TESTS_DIR:-}'; return; fi
  if [ -f "$TOPLEVEL/pyproject.toml" ] || [ -f "$TOPLEVEL/pytest.ini" ] || [ -f "$TOPLEVEL/tox.ini" ]; then
    echo 'pytest ${LCARS_TESTS_DIR:-.}'; return; fi
  if [ -f "$TOPLEVEL/Cargo.toml" ]; then echo "cargo test"; return; fi
  if [ -f "$TOPLEVEL/go.mod" ]; then echo "go test ./..."; return; fi
  if [ -f "$TOPLEVEL/Makefile" ] && grep -q '^test:' "$TOPLEVEL/Makefile"; then echo "make test"; return; fi
  echo ""
}
TEST_CMD="${LCARS_TEST_CMD:-$(detect_test_cmd)}"
if [ -n "$TEST_CMD" ]; then
  TESTCMD_VALUE="\"$TEST_CMD\""; TESTCMD_HUMAN="$TEST_CMD"
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
DESIRED_CONFIG="model=\"$DEFAULT_MODEL\"
projectName=\"$PROJECT_NAME\"
contextFile=$CONTEXT_VALUE
testCommand=$TESTCMD_VALUE
comprehensionBudget=1200
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
echo "  ✓ config.json written  (model: $PERSISTED_MODEL, context: $PERSISTED_CONTEXT, tests: $PERSISTED_TESTCMD)"
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
