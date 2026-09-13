"use strict";
/* S201 TESTER DRIVER — one command per press, against a Chrome that stays up.
 *
 * The pixel rig (xo-paint.js) asks all its questions in one process and then
 * tears the browser down. A tester cannot work that way: he presses a thing,
 * looks, curls, runs a CLI, presses another. So this attaches to the ALREADY
 * OPEN tab (never Target.createTarget — a new tab would be a new board and the
 * thing just pressed would be gone), does exactly one act, and exits.
 *
 *   node tester-drive.js --port N --url URL <act> [args]
 *
 *   open                      navigate the tab to the board and wait for cards
 *   eval '<expr>'             run it in the page, print JSON
 *   click '<selector>'        real CDP mouse press at the element's centre
 *   shot '<selector>' FILE    clip a screenshot to that element (+pad)
 *   shot-grey '<selector>' F  the same, with the s190 desaturation filter on
 *   fit                       widen the viewport to the board's scroll extent
 *
 * Reuses s190's CDP client, PNG reader and contrast formula — never a second
 * implementation of "what does this pixel actually say".
 */
const fs = require("fs");
const path = require("path");
const base = require("../s190/owner-paint.js");
const { CDP, connect, pngPixels, contrast, lum } = base;

function arg(n, d) {
  const i = process.argv.indexOf("--" + n);
  return i > -1 && process.argv[i + 1] ? process.argv[i + 1] : d;
}
const PORT = arg("port");
const URL_ = arg("url");
const rest = process.argv.slice(2).filter((a, i, A) =>
  !a.startsWith("--") && !(A[i - 1] || "").startsWith("--"));
const ACT = rest[0];
const A1 = rest[1];
const A2 = rest[2];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function ev(cdp, sid, expr) {
  const r = await cdp.send("Runtime.evaluate",
    { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r && r.exceptionDetails) throw new Error("probe threw: " + r.exceptionDetails.text);
  return r && r.result ? r.result.value : null;
}

const GREY = `(function(){
  var s = document.getElementById('__grey__');
  if (!s) { s = document.createElement('style'); s.id='__grey__';
    s.textContent = 'html{filter:grayscale(1) !important;}';
    document.documentElement.appendChild(s); }
  return true; })()`;
const UNGREY = `(function(){ var s=document.getElementById('__grey__');
  if (s) s.remove(); return true; })()`;

async function box(cdp, sid, sel) {
  const b = await ev(cdp, sid, `(function(){
    var e = document.querySelector(${JSON.stringify(sel)});
    if (!e) return null;
    var r = e.getBoundingClientRect();
    return {x:r.left+window.scrollX, y:r.top+window.scrollY, w:r.width, h:r.height,
            text:(e.innerText||'').slice(0,200)};
  })()`);
  if (!b) throw new Error("no element for selector: " + sel);
  return b;
}

async function main() {
  const ver = await (await fetch("http://127.0.0.1:" + PORT + "/json/version")).json();
  const cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  // Attach to whatever page target is already open — the tab the last act left.
  const { targetInfos } = await cdp.send("Target.getTargets");
  let t = targetInfos.filter((x) => x.type === "page")
                     .sort((a, b) => (b.url.indexOf("127.0.0.1") - a.url.indexOf("127.0.0.1")))[0];
  if (!t) throw new Error("no page target open in this Chrome");
  const { sessionId: sid } = await cdp.send("Target.attachToTarget",
    { targetId: t.targetId, flatten: true });
  await cdp.send("Page.enable", {}, sid);
  await cdp.send("Runtime.enable", {}, sid);

  if (ACT === "open") {
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: 1440, height: 1000, deviceScaleFactor: 2, mobile: false }, sid);
    await cdp.send("Page.navigate", { url: URL_ }, sid);
    const deadline = Date.now() + 40000;
    let r = null;
    while (Date.now() < deadline) {
      try { r = await ev(cdp, sid, `({cards:document.querySelectorAll('.card').length,
        cols:document.querySelectorAll('.col,.column,.stage-col').length,
        tokens:getComputedStyle(document.documentElement).getPropertyValue('--lcars-peach').trim(),
        title:document.title})`); } catch (e) { r = null; }
      if (r && r.cards > 0) break;
      await sleep(250);
    }
    console.log(JSON.stringify(r));
    process.exit(r && r.cards > 0 ? 0 : 1);
  }

  if (ACT === "fit") {
    const fit = await ev(cdp, sid, `(function(){
      var b=document.getElementById('board'); var w=window.innerWidth,h=window.innerHeight;
      if(b) w=Math.max(w, Math.ceil(b.scrollWidth + b.getBoundingClientRect().left + 24));
      h=Math.max(h, document.documentElement.scrollHeight);
      return {w:Math.min(w,6000), h:Math.min(h,6000)}; })()`);
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: fit.w, height: fit.h, deviceScaleFactor: 2, mobile: false }, sid);
    await sleep(500);
    console.log(JSON.stringify(fit));
    process.exit(0);
  }

  if (ACT === "eval") { console.log(JSON.stringify(await ev(cdp, sid, A1))); process.exit(0); }

  if (ACT === "click") {
    const b = await box(cdp, sid, A1);
    const m = await ev(cdp, sid, `(function(){var e=document.querySelector(${JSON.stringify(A1)});
      var r=e.getBoundingClientRect(); return {x:r.left+r.width/2, y:r.top+r.height/2};})()`);
    for (const type of ["mousePressed", "mouseReleased"]) {
      await cdp.send("Input.dispatchMouseEvent",
        { type, x: m.x, y: m.y, button: "left", clickCount: 1 }, sid);
    }
    await sleep(700);
    console.log(JSON.stringify({ clicked: A1, at: m, was: b.text.slice(0, 60) }));
    process.exit(0);
  }

  if (ACT === "shot" || ACT === "shot-grey") {
    if (ACT === "shot-grey") { await ev(cdp, sid, GREY); await sleep(350); }
    const pad = Number(arg("pad", "10"));
    const scale = Number(arg("scale", "2"));
    let b = await box(cdp, sid, A1);
    // --span "selA|selB": clip from the left edge of A to the right edge of B,
    // so a wide strip (the legend) can be cropped to the part that is the
    // point without inventing a wrapper element the product does not have.
    const span = arg("span", "");
    if (span) {
      const [sa, sb] = span.split("|");
      const ba = await box(cdp, sid, sa), bb = await box(cdp, sid, sb);
      b = { x: ba.x, y: Math.min(ba.y, bb.y), w: (bb.x + bb.w) - ba.x,
            h: Math.max(ba.y + ba.h, bb.y + bb.h) - Math.min(ba.y, bb.y),
            text: ba.text + " … " + bb.text };
    }
    const png = await cdp.send("Page.captureScreenshot", {
      format: "png", captureBeyondViewport: true,
      clip: { x: Math.max(0, b.x - pad), y: Math.max(0, b.y - pad),
              width: b.w + pad * 2, height: b.h + pad * 2, scale },
    }, sid);
    const buf = Buffer.from(png.data, "base64");
    fs.mkdirSync(path.dirname(A2), { recursive: true });
    fs.writeFileSync(A2, buf);
    // Did the greyscale filter actually BITE? r==g==b or it did not.
    let grey = null;
    if (ACT === "shot-grey") {
      const p = pngPixels(buf);
      let mono = 0, n = 0;
      for (let i = 0; i < p.w * p.h; i++) {
        const o = i * p.bpp; n++;
        if (p.px[o] === p.px[o + 1] && p.px[o + 1] === p.px[o + 2]) mono++;
      }
      grey = { sampled: n, monochrome: mono, bit: mono === n };
      await ev(cdp, sid, UNGREY);
    }
    console.log(JSON.stringify({ file: A2, bytes: buf.length, box: b, grey }));
    process.exit(0);
  }

  throw new Error("unknown act: " + ACT);
}

main().catch((e) => { console.error("DRIVE ERROR — " + (e && e.stack || e)); process.exit(77); });
