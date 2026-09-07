#!/usr/bin/env node
/* S184 SHOT PROBE — screenshot the day-zero front door in REAL headed Chrome.
 *
 * Drives the SHIPPING front end against a REAL daemon on a REAL repo. Its whole
 * job is to produce PNGs a human looks at, plus a small factual readout of what
 * was on screen, so a screenshot can never be mistaken for a passing test.
 *
 * Screen 3 (the recommendation) is reached by handing the front end a
 * recommendation turn — the RENDERER, CSS and layout are real; the recommendation
 * DATA is stubbed, and the readout says so. A live grill shapes that data for
 * real in the tester leg; this rig is for looking at the shape.
 *
 * Usage: node shot-probe.js --devtools-port N --url URL --out DIR [--stub-rec]
 */
const fs = require("fs");
function arg(n, d) { const i = process.argv.indexOf("--" + n);
  return i >= 0 && process.argv[i + 1] ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL_ = arg("url"), OUT = arg("out", ".");
const STUB_REC = process.argv.indexOf("--stub-rec") >= 0;
const TIMEOUT = 30000;

/* What is actually on screen — the front door, the board, or neither. */
const READ = `(function () {
  function vis(el) {
    if (!el) return false;
    if (el.hidden) return false;
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var s = getComputedStyle(el);
    return s.display !== "none" && s.visibility !== "hidden";
  }
  function txt(el) { return el ? (el.textContent || "").replace(/[ \\t\\r\\n]+/g, " ").trim() : ""; }
  var fd = document.getElementById("frontDoor");
  var cols = [].slice.call(document.querySelectorAll(".col, .column, [data-stage]"));
  var cards = [].slice.call(document.querySelectorAll(".card"));
  var btns = [].slice.call(fd ? fd.querySelectorAll("button") : []);
  var fileBtn = document.getElementById("fileBtn");
  return JSON.stringify({
    frontDoorVisible: vis(fd),
    bodyClass: document.body.className,
    columnsInDom: cols.length,
    visibleColumns: cols.filter(vis).length,
    cardsInDom: cards.length,
    visibleCards: cards.filter(vis).length,
    fileBtnPresent: !!fileBtn,
    fileBtnDisabled: fileBtn ? !!fileBtn.disabled : null,
    frontDoorButtons: btns.map(function (b) {
      return { label: txt(b), disabled: !!b.disabled, visible: vis(b) };
    }),
    frontDoorText: txt(fd).slice(0, 1400)
  }, null, 1);
})()`;

/* A GRILL TURN, IN THE DAEMON'S OWN SHAPE (fix round 2). Every key here is
   copied from `actions.py::_align_turn`'s question return — `sessionId`, not
   `sid`; `question` an OBJECT, not a string; `choices` present, because the
   live model returned them on most measured turns. Fed through the client's
   own `frontDoorTurn`, so the screen it produces is the screen a real turn
   produces. */
const STUB_Q = `(function () {
  try {
    frontDoorState.idea = "a website that does personal finance stuff";
    frontDoorTurn({
      sessionId: "9f2c41ab77de",
      status: "question",
      question: {
        text: "Let\u2019s pin down what this actually is before we talk stack \u2014 my read is a budget/expense tracker: you log transactions, sort them into categories, and see where your money goes. Does that match what\u2019s in your head?",
        choices: ["Budget/expense tracker (log & categorize spending)",
                  "Investment / portfolio tracking",
                  "Bill reminders & recurring payments",
                  "Something else"],
        recommended: "Budget/expense tracker (log & categorize spending)"
      },
      prd: "# Mission: Establish foundation\\n\\n**Type:** feature\\n"
    });
    return "sid=" + frontDoorState.sid + " screen=" + frontDoorState.screen;
  } catch (e) { return "ERR " + e.message; }
})()`;

/* Click the override affordance the way the captain does. */
const CLICK_OVERRIDE = `(function () {
  var fd = document.getElementById("frontDoor");
  var b = [].slice.call(fd ? fd.querySelectorAll("button") : [])
            .filter(function (n) { return /different stack/.test(n.textContent || ""); })[0];
  if (!b) return "NO OVERRIDE BUTTON";
  b.click();
  return "clicked";
})()`;

/* Hand the front end a recommendation turn through its own entry point. */
const STUB = `(function () {
  var rec = {
    stack: "Vite + React + Vitest",
    stackId: "js",
    reasons: [
      "You said \\u201Cwebsite with charts\\u201D \\u2014 React has the chart libraries, and you have used it before in two repos on this machine.",
      "Vitest runs your tests in about a second, so the red-then-green proof on every ticket stays fast instead of becoming the slow part.",
      "CSV import is a pure function \\u2014 the easiest thing in your idea to write a real first test against."
    ],
    slice: "A running app, a working test system, and one thin slice that proves both \\u2014 importing a CSV row and showing it.",
    deferred: ["Budgets", "charts", "bank import"]
  };
  try {
    if (typeof frontDoorTurn === "function") { frontDoorTurn({ recommendation: rec }); return "frontDoorTurn"; }
    if (typeof renderFrontDoorRecommendation === "function") { renderFrontDoorRecommendation(rec); return "renderFrontDoorRecommendation"; }
  } catch (e) { return "ERR " + e.message; }
  return "NO ENTRY POINT";
})()`;

(async () => {
  const list = await fetch("http://127.0.0.1:" + PORT + "/json/list").then(r => r.json());
  const page = list.find(t => t.type === "page" && t.webSocketDebuggerUrl);
  if (!page) { console.error("SKIP 77: no drivable page"); process.exit(77); }
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
    const r = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: true });
    if (r.result && r.result.data) {
      fs.writeFileSync(OUT + "/" + name, Buffer.from(r.result.data, "base64"));
      console.log("shot: " + OUT + "/" + name);
    }
  };

  await send("Page.enable");
  await send("Runtime.enable");
  await send("Page.navigate", { url: URL_ });

  /* Wait for the APP to have booted — either surface counts as booted. */
  const deadline = Date.now() + TIMEOUT;
  let booted = false;
  while (Date.now() < deadline) {
    try {
      booted = await evalJs(
        `!!document.getElementById("fileBtn") || ` +
        `(function(){var f=document.getElementById("frontDoor");return !!f && !f.hidden;})()`);
    } catch (e) { booted = false; }
    if (booted) break;
    await new Promise(r => setTimeout(r, 200));
  }
  if (!booted) {
    console.error("FAIL: the app never painted either surface");
    await shot("never-painted.png");
    process.exit(1);
  }
  /* SETTLE PROPERLY, don't guess. A fixed sleep read a 58-mission board as
     BLANK (its footer still said "loading…") — exactly the false accusation
     against the product this rig exists to prevent. Wait until the app has
     committed to a surface: the front door is up, or the board has columns. */
  const settleBy = Date.now() + TIMEOUT;
  while (Date.now() < settleBy) {
    const settled = await evalJs(
      `(function(){` +
      `  var f = document.getElementById("frontDoor");` +
      `  if (f && !f.hidden) return true;` +
      `  if (document.querySelectorAll(".col, .column, [data-stage]").length) return true;` +
      `  return false;` +
      `})()`);
    if (settled) break;
    await new Promise(r => setTimeout(r, 250));
  }
  await new Promise(r => setTimeout(r, 1200));

  const state = await evalJs(READ);
  fs.writeFileSync(OUT + "/state.json", state);
  console.log(state);
  await shot("screen.png");

  if (STUB_REC) {
    /* THE GRILL SCREEN FIRST — the one the captain saw `[object Object]` on. */
    const q = await evalJs(STUB_Q);
    console.log("stub grill turn: " + q);
    await new Promise(r => setTimeout(r, 700));
    const qstate = await evalJs(READ);
    fs.writeFileSync(OUT + "/state-grill.json", qstate);
    console.log(qstate);
    await shot("screen-grill.png");

    const how = await evalJs(STUB);
    console.log("stub recommendation via: " + how);
    await new Promise(r => setTimeout(r, 900));
    const rstate = await evalJs(READ);
    fs.writeFileSync(OUT + "/state-recommendation.json", rstate);
    console.log(rstate);
    await shot("screen-recommendation.png");

    /* …and the OVERRIDE screen, whose one-line input wore the textarea's box. */
    console.log("override: " + await evalJs(CLICK_OVERRIDE));
    await new Promise(r => setTimeout(r, 700));
    const ostate = await evalJs(READ);
    fs.writeFileSync(OUT + "/state-override.json", ostate);
    console.log(ostate);
    await shot("screen-override.png");
  }
  process.exit(0);
})().catch(e => { console.error("SKIP 77: probe crashed: " + e.message); process.exit(77); });
