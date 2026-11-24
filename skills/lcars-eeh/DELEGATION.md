# DELEGATION.md — how an LCARS orchestrator decides WHO does a unit of work

This is the **one** statement of how much orchestration a unit of work gets, who
owns it, and what a hand-off must say. `ORCHESTRATION.md` is its sibling: that
file owns **the loop** (implementor → fresh tester → fix rounds → teardown →
commit → readout). This file owns **the sizing judgement** that happens before
the loop starts, and the contract a delegate is handed.

**Where this file comes from.** It was written on 2026-11-11 (S350) because the
rules in it had never been written down anywhere. `HOLOGRAM-COMMAND-MODE.md` was
1,507 lines and the words *sub-agent*, *spawn* and *delegate* appeared in it
**zero times**. Everything the captain had watched the ECH do well — stand up a
second ECH for a chunk of work, stand up a tester at a Verify gate that came back
with evidence and a bug list to file — existed only in the prompts he typed at
the time. Prose nobody writes down does not survive a session: it drifted every
night, and the captain was the prompt. These rules are now on disk, and
`lcars-ech tier` prints the relevant one at the moment a seat commits to it.

**A rule without its reason gets undone**, so each one below keeps the evidence
that justifies it.

---

## Who reads this

The same three consumers as `ORCHESTRATION.md`, which is exactly why this is a
sibling file and not a section of the ECH playbook — all three gain delegation
at once:

- **`lcars eeh`** / **`lcars ech`** — the ECH, driving the factory for the
  captain while he is away.
- **`run-session`** (lcars-dev) — orchestrates one session from a `*-dev.md`
  session-plan doc.
- **`night-watch`** (lcars-dev) — chains sessions unattended.

Read it the mount-independent way, from any cwd and under either install farm:

```bash
lcars-eeh docs delegation          # prints this file
lcars-eeh docs --path delegation   # just its absolute path
```

**This file wins over any restatement.** If a skill, a doc or a prompt says
something different about tiers, hand-offs or who verifies, this file is right
and that text is a stale copy — delete the copy and point here.

---

## The three tiers

**A tier is defined by THE JUDGEMENT IT ABSORBS — never by how many writers it
adds.** This is the distinction that matters and the one that gets lost first.
More parallel writers is not what a higher tier buys; a tier buys you *not
having to make a class of decision yourself*. Pick the tier by asking "which
decisions am I handing away?", not "how do I get more done at once".

<!-- tier:T0 -->
### T0 — the ECH does the unit itself

No delegate. The ECH drives the unit through the factory's verbs exactly as it
does today, and every judgement in it is the ECH's own.

Choose T0 when the unit is small enough that a hand-off would cost more than the
work, or when the context needed to do it is already loaded and would have to be
rebuilt in someone else's head.

T0 absorbs nothing, because there is nobody to absorb it for you.
<!-- /tier:T0 -->

<!-- tier:T1 -->
### T1 — one delegate owns the unit end-to-end, and ABSORBS ITS OWN STUMBLES

ONE delegate owns the unit from start to finish. What it absorbs — and this is
T1's whole value — is **its own stumbles**:
a failed test, a contradicted premise, a ticket that will not go green.
It cures those itself, through the factory's own verbs, and reports up in
summaries.

**A delegate that escalates every stumble is worth nothing over T0.** If each
red test comes back to the ECH as a question, the ECH is doing the unit anyway
plus paying for a round trip — that is T0 with extra latency, and it is the
failure mode to watch for. The absorption obligation goes in the brief, out
loud, every time.

What it may NOT absorb: a scope change, a product call the captain owns, or a
conflict with a standing rule. Those are the ECH's to raise, through
`lcars-ech ask` — and they stay inside the interrupt budget
(`HOLOGRAM-COMMAND-MODE.md` § 9). **Delegation adds no new interrupt category:
a delegate's problem is the ECH's problem.** A delegate gets one of them TO the
ECH with a `BLOCKED:` beat — § *The exit door, named* — and never by running
`ask`, which is the ECH's own verb and reserved to it.
<!-- /tier:T1 -->

<!-- tier:T2 -->
### T2 — T1, plus an independent FRESH-CONTEXT tester at the gate

Everything T1 is, plus a **separate** tester/reviewer at the unit's gate that
never saw the implementor's reasoning. It returns evidence and a bug list, and
the ECH that OWNS THAT CHUNK files them — § *AUTHORITY TRAVELS WITH THE CHUNK*.

**This is the single best-evidenced pattern in the research behind this file.**
Cognition measured roughly **2 bugs per pull request, 58% of them severe**, and
found that a reviewer works **better with clean context than with the
implementor's history** — the implementor's reasoning is precisely what makes a
reviewer agree with a wrong premise. Fresh context is not a nice-to-have; it is
the mechanism.

**LCARS ALREADY OWNS THE TESTER RULES. READ THEM THERE.** What a tester is,
what it may touch, how it reports and what it must confirm first are all defined
in `ORCHESTRATION.md` § *The loop* (step 2) and § *The tester opens the real
product first*:

```bash
lcars-eeh docs orchestration   # § The loop, step 2; § The tester opens the real product first
```

That file is the authority and this one does not repeat a word of it. **A second
copy of a rule is a rule that drifts** — it is how the tester brief ended up
saying three different things on three different nights. Point the tester at
those sections; do not paraphrase them into its brief.

That tester is **additive** to the ECH's own check (§ *The unconditional
gate*) and **does not replace** it.

A T2 delegate **may** also divide the unit — into **Missions it hands to the
factory**, as many as the work divides into — but **division is a means, not the
point**. The point is the extra independent pair of eyes at the gate. If
dividing the unit does not buy you that, it buys you nothing. What it may
**not** do is mint a sub-ECH of its own: see § *ONE LAYER, AND WHAT STILL GOES
UP*.
<!-- /tier:T2 -->

---

## The tier is the ECH's own FREE JUDGEMENT

**Captain's ruling, 2026-11-11.** The tier is chosen by the ECH, freely.

The factory's own estimate (`lcars run estimate`, which writes
`missions/<id>/estimate.json` with a `reasoningCriticality` and an
`implCriticality`) is an **input the ECH must be shown and may disagree with**.
It is **not a floor**, it is not a minimum, and it must not constrain the
choice. A high/high estimate tiered T0 is a legitimate call; so is a low/low
estimate tiered T2.

What *is* mandatory is that the judgement and its reason are **recorded**:

```bash
lcars-ech tier <unit-id> --tier T0|T1|T2 --why "<the reason>"
```

**The reason is ONE LINE.** `tier` refuses a missing `--why`, an empty one, and
a whitespace-only one — three spaces is the same shrug as none — and it refuses
a multi-line one too. A reason goes into a permanent ledger that `status`,
`delegates` and the minted brief each print on one line, and a value with
newlines in it interpolated into a brief can forge the brief's own structure: a
`--why` whose second paragraph began `## 5.` minted a brief carrying a FORGED
copy of its verification section, 107 lines above the real one, saying to skip
the live check. Say the reason in one line; the detail belongs in the hand-back.
No value derived from input may create or alter a heading, a section boundary or
emphasis in a minted brief — the minter renders every such value inert as well,
because a hand-edited record, a mission title and a `prd.md` can all carry the
same markers.
 A sizing call with no reason on disk
is a shrug, and this one is going in the permanent record: the whole point of
writing it down is that next week somebody can tell a deliberate T0 from a
forgotten one. It records the tier, the reason, the timestamp, **and the
estimate it was shown** — so a disagreement with the factory is visible as a
disagreement rather than as ignorance.

Re-tiering is allowed and **appends**: the new judgement becomes current and the
previous one survives in the unit's ledger, nothing destroyed on write. That is
the same shape as the questions ledger, for the same reason.

---

## The four things every hand-off must state

A hand-off that is missing any of these produces delegates that duplicate each
other's work and leave gaps between them. `lcars-ech delegate <unit-id>` mints a
brief carrying all four from the unit's own artifacts, so none of them depends
on the orchestrator remembering:

1. **The goal** — what is true when the unit is done, as a checkable statement,
   not a topic.
2. **The output format expected back** — the shape of the hand-back, so the ECH
   does not have to parse prose to learn what happened.
3. **Which verbs** — the LCARS verbs in scope for this unit, named. A delegate
   that does not know its verbs invents a second route to the same outcome,
   which is what front-door doctrine exists to prevent
   (`HOLOGRAM-COMMAND-MODE.md` § 4a: never hand-step the stage machine). **That
   rule applies to a delegate exactly as it applies to the ECH.**
4. **Where the boundaries are** — what this unit does NOT cover, which files or
   missions it must not touch, and what belongs to a sibling.

A brief is minted **from artifact paths alone** — the unit's record, the
mission's `state.json`, and the tier contract above. Never from the
orchestrator's transcript: a transcript is not on disk, so a brief built from
one cannot be re-minted, reviewed, or trusted a day later.

**A chunk need not have a Mission yet.** At either T1 or T2, hand its goal to
the product with `lcars-ech delegate <unit-id> --goal <file>`. The file must be
readable and non-empty. Its text is snapshotted as `GOAL.md` beside the brief
and carried in section 1, escaped like every other artifact-derived value.
The record says `goalSource: chunk-goal` and names the snapshot in `goalRel`.
An explicit chunk goal takes precedence over a Mission's narrower PRD; without
the flag the existing PRD/title/no-goal behavior is unchanged. A sibling
validator inherits the driver's snapshot, not a later edit to the source file
and not a replacement goal supplied at validation time.

---

## NO SILENT HOURS — the beat

A delegate **declares N**, its total number of checkable steps, before starting
and **emits one beat per step**, as it finishes it, reporting the current K:

```bash
lcars-ech beat <delegate-id> "<one line of what you just did>" --step K/N
```

Why: a beat without a step proves you are alive, not that you are getting anywhere.
The step is optional for existing callers; without it a beat is unchanged.
When supplied it must be whole numbers with `1 <= K <= N <= 1000000`; junk
refuses before anything is recorded. Each reported step stays on its beat in
the append-only ledger, alongside the latest `delegates.<id>.step = {k, n, at}`.

**Why this exists, and why it is not optional.** `HOLOGRAM-COMMAND-MODE.md` § 8
carries the single biggest measured defect in this mode: *a wait has a limit, a
re-check, and an action on expiry* — four seat models out of four, across three
model families, stopped dead where that rule was missing, because *a seat that
waits for ever is indistinguishable from a dead one*. Every mechanism the ECH
has for enforcing it — `waitingSince`, `await`, `watch`, `stalled`, the crontab
`heartbeat` — guards **a process the ECH started itself** and decides from a
**recorded pid**. A delegate has no pid here. Without a beat, a delegate that
produces nothing for three hours is invisible to all of it, and the ECH finds
out in the morning.

**The limit, the re-check and the action, in the same three parts as § 8:**

- **The limit.** `1800` seconds — thirty minutes — between beats, overridable as
  `LCARS_ECH_BEAT_LIMIT` exactly as `LCARS_ECH_WAIT_LIMIT` bounds a wait. The
  brief a delegate is handed **states the limit it is held to**, so the
  obligation travels with the hand-off instead of living only here.
- **The re-check.** `lcars-ech stalled` — which the crontab heartbeat already
  runs every hour, unchanged — names every delegate whose last beat is older
  than the limit, and every delegate that has **never** beat and was minted
  longer ago than it. `lcars-ech status` shows the minutes since each delegate's
  last beat on the same line as its tier. A delegate whose status is `done` is
  never reported: it is quiet because it finished.
- **The action on expiry.** The report does **not** say "it is stuck". It names
  the delegate, its unit, its tier, how long it has been quiet, the limit it is
  **measured against**, and its last words — then gives three real verbs to pick
  from: **re-brief** it, **replace** it (`delegate close`, then a fresh
  `delegate`), or **raise it with the captain** (`lcars-ech ask`). **One beat
  clears the line.** The minted limit is **recorded** at
  `delegates.<id>.beatLimit`, so a delegate briefed under one limit and measured
  against another is told both figures rather than being told one of them as a
  fact.

**BEATING BUT NOT MOVING is a separate signal, not silence and not a verdict.**
Three step-bearing beats without K advancing trigger it, even inside the silence
limit. `LCARS_ECH_STEP_STALL_BEATS` overrides that threshold (whole numbers from
2 to 1000, default 3); one beat cannot show a lack of motion. Only a higher K
starts a new run: changing N or going backward does not. A beat without a step
neither claims an advance nor adds an observation to this count; a delegate
that never reported a step is never judged not-moving, and a `done` delegate
is never reported. `stalled` names the delegate, unit, tier, current step, beat
count, duration, applied threshold and last words, then the next action:
re-brief it with a smaller step, replace it, or raise a captain-owned call.
An advancing step clears this signal; another pulse at the same step does not.
The signal has its own tally and survives alongside a silence or BLOCKED signal.
`status` adds the step to its existing delegates line, `next` banners the
attention without changing the plan, and the unchanged heartbeat gets it through
`stalled`.

**GOING IN CIRCLES is the fourth lane, and the one a step number cannot see.**
Silence says nothing came back; `BLOCKED` says the delegate asked for something;
BEATING BUT NOT MOVING says the step is not climbing. None of the three sees the
delegate that is busy, talking, and doing **the same work over and over**. So a
beat reporting work the delegate has **already reported in the same words** three
times **running** is named GOING IN CIRCLES, with its own tally, the work that
repeated quoted back, how many times, the threshold applied and the next action.
`LCARS_ECH_CIRCLE_BEATS` overrides the threshold (whole numbers from 2 to 1000,
default 3); one report of a piece of work cannot show a repetition.

**The repeats have to be CONSECUTIVE, and the line CLEARS.** The tally is the
length of the delegate's *current* run of one piece of work, not a count over its
whole life, because both of those matter to whether the lane can be trusted. A
**different** beat resets it, so real work interleaved between repeats — "waiting
on the suite" / "t-001 green, 3 files changed" / "waiting on the suite" — is not
a circle and is not reported as one; and an **advancing** `--step K/N` restarts
the run, so a delegate that repeats a line while its step climbs is working, not
circling. Those are the two things the report names as clearing the line, and
they clear it for real: one beat of different work is enough, and an accusation
cannot outlive the loop that earned it. The brief a delegate is handed **states
this threshold** alongside the silence limit, so the obligation travels with the
hand-off, and § 2's beat example asks for *what changed* rather than a line
computed from K and N — a brief whose own example repeats itself manufactures the
accusation it warns about. A `done` delegate is never reported. The actions are
the same three real verbs — re-brief it with a *different* approach, replace it,
or raise the call it is circling on with the captain — and **a kill is not among them**: there is still no pid for a delegate.

**Why it is keyed on THE WORK and never on the step not incrementing.** The
signature was read out of the S353 capstone's own records rather than guessed.
The true positive is there: ticket `t-001` burned all three of its TDD sessions,
and two of them ran the *identical* gate command and failed on the *same* single
out-of-scope file. So is the trap — delegate `d2` beat **five times at the same
step 2/7**, and every beat carried different work ("research done (10 agents),
validate running" → "validate/plan(5 tickets)/plan-review/schedule(4 waves)
done, implement running" → "implement wave 1/4, ticket t-001 in progress" → …).
A detector keyed on the step number would have accused a delegate that was
visibly advancing, and a lane that cries wolf is one the ECH learns to skip.

**AND WHAT THIS LANE CANNOT CATCH, SAID IN ITS OWN FOOTER.** It compares the
delegate's own words, and only where the repeats are **consecutive**. Two shapes
are therefore not named by it. A delegate that loops while **rewording** each
beat is not caught by it — nothing this product records would show that, since
the ECH holds no clock, path or working tree of a delegate's beyond the beats it
sends. Nor is a loop that **alternates** between two or more different reports —
"ran the scope gate: FAIL" / "reverting, trying the same fix again", round and
round — because the different beat that *clears* the line is also the beat that
restarts the tally, so only a cycle of length **one** ever reaches the
threshold. Measured: that two-beat cycle run four times round scores nothing,
and one filler beat between repeats hides a real loop just as well. That is the
price the consecutive rule charges for the false positives it cures, and it is
why this lane is a NARROW signal and not a loop detector: the loops this factory
actually produces — gate red → revert → retry, research → plan → research → plan
— are mostly longer than one beat. The report says so where it reports; a lane
that stays SILENT prints nothing at all, so this paragraph is where the reader
of a quiet report learns it. BEATING BUT NOT MOVING is the half that still
catches both of those shapes while the step is not climbing, and reading the
artifacts is the half neither lane can do.

**A BROKEN LIMIT DEGRADES; IT DOES NOT REFUSE.** A `LCARS_ECH_BEAT_LIMIT` that
is not a whole number of seconds — `30m` is the one a model types after reading
the line above — is **not applied**, the documented `1800` is used instead, and
the problem is said out loud twice: once on stderr and once in every report line
that applies the limit. It is never a refusal: the first version of this check
was one, and in a repo with **no delegates at all** it stopped `lcars-ech
stalled` reporting a failed mission and took `next`, `status` and `playbook`
down with it. A limit with nothing to measure must never silence machinery that
does not read it, and `stalled` always exits 0.
The motion threshold follows the same discipline: a malformed or out-of-range
value falls back to 3, warns on stderr and in every motion report that applies
it, and never silences an unrelated report. So does the repetition threshold
(`LCARS_ECH_CIRCLE_BEATS`), with a known-good control holding it: after a
rejected value the circles lane still fires on a real loop, against the stated
default.

**AND A CLOCK THAT CANNOT BE READ IS REPORTED, NOT SKIPPED.** A delegate whose
recorded timestamp will not parse, or sits in the future, is **UNTIMEABLE** —
`stalled` names it and says what it does not know, instead of staying quiet,
which from outside reads exactly like all-quiet. That lane has its own tally and
its own actions: one beat, `delegate close`, or repair the record.

**WHAT EXPIRY IS NOT.** It is not a kill. The ECH has no process of a delegate's
to kill, and nothing in this path kills anything — kill discipline is unchanged
and still only ever by a recorded pid or its isolated process group. It is also
**not an interrupt**: a silent delegate reaches the **ECH**, never the captain.
The interrupt budget (§ 9) gains nothing from delegation, and a delegate's
problem is the ECH's problem.

---

## Only summaries travel up

A delegate reports in **summaries**, **never raw transcripts**. The ECH's
context is the scarcest thing in the system and a pasted transcript spends it on
material the delegate already acted on. A summary names what was done, what is
still open, and what it could not resolve — and it is the delegate's job to
have absorbed everything a transcript would have shown.

---

## THE UNCONDITIONAL GATE — at EVERY tier, including T0 and T1

**Captain's instruction, 2026-11-11. Delegation creates no exception to this.**

When a unit's work is done, **the ECH verifies it itself**, whatever the tier
and whoever did the work.

**THE SEQUENCE LIVES IN `HOLOGRAM-COMMAND-MODE.md` § 6 AND § 6a, NOT HERE** —
Number One's verdict, the ECH's own `live-check`, `policy`'s one action,
`file-bug`, and the send-back loop. Read it there:

```bash
lcars-eeh docs ech   # § 6 The Verify gate; § 6a The merge policy
```

That file is the authority and this one does not restate it. It already carries
the standing job in its own words — *"do the live check yourself every time,
regardless of its verdict. This is your standing job, never a fallback."* — and
a second copy of those steps here is a rule that drifts: the two copies had
already diverged, each omitting a step the other had, within a day of this file
being written. The evidence behind the rule is decisive and belongs to both: on
the modelled run Number One filed **0 of 31** bugs, and **every one of the 31
came from the ECH's own live check**.

What is **this file's own** — the three things that are true because of
DELEGATION, and the reason delegation needs no exception in § 6:

- **A delegate's hand-back is a REPORT, never a verdict** about the WHOLE. The
  ECH above it verifies the whole independently of it, every time. A hand-back
  that says "all green" is an input to that check, not a substitute for it. What
  it is NOT any more is a report about its own chunk waiting for someone else's
  look: a sub-ECH **validates its own chunk itself** (§ *AUTHORITY TRAVELS WITH
  THE CHUNK*), which is § 6's standing job applied per ECH, not an exception
  to it.
- **T2's dedicated tester is ADDITIVE.** It is an extra, independent pair of
  eyes on top of the ECH's own looking. It **does not replace** the ECH's check
  and no tier may be configured to skip it. A higher tier buys you more eyes; it
  does not buy the ECH's own eyes back.
- **Nothing advances on a delegate's word.** `lcars-ech delegate close` marks
  the *delegate* done and touches neither the mission's stage nor its verdict.
- **A unit can be delegated more than once, and usually is.** The gate above
  exists so the ECH finds bugs in a delegate's work, so a second pass at the
  same unit is the normal case. An **open** delegate blocks a second mint — two
  briefs for one unit is how two delegates end up doing the same work — but a
  **closed** one does not: `lcars-ech delegate <unit>` mints a fresh delegate
  beside it and names what it supersedes. The record is append-only, so the
  closed delegate keeps its id, its brief and its close time, which is why
  `delegate close` can go on refusing a second close.

---

## AUTHORITY TRAVELS WITH THE CHUNK

**Captain's ruling, 2026-11-20.** A **sub-ECH owns a chunk**: it hands it to the
factory, makes sure it lands, **validates it, files its own bugs and drives its
own fixes** until the chunk meets the ask. The **main ECH** owns the overall ask,
decides the chunking, and verifies **the whole** at the end. *"Each ECH verifies
its own chunk, and the one above it verifies the whole."*

**THIS IS A RE-READING, NOT A REVERSAL, AND THAT MATTERS.** The narrow rule it
replaces cites his instruction of 2026-11-11 and the evidence that Number One
filed **0 of 31** bugs while the ECH's own live check found all 31. That evidence
says *an automated reviewer's verdict is no substitute for a real look.* It does
**not** say *only one ECH may ever look.* **A sub-ECH IS an ECH doing its own
real look**, so `HOLOGRAM-COMMAND-MODE.md` § 6's standing job is **unchanged**
and now applies **per ECH, to the scope that ECH owns**. What changed is *which*
ECH owns *which* scope — nothing about the look itself got weaker.

**AND THE NARROW READING HAD A MEASURED COST.** On the 2026-11-18 capstone the
delegate found real defects and could not file them, so the supervisor filed
four through the front door exactly as briefed — and **those four filings are
what then blocked the parent Mission from being accepted at all.**
`resolve-logs` *orders* logged bugs but does not *drive* them, so clearing the
gate meant four full pipelines. On that build, **an ECH that filed bugs against
a live Mission had ended that Mission's run.**

### WHAT A SUB-ECH MAY AND MAY NOT DO

| | verb | in its OWN chunk | outside it |
|---|---|---|---|
| files its own bugs | `file-bug` | **yes**, recorded with its owner | **refused**, naming whose chunk it is |
| its own verify gate | `live-check`, `live-check done` | **yes** — § 6's standing job, per ECH | **refused** |
| the action for the verdict pair | `policy` | **yes** | **refused** |
| drives its own fixes | `drive` | **yes** | **refused** |
| publishes its tested fix head | `exec --refresh <mission>` | **yes**, driving seats only; no merge or stage change | **refused** |
| waits for a shared slot | `exec --await --limit <seconds>` | **yes**, bounded; no board mutation | n/a |
| the factory's front door | `exec lcars-file/file.sh`, `lcars-log/log.sh`, `lcars-run/run.sh`, `lcars-respond/respond.sh`, `lcars-resolve-logs/resolve-logs.sh` | **yes** — and a `--mission` outside the chunk is refused | **refused** |
| every other sibling script | `lcars-approve`, `lcars-answer`, `lcars-feedback`, `lcars-init`, `lcars-xo`, `lcars-eeh` | **never** — `exec` has its own allow-list | **never** |
| subdivides its own chunk into Missions | `exec lcars-file/file.sh` | **yes** — each one JOINS its chunk | n/a |
| raises it with the ECH | `beat … "BLOCKED: …"` | **yes** — the only channel up | n/a |
| the captain's attention | `ask` | **never** | **never** |
| the landing decision | `land`, `approve`, `push-gated` | **never** | **never** |
| the ECH's own bookkeeping | `record`, `tier`, `delegate`, `grant`, `answered`, `init` | **never** — this is the escalation chain | **never** |
| machinery and the ECH's board | `worktree`, `workflow-run`, `heartbeat`, `watch`, `await`, `_waiter`, `status`, `next`, `stalled`, `delegates`, `playbook`, `report`, `engines` | **never** — not on the allow-list | **never** |

### FINISHING A CHUNK, AND THE TWO-MISSION CAP

The shared driver permits **two concurrent Missions**, across all seats, not
two per seat. Two or three sub-ECHs are normal; the third Mission waits, not
the third seat's entire chunk. A refused drive is **not queued**. When both
slots are occupied, use `lcars-ech exec --await --limit 600` instead of polling.
Exit 0 observes a free slot but **does not reserve it**: retry your own drive;
if another seat wins it, the bounded wait is still the route. Exit 124 ends
the wait: report ONE `BLOCKED:` beat so the main ECH can inspect its drivers.
Do not restart the wait or turn it into a polling loop.
This lane changes neither the main ECH's `await` behavior nor its board.

**This is not a Mission-completion wait.** A free slot does not establish a
Mission's exit, Verify gate or success. Its waiter records the process exit;
hand that Mission id back to the main ECH, which owns board inspection and
stalled-driver recovery. Neither `await` nor `exec --await` queues work,
reserves capacity or wakes a seat on a particular Mission's completion.
Subsequent driving-seat briefs carry this parallel contract once another chunk
has been delegated; an already handed-off brief is not silently rewritten.

### INTEGRATION HANDOFF — THE MAIN ECH OWNS THE COMBINED RESULT

The **MAIN ECH owns cross-chunk integration**, not either chunk and not an
improvised third seat. A real recovery merge conflict still parks for a human;
the refusal names this **integration handoff**. The sub-ECH sends ONE
`BLOCKED:` beat with the Mission id, conflicting paths and the two intents.
It does not reach into its sibling's chunk or bypass the gate.

There is **no re-integrate verb**. The main ECH reads the recovery diagnosis,
settles the combined intent (asking the captain only for a product decision),
and routes any repair through the existing factory front door, as a bounded
integration Mission if needed. That is a composition repair, not another
whole-chunk validation and not permission to hand-merge, rebase, force, edit
control state or grant a seat authority over its sibling. Clear the blocker
FIRST, then answer the existing recovery gate: answering resumes the drive.
The main ECH verifies the combined result and retains the landing decision.
An unresolved human gate stays unresolved; naming an owner is not a new
automatic conflict resolver.

After `resolve-logs` folds fixes locally, run the chunk's own live check and
`policy`. With Number One OFF, omit `--verdict`: the recorded live-check
verdict decides, without inventing a Number One score. On pass, run
`lcars-ech exec --refresh <mission>`. It tests the exact detached Mission head
with the recorded `testCommand`, refuses a red suite (including success-shaped
`FAILED` output) or a moving head, and pushes only that tested commit to that
Mission's branch. It also retries any required forge review against the new
head. It never pushes the base, merges, advances the Mission or grants landing
authority. A validation pass cannot use it: publishing fixes is the driver's
act. Hand the result back to the main ECH, which still verifies the whole.

These are modes of the existing `exec` verb, not a wider sibling-script
allow-list. Existing nine-verb briefs remain byte-identical; this section and
`--help` document the added modes.

### IT IS A BOUNDARY, NOT A SET OF CHECKS

**S365 fix round 2 (F5), and this is the shape of the rule rather than a detail
of it.** The first build added authority as *checks on particular verbs*. The
gate was opt-in and six verbs opted in; about twenty did not. A fresh tester
walked through it with real verbs and no hand-editing:

> `d1` (chunk `m-mine`) is refused on `m-theirs` — the gate works. Then
> `record missions.theirs.id …` → *recorded*. Then `tier theirs --tier T1 …` →
> *TIER: T1*. Then `delegate theirs` → **MINTED: d2**, with a real brief. Then
> `LCARS_ECH_AS=d2 live-check m-theirs` → **granted**.

**A sub-ECH minted itself a seat over a chunk it was never handed.** The
identity mechanism refused all sixteen forgery attacks and was *irrelevant*,
because the seat never had to guess an id — it issued one. With
`record delegates.<id>.status` it could open and close any seat at will, which
is the very field the accept gates read.

**So a sub-ECH may run exactly the verbs its brief names, and the dispatcher
refuses everything else before the verb's arguments are read:**

```
beat exec budget ledger file-bug live-check policy drive request-validator
```

Four of those nine are **also** scoped to the chunk. **The boundary says which
VERBS; the chunk says which MISSIONS.** The list lives in ONE constant
(`SUBECH_VERBS` in `ech.sh`) and the minted brief is rendered from it, so the
rule a delegate is held to and the rule it is told cannot drift. **A verb added
to LCARS tomorrow is denied to a sub-ECH until somebody grants it on purpose** —
that is the whole difference between a boundary and a twenty-first check.

### AND IT BOUNDS WHAT A SEAT *DOES*, NOT JUST WHAT IT NAMES

**S365 fix round 3, and it is the same restructure applied to the other half of
the same door.** Round 2's boundary bounded the verb names. `exec` reaches a
sibling script, and the acts those scripts perform were not bounded at all.
Measured, same fixture, `LCARS_ECH_AS=d1` whose chunk is `m-other`:

> `lcars-ech land m-land` → **DENIED**, "NOT A VERB A SUB-ECH MAY RUN".
> `lcars-ech exec lcars-approve/approve.sh --mission m-land` → `pr-merge` calls
> **1**, and `m-land`'s stage afterwards **`done`**.

**It merged a Mission it was never handed.** `land`, `approve` and `push-gated`
are each refused by name, each with its own sentence about landing being the
main ECH's one decision — and the identical decision was one `exec` away. And
not one door: as `d1`, `exec` also reached `lcars-init/init.sh` (the reset that
drops delegate records and releases claims), `lcars-xo/xo.sh` (Number One —
billed model spend the captain has ruled OFF), `lcars-run/run.sh` on any Mission
with no chunk check, and `lcars-answer` / `lcars-feedback` as further routes to
the Review decision. Only `lcars-eeh/ech.sh` was safe, and **by accident of
environment inheritance rather than by design.**

**So `exec` has its own allow-list, in its own one constant
(`SUBECH_EXEC_SCRIPTS`), rendered into the brief the same way:**

```
lcars-file/file.sh  lcars-log/log.sh  lcars-run/run.sh
lcars-respond/respond.sh  lcars-resolve-logs/resolve-logs.sh
```

Those are the scripts the brief actually hands a delegate. Everything else is
refused by name, with the reason: `approve` merges, `init` resets,
`answer`/`feedback` are the Review decision, and **`xo.sh` is DENIED because it
is billed model spend and Number One is OFF by the captain's standing ruling of
2026-11-20** — it was in the delegate's own verb list until this round and is
not any more. A seat that needs a verifier raises a `BLOCKED:` beat.

**AND AN ALLOWED SCRIPT STILL OBEYS THE CHUNK.** `lcars-run/run.sh` is on the
list because it *is* the delegate's front door, and it takes `--mission` — so
without this, the chunk check on `drive` was one `exec` away. A `--mission`
outside the chunk is refused exactly as the verb would be. (`--parent` is
deliberately not checked up front: a creation under a foreign parent is caught
after the fact, where it is recorded to nobody and said out loud, so the Mission
exists and belongs to no chunk rather than `lcars log` being stopped mid-write.)

**`LCARS_ECH_AS` IS INHERITED BY A RE-ENTERED `ech.sh`, ON PURPOSE.** That is
the only reason `exec lcars-eeh/ech.sh delegate theirs` was ever refused, and
until this round it was an accident of environment inheritance that nothing
stated or tested. It is now a declared, tested property: a seat does not shed
its identity by re-entering this program, and `exec`'s own allow-list refuses
`lcars-eeh/*` besides, so the property is a belt rather than the only strap.

**`ask` and `land` STAY WITH THE MAIN ECH, and the refusal names it.** `ask`
prints *QUESTION FOR THE CAPTAIN* and fires his notifier: the interrupt budget
has exactly four categories, it is **the captain's**, and the main ECH is the one
seat that spends it — delegation still adds no fifth. `land` is one decision
about the **whole ask**, and the seat that makes it is the one that verifies the
whole. A refusal that only says *no* leaves a seat with nowhere to go, so each
one **names who owns the verb** and hands back the `BLOCKED:` beat.

### WHICH SEAT IS RUNNING A VERB — `LCARS_ECH_AS`

Authority has to be attributable, so a sub-ECH **declares itself**:

```bash
export LCARS_ECH_AS=<delegate-id>      # every verb this seat runs
```

**Unset means the main ECH**, which is every invocation that existed before this
rule and every repo that has never minted a sub-ECH — so nothing changes where
nobody asked for it. **A value the record does not back is REFUSED, never
promoted:** that variable is the one thing carrying authority, so a typo in it
must refuse rather than hand over everything, and a **closed** sub-ECH is
refused too (it handed its chunk back; it drives nothing). The minted brief
states the export, so the obligation travels with the hand-off — S359's lesson
the hard way: *a brief that does not state the rule it holds a delegate to
manufactures its own false positives.*

### THE CHUNK, AND WHERE IT STOPS

A sub-ECH's chunk is **three** things:

- **its SEED** — the Mission its unit resolves to (`delegates.<id>.mission`);
- **every Mission IT ITSELF FILED**, through `lcars-ech exec`;
- **every bug Mission logged beneath any of those, at any depth** — a bug
  logged against a bug is the same piece of work and the same seat is driving
  it.

*(Bulleted, not numbered, deliberately: `tests/delegation.test.sh` § D10 asserts
that the span from the unconditional gate to the verbs restates no numbered
sequence of its own, because a second copy of `HOLOGRAM-COMMAND-MODE.md` § 6's
steps is how the two drifted apart in a day. A numbered list anywhere in that
span trips it, and the assertion is right to be crude.)*

**The second of those IS THE CAPTAIN'S OWN DEFINITION, 2026-11-20:** *"sub echs can chunk the
work they want to the factory how they see fit. So if they get told add fish to
the river system that's impacted by water level, they can sub divide the
missions they feed the factory as it makes sense."* A sub-ECH handed one chunk
is **expected** to file several Missions for it — the fish data, the water-level
coupling, the cast verb — and drive all of them. With only (1) and (3) it would
be refused on two of its own three.

**IT IS RECORDED, NOT INFERRED, AND IN THE SAME RECORD.** For a live sub-ECH's
`exec lcars-file/file.sh` or `exec lcars-log/log.sh`, the producer reports each
new Mission id through a private, per-invocation filing receipt. `exec` writes
only those ids to `chunk-owners`. Both filing lanes (`--prd` and `--park`) and
every bug in a log batch use that channel. A completion of an existing parked
Mission reports no new creation. Nothing is inferred from directory changes or
console output, and a failure to write a receipt is an explicit filing error.

**AND THE ROUTE MATTERS, WHICH IS A COST THE FRONT-DOOR CONTRACT ALREADY
CHARGES.** `lcars-ech exec` is the one place a creation can be attributed, so a
delegate that goes around it (`bash .../file.sh` by hand) gets no ownership
recorded and its Mission is **out of chunk** — every verb on it refused, with
the refusal naming the front door. That is the safe direction: an unattributable
Mission earns a refusal, never a silent grant.

**AND A CREATION IS SCOPE-CHECKED BEFORE IT IS RECORDED (F2).** Round 1 claimed
*any* new Mission with no scope test, so `exec lcars-log/log.sh --parent <a
sibling's Mission>` handed the seat a bug under someone else's work and pulled
that Mission into its chunk — both gates then let the sibling's Mission through.
A creation is claimable only when it is a **new root** (no parent: the
subdivide-as-you-see-fit case) or when its parent chain **already reaches this
chunk**. Anything else is **recorded to nobody** and said out loud, which leaves
it outside every chunk — so it blocks its parent's accept and every verb on it
is refused.

**THERE IS NO ATTRIBUTION WINDOW (S370).** The before/after implementation
claimed that overlapping filings only widened a chunk. The capstone measured
the opposite: because `chunk-owners` is latest-line-wins, one seat finishing
later **transferred the other seat's Mission** to itself. Filing takes minutes,
and two parallel seats are the default. Separate producer receipts remove that
window entirely; other seats' and the main ECH's creations are not in this
call's receipt. Non-creating scripts still take the unchanged `exec` path.

The ascent is bounded at 32 hops, so a `parentMission` pointing in a circle
cannot hang a verb. **A delegate with no seed can still own what it filed** —
the seed is one of three ways in, not a precondition. Reaching into a sibling's
chunk is how two seats do the same work twice and neither owns the result, so it
is refused **by name**. A refusal is escalated to the main ECH through a
`BLOCKED:` beat; there is no `re-chunk` verb. The main ECH decides the new
hand-off using the existing mapping, close and mint verbs, rather than a seat
repairing ownership records by hand.

### A BUG A SUB-ECH OWNS AND IS DRIVING DOES NOT BLOCK THE PARENT

**The open-children gate is right to exist and its TIMING was wrong.** Nothing
may silently drop a logged bug — so:

- a bug a sub-ECH **owns and is driving** does **not** block the parent's accept,
  and every one let through is **named with its owner** on the way past;
- an **unowned, undriven** bug **still blocks**, and the refusal says **which,
  by id, and why**.

**AND ONE ADJUDICATOR DECIDES IT, WHICH IS THE OTHER HALF OF ROUND 2 (F1).**
The library was shared and the **adjudication** was not: `lcars_chunk_owner`
tested a row plus `delegates/<id>/BRIEF.md`, while `land` *also* consulted the
delegate record through python. So the two gates could disagree, and a fresh
tester reached the disagreement with two **documented** verbs — `lcars-ech init
--force` drops `delegates` by design, leaves the briefs by design, and left
`chunk-owners` alone. Afterwards `land` blocked and **`approve` MERGED.**

The whole test is now **two `[ -f ]`s and no JSON at all**, so there is nothing
either caller can read differently and no python in `approve.sh`:
`delegates/<id>/BRIEF.md` (a mint really happened) and `delegates/<id>/OPEN`
(the seat is still open). `delegate`'s mint writes the marker; `delegate close`
and `init --force` remove it. `land` reads the record only to say WHY it
blocked, never to decide, and `lcars_chunk_claim` exists so a refusal can still
name the id it refused. **A seat minted before the marker existed reads as
closed, and its bugs block** — the safe direction, as every ambiguity here is.

**AND ROUND 2 LEFT A SECOND READER BEHIND, WHICH ROUND 3 REMOVES (Cure 2).**
`delegate_is_open` consulted the record's `status` *as well as* the marker, so
"is this seat open" was two questions again — and a fresh tester measured them
disagreeing **in opposite directions at once**:

> `record delegates.d1.status done`, instead of `delegate close` → the marker is
> still there, so **both accept gates see owner `d1` and the bug STOPS
> BLOCKING**, while the seat itself is refused as closed.

The permissive side was **the accept gates**, which is the side that must never
be permissive. So `delegate_is_open` is now *exactly* `lcars_chunk_seat_open`
and nothing else: one reader, asked by the seat, by `land`, by
`chunk_owners_of` and by `approve.sh`. **And the route that could desynchronise
it is closed at source: `record` refuses `delegates.*`** and names
`delegate close`, which maintains the record and the marker together — so
`delegate close` is the only documented writer of `status: done`. `init`'s own
refusal text used to recommend `record` for exactly this kind of edit, which is
how the door was reachable without anybody hand-editing JSON.

**Ownership is recorded, released, and checked.** It is written to
`.git/lcars/chunk-owners` (`<mission-id>` TAB `<delegate-id>`, append-only,
latest line wins) by `file-bug` when a sub-ECH files a bug inside its chunk and
by `exec` for a Mission it files, and **released by `delegate close` — all of
it**, the Missions it filed as well as the bugs it was driving. A closed sub-ECH
drives nothing, so its bugs go back to blocking (the correct state for a bug
nobody is driving) and its Missions leave its chunk.

**A MISSION ROW CAN NEVER MAKE A BLOCKER GO QUIET.** Both accept gates only ever
ask about a `type: bug` child of the Mission being landed, so widening what a
row can name widens the CHUNK and not the gate. `mission_in_chunk` is the only
reader that asks about an ordinary Mission.
**A CLAIM IS CHECKED, NOT TAKEN, AND BY ONE READER.** Both gates ask
`lcars_chunk_owner` and nothing else, so a claim counts only when the brief AND
the seat marker are both on disk — one line in a text file is not an accept, and
when in doubt the reader returns nothing, which means the bug **blocks**. `land`
additionally reads the delegate record to **say which** of the three reasons it
blocked for (nobody owns it / the claimed seat has no record / the claimed seat
is not open), and `approve.sh` names what it let through; neither decides
differently from the other. A false accept is worse than the blocking this rule
cures, and the cheapest attacks on it are a hand-written claim and a reset that
leaves live claims behind — both of which now block.

**WHY A FLAT FILE AND NOT A FIELD IN `autopilot.json`.** Two scripts have to
agree about what a blocker is — `lcars-ech land` and `approve.sh`'s own
pre-merge gate — and they read JSON in two different ways (`ech.sh` through
python, `approve.sh` with `sed`, with no python dependency at all). The
open-children gate's own comment says why that matters: it and the folder use
*"deliberately the same reader … so the two can never disagree about what a
child is"*. One greppable file, read by `skills/lcars-eeh/chunk-owners.sh`,
which both of them source. **A missing file means nobody owns anything**, which
is every repo before this rule — the degradation is the known-good control.

### ONE LAYER, AND WHAT STILL GOES UP

**SUB-ECHS ARE EXACTLY ONE LAYER DEEP, AND A SUB-ECH MAY NOT MINT A SUB-ECH.**
Captain's ruling, 2026-11-20, and it is enforced rather than advised: `delegate`
is not on `SUBECH_VERBS`, so the boundary refuses it to every seat — a driving
one and a validating one alike — before its arguments are parsed. Every mint
records **`mintedBy`** and **`depth`**, so the shape of a run is a fact on disk
and not a claim about the refusal; the main ECH is depth 0 and everything it
mints is depth 1, **including a sibling validator**, which is the whole reason
it is called a sibling.

**TWO THINGS ARE LEGAL INSTEAD**, and the refusal names both, because a refusal
with no door in it is one a live seat will go round:

1. **Hand the work back up.** A chunk it was not handed, or a judgement only the
   main ECH can make, goes up in one `BLOCKED:` beat and the main ECH re-chunks.
2. **Chunk it into more Missions for the factory.** A sub-ECH subdivides its
   **own** chunk **freely** — as many Missions as the work divides into, filed
   through `exec lcars-file/file.sh`, each one joining its chunk (his tweak the
   same morning: *"they can sub divide the missions they feed the factory as it
   makes sense"*). **This is not rationed.** What is refused is minting another
   ECH, never dividing the work.

What goes **up** to the main ECH is unchanged: a scope change, a product call
the captain owns, a conflict with a standing rule, a question only the main ECH
can settle, and anything needing a chunk it does not own. The channel is the
`BLOCKED:` beat, which `stalled` surfaces at once.

### THE VALIDATION RULE — one pass, on a declared trigger, three rounds

**The captain's open worry, 2026-11-20:** *"I worry about how the main ech
chooses when to use that vs letting the sub ech that drove the work to validate
it. I also don't want to end up with spiralling double validation."* This is the
answer, and both halves of it are enforced.

**DEFAULT: THE DRIVING SUB-ECH VALIDATES ITS OWN CHUNK.** This is not marking
its own homework. The factory's gates — the flip-flop proof, the
declared-test-edits contract, the post-commit check — are independent machinery
that has already run; the sub-ECH's job is to confirm they really passed and to
take its own live look. Every real finding of the 2026-11-18 capstone came from
an ECH's own look, and none from an extra reviewer.

**A SEPARATE VALIDATING SIBLING IS SPENT ONLY ON A DECLARED TRIGGER**, recorded
with its reason the way the tier judgement already is. The triggers are the
industry's own axes — *can the error be detected*, and *what does it cost*:

| trigger | what fires it |
|---|---|
| `undetectable` | the chunk carries an acceptance criterion **its own tests cannot fail on**. The test is mechanical: does each criterion map to a test that could fail on it? *"the fish appear in the river"*, asserted against the entity list, does **not** trigger. *"it looks right"*, *"a player can see it"*, *"the error reads clearly"* do. The precedent is **S163** — 1,162 tests green while the board was blank in a real browser. |
| `irreversible` | it does something **that cannot be taken back**: a migration, a destructive operation, anything touching the forge or already-published state. This is where four-eyes is mandatory in every other industry. |
| `wide` | the **declared keystone**, or it touches machinery other chunks depend on — the blast-radius axis, and the argument `CODEOWNERS` makes. |

**AND TWO THINGS THAT LOOK LIKE TRIGGERS AND ARE DELIBERATELY NOT.**
**Size-as-proxy** — a big diff buying a second pass — is widely used, widely
criticised as weak, and **not used here**. And **"it changes something on
screen"** is excluded by name (the captain, 2026-11-20): a button moving four
pixels is a visual change a test asserts perfectly well, and that trigger would
fire on every UI chunk and re-create the double validation this rule exists to
prevent. S163's lesson is not *the change was visual* — it is that **no test
could fail on what a person would have seen immediately.**

**AND A SEPARATE, WEAKER LANE — THE DRIVER MAY ASK.** A driving sub-ECH that is
unsure runs `request-validator "<why>"`; the request is **always honoured** and
**always recorded**. It is **not a trigger**, and a pass granted on it may
**never be counted as coverage** — self-declared uncertainty is cheap and worth
having, but it only fires when the driver happens to notice.

**AND IT TERMINATES — THIS IS THE ANTI-SPIRAL HALF:**

- A validating sub-ECH is a **SIBLING**: minted by the **main ECH**, at **layer
  one**. Fresh eyes on a chunk are a new layer-one seat, so the cap still holds.
- Its findings go **back to the driving sub-ECH as bugs** — recorded as the
  driver's to drive, because the driver is the seat that fixes them.

**AND A VALIDATION PASS IS BOUNDED BY THE *ACT*, NOT BY A VERB NAME.** It
performs exactly **two** acts and every other one is refused:

| | |
|---|---|
| **LOOK** | `live-check <mission> --type <types>` — its own eyes on the real product. The whole reason it exists. |
| **FILE** | `file-bug`, or `exec lcars-log/log.sh`. Either door records the bug as the **driver's**, through one resolver, so the two cannot disagree. |

| refused act | what it is |
|---|---|
| **VERDICT** | `live-check done --verdict` — the record `policy` reads. A pass that marks its own chunk verified has decided the thing it was brought in to examine. |
| **DECIDE** | `policy` — the action for the verdict pair, whose `merge` branch prints the `land` command. |
| **FIX** | `drive`, **and `run.sh` / `respond.sh` / `resolve-logs.sh` through `exec`** — the same act by another route. |
| **SUBDIVIDE** | `exec lcars-file/file.sh` — filing Missions into a chunk it does not own. |

**WHY THE ACT AND NOT THE NAME.** S366's first build wrote the rule at
`[ "$verb" = drive ]`; `cmd_exec` hands the same gate the string
`exec lcars-run/run.sh --mission`, so a validation pass was refused `drive` and
**ran the identical act one `exec` away** — measured by effect by a fresh
tester, together with a three-step route to `ACTION: merge` on a verdict it
wrote itself. That is the class S365 fix round 3 had already cured for
`land`/`approve`/`push-gated`, in its own words: *"a boundary that bounds only
the VERB NAMES bounds nothing."* The acts are one constant (`VALIDATOR_ACTS`),
one classifier and one decider, asked at **both** gates — and deny-by-default,
so a verb or script added to LCARS tomorrow is refused to a validation pass
until somebody classifies it on purpose.

**AND THE BRIEF CANNOT SAY OTHERWISE.** § 5 of the minted brief is a **slot**,
filled by role exactly once: a driving seat gets the four steps (`live-check`,
`policy`'s action, `file-bug`, drive them); a validation pass gets the two acts
above and the three refusals. Before that it was fixed text telling every seat
to do all four while another section told a validator it must not — one brief,
two contracts, and the seat reading top-down met the wrong one last.
- **One validation pass per chunk per round.** Two validators on one chunk is
  refused by name.
- On re-report the **same validator re-checks ONLY the bugs it filed** — never
  the whole chunk again. `revalidate` snapshots that list and the scope gate
  refuses anything wider.
- **Validation is never re-delegated**, and **a validation pass is not itself
  validated.**
- **At most three rounds**, then the **main ECH decides** — it reads what was
  filed, what was fixed and what is open, and **it does not validate the chunk
  again**. Its final check is **whole-job**: do the chunks fit together and is
  the ask met. This mirrors `ORCHESTRATION.md` § *Three fix rounds, then STOP*
  and rests on the same evidence.

---

## The verbs

```bash
lcars-ech tier <unit-id> --tier T0|T1|T2 --why "<reason>"   # record the judgement
lcars-ech delegate <unit-id>                                 # mint the brief
lcars-ech delegate <unit-id> --validate --trigger undetectable|irreversible|wide --why "<r>"
                                                             # a SIBLING validator, layer one
lcars-ech request-validator "<why>"                          # a DRIVER asks (never coverage)
lcars-ech revalidate <validator-id>                          # its next round, bounded to what it filed
lcars-ech beat <delegate-id> "<one line of progress>"         # one per step; no silent hours
lcars-ech delegate close <delegate-id>                       # the delegate is done
lcars-ech delegates                                          # the list
```

The brief template is `delegate-brief.md`, beside this file —
`lcars-eeh docs delegate-brief` prints it. It is a reviewable file on disk, not
a heredoc in a shell script, for the same reason `bug-prd.md` is.

---

## WHO RUNS WHAT — the role → engine matrix

**This is the one statement of it.** Anything else that talks about which engine
a role runs on is a pointer here or a stale copy.

A run used to record exactly ONE engine, plus a second one for the verifier. So
there was no way to say *"orchestrator Claude, delegates and workers Copilot,
reviewer Claude"* — the captain's own arrangement worked **by accident**:
whichever CLI he launched became the boss, and the one recorded `engine` became
everything beneath it. That is now a setting.

```bash
lcars-ech engines                                   # read the table back
lcars-ech record engines.reviewer.engine claude      # change one row
lcars-ech record engines.tester.model   <model>      # pin one row's model
```

**The six roles**, and they are deliberately the roles the rest of LCARS can
already attribute spend to (`LCARS_WORKER_ROLE`, `stage_key_for_role`,
`usage_capture`) — a seventh would name something nothing downstream can see:

| role | what it is |
|---|---|
| `orchestrator` | the seat driving the factory — the ECH itself |
| `delegate` | a delegate minted by `lcars-ech delegate` |
| `worker` | the per-stage worker a mission's own stages spawn |
| `tester` | a T2 delegate's fresh-context tester |
| `reviewer` | a review pass over finished work |
| `numberOne` | the verifier |

**The documented default, and COPILOT IS EMPLOYER-PAID AND EFFECTIVELY FREE
WHILE CLAUDE IS BILLED.** That is the whole reason the default is shaped this
way, not a preference:

- `orchestrator` = **the run's own recorded engine** — `engine` in
  `autopilot.json`, else the repo's `config.json`. **NOTHING DETECTS THE HOST
  CLI.** This row read `default: the CLI this run is driven by` for one round
  and that was a label asserting a detection the code does not have: two repos
  differing only in that field, driven from one session, print different
  orchestrators. The row now names the file it was read from, because the claim
  was the defect and the value was fine.
- every other role = **copilot**.
- **A Claude role is only ever a recorded choice.**

**The captain's declared slice of the weekly Claude allowance** is set with
`lcars-ech record claudeCeilingPct <1-100>`; unset means **NO CEILING**, never
zero. `lcars-ech budget` reports the ceiling, live weekly reading, source, age,
remaining slice, reset time and which resolved roles it binds. It binds **only
billed Claude roles**; employer-paid, unmetered Copilot roles are **exempt**,
including when the Claude reading is unreadable. Before starting or resuming
any seat, run `lcars-ech budget --check <role> --mission <unit>`: only exit 0
permits it. Under the ceiling is silent; at or above it parks that seat through
the existing `ask` question ledger (exit 10), naming the role, engine, ceiling,
reading and reset, with the exact command to raise the slice or a recheck after
the stated reset time. Run the offered command and close the question through
`answered <id> "<answer>"` before retrying. An unreadable **weekly.pct** refuses
only that billed seat (exit 11), never grants unlimited use. Delegate minting
and mission-drive entry points enforce the same check; manually opened seats
must run it too. Every minted brief records its mint-time ceiling and reading,
or its role's exemption. A malformed persisted value (or
`LCARS_ECH_CLAUDE_CEILING_PCT` override) degrades to the documented **100%**
default, warns on stderr and on reports applying it, and never silences an
unrelated watchdog report. This is an admission check, not a reservation or a
mid-session cutoff: it starts no engine and stops no running seat.

**A DEFAULT IS PRINTED, NEVER SILENT.** Every row `lcars-ech engines` prints
says whether its engine came out of the record or out of the paragraph above. A
default nobody can see is indistinguishable from a setting somebody made, and
the captain has to be able to tell a deliberate Claude role from a forgotten
one — the same reason `tier` refuses a missing `--why`.

**`numberOne.engine` STAYS AS THE COMPATIBLE READ.** A repo recorded before this
existed keeps working, and its value is what `engines.numberOne` resolves to.
**Nothing migrates it**, because a migration is the only way to lose a captain's
recorded setting, and losing one is the worst thing this seam could do.

**AND PREFLIGHT NOW HONOURS THAT, WHICH IT DID NOT.** Preflight's Number One
question used to replace the whole `numberOne` object the moment
`numberOne.choice` was unset — so on a repo recorded before the choice existed
it turned a recorded `claude` into the run engine, dropped every sibling key
beside it, and left `engines` printing "recorded in numberOne.engine" over the
value it had just destroyed. The invariant, mechanised:

> A recorded `numberOne.engine` — **and any sibling key beside it** — survives
> preflight. Settling `numberOne.choice` may **add** fields; it may never
> replace or drop a value the captain put there. And **no row may be labelled
> "recorded" when what it reports is not what was recorded.**

Settling now writes the fields one at a time, writes the engine **only** when
there was none of his to keep, and applies HIS engine when he recorded one —
which is what the already-settled path has always done.

**IT NAMES WHO RUNS WHAT; IT DOES NOT YET GOVERN EVERY LAUNCH, AND IT SAYS SO.**
Two rows are consumed today: `delegate` and `tester` are **stamped into a minted
brief** and recorded on the delegate, so they are what a delegate is actually
told to run on. The other four — `orchestrator`, `worker`, `reviewer`,
`numberOne` — are **recorded and reported only**; nothing launches from them yet,
and Number One is still applied by its own LCARS verb from `numberOne.engine`,
not from `engines.numberOne`. Wiring the rest is a scope call, not a thing to
imply with a heading: a table that described itself as governing launches it does
not reach would be the same by-accident shape in a new costume.

**A SUBSTITUTION IS RECORDED, NOT JUST DISPLAYED.** When a row's engine is not
installed and the run resolves away from it, the minted brief **says which
engine was recorded, that it is absent, and that the replacement is the
machine's choice and not the captain's** — and `delegates.<id>.engineRecorded` /
`.engineSubstituted` carry the same fact on disk. A free row quietly becoming a
billed one is a bill nobody agreed to, and a screen nobody re-reads is not a
record.

**IT NEVER NAMES AN ENGINE THIS MACHINE DOES NOT HAVE.** Resolution goes through
`lcars_available_engines` and `lcars_default_engine` — the same functions every
other LCARS surface uses — so a row recorded as `claude` on a copilot-only box
resolves to copilot **and says so on its own line**. A brief that promises an
engine the machine cannot launch is a hand-off nobody can obey.

**STATED ONCE, AT PREFLIGHT — AND THERE IS NO SEVENTH PROMPT.** Preflight
**states the recommended table**, records the settlement
(`engines.settledBy` / `engines.settledAt`), and is **never re-asked**: a table
already on disk suppresses the item entirely, which is the unattended path.
It **reports and proceeds** rather than prompting, which is question 5's shape
and a deliberate deviation from question 6's — measured twice with the repo's own
rig: a seventh prompt yields `PTYPROMPTS 3 ANSWERED 2`, a prompt the harness
cannot answer, and the unanswered one then burns its full `ASK_TIMEOUT` every
run before proceeding on the recommendation it was going to take anyway.

**SO THE OVERRIDE IS A SETTING, NOT A SENTENCE HE RETYPES:**

```bash
lcars-ech record engines.<role>.engine claude     # the override, durable
lcars-ech record engines.<role>.model  <model>
```

That is read by every later run and is named in preflight's own text. **Nothing
here asks the captain a question**, so his reference must not tell him to answer
one.

**EVERY BRIEF IS STAMPED.** `lcars-ech delegate` names the delegate's engine and
model by name, records them at `delegates.<id>.engine` / `.model`, and states
that **the delegate may not choose another engine** — which engine a role runs
on is a cost decision the captain made, not one a delegate re-makes mid-unit.

---

## THE FRONT-DOOR CONTRACT a delegate is held to

**This is the one statement of it**, and it is in every minted brief because
**the doctrine is prose aimed at one reader**: `HOLOGRAM-COMMAND-MODE.md` § 4a
and the Holodeck sequence are written for the ECH, and **a delegate never reads
them**. So the rule travels with the hand-off.

**Drive through the HUMAN interfaces. Never hand-step the stage machine.** The
verbs, named: `lcars file`, `lcars log`, `lcars answer`,
`lcars-ech exec <skill>/<script>`, and **the Holodeck route for any screen
work** (derive — the wait is asynchronous — then promote inside one of its two
legal scopes).

**Never build what the factory builds.** **THE QUALITY IS IN THE HARNESS** — the
grills, the gates, the fresh reviewers, the flip-flop proof — so going around
the harness throws the quality away and hands back something that merely looks
finished.

**What a delegate decides alone:** how to do the work, in what order, in which
files, how to test it, and every stumble it can cure with those verbs.

**What goes UP to the ECH, never to the captain:** a scope change, a product
call he owns, a conflict with a standing rule. The interrupt budget
(`HOLOGRAM-COMMAND-MODE.md` § 9) has **four** categories, it is the ECH's to
spend, and **delegation adds no fifth**.

### THE ABSORPTION ROUTE — by using the factory, never by going round it

This is the clause that makes T1 worth having without making it dangerous. A
delegate absorbs a stumble **through the factory's own verbs**:

- a **defect in the work** → `lcars log` it against the Mission;
- a **ticket whose premises the code contradicts** → **UP to the ECH, through a
  `BLOCKED:` beat** (below). A delegate does **not** re-anchor the ticket
  itself: there is no delegate-facing verb for it, and a rewritten premise is a
  plan decision;
- a **question only the ECH can settle** → **UP to the ECH, through a
  `BLOCKED:` beat** (below). A delegate does **not** run `lcars-ech ask`: that
  verb prints *QUESTION FOR THE CAPTAIN* and fires his notifier, and the
  interrupt budget is the captain's for the MAIN ECH to spend. `ask` is in the
  brief's reserved list beside `land` for exactly that reason. `file-bug` is
  **not** on that list any more: inside its own chunk it is the sub-ECH's own
  verb — § *AUTHORITY TRAVELS WITH THE CHUNK*.

**THESE ARE NOT ABSORPTION:** hacking past a red test (deleting it, skipping it,
loosening its assertion), **building a parallel control beside the real one**, or
**hand-stepping a stage** to get moving. Each produces the **green-but-wrong
decoy** — work that reports success and delivers nothing — which is the exact
class the factory already has machinery against. A delegate that can only see
one of those three is not stuck on the work; **it is at a question for the ECH.**

### THE EXIT DOOR, NAMED — a `BLOCKED:` beat

**The prohibitions above are only safe if the way out is labelled.** This clause
also applies pressure in the other direction (*"a delegate that escalates every
stumble is worth nothing over T0"*), and a channel-less delegate under that
pressure is precisely the one that improvises. So the brief hands it **one
runnable command**, and `beat` — the only verb a delegate is given — **is** the
channel:

```bash
lcars-ech beat <delegate-id> "BLOCKED: <what it is stuck on, and what it needs>"
```

A beat whose line **opens with `BLOCKED`** is reported by `lcars-ech stalled`
**immediately, without waiting out the silence limit**, with the delegate's
words quoted and its own tally, and it is flagged beside the delegate on
`lcars-ech status`. It **never reaches the captain** unless the ECH decides it
should. It is still **not a verdict and it advances nothing** — it is a
delegate saying it needs an answer, and the ECH's three answers are: answer it,
replace it, or (only for a call he owns) raise it with the captain. The block
is read from the **latest** beat only, so the delegate's next beat clears it.

**AND THERE ARE NOW TWO DOORS FOR A DEFECT, BOTH OPEN IN ITS OWN CHUNK.**
`lcars log` asks only for a title and `**Type:** bug`; `lcars-ech file-bug` sits
behind an evidence-first template (`Observed live:` as acceptance criterion #1)
and is **the sub-ECH's own verb inside its chunk** — and the one that records
who owns the bug, which is what stops the filing ending the parent's run
(§ *AUTHORITY TRAVELS WITH THE CHUNK*). Outside its chunk, `file-bug` is
refused by name. A brief that sent a stuck delegate at `--prd <f>` without
saying what goes in the file was sending it at a door with no handle, so every
brief now names the staged `bug-prd.md` to copy.

### EVERY SEAT A DELEGATE OPENS TAKES THE `delegate` ROW

A delegate opens seats of its own — a worker, a tester, a second window — and
**there is no `subdelegate` row**: every seat it opens — sub-delegate, helper, or
just a second window — runs on the engine and model stamped in its own brief.
(This row is about the WINDOWS it opens and what they bill. **Minting another
sub-ECH is a different thing and it is refused** — § *ONE LAYER, AND WHAT STILL
GOES UP*.) The
prohibition is not "do not pick the engine you are fluent in", which a T2
delegate could obey while opening three Claude seats; it is **every seat this
unit pays for**. A seat that genuinely has to be a different engine **may not be
opened without asking the ECH**.

**AND THE SEAT IT IS ALREADY IN COUNTS.** A brief pasted into a Claude window is
not a choice the delegate made, and it bills the unit all the same — so "I chose
nothing" is a true report and a useless one. **If the seat it is in is not the
stamped engine, it stops** and says so with a `BLOCKED:` beat.

### The T2 tester hand-off

A T2 delegate stands up its own fresh-context tester, hands it **the unit's goal
and the real product — never its own reasoning**, and gets back **evidence and a
bug list**. The bug list is **filed through `lcars log`** against the parent
Mission, one bug per item. **The delegate FILES them; it does not ADJUDICATE
them** — it does not decide which are real, does not hand-write bugs in place of
filing them, and **does not fix them inline**. Nothing it files is a verdict about the
whole, and the ECH above it still verifies the whole regardless. **A sub-ECH
may file the list through `lcars-ech file-bug` instead, inside its own chunk**,
which records who owns and drives each one. **`ORCHESTRATION.md` owns the
tester's own rules** (§ *The loop* step 2, § *The tester opens the real product
first*) and neither this file nor any brief restates them.

### THE TWO-LIST SIGN-OFF

On exit a delegate makes **two** ledger writes through `lcars-ech ledger
feedback`:

```bash
lcars-ech ledger feedback '{"kind":"ech-shortfall","delegate":"<id>","what":"…"}'
lcars-ech ledger feedback '{"kind":"lcars-bug","delegate":"<id>","what":"…"}'
```

They are different piles **because they feed different work**: one is a brief to
write better next time, the other is a bug to fix in the harness. For a year
they were one pile — `lcars-feedback.jsonl`, "bugs, gaps, friction, wins, YOUR
OWN MISTAKES" — and that is precisely why it fed nothing.

**An explicit "nothing found" is a legal entry. SILENCE IS NOT** — silence is
indistinguishable from a delegate that never looked, which is the one thing
these two lists exist to tell apart. `lcars-ech delegate close <id>` **reports an
incomplete hand-back** when either kind is missing (it reports; it does not
refuse — a close carries no judgement and must never strand a finished
delegate), and `lcars-ech report` prints the ledger as **two separate lists**.

---

## Guardrails

- **The two-mission ceiling stands** (`HOLOGRAM-COMMAND-MODE.md` § 8). Two
  drivers at a time. **Delegates do not get their own slots and may not raise
  the ceiling.**
- **The interrupt budget stands** (§ 9). Exactly four things reach the captain.
  Delegation adds none.
- **`tier` and `delegate` do not re-order the work.** `lcars-ech next` decides
  the next *step*; this file decides *who does it*. A unit with no tier recorded
  behaves exactly as it always has.
- **A brief is located repo-relative.** `delegates.<id>.briefRel` is where the
  brief is *inside the repo* and is what every read resolves against the repo it
  is run in; `briefPath` is the absolute path of the checkout that minted it,
  kept as provenance only. This project replays archived missions by **copying**
  them into a repo, so a brief resolved from an absolute path was a brief
  belonging to someone else's checkout. A recorded brief that is missing, or
  that was minted elsewhere, is **named as such** instead of printed as if it
  were fine.
- **That comparison is symlink-resolved.** Whether a record was minted in
  another checkout is decided on **realpath-resolved** paths, not on the two
  strings: the same physical repo reached through a symlink, or through a
  symlinked parent, is the same checkout and gets **no warning**. `/tmp` is a
  symlink to `/private/tmp`, `$TMPDIR` is symlinked, and this project keeps its
  worktrees and archives under such paths — a guard that fires on correct
  behaviour is a guard the operator learns to ignore. A genuine `cp -R`, a
  record naming a different file in this repo, and a recorded path whose
  checkout no longer exists all still resolve DIFFERENT, and all still warn.
- **The brief self-checks its own location.** It is stamped with the absolute
  path it was minted at and tells its reader, in its own body, not to use it if
  the file is somewhere else — ask for a **re-mint** instead. The listing verbs'
  warning only reaches an operator who runs a listing verb, and a hand-over is
  a `cat` of one file; so the artifact carries the guard rather than depending
  on a sibling verb. The dangerous case is the one where the minting checkout
  is still there: every absolute path in the brief then resolves, and the
  delegate does coherent work in the **wrong repository** in silence.
- **A mint never overwrites a brief on disk.** An id is occupied by the record
  *or* by a `BRIEF.md` already at `delegates/<id>/`, and a mint takes the next
  free id and says which it skipped. `init --force` is a deliberate,
  documented reset: it drops `units` and `delegates` from the record, it now
  **says which judgements and delegates it discarded**, and it leaves the brief
  files on disk. Those become briefs no record claims — they are not destroyed,
  because a brief is a durable reviewable artifact the same way a closed
  delegate's `closedAt` is a fact.
- **Records live in `.git/lcars/`** — `units.<id>` and `delegates.<id>` in
  `autopilot.json`, briefs under `.git/lcars/delegates/<id>/`. Inside `.git/`,
  so no target repo's working tree is ever dirtied.
