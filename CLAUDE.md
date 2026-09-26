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
4. **Verify.** Run the **fast scoped** suite for the skill you touched
   (`bash tests/<name>.test.sh`). The full `bash tests/run.sh` — all suites green
   — is **`ship-it`'s merge gate**, not a session's or a fix's inner loop: it is
   slow, billable, and has hung whole sessions. Never run it (or the heavy
   `tests/lcars-run.test.sh`) to completion mid-session.
   The **harness itself is now tested**: `bash tests/harness.test.sh` asserts
   that suites TERMINATE from a pty with stdin genuinely open, and guards the
   hang class that made a suite block on inherited stdin (S208). `tests/run.sh`
   now invokes every suite with stdin closed. That removes one known cause of
   the hangs — it does NOT yet make the full run trustworthy; nobody has
   completed one, so "all suites green" is still an unverified claim (S209
   measures it). Run a single suite the safe way — `bash tests/<name>.test.sh`
   from a terminal is now fine; cage anything unattended with
   `python3 tests/lib/cage.py <secs> …`, which reports ELAPSED and kills
   the whole process group.
5. **Commit.** The skill source, its test, and any doc updates are all tracked.
   Work happens on a branch cut from `main` — **`feat/<round>`** for a round or
   session, **`fix/<slug>`** for a fix — and **never on `main` itself**. End the
   commit body with a `Co-Authored-By: <model that wrote it>
   <noreply@anthropic.com>` trailer, plus a
   `Claude-Session: https://claude.ai/code/session_…` line when the harness
   provides one.

A skill is not "done" until its source and test are committed in this repo.
Files left only in `~/.claude/` do not count — they don't ship.

### Orchestrated fixes and sessions

Sessions and fixes are not run freehand: one orchestrator spawns an implementor
sub-agent (TDD) and a **fresh** tester at a declared proof surface, loops fixes
with a regression guard, and **stops hard at three rounds**. Those rules live in
ONE file — `skills/lcars-buddy/ORCHESTRATION.md`, installed (and readable from
any cwd) at `~/.claude/skills/lcars-buddy/ORCHESTRATION.md`. It is shared by
`lcars buddy`, `run-session` and `night-watch` so the loop cannot drift between
them, and it **wins over any restatement**. Read it before orchestrating
anything; this section points at it rather than repeating it.

**Versioning contract.** Every PR into `main` bumps the root `VERSION` file
(`YYYY.M.N` — year, month with no leading zero, per-month counter) and adds a
matching newest-first `CHANGELOG.md` entry summarized from the PR body. `lcars
init` stamps a repo's `lcarsVersion`, `lcars update` refreshes it, and `lcars
version` reports the running/source/stamp picture — an unbumped `main` reads as
drift.

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
9. `lcars run`   — Implement stage: waves → one unified TDD worker per ticket,
   proven by post-hoc harness gates (see #13).  ✅ built
10. `lcars run`  — Verify stage + `lcars approve` / `lcars feedback`.  ✅ built
11. `lcars respond` — Async human gate: when a stage escalates (e.g. Research
    >20, Validate scope change), persist the question + apply
    `lcars:awaiting-human` so the board shows it; `lcars respond <id>` answers
    it later. Makes escalations walk-away instead of synchronous. Also owns the
    in-progress-stage label so a stuck card shows in the right column: today
    `lcars run` jumps a mission align→validate and never applies `lcars:research`,
    so the Research column is always empty. This stage must label the card with
    the stage actually running (e.g. `lcars:research`) while it is in flight, so
    an escalated mission reads as "in Research, awaiting me" rather than "Align".
    ✅ built
12. `lcars run`   — Per-stage isolation: move every headless stage (Research,
    Validate, Plan, Plan Review, Implement) into a cold subprocess worker spawned
    via `$LCARS_WORKER_BIN` (defaults to the host CLI), prompt assembled by
    `run.sh` from artifact paths alone; decision-rich artifacts. Closes BUG-004,
    lays the CLI-agnostic groundwork for BUG-003.  ✅ built
13. `lcars run`   — Implement guardrails: the adversarial Test-Writer/Implementer
    split is retired for ONE unified TDD worker, proven by deterministic post-hoc
    gates — flip-flop (tests fail on parent, pass on tip) + declared-edits
    contract + a quality floor; a gate rejection bounces to a fresh worker (≤3
    sessions) then parks awaiting-human, never a stage-stop.  ✅ built (S132–135)
14. `lcars run`   — Auto-advance + notifications: token-free bash driver loops the
    per-stage advances; `--step` for one; fires `$LCARS_NOTIFY` at every human
    gate (local banner default, ntfy/Pushover opt-in). **Full unattended loop.**
    ✅ built
15. `lcars`       — Human surface: `lcars` (do-the-right-thing) + `lcars answer`
    (one inbox absorbing respond/approve/feedback) + the read-only board; no
    mission-id juggling. Old verbs stay as power aliases.  ✅ built
16. `lcars log`   — Mission Log: bugs against an active mission (fast-track entry;
    the grounded flow lands in #18).  ✅ built
17. Copilot enablement — **RESEARCH session**: run the capability spike, then
    propose a phased plan of incremental Copilot build sessions (18+) behind
    `$LCARS_WORKER_BIN` rather than one big-bang. **DEFERRED** (closes BUG-003);
    start with the spike.
18. `lcars log`   — Mission-log grounding: a logged bug enters at **Research in a
    grounding mode** — a bounded, read-only worker anchors the free-form symptom
    to the parent Mission's *existing* code (its PRD, plan, delivered diff) and
    forbids a duplicate fix — then flows the full pipeline to Verify (only Align
    skipped), instead of fast-tracking straight to Plan. Closes the "green-but-
    wrong decoy" class (a fix that builds a parallel dead control beside the real
    one). Viewscreen + CLI show the Research + Validate Stages and their models on
    the same generic card. See `CONTEXT.md` → *Grounding*.  ✅ built

Detailed per-session prompts live in `.dev/bootstrap.md` (author-local, not
shipped). When you finish a skill, tick it off here.

## Mission state lives in `.git/lcars/`

At runtime, skills store all per-repo mission state under `.git/lcars/`
(config + `missions/`). It's inside `.git/`, so git never tracks it and the
working tree of the *target* repo stays clean. Do not add it to `.gitignore`
of target repos and do not commit it.
