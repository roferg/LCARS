"""Drive ONE live Align grill, answering every turn FROM THE CAPTAIN'S RECORD.

Usage: drive.py <port> <idea.md> <outdir> <missionId|""> [recordDir]

Until S180C this answered every question with "" — a stub that proved the
plumbing and nothing about the grill. It now stands in for the captain using
`standin.py`, which can only ever point at an answer he already wrote (see that
file's header). A question the record does not settle comes back NO-MATCH, is
counted, and FAILS the run.

  LCARS_STANDIN_ON_NOMATCH=continue|stop   (default: continue)
      continue — send an explicit "NOT IN THE RECORD" marker and keep going, so
                 ONE 30-minute run surfaces EVERY unrecorded question instead of
                 just the first. The run is already failed; this is triage.
      stop     — bail on the first one.
"""
import json, os, sys, urllib.request, urllib.error

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import standin  # noqa: E402

port, idea_path, out, mid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
record_dir = sys.argv[5] if len(sys.argv) > 5 else standin.DEFAULT_RECORD_DIR
ON_NOMATCH = os.environ.get("LCARS_STANDIN_ON_NOMATCH", "continue")
MAX_TURNS = int(os.environ.get("LCARS_STANDIN_MAX_TURNS", "30"))

# What we send when the record is silent. Deliberately NOT an answer: the run is
# already failed, and a plausible sentence here would contaminate the PRD the
# later stages read and make the failure harder to see, not easier.
NOT_IN_RECORD = ("NOT IN THE RECORD — the captain never answered this. This is "
                 "a stand-in for a capstone drive; treat it as unanswered.")


def unwrap(d):
    return d.get("state") if isinstance(d, dict) and isinstance(d.get("state"), dict) else d


def post(path, payload, timeout=2400):
    req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path),
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode())


rec = standin.load_record(record_dir)
log = standin.Log(out)
print("record: %d recorded decisions from %s"
      % (len(rec["entries"]), record_dir))
if not rec["entries"]:
    print("!! NO RECORD — every turn will be NO-MATCH. Check the record dir.")

body = {"idea": open(idea_path).read(), "engine": "copilot"}
if mid:
    body["missionId"] = mid

r = unwrap(post("/api/align/start", body))
sid = r.get("sessionId")
print("sid=", sid)
status, n, err, stopped = r.get("status"), 0, None, None

while status == "question" and n < MAX_TURNS:
    n += 1
    q = r.get("question") or {}
    if isinstance(q, str):
        q = {"text": q}
    qtext = q.get("text") or ""
    if q.get("choices"):
        qtext += "\n  (offered choices: %s)" % "; ".join(map(str, q["choices"]))
    if q.get("recommended"):
        qtext += "\n  (its recommendation: %s)" % q["recommended"]

    row = standin.match(qtext, rec, closing=bool(q.get("closing")))
    log.add(n, row)
    print("  turn %-2d %-8s %s" % (n, row["class"].upper(),
                                   standin._norm(qtext)[:90]))

    send = row["answer"]
    if row["class"] in ("nomatch", "error"):
        print("     !! NOT IN THE RECORD — this run is FAILED. why=%s"
              % standin._norm(row["why"])[:160])
        if ON_NOMATCH == "stop":
            stopped = "stopped on the first NO-MATCH (LCARS_STANDIN_ON_NOMATCH=stop)"
            break
        send = NOT_IN_RECORD

    try:
        r = unwrap(post("/api/align/%s/answer" % sid, {"answer": send}))
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", "replace")
        print("  TURN %d HTTP %s" % (n, e.code))
        print("  %s" % err[:400])
        break
    status = r.get("status")

c = log.counts()
result = {
    "sid": sid, "turns": n, "status": status, "stopped": stopped,
    "healed": (r or {}).get("healed"), "error": err,
    "recordDir": record_dir, "recordedDecisions": len(rec["entries"]),
    "counts": c,
    "humanAnswersRequired": c["humanAnswers"],
    "unrecordedQuestions": log.nomatch_questions(),
}
open(out + "/result.json", "w").write(json.dumps(result, indent=2))
open(out + "/prd.md", "w").write((r.get("prd") or "") if isinstance(r, dict) else "")

print("\nALIGN FINAL: status=%s turns=%d healed=%s" % (status, n, (r or {}).get("healed")))
print("  from the record : %d recorded + %d quoted" % (c["recorded"], c["quoted"]))
print("  closing turns   : %d" % c["closing"])
print("  HUMAN ANSWERS   : %d   <-- must be 0" % c["humanAnswers"])
for q in log.nomatch_questions():
    print("    ✗ %s" % q[:160])
if err:
    print("  err:", err[:300])
sys.exit(0 if status == "done" and c["humanAnswers"] == 0 else 1)
