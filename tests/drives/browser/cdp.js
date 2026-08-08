"use strict";
/* ══ REAL-CHROME DRIVER — Chrome DevTools Protocol, zero dependencies ═════════
 *
 * WHY RAW CDP AND NOT PUPPETEER. This machine's node has a global `WebSocket`,
 * which is the only thing a CDP client actually needs. That buys the rig its
 * most important property: `smoke.sh` is genuinely ONE command with no install
 * step, no `package.json`, no `node_modules`, and therefore no "the rig skipped
 * because a module was missing" failure mode — the mode most likely to turn
 * this rig back into the thing nobody runs. (`puppeteer-core` would have worked
 * too; plain `puppeteer` is forbidden, it downloads its own Chromium and the
 * whole point is to drive the Chrome the captain actually has.)
 *
 * WHAT IT DOES. Attaches to an already-launched Chrome (smoke.sh owns that
 * process so teardown is guaranteed from the shell layer), opens a tab on
 * about:blank, turns on Runtime/Log/Page BEFORE navigating so no early page
 * error is missed, navigates to the board, then POLLS THE REAL DOM until real
 * `.card` nodes exist with a real non-zero bounding box. It never sleeps and
 * hopes: every wait is on an observed condition with a deadline.
 *
 * WHAT IT CANNOT SEE — say it plainly. It proves the board PAINTS: nodes exist,
 * are laid out, and are not display:none / zero-size / transparent. It does not
 * prove the board is CORRECT, legible, or well-arranged. That is what the
 * screenshot is for, and a human still has to open it and look.
 *
 * Usage (smoke.sh's business, not yours):
 *   node cdp.js --devtools-port N --url URL --out DIR [--expect N] [--timeout MS]
 *              [--legend-check FILE] [--console-check FILE]
 *
 * --legend-check (S168) is an OPTIONAL act, and the default path is untouched
 * without it. It MEASURES the board's bottom legend swatches — the little 12px
 * colour chips beside "Awaiting you", "Child bug mission", "Ticket green". They
 * are sized by board.css and coloured by an inline `background:var(--lcars-…)`,
 * so a swatch whose token never resolves keeps a perfect 12×12 box and paints
 * NOTHING: transparent, invisible, and utterly undetectable by any assertion
 * about markup or CSS rules. Measured 2026-08-02 in Chrome: `--lcars-pink` was
 * defined nowhere, and the "Child bug mission" chip was blank on the real board
 * while its two neighbours showed. So this reads the RESOLVED background colour
 * off the live element and composites it against what is actually behind it.
 *
 * --console-check (S164) is the OPTIONAL second act, and the default path is
 * untouched without it. It clicks the board's File button, waits for the File
 * console's base-freshness pre-flight to arrive, and then MEASURES it in the
 * real cascade: the laid-out box, the resolved colour, the composited contrast
 * against whatever is actually behind it. A node DOM harness cannot do any of
 * that — it is a stub of a browser, every one of them calls render() itself,
 * and S162 shipped an amber warning that rendered as muted metadata with a test
 * asserting the CSS rule existed sitting green beside it. Reading a rule is not
 * reading the screen.
 *
 * EXIT CODES — and the reason there are four of them. Exit 1 is an ACCUSATION
 * against the product ("the board did not paint"), so nothing that is actually
 * the harness's own problem may ever leave through it. A rig that exists to stop
 * harness trouble being blamed on the app must not do it itself.
 *   0  the board painted, with its full stylesheet
 *   1  the board did NOT paint — a real product failure
 *   3  it painted, but was served INCOMPLETE (a required same-origin stylesheet
 *      did not load / the shared --lcars-* tokens are absent). What you are
 *      looking at is not the real app.
 *  77  INFRASTRUCTURE — Chrome/devtools never became drivable, the deadline
 *      expired before the page could be probed even once, etc. Never the board's
 *      fault, never reported as one.
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

/* ══════════════════════════════════════════════════════════════════════════
   S169 (FL-016) — READING THE COMPOSITED COLOUR OFF THE SCREEN.

   The defect this exists for: the INTENT panel's readability scrim was on the
   same element as `overflow:auto`, so it was one viewport-height rectangle
   that SCROLLED WITH THE CONTENT and slid off. Everything past the first
   screen sat bare on the deck's 22px grid, and the captain read his own
   captured requirements through it.

   NOTHING ALREADY IN THIS REPO CAN SEE THAT. Every harness under `web/tests/`
   is a node DOM with no CSS and no layout, so the rule is "present" wherever
   it lands (the documented `css-rule-tests-green-never-reaches-screen` class).
   Even this rig's computed-style reads — the S168 legend swatches — would say
   the scrim resolves to a perfectly good colour, because it DOES; it is simply
   somewhere else. The only honest question is what colour is actually PAINTED
   behind a word at the bottom of a long document, and the only way to answer
   it is to look at pixels.

   So: `Page.captureScreenshot` with a `clip`, and a small PNG reader. No
   dependency is added — `zlib` is node's own, and a Chrome screenshot is
   8-bit, non-interlaced RGB/RGBA, which is the whole of what this handles. It
   FAILS LOUD on anything else rather than guessing, because a sampler that
   quietly returns black is exactly the reassuring-output-proving-nothing shape
   this rig has been burned by twice.
   ══════════════════════════════════════════════════════════════════════════ */
function pngPixels(buf) {
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) {
    throw new InfraError("screenshot is not a PNG");
  }
  let off = 8, w = 0, h = 0, depth = 0, ctype = -1, interlace = 0;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.slice(off + 8, off + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0); h = data.readUInt32BE(4);
      depth = data[8]; ctype = data[9]; interlace = data[12];
    } else if (type === "IDAT") {
      idat.push(data);
    } else if (type === "IEND") {
      break;
    }
    off += 12 + len;
  }
  if (depth !== 8 || interlace !== 0 || (ctype !== 2 && ctype !== 6)) {
    throw new InfraError("unsupported PNG (depth " + depth + ", colour type " +
      ctype + ", interlace " + interlace + ") — the sampler reads 8-bit "
      + "non-interlaced RGB/RGBA only and will not guess");
  }
  const bpp = ctype === 6 ? 4 : 3;
  const stride = w * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y++) {
    const ft = raw[y * (stride + 1)];
    const line = raw.slice(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const cur = out.slice(y * stride, (y + 1) * stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;                 // left
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;       // up
      const c = (x >= bpp && y > 0) ? out[(y - 1) * stride + x - bpp] : 0;
      let v = line[x];
      if (ft === 1) v += a;
      else if (ft === 2) v += b;
      else if (ft === 3) v += (a + b) >> 1;
      else if (ft === 4) {
        const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b),
              pc = Math.abs(p - c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      } else if (ft !== 0) {
        throw new InfraError("unknown PNG row filter " + ft);
      }
      cur[x] = v & 0xff;
    }
  }
  return { w: w, h: h, bpp: bpp, px: out };
}

/* THE BACKGROUND OF A PATCH THAT HAS TEXT IN IT.
 *
 * A rectangle over a line of prose is mostly backing and partly glyph, and the
 * glyphs are the BRIGHT part on this deck. Averaging would let a bold heading
 * drag the answer around; taking the darkest quartile answers the question
 * actually being asked — "what is the paper under these words" — and is stable
 * whether the patch caught one word or five. */
function darkQuartile(png) {
  const n = png.w * png.h;
  if (!n) throw new InfraError("sampled an empty patch");
  const lum = [];
  for (let i = 0; i < n; i++) {
    const o = i * png.bpp;
    lum.push([png.px[o] * 0.299 + png.px[o + 1] * 0.587 + png.px[o + 2] * 0.114,
              png.px[o], png.px[o + 1], png.px[o + 2]]);
  }
  lum.sort((a, b) => a[0] - b[0]);
  const take = Math.max(1, Math.round(n / 4));
  let r = 0, g = 0, b = 0;
  for (let i = 0; i < take; i++) { r += lum[i][1]; g += lum[i][2]; b += lum[i][3]; }
  return { r: Math.round(r / take), g: Math.round(g / take),
           b: Math.round(b / take), samples: take, of: n };
}

function rgbDistance(a, b) {
  return Math.round(Math.sqrt((a.r - b.r) ** 2 + (a.g - b.g) ** 2 +
                              (a.b - b.b) ** 2));
}

function arg(name, dflt) {
  const i = process.argv.indexOf("--" + name);
  return i === -1 ? dflt : process.argv[i + 1];
}

const DEVTOOLS_PORT = arg("devtools-port");
const URL_ = arg("url");
const OUT = arg("out");
const EXPECT = parseInt(arg("expect", "1"), 10);
const TIMEOUT = parseInt(arg("timeout", "30000"), 10);
const CONSOLE_CHECK_FILE = arg("console-check", "");
const LEGEND_CHECK_FILE = arg("legend-check", "");
const GHLINK_CHECK_FILE = arg("ghlink-check", "");
const HOLODECK_CHECK_FILE = arg("holodeck-check", "");
const HANDOFF_CHECK_FILE = arg("handoff-check", "");

if (!DEVTOOLS_PORT || !URL_ || !OUT) {
  // 77, not 2: a mis-invoked driver is the harness's problem, and smoke.sh must
  // never be able to translate it into "the board did not paint".
  console.error("cdp.js: --devtools-port, --url and --out are required");
  process.exit(77);
}

const deadline = Date.now() + TIMEOUT;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const EXIT_PAINTED = 0, EXIT_NOT_PAINTED = 1, EXIT_DEGRADED = 3, EXIT_INFRA = 77;
/* S126 fix round 1b — THE HOLODECK CHECK GETS ITS OWN EXIT CODE. It used to
 * leave by EXIT_NOT_PAINTED, so smoke.sh fell through to its default and printed
 * "BLANK / WRONG — the board did not paint" two lines under its own report that
 * real Chrome had painted 2 cards and 9 columns. This repo once burned three
 * hours on a board that "looked blank"; a rig that tells that exact lie on
 * purpose is worse than no rig. Only ever produced when --holodeck-check is
 * given, so no existing caller can see it. */
const EXIT_HOLODECK = 4;

/* S169 — and the HAND-OFF check gets its own, for the same reason: this one
 * fails on a board that painted and a deck that measured up, so borrowing
 * either of their codes would make smoke.sh print the wrong accusation. Only
 * ever produced when --handoff-check is given. */
const EXIT_HANDOFF = 5;

/* An infrastructure failure is a DIFFERENT KIND of thing from a board failure,
 * so it is a different kind of error and leaves by a different exit code. */
class InfraError extends Error {}

/* Failures the RIG ITSELF provoked, counted as it provokes them (fix round 3).
 *
 * Two steps of the journey below deliberately drive the product into refusing:
 * the duplicate-name start (a 409 the daemon is RIGHT to return) and N4's
 * first turn dying before it opened a session (a 502). Both surface in Chrome
 * as network errors, and neither was on the benign list — so every run, product
 * and all seven controls, ended with "⚠ 1 UNEXPECTED PAGE ERROR(S) ON A GREEN
 * RUN". That warning exists to stop anyone shrugging at console errors, and a
 * warning that fires on a healthy product is a warning people learn to ignore.
 *
 * It is a BUDGET, not a pattern exemption: each is forgiven only if the rig
 * actually took that step, and only as many times as it took it. A second 409,
 * or one on a run that never drove the collision, is still unexpected. */
const RIG_PROVOKED = { duplicateStart: 0, deadFirstTurn: 0 };

/* The two page errors a healthy run always produces. Documented in the README,
 * deliberate, and NOT defects — but everything outside this set is surfaced,
 * including on a green run (an unexpected console error passing silently is the
 * false comfort this rig is built against). */
function isBenignPageError(e) {
  if (/\/favicon\.ico/.test(e)) return true;            // the daemon serves none
  if (/\/api\/mission\b/.test(e) && /\b400\b/.test(e)) return true;  // probeWrites()
  if (RIG_PROVOKED.duplicateStart > 0 &&
      /\/api\/holodeck\/start\b/.test(e) && /\b409\b/.test(e)) {
    RIG_PROVOKED.duplicateStart--;                      // the rig's own collision
    return true;
  }
  if (RIG_PROVOKED.deadFirstTurn > 0 &&
      /\/api\/holodeck\/[^/\s>]+\/say\b/.test(e) && /\b502\b/.test(e)) {
    RIG_PROVOKED.deadFirstTurn--;                       // the rig's own dead turn
    return true;
  }
  return false;
}

/* ── a minimal CDP client over the global WebSocket ───────────────────────── */
class CDP {
  constructor(ws) {
    this.ws = ws;
    this.next = 1;
    this.pending = new Map();
    this.pageErrors = [];
    ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.method + ": " + JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      if (msg.method === "Runtime.exceptionThrown") {
        const d = (msg.params && msg.params.exceptionDetails) || {};
        this.pageErrors.push(d.text + " " +
          ((d.exception && d.exception.description) || "").split("\n")[0]);
      } else if (msg.method === "Log.entryAdded") {
        // The URL matters as much as the text: an unattributed "404" in every
        // run's result.json is noise, and noise is what a real error hides in.
        const e = (msg.params && msg.params.entry) || {};
        if (e.level === "error") {
          this.pageErrors.push("[" + e.source + "] " + e.text +
            (e.url ? "  <" + e.url + ">" : ""));
        }
      }
    });
  }
  send(method, params, sessionId) {
    const id = this.next++;
    const payload = { id, method, params: params || {} };
    if (sessionId) payload.sessionId = sessionId;
    this.ws.send(JSON.stringify(payload));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject: (e) => reject(new Error(method + " → " + e.message)) });
    });
  }
}

function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener("open", () => resolve(ws), { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket refused: " + url)), { once: true });
  });
}

/* The probe. Runs INSIDE the page, in real Chrome, against the real DOM. */
const PROBE = `(function () {
  var cards = Array.prototype.slice.call(document.querySelectorAll(".card"));
  function painted(el) {
    var r = el.getBoundingClientRect();
    var s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== "none" &&
           s.visibility !== "hidden" && parseFloat(s.opacity || "1") > 0.01;
  }
  var visible = cards.filter(painted);
  var status = document.getElementById("status");
  // Is the app being served WHOLE? Measured, never asserted from a log line:
  // for every SAME-ORIGIN <link rel=stylesheet>, did the browser actually build
  // a sheet from it — and did the shared ADR-007 --lcars-* tokens land on :root.
  // board.css uses var(--lcars-black,#030608)-style fallbacks throughout, which
  // is exactly why a missing token sheet still PAINTS and still looks like a
  // pass. (Cross-origin sheets — the web font — are excluded: their cssRules are
  // unreadable by design, and the rig is offline-tolerant on purpose.)
  var sheets = Array.prototype.slice.call(
      document.querySelectorAll('link[rel="stylesheet"]'))
    .filter(function (l) { return l.href.indexOf(location.origin) === 0; })
    .map(function (l) {
      var loaded = false;
      try { loaded = !!(l.sheet && l.sheet.cssRules && l.sheet.cssRules.length); }
      catch (e) { loaded = !!l.sheet; }
      return { href: l.getAttribute("href"), loaded: loaded };
    });
  var tokens = getComputedStyle(document.documentElement);
  return {
    stylesheets: sheets,
    tokenProbe: (tokens.getPropertyValue("--lcars-amber") || "").trim(),
    cards: cards.length,
    visibleCards: visible.length,
    columns: document.querySelectorAll(".col").length,
    status: (status && status.textContent) || "",
    cardText: visible.slice(0, 12).map(function (c) {
      return (c.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 90);
    }),
    bodyText: (document.body.innerText || "").replace(/\\s+/g, " ").trim().slice(0, 400)
  };
})()`;

/* ── S168: the bottom legend's colour swatches, MEASURED ────────────────────
 *
 * Runs inside the page. The defect class here is narrower and nastier than a
 * blank board: `.legend i` is given `width:12px;height:12px` by board.css and
 * its colour by an INLINE `background:var(--lcars-x)` in index.html. When the
 * token behind that var does not exist the declaration is invalid at computed-
 * value time, the background falls back to `transparent`, and the element keeps
 * a flawless 12×12 laid-out box while painting nothing at all.
 *
 * So no assertion about the element, the attribute or the stylesheet can see
 * this. Only the RESOLVED background colour can — read off the live node, with
 * its alpha, composited over the first genuinely opaque surface behind it. A
 * chip painted in the page's own background colour is just as blank to a reader
 * as one painted in nothing, which is why the contrast against that backdrop is
 * measured rather than the alpha alone. */
const LEGEND_PROBE = `(function () {
  function rgb(s) {
    var m = String(s || "").match(/rgba?\\(([^)]+)\\)/);
    if (!m) return null;
    var p = m[1].split(",").map(function (x) { return parseFloat(x); });
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  }
  function lum(c) {
    function ch(v) { v /= 255; return v <= 0.03928 ? v / 12.92
                                : Math.pow((v + 0.055) / 1.055, 2.4); }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }
  function over(fg, bg, alpha) {
    return { r: fg.r * alpha + bg.r * (1 - alpha),
             g: fg.g * alpha + bg.g * (1 - alpha),
             b: fg.b * alpha + bg.b * (1 - alpha), a: 1 };
  }
  function backdrop(node) {   // the first really-opaque surface BEHIND the chip
    for (var n = node; n; n = n.parentElement) {
      var c = rgb(getComputedStyle(n).backgroundColor);
      if (c && c.a >= 0.999) return c;
    }
    var b = rgb(getComputedStyle(document.body).backgroundColor);
    return (b && b.a >= 0.999) ? b : { r: 0, g: 0, b: 0, a: 1 };
  }
  function vis(el) {
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== "none" &&
           s.visibility !== "hidden" && parseFloat(s.opacity || "1") > 0.01;
  }
  var legend = document.querySelector(".legend");
  var out = { present: !!legend, swatches: [] };
  if (!legend) return out;
  var lr = legend.getBoundingClientRect();
  out.legendBox = { x: lr.left + window.scrollX, y: lr.top + window.scrollY,
                    w: lr.width, h: lr.height };
  out.legendVisible = vis(legend);
  out.tokens = {};
  var ds = getComputedStyle(document.documentElement);
  ["--lcars-red", "--lcars-pink", "--lcars-teal"].forEach(function (t) {
    out.tokens[t] = (ds.getPropertyValue(t) || "").trim();
  });
  Array.prototype.slice.call(legend.querySelectorAll("i")).forEach(function (i) {
    var s = getComputedStyle(i), r = i.getBoundingClientRect();
    var own = rgb(s.backgroundColor) || { r: 0, g: 0, b: 0, a: 0 };
    var bg = backdrop(i.parentElement || legend);
    var op = parseFloat(s.opacity || "1");
    var seen = over(own, bg, own.a * op);
    var l1 = lum(seen), l2 = lum(bg);
    out.swatches.push({
      label: ((i.parentElement || i).textContent || "").replace(/\\s+/g, " ").trim(),
      declared: i.getAttribute("style") || "",
      visible: vis(i),
      box: { w: r.width, h: r.height, top: r.top, left: r.left },
      background: s.backgroundColor,
      backgroundImage: s.backgroundImage,
      rgb: own, opacity: s.opacity, backdrop: bg, composited: seen,
      contrast: (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05)
    });
  });
  return out;
})()`;

/* The verdicts. Every one is about a MEASURED value; not one of them asks
 * whether a rule, an attribute or a class exists — that is precisely the kind
 * of assertion that sat green beside this bug. Returns failures (empty = pass). */
function judgeLegend(p, want) {
  const bad = [];
  const need = want.swatches || [];
  const minContrast = want.minContrast || 1.25;
  if (!p.present) {
    bad.push("no .legend element in the real DOM");
    return bad;
  }
  if (!p.legendVisible) bad.push("the legend has no laid-out box: " + JSON.stringify(p.legendBox));
  // Named hues, decided on the colour the browser actually resolved. LCARS's
  // pink (#ff66aa), red (#ff3344) and teal (#00ccaa) are separable by ordering
  // alone, so a swatch that paints but paints the WRONG colour is caught too.
  const hues = {
    pink: (c) => c.r > 180 && c.b > 120 && c.b > c.g && c.r > c.b,
    red:  (c) => c.r > 150 && c.r > c.g && c.r > c.b && c.b < 120,
    teal: (c) => c.g > c.r && c.b > c.r,
  };
  need.forEach((w) => {
    const found = (p.swatches || []).filter(
      (s) => s.label.indexOf(w.label) !== -1);
    if (!found.length) {
      bad.push("no legend swatch labelled " + JSON.stringify(w.label) +
               " — labels seen: " + JSON.stringify((p.swatches || []).map((s) => s.label)));
      return;
    }
    const s = found[0];
    const who = JSON.stringify(w.label);
    if (!s.visible || !(s.box.w > 0 && s.box.h > 0)) {
      bad.push("the " + who + " swatch has no real bounding box: " + JSON.stringify(s.box));
      return;
    }
    // THE ONE THAT CATCHES IT. An unresolved var() leaves the box perfect and
    // the paint transparent, so the alpha of the resolved background is the
    // whole ballgame.
    if (!(s.rgb.a >= 0.99)) {
      bad.push("the " + who + " swatch paints NOTHING: background resolved to " +
               s.background + " (alpha " + s.rgb.a + ") on a " +
               Math.round(s.box.w) + "×" + Math.round(s.box.h) + "px box. Its " +
               "declaration is " + JSON.stringify(s.declared) + " — an undefined " +
               "custom property makes that invalid at computed-value time.");
      return;
    }
    // Opaque, but is it DISTINGUISHABLE from what is behind it? A chip painted
    // in the board's own background is blank to a reader all the same.
    if (!(s.contrast >= minContrast)) {
      bad.push("the " + who + " swatch is indistinguishable from the surface " +
               "behind it: " + s.background + " on " + JSON.stringify(s.backdrop) +
               " = " + s.contrast.toFixed(2) + ":1 (floor " + minContrast + ":1)");
      return;
    }
    if (w.hue && hues[w.hue] && !hues[w.hue](s.rgb)) {
      bad.push("the " + who + " swatch resolved to the wrong colour for a " +
               w.hue + " chip: " + s.background);
    }
  });
  return bad;
}

/* ── S164: the File console's base-freshness pre-flight, MEASURED ───────────
 *
 * Runs inside the page. Everything here is read off the LIVE element — the
 * laid-out rectangle, the resolved colour, the background actually painted
 * behind it — because the whole class of bug this exists for (S162) is a rule
 * that is present in the stylesheet and never reaches the screen.
 *
 * The contrast number is composited by hand rather than trusted from `color`
 * alone: the line is dimmed with `opacity`, so the colour a reader sees is the
 * blend of it with whatever opaque surface is behind it, and "muted" that has
 * quietly become "invisible" is the same defect wearing the opposite mask. */
const CONSOLE_PROBE = `(function () {
  function rgb(s) {
    var m = String(s || "").match(/rgba?\\(([^)]+)\\)/);
    if (!m) return null;
    var p = m[1].split(",").map(function (x) { return parseFloat(x); });
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 ? p[3] : 1 };
  }
  function lum(c) {
    function ch(v) { v /= 255; return v <= 0.03928 ? v / 12.92
                                : Math.pow((v + 0.055) / 1.055, 2.4); }
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }
  function over(fg, bg, alpha) {   // fg composited onto bg at that alpha
    return { r: fg.r * alpha + bg.r * (1 - alpha),
             g: fg.g * alpha + bg.g * (1 - alpha),
             b: fg.b * alpha + bg.b * (1 - alpha), a: 1 };
  }
  function backdrop(node) {        // the first really-opaque surface behind it
    for (var n = node; n; n = n.parentElement) {
      var c = rgb(getComputedStyle(n).backgroundColor);
      if (c && c.a >= 0.999) return c;
    }
    var b = rgb(getComputedStyle(document.body).backgroundColor);
    return (b && b.a >= 0.999) ? b : { r: 0, g: 0, b: 0, a: 1 };
  }
  function vis(el) {
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== "none" &&
           s.visibility !== "hidden" && parseFloat(s.opacity || "1") > 0.01;
  }
  var amber = (getComputedStyle(document.documentElement)
                 .getPropertyValue("--lcars-amber") || "").trim();
  var wrap = document.querySelector(".file-basefresh");
  var out = { amber: amber, consoleOpen: !!document.querySelector(".modal"),
              present: !!wrap };
  if (!wrap) return out;
  var ws = getComputedStyle(wrap), wr = wrap.getBoundingClientRect();
  out.wrapClass = wrap.className;
  out.wrapHidden = !!wrap.hidden;
  out.wrapVisible = vis(wrap);
  out.wrapBox = { w: wr.width, h: wr.height, top: wr.top, left: wr.left };
  out.wrapBackground = ws.backgroundColor;
  out.wrapBoxShadow = ws.boxShadow;
  out.hasHead = !!wrap.querySelector(".bf-head");
  out.hasFix = !!wrap.querySelector(".bf-fix");
  out.text = (wrap.innerText || "").replace(/\\s+/g, " ").trim();
  var q = wrap.querySelector(".bf-quiet");
  out.quietPresent = !!q;
  if (q) {
    var qs = getComputedStyle(q), qr = q.getBoundingClientRect();
    var fg = rgb(qs.color) || { r: 255, g: 255, b: 255, a: 1 };
    var op = parseFloat(qs.opacity || "1");
    var bg = backdrop(q);
    var seen = over(fg, bg, (fg.a === undefined ? 1 : fg.a) * op);
    var l1 = lum(seen), l2 = lum(bg);
    out.quiet = {
      visible: vis(q),
      box: { w: qr.width, h: qr.height, top: qr.top, left: qr.left },
      color: qs.color, opacity: qs.opacity, fontSize: qs.fontSize,
      rgb: fg, composited: seen, backdrop: bg,
      contrast: (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05),
      text: (q.innerText || "").replace(/\\s+/g, " ").trim(),
    };
  }
  var idea = document.querySelector(".modal textarea");
  if (idea) out.ideaTop = idea.getBoundingClientRect().top;
  out.buttonsDisabled = Array.prototype.slice
    .call(document.querySelectorAll(".modal button"))
    .filter(function (b) { return b.disabled; })
    .map(function (b) { return (b.textContent || "").trim(); });
  return out;
})()`;

/* ── S168: the board's "view on GitHub" LINKS, as the browser resolved them ──
 *
 * The captain's repos live on a GitHub ENTERPRISE host. Both of the board's
 * issue links concatenated a literal "https://github.com/", so every one of
 * them opened a github.com repository that does not exist and had to be
 * hand-edited after the click.
 *
 * What makes this worth a real browser rather than a node harness: the fix is
 * only real if the DAEMON actually delivers `meta.ghHost` to the live page.
 * Every harness under web/tests/ calls the builders itself, so all of them stay
 * green against a daemon that sends nothing — which is precisely how a blank
 * board survived 1,162 green tests for three fix rounds (S163).
 *
 * So this reads the anchor's `href` PROPERTY off the live DOM. That is the
 * resolved, absolute URL the browser would actually navigate to — not the
 * attribute, not a string the page was built from. Two links are measured: the
 * ⊗ BUG badge on a logged-bug CARD, and the ↗ View on GitHub button in a
 * mission's DETAIL overlay. */
const GHLINK_PROBE = `(function () {
  function vis(el) {
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.display !== "none" &&
           s.visibility !== "hidden" && parseFloat(s.opacity || "1") > 0.01;
  }
  function read(a, where) {
    var r = a.getBoundingClientRect();
    return {
      where: where,
      text: (a.innerText || a.textContent || "").replace(/\\s+/g, " ").trim(),
      href: a.href,                 // RESOLVED — what a click would open
      hrefAttr: a.getAttribute("href"),
      host: (function () { try { return new URL(a.href).host; }
                           catch (e) { return ""; } })(),
      protocol: (function () { try { return new URL(a.href).protocol; }
                               catch (e) { return ""; } })(),
      visible: vis(a),
      box: { w: r.width, h: r.height },
      target: a.getAttribute("target") || "",
      rel: a.getAttribute("rel") || "",
    };
  }
  var out = { links: [], detailOpen: !!document.querySelector(".det-actions"),
              cards: document.querySelectorAll(".card").length,
              // Diagnostic, not a verdict: a badge that rendered as a <span>
              // instead of an <a> is a link that is not there at all, and the
              // failure message should say which of the two happened.
              badgeTags: Array.prototype.slice
                .call(document.querySelectorAll(".logbug-badge"))
                .map(function (n) { return n.tagName; }) };
  Array.prototype.slice.call(document.querySelectorAll("a.logbug-badge"))
    .forEach(function (a) { out.links.push(read(a, "card-logbug-badge")); });
  Array.prototype.slice.call(document.querySelectorAll(".det-actions a"))
    .forEach(function (a) {
      if (/github/i.test(a.textContent || "")) out.links.push(read(a, "detail-header"));
    });
  return out;
})()`;

/* The verdicts. Everything asserted is something MEASURED off the live node —
 * the resolved href and the host the browser parsed out of it. */
function judgeGhLinks(p, want) {
  const bad = [];
  const wantHost = want.host || "github.com";
  const places = want.places || ["card-logbug-badge", "detail-header"];
  if (!p.links.length) {
    bad.push("NO GitHub link anywhere in the live DOM — the board rendered " +
             p.cards + " card(s) and a detail overlay was " +
             (p.detailOpen ? "open" : "NOT open"));
    return bad;
  }
  places.forEach((place) => {
    const found = p.links.filter((l) => l.where === place);
    if (!found.length) {
      bad.push("no GitHub link at " + JSON.stringify(place) + " — measured: " +
               JSON.stringify(p.links.map((l) => l.where)) +
               "; .logbug-badge nodes rendered as " +
               JSON.stringify(p.badgeTags || []));
      return;
    }
    found.forEach((l) => {
      if (l.host !== wantHost) {
        bad.push(place + ": the link the captain would CLICK resolves to host " +
                 JSON.stringify(l.host) + ", not " + JSON.stringify(wantHost) +
                 " — " + JSON.stringify(l.href));
      }
      if (l.protocol !== "https:") {
        bad.push(place + ": the link is not https (" + l.protocol + "): " +
                 JSON.stringify(l.href));
      }
      if (want.path && l.href.indexOf(want.path) === -1) {
        bad.push(place + ": the link does not carry " + JSON.stringify(want.path) +
                 " — " + JSON.stringify(l.href));
      }
      if (!l.visible || !(l.box.w > 0 && l.box.h > 0)) {
        bad.push(place + ": the link has no laid-out box (" +
                 JSON.stringify(l.box) + ") — a link nobody can click is not " +
                 "a link the host is fixed on");
      }
    });
  });
  return bad;
}

/* The verdicts. Every one of them is about something MEASURED above; none of
 * them asks whether a CSS rule exists. Returns a list of failures (empty = pass). */
function judgeConsole(p, want) {
  const bad = [];
  const need = want.reasonSubstring || "";
  const minContrast = want.minContrast || 4.5;
  if (!p.consoleOpen) bad.push("the File console never opened");
  if (!p.present) {
    bad.push("no .file-basefresh element in the real DOM — the captain was " +
             "told NOTHING about a base that is behind");
    return bad;
  }
  if (p.wrapHidden) bad.push("the pre-flight block is still hidden");
  if (!p.wrapVisible) bad.push("the pre-flight block has no laid-out box " +
    "(display/size/opacity): " + JSON.stringify(p.wrapBox));
  if (!p.quietPresent) {
    bad.push("no .bf-quiet line inside the pre-flight block — text was: " +
             JSON.stringify(p.text));
    return bad;
  }
  const q = p.quiet;
  if (!q.visible || !(q.box.w > 0 && q.box.h > 0)) {
    bad.push("the quiet line has no real bounding box: " + JSON.stringify(q.box));
  }
  if (need && q.text.indexOf(need) === -1) {
    bad.push("the quiet line does not carry the guard's own words " +
             JSON.stringify(need) + " — it said: " + JSON.stringify(q.text));
  }
  // NOT A WARNING. The amber panel, the ⚠ badge and the Fix: command are the
  // loud treatment, and this case is reassurance — the captain ruled it must
  // not read as an alarm.
  if (p.hasHead) bad.push("a ⚠ badge (.bf-head) is rendered — that is the alarm treatment");
  if (p.hasFix) bad.push("a Fix: row (.bf-fix) is rendered — that is a call to action");
  if (/⚠/.test(p.text)) bad.push("the block's text carries a ⚠: " + JSON.stringify(p.text));
  const bgm = String(p.wrapBackground || "").match(/rgba?\(([^)]+)\)/);
  const bgA = bgm ? bgm[1].split(",").map(function (x) { return parseFloat(x); }) : null;
  const bgAlpha = !bgm ? 0 : (bgA.length > 3 ? bgA[3] : 1);
  if (bgAlpha >= 0.01) {
    bad.push("the block is painted with a panel background (" + p.wrapBackground +
             ") — the amber warning panel reached the quiet line");
  }
  if (p.wrapBoxShadow && p.wrapBoxShadow !== "none") {
    bad.push("the block has an inset ring (" + p.wrapBoxShadow +
             ") — the amber warning frame reached the quiet line");
  }
  // The colour, resolved — never the rule. LCARS's warning colour is amber
  // (r ≫ b); the muted reading colour is a cool blue-grey (b > r). One
  // comparison, on the value the browser actually resolved.
  if (!(q.rgb.b > q.rgb.r)) {
    bad.push("the quiet line resolved to a WARM/warning colour (" + q.color +
             "); the muted metadata treatment is a cool blue-grey. --lcars-amber is " +
             p.amber);
  }
  if (!(parseFloat(q.opacity) < 1)) {
    bad.push("the quiet line is at full opacity (" + q.opacity +
             ") — it must read as dimmed metadata, not as body copy");
  }
  // Muted is not invisible. S163's status line was #50688a on #030608 — 3.6:1
  // at 12px — and that was judged unreadable, so this one is held above 4.5.
  if (!(q.contrast >= minContrast)) {
    bad.push("the quiet line is muted into unreadability: contrast " +
             q.contrast.toFixed(2) + ":1 against " + JSON.stringify(q.backdrop) +
             " (floor " + minContrast + ":1)");
  }
  if (p.buttonsDisabled && p.buttonsDisabled.length) {
    bad.push("filing controls were disabled by the line: " +
             JSON.stringify(p.buttonsDisabled));
  }
  return bad;
}


/* ── S125: THE HOLODECK, MEASURED IN A REAL BROWSER ─────────────────────────
 *
 * The deck is the exact shape of defect this rig exists for. It REPLACES the
 * board inside the same frame, and it does that in CSS off one class on <body>
 * (`body.on-deck`). A node harness can assert that class all day; only a
 * browser can answer the question that matters — did the board actually go
 * away, and did three panes actually arrive with real width on the screen.
 *
 * So every claim below is read off LAID-OUT BOXES, never off markup:
 *   • the board's columns and legend measured GONE (zero box / display:none);
 *   • the three deck panes measured PRESENT with non-zero width, in the mock's
 *     left-to-right order, at roughly the mock's chat:preview ratio;
 *   • the preview iframe's real box, its src (the jailed route) and its
 *     sandbox token list — with allow-same-origin measured ABSENT, because
 *     that one flag is the difference between a sandbox and a decoration;
 *   • the deck's own accent token resolving to a real colour (the S168 lesson:
 *     an unresolved var paints NOTHING while keeping a perfect box);
 *   • and, on the way back, the board measured PRESENT again.
 */
const HOLODECK_PROBE = `(function () {
  function box(el) {
    if (!el) return null;
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return { w: r.width, h: r.height, display: s.display,
             visible: r.width > 0 && r.height > 0 && s.display !== "none" &&
                      s.visibility !== "hidden" &&
                      parseFloat(s.opacity || "1") > 0.01 };
  }
  function anyVisible(sel) {
    var ns = Array.prototype.slice.call(document.querySelectorAll(sel));
    return ns.some(function (n) { var b = box(n); return b && b.visible; });
  }
  var deck = document.getElementById("deckHost");
  var view = document.querySelector(".deckview");
  /* ── S128: PANES vs FURNITURE ──────────────────────────────────────────────
     The deckview's children are NOT all panes. S127 added two nodes that are
     deliberately not pane-shaped and were never taught to this check:
       • \`.deck-split\` — the chat/preview drag handle, a 7px grid gutter;
       • \`.holo-scrim\` — the program-drawer's click-away, rendered at every
         width and display:none above the drawer breakpoint.
     For a whole session this check read those two as PANES and reported the
     product broken ("pane deck-split is 7px wide — it did not lay out") on a
     deck that was laying out perfectly. The cure is NOT to widen the pane list
     — a check that accepts any node at any size is decoration. The furniture is
     split out here and asserted BELOW, each as itself, with the shape that is
     correct FOR IT: a thin handle that really did lay out, and a scrim that is
     really inert while the drawer is shut. Everything else in the deck is still
     a pane, still measured, still held to a real width. */
  var kids = view ? Array.prototype.slice.call(view.children) : [];
  function firstClass(n) { return String(n.className || "").split(/\\s+/)[0]; }
  var FURNITURE = { "deck-split": 1, "holo-scrim": 1 };
  var panes = kids.filter(function (p) { return !FURNITURE[firstClass(p)]; });
  var frame = document.querySelector("#holoPreview");
  var ds = getComputedStyle(document.documentElement);
  var bs = getComputedStyle(document.body);
  return {
    onDeckClass: document.body.classList.contains("on-deck"),
    deckBox: box(deck),
    // THE REPLACEMENT, measured: is any board furniture still on the screen?
    boardColumnsVisible: anyVisible(".col"),
    boardWrapVisible: anyVisible(".board-wrap"),
    legendVisible: anyVisible(".legend"),
    deckviewClass: view ? view.className : null,
    paneClasses: panes.map(firstClass),
    paneWidths: panes.map(function (p) { var b = box(p); return b ? Math.round(b.w) : 0; }),
    panesVisible: panes.map(function (p) { var b = box(p); return !!(b && b.visible); }),
    // EVERY child of the deck, furniture included and in DOM order. This is
    // what makes a node the rig has never heard of impossible to ignore: the
    // pane list above is filtered, so without this a third piece of furniture
    // could appear tomorrow and be silently dropped — which is precisely the
    // staleness that left this check dead for a session.
    deckChildClasses: kids.map(firstClass),
    // THE DRAG HANDLE (S127), measured as a handle: thin, but really laid out,
    // really tall enough to grab, and really between the two panes it splits.
    splitM: (function () {
      var hs = kids.filter(function (p) { return firstClass(p) === "deck-split"; });
      if (!hs.length) return null;
      var h = hs[0], b = box(h), g = box(h.querySelector(".grip"));
      return { count: hs.length, index: kids.indexOf(h),
               w: b ? Math.round(b.w) : 0, h: b ? Math.round(b.h) : 0,
               visible: !!(b && b.visible),
               cursor: getComputedStyle(h).cursor,
               gripVisible: !!(g && g.visible) };
    })(),
    // THE DRAWER'S CLICK-AWAY (S127). Above the drawer breakpoint the program
    // list is a real pane, so the scrim must be GONE — a full-bleed overlay
    // that is merely transparent would swallow every click on the deck.
    scrimM: (function () {
      var ss = kids.filter(function (p) { return firstClass(p) === "holo-scrim"; });
      if (!ss.length) return null;
      var s = ss[0], b = box(s), cs = getComputedStyle(s);
      return { count: ss.length, index: kids.indexOf(s),
               w: b ? Math.round(b.w) : 0, h: b ? Math.round(b.h) : 0,
               visible: !!(b && b.visible), display: cs.display,
               opacity: parseFloat(cs.opacity || "1"),
               pointerEvents: cs.pointerEvents };
    })(),
    drawerOpen: view ? /(^|\\s)drawer-open(\\s|$)/.test(view.className) : false,
    deckviewW: view ? Math.round(view.getBoundingClientRect().width) : 0,
    // The chat's DECLARED share of (chat + preview) — the deck's own one number
    // (board.js HOLO_SPLIT_DEFAULT). Read so the ratio below can be judged
    // against what the product SAYS it does, instead of against a literal the
    // rig froze at some past ruling.
    splitDefault: (typeof HOLO_SPLIT_DEFAULT === "number"
                   ? HOLO_SPLIT_DEFAULT : null),
    splitStored: (function () {
      try { return window.localStorage.getItem("lcars-holo-split"); }
      catch (e) { return null; }
    })(),
    programRows: document.querySelectorAll(".prog").length,
    programRowsVisible: anyVisible(".prog"),
    composerPresent: !!document.querySelector(".composer textarea"),
    composerVisible: anyVisible(".composer textarea"),
    iframeBox: box(frame),
    iframeSrc: frame ? frame.getAttribute("src") : null,
    iframeSandbox: frame ? (frame.getAttribute("sandbox") || "") : null,
    bandLabel: (function () {
      var b = document.getElementById("holodeckBtn");
      return b ? (b.textContent || "").trim() : null;
    })(),
    bandVisible: anyVisible("#holodeckBtn"),
    // the deck's own accent. An unresolved custom property paints nothing at
    // all while every box stays perfect — that is the S168 defect class, and
    // the deck is drawn almost entirely in this one colour.
    holoGrid: (bs.getPropertyValue("--holo-grid") || "").trim(),
    amberToken: (ds.getPropertyValue("--lcars-amber") || "").trim(),
    emptyStateVisible: anyVisible(".holo-empty"),
    /* ── S125 FIX ROUND 1: THE DECK IS THE VIEWPORT ────────────────────────
       Round 0's rig measured pane WIDTHS on a one-turn transcript, so it was
       structurally blind to the defect that mattered most on screen: the deck
       GREW. Measured after one long turn — innerHeight 913, .deckview height
       1897, scrollHeight 1961, overflow-y VISIBLE on the deckview and all
       three panes. Nothing scrolled internally; the page did, and it carried
       the composer and the LIVE PREVIEW off the bottom — which is precisely
       what D2's fixed split exists to prevent ("the preview is the point — it
       must be permanently visible").

       So these are read off REAL BOX GEOMETRY against the REAL viewport, and
       the rig now grows the transcript before reading them. A rule-exists
       assertion passes while the screen is wrong. */
    viewportH: window.innerHeight,
    docScrollH: document.documentElement.scrollHeight,
    deckviewH: view ? Math.round(view.getBoundingClientRect().height) : 0,
    deckviewOverflowY: view ? getComputedStyle(view).overflowY : null,
    transcript: (function () {
      var t = document.querySelector(".transcript");
      if (!t) return null;
      var s = getComputedStyle(t);
      return { overflowY: s.overflowY, clientH: t.clientHeight,
               scrollH: t.scrollHeight, scrollTop: Math.round(t.scrollTop),
               bottom: Math.round(t.getBoundingClientRect().bottom) };
    })(),
    // "still on screen" is a BOTTOM EDGE inside the viewport, not a box.
    composerBottom: (function () {
      var c = document.querySelector(".composer");
      return c ? Math.round(c.getBoundingClientRect().bottom) : null;
    })(),
    previewBottom: (function () {
      var p = document.querySelector(".preview");
      return p ? Math.round(p.getBoundingClientRect().bottom) : null;
    })(),
    turnCount: document.querySelectorAll(".turn").length,
    // D12: the chip is a LINK to basis.md, not an inert span.
    groundChip: (function () {
      var g = document.querySelector(".ground-chip");
      if (!g) return null;
      return { tag: g.tagName.toLowerCase(), href: g.getAttribute("href") };
    })(),
    /* S126 (#7) — N6, ON THE SCREEN. The captain says a line, the turn dies, he
       presses RETRY TURN — and it is the SAME line, not a second one. Both the
       daemon and the deck reuse the pending turn for exactly that reason, and
       until now the only proof either worked was a unit test. This is what he
       actually reads. (No backticks in here: this whole probe is a template
       literal.) */
    youLines: Array.prototype.slice.call(
      document.querySelectorAll(".turn.you .body")).map(function (n) {
        return (n.innerText || "").trim();
      }),
    /* S126 (#8) — a fenced block's INFO STRING, on the screen. A new class with
       a new cascade around it: measured as a REAL BOX, because a CSS rule can
       test green and never reach the screen (S162). */
    fenceInfos: Array.prototype.slice.call(
      document.querySelectorAll(".turn.holo .body .fence-info")).map(function (n) {
        var b = box(n);
        var pre = n.nextElementSibling;
        // the GAP to the block it labels. A caption that renders detached from
        // its slab reads as unrelated metadata — exactly the S162 defect — so
        // the cascade is resolved by MEASURING the two boxes, never by
        // asserting the rule exists.
        var gap = null;
        if (pre && pre.tagName.toLowerCase() === "pre") {
          gap = Math.round(pre.getBoundingClientRect().top
                           - n.getBoundingClientRect().bottom);
        }
        return { text: (n.innerText || "").trim(), visible: !!(b && b.visible),
                 gapToBlock: gap };
      }),
    // the reply, RENDERED: no markdown source, no engine tool trace.
    replyText: (function () {
      var bs = document.querySelectorAll(".turn.holo .body");
      var last = bs.length ? bs[bs.length - 1] : null;
      return last ? (last.innerText || "") : "";
    })(),
    bodyText: (document.body.innerText || "").replace(/\\s+/g, " ").trim().slice(0, 600)
  };
})()`;

/* ── S169: THE SEND-TO-ALIGN BOX, MEASURED WHERE IT IS ACTUALLY READ ────────
   WHY A BROWSER, and it is not a formality. S128's worst defect was invisible
   to every one of the 1,100+ harnesses under web/tests/: the promote dialog's
   body is 1812px against a ~677px window, and its open questions sat 546–780px
   BELOW THE FOLD while ▦ File Mission did not — the session's own stated goal,
   shipped and unreadable. Those harnesses are node DOMs with no CSS and no
   layout; not one of them can see a fold.

   S169 pours two more sections into that same box, so it is the same trap one
   turn later. What is measured here is therefore not "is the text present" (a
   unit test owns that) but: IS THE CAPTAIN ACTUALLY SHOWN IT, and is the button
   he came to press still reachable while it is on screen.

   The textarea is SCROLLED as part of the probe — to the bottom and back — so
   the claim "the whole draft is reachable" is a thing the browser did, not a
   number the rig reasoned about. */
const HANDOFF_PROBE = `(function () {
  function box(el) {
    if (!el) return null;
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return { top: Math.round(r.top), bottom: Math.round(r.bottom),
             left: Math.round(r.left), right: Math.round(r.right),
             w: Math.round(r.width), h: Math.round(r.height),
             visible: r.width > 0 && r.height > 0 && s.display !== "none" &&
                      s.visibility !== "hidden" &&
                      parseFloat(s.opacity || "1") > 0.01 };
  }
  /* CAN A CLICK ACTUALLY LAND ON IT? A node with a perfect box can still be
     off the bottom of the window or under a scrim, and "it is in the DOM" is
     the exact claim that failed in S128. elementFromPoint asks the browser. */
  function hit(el) {
    var b = box(el);
    if (!b || !b.visible) return false;
    /* SEVERAL POINTS, and ANY of them counts. An INLINE element only occupies
       its text runs, so the centre of a two-line wrapped <span> lands in the
       empty tail of the short second line and elementFromPoint answers with
       the block behind it — a false negative on a line that is plainly on the
       screen (measured, first calibration run). The window-bounds test below
       is what actually catches "off screen"; this only asks whether SOMETHING
       of the node is hittable where it sits. */
    var pts = [[(b.left + b.right) / 2, (b.top + b.bottom) / 2],
               [b.left + 6, b.top + 6],
               [b.left + 6, (b.top + b.bottom) / 2],
               [(b.left + b.right) / 2, b.top + 6]];
    for (var i = 0; i < pts.length; i++) {
      var x = Math.round(pts[i][0]), y = Math.round(pts[i][1]);
      if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) continue;
      var at = document.elementFromPoint(x, y);
      while (at) { if (at === el) return true; at = at.parentElement; }
    }
    return false;
  }
  function ctl(re) {
    return Array.prototype.slice.call(
      document.querySelectorAll(".modal-foot [data-ctl], .modal-foot button"))
      .filter(function (n) { return re.test((n.textContent || "").trim()); })[0] || null;
  }
  var ta = document.querySelector("[data-holo=handoff-brief]");
  var field = document.querySelector("[data-holo=handoff-brief-field]");
  var hint = field ? field.querySelector(".hint") : null;
  var body = document.querySelector(".modal-body");
  var go = ctl(/File Mission/i);
  var qcue = document.querySelector("[data-holo=handoff-qcue]");
  var m = { viewportW: window.innerWidth, viewportH: window.innerHeight,
            bodyScrollTop: body ? Math.round(body.scrollTop) : null,
            bodyH: body ? body.clientHeight : null,
            bodyScrollH: body ? body.scrollHeight : null,
            // THE SCROLLING BOX'S OWN VISIBLE BAND. .modal-body CLIPS what
            // overflows it, so "inside a 677px window" is not the same claim
            // as "on screen" — a line 20px past this rectangle has a perfectly
            // good box in the viewport and is behind the footer.
            // (No backticks in here: this whole probe is a template literal.)
            bodyRect: body ? box(body) : null,
            present: !!ta };
  if (ta) {
    var cs = getComputedStyle(ta);
    var lh = parseFloat(cs.lineHeight);
    if (!(lh > 0)) lh = parseFloat(cs.fontSize) * 1.2;
    var value = String(ta.value || "");
    // THE SCROLL, ACTUALLY PERFORMED. Restored afterwards so the screenshot
    // taken next is of the box as the captain first meets it.
    var before = ta.scrollTop;
    ta.scrollTop = ta.scrollHeight;
    var reachedBottom = ta.scrollTop > 0 ||
                        ta.scrollHeight <= ta.clientHeight + 1;
    ta.scrollTop = before;
    m.brief = {
      rowsAttr: ta.rows, lines: value.split("\\n").length, chars: value.length,
      clientH: ta.clientHeight, scrollH: ta.scrollHeight,
      overflowY: cs.overflowY, lineHeight: Math.round(lh),
      linesShown: lh > 0 ? Math.floor(ta.clientHeight / lh) : 0,
      reachedBottom: reachedBottom,
      // S169 FIX ROUND 1 — WHAT IS HIDDEN BEHIND THE BOX'S OWN SCROLLBAR.
      // rows/linesShown count SOURCE lines, and this draft's lines wrap three
      // and four ways at 613px, so both were blind to the tester's finding: a
      // 269px box over 835px of content. This is the laid-out fact.
      // (No backticks in here: this whole probe is a template literal.)
      nestedHiddenPx: Math.max(0, ta.scrollHeight - ta.clientHeight),
      // the inline height the sizing pass set, so a run that FAILS this
      // says whether the pass never ran or ran and was overruled.
      styleH: ta.style.height || "",
      box: box(ta), hit: hit(ta),
      headings: value.split("\\n").filter(function (l) {
        return /^##\\s/.test(l);
      }),
      value: value
    };
  }
  // …and how many lines of it are ACTUALLY IN FRONT OF HIM at rest — the
  // intersection of the box with the scrolling body's own visible band, which
  // is what "on screen" means inside a modal that clips.
  if (ta && body) {
    var bb = box(ta), br = box(body);
    var top = Math.max(bb.top, br.top, 0);
    var bot = Math.min(bb.bottom, br.bottom, window.innerHeight);
    m.brief.visiblePx = Math.max(0, bot - top);
    m.brief.visibleLines = m.brief.lineHeight > 0
      ? Math.floor(m.brief.visiblePx / m.brief.lineHeight) : 0;
  }
  m.hint = hint ? { text: (hint.textContent || "").trim(), box: box(hint),
                    hit: hit(hint) } : null;
  m.fileBtn = go ? { text: (go.textContent || "").trim(), box: box(go),
                     hit: hit(go), disabled: !!go.disabled } : null;
  m.qcue = qcue ? { text: (qcue.textContent || "").trim(), box: box(qcue),
                    hit: hit(qcue) } : null;
  /* S169 FIX ROUND 2 — THE GUIDANCE BOX. Fix round 1 cured the brief textarea's
     nested scroller and MISSED this one, which is the box carrying the whole
     precedence rule. Measured on the capstone: clientHeight 228 against
     scrollHeight 729 — 69% of it hidden, inside a modal body that already
     scrolls, with a scrollbar of its own nobody notices. Same measurement,
     same claim: ONE scroller in this dialog. */
  var guide = document.querySelector("[data-holo=handoff-guidance]");
  if (guide) {
    var gs = getComputedStyle(guide);
    m.guidance = { clientH: guide.clientHeight, scrollH: guide.scrollHeight,
                   nestedHiddenPx: Math.max(0, guide.scrollHeight - guide.clientHeight),
                   overflowY: gs.overflowY, maxHeight: gs.maxHeight,
                   box: box(guide) };
  } else { m.guidance = null; }
  /* S170 — THE DERIVATION BAND. What one bounded read-only pass found when it
     stood in the captain's project and compared it with the mockup — and,
     while it is still running, the sentence telling him he may walk away. It
     is only worth anything if it is ON THE SCREEN where he skims, which is a
     laid-out fact and not a DOM fact. */
  var ckb = document.querySelector("[data-holo=handoff-derive]");
  if (ckb) {
    m.check = { text: (ckb.textContent || "").trim(), cls: ckb.className,
                state: ckb.getAttribute("data-state") || "",
                hidden: !!ckb.hidden, box: box(ckb), hit: hit(ckb),
                flags: Array.prototype.slice.call(
                  ckb.querySelectorAll("[data-holo=handoff-derive-change]"))
                  .map(function (n) { return (n.textContent || "").trim(); }) };
  } else { m.check = null; }
  return m;
})()`;

/* S171 — THE GATE ON THE DECK, measured off laid-out boxes.

   ▶ SEND TO ALIGN is a wait now. The states are the DAEMON's (`data-gate`,
   stamped from the published `derive` block), and what a browser adds — the
   only thing that can — is whether the disabled control is genuinely
   unclickable WHERE IT SITS, whether the loading indicator is really there,
   and whether the escape hatch is reachable rather than merely in the DOM.

   `clickable` is the strong claim: elementFromPoint at the control's own
   centre and corners, walked up to the node. A button behind a banner passes
   every DOM test in this repo and cannot be pressed. */
const GATE_PROBE = `(function () {
  function box(el) {
    if (!el) return null;
    var r = el.getBoundingClientRect();
    return { top: Math.round(r.top), left: Math.round(r.left),
             w: Math.round(r.width), h: Math.round(r.height),
             bottom: Math.round(r.bottom) };
  }
  function hit(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) return false;
    var pts = [[r.left + r.width / 2, r.top + r.height / 2],
               [r.left + 3, r.top + 3], [r.right - 3, r.bottom - 3]];
    for (var i = 0; i < pts.length; i++) {
      var x = pts[i][0], y = pts[i][1];
      if (x < 0 || y < 0 || x > window.innerWidth || y > window.innerHeight) continue;
      var at = document.elementFromPoint(x, y);
      while (at) { if (at === el) return true; at = at.parentElement; }
    }
    return false;
  }
  var bar = document.querySelector(".holo-handoff");
  if (!bar) return { present: false };
  var send = bar.querySelector("[data-holo=handoff-send]");
  /* S172 — THE HATCH IS DELETED (*"we don't need the send without change list
     one"*), and this probe still LOOKS FOR IT. That is the point: the claim
     inverted, so the measurement has to be able to see it come back. */
  var skip = bar.querySelector("[data-holo=handoff-skip]");
  var retry = bar.querySelector("[data-holo=handoff-retry]");
  var spin = bar.querySelector(".holo-bars .bars i");
  var hintEl = bar.querySelector(".hint");
  return {
    present: true,
    gate: bar.getAttribute("data-gate") || "",
    barBox: box(bar),
    hint: hintEl ? (hintEl.textContent || "").trim() : "",
    send: send ? { text: (send.textContent || "").trim(),
                   disabled: !!send.disabled, box: box(send),
                   clickable: hit(send),
                   /* THE FACT A CSS-ONLY "disabled" CANNOT FAKE: what the
                      browser would actually deliver the click to. */
                   topAtCentre: (function () {
                     var r = send.getBoundingClientRect();
                     var at = document.elementFromPoint(r.left + r.width / 2,
                                                        r.top + r.height / 2);
                     return at ? (at.getAttribute("data-holo")
                                  || at.tagName.toLowerCase()) : "";
                   })() } : null,
    spinner: !!spin,
    skip: skip ? { text: (skip.textContent || "").trim(),
                   disabled: !!skip.disabled, box: box(skip),
                   clickable: hit(skip) } : null,
    retry: retry ? { text: (retry.textContent || "").trim(),
                     clickable: hit(retry), box: box(retry),
                     /* S172 — THE FAMILY TEST, and it needs REAL CSS. A node
                        harness lays nothing out and cannot see that two
                        controls on one row are different sizes; the captain
                        saw it in a screenshot. It is read off the COMPUTED
                        style, not off a class name, so a rule that reaches
                        the control by any route is what is measured. */
                     font: getComputedStyle(retry).fontSize } : null,
    sendFont: send ? getComputedStyle(send).fontSize : "",
    dialogOpen: !!document.querySelector("[data-holo=handoff-brief]")
  };
})()`;

/* S171 — THE GATE'S VERDICT. Four states, and the two that matter most are
   the ones a DOM test cannot tell apart: a control that is disabled and one
   that is painted to look disabled, and an escape hatch that exists versus one
   a captain can reach. */
function judgeGate(g, want) {
  const f = [];
  const need = (m, what) => {
    if (!m || !m.present) { f.push("the hand-off bar was not there " + what); }
    return !!(m && m.present);
  };
  if (need(g.none, "before he pressed anything")) {
    if (g.none.gate !== "none") {
      f.push("a program with no change list should offer to GENERATE one; " +
             "the bar read gate=" + g.none.gate);
    }
    if (!/generat/i.test((g.none.send || {}).text || "")) {
      f.push("the control does not offer to generate the change list: " +
             JSON.stringify((g.none.send || {}).text || ""));
    }
    if (!(g.none.send || {}).clickable) {
      f.push("the GENERATE control is not hit-testable where it sits");
    }
    if (g.none.skip) {
      f.push("THE ESCAPE HATCH IS BACK ON THE BAR before the pass starts: " +
             JSON.stringify(g.none.skip.text) + ". The captain deleted it — " +
             "\"we don't need the send without change list one\"");
    }
  }
  if (need(g.running, "while the pass was running")) {
    if (g.running.gate !== "running") {
      f.push("the bar did not read gate=running while a pass was in flight " +
             "(it read " + g.running.gate + ")");
    }
    const sb = g.running.send || {};
    if (!sb.disabled) {
      f.push("the control was NOT disabled while the pass ran — this is the " +
             "defect the captain reported: he could send before it was done");
    }
    if (!/generating/i.test(sb.text || "")) {
      f.push("the control does not SAY it is generating: " +
             JSON.stringify(sb.text || ""));
    }
    if (!g.running.spinner) {
      f.push("there is no loading indicator beside the disabled control — " +
             "\"Generating…\" with nothing moving is a label, not a state");
    }
    if (g.running.skip) {
      f.push("THE ESCAPE HATCH IS BACK ON THE BAR during the wait: " +
             JSON.stringify(g.running.skip.text) + ". It is deleted; the only " +
             "roads out of a pass are waiting for it or a failure, and both " +
             "leave ▶ SEND TO ALIGN live");
    }
    if (g.running.dialogOpen) {
      f.push("the hand-off dialog was open while the gate said RUNNING — the " +
             "gate did not gate anything");
    }
    /* S172 — STRICT NOW, AND ON THIS BAR'S OWN WORDS. It used to check the
       DIALOG's phrases here with an `|| /reload|restart/` escape hatch, which
       the bar's hint satisfies by accident — so the claim passed without ever
       being made. That mattered less when the hatch let him into the dialog
       during the wait; THIS BAR IS NOW THE ONLY SURFACE THAT TELLS HIM HE MAY
       LEAVE, so it is measured on its own sentence with no escape. */
    (want.barWalkAwayPhrases || []).forEach((phrase) => {
      if ((g.running.hint || "").indexOf(phrase) === -1) {
        f.push("the waiting bar never says " + JSON.stringify(phrase) +
               " — with the escape hatch gone this is the ONLY place he is " +
               "told he can walk away. It reads " +
               JSON.stringify((g.running.hint || "").slice(0, 160)));
      }
    });
  }
  /* A LEG THAT DRIVES THE PASS INTO ITS `failed` STATE NEVER REACHES `ready`,
     and demanding both would be the rig failing itself — the shape this file
     keeps a standing note about. */
  if (!want.expectGateFailed && need(g.ready, "once the pass landed")) {
    if (g.ready.gate !== "ready") {
      f.push("after the pass landed the bar read gate=" + g.ready.gate +
             " rather than ready");
    }
    const sb = g.ready.send || {};
    if (sb.disabled || !/send to align/i.test(sb.text || "")) {
      f.push("the control did not become a live ▶ Send to Align: " +
             JSON.stringify(sb.text || "") + " disabled=" + !!sb.disabled);
    }
    if (!sb.clickable) {
      f.push("the ▶ Send to Align control is not hit-testable where it sits");
    }
  }
  /* ── S172: THE PASS DID NOT ANSWER — the state the hatch's deletion rests
     on, and the one the captain screenshotted.

     TWO CLAIMS, and only a browser can make either of them:

       1. THE ROAD THROUGH. ▶ SEND TO ALIGN must be live and hit-testable
          WHERE IT SITS. This is the whole argument for deleting the escape
          hatch — a dead engine cannot strand a finished design because the
          PRIMARY control is the way out. A DOM test cannot tell a live button
          from one painted to look live, and it certainly cannot tell that it
          is not behind something.
       2. THE TWO CONTROLS ARE ONE FAMILY. His screenshot: a small outlined
          pill beside a full-size filled button on the same row. Read off
          COMPUTED STYLE and LAID-OUT BOXES, because a class name proves
          nothing about what reached the screen (S162: a rule that tested
          green and lost on source order). */
  if (want.expectGateFailed) {
    if (need(g.failed, "after a pass that did not answer")) {
      if (g.failed.gate !== "failed") {
        f.push("a pass that did not answer left the bar reading gate=" +
               g.failed.gate + " rather than failed");
      }
      const sb = g.failed.send || {}, rb = g.failed.retry || {};
      if (sb.disabled || !/send to align/i.test(sb.text || "")) {
        f.push("A DEAD ENGINE STRANDED THE PROGRAM: the primary control is " +
               JSON.stringify(sb.text || "") + " disabled=" + !!sb.disabled +
               ". With the escape hatch deleted this IS the road through");
      }
      if (!sb.clickable) {
        f.push("▶ Send to Align is not hit-testable where it sits on a " +
               "failed pass — the one road out of an engine outage cannot " +
               "be pressed");
      }
      if (g.failed.skip) {
        f.push("THE ESCAPE HATCH IS BACK ON THE BAR after a failed pass: " +
               JSON.stringify(g.failed.skip.text));
      }
      if (!rb.text || !rb.clickable) {
        f.push("there is no reachable ↻ retry beside it: " +
               JSON.stringify(rb.text || ""));
      }
      const sh = (sb.box || {}).h, rh = (rb.box || {}).h;
      if (sh && rh && Math.abs(sh - rh) > 2) {
        f.push("THE HAND-OFF BAR'S CONTROLS ARE MISMATCHED — ▶ Send to Align " +
               "is " + sh + "px tall and " + JSON.stringify(rb.text) + " is " +
               rh + "px. The captain reported exactly this: \"a small " +
               "outlined pill beside a full-size filled button\"");
      }
      if (rb.font && g.failed.sendFont && rb.font !== g.failed.sendFont) {
        f.push("THE HAND-OFF BAR'S CONTROLS ARE MISMATCHED — the type is " +
               g.failed.sendFont + " on ▶ Send to Align and " + rb.font +
               " on " + JSON.stringify(rb.text) + ". They must differ by " +
               "FILL, not by size");
      }
    }
  }
  if (want.expectInvalidation) {
    if (need(g.afterTurn, "after a further composer turn")) {
      if (g.afterTurn.gate !== "none") {
        f.push("A FURTHER COMPOSER TURN DID NOT INVALIDATE THE CHANGE LIST: " +
               "the bar still read gate=" + g.afterTurn.gate + ". The captain " +
               "would send a list derived from a mockup he has since redrawn.");
      }
      if (!/generat/i.test((g.afterTurn.send || {}).text || "")) {
        f.push("after a turn the control does not offer to generate again: " +
               JSON.stringify((g.afterTurn.send || {}).text || ""));
      }
    }
  }
  return f;
}

/* The verdict. Every claim is about a LAID-OUT BOX or about text the browser
   read off the live node — never about the payload the daemon sent, which the
   unit suite already owns. */
function judgeHandoff(m, want) {
  const f = [];
  if (!m || !m.present) {
    f.push("the SEND TO ALIGN dialog has no brief box at all");
    return f;
  }
  const b = m.brief, vh = m.viewportH;
  // 1. THE DAEMON ACTUALLY DELIVERED IT to the live page. A node harness calls
  //    the builders itself and stays green against a daemon that sends nothing
  //    — the S168 lesson, and the whole reason this is read off the textarea.
  (want.sections || []).forEach((h) => {
    if (b.value.indexOf(h) === -1) {
      f.push("the pre-drafted brief does not contain " + JSON.stringify(h) +
             " — the box carries " + JSON.stringify(b.headings));
    }
  });
  if (b.lines < (want.minLines || 0)) {
    f.push("the pre-drafted brief is only " + b.lines + " lines; the fixture " +
           "room's draft carries the change list and the implied behaviour and " +
           "must be at least " + want.minLines);
  }
  // 1b. S171 — AND WHAT IT MUST NOT CONTAIN. The captain deleted the numbered
  //     "in your own words" list by hand before sending, twice: *"that's a raw
  //     chat feed timeline"*, *"they had my whole chat about the close button
  //     vs x"*. A brief that grows it back is this session undone, and no unit
  //     test can see that it is the thing on his screen.
  (want.briefForbids || []).forEach((bad) => {
    if (b.value.indexOf(bad) !== -1) {
      f.push("THE BRIEF IS A TIMELINE AGAIN: it contains " +
             JSON.stringify(bad) + ", which is the raw chat feed the captain " +
             "deletes by hand before he sends");
    }
  });
  // 1c. …AND ITS FIRST LINE IS HIS OWN OPENING DESCRIPTION, VERBATIM. It is
  //     also the mission's title on both filing roads, so a heading here is
  //     the `gh issue create --title ## What it must do…` a shim once caught.
  if (want.briefOpensWith && !want.typeWhileWaiting) {
    const first = (b.value.split("\n")[0] || "").trim();
    if (first !== want.briefOpensWith) {
      f.push("the brief does not open with the captain's own words: it opens " +
             JSON.stringify(first) + ", wanted " +
             JSON.stringify(want.briefOpensWith));
    }
  }
  // 2. HE MEETS THE TOP OF HIS OWN BRIEF. The box no longer has to fit the
  //    window — it is as tall as the draft, and `.modal-body` scrolls it (see
  //    3). What must be true at rest is that line 1 is in front of him, inside
  //    the scrolling body's own visible band and not merely "in the viewport"
  //    (the body CLIPS, so those are different claims).
  const band = m.bodyRect || { top: 0, bottom: vh };
  if (!b.box || !b.box.visible) {
    f.push("the brief box did not lay out");
  } else if (b.box.top < Math.max(0, band.top) ||
             b.box.top >= Math.min(vh, band.bottom)) {
    f.push("the brief box does not start on screen — its top is at " +
           b.box.top + "px and the dialog's scrolling body only shows " +
           band.top + "→" + band.bottom + "px of a " + vh + "px window " +
           "(S128 D1: the box below the fold is the box nobody reads)");
  }
  if (!b.hit) f.push("the brief box is in the DOM but nothing can click it");
  // 3. ONE SCROLLER, AND IT IS THE MODAL BODY. S169 fix round 1, and the check
  //    the previous shape was structurally blind to: `rows` and `linesShown`
  //    count SOURCE lines, and this draft's lines wrap three and four ways at
  //    613px, so a box that "showed 16 of 31 lines" was in fact showing 269px
  //    of 835px — two thirds of his brief behind a NESTED inner scrollbar,
  //    with `## Implied by the mockup` at the bottom of it. A box inside a
  //    scroller inside a modal is a box nobody reaches.
  if (b.nestedHiddenPx > 1) {
    f.push("the brief box hides " + b.nestedHiddenPx + "px of its own " +
           b.scrollH + "px of content behind an INNER scrollbar (it is " +
           b.clientH + "px tall) — the modal body must be the only scroller, " +
           "or the last section is below the fold of an inner box");
  }
  // 4. …AND ENOUGH OF IT IS IN FRONT OF HIM AT REST to read as a brief rather
  //    than a slot. Measured off the laid-out intersection with the scrolling
  //    body, not off the `rows` attribute.
  if ((b.visibleLines || 0) < (want.minLinesShown || 0)) {
    f.push("only " + b.visibleLines + " lines of the brief are on screen at " +
           "rest (" + (b.visiblePx || 0) + "px at " + b.lineHeight +
           "px/line); it must show at least " + want.minLinesShown);
  }
  if (b.overflowY === "hidden") {
    f.push("the brief box clips its own content (overflow-y: hidden) — the " +
           "part of the draft past " + b.clientH + "px cannot be reached");
  }
  // 5. THE REST IS REACHABLE ON THE ONE SCROLLER. Proven against the body's
  //    own numbers: it must be able to scroll far enough to bring the bottom
  //    of the brief into view.
  if (m.bodyScrollH != null && m.bodyH != null &&
      b.box && b.box.bottom > band.bottom &&
      m.bodyScrollH <= m.bodyH + 1) {
    f.push("the brief runs past the bottom of the dialog's body and the body " +
           "does not scroll (scrollHeight " + m.bodyScrollH + ", clientHeight " +
           m.bodyH + ") — the rest of the draft cannot be reached at all");
  }
  // 6. THE SIGN THAT IT GREW. The hint sits directly ABOVE the box (S169 fix
  //    round 1 — "under it" is 800px down now), so it is the one thing a
  //    captain who reads only the first screen still sees. It has to NAME the
  //    two new sections.
  if (!m.hint || !m.hint.box || !m.hint.box.visible) {
    f.push("the line above the brief box, which says what the draft is made " +
           "of, is not on the screen");
  } else {
    // HIT-TESTED, not compared against the window. The modal body CLIPS what
    // overflows it, so a hint 20px past the body's visible band still has a
    // rectangle inside a 677px window and is still on nobody's screen. Only
    // elementFromPoint knows the difference.
    if (m.hint.box.bottom > Math.min(vh, band.bottom) ||
        m.hint.box.top < Math.max(0, band.top) || !m.hint.hit) {
      f.push("the line saying what the draft is made of is not WHOLLY on " +
             "screen — it runs " + m.hint.box.top + "→" + m.hint.box.bottom +
             "px, and the dialog's scrolling body only shows " + band.top +
             "→" + band.bottom + "px of a " + vh + "px window (clickable: " +
             m.hint.hit + ")");
    }
    (want.hintNames || []).forEach((w) => {
      if (m.hint.text.toLowerCase().indexOf(String(w).toLowerCase()) === -1) {
        f.push("the line above the brief box never mentions " +
               JSON.stringify(w) + " — it says " +
               JSON.stringify(m.hint.text));
      }
    });
    /* S169 FIX ROUND 2 — AND WHAT IT MUST NOT SAY. It read "18 CHANGES THE
       MOCKUP MAKES TO TODAY'S APP", which is a comparison the daemon never
       made: it counted the bullets of a section a model wrote from the
       conversation. Fix round 1 corrected the caption INSIDE the box and left
       this line, four inches above it, asserting the same thing. */
    (want.hintForbids || []).forEach((w) => {
      if (m.hint.text.toLowerCase().indexOf(String(w).toLowerCase()) !== -1) {
        f.push("the line above the brief box CLAIMS " + JSON.stringify(w) +
               " — the daemon never read the captain's app, so that is a " +
               "comparison it cannot have made. It says " +
               JSON.stringify(m.hint.text));
      }
    });
  }
  // 7. THE PRIMARY ACTION IS STILL REACHABLE. This is the check that must not
  //    quietly stop being true because the box above it got longer.
  if (!m.fileBtn) {
    f.push("there is no ▦ File Mission control in the dialog's footer");
  } else if (!m.fileBtn.hit) {
    f.push("▦ File Mission is not clickable where it is laid out (" +
           JSON.stringify(m.fileBtn.box) + " against a " + vh + "px window)");
  }
  // 8. S128's OWN CURE, unregressed: the open-questions cue rides beside it.
  if (want.expectQCue) {
    if (!m.qcue) {
      f.push("the open-questions cue (S128 D1's fix) is gone from the footer");
    } else if (!m.qcue.hit) {
      f.push("the open-questions cue is in the DOM but not clickable at rest");
    }
    /* S169 FIX ROUND 2 — IT STOPPED CRYING WOLF. `⚠ 2 OPEN QUESTIONS
       UNANSWERED — READ THEM FIRST`, in the amber warning language, beside ▦
       FILE MISSION, was the loudest thing in this dialog and on the capstone it
       was FALSE. It also fired at every open, before he had had one second to
       answer anything. A warning that is always on trains him to click past the
       strip where a real finding appears. */
    if (m.qcue && (want.qcueForbids || []).length) {
      (want.qcueForbids || []).forEach((w) => {
        if (m.qcue.text.toLowerCase().indexOf(String(w).toLowerCase()) !== -1) {
          f.push("the open-questions cue still reads as a WARNING (" +
                 JSON.stringify(w) + ") before he has had a chance to answer " +
                 "anything — it says " + JSON.stringify(m.qcue.text));
        }
      });
    }
  }
  // 9. THE GUIDANCE BLOCK IS NOT A NESTED SCROLLER EITHER (S169 fix round 2).
  //    Same defect, same dialog, the box fix round 1 missed — and it is the one
  //    carrying the precedence rule this whole session is about. Measured on
  //    the capstone: 228px of a 729px block, 69% behind an inner scrollbar.
  if (want.expectGuidance) {
    if (!m.guidance || !m.guidance.box || !m.guidance.box.visible) {
      f.push("the 'how the mockup will be read' block did not lay out");
    } else if (m.guidance.nestedHiddenPx > 1) {
      f.push("the guidance block hides " + m.guidance.nestedHiddenPx +
             "px of its own " + m.guidance.scrollH + "px of content behind an " +
             "INNER scrollbar (it is " + m.guidance.clientH + "px tall, " +
             "max-height " + m.guidance.maxHeight + ") — that block carries " +
             "the precedence rule, and the modal body must be the only " +
             "scroller in this dialog");
    }
  }
  // 10. THE DERIVATION BAND. It only does anything if it is ON THE SCREEN,
  //     and there are two different claims to make about it.
  //
  //     RUNNING is the one S170 exists for. The wait was already 154–220s;
  //     what was missing was any way for the captain to know he could leave.
  //     So the running band must be WHOLLY on the first screen, hit-testable,
  //     and it must SAY he can walk away — a sentence no node harness can
  //     confirm is in front of anybody.
  //
  //     DONE is judged on the BRIEF, not on the band: the daemon redrafts the
  //     brief with the derived change list in it, and the only honest proof
  //     that the round works is that the change line is IN THE TEXTAREA the
  //     captain is about to send.
  const judgeBand = (state, phrases, label) => {
    if (!m.check) {
      f.push("the derivation band is not in the dialog at all (" + label + ")");
      return;
    }
    if (m.check.hidden || !m.check.box || !m.check.box.visible) {
      f.push("the derivation band is in the DOM but not on the screen (" +
             label + "; hidden=" + m.check.hidden + ", box=" +
             JSON.stringify(m.check.box) + ")");
      return;
    }
    if (m.check.state !== state) {
      f.push("the derivation band is in state " + JSON.stringify(m.check.state) +
             ", not " + JSON.stringify(state) + " (" + label + ") — it reads " +
             JSON.stringify(m.check.text.slice(0, 200)));
      return;
    }
    (phrases || []).forEach((w) => {
      if (m.check.text.indexOf(w) === -1) {
        f.push("the derivation band never says " + JSON.stringify(w) + " (" +
               label + ") — it reads " +
               JSON.stringify(m.check.text.slice(0, 240)));
      }
    });
    if (!m.check.hit) {
      f.push("the derivation band is laid out but nothing can reach it where " +
             "it sits (" + label + ")");
    }
    if (m.check.box.bottom > Math.min(vh, band.bottom) ||
        m.check.box.top < Math.max(0, band.top)) {
      f.push("the derivation band is not WHOLLY on the first screen (" + label +
             ") — it runs " + m.check.box.top + "→" + m.check.box.bottom +
             "px and the dialog's scrolling body only shows " + band.top +
             "→" + band.bottom + "px of a " + vh + "px window. A band half " +
             "off the screen is a band nobody reads");
    }
    // …and it must be ABOVE the brief box. The box is as tall as the draft, so
    // anything under it is ~800px down — which is where the section this round
    // exists to surface was already sitting.
    if (b.box && m.check.box.top >= b.box.top) {
      f.push("the derivation band is BELOW the top of the brief box (" +
             m.check.box.top + "px vs " + b.box.top + "px, " + label + ")");
    }
  };
  if (want.expectDeriveRunning) {
    judgeBand("running", want.walkAwayPhrases || [], "while the pass runs");
  }
  if (want.expectDeriveDone) {
    judgeBand("done", want.donePhrases || [], "after the pass landed");
    // THE PROOF THAT SURVIVES A RELOAD: the change line is in the textarea he
    // is about to send. Not in the band, not in the payload — in the box.
    (want.expectChangeLines || []).forEach((line) => {
      if (b.value.indexOf(line) === -1) {
        f.push("the derived change " + JSON.stringify(line) + " is not in the " +
               "brief the captain would send — the box carries " +
               JSON.stringify(b.headings));
      }
    });
    /* S172 — AND SO IS THE QUESTION IT DECLARED IT WAS NOT REPORTING. The
       captain's zoom buttons and hover pill were REAL differences the pass
       found and dropped on the floor because his own out-of-scope ruling made
       them ambiguous. They come back as questions in bucket 2, and this is
       the only place that is measured in the box he would actually send. */
    (want.expectImpliedLines || []).forEach((line) => {
      if (b.value.indexOf(line) === -1) {
        f.push("THE PASS'S DECLARED QUESTION " + JSON.stringify(line) +
               " is not in the brief the captain would send — it found a " +
               "difference, decided not to report it, and dropped it on the " +
               "floor. The box carries " + JSON.stringify(b.headings));
      }
    });
    // …AND WHAT HE TYPED IS STILL THERE. The other direction of the same
    // claim: a redraft that lands on top of a human's own words is FL-013,
    // and the band must be the thing that tells him it did not.
    if (want.expectBriefKeeps && b.value.indexOf(want.expectBriefKeeps) === -1) {
      f.push("what the captain typed while the pass was running (" +
             JSON.stringify(want.expectBriefKeeps) + ") was DESTROYED by the " +
             "redraft — the box now carries " + JSON.stringify(b.headings));
    }
    if (want.expectBriefKeeps && (want.donePhrases || []).length &&
        m.check.text.indexOf("added them") === -1) {
      f.push("the derivation landed on top of a brief the captain had edited " +
             "and the band never told him what it did with his text — it " +
             "reads " + JSON.stringify(m.check.text.slice(0, 240)));
    }
  }
  return f;
}


function judgeHolodeck(deckM, boardM, want) {
  const f = [];
  want = want || {};
  // ── on the deck ─────────────────────────────────────────────────────────
  if (!deckM.onDeckClass) f.push("the ⬡ HOLODECK control did not put the page on the deck");
  if (!deckM.deckBox || !deckM.deckBox.visible) {
    f.push("the deck host is not visible (box=" + JSON.stringify(deckM.deckBox) + ")");
  }
  // D1 — it REPLACES the board. Measured on the screen, not on a class name.
  if (deckM.boardColumnsVisible) f.push("board COLUMNS are still visible on the deck");
  if (deckM.boardWrapVisible) f.push("the board wrap is still visible on the deck");
  if (deckM.legendVisible) f.push("the board legend is still visible on the deck");
  if (deckM.bandLabel !== "▦ Board") {
    f.push("on the deck the band control reads " + JSON.stringify(deckM.bandLabel) +
           ", not \"▦ Board\"");
  }
  if (!deckM.bandVisible) f.push("the band control is not visible on the deck");
  /* D2 — three CONTENT panes, laid out, in order, with real width.
     `paneClasses` is the deck's children MINUS its furniture (the drag handle
     and the drawer scrim), each of which is judged separately below against the
     shape that is right for IT. Nothing here was relaxed by that split: three
     named panes, in this order, every one of them visible and ≥80px wide, at
     the mock's ratio — the same claim, now made about the same three nodes it
     was always about. */
  const want3 = ["programs", "holo-chat", "preview"];
  if (JSON.stringify(deckM.paneClasses) !== JSON.stringify(want3)) {
    f.push("panes are " + JSON.stringify(deckM.paneClasses) + ", expected " +
           JSON.stringify(want3));
  }
  deckM.paneWidths.forEach((w, i) => {
    if (w < 80) f.push("pane " + (deckM.paneClasses[i] || i) + " is " + w +
                       "px wide — it did not lay out");
  });
  if (!deckM.panesVisible.every(Boolean)) {
    f.push("a pane is present but not visible: " + JSON.stringify(deckM.panesVisible));
  }
  /* THE CHAT : PREVIEW SPLIT (rewritten S128 — the old literal was stale).
     This asked for ~1.15:1 because that is what D2 originally fixed the split
     at. S127's captain ruling REVERSED that ("the chat takes up a comical
     amount of room"): the default is now HOLO_SPLIT_DEFAULT = 0.42 — the chat's
     share of (chat + preview) — behind a drag handle, and 1.15:1 is named in
     board.js as "the poor starting position the amendment names". The literal
     could not have been right, and this check never even ran after S127: five
     children meant `length === 3` was false and the whole assertion was skipped
     in silence. So it is now made of two claims that a later ruling cannot
     rot:

       1. THE DECK RENDERS THE SPLIT IT DECLARES. Measured share vs the
          product's own HOLO_SPLIT_DEFAULT. This is FL-008's class in a
          browser — declared 0.42, grid resolves the fr against the wrong free
          space and strands a dead band — and it holds at whatever the captain
          sets the number to next.
       2. AND THE PREVIEW IS STILL "THE POINT". The rig owns this one and does
          NOT read it off the product: the declared default must leave the
          preview at least as wide as the chat. Change HOLO_SPLIT_DEFAULT back
          to 1.15:1 and claim 1 alone would happily agree with it. */
  if (deckM.paneWidths.length === 3) {
    const chat = deckM.paneWidths[1], preview = deckM.paneWidths[2];
    const span = chat + preview;
    const share = span > 0 ? chat / span : 0;
    const declared = typeof deckM.splitDefault === "number" ? deckM.splitDefault : null;
    if (declared === null) {
      f.push("the deck declares no HOLO_SPLIT_DEFAULT — the chat:preview split " +
             "has no stated intention to measure against");
    } else {
      if (!(declared <= 0.5)) {
        f.push("THE PREVIEW IS NO LONGER THE POINT: HOLO_SPLIT_DEFAULT is " +
               declared + ", so the deck opens with the chat wider than the " +
               "preview — D2's amendment (S127) says the default must favour " +
               "the pane the captain came to look at");
      }
      if (Math.abs(share - declared) > 0.03) {
        f.push("THE DECK DOES NOT RENDER THE SPLIT IT DECLARES: chat " + chat +
               "px / preview " + preview + "px is a " + share.toFixed(3) +
               " share, declared " + declared + " (persisted split: " +
               JSON.stringify(deckM.splitStored) + ") — a track resolved " +
               "against the wrong free space strands a dead band (FL-008)");
      }
    }
    // and the tracks must actually FILL the deck. The dead band above is only
    // visible as pixels that belong to no pane at all.
    const gutter = deckM.splitM ? deckM.splitM.w : 0;
    const tracks = deckM.paneWidths[0] + chat + gutter + preview;
    if (deckM.deckviewW && Math.abs(deckM.deckviewW - tracks) > 8) {
      f.push("THE DECK'S TRACKS DO NOT FILL IT: 216+chat+gutter+preview = " +
             tracks + "px inside a " + deckM.deckviewW + "px deck — " +
             Math.abs(deckM.deckviewW - tracks) + "px belongs to no pane");
    }
  }
  /* ── S128: THE DECK'S FURNITURE, ASSERTED AS ITSELF ─────────────────────────
     Two nodes S127 added are NOT panes, and for a session this check called
     them panes and reported a healthy deck broken. They are not exempt from
     measurement — they are held to their OWN shape, which is stricter than
     being on a list of things allowed to be any size.

     FIRST: EVERY child of the deck must be a node this rig knows. The pane list
     above is filtered, so an unrecognised node would otherwise vanish from it
     silently — and "the rig quietly stopped looking" is the exact failure that
     put this repair here. A new node is not a defect and this line does not say
     it is; it says the rig has never measured it and must be taught what it is
     FOR before the run can be believed. */
  const KNOWN_DECK_CHILDREN = ["programs", "holo-chat", "preview", "holo-empty",
                               "deck-split", "holo-scrim"];
  const strangers = (deckM.deckChildClasses || []).filter(
    (c) => KNOWN_DECK_CHILDREN.indexOf(c) === -1);
  if (strangers.length) {
    f.push("THE DECK GREW SOMETHING THIS RIG HAS NEVER MEASURED: " +
           JSON.stringify(strangers) + " (children " +
           JSON.stringify(deckM.deckChildClasses) + "). Decide what it is — a " +
           "pane, or furniture — and give it its own assertion. Adding it to " +
           "KNOWN_DECK_CHILDREN without one turns this check back into " +
           "decoration.");
  }
  // THE DRAG HANDLE. It is thin BY DESIGN — 7px of grid gutter — so the pane
  // width floor is the wrong question to ask it. The right ones: is there
  // exactly one, did it actually lay out, is it a gutter rather than a pane or
  // a hairline, does it run the height of the split, does it sit BETWEEN the
  // two panes it resizes, and does the pointer say it can be dragged.
  const sp = deckM.splitM;
  const kids = deckM.deckChildClasses || [];
  if (!sp) {
    f.push("THE CHAT/PREVIEW DRAG HANDLE IS GONE: no .deck-split among the " +
           "deck's children " + JSON.stringify(kids) + " — the split is not " +
           "resizable and D2's persisted ratio has no control");
  } else {
    if (sp.count !== 1) {
      f.push("there are " + sp.count + " drag handles on the deck; there is one split");
    }
    if (!sp.visible) {
      f.push("THE DRAG HANDLE DID NOT LAY OUT: " + JSON.stringify(sp) +
             " — a gutter with no box cannot be grabbed, at any width");
    }
    if (!(sp.w >= 3 && sp.w <= 24)) {
      f.push("the drag handle is " + sp.w + "px wide — it must be a thin " +
             "gutter (3–24px): under that the cursor cannot find it, over it " +
             "it is eating one of the panes");
    }
    if (!(sp.h >= 120)) {
      f.push("the drag handle is " + sp.h + "px tall — it must run the height " +
             "of the split, not sit in it as a dot");
    }
    if (!(kids.indexOf("holo-chat") >= 0 && kids.indexOf("preview") >= 0 &&
          sp.index === kids.indexOf("holo-chat") + 1 &&
          sp.index === kids.indexOf("preview") - 1)) {
      f.push("the drag handle is not between the chat and the preview: " +
             "children " + JSON.stringify(kids) + ", handle at index " + sp.index +
             " — the 216px program list is not part of this split");
    }
    if (sp.cursor !== "col-resize") {
      f.push("the drag handle's cursor resolves to " + JSON.stringify(sp.cursor) +
             ", not \"col-resize\" — nothing on screen says it can be dragged");
    }
  }
  // THE DRAWER SCRIM, while the drawer is SHUT — which is the only state this
  // rig drives (it never narrows the viewport past the drawer breakpoint, and
  // it never clicks the drawer button). Shut, the correct measurement is a node
  // with NO box that takes NO clicks: it is a full-bleed, z-index-5 overlay
  // across the whole deck, so a scrim that merely went transparent would eat
  // every click on the panes underneath while looking perfect in a screenshot.
  const sc = deckM.scrimM;
  if (!sc) {
    f.push("THE PROGRAM DRAWER'S CLICK-AWAY SCRIM IS GONE: no .holo-scrim " +
           "among " + JSON.stringify(kids) + " — on a narrow window the drawer " +
           "can be opened and not dismissed by clicking away from it");
  } else if (sc.count !== 1) {
    f.push("there are " + sc.count + " drawer scrims on the deck; there is one drawer");
  } else if (deckM.drawerOpen) {
    // The rig does not open the drawer today. If a later leg ever does, the
    // scrim must be REAL then — measured, not assumed.
    if (!sc.visible || !(sc.opacity > 0.3) || sc.pointerEvents === "none") {
      f.push("THE OPEN DRAWER HAS NO SCRIM ON THE SCREEN: " + JSON.stringify(sc) +
             " — clicking away from an open drawer does not close it");
    }
  } else {
    if (sc.visible || sc.w !== 0 || sc.h !== 0) {
      f.push("THE SHUT DRAWER'S SCRIM IS LAID OUT OVER THE DECK: " +
             JSON.stringify(sc) + " — above the drawer breakpoint the program " +
             "list is a pane, and a full-bleed overlay at z-index 5 takes every " +
             "click meant for the panes under it");
    }
    if (sc.display !== "none" && sc.pointerEvents !== "none") {
      f.push("the shut drawer's scrim still takes clicks (display " +
             JSON.stringify(sc.display) + ", pointer-events " +
             JSON.stringify(sc.pointerEvents) + ")");
    }
  }
  if (!deckM.programRowsVisible) f.push("no program row is visible in the list");
  if (!deckM.composerVisible) f.push("the chat composer is not visible");
  // D3 + the security property.
  if (!deckM.iframeSrc) f.push("no preview iframe on the deck");
  else if (!/^\/api\/holodeck\/[^/]+\/preview\//.test(deckM.iframeSrc)) {
    f.push("the preview iframe does not point at the jailed route: " + deckM.iframeSrc);
  }
  if (!deckM.iframeBox || !deckM.iframeBox.visible) {
    f.push("the preview iframe has no visible box: " + JSON.stringify(deckM.iframeBox));
  }
  const sb = String(deckM.iframeSandbox || "");
  if (deckM.iframeSandbox === null) f.push("the preview iframe carries no sandbox attribute");
  else {
    if (sb.indexOf("allow-scripts") === -1) {
      f.push("the preview iframe is not allowed scripts — a self-contained mockup cannot switch its own screens");
    }
    if (sb.indexOf("allow-same-origin") !== -1) {
      f.push("THE SANDBOX IS DECORATION: allow-same-origin is set beside allow-scripts, " +
             "so model-written HTML can reach the board's DOM and the write API");
    }
  }
  // the accent that draws the whole deck
  if (!deckM.holoGrid) {
    f.push("--holo-grid resolves to nothing — the deck's accent paints transparent " +
           "while every box stays perfect (the S168 class)");
  }
  if (want.mockText && String(deckM.bodyText || "").indexOf(want.mockText) === -1) {
    f.push("the deck does not carry the expected copy " + JSON.stringify(want.mockText));
  }
  // ── THE JOURNEY (fix round 1) ───────────────────────────────────────────
  // Only when the rig drove it: the grounding→design path, a long transcript,
  // and the collision refusal. Absent, everything above is exactly the round-0
  // check and the existing calibration controls are unaffected.
  if (want.journey) {
    // 1. THE RECOMMENDED PATH PRODUCED A FILE. This one assertion is the whole
    //    of defect 1: the preview src exists only because mockup.html is on
    //    disk in the room, which can only happen if the posture switched.
    if (!deckM.iframeSrc) {
      f.push("THE RECOMMENDED PATH WROTE NO MOCKUP: after grounding and a design "
             + "turn the preview is still empty — the grounding posture never "
             + "handed over to the design one");
    }
    // 2. THE DECK IS THE VIEWPORT, under a LONG transcript.
    const vh = deckM.viewportH || 0;
    if (deckM.turnCount < 4) {
      f.push("the transcript is only " + deckM.turnCount + " turns — too short "
             + "to see the growth defect at all");
    }
    if (deckM.docScrollH > vh + 4) {
      f.push("THE PAGE SCROLLS ON THE DECK: scrollHeight " + deckM.docScrollH
             + " vs viewport " + vh + " — the deck grew instead of the "
             + "transcript scrolling, and the composer and preview ride off "
             + "the bottom with it");
    }
    if (deckM.deckviewH > vh + 4) {
      f.push("the .deckview is " + deckM.deckviewH + "px tall in a " + vh
             + "px viewport");
    }
    if (deckM.composerBottom === null || deckM.composerBottom > vh + 4) {
      f.push("the composer's bottom edge is at " + deckM.composerBottom
             + " in a " + vh + "px viewport — you would have to scroll to type");
    }
    if (deckM.previewBottom === null || deckM.previewBottom > vh + 4) {
      f.push("the LIVE PREVIEW's bottom edge is at " + deckM.previewBottom
             + " in a " + vh + "px viewport — D2 says it must be permanently "
             + "visible");
    }
    const tr = deckM.transcript;
    if (!tr) f.push("no transcript on the deck");
    else {
      if (tr.overflowY !== "auto" && tr.overflowY !== "scroll") {
        f.push("the transcript does not scroll internally (overflow-y: "
               + tr.overflowY + ") — so the deck has nowhere to put a long "
               + "conversation but downwards");
      }
      if (tr.scrollH <= tr.clientH) {
        f.push("the transcript is not actually overflowing (" + tr.scrollH
               + " vs " + tr.clientH + ") — this run proved nothing about a "
               + "long conversation");
      } else if (tr.scrollTop < tr.scrollH - tr.clientH - 40) {
        f.push("the transcript is not showing the newest turn (scrollTop "
               + tr.scrollTop + " of " + (tr.scrollH - tr.clientH) + ")");
      }
    }
    // 3. D12's chip is a link to the basis it names.
    if (!deckM.groundChip) f.push("the grounded program shows no ▣ chip");
    else if (deckM.groundChip.tag !== "a" || !deckM.groundChip.href) {
      f.push("the ▣ grounded chip is inert (" + JSON.stringify(deckM.groundChip)
             + ") — D12 says the header LINKS to basis.md");
    }
    // 4. the reply is prose, not markdown source with a tool trace in it.
    const rt = String(deckM.replyText || "");
    if (!rt) f.push("the last reply rendered as nothing at all");
    ["**", "# Tile picker", "| token |"].forEach((leak) => {
      if (rt.indexOf(leak) !== -1) {
        f.push("the chat is printing markdown SOURCE: " + JSON.stringify(leak));
      }
    });
    ["List directory", "3 files found", "Create mockup.html"].forEach((leak) => {
      if (rt.indexOf(leak) !== -1) {
        f.push("the engine's tool trace leaked into the chat: "
               + JSON.stringify(leak));
      }
    });
    // 4b. AND NOTHING THE MODEL WROTE WAS DELETED (fix round 2). Round 1's
    //     cleaner dropped every line opening with a box-drawing glyph, so a
    //     captain's ASCII diagram came back as its top edge alone — and a
    //     `●`-prefixed design note vanished entirely. Both are in the scripted
    //     reply; both must be ON THE SCREEN. This is the half of the reply
    //     check that looks for what ISN'T there.
    ["│  SWATCHES  │", "│  PREVIEW   │", "└────────────┘",
     "swatch labels before you decide"].forEach((gone) => {
      if (rt.indexOf(gone) === -1) {
        f.push("THE CHAT DELETED WHAT THE MODEL WROTE: " + JSON.stringify(gone)
               + " is not on the screen — a cleaner is throwing away the "
               + "captain's own diagram/notes with nothing to say it did");
      }
    });
    // 4d. S126 (#8) — THE FENCE'S DECLARED FILENAME IS ON THE SCREEN. The
    //     scripted reply carries ```file:notes.md; the captain must be able to
    //     read which file that slab of text became, in a box that exists.
    const fi = (deckM.fenceInfos || []).filter((x) => /notes\.md/.test(x.text));
    if (!fi.length) {
      f.push("A FENCE'S DECLARED FILENAME NEVER REACHED THE SCREEN: the reply "
             + "declared ```file:notes.md and the chat shows an unlabelled slab "
             + "with nothing saying which file it is");
    } else if (!fi[0].visible) {
      f.push("the fence label naming notes.md is in the DOM with no visible "
             + "box: " + JSON.stringify(fi[0]));
    } else if (fi[0].gapToBlock === null || fi[0].gapToBlock > 1) {
      // MEASURED, not reasoned about: `.turn .body.md>*` gives every direct
      // child an 8px bottom margin, so a caption styled without cancelling it
      // floats above the slab and reads as unrelated metadata (the S162 class).
      f.push("the fence label is detached from the block it names (gap "
             + fi[0].gapToBlock + "px) — it reads as unrelated metadata rather "
             + "than as that block's filename");
    }
    // 4c. N4 — RETRY TURN IS NOT A DEAD END. The rig's worker kills the first
    //     design turn noisily, before its session exists, then answers
    //     normally; the deck's own RETRY control must get the captain moving
    //     again, which is only possible if the daemon threw the unproven
    //     session id away and OPENED a fresh one. If the retry resumes the
    //     ghost, the worker refuses it the way both real CLIs do and nothing
    //     the captain does from the deck can ever recover the program.
    if (want.deadFirstTurn) {
      const n4 = want.n4 || {};
      if (!n4.died) {
        f.push("THE N4 CHECK PROVED NOTHING: the first design turn was supposed "
               + "to die before opening a session and no HOLODECK OFFLINE "
               + "banner with a RETRY control ever appeared");
      } else if (!n4.retried) {
        f.push("the turn died and the banner offered no RETRY TURN control at "
               + "all: " + JSON.stringify(n4.banner));
      } else if (!n4.recovered) {
        f.push("RETRY TURN IS A DEAD END (N4): the first turn died before its "
               + "session existed, RETRY was pressed, and the conversation "
               + "never came back — the retry resumed a session the CLI never "
               + "created. The banner promised " + JSON.stringify(n4.banner));
      }
      /* ── S126 (#7): THREE CLAIMS THAT WERE UNIT-TEST-ONLY ─────────────────
         All three were cured in S125 and proven only in node — and S125 proved
         TWICE that a unit test can be green while the product is wrong (the
         renderer that dropped every plain paragraph; the stub that died
         SILENTLY, a shape the real world never produces). The banner below was
         raised by a worker that died NOISILY and non-zero, which is the only
         version of this that can see the defect. */
      if (n4.died) {
        const banner = String(n4.banner || "");
        // ── N5: the banner answers what stopped, that the work is safe, and
        //    how to try again. A raw exit code / signal number answers none of
        //    those and is not something a captain can act on.
        const leaks = [
          /\bexit(?:ed|\s*code|\s*status)?\b[^.\n]{0,14}?-?\d+/i,
          /\bsignal\s*(?:number\s*)?-?\d+/i,
          /\bSIG[A-Z]{3,}\b/,
          /\breturn\s*code\b/i,
        ];
        leaks.forEach((re) => {
          if (re.test(banner)) {
            f.push("N5: the HOLODECK OFFLINE banner leaks a raw exit code or "
                   + "signal number — LCARS internals, not the engine speaking, "
                   + "and nothing the captain can do anything about: "
                   + JSON.stringify(banner));
          }
        });
        // ── ONE VOICE: the daemon's message IS the account of what happened.
        //    Round 1 wrote a second copy on this side, so every failure said
        //    everything twice — and the client's half re-asserted an AUTHORSHIP
        //    claim the daemon had just been cured of.
        ["your program is safe", "the chat is still running",
         "say it again to retry", "every earlier turn is committed"
        ].forEach((phrase) => {
          const n = banner.toLowerCase().split(phrase).length - 1;
          if (n > 1) {
            f.push("TWO VOICES IN THE BANNER: " + JSON.stringify(phrase)
                   + " is printed " + n + " times — the client is writing its "
                   + "own copy beside the daemon's: " + JSON.stringify(banner));
          }
        });
        if (/never touches your project|nothing out there has been (?:changed|removed)|has not touched anything|LCARS did not (?:change|touch|remove)/i
            .test(banner)) {
          f.push("THE BANNER MAKES AN AUTHORSHIP CLAIM: it tells the captain "
                 + "what LCARS did or did not touch out in his project, which "
                 + "is precisely what the daemon's audit CANNOT know — it "
                 + "watches files, not who touched them: "
                 + JSON.stringify(banner));
        }
      }
      // ── N6: HE SAID IT ONCE. The retried line is the same turn, so no two
      //    captain bubbles on the deck may read identically.
      const said = deckM.youLines || [];
      const seen = {};
      said.forEach((line) => {
        if (!line) return;
        seen[line] = (seen[line] || 0) + 1;
        if (seen[line] === 2) {
          f.push("N6: the captain's line is on the deck TWICE — "
                 + JSON.stringify(line.slice(0, 60))
                 + " — a retry is the SAME turn said once, not a second one");
        }
      });
      if (!said.length) {
        f.push("THE N6 CHECK PROVED NOTHING: no captain line is on the deck at "
               + "all, so nothing was checked for duplication");
      }
    }
    // 5. two programs cannot share one room.
    if (want.collision) {
      /* COUNT THE CARDS FOR THAT NAME, not the cards on the deck (S126). The
         deck now lists rooms READ OFF DISK as well as live sessions, and the
         rig plants one (`nav-rail`) before the daemon boots — so a total of 2
         is the correct, healthy answer here and the old total-count assertion
         failed on a product that was behaving perfectly. What the refusal has
         to prevent is a SECOND CARD FOR ONE NAME: two rows a captain cannot
         tell apart, both writing one mockup.html. */
      if (want.collision.sameName !== 1) {
        f.push("a second program called "
               + JSON.stringify(want.collision.name) + " created a second card ("
               + want.collision.sameName + " of that name, "
               + want.collision.programs + " on the deck) — both writing one "
               + "mockup.html, indistinguishable in the list");
      }
      if (!want.collision.errorText) {
        f.push("the duplicate name was refused with no message the captain "
               + "can read");
      }
    }
    // 6. THE MORNING STATE (fix round 2, defect 6).
    if (!want.morning || !want.morning.rows) {
      f.push("THE MORNING-STATE CHECK PROVED NOTHING: the deck's first paint "
             + "showed no program rows at all, so the screen a captain gets "
             + "every morning was never on the screen this run");
    } else {
      const mt = String(want.morning.text || "");
      const ml = mt.toLowerCase();
      if (!want.morning.visible) {
        f.push("the deck's opening pane is in the DOM with no painted box");
      }
      if (ml.indexOf("left") === -1) {
        f.push("THE MORNING STATE POINTS AT NOTHING: " + want.morning.rows
               + " program(s) are in the list on the left and the main area "
               + "never mentions them — " + JSON.stringify(mt.slice(0, 160)));
      }
      if (ml.indexOf("same name") === -1) {
        f.push("the one prominent button (＋ NEW PROGRAM) is offered with no "
               + "word of what it does to a program that is already there — "
               + "under the same name it lands in the room-reuse disclosure, "
               + "under a different one the work is in two places");
      }
    }
    // 7. THE WARM RESTART SAYS ONE THING (fix round 2, defect 5).
    if (!want.restart || !want.restart.banner) {
      f.push("THE WARM-RESTART CHECK PROVED NOTHING: clicking the archived "
             + "room produced no banner, so the pill was never read beside it");
    } else {
      const bl = String(want.restart.banner).toLowerCase();
      const pl = String(want.restart.pill || "").toLowerCase();
      if (bl.indexOf("fresh") === -1) {
        f.push("the warm-restart banner does not say the next worker is fresh: "
               + JSON.stringify(want.restart.banner.slice(0, 160)));
      }
      if (!want.restart.pill || !want.restart.pillVisible) {
        f.push("the chat header has no visible engine pill on a reopened "
               + "program: " + JSON.stringify(want.restart));
      } else if (pl.indexOf("warm") !== -1) {
        f.push("THE SCREEN SAYS TWO THINGS AT ONCE: the banner says the "
               + "conversation is over and the next worker is fresh, and the "
               + "pill two inches below it reads "
               + JSON.stringify(want.restart.pill));
      }
    }
    // 8. S169 (FL-013) — THE UNSENT TURN.
    const dr = want.draft;
    if (!dr || !dr.idle || !dr.back) {
      f.push("THE DRAFT CHECK PROVED NOTHING: there was no composer to type "
             + "into on this run, so nothing was learnt about whether the "
             + "holodeck keeps an unsent turn"
             + (dr && dr.armErr ? " (" + dr.armErr + ")" : ""));
    } else {
      /* (a) THE POLL, ANSWERED RATHER THAN ASSUMED. The board's 4s safety poll
             must not be rebuilding the chat pane. If it is, a draft dies four
             seconds after it is typed and the surface is unusable — a much
             larger claim than the one the report made, and the reason this was
             worth measuring instead of reasoning about. */
      if (!(dr.idle.boardRenders > 0)) {
        f.push("THE POLL CHECK PROVED NOTHING: the board did not re-render "
               + "once in " + Math.round(dr.pollMs * 2.4) + "ms, so the "
               + "question 'does the 4s poll rebuild the chat pane' was never "
               + "actually put (" + JSON.stringify(dr.idle) + ")");
      } else if (dr.idle.deckRenders > 0 || !dr.idle.sameNode) {
        f.push("THE 4s POLL REBUILDS THE CHAT PANE: " + dr.idle.deckRenders
               + " deck re-render(s) in " + Math.round(dr.pollMs * 2.4)
               + "ms of sitting still (board re-renders: "
               + dr.idle.boardRenders + ") — an unsent turn cannot survive a "
               + "repaint on a timer, whatever else is done about it");
      }
      if (dr.idle.value !== dr.text) {
        f.push("THE HOLODECK ATE AN UNSENT TURN WHILE NOBODY TOUCHED IT: "
               + JSON.stringify(String(dr.idle.value).slice(0, 60)));
      }
      /* (b) AND THE JOURNEY HE DESCRIBED. The node identity is asserted first:
             a draft that "survived" a round trip that never rebuilt the pane
             is the shape in which this check would pass on a product that had
             not been fixed at all. */
      if (!dr.back.present) {
        f.push("THE DRAFT CHECK PROVED NOTHING: the composer was gone after "
               + "⬡ HOLODECK → ▦ BOARD → ⬡ HOLODECK");
      } else if (dr.back.sameNode) {
        f.push("THE DRAFT CHECK PROVED NOTHING: the board round-trip did not "
               + "rebuild the composer at all (same node), so a surviving "
               + "draft says nothing about surviving a rebuild");
      } else if (dr.back.value !== dr.text) {
        f.push("THE HOLODECK ATE AN UNSENT TURN ON THE BOARD ROUND-TRIP: he "
               + "typed " + JSON.stringify(dr.text.slice(0, 48)) + "…, went to "
               + "the board and came back to "
               + JSON.stringify(String(dr.back.value).slice(0, 48)));
      }
      /* (c) S169 (FL-014) — and a real clipboard paste is HARVESTED. Silence
             was the actual defect he hit: with no handler on this textarea the
             event went nowhere, nothing was sent, and the daemon's own honest
             refusal could never fire. */
      if (dr.pasteErr || !dr.paste) {
        f.push("THE PASTE CHECK PROVED NOTHING: the clipboard event was never "
               + "dispatched (" + (dr.pasteErr || "no measurement") + ")");
      } else if (!dr.paste.chips.length || !dr.paste.visible) {
        f.push("A PASTED IMAGE DID NOTHING ON THE COMPOSER: a real "
               + "ClipboardEvent carrying a PNG produced "
               + JSON.stringify(dr.paste.chips) + " ("
               + dr.paste.visible + " with a painted box) and the deck is "
               + "holding " + dr.paste.held + " image(s) — the deck's own rule "
               + "is that nothing does nothing when you use it");
      } else if (!dr.paste.held) {
        f.push("the pasted image drew a chip but the deck is holding none, so "
               + "the next re-render takes it: " + JSON.stringify(dr.paste));
      }
    }
    /* 8b. S169 (FL-015) — YOU CAN ASK IT SOMETHING, AND THE SCREEN SAYS SO.
       Four separate claims, each failing on the sentence that names it. */
    const ak = want.ask;
    /* "PROVED NOTHING" means THE LEG NEVER LOOKED — no deck, no composer, no
       measurement. A leg that looked and found no control has not failed a
       precondition; it has found the defect, and saying otherwise is how the
       `no-ask-on-the-composer` control went red on a line the judge is
       required to discount (measured 2026-08-06). `ctl.opts` being an array is
       the tell that the look happened. */
    if (!ak || !ak.ctl || !Array.isArray(ak.ctl.opts)) {
      f.push("THE ASK CHECK PROVED NOTHING: the composer was never inspected "
             + "on this run (" + ((ak && ak.ctl && ak.ctl.err)
                                  || "no measurement") + ")");
    } else {
      const opts = ak.ctl.opts;
      const laid = opts.filter((o) => o.box && o.box.visible);
      // `ctl.err` is set when a half the leg needs is absent — which IS the
      // defect, and the length check below names it in the same words.
      if (opts.length !== 2 || laid.length !== 2) {
        f.push("THE ASK AFFORDANCE IS NOT ON THE SCREEN: " + opts.length
               + " half/halves, " + laid.length + " with a painted box — "
               + JSON.stringify(opts));
      } else if (opts[0].intent !== "build" || opts[0].pressed !== "true") {
        f.push("THE COMPOSER DOES NOT OPEN ON BUILD, so asking a question "
               + "would need a switch he has to remember to flip: "
               + JSON.stringify(opts.map((o) => [o.intent, o.pressed])));
      } else if (!ak.ctl.pressedAfter
                 || ak.ctl.pressedAfter.join() !== "false,true") {
        f.push("CLICKING ASK DID NOT TAKE: aria-pressed reads "
               + JSON.stringify(ak.ctl.pressedAfter) + " after the click");
      } else if (ak.ctl.sendAfter === ak.ctl.sendBefore) {
        f.push("DECLARING A QUESTION CHANGES NOTHING HE CAN SEE: the Send "
               + "control still reads " + JSON.stringify(ak.ctl.sendAfter)
               + " — a declaration with no feedback is a switch he flips and "
               + "then wonders about");
      }
      // …the banner, which asserted a RENDER over a turn he only asked on.
      if (!ak.sent || ak.sent.err) {
        f.push("THE ASK-TURN CHECK PROVED NOTHING: the question was never "
               + "sent (" + ((ak.sent && ak.sent.err) || "no measurement") + ")");
      } else {
        if (!ak.sent.working) {
          f.push("THE WORKING-COPY CHECK PROVED NOTHING: no working strip was "
                 + "on screen the instant the turn was sent");
        } else if (/render/i.test(ak.sent.working)) {
          f.push("THE WORKING STRIP STILL ASSERTS A RENDER over a turn the "
                 + "captain only asked a question on: "
                 + JSON.stringify(ak.sent.working) + " — until a turn has "
                 + "written something, 'rendering' is a reason nothing on "
                 + "either side has earned");
        }
        if (ak.sent.sendWhileWorking && /render/i.test(ak.sent.sendWhileWorking)) {
          f.push("…and the Send control says "
                 + JSON.stringify(ak.sent.sendWhileWorking) + " with it");
        }
        // …and the OUTCOME, which is the half that would have caught this.
        if (!ak.outcome) {
          f.push("THE ASK-OUTCOME CHECK PROVED NOTHING: the turn produced no "
                 + "outcome note at all in 60s, so nothing on the screen says "
                 + "whether the design moved on a turn he did not direct");
        } else if (!(ak.outcome.w > 0 && ak.outcome.h > 0)) {
          f.push("the outcome note has no painted box: "
                 + JSON.stringify(ak.outcome));
        } else if (/\bdrift\b/.test(ak.outcome.cls)) {
          f.push("HE ASKED AND THE HOLODECK BUILT ANYWAY: the turn he declared "
                 + "a question wrote " + JSON.stringify(ak.outcome.chips)
                 + " — " + JSON.stringify(ak.outcome.text.slice(0, 120)));
        } else if (!/nothing was written/i.test(ak.outcome.text)) {
          f.push("the outcome note does not say what the turn did: "
                 + JSON.stringify(ak.outcome.text.slice(0, 140)));
        } else if (ak.outcome.pressed
                   && ak.outcome.pressed.join() !== "true,false") {
          f.push("ASK IS STICKY: after the question was sent the control still "
                 + "reads " + JSON.stringify(ak.outcome.pressed) + " — his "
                 + "next 'make the rail wider' would come back as an answer");
        }
      }
    }
    // 9. S169 (FL-016) — THE INTENT PANEL'S SCRIM, IN PIXELS.
    const im = want.intent;
    if (!im || !im.ok) {
      f.push("THE INTENT-SCRIM CHECK PROVED NOTHING: "
             + ((im && im.why) || "the panel was never sampled"));
    } else {
      const at = im.bottom.at;
      // the precondition, stated as a measurement: a document LONGER than the
      // pane, really scrolled to the bottom. On a short one the defect cannot
      // appear and a green run would mean nothing.
      if (!(at.scrollH > at.clientH + 120)) {
        f.push("THE INTENT-SCRIM CHECK PROVED NOTHING: concept.md is "
               + at.scrollH + "px in a " + at.clientH + "px pane — it does not "
               + "overflow, so the scrim could not have scrolled away");
      } else if (!(at.scrollTop > 40)) {
        f.push("THE INTENT-SCRIM CHECK PROVED NOTHING: the panel did not "
               + "scroll (scrollTop " + at.scrollTop + ", overflow-y "
               + JSON.stringify(at.overflowY) + ")");
      } else {
        const top = im.top.colour, bot = im.bottom.colour, grid = im.grid;
        const drift = rgbDistance(top, bot);
        const fromGrid = rgbDistance(bot, grid);
        // CALIBRATION FIRST. If the top sample is itself indistinguishable
        // from the bare grid, the two ends agreeing proves nothing.
        if (rgbDistance(top, grid) < 7) {
          f.push("THE INTENT-SCRIM CHECK PROVED NOTHING: the top of the "
                 + "document already paints the same colour as the bare deck "
                 + "grid (text backing rgb(" + top.r + "," + top.g + "," + top.b
                 + ") vs grid rgb(" + grid.r + "," + grid.g + "," + grid.b
                 + ")) — there is no scrim anywhere to lose");
        } else if (drift > 6 || fromGrid < 7) {
          /* ONE SENTENCE FOR ONE DEFECT (fix round 1). This was two — a
             "drifted" branch and an "it is the bare grid" branch — and the
             control landed between them: the pre-fix bottom sample is BOTH
             12.2 away from the top and 0 away from the grid, so which line
             fired was decided by a rounding, and the calibration judged the
             control red for the wrong reason. They were never two findings.
             The two numbers are the evidence and both are printed; the
             headline is the mechanism. */
          f.push("THE INTENT SCRIM SCROLLS AWAY: the colour painted behind the "
                 + "captain's own requirements is rgb(" + top.r + "," + top.g
                 + "," + top.b + ") at the top of concept.md and rgb(" + bot.r
                 + "," + bot.g + "," + bot.b + ") " + at.scrollTop
                 + "px down it — a drift of " + drift + ", landing " + fromGrid
                 + " from the bare deck grid rgb(" + grid.r + "," + grid.g + ","
                 + grid.b + "). The words are on the grid, which is the state "
                 + "the captain photographed");
        }
      }
    }
  }
  // ── back on the board ───────────────────────────────────────────────────
  if (boardM) {
    if (boardM.onDeckClass) f.push("▦ BOARD did not leave the deck");
    if (!boardM.boardColumnsVisible) {
      f.push("the board did not come back — no visible .col after ▦ BOARD");
    }
    if (boardM.deckBox && boardM.deckBox.visible) {
      f.push("the deck is still visible after ▦ BOARD");
    }
    if (boardM.bandLabel !== "⬡ Holodeck") {
      f.push("back on the board the control reads " + JSON.stringify(boardM.bandLabel));
    }
  }
  return f;
}

async function main() {
  // Chrome's own handshake: /json/version is only answerable once the browser
  // endpoint is live, so this IS the "browser is ready" signal.
  let verInfo = null;
  while (Date.now() < deadline) {
    try {
      const r = await fetch("http://127.0.0.1:" + DEVTOOLS_PORT + "/json/version");
      if (r.ok) { verInfo = await r.json(); break; }
    } catch (e) { /* not up yet */ }
    await sleep(100);
  }
  if (!verInfo) {
    throw new InfraError("Chrome's devtools endpoint never answered on port " +
      DEVTOOLS_PORT + " within " + TIMEOUT + "ms");
  }

  let cdp;
  try {
    cdp = new CDP(await connect(verInfo.webSocketDebuggerUrl));
  } catch (e) {
    throw new InfraError("could not attach to Chrome: " + e.message);
  }

  // about:blank FIRST, then enable the listeners, then navigate — so an error
  // thrown during the board's own boot is captured, not raced past.
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Runtime.enable", {}, sessionId);
  await cdp.send("Log.enable", {}, sessionId);
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
  await cdp.send("Page.navigate", { url: URL_ }, sessionId);

  // Poll the real DOM until the board has painted, or the deadline passes.
  let last = { cards: 0, visibleCards: 0, columns: 0, status: "", cardText: [],
               bodyText: "", stylesheets: [], tokenProbe: "" };
  let ok = false;
  let probes = 0;   // how many times the real DOM actually answered us
  while (Date.now() < deadline) {
    try {
      const res = await cdp.send("Runtime.evaluate",
        { expression: PROBE, returnByValue: true, awaitPromise: false }, sessionId);
      if (res && res.result && res.result.value) { last = res.result.value; probes++; }
      if (last.visibleCards >= EXPECT) { ok = true; break; }
    } catch (e) { /* mid-navigation; try again */ }
    await sleep(250);
  }
  // Never say "the board did not paint" about a board we never managed to ask.
  if (probes === 0) {
    throw new InfraError("the deadline (" + TIMEOUT + "ms) expired before the page " +
      "could be probed even once — the board was never asked whether it painted");
  }

  // The screenshot is taken on PASS AND FAIL. A picture of a blank board is the
  // single most useful artifact this rig can leave behind.
  //
  // FIRST widen the viewport to the board's own scroll extent. The Stage
  // columns scroll HORIZONTALLY inside #board, so at 1440px a healthy board
  // shows Align…Schedule and cuts Implement/Verify off the right edge — and a
  // tester opening that picture sees empty columns and reads "blank". Measured,
  // not guessed: captureBeyondViewport alone does nothing here, because the
  // overflow is on an inner element, not the document. Evidence that misleads
  // is worse than no evidence.
  let shot = "";
  try {
    const fit = await cdp.send("Runtime.evaluate", {
      expression: `(function () {
        var b = document.getElementById("board");
        var w = window.innerWidth, h = window.innerHeight;
        if (b) w = Math.max(w, Math.ceil(b.scrollWidth + b.getBoundingClientRect().left + 24));
        h = Math.max(h, document.documentElement.scrollHeight);
        return { w: Math.min(w, 6000), h: Math.min(h, 6000) };
      })()`, returnByValue: true }, sessionId);
    const v = (fit && fit.result && fit.result.value) || { w: 1440, h: 1000 };
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: v.w, height: v.h, deviceScaleFactor: 1, mobile: false }, sessionId);
    await sleep(300);  // one reflow; the assertions are already made above
    const png = await cdp.send("Page.captureScreenshot",
      { format: "png", captureBeyondViewport: true }, sessionId);
    shot = path.join(OUT, "board.png");
    fs.writeFileSync(shot, Buffer.from(png.data, "base64"));
  } catch (e) {
    cdp.pageErrors.push("screenshot failed: " + e.message);
  }

  // ── ACT TWO (optional, --legend-check): the bottom legend's swatches ──────
  // Only when asked for. Runs BEFORE the console act deliberately — that one
  // opens a modal over the board, and a chip measured from under an overlay is
  // not the chip the captain looks at.
  let legendCheck = null;
  if (LEGEND_CHECK_FILE && ok) {
    let want = {};
    try {
      want = JSON.parse(fs.readFileSync(LEGEND_CHECK_FILE, "utf8"));
    } catch (e) {
      throw new InfraError("could not read --legend-check file " +
        LEGEND_CHECK_FILE + ": " + e.message);
    }
    // Back to a captain-sized window: the board screenshot above widened the
    // viewport to the column strip's scroll extent, and nobody reads a legend
    // at 4000px.
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
    await sleep(200);
    const r = await cdp.send("Runtime.evaluate",
      { expression: LEGEND_PROBE, returnByValue: true }, sessionId);
    const probe = (r && r.result && r.result.value) || { present: false, swatches: [] };
    // A CLOSE-UP is the deliverable here. The swatches are 12px chips at the
    // bottom of a 4000px-wide board — in board.png a reader cannot tell a blank
    // one from a dark one, and evidence nobody can read is not evidence.
    let lshot = "";
    try {
      const clipOpts = { format: "png", captureBeyondViewport: true };
      if (probe.legendBox && probe.legendBox.w > 0 && probe.legendBox.h > 0) {
        clipOpts.clip = {
          x: Math.max(0, probe.legendBox.x - 12), y: Math.max(0, probe.legendBox.y - 12),
          width: Math.min(probe.legendBox.w + 24, 1440),
          height: probe.legendBox.h + 24, scale: 3,
        };
      }
      const png = await cdp.send("Page.captureScreenshot", clipOpts, sessionId);
      lshot = path.join(OUT, "legend.png");
      fs.writeFileSync(lshot, Buffer.from(png.data, "base64"));
    } catch (e) {
      cdp.pageErrors.push("legend screenshot failed: " + e.message);
    }
    const failures = judgeLegend(probe, want);
    legendCheck = { want: want, measured: probe, failures: failures,
                    screenshot: lshot, ok: failures.length === 0 };
    fs.writeFileSync(path.join(OUT, "legend-check.json"),
      JSON.stringify(legendCheck, null, 2) + "\n");
  }

  // ── ACT TWO-AND-A-HALF (optional, --ghlink-check): the GitHub links ──────
  // Only when asked for. Runs BEFORE the console act, which opens a modal over
  // the board; it closes its own overlay afterwards so that act is undisturbed.
  let ghLinkCheck = null;
  if (GHLINK_CHECK_FILE && ok) {
    let want = {};
    try {
      want = JSON.parse(fs.readFileSync(GHLINK_CHECK_FILE, "utf8"));
    } catch (e) {
      throw new InfraError("could not read --ghlink-check file " +
        GHLINK_CHECK_FILE + ": " + e.message);
    }
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
    await sleep(200);
    // Open a mission's DETAIL overlay — that is where the ↗ View on GitHub
    // button lives. The card badge is already on the board and needs no click.
    const clicked = await cdp.send("Runtime.evaluate", {
      expression: `(function () {
        var sel = ${JSON.stringify(want.mission || "")};
        var card = sel ? document.querySelector('.card[data-mid="' + sel + '"]')
                       : document.querySelector('.card');
        if (!card) return "no card to open (looked for " + (sel || "any") + ")";
        card.click();
        return "";
      })()`, returnByValue: true }, sessionId);
    const clickErr = (clicked && clicked.result && clicked.result.value) || "";
    // The overlay fills in from GET /api/mission/<id>, so poll on the observed
    // signal with a deadline. Never a sleep-and-hope.
    let probe = { links: [], detailOpen: false, cards: 0 };
    const gDeadline = Date.now() + Math.max(5000, Math.min(TIMEOUT, 20000));
    while (Date.now() < gDeadline) {
      const r = await cdp.send("Runtime.evaluate",
        { expression: GHLINK_PROBE, returnByValue: true }, sessionId);
      if (r && r.result && r.result.value) {
        probe = r.result.value;
        if (probe.detailOpen) break;
      }
      await sleep(200);
    }
    // What the daemon actually put on the wire, for the readout. NOT what the
    // verdict is made of — the verdict is the resolved href above.
    try {
      const w = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          try { return JSON.stringify({ ghHost: (LAST_BOARD && LAST_BOARD.meta &&
            LAST_BOARD.meta.ghHost) || null, repo: (LAST_BOARD && LAST_BOARD.meta &&
            LAST_BOARD.meta.repo) || null }); } catch (e) { return "{}"; }
        })()`, returnByValue: true }, sessionId);
      probe.payloadMeta = JSON.parse((w && w.result && w.result.value) || "{}");
    } catch (e) { probe.payloadMeta = null; }
    let gshot = "";
    try {
      const png = await cdp.send("Page.captureScreenshot",
        { format: "png", captureBeyondViewport: true }, sessionId);
      gshot = path.join(OUT, "gh-links.png");
      fs.writeFileSync(gshot, Buffer.from(png.data, "base64"));
    } catch (e) {
      cdp.pageErrors.push("gh-links screenshot failed: " + e.message);
    }
    const failures = clickErr ? [clickErr].concat(judgeGhLinks(probe, want))
                              : judgeGhLinks(probe, want);
    ghLinkCheck = { want: want, measured: probe, failures: failures,
                    screenshot: gshot, ok: failures.length === 0 };
    fs.writeFileSync(path.join(OUT, "ghlink-check.json"),
      JSON.stringify(ghLinkCheck, null, 2) + "\n");
    // Put the board back the way we found it for whatever act runs next.
    await cdp.send("Runtime.evaluate", {
      expression: `(function () { try { closeOverlay(); } catch (e) {} })()`,
      returnByValue: true }, sessionId);
    await sleep(200);
  }

  // ── ACT THREE (optional, --console-check): the File console's pre-flight ──
  // Only when asked for; without the flag not one line of this runs and the
  // default rig is exactly what it was.
  let consoleCheck = null;
  if (CONSOLE_CHECK_FILE && ok) {
    let want = {};
    try {
      want = JSON.parse(fs.readFileSync(CONSOLE_CHECK_FILE, "utf8"));
    } catch (e) {
      throw new InfraError("could not read --console-check file " +
        CONSOLE_CHECK_FILE + ": " + e.message);
    }
    // Back to a normal window first: the board screenshot above widened the
    // viewport to the column strip's scroll extent, and a 4000px-wide console is
    // not what any captain sees.
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
    await sleep(200);
    const clicked = await cdp.send("Runtime.evaluate", {
      expression: `(function () {
        var b = document.getElementById("fileBtn");
        if (!b) return "no #fileBtn on the board";
        b.click();
        return document.querySelector(".modal") ? "" : "the click opened no console";
      })()`, returnByValue: true }, sessionId);
    const clickErr = (clicked && clicked.result && clicked.result.value) || "";
    // A board with no File button, or one that refuses to open its console, is a
    // PRODUCT failure, not an infrastructure one — it leaves by exit 1 below.
    let probe = { present: false, consoleOpen: false, clickError: clickErr };
    // The pre-flight is asynchronous BY DESIGN (the console opens instantly and
    // fills in when GET /api/base-freshness answers), so this polls for it on an
    // observed signal with a deadline. Never a sleep-and-hope.
    const cDeadline = Date.now() + Math.max(5000, Math.min(TIMEOUT, 20000));
    while (Date.now() < cDeadline) {
      const r = await cdp.send("Runtime.evaluate",
        { expression: CONSOLE_PROBE, returnByValue: true }, sessionId);
      if (r && r.result && r.result.value) {
        probe = r.result.value;
        probe.clickError = clickErr;
        if (probe.present && !probe.wrapHidden) break;
      }
      await sleep(200);
    }
    let cshot = "";
    try {
      const png = await cdp.send("Page.captureScreenshot",
        { format: "png", captureBeyondViewport: true }, sessionId);
      cshot = path.join(OUT, "file-console.png");
      fs.writeFileSync(cshot, Buffer.from(png.data, "base64"));
    } catch (e) {
      cdp.pageErrors.push("console screenshot failed: " + e.message);
    }
    const failures = clickErr ? [clickErr].concat(judgeConsole(probe, want))
                             : judgeConsole(probe, want);
    consoleCheck = { want: want, measured: probe, failures: failures,
                     screenshot: cshot, ok: failures.length === 0 };
    fs.writeFileSync(path.join(OUT, "console-check.json"),
      JSON.stringify(consoleCheck, null, 2) + "\n");
  }


  // ── ACT FOUR (optional, --holodeck-check): S125's deck, in a real browser ─
  // Only when asked for; without the flag not one line of this runs and the
  // default rig is byte-for-byte what it was.
  let holodeckCheck = null;
  if (HOLODECK_CHECK_FILE && ok) {
    let want = {};
    try {
      want = JSON.parse(fs.readFileSync(HOLODECK_CHECK_FILE, "utf8"));
    } catch (e) {
      throw new InfraError("could not read --holodeck-check file " +
        HOLODECK_CHECK_FILE + ": " + e.message);
    }
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
    await sleep(200);
    // 1. Enter the deck through the REAL control the captain clicks.
    const entered = await cdp.send("Runtime.evaluate", {
      expression: `(function () {
        var b = document.getElementById("holodeckBtn");
        if (!b) return "no ⬡ HOLODECK control in the band";
        if (b.disabled) return "the ⬡ HOLODECK control is disabled";
        b.click();
        return "";
      })()`, returnByValue: true }, sessionId);
    let flowErr = (entered && entered.result && entered.result.value) || "";
    /* 1b. THE MORNING STATE (fix round 2, defect 6) — MEASURED BEFORE ANYTHING
       IS OPENED, because this is the screen a captain gets every morning: the
       archive's programs are in the list on the left, nothing is selected (the
       auto-select deliberately picks up only a LIVE program), and the whole
       main area used to read PROGRAM STANDING BY / "Describe a screen…" over
       one prominent ＋ NEW PROGRAM — pointing at nothing, and at the one
       action that either lands in the room-reuse disclosure or splits his work
       in two. A node harness has no CSS and cannot see whether that pane is
       even on the screen; this can. */
    if (!flowErr) {
      const mDeadline = Date.now() + 15000;
      let morning = null;
      while (Date.now() < mDeadline) {
        const r = await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            var e = document.querySelector('.holo-empty');
            var rows = document.querySelectorAll('.prog').length;
            var b = e ? e.getBoundingClientRect() : null;
            var s = e ? getComputedStyle(e) : null;
            return { rows: rows,
                     text: e ? (e.innerText || "").trim() : "",
                     visible: !!(b && b.width > 0 && b.height > 0 &&
                                 s.display !== "none" &&
                                 s.visibility !== "hidden") };
          })()`, returnByValue: true }, sessionId);
        morning = (r && r.result && r.result.value) || null;
        if (morning && morning.rows > 0 && morning.text) break;
        await sleep(250);
      }
      want.morning = morning;
    }
    // 2. Open a program through the REAL dialog. This is a genuine
    //    POST /api/holodeck/start: it creates the session and adopts the
    //    sidecar the rig planted, and in DESIGN mode it spawns no worker and
    //    spends nothing (holodeck_start opens the room; the first `say` is
    //    what opens a warm session).
    if (!flowErr) {
      const opened = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var add = document.querySelector('.pfoot [data-ctl]') ||
                    document.querySelector('.holo-empty [data-ctl]');
          if (!add) return "no ＋ New Program control on the deck";
          add.click();
          var name = document.querySelector('[data-holo=program-name]');
          if (!name) return "the New Program dialog has no name field";
          name.value = ${JSON.stringify(want.journey
            ? (want.groundedProgram || "Tile picker")
            : (want.program || "Nav rail"))};
          var choice = document.querySelector(
            ${JSON.stringify(want.journey ? "[data-choice=grounding]"
                                          : "[data-choice=design]")});
          if (!choice) return "the dialog offers no such start-from choice";
          choice.click();
          var run = Array.prototype.slice.call(
            document.querySelectorAll('.modal [data-ctl]'))
            .filter(function (n) { return /run program/i.test(n.getAttribute('data-ctl')||''); })[0];
          if (!run) return "the dialog has no ⬡ Run Program control";
          run.click();
          return "";
        })()`, returnByValue: true }, sessionId);
      flowErr = (opened && opened.result && opened.result.value) || "";
    }
    /* ── THE JOURNEY (fix round 1) ────────────────────────────────────────
       Round 0's rig opened a BLANK-DECK program against a planted mockup: it
       never drove the default path, never spawned a turn, and never grew the
       transcript — which is why it reported green while the recommended path
       could not write a file and the deck scrolled the composer off screen.
       Now it walks the real thing: grounding pass → design turns → a long
       transcript → a duplicate name. */
    if (!flowErr && want.journey) {
      // the grounding pass is a real (stubbed) turn and blocks the POST, so
      // wait for the program to exist on the deck before typing at it.
      const gDeadline = Date.now() + 60000;
      let seen = false;
      while (Date.now() < gDeadline) {
        const r = await cdp.send("Runtime.evaluate", {
          expression: `!!document.querySelector('.transcript')`,
          returnByValue: true }, sessionId);
        if (r && r.result && r.result.value) { seen = true; break; }
        await sleep(300);
      }
      if (!seen) flowErr = "the grounding pass never produced a program on the deck";
      // what the N4 step below measured, reported whether or not it fired.
      var n4 = { died: false, retried: false, recovered: false, banner: "" };
      want.n4 = n4;
      // THE GROUNDING PASS ALREADY LEFT A REPLY ON THE DECK, so `.turn.holo` is
      // 1 before the first design turn is even typed. Round 1's loop waited for
      // `>= n + 1` and so was satisfied the instant it looked — it never waited
      // for a design turn at all, which is why the whole N4 step ran past a
      // dead first turn without seeing it. Count from where we started.
      const baseR = await cdp.send("Runtime.evaluate", {
        expression: `document.querySelectorAll('.turn.holo').length`,
        returnByValue: true }, sessionId);
      var turnBase = (baseR && baseR.result && baseR.result.value) || 0;
      // THREE design turns. Each is a real POST /say through the scripted
      // worker, and each reply is long — the transcript has to be long or the
      // growth defect is invisible (exactly round 0's blind spot).
      for (let n = 0; !flowErr && n < 3; n++) {
        // the composer is disabled WHILE a turn is in flight, which is correct
        // — so wait for it rather than calling that a failure.
        const rDeadline = Date.now() + 60000;
        while (Date.now() < rDeadline) {
          const r = await cdp.send("Runtime.evaluate", {
            expression: `(function () {
              var s = Array.prototype.slice.call(
                document.querySelectorAll('.composer [data-ctl]'))
                .filter(function (b) { return /send/i.test(b.getAttribute('data-ctl')||''); })[0];
              return !!(s && !s.disabled);
            })()`, returnByValue: true }, sessionId);
          if (r && r.result && r.result.value) break;
          await sleep(300);
        }
        const sent = await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            var ta = document.querySelector('[data-holo=composer]');
            if (!ta) return "no composer on the deck";
            ta.value = ${JSON.stringify("Turn " + (n + 1)
              + ": show me the tile picker with its swatch grid.")};
            var send = Array.prototype.slice.call(
              document.querySelectorAll('.composer [data-ctl]'))
              .filter(function (b) { return /send/i.test(b.getAttribute('data-ctl')||''); })[0];
            if (!send) return "no Send control on the composer";
            if (send.disabled) return "the Send control is disabled";
            send.click();
            return "";
          })()`, returnByValue: true }, sessionId);
        flowErr = (sent && sent.result && sent.result.value) || "";
        /* ── N4, IN THE PRODUCT (fix round 3) ────────────────────────────────
           The scripted worker kills its FIRST design turn the way a real engine
           dies at startup — noisily (`Error: authentication failed`) and before
           the CLI has opened its session — and refuses to `--resume` a session
           it never opened, exactly as both real CLIs do. So the deck's own
           RETRY TURN control is the only way back, and it only works if the
           daemon threw the unproven session id away. Round 2's cure kept the id
           whenever the turn produced a REPLY, and a dying engine's message IS a
           reply: the program was a permanent dead end under a banner promising
           "the chat is still running; say it again to retry". This walks it. */
        const tDeadline = Date.now() + 90000;
        let turnsNow = 0;
        while (!flowErr && Date.now() < tDeadline) {
          const r = await cdp.send("Runtime.evaluate", {
            expression: `(function(){
              var b = document.querySelector('.holo-banner.down');
              var rt = b ? b.querySelector('[data-ctl]') : null;
              return { turns: document.querySelectorAll('.turn.holo').length,
                       banner: b ? (b.innerText || "").trim() : "",
                       retry: !!rt }; })()`,
            returnByValue: true }, sessionId);
          const v = (r && r.result && r.result.value) || { turns: 0 };
          turnsNow = v.turns;
          if (v.turns >= turnBase + n + 1) break;
          if (v.retry) {
            if (n === 0 && !n4.retried) {
              n4.died = true;
              n4.banner = v.banner;
              RIG_PROVOKED.deadFirstTurn++;   // the 502 is this step's doing
              await cdp.send("Runtime.evaluate", {
                expression: `(function () {
                  var b = document.querySelector('.holo-banner.down');
                  var rt = b ? b.querySelector('[data-ctl]') : null;
                  if (rt) rt.click();
                })()`, returnByValue: true }, sessionId);
              n4.retried = true;
            } else {
              flowErr = "a design turn died and the deck could not recover it: "
                      + v.banner;
            }
          }
          await sleep(300);
        }
        if (n === 0) n4.recovered = turnsNow >= turnBase + 1;
        await sleep(300);
      }
      // and the collision: the SAME name again must not make a second card.
      if (!flowErr) {
        RIG_PROVOKED.duplicateStart++;   // the 409 below is this line's doing
        await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            var add = document.querySelector('.pfoot [data-ctl]');
            if (!add) return;
            add.click();
            var name = document.querySelector('[data-holo=program-name]');
            if (name) name.value = ${JSON.stringify(want.groundedProgram || "Tile picker")};
            var run = Array.prototype.slice.call(
              document.querySelectorAll('.modal [data-ctl]'))
              .filter(function (n) { return /run program/i.test(n.getAttribute('data-ctl')||''); })[0];
            if (run) run.click();
          })()`, returnByValue: true }, sessionId);
        await sleep(2500);
        const col = await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            var want = ${JSON.stringify(want.groundedProgram || "Tile picker")};
            var err = document.querySelector('.modal .errline');
            var out = { errorText: err && !err.hidden ? (err.innerText||"").trim() : "",
                        name: want, programs: 0, sameName: 0, names: [] };
            var close = Array.prototype.slice.call(
              document.querySelectorAll('.modal [data-ctl], .modal button'))
              .filter(function (n) { return /cancel/i.test((n.textContent||"")); })[0];
            if (close) close.click();
            var rows = Array.prototype.slice.call(
              document.querySelectorAll('.prog'));
            out.programs = rows.length;
            out.names = rows.map(function (r) {
              var n = r.querySelector('.pn');
              return n ? (n.innerText || "").trim() : "";
            });
            out.sameName = out.names.filter(function (n) { return n === want; }).length;
            return out;
          })()`, returnByValue: true }, sessionId);
        want.collision = (col && col.result && col.result.value) || null;
        await sleep(400);
      }
    }
    // 3. Poll the REAL DOM until the three panes and the preview iframe exist.
    let deckM = { onDeckClass: false, paneClasses: [], paneWidths: [],
                  panesVisible: [], deckChildClasses: [] };
    const hDeadline = Date.now() + Math.max(5000, Math.min(TIMEOUT, 25000));
    while (Date.now() < hDeadline) {
      const r = await cdp.send("Runtime.evaluate",
        { expression: HOLODECK_PROBE, returnByValue: true }, sessionId);
      if (r && r.result && r.result.value) {
        deckM = r.result.value;
        if (deckM.onDeckClass && deckM.paneClasses.length === 3 && deckM.iframeSrc) break;
      }
      await sleep(250);
    }
    let hshot = "";
    try {
      const png = await cdp.send("Page.captureScreenshot",
        { format: "png", captureBeyondViewport: true }, sessionId);
      hshot = path.join(OUT, "holodeck.png");
      fs.writeFileSync(hshot, Buffer.from(png.data, "base64"));
    } catch (e) {
      cdp.pageErrors.push("holodeck screenshot failed: " + e.message);
    }
    /* ── 3a. S169 (FL-013): THE UNSENT TURN, AGAINST A REAL TIMER ───────────
       In the captain's words: "I was typing text, but hadn't sent it in the
       holodeck, I switched back to the board to deploy main, and when I came
       back my text was gone."

       TWO SEPARATE QUESTIONS, and only a browser can answer the first.

       (a) DOES THE 4s SAFETY POLL REBUILD THE CHAT PANE? The report said a
           board round-trip; the mechanism said any repaint at all — so if the
           poll rebuilds it, a draft dies four seconds after it is typed and
           the surface is unusable, not merely lossy. Nothing in `web/tests/`
           can answer this: those harnesses call the render functions
           themselves and have no timer. This one types, then WAITS past two
           whole poll intervals with `renderDeck` and `render` instrumented,
           and reports what actually ran.

       (b) AND DOES THE JOURNEY HE DESCRIBED KEEP IT? ⬡ HOLODECK → ▦ BOARD →
           ⬡ HOLODECK, through the real band control. The composer node
           identity is carried on the node itself, so "it survived" cannot pass
           by the pane simply never having been rebuilt. */
    if (deckM.onDeckClass && deckM.composerPresent) {
      const DRAFT = "Half a paragraph I have not sent yet, and it has to still "
        + "be here when I come back from the board.";
      const armed = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          if (!ta) return { err: "no composer on the deck" };
          /* Instrument the two renderers. Both are looked up GLOBALLY at every
             call site inside board.js, so a wrapper here really is what runs —
             and \`setInterval(refresh, …)\` captured \`refresh\` at boot, which
             is why \`render\` is counted rather than it. */
          window.__rigDeck = 0; window.__rigBoard = 0;
          var rd = window.renderDeck, rb = window.render;
          window.renderDeck = function () {
            window.__rigDeck++; return rd.apply(this, arguments);
          };
          window.render = function () {
            window.__rigBoard++; return rb.apply(this, arguments);
          };
          ta.value = ${JSON.stringify(DRAFT)};
          ta.dispatchEvent(new Event("input", { bubbles: true }));
          ta.__rigStamp = "S169";
          return { err: "", poll: (typeof LIVE_POLL_MS === "number"
                                   ? LIVE_POLL_MS : null) };
        })()`, returnByValue: true }, sessionId);
      const arm = (armed && armed.result && armed.result.value) || {};
      const pollMs = arm.poll || 4000;
      // PAST TWO WHOLE INTERVALS. One would be a coin toss on timing.
      await sleep(Math.round(pollMs * 2.4));
      const idleR = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          return { value: ta ? ta.value : null,
                   sameNode: !!(ta && ta.__rigStamp === "S169"),
                   deckRenders: window.__rigDeck,
                   boardRenders: window.__rigBoard };
        })()`, returnByValue: true }, sessionId);
      // …and now the round trip he actually made, through the real control.
      await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var b = document.getElementById("holodeckBtn"); if (b) b.click();
        })()`, returnByValue: true }, sessionId);
      await sleep(600);
      await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var b = document.getElementById("holodeckBtn"); if (b) b.click();
        })()`, returnByValue: true }, sessionId);
      await sleep(900);
      const backR = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          return { value: ta ? ta.value : null,
                   present: !!ta,
                   sameNode: !!(ta && ta.__rigStamp === "S169"),
                   deckRenders: window.__rigDeck,
                   boardRenders: window.__rigBoard };
        })()`, returnByValue: true }, sessionId);
      /* ── S169 (FL-014): AND A REAL PASTE, THROUGH A REAL CLIPBOARD EVENT ──
         "I can't paste in images in my chat." A node harness can call whatever
         listener it likes; only a browser can say whether a genuine
         ClipboardEvent carrying a File is harvested by the handler that is
         actually attached to this textarea. Deliberately NOT sent: the argv
         the image rides on is the unit suite's job (test_holodeck_endpoints's
         PastedImageReachesTheEngineTest), and an extra turn here would move
         the journey the rest of this check measures. */
      const pasteR = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          if (!ta) return { err: "no composer" };
          var bytes = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
          var dt = new DataTransfer();
          dt.items.add(new File([bytes], "reference.png", { type: "image/png" }));
          ta.dispatchEvent(new ClipboardEvent("paste", {
            clipboardData: dt, bubbles: true, cancelable: true }));
          return { err: "" };
        })()`, returnByValue: true }, sessionId);
      await sleep(400);
      const chipR = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var chips = Array.prototype.slice.call(
            document.querySelectorAll('.composer .img-chip-name'));
          var vis = chips.filter(function (n) {
            var r = n.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          });
          var sid = (typeof HOLO === "object" && HOLO) ? HOLO.activeId : null;
          var d = (sid && HOLO.drafts) ? HOLO.drafts[sid] : null;
          return { chips: chips.map(function (n) { return (n.innerText||"").trim(); }),
                   visible: vis.length,
                   held: d && d.images ? d.images.length : 0 };
        })()`, returnByValue: true }, sessionId);
      want.draft = {
        text: DRAFT, pollMs: pollMs, armErr: arm.err || "",
        idle: (idleR && idleR.result && idleR.result.value) || null,
        back: (backR && backR.result && backR.result.value) || null,
        pasteErr: ((pasteR && pasteR.result && pasteR.result.value) || {}).err || "",
        paste: (chipR && chipR.result && chipR.result.value) || null,
      };
      // LEAVE THE DECK AS IT WAS FOUND. The legs below measure a banner and a
      // document, and a half-typed line in the composer is state they did not
      // ask for.
      await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          if (ta) { ta.value = ""; ta.dispatchEvent(new Event("input", { bubbles: true })); }
          Array.prototype.slice.call(
            document.querySelectorAll('.composer .img-chip-x'))
            .forEach(function (x) { x.click(); });
        })()`, returnByValue: true }, sessionId);
    }
    /* 3b. THE WARM RESTART, ON ONE SCREEN (fix round 2, defect 5). Clicking a
       room the daemon is not holding is a real POST /api/holodeck/open — no
       worker, no tokens — and it puts the daemon's banner ("the conversation
       that built it is over; the worker that answers your next turn is a fresh
       one") two inches above the chat header's engine pill, which said
       `WARM · CLAUDE`. "Warm" is the exact word for the thing that did not
       survive. Both strings are read TOGETHER, off the same painted screen,
       because the defect is only visible as a contradiction. It runs after the
       geometry above is measured, so it disturbs nothing.

       ITS PRECONDITION IS THE DECK BEING UP, NOT A CLEAN JOURNEY (fix round 3).
       This was gated on `!flowErr`, and `flowErr` is set by the design-turn
       loop above whenever a turn dies and cannot be recovered — which is
       exactly what the `retry-is-a-dead-end` control makes happen BY
       CONSTRUCTION. So under that control this leg never ran, `want.restart`
       was empty, and the check emitted "THE WARM-RESTART CHECK PROVED NOTHING"
       — a blind line the judge counts as a failed precondition, so a control
       that HAD gone red for its own reason ("RETRY TURN IS A DEAD END (N4)")
       was reported as proving nothing and --calibrate could not run green on a
       clean tree.
       Nothing about a dead design turn stops a captain clicking an archived
       room: the deck is on screen, the room is on disk, and opening it is a
       plain POST. So the leg runs whenever the deck is painted, which is the
       condition it actually depends on — and when the deck is NOT painted the
       blind line is correct and stays. */
    if (deckM.onDeckClass) {
      /* WHATEVER BANNER IS ALREADY UP IS NOT THE ONE THIS LEG MEASURES.
         The loop below used to break the instant a banner and a pill were both
         non-empty — which, on a journey that ended with HOLODECK OFFLINE on
         screen, was true on the FIRST poll, before the open POST had even
         landed. It then read the offline banner and reported that "the
         warm-restart banner does not say the next worker is fresh": a red line
         about a screen state the click never produced. So the pre-click text is
         recorded and the leg waits for a DIFFERENT banner; if none arrives, the
         measurement is null and the honest "PROVED NOTHING" line fires. On a
         clean journey there is no banner up, so this changes nothing. */
      const pre = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var b = document.querySelector('#deckHost .holo-banner');
          return b ? (b.innerText || "").trim() : "";
        })()`, returnByValue: true }, sessionId);
      const bannerBefore = (pre && pre.result && pre.result.value) || "";
      await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var row = document.querySelector('.prog.ondisk');
          if (row) row.click();
        })()`, returnByValue: true }, sessionId);
      const rDeadline = Date.now() + 20000;
      let restartM = null;
      while (Date.now() < rDeadline) {
        const r = await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            // #deckHost, not the document: the view-only banner (#holoRoBanner,
            // class "holo-banner ro") lives OUTSIDE the deck and earlier in the
            // markup, and a hidden node's innerText is "" — so a bare
            // .holo-banner query reads an empty string off the wrong element.
            var b = document.querySelector('#deckHost .holo-banner');
            var p = document.querySelector('.chat-head .pill');
            var pb = p ? p.getBoundingClientRect() : null;
            return { banner: b ? (b.innerText || "").trim() : "",
                     pill: p ? (p.innerText || "").trim() : "",
                     pillVisible: !!(pb && pb.width > 0 && pb.height > 0),
                     title: document.querySelector('.chat-head .ct')
                       ? document.querySelector('.chat-head .ct').innerText : "" };
          })()`, returnByValue: true }, sessionId);
        restartM = (r && r.result && r.result.value) || null;
        if (restartM && restartM.banner && restartM.pill
            && restartM.banner !== bannerBefore) break;
        await sleep(250);
      }
      if (restartM && restartM.banner === bannerBefore) restartM = null;
      want.restart = restartM;
      try {
        const png = await cdp.send("Page.captureScreenshot",
          { format: "png", captureBeyondViewport: true }, sessionId);
        const rshot = path.join(OUT, "holodeck-warm-restart.png");
        fs.writeFileSync(rshot, Buffer.from(png.data, "base64"));
        want.restartScreenshot = rshot;
      } catch (e) { /* the deck shot is the one that matters */ }
    }
    /* ── 3c. S169 (FL-016): THE INTENT PANEL'S SCRIM, IN PIXELS ─────────────
       "UI bug on intent tab. The darker background to help read the text
       disappears as you scroll down."

       WHY IT RUNS HERE, on the program the leg above just warm-restarted: that
       is the room this rig PLANTS, so its `concept.md` is a fixture — long on
       purpose, longer than the pane, which is the precondition the defect
       needs. The live program of the journey has whatever the scripted worker
       wrote; this one is deterministic, and the check's precondition therefore
       holds under every control rather than only on a clean journey.

       WHAT IS MEASURED: the composited colour actually painted behind a line
       of the captain's own requirements — at the TOP of the document, where
       the scrim was always correct, and at the BOTTOM after really scrolling
       there. They must match. A third sample of the bare deck grid, from the
       stage's own padding band beside the panel, is the calibration that stops
       "they match" passing on two identically-unbacked patches.

       This is the only kind of evidence that can see this defect: the CSS rule
       resolves perfectly either way — it is simply somewhere else. */
    if (deckM.onDeckClass) {
      const im = { ok: false, why: "" };
      const open = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var t = document.querySelector('.pv-toggle .pvt-b.intent');
          if (!t) return "this program has no ▤ INTENT control (no concept.md)";
          t.click();
          return "";
        })()`, returnByValue: true }, sessionId);
      im.why = (open && open.result && open.result.value) || "";
      // the panel fetches concept.md over the jailed route — wait for prose.
      if (!im.why) {
        const iDeadline = Date.now() + 15000;
        let ready = false;
        while (Date.now() < iDeadline) {
          const r = await cdp.send("Runtime.evaluate", {
            expression: `(function () {
              var d = document.querySelector('.pv-intent .md');
              return !!(d && (d.innerText || "").trim().length > 200);
            })()`, returnByValue: true }, sessionId);
          if (r && r.result && r.result.value) { ready = true; break; }
          await sleep(300);
        }
        if (!ready) im.why = "the INTENT panel never rendered concept.md";
      }
      /* ONE PAGE FUNCTION, called at two scroll positions. It returns the
         patch to photograph — a rectangle over a real line of text three
         quarters of the way down the VISIBLE band, which is where the scrim
         had already gone by the time the captain noticed. */
      const RECT_FN = `(function (frac) {
        var panel = document.querySelector('.pv-intent');
        if (!panel) return { err: "no .pv-intent" };
        var sc = panel.querySelector('.pv-intent-scroll') || panel;
        var pr = panel.getBoundingClientRect();
        var lines = Array.prototype.slice.call(
          panel.querySelectorAll('.md p, .md li, .md h2, .md h3, .md h1'));
        var want = pr.top + pr.height * frac, best = null, bestD = 1e9;
        lines.forEach(function (n) {
          var r = n.getBoundingClientRect();
          if (r.width < 24 || r.height < 8) return;
          if (r.top < pr.top + 4 || r.bottom > pr.bottom - 4) return;
          if (!(n.innerText || "").trim()) return;
          var d = Math.abs((r.top + r.bottom) / 2 - want);
          if (d < bestD) { bestD = d; best = r; }
        });
        if (!best) return { err: "no line of text inside the visible panel" };
        return {
          err: "",
          scrollTop: Math.round(sc.scrollTop),
          scrollH: Math.round(sc.scrollHeight),
          clientH: Math.round(sc.clientHeight),
          overflowY: getComputedStyle(sc).overflowY,
          patch: { x: Math.round(best.left + 3), y: Math.round(best.top + 2),
                   w: Math.max(6, Math.min(Math.round(best.width) - 6, 160)),
                   h: Math.max(5, Math.min(Math.round(best.height) - 4, 14)) },
          // the bare deck grid, from .pv-stage's own padding band beside the
          // panel. The calibration sample: without it, "top matches bottom"
          // would pass on two equally unbacked patches.
          grid: { x: Math.round(pr.left) - 9, y: Math.round(pr.top + pr.height / 2),
                  w: 6, h: 10 }
        };
      })`;
      async function atScroll(where, frac) {
        await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            var p = document.querySelector('.pv-intent');
            var sc = p ? (p.querySelector('.pv-intent-scroll') || p) : null;
            if (sc) sc.scrollTop = ${where === "bottom" ? "sc.scrollHeight" : "0"};
          })()`, returnByValue: true }, sessionId);
        await sleep(220);
        const r = await cdp.send("Runtime.evaluate", {
          expression: RECT_FN + "(" + frac + ")", returnByValue: true }, sessionId);
        return (r && r.result && r.result.value) || { err: "probe returned nothing" };
      }
      async function shoot(rect) {
        const png = await cdp.send("Page.captureScreenshot",
          { format: "png",
            clip: { x: rect.x, y: rect.y, width: rect.w, height: rect.h,
                    scale: 1 } }, sessionId);
        return darkQuartile(pngPixels(Buffer.from(png.data, "base64")));
      }
      if (!im.why) {
        try {
          const top = await atScroll("top", 0.5);
          if (top.err) { im.why = top.err; }
          else {
            im.top = { at: top, colour: await shoot(top.patch) };
            im.grid = await shoot(top.grid);
            const bot = await atScroll("bottom", 0.75);
            if (bot.err) { im.why = bot.err; }
            else {
              im.bottom = { at: bot, colour: await shoot(bot.patch) };
              im.ok = true;
            }
          }
        } catch (e) {
          if (e instanceof InfraError) throw e;
          im.why = "sampling the intent panel failed: " + e.message;
        }
      }
      want.intent = im;
      try {
        const png = await cdp.send("Page.captureScreenshot",
          { format: "png", captureBeyondViewport: true }, sessionId);
        const ishot = path.join(OUT, "holodeck-intent-scrolled.png");
        fs.writeFileSync(ishot, Buffer.from(png.data, "base64"));
        want.intentScreenshot = ishot;
      } catch (e) { /* the deck shot is the one that matters */ }
    }
    /* ── 3d. S169 (FL-015): YOU CAN ASK IT SOMETHING ───────────────────
       The captain: *"I asked it what is it mean by the events tab and it's
       doing a long 'rendering to holodeck' turn. This was a question about its
       design, not a request to update the UI."* And: *"it answered my question,
       but also spent a lot of time on the events tab."* The MOCKUP MOVED on a
       turn he had not directed.

       WHAT THIS LEG CAN AND CANNOT PROVE, said before it runs. Whether a real
       model answers-then-stops is a MODEL choice and no rig on this path can
       stand in for it — the live leg does that. What only a browser can answer
       is everything else:

         • is the ask/build control REALLY THERE — two laid-out, hit-testable
           boxes on the composer, opening on BUILD so it is genuinely optional;
         • does clicking ASK show that it took (aria-pressed AND the Send verb);
         • does the declaration reach the daemon and come back as an outcome the
           captain can read — driven through the whole stack, with the scripted
           worker branching on the declaration it was handed;
         • and does the working strip still assert "rendering" over it.

       The working strip is captured IN THE SAME EVALUATE as the click: `holoSay`
       sets `HOLO.busy` and re-renders synchronously, so the strip is in the DOM
       before the expression returns. No race, no polling.

       WHY IT RUNS LAST, and this is not tidiness. It SENDS A REAL TURN, and a
       turn touches its room — which reorders the recency-sorted program list
       and moves which row `.prog.ondisk` picks. Placed between the draft leg
       and the warm-restart leg it did exactly that: MEASURED on 2026-08-06, the
       restart leg reopened `Tile picker` instead of the planted `Nav rail`
       room, which has no long `concept.md`, so the intent-scrim leg lost its
       fixture and the chat header's pill was read off a program that really was
       warm. Both legs went red for a reason that was the rig's, not the
       product's. A leg that mutates state belongs after the legs that read it.
       (The board leg below only measures the board, which a chat turn cannot
       touch.) */
    if (deckM.onDeckClass && deckM.composerPresent) {
      const QUESTION = "What do you mean by the events tab?";
      const ctlR = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          function box(n) {
            if (!n) return null;
            var r = n.getBoundingClientRect();
            var s = getComputedStyle(n);
            return { w: Math.round(r.width), h: Math.round(r.height),
                     visible: r.width > 0 && r.height > 0
                              && s.display !== "none" && s.visibility !== "hidden"
                              && parseFloat(s.opacity || "1") > 0.05,
                     bg: s.backgroundColor };
          }
          var opts = Array.prototype.slice.call(
            document.querySelectorAll('.composer .holo-intent .iopt'));
          function sendCtl() {
            return Array.prototype.slice.call(
              document.querySelectorAll('.composer [data-ctl]'))
              .filter(function (b) { return /send/i.test(b.getAttribute('data-ctl')||''); })[0];
          }
          var before = opts.map(function (n) {
            return { intent: n.getAttribute('data-holo-intent'),
                     text: (n.innerText||"").trim(),
                     pressed: n.getAttribute('aria-pressed'),
                     box: box(n) };
          });
          var s0 = sendCtl();
          var out = { opts: before, sendBefore: s0 ? (s0.innerText||"").trim() : null };
          var ask = opts.filter(function (n) {
            return n.getAttribute('data-holo-intent') === 'ask'; })[0];
          if (!ask) { out.err = "no ASK half on the composer"; return out; }
          ask.click();
          out.pressedAfter = opts.map(function (n) {
            return n.getAttribute('aria-pressed'); });
          var s1 = sendCtl();
          out.sendAfter = s1 ? (s1.innerText||"").trim() : null;
          out.askBgOn = box(ask) ? box(ask).bg : null;
          return out;
        })()`, returnByValue: true }, sessionId);
      const ctl = (ctlR && ctlR.result && ctlR.result.value) || {};
      // …and now SEND it, reading the working strip in the same breath.
      const sentR = await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          if (!ta) return { err: "no composer" };
          ta.value = ${JSON.stringify(QUESTION)};
          ta.dispatchEvent(new Event("input", { bubbles: true }));
          var send = Array.prototype.slice.call(
            document.querySelectorAll('.composer [data-ctl]'))
            .filter(function (b) { return /send/i.test(b.getAttribute('data-ctl')||''); })[0];
          if (!send) return { err: "no Send control" };
          if (send.disabled) return { err: "the Send control is disabled" };
          send.click();
          var w = document.querySelector('#deckHost .holo-working');
          var s2 = Array.prototype.slice.call(
            document.querySelectorAll('.composer [data-ctl]'))
            .filter(function (b) { return /send/i.test(b.getAttribute('data-ctl')||''); })[0];
          return { err: "", working: w ? (w.innerText||"").trim() : "",
                   sendWhileWorking: s2 ? (s2.innerText||"").trim() : null };
        })()`, returnByValue: true }, sessionId);
      const sent = (sentR && sentR.result && sentR.result.value) || {};
      let outcome = null;
      const aDeadline = Date.now() + 60000;
      while (Date.now() < aDeadline) {
        const r = await cdp.send("Runtime.evaluate", {
          expression: `(function () {
            var notes = Array.prototype.slice.call(
              document.querySelectorAll('#deckHost .holo-outcome'));
            var n = notes[notes.length - 1];
            if (!n) return null;
            var r = n.getBoundingClientRect();
            var opts = Array.prototype.slice.call(
              document.querySelectorAll('.composer .holo-intent .iopt'));
            var chips = Array.prototype.slice.call(
              document.querySelectorAll('#deckHost .turn.holo:last-child .chip-file'))
              .map(function (c) { return (c.innerText||"").trim(); });
            return { cls: n.className, text: (n.innerText||"").trim(),
                     w: Math.round(r.width), h: Math.round(r.height),
                     pressed: opts.map(function (o) { return o.getAttribute('aria-pressed'); }),
                     chips: chips };
          })()`, returnByValue: true }, sessionId);
        const v = r && r.result && r.result.value;
        if (v) { outcome = v; break; }
        await sleep(300);
      }
      want.ask = { question: QUESTION, ctl: ctl, sent: sent, outcome: outcome };
      // leave the composer as it was found.
      await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var ta = document.querySelector('[data-holo=composer]');
          if (ta) { ta.value = ""; ta.dispatchEvent(new Event("input", { bubbles: true })); }
        })()`, returnByValue: true }, sessionId);
    }
    // 4. …and back. The board must come back exactly as it was — the whole
    //    point of one control and one frame.
    let boardM = null;
    if (!flowErr) {
      await cdp.send("Runtime.evaluate", {
        expression: `(function () {
          var b = document.getElementById("holodeckBtn");
          if (b) b.click();
        })()`, returnByValue: true }, sessionId);
      await sleep(400);
      const r2 = await cdp.send("Runtime.evaluate",
        { expression: HOLODECK_PROBE, returnByValue: true }, sessionId);
      boardM = (r2 && r2.result && r2.result.value) || null;
      let bshot = "";
      try {
        const png = await cdp.send("Page.captureScreenshot",
          { format: "png", captureBeyondViewport: true }, sessionId);
        bshot = path.join(OUT, "holodeck-back-on-board.png");
        fs.writeFileSync(bshot, Buffer.from(png.data, "base64"));
      } catch (e) { /* the deck shot is the one that matters */ }
      if (bshot) want.backScreenshot = bshot;
    }
    const failures = flowErr ? [flowErr].concat(judgeHolodeck(deckM, boardM, want))
                             : judgeHolodeck(deckM, boardM, want);
    holodeckCheck = { want: want, measured: deckM, backOnBoard: boardM,
                      failures: failures, screenshot: hshot,
                      ok: failures.length === 0 };
    fs.writeFileSync(path.join(OUT, "holodeck-check.json"),
      JSON.stringify(holodeckCheck, null, 2) + "\n");
  }

  // ── ACT (optional, --handoff-check): THE SEND-TO-ALIGN BOX ───────────────
  // The captain's last screen before a Mission exists. It is driven through
  // the real controls — ⬡ HOLODECK, the archived program in the list, ▶ Send
  // to Align — against a real daemon reading a real planted room, and NO
  // WORKER IS SPAWNED anywhere on that path (`holodeck_open` warm-restarts
  // from disk and `promote` is a read).
  let handoffCheck = null;
  if (HANDOFF_CHECK_FILE && ok) {
    let want = {};
    try {
      want = JSON.parse(fs.readFileSync(HANDOFF_CHECK_FILE, "utf8"));
    } catch (e) {
      throw new InfraError("could not read --handoff-check file " +
        HANDOFF_CHECK_FILE + ": " + e.message);
    }
    // THE WINDOW IS THE POINT. 677px is the height that produced S128's D1 on
    // a 1440x900 screen with Chrome's own chrome taken off; measuring this
    // dialog in a 1000px test window would hide the very defect class.
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: want.viewportW || 1440, height: want.viewportH || 677,
        deviceScaleFactor: 1, mobile: false }, sessionId);
    await sleep(250);
    let flowErr = "";
    const step = async (expr) => {
      if (flowErr) return;
      const r = await cdp.send("Runtime.evaluate",
        { expression: expr, returnByValue: true }, sessionId);
      flowErr = (r && r.result && r.result.value) || "";
    };
    const waitFor = async (expr, ms, what) => {
      if (flowErr) return;
      const d = Date.now() + ms;
      while (Date.now() < d) {
        const r = await cdp.send("Runtime.evaluate",
          { expression: expr, returnByValue: true }, sessionId);
        if (r && r.result && r.result.value) return;
        await sleep(200);
      }
      flowErr = what;
    };
    // S171 — the gate as it was at each moment of the walk, measured off the
    // real bar. `gateNone` is before he presses anything, `gateRunning` is the
    // wait, `gateReady` is the moment it becomes a send button.
    let gateNone = null, gateRunning = null, gateReady = null,
        gateAfterTurn = null, gateClickBlocked = "", gateFailed = null;
    const gateShots = {};
    // He backs out of the hand-off with the control the dialog gives him.
    const closeDialog = async () => {
      await step(`(function () {
        if (!document.querySelector("[data-holo=handoff-brief]")) return "";
        var cancel = Array.prototype.slice.call(
          document.querySelectorAll(".modal-foot button"))
          .filter(function (n) { return /cancel/i.test(n.textContent || ""); })[0];
        if (!cancel) return "no Cancel control to close the hand-off dialog";
        cancel.click();
        return "";
      })()`);
      await waitFor(`!document.querySelector("[data-holo=handoff-brief]")`,
        10000, "the hand-off dialog would not close");
    };
    const gateProbe = async () => {
      const r = await cdp.send("Runtime.evaluate",
        { expression: GATE_PROBE, returnByValue: true }, sessionId);
      return (r && r.result && r.result.value) || null;
    };
    // ONE JOURNEY, RUN TWICE. Everything from the band's ⬡ HOLODECK button to
    // the open dialog is a closure, because S170's proof is that the captain
    // can WALK AWAY — and the only way a browser can show that is to leave and
    // come back, through the real controls, on a page that has been RELOADED.
    const openTheDialog = async () => {
      await step(`(function () {
        var b = document.getElementById("holodeckBtn");
        if (!b) return "no ⬡ HOLODECK control in the band";
        if (b.disabled) return "the ⬡ HOLODECK control is disabled";
        b.click();
        return "";
      })()`);
      // ON THE FIRST WALK the room is ARCHIVED (`.prog.ondisk`) and picking it
      // up is a WARM RESTART: no session resumed, no engine contacted
      // (actions.holodeck_open). ON THE SECOND — after the reload — the daemon
      // is still holding that session, so the same room is a LIVE program and
      // `.ondisk` is gone from it. Both are `.prog`, and demanding `.ondisk`
      // twice is how this rig spent a run reporting "the planted program never
      // appeared" about a program that was right there.
      await waitFor(`document.querySelectorAll(".prog").length > 0`, 20000,
        "the planted program never appeared in the deck's program list");
      await step(`(function () {
        var row = document.querySelector(".prog.ondisk")
                  || document.querySelector(".prog");
        if (!row) return "no program on the deck to open";
        row.click();
        return "";
      })()`);
      await waitFor(`(function () {
        var bar = document.querySelector(".holo-handoff");
        var b = bar && bar.querySelector("[data-holo=handoff-send]");
        return !!b;
      })()`, 30000,
        "the hand-off bar never offered a send control on the opened program");
      // ── S171 — THE GATE, WALKED THE WAY HE WALKS IT ─────────────────────
      // ▶ SEND TO ALIGN is a wait now, and its label, its disabled state and
      // what it does are the DAEMON's `derive` block. So the walk BRANCHES on
      // what the bar is currently showing — which is also what makes the
      // second walk (after the reload) a different and harder journey: the
      // answer is already on disk, so the gate is READY and there is no second
      // wait to sit through.
      const gateNow = async () => {
        const r = await cdp.send("Runtime.evaluate", { returnByValue: true,
          expression: `(function () {
            var bar = document.querySelector(".holo-handoff");
            return bar ? (bar.getAttribute("data-gate") || "") : "";
          })()` }, sessionId);
        return (r && r.result && r.result.value) || "";
      };
      const press = async (which, what) => {
        await step(`(function () {
          var bar = document.querySelector(".holo-handoff");
          var b = bar && bar.querySelector("[data-holo=${which}]");
          if (!b) return ${JSON.stringify("there is no " + (want.expectGate ? "" : "") + which + " control on the hand-off bar (" + what + ")")};
          if (b.disabled) return "the " + ${JSON.stringify(which)} +
            " control is disabled at the moment the rig needed it — gate: " +
            (bar.getAttribute("data-gate") || "?");
          b.click();
          return "";
        })()`);
      };

      let g = await gateNow();
      if (want.expectGate && g === "none") {
        gateNone = gateNone || await gateProbe();
        await press("handoff-send", "press GENERATE");
        await waitFor(`(function () {
          var bar = document.querySelector(".holo-handoff");
          return !!bar && (bar.getAttribute("data-gate") || "") === "running";
        })()`, 30000,
          "pressing the gate never put it into its RUNNING state — either " +
          "the click started no pass, or the deck is not rendering the one " +
          "the daemon reported");
        g = "running";
        if (!gateRunning) {
          gateRunning = await gateProbe();
          gateShots.running = await shoot("gate-running.png");
          // AND THE DISABLED CONTROL IS ACTUALLY DEAD. Not styled as though
          // it is: clicked, at its own centre, and the dialog must NOT open.
          // A control that only LOOKS disabled is this round's own defect
          // class one surface over.
          const bl = await cdp.send("Runtime.evaluate", { returnByValue: true,
            expression: `(function () {
              var bar = document.querySelector(".holo-handoff");
              var b = bar && bar.querySelector("[data-holo=handoff-send]");
              if (!b) return "the send control vanished mid-wait";
              var r = b.getBoundingClientRect();
              var at = document.elementFromPoint(r.left + r.width / 2,
                                                 r.top + r.height / 2);
              if (at) at.click();
              b.click();
              if (document.querySelector("[data-holo=handoff-brief]")) {
                return "clicking the DISABLED generating control opened the " +
                       "hand-off dialog — it is styled disabled, not disabled";
              }
              return "";
            })()` }, sessionId);
          gateClickBlocked = (bl && bl.result && bl.result.value) || "";
          if (gateClickBlocked) flowErr = flowErr || gateClickBlocked;
        }
      }
      if (g === "running" && want.expectDeriveRunning) {
        // ── S172: RE-ROUTED, AND WHAT IT NOW PROVES IS SMALLER. SAY SO. ────
        //
        // This used to press `handoff-skip` — `Send without the change list` —
        // which was the ONLY control that opened this dialog mid-pass. THE
        // CAPTAIN DELETED THAT CONTROL: *"we don't need the send without
        // change list one."*
        //
        // The proofs it carried are NOT dropped. The dialog is opened here by
        // calling the deck's own `holoPromote` — the exact function the hatch's
        // click handler called, no rig-built dialog and no faked state — so the
        // running band, the walk-away sentence, the mid-pass typing guarantee
        // and the reload are all still measured in a real browser against the
        // real daemon.
        //
        // WHAT THIS LEG NO LONGER PROVES, and it must not be read as if it
        // does: that a CAPTAIN CAN REACH this state. He cannot. With the hatch
        // gone the deck offers no door into the dialog while a pass runs, and
        // `judgeGate` asserts exactly that (`dialogOpen` must be false at
        // `running`, and the hatch must be absent). The landing machinery is
        // kept because a cancel control — the honest answer if a hang is ever
        // observed — would put a door back, and this is what keeps it safe.
        await step(`(function () {
          if (typeof holoPromote !== "function") {
            return "the deck has no holoPromote — this leg cannot open the " +
                   "dialog mid-pass and is measuring nothing";
          }
          var p = holoActive();
          if (!p || !p.sessionId) return "no active program on the deck";
          holoPromote(p.sessionId);
          return "";
        })()`);
      } else {
        if (g === "running") {
          await waitFor(`(function () {
            var bar = document.querySelector(".holo-handoff");
            if (!bar) return false;
            return (bar.getAttribute("data-gate") || "") !== "running";
          })()`, 180000,
            "the gate never left its RUNNING state — the pass never " +
            "answered, or the deck never asked the daemon again");
        }
        if (want.expectGate) {
          /* S172 — A PASS THAT DID NOT ANSWER IS ITS OWN GATE STATE, and it
             is the one the captain's screenshot was taken in. It is also the
             state that has to carry the road through now that the hatch is
             gone, so it is measured rather than assumed. */
          if (await gateNow() === "failed") {
            gateFailed = gateFailed || await gateProbe();
          } else {
            gateReady = gateReady || await gateProbe();
          }
        }
        await press("handoff-send", "press SEND TO ALIGN");
      }
      await waitFor(`!!document.querySelector("[data-holo=handoff-brief]")`,
        30000, "the SEND TO ALIGN dialog never opened");
    };

    const probe = async () => {
      await sleep(400);   // one layout pass on the opened dialog
      if (flowErr) return null;
      const r = await cdp.send("Runtime.evaluate",
        { expression: HANDOFF_PROBE, returnByValue: true }, sessionId);
      return (r && r.result && r.result.value) || null;
    };
    const shoot = async (name) => {
      try {
        const png = await cdp.send("Page.captureScreenshot",
          { format: "png" }, sessionId);   // the VIEWPORT, not the document
        const f = path.join(OUT, name);
        fs.writeFileSync(f, Buffer.from(png.data, "base64"));
        return f;
      } catch (e) {
        cdp.pageErrors.push(name + " screenshot failed: " + e.message);
        return "";
      }
    };

    await openTheDialog();

    // ── PHASE 1 (optional): THE WAIT, AND THE PROMISE THAT HE MAY LEAVE ────
    // The daemon answers `promote` immediately — a spinner blocking the dialog
    // would be a hand-off held up by a verification step, which is worse than
    // the defect — so the RUNNING band is what he is looking at for the first
    // 154–220s, and it is the surface that has to say he can close this.
    let runningM = null, rshot = "", typedInto = "";
    if (want.expectDeriveRunning) {
      await waitFor(`(function () {
        var n = document.querySelector("[data-holo=handoff-derive]");
        return !!(n && n.getAttribute("data-state") === "running");
      })()`, 20000,
        "the derivation band never reached its RUNNING state — either the " +
        "daemon did not start a pass or the dialog does not show one");
      runningM = await probe();
      rshot = await shoot("handoff-running.png");
      if (!flowErr) {
        // WHAT THE RUNNING PHASE IS NOT JUDGED ON: THE CHANGE LIST. It has
        // not landed — that is the whole point of this phase — so the brief is
        // shorter, has no change section, and the line above it honestly does
        // not name one. Demanding any of that here is the rig failing itself,
        // and it cost two calibration runs reporting `derive-never-asks` and
        // `no-change-list` on the wrong sentence. `hintForbids` STAYS: nothing
        // may overclaim at any moment. What this phase DOES judge is the
        // running band, the box being on screen, and how much of it he can
        // read while he waits.
        const rf = judgeHandoff(runningM, Object.assign({}, want, {
          expectDeriveDone: false, hintNames: [], sections: [],
          minLines: 0,
          minLinesShown: want.minLinesShownRunning != null
            ? want.minLinesShownRunning : want.minLinesShown }));
        if (rf.length) flowErr = "while the pass was running: " + rf.join(" | ");
      }
    }

    // ── PHASE 1b (optional): HE TYPES WHILE IT IS STILL RUNNING ───────────
    // FL-013 ONE DIALOG OVER. When the pass lands the daemon has redrafted the
    // brief WITH the change list in it, and putting that in the box is the
    // right move — UNLESS he has touched it, in which case it is destroying
    // what a human wrote. Typed through the REAL `input` event, because that
    // is what the product listens on.
    if (want.typeWhileWaiting && !flowErr) {
      await step(`(function () {
        var t = document.querySelector("[data-holo=handoff-brief]");
        if (!t) return "no brief box to type into";
        t.value = ${JSON.stringify(want.typeWhileWaiting)}
                  + String.fromCharCode(10) + t.value;
        t.dispatchEvent(new Event("input", { bubbles: true }));
        if (t.value.indexOf(${JSON.stringify(want.typeWhileWaiting)}) === -1) {
          return "the rig typed into the brief box and the text did not stick";
        }
        return "";
      })()`);
      const tr = await cdp.send("Runtime.evaluate", { returnByValue: true,
        expression: `(document.querySelector("[data-holo=handoff-brief]")||{}).value || ""` },
        sessionId);
      typedInto = ((tr && tr.result && tr.result.value) || "").slice(0, 400);
    }

    // ── PHASE 2 (optional): HE WALKED AWAY, AND THE PAGE WAS RELOADED ──────
    // THE HARDEST HALF, AND THE ONE NO HARNESS CAN FAKE. A reload throws away
    // every byte of client state — the dialog, the draft, the poll, the timer.
    // If the wait survives it, it survives because the DAEMON owns it. He then
    // walks the same controls again and must find the finished brief, with no
    // second wait.
    if (want.reloadProof && !flowErr) {
      try {
        await cdp.send("Page.reload", { ignoreCache: false }, sessionId);
      } catch (e) {
        flowErr = "could not reload the page: " + e.message;
      }
      await waitFor(`!!document.getElementById("holodeckBtn")`, 30000,
        "the board never came back after the reload");
      await sleep(400);
      await openTheDialog();
    }

    if (want.expectDeriveDone) {
      await waitFor(`(function () {
        var n = document.querySelector("[data-holo=handoff-derive]");
        if (!n) return false;
        var st = n.getAttribute("data-state") || "";
        return st === "done" || st === "failed";
      })()`, 120000,
        "the derivation band never settled — it stayed on its RUNNING state, " +
        "so either the pass never answered or the dialog never asked again");
    }
    const hm = await probe();
    const ashot = await shoot("handoff.png");
    // S171 — AND THE GATE AS IT IS ONCE THE PASS HAS LANDED, WITH THE DIALOG
    // OUT OF THE WAY. It is probed here rather than in the walk because the
    // escape-hatch road enters the dialog WHILE the pass runs — which is the
    // whole point of that road, and means the walk never sees "ready".
    //
    // THE DIALOG IS CLOSED FIRST, and that is not tidiness: the overlay COVERS
    // the deck, so `elementFromPoint` over the bar returns the overlay and
    // every hit-test on it reads false. Measured on the first run of this
    // phase — the rig accused the product of an unclickable ▶ Send to Align
    // that was simply behind the dialog the rig itself had opened.
    if (want.expectGate && !flowErr) {
      await closeDialog();
      await sleep(300);
      if (want.expectGateFailed) {
        gateFailed = await gateProbe();
        gateShots.failed = await shoot("gate-failed.png");
      } else {
        gateReady = await gateProbe();
        gateShots.ready = await shoot("gate-ready.png");
      }
    }
    // THE RUNNING CLAIM WAS ALREADY JUDGED, in phase 1, against the band as it
    // was THEN. Re-judging it here would demand a band that is running and
    // settled at the same time — the rig failing itself, which is the exact
    // shape of "reassuring output proving nothing" this file keeps a note
    // about.
    // ── PHASE 3 (optional): HE KEEPS CHATTING WITH THE COMPOSER ───────────
    // THE CAPTAIN'S OWN WORDS FOR THIS: *"a gated wait that retriggers behind
    // a wait guard if you keep chatting with the composer."* A change list
    // derived from a mockup he has since redrawn is worse than none — it
    // describes a drawing that no longer exists. The invalidation is a FACT
    // (the daemon fingerprints `mockup.html`), and this is the only place it
    // is measured END TO END: real dialog closed, real composer, real turn,
    // real bar.
    if (want.expectInvalidation && !flowErr) {
      await step(`(function () {
        var ta = document.querySelector('[data-holo=composer]');
        if (!ta) return "no composer on the deck";
        ta.value = "Move the toolbar buttons to the right.";
        ta.dispatchEvent(new Event("input", { bubbles: true }));
        var send = Array.prototype.slice.call(
          document.querySelectorAll('.composer [data-ctl]'))
          .filter(function (b) { return /send/i.test(b.getAttribute('data-ctl')||''); })[0];
        if (!send) return "no Send control on the composer";
        if (send.disabled) return "the composer's Send control is disabled";
        send.click();
        return "";
      })()`);
      await waitFor(`(function () {
        var bar = document.querySelector(".holo-handoff");
        if (!bar) return false;
        if (document.querySelector(".composer .holo-working")) return false;
        return (bar.getAttribute("data-gate") || "") !== "";
      })()`, 120000, "the composer turn never settled on the deck");
      await sleep(600);
      gateAfterTurn = await gateProbe();
      gateShots.afterTurn = await shoot("gate-after-turn.png");
    }

    const finalWant = Object.assign({}, want, { expectDeriveRunning: false });
    const failures = flowErr ? [flowErr] : judgeHandoff(hm, finalWant);
    if (want.expectGate && !flowErr) {
      judgeGate({ none: gateNone, running: gateRunning, ready: gateReady,
                  failed: gateFailed,
                  afterTurn: gateAfterTurn }, want).forEach((x) =>
        failures.push(x));
    }
    handoffCheck = { want: want, measured: hm, measuredRunning: runningM,
                     runningScreenshot: rshot, typedInto: typedInto,
                     gate: { none: gateNone, running: gateRunning,
                             ready: gateReady, failed: gateFailed,
                             afterTurn: gateAfterTurn,
                             clickBlocked: gateClickBlocked },
                     gateScreenshots: gateShots,
                     failures: failures,
                     screenshot: ashot, ok: failures.length === 0 };
    fs.writeFileSync(path.join(OUT, "handoff-check.json"),
      JSON.stringify(handoffCheck, null, 2) + "\n");
  }

  // Was the app served WHOLE? A same-origin stylesheet that did not load, or an
  // absent --lcars-* token layer, means the browser was shown a DEGRADED app —
  // and a tester comparing screenshots is then looking at a phantom.
  const deadSheets = (last.stylesheets || []).filter((s) => !s.loaded);
  const tokensPresent = !!last.tokenProbe;
  const servedComplete = deadSheets.length === 0 && tokensPresent;

  // snapshot the budget, then filter: what the run FORGAVE is the difference,
  // and the readout below names only what it actually forgave (a rig run that
  // never drove the collision must not claim a 409 was expected).
  const budget = { dup: RIG_PROVOKED.duplicateStart,
                   dead: RIG_PROVOKED.deadFirstTurn };
  const unexpectedErrors = cdp.pageErrors.filter((e) => !isBenignPageError(e));
  const benignKinds = ["favicon 404", "probeWrites 400"];
  if (budget.dup > RIG_PROVOKED.duplicateStart) {
    benignKinds.push("the rig's own duplicate-name 409");
  }
  if (budget.dead > RIG_PROVOKED.deadFirstTurn) {
    benignKinds.push("the rig's own dead-turn 502");
  }

  const result = {
    ok: ok,
    servedComplete: servedComplete,
    expected: EXPECT,
    cards: last.visibleCards,
    cardsInDom: last.cards,
    columns: last.columns,
    status: last.status,
    cardText: last.cardText,
    bodyText: last.bodyText,
    stylesheets: last.stylesheets || [],
    tokenProbe: last.tokenProbe || "",
    pageErrors: cdp.pageErrors,
    pageErrorsUnexpected: unexpectedErrors,
    chrome: verInfo.Browser,
    url: URL_,
    screenshot: shot,
    legendCheck: legendCheck,
    ghLinkCheck: ghLinkCheck,
    consoleCheck: consoleCheck,
    holodeckCheck: holodeckCheck,
    handoffCheck: handoffCheck,
  };
  fs.writeFileSync(path.join(OUT, "result.json"), JSON.stringify(result, null, 2) + "\n");

  try { await cdp.send("Target.closeTarget", { targetId }); } catch (e) { /* going away */ }
  try { cdp.ws.close(); } catch (e) { /* ditto */ }

  if (ok) {
    console.log("  real Chrome painted " + last.visibleCards + " card node(s), " +
      last.columns + " column(s); status line: " + JSON.stringify(last.status));
    // D3 — page errors are shown on failure AND on success. An unexpected
    // console error slipping past a green run is exactly the false comfort this
    // rig exists to remove, and "the README says the list is worth a look" is
    // not the same as telling anyone to look.
    const benignCount = cdp.pageErrors.length - unexpectedErrors.length;
    console.log("  page errors: " + benignCount + " known-benign (" +
      benignKinds.join(", ") + "), " + unexpectedErrors.length + " unexpected");
    if (unexpectedErrors.length) {
      console.log("\x1b[33m  ⚠ " + unexpectedErrors.length + " UNEXPECTED PAGE " +
        "ERROR(S) ON A GREEN RUN — the board painted, but the page is not clean:\x1b[0m");
      unexpectedErrors.slice(0, 8).forEach((e) => console.log("      " + e));
      if (unexpectedErrors.length > 8) {
        console.log("      … " + (unexpectedErrors.length - 8) + " more in result.json");
      }
    }
  }
  if (ok && !servedComplete) {
    console.error("\x1b[31m  THE APP WAS SERVED INCOMPLETE.\x1b[0m The board painted, but what the");
    console.error("  browser was given is NOT the shipping app — so anything you conclude");
    console.error("  from the screenshot about how it LOOKS is about a phantom.");
    deadSheets.forEach((s) => console.error("    stylesheet never loaded: " + s.href));
    if (!tokensPresent) {
      console.error("    the shared --lcars-* token layer (ADR-007) is ABSENT on :root —");
      console.error("    every colour on this page fell back to board.css's var() defaults.");
    }
    console.error("  If LCARS_BROWSER_WEB_DIR points at a copy, the daemon resolves the");
    console.error("  shared sheet as <web-dir>/../docs/lcars.css (server.py _SHARED_CSS).");
  }
  if (!ok) {
    console.error("  THE BOARD DID NOT PAINT.");
    console.error("    expected >= " + EXPECT + " visible .card node(s); saw " +
      last.visibleCards + " visible of " + last.cards + " in the DOM");
    console.error("    status line: " + JSON.stringify(last.status));
    console.error("    body text  : " + JSON.stringify(last.bodyText.slice(0, 200)));
    if (cdp.pageErrors.length) {
      console.error("    page errors:");
      cdp.pageErrors.slice(0, 8).forEach((e) => console.error("      " + e));
    }
  }
  if (legendCheck) {
    if (legendCheck.ok) {
      console.log("  legend: every named swatch PAINTS in the real DOM —");
      (legendCheck.measured.swatches || []).forEach((s) => {
        console.log("    " + JSON.stringify(s.label) + ": " + s.background +
          " on a " + Math.round(s.box.w) + "×" + Math.round(s.box.h) + "px box, " +
          s.contrast.toFixed(1) + ":1 against " + JSON.stringify(s.backdrop));
      });
    } else {
      console.error("\x1b[31m  A LEGEND SWATCH IS NOT ON THE SCREEN IN A REAL BROWSER.\x1b[0m");
      legendCheck.failures.forEach((f) => console.error("    ✗ " + f));
      console.error("    tokens on :root: " + JSON.stringify(legendCheck.measured.tokens));
      console.error("    screenshot: " + legendCheck.screenshot);
    }
  }
  if (ghLinkCheck) {
    if (ghLinkCheck.ok) {
      console.log("  github links: every measured link RESOLVES to " +
        JSON.stringify(ghLinkCheck.want.host || "github.com") + " —");
      (ghLinkCheck.measured.links || []).forEach((l) => {
        console.log("    " + l.where + ": " + l.href);
      });
      console.log("    board payload meta: " +
        JSON.stringify(ghLinkCheck.measured.payloadMeta));
    } else {
      console.error("\x1b[31m  A \"VIEW ON GITHUB\" LINK POINTS AT THE WRONG FORGE.\x1b[0m");
      ghLinkCheck.failures.forEach((f) => console.error("    ✗ " + f));
      console.error("    measured: " +
        JSON.stringify(ghLinkCheck.measured.links));
      console.error("    board payload meta: " +
        JSON.stringify(ghLinkCheck.measured.payloadMeta));
      console.error("    screenshot: " + ghLinkCheck.screenshot);
    }
  }
  if (consoleCheck) {
    const q = (consoleCheck.measured && consoleCheck.measured.quiet) || null;
    if (consoleCheck.ok) {
      console.log("  file console: the quiet base-freshness line is VISIBLE in the " +
        "real DOM — " + Math.round(q.box.w) + "×" + Math.round(q.box.h) + "px at " +
        q.fontSize + ", colour " + q.color + " @ opacity " + q.opacity + ", " +
        q.contrast.toFixed(1) + ":1 against " + JSON.stringify(consoleCheck.measured.wrapBackground) +
        " (--lcars-amber is " + consoleCheck.measured.amber + ")");
      console.log("    it says: " + JSON.stringify(q.text.slice(0, 120)));
    } else {
      console.error("\x1b[31m  THE FILE CONSOLE'S PRE-FLIGHT IS WRONG IN A REAL BROWSER.\x1b[0m");
      consoleCheck.failures.forEach((f) => console.error("    ✗ " + f));
      console.error("    measured: " + JSON.stringify(consoleCheck.measured).slice(0, 600));
      console.error("    screenshot: " + consoleCheck.screenshot);
    }
  }
  /* ── S126 fix round 1b: THE HOLODECK CHECK REPORTS ITS OWN REASON ─────────
     Every other check above prints `✗ <reason>` when it fails; this one printed
     NOTHING and left by the "did not paint" code, so smoke.sh accused a board
     that had painted perfectly and the real reason sat unread in
     holodeck-check.json. The N4/N5/N6 PRECONDITION is printed on the way past
     too — whether the scripted worker's first design turn actually died is the
     difference between four proofs and four empty rooms, and it is exactly what
     nobody could see for two whole calibration runs. */
  if (holodeckCheck) {
    const hm = holodeckCheck.measured || {};
    const hn4 = (holodeckCheck.want && holodeckCheck.want.n4) || null;
    const precondition = hn4
      ? (hn4.died
          ? ("the first design turn DIED as scripted (retry pressed: " +
             hn4.retried + ", conversation recovered: " + hn4.recovered + ")")
          : "THE FIRST DESIGN TURN NEVER DIED — the N4/N5/N6/one-voice half of " +
            "this check measured an empty room")
      : "the journey was not driven";
    if (holodeckCheck.ok) {
      console.log("  holodeck: the deck REPLACED the board in the real DOM — panes " +
        JSON.stringify(hm.paneClasses) + " at " + JSON.stringify(hm.paneWidths) +
        "px, preview " + JSON.stringify(hm.iframeSrc) + " sandboxed " +
        JSON.stringify(hm.iframeSandbox) + ", --holo-grid " +
        JSON.stringify(hm.holoGrid) + ", " + hm.turnCount + " turn(s)");
      // The furniture is named too, or the readout reads as if the deck had
      // three children and the next person to change it inherits this same
      // stale expectation.
      console.log("    furniture: handle " +
        (hm.splitM ? hm.splitM.w + "×" + hm.splitM.h + "px at index " + hm.splitM.index
                   : "(none)") +
        ", drawer scrim " +
        (hm.scrimM ? hm.scrimM.display + "/" + hm.scrimM.w + "px (drawer " +
                     (hm.drawerOpen ? "open" : "shut") + ")" : "(none)") +
        "; deck children " + JSON.stringify(hm.deckChildClasses));
      console.log("    precondition: " + precondition);
    } else {
      console.error("\x1b[31m  THE HOLODECK IS WRONG IN A REAL BROWSER.\x1b[0m The board " +
        "painted; the deck did not measure up:");
      holodeckCheck.failures.forEach((f) => console.error("    ✗ " + f));
      console.error("    precondition: " + precondition);
      console.error("    measured: panes " + JSON.stringify(hm.paneClasses) +
        " at " + JSON.stringify(hm.paneWidths) + "px, deck children " +
        JSON.stringify(hm.deckChildClasses) + ", handle " +
        JSON.stringify(hm.splitM) + ", scrim " + JSON.stringify(hm.scrimM) +
        ", preview " + JSON.stringify(hm.iframeSrc) + ", sandbox " +
        JSON.stringify(hm.iframeSandbox) + ", --holo-grid " +
        JSON.stringify(hm.holoGrid));
      console.error("    full measurements: " + path.join(OUT, "holodeck-check.json"));
      console.error("    screenshot: " + (holodeckCheck.screenshot || "(none)"));
    }
  }
  if (handoffCheck) {
    const am = handoffCheck.measured || {};
    const ab = am.brief || {};
    if (handoffCheck.ok) {
      console.log("  send to align: the pre-drafted brief is a " + ab.lines +
        "-line draft in a box showing " + ab.linesShown + " lines at once (" +
        ab.clientH + "px) at " + (ab.box ? ab.box.top + "→" + ab.box.bottom : "?") +
        "px of a " + am.viewportH + "px window; sections " +
        JSON.stringify(ab.headings));
      console.log("    it says what it is made of: " +
        JSON.stringify((am.hint && am.hint.text) || ""));
      console.log("    ▦ File Mission clickable: " +
        !!(am.fileBtn && am.fileBtn.hit) + "; open-questions cue clickable: " +
        !!(am.qcue && am.qcue.hit));
      const G = handoffCheck.gate || {};
      if (G.none || G.running || G.ready) {
        const one = (g) => g ? (g.gate + " · " +
          JSON.stringify(((g.send || {}).text || "").slice(0, 34)) +
          (((g.send || {}).disabled) ? " DISABLED" : " live") +
          (g.spinner ? " +bars" : "") +
          (g.skip ? " +hatch" : "")) : "(not measured)";
        console.log("    the gate: " + one(G.none) + "  →  " + one(G.running) +
          "  →  " + one(G.ready));
        if (G.afterTurn) {
          console.log("    after one more composer turn: " + one(G.afterTurn));
        }
      }
    } else {
      console.error("\x1b[31m  THE SEND-TO-ALIGN BOX IS WRONG IN A REAL BROWSER.\x1b[0m " +
        "The board painted; the dialog the captain files from did not measure up:");
      handoffCheck.failures.forEach((f) => console.error("    ✗ " + f));
      console.error("    measured: " + JSON.stringify({
        viewportH: am.viewportH, brief: ab.box, lines: ab.lines,
        linesShown: ab.linesShown, headings: ab.headings,
        fileBtn: am.fileBtn && am.fileBtn.box }));
      console.error("    full measurements: " + path.join(OUT, "handoff-check.json"));
      console.error("    screenshot: " + (handoffCheck.screenshot || "(none)"));
    }
  }
  if (!ok) return EXIT_NOT_PAINTED;
  if (legendCheck && !legendCheck.ok) return EXIT_NOT_PAINTED;
  if (ghLinkCheck && !ghLinkCheck.ok) return EXIT_NOT_PAINTED;
  if (consoleCheck && !consoleCheck.ok) return EXIT_NOT_PAINTED;
  if (holodeckCheck && !holodeckCheck.ok) return EXIT_HOLODECK;
  if (handoffCheck && !handoffCheck.ok) return EXIT_HANDOFF;
  return servedComplete ? EXIT_PAINTED : EXIT_DEGRADED;
}

main().then((code) => process.exit(code)).catch((err) => {
  // An InfraError is OUR failure, not the board's, and leaves by 77 — the rig
  // never accuses a board it could not even reach. Any other throw is also the
  // driver falling over rather than an observed blank page, so it goes the same
  // way: exit 1 is reserved for a board that was asked and did not paint.
  console.error("  cdp.js: " + (err instanceof InfraError ? "" : "unexpected driver failure: ") +
    err.message);
  try {
    fs.writeFileSync(path.join(OUT, "result.json"),
      JSON.stringify({ ok: false, infrastructure: true, error: err.message }, null, 2) + "\n");
  } catch (e) { /* out dir gone */ }
  process.exit(EXIT_INFRA);
});
