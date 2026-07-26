"use strict";
/* Park & Align (S137 / BUG-1/2/3) DETAIL + interaction harness. Loads the SHIPPING
 * web/static/board.js in a sandboxed vm (no DOM, no build — ADR-007) and drives the
 * real builders, projecting the produced DOM to inspectable JSON.
 *
 * argv[2]: a JSON file with a mission object.
 * argv[3]: mode —
 *   "detail"          renderDetail(mi) → project the overlay grid (BUG-1/BUG-2).
 *   "detail-aligning" as "detail" but with isAligning(id) forced true (BUG-3 guard).
 *   "card"            cardNode(mi) — reads mi.alignResume for the RESUME affordance.
 *   "card-aligning"   cardNode(mi) with isAligning(id) forced true (BUG-3 guard).
 *   "card-finalizing" cardNode(mi) with isFinalizing(id) forced true (F1 band+guard).
 *   "card-resume-client" cardNode(mi) with a client RESUMABLE[id] set (F2 RESUME).
 *   "close-keeps"     renderAlignConsole({...}, false, id) then closeOverlay() → F2:
 *                     assert NO /cancel POST and RESUMABLE[id] is set.
 *   "resume"          resumeAlignment(id, sid) with a canned question turn → F2:
 *                     assert a GET /api/align/<sid> and the console opens.
 *   "cancel-during-scan" beginAlignment(id); closeOverlay() → isAligning stays set.
 *   "stale-open"      beginAlignment(id); closeOverlay() BEFORE the in-flight
 *                     /api/align/start resolves; then let it resolve → console opens,
 *                     no /cancel.
 * argv[4]: optional "readonly" → writesActive=false before rendering.
 *
 * Output (stdout): JSON { overlay, fetches, opened, aligning, resumable } where
 * `overlay` is the projected captured DOM (or null), `fetches` the ordered list of
 * request URLs, `opened` the count of showOverlay calls, `resumable` the RESUMABLE
 * keys. Mirrors board_card_harness.js projection.
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
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { node.children.push(c); return c; },
    insertBefore(c) { node.children.push(c); return c; },
    removeChild() {}, setAttribute() {}, removeAttribute() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, focus() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
    parentNode: null, nextSibling: null,
  };
  Object.defineProperty(node, "lastChild", {
    get() { return node.children[node.children.length - 1] || null; },
  });
  Object.defineProperty(node, "className", {
    get() { return node._cls || ""; }, set(v) { node._cls = v; },
  });
  Object.defineProperty(node, "textContent", {
    get() { return node._text; },
    set(v) { node._text = v; node.children = []; },
  });
  Object.defineProperty(node, "innerHTML", {
    get() { return node._html || ""; },
    set(v) { node._html = v; if (v === "") node.children = []; },
  });
  return node;
}

var _timerSeq = 0;
const fetchCalls = [];
function fetchStub(url) {
  fetchCalls.push(String(url));
  var next = fetchStub._next || { ok: true, state: {} };
  var status = fetchStub._status || 200;
  return Promise.resolve({
    status: status,
    ok: status >= 200 && status < 300,
    json: function () { return Promise.resolve(next); },
  });
}

const documentStub = {
  getElementById() { return stubEl(); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { var n = stubEl("#text"); n._text = t; return n; },
  addEventListener() {},
  body: stubEl("body"),
};
const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval() { return 0; }, clearInterval() {},
  // Return a TRUTHY, unique timer handle (real setTimeout never returns 0) so
  // handle-as-flag guards like markAligning/markStarting (which store the handle
  // in a set and test its truthiness) behave as they do in a browser.
  setTimeout() { return ++_timerSeq; }, clearTimeout() {},
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

// capture showOverlay's argument (the modal/grid node) without a real DOM.
var captured = { node: null, count: 0 };
sandbox.showOverlay = function (node) { captured.node = node; captured.count += 1; };

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    disabled: !!n.disabled,
    children: (n.children || []).map(project).filter(Boolean),
  };
}

const mission = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const mode = process.argv[3] || "detail";
if (process.argv[4] === "readonly") sandbox.writesActive = false;

function flush() { return new Promise((r) => setImmediate(r)); }

var aligningAfter = null; // FIX-B: isAligning(id) captured after a cancel-during-scan.

async function main() {
  if (mode === "detail" || mode === "detail-aligning") {
    if (mode === "detail-aligning") sandbox.ALIGNING[String(mission.id)] = 1;
    sandbox.renderDetail(mission);
  } else if (mode === "card" || mode === "card-aligning"
             || mode === "card-finalizing" || mode === "card-resume-client") {
    if (mode === "card-aligning") sandbox.ALIGNING[String(mission.id)] = 1;
    if (mode === "card-finalizing") sandbox.FINALIZING[String(mission.id)] = 1;
    if (mode === "card-resume-client") {
      sandbox.RESUMABLE[String(mission.id)] = "sid-client";
    }
    captured.node = sandbox.cardNode(mission); // cardNode returns the node directly
  } else if (mode === "file") {
    sandbox.openFile(); // builds the File-New-Mission modal → showOverlay captures it
  } else if (mode === "close-keeps") {
    // F2: closing a mid-grill console KEEPS the warm session (no /cancel) and marks
    // the parked mission RESUMABLE.
    sandbox.renderAlignConsole({
      sessionId: "abc", status: "question",
      question: { text: "What matters most?", choices: ["a", "b"] }, prd: "",
    }, false, mission.id);
    sandbox.closeOverlay();
    await flush();
  } else if (mode === "resume") {
    // F2: RESUME ALIGN GETs the session's open turn and reopens the console.
    fetchStub._next = {
      sessionId: "sid-resume", status: "question",
      question: { text: "Where were we?", choices: ["x", "y"] }, prd: "# PRD",
    };
    sandbox.resumeAlignment(mission.id, "sid-resume");
    await flush(); await flush();
  } else if (mode === "cancel-during-scan") {
    // Dismissing an UNRELATED overlay DURING the in-flight /api/align/start POST
    // must NOT abort the scan — isAligning stays set (the console opens when the
    // worker turn returns). Capture isAligning right after closeOverlay (no flush —
    // still "in flight").
    sandbox.beginAlignment(mission.id);
    sandbox.closeOverlay();
    aligningAfter = sandbox.isAligning(mission.id);
  } else if (mode === "stale-open") {
    // An unrelated close during the in-flight POST must NOT abort: the console
    // still opens when the response resolves, and the session is NOT reaped.
    fetchStub._next = { ok: true, state: { sessionId: "sid-stale" } };
    sandbox.beginAlignment(mission.id); // arms guard + fires /api/align/start
    sandbox.closeOverlay();             // captain closes an unrelated overlay mid-POST
    await flush(); await flush();       // let the start response resolve → console opens
  }

  process.stdout.write(JSON.stringify({
    overlay: project(captured.node),
    fetches: fetchCalls,
    opened: captured.count,
    aligning: aligningAfter,
    resumable: Object.keys(sandbox.RESUMABLE || {}),
  }));
}

main();
