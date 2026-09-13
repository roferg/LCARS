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
 *      the reason this check exists at all. The answer must be FILL, not hue:
 *      the ENGAGED pill is a solid block and the FINISHED pill is an outline,
 *      and the rig proves that by DESATURATING the real page in real Chrome
 *      and re-reading the pixels through the filter. It also proves THE FILTER
 *      BIT (r == g == b), because a greyscale check that silently ran in
 *      colour would pass on the broken version.
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
    const engagedCardGrey = pngPixels(await shoot(
      cdp, sessionId, p.engagedCard, "xo-engaged-card-grey.png", 2, 6));
    const finishedCardGrey = pngPixels(await shoot(
      cdp, sessionId, p.finishedCard, "xo-finished-card-grey.png", 2, 6));
    const se = blockVsGround(engagedGrey, engagedCardGrey);
    const sf = finishedGrey
      ? blockVsGround(finishedGrey, finishedCardGrey) : null;
    if (se === null || sf === null) {
      skip("the pills could not be sampled against their cards in greyscale");
    } else if (se >= 3 && sf <= 1.6) {
      ok("ENGAGED and FINISHED differ by FILL in greyscale, not hue",
         "solid block stands " + se.toFixed(2) + ":1 off its card; hollow one "
         + sf.toFixed(2) + ":1 (i.e. it IS the card, with a rim)");
    } else {
      bad("ENGAGED and FINISHED are the same pill with the colour removed",
          "engaged " + se.toFixed(2) + ":1 off its card, finished "
          + sf.toFixed(2) + ":1 — a solid block must stand off it and a hollow "
          + "one must not");
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
