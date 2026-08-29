#!/usr/bin/env bash
# S179 LIVE COPILOT LEG — one real holodeck design turn, `claude` fenced off.
#   bash live-drive.sh <run-label> <brief-file>
# Drives the REAL daemon + REAL copilot. Zero claude. Reads the room off disk.
set -u
SP="$(cd "$(dirname "$0")" && pwd)"
REPO="${LCARS_DRIVE_REPO:-/Users/roganferguson/Projects/LCARS}"
LABEL="${1:?run label}"; BRIEF="${2:?brief file}"
OUT="$SP/runs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"

# a throwaway target repo, so the drive never writes near the real projects
TARGET="$OUT/target/roster-app"; mkdir -p "$TARGET"
( cd "$TARGET" && git init -q . && git config user.email t@t && git config user.name t \
  && echo "# roster-app" > README.md && git add -A && git commit -qm init )
SIDECAR="$OUT/target/roster-app-holodeck"

export LCARS_BLOCK_LOG="$OUT/claude-attempts.log"
export LCARS_SHIM_LOG="$OUT/copilot-argv.log"
export PATH="$SP/blockshim:$PATH"          # claude REFUSES, loudly, and counts
export LCARS_WORKER_BIN="$REPO/tests/drives/holodeck-shim/copilot"
export LCARS_SERVE_HOST=127.0.0.1
export LCARS_SERVE_ADAPTER=local
export LCARS_SERVE_REPO_ROOT="$TARGET"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
export LCARS_SERVE_PORT="$PORT"

( cd "$REPO/web" && python3 -m lcars_serve >"$OUT/daemon.log" 2>&1 ) &
DPID=$!
trap 'kill -9 $DPID 2>/dev/null' EXIT       # ONLY the pid we started (never by name)
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null 2>&1 && break
  python3 -c 'import time;time.sleep(0.5)'
done
curl -sf "http://127.0.0.1:$PORT/api/board" >/dev/null || { echo "DAEMON DID NOT COME UP"; cat "$OUT/daemon.log"; exit 1; }
echo "daemon up on $PORT (pid $DPID), target=$TARGET"

python3 - "$PORT" "$BRIEF" "$OUT" <<'PY'
import json, sys, urllib.request
port, brief, out = sys.argv[1], sys.argv[2], sys.argv[3]
def post(path, payload):
    req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path),
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=2400) as r:
        return json.loads(r.read().decode())
r = post("/api/holodeck/start", {"program": "team-roster", "engine": "copilot", "mode": "design"})
open(out + "/start.json", "w").write(json.dumps(r, indent=2))
sid = (r.get("state") or {}).get("sessionId")
print("sid=", sid)
say = post("/api/holodeck/%s/say" % sid, {"text": open(brief).read(), "intent": "build"})
open(out + "/say.json", "w").write(json.dumps(say, indent=2))
st = say.get("state") or {}
print("reply bytes:", len(st.get("reply") or ""))
print("filesChanged:", st.get("filesChanged"))
open(out+"/reply.txt","w").write(st.get("reply") or "")
PY

echo "=== ROOM ($SIDECAR/team-roster) ==="
ls -la "$SIDECAR/team-roster" 2>&1
for f in concept.md mockup.html; do
  [ -f "$SIDECAR/team-roster/$f" ] && cp "$SIDECAR/team-roster/$f" "$OUT/$f"
done
echo "=== claude spawn attempts: $( [ -f "$OUT/claude-attempts.log" ] && grep -c '^TIME:' "$OUT/claude-attempts.log" || echo 0 ) ==="
echo "=== copilot spawns:        $( [ -f "$OUT/copilot-argv.log" ] && grep -c '^TIME:' "$OUT/copilot-argv.log" || echo 0 ) ==="
