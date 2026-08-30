#!/usr/bin/env bash
# Prove Align end-to-end on BOTH paths, live copilot, driven to FILED.
#   bash matrix.sh <label> <holo|plain>
# LCARS_DRIVE_REPO=<checkout> selects pristine vs fixed code.
set -u
SP="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${LCARS_DRIVE_REPO:-/Users/roganferguson/Projects/LCARS}"
LABEL="${1:?label}"; MODE="${2:?holo|plain}"
SRC="$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260829-002"
OUT="$SP/align/runs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
TARGET="$OUT/target"; mkdir -p "$TARGET"
( cd "$TARGET" && git init -q . && git config user.email t@t && git config user.name t \
  && echo "# t" > README.md && git add -A && git commit -qm init \
  && mkdir -p .git/lcars/missions && printf '{"testCommand":"true"}\n' > .git/lcars/config.json )

MID=""
if [ "$MODE" = holo ]; then
  # THE CAPTAIN'S ACTUAL LANE: a PARKED mission whose attachments live on disk,
  # aligned in place. file.sh --complete re-lists them, so the gate sees the
  # concept doc. (Passing them to /api/align/start does NOT work: that endpoint
  # takes `images`, not `attachments`, and an unknown key is silently ignored.)
  MID="lcars-20260829-002"
  MD="$TARGET/.git/lcars/missions/$MID"; mkdir -p "$MD/attachments"
  cp "$SRC/attachments/attachment-01.html" "$SRC/attachments/attachment-02.md" "$MD/attachments/"
  cp "$SRC/attachments/attachment-02.md" "$OUT/"
  cp "$SRC/idea.md" "$MD/idea.md"
  printf '{"id":"%s","title":"MBR Builder","stage":"align","prdPending":true,"model":"claude-sonnet","workerBin":"copilot","attachments":["attachments/attachment-01.html","attachments/attachment-02.md"],"githubIssue":177,"branch":"lcars/%s","base":"main"}\n' "$MID" "$MID" > "$MD/state.json"
  IDEA="$SRC/idea.md"
else
  IDEA="$SP/align/plain-idea.md"
fi

export PATH="$SP/blockshim:$PATH"; export LCARS_BLOCK_LOG="$OUT/claude-attempts.log"
export LCARS_WORKER_BIN=copilot LCARS_GH_BIN="$SP/align/fake-gh"
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
trap 'kill -9 $DPID 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null 2>&1 && break; python3 -c 'import time;time.sleep(0.5)'; done
curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null || { echo "DAEMON DOWN"; tail -20 "$OUT/daemon.log"; exit 1; }

python3 "$SP/align/drive.py" "$PORT" "$IDEA" "$OUT" "$MID"

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
if [ "$MODE" = holo ]; then
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
