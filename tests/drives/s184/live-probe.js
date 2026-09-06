#!/usr/bin/env node
/* S184 LIVE PROBE — drive the REAL front-door grill in REAL headed Chrome
 * against a REAL model. Types the captain's idea, clicks ▸ Establish vision,
 * then answers each grill question with the next scripted captain reply,
 * screenshotting every turn, until the RECOMMENDATION screen appears, an error
 * appears, or the turn budget runs out. Everything it captures is verbatim.
 *
 * Usage: node live-probe.js --devtools-port N --url URL --out DIR
 *        --answers <file: one captain reply per line> --idea <text> [--turns N]
 */
const fs = require("fs");
function arg(n, d) { const i = process.argv.indexOf("--" + n);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL_ = arg("url"), OUT = arg("out", ".");
const IDEA = arg("idea", "a website that does personal finance stuff");
const ANSWERS = fs.readFileSync(arg("answers"), "utf8").split("\n").filter(s => s.trim());
const MAX = parseInt(arg("turns", "12"), 10);
const TURN_MS = 420000;

const READ = `(function(){
  function txt(el){return el?(el.textContent||"").replace(/[ \\t\\r\\n]+/g," ").trim():"";}
  var fd=document.getElementById("frontDoor");
  var btns=[].slice.call(fd?fd.querySelectorAll("button"):[]);
  return JSON.stringify({
    screen: (typeof frontDoorState!=="undefined")?frontDoorState.screen:null,
    busy:   (typeof frontDoorState!=="undefined")?!!frontDoorState.busy:null,
    error:  (typeof frontDoorState!=="undefined")?frontDoorState.error:null,
    sid:    (typeof frontDoorState!=="undefined")?frontDoorState.sid:null,
    rec:    (typeof frontDoorState!=="undefined")?frontDoorState.rec:null,
    question:(typeof frontDoorState!=="undefined")?frontDoorState.question:null,
    buttons: btns.map(function(b){return txt(b);}),
    text: txt(fd)
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
  const shot = async n => { const r = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    if (r.result && r.result.data) fs.writeFileSync(OUT + "/" + n, Buffer.from(r.result.data, "base64")); };
  const state = async () => JSON.parse(await ev(READ));
  const type = async t => ev(`(function(){var b=document.querySelector("#frontDoor textarea, #frontDoor input.fd-field");`
    + `if(!b)return "NO FIELD";b.value=${JSON.stringify(t)};b.dispatchEvent(new Event("input",{bubbles:true}));return "ok";})()`);
  const click = async label => ev(`(function(){var bs=[].slice.call(document.querySelectorAll("#frontDoor button"));`
    + `var b=bs.filter(function(x){return (x.textContent||"").indexOf(${JSON.stringify(label)})>=0;})[0];`
    + `if(!b)return "NO BUTTON: "+bs.map(function(x){return x.textContent;}).join(" | ");b.click();return "clicked";})()`);

  await send("Page.enable"); await send("Runtime.enable");
  await send("Page.navigate", { url: URL_ });
  for (let i = 0; i < 200; i++) { if (await ev(`(function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`)) break;
    await new Promise(r => setTimeout(r, 200)); }
  await new Promise(r => setTimeout(r, 800));
  await shot("live-00-door.png");

  const journal = [];
  const note = o => { journal.push(o); console.log(JSON.stringify(o)); 
    fs.writeFileSync(OUT + "/journal.json", JSON.stringify(journal, null, 1)); };

  console.log("TYPE IDEA: " + IDEA);
  console.log(await type(IDEA));
  console.log(await click("Establish"));

  for (let turn = 1; turn <= MAX; turn++) {
    const t0 = Date.now(); let s = await state();
    while (s.busy && Date.now() - t0 < TURN_MS) { await new Promise(r => setTimeout(r, 2000)); s = await state(); }
    const secs = Math.round((Date.now() - t0) / 1000);
    await shot("live-" + String(turn).padStart(2, "0") + ".png");
    note({ turn, secs, screen: s.screen, error: s.error, question: s.question,
           buttons: s.buttons, rec: s.rec, text: s.text });
    if (s.error) { console.log("STOPPED: error after " + secs + "s"); break; }
    if (s.screen === "recommend") { console.log("REACHED SCREEN 3 on turn " + turn); break; }
    if (s.busy) { console.log("STOPPED: turn still busy after " + secs + "s (hang)"); break; }
    const a = ANSWERS[(turn - 1) % ANSWERS.length];
    console.log("ANSWER " + turn + ": " + a);
    console.log(await type(a));
    console.log(await click("Continue"));
    await new Promise(r => setTimeout(r, 1500));
  }
  const fin = await state();
  fs.writeFileSync(OUT + "/final-state.json", JSON.stringify(fin, null, 1));
  await shot("live-final.png");
  console.log("FINAL screen=" + fin.screen + " error=" + (fin.error || "") );
  process.exit(0);
})().catch(e => { console.error("SKIP 77: probe crashed: " + e.message); process.exit(77); });
