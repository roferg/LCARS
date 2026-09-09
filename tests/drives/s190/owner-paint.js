/* ===========================================================================
 * S190 fix round 1 — the CDP drive behind owner-paint.sh.
 *
 * Three questions, each asked at the layer that can actually answer it:
 *
 *   D2  Does the locked control PAINT at the opacity the stylesheet says, and
 *       is what it paints READABLE? Answered twice, because one answer alone is
 *       exactly the trap: (a) the element's own computed opacity compared with
 *       its EFFECTIVE opacity — the product of every ancestor's, which is what
 *       compositing actually does — so a rule that promises what it cannot keep
 *       is caught structurally; and (b) the ink-to-paper contrast of the real
 *       PIXELS inside the control, read out of a clipped screenshot. (b) is the
 *       only one that would have survived a clever cascade, and (a) is the only
 *       one that names WHY.
 *   D3  Does any loaded rule style `.det-head .owner` while the detail header
 *       renders no owner node at all? Read off document.styleSheets — the sheet
 *       the browser actually built, not the file on disk.
 *   D6  Does a `prefers-reduced-motion` block touch the avatar's colour filter,
 *       and does asking the browser for reduced motion change that filter?
 *
 * S191 fix round 1 adds a fourth, and it is the one the capstone sent back:
 *
 *   D4  CAN YOU TELL, AT A GLANCE, THAT A CONTROL IS LOCKED? The lock was
 *       ENFORCED correctly and it did not READ as locked: a dim of .7 on
 *       saturated LCARS teal is imperceptible, so a locked `▶ START` and a live
 *       `▶ START` were the same button. Asked of the PAINT, on two cards that
 *       differ in exactly one fact — the same stage, the same column, one mine
 *       and one someone else's — by comparing the FILL each control paints. The
 *       floor is 3:1, which is WCAG's own number for two UI states that must be
 *       told apart. Measured before the cure: 1.84:1.
 *
 * Exit: 0 all green · 1 a check failed · 77 infrastructure (never a pass).
 * =========================================================================== */
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

function arg(name, dflt) {
  const i = process.argv.indexOf("--" + name);
  return i === -1 ? dflt : process.argv[i + 1];
}
const DEVTOOLS_PORT = arg("devtools-port");
const URL_ = arg("url");
const OUT = arg("out", ".");
const TIMEOUT = parseInt(arg("timeout", "45000"), 10);
const deadline = Date.now() + TIMEOUT;

class InfraError extends Error {}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* ── the PNG reader, lifted verbatim from tests/drives/browser/cdp.js ────────
 * Copied rather than imported: cdp.js is an executable drive, not a module, and
 * `require`ing it would run its main(). It reads 8-bit non-interlaced RGB/RGBA
 * — the whole of what a Chrome screenshot is — and FAILS LOUD on anything else
 * rather than quietly returning black, which is the reassuring-output-proving-
 * nothing shape this rig exists to avoid. */
function pngPixels(buf) {
  if (buf.length < 8 || buf.readUInt32BE(0) !== 0x89504e47) {
    throw new InfraError("screenshot is not a PNG");
  }
  let off = 8, w = 0, h = 0, depth = 0, ctype = -1, interlace = 0;
  const idat = [];
  while (off + 8 <= buf.length) {
    const len = buf.readUInt32BE(off);
    const type = buf.toString("ascii", off + 4, off + 8);
    const data = buf.slice(off + 8, off + 8 + len);
    if (type === "IHDR") {
      w = data.readUInt32BE(0); h = data.readUInt32BE(4);
      depth = data[8]; ctype = data[9]; interlace = data[12];
    } else if (type === "IDAT") { idat.push(data); }
    else if (type === "IEND") { break; }
    off += 12 + len;
  }
  if (depth !== 8 || interlace !== 0 || (ctype !== 2 && ctype !== 6)) {
    throw new InfraError("unsupported PNG (depth " + depth + ", colour type " +
      ctype + ", interlace " + interlace + ")");
  }
  const bpp = ctype === 6 ? 4 : 3;
  const stride = w * bpp;
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const out = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y++) {
    const ft = raw[y * (stride + 1)];
    const line = raw.slice(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride);
    const cur = out.slice(y * stride, (y + 1) * stride);
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? cur[x - bpp] : 0;
      const b = y > 0 ? out[(y - 1) * stride + x] : 0;
      const c = (x >= bpp && y > 0) ? out[(y - 1) * stride + x - bpp] : 0;
      let v = line[x];
      if (ft === 1) v += a;
      else if (ft === 2) v += b;
      else if (ft === 3) v += (a + b) >> 1;
      else if (ft === 4) {
        const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b),
              pc = Math.abs(p - c);
        v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
      } else if (ft !== 0) { throw new InfraError("unknown PNG row filter " + ft); }
      cur[x] = v & 0xff;
    }
  }
  return { w, h, bpp, px: out };
}

/* WCAG relative luminance and contrast, on sRGB 0-255 triples. */
function lum(r, g, b) {
  const f = (c) => { c /= 255; return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}
function contrast(a, b) {
  const la = lum(a[0], a[1], a[2]), lb = lum(b[0], b[1], b[2]);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

/* INK AND PAPER, from the pixels of one small control.
 *
 * A button is mostly its background with glyphs cut into it, and the question
 * "can this be read" is the contrast between the darkest thing on it and the
 * lightest. Percentiles, not min/max: a single antialiased outlier pixel would
 * otherwise decide the verdict. p04/p96 sit clear of the antialiasing fringe on
 * 10px type at scale 4 and are stable across re-runs. */
function inkAndPaper(png) {
  const n = png.w * png.h;
  if (!n) throw new InfraError("sampled an empty patch");
  const rows = [];
  for (let i = 0; i < n; i++) {
    const o = i * png.bpp;
    rows.push([lum(png.px[o], png.px[o + 1], png.px[o + 2]),
               png.px[o], png.px[o + 1], png.px[o + 2]]);
  }
  rows.sort((a, b) => a[0] - b[0]);
  const at = (q) => {
    const i = Math.min(n - 1, Math.max(0, Math.round(q * (n - 1))));
    return [rows[i][1], rows[i][2], rows[i][3]];
  };
  const dark = at(0.04), light = at(0.96);
  return { dark, light, contrast: contrast(dark, light), samples: n };
}

/* THE FILL A CONTROL PAINTS, as one colour. The MEDIAN pixel, not the mean: a
 * button is a slab of background with glyphs cut into it, so the middle of the
 * sorted-by-luminance distribution is the slab and an average would be the slab
 * pulled towards its own text. This is the number "does it look like the live
 * one?" is actually about — fill is what the eye reads across a room, long
 * before it reads a 10px label. */
function fill(png) {
  const n = png.w * png.h;
  if (!n) throw new InfraError("sampled an empty patch");
  const rows = [];
  for (let i = 0; i < n; i++) {
    const o = i * png.bpp;
    rows.push([lum(png.px[o], png.px[o + 1], png.px[o + 2]),
               png.px[o], png.px[o + 1], png.px[o + 2]]);
  }
  rows.sort((a, b) => a[0] - b[0]);
  const m = rows[Math.floor(n / 2)];
  return [m[1], m[2], m[3]];
}

/* ── a minimal CDP client over the global WebSocket ───────────────────────── */
class CDP {
  constructor(ws) {
    this.ws = ws; this.next = 1; this.pending = new Map(); this.pageErrors = [];
    ws.addEventListener("message", (ev) => {
      let msg; try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.method + ": " + JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      if (msg.method === "Runtime.exceptionThrown") {
        const d = (msg.params && msg.params.exceptionDetails) || {};
        this.pageErrors.push(String(d.text));
      }
    });
  }
  send(method, params, sessionId) {
    const id = this.next++;
    const payload = { id, method, params: params || {} };
    if (sessionId) payload.sessionId = sessionId;
    this.ws.send(JSON.stringify(payload));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject: (e) => reject(new Error(method + " → " + e.message)) });
    });
  }
}
function connect(url) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    ws.addEventListener("open", () => resolve(ws), { once: true });
    ws.addEventListener("error", () => reject(new Error("websocket refused: " + url)), { once: true });
  });
}

/* ── the probes, all of which run INSIDE real Chrome ─────────────────────── */

const READY = `(function () {
  var cards = document.querySelectorAll(".card");
  return { cards: cards.length,
           locked: document.querySelectorAll(".card.owned-by-other").length,
           owners: document.querySelectorAll(".card .owner").length,
           pair: !!(document.querySelector('.card[data-mid="m-align-mine"]') &&
                    document.querySelector('.card[data-mid="m-align-theirs"]')) };
})()`;

/* D2. The locked card's control row, measured element by element.
 *
 * `effective` is the product of every ancestor's computed opacity up to <html>
 * — which is what the compositor does and what the eye sees. `own` is what the
 * cascade told this element. When they differ, some ancestor made a compositing
 * group and every promise made inside it is unkeepable. */
const LOCK_PROBE = `(function () {
  function eff(el) {
    var o = 1, n = el;
    while (n && n.nodeType === 1) {
      var v = parseFloat(getComputedStyle(n).opacity || "1");
      if (!isNaN(v)) o *= v;
      n = n.parentElement;
    }
    return o;
  }
  var card = document.querySelector(".card.owned-by-other");
  if (!card) return { present: false };
  var ctrl = card.querySelector(".card-ctrl");
  var btns = ctrl ? Array.prototype.slice.call(ctrl.querySelectorAll("button")) : [];
  var kids = ctrl ? Array.prototype.slice.call(ctrl.children) : [];
  // A card of MY OWN, in the same run: the positive control that says the dim
  // is a statement about ownership and not something the whole board caught.
  var mine = document.querySelector(".card:not(.owned-by-other) .card-ctrl button");
  var cardBox = card.getBoundingClientRect();
  return {
    present: true,
    ctrlOpacity: ctrl ? parseFloat(getComputedStyle(ctrl).opacity || "1") : null,
    ctrlChildren: kids.map(function (k) {
      return { tag: k.tagName, disabled: !!k.disabled };
    }),
    mine: mine ? { text: (mine.textContent || "").trim(), disabled: !!mine.disabled,
                   own: parseFloat(getComputedStyle(mine).opacity || "1"),
                   effective: eff(mine) } : null,
    cardBox: { x: cardBox.x, y: cardBox.y, w: cardBox.width, h: cardBox.height },
    buttons: btns.map(function (b) {
      var r = b.getBoundingClientRect();
      var s = getComputedStyle(b);
      return {
        text: (b.textContent || "").trim(),
        disabled: !!b.disabled,
        title: b.title || "",
        own: parseFloat(s.opacity || "1"),
        effective: eff(b),
        bg: s.backgroundColor, color: s.color, fontSize: s.fontSize,
        box: { x: r.x, y: r.y, w: r.width, h: r.height }
      };
    })
  };
})()`;

/* D3 + D6. Every rule the browser actually BUILT, from every same-origin sheet.
 * The file on disk is not the question — a rule can be dropped as invalid, or
 * live in a sheet that never loaded. This walks what is live. */
const SHEET_PROBE = `(function () {
  var out = { detHeadOwnerRules: [], reducedMotionFilterRules: [],
              sheets: [], unreadable: 0 };
  function walk(rules, media) {
    for (var i = 0; i < rules.length; i++) {
      var r = rules[i];
      if (r.media && r.cssRules) { walk(r.cssRules, String(r.conditionText || r.media.mediaText || "")); continue; }
      if (r.cssRules && !r.selectorText) { walk(r.cssRules, media); continue; }
      var sel = r.selectorText || "";
      if (/\\.det-head\\b/.test(sel) && /\\.owner\\b/.test(sel)) {
        out.detHeadOwnerRules.push({ selector: sel, css: r.cssText, media: media });
      }
      if (/prefers-reduced-motion/.test(media) && /\\bfilter\\b/.test(r.cssText || "")) {
        out.reducedMotionFilterRules.push({ selector: sel, css: r.cssText, media: media });
      }
    }
  }
  var links = Array.prototype.slice.call(document.styleSheets);
  for (var i = 0; i < links.length; i++) {
    var sh = links[i];
    try {
      if (!sh.cssRules) { out.unreadable++; continue; }
      out.sheets.push({ href: sh.href, rules: sh.cssRules.length });
      walk(sh.cssRules, "");
    } catch (e) { out.unreadable++; }
  }
  return out;
})()`;

/* D4. THE PAIR. Two cards at the same stage whose ONLY difference is ownership,
 * each reduced to its first control-row button: the label (does it wear the lock
 * mark?), the box (so the pixels can be read), and the geometry of both cards
 * together (so one screenshot frames them identically, which is how a captain
 * actually compares them — side by side, not one at a time). */
const PAIR_PROBE = `(function () {
  function ctrl(mid) {
    var card = document.querySelector('.card[data-mid="' + mid + '"]');
    if (!card) return null;
    var b = card.querySelector(".card-ctrl button");
    if (!b) return null;
    var r = b.getBoundingClientRect(), cr = card.getBoundingClientRect();
    var s = getComputedStyle(b);
    var all = Array.prototype.slice.call(card.querySelectorAll(".card-ctrl button"));
    return {
      text: (b.textContent || "").trim(),
      labels: all.map(function (x) { return (x.textContent || "").trim(); }),
      disabled: !!b.disabled,
      bg: s.backgroundColor, color: s.color, borderColor: s.borderTopColor,
      box: { x: r.x, y: r.y, w: r.width, h: r.height },
      cardBox: { x: cr.x, y: cr.y, w: cr.width, h: cr.height }
    };
  }
  var mine = ctrl("m-align-mine"), theirs = ctrl("m-align-theirs");
  var pairBox = null;
  if (mine && theirs) {
    var x0 = Math.min(mine.cardBox.x, theirs.cardBox.x);
    var y0 = Math.min(mine.cardBox.y, theirs.cardBox.y);
    var x1 = Math.max(mine.cardBox.x + mine.cardBox.w,
                      theirs.cardBox.x + theirs.cardBox.w);
    var y1 = Math.max(mine.cardBox.y + mine.cardBox.h,
                      theirs.cardBox.y + theirs.cardBox.h);
    pairBox = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }
  return { mine: mine, theirs: theirs, pairBox: pairBox };
})()`;

/* EVERY locked control on the whole board, not just the first card's. The
 * contrast floor is a promise about the treatment, and the treatment is applied
 * by one rule to every stage's control row — so the weakest one on screen is the
 * one that has to clear it, not whichever card happens to render first. */
const ALL_LOCKED_PROBE = `(function () {
  var out = [];
  var btns = document.querySelectorAll(".card.owned-by-other .card-ctrl button");
  for (var i = 0; i < btns.length; i++) {
    var b = btns[i], r = b.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) continue;
    out.push({ text: (b.textContent || "").trim(),
               box: { x: r.x, y: r.y, w: r.width, h: r.height } });
  }
  return out;
})()`;

const DETAIL_PROBE = `(function () {
  var head = document.querySelector(".det-head");
  if (!head) return { open: false };
  return {
    open: true,
    ownerNodes: head.querySelectorAll(".owner").length,
    text: (head.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 200)
  };
})()`;

const AVATAR_PROBE = `(function () {
  var img = document.querySelector(".owner .owner-av img");
  if (!img) return { present: false,
                     deadPills: document.querySelectorAll(".owner.dead").length };
  var s = getComputedStyle(img);
  return { present: true, filter: s.filter,
           naturalWidth: img.naturalWidth, naturalHeight: img.naturalHeight,
           complete: !!img.complete };
})()`;

/* ── the run ─────────────────────────────────────────────────────────────── */
const findings = [];
let failures = 0, skips = 0;
function ok(name, detail) { findings.push({ name, ok: true, detail });
  console.log("  \x1b[32mPASS\x1b[0m  " + name + (detail ? "\n          " + detail : "")); }
function bad(name, detail) { findings.push({ name, ok: false, detail }); failures++;
  console.log("  \x1b[31mFAIL\x1b[0m  " + name + (detail ? "\n          " + detail : "")); }
function skip(name, detail) { findings.push({ name, ok: null, detail }); skips++;
  console.log("  \x1b[33mSKIP\x1b[0m  " + name + (detail ? "\n          " + detail : "")); }

async function evaluate(cdp, sessionId, expr) {
  const r = await cdp.send("Runtime.evaluate",
    { expression: expr, returnByValue: true, awaitPromise: false }, sessionId);
  if (r && r.exceptionDetails) throw new InfraError("probe threw: " + r.exceptionDetails.text);
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

async function main() {
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
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Runtime.enable", {}, sessionId);
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);
  await cdp.send("Page.navigate", { url: URL_ }, sessionId);

  // Wait for the board to PAINT the fixture — and specifically for the locked
  // card, because a board that painted without one would make every check below
  // vacuously pass.
  let ready = null;
  while (Date.now() < deadline) {
    try { ready = await evaluate(cdp, sessionId, READY); } catch (e) { ready = null; }
    if (ready && ready.cards >= 2 && ready.locked >= 1 && ready.owners >= 2) break;
    await sleep(250);
  }
  if (!ready) throw new InfraError("the page was never probed before the deadline");
  if (!(ready.cards >= 2)) throw new InfraError("the board did not paint its 2 fixture cards (saw " + ready.cards + ")");
  if (!(ready.locked >= 1)) throw new InfraError("no .card.owned-by-other rendered — the fixture's lock never applied");
  if (!ready.pair) throw new InfraError("the align pair (m-align-mine / m-align-theirs) never rendered — D4 cannot be measured");
  // The avatar is a real network image; give it a beat to arrive or to fail.
  await sleep(1500);

  // WIDEN THE VIEWPORT TO THE BOARD'S OWN SCROLL EXTENT before measuring
  // anything. The Stage columns scroll HORIZONTALLY inside #board, so at 1440px
  // the Verify column — where this fixture's two cards live — sits past the
  // right edge with a bounding rect of x≈1760. A screenshot clip there captures
  // bare page background, and an ink/paper reading off bare background is a
  // confident 1.00:1 about nothing. (Measured exactly that on the first run of
  // this drive.) cdp.js does the same thing for the same reason.
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

  await shoot(cdp, sessionId, { x: 0, y: 0, w: fit.w, h: fit.h }, "board.png", 1, 0);

  // ── D2 ────────────────────────────────────────────────────────────────
  console.log("\nD2 — the locked control row, as PAINTED");
  const lock = await evaluate(cdp, sessionId, LOCK_PROBE);
  if (!lock || !lock.present) throw new InfraError("no locked card to measure");
  const ctrlButtons = (lock.buttons || []).filter((b) => b.box.w > 0 && b.box.h > 0);
  if (!ctrlButtons.length) throw new InfraError("the locked card's control row has no laid-out button");

  for (const b of ctrlButtons) {
    const label = JSON.stringify(b.text.slice(0, 40));
    if (Math.abs(b.own - b.effective) > 0.001) {
      bad("the row keeps every opacity promise it makes about " + label,
          "computed opacity " + b.own + " but PAINTS at " + b.effective.toFixed(3) +
          " — an ancestor made a compositing group, so a child rule cannot " +
          "raise this control back out of it (row opacity " + lock.ctrlOpacity + ")");
    } else {
      ok("the row keeps every opacity promise it makes about " + label,
         "computed " + b.own + " == painted " + b.effective.toFixed(3));
    }
  }

  // EVERY child of the row is a disabled button — which is why moving the dim
  // off the row and onto the controls loses nothing. If a non-button child ever
  // appears here, the row stops being uniformly dimmed and this says so.
  const strays = (lock.ctrlChildren || []).filter((k) => k.tag !== "BUTTON" || !k.disabled);
  if (strays.length === 0) {
    ok("every child of the locked control row is a disabled <button>",
       (lock.ctrlChildren || []).length + " children, all disabled buttons — the " +
       "per-control dim covers the whole row");
  } else {
    bad("every child of the locked control row is a disabled <button>",
        "strays: " + JSON.stringify(strays));
  }

  // THE POSITIVE CONTROL. My own card in the same board must be untouched — a
  // dim that fell on everything would pass every check above and mean nothing.
  if (!lock.mine) {
    skip("my OWN card's control is live and undimmed", "no unlocked card with a control");
  } else if (!lock.mine.disabled && Math.abs(lock.mine.effective - 1) < 0.001) {
    ok("my OWN card's control is live and undimmed",
       JSON.stringify(lock.mine.text.slice(0, 40)) + " enabled, painting at 1");
  } else {
    bad("my OWN card's control is live and undimmed", JSON.stringify(lock.mine));
  }

  // …and the pixels. The ⊘ owner label is the one that matters: it is the
  // smallest type in the row and the only place the reason for the lock is
  // written, so it is the control the guarantee is about.
  const target = ctrlButtons.find((b) => /⊘/.test(b.text)) || ctrlButtons[0];
  const buf = await shoot(cdp, sessionId, target.box, "locked-control.png", 4, 0);
  const px = pngPixels(buf);
  const ip = inkAndPaper(px);
  const detail = "ink rgb(" + ip.dark.join(",") + ") vs paper rgb(" +
    ip.light.join(",") + ") → " + ip.contrast.toFixed(2) + ":1 over " +
    ip.samples + " sampled pixels (locked-control.png)";
  if (ip.contrast >= 4.5) {
    ok("the locked control is READABLE in the actual pixels (>= 4.5:1)", detail);
  } else {
    bad("the locked control is READABLE in the actual pixels (>= 4.5:1)", detail);
  }
  await shoot(cdp, sessionId, lock.cardBox, "locked-card.png", 3, 8);

  // ── D4 (S191 fix round 1) ─────────────────────────────────────────────
  console.log("\nD4 — can you SEE that a control is locked?");
  const pair = await evaluate(cdp, sessionId, PAIR_PROBE);
  if (!pair || !pair.mine || !pair.theirs) {
    throw new InfraError("the align pair did not both render a control button");
  }
  if (!pair.theirs.disabled) {
    bad("the locked card's control is actually disabled",
        "the fixture's lock never reached the control row — nothing below means anything");
  }
  // ONE FRAME, BOTH CARDS. This is the artefact a human looks at, and it is
  // deliberately a single clip rather than two files pasted together: identical
  // framing is not something the rig has to promise, it is a property of the
  // screenshot.
  await shoot(cdp, sessionId, pair.pairBox, "locked-vs-live.png", 3, 10);

  // …and the measurement. Each control's own FILL, from its own pixels.
  const liveFill = fill(pngPixels(
    await shoot(cdp, sessionId, pair.mine.box, "live-control.png", 4, 0)));
  const lockFill = fill(pngPixels(
    await shoot(cdp, sessionId, pair.theirs.box, "locked-control-align.png", 4, 0)));
  const sep = contrast(lockFill, liveFill);
  const sepDetail = "locked fill rgb(" + lockFill.join(",") + ") vs live fill rgb(" +
    liveFill.join(",") + ") → " + sep.toFixed(2) + ":1 " +
    "(locked-vs-live.png — LOOK AT THIS ONE)";
  // 3:1 is WCAG 1.4.11's threshold for non-text UI state, i.e. the standard's own
  // answer to "are these two states distinguishable?". The shipped .7 dim scored
  // 1.84:1 against it.
  if (sep >= 3.0) {
    ok("a locked control and a live one PAINT differently (>= 3:1)", sepDetail);
  } else {
    bad("a locked control and a live one PAINT differently (>= 3:1)", sepDetail);
  }
  // …and it must not be the WHOLE BOARD that went quiet. A cure that dimmed
  // everything would score beautifully above and say nothing.
  if (pair.mine.disabled) {
    bad("my own card's control is still live", "the live control is disabled too");
  } else {
    ok("my own card's control is still live",
       JSON.stringify(pair.mine.text) + " enabled, fill rgb(" + liveFill.join(",") + ")");
  }
  // THE LOCK MARK. `⊘` is already the glyph the Verify lock label wears and the
  // one a tester read at 3x and called native. Every control in a locked row
  // wears it, and no control in a live row does — a label that still opens with
  // `▶` is a control claiming it will go.
  const unmarked = (pair.theirs.labels || []).filter((t) => t.indexOf("⊘") !== 0);
  if (unmarked.length === 0 && (pair.theirs.labels || []).length > 0) {
    ok("every control in the locked row opens with the ⊘ lock mark",
       JSON.stringify(pair.theirs.labels));
  } else {
    bad("every control in the locked row opens with the ⊘ lock mark",
        "unmarked: " + JSON.stringify(unmarked));
  }
  const wronglyMarked = (pair.mine.labels || []).filter((t) => t.indexOf("⊘") === 0);
  if (wronglyMarked.length === 0) {
    ok("no control in the LIVE row wears the lock mark",
       JSON.stringify(pair.mine.labels));
  } else {
    bad("no control in the LIVE row wears the lock mark",
        JSON.stringify(wronglyMarked));
  }

  // …and the floor holds for EVERY locked control on the board, at every stage,
  // not only the one D2 happened to sample. `⊘ picard's mission` at Verify is
  // 34 characters of 10px display type; `⊘ Start` at Align is six. One rule
  // paints both, and both have to be readable.
  const allLocked = await evaluate(cdp, sessionId, ALL_LOCKED_PROBE) || [];
  if (!allLocked.length) {
    bad("every locked control on the board is legible (>= 4.5:1)",
        "no locked control was laid out at all");
  } else {
    let worst = null;
    for (let i = 0; i < allLocked.length; i++) {
      const c = allLocked[i];
      const m = inkAndPaper(pngPixels(
        await shoot(cdp, sessionId, c.box, "locked-ctrl-" + i + ".png", 4, 0)));
      if (!worst || m.contrast < worst.c) worst = { c: m.contrast, t: c.text, m: m };
    }
    const wd = allLocked.length + " locked control(s); worst is " +
      JSON.stringify(worst.t) + " at " + worst.c.toFixed(2) + ":1 " +
      "(ink rgb(" + worst.m.dark.join(",") + ") vs paper rgb(" +
      worst.m.light.join(",") + "))";
    if (worst.c >= 4.5) {
      ok("every locked control on the board is legible (>= 4.5:1)", wd);
    } else {
      bad("every locked control on the board is legible (>= 4.5:1)", wd);
    }
  }

  // ── D3 ────────────────────────────────────────────────────────────────
  console.log("\nD3 — no rule for something that never renders");
  const sheets = await evaluate(cdp, sessionId, SHEET_PROBE);
  if (!sheets || !sheets.sheets.length) throw new InfraError("no same-origin stylesheet was readable");
  // Open the detail the way a click does, and count what is actually there.
  await evaluate(cdp, sessionId,
    `(function(){var c=document.querySelector(".card.owned-by-other");if(c)c.click();return 1})()`);
  let det = null;
  for (let i = 0; i < 40 && Date.now() < deadline; i++) {
    det = await evaluate(cdp, sessionId, DETAIL_PROBE);
    if (det && det.open) break;
    await sleep(150);
  }
  if (!det || !det.open) {
    skip("the detail header renders no owner pill", "the detail overlay never opened");
  } else if (det.ownerNodes === 0) {
    ok("the detail header renders no owner pill (0 nodes)",
       "header text: " + JSON.stringify(det.text.slice(0, 90)));
  } else {
    // Not a failure of this round: it would mean the header GAINED a pill, and
    // then the rule below is alive and correct. Say so plainly.
    ok("the detail header renders " + det.ownerNodes + " owner pill(s)",
       "the .det-head .owner rule would be live — this drive's D3 check no longer applies");
  }
  if (det && det.open && det.ownerNodes === 0 && sheets.detHeadOwnerRules.length) {
    bad("no loaded rule styles `.det-head .owner` while nothing renders there",
        sheets.detHeadOwnerRules.map((r) => r.css).join(" | "));
  } else if (sheets.detHeadOwnerRules.length === 0) {
    ok("no loaded rule styles `.det-head .owner`", "0 such rules in the built sheets");
  }
  // Close the overlay again so the avatar probe reads the BOARD's pill.
  await evaluate(cdp, sessionId,
    `(function(){var o=document.querySelector(".overlay");if(o&&!o.hidden)o.click();return 1})()`);
  await sleep(300);

  // ── D6 ────────────────────────────────────────────────────────────────
  console.log("\nD6 — a colour treatment is not gated on a motion preference");
  if (sheets.reducedMotionFilterRules.length === 0) {
    ok("no `prefers-reduced-motion` block touches a `filter`", "0 such rules");
  } else {
    bad("no `prefers-reduced-motion` block touches a `filter`",
        sheets.reducedMotionFilterRules.map((r) => r.media + " { " + r.css + " }").join(" | "));
  }
  const base = await evaluate(cdp, sessionId, AVATAR_PROBE);
  if (!base || !base.present) {
    skip("asking for reduced motion does not change the avatar's colour filter",
         "no live avatar <img> on the board — github.com's avatar did not load, so " +
         "board.js removed the cap (" + ((base && base.deadPills) || 0) + " .owner.dead). " +
         "NOT a pass: the behavioural half of D6 was not measured.");
  } else if (!base.naturalWidth) {
    skip("asking for reduced motion does not change the avatar's colour filter",
         "the <img> is present but decoded 0x0");
  } else {
    await cdp.send("Emulation.setEmulatedMedia",
      { features: [{ name: "prefers-reduced-motion", value: "reduce" }] }, sessionId);
    await sleep(250);
    const reduced = await evaluate(cdp, sessionId, AVATAR_PROBE);
    await cdp.send("Emulation.setEmulatedMedia", { features: [] }, sessionId);
    if (reduced && reduced.filter === base.filter) {
      ok("asking for reduced motion does not change the avatar's colour filter",
         "filter stays " + JSON.stringify(base.filter));
    } else {
      bad("asking for reduced motion does not change the avatar's colour filter",
          "default " + JSON.stringify(base.filter) + " → reduced-motion " +
          JSON.stringify(reduced && reduced.filter));
    }
    // …and the feature the treatment DOES belong to. The escape hatch moved
    // here rather than being deleted: a reader who has asked the OS for more
    // contrast wants the untouched portrait, and THAT is a colour preference.
    // Asserted, not noted — a relocated rule nobody watches fire is a rule that
    // has merely been moved somewhere quieter.
    await cdp.send("Emulation.setEmulatedMedia",
      { features: [{ name: "prefers-contrast", value: "more" }] }, sessionId);
    await sleep(250);
    const more = await evaluate(cdp, sessionId, AVATAR_PROBE);
    await cdp.send("Emulation.setEmulatedMedia", { features: [] }, sessionId);
    if (more && more.filter === "none" && base.filter !== "none") {
      ok("asking for MORE CONTRAST does drop the colour filter",
         JSON.stringify(base.filter) + " → " + JSON.stringify(more.filter));
    } else {
      bad("asking for MORE CONTRAST does drop the colour filter",
          "default " + JSON.stringify(base.filter) + " → prefers-contrast:more " +
          JSON.stringify(more && more.filter));
    }
  }

  fs.writeFileSync(path.join(OUT, "owner-paint.json"), JSON.stringify({
    lock, pair, fills: { live: liveFill, locked: lockFill, separation: sep },
    sheets, detail: det, avatar: base, inkAndPaper: ip,
    findings, pageErrors: cdp.pageErrors,
  }, null, 2) + "\n");

  console.log("\nscreenshots: " + path.join(OUT, "locked-vs-live.png") +
              "  (LOOK AT THIS ONE — the pair, one frame)");
  console.log("             " + path.join(OUT, "locked-card.png"));
  console.log("             " + path.join(OUT, "locked-control.png") +
              "  (the 4x clip the contrast was read from)");
  console.log("             " + path.join(OUT, "board.png"));
  if (cdp.pageErrors.length) console.log("page errors: " + cdp.pageErrors.length);
  return failures === 0 ? 0 : 1;
}

main().then((code) => {
  if (skips) console.log("\n\x1b[33m" + skips + " check(s) SKIPPED — a skip is not a pass.\x1b[0m");
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
