---
name: lcars-run
description: >-
  Advance an LCARS Mission through the pipeline. By default `lcars run <id>`
  AUTO-ADVANCES — a thin, token-free bash driver sequences the Stages
  back-to-back (Research → Validate → Plan → Plan Review → Schedule →
  Implement), each spawned as a cold isolated worker, and stops only at a
  human gate, firing a walk-away notification. It halts when a Stage
  escalates a question (awaiting-human), at the Verify review gate, at an
  `align` feedback re-entry (an interactive re-grill), or on an error;
  `lcars run <id> --step` advances exactly one Stage (the old one-at-a-time
  behaviour, for debugging). It also handles the Align re-entry after `lcars
  feedback` bounces a Mission back from Verify — re-grilling against the PRD
  plus the accumulated feedback before Research. Use when the user runs
  `lcars run <mission-id>`, asks to advance / progress / continue / auto-run
  a mission, or to run a single Research, Validate, Plan, Plan Review,
  Schedule, Implement, or Verify stage.
---

# lcars run

`lcars run <mission-id>` **auto-advances** a Mission through the LCARS pipeline:
a thin, **token-free** bash driver runs the Stages back-to-back until it hits a
**human gate**, then stops and pings you. `lcars run <mission-id> --step`
advances **exactly one Stage** and stops — the previous one-at-a-time behaviour,
kept for debugging and inspection.

Every **headless** Stage's LLM work runs in a **cold subprocess worker** —
`run.sh` assembles the worker's prompt from a per-Stage template plus the
artifact *paths* alone and spawns it through `$LCARS_WORKER_BIN` (the host CLI by
default). You (Claude) do **no** Stage reasoning: you invoke the driver and
report what it printed. The driver itself does no model reasoning — it only
sequences the Stages; all the thinking happens in the cold workers each Stage
spawns. The bundled `run.sh` does the spawning, validation, and mechanical
persistence so it all stays under test.

### Stage isolation: headless Stages are cold workers, not inline reasoning

The reason the LLM work is a subprocess and not something you do inline is
**isolation** (vision.md → *Stage Isolation*; closes BUG-004). A worker shares
**no** context with you or with the previous Stage — its prompt is built by
`run.sh` from the on-disk artifact **paths** only (the worker `Read`s them
itself), so there is no channel for one Stage's reasoning to leak into the next,
even when the whole pipeline runs in one sitting. Because the worker is one
swappable binary, this is also the CLI-portability groundwork (BUG-003): run
LCARS under Claude Code and every worker is Claude; under Copilot, every worker
is Copilot.

Each headless Stage is therefore a single driver subcommand you run and report:

| Stage | Driver | What it spawns |
|---|---|---|
| Research | `run.sh research --mission <id>` | a question-generator worker, then **N parallel** stateless research workers (one per question) |
| Validate | `run.sh validate --mission <id>` | one Validator worker (fed only `prd.md` + `research/*.json`) |
| Plan | `run.sh plan --mission <id>` | one Planner worker (fed only `prd.md` + `validated-plan.md`) |
| Plan Review | `run.sh plan-review --mission <id>` | one fresh reviewer worker (fed only `plan.json`) |
| Implement | `run.sh implement-ticket --mission <id> --ticket <id>` | one unified TDD worker, proven post-hoc by the harness gates |

Live operator controls (`pause`, `resume`, and `xo on`/`xo off`, including
repo-wide switches and linked-child pauses) record each successful `state.json`
write in the mission's append-only `operator-writes.tsv`; pause/resume also record
their `events.jsonl` append. Each row names the file, exact input/output content
fingerprints, and control. The post-turn worker fence accepts only new records
that form an unbroken chain from its pre-turn fingerprint to its post-turn
fingerprint. Unrecorded worker writes, extra watched-file changes, and code
checkout changes still stop the Stage with `worker_fence_breach`. A failed write
records nothing; a failed recording is a loud failure, never an exemption.

Each driver prints a **`⊘ isolated`** marker naming the worker it ran in. If no
worker binary is available the driver refuses **loudly** (`⚠ NOT ISOLATED`) and
changes nothing — an inline/uncovered run must never masquerade as isolated. A
malformed worker output stops the Stage and is re-dispatched up to a few attempts
before surfacing failure; the Stage never silently advances on bad output.

**Schedule** is mechanical (no worker), and the two **interactive** Stages —
Align's re-grill and the Verify gate — stay on the host CLI (your session), not a
cold worker. The driver subcommands sit on top of the mechanical persistence
subcommands (`gate` / `save` / `validate-*` / `plan-save` / `review-save` /
`impl-*`), which they reuse to record results.

**This build implements the Research, Validate, Plan, Plan Review, Schedule,
Implement, and Verify stages.** A Mission filed by `lcars file` sits at stage
`align` (the Align grilling already happened during `lcars file`), so the next
Stage to execute is **Research**; when Research finishes the Mission parks at
`validate`, ready for **Validate**; when Validate finishes it parks at `plan`,
ready for **Plan**; when Plan finishes it parks at `plan-review`, ready for
**Plan Review**; when Plan Review passes it parks at `schedule`, ready for
**Schedule**; when Schedule finishes it parks at `implement`, ready for
**Implement**; when Implement finishes it parks at `verify`, ready for
**Verify**. Verify is a human gate: `lcars run` prints the pre-ship summary and
stops, and the captain ships with **`lcars approve`** or bounces it back with
**`lcars feedback`** (each its own skill). A feedback bounce resets the Mission
to `align` with `feedback.md` on disk, so the next `lcars run` re-enters Align
rather than running Research cold.

## When to use

The sentences below were part of this skill's frontmatter `description:` until
S276 moved them here. GitHub Copilot's CLI caps a skill description at 1024
characters and refused to load this skill over it; the description now keeps
the identity, the command forms and the `Use when…` trigger phrases that both
CLIs match on, and the detail it could not hold is relocated here verbatim.
Nothing was deleted.

Research reads the PRD, generates 0–20 questions, dispatches stateless
research subagents, and saves their findings; Validate synthesises those
findings against the PRD into a validated plan, escalating scope changes to
the human; Plan decomposes the validated plan into small, vertical-slice
tickets in plan.json; Plan Review runs a fresh reviewer over those tickets
alone, approving them to Schedule or looping back to Plan with objections
(escalating to the human after three rounds); Schedule builds the ticket
dependency graph into sequential waves, opens one GitHub sub-issue per ticket,
and advances to Implement; Implement processes the waves sequentially, running
each ticket through ONE unified TDD worker whose work is then proven by
deterministic gates (fail-on-parent/pass-on-tip flip-flop, declared test
edits, a quality floor — a rejection bounces to a fresh worker up to 3
sessions, then parks awaiting-human) and advancing to Verify when every ticket
is green; and Verify prints the captain's pre-ship summary and the two next
moves, then stops at the human gate.

## How you run it: the auto-advance driver

For almost every Mission you run **one command** and report what it printed:

```bash
bash ~/.claude/skills/lcars-run/run.sh drive --mission <id>          # auto-advance (default)
bash ~/.claude/skills/lcars-run/run.sh drive --mission <id> --step   # one Stage, then stop
```

The `drive` loop reads `state.json`, sequences the per-Stage advances below
(each a cold isolated worker), and **halts at a human gate**, printing a
stage-by-stage summary and the reason it stopped. Auto mode and `--step` share
the **exact same** per-Stage code path — the only difference is the loop.

### Before the first Stage: the base-freshness re-check (S159)

Every `drive` — auto or `--step` — re-asks the question `lcars file` asked when
the Mission was filed: **is the base branch still current?** Filing and starting
are different moments, and a Mission driven the next morning otherwise reasons
about last night's tree.

The check runs once per drive, after the driver lock and *before* any Stage
worker is spawned, through the same `ensure_base_current` guard `lcars file`
uses. It **never blocks the drive** and it holds the captain's clone sacred: it
may fast-forward the base only when that branch is checked out and the tree is
clean, and it never resets, forces, stashes, cleans, rebases, or checks anything
out. What it does, it prints:

| what you see | what happened |
|---|---|
| *(nothing)* | the base already contained everything origin has |
| `✓ base main fast-forwarded N commit(s) from origin.` | the base was behind and LCARS brought it current |
| `⚠ BASE FRESHNESS …` | the base is behind and LCARS could **not** fix it (dirty tree, diverged, …) — the block names why, and the exact command that clears it |
| `⊘ base lcars/<id> is a Mission branch …` | the base is another Mission's branch (a logged bug's parent), so there is nothing to bring down from origin and nothing was touched |
| `✓ MISSION BRANCH — lcars/<id> fast-forwarded N commit(s) onto main.` | the Mission's own branch carried no commits of its own, so the drive brought it onto the refreshed base too |
| `⚠ MISSION BRANCH …` | the Mission's branch is behind and the drive did **not** move it — it carries commits of its own (forcing it would destroy them), or its checkout is dirty, or a local file would be overwritten. The block names which, and the one command that clears it |

**Why the Mission branch matters more than the base.** Every read-only Stage is
pinned to `lcars/<id>` and told to ignore the ambient checkout, so bringing only
the base current would still hand each Stage the filing-time tree. The drive
therefore fast-forwards `lcars/<id>` as well — but ONLY when that is lossless (no
commits of its own), by a pointer move when it is not checked out and by a real
`--ff-only` inside its own checkout when it is, never into a dirty tree and never
by a checkout, reset or force. `lcars file` does none of this: at file time a
branch cut at an older commit was cut there on purpose.

**Implement self-heal recovery is different from the startup fast-forward.**
When the full-suite gate needs a repair and the Mission has both its own commits
and a newer base, the self-heal guard merges the base instead of rewriting those
commits. It builds the merge in a detached recovery worktree under the replay
mutex, checks that both original tips remain ancestors, and publishes only if
the Mission tip has not changed. The existing ticket re-check and full-suite
gate then judge the merged state. A dirty tree, an operation in progress, a
Mission branch checked out elsewhere, or a failed/conflicting merge stops
recovery for a human without spending a repair round. The startup helper's
refusal to force-move committed work and Verify's stage restriction are unchanged.

The verdict is recorded on the Mission as `state.json.baseFreshness`
(`verdict` ∈ `current | updated | stale | unknown | child-base`, plus `reason`,
`fix` (one runnable command or nothing), `fixNote`, `blocker`,
`behindBy`, `baseSha`, `checkedAt`, and `missionBranchAtBase` — `true` only when
`lcars/<id>` really does contain the base tip, so a move that did not happen is
never reported as one). A drive that *began* against a base that was
genuinely behind also logs one `base_stale` event to the Mission timeline; an
unchanged re-drive logs nothing new.

### Auto-advance with the foreground per-Stage loop (the portable default)

A full `drive` can run for many minutes (Research → … → Implement), so two naive
shapes both break:

- **One blocking `drive`** shows the captain nothing until it returns *and* can
  exceed a host's per-call time cap (Claude Code's Bash tool tops out around ten
  minutes), so a long Implement Stage gets **killed mid-Stage** — a regression.
- **Backgrounding (`&`) + piping (`| tee`)** is **denied under headless GitHub
  Copilot CLI** even with `--allow-all-tools` ("Permission denied and could not
  request permission from user"). A SKILL that mandates `&` reliably fails there.

So the **required, CLI-agnostic** way to auto-advance is the **foreground
per-Stage loop**: drive **one Stage at a time in the foreground** with `--step`,
relay each Stage's printed output, and loop until the driver reports a halt. No
`&`, no `| tee`, no pipe — every call is a plain foreground invocation, and each
`--step` advance is a single (short) Stage, so no one call risks the time cap and
nothing needs job control:

```bash
# Loop, one foreground Stage per pass, until the driver reports a halt.
bash ~/.claude/skills/lcars-run/run.sh drive --mission <id> --step
```

Each pass:

1. **Run exactly one foreground `--step`** and **relay what it printed** — the
   per-Stage line and its `⊘ isolated … via <cli>` marker — to the captain, so
   the session reads as a Stage-by-Stage ticker, not a wall of repeats.
2. **Read the printed halt line** the driver returns after the Stage. `--step`
   ends each pass with either `⏹ stepped one Stage → now at: <stage>` (keep
   looping) **or** a terminal halt (stop — see *Halt conditions* below).
3. **If it stepped to a new non-terminal stage, loop** — run the next foreground
   `--step`. **If it reported a halt** (an awaiting-human gate, `verify`, an
   `align` feedback re-entry, `done`, or `⚠ NOT ISOLATED`/error), **stop the
   loop**, relay the driver's **final summary byte-for-byte**, and **fire/echo
   the notification exactly as today** at the two human gates.

The driver does all the Stage work; you do **no** Stage reasoning — you sequence
the foreground `--step` calls and relay output. The end-of-run summary and the
`⊘ isolated … via <cli>` / `⚠ NOT ISOLATED` markers are the driver's, relayed
**byte-for-byte** — the loop changes only *when* progress is shown, never its
shape. It does **not** change the driver's stage logic or the event format.

> **Optional, job-control-only:** in a shell that *permits* backgrounding (e.g.
> an interactive Claude Code session — **never** headless Copilot, which denies
> `&`/pipes), you may instead run `drive` (no `--step`) **detached** —
> `bash …/run.sh drive --mission <id> > /tmp/lcars-drive-<id>.log 2>&1 &`,
> capturing `DRIVE_PID=$!` — and relay a periodic digest while it runs, looping
> `kill -0 "$DRIVE_PID"` until the driver exits and rendering each pass with
> `bash …/status.sh --once <id>` (the deterministic snapshot, **never** the
> worker) every `${LCARS_WATCH_INTERVAL:-60}` seconds. This is a convenience for
> shells with job control only — **not** the default path. The portable
> foreground per-Stage loop above is what you use unless you know the shell
> permits `&`.

A single `--step` for debugging needs no loop at all: it returns immediately
after one Stage — run it blocking and report what it printed.

**Halt conditions** (the driver stops and returns to you):

| Halt | Why | What the driver does |
|---|---|---|
| `awaitingHuman === true` | a Stage escalated (Research >20 Qs, Validate scope change, Plan Review round-3, Implement 3-worker-session cap) | prints the pending question(s) + the runnable `respond.sh answer --mission <id>` hint, **fires the notification** |
| `stage === "verify"` | the human review gate — never auto-passed | prints the ship-or-send-back next moves, **fires the notification** |
| `stage === "align"` **with** `feedback.md` | a Verify feedback re-entry needs an interactive Align re-grill | stops and tells you to re-grill (see below) — **no notification** |
| `stage === "done"` | terminal — the PR is open | reports it is shipped |
| a Stage errors | malformed worker output, missing worker, etc. | stops, surfaces the error, does **not** continue — **no notification** |

The summary marks each headless Stage `⊘ isolated` (the cold-worker handoff). If
a Stage ever prints `⚠ NOT ISOLATED` the driver stops loudly — there is no
worker binary; tell the captain to set `$LCARS_WORKER_BIN` (e.g. `claude`). Do
**not** substitute your own session for a worker.

Each front-half Stage line also carries a **`⌂ <branch> @ <sha>`** marker — the
tree that Stage actually read. Relay it: it is the captain's only sight of which
code their Research/Validate/Plan reasoned about, and the question every
surprising Stage result starts with. A line with **no** `⌂` means that Mission
has no branch of its own and the Stage read the ambient checkout — say that
plainly rather than filling in a branch name.

### The one thing you do *before* the driver: the interactive Align re-entry

The driver cannot run Align — it is a human grilling session, not automatable.
So when you start a `lcars run` you must first check: is this an **`align`
Mission with a `feedback.md`** (a bounce-back from Verify via `lcars feedback`)?

- **No `feedback.md`** (a freshly filed `align` Mission, or any later stage) →
  just run the **foreground per-Stage loop** above. It auto-advances from Research.
- **`feedback.md` present** → do the **Align re-entry** in *your* session first
  (read `prd.md` + the full `feedback.md`, re-grill, and **rewrite `prd.md`** —
  see *The Align re-entry* below). Then run `run.sh research --mission <id>` once
  to leave `align`, and finally auto-advance the rest with the foreground
  per-Stage loop. (Driving straight on an un-regrilled feedback Mission just halts
  at the align gate — that is the safety net, not the normal path.)

If the mission dir or `state.json` is missing, tell the captain the id is wrong
/ the mission isn't filed, and stop.

### When you want one Stage at a time

`--step` advances exactly one Stage and stops (no notification unless that single
Stage lands on a gate). The per-Stage sections below document what each composed
step does and remain the reference for `--step` and for debugging; the driver
simply runs them in sequence. **A paused Stage never re-runs on its own:** when
`awaitingHuman` is `true`, the underlying Stage driver refuses until
`respond.sh answer --mission <id> --answer "…"` clears the gate — auto mode and
`--step` both inherit that.

## The Research stage

**Do not read the PRD, generate questions, or spawn agents yourself.** Research
is a headless Stage: run the one driver and report. It spawns a cold
question-generator worker (fed only `prd.md`), gates on the count, and on
dispatch fans out **N parallel** stateless research workers — each given only its
single question, no PRD and no siblings (CONTEXT.md → *Research Agent*) — then
saves the findings and advances to `validate`.

```bash
bash ~/.claude/skills/lcars-run/run.sh research --mission <id>
```

The driver prints the gate decision plus a `⊘ isolated` marker:

| Driver output | Meaning | What you do |
|---|---|---|
| `GATE: skip` then `⊘ isolated` | 0 questions — the PRD was unambiguous. The mission has **already** advanced (stage + label → `validate`). | Report it. **Done.** |
| `GATE: dispatch N` … `SAVE: N responses` … `⊘ isolated` | N research workers ran in parallel and their findings were saved; the mission advanced to `validate`. | Report how many ran and that it is ready for **Validate**. |
| `GATE: too-many N` (exit 3) | More than 20 questions — the driver escalated to the **awaiting-human** gate (card moved to the Research column, `lcars:awaiting-human` overlaid). | Surface the two options — **override** (re-run `research` to proceed) or **return-to-align** (re-run `lcars file` with the context to sharpen the PRD). The captain answers with `respond.sh answer --mission <id> --answer "…"`. |

If the driver prints `⚠ NOT ISOLATED` and refuses, there is no worker binary —
tell the captain to set `$LCARS_WORKER_BIN` (e.g. `claude`); do **not** try to do
the Stage inline.

### A negative-existence claim is CHECKED, not believed (S180)

When a finding asserts that a **specific named, code-shaped identifier** is
absent from the repository *as a whole*, `save` runs that search itself — a
literal `git grep` of the Mission's own branch. **A worker's report of having
searched is never the evidence.** Measured: a finding said a name did not exist
"anywhere in the repo (grep returns zero matches)"; it was defined and used three
times in the one file the Mission was about to rewrite, and every later Stage
took the fabrication as fact.

The check is deterministic and deliberately narrow, so it fires rarely and is
always right: only an **unqualified, repository-wide** claim about a
`SCREAMING_SNAKE_CASE` / `snake_case` / `camelCase` name counts. A claim scoped to
one file, one call site or one subject, and any claim about a concept rather than
a name, is left alone — swept over 144 real findings it yields one candidate.

`SAVE: … / REFUTED:` means the repository contradicted a finding. The findings are
still saved, the Mission moves to **Validate** and parks there **awaiting-human**
with the identifier, the ref searched and the matching lines. Surface that to the
captain; his answer reaches the Validator as a decided input. `save` still exits
0 — a park is a gate, not an error.

## The Validate stage

Runs when `state.json.stage` is `validate` and `awaitingHuman` is not `true`
(see Dispatch). **Do not synthesise the findings yourself.** Run the driver: it
spawns one cold **Validator** worker fed only `prd.md` + `research/*.json`. The
worker reviews every finding *in the context of the PRD*, writes a
`validated-plan.md` synthesis (with `## Synthesis`, `## Decisions`, and a
`## Rationale` section recording the *why*), and emits zero or more
**scope-change** questions — a point counts only if it changes *what* gets built,
not *how* (CONTEXT.md → *Validate*). The driver persists the outcome.

```bash
bash ~/.claude/skills/lcars-run/run.sh validate --mission <id>
```

| Driver output | Meaning | What you do |
|---|---|---|
| `VALIDATE: advanced` … `⊘ isolated` | No scope question. The worker's `validated-plan.md` is saved and the mission advanced to `plan`. | Report that it is at **Plan**. |
| `VALIDATE: paused` … | A scope question. The driver wrote `pending.json`, set the awaiting-human gate, and kept the card in Validate. | Surface the question(s); the captain answers with `respond.sh answer --mission <id> --answer "…"`. **Stop.** |

A worker whose plan is malformed (e.g. it drops the `## Rationale`) is rejected
and re-dispatched; if it never produces a valid plan the driver stops the Stage
without advancing.

**Resume after the human answers:** once `respond.sh answer --mission <id>`
records the answers and clears `awaitingHuman`, it hands straight back to
`run.sh drive --mission <id>` itself, which falls through to Validate again and
re-runs the driver. The fresh Validator worker reads the recorded
answers alongside the PRD and findings, folds them in, and — assuming no new
scope question — advances to Plan, clearing the gate.

## The Plan stage

Runs when `state.json.stage` is `plan`. **Do not decompose the plan yourself.**
Run the driver: it spawns one cold **Planner** worker fed only `prd.md` +
`validated-plan.md` — the *what* and the agreed *how* — which decomposes them
into small, vertical-slice tickets and writes `plan.json`. The driver validates
and installs it, advancing to `plan-review`.

```bash
bash ~/.claude/skills/lcars-run/run.sh plan --mission <id>
```

Each ticket the worker produces carries `id`, `title`, `description`,
`acceptanceCriteria` (≥1), three comprehension-load estimates —
`estimatedReadLoc` (existing code to read), `estimatedTestLoc` (the test suite),
and `estimatedNewLoc` (net-new production code), whose sum targets
`comprehensionBudget`, default 1200 — `dependencies` (only ids in
this plan), and a **`rationale`** — *why* this slice exists and why it is drawn
where it is. `plan-save` (invoked by the driver) refuses a plan that drops any
required field, including the rationale, so the Stage will re-dispatch the worker
and ultimately stop rather than advance on a half-formed plan. On success the
driver prints `PLAN: advanced` and a `⊘ isolated` marker.

**Report:** how many tickets the plan holds (`plan.json`) and that the Mission is
now at **Plan Review**. (On a Plan Review loop-back, this same driver re-runs; the
fresh Planner worker reads the latest `plan-review-<round>.json` objections
itself — see Plan Review below.)

### A revision is a PATCH (S178)

When Plan Review bounces a plan back, `review_fail` writes
**`plan-under-review.json`** — a snapshot of the exact tickets the reviewer read.
That file is the *evidence* that a revision was requested, and everything below
keys off it and off nothing else:

- the Plan prompt lists it as an input and adds a contract saying plainly that
  this is a REVISION: apply what the objections ask and change nothing else,
  keeping every ticket's `dependencies` exactly as they were unless an objection
  names that ticket;
- `plan-save` **compares the two dependency graphs** before overwriting
  `plan.json`, then **consumes the snapshot**.

It is a one-shot token, never an archive, and it is deliberately not inferred
from the presence of `plan-review-*.json`: `lcars feedback` (the Verify
send-back) keeps every artifact, so a re-plan against a corrected PRD would
otherwise be diffed against the plan the captain had just rejected.

Edges the revision ADDED are refused when no objection names either end — the
SOURCE ticket (named anywhere in an objection) or the TARGET ticket (an
objection's own `ticketId`, since "every row ticket must depend on t-004" asks
for inbound edges without naming the rows). The rejection names each edge, is
threaded into the next worker's prompt, and the retry rides the Plan Stage's
existing `MAX_WORKER_TRIES` budget — no new stage, no new label, no new gate.

**It never kills a plan.** When the check cannot be trusted — no snapshot, an
unreadable plan, a renumbered or resized ticket set, an objection that names no
ticket in the plan, or the check itself crashing — it prints `⚠ REVISION
UNCHECKED`, says why, and passes the plan through. And on the worker's LAST
attempt the guard is advisory: a plan that passes `validate_plan_json` is saved
with an `⚠ OVER-CORRECTION UNRESOLVED` note and handed to Plan Review, which has
its own rounds and its own escalation, rather than deadlocking the Stage.
Removed edges are reported and never bounced on.

This exists because one objection asking for a single edge (`t-010` →
`t-012`) came back as a 14-ticket single-file chain and 14 waves of one ticket
each. It cannot catch over-correction on a FIRST plan (nothing to diff), and a
planner that renumbers its tickets defeats the comparison — both are stated in
the code and both are Plan Review's judgement to make.

## The Plan Review stage

Runs when `state.json.stage` is `plan-review` and `awaitingHuman` is not `true`
(see Dispatch). **Do not review the tickets yourself.** Run the driver: it spawns
one **fresh reviewer** worker fed **only** `plan.json` — never `prd.md` or
`validated-plan.md`. That independence is the whole point (vision.md → *Plan
Review*): the session that planned the work must not also grade it, so leaking
the spec in is structurally prevented — the driver simply doesn't put it on the
worker's path list. The worker audits every ticket (vertical slice, <300 LoC,
testable, deps in-plan) and emits a verdict; the driver branches on it.

```bash
bash ~/.claude/skills/lcars-run/run.sh plan-review --mission <id>
```

| Driver output | Meaning | What you do |
|---|---|---|
| `PLAN-REVIEW: passed` … `⊘ isolated` | Every ticket cleared review. `approved-plan.json` written; advanced to `schedule`. | Report it is at **Schedule**. |
| `PLAN-REVIEW: revise — round N` | The verdict failed (rounds 1–2). Objections logged to `plan-review-<round>.json`; looped back to `plan`. | Surface the objections; the next `run.sh drive --mission <id>` re-runs **Plan**, whose worker reads the objections and revises. |
| `PLAN-REVIEW: escalated` | The 3rd failed round. The driver wrote the unresolved objections to `pending.json`, set the awaiting-human gate, and kept the card in Plan Review. | Surface them; the captain overrides (proceed) or redirects via `respond.sh answer --mission <id> --answer "…"`. **Stop.** |

`planReviewRound` persists across the loop, so the third failure escalates rather
than looping forever. **An answered escalation RESETS it** (S180): the captain's
answer is information the reviewer has never seen, so it buys a fresh three
rounds — bounded by `planReviewEscalations`, which caps how many times that may
happen (3) so the loop still cannot run forever. A `passed:false` verdict with no issues is malformed — the
driver re-dispatches the reviewer and ultimately stops rather than moving on a
verdict that names nothing.

## The Schedule stage

Runs when `state.json.stage` is `schedule`. **This Stage is purely mechanical —
there is no LLM work to do.** The dependency graph, the wave grouping, and the
GitHub sub-issue creation are all deterministic, so you do **not** spawn agents
or reason over the plan: you just run the one subcommand and report what it did.

### STEP 1 — Run the schedule subcommand

```bash
bash ~/.claude/skills/lcars-run/run.sh schedule --mission <id>
```

`schedule` reads `approved-plan.json` (the ticket list Plan Review approved) and:

1. **Builds the dependency graph** from each ticket's `dependencies` array.
2. **Groups the tickets into sequential waves** by topological order — wave 1 is
   every ticket with no dependencies; wave *N* is every remaining ticket whose
   dependencies all sit in earlier waves (see CONTEXT.md → *Wave*). Tickets in a
   wave are mutually independent and so implementable in parallel.
3. **Isolates every infrastructure-establishing ticket** into a wave of its own.
   Such a ticket rides ALONE in its wave, and every ticket after it in plan order
   lands in a LATER wave, so later tickets build AGAINST the shared build/test
   infrastructure instead of beside it. Siblings in a wave are blind to each
   other: a docs ticket that authored a test against a base with no Vite config
   once had that test permanently broken by its own wave-mate's `vite.config.ts`,
   and eleven tickets built on top before anything noticed.

   The classification is **DECLARED, not guessed**: the Plan worker sets
   `establishesSharedInfrastructure` on each ticket (`stages/plan.md`) and Plan
   Review audits it (`stages/plan-review.md`). Schedule OBEYS the flag — `true`
   isolates, `false` never does, and no prose is inspected. **This is the
   mechanism.**

   Only when the field is ABSENT (an older plan, a mission already in flight)
   does a narrow **backstop** read the ticket's title, description, acceptance
   criteria and rationale. It has exactly ONE signal: a build/test **config
   filename** named on a line that also carries a create/change verb, ignoring
   negations, "existing"/"already" framing, and documentation references.
   **What it does NOT catch: any infrastructure ticket that never names a config
   file** — "Create the Django project and its settings module", "Stand up the
   test runner", "Add the GitHub Actions job that runs the unit tests",
   "Migrate the existing Jest suites onto Vitest" are all missed, deliberately.
   An earlier version also matched infrastructure phrasing; measured against a
   reworded corpus its recall fell from 14/14 to 5/14, and it scored 13/23 on
   unseen tickets while misfiring on ordinary work — so the phrase matching was
   deleted rather than widened. `tests/wave-isolation.test.sh` encodes those
   misses as explicit KNOWN-MISS assertions, including the phrasing coin-flip:
   the ground-truth scaffold ticket written as "Create the project scaffold —
   package.json, vite.config.ts and tsconfig.json" is isolated, while the same
   ticket written as "Create the app entry and wire the dev/build/test scripts"
   is not.

   **The one residual false positive: a repo whose subject matter IS build
   configuration.** The backstop cannot distinguish "this ticket changes
   `vite.config`" from "this ticket adds a feature that reads `vite.config`", so
   a dependency scanner, a language server, a CI dashboard or a template gallery
   will see tickets like "Add Gemfile support to the audit tool" or "Add the
   .csproj upload endpoint" inferred as infrastructure. LCARS itself is such a
   repo. Declaring the field removes the class completely — the text is then
   never read — and while undeclared the cost is **wall-clock only**: extra
   one-ticket waves, never wrong code. Always declare the field.

   **Provenance is always in the readout** — how many tickets declared the flag,
   how many were read from text, and a plain warning when NOTHING was declared,
   so you can tell "the planner decided" from "the harness guessed". A `false`
   that contradicts a config-file match is honoured (the plan's call wins) and
   reported in one line. `plan-save` raises the same warning earlier, where Plan
   Review can still act on it.

   Dependencies always win. A ticket never lands before one of its declared
   dependencies. When an infra ticket depends on a ticket ordered AFTER it, only
   that ticket's OWN unplaced dependencies are allowed past its barrier. Two
   such infra tickets can still force a third ticket ahead of the second
   barrier — the plan cannot satisfy both — and when that happens the reason
   string says so explicitly instead of calling it a dependency. Every
   "which it depends on" clause is checked against the dependency graph.
4. **Creates one GitHub sub-issue per ticket**, titled with the ticket title and
   bodied with its description plus an **Acceptance Criteria** list, labelled
   `lcars:implement,lcars:<type>` (the Mission's type — `feature`/`bug`).
5. **Writes `waves.json`** — an array of `{ wave, tickets:[ { id, issue } ] }`,
   each ticket carrying the number of the sub-issue just opened for it. An
   isolated wave also carries an additive `"reason"` string; a wave that was not
   isolated has no `reason` key at all.
6. **Advances** the stage to `implement` and moves the Mission's own issue label
   `lcars:schedule` → `lcars:implement`.

On success it prints:

```
SCHEDULE: advanced
  Grouped 4 ticket(s) into 2 wave(s); opened 4 sub-issue(s).
  Wave shape: 2 waves, up to 3 ticket(s) in parallel.
  Wrote waves.json.
  Stage:  implement
```

The **wave shape** line (S178) accompanies the count whenever the shape is
actually known — it is deliberately omitted, rather than guessed, when the wave
map could not be read. The wave COUNT alone does not say whether the plan can be
worked in parallel; the shape does, and a plan whose graph collapsed into a queue
says so in as many words:

```
  Wave shape: 14 waves, 1 ticket each — NO parallelism. CAUSE: the plan declares a dependency queue — all 14 tickets form a single chain, each one depending on the ticket before it. If that chain is not genuinely true, this run is as slow as it can possibly be.
```

On the serial branch it also NAMES ITS CAUSE (S181), because the two mechanisms
that serialise a plan need different repairs: `CAUSE: infrastructure isolation`
when every wave was an `establishesSharedInfrastructure` barrier, `CAUSE: the
plan declares a dependency queue` when the declared graph is one chain. When BOTH
are present it names both and says outright that repairing one alone will not
widen the plan (clearing every flag leaves the chain, and the chain alone still
gives one ticket per wave). The infrastructure remedy is worded off what was
measured: a DECLARED flag is repaired in the declaration, an INFERRED one has no
flag to clear and is repaired in the ticket text. When neither mechanism is
measurable it names NO cause and says the shape could not be attributed — a cause
is never inferred from the shape alone.

The same signal rides the board card, under the `WAVE x/y · TICKET n/m` strip,
and a compacted form rides `lcars run`'s per-Stage line and `events.jsonl`.

…and, when a wave was isolated, names it and why — stating whether the ticket
DECLARED the flag or the backstop inferred it:

```
SCHEDULE: advanced
  Grouped 12 ticket(s) into 8 wave(s); opened 12 sub-issue(s).
  Wave shape: 8 waves, up to 3 ticket(s) in parallel.
  Isolated 1 infrastructure ticket into a wave of its own:
    wave 1 — t-001 declares establishesSharedInfrastructure: true — isolated into a wave of its own so later tickets build against it
  Wrote waves.json.
  Stage:  implement
```

When the flag was absent, the same line reads as the inference it is, and names
the config file it matched:

```
    wave 1 — t-001 has no establishesSharedInfrastructure flag; the harness INFERRED shared build/test infrastructure because its text changes a shared config file (vite.config) — isolated into a wave of its own so later tickets build against it
```

The provenance line is printed on EVERY run, including a plan with no
infrastructure at all:

```
  Infrastructure: all 4 ticket(s) declared establishesSharedInfrastructure (1 true, 3 false).
  ⚠ NO ticket declared establishesSharedInfrastructure — the harness fell back to reading ticket text, which only catches a ticket that NAMES a build/test config file. …
  t-001 declares establishesSharedInfrastructure: false, overriding a config-file match (package.json) — the plan's call wins, so it shares its wave.
```

### STEP 2 — Circular dependencies stop the Stage

If the tickets form a dependency cycle, no wave can be built. `schedule` names
the stuck tickets and **changes nothing** — no `waves.json`, no sub-issues, no
stage move:

```
lcars run: circular dependency detected among the remaining tickets: t-002 t-003
```

The approved plan should never contain a cycle (`plan-save` already rejects
dangling dependency refs, and a clean plan is acyclic), so treat this as a
planning bug: surface the cycle to the captain. It cannot be resolved by
re-running Schedule — the plan itself has to change.

### STEP 3 — Report

Tell the captain how many waves the Mission was scheduled into, where the wave
graph lives (`waves.json`), that one sub-issue was opened per ticket, and that
the Mission is now at **Implement**.

## The Implement stage

Runs when `state.json.stage` is `implement` and `awaitingHuman` is not `true`.
The Mission's `waves.json` (from Schedule) is the work plan: **process the waves
in order, and within a wave build the tickets in parallel.** S133: each ticket is
built by **ONE unified TDD worker** (it writes the tests AND the code, in-tree at
the repo's own convention), and the harness **proves the work afterwards** with
deterministic gates — the parent commit is the snapshot.

**The driver composes this whole loop for you.** Both auto mode and `--step` run
the Implement Stage by spawning one subcommand —
`run.sh implement --mission <id>` — which sequences STEPs 1–4 below (find the
wave → build each pending ticket → advance to Verify, or stop at the
awaiting-human gate if a ticket flags). The STEP-by-STEP breakdown that follows
is the **reference** for what that subcommand composes; you do not normally run
the `impl-*` subcommands by hand. The script owns every mechanical, testable
handoff.

### STEP 1 — Find the current wave

Ask the script which wave to build and which of its tickets still need work:

```bash
bash ~/.claude/skills/lcars-run/run.sh impl-status --mission <id>
```

`impl-status` prints the **lowest-numbered wave that still has an unfinished
ticket** and lists that wave's pending ticket ids — it will **not** reveal a
later wave while an earlier one has open work, which is exactly the
sequential-wave rule. Two outcomes:

| Output | Meaning | What you do next |
|---|---|---|
| `IMPLEMENT: wave N active` | Wave N is the current wave; the line lists its pending tickets. | Build **every** listed ticket (STEP 2), then loop back to STEP 1. |
| `IMPLEMENT: complete` | Every ticket in every wave is green. | Go to STEP 4 — advance to Verify. |

### STEP 2 — Build each pending ticket (the unified TDD worker + proof gates)

For each pending ticket the current wave lists, run the **implement-ticket**
driver. **Do not write tests or implement anything yourself** — the driver
spawns ONE cold **unified TDD worker** (fed the ticket from
`approved-plan.json`): it writes failing tests AND the code that satisfies them,
in any order, authored **in-tree at the repo's own test convention**, iterating
freely (its `attempts` count — the worker's OWN internal iteration count — is
honest and uncapped; it gates nothing and is forensic only, so no captain-facing
surface quotes it), and reports `result.json` v2 (`{ ticketId, passed, attempts,
summary, newTests[], testEdits[], flipFlop }`). On the wire that number rides
event data as **`iterations`**; the count the captain is shown is **`sessions`**
— how many times LCARS had to hire a fresh worker.

```bash
bash ~/.claude/skills/lcars-run/run.sh implement-ticket --mission <id> --ticket <ticket-id>
```

**The harness then PROVES the work with deterministic gates** — the parent
commit is the snapshot; a worker rewarded for a green suite cannot talk its way
around them (see vision.md → *Implement*):

- **result v2 validation** — the shape above, rejected legibly when malformed.
- **Declared edits** — every test-classified path in the diff vs the parent
  (adds, edits, deletions, renames) must be declared (`newTests` ∪
  `testEdits[].path`, each edit with a reason); an undeclared test edit voids
  the session. Verified declarations land in `tickets/<id>/test-edits.json`.
- **Quality floor** — ≥1 new/changed asserting test, unless the result declares
  `flipFlop: "not-applicable"` with a reason.
- **Flip-flop** — the ticket's tests must be **GREEN on the tip** and **RED on
  the parent commit** (a scratch worktree at the parent sha). A test file that is
  NEW at the parent is staged into it; one that ALREADY EXISTED there runs the
  **parent's own committed copy**, so an honest REPAIR of a test that was already
  broken is provable, while weakening a test that passed on the parent still
  fails (S157). On the repair path one source-blind check applies: the
  RUNNER must not execute fewer tests on the tip than on the parent (tests that
  actually ran, and only when one runner parsed both legs). It is vacuous when
  the parent's copy was dead at import — it executed nothing — so Verify lists
  every repaired file for the human rather than the harness claiming the edit was
  honest. A diff touching ANY non-test path stages every file, as before, and says
  which path did it. Zero-collected legs are INCONCLUSIVE, never a pass. Verdict, both legs'
  runner tails, and the per-file source provenance (`parentLeg`) land in
  `tickets/<id>/flip-flop.json`.

  A non-zero TIP command is RED only when its failing invocation reports
  executed tests or runner-reported failed-test evidence (including Go's
  `--- FAIL: Test…`, quiet pytest's failed-test identifier plus nonzero failure
  summary, and Node dot's failed-test record with a test callback stack).
  Node TAP's `ERR_TEST_FAILURE` file-process wrappers alone do not prove test
  methods ran: boot-only failures are INCONCLUSIVE for both TAP and dot.
  Assertion text alone, including text in a passing doctest, is not failure
  evidence. Zero or unreadable execution evidence without failed-test evidence is
  INCONCLUSIVE, with the command recorded in the reason.
  An unreadable GREEN parent likewise cannot justify FAIL by claiming the
  ticket's tests passed there.
  For file scopes, direct `python -m unittest discover -s "$LCARS_TESTS_DIR"`
  commands receive the file's directory as the start directory and its basename
  as the discovery pattern. Directory-scoped commands are unchanged.
  Declared files must **take part**: produce executed tests, or have a function,
  method, or class defined there called during tests in a passing, positive
  file-scoped Python invocation. `sys.monitoring` observes direct
  `python -m unittest` and `python -m pytest` commands, including dynamically
  resolved calls; merely loading a module or executing its import-time body
  earns no credit. No source import scan or
  worker-declared helper exemption is used. A zero-test invocation supplies no
  call credit. For ancestor-directory scopes, positive file-scoped probes
  must agree with calls observed in the actual leg. Runtime participation appears
  as `path=called` in `declaredRan.each`. The independent inert-source exclusion
  is retained: inert Python source plus direct unittest loading that confirms
  zero tests appears in `declaredRan.excluded`. Plain module-name assignments
  of literal strings, numbers (including signed numbers), booleans, `None`,
  and recursively literal tuples/lists/dicts/sets are also inert. Calls,
  imports, comprehensions, classes, annotations, attribute/unpacking targets,
  and assignments to `load_tests` or dunder names cannot use this exclusion.
  The post-commit Python gate applies the same accounting.
  A declared file with neither executed tests nor observed participation stays
  INCONCLUSIVE. Wrappers, compound shell commands, isolated Python processes,
  and other runtimes have no call observer and retain count/ablation
  accounting; inability to observe is not permission to accept zero.

  **What a leg is scoped to, and the clock it runs under** (S308), both recorded
  in that file's `gate` block. The scope is the ticket's DECLARED test file; for
  several files it is their common ancestor DIRECTORY only when that directory
  holds no test the ticket did not declare — otherwise the leg runs the declared
  files one at a time. (A flat `tests/` layout makes that ancestor the whole
  suite: on one real repo a two-file ticket ran all 1255 tests, was terminated at
  the timeout, and scored INCONCLUSIVE five times.) A leg that cannot be narrowed
  at all says so by name — `proof_scope_full_suite_fallback` — instead of quietly
  running everything. And a scope the repo's own testCommand **cannot select**
  (the very common `$(find "$LCARS_TESTS_DIR" -name "*.test.js")` matches nothing
  for a declared `…_spec.js`, so the runner gets an empty argument list and
  discovers its own tests) refuses the leg before it runs: INCONCLUSIVE, named
  `proof_scope_selected_nothing`, with `gate.scopeSelectedNothing` recorded —
  never a confident verdict about tests that never took part.

  **The scope is PROVEN to have narrowed the run, not asserted.** LCARS does not
  know how a repo's testCommand turns `$LCARS_TESTS_DIR` into a file list, and a
  selection written in backticks, piped through `grep`, or spelled as a bare glob
  all hand the runner an empty argument list and let it discover its own tests.
  So the question is settled by EXPERIMENT: one **control run** per gate re-runs
  the repo's own testCommand with the scope pointed at an EMPTY directory. If any
  invocation of the leg executed the same number of tests under the same runner
  as that control, the scope selected nothing and the verdict is INCONCLUSIVE
  (`proof_scope_not_narrowed`). The comparison is made **per invocation**, where
  each count was produced — a declared-files leg runs once per file, and
  comparing only the SUM let a ticket pass while one of its two declared tests
  was red and never executed.

  The control is the FULL-SUITE-shaped run (an empty scope is what makes a
  command fall back to discovery), so it is budgeted against the repo's own
  recorded `gateTimeout` — or 120s — rather than a one-off narrow
  `LCARS_GATE_TIMEOUT`. Unittest controls use an empty importable package under
  the runner's working directory so `-t "$PWD"` remains valid. An unreadable
  control records its actual exit and runner diagnostic; a timeout names the
  gate-chosen budget, not a supposed repository defect or selection failure.
  A narrowing the gate cannot establish is **not** a
  licence to decide: `scopeControl.narrowing` records which it was — `proven`,
  `moot` (every tracked test file in the tree is one the ticket declared, so
  discovery could only run the ticket's own tests), `not-narrowed`,
  `uncountable` (this runner prints no test count), or `unproven` — and an
  `unproven` leg is INCONCLUSIVE with the reason naming why
  (`proof_scope_narrowing_unproven`), never a confident PASS or FAIL.

  **Zero executed is never evidence, on EITHER leg.** A run that exits green
  while its own runner reports executing zero tests is INCONCLUSIVE
  (`proof_leg_zero_executed`) — on the tip because a green on nothing is not a
  pass, and on the parent because "the ticket's tests pass on the parent commit"
  would describe a run that never happened. Zero on a **red** leg is untouched:
  that is the flagship legitimate red, the greenfield parent whose copy of the
  test dies at import because the module the ticket adds is not there yet.

  The timeout is resolved PER LEG as `LCARS_GATE_TIMEOUT` >
  `gateTimeout` in `.git/lcars/config.json` > 120s, so a repo can record what its
  suite really needs and a drive resumed by `lcars respond` cannot lose it. An
  unusable `gateTimeout` is **never discarded in silence**: a quoted or
  whitespace-padded integer (`"30"`, `"  12  "` — plausible, since every other
  value in that file is quoted) is honoured and the coercion is said out loud;
  anything else (`abc`, `-5`, `0`, `7.5`, `true`) falls back to 120s with one
  line naming the offending value; and a value above **3600s** is capped, because
  a bound longer than an hour stops protecting against the never-settling suite
  the gate exists to catch. What was wrong and what was used instead is recorded
  as `gate.timeoutNote`.

On a full pass the driver commits the ticket (tests + code in one commit),
re-verifies against the committed state (post-commit gate), and prints
`⊘ isolated — implement(<id>)`.

The post-commit gate and ticket-suite retests reuse the flip-flop gate's command
adapter: a Python `unittest discover` file scope becomes its directory plus a
basename pattern; directory-scoped commands stay byte-identical. At post-commit,
zero collection or an unimportable discovery start directory is a
**could not run the tests** error, never evidence that the implementation is
missing (rc 6). A real failing test keeps the existing missing-implementation
verdict.

**A gate rejection bounces, it does not die**: the verdict + runner tail is
written to `tickets/<id>/gate-signal.txt` and a FRESH worker is spawned carrying
that signal, up to `LCARS_WORKER_TRIES` (default 3) total sessions. Exhaustion
**parks the Mission awaiting-human** with the last gate verdict quoted — the
ticket then needs `respond.sh answer --mission <id> --answer "…"`; do not re-run it
until answered.

Run `implement-ticket` for **every** pending ticket the current wave lists (they
are independent within the wave), then loop back to STEP 1, which reveals the
next wave only once this one is fully green.

### STEP 3 — Finish the wave before the next

`impl-status` enforces this for you: it never surfaces wave N+1 while wave N has
a pending ticket. So the loop is simply: STEP 1 → build the wave (STEP 2) →
STEP 1 again, until `impl-status` reports `complete`.

### STEP 4 — Advance to Verify

When `impl-status` reports `complete`, advance the Mission:

```bash
bash ~/.claude/skills/lcars-run/run.sh impl-advance --mission <id>
```

`impl-advance` re-checks that **every** ticket in **every** wave has a passing
result, then sets the stage to `verify` and moves the label `lcars:implement` →
`lcars:verify`. If any ticket is still unfinished (or flagged), it refuses and
names the first blocker — a half-built Mission can never slip into Verify.

### STEP 5 — Report

Tell the captain that every ticket passed across all waves, where the per-ticket
tests and results live (`tickets/<id>/tests/`, `tickets/<id>/result.json`), and
that the Mission is now at **Verify** — or, if a ticket flagged the human, which
ticket failed and how to resolve it (`respond.sh answer --mission <id> --answer "…"`).

## The Verify stage

Runs when `state.json.stage` is `verify`. Implement parks the Mission here once
every ticket is green across every wave. **This Stage is a human gate** — the
captain reads the diff, runs the app, and decides whether to ship. You print the
summary and stop; you do **not** advance the Mission yourself.

The driver's automatic PR-open step (`open-pr`, also used by `drive`) exits
non-zero if it cannot open a PR, keeping the Mission at `verify` with no new
review/Done state. A degraded-open notification fires only once across retries.
When this repo has no `origin` remote, connect an **existing hosted repo** first:
`git remote add origin <repository-url>` (a manual remedy, never run automatically).
Then retry. The current Git configuration decides this, not an old
`baseFreshness.reason`; with an origin configured, the normal push/auth/gh
failure advice still applies.

### STEP 1 — Print the pre-ship summary

```bash
bash ~/.claude/skills/lcars-run/run.sh verify-summary --mission <id>
```

`verify-summary` is read-only. It prints the mission title, every completed
ticket with its result (✓ + how many WORKER SESSIONS it took, counted from the
mission's `ticket_attempt` events — a ticket that landed on its first hire says
nothing at all), the overall test tally (e.g. `4/4 ticket(s) green
across 2 wave(s)`), and the two next moves:

```
VERIFY: <title>
  All tickets completed:
    ✓ t-001 — green
    ✓ t-002 — green after 2 worker sessions
    …
  Test results: 4/4 ticket(s) green across 2 wave(s).
  Review the changes and run the app if needed.
    lcars approve <id>    — create the PR
    lcars feedback <id>   — send back with feedback
```

### STEP 2 — Hand the decision to the captain

Surface that summary and stop. The captain drives the outcome with a separate
skill — neither is part of `lcars run`:

- **`lcars approve <id>`** (the `lcars-approve` skill) — ship it: open the PR,
  mark the Mission `done`.
- **`lcars feedback <id> "<feedback>"`** (the `lcars-feedback` skill) — send it
  back: append the note to `feedback.md` and reset the Mission to `align`.

Do not call `verify-summary` again on a loop and do not try to advance the
Mission — Verify only moves when the captain approves or sends feedback.

## Notifications — the walk-away ping

When the driver halts at a **human gate** — `awaitingHuman === true` **or**
`stage === "verify"` — it fires the notify hook **once**, with the mission id,
the gate type, and a **one-line, decision-ready summary** (what it's asking and
what each answer does). A whole Stage's questions are batched into that single
notification — never one ping per question. The hook fires **only** at those two
gates; a clean Stage-to-Stage transition, an error, an `align` re-entry, and a
`done` Mission never ping.

Delivery is layered and local-first, handled by the bundled `notify.sh`:

- **Always** — a terminal bell + a one-line banner (and, on macOS, a desktop
  notification). Zero config.
- **Opt-in phone push** — set an ntfy topic (`LCARS_NTFY_TOPIC`, or
  `notifyNtfyTopic` in `.git/lcars/config.json`; optional `LCARS_NTFY_SERVER`)
  or Pushover credentials (`LCARS_PUSHOVER_TOKEN` + `LCARS_PUSHOVER_USER`, or the
  `notifyPushover{Token,User}` config keys).

The hook is `$LCARS_NOTIFY` (defaults to the bundled `notify.sh`), env-injectable
like `$LCARS_GH_BIN` so the test suite asserts the call without sending anything,
and the push uses `$LCARS_CURL_BIN` so the network call is stubbable too. The
driver fires it; you just relay the summary the driver printed.

## The Align re-entry (after feedback)

When `lcars feedback` bounces a Mission back, it resets the stage to `align`,
writes `feedback.md`, and **keeps every prior artifact** (PRD, research,
validated/approved plans). So an `align` Mission falls into one of two cases,
and the dispatch tells them apart by whether `feedback.md` exists:

- **No `feedback.md`** → a freshly filed Mission. Run **Research** as usual (the
  `research` driver).
- **`feedback.md` present** → a re-entry from Verify. The re-grill is
  **interactive**, so it stays on the host CLI (your session), not a cold worker:
  read `prd.md` *and* the full `feedback.md` (every stamped note, in order) plus
  any other artifacts you need, re-grill the same way `lcars file` did, and
  **rewrite `prd.md`** to fold in the captain's feedback. Once the PRD reflects
  the feedback, carry on into the **Research stage** in the same run — run the
  `research` driver, which reads the now-updated `prd.md`. Leave `feedback.md` in
  place as the durable history; it accumulates across rounds, and the `research`
  driver does not treat its presence as a blocker (the re-grill already ran).

This is what makes the Verify → Align loop pick up with the full context instead
of starting cold.

**Rewriting `prd.md` is not enough on its own — run the `research` driver.**
Reaching Research is what tells LCARS the re-grill has finished, and that is one
of the **two** moments the GitHub issue body is rebuilt from the current PRD (the
other is Verify entry). Skip it and the issue keeps the OLD spec, so anyone
picking the Mission up from GitHub — a reviewer, or another machine — builds the
thing the captain just sent back. Bodies in between those two points are stale by
design; see the header of `skills/lcars-run/issue-body.sh`.

## One source of truth: stage and label always agree

A Mission's position is stored in two places — `state.json.stage` on disk and
the GitHub label (which is what the kanban board reads). **They always hold the
same value**, so there is one unambiguous answer to "where is this Mission?" —
the Stage `lcars run` will execute next:

- A freshly filed Mission sits at **`align`** (Align already happened during
  `lcars file`). `lcars run` treats `align` as the signal to run **Research**.
- When Research finishes, both move to **`validate`** together — the card lands
  in the Validate column, and the next `lcars run` will run Validate.
- When Validate finishes, both move to **`plan`** together. While Validate is
  paused on a scope question, the stage stays `validate` and the additive
  `lcars:awaiting-human` label overlays it — the card stays in the Validate
  column, flagged as awaiting input, until the captain answers.
- When Plan finishes, both move to **`plan-review`** together — the card lands
  in the Plan Review column, ready for the Plan Review stage.
- When Plan Review passes, both move to **`schedule`** together. When it fails,
  both loop back to **`plan`** together so the card returns to the Plan column
  for revision; after three failed rounds the stage stays `plan-review` and the
  additive `lcars:awaiting-human` label overlays it — the card stays in the Plan
  Review column, flagged as awaiting input, until the captain answers.
- When Schedule finishes, both move to **`implement`** together — the card lands
  in the Implement column. The per-ticket sub-issues Schedule opens are *new*
  GitHub issues, each created already at `lcars:implement`; the Mission's own
  issue label is what moves `lcars:schedule` → `lcars:implement`.
- When Implement finishes (every ticket green across every wave), both move to
  **`verify`** together — the card lands in the Verify column. While a ticket is
  flagged for the human (it exhausted its 3 worker sessions), the stage stays
  `implement` and the additive `lcars:awaiting-human` label overlays it — the
  card stays in the Implement column, flagged as awaiting input, until the
  captain resolves it.
- At **`verify`** the Mission waits on the captain. `lcars run` only prints the
  summary; the move out of Verify is the captain's: **`lcars approve`** advances
  both stage and label to **`done`** (the card lands in the Done column once the
  PR is open), while **`lcars feedback`** resets both back to **`align`** and
  drops a `feedback.md` so the card returns to the Align column for a re-grill
  with the full prior history.

GitHub labels are the board's source of truth; `.git/lcars/` is the run-time
store. Keeping them in lockstep is what lets you call `lcars run` repeatedly and
trust the board to show exactly where every Mission is.

## What gets written

```
.git/lcars/missions/<id>/
  research/
    1.json, 2.json, …   ← one stateless agent's findings per file (Research)
  validated-plan.md     ← the Validator's synthesis: Synthesis + Decisions + Rationale (Validate → Plan)
  plan.json             ← the Planner's ticket list, each ticket carrying its rationale (Plan → Plan Review)
  approved-plan.json    ← copy of plan.json once Plan Review passes (→ Schedule)
  plan-review-<n>.json  ← the reviewer's verdict for failed round n (Plan Review)
  plan-under-review.json ← S178 one-shot revision token: the plan the reviewer reviewed. Written by review_fail on a loop-back, consumed by plan-save when the revision lands.
  waves.json            ← the wave graph: [ { wave, tickets:[ { id, issue } ] } ] (Schedule → Implement)
                          an ISOLATED wave also carries "reason" (additive; absent otherwise)
  tickets/
    <ticket-id>/
      result.json         ← v2: { ticketId, passed, attempts, summary, newTests, testEdits, flipFlop } (Implement)
      flip-flop.json      ← the flip-flop gate's verdict + both legs' rc/tails (Implement)
      test-edits.json     ← the verified declared test edits [{path, reason}] (Implement)
      proof-tests.sha256  ← proof-time hashes of the ticket's tests (the drift baseline)
      gate-signal.txt     ← the last gate rejection fed to the next session (bounce loop)
  pending.json          ← scope/objection/flagged-ticket questions, while paused at the human gate only
  feedback.md           ← the captain's Verify feedback, accumulated (written by `lcars feedback`; read by the Align re-entry)
  state.json            ← stage pointer + branch/base; baseFreshness (refreshed each drive); + planReviewRound, awaitingHuman/pendingQuestion while paused
```

All LCARS state stays inside `.git/`. Implement writes to the git history proper
in exactly one place: each green ticket's produced files are committed to
`lcars/<id>`, never to the base branch. The **only** other refs a drive moves are
the base branch and `lcars/<id>` itself, and only as the base-freshness re-check
below describes — fast-forwards of a clean tree, never anything else.

## Notes & failure modes

- **Headless Stages are cold workers — never do their reasoning inline.** For
  Research / Validate / Plan / Plan Review / Implement you run the driver and
  report; the LLM thinking happens in a subprocess worker whose prompt `run.sh`
  builds from artifact *paths* alone. If a driver prints `⚠ NOT ISOLATED` it
  found no worker binary — set `$LCARS_WORKER_BIN` (e.g. `claude`); do **not**
  substitute your own session for the worker.
- **Wrong stage for the Stage** → `run.sh` exits non-zero and changes nothing.
  Research only runs on an `align` mission; Validate only on a `validate` one;
  Plan only on a `plan` one; Plan Review only on a `plan-review` one; Schedule
  only on a `schedule` one; Implement only on an `implement` one.
- **No GitHub issue on file** (`githubIssue: null`) → the stage still advances;
  the relabel is skipped with a warning telling you to do it by hand.
- **`gh` missing / edit fails** → same: the local stage advances; you get a
  warning with the exact `gh` relabel to run later.
- **Research workers stay stateless — by construction.** The driver hands each
  research worker only its single question; it never puts `prd.md` or a sibling
  finding on the worker's path list. Synthesis against the PRD is the Validate
  worker's job.
- **Validate escalates scope, not implementation.** Only a finding that changes
  *what* gets built belongs in a scope question; the Validator worker decides
  everything else and records it under `## Decisions` (with its `## Rationale`).
  Over-escalating turns the walk-away gate into a chat.
- **A paused Validate must not re-run on its own.** When `awaitingHuman` is
  `true`, the `validate` driver refuses — wait for `lcars respond`. A fresh
  Validator worker only runs once the answer is recorded and the gate is cleared.
- **Decisions/rationale are required, not optional.** `validate-advance` refuses
  a `validated-plan.md` with no `## Rationale`, and `plan-save` refuses any
  ticket missing its `rationale` field — the artifact is the only thing crossing
  the Stage boundary, so it must carry the *why* (vision.md → *Stage Isolation*).
  The driver re-dispatches the worker and ultimately stops; it never advances on
  an artifact that drops its reasoning.
- **Malformed worker output stops the Stage, after retries.** Any worker artifact
  that fails its persistence validator is re-dispatched up to a few attempts;
  if it never validates the driver stops the Stage and changes nothing — no
  silent advance.
- **Every Plan ticket is a vertical slice under 300 LoC.** That sizing keeps
  each ticket inside an implementer LLM's window — the Planner worker must not
  emit horizontal, layer-only tickets or ones that blow past the limit.
- **The Plan Review reviewer is independent by construction.** The driver puts
  only `plan.json` on the reviewer worker's path list — never `prd.md` or
  `validated-plan.md` — so the session that planned the work cannot also grade it
  (vision.md → *Plan Review*), the same way a research worker never sees the PRD.
- **A failed verdict must name its objections.** `review-save` refuses a
  `passed:false` verdict with an empty `issues` list and changes nothing — a
  failing review has to say *what* failed so Plan can revise.
- **Plan Review escalates after three rounds, it does not loop forever.**
  `planReviewRound` persists across the loop-back to Plan; the third failure
  parks the card at the awaiting-human gate (stage stays `plan-review`) for the
  captain to override or redirect, rather than bouncing Plan again.
- **Schedule is mechanical — don't reason over it.** The wave grouping, the
  infrastructure-ticket isolation, and the sub-issue creation are all
  deterministic; never spawn an LLM at Schedule time to "decide" the waves or to
  classify a ticket as infrastructure. The infrastructure call is made UPSTREAM,
  by the Plan worker declaring `establishesSharedInfrastructure` and Plan Review
  auditing it. Just run `schedule` and report. A canonical `approved-plan.json` is
  acyclic (deps were validated at `plan-save`), so a reported cycle is a
  planning bug to surface, not something Schedule can retry away.
- **Schedule degrades gracefully without gh.** If `gh` is missing or a create
  fails, the waves are still grouped and `waves.json` is still written (with
  `"issue": null` for the un-opened tickets) and the stage still advances; you
  get a warning to open the sub-issues by hand.
- **Implement's honesty is enforced by the harness, not by trust.** S133: the
  unified worker's work is proven post-hoc by deterministic gates in `run.sh`
  (see *The Implement stage* above): **result v2 validation**, the
  **declared-edits guard** (an undeclared test edit voids the session — a test
  may only change when the ticket declares it with a reason), the **quality
  floor**, and the **flip-flop gate** (green-on-tip + red-on-parent; test
  command from `testCommand`/`$LCARS_TEST_CMD`). A worker that games the
  contract trips one of these and the session bounces with the verdict — it
  never silently advances.
- **Implement processes waves strictly in order.** `impl-status` never reveals a
  later wave while an earlier one has an open ticket, and `impl-advance` refuses
  to reach Verify until *every* ticket in *every* wave is green — so a half-built
  Mission can't slip forward. Build all of the current wave before looping back.
- **A ticket flags the human at the session cap.** After `LCARS_WORKER_TRIES`
  (default 3) gate-rejected sessions, `implement-ticket` parks the Mission at
  the awaiting-human gate with the last gate verdict quoted (stage stays
  `implement`, `lcars:awaiting-human` overlays the card). Don't keep re-running
  a flagged ticket — wait for `lcars respond`.
- **Implement commits each green ticket to the Mission's branch.** The files
  the unified worker produces are committed to `lcars/<id>` (recorded
  by `lcars file`) the moment a ticket goes green, so the eventual PR has
  content. The commit is best-effort and jq-free: no branch on file, no file
  changes, or a git failure just leaves a warning — the saved result still
  stands. Don't hand-commit the Implementer's output elsewhere; let
  `impl-save-result` do it onto the branch.
- **Verify is a human gate — `lcars run` never advances it.** `verify-summary`
  is read-only; the Mission only leaves Verify when the captain runs
  `lcars approve` (→ `done`) or `lcars feedback` (→ `align`). Don't try to ship
  or bounce a Mission from inside `lcars run`.
- **An `align` Mission with a `feedback.md` is a re-entry, not a fresh file.**
  Re-run Align (re-grill against the PRD + feedback and rewrite `prd.md`) before
  Research; only a `feedback.md`-free `align` Mission goes straight to Research.

## Implementation

`run.sh` next to this file holds three layers. The **auto-advance driver**
(`drive`, with `--step`) is a thin, token-free loop: it reads `state.json`,
sequences the Stage drivers below, halts at a human gate, prints the
stage-by-stage summary, and fires the notify hook. It does **no** Stage
reasoning and **no** model work — it never becomes the one session that thinks
about every Stage. **Stage drivers** spawn the cold workers and persist their
output: `research`, `validate`, `plan`, `plan-review`, `implement` (the whole
wave loop), `implement-ticket` (one ticket). **Persistence subcommands** (which
the drivers reuse, and which the test suite drives directly) do the mechanical,
jq-free recording: `gate`, `save`, `validate-pause`, `validate-advance`,
`plan-save`, `review-save`, `schedule`, `impl-save-result`,
`impl-status`, `impl-advance`, `verify-summary`. Each headless Stage's worker
prompt is a template under `skills/lcars-run/stages/<role>.md`; `run.sh`
assembles the final prompt from the template plus the artifact *paths* and spawns
it via `$LCARS_WORKER_BIN` (default `claude`) with the Stage's restricted tool
set. The walk-away ping is the bundled `notify.sh` (`$LCARS_NOTIFY`), fired by
the driver only at a human gate.

The Verify gate's two outcomes are separate skills — `lcars-approve` and
`lcars-feedback` — each with its own script and test suite. Behaviour is covered
by `tests/lcars-run.test.sh` (run with `bash tests/run.sh`); its stage-isolation
section stubs `$LCARS_WORKER_BIN`, and its auto-advance section stubs both that
and `$LCARS_NOTIFY`, so the spawn/assemble/validate/persist/notify plumbing runs
token-free with no real pings. The skill source lives in `skills/lcars-run/` and
is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo copy, not
`~/.claude`. If you change `run.sh`, a stage template, or `notify.sh`, keep those
tests green.
