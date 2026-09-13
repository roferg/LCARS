"use strict";
/* ══ S203 MICRO-SPIKE DRIVER — zero-dep raw CDP, screenshot + paired readout ══
 *
 * A probe-scale sibling of tests/drives/browser/cdp.js and
 * tests/drives/s192/shot-probe.js, written for the S203 gating spike ONLY:
 * answer "can the raw-CDP driver screenshot an app that launch.sh launched?"
 *
 * It attaches to an already-launched Chrome (the shell owns teardown), enables
 * Runtime/Log/Page BEFORE navigating, polls the REAL DOM until the named place
 * ids exist with a non-zero laid-out box, then captures a full-page PNG plus one
 * clipped PNG per named id, and writes beside each a FACTUAL .json readout
 * (url, title, text excerpt, per-id box + computed colour, console errors) and a
 * one-line .txt caption.
 *
 * It then PROVES the PNG is a real render rather than a blank frame, the way the
 * s190/s201 paint rigs do: it decodes the PNG itself (zlib, node's own) and
 * reports distinct-colour count, the non-background pixel fraction, and the mean
 * channel values. A frame that is one flat colour is reported as NOT PAINTED.
 *
 * Usage:  node spike-drive.js --devtools-port N --url URL --out DIR
 *                             [--places id,id,id] [--timeout MS]
 * Exit:   0 painted · 1 the app did not paint (product) · 77 infrastructure
 */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

function arg(n, d) { const i = process.argv.indexOf("--" + n); return i >= 0 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port");
const URL_ = arg("url");
const OUT = arg("out");
const PLACES = String(arg("places", "")).split(",").map(s => s.trim()).filter(Boolean);
const TIMEOUT = parseInt(arg("timeout", "30000"), 10);
if (!PORT || !URL_ || !OUT) { console.error("spike-drive.js: --devtools-port, --url, --out are required"); process.exit(77); }
fs.mkdirSync(OUT, { recursive: true });

class Infra extends Error {}
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

/* ── the PNG sampler: a screenshot that is one flat colour is NOT a render ── */
function pngStats(buf) {
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) throw new Infra("not a PNG");
  let off = 8, w = 0, h = 0, depth = 0, ctype = -1, interlace = 0; const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off), type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.slice(off + 8, off + 8 + len);
    if (type === "IHDR") { w = data.readUInt32BE(0); h = data.readUInt32BE(4); depth = data[8]; ctype = data[9]; interlace = data[12]; }
    else if (type === "IDAT") idat.push(data);
    else if (type === "IEND") break;
    off += 12 + len;
  }
  if (depth !== 8 || interlace !== 0 || (ctype !== 2 && ctype !== 6)) throw new Infra("unsupported PNG (depth " + depth + ", ctype " + ctype + ")");
  const bpp = ctype === 6 ? 4 : 3, stride = w * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(h * stride);
  let p = 0;
  for (let y = 0; y < h; y++) {
    const f = raw[p++]; const line = raw.slice(p, p + stride); p += stride;
    const cur = out.slice(y * stride, (y + 1) * stride), prev = y ? out.slice((y - 1) * stride, y * stride) : Buffer.alloc(stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0; let v = line[x];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += ((a + b) >> 1);
      else if (f === 4) { const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c); v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c); }
      cur[x] = v & 0xff;
    }
  }
  const counts = new Map(); let sr = 0, sg = 0, sb = 0, n = 0;
  for (let y = 0; y < h; y += 2) for (let x = 0; x < w; x += 2) {
    const o = y * stride + x * bpp, r = out[o], g = out[o + 1], bl = out[o + 2];
    const k = (r << 16) | (g << 8) | bl; counts.set(k, (counts.get(k) || 0) + 1);
    sr += r; sg += g; sb += bl; n++;
  }
  let topKey = 0, topN = 0;
  for (const [k, v] of counts) if (v > topN) { topN = v; topKey = k; }
  const hex = (k) => "#" + k.toString(16).padStart(6, "0");
  return {
    width: w, height: h, sampled: n,
    distinctColours: counts.size,
    dominantColour: hex(topKey),
    dominantFraction: +(topN / n).toFixed(4),
    nonDominantFraction: +(1 - topN / n).toFixed(4),
    mean: { r: Math.round(sr / n), g: Math.round(sg / n), b: Math.round(sb / n) },
    painted: counts.size > 8 && (1 - topN / n) > 0.01,
  };
}

/* ── minimal CDP client over node's global WebSocket ── */
async function connect() {
  let ver;
  for (let i = 0; i < 40; i++) {
    try { ver = await (await fetch("http://127.0.0.1:" + PORT + "/json/version", { signal: AbortSignal.timeout(2000) })).json(); if (ver.webSocketDebuggerUrl) break; } catch (_) {}
    await sleep(250);
  }
  if (!ver || !ver.webSocketDebuggerUrl) throw new Infra("chrome devtools never answered on port " + PORT);
  const ws = new WebSocket(ver.webSocketDebuggerUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Infra("devtools websocket refused")); setTimeout(() => rej(new Infra("devtools websocket timeout")), 10000); });
  let id = 0; const waiting = new Map(); const events = [];
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && waiting.has(msg.id)) { const { res, rej } = waiting.get(msg.id); waiting.delete(msg.id); msg.error ? rej(new Error(msg.error.message)) : res(msg.result); }
    else if (msg.method) events.push(msg);
  };
  const send = (method, params, sessionId) => new Promise((res, rej) => {
    const mid = ++id; waiting.set(mid, { res, rej });
    ws.send(JSON.stringify(sessionId ? { id: mid, method, params: params || {}, sessionId } : { id: mid, method, params: params || {} }));
    setTimeout(() => { if (waiting.has(mid)) { waiting.delete(mid); rej(new Infra("CDP timeout on " + method)); } }, TIMEOUT);
  });
  return { ws, send, events, ver };
}

const READ = (places) => `(function () {
  var ids = ${JSON.stringify(places)};
  function box(el) { var r = el.getBoundingClientRect(); return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }; }
  var out = { url: location.href, title: document.title, textExcerpt: (document.body.innerText || "").replace(/[ \\t\\r\\n]+/g, " ").trim().slice(0, 1200), places: {} };
  ids.forEach(function (id) {
    var el = document.getElementById(id);
    if (!el) { out.places[id] = { present: false }; return; }
    var s = getComputedStyle(el), b = box(el);
    out.places[id] = { present: true, box: b, laidOut: b.w > 0 && b.h > 0, color: s.color, background: s.backgroundColor, fontSize: s.fontSize, text: (el.innerText || "").replace(/[ \\t\\r\\n]+/g, " ").trim().slice(0, 200) };
  });
  return JSON.stringify(out);
})()`;

(async () => {
  const { ws, send, events } = await connect();
  const t = await send("Target.createTarget", { url: "about:blank" });
  const att = await send("Target.attachToTarget", { targetId: t.targetId, flatten: true });
  const S = att.sessionId;
  await send("Runtime.enable", {}, S);
  await send("Log.enable", {}, S);
  await send("Page.enable", {}, S);
  await send("Page.navigate", { url: URL_ }, S);

  const deadline = Date.now() + TIMEOUT;
  let readout = null;
  while (Date.now() < deadline) {
    try {
      const r = await send("Runtime.evaluate", { expression: READ(PLACES), returnByValue: true }, S);
      if (r && r.result && typeof r.result.value === "string") {
        const parsed = JSON.parse(r.result.value);
        const ok = PLACES.length === 0 || PLACES.every(id => parsed.places[id] && parsed.places[id].laidOut);
        if (ok && parsed.textExcerpt) { readout = parsed; break; }
      }
    } catch (_) {}
    await sleep(250);
  }
  if (!readout) { console.error("the app never laid out its named elements at " + URL_); ws.close(); process.exit(1); }

  readout.consoleErrors = events.filter(e => e.method === "Log.entryAdded" && e.params.entry.level === "error").map(e => e.params.entry.text);

  const shots = [];
  async function shoot(name, clip) {
    const p = clip ? { format: "png", clip: { x: clip.x, y: clip.y, width: clip.w, height: clip.h, scale: 1 } }
                   : { format: "png", captureBeyondViewport: true };
    const r = await send("Page.captureScreenshot", p, S);
    const buf = Buffer.from(r.data, "base64");
    const file = path.join(OUT, name + ".png");
    fs.writeFileSync(file, buf);
    const stats = pngStats(buf);
    shots.push({ name, file, clip: clip || "full", pixels: stats });
    fs.writeFileSync(path.join(OUT, name + ".json"), JSON.stringify({ shot: name, capturedAt: new Date().toISOString(), pixels: stats, page: readout }, null, 2));
    fs.writeFileSync(path.join(OUT, name + ".txt"), name + " — " + (clip ? "clipped" : "full page") + " of " + readout.url + " (" + stats.width + "x" + stats.height + "), " + stats.distinctColours + " distinct colours, " + (stats.painted ? "PAINTED" : "FLAT/BLANK") + "\n");
    return stats;
  }

  const full = await shoot("shot-01", null);
  let i = 2;
  for (const id of PLACES) {
    const pl = readout.places[id];
    if (pl && pl.laidOut) await shoot("shot-" + String(i++).padStart(2, "0"), pl.box);
  }

  fs.writeFileSync(path.join(OUT, "readout.json"), JSON.stringify({ url: readout.url, shots, page: readout }, null, 2));
  ws.close();
  const allPainted = shots.every(s => s.pixels.painted);
  console.log(JSON.stringify({ url: readout.url, allPainted, shots: shots.map(s => ({ name: s.name, painted: s.pixels.painted, distinctColours: s.pixels.distinctColours, dominant: s.pixels.dominantColour, nonDominantFraction: s.pixels.nonDominantFraction })) }, null, 2));
  process.exit(allPainted ? 0 : 1);
})().catch((e) => {
  console.error((e instanceof Infra ? "INFRA: " : "ERROR: ") + e.message);
  process.exit(e instanceof Infra ? 77 : 1);
});
