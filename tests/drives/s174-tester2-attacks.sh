#!/usr/bin/env bash
# S174 ROUND 2 — INDEPENDENT TESTER ATTACK RIG (not the author's).
# Zero spend. Drives the REAL validator + REAL Verify readout.
#   PLAN=<approved-plan.json> MOCKUP=<mockup.html> bash tests/drives/s174-tester2-attacks.sh
set -u
RUN="${LCARS_RUN_SCRIPT:-$(cd "$(dirname "$0")/../.." && pwd)/skills/lcars-run/run.sh}"
DXM="${DXM:-$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260814-001}"
PLAN="${PLAN:-$DXM/approved-plan.json}"
MOCKUP="${MOCKUP:-$DXM/attachments/attachment-01.html}"
[ -f "$PLAN" ] && [ -f "$MOCKUP" ] || { echo "SKIP: need PLAN + MOCKUP"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"; M="$R/.git/lcars/missions/d-001"
mkdir -p "$M/attachments"; ( cd "$R" && git init -q . && git config user.email t@t && git config user.name t )
cp "$MOCKUP" "$M/attachments/"; MB="$(basename "$MOCKUP")"

reset(){ printf '{ "id": "d-001", "type": "feature", "title": "d", "stage": "plan" }\n' > "$M/state.json"; rm -f "$M/plan.json"; }
verdict(){ reset; ( cd "$R" && bash "$RUN" plan-save --mission d-001 --plan "$1" >/dev/null 2>&1 ) && echo PASS || echo REJECT; }
why(){ reset; ( cd "$R" && bash "$RUN" plan-save --mission d-001 --plan "$1" 2>&1 >/dev/null ) | head -${2:-6}; }

# the REAL Verify readout, driven end to end
verify_out(){ # plan
  local V="$T/vrepo"; rm -rf "$V"; local VM="$V/.git/lcars/missions/v-001"
  mkdir -p "$VM/attachments" "$VM/tickets/t-012"; ( cd "$V" && git init -q . && git config user.email t@t && git config user.name t )
  cp "$MOCKUP" "$VM/attachments/"
  printf '{ "id": "v-001", "type": "feature", "title": "v", "stage": "verify" }\n' > "$VM/state.json"
  python3 - "$1" "$VM/waves.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
json.dump([{"wave":1,"tickets":[{"id":t["id"],"issue":None} for t in p]}],open(sys.argv[2],"w"),indent=2)
PY
  python3 - "$1" "$VM" <<'PY'
import json,os,sys
p=json.load(open(sys.argv[1]))
for t in p:
    d=os.path.join(sys.argv[2],"tickets",t["id"]); os.makedirs(d,exist_ok=True)
    open(os.path.join(d,"result.json"),"w").write('{ "ticketId": "%s", "passed": true, "attempts": 1 }\n'%t["id"])
PY
  cp "$1" "$VM/plan.json"
  ( cd "$V" && LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" bash "$RUN" verify-summary --mission v-001 2>&1 )
}
notdrawn_block(){ verify_out "$1" | sed -n '/NOT IN YOUR DRAWING/,/Everything else can be compared/p'; }
notdrawn_count(){ verify_out "$1" | grep -c '⊘ ' ; }

fails=0
want(){ if [ "$1" = "$2" ]; then printf '  %-6s %s\n' "$2" "$3"; else printf '  %-6s %s   <-- UNEXPECTED (want %s)\n' "$2" "$3" "$1"; fails=$((fails+1)); fi; }
# ROUND 3: this rig now ASSERTS. It was written against round 2 and printed its
# findings as prose; several of those findings were then fixed, and a rig whose
# expectations are comments cannot tell you when a fix dies. Each case below
# carries the verdict it must produce.
#
# THE PLACE-NAME VOCABULARY. Round 3 requires drawnAt to CITE an element id the
# drawing actually has, so every "the builder screen" anchor in this file — the
# transform that beat round 2 — is now a REJECT, and the honest controls cite a
# real id read out of the mockup here, exactly as the harness reads it.
IDS="$(grep -oE "[[:space:]]id=[\"'][^\"']*[\"']" "$MOCKUP" | sed -E "s/.*id=[\"']//; s/[\"']\$//" | grep -E '^[A-Za-z][A-Za-z0-9_:.-]*$' | sort -u)"
PLACE="$(printf '%s\n' "$IDS" | grep -m1 -i screen || printf '%s\n' "$IDS" | head -1)"
[ -n "$PLACE" ] || { echo "SKIP: mockup carries no ids to cite"; exit 0; }
echo "  (drawing vocabulary: $(printf '%s' "$IDS" | tr '\n' ' '))"
echo "  (honest anchors below cite: $PLACE)"

xf(){ MB="$MB" PLACE="$PLACE" python3 - "$PLAN" "$T/x.json" "$1" <<'PY'
import json,os,sys
mb=os.environ["MB"]; mode=sys.argv[3]; PL="#"+os.environ.get("PLACE","screen")
p=json.load(open(sys.argv[1]))
for t in p:
    if not t.get("changesScreenAppearance"): continue
    cs=t["acceptanceCriteria"]
    if   mode=="uniform_drawn":  t["acceptanceCriteria"]=[{"text":c,"drawnAt":"the builder screen"} for c in cs]
    elif mode=="one_char_drawn": t["acceptanceCriteria"]=[{"text":c,"drawnAt":"x"} for c in cs]
    elif mode=="first_then_nv":  t["acceptanceCriteria"]=[{"text":c,"drawnAt":PL} if i==0 else {"text":c,"notVisual":True} for i,c in enumerate(cs)]
    elif mode=="first_then_nd_blankreason":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":PL} if i==0 else {"text":c,"notDrawn":"n/a"} for i,c in enumerate(cs)]
    elif mode=="drawn_bool":     t["acceptanceCriteria"]=[{"text":c,"drawnAt":True} for c in cs]
    elif mode=="drawn_num":      t["acceptanceCriteria"]=[{"text":c,"drawnAt":0} for c in cs]
    elif mode=="drawn_null":     t["acceptanceCriteria"]=[{"text":c,"drawnAt":None} for c in cs]
    elif mode=="drawn_arr":      t["acceptanceCriteria"]=[{"text":c,"drawnAt":[]} for c in cs]
    elif mode=="nd_null":        t["acceptanceCriteria"]=[{"text":c,"drawnAt":PL} if i==0 else {"text":c,"notDrawn":None} for i,c in enumerate(cs)]
    elif mode=="nv_str_true":    t["acceptanceCriteria"]=[{"text":c,"drawnAt":PL} if i==0 else {"text":c,"notVisual":"true"} for i,c in enumerate(cs)]
    elif mode=="nv_false":       t["acceptanceCriteria"]=[{"text":c,"notVisual":False} for c in cs]
    elif mode=="nv_one":         t["acceptanceCriteria"]=[{"text":c,"notVisual":1} for c in cs]
    elif mode=="mixed":          t["acceptanceCriteria"]=[({"text":c,"drawnAt":PL} if i==0 else c) for i,c in enumerate(cs)]
    elif mode=="oneline":
        t["acceptanceCriteria"]=[{"text":c,"drawnAt":"the builder screen"} for c in cs]
json.dump(p,open(sys.argv[2],"w"),indent=2)
PY
echo "$T/x.json"; }

echo "=== S1. MECHANICAL TRANSFORMS OF THE REAL 13-TICKET PLAN ==="
echo "    (each is ONE jq/python map — no human judgement, no reading of the drawing)"
# uniform_drawn is THE attack that beat round 2: one constant, non-blank anchor
# on all 38 criteria, invention intact, Verify list empty, "PLAN: advanced".
# first_then_nv is the KNOWN LIMIT: notVisual is a claim about what a criterion
# IS, and refusing it needs the prose classifier this design replaced.
for spec in "uniform_drawn REJECT" "one_char_drawn REJECT" "mixed REJECT" \
            "first_then_nd_blankreason PASS" "first_then_nv PASS"; do
  m="${spec%% *}"; wantv="${spec##* }"
  f="$(xf "$m")"; v="$(verdict "$f")"; n="$(notdrawn_count "$f")"
  want "$wantv" "$v" "$(printf '%-26s verify-list-entries=%s' "$m" "$n")"
done
# The two that PASS are the two the schema is not allowed to judge, and they are
# NOT the same as round 2's laundering:
#   first_then_nd_blankreason declares 26 criteria un-drawn with a junk reason.
#     It passes, and every one of the 26 lands on the captain's Verify list with
#     its OWN TEXT — so nothing is hidden, which is the entire contract of that
#     field. Judging whether "n/a" is a good reason is prose classification.
#   first_then_nv declares them all notVisual: the KNOWN LIMIT, stated below.
nd_entries="$(notdrawn_count "$(xf first_then_nd_blankreason)")"
if [ "$nd_entries" -gt 0 ]; then
  printf '  %-6s %s\n' "OK" "junk-reason notDrawn is SURFACED, not hidden: $nd_entries Verify entries"
else
  printf '  %-6s %s   <-- UNEXPECTED\n' "BAD" "junk-reason notDrawn produced an EMPTY Verify list"; fails=$((fails+1))
fi
nv_entries="$(notdrawn_count "$(xf first_then_nv)")"
printf '  %-6s %s\n' "NOTE" "notVisual sweep hides everything: $nv_entries Verify entries (the known limit)"

echo
echo "=== S2. TYPE / MALFORMED DECLARATIONS ==="
for m in drawn_bool drawn_num drawn_null drawn_arr nd_null nv_str_true nv_false nv_one; do
  f="$(xf "$m")"; v="$(verdict "$f")"; n="$(notdrawn_count "$f")"
  want REJECT "$v" "$(printf '%-14s verify-list-entries=%s' "$m" "$n")"
done

echo
echo "=== S3. CONSUMER PARITY — strings vs objects, END TO END, no-mockup mission ==="
P="$T/parity"; mkdir -p "$P"
python3 - "$P" <<'PYX'
import json,os,sys
d=sys.argv[1]
TEXTS=[
 'The nav renders data-theme="dark" correctly',
 'The value cell commits the whole SubReading[] as one MetricValue',
 'An error path logs { "code": 1 } and returns }',
 'A criterion ending in a bracket]',
 'Quote-comma sequence ", " and a fake "drawnAt": "x" inside the sentence',
 'Unicode — em dash, \u2298 and \u00e9',
]
def w(path, crit):
    t={"id":"t-001","title":"Builder screen","description":"Build it",
       "acceptanceCriteria":crit,"estimatedReadLoc":10,"estimatedTestLoc":10,
       "estimatedNewLoc":10,"dependencies":[],"rationale":"because"}
    # CANONICAL shape: one field per line, criteria as an INLINE array
    lines=["[","  {"]
    keys=["id","title","description","acceptanceCriteria","estimatedReadLoc","estimatedTestLoc","estimatedNewLoc","dependencies","rationale"]
    for i,k in enumerate(keys):
        lines.append('    "%s": %s%s'%(k,json.dumps(t[k]),"," if i<len(keys)-1 else ""))
    lines+=["  }","]"]
    open(path,"w").write("\n".join(lines)+"\n")
w(os.path.join(d,"A-strings.json"),TEXTS)
w(os.path.join(d,"B-objects.json"),[{"text":x,"drawnAt":"the builder screen, row %d"%i} for i,x in enumerate(TEXTS)])
PYX
python3 -c "import json,sys;[json.load(open(sys.argv[1]+'/'+f)) for f in ['A-strings.json','B-objects.json']];print('  (both files are valid JSON)')" "$P"

mk_mission(){ # dir-suffix plan stage
  local V="$T/pr$1"; rm -rf "$V"; local VM="$V/.git/lcars/missions/p-001"
  mkdir -p "$VM"; ( cd "$V" && git init -q . && git config user.email t@t && git config user.name t
    git commit -q --allow-empty -m init )
  printf '{ "id": "p-001", "type": "feature", "title": "p", "stage": "%s", "githubIssue": 42, "branch": "lcars/p-001", "base": "main" }\n' "$3" > "$VM/state.json"
  cp "$2" "$VM/plan.json"; cp "$2" "$VM/approved-plan.json"
  printf '# prd\n' > "$VM/prd.md"
  printf '%s' "$V"
}
cat > "$T/gh" <<'EOF'
#!/usr/bin/env bash
printf '=== gh %s\n' "$*" >>"$GH_LOG"
echo "https://github.com/o/r/issues/7"
EOF
chmod +x "$T/gh"
cat > "$T/worker" <<'EOF'
#!/usr/bin/env bash
p=""; while [ $# -gt 0 ]; do case "$1" in -p) p="${2:-}"; shift 2;; *) shift;; esac; done
printf '%s\n' "$p" >> "$WORKER_PROMPTS"
printf '{"ok":true}\n'
EOF
chmod +x "$T/worker"

for form in A-strings B-objects; do
  # 1. GitHub sub-issue body (schedule)
  V="$(mk_mission "$form" "$P/$form.json" schedule)"
  GH_LOG="$T/$form.gh.log"; : > "$GH_LOG"
  ( cd "$V" && GH_LOG="$GH_LOG" LCARS_GH_BIN="$T/gh" LCARS_GIT_BIN="$(command -v git)" \
      bash "$RUN" schedule --mission p-001 >/dev/null 2>&1 )
  # 2. Implementer prompt
  V2="$(mk_mission "$form-i" "$P/$form.json" implement)"
  printf '[ { "wave": 1, "tickets": ["t-001"] } ]\n' > "$V2/.git/lcars/missions/p-001/waves.json"
  WORKER_PROMPTS="$T/$form.prompt"; : > "$WORKER_PROMPTS"
  ( cd "$V2" && WORKER_PROMPTS="$WORKER_PROMPTS" LCARS_WORKER_CLI=claude LCARS_WORKER_BIN="$T/worker" \
      LCARS_GH_BIN="$T/gh" LCARS_GIT_BIN="$(command -v git)" \
      bash "$RUN" implement-ticket --mission p-001 --ticket t-001 >/dev/null 2>&1 )
  # 3. author's own probe hook (cross-check)
  LCARS_CONSUMER_PLAN="$P/$form.json" bash "$RUN" consumer-probe-test > "$T/$form.probe" 2>/dev/null
done
# NORMALISE THE VOLATILE PATHS BEFORE COMPARING. Each form is driven in its own
# mktemp repo and each spawn gets its own scratch dir, so a raw diff reports
# DIFFERS on the temp paths alone — which is a false alarm loud enough to hide a
# REAL difference in the criteria. Strip /var|/tmp paths and the per-form repo
# name; everything that remains is content.
norm(){ sed -E -e "s#(/private)?/(var|tmp)/[^ )\"]*#<TMP>#g" \
                -e "s#pr(A-strings|B-objects)(-i)?#<REPO>#g" \
                -e "s#(A-strings|B-objects)#<FORM>#g" "$1"; }
for f in A-strings B-objects; do
  norm "$T/$f.gh.log" > "$T/$f.gh.norm"
  norm "$T/$f.prompt" > "$T/$f.prompt.norm"
  norm "$T/$f.probe"  > "$T/$f.probe.norm"
done
d1=OK; d2=OK; d3=OK
diff -q "$T/A-strings.gh.norm"     "$T/B-objects.gh.norm"     >/dev/null || d1=DIFFERS
diff -q "$T/A-strings.prompt.norm" "$T/B-objects.prompt.norm" >/dev/null || d2=DIFFERS
diff -q "$T/A-strings.probe.norm"  "$T/B-objects.probe.norm"  >/dev/null || d3=DIFFERS
for pair in "gh sub-issue body:$d1" "implementer prompt:$d2" "consumer probe:$d3"; do
  want OK "${pair##*:}" "consumer parity — ${pair%%:*}"
done
printf '  gh sub-issue body        : %s\n' "$d1"
printf '  implementer prompt       : %s\n' "$d2"
printf '  author consumer-probe    : %s\n' "$d3"
[ "$d1" = DIFFERS ] && diff "$T/A-strings.gh.norm" "$T/B-objects.gh.norm" | head -20
[ "$d2" = DIFFERS ] && diff "$T/A-strings.prompt.norm" "$T/B-objects.prompt.norm" | head -30
[ "$d3" = DIFFERS ] && diff "$T/A-strings.probe.norm" "$T/B-objects.probe.norm" | head -20
echo "  --- schema keys leaking into human/worker-facing output? ---"
# NB one of the fixture CRITERIA deliberately contains the words
# `"drawnAt": "x"` inside its own sentence, to prove a fake declaration in the
# prose is not read as a real one. That line is excluded here — a leak is a
# SCHEMA key rendered as structure, not a criterion that happens to quote one.
for f in "$T/B-objects.gh.log" "$T/B-objects.prompt" "$T/B-objects.probe"; do
  hits="$(grep -E '"?(text|drawnAt|notDrawn|notVisual)"?[[:space:]]*[:|]' "$f" 2>/dev/null \
          | grep -vc 'inside the sentence' || true)"
  printf '    %-28s key-leak-lines=%s\n' "$(basename "$f")" "$hits"
  want 0 "$hits" "no schema key leaks into $(basename "$f")"
done
echo "  --- implementer prompt criteria block (objects form) ---"
sed -n '/Acceptance criteria/,/^$/p' "$T/B-objects.prompt" | head -12
echo "  --- did anything actually get written? gh log lines: $(wc -l < "$T/B-objects.gh.log"), prompt bytes: $(wc -c < "$T/B-objects.prompt") ---"

echo
echo "=== S4/S5. MALFORMED + TYPE-CONFUSED DECLARATIONS (single screen-changing ticket) ==="
mk1(){ printf '[\n  {\n    "id": "t-001",\n    "title": "B",\n    "description": "d",\n    "acceptanceCriteria": %s,\n    "estimatedReadLoc": 10,\n    "estimatedTestLoc": 10,\n    "estimatedNewLoc": 10,\n    "dependencies": [],\n    "rationale": "r",\n    "changesScreenAppearance": true\n  }\n]\n' "$1" > "$T/one.json"
  want "$2" "$(verdict "$T/one.json")" "$3"; }
mk1 '[{"text": "A sub-value editor", "drawnAt": "'"$PLACE"', the value cell"}]'          PASS   'honest object citing a real place (control)'
mk1 '[{"text": "A sub-value editor", "drawnAt": "the builder screen"}]'                 REJECT 'ROUND 3: a constant anchor naming NO place in the drawing'
mk1 '[{"text": "A sub-value editor", "drawnAt": "x"}]'                                  REJECT 'one-character anchor'
mk1 '[{"text": "A sub-value editor", "drawnAt": "x", "drawnAt": "'"$PLACE"'"}]'         REJECT 'duplicate drawnAt key'
mk1 '["A sub-value editor\", \"drawnAt\": \"the builder screen"]'                       REJECT 'sed a fake declaration into a plain string (ROUND 1 ATTACK)'
mk1 '["A sub-value editor with a \"drawnAt\": \"the screen\" note"]'                     REJECT 'plain string quoting drawnAt in the sentence'
mk1 '[{"text": "Editor \" , \"drawnAt\" : \"screen", "notVisual": true}]'                REJECT 'fake declaration inside text, real decl = notVisual'
mk1 '[{"drawnAt": "'"$PLACE"'"}]'                                                       REJECT 'object with no text'
mk1 '[{"text": "", "drawnAt": "'"$PLACE"'"}]'                                           REJECT 'object with empty text'
mk1 '[{"text": "Editor", "drawnAt": "   "}]'                                            REJECT 'whitespace-only anchor'
mk1 '[{"text": "Editor", "DrawnAt": "'"$PLACE"'"}]'                                     REJECT 'case-variant key'
mk1 '[{"text": "Editor", "drawn_at": "'"$PLACE"'"}]'                                    REJECT 'snake_case key'
mk1 '[{"text": "Editor", "drawnAt": {"screen": "b"}}]'                                  REJECT 'nested-object anchor'
mk1 '[{"text": "Editor", "drawnAt": "'"$PLACE"'"}, "a legacy plain string"]'            REJECT 'mixed object + string'
mk1 '["a legacy plain string", {"text": "Editor", "drawnAt": "'"$PLACE"'"}]'            REJECT 'mixed string + object'
mk1 '[{"text": "Editor", "drawnAt": "'"$PLACE"'", "notes": "x"}]'                       PASS   'extra unknown key beside a valid decl'
echo "  --- ROUND 2 DEFECT D3, now cured: JSON values that SAY there is no anchor ---"
mk1 '[{"text": "Editor", "drawnAt": null}]'                                             REJECT 'JSON null anchor'
mk1 '[{"text": "Editor", "drawnAt": true}]'                                             REJECT 'JSON true anchor'
mk1 '[{"text": "Editor", "drawnAt": 0}]'                                                REJECT 'JSON 0 anchor'
mk1 '[{"text": "Editor", "drawnAt": "\t"}]'                                             REJECT 'JSON \t (whitespace-only) anchor'
mk1 '[{"text": "Editor", "drawnAt": "\n"}]'                                             REJECT 'JSON \n (whitespace-only) anchor'
mk1 '[{"text": "Editor", "notDrawn": null}]'                                            REJECT 'JSON null REASON (an empty Verify entry)'
echo "  --- ROUND 3: the vocabulary is published, so honest wording is free ---"
mk1 '[{"text": "Editor", "drawnAt": "#'"$PLACE"' — right column"}]'                     PASS   'hash-prefixed, em-dash, free wording'
mk1 '[{"text": "Editor", "drawnAt": "the row in '"$PLACE"' (right column)"}]'           PASS   'name mid-sentence, parenthesised detail'

echo
echo "  KNOWN LIMIT, stated as a measurement: a real place name is NOT proof the"
echo "  description matches it, and a visible control mislabelled notVisual still"
echo "  passes. The fence stops \"never opened the drawing\"; it cannot stop"
echo "  \"opened it and lied\". Plan Review owns both, and is briefed on both."

echo
if [ "$fails" -eq 0 ]; then echo "tester2 rig: all expectations met"; else echo "tester2 rig: $fails expectation(s) MISSED"; fi
[ "$fails" -eq 0 ]
