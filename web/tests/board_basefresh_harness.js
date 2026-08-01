"use strict";
/* S160 base-freshness render harness — loads the SHIPPING web/static/board.js in
 * a sandboxed vm with minimal browser stubs and drives the REAL surfaces, then
 * projects the produced DOM to inspectable JSON for the Python test (no DOM, no
 * build step — ADR-007). Mirrors board_detail_harness.js, plus:
 *   • `title` rides the projection — the card badge is compact by design and
 *     carries the record's own `reason` as its tooltip, so a test that could not
 *     see titles could not tell an honest badge from a decorative one;
 *   • a scripted GET /api/base-freshness answering the pre-flight the File
 *     console fires (a record, or a failure), so the console's behaviour on
 *     "loud", "quiet" and "the check never answered" is all drivable.
 *
 * argv[2]: mode —
 *   card     cardNode(m) → project the card
 *   detail   renderDetail(m) → project the captured overlay node
 *   file     openFile(), let the pre-flight settle → project the console
 * argv[3]: a JSON file: {"mission": {...}, "preflight": {...}|null,
 *                        "preflightFails": true|false}
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

const REGISTRY = {};
["mainDeploy", "fileBtn", "conn", "repoMeta", "deployMainBtn", "versionBanner",
 "readinessBanner", "board", "status", "viewonly", "overlay", "overlayBody"]
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

const INPUT = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const FETCH_CALLS = [];

function fetchStub(url, opts) {
  FETCH_CALLS.push({ url: url, method: (opts && opts.method) || "GET" });
  if (url === "/api/base-freshness") {
    if (INPUT.preflightFails) return Promise.reject(new Error("boom"));
    return Promise.resolve({
      status: 200, ok: true,
      json: function () {
        return Promise.resolve({ baseFreshness: INPUT.preflight || null });
      },
    });
  }
  const empty = { stages: [], columns: {}, missions: [], meta: {} };
  return Promise.resolve({ status: 200, ok: true,
                           json: function () { return Promise.resolve(empty); } });
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

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    title: n.title || "",
    hidden: !!n.hidden,
    disabled: !!n.disabled,
    children: (n.children || []).map(project).filter(Boolean),
  };
}

function drain() {
  return new Promise(function (r) { setImmediate(r); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); });
}

const mode = process.argv[2];
if (process.argv[4] === "readonly") sandbox.writesActive = false;

(async function main() {
  const mission = INPUT.mission || {};
  if (mode === "card") {
    captured.node = sandbox.cardNode(mission);
  } else if (mode === "detail") {
    sandbox.renderDetail(mission);
  } else if (mode === "file") {
    await drain();               // let boot's own fetches settle first
    FETCH_CALLS.length = 0;
    sandbox.openFile();
    await drain();               // let the pre-flight GET resolve
  } else {
    process.stderr.write("unknown mode " + mode + "\n");
    process.exit(2);
  }
  process.stdout.write(JSON.stringify({
    node: project(captured.node),
    fetches: FETCH_CALLS,
  }));
})().catch(function (e) {
  process.stderr.write(String((e && e.stack) || e) + "\n");
  process.exit(2);
});
