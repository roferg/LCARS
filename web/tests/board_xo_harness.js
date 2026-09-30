"use strict";
/* S201 — the BAND half of Number One, in a sandboxed vm.
 *
 * Loads the SHIPPING web/static/board.js and calls the real `renderXoBand(meta)`
 * and `renderXoLegend(meta)`, then (optionally) CLICKS the toggle and the
 * picker's confirm, projecting the toggle, the legend, the picker and every
 * POST the board tried to make.
 *
 * It is the sibling of board_band_harness.js (which drives renderMainDeploy) and
 * it exists for the same reason: the band is not a card, so the card harnesses
 * cannot reach it, and a real browser is the tester's job — this proves the
 * WIRING, the tester proves the PICTURE.
 *
 * THE POSTS ARE THE POINT. A band toggle that paints correctly and posts to the
 * wrong endpoint is a control that lies, so `fetch` is recorded rather than
 * stubbed away, and the recorded list is projected beside the DOM.
 *
 * argv[2]: a JSON file
 *   { "meta":     <board.meta>,            // may carry numberOne / enginesHere
 *     "readonly": true,                    // writesActive=false before render
 *     "click":    "toggle"|"engage"|"off"  // toggle: press the band control
 *                                          // engage: press it, then ◈ Engage
 *                                          // off:    press it (ON → repo off)
 *   }
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const POSTS = [];

function stubEl(tag) {
  const node = {
    tag: String(tag || ""),
    tagName: String(tag || "").toUpperCase(),
    style: {},
    attrs: {},
    classList: {
      _s: {},
      add(c) { this._s[c] = true; },
      remove(c) { delete this._s[c]; },
      toggle() { return false; },
      contains(c) { return !!this._s[c]; },
    },
    _handlers: {},
    addEventListener(ev, fn) { (node._handlers[ev] = node._handlers[ev] || []).push(fn); },
    removeEventListener() {},
    appendChild(c) { if (c) c.parentNode = node; node.children.push(c); return c; },
    insertBefore(c, ref) {
      if (c) c.parentNode = node;
      const i = node.children.indexOf(ref);
      if (i < 0) node.children.push(c); else node.children.splice(i, 0, c);
      return c;
    },
    removeChild(c) {
      const i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      if (c) c.parentNode = null;
      return c;
    },
    setAttribute(k, v) { node.attrs[String(k)] = String(v); },
    removeAttribute(k) { delete node.attrs[String(k)]; },
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(node.attrs, k) ? node.attrs[k] : null;
    },
    querySelector(sel) { const h = node.querySelectorAll(sel); return h.length ? h[0] : null; },
    /* A DELIBERATELY NARROW selector engine: `.cls` only, which is every
       selector the S201 band code uses. Anything richer would be a second
       implementation of a browser, and a wrong one. */
    querySelectorAll(sel) {
      const want = String(sel || "").replace(/^\./, "");
      const out = [];
      (function walk(n) {
        for (const c of n.children || []) {
          if ((" " + String(c._cls || "") + " ").indexOf(" " + want + " ") >= 0) out.push(c);
          walk(c);
        }
      })(node);
      return out;
    },
    focus() {},
    click() { (node._handlers.click || []).forEach((fn) => fn({ stopPropagation() {} }));
              if (typeof node.onclick === "function") node.onclick({ stopPropagation() {} }); },
    children: [], _text: "", title: "", hidden: false, disabled: false,
    parentNode: null, onclick: null,
  };
  Object.defineProperty(node, "lastChild", {
    get() { return node.children.length ? node.children[node.children.length - 1] : null; },
  });
  Object.defineProperty(node, "firstChild", {
    get() { return node.children.length ? node.children[0] : null; },
  });
  Object.defineProperty(node, "className", {
    get() { return node._cls || ""; },
    set(v) { node._cls = v; },
  });
  Object.defineProperty(node, "textContent", {
    get() {
      if (node._text) return node._text;
      return (node.children || []).map((c) => c.textContent || "").join("");
    },
    set(v) { node._text = v == null ? "" : String(v); node.children = []; },
  });
  Object.defineProperty(node, "innerHTML", {
    get() { return node._html || ""; },
    set(v) { node._html = v; if (v === "") node.children = []; },
  });
  return node;
}

const REGISTRY = {};
["xoBtn", "deployMainBtn", "mainDeploy", "fileBtn", "helpBtn", "conn",
 "repoMeta", "versionBanner", "board", "status", "viewonly",
 "overlay", "overlayBody"].forEach((id) => {
  REGISTRY[id] = stubEl("div");
  REGISTRY[id].setAttribute("id", id);
});
REGISTRY.xoBtn = stubEl("button");
REGISTRY.xoBtn.setAttribute("id", "xoBtn");
REGISTRY.xoBtn.className = "btn xo-toggle";
REGISTRY.xoBtn.hidden = true;

const LEGEND = stubEl("div");
LEGEND.className = "legend";
LEGEND.appendChild(REGISTRY.status);
LEGEND.appendChild(REGISTRY.viewonly);
REGISTRY.overlay.hidden = true;

const documentStub = {
  nodeType: 9,
  createElement: stubEl,
  createTextNode(t) { const n = stubEl("#text"); n._text = String(t); return n; },
  getElementById(id) { return REGISTRY[id] || null; },
  querySelector(sel) {
    if (String(sel) === ".legend") return LEGEND;
    return LEGEND.querySelector(sel);
  },
  querySelectorAll(sel) { return LEGEND.querySelectorAll(sel); },
  addEventListener() {}, removeEventListener() {},
  body: stubEl("body"),
};

const sandbox = {
  console, setTimeout, clearTimeout, setInterval, clearInterval, Date, Math,
  JSON, encodeURIComponent, decodeURIComponent, String, Number, Object, Array,
  document: documentStub,
  window: { addEventListener() {}, location: { href: "", search: "" },
            matchMedia() { return { matches: false, addListener() {} }; } },
  location: { href: "", search: "" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  EventSource: function () { return { addEventListener() {}, close() {} }; },
  fetch(url, opts) {
    let body = {};
    try { body = JSON.parse((opts && opts.body) || "{}"); } catch (e) { body = {}; }
    POSTS.push([String(url), body]);
    // A resolved, well-formed success — the board refreshes off it and moves on.
    return Promise.resolve({
      status: 200,
      json() { return Promise.resolve({ ok: true, state: {} }); },
    });
  },
};
sandbox.globalThis = sandbox;
sandbox.self = sandbox;
vm.createContext(sandbox);

const SRC = path.join(__dirname, "..", "static", "board.js");
try {
  vm.runInContext(fs.readFileSync(SRC, "utf8"), sandbox, { filename: SRC });
} catch (e) {
  /* boot side-effects may throw against the stubs; the hoisted declarations we
     need are bound to the sandbox global by then. */
}

for (const name of ["renderXoBand", "renderXoLegend", "openXoPicker"]) {
  if (typeof sandbox[name] !== "function") {
    process.stderr.write(name + " is not defined\n");
    process.exit(2);
  }
}

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const meta = spec.meta || {};
if (spec.readonly) sandbox.writesActive = false;
else sandbox.writesActive = true;

sandbox.renderXoBand(meta);
sandbox.renderXoLegend(meta);

if (spec.click === "toggle" || spec.click === "engage" || spec.click === "off"
    || spec.click === "menu") {
  REGISTRY.xoBtn.click();
}
// S205: THE ON-STATE MENU ITSELF — captured BEFORE any follow-through click
// below would close it, so "menu" alone (an ENABLED mission) can inspect what
// actually opened.
const menuItemNodes = overlayNodes().filter(
  (n) => (" " + String(n._cls || "") + " ").indexOf(" xo-menu-item ") >= 0);
// S205: an ENGAGED band click now opens the small ON-state MENU (report /
// change engine / turn off) rather than dispatching a stand-down off the one
// click — so "toggle"/"off" against an ENABLED mission follow through to the
// menu's own "■ Turn off" item, reaching the SAME eventual POST the old
// direct-dispatch reached. A DISABLED-mission "toggle" (the engine picker)
// has no such item, so this is a no-op there.
if (spec.click === "toggle" || spec.click === "off") {
  const menuOff = menuItemNodes.filter(
    (n) => (n.textContent || "").indexOf("Turn off") >= 0);
  if (menuOff.length) menuOff[0].click();
}
if (spec.click === "engage") {
  const foot = pickerFoot();
  const engage = foot.filter((b) => (b.textContent || "").indexOf("Engage") >= 0);
  if (engage.length) engage[0].click();
}
// A repaint after the act, the way the next SSE tick repaints: the legend must
// not accumulate, so "off" re-renders with the toggle's post-state meta.
if (spec.click === "off") {
  const after = JSON.parse(JSON.stringify(meta));
  if (after.numberOne) after.numberOne.enabled = false;
  sandbox.renderXoBand(after);
  sandbox.renderXoLegend(after);
}

function overlayNodes() {
  const out = [];
  (function walk(n) {
    out.push(n);
    for (const c of n.children || []) walk(c);
  })(REGISTRY.overlayBody);
  return out;
}

function pickerRows() {
  return overlayNodes().filter(
    (n) => (" " + String(n._cls || "") + " ").indexOf(" xo-engine ") >= 0);
}

function pickerFoot() {
  const foots = overlayNodes().filter(
    (n) => (" " + String(n._cls || "") + " ").indexOf(" modal-foot ") >= 0);
  return foots.length ? foots[0].children.slice() : [];
}

const rows = pickerRows();
const open = !REGISTRY.overlay.hidden && rows.length > 0;

process.stdout.write(JSON.stringify({
  toggle: {
    text: REGISTRY.xoBtn.textContent || "",
    cls: REGISTRY.xoBtn.className || "",
    title: REGISTRY.xoBtn.title || "",
    hidden: !!REGISTRY.xoBtn.hidden,
    disabled: !!REGISTRY.xoBtn.disabled,
  },
  legend: LEGEND.children
    .filter((n) => (" " + String(n._cls || "") + " ").indexOf(" xo-legend ") >= 0)
    .map((n) => ({ text: (n.textContent || "").trim(), cls: n.className || "",
                   swatch: (n.children[0] || {}).className || "" })),
  picker: {
    open: open,
    engines: rows.map((r) => r.getAttribute("data-engine") || ""),
    rows: rows.map((r) => ({ text: r.textContent || "", cls: r.className || "",
                             disabled: !!r.disabled })),
    chosen: (rows.filter((r) => r.getAttribute("aria-pressed") === "true")
                 .map((r) => r.getAttribute("data-engine"))[0]) || "",
    foot: pickerFoot().map((b) => (b.textContent || "").trim()),
  },
  // S205: the ON-state menu, snapshotted BEFORE any follow-through click
  // ("toggle"/"off") would have closed it — so `click: "menu"` can inspect
  // what actually opened.
  menu: {
    open: !REGISTRY.overlay.hidden && menuItemNodes.length > 0,
    items: menuItemNodes.map((n) => (n.textContent || "").trim()),
  },
  /* ONLY NUMBER ONE'S OWN POSTS. board.js's boot probes `/api/board` and
     `/api/mission` against these stubs; those are not this harness's subject
     and a test that had to skip past them would be asserting on noise. */
  posts: POSTS.filter((p) => p[0].indexOf("/api/xo") === 0),
}));
/* EXIT EXPLICITLY. board.js's boot arms real intervals against these stubs and
   a live timer keeps node's event loop open for ever — the harness would print
   its report and then hang. */
process.exit(0);
