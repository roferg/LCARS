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
`autopilot.sh`, which spends nothing.

> This is **not** a fix loop. The autopilot never edits the LCARS source. If it
> hits an LCARS bug it works around it with another verb and ledgers it, or it
> stops and asks. Fixing LCARS is `lcars buddy` § 2, under `ORCHESTRATION.md`.

## How to read this file

Ask the driver what to do next, then read that section:

```bash
bash ~/.claude/skills/lcars-buddy/autopilot.sh next
```

It prints one action and the **exact heading in this file** that covers it:

```
NEXT: verify-gate lcars-20260930-001
WHY: M0 reached the Verify gate — read Number One, then run the live check
PLAYBOOK: ## 6. The Verify gate — Number One, then the live check
```

`autopilot.sh playbook` prints the whole action→heading table, and the test
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
with its id (which `autopilot.sh status` prints) and the mirror moves on:

```bash
autopilot.sh status                       # [q1] lcars-…: <the question>
autopilot.sh answered q1 "yes, go ahead"  # records the answer BESIDE the question
```

`answered` never deletes: the question stays on the record with his answer next
to it, and it clears that mission's failed-drive counter (§ 5), because his
answer is what unblocks it.

Write with the driver, not by hand:

```bash
autopilot.sh record liveTargets.host github.ghe.com
autopilot.sh record missions.M0.id lcars-20260930-001
autopilot.sh record missions.M0.verified true
autopilot.sh record preauthorised.liveTestWrites true
```

**The memory rule.** Your context *will* compact on a run this long. After any
compaction — or at the start of any session where the captain says "continue" —
your **first** action is to re-read `autopilot.json` and run `autopilot.sh
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
autopilot.sh ledger feedback  '{"kind":"lcars-bug","detail":"fold drift blocked a merge"}'
autopilot.sh ledger overrides '{"mission":"lcars-…","verdict":"low","reason":"infra only","evidence":"…"}'
autopilot.sh ledger decisions '{"what":"added M6","who":"captain"}'
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
   there is a key for it: `autopilot.sh record deploy '{"where":"…","liveMeans":"…"}'`.
4. **What to do if LCARS itself breaks** — the default is *stop and report*.
5. **The pre-authorisations** (§ 9): may you do a manual merge if `approve` hits
   a known LCARS bug and the merged suite is green? May live checks write to the
   product repo? Both default to **no**.

Then write it all down and start:

```bash
autopilot.sh init --spec <path-or-url> --scope M0,M1,M2 --engine copilot \
                  --deadline 2026-10-01T07:00:00-07:00
autopilot.sh record latitude.allowed '[ … ]'     # his words, not the defaults
autopilot.sh record liveTargets '{"host":"…","owners":["…"]}'
autopilot.sh heartbeat install
```

**This is the whole interrupt budget for the setup.** A second question round
is a defect in how you ran this step, not a fact about the spec.

---

## 2. Captain-only steps, collected up front

Some things only he can do: a token, a repo secret, SSO authorisation, an org
setting, a repo rename. On the modelled run a hub token surfaced at 10:40am and
SSO at 1pm — both on the critical path, both avoidable. **Enumerate them in the
alignment round**, with a *needed by* time, and record them:

```bash
autopilot.sh record captainOnlySteps '[
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
`autopilot.sh record captainOnlySteps '[…"done":true…]'`, and say plainly what
is still missing.

**If he DECLINES one, record the decline — never `done: true`, never delete it.**
A declined step is an outcome, with a third state of its own:

```bash
autopilot.sh record captainOnlySteps '[
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
own initialization mission, and LCARS already has the verb for it:

```bash
bash ~/.claude/skills/lcars-init/establish-vision.sh --file \
     --stack "<the stack>" --slice "<a thin end-to-end slice>" --engine copilot
```

Do **not** write your own scaffold. Mark it done when it lands:

```bash
autopilot.sh record foundation.done true
```

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

File through the real verb, with a real PRD on disk:

```bash
bash ~/.claude/skills/lcars-file/file.sh --prd <path/to/prd.md> --engine copilot
autopilot.sh record missions.M0.id <the-mission-id-it-prints>
```

Use the holodeck first when the milestone **has screens** (design → `say` the
brief → read the concept's open questions → `derive` → align), and the CLI front
door otherwise.

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

## 5. Drive it — backgrounded, with a waiter that watches the process

```bash
autopilot.sh drive <mission-id>
```

That calls `run.sh drive --mission <id>` with the recorded `gateTimeout`, in the
background, and records the owning pid in `autopilot.json`. **Do not re-sequence
stages yourself** — the driver owns the order.

**The waiter watches the PROCESS, never a clock.** It is the driver's parent and
simply blocks on it, so it cannot overrun and cannot cut LCARS off. On the
modelled run a hand-rolled `alarm` wrapper killed an `approve` mid-retest and
left a reconcile worktree holding the branch. Never wrap an LCARS verb in a
timeout, and never poll a log in a sleep loop: ask `autopilot.sh next`.

**A failing drive is counted and capped.** The waiter records the exit against
`drivers.<id>.failures`; **three failures in a row and the mode stops retrying**
and writes you a question instead (§ 9) — repeating a failure that never changes
is an LCARS bug with no verb-level workaround, not something to sit on until
morning. A clean drive clears the counter, so one flake costs nothing.
`autopilot.sh answered <id>` clears it too, once the cause is fixed.

**A routine stage stop pings nobody.** The waiter records the exit and
`autopilot.sh next` has the next step; the captain hears about a drive only when
it has hit the cap. Spending his interrupt budget (§ 9) on "a stage stopped" is
the inversion of what he asked for.

While a drive is in flight, use the time for live-check prep, the report, or
the *other* slot (§ 8) — not for watching.

---

## 6. The Verify gate — Number One, then the live check

When a mission reaches `verify`, read Number One's verdict
(`xo.sh report`, `xo/verdict.json`) — and then **do the live check yourself**,
because on the modelled run Number One filed **0 of 31** bugs and every one came
from the live check. Its misses were all *reach* errors, never judgement: no
screen to look at, nothing seeded, stubs that made the seam untestable.

Always check from a detached worktree with a throwaway HOME, never the checked-out
branch:

```bash
autopilot.sh worktree <mission-id>      # prints WORKTREE: … and HOME: …
```

> **S234 — STUB.** The per-product-type live-check checklists (CLI, web page,
> CI workflow), the evidence-first bug PRD template, and the merge policy are
> **Session 234's** work and are not in this file yet. Until S234 lands, follow
> `orchestrator-playbook.md` § 4–5 by hand: run the real CLI (including
> `--help` and bad input), use two actors, make identities that usually coincide
> differ, follow the data end to end, check the host of every outbound call,
> screenshot in a real browser (400 px *iframe* for phone width), read the
> deployed artifact rather than "deploy succeeded", and re-verify after every fix
> round with different data.

When the live check finds something, send it back through LCARS's own verbs with
an evidence-first PRD — the first acceptance criterion is literally
`Observed live: <exact output>`:

```bash
bash ~/.claude/skills/lcars-log/log.sh --parent <mission> --prd <bug-prd.md>
bash ~/.claude/skills/lcars-resolve-logs/resolve-logs.sh --parent <mission>
bash ~/.claude/skills/lcars-respond/respond.sh answer --mission <mission> --answer "<the live evidence>"
```

When it is clean, record that fact — `land` and `next` both read it:

```bash
autopilot.sh record missions.M0.verified true
```

---

## 7. Land it — approve, then the hygiene that always follows

```bash
autopilot.sh land <mission-id>
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
autopilot.sh push-gated
```

It runs the recorded suite and pushes **only on exit 0**. A hand-rolled version
of this gate once matched the word `FAILED` as success and pushed a red `main`.

---

## 8. Waiting, two missions at a time, and the crontab heartbeat

**Two missions at a time is the ceiling**, and only when their write sets do not
overlap. Two was measured safe on a 10-core Mac; three drove load average to 170
and killed workers. `autopilot.sh next` enforces it and tells you to wait;
`autopilot.sh status` shows the slots in use.

**The heartbeat is `crontab`.** One line, minute 17:

```bash
autopilot.sh heartbeat install    # … remove / status
```

It calls `autopilot.sh stalled`, which reports a mission whose driver ended with
nobody picking it up — decided from the **recorded pid**, not by grepping a log.
Act on it, then `autopilot.sh record drivers.<id>.pickedUpAt <ts>`.

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
3. A **standing-rule conflict** — including every permission denial, and the
   refused merge of § 7.
4. An **LCARS bug with no verb-level workaround**.

Nothing else. Routine progress goes to the report and the pictures, not to a
question. Quality decisions — live verification, bug round-trips, merge
judgement, overriding a verdict on live evidence — you make alone and **record**;
you do not ask for them.

**A denial is a question with the evidence ready, never a retry by another
route.** What is blocked, why it is safe, the one command that will run, the
rollback. `autopilot.sh land` writes exactly that shape; write the same shape by
hand for anything else, into `pending`, and it is carried into the `questions`
ledger on the next write so it cannot be overwritten.

**Several questions can be open at once, and none of them parks the run.** Each
is recorded separately and `status` prints them all with their ids. A question on
one milestone blocks *that* milestone only: `autopilot.sh next` still names the
runnable work on the others, and with two slots that is the point. Ask them in
one message when you can, close each with `autopilot.sh answered <id> "<what he
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
autopilot.sh record lastForecast "M0–M2 by 06:10; M3 at risk (plan round 2)"
```

---

## 10. Wrap-up — lead with the time the captain got back

When everything in scope is merged and verified, `autopilot.sh next` says
`done`. The final message **leads with what he got back**: hours away, questions
asked, milestones shipped. Then:

- what shipped, and what each thing does in plain English;
- pictures;
- what you decided alone, and every override, from the ledgers;
- LCARS bugs and friction you hit, from `lcars-feedback.jsonl`, with the
  work-arounds you used — these are somebody's next fix session;
- what the proof was blind to;
- worker spend (Copilot is free — say so) alongside your own host-model tokens;
- `autopilot.sh heartbeat remove`, and any worktrees or throwaway HOMEs torn
  down.

---

## The shape of the whole thing, in one block

```
lcars buddy                                  # read the brief
buddy> run it for me <spec>                  # ONE question round
  autopilot.sh init --spec … --scope …       # record every answer
  autopilot.sh heartbeat install
loop:
  autopilot.sh next                          # the ONE next step + its heading here
    file       → file.sh --prd --engine      → record missions.<M>.id
    drive      → autopilot.sh drive <id>     (backgrounded; waiter on the process)
    verify-gate→ xo report + the live check   → record missions.<M>.verified
    land       → autopilot.sh land <id>      (approve + hygiene; exit 10 = ask)
    wait       → two at a time is the ceiling
  autopilot.sh status                        # the one screen, any time
done:
  autopilot.sh heartbeat remove; wrap up (§ 10)
```
