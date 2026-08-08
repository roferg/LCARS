# Real-Chrome board smoke — the rig that catches a blank viewscreen

> **Zero tokens, zero network, no install step.** Real Chrome, a real daemon, a
> fixture board on disk, and shims where the models would be. Run it as often as
> you like.

```bash
bash tests/drives/browser/smoke.sh
```

That is the whole thing. It prints a screenshot path. **Open it and look at it.**

---

## Why this exists

On 2026-08-02, S163's fix round 5 deleted `.then(render)` from `refresh()` in
`web/static/board.js` while inserting an explanatory comment in its place. The
viewscreen was a **permanently blank page** for three fix rounds while **1,162
unit tests and six tester rounds stayed green** — because every harness under
`web/tests/` calls `render()` itself, so not one of them ever asked the app to
paint. Real Chrome found it in about five minutes.

That Chrome rig was thrown away afterwards. S140's headed-Chrome rig before it
was thrown away too. So the equipment was rebuilt from scratch every round —
S163 rebuilt its fixture scaffold seven times. This is that rig, **committed**,
so no future tester has to invent it again. (`run-session` STEP 4a: on any
visual session the tester's *first* action is to open the real product in a real
browser and look at it. This is the one command that does that.)

## What it proves — and what it does not

**Proves:** booting the *shipping* front end against a *real* daemon in *real*
Chrome produces real, laid-out, visible `.card` nodes in the real DOM — with
real CSS, real layout, real paint. Every link is load-bearing:

```
Chrome loads /  →  board.js boots  →  refresh()  →  GET /api/board
    →  .json()  →  render(payload)  →  #board gains visible card nodes
```

Cut any one and the rig goes red. Unlike the node harness it *can* see CSS: a
card hidden by `display:none`, sized to zero, or faded to `opacity:0` does not
count here.

**Does not prove — say it plainly, because the last blind spot cost three hours
precisely because nobody wrote down what the harness could not see.** It proves
the board **paints**, not that it is **correct**. Wrong copy, a wrong pill, a
card in the wrong column, an unreadable colour, an ugly layout, a button that
does nothing — all of that passes here. It is one click deep: no interaction, no
overlay, no write path, one fixture board, one browser. **The tester still opens
the screenshot and looks.** This rig only removes the excuse for never having
looked at all.

It is also **not** a replacement for `web/tests/board_boot_harness.js` — that
node harness is cheap, runs in the default suite, and goes red on the same cut.
Keep both: the node one for every commit, this one for every visual session.

## The second rig: `basefresh-quiet.sh` (S164)

```bash
bash tests/drives/browser/basefresh-quiet.sh              # the product
bash tests/drives/browser/basefresh-quiet.sh --calibrate   # the RED CONTROLS
bash tests/drives/browser/basefresh-quiet.sh --all         # both
```

`smoke.sh` is one click deep: it proves the board paints and nothing more. This
one goes one click further, at *one* thing — the File console's base-freshness
pre-flight — and it is the template for any future "does this actually reach the
screen" question:

1. it plants a **base-freshness record** (`LCARS_BROWSER_BASEFRESH`) as a stub
   reporter, so a repo state — one commit behind, dirty, unreachable origin —
   can be put in front of real Chrome without constructing the git situation;
2. it clicks **File** and waits for the (asynchronous) pre-flight;
3. it **measures** the line: a real non-zero bounding box, the colour the
   cascade actually resolved, and that colour composited over whatever is really
   painted behind it, as a contrast ratio. Never "the CSS rule exists" — S162
   shipped an amber warning that rendered as muted metadata with exactly that
   assertion green beside it;
4. `--calibrate` patches a **copy** of `web/` four ways and requires the check to
   go red on each: the line **absent**, the line **dressed as the warning**, the
   line **with its quiet styling stripped** (amber panel, amber text) and the
   line **muted into unreadability**. The last two exist because the first two
   fail early, and an assertion no control ever exercises is an assertion nobody
   has shown can go red.

The screenshot is `file-console.png`; the numbers are `console-check.json`.
**Open the screenshot** — it still only proves what it measured.

Both seams are plain `smoke.sh` env vars, so any other console question can
reuse them: `LCARS_BROWSER_BASEFRESH` (a record to serve) and
`LCARS_BROWSER_CONSOLE_CHECK` (an expectation file). Neither is set by default,
and with both unset `smoke.sh` runs exactly the code it ran before S164.

## The holodeck rig: `holodeck.sh` (S125/S126)

```bash
bash tests/drives/browser/holodeck.sh              # the product
bash tests/drives/browser/holodeck.sh --calibrate  # the RED CONTROLS
bash tests/drives/browser/holodeck.sh --all        # both
```

**Zero tokens — but not "no worker".** This paragraph used to say the program is
opened in DESIGN mode and spawns no worker at all; that stopped being true the
moment the rig grew a journey, and a rig description that flatters the rig is
how a blind check survives. What actually happens: the rig opens the program in
**GROUNDING** mode and then drives **three design turns**, each a genuine
`POST /api/holodeck/<sid>/say` that spawns a worker process. That worker is a
**scripted Python stub** the rig writes — it branches on the *tool posture* it is
handed (a `--disallowedTools` naming `Write` means grounding), kills its first
design turn the way a real engine dies at startup, and writes `mockup.html` into
its cwd. **No engine is ever contacted and no token is ever spent**: the
`claude`/`copilot` on PATH are smoke.sh's logging shims and the run reports 0
invocations of them. The planted sidecar is a fixture: one room (`nav-rail`)
with a `mockup.html` **and a `transcript.md`** — the record that makes a
directory in the sidecar a *program* at all (fix round 2: the sidecar is the
captain's own archive, so a folder he drops in it is not a program and is never
listed, opened or `git rm`'d as one). It stands in for yesterday's work: the
archived card the morning-state and warm-restart checks below are about.

The holodeck **replaces the board inside the same LCARS frame** (D1), and it does
that with **one CSS class on `<body>`** — `body.on-deck` — chosen because
`render()` rebuilds the board area on every SSE tick and would wipe a JS `hidden`
flag. That is the whole reason a browser is required here: every node harness
under `web/tests/` can assert `body.classList.contains("on-deck")` and learn
*nothing whatsoever* about whether the board actually went away, and none of them
has any CSS at all.

So the driver clicks the real `⬡ HOLODECK` control, opens a program through the
real `＋ NEW PROGRAM` dialog (a genuine `POST /api/holodeck/start`), and then
measures **laid-out boxes**:

- the board's `.col`s, `.board-wrap` and `.legend` measured **gone** on the deck;
- three **content** panes — `programs · holo-chat · preview` — present,
  **visible**, in order, each with real width, at roughly the mock's 1.15 : 1
  chat:preview;
- the deck's **furniture**, judged separately and to its own shape (S128): the
  chat/preview drag handle (`.deck-split`) really laid out as a **3–24px**
  gutter that runs the height of the split, sits **between** the chat and the
  preview, and reads as draggable (`cursor: col-resize`); and the program
  drawer's click-away (`.holo-scrim`) measured **gone and click-through** while
  the drawer is shut — it is a full-bleed `z-index:5` overlay, so a merely
  transparent one would eat every click on the panes beneath it;
- **every child of the deck recognised.** The pane list is filtered, so an
  unrecognised node would otherwise drop out of it silently. This is a
  staleness alarm, not a defect claim: S127 added the handle and the scrim, the
  check called them panes, and the rig sat red on `pane deck-split is 7px wide`
  against a perfectly healthy deck for a whole session. When a new node
  appears, give it its own assertion — do **not** just add it to the known list;
- the preview `iframe`'s real box and its `src` on `/api/holodeck/<sid>/preview/…`;
- its `sandbox` token list: `allow-scripts` **present**, `allow-same-origin`
  **absent** — the one pairing that decides whether the sandbox is a mechanism or
  a decoration, since model-written HTML served same-origin could otherwise reach
  the board's DOM and the daemon's write API;
- `--holo-grid` resolving to a real colour (the S168 class applied to a surface
  that is drawn almost entirely in one accent);
- **that nothing the model wrote was deleted** — the scripted reply carries an
  ASCII diagram and a `●`-prefixed design note, and both must be on the screen.
  Fix round 2's cleaner ate exactly those (a captain's `┌────┐` came back as its
  top edge alone), so the `trace-eats-prose` control restores that filter and
  must go red;
- and the **board back** after the same control, now reading `▦ BOARD`.

It writes `holodeck.png` (open it) and `holodeck-back-on-board.png`.

**It earned its place on the first run.** The `⬡ PREVIEW / ▤ INTENT` toggle
rendered as two bare text runs jammed together — `⬡ Preview▤ Intent` — because
the `.pv-toggle` / `.pvt-b` rules had never been written. Every unit test was
green; the picture was not.

**The twenty-one red controls** (`--calibrate`) each patch a *copy* of `web/` and each
must make the run fail: `--holo-grid` deleted (the deck paints transparent while
every box stays perfect), the `body.on-deck` hiding rules neutered (the board
still laid out under the deck), the preview pane `display:none` (present in
markup, not on the screen), `allow-same-origin` added back beside
`allow-scripts`, the viewport pin removed (`deck-grows`), the grounding posture
never handing over (`grounding-sticks`), round 1's prose-eating cleaner restored
(`trace-eats-prose`), and — fix round 3 — `retry-is-a-dead-end`. Those eight went
red on 2026-08-05, though what "went red" meant at the time is the subject of
*A non-zero exit is not a control going red* below.

**S126 added the last three**, all of them failure-path claims that were
unit-test-only until now — and S125 proved *twice* that a unit test can be green
while the product is wrong:

- `n5-exit-code-in-banner` — round 1's banner restored, printing
  `(claude exited -9)`. A number that answers neither of the two questions a
  captain has (what it stopped, how to try again) and that he cannot act on.
- `retry-doubles-the-line` — the **daemon's** retry dedupe removed, so the
  captain reads himself saying the dead turn's line twice. Broken in the daemon
  rather than the deck on purpose: the daemon's turn list is what the deck
  re-reads after every settled turn, so a client-only break heals itself on the
  next refresh and the control would flicker green.
- `two-voices-in-the-banner` — round 1's client-authored banner copy restored.
  It repeats the daemon's own sentences *and* re-asserts the authorship claim
  ("nothing out there has been changed or removed by LCARS") that the daemon had
  just been cured of — a claim the audit cannot make, because it watches files,
  not who touched them.

All three read the banner raised by the **noisily** dying worker (stderr +
non-zero exit). A silently dying stub emits a shape the real world never
produces and hides the whole class.

**S126 fix round 2 added two more, and two new measurements to go with them.**
Both defects are *copy on a screen*, which is the one thing a node harness with
no CSS can be greenest about:

- `morning-points-nowhere` — the deck's opening pane as it was. The rig now
  measures that pane **before it opens anything**, which is the screen a captain
  gets every morning: yesterday's program sits in the list on the left, nothing
  is selected (correctly — the auto-select deliberately picks up only a *live*
  program, since an archived one would hand him a composer that 404s), and the
  main area read `PROGRAM STANDING BY / "Describe a screen…"` over one prominent
  `＋ NEW PROGRAM` — pointing at nothing, and at the one action that either lands
  in the room-reuse disclosure or splits his work in two. The check fails if the
  pane never mentions the list, or offers the button with no word of what it
  does to a program that already exists. **A run in which no program row was on
  the deck fails as "PROVED NOTHING" rather than passing.**
- `warm-pill-lies` — the chat header's engine pill asserting `WARM` again. At
  the end of the journey the rig clicks the **archived** room (a real
  `POST /api/holodeck/open`; no worker, no tokens) and reads the daemon's
  warm-restart banner and the pill **off the same painted screen**: the banner
  says the conversation that built the program is over and the worker answering
  the next turn is a fresh one, and the pill two inches below it said `WARM ·
  CLAUDE`. The defect exists only as a *contradiction*, so only a rig that reads
  both strings at once can see it. It writes `holodeck-warm-restart.png`.

### S169 added four more, and the first PIXEL measurement in this rig

Three defects the captain hit driving the real product on 2026-08-06 — two in
the chat composer, one in the INTENT panel — plus a control for the measurement
itself.

- **`draft-dies-on-repaint` (FL-013).** *"I was typing text, but hadn't sent it
  in the holodeck, I switched back to the board to deploy main, and when I came
  back my text was gone."* The composer is built as a fresh `<textarea>` on
  every render, so its value lived only in that node. The rig now types a
  paragraph and drives his exact journey — `⬡ HOLODECK` → `▦ BOARD` →
  `⬡ HOLODECK`, through the real band control — then reads the value back. **The
  node identity is asserted alongside it**: a draft that "survived" a round trip
  which never rebuilt the pane is the shape in which this check would pass on a
  product that had not been fixed at all.
- **`poll-rebuilds-the-deck`** is the control for the *other* half of that leg,
  and it exists because on a healthy product that half is **silent**. Before
  typing, the rig wraps `renderDeck` and `render` in counters, then sits still
  for 2.4 poll intervals and reports what actually ran. **Measured on the
  shipping product: 3 board re-renders, 0 deck re-renders, the same composer
  node** — so the 4s safety poll does *not* rebuild the chat pane, and an unsent
  turn dies on interactions rather than on a timer. That was an open question in
  the ledger, not an assumption, and it is now a number. This control makes the
  poll rebuild the deck, i.e. the world in which a draft dies four seconds after
  it is typed whatever else is done about it, and the check must say so.
- **`no-paste-on-the-composer` (FL-014).** *"I can't paste in images in my
  chat."* The rig dispatches a **real `ClipboardEvent` carrying a real `File`**
  at the composer and requires an `[Image #N]` chip with a painted box, plus the
  deck actually holding the image. Only a browser can say whether a genuine
  clipboard event is harvested by the handler attached to that textarea; the
  per-engine argv it then rides on (`--attachment` for copilot, a path in the
  prompt for claude) is the unit suite's job.
- **`intent-scrim-scrolls-away` (FL-016)** — *"the darker background to help
  read the text disappears as you scroll down"* — and this one needed **pixels**.
  `.pv-intent` was both the scroll container and the containing block of its
  readability scrim, so the `::before` was sized to the padding box and scrolled
  away with the content, leaving everything past the first screen bare on the
  deck's 22px grid. **Nothing already in this repo could see that**: the CSS
  rule resolves to a perfectly good colour either way — it is simply somewhere
  else — so even a computed-style read (the S168 legend swatches) says it is
  fine. `cdp.js` now carries a small PNG reader over node's own `zlib`, and the
  check photographs a clip of the screen behind a real line of text at the top
  of `concept.md` and again after really scrolling to the bottom, plus a third
  sample of the bare grid from the stage's padding band as calibration. Measured
  on 2026-08-06: **`rgb(3,6,8)` at both ends of a 3572px document in a 646px
  pane, against a bare grid of `rgb(4,16,15)`**; with the control applied, the
  bottom sample is `rgb(4,16,15)` — *identical* to the grid. The planted room's
  `concept.md` is a long fixture precisely so the document overflows the pane,
  and the check FAILS as "PROVED NOTHING" if it does not. It writes
  `holodeck-intent-scrolled.png`.

#### S169's second wave — you cannot ask the holodeck anything (FL-015)

*"I asked it what is it mean by the events tab and it's doing a long 'rendering
to holodeck' turn. This was a question about its design, not a request to update
the UI."* And, sharpening it: *"it answered my question, but also spent a lot of
time on the events tab."* **The mockup moved on a turn he had not directed.**

**What this rig can and cannot prove, stated before the controls.** Whether a
real model answers-then-stops is a *model* choice, and no rig on this path can
stand in for it — the live leg does that, and the endpoint suite records the full
`-p` prompt so the live leg can diff what a real worker was handed. What only a
browser can answer is everything else, and that is what these three own.

- **`no-ask-on-the-composer`** — the composer with no ask/build control at all,
  which is the state he was in: every turn was a build turn and there was no way
  to say otherwise. The rig requires **two laid-out, hit-testable halves**, the
  control **opening on BUILD** (it must be genuinely optional — a switch he has
  to remember to flip is one he will forget and blame), `aria-pressed` flipping
  on the click, and the **Send verb changing to `Ask ▸`**, because a declaration
  with no feedback is a switch he flips and then wonders about.
- **`ask-never-reaches-the-prompt`** — the declaration dropped on its way to the
  worker, broken in the **daemon**. This is the failure mode a control like his
  invites: the switch is on the screen, it lights up when he clicks it, the POST
  carries it… and the prompt says exactly what it said before. It can only be
  seen by driving the whole stack and looking at what the turn **did** — which is
  the half that would have caught the original defect. The rig declares ASK,
  sends a real question, and the scripted worker (which branches on the
  declaration it was handed) answers without writing; the deck must then show the
  daemon's *nothing was written* note, not its drift reading.
- **`banner-says-rendering`** — the working strip asserting a RENDER again. The
  strip is captured **in the same evaluate as the click** (`holoSay` sets
  `HOLO.busy` and re-renders synchronously), so there is no race and no polling.
  Until a turn has written something, "rendering" is a reason neither the daemon
  nor the deck has earned; "working" is honest for both kinds of turn.

`$LCARS_HOLODECK_VARIANTS` calibrates a **subset** (space-separated names), for
re-proving the controls a fix round just added without paying for twenty-one full
browser runs. The default is all of them, and a round is not calibrated until
the default has been run.

### A non-zero exit is not a control going red (fix round 1b)

`--calibrate` used to accept **any** failure from a variant as proof that the
control worked. It printed *"CALIBRATED — every control went red. The check can
see."* over runs in which **eleven of twelve** variants had failed on the
harness's own `THE N4 CHECK PROVED NOTHING` line and on nothing else — no `N5:`
failure and no N6 duplicate-line failure occurred anywhere in two full runs. The
three controls S126 added had gone red on plumbing, not on the defects they
inject, and three of the round's four deliverables were proven by nothing.

The mechanism was the rig's own memory. The scripted worker's only state is
`$out/holo-rig-state` — a `design-turns` counter that decides which design turn
dies — and nothing ever cleared it. `$out` is routinely **reused**
(`LCARS_BROWSER_HOLODECK_OUT` at a fixed dir is how you keep the artifacts), so
the second run into a dir began with the counter past zero, **the first design
turn no longer died**, no `HOLODECK OFFLINE` banner ever appeared, and the whole
N4/N5/N6/one-voice half of the check measured an empty room while still exiting
non-zero. `run_once` now wipes that state (and the worker log) before every
single run, so a re-run is a *run*, not a continuation.

And the summary can no longer lie about it. Every variant is judged off its own
`holodeck-check.json`, not off its exit code:

- its **precondition** must have fired — `n4.died`, i.e. the scripted worker's
  first design turn actually died and the banner actually appeared. Any
  `… CHECK PROVED NOTHING` failure is the harness saying it could not look, and
  is never counted as a control going red. `grounding-sticks` is the one
  exemption, by construction: it stops the posture handing over, so no design
  turn is ever spawned and there is no turn left to kill;
- and the run must have failed **on the sentence that names what that variant
  breaks** (`variant_signature`), so a control that goes red for someone else's
  reason is reported as proving nothing.

Anything short of both is loud, categorised (`N CONTROL(S) WENT RED WITHOUT
PROVING ANYTHING`) and non-zero.

**S169 — the one narrow escape hatch, `variant_blind_exemptions`.** A control
can blind another check *by construction*, and then the rule above reports it as
proving nothing even though it went red for its own reason.
`poll-rebuilds-the-deck` is the case: making every board poll rebuild the deck
is exactly the world in which the composer node cannot survive a round trip
either, so the draft leg's own blind line fires alongside the poll failure. The
table names the **specific line** a specific control may emit — never the
control's own signature, which is still required — so an exemption is a
one-line, reviewable claim rather than a category of failure being waved
through. S169 also merged the intent-scrim check's two failure sentences into
one for the same reason in reverse: the control landed *between* them (its
bottom sample is 12.2 from the top sample and 0.0 from the bare grid, so which
sentence fired was decided by a rounding), and two sentences for one defect is
how a signature table goes quietly wrong.

**Fix round 3 — no second exemption was added.** `--calibrate` could not run
green on a clean tree: `retry-is-a-dead-end` breaks the retry by construction,
so the design-turn loop ended with `flowErr` set, the warm-restart leg was
gated on `!flowErr` and never ran, and its `THE WARM-RESTART CHECK PROVED
NOTHING` line failed the precondition of a control that HAD gone red for its
own reason. The cure is in `cdp.js`, not in the judge: that leg's precondition
is now the **deck being painted**, which is what clicking an archived room
actually depends on — a dead design turn does not stop it. It also records the
banner text *before* the click and waits for a different one, so it can never
report the leftover `HOLODECK OFFLINE` banner as the restart's. When the leg
genuinely cannot look, `want.restart` is null and the blind line still fires.

`retry-is-a-dead-end` is the first control for a **failure path**. The rig's
scripted worker kills the first design turn the way a real engine dies at
startup — noisily (`Error: authentication failed`), before the CLI has opened
its session — and refuses to `--resume` a session it never opened, exactly as
both real CLIs do. The driver then presses the deck's own `RETRY TURN`, and the
conversation must come back, which is only possible if the daemon threw the
unproven session id away and opened a fresh one. The control restores the
`reply or` clause the daemon used to test "did a session get created" with: a
dying engine's message reaches the daemon as a perfectly non-empty reply
(`stderr` is merged into `stdout`), the ghost id is kept, and `RETRY TURN`
resumes it forever under a banner promising "the chat is still running". N4's
unit test used a *silent* death and was blind to all of it for a whole round.

---

## The third rig: `legend-swatches.sh` (S168)

```bash
bash tests/drives/browser/legend-swatches.sh              # the product
bash tests/drives/browser/legend-swatches.sh --calibrate   # the RED CONTROLS
bash tests/drives/browser/legend-swatches.sh --all         # both
```

The board's bottom legend teaches its colour language — a red chip for *Awaiting
you*, pink for *Child bug mission*, teal for *Ticket green*. Measured in Chrome
on 2026-08-02, **the pink chip was not there**: the label sat beside empty space.
`index.html` declared it `background:var(--lcars-pink)` with no fallback, and
nothing in this repo defines `--lcars-pink`, so the declaration was invalid at
computed-value time and the background fell back to `transparent`.

This is the *purest* case for the rig, and worth stating precisely, because the
broken chip had **everything a non-browser test can look at**:

| what a harness could check | broken chip |
|---|---|
| the element is in the DOM | ✓ |
| it has the right class and the right `style` attribute | ✓ |
| the CSS rule sizing it exists | ✓ |
| a real, laid-out, non-zero bounding box | ✓ — a perfect 12×12 |
| **it paints anything at all** | **✗** |

`.legend i` is sized by `board.css` and coloured inline, so an unresolved token
costs the chip its paint and nothing else. Even `smoke.sh`'s own visibility
predicate — box, `display`, `visibility`, `opacity` — passes it. Only the
**resolved background colour, with its alpha** can see this, which is what the
check reads off the live node, composited over the first genuinely opaque
surface behind it.

All **three** chips are measured, not just the broken one: the two healthy
neighbours are an in-run positive control, so "the pink one failed" cannot be
waved away as the rig misreading colours. The run also reports the tokens as
`:root` really resolved them — the product run measured
`{"--lcars-red":"#ff3344", "--lcars-pink":"", "--lcars-teal":"#00ccaa"}`, which
is the asymmetry itself, measured rather than argued.

`--calibrate` patches a **copy** of `web/` four ways and requires the check to go
red on each: the chip **removed**, its fallback **taken back off** (the S168 bug
verbatim), the chip **camouflaged** — opaque, and exactly the colour of the
surface behind it — and the chip painted in the **wrong hue**. The last two exist
because the first two fail early, and an assertion no control exercises is one
nobody has shown can fire. The camouflage control repaints the *legend's* own
surface rather than the chip, because the chip's colour is an inline style that
no selector can outrank; that makes it usefully targeted — the pink chip vanishes
while red and teal stay visible.

The deliverable is `legend.png`, a **3× close-up clip** of the legend strip. The
chips are 12px squares at the foot of a 4000px-wide `board.png`, where a reader
genuinely cannot tell a blank one from a dark one — and evidence nobody can read
is not evidence. The numbers are `legend-check.json`.

The seam is one more `smoke.sh` env var, `LCARS_BROWSER_LEGEND_CHECK` (an
expectation file naming the labels, their hues and a contrast floor). Unset by
default; with it unset `smoke.sh` runs exactly the code it ran before S168.

## The fourth rig: `ghe-links.sh` (S168)

```bash
bash tests/drives/browser/ghe-links.sh              # the product (4 scenarios)
bash tests/drives/browser/ghe-links.sh --calibrate   # the RED CONTROLS
bash tests/drives/browser/ghe-links.sh --all         # both
```

The captain's repos live on a GitHub **Enterprise** host. The board's two issue
links — the `↗ View on GitHub` button in a mission's detail overlay, and the
`⊗ BUG · child of #<n>` badge on a logged bug's card — both built their URL by
concatenating a literal `https://github.com/`, so every link opened a github.com
repository that does not exist and the host had to be hand-edited after every
click.

**Why this one needs a browser even though the front-end change is trivial.**
The fix is only real if the *daemon* delivers `meta.ghHost` to the live page, and
every harness under `web/tests/` calls the builders itself — so all of them stay
green against a daemon that sends nothing at all. The rig's second red control is
exactly that: front end perfect, daemon silenced. It goes red here and nowhere
else.

So the verdict is the **resolved `href` property** read off the live anchor —
the URL a click would actually open — against a real daemon reading a real git
remote. Four scenarios, each a real `git init` with a real origin:

| scenario | origin | links must resolve to |
|---|---|---|
| enterprise | `https://github.ghe.com/…` | `github.ghe.com` |
| github.com | `https://github.com/…` | `github.com` — **the one that must never break** |
| no-remote | *(a real repo, no origin)* | `github.com`, and no broken link |
| scp-style | `git@github.ghe.com:owner/repo` | `github.ghe.com` |

Entirely offline: which forge a repo lives on is a question about its origin
**URL**, and naming a remote never contacts it. No network, no GitHub account,
no spend.

`--calibrate` patches a copy of `web/` four ways and requires a red on each: the
front end **hardcoding github.com again** (the bug verbatim), the **daemon going
silent** while the front end stays perfect, the daemon sending the **wrong**
host, and **github.com broken for everyone else** (run against the github.com
scenario, so the regression guard is shown to have teeth rather than asserted to).

Three more `smoke.sh` seams, all unset by default: `LCARS_BROWSER_ORIGIN` (make
the fixture a real git repo with that origin, or `-` for one with none),
`LCARS_BROWSER_LOGBUG=1` (plant the logged-bug child card that carries the second
link) and `LCARS_BROWSER_GHLINK_CHECK` (the expectation file). The deliverable is
`gh-links.png`; the numbers are `ghlink-check.json`.

**What it caught beyond the reported bug**: measured 2026-08-03, the logged-bug
badge rendered as a dead `<span>` on a *first* paint — `renderMeta` ran at the
END of `render()`, after the cards were built, so `detailRepo` was still null
while `cardNode` was deciding whether the badge could be a link at all. Only a
later re-render made it one. A node harness could not see it either, until it was
changed to read the badge **render built** instead of calling `logBugBadge`
itself with the globals already populated.

## The fifth rig: `handoff.sh` (S169, extended S170)

```
bash tests/drives/browser/handoff.sh              # the product (THREE runs)
bash tests/drives/browser/handoff.sh --calibrate  # the RED CONTROLS (15)
bash tests/drives/browser/handoff.sh --all        # both
```

**The one screen a Mission is filed from**, measured at **1440x677** — the
window height that produced S128's D1.

**Why it exists at all, twice over.** S128 built a rig for this same dialog,
proved a real defect with it, and then tore it down; that is the third round
running (S140's headed rig, S163's) where the equipment had to be rebuilt from
scratch. And the defect it found is the defect S169 walks straight back into:
the promote dialog's body is 1812px against a ~677px window, and its open
questions sat 546–780px **below the fold** while ▦ File Mission did not — the
session's own stated goal, shipped and invisible to all 1,100+ harnesses under
`web/tests/`, because every one of them is a node DOM with no CSS and no layout.

S169 pours two more sections into that same box (what the mockup CHANGES about
the app you have today, and what it IMPLIES that nobody settled). So this rig
does not check that the text exists — 30 unit tests own that, and every one of
them stays green on a box the captain cannot read. It measures:

- the draft the **daemon actually delivered** to the live textarea, by its three
  section headings (a node harness calls the builders itself and stays green
  against a daemon that sends nothing — the `ghe-links.sh` lesson);
- the box **fully on screen at rest**, and hit-testable;
- **how many of its lines are visible at once** — an eight-row slot holding a
  31-line draft shows him his own words and hides the two new sections under
  them, which is D1 one level down;
- that the rest is **reachable**, proven by scrolling the textarea to its own
  bottom and reading back where it went;
- that the line under the box **names what the draft is made of** and is wholly
  inside `.modal-body`'s **clipping band** — not merely inside the window, which
  is a different and weaker claim;
- that **▦ File Mission** is still hit-testable (`elementFromPoint`, never "it
  is in the DOM"), and that S128's open-questions cue still is too.

**S170 added the WAIT, and it is the half no harness can fake.** Send to Align
is a stage now: one bounded read-only pass stands in the captain's project and
works out what the mockup changes about it, 154–220s measured. The rig drives a
scripted worker with a real `sleep` in it and measures, in three product runs:

- the **RUNNING band** wholly on the first screen, hit-testable, above the brief
  box, carrying the sentence that says he may **close this and walk away**.
  Its first version was ~170px and left EIGHT visible lines of brief at
  1440x677 against a bar of nine — found here, on the first run, and cured by
  cutting the copy to three lines;
- **`reloadProof`** — the page is RELOADED mid-wait, which throws away every
  byte of client state (dialog, draft, poll, timer), and the same controls are
  walked again. The brief he comes back to must be COMPLETE, with the derived
  change **in the textarea**. If that survives, it survives because the DAEMON
  owns the wait;
- **`typeWhileWaiting`** — he types into the brief while the pass runs. When it
  lands, HIS WORDS must still be there AND the change list must have been
  appended (FL-013, one dialog over). A reload would wipe the typing, so this
  is its own run.

**What it does NOT prove: the daemon dying.** A reload restarts the page, not
the process, so the in-memory cache still answers and a broken persisted record
comes back GREEN here. `tests/drives/handoff-durability.sh` is where that is
measured — it `kill -9`s the daemon mid-pass and again after, and starts a
fresh one over the same room.

**The fixture is the real room.** `web/tests/fixtures/s128-drive/concept.md` is
a byte copy of the concept doc the holodeck wrote for the program whose mission
then lost the look — the same file the unit suite uses. It is copied into a
planted sidecar as an **archived** program, so the whole path (enter the deck →
pick it back up → ▶ Send to Align) spawns **no worker at all**: `holodeck_open`
is a warm restart off disk and `holodeck_promote` is a read. Zero tokens, and
the run reports 0 shim invocations.

**What it caught on its very first run**, before a single control was written:
`brief.focus()` scrolled `.modal-body` down by **234px**, so the dialog opened
with the top of the captain's own words **55px above the window** — the draft
had grown and the first thing on screen was the middle of it. Cured in
`openHandoff` (caret to character 0, body pinned to the top). Nothing under
`web/tests/` can see that.

**Exit 5** is this rig's, for the same reason `4` is the holodeck's: it fails on
a board that painted and a deck that opened, and borrowing either of their codes
would make smoke.sh print the wrong accusation.

## The sixth rig: `duplicate.sh` (S172 fix round 1)

```
bash tests/drives/browser/duplicate.sh              # the product
bash tests/drives/browser/duplicate.sh --calibrate  # the RED CONTROLS (9)
bash tests/drives/browser/duplicate.sh --all        # both
```

**⧉ Duplicate a program**, driven end to end: the band control → a locked
program's card → the confirmation dialog → the new room, twice. Self-contained
(it owns its own daemon, its own headed Chrome and its own planted sidecar
rather than riding `smoke.sh`), so it adds no seam to the shared rig.

**Why it exists.** S172 shipped ⧉ Duplicate with 33 new headless tests, 852
existing ones green, and a feature that could not duplicate **either of the
captain's two real programs**. Two of the seven defects a tester found in real
Chrome were structurally invisible to every one of those tests:

- **D1 (blocker)** — a room name is `_slug`'d and capped at 48 characters, and
  every program the captain actually has is named with his whole idea sentence.
  The `(copy N)` differentiator lived only in the **display** name, so it fell
  off the far side of the cut and all 500 candidate rooms came back as the
  **source's own**. The headless suite named every program "Command palette" —
  15 characters — so it never once reached the cap. **The fixture here is the
  captain's actual program name — 114 characters, verbatim out of his archive —
  and it must not be shortened**: that is the only reason this rig can see the
  defect at all. (Fix round 1 wrote that sentence over a 51-character stand-in.
  It cleared the 48-character cap, so D1 was genuinely exercised, but it
  under-measured D3 by half — a 43px lineage chip where his real name paints
  72px — and it was too short to reach N1 at all.)
- **D3** — the lineage chip was `max-width:14ch`, so `⧉ from Tile editor` and
  `⧉ from Tile editor (copy)` both painted as `⧉ from Tile…`: the same six
  characters for every possible parent, on a chip whose whole job is to answer
  "which one was that". The rule resolves perfectly; it simply does not fit —
  the `css-rule-tests-green-never-reaches-screen` class, which no node DOM
  harness under `web/tests/` can see, because none of them has CSS or layout.

Nine checks, each named in `duplicate-check.json` and each owned by exactly one
red control (a variant that fails on somebody *else's* check is reported
inconclusive, never green):

| check | red control |
|---|---|
| `DUP-CONTROL-ON-LOCKED-CARD` | `no-duplicate-control` |
| `DUP-BLANK-NAME-WORKS` | `room-not-differentiated` — **D1 verbatim** |
| `DUP-TWO-DISTINCT-ROOMS` | `second-copy-overwrites` |
| `COPY-CARRIES-THE-SOURCES-FILES` | `copy-drops-the-design` — **round-2 probe A** |
| `NO-TWO-CARDS-ONE-NAME` | `copy-keeps-the-parents-name` — **round-2 probe B** |
| `SOURCE-STAYS-SENT` | `source-loses-its-lock` |
| `LINEAGE-CHIP-READABLE` | `chip-clipped` — **D3 verbatim** |
| `INHERITED-GROUNDING-SAID-ON-SCREEN` | `chip-says-grounded` |
| `CONTINUING-CHIP-ON-SCREEN` | `no-continuing-chip` |

**The last two checks are fix round 2's**, and they are here because the
round-2 tester broke the product twice in ways nothing looked at and this rig
answered `PROVEN`, 7/7 green, exit 0 both times: a copy that arrived carrying
`basis.md` and `transcript.md` and *nothing else* (the dialog promises it
"carries the mockup, the concept doc, anything you pasted in"), and three cards
on one deck all reading the same name (the exact pair the daemon's 409 exists to
prevent). `DUP-BLANK-NAME-WORKS` asserted only that the dialog closed without an
error — it never asked whether a room appeared or whether anything was in it —
and `SOURCE-STAYS-SENT` name-checks the *source* row, so no check had ever
looked at a copy's name.

Calibrated 2026-08-08 (fix round 2, on his real 114-character name): all nine
went red on their own check. `chip-clipped` measured 76×14px shown against
164×72px needed — the tester's own reading, reproduced by the committed rig.

`second-copy-overwrites` was **re-anchored** in fix round 2, and the move is
itself a finding. It used to break `_claim_room` alone ("the room is taken and
it says yes"); once the N1 cure put a name walk in front of that claim, the
broken claim was never reached on the blank road and the variant came back 9/9
**green on a product whose room claim was a lie**. It now breaks the road
itself — the blank road hands back the first copy's room every time — so the
check is proven against its own claim (two duplicates, two rooms) rather than
against one implementation detail of it. The claim-by-creation race stays
covered deterministically by `DuplicateRoomIsCLAIMEDNotJustCheckedTest`; a
browser is not where a race is proven.

A **stylesheet precondition** runs before any of it: if `--lcars-amber` and
`--holo-grid` do not both resolve on the live page, the run exits 77 and proves
nothing rather than measuring boxes off an unstyled phantom. It earned its keep
immediately — the first calibration served every variant without `docs/lcars.css`
and all six controls would otherwise have "gone red" on a page with no CSS at
all.

Zero tokens: the only `claude`/`copilot` on `PATH` are logging shims that exit
1, the journey never takes a turn, and a non-empty shim log fails the run.

## Exit codes

| code | meaning |
|---|---|
| `0` | the board painted, with its full stylesheet. **Now look at the screenshot.** |
| `1` | it did not paint — a real failure. The screenshot is a picture of exactly what the browser saw. |
| `3` | it painted, but was **served incomplete** — a same-origin stylesheet did not load, so the screenshot is a picture of a *phantom*, not of the product. |
| `4` | the board painted; the **holodeck check** failed. Only possible under `LCARS_BROWSER_HOLODECK_CHECK`, and `cdp.js` prints each `✗ <reason>` plus the precondition. |
| `5` | the board painted and the deck opened; the **hand-off check** failed. Only possible under `LCARS_BROWSER_HANDOFF_CHECK`, and `cdp.js` prints each `✗ <reason>`. |
| `77` | **SKIPPED / INFRASTRUCTURE**, loudly, with the reason named. Never a pass. |

A rig that quietly succeeds when it did nothing is the same disease as the blank
board, so a skip is never `0`.

`4` exists because `1` used to carry the holodeck's failures too, and smoke.sh
then fell through to its default and printed **"BLANK / WRONG — the board did not
paint"** two lines under this rig's own *"real Chrome painted 2 card node(s), 9
column(s)"*. The reason was sitting in `holodeck-check.json` and never reached
the operator. This repo burned three hours once on a board that "looked blank";
a rig set up to tell that exact lie on purpose is worse than no rig.

**And `1` is an accusation against the product, so nothing that is the rig's own
problem may leave through it.** No Chrome, no node, no python3, Chrome never
becoming drivable, a timeout too small to reach a first DOM probe, a driver
crash — all `77`. This rig exists to stop harness trouble being reported as a
product defect; it does not get to do that itself. `1` means the board was
asked, in a real browser, and did not paint.

## Artifacts

Each run gets its own directory (`mktemp -d`, or `LCARS_BROWSER_OUT`):

| file | what it is |
|---|---|
| `board.png` | **the screenshot** — the whole board, all Stage columns |
| `legend.png` | (with `LCARS_BROWSER_LEGEND_CHECK`) a 3× close-up of the legend strip |
| `legend-check.json` | (ditto) every swatch's resolved colour, box, backdrop and contrast |
| `handoff.png` | (with `LCARS_BROWSER_HANDOFF_CHECK`) the ▶ SEND TO ALIGN dialog, **viewport-sized** — a picture of what the captain actually sees at 677px |
| `handoff-check.json` | (ditto) the brief box's geometry and content, the modal body's clipping band, and the hit-test of every control |
| `result.json` | card count, column count, status line, card text, page errors, Chrome version |
| `daemon.log` | the daemon's stderr, including the URL it bound |
| `chrome.log` | Chrome's stderr |
| `pids.json` | daemon pid, Chrome pid, daemon port (teardown evidence) |
| `worker-shim.log` | every `claude`/`copilot` invocation. **Should be empty.** |
| `fixture/` | the throwaway `.git/lcars` board the daemon read |

`result.json` reports every browser console error it saw, **with the URL**. Two
are expected on a healthy run and are not defects:

- `POST /api/mission` → **400** — deliberate. `probeWrites()` POSTs an empty body
  precisely to read 400 (write layer active) vs 403 (view-only). See the comment
  above `probeWrites()` in `board.js`.
- `GET /favicon.ico` → **404** — the daemon serves no favicon.

Two more are expected **only in the holodeck journey, and only because the rig
provokes them**: the duplicate-name step's `POST /api/holodeck/start` → **409**
and N4's dead first turn's `POST …/say` → **502**. These are a *budget*, not a
pattern exemption — each is forgiven once per time the rig actually took that
step, so a 409 on a run that never drove the collision, or a second 502 (which
is what a ghost-resuming retry produces), is still unexpected. Before fix round
3 the 409 was not on the list at all, so every green run — the product and all
seven controls — ended with `⚠ 1 UNEXPECTED PAGE ERROR(S) ON A GREEN RUN`, which
is how a warning gets trained out of people.

**Anything outside that pair is printed on stdout — on a green run too**, under
`⚠ UNEXPECTED PAGE ERROR(S) ON A GREEN RUN`, without turning the run red. It is
also split out as `pageErrorsUnexpected` in `result.json`. Errors were once
shown only on failure, which meant an uncaught exception on a *passing* board
went unmentioned — the exact false comfort this rig is built against. Telling
the reader "the list is worth a look" is not the same as telling them to look.

`result.json` also carries `servedComplete`, `stylesheets` (each same-origin
`<link>` and whether the browser really built a sheet from it) and `tokenProbe`
(the resolved `--lcars-amber`), which are what exit `3` is decided from.

**Artifacts are kept on purpose** — the screenshot is the deliverable, and a run
you cannot look at afterwards is not evidence. Kept, but **bounded**: each run
prunes older sibling dirs from its own `mktemp` namespace, keeping the newest 5
(`calibrate.sh` keeps 3). Pruning is skipped entirely when you pass
`LCARS_BROWSER_OUT` — then the artifacts are yours to manage.

## Environment

| var | default | why |
|---|---|---|
| `LCARS_BROWSER_CHROME` | the installed `/Applications/Google Chrome.app` binary | never a downloaded Chromium |
| `LCARS_BROWSER_OUT` | fresh `mktemp -d` | where the artifacts land |
| `LCARS_BROWSER_WEB_DIR` | this repo's `web/` | **the calibration seam** — point it at a patched copy |
| `LCARS_BROWSER_EXPECT` | `2` (the fixture's mission count) | visible cards required |
| `LCARS_BROWSER_HEADED=1` | *(headless)* | watch it happen in a real window |
| `LCARS_BROWSER_TIMEOUT` | `30000` | ms to wait for the paint. **Minimum 2000** — below that nothing could be proven, so it is a loud skip, never a verdict |
| `LCARS_BROWSER_BASEFRESH` | *(unset)* | path to a base-freshness record JSON, planted as the stub reporter behind `GET /api/base-freshness` |
| `LCARS_BROWSER_CONSOLE_CHECK` | *(unset)* | path to an expectation JSON — makes the driver open the File console and **measure** its pre-flight line |
| `LCARS_BROWSER_HANDOFF_CHECK` | *(unset)* | path to an expectation JSON — makes the driver enter the deck, pick the planted program back up and open **▶ SEND TO ALIGN**, then measure the pre-drafted brief where it is read. See `handoff.sh` |
| `LCARS_HANDOFF_VARIANTS` | all fifteen | run a SUBSET of `handoff.sh --calibrate`'s red controls |
| `LCARS_RIG_DERIVE_SLEEP` | `6` | seconds the scripted derivation worker waits before answering — the rig's stand-in for the live pass's 154–220s |

### The seam serves the *whole* app

The daemon resolves the shared ADR-007 token stylesheet as
`<web-dir>/../docs/lcars.css` (`server.py`'s `_SHARED_CSS`), so a plain
`cp -R web/` copy has no sibling `docs/`, `/lcars.css` 404s, and **every
`--lcars-*` token disappears** — the title goes yellow-on-yellow, the header
buttons lose their teal pills, the legend swatches vanish. The board still
paints (`board.css` uses `var(--lcars-x, fallback)` throughout), so it still
*passed*, silently. Measured 2026-08-02: every seam run carried a `/lcars.css`
404 nobody was told about.

`smoke.sh` now makes the copy **faithful** — when `LCARS_BROWSER_WEB_DIR` is not
this repo's own `web/`, it places the shared stylesheet at
`<web-dir>/../docs/lcars.css` before serving. This is fixed in the **rig**, not
in `server.py`, deliberately: the daemon is shipped production code and changing
how it resolves the shared sheet has a blast radius well past this rig. And if
the sheet ever fails to load anyway, the run **exits 3 and says so** rather than
leaving a future tester to notice yellow-on-yellow by eye.

## Calibration — prove the rig can still go RED

```bash
bash tests/drives/browser/calibrate.sh     # exits 0 when the rig correctly FAILS
```

A green check that cannot go red is decoration (S162 shipped a warning styled
invisible while a test asserting the CSS rule *existed* stayed green). So this
rig does not get to *claim* it would catch a blank board — it demonstrates it on
demand: `calibrate.sh` copies `web/` to scratch, deletes the `.then(render)`
line from the **copy's** `board.js` — S163 fix round 5's mistake verbatim — and
requires the rig to fail. This repo's own `web/` is never touched.

Measured 2026-08-02: `0 visible of 0 cards in the DOM`, status line stuck on
`loading…`, and a screenshot of an empty black board. Exactly the incident.

Run this whenever you change the rig, and whenever a run's green feels too easy.

## Self-test — the rig's own properties

```bash
bash tests/drives/browser/selftest.sh      # ~2 min, launches Chrome several times
```

Proves: (1) it passes on a healthy board with the real card count, (2) it fails
under calibration, (3) a missing Chrome is a **loud skip**, not a pass, (4) a
screenshot exists at the announced path, (5) no orphan daemon, Chrome or held
port — **on success and on failure**, (6) two back-to-back runs take different
ports, (7) a copy served through the calibration seam is **fully styled**, and
(7b) one that *isn't* exits `3` loudly rather than passing, (8) a harness
failure exits **77 and never accuses the board** — including that a stale
`DevToolsActivePort` is not believed (8b), (9) an unexpected page error is
**surfaced on a green run**, without turning it red.

## Design notes for whoever changes this next

- **Raw CDP, no dependencies.** The driver (`cdp.js`) talks the Chrome DevTools
  Protocol over node's global `WebSocket` (node ≥ 22). That is what makes "one
  command" literally true — no `package.json`, no `node_modules`, no
  "skipped: module not found" mode, which is the mode most likely to turn this
  back into the rig nobody runs. `puppeteer-core` would also have worked; plain
  `puppeteer` is **forbidden** — it downloads its own Chromium, and the entire
  point is to drive the Chrome the captain actually has.
- **No sleep-and-hope.** Every wait is on an observed signal with a deadline:
  the daemon's own "serving at &lt;url&gt;" line, Chrome's `DevToolsActivePort`
  file, `/json/version` answering, then the DOM polled until cards are laid out.
- **`DevToolsActivePort` is read defensively.** Chrome writes it for itself, not
  for us, and reading it naively is a race — measured on a cold headed launch
  (with GoogleUpdater starting), the rig read one port while `chrome.log` showed
  Chrome listening on another. So the file is only believed once its **second
  line** (the `/devtools/...` browser path) has arrived, and only once that port
  actually answers `/json/version`; anything else sends it back to re-read,
  because Chrome may rewrite the file. Note the file has **no trailing
  newline**, so counting lines lies — a finished file reports one.
- **The app is checked for being served WHOLE, by measurement.** Every
  same-origin `<link rel=stylesheet>` must have produced a real `CSSStyleSheet`
  and `--lcars-amber` must resolve on `:root`. Both are read out of the live
  page, never inferred from a log line — the standing lesson here is that a CSS
  rule can test green and never reach the screen.
- **Free ports by construction.** The daemon takes `--port 0` and reports what
  the kernel gave it; Chrome takes `--remote-debugging-port=0` and writes its
  real port into `DevToolsActivePort` inside a throwaway profile. Nothing is
  hardcoded, so runs cannot collide.
- **A throwaway Chrome profile** also means the rig launches its **own** Chrome
  rather than attaching to the captain's — it can never touch their tabs.
- **Teardown from the shell layer.** `smoke.sh` owns both pids and kills them in
  an `EXIT INT TERM` trap, so a crash, a `^C` and a failing assertion all clean
  up identically. A polite `kill` is enough since 78450eb; if you ever see the
  `ignored SIGTERM` warning for the daemon, that is a **regression of that fix**
  — report it, don't work around it.
- **Zero spend is pinned with a PATH shim**, both `claude` and `copilot`, never
  an env var: the daemon's align path can override `LCARS_WORKER_BIN` from a
  *request body*, so the environment is not a safe pin.
- **Not in any automatic suite.** It is a drive rig, invoked deliberately, and it
  lives under `tests/drives/` where `tests/run.sh` (which globs `tests/*.test.sh`)
  cannot pick it up. It is not part of `python3 -m unittest discover -s tests`.
- **The screenshot must show everything.** The Stage columns scroll horizontally
  inside `#board`, so a 1440px shot of a *healthy* board cuts Implement/Verify
  off the right edge — and a tester opening that picture would read "blank". The
  driver measures the board's scroll extent and widens the viewport to it before
  capturing. Evidence that misleads is worse than no evidence.
