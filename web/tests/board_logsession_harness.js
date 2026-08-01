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
 "readinessBanner", "board", "status", "viewonly", "overlay", "overlayBody"]
  .forEach(function (id) { REGISTRY[id] = stubEl("div"); });

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
    return json(200, { ok: true, state: {} });
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

var captured = { node: null };
sandbox.showOverlay = function (node) { captured.node = node; };
sandbox.closeOverlay = function () { captured.closed = true; };
sandbox.refresh = function () {};
sandbox.setStatus = function (msg) { captured.status = msg; };

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
  FETCH_CALLS.length = 0;
  sandbox.openLog(MID);
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
  else if (mode === "clickGo") { click(captured.node, "Go ▸"); await drain(); }
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
  else if (mode !== "open") {
    process.stderr.write("unknown mode " + mode + "\n");
    process.exit(2);
  }
  var foot0 = (((captured.node || {}).children || [])[2] || {});
  var d = ((foot0.children || [])[0] || {});
  process.stdout.write(JSON.stringify({
    node: project(captured.node),
    fetches: FETCH_CALLS,
    closed: !!captured.closed,
    status: captured.status || "",
    // S162: whether the console marked its PARENT mission "filing" — the client
    // half of the card band, and the thing that makes closing the console safe.
    filing: typeof sandbox.isFiling === "function" ? !!sandbox.isFiling(MID)
                                                   : null,
    // the footer's dismissal control, projected by POSITION so its label is a
    // subject of the assertions rather than the way we find it.
    dismiss: { text: d._text || "", title: d.title || "" },
  }));
})().catch(function (e) {
  process.stderr.write(String((e && e.stack) || e) + "\n");
  process.exit(2);
});
