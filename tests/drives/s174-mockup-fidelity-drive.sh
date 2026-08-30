#!/usr/bin/env bash
# S174 adversarial drive — mockup-fidelity gate, run from OUTSIDE the author's suite.
#
# Zero-spend. Drives the REAL validator (run.sh plan-save) against the REAL
# 13-ticket approved plan that caused this round, plus mechanical bypasses a
# planner could apply with one sed. Written by the S174 tester against the ROUND
# 1 string rule, where the last three PASSED; kept and updated for the round 2
# schema, because those bypasses are the regressions that matter.
#
# ROUND 2 CHANGED THE SHAPE. The declaration is no longer a phrase inside the
# criterion; it is a FIELD beside it. On a changesScreenAppearance:true ticket of
# a mockup Mission each acceptanceCriteria entry is an object carrying its text
# and exactly one of `drawnAt` / `notDrawn` / `notVisual`. Every string transform
# below therefore fails for the same reason: none of them fills a slot.
#
#   PLAN=<path to a mockup-born approved-plan.json>  MOCKUP=<path to the .html>
#   bash tests/drives/s174-mockup-fidelity-drive.sh
#
# Defaults point at the DX-Scorecard mission if it is on this machine.
set -u
RUN="${LCARS_RUN_SCRIPT:-$(cd "$(dirname "$0")/../.." && pwd)/skills/lcars-run/run.sh}"
DXM="${DXM:-$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260814-001}"
PLAN="${PLAN:-$DXM/approved-plan.json}"
MOCKUP="${MOCKUP:-$DXM/attachments/attachment-01.html}"
[ -f "$PLAN" ] && [ -f "$MOCKUP" ] || { echo "SKIP: need PLAN + MOCKUP"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; M="$R/.git/lcars/missions/d-001"
mkdir -p "$M/attachments"; (cd "$R" && git init -q . && git config user.email t@t && git config user.name t)
cp "$MOCKUP" "$M/attachments/"; MB="$(basename "$MOCKUP")"
reset(){ printf '{ "id": "d-001", "type": "feature", "title": "d", "stage": "plan" }\n' > "$M/state.json"
         rm -f "$M/plan.json"; }
verdict(){ reset; ( cd "$R" && bash "$RUN" plan-save --mission d-001 --plan "$1" >/dev/null 2>&1 ) && echo PASS || echo REJECT; }
fails=0
want(){ # want-verdict got-verdict label
  if [ "$1" = "$2" ]; then printf '  %-6s %-56s [want %s]\n' "$2" "$3" "$1"
  else printf '  %-6s %-56s [want %s]  <-- FAIL\n' "$2" "$3" "$1"; fails=$((fails+1)); fi
}

xform(){ MB="$MB" MOCKUP_PATH="$MOCKUP" python3 - "$PLAN" "$T/v.json" "$1" <<'PY'
import json,os,sys
mb=os.environ["MB"]; mode=sys.argv[3]
p=json.load(open(sys.argv[1]))
INVENT="A manual cohort is edited via the ManualValueEditor"
# ROUND 3: drawnAt must CITE a place the drawing HAS. Read the vocabulary out of
# the drawing itself, exactly as the harness does.
import re as _re0
IDS=sorted(set(_re0.findall(r'id="([A-Za-z][A-Za-z0-9_:.-]*)"', open(os.environ["MOCKUP_PATH"]).read())))
HOME=(IDS[0] if IDS else "screen")
for t in p:
    if not t.get("changesScreenAppearance"): continue
    cs=t["acceptanceCriteria"]
    # --- the five STRING transforms (round 1 defects D1/D2/D3) --------------
    if   mode=="bare":   t["acceptanceCriteria"]=["The sidebar matches "+mb for _ in cs]
    elif mode=="suffix": t["acceptanceCriteria"]=[c+" ("+mb+"'s screen)" for c in cs]
    elif mode=="junk":   t["acceptanceCriteria"]=[c+" "+mb+"'s x" for c in cs]
    elif mode=="mark":   t["acceptanceCriteria"]=[c if i==0 else "NOT DRAWN: "+c for i,c in enumerate(cs)]
    elif mode=="bury":   t["acceptanceCriteria"]=["Reproduces "+mb+"'s #screen-builder value cell"]+[c+" NOT DRAWN: minor" for c in cs[1:]]
    # --- the SCHEMA transforms ---------------------------------------------
    # "declared": what a planner who read the contract writes. A criterion that
    # named the drawing becomes drawnAt; the measured invention becomes
    # notDrawn; the rest are notVisual.
    elif mode=="declared":
        out=[]
        for c in cs:
            if c.startswith(INVENT): out.append({"text":c,"notDrawn":"the drawing shows the cohort value as read-only text; it draws no sub-value editor"})
            elif mb in c:
                import re as _re
                hit=[i for i in IDS if _re.search(r"(?<![A-Za-z0-9_.:-])"+_re.escape(i)+r"(?![A-Za-z0-9_.:-])", c)]
                out.append({"text":c,"drawnAt":("#"+(hit[0] if hit else HOME))+", the surface this criterion names"})
            else:                    out.append({"text":c,"notVisual":True})
        t["acceptanceCriteria"]=out
    # "slots-empty": every slot present but blank — the schema equivalent of the
    # one-sed paste. A slot is not a declaration.
    elif mode=="slots_empty":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":""} for c in cs]
    # ROUND 3 — THE ATTACK THAT BEAT ROUND 2, and the reason a rig that only asks
    # questions which pass is not a rig. One jq line: a NON-BLANK CONSTANT anchor
    # on every criterion. It passed the whole real plan with the invention intact
    # and the Verify list empty.
    elif mode=="constant_anchor":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":"the builder screen"} for c in cs]
    elif mode=="one_char_anchor":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":"x"} for c in cs]
    # …and the JSON-EMPTY family: valid JSON that explicitly says there is no
    # anchor, accepted as one by a byte-level blank check.
    elif mode=="anchor_null":  t["acceptanceCriteria"]=[{"text":c,"drawnAt":None} for c in cs]
    elif mode=="anchor_true":  t["acceptanceCriteria"]=[{"text":c,"drawnAt":True} for c in cs]
    elif mode=="anchor_zero":  t["acceptanceCriteria"]=[{"text":c,"drawnAt":0} for c in cs]
    elif mode=="anchor_tab":   t["acceptanceCriteria"]=[{"text":c,"drawnAt":"\t"} for c in cs]
    elif mode=="anchor_arr":   t["acceptanceCriteria"]=[{"text":c,"drawnAt":[]} for c in cs]
    elif mode=="nd_null":      t["acceptanceCriteria"]=[{"text":c,"drawnAt":"#screen-builder"} if i==0 else {"text":c,"notDrawn":None} for i,c in enumerate(cs)]
    # the mechanical "declare it all away but one" transform
    elif mode=="first_then_nv":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":"#screen-builder"} if i==0 else {"text":c,"notVisual":True} for i,c in enumerate(cs)]
    # "double": two declarations on one criterion — hedging instead of deciding.
    elif mode=="double":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":"#screen","notVisual":True} for c in cs]
    # "all-notvisual": declare the whole screen away.
    elif mode=="all_notvisual":
        t["acceptanceCriteria"]=[{"text":c,"notVisual":True} for c in cs]
json.dump(p,open(sys.argv[2],"w"),indent=2)
PY
echo "$T/v.json"; }

echo "S174 mockup-fidelity drive"
want REJECT "$(verdict "$PLAN")"                    "the REAL plan, verbatim (t-012's invention intact)"
want REJECT "$(verdict "$(xform bare)")"            "every criterion = bare filename, no anchor"
want REJECT "$(verdict "$(xform suffix)")"          "D1 one-sed suffix \"(<mockup>'s screen)\" on each"
want REJECT "$(verdict "$(xform junk)")"            "D3 one-sed junk anchor \"<mockup>'s x\" on each"
want REJECT "$(verdict "$(xform mark)")"            "D2 \"NOT DRAWN: \" prefixed to every criterion"
want REJECT "$(verdict "$(xform bury)")"            "D2 \"NOT DRAWN: minor\" buried at the END"
want REJECT "$(verdict "$(xform slots_empty)")"     "every drawnAt present but BLANK"
want REJECT "$(verdict "$(xform double)")"          "two declarations on every criterion"
want REJECT "$(verdict "$(xform all_notvisual)")"   "every criterion notVisual (screen declared away)"
want REJECT "$(verdict "$(xform constant_anchor)")" "R3 CONSTANT anchor on all 38 (the jq line that beat round 2)"
want REJECT "$(verdict "$(xform one_char_anchor)")" "R3 one-character anchor on all 38"
want REJECT "$(verdict "$(xform anchor_null)")"     "R3 drawnAt: null on all 38"
want REJECT "$(verdict "$(xform anchor_true)")"     "R3 drawnAt: true on all 38"
want REJECT "$(verdict "$(xform anchor_zero)")"     "R3 drawnAt: 0 on all 38"
want REJECT "$(verdict "$(xform anchor_tab)")"      "R3 drawnAt: a JSON tab on all 38"
want REJECT "$(verdict "$(xform anchor_arr)")"      "R3 drawnAt: [] on all 38"
want REJECT "$(verdict "$(xform nd_null)")"         "R3 notDrawn: null (an empty Verify entry)"
want PASS   "$(verdict "$(xform declared)")"        "the real plan, honestly DECLARED"

echo
ALLIDS="$(grep -o 'id="[A-Za-z][A-Za-z0-9_:.-]*"' "$MOCKUP" | sed 's/id="//; s/"$//' | sort -u)"
FIRSTID="$(printf '%s\n' "$ALLIDS" | grep -m1 -i 'screen' || printf '%s\n' "$ALLIDS" | head -1)"
echo "  honest phrasings a real planner writes, each CITING a place the drawing has"
echo "  (want PASS — the vocabulary is published, the wording around it is free):"

while IFS= read -r a; do
  [ -n "$a" ] || continue
  python3 - "$T/one.json" "$a" <<'PY'
import json,sys
json.dump([{"id":"t-001","title":"T","description":"d",
 "acceptanceCriteria":[{"text":"The cohort cell renders every sub-reading","drawnAt":sys.argv[2]}],
 "changesScreenAppearance":True,"estimatedReadLoc":10,"estimatedTestLoc":10,
 "estimatedNewLoc":10,"dependencies":[],"rationale":"r"}],open(sys.argv[1],"w"),indent=2)
PY
  want PASS "$(verdict "$T/one.json")" "$a"
done <<EOF
#screen-builder cohort row
$FIRSTID, the cohort value cell
the cohort row in #$FIRSTID
section #$FIRSTID, right column
the cohort value cell of a KPI row ($FIRSTID)
$FIRSTID — right column, under the value
builder -> KPI row -> value cell in $FIRSTID
EOF

echo
# The mechanical "declare it all away but one" transform. It PASSES, and that is
# the known limit stated as a measurement rather than a claim: notVisual is a
# declaration about what a criterion IS, and refusing it needs a prose
# classifier — the thing this whole design replaced. The Verify list stays
# empty, so the mitigation is Plan Review, which is told to hunt exactly this.
want PASS "$(verdict "$(xform first_then_nv)")" "KNOWN LIMIT: first drawnAt, every other criterion notVisual"

echo
echo "  KNOWN LIMIT (not a failure): a VISIBLE control mislabelled notVisual passes"
echo "  here. Nothing reads the prose to second-guess a declaration — that is a"
echo "  classifier, and a classifier is what this design replaced. Plan Review is"
echo "  told to hunt exactly this, and it is the one lie the schema cannot catch."
echo
if [ "$fails" -eq 0 ]; then echo "drive: all expectations met"; else echo "drive: $fails expectation(s) MISSED"; fi
[ "$fails" -eq 0 ]
