#!/usr/bin/env bash
# ============================================================================
# S173 TESTER RIG — the four-wave HIRE / BOUNCE / ITERATION fixture mission.
#
#   bash s173-fixture.sh <fixture-root>
#
# Plants a repo-shaped dir (<root>/.git/lcars/…) holding ONE Implement mission
# with six waves, each isolating one case the S173 vocabulary round must get
# right. Every file is written in the EXACT on-disk format the harness writes
# (emit_event's compact one-line JSON incl. the `mission` key; emit_waves_json's
# pretty array; a pretty plan.json parse_plan_table can read).
#
#   wave 1 (a)  t-001  ONE hire, no bounces, green.  result.json.attempts = 7
#                      (deliberately LOUD: 7 must appear on no healthy surface)
#   wave 2 (b)  t-002  THREE hires, TWO bounces, green
#   wave 3 (c)  t-003  THREE hires, THREE bounces, hire cap exhausted → flagged
#   wave 4 (d)  t-004/5  PRE-S134: no ticket_attempt events at all, old detail
#   wave 5 (e)  t-006  MIXED: old-vocabulary detail text beside new-vocabulary
#   wave 6 (f)  t-007  TRULY HISTORICAL: ticket_attempt phase=test-writer /
#                      phase=implementer, the pre-S133 standoff shape
#   wave 7 (g)  t-008  THE RESUME SPLIT (fix round 2, N1): 3 hires + 2 bounces
#                      with a `stage_start` RE-ENTRY after hire 2, so the wave's
#                      hires straddle two timeline sections
# ============================================================================
set -euo pipefail
FIX="${1:?usage: s173-fixture.sh <fixture-root>}"
MID="lcars-20260830-001"
D="$FIX/.git/lcars/missions/$MID"
mkdir -p "$D" "$D/tickets/t-001"
cat >"$FIX/.git/lcars/config.json" <<'J'
{"lcarsVersion": "2026.8.5", "repo": "acme/s173", "testCommand": "true"}
J
cat >"$D/state.json" <<J
{
  "id": "$MID",
  "type": "feature",
  "title": "S173: hires, bounces and iterations",
  "stage": "implement",
  "created": "2026-08-30T10:00:00Z",
  "model": "claude",
  "githubIssue": 5100,
  "branch": "lcars/$MID",
  "base": "main"
}
J
# The worker's OWN iteration count, set LOUD on the clean first-hire ticket.
cat >"$D/tickets/t-001/result.json" <<'J'
{"ticketId":"t-001","passed":true,"attempts":7,"summary":"green","newTests":["a.test.js"],"testEdits":[],"flipFlop":"expected"}
J
cat >"$D/waves.json" <<'J'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": 5101
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": 5102
      }
    ]
  },
  {
    "wave": 3,
    "tickets": [
      {
        "id": "t-003",
        "issue": 5103
      }
    ]
  },
  {
    "wave": 4,
    "tickets": [
      {
        "id": "t-004",
        "issue": 5104
      },
      {
        "id": "t-005",
        "issue": 5105
      }
    ]
  },
  {
    "wave": 5,
    "tickets": [
      {
        "id": "t-006",
        "issue": 5106
      }
    ]
  },
  {
    "wave": 6,
    "tickets": [
      {
        "id": "t-007",
        "issue": 5107
      }
    ]
  },
  {
    "wave": 7,
    "tickets": [
      {
        "id": "t-008",
        "issue": 5108
      }
    ]
  }
]
J
python3 - "$D/plan.json" <<'PY'
import json, sys
tickets = [
  ("t-001", "Clean first-try ticket",   []),
  ("t-002", "Struggled but landed",     ["t-001"]),
  ("t-003", "Exhausted the hire cap",   ["t-002"]),
  ("t-004", "Pre-S134 green",           ["t-003"]),
  ("t-005", "Pre-S134 flagged",         ["t-003"]),
  ("t-006", "Mixed vocabulary",         ["t-004"]),
  ("t-007", "Pre-S133 standoff stream", ["t-006"]),
  ("t-008", "Resumed mid-wave",          ["t-007"]),
]
plan = {"tickets": [
  {"id": i, "title": t, "description": "S173 fixture ticket " + i,
   "acceptance": ["%s behaves as specified" % i], "dependsOn": d,
   "rationale": "fixture", "infrastructure": False}
  for i, t, d in tickets]}
json.dump(plan, open(sys.argv[1], "w"), indent=2)
PY
cp "$D/plan.json" "$D/approved-plan.json"

python3 - "$D/events.jsonl" "$MID" <<'PY'
import json, sys, time
path, mid = sys.argv[1], sys.argv[2]
out = open(path, "w")
T = [int(time.time()) - 4000]

def esc(s):
    return json.dumps(s)[1:-1]

def ev(typ, detail, stage="implement", **data):
    T[0] += 30
    bits = []
    for k, v in data.items():
        bits.append('"%s":%s' % (k, v if isinstance(v, int) else '"%s"' % esc(str(v))))
    d = (',"data":{%s}' % ",".join(bits)) if bits else ""
    out.write('{"ts":%d,"mission":"%s","stage":"%s","type":"%s","detail":"%s"%s}\n'
              % (T[0], mid, stage, typ, esc(detail), d))

ev("stage_start", "implement stage starting")

# ── wave (a): ONE hire, no bounces, green. result.json.attempts = 7 (LOUD).
ev("wave_start", "wave 1 starting (1 ticket(s))", wave=1, ticketCount=1, totalWaves=7)
ev("ticket_start", "ticket t-001 starting", ticket="t-001", wave=1)
ev("ticket_attempt", "tdd session 1 for t-001", ticket="t-001", phase="tdd", attempt=1)
ev("flip_flop_pass", "flip-flop proven for t-001", ticket="t-001")
ev("ticket_postcommit_ok", "ticket t-001 verified green on the committed branch",
   ticket="t-001", iterations=7)
ev("ticket_green", "ticket t-001 green", ticket="t-001", sessions=1, iterations=7)

# ── wave (b): THREE hires, TWO bounces, green.
ev("wave_start", "wave 2 starting (1 ticket(s))", wave=2, ticketCount=1, totalWaves=7)
ev("ticket_start", "ticket t-002 starting", ticket="t-002", wave=2)
ev("ticket_attempt", "tdd session 1 for t-002", ticket="t-002", phase="tdd", attempt=1)
ev("flip_flop_fail", "the tests passed on the parent commit too", ticket="t-002")
ev("ticket_gate_bounce", "ticket t-002 bounced by the flip-flop gate (tests pass on parent)"
   " - session 1; re-spawning a fresh worker with the verdict",
   ticket="t-002", gate="flip-flop", attempt=1)
ev("ticket_attempt", "tdd session 2 for t-002", ticket="t-002", phase="tdd", attempt=2)
ev("ticket_test_edits", "t-002 declared 1 test edit", ticket="t-002")
ev("ticket_gate_bounce", "ticket t-002 bounced by the declared-edits gate (undeclared edit)"
   " - session 2; re-spawning a fresh worker with the verdict",
   ticket="t-002", gate="declared-edits", attempt=2)
ev("ticket_attempt", "tdd session 3 for t-002", ticket="t-002", phase="tdd", attempt=3)
ev("flip_flop_pass", "flip-flop proven for t-002", ticket="t-002")
ev("ticket_green", "ticket t-002 green after 3 worker sessions",
   ticket="t-002", sessions=3, iterations=2)

# ── wave (c): THREE hires, hire cap EXHAUSTED, flagged awaiting-human.
ev("wave_start", "wave 3 starting (1 ticket(s))", wave=3, ticketCount=1, totalWaves=7)
ev("ticket_start", "ticket t-003 starting", ticket="t-003", wave=3)
for i in (1, 2, 3):
    ev("ticket_attempt", "tdd session %d for t-003" % i, ticket="t-003", phase="tdd", attempt=i)
    ev("flip_flop_fail", "the tests passed on the parent commit too", ticket="t-003")
    ev("ticket_gate_bounce", "ticket t-003 bounced by the flip-flop gate (tests pass on parent)"
       " - session %d; re-spawning a fresh worker with the verdict" % i,
       ticket="t-003", gate="flip-flop", attempt=i)
ev("ticket_flagged", "ticket t-003 flagged after 3 worker session(s) - last gate verdict:"
   " flip-flop (tests pass on parent)", ticket="t-003", sessions=3)
ev("gate", "t-003 is blocked after 3 worker sessions - answer with lcars respond")

# ── wave (d): PRE-S134 stream - NO ticket_attempt events at all, old detail text.
ev("wave_start", "wave 4 starting (2 ticket(s))", wave=4, ticketCount=2, totalWaves=7)
ev("ticket_start", "ticket t-004 starting", ticket="t-004", wave=4)
ev("ticket_green", "ticket t-004 green in 2 attempt(s)", ticket="t-004")
ev("ticket_start", "ticket t-005 starting", ticket="t-005", wave=4)
ev("ticket_flagged", "ticket t-005 flagged after 5 attempt(s)", ticket="t-005")

# ── wave (e): MIXED - old-vocabulary detail text beside new-vocabulary details.
ev("wave_start", "wave 5 starting (1 ticket(s))", wave=5, ticketCount=1, totalWaves=7)
ev("ticket_start", "ticket t-006 starting", ticket="t-006", wave=5)
ev("ticket_attempt", "attempt 1 for t-006", ticket="t-006", phase="tdd", attempt=1)
ev("ticket_gate_bounce", "ticket t-006 bounced by the quality gate (thin) - attempt 1",
   ticket="t-006", gate="quality", attempt=1)
ev("ticket_attempt", "tdd session 2 for t-006", ticket="t-006", phase="tdd", attempt=2)
ev("ticket_green", "ticket t-006 green in 4 attempt(s)", ticket="t-006", sessions=2, iterations=4)

# ── wave (f): TRULY HISTORICAL - the pre-S133 Test-Writer / Implementer standoff.
ev("wave_start", "wave 6 starting (1 ticket(s))", wave=6, ticketCount=1, totalWaves=7)
ev("ticket_start", "ticket t-007 starting", ticket="t-007", wave=6)
ev("ticket_attempt", "test-writer try 1 for t-007", ticket="t-007",
   phase="test-writer", attempt=1)
ev("ticket_attempt", "implementer try 1 for t-007", ticket="t-007",
   phase="implementer", attempt=1)
ev("ticket_green", "ticket t-007 green in 3 attempt(s)", ticket="t-007", attempts=3)

# wave (g): THE RESUME SPLIT. Three hires, two bounces, and a real `stage_start`
# re-entry after hire 2 - the shape a respond->run resume / manual retry / the
# auto-advance driver re-running Implement leaves on disk. `wave_start` is
# deduped against events.jsonl; `stage_start` is not, so the board opens a NEW
# section mid-wave and the wave's hires straddle it. The TIMELINE still splits
# here (deliberately unchanged); the wave band's COUNT must read 3, agreeing
# with ticket_hire_count / the comment mirror / the Verify roll-up.
ev("wave_start", "wave 7 starting (1 ticket(s))", wave=7, ticketCount=1, totalWaves=7)
ev("ticket_start", "ticket t-008 starting", ticket="t-008", wave=7)
ev("ticket_attempt", "tdd session 1 for t-008", ticket="t-008", phase="tdd", attempt=1)
ev("ticket_gate_bounce", "ticket t-008 bounced by the flip-flop gate (tests pass on parent)"
   " - session 1; re-spawning a fresh worker with the verdict",
   ticket="t-008", gate="flip-flop", attempt=1)
ev("ticket_attempt", "tdd session 2 for t-008", ticket="t-008", phase="tdd", attempt=2)
ev("ticket_gate_bounce", "ticket t-008 bounced by the declared-edits gate (undeclared edit)"
   " - session 2; re-spawning a fresh worker with the verdict",
   ticket="t-008", gate="declared-edits", attempt=2)
ev("stage_start", "implement stage resuming after the human answered")
ev("ticket_attempt", "tdd session 3 for t-008", ticket="t-008", phase="tdd", attempt=3)
ev("flip_flop_pass", "flip-flop proven for t-008", ticket="t-008")
ev("ticket_postcommit_ok", "ticket t-008 verified green on the committed branch",
   ticket="t-008", iterations=4)
ev("ticket_green", "ticket t-008 green after 3 worker sessions",
   ticket="t-008", sessions=3, iterations=4)
out.close()
PY
echo "fixture: $FIX  mission: $MID"
