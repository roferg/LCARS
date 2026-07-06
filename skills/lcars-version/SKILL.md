---
name: lcars-version
description: Show the LCARS version picture — the RUNNING version of this LCARS clone (its VERSION file), the source clone's path and git state (branch, clean/dirty), and, when the current repo is LCARS-initialized, the version stamped in its config.json with a one-line verdict — `current`, `repo needs lcars update`, or `unknown` (predates versioning). Read-only and safe; it never runs a network fetch. Use when the captain runs `lcars version`, asks "what version am I on", "is my checkout / repo up to date", or wants to know whether an initialized repo needs `lcars update`.
---

# lcars version

`lcars version` answers three questions in one read-only brief:

1. **What version is this LCARS clone?** — the RUNNING version from the clone's
   `VERSION` file (`YYYY.M.N`: calendar year, month with no leading zero, a
   per-month counter).
2. **Where does the source live and is it clean?** — the checkout path plus its
   git branch and clean/dirty state. (It does **not** fetch — ahead/behind of the
   remote is out of scope; this path has no network.)
3. **Is the current repo stamped and current?** — when the working directory is
   an LCARS-initialized repo (`.git/lcars/config.json` exists), the `lcarsVersion`
   recorded there and a one-line verdict:
   - stamped **==** running → `current`
   - stamped **<** running → `repo needs \`lcars update\``
   - stamped **absent** → `unknown` (the repo predates versioning)

Versions are compared field-by-field **numerically**, so `2026.7.10` is correctly
newer than `2026.7.2`.

## Run it

```bash
bash ~/.claude/skills/lcars-version/version.sh
```

If LCARS lives somewhere non-standard (auto-resolve through the install symlink
should normally find it), point at it explicitly:

```bash
LCARS_REPO=~/Projects/LCARS bash ~/.claude/skills/lcars-version/version.sh
```

Show the captain the brief verbatim, then give a short read: what version they're
on, whether the source checkout is clean, and — if the current repo is behind —
that `lcars update` will bring its stamp (and any missing labels/config keys)
current.

## What this skill is NOT

It does not modify anything. Stamping a repo's `lcarsVersion` happens in
`lcars init` (seeds it) and `lcars update` (refreshes it to the running version);
`lcars version` only reports.
