#!/usr/bin/env bash
# Fast, SCOPED test for S111 Phase 3′ — EVIDENCE-GATED DECLARED TEST SETUP.
#
# The behaviour: when the runner PREFLIGHT proves the ticket's target package
# cannot run tests (env-cannot-run) while the repo root CAN, the Test Writer is
# INVITED — in its prompt — to declare the missing test infrastructure alongside
# its tests: a `setup/` scratch dir of NEW package-relative files (e.g. a vitest
# config) plus `test-setup.json` naming the package, the observed gap, and an
# install command. The harness (never the worker) APPLIES it in the ticket's
# tree, re-probes, and only then runs the normal self-smoke + red gate — so the
# 127→red transition proves the declared setup actually works. Without evidence
# a manifest is IGNORED (attempt-1 always runs naked); an applied-but-still-dead
# setup parks awaiting-human; on ticket green the verified facts are recorded to
# the repo's test landscape. provision_worktree re-applies the install command
# in every fresh gate worktree so post-commit/full-suite judge the same env.
#
# Zero tokens: fake probe-based testCommands + a scripted stub worker.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }

# --- fixture: monorepo-ish repo with pkgA (no runner until "installed") ------
# testCommand `bash <repo>/probe.sh` (cwd = the package): 127s until the cwd
# holds .runner-installed; after install it is a healthy REACTIVE runner.
new_repo() { # -> echoes repo dir
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$repo/pkgA"
  printf '{ "name": "pkgA" }\n' > "$repo/pkgA/package.json"
  printf 'export function hint() {}\n' > "$repo/pkgA/game.js"
  ( cd "$repo" && git add -A && git commit -qm init )
  cat > "$repo/probe.sh" <<'SH'
#!/usr/bin/env bash
if [ ! -f ".runner-installed" ]; then
  echo "sh: vitest: command not found"
  exit 127
fi
files="$(find "${LCARS_TESTS_DIR:-}" -type f -name '*.test.*' 2>/dev/null)"
if [ -z "$files" ]; then echo "no test files found"; exit 0; fi
echo "AssertionError: expected hint overlay, got none"
exit 1
SH
  mkdir -p "$repo/.git/lcars/missions/test-001/tickets/t-001" \
           "$repo/.git/lcars/missions/test-001/manifests"
  cat > "$repo/.git/lcars/missions/test-001/state.json" <<'JSON'
{ "id": "test-001", "type": "feature", "title": "t", "stage": "implement" }
JSON
  cat > "$repo/.git/lcars/missions/test-001/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-001", "title": "hint overlay", "description": "d",
                 "acceptanceCriteria": ["overlay exists"] } ] }
JSON
  cat > "$repo/.git/lcars/missions/test-001/manifests/t-001.md" <<'MD'
## Relevant files
- pkgA/game.js
MD
  echo "$repo"
}

# A scripted stub worker: on a TEST-WRITER spawn it creates tests (+ optionally
# the declared setup) in $LCARS_WORK_OUT; other roles produce nothing. Its
# behaviour is keyed by $STUB_MODE (exported by each case).
make_worker() { # -> echoes stub path
  local stub="$TMPROOT/worker.sh"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
prompt="$2"   # claude adapter argv: -p <prompt> ...
out="${LCARS_WORK_OUT:-}"
[ -n "${STUB_PROMPT_LOG:-}" ] && printf '%s\n' "$prompt" >> "$STUB_PROMPT_LOG"
[ -n "$out" ] || exit 0
case "${LCARS_WORKER_ROLE:-}" in
  implement-test-writer)
    cat > "$out/tests/t-001.test.js" <<'TS'
import { hint } from './game';
test('overlay', () => { expect(hint()).toBe('Arrows / WASD to move'); });
TS
    if [ "${STUB_MODE:-}" = "declare-setup" ]; then
      mkdir -p "$out/setup"
      printf 'export default { test: {} }\n' > "$out/setup/vitest.config.js"
      cat > "$out/test-setup.json" <<JSON
{ "package": "pkgA", "gap": "no test runner: vitest 127",
  "installCommand": "bash ${STUB_INSTALL:-missing-install.sh}" }
JSON
    fi
    if [ "${STUB_MODE:-}" = "declare-bad-path" ]; then
      mkdir -p "$out/setup/src"
      printf 'evil\n' > "$out/setup/src/game.js"
      cat > "$out/test-setup.json" <<JSON
{ "package": "pkgA", "gap": "no runner",
  "installCommand": "bash ${STUB_INSTALL:-missing-install.sh}" }
JSON
    fi
    ;;
esac
exit 0
SH
  chmod +x "$stub"
  echo "$stub"
}

run_ticket() { # repo extra-env... -> RC + OUT (env pairs as later args)
  local repo="$1"; shift
  OUT="$( cd "$repo" && env "$@" \
            LCARS_TEST_CMD="bash $repo/probe.sh" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=claude \
            LCARS_EMPTY_WORKER_TRIES=1 LCARS_WORKER_TRIES=2 \
            LCARS_SETUP_INSTALL_ALLOW_RE='^bash ' \
            bash "$SCRIPT" implement-ticket --mission test-001 --ticket t-001 2>&1 )"
  RC=$?
}

WORKER="$(make_worker)"

# === G1: dead pkg + live root → the Test Writer prompt INVITES a declared setup
repo="$(new_repo)"
touch "$repo/.runner-installed"     # ROOT alive; pkgA stays dead
PLOG="$TMPROOT/g1-prompts.txt"; : > "$PLOG"
run_ticket "$repo" STUB_MODE= STUB_PROMPT_LOG="$PLOG"
if grep -q "test-setup.json" "$PLOG"; then
  ok "G1. dead-pkg preflight INVITES the declared setup in the Test-Writer prompt"
else
  bad "G1. no setup invitation in the prompt (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi

# === G1b: root ALSO dead, but a SIBLING package declares a runner → invite ===
# (the pnpm-monorepo reality: the workspace root has no runner in .bin, yet
# sibling packages test fine — the invite must key off sibling runner decls,
# not a root probe.)
repo="$(new_repo)"
mkdir -p "$repo/pkgB"
printf '{ "name": "pkgB", "devDependencies": { "vitest": "^1.6.0" } }\n' > "$repo/pkgB/package.json"
PLOG="$TMPROOT/g1b-prompts.txt"; : > "$PLOG"
run_ticket "$repo" STUB_MODE= STUB_PROMPT_LOG="$PLOG"       # NO root marker: root probe dead
if grep -q "test-setup.json" "$PLOG"; then
  ok "G1b. dead root + sibling vitest decl → still INVITES the declared setup"
else
  bad "G1b. sibling-runner repo did not invite (rc=$RC: $(printf '%s' "$OUT" | tail -3))"
fi

# === G1c: dead EVERYWHERE (no sibling runner) → park, no invite ==============
repo="$(new_repo)"
PLOG="$TMPROOT/g1c-prompts.txt"; : > "$PLOG"
run_ticket "$repo" STUB_MODE= STUB_PROMPT_LOG="$PLOG"
state="$repo/.git/lcars/missions/test-001/state.json"
if grep -q '"awaitingHuman": *true' "$state" && ! grep -q "test-setup.json" "$PLOG"; then
  ok "G1c. runner-less everywhere → parked, no invite (setup can't fix repo-wide provisioning)"
else
  bad "G1c. dead-everywhere handling (rc=$RC, invited=$(grep -c 'test-setup.json' "$PLOG" 2>/dev/null))"
fi

# === G2: declared setup is APPLIED, gate goes 127→red, tests saved ===========
repo="$(new_repo)"
touch "$repo/.runner-installed"     # root alive
cat > "$repo/install-fake.sh" <<'SH'
#!/usr/bin/env bash
touch .runner-installed
SH
STUB_MODE=declare-setup run_ticket "$repo" STUB_MODE=declare-setup \
  STUB_INSTALL="$repo/install-fake.sh"
if [ -f "$repo/pkgA/vitest.config.js" ]; then
  ok "G2a. declared setup file landed in the package"
else
  bad "G2a. setup file not applied (rc=$RC: $(printf '%s' "$OUT" | tail -4))"
fi
if [ -f "$repo/pkgA/.runner-installed" ]; then
  ok "G2b. installCommand ran in the package dir"
else
  bad "G2b. installCommand did not run"
fi
if [ -d "$repo/.git/lcars/missions/test-001/tickets/t-001/tests" ] \
   && [ -n "$(find "$repo/.git/lcars/missions/test-001/tickets/t-001/tests" -type f 2>/dev/null)" ]; then
  ok "G2c. red gate passed after setup — tests locked (127→red proven)"
else
  bad "G2c. tests not locked after setup (rc=$RC: $(printf '%s' "$OUT" | tail -4))"
fi
if [ -f "$repo/.git/lcars/missions/test-001/test-setup-applied.json" ]; then
  ok "G2d. applied setup recorded at mission level"
else
  bad "G2d. no mission-level applied-setup record"
fi

# === G3: NO evidence (healthy pkg runner) → a manifest is IGNORED ============
repo="$(new_repo)"
touch "$repo/.runner-installed" "$repo/pkgA/.runner-installed"   # both alive
cat > "$repo/install-fake.sh" <<'SH'
#!/usr/bin/env bash
touch .runner-installed
SH
STUB_MODE=declare-setup run_ticket "$repo" STUB_MODE=declare-setup \
  STUB_INSTALL="$repo/install-fake.sh"
if [ ! -f "$repo/pkgA/vitest.config.js" ]; then
  ok "G3. healthy runner → unsolicited manifest ignored (attempt-1 runs naked)"
else
  bad "G3. unsolicited manifest was applied without evidence"
fi

# === G4: a setup file targeting src/ is REJECTED =============================
repo="$(new_repo)"
touch "$repo/.runner-installed"
cat > "$repo/install-fake.sh" <<'SH'
#!/usr/bin/env bash
touch .runner-installed
SH
STUB_MODE=declare-bad-path run_ticket "$repo" STUB_MODE=declare-bad-path \
  STUB_INSTALL="$repo/install-fake.sh"
if [ ! -f "$repo/pkgA/src/game.js" ]; then
  ok "G4a. src/ setup file NOT applied (whitelist held)"
else
  bad "G4a. src/ setup file was applied"
fi
if printf '%s' "$OUT" | grep -qi "reject"; then
  ok "G4b. rejection is loud"
else
  bad "G4b. rejection not named in output (rc=$RC: $(printf '%s' "$OUT" | tail -4))"
fi

# === G5: setup applied but the runner is STILL dead → park, naming the try ===
repo="$(new_repo)"
touch "$repo/.runner-installed"
cat > "$repo/install-fake.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
STUB_MODE=declare-setup run_ticket "$repo" STUB_MODE=declare-setup \
  STUB_INSTALL="$repo/install-fake.sh"
state="$repo/.git/lcars/missions/test-001/state.json"
if grep -q '"awaitingHuman": *true' "$state"; then
  ok "G5a. still-dead runner after setup → parked awaiting-human"
else
  bad "G5a. no park after failed setup (rc=$RC: $(printf '%s' "$OUT" | tail -4))"
fi
if grep -qi "setup" "$repo/.git/lcars/missions/test-001/pending.json" 2>/dev/null; then
  ok "G5b. the pending question names the tried setup"
else
  bad "G5b. pending question does not mention the setup attempt"
fi

# === G6: provision_worktree re-applies the recorded installCommand ===========
LIB="$(mktemp "$TMPROOT/lib.XXXX")"
sed -n '/^provision_worktree() {/,/^}/p' "$SCRIPT" >"$LIB"
sed -n '/^setup_reapply_in_worktree() {/,/^}/p' "$SCRIPT" >>"$LIB"
sed -n '/^run_with_hard_timeout() {/,/^}/p' "$SCRIPT" >>"$LIB"
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null
if ! type setup_reapply_in_worktree >/dev/null 2>&1; then
  bad "G6. setup_reapply_in_worktree not extractable from run.sh"
else
  GIT_BIN=git
  emit_event() { :; }   # stub the event sink for the extracted functions
  json_str() { sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -1; }
  MISSION_DIR="$TMPROOT/g6-mission"; mkdir -p "$MISSION_DIR"
  wt="$TMPROOT/g6-wt"; mkdir -p "$wt/pkgA"
  cat > "$MISSION_DIR/test-setup-applied.json" <<JSON
{ "package": "pkgA", "gap": "g", "installCommand": "bash $TMPROOT/g6-install.sh" }
JSON
  cat > "$TMPROOT/g6-install.sh" <<'SH'
#!/usr/bin/env bash
touch .reapplied
SH
  LCARS_CFG="$TMPROOT/does-not-exist.json" LCARS_WORKTREE_SETUP_CMD="" \
  LCARS_SETUP_INSTALL_ALLOW_RE='^bash ' \
    provision_worktree "$wt" || :
  if [ -f "$wt/pkgA/.reapplied" ]; then
    ok "G6. provision_worktree re-applies the recorded installCommand in the pkg"
  else
    bad "G6. installCommand not re-applied in a fresh worktree"
  fi
fi

echo
printf 'test-setup-declare: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
