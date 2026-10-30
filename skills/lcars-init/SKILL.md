---
name: lcars-init
description: >-
  Initialize a repo for LCARS mission-based development. Scaffolds
  .git/lcars/ (config + missions dir), detects CONTEXT.md, verifies the
  Claude CLI, and creates the LCARS GitHub label set. Use when the user runs
  `lcars init`, asks to set up / bootstrap LCARS in a repo, or wants to
  prepare a repo for LCARS missions.
---

# lcars init

`lcars init` prepares a repo to run LCARS — the mission-based development
system where Claude runs the workflow and the captain (the user) makes the
decisions. It is **idempotent**: safe to run multiple times.

## What it does

**LOCAL**
- Creates `.git/lcars/` inside the repo's git dir (travels with the repo, stays
  out of the working tree):
  ```
  .git/lcars/
    config.json     ← { model, projectName, contextFile, created }
    missions/       ← one subdir per mission, added later by `lcars file`
  ```
- Scans the repo root for `CONTEXT.md`. If present, records its path in
  `config.json`; otherwise `contextFile` is `null`.
- Verifies the Claude CLI is available (`claude --version`). If it is missing,
  init stops with a clear error before doing GitHub work.

**GITHUB** — creates the LCARS label set on the current repo, skipping any that
already exist:

| Group | Color | Labels |
|-------|-------|--------|
| Stage | `#FF9900` | `lcars:align` `lcars:research` `lcars:validate` `lcars:plan` `lcars:plan-review` `lcars:schedule` `lcars:implement` `lcars:verify` `lcars:done` |
| Type | `#4499FF` | `lcars:feature` `lcars:bug` |
| Status | `#FF3344` | `lcars:paused` `lcars:awaiting-human` |
| Relationship | `#9977FF` | `lcars:linked` |
| Role | `#00B894` | `lcars:mission` `lcars:ticket` |
| Number One | `#FF9966` | `lcars:xo:high` `lcars:xo:medium` `lcars:xo:low` `lcars:xo:engaged` |

That is **20 labels** total.

## How to run it

```text
usage: lcars init [--help|-h] [--dry-run]
```

`--help` (or `-h`) prints this usage and exits successfully. Unknown options
exit non-zero with a usage error on stderr. Neither path creates local state
or calls `gh`.

`--dry-run` prints the config JSON a real init would merge and the canonical
label names and colors it would create if missing. It preserves existing
config values in the preview, but writes nothing, seeds no commit, runs no
worker or test probe, and makes no `gh` calls. Because existing GitHub labels
are not queried, all 20 candidate labels are listed. A new clone identity and
creation timestamp in the preview are provisional until a real init.

With no arguments, initialization runs as before.

The detected test command gets one live probe, bounded to 500 seconds by
default (`LCARS_PROBE_TIMEOUT` overrides it). Proof gates also default to 500
seconds. A timed-out probe records a provisional larger `gateTimeout` when
unset, stating only the exceeded bound, not a measured suite duration or a
passing verdict. Adjust it with `lcars update --gate-timeout <seconds>`
(1–3600), then re-probe with a suitable `LCARS_PROBE_TIMEOUT`.

Python detection reuses an existing interpreter from the shared git directory's
`lcars/testenv`, `.venv`, or `venv`, in that order, before falling back to
`python3`/`pytest`. It records an absolute interpreter path so isolated gate
worktrees use the same installed dependencies. On fresh init, if the detected
Python command's live probe does not pass, init probes the other existing
environments and PATH's `python3`, retaining the first command that actually
passes the suite. If none passes, the original command and its probe verdict
remain; an executable alone is not proof of capability. This does not run when
probes are skipped, in dry-run mode, or for an existing captain command.
A unittest suite containing only skips or expected failures is inconclusive,
never verified, and the search continues. Only an executed-and-genuinely-passed
test certifies: a passing run with some skipped tests or expected failures still
qualifies when at least one test genuinely passed.
Without an existing environment,
a missing dependency remains a reported probe failure, never a verified suite.
Existing customized test commands are preserved.

Run the bundled script from the repo you want to initialize:

```bash
bash ~/.claude/skills/lcars-init/init.sh
```

The script handles everything above and prints a readiness summary. Show its
output to the user. It looks like:

```
  ◇ NO ENGINE RECORDED — model seeded as "claude-sonnet" for claude:
    nothing records which engine this repo runs on, so init took claude — LCARS's historical default.
    If this repo should run on another engine, record it rather than letting a
    mission re-guess it:  lcars update --engine <engine>
  ✓ .git/lcars/ created
  ✓ config.json written  (model: claude-sonnet, context: CONTEXT.md)
  ✓ Claude CLI verified  (2.0.44 (Claude Code))
  ✓ 20 labels created on github.com/owner/repo
  LCARS ready — run `lcars file` to start your first Mission.
```

### The `model` seed follows the recorded engine (S309)

`model` is **not** a constant. It is seeded from the engine this repo or this
run actually **recorded**, in this order:

1. `$LCARS_MODEL` — the captain named it; it wins outright.
2. an existing `model` in `config.json` — preserved by the merge, never clobbered.
3. the repo's `workerBin` pin, else an ECH run's `.git/lcars/autopilot.json`
   `engine` (a record for an engine that is **not installed** is skipped, never
   obeyed), then `lcars_default_model_for_engine`: `claude` → `claude-sonnet`,
   `copilot` → `claude-opus-5.5`.
4. nothing recorded → the engine installed here, and init prints the
   `◇ NO ENGINE RECORDED` line above naming the engine, the reason and the verb
   that corrects it (`lcars update --engine <engine>`). It is a calm readout
   line, not a `⚠`: a fresh repo with nothing recorded is the normal first run.

**A record that was read and skipped is never reported as no record.** When a
record exists but names an engine that is **not installed here**, the skip is
correct — and saying nothing was recorded would be false, at the one moment the
captain most needs telling (on an unattended leg with a trimmed PATH, the record
that would have saved him the bill is the thing being thrown away). Init says
which of the two happened:

```
  ◇ RECORDED ENGINE NOT INSTALLED — model seeded as "claude-sonnet" for claude:
    this repo's run record names 'copilot', but 'copilot' is not on this machine
    (looked for 'copilot'). The record stands and was NOT obeyed:
    init seeded the model for claude, the engine that IS installed here.
    Install copilot, or record the engine this repo should run on:  lcars update --engine <engine>
```

And a record naming something LCARS does not drive at all is a THIRD case, not
that one: there is no binary to look for and nothing to install, so saying
"not installed (looked for '')" would send the captain after a thing that does
not exist. It gets `lcars update --engine`'s sentence instead:

```
  ◇ RECORDED ENGINE NOT RECOGNISED — model seeded as "claude-sonnet" for claude:
    this repo's run record names 'gpt5', but 'gpt5' is not an engine LCARS drives —
    it knows claude and copilot. There is nothing to install.
    The record stands and was NOT obeyed: init seeded the model for claude,
    the engine that IS installed here.
    Record the engine this repo should run on:  lcars update --engine <engine>
```

**And an incoherent pair is named, not left silent.** When init records an
engine pin for the first time while PRESERVING a `model` the repo already
carried — both individually correct — the pair it leaves can disagree, so it
says so in one line and names the verb that aligns them. It is a note, never a
refusal: top-level `model` is read by `lcars xo` (Number One's model) and not by
run.sh's resolver, which uses `modelAliases` / `stages.*.model`.

```
  ◇ ENGINE AND MODEL DISAGREE — engine recorded as "copilot", model left as "claude-sonnet":
    a model this repo already records is never clobbered, so init kept yours, and copilot
    runs "claude-opus-5.5". Align them when you want to —
    `lcars update --engine copilot` records the engine and moves the model with it;
    `lcars update --model '<model>'` sets the model alone.
```

This closes a measured **cost surprise**: a run started
`lcars-ech init --engine copilot` had its engine recorded in `autopilot.json`
and init wrote `claude-sonnet` anyway, so a mission filed without an explicit
engine would have billed a captain who asked for Copilot only. When the engine
is recorded, init also writes the `workerBin` pin, so no later stage re-guesses
it. `numberOne.enabled` stays `false` — the model seeding changed, not the switch.

## Notes & failure modes

- **Not a git repo** → the script exits with an error. Offer to `git init`.
- **Claude CLI missing** → the script exits non-zero with an install hint. This
  is intentional: LCARS depends on the CLI, so init refuses to half-finish.
- **`gh` missing or no GitHub remote** → local scaffolding still completes; the
  GitHub label step is skipped with a warning, and the user can re-run after
  installing/authenticating `gh`. Re-running only creates the missing labels.
- **Re-running** → existing labels are skipped, `.git/lcars/` is reused, and the
  original `created` timestamp in `config.json` is preserved.

## Implementation

The logic lives in `init.sh` next to this file so it can be exercised directly.
Its behaviour is covered by `tests/lcars-init.test.sh` in the LCARS repo (run
with `bash tests/lcars-init.test.sh`). The skill source lives in `skills/lcars-init/` in the
repo and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo
copy, not `~/.claude`. If you change `init.sh`, keep those tests green.
