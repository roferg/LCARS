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
  var node = {
    style: {},
    classList: { add() {}, remove() {}, toggle() { return false; }, contains() { return false; } },
    addEventListener() {}, removeEventListener() {},
    // track appended children so the chip / health-bar DOM builders can be
    // inspected (className, textContent, and segment style.width) by the tests.
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
const mode = process.argv[3] || "";

if (mode === "headlines") {
  // S173 fix-round: the captain-facing EVENT HEADLINE for each input event, as
  // produced by the SHIPPING headlineFor(), plus the raw EVENT_HEADS map — so a
  // test can prove no headline says "attempt" on ANY stream shape.
  if (typeof sandbox.headlineFor !== "function") {
    process.stderr.write("headlineFor is not defined\n");
    process.exit(2);
  }
  process.stdout.write(JSON.stringify({
    headlines: acts.map(function (ev) { return sandbox.headlineFor(ev); }),
    heads: sandbox.EVENT_HEADS || {},
  }));
} else if (mode === "chips") {
  // VISUAL POLISH: exercise the graphic chip + health-bar DOM builders against
  // the SHIPPING board.js, projecting the produced DOM to inspectable JSON.
  if (typeof sandbox.sectionSummaryChips !== "function"
      || typeof sandbox.sectionHealthBar !== "function") {
    process.stderr.write("chip helpers are not defined\n");
    process.exit(2);
  }
  const out = sections.map(function (s) {
    const chips = sandbox.sectionSummaryChips(s) || [];
    const hb = sandbox.sectionHealthBar(s);
    return {
      kind: s.kind, wave: s.wave, active: s.active,
      ticketCount: s.ticketCount, greenCount: s.greenCount,
      flaggedCount: s.flaggedCount, flagged: s.flagged,
      durationSec: s.durationSec,
      sessionCount: s.sessionCount, bounceCount: s.bounceCount,
      chipClasses: chips.map(function (c) { return c.className || ""; }),
      chipTexts: chips.map(function (c) { return c.textContent || ""; }),
      healthBar: hb ? (hb.className || "") : null,
      healthGreen: hb && hb.children[0] ? hb.children[0].style.width : null,
      healthRed: hb && hb.children[1] ? hb.children[1].style.width : null,
    };
  });
  process.stdout.write(JSON.stringify(out));
} else {
  process.stdout.write(JSON.stringify(sections));
}
