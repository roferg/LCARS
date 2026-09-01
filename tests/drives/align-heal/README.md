# The Align filing lane — recovery drives

> Two rigs. `heal-test.sh` FORCES the failure and proves the recovery
> deterministically; `matrix.sh` drives REAL copilot grills on both paths and
> measures how often a live worker still drops questions.

```bash
# deterministic — scripted worker, everything else real
bash tests/drives/align-heal/heal-test.sh heal-A 5 1   # drops 5, fixes itself -> FILES
bash tests/drives/align-heal/heal-test.sh heal-B 5 0   # never fixes -> caps, keeps draft, RESUMABLE

# live — one real grill, driven to FILED
bash tests/drives/align-heal/matrix.sh run-1 holo      # the captain's 14-question brief
bash tests/drives/align-heal/matrix.sh run-1 plain     # a hand-typed idea, no attachments
LCARS_DRIVE_REPO=/path/to/worktree bash …              # run a DIFFERENT checkout (baselines)

# free — prove the rig itself before spending a token
bash tests/drives/align-heal/matrix.sh x holo --dry-run   # engine/pins/shim, no daemon
bash tests/drives/align-heal/capstone-smoke.sh            # the 5 plumbing scenarios
python3 tests/drives/align-heal/standin.py smoke          # the matcher (copilot, free)
```

## What happened (2026-08-29), and why both rigs exist

The captain's capstone died at filing: his PRD dropped 5 of the brief's 14 open
questions, `lcars file` refused (correctly), and the harness killed the filing,
DELETED the drafted PRD and left the card offering a fresh grill. Ten answered
questions, gone, with a defect he did not write and could not fix.

**The live rate is a LOTTERY.** Pristine holodeck runs against the same brief
dropped **5, 2, 1, 0, 0, 0, 0** questions — ~3 in 7 fail, and severity swings
wildly. Three runs a side cannot measure that, so a green matrix proves only
"nothing broke", never "the cure works". That is why `heal-test.sh` exists: it
scripts the WORKER (the thing already measured misbehaving) and leaves the
daemon, `file.sh`, the gate, the exit codes, the heal loop and the draft
handling REAL, so the recovery path is hit on demand instead of by chance.

## Two traps this rig was built around — do not remove these

1. **PIN EVERY SKILL TO THE DAEMON'S CHECKOUT.** The daemon resolves `file.sh`
   from `~/.claude/skills/`, a symlink to the MAIN checkout — so a "pristine"
   baseline silently ran the FIXED `file.sh`. Both rigs now export
   `LCARS_FILE_SCRIPT` / `LCARS_RUN_SCRIPT` / `LCARS_VERSION_CHECK_BIN`.
   Verify the pin bites before trusting a baseline (`grep -c die_prd`).
2. **`/api/align/start` takes `images`, NOT `attachments`.** An unknown key is
   silently ignored, so passing attachments there gives the gate no brief, no
   questions, and a PASS that means nothing. The holo cell reproduces the real
   lane instead: a PARKED mission with its attachments on disk, completed in
   place (`file.sh --complete`), which is exactly how the captain hit it.

The fault injector must also ASK a question or two before returning `done` — a
session with no `last_question` is not resumable for reasons that have nothing
to do with the code under test.

## Reading a result

`heals: N` on a filed mission is the cure working. On the plain (non-holodeck)
path it must always be **0**: a mission with no concept doc has no open-questions
gate to fail, so a heal there means the exit-code split is leaking. `prd-draft.md`
must be absent after a SUCCESS and present after an exhausted cap.

---

## The capstone (S180 part C) — a stand-in that cannot invent an answer

```bash
# 1. cheap: prove the matcher, no grill, no daemon (~7 min, copilot, free)
python3 tests/drives/align-heal/standin.py smoke
bash    tests/drives/align-heal/capstone-smoke.sh     # the gate loop's shape, no workers

# 2. the real thing — FOUR CELLS, each Align → … → Implement → the VERIFY gate.
#    LCARS_DRIVE_ENGINE picks the engine; the mode picks the lane.
export LCARS_DRIVE_TARGET_SRC="$HOME/Projects/DX-Scorecard"
                                bash …/matrix.sh cap-cop-holo  capstone        # copilot · holo
                                bash …/matrix.sh cap-cop-plain capstone-plain  # copilot · plain
LCARS_DRIVE_ENGINE=claude       bash …/matrix.sh cap-cla-holo  capstone        # claude  · holo
LCARS_DRIVE_ENGINE=claude       bash …/matrix.sh cap-cla-plain capstone-plain  # claude  · plain
```

`capstone` is `holo` plus everything after FILED; `capstone-plain` is the same
for the `plain` lane (its mission id is only knowable after filing, so the rig
reads it off disk). **`capstone-plain` needs its own record**: `plain-idea.md`
is a docs-site strip and the default record is the MBR-Builder mission, so
pairing them makes every turn a NO-MATCH by construction and the run dies at
Align before spending. Point `LCARS_DRIVE_RECORD_DIR` at a mission whose
`idea.md` IS that idea. The rig says so before it starts (and in `--dry-run`). Both mint the mission, run a live Align, and then hand the
filed mission to the REAL driver (`run.sh drive --mission <id>`) through
Research → Validate → Plan → Plan Review → Schedule → Implement to Verify,
where the stand-in approves and the (faked) PR merges.

### The engine knob — and how to check WHICH engine actually ran

`LCARS_DRIVE_ENGINE=copilot|claude` (default **copilot**, so an invocation
written before the knob existed is byte-identical). One cell is one engine end
to end: the Align grill AND the cold pipeline workers. They are never split.
**The stand-in matcher is always copilot** — it is free, and it is not the thing
under test.

A persisted `state.json.workerBin` has been measured BEATING the env var (the
daemon reads it and feeds it back in as `$LCARS_WORKER_BIN`, so "env last" does
not save you — this is the money-bug family). So the parked mission's pin is
written as the cell's engine too, and the readout prints **three independent
readings that must agree**:

1. the requested `LCARS_DRIVE_ENGINE`,
2. the mission's persisted `state.json.workerBin` after the run,
3. the claude-spawn count through the PATH shim.

The shim is the one that cannot be fooled by a config file. On a **copilot**
cell it is `tests/drives/undrawn/blockshim` — every claude spawn is REFUSED and
counted, and the count must be **0**. On a **claude** cell it is
`tests/drives/align-heal/countshim` — the same log format, but it `exec`s the
real binary (resolved into `$LCARS_REAL_CLAUDE` before the shim goes on PATH),
and the assertion **inverts**: the count must be **non-zero**. `run.sh usage`
under the readout is the fourth reading, and the expensive one to get wrong.

**The stand-in never writes an answer — it only ever points at one.** A live
`copilot -p` call picks the INDEX of one decision the captain already recorded,
and the reply we send is read off disk from that entry; the model's own prose is
thrown away. Where no recorded decision fits it may instead return verbatim
SPANS of `idea.md`/`prd.md`, and every span is checked byte-for-byte against
those files before it is sent — one span that does not verify collapses the turn
to NO-MATCH. `closing:true` turns are handled without the model at all.

That is the whole point. A stand-in that produced something plausible would make
the capstone pass by fabricating, which is the exact failure this rig exists to
detect. **NO-MATCH is a first-class, reachable outcome** — three negative
controls in `standin.py smoke` prove it fires — and it is what FAILS a run.

### The stop conditions are not the same either side of Schedule

| | up to and including Schedule | past Schedule |
|---|---|---|
| a gate the record settles | answered from the record, counted, reported | — |
| a gate the record cannot settle | **run FAILS**, named in the readout | left parked, never answered |
| intervention | only ever from the record | **only the Verify approve** |

Past Schedule the stand-in may do exactly ONE thing: at the **Verify ship gate**
(the driver's "in review — PR open" halt, which is not an awaiting-human gate) it
runs the real `lcars approve`. That is not an answer — it invents nothing and
reads nothing off the record; it is the captain's one mechanical ship signal. An
awaiting-human gate past Schedule (a blocked Implement ticket, a reconcile
escalation) is still left parked and reported, never answered.

The forge is FAKED end to end: `fake-gh` answers `pr create` / `pr view` /
`pr merge` (with the merge state on disk, so `pr view` honestly says OPEN before
the merge and MERGED after — a fake that always said MERGED would let the driver
mark the Mission Done on its own and the approve would never be exercised), and
the target's `origin` is re-pointed at a **throwaway bare repo inside the run
dir**. `git clone --local` points origin at the captain's REAL repo and Verify's
PR-open does `git push -u origin <mission branch>`; without the re-point, a
capstone writes a mission branch into his working repo.

`LCARS_CAPSTONE_MAX_ROUNDS` stays at **12**. A round is one `run.sh drive`
invocation, and that driver has its own internal stage loop — the 2026-08-30
`runs/cap-1` drive went align → research → validate → plan → plan-review →
schedule → implement → verify in ONE round. Implement's wave loop lives inside
`cmd_implement`, so it consumes no extra rounds either, and the Verify approve
plus its confirming re-drive are deliberately not counted. Rounds are spent only
on pre-Schedule gates, so 12 is still far more than the lane can use.

### Reading the result

`runs/<label>/standin-log.txt` is the deliverable. Every turn: what was asked,
which class it fell in, which recorded decision it pointed at, and the exact
text sent back. **"Zero human answers" is a claim that must be readable off that
file** — the readout's headline is a summary of it, not a substitute.

The readout prints a VERDICT before the headline, and the headline reads `n/a
(NOTHING RAN)` when there is no `result.json`. A drive that dies before its
first turn must never be able to report `0`.

### Knobs

```
LCARS_DRIVE_ENGINE=copilot|claude
                                the cell's engine — grill AND pipeline workers
                                (default copilot). NOT the stand-in matcher.
LCARS_DRIVE_TARGET_SRC=<repo>   clone this as the mission target (local clone, no
                                network). WITHOUT it the target is an empty
                                throwaway repo — fine for Align, but Research and
                                Plan then have no real code to read.
LCARS_DRIVE_RECORD_DIR=<dir>    the mission whose idea.md/prd.md IS the record
LCARS_STANDIN_ON_NOMATCH=stop   bail on the first unrecorded question
                     (default: continue — send an explicit NOT-IN-THE-RECORD
                      marker so ONE 30-minute run surfaces every one of them;
                      the run is failed either way and the pipeline is not run)
LCARS_STANDIN_MODEL=…           matcher model (default claude-sonnet-4.5)
LCARS_CAPSTONE_MAX_ROUNDS=12    driver rounds before the rig gives up
LCARS_REAL_CLAUDE=<path>        the binary the countshim execs (auto-detected)
LCARS_FAKE_PR_URL=<url>         the PR url fake-gh's `pr create` returns
```

### Proving the rig itself, for free

`matrix.sh <label> <mode> --dry-run` (or `LCARS_DRIVE_DRYRUN=1`) assembles the
WHOLE cell — target clone, throwaway origin, parked mission with its engine pin,
the skill pins, the shim choice — asserts the pins exist, prints what it would
run, and stops before the daemon. No worker, no grill, no spend.
`capstone-smoke.sh` then drives `capstone.py` through five scripted scenarios:
a pre-Schedule gate the record settles, one it cannot, the Verify approve (real
`approve.sh`, real `git push` into a throwaway bare origin, faked forge), an
Implement gate left alone past Schedule, and both engine cells via `--dry-run`.

### Daemon safety

The trap is `kill -9 $DPID` on the ONE pid this script started. Never `pkill`
or `killall` by name — the captain runs his own viewscreen daemon in parallel
sessions and a pattern kill takes it out.
