# S203 gating micro-spike — RESULT (run 2026-09-13, standalone de-risking probe)

Run BEFORE S203, by a probe agent, so the captain knows the answer before he
commits the session. No production code was written; nothing was committed.

## Q1 — can the raw-CDP driver screenshot an app that `launch.sh` launched?  **YES**

Path that worked, end to end:

1. Sandbox app: a purpose-built minimal Node web app ("grout-tracker") in its own
   throwaway git repo under the session scratchpad — `package.json` with a `dev`
   script, `server.js` (node http, no deps), `index.html` with five `id=`'d
   elements (`siteTitle`, `batchCode`, `tileCount`, `mixRatio`, `statusLine`).
   WHY this and not a groutwork duplicate: the 50-minute box. A groutwork clone
   needs a pnpm/electron provision step whose failure mode is exactly the thing
   S203 is not asking about. The spike question is about the DRIVER, so the app
   only had to be real and launchable through `launch.sh`. It was.
   `roferg/groutwork` and `roferg/groutwork-holodeck` were never touched.

2. `bash skills/lcars-launch/launch.sh --main "the grout tracker web app"`
   with `LCARS_WORKER_BIN=copilot` and `LCARS_LAUNCH_ROOT` pointed at the
   scratchpad. REAL launch: a real copilot `launch`-role inspector worker wrote
   `launch-discovery.json` ({target, command `npm run dev`, cwd ".",
   url http://localhost:4173, status ready}), the skill launched it detached,
   and `launch.json` came back `status: running`, pid/pgid 41250, with the
   S187-verified url. (`launch --main` needs NO mission — that is the cheapest
   real launch path for a rig.)

3. `tests/drives/s203/spike.sh <url> <out> siteTitle,batchCode,tileCount,mixRatio,statusLine`
   — headless Chrome in smoke.sh's shape (own profile, `--remote-debugging-port=0`,
   DevToolsActivePort read defensively, PID-recorded teardown) driving
   `tests/drives/s203/spike-drive.js` (zero-dep raw CDP; Runtime/Log/Page enabled
   before navigating; polls the real DOM until every named id has a non-zero box).

4. Output: 6 PNGs (one full page + one clipped per place name), each with a paired
   `.json` factual readout (url, title, text excerpt, per-id box + computed colour,
   console errors) and a one-line `.txt` caption.

Proof the PNGs are REAL renders, not blank frames: `spike-drive.js` decodes each
PNG itself (node `zlib`, the cdp.js sampler idiom) and reports distinct-colour
count, dominant colour and non-dominant pixel fraction. shot-01: 464 distinct
colours, dominant `#0b0f14` at 82%, 17.9% non-dominant — `painted: true`. Every
one of the 6 shots painted; driver exited 0. A human (the probe agent) also
OPENED shot-01.png and read it: the page, its orange header and its three panels
are visibly, correctly rendered.

## Q2 — can a copilot `number-one` worker SEE a PNG it is given?  **YES — decisively**

Design that separates a READ from a GUESS: `index.html`'s batch-code element was
filled at fixture-build time from `/dev/urandom` — the value **NQVNFZ**. That
string exists in no filename, no path, no prompt, and nowhere in the worker's cwd.
The worker was given a directory containing ONLY `shot-01.png` (no `.json`, no
`.txt`), via the adapter's `--add-dir` seam
(`LCARS_WORKER_INPUT_DIRS`), role `number-one`, `LCARS_WORKER_MODEL=claude-opus-4.8`.
The prompt named no content, only the layout slots to fill, and said explicitly
"do not guess — a guess is worse than an honest false".

It returned, verbatim:

    {"canSeeImage": true, "headline": "GROUT TRACKER", "topBarColour": "orange",
     "panels": [{"label":"BATCH CODE","value":"NQVNFZ"},
                {"label":"TILES LAID","value":"1,472"},
                {"label":"MIX RATIO","value":"3:1"}],
     "footerText": "Bay 4 — curing, 18 hours remaining",
     "pageBackground": "very dark navy blue (near-black)"}

Every value correct, including the random token, the thousands separator, and the
footer's em-dash. Its stdout was "I'll look at the image first." That is a read.

### Control — copilot's DEFAULT model: **produced nothing at all**
Same prompt, same `--add-dir`, no `--model`: zero-byte `.worker.out`, no
`xo-answer.json`. This is S194's measured write-floor failure (the default model
has no `create`), not a vision failure — but it has the same consequence.
**S203's worker spawns MUST pin the write-capable model alias, exactly as
`launch.sh:launch_worker_model()` does.** An unpinned Number One worker is silent.

### Fallback leg (run anyway, as belt-and-braces): readout JSON alone — **also YES**
Same worker, given a directory containing ONLY `shot-01.json` (no PNG) and told
there was no screenshot: identical correct answer, `couldNotDetermine: []`.
So the paired readout is a genuine second evidence channel, not a theory.

## Recommendation for S203
The spike's "if NO" branch is DEAD. Build the image path as primary:
xo-drive.js writes PNGs, the worker is handed `xo/shots/` via `--add-dir` and
looks at them. Keep the paired `.json` readout — it costs nothing, it is what
the report quotes in words (screenshots do not travel), and it is a working
fallback if a future engine's vision regresses. Pin the worker model.

## Files
- `spike-drive.js`, `spike.sh` — the rig (kept).
- `shots/` (gitignored) — the 6 PNG/json/txt triples, `launch.json`,
  `launch-discovery.json`, the fixture app, and `q2-worker/` holding both
  prompts and both worker answers verbatim.
