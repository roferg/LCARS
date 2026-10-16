---
name: lcars-update
description: >-
  Bring an already-initialized LCARS repo up to the current schema without
  clobbering the captain's customizations. Creates any MISSING GitHub labels
  and adds any MISSING config.json keys with their defaults, while
  preserving every existing value (customized testCommand / model /
  comprehensionBudget) and leaving missions/ untouched. Also migrates a
  stale LCARS-generated copy-based vitest testCommand (the incompatible
  `.lcars-tests` copy-staging form) to the in-place equivalent, preserving
  its runner flags and any leading `cd`. Use when the user runs `lcars
  update`, asks to refresh / upgrade / sync an existing LCARS setup after
  pulling new versions, wants new labels/config keys added without
  re-initializing, or wants the repo's test systems set, probed, or repaired
  (TEST SYSTEMS OFFLINE).
---

# lcars update

`lcars update` brings a repo that was **already initialized** with `lcars init`
up to the current LCARS schema — the safe way to pick up new labels and config
keys after a `git pull`, without touching anything the captain has customized.

Where `lcars init` is first-time setup (and is itself idempotent), `update` only
fills GAPS. It never overwrites a value you set.

## When to use

The sentences below were part of this skill's frontmatter `description:` until
S276 moved them here. GitHub Copilot's CLI caps a skill description at 1024
characters and refused to load this skill over it; the description now keeps
the identity, the command forms and the `Use when…` trigger phrases that both
CLIs match on, and the detail it could not hold is relocated here verbatim.
Nothing was deleted.

Additionally carries the S146 test-readiness verbs — the ONE sanctioned
testCommand writers: `--test-command '<cmd>'` (manual set), `--probe-tests`
(one bounded suite run reporting pass/fail/zero-collected/timeout), and
`--fix-tests` (the one-click repair: detected suggestion or a read-only
discovery worker, then set + probe + verdict).

## What it does

**GITHUB** — creates any **missing** LCARS labels on the current repo, skipping
every label already present. (Same canonical label set as `lcars init`, shared
from `lcars-common.sh` so the two can never drift.)

**LOCAL** — adds any **missing** `config.json` keys with their defaults via the
merge-preserving writer. Existing values — a customized `testCommand`, `model`,
or `comprehensionBudget` — are kept exactly as they are. `missions/` is left
completely untouched.

**OUTPUT** — reports what was ADDED versus what was ALREADY PRESENT. On an
up-to-date repo it changes nothing and prints `nothing to update`.

## How to run it

Run the bundled script from the repo you want to update:

```bash
bash ~/.claude/skills/lcars-update/update.sh
```

Show its output to the user. It looks like:

```
  ✓ 1 label(s) created on github.com/owner/repo: lcars:ticket
    (15 already present)
  ✓ config keys added (defaults filled, existing values preserved): comprehensionBudget
  missions/ untouched.
```

…or, on a current repo:

```
  ✓ nothing to update — labels and config are already current.
  missions/ untouched.
```

## Test-readiness verbs (S146)

`lcars update` also carries the repo's test-systems repair surface. The shared
verdict (computed once, in `skills/lcars-init/lcars-common.sh`, and consulted
by `lcars status`, init/update readouts, and the viewscreen banner) reads:
**ready** (testCommand set, runner resolves) · **missing** (no command, a
detected candidate exists) · **broken** (command set, runner not found) ·
**unknown** (no command, nothing detectable — a *greenfield* repo, which is
expected status, never an alarm). These flags are the ONE sanctioned way
`testCommand` is ever written — plain `update` still never touches it:

```bash
bash ~/.claude/skills/lcars-update/update.sh --test-command 'npm test'  # manual set + re-verdict
bash ~/.claude/skills/lcars-update/update.sh --probe-tests   # one bounded run: pass/fail/zero-collected/timeout
bash ~/.claude/skills/lcars-update/update.sh --fix-tests     # one-click: suggest-or-discover → set → probe → verdict
```

- `--probe-tests` is bounded by `LCARS_PROBE_TIMEOUT` (default 120s) and is
  captain-triggered only. A run that collects ZERO tests is reported as its own
  honest outcome, never a pass.
- `--fix-tests` spawns a read-only discovery worker (the lcars-launch pattern,
  engine `$LCARS_WORKER_BIN` → config `workerBin` → claude) ONLY when detection
  has no candidate. A failed/garbage discovery leaves the config untouched; on
  a greenfield repo "nothing found" is the expected bootstrap outcome (exit 0).
  A probe failure after a set reports "SET BUT UNVERIFIED", never ready.
- The viewscreen's `POST /api/config/{test-command,probe-tests,fix-tests}`
  endpoints dispatch these exact verbs (the daemon never rewrites config in
  Python).

## Notes & failure modes

- **Not initialized** → if `.git/lcars/` doesn't exist, update refuses and tells
  the captain to run `lcars init` first. It does not silently initialize.
- **`gh` missing or no GitHub remote** → the local config check still runs; the
  GitHub label step is skipped with a warning. Re-run after installing `gh`.
- **Idempotent** → running it again on an up-to-date repo changes nothing.
- **Never clobbers** → any value already in `config.json` survives; only absent
  keys get filled. This is the same merge logic `lcars init` uses on re-run.

## Implementation

The logic lives in `update.sh` next to this file so it can be exercised
directly. The canonical label set and the merge-preserving config writer are
shared with `lcars init` via `skills/lcars-init/lcars-common.sh` (sourced by
both). Behaviour is covered by `tests/lcars-update.test.sh` in the LCARS repo
(run with `bash tests/run.sh`). The skill source lives in `skills/lcars-update/`
and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo copy,
not `~/.claude`. If you change `update.sh`, keep those tests green.
