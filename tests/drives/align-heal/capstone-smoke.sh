#!/usr/bin/env bash
# Cheap plumbing smoke for C2 — NO workers, NO daemon, NO spend.
#
# Proves the gate loop's SHAPE with a scripted driver: that capstone.py reads
# state.json/pending.json, matches a gate question against the record, hands the
# recorded answer to the REAL respond.sh, re-drives, and reports. The matcher
# itself is proven separately by `standin.py smoke`.
#
#   bash capstone-smoke.sh
#
# Five scenarios, all free:
#   1  a pre-Schedule gate the record SETTLES  → answered from the record
#   2  a pre-Schedule gate it CANNOT settle    → NO-MATCH, run FAILS, named
#   3  the VERIFY ship gate                    → the stand-in APPROVES (real
#      approve.sh, real git push into a throwaway bare origin, faked forge)
#   4  an IMPLEMENT gate past Schedule         → left parked, never answered
#   5  the ENGINE knob                         → matrix.sh --dry-run, both cells
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

# ── scenario 3 — PAST SCHEDULE: the VERIFY ship gate, approved ─────────────
# The one thing the stand-in may do past Schedule. Everything here is the REAL
# code path except the forge and the worker: a real `lcars approve`, a real
# `git push` — into a THROWAWAY BARE ORIGIN inside this run dir — and a real
# host-adapter `pr merge`, over fake-gh. No network, no token, no GitHub.
echo; echo "=== scenario 3 — Verify ship gate: the stand-in approves ==="
O3="$SD/runs/smoke-c2c"; rm -rf "$O3"; mkdir -p "$O3"
T3="$O3/target"; ORIGIN3="$O3/origin.git"; mkdir -p "$T3"
git init -q --bare "$ORIGIN3"
( cd "$T3" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > README.md && git add -A && git commit -qm init \
  && git branch -M main \
  && git remote add origin "$ORIGIN3" && git push -q origin main \
  && git checkout -q -b lcars/smoke-3 && echo y > feature.txt && git add -A \
  && git commit -qm "the mission's work" && git checkout -q main \
  && mkdir -p .git/lcars/missions && printf '{"testCommand":"true"}\n' > .git/lcars/config.json )

M3="$T3/.git/lcars/missions/smoke-3"; mkdir -p "$M3"
# ONE KEY PER LINE — the shape file.sh/run.sh actually write. approve's
# state_del is a `grep -v` on the key, so a single-line state.json is DELETED
# WHOLE by the first field write. A fixture in the wrong shape tests nothing.
cat > "$M3/state.json" <<'EOF'
{
  "id": "smoke-3",
  "title": "t",
  "stage": "implement",
  "branch": "lcars/smoke-3",
  "base": "main",
  "githubIssue": 177
}
EOF

# A scripted driver: pass 1 advances implement → verify and records the PR the
# REAL drive_verify would have opened; `reconcile` (which approve shells first)
# is a clean no-op; a later pass on a done mission just reports.
F3="$O3/fake-lcars"; mkdir -p "$F3/skills/lcars-run"
cat > "$F3/skills/lcars-run/run.sh" <<'EOF'
#!/usr/bin/env bash
SUB="${1:-}"
case "$SUB" in
  reconcile) exit 0 ;;   # base is not ahead — approve's self-heal gate no-ops
esac
MD="$(git rev-parse --git-common-dir)/lcars/missions/smoke-3"
ST="$(sed -n 's/.*"stage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MD/state.json" | head -1)"
if [ "$ST" = implement ]; then
  cat > "$MD/state.json" <<'JSON'
{
  "review": "open",
  "prNumber": "4242",
  "prUrl": "https://github.test/x/y/pull/4242",
  "id": "smoke-3",
  "title": "t",
  "stage": "verify",
  "branch": "lcars/smoke-3",
  "base": "main",
  "githubIssue": 177
}
JSON
  echo "fake driver: implement -> verify (PR opened)"
else
  echo "fake driver: nothing to do at stage=$ST"
fi
EOF
chmod +x "$F3/skills/lcars-run/run.sh"
ln -snf "$REPO/skills/lcars-approve"  "$F3/skills/lcars-approve"
ln -snf "$REPO/skills/lcars-respond"  "$F3/skills/lcars-respond"

# approve resolves its reconcile engine from $LCARS_RUN_SCRIPT — pin it at the
# same scripted driver so no real run.sh (and no worker) can be reached.
LCARS_RUN_SCRIPT="$F3/skills/lcars-run/run.sh" \
LCARS_FAKE_GH_STATE="$O3/pr.state" \
LCARS_MERGE_RETRY_SLEEP=0 \
  python3 "$SD/capstone.py" "$T3" smoke-3 "$O3" "$F3" "$SRC"; RC3=$?

echo; echo "--- capstone.json (scenario 3) ---"; cat "$O3/capstone.json"
echo; echo "--- checks ---"
j3() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get(sys.argv[2]);print("" if v is None else v)' "$O3/capstone.json" "$1"; }
chk "exit 0"                    "$RC3" 0
chk "verifyApproved"            "$(j3 verifyApproved)" True
chk "stage reached"             "$(j3 stageReached)" done
chk "human answers"             "$(j3 humanAnswersRequired)" 0
chk "gates answered from record" "$(j3 gatesAnsweredFromRecord)" 0
chk "mission stage on disk"     "$(sed -n 's/.*"stage"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$M3/state.json" | head -1)" done
chk "review sub-state"          "$(sed -n 's/.*"review"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$M3/state.json" | head -1)" merged
chk "the faked PR really merged" "$(cat "$O3/pr.state" 2>/dev/null)" MERGED
# The push was REAL — the branch is in the throwaway bare origin, not on GitHub
# and not in anyone's working repo.
if git --git-dir="$ORIGIN3" show-ref --verify --quiet refs/heads/lcars/smoke-3; then
  echo "  PASS approve pushed the mission branch to the THROWAWAY origin"
else
  echo "  FAIL the mission branch never reached the throwaway origin"; fail=1
fi
# json.dumps escapes the arrows, so match on the ASCII the note carries.
grep -q '"stopped": "SHIPPED' "$O3/capstone.json" && echo "  PASS the ship is named in capstone.json" \
  || { echo "  FAIL the ship is not named"; fail=1; }

# ── scenario 4 — PAST SCHEDULE, NOT Verify: still strictly hands-off ───────
# The doctrine the brief protects: past Schedule the ONLY intervention is the
# Verify approve. An Implement gate is left parked and reported, never answered.
echo; echo "=== scenario 4 — an Implement gate past Schedule is left alone ==="
O4="$SD/runs/smoke-c2d"; rm -rf "$O4"; mkdir -p "$O4"
T4="$O4/target"; mkdir -p "$T4"
( cd "$T4" && git init -q . && git config user.email t@t && git config user.name t \
  && echo x > README.md && git add -A && git commit -qm init && mkdir -p .git/lcars/missions )
M4="$T4/.git/lcars/missions/smoke-4"; mkdir -p "$M4"
printf '{"id":"smoke-4","title":"t","stage":"implement","awaitingHuman":true}\n' > "$M4/state.json"
cat > "$M4/pending.json" <<'EOF'
{"stage":"implement","questions":["Ticket T-03 exhausted its three worker sessions. How should it be unblocked?"]}
EOF
F4="$O4/fake-lcars"; mkdir -p "$F4/skills/lcars-run"
printf '#!/usr/bin/env bash\necho "fake driver: parked"\n' > "$F4/skills/lcars-run/run.sh"
chmod +x "$F4/skills/lcars-run/run.sh"
ln -snf "$REPO/skills/lcars-respond" "$F4/skills/lcars-respond"
python3 "$SD/capstone.py" "$T4" smoke-4 "$O4" "$F4" "$SRC"; RC4=$?
j4() { python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get(sys.argv[2]);print("" if v is None else v)' "$O4/capstone.json" "$1"; }
chk "exit 0 (a parked gate is not a human ANSWER)" "$RC4" 0
chk "verifyApproved stays false"  "$(j4 verifyApproved)" False
chk "human answers"               "$(j4 humanAnswersRequired)" 0
chk "gates answered from record"  "$(j4 gatesAnsweredFromRecord)" 0
grep -q 'left alone (past Schedule' "$O4/capstone.json" \
  && echo "  PASS the gate is recorded as LEFT ALONE" \
  || { echo "  FAIL the gate was not left alone"; fail=1; }
if [ -f "$M4/answers.json" ]; then echo "  FAIL respond.sh was called past Schedule"; fail=1
else echo "  PASS respond.sh never called past Schedule"; fi

# ── scenario 5 — the ENGINE knob, proven without a daemon or a worker ──────
# matrix.sh --dry-run assembles the whole cell (target, throwaway origin, parked
# mission, pins, shim choice) and stops before the daemon. It is the cheapest
# place to see that a claude cell is claude ALL THE WAY DOWN — including the
# persisted state.json workerBin, the field measured beating the env var.
echo; echo "=== scenario 5 — engine selection (matrix.sh --dry-run) ==="
if [ -d "$SRC/attachments" ]; then
  D1="$SD/runs/smoke-dry-copilot.out"; D2="$SD/runs/smoke-dry-claude.out"
  bash "$SD/matrix.sh" smoke-dry-copilot holo --dry-run > "$D1" 2>&1
  LCARS_DRIVE_ENGINE=claude \
    bash "$SD/matrix.sh" smoke-dry-claude capstone --dry-run > "$D2" 2>&1
  g() { grep -c "$1" "$2" >/dev/null 2>&1 && grep -q "$1" "$2"; }
  for pair in \
    "default is copilot|ENGINE     : copilot|$D1" \
    "copilot cell uses the blockshim|blockshim|$D1" \
    "copilot cell expects 0 claude spawns|claude spawns must be: 0|$D1" \
    "copilot cell parks workerBin=copilot|parked mission workerBin: copilot|$D1" \
    "claude cell selects claude|ENGINE     : claude|$D2" \
    "claude cell uses the countshim|countshim|$D2" \
    "claude cell expects claude spawns|claude spawns must be: non-zero|$D2" \
    "claude cell parks workerBin=claude|parked mission workerBin: claude|$D2" \
    "stand-in stays on copilot|stand-in   : copilot|$D2" \
    "pins are asserted|SKILL PINS|$D2" \
    "the capstone lane names the post-align drive|capstone.py|$D2" \
  ; do
    name="${pair%%|*}"; rest="${pair#*|}"; pat="${rest%%|*}"; f="${rest#*|}"
    if grep -q "$pat" "$f"; then echo "  PASS $name"
    else echo "  FAIL $name (no '$pat' in $f)"; fail=1; fi
  done
  # No worker, no daemon, no spend: the dry run must not have started one.
  if grep -q 'DAEMON DOWN\|sid=' "$D1" "$D2"; then
    echo "  FAIL a dry run reached the daemon"; fail=1
  else echo "  PASS neither dry run started a daemon or a grill"; fi
else
  echo "  SKIP no record dir at $SRC — set LCARS_DRIVE_RECORD_DIR to run scenario 5"
fi

echo
[ "$fail" = 0 ] && echo "SMOKE C2 (all scenarios): PASS" || echo "SMOKE C2 (all scenarios): FAIL"
exit $fail
