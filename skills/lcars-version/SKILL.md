---
name: lcars-version
description: >-
  Show the LCARS version picture — the RUNNING version of this LCARS clone
  (its VERSION file), the source clone's path and git state (branch,
  clean/dirty), and, when the current repo is LCARS-initialized, the version
  stamped in its config.json with a one-line verdict — `current`, `repo
  needs lcars update` (stamp behind OR an initialized-but-unstamped repo
  that predates versioning), or `unknown` (only a malformed stamp).
  Read-only and safe; it never runs a network fetch. Also hosts `lcars
  release`, the manual drift-repair that bumps VERSION + writes a CHANGELOG
  entry when main moved without a bump. Use when the captain runs `lcars
  version`, asks "what version am I on", "is my checkout / repo up to date",
  wants to know whether an initialized repo needs `lcars update`, or runs
  `lcars release` to repair unversioned drift on main.
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
   - stamped **absent** (but the repo IS initialized) → `repo needs \`lcars
     update\` (predates versioning)` — an initialized-but-unstamped repo predates
     the versioning round, so it definitely needs updating (captain amendment).
   - stamped **malformed** (a non-`YYYY.M.N` value) → `unknown` — never nag on
     garbage.

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

## `lcars release` — repair unversioned drift on main

Every PR into LCARS `main` is supposed to carry its own `VERSION` bump + a
`CHANGELOG.md` entry (there is no CI — the PR author is an LLM already in the
loop). When main moves WITHOUT a bump, the version checker flags **DRIFT**
("main has unversioned changes"). `lcars release` is the manual repair:

```bash
bash ~/.claude/skills/lcars-version/release.sh
```

It only runs on a **clean `main` checkout** (the captain's clones are sacred —
any other branch or a dirty tree declines with a one-line reason and no-ops). It
collects the commits on main since VERSION last changed, spawns **exactly one**
summarization worker (through the shared, engine-aware worker adapter) to author
a CHANGELOG entry from those commit subjects/bodies, bumps `VERSION` (increment
the per-month counter, or roll to `<year>.<month>.1` on a month change), prepends
the entry newest-first, and commits both. With nothing unstamped it prints
"nothing to release" and no-ops (no worker spend).

## What `lcars version` is NOT

`lcars version` does not modify anything. Stamping a repo's `lcarsVersion` happens
in `lcars init` (seeds it) and `lcars update` (refreshes it to the running
version); `lcars version` only reports. (`lcars release`, above, is the one write
path in this skill — and only against a clean main source checkout.)
