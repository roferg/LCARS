"use strict";
/* S161 Mission-Log SESSION console harness — loads the SHIPPING web/static/board.js
 * in a sandboxed vm with minimal browser stubs and drives the REAL `openLog(id)`,
 * then projects the produced console DOM (plus every fetch it made, with bodies)
 * to inspectable JSON for the Python test. No DOM, no build step (ADR-007).
 * Mirrors board_basefresh_harness.js.
 *
 * It scripts the two GETs openLog fires (the mission detail and, new in S161, the
 * daemon-side log session) and the two POSTs its buttons dispatch, so the whole
 * restore-a-closed-console flow is drivable with zero daemon and zero spend.
 *
 * argv[2]: mode —
 *   open       openLog(id), let the restore GET settle → project the console
 *   clickFile  ... then click the console's File button → project again
 *   clickFilePos ... then click the FOOTER's File control by POSITION → project
 *              again. At `partial` that control's label is part of what we assert
 *              (it names how many bugs the retry will file), so it cannot be found
 *              by text.
 *   clickGo    ... then click the console's "Go ▸" button → project again
 *   openFix    openLog(id, {fix: true}) — the S163 "Fix Filed Bugs" entry point,
 *              i.e. the captain reopening the cost review from the CARD after
 *              closing the console. Same console, one option: with a session it
 *              restores it; with none (the daemon restarted) it falls back to the
 *              read-only linked-children view rather than a dead panel.
 *   fixThenGo  ... openFix, then click "Go ▸" → project again.
 *   fixSteerGo ... openFix, type INPUT.steer into the FIRST bug's model-override
 *              box (the S74 steer the whole review exists for), then click
 *              "Go ▸" → project again. The /log/run body is the assertion.
 *   dismiss    ... then click the footer's dismissal button (whatever it is
 *              currently labelled) → project again. That is the S161-fix D3
 *              escape hatch: from a state where nothing landed it discards the
 *              daemon session; otherwise it only closes.
 *   clickPreview     ... then click the footer's Preview control BY POSITION →
 *              project again. By position because the S161-fix-R3 (R1) guard
 *              RELABELS it to name what a second click would destroy, so its label
 *              is a subject of the assertions.
 *   clickPreviewTwice ... same control, clicked TWICE — the captain passing the
 *              confirmation deliberately.
 *   clickFileThenPreview  click the footer's File control and then, WITHOUT
 *              letting the /log/file POST settle, click the footer's Preview
 *              control. That is the console mid-dispatch: File is wearing its
 *              transient "Filing…" text while the session the daemon still holds
 *              is `partial`, so any copy that names the retry control by reading
 *              its DOM text names it wrongly.
 * argv[3]: a JSON file:
 *   {"mission": {...},            the /api/mission/<id> detail
 *    "session": {...}|null,       the /log/session payload (null ⇒ HTTP 404)
 *    "children": [...],           S163 fix round 1 (D2): the parent's LINKED BUG
 *                                 CHILDREN, fed through the REAL
 *                                 `indexIssues({missions})` so the console can
 *                                 read `logFixState(mi)` the way a board render
 *                                 builds it. Absent ⇒ the index stays empty, so
 *                                 every pre-existing drive is unchanged.
 *    "fileResponse": {...}}       the /log/file success `state` (default: an
 *                                 S161 accepted-dispatch, status "filing")
 * argv[4]: optional "readonly" → writesActive=false before rendering.
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function stubEl(tag) {
  var node = {
    tag: tag || "",
    style: {},
    classList: {
      _s: {},
      add(c) { this._s[c] = true; },
      remove(c) { delete this._s[c]; },
      toggle() { return false; },
      contains(c) { return !!this._s[c]; },
    },
    _listeners: {},
    addEventListener(type, fn) {
      (node._listeners[type] || (node._listeners[type] = [])).push(fn);
    },
    removeEventListener() {},
    appendChild(c) { node.children.push(c); if (c) c.parentNode = node; return c; },
    insertBefore(c, ref) {
      var i = node.children.indexOf(ref);
      if (i < 0) node.children.push(c); else node.children.splice(i, 0, c);
      if (c) c.parentNode = node;
      return c;
    },
    removeChild(c) {
      var i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      return c;
    },
    setAttribute() {}, removeAttribute() {},
    querySelector(sel) {
      // openLog's working node looks up ".lcars-working-label" inside itself.
      var found = null;
      (function walk(n) {
        if (found || !n) return;
        var cls = " " + (n._cls || "") + " ";
        if (sel && sel.charAt(0) === "." &&
            cls.indexOf(" " + sel.slice(1) + " ") !== -1) { found = n; return; }
        (n.children || []).forEach(walk);
      })(node);
      return found;
    },
    querySelectorAll() { return []; },
    getAttribute() { return null; }, focus() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
    value: "",
  };
  Object.defineProperty(node, "className", {
    get() { return node._cls || ""; },
    set(v) { node._cls = v; },
  });
  Object.defineProperty(node, "textContent", {
    // configurable so a single node (the status line) can be re-wrapped to
    // record every write — see STATUS_TRACE below.
    configurable: true,
    get() { return node._text; },
    set(v) { node._text = v; node.children = []; },
  });
  Object.defineProperty(node, "innerHTML", {
    get() { return node._html || ""; },
    set(v) { node._html = v; if (v === "") node.children = []; },
  });
  Object.defineProperty(node, "lastChild", {
    get() { return node.children[node.children.length - 1] || null; },
  });
  return node;
}

const REGISTRY = {};
["mainDeploy", "fileBtn", "conn", "repoMeta", "deployMainBtn", "versionBanner",
 "readinessBanner", "board", "status", "viewonly", "overlay", "overlayBody",
 "boardEmpty"]
  .forEach(function (id) { REGISTRY[id] = stubEl("div"); });

/* S163 fix round 5 — EVERY frame of the status line, not just the last one.
 *
 * The defect this instrumentation exists for was invisible to a final-frame
 * assertion: a refused Go put its verdict on screen for 33 ms (~2 frames) and
 * the routine repaint then erased it, so the last frame read "16 active
 * missions" and the middle frame — the only one that told the captain the run
 * did not happen — was gone. Sampling the END of an interaction can only ever
 * see the erasure, never the claim that preceded it.
 *
 * So the trace hooks the STATUS NODE itself rather than any one writer: every
 * textContent write lands here in order, whichever function made it. A drive can
 * then assert on the whole interaction ("no frame ever claimed a dispatch") and
 * on what survives ("the last frame still names the bug and the steer").
 */
const STATUS_TRACE = [];
(function (n) {
  Object.defineProperty(n, "textContent", {
    get() { return n._text; },
    set(v) { n._text = v; n.children = []; STATUS_TRACE.push(String(v)); },
  });
})(REGISTRY.status);

const bodyStub = stubEl("body");
// The console guards its status poll with `document.body.contains(m.wrap)` (the
// real overlay lives inside <body>, and closing it detaches the modal). The
// registry stubs above are not parented to this body, so answer true — this
// harness only ever drives an OPEN console.
bodyStub.contains = function () { return true; };

const documentStub = {
  getElementById(id) { return REGISTRY[id] || stubEl(); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { var n = stubEl("#text"); n._text = t; return n; },
  addEventListener() {},
  body: bodyStub,
};

const INPUT = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const FETCH_CALLS = [];
const MID = (INPUT.mission && INPUT.mission.id) || "m-001";

function json(status, obj) {
  return Promise.resolve({
    status: status, ok: status >= 200 && status < 300,
    json: function () { return Promise.resolve(obj); },
  });
}

function fetchStub(url, opts) {
  const method = (opts && opts.method) || "GET";
  let body = null;
  if (opts && opts.body) { try { body = JSON.parse(opts.body); } catch (e) {} }
  FETCH_CALLS.push({ url: url, method: method, body: body });
  if (url === "/api/mission/" + MID) return json(200, INPUT.mission || {});
  if (url === "/api/mission/" + MID + "/log/session") {
    // S163: `sessionError` ⇒ the restore GET FAILS rather than 404s (the daemon
    // is wedged, not merely forgetful). "Never a dead button" has to hold there
    // too, so a drive can ask for it.
    if (INPUT.sessionError) return json(500, { error: "boom" });
    if (!INPUT.session) return json(404, { error: "no session" });
    return json(200, INPUT.session);
  }
  if (url === "/api/mission/" + MID + "/log/file") {
    // S162: `fileError` ⇒ the daemon REFUSES the dispatch. The console has
    // already closed by then, so what the client does with that refusal (drop
    // the optimistic band, say so on the only surface left) is the assertion.
    if (INPUT.fileError) {
      return json(409, { ok: false, error: String(INPUT.fileError) });
    }
    const state = INPUT.fileResponse || {
      sessionId: (INPUT.session && INPUT.session.sessionId) || "sid",
      parent: MID, status: "filing", authored: true, filed: false,
      children: (INPUT.session && INPUT.session.children) || [], count: 1,
    };
    return json(200, { ok: true, state: state });
  }
  if (url === "/api/mission/" + MID + "/log/run") {
    // S163 fix round 4 (D1): `runError` ⇒ the daemon REFUSES the Go because a
    // steer could not be resolved. Nothing is dispatched, so what the client
    // does with that refusal — put the control back, say why, and KEEP the
    // captain's typed words — is the assertion.
    if (INPUT.runError) {
      return json(400, { ok: false, error: String(INPUT.runError) });
    }
    return json(200, { ok: true, state: INPUT.runResponse || {} });
  }
  if (url === "/api/mission/" + MID + "/log/discard") {
    return json(200, { ok: true,
                       state: { parent: MID, status: "discarded" } });
  }
  if (url === "/api/mission/" + MID + "/log") {
    // `previewError` ⇒ the daemon REFUSES the preview (the R1 guard's 409, or any
    // other refusal). Lets a drive prove what a console does when its own picture
    // of the session turns out to be stale.
    if (INPUT.previewError) {
      return json(409, { ok: false, error: String(INPUT.previewError) });
    }
    return json(200, { ok: true, state: INPUT.previewResponse || {} });
  }
  const empty = { stages: [], columns: {}, missions: [], meta: {} };
  return json(200, empty);
}

const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval() { return 0; }, clearInterval() {},
  setTimeout() { return 1; }, clearTimeout() {},
  fetch: fetchStub,
  FileReader: function () {},
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date, Promise,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const src = fs.readFileSync(path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) { /* boot side-effects may throw against stubs; declarations are bound. */ }

var captured = { node: null, opened: 0 };
const REPAINT_ERRORS = [];
sandbox.showOverlay = function (node) { captured.node = node; captured.opened++; };
sandbox.closeOverlay = function () { captured.closed = true; };
/* S163 fix round 5 — `refresh` is the ROUTINE REPAINT, and it is half of the
 * defect. In production it fetches /api/board and renders it, and that render
 * writes the idle "N active missions" line over whatever the action just said.
 * A no-op stub can never see that, which is how four rounds of green tests sat
 * on top of a verdict the captain never got to read.
 *
 * With `repaint` in the drive's JSON the stub renders that board through the
 * REAL `render()`, so a drive measures the same sequence the browser produces:
 * action → verdict → repaint. Without it the stub stays the no-op every earlier
 * drive was written against. */
sandbox.refresh = function () {
  if (!INPUT.repaint) return;
  // ASYNC, like the real one: `refresh` fetches /api/board and renders in a
  // later microtask, so the render lands AFTER the onResult callback that
  // `postWrite` invokes on the same tick. A synchronous stub reverses that
  // order and makes the erasure disappear — the ordering IS the bug.
  return Promise.resolve()
    .then(function () {})
    .then(function () {
      try { sandbox.render(INPUT.repaint); }
      catch (e) { REPAINT_ERRORS.push(String((e && e.message) || e)); }
    });
};
/* NOTE: `setStatus` is deliberately NOT stubbed any more. It writes to the real
 * status node (hooked above), so the trace records what a captain would see
 * whichever writer produced it — including writers this harness has never heard
 * of. `status` below is the LAST frame, unchanged for existing drives. */

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    title: n.title || "",
    hidden: !!n.hidden,
    disabled: !!n.disabled,
    value: n.value || "",
    children: (n.children || []).map(project).filter(Boolean),
  };
}

function drain() {
  var p = Promise.resolve();
  for (var i = 0; i < 8; i++) {
    p = p.then(function () { return new Promise(function (r) { setImmediate(r); }); });
  }
  return p;
}

function findButton(node, label) {
  var found = null;
  (function walk(n) {
    if (found || !n) return;
    if (n.tag === "button" && (n._text || "") === label) { found = n; return; }
    (n.children || []).forEach(walk);
  })(node);
  return found;
}

/* The FIRST per-bug model-override box in a console — found as the first <input>
 * carrying an "input" listener, which is what wires it to `authored.steers`.
 * Lifted out of the drives that already did this by hand (S163 fix round 6): a
 * drive that types, refuses, and types again needs it more than once, and two
 * copies of a finder is how one of them quietly starts finding something else. */
function firstSteerBox(root) {
  var box = null;
  (function walk(n) {
    if (box || !n) return;
    if (n.tag === "input" && (n._listeners.input || []).length) { box = n; return; }
    (n.children || []).forEach(walk);
  })(root);
  if (!box) throw new Error("no per-bug model-override box in the review");
  return box;
}

function click(node, label) {
  var b = findButton(node, label);
  if (!b) throw new Error("no button labelled " + JSON.stringify(label));
  (b._listeners.click || []).forEach(function (fn) {
    fn({ stopPropagation() {} });
  });
}

const mode = process.argv[2];

(async function main() {
  await drain();                    // let boot's own fetches settle first
  if (process.argv[4] === "readonly") sandbox.writesActive = false;
  // S163 fix round 1 (D2): build CHILDREN_BY_PARENT through the REAL indexer so
  // the console's own `logFixState(mi)` reading is the board's reading, not a
  // poked index. Only when a drive asks for it.
  if (INPUT.children) {
    sandbox.indexIssues({ missions: [INPUT.mission || { id: MID }]
                            .concat(INPUT.children),
                          meta: {} });
  }
  FETCH_CALLS.length = 0;
  STATUS_TRACE.length = 0;   // boot's own render is not part of the drive
  // S163: the card's "Fix Filed Bugs" control opens the SAME console with one
  // option set — never a second console and never a second dispatch path.
  var FIX = (mode === "openFix" || mode === "fixThenGo"
             || mode === "fixSteerGo" || mode === "fixSteer"
             || mode === "fixSteerGoReopen" || mode === "fixSteerGoThenDismiss"
             // S163 fix round 6 (D1/D2) — the two sequences that only mean
             // anything from the card's Fix Filed Bugs door.
             || mode === "fixSteerGoClearGo"
             || mode === "fixSteerGoThenOpenPlain");
  if (FIX) sandbox.openLog(MID, { fix: true });
  else sandbox.openLog(MID);
  await drain();                    // detail GET + the S161 restore GET
  // Type a fresh report into the console's box when the drive needs one: an EMPTY
  // box means the read-only linked-children preview, which authors nothing — the
  // R1 guard only concerns a preview that would replace held authored text.
  if (INPUT.report) {
    (function walk(n) {
      if (!n) return;
      if (n.tag === "textarea") { n.value = INPUT.report; return; }
      (n.children || []).forEach(walk);
    })(captured.node);
  }
  // S162 renamed the control to "File & Cost" — it now DISPATCHES the filing and
  // hands the captain the parent card, so its name says what it costs them.
  if (mode === "clickFile") { click(captured.node, "File & Cost"); await drain(); }
  else if (mode === "clickFilePos") {
    // footer order is [dismiss, Preview, File, Go ▸] — take File by index so its
    // label stays a subject of the assertions.
    var ft = (captured.node.children || [])[2];
    var fb = ((ft && ft.children) || [])[2];
    if (!fb) throw new Error("no File control in the console footer");
    (fb._listeners.click || []).forEach(function (fn) {
      fn({ stopPropagation() {} });
    });
    await drain();
  }
  else if (mode === "clickPreview" || mode === "clickPreviewTwice") {
    // footer order is [dismiss, Preview, File, Go ▸] — take Preview by index so
    // its label (which the R1 guard rewrites) stays a subject of the assertions.
    var pf = (captured.node.children || [])[2];
    var pb = ((pf && pf.children) || [])[1];
    if (!pb) throw new Error("no Preview control in the console footer");
    var hits = mode === "clickPreviewTwice" ? 2 : 1;
    for (var k = 0; k < hits; k++) {
      (pb._listeners.click || []).forEach(function (fn) {
        fn({ stopPropagation() {} });
      });
      await drain();
    }
  }
  else if (mode === "clickFileThenPreview") {
    // Deliberately NO drain between the two clicks: the /log/file promise is still
    // pending, so File is showing "Filing…" while the session is still `partial`.
    var mf = (captured.node.children || [])[2];
    var mfb = ((mf && mf.children) || [])[2];
    var mpb = ((mf && mf.children) || [])[1];
    if (!mfb || !mpb) throw new Error("no File/Preview controls in the footer");
    (mfb._listeners.click || []).forEach(function (fn) {
      fn({ stopPropagation() {} });
    });
    (mpb._listeners.click || []).forEach(function (fn) {
      fn({ stopPropagation() {} });
    });
    await drain();
  }
  else if (mode === "clickGo" || mode === "fixThenGo") {
    click(captured.node, "Go ▸"); await drain();
  }
  else if (mode === "fixSteerGo" || mode === "fixSteer") {
    // The per-bug model-override box (S74) — the control the whole cost review
    // exists for. Found as the first <input> carrying an "input" listener, which
    // is what wires it to authored.overrides[i]; typed into the way a captain
    // types (set value, fire the listener), then Go.
    //
    // S163 fix round 4 (D1): `fixSteer` STOPS at the typing. What the console
    // says about a steer it has not resolved is the assertion — the tester was
    // told "model intent resolved when filed" about a steer that never resolved
    // and was never going to, on a batch that was already filed.
    var ovBox = null;
    (function walk(n) {
      if (ovBox || !n) return;
      if (n.tag === "input" && (n._listeners.input || []).length) { ovBox = n; return; }
      (n.children || []).forEach(walk);
    })(captured.node);
    if (!ovBox) throw new Error("no per-bug model-override box in the review");
    ovBox.value = INPUT.steer || "use Opus";
    (ovBox._listeners.input || []).forEach(function (fn) { fn({}); });
    if (mode === "fixSteerGo") {
      click(captured.node, "Go ▸");
      await drain();
    }
  }
  else if (mode === "fixSteerGoThenDismiss") {
    // S163 fix round 5: a refused Go (which leaves a VERDICT on the status
    // line), then a second, unrelated dispatch — the console's dismissal
    // control, which discards the session and reports no copy of its own. The
    // stale verdict must not outlive it. Nothing but the dispatch can clear it,
    // so this is the sequence that proves the rule rather than the copy.
    var ovBox3 = null;
    (function walk(n) {
      if (ovBox3 || !n) return;
      if (n.tag === "input" && (n._listeners.input || []).length) { ovBox3 = n; return; }
      (n.children || []).forEach(walk);
    })(captured.node);
    if (!ovBox3) throw new Error("no per-bug model-override box in the review");
    ovBox3.value = INPUT.steer || "use haiku";
    (ovBox3._listeners.input || []).forEach(function (fn) { fn({}); });
    click(captured.node, "Go ▸");
    await drain();
    // the refusal reopened the review; its footer's FIRST control is dismissal.
    var dfoot = (((captured.node || {}).children || [])[2] || {});
    var dbtn = ((dfoot.children || [])[0] || null);
    if (!dbtn) throw new Error("no dismissal control in the reopened console");
    (dbtn._listeners.click || []).forEach(function (fn) {
      fn({ stopPropagation() {} });
    });
    await drain();
  }
  else if (mode === "fixSteerGoReopen") {
    // S163 fix round 4 (D1): type a steer, press Go, have it REFUSED, then
    // reopen the console from the card exactly as the captain would. The typed
    // words must still be in the box — a refusal that eats the instruction is
    // the same loss as a drop, one click later.
    var ovBox2 = null;
    (function walk(n) {
      if (ovBox2 || !n) return;
      if (n.tag === "input" && (n._listeners.input || []).length) { ovBox2 = n; return; }
      (n.children || []).forEach(walk);
    })(captured.node);
    if (!ovBox2) throw new Error("no per-bug model-override box in the review");
    ovBox2.value = INPUT.steer || "use haiku";
    (ovBox2._listeners.input || []).forEach(function (fn) { fn({}); });
    click(captured.node, "Go ▸");
    await drain();
    captured.node = null;
    sandbox.openLog(MID, { fix: true });
    await drain();
  }
  else if (mode === "fixSteerGoClearGo") {
    /* S163 fix round 6 (D1) — THE CLEAR. Type a steer, have the Go refused,
     * then EMPTY that box in the reopened review and press Go again.
     *
     * The tester's measurement: the second Go re-sent the steer the captain had
     * just deleted, because the box was re-seeded from the daemon's stale
     * verdict for that bug. Both halves are asserted from this one drive — what
     * the second /log/run BODY carries, and what the box holds afterwards. */
    var boxA = firstSteerBox(captured.node);
    boxA.value = INPUT.steer || "badsteer1";
    (boxA._listeners.input || []).forEach(function (fn) { fn({}); });
    click(captured.node, "Go ▸");
    await drain();
    // the refusal reopened the review — clear the box in THAT console, the one
    // the captain is actually looking at.
    var boxB = firstSteerBox(captured.node);
    boxB.value = "";
    (boxB._listeners.input || []).forEach(function (fn) { fn({}); });
    click(captured.node, "Go ▸");
    await drain();
  }
  else if (mode === "fixSteerGoThenOpenPlain") {
    /* S163 fix round 6 (D2) — a refused Go leaves a verdict; the captain then
     * opens a console by hand. That is the NEXT ACTION, and the last action's
     * outcome must stop speaking over it. Opening is deliberately the whole
     * second step: it reports no copy of its own and dispatches nothing, which
     * is exactly the case `postWrite`'s clear could never reach. */
    var boxC = firstSteerBox(captured.node);
    boxC.value = INPUT.steer || "badsteer1";
    (boxC._listeners.input || []).forEach(function (fn) { fn({}); });
    click(captured.node, "Go ▸");
    await drain();
    captured.node = null;
    sandbox.openLog(MID);          // by hand, from the detail — no options
    await drain();
  }
  else if (mode === "dismiss") {
    // the footer's FIRST button is the dismissal control; its label is part of
    // what we are asserting, so find it by position, not by text.
    var foot = (captured.node.children || [])[2];
    var b = ((foot && foot.children) || [])[0];
    if (!b) throw new Error("no dismissal button in the console footer");
    (b._listeners.click || []).forEach(function (fn) {
      fn({ stopPropagation() {} });
    });
    await drain();
  }
  else if (mode !== "open" && mode !== "openFix") {
    process.stderr.write("unknown mode " + mode + "\n");
    process.exit(2);
  }
  // S163 fix round 5: one more ROUTINE repaint after everything has settled —
  // the SSE tick that arrives a second later, with no action behind it. A
  // verdict has to survive that too, not just the repaint its own action fired.
  if (INPUT.repaintAfter && INPUT.repaint) {
    try { sandbox.render(INPUT.repaint); }
    catch (e) { REPAINT_ERRORS.push(String((e && e.message) || e)); }
    await drain();
  }
  var foot0 = (((captured.node || {}).children || [])[2] || {});
  var d = ((foot0.children || [])[0] || {});
  process.stdout.write(JSON.stringify({
    node: project(captured.node),
    fetches: FETCH_CALLS,
    closed: !!captured.closed,
    status: REGISTRY.status._text || "",
    /* S163 fix round 6 (D4) — the status node's CLASS LIST, because the class
     * list is half of what reaches the screen. The round-5 assertions read only
     * the TEXT, and the tester then measured that text arriving in the page's
     * dimmest colour (3.6:1) on every modal-closing path. The Python side
     * cascades this against the real stylesheets rather than trusting a rule to
     * exist in one. */
    statusCls: REGISTRY.status._cls || "",
    // every frame of the status line, in order (S163 fix round 5).
    statusTrace: STATUS_TRACE,
    repaintErrors: REPAINT_ERRORS,
    // how many times a console was put on the stage during this drive — a
    // refusal that reopens the review is 2.
    opened: captured.opened,
    // S162: whether the console marked its PARENT mission "filing" — the client
    // half of the card band, and the thing that makes closing the console safe.
    filing: typeof sandbox.isFiling === "function" ? !!sandbox.isFiling(MID)
                                                   : null,
    // S163: whether the Go marked the PARENT "dispatched" — the client half of
    // what makes the Fix Filed Bugs control disappear on the click.
    logRun: typeof sandbox.isLogRunDispatched === "function"
      ? !!sandbox.isLogRunDispatched(MID) : null,
    // the footer's dismissal control, projected by POSITION so its label is a
    // subject of the assertions rather than the way we find it.
    dismiss: { text: d._text || "", title: d.title || "" },
  }));
})().catch(function (e) {
  process.stderr.write(String((e && e.stack) || e) + "\n");
  process.exit(2);
});
