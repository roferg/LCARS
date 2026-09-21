#!/usr/bin/env node
/* S221 fix 4 — BREATHING ROOM UNDER THE FILTER ROWS, measured in REAL headless
 * Chrome over raw CDP against the REAL daemon.
 *
 *   node gap.js --devtools-port N --url BOARD_URL --out DIR
 *
 * WHY A BROWSER AND NOT A TEST THAT GREPS THE STYLESHEET. This is a CASCADE
 * problem. A rule can exist, be correct, and never reach the screen — two
 * selectors that tie on specificity are decided by SOURCE ORDER, and this repo
 * has already shipped an amber warning that tested green and rendered as muted
 * metadata. So nothing here reads board.css. It reads getComputedStyle and the
 * measured distance in px between the filter row's bottom edge and the top of
 * the heading beneath it — which is the thing the captain actually saw.
 *
 * Prints one JSON object: {rows: {...}, checks: [...]}; exit 0 only when every
 * check is ok. Shots land in DIR (gitignored).
 */
const fs = require("fs"), path = require("path");
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), OUT = arg("out", ".");
const MIN_GAP = +arg("min-gap", "14");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

class CDP {
  constructor(ws) { this.ws = ws; this.next = 1; this.pending = new Map();
    ws.addEventListener("message", (ev) => { let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); } }); }
  send(method, params, sid) { const id = this.next++; const pl = { id, method, params: params || {} };
    if (sid) pl.sessionId = sid; this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej })); } }
const connect = (u) => new Promise((res, rej) => { const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused")), { once: true }); });

let cdp, sid;
async function ev(expr) {
  const r = await cdp.send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true }, sid);
  if (r && r.exceptionDetails) throw new Error("probe threw: " + JSON.stringify(r.exceptionDetails).slice(0, 500));
  return r && r.result ? r.result.value : null;
}
async function waitFor(expr, ms) { const dl = Date.now() + (ms || 15000);
  while (Date.now() < dl) { try { if (await ev(expr)) return true; } catch (e) {} await sleep(100); } return false; }
async function shot(name, clipSel) {
  let params = { format: "png" };
  if (clipSel) {
    const r = await ev(`(function(){var e=document.querySelector(${JSON.stringify(clipSel)}); if(!e) return null;
      e.scrollIntoView({block:'center'}); var b=e.getBoundingClientRect();
      return {x:b.left,y:b.top,w:b.width,h:b.height}})()`);
    await sleep(150);
    const r2 = await ev(`(function(){var e=document.querySelector(${JSON.stringify(clipSel)}); if(!e) return null;
      var b=e.getBoundingClientRect(); return {x:b.left,y:b.top,w:b.width,h:b.height}})()`);
    const rr = r2 || r;
    if (rr && rr.w > 0) params.clip = { x: Math.max(0, rr.x - 8), y: Math.max(0, rr.y - 8), width: rr.w + 16, height: rr.h + 60, scale: 1 };
  }
  const img = await cdp.send("Page.captureScreenshot", params, sid);
  const f = path.join(OUT, name + ".png"); fs.writeFileSync(f, Buffer.from(img.data, "base64")); return f;
}

const out = { rows: {}, checks: [], shots: [] };
function check(name, ok, detail) { out.checks.push({ name, ok: !!ok, detail: detail === undefined ? null : detail }); }

/* THE MEASUREMENT, written once and used for both rows. It is deliberately
   geometric: the bottom of the filter row's border box to the top of the next
   visible element's border box. Margins, padding and collapsing are all
   already folded into those two numbers, which is exactly why this — and not a
   reading of `margin-bottom` — is the number the captain's eye reports. */
const MEASURE = (rowSel, nextSel) => `(function(){
  var row = document.querySelector(${JSON.stringify(rowSel)});
  if (!row) return {err: "no row"};
  var next = null, cands = document.querySelectorAll(${JSON.stringify(nextSel)});
  for (var i = 0; i < cands.length; i++) {
    var c = cands[i], b = c.getBoundingClientRect();
    if (c.hidden || (!b.height && !b.width)) continue;
    if (b.top >= row.getBoundingClientRect().bottom - 0.5) { next = c; break; }
  }
  if (!next) return {err: "no heading under the row"};
  var rb = row.getBoundingClientRect(), nb = next.getBoundingClientRect();
  var cs = getComputedStyle(row);
  return {gap: Math.round((nb.top - rb.bottom) * 100) / 100,
          rowMarginBottom: cs.marginBottom, rowPaddingBottom: cs.paddingBottom,
          nextTag: next.className || next.tagName, nextMarginTop: getComputedStyle(next).marginTop};
})()`;

/* A report of the real shape, fed to the REAL renderer (xoReportPane) — the
   same function the ◈ Number One tab calls — inside a REAL modal, so the
   cascade the row lands in is the cascade the captain sees. */
const FIXTURE = `(function(){
  var crit = [];
  var kinds = [["met","Worked"],["gap","Didn't work"],["untested","Couldn't check"]];
  for (var i = 0; i < 12; i++) {
    var k = kinds[i % 3];
    crit.push({id: "prd-" + i, text: "Requirement number " + i + " of the captain's list.",
               impact: i % 2 ? "high" : "medium", impactWhy: "it is the point of the mission.",
               status: k[0], shot: "shot-01", evidence: "picture",
               note: "what I saw on the screen for row " + i,
               reason: "Impact high. I looked twice. Outcome: " + k[1].toLowerCase() + "."});
  }
  return {id: "lcars-20260920-001", title: "The tile readout", stage: "verify",
    numberOne: {status: "finished", score: "medium", engine: "copilot",
      headline: "Most of it works; one thing I could not check.",
      report: {score: "medium", logs: [],
        verdict: {score: "medium", derivation: "Most of it works; one thing I could not check.",
          scoreMeaning: "medium means most of it works.",
          summary: "I walked the build and checked each row.",
          counts: {met: 4, gap: 4, untested: 4},
          criteria: crit,
          observations: [{what: "two controls overlap", where: "the header",
                          screen: "Default", kind: "overlap", detail: "measured 4px of overlap"}],
          gaps: [], alsoChecked: ["the header"]}}}};
})()`;

(async () => {
  const list = JSON.parse(await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).text());
  const page = list.find((t) => t.type === "page") || list[0];
  cdp = new CDP(await connect(page.webSocketDebuggerUrl));
  const at = await cdp.send("Target.attachToTarget", { targetId: page.id, flatten: true });
  sid = at.sessionId;
  await cdp.send("Page.enable", {}, sid);
  await cdp.send("Runtime.enable", {}, sid);
  await cdp.send("Emulation.setDeviceMetricsOverride", { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false }, sid);
  await cdp.send("Page.navigate", { url: URL }, sid);
  if (!await waitFor(`typeof xoReportPane === "function"`, 30000)) throw new Error("board.js never loaded");
  await sleep(700);

  /* ── ROW 1 · the Number One report's All / Didn't work / … row ── */
  await ev(`(function(){
    if (typeof closeOverlay === "function") closeOverlay();
    var m = modal("◈ NUMBER ONE", {headClass: "xo", wide: true});
    m.body.appendChild(xoReportPane(${FIXTURE}));
    showOverlay(m.wrap);
    return true})()`);
  await waitFor(`!!document.querySelector('.xo-filters')`, 10000);
  await sleep(400);
  const r1 = await ev(MEASURE(".xo-filters", ".xo-items > *"));
  out.rows.numberOneReport = r1;
  check("the ◈ Number One report's filter row has breathing room under it",
        r1 && !r1.err && r1.gap >= MIN_GAP, r1);
  out.shots.push(await shot("filter-row-number-one", ".xo-filters"));
  await ev(`closeOverlay()`);
  await sleep(300);

  /* ── ROW 2 · the First Officer's report "Show:" row ── */
  await ev(`openXoReport()`);
  await waitFor(`!!document.querySelector('.xo-report-controls')`, 20000);
  await sleep(900);
  const r2 = await ev(MEASURE(".xo-report-controls",
    ".xo-report-groups > *, .xo-report-since-head, .xo-hist-line, .xo-report-history > *"));
  out.rows.firstOfficerReport = r2;
  check("the First Officer's report Show row has breathing room under it",
        r2 && !r2.err && r2.gap >= MIN_GAP, r2);
  out.shots.push(await shot("filter-row-first-officer", ".xo-report-controls"));

  console.log(JSON.stringify(out, null, 2));
  process.exit(out.checks.every((c) => c.ok) ? 0 : 1);
})().catch((e) => { console.log(JSON.stringify({ error: String(e), out }, null, 2)); process.exit(2); });
