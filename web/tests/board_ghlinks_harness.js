"use strict";
/* S168 — "view on GitHub" LINK harness. Loads the SHIPPING web/static/board.js in
 * a sandboxed vm (no DOM, no build step — ADR-007) and drives the REAL builders,
 * then reads the `href` the board actually assigned to each anchor.
 *
 * The bug it locks: both link builders concatenated a LITERAL
 * "https://github.com/", so on a GitHub Enterprise repo every link the captain
 * clicked went to a github.com repository that does not exist.
 *
 * WHAT THIS CANNOT SEE, said plainly: it calls the builders itself, so it would
 * stay green against a daemon that never sends `meta.ghHost` at all — the exact
 * S163 blind spot (1,162 harness tests green over a blank board, because every
 * harness calls render() itself). The daemon→page delivery is proven in real
 * Chrome by tests/drives/browser/ghe-links.sh, not here.
 *
 * argv[2]: a JSON file — { board: {...}, mission: {...} }
 * argv[3]: mode —
 *   "detail"  render(board) → renderDetail(mission) → every anchor href.
 *   "logbug"  render(board) → logBugBadge(mission) → the badge's href.
 *
 * Both modes go through render(board) and NEVER call renderMeta directly: the
 * board's forge identity has to be captured by the render the product actually
 * performs. Measured 2026-08-03, it was not — renderMeta ran at the END of
 * render(), after the cards were built, so on the FIRST paint the logged-bug
 * badge had no repo to build a URL from and rendered as a plain <span>. A
 * harness that primed the globals itself would never have seen that.
 *
 * Output (stdout): JSON { hrefs: [...], badgeHref, badgeTag, bootErrors }
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function stubEl(tag) {
  const node = {
    tag: tag || "",
    style: {},
    dataset: {},
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
    replaceChildren() { node.children = []; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, closest() { return null; },
    contains() { return false; },
    focus() {}, blur() {}, click() {}, remove() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
    href: "", target: "", rel: "",
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

const captured = { node: null, count: 0 };
const byId = Object.create(null);

const sandbox = {
  console: console,
  document: {
    addEventListener() {}, removeEventListener() {},
    // MEMOIZED per id, so the node render() paints into is the same node this
    // harness can then walk. A fresh stub per call would hand back an empty
    // board and quietly make the logbug mode unable to observe anything.
    getElementById(id) {
      return byId[id] || (byId[id] = stubEl("div"));
    },
    querySelector() { return null; },
    querySelectorAll() { return []; },
    createElement(t) { return stubEl(t); },
    createTextNode(t) { const n = stubEl("#text"); n._text = t; return n; },
    body: stubEl("body"),
    documentElement: stubEl("html"),
  },
  window: null,
  location: { href: "", search: "", pathname: "/", origin: "http://x" },
  navigator: { userAgent: "test" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  fetch() {
    const p = { then() { return p; }, catch() { return p; },
                finally() { return p; } };
    return p;
  },
  EventSource: function () { return { addEventListener() {}, close() {} }; },
  setTimeout() { return 0; }, clearTimeout() {},
  setInterval() { return 0; }, clearInterval() {},
  requestAnimationFrame() { return 0; },
  JSON: JSON, Math: Math, Date: Date, Object: Object, Array: Array,
  String: String, Number: Number, Boolean: Boolean, RegExp: RegExp,
  Promise: Promise, Error: Error, encodeURIComponent, decodeURIComponent,
  isNaN, parseFloat, parseInt,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const bootErrors = [];
const src = fs.readFileSync(
  path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) {
  bootErrors.push(String(e && e.message));
}

/* showOverlay is how renderDetail hands its built node to the page. */
if (typeof sandbox.showOverlay === "function") {
  sandbox.showOverlay = function (node) { captured.node = node; captured.count++; };
}

function hrefs(n, acc) {
  acc = acc || [];
  if (!n || typeof n !== "object") return acc;
  if (n.href) acc.push({ tag: n.tag, cls: n._cls || "", text: n._text || "",
                         href: n.href });
  (n.children || []).forEach((c) => hrefs(c, acc));
  return acc;
}

function find(n, pred) {
  if (!n || typeof n !== "object") return null;
  if (pred(n)) return n;
  const kids = n.children || [];
  for (let i = 0; i < kids.length; i++) {
    const hit = find(kids[i], pred);
    if (hit) return hit;
  }
  return null;
}

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const mode = process.argv[3] || "detail";
const out = { hrefs: [], badgeHref: null, badgeTag: null,
              bootErrors: bootErrors };

try {
  // ONE render of the real board — the same call the daemon's payload arrives
  // through. Nothing here primes the module globals by hand.
  sandbox.render(spec.board);
  if (mode === "detail") {
    sandbox.renderDetail(spec.mission);
    out.hrefs = hrefs(captured.node);
  } else if (mode === "logbug") {
    // The badge as RENDER BUILT IT, dug out of the board root — never a second
    // call to logBugBadge(). Calling it again would run it with the globals
    // render() has since populated, which is exactly the ordering the product
    // gets wrong on a first paint.
    const badge = find(byId.board, (n) => /logbug-badge/.test(n._cls || ""));
    out.badgeTag = badge && badge.tag;
    out.badgeHref = (badge && badge.href) || null;
    out.badgeText = badge && badge._text;
    out.hrefs = hrefs(badge);
  }
} catch (e) {
  out.bootErrors.push(String((e && e.stack) || e));
}

process.stdout.write(JSON.stringify(out));
