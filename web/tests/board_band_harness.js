"use strict";
/* S139 deploy-main BAND-render harness — loads the SHIPPING web/static/board.js in
 * a sandboxed vm with minimal browser stubs, then calls the real renderMainDeploy(meta)
 * and projects the produced #mainDeploy host DOM to inspectable JSON so the Python
 * test can assert the ● MAIN LIVE pill + sha + STOP (running) and the empty band
 * (no mainLaunch) without a DOM or a build step (ADR-007). Mirrors
 * board_card_harness.js, but drives the topbar band rather than a card.
 *
 * The stub document REGISTERS persistent nodes for the topbar ids (mainDeploy,
 * fileBtn, conn, repoMeta, deployMainBtn) so the test can (a) inspect the band host
 * after render and (b) confirm the existing chrome ids still resolve (untouched).
 *
 * argv[2]: a JSON file with a board `meta` object (may carry meta.mainLaunch).
 * argv[3]: optional "readonly" → sets writesActive=false before rendering, so the
 *          test can assert the band's STOP control is disabled on a view-only build.
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

// persistent registry so getElementById returns the SAME node across calls (the
// band host must be inspectable after render, and the fixed chrome ids resolve).
const REGISTRY = {};
["mainDeploy", "fileBtn", "conn", "repoMeta", "deployMainBtn",
 "versionBanner", "board", "status", "viewonly", "overlay", "overlayBody"]
  .forEach(function (id) { REGISTRY[id] = stubEl(); });

const documentStub = {
  getElementById(id) { return REGISTRY[id] || stubEl(); },
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

if (typeof sandbox.renderMainDeploy !== "function") {
  process.stderr.write("renderMainDeploy is not defined\n");
  process.exit(2);
}

const meta = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (process.argv[3] === "readonly") sandbox.writesActive = false;
// "stopping" → simulate a stop already in flight (■ STOP clicked): the running
// band must render a disabled ◐ STOPPING… segment, not a clickable STOP.
if (process.argv[3] === "stopping") sandbox.mainDeployStopping = true;

sandbox.renderMainDeploy(meta);

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
process.stdout.write(JSON.stringify({
  mainDeploy: project(REGISTRY.mainDeploy),
  // the ▸ Deploy Main button's display: "" when shown, "none" when the live
  // status has replaced it in-place (active deploy).
  deployMainBtnDisplay: REGISTRY.deployMainBtn.style.display || "",
  chrome: {
    fileBtn: !!REGISTRY.fileBtn,
    conn: !!REGISTRY.conn,
    repoMeta: !!REGISTRY.repoMeta,
    deployMainBtn: !!REGISTRY.deployMainBtn,
  },
}));
