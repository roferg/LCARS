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

A unittest run with no genuine passes (zero collected, only skips, or only
expected failures) is inconclusive, never verified. A genuine pass alongside
skips or expected failures still qualifies.

Also carries the S309 engine verbs — `--engine <claude|copilot>` and
`--model '<model>'` — the sanctioned writers for the two keys that say which
engine this repo runs on and what model its workers are spawned with.

## What it does

**GITHUB** — creates any **missing** LCARS labels on the current repo, skipping
every label already present. (Same canonical label set as `lcars init`, shared
from `lcars-common.sh` so the two can never drift.)

**LOCAL** — adds any **missing** `config.json` keys with their defaults via the
merge-preserving writer. Existing values — a customized `testCommand`, `model`,
`comprehensionBudget` or `gateTimeout` — are kept exactly as they are.
`missions/` is left completely untouched.

`gateTimeout` (seconds) is the repo's own proof-gate timeout: how long an
Implement proof leg may run its tests before the harness terminates it as a
hang. `null` means the 500s default. The probe window also defaults to 500s.
A slow passing probe or a timed-out probe seeds a provisional budget (twice
the measurement or exceeded bound, rounded up to 30s, capped at 3600s), only
when no value is already recorded. A timeout states only that the suite
exceeded the probe bound; it never claims a measured duration or a passing
suite. `LCARS_GATE_TIMEOUT` in the environment still overrides the record.
Set the record with `lcars update --gate-timeout <seconds>` (an integer from
1 to 3600); invalid input is refused before writing. No file editing is needed.
The proof gate also accepts valid JSON whitespace around `gateTimeout`'s
colon (including separate key, colon, and value lines) and JSON-escaped
spellings of that key, such as `"gate\u0054imeout"`.

Settings writers parse complete JSON values, including multiline objects,
and validate read-back before atomically replacing the file. Invalid JSON
is an explicit failure and leaves the original settings untouched.

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

- `--probe-tests` is bounded by `LCARS_PROBE_TIMEOUT` (default 500s) and is
  captain-triggered only. A run that collects ZERO tests is reported as its own
  honest outcome, never a pass.
- `--gate-timeout 700` records a 700-second gate budget without probing or
  changing other settings. Use it alone; missing, non-integer, zero, negative,
  leading-zero, or above-3600 values are usage errors.
- `--fix-tests` spawns a read-only discovery worker (the lcars-launch pattern,
  engine `$LCARS_WORKER_BIN` → config `workerBin` → claude) ONLY when detection
  has no candidate. A failed/garbage discovery leaves the config untouched; on
  a greenfield repo "nothing found" is the expected bootstrap outcome (exit 0).
  A probe failure after a set reports "SET BUT UNVERIFIED", never ready.
- The viewscreen's `POST /api/config/{test-command,probe-tests,fix-tests}`
  endpoints dispatch these exact verbs (the daemon never rewrites config in
  Python).

## Engine verbs (S309)

`lcars init` seeds `model` from the engine the repo or the run **records** (an
ECH run's `.git/lcars/autopilot.json` `engine`, else the config's `workerBin`
pin, else the engine installed here). When nothing records one, the seed is a
choice and init says so out loud. These two verbs are how a wrong record is
corrected — by a verb, not by hand-editing `.git/lcars/config.json`:

```bash
bash ~/.claude/skills/lcars-update/update.sh --engine copilot          # pin + model follow
bash ~/.claude/skills/lcars-update/update.sh --model 'claude-opus-5.5' # model only, verbatim
bash ~/.claude/skills/lcars-update/update.sh --engine copilot --model 'claude-sonnet-4.6'
```

- `--engine` writes **`workerBin`** (the repo's engine pin) and moves **`model`**
  to the one that engine actually runs — `claude` → `claude-sonnet`,
  `copilot` → `claude-opus-5.5` (`lcars_default_model_for_engine`, which mirrors
  run.sh's `alias_for_tier` policy; that remains the policy's one home).
- `--model` sets `model` verbatim and never touches the pin. Given with
  `--engine`, the explicit model **wins** over the engine's default.
- They change **only** those keys. Both go through the targeted single-key
  writers, not the schema merge, so every other byte of the captain's config —
  a customised `testCommand` included — survives unchanged. A verb invocation
  also syncs no labels and refreshes no version stamp.
- An unknown engine name, an **empty or missing `--engine`**, or an empty model
  is **refused before anything is written**, non-zero, naming the flag that was
  wrong; `config.json` is left untouched. In particular
  `lcars update --engine "$E" --model "$M"` with `$E` unset is a REFUSAL, never
  an exit-0 that writes the model and silently drops the engine — a caller must
  not read a tick for a record that was not made. A flag-shaped value
  (`--engine --model 'x'`) counts as a missing one and is reported against
  `--engine`, not against the token that followed it. **Both flags read it the
  same way**: `--model --engine` (what `--model $M --engine $E` collapses to
  when both are unset) is a refusal too, never an exit-0 that writes the
  literal string `--engine` as the model. Every missing value is named before
  any value is judged, so `--model --engine zzz` reports the empty `--model`
  rather than the stray `zzz`.
- An engine that is not installed here can still be **recorded** (a record is
  not a claim about this laptop); update says so in one line.
- `workerBin` is now listed in update's desired schema, so a plain
  `lcars update` **preserves** the pin instead of deleting it as an unknown key.

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
