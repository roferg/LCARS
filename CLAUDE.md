# LCARS — repo guide for Claude Code sessions

This repo **is** LCARS: a reusable AI harness that drives a human idea to a
merged PR. See `vision.md` for the full design and `CONTEXT.md` for the domain
glossary — read both before doing substantial work.

This file is the contract for *building* LCARS. Follow it on every session.

## The golden rule: skills live in this repo, not in `~/.claude`

LCARS ships as a set of Claude Code skills (`lcars init`, `lcars file`, …).
For others to clone the repo, install the skills, and receive updates via
`git pull`, **the skill source must live in this repo** — never authored
directly under `~/.claude/skills/`.

> ⚠️ The bootstrap prompts in `.dev/bootstrap.md` say things like
> "implement the skill at `~/.claude/skills/<name>/SKILL.md`". **Ignore that
> location.** Author the skill in `skills/<name>/` here, then run
> `./install.sh`, which symlinks it into `~/.claude/skills/`. The symlink is
> what makes `git pull` deliver updates with no re-install.

## Repo layout

```
skills/<name>/        Skill source — one dir per `lcars` command.
  SKILL.md              Frontmatter (name, description) + instructions.
  <name>.sh / init.sh   The executable logic the skill runs (keeps it testable).
tests/                Tracked test suites. One <name>.test.sh per skill.
  run.sh                Runs every *.test.sh.
install.sh            Symlinks skills/* into ~/.claude/skills/ (idempotent).
vision.md             The product vision. Source of truth for behaviour.
CONTEXT.md            Domain glossary. Use this language in code and docs.
docs/                 Rendered vision / static assets.
.dev/                 GIT-IGNORED. Author-local notes (bootstrap prompts). Do
                      not put anything others need to clone in here.
```

Anything others must be able to clone goes in a **tracked** path. `.dev/` is
ignored — never put skills, tests, installers, or docs there.

## Workflow for adding or changing a skill

1. **Author in the repo.** Create/edit `skills/<name>/SKILL.md` and its script.
2. **TDD it.** Each skill has `tests/<name>.test.sh`. Write the failing test
   first, then make it pass (see `tdd` skill). Keep logic in a bundled shell
   script (not buried in prose) so it stays testable. Make the script take its
   external dependencies via env vars (e.g. `LCARS_CLAUDE_BIN`, `LCARS_GH_BIN`)
   so tests can stub them — see `skills/lcars-init/init.sh` for the pattern.
3. **Install.** Run `./install.sh` to (re)link skills into `~/.claude/skills/`.
4. **Verify.** Run `bash tests/run.sh` — all suites must be green.
5. **Commit.** The skill source, its test, and any doc updates are all tracked.

A skill is not "done" until its source and test are committed in this repo.
Files left only in `~/.claude/` do not count — they don't ship.

## Build order (from `.dev/bootstrap.md`)

Skills are built in this sequence. Status:

1. `lcars init`   — Setup: local config + GitHub labels.  ✅ built
2. `lcars file`   — Entry: idea → Align → PRD on disk.  ✅ built
3. `lcars status` — Read/display active mission state.  ✅ built
4. `lcars run`   — Research stage: PRD → 0–20 questions → stateless agents.  ✅ built
5. `lcars run`   — Validate stage: synthesise findings → plan, scope-change gate.  ✅ built
6. `lcars run`   — Plan stage: validated-plan → vertical-slice tickets in plan.json.  ✅ built
7. `lcars run`   — Plan Review stage: fresh reviewer audits tickets → approve/loop/escalate.  ✅ built
8. `lcars run`   — Schedule stage: dependency graph → waves, create sub-issues.  ✅ built
9–10. `lcars run` — Implement, Verify + PR.
11. `lcars respond` — Async human gate: when a stage escalates (e.g. Research
    >20, Validate scope change), persist the question + apply
    `lcars:awaiting-human` so the board shows it; `lcars respond <id>` answers
    it later. Makes escalations walk-away instead of synchronous. Also owns the
    in-progress-stage label so a stuck card shows in the right column: today
    `lcars run` jumps a mission align→validate and never applies `lcars:research`,
    so the Research column is always empty. This stage must label the card with
    the stage actually running (e.g. `lcars:research`) while it is in flight, so
    an escalated mission reads as "in Research, awaiting me" rather than "Align".
12. `lcars run`   — Auto-advance: drive stages by default; `--step` for one.
13. `lcars log`   — Mission Log: bugs against an active mission.

Detailed per-session prompts live in `.dev/bootstrap.md` (author-local, not
shipped). When you finish a skill, tick it off here.

## Mission state lives in `.git/lcars/`

At runtime, skills store all per-repo mission state under `.git/lcars/`
(config + `missions/`). It's inside `.git/`, so git never tracks it and the
working tree of the *target* repo stays clean. Do not add it to `.gitignore`
of target repos and do not commit it.
