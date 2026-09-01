# S168 — the regression drives (2026-08-31 → 09-01)

The question these answer is NOT "does the fence work" (that is the parent
directory). It is the captain's question: **did this round break the harness's
ability to finish work?** The round added a check that can STOP A STAGE, and a
check that stops honest work is worse than the hole it closes.

## The answer

**Zero `worker_fence_breach` events across every live drive.** Not one false
fire, on either engine, in either configuration.

| drive | engine | stages that ran under the audit | breaches |
|---|---|---|---|
| `cap-cop-holo` | copilot | research, validate, plan ×3, plan-review ×2 (6 `stage_done`) | 0 |
| `claude-stages` | claude | research (15 cold workers), validate, plan | 0 |
| `claude-worktree` | claude | research **inside a real front-half worktree**, 15 cold workers | 0 |

The last row matters most: it is the ONLY live run in which the captain's
ruling — the post-turn checkout-cleanliness check — was actually exercised. The
other drives ran on missions with no branch of their own, so
`enter_mission_worktree` correctly declined to cut a tree and only the
mission-state half of the audit was live. That was found by checking rather than
assumed, and the branch was created specifically to close it.

## What stopped, and why none of it was the fence

- **`cap-cop-holo` stopped at Plan** — the **mockup-fidelity gate** (S174/S175,
  already merged) bounced the Plan worker 3× because ticket t-002 declares
  `changesScreenAppearance:true` and cites no `drawnAt` anchor. Inherited gate,
  working as designed, unrelated to this round.
- **Every plain-lane cell died at Align** — a FIXTURE defect of mine: the idea
  (`plain-idea.md`, a docs-site "recently viewed" strip) does not fit the target
  repo (DX-Scorecard, a KPI dashboard with no documents, sections or search box).
  **claude caught this and refused to proceed; copilot did not and carried on.**
  That contrast is worth more than the cell was.
- **Align holds an unanswered gate indefinitely, on BOTH engines.** Correct
  behaviour — Align is interactive and must not invent an answer — but it means
  the stand-in, which may only repeat recorded decisions, cannot get a mission
  through Align unless the record covers every question asked.

## Cost

Claude worker spend RECORDED by usage capture: **$18.32**. Not included: ~61
claude Align grill turns across the two failed claude cells, which bill outside
the mission usage log. Copilot's `$37.99` is notional AI-credit accounting on an
unlimited work account, not money.

## What these drives still do not prove

Schedule, Implement and Verify were never reached by any cell, so the narrowed
`--add-dir` grant is unproven against a real Implement worker, and the Verify
approve path is proven only by `capstone-smoke.sh` scenario 3. The Implement
worker is `repo-write` and therefore EXEMPT from the audit by design, so the
stop-the-stage risk this round introduced does not live there — but the grant
narrowing does.
