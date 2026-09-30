# Holodeck argv shims — reading the flags the daemon really built

> Two one-page pass-through wrappers. They log the **full argv and cwd** of every
> holodeck worker spawn and then `exec` the real CLI, so a live drive tells you
> what the product actually did instead of what its tests say it does.

```bash
export LCARS_SHIM_LOG=/tmp/shim.log
LCARS_WORKER_BIN="$PWD/tests/lib/shims/holodeck/copilot" bash web/serve.sh
# …open a holodeck program, say something, then:
cat /tmp/shim.log
```

Each spawn appends:

```
TIME: 2026-08-04T20:52:11Z
ARGV: -p <the whole prompt> --session-id=… --available-tools view,grep,glob --model claude-opus-4.8
CWD:  /Users/you/Projects/foo-holodeck/nav-rail
REAL: /opt/homebrew/bin/copilot
---
```

## Why this exists

The holodeck builds its worker argv inside the daemon, from per-(engine, mode)
tables, and the process is normally gone before you can look at it — **`ps` never
shows you the spawned argv.** During S124's round-0 review these shims were the
only instrument that could answer "what flags is a grounding turn actually
getting?", and the answer falsified a shipped claim: the claude grounding posture
was **not** read-only, because `--allowedTools` is a pre-approval list and
`--dangerously-skip-permissions` waives the rest. The cure (`--disallowedTools`)
was found and confirmed with these same shims plus a real write attempt.

The rig was going to be thrown away with the scratchpad, like S140's and S163's
Chrome rigs before it. It is committed instead, so the next round does not have to
invent it. (Same principle as `tests/drives/browser/`.)

## What they are and are not

* **Pass-through, not stubs.** They exec the real CLI and spend real tokens/credits.
  For a zero-spend run use a *stub* on `$PATH` instead — see the recording stub in
  `web/tests/test_holodeck_endpoints.py`, which fakes the CLI entirely.
* **They see the argv, never the enforcement.** A flag in the log is not proof the
  CLI honours it. Pair the log with a control: ask the worker to write a file it
  must not be able to write, then check the filesystem. That pairing is what
  distinguishes a real fence from a hopeful one.
* The real binary is found by scanning `type -pa` and skipping this directory, so
  putting the shim dir first on `$PATH` works. Override with
  `$LCARS_HOLODECK_REAL_CLAUDE` / `$LCARS_HOLODECK_REAL_COPILOT`.
* `$LCARS_SHIM_LOG` defaults to `/tmp/lcars-holodeck-shim.log`. Use one file per
  engine when driving both at once.
