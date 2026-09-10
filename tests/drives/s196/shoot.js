#!/usr/bin/env node
/* S196 tester: a generic real-Chrome screenshot driver over CDP.
 * node shoot.js --devtools-port N --url URL --out DIR --shots '<json>'
 * shots: [{file, selector?, fullPage?, pad?, scale?, wait?, click?, eval?}]
 * Prints JSON of any `eval` results so a bash drive can assert on them.
 */
const fs = require("fs"), path = require("path");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), OUT = arg("out", ".");
const SHOTS = JSON.parse(arg("shots", "[]"));
const WAITSEL = arg("wait-for", ".card");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
class CDP {
  constructor(ws) { this.ws = ws; this.next = 1; this.pending = new Map(); this.errs = [];
    ws.addEventListener("message", (ev) => { let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(m.method + ": " + JSON.stringify(m.error))) : p.resolve(m.result); return; }
      if (m.method === "Runtime.exceptionThrown") this.errs.push(String((m.params.exceptionDetails||{}).text)); }); }
  send(method, params, sessionId) { const id = this.next++;
    const pl = { id, method, params: params || {} }; if (sessionId) pl.sessionId = sessionId;
    this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej })); } }
function connect(u) { return new Promise((res, rej) => { const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused " + u)), { once: true }); }); }
async function ev(cdp, sid, expr) {
  const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r && r.exceptionDetails) throw new Error("probe threw: " + JSON.stringify(r.exceptionDetails.text));
  return r && r.result ? r.result.value : null; }
(async () => {
  let ver = null, dl = Date.now() + 30000;
  while (Date.now() < dl) { try { const r = await fetch("http://127.0.0.1:" + PORT + "/json/version"); if (r.ok) { ver = await r.json(); break; } } catch (e) {} await sleep(100); }
  if (!ver) { console.error("no devtools"); process.exit(77); }
  const ws = await connect(ver.webSocketDebuggerUrl); const cdp = new CDP(ws);
  const t = await cdp.send("Target.createTarget", { url: "about:blank" });
  const att = await cdp.send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
  const sid = att.sessionId;
  await cdp.send("Page.enable", {}, sid); await cdp.send("Runtime.enable", {}, sid);
  await cdp.send("Page.navigate", { url: URL }, sid);
  dl = Date.now() + 30000; let ready = false;
  while (Date.now() < dl) { try { if (await ev(cdp, sid, `!!document.querySelector(${JSON.stringify(WAITSEL)})`)) { ready = true; break; } } catch (e) {} await sleep(200); }
  await sleep(700);
  const results = { chrome: ver.Browser, ready, pageErrors: cdp.errs, shots: [] };
  for (const s of SHOTS) {
    if (s.eval) { results.shots.push({ file: s.file || null, eval: await ev(cdp, sid, s.eval) }); }
    if (s.click) { await ev(cdp, sid, `(function(){var e=document.querySelector(${JSON.stringify(s.click)}); if(e){e.click(); return true} return false})()`); await sleep(s.wait || 800); }
    if (s.wait && !s.click) await sleep(s.wait);
    if (!s.file) continue;
    let clip = null;
    if (s.selector) {
      const box = await ev(cdp, sid, `(function(){var e=document.querySelector(${JSON.stringify(s.selector)}); if(!e) return null; var r=e.getBoundingClientRect(); return {x:r.x+scrollX,y:r.y+scrollY,w:r.width,h:r.height}})()`);
      if (!box) { results.shots.push({ file: s.file, error: "selector not found: " + s.selector }); continue; }
      const pad = s.pad == null ? 12 : s.pad;
      clip = { x: Math.max(0, box.x - pad), y: Math.max(0, box.y - pad), width: box.w + pad * 2, height: box.h + pad * 2, scale: s.scale || 2 };
    }
    const p = { format: "png", captureBeyondViewport: true };
    if (clip) p.clip = clip; else p.captureBeyondViewport = true;
    const png = await cdp.send("Page.captureScreenshot", p, sid);
    fs.writeFileSync(path.join(OUT, s.file), Buffer.from(png.data, "base64"));
    results.shots.push({ file: s.file, bytes: Buffer.from(png.data, "base64").length, clip });
  }
  console.log(JSON.stringify(results, null, 1));
  process.exit(0);
})().catch((e) => { console.error("ERR " + e.message); process.exit(1); });
