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

3. **DRIVE.** For each bug in order, it delegates to **`lcars run drive`** and
   drives the bug **only up to its Verify gate** — it never approves and never
   opens a PR. If a bug **escalates** to awaiting-human (a cap-exhausted ticket,
   a scope change, an empty rebuild, …), the batch **pauses at that bug**: its
   question is left in the normal awaiting-human gate / `lcars answer` inbox, no
   consolidated gate fires, and **already-resolved earlier bugs are not rolled
   back**. Answer it (`lcars answer`), then re-run `lcars resolve-logs <parent>`
   to continue with the rest.

## The single re-verify ask

Once **every** bug in the set has reached its Verify gate (fix on its branch,
guardrails green), `resolve-logs` raises **exactly one** consolidated
awaiting-human card on the **parent** — *"N logged bugs resolved [list], ready
for you to re-verify"* — and fires **exactly one** `$LCARS_NOTIFY`. Not N.

**What "re-verify" means:** the bugs are fixed and parked at Verify, but nothing
has been shipped. The captain re-inspects each fix (re-run the app, read the
diff), then for each bug either:

- **`lcars approve <bug-id>`** — ship it (open its PR, mark it Done), or
- **`lcars feedback <bug-id>`** — send it back to Align with a note.

`resolve-logs` **never auto-approves** anything and never opens a PR — the
re-verify decision is always the captain's.

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
`$LCARS_RUN_SCRIPT` (the path to the `lcars run` driver).
