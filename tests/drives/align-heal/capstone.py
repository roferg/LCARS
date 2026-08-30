#!/usr/bin/env python3
"""C2 — drive a FILED mission on through Research → … → Schedule and beyond.

  capstone.py <targetRepo> <missionId> <outDir> <lcarsRepo> [recordDir]

`matrix.sh holo` stops at FILED. This is the rest of the capstone: it runs the
REAL driver (`run.sh drive --mission <id>`) and, whenever the driver halts at an
awaiting-human gate, it stands in for the captain THE SAME WAY the Align grill
did — the answer may only come from what he already wrote.

THE TWO STOP CONDITIONS ARE NOT THE SAME EITHER SIDE OF SCHEDULE:

  up to and including Schedule   a gate is answered ONLY if the record settles
                                 it. A gate the record cannot settle is a HUMAN
                                 ANSWER, and one is enough to fail the run.
  past Schedule                  NO INTERVENTION. The drive is left to run to
                                 wherever it parks (normally Verify) and any
                                 gate there is reported, never answered.

Every gate is recorded either way — a gate the record COULD answer is still the
harness asking for something it was already given, which is the whole question
this capstone exists to measure.
"""
import json, os, re, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import standin  # noqa: E402

target, mid, out, lcars = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
record_dir = sys.argv[5] if len(sys.argv) > 5 else standin.DEFAULT_RECORD_DIR

RUN = os.path.join(lcars, "skills/lcars-run/run.sh")
RESPOND = os.path.join(lcars, "skills/lcars-respond/respond.sh")
MDIR = os.path.join(target, ".git/lcars/missions", mid)
MAX_ROUNDS = int(os.environ.get("LCARS_CAPSTONE_MAX_ROUNDS", "12"))

# The measured window. A gate raised at any of these is a defect the rig may
# clear from the record; anything later is left strictly alone.
PRE_SCHEDULE = {"align", "research", "validate", "plan", "plan-review", "schedule"}


def state(key, raw=False):
    try:
        d = json.load(open(os.path.join(MDIR, "state.json")))
    except Exception:
        return None
    return d.get(key)


def pending_questions():
    p = os.path.join(MDIR, "pending.json")
    if not os.path.exists(p):
        return []
    try:
        d = json.load(open(p))
    except Exception:
        return [re.sub(r"\s+", " ", open(p).read())[:400]]
    qs = d.get("questions") or []
    outq = []
    for q in qs:
        if isinstance(q, dict):
            q = q.get("question") or q.get("text") or json.dumps(q)
        outq.append(str(q))
    return outq


def sh(cmd, log):
    with open(log, "ab") as f:
        f.write(("\n$ %s\n" % " ".join(cmd)).encode())
        p = subprocess.run(cmd, cwd=target, stdout=f, stderr=subprocess.STDOUT,
                           stdin=subprocess.DEVNULL)
    return p.returncode


rec = standin.load_record(record_dir)
# APPEND into the Align run's own log: one file is the whole run's evidence.
log = standin.Log(out, append=True)
with open(log.txt, "a") as f:
    f.write("\n" + "=" * 72 + "\nPOST-ALIGN DRIVE\n" + "=" * 72 + "\n")

drive_log = os.path.join(out, "drive.log")
gates, human, answered_from_record, rounds = [], 0, 0, 0
turn = 1000                     # gate turns are numbered apart from align turns
stopped = ""

while rounds < MAX_ROUNDS:
    rounds += 1
    st = state("stage")
    print("\n── round %d · stage=%s ──" % (rounds, st), flush=True)
    rc = sh(["bash", RUN, "drive", "--mission", mid], drive_log)
    st = state("stage")
    awaiting = state("awaitingHuman") is True
    print("   driver rc=%s → stage=%s awaitingHuman=%s" % (rc, st, awaiting), flush=True)

    if not awaiting:
        stopped = "driver halted with no gate (stage=%s, rc=%s)" % (st, rc)
        break

    qs = pending_questions()
    gate = {"round": rounds, "stage": st, "questions": qs, "handled": None}
    gates.append(gate)

    if st not in PRE_SCHEDULE:
        gate["handled"] = "left alone (past Schedule — no intervention)"
        stopped = "parked at an awaiting-human gate in %s — past Schedule, left alone" % st
        print("   ⏸ past Schedule; leaving it parked.", flush=True)
        break

    # Pre-Schedule: the record must settle it, or the run has failed.
    rows, ok = [], True
    for q in qs:
        turn += 1
        row = standin.match(q, rec)
        log.add(turn, row, where="gate/%s" % st)
        rows.append(row)
        print("   gate q → %s : %s" % (row["class"].upper(),
                                       standin._norm(q)[:90]), flush=True)
        if row["class"] not in ("recorded", "quoted"):
            ok = False

    if not ok:
        human += sum(1 for r in rows if r["class"] not in ("recorded", "quoted"))
        gate["handled"] = "NOT IN THE RECORD — run failed"
        stopped = ("a %s gate asked something the captain never answered — "
                   "this is the failure the capstone hunts" % st)
        print("   ✗ NOT IN THE RECORD. Stopping.", flush=True)
        break

    answer = "\n\n".join(r["answer"] for r in rows if r["answer"])
    gate["handled"] = "answered FROM THE RECORD"
    gate["answer"] = answer
    answered_from_record += 1
    env = dict(os.environ, LCARS_RESPOND_RESUME="0")   # this rig owns the loop
    with open(drive_log, "ab") as f:
        f.write(b"\n$ respond.sh answer\n")
        subprocess.run(["bash", RESPOND, "answer", "--mission", mid,
                        "--answer", answer], cwd=target, env=env,
                       stdout=f, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print("   ↩ answered from the record; re-driving.", flush=True)
else:
    stopped = "hit the %d-round cap" % MAX_ROUNDS

c = log.counts()
res = {
    "missionId": mid, "stageReached": state("stage"), "rounds": rounds,
    "stopped": stopped, "gates": gates,
    "gatesAnsweredFromRecord": answered_from_record,
    "humanAnswersRequired": human,
    "postAlignTurns": c,
}
open(os.path.join(out, "capstone.json"), "w").write(json.dumps(res, indent=2))
print("\nPOST-ALIGN: stage=%s gates=%d fromRecord=%d humanAnswers=%d"
      % (res["stageReached"], len(gates), answered_from_record, human))
sys.exit(0 if human == 0 else 1)
