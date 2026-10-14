# Configuration

You should not need this page on day one. `lcars init` writes a working
`.git/lcars/config.json` and the Align estimator chooses a model tier per Stage
for you. This is the day-two reference for when you want to override something.

LCARS **never** modifies `CLAUDE.md`, `.gitignore`, `CONTEXT.md`,
`.claude/settings.json`, or any of your source files.

## Per-repo config: `.git/lcars/config.json`

`lcars init` writes it; `lcars update` absorbs keys added by a later LCARS
release. Both are **merge-preserving** — an existing value is never reset, only
missing keys are filled in at their defaults, and `missions/` is left alone. So
re-running either is safe.

| Key | What it sets |
|---|---|
| `model` | The default tier when nothing more specific applies. |
| `testCommand` | The suite the Implement proof gates run. |
| `contextFile` | The repo's own context document, if it has one. |
| `notify` | Where walk-away notifications go (see below). |
| `comprehensionBudget` | How much of the repo a worker is expected to read. |
| `numberOne` | Whether Number One is engaged here, and on which engine. |
| `lcarsVersion` | The LCARS version this repo was last stamped at. |

The Implement flip-flop gate records a parent failure caused by absent LCARS
initialization as `configuration-red` and returns **INCONCLUSIVE**, never PASS.
Like a runner environment failure, missing LCARS setup is not proof that product
behavior was missing on the parent commit.

## Choosing models per Stage

The estimator writes the per-Stage tiers into the Mission's `estimate.json`, so
you rarely touch these. When you want to, all of them are optional:

- `stages.<key>.model` — pin one Stage to a tier (`sonnet` / `opus`).
- `modelAliases.<cli>.<tier>` — change how a logical tier maps to a real CLI
  flag. The defaults are `sonnet` / `opus` on Claude Code and
  `claude-sonnet-4.6` / `claude-opus-4.8` on the Copilot CLI.
- `estimatorModel` — the tier the estimator itself runs on (default `opus`).

## What a run costs, and how that figure is reached

On Claude the estimate is in dollars. On Copilot it is in GitHub AI Credits,
with your plan's included allowance netted off:

- `copilotPlan` — `pro` / `proPlus` / `business` / `enterprise`. Sets the
  included-credit allotment subtracted from the estimate.
- `copilotBilling` — `usage` (default) for usage-based AI-Credit billing, or
  `legacy` for the older premium-request model.

Every rate, price and allotment the figure is computed from lives in one data
file, `skills/lcars-run/pricing.json`, so a billing change is a data edit rather
than a code change.

## Environment variables

External dependencies are injected as environment variables, so they are
swappable — and stubbable in the test suite.

| Variable | Purpose | Default |
|---|---|---|
| `LCARS_WORKER_BIN` | The cold-worker CLI every headless Stage spawns | auto-detected (`claude` or `copilot`) |
| `LCARS_WORKER_MODEL` | Global model pin, overriding per-Stage selection everywhere (config key: `workerModel`) | unset |
| `LCARS_MODEL_OVERRIDE` | Pin a tier for one axis on a re-run — `all:opus`, `implementation:opus`, `reasoning:sonnet` | unset |
| `LCARS_GH_BIN` | The GitHub CLI | `gh` |
| `LCARS_MAX_PARALLEL` | Concurrency cap for a wave's tickets and the Research fan-out | `4` |
| `LCARS_NOTIFY` | The notification hook fired at human gates | desktop banner + bell |
| `LCARS_VERSION_CHECK` | Set `0` to disable the throttled staleness check | enabled |
| `LCARS_WORKTREE_SETUP_CMD` | A command to run in a fresh worktree before a Mission's app starts | unset |

## Notifications

They fire **only** at a genuine gate — an escalation, or Verify — batched per
Stage. Never one per question, never on a clean transition between Stages. The
default is a local desktop banner; a phone push (ntfy or Pushover) is opt-in
through `notify` in the config.

## Where the state lives

```text
.git/lcars/
  config.json                  engines, model tiers, test command, notifications
  missions/<mission-id>/
    state.json  prd.md  estimate.json  research/  validated-plan.md
    plan.json  waves.json  tickets/  pending.json  answers.json  events.jsonl
```

It is inside `.git/`, so git never tracks it and your working tree stays clean.
Do not add it to a `.gitignore` and do not commit it.
