"use strict";
/* S202 — one clipped screenshot of one real board element, raw CDP, no deps.
 *   node shot.js --devtools-port N --url URL --sel "<css>" --out FILE [--pad 8]
 * Waits for the selector to have a real non-zero box, then captures exactly
 * that box (plus padding) so the captain's 390px phone gets the card, not the
 * desktop. Fails loudly rather than writing a blank PNG. */
const fs = require("fs");
const A = {};
process.argv.slice(2).forEach((a, i, all) => {
  if (a.startsWith("--")) A[a.slice(2)] = all[i + 1];
});
const port = A["devtools-port"], url = A.url, sel = A.sel, out = A.out;
const pad = Number(A.pad || 8);
const maxw = Number(A.maxw || 665);

(async () => {
  const v = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
  const ws = new WebSocket(v.webSocketDebuggerUrl);
  let id = 0; const waiting = new Map();
  const send = (method, params = {}, sessionId) =>
    new Promise((res, rej) => {
      const m = ++id;
      waiting.set(m, { res, rej });
      ws.send(JSON.stringify({ id: m, method, params, sessionId }));
    });
  const events = [];
  await new Promise((r) => ws.addEventListener("open", r));
  ws.addEventListener("message", (e) => {
    const m = JSON.parse(e.data);
    if (m.id && waiting.has(m.id)) {
      const w = waiting.get(m.id); waiting.delete(m.id);
      m.error ? w.rej(new Error(m.error.message)) : w.res(m.result);
    } else events.push(m);
  });
  const { targetId } = await send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await send("Target.attachToTarget", { targetId, flatten: true });
  await send("Page.enable", {}, sessionId);
  await send("Runtime.enable", {}, sessionId);
  await send("Emulation.setDeviceMetricsOverride",
    { width: 1100, height: 1600, deviceScaleFactor: 1, mobile: false }, sessionId);
  await send("Page.navigate", { url }, sessionId);

  const deadline = Date.now() + 30000;
  let box = null;
  while (Date.now() < deadline) {
    const r = await send("Runtime.evaluate", {
      expression: `(() => { const e = document.querySelector(${JSON.stringify(sel)});
        if (!e) return null; e.scrollIntoView({block:"center",inline:"center"});
        const b = e.getBoundingClientRect();
        return (b.width > 1 && b.height > 1)
          ? {x:b.x, y:b.y, w:b.width, h:b.height} : null; })()`,
      returnByValue: true,
    }, sessionId);
    if (r.result && r.result.value) { box = r.result.value; break; }
    await new Promise((r2) => setTimeout(r2, 250));
  }
  if (!box) { console.error(`NOT FOUND / zero-size: ${sel}`); process.exit(3); }

  const w = Math.min(box.w + pad * 2, maxw);
  const scale = Math.min(1, maxw / (box.w + pad * 2));
  const shot = await send("Page.captureScreenshot", {
    format: "png",
    clip: { x: Math.max(0, box.x - pad), y: Math.max(0, box.y - pad),
            width: box.w + pad * 2, height: box.h + pad * 2, scale: 1 },
  }, sessionId);
  fs.writeFileSync(out, Buffer.from(shot.data, "base64"));
  console.log(`wrote ${out}  css-box ${Math.round(box.w)}x${Math.round(box.h)}  png-width ${Math.round(w * 2)}px@2x`);
  ws.close();
  process.exit(0);
})().catch((e) => { console.error(e.message); process.exit(1); });
