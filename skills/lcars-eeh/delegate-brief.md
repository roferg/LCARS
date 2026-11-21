# delegate-brief.md — the hand-off brief a delegate is given

The template `lcars-ech delegate <unit-id>` renders to
`.git/lcars/delegates/<delegate-id>/BRIEF.md`. It is **the thing the captain used
to type**, on disk, so it survives a session and can be reviewed before anyone
acts on it.

Why a file and not a heredoc: `bug-prd.md` is the precedent. A template buried in
a shell script cannot be read by the person whose work depends on it, cannot be
diffed, and gets edited by whoever is nearest the bug. This one is reviewable.

## What fills it, and what may not

The brief is rendered **from artifact paths alone** — the unit's record in
`autopilot.json`, the mission's `state.json`, and the tier's contract block in
`DELEGATION.md`. **Never from the orchestrator's transcript.** A transcript is
not on disk, so a brief built from one cannot be re-minted, reviewed or trusted
a day later, which is the whole defect this file exists to close.

The four numbered sections are *the four things every hand-off must state*
(`DELEGATION.md` § *The four things every hand-off must state*). Without all
four, delegates duplicate each other's work and leave gaps between them.

## The slots

| Slot | Filled from |
|---|---|
| `{{UNIT}}` | the unit id given to `tier` / `delegate` |
| `{{DELEGATE_ID}}` | the minted delegate id |
| `{{TIER}}` | `units.<id>.tier` — the ECH's recorded judgement |
| `{{TIER_WHY}}` | `units.<id>.tierWhy` — why it chose that tier |
| `{{ESTIMATE_SHOWN}}` | `units.<id>.estimateShown` — the factory estimate it was shown, or `none` |
| `{{GOAL}}` | a CHECKABLE statement of done, from the richest artifact on disk: `prd.md`'s own `**Goal:**` plus its `**Acceptance Criteria:**` if there is one, else the mission's `state.json` title (said to be a title), else a plain statement that neither exists. Never a topic passed off as a goal. The source is recorded as `delegates.<id>.goalSource` |
| `{{MISSION}}` | the mission id, and the path to its `state.json` |
| `{{STATE_PATH}}` | the absolute path to that `state.json` |
| `{{ARTIFACTS}}` | every artifact ACTUALLY PRESENT under `missions/<id>/`, by absolute path — `prd.md`, `plan.json`, `tickets/`, … (**D1**) |
| `{{WORKSPACE}}` | the brief's own **self-check** — the absolute path it was minted at, and the instruction not to use it anywhere else but to ask for a re-mint (**D16**) — then the repository root, the Mission's branch and base, and the ABSOLUTE path of the launcher that minted this brief (**D6**) |
| `{{TIER_DELIVERABLE}}` | what THIS tier adds to the hand-back. Empty at T0/T1; at T2 it asks for the tester's evidence and bug list (**D4**) |
| `{{TIER_CONTRACT}}` | the `<!-- tier:<T> -->` block of `DELEGATION.md`, verbatim |
| `{{VERBS}}` | the LCARS verbs in scope for this unit — and, **S365**, § *YOUR CHUNK, AND THE AUTHORITY THAT COMES WITH IT*: the chunk this sub-ECH owns **by Mission id**, the `LCARS_ECH_AS` export that makes its authority resolvable, the verbs that are **its own inside that chunk** (`file-bug`, `live-check`, `policy`, `drive`), that the same verbs are **refused by name outside it**, and the limit — `land`, `approve`, `push-gated` and `ask` stay the MAIN ECH's, each with the reason. The ONE statement of all of it is `DELEGATION.md` § *AUTHORITY TRAVELS WITH THE CHUNK*; this slot carries it to a reader who will never open that file, which is S359's lesson: a brief that does not state the rule it holds a delegate to manufactures its own false positives |
| `{{VERIFY_ROLE}}` | **S366 fix round 1** — § 5's body, and it is slotted precisely so a brief CANNOT CARRY BOTH ROLES. For a DRIVING seat it is the four steps it always was (read Number One, `live-check`, take `policy`'s action, `file-bug` and drive them). For a VALIDATION PASS it is that pass's contract: it LOOKS and it FILES, and the verdict, the action and the fix are **not its acts** — the harness refuses all three by name. Before this slot existed, § 5 was fixed text telling every seat to run `policy` and drive its own bugs, while the S366 section in `{{VERBS}}` told a validator it must not: one brief, two contracts, no override stated. The contradiction is now structurally impossible rather than patched by wording, because the slot is filled exactly once |
| `{{BOUNDARIES}}` | what this unit does not cover |
| `{{CREATED_AT}}` | when it was minted |
| `{{SIGNOFF}}` | who minted it and under which recorded judgement |
| `{{LAUNCHER}}` | **S351** — `bash <absolute path of the launcher that minted this brief>`, the same path § 3 already gives for every other verb. A brief whose commands are runnable as they stand is the difference between a delegate that beats and one that goes looking |
| `{{BEAT_LIMIT}}` | **S351** — the silence limit this delegate is held to, in minutes and in seconds, and what happens on expiry. The number comes from `BEAT_LIMIT` (`LCARS_ECH_BEAT_LIMIT`), so a brief minted under an overridden limit states the limit it was actually minted under. That figure is also RECORDED at `delegates.<id>.beatLimit`, so `stalled` can report the limit this delegate was briefed under rather than whichever one happens to be set when the report runs |
| `{{ENGINE_STAMP}}` | **S352** — the engine AND model this delegate's role must run on, by name, from the role → engine matrix (`DELEGATION.md` § *Who runs what*), plus the rule that **another engine may not be chosen**. At T2 it also names the tester's row. Recorded at `delegates.<id>.engine` / `.model`, so nothing greps the brief back to learn what it was stamped with. **S352 fix round 1** adds the three things that rule did not cover: **every seat the delegate opens** takes the same row (there is no `subdelegate` row, and a T2 delegate dividing its unit could otherwise open three Claude seats without breaking a sentence); **the seat it is already in** is checked, because a brief pasted into a window it did not choose bills the unit just the same; and a **FREE→BILLED substitution** is stated in the brief and recorded at `delegates.<id>.engineRecorded` / `.engineSubstituted` rather than being visible only on the `engines` screen |
| `{{FRONT_DOOR}}` | **S352** — the front-door clause: the verbs in scope by name, the Holodeck route for screen work, HCM § 4a's rule stated once, what the delegate decides alone, that a question goes UP to the ECH, **the absorption route and what is NOT absorption**, the T2 tester hand-off, and the two-list sign-off. The ONE statement of those rules is `DELEGATION.md`; this slot carries them to a reader who will never open it. **S352 fix round 1** labels the exit door the prohibitions made necessary: the absorption section used to end on *"raise it"* with no command behind it, and the only escalation verb named was `ask` — which prints *QUESTION FOR THE CAPTAIN*, fires the notifier this same brief forbids four times, and was not even in the reserved list. The channel is now **one runnable command**, a `BLOCKED:` beat, which `stalled` and `status` surface at once; `ask` joins `land` on the reserved list; and the `lcars log` door names the `bug-prd.md` to copy, because a brief that said `--prd <f>` and nothing more sent a stuck delegate at a door with no handle. **S365** re-reads one entry of that list: `file-bug` is the sub-ECH's own verb **inside its own chunk** and is reserved only outside it — see the `{{VERBS}}` row |

**Those two slots were named and left empty by S350 so that S352 would edit ONE
template instead of inventing a second one. S352 has filled them.** A renderer
must still leave an *unsupported* slot **empty**, never print the token: a brief
with a raw `{{TOKEN}}` in it is a brief a delegate has to guess at.

## The brief is its own guard (D16)

`{{WORKSPACE}}` leads with the path this brief was **minted at** and one
instruction: if the file you are reading is not there, do not use it — ask the
ECH to re-mint. Every other path in the brief is **absolute**, which is what the
delegate needs in order to `cat` anything, and which is also why a copied brief
is dangerous rather than merely stale: in a `cp -R` of the repo, with the
original still present, every path still resolves and the delegate does coherent
work in the **wrong repository** while the ECH believes otherwise. The listing
verbs warn about this, but a hand-over is a `cat` of one file and never runs
them. So the artifact carries the check. **The cure is the self-check, not
relativising the paths.**

## The template

Everything between the fences is the template. The fences are the declared
boundary the renderer reads — not a heading it guesses at.

<!-- template:begin -->
# DELEGATE BRIEF — {{DELEGATE_ID}} · unit {{UNIT}} · tier {{TIER}}

Minted {{CREATED_AT}} by the ECH, from artifact paths alone.
You are a delegate of the LCARS Emergency Command Hologram. Read this whole
file before you touch anything. If something you need is not in here, that is a
defect in the brief — say so rather than guessing.

## Your tier: {{TIER}}

The ECH chose this tier freely and recorded why: **{{TIER_WHY}}**
The factory's own estimate, which it was shown and was free to disagree with:
**{{ESTIMATE_SHOWN}}**

This is your contract, verbatim from `DELEGATION.md` (read the whole file with
`lcars-eeh docs delegation`):

{{TIER_CONTRACT}}

## Where you work

{{WORKSPACE}}

## 1. The goal

{{GOAL}}

Mission: **{{MISSION}}**
Its record on disk, which is the authority over anything summarised here:
`{{STATE_PATH}}`

### Read these before you write anything

These are the artifacts actually on disk for this unit. The brief summarises
them; they are the authority.

{{ARTIFACTS}}

## 2. The output format expected back

Report in **SUMMARIES, never raw transcripts.** The ECH's context is the
scarcest thing in the system; a pasted transcript spends it on material you have
already acted on, and it is your job to have absorbed what a transcript would
have shown.

Your hand-back states, in this order:

- **What is now true** — the goal above, answered, or the part of it that is.
- **What you ran, and what it printed** — the commands and their real output,
  with the real identifiers (ids, paths, field names). Not a paraphrase.
- **What you cured yourself** — each stumble you absorbed and how. At T1 and T2
  this section is the measure of whether the tier earned anything.
- **What is still open** — anything you could not resolve, and what it is
  blocked on.
- **What you did NOT touch** — so the ECH can tell an untested area from a
  working one.

{{TIER_DELIVERABLE}}
**Your hand-back is a report, never a verdict.** See § 5.

### And while you work: BEAT

The hand-back above is the END. Between now and then the ECH has **no other way
to see you**: you are a model in another window, not a process it started, so it
has no pid of yours to watch and no log of yours to read. Your beat is the only
thing it can see.

**One beat per step, as you finish it** — through the launcher named in
*Where you work* above, by its absolute path. **Declare N**, your total number
of checkable steps, before starting; report the current K of that N. And say
**what changed**: the two numbers are the bookkeeping, the words after the colon
are the beat. This runnable example declares seven steps and reports the first —
set N to your own count, K to the step you are on, and WHAT to what actually
moved since your last beat.

    N=7
    K=1
    WHAT="oriented: seat and budget checked, the mission is at stage align"
    {{LAUNCHER}} beat {{DELEGATE_ID}} "step $K of $N running: $WHAT" --step "$K/$N"

Why: a beat without a step proves you are alive, not that you are getting anywhere.

One line, every time. It appends — a beat never overwrites an earlier one — so
the sequence of them is the record of how you spent your hours, and the ECH
reads your latest one as *where you got to*. Repeat the current step if it is
still running; do not invent an advance to quiet the watchdog.

{{BEAT_LIMIT}}

{{CIRCLE_LIMIT}}

## 3. The LCARS verbs in scope

{{VERBS}}

Use the factory's own verbs and nothing else. **Never hand-step the stage
machine**, and never build a second route to an outcome a verb already
produces — front-door doctrine, `HOLOGRAM-COMMAND-MODE.md` § 4a, and it applies
to you exactly as it applies to the ECH. Run any of them through the launcher named in *Where you work* above, **by its
absolute path** — a bare `lcars-ech` on `PATH` may be a different install than
the one that minted this brief. Do not re-implement a verb, and do not guess
its flags.
{{FRONT_DOOR}}

## 4. The boundaries

{{BOUNDARIES}}

Also, and without exception:

- You do not get a parallel-mission slot of your own and you may not raise the
  two-mission ceiling (`HOLOGRAM-COMMAND-MODE.md` § 8).
- You do not interrupt the captain. A scope change, a product call he owns, or a
  conflict with a standing rule comes back to the ECH, which owns the interrupt
  budget (§ 9). **Your problem is the ECH's problem**, not his.
- You do not merge, approve, land or mark the WHOLE ask verified, approved or
  landed. That is § 5.
- You do not reach outside your own chunk. § 3 names what is yours and where it
  stops.
- Everything you write stays inside `.git/lcars/` or the mission's own branch.

## 5. YOU verify your chunk; the MAIN ECH verifies the whole

**Each ECH verifies its own chunk, and the one above it verifies the whole.**

{{VERIFY_ROLE}}

**AND THE WHOLE IS NOT YOURS.** When you hand back,
**the ECH will verify the work itself** at the level of the whole ask — do the
chunks fit together, is the overall ask met — and that is the one thing no
single chunk can see. It is not a second validation of your chunk.

**Your hand-back is a report, never a verdict** about the whole. Saying "all
green" is an input to that check, not a substitute for it, and nothing about
the whole advances on your word: closing you out marks *you* done and moves
neither the mission's stage nor its verdict. `land` and `approve` stay the main
ECH's.

{{ENGINE_STAMP}}

## Sign-off

{{SIGNOFF}}
<!-- template:end -->

## The T2 addition

At T2 the tier contract above carries **T1's contract and T2's**, in that order,
because T2 is defined as "T1, plus a tester" — a strict superset. A T2 brief
that embedded only the T2 fence never told its delegate T1's absorption
obligation at all, and a live Copilot seat handed one said so unprompted: *"the
full inherited T1 obligations are not included."*

T2 also fills `{{TIER_DELIVERABLE}}`, so the tester arrives as an **instruction
to this delegate** — § 2 asks for the tester's evidence and its bug list, and
§ 3 puts standing one up in scope. Before that, T2 appeared only as a quoted
description of what T2 *is*, and a T2 delegate could file a fully §2-conformant
hand-back having stood up no tester at all.

The brief points at `ORCHESTRATION.md` for what a tester is and does — it does
not restate those rules. A second copy of a rule is a rule that drifts. That
tester is **additive**: it is an extra independent pair of eyes at the gate and
it **does not replace** the ECH's own check in § 5.
