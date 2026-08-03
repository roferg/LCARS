# Deploy-watcher drive — can a deployed app see its own writes?

> **Zero tokens.** Both CLI names are pinned by a PATH shim and the drive refuses
> to start if that shim did not take. One network step: `npm install` of Vite 5
> (~15s cold, ~3s warm on this machine). **~22s total**, warm.

```bash
bash tests/drives/deploy-watcher/drive.sh
```

On-demand only. It is **not** wired into `tests/run.sh` or any suite that runs by
default — it needs a network install and a real dev server, like its siblings in
`tests/drives/`.

---

## Why this exists

S167 moved `lcars launch`'s deploy checkout out of the repo's `.git/` and into
`<repo-parent>/.lcars-launch/<repo>/<key>`. Not for tidiness: Vite's default
`server.watch.ignored` contains `**/.git/**`, so a deploy cut inside `.git/` was
watched by **nothing**. The server booted, served pages, and then never saw
another change — no HMR, no `import.meta.glob` re-evaluation, no re-read of data
files. Every chokidar-based tool (webpack, nodemon, Tailwind JIT, `tsc --watch`)
is affected identically.

That made a deploy **misleading**, not merely limited. It looks like a working
app, so a correct fix whose effect depends on reading changed files back reads as
*still broken* — two correctly-fixed bug missions (`lcars-20260801-004` and
`-006`) were both presented to the captain as failures.

**A path assertion cannot catch this.** `tests/lcars-launch.test.sh` proves the
worktree lands at the sibling path, and it would stay green if a new
watcher-hostile location were invented tomorrow. The only instrument that can see
the defect is a real dev server, on a real deploy, asked whether it noticed a real
new file.

## What it proves

Two legs, run sequentially against the same commit, the same deps, the same Vite,
the same fixture — **one thing different, the path**:

| leg | deploy location | new `src/data/*.json` must be… |
|---|---|---|
| **GREEN** | the real `lcars launch` deploy, outside `.git/` | **seen** — served glob goes 2 → 3 |
| **RED CONTROL** | the pre-S167 location, inside `.git/` | **not seen** — served glob stays 2 |

Measured on this machine: green flips in **~50ms**; red is still at 2 after a
**10s** window (~200× longer).

The fixture is one file doing one job — `src/data-index.js` calls
`import.meta.glob('./data/*.json', { eager: true })`. Vite resolves that at
transform time and re-resolves it only when its **watcher** says the directory
changed, so the number of keys the server hands back is a direct readout of "is a
watcher alive on this checkout?". `probe.sh` counts those keys over HTTP.

## The RED CONTROL is not optional

**A drive that cannot go red proves nothing.** If the fixture ever stopped
exercising the watcher at all — wrong URL, a cached response, the glob no longer
eager — the green leg would keep passing by pure accident, and this drive would
become another green light over a broken product. The red leg is what makes the
green leg mean something.

So if the red control ever goes *green*, the drive reports **BROKEN CONTROL** and
exits `2`. It does not quietly pass. Do not delete the red leg, and do not
"simplify" it into a path check — that is exactly the over-certification the whole
rig exists to replace.

The control has to be staged **by hand**, with `git worktree add --detach` into
`.git/lcars/launch/m1` plus a directly-started Vite. That is not laziness:
`lcars launch` now *refuses* to deploy under `.git/` (the fix working), and
`$LCARS_LAUNCH_ROOT` is not a way in either — the guard rejects an override
pointing under `.git/` too, and correctly so.

## Zero spend, and how it is held

`launch.sh` resolves its engine from **three** places with a different winner per
path: `$LCARS_WORKER_BIN`, the mission's persisted `state.json` `workerBin`, and
its own literal `claude` fallback. Pinning the env var alone has been *measured*
losing to a persisted `state.json` and spawning a real billable worker. PATH is
the one seam all three go through, so the drive shims **both** `claude` and
`copilot` there — and the mission's `state.json` deliberately persists
`"workerBin": "claude"` so that path is the one actually exercised.

Belt and braces: before anything runs, the drive checks that `command -v claude`
and `command -v copilot` both resolve *inside* its own shim dir, and **skips**
(77) rather than risk one real worker. At the end it asserts the shim was actually
invoked.

## Exit codes

| code | meaning |
|---|---|
| `0` | both legs held — outside `.git/` the deploy sees its own writes; inside, it does not. |
| `1` | the **green** leg failed: a real deploy could not see its own writes. The S167 defect is back. |
| `2` | the **red control** failed to go red. The drive proves nothing — fix the rig before trusting any green. |
| `77` | **SKIPPED / infrastructure**, loudly, with the reason named (no node/npm/curl/git, `npm install` failed, no free port, shim did not take). Never a pass. |

Artifacts — `npm.log`, `red.log`, `shim-invocations.tsv`, the launch stdout, the
whole throwaway repo — live under the drive root.

**A passing run leaves nothing behind**: no server running, no root on disk. Both
dev servers are reaped by process *group* (the red control is started with the
same `perl POSIX::setsid` trick `launch.sh` uses, so `PID == PGID` and its whole
tree dies with it), the in-`.git` control worktree is unregistered, and the root —
~18MB of `node_modules` a run — is removed. A **non-zero** exit keeps the root and
prints its path, because the failure messages point at files inside it. Cleanup
runs on normal exit, on every failure path and on Ctrl-C, and always preserves the
exit code it found.

Set `DRIVE_ROOT` to pin the root somewhere; otherwise it is a fresh `mktemp -d`. A
root you named is never deleted (the worktree is still unregistered, so a re-run
at the same path works). `LCARS_REPO` overrides which LCARS checkout is under test
(default: the repo this drive is committed in, so the drive relocates with it).

`shim-invocations.tsv` records `timestamp⇥cli⇥argc=N⇥model=yes|no` per worker
invocation, and the drive's own summary reports how many carried `--model` — so
"would this have billed, and at what tier?" is answerable from the drive's
artifacts alone.

## What it does NOT prove

Say the blind spots out loud, so nobody mistakes this for more than it is:

- **One watcher, one framework.** Vite 5 + chokidar. It does not exercise webpack,
  nodemon, Tailwind JIT or `tsc --watch`, which share the mechanism but not the
  code.
- **One signal.** `import.meta.glob` re-resolution on file *add*. Not HMR of an
  edited module, not a delete, not a rename.
- **Nothing about the app being right.** It proves the deploy is *observable*, not
  that it renders anything correct. The captain still looks at the screen.
- **No real worker.** Discovery is shimmed, so this says nothing about whether a
  real `launch` worker picks the right command for a real repo.
- **The guard's copy is pinned elsewhere.** The two-cause refusal for a deploy root
  under `.git/` is asserted in `tests/lcars-launch.test.sh` §23, not here.
