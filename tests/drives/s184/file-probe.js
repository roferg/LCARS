#!/usr/bin/env node
/* S184 VERIFICATION PROBE — the WHOLE front door, live, to a FILED MISSION.
 * Extends the previous tester's live-probe.js with the three legs it stopped
 * short of: (a) a CHOICE CHIP answer, (b) screen 3 SCROLLING at a short
 * viewport (the holodeck mask), and (c) the ✓ Accept & file mission click.
 * Everything it records is verbatim; it scans every painted frame for
 * "[object Object]" (D3).
 */
const fs = require("fs");
function arg(n, d) { const i = process.argv.indexOf("--" + n);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : d; }
const has = n => process.argv.indexOf("--" + n) >= 0;
const PORT = arg("devtools-port"), URL_ = arg("url"), OUT = arg("out", ".");
const IDEA = arg("idea", "a website that does personal finance stuff");
const ANSWERS = fs.readFileSync(arg("answers"), "utf8").split("\n").filter(s => s.trim());
const MAX = parseInt(arg("turns", "12"), 10);
const CHIP_TURN = parseInt(arg("chip-turn", "0"), 10);   // 0 = never
const MODE = arg("mode", "accept");                        // accept | override
const OVERRIDE_STACK = arg("stack", "Go + net/http + go test");
const TURN_MS = 480000;

const READ = `(function(){
  function txt(el){return el?(el.textContent||"").replace(/[ \\t\\r\\n]+/g," ").trim():"";}
  var fd=document.getElementById("frontDoor");
  var btns=[].slice.call(fd?fd.querySelectorAll("button"):[]);
  var chips=[].slice.call(fd?fd.querySelectorAll("button.fd-choice"):[]);
  return JSON.stringify({
    screen:(typeof frontDoorState!=="undefined")?frontDoorState.screen:null,
    busy:(typeof frontDoorState!=="undefined")?!!frontDoorState.busy:null,
    error:(typeof frontDoorState!=="undefined")?frontDoorState.error:null,
    sid:(typeof frontDoorState!=="undefined")?frontDoorState.sid:null,
    rec:(typeof frontDoorState!=="undefined")?frontDoorState.rec:null,
    question:(typeof frontDoorState!=="undefined")?frontDoorState.question:null,
    buttons:btns.map(txt), chips:chips.map(txt),
    hidden: !!(fd&&fd.hidden), cards:document.querySelectorAll(".card").length,
    text:txt(fd), bodyText:txt(document.body)
  });
})()`;

(async () => {
  const list = await fetch("http://127.0.0.1:" + PORT + "/json/list").then(r => r.json());
  const page = list.find(t => t.type === "page" && t.webSocketDebuggerUrl);
  if (!page) { console.error("SKIP 77: no drivable page"); process.exit(77); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0; const waiters = new Map();
  const send = (m, p) => new Promise(res => { const i = ++id; waiters.set(i, res);
    ws.send(JSON.stringify({ id: i, method: m, params: p || {} })); });
  ws.addEventListener("message", e => { const m = JSON.parse(e.data);
    if (m.id && waiters.has(m.id)) { waiters.get(m.id)(m); waiters.delete(m.id); } });
  await new Promise((r, j) => { ws.addEventListener("open", r, { once: true });
    ws.addEventListener("error", () => j(new Error("ws refused")), { once: true }); });
  const ev = async e => {
    const r = await send("Runtime.evaluate", { expression: e, returnByValue: true, awaitPromise: true });
    return r.result && r.result.result && r.result.result.value;
  };
  const shot = async (n, beyond) => {
    const r = await send("Page.captureScreenshot",
      { format: "png", captureBeyondViewport: beyond !== false });
    if (r.result && r.result.data) fs.writeFileSync(OUT + "/" + n, Buffer.from(r.result.data, "base64"));
  };
  const state = async () => JSON.parse(await ev(READ));
  const type = async t => ev(`(function(){var b=document.querySelector("#frontDoor textarea, #frontDoor input.fd-field");`
    + `if(!b)return "NO FIELD";b.value=${JSON.stringify(t)};b.dispatchEvent(new Event("input",{bubbles:true}));return "ok";})()`);
  const click = async label => ev(`(function(){var bs=[].slice.call(document.querySelectorAll("#frontDoor button"));`
    + `var b=bs.filter(function(x){return (x.textContent||"").indexOf(${JSON.stringify(label)})>=0;})[0];`
    + `if(!b)return "NO BUTTON: "+bs.map(function(x){return x.textContent;}).join(" | ");b.click();return "clicked";})()`);
  const clickChip = async () => ev(`(function(){var cs=[].slice.call(document.querySelectorAll("#frontDoor button.fd-choice"));`
    + `if(!cs.length)return "NO CHIPS";var b=cs.filter(function(x){return /recommended/.test(x.textContent||"");})[0]||cs[0];`
    + `var lab=(b.textContent||"").trim();b.click();return "CHIP CLICKED: "+lab;})()`);

  const journal = []; let objObj = [];
  const note = o => { journal.push(o); console.log(JSON.stringify(o));
    fs.writeFileSync(OUT + "/journal.json", JSON.stringify(journal, null, 1)); };
  const scanObj = (where, s) => {
    if (s && s.bodyText && s.bodyText.indexOf("[object Object]") >= 0) {
      objObj.push(where); console.log("!!! [object Object] AT " + where);
    }
  };

  await send("Page.enable"); await send("Runtime.enable");
  await send("Page.navigate", { url: URL_ });
  for (let i = 0; i < 250; i++) { if (await ev(`(function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`)) break;
    await new Promise(r => setTimeout(r, 200)); }
  await new Promise(r => setTimeout(r, 900));
  await shot("s1-door.png");
  scanObj("screen1", await state());

  console.log("TYPE IDEA: " + IDEA);
  console.log(await type(IDEA));
  console.log(await click("Establish"));

  let reached = false, lastTurn = 0;
  for (let turn = 1; turn <= MAX; turn++) {
    lastTurn = turn;
    const t0 = Date.now(); let s = await state();
    while (s.busy && Date.now() - t0 < TURN_MS) { await new Promise(r => setTimeout(r, 2000)); s = await state(); }
    const secs = Math.round((Date.now() - t0) / 1000);
    await shot("t" + String(turn).padStart(2, "0") + ".png");
    scanObj("turn" + turn, s);
    note({ turn, secs, screen: s.screen, sid: s.sid, error: s.error,
           question: s.question, chips: s.chips, buttons: s.buttons, rec: s.rec,
           text: s.text });
    if (s.error) { console.log("STOPPED: error after " + secs + "s"); break; }
    if (s.screen === "recommend") { console.log("REACHED SCREEN 3 on turn " + turn); reached = true; break; }
    if (s.busy) { console.log("STOPPED: still busy after " + secs + "s (hang)"); break; }
    if (turn === CHIP_TURN && s.chips && s.chips.length) {
      const r = await clickChip(); console.log("TURN " + turn + " " + r);
      note({ turn, chipAnswer: r });
    } else {
      const a = ANSWERS[Math.min(turn - 1, ANSWERS.length - 1)];
      console.log("ANSWER " + turn + ": " + a);
      console.log(await type(a));
      console.log(await click("Continue"));
    }
    await new Promise(r => setTimeout(r, 1500));
  }

  if (!reached) {
    const fin = await state();
    fs.writeFileSync(OUT + "/final-state.json", JSON.stringify({ ...fin, objObj, reached }, null, 1));
    await shot("final.png");
    console.log("DID NOT REACH SCREEN 3. objObj=" + JSON.stringify(objObj));
    process.exit(0);
  }

  // --- screen 3 in the frame, then SCROLLED at a SHORT viewport (item 5) ----
  await shot("s3-recommend.png", false);
  await shot("s3-recommend-full.png", true);
  for (const h of [620, 520]) {
    await send("Emulation.setDeviceMetricsOverride",
      { width: 1440, height: h, deviceScaleFactor: 1, mobile: false });
    await new Promise(r => setTimeout(r, 500));
    await ev(`(function(){var f=document.getElementById("frontDoor");if(f)f.scrollTop=0;window.scrollTo(0,0);return 1;})()`);
    await new Promise(r => setTimeout(r, 350));
    await shot("s3-short" + h + "-top.png", false);
    const m = await ev(`(function(){var f=document.getElementById("frontDoor");
      var t=f.scrollHeight>f.clientHeight?f:document.scrollingElement;
      t.scrollTop=t.scrollHeight;window.scrollTo(0,document.body.scrollHeight);
      return JSON.stringify({fdScrollH:f.scrollHeight,fdClientH:f.clientHeight,
        docScrollH:document.scrollingElement.scrollHeight,
        docClientH:document.scrollingElement.clientHeight,
        scrolledTarget:(t===f?"frontDoor":"document"),after:t.scrollTop});})()`);
    console.log("SHORT " + h + " scroll: " + m);
    await new Promise(r => setTimeout(r, 450));
    await shot("s3-short" + h + "-bottom.png", false);
    fs.writeFileSync(OUT + "/scroll-" + h + ".json", m || "{}");
  }
  await send("Emulation.clearDeviceMetricsOverride");
  await new Promise(r => setTimeout(r, 500));

  // --- the decision -------------------------------------------------------
  const before = await state();
  fs.writeFileSync(OUT + "/recommendation.json", JSON.stringify(before.rec, null, 1));
  fs.writeFileSync(OUT + "/screen3-text.txt", before.text || "");
  if (MODE === "override") {
    console.log("click override: " + await click("different stack"));
    await new Promise(r => setTimeout(r, 700));
    await shot("s4-override.png", false);
    const ovs = await state(); scanObj("override", ovs);
    fs.writeFileSync(OUT + "/override-screen.txt", ovs.text || "");
    const box = await ev(`(function(){var b=document.querySelector("#frontDoor input.fd-field");`
      + `if(!b)return "NO INPUT";var r=b.getBoundingClientRect();`
      + `b.value=${JSON.stringify(OVERRIDE_STACK)};`
      + `return JSON.stringify({tag:b.tagName,h:Math.round(r.height),w:Math.round(r.width),v:b.value});})()`);
    console.log("override input: " + box);
    fs.writeFileSync(OUT + "/override-input.json", String(box));
    console.log("click file: " + await click("Use this stack"));
  } else {
    console.log("click ACCEPT: " + await click("Accept & file mission"));
  }
  for (let i = 0; i < 90; i++) {
    const s = await state();
    if (s.hidden || s.error) break;
    await new Promise(r => setTimeout(r, 1000));
  }
  await new Promise(r => setTimeout(r, 2500));
  const fin = await state();
  scanObj("after-file", fin);
  await shot("s5-after-file.png", false);
  fs.writeFileSync(OUT + "/final-state.json",
    JSON.stringify({ ...fin, objObj, reached, lastTurn, mode: MODE }, null, 1));
  console.log("AFTER FILE: hidden=" + fin.hidden + " cards=" + fin.cards
              + " screen=" + fin.screen + " error=" + (fin.error || ""));
  console.log("OBJECT_OBJECT_HITS=" + objObj.length + " " + JSON.stringify(objObj));
  process.exit(0);
})().catch(e => { console.error("SKIP 77: probe crashed: " + e.message + "\n" + e.stack); process.exit(77); });
