# The live-Copilot baseline — real model output, not a hand-written fixture

Measured 2026-08-28 by the S178 orchestrator against **pristine HEAD** (today's
unmodified Plan prompt), live Copilot, three identical runs.

The setup: an 8-ticket plan with genuine parallelism (`pre-review-plan.json`) and
ONE Plan Review objection (`plan-review-1.json`) asking for exactly ONE edge —
add `t-004` to `t-006`'s dependencies.

    pre-review:  t-001 []        t-002 []        t-003 [t-001]   t-004 [t-001]
                 t-005 [t-001]   t-006 [t-001]   t-007 [t-002]   t-008 [t-001]

All three runs FAILED, and — this is why these files are committed — **none of
them failed the way the doc's measured case failed.** The doc's case is a 14-deep
linear chain. These are GRAPH CHURN: edges added and removed all over a graph
that stays roughly the same shape, and run 3 barely moves the wave count at all.

    run 1  t-003 [t-001,t-002] · t-004 [] · t-006 [t-003,t-004] · t-007 [t-001,t-002]
    run 2  t-003 [t-001,t-002] · t-004 [] · t-005 [t-001,t-002] · t-006 [t-001,t-003,t-004] · t-007 [t-001,t-002]
    run 3  t-003 [t-001]       · t-004 [] · t-006 [t-003,t-004] · t-007 [t-001,t-002]

Invariant across all three: `t-007` gains `t-001`, `t-006` gains an unrequested
`t-003`, and `t-004` LOSES `t-001` — none of which anyone asked for.

**This is the argument for the guard being a per-ticket EDGE DIFF and nothing
else.** A guard keyed on "the revision became a chain", or on wave count, or on
any aggregate shape, would wave all three of these straight through.
