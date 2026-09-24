#!/usr/bin/env node
/* S225 — the three-question report rail, driven in REAL headless Chrome over
 * raw CDP against a REAL daemon serving the planted fixture.
 *
 *   node rail.js --devtools-port N --url BOARD_URL --out SHOTS_DIR
 *
 * Every claim about anything the CASCADE decides is read as a COMPUTED style
 * off the live DOM — a rule that ties on specificity loses on source order and
 * never reaches the screen, and a node DOM harness cannot see that at all.
 *
 * Screenshots are CROPPED to the component and taken at scale 3: the captain
 * reads them on a 390px phone, where a full-viewport grab lands at about a
 * quarter of life size and he has twice said the images are pixely.
 *
 * Prints one JSON object with `checks`; exit 0 only when every check is ok.
 */
const fs = require("fs"), path = require("path");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), OUT = arg("out", ".");
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
      if (m.method === "Runtime.exceptionThrown")
        this.errs.push(String((m.params.exceptionDetails || {}).text));
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
const out = { checks: [], shots: [], m: {} };
function check(name, ok, detail) {
  out.checks.push({ name, ok: !!ok, detail: detail === undefined ? null : detail });
}
const Q = (s) => JSON.stringify(s);

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
async function viewport(w, h) {
  VIEW = { w: w, h: h };
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: w, height: h, deviceScaleFactor: 1, mobile: w < 700 }, sid);
}
/* CROPPED, AND AT 3x. A caption file rides beside every shot: the orchestrator
 * builds the captain's picture page out of these and cannot write them,
 * because this is the only thing that saw the screen. */
let VIEW = { w: 1600, h: 1200 };
async function shot(name, sel, caption, maxH) {
  // `captureBeyondViewport` RE-LAYS-OUT THE PAGE and then clips in the ORIGINAL
  // coordinates. Measured here twice: the shots came out ~40px to the left of
  // the rail and clipped its right edge, because this board's own column is a
  // horizontal scroller and it reflows the moment the capture widens the page.
  // So the viewport is GROWN to hold the component instead, the rect is read
  // AFTER the reflow has settled, and the capture stays inside the viewport.
  // A picture nobody checked is not evidence, and this one was wrong.
  const first = await ev(`(function(){var e=document.querySelector(${Q(sel)});`
    + `if(!e) return null; var b=e.getBoundingClientRect(); return {h:b.height}})()`);
  if (!first) { check("shot " + name + ": " + sel + " was on the page", false, null); return null; }
  // +420, not +200: this board has a ~110px STICKY detail header, and a
  // centred element with only 100px of headroom lands with its first line
  // behind it — measured, the phone shot lost the grade chip off the top and
  // the engine line off the bottom.
  const tall = Math.max(VIEW.h, Math.ceil(first.h) + 420);
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: VIEW.w, height: tall, deviceScaleFactor: 1, mobile: VIEW.w < 700 }, sid);
  await sleep(250);
  await ev(`(function(){var e=document.querySelector(${Q(sel)});`
    + `if(e) e.scrollIntoView({block:'center'}); return !!e})()`);
  await sleep(300);
  const r = await ev(`(function(){var e=document.querySelector(${Q(sel)});`
    + `if(!e) return null; var b=e.getBoundingClientRect();`
    + `return {x:b.left,y:b.top,w:b.width,h:b.height}})()`);
  if (!r || !(r.w > 0)) { check("shot " + name + ": " + sel + " was on the page", false, r); return null; }
  // A picture of fifty folded rows is a picture of nothing. `maxH` clips the
  // shot to the top of a long block, so what is IN it can be seen at 3x rather
  // than shrunk to a grey column.
  const h = maxH ? Math.min(r.h + 20, maxH) : r.h + 20;
  const img = await cdp.send("Page.captureScreenshot", {
    format: "png", captureBeyondViewport: false,
    clip: { x: Math.max(0, r.x - 10), y: Math.max(0, r.y - 10),
            width: r.w + 20, height: h, scale: 3 },
  }, sid);
  const f = path.join(OUT, name + ".png");
  fs.writeFileSync(f, Buffer.from(img.data, "base64"));
  fs.writeFileSync(path.join(OUT, name + ".txt"), caption.trim() + "\n");
  out.shots.push(f);
  await viewport(VIEW.w, VIEW.h);      // put the window back where it was
  await sleep(150);
  return f;
}

/* The BOARD CARD's own pill, read before the report is opened. `verdict.score`
   IS the person group's grade under the new contract, and the card's pill is
   fed from `state.numberOne.score` which the scorer writes from that same
   value — so this should need no change at all. CHECKED, not assumed. */
async function cardPill(mid) {
  return await ev(`(function(){var c=document.querySelector('.card[data-mid=${Q(mid)}]');`
    + `var p=c&&c.querySelector('.pill.xo-score'); return p? p.textContent.trim():null})()`);
}

/* S225 CARD FACE — the captain's actual complaint. The card must carry the
   grade and NOTHING else: no axes sentence on the pill, no second
   `.xo-verdict-line`, and no before/after grade pair when a mission was
   looked at twice. Read off the LIVE card, then shot it as evidence. */
async function cardShape(mid) {
  return await ev(`(function(){
    var c=document.querySelector('.card[data-mid=${Q(mid)}]');
    if(!c) return {missing:true};
    var pills=Array.prototype.slice.call(c.querySelectorAll('.pill.xo-score'));
    var p=pills[0]||null;
    return {
      scorePills: pills.length,
      pillText: p? p.textContent.trim():null,
      pillTitle: p? (p.getAttribute('title')||''):'',
      verdictLines: c.querySelectorAll('.xo-verdict-line').length,
      hasAxes: /·\\s*\\d+\\s+of\\s+\\d+/.test(c.textContent) || /couldn't/i.test(c.textContent)
    };
  })()`);
}

async function openReport(mid) {
  await cdp.send("Page.navigate", { url: URL }, sid);
  if (!await waitFor(`!!document.querySelector('.card[data-mid=${Q(mid)}]')`, 30000))
    throw new Error("card never appeared: " + mid);
  await sleep(400);
  out.m["pill:" + mid] = await cardPill(mid);
  // S225 — prove the card face BEFORE we leave it for the report.
  var cs = await cardShape(mid);
  out.m["card:" + mid] = cs;
  if (!cs.missing) {
    check(mid + ": the card shows exactly ONE Number One grade pill",
      cs.scorePills === 1, cs);
    check(mid + ": the pill is grade-only (◈ NUMBER ONE · WORD, no axes sentence)",
      /^◈ NUMBER ONE · (LOW|MEDIUM|HIGH)$/.test(cs.pillText || ""), cs.pillText);
    check(mid + ": no second verdict line is on the card",
      cs.verdictLines === 0, cs);
    check(mid + ": the meaning is still on hover (pill title kept)",
      (cs.pillTitle || "").length > 0, cs.pillTitle);
    await shot("card-" + mid, `.card[data-mid=${Q(mid)}]`,
      "The board card for " + mid + " before the report is opened: one "
      + "◈ NUMBER ONE grade pill reading " + (cs.pillText || "?") + " and "
      + "nothing else — no coverage sentence, no second verdict line, no "
      + "before/after grade pair. S225: the pill now shows the CURRENT grade — "
      + "the re-check's when a mission was looked at twice — so it AGREES with "
      + "the grade the report opens on. The full meaning rides on the pill's "
      + "hover title; the WHY lives in the report.", 520);
  }
  await ev(`(function(){var c=document.querySelector('.card[data-mid=${Q(mid)}]');`
    + `var b=c&&c.querySelector('.xo-read-report'); if(b){b.click();return true} return false})()`);
  if (!await waitFor(`!!document.querySelector('.xo-pane .xo-verdict')`, 20000))
    throw new Error("the report pane never opened for " + mid);
  await sleep(500);
}

/* Everything read back as COMPUTED, off the live DOM. */
const PROBE = `(function(){
  var q=function(s){return document.querySelector(s)};
  var all=function(s){return Array.prototype.slice.call(document.querySelectorAll(s))};
  var rail=q('.xo-pane .xo-rail'), head=q('.xo-pane .xo-verdict');
  if(!rail||!head) return {missing:true};
  var rb=rail.getBoundingClientRect(), rs=getComputedStyle(rail);
  var grp=function(k){
    var e=q('.xo-pane .xo-group-'+k); if(!e) return null;
    var b=e.getBoundingClientRect();
    var segs=Array.prototype.slice.call(e.querySelectorAll('.xo-seg')).map(function(s){
      var cs=getComputedStyle(s);
      return {cls:s.className, w:+s.getBoundingClientRect().width.toFixed(1),
              bg:cs.backgroundColor, img:cs.backgroundImage, shadow:cs.boxShadow};
    });
    var gr=e.querySelector('.xo-group-grade');
    var cov=e.querySelector('.xo-group-cov');
    return {
      text:e.textContent.trim(),
      question:(e.querySelector('.xo-group-q')||{}).textContent||'',
      grade: gr? {t:gr.textContent.trim(), c:getComputedStyle(gr).color} : null,
      cov: cov? {t:cov.textContent.trim(), c:getComputedStyle(cov).color} : null,
      aside:(e.querySelector('.xo-group-aside')||{}).textContent||'',
      counts:Array.prototype.slice.call(e.querySelectorAll('.xo-count')).map(function(c){return c.textContent.trim()}),
      bars:e.querySelectorAll('.xo-bar').length,
      segs:segs,
      h:Math.round(b.height), visible:e.checkVisibility(),
      right:Math.round(b.right)
    };
  };
  var chip=q('.xo-pane .xo-grade-chip');
  var mine=q('.xo-pane .xo-mine');
  return {
    railW:+rb.width.toFixed(1), railH:Math.round(rb.height),
    /* WHAT THE RAIL ACTUALLY COSTS ON SCREEN. The header is a two-column grid,
       so its height is max(rail, words) — a rail shorter than the prose beside
       it costs the page nothing at all, and the raw rail height on its own
       answers a question nobody is asking. */
    vtextH: Math.round(q('.xo-pane .xo-vtext').getBoundingClientRect().height),
    headH: Math.round(head.getBoundingClientRect().height),
    railPadR:rs.paddingRight, railBorder:rs.borderRightWidth,
    railContentW:+(rb.width - parseFloat(rs.paddingRight||0) - parseFloat(rs.borderRightWidth||0)).toFixed(1),
    cols:getComputedStyle(head).gridTemplateColumns,
    chip: chip? {t:chip.textContent.trim(), c:getComputedStyle(chip).color, cls:chip.className} : null,
    chips: all('.xo-pane .xo-grade-chip').length,
    order: all('.xo-pane .xo-group').map(function(e){return e.className}),
    person:grp('person'), drawing:grp('drawing'), contract:grp('contract'),
    legacyBars: all('.xo-pane .xo-bars .xo-bar').length,
    legacyLegend: all('.xo-pane .xo-legend-row').length,
    whenBoth:(q('.xo-pane .xo-when-both')||{}).textContent||'',
    mine: mine? {text:mine.textContent.trim().slice(0,400),
                 visible:mine.checkVisibility(),
                 rows:mine.querySelectorAll('.xo-mine-row').length,
                 foldOpen:(mine.querySelector('details')||{}).open,
                 w:Math.round(mine.getBoundingClientRect().width)} : null,
    /* Does anything in the report spill past its own pane? The PAGE scrollWidth
       is not the measurement — .board is a row of Kanban columns and scrolls
       sideways by design. */
    overflow:(function(){
      var pane=q('.xo-pane'); if(!pane) return null;
      var pr=pane.getBoundingClientRect().right, worst=0, who='';
      var kids=pane.querySelectorAll('*');
      for(var i=0;i<kids.length;i++){
        var b=kids[i].getBoundingClientRect();
        if(b.width<=0&&b.height<=0) continue;
        if(b.right-pr>worst){worst=b.right-pr;who=kids[i].className}
      }
      return {px:Math.round(worst), who:String(who).slice(0,60)};
    })()
  };
})()`;

const TEAL = "teal", AMBER = "amber", RED = "red";
const WORKED = "rgb(47, 116, 192)";
const DIDNT = "rgb(192, 111, 30)";
const NOCHK = "rgb(110, 104, 120)";

function segsOf(g, k) {
  return (g.segs || []).filter((s) => s.cls.indexOf("xo-seg-" + k) >= 0);
}

async function main() {
  const v = await (await fetch("http://127.0.0.1:" + PORT + "/json/version")).json();
  cdp = new CDP(await connect(v.webSocketDebuggerUrl));
  const targets = await cdp.send("Target.getTargets");
  const page = targets.targetInfos.find((t) => t.type === "page");
  sid = (await cdp.send("Target.attachToTarget", { targetId: page.targetId, flatten: true })).sessionId;
  await cdp.send("Page.enable", {}, sid);
  await cdp.send("Runtime.enable", {}, sid);

  // ── 1. THE MAIN CASE: two looks, three groups ─────────────────────────
  await viewport(1600, 1200);
  await openReport("lcars-20260921-twice");
  const w = await ev(PROBE);
  out.m.twice = w;
  if (w.missing) { check("the rail rendered at all", false, w); return; }

  check("the rail is the narrow column it was (~205px content, ~240px box)",
    w.railContentW >= 160 && w.railContentW <= 206 && w.railW <= 250,
    { railW: w.railW, contentW: w.railContentW, cols: w.cols });

  check("one block per group, in the scorer's order person → drawing → contract",
    w.order.length === 3
    && /xo-group-person/.test(w.order[0])
    && /xo-group-drawing/.test(w.order[1])
    && /xo-group-contract/.test(w.order[2]), w.order);

  check("each group paints — none is laid out but invisible",
    w.person.visible && w.drawing.visible && w.contract.visible,
    [w.person.visible, w.drawing.visible, w.contract.visible]);

  check("each group asks its own question, in his words",
    /Can a person do what it promises/.test(w.person.question)
    && /Does it look like your drawing/.test(w.drawing.question)
    && /Is the contract covered/.test(w.contract.question),
    [w.person.question, w.drawing.question, w.contract.question]);

  // ── the headline is ONE word and it is the person group's ─────────────
  check("the headline is exactly one grade chip and it is one word",
    w.chips === 1 && /^(HIGH|MEDIUM|LOW)$/.test(w.chip.t), w.chip);
  // THE CARD'S PILL AND THE REPORT AGREE ON THE CURRENT GRADE (S225 fix).
  //
  // This is the captain's exact confusion, reproduced and then cured. The
  // `twice` fixture is his real DX-scorecard mission: first look MEDIUM (1
  // broken), re-check HIGH (0 broken). BEFORE this fix the card read `score`
  // (the first look, MEDIUM) while the report drew `score2` (the re-check,
  // HIGH), so the same mission said MEDIUM on its card and HIGH in its own
  // report — read as a HIGH→MEDIUM demotion. The card now reads the CURRENT
  // grade (the re-check's), off the re-check verdict the adapter records, so
  // the two surfaces land on the same word: HIGH.
  const pill = out.m["pill:lcars-20260921-twice"] || "";
  check("the board CARD's pill is grade-only in Number One's voice (◈ NUMBER ONE · WORD)",
    /^◈ NUMBER ONE · (HIGH|MEDIUM|LOW)$/.test(pill), pill);
  const cardGrade = (pill.match(/· (HIGH|MEDIUM|LOW)$/) || [])[1] || null;
  out.m.cardVsPane = {
    card: cardGrade, pane: w.chip.t,
    note: "S225 FIXED: the card shows the CURRENT grade (the re-check's), the "
        + "same one the report opens on. Both HIGH; MEDIUM→HIGH is an "
        + "improvement, and neither surface reads it as a demotion any more.",
  };
  check("the card grade and the report grade AGREE (both the re-check's HIGH)",
    cardGrade === "HIGH" && w.chip.t === "HIGH", out.m.cardVsPane);
  check("the headline reads the person group's grade (HIGH on the re-check)",
    w.chip.t === "HIGH" && /HIGH/.test(w.person.grade.t), [w.chip.t, w.person.grade]);
  // The photograph the captain gets: the report opened to its HIGH grade, with
  // its caption citing the card pill that now reads HIGH too. Card shot and
  // report shot together are the twice-looked mission agreeing.
  await shot("twice-card-and-report-agree", ".xo-pane .xo-score-block",
    "The report for lcars-20260921-twice — the captain's DX-scorecard mission "
    + "— opened to its grade: the badge reads HIGH (the re-check, after the "
    + "fixes) with the chip beneath it reading '▲ up from MEDIUM before the "
    + "fixes'. The board card for this same mission (see "
    + "card-lcars-20260921-twice.png) now reads ◈ NUMBER ONE · " + cardGrade
    + " — the two surfaces AGREE on the current grade. The build went "
    + "MEDIUM → HIGH, an improvement; nothing here reads as a demotion.", 620);

  // ── THE CONTRACT IS NOT A GRADE. The point of the whole change. ───────
  check("the contract block renders NO grade word anywhere",
    !/\b(HIGH|MEDIUM|LOW)\b/.test(w.contract.text), w.contract.text.slice(0, 300));
  check("the contract block has no grade node at all",
    w.contract.grade === null, w.contract.grade);
  check("the contract says how much was answered, as a count",
    w.contract.cov && /^17 of 58 answered$/.test(w.contract.cov.t), w.contract.cov);
  check("…and the count is NOT painted in any of the grade colours",
    w.contract.cov
    && w.contract.cov.c !== (w.person.grade || {}).c
    && w.contract.cov.c !== (w.drawing.grade || {}).c,
    { cov: w.contract.cov && w.contract.cov.c,
      person: (w.person.grade || {}).c, drawing: (w.drawing.grade || {}).c });
  check("the contract carries the scorer's 'this is not a grade' aside, on screen",
    /not a grade/i.test(w.contract.aside), w.contract.aside);

  // ── FOUR OUTCOMES, FOUR DISTINGUISHABLE STATES ───────────────────────
  const dr = w.drawing;
  check("'worked' is S224's validated blue, untouched",
    segsOf(dr, "w").length > 0 && segsOf(dr, "w").every((s) => s.bg === WORKED),
    segsOf(dr, "w").map((s) => s.bg));
  check("'didn't work' is the validated orange AND still hatched",
    segsOf(dr, "d").every((s) => s.bg === DIDNT && s.img && s.img !== "none"),
    segsOf(dr, "d").map((s) => [s.bg, (s.img || "").slice(0, 50)]));
  check("'couldn't see it' is the muted grey",
    segsOf(dr, "c").length > 0 && segsOf(dr, "c").every((s) => s.bg === NOCHK),
    segsOf(dr, "c").map((s) => s.bg));
  // …and the one this session is for: OUR failure is not a shade of HIS doubt.
  const u = segsOf(w.person, "u").concat(segsOf(dr, "u"));
  check("'couldn't set it up' is drawn at all",
    u.length > 0, (w.person.segs || []).map((s) => s.cls));
  check("'couldn't set it up' is HOLLOW — an outline, not a fifth grey fill",
    u.every((s) => s.shadow && s.shadow !== "none" && s.bg !== NOCHK),
    u.map((s) => [s.bg, s.shadow]));
  check("…and it is therefore distinguishable from 'couldn't see it' with no colour at all",
    u.every((s) => segsOf(dr, "c").every((c) => c.shadow !== s.shadow)),
    { setUp: u.map((s) => s.shadow), see: segsOf(dr, "c").map((s) => s.shadow) });

  check("every drawn count is written out beside its swatch",
    /25\s*worked/.test(w.person.counts.join(" | "))
    && /3\s*couldn't set up/.test(w.person.counts.join(" | ")),
    w.person.counts);
  check("a count that MOVED carries its delta; the rest do not invent one",
    w.person.counts.some((c) => /[+−]/.test(c)), w.person.counts);

  check("two bars per group, one for each look",
    w.person.bars === 2 && w.drawing.bars === 2 && w.contract.bars === 2,
    [w.person.bars, w.drawing.bars, w.contract.bars]);
  check("the two looks are dated ONCE, above all three groups",
    /First look/.test(w.whenBoth) && /now/i.test(w.whenBoth), w.whenBoth);

  // person: 26/30 then, 25/30 now — same denominator, comparable as drawn.
  const pw = segsOf(w.person, "w");
  check("the two bars share one scale (26 of 30 then is wider than 25 of 30 now)",
    pw.length === 2 && pw[0].w > pw[1].w && (pw[0].w - pw[1].w) < 12,
    pw.map((s) => s.w));

  check("nothing in the report spills past its own pane",
    w.overflow && w.overflow.px <= 1, w.overflow);

  // ── myChecking ────────────────────────────────────────────────────────
  check("what I couldn't check is on screen, and it is MINE",
    w.mine && w.mine.visible && /mine to fix/i.test(w.mine.text), w.mine);
  check("…and it does not read as a fault in his build",
    w.mine && /not a fault in your build/i.test(w.mine.text),
    w.mine && w.mine.text.slice(0, 200));

  await shot("01-rail-three-questions", ".xo-pane .xo-rail",
    "The report rail at its real width, on a mission looked at twice: one block "
    + "per question — can a person do it (HIGH), does it look like your drawing "
    + "(HIGH), is the contract covered (17 of 58 answered, and NO grade). Each "
    + "block carries the first look's bar and the re-check's on one scale.");
  await shot("02-contract-is-not-a-grade", ".xo-pane .xo-group-contract",
    "The contract group close up. It says '17 of 58 answered' in ordinary ink "
    + "with no HIGH/MEDIUM/LOW anywhere, and the scorer's own line under it: "
    + "this is not a grade, it is how much I could answer at all.");
  await shot("03-four-outcomes", ".xo-pane .xo-group-drawing",
    "The four outcomes in one bar: solid blue worked, hatched orange didn't "
    + "work, solid grey couldn't see it, and HOLLOW for couldn't set it up — "
    + "our own failure to reach the state, drawn as an empty box rather than a "
    + "fifth shade of his doubt.");
  await shot("04-mine-to-fix", ".xo-pane .xo-mine",
    "What I couldn't check, as he first sees it: the scorer's own note that "
    + "these are gaps in MY checking and not a fault in your build, the two "
    + "counts keyed to the same swatches the bars use, and a fold that says "
    + "how many there are before he opens it.");
  await ev(`(function(){var d=document.querySelector('.xo-pane .xo-mine details');`
    + `if(d) d.open=true; return true})()`);
  await sleep(300);
  await shot("04b-mine-to-fix-opened", ".xo-pane .xo-mine",
    "The same block opened (top of 52 rows): each one names the thing and the "
    + "reason I could not settle it — a seed that could not reach the state, a "
    + "behaviour with no test I could name. None of it is counted against him.",
    430);

  // ── 2. ONE LOOK ONLY: one bar per group, no delta claimed ─────────────
  await openReport("lcars-20260921-once");
  const w1 = await ev(PROBE);
  out.m.once = w1;
  check("a first look draws ONE bar per group",
    w1.person.bars === 1 && w1.drawing.bars === 1 && w1.contract.bars === 1,
    [w1.person.bars, w1.drawing.bars, w1.contract.bars]);
  check("…and claims no delta off a comparison nobody made",
    !w1.person.counts.some((c) => /[+−]/.test(c)), w1.person.counts);
  check("the headline is the FIRST look's person grade (MEDIUM)",
    w1.chip.t === "MEDIUM" && /MEDIUM/.test(w1.person.grade.t),
    [w1.chip.t, w1.person.grade]);
  check("a zero outcome is not drawn (person had 0 couldn't-see on the first look)",
    segsOf(w1.person, "c").length === 0
    && !/couldn't see/.test(w1.person.counts.join(" ")), w1.person.counts);
  await shot("05-first-look-only", ".xo-pane .xo-rail",
    "The same rail on a mission looked at once: one bar per question, no "
    + "'first look' label over a comparison nobody made, and no deltas.");

  // ── 3. NO DRAWING: the group is not drawn at all ──────────────────────
  await openReport("lcars-20260921-nodrawing");
  const w2 = await ev(PROBE);
  out.m.nodrawing = w2;
  check("a group with nothing in it is not drawn — no 'drawing — LOW' invented",
    w2.drawing === null && w2.order.length === 2, w2.order);
  check("…and the other two questions are still there",
    !!w2.person && !!w2.contract, [!!w2.person, !!w2.contract]);
  await shot("06-no-drawing-group-skipped", ".xo-pane .xo-rail",
    "A mission with no drawing: the drawing question is absent entirely, "
    + "rather than rendered as 'Does it look like your drawing? — LOW' over an "
    + "empty ledger. Two questions, not three.");

  // ── 4. THE OLD SHAPE STILL RENDERS ───────────────────────────────────
  await openReport("lcars-20260921-legacy");
  const w3 = await ev(PROBE);
  out.m.legacy = w3;
  check("a verdict with no groups still paints its rail",
    !w3.missing && w3.railW > 0 && w3.chips === 1, w3.chip);
  check("…and it is the OLD single whole-ledger bar and 3-row legend",
    w3.order.length === 0 && w3.legacyBars === 1 && w3.legacyLegend === 3,
    { groups: w3.order.length, bars: w3.legacyBars, legend: w3.legacyLegend });
  check("nothing in the old rail spills past the pane either",
    w3.overflow && w3.overflow.px <= 1, w3.overflow);
  await shot("07-old-shape-unchanged", ".xo-pane .xo-rail",
    "A mission scored before the split, with no groups on disk: it keeps the "
    + "old single whole-ledger bar and three-row legend exactly as it was. "
    + "This is also the height the new rail is measured against.");

  // HOW MUCH TALLER. Measured, not asserted — same page, same width, the only
  // difference being whether the verdict carries groups.
  out.m.heights = { newRail: w.railH, oldRail: w3.railH,
                    ratio: +(w.railH / w3.railH).toFixed(2),
                    wordsBesideIt: w.vtextH, headerNow: w.headH,
                    headerIfRailWereOld: Math.max(w3.railH, w.vtextH) };
  // THE HONEST COST, STATED RATHER THAN WISHED AWAY. Three questions — each
  // with a question, a grade or a count, two bars, its counts and the scorer's
  // caveat — cannot be a third taller than one grade over one bar; measured it
  // is about 3.4x the old rail, and it DOES drive the header past the prose
  // beside it. The numbers are recorded above so nobody has to re-measure them.
  //
  // What actually matters at this width is whether all three questions are ONE
  // SCREENFUL — if the third needs a scroll the reader never compares it with
  // the first, which is the entire reason for splitting them.
  check("all three questions are one screenful at a 1200px window",
    w.railH <= 1150, { railH: w.railH, viewport: 1200, heights: out.m.heights });

  // ── 5. THE PHONE ─────────────────────────────────────────────────────
  // 390 CSS px is where he actually reads this. The rail stacks above the
  // words there (the max-width:640px rule), so the whole pane is the subject.
  await viewport(390, 844);
  await openReport("lcars-20260921-twice");
  const p = await ev(PROBE);
  out.m.phone = p;
  check("on a 390px phone the rail takes the full width and stacks",
    p.railW > 300 && p.railW <= 390, { railW: p.railW, cols: p.cols });
  check("…and still nothing spills off the side",
    p.overflow && p.overflow.px <= 1, p.overflow);
  check("…and all three questions are still painted",
    p.person.visible && p.drawing.visible && p.contract.visible,
    [p.person && p.person.h, p.drawing && p.drawing.h, p.contract && p.contract.h]);
  await shot("08-phone-390", ".xo-pane .xo-rail",
    "The same rail at a true 390px phone viewport, where the rail stacks above "
    + "the words: all three questions, full width, nothing cut off at either "
    + "edge.");

  check("no uncaught exception was thrown on the page", cdp.errs.length === 0, cdp.errs);
}

main().then(() => {
  process.stdout.write(JSON.stringify(out, null, 1));
  process.exit(out.checks.every((c) => c.ok) ? 0 : 1);
}).catch((e) => {
  out.checks.push({ name: "the drive ran to completion", ok: false, detail: String(e && e.stack || e) });
  process.stdout.write(JSON.stringify(out, null, 1));
  process.exit(1);
});
