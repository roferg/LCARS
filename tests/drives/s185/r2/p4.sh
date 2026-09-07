#!/usr/bin/env bash
# S185 ROUND 2 — PRIORITY 4: the three cosmetic cures (D2, D3, D4).
set -u
LCARS_SRC=/Users/roganferguson/Projects/LCARS
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
FIX="${TMPDIR:-/tmp}lcars-s185"; FIX="${FIX%/}"
W="$FIX/r2-p4"; rm -rf "$W"; mkdir -p "$W"
SHIM="$W/shim"; mkdir -p "$SHIM"
for b in claude copilot; do printf '#!/usr/bin/env bash\ncase " $* " in *" --version "*|*" -v "*) echo "0.0.0-r2"; exit 0;; esac\nprintf "SPAWN\\tr2p4\\t%s\\n" "$(basename $0)" >> "%s/spend.log"\nexit 0\n' "$FIX" > "$SHIM/$b"; chmod +x "$SHIM/$b"; done
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "FUSE TRIPPED"; exit 99; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; }

mkrepo(){ # dir
  local p="$1"; mkdir -p "$p"; git -C "$p" init -q
  git -C "$p" config user.email t@e.x; git -C "$p" config user.name t
  git -C "$p" config commit.gpgsign false
  printf '# r\n' > "$p/README.md"; git -C "$p" add -A >/dev/null; git -C "$p" commit -qm init >/dev/null
  mkdir -p "$p/.git/lcars/missions"; printf '{\n  "version": 1\n}\n' > "$p/.git/lcars/config.json"
}
plant(){ # repo mid  -> mission dir (2 tickets, initialization)
  local r="$1" mid="$2"; local md="$r/.git/lcars/missions/$2"
  mkdir -p "$md/tickets" "$md/manifests"
  cat > "$md/state.json" <<J
{ "id": "$mid", "missionType": "initialization", "type": "feature",
  "title": "Establish the foundation", "stage": "implement",
  "branch": "lcars/$mid", "base": "main", "workerBin": "claude", "workerCli": "claude" }
J
  cat > "$md/approved-plan.json" <<'P'
[
  { "id": "t-001", "title": "scaffold", "description": "d", "acceptanceCriteria": ["a"], "dependencies": [] },
  { "id": "t-002", "title": "second",  "description": "d", "acceptanceCriteria": ["a"], "dependencies": [] }
]
P
  cp "$md/approved-plan.json" "$md/plan.json"
  cat > "$md/waves.json" <<'WJ'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": null
      }
    ]
  }
]
WJ
  printf '%s' "$md"
}
pvr(){ # repo mid ticket resultfile -> stdout+stderr
  ( cd "$1" && LCARS_VERSION_CHECK=0 LCARS_GIT_BIN="$(command -v git)" \
      bash "$RUN_SH" proof-validate-result-test --mission "$2" --ticket "$3" --result "$4" 2>&1 )
}

echo "############ D2 — the ticket-2 rejection sentence ############"
R="$W/d2"; mkrepo "$R"; MD="$(plant "$R" init-d2)"
cat > "$W/r2.json" <<'RJ'
{ "ticketId": "t-002", "passed": true, "attempts": 1, "summary": "s",
  "newTests": [], "testEdits": [], "flipFlop": "not-applicable",
  "flipFlopReason": "I did not feel like proving it" }
RJ
OUT="$(pvr "$R" init-d2 t-002 "$W/r2.json")"
printf '%s\n' "$OUT" | fold -w 100 -s
echo "$OUT" | grep -q 'PVRC=1' && ok "D2a. ticket 2's waiver is REJECTED (rc 1)" || bad "D2a. NOT rejected"
N="$(printf '%s' "$OUT" | grep -o 't-002' | wc -l | tr -d ' ')"
[ "$N" = 1 ] && ok "D2b. the ticket id 't-002' appears exactly ONCE ($N)" || bad "D2b. ticket id appears $N times"
printf '%s' "$OUT" | grep -q 'not this one t-002' && bad "D2c. the duplicated-id stutter is STILL there" || ok "D2c. no 'not this one <id>' stutter"
printf '%s' "$OUT" | grep -q 'the scaffold ticket is "t-001", not this one\.' && ok "D2d. sentence reads cleanly and names t-001" \
  || { printf '%s' "$OUT" | grep -o 'the scaffold ticket is[^.]*\.' | head -1; bad "D2d. sentence shape unexpected"; }

echo
echo "############ D4 — a present-but-CORRUPT waves.json must FAIL CLOSED ############"
cat > "$W/r1.json" <<'RJ'
{ "ticketId": "t-001", "passed": true, "attempts": 1, "summary": "s",
  "newTests": [], "testEdits": [], "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the test system" }
RJ
for shape in garbage empty-array no-ids truncated html binary-nul object-not-array; do
  R2="$W/d4-$shape"; mkrepo "$R2"; MD2="$(plant "$R2" init-d4)"
  case "$shape" in
    garbage)          printf 'this is not json at all\n' > "$MD2/waves.json" ;;
    empty-array)      printf '[]\n' > "$MD2/waves.json" ;;
    no-ids)           printf '[\n  {\n    "wave": 1,\n    "tickets": []\n  }\n]\n' > "$MD2/waves.json" ;;
    truncated)        printf '[\n  {\n    "wave": 1,\n    "tickets": [\n      {\n' > "$MD2/waves.json" ;;
    html)             printf '<!doctype html><h1>oops</h1>\n' > "$MD2/waves.json" ;;
    binary-nul)       printf '\000\001\002' > "$MD2/waves.json" ;;
    object-not-array) printf '{ "wave": 1, "tickets": [ { "id": "t-001" } ] }\n' > "$MD2/waves.json" ;;
  esac
  # the GOOD approved-plan.json sits right beside it and names t-001 first
  F="$( cd "$R2" && LCARS_VERSION_CHECK=0 bash "$RUN_SH" init-first-ticket-test --mission init-d4 --ticket t-001 2>&1 )"
  O1="$(pvr "$R2" init-d4 t-001 "$W/r1.json")"
  FIRST="$(printf '%s' "$F" | sed -n 's/^FIRST=//p')"
  if printf '%s' "$O1" | grep -q 'PVRC=1'; then
    ok "D4[$shape]. waiver REFUSED (first-ticket resolved to '${FIRST:-<empty>}')"
  else
    bad "D4[$shape]. waiver GRANTED on a corrupt waves.json (first='${FIRST:-<empty>}') <<< FAIL-OPEN"
    printf '%s\n' "$O1" | head -4
  fi
done
# and the message on the corrupt path
R3="$W/d4-msg"; mkrepo "$R3"; MD3="$(plant "$R3" init-d4)"
printf 'not json\n' > "$MD3/waves.json"
pvr "$R3" init-d4 t-002 "$W/r2.json" | fold -w 100 -s

echo
echo "############ D3 — the WORKSPACE-ROOT refusal reaches the captain ############"
mk_ws(){ # dir  workspace?  -> repo
  local p="$1" ws="$2"; local mt="$3"; mkrepo "$p"
  if [ "$ws" = yes ]; then printf 'packages:\n  - "packages/*"\n' > "$p/pnpm-workspace.yaml"
    mkdir -p "$p/packages/a"; printf '{"name":"a"}\n' > "$p/packages/a/package.json"
    git -C "$p" add -A >/dev/null; git -C "$p" commit -qm ws >/dev/null; fi
  local md="$p/.git/lcars/missions/init-d3"; mkdir -p "$md/tickets" "$md/manifests"
  cat > "$md/state.json" <<J
{ "id": "init-d3", $mt "type": "feature",
  "title": "Establish the foundation", "stage": "implement",
  "branch": "lcars/init-d3", "base": "main", "workerBin": "claude", "workerCli": "claude" }
J
  cat > "$md/approved-plan.json" <<'P'
[ { "id": "t-001", "title": "scaffold", "description": "d", "acceptanceCriteria": ["a"], "dependencies": [] } ]
P
  cp "$md/approved-plan.json" "$md/plan.json"
  cat > "$md/waves.json" <<'WJ'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  }
]
WJ
  printf '%s' "$md"
}
for kind in workspace plain; do
  RW="$W/d3-$kind"
  if [ "$kind" = workspace ]; then MDW="$(mk_ws "$RW" yes '"missionType": "initialization",')"
  else MDW="$(mk_ws "$RW" no '')"; fi
  ( cd "$RW" && env PATH="$SHIM:$PATH" LCARS_VERSION_CHECK=0 LCARS_GIT_BIN="$(command -v git)" \
      LCARS_GH_BIN=true LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 \
      bash "$RUN_SH" implement --mission init-d3 ) >"$W/d3-$kind.log" 2>&1
  echo "--- $kind: stage rc=$? ---"
  sed -n '1,60p' "$W/d3-$kind.log"
  if [ -f "$MDW/pending.json" ]; then
    python3 - "$MDW/pending.json" "$W/d3-$kind.human.txt" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
def find(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k in ("humanSummary","question","summary","notify") and isinstance(v,str): yield k,v
            yield from find(v)
    elif isinstance(o,list):
        for x in o: yield from find(x)
out=[]
for k,v in find(d): out.append("%s: %s" % (k,v))
open(sys.argv[2],"w").write("\n\n".join(out))
print("\n\n".join(out))
PY
  else
    echo "(no pending.json — log tail:)"; tail -20 "$W/d3-$kind.log"
  fi
done
echo
printf 'P4: %d ok, %d FAIL\n' "$PASS" "$FAIL"
echo "artifacts: $W"
