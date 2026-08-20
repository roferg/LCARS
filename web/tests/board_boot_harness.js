"use strict";
/* ══ S163 fix round 7 (D1) — the PRODUCT'S OWN paint path, end to end ══════════
 *
 * WHY THIS HARNESS EXISTS. Every other board harness in this directory calls a
 * render function BY HAND — `cardNode(m)`, `renderMainDeploy(meta)`,
 * `render(board)`. That is the right shape for asking "does this card draw the
 * right badge?", and 1137 of them were green while the shipping board was a
 * PERMANENTLY BLANK PAGE: fix round 5 deleted the `.then(render)` out of
 * `refresh()` while inserting an explanatory comment in its place, so the app
 * fetched a perfectly good payload eight times in thirty seconds and drew
 * nothing. Not one test could tell the difference, because not one test ever
 * asked the app to paint itself. It took a real Chrome to see it.
 *
 * So this harness NEVER calls render(). It loads the SHIPPING board.js exactly
 * as the browser does — boot statements and all — hands it a fetch that
 * resolves a real board payload, and then asks the DOM what appeared. Every
 * link in the chain is therefore load-bearing:
 *
 *     boot `refresh()`  →  fetch("/api/board")  →  .json()  →  render(payload)
 *          →  #board gains column + card nodes
 *
 * plus the two LIVE paths `connect()` installs (BUG-065), which are the only
 * reason a board that was up when a mission changed ever shows the change:
 *
 *     setInterval(refresh, LIVE_POLL_MS)      the safety poll
 *     EventSource("/api/events") "update"     the SSE push
 *
 * Cut any one of those and a mode below goes red.
 *
 * WHAT IT DOES NOT COVER — say it plainly, because the last blind spot was
 * built out of an unstated assumption. This is a node `vm` with hand-written
 * DOM stubs, not a browser: it cannot see CSS (a card painted `display:none`
 * still counts here), it cannot see layout, paint or z-order, and it cannot
 * catch a syntax error that only some engine rejects. It proves the WIRING is
 * connected and that real payload data reaches real DOM nodes. It does not
 * prove the result is legible. The round's tester eyeball in real Chrome
 * remains the check for that.
 *
 * argv[2]: JSON file — {board: <payload>, board2: <payload>} (board2 optional,
 *          used by the live modes as the "something changed" second payload).
 * argv[3]: mode —
 *          "boot" (default) load board.js and let ITS boot paint the board;
 *          "poll"           boot, swap in board2, fire the safety-poll callback;
 *          "sse"            boot, swap in board2, fire the SSE `update` listener;
 *          "fail"           boot with a fetch that REJECTS (the .catch path);
 *          "pollsame"       boot, fire the safety poll with the SAME payload
 *                           (S176: nothing changed — the board must not repaint);
 *          "burst"          boot, then poll board2 then board3 (S176: the
 *                           reconcile write-burst the safety poll exists for —
 *                           every DIFFERENT payload must still repaint);
 *          "failthenpoll"   boot with a REJECTING fetch, then recover and poll
 *                           the SAME payload (S176: the skip must not strand a
 *                           board that never painted, or a status line stuck on
 *                           "board unavailable").
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
    // S176: count the teardown writes. render() opens with `root.innerHTML = ""`
    // and rebuilds every column, so on the #board node this counter IS the
    // number of full board repaints — the thing the change check exists to stop
    // doing for nothing. Counting it here (rather than wrapping render) keeps
    // the harness's rule intact: it never calls a render function by hand.
    set(v) {
      node._htmlWrites = (node._htmlWrites || 0) + 1;
      node._html = v;
      if (v === "") node.children = [];
    },
  });
  return node;
}

// Persistent registry: getElementById must return the SAME node every call, or
// render() would paint into a throwaway and the assertions would read an empty
// one — an artificial red that hides the real question.
const REGISTRY = {};
["board", "status", "conn", "fileBtn", "deployMainBtn", "helpBtn", "mainDeploy",
 "repoMeta", "versionBanner", "viewonly", "overlay", "overlayBody",
 "emptyState", "testReadiness"]
  .forEach(function (id) { REGISTRY[id] = stubEl(id); });

const documentStub = {
  getElementById(id) {
    if (!REGISTRY[id]) REGISTRY[id] = stubEl(id);
    return REGISTRY[id];
  },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { var n = stubEl("#text"); n._text = t; return n; },
  addEventListener() {},
  body: stubEl("body"),
};

const payloads = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const mode = process.argv[3] || "boot";

// ── the seams this harness watches ──────────────────────────────────────────
const FETCHED = [];          // every URL the page asked for, in order
let SERVE = payloads.board;  // what /api/board answers with right now
// "failthenpoll" starts broken too — it recovers below, after boot has failed.
let FETCH_FAILS = mode === "fail" || mode === "failthenpoll";
const INTERVALS = [];        // [fn, ms] the page installed
const SSE = { url: null, listeners: Object.create(null) };

function fetchStub(url, opts) {
  FETCHED.push(String(url));
  if (FETCH_FAILS) return Promise.reject(new Error("network down"));
  // Only /api/board is modelled; anything else (probeWrites' HEAD, etc.) gets a
  // benign empty object so boot does not explode on the way past.
  const body = String(url).indexOf("/api/board") === 0 ? SERVE : {};
  return Promise.resolve({
    ok: true, status: 200,
    json() { return Promise.resolve(body); },
    text() { return Promise.resolve(JSON.stringify(body)); },
  });
}

const sandbox = {
  document: documentStub,
  location: { href: "http://127.0.0.1/", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval(fn, ms) { INTERVALS.push([fn, ms]); return INTERVALS.length; },
  clearInterval() {},
  setTimeout() { return 0; }, clearTimeout() {},
  fetch: fetchStub,
  EventSource: function (url) {
    SSE.url = String(url);
    this.addEventListener = function (evt, fn) { SSE.listeners[evt] = fn; };
    this.close = function () {};
  },
  console, JSON, Math, Date, Promise,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const src = fs.readFileSync(path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
let bootError = "";
try {
  // NOTE: no hand-call of render() anywhere in this file. Running the source IS
  // the boot — board.js ends in `refresh(); connect(); probeWrites();`.
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) {
  bootError = String((e && e.message) || e);
}

function project(n, depth) {
  if (!n || typeof n !== "object") return null;
  if ((depth || 0) > 12) return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    disabled: !!n.disabled,
    children: (n.children || []).map(function (c) {
      return project(c, (depth || 0) + 1);
    }).filter(Boolean),
  };
}

// Let the fetch promise chain settle. Several turns, because refresh() is
// fetch → .json() → render, i.e. at least two microtask hops.
function settle() {
  return new Promise(function (resolve) { setImmediate(resolve); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); })
    .then(function () { return new Promise(function (r) { setImmediate(r); }); });
}

function firePoll() {
  INTERVALS.forEach(function (pair) {
    if (typeof pair[0] === "function") pair[0]();
  });
}

settle().then(function () {
  if (mode === "failthenpoll") {
    // The daemon comes back. The payload is byte-identical to the one that
    // never arrived — so "unchanged" must NOT mean "nothing to do" here.
    FETCH_FAILS = false;
    firePoll();
    return settle();
  }
  if (mode === "pollsame") {
    // NOTHING changed on the server. SERVE is left exactly as it was.
    firePoll();
    return settle();
  }
  if (mode === "burst") {
    // A mission reconciling through several rapid state writes — the case the
    // safety poll was added for (SSE is debounced and only emits once writes
    // STOP). Each payload genuinely differs, so each must repaint.
    SERVE = payloads.board2 || payloads.board;
    firePoll();
    return settle().then(function () {
      SERVE = payloads.board3 || payloads.board2 || payloads.board;
      firePoll();
      return settle();
    });
  }
  if (mode === "poll" || mode === "sse") {
    // Something on the board changed. Only the live wiring can show it.
    SERVE = payloads.board2 || payloads.board;
    if (mode === "poll") {
      // The safety poll's callback, exactly as the browser's timer would fire
      // it. `connect()` installs it as setInterval(refresh, LIVE_POLL_MS).
      firePoll();
    } else {
      const fn = SSE.listeners.update;
      if (typeof fn === "function") fn({ data: "" });
    }
    return settle();
  }
}).then(function () {
  process.stdout.write(JSON.stringify({
    bootError: bootError,
    fetched: FETCHED,
    boardFetches: FETCHED.filter(function (u) {
      return u.indexOf("/api/board") === 0;
    }).length,
    board: project(REGISTRY.board),
    // S176: how many times render() tore the board down and rebuilt it.
    boardPaints: REGISTRY.board._htmlWrites || 0,
    status: REGISTRY.status._text || "",
    statusClass: REGISTRY.status._cls || "",
    intervals: INTERVALS.map(function (p) { return p[1]; }),
    sseUrl: SSE.url,
    sseEvents: Object.keys(SSE.listeners),
  }));
});
