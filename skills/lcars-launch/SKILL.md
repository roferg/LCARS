---
name: lcars-launch
description: Get an LCARS Mission's app running locally so the captain can view it during Verify. `lcars launch <mission> [hint]` checks the mission's branch out into a disposable DETACHED git worktree, spawns a `launch`-role cold worker that DISCOVERS how to start the app (it never starts it itself), then the skill launches that command detached — owning the whole process group — writes a launch.json record both the CLI and the viewscreen daemon read, and prints an LCARS-voice readout naming the target, URL, and how to stop it. `lcars launch <mission> --stop` kills the process group and prunes the worktree. `lcars launch --main [hint]` deploys the LOCAL default-branch HEAD (whatever is already merged — no fetch) through the same pipeline, with `--main --stop` to tear it down. Failures are plain English, never a raw stack trace. Use when the captain runs `lcars launch`, asks to run / open / preview / see a mission's app while reviewing it, wants to deploy/run local main, or wants to stop a launched app.
---

# lcars launch

`lcars launch <mission> [hint]` gets a Mission's app **running locally** so the
captain can look at it during **Verify** — the pre-ship human checkpoint. It is
read-only against the captain's own checkout: the mission's code is checked out
into a *separate, disposable* worktree, so nothing about the working tree the
captain is sitting on changes.

```bash
lcars launch lcars-20260705-001                 # run the mission's app
lcars launch lcars-20260705-001 "the game"       # a hint steers WHICH app runs
lcars launch lcars-20260705-001 --stop           # stop it + clean up

lcars launch --main                              # deploy the LOCAL main HEAD
lcars launch --main "the game"                    # same, with a WHICH-app hint
lcars launch --main --stop                        # stop the main deploy + clean up
```

## `--main` — deploy what's already merged

`lcars launch --main [hint]` runs the **local default-branch HEAD** — whatever is
already merged on this machine — through the *exact same* launch pipeline a
mission uses. It is a target-resolution seam, not new machinery: nothing about the
discover→launch-detached→settle→stop flow changes.

- **No network, ever.** The SHA is a **local** `rev-parse` — there is no `fetch`
  or `pull`. You deploy the HEAD you have, not the remote's.
- **Which branch.** `mainBranch` in `.git/lcars/config.json` if set, else local
  `main`, else local `master`; otherwise a legible refusal asking you to set
  `mainBranch`.
- **State + worktree.** Records live in `.git/lcars/main/` (no mission dir), and
  the disposable DETACHED worktree lands at the reserved `@main` key of the deploy
  root — `<repo-parent>/.lcars-launch/<repo>/@main`. `@main` is reserved — a mission literally named
  `@main` is rejected, and `--main` refuses a mission id (`lcars launch --main m1`
  is an error; run one form or the other).
- **Record.** The `running` `launch.json` adds `branch` and a short `sha` on the
  main path only; the readout names `<branch> @ <sha>` and the stand-down hint is
  `lcars launch --main --stop`. The per-mission `launch.json` is unchanged.

You (Claude) generally don't need to do any natural-language work here — hand the
captain's words straight to `launch.sh`. If the captain named *which* app or a
directory (a repo can host more than one), pass that as the free-form **hint**.

## What it does

1. **Resolve** the mission → its branch (`state.json.branch`) → the branch-tip
   SHA.
2. **Check out** that SHA into a **disposable DETACHED worktree** at
   `<repo-parent>/.lcars-launch/<repo>/<mission>` — a **sibling of the repo**, see
   *Where a deploy lives* below. *Detached is deliberate:* a normal branch
   checkout **holds** the branch ref and would block the Implement replay gate
   from landing fixes on that branch. A detached checkout gives the same code
   **without** holding the ref. Idempotent — an existing worktree is reused.
3. **Discover, don't run.** Spawn a `launch`-role cold worker (same engine as the
   mission — its `state.json.workerBin`, or `$LCARS_WORKER_BIN`) that *inspects*
   the checkout and writes `launch.json` describing how to start the app. The
   worker is fenced to **read + shell only** (`Read,Grep,Glob,Bash` /
   `view,grep,glob,bash`) — no Write/Edit — so it cannot modify the checkout, and
   it is told **not to start anything itself**.
4. **Launch it (the skill does this, not the worker).** The skill reads
   `launch.json` and runs the discovered `command` in `<worktree>/<cwd>`,
   **detached as its own process group**, capturing output to
   `.git/lcars/missions/<mission>/launch.log`. This split is the fixed
   architecture: headless Copilot denies backgrounding (`&`/pipes) even with
   `--allow-all-tools`, so a worker can't reliably detach a dev server — and
   skill-owned launching yields one clean, capturable **process-group id** for a
   reliable `--stop` (and daemon tracking). It's uniform across claude/copilot.
5. **Report.** On success it prints an LCARS readout (target / URL / how to stop)
   and records the final `launch.json` with `status: "running"`.

`--stop` kills the whole **process group** (so a dev server's child processes die
too), flips `status` to `stopped`, and prunes the launch worktree. It is
idempotent, and a fresh `lcars launch` after a stop works again.

## The hint matters

A repo's root often does **not** launch the app the captain wants — e.g. a root
`package.json` that only starts an Electron editor while the real game lives in a
subdirectory with its own dev server, unreachable from the root scripts. Pass the
captain's hint (`"the game"`, `"the marketing site"`, a directory name) so the
inspector picks the **right** target.

## `launch.json` — the record both the CLI and the daemon read

Written to `.git/lcars/missions/<mission>/launch.json`:

```json
{
  "status":    "ready|running|failed|stopped",
  "target":    "example-game dev server",
  "url":       "http://localhost:5173",
  "howToStop": "Ctrl-C in the window, or lcars launch <id> --stop",
  "command":   "npm run dev",
  "cwd":       "example-game",
  "worktree":  "/abs/<repo-parent>/.lcars-launch/<repo>/<id>",
  "log":       "/abs/.git/lcars/missions/<id>/launch.log",
  "startedAt": "2026-07-05T12:00:00Z",
  "pid":       12345,
  "pgid":      12345,
  "message":   "plain-English text, present on failed/stopped"
}
```

The **worker** writes the discovery fields (`target`, `command`, `cwd`, `url`,
`howToStop`, `status: ready|failed`, and `message` on failure). The **skill**
augments it with `pid`, `pgid`, `log`, `startedAt`, `worktree` and flips
`status` `ready → running` (or `→ failed` on instant death). The viewscreen
daemon (a later session) reads `status`, `target`, `url`, and `message`, so those
always persist.

## Where a deploy lives — beside the repo, never inside `.git/`

The disposable checkout is cut at **`<repo-parent>/.lcars-launch/<repo-name>/<key>`**
(`<key>` = the mission id, or `@main`) — a *sibling* of the repo. Two things make
that the only workable shape:

- **Not inside `.git/`.** Vite's default `server.watch.ignored` contains
  `**/.git/**`, so a deploy under `.git/lcars/launch/…` had its file watcher
  switched off permanently: the dev server booted, served pages, and then never
  saw another change — no HMR, no `import.meta.glob` re-evaluation, no re-read of
  data files. Every watcher-based tool (webpack, nodemon, Tailwind JIT,
  `tsc --watch`) failed identically. Measured on the same commit with one file
  added while the server ran: inside `.git/` the served glob stayed at **1** entry
  indefinitely; outside it reached **2** within 5 seconds. That made a deploy
  *misleading*, not merely limited — a correct fix that reads changed files back
  read as still broken.
- **Not inside the repo either.** A full second copy of the repo *within* the repo
  is picked up by the parent's own test globs and watchers (vitest's default
  `include` would collect the deploy's test files as if they were the captain's);
  `.git/info/exclude` does not stop a glob.

The root is keyed by the repo's **canonical** parent + basename, so two repos that
share a basename under different parents can never fold together. **State does not
move**: `launch.json`, `launch-discovery.json`, `launch.log` and every mission
artifact stay under `.git/lcars` — only the checkout relocates. A deploy still
sitting at the pre-S167 `.git/lcars/launch/<key>` path is **migrated** (removed +
pruned) on the next launch or `--stop`, so no mission ends up with two checkouts
or a stale `git worktree list` row. If the repo's parent directory isn't writable,
`lcars launch` refuses in plain English (`$LCARS_LAUNCH_ROOT` overrides the root).

## Failure is always plain English

Never a raw stack trace, and never a bare command as the primary line (UX-33):

- **Worker can't figure out how to run it** → it writes `status: "failed"` with a
  `message` naming what's missing (no dev script, ambiguous entry point). The
  skill surfaces that message and exits non-zero, launching nothing.
- **The app exits immediately** → `status: "failed"`, message
  `"the app exited immediately — <tail of the log>"`.
- **Unknown mission / no branch yet** → a clean refusal naming the problem (run
  the mission first).
- **The deploy root would land inside a `.git/`** → refused either way (watchers
  ignore `.git`), but the message names the cause that actually applies: if
  `$LCARS_LAUNCH_ROOT` is what put it there it says so and tells you to repoint or
  unset it; if the root was *derived* from a checkout that itself lives under a
  `.git/` it tells you to run from the repo's own checkout. Naming the wrong one
  is a dead end — the operator can only fix the cause they own.

## Invoking the script

```bash
bash ~/.claude/skills/lcars-launch/launch.sh <mission> [hint]
bash ~/.claude/skills/lcars-launch/launch.sh <mission> --stop
bash ~/.claude/skills/lcars-launch/launch.sh --main [hint]
bash ~/.claude/skills/lcars-launch/launch.sh --main --stop
```

Dependencies are taken via env so tests can stub them: `LCARS_GIT_BIN` (git),
`LCARS_WORKER_BIN` (the cold-worker CLI; defaults to the mission's `workerBin`,
then `claude`), `LCARS_WORKER_ADAPTER` (the worker-adapter path),
`LCARS_LAUNCH_SETTLE` (the liveness poll WINDOW in seconds, default 4 — the app
must stay alive across the whole window to count as running; a dev server that
dies anywhere in it is caught as failed), `LCARS_LAUNCH_ROOT` (the deploy-checkout
root; defaults to `<repo-parent>/.lcars-launch/<repo>`), `LCARS_NOW` (the
`startedAt` stamp).

## Implementation

The logic lives in `launch.sh` next to this file, and the `launch` worker toolset
is one arm in `skills/lcars-run/worker-adapter.sh`. Behaviour is covered by
`tests/lcars-launch.test.sh`, the `--main` deploy seam by
`tests/deploy-main.test.sh` (and the `launch`-role fences by
`tests/worker-adapter.test.sh`). Edit the repo copy under `skills/`, not
`~/.claude/`; `./install.sh` symlinks it in. Keep those tests green.
