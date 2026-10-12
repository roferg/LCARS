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
 *   "board"   render(board) → the WHOLE #board subtree, projected (S278). The
 *             Done column's cards are built by render() and by nothing else,
 *             and the "+ more on GitHub" row only exists inside that loop, so
 *             neither can be reached by calling a builder directly. `tree` is
 *             the projection; `hrefs` is the same board's anchors.
 *
 * Both modes go through render(board) and NEVER call renderMeta directly: the
 * board's forge identity has to be captured by the render the product actually
 * performs. Measured 2026-08-03, it was not — renderMeta ran at the END of
 * render(), after the cards were built, so on the FIRST paint the logged-bug
 * badge had no repo to build a URL from and rendered as a plain <span>. A
 * harness that primed the globals itself would never have seen that.
 *
 * Output (stdout): JSON { hrefs: [...], badgeHref, badgeTag, tree,
 *   emptyState, opened, bootErrors }
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
    _handlers: {},
    addEventListener(ev, fn) {
      (node._handlers[ev] = node._handlers[ev] || []).push(fn);
    },
    removeEventListener() {},
    appendChild(c) { node.children.push(c); return c; },
    insertBefore(c) { node.children.push(c); return c; },
    removeChild(c) {
      const i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      return c;
    },
    /* S278: attributes are RECORDED, not dropped. `data-mid` is the handle the
       keyboard deck and this harness both resolve a card by, and a no-op
       setAttribute made the card that was built unidentifiable. */
    attrs: {},
    setAttribute(k, v) { node.attrs[String(k)] = String(v); },
    removeAttribute(k) { delete node.attrs[String(k)]; },
    replaceChildren() { node.children = []; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute(k) {
      return Object.prototype.hasOwnProperty.call(node.attrs, k)
        ? node.attrs[k] : null;
    },
    closest() { return null; },
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

/* S278 — the projection the Done-column tests read. Tag, class, text, href and
   `disabled` are exactly the five things "is there a live control on this card?"
   and "does this row link where it says" are asked of; nothing else is emitted,
   so the projection cannot quietly become the assertion. */
function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "", cls: n._cls || "", text: n._text || "",
    href: n.href || "", title: n.title || "",
    disabled: !!n.disabled, attrs: n.attrs || null,
    clicks: ((n._handlers && n._handlers.click) || []).length,
    children: (n.children || []).map(project).filter(Boolean),
  };
}

/* THE CAPTAIN CLICKS A DONE CARD. There is no local detail for it, so the click
   has to reach the issue — and `window.open` is the only thing that can say so.
   Recorded rather than stubbed away: a handler that exists proves nothing about
   where it goes. */
const OPENED = [];
sandbox.open = function (url, target, feats) {
  OPENED.push({ url: String(url || ""), target: String(target || ""),
                features: String(feats || "") });
  return null;
};

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const mode = process.argv[3] || "detail";
const out = { hrefs: [], badgeHref: null, badgeTag: null, tree: null,
              opened: OPENED, bootErrors: bootErrors };

try {
  // ONE render of the real board — the same call the daemon's payload arrives
  // through. Nothing here primes the module globals by hand.
  sandbox.render(spec.board);
  if (mode === "detail") {
    sandbox.renderDetail(spec.mission);
    out.hrefs = hrefs(captured.node);
  } else if (mode === "board") {
    out.tree = project(byId.board);
    out.hrefs = hrefs(byId.board);
    /* S278 fix round 1 (D1) — THE FIRST-RUN BANNER, as render() left it. The
       banner and the cards are painted by the SAME render(), and the defect was
       that they disagreed: 51 cards drawn and the banner still claiming the
       board was empty. Only a projection taken from the same pass can catch
       that, so it is read off the memoized #boardEmpty node render() wrote
       into, never from a second call to renderEmptyState(). */
    out.emptyState = byId.boardEmpty
      ? { hidden: !!byId.boardEmpty.hidden,
          text: (function collect(n) {
            if (!n || typeof n !== "object") return "";
            var t = n._text || "";
            (n.children || []).forEach(function (c) { t += " " + collect(c); });
            return t;
          })(byId.boardEmpty).trim() }
      : null;
    // …and then CLICK what the spec named, through the node's own handler, with
    // the event object board.js expects. `clickCard` is a card's `data-mid`.
    if (spec.clickCard) {
      const want = String(spec.clickCard);
      (function walk(n) {
        if (!n || typeof n !== "object") return;
        if (/(^| )card( |$)/.test(n._cls || "")
            && (n.attrs || {})["data-mid"] === want) {
          (n._handlers.click || []).forEach(function (fn) {
            fn.call(n, { stopPropagation() {}, preventDefault() {} });
          });
        }
        (n.children || []).forEach(walk);
      })(byId.board);
    }
    /* …and the KEYBOARD's door. The command deck's Enter resolves a card's
       `data-mid` and calls openDetail DIRECTLY — it never touches the card's own
       click handler — so "the click opens the issue" and "Enter opens the issue"
       are two different claims, and this makes the second one checkable. */
    if (spec.openDetail && typeof sandbox.openDetail === "function") {
      sandbox.openDetail(String(spec.openDetail));
    }
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
