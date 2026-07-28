"use strict";
/* S141 ? — HELP-CONSOLE harness. Loads the SHIPPING web/static/board.js in a
 * sandboxed vm against a MINI-DOM (no jsdom, no build step — ADR-007), renders a
 * real board, opens the help console the way the captain does (the band's ? button
 * or the ? key), and projects the produced console to inspectable JSON.
 *
 * It is the S140 board_hotkeys_harness.js mini-DOM with three additions the help
 * round needs:
 *   • the band carries the S141 #helpBtn alongside #deployMainBtn / #fileBtn, and
 *     the whole topbar is projected so a test can prove the NON-help chrome is
 *     untouched;
 *   • fetch() can resolve SYNCHRONOUSLY for a registered mission detail, so the
 *     REAL openVerify()/launchAffordance() surfaces can be built and the primer's
 *     control references checked against them;
 *   • KEY_BINDINGS can be mutated BEFORE the console opens, which is how a test
 *     proves the cheatsheet is generated from the table rather than duplicated.
 *
 * argv[2]: a JSON spec file:
 *   {
 *     "board":      <the /api/board shape passed to render()>,
 *     "readonly":   true,              // writesActive=false before render
 *     "open":       "key"|"button",    // how to open the help console
 *     "openOverlayFirst": true,        // an overlay is up before ? (GUARD 2)
 *     "keys":       [ {"key":"Escape"}, ... ],   // keys AFTER the console opened
 *     "addBinding": {"id":"x","keys":["x"],"label":"Do the extra thing"},
 *     "missionDetail": <mission detail for the canned /api/mission/<id> read>,
 *     "resolveRefs": true,             // walk every ORIENTATION control reference
 *     "consoleFirst": {                // a REAL console is on the stage before ?
 *       "kind": "file"|"detail"|"align"|"bare",
 *       "type": "half-typed idea",     // into the File console's idea box
 *       "pickEngine": "copilot",       // click the engine picker's option
 *       "mid": "v1",                   // which mission the detail opens
 *       "keepFocus": true              // leave focus IN the field (GUARD 1)
 *     },
 *     "closeVia": "escape"|"x"|"footer"|"backdrop"   // how help is dismissed
 *   }
 *
 * stdout: a JSON report — see the bottom of the file.
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

/* ══════════════════ a very small DOM ══════════════════ */

const CLICKS = [];
const FETCHES = [];
let ACTIVE = null;

function parseCompound(sel) {
  const out = { tag: null, id: null, classes: [], attrs: [] };
  const re = /([.#]?[A-Za-z0-9_-]+)|\[([^\]]+)\]/g;
  let m;
  while ((m = re.exec(sel))) {
    if (m[2] !== undefined) {
      const a = m[2];
      const eq = a.indexOf("=");
      if (eq === -1) out.attrs.push([a.trim(), null]);
      else {
        out.attrs.push([
          a.slice(0, eq).trim(),
          a.slice(eq + 1).trim().replace(/^['"]/, "").replace(/['"]$/, ""),
        ]);
      }
    } else {
      const t = m[1];
      if (t[0] === ".") out.classes.push(t.slice(1));
      else if (t[0] === "#") out.id = t.slice(1);
      else out.tag = t.toUpperCase();
    }
  }
  return out;
}

function parseSelector(sel) {
  return String(sel).split(",").map(function (one) {
    return one.trim().split(/\s+/).filter(Boolean).map(parseCompound);
  }).filter(function (p) { return p.length; });
}

function matchesCompound(node, c) {
  if (!node || node.nodeType !== 1) return false;
  if (c.tag && node.tagName !== c.tag) return false;
  if (c.id && node.getAttribute("id") !== c.id) return false;
  for (const cls of c.classes) if (!node.classList.contains(cls)) return false;
  for (const [name, val] of c.attrs) {
    if (!node.hasAttribute(name)) return false;
    if (val !== null && node.getAttribute(name) !== val) return false;
  }
  return true;
}

function matchesOne(node, parts) {
  if (!matchesCompound(node, parts[parts.length - 1])) return false;
  let i = parts.length - 2;
  let cur = node.parentNode;
  while (i >= 0) {
    if (!cur) return false;
    if (matchesCompound(cur, parts[i])) i--;
    cur = cur.parentNode;
  }
  return true;
}

function matchesSelector(node, sel) {
  return parseSelector(sel).some(function (parts) { return matchesOne(node, parts); });
}

let NEXT_UID = 1;

function Element(tag) {
  this.nodeType = 1;
  this.tag = String(tag || "");
  this.tagName = String(tag || "").toUpperCase();
  this.uid = NEXT_UID++;
  this._attrs = Object.create(null);
  this._listeners = Object.create(null);
  this._text = "";
  this._html = "";
  this.children = [];
  this.parentNode = null;
  this.style = {};
  this.disabled = false;
  this._hidden = false;
  this.title = "";
  this.value = "";
  const self = this;
  this.classList = {
    add(c) { self._addClass(c); },
    remove(c) { self._removeClass(c); },
    contains(c) { return self._classes().indexOf(c) !== -1; },
    toggle(c, on) {
      const has = self._classes().indexOf(c) !== -1;
      const want = on === undefined ? !has : !!on;
      if (want) self._addClass(c); else self._removeClass(c);
      return want;
    },
  };
}

Element.prototype._classes = function () {
  return String(this._attrs["class"] || "").split(/\s+/).filter(Boolean);
};
Element.prototype._addClass = function (c) {
  const cur = this._classes();
  if (cur.indexOf(c) === -1) { cur.push(c); this._attrs["class"] = cur.join(" "); }
};
Element.prototype._removeClass = function (c) {
  this._attrs["class"] = this._classes().filter(function (x) { return x !== c; }).join(" ");
};
Element.prototype.setAttribute = function (n, v) { this._attrs[n] = String(v); };
Element.prototype.getAttribute = function (n) {
  return Object.prototype.hasOwnProperty.call(this._attrs, n) ? this._attrs[n] : null;
};
Element.prototype.hasAttribute = function (n) {
  return Object.prototype.hasOwnProperty.call(this._attrs, n);
};
Element.prototype.removeAttribute = function (n) { delete this._attrs[n]; };
Element.prototype.appendChild = function (c) {
  if (!c) return c;
  if (c.parentNode) c.parentNode.removeChild(c);
  c.parentNode = this;
  this.children.push(c);
  return c;
};
Element.prototype.insertBefore = function (c, ref) {
  if (!c) return c;
  if (c.parentNode) c.parentNode.removeChild(c);
  const i = ref ? this.children.indexOf(ref) : -1;
  c.parentNode = this;
  if (i === -1) this.children.push(c); else this.children.splice(i, 0, c);
  return c;
};
Element.prototype.replaceChild = function (nw, old) {
  const i = this.children.indexOf(old);
  if (i === -1) return old;
  old.parentNode = null;
  nw.parentNode = this;
  this.children[i] = nw;
  return old;
};
Element.prototype.remove = function () {
  if (this.parentNode) this.parentNode.removeChild(this);
};
/* Real-DOM fidelity: detaching (or MOVING, which is a detach first) the focused
 * element BLURS it — focus falls back to the page and putting the node back does
 * NOT bring focus with it. Without this the harness would flatter any code that
 * lifts a live subtree and drops the captain's place in it. */
function dropFocusInside(node) {
  if (ACTIVE && (ACTIVE === node || node.contains(ACTIVE))) ACTIVE = null;
}
Element.prototype.removeChild = function (c) {
  const i = this.children.indexOf(c);
  if (i !== -1) { this.children.splice(i, 1); c.parentNode = null; }
  dropFocusInside(c);
  return c;
};
Element.prototype.contains = function (n) {
  let cur = n;
  while (cur) { if (cur === this) return true; cur = cur.parentNode; }
  return false;
};
Element.prototype.addEventListener = function (type, fn) {
  (this._listeners[type] || (this._listeners[type] = [])).push(fn);
};
Element.prototype.removeEventListener = function (type, fn) {
  const l = this._listeners[type];
  if (!l) return;
  const i = l.indexOf(fn);
  if (i !== -1) l.splice(i, 1);
};
Element.prototype.focus = function () { ACTIVE = this; };
Element.prototype.blur = function () { if (ACTIVE === this) ACTIVE = null; };
Element.prototype.getClientRects = function () { return [{}]; };
Element.prototype.closest = function (sel) {
  let cur = this;
  while (cur && cur.nodeType === 1) {
    if (matchesSelector(cur, sel)) return cur;
    cur = cur.parentNode;
  }
  return null;
};
Element.prototype.matches = function (sel) { return matchesSelector(this, sel); };
Element.prototype._walk = function (out) {
  for (const c of this.children) {
    if (c.nodeType === 1) { out.push(c); c._walk(out); }
  }
  return out;
};
Element.prototype.querySelectorAll = function (sel) {
  const parsed = parseSelector(sel);
  return this._walk([]).filter(function (n) {
    return parsed.some(function (parts) { return matchesOne(n, parts); });
  });
};
Element.prototype.querySelector = function (sel) {
  const all = this.querySelectorAll(sel);
  return all.length ? all[0] : null;
};
Element.prototype.click = function () {
  CLICKS.push({
    act: this.getAttribute("data-act"),
    id: this.getAttribute("id"),
    cls: this.getAttribute("class") || "",
    text: this.textContent,
    disabled: !!this.disabled,
    fired: !this.disabled,
  });
  if (this.disabled) return;
  const ev = {
    type: "click", target: this, _stop: false,
    stopPropagation() { this._stop = true; },
    preventDefault() {},
  };
  let cur = this;
  while (cur) {
    const ls = (cur._listeners["click"] || []).slice();
    for (const fn of ls) fn.call(cur, ev);
    if (ev._stop) break;
    cur = cur.parentNode;
  }
};

Object.defineProperty(Element.prototype, "className", {
  get() { return this._attrs["class"] || ""; },
  set(v) { this._attrs["class"] = String(v); },
});
Object.defineProperty(Element.prototype, "id", {
  get() { return this._attrs["id"] || ""; },
  set(v) { this._attrs["id"] = String(v); },
});
Object.defineProperty(Element.prototype, "textContent", {
  get() {
    if (!this.children.length) return this._text;
    return this._text + this.children.map(function (c) { return c.textContent; }).join("");
  },
  set(v) { this._text = v == null ? "" : String(v); this.children.forEach(function (c) { c.parentNode = null; }); this.children = []; },
});
Object.defineProperty(Element.prototype, "innerHTML", {
  get() { return this._html; },
  set(v) {
    this._html = String(v);
    this.children.forEach(function (c) { c.parentNode = null; dropFocusInside(c); });
    this.children = [];
    if (v !== "") this._text = "";
  },
});
Object.defineProperty(Element.prototype, "lastChild", {
  get() { return this.children.length ? this.children[this.children.length - 1] : null; },
});
Object.defineProperty(Element.prototype, "firstChild", {
  get() { return this.children.length ? this.children[0] : null; },
});
/* Real-DOM fidelity, the HIDE half of the pair above: a browser BLURS the active
 * element the moment it (or any ancestor) stops being rendered — `[hidden]`
 * carries `display:none !important` in board.css. Without this the harness would
 * flatter a cover that hides a console in place and never hands focus back. */
Object.defineProperty(Element.prototype, "hidden", {
  get() { return !!this._hidden; },
  set(v) { this._hidden = !!v; if (this._hidden) dropFocusInside(this); },
});
Object.defineProperty(Element.prototype, "isContentEditable", {
  get() { return this._attrs["contenteditable"] === "true"; },
  set(v) { this._attrs["contenteditable"] = v ? "true" : "false"; },
});

function TextNode(t) {
  Element.call(this, "#text");
  this.nodeType = 3;
  this._text = t == null ? "" : String(t);
}
TextNode.prototype = Object.create(Element.prototype);
TextNode.prototype.constructor = TextNode;

/* ══════════════════ the page — index.html's band, verbatim in order ══════════ */

const root = new Element("html");
const body = new Element("body");
root.appendChild(body);

function mk(tag, id, cls, parent) {
  const n = new Element(tag);
  if (id) n.setAttribute("id", id);
  if (cls) n.setAttribute("class", cls);
  (parent || body).appendChild(n);
  return n;
}

const frame = mk("div", null, "lcars-frame");
const topbar = mk("div", null, "frame-top topbar", frame);
mk("div", null, "brand", topbar);
mk("div", "repoMeta", "repo-meta", topbar);
mk("div", "mainDeploy", "main-deploy", topbar);
const deployMainBtn = mk("button", "deployMainBtn", "btn go", topbar);
deployMainBtn.textContent = "▸ Deploy Main";
const fileBtn = mk("button", "fileBtn", "btn go", topbar);
fileBtn.textContent = "▦ File Mission";
// S141: the band's help control. Built here from the SAME markup index.html ships
// (see test_help_console.py's band-parity test, which reads the real file).
const helpBtn = mk("button", "helpBtn", "btn help-btn", topbar);
helpBtn.textContent = "?";
helpBtn.title = "Help — press ?";
mk("div", "conn", "conn", topbar);
const content = mk("div", null, "frame-content", frame);
mk("div", "versionBanner", "version-banner", content);
mk("div", "readinessBanner", "readiness-banner", content);
const boardEmpty = mk("div", "boardEmpty", "board-empty", content);
boardEmpty.hidden = true;
const boardWrap = mk("div", null, "board-wrap", content);
mk("div", "board", "board", boardWrap);
const legend = mk("div", null, "legend", content);
mk("span", "status", "dim", legend);
mk("span", "viewonly", "dim viewonly", legend);
const overlayEl = mk("div", "overlay", "overlay");
overlayEl.hidden = true;
const overlayBodyEl = mk("div", "overlayBody", "overlay-stage", overlayEl);

const documentStub = {
  nodeType: 9,
  body: body,
  documentElement: root,
  _listeners: Object.create(null),
  createElement(tag) { return new Element(tag); },
  createTextNode(t) { return new TextNode(t); },
  getElementById(id) { return root.querySelector("#" + id); },
  querySelector(sel) { return root.querySelector(sel); },
  querySelectorAll(sel) { return root.querySelectorAll(sel); },
  addEventListener(type, fn) {
    (this._listeners[type] || (this._listeners[type] = [])).push(fn);
  },
  removeEventListener(type, fn) {
    const l = this._listeners[type];
    if (!l) return;
    const i = l.indexOf(fn);
    if (i !== -1) l.splice(i, 1);
  },
};
Object.defineProperty(documentStub, "activeElement", {
  get() { return ACTIVE && root.contains(ACTIVE) ? ACTIVE : body; },
});

/* A fetch that resolves SYNCHRONOUSLY for a REGISTERED mission-detail read, and
 * stays inert (never settles) for everything else. That is enough to build the
 * REAL openVerify() screen — including launchAffordance's re-read — so the
 * primer's ⚡ RUN / ✓ Merge PR / ↩ Send Back… references are checked against the
 * console the captain actually sees, not a mock of it. */
let MISSION_DETAIL = null;
function settled(value) {
  const p = {
    // Promise semantics, including the ASSIMILATION step: a handler that returns
    // a thenable resolves TO it. fetchMission's chain is
    // `.then(r => r.json()).then(cb)` — without the flatten, cb was handed the
    // promise object instead of the mission, and every console built off a
    // detail read got an empty shell that happened to render.
    then(fn) {
      if (!fn) return p;
      const out = fn(value);
      return out && typeof out.then === "function" ? out : settled(out);
    },
    catch() { return p; },
  };
  return p;
}
function fetchStub(url, opts) {
  const method = (opts && opts.method) || "GET";
  FETCHES.push({ url: String(url), method: method });
  if (MISSION_DETAIL && method === "GET" && /^\/api\/mission\/[^/]+$/.test(String(url))) {
    return settled({ status: 200, json() { return settled(MISSION_DETAIL); } });
  }
  const p = { then() { return p; }, catch() { return p; } };
  return p;
}

/* ══════════════════ a clock the test drives ══════════════════ */
/* D-A: the cover has to be proven against LIVE LOOPS — the mission detail's
 * "Active" tick (setInterval) and the Verify launch poll (setTimeout chain).
 * Both self-cancel on `document.body.contains(node) === false`, so a harness
 * whose timers never fire cannot tell a loop that kept running from one that
 * died. So: real timer bookkeeping on a virtual clock the spec advances, and a
 * Date whose now() reads that same clock (the tick recomputes from Date.now()).
 *
 * Nothing fires unless the spec asks for it, so every pre-existing drive behaves
 * exactly as it did when setInterval/setTimeout were no-ops. */
const RealDate = Date;
let CLOCK = RealDate.now();
const FakeDate = new Proxy(RealDate, {
  get(t, p, r) { return p === "now" ? function () { return CLOCK; } : Reflect.get(t, p, r); },
  construct(t, args) { return args.length ? new t(...args) : new t(CLOCK); },
  apply(t, thisArg, args) { return t(...args); },
});

const TIMERS = new Map();
let NEXT_TIMER = 1;
function arm(fn, ms, repeat) {
  const id = NEXT_TIMER++;
  const delay = Math.max(0, Number(ms) || 0);
  TIMERS.set(id, { fn: fn, ms: delay, due: CLOCK + delay, repeat: repeat });
  return id;
}
function disarm(id) { TIMERS.delete(id); }
const TIMER_ERRORS = [];
/* Run the clock forward, firing everything that comes due in order — exactly
 * what a browser does over `ms` of wall time. */
function advanceClock(ms) {
  const target = CLOCK + Math.max(0, Number(ms) || 0);
  for (let guard = 0; guard < 10000; guard++) {
    let pick = null, pickId = null;
    for (const [id, t] of TIMERS) {
      if (t.due <= target && (!pick || t.due < pick.due)) { pick = t; pickId = id; }
    }
    if (!pick) break;
    CLOCK = pick.due;
    if (pick.repeat) pick.due = CLOCK + pick.ms; else TIMERS.delete(pickId);
    try { pick.fn(); } catch (e) { TIMER_ERRORS.push(String(e && e.message ? e.message : e)); }
  }
  CLOCK = target;
}

const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval(fn, ms) { return arm(fn, ms, true); },
  clearInterval(id) { disarm(id); },
  setTimeout(fn, ms) { return arm(fn, ms, false); },
  clearTimeout(id) { disarm(id); },
  fetch: fetchStub,
  FileReader: function () {
    const self = this;
    this.result = "";
    this.readAsDataURL = function () {
      self.result = "data:image/png;base64,QUJD";
      if (typeof self.onload === "function") self.onload();
    };
  },
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date: FakeDate,
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

/* ══════════════════ drive the spec ══════════════════ */

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const runErrors = [];

// The REAL view-only path: markViewOnly() is what a 403 from the write probe
// runs, so a readonly drive exercises exactly what a view-only build does (flag
// + the band's own write control disabled), not a hand-set flag.
if (spec.readonly) sandbox.markViewOnly();
if (spec.missionDetail) MISSION_DETAIL = spec.missionDetail;

try {
  sandbox.render(spec.board || { columns: {}, missions: [], meta: {} });
} catch (e) {
  runErrors.push("render: " + (e && e.message ? e.message : e));
}

// The board render is SETUP — only what the help console does is reported.
const bandBeforeHelp = projectBand();
const cards = projectCards();
const emptyState = {
  hidden: !!boardEmpty.hidden,
  text: boardEmpty.textContent,
};

// A binding added to the table AFTER boot must surface in the cheatsheet with no
// other change anywhere — the proof that the deck is GENERATED, not duplicated.
if (spec.addBinding && Array.isArray(sandbox.KEY_BINDINGS)) {
  sandbox.KEY_BINDINGS.push({
    id: spec.addBinding.id, keys: spec.addBinding.keys,
    on: spec.addBinding.on || [], scope: "global",
    label: spec.addBinding.label, run: null,
  });
}

if (spec.openOverlayFirst) {
  try { sandbox.showOverlay(new Element("div")); }
  catch (e) { overlayEl.hidden = false; }
}

/* A REAL console on the stage before ? is pressed — built by the SHIPPING code
 * path that builds it, then driven the way the captain drives it (type into the
 * idea box, click an engine option). The captain's own repro then continues:
 * click OUT of the field (focus leaves the textarea, so GUARD 1 lets ? through)
 * and press ?. `keepFocus` skips that last step to prove the guard still holds. */
function openConsoleFirst(cf) {
  const kind = cf.kind || "bare";
  if (kind === "bare") { sandbox.showOverlay(new Element("div")); return; }
  if (kind === "file") {
    sandbox.openFile();
    const ta = overlayEl.querySelector("textarea");
    if (ta && cf.type !== undefined) ta.value = cf.type;
    if (cf.pickEngine) {
      const want = String(cf.pickEngine).toLowerCase();
      overlayEl.querySelectorAll(".choice .opt").forEach(function (o) {
        if (o.textContent.toLowerCase().indexOf(want) !== -1) o.click();
      });
    }
  } else if (kind === "detail") {
    sandbox.openDetail(cf.mid || "v1");
  } else if (kind === "verify") {
    // The REAL Verify console, launch panel and all — its poll loop is the
    // second live loop the cover has to keep alive.
    sandbox.openVerify(cf.mid || "v1");
  } else if (kind === "align") {
    sandbox.renderAlignConsole({
      sessionId: "s-1", status: "asking",
      question: { text: "Which dialect?", choices: ["Alpha", "Beta"], recommended: "Beta" },
      prd: "**Goal:** ship it",
    }, false, null);
  }
  if (!cf.keepFocus && ACTIVE) ACTIVE.blur();
  // Tab-to-a-control inside the console (a footer button, the engine picker)
  // before ? is pressed: a NON-typing target, so GUARD 1 lets ? through.
  if (cf.focusSel) {
    const n = overlayEl.querySelector(cf.focusSel);
    if (!n) throw new Error("focusSel matched nothing: " + cf.focusSel);
    n.focus();
  }
}

if (spec.consoleFirst) {
  try { openConsoleFirst(spec.consoleFirst); }
  catch (e) { runErrors.push("consoleFirst: " + (e && e.message ? e.message : e)); }
}

FETCHES.length = 0;
CLICKS.length = 0;

/* Everything the overlay stage is holding right now. Captured before ?, while
 * help is up, and after help closes — three snapshots are all a save/restore
 * claim needs. The field readouts are LIVE input state (a textarea's value, the
 * engine picker's selected option), not markup, so a console that was
 * re-rendered rather than restored cannot pass. */
/* "On the stage" = actually rendered. A console the help cover HIDES in place is
 * still in the document (that is the whole point — its live loops keep running),
 * but the captain cannot see it, so it must not count as being on the stage. The
 * test walks up to the overlay body and asks whether the console subtree holding
 * this node is hidden. */
function onStage(node) {
  let cur = node;
  while (cur && cur !== overlayBodyEl) {
    if (cur.hidden) return false;
    if (cur.parentNode === overlayBodyEl) return !cur.hidden;
    cur = cur.parentNode;
  }
  return true;
}
function stageQuery(sel) {
  return overlayEl.querySelectorAll(sel).filter(onStage);
}

function projectStage() {
  return {
    hidden: !!overlayEl.hidden,
    modals: stageQuery(".modal, .detail-grid").map(function (n) {
      return n.getAttribute("class") || "";
    }),
    helps: stageQuery(".help-console").length,
    heads: stageQuery(".modal-head, .det-head h3").map(function (n) {
      return n.textContent;
    }),
    textareas: stageQuery("textarea").map(function (t) { return t.value; }),
    engine: stageQuery(".choice .opt.sel").map(function (o) {
      return o.textContent;
    }),
    inputs: stageQuery("input").map(function (i) { return i.value; }),
    focus: focusMark(),
  };
}

/* D-A: the LIVE readouts of whatever the overlay is holding — reported whether
 * or not it is currently visible, because the defect is precisely that a covered
 * console's loops stop. `clock` is the mission detail's ticking "Active …";
 * `launch` is the Verify console's launch panel (Launching… → ● LIVE). */
/* What a reader would actually READ off this subtree: `hidden` branches are not
 * on screen (board.css: `[hidden]{display:none !important}`), and a panel keeps
 * a hidden "Launching the app…" busy node around between renders. */
function visibleText(node) {
  if (!node || node.hidden) return "";
  if (node.nodeType === 3) return node._text;
  if (!node.children.length) return node._text;
  return node._text + node.children.map(visibleText).join("");
}
function projectLive() {
  const ar = overlayEl.querySelector(".ar-val");
  const lp = overlayEl.querySelector(".launch-panel");
  return {
    now: CLOCK,
    clock: ar ? ar.textContent : null,
    launch: lp ? visibleText(lp) : null,
    timers: TIMERS.size,
  };
}

// Where the keyboard captain's place is: the focused control, or null when
// focus has fallen back to the page.
function focusMark() {
  const a = documentStub.activeElement;
  if (!a || a === body || !overlayEl.contains(a)) return null;
  return { tag: a.tag, cls: a.getAttribute("class") || "", text: a.textContent };
}

const stageBeforeHelp = projectStage();
const liveBeforeHelp = projectLive();

function dispatchKey(k) {
  let stopped = false;
  const target = documentStub.activeElement;
  const ev = {
    type: "keydown",
    key: k.key,
    repeat: !!k.repeat,
    ctrlKey: !!k.ctrlKey,
    metaKey: !!k.metaKey,
    altKey: !!k.altKey,
    shiftKey: !!k.shiftKey,
    target: target,
    defaultPrevented: false,
    preventDefault() { this.defaultPrevented = true; },
    stopPropagation() { stopped = true; },
  };
  let cur = target;
  while (cur && cur.nodeType === 1 && !stopped) {
    const own = (cur._listeners["keydown"] || []).slice();
    for (const fn of own) { fn.call(cur, ev); if (stopped) break; }
    cur = cur.parentNode;
  }
  if (!stopped) {
    const ls = (documentStub._listeners["keydown"] || []).slice();
    for (const fn of ls) fn.call(documentStub, ev);
  }
  return ev.defaultPrevented;
}

if (spec.open === "key") {
  try { dispatchKey({ key: "?", shiftKey: true }); }
  catch (e) { runErrors.push("? key: " + (e && e.message ? e.message : e)); }
} else if (spec.open === "button") {
  try { helpBtn.click(); }
  catch (e) { runErrors.push("? button: " + (e && e.message ? e.message : e)); }
}

const openedHelp = projectHelp();
const stageAtHelp = projectStage();
const liveAtHelp = projectLive();

/* D-A: hold the cover for a while and let the world move underneath it. The
 * daemon's own record can change mid-cover (`missionDetailDuring` re-arms the
 * canned /api/mission read), and `advance` runs the virtual clock so every timer
 * that is STILL ARMED fires. A loop that died on the cover simply never runs. */
if (spec.missionDetailDuring) MISSION_DETAIL = spec.missionDetailDuring;
if (spec.advance) {
  try { advanceClock(spec.advance); }
  catch (e) { runErrors.push("advance: " + (e && e.message ? e.message : e)); }
}
const liveUnderCover = projectLive();

// A console taking the stage WHILE help is up (no UI route reaches this today —
// GUARD 2 blocks the hotkeys and the backdrop covers the cards — so it is driven
// directly): whatever help was holding must be released, not resurrected later.
if (spec.consoleDuringHelp) {
  try { openConsoleFirst(spec.consoleDuringHelp); }
  catch (e) { runErrors.push("consoleDuringHelp: " + (e && e.message ? e.message : e)); }
}

(spec.keys || []).forEach(function (k) {
  try { dispatchKey(k); }
  catch (e) { runErrors.push("key " + k.key + ": " + (e && e.message ? e.message : e)); }
});

/* Every close route the console actually renders. They must all land in the
 * same place — the ✕ in the modal head, the footer Close, the dimmed backdrop
 * and Escape are four doors out of ONE room. */
function closeVia(route) {
  if (route === "escape") { dispatchKey({ key: "Escape" }); return; }
  if (route === "x") {
    const x = overlayEl.querySelector(".modal-head .close");
    if (!x) throw new Error("no ✕ in the modal head");
    x.click(); return;
  }
  if (route === "footer") {
    const hits = overlayEl.querySelectorAll(".modal-foot .btn").filter(function (b) {
      return b.textContent.indexOf("Close") !== -1;
    });
    if (!hits.length) throw new Error("no footer Close");
    hits[0].click(); return;
  }
  if (route === "backdrop") { overlayEl.click(); return; }
  throw new Error("unknown close route: " + route);
}

if (spec.closeVia) {
  try { closeVia(spec.closeVia); }
  catch (e) { runErrors.push("closeVia " + spec.closeVia + ": " + (e && e.message ? e.message : e)); }
}

// Snapshot BEFORE the reference walk below, which drives consoles of its own.
const stageAfterClose = projectStage();
const liveAfterClose = projectLive();
// UX-32's leak register. Keeping a covered console's loops ALIVE must not turn
// into leaking them once the console really closes.
const detailTimers = Array.isArray(sandbox.DETAIL_TIMERS)
  ? sandbox.DETAIL_TIMERS.length : null;

/* ══════════════════ the ORIENTATION control-reference walk ══════════════════ */
/* The primer names on-screen controls; every one of them must resolve to a REAL
 * node, on the surface the step says it lives on, carrying the very label the
 * primer prints. Each surface is materialised by the shipping code path that
 * builds it — no fixtures of our own. */
function surfaceRoot(surface) {
  if (surface === "band") return topbar;
  if (surface === "board") return root.querySelector("#board");
  if (surface === "file-console") {
    sandbox.closeOverlay();
    sandbox.openFile();
    return overlayEl;
  }
  if (surface === "align-console") {
    sandbox.closeOverlay();
    sandbox.renderAlignConsole({
      sessionId: "s-1", status: "asking",
      question: { text: "Which dialect?", choices: ["Alpha", "Beta"], recommended: "Beta" },
      prd: "**Goal:** ship it",
    }, false, null);
    return overlayEl;
  }
  if (surface === "launch-console") {
    // The console ▶ Start engages — built by the SHIPPING openLaunch(), which
    // reads the mission through the same canned detail the verify surface uses.
    // Its ▶ Start Run is what actually spawns the driver, so the primer names
    // it and the walk proves it is there.
    sandbox.closeOverlay();
    sandbox.openLaunch(spec.verifyId || "v1");
    return overlayEl;
  }
  if (surface === "verify-console") {
    sandbox.closeOverlay();
    sandbox.openVerify(spec.verifyId || "v1");
    return overlayEl;
  }
  return null;
}

let refs = null;
if (spec.resolveRefs) {
  refs = [];
  const briefing = sandbox.ORIENTATION_BRIEFING;
  const steps = (briefing && briefing.steps) || [];
  steps.forEach(function (step) {
    (step.refs || []).forEach(function (ref) {
      let found = false, labelled = false, err = null, disabled = null;
      try {
        const host = surfaceRoot(ref.surface);
        const hits = host ? host.querySelectorAll(ref.selector) : [];
        found = hits.length > 0;
        const bearing = hits.filter(function (n) {
          return n.textContent.indexOf(ref.label) !== -1;
        });
        labelled = bearing.length > 0;
        // D-B: the MEASURED state of the control the primer names — the ground
        // truth the view-only line has to match. Read off the node that actually
        // carries the printed label, on a board driven through the real
        // markViewOnly() path.
        if (bearing.length) disabled = !!bearing[0].disabled;
      } catch (e) {
        err = String(e && e.message ? e.message : e);
      }
      refs.push({
        step: step.id, label: ref.label, selector: ref.selector,
        surface: ref.surface, found: found, labelled: labelled,
        disabled: disabled, error: err,
      });
    });
  });
  try { sandbox.closeOverlay(); } catch (e) { /* nothing open */ }
  // Column heads the primer names must exist on the rendered board.
  const heads = root.querySelectorAll("#board .col-head").map(function (h) {
    return h.textContent;
  });
  refs.columns = heads;
}

/* ══════════════════ report ══════════════════ */

/* D-C: every card on the board with the data-act controls it renders, as PRINTED.
 * The `s` key resolves data-act=start on whatever card holds focus — and a
 * standby card puts a completely different control (and console) behind that
 * same identity than a holding card does. A label that names one of them is a
 * lie on the other, so the test measures both off the real card builder. */
function projectCards() {
  const boardEl = root.querySelector("#board");
  if (!boardEl) return [];
  return boardEl.querySelectorAll(".card").map(function (c) {
    return {
      mid: c.getAttribute("data-mid") || "",
      acts: c.querySelectorAll("[data-act]").map(function (n) {
        return {
          act: n.getAttribute("data-act"), text: n.textContent,
          disabled: !!n.disabled,
        };
      }),
    };
  });
}

function projectBand() {
  return topbar.children.map(function (n) {
    return {
      tag: n.tag, id: n.getAttribute("id") || "",
      cls: n.getAttribute("class") || "", text: n.textContent,
      disabled: !!n.disabled, title: n.title || "",
    };
  });
}

function projectHelp() {
  // The VISIBLE modal — with a console covered in place there are two nodes on
  // the overlay and only one of them is on screen.
  const wrap = stageQuery(".modal")[0];
  if (overlayEl.hidden || !wrap) return { open: false };
  const isHelp = !!stageQuery(".help-console").length;
  const one = function (sel) {
    const hits = stageQuery(sel);
    return hits.length ? hits[0] : null;
  };
  return {
    open: true,
    isHelp: isHelp,
    title: (wrap.querySelector(".modal-head") || { textContent: "" }).textContent,
    sections: stageQuery(".help-sec").map(function (s) {
      return { id: s.getAttribute("id") || "", title: (s.querySelector("h4") || { textContent: "" }).textContent };
    }),
    rows: stageQuery(".keyrow").map(function (r) {
      return {
        caps: r.querySelectorAll("kbd").map(function (k) { return k.textContent; }),
        label: (r.querySelector(".keylabel") || { textContent: "" }).textContent,
      };
    }),
    steps: stageQuery(".orient-step").map(function (s) {
      return {
        id: s.getAttribute("data-step") || "",
        title: (s.querySelector(".step-title") || { textContent: "" }).textContent,
        text: (s.querySelector(".step-body") || { textContent: "" }).textContent,
      };
    }),
    intro: (one(".orient-intro") || { textContent: null }).textContent,
    viewOnlyNote: (one(".help-viewonly") || { textContent: null }).textContent,
    scrollHosts: stageQuery(".modal-body").length,
  };
}

const bindings = Array.isArray(sandbox.KEY_BINDINGS)
  ? sandbox.KEY_BINDINGS.map(function (b) {
      return { id: b.id, keys: b.keys, label: b.label };
    })
  : null;

const briefingOut = sandbox.ORIENTATION_BRIEFING
  ? {
      intro: sandbox.ORIENTATION_BRIEFING.intro,
      viewOnly: sandbox.ORIENTATION_BRIEFING.viewOnly,
      deckIntro: sandbox.ORIENTATION_BRIEFING.deckIntro,
      columns: sandbox.ORIENTATION_BRIEFING.columns,
      steps: (sandbox.ORIENTATION_BRIEFING.steps || []).map(function (s) {
        return { id: s.id, title: s.title, body: s.body, refs: s.refs || [] };
      }),
    }
  : null;

process.stdout.write(JSON.stringify({
  bootErrors: bootErrors,
  runErrors: runErrors,
  timerErrors: TIMER_ERRORS,
  bindings: bindings,
  briefing: briefingOut,
  help: openedHelp,
  helpAfterKeys: projectHelp(),
  stageBeforeHelp: stageBeforeHelp,
  stageAtHelp: stageAtHelp,
  stageAfterClose: stageAfterClose,
  liveBeforeHelp: liveBeforeHelp,
  liveAtHelp: liveAtHelp,
  liveUnderCover: liveUnderCover,
  liveAfterClose: liveAfterClose,
  detailTimers: detailTimers,
  cards: cards,
  band: bandBeforeHelp,
  bandAfter: projectBand(),
  emptyState: emptyState,
  clicks: CLICKS,
  fetches: FETCHES,
  overlayHidden: !!overlayEl.hidden,
  refs: refs,
  refColumns: refs ? refs.columns : null,
  status: (root.querySelector("#status") || { textContent: "" }).textContent,
}));
