#!/usr/bin/env bash
# Fast, STANDALONE test for the S133 span-packages preflight fix (skill source:
# skills/lcars-run/run.sh — repo_tests_elsewhere, the predicate behind "don't park
# a package-spanning ticket just because the repo root has no hoisted runner").
#
# The defect (caught live on bug lcars-20260713-003): its manifest spanned TWO
# packages (packages/editor + packages/engine, the latter only a read-only type
# import), so ticket_target_package returned "" and the preflight probed the REPO
# ROOT. In a non-hoisted pnpm monorepo vitest lives in each package's node_modules,
# NOT the root, so `npx vitest` at the root → "vitest: command not found" → the
# ticket parked at an un-answerable env gate, even though packages/editor runs
# tests fine and the ticket's test lands THERE.
#
# The fix consults `repo_tests_elsewhere ""` (target package empty): if ANY package
# declares a runner, the env CAN test → proceed instead of parking. This locks in
# that predicate — it must find a sibling package's runner even when the root can't
# run tests and the target package arg is EMPTY.
#
# PURE: extracts the helpers with sed and drives them with a fixture repo. A fake
# testCommand that is dead at the root ($TEST_CMD_ENV) + package.json fixtures. No
# real runner, no tokens.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_SH="$REPO/skills/lcars-run/run.sh"

pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }

LIB="$(mktemp)"; TMP="$(mktemp -d)"; trap 'rm -rf "$LIB" "$TMP"' EXIT
for fn in rg_signature resolve_test_cmd red_gate_env_failure runner_preflight_env_failure repo_tests_elsewhere; do
  sed -n "/^$fn() {/,/^}/p" "$RUN_SH" >>"$LIB"
done
# shellcheck source=/dev/null
. "$LIB"
type repo_tests_elsewhere >/dev/null 2>&1 || { echo "FATAL: repo_tests_elsewhere not extracted" >&2; exit 1; }

# The runner is DEAD at the repo root (a non-hoisted monorepo): the testCommand
# always reports vitest missing. red_gate_env_failure must classify it as an
# env/launch failure so runner_preflight_env_failure(root) returns "dead".
export TEST_CMD_ENV='printf "sh: vitest: command not found\n" >&2; exit 127'
export LCARS_CFG="/nonexistent"          # force resolve_test_cmd onto TEST_CMD_ENV
export LCARS_RUNNER_PREFLIGHT=1

echo "S133 span-packages — repo_tests_elsewhere finds a package runner with an EMPTY target"

# Fixture: root package.json (NO runner) + packages/editor/package.json (vitest).
mk_repo() { # -> echoes repo
  local r; r="$(mktemp -d "$TMP/repo.XXXX")"
  printf '{ "name": "root", "private": true }\n' > "$r/package.json"
  mkdir -p "$r/packages/editor"
  printf '{ "name": "@x/editor", "devDependencies": { "vitest": "^1.6.0" } }\n' \
    > "$r/packages/editor/package.json"
  echo "$r"
}

# A. target package EMPTY, root can't run, packages/editor declares vitest → elsewhere=YES
REPO_ROOT="$(mk_repo)"; export REPO_ROOT
if repo_tests_elsewhere ""; then
  ok "A. empty target + root dead + packages/editor has vitest → tests run elsewhere (proceed)"
else
  bad "A. expected repo_tests_elsewhere '' → 0 (found the package runner)"
fi

# B. no package anywhere declares a runner → elsewhere=NO (genuine park)
REPO_ROOT="$(mk_repo)"; rm -f "$REPO_ROOT/packages/editor/package.json"; export REPO_ROOT
if repo_tests_elsewhere ""; then
  bad "B. expected repo_tests_elsewhere '' → 1 (nothing runs → still park)"
else
  ok "B. empty target + NO package declares a runner → nothing runs anywhere (still escalates)"
fi

# C. regression: a NAMED runner-capable package still reports elsewhere=YES
REPO_ROOT="$(mk_repo)"; export REPO_ROOT
if repo_tests_elsewhere "packages/other"; then
  ok "C. named target + a sibling package has vitest → tests run elsewhere (unchanged)"
else
  bad "C. named-target sibling-runner path regressed"
fi

echo
printf 'preflight-spans-packages: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
