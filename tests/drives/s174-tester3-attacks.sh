#!/usr/bin/env bash
# S174 ROUND 3 — TESTER 3 (fresh, adversarial). ZERO SPEND: touches no worker.
#
# Drives the REAL validator over the REAL 13-ticket approved plan and the REAL
# drawing of mission lcars-20260814-001 (DX-Scorecard). Every case below is ONE
# jq line: no human judgement, nobody opens the drawing.
#
# HEADLINE: the round-3 fence did NOT stop the transform that killed rounds 1
# and 2. `drawnAt: "the builder screen"` -> `drawnAt: "#screen-builder"` is a
# one-word substitution, and the id list is printed to the planner up front AND
# re-printed in every rejection message.
#
# Requires jq. Skips (exit 0) when the real mission is not on this machine.
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
REAL="${LCARS_S174_MISSION:-$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260814-001}"
PLAN="$REAL/approved-plan.json"; DRAW="$REAL/attachments/attachment-01.html"
command -v jq >/dev/null || { echo "drive: no jq — skipped"; exit 0; }
[ -f "$PLAN" ] && [ -f "$DRAW" ] || { echo "drive: real mission not present — skipped"; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BAD=0

mk() { local r; r="$(mktemp -d "$TMP/repo.XXXXXX")"
  ( cd "$r" && git init -q && git config user.email t@t && git config user.name t )
  local m="$r/.git/lcars/missions/test-001"; mkdir -p "$m/attachments"
  printf '{ "id": "test-001", "type": "feature", "title": "t", "stage": "plan" }\n' >"$m/state.json"
  cp "$DRAW" "$m/attachments/attachment-01.html"; echo "$r"; }

# case <expect pass|reject> <label> <jq program>
case_() { local want="$1" label="$2" prog="$3" r rc nd
  r="$(mk)"; jq "$prog" "$PLAN" >"$r/p.json" || { echo "  JQ-ERR $label"; BAD=$((BAD+1)); return; }
  ( cd "$r" && bash "$SCRIPT" plan-save --mission test-001 --plan p.json ) >/dev/null 2>&1; rc=$?
  nd="$(jq '[.[].acceptanceCriteria[]?|objects|select(has("notDrawn"))]|length' "$r/p.json")"
  local got; [ "$rc" -eq 0 ] && got=pass || got=reject
  printf '  %-6s %-44s verify-list=%s %s\n' "$got" "$label" "$nd" \
    "$([ "$got" = "$want" ] && echo "(as measured)" || { BAD=$((BAD+1)); echo "<< CHANGED"; })"; }

CSA='if .changesScreenAppearance==true then .acceptanceCriteria|=map('; E=') else . end'

echo "=== A. THE KILL — one jq line, constant real id, invention intact ==="
case_ pass   "constant #screen-builder on all 38 criteria" "map($CSA {text:.,drawnAt:\"#screen-builder\"} $E)"
case_ pass   "bare screen-builder, no #"                   "map($CSA {text:.,drawnAt:\"screen-builder\"} $E)"
case_ pass   "id bolted onto round-2's dead sentence"      "map($CSA {text:.,drawnAt:\"the builder screen (screen-builder)\"} $E)"
case_ pass   "id inside an unrelated URL"                  "map($CSA {text:.,drawnAt:\"https://x.test/screen-builder/docs\"} $E)"
case_ pass   "all twelve ids concatenated as one anchor"   "map($CSA {text:.,drawnAt:\"screen-start screen-builder screen-collect modal-lock automateBtn bulkBar collect-list continueBtn modal-discard modal-unlock pullBar themeBtn\"} $E)"

echo "=== B. THE CHEAPER KILL — changesScreenAppearance:false is unchecked ==="
case_ pass   "csa:=false on the villain t-012 only"        'map(if .id=="t-012" then .changesScreenAppearance=false else (if .changesScreenAppearance==true then .acceptanceCriteria|=map({text:.,drawnAt:"#screen-builder"}) else . end) end)'
case_ pass   "csa:=true on t-001 ONLY, 12 tickets exempt"  'map(.changesScreenAppearance=(.id=="t-001"))|map(if .changesScreenAppearance then .acceptanceCriteria|=map({text:.,drawnAt:"#screen-builder"}) else . end)'
case_ reject "csa:=false on ALL (the one guard there is)"  'map(.changesScreenAppearance=false)'

echo "=== C. notVisual at scale keeps the Verify list empty ==="
case_ pass   "1 anchor per ticket, other 26 notVisual"     'map(if .changesScreenAppearance==true then .acceptanceCriteria|=([.[0]|{text:.,drawnAt:"#screen-builder"}]+(.[1:]|map({text:.,notVisual:true}))) else . end)'
case_ reject "notVisual on EVERY criterion"                "map($CSA {text:.,notVisual:true} $E)"
case_ reject "notDrawn junk reason on every criterion"     "map($CSA {text:.,notDrawn:\"n/a\"} $E)"

echo "=== D. the fence itself is mechanically sound (these all reject) ==="
for bad in '"#screen-builders"' '"pre-screen-builder"' '"SCREEN-BUILDER"' '"screen_builder"' 'null' 'true' '0' '"\t"' '["#screen-builder"]' '{id:"screen-builder"}'; do
  case_ reject "drawnAt=$bad" "map($CSA {text:.,drawnAt:$bad} $E)"
done
case_ reject "real id in TEXT, junk in drawnAt"            "map($CSA {text:(.+\" #screen-builder\"),drawnAt:\"the builder screen\"} $E)"
case_ reject "text empty, drawnAt real"                    "map($CSA {text:\"\",drawnAt:\"#screen-builder\"} $E)"

echo
[ "$BAD" -eq 0 ] && echo "tester3 rig: every case behaves as MEASURED on 2026-08-25 (the kills still kill)" \
                 || echo "tester3 rig: $BAD case(s) changed behaviour since 2026-08-25"
exit 0
