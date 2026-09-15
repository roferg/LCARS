"use strict";
/* ══ S205 ACT TOOL — a small sequence-of-steps CDP driver, headed Chrome ═════
 *
 * The tester's own rig: attach to an ALREADY-LAUNCHED headed Chrome (started
 * with --remote-debugging-port), open ONE tab, and run a JSON list of steps —
 * navigate, wait for a selector, click, type, eval, screenshot (viewport or a
 * selector's box), sleep — so a whole multi-click journey (open the board,
 * click a card, open a tab, open a menu, open a modal, search) happens in one
 * real page session instead of one fresh reload per shot.
 *
 *   node act.js --port P --steps steps.json --outdir DIR
 *
 * Screenshots always go through Emulation.setDeviceMetricsOverride at the
 * requested deviceScaleFactor (default 2, i.e. "2x or better" per the
 * captain's sharpness ruling) BEFORE Page.captureScreenshot, and every clip
 * shot is a real element's measured box (+ pad), not a guessed rectangle.
 *
 * step shapes:
 *   {"goto": "http://..."}
 *   {"wait": "css selector", "timeout": 15000}
 *   {"click": "css selector"}
 *   {"type": "css selector", "text": "..."}
 *   {"eval": "js expression"}
 *   {"sleep": 400}
 *   {"shot": "name", "clip": "css selector"|null, "pad": 12, "scale": 2.5, "full": true}
 *   {"scale": 2}          — set default device scale factor for the session
 *   {"viewport": [1440, 1400]}
 * ═══════════════════════════════════════════════════════════════════════════ */
const fs = require("fs");
const path = require("path");

const argv = process.argv.slice(2);
function arg(n, d) { const i = argv.indexOf("--" + n); return i < 0 ? d : argv[i + 1]; }

const PORT = arg("port", "9222");
const STEPS_FILE = arg("steps");
const OUTDIR = arg("outdir", ".");

if (!STEPS_FILE) { console.error("need --steps steps.json"); process.exit(2); }
fs.mkdirSync(OUTDIR, { recursive: true });
const steps = JSON.parse(fs.readFileSync(STEPS_FILE, "utf8"));

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
  let W = 1440, H = 1400, SCALE = 2;
  await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });

  async function waitFor(sel, timeout) {
    const deadline = Date.now() + (timeout || 15000);
    for (;;) {
      const r = await S("Runtime.evaluate", {
        expression: "!!document.querySelector(" + JSON.stringify(sel) + ")",
        returnByValue: true,
      });
      if (r.result && r.result.value) return true;
      if (Date.now() > deadline) throw new Error("timeout waiting for " + sel);
      await sleep(200);
    }
  }

  for (const step of steps) {
    if (step.goto) {
      await S("Page.navigate", { url: step.goto });
      await sleep(step.settle || 600);
    } else if (step.viewport) {
      W = step.viewport[0]; H = step.viewport[1];
      await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
    } else if (step.scale) {
      SCALE = step.scale;
      await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
    } else if (step.wait) {
      await waitFor(step.wait, step.timeout);
    } else if (step.click) {
      await waitFor(step.click, step.timeout);
      const r = await S("Runtime.evaluate", {
        expression: `(function(){var e=document.querySelector(${JSON.stringify(step.click)});
          if(!e) return "NOTFOUND"; e.scrollIntoView({block:"center"}); e.click(); return "OK";})()`,
        returnByValue: true,
      });
      if (r.result && r.result.value !== "OK") throw new Error("click target not found: " + step.click);
      await sleep(step.settle || 400);
    } else if (step.type) {
      await waitFor(step.type, step.timeout);
      await S("Runtime.evaluate", {
        expression: `(function(){var e=document.querySelector(${JSON.stringify(step.type)});
          e.focus(); e.value=${JSON.stringify(step.text || "")};
          e.dispatchEvent(new Event('input',{bubbles:true}));
          e.dispatchEvent(new Event('change',{bubbles:true}));})()`,
      });
      await sleep(step.settle || 300);
    } else if (step.eval) {
      const r = await S("Runtime.evaluate", { expression: step.eval, returnByValue: true, awaitPromise: true });
      if (r.exceptionDetails) throw new Error("eval threw: " + JSON.stringify(r.exceptionDetails));
      if (step.log) console.log("EVAL " + step.eval + " => " + JSON.stringify(r.result && r.result.value));
    } else if (step.sleep) {
      await sleep(step.sleep);
    } else if (step.shot) {
      let clip = null;
      if (step.clip) {
        const r = await S("Runtime.evaluate", {
          expression: `(function(){var e=document.querySelector(${JSON.stringify(step.clip)});
            if(!e) return null; var b=e.getBoundingClientRect();
            return {x:b.x+scrollX,y:b.y+scrollY,w:b.width,h:b.height};})()`,
          returnByValue: true,
        });
        const b = r.result && r.result.value;
        if (!b) throw new Error("--clip selector not found: " + step.clip);
        const pad = step.pad == null ? 12 : step.pad;
        clip = { x: Math.max(0, b.x - pad), y: Math.max(0, b.y - pad), width: b.w + pad * 2, height: b.h + pad * 2, scale: 1 };
      }
      if (step.scaleForShot) {
        SCALE = step.scaleForShot;
        await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: SCALE, mobile: false });
        await sleep(100);
      }
      const outp = path.join(OUTDIR, step.shot + ".png");
      const shotres = await S("Page.captureScreenshot",
        clip ? { format: "png", clip, captureBeyondViewport: true } : { format: "png", captureBeyondViewport: !!step.full });
      fs.writeFileSync(outp, Buffer.from(shotres.data, "base64"));
      const css = clip ? Math.round(clip.width) + "x" + Math.round(clip.height) + " CSS" : W + "x" + H + " viewport";
      console.log("saved " + outp + "  (" + css + " @" + SCALE + "x)");
    }
  }
  await cdp.send("Target.closeTarget", { targetId });
  process.exit(0);
})().catch((e) => { console.error("ACT FAILED: " + e.message); process.exit(1); });
