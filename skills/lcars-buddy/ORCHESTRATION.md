# ORCHESTRATION.md — how an LCARS orchestrator runs a session or a fix

This is the **one** statement of the orchestration loop: implementor (TDD) →
a fresh tester at the declared proof surface → fix rounds with a regression
guard → teardown → commit → readout.

**Where these rules come from.** They were written on 2026-08-02 after the S163
post-mortem (`lcars-dev/s163-post-mortem.md`) and a review of every session from
S140 on, and were extracted into this shared file on 2026-09-11 (S197) because
three skills were each restating them and had begun to drift. Two findings drive
nearly all of them:

1. **Round count tracks one variable: whether the harness faked the layer the
   work was changing.** S163 changed the board's rendering and faked the browser
   — 7 rounds, 3 of them against a product that was blank in Chrome while 1,162
   tests passed. S157 changed a gate that inspects real repos and faked the repo
   — 5 rounds, and the real defect was found by the first live drive. S159
   changed driver behaviour and faked the worker — its one live drive proved a
   live worker ignores the prose pin it depended on. Against that: S140 tested on
   real Chrome (1 round) and S166 on six live Copilot drives (2 rounds).
2. **Rounds are not the enemy — unproductive rounds are.** S158 also ran 5 rounds
   and found 26 real defects with a fully real harness (real git, real bare
   remotes). All 26 were in the thing it built. S163's were 4 of 20. The number
   that matters is **what fraction of defects were in this work's own scope**.

Every rule below keeps the example that justifies it. **A rule without its reason
gets undone** — that is why the S156/S163/S188 stories are in here and not in a
post-mortem nobody re-reads.

---

## Who reads this

Three consumers, one file:

- **`run-session`** (lcars-dev) — orchestrates one session from a `*-dev.md`
  session-plan doc.
- **`night-watch`** (lcars-dev) — chains sessions unattended; adds its own rules
  *on top of* this file.
- **`lcars buddy`** (this skill) — orchestrates one **fix** to LCARS, driven from
  whatever foreign repo the captain happens to be in.

Read it at the install path, which is stable from any cwd because `install.sh`
symlinks this skill dir into `~/.claude/skills/`:

```
~/.claude/skills/lcars-buddy/ORCHESTRATION.md
```

**This file wins over any restatement.** If a skill, a doc, or a script says
something different about the loop, the pre-flight, the fix rounds, the branch,
the trailer or the readout, this file is right and that text is a stale copy —
fix the copy by deleting it and pointing here. Each consumer keeps only what is
genuinely its own (run-session keeps roadmap resolution and its briefing;
night-watch keeps its unattended additions; buddy keeps its own refusal rule).

---

## Pre-flight

Run these **after** the go-ahead and **before** any sub-agent.

- **The proof-surface check — this one can refuse to start.**
  Name the layer this work changes, and the layer the tester will drive. **If the
  work changes a layer its harness fakes, do not start.** Fix the harness first,
  or re-scope, and say which you're doing. The recurring instances, all of which
  shipped as multi-round sessions:
  - changes what a page **looks like or does in a browser** → a Node DOM harness
    is a *stub of a browser*. Every harness in `web/tests/` calls `render()`
    itself, so none of them can tell a working board from a blank one. Drive
    **real headed Chrome**.
  - changes something that inspects **real repositories** → fixtures miss what
    real repos have (LCARS symlinks `node_modules`; `node_modules/` is a
    directory-only gitignore pattern — that combination made a gate blame its own
    provisioning artifacts on the worker, and five fixture rounds never saw it).
  - changes **what a live model reads or chooses** → a stubbed worker cannot
    reproduce it. Drive live Copilot.
  - changes **CSS or anything the cascade decides** → a rule-exists test passes
    while the screen is grey. Resolve the real cascade or read computed style.
- **The infer-vs-record check.** Ask of the thing about to be built: *does it work
  out a fact by reading finished output, when it could have written that fact down
  when it produced it?* If yes, record instead — before you build it, not after a
  tester beats it.

  This has cost three sessions multiple rounds each, and the tell is always the
  same: the code reads back text a human also writes, so the human's wording
  eventually collides with it.
  - **S147** — four generations of a source parser, each beaten; cured by
    refusing to judge what it cannot name.
  - **S156** — a regex classifier whose recall collapsed when the tester reworded
    its corpus preserving meaning; cured by moving the decision to a declared
    flag and deleting the signals.
  - **S188** — twice in one session. A guard inferred from the whole issue body
    whether content had been lost (beaten by a PRD's own `---` rules and by an
    honest scope cut); its replacement inferred from headings (`^## Estimate$`,
    the four ADR field names) which parts a body carried, and was beaten by a PRD
    that merely *mentioned* them. Cured by having the composer record the parts it
    emitted, checksummed to the body it produced.

  The captain writes specs *about LCARS*, so any heuristic that reads LCARS's own
  vocabulary will eventually be handed a document containing it. Treat "the
  producer records it" as the default and inference as the thing needing a reason.
- **Zero-spend pinning:** if this work is meant to cost nothing, pin it with a
  **PATH shim faking both `claude` and `copilot`** — never an env var. The engine
  arrives from three places with a different winner per path (request body,
  `LCARS_WORKER_BIN`, persisted `state.json workerBin`), and S159 measured an env
  var losing to a persisted `workerBin`. **Report the shim's invocation count and
  how many carried a `--model`** and would have billed.
- **Engine auth:** if real drives are in scope, confirm the needed CLI(s) are
  authenticated before spending anything.
- **Cost rule — NEVER run the full suite.** Never run the heavy
  `tests/lcars-run.test.sh` or the full `bash tests/run.sh` to completion during
  a session or a fix — they are slow, billable, and have hung whole sessions.
  **Fast scoped suites only** (`bash tests/<name>.test.sh`). The full run belongs
  to `ship-it`'s merge gate; see *Build contract*.
- **A pre-flight failure means stand down** — report it; work started on a bad
  base wastes its whole hand-off.

---

## The loop

Each piece of work is driven by ONE **orchestrator**. **The orchestrator writes
no production code itself** — it spawns sub-agents and runs this loop:

1. **Implementor sub-agent (TDD).** Given the goal + the "Behaviors to drive with
   /tdd" list, it writes the failing tests **first**, implements until the scoped
   suite is green, runs the install/build step (`./install.sh` in LCARS, so the
   change is the code that actually runs), and returns a summary of what changed.
2. **Tester sub-agent (fresh, captain stand-in).** A *separate* sub-agent that
   never saw the implementor's reasoning. It does NOT read the code to decide if
   it works — it **uses the product for real** and judges from the outside:
   drives the real entry points end-to-end against the sandbox, answers every
   human gate as the captain would, and reports each defect as *what it did /
   what it expected / what it saw*. It must not edit source or tests; fixes route
   back through the orchestrator. It logs every artifact it creates for teardown.
   **Its first action is to confirm the product works at all** at the declared
   proof surface (see the next section) before hunting specific behaviours.
3. **Fix loop.** For each defect the orchestrator spawns a **new** implementor
   sub-agent (fresh context, given the defect + the tester's observation),
   re-runs the tests, and re-invokes the tester. Repeat until the tester reports
   clean. Every fix round must also: re-run the previous rounds' cures and show
   them green, deliberately read the lines its diff REMOVED, and not refactor
   while curing. **At the end of round 3 the orchestrator STOPS and asks.** After
   round 1 the tester brief narrows to the specific cures plus a short
   regression; the full sweep returns on the final round. No sub-agent runs past
   ~60 minutes without a check-in.
4. **Teardown.** The tester tears down everything its runs created — locally and
   remotely — leaving the sandbox clean (reuse, don't delete, between rounds). No
   orphans. **Never tear down before the verdict is final**, and rigging worth
   keeping gets committed under `tests/drives/` rather than rebuilt by the next
   round.
5. **Commit + readout.** The orchestrator commits the implementor's work + the
   fixes to the work's branch (see *Build contract*), then reads out per
   *Readout*. No PR unless asked.

**An invariant touch is a STOP.** Honour every invariant the work declares (a
session doc's *What we are NOT changing*; for a buddy fix, the protected
machinery: the Implement proof gates (flip-flop, declared test-edits,
quality floor), the ≤3-sessions-then-park bound, env-injected/stubbable CLIs). If
a change would touch one, **STOP and
report** rather than papering over it.

---

## The tester opens the real product first

Before any harness-driven testing, the tester's first action is to use the thing
the way the captain would and confirm **it works at all**. On a viewscreen
session that means: start the daemon, open it in real headed Chrome, take a
screenshot, and look at it. On a buddy fix it means: re-collect the brief (or
re-drive the failing verb) from the foreign repo and read it. Only then go
hunting for the specific behaviours.

This is a captain directive (2026-08-02) and it is not negotiable on any visual
session. It costs nothing to run. Three hours of S163 were spent testing a board
that was blank in a browser.

Use the committed rig if one exists; if you build one, commit it rather than
tearing it down (see *Inherit the rig*).

---

## Every fix proves it didn't break the last

45% of S163's defects were made by the fix loop itself. Every implementor in a
fix round must, before reporting:

- **Re-run the previous rounds' specific proofs**, not just its own new test.
  Keep a short accumulating "cures so far" list and show it green. They're unit
  tests; this is cheap.
- **Read the lines it REMOVED.** `git diff | grep '^-'`, reviewed deliberately.
  The blank board was a deleted `.then(render)` — someone wrote an explanatory
  comment beside the line and the line went with it. Nobody looked at deletions
  for two rounds.
- **Not refactor while curing.** Cure the defect; restructure separately and test
  the restructure on its own. Both of S163's mid-session restructures were the
  right call and both produced the next round's defect.

---

## Three fix rounds, then STOP

At the end of the third fix round, do not start a fourth. Come to the captain.

This is not merely a cost cap. **Every session that went past three rounds was
eventually cured by deleting or restructuring something, never by the next
patch:**

- S147 — four successive generations of a source parser, each beaten; cured by
  refusing to judge what it cannot name.
- S156 — a regex classifier whose recall fell 14/14 → 5/14 when the tester
  reworded its own corpus preserving meaning; cured by moving the decision to a
  declared flag and **deleting** the signals.
- S157 — five versions of an anti-gutting guard, each beaten, one caught
  false-failing an honest repair; cured by deleting ~1,000 lines for one
  source-blind check.
- S158 — fifteen verdict names; cured by consolidating to four, because the name
  count *was* the lying surface.
- S163 — seven rounds; cured by driving a real browser.

So at round 3, present: what's fixed, what's open, what it has cost so far, and a
recommendation drawn from **one of these two moves** — (a) make the harness real
at the layer that keeps surprising you, or (b) delete or restructure the
mechanism that keeps generating defects. "Apply the next patch" is not one of the
options.

Ask in **plain English**, describing what happens *to the captain* in the
product, **as a story — never in harness jargon**. S163's first attempt at a
check-in used option labels full of internal vocabulary and was rejected twice
with "Plain English"; the re-ask got an immediate, decisive answer. The one
check-in that session did make took five minutes and produced its best decision.

When nobody is awake to ask (an unattended run), the stop is absolute: write up
the two options and park it for the morning.

---

## Inherited defects are ledgered

If a defect **predates this work**, the default is: write it up, file it, ledger
it in the readout — do **not** cure it inline. Seven of S163's twenty defects
were inherited from sibling sessions on the same unmerged branch, and curing them
turned a one-session slice into a mini-round.

The exception, which is **the captain's call and not yours**: when the inherited
defect makes *this work's own feature dishonest*. Bring it to them with the
story, in plain English, and let them rule.

---

## Inherit the rig

Seven S163 tester rounds each rebuilt the same fixture scaffold from scratch, and
one tore it down before its verdict was final, so the next round had to rebuild
rigging five rounds had accumulated. **Reuse the rig between rounds.** When the
work invents rigging worth keeping, **commit it under `tests/drives/`** rather
than discarding it. **Testers must not tear down until the verdict is final.**

---

## Narrow briefs after round 1

Round 1 verifies the whole feature. After that, verify **the specific cures plus
a short regression**, and save the full sweep for the final round. The unit
suites are the regression net; a human stand-in re-driving everything by hand
every round is redundant with them and cost 40–60 minutes a round, seven times.

---

## Time-box and verify claims

No single sub-agent run goes past **~60 minutes** without a check-in (one S163
run went 144 minutes unbounded). And when a sub-agent reports something
structural — "exactly two call sites", "all suites green" — spend 30 seconds
confirming it yourself: one `grep` would have confirmed the blank board in ten
seconds, and it was available for six rounds. **Spot-check *positive* claims
too** — six rounds of "suites green" were true and meaningless.

### A spot-check needs a known-good control

**Every spot-check MUST include a known-good control — a case whose expected
result you already know — or it cannot detect its own breakage.**

The story, written down because a rule without its reason gets undone. On
2026-09-11 an orchestrator verified a HIGH hang-fix with a probe loop that built
its arguments in a shell variable:

```
for a in "--five-hour" "--five-hour 50 --weekly 10"; do  bash usage.sh gate $a ; done
```

That shell does **not** word-split an unquoted variable, so the script under test
received ONE joined argument and correctly rejected every case. Every probe read
`exit 64, pass` — including the valid pair, which should have passed. The
verification step had produced its own false green, and it was the same shape of
error the spot-check rule above exists to catch. It was caught only because a
later run included a **valid case whose `exit 64` was impossible**.

So: **pass probe arguments literally, never through a variable**, and always
include one case you know must succeed.

### Inspect the thing, don't measure a correlate of it

**When you can look at the artefact itself for the same effort, looking beats
measuring something that merely correlates with the fault.** Written down after
this failed THREE TIMES IN ONE NIGHT (2026-09-16/17), each time in a different
costume, each time with the real check available and cheap:

| the claim | the proxy used | what it missed |
|---|---|---|
| "the test fixture is sound" | `.bin/vitest` exists on disk | it did — but the PACKAGE it points at was a dangling symlink into a deleted worktree. **The repo's tests could not run at all.** Running them would have taken 20 seconds. |
| "the walkthrough's images are fine" | image DIMENSIONS (tall+narrow ⇒ suspect) | a crop of the WRONG COLUMN that was neither tall nor narrow. The captain found more after the proxy declared the rest clean. **Opening them found every fault in one pass.** |
| "the test failures are the node_modules symlinking" | reasoning from `worktreeSetupCommand`'s text | the actual cause was a double `cd` — the gate runs the command from INSIDE the package, so a command that also steps in lands nowhere. **A two-line shell test settled it.** |

The tell is always the same: **the proxy answers a question NEAR the one being
asked.** "A binary is present" is near "the tests run". "This image is an odd
shape" is near "this image shows the wrong thing". Near is not the same, and the
gap is exactly where the defect lives.

**So: if the real check costs a command, run the command.** Reserve inference for
things that genuinely cannot be observed — and when you must infer, say in the
readout that you inferred, so the next reader knows what was actually established.

**This sits beside the known-good control rule above, and they compose:** a
control proves your check can detect the fault; inspecting rather than measuring
proves you are checking the fault at all.

### Cage a hang probe in its own PROCESS GROUP

`perl -e 'alarm N; exec @ARGV'` does **NOT** reliably kill a blocked probe. On
2026-09-11 bash waiting on a command-substitution child survived `SIGALRM`, a
probe ran past 120 s, and an orphan held the tester's stdout pipe open — twice.

Use a process-group cage: `start_new_session=True` to put the probe in its own
group, `killpg` to kill the whole group on timeout, and **report ELAPSED time**
so a fast pass is distinguishable from a kill. The reference implementation is
committed:

```
python3 tests/drives/s197/cage.py 5 bash skills/<name>/<script>.sh <args…>
```

It also gives the probe `stdin=DEVNULL`, which matters more than it sounds:
these suites use a `qgrep` helper that drains stdin, so an uncaged run from an
interactive shell blocks on its own first assertion.

**A caged run that does not come back is NOT proof of safety** — it is the hang,
reported.

### Two mechanisms hang a suite, not one

BUG-089 — a harness helper's bare `cat` blocking on inherited stdin — is the
famous one, and `stdin=DEVNULL` closes it. There is a **second, independent** one:
the LCARS **version check**. It throttles on `LCARS_VERSION_STAMP`, which defaults
into `$HOME`, so under a redirected `$HOME` or an isolated install the stamp is
always absent, the throttle never engages, and every call runs
`git fetch origin main`. Against a network `origin` with no usable credential that
fetch asks for one — **and closing stdin is not a defence**, because git never
reads the prompt from stdin. Measured, with controls:

| condition | result |
|---|---|
| worktree (origin = GitHub) + fake `$HOME` | **600.1 s HUNG** |
| `GIT_TERMINAL_PROMPT=0` only | **still hung** — git prefers `$GIT_ASKPASS`, and an editor's askpass helper waits forever for a GUI answer |
| `+ GIT_ASKPASS= SSH_ASKPASS= -c core.askPass=` | 0.4 s, degrades to "could not reach origin" |
| clone whose `origin` is a local path + fake `$HOME` | 8.3 s, PASS |

`check.sh` now sets all four, so the fetch fails fast instead of prompting. When
a suite hangs, check **both** mechanisms — and remember the obvious variable
(`GIT_TERMINAL_PROMPT=0`) is not the one that was blocking.

---

## Build contract

The contract for building LCARS is `CLAUDE.md` in the LCARS checkout
(`CLAUDE.md:43-54`). Restated, because an orchestrator working from a foreign
repo needs it to hand:

1. **Author in the repo.** Create/edit `skills/<name>/SKILL.md` and its script —
   **never** under `~/.claude` (that is the install symlink farm;
   `CLAUDE.md:9-20`).
2. **TDD it.** Write the failing case in `tests/<name>.test.sh` first, then make
   it pass. Keep logic in a bundled shell script (not buried in prose) so it
   stays testable, and take external dependencies via env vars
   (`LCARS_GH_BIN`, `LCARS_WORKER_BIN`, …) so tests can stub them.
3. **Install — ISOLATED.** `./install.sh` so the change is the code that actually
   runs, but **never a bare `./install.sh` mid-session**: install into a scratch
   dir with a single `LCARS_INSTALL_PREFIX=<scratch>`. An LCARS install writes to
   FIVE destinations under `$HOME` and setting only one of the five individual
   variables does NOT isolate the install — `install.sh`'s own header block names
   all five and explains the hazard. A bare run off a WIP branch repoints the
   captain's live launchers and Copilot plugin at it. The fifth,
   `LCARS_VERSION_STAMP`, is written by `skills/lcars-version/check.sh` rather
   than by `install.sh`, which is how it stayed uncounted for a round — and it is
   not cosmetic; see the hang rule above.
4. **Verify.** See the scoped-suite rule below.
5. **Commit.** Source, test and doc updates are all tracked. Nothing that lives
   only in `~/.claude/` counts — it doesn't ship.

Three things the contract did not say, written down here (and now in `CLAUDE.md`
too — this file quotes the contract, not the reverse):

- **Branch naming.** Cut from `main`, **never commit to `main`**:
  - a round / session → **`feat/<round>`** (e.g. `feat/portability`,
    `feat/buddy-orchestrator`).
  - a fix → **`fix/<slug>`** (e.g. `fix/launch-copilot-model`,
    `fix/wave-serialization`).
- **The commit trailer.** End the commit body with a
  `Co-Authored-By: <model that wrote it> <noreply@anthropic.com>` trailer, plus a
  `Claude-Session: https://claude.ai/code/session_…` line when the harness
  provides one. (Ground truth is the git history, e.g.
  `git log -1 --format=%B 24922a7`.)
- **The scoped-suite rule, and that it OVERRIDES `CLAUDE.md:50`.** For a fix or a
  session, verify with the **fast scoped** `bash tests/<name>.test.sh` only.
  `CLAUDE.md` used to read "run `bash tests/run.sh` — all suites green" with no
  qualification; the full run is slow, billable and has hung whole sessions. **The
  full `tests/run.sh` is `ship-it`'s merge gate, not a session's inner loop.**

---

## Readout

After the DONE WHEN is met, read out: **what was built**, the **unit + tester
verdict**, **what was torn down**, and **what's next** (the next session's number
+ one-liner, or for a fix: "ship it with `ship-it` when you are ready") — plus
these four, which are **mandatory**:

- **Fix-loop rounds**, and **how many of the defects were in this work's own
  scope** vs **inherited** vs **made by the fix loop**. This ratio is the health
  signal; work with few rounds and mostly-inherited defects is not healthy just
  because the number was low.
- **BOTH costs: what it cost in orchestrator/sub-agent tokens, alongside the
  worker spend** (with the PATH shim's invocation count when zero spend was the
  plan). Reporting only "ZERO SPEND" on workers is what let a session burn 3.9M
  billed sub-agent tokens while everyone believed it was free. The number that
  gets measured is the number that gets optimised — so measure the real one.
- **What the proof was blind to** — the stated limits of what was actually
  driven, including any Claude drive the captain declined.
- **Ledgered items** — inherited defects filed rather than cured, and anything
  deliberately left.

### And when a model DROVE LCARS itself — the journey (captain ruling 2026-09-17)

**Whenever Copilot or Claude stood in for a human and drove LCARS — filing a
mission and living the pipeline as a person would — a JOURNEY is published
alongside the readout.** Numbered steps, a real screenshot each, written so
**a colleague who has never heard of LCARS can follow it**: what was asked for,
what the run found and built (quoting the real plan, tickets and tests, never
describing their shape), what kind of mission it was and what the other kinds
are, what is NEW, and what WORKED — including what a person did NOT have to do
because the system did it. Any patch the drive leaned on is said plainly and
early. Every picture is tappable to full size.

**The contract lives in ONE place — `run-session` STEP 5.5 § THE STAND-IN
DRIVE** — and `walkthrough.sh` beside it builds the page. Read it there.

**His reason:** *"being able to click through the journey and feel like I'm
going along with it helps cut down the evaluation time greatly"*, and he intends
to show these to other stakeholders. **It is IN ADDITION to the readout above,
never instead of it** — the readout carries defect health, both costs and the
blind spots; the journey carries the experience.

---

## Guardrails

- **Briefing-before-work is unconditional** — even for "run session NN" with an
  explicit number, even mid-round; and for a buddy fix, before the branch is cut.
- **Never fake the layer the work changes.** If pre-flight finds that, nothing
  starts until the harness is fixed or the scope changes.
- **Never spend Claude without asking, and never quietly skip a Claude drive the
  change needs.** Recommend it, name what a Copilot-only proof would miss, and
  let the captain decide. Copilot is free; Claude is billed, so live drives
  default to Copilot.
- **Never auto-chain.** One confirmation buys ONE session (or ONE fix). At the
  readout, offer the next; do not start it.
- **A pre-flight failure means stand down** (dirty tree, install out of sync,
  missing auth) — report it rather than working around it.
- **Never author under `~/.claude`.** lcars-dev is for planning docs and
  meta-skills only; anything that ships is authored in the LCARS repo.
