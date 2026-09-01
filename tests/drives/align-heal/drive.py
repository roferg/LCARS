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
# LCARS_STANDIN_DEFER=1 — the PIPELINE mode. See the long note at its use below.
DEFER = os.environ.get("LCARS_STANDIN_DEFER", "0") == "1"
DEFER_REPLY = ("Go with your recommendation on this one. I am not adding a new "
               "constraint — take the option you recommended and carry on.")
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
print("engine: %s (grill) · stand-in matcher: %s (always, never the cell engine)"
      % (os.environ.get("LCARS_DRIVE_ENGINE", "copilot"), standin.COPILOT_BIN))
if not rec["entries"]:
    print("!! NO RECORD — every turn will be NO-MATCH. Check the record dir.")

# THE CELL'S ENGINE runs the grill AND the pipeline — never split (the
# captain's standing constraint). Default copilot, so an unset knob is
# byte-identical to every invocation before the knob existed.
ENGINE = os.environ.get("LCARS_DRIVE_ENGINE", "copilot")
body = {"idea": open(idea_path).read(), "engine": ENGINE}
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
        # TWO DIFFERENT QUESTIONS, AND THEY NEED DIFFERENT RIGS.
        #
        # STRICT (default) asks: "is the PRD faithful to what the captain
        # actually decided?" There, an unrecorded question MUST fail the run —
        # that is the whole fabrication fence, and it stays exactly as it was.
        #
        # DEFER (LCARS_STANDIN_DEFER=1) asks a different question: "does the
        # PIPELINE still complete end to end?" MEASURED 2026-09-01 across four
        # drives: the grill generates arbitrarily fine-grained refinements
        # (floor-vs-round at a unit boundary; print styling), and holds any
        # unanswered one FOREVER — correctly, since Align is interactive and
        # must not guess. One run answered 5 of 5 from the record; the next hit
        # a gap on turn 4 and stalled for 26 turns. No finite record wins that
        # game, so a strict rig can never reach the pipeline by itself.
        #
        # What DEFER does is narrow and auditable: where the record is silent AND
        # the grill has offered its own recommendation, it replies "take your
        # recommendation" — the stand-in still invents NOTHING and adds no
        # constraint of its own; it declines to overrule. Every deferral is
        # logged and counted separately, and a DEFER run must never be reported
        # as "zero human answers" — the honest phrasing is "zero fabricated
        # answers, N deferrals". It proves the pipeline runs. It proves nothing
        # about whether the PRD says what the captain wanted.
        if DEFER and "recommend" in qtext.lower():
            row["class"] = "deferred"
            print("     ~~ not on the record; DEFERRING to the grill's own "
                  "recommendation (proves the pipeline, not the PRD)")
            send = DEFER_REPLY
        else:
            print("     !! NOT IN THE RECORD — this run is FAILED. why=%s"
                  % standin._norm(row["why"])[:160])
            if ON_NOMATCH == "stop":
                stopped = "stopped on the first NO-MATCH (LCARS_STANDIN_ON_NOMATCH=stop)"
                break
            send = NOT_IN_RECORD

    # RETRY THE RECOVERABLE ONE. LCARS itself distinguishes these: when the Align
    # worker's reply cannot be parsed as a question it says so AND says "answer
    # again to retry" — the grill is explicitly UNCHANGED, so re-sending the same
    # answer costs one turn and usually lands. MEASURED 2026-09-01: a drive whose
    # record answered 5 of 5 questions with ZERO human answers died on this, and
    # reported "FAILED at Align" as though the record were at fault. A model's
    # reply SHAPE is a lottery; treating one bad roll as terminal throws away a
    # run that was working. Every other error still breaks immediately.
    RETRYABLE = "could not be read as a question"
    r = None
    for attempt in range(3):
        try:
            r = unwrap(post("/api/align/%s/answer" % sid, {"answer": send}))
            err = None
            break
        except urllib.error.HTTPError as e:
            err = e.read().decode("utf-8", "replace")
            if RETRYABLE in err and attempt < 2:
                print("  TURN %d — unparseable worker reply, retrying (%d/2)"
                      % (n, attempt + 1))
                continue
            print("  TURN %d HTTP %s" % (n, e.code))
            print("  %s" % err[:400])
            break
    if r is None:
        break
    status = r.get("status")

c = log.counts()
result = {
    "sid": sid, "turns": n, "status": status, "stopped": stopped,
    "healed": (r or {}).get("healed"), "error": err,
    "recordDir": record_dir, "recordedDecisions": len(rec["entries"]),
    "engine": ENGINE,
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
if c.get("deferred"):
    print("  DEFERRED        : %d   <-- the record was silent and the stand-in did"
          % c["deferred"])
    print("                        not overrule the grill's own recommendation.")
    print("                        This run proves THE PIPELINE RUNS. It does NOT")
    print("                        prove the PRD says what the captain wanted.")
for q in log.nomatch_questions():
    print("    ✗ %s" % q[:160])
if err:
    print("  err:", err[:300])
sys.exit(0 if status == "done" and c["humanAnswers"] == 0 else 1)
