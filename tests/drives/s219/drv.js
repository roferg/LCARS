#!/usr/bin/env node
/* S219 driver: a PERSISTENT headless-Chrome tab over CDP (state survives between calls).
 * node drv.js '<json steps>'   env: DEVPORT (9231), BOARD (http://127.0.0.1:8931/), OUT (shots dir)
 * steps: {nav:url} {eval:js} {click:sel} {type:{sel,text}} {key:"Enter"} {wait:ms}
 *        {waitFor:js-expr, timeout} {shot:file, selector?, pad?, full?}
 * Viewport 1440x1000 CSS at deviceScaleFactor 2 (every shot is 2x).
 */
const fs = require("fs"), path = require("path");
const DEVPORT = process.env.DEVPORT || "9231";
const BOARD = process.env.BOARD || "http://127.0.0.1:8931/";
const OUT = process.env.OUT || path.join(__dirname, "shots");
const W = +(process.env.VW || 1440), H = +(process.env.VH || 1000);
const STEPS = JSON.parse(process.argv[2] || "[]");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
class CDP {
  constructor(ws) { this.ws = ws; this.next = 1; this.pending = new Map(); this.errs = [];
    ws.addEventListener("message", (ev) => { let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); return; }
      if (m.method === "Runtime.exceptionThrown") this.errs.push(String((m.params.exceptionDetails || {}).text)); }); }
  send(method, params, sessionId) { const id = this.next++;
    const pl = { id, method, params: params || {} }; if (sessionId) pl.sessionId = sessionId;
    this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej })); } }
function connect(u) { return new Promise((res, rej) => { const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused " + u)), { once: true }); }); }
async function ev(cdp, sid, expr) {
  const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r && r.exceptionDetails) throw new Error("eval threw: " + JSON.stringify(r.exceptionDetails.exception && r.exceptionDetails.exception.description || r.exceptionDetails.text));
  return r && r.result ? r.result.value : null; }
(async () => {
  const ver = await (await fetch("http://127.0.0.1:" + DEVPORT + "/json/version")).json();
  const ws = await connect(ver.webSocketDebuggerUrl); const cdp = new CDP(ws);
  const { targetInfos } = await cdp.send("Target.getTargets");
  let t = targetInfos.find((x) => x.type === "page" && x.url.startsWith(BOARD));
  let targetId = t ? t.targetId : (await cdp.send("Target.createTarget", { url: "about:blank" })).targetId;
  const sid = (await cdp.send("Target.attachToTarget", { targetId, flatten: true })).sessionId;
  await cdp.send("Page.enable", {}, sid); await cdp.send("Runtime.enable", {}, sid);
  await cdp.send("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: 2, mobile: false }, sid);
  if (!t) { await cdp.send("Page.navigate", { url: BOARD }, sid); await sleep(3000); }
  const out = { pageErrors: [], steps: [] };
  for (const s of STEPS) {
    try {
      if (s.nav) { await cdp.send("Page.navigate", { url: s.nav }, sid); await sleep(s.wait || 3000); out.steps.push({ nav: s.nav }); continue; }
      if (s.eval) { out.steps.push({ eval: await ev(cdp, sid, s.eval) }); }
      if (s.waitFor) { const dl = Date.now() + (s.timeout || 30000); let ok = false;
        while (Date.now() < dl) { try { if (await ev(cdp, sid, s.waitFor)) { ok = true; break; } } catch (e) {} await sleep(500); }
        out.steps.push({ waitFor: s.waitFor, ok }); }
      if (s.click) { const ok = await ev(cdp, sid, `(function(){var e=document.querySelector(${JSON.stringify(s.click)}); if(e){e.scrollIntoView({block:'center'}); e.click(); return true} return false})()`);
        out.steps.push({ click: s.click, ok }); await sleep(s.wait || 800); continue; }
      if (s.type) { await ev(cdp, sid, `(function(){var e=document.querySelector(${JSON.stringify(s.type.sel)}); e.focus(); if('value' in e) e.value=''; return true})()`);
        await cdp.send("Input.insertText", { text: s.type.text }, sid); out.steps.push({ typed: s.type.sel, len: s.type.text.length }); continue; }
      if (s.key) { const k = s.key; const code = k === "Enter" ? 13 : k === "Escape" ? 27 : 0;
        const mods = s.mods || 0;
        await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: k, code: k, windowsVirtualKeyCode: code, modifiers: mods }, sid);
        await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code: k, windowsVirtualKeyCode: code, modifiers: mods }, sid);
        out.steps.push({ key: k }); await sleep(s.wait || 500); continue; }
      if (s.wait && !s.shot) { await sleep(s.wait); continue; }
      if (s.shot) {
        let clip = null;
        if (s.selector) {
          const box = await ev(cdp, sid, `(function(){var e=document.querySelector(${JSON.stringify(s.selector)}); if(!e) return null; e.scrollIntoView({block:'nearest'}); var r=e.getBoundingClientRect(); return {x:r.x+scrollX,y:r.y+scrollY,w:r.width,h:r.height}})()`);
          if (!box) { out.steps.push({ shot: s.shot, error: "selector not found " + s.selector }); continue; }
          const pad = s.pad == null ? 12 : s.pad;
          clip = { x: Math.max(0, box.x - pad), y: Math.max(0, box.y - pad), width: box.w + pad * 2, height: box.h + pad * 2, scale: 1 };
        } else if (s.clip) { clip = Object.assign({ scale: 1 }, s.clip); }
        const p = { format: "png", captureBeyondViewport: !!s.full };
        if (clip) p.clip = clip;
        const png = await cdp.send("Page.captureScreenshot", p, sid);
        fs.writeFileSync(path.join(OUT, s.shot), Buffer.from(png.data, "base64"));
        out.steps.push({ shot: s.shot, clip });
      }
    } catch (e) { out.steps.push({ error: String(e.message || e), step: s }); }
  }
  out.pageErrors = cdp.errs;
  console.log(JSON.stringify(out, null, 1));
  process.exit(0);
})().catch((e) => { console.error("ERR " + e.message); process.exit(1); });
