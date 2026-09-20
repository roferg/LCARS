# S220 · after parts E/F/G — what Number One's LOOK finds now

Recorded 2026-09-19 evening on `feat/number-one`, with parts A–G present as
**uncommitted working-tree changes**. Read `BASELINE.md` first: these numbers
only mean something beside the ones it holds, and it is the file that states
the trap — *a zero from a build that never came up is not a zero from a look
that could not see.* Every arm below was checked for `"the build is up"` in its
own `*.look.log` before its number was believed. **There were no harness deaths
in this session:** all five looks launched, all five produced a verdict, none
hit its cage.

Every arm ran LIVE on Copilot (`/opt/homebrew/bin/copilot`, absolute path only,
`claude-opus-4.8`), against the same two fixtures the baseline used:
DX-Scorecard PR #206 at `672825b` for the real arm, and the Tide Board fixture
for the planted one. **No Claude look was run.**

---

## The numbers

The real arm was run **twice** after the entry fix, sequentially, one live look
at a time. Both are below; neither is an average and neither is "the better
one".

**Re-stated 2026-09-20 in the provenance shape (fix round 1, D1).** Recall is
three numbers now: the MODEL'S OWN EYE, the DETERMINISTIC DETECTORS, and the
union. The single number below used to be the union alone, printed as though
one eye had earned it — and a tester who muted every model criterion to "met",
so the model said *nothing at all*, still got 5/5, 0 false alarms, "medium,
earned" out of this drill. **Nothing was re-looked to produce this table**; the
same recorded verdicts under `after-efg-scored/` were re-scored.

| arm / look | model's eye | detectors | union | false alarms | grade | the look said | the worker moved | the declared journey (part F) |
|---|---|---|---|---|---|---|---|---|
| **real · look C** | **3 / 5** | **5 / 5** | **5 / 5** | **0 / 1** ‡ | medium, **earned** | 11 didn't-work (4 its own, 7 a detector's), 13 couldn't-check | 2 clicks, 1 typing, 1 keypress, 0 jumps | **9 of 9 steps — 7 clicks, 2 typings, 0 jumps** |
| **real · look D** | **3 / 5** | **5 / 5** | **5 / 5** | **0 / 1** ‡ | medium, **earned** | 10 didn't-work (3 its own, 7 a detector's), 19 couldn't-check | 0 clicks, 0 typings, 0 keypresses, 0 jumps | **9 of 9 steps — 7 clicks, 2 typings, 0 jumps** |
| **planted** (regression) | **4 / 5** | 0 / 5 | **4 / 5** | **0 / 2** | low, **earned** | 7 didn't-work (6 its own, 1 a detector's), 7 couldn't-check | 0 | 4 of 4 steps — 3 clicks, 1 typing, 0 jumps |
| real · look A † | 3 / 5 | 4 / 5 | 4 / 5 | 0 / 1 ‡ | low, earned | 9 didn't-work (4 its own, 5 a detector's), 12 couldn't-check | 6 clicks, 0 typings, 1 keypress, **1 jump** | **0 of 8 steps taken** |
| real · look B † | 3 / 5 | 3 / 5 | 3 / 5 | 0 / 1 ‡ | medium, earned | 7 didn't-work (3 its own, 4 a detector's), 17 couldn't-check | 2 clicks, 0 typings, 0 jumps | **0 of 8 steps taken** |
| **the model MUTED** (tester's probe) | **0 / 5** | **5 / 5** | 5 / 5 | 0 / 1 ‡ | medium, earned | 7 didn't-work, **0 of them the model's** | 2 clicks, 1 typing | 9 of 9 steps |
| **real · look E** (fix round 1, live) | **2 / 5** | **5 / 5** | **5 / 5** | **0 / 1** ‡ | low, **earned** | 10 didn't-work (3 its own, 7 a detector's), 52 couldn't-check | 0 | **9 of 10 steps — 1 changed nothing** |

‡ **The one declared-correct control on the real arm is NOT COMPARABLE**, and
the drill now says so out loud instead of counting it as a clean pass. The
Preview button's DRAWN box is 0×0 — the drawing has no such part — so nothing
was ever held against anything and "zero false alarms" over it was a number
about nothing. The planted arm's two correct controls ARE drawn, and its zero is
real.

**And there is only ONE declared-correct control on the real arm, so its
false-alarm number has no margin at all.** A single miss takes it from 0/1 to
1/1; there is no way for that column to be a little wrong. It is reported as it
stands rather than propped up — inventing extra "correct" controls to widen it
would be declaring known answers out of the harness's own convenience, which is
the one thing the known-answer files may never do.

The last row is the tester's own probe, kept here because it is the sharpest
statement of what the columns are for: a look whose model is silent scores **0
by its own eye** and the detectors' 5 is printed as theirs.

Beside the recorded history:

| | real, model's eye | real, detectors | real union | real grade | planted union | walking |
|---|---|---|---|---|---|---|
| baseline (before S220) | 0 / 5 | 0 / 5 | **0 / 5** | medium, **not** earned | 5 / 5 | 2 clicks, 0 typings |
| **after parts E/F/G** | **3 / 5** | **5 / 5** | **5 / 5, twice** | medium, earned | 4 / 5 | **7 clicks, 2 typings, 0 jumps** |

**The honest headline is not 5/5.** The model's own eye went from 0/5 to 3/5
on the real case — real movement, and the first time it has found any of those
buttons at all. The detectors went from nothing to 5/5. The 5/5 is the two
together, and it must never again be read as one.

### Which faults, by name

Both eyes are shown, because either one alone is a half-truth. "found by" used
to be whichever list `judge()` happened to walk first, which is iteration order
and not provenance at all; each eye is now judged on its own pass.

| | part | look C — model | look C — detector | look D — model | look D — detector |
|---|---|---|---|---|---|
| r1 | Pull data & start | ✓ `prd-21` | ✓ `oversized-icon` | ✓ `prd-21` | ✓ `oversized-icon` |
| r2 | Continue to builder | ✓ `prd-21` | ✓ `oversized-icon` | ✓ `prd-21` | ✓ `oversized-icon` |
| r3 | Lock month | ✓ `prd-21` | ✓ `oversized-icon` | ✓ `prd-21` | ✓ `oversized-icon` |
| r4 | Back to builder | — | ✓ `oversized-icon` | — | ✓ `oversized-icon` |
| r5 | the August→September mismatch | — | ✓ `carried-value` | — | ✓ `carried-value` |
| | **total** | **3 / 5** | **5 / 5** | **3 / 5** | **5 / 5** |

**`r3`, and what actually decides it — corrected in fix round 2.** Round 1
removed a bare 40px floor from the `oversized-icon` vocabulary (a MEASURED 34px
icon in a 32px control — the real Lock month button — was not "oversized" under
it unless somebody wrote prose about it) and this section then claimed the kind
was "now decided by comparing the two measurements". **On look D it is not.**
Look D's r3 credit comes from the PHRASE LIST — "icons that spill past the
button and labels that wrap to 2–3 lines" — and with `spill`/`wrap` taken out
and only its ratio ("1.06–1.91× their control height") left, it scores 0. The
sentence described an intention, not the tool.

The comparator now does compare, and it is measurable on look C. Look C writes
"its lock icon runs 34px in a 32px control": the phrase list alone does NOT
credit that, and the comparator does — which is why look C's model eye reads
**3 / 5** here where the fix-round-1 table published 2 / 5. That single cell is
the only number in this document that moved, and this is why. Round 1's
comparator could not read it either: it found its two numbers with overlapping
regexes on a non-overlapping scan, so in the word order a person actually uses
("holds a 34px icon inside a 32px control") the icon's own 34 was taken as the
control's measurement and 34 > 34 was false. Measured over 18 phrasings, six
missed — including "Back to builder has an icon taller than the button it sits
in". Each measurement is now attached to the nearest part word, and a
comparison stated in words counts as the comparison it is. See
`selftest.sh` case 13.

The declared-correct control — the builder's Preview button — was **not**
flagged in either run. Nothing was invented.

† **Looks A and B are not measurements of E/F/G and must not be read as one.**
Both were started before the walk could find its way into the flow (the app's
front door is a scorecard; the drawn journey lives behind an "MBR builder"
button), so their declared journeys came back **all-unreachable — 0 of 8 steps
taken** — and the carry check never ran, which is exactly why `r5` is missed in
both. They are kept because they are real live looks at almost the same code and
they show the spread. **The after-number is C and D.**

---

## Fix round 1 — the live look that proved D5 and D6 (2026-09-20)

One live real-arm look on `/opt/homebrew/bin/copilot`, from a clone at
`672825b`, with the fix-round changes in the working tree. It is here for the
two things only a real walk can show.

**D6 — the walk fills the form, and a step that changed nothing is not "taken".**
Its `walk.json`, step by step:

| step | before | after |
|---|---|---|
| j8 `fill every field this screen still wants` | did not exist; the walk typed into **2** named fields and stopped | **33 fields on the screen; 1 still empty and filled; 2 it could not fill, both NAMED** — *"[wip] baseline skills and shift left metrics value"*, *"copilot sre impact score value"* |
| j9 `click "Lock month" now everything is filled` | `status: done`, `changed: false` — counted among **"9 of 9 steps taken"** | **`status: no-change`** — *"I did it and the screen was the same before and after — same address, same words — so I cannot say whether it worked"* |

The blank-phase gate (j3) is deliberately exempt: it is ASKING the gate to
refuse, so nothing changing is the answer it wanted. Every genuine step of the
walk (j1, j2, j4–j8) changed state and is still counted as taken.

Read the "1 of 33" honestly: this look ran on a clone that already carried a
snapshot the PREVIOUS walk had written (ledgered as D7 — the walk mutates the
launch worktree's `data/`), so 30 of the 33 boxes arrived with text already in
them. The number that matters is that the step now ASKS all 33, fills the ones
it can, and names the ones it cannot — where before it typed into exactly two
and the gate's "filled" phase was tried over a form nobody had filled.

Its scored numbers are the **look E** row above: model 2/5, detectors 5/5,
union 5/5, no false alarms, the one correct control reported NOT COMPARABLE,
grade LOW and earned. Its `xo/` is under `fix1-scored/real-lookE/` (no PNGs).
The journey reads **9 of 10 steps taken, 1 changed nothing** — a sentence the
old record could not produce.

**D5 — every finding the drill counts for recall now reaches the captain.** The
loader took `message` and nothing else; the part-by-part measurements and the
journey's carry check write `says`. Four oversized-icon findings and the
August→September carry were being scored as FOUND and printed **nowhere** in
`report.md`. They now have their own section, *What I measured on your drawing,
and what I saw walking it*, with a one-line signpost to it from the top of the
report, and the loose layout findings stay where they were. In look E's own `report.md`,
line 15 reads *"I also measured 5 things against your drawing and while walking
the flow myself … they are faults and they are listed below"*, and lines
296–300 are those five, one bullet each — including **"Back to builder"**,
which reached him nowhere at all before, and the August→September month, which
reached him only as the third semicolon-clause of a "yours to decide"
paragraph.

**D-C (fix round 2) — …and now they reach him on the BOARD, which is where he
actually reads them.** D5 above routed the findings into `report.md` and
stopped there. The tester then served this same scored run through the real
Number One reader — real daemon, headless Chrome — opened every filter and
every disclosure, and dumped 46.8k characters of rendered text: not one
observation was in it. Not "the month did not carry", not the 41px icon on
Back to builder, not even the two crowding lines that predate this round. The
data was in `verdict.json.observations` the whole time and `board.js` never
read the array. It does now: the measured and walked findings are drawn as
boxed blocks in the same list as the requirements, above "couldn't check",
under the same two headings `report.md` uses, with the same signpost sentence
at the top of the pane — and behind a filter of their own, **I measured**,
because they are not scored criteria. The S210 contract is untouched: a
measurement carries its own outcome word, says on its face that it does not
change the grade, and is never counted inside "Didn't work".

---

## Read the "found by" column before celebrating

Two of the five faults in look C, and two of five in look D, were found by
**the deterministic measurements parts B and F added to the harness and by
nothing else**. That is what those parts are for, and it is the good news: r4
(on a preview screen the drawing never drew) and r5 (a value that changes
between two screens) were produced identically in both runs, and in the round-0
record before any worker spoke. They are repeatable, not a lottery.

But it also means the model's own contribution is r1+r2+r3 in both looks — the
same band looks A and B were already in. **A later agent should
not read 5/5 as "the model now sees everything."** What moved is that the
harness walks the whole flow, measures every screen it stands on, and hands the
worker facts it cannot grade away.

The grade is the other honest half. Both runs graded MEDIUM, inside the cap,
and `gradeEarned` is true in both — a declared fault is what drove it there.
The baseline's medium was **not** earned: it was medium in spite of seeing
nothing.

---

## A real defect parts E/F/G introduced, found while measuring

**Part F's walk poisons the repo's own test suite.** In *both* looks that
reached the flow (C and D), the project's 597-test suite came back RED — 6
failures — because the walk types into the app, the app autosaves to disk, and
the typed string plus a draft id `2026-09-20.0` leaked into the project's
fixtures. Looks A and B, which never reached the flow, both reported the suite
green. So this is not load or flake: **it reproduces 2 out of 2 whenever the
walk actually walks.**

Number One caught it itself and did not charge it to the build — *"they are my
own walk's autosaved draft leaking into the fixtures"* — and the harness printed
*"I am not counting that against the build on its own."* That is good
behaviour, but it is a cure downstream of the cause: the walk is mutating the
repo under test, and a later look (or a human) reading that suite would see a
red build that is not red. Worth a ticket.

---

## The planted case — the Tide Board fixture (the regression)

**4 of 5, 0 of 2 correct controls flagged, grade low and earned.** It holds the
required 4–5 of 5 with no false alarms — unchanged from after parts B/C/D. The
miss is `p4-help-corner`, the same soft spot the baseline flagged, where the
look names the part but gets the corner only half right. It found the oversized
save icon, the wrapping Publish label, the green-instead-of-red stale chip and
the missing Export CSV, left both correct controls alone, and caught the
blank-note lock gate publishing anyway. It took all 4 declared journey steps
(3 clicks, 1 typing, 0 address jumps).

---

## A drill bug found and fixed while measuring

`score.py`'s walk column read **only** `actions-*.json` — the list of moves the
*worker* asked for. Part F added a second mover: LCARS itself now walks the
declared journey before the worker says anything, and records it in
`walk.json`. So the drill reported **0 clicks and 0 typings for the planted
arm, which had clicked three times and typed once**, and **0 clicks for look D,
which had clicked seven times.** Read literally, it would have said parts E/F/G
made the walking *worse*.

The fix is additive and changes no recall, false-alarm or grade number: a second
`walkDeclared` block, read from `walk.json`, printed on its own line and written
to the result JSON beside the original `walk`. The original rule is untouched so
`BASELINE.md`'s numbers stay comparable. The ten `selftest.sh` cases still pass.
Nothing else in the drill was changed, and nothing outside it was.

---

## Evidence

Each directory is that look's own `xo/` — verdict, criteria, observations, the
walk, the action lists, the per-shot readouts — trimmed of PNGs (`.gitignore`
covers `tests/drives/**/*.png`), of `shots/`, `drawing/` and `logs/`, and of
`build-parts-*.json`, which are over 80KB and regenerate on a rerun.
`verdict.json` is kept whatever its size: it is the answer.

    after-efg-scored/real-lookC/    + real-lookC.score.json, real-lookC.look.log
    after-efg-scored/real-lookD/    + real-lookD.score.json, real-lookD.look.log
    after-efg-scored/real-lookA/    + real-lookA.score.json, real-lookA.look.log
    after-efg-scored/real-lookB/    + real-lookB.score.json, real-lookB.look.log
    after-efg-scored/planted/       + planted.score.json,    planted.look.log

`after-efg/` beside it holds the round-0 deterministic record of look C — the
journey, the walk, the layout observations, the scan and the carry — taken
before any worker had spoken.

To reproduce one: `bash tests/drives/s220/bench/run.sh --case real --from
after-efg-scored/real-lookC`.

---

## What these numbers are NOT evidence of

- **Not a measurement of one frozen tree.** `skills/lcars-xo/` was still being
  edited while looks A, B and C were in flight (`xo-score.py` 20:32,
  `xo-journey.py`/`xo-drive.js` 20:40, `prompts/evaluate.md` 20:41, `xo.sh`
  20:53). Look C in particular picked up a changed `xo-drive.js` mid-run. **Look
  D is the only run against a tree that did not move under it** — and it agreed
  with look C exactly. Anyone repeating this should freeze the source first.
- **Not a repeatable 5/5 for the model.** Four real looks at nearly the same
  code scored 4, 3, 5 and 5. The deterministic half is what should repeat.
- **Not a Claude measurement.** Both arms ran on Copilot.
- **Not free of concurrency damage.** Four looks were running at once when this
  session began, which is what starved the box; look C's slow rounds were
  measured under that load, and look D (run alone) finished on its FIRST worker
  round where look C needed two. **Run one at a time.**

---

## Fix round 3 (F2): the comparator learned the word "arrow" — and no number here moved

The icon vocabulary was the harness's own short list — `icon|glyph|svg|chevron`
— so the identical sentence scored 1 with "icon" in it and 0 with "arrow". That
bit the REAL case, not a hypothetical: the build's Continue-to-builder icon IS
an arrow, and the look's own words for it, quoted in the table above, are "an
oversized arrow icon". The list was widened generically to what a person
writes — arrow, symbol, graphic, image, mark, badge, artwork, logo, caret —
bounded and pluralised so "bookmark" and "remarkable" are not icons, in both
`score.py`'s comparator (`ICON_WORD`) and `known-answers/kinds.json`'s
`oversized-icon` patterns.

**Every recorded run on this page was then re-scored** — `baseline-run/`,
`after-bcd/`, all four `after-efg-scored/` looks and `fix1-scored/real-lookE` —
against the pre-F2 scorer and the post-F2 scorer, and compared on `found`,
`foundByModel`, `foundByDetector`, `foundByHarness`, `falseAlarms`,
`falseAlarmsByModel`, `recall`, `recallByModel`, `gradeOk`, `gradeEarned` and
`notComparable`. **Not one number moved**, so nothing published above changes.
That is the expected result and not a null one: the looks in these runs all
happened to say "icon"; the widening is for the look that says "arrow", and the
selftest now holds the tester's own sentence — *"on the Lock month control the
arrow overflows its 32px frame at 34px"* — plus two more, as must-match cases.

One caveat for whoever reads these files next: the stored `*.score.json` under
`baseline-run/`, `after-bcd/` and `after-efg-scored/` were written BEFORE fix
rounds 1 and 2, so they carry none of the per-eye columns (`foundByModel`,
`foundByDetector`, `notComparable`). Re-scoring them fills those in. That is a
STALE-FILE difference, not a scoring change, and it is why the comparison above
was run pre-scorer against post-scorer rather than against the files on disk.
