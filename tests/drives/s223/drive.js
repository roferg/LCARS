#!/usr/bin/env node
/* S223 — the Number One reader, driven in REAL headless Chrome over raw CDP
 * against the REAL daemon (rig.sh). Reads COMPUTED styles, never rules.
 *
 *   node drive.js --devtools-port N --url BOARD_URL --out DIR --mission ID
 *                 [--engaged ID2]
 *
 * Prints one JSON object of measurements + a `checks` list of
 * {name, ok, detail}; exit 0 only when every check is ok. Screenshots land in
 * DIR (git-ignored under tests/drives/s223/shots/).
 */
const fs = require("fs"), path = require("path");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), OUT = arg("out", ".");
const MID = arg("mission"), MID2 = arg("engaged", "");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

class CDP {
  constructor(ws) { this.ws = ws; this.next = 1; this.pending = new Map(); this.errs = [];
    ws.addEventListener("message", (ev) => { let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); return; }
      if (m.method === "Runtime.exceptionThrown") this.errs.push(String((m.params.exceptionDetails || {}).text)); }); }
  send(method, params, sid) { const id = this.next++; const pl = { id, method, params: params || {} };
    if (sid) pl.sessionId = sid; this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej })); } }
const connect = (u) => new Promise((res, rej) => { const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused")), { once: true }); });

let cdp, sid;
async function ev(expr) {
  const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r && r.exceptionDetails) throw new Error("probe threw: " + JSON.stringify(r.exceptionDetails));
  return r && r.result ? r.result.value : null;
}
async function waitFor(expr, ms) { const dl = Date.now() + (ms || 15000);
  while (Date.now() < dl) { try { if (await ev(expr)) return true; } catch (e) {} await sleep(100); } return false; }
async function shot(name, clipSel) {
  let params = { format: "png" };
  if (clipSel) {
    await ev(`(function(){var e=document.querySelector(${JSON.stringify(clipSel)}); if(e) e.scrollIntoView({block:'center',inline:'center'}); return !!e})()`);
    await sleep(250);
    const r = await ev(`(function(){var e=document.querySelector(${JSON.stringify(clipSel)}); if(!e) return null; var b=e.getBoundingClientRect(); return {x:b.left,y:b.top,w:b.width,h:b.height}})()`);
    if (r && r.w > 0) params.clip = { x: Math.max(0, r.x - 4), y: Math.max(0, r.y - 4), width: r.w + 8, height: r.h + 8, scale: 1 };
  }
  const img = await cdp.send("Page.captureScreenshot", params, sid);
  const f = path.join(OUT, name + ".png"); fs.writeFileSync(f, Buffer.from(img.data, "base64")); return f;
}
async function viewport(w, h, mobile) {
  await cdp.send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: !!mobile }, sid);
}
async function reducedMotion(on) {
  await cdp.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: on ? "reduce" : "no-preference" }] }, sid);
}
const out = { checks: [], shots: [], m: {} };
function check(name, ok, detail) { out.checks.push({ name, ok: !!ok, detail: detail === undefined ? null : detail }); }

const Q = (s) => JSON.stringify(s);
const CARD = `document.querySelector('.card[data-mid=${Q(MID)}]')`;

async function openBoard() {
  await cdp.send("Page.navigate", { url: URL }, sid);
  await waitFor(`!!${CARD}`, 30000);
  await sleep(600);
}
async function openReportFromCard() {
  await ev(`(function(){var c=${CARD}; var b=c && c.querySelector('.xo-read-report'); if(b){b.click(); return true} return false})()`);
  await waitFor(`!!document.querySelector('.detail-grid .xo-pane')`);
  await sleep(700);
}
const GRIDW = `(function(){var g=document.querySelector('.detail-grid'); return g? g.getBoundingClientRect().width : -1})()`;

(async () => {
  let ver = null, dl = Date.now() + 30000;
  while (Date.now() < dl) { try { const r = await fetch("http://127.0.0.1:" + PORT + "/json/version"); if (r.ok) { ver = await r.json(); break; } } catch (e) {} await sleep(100); }
  if (!ver) { console.error("no devtools"); process.exit(77); }
  cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  const t = await cdp.send("Target.createTarget", { url: "about:blank" });
  sid = (await cdp.send("Target.attachToTarget", { targetId: t.targetId, flatten: true })).sessionId;
  await cdp.send("Page.enable", {}, sid); await cdp.send("Runtime.enable", {}, sid);
  await viewport(1600, 1000, false); await reducedMotion(false);
  await openBoard();
  await ev(`try{localStorage.removeItem("lcars.numberOne.sideBySide")}catch(e){}`);

  /* ── 6 · the card's score line ── */
  const pill = await ev(`(function(){var c=${CARD}; var p=c.querySelector('.xo-axes-pill'); if(!p) return null;
    var g=p.querySelector('.xo-grade'), a=p.querySelector('.xo-axes'); var col=c.closest('.col')||c.parentNode;
    var gs=getComputedStyle(g), as=getComputedStyle(a);
    return {text:a.textContent, grade:g.textContent, gradeColor:gs.color, axesColor:as.color, axesSize:parseFloat(as.fontSize),
      axesCase:as.textTransform, colW:col.getBoundingClientRect().width, pillW:p.getBoundingClientRect().width,
      pillScroll:p.scrollWidth, pillClient:p.clientWidth, cardW:c.getBoundingClientRect().width,
      bodyInk:getComputedStyle(document.body).getPropertyValue('--lcars-text-bright').trim()}})()`);
  out.m.pill = pill;
  check("6 card: sentence in plain words", pill && /point of the mission/.test(pill.text) && !/core/.test(pill.text) && /\d+ of \d+ checked/.test(pill.text), pill && pill.text);
  check("6 card: sentence at body contrast (ink rgb(228,238,255))", pill && pill.axesColor === "rgb(228, 238, 255)", pill && pill.axesColor);
  check("6 card: only the grade word coloured", pill && pill.gradeColor !== pill.axesColor, pill && pill.gradeColor);
  check("6 card: sentence body size, sentence case", pill && pill.axesSize >= 12 && pill.axesCase === "none", pill);
  check("6 card: fits its column (no overflow)", pill && pill.pillScroll <= pill.pillClient + 1 && pill.pillW <= pill.cardW, pill);
  out.shots.push(await shot("01-card-desktop", `.card[data-mid=${Q(MID)}]`));

  /* ── 1 · Read the full report → lands in FULL mode ── */
  await openReportFromCard();
  const full = await ev(`(function(){var g=document.querySelector('.detail-grid'); var f=g.querySelector('.feed');
    var act=g.querySelector('.tab[data-tab=act]'), sb=g.querySelector('.detail-side');
    var fr=f.getBoundingClientRect();
    return {cls:g.className, w:g.getBoundingClientRect().width, h:g.getBoundingClientRect().height, vw:innerWidth, vh:innerHeight,
      feedW:fr.width, feedOpacity:getComputedStyle(f).opacity, actVisible: !!act && !act.hidden,
      side: sb ? {text:sb.textContent, hidden:sb.hidden} : null, xoOn: !!g.querySelector('.tab[data-tab=xo].on')}})()`);
  out.m.full = full;
  check("1 full mode on arrival from the card", full.cls.includes("xo-full") && full.cls.includes("xo-solo") && full.xoOn, full.cls);
  check("1 window grows to almost the whole screen", full.w >= full.vw - 40 && full.h >= full.vh - 40, full);
  check("1 live activity steps aside (feed collapsed)", full.feedW < 2 && full.feedOpacity === "0", full);
  check("1 Activity › tab present; ⤡ Side by side in the title bar", full.actVisible && full.side && !full.side.hidden && /Side by side/.test(full.side.text), full);
  out.shots.push(await shot("02-full-report-desktop"));

  /* ── 1 · THE ACTIVITY › TAB SHOWS THE FEED (S223 fix round 1, D1) ──
     The fresh tester clicked it and got a blank window: the tab lit up while
     `.act-pane.tabpane.on` measured 0px wide with 1676 feed nodes inside it.
     `.xo-solo` collapses the feed's grid column to 0fr, and on this tab the
     feed has MOVED into the pane — leaving the panes as the body's only child,
     which lands in that 0fr column. Measured, never inferred: the pane's own
     box, and the feed's box inside it. */
  await ev(`document.querySelector('.detail-grid .tab[data-tab=act]').click()`);
  await sleep(800);
  const act = await ev(`(function(){var g=document.querySelector('.detail-grid');
    var p=g.querySelector('.act-pane'); var f=p?p.querySelector('.feed'):null;
    var pr=p?p.getBoundingClientRect():null, fr=f?f.getBoundingClientRect():null;
    // The widest VISIBLE block in the feed: .evt rows live inside collapsed
    // band-events[hidden] sections, so measuring the first one measures a
    // hidden node — the bands themselves are what a reader sees.
    var er={width:0};
    [].forEach.call(f?f.querySelectorAll('.feed-band, .feed-current, .evt, h4'):[],function(n){
      if(!n.getClientRects().length) return; var b=n.getBoundingClientRect(); if(b.width>er.width) er=b});
    return {on:!!(p&&p.classList.contains('on')), tabOn:!!g.querySelector('.tab[data-tab=act].on'),
      paneW:pr?pr.width:-1, paneH:pr?pr.height:-1, feedIn:!!f, feedW:fr?fr.width:-1,
      feedOpacity:f?getComputedStyle(f).opacity:null, nodes:f?f.querySelectorAll('*').length:0,
      evW:er?er.width:-1, gridW:g.getBoundingClientRect().width, cls:g.className,
      panes:[].map.call(g.querySelectorAll('.tabpane'),function(n){
        return {k:n.getAttribute('data-pane'), on:n.classList.contains('on'),
                disp:getComputedStyle(n).display, h:Math.round(n.getBoundingClientRect().height)}}),
      bodyKids:g.querySelector('.det-body').children.length}})()`);
  out.m.act = act;
  check("1 Activity › SHOWS the feed: the pane is full width, not 0px",
    act.on && act.tabOn && act.feedIn && act.paneW > act.gridW * 0.5 && act.feedW > 400 && act.feedOpacity === "1",
    act);
  check("1 Activity ›: a real, visible activity block is drawn with width", act.evW > 300, act);
  // …and the REPORT is gone while it is showing. `.xo-pane{display:flex}` used
  // to beat `.tabpane{display:none}` on source order, so the report stayed on
  // screen and the feed sat 17,000px below it: the tab looked empty.
  check("1 Activity › hides the report: exactly ONE pane is displayed",
    act.panes && act.panes.filter((p) => p.disp !== "none").length === 1
    && act.panes.every((p) => (p.disp !== "none") === p.on), act.panes);
  out.shots.push(await shot("02b-activity-tab"));
  await ev(`document.querySelector('.detail-grid .tab[data-tab=xo]').click()`);
  await sleep(800);
  const backToXo = await ev(`(function(){var g=document.querySelector('.detail-grid');
    var f=g.querySelector('.det-body > .feed'); var pane=g.querySelector('.xo-pane');
    return {feedBack:!!f, feedW:f?f.getBoundingClientRect().width:-1, cls:g.className,
      paneW:pane?pane.getBoundingClientRect().width:-1}})()`);
  out.m.backToXo = backToXo;
  check("1 leaving Activity › puts the one feed node back and the report keeps the width",
    backToXo.feedBack && backToXo.feedW < 2 && backToXo.paneW > 600 && backToXo.cls.includes("xo-solo"),
    backToXo);

  /* ── 3 · two text colours only, colour only in chips (COMPUTED) ── */
  const colours = await ev(`(function(){var pane=document.querySelector('.detail-grid .xo-pane');
    var ps=getComputedStyle(pane); var ink=null, muted=null;
    var probe=document.createElement('span'); probe.style.color='var(--xo-ink)'; pane.appendChild(probe); ink=getComputedStyle(probe).color;
    probe.style.color='var(--xo-muted)'; muted=getComputedStyle(probe).color; pane.removeChild(probe);
    var CHIP='.xo-chip2,.xo-grade-chip'; var seen={}, bad=[], chipCols={}; var n=0;
    var w=document.createTreeWalker(pane, NodeFilter.SHOW_TEXT);
    while(w.nextNode()){var t=w.currentNode; if(!t.nodeValue.trim()) continue; var e=t.parentElement; if(!e||!e.getClientRects().length) continue;
      var c=getComputedStyle(e).color; n++;
      if(e.closest(CHIP)){chipCols[c]=(chipCols[c]||0)+1; continue}
      seen[c]=(seen[c]||0)+1; if(c!==ink&&c!==muted&&bad.length<8) bad.push({cls:e.className,tag:e.tagName,color:c,text:t.nodeValue.trim().slice(0,50)});}
    return {ink:ink, muted:muted, textColours:seen, chipColours:chipCols, violations:bad, nodes:n}})()`);
  out.m.colours = colours;
  check("3 report prose uses ONLY ink + muted (computed, every visible text node)", colours.violations.length === 0 && Object.keys(colours.textColours).length <= 2, colours);
  check("3 colour lives in the chips", Object.keys(colours.chipColours).some((c) => c !== colours.ink && c !== colours.muted), colours.chipColours);

  /* ── 3 · WHY THIS GRADE IS PROSE, NOT A WALL (S223 fix round 1, D3) ──
     It was one ~2,300-word paragraph carrying raw ** asterisks and it is the
     first thing the captain reads. Measured on the real report: no raw
     markdown on screen, more than one paragraph, a short lead, and the rest
     one tap away with every word still in it. */
  const why = await ev(`(function(){var b=document.querySelector('.detail-grid .xo-why');
    if(!b) return null; var d=b.querySelector('details.xo-why-more');
    var bodies=[].map.call(b.querySelectorAll('.xo-why-body'),function(n){return n.textContent.trim()});
    var lead=b.querySelector('.xo-why-body');
    if(d) d.open=true;
    var openText=b.textContent;
    return {asterisks:b.textContent.split('**').length-1, bodies:bodies.length,
      leadLen:lead?lead.textContent.trim().length:-1, whole:b.textContent.trim().length,
      hasFold:!!d, sum:d?d.querySelector('summary').textContent:null,
      strongs:b.querySelectorAll('strong,b').length, paras:b.querySelectorAll('p').length,
      sumColour:d?getComputedStyle(d.querySelector('summary')).color:null,
      leadW:lead?lead.getBoundingClientRect().width:-1}})()`);
  out.m.why = why;
  check("3 why-this-grade: no raw ** markdown reaches the screen", why && why.asterisks === 0 && why.strongs >= 1, why);
  check("3 why-this-grade: a short lead, the rest behind a disclosure", why && why.hasFold && /Show the full reasoning/.test(why.sum) && why.leadLen < why.whole, why);
  check("3 why-this-grade: every word is still there when it is opened", why && why.whole > why.leadLen + 200, why);
  out.shots.push(await shot("02c-why-this-grade", ".detail-grid .xo-why"));

  /* ── 4 · each item: did / saw / why once; problems first ── */
  const items = await ev(`(function(){var its=[].slice.call(document.querySelectorAll('.detail-grid .xo-item'));
    var order=its.map(function(i){return i.getAttribute('data-status')});
    var per=its.map(function(i){var m=i.querySelector('.xo-matters'); var mt=m?m.textContent.replace(/^Why it matters: /,''):'';
      var key=mt.slice(0,40); var txt=i.textContent; var occ=key?txt.split(key).length-1:0;
      return {did:i.querySelectorAll('.xo-beat.did').length, saw:i.querySelectorAll('.xo-beat.saw').length,
        matters:i.querySelectorAll('.xo-matters').length, whyOccurrences:occ, impactWords:(txt.match(/Impact (high|medium|low)/g)||[]).length,
        chips:[].map.call(i.querySelectorAll('.xo-chip2'),function(c){return c.textContent})}});
    return {n:its.length, order:order, per:per}})()`);
  out.m.items = { n: items.n, order: items.order.join(","), sample: items.per.slice(0, 3) };
  const rank = { gap: 0, untested: 1, met: 2 };
  check("4 every requirement is its own block (79 rows)", items.n === 79, items.n);
  check("4 problems first, worked last", items.order.every((s, i, a) => i === 0 || rank[a[i - 1]] <= rank[s]), items.order.join(","));
  check("4 each block: one did, one saw, at most one why-it-matters", items.per.every((p) => p.did === 1 && p.saw === 1 && p.matters <= 1), null);
  // S223 fix round 1 (D2): the importance reasoning is said ONCE — measured as
  // "the recorded impactWhy text appears at most once in the block", which is
  // the behaviour. The old clause also banned the literal words "Impact high"
  // from appearing AT ALL; that was a proxy for the same thing, and it is the
  // clause that made the report chop the look's own recorded sentence to
  // pieces. A row with no `action` field now shows its reason as written, so
  // the words appear ONCE, inside that one record, and the separate "Why it
  // matters" line stands down. Once is not repeated.
  check("4 importance reasoning said ONCE per block", items.per.every((p) => p.whyOccurrences <= 1 && p.impactWords <= 1 && !(p.impactWords && p.matters)), items.per.filter((p) => p.whyOccurrences > 1 || p.impactWords > 1 || (p.impactWords && p.matters)).slice(0, 3));
  check("4 importance chip reads e.g. 'HIGH · the point'", items.per.some((p) => p.chips.indexOf("HIGH · the point") >= 0), items.per[0].chips);
  // filters
  const filt = await ev(`(function(){var r={}; [].forEach.call(document.querySelectorAll('.detail-grid .xo-filter'),function(b){r[b.getAttribute('data-filter')]=b.textContent});
    var b=document.querySelector('.detail-grid .xo-filter[data-filter=met]'); b.click();
    var vis=[].filter.call(document.querySelectorAll('.detail-grid .xo-item'),function(i){return !i.hidden}).map(function(i){return i.getAttribute('data-status')});
    document.querySelector('.detail-grid .xo-filter[data-filter=all]').click();
    return {labels:r, metVisible:vis.length, allMet:vis.every(function(s){return s==='met'})}})()`);
  out.m.filters = filt;
  check("1 filters All / Didn't work / Couldn't check / Worked", /^All · 79$/.test(filt.labels.all) && /Didn't work/.test(filt.labels.gap) && /Couldn't check/.test(filt.labels.untested) && filt.allMet && filt.metVisible > 0, filt);

  /* ── 5 · evidence is the real screenshot; tap to enlarge; missing says so ── */
  await ev(`(function(){var b=document.querySelector('.detail-grid .xo-thumb-btn'); b.scrollIntoView({block:'center'});})()`);
  await waitFor(`(function(){var i=document.querySelector('.detail-grid .xo-thumb-btn img'); return i && i.complete && i.naturalWidth>0})()`, 10000);
  const thumb = await ev(`(function(){var i=document.querySelector('.detail-grid .xo-thumb-btn img'); var s=i.closest('.xo-item').querySelector('.xo-story').getBoundingClientRect(), r=i.getBoundingClientRect();
    return {src:i.getAttribute('src'), natW:i.naturalWidth, natH:i.naturalHeight, shownW:r.width, besideText: r.left > s.right - 1}})()`);
  out.m.thumb = thumb;
  check("5 evidence renders as the real screenshot, beside the text", thumb.natW > 0 && thumb.besideText, thumb);
  out.shots.push(await shot("03-item-with-evidence", ".detail-grid .xo-item:has(.xo-thumb-btn)"));
  await ev(`document.querySelector('.detail-grid .xo-thumb-btn').click()`);
  await waitFor(`(function(){var i=document.querySelector('#xoLightbox img'); return i && i.complete && i.naturalWidth>0})()`, 8000);
  const lb = await ev(`(function(){var i=document.querySelector('#xoLightbox img'); return i? {natW:i.naturalWidth, shownW:i.getBoundingClientRect().width, src:i.getAttribute('src')} : null})()`);
  out.m.lightbox = lb;
  check("5 tap opens it full size", lb && lb.natW === thumb.natW && lb.shownW > thumb.shownW && lb.src === thumb.src, lb);
  out.shots.push(await shot("04-lightbox"));
  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 }, sid);
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 }, sid);
  await sleep(300);
  check("5 Escape closes the picture, the mission window stays", await ev(`!document.getElementById('xoLightbox') && !!document.querySelector('.detail-grid')`), null);
  const missing = await ev(`(function(){var n=document.querySelectorAll('.detail-grid .xo-ev-none'); return {n:n.length, first:n[0]?n[0].textContent:null}})()`);
  // a picture that is gone from disk: point one real thumb at a missing file.
  await ev(`(function(){var i=document.querySelectorAll('.detail-grid .xo-thumb-btn img')[1]; i.src='/api/xo/shot/${MID}/shots/look-2/not-there.png'; return true})()`);
  await sleep(1200);
  const broken = await ev(`(function(){var t=[].map.call(document.querySelectorAll('.detail-grid .xo-ev-none'),function(e){return e.textContent}); return t.filter(function(x){return /isn't on this laptop/.test(x)})})()`);
  out.m.missing = { none: missing, broken };
  check("5 a missing picture says so in words", missing.n > 0 && /No picture/.test(missing.first) && broken.length === 1, out.m.missing);

  /* ── 1 · ⤡ side by side restores live activity and is remembered ── */
  await ev(`document.querySelector('.detail-grid .detail-side').click()`);
  await sleep(800);
  const side = await ev(`(function(){var g=document.querySelector('.detail-grid'); var f=g.querySelector('.det-body > .feed');
    return {cls:g.className, feedW:f?f.getBoundingClientRect().width:-1, stored:localStorage.getItem('lcars.numberOne.sideBySide'),
      btn:g.querySelector('.detail-side').textContent, actHidden:g.querySelector('.tab[data-tab=act]').hidden}})()`);
  out.m.side = side;
  check("1 ⤡ Side by side brings live activity back beside the report", !side.cls.includes("xo-solo") && side.feedW > 200 && side.actHidden, side);
  out.shots.push(await shot("05-side-by-side"));
  await ev(`document.querySelector('.detail-grid .detail-close').click()`);
  await sleep(300);
  await openReportFromCard();
  const remembered = await ev(`(function(){var g=document.querySelector('.detail-grid'); return {cls:g.className, feedW:g.querySelector('.det-body > .feed').getBoundingClientRect().width}})()`);
  check("1 side by side is REMEMBERED (reopen lands side by side)", !remembered.cls.includes("xo-solo") && remembered.feedW > 200, remembered);
  await ev(`document.querySelector('.detail-grid .detail-side').click()`);   // back to report-only
  await sleep(800);

  /* ── 1/2 · PRD restores today's layout — and the glide is ANIMATED ── */
  const wFull = await ev(GRIDW);
  await ev(`document.querySelector('.detail-grid .tab[data-tab=prd]').click()`);
  const shrink = [];
  const t0 = Date.now();
  for (const at of [60, 180, 320, 700]) { while (Date.now() - t0 < at) await sleep(5);
    shrink.push({ t: Date.now() - t0, w: await ev(GRIDW), go: await ev(`document.querySelector('.detail-grid').className`) });
    if (at === 180) out.shots.push(await shot("06-shrink-mid-glide")); }
  out.m.shrink = { wFull, frames: shrink };
  const wEnd = shrink[shrink.length - 1].w;
  check("1 PRD returns today's layout", wEnd <= 1082 && !shrink[3].go.includes("xo-full"), shrink[3]);
  check("2 shrink is animated: mid-glide width strictly between, sweep class on", shrink.some((f) => f.w < wFull - 20 && f.w > wEnd + 20) && shrink.some((f) => /xo-go/.test(f.go)), shrink);
  await ev(`document.querySelector('.detail-grid .tab[data-tab=xo]').click()`);
  const grow = []; const t1 = Date.now();
  for (const at of [60, 180, 320, 700]) { while (Date.now() - t1 < at) await sleep(5);
    grow.push({ t: Date.now() - t1, w: await ev(GRIDW), sweep: await ev(`getComputedStyle(document.querySelector('.detail-grid'),'::before').animationName`) });
    if (at === 180) out.shots.push(await shot("07-grow-mid-glide")); }
  out.m.grow = grow;
  check("2 grow is animated: mid-glide width strictly between, sweep running", grow.some((f) => f.w > wEnd + 20 && f.w < wFull - 20) && grow.some((f) => f.sweep === "xo-sweep"), grow);
  check("1 text reflows, never scaled (no transform on the window)", await ev(`getComputedStyle(document.querySelector('.detail-grid')).transform === 'none'`), null);
  const fontSame = await ev(`getComputedStyle(document.querySelector('.detail-grid .xo-beat-v')).fontSize`);
  out.m.fontFull = fontSame;
  // reduced motion: instant
  await reducedMotion(true);
  await ev(`document.querySelector('.detail-grid .tab[data-tab=prd]').click()`);
  await sleep(40);
  const rmW = await ev(GRIDW);
  const rmT = await ev(`getComputedStyle(document.querySelector('.detail-grid')).transitionDuration`);
  await ev(`document.querySelector('.detail-grid .tab[data-tab=xo]').click()`);
  await sleep(40);
  const rmW2 = await ev(GRIDW);
  const rmSweep = await ev(`getComputedStyle(document.querySelector('.detail-grid'),'::before').animationName`);
  out.m.reduced = { shrinkAt40ms: rmW, growAt40ms: rmW2, transitionDuration: rmT, sweep: rmSweep };
  check("2 prefers-reduced-motion: instant (final width at 40ms, no transition, no sweep)", rmW <= 1082 && rmW2 >= wFull - 2 && /^0s/.test(rmT) && rmSweep === "none", out.m.reduced);
  await reducedMotion(false);
  await ev(`document.querySelector('.detail-grid .detail-close').click()`);
  await sleep(300);

  /* ── 8 · Arrange (single-choice switch) vs Show (filter chips) ── */
  await ev(`openXoReport()`);
  await waitFor(`!!document.querySelector('.xo-seg .xo-view')`);
  await sleep(500);
  const ctl = await ev(`(function(){var v=[].slice.call(document.querySelectorAll('.xo-seg .xo-view')), c=[].slice.call(document.querySelectorAll('.xo-fchip'));
    function st(e){var s=getComputedStyle(e), b=getComputedStyle(e,'::before'); return {on:e.classList.contains('on'), borderStyle:s.borderTopStyle, bg:s.backgroundColor, color:s.color, before:b.content, radius:s.borderTopLeftRadius}}
    var r={views0:v.map(st)}; v[1].click(); r.views1=v.map(st); v[0].click();
    r.chips0=c.map(st); c[1].click(); r.chips1=c.map(st); c[2].click(); r.chips2=c.map(st); c[0].click(); r.chips3=c.map(st);
    r.segRole=document.querySelector('.xo-seg').getAttribute('role'); return r})()`);
  out.m.controls = ctl;
  const onCount = (a) => a.filter((x) => x.on).length;
  check("8 Arrange is single-choice: exactly one on, before and after a click", onCount(ctl.views0) === 1 && onCount(ctl.views1) === 1 && ctl.views1[1].on && ctl.segRole === "radiogroup", null);
  check("8 Show chips are multi-select filters (Needs you + Verdicts both on)", ctl.chips1[0].on && ctl.chips1[1].on && !ctl.chips1[2].on && ctl.chips2[2].on && onCount(ctl.chips2) === 1, { c1: ctl.chips1.map((x) => x.on), c2: ctl.chips2.map((x) => x.on) });
  check("8 they LOOK different: filled segment vs dashed/solid outlined chip with a tick", ctl.views0[0].bg !== "rgba(0, 0, 0, 0)" && ctl.chips0[1].borderStyle === "dashed" && ctl.chips1[1].borderStyle === "solid" && /✓/.test(ctl.chips1[1].before) && ctl.chips1[1].bg === "rgba(0, 0, 0, 0)", { seg: ctl.views0[0], chipOff: ctl.chips0[1], chipOn: ctl.chips1[1] });
  // land on Everything for the Seen-all proof
  await ev(`document.querySelector('.xo-fchip[data-chip=all]').click()`);
  await sleep(200);
  out.shots.push(await shot("08-first-officers-report"));

  /* ── 9 · ✓ Seen all N ── */
  const before = await ev(`(function(){var b=document.querySelector('.xo-mhead .xo-seen-all'); if(!b) return null; var g=b.closest('.xo-mgrp');
    return {mission:b.getAttribute('data-mission'), label:b.textContent, n:+b.textContent.replace(/\\D+/g,''), perEntry:g.querySelectorAll('.xo-entry .xo-seen').length,
      all:document.querySelector('.xo-fchip[data-chip=all]').textContent, hist:document.querySelector('.xo-hist-line').textContent}})()`);
  out.m.seenBefore = before;
  check("9 ✓ Seen all N sits on a mission header beside per-entry ✓ Seen", before && /^✓ Seen all \d+$/.test(before.label) && before.perEntry > 0, before);
  // S223 fix round 1 (D5): the number on the button IS the list it clears.
  // The tester pressed "SEEN ALL 7" under Verdicts and 48 entries left the
  // news. Measured here under BOTH a filter and Everything: label === rows
  // shown, and the body posted names exactly those keys.
  const named = await ev(`(function(){window.__seenBodies=[]; var f=window.fetch;
    window.fetch=function(u,o){ if(String(u).indexOf('/api/xo/seen')===0 && o && o.body) window.__seenBodies.push(JSON.parse(o.body)); return f.apply(this,arguments)};
    document.querySelector('.xo-fchip[data-chip=verdicts]').click(); return true})()`);
  await sleep(300);
  const filtered = await ev(`(function(){
    var bs=[].slice.call(document.querySelectorAll('.xo-mhead .xo-seen-all'));
    // EVERY header under this filter, and then the biggest one to press.
    var all=bs.map(function(x){var g=x.closest('.xo-mgrp');
      return {label:x.textContent, n:+x.getAttribute('data-count'),
        rows:g.querySelectorAll('.xo-entry').length,
        mcount:g.querySelector('.xo-mcount').textContent}});
    var b=bs.slice().sort(function(p,q){return (+q.getAttribute('data-count'))-(+p.getAttribute('data-count'))})[0];
    if(!b) return null;
    var g=b.closest('.xo-mgrp');
    return {all:all, label:b.textContent, n:+b.getAttribute('data-count'),
      rows:g.querySelectorAll('.xo-entry').length, mission:b.getAttribute('data-mission'),
      keys:[].map.call(g.querySelectorAll('.xo-entry'),function(e){return e.getAttribute('data-key')}),
      headCount:g.querySelector('.xo-mcount').textContent}})()`);
  out.m.seenFiltered = filtered;
  check("9 under a filter EVERY header's count is the rows on screen, not the backlog",
    filtered && filtered.all.length > 0
    && filtered.all.every((r) => r.n === r.rows && r.label === "✓ Seen all " + r.rows),
    filtered && filtered.all);
  if (filtered) {
    await ev(`document.querySelector('.xo-mhead .xo-seen-all[data-mission=${Q(filtered.mission)}]').click()`);
    await sleep(900);
    const posted = await ev(`window.__seenBodies`);
    out.m.seenPosted = posted;
    check("9 it clears exactly the entries it named (its keys, nothing else)",
      posted && posted.length === 1 && Array.isArray(posted[0].entries)
      && posted[0].entries.length === filtered.n
      && posted[0].entries.every((k) => filtered.keys.indexOf(k) >= 0)
      && !posted[0].mission, { posted, filtered });
  }
  await ev(`document.querySelector('.xo-fchip[data-chip=all]').click()`);
  await sleep(300);
  if (before) {
    await ev(`document.querySelector('.xo-mhead .xo-seen-all[data-mission=${Q(before.mission)}]').click()`);
    await waitFor(`!document.querySelector('.xo-mhead .xo-seen-all[data-mission=${Q(before.mission)}]')`, 20000);
    await sleep(400);
    const after = await ev(`({all:document.querySelector('.xo-fchip[data-chip=all]').textContent, hist:document.querySelector('.xo-hist-line').textContent,
      grp: !!document.querySelector('.xo-mgrp[data-mission=${Q(before.mission)}]')})`);
    out.m.seenAfter = after;
    const num = (s) => +(String(s).match(/(\d+)/) || [0, 0])[1];
    check("9 counts drop by that mission's news; history keeps it (seen count rises)",
      num(after.all.split("·")[1]) < num(before.all.split("·")[1]) && num(after.hist) > num(before.hist) && after.grp, { before, after });
    out.shots.push(await shot("09-after-seen-all"));
  }
  await ev(`closeOverlay()`);
  await sleep(300);

  /* ── 3/7 · Stand down can't be clicked twice ── */
  await ev(`(function(){window.__offPosts=0; var f=window.fetch; window.fetch=function(u,o){ if(String(u).indexOf('/api/xo/off')===0) window.__offPosts++; return f.apply(this,arguments)}; return true})()`);
  const sdMid = MID2 || MID;
  const sd = await ev(`(function(){var c=document.querySelector('.card[data-mid=${Q(sdMid)}]'); var b=c&&c.querySelector('.xo-stand-down'); if(!b) return null;
    b.click(); var t1=b.textContent, d1=b.disabled; b.click(); b.disabled=false; b.click(); return {t1:t1, d1:d1}})()`);
  await sleep(150);
  const sdNow = await ev(`(function(){var c=document.querySelector('.card[data-mid=${Q(sdMid)}]'); var b=c&&c.querySelector('.xo-stand-down'); return {posts:window.__offPosts, text:b?b.textContent:null, disabled:b?b.disabled:null}})()`);
  out.m.standDown = { sd, sdNow };
  check("3 Stand down flips to 'Standing down…' and locks instantly", sd && sd.t1 === "Standing down…" && sd.d1, sd);
  check("7 a second (and third) click on Stand down is a no-op — ONE request", sdNow.posts === 1, sdNow);
  out.shots.push(await shot("10-standing-down", `.card[data-mid=${Q(sdMid)}]`));
  await waitFor(`(function(){var c=document.querySelector('.card[data-mid=${Q(sdMid)}]'); return c && !c.querySelector('.xo-stand-down')})()`, 20000);
  check("3 the lock lifts once the mission is stood down", await ev(`!document.querySelector('.card[data-mid=${Q(sdMid)}] .xo-stand-down')`), null);

  /* ── 3/7 · Turn Number One off (repo) can't be clicked twice ── */
  await ev(`window.__offPosts=0`);
  await ev(`document.getElementById('xoBtn').click()`);
  await waitFor(`!![].find.call(document.querySelectorAll('.xo-menu-item'),function(b){return /Turn off/.test(b.textContent)})`);
  const off = await ev(`(function(){var b=[].find.call(document.querySelectorAll('.xo-menu-item'),function(b){return /Turn off/.test(b.textContent)}); b.click(); b.click();
    var band=document.getElementById('xoBtn'); var r={bandText:band.textContent, bandDisabled:band.disabled}; band.click(); return r})()`);
  await sleep(100);
  off.posts = await ev(`window.__offPosts`);
  off.menuOpen = await ev(`!!document.querySelector('.xo-menu-item')`);
  out.m.turnOff = off;
  check("3 Turn off flips the band to 'Standing down…' and locks it", /Standing down…/.test(off.bandText) && off.bandDisabled && !off.menuOpen, off);
  check("7 a second click on Turn off is a no-op — ONE request", off.posts === 1, off);
  out.shots.push(await shot("11-band-standing-down", "#xoBtn"));
  await waitFor(`/OFF/.test(document.getElementById('xoBtn').textContent)`, 20000);
  check("3 the band re-arms once Number One is off", await ev(`(function(){var b=document.getElementById('xoBtn'); return /OFF/.test(b.textContent) && !b.disabled})()`), await ev(`document.getElementById('xoBtn').textContent`));

  /* ── phone width: 390px ── */
  await viewport(390, 844, true);
  await openBoard();
  const ph = await ev(`(function(){var c=${CARD}; var p=c&&c.querySelector('.xo-axes-pill'); return p? {pillScroll:p.scrollWidth, pillClient:p.clientWidth, docScroll:document.documentElement.scrollWidth, vw:innerWidth}:null})()`);
  out.shots.push(await shot("12-card-390", `.card[data-mid=${Q(MID)}]`));
  await openReportFromCard();
  const phr = await ev(`(function(){var it=document.querySelector('.detail-grid .xo-item:has(.xo-thumb-btn)'); var s=it.querySelector('.xo-story').getBoundingClientRect(), e=it.querySelector('.xo-ev').getBoundingClientRect();
    var g=document.querySelector('.detail-grid').getBoundingClientRect(); return {evBelow: e.top >= s.bottom - 1, gridW:g.width, vw:innerWidth}})()`);
  out.m.phone = { card: ph, report: phr };
  check("390px: card score line fits", ph && ph.pillScroll <= ph.pillClient + 1, ph);
  check("390px: evidence sits BELOW the text; window fits the screen", phr.evBelow && phr.gridW <= phr.vw, phr);
  out.shots.push(await shot("13-report-390"));
  await ev(`document.querySelector('.detail-grid .xo-item:has(.xo-thumb-btn)').scrollIntoView({block:'start'})`);
  await sleep(500);
  out.shots.push(await shot("14-report-390-item"));

  /* ── 390px: note 1 says "full size". On a phone it has to MEAN it (D2) ──
     A 2880px-wide app screenshot fitted into a 390px window is a 1.27×
     "enlarge" off the thumbnail — unreadable. The enlarged view opens the
     picture at its NATURAL resolution and lets the captain pan it. */
  await waitFor(`(function(){var i=document.querySelector('.detail-grid .xo-thumb-btn img'); return i && i.complete && i.naturalWidth>0})()`, 10000);
  await ev(`document.querySelector('.detail-grid .xo-thumb-btn').click()`);
  await waitFor(`(function(){var i=document.querySelector('#xoLightbox img'); return i && i.complete && i.naturalWidth>0})()`, 8000);
  const phlb = await ev(`(function(){
    var b=document.querySelector('#xoLightbox'), i=b.querySelector('img'),
        t=document.querySelector('.detail-grid .xo-thumb-btn img');
    return {natW:i.naturalWidth, shownW:i.getBoundingClientRect().width,
            thumbW:t.getBoundingClientRect().width, vw:innerWidth,
            panX: b.scrollWidth > b.clientWidth + 1, panY: b.scrollHeight > b.clientHeight + 1,
            overflow: getComputedStyle(b).overflow}})()`);
  out.m.phoneLightbox = phlb;
  check("390px: the enlarged picture opens at natural resolution, not fitted to the phone",
    phlb && phlb.shownW >= phlb.natW - 1, phlb);
  check("390px: …and the enlarged view PANS (it is wider than the screen)",
    phlb && phlb.panX && phlb.shownW > phlb.vw, phlb);
  out.shots.push(await shot("15-lightbox-390"));
  await cdp.send("Input.dispatchKeyEvent", { type: "keyDown", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 }, sid);
  await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 }, sid);
  await sleep(300);
  check("390px: Escape still closes the picture and the report stays open",
    await ev(`!document.getElementById('xoLightbox') && !!document.querySelector('.detail-grid .xo-pane')`), null);
  // …and a tap on the backdrop closes it too.
  await ev(`document.querySelector('.detail-grid .xo-thumb-btn').click()`);
  await waitFor(`!!document.getElementById('xoLightbox')`, 5000);
  await ev(`document.getElementById('xoLightbox').click()`);
  await sleep(300);
  check("390px: tapping out still closes it, report still open",
    await ev(`!document.getElementById('xoLightbox') && !!document.querySelector('.detail-grid .xo-pane')`), null);

  out.pageErrors = cdp.errs;
  check("no page errors", cdp.errs.length === 0, cdp.errs);
  console.log(JSON.stringify(out, null, 1));
  process.exit(out.checks.every((c) => c.ok) ? 0 : 1);
})().catch((e) => { console.error("DRIVE FAILED", e && e.stack || e); console.log(JSON.stringify(out, null, 1)); process.exit(2); });
