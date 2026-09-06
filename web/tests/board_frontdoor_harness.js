"use strict";
/* S184 FRONT-DOOR render harness — loads the SHIPPING web/static/board.js in a
 * sandboxed vm with minimal browser stubs and drives the REAL `render()` over a
 * whole board payload, projecting the produced DOM to inspectable JSON.
 *
 * WHY render() AND NOT renderFrontDoor(): the question this session must never
 * get wrong is "does the BOARD still render?", and only render() can answer it —
 * it is the function that decides between columns and the door. A harness that
 * called the front-door painter directly would pass on a build that had eaten
 * every healthy repo's board. (A node harness still cannot prove the board
 * PAINTS — S163 — the tester drives real Chrome for that; this pins the
 * decision.)
 *
 * argv[2]: a JSON file — {"board": <the full board payload>,
 *                         "readonly": true|false}
 * Output: {columns: N, cards: N, frontDoor: <projected #frontDoor>,
 *          frontDoorHidden: bool, bodyClasses: [...], fileBtn, holodeckBtn}
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
      list() { return Object.keys(this._s); },
    },
    _listeners: {},
    addEventListener(type, fn) {
      (node._listeners[type] || (node._listeners[type] = [])).push(fn);
    },
    removeEventListener() {},
    appendChild(c) { node.children.push(c); if (c) c.parentNode = node; return c; },
    insertBefore(c, ref) {
      var i = node.children.indexOf(ref);
      if (i < 0) node.children.push(c); else node.children.splice(i, 0, c);
      if (c) c.parentNode = node;
      return c;
    },
    removeChild(c) {
      var i = node.children.indexOf(c);
      if (i >= 0) node.children.splice(i, 1);
      return c;
    },
    _attrs: {},
    setAttribute(k, v) { node._attrs[k] = v; },
    removeAttribute(k) { delete node._attrs[k]; },
    getAttribute(k) { return node._attrs[k]; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    focus() {},
    children: [], _text: "", title: "", hidden: false, disabled: false,
    value: "", placeholder: "", rows: 0,
  };
  Object.defineProperty(node, "className", {
    get() { return node._cls || ""; },
    set(v) { node._cls = v; },
  });
  /* String(), because THE DOM DOES. `textContent = {text:"…"}` puts the
     literal characters `[object Object]` on a real screen — which is exactly
     what the captain read on every grill turn of both live runs (D3). A stub
     that stored the object instead let a projection show a tidy dict and a
     test assert against it. */
  Object.defineProperty(node, "textContent", {
    get() { return node._text; },
    set(v) { node._text = String(v); node.children = []; },
  });
  Object.defineProperty(node, "innerHTML", {
    get() { return node._html || ""; },
    set(v) { node._html = v; if (v === "") node.children = []; },
  });
  Object.defineProperty(node, "lastChild", {
    get() { return node.children[node.children.length - 1] || null; },
  });
  return node;
}

const REGISTRY = {};
["mainDeploy", "fileBtn", "holodeckBtn", "conn", "repoMeta", "deployMainBtn",
 "helpBtn",
 "versionBanner", "readinessBanner", "board", "status", "viewonly",
 "overlay", "overlayBody", "boardEmpty", "deckHost", "holoRoBanner",
 "frontDoor"]
  .forEach(function (id) { REGISTRY[id] = stubEl("div"); });

const bodyStub = stubEl("body");
const documentStub = {
  getElementById(id) { return REGISTRY[id] || stubEl(); },
  querySelector() { return null; },
  querySelectorAll() { return []; },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { var n = stubEl("#text"); n._text = t; return n; },
  addEventListener() {},
  body: bodyStub,
};

const FETCH_CALLS = [];
/* GET /api/board answers THE BOARD UNDER TEST. This is load-bearing, not
   convenience: board.js's boot `refresh()` resolves during any drain() and
   re-renders — answering it with an empty board silently reset the surface
   mid-interaction, so a click chain projected a blank front door and every
   assertion about it would have been measuring the wrong screen. */
let CURRENT_BOARD = { stages: [], columns: {}, missions: [], meta: {} };
/* S184 FIX ROUND 2 (D10) — THE POST STUB ANSWERS WHAT THE DAEMON ANSWERS.
   Until now every POST here resolved to `{ok:true, state:{}}`, so the whole
   front-door suite could only ever see a screen the RENDERER had been handed
   directly (`act:"recommend"`, `rec:{...}`). That is the S163 blindness class:
   the harness supplied the field the server never sent, and three blockers
   (the session id read off the wrong key, a recommendation nothing could
   produce, a question object printed as `[object Object]`) stayed green
   through 36 tests and died in real Chrome on the first turn.
   `input.responses` is an ORDERED list of the `state` payloads the daemon
   really returns — copied from `actions.py`'s own `out = {...}` dicts — popped
   one per POST. With none given the old `{}` is kept, so every existing test
   is unchanged. */
let POST_RESPONSES = [];
function fetchStub(url, opts) {
  FETCH_CALLS.push({ url: url, method: (opts && opts.method) || "GET",
                     body: (opts && opts.body) || null });
  var isPost = (opts && opts.method) === "POST";
  /* board.js's boot WRITE PROBE (`probeWrites`) is a bare POST /api/mission
     with an empty body. It is not a scripted turn and must not eat one. */
  var scripted = isPost && /^\/api\/(align|vision)\//.test(url);
  var state = scripted && POST_RESPONSES.length ? POST_RESPONSES.shift()
                                                : {};
  return Promise.resolve({
    status: 200, ok: true,
    json: function () {
      return Promise.resolve(isPost ? { ok: true, state: state } : CURRENT_BOARD);
    },
  });
}

const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval() { return 0; }, clearInterval() {},
  setTimeout() { return 0; }, clearTimeout() {},
  fetch: fetchStub,
  prompt() { return null; },
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date, Object,
};
sandbox.window = sandbox;
sandbox.globalThis = sandbox;

const src = fs.readFileSync(path.join(__dirname, "..", "static", "board.js"), "utf8");
vm.createContext(sandbox);
try {
  vm.runInContext(src, sandbox, { filename: "board.js" });
} catch (e) { /* boot side-effects may throw against the stubs */ }

function project(n) {
  if (!n || typeof n !== "object") return null;
  return {
    tag: n.tag || "",
    cls: n._cls || "",
    text: n._text || "",
    disabled: !!n.disabled,
    reason: (n._attrs && n._attrs["data-reason"]) || "",
    title: n.title || "",
    value: n.value || "",
    placeholder: n.placeholder || "",
    hidden: !!n.hidden,
    children: (n.children || []).map(project).filter(Boolean),
  };
}
function findNode(root, pred) {
  if (!root || typeof root !== "object") return null;
  if (pred(root)) return root;
  for (var i = 0; i < (root.children || []).length; i++) {
    var hit = findNode(root.children[i], pred);
    if (hit) return hit;
  }
  return null;
}
function click(node) {
  ((node && node._listeners && node._listeners.click) || [])
    .forEach(function (fn) { fn({ stopPropagation: function () {} }); });
}
function drain() {
  var p = Promise.resolve();
  for (var i = 0; i < 5; i++) {
    p = p.then(function () { return new Promise(function (r) { setImmediate(r); }); });
  }
  return p;
}
function countCards(boardNode) {
  var n = 0;
  (boardNode.children || []).forEach(function (col) {
    (col.children || []).forEach(function (part) {
      if ((part._cls || "").indexOf("col-body") === 0) {
        n += (part.children || []).length;
      }
    });
  });
  return n;
}

/* The board controls the top band carries. Mirrors board.js's
   FRONT_DOOR_BAND_HIDDEN — restated here deliberately, so a build that silently
   drops one from the painter's list still has it projected and asserted. */
const FRONT_DOOR_BAND = ["deployMainBtn", "mainDeploy", "holodeckBtn",
                         "fileBtn", "helpBtn"];

const input = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (input.readonly) sandbox.writesActive = false;
CURRENT_BOARD = input.board;
POST_RESPONSES = (input.responses || []).slice();

/* The front-door text box, whichever screen is up (the ask/grill textarea, or
   the override's single-line input). */
function fdBox() {
  return findNode(REGISTRY.frontDoor, function (n) {
    return n.tag === "textarea" || n.tag === "input";
  });
}
function fdButton(re) {
  return findNode(REGISTRY.frontDoor, function (n) {
    return n.tag === "button" && re.test(n._text || "");
  });
}

(async function main() {
  sandbox.render(input.board);
  /* Optional scripted interaction: drive the REAL grill/accept path so the test
     can prove what actually gets POSTed (the override, chiefly). */
  if (input.act === "submit") {
    var box = findNode(REGISTRY.frontDoor, function (n) { return n.tag === "textarea"; });
    if (box) box.value = input.text || "";
    var go = findNode(REGISTRY.frontDoor, function (n) {
      return n.tag === "button" && /Establish/.test(n._text || "");
    });
    FETCH_CALLS.length = 0;
    click(go);
    await drain();
  }
  /* THE GRILL, TURN BY TURN — the road the tester drove in Chrome and no test
     had ever walked. Each entry of `input.turns` is what the captain types;
     the first goes into the ask box under the primary action, every later one
     under "▸ Continue". Nothing is injected into `frontDoorState`: whatever
     the screen shows after turn N is whatever the REAL `frontDoorTurn` made of
     the daemon's REAL response to turn N. */
  if (input.act === "grill") {
    var turns = input.turns || [];
    for (var ti = 0; ti < turns.length; ti++) {
      var tbox = fdBox();
      if (tbox) tbox.value = turns[ti];
      var tgo = fdButton(ti === 0 ? /Establish/ : /Continue/);
      if (!tgo) break;
      click(tgo);
      await drain();
    }
    /* …and, optionally, act on the screen the grill actually produced. */
    if (input.then === "accept") {
      var acc = fdButton(/Accept/);
      if (acc) { click(acc); await drain(); }
    }
  }
  /* Click one of the model's offered CHOICES instead of typing an answer. */
  if (input.act === "choose") {
    var cbox = fdBox();
    if (cbox) cbox.value = input.text || "";
    click(fdButton(/Establish/));
    await drain();
    var chosen = fdButton(new RegExp(input.choice.replace(
      /[.*+?^${}()|[\]\\]/g, "\\$&")));
    if (chosen) { click(chosen); await drain(); }
  }
  if (input.act === "recommend" || input.act === "accept" || input.act === "override") {
    sandbox.frontDoorState.screen = "recommend";
    sandbox.frontDoorState.idea = input.idea || "an idea";
    sandbox.frontDoorState.rec = input.rec;
    sandbox.render(input.board);
    if (input.act !== "recommend") {
      var label = input.act === "accept" ? /Accept/ : /different stack/;
      var btn = findNode(REGISTRY.frontDoor, function (n) {
        return n.tag === "button" && label.test(n._text || "");
      });
      FETCH_CALLS.length = 0;
      click(btn);
      await drain();
      if (input.act === "override") {
        var inp = findNode(REGISTRY.frontDoor, function (n) { return n.tag === "input"; });
        if (inp) inp.value = input.override || "";
        var use = findNode(REGISTRY.frontDoor, function (n) {
          return n.tag === "button" && /Use this stack/.test(n._text || "");
        });
        FETCH_CALLS.length = 0;
        click(use);
        await drain();
      }
    }
  }
  /* EVERY control in the document, band included — not just the ones inside
     #frontDoor. Fix round 1 / D1: the 25 front-door tests all projected
     #frontDoor alone, so they were green while ⬡ HOLODECK and ▦ FILE MISSION
     sat greyed-out in the top band above a screen promising nothing was being
     withheld. A projection that cannot see the band cannot catch that. */
  var controls = [];
  Object.keys(REGISTRY).forEach(function (id) {
    var root = REGISTRY[id];
    (function walk(n, inheritedHidden) {
      if (!n || typeof n !== "object") return;
      var hidden = inheritedHidden || !!n.hidden;
      if (n.disabled === true || n.tag === "button") {
        controls.push({ id: id, tag: n.tag, text: n._text || "",
                        disabled: !!n.disabled, hidden: hidden });
      }
      (n.children || []).forEach(function (c) { walk(c, hidden); });
    })(root, false);
  });
  process.stdout.write(JSON.stringify({
    controls: controls,
    band: FRONT_DOOR_BAND.reduce(function (acc, id) {
      var n = REGISTRY[id];
      acc[id] = { hidden: !!(n && n.hidden), disabled: !!(n && n.disabled) };
      return acc;
    }, {}),
    columns: (REGISTRY.board.children || []).length,
    cards: countCards(REGISTRY.board),
    frontDoor: project(REGISTRY.frontDoor),
    frontDoorHidden: !!REGISTRY.frontDoor.hidden,
    bodyClasses: bodyStub.classList.list(),
    fileBtn: project(REGISTRY.fileBtn),
    holodeckBtn: project(REGISTRY.holodeckBtn),
    fetches: FETCH_CALLS,
  }));
})().catch(function (e) {
  process.stderr.write(String((e && e.stack) || e) + "\n");
  process.exit(2);
});
