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
 *                        rerender: bool,     // build the SAME card again after
 *                                            // the above, and project THAT
 *                        steps: [{...}],     // S196.1: a SEQUENCE of the four
 *                                            // above, so several rebuilds can
 *                                            // happen INSIDE one give-up
 *                                            // window; replaces the flat keys
 *                        emit: "full"}       // {tree, now, timers} instead of
 *                                            // the bare projected tree
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
  console, JSON, Math,
};
/* THE CLOCK. board.js's avatar give-up is a real `setTimeout`, and a stub that
   silently drops it would make the give-up path untestable AND make the "load
   cancels the timer" promise unfalsifiable. Timers are recorded here and fired
   on demand, so the 8s window is asserted in microseconds. */
const TIMERS = [];
let TIMER_ID = 0;
/* THE VIRTUAL WALL CLOCK. `setTimeout` alone cannot answer the question S196.1
   asks — "does a REBUILT node give up at the ORIGINAL deadline?" — because a
   deadline is a point in time and a recorded duration is not. So the harness
   owns `Date.now()` as well as the timer queue, and the two move together. */
let NOW = 0;
sandbox.setTimeout = function (fn, ms) {
  const d = Number(ms) || 0;
  TIMERS.push({ id: ++TIMER_ID, fn: fn, ms: d, at: NOW + d, dead: false });
  return TIMER_ID;
};
sandbox.clearTimeout = function (id) {
  for (const t of TIMERS) if (t.id === id) t.dead = true;
};
/* Advance the clock `ms`, firing every live timer whose DEADLINE falls inside
   the step, EARLIEST FIRST, with NOW set to that deadline as it fires — so a
   timer armed by a handler is armed against the same clock everything else
   reads, and two timers inside one step run in the order a browser would run
   them rather than in arming order. */
function advanceTimers(fromIndex, ms) {
  const target = NOW + (Number(ms) || 0);
  for (;;) {
    let next = null;
    for (let i = fromIndex; i < TIMERS.length; i++) {
      const t = TIMERS[i];
      if (t.dead || t.at > target) continue;
      if (!next || t.at < next.at) next = t;
    }
    if (!next) break;
    next.dead = true;
    if (next.at > NOW) NOW = next.at;
    try { next.fn(); } catch (e) { /* a stub-driven boot timer is not the subject */ }
  }
  NOW = target;
}
/* `Date` on the virtual clock. board.js records the give-up DEADLINE as an
   absolute `Date.now() + AVATAR_GIVE_UP_MS`; against the host clock that would
   make the give-up untestable all over again — the very thing the recorded
   timer queue exists to prevent. Everything else about Date is inherited. */
class VirtualDate extends Date {
  constructor(...a) { if (a.length === 0) super(NOW); else super(...a); }
  static now() { return NOW; }
}
sandbox.Date = VirtualDate;

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
function fireLoad(node) {
  let fired = 0;
  walk(node, function (n) {
    if (n.tag !== "img") return;
    (n._handlers.load || []).forEach(function (fn) { fired++; fn.call(n, {}); });
  });
  if (!fired) process.stderr.write("no image load handler was fired\n");
}
function fireError(node) {
  let fired = 0;
  walk(node, function (n) {
    if (n.tag !== "img") return;
    (n._handlers.error || []).forEach(function (fn) { fired++; fn.call(n, {}); });
    if (typeof n.onerror === "function") { fired++; n.onerror.call(n, {}); }
  });
  if (!fired) process.stderr.write("no image error handler was fired\n");
}

let subject = card;
if (Array.isArray(spec.steps)) {
  /* THE SEQUENCE. One `advanceMs` and one `rerender` cannot express the defect
     S196.1 cures: the board rebuilds the `.beam` node every 3.4–5.6s during a
     mission, so the question is what happens to the give-up window across
     SEVERAL rebuilds INSIDE one window. Each step may fire the portrait's own
     events, move the clock, and then repaint — in that order, which is the
     order a real tick takes them in. */
  for (const st of spec.steps) {
    if (st.loadAvatar) fireLoad(subject);
    if (st.killAvatar) fireError(subject);
    if (st.advanceMs) advanceTimers(TIMER_MARK, Number(st.advanceMs));
    if (st.rerender) subject = sandbox.cardNode(spec.mission);
  }
} else {
  if (spec.loadAvatar) fireLoad(card);
  if (spec.killAvatar) fireError(card);
  // THE CLOCK MOVES. The give-up window is the only thing standing between a
  // portrait that never arrives and a pad that hums for ever.
  if (spec.advanceMs) advanceTimers(TIMER_MARK, Number(spec.advanceMs));
  // RE-RENDER. Same mission, same process, after whatever happened above — the
  // only way to see whether the beam replays on a card the board simply
  // repainted.
  if (spec.rerender) subject = sandbox.cardNode(spec.mission);
}

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
/* A TIMER LEDGER, because "the pad gave up on time" and "the board is not
   quietly hoarding one abandoned 8s timer per repaint" are two different
   promises and only one of them is visible in the DOM. */
function timerStats() {
  let armed = 0, live = 0;
  for (let i = TIMER_MARK; i < TIMERS.length; i++) {
    armed++;
    if (!TIMERS[i].dead) live++;
  }
  return { armed: armed, live: live };
}

if (spec.emit === "full") {
  process.stdout.write(JSON.stringify(
    { tree: project(subject), now: NOW, timers: timerStats() }));
} else {
  process.stdout.write(JSON.stringify(project(subject)));
}
