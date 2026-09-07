/* S183b — REAL-CHROME probe for the foundation lock.
 * Connects to a live Chrome over CDP, loads the board, MEASURES the ▦ File
 * Mission and ⬡ Holodeck controls (disabled state, computed opacity, the text
 * a human can actually READ on screen), then CLICKS File and measures what
 * opens. Screenshots both. Purpose-built and small; the shared painting rig
 * lives at tests/drives/browser/ and is not duplicated here.
 *
 * node lock-probe.js --devtools-port N --url URL --out DIR
 */
const fs = require("fs");
const http = require("http");
function arg(n, d) { const i = process.argv.indexOf("--" + n);
  return i > -1 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL_ = arg("url"), OUT = arg("out");
const TIMEOUT = parseInt(arg("timeout", "25000"), 10);

function json(path) {
  return new Promise((res, rej) => {
    http.get({ host: "127.0.0.1", port: PORT, path }, r => {
      let b = ""; r.on("data", c => b += c);
      r.on("end", () => { try { res(JSON.parse(b)); } catch (e) { rej(e); } });
    }).on("error", rej);
  });
}

const READ = `(function () {
  function seen(el) {
    if (!el) return null;
    var r = el.getBoundingClientRect(), s = getComputedStyle(el);
    return {
      text: (el.textContent || "").replace(/\\s+/g, " ").trim(),
      disabledProp: !!el.disabled,
      ariaDisabled: el.getAttribute("aria-disabled"),
      classes: el.className,
      title: el.title || "",
      dataReason: el.getAttribute("data-reason") || "",
      opacity: s.opacity, cursor: s.cursor, color: s.color,
      pointerEvents: s.pointerEvents,
      box: { w: Math.round(r.width), h: Math.round(r.height) },
      visible: r.width > 0 && r.height > 0 && s.display !== "none" &&
               s.visibility !== "hidden" && parseFloat(s.opacity || "1") > 0.01
    };
  }
  var banner = document.getElementById("readinessBanner");
  return {
    fileBtn: seen(document.getElementById("fileBtn")),
    holodeckBtn: seen(document.getElementById("holodeckBtn")),
    readinessBanner: banner && !banner.hidden
      ? (banner.innerText || "").replace(/\\s+/g, " ").trim() : "",
    cards: document.querySelectorAll(".card").length,
    /* what a human can READ on the page without hovering anything */
    bodyText: (document.body.innerText || "").replace(/\\s+/g, " ").trim()
  };
})()`;

const CLICK_FILE = `(function () {
  var b = document.getElementById("fileBtn");
  if (!b) return { clicked: false, why: "no #fileBtn" };
  b.click();
  return { clicked: true, disabledAtClick: !!b.disabled };
})()`;

const OVERLAY = `(function () {
  var ov = document.getElementById("overlay");
  if (!ov || ov.hidden) return { open: false, hiddenFlag: ov ? ov.hidden : "no #overlay" };
  var m = ov.querySelector(".modal");
  return {
    open: true,
    title: m ? ((m.querySelector(".modal-head") || {}).innerText || "").replace(/\\s+/g, " ").trim() : "",
    text: ((m || ov).innerText || "").replace(/\\s+/g, " ").trim(),
    hasTextarea: !!(m || ov).querySelector("textarea"),
    textareaPlaceholder: (((m || ov).querySelector("textarea")) || {}).placeholder || ""
  };
})()`;

(async () => {
  const targets = await json("/json/list");
  const page = targets.find(t => t.type === "page" && t.webSocketDebuggerUrl);
  if (!page) { console.error("no drivable page"); process.exit(77); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0; const waiters = new Map();
  const send = (method, params) => new Promise((res, rej) => {
    const i = ++id; waiters.set(i, { res, rej });
    ws.send(JSON.stringify({ id: i, method, params: params || {} }));
  });
  ws.addEventListener("message", e => {
    const m = JSON.parse(e.data);
    if (m.id && waiters.has(m.id)) { waiters.get(m.id).res(m); waiters.delete(m.id); }
  });
  await new Promise((r, j) => {
    ws.addEventListener("open", r, { once: true });
    ws.addEventListener("error", () => j(new Error("ws refused")), { once: true });
  });
  const evalJs = async expr => {
    const r = await send("Runtime.evaluate",
      { expression: expr, returnByValue: true, awaitPromise: true });
    if (r.result && r.result.exceptionDetails)
      throw new Error(JSON.stringify(r.result.exceptionDetails));
    return r.result && r.result.result && r.result.result.value;
  };
  const shot = async name => {
    const r = await send("Page.captureScreenshot", { format: "png" });
    if (r.result && r.result.data)
      fs.writeFileSync(OUT + "/" + name, Buffer.from(r.result.data, "base64"));
  };

  await send("Page.enable");
  await send("Runtime.enable");
  await send("Page.navigate", { url: URL_ });
  // wait for the board app to have rendered its top band
  const deadline = Date.now() + TIMEOUT;
  let ready = false;
  while (Date.now() < deadline) {
    try {
      ready = await evalJs(`!!document.getElementById("fileBtn")`);
    } catch (e) { ready = false; }
    if (ready) break;
    await new Promise(r => setTimeout(r, 200));
  }
  if (!ready) { console.error("board never painted a #fileBtn"); await shot("never-painted.png"); process.exit(1); }
  // let refresh()/render() settle
  await new Promise(r => setTimeout(r, 1500));

  const board = await evalJs(READ);
  await shot("board.png");
  const api = await evalJs(
    `fetch("/api/board").then(r=>r.json()).then(j=>JSON.stringify(j.meta||{}))`);
  const clicked = await evalJs(CLICK_FILE);
  await new Promise(r => setTimeout(r, 600));
  const overlay = await evalJs(OVERLAY);
  await shot("after-file-click.png");

  /* The `f` HOTKEY reaches openFile() directly, bypassing the disabled button —
     the path board.js's own comment says the modal exists for. */
  await evalJs(`(function(){ try{ if(typeof closeOverlay==="function") closeOverlay(); }catch(e){} try { if (typeof openFile === "function") { openFile(); return "called openFile()"; } } catch(e){ return "ERR "+e.message; } return "openFile not global"; })()`);
  await new Promise(r => setTimeout(r, 700));
  const hotkeyOverlay = await evalJs(OVERLAY);
  await shot("after-f-hotkey.png");

  /* And the HOLODECK control — does it actually refuse? */
  await evalJs(`(function(){ try{ if(typeof closeOverlay==="function") closeOverlay(); }catch(e){} var b=document.getElementById("holodeckBtn"); if(b) b.click(); return 1; })()`);
  await new Promise(r => setTimeout(r, 1200));
  const afterHolo = await evalJs(`(function(){
    var deck = document.querySelector(".holo, #holodeck, .deck, .holo-wrap");
    var b = document.getElementById("holodeckBtn");
    return { deckPresent: !!deck,
             holodeckBtnText: b ? (b.textContent||"").trim() : "",
             boardVisible: !!(document.getElementById("board") &&
                              getComputedStyle(document.getElementById("board")).display !== "none"),
             bodyText: (document.body.innerText||"").replace(/\s+/g," ").trim().slice(0,300) };
  })()`);
  await shot("after-holodeck-click.png");

  const out = { board, apiMeta: JSON.parse(api || "{}"), clicked, overlay,
                hotkeyOverlay, afterHolo };
  fs.writeFileSync(OUT + "/result.json", JSON.stringify(out, null, 2));
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
})().catch(e => { console.error("PROBE ERROR: " + e.message); process.exit(77); });
