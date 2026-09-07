#!/usr/bin/env node
/* ==========================================================================
 * S192 CAPSTONE SHOT PROBE — photograph the whole day-zero loop in REAL
 * HEADED CHROME, and write beside every PNG the FACTUAL READOUT of what was
 * on screen when the shutter fired.
 *
 * Adapted from tests/drives/s184/shot-probe.js + live-probe.js. What is kept
 * verbatim in spirit: the SETTLE-PROPERLY discipline (a fixed sleep once read
 * a 58-mission board as BLANK while its footer still said "loading…" — the
 * exact false accusation against the product these rigs exist to prevent), and
 * the paired .json/.txt readout, which is what stops a screenshot from being
 * mistaken for a passing test.
 *
 * What is NEW: nothing is stubbed. s184 handed the front end a fabricated
 * recommendation turn to look at the layout. Here every turn on screen came
 * back from a REAL LIVE COPILOT worker.
 *
 * Usage:
 *   node shot-probe.js --devtools-port N --url URL --out DIR --phase P [opts]
 *     --phase front-door
 *     --phase grill   --idea TEXT --answers FILE [--turns N] [--turn-ms MS]
 *     --phase run     --mission ID [--budget SECS] [--every SECS]
 *     --phase verify  --mission ID
 *     --phase approve --mission ID
 *     --phase normal  --mission ID [--budget SECS] [--every SECS]
 * ========================================================================== */
const fs = require("fs");

function arg(n, d) {
  const i = process.argv.indexOf("--" + n);
  return i >= 0 && process.argv[i + 1] !== undefined ? process.argv[i + 1] : d;
}
const PORT = arg("devtools-port");
const URL_ = arg("url");
const OUT = arg("out", ".");
const PHASE = arg("phase", "front-door");
const MISSION = arg("mission", "");
const TURNS = parseInt(arg("turns", "10"), 10);
const TURN_MS = parseInt(arg("turn-ms", "600000"), 10);
const BUDGET_S = parseInt(arg("budget", "5400"), 10);
const EVERY_S = parseInt(arg("every", "45"), 10);
const IDEA = arg("idea", "");
const ANSWERS_FILE = arg("answers", "");
const ANSWERS = ANSWERS_FILE
  ? fs.readFileSync(ANSWERS_FILE, "utf8").split("\n").filter(s => s.trim())
  : [];
const SETTLE_MS = 30000;

/* ---------------------------------------------------------------------------
 * THE READOUT. Deliberately factual and deliberately BOTH surfaces: whether the
 * FRONT DOOR is up, and what the BOARD holds. Shot 01's whole claim is
 * "frontDoorVisible: true, visibleColumns: 0" — the board is not what renders.
 * ------------------------------------------------------------------------- */
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
  var fdBtns = [].slice.call(fd ? fd.querySelectorAll("button") : []);
  var fileBtn = document.getElementById("fileBtn");
  var fds = (typeof frontDoorState !== "undefined") ? frontDoorState : null;
  return JSON.stringify({
    url: location.href,
    title: document.title,
    frontDoorVisible: vis(fd),
    frontDoorScreen: fds ? fds.screen : null,
    frontDoorBusy: fds ? !!fds.busy : null,
    frontDoorSid: fds ? fds.sid : null,
    frontDoorError: fds ? (fds.error || "") : null,
    frontDoorQuestion: fds ? fds.question : null,
    frontDoorRecommendation: fds ? fds.rec : null,
    frontDoorButtons: fdBtns.map(function (b) {
      return { label: txt(b), disabled: !!b.disabled, visible: vis(b) };
    }),
    frontDoorText: txt(fd).slice(0, 2500),
    fileBtnPresent: !!fileBtn,
    fileBtnDisabled: fileBtn ? !!fileBtn.disabled : null,
    columnsInDom: cols.length,
    visibleColumns: cols.filter(vis).length,
    cardsInDom: cards.length,
    visibleCards: cards.filter(vis).length,
    cards: cards.filter(vis).map(function (c) {
      return {
        id: c.getAttribute("data-mid") || c.getAttribute("data-mission") || c.id || null,
        column: (function () {
          var p = c.closest(".col, .column, [data-stage]");
          return p ? (p.getAttribute("data-stage") || txt(p.querySelector(".col-h, .column-h, h2, h3"))) : null;
        })(),
        text: txt(c).slice(0, 600)
      };
    })
  }, null, 1);
})()`;

/* The authoritative server-side view, alongside the DOM view. Same origin, so
   the page can fetch it; a board that LOOKS empty and an API that says
   otherwise is exactly the disagreement worth catching. */
const BOARD_API = `fetch("/api/board").then(function (r) { return r.text(); })`;

function pad(n) { return String(n).padStart(2, "0"); }

/* The human-readable readout that sits beside each PNG. */
function readoutText(name, state, api) {
  const L = [];
  L.push("S192 SHOT READOUT — " + name);
  L.push("captured: " + new Date().toISOString());
  L.push("");
  L.push("FRONT DOOR");
  L.push("  visible:  " + state.frontDoorVisible);
  L.push("  screen:   " + state.frontDoorScreen);
  L.push("  busy:     " + state.frontDoorBusy);
  L.push("  session:  " + state.frontDoorSid);
  if (state.frontDoorError) L.push("  error:    " + state.frontDoorError);
  if (state.frontDoorQuestion) {
    const q = state.frontDoorQuestion;
    L.push("  question: " + (typeof q === "string" ? q : (q.text || JSON.stringify(q))));
    if (q && q.choices) q.choices.forEach(c => L.push("      · " + c));
  }
  if (state.frontDoorRecommendation) {
    const r = state.frontDoorRecommendation;
    L.push("  RECOMMENDATION (live, not stubbed)");
    L.push("      stack:    " + r.stack);
    (r.reasons || []).forEach(x => L.push("      because:  " + x));
    L.push("      slice:    " + r.slice);
    L.push("      deferred: " + (r.deferred || []).join(", "));
  }
  L.push("  buttons:  " + state.frontDoorButtons.map(b =>
    b.label + (b.disabled ? " [disabled]" : "")).join(" | "));
  L.push("");
  L.push("BOARD");
  L.push("  columns in DOM: " + state.columnsInDom + "   visible: " + state.visibleColumns);
  L.push("  cards in DOM:   " + state.cardsInDom + "   visible: " + state.visibleCards);
  L.push("  FILE MISSION button: " + (state.fileBtnPresent
    ? (state.fileBtnDisabled ? "present, DISABLED (foundation gate)" : "present, enabled")
    : "absent"));
  (state.cards || []).forEach(c => L.push("  · [" + (c.column || "?") + "] " + c.text));
  L.push("");
  L.push("VERDICT LINE");
  if (state.frontDoorVisible && state.visibleColumns === 0) {
    L.push("  THE BOARD IS NOT WHAT RENDERS — the day-zero front door has replaced it.");
  } else if (state.frontDoorVisible) {
    L.push("  front door visible, but " + state.visibleColumns + " board column(s) are ALSO visible.");
  } else {
    L.push("  the BOARD is what renders (" + state.visibleColumns + " columns, "
           + state.visibleCards + " cards); the front door is down.");
  }
  L.push("");
  L.push("FRONT DOOR TEXT, VERBATIM");
  L.push(state.frontDoorText || "  (none)");
  if (api) {
    L.push("");
    L.push("/api/board (server's own view, first 4000 chars)");
    L.push(api.slice(0, 4000));
  }
  return L.join("\n") + "\n";
}

(async () => {
  const list = await fetch("http://127.0.0.1:" + PORT + "/json/list").then(r => r.json());
  const page = list.find(t => t.type === "page" && t.webSocketDebuggerUrl);
  if (!page) { console.error("SKIP 77: no drivable page"); process.exit(77); }
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0; const waiters = new Map();
  const send = (method, params) => new Promise(res => {
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

  const evalJs = async (expr, awaitPromise) => {
    const r = await send("Runtime.evaluate",
      { expression: expr, returnByValue: true, awaitPromise: !!awaitPromise });
    if (r.result && r.result.exceptionDetails)
      throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 500));
    return r.result && r.result.result && r.result.result.value;
  };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const shot = async file => {
    const r = await send("Page.captureScreenshot",
      { format: "png", captureBeyondViewport: true });
    if (r.result && r.result.data) {
      fs.writeFileSync(OUT + "/" + file, Buffer.from(r.result.data, "base64"));
      console.log("shot: " + OUT + "/" + file);
      return true;
    }
    console.log("SHOT FAILED: " + file);
    return false;
  };
  const state = async () => JSON.parse(await evalJs(READ));
  const boardApi = async () => { try { return await evalJs(BOARD_API, true); } catch (e) { return ""; } };

  /* One capture = PNG + machine readout + human readout. */
  const capture = async name => {
    const s = await state();
    let api = "";
    try { api = await boardApi(); } catch (e) { api = ""; }
    fs.writeFileSync(OUT + "/" + name + ".json", JSON.stringify(s, null, 1));
    fs.writeFileSync(OUT + "/" + name + ".txt", readoutText(name, s, api));
    await shot(name + ".png");
    console.log("  " + name + ": frontDoor=" + s.frontDoorVisible
      + " screen=" + s.frontDoorScreen
      + " visibleColumns=" + s.visibleColumns
      + " visibleCards=" + s.visibleCards);
    return s;
  };

  const typeText = async t => evalJs(
    `(function(){var b=document.querySelector("#frontDoor textarea, #frontDoor input.fd-field");`
    + `if(!b)return "NO FIELD";b.value=${JSON.stringify(t)};`
    + `b.dispatchEvent(new Event("input",{bubbles:true}));return "typed";})()`);
  const clickFd = async label => evalJs(
    `(function(){var bs=[].slice.call(document.querySelectorAll("#frontDoor button"));`
    + `var b=bs.filter(function(x){return (x.textContent||"").indexOf(${JSON.stringify(label)})>=0;})[0];`
    + `if(!b)return "NO BUTTON: "+bs.map(function(x){return (x.textContent||"").trim();}).join(" | ");`
    + `b.click();return "clicked";})()`);
  /* The board's own "▶ Start" on a named mission's card — the captain's path,
     which dispatches `run.sh drive --mission <id>` (the STAGE driver). */
  const clickStart = async mid => evalJs(
    `(function(){
       var mid=${JSON.stringify(mid)};
       var cards=[].slice.call(document.querySelectorAll(".card"));
       /* S192 fix, measured: the board stamps the mission id as data-mid
          (board.js:1154), NOT data-mission, and the id never appears in the
          card's visible text — so all three original selectors missed a card
          that was plainly on screen with a working Start button. The old
          attributes stay as fallbacks; the single-card fallback goes last so a
          one-mission board is still drivable if the attribute is renamed. */
       var card=cards.filter(function(c){
         return (c.getAttribute("data-mid")===mid)
             || (c.getAttribute("data-mission")===mid) || (c.id===mid)
             || ((c.textContent||"").indexOf(mid)>=0); })[0];
       if(!card && cards.length===1) card=cards[0];
       if(!card) return "NO CARD for "+mid+" (cards: "+cards.length+")";
       var bs=[].slice.call(card.querySelectorAll("button"));
       /* The board's own action hook first (board.js data-act="start"); the
          label match stays as the fallback. */
       var b=card.querySelector('[data-act="start"]')
             || bs.filter(function(x){return /Start/.test(x.textContent||"");})[0];
       if(!b) return "NO START BUTTON (buttons: "+bs.map(function(x){return (x.textContent||"").trim();}).join(" | ")+")";
       b.click(); return "clicked Start";
     })()`);
  const missionApi = async mid => {
    try {
      return JSON.parse(await evalJs(
        `fetch("/api/mission/" + ${JSON.stringify(mid)}).then(function(r){return r.text();})`, true));
    } catch (e) { return null; }
  };

  await send("Page.enable");
  await send("Runtime.enable");
  await send("Page.navigate", { url: URL_ });

  /* BOOT, then SETTLE — never a fixed sleep before the app has committed to a
     surface. Either surface counts as booted. */
  const bootBy = Date.now() + SETTLE_MS;
  let booted = false;
  while (Date.now() < bootBy) {
    try {
      booted = await evalJs(
        `!!document.getElementById("fileBtn") || `
        + `(function(){var f=document.getElementById("frontDoor");return !!f && !f.hidden;})()`);
    } catch (e) { booted = false; }
    if (booted) break;
    await sleep(200);
  }
  if (!booted) {
    console.error("FAIL: the app never painted either surface");
    await shot("00-never-painted.png");
    process.exit(1);
  }
  const settleBy = Date.now() + SETTLE_MS;
  while (Date.now() < settleBy) {
    const settled = await evalJs(
      `(function(){var f=document.getElementById("frontDoor");`
      + `if(f&&!f.hidden)return true;`
      + `return document.querySelectorAll(".col, .column, [data-stage]").length>0;})()`);
    if (settled) break;
    await sleep(250);
  }
  await sleep(1200);

  /* ===================== PHASES ========================================= */
  if (PHASE === "front-door") {
    const s = await capture("01-front-door");
    if (!s.frontDoorVisible) { console.log("READOUT SAYS: the front door is NOT up."); process.exit(1); }
    if (s.visibleColumns > 0) { console.log("READOUT SAYS: board columns are visible too."); process.exit(1); }
    console.log("READOUT SAYS: the board is NOT what renders — the day-zero door replaced it.");
    process.exit(0);
  }

  if (PHASE === "grill") {
    /* 02..NN — the live grill, one shot per turn as the model asks. */
    await capture("02-grill-00-idea-empty");
    console.log("TYPE IDEA: " + IDEA);
    console.log(await typeText(IDEA));
    await sleep(300);
    await capture("02-grill-00-idea-typed");
    console.log(await clickFd("Establish"));

    const journal = [];
    let reached = false;
    for (let turn = 1; turn <= TURNS; turn++) {
      const t0 = Date.now();
      let s = await state();
      /* Wait out the LIVE turn. Copilot can take minutes and can hang; the
         bash wrapper owns the kill, this owns the give-up. */
      while (s.frontDoorBusy && Date.now() - t0 < TURN_MS) {
        await sleep(3000);
        s = await state();
      }
      const secs = Math.round((Date.now() - t0) / 1000);
      const name = (s.frontDoorScreen === "recommend")
        ? "20-recommendation"
        : "02-grill-turn-" + pad(turn);
      const shotState = await capture(name);
      journal.push({
        turn, secs, screen: shotState.frontDoorScreen,
        sid: shotState.frontDoorSid, busy: shotState.frontDoorBusy,
        error: shotState.frontDoorError,
        question: shotState.frontDoorQuestion,
        rec: shotState.frontDoorRecommendation
      });
      fs.writeFileSync(OUT + "/grill-journal.json", JSON.stringify(journal, null, 1));
      console.log("turn " + turn + " · " + secs + "s · screen=" + shotState.frontDoorScreen
                  + " · sid=" + shotState.frontDoorSid);
      if (shotState.frontDoorError) { console.log("STOPPED: front-door error"); break; }
      if (shotState.frontDoorScreen === "recommend") { reached = true; break; }
      if (shotState.frontDoorBusy) { console.log("STOPPED: turn still busy after " + secs + "s (HANG)"); break; }
      const a = ANSWERS[(turn - 1) % ANSWERS.length] || "Whatever you recommend is fine — go.";
      console.log("ANSWER " + turn + ": " + a);
      console.log(await typeText(a));
      console.log(await clickFd("Continue"));
      await sleep(1500);
    }
    if (!reached) {
      console.log("NEVER REACHED THE RECOMMENDATION in " + TURNS + " turns");
      process.exit(1);
    }
    /* 30 — ACCEPT. The mission is filed and the door drops on its own. */
    console.log("ACCEPT: " + await clickFd("Accept"));
    const acceptBy = Date.now() + TURN_MS;
    while (Date.now() < acceptBy) {
      const s = await state();
      if (!s.frontDoorVisible && s.visibleColumns > 0) break;
      if (s.frontDoorError) break;
      await sleep(2000);
    }
    await sleep(2500);
    const s2 = await capture("30-board-after-accept");
    process.exit(s2.visibleCards > 0 ? 0 : 1);
  }

  if (PHASE === "run" || PHASE === "normal") {
    const prefix = PHASE === "run" ? "40-run" : "71-normal-run";
    if (!MISSION) { await capture(PHASE === "run" ? "40-run-00" : "70-normal-filed"); process.exit(1); }
    if (PHASE === "normal") await capture("70-normal-filed");
    console.log("START: " + await clickStart(MISSION));
    const deadline = Date.now() + BUDGET_S * 1000;
    let n = 0, lastStage = "";
    while (Date.now() < deadline) {
      n += 1;
      const s = await capture(prefix + "-" + pad(n));
      const m = await missionApi(MISSION);
      const stage = m && (m.mission ? m.mission.stage : m.stage);
      if (stage) {
        fs.appendFileSync(OUT + "/" + prefix + "-stages.log",
          new Date().toISOString() + "\t" + pad(n) + "\t" + stage + "\n");
        if (stage !== lastStage) { console.log("  stage → " + stage); lastStage = stage; }
        if (stage === "verify" || stage === "done") { console.log("REACHED " + stage); break; }
      }
      const awaiting = /"awaitingHuman":\s*true/.test(JSON.stringify(m || {}));
      if (awaiting) { console.log("STOPPED: mission is awaiting a human"); break; }
      await sleep(EVERY_S * 1000);
    }
    await capture(prefix + "-final");
    process.exit(0);
  }

  if (PHASE === "verify") {
    const s = await capture("50-verify");
    process.exit(s.visibleCards > 0 ? 0 : 1);
  }

  if (PHASE === "approve") {
    const s = await capture("60-approved-unlocked");
    console.log("FILE MISSION button: " + (s.fileBtnPresent
      ? (s.fileBtnDisabled ? "still DISABLED (repo did NOT unlock)" : "ENABLED — the repo is unlocked")
      : "absent"));
    process.exit(0);
  }

  console.error("unknown phase: " + PHASE);
  process.exit(2);
})().catch(e => { console.error("SKIP 77: probe crashed: " + e.message); process.exit(77); });
