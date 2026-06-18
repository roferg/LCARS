---
name: lcars-resolve-logs
description: Resolve every bug logged against a parent Mission in one batch — the Mission Log resolver. Takes a parent Mission that has N linked bug Missions (filed via `lcars log` during the parent's Verify), decides a sensible resolution order, drives each bug one-by-one to its Verify gate by delegating to the existing `lcars run` driver, and then raises EXACTLY ONE consolidated re-verify human gate plus ONE notification on the parent — instead of N scattered Verify gates. If a bug escalates mid-batch (a cap-exhausted ticket, a scope change, etc.) the batch pauses at that bug, surfaces its question in the `lcars answer` inbox, and resumes from the remaining bugs once you have answered. Adds no new stage logic. Use when the captain runs `lcars resolve-logs <parent>`, asks to resolve / clear / work through the bugs logged against a Mission, or wants the logged bugs of a Mission driven to a single re-verify gate.
---

# lcars resolve-logs

`lcars resolve-logs <parent>` is the **Mission Log resolver**. During a parent
Mission's Verify, the captain logs bugs against it with `lcars log`; each becomes
its own fast-tracked bug Mission linked to that parent. Left alone, each bug
would later reach its **own** Verify gate and ping you separately — N scattered
asks for one review session. `resolve-logs` collapses that: it drives every
logged bug to its Verify gate and then asks you to re-verify them **once**.

This verb adds **no new stage logic**. It is pure orchestration over machinery
that already exists:

- the linkage `lcars log` wrote (`state.json` `parentMission` + `type: bug`),
- the existing **`lcars run`** driver (it never reimplements a stage),
- the existing **awaiting-human** gate + the **`lcars answer`** inbox,
- the existing **`$LCARS_NOTIFY`** walk-away ping.

You (Claude) do not need to do a natural-language half here — the mechanical
`resolve-logs.sh` does everything. Just run it and report what it did.

## What it does

1. **GATHER.** Resolve `<parent>` against the active Mission table — accepts a
   mission **id**, a **`#issue`** number, or a **title** substring, exactly like
   `lcars log`. An ambiguous or missing selector lists the candidates and
   refuses. It then collects every linked bug Mission (`parentMission == parent`,
   `type bug`, `stage != done`, not already at Verify) into the **work set**. If
   there are no open linked bugs, it prints a message and exits cleanly — **no
   gate, no notification**.

2. **ORDER.** It asks the worker (`$LCARS_WORKER_BIN`) for a sensible resolution
   order — root-cause / data-model bugs and dependencies **before** cosmetic
   ones — and records the chosen order plus a one-line rationale per bug to
   `resolve-logs.md` on the parent. Absent a worker choice it falls back to
   **filed order**. The ordering decision stays out of the shell.

3. **SCHEDULE (S73).** It folds the ordered work set into dependency-aware
   **waves**, reusing the per-Mission Schedule stage's wave concept. The
   independence signal is **conservative**: two sibling bugs share a wave (and so
   may drive concurrently) **only** when their `plan.json` target file paths are
   clearly **disjoint** *and* they do **not** share a working branch — otherwise
   they serialise into ordered waves. A bug with no plan paths is treated as
   touching-everything and serialises. The schedule is recorded as
   `resolve-waves.json` (and appended to `resolve-logs.md`) on the parent.

4. **DRIVE.** It runs the waves **in sequence**; same-wave bugs are eligible to
   drive **concurrently** (bounded by `$LCARS_RESOLVE_CONCURRENCY`, default 2),
   each delegated to **`lcars run drive`** up to its Verify gate only — never
   approving, never opening a PR. Concurrency is **safe** because the per-Mission
   driver lock isolates distinct child Missions and same-wave bugs have **distinct
   branches** (so no same-branch / shared-working-tree commit collision);
   same-branch fold cases are placed in separate waves and stay serial. A bug that
   is **scheduled but not yet driving** carries a `queued: true` flag in its
   `state.json` (the board's "waiting to go" pill, UX-29), cleared when it starts.
   If a bug **escalates** to awaiting-human, the batch **pauses**: remaining waves
   do **not** run, its question is left in the `lcars answer` inbox, no
   consolidated gate fires, and **already-resolved bugs are not rolled back**.
   Answer it (`lcars answer`), then re-run `lcars resolve-logs <parent>` to
   complete the remaining waves.

## The single re-verify ask

Once **every** bug in the set has reached its Verify gate (fix on its branch,
guardrails green), `resolve-logs` raises **exactly one** consolidated
awaiting-human card on the **parent** — *"N logged bugs resolved [list], ready
for you to re-verify"* — and fires **exactly one** `$LCARS_NOTIFY`. Not N.

**What "re-verify" means (Model A — logged-bug fixes fold into the parent):**
the bug fixes are committed onto the **parent's** branch, so they ride the
**parent's** existing PR — there is **no per-bug PR** and no stack of
bug→parent PRs. The captain re-inspects the fixes (re-run the app, read the
diff) once, then for the **whole batch**:

- **accept** — answer the consolidated gate
  (`lcars answer respond --mission <parent> --answer "…"`). On acceptance,
  `respond` folds every resolved child bug to **Done** (clears its stage label,
  applies `lcars:done`, moves it to the Done column) **without opening a per-bug
  PR** — the parent's PR carries the merged fixes. No child is left orphaned at
  Verify.
- **send back** — `lcars feedback <parent>` returns the Mission (and its folded
  fixes) to Align with a note.

The completion fold is owned by `resolve-logs` itself
(`resolve-logs complete --parent <id>`) and invoked by `respond` when the gate
is cleared; it is a clean no-op for an ordinary escalation. `resolve-logs`
**never auto-accepts** anything and never opens a PR — the re-verify decision is
always the captain's.

## Usage

```
lcars resolve-logs <parent>      # id | #issue | title substring
```

Open the consolidated card with `lcars answer` once it has been raised. The
verb is **idempotent**: re-running it after answering a paused bug picks up the
remaining bugs and only raises the consolidated gate when all of them are green.

## Implementation

The mechanical logic lives in the bundled `resolve-logs.sh` (pure bash, jq-free)
so it stays testable; `lcars resolve-logs` is wired through `skills/lcars/lcars.sh`
as a thin delegator. All external dependencies are env-injected so tests can stub
them: `$LCARS_WORKER_BIN`, `$LCARS_GH_BIN`, `$LCARS_GIT_BIN`, `$LCARS_NOTIFY`, and
`$LCARS_RUN_SCRIPT` (the path to the `lcars run` driver). `$LCARS_RESOLVE_CONCURRENCY`
(default 2) caps how many same-wave bug drivers run at once.
