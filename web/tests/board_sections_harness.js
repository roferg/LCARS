"use strict";
/* S115 test harness — loads the SHIPPING web/static/board.js in a sandboxed vm
 * with minimal browser stubs so its boot side-effects no-op, then exercises the
 * PURE grouping helper `groupActivityIntoSections` (no DOM needed). Reads an
 * events array from argv[2] (a JSON file) and prints the section list as JSON.
 *
 * There is NO JS DOM harness in this repo (ADR-007: no build step, no npm), so
 * the collapsible-feed logic lives in a pure, separately-testable helper and the
 * DOM wiring stays thin. This harness unit-tests that helper directly. */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function stubEl() {
  return {
    style: {},
    classList: { add() {}, remove() {}, toggle() { return false; }, contains() { return false; } },
    addEventListener() {}, removeEventListener() {},
    appendChild() {}, removeChild() {}, setAttribute() {}, removeAttribute() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, focus() {},
    children: [], innerHTML: "", textContent: "", hidden: false, title: "",
  };
}
const documentStub = {
  getElementById() { return stubEl(); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement() { return stubEl(); },
  createTextNode() { return stubEl(); },
  addEventListener() {},
  body: stubEl(),
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

if (typeof sandbox.groupActivityIntoSections !== "function") {
  process.stderr.write("groupActivityIntoSections is not defined\n");
  process.exit(2);
}
const acts = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const sections = sandbox.groupActivityIntoSections(acts);
process.stdout.write(JSON.stringify(sections));
