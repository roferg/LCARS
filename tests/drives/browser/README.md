# Real-Chrome board smoke — the rig that catches a blank viewscreen

> **Zero tokens, zero network, no install step.** Real Chrome, a real daemon, a
> fixture board on disk, and shims where the models would be. Run it as often as
> you like.

```bash
bash tests/drives/browser/smoke.sh
```

That is the whole thing. It prints a screenshot path. **Open it and look at it.**

---

## Why this exists

On 2026-08-02, S163's fix round 5 deleted `.then(render)` from `refresh()` in
`web/static/board.js` while inserting an explanatory comment in its place. The
viewscreen was a **permanently blank page** for three fix rounds while **1,162
unit tests and six tester rounds stayed green** — because every harness under
`web/tests/` calls `render()` itself, so not one of them ever asked the app to
paint. Real Chrome found it in about five minutes.

That Chrome rig was thrown away afterwards. S140's headed-Chrome rig before it
was thrown away too. So the equipment was rebuilt from scratch every round —
S163 rebuilt its fixture scaffold seven times. This is that rig, **committed**,
so no future tester has to invent it again. (`run-session` STEP 4a: on any
visual session the tester's *first* action is to open the real product in a real
browser and look at it. This is the one command that does that.)

## What it proves — and what it does not

**Proves:** booting the *shipping* front end against a *real* daemon in *real*
Chrome produces real, laid-out, visible `.card` nodes in the real DOM — with
real CSS, real layout, real paint. Every link is load-bearing:

```
Chrome loads /  →  board.js boots  →  refresh()  →  GET /api/board
    →  .json()  →  render(payload)  →  #board gains visible card nodes
```

Cut any one and the rig goes red. Unlike the node harness it *can* see CSS: a
card hidden by `display:none`, sized to zero, or faded to `opacity:0` does not
count here.

**Does not prove — say it plainly, because the last blind spot cost three hours
precisely because nobody wrote down what the harness could not see.** It proves
the board **paints**, not that it is **correct**. Wrong copy, a wrong pill, a
card in the wrong column, an unreadable colour, an ugly layout, a button that
does nothing — all of that passes here. It is one click deep: no interaction, no
overlay, no write path, one fixture board, one browser. **The tester still opens
the screenshot and looks.** This rig only removes the excuse for never having
looked at all.

It is also **not** a replacement for `web/tests/board_boot_harness.js` — that
node harness is cheap, runs in the default suite, and goes red on the same cut.
Keep both: the node one for every commit, this one for every visual session.

## The second rig: `basefresh-quiet.sh` (S164)

```bash
bash tests/drives/browser/basefresh-quiet.sh              # the product
bash tests/drives/browser/basefresh-quiet.sh --calibrate   # the RED CONTROLS
bash tests/drives/browser/basefresh-quiet.sh --all         # both
```

`smoke.sh` is one click deep: it proves the board paints and nothing more. This
one goes one click further, at *one* thing — the File console's base-freshness
pre-flight — and it is the template for any future "does this actually reach the
screen" question:

1. it plants a **base-freshness record** (`LCARS_BROWSER_BASEFRESH`) as a stub
   reporter, so a repo state — one commit behind, dirty, unreachable origin —
   can be put in front of real Chrome without constructing the git situation;
2. it clicks **File** and waits for the (asynchronous) pre-flight;
3. it **measures** the line: a real non-zero bounding box, the colour the
   cascade actually resolved, and that colour composited over whatever is really
   painted behind it, as a contrast ratio. Never "the CSS rule exists" — S162
   shipped an amber warning that rendered as muted metadata with exactly that
   assertion green beside it;
4. `--calibrate` patches a **copy** of `web/` four ways and requires the check to
   go red on each: the line **absent**, the line **dressed as the warning**, the
   line **with its quiet styling stripped** (amber panel, amber text) and the
   line **muted into unreadability**. The last two exist because the first two
   fail early, and an assertion no control ever exercises is an assertion nobody
   has shown can go red.

The screenshot is `file-console.png`; the numbers are `console-check.json`.
**Open the screenshot** — it still only proves what it measured.

Both seams are plain `smoke.sh` env vars, so any other console question can
reuse them: `LCARS_BROWSER_BASEFRESH` (a record to serve) and
`LCARS_BROWSER_CONSOLE_CHECK` (an expectation file). Neither is set by default,
and with both unset `smoke.sh` runs exactly the code it ran before S164.

## Exit codes

| code | meaning |
|---|---|
| `0` | the board painted, with its full stylesheet. **Now look at the screenshot.** |
| `1` | it did not paint — a real failure. The screenshot is a picture of exactly what the browser saw. |
| `3` | it painted, but was **served incomplete** — a same-origin stylesheet did not load, so the screenshot is a picture of a *phantom*, not of the product. |
| `77` | **SKIPPED / INFRASTRUCTURE**, loudly, with the reason named. Never a pass. |

A rig that quietly succeeds when it did nothing is the same disease as the blank
board, so a skip is never `0`.

**And `1` is an accusation against the product, so nothing that is the rig's own
problem may leave through it.** No Chrome, no node, no python3, Chrome never
becoming drivable, a timeout too small to reach a first DOM probe, a driver
crash — all `77`. This rig exists to stop harness trouble being reported as a
product defect; it does not get to do that itself. `1` means the board was
asked, in a real browser, and did not paint.

## Artifacts

Each run gets its own directory (`mktemp -d`, or `LCARS_BROWSER_OUT`):

| file | what it is |
|---|---|
| `board.png` | **the screenshot** — the whole board, all Stage columns |
| `result.json` | card count, column count, status line, card text, page errors, Chrome version |
| `daemon.log` | the daemon's stderr, including the URL it bound |
| `chrome.log` | Chrome's stderr |
| `pids.json` | daemon pid, Chrome pid, daemon port (teardown evidence) |
| `worker-shim.log` | every `claude`/`copilot` invocation. **Should be empty.** |
| `fixture/` | the throwaway `.git/lcars` board the daemon read |

`result.json` reports every browser console error it saw, **with the URL**. Two
are expected on a healthy run and are not defects:

- `POST /api/mission` → **400** — deliberate. `probeWrites()` POSTs an empty body
  precisely to read 400 (write layer active) vs 403 (view-only). See the comment
  above `probeWrites()` in `board.js`.
- `GET /favicon.ico` → **404** — the daemon serves no favicon.

**Anything outside that pair is printed on stdout — on a green run too**, under
`⚠ UNEXPECTED PAGE ERROR(S) ON A GREEN RUN`, without turning the run red. It is
also split out as `pageErrorsUnexpected` in `result.json`. Errors were once
shown only on failure, which meant an uncaught exception on a *passing* board
went unmentioned — the exact false comfort this rig is built against. Telling
the reader "the list is worth a look" is not the same as telling them to look.

`result.json` also carries `servedComplete`, `stylesheets` (each same-origin
`<link>` and whether the browser really built a sheet from it) and `tokenProbe`
(the resolved `--lcars-amber`), which are what exit `3` is decided from.

**Artifacts are kept on purpose** — the screenshot is the deliverable, and a run
you cannot look at afterwards is not evidence. Kept, but **bounded**: each run
prunes older sibling dirs from its own `mktemp` namespace, keeping the newest 5
(`calibrate.sh` keeps 3). Pruning is skipped entirely when you pass
`LCARS_BROWSER_OUT` — then the artifacts are yours to manage.

## Environment

| var | default | why |
|---|---|---|
| `LCARS_BROWSER_CHROME` | the installed `/Applications/Google Chrome.app` binary | never a downloaded Chromium |
| `LCARS_BROWSER_OUT` | fresh `mktemp -d` | where the artifacts land |
| `LCARS_BROWSER_WEB_DIR` | this repo's `web/` | **the calibration seam** — point it at a patched copy |
| `LCARS_BROWSER_EXPECT` | `2` (the fixture's mission count) | visible cards required |
| `LCARS_BROWSER_HEADED=1` | *(headless)* | watch it happen in a real window |
| `LCARS_BROWSER_TIMEOUT` | `30000` | ms to wait for the paint. **Minimum 2000** — below that nothing could be proven, so it is a loud skip, never a verdict |
| `LCARS_BROWSER_BASEFRESH` | *(unset)* | path to a base-freshness record JSON, planted as the stub reporter behind `GET /api/base-freshness` |
| `LCARS_BROWSER_CONSOLE_CHECK` | *(unset)* | path to an expectation JSON — makes the driver open the File console and **measure** its pre-flight line |

### The seam serves the *whole* app

The daemon resolves the shared ADR-007 token stylesheet as
`<web-dir>/../docs/lcars.css` (`server.py`'s `_SHARED_CSS`), so a plain
`cp -R web/` copy has no sibling `docs/`, `/lcars.css` 404s, and **every
`--lcars-*` token disappears** — the title goes yellow-on-yellow, the header
buttons lose their teal pills, the legend swatches vanish. The board still
paints (`board.css` uses `var(--lcars-x, fallback)` throughout), so it still
*passed*, silently. Measured 2026-08-02: every seam run carried a `/lcars.css`
404 nobody was told about.

`smoke.sh` now makes the copy **faithful** — when `LCARS_BROWSER_WEB_DIR` is not
this repo's own `web/`, it places the shared stylesheet at
`<web-dir>/../docs/lcars.css` before serving. This is fixed in the **rig**, not
in `server.py`, deliberately: the daemon is shipped production code and changing
how it resolves the shared sheet has a blast radius well past this rig. And if
the sheet ever fails to load anyway, the run **exits 3 and says so** rather than
leaving a future tester to notice yellow-on-yellow by eye.

## Calibration — prove the rig can still go RED

```bash
bash tests/drives/browser/calibrate.sh     # exits 0 when the rig correctly FAILS
```

A green check that cannot go red is decoration (S162 shipped a warning styled
invisible while a test asserting the CSS rule *existed* stayed green). So this
rig does not get to *claim* it would catch a blank board — it demonstrates it on
demand: `calibrate.sh` copies `web/` to scratch, deletes the `.then(render)`
line from the **copy's** `board.js` — S163 fix round 5's mistake verbatim — and
requires the rig to fail. This repo's own `web/` is never touched.

Measured 2026-08-02: `0 visible of 0 cards in the DOM`, status line stuck on
`loading…`, and a screenshot of an empty black board. Exactly the incident.

Run this whenever you change the rig, and whenever a run's green feels too easy.

## Self-test — the rig's own properties

```bash
bash tests/drives/browser/selftest.sh      # ~2 min, launches Chrome several times
```

Proves: (1) it passes on a healthy board with the real card count, (2) it fails
under calibration, (3) a missing Chrome is a **loud skip**, not a pass, (4) a
screenshot exists at the announced path, (5) no orphan daemon, Chrome or held
port — **on success and on failure**, (6) two back-to-back runs take different
ports, (7) a copy served through the calibration seam is **fully styled**, and
(7b) one that *isn't* exits `3` loudly rather than passing, (8) a harness
failure exits **77 and never accuses the board** — including that a stale
`DevToolsActivePort` is not believed (8b), (9) an unexpected page error is
**surfaced on a green run**, without turning it red.

## Design notes for whoever changes this next

- **Raw CDP, no dependencies.** The driver (`cdp.js`) talks the Chrome DevTools
  Protocol over node's global `WebSocket` (node ≥ 22). That is what makes "one
  command" literally true — no `package.json`, no `node_modules`, no
  "skipped: module not found" mode, which is the mode most likely to turn this
  back into the rig nobody runs. `puppeteer-core` would also have worked; plain
  `puppeteer` is **forbidden** — it downloads its own Chromium, and the entire
  point is to drive the Chrome the captain actually has.
- **No sleep-and-hope.** Every wait is on an observed signal with a deadline:
  the daemon's own "serving at &lt;url&gt;" line, Chrome's `DevToolsActivePort`
  file, `/json/version` answering, then the DOM polled until cards are laid out.
- **`DevToolsActivePort` is read defensively.** Chrome writes it for itself, not
  for us, and reading it naively is a race — measured on a cold headed launch
  (with GoogleUpdater starting), the rig read one port while `chrome.log` showed
  Chrome listening on another. So the file is only believed once its **second
  line** (the `/devtools/...` browser path) has arrived, and only once that port
  actually answers `/json/version`; anything else sends it back to re-read,
  because Chrome may rewrite the file. Note the file has **no trailing
  newline**, so counting lines lies — a finished file reports one.
- **The app is checked for being served WHOLE, by measurement.** Every
  same-origin `<link rel=stylesheet>` must have produced a real `CSSStyleSheet`
  and `--lcars-amber` must resolve on `:root`. Both are read out of the live
  page, never inferred from a log line — the standing lesson here is that a CSS
  rule can test green and never reach the screen.
- **Free ports by construction.** The daemon takes `--port 0` and reports what
  the kernel gave it; Chrome takes `--remote-debugging-port=0` and writes its
  real port into `DevToolsActivePort` inside a throwaway profile. Nothing is
  hardcoded, so runs cannot collide.
- **A throwaway Chrome profile** also means the rig launches its **own** Chrome
  rather than attaching to the captain's — it can never touch their tabs.
- **Teardown from the shell layer.** `smoke.sh` owns both pids and kills them in
  an `EXIT INT TERM` trap, so a crash, a `^C` and a failing assertion all clean
  up identically. A polite `kill` is enough since 78450eb; if you ever see the
  `ignored SIGTERM` warning for the daemon, that is a **regression of that fix**
  — report it, don't work around it.
- **Zero spend is pinned with a PATH shim**, both `claude` and `copilot`, never
  an env var: the daemon's align path can override `LCARS_WORKER_BIN` from a
  *request body*, so the environment is not a safe pin.
- **Not in any automatic suite.** It is a drive rig, invoked deliberately, and it
  lives under `tests/drives/` where `tests/run.sh` (which globs `tests/*.test.sh`)
  cannot pick it up. It is not part of `python3 -m unittest discover -s tests`.
- **The screenshot must show everything.** The Stage columns scroll horizontally
  inside `#board`, so a 1440px shot of a *healthy* board cuts Implement/Verify
  off the right edge — and a tester opening that picture would read "blank". The
  driver measures the board's scroll extent and widens the viewport to it before
  capturing. Evidence that misleads is worse than no evidence.
