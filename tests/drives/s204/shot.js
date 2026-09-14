"use strict";
/* ══ S204 SHOT TOOL — crop tight, capture at 3x ══════════════════════════════
 *
 * The captain read S200's walkthrough on his phone and said the images were
 * "very pixely". The cause was a 665-CSS-px crop saved as a 665-PIXEL file and
 * then stretched across ~2000 physical phone pixels. Cropping alone cannot fix
 * that — only CAPTURE TIME can. So every shot here is taken with
 * Page.captureScreenshot's clip.scale = 3, and the clip is a real element's
 * measured box, not the viewport.
 *
 *   node shot.js --port P --url U --out FILE
 *        [--wait SEL] [--clip SEL] [--clip-box x,y,w,h] [--pad N]
 *        [--scale 3] [--width 1440] [--height 1000] [--eval 'js'] [--settle MS]
 *
 * --clip takes a CSS selector; the element's bounding box (plus --pad) is the
 * crop. Zero-dependency, attaches to an already-running Chrome.
 * ═══════════════════════════════════════════════════════════════════════════ */
const fs = require("fs");

const argv = process.argv.slice(2);
function arg(n, d) { const i = argv.indexOf("--" + n); return i < 0 ? d : argv[i + 1]; }
function flag(n) { return argv.indexOf("--" + n) >= 0; }

const PORT = arg("port");
const URL_ = arg("url");
const OUT = arg("out");
const WAIT = arg("wait", null);
const CLIP = arg("clip", null);
const CLIPBOX = arg("clip-box", null);
const PAD = parseInt(arg("pad", "10"), 10);
const SCALE = parseFloat(arg("scale", "3"));
const W = parseInt(arg("width", "1440"), 10);
const H = parseInt(arg("height", "1400"), 10);
const EVAL = arg("eval", null);
const SETTLE = parseInt(arg("settle", "900"), 10);
const TIMEOUT = parseInt(arg("timeout", "30000"), 10);

class CDP {
  constructor(ws) {
    this.ws = ws; this.next = 1; this.pending = new Map();
    ws.addEventListener("message", (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) reject(new Error(JSON.stringify(m.error))); else resolve(m.result);
      }
    });
  }
  send(method, params, sessionId) {
    const id = this.next++;
    const p = { id, method, params: params || {} };
    if (sessionId) p.sessionId = sessionId;
    this.ws.send(JSON.stringify(p));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej }));
  }
}
const connect = (u) => new Promise((res, rej) => {
  const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused " + u)), { once: true });
});
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  const ver = await (await fetch("http://127.0.0.1:" + PORT + "/json/version")).json();
  const cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  const S = (m, p) => cdp.send(m, p, sessionId);

  await S("Page.enable");
  await S("Runtime.enable");
  await S("Emulation.setDeviceMetricsOverride", {
    width: W, height: H, deviceScaleFactor: SCALE, mobile: false,
  });
  await S("Page.navigate", { url: URL_ });

  const deadline = Date.now() + TIMEOUT;
  if (WAIT) {
    for (;;) {
      const r = await S("Runtime.evaluate", {
        expression: "!!document.querySelector(" + JSON.stringify(WAIT) + ")",
        returnByValue: true,
      });
      if (r.result && r.result.value) break;
      if (Date.now() > deadline) throw new Error("timeout waiting for " + WAIT);
      await sleep(250);
    }
  }
  await sleep(SETTLE);
  if (EVAL) {
    const r = await S("Runtime.evaluate", { expression: EVAL, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error("--eval threw: " + JSON.stringify(r.exceptionDetails));
    await sleep(SETTLE);
  }

  let clip = null;
  if (CLIPBOX) {
    const [x, y, w, h] = CLIPBOX.split(",").map(Number);
    clip = { x, y, width: w, height: h, scale: 1 };
  } else if (CLIP) {
    const r = await S("Runtime.evaluate", {
      expression: `(function(){var e=document.querySelector(${JSON.stringify(CLIP)});
        if(!e) return null; var b=e.getBoundingClientRect();
        return {x:b.x+scrollX,y:b.y+scrollY,w:b.width,h:b.height};})()`,
      returnByValue: true,
    });
    const b = r.result && r.result.value;
    if (!b) throw new Error("--clip selector not found: " + CLIP);
    clip = {
      x: Math.max(0, b.x - PAD), y: Math.max(0, b.y - PAD),
      width: b.w + PAD * 2, height: b.h + PAD * 2, scale: 1,
    };
  }
  const shot = await S("Page.captureScreenshot",
    clip ? { format: "png", clip, captureBeyondViewport: true } : { format: "png" });
  fs.writeFileSync(OUT, Buffer.from(shot.data, "base64"));
  // The sidecar walkthrough.sh reads to tell CONTENT width from PIXEL width.
  fs.writeFileSync(OUT.replace(/\.png$/, ".json"),
    JSON.stringify({ deviceScaleFactor: SCALE, url: URL_, clip: clip || "viewport" }, null, 1));
  const css = clip ? Math.round(clip.width) + "x" + Math.round(clip.height) + " CSS" : "viewport";
  console.log("saved " + OUT + "  (" + css + " @" + SCALE + "x)");
  await cdp.send("Target.closeTarget", { targetId });
  process.exit(0);
})().catch((e) => { console.error("SHOT FAILED: " + e.message); process.exit(1); });
