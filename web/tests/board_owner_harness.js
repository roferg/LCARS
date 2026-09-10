"use strict";
/* S190 owner/avatar/light-lock card-render harness.
 *
 * Loads the SHIPPING web/static/board.js in a sandboxed vm with minimal browser
 * stubs, calls the real cardNode(m), and projects the produced DOM tree to
 * inspectable JSON so the Python test can assert the avatar + handle treatment
 * and the disabled write affordances without a DOM or a build step (ADR-007).
 *
 * It differs from board_card_harness.js in exactly three ways, and each one is
 * load-bearing for THIS session:
 *
 *   - it projects `attrs` (setAttribute is a no-op in the other harness), so the
 *     avatar's src/alt can be asserted rather than assumed;
 *   - it projects `title` and `hidden`, which carry the lock tooltip and the
 *     dead-image degrade;
 *   - it can FIRE an element's error handler, so the dead-src fallback is driven
 *     the way a broken image drives it, not asserted from the markup;
 *   - it OWNS THE CLOCK (S196 beam). `setTimeout` is recorded rather than
 *     dropped, so the avatar's give-up window can be advanced deterministically
 *     instead of slept through, and the card can be RE-RENDERED in the same
 *     process so "the beam does not replay" is a thing the harness can see at
 *     all. A fresh subprocess per render cannot answer that question.
 *
 * A projected class name is NOT proof that an avatar rendered — a dead <img> has
 * the same box and class as a live one (the S164 legend-swatch lesson). This
 * harness proves the WIRING; the tester proves the PICTURE in real Chrome at
 * real rendered dimensions. Both are required.
 *
 * argv[2]: a JSON file: {mission: <card>, self: "<login>"|null,
 *                        readonly: bool, killAvatar: bool,
 *                        loadAvatar: bool,   // fire the <img>'s own load event
 *                        advanceMs: <int>,   // run the card's timers that far
 *                        rerender: bool}     // build the SAME card again after
 *                                            // the above, and project THAT
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function stubEl(tag) {
  var node = {
    tag: tag || "",
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
    appendChild(c) { node.children.push(c); return c; },
    removeChild(c) {
      var i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      return c;
    },
    setAttribute(k, v) { node.attrs[String(k)] = String(v); },
    removeAttribute(k) { delete node.attrs[String(k)]; },
    getAttribute(k) { return Object.prototype.hasOwnProperty.call(node.attrs, k) ? node.attrs[k] : null; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    focus() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
    parentNode: null,
  };
  var _append = node.appendChild;
  node.appendChild = function (c) { if (c) c.parentNode = node; return _append(c); };
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
  // src/alt are real attributes on an <img>; mirror assignment into attrs so the
  // projection sees whichever way board.js sets them.
  ["src", "alt", "width", "height", "loading", "referrerPolicy"].forEach(function (p) {
    Object.defineProperty(node, p, {
      get() { return node.attrs[p] === undefined ? "" : node.attrs[p]; },
      set(v) { node.attrs[p] = String(v); },
    });
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
  fetch() { const p = { then() { return p; }, catch() { return p; } }; return p; },
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date,
};
/* THE CLOCK. board.js's avatar give-up is a real `setTimeout`, and a stub that
   silently drops it would make the give-up path untestable AND make the "load
   cancels the timer" promise unfalsifiable. Timers are recorded here and fired
   on demand, so the 8s window is asserted in microseconds. */
const TIMERS = [];
let TIMER_ID = 0;
sandbox.setTimeout = function (fn, ms) {
  TIMERS.push({ id: ++TIMER_ID, fn: fn, ms: Number(ms) || 0, dead: false });
  return TIMER_ID;
};
sandbox.clearTimeout = function (id) {
  for (const t of TIMERS) if (t.id === id) t.dead = true;
};
function advanceTimers(fromIndex, ms) {
  for (let i = fromIndex; i < TIMERS.length; i++) {
    const t = TIMERS[i];
    if (t.dead || t.ms > ms) continue;
    t.dead = true;
    try { t.fn(); } catch (e) { /* a stub-driven boot timer is not the subject */ }
  }
}

sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const src = fs.readFileSync(path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) {
  /* boot side-effects may throw against the stubs; the hoisted declarations we
     need are already bound to the sandbox global by then. */
}

if (typeof sandbox.cardNode !== "function") {
  process.stderr.write("cardNode is not defined\n");
  process.exit(2);
}

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

// The board captures identity from board.meta BEFORE any card is built (see
// render()). Drive the real capture path rather than poking a variable, so this
// harness cannot pass while the product's own wiring is broken.
if (typeof sandbox.captureForgeIdentity === "function") {
  sandbox.captureForgeIdentity({
    repo: "acme/repo",
    self: spec.self ? { login: spec.self } : undefined,
  });
}
if (spec.readonly) sandbox.writesActive = false;

// Only the timers THIS card arms may be advanced; boot side-effects against the
// stubs are not the subject and firing them would be noise, not signal.
const TIMER_MARK = TIMERS.length;
const card = sandbox.cardNode(spec.mission);

// KILL THE AVATAR the way a broken URL kills it: fire the element's own error
// handler. Asserting the handler exists would prove nothing about what it does.
function walk(n, fn) {
  if (!n || typeof n !== "object") return;
  fn(n);
  (n.children || []).forEach(function (c) { walk(c, fn); });
}
// THE PORTRAIT ARRIVES. Fired through the element's own `load`, the way the
// network fires it — asserting the handler exists proves nothing about what it
// does, and this is the event the whole beam hangs off.
if (spec.loadAvatar) {
  let fired = 0;
  walk(card, function (n) {
    if (n.tag !== "img") return;
    (n._handlers.load || []).forEach(function (fn) { fired++; fn.call(n, {}); });
  });
  if (!fired) process.stderr.write("no image load handler was fired\n");
}

if (spec.killAvatar) {
  var fired = 0;
  walk(card, function (n) {
    if (n.tag !== "img") return;
    (n._handlers.error || []).forEach(function (fn) { fired++; fn.call(n, {}); });
    if (typeof n.onerror === "function") { fired++; n.onerror.call(n, {}); }
  });
  if (!fired) process.stderr.write("no image error handler was fired\n");
}

// THE CLOCK MOVES. The give-up window is the only thing standing between a
// portrait that never arrives and a pad that hums for ever.
if (spec.advanceMs) advanceTimers(TIMER_MARK, Number(spec.advanceMs));

// RE-RENDER. Same mission, same process, after whatever happened above — the
// only way to see whether the beam replays on a card the board simply repainted.
const subject = spec.rerender ? sandbox.cardNode(spec.mission) : card;

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    title: n.title || "",
    hidden: !!n.hidden,
    disabled: !!n.disabled,
    attrs: n.attrs || {},
    children: (n.children || []).map(project).filter(Boolean),
  };
}
process.stdout.write(JSON.stringify(project(subject)));
