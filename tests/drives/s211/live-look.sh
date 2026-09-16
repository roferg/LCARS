#!/usr/bin/env bash
# ONE LIVE COPILOT LOOK at a planted input dir — the REAL evaluate.md prompt,
# the REAL worker-adapter, a real cold copilot worker in the number-one role,
# pinned to Opus. No claude ever. Then the REAL xo-score.py over its verdict.
#
#   bash live-look.sh <case-dir>        # case-dir holds input/ ; writes out/
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
W="$1"
. "$REPO/tests/drives/lib/real-worker.sh"
REAL_COPILOT="$(lcars_resolve_real_worker copilot "")" || exit 77
INPUT="$W/input"; OUT="$W/out"; rm -rf "$OUT"; mkdir -p "$OUT"
inventory="$(cd "$INPUT" && find . -type f | sed 's|^\./|  - |' | sort)"
extra="## The mission
Mission id: lcars-20260916-s211-live

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
bash "$ADAPTER" spawn copilot number-one "$OUT" "$prompt" >"$W/worker.stdout" 2>"$W/worker.stderr"
rc=$?
echo "worker exit $rc"
[ -s "$OUT/xo-verdict.json" ] || { echo "NO VERDICT (see $W/worker.stdout)"; exit 1; }
python3 "$REPO/skills/lcars-xo/xo-score.py" "$OUT/xo-verdict.json" "$INPUT/criteria.json" \
        "$OUT/verdict.json" "$INPUT/observations.json" "$INPUT/tests.json" >"$OUT/score.txt" 2>&1
echo "--- score.txt ---"; cat "$OUT/score.txt" | sed -n '1,6p'
