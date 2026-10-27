#!/usr/bin/env bash
# Prompt-contract regression only; behavioral acceptance requires real workers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT/skills/lcars-run/stages/plan.md" <<'PY'
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
heading = "## Before submitting: two checks against the actual artifacts"
assert heading in text, "Plan has no pre-submission self-check at all"
block = text.split(heading, 1)[1].split("\n## ", 1)[0]
for phrase in (
    "Is this visual claim actually true of the drawing?",
    "What else does this change move?",
    "removing",
    "notDrawn",
    "same block",
    "seams",
    "dependencies",
    "establishesSharedInfrastructure",
    "test does not make",
    "description alone",
    "rewrite another ticket",
    "every clause",
    "base rules",
    "each consumer",
    "comparison evidence",
    "consumer-to-criterion",
):
    assert phrase in block, f"Plan self-check omits {phrase!r}"
print("PASS: Plan's submission contract covers drawing truth and change impact")
PY
