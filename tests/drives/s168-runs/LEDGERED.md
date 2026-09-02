# S168 — found, measured, NOT cured. Named so the round does not read as total coverage.

Two holes this round did not close. Both were found by the LIVE drives; neither
is visible to a stub, and neither was known when the round was planned.

---

## L1. copilot's path sandbox does not cover the system temp root

**Measured 2026-08-30/31, copilot CLI 1.0.82, role `repo-read`, every run with a
working negative control:**

| forbidden target | wrote without a grant? |
|---|---|
| inside `$TMPDIR` (`/var/folders/.../T/`) | **5 of 6** |
| anywhere else | **0 of 5** — refused every time |

So `--add-dir` IS a real fence for ordinary absolute paths — and is NOT one for
`$TMPDIR`. This **partly refutes the S124 spike's "copilot's sandbox is
structural"**, which this round's own "What we are NOT changing" section rests
on when it declares Part A a claude-only change. The tool restriction is real
(separately proven: both copilot roles reported no shell and still wrote their
answer); the PATH restriction has a temp-shaped hole.

**Why it matters to LCARS specifically.** Worker scratch outdirs are created with
a bare `mktemp -d` — 24 sites in `run.sh`, e.g. `:530`, `:10547`, `:10685`,
`:10813` — so they live under `$TMPDIR`. The harness reads each worker's ANSWER
out of exactly those directories, Research fans out one worker per question and
Implement runs up to `$LCARS_MAX_PARALLEL` at once. A copilot worker therefore
holds ungranted write access to a CONCURRENT worker's answer channel.

Exploiting it requires the worker to go looking — it is handed only its own
path — but it holds `glob`, and the sandbox will not stop it.

**Captain's ruling (2026-08-31): ledger, do not cure here.** It is inherited
production code, not this session's work. The cure, when it is taken: point the
outdirs workers are HANDED at `$MISSION_DIR` (the pattern already used at
`:8888` and `:11118`), which the sandbox does cover.

Evidence: `copilot-clean-repo-read.txt` (PASS), `copilot-offtmp-*.txt` (PASS,
off-temp), `post168-copilot-repo-read-INSIDE-TMPDIR.txt` (FAIL, in-temp),
`pre168-copilot-repo-read.txt`.

---

## L2. The Research fan-out agents are not audited

Part C's audit is gated by `worker_fence_active()`, which requires `MISSION_DIR`
to be set. The Research fan-out does **not** satisfy that, and the comment at
`run.sh:11974` describing this is CORRECT — verified independently at the close
of the session, because an implementor pass reported the opposite:

- `MISSION_DIR` is assigned but **never exported** (`run.sh:469` and friends).
- `run_capped` runs every job as `bash -c "$line" &` — a SEPARATE PROCESS.
- the job line (`:12441`) exports only `LCARS_RA_DIR`, `LCARS_RA_Q`,
  `LCARS_WORKER_BIN`, `LCARS_WORKER_MODEL` — deliberately, since a research
  agent is stateless and reaches no mission artifacts.

**The good news:** no false-fire. Concurrent agents cannot trip each other's
`events.jsonl` window, because none of them has a window.

**The gap:** those agents are the most numerous workers in the pipeline — up to
20 per Research stage — they run at `repo-read-web` (which HOLDS `Write`), and
they inherit the front-half worktree as cwd. They are unaudited. What guards
them today is that they are handed no mission paths, not that anything checks
them afterwards.

Closing it means exporting the mission context into the child, which switches on
the `events.jsonl` half of the audit for many concurrent processes and creates
exactly the false-fire risk Part C was careful to avoid. That is a design pass,
not a patch, and it belongs to whoever owns the audit next.

---

## L3. A plan with NO declared dependencies serialized completely (12 waves of 1)

**Measured 2026-09-01** on the holodeck end-to-end drive (`cap-cop-holo3`,
mission `lcars-20260901-002`, a 12-ticket MBR-Builder rebuild).

Schedule laid the 12 tickets out as **twelve sequential waves, one ticket each**
— every ticket waiting on the one before it. **Not one of the 12 tickets
declares a dependency on any other.** With nothing declared, the dependency
graph became a queue.

LCARS itself flagged it, which is the point — the warning is already there and
already correct:

```
schedule     ✓  12 wave(s) — ⚠ 1 ticket each, no parallelism
```

`wave_shape` (run.sh ~:4846) prints exactly this when `peak <= 1`: *"If that is
not genuinely true, the dependency graph is a queue and this run is as slow as
it can possibly be."* It was true here.

**Some serialization IS warranted.** These tickets pile onto the same few files
(the builder view, `styles.css`), and two siblings editing one file blind to each
other is precisely the failure the wave-isolation round (S156–157) was built to
stop — it went undetected for eleven tickets last time. The likely cause is that
round's infra-isolation backstop classifying broadly and isolating everything.

**But twelve-of-twelve is over-conservative.** t-001 (Reviews landing screen) and
t-002 (Pulling-data screen) are separate surfaces with no overlap with the
builder chain; they could have run alongside t-003. Realistically this was 4–5
waves of work. The parallel cap already exists (`LCARS_MAX_PARALLEL`, default 4)
and went unused. Cost: roughly 2–3x the wall clock, on a stage that is already
the longest in the pipeline.

**Captain's call 2026-09-01: note it, circle back after this round passes.**
Deliberately NOT touched here — it is not this round's code, and rewriting wave
scheduling on the strength of a single mission is how you re-create the bug S156
cured. The question worth a round of its own:

> Why does a plan with **no declared dependencies** serialize completely, and
> what is the smallest change that keeps S156's anti-blindness guarantee while
> letting genuinely independent tickets share a wave?

Evidence: `pipeline/cap-cop-holo3.*`, and `plan.json` in that run's mission dir
(every ticket's `dependsOn` empty).
