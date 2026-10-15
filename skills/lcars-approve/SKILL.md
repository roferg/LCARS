---
name: lcars-approve
description: >-
  Ship a verified LCARS Mission — MERGE its open pull request and mark it
  Done. Runs only on a Mission parked at the Verify stage, where `lcars run`
  has already AUTO-OPENED the PR and left the Mission "in review — PR open"
  (prUrl recorded in state.json). `lcars approve` is the captain's MERGE
  signal: it merges that open PR with `gh pr merge` (via the host adapter)
  and, only on a SUCCESSFUL merge, clears the stage labels, applies
  `lcars:done`, moves the stage to `done`, and prints the merged PR URL. It
  NEVER marks a Mission Done without a real merge — a failed merge
  (conflicts, checks, auth) leaves it at Verify with an actionable message
  (no false Done). With no open PR recorded it refuses (re-run the mission
  so Verify opens the PR first). Use when the captain runs `lcars approve
  <mission-id>`, or asks to approve / ship / merge the PR for a Mission they
  have finished reviewing in Verify.
---

# lcars approve

`lcars approve <mission-id>` is the captain's go-ahead at the end of **Verify**.
By the time a Mission reaches Verify, `lcars run` has already **auto-opened the
PR** and parked the Mission "in review — PR open". The human has read the diff,
run the app, and reviewed the PR; `lcars approve` is the **merge** signal that
ships it. It is purely mechanical — there is no LLM work to do — so you just run
the one script and report what it did.

## What it does

```bash
bash ~/.claude/skills/lcars-approve/approve.sh --mission <id>
```

1. **Requires an open PR.** It reads `prUrl` / `prNumber` from `state.json` —
   the PR **Verify** opened. With no recorded PR it refuses (re-run the mission
   so Verify opens one), staying at `verify`.
2. **Merges the PR** with `gh pr merge` (via the host adapter), identifying it by
   the recorded PR number (or the branch).
3. **Only on a successful merge:** clears the stage labels (removes
   `lcars:verify` + any `lcars:awaiting-human`, adds `lcars:done`), advances the
   stage to `done` in `state.json` (label and stage in lockstep), records
   `review: "merged"`, and prints the merged PR URL. If Number One was stood
   down, releases only the mission and child pauses recorded as `paused-by-us`
   in its `xo-stop` record, then removes that record. Existing captain-owned
   pauses (`already-paused`), marker-only stops (`left-running`), and pauses
   without a stop record are not cleared. This does not re-engage Number One.

On success it prints:

```
APPROVE: merged — <title>
  Merged PR: https://github.com/<owner>/<repo>/pull/<n>
  Branch:    lcars/<id> → <base>
  Stage:     done
```

The PR-open logic (title/body/manifest builders + the checkout/push/`gh pr
create` orchestration) lives in `pr-lib.sh` next to this file, shared with the
Verify driver's auto-open (`run.sh open-pr`) so the PR body is built in exactly
one place.

## Guards & failure modes

- **Verify only.** `approve.sh` refuses to run on any stage other than `verify`
  and changes nothing.
- **No merge ⇒ no Done — the Mission stays at `verify`.** This is the core
  invariant. If `gh pr merge` fails (merge conflicts, failing required checks,
  auth, or `gh` missing), `approve.sh` exits non-zero with an actionable message
  and applies **no** `lcars:done` and **no** stage change. A card in the Done
  column with no merged pull request behind it is a false signal, so approve
  never produces one — fix the blocker (resolve conflicts, fix `gh` auth, or
  merge on GitHub) and re-run.
- **GitHub-side merge.** If the captain merges the PR directly on GitHub, the
  `lcars run` driver's Verify heartbeat detects it (`gh pr view --json
  state,mergedAt`) and marks the Mission Done the same way — `lcars approve` is
  not the only path to Done, just the in-CLI one. A paused Verify mission with
  a recorded PR can still detect that merge and release its recorded
  Number One stop; an open PR remains paused and starts no work.

## Report

Tell the captain the PR is merged (with its URL), that the Mission is now
**Done**, and surface any warning the script printed.

## Implementation

The logic lives in `approve.sh` + `pr-lib.sh` next to this file; behaviour is
covered by `tests/lcars-approve.test.sh` (merge role) and
`tests/lcars-verify-pr.test.sh` (Verify auto-open) in the LCARS repo (run with
`bash tests/run.sh`). The `gh` and `git` binaries are taken via `LCARS_GH_BIN` /
`LCARS_GIT_BIN` so tests can stub them. Edit the repo copy, not `~/.claude` —
`./install.sh` symlinks it in.
