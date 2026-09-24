#!/usr/bin/env node
/* S224 FIX ROUND 1 — the captain's four notes, measured in REAL headless
 * Chrome against a REAL daemon and his REAL re-checked mission.
 *
 *   node fix.js --devtools-port N --url BOARD_URL --out DIR --mission <id>
 *
 * Fix round 2 adds a fifth: "Show me should span completely" / "the previous
 * image text should span as well" — the boxes spanned and the SENTENCES in
 * them still stopped at 68ch, so every prose block is now measured against
 * its own container's content width.
 *
 * The four:
 *   D1  "No space."           — the gap between the Show me box and the first
 *                               item card, in computed pixels.
 *   D2/D3 "so much dead space" — the HEADER's content band against the ITEM
 *                               cards' band: same left edge, same right edge,
 *                               at 1280 / 1440 / 1690 / 400 and side by side.
 *   D4  "What happened to the pictures being inline?" — every thumbnail in the
 *                               ledger must actually LOAD (naturalWidth > 0),
 *                               not merely be an <img> that is present.
 *
 * A node DOM harness is a browser stub; this is the other half. Everything the
 * CASCADE decides is read as a computed value or a laid-out box, never
 * asserted from a rule existing.
 *
 * Prints one JSON object; exit 0 only when every check is ok.
 */
const fs = require("fs"), path = require("path");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), OUT = arg("out", ".");
const MID = arg("mission");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

class CDP {
  constructor(ws) {
    this.ws = ws; this.next = 1; this.pending = new Map(); this.errs = [];
    ws.addEventListener("message", (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) {
        const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); return;
      }
      if (m.method === "Runtime.exceptionThrown") this.errs.push(String((m.params.exceptionDetails || {}).text));
    });
  }
  send(method, params, sid) {
    const id = this.next++; const pl = { id, method, params: params || {} };
    if (sid) pl.sessionId = sid; this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej }));
  }
}
const connect = (u) => new Promise((res, rej) => {
  const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused")), { once: true });
});

let cdp, sid;
async function ev(expr) {
  const r = await cdp.send("Runtime.evaluate",
    { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r && r.exceptionDetails) throw new Error("probe threw: " + JSON.stringify(r.exceptionDetails));
  return r && r.result ? r.result.value : null;
}
async function waitFor(expr, ms) {
  const dl = Date.now() + (ms || 20000);
  while (Date.now() < dl) { try { if (await ev(expr)) return true; } catch (e) {} await sleep(120); }
  return false;
}
const out = { checks: [], shots: [], m: {} };
function check(name, ok, detail) { out.checks.push({ name, ok: !!ok, detail: detail === undefined ? null : detail }); }
const Q = (s) => JSON.stringify(s);

/* `viewportOnly` is what the captain actually sees: the report is a FIXED
   overlay over a scrolling board, so a full-page capture renders the kanban
   columns behind it and not the pane at all. A band claim has to be shown on
   the picture it was measured on. */
async function shot(name, clipSel, viewportOnly) {
  if (viewportOnly) {
    await ev(`(function(){var p=document.querySelector('.xo-pane');`
      + `if(p&&p.parentNode&&p.parentNode.scrollTo) p.parentNode.scrollTo(0,0);`
      + `var h=document.querySelector('.xo-pane .xo-verdict');`
      + `if(h) h.scrollIntoView({block:'start'}); return 1})()`);
    await sleep(350);
    const img = await cdp.send("Page.captureScreenshot",
      { format: "png", captureBeyondViewport: false }, sid);
    const f = path.join(OUT, name + ".png");
    fs.writeFileSync(f, Buffer.from(img.data, "base64"));
    out.shots.push(f);
    return f;
  }
  let params = { format: "png", captureBeyondViewport: true };
  if (clipSel) {
    await ev(`(function(){var e=document.querySelector(${JSON.stringify(clipSel)}); if(e) e.scrollIntoView({block:'start'}); return !!e})()`);
    await sleep(250);
    const r = await ev(`(function(){var e=document.querySelector(${JSON.stringify(clipSel)}); if(!e) return null; var b=e.getBoundingClientRect(); return {x:b.left+scrollX,y:b.top+scrollY,w:b.width,h:b.height}})()`);
    if (r && r.w > 0) params.clip = { x: Math.max(0, r.x - 8), y: Math.max(0, r.y - 8), width: r.w + 16, height: r.h + 16, scale: 1 };
  }
  const img = await cdp.send("Page.captureScreenshot", params, sid);
  const f = path.join(OUT, name + ".png");
  fs.writeFileSync(f, Buffer.from(img.data, "base64"));
  out.shots.push(f);
  return f;
}
async function viewport(w, h) {
  // mobile:false EVEN AT 400. With mobile emulation on, the page's own
  // viewport meta re-scales the layout and `innerWidth` came back 644 for a
  // 400px device — so a claim "measured at 400" would have been measured at
  // 644. The claim here is about the CSS width the layout actually got, and
  // this is the setting under which the window reports the width asked for.
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: w, height: h, deviceScaleFactor: 1, mobile: false }, sid);
}

async function openReport(mid) {
  // START FROM A KNOWN STATE. Side-by-side is persisted in localStorage, so
  // a run inherits whatever the last one left — which is how one pass of this
  // drive measured the full-width layout and the next measured side-by-side
  // from the same line of code. The four widths are the SOLO layout; the
  // side-by-side pass below turns it on deliberately.
  await cdp.send("Page.navigate", { url: URL }, sid);
  await waitFor(`!!document.body`, 15000);
  await ev(`(function(){try{localStorage.removeItem('lcars.numberOne.sideBySide')}catch(e){}return 1})()`);
  await cdp.send("Page.navigate", { url: URL }, sid);
  const seen = await waitFor(`!!document.querySelector('.card[data-mid=${Q(mid)}]')`, 30000);
  if (!seen) throw new Error("card never appeared: " + mid);
  await sleep(500);
  await ev(`(function(){var c=document.querySelector('.card[data-mid=${Q(mid)}]');`
    + `var b=c&&c.querySelector('.xo-read-report'); if(b){b.click();return true} return false})()`);
  const pane = await waitFor(`!!document.querySelector('.xo-pane .xo-verdict')`, 20000);
  if (!pane) throw new Error("the report pane never opened for " + mid);
  await sleep(800);
}

/* ── THE BAND ──────────────────────────────────────────────────────────────
   The captain's rule: the header occupies the same horizontal band as the
   item cards below it — same left edge, same right edge — at every width.
   "The header's content band" is not the grid box (which always stretched);
   it is where the PAINTED content actually ends, which is what he read at
   x≈795. So it is measured off the boxes a reader can see: the rail and the
   three containers in the right column. Fix round 2: the PROSE inside them is
   measured too, against each container's content width — the captain's ruling
   is that the width is used, at every level. */
const BAND = `(function(){
  var q=function(s){return document.querySelector(s)};
  var all=function(s){return Array.prototype.slice.call(document.querySelectorAll(s))};
  var head=q('.xo-pane .xo-verdict');
  var items=all('.xo-pane .xo-items > .xo-item');
  if(!head||!items.length) return {missing:true};
  var vis=function(e){return e && e.checkVisibility && e.checkVisibility() &&
                             e.getBoundingClientRect().width>0};
  var boxes=all('.xo-pane .xo-rail, .xo-pane .xo-changed, .xo-pane .xo-showme, .xo-pane .xo-needs')
              .filter(vis);
  var L=Infinity,R=-Infinity;
  boxes.forEach(function(b){var r=b.getBoundingClientRect();
    if(r.left<L)L=r.left; if(r.right>R)R=r.right;});
  var ib=items[0].getBoundingClientRect();
  var iL=Infinity,iR=-Infinity;
  items.forEach(function(it){ if(!vis(it)) return; var r=it.getBoundingClientRect();
    if(r.left<iL)iL=r.left; if(r.right>iR)iR=r.right;});
  var show=q('.xo-pane .xo-showme');
  // THE HONEST GAP is to whatever the evidence list actually STARTS with —
  // on the captain's mission that is a bucket heading, and measuring past it
  // to the first card would report ~100px of separation that is mostly the
  // heading's own height. Both numbers are kept; the heading one is the claim.
  var list=q('.xo-pane .xo-items');
  var firstRow=list ? Array.prototype.slice.call(list.children).filter(vis)[0] : null;
  var gap = (show && firstRow)
    ? (firstRow.getBoundingClientRect().top - show.getBoundingClientRect().bottom) : null;
  var gapToCard = show ? (ib.top - show.getBoundingClientRect().bottom) : null;
  // WHAT THE GAP IS MADE OF, so a number can be read rather than trusted: the
  // header's own bottom margin, the pane's flex gap, and whatever the rail
  // leaves hanging below the right column (the rail is the taller track at
  // wide widths, so the header box ends below the Show me box).
  var hs=getComputedStyle(head), ps=getComputedStyle(head.parentNode);
  var parts={ headMarginBottom: hs.marginBottom, paneGap: ps.rowGap||ps.gap,
              // FOUND WHILE MEASURING: .tabpane.on (display block, 0,2,0)
              // outranks .xo-pane (display flex + 14px gap, 0,1,0), so the
              // pane's 14px rhythm has never applied while the tab is ON, and
              // .xo-pane > * zeroes every block's own margin. That is
              // literally "no space", and it is why this gap has to be stated
              // as a margin that outranks that reset.
              paneDisplay: ps.display,
              showMeToHeadBottom: show
                ? Math.round((head.getBoundingClientRect().bottom
                              - show.getBoundingClientRect().bottom)*10)/10
                : null,
              headBottomToCard: Math.round((ib.top-hb0())*10)/10 };
  function hb0(){ return head.getBoundingClientRect().bottom; }
  var hb=head.getBoundingClientRect();
  var lede=q('.xo-pane .xo-lede');
  return {
    win: innerWidth,
    headBox: {l:Math.round(hb.left), r:Math.round(hb.right), w:Math.round(hb.width)},
    headContent: {l:Math.round(L), r:Math.round(R), w:Math.round(R-L)},
    items: {l:Math.round(iL), r:Math.round(iR), n:items.length},
    // FIX ROUND 2 — THE TEXT SPANS TOO. Round 1 uncapped the boxes and left
    // the sentences at 68ch, so the dead space moved one level in: on a
    // desktop-width box the All-105 line stopped at 629px inside a
    // ~1300px frame. Each block is measured against its OWN container's
    // CONTENT width (border box minus borders and padding), which is the
    // width it can actually use. 'lines' is how many line boxes the text
    // paints: a one-line sentence that does not fill is a short sentence,
    // not a cap, and the number says which is which.
    text: (function(){
      var pairs=[['.xo-pane .xo-filters-key','.xo-pane .xo-showme'],
                 ['.xo-pane .xo-changed-line','.xo-pane .xo-changed'],
                 ['.xo-pane .xo-needs-line','.xo-pane .xo-needs'],
                 ['.xo-pane .xo-lede','.xo-pane .xo-vtext'],
                 ['.xo-pane .xo-more > summary','.xo-pane .xo-vtext']];
      return pairs.map(function(p){
        var e=q(p[0]), box=q(p[1]);
        if(!e||!box||!vis(e)) return {sel:p[0], missing:true};
        var bs=getComputedStyle(box);
        var inner=box.clientWidth
          - parseFloat(bs.paddingLeft||0) - parseFloat(bs.paddingRight||0);
        var r=document.createRange(); r.selectNodeContents(e);
        var rects=Array.prototype.slice.call(r.getClientRects());
        var widest=rects.reduce(function(m,x){return Math.max(m,x.width)},0);
        return {sel:p[0], el:Math.round(e.getBoundingClientRect().width),
                inner:Math.round(inner), widestLine:Math.round(widest),
                lines:rects.length,
                cap:getComputedStyle(e).maxWidth};
      });
    })(),
    gapShowMeToFirstCard: gap===null?null:Math.round(gap*10)/10,
    gapShowMeToFirstItemCard: gapToCard===null?null:Math.round(gapToCard*10)/10,
    firstRow: firstRow?firstRow.className:null,
    gapParts: parts,
    ledeWidth: lede?Math.round(lede.getBoundingClientRect().width):null,
    boxes: boxes.map(function(b){var r=b.getBoundingClientRect();
      return {cls:b.className, l:Math.round(r.left), r:Math.round(r.right)};}),
    gridCols: getComputedStyle(head).gridTemplateColumns,
    railStacked: getComputedStyle(head).gridTemplateColumns.split(' ').length===1
  };
})()`;

/* ── THE PICTURES ──────────────────────────────────────────────────────────
   naturalWidth, not "an <img> is present": a 404 still leaves the tag in the
   document, and the sentence the captain read was drawn by the img's own
   error handler. `decode()` is awaited so a lazy image that has not started
   is never counted as broken. */
const PICS = `(async function(){
  var all=function(s){return Array.prototype.slice.call(document.querySelectorAll(s))};
  var imgs=all('.xo-pane .xo-items img.xo-thumb');
  // EVERY thumbnail on the pane is un-lazied, the gaps' included: they sit
  // hundreds of pixels below the fold and a lazy image that never entered a
  // viewport reports naturalWidth 0 — which would read as "broken" and is
  // only "not asked for yet". Measuring that as a defect is the measurement
  // lying, not the page.
  all('.xo-pane img.xo-thumb').forEach(function(i){ i.loading='eager'; });
  await new Promise(function(r){setTimeout(r,2500)});
  var rows=[];
  for (var i=0;i<imgs.length;i++){
    var im=imgs[i];
    try { await im.decode(); } catch(e) {}
    rows.push({src:im.getAttribute('src'), nw:im.naturalWidth, nh:im.naturalHeight});
  }
  var gone=all('.xo-pane .xo-ev-none').map(function(n){return n.textContent})
             .filter(function(t){return t.indexOf("isn't on this laptop")>=0});
  var measured=all('.xo-pane .xo-ev-none').map(function(n){return n.textContent})
             .filter(function(t){return t.indexOf('a measured box settled')>=0});
  var gimgs=all('.xo-pane .xo-gap-row img.xo-thumb'), gaps=[];
  for (var k=0;k<gimgs.length;k++){
    try { await gimgs[k].decode(); } catch(e) {}
    gaps.push({src:gimgs[k].getAttribute('src'), nw:gimgs[k].naturalWidth});
  }
  return {n:rows.length, loaded:rows.filter(function(r){return r.nw>0}).length,
          broken:rows.filter(function(r){return !(r.nw>0)}).slice(0,5),
          sample:rows.slice(0,3), goneSentences:gone.length,
          measuredSentences:measured.length,
          gapThumbs:gaps.length, gapLoaded:gaps.filter(function(g){return g.nw>0}).length,
          gapSample:gaps.slice(0,2)};
})()`;

async function bandAt(label, w, h, tag) {
  await viewport(w, h);
  await sleep(700);
  const b = await ev(BAND);
  out.m[label] = b;
  if (!b || b.missing) { check("band@" + label, false, b); return null; }
  // A TOLERANCE, NAMED. The item card and the header box are two different
  // borders; 2px is the most a 1px border on each side can account for.
  const dL = Math.abs(b.headContent.l - b.items.l);
  const dR = Math.abs(b.headContent.r - b.items.r);
  check("left edges match @" + label, dL <= 2,
        { header: b.headContent.l, items: b.items.l, delta: dL });
  check("right edges match @" + label, dR <= 2,
        { header: b.headContent.r, items: b.items.r, delta: dR });
  // FIX ROUND 2: every prose block fills its container. A block element that
  // is uncapped IS its container's content width, so a mismatch here is a cap
  // that survived — and `cap` is read back as a computed value so "none" is a
  // fact, not the absence of a rule I remembered to delete.
  const capped = (b.text || []).filter((t) => !t.missing
    && (t.cap !== "none" || Math.abs(t.el - t.inner) > 2));
  check("the text spans its box @" + label, capped.length === 0,
        { capped, all: b.text });
  await shot(tag, null, true);
  return b;
}

(async function main() {
  const ver = await (await fetch("http://127.0.0.1:" + PORT + "/json/version")).json();
  cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  const tgt = await cdp.send("Target.createTarget", { url: "about:blank" });
  sid = (await cdp.send("Target.attachToTarget", { targetId: tgt.targetId, flatten: true })).sessionId;
  await cdp.send("Page.enable", {}, sid);
  await cdp.send("Runtime.enable", {}, sid);
  await cdp.send("Emulation.setEmulatedMedia",
    { features: [{ name: "prefers-reduced-motion", value: "reduce" }] }, sid);

  try {
    // ── the four widths, SOLO (the report filling the window) ────────────
    await viewport(1690, 1100);
    await openReport(MID);

    // D4 first: the pictures, on the widest layout, before anything is resized.
    const pics = await ev(PICS);
    out.m.pictures = pics;
    check("every ledger thumbnail LOADS (naturalWidth>0)",
          pics.n > 0 && pics.loaded === pics.n,
          { of: pics.n, loaded: pics.loaded, broken: pics.broken });
    check("no row says the picture is gone", pics.goneSentences === 0,
          { sentences: pics.goneSentences });
    check("the filed gaps' thumbnails still load",
          pics.gapThumbs === 0 || pics.gapLoaded === pics.gapThumbs,
          { of: pics.gapThumbs, loaded: pics.gapLoaded, sample: pics.gapSample });
    await shot("pics-1690-ledger", ".xo-pane .xo-items");
    await shot("pics-1690-view", null, true);

    const w1690 = await bandAt("1690", 1690, 1100, "band-1690");
    check("the Show me box is clear of the first card @1690",
          w1690 && w1690.gapShowMeToFirstCard >= 18,
          { gap: w1690 && w1690.gapShowMeToFirstCard });
    await shot("gap-1690", ".xo-pane .xo-showme");

    await bandAt("1440", 1440, 1000, "band-1440");
    await bandAt("1280", 1280, 900, "band-1280");

    // ── 400: the phone. The rail stacks; prose is expected to fill. ───────
    const p400 = await viewport(400, 900);
    await sleep(700);
    const b400 = await ev(BAND);
    out.m["400"] = b400;
    check("the rail stacks at 400", !!(b400 && b400.railStacked),
          b400 && b400.gridCols);
    check("the band still matches at 400",
          b400 && Math.abs(b400.headContent.l - b400.items.l) <= 2
              && Math.abs(b400.headContent.r - b400.items.r) <= 2,
          b400 && { header: b400.headContent, items: b400.items });
    const cap400 = ((b400 && b400.text) || []).filter((t) => !t.missing
      && (t.cap !== "none" || Math.abs(t.el - t.inner) > 2));
    check("the text spans its box @400", cap400.length === 0,
          { capped: cap400, all: b400 && b400.text });
    check("the Show me box is clear of the first card @400",
          b400 && b400.gapShowMeToFirstCard >= 18,
          b400 && { gap: b400.gapShowMeToFirstCard });
    await shot("band-400", null, true);

    // ── SIDE BY SIDE: the feed beside the report (the non-solo state) ─────
    await viewport(1690, 1100);
    await sleep(500);
    // THE BUTTON IS A TOGGLE AND THE CHOICE IS PERSISTED, so a blind click
    // lands wherever the LAST run left it — the first pass of this drive
    // measured side-by-side and the second measured full width, from the same
    // line of code. Click only while the window is still solo.
    let toggled = false;
    for (let i = 0; i < 2; i++) {
      const solo = await ev(`(function(){var g=document.querySelector('.detail-grid');`
        + `return !!(g&&g.className.indexOf('xo-solo')>=0)})()`);
      if (!solo) break;
      toggled = await ev(`(function(){var b=document.querySelector('.detail-side');`
        + `if(!b) return false; b.click(); return true})()`);
      await sleep(900);
    }
    await sleep(600);
    const side = await ev(`(function(){var g=document.querySelector('.detail-grid');`
      + `return g? {solo:g.className.indexOf('xo-solo')>=0, cls:g.className}:null})()`);
    out.m.sideState = { toggled, side };
    const bSide = await ev(BAND);
    out.m.sideBySide = bSide;
    check("side by side really engaged", !!(side && !side.solo), side);
    check("the band matches side by side",
          bSide && !bSide.missing
            && Math.abs(bSide.headContent.l - bSide.items.l) <= 2
            && Math.abs(bSide.headContent.r - bSide.items.r) <= 2,
          bSide && { header: bSide.headContent, items: bSide.items,
                     paneWidth: bSide.headBox.w });
    const capSide = ((bSide && bSide.text) || []).filter((t) => !t.missing
      && (t.cap !== "none" || Math.abs(t.el - t.inner) > 2));
    check("the text spans its box side by side", capSide.length === 0,
          { capped: capSide, all: bSide && bSide.text });
    check("the Show me box is clear of the first card side by side",
          bSide && bSide.gapShowMeToFirstCard >= 18,
          bSide && { gap: bSide.gapShowMeToFirstCard });
    await shot("band-sidebyside", null, true);

    check("no uncaught exception on the page", cdp.errs.length === 0, cdp.errs.slice(0, 3));
  } catch (e) {
    check("drive completed", false, String(e && e.message ? e.message : e));
  }

  process.stdout.write(JSON.stringify(out, null, 2) + "\n");
  process.exit(out.checks.every((c) => c.ok) ? 0 : 1);
})();
