---
name: lcars-approve
description: Ship a verified LCARS Mission — open its pull request and mark it Done. Runs only on a Mission parked at the Verify stage (where `lcars run` left it after every ticket went green). It checks out the Mission's branch (recorded by `lcars file`), requires commits ahead of the base, pushes the branch, and opens the PR with `gh pr create --head <branch> --base <base>` — titled from the PRD and bodied with a per-wave summary of the tickets — then, only once a PR URL is captured, clears the stage labels, applies `lcars:done`, moves the stage to `done`, and prints the PR URL. If no PR can be created it stays at Verify (never a false Done). Use when the captain runs `lcars approve <mission-id>`, or asks to approve / ship / create the PR for a Mission they have finished reviewing in Verify.
---

# lcars approve

`lcars approve <mission-id>` is the captain's go-ahead at the end of **Verify**.
The human has read the diff and run the app; this skill ships it. It is purely
mechanical — there is no LLM work to do — so you just run the one script and
report what it did.

## What it does

```bash
bash ~/.claude/skills/lcars-approve/approve.sh --mission <id>
```

`approve.sh` opens the PR **deterministically from the Mission's own branch** —
it does not rely on the captain happening to be on the right branch:

1. **Reads `branch` and `base` from `state.json`** (recorded by `lcars file`).
2. **Checks the branch out** (it must exist — Implement committed the tickets to
   it) and **requires commits ahead of `base`** — no content, no PR.
3. **Pushes it** with `git push -u origin <branch>`.
4. **Opens the PR** with `gh pr create --head <branch> --base <base>`. The title
   is the PRD's `# Mission:` line (falling back to the `state.json` title); the
   body is a `## Summary` plus a per-wave list of the tickets, read from
   `waves.json` and `approved-plan.json`.
5. **Only once a PR URL is captured:** clears the stage labels (removes
   `lcars:verify` + any `lcars:awaiting-human`, adds `lcars:done`), advances the
   stage to `done` in `state.json` (label and stage in lockstep), and prints the
   PR URL.

On success it prints:

```
APPROVE: shipped — <title>
  Opened PR: https://github.com/<owner>/<repo>/pull/<n>
  Branch:    lcars/<id> → <base>
  Stage:     done
```

## Guards & failure modes

- **Verify only.** `approve.sh` refuses to run on any stage other than `verify`
  and changes nothing — a Mission can only be shipped once Implement has every
  ticket green and `lcars run` has parked it at Verify.
- **No PR ⇒ no Done — the Mission stays at `verify`.** This is the core
  invariant. If the branch is missing, has **no commits ahead** of base, the
  **push fails**, `gh` is missing, or **`gh pr create` returns no URL**,
  `approve.sh` exits non-zero with an actionable message and applies **no**
  `lcars:done` and **no** stage change. A card in the Done column with no pull
  request behind it is a false signal, so approve never produces one — fix the
  blocker (e.g. push the branch, fix `gh` auth) and re-run.

## Report

Tell the captain the PR is open (with its URL), that the Mission is now
**Done**, and surface any warning the script printed (e.g. open the PR by hand
if `gh` was unavailable).

## Implementation

The logic lives in `approve.sh` next to this file; its behaviour is covered by
`tests/lcars-approve.test.sh` in the LCARS repo (run with `bash tests/run.sh`).
The `gh` and `git` binaries are taken via `LCARS_GH_BIN` / `LCARS_GIT_BIN` so
tests can stub them (the suite uses a real local bare repo as `origin` to
exercise the push + `--head`/`--base` path for real). Edit the repo copy, not
`~/.claude` — `./install.sh` symlinks it in.
