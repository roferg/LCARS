# AUTOPILOT.md — how to run LCARS *for* the captain

This is the playbook for `lcars buddy`'s second half: the captain says
**"run it for me &lt;spec&gt;"**, answers **one** round of questions, and walks
away. From then on you are the orchestrator of his build.

It is modelled on a real run: over 26–29 Sep 2026 a session drove LCARS on
Copilot workers to ship 7 features and ~40 bug fixes — 34 missions in about 36
hours — while the captain was with family or asleep. Everything below either
worked on that run or is a guard against something that cost him attention.

**One principle: you steer and verify; you never build.** Your tokens go to
reading the spec, one alignment round, briefs, answering grills, judging live
checks, writing bug PRDs and the merge call. Everything sequenceable is
`lcars-autopilot`, which spends nothing.

> This is **not** a fix loop. The autopilot never edits the LCARS source. If it
> hits an LCARS bug it works around it with another verb and ledgers it, or it
> stops and asks. Fixing LCARS is `lcars buddy` § 2, under `ORCHESTRATION.md`.

## How to read this file

Ask the driver what to do next, then read that section:

```bash
lcars-autopilot next
```

`install.sh` generates that command for both CLIs, and **every command in this
file is written out in full** — there is no shorthand to expand, because a
reader who jumps straight to § 9 never sees the top of the file.

**If it says "command not found"**, `install.sh`'s launcher dir (`~/.local/bin`)
is missing from your PATH; `install.sh` prints the line to add. Until you add
it, `bash <your-lcars-clone>/skills/lcars-buddy/autopilot.sh` is the same
driver and takes exactly the arguments shown below.

It prints one action and the **exact heading in this file** that covers it:

```
NEXT: verify-gate lcars-20260930-001
WHY: M0 reached the Verify gate — read Number One, then run the live check
PLAYBOOK: ## 6. The Verify gate — Number One, then the live check
```

`lcars-autopilot playbook` prints the whole action→heading table, and the test
suite asserts every heading in it exists here — so this file and the script
cannot drift apart.

## Durable state: `.git/lcars/autopilot.json`

**Record, don't infer.** Every fact this mode needs later is written to
`.git/lcars/autopilot.json` *at the moment it is decided* — never left in the
chat. Scope, latitude, the captain's answers, the captain-only steps, driver
pids, and **every** open question.

**Questions are a ledger, not a slot.** `questions` holds every question ever
raised — answered or not — and `pending` is a derived *mirror* of the oldest
open one, there because the model-facing surface reads a single question.
Writing a question **appends**; nothing already recorded is destroyed, so a
second question can never delete the first. **Raising the same question twice
is a no-op.** A question already *open* on the same (mission, question) pair is
not re-recorded and does not ping him again, so re-running a blocked step is
safe; two *different* questions on one mission stay two questions, and a
problem that recurs **after** he answered it raises a real new one. Close one
with its id (which `lcars-autopilot status` prints) and the mirror moves on:

```bash
lcars-autopilot status                          # [q1] lcars-…: <the question>
lcars-autopilot ask "<what you need>" --mission <id> --why "<why>"   # raise one (§ 9)
lcars-autopilot answered q1 "yes, go ahead"     # records the answer BESIDE the question
```

Raise every question with `ask` (§ 9) and never write `pending` yourself: it is
derived, and the driver overwrites it on the next write.

`answered` never deletes: the question stays on the record with his answer next
to it, and it clears that mission's failed-drive counter (§ 5), because his
answer is what unblocks it.

Write with the driver, not by hand:

```bash
lcars-autopilot record liveTargets.host github.ghe.com
lcars-autopilot record missions.M0.id lcars-20260930-001
lcars-autopilot record missions.M0.verified true
lcars-autopilot record preauthorised.liveTestWrites true
```

**The memory rule.** Your context *will* compact on a run this long. After any
compaction — or at the start of any session where the captain says "continue" —
your **first** action is to re-read `autopilot.json` and run `lcars-autopilot
status`. Do not re-ask anything that is already recorded there. State that
lived only in the transcript is state that is gone.

Ledgers live beside it, also inside `.git/` so the product's working tree stays
clean:

| File | What goes in it |
|---|---|
| `.git/lcars/lcars-feedback.jsonl` | LCARS bugs, gaps, friction, wins, your own mistakes |
| `.git/lcars/autopilot-overrides.jsonl` | every Number One verdict you overrode, with the live evidence |
| `.git/lcars/decisions.jsonl` | product calls, scope changes, merges |

```bash
lcars-autopilot ledger feedback  '{"kind":"lcars-bug","detail":"fold drift blocked a merge"}'
lcars-autopilot ledger overrides '{"mission":"lcars-…","verdict":"low","reason":"infra only","evidence":"…"}'
lcars-autopilot ledger decisions '{"what":"added M6","who":"captain"}'
```

---

## 1. The alignment round — one batch of questions, then walk away

**Before you ask anything**, do the reading, so no question is wasted:

1. Run `lcars buddy` (§ 1 of SKILL.md) and read the brief — where LCARS lives,
   whether the install is in sync, what is already in this repo.
2. **Repeat the ask back** in plain terms and get it confirmed.
3. Read the spec. Then check what the harness can actually do (engine flags,
   Number One, the holodeck) *before* asking.

Then **one** batch of 3–5 questions, each with a **recommended option** so the
captain can answer in a word:

1. **Scope** — which milestones, in what order. (Recommend the spec's own.)
2. **Live targets** — the host and the owners you may create or touch things
   under.
3. **Where it deploys**, and what "live" means for this product. Record it —
   there is a key for it: `lcars-autopilot record deploy '{"where":"…","liveMeans":"…"}'`.
4. **What to do if LCARS itself breaks** — the default is *stop and report*.
5. **The pre-authorisations** (§ 9): may you do a manual merge if `approve` hits
   a known LCARS bug and the merged suite is green? May live checks write to the
   product repo? Both default to **no**.

Then write it all down and start:

```bash
lcars-autopilot init --spec <path-or-url> --scope M0,M1,M2 --engine copilot \
                  --deadline 2026-10-01T07:00:00-07:00
lcars-autopilot record latitude.allowed '[ … ]'     # his words, not the defaults
lcars-autopilot record liveTargets '{"host":"…","owners":["…"]}'
lcars-autopilot heartbeat install
```

**This is the whole interrupt budget for the setup.** A second question round
is a defect in how you ran this step, not a fact about the spec.

An empty scope is unfinished alignment: set it with `init --scope` or
`lcars-autopilot record scope '["M0","M1"]'` before building or claiming completion.

---

## 2. Captain-only steps, collected up front

Some things only he can do: a token, a repo secret, SSO authorisation, an org
setting, a repo rename. On the modelled run a hub token surfaced at 10:40am and
SSO at 1pm — both on the critical path, both avoidable. **Enumerate them in the
alignment round**, with a *needed by* time, and record them:

```bash
lcars-autopilot record captainOnlySteps '[
  {"what":"HUB_TOKEN secret on the product repo",
   "instructions":"! pbpaste | gh secret set HUB_TOKEN -R <host>/<owner>/<repo> --app actions",
   "neededBy":"before M2 drives","done":false}
]'
```

**Secret values never appear in the transcript.** Always give him the
`! pbpaste | gh secret set NAME -R <host>/<owner>/<repo> --app actions` shape —
he copies the value to the clipboard and the command reads it from there. (On
the modelled run he pasted a token into the chat on the first try and had to
rotate it.)

**Verify each one the moment he says it is done** — list the secret names, check
the first workflow run gets past checkout — then
`lcars-autopilot record captainOnlySteps '[…"done":true…]'`, and say plainly what
is still missing.

**If he DECLINES one, record the decline — never `done: true`, never delete it.**
A declined step is an outcome, with a third state of its own:

```bash
lcars-autopilot record captainOnlySteps '[
  {"what":"a Pages deploy token", "instructions":"…", "neededBy":"before M2",
   "done":false, "declined":true,
   "declinedReason":"no deploy token, no Pages tonight"}
]'
```

`next` never asks for a declined step again, `status` still lists it as declined,
and the ledger keeps the fact that it was asked. Writing `done: true` would be a
lie in the ledger and deleting the step loses the ask; neither is the answer.

---

## 3. Foundation — establish the vision, then re-check the test command

A repo with no test foundation refuses a normal mission. The foundation is its
own initialization mission; autopilot `init` and every `next` check the repo with
the same readiness signal as `lcars init`, so no `foundation.required` or
`foundation.done` flag is needed. LCARS already has the verb for it:

```bash
lcars-autopilot exec lcars-init/establish-vision.sh --file \
     --stack "<the stack>" --slice "<a thin end-to-end slice>" --engine copilot
```

Do **not** write your own scaffold. Drive the initialization mission, do its
Verify gate and land it before filing the first product milestone; `next`
finds it by LCARS's existing `missionType: initialization`, not an autopilot flag.

**Immediately after it is approved, check `testCommand`.** `approve` has
promoted an uninstalled runner over a captain-set stdlib command before. `land`
re-asserts it automatically from `autopilot.json`; this is the one place where
the recorded value is first set, so make sure it is the command the captain
actually wants.

---

## 4. File a milestone through the front door

**`file.sh` requires six sections** and refuses the PRD without any one of them.
Write all six before you call it — they are, exactly: **Mission title**, **Type**,
**Goal**, **Acceptance Criteria**, **Out of Scope**, **Constraints**. Either
shape is accepted per section — a bold inline label (`**Goal:** …`) or the label
owning its own line as a heading (`## Goal`). (A complex mission filed with
`--adr` needs each ADR to carry **Context**, **Decision**, **Alternatives
considered** and **Consequences** too.)

For each unfiled milestone, `next` prints mutually exclusive branches: judge
**its own spec/brief**. If it **has screens**, take `holodeck` before filing;
otherwise go straight to `file`. This is model judgement, not a recorded flag.

**Holodeck means the real surface**: open a named Program with
`holodeck_start`, author there through `holodeck_say`, read the concept's open
questions, `derive`, then hand it to a Mission through Align and record its id.
`holodeck_end` closes the worker; its own rooms and Programs survive in the
sidecar. A hand-authored `mockup.html` attached at CLI filing is an
**attachment-only** path: it never passes through the surface, so the Holodeck
stays empty. **State which path you took.**

File through the real verb, with a real PRD on disk:

```bash
lcars-autopilot exec lcars-file/file.sh --prd <path/to/prd.md> --engine copilot
lcars-autopilot record missions.M0.id <the-mission-id-it-prints>
```

**The brief pattern that worked** (200–400 words): the product context and
what is already built; the exact experience in numbered steps; files and paths;
the test seams; out of scope; and, for screens, "mock up: &lt;the screens and
states&gt;".

**The Align-answer pattern:** accept or correct the recommendation in one
sentence, then **pre-settle everything else**, marking each item "RESOLVED with
the captain". Answer *every* design-session item in your first reply — it roughly
halves the grill.

**Two injections into every PRD** until the harness does them for you:

- **The seam constraint.** For every producer/consumer pair the milestone
  creates, demand a round-trip test that uses **both real halves** with no
  hand-written fixture between them. For every CI workflow, demand a test that
  runs the **real entrypoint exactly as the workflow does** (same cwd, same
  command, the env Actions always sets). A test that stubs the seam it claims to
  prove is not proof.
- **The anchor rule**, verbatim with the anchor list, on any PRD with a mockup —
  it turns a 6-attempt Plan flip-flop into a first-try pass.

---

## 4a. Drive through the HUMAN interfaces — never hand-step the stage machine

**The captain's rule, 2026-10-13, after watching a buddy hand-walk a run:**

> *"Buddy in autopilot should run this like a human. I'd click run from after the
> align and let it go and click pause when needed. But the harness should drive
> the states."*
> *"We don't want it not to solve stuff, just do it through the human interfaces."*

Both halves of that matter, and they are easy to get wrong in opposite
directions.

**DO — these ARE the human interfaces, and using them is the job. Never defer
them, never wait for a human, there is nobody there:**

- **Start a mission and let the harness drive it.** `lcars run <id>` WITHOUT
  `--step` is a token-free bash driver that sequences Research → Validate → Plan
  → Plan Review → Schedule → Implement by itself and stops only at a real gate.
- **Answer every human gate, immediately** (`lcars respond`, or the board's
  ANSWER control). A gate with nobody to answer it is a stopped run.
- **Pause when something genuinely needs stopping, and resume.**
- **Accept or send back at Verify, and merge through `lcars approve`.**

**DO NOT — this is reaching behind the interface:**

- Walking a mission forward one verb per Stage, re-issuing `xo off` / `pause` /
  `resume` / `--step` to advance it yourself.
- Writing mission state the harness owns while a worker is running.

**WHY, measured on 2026-10-13 (S291).** Hand-stepping writes mission control
state into `state.json` *while a cold worker is mid-Stage*. The worker fence sees
that file change under a running worker and blames the WORKER, stopping the Stage
and painting a red card:

```
WORKER FENCE BREACH — the repo-read cold worker for this Stage changed
things it is never allowed to write. MISSION STATE: state.json
```

**Nothing is wrong with the build when this fires.** It fired five times in one
run across BOTH engines — Copilot at Plan and at Validate, Claude three times at
Research — every one of them triggered by the buddy following the product's own
prescribed sequence (`pause` refuses while Number One is engaged and names
`xo off` as the cure; both write `state.json`). After the same run switched to
starting missions and letting the harness drive, the count held flat for the rest
of the day while missions continued to complete.

**And the failure mode of over-applying this is just as bad.** Told only "stop
touching control state", a buddy went timid for a whole turn: no merge, no
resume, no gate answered, and it recorded *"leave control state untouched"* while
a mission sat parked at a gate nobody could answer. **A rule that only says what
not to touch produces an agent that solves nothing.** The test is not "did I
touch state" — it is **"would the captain have done this by clicking
something?"** If yes, do it.

> **Note for whoever fixes the underlying defect:** the real cure is in LCARS,
> not here — the fence should distinguish the OPERATOR's sanctioned control
> writes from a worker writing outside its lane. This section reduces how often
> the trap is stepped on; only that change removes it.

## 5. Drive it — backgrounded, with a waiter that watches the process

```bash
lcars-autopilot drive <mission-id>
```

That calls `run.sh drive --mission <id>` with the recorded `gateTimeout`, in the
background, and records the owning pid in `autopilot.json`. **Do not re-sequence
stages yourself** — the driver owns the order.

**The waiter watches the PROCESS, never a clock.** It is the driver's parent and
simply blocks on it, so it cannot overrun and cannot cut LCARS off. On the
modelled run a hand-rolled `alarm` wrapper killed an `approve` mid-retest and
left a reconcile worktree holding the branch. Never wrap an LCARS verb in a
timeout, and never poll a log in a sleep loop: ask `lcars-autopilot next`.

**A failing drive is counted and capped.** The waiter records the exit against
`drivers.<id>.failures`; **three failures in a row and the mode stops retrying**
and writes you a question instead (§ 9) — repeating a failure that never changes
is an LCARS bug with no verb-level workaround, not something to sit on until
morning. A clean drive clears the counter, so one flake costs nothing.
`lcars-autopilot answered <id>` clears it too, once the cause is fixed.

**A routine stage stop pings nobody.** The waiter records the exit and
`lcars-autopilot next` has the next step; the captain hears about a drive only when
it has hit the cap. Spending his interrupt budget (§ 9) on "a stage stopped" is
the inversion of what he asked for.

While a drive is in flight, use the time for live-check prep, the report, or
the *other* slot (§ 8) — not for watching.

---

## 6. The Verify gate — Number One, then the live check

When a mission reaches `verify`, read Number One's verdict
(`lcars-autopilot exec lcars-xo/xo.sh report`, `xo/verdict.json`) — then **do the live check yourself every
time, regardless of its verdict. This is your standing job, never a fallback.**
On the modelled run Number One filed **0 of 31** bugs and every one came from
the live check. Its misses were all *reach* errors, never judgement: no screen
to look at, nothing seeded, stubs that made the seam untestable.

### 6.1 Set it up with one command, then do the looking

```bash
lcars-autopilot live-check <mission-id> --type cli,web,workflow
```

That prepares a **detached** worktree of the mission branch and a **throwaway
HOME** (never the checked-out branch, and never your own HOME: a config you
wrote earlier makes an unconfigurable product look configured), makes the
evidence dir at `.git/lcars/missions/<id>/live-check/`, and prints the
checklist(s) for the product types the milestone touches.

**The script owns the setup, the evidence paths and the record. The looking is
yours.** The checklists live at `skills/lcars-run/live-check/{cli,web,workflow}.md`
— that shared home, and not under the buddy, because the rebuilt Number One
reads the same files. Every item is an action plus the evidence to capture plus
what counts as a defect, and carries a fenced `run:`/`workflow:`/`read:`
template beside the prose so a fenced worker with no shell can lift it.

Pick **every** type the milestone touches. A CLI that writes a page published by
a workflow is all three. The items that found the bugs, by name:

- run `--help` and bad input; a subcommand missing from `--help` is a defect
- **two actors**, two HOMEs
- **make the identities that usually coincide differ** — owner ≠ login, draft
  name ≠ title
- **follow one record end to end**, through every real half (no hand-written
  fixture between a producer and its consumer)
- **check the host of every outbound call**, with a non-default host configured
- real headless Chrome, and the **400 px iframe** recipe for phone width
  (headless will not lay out below 500 px)
- **read the deployed artifact**, not "deploy succeeded"
- **re-verify after every fix round with different data**

### 6.2 Every workflow the mission adds, run exactly as CI runs it

```bash
lcars-autopilot workflow-run <mission-id> .github/workflows/<name>.yml
```

The job's steps, in order, each from its own `working-directory`, with the env
Actions always sets (`GITHUB_SERVER_URL`, `GITHUB_REPOSITORY_OWNER`,
`GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`), and the **first failing step named**.
This is the check a green suite cannot do: on the modelled run a workflow ran
`python3 pkg/hub_requests.py`, which dies on a relative import, while
`python3 -m pkg.hub_requests` works — and every test that imported the function
passed. Do not rewrite a step's command into the form that works; fix the step.

A `uses:` step is reported SKIPPED. That means **unproven**, not passed — prove
it by reading what it published (the web/workflow checklist's artifact item).

### 6.3 Record the verdict, then take the policy's one action

```bash
lcars-autopilot live-check done <mission-id> --verdict pass|bugs
lcars-autopilot policy --mission <mission-id> --live-check pass|bugs \
                    [--verdict high|medium|low] [--reason product|infrastructure] \
                    [--evidence <path>]
```

There is no default verdict: an unrecorded live check would read later as one
that passed. `policy` prints **ONE** action; `lcars-autopilot policy --table`
prints the whole table.

---

## 6a. The merge policy — one action per verdict pair

| Number One | Live check | Action |
|---|---|---|
| any | **bugs** | **send-back** |
| high | pass | **merge** |
| medium | pass | **merge+follow-ups** — merge, and file the gaps it named as their own missions |
| low, for a **product** reason | pass | **send-back** |
| low, for **infrastructure** reasons only | pass | **override** — fix the cause, verify that one point live, record the override |

**THE MERGE IS THE BUDDY'S CALL.** Number One *recommends*; the buddy decides.
It scored every CLI or integration milestone `low` for reasons it could not
reach, which is why a `bugs` live check sends back even a `high`, and why a
`low` that is purely about infrastructure is an override rather than a stop. It
may run its own one fix round (`xo file-logs` → `xo recheck`); you may run
further rounds through `file-bug` beyond that one.

**Every override is recorded, with its evidence path.** `policy` writes it to
`.git/lcars/autopilot-overrides.jsonl` and **refuses** an override whose
`--evidence` path does not exist on disk — an unevidenced override is a shrug,
and this ledger is what the captain reads afterwards.

### The send-back loop, in order

```bash
lcars-autopilot file-bug --parent <mission> --prd <bug-prd.md>   # one PRD per bug
lcars-autopilot exec lcars-resolve-logs/resolve-logs.sh --parent <mission>
lcars-autopilot live-check <mission> --type <types>              # DIFFERENT data this round
lcars-autopilot exec lcars-respond/respond.sh answer --mission <mission> --answer "<the live evidence>"
lcars-autopilot land <mission>
```

The bug PRD template is `bug-prd.md`, beside this file. AC #1 is mandatorily
`Observed live: <the exact output>` with the real identifiers, and a bug at a
producer/consumer seam needs a **round-trip** criterion using both real halves
with no hand-written fixture between them. `file-bug` refuses a PRD without
them, and refuses to report a filing it cannot see (a `log.sh` that exits 0
without linking a child is a refusal, not a filing).

**The one style exemplar is `bug-prd.md`'s own worked example** — match that,
and nothing else. The PRDs in the weekend archive
(`canvas-weekend-2026-09-26/evidence/filed-prds/`) predate the template and
`file-bug` refuses them (no `Out of Scope`, no `**Seam:**`, an AC #1 worded
`Observed (real code, no stubs on the contract):`), so a PRD matched to one of
those cannot be filed. The validator is right; the archive is just older. The
worked example is also deliberately about a FICTIONAL product: an example drawn
from the thing you are checking hands you one of its faults for free.

**Re-verify with DIFFERENT data.** Re-running the first pass's inputs proves
only that one input was patched. Re-run the items that *passed*, too: a fix that
breaks a neighbour is what that catches.

**You do not paste the anchor rule or the seam constraint into the PRDs you file.**
Both are **harness defaults** now — the Plan prompt carries the anchor rule from
one source, and the validator enforces each ticket's declared producer/consumer
seams (S236/S237, landed 2026-10-01). Pasting either into a PRD duplicates what
the harness already does.

When the live check is clean, record that fact for the status readout:

```bash
lcars-autopilot record missions.M0.verified true
```

Take the policy's action directly (`land` for a merge); `next` always returns
the Verify gate while the mission is at `verify`, even with this flag set.

And keep the progress page current, because it is what the captain reads on his
phone:

```bash
lcars-autopilot report
```

It renders, per milestone, the stage, Number One's verdict, the live-check
verdict, the screenshots and the bugs filed/fixed — only from what was written
down, so nothing on it comes from a clock.

---


## 7. Land it — approve, then the hygiene that always follows

```bash
lcars-autopilot land <mission-id>
```

It pre-checks (no live driver, no open logged children), calls the real
`approve.sh --mission`, and then runs the hygiene that the modelled run had to
remember by hand every time: re-assert the captain's `testCommand`, `xo off`
every folded child (LCARS does not release them on fold), remove any stale
`reconcile.XXXXXX` worktree, pull, and write the merge to the decisions ledger.

**`approve` exiting 0 is not proof of a merge.** Its self-heal reconcile path
reconciles `main` into the branch, re-tests it green and then waits for the
captain's `--reapprove` — exit 0, nothing merged, the Mission still at `verify`.
So `land` re-reads the Mission's own `state.json` and claims it landed only when
the stage is really `done`. Otherwise it runs **no** hygiene, writes **no**
`merged` ledger line, raises the pre-staged question naming the exact
`--reapprove` command, and exits **10**. Reapprove is the captain's sign-off:
the mode never gives it.

**You never merge by hand.** Not with a better justification, not "just this
once", not by another route when the permission classifier blocks the first one.
When LCARS refuses a merge, `land` exits **10** and writes ONE pre-staged
question to `autopilot.json.pending` with four fields — what is blocked, why it
is safe, the one command that would run, and the rollback. Surface that
question and **stop that milestone**. Other milestones carry on.

If the captain pre-authorised the manual merge in § 1
(`preauthorised.manualMergeWhenApproveHitsKnownBug`), the question still gets
raised — you pre-stage it with the suite already run on the merged state so his
"OK" costs seconds. His OK is what runs it, not the pre-authorisation alone.

Pushing is also not yours to hand-roll:

```bash
lcars-autopilot push-gated
```

It runs the recorded suite and pushes **only on exit 0**. A hand-rolled version
of this gate once matched the word `FAILED` as success and pushed a red `main`.

---

## 8. Waiting, two missions at a time, and the crontab heartbeat

**Two missions at a time is the ceiling**, and only when their write sets do not
overlap. Two was measured safe on a 10-core Mac; three drove load average to 170
and killed workers. `lcars-autopilot next` enforces it and tells you to wait;
`lcars-autopilot status` shows the slots in use.

**The heartbeat is `crontab`.** One line, minute 17:

```bash
lcars-autopilot heartbeat install    # … remove / status
```

It calls `lcars-autopilot stalled`, which reports a mission whose driver ended with
nobody picking it up — decided from the **recorded pid**, not by grepping a log.
Act on it, then `lcars-autopilot record drivers.<id>.pickedUpAt <ts>`.

Why a crontab line and not the host harness's own cron tool: LCARS ships to
people who are not inside Claude Code, so a harness-only tool cannot be this
mode's heartbeat — on their machine it does not exist. A crontab line is on
every POSIX box, it outlives the session, and the captain can read and delete it
himself. Remove it when the run ends.

---

## 9. The interrupt budget — what actually reaches the captain

> "I definitely don't want to match something if it means I'm going to be
> annoyed more often." — the captain, 2026-09-28

After § 1, **exactly four things** reach him:

1. A **product call** only he can make.
2. A **scope change**.
**A REFUSAL THAT NAMES ITS OWN CURE IS NOT A WALL (S260, 2026-10-08).** This
rule forbids RETRYING BY ANOTHER ROUTE — it does not forbid doing the ONE thing
the refusal explicitly told you to do. When LCARS refuses and names the
sanctioned command that clears it (`xo off <mission>` before answering a
mission Number One owns, `lcars update --test-command` for an unrecorded
runner), RUN THAT COMMAND, record that you did and why, and carry on. Measured:
a run stopped dead and waited on the captain for a documented one-line transfer
the refusal itself had spelled out. Ask only when the cure is NOT named, or when
running it would cross a `never`.

**AND IF A MISSION CANNOT BE PROOF-GATED BECAUSE OF ITS OWN EARLIER ATTEMPTS,
RETIRE AND RE-FILE IT — you already have that latitude.** A mission proves work
by its tests failing on the parent and passing on the tip; once a failed attempt
has COMMITTED its scaffold, the tests pass on the parent too and that mission
can never go green again. That is a dead mission, not a question for the
captain: archive it and re-file from a clean base (never delete), and say in
your report that you did.

3. A **standing-rule conflict** — including every permission denial, and the
   refused merge of § 7.
4. An **LCARS bug with no verb-level workaround**.

Nothing else. Routine progress goes to the report and the pictures, not to a
question. Quality decisions — live verification, bug round-trips, merge
judgement, overriding a verdict on live evidence — you make alone and **record**;
you do not ask for them.

**A denial is a question with the evidence ready, never a retry by another
route.** What is blocked, why it is safe, the one command that will run, the
rollback. `lcars-autopilot land` writes exactly that shape for a refused merge.

**For everything else, raise it with `lcars-autopilot ask` — never by editing
`autopilot.json`.** One question per call, in the same four fields:

```bash
lcars-autopilot ask "Ship M1 as the CLI only, or hold it for the page?" \
  --mission lcars-20260930-001 \
  --why "a product call only you can make — the page needs a deploy token" \
  --command "-" \
  --rollback "nothing to undo — nothing was attempted."
```

It lands in the `questions` ledger **immediately**, with its own id, and pings
him **once**. Asking the same thing again while it is open is a no-op and does
not ping him twice; the same problem recurring *after* he answered is a real new
question. `--mission <id>` is required, because a question blocks *that*
milestone and no other — use `--mission -` for one that belongs to no milestone.
`ask` exits 0: a question is not a milestone stop, so keep working.

**`pending` is a read-only mirror of the oldest open question, derived on every
write — it is never storage.** Do not write it, and never read a question out of
it: `questions` is the record and `status` prints every id. A question an older
run left in `pending` is still honoured: it is adopted the moment it is seen,
exactly once, into `questions` under a real id. Use the verb and there is
nothing to adopt.

**Several questions can be open at once, and none of them parks the run.** Each
is recorded separately and `status` prints them all with their ids. A question on
one milestone blocks *that* milestone only: `lcars-autopilot next` still names the
runnable work on the others, and with two slots that is the point. Ask them in
one message when you can, close each with `lcars-autopilot answered <id> "<what he
said>"`, and keep working while you wait.

**The communication rules**, which he taught during the modelled run:

- **Answer as the final message of the turn.** A reply woven between tool calls
  never reaches his remote view — he said "you've ignored my last two messages".
- **One crisp, plain-English paragraph** on request: what is done, what is
  blocked, the next step and its owner. Say what "works" and "blocked" mean
  concretely.
- **Pictures for every milestone**, including CLI ones. Keep ONE report page and
  republish it in place; send key screenshots to his phone proactively.
- He dictates by voice: read "our cars" / "Elcar" / "El cars" as LCARS, "corks"
  as quirks, and expect "do"/"don't" to flip occasionally — confirm when it
  matters.
- **Be honest about misses, including your own**, and ledger them.

**Deadline honesty.** **Re-forecast at every stage change** from actuals, and
push the new forecast to him as soon as it crosses his target, with the options
("ship these three now and land the laggard later"). On the modelled run every
slip was reported late.

```bash
lcars-autopilot record lastForecast "M0–M2 by 06:10; M3 at risk (plan round 2)"
```

---

## 10. Wrap-up — lead with the time the captain got back

When everything in scope is merged and verified, `lcars-autopilot next` says
`done`. The final message **leads with what he got back**: hours away, questions
asked, milestones shipped. Then:

- what shipped, and what each thing does in plain English;
- pictures;
- what you decided alone, and every override, from the ledgers;
- LCARS bugs and friction you hit, from `lcars-feedback.jsonl`, with the
  work-arounds you used — these are somebody's next fix session;
- what the proof was blind to;
- worker spend (Copilot is free — say so) alongside your own host-model tokens;
- `lcars-autopilot heartbeat remove`, and any worktrees or throwaway HOMEs torn
  down.

---

## The shape of the whole thing, in one block

```
lcars buddy                                     # read the brief
buddy> run it for me <spec>                     # ONE question round
  lcars-autopilot init --spec … --scope …       # record every answer
  lcars-autopilot heartbeat install
loop:
  lcars-autopilot next                          # the ONE next step + its heading here
    file       → lcars-autopilot exec lcars-file/file.sh --prd --engine  → record missions.<M>.id
    drive      → lcars-autopilot drive <id>        (backgrounded; waiter on the process)
    verify-gate→ xo report + your live check    → policy → land or the send-back loop
    land       → lcars-autopilot land <id>         (approve + hygiene; exit 10 = ask)
    wait       → two at a time is the ceiling
  lcars-autopilot status                        # the one screen, any time
done:
  lcars-autopilot heartbeat remove; wrap up (§ 10)
```
