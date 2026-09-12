# `tests/drives/s197/` — the buddy-orchestrator proof rig (S197)

The sandbox the S197 tester drove, kept rather than rebuilt (ORCHESTRATION.md
§ *Inherit the rig*).

## What `plant.sh` plants

One `SANDBOX` directory holding four things that, together, let `lcars buddy` be
driven as an orchestrator end-to-end with zero worker spend:

1. **A throwaway LCARS clone of `SRC`'s HEAD, on a clean `main`** — whatever
   commit `SRC` is actually on, checked out as the clone's own `main` (buddy's
   pre-flight refuses a dirty tree or a non-`main` checkout, and that refusal is
   itself under test), with any uncommitted files copied on top. So it works with
   the work dirty *or* committed to a branch.
2. **One planted one-line defect** in `skills/lcars-status/status.sh` (the
   `issue_disp` `case` default arm prints `42` where the board says `#42`) — a
   real, fixable defect in a field four render sites share.
3. **A throwaway install** of that clone with **all five** `install.sh`
   destinations redirected into the sandbox (the fifth, `LCARS_VERSION_STAMP`, is
   written by `skills/lcars-version/check.sh` rather than by `install.sh`, which
   is exactly why it went uncounted for a round).
4. **A foreign fixture repo** (`lcars init`-ed against a `gh` stub) carrying one
   planted mission at `implement` whose `events.jsonl` ends in the breadcrumb
   that describes the planted defect — so buddy has something real to collect a
   brief from, plus refusing PATH shims for both worker CLIs (`claude`,
   `copilot`: log the call, exit 97).

## How to run it

```
SRC=/path/to/LCARS-checkout-or-worktree SANDBOX=/path/to/empty/dir bash plant.sh
```

It prints the code under test (`SRC @ <sha> (<branch>)`), the paths it made, and
the exact command to drive buddy from the fixture repo with the shims first on
`PATH`. Expected worker invocations: **0**.

## The guard — why this rig cannot quietly test the wrong code

The first version of this script checked the clone out on **`main`** and copied
`SRC`'s *uncommitted* files over it. That was correct while the work was dirty.
The moment the work was **committed to a branch** it became silently wrong: the
sandbox went back to `main` (`ff1bb68`) and carried none of the branch — no
`ORCHESTRATION.md`, no `LCARS_INSTALL_PREFIX` — so re-running the rig "to verify
the PR" exercised the OLD code and printed a confident green. A fresh tester hit
exactly that, and it is the failure class `ORCHESTRATION.md § Time-box and verify
claims` warns about.

So after planting, `plant.sh` now **proves** the sandbox carries the code under
test, and **exits 1 before installing anything** if it does not:

| Guard | What it catches |
|---|---|
| the baseline commit's parent `==` `SRC`'s HEAD | the clone landed on some other commit — wording-proof, it does not care what the branch is called |
| `LCARS_INSTALL_PREFIX` present in the clone's `install.sh` | a pre-S197 `install.sh` |
| `skills/lcars-buddy/ORCHESTRATION.md` exists in the clone | the shared orchestration rules did not come along |
| `$SKILLS/lcars-buddy` resolves into the clone | the install landed on another checkout (a stale dest from an earlier run) |

Each failure names itself on stderr. A proof rig that can silently test the wrong
code is worse than no rig.

## The five-destination install hazard

`install.sh` has **five** destinations and four default into `$HOME`, so setting
only `LCARS_SKILLS_DEST` still repoints the captain's real launchers
(`LCARS_BIN_DEST` → `~/.local/bin`), Copilot plugin
(`LCARS_COPILOT_PLUGINS_DIR`) and Copilot config (`LCARS_COPILOT_CONFIG`) at the
throwaway clone — it happened on 2026-09-11 and had to be repaired, so always set
all five (see `plant.sh`'s header).

The fifth is `LCARS_VERSION_STAMP` (default `~/.claude/lcars-version-check`), the
version check's throttle stamp. It is not *written* by `install.sh`, which is how
it stayed uncounted — and leaving it in `$HOME` is not cosmetic: under a
redirected `$HOME` the stamp is always absent, so the throttle never engages and
every call runs `git fetch origin main`, which against a network `origin` blocks
on a credential prompt even with stdin closed (measured: 600 s, a hung run).

## Evidence from the session

| File | What it records |
|---|---|
| `fix-commit-message.txt` | the commit message recorded for the planted defect's cure (its subject is `fix-branch-log.txt`'s tip) |
| `fix-branch-log.txt` | the `fix/` branch's log: cure on top of the sandbox baseline on top of `main` @ `ff1bb68` |
| `shim-invocations-final.log` | the refusing shims' final log — two `claude --version` probes, zero worker drives |
