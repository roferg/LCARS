"use strict";
/* S157 × #93 — GATE-COPY harness. Loads the SHIPPING web/static/board.js in a
 * sandboxed vm (no DOM, no build step — ADR-007) and calls the REAL
 * whyCopyForGate() for each escalationType, so the card's "Why you're seeing
 * this" line is asserted from the shipping source rather than a transcription.
 *
 * It exists because the harness gained a NEW escalationType ("environment") that
 * the board had never seen. The default branch caught it safely, but the generic
 * copy it produced said the harness "needs your decision to proceed" — when the
 * truth is that the toolchain is stale, no ticket is implicated, and no decision
 * about the work is being asked for at all.
 *
 * argv[2]: a JSON file — a list of escalationType values (or null/absent for the
 *          default branch, expressed as the JSON literal null).
 * Output (stdout): JSON { copy: { "<type or __default__>": "<string>" },
 *                         bootErrors: [...] }
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

/* The minimum board.js needs at module scope: it registers listeners and reads a
 * few globals on load. Nothing here renders — we only want the pure function. */
function noop() {}
function stubEl() {
  const node = {
    style: {}, children: [], dataset: {}, textContent: "", value: "",
    classList: { add: noop, remove: noop, toggle() { return false; },
                 contains() { return false; } },
    addEventListener: noop, removeEventListener: noop,
    appendChild(c) { node.children.push(c); return c; },
    removeChild: noop, replaceChildren: noop, insertBefore(c) { return c; },
    setAttribute: noop, removeAttribute: noop, getAttribute() { return null; },
    focus: noop, blur: noop, click: noop, remove: noop,
    querySelector() { return stubEl(); }, querySelectorAll() { return []; },
    closest() { return null; }, contains() { return false; },
  };
  return node;
}
const sandbox = {
  document: {
    addEventListener: noop, removeEventListener: noop,
    getElementById() { return stubEl(); },
    querySelector() { return stubEl(); },
    querySelectorAll() { return []; },
    createElement() { return stubEl(); },
    createTextNode() { return stubEl(); },
    body: stubEl(),
    documentElement: stubEl(),
  },
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "test" },
  localStorage: { getItem() { return null; }, setItem: noop, removeItem: noop },
  // a never-resolving thenable: board.js chains .then().then().catch() on load
  fetch() {
    const p = { then() { return p; }, catch() { return p; }, finally() { return p; } };
    return p;
  },
  setTimeout: noop, clearTimeout: noop, setInterval: noop, clearInterval: noop,
  requestAnimationFrame: noop,
  EventSource: function () { this.addEventListener = noop; this.close = noop; },
  console, JSON, Math, Date,
  Array, Object, String, Number, Boolean, RegExp, Error,
  encodeURIComponent, decodeURIComponent, isNaN, parseInt, parseFloat,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const src = fs.readFileSync(path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
const bootErrors = [];
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) {
  bootErrors.push(String(e && e.message ? e.message : e));
}

const types = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const copy = {};
for (const t of types) {
  const key = t === null || t === undefined ? "__default__" : String(t);
  try {
    copy[key] = sandbox.whyCopyForGate(t);
  } catch (e) {
    copy[key] = "ERROR: " + String(e && e.message ? e.message : e);
  }
}
process.stdout.write(JSON.stringify({ copy, bootErrors }));
