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

/* The two page errors a healthy run always produces. Documented in the README,
 * deliberate, and NOT defects — but everything outside this set is surfaced,
 * including on a green run (an unexpected console error passing silently is the
 * false comfort this rig is built against). */
function isBenignPageError(e) {
  if (/\/favicon\.ico/.test(e)) return true;            // the daemon serves none
  if (/\/api\/mission\b/.test(e) && /\b400\b/.test(e)) return true;  // probeWrites()
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

  // Was the app served WHOLE? A same-origin stylesheet that did not load, or an
  // absent --lcars-* token layer, means the browser was shown a DEGRADED app —
  // and a tester comparing screenshots is then looking at a phantom.
  const deadSheets = (last.stylesheets || []).filter((s) => !s.loaded);
  const tokensPresent = !!last.tokenProbe;
  const servedComplete = deadSheets.length === 0 && tokensPresent;

  const unexpectedErrors = cdp.pageErrors.filter((e) => !isBenignPageError(e));

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
    console.log("  page errors: " + benignCount + " known-benign (favicon 404, " +
      "probeWrites 400), " + unexpectedErrors.length + " unexpected");
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
  if (!ok) return EXIT_NOT_PAINTED;
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
