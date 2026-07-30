# Proof drive — the Mission-Log fold, both directions

> ⚠️ **BILLABLE AND MANUAL.** This spends real tokens on real `copilot` workers.
> It must NEVER be wired into `tests/run.sh` or any automatic suite. Run it by
> hand when you have changed the fold, `lcars approve`, or `lcars resolve-logs`.
> Last run: **$8.56** total (feature mission $3.63, logged bug $4.93; 16 worker
> sessions), about 25 minutes wall clock.

## What it proves

A logged bug's fix folds onto its **parent's** branch and the bug gets **no PR of
its own**, so two separate things have to be true at once, and they can fail
independently in opposite directions:

| | the CODE | the CARD |
|---|---|---|
| **2026-07-28 incident** | ❌ fix vanished from the branch | ✅ read Done |
| **2026-07-29 incident** | ✅ merged into `main` | ❌ stranded at verify |

Each fix closes one direction and could plausibly reopen the other, so they are
driven together. The drive asserts **both**:

- **(A)** the bug's `lcars(<bug-id>)` commit is on merged `main`, and the feature
  is really in the merged file
- **(B)** the parent card *and* the bug card both read `done`

## What is real, and what is not

Real: `copilot` workers driving Research → Validate → Plan → Plan Review →
Schedule → Implement with real TDD, real flip-flop and declared-edit gates, real
commits, the real fold, and the real `lcars approve`.

Local: the **forge only**. `origin` is a bare repo on disk, and
`host-stub.sh` stands in for `skills/lcars-run/host-adapter.sh`. Its `pr-merge`
performs a *genuine* fast-forward of `origin/main` to the mission branch — the
branch is `main` plus the mission's commits, so a fast-forward **is** the merge.
That is what makes "did the folded bug's code reach `main`?" a real question
answered by reading `origin/main`, rather than a mock asserting itself.

`copilot` also plays the **captain** twice, non-interactively: once to author the
feature PRD, once to file a bug against the delivered code.

## Running it

```bash
DRIVE_ROOT=$(mktemp -d) bash tests/drives/fold-both-directions/drive.sh
```

Exit code is the number of failed checks (0 = both directions hold). Artifacts —
every stage's stdout, the mission dirs, the host-adapter call log — are left under
`$DRIVE_ROOT/state` for post-mortem.

Optional env: `LCARS_REPO` (defaults to `~/Projects/LCARS`).

## Deliberate limits

- **One bug, not a batch.** It does not reproduce the multi-child shape (four bugs
  logged against one parent), so it exercises `resolve-logs complete --bug` per
  child but not the bulk path's completeness guard.
- **No real GitHub.** PR semantics — required checks, merge conflicts, `Closes`
  directives, sub-issue nesting — are not exercised.
- **Fresh repos need a version stamp.** `.git/lcars/config.json` must carry an
  `lcarsVersion`, or `file.sh` blocks forever on the interactive
  `RUN lcars update? [y/N]` prompt. The drive stamps it from `VERSION`; any other
  automated drive must do the same.
