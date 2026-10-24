# S313 — two REAL Copilot Plan outputs, same PRD, one line of prompt apart

Both files were written by a **live Copilot planner** (copilot 1.0.89, no
`--model`) driven through the **real Plan path** (`run.sh plan` → cold worker →
`plan-save`) on the same fixture Mission: a comment-thread renderer whose PRD
asks for an anchor chip AND for today's anchor-less output to be protected by
tests. Nothing here is hand-written.

- `standalone-lock-plan.json` — planned at **pristine HEAD** (before S313).
  The planner emitted the UNLANDABLE SHAPE on its own: `t-001` *"Pin today's
  anchor-less thread markup with golden tests"*, `estimatedNewLoc: 0`, a
  criterion that says *"src/thread.js is not modified by this ticket"*, and
  `t-002` depending on it. That ticket can never flip red on its parent, and the
  escape (`flipFlop: "not-applicable"`) is refused beside its new tests. This
  file is the live proof that the defect is real and that **Plan creates it**.
- `folded-plan.json` — planned with S313's Plan prompt in place. ONE ticket:
  the behaviour change, with the goldens riding along as a declared supporting
  criterion. Guard preserved, proof honest.

`tests/regression-lock.test.sh` feeds the first file to the REAL validator and
requires the refusal; the second is kept as the shape that must stay accepted.
Single samples, not a rate: they fix the mechanism, not the model's taste.
