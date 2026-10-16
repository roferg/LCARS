# bug-prd.md — the evidence-first bug PRD

The template for a bug the **live check** found. File it with:

```bash
ech.sh file-bug --parent <mission-id> --prd <your-bug-prd.md>
```

`file-bug` validates this shape and then calls `lcars log`, which files the bug
as a **child Mission** of the parent, grounds it against the parent's existing
code, and labels its issue `lcars:linked`.

## Why this shape and not prose

On the modelled weekend of 26–29 Sep 2026, bugs written in prose came back:
the worker fixed something adjacent, or built a parallel dead control beside
the real one, and the bug had to be re-filed. The bugs that were **fixed first
time** all had the same three things, and they are the three this template
makes mandatory:

1. **A title that states the broken behaviour as a sentence** — not a topic.
   "every promote/demote request is refused — publish writes an issue body the
   hub can't parse", not "promote/demote bug".
2. **AC #1 is `Observed live:`** with the **exact output** you saw and the real
   identifiers — the command, the ids, the paths, the hosts, the field names.
   This is not optional and `file-bug` refuses a PRD without it. It is what
   lets the worker reproduce the fault in one step instead of guessing at it,
   and it is the only part of a bug report that cannot be wrong.
3. **A round-trip criterion when the bug sits at a seam** — a test that drives
   **both real halves** with **no hand-written fixture** between them. Six of
   that weekend's live breaks sat at a seam their tests stubbed; a test that
   stubs the seam it claims to prove is not proof.

## The template

Copy everything between the rules, replace every `<…>`, and delete nothing.

---

```markdown
# Mission: <the broken behaviour, as a sentence — what is wrong, and where>

**Type:** bug
**Seam:** <producer (file:function, what it writes) -> consumer (file:function, what it reads)>   |   none
**Goal:** <the CORRECTED INVARIANT, as something that is true afterwards and
checkable — "the host the CLI stores is the host the page renders, for every
record" — not "fix the host bug".>
**Acceptance Criteria:**
- Observed live: <the exact command you ran> <and its exact output, quoted>.
  <the identifiers: the record id, the file path, the field names, the host.>
  <one sentence naming the two rules that disagree, if that is the shape.>
- <the corrected behaviour as ONE shared rule, naming where it is declared>
- Round-trip test with NO hand-written fixture: <the test drives the real
  producer, feeds its output to the real consumer, and asserts <what>>.
  <required whenever Seam is not `none`>
- <any further case: the second actor, the non-default host, the empty input>
**Out of Scope:**
- <the neighbouring faults you also saw, each filed as its own bug>
**Constraints:**
- <the stack rule: stdlib only, no network in tests, keep the permission model>
- <which seams a test may stub, and which it may not>
```

---

## A filled-in example — the ONE exemplar to match

**This worked example is the style exemplar.** Match it, not the PRDs in the
weekend archive (`canvas-weekend-2026-09-26/evidence/filed-prds/`): those
**predate this template** and `file-bug` refuses them — no `Out of Scope`
section, no `**Seam:**` line, and an AC #1 worded `Observed (real code, no
stubs on the contract):` instead of `Observed live:`. The validator is right
and the archive is simply older; do not "fix" the validator to accept it.

The product below (`kettle`, a brew timer) is **fictional on purpose**. An
example drawn from the product you are about to check hands you one of its
faults for free, and a fault you were handed proves nothing about the checks.
What to copy is the *shape*: a title that is a sentence, a Goal that is the
corrected invariant, a quoted command with its quoted output and the real
identifiers, and a round trip over both real halves.

```markdown
# Mission: every brew in the log reads "0 min" steep, never the time that was recorded

**Type:** bug
**Seam:** kettle.py cmd_brew (writes the record) -> brewlog/report.py steep_minutes (reads it)
**Goal:** The steep time the CLI records is the steep time the brew log shows,
for every brew, in the same unit.
**Acceptance Criteria:**
- Observed live: `python3 kettle.py brew "assam" --steep 210` stored
  `"steepSeconds": 210` in `brews/b-0007.json`; `python3 -m brewlog.report`
  then rendered `<td class="steep">0 min</td>` for `b-0007`. The writer stores
  SECONDS under `steepSeconds`; `steep_minutes()` reads `steepMinutes` and
  falls back to `0`, so the two halves never meet and nothing errors.
- ONE shared field name AND ONE unit, declared in `brewlog/schema.py` and used
  by both halves.
- Round-trip test with NO hand-written fixture: the test brews a record with the
  CLI's own `cmd_brew`, renders it with the real `report()`, and asserts the
  rendered steep time is the one that was passed in.
- The same round trip for a brew with no `--steep` given: both halves agree on
  the default, in the same unit.
**Out of Scope:**
- `--steep` accepting a negative number without complaint (filed separately).
- The column order of the brew log.
**Constraints:**
- Stdlib only; no network in tests.
- The test may stub the clock. It may NOT stub either half of the seam —
  that is the thing under test.
```

## What `file-bug` checks, and refuses

| It refuses | Because |
|---|---|
| a missing `Mission title`, `Type`, `Goal`, `Acceptance Criteria`, `Out of Scope` or `Constraints` section | `lcars file` requires all six; being told now is an edit, being told later is a re-file |
| `Type` that is not `bug` | a logged bug is a bug Mission |
| a missing `**Seam:**` line | you have to decide whether this is a seam bug; `none` is a fine answer, silence is not |
| AC #1 that is not an `Observed live:` line | the exact output is the one part of a bug report that cannot be wrong |
| a declared Seam with no `Round-trip` criterion | a test that stubs the seam it claims to prove is not proof |
| a `log.sh` that exits 0 without linking a child | a filing nobody can see is not a filing |

## Two notes on what you do *not* have to write

- **The anchor rule and the seam declarations are harness defaults now.** The
  Plan prompt injects the drawnAt/notDrawn anchor rule from one source, and the
  validator enforces the declared producer/consumer seams. Do not paste either
  into a PRD's Constraints — it would be a duplicate of what the harness
  already does.
- **One PRD per bug.** `--prd` may be given many times; each one becomes its
  own child Mission, which is what lets `resolve-logs` raise a single
  re-verify gate for all of them.
