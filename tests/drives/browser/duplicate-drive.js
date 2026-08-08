"use strict";
/* ══ S172 fix round 1 — ⧉ DUPLICATE, DRIVEN IN REAL HEADED CHROME ═══════════
 *
 * `duplicate.sh` owns the daemon, the planted sidecar and the Chrome process;
 * this file is the half that LOOKS. It uses the deck the way the captain does —
 * the band control, the program card's own ⧉ Duplicate button, the dialog's
 * ⧉ Duplicate Program button — and every verdict is read off a LAID-OUT BOX or
 * a RESOLVED style in that browser, never off markup.
 *
 * Raw CDP, zero dependencies (node's global WebSocket), the same mechanism
 * `cdp.js` uses. Grown from the S172 tester's own working driver rather than
 * reinvented: it is the rig that found D1 and D3 in the first place.
 *
 * WHY THIS EXISTS AT ALL. Two of the seven defects the tester found were
 * invisible to 33 new headless tests and 852 existing ones:
 *
 *   • D1 — every candidate room for a duplicate of a REAL-LENGTH program name
 *     collapsed onto the SOURCE room, so the blank-name road (the one the
 *     dialog itself recommends) could not copy anything at all. The headless
 *     suite used "Command palette" — 15 characters — everywhere, so nothing
 *     ever reached the 48-character cap where the differentiator falls off.
 *     The fixture here is the captain's ACTUAL program name and nothing
 *     shorter — 114 characters, verbatim out of his archive. Fix round 1 said
 *     that over a 51-character stand-in; it cleared the cap, so D1 was really
 *     exercised, but it painted a 43px lineage chip where his real name paints
 *     72px, which is what D3's check is READING.
 *   • D3 — the lineage chip was clipped to 14ch, so "⧉ from Tile editor" and
 *     "⧉ from Tile editor (copy)" both painted as "⧉ from Tile…": the same
 *     six characters for every possible parent. A rule that resolves perfectly
 *     and simply does not fit is exactly the class no node DOM harness can
 *     see, because none of them has any CSS or any layout.
 *
 * EXIT: 0 every check passed · 1 a check FAILED (the product) · 77 the rig
 *       could not drive (never the product's fault, never reported as one).
 */
const fs = require("fs");
const path = require("path");

const OUT = process.argv[2];
const ENV = JSON.parse(fs.readFileSync(path.join(OUT, "env.json"), "utf8"));
/* The room the fixture's SENT program lives in, and its full name. Passed in
   by the shell so the two halves cannot drift apart. */
const SRC_ROOM = ENV.srcRoom;
const SRC_NAME = ENV.srcName;

class CDP {
  constructor(ws) {
    this.ws = ws; this.next = 1; this.pending = new Map(); this.pageErrors = [];
    ws.addEventListener("message", (ev) => {
      let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        if (m.error) reject(new Error(JSON.stringify(m.error))); else resolve(m.result);
        return;
      }
      if (m.method === "Runtime.exceptionThrown") {
        const d = (m.params && m.params.exceptionDetails) || {};
        this.pageErrors.push(d.text + " " +
          ((d.exception && d.exception.description) || "").split("\n")[0]);
      } else if (m.method === "Log.entryAdded") {
        const e = (m.params && m.params.entry) || {};
        if (e.level === "error") this.pageErrors.push("[" + e.source + "] " + e.text);
      }
    });
  }
  send(method, params, sessionId) {
    const id = this.next++;
    const p = { id, method, params: params || {} };
    if (sessionId) p.sessionId = sessionId;
    this.ws.send(JSON.stringify(p));
    return new Promise((res, rej) => this.pending.set(id,
      { resolve: res, reject: (e) => rej(new Error(method + " → " + e.message)) }));
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const connect = (url) => new Promise((res, rej) => {
  const ws = new WebSocket(url);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused " + url)), { once: true });
});

const notes = [];
const say = (s) => { notes.push(s); console.log(s); };
/* Every check is recorded BY NAME, so `duplicate.sh` can judge a red control on
   the check it is supposed to break rather than on "the run was non-zero" —
   this rig's own history is six defects of the form "a control that proved
   nothing while reporting PASSED". */
const checks = [];
function check(id, ok, detail) {
  checks.push({ id: id, ok: !!ok, detail: detail });
  say((ok ? "  [32m✓[0m " : "  [31m✗[0m ") + id + " — " + detail);
  return !!ok;
}

(async () => {
  const ver = await (await fetch("http://127.0.0.1:" + ENV.devtools + "/json/version")).json();
  const ws = await connect(ver.webSocketDebuggerUrl);
  const cdp = new CDP(ws);
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  await cdp.send("Runtime.enable", {}, sessionId);
  await cdp.send("Log.enable", {}, sessionId);
  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Emulation.setDeviceMetricsOverride",
    { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false }, sessionId);

  const ev = async (expr) => {
    const r = await cdp.send("Runtime.evaluate",
      { expression: expr, returnByValue: true, awaitPromise: true }, sessionId);
    if (r.exceptionDetails) {
      throw new Error("page threw: " +
        JSON.stringify(r.exceptionDetails.exception || r.exceptionDetails));
    }
    return r.result && r.result.value;
  };
  const shot = async (name) => {
    const r = await cdp.send("Page.captureScreenshot", { format: "png" }, sessionId);
    fs.writeFileSync(path.join(OUT, name), Buffer.from(r.data, "base64"));
    say("  📷 " + path.join(OUT, name));
  };
  const waitFor = async (expr, ms, label) => {
    const dl = Date.now() + (ms || 15000);
    while (Date.now() < dl) {
      const v = await ev(expr);
      if (v) return v;
      await sleep(200);
    }
    say("  ⚠ TIMED OUT waiting for: " + label);
    return null;
  };

  /* ── the STYLESHEET PRECONDITION. A page served without board.css measures
     as a phantom: every box is wrong and every colour is the UA default, and a
     rig that reports "clipped"/"not clipped" off that is inventing. */
  await cdp.send("Page.navigate", { url: ENV.url }, sessionId);
  /* WAIT FOR THE REAL DOCUMENT, not for a node that is in the static HTML
     before a single byte of CSS or JS has arrived. `document.readyState` plus
     a JS-rendered board node is the earliest honest moment to measure. */
  if (!await waitFor(`document.readyState==="complete" &&
                      document.styleSheets.length>0`,
                     25000, "the page to finish loading")) {
    say("INFRASTRUCTURE — the page never finished loading.");
    return finish(77);
  }
  const styled = await ev(`(function(){
    var ds=getComputedStyle(document.documentElement);
    var bs=getComputedStyle(document.body);
    return {amber:(ds.getPropertyValue("--lcars-amber")||"").trim(),
            holo:(bs.getPropertyValue("--holo-grid")||"").trim(),
            cls:document.body.className,
            sheets:Array.prototype.slice.call(document.styleSheets)
              .map(function(s){return (s.href||"inline")+":"+
                (function(){try{return s.cssRules.length}catch(e){return "X"}})();})};})()`);
  say("stylesheet: --lcars-amber=" + (styled && styled.amber) +
      "  --holo-grid=" + (styled && styled.holo) +
      "  sheets=" + JSON.stringify((styled && styled.sheets) || []));
  if (!(styled && styled.amber && styled.holo)) {
    say("INCONCLUSIVE — the app was served without its stylesheet; the page "
        + "measured here is a phantom, so nothing is proven either way.");
    return finish(77);
  }

  /* ── onto the deck through the REAL band control ───────────────────────── */
  const onDeck = await ev(`(function(){var b=document.getElementById("holodeckBtn");
    if(!b||b.disabled) return false; b.click(); return true;})()`);
  if (!onDeck) { say("INFRASTRUCTURE — no usable ⬡ HOLODECK control."); return finish(77); }
  if (!await waitFor(`document.querySelectorAll(".prog").length>0`, 20000, "program rows")) {
    say("INFRASTRUCTURE — the program list never rendered.");
    return finish(77);
  }
  await sleep(700);
  await shot("01-deck.png");

  const ROWS = `(function(){
    function box(el){var r=el.getBoundingClientRect(),s=getComputedStyle(el);
      return {w:r.width,h:r.height,x:r.left,y:r.top,
              painted:r.width>0&&r.height>0&&s.display!=="none"&&
                      s.visibility!=="hidden"&&parseFloat(s.opacity||"1")>0.01,
              client:el.clientWidth,scroll:el.scrollWidth,
              clientH:el.clientHeight,scrollH:el.scrollHeight,
              /* BOTH DIRECTIONS: an ellipsis cuts sideways and a capped
                 height cuts downwards, and either one paints a parent name
                 the captain cannot read. */
              clipped:el.scrollWidth>el.clientWidth+0.5||
                      el.scrollHeight>el.clientHeight+0.5};}
    return Array.prototype.slice.call(document.querySelectorAll(".prog"))
      .map(function(n){
        var room=n.querySelector(".proom"); var dup=n.querySelector(".pdup");
        var stat=n.querySelector(".pstat");
        var d=Array.prototype.slice.call(n.querySelectorAll("[data-ctl]"))
          .filter(function(c){return /duplicate/i.test(c.getAttribute("data-ctl")||"");})[0];
        return {
          name:((n.querySelector(".pn")||{}).textContent||"").trim(),
          room:((room||{}).textContent||"").replace(/^⌂\\s*/,"").trim(),
          life:((stat||{}).textContent||"").trim(),
          /* NOT A CHECK — the numbers behind the fix-round-2 F4 judgement, so
             the next round argues from measurement instead of impression: how
             much of a card the lineage chip is, on a name of this length. */
          card:box(n), nameBox:n.querySelector(".pn")?box(n.querySelector(".pn")):null,
          dupBtn: d ? {label:d.getAttribute("data-ctl"), box:box(d),
                       hit:(function(){var r=d.getBoundingClientRect();
                         var t=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);
                         return !!(t&&(t===d||d.contains(t)||t.contains(d)));})()} : null,
          pdup: dup ? {text:dup.textContent, title:dup.title, box:box(dup)} : null
        };});})()`;

  const before = await ev(ROWS);
  fs.writeFileSync(path.join(OUT, "rows-before.json"), JSON.stringify(before, null, 2));
  const src = before.filter((r) => r.room === SRC_ROOM)[0];
  if (!src) {
    say("INFRASTRUCTURE — the planted SENT program (room " + SRC_ROOM +
        ") is not on the deck: " + JSON.stringify(before.map((r) => r.room)));
    return finish(77);
  }
  say("The planted program: " + JSON.stringify(src.name) + "  room " + src.room +
      "  lifecycle " + JSON.stringify(src.life));

  /* ── C1 — the control is ON THE LOCKED CARD, painted and reachable ─────── */
  check("DUP-CONTROL-ON-LOCKED-CARD",
        src.life === "sent" && !!src.dupBtn && src.dupBtn.box.painted && src.dupBtn.hit,
        src.dupBtn
          ? ("⧉ Duplicate on the " + src.life + " card: painted=" +
             src.dupBtn.box.painted + " hittable=" + src.dupBtn.hit + " " +
             Math.round(src.dupBtn.box.w) + "×" + Math.round(src.dupBtn.box.h))
          : ("NO ⧉ Duplicate control on the " + src.life + " card — the one "
             + "state the whole feature exists for"));

  /* ── the journey: duplicate the REAL-LENGTH program, twice, blank name ─── */
  async function duplicateOnce(label) {
    const clicked = await ev(`(function(){
      var rows=Array.prototype.slice.call(document.querySelectorAll(".prog"));
      var row=rows.filter(function(n){
        var r=n.querySelector(".proom");
        return r && r.textContent.replace(/^⌂\\s*/,"").trim()===${JSON.stringify(SRC_ROOM)};})[0];
      if(!row) return "no source row";
      var d=Array.prototype.slice.call(row.querySelectorAll("[data-ctl]"))
        .filter(function(c){return /duplicate/i.test(c.getAttribute("data-ctl")||"");})[0];
      if(!d) return "no ⧉ Duplicate control";
      d.click(); return "ok";})()`);
    if (clicked !== "ok") return { error: clicked };
    if (!await waitFor(`!!document.querySelector(".modal")`, 8000, "the dialog")) {
      return { error: "the dialog never opened" };
    }
    await sleep(300);
    if (label) await shot(label + "-dialog.png");
    /* THE BLANK-NAME ROAD — the one the dialog itself recommends, and the one
       that could not copy anything at all before this fix. Nothing is typed. */
    const went = await ev(`(function(){
      var go=Array.prototype.slice.call(document.querySelectorAll(".modal [data-ctl]"))
        .filter(function(n){return /duplicate program/i.test(n.getAttribute("data-ctl")||"");})[0];
      if(!go) return false; go.click(); return true;})()`);
    if (!went) return { error: "no ⧉ Duplicate Program button in the dialog" };
    await waitFor(`(function(){
        if(!document.querySelector(".modal")) return true;
        var e=document.querySelector(".modal .errline");
        return !!(e && !e.hidden && e.textContent.trim());})()`,
                  25000, "the dialog to close or refuse");
    await sleep(1500);
    return await ev(`(function(){
      var e=document.querySelector(".modal .errline");
      return {stillOpen:!!document.querySelector(".modal"),
              err:(e&&!e.hidden)?e.textContent.trim():null};})()`);
  }

  const first = await duplicateOnce("02");
  check("DUP-BLANK-NAME-WORKS",
        !first.error && !first.stillOpen && !first.err,
        first.error ? first.error
          : (first.err ? ("REFUSED on the road the dialog recommends: " + first.err)
             : "the blank-name road copied a real-length program name without refusing"));

  const second = await duplicateOnce(null);
  await sleep(800);
  await shot("03-after-two.png");

  const after = await ev(ROWS);
  fs.writeFileSync(path.join(OUT, "rows-after.json"), JSON.stringify(after, null, 2));
  const copies = after.filter((r) => r.room !== SRC_ROOM && r.pdup);
  const rooms = copies.map((r) => r.room);

  /* ── C2/C3 — TWO copies, TWO rooms, NEITHER of them the source's ───────── */
  check("DUP-TWO-DISTINCT-ROOMS",
        copies.length === 2 && rooms[0] !== rooms[1] &&
          rooms.indexOf(SRC_ROOM) === -1,
        "copies on the deck: " + JSON.stringify(rooms) +
          " (source " + SRC_ROOM + (second.err ? "; second refused: " + second.err : "") + ")");

  /* ── C8 — THE COPY CARRIES THE DESIGN (fix round 2) ───────────────────────
     The dialog's own promise is that a copy "carries the mockup, the concept
     doc, anything you pasted in". Nothing here looked: the round-2 tester
     dropped `mockup.html`, `concept.md` and `attachments/` from the copy road —
     the copied room held `basis.md` and `transcript.md` and nothing else — and
     this rig reported 7/7 green and exit 0. `DUP-BLANK-NAME-WORKS` asserts only
     that the dialog closed without an error, and no other check ever opened the
     room it made.

     Measured on DISK, in the sidecar the daemon really wrote, for the rooms the
     DECK says the copies are in. `handoff-changes.json` is the one file that
     must NOT travel (it is a derivation of the old draft against a repo that has
     since moved), so it is excluded here for the same reason the product
     excludes it. `transcript.md` and `basis.md` are compared for PRESENCE only:
     the copy road rewrites both on purpose (its own name and lineage; the
     inherited-grounding banner). Everything else must arrive byte for byte — a
     truncated mockup is a design that did not come over. */
  const SKIP = ["handoff-changes.json", "handoff-changes.json.tmp"];
  const REWRITTEN = ["transcript.md", "basis.md"];
  function roomFiles(room) {
    const base = path.join(ENV.sidecar, room);
    const out = {};
    (function walk(dir, rel) {
      let ents;
      try { ents = fs.readdirSync(dir, { withFileTypes: true }); }
      catch (e) { return; }
      for (const e of ents) {
        if (e.name.startsWith(".")) continue;      /* `.git` is not the program */
        const r = rel ? rel + "/" + e.name : e.name;
        if (SKIP.indexOf(r) !== -1) continue;
        if (e.isDirectory()) walk(path.join(dir, e.name), r);
        else if (e.isFile()) out[r] = fs.readFileSync(path.join(dir, e.name));
      }
    })(base, "");
    return out;
  }
  const srcFiles = roomFiles(SRC_ROOM);
  const carried = copies.map((r) => {
    const got = roomFiles(r.room);
    const missing = Object.keys(srcFiles).filter((f) => !(f in got));
    const differs = Object.keys(srcFiles).filter((f) =>
      f in got && REWRITTEN.indexOf(f) === -1 && !got[f].equals(srcFiles[f]));
    return { room: r.room, missing: missing, differs: differs,
             held: Object.keys(got).sort() };
  });
  check("COPY-CARRIES-THE-SOURCES-FILES",
        Object.keys(srcFiles).length > 0 && carried.length > 0 &&
          carried.every((c) => !c.missing.length && !c.differs.length),
        Object.keys(srcFiles).length === 0
          ? ("the SOURCE room " + SRC_ROOM + " has no files to carry — the "
             + "fixture is broken, nothing is proven")
          : (carried.length
             ? carried.map((c) => c.room + " holds " + JSON.stringify(c.held) +
                 (c.missing.length ? "; MISSING " + JSON.stringify(c.missing) : "") +
                 (c.differs.length ? "; DIFFERENT BYTES " + JSON.stringify(c.differs) : ""))
                 .join(" · ") + " (source: " + JSON.stringify(Object.keys(srcFiles).sort()) + ")"
             : "no copy on the deck to open"));

  /* ── C9 — NO TWO CARDS ON THE DECK READ THE SAME NAME (fix round 2) ───────
     The exact pair the daemon's 409 exists to prevent — "two cards with one
     name is a pair you cannot tell apart" — and the round-2 tester made three
     of them on one deck without this rig noticing. `SOURCE-STAYS-SENT`
     name-checks the SOURCE row and nothing has ever looked at a COPY's name.
     Read off the deck, because the deck is where a captain is choosing. */
  const deckNames = after.map((r) => r.name);
  const seen = {}, dupNames = [];
  deckNames.forEach((n) => {
    const k = (n || "").trim().toLowerCase();
    if (seen[k]) { if (dupNames.indexOf(n) === -1) dupNames.push(n); }
    seen[k] = true;
  });
  check("NO-TWO-CARDS-ONE-NAME",
        deckNames.length > 1 && deckNames.every((n) => (n || "").trim()) &&
          dupNames.length === 0,
        deckNames.length < 2
          ? ("only " + deckNames.length + " card on the deck — nothing to tell "
             + "apart, so nothing is proven")
          : (dupNames.length
             ? (dupNames.length + " name(s) on more than one card: " +
                JSON.stringify(dupNames))
             : deckNames.length + " cards, " + deckNames.length +
               " different names"));

  /* ── C4 — the ORIGINAL is untouched: still sent, still its mission ─────── */
  const stillSrc = after.filter((r) => r.room === SRC_ROOM)[0];
  check("SOURCE-STAYS-SENT",
        !!stillSrc && stillSrc.life === "sent" && stillSrc.name === SRC_NAME,
        stillSrc ? ("the filed program still reads " + JSON.stringify(stillSrc.life) +
                    " and is still called " + JSON.stringify(stillSrc.name))
                 : "the source program is GONE from the deck");

  /* ── C5 — THE LINEAGE CHIP IS READABLE (D3) ────────────────────────────────
     Measured, not asserted: `scrollWidth` against `clientWidth` on the live
     node, plus the rendered text against the parent's real name. A chip that
     paints "⧉ from Give…" for every possible parent answers the one question
     the program list exists to answer with the same six characters. */
  const chips = copies.map((r) => r.pdup).filter(Boolean);
  const readable = chips.length > 0 && chips.every((c) =>
    !c.box.clipped && c.box.painted && c.text.indexOf(SRC_NAME) !== -1);
  check("LINEAGE-CHIP-READABLE", readable,
        chips.length
          ? chips.map((c) => JSON.stringify(c.text) + " clipped=" + c.box.clipped +
              " " + Math.round(c.box.client) + "×" + Math.round(c.box.clientH) +
              "px shown / " + Math.round(c.box.scroll) + "×" +
              Math.round(c.box.scrollH) + "px needed").join(" · ")
          : "no ⧉ from chip on either copy");

  /* ── C6 — the duplicate's grounding chip says INHERITED, not "grounded in" */
  const clicked = await ev(`(function(){
    var rows=Array.prototype.slice.call(document.querySelectorAll(".prog"));
    var row=rows.filter(function(n){return !!n.querySelector(".pdup");})[0];
    if(!row) return false; row.click(); return true;})()`);
  let chip = null;
  if (clicked) {
    await waitFor(`!!document.querySelector(".ground-chip")`, 15000, "the grounding chip");
    await sleep(500);
    chip = await ev(`(function(){
      function read(sel){var c=document.querySelector(sel);
        if(!c) return null; var r=c.getBoundingClientRect(); var s=getComputedStyle(c);
        return {text:c.textContent, title:c.title,
                clipped:c.scrollWidth>c.clientWidth+0.5||
                        c.scrollHeight>c.clientHeight+0.5,
                painted:r.width>0&&r.height>0&&s.display!=="none"&&
                        s.visibility!=="hidden"&&parseFloat(s.opacity||"1")>0.01};}
      return {ground:read(".ground-chip"), cont:read(".cont-chip")};})()`);
  }
  await shot("04-duplicate-open.png");
  const ground = chip && chip.ground;
  const cont = chip && chip.cont;
  chip = ground;
  check("INHERITED-GROUNDING-SAID-ON-SCREEN",
        !!chip && chip.painted && /inherited/i.test(chip.text) && /stale/i.test(chip.text),
        chip ? ("the chip in the duplicate's chat header reads " +
                JSON.stringify(chip.text) + " painted=" + chip.painted)
             : "no grounding chip in the duplicate's chat header at all");

  /* ── C7 — whose CONVERSATION is in the pane. The duplicate opens holding the
     parent's whole chat, and the banner that said so is transient: one refresh
     later the header names this program and the turns under it are somebody
     else's, with nothing on screen joining them up. */
  check("CONTINUING-CHIP-ON-SCREEN",
        !!cont && cont.painted && !cont.clipped &&
          cont.text.indexOf(SRC_NAME) !== -1,
        cont ? ("the chat header reads " + JSON.stringify(cont.text) +
                " painted=" + cont.painted + " clipped=" + cont.clipped)
             : "nothing in the duplicate's chat header says whose conversation "
               + "the pane is holding");

  return finish(checks.every((c) => c.ok) ? 0 : 1);

  function finish(code) {
    if (cdp.pageErrors.length) {
      say("PAGE ERRORS:");
      cdp.pageErrors.forEach((e) => say("   ! " + e));
    }
    fs.writeFileSync(path.join(OUT, "duplicate-check.json"),
      JSON.stringify({ exit: code, checks: checks,
                       pageErrors: cdp.pageErrors }, null, 2));
    fs.writeFileSync(path.join(OUT, "drive-log.txt"), notes.join("\n") + "\n");
    try { ws.close(); } catch (e) { /* the run is over either way */ }
    process.exit(code);
  }
})().catch((e) => { console.error("DRIVER ERROR: " + e.stack); process.exit(77); });
