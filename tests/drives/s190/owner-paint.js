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
 * S196 half B adds three more, and the whole reason they are HERE and not in a
 * second rig is that they are the same question about the same board:
 *
 *   B1  CAN YOU TELL WHOSE MISSION IT IS WITH THE COLOUR TAKEN AWAY? Ownership
 *       was hue alone (amber/blue, 1.51:1 in luminance). Answered by applying
 *       `grayscale(1)` in real Chrome and re-reading the pixels THROUGH it —
 *       and by checking r == g == b, so a filter that silently failed to apply
 *       cannot return a colour reading wearing a greyscale label.
 *   B2  DOES A REMOTE CONTROL THAT CANNOT BE USED LOOK LIKE IT? Measured on the
 *       DETAIL row, which is where a locked control and the live Adopt still
 *       sit side by side — the card no longer draws one (B3), which is the only
 *       reason its own 1.79:1 pair is gone.
 *   B3  DOES A REMOTE CARD DRAW A CONTROL IT CANNOT HONOUR? Asked as a count of
 *       disabled children, not as a property of one of them.
 *   B5  CAN THE BOARD BE ASKED A QUESTION, AND DOES ASKING COST ANYTHING? The
 *       ownership filter, driven the way a captain drives it — chips clicked,
 *       `o` dispatched as a real key event, the page really reloaded — with the
 *       verdict read off what the board DREW. And the constraint it lives
 *       under, which is the reason this check is here rather than in a unit
 *       test: fifty filter applications inside ONE synchronous JS turn, the
 *       page's own fetch counter read either side of it, and the `gh` shim's
 *       log counted either side of that. A unit harness calls render() itself
 *       and can see neither.
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
    // S196: requests held by Fetch.enable. Pausing the avatar's own GET is the
    // only honest way to put the board into the state this session is about —
    // a portrait that is PENDING, which is neither loaded nor failed and is
    // therefore the one state no event ever announces.
    this.paused = [];
    ws.addEventListener("message", (ev) => {
      let msg; try { msg = JSON.parse(ev.data); } catch (e) { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.method + ": " + JSON.stringify(msg.error)));
        else resolve(msg.result);
        return;
      }
      if (msg.method === "Fetch.requestPaused") {
        this.paused.push(msg.params || {});
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
  // S196: …and NOT a remote one. The fixture now carries remote cards too, whose
  // one live control is ADOPT; picking that as "my own live control" would
  // measure the wrong button. This drive's D2/D4 subject is the LOCAL board.
  var mine = document.querySelector(
    ".card:not(.owned-by-other):not(.remote) .card-ctrl button");
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

/* ─────────────── S196 HALF B ───────────────────────────────────────────── */

/* B1. THE OWNER PILL, on the pair of cards that differ in exactly one fact.
 * Ownership used to be carried by HUE ALONE (amber = mine, blue = theirs), and
 * hue is the one channel a greyscale screenshot, a projector and a red-green
 * colourblind reader all throw away. This reads the two pills' boxes so their
 * PIXELS can be compared — in colour and again with the page desaturated — plus
 * the computed background and border-style, which is the structural half:
 * "solid vs hollow" is a claim about the cascade that the pixels then confirm. */
const OWNER_PILL_PROBE = `(function () {
  function pill(mid) {
    var card = document.querySelector('.card[data-mid="' + mid + '"]');
    if (!card) return null;
    var p = card.querySelector(".owner");
    if (!p) return null;
    var handle = p.querySelector(".owner-handle");
    var r = p.getBoundingClientRect();
    var hs = handle ? getComputedStyle(handle) : null;
    return {
      box: { x: r.x, y: r.y, w: r.width, h: r.height },
      text: (p.textContent || "").trim(),
      bg: hs ? hs.backgroundColor : null,
      color: hs ? hs.color : null,
      borderStyle: hs ? hs.borderTopStyle : null,
      borderColor: hs ? hs.borderTopColor : null
    };
  }
  return { mine: pill("m-align-mine"), theirs: pill("m-align-theirs") };
})()`;

/* S197. THE MISSION THAT ALREADY SHIPPED, FROM SOMEWHERE ELSE.
 *
 * `m-mine` and `m-shipped-mine` are IDENTICAL on disk — same stage, same owner,
 * same open PR recorded in state.json. The only difference between them lives
 * on the forge: `m-shipped-mine`'s issue (#106) is CLOSED and wears
 * `lcars:done`, and #101 is not in the listing at all. So every difference this
 * probe reports is the cure, and nothing else can be.
 *
 * It reads BOTH cards so the pair can be shot in one frame and compared the way
 * a captain compares them — side by side — and it reports the CARD's own left
 * edge as well as the controls, because "solid = actionable, hollow/dashed =
 * not" is a claim about the card at across-the-room distance and about the
 * control at reading distance, and the two are measured separately. */
const SHIPPED_PROBE = `(function () {
  function read(mid) {
    var card = document.querySelector('.card[data-mid="' + mid + '"]');
    if (!card) return null;
    var cs = getComputedStyle(card);
    var r = card.getBoundingClientRect();
    var btns = Array.prototype.slice.call(
      card.querySelectorAll(".card-ctrl button"));
    return {
      mid: mid,
      cls: String(card.className || ""),
      edgeStyle: cs.borderLeftStyle,
      text: (card.textContent || "").replace(/\\s+/g, " ").trim(),
      cardBox: { x: r.x, y: r.y, w: r.width, h: r.height },
      controls: btns.map(function (b) {
        var br = b.getBoundingClientRect(), bs = getComputedStyle(b);
        return {
          text: (b.textContent || "").trim(),
          disabled: !!b.disabled,
          title: String(b.title || ""),
          cls: String(b.className || ""),
          bg: bs.backgroundColor, borderStyle: bs.borderTopStyle,
          box: { x: br.x, y: br.y, w: br.width, h: br.height }
        };
      })
    };
  }
  var live = read("m-mine"), over = read("m-shipped-mine");
  var pairBox = null;
  if (live && over) {
    var x0 = Math.min(live.cardBox.x, over.cardBox.x);
    var y0 = Math.min(live.cardBox.y, over.cardBox.y);
    var x1 = Math.max(live.cardBox.x + live.cardBox.w,
                      over.cardBox.x + over.cardBox.w);
    var y1 = Math.max(live.cardBox.y + live.cardBox.h,
                      over.cardBox.y + over.cardBox.h);
    pairBox = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }
  return { live: live, over: over, pairBox: pairBox,
           remoteMids: Array.prototype.slice.call(
             document.querySelectorAll(".card.remote")).map(function (c) {
               return c.getAttribute("data-mid"); }) };
})()`;

/* B3 + B4. EVERY REMOTE CARD's control row, child by child.
 *
 * The question B3 asks is not "does the dead control look right" — it is
 * "is it there at all". So this reports every child of the row with its tag,
 * its disabled state and its label, and the checks below assert an EMPTY set of
 * disabled controls rather than a property of one. */
const REMOTE_PROBE = `(function () {
  var out = [];
  var cards = document.querySelectorAll(".card.remote");
  for (var i = 0; i < cards.length; i++) {
    var c = cards[i];
    var ctrl = c.querySelector(".card-ctrl");
    var kids = ctrl ? Array.prototype.slice.call(ctrl.children) : [];
    var cr = c.getBoundingClientRect();
    out.push({
      mid: c.getAttribute("data-mid"),
      stage: (function () {
        var n = c.querySelector(".no");
        return n ? (n.textContent || "").trim() : "";
      })(),
      hasCtrlRow: !!ctrl,
      cardBox: { x: cr.x, y: cr.y, w: cr.width, h: cr.height },
      children: kids.map(function (k) {
        var r = k.getBoundingClientRect();
        var st = getComputedStyle(k);
        return {
          tag: k.tagName, cls: String(k.className || ""),
          text: (k.textContent || "").trim(), disabled: !!k.disabled,
          bg: st.backgroundColor, borderStyle: st.borderTopStyle,
          box: { x: r.x, y: r.y, w: r.width, h: r.height }
        };
      })
    });
  }
  return out;
})()`;

/* B2. The REMOTE DETAIL's action row — the surface that still renders a remote
 * mission's controls (the card hides them; a captain who clicked in to READ the
 * mission is entitled to see what it has). This is where the 1.79:1 pair now
 * lives, and where it has to be closed. */
const REMOTE_DETAIL_PROBE = `(function () {
  var row = document.querySelector(".det-actions");
  if (!row) return { present: false };
  var btns = Array.prototype.slice.call(row.querySelectorAll("button"));
  return {
    present: true,
    buttons: btns.map(function (b) {
      var r = b.getBoundingClientRect();
      var st = getComputedStyle(b);
      return {
        text: (b.textContent || "").trim(), disabled: !!b.disabled,
        cls: String(b.className || ""), title: b.title || "",
        bg: st.backgroundColor, color: st.color,
        borderStyle: st.borderTopStyle, opacity: parseFloat(st.opacity || "1"),
        box: { x: r.x, y: r.y, w: r.width, h: r.height }
      };
    })
  };
})()`;

/* ── S196 B5 — THE OWNERSHIP FILTER ─────────────────────────────────────────
 * The strip, the cards it left on screen, the counts it printed, and the
 * column heads — read together in ONE probe, because "the chip says 3" and
 * "the board drew 3" are only worth anything as the same observation. */
const FILTER_PROBE = `(function () {
  var host = document.getElementById("ownerFilter");
  function box(n) {
    var r = n.getBoundingClientRect();
    return { x: r.x, y: r.y, w: r.width, h: r.height };
  }
  var chips = host
    ? Array.prototype.slice.call(host.querySelectorAll("button")) : [];
  return {
    present: !!host,
    hidden: host ? !!host.hidden : null,
    strip: host && !host.hidden ? box(host) : null,
    chips: chips.map(function (b) {
      var st = getComputedStyle(b);
      return {
        id: b.getAttribute("data-filter"),
        text: (b.textContent || "").trim(),
        count: Number(b.getAttribute("data-count")),
        pressed: b.getAttribute("aria-pressed"),
        disabled: !!b.disabled, cls: String(b.className || ""),
        bg: st.backgroundColor, borderStyle: st.borderTopStyle,
        box: box(b)
      };
    }),
    cards: Array.prototype.slice.call(
      document.querySelectorAll(".board .card[data-mid]")
    ).map(function (c) { return c.getAttribute("data-mid"); }),
    heads: Array.prototype.slice.call(
      document.querySelectorAll(".board .col")
    ).map(function (c) {
      var ct = c.querySelector(".col-head .ct");
      return { ct: ct ? (ct.textContent || "").trim() : null,
               drawn: c.querySelectorAll(".card[data-mid]").length };
    }),
    status: (document.getElementById("status") || { textContent: "" }).textContent
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

/* ─────────────── S196 — THE TRANSPORTER MATERIALIZE ────────────────────────

   THE DEFECT. `ownerNode()` handled a portrait that FAILED and never one that
   was merely PENDING, so an avatar still in flight — or deferred by its own
   `loading="lazy"` and never started at all — painted a flat dark disc at rest.
   The captain hit it for real: a whole capture run of cards wearing a black
   circle where his face goes. Nothing errored, so nothing degraded.

   WHY THIS NEEDS A BROWSER, and specifically needs CDP. "Pending" is the one
   state that fires no event, and it is invisible to every harness in web/tests
   for the same reason it was invisible to the product: there is nothing to
   listen for. Here the avatar's own GET is HELD by `Fetch.enable`, so the real
   board sits in the real pending state for as long as the drive wants, and the
   disc can be read — and photographed — in it.

   AND THE GEOMETRY, which is the half a stylesheet test structurally cannot
   answer. `.owner .owner-av img` is (0,2,1); a bare `.beam img` is (0,1,1) and
   loses, sizing the portrait at the old explicit 17px inside a 15px disc that
   clips it — a visibly non-circular avatar with two fighting rings, from a
   sheet in which every rule reads correct. Only rendered boxes can see that,
   so the disc's content box and the portrait's border box are MEASURED and
   required to be the same box. */
const BEAM_PROBE = `(function (sel) {
  function num(v) { return parseFloat(v) || 0; }
  var disc = document.querySelector(sel);
  if (!disc) return { present: false,
                      caps: document.querySelectorAll(".owner .owner-av").length,
                      dead: document.querySelectorAll(".owner.dead").length };
  var img = disc.querySelector("img");
  var d = disc.getBoundingClientRect();
  var ds = getComputedStyle(disc);
  var af = getComputedStyle(disc, "::after");
  var bf = getComputedStyle(disc, "::before");
  var i = img ? img.getBoundingClientRect() : null;
  var is = img ? getComputedStyle(img) : null;
  return {
    present: true,
    cls: String(disc.className || ""),
    disc: {
      w: d.width, h: d.height, x: d.x, y: d.y,
      overflow: ds.overflow, position: ds.position, radius: ds.borderTopLeftRadius,
      borderW: num(ds.borderTopWidth),
      // the CONTENT box — what the portrait is allowed to fill
      innerW: d.width - num(ds.borderLeftWidth) - num(ds.borderRightWidth)
                      - num(ds.paddingLeft) - num(ds.paddingRight),
      innerH: d.height - num(ds.borderTopWidth) - num(ds.borderBottomWidth)
                       - num(ds.paddingTop) - num(ds.paddingBottom)
    },
    img: img ? { w: i.width, h: i.height, x: i.x, y: i.y,
                 borderW: num(is.borderTopWidth), objectFit: is.objectFit,
                 opacity: parseFloat(is.opacity || "1"),
                 filter: is.filter, natural: img.naturalWidth,
                 lazy: img.getAttribute("loading") } : null,
    pad: { afterName: af.animationName, afterIter: af.animationIterationCount,
           beforeName: bf.animationName, beforeIter: bf.animationIterationCount },
    box: { x: d.x, y: d.y, w: d.width, h: d.height },
    // the WHOLE pill, for the artefact a human looks at: cap + handle is the
    // thing the captain recognises, and a disc on its own is not a pill.
    pill: (function () {
      var o = disc.closest ? disc.closest(".owner") : null;
      if (!o) return null;
      var r = o.getBoundingClientRect();
      return { x: r.x, y: r.y, w: r.width, h: r.height };
    })()
  };
})`;

/* Build ONE extra owner pill through the page's own `ownerNode()`, on a URL the
   drive is holding, and park it on the board where it can be measured and shot.
   The page's real function, the page's real stylesheet — nothing is staged but
   the URL. */
const PENDING_BUILD = `(function () {
  if (typeof ownerNode !== "function") return { fn: false };
  var old = document.getElementById("s196-beam-probe");
  if (old && old.parentNode) old.parentNode.removeChild(old);
  var host = document.createElement("div");
  host.id = "s196-beam-probe";
  host.className = "card";
  host.style.cssText = "position:absolute;left:12px;top:12px;z-index:99999;" +
                       "padding:12px;";
  var pill = ownerNode({ owner: { login: "intransit",
    avatarUrl: "https://github.com/roferg.png?size=64&beam-probe=1" } });
  if (!pill) return { fn: true, pill: false };
  host.appendChild(pill);
  document.body.appendChild(host);
  return { fn: true, pill: true };
})()`;

const PENDING_TEARDOWN = `(function () {
  var host = document.getElementById("s196-beam-probe");
  var pill = host ? host.querySelector(".owner") : null;
  var out = { deadPill: !!(pill && /(^| )dead( |$)/.test(pill.className || "")),
              caps: host ? host.querySelectorAll(".owner-av").length : -1,
              imgs: host ? host.querySelectorAll("img").length : -1,
              handle: pill ? (pill.textContent || "").trim() : "" };
  if (host && host.parentNode) host.parentNode.removeChild(host);
  return out;
})()`;

/* ── S196.1: THE WINDOW MUST SURVIVE THE BOARD'S OWN REPAINT ───────────────
 *
 * The give-up above is asked of a node that is built ONCE and left alone. That
 * is not the board. The SSE tick rebuilds every `.beam` node every 3.4–5.6s
 * during a mission, and the failure side of the memo used to live in the node's
 * closure — so each rebuild armed a fresh eight-second window and threw the
 * previous one away. The deadline receded for as long as the board stayed busy.
 *
 * NO UNIT HARNESS FOUND THIS AND NO STYLESHEET RULE IS WRONG. It was measured
 * here, live: a DNS-blackholed portrait still `beam loading` with both pad
 * animations `infinite` at 14s and 16s, six `.beam` generations in twenty
 * seconds — while the same portrait on an IDLE board collapsed at 8s. So the
 * repaint is STAGED here, on the page's own `ownerNode()`, on a URL this drive
 * is holding open, and the clock is the wall clock. */
const REBUILD_SRC = "https://github.com/roferg.png?size=64&beam-rebuild-probe=1";
const REBUILD_BUILD = `(function () {
  if (typeof ownerNode !== "function") return { fn: false };
  var host = document.getElementById("s196-rebuild-probe");
  if (!host) {
    host = document.createElement("div");
    host.id = "s196-rebuild-probe";
    host.className = "card";
    host.style.cssText = "position:absolute;left:12px;top:120px;z-index:99999;" +
                         "padding:12px;";
    document.body.appendChild(host);
  }
  // THE REPAINT, exactly as render() does it: the old node is thrown away and a
  // brand-new one is built from the same card.
  while (host.firstChild) host.removeChild(host.firstChild);
  var pill = ownerNode({ owner: { login: "rebuilt",
    avatarUrl: ${JSON.stringify(REBUILD_SRC)} } });
  if (!pill) return { fn: true, pill: false };
  host.appendChild(pill);
  var b = host.querySelector(".beam");
  return { fn: true, pill: true, cls: b ? b.className : null,
           window: (typeof AVATAR_GIVE_UP_MS === "number" ? AVATAR_GIVE_UP_MS : null) };
})()`;

const REBUILD_PROBE = `(function () {
  var host = document.getElementById("s196-rebuild-probe");
  var pill = host ? host.querySelector(".owner") : null;
  var b = host ? host.querySelector(".beam") : null;
  var pad = { afterName: "none", afterIter: "", beforeName: "none", beforeIter: "" };
  if (b) {
    var a = getComputedStyle(b, "::after"), f = getComputedStyle(b, "::before");
    pad = { afterName: a.animationName, afterIter: a.animationIterationCount,
            beforeName: f.animationName, beforeIter: f.animationIterationCount };
  }
  return { pill: !!pill,
           dead: !!(pill && /(^| )dead( |$)/.test(pill.className || "")),
           cls: b ? b.className : null,
           caps: host ? host.querySelectorAll(".owner-av").length : -1,
           imgs: host ? host.querySelectorAll("img").length : -1,
           handle: pill ? (pill.textContent || "").trim() : "",
           pad: pad };
})()`;

const REBUILD_TEARDOWN = `(function () {
  var h = document.getElementById("s196-rebuild-probe");
  if (h && h.parentNode) h.parentNode.removeChild(h);
  return 1;
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

  // ── S196 B1 ───────────────────────────────────────────────────────────
  // OWNERSHIP WITH THE COLOUR TAKEN AWAY. The two align cards differ in exactly
  // one fact, so their two owner pills are the cleanest possible subject. Read
  // twice: once in colour, and once with the whole page desaturated in Chrome —
  // because "desaturate it and look" is the captain's own acceptance test and
  // a number computed from the colour pixels is not the same evidence.
  console.log("\nB1 — can you tell WHOSE mission it is in GREYSCALE?");
  let greyDetail = null, colourSep = null, greySep = null;
  const pills = await evaluate(cdp, sessionId, OWNER_PILL_PROBE);
  if (!pills || !pills.mine || !pills.theirs) {
    bad("both owner pills rendered", JSON.stringify(pills));
  } else {
    // The structural half first, because it NAMES the cure: the two states must
    // differ in FILL and EDGE, not merely in hue.
    const solid = /rgba?\(0,\s*0,\s*0,\s*0\)|transparent/.test(pills.mine.bg);
    const hollow = /rgba?\(0,\s*0,\s*0,\s*0\)|transparent/.test(pills.theirs.bg);
    if (!solid && hollow) {
      ok("my pill is FILLED and theirs is HOLLOW",
         "mine bg " + pills.mine.bg + " (" + pills.mine.borderStyle + ") · " +
         "theirs bg " + pills.theirs.bg + " (" + pills.theirs.borderStyle + ")");
    } else {
      bad("my pill is FILLED and theirs is HOLLOW",
          "mine bg " + pills.mine.bg + " · theirs bg " + pills.theirs.bg +
          " — ownership is back on hue alone");
    }
    if (pills.mine.borderStyle !== pills.theirs.borderStyle) {
      ok("the two pills differ in EDGE as well as fill",
         pills.mine.borderStyle + " vs " + pills.theirs.borderStyle);
    } else {
      bad("the two pills differ in EDGE as well as fill",
          "both " + pills.mine.borderStyle);
    }

    // …and the pixels. IN COLOUR first: this is the number the shipped board
    // scored, and it is here so the greyscale number below has something to be
    // compared against rather than being reported alone.
    const mineFill = fill(pngPixels(
      await shoot(cdp, sessionId, pills.mine.box, "owner-pill-mine.png", 4, 0)));
    const theirsFill = fill(pngPixels(
      await shoot(cdp, sessionId, pills.theirs.box, "owner-pill-theirs.png", 4, 0)));
    colourSep = contrast(mineFill, theirsFill);
    // ONE FRAME, BOTH CARDS, IN COLOUR — the artefact a human looks at.
    if (pair && pair.pairBox) {
      await shoot(cdp, sessionId, pair.pairBox, "owner-pair-colour.png", 3, 10);
    }

    // NOW TAKE THE COLOUR AWAY. A real filter, applied in real Chrome, and the
    // screenshot re-taken through it — not a number computed off the colour
    // pixels and called a greyscale reading.
    await evaluate(cdp, sessionId,
      `(function(){document.documentElement.style.filter="grayscale(1)";return 1})()`);
    await sleep(300);
    const gMine = fill(pngPixels(await shoot(
      cdp, sessionId, pills.mine.box, "owner-pill-mine-greyscale.png", 4, 0)));
    const gTheirs = fill(pngPixels(await shoot(
      cdp, sessionId, pills.theirs.box, "owner-pill-theirs-greyscale.png", 4, 0)));
    if (pair && pair.pairBox) {
      await shoot(cdp, sessionId, pair.pairBox, "owner-pair-greyscale.png", 3, 10);
    }
    // …and PROVE THE FILTER ACTUALLY BIT, or the whole check is a colour reading
    // wearing a greyscale label. A desaturated pixel has r == g == b.
    const desaturated = (c) => Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2]) <= 2;
    await evaluate(cdp, sessionId,
      `(function(){document.documentElement.style.filter="";return 1})()`);
    await sleep(200);
    greySep = contrast(gMine, gTheirs);
    greyDetail = "MINE rgb(" + gMine.join(",") + ") vs THEIRS rgb(" +
      gTheirs.join(",") + ") → " + greySep.toFixed(2) + ":1 " +
      "(in colour it is " + colourSep.toFixed(2) + ":1) " +
      "— owner-pair-greyscale.png, LOOK AT THIS ONE";
    if (!desaturated(gMine) || !desaturated(gTheirs)) {
      bad("the greyscale screenshot is actually greyscale",
          "grayscale(1) did not take: " + greyDetail);
    } else if (greySep >= 3.0) {
      ok("ownership is legible with the COLOUR REMOVED (>= 3:1)", greyDetail);
    } else {
      bad("ownership is legible with the COLOUR REMOVED (>= 3:1)", greyDetail);
    }
  }

  // ── S196 B3 + B4 ──────────────────────────────────────────────────────
  console.log("\nB3/B4 — a remote card offers only what it can do");
  const remotes = await evaluate(cdp, sessionId, REMOTE_PROBE) || [];
  if (remotes.length < 2) {
    throw new InfraError("the remote fixture did not paint 2 remote cards (saw "
      + remotes.length + ") — the gh shim's listing never reached the board");
  }
  for (const rc of remotes) {
    const dead = (rc.children || []).filter((k) => k.disabled);
    if (dead.length === 0) {
      ok("remote card " + JSON.stringify(rc.stage) + " carries NO dead control",
         (rc.children || []).length + " control(s): " +
         JSON.stringify((rc.children || []).map((k) => k.text)));
    } else {
      bad("remote card " + JSON.stringify(rc.stage) + " carries NO dead control",
          "still drawing " + JSON.stringify(dead.map((k) => k.text)) +
          " — a control that promises an action this laptop cannot perform");
    }
    await shoot(cdp, sessionId, rc.cardBox,
                "remote-card-" + rc.mid + ".png", 3, 8);
  }
  const adoptable = remotes.filter(
    (r) => (r.children || []).some((k) => /ADOPT/i.test(k.text)));
  if (adoptable.length === 1) {
    const row = adoptable[0].children;
    if (row.length === 1) {
      ok("the adoptable remote card offers EXACTLY ONE control", row[0].text);
    } else {
      bad("the adoptable remote card offers EXACTLY ONE control",
          JSON.stringify(row.map((k) => k.text)));
    }
    // B4 — the glyph. `◆` leads, `▸` is the shared dispatch suffix, and
    // nothing in the label may come from outside the house family.
    const label = row.find((k) => /ADOPT/i.test(k.text)).text;
    const FAMILY = "▶▸▹✓⏸◐◷↻◆⊹⊘◈";
    const stray = Array.from(label).filter(
      (ch) => ch.codePointAt(0) > 0x2000 && FAMILY.indexOf(ch) < 0);
    if (label.indexOf("◆") === 0 && /▸$/.test(label) && stray.length === 0) {
      ok("the adopt label leads with ◆ and keeps the ▸ dispatch suffix",
         JSON.stringify(label) + " — no hollow triangle beside a solid one");
    } else {
      bad("the adopt label leads with ◆ and keeps the ▸ dispatch suffix",
          JSON.stringify(label) + (stray.length
            ? " — off-family glyph(s) " + JSON.stringify(stray) : ""));
    }
  } else {
    bad("exactly one remote card offers Adopt",
        adoptable.length + " did (the fixture is verify + research)");
  }
  const noAdopt = remotes.filter(
    (r) => !(r.children || []).some((k) => /ADOPT/i.test(k.text)));
  if (noAdopt.length === 1 && (noAdopt[0].children || []).length === 0) {
    ok("the MID-PIPELINE remote card offers nothing at all",
       JSON.stringify(noAdopt[0].stage) + " — the stage line carries the state");
  } else {
    bad("the MID-PIPELINE remote card offers nothing at all",
        JSON.stringify(noAdopt.map((r) => (r.children || []).map((k) => k.text))));
  }

  // ── S197 ──────────────────────────────────────────────────────────────
  console.log("\nS197 — the board stops offering an action that cannot succeed");
  const sh = await evaluate(cdp, sessionId, SHIPPED_PROBE);
  if (!sh || !sh.live || !sh.over) {
    throw new InfraError("the shipped/live pair (m-mine / m-shipped-mine) never "
      + "rendered — the S197 fixture did not reach the board");
  }
  // THE CONTROL, and this is the headline. A live `✓ Review PR ▸` for a pull
  // request that merged minutes ago is the defect two independent two-laptop
  // runs found on the same day.
  const stillOffered = (sh.over.controls || []).filter(
    (b) => /review pr/i.test(b.text) && !b.disabled);
  if (stillOffered.length === 0 && !/Review PR/i.test(sh.over.text)) {
    ok("a merged mission offers NO Review PR control",
       JSON.stringify((sh.over.controls || []).map((b) => b.text)));
  } else {
    bad("a merged mission offers NO Review PR control",
        "the board is still offering a merged PR for review: "
        + JSON.stringify((sh.over.controls || []).map((b) => b.text)));
  }
  const liveOnOver = (sh.over.controls || []).filter((b) => !b.disabled);
  if (liveOnOver.length === 0) {
    ok("nothing in the shipped card's control row is live",
       (sh.over.controls || []).length + " control(s), all dead");
  } else {
    bad("nothing in the shipped card's control row is live",
        JSON.stringify(liveOnOver.map((b) => b.text)));
  }
  // IT SAYS SO IN WORDS. Withdrawing the control without replacing it with a
  // statement would leave the captain looking at a card that had gone quiet for
  // no reason he can see.
  if (/SHIPPED ELSEWHERE/i.test(sh.over.text)) {
    ok("the card states what actually happened", "it says SHIPPED ELSEWHERE");
  } else {
    bad("the card states what actually happened",
        JSON.stringify(sh.over.text.slice(0, 160)));
  }
  // AND IT IS LEGIBLE WITHOUT COLOUR. Shape, at both distances: the card's
  // 6px left edge goes DASHED where a live card's is SOLID, and every dead
  // control takes `.btn.locked` (hollow + dashed + `⊘`). Read off the CASCADE
  // here and confirmed in the pixels below.
  if (sh.over.edgeStyle === "dashed" && sh.live.edgeStyle !== "dashed") {
    ok("the shipped card's edge is DASHED where the live one's is solid",
       sh.over.edgeStyle + " vs " + sh.live.edgeStyle);
  } else {
    bad("the shipped card's edge is DASHED where the live one's is solid",
        sh.over.edgeStyle + " vs " + sh.live.edgeStyle);
  }
  const unmarkedOver = (sh.over.controls || []).filter(
    (b) => b.text && b.text.indexOf("⊘") !== 0);
  if ((sh.over.controls || []).length > 0 && unmarkedOver.length === 0) {
    ok("every dead control on the shipped card opens with the ⊘ lock mark",
       JSON.stringify((sh.over.controls || []).map((b) => b.text)));
  } else {
    bad("every dead control on the shipped card opens with the ⊘ lock mark",
        "unmarked: " + JSON.stringify(unmarkedOver.map((b) => b.text)));
  }
  const mute = (sh.over.controls || []).filter((b) => !b.title);
  if (mute.length === 0) {
    ok("every dead control still says why in one sentence",
       JSON.stringify((sh.over.controls || []).map((b) => b.title)[0] || ""));
  } else {
    bad("every dead control still says why in one sentence",
        mute.length + " carry no tooltip");
  }
  // THE NEGATIVE CONTROL, and it is the one that stops this from being a cure
  // that quietly killed the whole column: the card beside it, identical on
  // disk, whose issue the forge did not mention, must be completely live.
  const liveOnLive = (sh.live.controls || []).filter((b) => !b.disabled);
  if (liveOnLive.length > 0 && /Review PR/i.test(sh.live.text)) {
    ok("the mission the forge said nothing about is UNTOUCHED",
       JSON.stringify(liveOnLive.map((b) => b.text)));
  } else {
    bad("the mission the forge said nothing about is UNTOUCHED",
        JSON.stringify((sh.live.controls || []).map(
          (b) => b.text + (b.disabled ? " [DEAD]" : ""))));
  }
  // LOCAL WINS, still. The closed issue must not also draw a remote card.
  if ((sh.remoteMids || []).indexOf("106") < 0) {
    ok("the shipped issue draws no SECOND card",
       "remote cards: " + JSON.stringify(sh.remoteMids));
  } else {
    bad("the shipped issue draws no SECOND card",
        "remote cards: " + JSON.stringify(sh.remoteMids));
  }
  // ONE FRAME, BOTH CARDS — the artefact a human looks at.
  await shoot(cdp, sessionId, sh.pairBox, "shipped-vs-live.png", 3, 10);
  // …and the pixels. Same 3:1 threshold (WCAG 1.4.11 for non-text UI state) the
  // owner lock is held to, measured between the two control FILLS.
  if ((sh.over.controls || []).length && (sh.live.controls || []).length) {
    const overFill = fill(pngPixels(await shoot(
      cdp, sessionId, sh.over.controls[0].box, "shipped-control.png", 4, 0)));
    const liveFill2 = fill(pngPixels(await shoot(
      cdp, sessionId, sh.live.controls[0].box, "shipped-live-control.png", 4, 0)));
    const sep2 = contrast(overFill, liveFill2);
    const d2 = "withdrawn fill rgb(" + overFill.join(",") + ") vs live fill rgb("
      + liveFill2.join(",") + ") → " + sep2.toFixed(2) + ":1 "
      + "(shipped-vs-live.png — LOOK AT THIS ONE)";
    if (sep2 >= 3.0) {
      ok("the withdrawn control and the live one PAINT differently (>= 3:1)", d2);
    } else {
      bad("the withdrawn control and the live one PAINT differently (>= 3:1)", d2);
    }
    const wr2 = inkAndPaper(pngPixels(await shoot(
      cdp, sessionId, sh.over.controls[0].box, "shipped-control-ink.png", 4, 0)));
    if (wr2.contrast >= 4.5) {
      ok("the withdrawn control is READABLE in the actual pixels (>= 4.5:1)",
         wr2.contrast.toFixed(2) + ":1");
    } else {
      bad("the withdrawn control is READABLE in the actual pixels (>= 4.5:1)",
          wr2.contrast.toFixed(2) + ":1");
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

  // ── S196 — THE TRANSPORTER MATERIALIZE ────────────────────────────────
  console.log("\nS196 — a portrait that has NOT ARRIVED YET");
  let beamSettled = null, beamPending = null, beamDead = null;

  // (a) THE SETTLED PILL. "Once loaded it must look EXACTLY as it does today"
  //     is a claim about rendered boxes, so it is measured as rendered boxes.
  beamSettled = await evaluate(cdp, sessionId,
    BEAM_PROBE + '(".card .owner .owner-av .beam")');
  if (!beamSettled || !beamSettled.present) {
    skip("the settled portrait fills its disc exactly",
         "no .beam disc on the board — the cap is " +
         ((beamSettled && beamSettled.caps) || 0) + " deep and " +
         ((beamSettled && beamSettled.dead) || 0) + " pill(s) are .dead. NOT a pass.");
  } else if (!beamSettled.img) {
    skip("the settled portrait fills its disc exactly", "the disc holds no <img>");
  } else {
    const D = beamSettled.disc, I = beamSettled.img;
    const geo = "disc " + D.w.toFixed(2) + "x" + D.h.toFixed(2) +
      " (content " + D.innerW.toFixed(2) + "x" + D.innerH.toFixed(2) +
      ", border " + D.borderW + "px, radius " + D.radius + ", " + D.overflow +
      ") · portrait " + I.w.toFixed(2) + "x" + I.h.toFixed(2) +
      " (border " + I.borderW + "px, object-fit " + I.objectFit + ")";
    if (Math.abs(D.w - D.h) <= 0.5) {
      ok("the disc is SQUARE, so `border-radius:50%` is a circle", geo);
    } else {
      bad("the disc is SQUARE, so `border-radius:50%` is a circle", geo);
    }
    // THE ANTI-CLIPPING GUARD. Image border box == disc content box. A portrait
    // even a pixel larger is silently cropped by `overflow:hidden` and paints
    // out of round; one smaller leaves a crescent of bare disc inside the ring.
    const fits = Math.abs(I.w - D.innerW) <= 0.5 && Math.abs(I.h - D.innerH) <= 0.5;
    if (fits) {
      ok("the portrait EXACTLY fills the disc's content box", geo);
    } else {
      bad("the portrait EXACTLY fills the disc's content box",
          geo + " — `.owner .owner-av img` (0,2,1) is outranking the beam's own " +
          "rule, so the portrait keeps the old explicit size inside a smaller " +
          "disc and is clipped out of round");
    }
    if (I.borderW === 0) {
      ok("the portrait draws NO ring of its own (the disc owns it)", geo);
    } else {
      bad("the portrait draws NO ring of its own (the disc owns it)",
          geo + " — two concentric black rings, which is what the mock did first");
    }
    // …and the settled pill still wears exactly the treatment it wore before.
    if (/saturate\(0?\.72\)/.test(I.filter || "")) {
      ok("the settled portrait still wears the seat-it-in-the-palette filter",
         I.filter);
    } else {
      bad("the settled portrait still wears the seat-it-in-the-palette filter",
          JSON.stringify(I.filter) + " — the pill does not look as it did before");
    }
    if (I.lazy === null) {
      ok("the portrait is not `loading=\"lazy\"`",
         "a deferred image never starts, never errors, and would trip the " +
         "give-up window on a card merely scrolled off screen");
    } else {
      bad("the portrait is not `loading=\"lazy\"`", "loading=" + JSON.stringify(I.lazy));
    }
    await shoot(cdp, sessionId, beamSettled.pill || beamSettled.box,
                "beam-settled-pill.png", beamSettled.pill ? 12 : 80, 0);
    await shoot(cdp, sessionId, beamSettled.box, "beam-settled-disc.png", 80, 0);
  }

  // (b) THE PENDING PORTRAIT — the state the whole session exists for. The GET
  //     is HELD by Fetch so the board really is waiting; nothing is staged.
  await cdp.send("Fetch.enable",
    { patterns: [{ urlPattern: "*beam-probe*", requestStage: "Request" }] }, sessionId);
  const built = await evaluate(cdp, sessionId, PENDING_BUILD);
  if (!built || !built.fn || !built.pill) {
    await cdp.send("Fetch.disable", {}, sessionId);
    skip("a PENDING portrait is never a resting empty disc",
         "the page's own ownerNode() could not be driven: " + JSON.stringify(built));
  } else {
    await sleep(600);
    beamPending = await evaluate(cdp, sessionId,
      BEAM_PROBE + '("#s196-beam-probe .owner .owner-av .beam")');
    const held = cdp.paused.filter((r) => /beam-probe/.test((r.request || {}).url || ""));
    if (!beamPending || !beamPending.present) {
      bad("a PENDING portrait is never a resting empty disc",
          "the pill built no disc at all: " + JSON.stringify(beamPending));
    } else {
      const cls = beamPending.cls.split(/\s+/);
      const pd = "class " + JSON.stringify(beamPending.cls) + " · pad ::after " +
        beamPending.pad.afterName + "/" + beamPending.pad.afterIter +
        " ::before " + beamPending.pad.beforeName + "/" + beamPending.pad.beforeIter +
        " · " + held.length + " request(s) held";
      // THE HEADLINE. The disc must be SAYING something.
      const humming = beamPending.pad.afterName !== "none" &&
                      beamPending.pad.beforeName !== "none";
      const loops = /infinite/.test(beamPending.pad.afterIter) &&
                    /infinite/.test(beamPending.pad.beforeIter);
      if (cls.indexOf("loading") >= 0 && humming && loops) {
        ok("a PENDING portrait is never a resting empty disc — the pad is LIT", pd);
      } else {
        bad("a PENDING portrait is never a resting empty disc — the pad is LIT",
            pd + " — an avatar in flight paints a flat dark circle, which is " +
            "the hole the .dead degrade exists to prevent and the one no event " +
            "ever announces");
      }
      // The geometry has to hold in THIS state too: the pad is drawn on the
      // disc, and a disc that is the wrong shape while waiting is a wrong-shaped
      // hole with lights on it.
      const P = beamPending;
      if (Math.abs(P.disc.w - P.disc.h) <= 0.5 && P.img &&
          Math.abs(P.img.w - P.disc.innerW) <= 0.5 && P.img.borderW === 0) {
        ok("the disc keeps its geometry WHILE WAITING",
           "disc " + P.disc.w.toFixed(2) + "x" + P.disc.h.toFixed(2) +
           " · portrait " + P.img.w.toFixed(2) + "x" + P.img.h.toFixed(2));
      } else {
        bad("the disc keeps its geometry WHILE WAITING", JSON.stringify(P.disc) +
            " vs " + JSON.stringify(P.img));
      }
      // THE ARTEFACT THE CAPTAIN LOOKS AT: the pad, mid-loop, at 80x.
      await shoot(cdp, sessionId, beamPending.box, "beam-pad-mid-loop.png", 80, 0);
    }
    // (c) …AND IT GIVES UP. A pad that hums for ever is a spinner that lies, so
    //     the held request is FAILED and the pill must land on the existing
    //     complete `.dead` shape — the same place a portrait that never arrives
    //     lands after AVATAR_GIVE_UP_MS.
    for (const r of held.length ? held : cdp.paused) {
      try { await cdp.send("Fetch.failRequest",
        { requestId: r.requestId, errorReason: "ConnectionRefused" }, sessionId); }
      catch (e) { /* already gone */ }
    }
    await sleep(400);
    beamDead = await evaluate(cdp, sessionId, PENDING_TEARDOWN);
    await cdp.send("Fetch.disable", {}, sessionId);
    const dd = JSON.stringify(beamDead);
    if (beamDead && beamDead.deadPill && beamDead.caps === 0 && beamDead.imgs === 0 &&
        /INTRANSIT/.test(beamDead.handle || "")) {
      ok("a portrait that never comes collapses to the handle-ALONE pill", dd);
    } else {
      bad("a portrait that never comes collapses to the handle-ALONE pill",
          dd + " — wanted the cap removed, the pill .dead and the handle intact");
    }
  }

  // (d) …AND THE WINDOW SURVIVES THE BOARD'S OWN REPAINT. S196.1: the defect
  //     that only exists while the board is BUSY, which is most of a mission.
  //     The portrait's GET is held (no load, no error — the blackhole), the
  //     node is rebuilt three times INSIDE the window the way the SSE tick
  //     rebuilds it, and the pill must still collapse at the ORIGINAL
  //     deadline. A window that restarts on each rebuild would not expire
  //     until t0 + 6s + 8s, so it is still humming when this reads it.
  console.log("\nS196.1 — the give-up window survives the board's own repaint");
  await cdp.send("Fetch.enable",
    { patterns: [{ urlPattern: "*beam-rebuild-probe*", requestStage: "Request" }] },
    sessionId);
  const rb0 = await evaluate(cdp, sessionId, REBUILD_BUILD);
  if (!rb0 || !rb0.fn || !rb0.pill) {
    await cdp.send("Fetch.disable", {}, sessionId);
    skip("a REPAINTED pending portrait gives up at the ORIGINAL deadline",
         "the page's own ownerNode() could not be driven: " + JSON.stringify(rb0));
  } else {
    // The window is read off the SHIPPING constant, never duplicated here — a
    // number copied into a rig is a second source of truth and the first thing
    // to go stale.
    const WIN = typeof rb0.window === "number" ? rb0.window : 8000;
    const t0 = Date.now();
    const gens = [rb0.cls];
    const every = Math.max(1200, Math.floor(WIN / 4));
    while (Date.now() - t0 < WIN - every) {
      await sleep(every);
      const g = await evaluate(cdp, sessionId, REBUILD_BUILD);
      gens.push(g && g.cls);
    }
    // Past the ORIGINAL deadline, and only just.
    while (Date.now() - t0 < WIN + 1500) await sleep(200);
    const rb = await evaluate(cdp, sessionId, REBUILD_PROBE);
    const elapsed = Date.now() - t0;
    // Only now let the held requests go — failing them fires `error`, which
    // would collapse the pill for the wrong reason.
    for (const r of cdp.paused.filter(
           (x) => /beam-rebuild-probe/.test((x.request || {}).url || ""))) {
      try { await cdp.send("Fetch.failRequest",
        { requestId: r.requestId, errorReason: "ConnectionRefused" }, sessionId); }
      catch (e) { /* already gone */ }
    }
    await evaluate(cdp, sessionId, REBUILD_TEARDOWN);
    await cdp.send("Fetch.disable", {}, sessionId);
    const rd = JSON.stringify(rb) + " · " + gens.length + " generation(s) of .beam " +
      "inside a " + WIN + "ms window · read at " + elapsed + "ms since first sight";
    if (rb && rb.dead && rb.caps === 0 && rb.imgs === 0 &&
        /REBUILT/.test(rb.handle || "")) {
      ok("a REPAINTED pending portrait gives up at the ORIGINAL deadline", rd);
    } else {
      bad("a REPAINTED pending portrait gives up at the ORIGINAL deadline",
          rd + " — every repaint re-armed the window and discarded the old " +
          "one, so the deadline recedes for as long as the board is busy and " +
          "the pad hums for ever: a spinner that lies, which is the exact " +
          "thing ownerNode()'s own comment says the give-up prevents");
    }
  }

  // ── S196 B2 ───────────────────────────────────────────────────────────
  // THE 1.79:1 PAIR, WHEREVER IT STILL EXISTS. B3 removed it from the card by
  // deleting the dead control; the DETAIL still renders one (a captain who
  // opened a mission to read it is entitled to see what it has), and that is
  // the one surface where a locked remote control and a live one still sit side
  // by side in the same row — which is the only place the question can be asked.
  console.log("\nB2 — a REMOTE control that cannot be used looks like it");
  let remoteSep = null;
  const remoteMid = (remotes.find(
    (r) => (r.children || []).some((k) => /ADOPT/i.test(k.text))) || remotes[0]).mid;
  await evaluate(cdp, sessionId,
    `(function(){var c=document.querySelector('.card.remote[data-mid="` +
    remoteMid + `"]');if(c)c.click();return 1})()`);
  let rdet = null;
  for (let i = 0; i < 60 && Date.now() < deadline; i++) {
    rdet = await evaluate(cdp, sessionId, REMOTE_DETAIL_PROBE);
    if (rdet && rdet.present && (rdet.buttons || []).length) break;
    await sleep(200);
  }
  if (!rdet || !rdet.present) {
    bad("the remote detail opens at all",
        "clicking the remote card never rendered a .det-actions row — the one " +
        "surface a remote mission's controls still live on");
  } else {
    const laid = (rdet.buttons || []).filter((b) => b.box.w > 0 && b.box.h > 0);
    const locked = laid.filter((b) => b.disabled);
    const live = laid.filter((b) => !b.disabled);
    if (!locked.length) {
      bad("the remote detail still renders the mission's controls",
          "no disabled control — B3 has leaked onto the detail and B2 is " +
          "measuring nothing");
    } else if (!live.length) {
      bad("ADOPT is live in the remote detail",
          JSON.stringify(laid.map((b) => b.text)));
    } else {
      // THE LABEL. A locked control that still opens with `▶` is the lie
      // stated twice; the glyph is REPLACED, not prefixed.
      const unmarked = locked.filter((b) => b.text.indexOf("⊘") !== 0);
      if (unmarked.length === 0) {
        ok("every locked control in the remote detail wears the ⊘ mark",
           JSON.stringify(locked.map((b) => b.text)));
      } else {
        bad("every locked control in the remote detail wears the ⊘ mark",
            "unmarked: " + JSON.stringify(unmarked.map((b) => b.text)));
      }
      // …AND THE TOOLTIP still says WHY, which is the half that differs from
      // S190's lock. One state, two reasons, and the reason must survive.
      const mute = locked.filter((b) => !/another machine/.test(b.title));
      if (mute.length === 0) {
        ok("every locked remote control still says why in one sentence",
           JSON.stringify(locked[0].title));
      } else {
        bad("every locked remote control still says why in one sentence",
            JSON.stringify(mute.map((b) => b.text)));
      }
      // THE PIXELS. This is the number: 1.79:1 was the shipped separation
      // between a dead control and the live Adopt beside it.
      const lockShot = fill(pngPixels(await shoot(
        cdp, sessionId, locked[0].box, "remote-locked-control.png", 4, 0)));
      const liveShot = fill(pngPixels(await shoot(
        cdp, sessionId, live[0].box, "remote-live-adopt.png", 4, 0)));
      remoteSep = contrast(lockShot, liveShot);
      const rdDetail = "locked " + JSON.stringify(locked[0].text) +
        " fill rgb(" + lockShot.join(",") + ") vs live " +
        JSON.stringify(live[0].text) + " fill rgb(" + liveShot.join(",") +
        ") → " + remoteSep.toFixed(2) + ":1 (was 1.79:1)";
      if (remoteSep >= 3.0) {
        ok("a locked REMOTE control and the live Adopt PAINT differently (>= 3:1)",
           rdDetail);
      } else {
        bad("a locked REMOTE control and the live Adopt PAINT differently (>= 3:1)",
            rdDetail);
      }
      // …and it must still be READABLE. The cure for "looks live" must not be
      // "vanishes": S190 round 1's dim scored 5.26:1 and this has to beat it.
      let worstR = null;
      for (let i = 0; i < locked.length; i++) {
        const m = inkAndPaper(pngPixels(await shoot(
          cdp, sessionId, locked[i].box, "remote-locked-" + i + ".png", 4, 0)));
        if (!worstR || m.contrast < worstR.c) {
          worstR = { c: m.contrast, t: locked[i].text, m: m };
        }
      }
      const wr = locked.length + " locked control(s); worst is " +
        JSON.stringify(worstR.t) + " at " + worstR.c.toFixed(2) + ":1 " +
        "(ink rgb(" + worstR.m.dark.join(",") + ") vs paper rgb(" +
        worstR.m.light.join(",") + "))";
      if (worstR.c >= 4.5) {
        ok("every locked control in the remote detail is READABLE (>= 4.5:1)", wr);
      } else {
        bad("every locked control in the remote detail is READABLE (>= 4.5:1)", wr);
      }
      // THE ROW, ONE FRAME. Identical framing is a property of the screenshot,
      // not something the rig has to promise.
      const xs = laid.map((b) => b.box.x), ys = laid.map((b) => b.box.y);
      const x1 = Math.max.apply(null, laid.map((b) => b.box.x + b.box.w));
      const y1 = Math.max.apply(null, laid.map((b) => b.box.y + b.box.h));
      const x0 = Math.min.apply(null, xs), y0 = Math.min.apply(null, ys);
      await shoot(cdp, sessionId, { x: x0, y: y0, w: x1 - x0, h: y1 - y0 },
                  "remote-detail-locked-vs-live.png", 3, 10);
    }
  }
  await evaluate(cdp, sessionId,
    `(function(){var o=document.querySelector(".overlay");if(o&&!o.hidden)o.click();return 1})()`);

  // ── S196 B5 ───────────────────────────────────────────────────────────
  // FILTER THE BOARD BY OWNERSHIP. Four questions the board can already
  // answer, asked here of the REAL product in a REAL browser — because every
  // harness in web/tests calls render() itself, and none of them can tell a
  // working filter from a blank board.
  //
  // The fixture puts all four facets on screen at once: two missions assigned
  // to `roferg` (MINE), two to `picard` (THEIRS), and the two REMOTE rows the
  // gh shim serves — both unassigned, so they are UNASSIGNED as well. That
  // overlap is deliberate: `remote` is a CARD CLASS, not an owner, and a filter
  // that treated it as a fifth owner would put those two cards in the wrong
  // bucket.
  console.log("\nB5 — filter the board by ownership");

  /* THE `gh` INVOCATION COUNT, read off the shim's own log. This is the S152
     constraint and it is the reason this check exists at all: the remote
     overlay is ONE cached `gh issue list` per CYCLE, and a filter that asked
     the daemon to re-answer would put a forge call behind every chip. A count
     is the only thing that can settle it — no number, no claim. */
  function ghCalls() {
    try {
      return fs.readFileSync(path.join(OUT, "shim.log"), "utf8")
        .split("\n").filter((l) => /^gh /.test(l)).length;
    } catch (e) { return null; }
  }

  async function clickChip(id) {
    return evaluate(cdp, sessionId,
      "(function(){var b=document.querySelector('#ownerFilter button[data-filter=\"" +
      id + "\"]');if(!b)return false;b.click();return true})()");
  }

  let fstate = await evaluate(cdp, sessionId, FILTER_PROBE);
  if (!fstate || !fstate.present) {
    bad("the board carries an ownership filter strip",
        "#ownerFilter is not in the document at all");
  } else if (fstate.hidden) {
    bad("the strip is offered on a board with four kinds of ownership on it",
        "#ownerFilter is hidden with " + fstate.cards.length + " cards on screen");
  } else {
    // The whole board, before a single filter is applied — the number every
    // "it did not blank the board" check below is held against.
    const wantAllCount = fstate.cards.length;
    const ids = fstate.chips.map((c) => c.id);
    const want = ["all", "mine", "theirs", "unassigned", "remote"];
    if (want.every((w) => ids.indexOf(w) >= 0)) {
      ok("the strip offers every facet this board can be asked about",
         JSON.stringify(fstate.chips.map((c) => c.text)));
    } else {
      bad("the strip offers every facet this board can be asked about",
          "offered " + JSON.stringify(ids));
    }

    /* ── THE PAINT. A chip that is ON and a chip that is OFF have to be told
       apart, and by the SAME axis B1 and S191 used: SOLID vs HOLLOW. The floor
       is 3:1, WCAG's own number for two UI states that must be distinguished —
       and because contrast() is computed from relative LUMINANCE, a pair that
       clears it clears it in greyscale too. That is the whole point of picking
       fill rather than hue a third time. */
    const on = fstate.chips.filter((c) => c.pressed === "true")[0];
    const off = fstate.chips.filter((c) => c.pressed === "false")[0];
    if (!on || !off) {
      bad("the strip shows one chip selected and the rest not",
          JSON.stringify(fstate.chips.map((c) => [c.id, c.pressed])));
    } else {
      const onFill = fill(pngPixels(await shoot(
        cdp, sessionId, on.box, "filter-chip-on.png", 4, 0)));
      const offFill = fill(pngPixels(await shoot(
        cdp, sessionId, off.box, "filter-chip-off.png", 4, 0)));
      const chipSep = contrast(onFill, offFill);
      const cd = "selected " + JSON.stringify(on.text) + " fill rgb(" +
        onFill.join(",") + ") vs unselected " + JSON.stringify(off.text) +
        " fill rgb(" + offFill.join(",") + ") → " + chipSep.toFixed(2) +
        ":1 (luminance, so it holds in greyscale)";
      if (chipSep >= 3.0) {
        ok("a selected chip and an unselected one PAINT differently (>= 3:1)", cd);
      } else {
        bad("a selected chip and an unselected one PAINT differently (>= 3:1)", cd);
      }
      await shoot(cdp, sessionId, fstate.strip, "owner-filter-strip.png", 3, 8);
    }

    /* ── IT MUST NOT ADD A FORGE ROUND TRIP (S152). Measured two ways, because
       either one alone leaves a hole:

         (a) EXACT, and immune to timing. `window.fetch` is counted and the
             counter is read BEFORE and AFTER fifty filter applications INSIDE
             ONE SYNCHRONOUS JS TURN — no timer, no SSE tick and no safety poll
             can interleave with a synchronous block, so this delta is caused by
             the clicks and by nothing else. Filtering reaches no endpoint,
             therefore it reaches no `gh`.
         (b) THE SUBPROCESS ITSELF. The gh shim's log, counted either side of
             that same evaluate. This is what a page-level counter cannot see.
             It CAN catch the daemon's own cache-expiry poll landing in the
             window, which is not the filter's doing — so when (a) says the
             clicks fetched nothing and the count still moved, the window is
             re-taken rather than blamed. Three tries; still moving with zero
             fetches is a real failure, not a flake. */
    const EX = `(function () {
      if (!window.__lcarsFetchN) {
        window.__lcarsFetchN = 0;
        var f = window.fetch;
        window.fetch = function () { window.__lcarsFetchN++; return f.apply(this, arguments); };
      }
      var before = window.__lcarsFetchN, n = 0;
      var ids = ["mine", "theirs", "unassigned", "remote", "all"];
      for (var pass = 0; pass < 10; pass++) {
        for (var i = 0; i < ids.length; i++) {
          var b = document.querySelector('#ownerFilter button[data-filter="' + ids[i] + '"]');
          if (b) { b.click(); n++; }
        }
      }
      return { applications: n, fetches: window.__lcarsFetchN - before };
    })()`;
    let ex = null, ghDelta = null, ghBefore = null, ghAfter = null, tries = 0;
    while (tries < 3) {
      tries++;
      ghBefore = ghCalls();
      ex = await evaluate(cdp, sessionId, EX);
      ghAfter = ghCalls();
      if (ghBefore === null || ghAfter === null) break;
      ghDelta = ghAfter - ghBefore;
      if (ghDelta === 0 || !ex || ex.fetches !== 0) break;
      // zero fetches from the page and gh still moved ⇒ the daemon's own cache
      // expiry landed in the window. Not the filter's doing; take it again.
      await sleep(400);
    }
    if (ghBefore === null) {
      skip("filtering costs ZERO gh invocations",
           "the shim log was unreadable at " + path.join(OUT, "shim.log") +
           " — NOT a pass");
    } else if (!ex || !ex.applications) {
      bad("filtering costs ZERO gh invocations",
          "the exercise applied no filters at all: " + JSON.stringify(ex));
    } else {
      const gd = ex.applications + " filter applications · page fetches " +
        ex.fetches + " · gh invocations " + ghBefore + " → " + ghAfter +
        " (delta " + ghDelta + ", " + tries + " window(s))";
      if (ex.fetches === 0 && ghDelta === 0) {
        ok("filtering costs ZERO fetches and ZERO gh invocations (S152)", gd);
      } else {
        bad("filtering costs ZERO fetches and ZERO gh invocations (S152)", gd);
      }
    }

    /* ── EACH FILTER SELECTS THE RIGHT CARDS, AND THE COUNTS AGREE. Read off
       the DOM of the running product: what the chip printed, what the board
       drew, and what each column head still claims. A head that keeps counting
       cards it is no longer drawing is the board disagreeing with itself in the
       one place a captain checks a number. */
    const base = {};
    fstate.chips.forEach((c) => { base[c.id] = c; });
    let mineCards = null;
    for (const id of ["all", "mine", "theirs", "unassigned", "remote"]) {
      if (!base[id]) continue;
      await clickChip("all");
      await clickChip(id);
      const st = await evaluate(cdp, sessionId, FILTER_PROBE);
      if (id === "mine") mineCards = st.cards.slice().sort();
      const headsBad = st.heads.filter((h) => String(h.drawn) !== h.ct);
      const d = "chip says " + base[id].count + ", board drew " +
        st.cards.length + " " + JSON.stringify(st.cards.slice().sort());
      if (st.cards.length !== base[id].count) {
        bad("the " + id.toUpperCase() + " chip's count is what the board draws", d);
      } else if (headsBad.length) {
        bad("the " + id.toUpperCase() + " chip's count is what the board draws",
            d + " — but column head(s) still claim " +
            JSON.stringify(headsBad.map((h) => h.ct + " over " + h.drawn)));
      } else if (st.cards.length === 0) {
        bad("the " + id.toUpperCase() + " chip's count is what the board draws",
            "it emptied the board — no facet on this fixture selects nothing");
      } else {
        ok("the " + id.toUpperCase() + " chip's count is what the board draws", d);
      }
    }
    // …and the facets are DIFFERENT selections, not the same board five times.
    await clickChip("all");
    await clickChip("theirs");
    const theirsCards = (await evaluate(cdp, sessionId, FILTER_PROBE)).cards;
    if (mineCards && theirsCards.length &&
        !theirsCards.some((c) => mineCards.indexOf(c) >= 0)) {
      ok("MINE and THEIRS select disjoint sets of cards",
         JSON.stringify(mineCards) + " vs " + JSON.stringify(theirsCards.sort()));
    } else {
      bad("MINE and THEIRS select disjoint sets of cards",
          JSON.stringify(mineCards) + " vs " + JSON.stringify(theirsCards));
    }

    /* ── THE `o` KEY, DISPATCHED AT THE BROWSER. Not `.click()` on a chip: a
       real key event through the real hotkey layer, past all four of its
       guards, on the real page. A binding that shadowed an existing key would
       show up here as the wrong thing happening. */
    await clickChip("all");
    for (const type of ["keyDown", "keyUp"]) {
      await cdp.send("Input.dispatchKeyEvent", {
        type, key: "o", code: "KeyO", text: type === "keyDown" ? "o" : undefined,
        unmodifiedText: type === "keyDown" ? "o" : undefined,
        windowsVirtualKeyCode: 79, nativeVirtualKeyCode: 79,
      }, sessionId);
    }
    await sleep(150);
    const afterKey = await evaluate(cdp, sessionId, FILTER_PROBE);
    const keyed = afterKey.chips.filter((c) => c.pressed === "true")[0];
    if (keyed && keyed.id === "mine" && afterKey.cards.length === base.mine.count) {
      ok("the `o` key cycles the filter on the real page",
         "ALL → " + keyed.text + ", " + afterKey.cards.length + " card(s) drawn");
    } else {
      bad("the `o` key cycles the filter on the real page",
          "selected " + JSON.stringify(keyed && keyed.id) + ", " +
          afterKey.cards.length + " card(s) drawn");
    }
    // …and the STATUS LINE says the board is filtered, rather than reporting a
    // mission count it is no longer showing.
    if (/filtered/i.test(afterKey.status) &&
        afterKey.status.indexOf(String(afterKey.cards.length)) >= 0) {
      ok("a filtered board says so in its own status line",
         JSON.stringify(afterKey.status));
    } else {
      bad("a filtered board says so in its own status line",
          JSON.stringify(afterKey.status));
    }
    /* …AND BOTH ITS NUMBERS COUNT THE BOARD THE CAPTAIN IS LOOKING AT. S196 B5
       fix round 1, and the reason this fixture now carries a DONE card:
       `board.missions` excludes done, `board.columns` does not, and the first
       cut of this sentence took its numerator AND its denominator off
       `missions` while the chip above it and the heads beside it counted
       `columns`. On a board with one done mission that is `MINE · 3`, three
       cards drawn, and a footer reading "2 of 6" — three numbers, two of them
       wrong, in one glance. Read here off the DOM: the numerator against the
       cards ACTUALLY drawn, the denominator against the ALL chip. The word
       "active" is barred outright — the honest unfiltered line owns it, and
       borrowing it for a sentence counting every card would re-tell the lie in
       words instead of digits. */
    const nOfM = /(-?\d+)\s+of\s+(-?\d+)/.exec(afterKey.status || "");
    const allChip = afterKey.chips.filter((c) => c.id === "all")[0];
    const sd = JSON.stringify(afterKey.status) + " over " +
      afterKey.cards.length + " card(s) drawn of " +
      (allChip ? allChip.count : "?") + " on the board" +
      (nOfM ? "" : " (no `N of M` in it at all)");
    if (!nOfM || !allChip) {
      bad("the filtered status line counts the CARDS, done included", sd);
    } else if (Number(nOfM[1]) !== afterKey.cards.length ||
               Number(nOfM[2]) !== allChip.count) {
      bad("the filtered status line counts the CARDS, done included",
          sd + " — wanted " + afterKey.cards.length + " of " + allChip.count);
    } else if (/active/i.test(afterKey.status)) {
      bad("the filtered status line counts the CARDS, done included",
          sd + " — it says `active` while counting every card, done included");
    } else {
      ok("the filtered status line counts the CARDS, done included", sd);
    }
    await shoot(cdp, sessionId,
      { x: 0, y: 0, w: fit.w, h: Math.min(fit.h, 900) },
      "filtered-board.png", 1, 0);

    /* ── IT SURVIVES A REFRESH. The real one: reload the page, boot board.js
       from scratch, and find the question the captain asked still being asked —
       out of the browser's own localStorage, not out of anything this drive
       kept in a variable. */
    const wantAfterReload = afterKey.cards.slice().sort();
    await cdp.send("Page.reload", { ignoreCache: false }, sessionId);
    let reloaded = null;
    for (let i = 0; i < 80 && Date.now() < deadline; i++) {
      await sleep(250);
      try { reloaded = await evaluate(cdp, sessionId, FILTER_PROBE); }
      catch (e) { reloaded = null; }
      if (reloaded && reloaded.present && !reloaded.hidden && reloaded.cards.length) break;
    }
    if (!reloaded || !reloaded.present) {
      bad("the filter survives a refresh", "the board never came back after reload");
    } else {
      const still = reloaded.chips.filter((c) => c.pressed === "true")[0];
      const got = reloaded.cards.slice().sort();
      const rd = "after reload: " + JSON.stringify(still && still.text) +
        " selected, cards " + JSON.stringify(got);
      if (still && still.id === "mine" &&
          JSON.stringify(got) === JSON.stringify(wantAfterReload)) {
        ok("the filter survives a refresh", rd);
      } else {
        bad("the filter survives a refresh",
            rd + " (wanted MINE and " + JSON.stringify(wantAfterReload) + ")");
      }
      /* …AND IDENTITY ABSENT CHANGES NOTHING — the S190 posture, applied to a
         REMEMBERED preference. He filters to THEIRS on a laptop with a live
         `gh`; the auth expires and the payload stops carrying `meta.self`. The
         board can no longer say what "somebody else" means, so it must not
         offer the question — and the answer it can no longer give must not be
         allowed to blank the board.

         Driven through the product's own degrade path rather than by reaching
         into it: `captureForgeIdentity` re-reads `meta.self` on EVERY render
         precisely so a payload that stops carrying one reverts to "we do not
         know", so dropping it from the board this page already holds and
         repainting is exactly what an expired auth looks like from here. The
         STORED choice is checked afterwards because a preference that got
         silently rewritten by a network hiccup is the other way to fail this. */
      await clickChip("all");
      await clickChip("theirs");
      const degraded = await evaluate(cdp, sessionId, `(function () {
        if (LAST_BOARD && LAST_BOARD.meta) LAST_BOARD.meta.self = null;
        repaintBoard();
        var host = document.getElementById("ownerFilter");
        var chips = host ? Array.prototype.slice.call(host.querySelectorAll("button")) : [];
        return {
          ids: chips.map(function (b) { return b.getAttribute("data-filter"); }),
          cards: document.querySelectorAll(".board .card[data-mid]").length,
          stored: (function () { try { return localStorage.getItem("lcars-owner-filter"); } catch (e) { return null; } })()
        };
      })()`);
      const dd = "identity gone → chips " + JSON.stringify(degraded.ids) +
        ", " + degraded.cards + " of " + wantAllCount +
        " card(s) still drawn, stored choice kept as " +
        JSON.stringify(degraded.stored);
      if (degraded.cards === wantAllCount &&
          degraded.ids.indexOf("mine") < 0 && degraded.ids.indexOf("theirs") < 0 &&
          degraded.stored === "theirs") {
        ok("with no identity the board shows EVERYTHING and offers no MINE", dd);
      } else {
        bad("with no identity the board shows EVERYTHING and offers no MINE",
            dd + " (wanted " + wantAllCount + " cards, no mine/theirs chip, and " +
            "the stored choice untouched)");
      }
    }
  }

  fs.writeFileSync(path.join(OUT, "owner-paint.json"), JSON.stringify({
    lock, pair, fills: { live: liveFill, locked: lockFill, separation: sep },
    sheets, detail: det, avatar: base, inkAndPaper: ip,
    s196: { pills: pills, ownerColourSeparation: colourSep,
            ownerGreyscaleSeparation: greySep, remotes: remotes,
            remoteDetail: rdet, remoteSeparation: remoteSep,
            ownerFilter: fstate,
            beam: { settled: beamSettled, pending: beamPending,
                    collapsed: beamDead } },
    findings, pageErrors: cdp.pageErrors,
  }, null, 2) + "\n");

  console.log("\nbeam: " + path.join(OUT, "beam-pad-mid-loop.png") +
              "  (S196 — the pad, mid-loop, with the portrait's GET held)");
  console.log("      " + path.join(OUT, "beam-settled-pill.png") +
              "  (S196 — the same pill once the portrait has arrived)");
  console.log("\ns196: " + path.join(OUT, "owner-pair-greyscale.png") +
              "  (B1 — the colour taken away)");
  console.log("      " + path.join(OUT, "remote-detail-locked-vs-live.png") +
              "  (B2 — the pair that measured 1.79:1)");
  console.log("      " + path.join(OUT, "owner-filter-strip.png") +
              "  (B5 — the strip, solid = asking, hollow = not)");
  console.log("      " + path.join(OUT, "filtered-board.png") +
              "  (B5 — the board with MINE applied)");
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
