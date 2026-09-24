#!/bin/bash
# waitchg.sh <max-seconds> — return when state.json / events.jsonl changes, or on timeout
M=~/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260911-001-8cb0
f() { cat $M/state.json $M/events.jsonl 2>/dev/null | shasum; ls $M | grep -v liveness | shasum; }
h0=$(f); end=$(( $(date +%s) + $1 ))
st=$(date +%s); until { [ "$(f)" != "$h0" ] && [ $(( $(date +%s) - st )) -ge 90 ]; } || [ $(date +%s) -ge $end ]; do sleep 5; done
