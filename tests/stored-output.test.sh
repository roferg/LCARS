#!/usr/bin/env bash
# Real Git and real runners; optional Jest/RSpec dependencies are never installed.
set -eu
export LCARS_WORKER_BIN=copilot
exec python3 "$(dirname "$0")/lib/stored-output.py"
