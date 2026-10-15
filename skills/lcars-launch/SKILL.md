---
name: lcars-launch
description: >-
  Get an LCARS Mission's app running locally so the captain can view it
  during Verify. `lcars launch <mission> [hint]` checks the mission's branch
  out into a disposable DETACHED git worktree, spawns a `launch`-role cold
  worker that DISCOVERS how to start the app (it never starts it itself),
  then the skill launches that command detached — owning the whole process
  group — writes a launch.json record both the CLI and the viewscreen daemon
  read, and prints an LCARS-voice readout naming the target, URL, and how to
  stop it. `lcars launch <mission> --stop` kills the process group and
  prunes the worktree. `lcars launch --main [hint]` deploys the LOCAL
  default-branch HEAD (whatever is already merged — no fetch) through the
  same pipeline, with `--main --stop` to tear it down. Failures are plain
  English, never a raw stack trace. Use when the captain runs `lcars
  launch`, asks to run / open / preview / see a mission's app while
  reviewing it, wants to deploy/run local main, or wants to stop a launched
  app.
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

# A hint is PROSE, and prose can quote a command. `--` ends the options, so
# everything after it is your words even when a word starts with a dash:
lcars launch --main -- "the browser build (npx vite --config vite.config.ts)"
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
   the checkout and writes `launch-discovery.json` describing how to start the
   app. The worker is fenced to **read + author its one answer** (`Read,Grep,Glob,Write`
   / `view,grep,glob,create`) — no shell, no Edit (S168) — the checkout is checked
   clean after its turn, and it is told **not to start anything itself**.
   **On copilot the inspector runs on a write-capable model** (the S194 write
   floor): `create` exists only on a model that offers it, and copilot's default
   model does not — without a pin the inspector writes nothing and every launch
   fails with "the inspector reported nothing back". The model is
   `$LCARS_WORKER_MODEL`, else config `workerModel`, else
   `modelAliases.copilot.opus`, else `claude-opus-4.8`. Claude gets no model flag.
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
`--stop --keep-worktree` stops the same process group but retains the checkout
and records its path. Number One uses this to run declared tests with the app's
default port free, then relaunches before its browser walk. A later ordinary
`--stop` still prunes the checkout. `--keep-worktree` requires `--stop`.

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
  "url":       "http://localhost:5174",
  "predictedUrl": "http://localhost:5173",
  "urlNote":   "plain English, present only when the guess and the socket disagreed",
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

### `url` is VERIFIED, not predicted (S187)

The worker's `url` is a **guess** read out of config. A dev server whose port is
already taken silently binds the next one, and a record that published the guess
pointed at whatever *other* app held that port — one repo's board handing the
captain a different repo's app. So the skill **observes** instead: across the
same liveness-poll window it enumerates the launched process group
(`pgrep -g <pgid>`) and reads its LISTEN sockets (`lsof`), then

- **rewrites `url`'s port** to the observed one, keeping the predicted scheme,
  host and path (and synthesizing `http://localhost:<port>` when nothing was
  predicted). Several ports in one group: the predicted port wins if the group
  really holds it, else the lowest.
- **keeps the guess as `predictedUrl`**, always — the record never loses it.
- **empties `url`** when the group holds no listening socket at all, with a
  `urlNote` saying the prediction went unverified. The app is still `running`;
  `pid`/`pgid`, `--stop` and re-launch are unchanged.
- **adds `urlNote`** whenever the observation disagreed with the guess, and says
  the same thing in the readout. A wrong guess is never a failure.

The best-effort curl probe targets the **verified** url (it still never gates).
The viewscreen renders `url` as before; `predictedUrl`/`urlNote` are additive and
the board's launch payload does not carry them.

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
- **Dependency setup went wrong** → the message leads with *that*, not with the
  symptom three layers downstream. Provisioning (the repo's
  `worktreeSetupCommand`, or `$LCARS_WORKTREE_SETUP_CMD`) runs with **both streams
  captured** to `.git/lcars/missions/<id>/launch-provision.log`, and what it said
  is classified: pnpm **actually refusing** over an out-of-date lockfile (which it
  is documented to do *while exiting 0*, so the exit code alone is not the signal —
  but a passing *mention* of `ERR_PNPM_OUTDATED_LOCKFILE` is not a refusal and is
  never diagnosed as one) is named as the lockfile problem it is; any other
  non-zero exit is reported with the line that explains it — a line carrying its own
  error tag (`error:`, `fatal:`, `ERR_…`, `npm ERR!`) wins even when it also talks
  about warnings, and only failing that is a bare warning excluded rather than
  dressed up as the reason. When the output genuinely explains nothing the message
  says so, and it names a `--silent`/`--quiet` flag only when the setup command
  really carries one. Every one of them names the override you can actually reach:
  `LCARS_WORKTREE_SETUP_CMD="…" lcars-launch <mission>`. Provisioning stays
  **best-effort** — a failure is *reported*, never enforced, so it can't refuse a
  launch that would have worked (deps may already be in a reused worktree). If the
  app does come up anyway, the readout and the record carry a `provisioning`
  heads-up rather than passing it off as clean.
- **A failed launch keeps its checkout.** The disposable worktree is *not* pruned
  on failure — that directory (a half-provisioned `node_modules`, a missing
  binary) is the evidence of *why*, and deleting it before anyone reads it is what
  made this class of failure unreadable. It cannot accumulate: the path is keyed
  by mission, so a re-launch reuses that same one and `--stop` clears it. Every
  failure message says where it is and how to clear it.
- **Unknown mission / no branch yet** → a clean refusal naming the problem (run
  the mission first).
- **The deploy root would land inside a `.git/`** → refused either way (watchers
  ignore `.git`), but the message names the cause that actually applies: if
  `$LCARS_LAUNCH_ROOT` is what put it there it says so and tells you to repoint or
  unset it; if the root was *derived* from a checkout that itself lives under a
  `.git/` it tells you to run from the repo's own checkout. Naming the wrong one
  is a dead end — the operator can only fix the cause they own.

## Invoking the script

`install.sh` also drops a real on-PATH **`lcars-launch`** command (beside
`lcars-viewscreen` / `lcars-serve`), so the environment overrides below can
actually be set on a launch from any shell:

```bash
LCARS_WORKTREE_SETUP_CMD='pnpm install --no-frozen-lockfile --prefer-offline' \
  lcars-launch <mission>
```

```bash
bash ~/.claude/skills/lcars-launch/launch.sh <mission> [hint]
bash ~/.claude/skills/lcars-launch/launch.sh <mission> --stop
bash ~/.claude/skills/lcars-launch/launch.sh --main [hint]
bash ~/.claude/skills/lcars-launch/launch.sh --main --stop
```

Dependencies are taken via env so tests can stub them: `LCARS_GIT_BIN` (git),
`LCARS_WORKER_BIN` (the cold-worker CLI; defaults to the mission's `workerBin`,
then `claude`), `LCARS_WORKER_MODEL` (pins the inspector's model; see step 3),
`LCARS_WORKER_ADAPTER` (the worker-adapter path),
`LCARS_LAUNCH_SETTLE` (the liveness poll WINDOW in seconds, default 4 — the app
must stay alive across the whole window to count as running; a dev server that
dies anywhere in it is caught as failed), `LCARS_LAUNCH_ROOT` (the deploy-checkout
root; defaults to `<repo-parent>/.lcars-launch/<repo>`), `LCARS_WORKTREE_SETUP_CMD`
(the worktree provisioning command; overrides the repo's `worktreeSetupCommand`
for this run), `LCARS_NOW` (the `startedAt` stamp).

## Implementation

The logic lives in `launch.sh` next to this file, and the `launch` worker toolset
is one arm in `skills/lcars-run/worker-adapter.sh`. Behaviour is covered by
`tests/lcars-launch.test.sh`, the `--main` deploy seam by
`tests/deploy-main.test.sh` (and the `launch`-role fences by
`tests/worker-adapter.test.sh`). Edit the repo copy under `skills/`, not
`~/.claude/`; `./install.sh` symlinks it in. Keep those tests green.
