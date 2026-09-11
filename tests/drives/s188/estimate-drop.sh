#!/usr/bin/env bash
# DRIVE 7 — can the refresh silently DROP the "## Estimate" section (and with it
# every pill the GitHub board scrapes)?
. "$(dirname "$0")/lib.sh"
mkv() { local R; R="$(new_repo)"; write_prd "$R/prd-in.md"; write_adr "$R/adr-in.md"
  ( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" --adr "$R/adr-in.md" ) >/dev/null 2>&1
  printf '\n**Amended:** x\n' >>"$R/.git/lcars/missions/lcars-20260907-001/prd.md"
  sed -i '' 's/"stage": "align"/"stage": "verify"/' "$R/.git/lcars/missions/lcars-20260907-001/state.json"
  printf '%s' "$R"; }
pills() { ( cd "$LCARS_SRC/web" && python3 -c '
import sys,json; sys.path.insert(0,".")
from lcars_serve import github_adapter as ga
print(json.dumps(ga._pills_from_body(open(sys.argv[1]).read())))' "$1" ); }

hdr "G1 — baseline: estimate.json present, worker on PATH"
R="$(mkv)"; ( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
grep -q '## Estimate' "$p" && ok "Estimate section present" || bad "Estimate MISSING"
note "pills: $(pills "$p")"

hdr "G2 — estimate.json DELETED before the transfer point"
R="$(mkv)"; rm -f "$R/.git/lcars/missions/lcars-20260907-001/estimate.json"
( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >/dev/null 2>&1
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
if grep -q '## Estimate' "$p"; then ok "Estimate survived"
else bad "the refresh PUSHED a body with NO '## Estimate' — the board loses all three pills"; note "pills now: $(pills "$p")"; fi

hdr "G3 — the mission's workerBin points at a binary that is NOT installed"
R="$(mkv)"; M="$R/.git/lcars/missions/lcars-20260907-001"
sed -i '' 's|"stage": "verify"|"stage": "verify",\n  "workerBin": "/nope/not-a-real-cli"|' "$M/state.json"
note "state: $(tr -d '\n' <"$M/state.json"|sed 's/  */ /g'|cut -c1-260)"
( cd "$R" && bash "$RUN_SH" drive --mission lcars-20260907-001 ) >"$WORK/g3.out" 2>&1
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
if grep -q '## Estimate' "$p"; then ok "Estimate survived an unresolvable workerBin"
else bad "an unresolvable workerBin DROPPED the Estimate section from the pushed body"; note "pills: $(pills "$p")"; fi
note "envelope engine: $(tail -1 "$p" | sed 's/.*"engine":\([^,]*\).*/\1/')"

hdr "G4 — NO worker CLI at all on PATH"
R="$(mkv)"
( cd "$R" && env PATH="/usr/bin:/bin" LCARS_GH_BIN="$GH_STUB" LCARS_VERSION_CHECK=0 bash "$RUN_SH" drive --mission lcars-20260907-001 ) >"$WORK/g4.out" 2>&1
note "rc=$?"; tail -3 "$WORK/g4.out" | sed 's/^/    /'
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
if grep -q '## Estimate' "$p"; then ok "Estimate survived with no worker CLI"
else bad "no worker CLI on PATH → the refresh DROPPED the Estimate section"; note "pills: $(pills "$p")"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
