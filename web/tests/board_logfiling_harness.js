"use strict";
/* S162 mission-log FILING-BAND harness — loads a board.js in a sandboxed vm with
 * minimal browser stubs, drives the REAL card/detail builders, and projects the
 * produced DOM to inspectable JSON so the Python test can assert the
 * ◐ FILING & COSTING… control, the persistent animated band and the failure state
 * without a DOM or a build step (ADR-007). Mirrors board_card_harness.js.
 *
 * Two things it does that the older card harnesses do not:
 *
 *   1. It marks the client-side state through the REAL `markFiling(id)` /
 *      `markFinalizing(id)` entry points rather than poking the maps, so the drive
 *      proves the mark→render wiring the captain's click actually uses. (Its
 *      setTimeout therefore returns a TRUTHY handle: those maps store the timer
 *      handle and test it for truth, so a stub returning 0 would silently render
 *      the "not marked" card.)
 *   2. It can load an ALTERNATE board.js via $LCARS_BOARD_JS, so a test can render
 *      the same fixture through a pristine pre-S162 checkout and compare the two
 *      projections byte-for-byte (the additive-payload invariant).
 *
 * S163 adds two more inputs, for the "Fix Filed Bugs" follow-through:
 *
 *   3. `children` — the parent's LINKED BUG CHILDREN, fed through the REAL
 *      `indexIssues({missions})` so `CHILDREN_BY_PARENT` (and therefore
 *      `isResolvingLocked` / the daemon-restart fallback) is built the way a
 *      board render builds it, not by poking the index. Absent ⇒ the index is
 *      left exactly as S162 left it (empty), so every S162 drive is unchanged.
 *   4. `markLogRun` — the client-side "the captain's Go is dispatched" flag, set
 *      through the shipping `markLogRun(id)` entry point (same contract as
 *      markFiling above: a truthy timer handle is required).
 *
 * argv[2]: mode — "card" (cardNode(m)) | "detail" (renderDetail(m)).
 * argv[3]: a JSON file: {"mission": {...}, "children": [...],
 *                        "markFiling": bool, "markFinalizing": bool,
 *                        "markLogRun": bool}
 * argv[4]: optional "readonly" → writesActive=false before rendering.
 *
 * Output (stdout): {"node": <projection>, "filing": bool, "finalizing": bool,
 *                   "logRun": bool}.
 * The projection carries tag/cls/text/title/hidden/disabled/clickable/children —
 * everything a card can differ by, because it doubles as the byte-identity
 * comparison surface (a field left out of it is a field a regression can hide in).
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
    insertBefore(c) { node.children.push(c); return c; },
    removeChild(c) {
      var i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      return c;
    },
    setAttribute() {}, removeAttribute() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, focus() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
    parentNode: null, nextSibling: null, value: "",
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
  setInterval() { return ++_timerSeq; }, clearInterval() {},
  // A TRUTHY, unique handle — real setTimeout never returns 0, and the optimistic
  // maps (FILING / FINALIZING / ALIGNING) store the handle AS the flag.
  setTimeout() { return ++_timerSeq; }, clearTimeout() {},
  fetch() { const p = { then() { return p; }, catch() { return p; } }; return p; },
  FileReader: function () {},
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date, Promise,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const BOARD_JS = process.env.LCARS_BOARD_JS ||
  path.join(__dirname, "..", "static", "board.js");
const src = fs.readFileSync(BOARD_JS, "utf8");
vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) {
  /* boot side-effects may throw against the stubs; the hoisted function
     declarations we need are already bound to the sandbox global by then. */
}

if (typeof sandbox.cardNode !== "function") {
  process.stderr.write("cardNode is not defined\n");
  process.exit(2);
}

// capture showOverlay's argument (renderDetail shows the grid itself).
var captured = { node: null };
sandbox.showOverlay = function (node) { captured.node = node; };

const INPUT = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const mission = INPUT.mission || {};
const mode = process.argv[2] || "card";
if (process.argv[4] === "readonly") sandbox.writesActive = false;

// The client-side optimistic marks, set through the SHIPPING entry points. A
// pre-S162 board.js has no markFiling at all — that is a legitimate answer for
// the byte-identity drive (which never asks for the mark), and a loud one for any
// other drive.
if (INPUT.markFiling) {
  if (typeof sandbox.markFiling !== "function") {
    process.stderr.write("markFiling is not defined\n");
    process.exit(2);
  }
  sandbox.markFiling(mission.id);
}
if (INPUT.markFinalizing) sandbox.markFinalizing(mission.id);
// S163: a pre-163 board.js has no markLogRun — loud, exactly like markFiling.
if (INPUT.markLogRun) {
  if (typeof sandbox.markLogRun !== "function") {
    process.stderr.write("markLogRun is not defined\n");
    process.exit(2);
  }
  sandbox.markLogRun(mission.id);
}
// S163: build the board's parent→children index through the REAL indexer, so a
// drive that needs linked bug children gets the same CHILDREN_BY_PARENT a render
// would produce. Only when the drive asks for it (S162's fixtures pass none, so
// their index stays empty and their projections are untouched).
if (INPUT.children) {
  sandbox.indexIssues({ missions: [mission].concat(INPUT.children),
                        meta: INPUT.adapter ? { adapter: INPUT.adapter } : {} });
}

if (mode === "detail") sandbox.renderDetail(mission);
else captured.node = sandbox.cardNode(mission);

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    title: n.title || "",
    hidden: !!n.hidden,
    disabled: !!n.disabled,
    clickable: ((n._listeners && n._listeners.click) || []).length > 0,
    children: (n.children || []).map(project).filter(Boolean),
  };
}

process.stdout.write(JSON.stringify({
  node: project(captured.node),
  filing: typeof sandbox.isFiling === "function"
    ? !!sandbox.isFiling(mission.id) : null,
  finalizing: typeof sandbox.isFinalizing === "function"
    ? !!sandbox.isFinalizing(mission.id) : null,
  logRun: typeof sandbox.isLogRunDispatched === "function"
    ? !!sandbox.isLogRunDispatched(mission.id) : null,
}));
