#!/usr/bin/env bash
# S348: real drive boundary with local git and fake workers.
# Fixture and comparison worktree writes stay under tests/drives/s348/.
set -uo pipefail
exec python3 tests/lib/drive-reanchor.py "$@"
