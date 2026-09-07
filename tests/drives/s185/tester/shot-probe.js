#!/usr/bin/env node
/* S185 SHOT PROBE — the REAL viewscreen, the REAL daemon, REAL headed Chrome.
 *
 * Three screens the captain asked for:
 *   01  holodeck LOCKED, before the initialization mission is approved
 *   03  the VERIFY surface, showing the scaffold ticket waived AND WHY
 *   02  holodeck + File Mission UNLOCKED, after approve
 *
 * The unlock is exercised on the SAME LIVE DAEMON: approve runs while the board
 * is open, and the board is re-read without restarting anything, so the memo
 * invalidation is the thing under test, not a fresh process.
 */
const fs = require("fs");
const { execFileSync } = require("child_process");
function arg(n, d) { const i = process.argv.indexOf("--" + n);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL_ = arg("url"), OUT = arg("out", ".");
const APPROVE = arg("approve-cmd");
const MID = arg("mission", "init-001");
const TIMEOUT = 30000;

const READ = `(function () {
  function vis(el){ if(!el||el.hidden) return false;
    var r=el.getBoundingClientRect(); if(r.width<=0||r.height<=0) return false;
    var s=getComputedStyle(el); return s.display!=="none"&&s.visibility!=="hidden"; }
  function txt(el){ return el?(el.textContent||"").replace(/[ \\t\\r\\n]+/g," ").trim():""; }
  function btn(id){ var b=document.getElementById(id); if(!b) return null;
    var s=getComputedStyle(b);
    return { present:true, disabled:!!b.disabled, visible:vis(b),
             className:b.className, title:b.title||"",
             dataReason:b.getAttribute("data-reason")||"",
             opacity:s.opacity, cursor:s.cursor, label:txt(b) }; }
  var fd=document.getElementById("frontDoor");
  return JSON.stringify({
    frontDoorVisible: vis(fd),
    holodeckBtn: btn("holodeckBtn"),
    fileBtn: btn("fileBtn"),
    columnsVisible: [].slice.call(document.querySelectorAll(".col, .column, [data-stage]")).filter(vis).length,
    cardsVisible: [].slice.call(document.querySelectorAll(".card")).filter(vis).length,
    ffChips: [].slice.call(document.querySelectorAll(".ff-chip")).map(function(c){
       var w=c.parentNode; return txt(w); }),
    bodyText: txt(document.body).slice(0, 2000)
  }, null, 1);
})()`;

const OPEN_CARD = `(function(){
  var c=document.querySelector(".card");
  if(!c) return "NO CARD";
  c.click(); return "clicked: "+(c.textContent||"").replace(/\\s+/g," ").trim().slice(0,80);
})()`;

const DETAIL = `(function(){
  function txt(el){ return el?(el.textContent||"").replace(/[ \\t\\r\\n]+/g," ").trim():""; }
  var chips=[].slice.call(document.querySelectorAll(".ff-chip"));
  return JSON.stringify({
    chipCount: chips.length,
    chips: chips.map(function(c){ return txt(c.parentNode); }),
    detailOpen: !!document.querySelector(".detail, #detail, .mission-detail, .drawer"),
    visibleText: txt(document.body).slice(0, 4000)
  }, null, 1);
})()`;

(async () => {
  const list = await fetch("http://127.0.0.1:" + PORT + "/json/list").then(r => r.json());
  const page = list.find(t => t.type === "page" && t.webSocketDebuggerUrl);
  if (!page) { console.error("SKIP 77: no drivable page"); process.exit(77); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0; const waiters = new Map();
  const send = (method, params) => new Promise((res) => {
    const i = ++id; waiters.set(i, res);
    ws.send(JSON.stringify({ id: i, method, params: params || {} }));
  });
  ws.addEventListener("message", e => {
    const m = JSON.parse(e.data);
    if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); }
  });
  await new Promise((r, j) => {
    ws.addEventListener("open", r, { once: true });
    ws.addEventListener("error", () => j(new Error("ws refused")), { once: true });
  });
  const evalJs = async expr => {
    const r = await send("Runtime.evaluate", { expression: expr, returnByValue: true, awaitPromise: true });
    return r.result && r.result.result && r.result.result.value;
  };
  const shot = async name => {
    const r = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    if (r.result && r.result.data) {
      fs.writeFileSync(OUT + "/" + name, Buffer.from(r.result.data, "base64"));
      console.log("shot: " + OUT + "/" + name);
    }
  };
  const sleep = ms => new Promise(r => setTimeout(r, ms));

  await send("Page.enable"); await send("Runtime.enable");
  await send("Page.navigate", { url: URL_ });
  const deadline = Date.now() + TIMEOUT;
  while (Date.now() < deadline) {
    const booted = await evalJs(`!!document.getElementById("fileBtn") ||
      (function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`);
    if (booted) break;
    await sleep(200);
  }
  const settleBy = Date.now() + TIMEOUT;
  while (Date.now() < settleBy) {
    const s = await evalJs(`document.querySelectorAll(".col, .column, [data-stage]").length > 0 ||
      (function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`);
    if (s) break;
    await sleep(250);
  }
  await sleep(1500);

  /* ---- 01 LOCKED ---- */
  let st = await evalJs(READ);
  fs.writeFileSync(OUT + "/01-locked.state.json", st);
  console.log("=== 01 LOCKED (before approve) ===\n" + st.slice(0, 1400));
  await shot("01-holodeck-locked.png");
  const api1 = await evalJs(`fetch("/api/board").then(r=>r.json()).then(b=>JSON.stringify({
      foundation:b.meta&&b.meta.foundation, frontDoor:!!(b.meta&&b.meta.frontDoor),
      testReadiness:b.meta&&b.meta.testReadiness}))`);
  fs.writeFileSync(OUT + "/01-locked.api.json", api1 || "");
  console.log("api meta: " + api1);

  /* ---- 03 THE VERIFY SURFACE ---- */
  console.log("open card: " + await evalJs(OPEN_CARD));
  await sleep(1500);
  const d = await evalJs(DETAIL);
  fs.writeFileSync(OUT + "/03-verify.state.json", d);
  console.log("=== 03 VERIFY SURFACE (activity) ===\n" + d.slice(0, 2500));
  await shot("03a-verify-activity.png");

  /* The TICKETS · WAVES tab — where the per-ticket flip-flop chip lives. */
  const tab = await evalJs(`(function(){
    var b=[].slice.call(document.querySelectorAll("button, .tab, [role=tab]"))
      .filter(function(n){return /TICKETS\\s*[·.]\\s*WAVES/i.test(n.textContent||"");})[0];
    if(!b) return "NO TICKETS TAB";
    b.click(); return "clicked tickets tab";
  })()`);
  console.log("tickets tab: " + tab);
  await sleep(1200);
  const dt = await evalJs(DETAIL);
  fs.writeFileSync(OUT + "/03-verify-tickets.state.json", dt);
  console.log("=== 03 VERIFY SURFACE (tickets·waves) ===\n" + dt.slice(0, 2500));
  await shot("03-verify-waived.png");

  /* And the waiver event itself, scrolled into view in the activity log. */
  const sc = await evalJs(`(function(){
    var n=[].slice.call(document.querySelectorAll("*")).filter(function(e){
      return e.children.length===0 && /PROOF WAIVED/i.test(e.textContent||"");})[0];
    if(!n) return "NO WAIVER EVENT NODE";
    n.scrollIntoView({block:"center"}); return "scrolled to: "+(n.textContent||"").trim().slice(0,60);
  })()`);
  console.log("waiver event: " + sc);
  await sleep(900);
  await shot("03b-verify-waiver-event.png");

  /* ---- run approve against the SAME live repo, daemon still up ---- */
  if (APPROVE) {
    console.log("=== running approve while the board is open ===");
    try {
      const o = execFileSync("bash", [APPROVE], { encoding: "utf8" });
      fs.writeFileSync(OUT + "/approve.log", o);
      console.log(o.split("\n").slice(0, 12).join("\n"));
    } catch (e) {
      fs.writeFileSync(OUT + "/approve.log", String(e.stdout || "") + String(e.stderr || ""));
      console.log("approve FAILED: " + e.message);
    }
  }

  /* ---- 02 UNLOCKED — SAME PAGE, SAME DAEMON, no reload first ---- */
  await sleep(4000);
  let live = await evalJs(READ);
  fs.writeFileSync(OUT + "/02-unlocked-live.state.json", live);
  console.log("=== 02a AFTER APPROVE, WITHOUT RELOADING (live SSE) ===\n" + live.slice(0, 900));
  await shot("02a-after-approve-no-reload.png");

  await send("Page.navigate", { url: URL_ });
  await sleep(4000);
  let un = await evalJs(READ);
  fs.writeFileSync(OUT + "/02-unlocked.state.json", un);
  console.log("=== 02 UNLOCKED (after approve, reloaded — SAME daemon process) ===\n" + un.slice(0, 1400));
  await shot("02-holodeck-unlocked.png");
  const api2 = await evalJs(`fetch("/api/board").then(r=>r.json()).then(b=>JSON.stringify({
      foundation:b.meta&&b.meta.foundation, frontDoor:!!(b.meta&&b.meta.frontDoor),
      testReadiness:b.meta&&b.meta.testReadiness}))`);
  fs.writeFileSync(OUT + "/02-unlocked.api.json", api2 || "");
  console.log("api meta: " + api2);

  process.exit(0);
})().catch(e => { console.error("SKIP 77: probe crashed: " + e.message); process.exit(77); });
