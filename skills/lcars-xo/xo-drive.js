"use strict";
/* ═══════════════════════════════════════════════════════════════════════════
 * xo-drive.js — Number One's browser. Zero dependencies, raw CDP, HEADLESS.
 *
 *   node xo-drive.js --url URL --out DIR
 *                    [--actions FILE] [--place-names FILE]
 *                    [--chrome PATH] [--timeout MS] [--max-actions N]
 *                    [--devtools-port N]
 *
 * It opens the app Number One is judging, walks it, and leaves behind EVIDENCE:
 * one PNG per shot, and beside every PNG a `.json` readout of what the page
 * actually said (url, title, a visible-text excerpt, the box + computed colour
 * of each named place, console errors, and the PNG's own pixel statistics) plus
 * a one-line `.txt` caption.
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

/* ── the PNG sampler ─────────────────────────────────────────────────────────
 * A screenshot that is ONE FLAT COLOUR is not a render, and a driver that
 * cannot tell the difference will happily hand a worker a blank frame to score
 * an app on. So every PNG is decoded here (node's own zlib, no dependency) and
 * reported: distinct colours, the dominant colour and its share, the mean
 * channels. `painted` is the honest summary of those numbers.
 * Lifted, unchanged in substance, from the S203 probe that proved it. */
function pngStats(buf) {
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
  for (let y = 0; y < h; y += 2) for (let x = 0; x < w; x += 2) {
    const o = y * stride + x * bpp, r = out[o], g = out[o + 1], bl = out[o + 2];
    const k = (r << 16) | (g << 8) | bl;
    counts.set(k, (counts.get(k) || 0) + 1);
    sr += r; sg += g; sb += bl; n++;
  }
  let topKey = 0, topN = 0;
  for (const [k, v] of counts) if (v > topN) { topN = v; topKey = k; }
  const hex = (k) => "#" + k.toString(16).padStart(6, "0");
  return {
    width: w, height: h, sampled: n,
    distinctColours: counts.size,
    dominantColour: hex(topKey),
    dominantFraction: +(topN / n).toFixed(4),
    nonDominantFraction: +(1 - topN / n).toFixed(4),
    mean: { r: Math.round(sr / n), g: Math.round(sg / n), b: Math.round(sb / n) },
    painted: counts.size > 8 && (1 - topN / n) > 0.01,
  };
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

/* The page reader — ONE evaluate, returning facts and never opinions. */
const READ = (places) => `(function () {
  var ids = ${JSON.stringify(places)};
  function box(el) { var r = el.getBoundingClientRect(); return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }; }
  var out = { url: location.href, title: document.title, textExcerpt: (document.body ? (document.body.innerText || "") : "").replace(/[ \\t\\r\\n]+/g, " ").trim().slice(0, 2000), places: {} };
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

/* ── the drive ───────────────────────────────────────────────────────────── */
(async () => {
  const places = readPlaceNames(PLACES_FILE);
  let actions = readActions(ACTIONS_FILE);
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
        const r = await send("Runtime.evaluate", { expression: READ(places), returnByValue: true }, S);
        if (r && r.result && typeof r.result.value === "string") {
          last = JSON.parse(r.result.value);
          const named = places.length === 0 || places.some((id) => {
            const p = last.places[id.replace(/^#/, "")];
            return p && p.laidOut;
          });
          if (last.textExcerpt && named) return last;
        }
      } catch (_) {}
      await sleep(250);
    }
    return last;
  }

  async function readout() {
    const r = await send("Runtime.evaluate", { expression: READ(places), returnByValue: true }, S);
    const doc = (r && r.result && typeof r.result.value === "string") ? JSON.parse(r.result.value) : { url: currentUrl, title: "", textExcerpt: "", places: {} };
    doc.consoleErrors = events
      .filter((e) => e.method === "Log.entryAdded" && e.params.entry.level === "error")
      .map((e) => e.params.entry.text)
      .slice(-20);
    return doc;
  }

  const shots = [];
  let incomplete = false;

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
    try { pixels = pngStats(buf); } catch (e) { pixels = { error: e.message, painted: false }; }
    fs.writeFileSync(path.join(OUT, name + ".json"), JSON.stringify({
      shot: name, file: png, capturedAt: new Date().toISOString(),
      selector: selector || null, clip: clip || "full-page",
      note: clipNote || undefined,
      pixels, page,
    }, null, 2) + "\n");
    // The caption is what the REPORT quotes. Screenshots do not travel between
    // laptops (ruling, ledgered) — this line does.
    fs.writeFileSync(path.join(OUT, name + ".txt"),
      name + " — " + (selector && clip ? "clipped to " + selector : "full page") +
      " of " + (page.url || currentUrl) +
      " (" + (pixels.width || "?") + "x" + (pixels.height || "?") + "), " +
      (pixels.distinctColours || 0) + " distinct colours, " +
      (pixels.painted ? "PAINTED" : "FLAT/BLANK") +
      (page.title ? ', title "' + page.title + '"' : "") +
      (clipNote ? " — " + clipNote : "") + "\n");
    shots.push({ name, file: png, selector: selector || null, painted: !!pixels.painted, pixels });
    return pixels;
  }

  await navigate(URL_);
  const first = await readout();
  if (!first.textExcerpt) {
    // The app did not lay out. That is the PRODUCT's answer, exit 1 — but the
    // evidence is written anyway, because "it rendered nothing" is a finding
    // and the caller needs the picture of the nothing.
    await shoot(PREFIX + "-01", null);
    fs.writeFileSync(path.join(OUT, "readout.json"), JSON.stringify({
      url: currentUrl, painted: false, shots, notes: notes.concat(["the app never laid out any text at " + URL_]),
      places, page: first,
    }, null, 2) + "\n");
    console.error("the app never laid out any text at " + URL_);
    ws.close(); stopChrome(); process.exit(EXIT_PRODUCT);
  }

  let n = 1;
  const nextName = () => PREFIX + "-" + String(n++).padStart(2, "0");

  if (actions.length === 0) {
    /* ROUND 0 — the standard look: the whole page, then one CLIPPED shot per
     * place the drawing named AND THE APP ACTUALLY HAS. A name the app does not
     * have gets no shot and an explicit note, which is exactly the shape of a
     * "the drawing says X, the app has no X" finding. */
    await shoot(nextName(), null);
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
  } else {
    for (const a of actions) {
      try {
        if (a.navigate) { await navigate(String(a.navigate)); }
        else if (a.click) {
          const r = await send("Runtime.evaluate", { expression: CLICK(String(a.click)), returnByValue: true }, S);
          if (r.result && r.result.value === "no-such-element") { notes.push("click: nothing matched " + a.click); incomplete = true; }
          else await sleep(400);
        } else if (a.type) {
          const r = await send("Runtime.evaluate", { expression: TYPE(String(a.type), String(a.text || "")), returnByValue: true }, S);
          if (r.result && r.result.value === "no-such-element") { notes.push("type: nothing matched " + a.type); incomplete = true; }
          else await sleep(200);
        } else if (a.wait !== undefined) {
          await sleep(Math.min(parseInt(a.wait, 10) || 0, 10000));
        } else if (a.screenshot) {
          // Names come from the worker. Keep them to a filename-safe alphabet so
          // no action list can ever write outside --out.
          const safe = String(a.screenshot).replace(/[^A-Za-z0-9._-]+/g, "-").replace(/^[.-]+/, "") || nextName();
          await shoot(safe, a.selector ? String(a.selector) : null);
        } else {
          notes.push("unknown action, skipped: " + JSON.stringify(a));
          incomplete = true;
        }
      } catch (e) {
        if (e instanceof Infra) throw e;
        notes.push("action failed (" + JSON.stringify(a) + "): " + e.message);
        incomplete = true;
      }
    }
    if (shots.length === 0) {
      // An action round that took no picture saw nothing anyone can check.
      await shoot(nextName(), null);
      notes.push("the action list named no screenshot; one full-page shot was taken so the round has evidence");
    }
  }

  const page = await readout();
  fs.writeFileSync(path.join(OUT, "readout.json"), JSON.stringify({
    url: currentUrl, painted: shots.every((s) => s.painted), places, notes,
    shots: shots.map((s) => ({ name: s.name, selector: s.selector, painted: s.painted, pixels: s.pixels })),
    page,
  }, null, 2) + "\n");

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
