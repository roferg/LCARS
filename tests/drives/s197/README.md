# `tests/drives/s197/` — the buddy-orchestrator proof rig (S197)

The sandbox the S197 tester drove, kept rather than rebuilt (ORCHESTRATION.md
§ *Inherit the rig*).

## What `plant.sh` plants

One `SANDBOX` directory holding four things that, together, let `lcars buddy` be
driven as an orchestrator end-to-end with zero worker spend:

1. **A throwaway LCARS clone on a clean `main`** — the WIP buddy's uncommitted
   files copied over a clone of `SRC` and committed onto the clone's own `main`,
   because buddy's pre-flight refuses a dirty tree or a non-`main` checkout and
   that refusal is itself under test.
2. **One planted one-line defect** in `skills/lcars-status/status.sh` (the
   `issue_disp` `case` default arm prints `42` where the board says `#42`) — a
   real, fixable defect in a field four render sites share.
3. **A throwaway install** of that clone with **all four** `install.sh`
   destinations redirected into the sandbox.
4. **A foreign fixture repo** (`lcars init`-ed against a `gh` stub) carrying one
   planted mission at `implement` whose `events.jsonl` ends in the breadcrumb
   that describes the planted defect — so buddy has something real to collect a
   brief from, plus refusing PATH shims for both worker CLIs (`claude`,
   `copilot`: log the call, exit 97).

## How to run it

```
SRC=/path/to/LCARS-checkout-or-worktree SANDBOX=/path/to/empty/dir bash plant.sh
```

It prints the paths it made and the exact command to drive buddy from the
fixture repo with the shims first on `PATH`. Expected worker invocations: **0**.

## The four-destination install hazard

`install.sh` has **four** destinations and three default into `$HOME`, so setting
only `LCARS_SKILLS_DEST` still repoints the captain's real launchers
(`LCARS_BIN_DEST` → `~/.local/bin`), Copilot plugin
(`LCARS_COPILOT_PLUGINS_DIR`) and Copilot config (`LCARS_COPILOT_CONFIG`) at the
throwaway clone — it happened on 2026-09-11 and had to be repaired, so always set
all four (see `plant.sh`'s header).

## Evidence from the session

| File | What it records |
|---|---|
| `fix-commit-message.txt` | the commit message recorded for the planted defect's cure (its subject is `fix-branch-log.txt`'s tip) |
| `fix-branch-log.txt` | the `fix/` branch's log: cure on top of the sandbox baseline on top of `main` @ `ff1bb68` |
| `shim-invocations-final.log` | the refusing shims' final log — two `claude --version` probes, zero worker drives |
