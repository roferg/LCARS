# Changelog

All notable changes to LCARS are recorded here, newest first. The version
scheme is `YYYY.M.N` (calendar year, month with no leading zero, per-month
counter). Every PR into `main` bumps `VERSION` and adds its entry here.

## 2026.10.6 — 2026-10-30

The open-source round. Twenty-plus sessions of fixes found by driving real
work hands-off, plus the vision and README rewritten for a stranger.

### preserve concurrent Mission commits at startup (S338)
The off-checkout Mission fast-forward now compares-and-swaps the tip whose
losslessness was measured, rather than force-moving the branch. A concurrent
commit makes publication refuse with inspection/retry guidance, even without
reflogs. Checkout registration is rechecked before publication. Existing
own-commit refusals, successful output, and S336 recovery are unchanged.

### self-heal can merge an advanced base (S336)
Implement self-heal now merges a newer base into a Mission carrying its own
commits, then continues through the existing shared re-test gates. Recovery
preserves both tips, refuses concurrent tip replacement, and never rewrites
published history. Dirty trees, unfinished operations, checked-out Mission
branches and conflicting merges still stop for a human. The startup helper's
lossless-fast-forward refusal and Verify-only reconcile command are unchanged.

### honest all-undrawn tickets (S335)
A screen-changing ticket whose criteria are all `notDrawn` or `notVisual` no
longer needs a fabricated `drawnAt`. Every criterion still requires exactly one
valid declaration; undrawn reasons remain mandatory and appear with their
criterion text at Verify. Drawn anchors still require a real drawing element,
and Plan Review still audits false non-visual claims.

## 2026.10.5 — the holograms, and a first commit worth keeping

Start a new project and its first commit is clean. The greenfield foundation
now writes a stack-appropriate `.gitignore`, and if you already have one it
asks **git** which rules you are actually missing and adds only those, in a
dated block marked top and bottom that you can delete in one gesture. Your own
lines stay exactly as you wrote them — and if you deliberately un-ignored one
file inside an ignored folder, that exception survives (S298).

A file that only *looks* like test configuration stops counting as a test
system. A `Makefile` target with no recipe, an empty `tests/run.sh`, a
`package.json` test script that is a shell no-op — none of them can satisfy the
gate any more, and the refusal names the file and says why it runs nothing. The
terminal, `lcars update --fix-tests` and the viewscreen now all tell you the
same story in the same words (S299).

An unattended run asks what it needs while you are still there, and will not
hang when you are not. With no terminal it prints the question it would have
asked and the value it is proceeding on, or stops on a question it records for
you — one that settles when you answer it and withdraws itself once the cause
is fixed. It now checks the things that actually killed overnight runs:
`COPILOT_ALLOW_ALL`, a forge login, and whether your remote genuinely answers
rather than merely having a name (S300).

`lcars-buddy` is now **`lcars-eeh`**, the Emergency Engineering Hologram that
rides along with you, and `lcars-autopilot` is **`lcars-ech`**, the Emergency
Command Hologram you hand the loop to. Each announces itself. Nothing else
changed — proven by diffing twenty-four verb pairs old against new (S301).

And an escalation is a question you can answer rather than a wall to scroll
past. The card tells you *which* decision is waiting and how much more there is
to read; the full text, its options and the answer box now sit together in one
place. Previously the options were only legible on the card *behind* the box
you were typing into.

## 2026.10.4 — release Number One's stop after merge

Successful approval and GitHub-merge detection now release only the mission
and child pauses owned by the completing mission's `xo-stop` record, then
remove that record. Captain-owned pauses remain untouched. A paused Verify
mission can detect an already-merged PR without starting work; unfinished
stand-downs and failed merges keep their pause and marker.

## 2026.10.3 — public-project contribution and safety contracts

Completed the human contribution guide alongside the AI-agent build contract.
Added a security policy describing private reporting and the command-execution
and directory-trust risks, a Contributor Covenant-based conduct policy, default
code ownership, bug and idea templates, and a PR checklist for scoped proof and
release metadata. Private contact placeholders still require owner configuration.
A fast public-project guard now checks that these files remain substantive.

## 2026.10.2 — the stand-in gets its reach back

**Your buddy can now do what you'd do, instead of stopping to ask you to do it.**
When LCARS refuses something and its own message names the fix, the buddy runs
that fix, writes down that it did and why, and carries on — it only comes to you
when the cure isn't named or would cross one of its nevers. And its step chooser
now reads the repository instead of only its own notes, which is what was making
a permanent feature feel less capable than prompting the buddy by hand: the
playbook already knew what to do, the chooser was walking straight past it. Six
branches that were unreachable or simply wrong are now reachable, each one
measured before it was fixed.

It showed up live this round. Left to run unattended, the buddy agreed the scope
itself, took the authority it had been given — and then used that authority to
*refuse* a merge, on evidence, because the build could silently lose data. "Being
blocked is uncomfortable, not a reason." That is the stand-in role doing the job
you keep it for.

**And Number One stopped lying about what it saw.** A malformed screenshot
reference used to crash the review, write no file at all, and have that silence
reach you as a clean bill of health. Worse, it was *inventing* citations — a
filename split into one citation per letter, a lookup table cited by its key, an
empty entry cited as a file called "None" — and filing each as a genuine fault
against your build. Both are gone. Your report now also admits the steps it kept
and never ran, and the checks it passed without ever taking a photograph, and
only says so when the count isn't zero.

**The factory builds small projects again.** Four setup gates were turning away
work that was correct: a project with nothing to install had no way to say so, a
gate rejected the files its own test run creates, a brand-new file was read as
modifying something that doesn't exist, and the test-runner detector guessed from
a config file's presence rather than evidence. A plain standard-library project
now goes end to end — planned, built, fixed, reviewed, with passing tests.

Measured this round: asked to review a build nobody had briefed it on, Number One
found a concurrent-write bug by *running* the attack — twenty simultaneous writes,
all reporting success, five surviving. Its findings also proved perfectly
repeatable across two reviews of identical code, while its final verdict did not,
so judgement is the next thing to work on rather than observation.

## 2026.10.1 — hand the factory over

**You can now hand the loop itself to the buddy, and get your attention back.**
Give it a goal, agree what to build in one round, and it drives the rest —
planning, implementing, checking, fixing, filing what it finds — coming back only
when it genuinely needs you. The repetitive middle of the pipeline stops being
yours to run; what you keep is deciding what to build, and the final yes.

On the run that proved it, it built a working product from a goal — a command
line, a page that renders its state, and a CI workflow that republishes that page
— and merged every piece. It **needed you exactly once** across the whole night,
the opening round where it agreed what to build, and it answered two later
questions itself rather than spending you on them. One step is still yours: on
the final milestone, a human ran the landing.

**What makes handing it over reasonable is that it works with evidence.** At the
end of each job it *uses* what it built — against a checklist for that kind of
thing, whether a command line, a web page or a CI workflow — and records what it
actually saw under that job's own state: transcripts, screenshots, the artifact
it downloaded and read back. That is how it caught **two real bugs your fully
green test suite had passed**: `list` breaking its own "one per line" promise
when a request contained a line break, and filing a request crashing with a raw
error while silently storing a blank source. Both were filed with reproductions,
fixed through the ordinary verbs, and re-proved on deliberately different data.
When its browser check found nothing, it said so rather than inventing a finding.

**Tickets now declare their seams and their entrypoints.** Six live bugs once
shipped past a green suite in a single weekend, and every one sat at a seam —
two code paths touching the same state, with the suite only ever driving one
side. So a ticket now records, as two arrays, what writes state another path
reads, and which files CI really runs, each naming a test **and one sentence
saying how that test drives both real halves, or runs the file the way CI runs
it**. Nothing infers them from prose or scans a diff for them: the planner
records them and the reviewer audits them, rejecting a sentence that describes a
stub.

**Smaller things you will notice.** A question has one home — `ask` is the verb
and the pending list is derived from it, so a hand-written question can no longer
be hidden by another open one. A plan whose final anchor check fails now **parks
awaiting you**, naming the failing tickets and the valid anchors, instead of the
stage dying underneath you. Commit subjects are readable again rather than
carrying an entire report on line one. And a PR description no longer loses every
wrapped paragraph after its first line — which had been quietly damaging the half
written for humans while the machine-written half survived intact.

## 2026.9.8 — approve lands on its own

**A bug you logged against a Mission no longer blocks the merge it belongs to.**
Over the Canvas weekend `lcars approve` refused **three** merges that were fine:
each was a Mission whose logged bug had legitimately changed one of the Mission's
own tests *and declared that it had*, and each landed only because you hand-merged
it. The allow-list only ever looked at the parent Mission's own tickets, and a
logged bug is its own Mission, so its declaration was invisible. It is visible
now — and an **undeclared** test change still blocks, in exactly the same words.
A refused merge also stopped leaving a half-finished `reconcile.XXXXXX` folder
holding the Mission's branch, which is what made the *next* attempt fail too
(S231).

Missions filed before this shipped still merge: a folded bug carrying none of the
new bookkeeping is recognised from the fact that its commits are genuinely in the
Mission's history, and LCARS **writes down** that it fell back to that reasoning
rather than doing it quietly.

**And approve stopped doing three things behind your back** (S232):

- **It refuses to merge a Mission whose logged bugs are still unfinished**, naming
  each one by title and the Stage it is stuck at, and telling you the one command
  that clears it. Before, it merged first and warned afterwards — so the bugs'
  fixes were left outside the pull request, and once a Mission is Done its bugs
  can never be attached to it again. There is deliberately no `--force`. Blocked
  at every door: `lcars approve`, `--reapprove`, and `lcars answer approve`.
- **A test command you set by hand survives.** An initialization Mission used to
  overwrite `testCommand` with whatever its worker declared — on the weekend that
  replaced a working `python3 -m unittest …` with an uninstalled `pytest`. Now an
  existing value is kept, the declared one is filed on the Mission as
  `declaredTestCommand`, and approve prints which it kept, why, and the
  `lcars update --test-command` line if you ever want to switch. Only an absent
  value is filled.
- **Answering a question no longer claims to resume a Mission that is already
  running.** The driver records itself while it works, so `respond` and the
  auto-advance both see it, tell you it is already going, and start nothing. A
  crashed driver leaves a stale record, which counts as none, so it cannot wedge
  a Mission.

**If a Mission record on disk cannot be read, approve now stops rather than
merging past it.** Because only a bug records its parent, an unreadable record
cannot be attributed, so ambiguity refuses and names the exact file to repair.
Two exemptions keep that from becoming a nuisance: a Mission that has already
finished does not block, and an ordinary Mission is untouched.

## 2026.9.7 — Number One, the first officer that reviews your build

**You can hand a Mission to an AI first officer and walk away.** `lcars xo on`
engages **Number One** for a repo — off by default, and the engine you pick is
recorded rather than guessed. Engaged, it works the gates you would otherwise sit
and wait for: when a Stage escalates it reads the Mission's record in a read-only
copy and either answers through the ordinary `lcars respond` (attributed
`answeredBy: number-one`, so the record always says who decided) or escalates with
a recommendation and leaves the gate standing. It always escalates a scope
question, an answer it cannot cite, and anything malformed.

**And it looks at what got built.** At Verify it writes its checklist *before* it
opens a browser — your acceptance criteria, the plan's per-ticket criteria, the
drawing's place names — then launches the build, walks it headless, photographs
it, and scores whether it matches what you asked for. Appearance is judged on one
rail and behaviour on another. Screens that need data to exist can be seeded from
a `verifySeed` command or a `.lcars/verify-seed.sh` your project ships; with
neither declared nothing is invented — those rows read *couldn't check* rather
than becoming a fault in your build. `lcars xo report` is the First Officer's
report since you last looked, and `lcars xo off` hands the conn straight back.

**Number One is advisory, not a gatekeeper — deliberately.** It reviews and
recommends; you still ship. That is a measured position, not caution: on three
identical looks it published `high` over a review only 55–64% checked, and it
cannot yet always tell when it photographed the wrong screen. It is a useful
second pair of eyes that names real blockers, and the docs now say exactly that
(S201–S228).

Also in this release: **the test rigs have left the product repo.** 3,913 tracked
files and 109 MB of recorded run output are gone from the clone you pull — the rig
scripts now live in `lcars-dev`, the shared equipment that shipped suites actually
need lives in `tests/lib/`, and a closed-inventory gate refuses to let either back
in. And Number One finally appears in `README.md`, `vision.md` and both `docs/`
pages, which had never mentioned it.

## 2026.9.6 — lcars buddy improvements

**`lcars buddy` now fixes LCARS the way a session does** — it briefs you first,
refuses to start on a checkout that is dirty or mid-round, works on its own
`fix/<slug>` branch, has a fresh tester check the result, stops after three
attempts instead of flailing, and reads out what it did. The rules it follows now
live in one file that `buddy`, `run-session` and `night-watch` all read, so they
cannot drift apart.

Also: `LCARS_INSTALL_PREFIX` gives you a genuinely isolated install in one
variable; buddy's install check can no longer report "in sync" on a partial
install; and the version check can no longer block a test run.

## 2026.9.5 — launch works on copilot again

**`lcars launch` (and the viewscreen's launch button) runs your Mission's app on
copilot again.** Since the worker fences landed (S168), every copilot launch
failed with "the inspector reported nothing back": the inspector that works out
how to start your app ran on copilot's default model, which has no tool to write
its answer. It read your `package.json`, knew exactly what to run, and had no
way to say so.

The inspector now gets the same write-capable model every other copilot worker
already gets (the S194 floor): `claude-opus-4.8` unless you pin one — your
`LCARS_WORKER_MODEL`, config `workerModel`, or `modelAliases.copilot.opus` still
win, in that order. Claude launches are unchanged. No daemon restart needed; the
next launch click picks it up.

## 2026.9.4 — one board, every laptop

**A Mission now belongs to a person, not to a laptop.** Until this release
LCARS assumed one operator at one keyboard: the board showed your Missions,
your machine held the only copy, and a Mission that started on the desktop
stayed there. That is over. Every card says whose Mission it is, you can see
Missions running right now on machines you do not have, you cannot drive
someone else's by accident, and when one needs to change hands you take it over
deliberately and on the record.

**LCARS is now set up to support multiple people. The full build-out of that is
what comes next** — so far it has only been run against one GitHub account
("someone else's Mission" has been exercised with planted owner data, not yet a
second human), and two people acting in the same moment is deliberately still
ahead. The foundation is laid and working; the rest is the next round.

What changed, concretely:

- **Whose Mission is whose.** Identity is the (host, login) pair, never a
  machine and never a numeric id — so the same login on github.com and on a
  GitHub Enterprise host is correctly two different people. Your Missions wear
  a solid owner pill, someone else's a hollow dashed one, so ownership survives
  a greyscale screenshot and colour-blindness rather than living in hue alone.
- **A light lock, enforced on both surfaces.** You cannot start, pause, answer,
  log against or approve someone else's Mission. Not a greyed-out button: the
  daemon refuses ten verbs outright and the command line refuses them too, with
  one byte-identical sentence everywhere. Unassigned is never locked, and an
  identity LCARS cannot resolve never locks you out of your own work.
- **You see work you do not hold.** A Mission with no local copy still appears
  on your board, read from the forge, showing its real stage — so a second
  laptop watches a pipeline advance without touching it.
- **`lcars adopt`, and an Adopt button that asks.** Take a Mission over at
  Align or Verify. The viewscreen now asks which engine should drive it here —
  because a laptop may only have one CLI installed — defaults to the one the
  Mission was filed with, and records that a human chose, so the card says
  `chosen at adopt` rather than guessing later.
- **Two laptops can no longer collide.** Mission names were counted per clone,
  so two machines filing on the same day minted the same name — and adopting
  the second silently destroyed the first, merge record and all. Names now
  carry a per-clone fingerprint; existing Missions keep theirs untouched.
- **Your billed CLI stops winning by accident.** A clone's local config used to
  outrank the engine a Mission was filed with. The Mission's own engine now
  wins, and the card shows which engine is running and where that choice came
  from.
- **Filter the board** by mine, someone else's, unassigned or remote, on the
  `o` key — costing no extra call to GitHub.
- **Small things that were lying.** A pending avatar left a hole in its pill;
  it now beams in and collapses honestly if it never arrives. A filter count
  disagreed with the cards on screen. A merged Mission kept offering to review
  its own pull request on the laptop that filed it.

Sessions 188–191 and 196, plus four defects that only real two-laptop runs
could find. Proven on cold clones against real GitHub with live pipelines and
real merges; every visual claim measured off pixels in a real browser.

## 2026.9.3 — the launch link tells the truth

**When you click RUN, you get the app you asked for.** Until this release the
URL on a Mission's card was a *guess*. The launch inspector predicted where your
app would listen, LCARS wrote that prediction down, and nothing ever checked it.
That is fine right up until you have two repos open — and then it is not. Run two
viewscreens, deploy both apps, and the second dev server quietly takes the next
port because the first one is holding 5173. LCARS still shows the number it
guessed. It even "confirms" it, because something IS answering on that port: the
*other* repo's app. Click through and you are looking at the wrong product, from
a board whose data was correct the whole time.

**LCARS now looks instead of guessing (session 187).** After your app starts,
LCARS walks that launch's own process group, finds the socket it actually bound,
and writes down where the app really is. Dev servers that bind late are caught —
it watches across the whole startup window rather than glancing once. The
original prediction is kept beside the verified answer rather than thrown away,
so the record is honest about both, and when they disagree the readout says so
plainly and carries on: the app is fine, the guess was wrong. If nothing in the
group is listening at all, you get an empty link and a sentence explaining why,
instead of a confident link to nowhere. The readiness probe now checks the
verified address too — it was the probe hitting the neighbour's server that made
the wrong answer look right.

**A second viewscreen refuses politely.** Starting another plain `lcars
viewscreen` while one already holds port 8765 used to end in a raw Python
traceback. It now exits with one line naming the port, who is holding it, and
the two ways forward — `lcars viewscreen --open` for a free port, or `--port N`
to pick your own.

**Why this hid for so long.** Every launch fixture in the test suite was a sleep
loop that bound no port at all, so no test could tell a right URL from a wrong
one. The suite now launches processes that really listen, and the exact two-repo
failure is a permanent regression test: it watches the neighbouring app's request
counter and fails if LCARS ever touches it again.

## 2026.9.2 — greenfield supported: LCARS can start a project from day zero

**You can now point LCARS at an empty folder.** Until this release the pipeline
could only work on a repo that already had a test runner — every ticket is proven
by showing its tests red on the parent commit and green on the tip, and a project
with no runner cannot produce that proof. LCARS was correct to refuse, and
useless to anyone starting something new.

**Establish Vision (sessions 183–184).** On a repo with no foundation the
viewscreen no longer shows an empty board; it shows a door. You describe what you
want in a sentence, LCARS reads whatever is actually in the repo, asks a few
questions one at a time, then recommends a stack **and says why** — in terms of
what you told it. Features you mention that are not the foundation are recorded
by name and deferred, not dropped. Nothing is filed until you accept a
recommendation you were free to refuse. The rule is narrow on purpose: the door
replaces the board only when the repo is foundationless **and** has nothing to
put on the board, so a repo with missions in flight keeps its board.

**The initialization mission (session 185).** Accepting files a Mission that runs
the ordinary pipeline hands-off and builds a running skeleton, a real test runner,
and one thin vertical slice proving both are wired together. Its **first ticket —
and only its first** — may finish without a flip-flop, because it is the ticket
that creates the runner there was none of; the waiver records a reason and
surfaces at Verify, and is read from wave order so it fails closed. Every later
ticket faces the real gate. At approve the repo **graduates**: the established
test command is promoted into repo config, normal missions unlock, and the
holodeck opens.

**Every stack the classifier knows (sessions 186, 193).** Per-arm foundation
recipes, and two honesty gates that were misreading true signals as false: a Rust
library crate's empty doc-test scoreboards read as "zero tests collected", and a
correct Python fail-first red read as a dead runner.

**Choose your engine (session 195).** The same screen asks which CLI drives the
project — Claude Code or GitHub Copilot. Only engines installed on your machine
are offered; the choice runs the conversation *and* every stage of the Mission it
files, and becomes the project's default.

**Two bugs that made day zero impossible, both found by driving it (session 194).**
Copilot's default model has no file-writing tool, and every cold worker's entire
output is a file it writes — so any worker LCARS spawned without naming a model
was hired, reasoned, reported what it "wrote", and left nothing on disk. LCARS now
never hands a Copilot worker the default model. And the failure was silent: a
best-effort guard could not catch `die`'s exit, so the Implement stage died having
printed 52 bytes; the reason is now carried, so the board names *why*. A refused
scaffold ticket also now retries with the refusal reason fed back instead of
parking terminally with circular advice.

Also: a greenfield Mission can open its own pull request (an empty array expanded
under `set -u` on bash 3.2 crashed every one), and the vision panel names Electron
instead of calling it "JavaScript / Node".

**Proven live, not just unit-tested.** A `git init` folder with no commits and no
context file reaches a working, tested app end to end on real workers, verified by
hand outside LCARS and shown to be discriminating. **JVM is NOT proven** — there
is no JDK detection arm, so a Java/Kotlin project cannot yet establish a
foundation this way.

## 2026.9.1 — the plan stops lying about what waits for what

**Wave serialization (session 181).** A 12-ticket mission was scheduled as
**12 waves of one ticket** — about 130 of its 160 minutes spent in Implement,
roughly 2–3x the honest wall clock. The scheduler was never at fault:
`compute_waves` is a correct layered-Kahn, and empty dependencies with no
infrastructure flags provably yield ONE wave. The inputs were dishonest.

Measured live on unchanged `main` before anything was changed — 9 draws, 108
tickets, three briefs (`tests/drives/s181/BEFORE.md`): the Plan worker authors a
**linear dependency chain on its first pass**, reproduced 2 of 3 draws. The
competing theory is dead — the planner set `establishesSharedInfrastructure:
true` **zero times in 108 tickets**, so a blanket of trues cannot have caused it.
An older ledger entry blamed a field named `dependsOn`, which appears **zero
times** in LCARS; the schema key is `dependencies`, so that diagnosis was void.

The planner said why it chained, in two different voices: *"preserving
top-to-bottom order"* (page order mistaken for a dependency) and *"chained on
t-004 for shared-file serialization"* (file contention mistaken for one).

- **One definition of a dependency, on all three surfaces.** The "what a
  dependency IS / two tickets adding into the same shell are SIBLINGS" framing
  existed only on the revision path, behind a file-exists check, so a first pass
  never saw a word of it. It is now one shared block fed to the first-pass Plan
  prompt, the revision contract, and **Plan Review** — which was measured telling
  a planner to *"chain the section tickets via dependencies"*, the exact edge the
  planner had just been told not to declare.
- **Shared-file safety is not a dependency, and now the prompt says why.** The
  harness already composes same-file sibling edits: green tickets replay in plan
  order and only a real collision rebuilds on the tip. Declaring the edge pays
  full serial wall-clock up front for a guarantee already owned. The S156 line is
  drawn explicitly — a ticket that CREATES what another builds ON TOP OF is still
  a real edge.
- **Calibrated infrastructure guidance**, with the `true` list winning wherever
  the lists overlap and **"serialise when unsure"** stated as the general
  tie-breaker.
- **A dependency-queue signal** routed to Plan Review, with provenance and an
  events marker. Soft by construction — never a rejection; a flagged plan still
  saves, advances and schedules.
- **The serial warning names its cause** — a declared queue, declared
  infrastructure, both, or an honest "could not attribute" when it cannot tell.

**A latent blind-sibling bug, found on the way and fixed by ruling.**
`parse_plan_table` read `dependencies` only from the line the key sat on, so a
pretty-printed array — what a default JSON dump produces — made Schedule
**silently discard every dependency** and build every ticket in one blind wave.
That is the failure class the wave-isolation round exists to prevent, inherited
and reproducing on `main`. Fixed by mirroring the accumulator S174 already added
one function above; `validate_plan_json` carried the identical defect on the same
field and moved with it (it now sees ids it previously could not, so it can only
reject more, never less).

That also cured this round's own worst defect: the new signal parsed plans with
`json.load` while Schedule parsed with awk, so on a pretty-printed plan it told
the reviewer *"Schedule will build 12 waves"* while Schedule built **one**. Both
now read through `parse_plan_table`, and the detector calls **`compute_waves`
itself** — so the signal and the scheduler cannot disagree, and a queue with an
integrator tail is no longer invisible.

**Measured result** (`tests/drives/s181/AFTER.md`), same fixture, live:
**2 of 3 draws chained → 0 of 7.** Controls held — an independent plan stayed
wide, a genuinely serial pipeline stayed 12 waves, and a greenfield scaffold
ticket kept its infrastructure flag 5/5. Best draw: challenged about a shared
registry, the planner **invented one foundational ticket** and hung twelve
siblings off it — 2 waves instead of 13.

**The reviewer was checked for damage, not assumed safe.** Teaching it "siblings
share a wave" could have made it soft on genuinely missing edges, so two plans
with one planted defect each were fed to both builds: **8 of 8 caught**, and the
new reviewer explains itself in the new terms — *"it READS the formatCurrency
module"*. Not blunted; slightly sharper.

Suites: wave-serialization **173/0** (new) · wave-isolation 131/0 ·
plan-validator 130/0 · replan-overcorrection 166/0 · slice-pressure 10/0.

Known blind spots, stated rather than papered over: every live draw was
**Copilot**, so a live Claude planner is unproven; **Implement was never
entered**, so the wall-clock saving is inferred from wave shape and not observed;
and the rates are small samples of a defect measured to be a lottery. Open and
unruled: whether a design-token stylesheet counts as shared infrastructure — the
planner flags it both ways and the reviewer accepts both.

## 2026.8.7 — the role fences are real

**The worker fence (session 168).** Every cold worker LCARS spawns is described
in code and prompts as locked to a role. On claude none of it was true:
`--allowedTools` only PRE-APPROVES, and `--dangerously-skip-permissions` waives
what is left to ask about, so the `launch` inspector documented as having "NO
Write/Edit" held both, and a Research worker held Edit and Bash.

- **Deny lists (claude).** Every role now carries `--disallowedTools`, the flag
  that actually refuses. MEASURED live with a negative control: at the `default`
  role the worker reported the Write tool disabled and no shell to substitute,
  and wrote nothing, while the same argv with the deny list stripped wrote the
  file. Bash denial proven at `launch` and `repo-read` on both engines.
  The copilot argv is byte-for-byte unchanged (`--available-tools` is already a
  real restriction there) apart from the one intended `launch` change below.
- **`launch` swapped its shell for a pen.** It held `Bash` and no `Write`, so it
  wrote its one artifact via a shell inside a checkout of your code while its own
  prompt said "inspection only". It now holds `Write` and no shell, on both
  engines. Discovery still works — proven live.
- **A narrowed grant.** Cold workers were handed `--add-dir` on the whole
  `.git/lcars` store — every mission's state, including the state that judges
  them. They now get their own mission dir and the context pack. A worker on
  mission A cannot reach mission B.
- **A post-turn audit**, because on claude no flag can fence a role that must
  hold a pen: `Write` is not directory-scoped, so a `repo-read` worker with a
  legitimate pen can write anywhere — measured, it did. The judge-critical
  mission state is hashed before and after every non-`repo-write` turn, and the
  front-half worktree's `git status --porcelain` is diffed against a baseline
  taken just before the turn. A change is a `worker_fence_breach`: named files,
  stage stopped, never silently repaired.
- **False fence comments deleted**, in `worker-adapter.sh` and `run.sh`. A
  comment asserting a guarantee the flags do not deliver is how this survived a
  year.

**Named, not fixed** (`tests/drives/s168-runs/LEDGERED.md`): copilot's path
sandbox does not cover `$TMPDIR`, where worker scratch dirs live (5 of 6 wrote
there without a grant; 0 of 5 elsewhere); the Research fan-out agents run
mission-less and are unaudited; and `repo-write` keeps a shell and is not
fenceable by any tool list — its containment is the isolated worktree,
declared-edits and the post-commit scope check.

## 2026.8.6 — 2026-08-30

**Count the hires, not the swings.** Session 173. Every Implement surface used
the word "attempt" for two different quantities, and gave the headline to the one
that governs nothing. A ticket going green read `green in 4 attempt(s)` — the
worker's OWN internal iteration count, uncapped and informational since S133 —
while the number that actually decides whether the captain is interrupted (how
many times LCARS cold-spawned a fresh worker, capped at 3, exhaustion parks the
ticket awaiting-human) was folded into a chip wearing the same word. A clean
first-try ticket read as though it had been retried three times.

Found live on a DX-Scorecard Mission: the wave band said `↻ 1 attempt` while the
ticket line said `green in 4 attempt(s)`. Both correct, counting different things.

### One word per quantity

**HIRE / worker session** — one worker dispatch, capped at `MAX_WORKER_TRIES`.
**BOUNCE** — a gate rejection that costs a hire. **ITERATION** — the worker's own
`result.json.attempts`, forensic only, on no healthy-path surface. **"attempt" is
retired from every captain-facing string.**

A ticket green on its first hire now reads `ticket t-001 green` — no number at
all. One that struggled reads `green after 2 worker sessions`. Silence when
nothing went wrong; signal when it did. The same vocabulary lands on the Verify
roll-up, the terminal echo, the comment mirror and `lcars status`.

### The board shows the number that governs

The wave band gained a red **bounce** chip — the "something went wrong" signal,
previously invisible — and now OMITS the session chip at ≤1 hire, so a wave where
every ticket landed first try wears no counter. `lcars status` gained glyphs and
indentation for `ticket_gate_bounce`, the `flip_flop_*` family,
`ticket_postcommit_ok` and `ticket_test_edits`, which previously rendered
flush-left and unmarked; its pace line now carries `· hire N · N bounces`.

### One key, one quantity — and one derivation

The colliding `attempts` event-data key is split into `sessions=` (hires),
`iterations=` (the worker's count) and `emptyOutputTries=` (empty-output retries,
which are REFUNDED against the cap and so are not hires). A repo-wide grep proved
no consumer read the old key — a free rename, no deprecated alias. Nine emit
sites were reclassified, not four: `ticket_env_unprovisioned`,
`ticket_locked_test_tampered`, `ticket_postcommit_red` and `ticket_postcommit_ok`
were all carrying the ambiguous key too.

Three surfaces derived "hires" three different ways and disagreed on the same
ticket. `ticket_hire_count()` filtered `phase=tdd` and then FLOORED AT 1 — so
every pre-S133 ticket counted zero hires and the floor rewrote the zero as one,
a function asserting a number it had not counted. The mirror and `lcars status`
took the MAX `attempt` VALUE, wrong in both directions (two dispatches both
stamped `attempt=1` under-count 2→1; a gapped `1,3` over-counts 2→3). All four
surfaces now share ONE rule: **hires = the count of `ticket_attempt` events, any
phase; zero events means UNKNOWN, and the surface stays silent** — never a
fabricated count, never a floored one.

The board's counters also now span a resumed Implement stage. `stage_start` is
not deduped, so a resume splits the timeline and the hires landed on both sides
of the split — the band read 2 where every other surface read 3. The split itself
is deliberately kept (and pinned by a test); only the number crosses it.

### The retired cap stops being documented as live

`MAX_ATTEMPTS=5` was retired in S133 and replaced by a 3-worker-session cap, but
four docs still taught the old number — including `lcars-respond`'s frontmatter
`description:`, which is model-facing routing text, i.e. wrong guidance rather
than a stale comment.

**Not changed:** the escalation machinery itself — `MAX_WORKER_TRIES`, the gate
set, the bounce-and-rehire loop, the awaiting-human park. This round changes what
the captain is TOLD, not what LCARS DOES. Event TYPE names and the `attempt` wire
key are unchanged, so historical `events.jsonl` files render correctly; the board
keys on event type, never on detail text, which is asserted by mangling every
detail string and confirming the tallies are byte-identical.

Proven on fixtures and REAL HEADED CHROME (rig committed at
`tests/drives/browser/s173-{fixture.sh,hires.sh,drive.js}`), zero worker spend.

## 2026.8.5 — 2026-08-30

**The harness stops asking what it already knows.** Session 180. A complex
holodeck Mission reached Verify green but raised **four human gates, all on ONE
ticket, all about ONE question the captain had already answered TWICE**. Plan
Review called it "an UNSETTLED open question with no captain resolution"; the PRD
had recorded it RESOLVED since Align.

Measured on a live Copilot capstone of that same Mission, hands-off Align →
Verify: **4 human gates → 0**, Plan Review 6 rounds → 1 (none failed),
**$407.89 → $165.03**. A separate plain non-holodeck drive also ran hands-off to
Verify in ~6 minutes / $2.78.

### The reviewer can see what the captain decided

`cmd_plan_review` is deliberately never handed `prd.md` (S174's independence
design, which stands). It is now handed a **decisions digest** — the resolved
open-questions entries and nothing else — plus a precedence rule: a recorded
answer OUTRANKS the drawing on BEHAVIOUR, the drawing remains the authority on
LOOK, and declaring a decided question "unsettled" is not an objection. A Mission
that decided nothing produces a byte-identical reviewer prompt.

### Decisions stop vanishing, and the loop stops costing money

- **`answers.json` is an append-only ledger.** It was a single slot: three
  successive answers to one question each erased the last.
- **The round budget resets on an answer**, under a separate escalation cap — past
  round 3 every failure had been a human gate at ~$6–10 a cycle.
- **The driver auto-resumes** after an answered gate instead of exiting. Proven
  live: one `respond` ran a plain Mission all the way back to Verify unaided.
- **The hints it prints are commands that run.** `lcars` is not on `PATH` and
  never was; 19 printed hints and 14 SKILL.md lines said otherwise.

### A negative-existence claim is checked, not believed

A Research worker wrote *"There is no `WIRED_METRIC_IDS` symbol anywhere in the
repo (grep returns zero matches)"*. It exists three times, in the file the
Mission was about to rewrite. Nobody ran that grep. The harness now runs it: a
claim that a named, code-shaped identifier is absent repo-wide is verified
against the Mission's own branch, and a refuted claim parks the Mission with the
matching lines. Swept over 126 real negative-existence sentences from 58
Missions, it fires on none of them.

### Pulled: the prohibition-carry check

A companion check — "a prohibition in the validated plan must reach a ticket" —
was **removed** after three rounds, each of which traded one failure for another.
Its noise floor had been measured on 56 Missions from one repo, all holodeck-
style; the first plain Mission driven through it produced a false positive,
reading a test-coverage bullet as a prohibition. The defect it found is real and
**reproduces** — two independent live Planners dropped the same decision from
`validated-plan.md` to zero mentions in `plan.json` — so the evidence is
preserved under `tests/drives/align-heal/runs/` and the false positive is kept as
a regression test the next attempt must clear. Test counts fell accordingly
(claim-check 161 → 93, replan-overcorrection 222 → 166).

## 2026.8.4 — 2026-08-20

**The viewscreen stops paying for work you already finished.** Sessions 176–177.
Session 176 made the board BUILD cheap; session 177 found the 2.3 seconds that
176's own benchmark could not see, because it timed the adapter in isolation
instead of the daemon over HTTP.

### Session 177 — the Mission-Log overlay stops rebuilding the whole repo

The captain reported the board still lagging on a card click after 176 shipped.
Instrumented, ONE `/api/board` request was making **784 full mission-detail
builds** — 56 missions × 14 scans. Two causes:

- **`LogFacts._linked_children` built a full mission detail for every mission in
  the repo to test one key.** It called `reader.mission(name)` first and only
  then read `parentMission` off `state.json` — the cheap test it already knew how
  to do, run after the expensive work it gates. The test now comes first.
- **The scan ran once per parent, fourteen times per request.**
  `_waiting_counts → _waiting_children → _log_dispatch_is_stale →
  _batch_short_of_its_gate → _waiting_children` is mutually recursive and every
  arm re-walked the missions dir. A read request now opens a **thread-local**
  scope in which the dir is walked ONCE and grouped by parent (thread-local
  because the daemon serves boards concurrently; outside a scope there is no memo
  at all, so every write path behaves exactly as before). The recursion's LOGIC
  is untouched — it is a correct reading of a subtle state (S163 round 7 D3); it
  is only made cheap.
- **`mission()` now answers through the same done-card memo the board uses.** It
  called `_card` directly, so 176's memo never reached the DETAIL path — which is
  the path the overlay hits once per linked child, on every render.

Measured over HTTP against a real 56-mission repo with 8 log parents and 44
linked children: **`/api/board` 2400 ms → 50 ms (48×)**, **`/api/mission/<parent>`
2285 ms → 30 ms (76×)**, detail builds per render **784 → 44**. This path is only
reached when a Mission-Log parent has linked bug children, which is why it went
unnoticed: a repo that never ran `lcars log` never paid it.

### Session 176 — the board build itself

**The board stops paying for finished missions.** The board got
slower with every mission you completed and never gave the memory back — on a
56-mission repo (51 of them Done) it rebuilt every card from disk and tore down
and repainted the whole DOM four times a minute, whether or not anything had
changed. Session 176.

- **A finished mission's card is computed once.** A `done` Mission is immutable
  by construction — terminal Stage, no driver lock, no worker — so its card is
  memoized on a cheap directory signature (dir mtime + max file mtime + entry
  count, so a DELETED artifact is caught as well as a written one, plus
  `config.json`'s mtime because a `modelAliases` edit legitimately changes a
  done card's model mix). In-flight Missions are never memoized: they carry live
  fields, and there are only ever a handful of them.
- **The board stops rebuilding itself over nothing.** The 4-second safety poll
  now compares what came back against what is already drawn, and leaves the DOM
  alone when they match. The comparison is on the PAYLOAD, deliberately not on
  `fingerprint()`: the fingerprint is a disk signature, but `meta.holodeck` is
  in-memory daemon state, so a fingerprint gate would have silently stopped the
  ⬡ HOLODECK band from lighting up. A failed fetch invalidates the comparison,
  so a recovered daemon always repaints. The poll still carries every step of a
  reconcile write-burst — the reason it exists.
- **Repo identity resolves once per daemon**, exactly as `gh_host` already did,
  removing a `git` subprocess spawn from every single render.
- **The detection sweep stops walking `node_modules`.** `_detect_signature`
  applied its prune list to the glob RESULTS, so `*/*/*.csproj` enumerated every
  package before discarding it — on a path `fingerprint()` reaches, which the SSE
  channel polls once a second. It now prunes during the descent: same file set,
  same order, and detection stays IMMEDIATE (a TTL memo was tried first and
  correctly rejected by `test_readiness.py`, which encodes that contract).

Measured on a real 56-mission repo, `main` vs branch in one process: `board()`
**192.9 ms → 19.2 ms** (10.0×), file opens per render **805 → 106**,
`fingerprint()` **24.2 ms → 9.4 ms**, `_detect_signature()` **15.3 ms → 2.5 ms**.
The `/api/board` payload is **byte-identical** to before (433 270 bytes, verified
mechanically) — the same board, for a tenth of the money. Capping the Done column
remains deliberately unbuilt; it is a product decision, not an optimisation.

## 2026.8.3 — 2026-08-08

**The Holodeck — design it in conversation, then hand the drawing to a Mission.**
A `⬡ HOLODECK` room on the viewscreen where you talk a mockup into existence
against your real project, see it rendered live, and then send it to Align as a
Mission that builds the thing you drew. Sessions 123–172.

- **The room.** Three panes — the program list, the chat, and a sandboxed live
  preview jailed to the sidecar (with a `▤ Intent` toggle that swaps the
  preview for what has been captured so far) — in the LCARS visual language.
  Programs live in a sidecar git repo beside your project (`<repo>-holodeck`),
  never in your working tree, so a mockup can never be mistaken for the product.
- **Grounding.** Starting a program offers a bounded read-only pass over your
  real project, so the mockup arrives looking like it belongs in that product
  rather than inventing a design system. It is the recommended start and not
  the only one — a blank deck spends nothing and reads nothing.
- **Durable programs.** A program survives a daemon restart; reopening replays
  the whole transcript into a fresh worker, which is told plainly that it is
  fresh and remembers nothing itself. Delete records before it removes, and
  refuses what it cannot recover.
- **Send to Align.** The hand-off carries the mockup, your captured
  requirements and a change list — and the mission's tickets carry them too:
  each ticket declares whether it changes what the screen looks like, and one
  that says yes must name the mockup. Mockup-referencing acceptance criteria
  went from **0/44 to 19/40** across the round, with the "judged at Verify"
  deferral gone entirely.
- **The brief is in your words.** It opens with what you actually said,
  byte-for-byte. The change list is a **diff of the finished mockup against the
  app as it is now** — not a transcript of the conversation — so a turn where
  you corrected the *mockup* no longer reads downstream as an instruction to
  change the *product*. What the pass cannot scope comes back as a question
  rather than silently vanishing.
- **Duplicate a program, carrying its history** (session 172). A program sent to
  Align is locked — it is the record of what was filed. `⧉ Duplicate` opens a
  new room carrying its mockup, concept doc, grounding, attachments and the
  whole conversation, editable from the first turn, while the original stays
  exactly as handed over. The worker is told the history is context and not a
  contract: *"nothing in it is binding … where what he asks for now contradicts
  a decision in the history, what he asks for now wins."* Lineage is recorded on
  the copy; the inherited grounding is marked possibly-stale in the file, on the
  deck and in the worker's prompt; the derivation deliberately does not travel.

Proven on real drives, not fixtures: a holodeck program became a real mission
that ran Align→Verify hands-off (9/9 tickets, 9/9 gates, zero escalations), and
session 172's duplicate road was driven in real headed Chrome against a copy of
a real archive and on **both live engines** — each obeying the not-binding
instruction against a decision the record itself marked "settled". Committed
rigs at `tests/drives/browser/holodeck.sh`, `handoff.sh` and `duplicate.sh`
(9 checks, every control verified red).

**Known and NOT fixed in this release** (found by the round's own testers,
shipped knowingly):

- **A duplicate-name race.** Two duplicates typing one name in the same instant
  can both pass the name check. Nothing is destroyed — the room claim is atomic,
  so they land in separate rooms and the `⌂ room` chip tells them apart.
- **Unicode-only program names still collapse to one shared room** (legacy).
  Duplication now differentiates rather than merging, so it is harmless here.
- **The lineage chip is verbose on a long program name** — with a whole-sentence
  name it wraps to six lines and restates the card's own title. Readable, but it
  costs about a third of the card.
- **Seventeen image-paste tests are red**, in three suites outside the holodeck.
  A validator added mid-round correctly refuses images that do not hold
  together, and those suites' fixture is a fake PNG. Real screenshots pass and
  truncated ones are correctly refused — the fixtures are stale, the feature is
  not broken.

## 2026.8.2 — 2026-08-03

**"View on GitHub" now opens the forge the repo is actually on.** Captain-
reported: earlier work taught the harness to talk to GitHub Enterprise, so stage
comments and mission-log issues land correctly on a `*.ghe.com` host — but the
viewscreen's links still string-concatenated `https://github.com/`, so every
click landed on the wrong forge and had to be hand-edited.

- The two link sites (`board.js`, the card's linked-ref badge and the mission
  detail's View-on-GitHub) now build their URL through one helper fed by the
  repo's real forge host. The host comes from the SINGLE existing
  implementation — `host-adapter.sh`'s `gh_hostname`, exposed as a new `gh-host`
  op — rather than a second copy in Python. That was deliberate: this release
  also ships alongside a ledgered bug caused by exactly that pattern (the
  zero-collect phrase list is duplicated between `lcars-init` and `run.sh` and
  has since drifted, leaving one surface honest and the other blind).
- **Resolved ONCE per daemon lifetime**, warmed at startup and memoized —
  including the empty answer, or every github.com daemon would shell out
  forever. Measured from outside with a logging `git` shim: a board left open
  60s makes exactly **1** `git remote get-url` call on the branch vs 0 on main,
  with the pre-existing per-tick repo-name lookup unchanged at 17 either way.
- **github.com users pay nothing.** The board payload is byte-identical to the
  previous release — verified by running identical fixtures through both
  daemons and comparing bytes (4683 for a github.com repo, 4682 for a repo with
  no remote), with `meta` carrying no new key at all.
- Generic host resolution, not a `.ghe.com` special case: a self-hosted GHES on
  `github.internal.acme.com` works, as do scp-style `git@host:owner/repo`,
  `ssh://` with a port, `git://`, uppercase hosts, and trailing slashes. A repo
  with no origin — or no git at all — still renders today's links rather than a
  broken one.
- Fixed alongside, because it made the first link unmeasurable: the logged-bug
  badge rendered as a dead `<span>` on FIRST paint and only became a link if a
  later re-render happened along, because the repo identity was captured at the
  END of `render()`, after the cards were built.

Proven in real headed Chrome against a real daemon reading a real git remote,
reading the anchor's RESOLVED href — plus four red controls, including one that
silences the daemon while leaving the front end perfect, which is the failure no
Node DOM harness can see. Rig committed at `tests/drives/browser/ghe-links.sh`.

**Known and NOT fixed in this release** (found by the session's own tester,
shipped knowingly):

- **The GitHub adapter still links to github.com.** The fix landed on the local
  adapter only; `--adapter github` / `LCARS_SERVE_ADAPTER=github` — the
  view-only mode the viewscreen SKILL.md advertises as the hosted board — never
  gained the host. Not the default path, but it is exactly where an enterprise
  user would point a shared board.
- **A stale host survives `git remote set-url` on a running daemon.** The repo
  name is re-read every poll while the host is cached for the daemon's life, so
  changing the remote under an open board yields a HYBRID url — new repo, old
  host — pointing at neither. Restarting the daemon clears it. Fix is to cache
  both or neither.

## 2026.8.1 — 2026-08-02

The **quality-of-life round** (sessions 158–167): base freshness, backgroundable
bug filing from the board, and a capstone that drove the whole round for real.
Ten sessions on one branch, closed by a live drive on a real private GitHub repo
with live workers — which is how most of what follows was found rather than
assumed.

- **A Mission filed from a stale checkout now reasons about the fresh tree.**
  `ensure_base_current()` brings the Mission's base branch up to date before
  filing and records an honest freshness verdict; a re-check runs again at drive
  time. It NEVER blocks filing, never touches a dirty tree, and never resets,
  force-updates, stashes or checks out anything — a mission branch is left
  exactly as it is (`⊘ base … is a Mission branch`). Proven on a fixture whose
  local `main` was one commit behind the commit that added the file the Mission
  targeted: the reflog shows one ref move and the mission branch parented on the
  fresh tip.

- **The freshness verdict reached the surface Missions are actually filed from.**
  The guard printed to stdout, which a captain filing from the board never sees.
  A card badge, a detail line and a File-console pre-flight now carry it, backed
  by a read-only `GET /api/base-freshness` that measures without moving a ref.
  Gated on the record's CARRIED `loud` flag, never on a verdict allowlist —
  `unknown` is both the silent no-remote case and the loud unreachable one, so an
  allowlist provably cannot tell them apart. **Capstone amendment:** a base that
  is behind but fast-forwards cleanly is no longer silent — `loud` now picks the
  TREATMENT rather than deciding whether to speak, so that case gets one calm,
  muted line ("1 commit behind … filing brings it up to date first") while the
  loud cases keep their warning treatment byte-identically.

- **The front-half Stages read the Mission's code structurally, not by request.**
  Research, Validate, Plan and Plan Review resolved paths against the captain's
  ambient checkout; the "read the Mission's branch" pin was a sentence in a
  prompt, and a live worker was MEASURED ignoring it. Each now runs in a DETACHED
  worktree at the Mission's branch sha. **A prose pin is not a mechanism.**

- **Filing bugs from the board no longer dies with the dialog.** The Mission Log
  console's File & Cost is backgroundable: the daemon owns the filing session, the
  parent card carries a ◐ FILING & COSTING band, and closing the window mid-flight
  leaves the work running. A "Fix Filed Bugs" control then opens the review and
  dispatches the SAME endpoint the Go button always did — no second filing path,
  and BUG-059's hold stands (filing never auto-proceeds into running).

- **A folded bug's GitHub issue now CLOSES.** Previously a folded child was
  relabelled `lcars:done` and left open — the shape seen on DX-Scorecard PR #77,
  where seven children stayed open. The cure keys off the fold's EXIT STATUS, not
  the refusal wording. Verified on real GitHub issues, on the harder REFUSAL path
  (a bug correctly found not to reproduce still closes out).

- **A deploy is no longer blind to its own writes.** Every `lcars launch` checkout
  was cut inside the repo's `.git/`, which Vite's default `server.watch.ignored`
  (`**/.git/**`) makes chokidar ignore wholesale: the dev server booted, served
  pages, and never saw another change. The checkout now lands beside the repo,
  keyed by canonical path; mission state stays under `.git/lcars`. Judged on the
  RUNNING SERVER, never the path — outside `.git/` the served glob went 2→3 in
  45ms; under it, still 2 at 60s.

- **The Research column is no longer always empty.** `lcars:research` was applied
  in exactly ONE place — inside the >20-question escalation branch — so a Mission
  actually running Research still read `lcars:align`. The cause is structural:
  `research` is the only `lcars:*` stage label with no `set_stage`, so the pointer
  stays `align` for the whole Stage. Fixed label-only; grounding-mode Research on
  logged bugs gets it too.

- **`lcars init` no longer certifies a zero-test repo as online.** `node --test`
  with no test files exits 0 printing `tests 0`, and init reported "TEST SYSTEMS
  ONLINE — verified by a live run". The zero-collect guard knew six runners'
  phrasings but not Node's own. The new pattern is anchored at both ends so a
  healthy run's `tests 12`, `fail 0` and `suites 0` cannot match it.

- **The "Child bug mission" legend swatch paints.** `docs/lcars.css` never defined
  `--lcars-pink`, and this was the one use site without the `#ff66aa` fallback, so
  the declaration was invalid at computed-value time — alpha 0 on a perfect 12×12
  box with element, class, style attribute, CSS rule and layout all present.

Rigs committed rather than discarded, under `tests/drives/`: a real-Chrome board
smoke, the base-freshness quiet-line check, the legend-swatch check (each with red
controls that genuinely fail when the feature is removed), and a deploy-watcher
drive that keeps a deliberate under-`.git/` RED CONTROL.

## 2026.7.20 — 2026-07-29

Three defects found on ONE real mission — `lcars-20260729-001`, a 12-ticket
DX-Scorecard feature that ran 2h14m unattended and shipped with 4 logged bug
fixes. Each defect sat at a different seam, and each was invisible: none produced
an error, and two were actively reassuring while broken.

- **The Align console blanked mid-interview.** The captain answered question one
  and the grill repainted its "What would you like to refine?" fallback over an
  empty PRD panel, with no error and no way back in. The worker was fine — both
  turns emitted well-formed JSON. The daemon misread the second one. The grill's
  tools-denied posture (`--available-tools=`) no longer holds on a copilot
  continuation turn: the opening turn made 0 tool calls and parsed cleanly, the
  turn after the answer made 10 builtin `view` calls, so its stdout carried tool
  activity ahead of the real turn. `_extract_json` took the FIRST balanced `{...}`
  that parsed — a tool ARGUMENT object, `{"path":"…"}`, perfectly valid JSON —
  producing a turn with no question and no PRD. It now collects every parseable
  top-level object and returns the LAST one carrying turn keys: the turn is the
  worker's final message, and tool noise is never turn-shaped. `_align_turn`
  additionally refuses to ship a question it cannot render, raising 502 BEFORE
  mutating the session so the console shows an error with Submit re-armed and the
  previous question, transcript and PRD all survive.

- **Approving a parent stranded its logged bug children.** A logged bug folds its
  fix onto the parent's branch and gets NO PR of its own, so the only thing that
  can mark it Done is the fold — reachable from exactly one place: accepting the
  parent's consolidated re-verify gate. Merging the parent destroyed that route.
  approve's merge-success block deletes `awaitingHuman`/`pendingQuestion` (the
  gate), then `set_stage done` puts the parent outside resolve-logs' reach
  entirely (its `active_table` skips done missions), while approve refuses a child
  directly for having no PR. Review the PR, merge it, and four bug cards are
  orphaned at verify with their fixes already in `main` — with no way back. approve
  now folds them as part of the merge, before the parent goes done, dispatching per
  child to `resolve-logs complete --bug` so the fold keeps one home. Best-effort
  and never fatal (the merge has landed; a refusal must not fail a shipped parent),
  and a still-mid-flight child is named too — merging the parent leaves its fix out
  of the PR.

- **The fold's premise check was inverted — and had never run.** 2026.7.18 taught
  `fold_one_child` to verify a bug's fix is actually on the parent branch before
  calling it Done, closing the class where cards read Done while the code had
  vanished. `child_fix_on_branch` piped `git log` into `grep -q`; the script runs
  under `set -o pipefail`, and `grep -q` exits the instant it matches, so git dies
  of SIGPIPE and pipefail returns 141. The result was inverted on the ONE case that
  matters: a fix that IS on the branch reported "not on branch", so every
  legitimate fold was REFUSED with a false alarm about missing code. It shipped
  undetected because nothing in the suite ever planted a `.commit-sha` —
  `child_recorded_a_commit` was always false, the check never ran, and every
  existing fold test passed it vacuously. Now capture-then-match with a
  here-string: no pipe, no SIGPIPE, same subjects-only fixed-string semantics.
  Behaviour 14 gives it its first real coverage, in both directions.

- **Both fold directions are now proven together.** The two fold defects are exact
  inverses — 2026-07-28 was green cards with no code, 2026-07-29 was merged code
  with stranded cards — so they are tested as a pair and driven as a pair: a
  stand-in-captain proof drive runs a real mission and a real logged bug end to
  end on real workers, with a local bare `origin` whose `pr-merge` genuinely
  fast-forwards `main`, then asserts BOTH that the bug's commit is on merged main
  AND that its card reads done.

- **Known, unfixed:** copilot's grill no longer honours `--available-tools=`
  (builtin tools execute; custom MCP servers boot every turn, ~13s each), and the
  cost estimator undercalled a 12-ticket mission ~6× ($4.86–$25.47 estimated vs
  $150.07 actual). An automated drive against a fresh repo also blocks on the
  interactive `RUN lcars update? [y/N]` prompt until its config carries an
  `lcarsVersion` stamp.

## 2026.7.19 — 2026-07-29

Wave isolation and provable repairs (S156–S157). Two defects from one dead
mission: `lcars-20260727-001` landed all 12 tickets, then burned 8 worker
sessions, 2 self-heal rounds, 3 flip-flop rejections and 8 gate bounces on ONE
ticket and never reached Verify. It was ended by hand.

### Infrastructure tickets get their own wave (S156)

Wave 1 held both the Vite/React/TS scaffold and a docs ticket. Siblings in a
wave build against the same frozen base, blind to each other, so the docs test
resolved the repo root with `fileURLToPath(new URL('..', import.meta.url))` —
correct against a repo with no Vite config. The scaffold then landed
`vite.config.ts`, Vite rewrote `import.meta.url` to a served URL, and the file
threw at import. Its 13 tests never ran again, and nothing noticed for eleven
more tickets.

A ticket that establishes shared infrastructure now schedules into its own wave.
Classification is **declared**, not guessed: a per-ticket
`establishesSharedInfrastructure` flag that Plan sets and Plan Review audits both
ways. The text heuristic that preceded it was demoted to a narrow backstop after
the tester reworded its own corpus preserving meaning and recall fell 14/14 to
5/14 — proof it was matching sentences, not concepts. Undeclared, a plan is still
a coin flip on phrasing, so Plan Review is load-bearing here; that limit is
recorded as a test pair rather than hidden.

### An honest test repair can finally be certified (S157)

Every worker must prove its work: its test is run against the code as it was
before, and must fail there. Correct for a NEW test — and wrong for REPAIRING a
pre-existing broken one, because the harness ran the worker's *fixed* file
against parent code, where it passed. Red-on-parent was unprovable by
construction, so a correct fix was rejected forever. That is what killed the
mission above: the reconcile worker diagnosed the bug accurately, fixed it
minimally, declared the edit honestly, and was rejected three times.

A test file that already existed at the parent is now judged against the
**parent's own committed copy**. Red-on-parent then means the file was genuinely
broken before. New files keep byte-identical staged behaviour; any non-test path
in the diff routes the ticket to the normal gate and names the paths that did it,
so a worker is never told its broken test "passes on the parent" with no
explanation. The acceptance bar is unmoved: weakening a test that PASSED on the
parent still yields no red and still fails.

### Self-heal names the ticket that authored the failing suite

It named the last ticket to land. In the live incident that was t-011, for a
break whose test file t-012 wrote — so a worker was handed a brief for a ticket
unrelated to the failure. It now names the **authoring** ticket, re-picked each
self-heal round from that round's failing set, and says plainly when ownership
cannot be resolved instead of guessing. The old copy asserting "a LATER ticket's
produced code REGRESSED its locked contract" is gone: the gate never established
that, and the confident wrong premise cost real sessions.

### The anti-gutting guard was retired, deliberately

Allowing a worker to edit an already-broken test opens a door: delete the failing
test instead of fixing it, and the evidence looks identical. Four successive
guards were built to close it — file existence, line counts, regex name sets, a
character-level lexer — and five adversarial review rounds beat each one at a new
token: `test.skip`, commented-out padding, apostrophes truncating names, names
read out of string literals, `describe.skip`, multi-line templates, ruby
`=begin`, a regex literal containing `/*`, `it.each` tables. Round five then
caught the guard **false-failing an honest repair** that dropped a dead
`require` — re-creating the very loop this work exists to end.

So the ~1,000 lines of source parsing were deleted for one source-blind check —
the runner may not execute fewer tests than before — and repairs are made
**visible** instead: Verify lists every repaired file for human review, and the
declared-edits contract already forces a reason for each. The remaining check is
called a screen, not a proof, everywhere it is described, and its blind spots are
stated plainly: when the parent's copy is dead at import it executes nothing, so
the comparison proves nothing there. Five residuals are each pinned as a live
assertion, so closing one is a deliberate visible change.

### The defect no scoped test could find

Verification by live drive, with real workers, found what five rounds of fixtures
could not. `lcars init` seeds a `worktreeSetupCommand` that SYMLINKS
`node_modules` into each ticket worktree — and `node_modules/`, the near-universal
gitignore pattern, is directory-only, so it does not match a symlink:

```sh
printf 'node_modules/\n' > .gitignore; ln -s /tmp node_modules
git ls-files --others --exclude-standard   # -> node_modules
```

The gate counted the harness's own provisioning artifacts as worker-authored
non-test paths, declared the diff mixed, and refused the repair path — on a ticket
whose real diff was one line in one test file. The repair path was effectively
unreachable on any standard JS repo. In the drive it only recovered because the
worker diagnosed the harness bug and hand-edited `.git/info/exclude`. An untracked
symlink is now recognised as provisioning, not authorship, at the point
eligibility is decided; the declared-edits guard and quality floor still see the
raw diff, so a worker that genuinely commits a dependency tree stays visible.

### Never self-heal an environment fault

Merging `main` mid-round (2026.7.16–2026.7.18) put this work in the same function
as the new stale-dependency classifier. Resolved by ordering — the environment
diagnosis returns before attribution, so a toolchain fault names no ticket — and
pinning that seam then exposed a further gap: self-heal still fell back to the
last-built ticket and spent worker sessions trying to edit code for a broken
toolchain. It now skips entirely on an environment fault and parks the human with
an actionable diagnosis naming `lcars update`. The board grew matching copy: a
stale toolchain is not a decision the operator is being asked to make.

### Proven live

Three drives with real workers, on top of the scoped suites: an honest repair of
a collection-red pre-existing test certified on the **first attempt**; a genuine
cross-ticket break attributed to the **authoring** ticket while the reconcile
worker kept the innocent change intact; and an ordinary feature mission running
Align to Verify hands-off, three tickets, each green on its first session.

### Also

`lcars-run.test.sh` was measured rather than assumed: it is **effectively 100%
stubbed and costs nothing to run** — 52 minutes of wall clock but ~3.5 minutes of
CPU, the rest hang-guard polling. Its 248 failures are byte-identical on this
branch and on `main`, all stale fixtures predating the S132–135 unified worker.
The BUG-029 self-heal assertions are unreachable on their own fixture, which
writes `tests.sha256` where the code reads `proof-tests.sha256`.

## 2026.7.18 — 2026-07-28

The reconcile re-entry no longer destroys committed work — **the worst defect
found so far, because it deleted verified code and reported success.**

BUG-077 made a reconcile re-entry reset the local mission branch to the remote
PR head before re-merging, so a killed/retried reconcile could not leave the tip
diverged and jam the push:

```sh
git branch -f "$BRANCH" "origin/$BRANCH"
```

Right when the local-only commits are a dead attempt's merge commit. Catastrophic
when they are real work — and **mission-log bug fixes are exactly that work.** A
logged bug never opens its own PR: its fix is cherry-picked onto the *parent's*
branch and rides the parent's PR, so until the parent next pushes it exists only
locally.

Observed live (DX-Scorecard, 2026-07-28). Three gate-verified bug fixes were
cherry-picked onto the parent branch; 109 seconds after the last one, the parent
re-entered reconcile because main had moved 8 commits ahead:

```
b75400b (bug 005)   1785267868
a2509a8 (bug 006)   1785268473
cddf9b4 (bug 007)   1785269867
RESET -> 091fbb7    1785269976
```

The reset moved the branch back to the remote head — precisely the chain's base.
All three commits became unreachable in one command. The reconcile then re-tested
the *parent's* ticket, went green (the bug fixes' own tests had been discarded
along with their code, so nothing was left to fail), and the PR merged carrying
none of it. No error was raised anywhere; the loss was found days later, by hand.

- **Divergence is now resolved by PUBLISHING, not deleting.** When the local
  branch holds TICKET WORK the remote has never seen,
  `reconcile_sync_local_branch` pushes it — divergence is genuinely gone
  (local == remote) and nothing is lost.

- **BUG-077's own case is untouched.** The decision keys on LCARS's own commit
  contract rather than on "is there anything local": `commit_ticket` always
  writes `lcars(<mission-id>) t-NNN: …`, and a cherry-pick preserves that
  subject, so a logged bug's fix is always recognised. A dead reconcile attempt
  is built with `git merge --no-edit` and carries no such subject, so it is
  still discarded exactly as before. `run.sh` has precisely two commit sites,
  one of each kind, so the partition is exhaustive by construction.

- **A failed push refuses rather than falls back.** If the work cannot be
  published, the branch is left alone with a loud event naming it. A jammed
  push is recoverable; deleted commits are not.

- **Measurement failure can never authorise a reset.** The counters return 0
  only for "nothing provably at risk"; an unresolvable or non-numeric count is
  treated as unsafe, not as permission.

- **The fold now verifies its own premise.** `fold_one_child` marked a logged
  bug Done on the stated assumption that "its fix already lives on the parent
  branch" — and never checked. That is what turned the branch reset into a
  green board with no fix anywhere. It now confirms the fix is actually on the
  parent branch (by the same preserved `lcars(<bug-id>)` subject) and REFUSES
  with a distinct code otherwise: the bug stays at Verify, its siblings still
  fold, and the command exits non-zero naming what was refused. A bug whose
  ticket recorded no commit has nothing to verify and folds as before, so
  no-op fixes are never false-refused. This closes the CLASS — any future cause
  (a force-push, a botched cherry-pick) is now a loud refusal at the moment of
  decision instead of a silent loss found days later.
## 2026.7.17 — 2026-07-28

GitHub Enterprise support — **LCARS worked on `github.com` and quietly half-worked
everywhere else.** On a `*.ghe.com` (or any self-hosted) repo, issues never
received their per-stage detail comments and ticket sub-issues were never nested,
with no error anywhere to explain why.

The cause is a split in `gh` itself: `gh issue` / `gh pr` resolve the forge host
from the repo's own remote, so they work on enterprise with no configuration —
but `gh api` does **not**. It targets the default host and only substitutes
`{owner}/{repo}` from the cwd repo. Verified against a real enterprise repo:

```
$ gh api "repos/{owner}/{repo}"
{"message":"Not Found","documentation_url":"https://docs.github.com/..."}
```

A 404 from *docs.github.com* — the call went to github.com — while `gh auth
status` showed a valid enterprise login the whole time. Every api-backed op
discards stderr, so the failure was completely invisible.

- **`gh api` is now host-pinned.** `host-adapter.sh` derives the host from the
  repo's origin remote and passes `--hostname` to every api call, routed through
  one `gh_api` wrapper so a future op cannot forget it. This repairs the S65
  living per-stage comments and native sub-issue linking on enterprise. Handles
  https, ssh, scp-style (`git@host:owner/repo`) and `host:port` remotes;
  `LCARS_GH_HOST` overrides.

- **github.com is byte-for-byte unchanged.** The helper returns EMPTY for
  github.com and for a repo with no origin, so no `--hostname` is added and the
  argv stays exactly what it has always been — the adapter's regression locks in
  `tests/host-adapter.test.sh` keep their meaning (56 green, untouched).

- **Readout links name the real host.** `lcars init` / `lcars update` printed a
  hardcoded `on github.com/<owner>/<repo>`, which on enterprise links to a repo
  that does not exist. Both now use the shared `lcars_gh_web_host`.

## 2026.7.16 — 2026-07-28

The Honest Environment round — **stop blaming the code for a stale toolchain,
and stop calling a repo mission-ready before anything has run.** One field
failure produced all three fixes. A Mission's ticket correctly diagnosed that
its repo's suite could never run (vitest 4 pinned against vite 5, which needs
vite >= 6) and committed the fix. The gate symlinked the main checkout's
`node_modules` — still holding vitest 4 — so the suite died at import anyway,
and the gate reported *"the implementation is NOT present on the committed
branch"*. No committed change could ever have cleared it. Three TDD sessions
were spent re-solving a solved problem, and `lcars init` had cheerfully
declared the repo ready in the first place.

- **Provisioning honours the lockfile.** The seeded JS `worktreeSetupCommand`
  reused the main checkout's `node_modules` whenever it existed — right up until
  a ticket CHANGED dependencies, at which point the shared install is the wrong
  set by definition and the ticket's own lockfile fix can never take effect. It
  now compares the worktree's lockfile against the main checkout's and does a
  real install when they diverge, keeping the fast symlink path (~0.07s) when
  they match. Covers npm / pnpm / yarn.

- **Existing repos are repaired, not just new ones.** `lcars update` gains a
  fingerprint-gated migration that rewrites LCARS's own un-guarded symlink
  command in place, alongside the S101/S148 `testCommand` migrations. It matches
  only a command carrying our symlink signature that lacks the guard, and
  regenerates the replacement from `detect_worktree_setup_cmd` so it cannot
  drift from the seed. A captain's hand-written command is never touched.

- **The gates name the real fault.** `red_gate_env_failure` only catches a
  runner that fails to START; here the runner started perfectly and simply had
  the wrong packages. The new `stale_dep_env_reason` is its state-based
  companion: when a gate worktree's deps are shared in by symlink AND its
  committed lockfile differs from that checkout's, both the post-commit and
  full-suite gates now report a STALE DEPENDENCY ENVIRONMENT — naming the repair
  — instead of accusing the implementation of being absent or earlier tickets of
  regressing. Conservative by construction: it speaks only on positive evidence,
  so a genuinely missing implementation keeps its existing wording.

- **`lcars init` proves the suite runs.** `lcars_test_readiness` is cheap by
  design (status and the board call it constantly), so "ready" only ever meant
  *the command's first token resolves* — a claim about the command, not the
  suite. init is a one-time action and can afford more, so it now runs the
  seeded command ONCE through the same bounded probe `lcars update --fix-tests`
  already used (moved into `lcars-common.sh` so the two can never disagree about
  what counts as a pass, a zero-collect, or a timeout). It probes only the
  `ready` verdict — the one state that can lie — reports honestly, and never
  blocks setup on a red suite. `LCARS_INIT_SKIP_PROBE=1` opts out.

## 2026.7.15 — 2026-07-28

The Hotkeys & Help round (S140–141) — **drive the bridge from the keyboard, and
find out how without leaving it.** The viewscreen had exactly one keyboard
listener in the whole front end (Escape-to-close) and no help surface of any
kind: no card navigation, no action keys, and nowhere for a new captain to learn
what the board even is. This round adds both halves — a command deck of single
keys, and a `?` console that documents itself from the same table that registers
the bindings.

- **The command deck (S140).** Cards are focusable (`role="button"`,
  `tabindex="0"`) behind an amber `:focus-visible` outline; arrows walk focus
  within a column and across columns (skipping empty ones); Enter *and* Space
  open the focused Mission; `f` `d` `s` `p` `v` `l` reach the band and card
  controls. Every binding dispatches by `.click()`ing the card's REAL control, so
  a hotkey is gated identically to the button it triggers — a disabled or absent
  control is a silent no-op, and read-only boards need no separate guard. Four
  guards: never hijack typing, an open console owns the keyboard (`?` excepted),
  modifier chords belong to the browser, and key auto-repeat cannot double-POST.
- **The `?` console (S141).** A `?` button in the yellow band (and the `?` key)
  opens one modal with two sections. **COMMAND DECK** is the cheatsheet,
  *generated by iterating the binding table* — a binding added later appears with
  zero extra work and the two can never drift. **ORIENTATION** is a
  getting-started briefing in the ship's voice: file or park a Mission, answer
  the Align grill, watch the stages advance, answer when the ship hails you,
  review at Verify, deploy main. It renders from a declared content structure
  whose every named control is walked to a real DOM node by test, so the primer
  cannot describe a UI that isn't there. A board with no Missions points at `?`.
  Help is never write-gated — it opens on read-only boards too.
- **Help covers the console underneath; it never destroys it.** Pressing `?`
  mid-task used to replace the open console, discarding a half-typed idea with no
  warning. Now the open console is hidden **in place** and revealed again on
  close, so typed text, an engine pick and a warm Align session all survive the
  round trip. Hiding rather than detaching keeps the node in the document, so
  intervals guarded on `document.body.contains` — a running Mission's clock, a
  Verify launch poll — keep ticking under the cover instead of self-cancelling
  and never restarting.
- **Copy that cannot lie.** Three tester rounds on real Chrome found nine
  defects, nearly all the same shape: prose describing conditional UI as
  unconditional. Two cheatsheet rows claimed to deploy and start when they only
  open a console; the Verify step promised "what was built" and an EST→ACTUAL
  line that are both gated; the VIEW-ONLY line claimed every named console still
  opens when only the File console does. The durable fix is that these claims are
  now pinned by tests that **measure the product** — walking each opener's real
  disabled state — rather than string-matching the sentence.
- **A fixture flake, root-caused.** `test_deploy_main.py`'s setsid handshake spun
  200 iterations with no sleep, finishing before the forked `perl` was even
  scheduled, and recorded a pgid its own comment says must be certified. When it
  lost that race `killpg` missed the group and the assertion accused production
  code of orphaning a deploy the fixture never group-leadered.

## 2026.7.14 — 2026-07-27

**Two silent-failure fixes from one live greenfield mission** — a multi-session
ticket no longer loses every commit but its last, and a mission can no longer be
re-homed onto a different (billed) engine just by resuming it from another
terminal. Both were invisible while they happened; both were found by driving a
real mission rather than by reading the code.

### Multi-session tickets keep all their work

- **The defect.** A bounced ticket re-enters the SAME per-ticket worktree with
  the prior session's commit as HEAD — `_tdd_reject` clears `result.json` and the
  output dir, never the tree. So session N committed ON TOP of session N-1, while
  `commit_ticket` recorded a SINGLE `.commit-sha` via `rev-parse HEAD`: the LAST
  commit only. The wave-end replay cherry-picks exactly that one commit (S133:
  "the ticket's tests ride in its ONE commit"), so sessions 1..N-1 were dropped
  on the floor.

  It failed SILENTLY, which is the worst part: every gate — flip-flop,
  declared-edits, quality floor, post-commit — runs against the worktree, where
  the full tree exists. All of them were green and all of them were right. The
  loss happened after the last gate, at replay, with nothing left to re-verify
  the branch.

  Observed live: a Vite+React scaffold ticket took 4 sessions. Session 3
  committed the whole app (13 files); session 4 added only `package-lock.json`.
  The mission branch received the lockfile alone — no `src/`, no `vite.config.ts`,
  no `package.json` — and a sibling ticket's stub `package.json` then replayed on
  top of the hole. The wave read as fully green.

- **The fix.** `commit_ticket` pins the wave base to `.commit-base` on a ticket's
  first session, then SOFT-resets to it before each later session's commit. A soft
  reset moves HEAD only — index and worktree untouched — so the recorded commit
  always carries the ticket's CUMULATIVE diff vs the base. `.commit-sha` keeps
  naming exactly one commit, so the replay, cherry-pick-conflict and
  serial-rebuild paths (all of which already assume one commit per ticket) are
  untouched. `.commit-base` is cleared everywhere `.commit-sha` is, so a serial
  rebuild re-pins against its own base. The single-session path is byte-identical.

Verified by a new scoped suite, `tests/replay-multisession.test.sh` (13), driving
the REAL `commit_ticket` through a new inert `commit-ticket-test` hook: two
sessions in one worktree must leave `.commit-sha` rooted AT the wave base with
the cumulative patch, and an actual cherry-pick of it must land every session's
files on the mission branch. Asserted against the commit's own PATCH, not its
tree — a tree diff passes even for the broken stacked-commit shape. Red on 5
before the fix. Regression: proof-gates 154, unified-implementer 37.

### A mission's recorded engine now outranks host auto-detection

- **The defect.** `resolve_worker_bin`'s precedence ran `$LCARS_WORKER_BIN` >
  `config.json workerBin` > **host-CLI auto-detect** > claude — it never read the
  engine the mission itself recorded in `state.json`. So the engine was
  re-DECIDED from the ambient terminal on every invocation. A mission filed and
  driven under Copilot, then RESUMED from a Claude Code session (`CLAUDECODE=1`),
  silently moved onto billed claude mid-flight with its `workerBin: copilot` pin
  sitting right there being ignored.

  Observed live: 7 workers and **$11.39** billed to the wrong engine after a
  resume from the wrong terminal. Nothing warned — the SPEND was the only
  symptom, and it only surfaced because someone read the per-engine cost split.
  That is precisely why auto-detection must never outrank an explicit record.

- **The fix.** The mission's `state.json` `workerBin` is consulted BEFORE host
  detection. Deliberate operator acts still win — `$LCARS_WORKER_BIN` and
  `config.json workerBin` both outrank the mission pin, so a mission can still be
  moved on purpose — but a guess drawn from whichever terminal happens to be
  driving no longer silently overrides what the mission recorded. A mission with
  no recorded engine falls through to detection unchanged, and the new source is
  reported as `binsrc=mission` in the resolution log. Several callers set
  `MISSION_DIR` but not `STATE`, so the state path is derived defensively and the
  resolver stays silent when there is no mission at all.

Verified by 6 new cases in `tests/worker-resolve.test.sh` (29): a copilot-pinned
mission resolved from a CLAUDE host yields copilot via `binsrc=mission` and does
NOT re-home; `config.json` and `$LCARS_WORKER_BIN` both still outrank the pin;
and an unpinned mission still falls through to detection. `resolve-worker` grew
`--mission <id>` so the pin participates, mirroring how the real spawn paths set
`MISSION_DIR`. (5f/5i in that suite fail on `main` too — a pre-existing
adapter-argv issue, untouched here.)

## 2026.7.13 — 2026-07-27

**`lcars buddy` stops misreporting the config it exists to show you.**

- **The truncated testCommand.** buddy's `json_str` carried the comment "mirror
  status.sh" but had drifted to the old naive sed reader whose value class is
  `[^"]*` — it ends the value at the FIRST escaped quote. That is not an exotic
  input for this reader: S148 makes every `testCommand` LCARS itself seeds QUOTE
  its `$LCARS_TESTS_DIR` scope, so a correctly-configured `config.json` always
  stores `\"`. The brief therefore printed a truncated command
  (`npx vitest run ${LCARS_TESTS_DIR:+\`) for a repo whose config was perfectly
  fine — misreporting the one value a captain runs buddy to verify, and reading
  as if the config had been mangled. `worktreeSetupCommand` (whose JS seed is
  built almost entirely of quoted shell) and any mission `title` containing a
  quote truncated the same way.

  `json_str` is now status.sh's escape-aware POSIX-awk reader, which treats
  `\"` as part of the value and decodes the common escapes on the way out —
  making the "mirror status.sh" comment true rather than aspirational, so the
  two readers cannot disagree about the same file. Display-only and read-only:
  buddy changes nothing, and no gate, stage or driver behaviour is touched.
  `json_raw` is unchanged (bare tokens carry no quotes to escape).

Verified by three regression cases in the scoped suite — a quoted
`testCommand`, a quoted `worktreeSetupCommand`, and a mission title containing
a quote, each asserted to render IN FULL with the expected value held in a file
so the harness's `eval` never re-expands the `$` and `"` it is made of.
lcars-buddy 17.

## 2026.7.12 — 2026-07-27

The Stack Readiness round (S145–147) — **Ruby becomes a first-class stack, the
"no test command" state becomes legible and fixable in one click, and dotnet's
gate legs stop being able to green on nothing.** Two live missions were then
driven end to end on real repos to prove it, which surfaced a further set of
fixes carried in the same PR.

- **The Ruby arm (S145).** Ruby is a supported stack across four seams:
  `detect_stack` markers (Gemfile / *.gemspec / Rakefile / config.ru),
  bundler-aware rspec-vs-minitest seeding, anchored Ruby classifier phrasings,
  and native rspec isolation with ruby as its OWN case (`rust|go` was never
  widened). Ruby joins the zero-collected guard family on day one: a greenfield
  `LoadError` (`0 examples, 0 failures, 1 error occurred outside of examples`,
  exit 1) stays a REAL red rather than being swallowed as zero-collect, and the
  `10 examples` / `0 examples` substring hazard is word-boundary anchored.
- **A legible, one-click-fixable test story (S146).** One shared 4-state verdict
  (`readiness.sh --json|--line`, consumed by both CLI and daemon) surfaces on
  `init` / `update` / `status`, on a board banner, and in the File console as
  **⚡ FIX TEST SYSTEMS** — suggest-or-discover → set → probe in a single action,
  with typing a command as the manual override, never the primary path. CLI
  parity via `lcars update --fix-tests` / `--test-command` / `--probe-tests`.
  A greenfield repo gets a calm bootstrap voice; a broken one gets a repair
  voice; the two never blur. Filing is never blocked — readiness warns and
  offers the fix, because the gates are the enforcement point.
- **dotnet gate-leg hardening (S147).** C# repos now seed `dotnet test <proj>`
  (including the canonical layout where the test project sits below the repo
  root), stage specs INSIDE the discovered test project, and scope each leg by
  declared-class FQN. Observed on a real SDK, not assumed: a `--filter` matching
  nothing, an empty test project, and an all-skipped run **all exit 0** — three
  silent-green paths, all now INCONCLUSIVE. VSTest filters on class FQN, never
  filename, so filter terms are namespace-qualified and dot-terminated (`~` is a
  substring match). Sub-top-level markers count only when they are real test
  systems, so a vendored `.csproj` cannot hijack a js/python/rust repo.
- **Two structural guards, because the source scan was wrong four times.** The
  round found four generations of the same silent green — BOM-stripped
  namespaces, two classes on one line, multi-line strings desyncing brace depth,
  and `#if`-guarded types. Rather than patch a fifth, the design stopped
  trusting the scan: **GUARD 1 refuses to name what it cannot name** (an
  unqualified, generic, or nested type parks the staged set) and **GUARD 2**
  requires the tip leg to collect at least `count([Fact]) + count([Theory])`.
  GUARD 2's real bound is stated in-code: its floor shares a scanner with the
  filter it checks, which is precisely why known-unnameable shapes are refused
  outright instead of left to a count.
- **Proven live, on real repos.** Two missions were driven Align→Verify
  hands-off with live workers — a C# mission and a Ruby mission — each landing a
  correct PR on the first attempt with zero human gates. What they found is
  fixed here: `lcars file --engine` was **silently ignored** on the grill-first
  and `--complete` lanes (a mission pinned to copilot ran on billed claude);
  `flip-flop.json` recorded no leg **command**, so a captain could not tell from
  the artifact whether scoping was ever applied; the copilot model readout said
  Sonnet while every tier resolves to Opus — and priced it at Sonnet rates, so
  the copilot cost band moves up; and the gate-timeout message could tell a
  captain "the tests themselves are not implicated" about a genuinely hung suite.
- **Repos with a space in their path no longer fail their own gate.** The seeded
  test commands interpolated `${LCARS_TESTS_DIR}` unquoted, so a checkout at
  `~/My Projects/thing` word-split the scope and false-FAILED honest work —
  bouncing it to a fresh worker and then parking it. Quoted at the seeder, with
  a migration for already-initialised repos that rewrites only the exact shapes
  LCARS itself seeded (never a hand-written command).
- **A silent green closed, found while fixing the above.** Since Node ≥22,
  `node --test` re-interprets its positional as a GLOB rather than a path. When
  a glob metacharacter sits in the scope path, the leg collects SIBLING test
  files the ticket never touched — on BOTH legs — so a ticket whose staged test
  is a pure cheat, or which declares no tests at all, could be certified PROVEN
  on red supplied by a file outside its own `testFiles`. Reproduced end to end
  for `*`, `?` and a closed `[…]` class. The scope is now refused outright when
  it carries a glob metacharacter (`*` `?` `[` `{` `\`), rendering INCONCLUSIVE
  with the real cause named — the same refuse-what-you-cannot-scope principle as
  GUARD 1. Runner-specific (pytest, rspec and mocha take the path literally);
  jest's regex positional is ledgered as an unexplored neighbour.

## 2026.7.11 — 2026-07-26

The Deploy Main round (S138–139) — deploy **what's already merged**. Until now
the only way to run a repo's app from LCARS was per-mission (`lcars launch
<mission>`); reviewing "current" meant leaving LCARS to start the app by hand.
Now a **DEPLOY MAIN** control runs the local `main` HEAD — no fetch, no pull,
whatever is committed on the machine — through the exact same launch pipeline,
from both the CLI and a top-band button on the viewscreen.

- **`lcars launch --main [hint]` / `--main --stop` (S138).** A target-resolution
  seam on the existing launch pipeline (≈90% reuse): the local default branch
  (config `mainBranch` → `main` → `master`) is resolved by a **local**
  `rev-parse` (never a network fetch), checked out DETACHED into a disposable
  `.git/lcars/launch/@main` worktree, discovered + launched detached with a
  group-killable pgid — exactly as a mission launch. State lives under
  `.git/lcars/main/`; the record adds `branch` + a short `sha` on the main path
  only (the per-mission `launch.json` is byte-identical). `--main` is mutually
  exclusive with a mission id, and `@main` is reserved.
- **DEPLOY MAIN band control + daemon endpoints (S139).** A `▸ Deploy Main`
  button in the yellow band opens a small console (optional instructions) and
  deploys via the daemon; the band flips to `● MAIN LIVE` — short sha, clickable
  URL, and an integrated `■ STOP` — synced to every browser over SSE. New
  `POST /api/deploy/main` + `/stop` (read-only builds 403 both); an additive
  `meta.mainLaunch` payload rides the board only when a deploy exists (absent ⇒
  byte-identical). The deploy's pgid joins the daemon's shutdown group-kill.
- **Redeploy no longer orphans (both paths).** A relaunch while an app was still
  running used to spawn a new process and leak the old one (a pre-existing bug on
  the mission path too); the stop kill sequence is now applied before every
  relaunch, so the prior process is reaped first.
- **AI-session guard on the viewscreen.** Starting the board from inside a
  sandboxed Claude Code / Copilot session gives a half-working board (DEPLOY
  MAIN / launch can't reach the desktop). `viewscreen.sh` now refuses and prints
  a copy-paste `cd <repo> && lcars-viewscreen --open` to run in a real terminal
  (bypass with `LCARS_VIEWSCREEN_ALLOW_AI=1`).
- **Docs.** README quick-start now `cd`s into *your* project first (everything
  acts on the repo you're in — not the LCARS repo); the SSE fingerprint watches
  the main-deploy record so a deploy/stop pushes live to passive browsers.

## 2026.7.10 — 2026-07-25

The Park & Align round (S136–137) — a backlog-fast capture lane for `lcars
file`. An idea can now be **parked** with just an engine and the raw text: the
Mission and its GitHub issue are created instantly in a new pre-PRD **standby
state**, dropped in the Align column *awaiting alignment*, and the Align grill
runs later, on demand — from the CLI or one click on the board. Backlog fast;
grill when ready.

- **The parked state + verbs (S136).** `lcars file --park "<idea>" [--engine
  claude|copilot]` mints the mission dir + issue with `prdPending: true` (no
  grill, no PRD, no type, no estimate; labels `lcars:mission`+`lcars:align`
  only). `lcars file <id>` resumes: it runs the warm grill seeded from the
  captured `idea.md`, then `lcars file --complete <id> --prd <path>` validates
  the PRD, writes it, derives type/title, retitles + re-bodies the issue **in
  place** with a type label added, runs the estimator, and clears `prdPending`
  **last** (a failed issue update leaves the Mission parked and exits non-zero so
  a re-run retries — nothing partial). The result is byte-equivalent to a
  grill-first filing, `idea.md` the only extra artifact. Every "align ⇒ PRD
  exists" consumer is guarded: the driver/Research refuse a parked Mission with
  an actionable align hint (never a stack trace), the bare-`lcars` resolver
  offers parked Missions as a distinct *awaiting alignment* group but never
  auto-drives them, `lcars status` shows a ◇ standby row, and the comment-mirror
  does not drift. Grill-first `lcars file` is byte-identical.
- **Viewscreen quick-park (S137).** A **Park** affordance in the File console
  (engine + idea + optional pasted images) files instantly via `POST /api/park`;
  parked Missions render in the Align column with a themed *◇ STANDBY — AWAITING
  ALIGNMENT* badge and a **START ALIGNMENT** action (never a runnable Start). It
  opens the existing warm grill seeded from the parked idea, completing via
  `file.sh --complete <id>` so the card swaps standby → aligned in place on the
  SSE push (estimate pills appearing as usual). The board payload is additive
  (`prdPending` only when parked — old cards byte-identical); read-only builds
  403 the park + parked-align-start endpoints and hide the affordances. Full CLI
  parity — every button maps to a `lcars file` capability.
- **Viewscreen alignment UX (S137 follow-ups, from live captain testing).** The
  detail modal mirrors the card for a parked Mission (▹ START ALIGNMENT, never a
  runnable Start) and shows an *◇ STANDBY — AWAITING ALIGNMENT* panel instead of
  a placeholder PRD; **Mission Log is Verify-only** (it belongs at the demo-day
  checkpoint). START ALIGNMENT gains a persistent animated **scanning band** +
  a click-guard (no duplicate grill sessions), and closing an unrelated overlay
  mid-scan no longer aborts it. In the File console **Park is the default
  primary** (`◇ File to Backlog`), with *File & Begin Alignment* secondary.
- **Resume mid-grill + backgroundable finalize (in-session).** Closing the Align
  console mid-grill now **preserves** the warm session: the card + detail flip to
  **▹ RESUME ALIGN** (surfaced on both `/api/board` and `/api/mission/<id>` via an
  additive `alignResume` overlay, so it survives a page reload) and a new `GET
  /api/align/<sid>` reopens the interview at its current question. Closing during
  the closing-turn estimate shows a **◐ FINALIZING & COSTING…** band and the card
  swaps to aligned on its own when `file.sh --complete` finishes. In-memory only
  (a daemon restart drops an in-progress grill; the Mission simply stays parked).

## 2026.7.9 — 2026-07-24

The Unified TDD Implementer round (S132–135) — retire the adversarial Test
Writer / Implementer standoff for ONE cold TDD worker per ticket, with
correctness enforced by three deterministic, post-hoc proof-of-work gates
instead of a second agent's judgment. A gate rejection bounces to a fresh worker
(≤3 sessions) then parks awaiting-human — no worker can fail terminally on
quality grounds. Full replacement, no fallback flag; the standoff code is retired
to git history (`run.sh` −1,335 LOC).

- **Proof-of-work gates, standalone (S132).** `flip_flop_gate` (a ticket's
  new/changed tests must FAIL on the parent commit and PASS on the tip;
  zero-collected = inconclusive, never a pass), `declared_edits_guard`
  (undeclared edits to existing tests BLOCK; declared `{path,reason}` ride to
  Verify), a `result.json` v2 contract, and a quality floor — built and
  fixture-proven while the live path still ran the old standoff.
- **The path flip (S133).** `cmd_implement_ticket` drives ONE `implement-tdd`
  worker → the S132 gates → bounce-3-then-park. The Test Writer, red-gate
  choreography, `tests.sha256` lifecycle, and `reconcile_tests` are deleted; the
  `ticket_test_writer_failed → die` class no longer exists. Env-truth machinery
  (preflight/self-heal, declared-setup invitation, worktree isolation,
  full-suite gate, empty-worker budgets) is byte-preserved.
- **Surfaces + doctrine (S134).** Verify shows a per-ticket flip-flop verdict
  chip (PROVEN / N-A) + a "CONTRACT AMENDMENTS" block (declared edits verbatim)
  on both the CLI and the board from one shared shape; single-ticket missions
  surface their proof via a mission-level fallback. Board activity renders the
  gate events in LCARS voice with a worker-session marker on bounce and no role
  chip. `vision.md` / `CONTEXT.md` / `CLAUDE.md` / `README.md` + the rendered
  `docs/` HTML tell the unified doctrine. Display-only; pre-S133 missions render
  byte-identically.
- **Dual-CLI cutover capstone (S135).** Two real missions driven Align→Verify
  hands-off, one per engine (claude + copilot), through the unified path — every
  ticket flip-flop-proven, zero test-writer events, zero stage-stop dies. First
  real missions through S112 usage capture; validate + implement are the cost
  peaks.

## 2026.7.8 — 2026-07-11

The Actual-Cost & Honest-Progress round (S111–115) — replace two guesses with
truth: measured per-mission cost, and a real activity signal in place of the
fake pulse. Everything is additive and display-only; no gate changes, and the
no-usage path stays byte-for-byte as before.

- **Per-engine usage-capture spike (S111).** Both engines expose what one cold
  `-p` worker actually spent via a minted `--session-id` + the CLI's own on-disk
  session artifact (claude transcript / copilot session-state `events.jsonl`),
  parsed after exit — stdout format untouched, so no `.worker.out` consumer
  breaks. Recorded in `skills/lcars-run/USAGE-CAPTURE-SPIKE.md` with fixtures.
- **Actual usage capture (S112).** Every cold-worker spawn appends its real
  usage to the mission's `usage.json` and emits a `worker_usage` event, cost
  computed by code from `pricing.json`. A missing artifact degrades to a
  recorded `"unavailable"` entry and never fails a stage; capture-off argv is
  byte-identical. New `run.sh usage <mission>` sums per-stage + total.
- **ACTUAL cost pill (S113).** At Verify/Done, mission and mission-log cards show
  an ACTUAL pill beside the estimate — same billing-unit rules — plus an
  "EST → ACTUAL" line in the detail modal, Verify dialog, and CLI verify
  summary. Absent/partial usage renders honestly; per-mission only (no roll-up).
- **Honest liveness (S114).** The make-believe CSS pulse becomes a real signal
  derived from the hang-guard's existing output watch — THINKING / WRITING
  OUTPUT / SUBSPACE QUIET Ns (+ hang-guard-watching) on the board and
  `lcars status --watch`. Removed on worker exit; the CLI tail is gated on a live
  driver lock so a crashed driver can't show a false "producing".
- **Collapsible activity sections (S115).** A big mission's detail feed groups
  into collapsible per-wave/per-stage bands — completed waves fold to one LCARS
  summary band with graphic stat chips (tickets / attempts / duration), a
  wave-health micro-bar, and a flagged badge; the active section stays open,
  everything expandable, nothing lost. Mission-log parents get the same idiom.
  Motion honors `prefers-reduced-motion`; cards and board shape untouched.
- **Docs.** First screenshots in the repo (viewscreen board, Mission Log,
  Re-Verify gate) added to the README and vision guides.

## 2026.7.7 — 2026-07-09

The Multi-Stack Breadth round (S104–106) — LCARS goes from JS/TS-and-Python to
*recognizing and running* compiled/managed toolchains. Every change generalizes
the harness and never loosens a gate: a new stack makes rejection MORE precise.

- **Per-stack classifier arms (S104).** The S96 table-driven red-gate classifier
  (`rg_signature`) gains Rust / Go / .NET / JVM arms. A `cargo` compile error,
  a Go "cannot find package", a C# `error CS####`, or a javac "cannot find
  symbol" is now named as the compile/resolution failure it is — while a genuine
  cargo/go assertion failure stays a valid red. Each signature is anchored to the
  way each toolchain prints its own diagnostic, so an assertion diff that merely
  quotes a compile phrase can't false-match. Every JS/Python arm is byte-identical.
- **Stack detection + per-stack defaults (S105).** `lcars init` (and `lcars
  update`) detect the repo's stack from its markers — Rust, Go, Python, JS/TS,
  .NET, JVM; several markers → `ambiguous(list)`; none → `unknown` — via a shared
  `detect_stack()`. They seed a MISSING-only `stack` key and a per-stack test
  command, warning (never guessing) on ambiguity. Customized values survive both
  re-init and update untouched.
- **Per-stack test isolation (S106).** The Implement red gate now isolates a
  ticket's fail-first tests for compiled runners whose tests live *inside* the
  crate/package and can't be pointed at an external dir. Keyed by the `stack`
  key: Rust stages an integration test scoped by `cargo test --test`; Go stages
  an in-package `_test.go` scoped by `go test -run` (leading-letter name — a
  spike-caught Go `_`-prefix file-invisibility false-green is avoided); JS/Python
  keep their `$LCARS_TESTS_DIR` path byte-for-byte. A file-absence probe enforces
  scope-was-honored per stack — green-on-nothing or unprovable scope BLOCKS loud,
  never a silent green. Immutability, ride-along-into-the-PR (at each stack's own
  convention), and staging cleanup on every exit are preserved.

Proven by a live dual-CLI capstone: two real fixture repos driven Align→Verify
hands-off with zero interventions — a Rust crate on Claude and a Go module on
Copilot — each reaching Verify on the first attempt with its fail-first test
riding into a real PR via the native isolation gate.

## 2026.7.6 — 2026-07-09

The declared-test-setup ↔ placement contract round (S131) — a one-off harness
fix from the 2026-07-09 groutwork demo failure, where a test-writer's declared
vitest config (`include: tests/**`) disagreed with the harness's S101 placement
(co-located under `src/`), collecting zero tests through three blind retries
and a terminal `over-broad-slice` misclassification.

- **The invitation states the placement contract.** The declared-setup block
  now names the DETECTED test convention (co-located / `__tests__` / `tests`)
  with a concrete example placed path — computed by the same
  `detect_test_convention`/`test_path_for` calls placement itself uses — and
  instructs that any authored runner config must collect that location (safest:
  don't narrow `include` at all).
- **Setup-aware zero-collect diagnostics.** When the self-smoke collects zero
  tests and a declared setup was applied this mission, the bounce quotes the
  runner's own `include:`/`filter:` lines and the placed in-tree test path and
  says they must agree — no more blind retries.
- **Honest terminal category.** That exhaustion signature now reads
  `test-infra-mismatch` (naming the package), not `over-broad-slice`, which
  remains for genuine no-coherent-red cases.

Red-gate semantics, S101 placement, and the evidence gate are untouched
(verified zero-diff). Proven by re-driving the failed demo mission hands-off
Align→Verify on BOTH engines (copilot + claude): setup invited/applied/
probe-verified, co-located placement collected, one attempt per role, zero
infra stalls (groutwork PRs #203/#205, torn down after the pass).

## 2026.7.5 — 2026-07-08

Docs catch-up for 2026.7.4: `lcars launch` (the deploy/run-app feature) and the
S111 test-setup robustness round are now documented in README.md and vision.md
— the launch command + Verify RUN/STOP flow, the runner preflight, the
evidence-gated declared test setup with probe-verified installs, the test
landscape, root-tree sovereignty, and the objective-residue testing rule — with
both rendered docs/ mirrors updated and their source-hash breadcrumbs
refreshed (docs-sync guard green).

## 2026.7.4 — 2026-07-08

The run-app + test-setup robustness round. Two features, one hardening sweep —
proven live by driving three groutwork missions Align→Verify (two fully
hands-off, including a runner-less package) plus four mission-log bugs across
both engines.

**`lcars launch` — deploy/run a mission's app for Verify.** A `launch`-role
cold worker DISCOVERS how to start the app in a disposable detached worktree
(dep provisioning included); the skill starts it detached, owns the process
group, and records launch.json for both the CLI and the viewscreen. RUN/STOP
land on the board's Verify dialogs (daemon-owned launches, per-mission
instances, target pinning, card badge). The discovery worker writes a PRIVATE
launch-discovery.json and launch.json is written only atomically — the mid-
launch RUN-button flash is gone.

**Test-setup robustness (S111).** The Test Writer can now survive contact with
any package's test reality:
- The red gate triages an un-launchable runner BEFORE the ignored-var verdict
  (rc-3 "cannot run tests here" escalates instead of burning retries), and a
  RUNNER PREFLIGHT probes the ticket's package before any worker spawn.
- EVIDENCE-GATED DECLARED SETUP: when the preflight proves a package cannot
  run tests while the repo tests elsewhere (sibling runner declarations count),
  the Test Writer is invited to declare the missing infra (ADD-only whitelist,
  package-manager installs only); the harness applies it PROBE-VERIFIED —
  exit codes are never trusted, pnpm's symlink/virtual-store no-ops are healed
  by a forced relink cycle at every gate door — and a verified green records
  the facts to `.git/lcars/test-landscape/`.
- ROOT-TREE SOVEREIGNTY: missions never touch the captain's checkout again —
  commits land via an ephemeral landing worktree under the replay mutex, the
  self-heal and reconcile no longer check out or detach the root, and PR-open
  pushes by ref. Switching branches mid-drive is safe by construction.
- Fail-loud isolation: no silent in-tree fallback when a worktree cut fails
  (stale registrations self-heal via prune+retry), and the post-commit gate
  names WHERE stray code landed (the wrong-tree suspect note).
- Worker comprehension: the resolution-failure hint now states a per-specifier
  VERDICT (module exists at <path> → fix the import / no match → must stub),
  greenfield tests place INSIDE the target package, and the Test Writer/Planner
  carry the objective-residue rule — never invent numeric proxies for taste;
  subjective qualities are the captain's Verify judgment.
- worktreeSetupCommand's node_modules find prunes .git (launch worktrees carry
  node_modules there), and the npx no-binary phrasing joined the env signatures.

## 2026.7.3 — 2026-07-06

Drift detection no longer false-positives after a merged PR. The `drift` verdict
("main moved without a version bump") now counts only real content commits since
the last `VERSION` touch (`git rev-list --count --no-merges`), so the PR **merge
commit** — which always trails the bump under a merge-commit workflow and never
touches `VERSION` — no longer trips drift after every merge. A genuine
unversioned content commit on `main` still drifts. No other behaviour changes.

## 2026.7.2 — 2026-07-06

Viewscreen update-banner UX polish. The version banner now drops clear of the
LCARS frame — a gap below the solid yellow top band — and its left edge lines up
with the board columns (the ALIGN column) instead of floating in from them. The
repo-stale copy names LCARS explicitly and shows both the current and target
version — *UPDATE LCARS IN THIS REPO — &lt;from&gt; → &lt;to&gt;* rather than the
ambiguous "REPO NEEDS UPDATE" (which read as the repo's own code being stale); an
unstamped repo that predates versioning says so instead of a from-version. The
board's `meta.version` block now carries the viewed repo's stamped version to
feed that from→to. The banner is now shown **only for actionable states** (source-behind or
repo-stale/predates, each with an update button); a drift-only state ("main
moved without a bump") is a maintainer signal surfaced in the CLI, not a
persistent board banner — so a successful update, which leaves at most drift,
clears the banner instead of stranding a confusing red bar. Pressing **ENGAGE
UPDATE** now gives
visible feedback: the band turns LCARS blue ("UPDATING LCARS…") while pull →
install → `lcars update` runs, then teal ("UPDATE COMPLETE") on success, before
the live SSE tick clears it — instead of only changing a small message string,
which read as "still running." No behavioural change to the check, the update
action, or `lcars release`.

## 2026.7.1 — 2026-07-05

Genesis release: the LCARS harness through the image-paste round. LCARS is a
reusable AI harness that drives a human idea all the way to a merged PR through
the full pipeline — Align → Research → Validate → Plan → Plan Review → Schedule
→ Implement → Verify — with each headless stage spawned as a cold, isolated
worker. It runs on either supported CLI (dual-CLI: `claude` and `copilot`),
surfaces every active Mission on the viewscreen Kanban board, lets the captain
log bugs against an in-flight Mission and drive them through mission-log
grounding (a read-only worker anchors each symptom to the parent Mission's
existing code before a fix is planned), and accepts pasted images as Mission
input threaded through the cold stages. Full history prior to 2026.7.1 lives in
git — see `git log`.
