# S220 · the benchmark — can Number One's LOOK find what a careful person finds?

Every other part of Session 220 changes how Number One looks at a build. This
part is the ruler the others are measured with, and it is built first, on
purpose, so that its numbers are recorded **before** anything moves.

    bash tests/drives/s220/bench/run.sh [--case real|planted|all]

It sets itself up, runs the look live, scores it, prints a table and writes a
JSON result per arm. `run.sh --help` lists the options. `BASELINE.md` holds the
numbers today's code produced, with the raw output beside it in `baseline-run/`.

---

## The two arms

**The real case** — DX-Scorecard PR #206 at `672825b`, the branch head when it
reached Verify on 2026-09-19, before any fix. The drill **clones** that repo
(local objects, no network), checks out the SHA, installs into the clone, and
copies the mission — drawing, PRD and all — out of the captain's checkout
read-only. His working tree is never written to, and `node_modules` is
installed into the clone rather than symlinked: the spike symlinked his and
vite wrote a cache back into it.

Five known faults, every one of them **measured in a browser** rather than
recalled (the measurements are in `known-answers/real.json`): four buttons that
hold an icon bigger than themselves and wrap their label, and a month that
changes between the start card ("August 2026") and the collect step it leads to
("Pulling data · September 2026"). One correct control — the Preview button,
one line, no icon — is declared too, so a look that complains about everything
cannot score well by accident.

Worth knowing before you read a low number as a surprise: only *Continue to
builder* has an `id` in the drawing at all. *Pull data & start* and *Lock month*
have none, and *Back to builder* is on a preview screen **the drawing never
drew**. All four are declared anyway. The benchmark measures what the look
finds, not what the drawing enumerates.

**The planted case** — a small fixture app (`fixture/app/`) beside a drawing
whose parts carry ids (`fixture/drawing.html`), in the shape of the S192/S213
fixture arms. Five planted faults, each commented at the line that plants it:

| key | part | what is wrong |
|---|---|---|
| `p1-save-icon` | Save reading | a 44px icon in a 34px control (drawn 16px) |
| `p2-publish-wrap` | Publish board | the label wraps at 74px (drawn one line at 160px) |
| `p3-chip-colour` | stale-readings chip | built green, drawn red |
| `p4-help-corner` | Help | bottom-left of the head, drawn top-right |
| `p5-export-missing` | Export CSV | drawn, never built |

and two controls that are **right**, which a look must not flag:

| key | part | why it is correct |
|---|---|---|
| `c1-tabbar` | the tab bar | flush, edge to edge, exactly as drawn |
| `c2-notice` | the notice | two lines — but the drawing wraps it too |

Plus the part-F pair, reported separately from recall: a second screen with no
address, reachable only by clicking **Open the board**, and a **Lock the board**
gate that publishes with a blank note when the drawing says it refuses.

---

## The rule

A score is worth nothing if the thing being scored can also decide what the
right answer was, so the two are kept apart by force:

1. **Known answers are declared, never inferred.** They live in
   `known-answers/real.json` and `known-answers/planted.json` and come from the
   fixture's own source and from direct measurement of the build in headless
   Chrome. Nothing in them is read back out of anything a look has said.

2. **Every finding carries WHERE IT CAME FROM, stamped when it is produced.**
   A look has two eyes: the model's own words (its criteria, notes, reasons and
   the bugs it files) and the deterministic detectors LCARS runs beside it (the
   part-by-part measurements, the layout pass, the journey's carry and gate
   checks). Each is judged on its OWN pass and reported in its OWN column —
   recall by the model's eye, recall by the detectors, and the union — because
   one number over both flatters whichever is weaker. It flattered all the way
   to 5/5 on 2026-09-19, with every model criterion muted to "met": the model
   said nothing at all and the drill called it "medium, earned". A silent model
   now scores zero in its own column by construction, not by inspection.
   Provenance is never worked out afterwards from the order a list was built
   in — that is iteration order, not provenance.

3. **Only complaints count.** The look's output is reduced to *negative
   findings*: a criterion whose status is `gap` (its own word for "didn't
   work"), an entry in the layout observations, or a bug it filed. A criterion
   marked `untested` — "I couldn't check this" — is counted and printed, but it
   is neither a find nor a false alarm. Saying you could not see something is
   not the same as saying it is broken, and it must never be able to earn
   recall. `met` is never a finding.

4. **A match needs both halves, in the same finding, ABOUT THE SAME PART.** A
   known fault counts as FOUND when one negative finding matches **(a)** one of
   that part's name patterns *and* **(b)** one of the patterns for that fault's
   kind. The kind vocabulary — `oversized-icon`, `wrapped-label`,
   `wrong-colour`, `wrong-corner`, `missing-part`, `month-mismatch`,
   `gate-wrong` — is declared once in `known-answers/kinds.json` and shared by
   both arms. Either half alone would be a text search over prose: "lock" is in
   a dozen criteria that have nothing to do with that button, and "two lines"
   turns up wherever a look discusses wrapping anything at all.

   "About the same part" is the half that was missing. A criterion whose PRD
   text NAMED the four buttons, whose note said they "render correctly", and
   which complained only about an unrelated 72px org-picker icon scored **4/5
   FOUND**: the name came from the question and the kind from an answer about
   something else. So the kind is matched CLAUSE BY CLAUSE. A clause that both
   names the part and carries the kind is taken at once; otherwise the clause
   carrying the kind must at least not point at a different named thing (a
   hyphenated compound, a camelCase id or a quoted label sitting in front of a
   word for a part). Adjectives — `single-line`, `34px-tall`, `read-only` —
   are not names and never count.

5. **A kind that is a comparison is compared, not floored.** `oversized-icon`
   carried a bare `4[0-9]|[5-9][0-9]|…px` floor inside its own regex, so the
   real Lock month button — a 34px icon MEASURED in a 32px control, one of the
   five declared faults — was not "oversized" unless prose happened to say so.
   Kinds may declare a named COMPARATOR in `kinds.json` (implemented in
   `score.py`); `icon-bigger-than-its-control` reads both measurements out of
   the look's own words and asks whether 34 > 32. No invented floors.

6. **A false alarm is the same test, widened.** A declared-correct control is
   flagged when a negative finding names it and reads as *any* kind of
   complaint — not just the one fault it happens not to have. The name patterns
   must answer to how a person writes, not to one word: "the Preview **control**
   is the wrong shade of blue" and "Preview **is drawn** but I could not find
   it" are both cries of wolf, and neither says "button".

7. **A control nothing was DRAWN for is NOT COMPARABLE, not a pass.** A
   declared-correct control whose `pairs.json` entry has a 0×0 drawn box was
   never held against anything, and a clean sheet over it is a number about
   nothing. It is reported by name, on its own line.

8. **The matched text is scoped to the criterion.** A finding's text is that
   criterion's own wording, note and reason — not the whole report. A sentence
   elsewhere in the prose cannot pay for a criterion the look graded "worked".

9. **Walking is read from the record.** `actions-*.json` is the list of moves
   the look actually executed, so clicks, typings, keypresses and address jumps
   are counted from it. One navigation is the front door; every later one is a
   jump past the entry. A declared step is only *taken* when its before/after
   state differs: a step that changed nothing is counted in its own column as
   couldn't-check, never among the steps taken.

The rule lives in exactly one place — `judge()` in `score.py` — and the printed
table, the JSON and `BASELINE.md` all come out of that one function.

---

## Checking the ruler itself

    bash tests/drives/s220/bench/selftest.sh

A benchmark that reports 0/5 is only evidence if it *can* report 5/5. The
selftest feeds `score.py` hand-written verdicts — a look that found everything,
one that only said "I couldn't check", one that graded a broken control
"worked", one that cried wolf over both correct controls, and one that names a
part without naming a fault — and checks the number that comes back. No worker,
no browser, no spend, a second to run. Run it after any change to `score.py` or
to `known-answers/*.json`; the wordings in it are deliberately unlike anything
a real look has said, so the rule has to turn on the part and the kind rather
than on a remembered transcript.

## Re-running it after a change

    bash tests/drives/s220/bench/run.sh --case all --label "after part B"

The drill is **resumable**: a clone that exists is reused, `npm install` runs
once, and an arm that already has a `verdict.json` on disk is scored rather
than re-looked. Force a new look with `--fresh`, or by deleting that arm's
directory under the work dir (`$TMPDIR/s220-bench` by default, `--work` to move
it). Every live look is caged (`--timeout`, 45 minutes by default) and a look
that hits the cage is scored on whatever it managed, loudly.

To score a look captured somewhere else — another agent's run, an older
recording — point the drill at its `xo/` directory:

    bash tests/drives/s220/bench/run.sh --case real --from /path/to/mission/xo

Copilot only, and only by absolute path (`/opt/homebrew/bin/copilot`): a VS Code
shim of that name on `PATH` fork-bombs the machine. `run.sh` refuses a relative
one. Claude is never spawned. Screenshots are not committed — `.gitignore`
covers `tests/drives/**/*.png` repo-wide.

## What this drill does not measure

- **Whether a found fault was found for the right reason.** A look that flags
  the Lock month button because its label wraps scores the same as one that
  flags it because the icon is oversized: both name the part and read as a
  complaint of a declared kind.
- **Anything about a build with no drawing.** Both arms have one.
- **The quality of the writing.** A finding the captain could not act on scores
  the same as one he could.
- **Claude's eye.** Both arms run on Copilot.
