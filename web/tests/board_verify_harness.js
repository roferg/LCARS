"use strict";
/* S134 test harness — loads the SHIPPING web/static/board.js in a sandboxed vm
 * with minimal browser stubs (same pattern as board_sections_harness.js), then
 * exercises the DOM builders that render the unified-implementer surfaces:
 *   • renderEvent(ev)        — one activity event → an `.evt` node
 *   • renderStream(acts)     — S173 fix round 2: a whole ORDERED stream, grouped
 *                              through groupActivityIntoSections FIRST (the only
 *                              path the product ever takes to renderEvent) and
 *                              then rendered event by event → an array of nodes.
 *   • buildSummary(mi)       — the Verify "what was built" ticket list
 *   • contractAmendments(mi) — the CONTRACT AMENDMENTS block (or null)
 * The produced DOM is projected to plain JSON (className + textContent + html +
 * recursive children) so a Python test can assert on it without a browser.
 *
 * argv[2] = mode ("renderEvent" | "renderStream" | "buildSummary" | "contract")
 * argv[3] = a JSON file: an event (renderEvent), an event ARRAY (renderStream),
 *           or a mission (buildSummary/contract)
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

function stubEl() {
  var node = {
    style: {},
    classList: { add() {}, remove() {}, toggle() { return false; }, contains() { return false; } },
    addEventListener() {}, removeEventListener() {},
    appendChild(c) { node.children.push(c); return c; },
    removeChild() {}, setAttribute() {}, removeAttribute() {},
    querySelector() { return null; }, querySelectorAll() { return []; },
    getAttribute() { return null; }, focus() {},
    children: [], innerHTML: "", textContent: "", hidden: false, title: "",
  };
  return node;
}
const documentStub = {
  getElementById() { return stubEl(); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement() { return stubEl(); },
  createTextNode() { var n = stubEl(); return n; },
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
} catch (e) { /* boot side-effects may throw against the stubs — the hoisted fns are bound */ }

function project(node) {
  if (node == null || typeof node !== "object") return null;
  return {
    className: node.className || "",
    text: node.textContent || "",
    html: node.innerHTML || "",
    title: node.title || "",
    children: (node.children || []).map(project),
  };
}

const mode = process.argv[2] || "";
const input = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));

function need(name) {
  if (typeof sandbox[name] !== "function") {
    process.stderr.write(name + " is not defined\n");
    process.exit(2);
  }
}

var out;
if (mode === "renderEvent") {
  need("renderEvent");
  out = project(sandbox.renderEvent(input));
} else if (mode === "renderStream") {
  // S173 FIX ROUND 2: the product renders events only AFTER grouping, and the
  // grouping pass is what derives a ticket_attempt's per-ticket hire index. A
  // harness that skipped it was rendering a shape the board never produces.
  need("renderEvent");
  need("groupActivityIntoSections");
  sandbox.groupActivityIntoSections(input);
  out = input.map(function (ev) { return project(sandbox.renderEvent(ev)); });
} else if (mode === "buildSummary") {
  need("buildSummary");
  out = project(sandbox.buildSummary(input));
} else if (mode === "contract") {
  need("contractAmendments");
  out = project(sandbox.contractAmendments(input));   // may be null → JSON null
} else {
  process.stderr.write("unknown mode: " + mode + "\n");
  process.exit(2);
}
process.stdout.write(JSON.stringify(out));
