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
  var panes = view ? Array.prototype.slice.call(view.children) : [];
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
    paneClasses: panes.map(function (p) {
      return String(p.className || "").split(/\\s+/)[0];
    }),
    paneWidths: panes.map(function (p) { var b = box(p); return b ? Math.round(b.w) : 0; }),
    panesVisible: panes.map(function (p) { var b = box(p); return !!(b && b.visible); }),
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
  // D2 — three panes, laid out, in order, with real width.
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
  if (deckM.paneWidths.length === 3) {
    const ratio = deckM.paneWidths[1] / deckM.paneWidths[2];
    if (!(ratio > 0.95 && ratio < 1.45)) {
      f.push("chat:preview is " + ratio.toFixed(2) + ":1 — the mock says ~1.15:1");
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
    }
    // 5. two programs cannot share one room.
    if (want.collision) {
      if (want.collision.programs !== 1) {
        f.push("a second program with the SAME NAME created a second card ("
               + want.collision.programs + " on the deck) — both writing one "
               + "mockup.html, indistinguishable in the list");
      }
      if (!want.collision.errorText) {
        f.push("the duplicate name was refused with no message the captain "
               + "can read");
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
            var err = document.querySelector('.modal .errline');
            var out = { errorText: err && !err.hidden ? (err.innerText||"").trim() : "",
                        programs: 0 };
            var close = Array.prototype.slice.call(
              document.querySelectorAll('.modal [data-ctl], .modal button'))
              .filter(function (n) { return /cancel/i.test((n.textContent||"")); })[0];
            if (close) close.click();
            out.programs = document.querySelectorAll('.prog').length;
            return out;
          })()`, returnByValue: true }, sessionId);
        want.collision = (col && col.result && col.result.value) || null;
        await sleep(400);
      }
    }
    // 3. Poll the REAL DOM until the three panes and the preview iframe exist.
    let deckM = { onDeckClass: false, paneClasses: [], paneWidths: [],
                  panesVisible: [] };
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
  if (!ok) return EXIT_NOT_PAINTED;
  if (legendCheck && !legendCheck.ok) return EXIT_NOT_PAINTED;
  if (ghLinkCheck && !ghLinkCheck.ok) return EXIT_NOT_PAINTED;
  if (consoleCheck && !consoleCheck.ok) return EXIT_NOT_PAINTED;
  if (holodeckCheck && !holodeckCheck.ok) return EXIT_NOT_PAINTED;
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
