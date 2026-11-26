#!/usr/bin/env bash
set -uo pipefail
if [ "${1:-}" = --mutations ]; then
  exec python3 "$(dirname "${BASH_SOURCE[0]}")/lib/chunking-decision-mutations.py"
fi
python3 "$(dirname "${BASH_SOURCE[0]}")/lib/chunking-decision.test.py" "$@"
