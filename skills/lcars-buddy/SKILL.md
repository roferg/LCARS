---
name: lcars-buddy
description: Your LCARS ride-along buddy — a companion you keep with you in ANY repo while you use LCARS, useful from day one and at every point after. Run it anytime (it's read-only and safe) to get extra detail the normal surfaces don't show: where the LCARS source sits and its git state, whether the installed skills actually match that checkout, and a live snapshot of the current repo's Mission(s) — stage, status, and recent events. It rides shotgun while everything's going fine (situational awareness, "what's actually happening under the hood"), and escalates naturally into a live-debug partner the moment something's off — diagnosing and fixing the LCARS source under LCARS's own build contract (author in skills/, TDD, ./install.sh, fast scoped tests). Use when the captain runs `lcars buddy`, wants a closer look / more detail on what LCARS is doing, is keeping a buddy around while driving a Mission elsewhere, or hits something that needs debugging or fixing in LCARS from another repo.
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
- **When something's off** — it escalates, in the same session, into a live-debug
  partner: reproduce from the breadcrumb, find the cause in the LCARS source, and
  fix it under LCARS's own contract.

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

## 2. When it's time to debug — fix following the LCARS contract

When the captain flags something (or the brief surfaces a failing event), work the
problem against the **LCARS source** (use absolute paths under the reported
`LCARS REPO` — you can read and edit it even though the session's cwd is the other
repo):

1. **Reproduce from the breadcrumb.** Start from the failing event(s) in the
   CURRENT REPO section and the relevant skill script (`skills/lcars-run/run.sh`,
   `skills/lcars-init/init.sh`, …). Read before you theorize.
2. **Honour the build contract** (it's in `LCARS_REPO/CLAUDE.md` — read it):
   - Author every fix in `LCARS_REPO/skills/<name>/` — **never** in `~/.claude`.
   - **TDD**: write the failing `tests/<name>.test.sh` case first, then the fix.
   - Verify with the **FAST scoped** suite for that skill only
     (`bash tests/<name>.test.sh`). **Do NOT** run the heavy
     `tests/lcars-run.test.sh` or the full `tests/run.sh` to completion — they are
     slow, billable, and have hung whole sessions.
   - After any change, run **`./install.sh`** in `LCARS_REPO` so the fix is the
     code that actually runs, then re-collect the brief / re-drive to confirm.
3. **Mind the protected machinery.** Don't loosen a gate to make a stall go away,
   don't weaken the adversarial Test-Writer→Implementer split or the immutable
   test hashes, and keep external CLIs env-injected/stubbable. When unsure whether
   a change is in-scope, ask the captain rather than guessing.
4. **Commit only when asked.** LCARS work goes on a feature branch off `main`
   (never commit to `main`). End commit bodies per `CLAUDE.md`. No PR unless the
   captain asks.

## What this skill is NOT

It does **not** drive a Mission, file issues, or run a worker CLI — it is a
read-only collector plus this orientation. To run/board a Mission use `lcars` /
`lcars run` / `lcars viewscreen`. `lcars buddy` is the "ride along, get the extra
detail, and help me fix LCARS if it comes to that" companion.
