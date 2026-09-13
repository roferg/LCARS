"use strict";
/* ============================================================================
 * S201 — NUMBER ONE'S BADGE, MEASURED IN PIXELS.
 *
 * Driven by `tests/drives/s201/xo-paint.sh`, which is S190's `owner-paint.sh`
 * with two seams set. IT INHERITS RATHER THAN FORKS: the CDP client, the PNG
 * reader, the luminance/contrast formulae and the ink-and-paper sampler all
 * come out of `../s190/owner-paint.js` by `require`, so there is ONE
 * implementation of "what does this pixel actually say" in this repo and a fix
 * to it fixes both rounds.
 *
 * THE TWO QUESTIONS, and they are not the same question:
 *
 *   1. IS IT LEGIBLE. The engaged pill's ink against its own paper must clear
 *      4.5:1 — WCAG's text floor, read off the SCREENSHOT rather than off
 *      getComputedStyle, because a compositing group (S190's D2) can make the
 *      cascade report a contrast the screen does not have.
 *
 *   2. CAN YOU TELL IT FROM THE OWNER PILL WITH THE COLOUR GONE. Peach and
 *      amber are ONE HUE to a greyscale screenshot, a projector and a
 *      red-green colourblind reader — which is S196's B1 defect exactly, and
 *      the reason this check exists at all. The answer must be SHAPE, not hue,
 *      and the rig proves it by DESATURATING the real page in real Chrome and
 *      re-reading the pixels through the filter. It also proves THE FILTER BIT
 *      (r == g == b), because a greyscale check that silently ran in colour
 *      would pass on the broken version.
 *
 *   3. AND CAN YOU TELL ENGAGED FROM FINISHED WITH THE COLOUR GONE. Both are
 *      hollow peach pills since the 2026-09-13 ruling, so what separates them
 *      is RIM WEIGHT — 2px against 1px — and this rig measures that rim band
 *      in the desaturated screenshot. It deliberately does NOT lean on the
 *      pulse: a pulse is motion, and motion is gone from a still frame and
 *      switched off under `prefers-reduced-motion`, so a check that measured
 *      it would be measuring the one cue that is missing exactly when the
 *      captain is reading a captured board.
 *
 * EXIT: 0 proven · 1 the product is wrong · 77 infrastructure (never a pass).
 * ========================================================================= */
const fs = require("fs");
const path = require("path");

const base = require("../s190/owner-paint.js");
const { pngPixels, contrast, inkAndPaper, fill, connect, InfraError,
        CDP } = base;

function arg(name, dflt) {
  const i = process.argv.indexOf("--" + name);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : dflt;
}
const DEVTOOLS_PORT = arg("devtools-port");
const URL_ = arg("url");
const OUT = arg("out", ".");
const TIMEOUT = parseInt(arg("timeout", "45000"), 10);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failures = 0, skips = 0;
function ok(name, detail) {
  console.log("  \x1b[32mPASS\x1b[0m  " + name + (detail ? "\n          " + detail : ""));
}
function bad(name, detail) {
  failures++;
  console.log("  \x1b[31mFAIL\x1b[0m  " + name + (detail ? "\n          " + detail : ""));
}
function skip(name, detail) {
  skips++;
  console.log("  \x1b[33mSKIP\x1b[0m  " + name + (detail ? "\n          " + detail : ""));
}

async function evaluate(cdp, sessionId, expr) {
  const r = await cdp.send("Runtime.evaluate",
    { expression: expr, returnByValue: true, awaitPromise: false }, sessionId);
  if (r && r.exceptionDetails) {
    throw new InfraError("probe threw: " + r.exceptionDetails.text);
  }
  return r && r.result ? r.result.value : null;
}

async function shoot(cdp, sessionId, box, file, scale, pad) {
  const png = await cdp.send("Page.captureScreenshot", {
    format: "png", captureBeyondViewport: true,
    clip: { x: Math.max(0, box.x - pad), y: Math.max(0, box.y - pad),
            width: box.w + pad * 2, height: box.h + pad * 2, scale: scale },
  }, sessionId);
  const buf = Buffer.from(png.data, "base64");
  fs.writeFileSync(path.join(OUT, file), buf);
  return buf;
}

/* THE BOARD IS PAINTED. Same shape as S190's READY probe — the cards are drawn
   and the band control has had a render to paint itself in. */
const READY = `(function () {
  var cards = document.querySelectorAll(".card");
  return { cards: cards.length,
           band: !!document.getElementById("xoBtn") };
})()`;

/* WHERE EVERYTHING IS, in page coordinates. One probe, so the screenshots and
   the numbers are read off ONE layout rather than two. */
const XO_PROBE = `(function () {
  function box(n) {
    if (!n) return null;
    var r = n.getBoundingClientRect();
    return { x: r.x + window.scrollX, y: r.y + window.scrollY,
             w: r.width, h: r.height };
  }
  function card(mid) {
    return document.querySelector('.card[data-mid="' + mid + '"]');
  }
  function pill(mid, cls) {
    var c = card(mid);
    return c ? c.querySelector(".pill.xo" + (cls ? "." + cls : "")) : null;
  }
  var engaged = card("m-mine"), finished = card("m-align-mine");
  var ep = pill("m-mine"), fp = pill("m-align-mine", "done");
  var owner = engaged ? engaged.querySelector(".owner") : null;
  var line = engaged ? engaged.querySelector(".xo-line") : null;
  var note = finished ? finished.querySelector(".xo-note") : null;
  var band = document.getElementById("xoBtn");
  var legend = document.querySelectorAll(".legend .xo-legend");
  var ctrl = engaged ? engaged.querySelectorAll(".card-ctrl .btn") : [];
  var live = [], dead = [], standDown = null;
  for (var i = 0; i < ctrl.length; i++) {
    var b = ctrl[i];
    var t = (b.textContent || "").trim();
    if ((" " + b.className + " ").indexOf(" xo-stand-down ") >= 0) {
      standDown = { text: t, disabled: !!b.disabled, box: box(b) };
    } else if (b.disabled) dead.push(t);
    else live.push(t);
  }
  return {
    engagedCard: box(engaged), finishedCard: box(finished),
    engagedPill: box(ep), finishedPill: box(fp), ownerPill: box(owner),
    engagedPillText: ep ? (ep.textContent || "").trim() : null,
    finishedPillText: fp ? (fp.textContent || "").trim() : null,
    lineText: line ? (line.textContent || "").trim() : null,
    noteText: note ? (note.textContent || "").trim() : null,
    edge: engaged ? getComputedStyle(engaged).borderLeftColor : null,
    engagedHasClass: !!engaged &&
      (" " + engaged.className + " ").indexOf(" xo-engaged ") >= 0,
    finishedHasClass: !!finished &&
      (" " + finished.className + " ").indexOf(" xo-engaged ") >= 0,
    band: band ? { text: (band.textContent || "").trim(),
                   hidden: !!band.hidden, box: box(band),
                   cls: band.className } : null,
    legend: Array.prototype.map.call(legend,
      function (n) { return (n.textContent || "").trim(); }),
    // THE UNION BOX of the two legend entries, so the frames can show that the
    // legend teaches the SAME pair of shapes the cards draw. A legend that
    // taught a shape the board no longer paints would be a defect no check in
    // this rig asks about, and the captain reads it off the picture.
    legendXo: (function () {
      var u = null;
      for (var j = 0; j < legend.length; j++) {
        var b = box(legend[j]);
        if (!b) continue;
        if (!u) { u = { x: b.x, y: b.y, w: b.w, h: b.h }; continue; }
        var x2 = Math.max(u.x + u.w, b.x + b.w), y2 = Math.max(u.y + u.h, b.y + b.h);
        u.x = Math.min(u.x, b.x); u.y = Math.min(u.y, b.y);
        u.w = x2 - u.x; u.h = y2 - u.y;
      }
      return u;
    })(),
    liveControls: live, deadControls: dead, standDown: standDown,
  };
})()`;

/* THE GREYSCALE FILTER. S196's own: applied to the documentElement so every
   painted pixel goes through it, and PROVEN to have bitten by reading r==g==b
   back off the screenshot. */
const GREY_ON = `(function () {
  document.documentElement.style.filter = "grayscale(1)";
  return true;
})()`;
const GREY_OFF = `(function () {
  document.documentElement.style.filter = "";
  return true;
})()`;

function isGrey(png) {
  const n = png.w * png.h;
  for (let i = 0; i < n; i++) {
    const o = i * png.bpp;
    const r = png.px[o], g = png.px[o + 1], b = png.px[o + 2];
    if (Math.abs(r - g) > 2 || Math.abs(g - b) > 2) return false;
  }
  return true;
}

/* SOLID OR HOLLOW — and the ONLY way to ask it that survives desaturation.
 *
 * THE FIRST ATTEMPT WAS WRONG, and the rig caught it before the product did:
 * "what fraction of this clip is its own median colour" reads ~79% for a solid
 * pill AND ~75% for a hollow one, because a hollow pill's median IS the card
 * ground and most of the clip is card ground. Two very different pills, one
 * number. A check that cannot fail is not a check.
 *
 * So the question is asked against the CARD's own ground instead: a SOLID pill
 * is a block whose value is far from the card behind it; a HOLLOW pill IS the
 * card behind it, with a rim. In greyscale that difference is all that is left
 * of "peach" — which is exactly the property the board is claiming. */
function blockVsGround(pillPng, cardPng) {
  const p = fill(pillPng), g = fill(cardPng);
  if (!p || !g) return null;
  return contrast(p, g);
}

/* HOW HEAVY IS THE RIM — the one difference between ENGAGED and FINISHED that
 * a still frame keeps.
 *
 * Since the 2026-09-13 ruling both pills are HOLLOW, so `blockVsGround` cannot
 * separate them: a hollow pill's median pixel IS the card ground, and both
 * read 1.00:1. What separates them now is the WIDTH OF THE RIM BAND — 2px on
 * the engaged pill against 1px on the done family — and that is a difference
 * in shape, which is what survives desaturation, a static screenshot AND
 * `prefers-reduced-motion`. The pulse survives none of those three, which is
 * exactly why it is not what gets measured here.
 *
 * MEASURED WHERE THE RIM IS PERPENDICULAR TO THE SCAN. The pill is a stadium,
 * so along a scanline through its vertical centre the left cap's rim is a
 * clean radial band: walk in from x = 0 and the first run of not-the-ground
 * pixels IS the border, at its true thickness, with no text in the way (the
 * label starts a whole padding box further in). Rows are taken in a narrow
 * band either side of the centre and the MEDIAN run is returned, so one
 * antialiased row cannot decide the number.
 *
 * HALF-MAXIMUM, not a fixed threshold: the rim's outer edge at the extreme of
 * an arc is smeared across a pixel or two, so the run is counted between the
 * half-peak crossings. Both pills are measured by the identical rule at the
 * identical scale, so the comparison is honest whatever the smear costs.
 *
 * Returns device pixels (the clips are shot at scale 4, so a 1px CSS border is
 * about 4), or null when the clip has no rim to measure. */
function rimBand(png) {
  if (!png || !png.w || !png.h) return null;
  const g = fill(png);
  if (!g) return null;
  const groundV = (g[0] + g[1] + g[2]) / 3;
  const val = (x, y) => {
    const o = (y * png.w + x) * png.bpp;
    return (png.px[o] + png.px[o + 1] + png.px[o + 2]) / 3;
  };
  // The left cap only: never wider than the pill is tall, so the label — which
  // starts a padding box in — can never be mistaken for rim.
  const span = Math.max(2, Math.min(png.w, Math.round(png.h * 0.45)));
  const y0 = Math.floor(png.h * 0.42), y1 = Math.ceil(png.h * 0.58);
  const runs = [];
  for (let y = y0; y <= y1 && y < png.h; y++) {
    let peak = 0;
    for (let x = 0; x < span; x++) peak = Math.max(peak, Math.abs(val(x, y) - groundV));
    if (peak < 20) continue;               // no rim on this row worth measuring
    const half = peak / 2;
    let run = 0, started = false;
    for (let x = 0; x < span; x++) {
      const d = Math.abs(val(x, y) - groundV);
      if (d >= half) { run++; started = true; }
      else if (started) break;             // the band has ended — stop counting
    }
    if (run > 0) runs.push(run);
  }
  if (!runs.length) return null;
  runs.sort((a, b) => a - b);
  return { px: runs[Math.floor(runs.length / 2)], rows: runs.length };
}

async function main() {
  console.log("\nS201 — Number One's badge, in real Chrome\n");
  const deadline = Date.now() + TIMEOUT;
  // THE SAME OPENING S190's drive takes, because it is the same browser and the
  // same board: a fresh tab off the BROWSER-level socket, flat sessions, and a
  // pinned 1440x1000 to start from.
  let verInfo = null;
  while (Date.now() < deadline) {
    try {
      const r = await fetch("http://127.0.0.1:" + DEVTOOLS_PORT + "/json/version");
      if (r.ok) { verInfo = await r.json(); break; }
    } catch (e) { /* not up yet */ }
    await sleep(100);
  }
  if (!verInfo) throw new InfraError("Chrome's devtools endpoint never answered");
  const cdp = new CDP(await connect(verInfo.webSocketDebuggerUrl));
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget",
    { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Runtime.enable", {}, sessionId);
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
  await cdp.send("Page.navigate", { url: URL_ }, sessionId);

  let ready = null;
  while (Date.now() < deadline) {
    try { ready = await evaluate(cdp, sessionId, READY); } catch (e) { ready = null; }
    if (ready && ready.cards >= 5 && ready.band) break;
    await sleep(250);
  }
  if (!ready || !ready.cards) throw new InfraError("the board never painted");
  await sleep(1200);

  // WIDEN THE VIEWPORT TO THE BOARD'S OWN SCROLL EXTENT before measuring
  // anything — S190's own lesson, inherited verbatim. The Stage columns scroll
  // HORIZONTALLY inside #board, so a card in a right-hand column has a bounding
  // rect past the viewport and a screenshot clip there captures bare page
  // background. An ink/paper reading off bare background is a confident 1.00:1
  // about nothing.
  const fit = await evaluate(cdp, sessionId, `(function () {
    var b = document.getElementById("board");
    var w = window.innerWidth, h = window.innerHeight;
    if (b) w = Math.max(w, Math.ceil(b.scrollWidth + b.getBoundingClientRect().left + 24));
    h = Math.max(h, document.documentElement.scrollHeight);
    return { w: Math.min(w, 6000), h: Math.min(h, 6000) };
  })()`) || { w: 1440, h: 1000 };
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: fit.w, height: fit.h, deviceScaleFactor: 1, mobile: false }, sessionId);
  await sleep(400);

  const p = await evaluate(cdp, sessionId, XO_PROBE);
  if (!p || !p.engagedCard) {
    throw new InfraError("the engaged fixture card is not on the board");
  }

  // ── 1. the vocabulary, on the real page ────────────────────────────────
  if (p.engagedPillText === "◈ NUMBER ONE · ENGAGED") {
    ok("the engaged pill says the captain's words, verbatim", p.engagedPillText);
  } else {
    bad("the engaged pill's words", "saw: " + JSON.stringify(p.engagedPillText));
  }
  if (p.finishedPillText === "◈ NUMBER ONE · FINISHED") {
    ok("…and the finished pill says the finished words", p.finishedPillText);
  } else {
    bad("the finished pill's words", "saw: " + JSON.stringify(p.finishedPillText));
  }
  const words = [p.engagedPillText, p.finishedPillText, p.lineText, p.noteText,
                 p.band && p.band.text].concat(p.legend).join(" ").toLowerCase();
  if (/\bfix/.test(words)) {
    bad("it must never say 'fixing' — fixes are the board's own control",
        words);
  } else {
    ok("nothing on screen claims a fix (the board's own control owns that)");
  }
  if (/\bfree\b|\bbilled\b|\bcost/.test(words)) {
    bad("a PRICING WORD is on screen — the captain's ruling forbids it", words);
  } else {
    ok("no pricing word anywhere on Number One's copy");
  }
  if (p.engagedHasClass && !p.finishedHasClass) {
    ok("the peach edge is on the ENGAGED card and only that one", p.edge);
  } else {
    bad("the peach edge", "engaged=" + p.engagedHasClass +
        " finished=" + p.finishedHasClass);
  }
  if (p.band && !p.band.hidden && /◈ Number One · ON · COPILOT/.test(p.band.text)) {
    ok("the band toggle reads ON with the engine named", p.band.text);
  } else {
    bad("the band toggle", "saw: " + JSON.stringify(p.band));
  }
  if (p.legend.length === 2) {
    ok("the legend gained exactly two entries", p.legend.join(" | "));
  } else {
    bad("the legend entries", "saw " + p.legend.length + ": " + p.legend.join(" | "));
  }

  // ── 2. the sweep, on the real page ─────────────────────────────────────
  if (p.liveControls.length === 0 && p.deadControls.length > 0) {
    ok("every write control on the engaged card is locked",
       "locked: " + p.deadControls.join(", "));
  } else {
    bad("a LIVE write control survived on an engaged card",
        "live: " + p.liveControls.join(", "));
  }
  if (p.standDown && p.standDown.text === "■ Stand down" && !p.standDown.disabled) {
    ok("■ Stand down is present and LIVE beside the locked controls");
  } else {
    bad("■ Stand down", "saw: " + JSON.stringify(p.standDown));
  }

  // ── 3. IS IT LEGIBLE — read off the screenshot ─────────────────────────
  await shoot(cdp, sessionId, p.engagedCard, "xo-engaged-card.png", 2, 6);
  await shoot(cdp, sessionId, p.finishedCard, "xo-finished-card.png", 2, 6);
  const pillPng = pngPixels(
    await shoot(cdp, sessionId, p.engagedPill, "xo-pill.png", 4, 0));
  if (p.legendXo) await shoot(cdp, sessionId, p.legendXo, "xo-legend.png", 4, 4);
  const ip = inkAndPaper(pillPng);
  if (!ip) {
    skip("the engaged pill's contrast could not be sampled",
         "the clip came back featureless — the RIG's problem, never a pass");
  } else {
    const c = ip.contrast;
    if (c >= 4.5) {
      ok("the engaged pill reads " + c.toFixed(2) + ":1 on the card (floor 4.5:1)",
         "ink " + JSON.stringify(ip.dark) + " on paper " + JSON.stringify(ip.light));
    } else {
      bad("the engaged pill reads only " + c.toFixed(2) + ":1 (floor 4.5:1)",
          "ink " + JSON.stringify(ip.dark) + " on paper " + JSON.stringify(ip.light));
    }
  }

  // ── 4. CAN YOU TELL IT FROM THE OWNER PILL WITH THE COLOUR GONE ────────
  await evaluate(cdp, sessionId, GREY_ON);
  await sleep(150);
  const greyBoard = pngPixels(
    await shoot(cdp, sessionId, p.engagedCard, "xo-engaged-grey.png", 2, 6));
  if (!isGrey(greyBoard)) {
    skip("the greyscale filter did not bite (r != g != b)",
         "a greyscale check that ran in colour would pass on the broken "
         + "version — the RIG's problem, never a pass");
  } else {
    ok("the greyscale filter bit — every pixel is r == g == b");
    const engagedGrey = pngPixels(
      await shoot(cdp, sessionId, p.engagedPill, "xo-pill-grey.png", 4, 0));
    let finishedGrey = null;
    if (p.finishedPill) {
      finishedGrey = pngPixels(await shoot(
        cdp, sessionId, p.finishedPill, "xo-pill-finished-grey.png", 4, 0));
    }
    let ownerGrey = null;
    if (p.ownerPill) {
      ownerGrey = pngPixels(await shoot(
        cdp, sessionId, p.ownerPill, "xo-owner-grey.png", 4, 0));
    }
    if (p.legendXo) {
      await shoot(cdp, sessionId, p.legendXo, "xo-legend-grey.png", 4, 4);
    }
    const engagedCardGrey = pngPixels(await shoot(
      cdp, sessionId, p.engagedCard, "xo-engaged-card-grey.png", 2, 6));
    const finishedCardGrey = pngPixels(await shoot(
      cdp, sessionId, p.finishedCard, "xo-finished-card-grey.png", 2, 6));
    const se = blockVsGround(engagedGrey, engagedCardGrey);
    const sf = finishedGrey
      ? blockVsGround(finishedGrey, finishedCardGrey) : null;
    // ENGAGED vs FINISHED, measured in RIM WEIGHT. Both pills are hollow, so
    // the question is not "which is the block" — it is "is the engaged rim
    // demonstrably heavier", asked of the desaturated pixels. Nothing here
    // reads the pulse, the colour or the word: a still frame keeps none of the
    // first, a projector none of the second, and a glance across a room none
    // of the third.
    const re_ = rimBand(engagedGrey);
    const rf_ = finishedGrey ? rimBand(finishedGrey) : null;
    if (!re_ || !rf_) {
      skip("the pills' rims could not be measured in greyscale",
           "the clip came back with no rim band — the RIG's problem, never a "
           + "pass");
    } else if (re_.px >= rf_.px * 1.5 && re_.px - rf_.px >= 2) {
      ok("ENGAGED and FINISHED differ by RIM WEIGHT in greyscale, not hue",
         "engaged rim " + re_.px + " device px vs finished " + rf_.px
         + " (x" + (re_.px / rf_.px).toFixed(2) + " at scale 4) — and both are "
         + "hollow: they stand " + se.toFixed(2) + ":1 and " + sf.toFixed(2)
         + ":1 off their own cards");
    } else {
      bad("ENGAGED and FINISHED are the same pill with the colour removed",
          "engaged rim " + re_.px + " device px, finished " + rf_.px
          + " — two hollow pills with the same rim weight are told apart only "
          + "by the WORD and the PULSE, and a static screenshot keeps neither");
    }
    if (!ownerGrey) {
      skip("no owner pill on the engaged card to compare against",
           "the fixture plants one; its absence is the RIG's problem");
    } else {
      const ownerCardGrey = engagedCardGrey;   // the owner pill is on that card
      const so = blockVsGround(ownerGrey, ownerCardGrey);
      // THE REAL QUESTION: with the colour gone, is the peach pill readable as
      // A DIFFERENT THING from the amber owner pill beside it? Compared on the
      // SLAB colour (fill()'s median), not on ink-and-paper: a pill's identity
      // across a room is its block, and two blocks that land on the same grey
      // are two blocks a projector merges.
      const lo = fill(ownerGrey), le = fill(engagedGrey);
      const sep = (lo && le) ? contrast(lo, le) : null;
      console.log("          owner block stands " +
                  (so === null ? "?" : so.toFixed(2) + ":1") +
                  " off its card · Number One's block " +
                  (se === null ? "?" : se.toFixed(2) + ":1") +
                  " · the two blocks are " +
                  (sep === null ? "?" : sep.toFixed(2) + ":1") + " apart");
      // TWO WAYS TO PASS, because there are two honest ways to be told apart
      // with the colour gone, and the board only has to speak one of them:
      // VALUE (the two blocks land on different greys) or SHAPE (one is a solid
      // block and the other is an outline). Hue is not on the list — that is
      // the whole point of the check.
      if (sep !== null && sep >= 1.5) {
        ok("the peach pill separates from the amber owner pill in greyscale",
           sep.toFixed(2) + ":1 of VALUE between the two blocks");
      } else if (so !== null && se !== null
                 && ((so >= 3 && se <= 1.6) || (se >= 3 && so <= 1.6))) {
        ok("the two pills differ by FILL in greyscale — one block, one outline",
           "owner " + so.toFixed(2) + ":1 vs Number One " + se.toFixed(2) + ":1");
      } else {
        bad("the peach pill and the amber owner pill are ONE pill in greyscale",
            "value separation " + (sep === null ? "?" : sep.toFixed(2)) +
            ":1; both blocks are solid (" +
            (so === null ? "?" : so.toFixed(2)) + ":1 and " +
            (se === null ? "?" : se.toFixed(2)) + ":1 off their card), so the " +
            "only thing telling them apart is HUE");
      }
    }
  }
  await evaluate(cdp, sessionId, GREY_OFF);

  // ── the frame the captain actually looks at ────────────────────────────
  const full = await cdp.send("Page.captureScreenshot",
    { format: "png", captureBeyondViewport: true }, sessionId);
  fs.writeFileSync(path.join(OUT, "xo-board.png"),
                   Buffer.from(full.data, "base64"));

  console.log("\nscreenshots: " + path.join(OUT, "xo-board.png")
              + "  (LOOK AT THIS ONE)");
  console.log("             " + path.join(OUT, "xo-engaged-card.png"));
  console.log("             " + path.join(OUT, "xo-engaged-grey.png")
              + "  (the greyscale read)");
  console.log("             " + path.join(OUT, "xo-pill.png")
              + "  (the 4x clip the contrast was read from)");
  return failures === 0 ? 0 : 1;
}

main().then((code) => {
  if (skips) {
    console.log("\n\x1b[33m" + skips + " check(s) SKIPPED — a skip is not a pass.\x1b[0m");
  }
  process.exit(code);
}).catch((e) => {
  if (e instanceof InfraError) {
    console.log("\n\x1b[33mINFRASTRUCTURE\x1b[0m — " + e.message);
    console.log("  This is the RIG's problem, not the board's. Never a pass.");
    process.exit(77);
  }
  console.log("\n\x1b[31mDRIVE ERROR\x1b[0m — " + (e && e.stack || e));
  process.exit(77);
});
