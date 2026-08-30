#!/usr/bin/env bash
# Prove Align end-to-end, live copilot, driven to FILED — and, in `capstone`
# mode, on through Research → Validate → Plan → Plan Review → Schedule.
#
#   bash matrix.sh <label> <holo|plain|capstone>
#
# LCARS_DRIVE_REPO=<checkout>       which LCARS source is under test
# LCARS_DRIVE_TARGET_SRC=<repo>     clone THIS repo as the mission target
#                                   (default: an empty throwaway git repo, which
#                                   is fine for Align but gives Research/Plan
#                                   nothing real to read — point it at the real
#                                   product repo for a meaningful capstone)
set -u
SD="$(cd "$(dirname "$0")" && pwd)"                 # this rig
SP="$(cd "$SD/.." && pwd)"                          # tests/drives
REPO="${LCARS_DRIVE_REPO:-/Users/roganferguson/Projects/LCARS}"
LABEL="${1:?label}"; MODE="${2:?holo|plain|capstone}"
SRC="${LCARS_DRIVE_RECORD_DIR:-$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260829-002}"
OUT="$SD/runs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
TARGET="$OUT/target"

# ── the mission target ──────────────────────────────────────────────────────
# A local clone (no network) when one is named, so Research/Plan/Implement have
# real code to read; otherwise the empty throwaway the Align lane only needs.
if [ -n "${LCARS_DRIVE_TARGET_SRC:-}" ]; then
  echo "cloning $LCARS_DRIVE_TARGET_SRC → $TARGET (local, no network)…"
  git clone -q --local --no-hardlinks "$LCARS_DRIVE_TARGET_SRC" "$TARGET" \
    || { echo "clone FAILED"; exit 1; }
  mkdir -p "$TARGET/.git/lcars/missions"
  if [ -f "$LCARS_DRIVE_TARGET_SRC/.git/lcars/config.json" ]; then
    cp "$LCARS_DRIVE_TARGET_SRC/.git/lcars/config.json" "$TARGET/.git/lcars/config.json"
  else
    printf '{"testCommand":"true"}\n' > "$TARGET/.git/lcars/config.json"
  fi
else
  mkdir -p "$TARGET"
  ( cd "$TARGET" && git init -q . && git config user.email t@t && git config user.name t \
    && echo "# t" > README.md && git add -A && git commit -qm init \
    && mkdir -p .git/lcars/missions && printf '{"testCommand":"true"}\n' > .git/lcars/config.json )
fi

MID=""
if [ "$MODE" = plain ]; then
  IDEA="$SD/plain-idea.md"
else
  # THE CAPTAIN'S ACTUAL LANE: a PARKED mission whose attachments live on disk,
  # aligned in place. file.sh --complete re-lists them, so the gate sees the
  # concept doc. (Passing them to /api/align/start does NOT work: that endpoint
  # takes `images`, not `attachments`, and an unknown key is silently ignored.)
  MID="lcars-20260829-002"
  MD="$TARGET/.git/lcars/missions/$MID"; rm -rf "$MD"; mkdir -p "$MD/attachments"
  cp "$SRC/attachments/attachment-01.html" "$SRC/attachments/attachment-02.md" "$MD/attachments/"
  cp "$SRC/attachments/attachment-02.md" "$OUT/"
  cp "$SRC/idea.md" "$MD/idea.md"
  printf '{"id":"%s","title":"MBR Builder","stage":"align","prdPending":true,"model":"claude-sonnet","workerBin":"copilot","attachments":["attachments/attachment-01.html","attachments/attachment-02.md"],"githubIssue":177,"branch":"lcars/%s","base":"main"}\n' "$MID" "$MID" > "$MD/state.json"
  IDEA="$SRC/idea.md"
fi

export PATH="$SP/undrawn/blockshim:$PATH"; export LCARS_BLOCK_LOG="$OUT/claude-attempts.log"
export LCARS_WORKER_BIN=copilot LCARS_GH_BIN="$SD/fake-gh"
# PIN EVERY SKILL TO THE SAME CHECKOUT AS THE DAEMON. Without this the
# daemon resolves file.sh from ~/.claude/skills (a symlink to the MAIN
# checkout), so a "pristine" baseline silently ran the FIXED file.sh.
export LCARS_FILE_SCRIPT="$REPO/skills/lcars-file/file.sh"
export LCARS_RUN_SCRIPT="$REPO/skills/lcars-run/run.sh"
export LCARS_VERSION_CHECK_BIN="$REPO/skills/lcars-version/check.sh"
export LCARS_SERVE_HOST=127.0.0.1 LCARS_SERVE_ADAPTER=local LCARS_SERVE_REPO_ROOT="$TARGET"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
export LCARS_SERVE_PORT="$PORT"
( cd "$REPO/web" && python3 -m lcars_serve >"$OUT/daemon.log" 2>&1 ) & DPID=$!
# ONLY the PID this script started. NEVER pkill/killall by name — the captain
# runs his own viewscreen daemon in parallel sessions.
trap 'kill -9 $DPID 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null 2>&1 && break; python3 -c 'import time;time.sleep(0.5)'; done
curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null || { echo "DAEMON DOWN"; tail -20 "$OUT/daemon.log"; exit 1; }

# ── ALIGN: the stand-in answers ONLY from the captain's record ──────────────
python3 "$SD/drive.py" "$PORT" "$IDEA" "$OUT" "$MID" "$SRC"; ALIGN_RC=$?

echo "=== FILED? ==="
curl -s "http://127.0.0.1:$PORT/api/board" | python3 -c "
import sys,json
d=json.load(sys.stdin); tot=0
for st,cards in d['columns'].items():
    for c in cards:
        tot+=1; print('  ', c['id'], 'stage=',c['stage'], 'prdPending=', c.get('prdPending'))
print('   MISSIONS ON BOARD:', tot)
"
echo "=== leftovers ==="
find "$TARGET/.git/lcars" -name "prd-draft*" 2>/dev/null | sed 's/^/  DRAFT: /'
find "$TARGET/.git/lcars/tmp" -name "lcars-prd-*" 2>/dev/null | sed 's/^/  TMP: /'
ls "$TARGET/.git/lcars/missions"/*/prd.md 2>/dev/null | sed 's/^/  prd.md: /'
if [ "$MODE" != plain ]; then
  echo "=== questions carried ==="
  bash -c ". $REPO/skills/lcars-init/lcars-common.sh
    P=\$(ls $TARGET/.git/lcars/missions/*/prd.md 2>/dev/null | head -1)
    [ -n \"\$P\" ] || P=$OUT/prd.md
    want=\$(lcars_concept_open_questions $OUT/attachment-02.md | wc -l | tr -d ' ')
    if lcars_prd_questions_gate \"\$P\" $OUT/attachment-02.md 2>$OUT/gate.txt; then
      echo \"  GATE PASS — all \$want carried\"
    else
      echo \"  GATE REFUSED — dropped \$(grep -c '^  - ' $OUT/gate.txt) of \$want\"
    fi"
fi
echo "=== heals: $(grep -ci 'heal' "$OUT/daemon.log" 2>/dev/null || echo 0) · claude spawns: $( [ -f "$OUT/claude-attempts.log" ] && grep -c '^TIME:' "$OUT/claude-attempts.log" || echo 0 ) ==="

[ "$MODE" = capstone ] || exit $ALIGN_RC

# ── CAPSTONE: on through Research → … → Schedule and beyond ────────────────
# A failed Align is NOT driven further: the expensive stages would be reading a
# PRD assembled around answers the captain never gave.
if [ "$ALIGN_RC" -ne 0 ]; then
  echo
  echo "############################################################"
  echo "# ALIGN FAILED — not spending on the pipeline."
  echo "# See $OUT/standin-log.txt and $OUT/result.json"
  echo "############################################################"
fi

if [ "$ALIGN_RC" -eq 0 ]; then
  echo; echo "=== POST-ALIGN DRIVE ==="
  python3 "$SD/capstone.py" "$TARGET" "$MID" "$OUT" "$REPO" "$SRC"
fi

# ── the readout ─────────────────────────────────────────────────────────────
BLOCKED=$( [ -f "$OUT/claude-attempts.log" ] && grep -c '^TIME:' "$OUT/claude-attempts.log" || echo 0 )
USAGE="$( cd "$TARGET" && bash "$REPO/skills/lcars-run/run.sh" usage --mission "$MID" 2>/dev/null | tail -20 )"
OUT="$OUT" MID="$MID" BLOCKED="$BLOCKED" USAGE="$USAGE" python3 - <<'PY'
import json, os
out = os.environ["OUT"]
def load(n):
    try: return json.load(open(os.path.join(out, n)))
    except Exception: return {}
a, c = load("result.json"), load("capstone.json")
ac = a.get("counts", {})
human = a.get("humanAnswersRequired", 0) + c.get("humanAnswersRequired", 0)
bar = "=" * 62
# THE HEADLINE MUST NEVER READ 0 FROM AN ABSENT FILE. A drive that died before
# the first turn leaves no result.json, and a naive .get(…, 0) turns that into
# the very "zero human answers" the capstone is trying to earn.
if not a:
    verdict = "NO RESULT — the Align drive produced no result.json; nothing was measured"
    headline = "n/a  (NOTHING RAN)"
elif a.get("status") != "done":
    verdict = "FAILED at Align — status=%s" % a.get("status")
    headline = "%d (of %d turns)" % (human, ac.get("turns", 0))
elif human:
    verdict = "FAILED — the harness asked for %d thing(s) the captain never answered" % human
    headline = "%d" % human
elif not c:
    verdict = "ALIGN CLEAN — post-Align drive did not run"
    headline = "%d" % human
else:
    verdict = "PASS through %s — zero human answers" % c.get("stageReached")
    headline = "%d" % human
print("\n" + bar + "\nCAPSTONE READOUT — " + os.environ["MID"] + "\n" + bar)
print("  VERDICT                : %s" % verdict)
print("  stage reached          : %s" % (c.get("stageReached") or a.get("status") or "?"))
print("  HUMAN ANSWERS REQUIRED : %s      <-- the headline; must be 0" % headline)
print("  align turns            : %d  (%d from a recorded decision, %d from a "
      "verified quote, %d closing)"
      % (ac.get("turns", 0), ac.get("recorded", 0), ac.get("quoted", 0), ac.get("closing", 0)))
print("  align healed           : %s" % a.get("healed"))
print("  claude spawn attempts  : %s      <-- must be 0" % os.environ["BLOCKED"])
print("  driver rounds          : %s" % c.get("rounds"))
print("  stopped because        : %s" % (c.get("stopped") or a.get("stopped") or "-"))
un = a.get("unrecordedQuestions") or []
if un:
    print("\n  QUESTIONS THE RECORD DID NOT SETTLE (align):")
    for q in un: print("    ✗ %s" % q[:200])
gates = c.get("gates") or []
print("\n  AWAITING-HUMAN GATES HIT: %d" % len(gates))
for g in gates:
    print("    · round %s · stage %s · %s" % (g.get("round"), g.get("stage"), g.get("handled")))
    for q in g.get("questions") or []:
        print("        Q: %s" % " ".join(str(q).split())[:220])
print("\n  WORKER USAGE (run.sh usage):")
for line in (os.environ.get("USAGE") or "(none recorded)").splitlines():
    print("    " + line)
print("\n  evidence: %s/standin-log.txt   (every turn, every match, every reply)" % out)
print(bar)
PY
