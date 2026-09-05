# S181 — the measured "after"

Live Copilot (`claude-opus-4.8`), Plan → Plan Review → Schedule, stopping before
Implement. Baseline in `BEFORE.md`. 26 pipeline draws + 8 reviewer-only probe
calls.

## Headline

| | before (`6e8a9c8`) | after (`b53c5d8`) | confirm (`b80f8ec`) |
|---|---|---|---|
| **builder — chained** | **2 of 3** | **0 of 5** | **0 of 2** |
| independent control (stay wide) | 5/5 wide | 2/2 wide ✓ | — |
| serial control (stay serial) | 12 waves ✓ | 2/2 × 12 ✓ | 2/2 × 12 ✓ |
| greenfield scaffold `true` | no baseline | 2/2 ✓ | 3/3 ✓ |
| queue signal on integrator tail | — | **missed** | **fires** ✓ |

**Cumulative builder rate: 2 of 3 chained on main → 0 of 7 post-cure.**

Both original rationales are gone. Draw 201's *"preserving top-to-bottom order"*
and draw 203's *"chained on t-004 for shared-file serialization"* have no
counterpart in any post-cure draw. The replacement language tracks the new prose:
one draw used **"sibling"** in all twelve rationales and named shared-file overlap
as explicitly not a reason to wait.

## The best draw was not the cleanest one

On builder draw 302 the reviewer objected about the shared `sections` registry.
The planner responded by **inventing one foundational infra ticket** and hanging
all twelve sections off it as siblings — **2 waves of `[1, 12]`** instead of 13
waves of 1, with `1 true, 12 false` and one `"reason"` key. It serialised exactly
where substrate genuinely existed and nowhere else. That is the target behaviour,
not merely the absence of the bug.

The serial control shows the same discrimination from the other side:
> *t-002:* "Consumes RawRecord[] produced by t-001… **Its tests run against the
> real raw reader output**, so t-001 must exist first."
> *t-009:* "**Reads what t-008 persisted** and defines the Manifest the verifier
> re-checks."

## D-8 proven on a naturally-occurring shape

Confirm draw 422 produced the integrator tail (a `t-012` orchestrator depending
on all eleven predecessors) — the shape invisible to the old hand-matched
predicate on after-draw 322. Same graph shape, two builds:

- **before:** no signal; *"(The harness could not attribute this shape to declared
  infrastructure or to a single dependency chain.)"*
- **after:** `⚠ DEPENDENCY-QUEUE SIGNAL — run through the scheduler's own wave
  computation, these dependencies admit ONE ticket at a time…` and
  `CAUSE: the plan declares a dependency queue — its edges admit ONE ticket at a
  time, so all 12 tickets build one after another.`

## The blunting probe — the session's biggest open risk, closed

Feeding the dependency framing to Plan Review could have made it reluctant to
demand a real edge. The confirm drive could not settle this (0 bounces in 7, but
*"a reviewer that never sees a defect and a reviewer that ignores defects produce
identical output"*), so two plans with ONE planted, declared defect each were fed
straight to `plan-review` on both builds.

| | pre-D-7 (`6e8a9c8`) | post-D-7 (`b80f8ec`) |
|---|---|---|
| **P1** spurious infra `true` | CAUGHT 2/2 | CAUGHT 2/2 |
| **P2** missing real edge | CAUGHT 2/2 | CAUGHT 2/2 |

**8 of 8 caught**, every objection naming the planted ticket by id. No cell split,
so no tiebreakers were needed.

**The post-D-7 objections cite the new framing explicitly** — the outcome that
would most strongly vindicate D-7:
> *"Add t-003 (**it READS the formatCurrency module**) so t-007 is not scheduled
> blind beside the formatter it needs"*
> *"**t-007 reads the formatCurrency module t-003 creates**"*

Pre-D-7 caught the same defect in generic scheduling terms (*"Schedule could place
t-007 in the same wave"*). One post-D-7 draw also raised an **extra** objection the
pre-D-7 reviewer did not — over-eagerness, not a miss. **On this evidence the
reviewer is not worse at demanding a real edge; it is slightly better.**

Probe plans: `tests/drives/s181/probes/`.

## What the proof is blind to

- **A live Claude planner.** Every draw was Copilot. The captain approved
  Copilot-only at briefing on the grounds that the mechanical changes are
  engine-independent and the prompt text is byte-identical per engine; per-model
  drift is what the now cause-naming `wave_shape` warning monitors at runtime.
- **Implement.** Deliberately never entered on any of the 34 missions.
- **Sample size.** 2/3 → 0/7 is a large move, but these are small samples of a
  stochastic process. The defect was measured to be a lottery (2 of 3 on one
  identical brief), so no single draw in either direction means much.
- **The bounce-rate question.** The probe shows the reviewer still finds both
  defect classes when present; it does not explain why the confirm drive saw 0
  bounces in 7. Best explanation remains that those 7 plans were clean.

## Open question nobody has ruled on

**Is a design-token stylesheet shared infrastructure?** Greenfield draws have
flagged it `true` (after 332, confirm 402) and `false` (confirm 403), with the
reviewer accepting both, and one post-D-7 probe draw objecting to `true`. It is a
genuine coin-flip. Settling it needs a line in `plan.md`'s true/false shapes, not
another drive.
