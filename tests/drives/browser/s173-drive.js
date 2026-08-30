"use strict";
/* S173 TESTER RIG — real-Chrome drive of the Implement ACTIVITY FEED.
 * Opens the board, clicks the mission card, expands every activity band, and
 * screenshots the wave bands + the per-event headlines. Zero tokens: GETs only.
 *   node s173-drive.js --devtools-port N --url URL --out DIR
 * Written by the S173 tester because smoke.sh has no hook that opens a mission
 * detail. Kept so the next round does not rebuild it. */
const fs = require("fs");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL_ = arg("url"), OUT = arg("out", ".");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class CDP {
  constructor(ws) { this.ws = ws; this.next = 1; this.pending = new Map(); this.errors = [];
    ws.addEventListener("message", (e) => {
      const m = JSON.parse(e.data);
      if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(m.error.message)) : p.resolve(m.result); return; }
      if (m.method === "Runtime.exceptionThrown") this.errors.push(JSON.stringify(m.params).slice(0, 200));
    });
  }
  send(method, params, sessionId) {
    const id = this.next++;
    this.ws.send(JSON.stringify(sessionId ? { id, method, params: params || {}, sessionId } : { id, method, params: params || {} }));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej }));
  }
}
async function evalIn(cdp, sid, expr) {
  const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails).slice(0, 400));
  return r.result.value;
}
async function shot(cdp, sid, name, h) {
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: 1500, height: h || 1400, deviceScaleFactor: 1, mobile: false }, sid);
  await sleep(400);
  const png = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true }, sid);
  fs.writeFileSync(OUT + "/" + name, Buffer.from(png.data, "base64"));
  console.log("screenshot: " + OUT + "/" + name);
}

(async () => {
  const ver = await (await fetch("http://127.0.0.1:" + PORT + "/json/version")).json();
  const ws = new WebSocket(ver.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.addEventListener("open", res, { once: true }); ws.addEventListener("error", rej, { once: true }); });
  const cdp = new CDP(ws);
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId: sid } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sid);
  await cdp.send("Runtime.enable", {}, sid);
  await cdp.send("Emulation.setDeviceMetricsOverride", { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false }, sid);
  await cdp.send("Page.navigate", { url: URL_ }, sid);

  // wait for a painted card
  let n = 0;
  for (let i = 0; i < 100; i++) {
    n = await evalIn(cdp, sid, "document.querySelectorAll('#board .card').length");
    if (n > 0) break;
    await sleep(300);
  }
  console.log("cards painted: " + n);
  if (!n) { console.log("NO CARDS — board did not paint"); process.exit(1); }
  await shot(cdp, sid, "s173-board.png", 900);

  // open the mission detail
  await evalIn(cdp, sid, "document.querySelector('#board .card').click(); true");
  await sleep(900);
  // expand every activity band
  const expanded = await evalIn(cdp, sid, `(function(){
    var b = Array.prototype.slice.call(document.querySelectorAll('.feed-expand-btn'));
    b.forEach(function(x){ x.click(); });
    return b.length;
  })()`);
  await sleep(500);
  console.log("expand-all buttons clicked: " + expanded);

  const readout = await evalIn(cdp, sid, `(function(){
    function txt(e){ return (e.textContent||'').replace(/\\s+/g,' ').trim(); }
    function vis(e){ var r=e.getBoundingClientRect(); var s=getComputedStyle(e);
      return r.width>0 && r.height>0 && s.display!=='none' && s.visibility!=='hidden' && parseFloat(s.opacity)>0.05; }
    var out = { bands: [], headlines: [], attemptHits: [] };
    Array.prototype.slice.call(document.querySelectorAll('.feed-section')).forEach(function(sec){
      var band = sec.querySelector('.feed-band');
      out.bands.push({
        title: txt(sec.querySelector('.band-title')),
        chips: Array.prototype.slice.call(sec.querySelectorAll('.band-chip')).map(function(c){
          return { cls: c.className, text: txt(c), visible: vis(c),
                   color: getComputedStyle(c).color, bg: getComputedStyle(c).backgroundColor }; }),
        flag: sec.querySelector('.band-flag') ? txt(sec.querySelector('.band-flag')) : null,
        bandVisible: band ? vis(band) : false
      });
    });
    Array.prototype.slice.call(document.querySelectorAll('.evt .head')).forEach(function(h){
      out.headlines.push(txt(h));
    });
    // EVERY captain-visible node whose own text mentions "attempt"
    var all = document.querySelectorAll('#detail *, .detail *, body *');
    Array.prototype.slice.call(all).forEach(function(e){
      if (e.children.length) return;
      var t = txt(e);
      if (/attempt/i.test(t) && vis(e)) out.attemptHits.push({ cls: e.className, tag: e.tagName, text: t.slice(0,160) });
    });
    return out;
  })()`);
  fs.writeFileSync(OUT + "/s173-readout.json", JSON.stringify(readout, null, 2));
  console.log(JSON.stringify(readout.bands, null, 2));
  console.log("--- headlines ---");
  console.log(readout.headlines.join("\n"));
  console.log("--- visible leaf nodes containing 'attempt' ---");
  console.log(JSON.stringify(readout.attemptHits, null, 2));

  // Second pass: COLLAPSE every band back to its summary — this is what the
  // captain sees WITHOUT opening a wave, and the whole point of the round.
  await evalIn(cdp, sid, `(function(){
    var b = document.querySelector('.feed-expand-btn'); if (b) b.click(); return true;
  })()`);
  await sleep(500);
  const box = await evalIn(cdp, sid, `(function(){
    var f = document.querySelector('.feed-history'); if(!f) return null;
    f.scrollIntoView(); var r = f.getBoundingClientRect();
    return {x:r.x+window.scrollX, y:r.y+window.scrollY, w:r.width, h:r.height};
  })()`);
  if (box) {
    await cdp.send("Emulation.setDeviceMetricsOverride",
      { width: 1500, height: 1400, deviceScaleFactor: 2, mobile: false }, sid);
    await sleep(400);
    const png2 = await cdp.send("Page.captureScreenshot", { format: "png",
      captureBeyondViewport: true,
      clip: { x: box.x, y: box.y, width: box.w, height: Math.min(box.h, 1200), scale: 2 } }, sid);
    fs.writeFileSync(OUT + "/s173-bands.png", Buffer.from(png2.data, "base64"));
    console.log("screenshot: " + OUT + "/s173-bands.png");
  }
  const h = await evalIn(cdp, sid, "Math.min(document.body.scrollHeight, 9000)");
  await shot(cdp, sid, "s173-detail.png", h);
  console.log("page errors: " + cdp.errors.length);
  process.exit(0);
})().catch((e) => { console.error("DRIVER ERROR: " + e.message); process.exit(77); });
