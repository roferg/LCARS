#!/usr/bin/env node
/* S224 — the two-column verdict header, driven in REAL headless Chrome over
 * raw CDP against a REAL daemon and the captain's REAL missions.
 *
 *   node drive.js --devtools-port N --url BOARD_URL --out DIR \
 *                 --regrade <mission with two verdicts> \
 *                 --first   <mission with one verdict>
 *
 * A node DOM harness is a browser stub; this is the other half. Every claim
 * about anything the CASCADE decides is read as a COMPUTED style, and a fold
 * is proved unpainted with checkVisibility() — getBoundingClientRect() on a
 * closed <details> still returns its last laid-out box and would lie.
 *
 * Prints one JSON object with `checks`; exit 0 only when every check is ok.
 */
const fs = require("fs"), path = require("path");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), OUT = arg("out", ".");
const M_RE = arg("regrade"), M_1 = arg("first");
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
async function shot(name, clipSel) {
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
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: w, height: h, deviceScaleFactor: 1, mobile: w < 700 }, sid);
}
const out = { checks: [], shots: [], m: {} };
function check(name, ok, detail) { out.checks.push({ name, ok: !!ok, detail: detail === undefined ? null : detail }); }
const Q = (s) => JSON.stringify(s);

async function openReport(mid) {
  await cdp.send("Page.navigate", { url: URL }, sid);
  const seen = await waitFor(`!!document.querySelector('.card[data-mid=${Q(mid)}]')`, 30000);
  if (!seen) throw new Error("card never appeared: " + mid);
  await sleep(500);
  await ev(`(function(){var c=document.querySelector('.card[data-mid=${Q(mid)}]');`
    + `var b=c&&c.querySelector('.xo-read-report'); if(b){b.click();return true} return false})()`);
  const pane = await waitFor(`!!document.querySelector('.xo-pane .xo-verdict')`, 20000);
  if (!pane) throw new Error("the report pane never opened for " + mid);
  await sleep(600);
}

/* Everything the cascade decides, read back as COMPUTED — a rule that ties on
   specificity loses on source order and never reaches the screen (S162). */
const PROBE = `(function(){
  var q=function(s){return document.querySelector(s)};
  var all=function(s){return Array.prototype.slice.call(document.querySelectorAll(s))};
  var head=q('.xo-pane .xo-verdict'), rail=q('.xo-pane .xo-rail'), col=q('.xo-pane .xo-vtext');
  if(!head||!rail||!col) return {missing:true};
  var hs=getComputedStyle(head), rb=rail.getBoundingClientRect(), cb=col.getBoundingClientRect();
  var bars=all('.xo-pane .xo-bar');
  var segs=bars.map(function(b){return all('.xo-seg',b).map(function(s){
      var cs=getComputedStyle(s);
      return {w:s.getBoundingClientRect().width, bg:cs.backgroundColor,
              img:cs.backgroundImage, cls:s.className};
  })});
  var det=q('.xo-pane details.xo-more'), body=det&&det.querySelector('.xo-more-body');
  var lede=q('.xo-pane .xo-lede');
  return {
    display:hs.display, cols:hs.gridTemplateColumns,
    rail:{x:rb.left,r:rb.right,y:rb.top,b:rb.bottom,w:rb.width},
    col:{x:cb.left,r:cb.right,y:cb.top,b:cb.bottom,w:cb.width},
    bars:bars.map(function(b){var cs=getComputedStyle(b);
      return {cls:b.className,opacity:cs.opacity,gap:cs.columnGap||cs.gap,w:b.getBoundingClientRect().width}}),
    segs:segs,
    legend:all('.xo-pane .xo-legend-row').map(function(r){return r.textContent.trim()}),
    deltas:all('.xo-pane .xo-legend-d').map(function(r){return r.textContent.trim()}),
    barlabs:all('.xo-pane .xo-barlab').map(function(r){return r.textContent.trim()}),
    changed:q('.xo-pane .xo-changed')?q('.xo-pane .xo-changed').textContent.trim():null,
    needs:q('.xo-pane .xo-needs')?q('.xo-pane .xo-needs').textContent.trim().slice(0,120):null,
    measured:q('.xo-pane .xo-measured-lede')?q('.xo-pane .xo-measured-lede').textContent.trim():null,
    grade:q('.xo-pane .xo-grade-chip')?q('.xo-pane .xo-grade-chip').textContent.trim():null,
    score2:q('.xo-pane .xo-score2')?q('.xo-pane .xo-score2').textContent.trim():null,
    score2H:q('.xo-pane .xo-score2')?Math.round(q('.xo-pane .xo-score2').getBoundingClientRect().height):-1,
    showmeInCol:!!(col.querySelector('.xo-showme')),
    showmeChips:all('.xo-pane .xo-showme .xo-filter').length,
    showmeLast:(col.lastElementChild&&col.lastElementChild.className)||'',
    ledeW: lede? lede.getBoundingClientRect().width : -1,
    foldClosed: det? det.open : null,
    /* A CLOSED <details> STILL REPORTS ITS LAST LAID-OUT BOX, so the rect is
       not evidence. checkVisibility() is. */
    foldBodyPainted: body? body.checkVisibility() : null,
    /* THE PAGE-LEVEL scrollWidth IS NOT THE MEASUREMENT. div.board is a row
       of Kanban columns and scrolls sideways BY DESIGN — asking the document
       whether anything is wider than the window answers a question about the
       board, not about this report, and would have "failed" a header that fits
       perfectly. What matters is whether the REPORT overflows its own pane. */
    paneOverflow: (function(){
      var pane=q('.xo-pane'); if(!pane) return null;
      var pr=pane.getBoundingClientRect().right, worst=0, who='';
      var kids=pane.querySelectorAll('*');
      for (var i=0;i<kids.length;i++){
        var b=kids[i].getBoundingClientRect();
        if (b.width<=0 && b.height<=0) continue;
        if (b.right-pr > worst) { worst=b.right-pr; who=kids[i].className; }
      }
      return {px:Math.round(worst), who:String(who).slice(0,60),
              scrollW:pane.scrollWidth, clientW:pane.clientWidth};
    })(),
    scrollW: document.documentElement.scrollWidth,
    clientW: document.documentElement.clientWidth
  };
})()`;

const OPEN_FOLD = `(function(){var d=document.querySelector('.xo-pane details.xo-more');
  if(!d) return null; d.open=true; var b=d.querySelector('.xo-more-body');
  return b? b.checkVisibility() : null})()`;

const WORKED = "rgb(47, 116, 192)";    // #2F74C0
const DIDNT  = "rgb(192, 111, 30)";    // #C06F1E
const NOCHK  = "rgb(110, 104, 120)";   // #6E6878

async function run(tag, mid, expectTwo) {
  await viewport(1600, 1100);
  await openReport(mid);
  const w = await ev(PROBE);
  out.m[tag + "@1600"] = w;
  if (w.missing) { check(tag + ": the header rendered at all", false, w); return; }

  check(tag + ": the header is two columns", w.display === "grid"
    && /\S+\s+\S+/.test(w.cols), { display: w.display, cols: w.cols });
  const railW = parseFloat(w.cols.split(/\s+/)[0]);
  check(tag + ": the rail is 160–205px wide", railW >= 160 && railW <= 205.5, w.cols);
  check(tag + ": the words sit BESIDE the numbers, not under them",
    w.rail.r <= w.col.x + 1 && Math.abs(w.rail.y - w.col.y) < 40,
    { rail: w.rail, col: w.col });
  check(tag + ": the prose is capped at a readable measure",
    w.ledeW > 0 && w.ledeW <= 700, { ledeW: w.ledeW, colW: w.col.w });

  // the bar, and the one palette that was validated rather than chosen
  check(tag + ": " + (expectTwo ? "two bars" : "one bar"),
    w.bars.length === (expectTwo ? 2 : 1), w.barlabs);
  const flat = [].concat.apply([], w.segs);
  const byCls = (k) => flat.filter((s) => s.cls.indexOf("xo-seg-" + k) >= 0);
  check(tag + ": 'worked' is the validated blue",
    byCls("w").length > 0 && byCls("w").every((s) => s.bg === WORKED),
    byCls("w").map((s) => s.bg));
  check(tag + ": 'couldn't check' is the muted grey",
    byCls("c").length > 0 && byCls("c").every((s) => s.bg === NOCHK),
    byCls("c").map((s) => s.bg));
  const d = byCls("d");
  check(tag + ": 'didn't work' is the validated orange AND hatched",
    d.every((s) => s.bg === DIDNT && s.img && s.img !== "none"),
    d.map((s) => [s.bg, (s.img || "").slice(0, 60)]));
  check(tag + ": the segments are separated by a real 2px surface gap",
    w.bars.every((b) => b.gap === "2px"), w.bars.map((b) => b.gap));
  check(tag + ": every count is written out in the legend",
    w.legend.length === 3 && /worked/.test(w.legend[0])
    && /didn't work/.test(w.legend[1]) && /couldn't check/.test(w.legend[2]),
    w.legend);

  if (expectTwo) {
    check(tag + ": the first look is held back, the now is not",
      parseFloat(w.bars[0].opacity) < 1 && parseFloat(w.bars[1].opacity) === 1,
      w.bars.map((b) => b.opacity));
    check(tag + ": both bars are drawn on ONE scale",
      Math.abs(w.bars[0].w - w.bars[1].w) < 1.5, w.bars.map((b) => b.w));
    check(tag + ": the legend carries a delta per outcome",
      w.deltas.length === 3, w.deltas);
    check(tag + ": what changed is on the screen",
      !!w.changed && /bugs? filed/.test(w.changed) && /Why it's/.test(w.changed),
      (w.changed || "").slice(0, 200));
    check(tag + ": the grade says what it WAS before the fixes",
      !!w.score2 && /was /.test(w.score2), w.score2);
    // it is a CHIP, and a chip that wraps is a box. Measured, not eyeballed.
    check(tag + ": …on one line, inside the rail",
      w.score2H > 0 && w.score2H < 24, { h: w.score2H, railW: w.rail.w });
  } else {
    check(tag + ": a first look claims no deltas", w.deltas.length === 0, w.deltas);
    check(tag + ": and grows no 'what changed' block", w.changed === null, w.changed);
    check(tag + ": and no 'first look' label either",
      !w.barlabs.some((t) => /First look/.test(t)), w.barlabs);
  }

  check(tag + ": the chips are the last control in the column",
    w.showmeInCol && w.showmeChips >= 3 && /xo-showme/.test(w.showmeLast),
    { inCol: w.showmeInCol, chips: w.showmeChips, last: w.showmeLast });

  // the fold — proved unpainted, not merely un-boxed
  check(tag + ": the reasoning starts folded away and is NOT painted",
    w.foldClosed === false && w.foldBodyPainted === false,
    { open: w.foldClosed, painted: w.foldBodyPainted });
  const opened = await ev(OPEN_FOLD);
  check(tag + ": …and one tap paints every word of it", opened === true, opened);
  await ev(`(function(){var d=document.querySelector('.xo-pane details.xo-more'); if(d) d.open=false})()`);
  await sleep(150);

  await shot(tag + "-1600");
  await shot(tag + "-1600-header", ".xo-pane .xo-verdict");

  // ── THE PHONE ────────────────────────────────────────────────────────────
  await viewport(400, 900);
  await sleep(500);
  const p = await ev(PROBE);
  out.m[tag + "@400"] = p;
  check(tag + " @400: the rail stacks to ONE column",
    p.display === "grid" && !/\S+\s+\S+/.test(p.cols) && p.rail.b <= p.col.y + 1,
    { cols: p.cols, rail: p.rail, col: p.col });
  check(tag + " @400: nothing in the report runs off the side of it",
    p.paneOverflow && p.paneOverflow.px <= 1
    && p.paneOverflow.scrollW <= p.paneOverflow.clientW + 1, p.paneOverflow);
  check(tag + " @400: the bar is still there and still says its counts",
    p.bars.length === (expectTwo ? 2 : 1) && p.legend.length === 3, p.legend);
  // CLIPPED to the header: an unclipped capture of this page is 15,000px tall
  // and shows nothing a reader can see.
  await shot(tag + "-400", ".xo-pane .xo-verdict");
}

(async () => {
  let ver = null, dl = Date.now() + 30000;
  while (Date.now() < dl) {
    try { const r = await fetch("http://127.0.0.1:" + PORT + "/json/version"); if (r.ok) { ver = await r.json(); break; } } catch (e) {}
    await sleep(120);
  }
  if (!ver) { console.error("no devtools on " + PORT); process.exit(77); }
  cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  const t = await cdp.send("Target.createTarget", { url: "about:blank" });
  sid = (await cdp.send("Target.attachToTarget", { targetId: t.targetId, flatten: true })).sessionId;
  await cdp.send("Page.enable", {}, sid);
  await cdp.send("Runtime.enable", {}, sid);
  try {
    await run("regrade", M_RE, true);
    await run("firstlook", M_1, false);
  } catch (e) {
    check("the drive completed", false, String(e && e.message || e));
  }
  check("no uncaught page exceptions", cdp.errs.length === 0, cdp.errs.slice(0, 5));
  console.log(JSON.stringify(out, null, 1));
  process.exit(out.checks.every((c) => c.ok) ? 0 : 1);
})().catch((e) => { console.error(String(e && e.stack || e)); process.exit(70); });
