---
name: lcars-file
description: File a new LCARS Mission. Captures a free-form idea from the captain, runs an Align session to produce a PRD, then persists the mission under .git/lcars/missions/ and opens a labelled GitHub issue at the align stage. Use when the user runs `lcars file`, asks to start / file / open a new LCARS mission, feature, or bug.
---

# lcars file

`lcars file` is the **Entry Skill**: it turns a free-form human idea into a
filed Mission sitting at the **Align** stage, ready for `lcars run` to pick up.
You (Claude) run the conversation; the bundled `file.sh` does the mechanical
persistence so it stays testable.

Run `lcars init` first if `.git/lcars/` does not exist — `file.sh` will create
the `missions/` dir if needed, but a repo without the LCARS labels can't be
issue-labelled properly.

## STEP 1 — Capture

Ask the captain for a free-form description of the idea. One open prompt:

> What do you want to build or fix?

If it isn't obvious from their answer whether this is a **feature** or a
**bug**, ask. Don't over-interrogate here — capture is just intake; the real
sharpening happens in Align.

## STEP 2 — Align

**First, resolve the repo context source — once.** Before grilling, run the
shared resolver so Align reads the same durable repo facts every later Stage
will (architecture, conventions, how tests run, key interfaces / domain terms),
instead of re-deriving them from the tree each session:

```bash
ctx=$(bash ~/.claude/skills/lcars-run/run.sh context-source)
```

It prints ONE path and you read it:

- If a `CONTEXT.md` exists at the repo root, that is the source (no pack is
  generated).
- Otherwise it returns `.git/lcars/context-pack.md`, generating it lazily on
  first use via a single cold worker (and reusing it thereafter). The pack lives
  inside `.git/` — it never touches the working tree and is never committed.

Read `$ctx` and treat it as the ground truth for repo facts during Align. Where
this guide below says "the codebase or `CONTEXT.md`", it means `$ctx`.

Align is a **relentless, one-question-at-a-time interview** in the style of the
`grill-me` / `grill-with-docs` skills — not a fixed questionnaire, and **never a
batch of questions fired off at once**.

**The gate (non-skippable):** Align MUST conduct **at least one real
question→answer exchange with the captain before the PRD is written.** Producing
a PRD straight from the captured idea with **zero captain exchanges is a defect,
not an efficiency** — no matter how fully specified the idea looks or how
inferable the answers seem. The load-bearing decisions (defaults, limits, naming,
tie-breaks, rendering/UX behaviour, qualification rules, scope boundaries) must
be **surfaced to the captain for explicit confirmation** — lead-with-your-
recommendation, one at a time. The captain confirming or redirecting your
recommended decisions **IS** the alignment; it cannot be assumed on their behalf
or silently resolved into the PRD. Run it like this:

- **One question at a time.** Ask, then *wait* for the captain's answer before
  asking the next. Do **not** present a multi-question form or pick-list to be
  answered in one go — that short-circuits the whole point, which is to let each
  answer steer the next question.
- **A human gate is a HARD STOP with NO TIMEOUT. You must never assume on the
  human's behalf here, and you must wait for them to respond.** After you ask the
  captain a question, you **end your turn and wait for the captain's actual reply.** You do
  not continue, you do not proceed to the next step, and you do not answer the
  question yourself. **Silence, a pause, a delay, or the captain appearing to be
  away is NEVER an answer** — it is not delegation, not approval, not "go ahead,"
  and not permission to decide on their behalf. There is **no timeout**: wait as
  long as it takes, indefinitely. If you are uncertain whether the captain has
  actually answered, then they have **not** — keep waiting; only an explicit
  reply from the captain advances the gate. This applies to **every** question in
  the interview *and* to the final "is the PRD right?" confirmation: none of them
  may be self-resolved by assuming the captain delegated.
- **Walk the decision tree.** Every answer opens new branches and creates
  dependencies between decisions; resolve them one by one. *How sleep gets
  captured* changes *what the summary can show* — follow that thread rather than
  pre-scripting a list.
- **Always lead with your recommended answer.** Don't just interrogate —
  propose the answer you'd pick and why, so the captain can confirm or push
  back. This is what keeps a simple idea moving fast instead of stalling.
- **Explore instead of asking — but only for *factual* questions.** Exploring
  the codebase or `CONTEXT.md` substitutes ONLY for **factual** questions —
  things the repo can answer (how tests run, what an interface is, an existing
  convention). It **never** substitutes for a **decision** question: anything
  that turns on the captain's preference, product judgment, scope boundary,
  default value, limit, naming, or UX behaviour. Those must be put to the captain
  with your recommendation — they may **not** be silently resolved into the PRD
  or an ADR.
- **Sharpen fuzzy language.** When the captain uses a vague or overloaded term,
  propose a precise one. If `CONTEXT.md` defines it differently, surface the
  conflict immediately.

There is **no fixed number of questions** — let complexity set the depth. A
one-line bug ("the /about link 404s") may converge after a single exchange; a
broad feature may take many turns. Keep grilling until you and the captain share
a clear picture of what's being built *and what isn't*, then stop. Don't
manufacture ambiguity to pad the session, and don't cut it short while real
branches are still unresolved.

### Scale the PRD's depth to the Mission's complexity

The *same judgment* that sets the interview length sets the PRD's depth — it is
a JUDGMENT, not a rigid threshold. The required sections below are always
present, but **how much each carries scales with complexity**:

- **Trivial Mission** (a one-line bug, a copy tweak, a single obvious fix): keep
  the PRD THIN. A one-sentence Goal, one or two crisp acceptance criteria, a
  terse Out of Scope / Constraints. Do **not** over-specify small work — and
  write **no `adr.md`** (see below). Padding a trivial Mission wastes downstream
  comprehension budget.
- **Complex Mission** (a broad feature, a cross-cutting change, anything with
  real architectural choices): go DEEP. Spell out the acceptance criteria
  exhaustively, name every out-of-scope boundary, and enumerate the real
  Constraints — and additionally write an **engineering ADR set** (`adr.md`,
  below) capturing the high-level architectural decisions the engine has no
  out-of-the-box context for.

Match the depth to the work in front of you: a thin PRD for thin work, a deep
PRD for deep work. Use the same "don't pad / don't cut short" discipline you use
for the interview length.

### Engineering ADRs (complex Missions only)

For a **complex** Mission, also write an **`adr.md`** — the high-level
**Architecture Decision Records** the downstream stages have no out-of-the-box
context for. ADRs are **declarative facts** every later worker may read (with one
hard exception: **research agents never see them** — Research is
context-free by design). They capture **engineering** decisions only:

- **In scope for an ADR:** framework / library choice, the overall architecture
  or module boundaries, key data shapes / schemas, and the load-bearing
  constraints those impose.
- **NOT in an ADR:** implementation detail or ticket-level decisions — those stay
  with Plan and Implement. Keep the role separation; an ADR is the *frame*, not
  the *build*.

An ADR captures a decision the captain has been **walked through and confirmed**
during the interview — never a unilateral architectural choice the model made and
recorded on the captain's behalf.

Each ADR **must** carry these four sections, in this exact shape — `file.sh`
rejects an `adr.md` missing any of them:

```markdown
# Architecture Decision Records: <mission title>

## ADR-001: <short decision title>

**Context:** <the forces / situation that make a decision necessary>
**Decision:** <the decision taken>
**Alternatives considered:** <the options weighed and why they lost>
**Consequences:** <the rationale + what this commits us to / rules out>
```

Add one `## ADR-NNN:` block per decision. For a **trivial** Mission, write **no
`adr.md` at all** (at most a single one-liner ADR if there is genuinely one
architectural fact worth pinning) — never burden small work with ceremony.

When (and only when) the Mission is complex, write the ADRs to a temp file too:

```bash
adr=$(mktemp); cat > "$adr" <<'ADR'
# Architecture Decision Records: ...
...
ADR
```

…and pass it with `--adr "$adr"` alongside `--prd` in the next step. For a
trivial Mission, omit `--adr` entirely. **Align only SEEDS the ADRs** — the
Validate stage may later REFINE them when research findings change a decision, so
keep them high-level and revisable, not exhaustive.

When alignment is reached, write the PRD. **"Alignment reached" REQUIRES that the
captain has confirmed the load-bearing decisions through the interview** — not
the model deciding them on the captain's behalf. If a real decision went into the
PRD without a captain exchange, alignment is **not** reached. It **must** contain
all of these sections, in this exact shape — `file.sh` rejects a PRD that is
missing any of them:

```markdown
# Mission: <title>

**Type:** feature | bug
**Goal:** <one sentence>
**Acceptance Criteria:**
- <bullet>
- <bullet>
**Out of Scope:**
- <anything explicitly excluded>
**Constraints:**
- <tech stack, perf requirements, etc.>
```

The `# Mission:` title and `**Type:**` value are the source of truth — the
script reads the mission title and type straight from the PRD, so get them
right. Use `lcars:feature` / `lcars:bug` vocabulary consistently.

When the captain is happy with the PRD, write it to a temp file, e.g.:

```bash
prd=$(mktemp); cat > "$prd" <<'PRD'
# Mission: ...
...
PRD
```

## STEP 3–5 — Persist, open the issue, confirm

Hand the PRD to the bundled script. It mints the mission ID
(`lcars-YYYYMMDD-NNN`, sequenced per day), creates
`.git/lcars/missions/<id>/{prd.md,state.json}`, **creates the Mission's own
branch `lcars/<id>` off the current branch** (recording the branch and its base
in `state.json`), opens the GitHub issue with the `lcars:align,lcars:<type>`
labels, records the issue number, and prints the summary:

```bash
bash ~/.claude/skills/lcars-file/file.sh --prd "$prd"
```

For a **complex** Mission, also hand over the ADR set you wrote (the script
shape-checks it the same way it checks the PRD, then persists it as `adr.md`):

```bash
bash ~/.claude/skills/lcars-file/file.sh --prd "$prd" --adr "$adr"
```

For a **trivial** Mission, pass `--prd` only — no `--adr`, and no `adr.md` is
written.

Show the captain its output verbatim:

```
  Mission filed: lcars-20260530-001
  GitHub issue:  #42
  Branch:        lcars/lcars-20260530-001 (off main)
  Stage:         align
  Next:          run `lcars run lcars-20260530-001` to continue
```

## What gets written

```
.git/lcars/missions/<id>/
  prd.md        ← the PRD from Align (the GitHub issue body, too)
  adr.md        ← the engineering ADRs (COMPLEX Missions only; absent for trivial work)
  estimate.json ← the end-of-Align estimate (per-stage model map; OPTIONAL, see below)
  state.json    ← { id, type, title, stage: "align", created, model, githubIssue, branch, base }
```

At the end of filing, `file.sh` runs the lcars-run estimator
(`run.sh estimate`) once, which reasons over the finalized PRD + ADRs + repo and
writes `estimate.json` — two criticality scores and a per-stage model assignment
the downstream stages consume to spend Opus where the work warrants it. The
estimator is **strictly optional**: if it is unavailable or produces nothing, the
mission still files (a note is printed) and every stage falls back to its default
model — exactly like the `gh`-missing degradation.

Plus, in git itself: the branch `lcars/<id>` is created off the current branch
(the `base` the PR will later target). The working tree is **not** switched to
it — `lcars file` leaves the captain's checkout exactly as it was. Implement
checks the branch out when it commits the first green ticket; `lcars approve`
pushes it and opens the PR with `--head lcars/<id> --base <base>`.

## Notes & failure modes

- **PRD missing a required section** → the script exits non-zero and writes
  nothing. Finish Align — produce the missing section — and re-run.
- **`--adr` given but an ADR is missing a required section** (Context / Decision
  / Alternatives considered / Consequences) → the script exits non-zero and
  writes nothing, same as a bad PRD. Fix the ADR shape and re-run. (`--adr` is
  optional: omit it entirely for a trivial Mission — an absent `adr.md` is never
  an error.)
- **`gh` missing or issue creation fails** → the mission is still filed
  locally; `githubIssue` is recorded as `null` and the summary says so. Re-run
  after fixing `gh`, or open the issue by hand and record the number.
- **Mission ID** is `lcars-<UTC date>-NNN`; `NNN` increments per day from the
  existing missions in `.git/lcars/missions/`. Override the date in tests with
  `LCARS_DATE=YYYYMMDD`.
- **Model** is read from `.git/lcars/config.json` (written by `lcars init`),
  falling back to `LCARS_MODEL` then `claude-sonnet`.
- **Branch creation is best-effort.** In a repo with no commits there is nothing
  to branch from, so `lcars file` records the intended branch name but warns and
  leaves creation to Implement's first commit. An already-existing `lcars/<id>`
  branch is reused. Stub the git binary in tests with `LCARS_GIT_BIN`.

## Implementation

The logic lives in `file.sh` next to this file so it can be exercised directly.
Its behaviour is covered by `tests/lcars-file.test.sh` in the LCARS repo (run
with `bash tests/run.sh`). The skill source lives in `skills/lcars-file/` in the
repo and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo
copy, not `~/.claude`. If you change `file.sh`, keep those tests green.
