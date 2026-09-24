#!/bin/bash
# autoshoot.sh — for children 2..4: on every stage change, shoot board+card (cshot.sh) with the next shot number; tripwire after each
S="$(cd "$(dirname "$0")" && pwd)"; M=~/Projects/DX-Scorecard/.git/lcars/missions
iss() { echo $((206+$1)); }
prev2=align; prev3=align; prev4=align; N=${1:-89}
while kill -0 33937 2>/dev/null; do
  for i in 2 3 4; do
    f=$M/lcars-20260919-00$i-8cb0/state.json
    st=$(sed -n 's/.*"stage": "\([^"]*\)".*/\1/p' $f | head -1); aw=$(grep -c '"awaitingHuman": true' $f)
    eval pv=\$prev$i
    key="$st$aw"
    if [ "$key" != "$pv" ] && [ "$st" != "align" ]; then
      t=$(date +%H:%M)
      "$S/cshot.sh" $N bug$(iss $i)-$st lcars-20260919-00$i-8cb0 "$t PDT: the board as bug #$(iss $i) (lcars-20260919-00$i-8cb0) enters $(echo $st | tr a-z A-Z)$([ "$aw" = 1 ] && echo ' — AWAITING HUMAN')." "Card crop: bug #$(iss $i) at ${st}$([ "$aw" = 1 ] && echo ' (awaiting human)'), $t PDT." >/dev/null 2>&1
      echo "$t shot $N bug#$(iss $i) $st aw=$aw"
      bash "$S/trip.sh" | sed "s/^/$t phase-D bug$(iss $i)-$st /" >> "$S/tripwire.log"; tail -1 "$S/tripwire.log"
      N=$((N+2)); eval prev$i=\$key
    fi
  done
  sleep 15
done
echo "$(date +%H:%M) resolve-logs exited; autoshoot done (next shot $N)"
