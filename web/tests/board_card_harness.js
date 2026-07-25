"use strict";
/* Park & Align (S137) card-render harness — loads the SHIPPING web/static/board.js
 * in a sandboxed vm with minimal browser stubs, then calls the real cardNode(m)
 * builder and projects the produced DOM tree to inspectable JSON so the Python
 * test can assert the STANDBY badge + START ALIGNMENT control (and the absence of
 * estimate pills / the "▶ Start" runnable control) without a DOM or a build step
 * (ADR-007). Mirrors board_sections_harness.js.
 *
 * argv[2]: a JSON file with a mission card object.
 * argv[3]: optional "readonly" → sets writesActive=false before rendering, so the
 *          test can assert every write control is disabled on a view-only build.
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
    removeChild() {}, setAttribute() {}, removeAttribute() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, focus() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
  };
  // className / textContent / innerHTML behave as plain assignable props.
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
  return node;
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
  setTimeout() { return 0; }, clearTimeout() {},
  fetch() { const p = { then() { return p; }, catch() { return p; } }; return p; },
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
  /* boot side-effects may throw against the stubs; the hoisted function
     declarations we need are already bound to the sandbox global by then. */
}

if (typeof sandbox.cardNode !== "function") {
  process.stderr.write("cardNode is not defined\n");
  process.exit(2);
}

const mission = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (process.argv[3] === "readonly") sandbox.writesActive = false;

const card = sandbox.cardNode(mission);

// project the DOM subtree to {tag, cls, text, disabled, children}.
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
process.stdout.write(JSON.stringify(project(card)));
