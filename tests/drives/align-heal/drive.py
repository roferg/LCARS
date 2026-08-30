import json, sys, urllib.request, urllib.error
port, idea_path, out, mid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
def unwrap(d):
    return d.get("state") if isinstance(d, dict) and isinstance(d.get("state"), dict) else d
def post(path, payload):
    req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path),
        data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=2400) as r:
        return json.loads(r.read().decode())
body = {"idea": open(idea_path).read(), "engine": "copilot"}
if mid:
    body["missionId"] = mid
r = unwrap(post("/api/align/start", body))
sid = r.get("sessionId"); print("sid=", sid)
status, n, err = r.get("status"), 0, None
while status == "question" and n < 30:
    n += 1
    try:
        r = unwrap(post("/api/align/%s/answer" % sid, {"answer": ""}))
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", "replace")
        print("TURN %d HTTP %s" % (n, e.code)); break
    status = r.get("status"); print("turn %d -> %s" % (n, status))
open(out + "/result.json", "w").write(json.dumps(
    {"sid": sid, "turns": n, "status": status, "healed": (r or {}).get("healed"), "error": err}, indent=2))
open(out + "/prd.md", "w").write((r.get("prd") or "") if isinstance(r, dict) else "")
print("FINAL:", status, "turns:", n, "healed:", (r or {}).get("healed"), "err:", (err or "")[:300])
