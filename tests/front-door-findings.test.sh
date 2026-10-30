#!/usr/bin/env bash
# S323: real Plan, HTTP filing, and ECH command regressions (no paid workers).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$ROOT/tests/lib/front-door-findings.test.py" "$@"
