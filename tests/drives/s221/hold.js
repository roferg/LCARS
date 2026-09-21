#!/usr/bin/env node
/* ═══════════════════════════════════════════════════════════════════════════
 * S221 fix 5 — DOES `{"press":…,"hold":MS}` ACTUALLY WALK A CHARACTER?
 *
 *   node hold.js --devtools-port N --url URL --out DIR [--hold 250] [--drive PATH]
 *
 * WHY THIS AND NOT A UNIT TEST. The defect being fixed is that a perfectly
 * well-formed key event DID NOTHING. A test that asserts the CDP payload would
 * have passed on the broken code, because the payload was never the problem —
 * the absence of wall-clock time between the down and the up was. So nothing
 * here inspects a payload. It runs the REAL `skills/lcars-xo/xo-drive.js`
 * against a REAL game that moves its character at a steady speed while a key
 * is held, and MEASURES how far the character actually travelled.
 *
 * AND IT MEASURES THE CONTROL. One run taps (no `hold`), one run holds. The
 * finding is the CONTRAST: a tap barely twitches, a hold walks a whole tile.
 * A number with nothing to compare it against would not have caught this.
 *
 * HOW THE POSITION IS READ. The game draws to a canvas and puts nothing on
 * `window`, so the player's position comes off the live Pixi scene graph. Pixi
 * v8 calls `globalThis.__PIXI_APP_INIT__` right after `Application.init` — the
 * one handle the app gives us — and that hook has to be installed BEFORE any
 * page script runs. xo-drive.js opens its own tab, so this rig cannot simply
 * install it on a tab of its own: it turns on browser-level auto-attach with
 * `waitForDebuggerOnStart`, so every new tab is frozen before it executes
 * anything, installs the hook, and releases it. Deterministic — no race with
 * the driver's own navigate.
 *
 * (The probe and the scene-graph arithmetic are inherited verbatim from the
 * S221 control rig, which established them against this same build.)
 *
 * Prints one JSON object with a `checks` list; exit 0 only when every check is
 * ok. Screenshots land in DIR (gitignored).
 * ═══════════════════════════════════════════════════════════════════════════ */
"use strict";
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port");
const URL_ = arg("url");
const OUT = arg("out", ".");
const HOLD_MS = Number(arg("hold", "250"));
const DRIVE = arg("drive", path.join(__dirname, "..", "..", "..", "skills", "lcars-xo", "xo-drive.js"));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

/* ── the live Pixi scene graph, read from inside the page ──────────────────
 * playerX = sprite.x + camX, playerY = sprite.y + camY, and camX/camY are
 * constant because the 640px map is smaller than the viewport so the camera is
 * pinned. Cross-checked against playerContainer.zIndex - 1 - tileSize.  */
const PROBE = `(function () {
  var app = globalThis.__S221_APP;
  if (!app) return { err: "no pixi app", hook: typeof globalThis.__PIXI_APP_INIT__,
                     href: String(location.href), ready: document.readyState };
  var stage = app.stage;
  var combined = stage.children.filter(function (c) { return c.sortableChildren === true; })[0];
  if (!combined) return { err: "no combined container" };
  var pc = combined.children.filter(function (c) { return c.texture === undefined && c.children && c.children.length > 0; })[0];
  if (!pc) return { err: "no player container" };
  var spr = pc.children[0];
  var MAP = 640, TILE = 32;
  var sw = app.screen.width, sh = app.screen.height;
  var camX = MAP < sw ? (MAP - sw) / 2 : null;
  var camY = MAP < sh ? (MAP - sh) / 2 : null;
  if (camX === null || camY === null) return { err: "viewport smaller than the map — the camera is not pinned" };
  var px = spr.x + camX, py = spr.y + camY;
  return {
    playerX: px, playerY: py, spriteVisible: spr.visible, zIndex: pc.zIndex,
    screenW: sw, screenH: sh,
    yFromZIndex: pc.zIndex - 1 - TILE,
    tileCol: Math.floor((px + TILE / 2) / TILE),
    tileRow: Math.floor((py + TILE / 2) / TILE),
    hasTexture: !!(spr.texture && spr.texture.source && spr.texture.source.width > 0)
  };
})()`;

const HOOK = "globalThis.__PIXI_APP_INIT__ = function (a) { globalThis.__S221_APP = a; };";

class CDP {
  constructor(ws) {
    this.ws = ws; this.next = 1; this.pending = new Map(); this.sessions = new Set();
    this.targets = new Map();   // sessionId -> targetId, so a finished run's tab can be closed
    ws.addEventListener("message", (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) {
        const p = this.pending.get(m.id); this.pending.delete(m.id);
        return m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result);
      }
      if (m.method === "Target.attachedToTarget") this.onAttach(m.params);
    });
  }
  send(method, params, sid) {
    const id = this.next++; const pl = { id, method, params: params || {} };
    if (sid) pl.sessionId = sid; this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej }));
  }
  /* Every new tab arrives here FROZEN (waitForDebuggerOnStart). Install the
   * Pixi hook, then let it run. Order matters and this is the only ordering
   * that is guaranteed rather than lucky. */
  async onAttach(p) {
    const sid = p.sessionId;
    if (p.targetInfo && p.targetInfo.type !== "page") {
      try { await this.send("Runtime.runIfWaitingForDebugger", {}, sid); } catch (_) {}
      return;
    }
    try {
      await this.send("Page.enable", {}, sid);
      await this.send("Runtime.enable", {}, sid);
      await this.send("Page.addScriptToEvaluateOnNewDocument", { source: HOOK }, sid);
      this.sessions.add(sid);
      this.targets.set(sid, p.targetInfo.targetId);
    } catch (_) {}
    try { await this.send("Runtime.runIfWaitingForDebugger", {}, sid); } catch (_) {}
  }
  async probeAny() {
    this.lastRaw = { sessions: this.sessions.size, values: [] };
    for (const sid of this.sessions) {
      try {
        const r = await this.send("Runtime.evaluate",
          { expression: PROBE, returnByValue: true }, sid);
        const v = r && r.result ? r.result.value : null;
        this.lastRaw.values.push(v);
        if (v && !v.err && v.spriteVisible && v.hasTexture && v.zIndex > 0) return v;
      } catch (e) { this.lastRaw.values.push("threw: " + e.message.slice(0, 120)); }
    }
    return null;
  }
}
/* ONE GAME TAB AT A TIME, and this is not tidiness (S221). Measured: the run
 * that happens FIRST in a browser walks correctly and every run after it moves
 * ZERO pixels — a tab that is no longer the active one has its requestAnimationFrame
 * throttled to nothing, the game loop stops, and a key held for 250ms is held
 * across no frames at all. It looks exactly like a dead key and it is a
 * property of the RIG, not of the driver: the first run proves the driver, and
 * leaving the previous tab open was quietly breaking the second measurement.
 * So each run's tab is closed before the next one opens. */
async function closeRunTabs(cdp, keep) {
  for (const [sid, tid] of Array.from(cdp.targets.entries())) {
    if (keep.has(tid)) continue;
    try { await cdp.send("Target.closeTarget", { targetId: tid }); } catch (_) {}
    cdp.targets.delete(sid); cdp.sessions.delete(sid);
  }
}

const connect = (u) => new Promise((res, rej) => {
  const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused " + u)), { once: true });
});

/* Run the REAL driver with an action list, polling the scene graph throughout.
 * The first reading taken while the game is ready is the BEFORE; the last one
 * that came back is the AFTER. Nothing else in this app moves the character,
 * so the difference is what the action list did. */
async function drive(cdp, label, actions) {
  const dir = path.join(OUT, label);
  fs.mkdirSync(dir, { recursive: true });
  const af = path.join(dir, "actions.json");
  fs.writeFileSync(af, JSON.stringify(actions, null, 1));

  const child = spawn(process.execPath,
    [DRIVE, "--url", URL_, "--out", dir, "--actions", af,
     "--devtools-port", String(PORT), "--walk-out", path.join(dir, "walk.json")],
    { stdio: ["ignore", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.on("data", (b) => { stdout += b; });
  child.stderr.on("data", (b) => { stderr += b; });

  let before = null, last = null;
  const done = new Promise((res) => child.on("exit", (c) => res(c)));
  let running = true;
  done.then(() => { running = false; });
  while (running) {
    const v = await cdp.probeAny();
    if (v) { if (!before) before = v; last = v; }
    await sleep(40);
  }
  // One last reading after the driver has finished with the tab.
  const post = await cdp.probeAny();
  if (post) last = post;
  const rc = await done;

  let walk = null;
  try { walk = JSON.parse(fs.readFileSync(path.join(dir, "walk.json"), "utf8")); } catch (_) {}
  return {
    label, exit: rc, before, after: last, walk, probeRaw: cdp.lastRaw,
    dx: before && last ? Math.round((last.playerX - before.playerX) * 100) / 100 : null,
    dy: before && last ? Math.round((last.playerY - before.playerY) * 100) / 100 : null,
    stdoutTail: stdout.slice(-400), stderrTail: stderr.slice(-400),
  };
}

const out = { hold: HOLD_MS, runs: {}, checks: [] };
function check(name, ok, detail) { out.checks.push({ name, ok: !!ok, detail: detail === undefined ? null : detail }); }

(async () => {
  let ver = null;
  for (let i = 0; i < 300 && !ver; i++) {
    try { const r = await fetch("http://127.0.0.1:" + PORT + "/json/version"); if (r.ok) ver = await r.json(); } catch (_) {}
    if (!ver) await sleep(100);
  }
  if (!ver) throw new Error("no devtools on " + PORT);
  out.chrome = ver.Browser;
  const cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  // Every tab this browser opens from now on is frozen at birth until the hook
  // is in. xo-drive.js opens its tab AFTER this, which is the whole point.
  await cdp.send("Target.setAutoAttach",
    { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });

  /* THE TWO RUNS. Identical but for one key: `hold`. The walk is EAST along
   * clean ground (cols 2-9, rows 2-17 are clear; the column-10 tile is a map
   * link and the south-east corner has a chest and oak trees — a first pass
   * that drove that way looked like a broken control and was furniture). */
  const tapList = [
    { wait: 1200 },
    { screenshot: "before" },
    { press: "ArrowRight" },
    { wait: 600 },
    { screenshot: "after" },
  ];
  const holdList = [
    { wait: 1200 },
    { screenshot: "before" },
    { press: "ArrowRight", hold: HOLD_MS },
    { wait: 600 },
    { screenshot: "after" },
  ];

  // Whatever tabs the browser opened for itself are not this rig's to close.
  await sleep(400);
  const preexisting = new Set(cdp.targets.values());

  out.runs.hold = await drive(cdp, "hold", holdList);
  await closeRunTabs(cdp, preexisting);
  out.runs.tap = await drive(cdp, "tap", tapList);
  await closeRunTabs(cdp, preexisting);

  const tap = out.runs.tap, hold = out.runs.hold;
  check("the rig read the player position in both runs",
    tap.before && tap.after && hold.before && hold.after,
    { tapBefore: tap.before && tap.before.playerX, holdBefore: hold.before && hold.before.playerX });
  // A TAP BARELY MOVES IT. This is the defect, measured: one frame of walking.
  check("CONTROL — a tap moves the character less than a quarter of a tile",
    tap.dx !== null && Math.abs(tap.dx) < 8, { dx: tap.dx, dy: tap.dy });
  // A HOLD WALKS IT. 128px/s * 0.25s = 32px = one tile; one extra 60fps frame
  // can land while the keyUp is in flight, so allow a little over.
  const want = 128 * (HOLD_MS / 1000);
  check("a " + HOLD_MS + "ms hold walks the character a whole tile",
    hold.dx !== null && hold.dx >= want * 0.9 && hold.dx <= want * 1.25,
    { dx: hold.dx, expected: want, pctOfExpected: hold.dx === null ? null : Math.round((hold.dx / want) * 100) });
  check("it walked STRAIGHT — no drift on the other axis",
    hold.dy !== null && Math.abs(hold.dy) < 1, { dy: hold.dy });
  check("THE CONTRAST — the hold moved it at least 8x further than the tap",
    tap.dx !== null && hold.dx !== null && Math.abs(hold.dx) >= Math.abs(tap.dx) * 8,
    { tapPx: tap.dx, holdPx: hold.dx });
  // The RECORD has to show it was held, or the captain's report cannot tell a
  // walk from a twitch.
  const acts = (hold.walk && hold.walk.actions) || [];
  const held = acts.filter((a) => a.press && a.holdMs === HOLD_MS);
  check("the walk record says the key was HELD, and for how long",
    held.length === 1, acts);
  const tapActs = (tap.walk && tap.walk.actions) || [];
  check("…and a tap records no hold at all (the old shape is unchanged)",
    tapActs.length === 1 && tapActs[0].press === "ArrowRight" && tapActs[0].holdMs === undefined, tapActs);
  check("the keypress counter still counts it",
    hold.walk && hold.walk.moves && hold.walk.moves.keypresses === 1,
    hold.walk && hold.walk.moves);

  console.log(JSON.stringify(out, null, 2));
  process.exit(out.checks.every((c) => c.ok) ? 0 : 1);
})().catch((e) => {
  console.log(JSON.stringify({ error: String(e && e.stack || e), out }, null, 2));
  process.exit(2);
});
