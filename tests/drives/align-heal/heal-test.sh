#!/usr/bin/env bash
# Deterministic proof of the RECOVERY half. Worker is scripted; daemon, file.sh,
# gate, exit codes, heal loop, draft handling are all REAL.
#   bash heal-test.sh <label> <drop> <heals_ok>
set -u
SD="$(cd "$(dirname "$0")" && pwd)"
SP="$(cd "$SD/.." && pwd)"
REPO="${LCARS_DRIVE_REPO:-/Users/roganferguson/Projects/LCARS}"
LABEL="${1:?}"; DROP="${2:-5}"; HEALS_OK="${3:-1}"
SRC="$HOME/Projects/DX-Scorecard/.git/lcars/missions/lcars-20260829-002"
OUT="$SD/runs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
TARGET="$OUT/target"; mkdir -p "$TARGET"
( cd "$TARGET" && git init -q . && git config user.email t@t && git config user.name t \
  && echo "# t" > README.md && git add -A && git commit -qm init \
  && mkdir -p .git/lcars/missions && printf '{"testCommand":"true"}\n' > .git/lcars/config.json )
MID="lcars-20260829-002"; MD="$TARGET/.git/lcars/missions/$MID"; mkdir -p "$MD/attachments"
cp "$SRC/attachments/attachment-01.html" "$SRC/attachments/attachment-02.md" "$MD/attachments/"
cp "$SRC/idea.md" "$MD/idea.md"
printf '{"id":"%s","title":"MBR Builder","stage":"align","prdPending":true,"model":"claude-sonnet","workerBin":"copilot","attachments":["attachments/attachment-01.html","attachments/attachment-02.md"],"githubIssue":177,"branch":"lcars/%s","base":"main"}\n' "$MID" "$MID" > "$MD/state.json"

export FI_STATE="$OUT/fi.count" FI_DROP="$DROP" FI_HEALS_OK="$HEALS_OK"
export FI_BRIEF="$MD/attachments/attachment-02.md" FI_REPO="$REPO"
export PATH="$SD/faultinj:$SP/undrawn/blockshim:$PATH"
export LCARS_WORKER_BIN="$SD/faultinj/copilot"
export LCARS_GH_BIN="$SD/fake-gh" LCARS_BLOCK_LOG="$OUT/claude-attempts.log"
export LCARS_FILE_SCRIPT="$REPO/skills/lcars-file/file.sh"
export LCARS_VERSION_CHECK_BIN="$REPO/skills/lcars-version/check.sh"
export LCARS_SERVE_HOST=127.0.0.1 LCARS_SERVE_ADAPTER=local LCARS_SERVE_REPO_ROOT="$TARGET"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
export LCARS_SERVE_PORT="$PORT"
( cd "$REPO/web" && python3 -m lcars_serve >"$OUT/daemon.log" 2>&1 ) & DPID=$!
trap 'kill -9 $DPID 2>/dev/null' EXIT
for _ in $(seq 1 40); do curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null 2>&1 && break; python3 -c 'import time;time.sleep(0.5)'; done

python3 - "$PORT" "$MD/idea.md" "$OUT" "$MID" <<'PY'
import json, sys, urllib.request, urllib.error
port, idea, out, mid = sys.argv[1:5]
def unwrap(d): return d.get("state") if isinstance(d,dict) and isinstance(d.get("state"),dict) else d
def post(p, b):
    r=urllib.request.Request("http://127.0.0.1:%s%s"%(port,p), data=json.dumps(b).encode(),
                             headers={"Content-Type":"application/json"})
    with urllib.request.urlopen(r, timeout=600) as x: return json.loads(x.read().decode())
d = unwrap(post("/api/align/start", {"idea": open(idea).read(), "engine":"copilot", "missionId": mid}))
sid = d.get("sessionId"); print("sid=%s status=%s" % (sid, d.get("status")))
n = 0
while d.get("status") == "question" and n < 10:
    n += 1
    try:
        d = unwrap(post("/api/align/%s/answer" % sid, {"answer": ""}))
        print("  turn %d -> %s healed=%s" % (n, d.get("status"), d.get("healed")))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        print("  REFUSED http=%s on turn %d" % (e.code, n))
        open(out+"/error.txt","w").write(body)
        try: print("  message:", json.loads(body).get("error","")[:350])
        except Exception: print("  body:", body[:350])
        break
open(out+"/result.json","w").write(json.dumps(d, indent=2)[:4000])
PY

echo "--- worker turns: $(cat "$OUT/fi.count" 2>/dev/null || echo 0)  heal turns: $(cat "$OUT/fi.count.heal" 2>/dev/null || echo 0)"
echo "--- filed?"; ls "$MD/prd.md" >/dev/null 2>&1 && echo "    prd.md WRITTEN ($(grep -c 'STILL OPEN' "$MD/prd.md") questions)" || echo "    NOT filed"
echo "--- draft kept?"; ls "$MD/prd-draft.md" >/dev/null 2>&1 && echo "    prd-draft.md PRESENT ($(wc -c <"$MD/prd-draft.md") bytes)" || echo "    no draft"
echo "--- card resumable?"; curl -s "http://127.0.0.1:$PORT/api/board" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for st,cs in d['columns'].items():
  for c in cs: print('   ',c['id'],'stage=',c['stage'],'alignResume=',bool(c.get('alignResume')),'prdPending=',c.get('prdPending'))"
