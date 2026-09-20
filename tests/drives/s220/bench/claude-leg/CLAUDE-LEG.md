# S220 · the Claude leg — one look, STOPPED ON COST before it reached a verdict

Run 2026-09-20 on `feat/number-one` (S220 uncommitted), against a **fresh clone**
of DX-Scorecard at `672825b` in `$TMPDIR/s220-bench-claude`. The captain's own
checkouts were never written to.

**Read this first: the benchmark question is NOT answered.** The look was killed
part-way through its second worker round because it had already spent more than
the whole authorised budget. It never wrote a `verdict.json`, so **the model's
own eye was never measured**. The `0/5` in the model column below is the drill
correctly scoring *a look that said nothing*, exactly as `README.md` rule 2
prescribes — it is an artefact of the stop, **not** a finding about Claude.

---

## The money, which is the real result

| | round 1 | round 2 | round 3 | look total |
|---|---|---|---|---|
| **Claude (Opus 5, measured)** | **$5.84** | killed mid-round | never ran | **$5.84 spent, ~$15–18 projected** |
| Copilot (Opus 4.8, recorded, look E) | $3.06 | $4.36 | $9.59 | $17.01 *on Copilot's own usage billing* |

Claude round 1, from `usage-claude.jsonl` — the per-engine capture, **measured,
not estimated**:

```
model claude-opus-5 · input 64 · output 50,715
cacheRead 3,506,855 · cacheWrite 451,525 · costUsd 5.84365
```

**Pre-flight estimate vs. reality.** Before starting I re-priced Copilot's three
recorded real-arm looks onto Claude's rate card ($5/$25 per MTok, cacheRead
×0.1, cacheWrite ×1.25 — `skills/lcars-run/pricing.json`, confirmed current for
Opus 5). That gave **$4.01 / $4.48 / $6.05 per look**, central ≈ $4.5 — under
the ~$5 ceiling, so the look was started. **One round then cost $5.84.** The
estimate was low by roughly 3×, because Claude's Number One round pulls ~3.5M
cache-read and ~450k cache-write tokens where Copilot's heaviest round pulled
1.3M/244k. The old lesson holds: **a token estimate transferred between engines
is not a budget.**

---

## What was measured before the stop

| | Claude (this leg) | Copilot look E | Copilot look C / D |
|---|---|---|---|
| model's own eye | **not measured** (no verdict) | 2 / 5 | 2 / 5 · 3 / 5 |
| detectors | **5 / 5** | 5 / 5 | 5 / 5 · 5 / 5 |
| union | 5 / 5 *(detectors alone)* | 5 / 5 | 5 / 5 |
| false alarms | 0 of 1 ‡ | 0 of 1 ‡ | 0 of 1 ‡ |
| grade | none written | low, earned | medium, earned |
| declared journey | **9 of 10 taken, 1 changed nothing** | 9 of 10, 1 changed nothing | 9 of 9 |
| journey moves | 6 clicks, 3 typings, **0 jumps** | 6 clicks, 3 typings, 0 jumps | 7 clicks, 2 typings, 0 jumps |
| its own extra looking | 4 clicks, 2 keypresses, **0 jumps** | 0 | 2 clicks, 1 typing |

‡ the one declared-correct control (Preview) is NOT COMPARABLE — 0×0 drawn box.

The detector column is deterministic and engine-independent, so its 5/5 is
expected and says nothing about Claude. It did fire identically here:

- r1 `Pull data & start` — 55px icon in a 38px control
- r2 `Continue to builder` — 61px icon in a 32px control
- r3 `Lock month` — 34px icon in a 32px control
- r4 `Back to builder` — 41px icon in a 30px control
- r5 `August 2026 became September 2026 after I clicked "pull data & start"`

## It walked; it did not teleport

The one genuinely new fact about Claude's behaviour. Its round-1 action list
(`actions-1.json`) is twelve moves and **not one of them is an address**:

```json
{"press":"Escape"} {"click":"Discard draft"} {"screenshot":"a1-discard-dialog"}
{"press":"Escape"} {"screenshot":"a2-after-esc"} {"click":"Lock month"}
{"wait":300} {"click":".modal-foot .btn.warn-primary"} {"wait":800}
{"screenshot":"a3-after-lock"} {"click":"Unlock"} {"screenshot":"a4-unlock-dialog"}
```

It went after the **lock/unlock/discard dialogs** — the part of the flow the
declared journey only brushes — by clicking through them and screenshotting
before and after each step. Scored: **4 clicks, 2 keypresses, 0 address jumps
past the front door.** On the S219 teleport test this is the right shape.

## Two things found on the way that are not about Claude

1. **The drill cannot select Claude, and does not claim to.** `run.sh` has no
   engine option; it hard-pins `LCARS_WORKER_BIN=$COPILOT`,
   `LCARS_XO_ENGINE=copilot`, `LCARS_COPILOT_BIN=$COPILOT` in one `BENCH_ENV`
   list, and its own header says "Claude is never spawned". The only knob is
   `$LCARS_BENCH_COPILOT`, which is misnamed for this and also sets
   `LCARS_COPILOT_BIN`. **No source was edited.** This leg used the drill's two
   documented seams instead: the shipped verb `lcars xo on --engine claude`
   (which writes `numberOne.engine`, the per-repo choice `resolve_stage_model`
   honours above the mission's `workerBin`), and `run.sh --case real --from
   <xo dir>`, the drill's own path for scoring a look captured elsewhere.

2. **`lcars xo on` starts a look immediately**, with no cage. `run.sh` wraps its
   own look in `timeout_wrap` at 45 min; the `on` verb does not. Worth knowing
   before anyone types it on a metered engine.

3. **The look turns the app's test suite red by its own hand.** The walk types
   `"Number One typed this to see it carry"` into a field; that writes through
   to the launch worktree's `data/`, and the project's own snapshot test then
   fails on it (`tests-summary.json`). Copilot's looks reported "tests passed"
   — so *whether Number One sees a green suite is luck of the draw*, and any
   grade that leans on it is unstable. This is the D7 issue ledgered in
   `AFTER-EFG.md`, reproduced here on a clean clone.

## Model parity, for the record

Copilot's Number One runs `claude-opus-4.8`, pinned by `write_capable_alias`.
On Claude the ladder in `resolve_stage_model` yields **no `--model` flag at
all**, so it took the CLI default — `opus[1m]`, i.e. **`claude-opus-5` with the
1M context window**, which the usage record confirms. Same tier and price card,
but the 1M window is the likeliest reason the context (and so the bill) ran
three times heavier than Copilot's.

## Files

`real.score.json` (the drill's own output) · `actions-1.json` · `walk.json` ·
`observations.json` · `journal.jsonl` · `usage-claude.jsonl` ·
`tests-summary.json`. No screenshots (`.gitignore:16` covers
`tests/drives/**/*.png`); `criteria.json`, `drawing-parts.json`, `pairs.json`
and the full `tests.json` were dropped — they are large and regenerate.

## What it would take to answer the question

One more look, budgeted at **$15–20**, run to a verdict. Nothing about the
method needs changing; only the money does.
