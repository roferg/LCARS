"use strict";
/* ═══════════════════════════════════════════════════════════════════════════
 * xo-drive.js — Number One's browser. Zero dependencies, raw CDP, HEADLESS.
 *
 *   node xo-drive.js --url URL --out DIR
 *                    [--actions FILE] [--place-names FILE]
 *                    [--chrome PATH] [--timeout MS] [--max-actions N]
 *                    [--devtools-port N] [--element-cap N]
 *
 * It opens the app Number One is judging, walks it, and leaves behind EVIDENCE:
 * one PNG per shot, and beside every PNG a `.json` readout of what the page
 * actually said (url, title, a visible-text excerpt, the box + computed colour
 * of each named place, a box + computed colour + a couple of cheap DOM facts
 * for EVERY OTHER visible element up to `--element-cap` (default 300, S210),
 * console errors, and the PNG's own pixel statistics) plus a one-line `.txt`
 * caption.
 *
 * WHY NOT tests/drives/browser/cdp.js. That file is 3,900 lines hard-wired to
 * the LCARS board — `.card` polling, `--legend-check`, board-specific paint
 * assertions. It is a board rig, not a driver. This is the product-side sibling
 * the S203 probe's `tests/drives/s203/spike-drive.js` (~190 lines) proved out:
 * same CDP shape, same PNG sampler, same exit-code discipline, none of the
 * board.
 *
 * ── THE CAPTAIN'S FOCUS IS NEVER TAKEN (captain's ruling, 2026-09-13) ──
 * In his words: *"we don't want Number One actually doing something to
 * interrupt the focus of the user on the computer. Want it all done kind of in
 * the background or headless so to speak, even when interacting with UI and the
 * web browser."*
 *
 * So this driver is **headless, always, with no way to ask it not to be**.
 * There is deliberately NO `--headed` flag and NO env var that flips it — not
 * even `LCARS_BROWSER_HEADED`, which is a TEST affordance for the board's
 * eyeball legs and must never become a product path. A headed Chrome raises a
 * window and steals focus on macOS; a headless one screenshots exactly as well.
 * The guarantee is structural rather than conditional precisely so it cannot be
 * turned off by an environment nobody audited, and so a test can assert it by
 * reading the argv this file builds.
 *
 * It also opens nothing FOR the captain: no `open`, no tab in his own browser,
 * no file handed to a viewer. Chrome runs in a throwaway `--user-data-dir` and
 * is TERMed by pid on the way out — its own pid, and only its own.
 *
 * ── EXIT CODES (cdp.js's discipline: rig trouble is never an accusation) ──
 *   0   the app painted and every requested shot was taken
 *   1   PRODUCT failure — the app never laid out, or a shot came back flat
 *   3   INCOMPLETE — some shots were taken, some could not be (a missing
 *       selector, an action that found nothing). The evidence that exists is
 *       still written; the caller decides what that is worth.
 *  77   INFRASTRUCTURE — no Chrome, devtools never answered, a CDP timeout.
 *       Never the app's fault, never scored against it.
 *
 * ── THE ACTION LIST ──
 * `--actions FILE` is a JSON array (or `{"actions":[…]}`), each entry one of:
 *   {"navigate":"URL"}                 go somewhere
 *   {"click":"SELECTOR"}               click the first match
 *   {"type":"SELECTOR","text":"…"}     focus and type
 *   {"press":"ArrowRight"}             tap a real key (see PRESS below)
 *   {"press":"ArrowRight","hold":250}  HOLD it down 250ms, then let go
 *   {"press":"w","selector":"#board","times":5,"modifiers":["Shift"]}
 *   {"wait":800}                       wait ms (capped)
 *   {"screenshot":"name"}              full-page shot called `name`
 *   {"screenshot":"name","selector":"#x"}   clipped to that element
 * At most --max-actions (default 12) entries: a look is a look, not a session.
 * ═══════════════════════════════════════════════════════════════════════════ */

const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");
const { spawn } = require("child_process");

/* ── argv ────────────────────────────────────────────────────────────────── */
function arg(n, d) {
  const i = process.argv.indexOf("--" + n);
  return i >= 0 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : d;
}
function has(n) { return process.argv.indexOf("--" + n) >= 0; }

const URL_ = arg("url");
const OUT = arg("out");
const ACTIONS_FILE = arg("actions", "");
const PLACES_FILE = arg("place-names", "");
const CHROME = arg("chrome", process.env.LCARS_BROWSER_CHROME || "");
const TIMEOUT = parseInt(arg("timeout", "30000"), 10) || 30000;
const MAX_ACTIONS = parseInt(arg("max-actions", "12"), 10) || 12;
const ATTACH_PORT = arg("devtools-port", "");
const PREFIX = arg("prefix", "shot");
/* ── THE PARTS PASS (S220 part B) ───────────────────────────────────────────
 * `--parts-out <file>` asks for the page's PARTS — see the PARTS reader below
 * — written to that file, with a 2x crop of each one beside the ordinary
 * shots. It is how the drawing and the build are read the same way, by the
 * same code, at the same scale, so the two crops can go side by side.
 * `--parts-crop-cap` bounds how many crops one page pays for; the parts
 * themselves are all recorded either way. */
const PARTS_OUT = arg("parts-out", "");
const PARTS_CAP = parseInt(arg("parts-cap", "80"), 10) || 80;
const PARTS_CROP_CAP = parseInt(arg("parts-crop-cap", "16"), 10) || 16;
/* ── WALK THE JOURNEY, DON'T TELEPORT (S220 part F) ─────────────────────────
 * `--journey <file>` hands the driver a DECLARED JOURNEY — screen, action,
 * next screen — built from the record (the drawing's screen order, the PRD's
 * own steps) by xo-journey.py. The driver WALKS it: it clicks the control the
 * step names, types where the step says to type, and photographs each screen
 * it arrives on.
 *
 * WHY THE HARNESS WALKS IT AND NOT THE MODEL. Measured, twice, on the same
 * case with the same code: one look clicked its way through, the next jumped
 * to four addresses in a row and never touched a control. A walk left to the
 * model's discretion is a lottery, and a lottery cannot be a proof. So the
 * steps are executed here, deterministically, and what actually happened —
 * every click, every typing, every step that could not be reached — is
 * written to `--walk-out` as the record the report and the score read. */
const JOURNEY_FILE = arg("journey", "");
const WALK_OUT = arg("walk-out", "");
/* ── EVERY VISIBLE ELEMENT, NOT ONLY THE NAMED ONES (S210) ──────────────────
 * Before this the readout only ever carried a box for a PLACE NAME — an
 * element the drawing never mentions had no geometry at all, so "these two
 * buttons are smooshed together" was literally unmeasurable. `--element-cap`
 * bounds how many of them the readout carries (a dense page cannot blow up
 * the readout), and if the page has more than that the readout SAYS so — the
 * count captured and the count dropped — rather than truncating in silence. */
const ELEMENT_CAP = (() => {
  const v = parseInt(arg("element-cap", "300"), 10);
  return isFinite(v) && v > 0 ? v : 300;
})();
/* ── THE SHOT HAS TO BE SHARP (captain's ruling, 2026-09-13) ────────────────
 * In his words: *"the images are very pixely"*.
 *
 * Every shot up to S203 was captured at device scale factor 1, so a crop of
 * 665 CSS px was a 665-PIXEL png. The captain reads the walkthrough on a phone
 * whose column is ~334 CSS px across but ~1000 physical pixels deep; a 665 px
 * png is UPSCALED to fill it, and upscaling is what "pixely" looks like.
 *
 * So the browser is told to render at a real device scale factor and the same
 * 665 CSS px of content comes back as a ~1330-pixel png that DOWNSAMPLES on
 * his phone instead of stretching. 2 is the default because it clears a 3x
 * phone at the half-size the page lays a shot out at; --scale 3 costs a little
 * more png and is there for a caller who wants it. Clamped to 1..4: a scale of
 * 0 is a blank image and a scale of 9 is a 16 MB page.
 *
 * THIS IS NOT THE HEADLESS SWITCH. It changes how many pixels the raster has,
 * never whether a window exists; chromeArgv is still the only place the
 * browser's flags are built and `--headless=new` is still unconditional there. */
const SCALE = (() => {
  const v = parseFloat(arg("scale", "2"));
  if (!isFinite(v) || v <= 0) return 2;
  return Math.min(4, Math.max(1, v));
})();

/* Codes as constants so the tests can name them and the code cannot drift. */
const EXIT_OK = 0, EXIT_PRODUCT = 1, EXIT_INCOMPLETE = 3, EXIT_INFRA = 77;

if (!URL_ || !OUT) {
  console.error("xo-drive.js: --url and --out are required");
  process.exit(EXIT_INFRA);
}
fs.mkdirSync(OUT, { recursive: true });

class Infra extends Error {}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ── inputs ──────────────────────────────────────────────────────────────── */
function readPlaceNames(file) {
  if (!file) return [];
  let raw;
  try { raw = fs.readFileSync(file, "utf8"); }
  catch (_) { throw new Infra("cannot read --place-names " + file); }
  // Three shapes are all legal, because three producers exist: the criteria
  // file writes {"placeNames":[…]}, a hand-rolled list writes a bare array, and
  // `mission_mockup_place_names` prints them space-separated.
  try {
    const doc = JSON.parse(raw);
    if (Array.isArray(doc)) return doc.map(String);
    if (doc && Array.isArray(doc.placeNames)) return doc.placeNames.map(String);
  } catch (_) { /* fall through to the plain-text shape */ }
  return raw.split(/[\s,]+/).map((s) => s.trim()).filter(Boolean);
}

function readActions(file) {
  if (!file) return [];
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (_) { throw new Infra("cannot read --actions " + file + " as JSON"); }
  let list = Array.isArray(doc) ? doc : (doc && Array.isArray(doc.actions) ? doc.actions : null);
  if (!list) throw new Infra("--actions must be a JSON array (or {\"actions\": […]})");
  return list;
}

/* THE DECLARED JOURNEY (S220 part F). A missing or unreadable file means no
 * walk — never a dead look: a mission whose record says nothing about a flow
 * is looked at exactly as it always was. */
function readJourney(file) {
  if (!file) return { steps: [], entry: [] };
  let doc;
  try { doc = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (_) { return { steps: [], entry: [] }; }
  const list = Array.isArray(doc) ? doc : (doc && Array.isArray(doc.steps) ? doc.steps : []);
  return { steps: list.filter((s) => s && typeof s === "object").slice(0, 24),
           entry: (doc && Array.isArray(doc.entry) ? doc.entry : []).slice(0, 6) };
}

/* ── the PNG sampler ─────────────────────────────────────────────────────────
 * A screenshot that is ONE FLAT COLOUR is not a render, and a driver that
 * cannot tell the difference will happily hand a worker a blank frame to score
 * an app on. So every PNG is decoded here (node's own zlib, no dependency) and
 * reported: distinct colours, the dominant colour and its share, the mean
 * channels. `painted` is the honest summary of those numbers.
 * Lifted, unchanged in substance, from the S203 probe that proved it.
 *
 * ── THE INK FLOOR MOVES WITH THE SCALE (2026-09-13) ──
 * `painted` used to be `distinct > 8 && nonDominantFraction > 0.01`, a floor
 * calibrated on 1x rasters. Capturing at a real device scale factor makes the
 * SAME element measure LESS ink, because at 1x a 14 px glyph is mostly
 * antialiasing fringe and every fringe pixel counts as non-dominant, while at
 * 2x the strokes resolve and the fraction falls towards the true coverage.
 * Measured on the S203 rig's own `#task-list` — three lines of text in a wide
 * box — nonDominantFraction went 0.0105 (1x) → 0.0081 (2x) → 0.0073 (3x) with
 * the picture unchanged and plainly legible. A fixed 0.01 floor therefore calls
 * a perfectly painted element FLAT the moment the shot gets sharper, and a flat
 * shot is exit 1: an ACCUSATION AGAINST THE APP for something the driver did.
 * So the floor is divided by the scale the shot was taken at. A genuinely blank
 * frame is still caught by both halves — one colour is one colour at any
 * density, and `distinctColours > 8` does not move at all. */
const FLAT_FLOOR_AT_1X = 0.01;
function pngStats(buf, scale) {
  const floor = FLAT_FLOOR_AT_1X / Math.max(1, scale || 1);
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) throw new Infra("not a PNG");
  let off = 8, w = 0, h = 0, depth = 0, ctype = -1, interlace = 0;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off), type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.slice(off + 8, off + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); depth = data[8]; ctype = data[9]; interlace = data[12]; }
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    off += 12 + len;
  }
  if (depth !== 8 || interlace !== 0 || (ctype !== 2 && ctype !== 6)) {
    throw new Infra("unsupported PNG (depth " + depth + ", ctype " + ctype + ")");
  }
  const bpp = ctype === 6 ? 4 : 3, stride = w * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(h * stride);
  let p = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[p++]; const line = raw.slice(p, p + stride); p += stride;
    const cur = out.slice(y * stride, (y + 1) * stride);
    const prev = y ? out.slice((y - 1) * stride, y * stride) : Buffer.alloc(stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
      let v = line[x];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += ((a + b) >> 1);
      else if (f === 4) {
        const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      }
      cur[x] = v & 0xff;
    }
  }
  const counts = new Map(); let sr = 0, sg = 0, sb = 0, n = 0;
  // THE GRID (S222 fix 1). Every statistic above is a single number over the
  // WHOLE frame, so it answers "did anything change" and can never answer "how
  // much". The idle control needs a magnitude — the keyed change has to be
  // compared against what this build does on its own — so the frame is also
  // reduced to a GRID_N x GRID_N block of average colours. It is the same pass
  // and the same samples; nothing extra is decoded.
  const gsum = new Float64Array(GRID_N * GRID_N * 3);
  const gcnt = new Float64Array(GRID_N * GRID_N);
  for (let y = 0; y < h; y += 2) for (let x = 0; x < w; x += 2) {
    const o = y * stride + x * bpp, r = out[o], g = out[o + 1], bl = out[o + 2];
    const k = (r << 16) | (g << 8) | bl;
    counts.set(k, (counts.get(k) || 0) + 1);
    sr += r; sg += g; sb += bl; n++;
    const gi = (Math.min(GRID_N - 1, (y * GRID_N / h) | 0) * GRID_N)
             + Math.min(GRID_N - 1, (x * GRID_N / w) | 0);
    gsum[gi * 3] += r; gsum[gi * 3 + 1] += g; gsum[gi * 3 + 2] += bl; gcnt[gi]++;
  }
  const grid = new Uint8Array(GRID_N * GRID_N * 3);
  for (let i = 0; i < GRID_N * GRID_N; i++) {
    const c = gcnt[i] || 1;
    grid[i * 3] = Math.round(gsum[i * 3] / c);
    grid[i * 3 + 1] = Math.round(gsum[i * 3 + 1] / c);
    grid[i * 3 + 2] = Math.round(gsum[i * 3 + 2] / c);
  }
  let topKey = 0, topN = 0;
  for (const [k, v] of counts) if (v > topN) { topN = v; topKey = k; }
  const hex = (k) => "#" + k.toString(16).padStart(6, "0");
  const stats = {
    width: w, height: h, sampled: n,
    distinctColours: counts.size,
    dominantColour: hex(topKey),
    dominantFraction: +(topN / n).toFixed(4),
    nonDominantFraction: +(1 - topN / n).toFixed(4),
    mean: { r: Math.round(sr / n), g: Math.round(sg / n), b: Math.round(sb / n) },
    painted: counts.size > 8 && (1 - topN / n) > floor,
    inkFloor: +floor.toFixed(5),
  };
  // NOT ENUMERABLE, so it never reaches readout.json. This object is written
  // straight into the record for every shot a look takes; 3072 numbers per
  // shot would swamp the file a person reads, and the grid is machinery, not
  // a finding. The two distances computed FROM it are what gets recorded.
  Object.defineProperty(stats, "grid", { value: grid, enumerable: false });
  return stats;
}

/* HOW MUCH OF THE PICTURE CHANGED (S222 fix 1) — the fraction of grid cells
 * whose average colour moved by more than GRID_TOL in any channel. Returns
 * null when either frame has no grid (a failed shot, a different size), which
 * the caller must treat as "no control", never as zero. */
const GRID_N = 32;
const GRID_TOL = 8;
// The idle control's window is the keyed window's own length, floored so a
// zero-hold press still watches for a moment and capped so a pathological
// keyed step cannot double a whole look's runtime.
const IDLE_WINDOW_CAP_MS = 10000;
// Two grid cells out of GRID_N x GRID_N — the floor a still build's keyed
// change must clear. See the margin note at the verdict.
const IDLE_MARGIN = 2 / (GRID_N * GRID_N);
// A fraction of the picture, said the way a person reads it.
function fmtFrac(v) {
  if (typeof v !== "number") return "an unknown amount";
  if (v <= 0) return "none";
  return v < 0.001 ? "under 0.1%" : (v * 100).toFixed(1) + "%";
}
function pictureDistance(a, b) {
  const ga = a && a.grid, gb = b && b.grid;
  if (!ga || !gb || ga.length !== gb.length || !ga.length) return null;
  const cells = ga.length / 3;
  let moved = 0;
  for (let i = 0; i < cells; i++) {
    const o = i * 3;
    if (Math.abs(ga[o] - gb[o]) > GRID_TOL ||
        Math.abs(ga[o + 1] - gb[o + 1]) > GRID_TOL ||
        Math.abs(ga[o + 2] - gb[o + 2]) > GRID_TOL) moved++;
  }
  return +(moved / cells).toFixed(5);
}

/* ── Chrome, headless, ours, and ours alone ──────────────────────────────────
 * The argv is built by ONE function so a test can read it back and assert
 * `--headless` is in it with no branch that could remove it. */
const CHROME_CANDIDATES = [
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
];
function findChrome() {
  if (CHROME) return fs.existsSync(CHROME) ? CHROME : null;
  for (const c of CHROME_CANDIDATES) if (fs.existsSync(c)) return c;
  return null;
}
function chromeArgv(port, userDataDir) {
  // HEADLESS IS NOT CONDITIONAL. See the header. Nothing in this function reads
  // the environment, so nothing in the environment can raise a window.
  return [
    "--headless=new",
    "--remote-debugging-port=" + port,
    "--user-data-dir=" + userDataDir,
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-extensions",
    "--disable-gpu",
    "--hide-scrollbars",
    "--window-size=1440,900",
    "about:blank",
  ];
}
if (has("print-chrome-argv")) {                 // the focus test's read surface
  console.log(JSON.stringify(chromeArgv(0, "/tmp/x")));
  process.exit(EXIT_OK);
}

let CHROME_PROC = null, CHROME_UDD = "";
async function launchChrome() {
  const bin = findChrome();
  if (!bin) throw new Infra("no Chrome — set $LCARS_BROWSER_CHROME or --chrome");
  CHROME_UDD = fs.mkdtempSync(path.join(os.tmpdir(), "lcars-xo-chrome."));
  const port = 9000 + Math.floor(Math.random() * 1000);
  CHROME_PROC = spawn(bin, chromeArgv(port, CHROME_UDD), { stdio: "ignore", detached: false });
  CHROME_PROC.on("error", () => { CHROME_PROC = null; });
  return String(port);
}
/* A SYNCHRONOUS sleep, because teardown has to work from an `exit` handler,
 * where nothing async will ever run again. Atomics.wait on a throwaway buffer
 * blocks this thread and nothing else. */
function sleepSync(ms) {
  try { Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms); }
  catch (_) { const t = Date.now(); while (Date.now() - t < ms) {} }
}
function alive(pid) { try { process.kill(pid, 0); return true; } catch (_) { return false; } }

function stopChrome() {
  // ONLY the pid we started. There are long-lived Chromes on this machine that
  // are not ours and a pkill would be a wrecking ball.
  //
  // TERM, THEN WAIT, THEN KILL (fix round 1, D2). A single TERM and an immediate
  // process.exit was not teardown, it was a request: a Chrome wedged badly
  // enough to time out CDP is exactly the Chrome that ignores a polite TERM, and
  // the tester watched one live on for thirteen minutes after a LOW was written.
  // The profile dir cannot be removed until the browser has actually let go of
  // it either — 21 stray `lcars-xo-chrome.*` dirs on that machine are what
  // removing it too early looks like.
  const pid = CHROME_PROC && CHROME_PROC.pid;
  CHROME_PROC = null;
  if (pid) {
    try { process.kill(pid, "SIGTERM"); } catch (_) {}
    for (let i = 0; i < 30 && alive(pid); i++) sleepSync(100);   // up to 3s
    if (alive(pid)) { try { process.kill(pid, "SIGKILL"); } catch (_) {} sleepSync(200); }
  }
  if (CHROME_UDD) { try { fs.rmSync(CHROME_UDD, { recursive: true, force: true }); } catch (_) {} CHROME_UDD = ""; }
}

/* EVERY WAY OUT OF THIS PROCESS TEARS THE BROWSER DOWN (fix round 1, D2).
 * `stopChrome` was called from the paths that remembered to — so a TERM from
 * xo.sh's stand-down, or from the captain's own shell, killed node and left a
 * headless Chrome and its profile dir behind with nothing to reap them. The
 * `exit` handler covers every ordinary return as well, which is why the calls
 * already written inline are now belt to this brace (stopChrome is idempotent).
 *
 * NOTHING HERE TOUCHES HEADLESSNESS. chromeArgv is still the only place the
 * browser's flags are built and `--headless=new` is still unconditional in it. */
let TORN_DOWN = false;
function teardown() { if (TORN_DOWN) return; TORN_DOWN = true; try { stopChrome(); } catch (_) {} }
process.on("exit", teardown);
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(sig, () => { teardown(); process.exit(EXIT_INFRA); });
}

/* ── minimal CDP over node's global WebSocket ────────────────────────────── */
async function connect(port) {
  let ver;
  for (let i = 0; i < 60; i++) {
    try {
      ver = await (await fetch("http://127.0.0.1:" + port + "/json/version", { signal: AbortSignal.timeout(2000) })).json();
      if (ver.webSocketDebuggerUrl) break;
    } catch (_) {}
    await sleep(250);
  }
  if (!ver || !ver.webSocketDebuggerUrl) throw new Infra("chrome devtools never answered on port " + port);
  const ws = new WebSocket(ver.webSocketDebuggerUrl);
  await new Promise((res, rej) => {
    ws.onopen = res;
    ws.onerror = () => rej(new Infra("devtools websocket refused"));
    setTimeout(() => rej(new Infra("devtools websocket timeout")), 10000);
  });
  let id = 0; const waiting = new Map(); const events = [];
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && waiting.has(msg.id)) {
      const { res, rej } = waiting.get(msg.id); waiting.delete(msg.id);
      msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
    } else if (msg.method) events.push(msg);
  };
  const send = (method, params, sessionId) => new Promise((res, rej) => {
    const mid = ++id; waiting.set(mid, { res, rej });
    ws.send(JSON.stringify(sessionId
      ? { id: mid, method, params: params || {}, sessionId }
      : { id: mid, method, params: params || {} }));
    setTimeout(() => { if (waiting.has(mid)) { waiting.delete(mid); rej(new Infra("CDP timeout on " + method)); } }, TIMEOUT);
  });
  return { ws, send, events };
}

/* The page reader — ONE evaluate, returning facts and never opinions.
 *
 * `elements` is the S210 addition: a box, a computed colour and a couple of
 * cheap DOM facts (is it interactive, does its own content overflow it) for
 * EVERY VISIBLE element on the page — not just the drawing's named places.
 * Geometry is arithmetic; nothing here decides whether two things are too
 * close together. That decision is xo-observe.py's, done AFTER the browser
 * has closed, from exactly these numbers.
 *
 * S212 ADDS THREE FACTS, AND IT ADDS THEM HERE ON PURPOSE. Driven live, the
 * observations pass cried wolf on correct UI — a chip's own remove button, a
 * badge on a button corner, a box that is MEANT to scroll. Every one of those
 * is settled by something THE BROWSER ALREADY KNOWS and nobody wrote down:
 *
 *   `path`            where the element sits in the DOM, as the chain of
 *                     child indices from the root. Two elements are nested
 *                     when one path is the other's prefix — a STRUCTURAL
 *                     fact, recorded. It would have been tempting to work
 *                     nesting out downstream from the boxes ("A's box
 *                     contains B's, so A is B's parent"), and that is exactly
 *                     the inference this project has been beaten by three
 *                     times: a badge sits geometrically inside its button,
 *                     and so does a genuinely misplaced element that merely
 *                     overlaps one. Boxes cannot tell those apart. The DOM
 *                     can, and it is right here when we look.
 *   overflowStyleX/Y  the COMPUTED overflow property — "visible", "hidden",
 *                     "auto", "scroll". Deliberately NOT folded into the
 *                     existing `overflowX`/`overflowY`, which are pixel
 *                     amounts of spill and are read downstream today.
 *   textOverflow      the COMPUTED text-overflow property — "clip" or
 *                     "ellipsis". `overflow: hidden` says the text is cut
 *                     off; this says whether cutting it off was the POINT.
 *                     The same shape of fact as overflowStyleX/Y, one field on.
 *   whiteSpace        the COMPUTED white-space property. An ellipsis only
 *                     ever renders on a single non-wrapping line, so this is
 *                     what says whether the field above can do anything at
 *                     all — a base class setting `text-overflow: ellipsis`
 *                     on everything is how people write CSS.
 *   seen              whether the element is actually the thing painted at
 *                     its own position, and
 *   hiddenBy          why not, when it is not: "clipped" (an ANCESTOR won the
 *                     hit test — its own scroll container has carried it away)
 *                     or "covered" (something else is painted on top, and that
 *                     something is solid enough to actually hide it). Two
 *                     different causes that used to be one silent boolean;
 *                     recorded apart because only one of them should ever be
 *                     bought by a see-through overlay.
 *
 * Still facts, still no opinions: every one of them is recorded and none of
 * them is acted on until the browser has closed. */
const READ = (places, cap) => `(function () {
  var ids = ${JSON.stringify(places)};
  var CAP = ${JSON.stringify(cap)};
  function box(el) { var r = el.getBoundingClientRect(); return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }; }
  // WHERE IT SITS IN THE DOM — the chain of child indices from the root, so
  // "is one of these inside the other" is a prefix test on a string the
  // BROWSER wrote, not a guess made later from two rectangles.
  function pathOf(el) {
    var parts = [], n = el, guard = 0;
    while (n && n.nodeType === 1 && guard++ < 100) {
      var i = 0, sib = n;
      while ((sib = sib.previousElementSibling)) i++;
      parts.push(i);
      n = n.parentElement;
    }
    return parts.reverse().join(".");
  }
  // ── WHAT THE PAGE DECLARES ABOUT ITS OWN CONTROLS (S213 fix round 1) ──
  //
  // Two detectors used to GUESS at intent from the boxes: crowding decided
  // that a gap matching its neighbours' rhythm was deliberate, and the
  // misalignment check decided a group was a column because no two members
  // shared a horizontal band. Guesses, both, and both were wrong in the real
  // world. A browser already KNOWS the answers, because the page says them out
  // loud — so they are read here, as facts, and carried through to the
  // observations pass exactly like a box or a colour.
  //
  // 'segment' — the SEGMENTED CONTROL this control belongs to, if any: a
  // 'role="tablist"' tab bar, a 'role="toolbar"', a 'role="radiogroup"' or
  // '<fieldset>' of radios, a menubar, an explicit 'role="group"'. Sibling
  // controls inside one of those are MEANT to sit flush against each other
  // (the captain's ruling, 2026-09-17), so two of them touching is design, not
  // crowding. It is a string identifying the group — the declaring ancestor's
  // own path plus what it declared — so two controls are in the same segmented
  // control when, and only when, the two strings are equal.
  var SEGMENT_ROLE = { tablist: 1, toolbar: 1, radiogroup: 1, menubar: 1, group: 1 };
  var MEMBER_ROLE = { tab: 1, radio: 1, menuitemradio: 1, option: 1 };
  function segmentOf(el) {
    var r = (el.getAttribute("role") || "").toLowerCase();
    // The control saying it for itself: a tab, a radio, or anything carrying
    // aria-selected is one of a set by its own declaration.
    var member = !!MEMBER_ROLE[r] || el.hasAttribute("aria-selected") ||
      (el.tagName === "INPUT" && (el.getAttribute("type") || "").toLowerCase() === "radio");
    var n = el.parentElement, hops = 0;
    while (n && n.nodeType === 1 && hops++ < 6) {
      var nr = (n.getAttribute("role") || "").toLowerCase();
      if (SEGMENT_ROLE[nr]) return pathOf(n) + "|" + nr;
      if (n.tagName === "FIELDSET") return pathOf(n) + "|fieldset";
      n = n.parentElement;
    }
    // No container declared itself, but the controls did: their shared parent
    // is the bar, and what makes it one is that they all say so.
    return member && el.parentElement ? pathOf(el.parentElement) + "|members" : null;
  }
  // HOW MUCH OF WHAT IS UNDERNEATH SURVIVES A COVER. Anything at all can be
  // laid over a page — a modal backdrop, a drag layer, a toast container, a
  // bare click-catcher — and a hit test alone cannot tell a sheet of black
  // from a sheet of nothing: both win it. What separates them is how solid
  // the cover actually paints, and the browser already knows: the alpha of
  // its background colour, times its opacity — which is INHERITED, so a
  // cover whose own opacity is 1 inside a half-faded wrapper is still half
  // see-through and the whole ancestor chain has to be multiplied out.
  //
  // ── THE RULE EVERYTHING BELOW OBEYS (captain's ruling, S212 round 4) ──
  //
  //   AN ELEMENT MAY BE RECORDED AS NOT-SEEN ONLY WHERE HIDING WAS
  //   POSITIVELY ESTABLISHED — an ancestor won the hit test (it is genuinely
  //   clipped away by its own scroll container), or a non-ancestor cover was
  //   MEASURED and found opaque. Everything else is SEEN, and gets measured.
  //
  // A colour that cannot be parsed, a background image whose paint cannot be
  // bounded, a filter nobody here understands: every one of those now means
  // "I could not establish that this is hidden, so I will look at it."
  //
  // WHY, because this is the argument three rounds of authors got backwards
  // and the comment that used to sit here got backwards with them. THE
  // FAILURE MODE OF THIS FEATURE IS SILENCE, NOT NOISE. A false complaint is
  // right there on the screen where the captain can see it and say it is
  // wrong. A false silence he never finds out about — he cannot tell "it
  // looked and there was nothing" from "it never looked", and these covers
  // are position:fixed inset:0 in every real application, so what goes quiet
  // is the whole page. He accepted the cost of the occasional wrong
  // complaint, knowingly, to get that.
  //
  // Three authors wrote a fallback here believing it unreachable and three
  // were wrong: no alpha measured at all (round 1, so ANY overlay silenced
  // the page), any background-image assumed solid (round 2, so ANY gradient
  // did), any unparseable colour assumed solid (round 3 — which is how a 30%
  // dim written as oklch() / lab() / color-mix() / color(srgb …) silenced a
  // whole page while the identical dim written as rgba() did not). Arguing a
  // branch is unreachable is not the safeguard. WHICH WAY IT FAILS is.

  // THE ALPHA OF A COLOUR — or null when it cannot be measured. A SENTINEL
  // rather than a number, deliberately, so that no caller can quietly read
  // "I do not know" as "solid" the way round 3's "return 1" did: null has to
  // be handled on purpose or the arithmetic breaks loudly.
  //
  // And most of what round 3 gave up on is genuinely READABLE. Every CSS
  // colour function states its alpha after a "/" — oklch(0 0 0 / 0.3),
  // color(srgb 0 0 0 / 0.3), lab(0 0 0 / 0.3) — and is fully opaque when it
  // states none. That is a fact about the syntax, not a guess. So parse what
  // can be parsed, AND make what still cannot mean "look anyway".
  var COLOUR_FN = /^(rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)$/i;
  function alphaAfterSlash(args) {
    var i = args.lastIndexOf("/");
    if (i < 0) return 1;                     // no alpha channel stated: opaque
    var t = args.slice(i + 1).trim();
    var a = parseFloat(t);
    if (isNaN(a)) return null;               // an alpha is stated and unreadable
    return t.indexOf("%") >= 0 ? a / 100 : a;
  }
  function bgAlpha(colour) {
    if (!colour) return 0;
    var c = colour.trim();
    if (c.toLowerCase() === "transparent") return 0;
    var m = /^rgba?\\(([^)]*)\\)$/.exec(c);
    if (m) {
      var parts = m[1].split(/[,/ ]+/).filter(function (p) { return p !== ""; });
      // THE ONE FALLBACK IN THIS FUNCTION THAT IS MEASURED RATHER THAN
      // ASSUMED, AND SO STAYS A 1: rgb(0,0,0) carries no alpha channel at
      // all, and a colour with no alpha channel is genuinely opaque.
      if (parts.length < 4) return 1;
      var a = parseFloat(parts[3]);
      if (isNaN(a)) return null;
      return parts[3].indexOf("%") >= 0 ? a / 100 : a;
    }
    var f = /^([a-z-]+)\\((.*)\\)$/i.exec(c);
    if (!f || !COLOUR_FN.test(f[1])) return null;   // nothing established
    return alphaAfterSlash(f[2]);
  }
  function effectiveOpacity(el) {
    var o = 1, n = el, guard = 0;
    while (n && n.nodeType === 1 && guard++ < 100) {
      var v = parseFloat(getComputedStyle(n).opacity);
      if (!isNaN(v)) o *= v;
      n = n.parentElement;
    }
    return o;
  }
  // WHAT A BACKGROUND IMAGE CAN PAINT AT ITS DARKEST — an upper bound on
  // anything it can put on the screen, or null when there is no bound to be
  // had. A gradient is not an unknown: it STATES its own colour stops, and
  // the strongest of them bounds it. A sheet whose every stop is alpha 0
  // paints not one pixel and hides nothing; a decorative vignette topping
  // out at 0.25 is a decoration, not a lid.
  //
  // ONE DELIBERATE EXCEPTION, and the tester endorsed it: a real raster
  // url(...) still reads as solid. A picture genuinely does paint something,
  // and its pixels are not in computed style to be measured — unlike a
  // gradient, there is a real reason to believe it covers. Everything else
  // that cannot be bounded — a paint() worklet, a stop in a syntax nobody
  // has written yet — now means LOOK, where round 2 and round 3 both made
  // it mean silence.
  var COLOUR_TOKEN = /\\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\\([^()]*\\)/gi;
  function imageStrength(v) {
    if (!v || v === "none") return 0;
    if (/url\\(/i.test(v)) return 1;         // a real picture — it really paints
    var stops = v.match(COLOUR_TOKEN);
    if (!stops) return null;                 // nothing measurable in it at all
    var max = 0;
    for (var i = 0; i < stops.length; i++) {
      var a = bgAlpha(stops[i]);
      if (a === null) return null;           // one unreadable stop, so no bound
      if (a > max) max = a;
    }
    return max;
  }
  // A BACKDROP FILTER ONLY HIDES WHEN IT DOES SOMETHING THAT CAN BE SHOWN TO
  // HIDE. blur(8px) really does destroy what is behind it and must keep
  // buying silence — a glass modal is genuinely unreadable through.
  // blur(0px), and every other identity value, has no visual effect
  // whatsoever and must buy none.
  //
  // ROUND 4 REVERSED THE UNRECOGNISED CASE. It used to be assumed to act,
  // "because an unknown filter is far more likely to be a real effect than a
  // no-op" — which may even be true, and is still the wrong way round under
  // the rule above: likely-to-act is not ESTABLISHED to hide, and the price
  // of being wrong is a silent page. The identity table itself was proven
  // clean against twelve no-op forms, so what is recognised is trustworthy;
  // only the unrecognised changed hands, and an unrecognised function now
  // contributes nothing either way rather than silencing the page alone.
  //
  // ONE EXCEPTION KEPT ON PURPOSE — url(#…), an SVG filter — and here is the
  // why, since keeping it needs one: an SVG filter is an arbitrary program
  // over the pixels behind it, and feFlood on its own paints an opaque
  // sheet. Nothing in computed style bounds what it does. That is the same
  // case as the raster url(...) background above — a real reason to believe
  // it covers — and not the same case as a function name we merely have not
  // heard of.
  var IDENTITY = { blur: 0, grayscale: 0, sepia: 0, invert: 0, opacity: 1,
                   brightness: 1, contrast: 1, saturate: 1, "hue-rotate": 0 };
  function filterHides(v) {
    if (!v || v === "none") return false;
    if (/url\\(/i.test(v)) return true;      // an SVG filter — see above
    var fns = v.match(/[a-z-]+\\([^)]*\\)/gi);
    if (!fns) return false;                  // unreadable: nothing established
    var hides = false;
    for (var i = 0; i < fns.length; i++) {
      var m = /^([a-z-]+)\\((.*)\\)$/i.exec(fns[i]);
      if (!m) continue;                      // unreadable token
      var name = m[1].toLowerCase();
      if (!(name in IDENTITY)) continue;     // unrecognised: establishes nothing
      var n = parseFloat(m[2]);
      if (isNaN(n)) continue;
      if (m[2].indexOf("%") >= 0) n /= 100;
      if (n !== IDENTITY[name]) hides = true;
    }
    return hides;                            // only a RECOGNISED, real effect
  }
  function coverStrength(el) {
    var cs = getComputedStyle(el);
    // null from either measurement means "hiding could not be established",
    // and that contributes NOTHING. It must never be folded in as if it were
    // a 1 — that single substitution is round 3's whole defect.
    var strength = 0;
    var a = bgAlpha(cs.backgroundColor);
    if (a !== null && a > strength) strength = a;
    var img = imageStrength(cs.backgroundImage);
    if (img !== null && img > strength) strength = img;
    if (filterHides(cs.backdropFilter || cs.webkitBackdropFilter)) strength = 1;
    return strength * effectiveOpacity(el);
  }
  // Past this much, the page underneath is gone. Below it you can still read
  // what is there — the ordinary modal backdrop is 0.3–0.6 and is MEANT to
  // dim, not to hide. A backdrop drawn to actually hide the page is opaque.
  var HIDE_AT = 0.85;
  // CAN IT ACTUALLY BE SEEN. visible() below already covers display,
  // visibility and the outer viewport; this covers the two it cannot — an
  // ancestor's scroll having carried the element out of its own container,
  // and something solid painted on top of it. Both are one question: is
  // this element (or its own content) what is painted where it says it is?
  // Sampled at the centre of the part of the box that is inside the
  // viewport, then at four inset corners, so a control that is merely
  // half-covered still counts as seen.
  //
  // Returns WHY, not just whether: "seen", "clipped" (an ancestor won), or
  // "covered" (a solid non-ancestor won). Those two are not the same fault
  // and must not buy the same silence.
  function seenAt(el, b, s) {
    // An element with pointer-events:none can never be returned by a hit
    // test, so a miss proves nothing about it. Say nothing rather than
    // wrongly calling it hidden — quietening a real fault is the worse error.
    if (s.pointerEvents === "none") return "seen";
    var vw = window.innerWidth || 0, vh = window.innerHeight || 0;
    var x1 = Math.max(0, b.x), y1 = Math.max(0, b.y);
    var x2 = Math.min(vw, b.x + b.w), y2 = Math.min(vh, b.y + b.h);
    if (x2 <= x1 || y2 <= y1) return "offscreen";
    var ix = Math.min(4, (x2 - x1) / 4), iy = Math.min(4, (y2 - y1) / 4);
    var pts = [[(x1 + x2) / 2, (y1 + y2) / 2],
               [x1 + ix, y1 + iy], [x2 - ix, y1 + iy],
               [x1 + ix, y2 - iy], [x2 - ix, y2 - iy]];
    var covered = false;
    for (var i = 0; i < pts.length; i++) {
      var hit = document.elementFromPoint(pts[i][0], pts[i][1]);
      if (!hit) continue;
      // The element itself, or its own content painted inside it.
      if (hit === el || el.contains(hit)) return "seen";
      // An ANCESTOR won: the element is not painted here because its own
      // scroll container has carried it away. Genuinely gone — keep looking
      // at the other sample points, but this one proves nothing in favour.
      if (hit.contains(el)) continue;
      // A NON-ANCESTOR is on top. It only hides anything if it actually
      // paints something solid enough to hide it — a fully transparent
      // click-catcher hides NOTHING, and a 35% backdrop is a dimmer, not a
      // lid. Measured, not assumed.
      if (coverStrength(hit) < HIDE_AT) return "seen";
      covered = true;
    }
    return covered ? "covered" : "clipped";
  }
  function visible(el, b) {
    if (b.w <= 0 || b.h <= 0) return false;
    var s = getComputedStyle(el);
    if (s.display === "none" || s.visibility === "hidden") return false;
    // OFF-SCREEN. A box that never lands inside the viewport is not something
    // the captain (or Number One) can see, so it earns no geometry either.
    if (b.x + b.w <= 0 || b.y + b.h <= 0) return false;
    if (b.x >= (window.innerWidth || 0) || b.y >= (window.innerHeight || 0)) return false;
    return true;
  }
  var SKIP_TAG = { SCRIPT: 1, STYLE: 1, META: 1, LINK: 1, TITLE: 1, HEAD: 1,
    NOSCRIPT: 1, TEMPLATE: 1, HTML: 1, BR: 1, WBR: 1 };
  var INTERACTIVE_TAG = { BUTTON: 1, A: 1, INPUT: 1, SELECT: 1, TEXTAREA: 1, SUMMARY: 1 };
  var all = document.querySelectorAll("*");
  var elements = [], dropped = 0;
  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    if (SKIP_TAG[el.tagName]) continue;
    var b = box(el);
    if (!visible(el, b)) continue;
    if (elements.length >= CAP) { dropped++; continue; }
    var s = getComputedStyle(el);
    var role = el.getAttribute("role") || "";
    var interactive = !!INTERACTIVE_TAG[el.tagName] || role === "button" || role === "link" ||
      el.hasAttribute("onclick") || (el.tabIndex != null && el.tabIndex >= 0 && el.tagName !== "BODY");
    // Leaf-ish text only: a container's "text" would be every descendant's
    // text glued together, which names nothing.
    var ownText = el.childElementCount === 0 ? (el.innerText || el.textContent || "") : "";
    var why = seenAt(el, b, s);
    elements.push({
      id: el.id || null,
      tag: el.tagName.toLowerCase(),
      className: (typeof el.className === "string" && el.className) ? el.className : null,
      inputType: el.tagName === "INPUT" ? (el.getAttribute("type") || "text") : null,
      ariaLabel: el.getAttribute("aria-label") || null,
      text: ownText.replace(/[ \\t\\r\\n]+/g, " ").trim().slice(0, 80),
      box: b,
      color: s.color, background: s.backgroundColor,
      interactive: interactive,
      // How many pixels of the element's own content spill past its own box —
      // 0 when nothing does. Computed here because scrollWidth/scrollHeight
      // are DOM facts, not a judgement about whether that is a problem.
      overflowX: Math.max(0, Math.round((el.scrollWidth || 0) - (el.clientWidth || 0))),
      overflowY: Math.max(0, Math.round((el.scrollHeight || 0) - (el.clientHeight || 0))),
      // The COMPUTED overflow PROPERTY — a different fact from the two pixel
      // amounts above, and the one that says whether spilling is the point.
      overflowStyleX: s.overflowX, overflowStyleY: s.overflowY,
      // Whether cutting the text off was the POINT. overflow:hidden alone
      // says only that it IS cut off; the ellipsis is the author saying so.
      textOverflow: s.textOverflow,
      // ...and whether an ellipsis could RENDER. text-overflow does nothing
      // at all on text that is allowed to wrap, so the property alone is not
      // the author saying anything.
      whiteSpace: s.whiteSpace,
      // WHAT THE PAGE DECLARES. 'segment' names the segmented control this one
      // belongs to (see segmentOf); the three layout properties are how its own
      // container says it lays its children out and which edge it lines them up
      // on — read off an element, used by the observations pass as the PARENT's
      // declaration about the children inside it. Never inferred from boxes.
      segment: segmentOf(el),
      display: s.display,
      flexDirection: s.flexDirection,
      alignItems: s.alignItems,
      alignSelf: s.alignSelf,
      // Where it sits in the DOM, and whether it is really on screen.
      path: pathOf(el),
      seen: why === "seen",
      hiddenBy: why === "seen" ? null : why
    });
  }
  var elementsNote = dropped > 0
    ? ("the page has more visible elements than one look records; " + elements.length +
       " were captured and " + dropped + " were dropped (cap " + CAP + ")")
    : null;
  var out = { url: location.href, title: document.title, textExcerpt: (document.body ? (document.body.innerText || "") : "").replace(/[ \\t\\r\\n]+/g, " ").trim().slice(0, 2000), places: {}, elements: elements, elementsNote: elementsNote };
  ids.forEach(function (id) {
    var sel = id.charAt(0) === "#" ? id.slice(1) : id;
    var el = document.getElementById(sel) || document.querySelector(id.charAt(0) === "#" ? id : "#" + sel);
    if (!el) { out.places[sel] = { present: false }; return; }
    var s = getComputedStyle(el), b = box(el);
    out.places[sel] = { present: true, box: b, laidOut: b.w > 0 && b.h > 0,
      color: s.color, background: s.backgroundColor, fontSize: s.fontSize,
      text: (el.innerText || "").replace(/[ \\t\\r\\n]+/g, " ").trim().slice(0, 300) };
  });
  return JSON.stringify(out);
})()`;

/* ── THE PARTS READER (S220 part B) ────────────────────────────────────────
 *
 * WHY IT IS NOT `READ`. The element capture above is the OBSERVATIONS pass's
 * input and it deliberately keeps only what is IN THE VIEWPORT — a box nobody
 * can see is not a crowding fault. A DRAWING is one long page with six screens
 * stacked down it, so reading it through that lens would find the first screen
 * and call the rest missing. This reader answers a different question — "what
 * are the named, labelled PARTS of this page, wherever they sit on it" — so it
 * keeps everything that is laid out and rendered, above the fold or below it.
 *
 * WHAT IT MEASURES, and every one of these is a FACT the browser already knows:
 *   name      what a person would call it: its aria-label, else its own text,
 *             else its title/alt/placeholder. The handle that matched a drawn
 *             part to a built one, when the ids do not line up — and on the
 *             S220 benchmark they do not: the drawing names twelve and the
 *             build has none of them.
 *   testid    `data-testid` when the project uses them. A convention, never a
 *             guarantee, which is exactly why it is one handle among several.
 *   iconBox   the tallest icon-ish child: an svg, an img, a canvas, or a glyph
 *             span of a character or two. The four buttons Number One passed
 *             on 2026-09-19 each held one of these at 34-61 px inside a 30-38
 *             px control.
 *   lines     how many lines the label ACTUALLY renders on, counted from the
 *             rects of its own text nodes — not guessed from a height, which
 *             would make padding look like a wrap.
 * It also stamps `data-xo-part` on each part, so the crop that follows can
 * clip to exactly the element that was measured.  */
const PARTS = (cap) => `(function () {
  var CAP = ${JSON.stringify(cap)};
  function box(el) { var r = el.getBoundingClientRect(); return { x: Math.round(r.x + window.scrollX), y: Math.round(r.y + window.scrollY), w: Math.round(r.width), h: Math.round(r.height) }; }
  function txt(el) { return (el.innerText || el.textContent || "").replace(/\\s+/g, " ").trim(); }
  function nameOf(el) {
    var n = el.getAttribute("aria-label") || "";
    if (!n) n = txt(el);
    if (!n) n = el.getAttribute("title") || el.getAttribute("alt") || el.getAttribute("placeholder") || "";
    return n.slice(0, 80);
  }
  // HOW MANY LINES THE LABEL RENDERS ON. From the rects of the TEXT NODES
  // themselves: an icon beside the text is not a line of text, and a tall box
  // is padding until the text says otherwise.
  function lines(el) {
    try {
      var w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null), tops = {}, n = 0, node;
      while ((node = w.nextNode())) {
        if (!String(node.nodeValue || "").trim()) continue;
        var r = document.createRange(); r.selectNodeContents(node);
        var rs = r.getClientRects();
        for (var i = 0; i < rs.length; i++) {
          if (rs[i].height < 1 || rs[i].width < 1) continue;
          var t = Math.round(rs[i].top);
          if (!(t in tops)) { tops[t] = 1; n++; }
        }
      }
      return n || (txt(el) ? 1 : 0);
    } catch (e) { return txt(el) ? 1 : 0; }
  }
  var ICON_TAG = { SVG: 1, IMG: 1, CANVAS: 1, I: 1, PICTURE: 1 };
  function iconOf(el) {
    var kids = el.querySelectorAll("*"), best = null;
    for (var i = 0; i < kids.length; i++) {
      var k = kids[i], r = k.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      var tag = (k.tagName || "").toUpperCase();
      var own = (k.childElementCount === 0) ? txt(k) : "";
      // An svg/img/canvas, or a glyph: a leaf of a character or two (an emoji
      // counts as one or two code units), or a leaf with no text at all that
      // is still painting something square-ish.
      var iconish = !!ICON_TAG[tag] || (k.childElementCount === 0 && own.length > 0 && own.length <= 2) ||
        (k.childElementCount === 0 && own.length === 0 && r.width >= 6 && r.height >= 6 &&
         (getComputedStyle(k).backgroundImage !== "none" || getComputedStyle(k).backgroundColor !== "rgba(0, 0, 0, 0)" ||
          (getComputedStyle(k).maskImage && getComputedStyle(k).maskImage !== "none")));
      if (!iconish) continue;
      if (!best || r.height > best.h) best = { x: Math.round(r.x + window.scrollX), y: Math.round(r.y + window.scrollY), w: Math.round(r.width), h: Math.round(r.height) };
    }
    return best;
  }
  var INTERACTIVE_TAG = { BUTTON: 1, A: 1, INPUT: 1, SELECT: 1, TEXTAREA: 1, SUMMARY: 1, LABEL: 1 };
  var LABELLED_TAG = { H1: 1, H2: 1, H3: 1, H4: 1, P: 1, LI: 1, TD: 1, TH: 1, LEGEND: 1 };
  var all = document.querySelectorAll("*");
  var parts = [], dropped = 0, idx = 0;
  for (var i = 0; i < all.length; i++) {
    var el = all[i], tag = (el.tagName || "").toUpperCase();
    var r = el.getBoundingClientRect();
    var s = getComputedStyle(el);
    if (s.display === "none" || s.visibility === "hidden") continue;
    var role = (el.getAttribute("role") || "").toLowerCase();
    var interactive = !!INTERACTIVE_TAG[tag] || role === "button" || role === "link" || role === "tab" ||
      el.hasAttribute("onclick");
    // A NAMED part of the drawing is a part whatever it is: the drawing's ids
    // are the vocabulary the contract is written in.
    var named = !!el.id || el.hasAttribute("data-testid");
    var labelled = !!LABELLED_TAG[tag] && txt(el).length > 0 && el.childElementCount === 0;
    if (!interactive && !named && !labelled) continue;
    if (parts.length >= CAP) { dropped++; continue; }
    idx++;
    try { el.setAttribute("data-xo-part", String(idx)); } catch (e) {}
    // IS IT A PART, OR THE BOX THE PARTS SIT IN? A section with an id is
    // still a section: measuring "the entry section runs onto 11 lines where
    // the drawing has 10" is a sentence about nothing, and on the S220
    // fixture it was a FALSE ALARM against a correct tab bar, because the
    // section's text contains every control's label. Recorded as a fact here;
    // xo-parts.py is what decides to leave containers out of the pairing.
    var kids = el.childElementCount;
    var container = (!interactive && (kids > 2 || r.height > 200));
    parts.push({
      index: idx,
      kids: kids,
      container: container,
      id: el.id || null,
      testid: el.getAttribute("data-testid") || null,
      name: nameOf(el),
      // THE OTHER NAMES A CONTROL HAS (S224 item 1). nameOf() returns the
      // ACCESSIBLE name, and aria-label wins it outright. Measured on the
      // S222 capstone: the build labels its selects "Status for LTC P75" and
      // its insight boxes "Insight for LTC P75", while the holodeck drawing —
      // plain HTML, no aria — names the same controls by what is PRINTED on
      // them ("On trackWatchOff track") and by their placeholder ("Add an
      // insight for this KPI…"). Both ends read only the accessible name, so
      // the two records could never meet and ten controls that were right
      // there came back "I could not find it in the build". Writing the other
      // names down costs nothing and is what lets the pairer try them.
      text: txt(el).slice(0, 80),
      placeholder: el.getAttribute("placeholder") || null,
      value: (typeof el.value === "string" ? el.value : "").slice(0, 80) || null,
      role: role || null,
      tag: el.tagName.toLowerCase(),
      interactive: interactive,
      box: box(el),
      iconBox: iconOf(el),
      lines: lines(el),
      color: s.color,
      background: s.backgroundColor,
      crop: null
    });
  }
  return JSON.stringify({ url: location.href, title: document.title, parts: parts,
    droppedParts: dropped, cap: CAP });
})()`;

const BOX_OF = (sel) => `(function () {
  var el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return "";
  var r = el.getBoundingClientRect();
  return JSON.stringify({ x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) });
})()`;

const CLICK = (sel) => `(function () {
  var el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return "no-such-element";
  el.scrollIntoView({ block: "center" });
  el.click();
  return "ok";
})()`;

const TYPE = (sel, text) => `(function () {
  var el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return "no-such-element";
  el.focus();
  var v = ${JSON.stringify(text)};
  if ("value" in el) {
    el.value = v;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  } else { el.textContent = v; }
  return "ok";
})()`;

/* ── pressing a key (S213) ────────────────────────────────────────────────
 * Everything above this line is something you do TO an element. A keyboard is
 * not: the game moves on the arrows, a dialog closes on Escape, and the whole
 * of tab order is a key nobody could send. Without this the look could confirm
 * a step-count readout EXISTS and never that the number GOES UP as you walk,
 * which on a real mission was the entire thing the captain asked for.
 *
 * IT HAS TO BE A REAL KEY. The cheap version — set a value, or
 * dispatchEvent(new KeyboardEvent(…)) — runs the page's own handlers, so a test
 * of it goes green while no key was ever pressed; and any page that checks
 * `event.isTrusted`, or relies on the browser's own default behaviour (typing
 * into a field, moving focus on Tab, scrolling on Space), does nothing at all.
 * So this goes through CDP's Input domain, where the BROWSER generates the
 * event, exactly as it does for a finger on a key.
 */
const KEYS = {
  // name              code             vk   text (printable only)
  ArrowUp:    ["ArrowUp", 38], ArrowDown:  ["ArrowDown", 40],
  ArrowLeft:  ["ArrowLeft", 37], ArrowRight: ["ArrowRight", 39],
  Enter:      ["Enter", 13, "\r"], Escape: ["Escape", 27],
  Tab:        ["Tab", 9], Backspace: ["Backspace", 8], Delete: ["Delete", 46],
  Space:      ["Space", 32, " "], " ": ["Space", 32, " "],
  Home:       ["Home", 36], End: ["End", 35],
  PageUp:     ["PageUp", 33], PageDown: ["PageDown", 34],
};
/* THE FUNCTION KEYS (S221 fix 8c). F1..F12, generated rather than typed out —
 * their virtual key codes are contiguous from 112, and their `code` is their
 * own name. They are here because the planner can now emit them and a build
 * can answer them: this session's own mission has a criterion about its F3
 * debug overlay, and the driver refusing F3 left that criterion reading
 * "couldn't check" for ever while the game answered the key perfectly well.
 * No `text`: a function key prints nothing. */
for (let fn = 1; fn <= 12; fn++) KEYS["F" + fn] = ["F" + fn, 111 + fn];
const MODIFIER_BITS = { alt: 1, control: 2, ctrl: 2, meta: 4, command: 4, cmd: 4, shift: 8 };

/* What the browser needs to be told to press <key>, or null when <key> is not
 * a key anybody can press. Named keys come from the table; a single character
 * is worked out from the character itself. Returning null rather than guessing
 * is deliberate: a key we cannot press must be SAID, not silently dropped. */
/* THE CEILING ON A HELD KEY (S221). Two of them, because one is not enough:
 * MAX_HOLD_MS bounds a single hold, MAX_HOLD_TOTAL_MS bounds what ONE action
 * may spend holding however many repeats it asked for. 2s is far longer than
 * any single input gesture a person makes; 10s of holding is 40 tiles of
 * walking in the build this was measured on. Twelve actions at the total is
 * two minutes — a rounding error against the 45-minute cage, and nothing an
 * action list can do will wedge a look.
 */
const MAX_HOLD_MS = 2000;
const MAX_HOLD_TOTAL_MS = 10000;

function keyDescriptor(key) {
  if (typeof key !== "string" || key.length === 0) return null;
  const named = KEYS[key];
  if (named) {
    return { key: key === " " ? " " : key, code: named[0],
             vk: named[1], text: named[2] || "" };
  }
  if (key.length !== 1) return null;
  const ch = key;
  const upper = ch.toUpperCase();
  let code = "";
  if (upper >= "A" && upper <= "Z") code = "Key" + upper;
  else if (ch >= "0" && ch <= "9") code = "Digit" + ch;
  else code = "";                       // punctuation: no code, still typable
  return { key: ch, code, vk: upper.charCodeAt(0), text: ch };
}

function modifierMask(mods) {
  if (!Array.isArray(mods)) return 0;
  let bits = 0;
  for (const m of mods) bits |= MODIFIER_BITS[String(m).toLowerCase()] || 0;
  return bits;
}

/* ── ACTING ON A CONTROL BY ITS NAME (S220 part F) ──────────────────────────
 * A declared journey names the control the way a person does — "Pull data &
 * start", "Continue to builder" — not by a css selector, because the record
 * the journey is built from (a drawing, a PRD) names things that way and a
 * selector invented from a label is a guess about the build's markup.
 *
 * So the browser is asked to find the control by its ACCESSIBLE NAME and act
 * on it: the same question a person asks looking at the screen. What came
 * back — which control it matched, whether the control refused (disabled),
 * and, when nothing matched, the names that WERE on the screen — is returned
 * so the record can say why a step did not happen.
 */
/* ── ONE COPY OF THE PAGE-SIDE VOCABULARY (S225) ────────────────────────────
 * THREE expressions now run inside the page — act on a control, read what the
 * screen SAID when it refused, and fill the fields that refusal named — and all
 * three have to agree on what a field is, what a control is called, and what a
 * value for a field looks like. Two copies of a payload is exactly how a `hold`
 * ends up working in one path and silently not in the other (S221, measured, a
 * few hundred lines down). So the vocabulary is written ONCE, here, and
 * injected into each expression.
 */
const PAGE_LIB = `
  function norm(s) { return String(s == null ? "" : s).replace(/\\s+/g, " ").trim().toLowerCase(); }
  function raw(s) { return String(s == null ? "" : s).replace(/\\s+/g, " ").trim(); }
  function nameOf(el) {
    var n = (el.getAttribute && el.getAttribute("aria-label")) || "";
    if (!n && el.tagName === "INPUT") n = el.getAttribute("placeholder") || el.value || "";
    if (!n && el.tagName === "TEXTAREA") n = el.getAttribute("placeholder") || "";
    if (!n) n = el.innerText || el.textContent || "";
    if (!n && el.id) {
      var lab = document.querySelector('label[for="' + el.id + '"]');
      if (lab) n = lab.innerText || "";
    }
    if (!n && el.getAttribute) n = el.getAttribute("title") || el.getAttribute("name") || "";
    return norm(n).slice(0, 120);
  }
  var TYPEABLE = 'input[type=text],input[type=search],input[type=email],input[type=number],input:not([type]),textarea,[contenteditable=true]';
  var CLICKABLE = 'button,a[href],[role=button],[role=tab],[role=link],input[type=submit],input[type=button],summary,[onclick]';
  function visible(el) {
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== "none" && s.visibility !== "hidden";
  }
  function isEmpty(el) { return el.isContentEditable ? !norm(el.innerText) : !norm(el.value); }
  /* WHAT THIS PARTICULAR BOX WILL ACTUALLY TAKE (S225 fix c).
   *
   * MEASURED ON THE CAPTAIN'S OWN APP: the whole-form fill assigned the SAME
   * sentence to every empty field, and a browser silently coerces a non-numeric
   * string assigned to an <input type=number> to "". The read-back check below
   * then saw an empty box and recorded "could not fill" — so a number box was
   * SELECTED by the selector and STRUCTURALLY unfillable, every single time, and
   * the gate it fed could never be satisfied. A field gets a value that suits
   * its own type, and a number box's value respects the min/max/step the page
   * declared rather than a constant that might sit outside them.
   */
  function fieldValue(el, text0) {
    var type = (el.tagName === "INPUT" ? (el.getAttribute("type") || "text") : "").toLowerCase();
    var mode = (el.getAttribute && el.getAttribute("inputmode")) || "";
    if (type === "email") return "number.one@example.com";
    if (type !== "number" && mode !== "numeric" && mode !== "decimal") return text0;
    var min = parseFloat(el.getAttribute("min"));
    var max = parseFloat(el.getAttribute("max"));
    var step = parseFloat(el.getAttribute("step"));
    var v = 42;
    if (!isNaN(min) && v < min) v = min;
    if (!isNaN(max) && v > max) v = max;
    if (!isNaN(step) && step > 0) {
      var base = !isNaN(min) ? min : 0;
      v = base + Math.round((v - base) / step) * step;
      if (!isNaN(max) && v > max) v = v - Math.ceil((v - max) / step) * step;
      if (!isNaN(min) && v < min) v = min;
    }
    if (!isFinite(v)) v = 42;
    return String(Math.round(v * 1e6) / 1e6);
  }
  /* Assign through the PROTOTYPE setter so a framework's own change tracking
   * sees it, then READ IT BACK: a browser drops a value a field will not take
   * without a word of complaint, and the read-back is the only honest evidence
   * anything landed at all. Returns what the field now holds. */
  function setField(el, v) {
    el.focus();
    if (el.isContentEditable) { el.innerText = v; }
    else {
      var proto = el.tagName === "TEXTAREA" ? window.HTMLTextAreaElement.prototype
                                            : window.HTMLInputElement.prototype;
      var setter = Object.getOwnPropertyDescriptor(proto, "value");
      if (setter && setter.set) setter.set.call(el, v); else el.value = v;
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return el.isContentEditable ? norm(el.innerText) : norm(el.value);
  }
  /* The words a control carries ABOUT ITSELF when it will not be used: the
   * tooltip, or whatever the page pointed at with aria-describedby. On a
   * disabled control this is very often the only place the reason lives. */
  function tipOf(el) {
    var tip = raw((el.getAttribute && el.getAttribute("title")) || "");
    if (!tip && el.getAttribute) {
      var db = el.getAttribute("aria-describedby") || "";
      var parts = [];
      db.split(/\\s+/).forEach(function (idr) {
        if (!idr) return;
        var e = document.getElementById(idr);
        if (e) parts.push(raw(e.innerText || e.textContent || ""));
      });
      tip = parts.filter(Boolean).join(" ");
    }
    return tip.slice(0, 200);
  }
`;

const ACT = (spec) => `(function () {
  var spec = ${JSON.stringify(spec)};
  ${PAGE_LIB}
  var typing = (spec.do === "type" || spec.do === "typeall");
  var all = Array.prototype.slice.call(document.querySelectorAll(typing ? TYPEABLE : CLICKABLE));
  var cands = all.filter(visible);
  var pats = (spec.match || []).map(norm).filter(Boolean);
  // FILL THE WHOLE FORM (fix round 1, D6). The declared journey names one or
  // two fields because that is all the DRAWING draws; the screen in front of
  // it asks for nineteen. A gate's "now everything is filled" phase is a lie
  // while seventeen boxes are empty, so this mode types into every empty
  // field on the screen and reports, by name, the ones it could not fill.
  if (spec.do === "typeall") {
    var text0 = String(spec.text == null ? "" : spec.text);
    var filled = 0, names = [], values = [], leftNames = [];
    cands.forEach(function (el) {
      if (!isEmpty(el)) return;
      try {
        // S225 fix c: the value suits THIS box, not every box. One string for
        // all of them is how two KPI number inputs were "could not fill".
        var want = fieldValue(el, text0);
        var back = setField(el, want);
        if (back) { filled += 1; names.push(nameOf(el)); values.push(want); }
        else { leftNames.push(nameOf(el)); }
      } catch (e) { leftNames.push(nameOf(el)); }
    });
    return JSON.stringify({ ok: true, filled: filled, left: leftNames.length,
      names: names.slice(0, 30), typedValues: values.slice(0, 30),
      leftNames: leftNames.slice(0, 30),
      fieldsOnScreen: cands.length });
  }
  var best = null, bestScore = -1;
  cands.forEach(function (el) {
    var n = nameOf(el), sc = -1;
    if (!pats.length) {
      // No name to go on: for typing, the first EMPTY field is the one a
      // person fills; for anything else, nothing is matched at all.
      sc = (typing && !norm(el.value) && !norm(el.innerText)) ? 1 : -1;
    } else {
      for (var i = 0; i < pats.length; i++) {
        var p = pats[i], s2 = -1;
        if (n === p) s2 = 100 - i;
        else if (n.indexOf(p) === 0) s2 = 80 - i;
        else if (n.indexOf(p) >= 0) s2 = 60 - i;
        else if (n.length > 3 && p.indexOf(n) >= 0) s2 = 40 - i;
        else {
          // MOSTLY THE SAME WORDS. The record names a thing one way and the
          // build names it another — "MBR View Builder" in the mission, "MBR
          // builder" on the screen — and neither contains the other. Measured
          // on the real benchmark, where that one gap left every step of the
          // walk "unreachable" on a page the button was two clicks from. So:
          // the words they share, against the shorter of the two.
          var wa = n.split(" ").filter(function (x) { return x.length > 2; });
          var wb = p.split(" ").filter(function (x) { return x.length > 2; });
          if (wa.length && wb.length) {
            var shared = wa.filter(function (x) { return wb.indexOf(x) >= 0; }).length;
            var need = Math.min(wa.length, wb.length);
            if (shared >= 2 && shared >= need * 0.6) s2 = 30 - i;
          }
        }
        if (s2 > sc) sc = s2;
      }
    }
    if (sc > bestScore) { bestScore = sc; best = el; }
  });
  if (!best || bestScore < 0) {
    return JSON.stringify({ ok: false, why: "no-such-control",
      onScreen: cands.slice(0, 30).map(nameOf).filter(Boolean) });
  }
  var disabled = !!best.disabled || best.getAttribute("aria-disabled") === "true" ||
                 String(best.className || "").indexOf("disabled") >= 0;
  var found = { ok: true, name: nameOf(best), tag: best.tagName.toLowerCase(),
                id: best.id || null, disabled: disabled };
  try { best.scrollIntoView({ block: "center" }); } catch (e) {}
  if (spec.do === "probe") return JSON.stringify(found);
  if (spec.do === "type") {
    var text = String(spec.text == null ? "" : spec.text);
    try {
      var want1 = fieldValue(best, text);
      found.typed = want1;
      found.readBack = setField(best, want1);
    } catch (e) { found.ok = false; found.why = "could-not-type: " + e.message; }
    // S225 fix a: a field that would not take the text usually says why. The
    // browser's own validation message, then whatever the page put on the box.
    if (!found.readBack) {
      var vm1 = "";
      try { vm1 = raw(best.validationMessage || ""); } catch (e2) {}
      found.refusalText = vm1 || tipOf(best);
    }
    return JSON.stringify(found);
  }
  // click. A control that refuses is NOT forced: "it refused" is the answer to
  // the question a gate step asks, and clicking it anyway would erase it.
  // S225 fix a: and it is asked what it has to say for itself, because a
  // disabled control's tooltip is very often the whole reason.
  if (disabled) {
    found.clicked = false;
    var tip = tipOf(best);
    if (tip) found.refusalText = tip;
    return JSON.stringify(found);
  }
  try { best.click(); found.clicked = true; }
  catch (e) { found.clicked = false; found.why = "could-not-click: " + e.message; }
  return JSON.stringify(found);
})()`;

/* ── WHAT THE SCREEN SAID WHEN IT REFUSED (S225 fix a) ──────────────────────
 * A refusal used to be recorded as a bare word. `status: "refused"` was set in
 * three places with NOTHING beside it about why, while the `unreachable` case
 * one branch above always captured a reason — refused and unreachable are
 * siblings in that code and only one of them talked. So the captain's row read
 * "I did it and the screen was the same before and after … so I cannot say
 * whether it worked", and nobody could tell a broken button from a form that
 * was never made ready.
 *
 * This reads the refusal back off the screen, from the places a page DECLARES
 * one rather than from any guess about English:
 *
 *   MARKED — the browser's own `validationMessage`, and any visible element the
 *   page tagged as a message (role=alert/status, aria-live, an error/invalid/
 *   warning class). These are the page's own declaration, not a classifier.
 *   `hint` — short text that appeared on the screen since the action, passed in
 *   from the driver. Not marked, so it never on its own decides that a refusal
 *   happened; it only adds words to what the refusal SAID.
 *
 * And it names the fields the refusal points at, so the repair can do THAT and
 * nothing else: a field the page marks required-and-empty or invalid, or an
 * empty field whose own name shares a word with what the refusal said. Nothing
 * is actionable because it merely exists — an empty box the refusal never
 * mentioned is left exactly as it is.
 */
const REFUSAL = (hint) => `(function () {
  ${PAGE_LIB}
  var hint = ${JSON.stringify(String(hint == null ? "" : hint))};
  var marked = [], seen = {};
  function say(list, s) {
    s = raw(s);
    if (!s) return;
    if (s.length > 240) s = s.slice(0, 240);
    var k = s.toLowerCase();
    if (seen[k]) return;
    seen[k] = 1;
    list.push(s);
  }
  var MSG = '[role=alert],[role=status],[role=alertdialog],[aria-live],.error,.errors,' +
            '.invalid,.warning,.validation,.validation-message,.form-error,.field-error,' +
            '.help-block,[data-error],[aria-invalid=true]';
  Array.prototype.slice.call(document.querySelectorAll(MSG)).forEach(function (el) {
    if (!visible(el)) return;
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") return;
    say(marked, el.innerText || el.textContent || "");
  });
  var boxes = Array.prototype.slice.call(document.querySelectorAll(TYPEABLE + ",select"))
                   .filter(visible);
  boxes.forEach(function (el) {
    var vm = "";
    try { vm = raw(el.validationMessage || ""); } catch (e) {}
    if (vm) say(marked, vm);
  });
  var said = marked.slice(0);
  if (hint) say(said, hint);
  var hay = norm(said.join(" "));
  var STOP = { the:1, and:1, for:1, this:1, that:1, with:1, your:1, you:1, are:1, was:1,
               not:1, but:1, its:1, has:1, have:1, add:1, enter:1, type:1, please:1,
               field:1, fields:1, first:1, must:1, all:1, each:1, into:1, from:1,
               here:1, more:1, some:1, any:1, one:1, before:1, need:1, needs:1,
               required:1, missing:1, cannot:1, still:1, then:1, they:1, them:1 };
  function stem(w) { return w.replace(/ies$/, "y").replace(/s$/, ""); }
  function namedIn(nm) {
    if (!hay) return false;
    var ws = nm.split(/[^a-z0-9]+/).filter(function (w) { return w.length >= 4 && !STOP[w]; });
    for (var i = 0; i < ws.length; i++) if (hay.indexOf(stem(ws[i])) >= 0) return true;
    return false;
  }
  var fields = [];
  Array.prototype.slice.call(document.querySelectorAll(TYPEABLE)).filter(visible)
    .forEach(function (el) {
      if (!isEmpty(el) || fields.length >= 12) return;
      var nm = nameOf(el);
      var vm = "";
      try { vm = raw(el.validationMessage || ""); } catch (e) {}
      var required = !!el.required || el.getAttribute("aria-required") === "true";
      var invalid = el.getAttribute("aria-invalid") === "true" || !!vm;
      var why = required ? "the screen marks it required and it is empty"
              : invalid ? "the screen marks it invalid"
              : namedIn(nm) ? "the refusal names it"
              : null;
      if (!why) return;
      fields.push({ name: nm, id: el.id || null, why: why, message: vm,
                    kind: el.tagName === "INPUT"
                            ? (el.getAttribute("type") || "text").toLowerCase()
                            : el.tagName.toLowerCase() });
    });
  return JSON.stringify({ marked: marked.slice(0, 6), said: said.slice(0, 6),
                          text: said.slice(0, 6).join(" "), fields: fields });
})()`;

/* ── DO EXACTLY WHAT IT NAMED, AND NOTHING ELSE (S225 fix b) ────────────────
 * Fill the fields the refusal pointed at, each with a value its own box will
 * take, and say by name what went in and what would not. It is handed the list
 * REFUSAL produced — it never looks for work of its own — and a field somebody
 * has filled in the meantime is left alone.
 */
const FILL_FIELDS = (targets, text) => `(function () {
  ${PAGE_LIB}
  var targets = ${JSON.stringify(targets)};
  var text0 = ${JSON.stringify(String(text == null ? "" : text))};
  var all = Array.prototype.slice.call(document.querySelectorAll(TYPEABLE)).filter(visible);
  var filled = [], left = [];
  targets.forEach(function (t) {
    var el = null;
    if (t.id) { try { el = document.getElementById(t.id); } catch (e) { el = null; } }
    if (el && all.indexOf(el) < 0) el = null;
    if (!el) {
      for (var i = 0; i < all.length; i++) {
        if (nameOf(all[i]) === norm(t.name)) { el = all[i]; break; }
      }
    }
    if (!el) { left.push(String(t.name || "(a field)")); return; }
    if (!isEmpty(el)) return;
    try {
      var want = fieldValue(el, text0);
      var back = setField(el, want);
      if (back) filled.push({ name: nameOf(el), value: want, why: t.why || null });
      else left.push(nameOf(el));
    } catch (e) { left.push(nameOf(el)); }
  });
  return JSON.stringify({ ok: true, filled: filled, left: left });
})()`;

const FOCUS = (sel) => `(function () {
  var el = document.querySelector(${JSON.stringify(sel)});
  if (!el) return "no-such-element";
  el.scrollIntoView({ block: "center" });
  el.focus();
  return "ok";
})()`;

/* ── the drive ───────────────────────────────────────────────────────────── */
(async () => {
  const places = readPlaceNames(PLACES_FILE);
  let actions = readActions(ACTIONS_FILE);
  const journeyDoc = readJourney(JOURNEY_FILE);
  const journey = journeyDoc.steps;
  const notes = [];
  if (actions.length > MAX_ACTIONS) {
    // A look is a look. The overflow is DROPPED and SAID, never silently run:
    // the readout is evidence, and evidence that hides what it refused is not.
    notes.push("the action list carried " + actions.length + " actions; only the first " + MAX_ACTIONS + " were run (cap " + MAX_ACTIONS + ")");
    actions = actions.slice(0, MAX_ACTIONS);
  }

  let port = ATTACH_PORT;
  if (!port) port = await launchChrome();
  const { ws, send, events } = await connect(port);

  const t = await send("Target.createTarget", { url: "about:blank" });
  const att = await send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
  const S = att.sessionId;
  // Runtime/Log/Page BEFORE navigating, or the first console error of the load
  // is missed and the readout quietly under-reports.
  await send("Runtime.enable", {}, S);
  await send("Log.enable", {}, S);
  await send("Page.enable", {}, S);

  /* The device scale factor, set ONCE for the whole look so every shot — the
   * full-page ones and the clipped ones alike — comes back at the same real
   * resolution. width/height 0 means "override nothing but the scale": the
   * page still lays out at the 1440x900 window chromeArgv asked for, so a
   * selector's box is the same CSS box it always was, and only the raster
   * behind it gets denser. A browser too old to know the command is not a
   * reason to abandon the look, so a failure here is recorded and the shots
   * are taken at whatever it does give. */
  let scaleApplied = SCALE;
  try {
    await send("Emulation.setDeviceMetricsOverride",
      { width: 0, height: 0, deviceScaleFactor: SCALE, mobile: false }, S);
  } catch (e) {
    scaleApplied = 1;
    notes.push("this browser refused a device scale factor of " + SCALE +
               " (" + e.message + "); the shots are at whatever it renders natively");
  }

  let currentUrl = URL_;
  async function navigate(u) {
    currentUrl = u;
    await send("Page.navigate", { url: u }, S);
    await settle();
  }

  /* Wait for the page to be worth looking at: a body with text, and every named
   * place laid out if we were given names. Polling the REAL DOM, not a timer —
   * a fixed sleep is how a rig starts photographing loading spinners. */
  async function settle() {
    const deadline = Date.now() + TIMEOUT;
    let last = null;
    while (Date.now() < deadline) {
      try {
        const r = await send("Runtime.evaluate", { expression: READ(places, ELEMENT_CAP), returnByValue: true }, S);
        if (r && r.result && typeof r.result.value === "string") {
          last = JSON.parse(r.result.value);
          const named = places.length === 0 || places.some((id) => {
            const p = last.places[id.replace(/^#/, "")];
            return p && p.laidOut;
          });
          /* A PAGE THAT DRAWS ITSELF HAS NOTHING TO WAIT FOR (S221 fix 7).
           * This loop waits for TEXT to appear, and a canvas build has none —
           * ever. So on one it never returned early and every journey step
           * burned the whole --timeout before moving on, which reads exactly
           * like a hung look. Measured: a three-hold press step never came
           * back. With nothing to settle on, the first readout IS the answer. */
          if ((last.textExcerpt || canvasOnly) && named) return last;
        }
      } catch (_) {}
      await sleep(250);
    }
    return last;
  }

  async function readout() {
    const r = await send("Runtime.evaluate", { expression: READ(places, ELEMENT_CAP), returnByValue: true }, S);
    const doc = (r && r.result && typeof r.result.value === "string") ? JSON.parse(r.result.value) : { url: currentUrl, title: "", textExcerpt: "", places: {} };
    doc.consoleErrors = events
      .filter((e) => e.method === "Log.entryAdded" && e.params.entry.level === "error")
      .map((e) => e.params.entry.text)
      .slice(-20);
    return doc;
  }

  const shots = [];
  let incomplete = false;
  // S221 fix 6: this page draws itself and has no laid-out text (a canvas app).
  // Set by the render gate below; it suppresses round 0's duplicate full-page
  // shot and is carried into the walk record.
  let canvasOnly = false;

  /* WHAT MAKES ONE SCREEN DIFFERENT FROM ANOTHER. The address, plus the first
   * words on it: an app that changes its whole view without changing its url
   * has two screens, and a record keyed on the url alone keeps only the last. */
  function screenSig(doc) {
    return String((doc && (doc.title || "")) + " " +
                  String((doc && doc.textExcerpt) || "").replace(/\s+/g, " ").trim().slice(0, 80));
  }

  /* ── A PARTS SNAPSHOT PER SCREEN (S220 part B) ─────────────────────────────
   * MEASURED ON THE REAL BENCHMARK: a drawing of six screens, paired against
   * ONE snapshot taken where the round happened to end, matched 6 of 65 parts
   * and called the other 59 "not in the build" — a wall of couldn't-checks
   * about controls that were right there two clicks back. A person holding the
   * drawing walks the app and looks at each screen in turn, so the parts are
   * read on EVERY screen the look stands on and kept per screen. */
  const partPages = [];
  let partCrops = 0;
  /* ── THE CROP BUDGET IS DIVIDED, NOT RACED FOR (S224 fix round 2) ──────────
   * MEASURED ON THE S222 CAPSTONE: the look came back with exactly sixteen
   * `shot-s0-part-*.png` — all of them from the LANDING screen — and not one
   * part crop from any of the screens the walk then went on to visit. The
   * counter below was a single running total and `snapScreen("s0")` runs before
   * `walkTheJourney()`, so the first screen spent the whole budget before the
   * walk began. The comment here used to claim the opposite ("the cap is shared
   * across screens, so a first screen cannot spend every crop the look has");
   * nothing implemented it. It does now.
   *
   * HOW IT IS DIVIDED. Each parts snapshot may spend its FAIR SHARE of what is
   * LEFT — the remainder over the snapshots the plan still has to take — with a
   * floor of one, so no screen the look stood on comes back with no picture of
   * its parts while there is budget left. A screen with fewer croppable parts
   * than its share leaves the rest to the screens after it, so nothing is
   * reserved and then wasted. The plan is the walk itself: the landing screen,
   * the way in if there are entry hints, and one snapshot per journey step (or
   * per action, on the action path). The final `snapParts("end")` is deliberately
   * NOT in the plan — it re-reads the screen the look ended on, which it has
   * already photographed.
   *
   * THE TOTAL IS UNCHANGED, deliberately. More pictures cost RECALL: on a
   * 40-picture corpus the criteria-free pass lost the month-jump finding it
   * caught 2/2 on the same corpus at 27 pictures — same prompt, same day. This
   * buys SPREAD at the same price; it must never buy more pictures.
   *
   * A SCREEN IS PHOTOGRAPHED ONCE. Standing on a screen again re-reads its
   * parts (the later reading still wins) but REUSES the crops already on disk
   * rather than taking near-duplicates under a second tag — which would spend
   * the budget twice and pad the corpus with the same picture twice over.
   */
  const plannedSnaps = Math.max(1, journey.length
    ? 1 + (journeyDoc.entry.length ? 1 : 0) + journey.length
    : 1 + actions.length);
  const nominalShare = Math.max(1, Math.ceil(PARTS_CROP_CAP / plannedSnaps));
  let snapsDone = 0;
  const cropsBySig = new Map();   // screen signature -> Map(part index -> crop name)
  function cropAllowance(sig) {   // how many NEW crops this screen may take now
    const left = PARTS_CROP_CAP - partCrops;
    if (left <= 0) return 0;
    const mine = cropsBySig.get(sig);
    const spent = mine ? mine.size : 0;
    // Past the plan (a screen the walk did not predict): the nominal share
    // only, so an unplanned late screen cannot hoover up what is left either.
    const share = (snapsDone > plannedSnaps)
      ? nominalShare
      : Math.max(1, Math.ceil((left + spent) / Math.max(1, plannedSnaps - snapsDone + 1)));
    return Math.max(0, Math.min(share - spent, left));
  }
  async function snapParts(tag) {
    if (!PARTS_OUT) return;
    snapsDone++;
    try {
      const pr = await send("Runtime.evaluate", { expression: PARTS(PARTS_CAP), returnByValue: true }, S);
      const doc = (pr && pr.result && typeof pr.result.value === "string")
        ? JSON.parse(pr.result.value) : null;
      if (!doc) return;
      // The same screen twice is one screen. The LATER reading wins: it is the
      // one the look was standing on when it decided anything.
      //
      // AND A SCREEN IS NOT JUST A URL. An app that swaps its whole view
      // without touching the address has two screens at one address, and
      // keying this on the url alone threw the second one away — measured on
      // the S220 fixture, where five visited screens came back as one.
      const at = String(doc.url || currentUrl);
      const sig = at + "|" + screenSig(doc);
      for (let i = partPages.length - 1; i >= 0; i--) {
        if (partPages[i].sig === sig) partPages.splice(i, 1);
      }
      let mine = cropsBySig.get(sig);
      if (!mine) { mine = new Map(); cropsBySig.set(sig, mine); }
      let allow = cropAllowance(sig);
      for (const p of doc.parts || []) {
        if (!p.box || p.box.w <= 0 || p.box.h <= 0) continue;
        // Only the parts worth a picture of their own: a control, or something
        // the page named.
        if (!p.interactive && !p.id && !p.testid) continue;
        // ALREADY PHOTOGRAPHED, ON THIS SAME SCREEN. The picture on disk is the
        // picture of this part; the reading is new, the crop is not.
        const already = mine.get(p.index);
        if (already) { p.crop = already; continue; }
        if (allow <= 0 || partCrops >= PARTS_CROP_CAP) continue;
        const name = PREFIX + "-" + tag + "-part-" + String(p.index).padStart(2, "0");
        try {
          const clip = { x: p.box.x, y: p.box.y, width: p.box.w, height: p.box.h, scale: 1 };
          const r = await send("Page.captureScreenshot", { format: "png", clip, captureBeyondViewport: true }, S);
          fs.writeFileSync(path.join(OUT, name + ".png"), Buffer.from(r.data, "base64"));
          fs.writeFileSync(path.join(OUT, name + ".txt"),
            name + " — " + (p.name || p.id || p.tag) + ", clipped to it alone, at " +
            scaleApplied + "x, on " + at + "\n");
          p.crop = name;
          mine.set(p.index, name);
          partCrops++; allow--;
        } catch (e) { p.cropError = e.message; }
      }
      partPages.push({ url: at, sig: sig, title: doc.title || "", parts: doc.parts || [],
                       droppedParts: doc.droppedParts || 0 });
      if (partPages.length > 12) partPages.shift();
    } catch (e) {
      notes.push("the parts pass could not run on " + currentUrl + ": " + e.message);
    }
  }

  /* ── A READOUT PER SCREEN (S220 part D, carry-over) ────────────────────────
   * `readout.json` is written ONCE, at the end of a driver run, so the layout
   * pass — overflow, wrapping, clipping, crowding, misalignment — only ever
   * saw the screen the round happened to END on. Measured on the real
   * benchmark: five screens visited, two of them ever measured. Every screen
   * the look stands on gets its own reading here, and `readouts.json` carries
   * them all, so the layout pass runs on each and every finding can name the
   * screen it was seen on. */
  const readoutPages = [];
  async function snapReadout() {
    try {
      const doc = await readout();
      const at = String((doc && doc.url) || currentUrl);
      const sig = at + "|" + screenSig(doc);
      for (let i = readoutPages.length - 1; i >= 0; i--) {
        if (readoutPages[i].sig === sig) readoutPages.splice(i, 1);
      }
      readoutPages.push({ url: at, sig: sig, title: doc.title || "", page: doc });
      if (readoutPages.length > 12) readoutPages.shift();
    } catch (e) {
      notes.push("the layout reading could not be taken on " + currentUrl + ": " + e.message);
    }
  }

  async function snapScreen(tag) {
    await snapParts(tag);
    await snapReadout();
  }

  /* ── THE WALK (S220 part F) ────────────────────────────────────────────────
   * Enter at the front door and move through the app's OWN controls, step by
   * declared step. Nothing here chooses where to go: the steps come from the
   * record. What this decides is only whether each one HAPPENED, and it says
   * so either way — a step whose control is not on the screen is recorded
   * `unreachable`, by name, with the names that WERE on the screen beside it,
   * and the walk carries on to the next step rather than stopping the look.
   */
  const walk = { entry: URL_, steps: [], actions: [],
                 moves: { clicks: 0, typings: 0, keypresses: 0, addressJumps: 0 } };
  function excerpt(doc) {
    return String((doc && doc.textExcerpt) || "").replace(/\s+/g, " ").trim().slice(0, 1200);
  }
  async function probe(match) {
    try {
      const r = await send("Runtime.evaluate",
        { expression: ACT({ do: "probe", match: match }), returnByValue: true }, S);
      return (r && r.result && typeof r.result.value === "string") ? JSON.parse(r.result.value) : null;
    } catch (_) { return null; }
  }

  /* FINDING THE WAY IN (S220 part F). The app's front door is not always the
   * drawing's first screen — on the real benchmark the front door is one view
   * and the drawn flow lives behind a nav item. A person clicks their way in;
   * so does this. The names come from the record (the first screen's own
   * headings, the mission's title), never from a guess at a URL. */
  async function findTheWayIn(firstStep) {
    if (!firstStep || !journeyDoc.entry.length) return null;
    const there = await probe(firstStep.match || []);
    if (there && there.ok) return null;
    for (const hint of journeyDoc.entry) {
      const r = await send("Runtime.evaluate",
        { expression: ACT({ do: "click", match: [hint] }), returnByValue: true }, S);
      const res = (r && r.result && typeof r.result.value === "string") ? JSON.parse(r.result.value) : null;
      if (!res || !res.ok || !res.clicked) continue;
      walk.moves.clicks += 1;
      walk.actions.push({ click: res.name || hint });
      await sleep(600);
      try { await settle(); } catch (_) {}
      const now = await probe(firstStep.match || []);
      const rec = { key: "j0", name: 'find the way in by clicking "' + (res.name || hint) + '"',
                    do: "click", match: [hint], matched: res.name || null,
                    status: (now && now.ok) ? "done" : "done",
                    reachedFirstScreen: !!(now && now.ok) };
      rec.shot = PREFIX + "-walk-00-wayin";
      try { await shoot(rec.shot, null); } catch (_) {}
      await snapScreen("w0");
      walk.steps.push(rec);
      if (now && now.ok) return rec;
    }
    return null;
  }

  /* ONE PLACE THAT BUILDS A KEY EVENT (S221 fix 7). The action list and the
   * declared journey both press keys now, and two copies of this payload is
   * exactly how a `hold` ends up working in one path and silently not in the
   * other. Everything measured the hard way lives here:
   *
   *   1. The tab this driver opens is NOT the browser's active one, and Input
   *      events go to the active one. Without activating it first the dispatch
   *      never comes back AT ALL — the whole look dies on a CDP timeout, not on
   *      a bad key.
   *   2. `nativeVirtualKeyCode` sends headless Chrome into a runaway AUTO-REPEAT:
   *      one press measured 729 keydowns in 150 ms and was still climbing 600 ms
   *      after the keyUp. Sent without it, one press is exactly one key event.
   *   3. `hold` is real wall-clock time between the down and the up — the only
   *      thing a game loop reading "is this key down right now" can respond to.
   */
  async function dispatchKey(d, mods, hold, reps) {
    /* BOUNDED, because this one can hang (S221 fix 7, measured). Activating
     * the tab is required — Input events go to the ACTIVE tab and without it
     * the dispatch never returns at all — but the call itself does not always
     * come back either, and a look now runs under a 45-minute cage. An
     * unbounded await here spends the whole cage on one keystroke. So it is
     * raced against a short timer: if it does not answer, the press is tried
     * anyway (the tab is usually already active) rather than the look dying.
     */
    const bounded = (pr, ms) => Promise.race([
      pr.catch(() => null),
      new Promise((res) => setTimeout(() => res("timeout"), ms)),
    ]);
    if (await bounded(send("Target.activateTarget", { targetId: t.targetId }), 4000) === "timeout") {
      notes.push("the browser did not answer when asked to bring its tab forward; the key was sent anyway");
    }
    await bounded(send("Page.bringToFront", {}, S), 4000);
    const common = { modifiers: mods, key: d.key, code: d.code,
                     windowsVirtualKeyCode: d.vk, autoRepeat: false,
                     isKeypad: false, location: 0 };
    for (let k = 0; k < reps; k++) {
      await send("Input.dispatchKeyEvent",
        Object.assign({ type: "keyDown", text: d.text, unmodifiedText: d.text }, common), S);
      if (hold > 0) await sleep(hold);
      await send("Input.dispatchKeyEvent", Object.assign({ type: "keyUp" }, common), S);
      await sleep(hold > 0 ? 60 : 30);
    }
  }

  /* DID THE PICTURE MOVE? (S221 fix 7.) A journey step is only taken if
   * something CHANGED, and the existing test for that reads the url and the
   * page's TEXT — which on a canvas build never change, however far the
   * character walked. So a press step is judged on its two pictures instead:
   * the same statistics `pngStats` already computes for every shot. Any
   * difference at all counts, because a build that answers a key answers it
   * visibly.
   *
   * WHAT THIS WOULD MISS — and on the build it was written for it MISSES IT
   * EVERY TIME, so this is not a caveat, it is the state of the mechanism. A
   * page with an idle animation or a clock changes between any two shots.
   * Measured by the tester on 2026-09-20: pressing `q`, a key the example game
   * ignores completely, came back "changed" — the only differing pixels were a
   * 42x58 patch of the character's own idle animation, while the tile readout
   * read `Tile 10, 10` before and after. So on any animating build this is a
   * rubber stamp: it can say a step RAN, and it can never say a key was
   * ANSWERED. Nothing that reads it may claim otherwise (S221 fix 8b).
   *
   * THE CURE, ledgered and not built tonight: take a third shot with NO key
   * pressed and require the keyed difference to exceed that idle difference.
   * That needs its own proof, so until it exists the verdict on a key press
   * comes from the LOOK, by eye, with the before and after pair in front of it.
   */
  function pictureMoved(a, b) {
    if (!a || !b || a.error || b.error) return false;
    return a.distinctColours !== b.distinctColours
        || a.dominantColour !== b.dominantColour
        || Math.abs((a.dominantFraction || 0) - (b.dominantFraction || 0)) > 0.0005
        || !a.mean || !b.mean
        || a.mean.r !== b.mean.r || a.mean.g !== b.mean.g || a.mean.b !== b.mean.b;
  }

  /* ── ONE PLACE THAT TAKES A STEP, AND ONE THAT SCORES IT (S225) ────────────
   * A step can now be tried TWICE — once, and once more after the screen's own
   * refusal has been answered — and a second copy of "ask the browser to do the
   * thing" is how the two attempts end up being subtly different actions. So
   * both the doing and the scoring are lifted out of the loop and shared.
   */
  async function actOnStep(rec, step) {
    const r = await send("Runtime.evaluate",
      { expression: ACT({ do: rec.do === "gate" ? "click"
                            : rec.do === "type-all" ? "typeall" : rec.do,
                          match: rec.match, text: step.text }), returnByValue: true }, S);
    let res = (r && r.result && typeof r.result.value === "string") ? JSON.parse(r.result.value) : null;
    if ((!res || res.ok === false) && rec.do === "type") {
      // A FIELD IS A FIELD. The record names it by what the DRAWING put in
      // it ("gh/gh remains the long pole…") and the build labels it by what
      // it asks for ("Add an insight for this KPI…"). A person fills the
      // empty box in front of them, so when the named one is not there the
      // first empty field is typed into and the record says which.
      const r2 = await send("Runtime.evaluate",
        { expression: ACT({ do: "type", match: [], text: step.text }), returnByValue: true }, S);
      const alt = (r2 && r2.result && typeof r2.result.value === "string") ? JSON.parse(r2.result.value) : null;
      if (alt && alt.ok) { res = alt; rec.byFallback = "the first empty field on the screen"; }
    }
    return res;
  }

  /* What the result MEANS for this step, and what it adds to the tally of what
   * the look actually did. Called once per attempt: an attempt that clicked is
   * a click that happened, whether or not it was the first. */
  function scoreStep(rec, res, step) {
    rec.matched = res.name || null;
    rec.disabled = !!res.disabled;
    if (res.refusalText) rec.saidByTheControl = String(res.refusalText);
    if (rec.do === "type-all") {
      /* D6: every field the screen still wants, and by NAME the ones it
       * would not take. "I filled 2 of 19" is the honest number; "9 of 9
       * steps taken" over a form that was never filled is not. */
      rec.typed = String(step.text || "");
      rec.filled = Number(res.filled || 0);
      rec.fieldsOnScreen = Number(res.fieldsOnScreen || 0);
      rec.filledNames = res.names || [];
      rec.typedValues = res.typedValues || [];
      rec.couldNotFill = res.leftNames || [];
      rec.status = rec.filled > 0 ? "done" : "refused";
      if (rec.couldNotFill.length) {
        rec.why = "I could not fill " + rec.couldNotFill.length + " field(s): " +
                  rec.couldNotFill.slice(0, 6).join(", ");
        notes.push("on \"" + rec.name + "\" I filled " + rec.filled +
                   " field(s) and could not fill " + rec.couldNotFill.length + ": " +
                   rec.couldNotFill.slice(0, 6).join(", "));
      }
      walk.moves.typings += rec.filled;
      for (let k = 0; k < rec.filledNames.length; k++) {
        walk.actions.push({ type: rec.filledNames[k],
                            text: rec.typedValues[k] === undefined ? rec.typed : rec.typedValues[k] });
      }
    } else if (rec.do === "type") {
      rec.typed = res.typed || "";
      rec.readBack = res.readBack || "";
      rec.status = res.readBack ? "done" : "refused";
      walk.moves.typings += 1;
      walk.actions.push({ type: rec.matched || "(the field)", text: rec.typed });
    } else if (rec.do === "press") {
      // A PRESS HAS NOTHING TO CLICK (S221 fix 7). Falling through to the
      // click branch made every key press "refused" — res.clicked is
      // undefined because no element was ever looked for — and a step the
      // record asked for, that the build answered, read as one the build
      // turned down. It is done; whether it CHANGED anything is decided by
      // the picture pair below, which is the honest question here.
      rec.status = "done";
    } else {
      rec.clicked = !!res.clicked;
      rec.status = res.clicked ? "done" : "refused";
      if (res.clicked) {
        walk.moves.clicks += 1;
        walk.actions.push({ click: rec.matched || (rec.match[0] || "(a control)") });
      }
    }
  }

  /* THE WORDS THAT ARE NEW ON THE SCREEN. A validation message is very often
   * the only thing that changed, and it is short and on the same address. Long
   * new text, or a new address, is a page the step went THROUGH to — not a
   * sentence it was refused with — so neither counts here. */
  function newOnScreen(before, after, sameUrl) {
    if (!sameUrl) return "";
    const a = String(after || ""), b = String(before || "");
    if (!a || a === b) return "";
    const fresh = a.split(/(?<=[.!?:;])\s+/)
                   .map((s) => s.trim())
                   .filter((s) => s.length > 2 && b.indexOf(s) < 0);
    const text = fresh.join(" ");
    return text.length > 240 ? "" : text;
  }

  /* The text a repair puts in a field the refusal named. The journey's own
   * words when it has any — the same sentence the whole-form fill uses, so a
   * reader sees one voice in the boxes — and a plain one otherwise. */
  const REPAIR_TEXT = String((journey.filter((s) => s && s.text)[0] || {}).text ||
                             "Number One filled this because the screen asked for it");

  async function walkTheJourney() {
    if (!journey.length) return;
    await findTheWayIn(journey[0]);
    let i = 0;
    for (const step of journey) {
      i++;
      const key = String(step.key || "j" + i);
      const rec = { key, name: String(step.name || key), do: String(step.do || "click"),
                    phase: step.phase || null,
                    match: step.match || [], expect: step.expect || null };
      let before = null;
      try { before = await readout(); } catch (_) {}
      rec.urlBefore = (before && before.url) || currentUrl;
      rec.textBefore = excerpt(before);
      let res = null;
      /* A KEY IS A CONTROL (S221 fix 7). A press step does not go through ACT
       * — there is no element to find and nothing to click. It takes its own
       * BEFORE picture first, because on a canvas build the picture is the only
       * place a change can show. */
      let pxBefore = null, keyedFrom = 0;
      if (rec.do === "press") {
        const d = keyDescriptor(String(step.pressKey || ""));
        if (!d) {
          rec.status = "unreachable";
          rec.couldNotCheck = "not a key this browser can press";
          rec.why = "the record names `" + String(step.pressKey || "") +
                    "`, which is not a key I can press";
          notes.push("journey step \"" + rec.name + "\": `" + String(step.pressKey || "") +
                     "` is not a key this browser can press");
          incomplete = true;
        } else {
          const hold = Math.min(Math.max(parseInt(step.hold, 10) || 0, 0), MAX_HOLD_MS);
          const reps = Math.min(Math.max(parseInt(step.times, 10) || 1, 1),
                                hold > 0 ? Math.max(1, Math.floor(MAX_HOLD_TOTAL_MS / hold)) : 50);
          rec.pressed = d.key; rec.holdMs = hold; rec.times = reps;
          try { pxBefore = await shoot(rec.shotBefore = PREFIX + "-walk-" +
                 String(i).padStart(2, "0") + "-" + key.replace(/[^A-Za-z0-9._-]+/g, "-") +
                 "-before", null); } catch (e) { rec.shotError = e.message; }
          // WHEN THE KEYED WINDOW OPENED. The idle control below has to watch
          // this build for the SAME length of time with no key, or it is not
          // a control — a shorter look would under-measure the drift and a
          // longer one would over-measure it.
          keyedFrom = Date.now();
          walk.moves.keypresses += reps;
          walk.actions.push(hold > 0 ? { press: d.key, times: reps, holdMs: hold }
                                     : { press: d.key, times: reps });
          /* THE WHOLE DISPATCH IS BOUNDED (S221 fix 7). Measured on a canvas
           * page driving a rAF loop: a press issued from the JOURNEY path can
           * leave a CDP call pending for ever — the same press from the action
           * list returns fine, and the cause is not yet understood. A look now
           * runs under a 45-minute cage, so an unbounded await here spends the
           * captain's whole night on one keystroke. It is raced against a
           * deadline generous enough for the longest legal hold, and a step
           * that does not come back is recorded as COULDN'T CHECK, by name —
           * never as taken, and never as a fault of the build.
           */
          const budget = 6000 + reps * (hold + 400);
          const finished = await Promise.race([
            dispatchKey(d, 0, hold, reps).then(() => "done").catch((e) => "failed: " + e.message),
            new Promise((r) => setTimeout(() => r("timeout"), budget)),
          ]);
          if (finished === "done") {
            res = { ok: true };
          } else {
            rec.status = "unreachable";
            rec.couldNotCheck = "the key could not be pressed";
            rec.why = "I asked the browser to press " + d.key +
                      (hold ? " and hold it " + hold + "ms" : "") +
                      " and it never came back (" + finished + "), so I could not try this step";
            notes.push("journey step \"" + rec.name + "\": the browser never finished the key press");
            incomplete = true;
          }
        }
      }
      try {
        if (rec.do !== "press") res = await actOnStep(rec, step);
      } catch (e) { rec.status = "unreachable"; rec.why = e.message; }
      if (!res || res.ok === false) {
        rec.status = "unreachable";
        rec.couldNotCheck = "unreachable";
        rec.why = (res && res.why) || rec.why || "the control this step names was not on the screen";
        rec.onScreen = (res && res.onScreen) || [];
        notes.push("the journey step \"" + rec.name + "\" could not be taken: " +
                   rec.why + " — reached by address, no; not reached at all");
        walk.steps.push(rec);
        incomplete = true;
        continue;
      }
      scoreStep(rec, res, step);
      await sleep(600);
      let after = null;
      try { after = await settle(); } catch (_) {}
      if (!after) { try { after = await readout(); } catch (_) {} }
      const url = (after && after.url) || currentUrl;
      currentUrl = url;
      rec.urlAfter = url;
      rec.textAfter = excerpt(after);
      rec.changed = rec.urlAfter !== rec.urlBefore || rec.textAfter !== rec.textBefore;

      /* ── A REFUSAL CARRIES ITS TEXT, AND IS ANSWERED ONCE (S225) ────────────
       * THE ROW THIS COST HIM. He clicked "Lock month" in his own app, read the
       * refusal, saw it wanted three missing insights, said "I can do that
       * easily", filled them, and locked it. This walked the same screen, filled
       * one field of three, clicked Lock month regardless, and wrote: "I did it
       * and the screen was the same before and after — same address, same words
       * — so I cannot say whether it worked." It could not tell a broken button
       * from a form it never got ready.
       *
       * So a step that meets a refusal now does what he did: read what the
       * screen said, do ONLY what that refusal named, and try the original
       * action ONE more time. Through on the retry and the step passes with the
       * repair on its record; refused again and it is a genuine fault with two
       * attempts behind it — never a shrug.
       *
       * WHY IT CANNOT WANDER. The only work it will do is work the product
       * itself asked for: a field the page marks required-and-empty or invalid,
       * or an empty field whose own name is in the words the refusal used. A
       * refusal that names nothing actionable is simply a refusal with its text
       * captured — there is no guessing branch. It never fires on a step that
       * went somewhere (the address must be unchanged), never fires twice, and
       * never fires on the gate's BLANK phase, where a refusal is the answer the
       * journey wanted.
       */
      /* WHICH STEPS CAN EVEN BE REFUSED. A `type` or `type-all` that came back
       * done DID fill its boxes — the read-back is the evidence — and the page's
       * words do not change when a textarea does, so "nothing changed" says
       * nothing about it. Only a step that was refused outright, or a click on a
       * control that was supposed to move the screen, is asked this question. */
      const actedOnControl = rec.do === "click" || rec.do === "gate";
      if (rec.do !== "press" && rec.status !== "unreachable" &&
          (rec.status === "refused" || actedOnControl)) {
        const blankGate = rec.do === "gate" && rec.phase === "blank";
        const sameUrl = rec.urlAfter === rec.urlBefore;
        const hint = newOnScreen(rec.textBefore, rec.textAfter, sameUrl);
        let said = null;
        try {
          const rr = await send("Runtime.evaluate",
            { expression: REFUSAL(hint), returnByValue: true }, S);
          said = (rr && rr.result && typeof rr.result.value === "string")
            ? JSON.parse(rr.result.value) : null;
        } catch (_) { said = null; }
        const marked = (said && said.marked) || [];
        // A message that was ALREADY on the screen before the step is the
        // page's furniture, not this step's answer. Only a fresh one decides
        // that a step which otherwise moved the screen was refused.
        const freshMarked = marked.filter((m) => (rec.textBefore || "").indexOf(m) < 0);
        const fromControl = rec.saidByTheControl ? [rec.saidByTheControl] : [];
        const metRefusal = rec.status === "refused" || !rec.changed ||
                           freshMarked.length > 0 || blankGate;
        if (metRefusal) {
          const words = fromControl.concat((said && said.said) || []).filter(Boolean);
          const text = words.join(" ").trim().slice(0, 400);
          if (text || (said && said.fields && said.fields.length)) {
            rec.refusal = { text: text, said: words.slice(0, 6),
                            asks: ((said && said.fields) || []).map((f) => f.name) };
          } else {
            // It refused and told us nothing. That is itself worth saying, and
            // the screen's own words are the next best evidence a reader has.
            rec.refusal = { text: "", said: [],
                            screenReads: String(rec.textAfter || "").slice(0, 300) };
          }
        }
        const asks = (metRefusal && !blankGate && sameUrl && said) ? (said.fields || []) : [];
        if (asks.length) {
          let fres = null;
          try {
            const fr = await send("Runtime.evaluate",
              { expression: FILL_FIELDS(asks.map((a) => ({ id: a.id, name: a.name, why: a.why })),
                                        REPAIR_TEXT), returnByValue: true }, S);
            fres = (fr && fr.result && typeof fr.result.value === "string")
              ? JSON.parse(fr.result.value) : null;
          } catch (_) { fres = null; }
          rec.repair = { becauseItSaid: (rec.refusal && rec.refusal.text) || "",
                         asked: asks.map((a) => a.name + " — " + a.why),
                         filled: (fres && fres.filled) || [],
                         couldNotFill: (fres && fres.left) || [] };
          if (rec.repair.filled.length) {
            walk.moves.typings += rec.repair.filled.length;
            for (const f of rec.repair.filled) {
              walk.actions.push({ type: f.name, text: f.value,
                                  because: "the screen refused and named this field" });
            }
            /* The state the retry is judged against is the state right HERE —
             * after the repair, before the second attempt. Comparing back to
             * before the first attempt would score the refusal message itself
             * as "the screen moved", and a build that refuses twice would read
             * as one that went through. */
            let mid = null;
            try { mid = await readout(); } catch (_) {}
            const urlMid = (mid && mid.url) || currentUrl;
            const textMid = excerpt(mid);
            rec.attempts = 2;
            let res2 = null;
            try { res2 = await actOnStep(rec, step); } catch (e) { res2 = null; }
            if (res2 && res2.ok !== false) scoreStep(rec, res2, step);
            await sleep(600);
            let after2 = null;
            try { after2 = await settle(); } catch (_) {}
            if (!after2) { try { after2 = await readout(); } catch (_) {} }
            currentUrl = rec.urlAfter = (after2 && after2.url) || currentUrl;
            rec.textAfter = excerpt(after2);
            rec.changed = rec.urlAfter !== rec.urlBefore || rec.textAfter !== rec.textBefore;
            const wentThrough = rec.status === "done" &&
                                (rec.urlAfter !== urlMid || rec.textAfter !== textMid);
            const names = rec.repair.filled.map((f) => f.name).join(", ");
            if (wentThrough) {
              rec.repaired = true;
              rec.changeEvidence = "refused, repaired, then through";
              delete rec.couldNotCheck;
              rec.why = "It refused" +
                        (rec.repair.becauseItSaid ? " and said: \"" + rec.repair.becauseItSaid + "\"" : "") +
                        ". I did exactly what it named — filled " + names +
                        " — tried the same thing again, and that time it went through.";
              notes.push("the journey step \"" + rec.name + "\" was refused, and the screen said " +
                         "what it wanted (" + (rec.repair.becauseItSaid || "nothing in words") +
                         "). I filled " + names + " and tried again, and it went through — so " +
                         "this step is taken, on the second attempt, not the first.");
            } else {
              rec.status = "refused";
              rec.refusedTwice = true;
              delete rec.couldNotCheck;
              rec.why = "It refused" +
                        (rec.repair.becauseItSaid ? " and said: \"" + rec.repair.becauseItSaid + "\"" : "") +
                        ". I did exactly what it named — filled " + names +
                        " — and tried again, and it refused a second time. This is the build, " +
                        "not a form I failed to get ready.";
              /* NOT `incomplete`. A look that asked twice and was turned down
               * twice is a COMPLETE look reporting a fault in the build; only
               * the harness failing to ask is an incomplete one. */
              notes.push("the journey step \"" + rec.name + "\" refused TWICE: it said what it " +
                         "wanted, I filled " + names + ", and it still would not go through.");
            }
          }
        }
        /* THE WHOLE POINT OF (a), on its own. A refusal that was never repaired
         * — because it named nothing anyone could act on — still says what it
         * told us, in the record, beside whatever else this step had to say. */
        if (rec.status === "refused" && !rec.repaired && !rec.refusedTwice &&
            rec.refusal && rec.refusal.text) {
          rec.why = (rec.why ? rec.why + " " : "") +
                    "It refused, and this is what it told me: \"" + rec.refusal.text + "\".";
          notes.push("the journey step \"" + rec.name + "\" refused, and said: \"" +
                     rec.refusal.text + "\"");
        }
      }
      /* A STEP THAT CHANGED NOTHING WAS NOT TAKEN (fix round 1, D6). On
       * 2026-09-19 the blank gate and the filled gate came back BYTE-IDENTICAL
       * — same address, same text, `changed:false` on both — and the record
       * still said 9 of 9 steps taken. Clicking a control and watching the
       * screen stay exactly as it was tells you nothing about whether the step
       * worked, so it is named for what it is: couldn't check.
       *
       * Two exceptions, both because the change IS somewhere else: typing
       * changes the FIELD (its read-back is the evidence, and a textarea's
       * value never shows in the page's text), and the gate's BLANK phase is
       * asking the gate to refuse — nothing changing is the answer it wanted. */
      /* A THIRD EXCEPTION, and it is a retraction (S221 fix 8a): a PRESS
       * step is not settled here at all. Its evidence is the picture pair
       * compared a few lines below, and this block used to push a note saying
       * the step "changed nothing at all, so it is couldn't-check, not taken"
       * which was never taken back when that comparison upgraded the status.
       * The tester read both: `walk.json` saying done, and this note saying
       * couldn't-check, about the SAME step — and both go to the worker. The
       * harness must not tell its own reader two opposite things about the one
       * fact this round exists to establish. So a press step is skipped here
       * and says its piece once, below, whichever way it goes. */
      /* A FOURTH EXCEPTION, and it is the point of S225: a step that was
       * REPAIRED and then went through is not a step that changed nothing, and
       * it must never end up wearing this sentence. And when the screen DID say
       * something on its way to refusing, that sentence is no longer true
       * either — "I cannot say whether it worked" is the wrong answer when the
       * screen told us exactly what it wanted. The status is unchanged (nothing
       * moved, so nothing is proven); the WORDS carry what was learnt. */
      if (rec.status === "done" && !rec.changed && !rec.repaired && rec.do !== "press" &&
          rec.do !== "type" && rec.do !== "type-all" &&
          !(rec.do === "gate" && rec.phase === "blank")) {
        rec.status = "no-change";
        rec.couldNotCheck = "nothing changed";
        const heard = rec.refusal && rec.refusal.text;
        rec.why = heard
          ? "I did it and the screen's address and words were the same before and after — " +
            "but it did not go silent: it said \"" + heard + "\". So it refused; it did not " +
            "simply fail to answer."
          : "I did it and the screen was the same before and after — same address, " +
            "same words — so I cannot say whether it worked";
        notes.push(heard
          ? "the journey step \"" + rec.name + "\" changed nothing on the screen, and the " +
            "screen said \"" + heard + "\" — so it REFUSED, which is a different thing from " +
            "a control that did nothing"
          : "the journey step \"" + rec.name + "\" changed nothing at all, so it is " +
            "couldn't-check, not taken");
      }
      rec.shot = PREFIX + "-walk-" + String(i).padStart(2, "0") + "-" + key.replace(/[^A-Za-z0-9._-]+/g, "-");
      let pxAfter = null;
      try { pxAfter = await shoot(rec.shot, null); } catch (e) { rec.shotError = e.message; }
      /* THE IDLE CONTROL — THE THIRD SHOT (S222 fix 1).
       *
       * S221 judged a press on a BEFORE and an AFTER, and on a build that
       * animates by itself that is a rubber stamp: the picture always differs,
       * so every key "worked". Measured by the tester on 2026-09-20 on the
       * captain's real game — `q`, a key it ignores completely, came back
       * `done`; the readout said `Tile 10, 10` before AND after; the only
       * differing pixels were a 42x58 patch of the character breathing.
       *
       * So a third picture is taken with NO KEY PRESSED, over a window the
       * same length as the keyed one, and it measures how much this build
       * changes ON ITS OWN. The keyed change has to EXCEED that. It is the
       * same comparison, given a control — no new mechanism, and nothing here
       * asks the build a question it cannot answer.
       *
       * The idle window starts AFTER the after-shot, so it is very slightly
       * longer than the keyed window (it also pays for its own capture). That
       * bias is deliberate and it is the safe direction: the control can only
       * over-state the drift, which makes a "taken" verdict harder to earn. */
      let pxIdle = null;
      if (rec.do === "press" && rec.status !== "unreachable" && pxBefore && pxAfter) {
        rec.idleWindowMs = Math.min(Math.max(Date.now() - keyedFrom, 300), IDLE_WINDOW_CAP_MS);
        await sleep(rec.idleWindowMs);
        const idleName = rec.shot + "-idle";
        try { pxIdle = await shoot(idleName, null); rec.shotIdle = idleName; }
        catch (e) { rec.shotError = rec.shotError || e.message; }
      }
      /* THE PRESS STEP IS JUDGED ON ITS PICTURES (S221 fix 7), and this has to
       * happen AFTER the shot, because the after-picture is the shot. On a
       * canvas build the url and the page text are identical before and after
       * however far the character walked, so the text comparison above calls
       * every key press "nothing changed" — which would turn a build that
       * works perfectly into a couldn't-check on every step. The shots are
       * also the evidence the look reads: a before and an after of the same
       * screen is how a person tells a readout that follows from one that is
       * merely present. */
      if (rec.do === "press" && rec.status !== "unreachable") {
        rec.pictureMoved = pictureMoved(pxBefore, pxAfter);
        const keyed = pictureDistance(pxBefore, pxAfter);
        const idle = pictureDistance(pxAfter, pxIdle);
        /* WITHOUT A CONTROL, THE OLD, WEAKER TEST — and it says so. A shot
         * that failed leaves no grid to compare, and a missing control must
         * never be read as a control that measured zero. */
        let answered = rec.pictureMoved;
        if (keyed !== null && idle !== null) {
          rec.keyedDistance = keyed;
          rec.idleDistance = idle;
          /* THE MARGIN, AND WHY IT IS THIS ONE. One idle shot is a single
           * noisy sample of a build's self-drift, so the keyed change must
           * beat DOUBLE it — a sample that happened to land low cannot pass a
           * key off as answered. And on a build that is perfectly still (idle
           * 0) the keyed change must still be worth more than two grid cells,
           * so image-compression and anti-aliasing noise in one cell cannot
           * do it either. */
          rec.beatIdle = keyed > Math.max(2 * idle, idle + IDLE_MARGIN);
          answered = rec.beatIdle;
        } else {
          rec.idleControl = "none — a shot could not be measured, so the keyed " +
                            "change was not compared against this build's own drift";
        }
        if (answered) {
          /* TAKEN. S221 fix 8b took out "something answered the key", which
           * the two-shot mechanism could not support. With the control it can
           * support MORE than that — the keyed change beat what this build
           * does with no key at all — but the sentence below still refuses to
           * read a changed picture ON ITS OWN as the evidence, because it is
           * not: the control is. The numbers are in the record either way, and
           * the three shots are on disk for the reader. */
          rec.status = "done";
          delete rec.couldNotCheck;
          rec.changeEvidence = rec.beatIdle === true ? "picture-beat-idle-control" : "picture-only";
          rec.why = "I pressed " + (rec.pressed || "the key") +
                    (rec.holdMs ? " and held it " + rec.holdMs + "ms" : "") +
                    ". The page's words are identical before and after — on a build that " +
                    "draws itself they always are — and the pictures differ. That means " +
                    "the step was TAKEN. A changed picture on its own is NOT evidence the " +
                    "key was answered, because a build that animates changes its picture " +
                    "whether or not it heard you" +
                    (rec.beatIdle === true
                      ? "; what settles it here is the un-keyed control shot — with no key at " +
                        "all this build changed " + fmtFrac(rec.idleDistance) + " of the " +
                        "picture over the same length of time, and with the key it changed " +
                        fmtFrac(rec.keyedDistance) + ", which is more"
                      : " — and there is no control shot for this step, so this is the weaker " +
                        "two-picture test") +
                    ". Compare the shots yourself and judge it by eye.";
          /* THE NOTE KEEPS S221 fix 8b's SENTENCE WHICHEVER WAY THIS WENT. A
           * changed picture ON ITS OWN is never the evidence — with a control
           * the control is, without one there is none — and the reader is
           * told that in both cases, because both cases reach them. */
          notes.push("the journey step \"" + rec.name + "\" was taken and its picture changed" +
                     (rec.beatIdle === true
                       ? " MORE than this build changes on its own with no key at all (" +
                         fmtFrac(rec.keyedDistance) + " against " + fmtFrac(rec.idleDistance) +
                         "). A changed picture by itself is NOT evidence the key was answered — " +
                         "the un-keyed control shot is what makes this one count. Read the " +
                         "before/after pair for this step and judge it by eye."
                       : " — but this build draws itself and there was no control shot for this " +
                         "step, so a changed picture is NOT evidence the key was answered. Read " +
                         "the before/after pair for this step and judge it by eye."));
        } else if (!rec.changed) {
          rec.status = "no-change";
          /* "THE PICTURE DID CHANGE" IS THE GRID'S ANSWER, NOT pictureMoved's.
           * pictureMoved reads whole-frame statistics, and a small animating
           * patch can move the grid while leaving those statistics alone — it
           * did on this fixture, intermittently. The branch has to key off the
           * measurement the verdict was actually made on. */
          if (rec.beatIdle === false && (rec.keyedDistance > 0 || rec.pictureMoved)) {
            /* THE CASE THIS FIX EXISTS FOR: the picture DID change, and it
             * changed no more than the build changes on its own. That is not
             * a key being answered; it is a build breathing. */
            rec.couldNotCheck = "no more than it changes on its own";
            rec.why = "I pressed " + (rec.pressed || "the key") +
                      (rec.holdMs ? " and held it " + rec.holdMs + "ms" : "") +
                      ", and the picture did change — but this build changes by itself. " +
                      "With no key pressed at all, over the same length of time, " +
                      fmtFrac(rec.idleDistance) + " of the picture changed; with the key, " +
                      fmtFrac(rec.keyedDistance) + " did. It changed as much as it changes " +
                      "on its own, so I cannot say whether the key was answered.";
            notes.push("the journey step \"" + rec.name + "\" changed the picture no more " +
                       "than this build changes on its own with no key at all (" +
                       fmtFrac(rec.keyedDistance) + " against " + fmtFrac(rec.idleDistance) +
                       "), so it is couldn't-check, not taken");
          } else {
            rec.couldNotCheck = "nothing changed";
            rec.why = "I pressed " + (rec.pressed || "the key") +
                      (rec.holdMs ? " and held it " + rec.holdMs + "ms" : "") +
                      ", and the screen was the same before and after — same words AND the " +
                      "same picture — so I cannot say whether it worked";
            notes.push("the journey step \"" + rec.name + "\" changed nothing at all — " +
                       "same words and the same picture — so it is couldn't-check, not taken");
          }
        }
      }
      await snapScreen("w" + i);
      walk.steps.push(rec);
    }
  }

  async function shoot(name, selector) {
    const page = await readout();
    let clip = null, clipNote = "";
    if (selector) {
      const r = await send("Runtime.evaluate", { expression: BOX_OF(selector), returnByValue: true }, S);
      const v = r && r.result ? r.result.value : "";
      if (!v) {
        // The element the drawing named is NOT THERE. That is a fact worth
        // recording — very possibly THE finding — so the shot still happens,
        // full page, and the readout says the selector was missing.
        clipNote = "the selector " + selector + " matched nothing; captured the full page instead";
        notes.push(clipNote);
        incomplete = true;
      } else {
        const b = JSON.parse(v);
        if (b.w > 0 && b.h > 0) clip = { x: b.x, y: b.y, width: b.w, height: b.h, scale: 1 };
        else {
          clipNote = "the selector " + selector + " matched an element with no laid-out box; captured the full page instead";
          notes.push(clipNote);
          incomplete = true;
        }
      }
    }
    const params = clip ? { format: "png", clip } : { format: "png", captureBeyondViewport: true };
    const r = await send("Page.captureScreenshot", params, S);
    const buf = Buffer.from(r.data, "base64");
    const png = path.join(OUT, name + ".png");
    fs.writeFileSync(png, buf);
    let pixels = null;
    try { pixels = pngStats(buf, scaleApplied); } catch (e) { pixels = { error: e.message, painted: false }; }
    fs.writeFileSync(path.join(OUT, name + ".json"), JSON.stringify({
      shot: name, file: png, capturedAt: new Date().toISOString(),
      selector: selector || null, clip: clip || "full-page",
      note: clipNote || undefined,
      // The scale the raster was taken at, so a reader of this file can divide
      // the pixel width back into the CSS width it actually shows.
      deviceScaleFactor: scaleApplied,
      pixels, page,
    }, null, 2) + "\n");
    // The caption is what the REPORT quotes. Screenshots do not travel between
    // laptops (ruling, ledgered) — this line does.
    fs.writeFileSync(path.join(OUT, name + ".txt"),
      name + " — " + (selector && clip ? "clipped to " + selector : "full page") +
      " of " + (page.url || currentUrl) +
      " (" + (pixels.width || "?") + "x" + (pixels.height || "?") + " px at " +
      scaleApplied + "x, " +
      (pixels.width ? Math.round(pixels.width / scaleApplied) : "?") + " CSS px wide), " +
      (pixels.distinctColours || 0) + " distinct colours, " +
      (pixels.painted ? "PAINTED" : "FLAT/BLANK") +
      (page.title ? ', title "' + page.title + '"' : "") +
      (clipNote ? " — " + clipNote : "") + "\n");
    shots.push({ name, file: png, selector: selector || null, painted: !!pixels.painted, pixels });
    return pixels;
  }

  await navigate(URL_);
  const first = await readout();
  if (first.elementsNote) notes.push(first.elementsNote);
  let n = 1;
  const nextName = () => PREFIX + "-" + String(n++).padStart(2, "0");

  /* ── DID ANYTHING RENDER? (S221 fix 6, captain's ruling) ──────────────────
   *
   * THE DEFECT THIS REPLACES. This gate used to ask "is there TEXT on the
   * page", and exit 1 — an accusation against the app — the moment there was
   * none, BEFORE a single action in the list ran. A canvas game is exactly
   * that page: a `<title>`, a `<canvas>`, and an empty body. So the example
   * game was scored LOW for "rendering nothing" while it sat there rendering
   * a whole world, and no key was ever pressed at it. Measured: both runs
   * exit 1, `walk.json` never written.
   *
   * WHAT IT ASKS NOW, and the boundary is the whole fix: a page with no text
   * gets its picture taken FIRST, and the question is whether that picture is
   * PAINTED — `pngStats`'s own long-standing measure, `distinctColours > 8 &&
   * nonDominantFraction > inkFloor`. So:
   *   • a page that truly laid out nothing — white, blank, one or two colours
   *     — is NOT painted, and exits 1 with the same sentence and the same
   *     picture-of-the-nothing it always did. Nothing about that case moved.
   *   • a page that is one flat fill and nothing else is ALSO not painted:
   *     one colour is one colour, `distinctColours` does not reach 9. That is
   *     deliberate — a solid background is far closer to blank than to a game,
   *     and a look that wandered it for 45 minutes would be worse than a fast
   *     honest failure.
   *   • a canvas with a world drawn in it is hundreds of colours and plenty of
   *     non-dominant ink. It proceeds, and gets walked.
   *
   * WHAT IT WOULD MISS, said plainly because the next reader deserves it:
   *   • a page that renders a rich BACKGROUND IMAGE or a decorative gradient
   *     and nothing else reads as painted and will be walked. It is a busy
   *     picture by every measure this driver has; only a human eye can call
   *     it empty.
   *   • the converse: a canvas app drawing something genuinely minimal — two
   *     flat rectangles on a flat field — can fall under the ink floor and be
   *     called blank. The floor is `pngStats`'s, calibrated on text, and this
   *     gate inherits it rather than inventing a second one.
   *   • it says nothing about whether the right thing rendered. "Something
   *     painted" is the floor for looking at all, never evidence of working.
   */
  if (!first.textExcerpt) {
    // The picture is needed either way — as the evidence of the nothing, or as
    // round 0's full-page shot — so it is taken once, under the name round 0
    // would have given it, and `n` carries on from there.
    const px = await shoot(nextName(), null);
    if (!px || !px.painted) {
      // The app did not lay out. That is the PRODUCT's answer, exit 1 — but the
      // evidence is written anyway, because "it rendered nothing" is a finding
      // and the caller needs the picture of the nothing.
      fs.writeFileSync(path.join(OUT, "readout.json"), JSON.stringify({
        url: currentUrl, painted: false, shots, notes: notes.concat(["the app never laid out any text at " + URL_]),
        places, page: first,
      }, null, 2) + "\n");
      console.error("the app never laid out any text at " + URL_);
      ws.close(); stopChrome(); process.exit(EXIT_PRODUCT);
    }
    /* IT PAINTED, AND THERE IS NOTHING HERE TO MEASURE — and that second half
     * has to be SAID. Every deterministic pass this harness runs reads the
     * DOM: the readout's element boxes, the layout/crowding pass, the
     * drawing-to-build part pairing. On a canvas app they all come back empty,
     * and an empty measurement is not a finding of absence — it is the absence
     * of a measurement. Unsaid, a look reads "0 findings" as "nothing wrong",
     * which is the confabulation this whole round exists to stop. So the
     * record says it, in the words the worker will read.
     */
    canvasOnly = true;
    walk.canvasOnly = true;
    notes.push("this page draws itself — there is no laid-out text or element on it to measure. " +
               "Every measurement pass here is blind, so nothing it reports as empty is evidence of absence: " +
               "judge this build BY EYE from the pictures, and say so.");
  }

  if (actions.length === 0) {
    /* ROUND 0 — the standard look: the whole page, then one CLIPPED shot per
     * place the drawing named AND THE APP ACTUALLY HAS. A name the app does not
     * have gets no shot and an explicit note, which is exactly the shape of a
     * "the drawing says X, the app has no X" finding. */
    // …unless the gate above already took it (a canvas app's only shot).
    if (!canvasOnly) await shoot(nextName(), null);
    for (const id of places) {
      const key = id.replace(/^#/, "");
      const pl = first.places[key];
      if (pl && pl.present && pl.laidOut) await shoot(nextName(), "#" + key);
      else {
        // A shot the drawing asked for and we could not take. That is exactly
        // what exit 3 means — and very possibly the finding itself, so it is
        // written down rather than quietly skipped.
        notes.push("the drawing names `#" + key + "`; the page " + (pl && pl.present ? "has it but it has no laid-out box" : "has no element with that id"));
        incomplete = true;
      }
    }
    await snapScreen("s0");
    await walkTheJourney();
  } else {
    for (const a of actions) {
      try {
        if (a.navigate) {
          /* A URL JUMP IS NOT A JOURNEY (S220 part F). The front door is the
           * one address the look is allowed to type; every later one is
           * recorded as what it is, and the screen it lands on is marked
           * "reached by address, not by the flow" so nobody reading the
           * report mistakes a teleport for a walk. */
          walk.moves.addressJumps += 1;
          const jump = { to: String(a.navigate), from: currentUrl };
          walk.jumps = (walk.jumps || []).concat([jump]);
          walk.actions.push({ navigate: String(a.navigate) });
          notes.push("reached by address, not by the flow: " + String(a.navigate));
          await navigate(String(a.navigate));
        }
        else if (a.click) {
          walk.moves.clicks += 1;
          walk.actions.push({ click: String(a.click) });
          const r = await send("Runtime.evaluate", { expression: CLICK(String(a.click)), returnByValue: true }, S);
          if (r.result && r.result.value === "no-such-element") {
            notes.push("click: nothing matched " + a.click);
            walk.moves.clicks -= 1;
            walk.actions.pop();
            incomplete = true;
          } else await sleep(400);
        } else if (a.type) {
          walk.moves.typings += 1;
          walk.actions.push({ type: String(a.type), text: String(a.text || "") });
          const r = await send("Runtime.evaluate", { expression: TYPE(String(a.type), String(a.text || "")), returnByValue: true }, S);
          if (r.result && r.result.value === "no-such-element") { notes.push("type: nothing matched " + a.type); incomplete = true; }
          else await sleep(200);
        } else if (a.press !== undefined) {
          const d = keyDescriptor(String(a.press));
          if (!d) {
            notes.push("press: `" + String(a.press) + "` is not a key this browser can press; nothing was pressed");
            incomplete = true;
          } else {
            // Aim it, when asked. A selector that matches nothing is the
            // finding, not a reason to press into the void.
            let aimed = true;
            if (a.selector) {
              const f = await send("Runtime.evaluate", { expression: FOCUS(String(a.selector)), returnByValue: true }, S);
              if (f.result && f.result.value === "no-such-element") {
                notes.push("press: nothing matched " + a.selector + "; the key was not pressed");
                incomplete = true;
                aimed = false;
              }
            }
            if (aimed) {
              /* TWO THINGS MEASURED HERE THE HARD WAY, both invisible to any
               * stub of this layer (S213):
               *
               * 1. The tab this driver opens is NOT the browser's active one,
               *    and Input events go to the active one. Without activating
               *    it first the dispatch never comes back AT ALL — the whole
               *    look dies on a CDP timeout, not on a bad key.
               * 2. `nativeVirtualKeyCode` sends headless Chrome into a runaway
               *    AUTO-REPEAT: one press measured 729 keydowns in 150 ms and
               *    was still climbing 600 ms later, long after the keyUp. Sent
               *    without it, one press is exactly one key event. So it is not
               *    sent, and the count the page sees is the count that was
               *    asked for.
               */
              const times = Math.min(Math.max(parseInt(a.times, 10) || 1, 1), 50);
              /* HOLDING THE KEY DOWN (S221). A tap is a keyDown and a keyUp in
               * the same breath, and for a great many builds that is exactly
               * right — a menu, a form, a focus walk. For anything that moves
               * WHILE a key is held it is useless: the example game walks its
               * character at 128 px/s, so a tap moves it about two pixels —
               * a sixteenth of one 32px tile — and Number One, looking at a
               * readout that has not changed, reports a DIDN'T-WORK against a
               * build that is perfectly correct. The prompt has been telling
               * it to "walk the character with the arrows" since S220; this is
               * the capability that sentence promised.
               *
               * `hold` is milliseconds between the down and the up. Absent or
               * 0 is the old tap, byte for byte.
               */
              const holdAsked = Math.max(parseInt(a.hold, 10) || 0, 0);
              const hold = Math.min(holdAsked, MAX_HOLD_MS);
              if (holdAsked > hold) {
                notes.push("press: a " + holdAsked + "ms hold is longer than this driver allows; held "
                           + hold + "ms instead");
              }
              /* AND A BUDGET ON THE WHOLE ACTION, not just one hold. `times`
               * alone clamps at 50; 50 x 2000ms is a hundred seconds from ONE
               * entry, and twelve of those would eat a third of the 45-minute
               * cage a look now runs under. So the repeats are cut to fit a
               * total, and the cut is SAID — a look that quietly did six of the
               * twenty walks it asked for would reason from a distance it never
               * travelled.
               */
              let reps = times;
              if (hold > 0) {
                const fits = Math.max(1, Math.floor(MAX_HOLD_TOTAL_MS / hold));
                if (reps > fits) {
                  notes.push("press: " + times + " x " + hold + "ms is longer than one action may hold a key; did "
                             + fits + " of them");
                  incomplete = true;
                  reps = fits;
                }
              }
              walk.moves.keypresses += reps;
              const rec = { press: d.key, times: reps };
              if (hold > 0) rec.holdMs = hold;
              walk.actions.push(rec);
              await dispatchKey(d, modifierMask(a.modifiers), hold, reps);
              // RECORDED, not left to be inferred from what the page ended up
              // looking like: the evidence says which key went in, how often,
              // and — since S221 — whether it was HELD and for how long. A
              // report that cannot tell a tap from a walk cannot show the
              // captain that his character was walked.
              notes.push("pressed " + d.key + (reps > 1 ? " x" + reps : "") +
                         (hold > 0 ? (reps > 1 ? ", each held down " + hold + "ms"
                                               : ", held down " + hold + "ms") : "") +
                         (a.modifiers && a.modifiers.length ? " with " + a.modifiers.join("+") : "") +
                         (a.selector ? " into " + a.selector : ""));
              await sleep(200);
            }
          }
        } else if (a.wait !== undefined) {
          await sleep(Math.min(parseInt(a.wait, 10) || 0, 10000));
        } else if (a.screenshot) {
          // Names come from the worker. Keep them to a filename-safe alphabet so
          // no action list can ever write outside --out.
          const safe = String(a.screenshot).replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[.-]+/, "") || nextName();
          await shoot(safe, a.selector ? String(a.selector) : null);
        } else if (a.do === "run" || a.do === "workflow" || a.do === "read") {
          /* S239 fix round 1 (D5) — A HARNESS STEP WAS NOT DROPPED, SO DO NOT
           * SAY IT WAS. One actions file goes to two executors: the browser
           * kinds come here, and `run` / `workflow` / `read` are run by
           * xo-run.py in the detached worktree with its throwaway HOME. This
           * loop used to fall through to the unknown-action fallback and
           * journal "unknown action, skipped: {...}" for each of them, and set
           * `incomplete`. THE WORKER READS THESE NOTES, so a step that really
           * ran reached its next round labelled dropped. The browser still
           * does nothing with it; it now says that honestly.
           */
          notes.push(a.do + ": handed to the harness, not the browser — it runs in "
                     + "the detached worktree and leaves its own transcript");
        } else {
          notes.push("unknown action, skipped: " + JSON.stringify(a));
          incomplete = true;
        }
      } catch (e) {
        if (e instanceof Infra) throw e;
        notes.push("action failed (" + JSON.stringify(a) + "): " + e.message);
        incomplete = true;
      }
      // EVERY SCREEN IT STANDS ON. A click that changed nothing costs one
      // evaluate and replaces the reading for that same url.
      await snapScreen("a" + partPages.length);
    }
    if (shots.length === 0) {
      // An action round that took no picture saw nothing anyone can check.
      await shoot(nextName(), null);
      notes.push("the action list named no screenshot; one full-page shot was taken so the round has evidence");
    }
  }

  /* ── THE PARTS PASS, and the crop of each part ──────────────────────────
   * Last, so the page is in the state the look left it in: the parts of the
   * screen it ENDED on are the parts worth pairing with the drawing.
   * Best-effort in the same way the observations pass is — a page that will
   * not answer this must never be why a look cannot finish. */
  await snapReadout();
  if (PARTS_OUT) {
    await snapParts("end");
    // EVERY SCREEN, AND A FLAT LIST OF ALL OF THEM. `pages` is the record;
    // `parts` is every part of every screen, each carrying the screen it is
    // on, so a reader that wants one list gets one that is not a lie about
    // where things were.
    const flat = [];
    for (const pg of partPages) {
      for (const p of pg.parts || []) flat.push(Object.assign({ screen: pg.url }, p));
    }
    try {
      fs.mkdirSync(path.dirname(path.resolve(PARTS_OUT)), { recursive: true });
      fs.writeFileSync(PARTS_OUT, JSON.stringify({
        url: currentUrl, screens: partPages.map((p) => p.url),
        pages: partPages, parts: flat, cropped: partCrops,
        // THE BUDGET, WRITTEN DOWN. `cropped` alone cannot say whether the
        // pictures were spread or spent in one place; `croppedScreens` can,
        // and a reader (or a test) can see the bound was a bound.
        cropCap: PARTS_CROP_CAP, plannedSnaps: plannedSnaps,
        croppedScreens: Array.from(cropsBySig.values()).filter((m) => m.size > 0).length,
      }, null, 2) + "\n");
    } catch (e) {
      notes.push("the parts record could not be written: " + e.message);
    }
  }

  const page = await readout();
  fs.writeFileSync(path.join(OUT, "readout.json"), JSON.stringify({
    url: currentUrl, painted: shots.every((s) => s.painted), places, notes,
    shots: shots.map((s) => ({ name: s.name, selector: s.selector, painted: s.painted, pixels: s.pixels })),
    page,
  }, null, 2) + "\n");

  /* EVERY SCREEN'S READING, not just the last one's (S220 part D carry-over).
   * `readout.json` above stays exactly as it was — callers read it — and this
   * is the same thing once per screen, so the layout pass can run on each and
   * name the screen in every finding. */
  try {
    fs.writeFileSync(path.join(OUT, "readouts.json"), JSON.stringify({
      screens: readoutPages.map((p) => p.url),
      pages: readoutPages, notes,
    }, null, 2) + "\n");
  } catch (e) { notes.push("the per-screen readings could not be written: " + e.message); }

  /* THE RECORD OF HOW IT MOVED (S220 part F) — clicks, typings, keypresses and
   * every address jump past the front door, plus each declared step and
   * whether it happened. Written whatever the look did: a walk that teleported
   * is recorded as a walk that teleported. */
  if (WALK_OUT) {
    try {
      fs.mkdirSync(path.dirname(path.resolve(WALK_OUT)), { recursive: true });
      let prior = null;
      try { prior = JSON.parse(fs.readFileSync(WALK_OUT, "utf8")); } catch (_) { prior = null; }
      const out = { entry: (prior && prior.entry) || walk.entry,
        steps: ((prior && prior.steps) || []).concat(walk.steps),
        actions: ((prior && prior.actions) || []).concat(walk.actions),
        jumps: ((prior && prior.jumps) || []).concat(walk.jumps || []),
        screens: readoutPages.map((p) => p.url),
        moves: { clicks: ((prior && prior.moves && prior.moves.clicks) || 0) + walk.moves.clicks,
                 typings: ((prior && prior.moves && prior.moves.typings) || 0) + walk.moves.typings,
                 keypresses: ((prior && prior.moves && prior.moves.keypresses) || 0) + walk.moves.keypresses,
                 addressJumps: ((prior && prior.moves && prior.moves.addressJumps) || 0) + walk.moves.addressJumps } };
      /* S221 fix 6 — CARRIED, not dropped. This writer builds a NEW object
       * with an explicit field list, so anything set on `walk` that is not
       * named right here vanishes silently (which is exactly how it ate
       * `canvasOnly` the first time). Sticky across rounds like the counters
       * above: once a look has seen a page with nothing to measure, every
       * later round's record still says so. */
      if (canvasOnly || (prior && prior.canvasOnly)) out.canvasOnly = true;
      fs.writeFileSync(WALK_OUT, JSON.stringify(out, null, 2) + "\n");
    } catch (e) { notes.push("the walk record could not be written: " + e.message); }
  }

  ws.close(); stopChrome();
  const allPainted = shots.length > 0 && shots.every((s) => s.painted);
  console.log(JSON.stringify({
    url: currentUrl, allPainted, notes,
    shots: shots.map((s) => ({ name: s.name, selector: s.selector, painted: s.painted, distinctColours: s.pixels.distinctColours })),
  }, null, 2));
  process.exit(!allPainted ? EXIT_PRODUCT : (incomplete ? EXIT_INCOMPLETE : EXIT_OK));
})().catch((e) => {
  try { stopChrome(); } catch (_) {}
  console.error((e instanceof Infra ? "INFRA: " : "ERROR: ") + e.message);
  process.exit(e instanceof Infra ? EXIT_INFRA : EXIT_PRODUCT);
});
