"use strict";
/* S213 — the ◈ NUMBER ONE TAB, in a sandboxed vm.
 *
 * Loads the SHIPPING web/static/board.js and calls the real `detailTabs(mi)`
 * and `xoReportPane(mi)` against a mission-detail payload, then projects the
 * produced DOM to inspectable JSON — IN DOCUMENT ORDER, because the order is
 * the whole claim. The fault this session exists to kill was not a missing
 * fact; it was the RIGHT facts in the WRONG ORDER: the tab led with "Also
 * checked, fine — no gaps found on this look" above a MEDIUM score whose real
 * finding was that nothing could be tested at all.
 *
 * A NODE DOM IS A STUB OF A BROWSER and this harness is no exception — it
 * proves the WIRING and the ORDER; a real browser is the tester's job.
 *
 * argv[2]: a JSON file with a mission DETAIL object (`mi`).
 * argv[3]: OPTIONAL inline JSON for the BOARD payload (S224). The pane counts
 *          how many of the bugs Number One filed are fixed by looking up each
 *          filed bug's child Mission and reading its recorded STAGE off the
 *          board — so a test about that count has to be able to plant one.
 *          Absent ⇒ no board, exactly as it is on a page that never rendered.
 * stdout:  { pane: <projected xoReportPane tree>,
 *            tabs: [tab labels in bar order],
 *            paneText: [every non-empty text node, in document order] }
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function stubEl(tag) {
  var node = {
    tag: tag || "",
    style: {},
    attrs: {},
    /* classList and className are ONE list, as they are in a browser: board.js
       sets `className` at construction and then calls `classList.add`, so a
       stub that kept two separate lists would silently drop the first — which
       is exactly how an earlier version of this harness lost the ◈ Number One
       tab from its own projection. */
    classList: {
      add(c) {
        const cur = String(node._cls || "").split(/\s+/).filter(Boolean);
        if (cur.indexOf(c) < 0) cur.push(c);
        node._cls = cur.join(" ");
      },
      remove(c) {
        node._cls = String(node._cls || "").split(/\s+/)
          .filter(function (x) { return x && x !== c; }).join(" ");
      },
      toggle() { return false; },
      contains(c) {
        return String(node._cls || "").split(/\s+/).indexOf(c) >= 0;
      },
    },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { if (c) c.parentNode = node; node.children.push(c); return c; },
    removeChild() {},
    setAttribute(k, v) { node.attrs[k] = String(v); },
    removeAttribute(k) { delete node.attrs[k]; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(node.attrs, k) ? node.attrs[k] : null; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    focus() {},
    replaceWith() {},
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
  /* boot side-effects may throw against the stubs; the hoisted declarations
     we need are bound to the sandbox global by then. */
}

for (const name of ["xoReportPane", "detailTabs"]) {
  if (typeof sandbox[name] !== "function") {
    process.stderr.write(name + " is not defined\n");
    process.exit(2);
  }
}

const mission = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (process.argv[3]) {
  // `var LAST_BOARD` in board.js is a property of the sandbox global, so this
  // plants the very payload the shipping code reads — no shim in between.
  sandbox.LAST_BOARD = JSON.parse(process.argv[3]);
}
const pane = sandbox.xoReportPane(mission);
let tabs = [];
try {
  const t = sandbox.detailTabs(mission);
  (function walk(n) {
    if (!n) return;
    if ((" " + (n._cls || "") + " ").indexOf(" tab ") >= 0) {
      tabs.push({ text: n._text || "", key: n.getAttribute("data-tab") || "" });
    }
    (n.children || []).forEach(walk);
  })(t);
} catch (e) {
  tabs = [{ text: "ERROR: " + (e && e.message ? e.message : e), key: "" }];
}

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    // A block board.js fills through setMd() has NO child text nodes — its
    // words live in innerHTML. Projecting only textContent would have made
    // the full verdict invisible to every assertion about it.
    text: n._text || stripTags(n._html || ""),
    title: n.title || "",
    // S224: the bar's segments are sized by an inline width, so a claim about
    // TWO BARS ON ONE SCALE has to be able to read it. (The cascade still
    // belongs to the browser drive; this is the value the code set.)
    style: Object.assign({}, n.style || {}),
    // S224 fix round 1 (D4): the picture a row points AT. The captain's board
    // drew "isn't on this laptop any more" over files that were on his disk,
    // because the URL was composed against the wrong look's directory — a
    // claim about which directory a thumbnail asks for cannot be made without
    // reading the value the code set on it.
    src: n.src || "",
    // S223 fix round 1 (D2): a row is identified by its own `data-id`, so an
    // assertion names the requirement it is about rather than an index.
    attrs: n.attrs || {},
    children: (n.children || []).map(project).filter(Boolean),
  };
}

function stripTags(html) {
  return String(html).replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
}

const text = [];
(function collect(n) {
  if (!n) return;
  const own = n._text || stripTags(n._html || "");
  if (own && String(own).trim()) text.push(String(own).trim());
  (n.children || []).forEach(collect);
})(pane);

process.stdout.write(JSON.stringify({
  pane: project(pane),
  tabs: tabs,
  paneText: text,
}));
