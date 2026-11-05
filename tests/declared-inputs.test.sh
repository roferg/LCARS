#!/usr/bin/env bash
# S347 leg B: real Schedule/Respond and real git; only the forge/worker are fake.
# All fixture and evidence writes use an automatically cleaned temp directory.
set -uo pipefail
python3 tests/lib/declared-inputs.py "$@"
