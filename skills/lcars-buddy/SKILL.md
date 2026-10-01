---
name: lcars-buddy
description: Your LCARS ride-along buddy — a companion you keep with you in ANY repo while you use LCARS, useful from day one and at every point after. Run it anytime (it's read-only and safe) to get extra detail the normal surfaces don't show: where the LCARS source sits and its git state, whether the installed skills actually match that checkout, and a live snapshot of the current repo's Mission(s) — stage, status, and recent events. It rides shotgun while everything's going fine (situational awareness, "what's actually happening under the hood"), and escalates naturally into a live-debug partner the moment something's off — diagnosing and fixing the LCARS source under LCARS's own build contract (author in skills/, TDD, ./install.sh, fast scoped tests). It also has an AUTOPILOT mode: say "run it for me <spec>" and it runs LCARS FOR you — one alignment round, then it files, drives, verifies and lands each milestone through LCARS's own verbs, keeping durable state in .git/lcars/autopilot.json and contacting you only for a product call, a scope change, a standing-rule conflict, or an LCARS bug with no workaround (see AUTOPILOT.md). Use when the captain runs `lcars buddy`, wants a closer look / more detail on what LCARS is doing, is keeping a buddy around while driving a Mission elsewhere, says "run it for me" / "drive this for me" / "autopilot" / "run while I sleep" / "continue" on an autopilot run, or hits something that needs debugging or fixing in LCARS from another repo.
---

# lcars buddy

`lcars buddy` is the companion you **bring with you and keep running** while you
use LCARS in your other repos. It's not a break-glass tool — it's a ride-along
that's useful from the very first mission and stays useful as things evolve:

- **While everything's fine** — it rides shotgun. Run it whenever you want extra
  detail the normal surfaces (`lcars status`, the viewscreen) don't show: exactly
  where the LCARS source lives and what state it's in, whether the code you'd edit
  is the code that's running, and what each Mission is *actually* doing event by
  event. Pure situational awareness. It's **read-only and safe to run as often as
  you like.**
- **When something's off** — it escalates into the **orchestrator of one fix**:
  brief the captain, cut a `fix/<slug>` branch, spawn an implementor on TDD and a
  fresh tester, and land the cure under LCARS's own contract — the same loop a
  session runs (§ 2).

It works from anywhere because the skill is installed globally (symlinked into
`~/.claude/skills/` by `install.sh`).

## 1. Run the diagnostic collector and show it verbatim

```bash
bash ~/.claude/skills/lcars-buddy/buddy.sh
```

If LCARS lives somewhere non-standard (auto-resolve through the install symlink
should normally find it), pass it explicitly:

```bash
LCARS_REPO=~/Projects/LCARS bash ~/.claude/skills/lcars-buddy/buddy.sh
```

The brief reports, in order:
- **LCARS REPO** — where the source lives + its branch / HEAD / dirty state / recent
  commits. This is the code you can read and (when needed) fix.
- **INSTALL SYNC** — whether the installed skills point at *that* checkout. Worth a
  glance every time: if it says **STALE**, you've been editing one clone while a
  different one runs — surface it and offer to run `./install.sh`. (Even when all
  is well, this is the answer to "am I looking at the right code?")
- **CURRENT REPO** — the Mission(s) in *this* repo: config (`testCommand`,
  `worktreeSetupCommand`, model, engine), each mission's stage + paused /
  awaiting-human status, and the **last events**. In the healthy case this is your
  extra-detail view; when something breaks it's the breadcrumb (e.g.
  `vitest: not found`, `worktree_provision_failed`) you start the debug from.

After showing the brief, give the captain a short read of it — what's notable,
what each mission is doing, anything worth watching — even if nothing's wrong.
That ride-along read is the point in the healthy case.

## 2. When it's time to fix — run it as an orchestrated session

A fix to LCARS is run the **same way a session is run**: you become the
**orchestrator**, and you write **no production code yourself**. The rules are in
ONE file, shared with `run-session` and `night-watch` so the three cannot drift:

```
~/.claude/skills/lcars-buddy/ORCHESTRATION.md
```

**Read it now, before anything else.** It is the source; everything below is the
buddy-shaped wrapper around it. Where the two appear to disagree, that file wins.

`$REPO` below is the **LCARS REPO** the brief reported — the checkout the install
symlinks actually point at. That is where the fix lands, always: never a second
clone, never `~/.claude`.

### a. BRIEF FIRST, then wait for the go

Before touching anything, give the captain a short briefing in plain English —
the same shape `run-session` uses for a session, but for one defect:

1. **The breadcrumb** — the failing event(s) from the CURRENT REPO section, or
   what the captain flagged, quoted.
2. **The suspected seam** — `file:line` in `$REPO`, having *read* it. Read before
   you theorize.
3. **The proof surface for THIS fix** — what must be real to prove it, and what a
   fake there could not see. Usually: re-collect the brief
   (`bash $REPO/skills/lcars-buddy/buddy.sh`) or re-drive the failing verb against
   the repo that produced the breadcrumb. Apply ORCHESTRATION.md § Pre-flight's
   proof-surface check: **if the fix changes a layer its harness fakes, say so and
   do not start.**
4. **The cost** — sub-agent tokens, and **worker spend zero** unless the defect
   lives inside a worker path. If it does, **RECOMMEND the live leg and ask** —
   never spend it silently, never skip it silently (ORCHESTRATION.md
   § Guardrails).
5. **The branch** — `fix/<slug>`, cut from `main`.

Then **ask and wait**. "y / fix it" proceeds; anything else is feedback.

### b. PRE-FLIGHT — and buddy's own refusal

Run ORCHESTRATION.md § Pre-flight (proof surface, infer-vs-record, PATH-shim
pinning for both CLIs, engine auth, **never the full suite**). Then buddy's own
rule, because the captain is usually mid-round in that very checkout:

**`$REPO` must be clean and on `main`.** Check
`git -C "$REPO" status --porcelain` (empty) and
`git -C "$REPO" rev-parse --abbrev-ref HEAD` (`main`). If either fails, **REFUSE
and stop**, with exactly this sentence:

> LCARS at \<path\> is \<dirty|on \<branch\>\> — finish or stash that round first;
> buddy will not stack a fix onto it.

A fix stacked onto someone's in-flight round is unreviewable and unshippable
separately. On a clean `main`:

```bash
git -C "$REPO" switch -c fix/<slug>
```

### c. THE LOOP — per ORCHESTRATION.md § The loop

Implementor sub-agent (TDD) → **fresh** tester at the proof surface → fix rounds
with the regression guard → **hard stop at three rounds** → teardown → commit →
readout. Buddy-specific instructions for the sub-agents:

- **Implementor:** author only under `$REPO/skills/` and `$REPO/tests/` (never
  `~/.claude`); failing `tests/<name>.test.sh` case FIRST; verify with the **fast
  scoped** `bash tests/<name>.test.sh` only — **not** `tests/lcars-run.test.sh`,
  **not** the full `tests/run.sh`; then `./install.sh` in `$REPO` so the fix is
  the code that actually runs.
- **Tester (fresh, never saw the implementor's reasoning):** from the foreign repo,
  re-collect the brief / re-drive the failing verb and judge from the outside —
  the breadcrumb must be gone and nothing else changed. It edits no source and no
  tests, and logs every artifact for teardown.
- **Mind the protected machinery.** Don't loosen a gate to make a stall go away,
  don't weaken the Implement proof gates (the fail-on-parent/pass-on-tip
  flip-flop, the declared test-edits contract, the quality floor) or the
  ≤3-sessions-then-park bound, and keep external CLIs env-injected/stubbable. An
  invariant touch is a **STOP and report**, not a judgement call.

### d. COMMIT, then READ OUT

Commit on `fix/<slug>` with the trailer from ORCHESTRATION.md § Build contract
(`Co-Authored-By:` for the model that wrote it, plus the `Claude-Session:` line
when the harness gives one). **No PR.** Then read out in chat per
ORCHESTRATION.md § Readout — unit + tester verdict, rounds with the
own/inherited/fix-loop split, **both** costs, what the proof was blind to,
ledgered items — and add one line:

> ship it with `ship-it` when you are ready.

## 3. When you want it run FOR you — the autopilot

The third thing buddy does is **run LCARS for the captain while he is away**.

**Trigger phrases** (any of these, with or without a spec):

> "run it for me", "run it for me &lt;spec&gt;", "drive this for me", "autopilot",
> "take this and build it", "run while I sleep", "keep going and wake me if you
> need me", "continue" (resuming an autopilot run)

**What happens.** You become the orchestrator of his *build* (not of a fix):
**ONE** round of 3–5 questions, then you file, drive, verify and land each
milestone in scope, and he hears from you only for a product call, a scope
change, a standing-rule conflict, or an LCARS bug with no workaround.

**The full playbook is ONE file** — read it before you ask him anything:

```
~/.claude/skills/lcars-buddy/AUTOPILOT.md
```

The token-free driver that sequences it (and spends nothing) sits beside it:

```bash
bash ~/.claude/skills/lcars-buddy/autopilot.sh next      # the ONE next step
bash ~/.claude/skills/lcars-buddy/autopilot.sh status    # the one screen
bash ~/.claude/skills/lcars-buddy/autopilot.sh playbook  # action → AUTOPILOT.md heading
```

### The first 20 minutes

1. Run § 1's collector and read the brief — where LCARS lives, whether the
   install is in sync, what is already in this repo.
2. **Repeat the ask back** in plain terms and get it confirmed before acting.
3. Read the spec, then check what the harness can do (engine flags, the
   holodeck, Number One) **before** asking, so no question is wasted.
4. **One batch of 3–5 questions**, each with a recommended option: scope, live
   targets, where it deploys, what to do if LCARS itself breaks — plus the
   captain-only steps (tokens, secrets, SSO, renames) and the
   pre-authorisations. AUTOPILOT.md §§ 1–2 has the exact list.
5. `autopilot.sh init --spec … --scope …`, record every answer, then
   `autopilot.sh heartbeat install`. **Durable state is
   `.git/lcars/autopilot.json`, never the transcript** — after a context
   compaction, re-read it first.

Then loop on `autopilot.sh next` and follow the heading it names.

**It never edits LCARS.** An LCARS bug is ledgered and worked around with
another verb, or it becomes a question for the captain. If he wants LCARS
*fixed*, that is § 2 above.

## What this skill is NOT

It does **not** write product code and it never merges by hand. It is three
things: the **read-only collector** of §1, the **orchestrator of one fix** in
§2 — which spawns sub-agents and commits to a `fix/<slug>` branch, but never
opens a PR and never merges — and the **autopilot** of §3, which drives the
captain's build through LCARS's own verbs and stops at every gate LCARS refuses.
To board a Mission by hand use `lcars` / `lcars run` / `lcars viewscreen`; to
land a fix use `ship-it`.
