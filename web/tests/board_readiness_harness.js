"use strict";
/* S146 test-readiness render harness — loads the SHIPPING web/static/board.js in
 * a sandboxed vm with minimal browser stubs and drives the REAL readiness
 * surfaces, projecting the produced DOM to inspectable JSON for the Python test
 * (no DOM, no build step — ADR-007). Mirrors board_band_harness.js, plus:
 *   • stub nodes RECORD their click listeners so the test can simulate clicks;
 *   • a scripted host-side fetch stub records every request and answers from a
 *     queue, so ⚡ FIX / SET / park clicks run their real postWrite path.
 *
 * argv[2]: mode —
 *   banner    render renderTestReadiness(tr); project #readinessBanner
 *   file      openFile() with LAST_BOARD.meta.testReadiness = tr; project the
 *             overlay (the console) — used for both unready and READY (tr null)
 *   fileclick openFile(), type an idea, click ⚡ FIX (scripted success),
 *             project after the settled return (warning must clear IN PLACE,
 *             idea preserved)
 *   filefail  like fileclick but the fix POST fails → plain report, input stays
 *   filesse   openFile(), type an idea, then render() a READY board (the SSE
 *             re-verdict) → warning clears in place, idea preserved
 *   filepark  openFile() on an UNREADY board, type an idea, click
 *             "◇ File to Backlog ▸" → the park POST must fire (never blocked)
 *   fileset   openFile(), type a command into the override input, click SET →
 *             POST /api/config/test-command with that command
 * argv[3]: a JSON file: {"tr": {...}|null}
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
    querySelector() { return null; }, querySelectorAll() { return []; },
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

// persistent registry so getElementById returns the SAME node across calls.
const REGISTRY = {};
["mainDeploy", "fileBtn", "conn", "repoMeta", "deployMainBtn",
 "versionBanner", "readinessBanner", "board", "status", "viewonly",
 "overlay", "overlayBody"]
  .forEach(function (id) { REGISTRY[id] = stubEl("div"); });

const documentStub = {
  getElementById(id) { return REGISTRY[id] || stubEl(); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { var n = stubEl("#text"); n._text = t; return n; },
  addEventListener() {},
  body: stubEl("body"),
};

// scripted fetch: records {url, body}; answers ok-JSON per URL. The fix/set
// endpoints answer with a READY board state (state.board.meta = {}) unless
// FAIL_WRITES is set (then ok:false with a plain report). /api/board answers a
// ready board so postWrite's refresh() path renders cleanly.
const FETCH_CALLS = [];
let FAIL_WRITES = false;
const READONLY = process.argv[4] === "readonly";
// what GET /api/board answers — starts as the mode's board (set in main());
// fileclick flips it to the READY board before clicking, mirroring the server's
// post-fix re-verdict.
let CURRENT_BOARD = { stages: [], columns: {}, missions: [], meta: {} };
function fetchStub(url, opts) {
  FETCH_CALLS.push({ url: url, method: (opts && opts.method) || "GET",
                     body: (opts && opts.body) || null });
  var data;
  if (url === "/api/board" || (opts && opts.method) !== "POST") {
    // resolve CURRENT_BOARD LAZILY (at json() time), so a board fetched at
    // boot but consumed after main() swapped the board sees the mode's board.
    return Promise.resolve({ status: 200, ok: true,
                             json: function () { return Promise.resolve(CURRENT_BOARD); } });
  }
  if (READONLY) {
    data = { ok: false, error: "read-only" };
    return Promise.resolve({ status: 403, ok: false,
                             json: function () { return Promise.resolve(data); } });
  }
  if (FAIL_WRITES) {
    data = { ok: false,
             error: "⚠ TEST SYSTEMS SET BUT UNVERIFIED — the probe reported fail." };
  } else {
    data = { ok: true, state: { board: { meta: {} } } };
  }
  return Promise.resolve({ status: 200, ok: true,
                           json: function () { return Promise.resolve(data); } });
}

const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval() { return 0; }, clearInterval() {},
  setTimeout() { return 0; }, clearTimeout() {},
  fetch: fetchStub,
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const src = fs.readFileSync(path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) {
  /* boot side-effects may throw against the stubs; the hoisted declarations we
     need are already bound by then. */
}

const mode = process.argv[2];
const input = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const tr = input.tr || null;
if (process.argv[4] === "readonly") sandbox.writesActive = false;

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    disabled: !!n.disabled,
    value: n.value || "",
    hidden: !!n.hidden,
    children: (n.children || []).map(project).filter(Boolean),
  };
}

// depth-first find over the LIVE stub tree.
function findNode(root, pred) {
  if (!root || typeof root !== "object") return null;
  if (pred(root)) return root;
  for (var i = 0; i < (root.children || []).length; i++) {
    var hit = findNode(root.children[i], pred);
    if (hit) return hit;
  }
  return null;
}
function click(node) {
  ((node && node._listeners && node._listeners.click) || [])
    .forEach(function (fn) { fn({ stopPropagation: function () {} }); });
}
function drain() {
  // flush the promise chain a few microtask/macrotask rounds.
  return new Promise(function (r) { setImmediate(r); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); });
}

function boardWith(trBlock) {
  var meta = {};
  if (trBlock) meta.testReadiness = trBlock;
  return { stages: [], columns: {}, missions: [], meta: meta };
}

function out(obj) { process.stdout.write(JSON.stringify(obj)); }

(async function main() {
  if (mode === "banner") {
    sandbox.renderTestReadiness(tr);
    out({ banner: project(REGISTRY.readinessBanner),
          hidden: !!REGISTRY.readinessBanner.hidden });
    return;
  }

  // every file* mode opens the console over a board carrying (or not) the block.
  CURRENT_BOARD = boardWith(tr);
  sandbox.LAST_BOARD = boardWith(tr);
  if (mode !== "file") {
    // flush board.js's BOOT promises (probeWrites + the initial refresh) so a
    // late-resolving boot render can't repaint the block mid-assertion; the
    // boot board carries the same tr, so this is a no-op visually. "file"
    // projects synchronously, before any promise can resolve.
    await drain();
    FETCH_CALLS.length = 0;
  }
  sandbox.openFile();
  const overlayBody = REGISTRY.overlayBody;
  const ideaBox = findNode(overlayBody, function (n) { return n.tag === "textarea"; });

  if (mode === "file") {
    out({ overlay: project(overlayBody) });
    return;
  }

  if (ideaBox) ideaBox.value = "my precious idea";

  if (mode === "fileclick" || mode === "filefail") {
    FAIL_WRITES = (mode === "filefail");
    if (mode === "fileclick") CURRENT_BOARD = boardWith(null); // post-fix ready
    const fixBtn = findNode(overlayBody, function (n) {
      return n.tag === "button" && n._text === "⚡ FIX TEST SYSTEMS";
    });
    if (!fixBtn) {
      out({ error: "fix button not found", overlay: project(overlayBody) });
      process.exit(2);
    }
    click(fixBtn);
    await drain();
    out({ overlay: project(overlayBody),
          idea: ideaBox ? ideaBox.value : null,
          fetches: FETCH_CALLS });
    return;
  }

  if (mode === "fileset") {
    const inputBox = findNode(overlayBody, function (n) {
      return n.tag === "input" && /Manual override/.test(n.placeholder || "");
    });
    if (!inputBox) { out({ error: "override input not found" }); process.exit(2); }
    inputBox.value = "bash run-my-suite.sh";
    const setBtn = findNode(overlayBody, function (n) {
      return n.tag === "button" && n._text === "SET";
    });
    click(setBtn);
    await drain();
    out({ overlay: project(overlayBody),
          idea: ideaBox ? ideaBox.value : null,
          fetches: FETCH_CALLS });
    return;
  }

  if (mode === "filesse") {
    // the SSE re-verdict: a fresh READY board renders while the console is open.
    sandbox.render(boardWith(null));
    out({ overlay: project(overlayBody),
          idea: ideaBox ? ideaBox.value : null });
    return;
  }

  if (mode === "filepark") {
    const parkBtn = findNode(overlayBody, function (n) {
      return n.tag === "button" && /File to Backlog/.test(n._text || "");
    });
    if (!parkBtn) { out({ error: "park button not found" }); process.exit(2); }
    click(parkBtn);
    await drain();
    out({ fetches: FETCH_CALLS });
    return;
  }

  process.stderr.write("unknown mode " + mode + "\n");
  process.exit(2);
})().catch(function (e) {
  process.stderr.write(String(e && e.stack || e) + "\n");
  process.exit(2);
});
