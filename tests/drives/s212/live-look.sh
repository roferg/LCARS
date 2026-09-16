#!/usr/bin/env bash
# ONE LIVE COPILOT LOOK — the real prompt template, the real adapter, a real
# cold copilot worker in the number-one role, pinned to Opus. No claude ever.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
W="$REPO/tests/drives/s212/live"
. "$REPO/tests/drives/lib/real-worker.sh"
REAL_COPILOT="$(lcars_resolve_real_worker copilot "")" || exit 77
INPUT="$W/input"; OUT="$W/out"; mkdir -p "$OUT"
inventory="$(cd "$INPUT" && find . -type f | sed 's|^\./|  - |' | sort)"
extra="## The mission
Mission id: lcars-20260915-s212-live

## Your input directory — the mission's RECORD, read-only
$INPUT

These are the files a human at this gate would have in front of him. They are
COPIES; nothing you do can change the mission. Read them with your read tools.
$inventory

## Your output file
Write EXACTLY ONE of these two files:
  - $OUT/xo-verdict.json   you have seen enough, and this is your verdict
  - $OUT/xo-actions.json   you want to look further (at most 12 actions)"
prompt="$(cat "$REPO/skills/lcars-xo/prompts/evaluate.md")

$extra"
export LCARS_WORKER_BIN="$REAL_COPILOT"
export LCARS_WORKER_MODEL="${LCARS_WORKER_MODEL:-claude-opus-4.8}"
export LCARS_WORKER_INPUT_DIRS="$INPUT
$INPUT/shots"
ADAPTER="$REPO/skills/lcars-run/worker-adapter.sh"
echo "── argv ──"; bash "$ADAPTER" argv copilot number-one "$OUT" | sed "s/^/   /"
echo "── live copilot (model $LCARS_WORKER_MODEL) ──"
bash "$ADAPTER" spawn copilot number-one "$OUT" "$prompt" >"$W/worker.stdout" 2>"$W/worker.stderr"
echo "worker exit $?"
