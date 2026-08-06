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
  if (!ok) return EXIT_NOT_PAINTED;
  if (legendCheck && !legendCheck.ok) return EXIT_NOT_PAINTED;
  if (ghLinkCheck && !ghLinkCheck.ok) return EXIT_NOT_PAINTED;
  if (consoleCheck && !consoleCheck.ok) return EXIT_NOT_PAINTED;
  if (holodeckCheck && !holodeckCheck.ok) return EXIT_HOLODECK;
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
