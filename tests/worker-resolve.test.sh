#!/usr/bin/env bash
#
# Tests for cold-worker BINARY + MODEL resolution (skills/lcars-run/run.sh,
# session 19). This is the CLI-agnostic seam: run.sh decides WHICH cli to run as
# the cold worker (and with which model), the adapter (worker-adapter.sh) decides
# the cli-specific flags. Resolution precedence:
#
#   worker bin   : $LCARS_WORKER_BIN  >  config.json workerBin
#                  >  host-CLI auto-detect (env marker)  >  claude (default)
#   worker model : $LCARS_WORKER_MODEL >  config.json workerModel  >  unset
#
# Host markers (the env var a process LCARS spawns inherits from its host CLI):
#   CLAUDECODE=1  ⇒ claude
#   COPILOT_RUN_APP=1 OR COPILOT_CLI_BINARY_VERSION=<non-empty>  ⇒ copilot
#   (the real GitHub Copilot CLI v1.0.60 sets COPILOT_RUN_APP=1 +
#    COPILOT_CLI_BINARY_VERSION + COPILOT_LOADER_PID; it does NOT set COPILOT_CLI)
#
# The resolver is exercised through the `resolve-worker` subcommand, which prints
# ONE self-explaining line naming the resolved cli + model + the winning SOURCE
# (env / config / detected / default), then a machine-readable summary so the
# tests can assert the resolved values without parsing prose:
#
#   WORKER-RESOLVED bin=<basename> binsrc=<src> model=<m|-> modelsrc=<src>
#
# ⚠ This session's ambient env has CLAUDECODE=1 set. Every test below controls
# the markers explicitly (env -u / explicit set) so a default/detect test can
# never pass for the wrong reason.
#
# Usage: bash tests/worker-resolve.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# Build a throwaway git repo with a .git/lcars/config.json so the resolver's
# config-path resolution (git-common-dir → .git/lcars/config.json) finds it.
# $1 = optional config.json body (default: an empty-object config).
make_repo() { # [config-json]
  local d; d="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$d" && git init -q )
  mkdir -p "$d/.git/lcars"
  printf '%s\n' "${1:-{\}}" >"$d/.git/lcars/config.json"
  printf '%s' "$d"
}

# Run `resolve-worker` from inside a repo with FULL control of the host markers.
# CLAUDECODE and ALL the copilot markers are scrubbed first; the caller re-sets
# via leading VAR=val tokens. Returns the WORKER-RESOLVED summary (stdout) AND the
# human resolution log line (stderr, merged in) so both surfaces are assertable.
resolve_in() { # repo  [extra env assignments...]
  local repo="$1"; shift
  ( cd "$repo" && env -u CLAUDECODE \
      -u COPILOT_CLI -u COPILOT_RUN_APP -u COPILOT_CLI_BINARY_VERSION \
      -u LCARS_WORKER_BIN -u LCARS_WORKER_MODEL -u LCARS_WORKER_CLI \
      "$@" bash "$RUN" resolve-worker 2>&1 )
}

echo "worker-resolve — host-default cold-worker bin + model (session 19)"

# --- 1. explicit LCARS_WORKER_BIN beats config AND detection ------------------
r1="$(make_repo '{"workerBin": "from-config-bin"}')"
out1="$(resolve_in "$r1" CLAUDECODE=1 LCARS_WORKER_BIN=/usr/bin/explicit-bin)"
check "1a. explicit env bin wins over config + detection" \
  "printf '%s' \"\$out1\" | grep -q 'bin=explicit-bin'"
check "1b. explicit env bin source = env" \
  "printf '%s' \"\$out1\" | grep -q 'binsrc=env'"

# --- 2. no env → config.json workerBin is used --------------------------------
r2="$(make_repo '{"workerBin": "config-bin"}')"
out2="$(resolve_in "$r2" CLAUDECODE=1)"
check "2a. config workerBin used when no env" \
  "printf '%s' \"\$out2\" | grep -q 'bin=config-bin'"
check "2b. config bin source = config" \
  "printf '%s' \"\$out2\" | grep -q 'binsrc=config'"

# --- 3. no env, no config → host marker resolves the cli ----------------------
r3="$(make_repo)"
out3c="$(resolve_in "$r3" CLAUDECODE=1)"
check "3a. CLAUDECODE marker ⇒ claude" \
  "printf '%s' \"\$out3c\" | grep -q 'bin=claude'"
check "3b. claude marker source = detected" \
  "printf '%s' \"\$out3c\" | grep -q 'binsrc=detected'"
# Real Copilot CLI (v1.0.60) sets COPILOT_RUN_APP=1 — NOT COPILOT_CLI.
out3p="$(resolve_in "$r3" COPILOT_RUN_APP=1)"
check "3c. COPILOT_RUN_APP marker ⇒ copilot" \
  "printf '%s' \"\$out3p\" | grep -q 'bin=copilot'"
check "3d. copilot marker source = detected" \
  "printf '%s' \"\$out3p\" | grep -q 'binsrc=detected'"
# Fallback marker: COPILOT_CLI_BINARY_VERSION non-empty (RUN_APP unset) ⇒ copilot.
out3v="$(resolve_in "$r3" COPILOT_CLI_BINARY_VERSION=1.0.60)"
check "3e. COPILOT_CLI_BINARY_VERSION marker ⇒ copilot" \
  "printf '%s' \"\$out3v\" | grep -q 'bin=copilot'"
check "3f. copilot version-marker source = detected" \
  "printf '%s' \"\$out3v\" | grep -q 'binsrc=detected'"

# --- 4. nothing at all → claude default (NO marker set) -----------------------
r4="$(make_repo)"
out4="$(resolve_in "$r4")"   # CLAUDECODE/COPILOT_CLI scrubbed by resolve_in
check "4a. no env, no config, no marker ⇒ claude" \
  "printf '%s' \"\$out4\" | grep -q 'bin=claude'"
check "4b. fallback source = default" \
  "printf '%s' \"\$out4\" | grep -q 'binsrc=default'"

# --- 5. workerModel: env > config > unset; unset ⇒ adapter emits NO --model ----
r5e="$(make_repo '{"workerModel": "config-model"}')"
out5e="$(resolve_in "$r5e" CLAUDECODE=1 LCARS_WORKER_MODEL=env-model)"
check "5a. env model wins over config" \
  "printf '%s' \"\$out5e\" | grep -q 'model=env-model'"
check "5b. env model source = env" \
  "printf '%s' \"\$out5e\" | grep -q 'modelsrc=env'"

r5c="$(make_repo '{"workerModel": "config-model"}')"
out5c="$(resolve_in "$r5c" CLAUDECODE=1)"
check "5c. config model used when no env" \
  "printf '%s' \"\$out5c\" | grep -q 'model=config-model'"
check "5d. config model source = config" \
  "printf '%s' \"\$out5c\" | grep -q 'modelsrc=config'"

r5u="$(make_repo)"
out5u="$(resolve_in "$r5u" CLAUDECODE=1)"
check "5e. no model anywhere ⇒ model unset (printed as -)" \
  "printf '%s' \"\$out5u\" | grep -q 'model=- '"

# Adapter regression lock: with NO model env, claude argv is byte-for-byte the
# session-18 five lines (no --model).
A_NOMODEL="$(env -u LCARS_WORKER_MODEL bash "$ADAPTER" argv claude repo-read "$TMPROOT")"
EXPECT_NOMODEL='-p
--allowedTools
Read,Grep,Glob,Write
--output-format
text'
check "5f. adapter: unset model ⇒ exactly the session-18 5 lines (no --model)" \
  "[ \"\$A_NOMODEL\" = \"\$EXPECT_NOMODEL\" ]"

# With a model env set, the adapter appends --model <m> for claude.
A_MODEL="$(LCARS_WORKER_MODEL=opus-x bash "$ADAPTER" argv claude repo-read "$TMPROOT")"
check "5g. adapter: set model ⇒ argv appends '--model'" \
  "printf '%s' \"\$A_MODEL\" | grep -qx -- '--model'"
check "5h. adapter: set model ⇒ argv appends the model value" \
  "printf '%s' \"\$A_MODEL\" | grep -qx 'opus-x'"
check "5i. adapter: --model is the LAST flag pair (appended, not reordered)" \
  "[ \"\$(printf '%s' \"\$A_MODEL\" | sed -n '6p')\" = '--model' ] && [ \"\$(printf '%s' \"\$A_MODEL\" | sed -n '7p')\" = 'opus-x' ]"

# --- 6. the resolution log line names the winning SOURCE for a human ----------
check "6a. log line names env source" \
  "printf '%s' \"\$out1\" | grep -qi 'env'"
check "6b. log line names config source" \
  "printf '%s' \"\$out2\" | grep -qi 'config'"
check "6c. log line names detected source" \
  "printf '%s' \"\$out3c\" | grep -qi 'detect'"
check "6d. log line names default source" \
  "printf '%s' \"\$out4\" | grep -qi 'default'"

echo "worker-resolve: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
