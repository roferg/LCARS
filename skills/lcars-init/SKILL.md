---
name: lcars-init
description: Initialize a repo for LCARS mission-based development. Scaffolds .git/lcars/ (config + missions dir), detects CONTEXT.md, verifies the Claude CLI, and creates the LCARS GitHub label set. Use when the user runs `lcars init`, asks to set up / bootstrap LCARS in a repo, or wants to prepare a repo for LCARS missions.
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

That is **14 labels** total.

## How to run it

Run the bundled script from the repo you want to initialize:

```bash
bash ~/.claude/skills/lcars-init/init.sh
```

The script handles everything above and prints a readiness summary. Show its
output to the user. It looks like:

```
  ✓ .git/lcars/ created
  ✓ config.json written  (model: claude-sonnet, context: CONTEXT.md)
  ✓ Claude CLI verified  (2.0.44 (Claude Code))
  ✓ 14 labels created on github.com/owner/repo
  LCARS ready — run `lcars file` to start your first Mission.
```

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
with `bash tests/run.sh`). The skill source lives in `skills/lcars-init/` in the
repo and is symlinked into `~/.claude/skills/` by `./install.sh`; edit the repo
copy, not `~/.claude`. If you change `init.sh`, keep those tests green.
