---
name: lcars-xo
description: Engage, stand down, and inspect Number One — the AI first officer that holds a Mission on the captain's behalf. `lcars xo on [--engine copilot|claude] [--model M]` turns Number One ON for this repo, recording the choice in `.git/lcars/config.json` as a one-line `numberOne` block; with no `--engine` and a terminal it opens a picker naming the engines installed on this machine, and with no terminal it refuses loudly rather than choosing in silence. `lcars xo off` stands the repo down and hands the conn back on every engaged Mission; `lcars xo off <mission>` opts one Mission out and stands just that one down (signalling its recorded worker pid, recording `stood-down` and a note); `lcars xo on <mission>` puts that Mission back in scope — it clears the per-mission opt-out AND the `stood-down` status, so the next drive can engage it again. `lcars xo answer --mission <id>` is the driver's call at a park: Number One reads the Mission's record in a read-only copy, then either ANSWERS the gate through `lcars respond` (attributed `answeredBy: number-one`, exit 0) or ESCALATES with a note and a recommendation and leaves the gate up (exit 1) — always escalating a `scope` gate, an uncited answer, and anything malformed. Bare `lcars xo` prints the status table — every Mission with its stage, Number One's RECORDED status (engaged / finished / escalated / answered / stood-down / opted-out) and its note. While a Mission is engaged the write verbs (approve, feedback, respond, log, pause, resume, resolve-logs) and the viewscreen's matching endpoints refuse with ONE sentence, because Number One is already acting through them on the captain's behalf. Use when the captain runs `lcars xo`, says "engage Number One", "turn the first officer on/off", "stand Number One down", "who has the conn", or asks what Number One is doing.
---

# lcars xo — Number One

**Number One is the AI first officer.** With it engaged, LCARS does not just stop
at a gate and wait: it takes the conn on the captain's behalf, works the gate
through the ordinary verbs, and hands the conn back with a report.

`xo.sh` does all of the mechanical work. It asks no model anything — **the
worker reasons, the skill executes** (captain ruling, 2026-09-11). You (Claude)
run it and read out what it printed.

## The verbs

```bash
bash skills/lcars-xo/xo.sh                          # the status table
bash skills/lcars-xo/xo.sh on --engine copilot      # engage for this repo
bash skills/lcars-xo/xo.sh on                       # …with the picker
bash skills/lcars-xo/xo.sh off                      # stand the repo down
bash skills/lcars-xo/xo.sh off <mission>            # opt ONE mission out
bash skills/lcars-xo/xo.sh on  <mission>            # clear that opt-out
bash skills/lcars-xo/xo.sh answer --mission <id>    # take the park (S202)
bash skills/lcars-xo/xo.sh evaluate --mission <id>  # the Verify look (S203)
bash skills/lcars-xo/xo.sh file-logs --mission <id> # file the gaps as logs (S204)
bash skills/lcars-xo/xo.sh recheck --mission <id>   # re-look after the fixes (S204)
bash skills/lcars-xo/xo.sh report [<mission>] [--all] [--seen]
                                                     # the First Officer's report (S205):
                                                     # since you last looked, then history,
                                                     # folded per mission. Scope to one
                                                     # mission's own journal by naming it;
                                                     # --all shows every entry; --seen marks
                                                     # it read (.git/lcars/xo-seen.json).
                                                     # The board's own GET /api/xo/report and
                                                     # POST /api/xo/seen read and write the
                                                     # SAME record through the SAME builder
                                                     # (skills/lcars-xo/xo-report.py).
```

The front door routes `lcars xo …` here through an explicit delegator in
`skills/lcars/lcars.sh` — **not** through smart-default routing, because a bare
`lcars xo` is a READ and the router would otherwise take `xo` for a Mission
selector and try to drive something.

## `answer` — taking a park (S202)

When a Mission stops **awaiting-human** and Number One is engaged there, the run
driver calls `xo.sh answer --mission <id>`. It:

1. copies the Mission's record into a temp **input** dir, **read-only** — the
   PRD, the ADRs, the validated plan, `plan.json`, `pending.json`,
   `answers.json`, the research findings, the last 200 events, the attachments
   (the holodeck drawing and its concept), and `claim-check.txt` /
   `reconcile-design-question.txt` when they are there;
2. hires **one cold worker** through `run.sh spawn-number-one`, so the first
   officer reaches the same chokepoint every Stage uses — role → stage key
   (`numberOne`) → the pinned model → the fenced argv → the S168 fence snapshot
   → usage capture. The role is READ + author-one-file, **no shell, no
   network**, on both engines (`worker-adapter.sh`);
3. reads back the worker's one file, `xo-answer.json`, and **checks it**;
4. **ANSWER** → `respond.sh answer`, the ordinary verb, with
   `LCARS_ANSWERED_BY=number-one` (the ledger says who) and
   `LCARS_RESPOND_RESUME=0` (the driver is already running; a re-exec would put
   two drivers on one Mission). Exit **0** — the driver continues;
   **ESCALATE** → the gate is left exactly as the stage raised it,
   `numberOne.status` becomes `escalated` with a note carrying the summary and
   the recommendation. Exit **1** — the driver halts, as today.

`xo.pid` holds this script's pid for the length of the spin, and a SIGTERM (what
`lcars xo off <id>` sends) walks the whole process tree down so the worker dies
with it. Every action is appended to `<mission>/number-one.jsonl`.

### What is checked, and why

- **An ANSWER must cite a line that is really there.** At least one citation
  quote must occur, verbatim (whitespace-normalised), in the file it names. The
  prior-art on LLM judges says the failure to expect is not over-refusal but a
  judge that **reasons its way past the record** — a chain of sensible
  inferences landing somewhere the Mission never said. A verdict that cannot
  show its line is not a verdict.
- **Scope and spend are the captain's, always.** A gate whose
  `escalationType` is `scope` escalates no matter what the worker decided
  (ruling 2026-09-11). The worker still runs, so the captain gets a
  recommendation with the escalation.
- **The unsure exit is honoured.** `decision: answer` with `confidence: low` is
  taken as the escalation the prompt asked for.
- **Anything malformed escalates** with the note
  `Number One could not decide — malformed verdict` — no file, not JSON, no
  decision, an answer with no citations. Never a crash, never a silent answer.

The model is the captain's Opus pin: the S194 write floor
(`write_capable_alias` → `modelAliases.copilot.opus`, default
`claude-opus-4.8`), overridable by config `numberOne.model`, outranked by
`LCARS_WORKER_MODEL`. The prompt is `skills/lcars-xo/prompts/answer.md`.

## `evaluate` — the Verify look (S203)

The Mission has a PR open and is parked at Verify. `evaluate` launches the
build, walks it in a **headless** browser, compares it against a contract
written before it looked, and scores the intent match.

The order is the contract:

1. **`xo/criteria.json` FIRST, before any browser.** The PRD's acceptance
   criteria (marked `primary`), the plan's per-ticket criteria with their
   `drawnAt` / `notDrawn` / `notVisual`, and the drawing's place names. A judge
   that writes its checklist after looking writes a checklist of what it
   happened to notice.
2. **`launch.sh <id>`.** If the build does not come up, the score is **LOW**
   quoting the launch message — and **no browser is started at all**.

   **2b. THE DECLARED SEED (S220 part E).** Screens that only exist once there
   is data in them cannot be photographed into existence, so a repo may declare
   sample data for the look and it is loaded here, in the launched build's own
   worktree, before the first picture. Two places, both of them the RECORD —
   never a guess by a worker:

   - `"verifySeed": "<command>"` in `.git/lcars/config.json`, or
   - an executable `.lcars/verify-seed.sh` the project itself ships.

   It is caged (`LCARS_XO_SEED_TIMEOUT`, 300s) and what ran is recorded in
   `xo/seed.json`. **With neither declared nothing is invented**: the report
   says in one plain sentence which screens it could not see for want of data,
   and those rows are `couldn't check` — never a fault in the build.

   **2c. THE DECLARED JOURNEY (S220 part F).** `xo-journey.py` reads the flow
   out of the record — the drawing's screen order and each screen's own forward
   control, the PRD's steps ("the Preview button navigates to …", which is how a
   screen the drawing never drew is reached at all), and the fields and gates
   the screens carry — and writes `xo/journey.json`, one requirement per step.
   The DRIVER walks it: it finds its way in by clicking (the first screen's
   headings and the mission title are the names it tries), clicks each step's
   control by its accessible name, types into the fields a person fills, and
   tries every gate BOTH ways — once while the thing it waits for is blank,
   once when it is filled. `xo/walk.json` is what actually happened: every
   click, typing, keypress and address jump, and each step that could not be
   taken, by name. A step recorded `unreachable` is forced to **couldn't check
   (unreachable)** whatever the look says about it.

   **Why the harness walks it and not the model:** measured twice on the same
   build with the same code, one look clicked its way through and the next
   jumped to four addresses and never touched a control. A walk left to the
   model's discretion is a lottery. `navigate` still works for the model's own
   rounds — every jump past the front door is counted and the screens reached
   that way are labelled *reached by address, not by the flow*.
3. **Round 0** — `xo-drive.js` takes the whole page plus one clipped shot per
   place the drawing names. Every PNG gets a paired `.json` readout and a
   one-line `.txt` caption.

   **ONE LOOK, ONE DIRECTORY.** Each look writes into its own
   `xo/shots/<look>/` — `look-1`, then `recheck-1`, `recheck-2` — and the worker
   is handed THAT directory and no other. Nothing is ever deleted (the
   walkthrough is built from these pictures); which directory a look reasoned
   from is in its journal line, and `xo/look.txt` points `file-logs` at the one
   the verdict came from. Before this, a second look that took fewer shots than
   the first inherited the first's leftovers and reasoned about them as current.

   **Every visible element gets geometry, not just the drawing's named places
   (S210).** `xo-drive.js` walks the whole rendered DOM and records a box, a
   computed colour and a couple of DOM facts for every visible element, up to
   `--element-cap` (default 300) — a dense page says how many it captured and
   how many it dropped, in the record, never in silence.

   **And it writes down what the browser knows about each one (S212):** where
   it sits in the DOM (`path`), its computed `overflow` (`overflowStyleX/Y`,
   kept separate from the pixel-spill `overflowX/Y`), whether cutting its text
   off was the POINT (`textOverflow` — the ellipsis idiom), and whether it is
   really the thing painted at its own position (`seen`, with `hiddenBy`
   saying WHY when it is not: `clipped` — its own scroll container has carried
   it away — or `covered` — something solid is painted on top). A cover only
   counts when it is solid enough to actually hide what is under it: the alpha
   of its background colour times its opacity, multiplied down the ancestor
   chain because opacity is inherited. A bare click-catcher and a 35% modal
   backdrop hide NOTHING and buy no silence; an opaque backdrop does. These
   are RECORDED, never worked out afterwards from the boxes: a badge sits
   geometrically inside its button and so does a genuinely misplaced element
   that merely overlaps one, and rectangles cannot tell those two apart.
3b. **`xo/observations.json` — computed by the SKILL, not asked of the
   worker** (`xo-observe.py`, arithmetic over Round 0's boxes). Crowding,
   overlap, a misaligned row, clipped text: things no drawing states, so
   nothing ever asked the model to notice them. Each reads the way a person
   would say it — *"the ADD and CANCEL buttons are touching — 0 px between
   them"* — never harness vocabulary. **They are not gaps.** They never move
   the score, they live in their own section of `xo/report.md` (and the living
   comment, which renders it verbatim), and the worker may cite one as
   evidence for a real gap but may never invent a criterion from one. The
   thresholds used are printed at the bottom of that section, because only the
   captain can calibrate them against his own eye.

   **It does not cry wolf, and it does not shout (S212).** Driven live, this
   pass fired on UI that was perfectly correct, so four things are now true of
   it. It never compares an element with something inside it — a chip and its
   own remove button, a button and its unread badge. It never calls a box that
   is MEANT to scroll "clipped", nor a name deliberately shortened with an
   ellipsis that can actually render (`overflow: hidden` with the same spill
   and NO ellipsis still reports, and so does `text-overflow: ellipsis` on
   text that is allowed to WRAP, where no ellipsis is ever drawn — those are
   the controls). It never measures what cannot be seen —
   and "cannot be seen" means actually covered, not merely overlaid. And
   one fact found over and over is ONE note that names the count — *"five rows
   in this list sit 6 px apart"* — with the whole list capped past a handful:
   *"This page has a lot going on — here are the three worst. I held back 5
   more."* `foundCount` keeps the true total in the file and in the journal, so
   a capped list can never read as a quiet page.

   Two rules keep those collapsed sentences honest. A family is things that
   really sit TOGETHER — same kind AND **one place that holds all of them**,
   and A PLACE HAS TO BE EARNED. There are exactly two shapes that earn one,
   read off the recorded DOM paths and boxes: every member shares the **same
   direct parent** (one toolbar, one list, one form row), or the group is
   **one repeated family** — units that are siblings under one ancestor, all
   the same shape, laid out in a column, a row or a filled grid. That second
   shape is the table for twenty list rows each carrying its own Edit/Delete
   pair: one fact, said once, and said as *"every row's Edit and Delete
   buttons are touching — 0 px between them"* rather than as a button count
   nobody can picture. **"Every" is established before it is said** — the rest
   of that family is counted, and a list where only three of eight rows are
   affected reads *"three rows' Edit and Delete buttons are touching — 0 px
   between them"*. A story with a false number in it is worse than a number
   with no story: it is the one he can catch himself, looking at the screen. Anything else has **no place** and says so — *"in
   different parts of the page"* — instead of inventing one. A WRAPPER THAT
   MERELY CONTAINS EVERYTHING IS NOT A PLACE: a tab bar, a segmented control
   and a pager inside one `#app` stay separate facts rather than becoming
   "seven buttons in this list". Whether a place it does have is a row or a
   list is read off the boxes, not off the crowding axis. And as a last
   resort: if two notes would read the same word for word, they fold — the
   captain is never handed the same sentence twice.
   And "the three worst" is EARNED, not a fixed order of categories: how much
   of the page each fault actually spoils, in pixels, times how many things it
   is about. Six names cut off mid-word outrank two buttons a pixel apart.

   **Silence has to be earned.** An element is written off as not-seen only
   where hiding was POSITIVELY established: an ancestor won the hit test (its
   own scroll container has carried it away), or a cover was MEASURED and
   found opaque. Everything else is looked at. A colour's alpha is really
   parsed, in every syntax a browser computes — `rgba()`, `hsl()`, `oklch()`,
   `lab()`, `color(srgb …)`, `color-mix()` — so six visually identical 30%
   dims behave identically, and an opaque one in any of them still hides. A
   gradient states its own colour stops, so its strongest stop bounds it: a
   sheet whose every stop is alpha 0, or a decorative vignette topping out at
   0.25, hides nothing. `backdrop-filter: blur(0px)` hides nothing either,
   while a real `blur(8px)` glass panel still does. Anything that cannot be
   measured — an unrecognised filter, a `paint()` worklet, a colour syntax
   nobody has written yet — means "I could not establish that this is
   hidden", and the page under it is measured. Two deliberate exceptions stay
   solid because there is a real reason to believe they cover: a raster
   `url(...)` image and an SVG `url(#…)` filter. The failure mode of this
   whole pass is SILENCE, not noise — a false alarm is on the screen for the
   captain to overrule, a false silence he never learns about. **And the
   silence that is left is said out loud**: where something really was behind
   something solid, the report's own observations section tells him so —
   *"Three things on this page were behind something solid, so I could not
   look at them."* Nothing hidden, nothing said.
3c. **`xo/tests.json` — the project's OWN tests, run by the SKILL** (S211,
   `xo-tests.py`). Number One acts only through a browser, so a change with no
   screen surface was simply invisible to it: *"batches survive a restart"*
   came back "I could not check this" on both engines in S203 — correct, and
   useless. So between the capture and the worker round, `evaluate` runs the
   repo's own `testCommand` **in the launched build's worktree**, bounded
   (`LCARS_XO_TEST_TIMEOUT`, 300s) with the output tail capped
   (`LCARS_XO_TEST_TAIL_CAP`, 8000 bytes) and the cut STATED. It records the
   command, the exit code, the duration, the tail and a plain verdict, and
   derives ONE `outcome` where it knew it: `passed` · `failed` · `hung` ·
   `no-test-command` · `no-worktree`. **A hang is infrastructure, never a
   product failure** — a suite that did not finish says nothing about the
   build, and the whole process group is killed. **A repo with no
   `testCommand` is the common case**: the file records that plainly and the
   look proceeds exactly as it always did.

   **The skill runs it; the worker never does.** The fence (S168) is untouched
   — the worker is handed `tests.json` through the same read-only door as the
   shots and the observations, and has no shell.

   **THE OVER-CLAIMING GUARD, which is the point of the session.** A
   `notVisual` criterion may be settled by the project's own tests and cited
   like any other evidence — but a citation is a LINE out of the recorded
   output, and `xo-score.py` checks it against that record. Lean on a green
   run with no line to point at, quote a line that is not there, quote a line
   that is only a TALLY (`413 passed, 0 failed`, `Duration 1.23s` — a class of
   line that names nothing, so it can settle nothing, refused with no
   relevance judgement at all), or cite a suite that never ran or hung, and
   the criterion goes back to **"I could not check this"**. A passing suite does not prove a criterion the suite does not
   cover, and the report says so in his words: *"They pass, but they don't
   cover everything on your list…"*

   **A FAILING test relevant to a criterion is a GAP**, with the failure
   quoted — and the score falls by the EXISTING matrix below, with no new
   rule. Such a gap keeps its `contradiction` kind with no screenshot behind
   it, because the failing line IS the picture; the bug PRD `file-logs` writes
   carries that line for the fix worker.

   **Every ledger line names its evidence kind** — `picture`, `measurement`,
   `tests` or `none` — declared by whatever made the judgement, never worked
   out afterwards from the wording of a note, and rendered as a *How I know*
   column in `xo/report.md`. The captain must never have to guess which of the
   three decided a line. An **`untested` line settled nothing, so it names
   nothing**: its kind is `none` and the column reads `—`. A row that both
   decided nothing and named a source is worse than one that admits it could
   not tell. A `met` on the tests **quotes the line that settled it**, the same
   way a gap does.

   **A non-zero exit is not "your tests failed".** A run that exits 1 is a red
   test of his OR a runner that never started, and nothing on disk separates
   them: measured, the tester's genuine failing suite exited 1 after 0.26s with
   877 bytes of output and the crashed runner exited 1 after 0.12s with 1030.
   So the sentence the skill writes for itself says the RUN failed, names both
   possibilities, and does not count the number against the build on its own —
   what it MEANS is decided by a quoted line, checked against the output.

   **`recheck` re-runs it too**, for the reason its observations pass re-runs:
   a recheck relaunches the build from the FIXED branch, so the first look's
   test run is about code that no longer exists. Carrying it forward would be
   the S204 stale-shots defect in another costume.
4. **Up to `$LCARS_XO_MAX_ROUNDS` worker rounds — TWO by default** (the ceiling
   came down from three on 2026-09-20: over five real-arm runs the third round
   changed nothing). Each round Number One writes EITHER `xo-actions.json` (it
   wants to look further — at most 12 actions, every screenshot named; the
   vocabulary is `navigate` / `click` / `type` / `press` / `wait` / `screenshot`,
   and `press` takes a **`hold` in milliseconds** (S221) because a tap cannot
   move anything that moves only while a key is DOWN — a game character walks a
   couple of pixels on a tap and one 32px tile on a 250ms hold, and a look that
   taps at one is reading a readout that had no reason to change) OR
   `xo-verdict.json`. No verdict by the end of the last round is a **LOW** that
   lists what it saw. The number lives in `xo.sh` alone and is exported into
   the worker's prompt, so the model is told the budget it actually has.
4b. **ONE MORE PASS, WITH THE LIST PUT AWAY (S224).** Number One reviews what
   the captain wrote down — and on the S222 capstone it filed every fault an
   acceptance criterion named and missed or demoted every fault none did. It
   quoted one faulty line of text *verbatim* and passed the row it was on, and
   it passed a control missing something all its neighbours had, because the
   comparator asks whether a thing OVERFLOWS and cannot ask whether it is
   ABSENT.

   So after the verdict exists, one more worker is asked a single question —
   *"what is wrong here that nobody asked about?"* — **over the pictures the
   walk already took**. No second browser, no second walk, no extra look: one
   prompt against shots already on disk. What makes it different is not the
   prompt but its CONTEXT: its input directory holds the PNGs and their
   readouts and **nothing else** — no `criteria.json`, no PRD, no plan, no
   drawing, no journey, no pairs. A reviewer holding a list finds what is on
   the list.

   **Its findings go to `escalations` — the channel S222 built — and nowhere
   else.** Not the score, not a criterion, not a gap, not a second surface. An
   unlisted finding is evidence for the captain, not a criterion he wrote, so
   it reaches the console line, the journal and `lcars xo report` exactly as
   the look's own escalations do, attributed *"nobody asked about this"*. The
   fence is `merge_unlisted` in `xo-score.py`, read after every number is
   already final, and pinned by a test that scores the SAME ledger twice and
   demands the two verdicts agree everywhere but there.

   **A finding must name a picture that was taken.** `xo.sh` stamps the
   inventory it granted into the record, so the model cannot declare its own
   corpus; one citing a picture nobody took is dropped, and the drop is
   disclosed in the notes. `LCARS_XO_UNLISTED=0` switches the pass off; no
   shots, no worker output or a malformed file leaves no record at all and the
   look finishes exactly as it would have.
5. **The score is RECOMPUTED from the ledger** (`xo-score.py`). The model
   reasons; the skill decides:

   **The captain's two-part score (S216).** Before judging, each criterion
   gets an IMPACT (`high` = the point of the mission, a reasonable person
   would block the merge; `medium` = a stated requirement that is secondary,
   or works but not as asked; `low` = polish).

   **THREE QUESTIONS, NOT ONE GRADE (S225 change 01).** Every criterion has
   carried a `source` since it was written; the ledger splits three ways on it
   and each row carries its `source` and its `group`:

   | group | from | question | what it produces |
   |---|---|---|---|
   | `person` | `prd` + `journey` | Can a person do what it promises? | **the headline grade** |
   | `drawing` | `drawing` | Does it look like your drawing? | its own graded line |
   | `contract` | `plan` (ticket ACs) | Is the contract covered? | a COVERAGE COUNT, no grade |

   `verdict.score` is the PERSON group's grade and nothing else (the captain's
   ruling, 2026-09-22 — not the worst of the three); `verdict.scoreGroup` says
   so, and `verdict.groups` carries all three. A source this file does not
   know falls to `person`. The drawing line is never hidden; it simply does not
   set the headline. The contract group carries no `grade` key at all: a ticket
   criterion nobody could answer is a fact about our checking, not a failure of
   the build.

   **FOUR OUTCOMES, AND ONLY TWO OF THEM GRADE (S225 change 03).** Each row
   carries an `outcome`: `worked` | `didnt-work` | `couldnt-see` |
   `couldnt-set-up`. `status` (`met`/`gap`/`untested`) and `couldNotCheck`
   (`unreachable` | `unobservable`) are unchanged beneath it. Only `worked` and
   `didnt-work` may move the grade — *a failure of ours must never read as a
   doubt about your build* — and what could not be checked is listed for US to
   fix in `verdict.myChecking` (`couldntSee` / `couldntSetUp`, each naming what
   defeated it). First match wins, over ONE graded group:

   | impact x outcome | the score | |
   |---|---|---|
   | nothing on this list | **LOW** | never a pass |
   | a HIGH one didn't work | **LOW** | `core` broken |
   | nothing on this list was checked at all | **LOW** | nothing is vouched for |
   | there are HIGH ones and not one was checked | **LOW** | `core` unverified |
   | every high worked; a MEDIUM one didn't work | **MEDIUM** | go with the named known issues |
   | every high and medium worked | **HIGH** | low ones, and blind spots, never move it |

   A criterion with no impact counts as HIGH and the reasoning says so. Every
   row carries a `reason` sentence (a fallback says when none was given); the
   verdict carries `whyThisGrade`, `core`, and — beside the grade, never
   instead of it — `altReading` / `polishFlag`. Ids not in the contract are
   not counted. The card pill reads `◈ MEDIUM · checked 11 of 14 · core met`.

   **A worker score that disagrees with its own ledger is overwritten, and the
   disagreement is journaled** (`score-overruled`). Both scores stay in
   `xo/verdict.json`.

   **NEVER SILENTLY MET, with no drawing (S210).** `criteria.json` carries
   `hasDrawing` (`xo-criteria.py`, true only when `attachments/` holds a
   mockup). When it is false, every `drawnAt` criterion is FORCED to
   `untested` — *"I could not check this against a drawing, because there
   isn't one"* — whatever the worker rated it. This is the one place
   `xo-score.py` overrules the worker outright rather than merely checking a
   citation: it is a fact about the mission's own attachments, not a
   judgement call. A mission with no PRD-drawn criteria at all can still score
   HIGH; a `drawnAt` one cannot pass on a look that had nothing to compare it
   against.
6. **`launch.sh <id> --stop`** — on every path out.
7. **The record:** `xo/verdict.json`, `xo/report.md` (what the living comment
   includes), journal lines, `numberOne.score`, status `finished` (a HIGH) or
   `engaged` (gaps → S204), and the score **LABEL** `lcars:xo:<score>` with the
   other two removed. One source per fact: the label is the score, the comment
   is the report.

   The four `lcars:xo:*` labels are part of `lcars init`'s canonical set, and
   the swap **ensures its own family first** (host adapter `label-ensure`) so a
   repo initialized before this round does not silently lose the verdict to a
   label the forge has never heard of. `lcars update` fills them in too.

`evaluate` is idempotent on `numberOne.evaluatedAt`, and a logged bug child
(`parentMission`) is never evaluated — its parent carries the build.

**The driver starts the look, detached.** `drive_verify` hands the build to
`xo.sh evaluate` at both Verify halts — the pass that opens the PR and the pass
that finds one already open — as a `setsid`/`nohup` child with its pid in
`xo.pid`, so the halt returns the captain's terminal immediately. Same two
guards on the driver's side (`evaluatedAt`, `parentMission`), because a spawn
that only refuses *inside* the verb has already paid for a launch and a browser.
`LCARS_XO_DRIVE=0` turns the hook off.

**The score travels.** Because it is a LABEL, a board on another laptop reads it
off the one listing the remote poll already fetched (S191) and draws an
`INTENT MATCH · HIGH|MEDIUM|LOW` pill — teal / amber / red, and labelled in full
so it never reads as one of the card's two DIFFICULTY pills, whose HIGH means
the opposite kind of news. `lcars:xo:engaged` carries the badge the same way.

**It files nothing.** S203 finds and scores; S204 is the round that acts.

### The captain's focus is never taken

Captain's ruling, 2026-09-13. `xo-drive.js` launches Chrome **headless, always,
with no flag and no environment variable that can raise a window** — not even
`LCARS_BROWSER_HEADED`, which is a test affordance for the board's eyeball legs
and must never become a product path. Nothing here opens a tab, an app window or
a file for the captain: `launch.sh` starts the app on a port and returns a url,
and the only thing that ever visits that url is Number One's own headless
Chrome, in a throwaway profile, TERMed by its own pid on the way out.
`tests/drives/s203/drive-rig.sh` asserts it by reading the frontmost application
before and after a whole real drive.

## `on` sweeps what is already waiting at Verify (S220 part G)

Switching Number One on is the captain saying *"I have to step out"*, so
`lcars xo on` (repo-wide, and the board's toggle) does not only arm the hook
that fires when a run ARRIVES at Verify — it picks up what is already there.

His ruling on scope (2026-09-19): **"Review everyone at verify that doesn't
have a previous Number One score."** So the sweep takes every mission that is

- at **Verify**, and
- has **no score on record** — `numberOne.score`, `numberOne.score2` or an
  `xo/verdict.json` on disk; all three are read, nothing is inferred —

and is not opted out (`lcars xo off <id>`), not a bug child (it has no build of
its own), and not another laptop's (a different `cloneId`). It says what it
picked up in plain words — *"I'm reviewing 3 missions that were waiting at
Verify: …"* — journals `swept` on each, and runs them **one at a time**.

**Standing it down stops the chain.** Both questions are asked again between
missions, so `lcars xo off` during a round ends the sweep after that round —
never in the middle of one. `LCARS_XO_SWEEP=0` turns the sweep off entirely;
`LCARS_XO_SWEEP_BIN` is the per-mission command a test drives it with.

**Each swept look is CAGED** at `$LCARS_XO_LOOK_TIMEOUT` seconds (default 2700 —
45 minutes, the benchmark rig's own limit). A look that outstays it is stopped,
said out loud naming the mission and the limit, and journaled as `sweep-timeout`
on that mission; the sweep then carries on to the next one. A stopped look has
scored nothing and never reads as a quiet success.

## The engine picker

It **names engines and nothing else**: `copilot` and `claude`, each *installed*
or *not installed*, detected through the one shared probe
(`lcars_engine_available`, `skills/lcars-init/lcars-common.sh`).

**There are no pricing words in this product — not "free", not "billed", not
"costs"** (captain ruling, 2026-09-11). Not everyone's situation is the
captain's, and a product that prices a choice for you is making the choice for
you. Do not add them to any surface, ever.

**No terminal and no `--engine` is a loud refusal**, the `lcars adopt`
precedent. Choosing an engine in silence *is* the defect; failing loudly is the
cure.

## The two records

Everything downstream reads these, and nothing infers them from prose — the
producer records, the surface displays.

**`.git/lcars/config.json` — the repo switch, ON ONE LINE:**

```json
  "numberOne": {"enabled": true, "engine": "copilot"}
```

**The engine is a real pin, not a label.** `numberOne.engine` is what Number
One's worker actually runs on: `xo.sh` exports it as `$LCARS_WORKER_BIN` with
`$LCARS_WORKER_BIN_INTERNAL=1` when it spawns the spin, and `run.sh`'s
`spawn-number-one` entry honours it ABOVE the Mission's own `workerBin`. The
Mission's `engineSource` / `engineResolved` / `workerBin` are left untouched —
those answer "why does this MISSION run on this engine", and Number One's engine
is Number One's. The captain's own `$LCARS_WORKER_BIN` still outranks the pin,
because it is per-invocation and unmistakably deliberate. (Fix round 1: the
engine was recorded and displayed and consulted by nothing, so a repo pinned to
claude spawned copilot while every surface said claude.)

One line is load-bearing twice over. `lcars_config_merge` preserves an existing
raw value only when it sits on a single line, and it **deletes** any top-level
key missing from `DESIRED_CONFIG` — so `numberOne` is listed in both
`lcars-update/update.sh` and `lcars-init/init.sh`. That second rule is the exact
failure S196 paid for with `cloneId`.

**`state.json` — the per-mission record, AT THE TOP OF THE FILE:**

```json
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "…", "note": "…"}
```

`status` is one of `engaged`, `finished`, `escalated`, `answered`,
`stood-down`. `optOut: true` means "never engage here". The key goes at the top
because a last-key corruption bug is latent in the state writers (the S189
rule) — keeping new keys off the end keeps it latent.

## When the driver calls it (S202)

`lcars run` engages Number One **once, at the top of a drive**, when the repo
switch is on and the Mission is not opted out (and never re-engages one the
captain stood down, nor overwrites one that is `escalated` while the gate it
handed back — the one whose cksum is in `lastPending` — is still up; once the
captain has answered that gate, the next drive re-engages and drops the stale
note). Engaging is the driver's act and only the driver's:
`lcars xo on` is a repo switch, and `lcars xo on <mission>` only returns a
Mission to scope — it clears the opt-out AND the `stood-down` status the
matching `off` wrote, leaving the Mission looking exactly like one that was
never stood down, so the NEXT drive is what engages it. It does not touch
`escalated`: that gate is still the captain's.

Every park in the pipeline lands on ONE line of `cmd_drive` — the awaiting halt
at the top of the loop — so the hook is there, not at the two dozen raisers:

* `numberOne.status == engaged` → `bash xo.sh answer --mission <id>`
* exit **0** → the gate is cleared; the loop goes round and the drive carries
  on. There is **no second driver**: `xo.sh` pins `LCARS_RESPOND_RESUME=0`, so
  `respond.sh` records the answer and returns instead of re-entering the driver.
* exit **1** → the driver halts at the gate exactly as it did before S202.

`--step` has its **own** arm. A Stage that finishes by asking has finished, so
the first officer answers there and the step **ends, cleared** — rather than the
gate falling through to the top of the loop, where auto mode would clear it and
then run a second Stage the captain never asked for.

**The same question is never asked twice.** An escalated gate is still a gate,
and the next pass would otherwise hire a worker to be told the same thing. The
driver **records** the `cksum` of the `pending.json` it acted on as
`numberOne.lastPending` — written BEFORE the spawn, so a crash mid-spin does not
buy a second one — and skips a gate whose pending matches. It is recorded, never
worked out afterwards from a journal or a comment.

`LCARS_XO_DRIVE=0` takes the hook out of the loop entirely.

## Number One's report — the living comment

`comment-mirror.sh` renders `<mission>/number-one.jsonl` into **one** issue
comment keyed `number-one`: status, engine, the last answer with the line that
grounded it, the escalation note, and the whole journal folded into a
`<details>`. It is CREATED once and **EDITED** thereafter — the S65 model,
unchanged; two answers are two lines in one comment, never two comments.

The one exception is an **escalation**, and it is S65's own exception: an edit
does not notify on GitHub, so a gate that has just become the captain's also
goes out through `cm_ping_gate` as a fresh comment (idempotent by its recorded
gate key, so a re-render never pings twice). That ping **replaces** the generic
"Awaiting your answer" one rather than joining it — one gate, one notification —
and with Number One off, or engaged but not escalated, the pre-existing ping
fires exactly as it always has. `lcars answer` prints the same note on the card,
read off `state.numberOne` — the inbox infers nothing.

## The engaged lock

While `status` is `engaged`, these refuse with **one sentence**:

```
Number One is engaged on this mission on your behalf — stand it down (lcars xo off <id>) to act yourself
```

`lcars approve`, `lcars feedback`, `lcars respond answer`, `lcars log`,
`lcars pause`, `lcars resume`, `lcars resolve-logs` — and the viewscreen's
matching endpoints, with a 403 carrying the same bytes.

`lcars run` and `lcars xo` are **exempt**: Number One's own actions go through
them, so locking them would lock Number One out of itself. `start` is likewise
absent from the daemon's set — an engaged mission is already being driven.

It is a **second reason on the existing owner-lock seam**
(`skills/lcars-run/ownership.sh`), not a new mechanism, and it keeps that seam's
posture exactly: every uncertain case proceeds (no state file, no key, an
unreadable value), one sentence pinned byte-identical everywhere, and
`LCARS_XO_ENFORCE=0` bypasses it for harness debugging.

**Number One's own hand is not a second hand** (S204 fix round 1, D1). Number
One acts THROUGH these very verbs, so without an exemption the lock refuses the
first officer's own `log.sh`, `resolve-logs.sh` and `respond.sh answer` calls —
and nothing it decides can ever be filed. `xo.sh` sets
**`$LCARS_XO_INTERNAL=<mission-id>`** on exactly those child calls, and
`lcars_xo_lock_reason` exempts a call only when the marker names the SAME
mission it is being asked to lock. It is the S207 `$LCARS_WORKER_BIN_INTERNAL`
shape (the producer states who set it), narrowed: Number One holding mission A
buys no free pass on mission B, and the captain's own `lcars log` on A is
refused with the same sentence as before. It is never set process-wide and never
exported to a worker. `LCARS_XO_ENFORCE=0` is NOT the cure — it switches the
lock off wholesale for everything the call spawns.

## The fix round (S204) — `file-logs` and `recheck`

A look that scores MEDIUM or LOW has found gaps. Number One does with them what
the captain would: it files an ordinary **mission log** for each one and lets
LCARS drive it.

**`file-logs`** reads `xo/verdict.json` and takes the gaps of kind
`contradiction` — the build disagreeing with something written down, with a
picture of it. An **interpretation** (a call the build made where the record is
silent) is never filed; it is on the report, as the captain's own call. The cap
is **ten**; an eleventh gap is journalled (`N more gaps not filed — cap 10`),
never dropped in silence. For each gap it writes a bug PRD under `xo/logs/`,
then makes **one** `lcars log` call in the shape `run.sh` already uses —
`--parent <id> --prd 1.md --attach shot-a.png --prd 2.md --attach shot-b.png` —
so each shot binds to its OWN bug by argument order. The parent's drawing is
**not** attached by hand: `log.sh` inherits a holodeck parent's mockup itself.
The child ids come back off the verb's own summary and land in
**`xo/logs.json`**, which is the only thing `recheck` reads to know what it
filed. Then `resolve-logs` is started detached, its pid in **`xo-resolve.pid`**.

**ONE ROUND ONLY** (captain's ruling). `numberOne.round` is set to `1` and never
incremented. A fix that does not hold goes to the captain, not to round two.

**`recheck`** runs when the consolidated re-verify gate comes up. It relaunches
the build from the parent branch (the children's fixes are on it), drives it,
and asks ONE worker the narrow question: **for each gap you filed, did its fix
hold?** Every fix holding is accepted through `respond.sh answer`, attributed to
`number-one` — which is what triggers `resolve-logs complete`'s fold of each
child to Done and the push of the parent branch. Anything that does not hold
leaves the gate exactly where it was, with the list beside it. The second score
is recomputed from the ledger by the same `xo-score.py` that scored the first
look, and `xo/report.md` becomes *after the fixes* with the first look folded
underneath it.

A child that **parked** blocks all of it — `resolve-logs complete`'s
completeness guard would refuse the whole batch — so `recheck` escalates
"log #n needs you" **before** spending a launch, a browser or a worker.

**AN ACCEPT IS FINAL (captain's ruling, S205, 2026-09-14).** Once
`numberOne.status` is recorded `finished` — the terminal state BOTH a clean
first look and a successful `recheck` leave behind — a further `recheck` is
**refused, verbatim, before a look name is even minted**: *"I've already
handed this one back — the PR is yours."* Wanting a fresh opinion after
changing the branch is a deliberate restart (stand it down, re-engage), never
a second call to `recheck` on a mission it already closed out.

**`recheck` FETCHES — it never trusts the local branch alone (captain's
ruling, S205, 2026-09-14).** Before relaunching, it fetches the mission's
branch from `origin` (best-effort — no remote, no network, or no recorded
branch never blocks the look) and fast-forwards the LOCAL branch ref when that
is safe (origin moved past local, no local-only work). When it cannot — the
histories have diverged, or origin is unreachable — it never force-resets (the
same data-loss `reconcile_sync_local_branch` in `run.sh` was written to stop);
it says, plainly, which commit it is about to look at instead. Either way the
captain never gets a confident "every fix held" against a branch this process
never actually looked at. See `xo_recheck_branch_report` in `xo.sh`.

### Which gate is this? The record says, not the prose

`resolve-logs.sh` writes `"kind": "reverify"` into the parent's `pending.json`
when it raises the consolidated gate, and `"kind": "reverify-blocked"` when it
re-raises it because the fold could not happen. **`xo.sh answer` routes on that
recorded field and on nothing else.** Matching the question's wording would be
the same defect this project has already paid for three times (S147, S156,
S188), and it is cured the same way every time: the producer records the fact,
the consumer reads it. The captain rewords gate prose freely; a matcher over it
eventually meets a question that contains its vocabulary.

## Standing down

`lcars xo off <mission>` **signals first, then records**: it TERMs the pid in
the mission's `xo.pid` (best effort — a stale pid file is not a reason to refuse
to hand the conn back, and nothing is ever KILLed, so a worker gets to finish
its own cleanup), then writes `stood-down` plus the note
`Number One stood down <time> · you have the conn`, and the lock lifts.

Standing down is an **action**, so it appends its own `stood-down` line to
`<mission>/number-one.jsonl` — the living comment's journal is otherwise the one
surface with no record that a spin was aborted. It also **clears
`lastPending`**: that cksum is stamped BEFORE the spin, so a worker killed
mid-spin would otherwise leave Number One locked out of a gate it never actually
read. The conn comes back, and so does the gate.

**It never stops the fixes.** `xo.pid` is Number One's own chain — its worker,
its browser, its launch. `xo-resolve.pid` is the `lcars resolve-logs` driver
working the logged bugs, and **those are LCARS's missions, not the first
officer's**: each has its own issue, its own branch and its own worker. That pid
is read and never signalled. When it is alive the stand-down note says so —
`Number One stood down <time> · N log/logs still driving · the re-verify gate will
wait for you` — because a captain taking the conn back mid-fix-round needs to
know both that the fixes are still going and that the gate at the end of them is
now his.

A repo-level `lcars xo off` does that for every engaged mission and flips
`enabled` to `false` — **keeping the recorded engine**, because the captain
turned Number One off, he did not un-choose his engine.

## Related

- `skills/lcars-run/ownership.sh` — `lcars_xo_lock_reason`, `xo-lock-reason`
- `skills/lcars-init/lcars-common.sh` — `lcars_engine_available`,
  `lcars_xo_default_engine`, `lcars_config_set_or_add_raw`, `lcars_config_get_raw`
- `skills/lcars-run/worker-adapter.sh` — the `number-one` role (both CLIs)
- `skills/lcars-run/run.sh` — `spawn_number_one`, `spawn-number-one`,
  `stage_key_for_role number-one → numberOne`, `drive_engage_number_one`,
  `drive_number_one_gate` (the `cmd_drive` hook + the `--step` arm)
- `skills/lcars-run/comment-mirror.sh` — `cm_render_number_one`,
  `cm_mirror_number_one`
- `skills/lcars-answer/answer.sh` — the escalation note on the inbox card
- `skills/lcars-respond/respond.sh` — `$LCARS_ANSWERED_BY` → `answeredBy`
- `tests/lcars-xo.test.sh`, `tests/worker-adapter.test.sh`,
  `tests/stage-model.test.sh`, `tests/lcars-respond.test.sh`,
  `tests/ownership.test.sh`,
  `tests/lcars-update.test.sh`, `web/tests/test_xo_lock_endpoints.py`,
  `tests/lcars-drive-xo.test.sh` (the driver hook — scoped, seconds, never the
  whole run suite), `tests/lcars-comment.test.sh`, `tests/lcars-answer.test.sh`
