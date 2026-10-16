# LCARS — Vision

This is the story of why LCARS exists, what actually happened while I built it
over a year, what I got wrong, and where it is going. It is deliberately not a
manual. [`README.md`](README.md) tells you what LCARS does and how to install
it, [`CONTEXT.md`](CONTEXT.md) defines every word, and each command explains
itself in its own `skills/<name>/SKILL.md`. Where this page touches the same
ground as those, it is here for the *why* — what was measured, what it cost to
learn, and what changed because of it. Go there for what the thing does.

Every number below is cited to the [`CHANGELOG.md`](CHANGELOG.md) entry that
recorded it, so you can check me. Where something is true but not yet in the
changelog, I say so and give you no number to lean on.

---

## I. How this started, and why

I kept having the same bad afternoon. I would have a clear idea, open a coding
agent, and get something that *looked* right in about four minutes — and then
spend the rest of the day working out whether it actually was. The generating
had become nearly free. The believing had not moved at all.

What I wanted was narrow and, written down, a bit obvious: **an idea goes in at
one end, a merged pull request comes out of the other, and I am only asked
something when a human genuinely has to decide.** Not a smarter chat window. A
pipeline, with stages, with artifacts on disk between them, and with my
attention spent only at the points where my judgement is the thing being bought.

LCARS has a name for that human: **the captain** — the person whose decisions
the pipeline exists to serve, who files the idea and gives the final yes. There is
Star Trek paint all over this project, and the captain is the one piece of it
that is load-bearing rather than decorative: every gate in the system is defined
by what it refuses to decide on the captain's behalf. I will use the word for
the rest of this page.

The first thing that worked was smaller than the idea. A single Mission went in
as a sentence and came back as a branch with tests on it, and I had not typed
any of it. That was enough to tell me the shape was real, and the first release
that carried the whole of it — Align through Verify, each stage running as a
cold isolated worker, on either supported CLI — is `2026.7.1` in the changelog.

### The shape the thesis took: a factory

Once there were stages and artifacts, what I had stopped resembling an assistant
and started resembling a **factory** — and the factory's vocabulary turned out
to be the product's, so learning one teaches the other. A **Mission** is the
work order: one intent, admitted at one end of the line. The **Stages** are the
stations it passes, each taking the previous station's output off the belt as a
file on disk and putting its own back, which is why a Stage that cannot write
down what it decided has not finished its part. A **Wave** is a batch of
**tickets** the line can run side by side without them fouling each other.
**Verify** is final inspection. The board is the floor: every work order visible
at the station it is standing at, which is the whole reason it is a board and
not a log.

Naming it that way turned out to matter more than the pipeline diagram, because
it decides where the real cost sits. On this line the machining is cheap and the
inspection is not. Writing the change is the cheap half now; deciding whether to
*believe* a change you did not write is the expensive half, and it does not get
cheaper because a test run came back green.

So almost everything LCARS has grown since then is a way of instrumenting the
line so that inspection can be quick and still honest: artifacts a later stage
can be audited against, gates that must show their work, photographs of the
running product, reports that are required to admit what they could not check.

---

## II. The year in turning points

Each of these is a point where a measurement told me something I had not
believed, and the intent changed because of it.

### July — the first long run alone, and the first lie

A twelve-ticket feature ran unattended for 2h14m and came back shipped, with
four logged bug fixes folded in (`2026.7.20`). I was pleased for about an hour.

Then the same release's post-mortem found three defects on that one mission, and
the detail that reorganised my thinking was this: none of them produced an
error, and two of them were *actively reassuring while broken*. A premise check
that was supposed to confirm a fix was really on the branch had been inverted and
had **never once run**, and every test that covered it passed vacuously
(`2026.7.20`). The same entry records, under "known, unfixed", that the cost
estimator undercalled that mission by roughly six times — $4.86–$25.47 estimated
against $150.07 actual (`2026.7.20`).

Two intents changed here. First: **a green suite is not evidence.** Second: ship
the known-broken thing with its name written down, rather than quietly. That
"known, unfixed" habit is why the rest of this page can be specific.

### August — a prose pin is not a mechanism

Four stages were documented as reading the Mission's own branch. The way that
was enforced was a sentence in a prompt. A live worker was measured ignoring it
(`2026.8.1`). The cure was structural — each of those stages now runs in a
detached worktree at the Mission's commit, so there is nothing to ignore.

The same lesson arrived again, harder, a few weeks later. Every cold worker was
described in code and in its own prompt as locked to a role. On one engine none
of it was true: the flag being used only *pre-approves* tools, so an inspector
documented as having no write access held it, and a read-only researcher held an
editor and a shell (`2026.8.7`). It had survived a year because a comment next
to the flag asserted a guarantee the flag did not deliver. The fences are real
now, proven with negative controls, and the false comments were deleted.

They are real only as far as a flag reaches, and the same entry says where that
stops: on one engine the path sandbox does not cover the scratch directory
workers actually write in, and five of six wrote there with no grant; the
Research fan-out agents run unaudited; and the one role that must hold a shell
cannot be fenced by any tool list at all, so what contains it is an isolated
worktree and a post-commit scope check rather than a fence (`2026.8.7`).

**If you only take one rule from this page, take this one: never fake the layer
you are changing.** Every expensive round I have had came from testing a real
change against a fake version of the thing it changed.

### August — the holodeck, and handing over a drawing

A paragraph is a poor way to specify a screen. The holodeck is a room on the
board where you talk a mockup into existence against your real project, see it
rendered live, and then hand the finished drawing to Align as a Mission
(`2026.8.3`).

![The LCARS holodeck: the programs list on the left, the design conversation in the middle, and the live-rendered mockup of a tile editor on the right.](docs/assets/holodeck.png)

The measurement that justified it was not about the pictures. Before the
holodeck, acceptance criteria that referenced a mockup were essentially
nonexistent; with the hand-off carrying the drawing and its change list into the
tickets, they went from 0/44 to 19/40 across that round, with the "judged at
Verify" deferral gone entirely (`2026.8.3`). The briefs got concrete because the
drawing made vagueness impossible to hide.

### September — the board stops belonging to a laptop

Until `2026.9.4` LCARS quietly assumed one operator at one keyboard. A Mission
lived in the machine that filed it. Making ownership a property of the *person*
— read from the forge, not from a second private answer that could disagree with
it — is what turned a personal tool into something a crew can share.

![Two LCARS mission cards side by side on the viewscreen: one in Implement marked REMOTE — DRIVEN ELSEWHERE, one in Verify reading "copilot — chosen at adopt", both carrying their owner's avatar and handle, above an ownership filter strip.](docs/assets/ownership-board.png)

Also in September, LCARS stopped requiring that your project already exist. It
could only ever work on a repo with a test runner, because every ticket is
proven by showing its tests red before the change and green after, and a project
with no runner cannot produce that proof. It was right to refuse, and useless to
anyone starting something new. Day zero landed in `2026.9.2`.

### September — Number One, and his first honest zero

Number One is a first officer who works the gates for you: he answers what he
can cite, escalates what he cannot, and at Verify he writes his checklist
*before* he opens a browser, then walks the build, photographs it, and scores
what he saw against what you asked for (`2026.9.7`).

![The First Officer's Report: everything Number One has looked at, grouped by mission, with the ones he is handing back to you beside his verdicts and the entries you can open.](docs/assets/number-one-report.png)

The honest part is the number he reports *about himself*. On three identical
looks he published a confident verdict over a review that was only 55–64%
checked (`2026.9.7`). That is why he is advisory and not a gatekeeper — a
measured position, not caution. It is also why every report he writes now has to
state plainly what it could not check, and only says so when that count is not
zero.

He got worse before he got better. A later round found he had been *inventing*
citations — a filename split into one citation per letter, a lookup table cited
by its own key, an empty entry cited as a file called "None" — and filing each
as a genuine fault against your build. A malformed screenshot reference used to
crash the review, write no file at all, and have that silence reach you as a
clean bill of health (`2026.10.2`).

### October — handing over the loop

The ECH is the point where you stop running the factory yourself. You hand it a
goal; it settles the scope with you in a single round, and from there it takes
one milestone at a time on its own (`2026.10.1`).

![The ECH's own status in a terminal: the spec it is working to, the missions in scope with their stages and gates, the parallel slots in use, and the one question it has parked for you.](docs/assets/ech-status.png)

The first night it ran unwatched is in here for what it settled, not for what
it produced. The question was never whether an unattended shift could produce
working software; it was whether anything it produced could be believed. Two of
its bug reports had come through a fully green suite (`2026.10.1`) — the kind
of finding that shows a shift inspecting its own work rather than merely
finishing it. Autonomy it did not settle: the last milestone's landing was mine
to run (`2026.10.1`), and nothing here claims a shift can end with nobody
there.

What makes the rest of it worth anything is not that it was clever. It is that
the evidence was first-hand — nothing in that night's report was a prediction
about the build, and every claim in it was something the ECH had watched happen
on the running thing.

A few weeks later, left running unattended with the authority to merge, it used
that authority to *refuse* a merge — on evidence, because the build could
silently lose data (`2026.10.2`). That is the stand-in doing the job you keep it
for, and it is the moment I stopped thinking of it as an automation.

### October — the factory builds the thing it reviewed

On 2026-10-15 and 2026-10-16 both engines were pointed at real private repos,
with real workers and nobody in the loop. Both took a product from nothing to
merged, every merge confirmed at GitHub rather than taken from a worker's own
report. Separately, a design made in the holodeck was promoted into a Mission,
and the line then built it on top of code it had itself reviewed and merged —
the floor finally running work it had produced, rather than work handed to it.

**These runs are not in the changelog yet**, so I am giving you no counts to
check here; they land with the release that carries them. They also produced
most of the open items in the next section, which is the honest half of it.

### Then and now

The same board, July and October of the same year:

![The LCARS viewscreen in July 2026: seven columns beginning at Validate, cards carrying a cost estimate and two difficulty pills but nothing showing what a run really cost, and no ownership strip or hologram controls in the band.](docs/assets/viewscreen-board-2026-07.png)

*July — seven columns, the first of them Validate, so the two stages before it
had nowhere to show. A card priced the work ahead and never said what it came
to. Nothing recorded whose Mission it was.*

![The LCARS viewscreen in October 2026: every stage column from Align to Done populated, an ownership filter strip, hologram and deploy controls in the band, and cards carrying actuals beside estimates.](docs/assets/viewscreen-board.png)

*October — every stage has a column, cards carry what the run really cost beside
what it was estimated at, the strip above filters the board by who owns what,
and the band carries the holodeck, the first officer and a deploy control.*

---

## III. What we learned, and what is still not right

### The rules that survived

These are the ones that earned their place by being expensive to learn.

- **Never fake the layer you are changing.** Changing what the board paints and
  testing it without a browser; changing a worker's behaviour and testing it
  with a stub worker — both of those cost me whole days. The cure is always the
  same: make the harness real at exactly the layer the change lives in.
- **A prose pin is not a mechanism.** If the only thing enforcing a rule is a
  sentence asking a model to follow it, the rule is a wish. Measured live, a
  worker ignored one (`2026.8.1`).
- **Measure, don't estimate.** Read the clock. Dump the artifact that was
  actually assembled. Count what the board really drew rather than inferring it
  from the fixture that fed it.
- **Found versus hedged.** A report must separate what it genuinely found from
  what it could not check, and a coverage gain is not a capability gain. A
  reviewer that hides its blind spots is worse than no reviewer, because it
  spends your trust without telling you.
- **A negative-existence claim is checked, not believed.** "This field does not
  exist" is the single most expensive sentence a planning stage can emit
  unverified (`2026.8.5`).
- **The stand-in is standing in for a human.** When its review misses something,
  the fix is to make the reviewer miss less — not to make the thing it reviews
  easier to approve.

### What does not work well yet

No hedging on this list. Each one is a real, current, reproducible problem.

**The cost estimate is wrong, and there is no spend meter.** The estimator
reads a spec and prices the run, and it under-reads what the run actually
costs. The last time that gap was measured and written down it was roughly six
times (`2026.7.20`), and it has not been re-measured since, so read the figure
on the card as a floor rather than a prediction. The diagnosis is now known:
it cannot see cached-token volume, and it cannot see the first officer's own
spend at all. Worse than the inaccuracy: **there is nowhere in the product that
shows you what you have spent.** Not on the card, not on the board, not in the
terminal. The holodeck records no cost at all. You find out from your provider.

**An optional logged bug cannot be declined.** If you log a bug against a
Mission and then decide it does not matter, there is no verb that closes it
unfixed. The only route to a clean board is to pay to drive it through the whole
pipeline. On an unattended run this is not merely annoying — it is how a loop
that files what it finds becomes a loop that cannot converge.

**Number One reviews a Mission once, and his floor is unfair.** He looks at
Verify, scores it, and that is the review; there is no second pass after you fix
what he found. His coverage floor also counts screens he could not reach against
the build, so a Mission that was never meant to have a user interface is marked
down for not having one. Both of those make a useful second pair of eyes read as
a harsher judge than it has earned.

**Plan Review oscillates, and it costs money.** Each review round gets a fresh
reviewer with no sight of the previous round's objection. So round one can
demand a ticket, round two can reject that same ticket, and round three can pass
the thing round two rejected — each round a real worker and a real bill. The
isolation that makes the audit honest is the same thing that makes it forget.

**Copilot is new here.** The whole pipeline runs on it and has driven ideas to
merged pull requests, but it has a fraction of the miles the Claude path has,
and its billing is counted in a different unit. Expect to meet an edge there
first.

**The test suite is a gate, not an inner loop.** It is slow enough that nobody
runs the whole of it while working, which means it only catches things at the
end, which means some things it would have caught got committed first.

---

## IV. Where it is going

**A board across repositories.** Today the viewscreen shows one repo. The
shared-board work is already laid — ownership, remote cards, taking a Mission
over — and the piece it deliberately did not take on is a registry of several
projects in one view.

**Copilot to parity.** Not just "it runs", but the same number of miles, the
same confidence, and cost shown in its own unit without a mental conversion.

**A spend meter, and an estimator that can see what it is pricing.** In that
order. Showing the true number is worth more than predicting it better.

**Number One's reach.** Re-review after a fix, a coverage floor that knows what
kind of thing it is looking at, and verdicts as repeatable as his observations
already are (`2026.10.2`).

**This round itself** — making the repo something a stranger can clone, install
with whichever CLI they happen to have, and understand in five minutes. That is
what you are reading the output of.

### Two things I tried and cut

**The anti-gutting guard.** Letting a worker edit an already-failing test opens
an obvious door: delete the test instead of fixing it, and the evidence looks
identical. I built four successive guards to close it, and five adversarial
review rounds beat every one at a new token. Round five then caught a guard
*false-failing an honest repair*. So about a thousand lines of source parsing
were deleted for one source-blind check — the runner may not execute fewer tests
than it did before — and repairs are made visible to you at Verify instead
(`2026.7.19`). What remains is called a screen, not a proof, in every place it is
described.

**The prohibition-carry check.** A check that a prohibition written into the
plan must survive into a ticket. It was removed after three rounds, each of which
traded one failure for another: its noise floor had been measured on missions
from a single repo, and the first ordinary Mission it met produced a false
positive by reading a test-coverage bullet as a prohibition (`2026.8.5`). The
defect it was built to catch is real and reproduces, so the evidence is kept and
the false positive is kept as a regression test the next attempt has to clear.

### The stance

LCARS is not a finished artifact and is not meant to read as one. The way it has
got this far is that things which *kind of* work get shipped with their flaws
written down, used in anger, measured, and then changed because of what the
measurement said rather than because of what I had already drafted. Everything
in the section above will move. Some of it will move because somebody reading
this page hits it before I do.

---

## V. How to be part of it

Issues and pull requests are welcome, and so is being told that something on
this page is wrong. [`CONTRIBUTING.md`](CONTRIBUTING.md) is the short version of
how the code is built — command source lives in `skills/<name>/`, every command
has a test, the failing test is written first — and
[`CLAUDE.md`](CLAUDE.md) is that same contract written for an AI agent, because
most of this repo was built by one working under it. If you want to understand a
decision rather than a command, [`CHANGELOG.md`](CHANGELOG.md) is the honest
record: every release says what was proven, and what shipped knowingly broken.
