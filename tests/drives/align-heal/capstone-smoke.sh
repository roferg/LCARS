#!/usr/bin/env bash
# Cheap plumbing smoke for C2 — NO workers, NO daemon, NO spend.
#
# Proves the gate loop's SHAPE with a scripted driver: that capstone.py reads
# state.json/pending.json, matches a gate question against the record, hands the
# recorded answer to the REAL respond.sh, re-drives, and reports. The matcher
# itself is proven separately by `standin.py smoke`.
#
#   bash capstone-smoke.sh
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
REPO="${LCARS_DRIVE_REPO:-/Users/roganferguson/Projects/LCARS}"
SRC="${LCARS_DRIVE_RECORD_DIR:-$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260829-002}"
OUT="$SD/runs/smoke-c2"; rm -rf "$OUT"; mkdir -p "$OUT"
T="$OUT/target"; mkdir -p "$T"
( cd "$T" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > README.md && git add -A && git commit -qm init \
  && mkdir -p .git/lcars/missions && printf '{"testCommand":"true"}\n' > .git/lcars/config.json )

MID=smoke-1; MD="$T/.git/lcars/missions/$MID"; mkdir -p "$MD"
printf '{"id":"%s","title":"t","stage":"validate","awaitingHuman":true}\n' "$MID" > "$MD/state.json"
# A gate whose answer IS on the record (question 6, verbatim from prd.md).
cat > "$MD/pending.json" <<'EOF'
{"stage":"validate","questions":["Is the draft stored locally only, or synced?"]}
EOF

# A SCRIPTED driver: pass 1 leaves the gate up (respond.sh clears it), pass 2
# advances to schedule and stops clean. Stands in for run.sh only.
FAKE="$OUT/fake-lcars"; mkdir -p "$FAKE/skills/lcars-run"
cat > "$FAKE/skills/lcars-run/run.sh" <<'EOF'
#!/usr/bin/env bash
MD="$(git rev-parse --git-common-dir)/lcars/missions/${3:-}"
N="$MD/.smokecount"; C=$(( $(cat "$N" 2>/dev/null || echo 0) + 1 )); echo "$C" > "$N"
echo "fake driver pass $C"
if [ "$C" -ge 2 ]; then
  printf '{"id":"smoke-1","title":"t","stage":"schedule"}\n' > "$MD/state.json"
fi
EOF
chmod +x "$FAKE/skills/lcars-run/run.sh"
ln -snf "$REPO/skills/lcars-respond" "$FAKE/skills/lcars-respond"

export LCARS_GH_BIN="$SD/fake-gh"
python3 "$SD/capstone.py" "$T" "$MID" "$OUT" "$FAKE" "$SRC"; RC=$?

echo; echo "--- capstone.json ---"; cat "$OUT/capstone.json"
echo; echo "--- checks ---"
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  PASS $1"; else echo "  FAIL $1: got '$2' want '$3'"; fail=1; fi; }
chk "exit 0 (no human answers)" "$RC" 0
chk "stage reached"      "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["stageReached"])' "$OUT/capstone.json")" schedule
chk "human answers"      "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["humanAnswersRequired"])' "$OUT/capstone.json")" 0
chk "gates answered"     "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["gatesAnsweredFromRecord"])' "$OUT/capstone.json")" 1
chk "gate cleared by the REAL respond.sh" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("awaitingHuman"))' "$MD/state.json")" None
A="$(grep -c 'Local only' "$MD/answers.json" 2>/dev/null || echo 0)"
if [ "$A" -ge 1 ]; then echo "  PASS answer recorded on disk ($A hit(s))"; else echo "  FAIL answer not in answers.json"; fail=1; fi
echo "  --- gate answer sent: $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["gates"][0]["answer"])' "$OUT/capstone.json")"

# ── scenario 2: a gate the record CANNOT settle must FAIL the run ──────────
echo; echo "=== scenario 2 — unrecorded gate question ==="
O2="$SD/runs/smoke-c2b"; rm -rf "$O2"; mkdir -p "$O2"
T2="$O2/target"; mkdir -p "$T2"
( cd "$T2" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > README.md && git add -A && git commit -qm init && mkdir -p .git/lcars/missions )
M2="$T2/.git/lcars/missions/$MID"; mkdir -p "$M2"
printf '{"id":"%s","title":"t","stage":"plan","awaitingHuman":true}\n' "$MID" > "$M2/state.json"
cat > "$M2/pending.json" <<'EOF'
{"stage":"plan","questions":["Which cloud region should the MBR builder's data be stored in, and who owns the encryption keys?"]}
EOF
python3 "$SD/capstone.py" "$T2" "$MID" "$O2" "$FAKE" "$SRC"; RC2=$?
chk "exit 1 on an unrecorded gate" "$RC2" 1
chk "human answers = 1" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["humanAnswersRequired"])' "$O2/capstone.json")" 1
chk "gate NOT answered"  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["gatesAnsweredFromRecord"])' "$O2/capstone.json")" 0
if [ -f "$M2/answers.json" ]; then echo "  FAIL respond.sh was called on an unrecorded gate"; fail=1; else echo "  PASS respond.sh never called"; fi
grep -q 'NOT IN THE RECORD' "$O2/capstone.json" && echo "  PASS failure named in capstone.json" || { echo "  FAIL failure not named"; fail=1; }

echo
[ "$fail" = 0 ] && echo "SMOKE C2: PASS" || echo "SMOKE C2: FAIL"
exit $fail
