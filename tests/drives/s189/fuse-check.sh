#!/usr/bin/env bash
# S189 fuse check — PROVE the spend fuse is armed before believing "0 billable".
# Every other drive reports 0 spawns; that number only means anything if BOTH
# worker CLIs really resolve to the shim. This fires one deliberate `--model`
# call so the counters are shown moving.
. "$(dirname "$0")/lib.sh"
hdr "FUSE"
note "which claude  : $(command -v claude)"
note "which copilot : $(command -v copilot)"
case "$(command -v claude)" in "$SHIM"/*) ok "claude resolves to the shim" ;; *) bad "claude is the REAL binary" ;; esac
case "$(command -v copilot)" in "$SHIM"/*) ok "copilot resolves to the shim" ;; *) bad "copilot is the REAL binary" ;; esac
claude --model opus -p hi >/dev/null 2>&1
note "after one deliberate --model call: spawns=$(spawns) billable=$(billable)"
