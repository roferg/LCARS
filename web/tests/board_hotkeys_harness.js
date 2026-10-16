"use strict";
/* S140 keyboard-command-deck harness — loads the SHIPPING web/static/board.js in a
 * sandboxed vm against a MINI-DOM (no jsdom, no build step — ADR-007), renders a
 * real board with render(), then dispatches real `keydown` events at the document
 * so the shipping hotkey layer runs exactly as it does in a browser.
 *
 * It is deliberately richer than the other board_*_harness.js stubs because the
 * hotkey layer is DOM-behavioural: it needs activeElement, focus(), .click() with
 * bubbling + the disabled short-circuit, closest(), and attribute selectors.
 *
 * argv[2]: a JSON spec file:
 *   {
 *     "board":   <the /api/board shape passed to render()>,
 *     "readonly": true|false,          // sets writesActive=false before render
 *     "focus":   "<data-mid>",         // focus that card before the keys
 *     "focusTextarea": true,           // focus a TEXTAREA instead (typing guard)
 *     "focusInput": true,              // focus an INPUT instead
 *     "openOverlay": true,             // open the overlay before the keys
 *     "openFile": true,                // open the REAL File console (openFile())
 *     "openAlign": <align state>,      // open the REAL Align grill console
 *     "pasteImage": true,              // paste an image into the File console's
 *                                      // idea box (so an ✕ chip exists)
 *     "typeFree": "<text>",            // type into the console's free-form box
 *                                      // (fires `input`, as a real keystroke does)
 *     "focusSelector": "<sel>",        // focus a node by selector…
 *     "focusIndex": 1,                 // …the Nth match (default 0)
 *     "keys": [ {"key":"s","repeat":false,"metaKey":false,...}, ... ]
 *   }
 *
 * stdout: a JSON report — see buildReport() at the bottom.
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

/* ══════════════════ a very small DOM ══════════════════ */

const CLICKS = [];   // every .click() the run performed (hotkey or otherwise)
const FETCHES = [];  // every fetch() the run performed (the no-bypass proof)
let ACTIVE = null;   // document.activeElement

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

// selector → list of {parts:[compound,...]} (descendant combinator only, which is
// all board.js and the hotkey layer use).
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
  this.hidden = false;
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
Element.prototype.removeChild = function (c) {
  const i = this.children.indexOf(c);
  if (i !== -1) { this.children.splice(i, 1); c.parentNode = null; }
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
    cls: this.getAttribute("class") || "",
    text: this.textContent,
    disabled: !!this.disabled,
    mid: this.closest("[data-mid]") ? this.closest("[data-mid]").getAttribute("data-mid") : null,
    // A real DOM .click() on a DISABLED button dispatches nothing at all.
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
    this.children.forEach(function (c) { c.parentNode = null; });
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

/* ══════════════════ the page (index.html, minus the chrome we don't render) ══ */

/* The spec is read HERE, before the DOM and before board.js boots, because
   `spec.storage` seeds localStorage and a cold-boot-with-a-remembered-choice
   test is exactly what "it survives a refresh" means. Everything downstream
   still uses the same `spec` object. */
const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const STORE = Object.create(null);
Object.keys(spec.storage || {}).forEach(function (k) {
  STORE[k] = String(spec.storage[k]);
});

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
mk("div", "conn", "conn", topbar);
const content = mk("div", null, "frame-content", frame);
mk("div", "versionBanner", "version-banner", content);
mk("div", "readinessBanner", "readiness-banner", content);
/* S275 — the "no engine on this machine" band. Same host shape and the same
   `.version-banner` wrapper index.html gives it, so the projection below reads
   the real thing rather than a stand-in. */
const engineBannerHost = mk("div", "engineBanner", "version-banner", content);
engineBannerHost.hidden = true;
/* S196 B5 — the ownership filter strip. Its own row in frame-content, above the
   board, exactly where index.html puts it. Present-but-empty here, as it is on a
   cold page: renderOwnerFilter fills it (or hides it) on every render. */
const ownerFilterHost = mk("div", "ownerFilter", "owner-filter", content);
ownerFilterHost.hidden = true;
const boardWrap = mk("div", null, "board-wrap", content);
mk("div", "board", "board", boardWrap);
const legend = mk("div", null, "legend", content);
mk("span", "status", "dim", legend);
mk("span", "viewonly", "dim viewonly", legend);
const overlayEl = mk("div", "overlay", "overlay");
overlayEl.hidden = true;
mk("div", "overlayBody", "overlay-stage", overlayEl);

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
// A real browser resets document.activeElement to <body> the moment the focused
// element leaves the document (which is exactly what render()'s innerHTML="" does
// to the focused card) — mirror that, or a detached card would keep "focus".
Object.defineProperty(documentStub, "activeElement", {
  get() { return ACTIVE && root.contains(ACTIVE) ? ACTIVE : body; },
});

function fetchStub(url, opts) {
  /* `body` is ADDITIVE (S275): the File console's whole defect was the engine
     it POSTs, and a projection that records only the URL cannot see it. */
  FETCHES.push({ url: String(url), method: (opts && opts.method) || "GET",
                 body: (opts && opts.body) || null });
  const p = { then() { return p; }, catch() { return p; } };
  return p;
}

const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: {
    getItem(k) {
      return Object.prototype.hasOwnProperty.call(STORE, k) ? STORE[k] : null;
    },
    setItem(k, v) { STORE[String(k)] = String(v); },
    removeItem(k) { delete STORE[String(k)]; },
  },
  setInterval() { return 0; }, clearInterval() {},
  setTimeout() { return 0; }, clearTimeout() {},
  fetch: fetchStub,
  // Synchronous stand-in: the File console's image paster reads a pasted file as
  // a data URL. Firing onload inline keeps the harness free of async plumbing.
  FileReader: function () {
    const self = this;
    this.result = "";
    this.readAsDataURL = function () {
      self.result = "data:image/png;base64,QUJD";
      if (typeof self.onload === "function") self.onload();
    };
  },
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date, Array, Object, String, Number, Boolean, RegExp, Error,
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

const runErrors = [];

if (spec.readonly) sandbox.writesActive = false;

try {
  sandbox.render(spec.board || { columns: {}, missions: [], meta: {} });
} catch (e) {
  runErrors.push("render: " + (e && e.message ? e.message : e));
}

if (spec.focus) {
  const card = root.querySelector('[data-mid="' + spec.focus + '"]');
  if (card) card.focus();
}
if (spec.focusChildAct) {
  const card = root.querySelector('[data-mid="' + spec.focus + '"]');
  const inner = card && card.querySelector('[data-act="' + spec.focusChildAct + '"]');
  if (inner) inner.focus();
}
if (spec.focusTextarea) {
  const ta = new Element("textarea");
  body.appendChild(ta);
  ta.focus();
}
if (spec.focusInput) {
  const inp = new Element("input");
  body.appendChild(inp);
  inp.focus();
}
if (spec.focusContentEditable) {
  const ce = new Element("div");
  ce.isContentEditable = true;
  body.appendChild(ce);
  ce.focus();
}
if (spec.openOverlay) {
  try { sandbox.showOverlay(new Element("div")); } catch (e) { overlayEl.hidden = false; }
}
// The REAL File console — the span-as-control surfaces (engine picker, image
// chips) only exist once openFile() has built it.
if (spec.openFile) {
  try { sandbox.openFile(); } catch (e) { runErrors.push("openFile: " + (e && e.message ? e.message : e)); }
}
// The REAL Align grill console — the answer options are the same span-as-control
// idiom, one screen on from "File & Begin Alignment".
if (spec.openAlign) {
  try { sandbox.renderAlignConsole(spec.openAlign, false, null); }
  catch (e) { runErrors.push("renderAlignConsole: " + (e && e.message ? e.message : e)); }
}

function fire(node, type, ev) {
  if (!node) return;
  ev.type = type;
  ev.target = node;
  if (!ev.preventDefault) ev.preventDefault = function () {};
  if (!ev.stopPropagation) ev.stopPropagation = function () {};
  (node._listeners[type] || []).slice().forEach(function (fn) { fn.call(node, ev); });
}

if (spec.pasteImage) {
  const ta = overlayEl.querySelector("textarea");
  const file = { type: "image/png", size: 64, name: "shot.png" };
  const items = [{ kind: "file", getAsFile() { return file; } }];
  fire(ta, "paste", { clipboardData: { items: items } });
}
if (spec.typeFree) {
  const ta = overlayEl.querySelector("textarea");
  if (ta) { ta.value = spec.typeFree; fire(ta, "input", {}); }
}
if (spec.focusSelector) {
  const hits = root.querySelectorAll(spec.focusSelector);
  const node = hits[spec.focusIndex || 0];
  if (node) node.focus();
  else runErrors.push("focusSelector matched nothing: " + spec.focusSelector);
}

// Everything before this point is setup — only the keys' effects are reported.
FETCHES.length = 0;
CLICKS.length = 0;
const overlayHiddenBefore = !!overlayEl.hidden;

// A real keydown fires at the focused element and BUBBLES to the document, so a
// control that handles its own key (the File console's span-as-button pickers)
// runs first and can stopPropagation before the global command deck sees it.
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

const prevented = [];
(spec.keys || []).forEach(function (k) {
  // A `rerender` pseudo-key re-runs render() with a (possibly new) board, so a
  // test can prove focus survives a full board rebuild.
  // A `click` pseudo-key clicks a real node by selector, so a mouse gesture and
  // a keystroke can be interleaved in one ordered stream (the strip is driven
  // both ways and the two must land on the same state).
  if (k.click) {
    const target = root.querySelector(k.click);
    if (!target) { runErrors.push("click: no node matches " + k.click); }
    else { try { target.click(); } catch (e) { runErrors.push("click " + k.click + ": " + (e && e.message ? e.message : e)); } }
    prevented.push(null);
    return;
  }
  if (k.rerender) {
    try { sandbox.render(k.board || spec.board); }
    catch (e) { runErrors.push("rerender: " + (e && e.message ? e.message : e)); }
    prevented.push(null);
    return;
  }
  try { prevented.push(dispatchKey(k)); }
  catch (e) { runErrors.push("key " + k.key + ": " + (e && e.message ? e.message : e)); prevented.push(null); }
});

/* ══════════════════ S275 — the File console's engine picker ══════════════
 * Clicking an engine and then SUBMITTING is the only way to see the value the
 * daemon is actually handed, which is where this session's defect lived: the
 * console looked fine and posted `claude` on a machine that had no claude.
 * Run after the keys so a keyboard-driven pick can be submitted too. */
function consoleOpt(name) {
  return overlayEl.querySelectorAll(".choice .opt").filter(function (o) {
    return String(o.textContent || "").toLowerCase().indexOf(name) !== -1;
  })[0] || null;
}
function footBtn(re) {
  return overlayEl.querySelectorAll("button").filter(function (b) {
    return re.test(String(b.textContent || ""));
  })[0] || null;
}
let filePost = null;
/* CAPTURED BEFORE THE SUBMIT, deliberately: pressing ◇ File to Backlog ▸
 * rewrites its own label to "Filing…", so a report that re-finds it by text
 * afterwards finds nothing and projects `submit: null`. */
const submitNode = footBtn(/File to Backlog/);
const alignNode = footBtn(/Begin Alignment/);
if (spec.clickEngine) {
  const opt = consoleOpt(String(spec.clickEngine).toLowerCase());
  if (!opt) runErrors.push("clickEngine matched no option: " + spec.clickEngine);
  else opt.click();
}
if (spec.keyEngine) {
  const opt = consoleOpt(String(spec.keyEngine).toLowerCase());
  if (!opt) runErrors.push("keyEngine matched no option: " + spec.keyEngine);
  else {
    // the keydown path only — role/tabindex are a promise the KEY has to keep
    fire(opt, "keydown", { key: spec.keyEngineKey || "Enter" });
  }
}
if (spec.submitFile) {
  FETCHES.length = 0;
  const b = spec.submitFile === "align"
    ? footBtn(/Begin Alignment/) : footBtn(/File to Backlog/);
  if (!b) runErrors.push("submitFile found no button: " + spec.submitFile);
  else {
    const ta = overlayEl.querySelector("textarea");
    if (ta) { ta.value = spec.idea || "ship the thing"; }
    b.click();
  }
  const post = FETCHES.filter(function (f) { return f.method === "POST"; })[0];
  filePost = post
    ? { url: post.url, body: post.body ? JSON.parse(post.body) : null }
    : null;
}

/* ══════════════════ report ══════════════════ */

function projectCard(card) {
  return {
    mid: card.getAttribute("data-mid"),
    role: card.getAttribute("role"),
    tabindex: card.getAttribute("tabindex"),
    acts: card.querySelectorAll("[data-act]").map(function (b) {
      return { act: b.getAttribute("data-act"), text: b.textContent, disabled: !!b.disabled };
    }),
  };
}

// Structure-only projection (tag / class / text / disabled) — used to prove the
// S140 render diff is ATTRIBUTE-ONLY: role/tabindex/data-act never change this.
function structure(n) {
  if (!n) return null;
  return {
    tag: n.tag,
    cls: n.getAttribute("class") || "",
    text: n._text || "",
    disabled: !!n.disabled,
    children: n.children.map(structure).filter(Boolean),
  };
}

const columns = root.querySelectorAll(".board .col").map(function (col) {
  return {
    head: (col.querySelector(".col-head") || { textContent: "" }).textContent,
    cards: col.querySelectorAll(".card[data-mid]").map(projectCard),
  };
});

const focused = documentStub.activeElement;
const focusedCard = focused && focused.closest ? focused.closest("[data-mid]") : null;

const bindings = Array.isArray(sandbox.KEY_BINDINGS)
  ? sandbox.KEY_BINDINGS.map(function (b) {
      return { id: b.id, keys: b.keys, label: b.label, scope: b.scope,
               on: b.on || [], acts: b.acts || null,
               overlaySafe: !!b.overlaySafe };
    })
  : null;

// Span-as-control surfaces inside the open console — the keyboard-reachability
// projection (role/tabindex) plus the state class the pick writes (.sel).
function projectControl(n) {
  return {
    tag: n.tag,
    cls: n.getAttribute("class") || "",
    text: n.textContent,
    role: n.getAttribute("role"),
    tabindex: n.getAttribute("tabindex"),
    ariaPressed: n.getAttribute("aria-pressed"),
    // S275 — the lock treatment: `disabled`, the `locked` class markLocked
    // writes, and the tooltip that says WHY.
    disabled: !!n.disabled,
    title: n.title || "",
    engine: n.getAttribute("data-engine"),
  };
}
const consoleOpts = overlayEl.querySelectorAll(".choice .opt").map(projectControl);
const fileConsole = {
  opts: consoleOpts,
  chipRemoves: overlayEl.querySelectorAll(".img-chip-x").map(projectControl),
  chips: overlayEl.querySelectorAll(".img-chip").length,
  // S275 — the submit, its lock state, and the sentence that explains it.
  submit: submitNode
    ? { text: submitNode.textContent, disabled: !!submitNode.disabled,
        title: submitNode.title || "" } : null,
  align: alignNode
    ? { text: alignNode.textContent, disabled: !!alignNode.disabled,
        title: alignNode.title || "" } : null,
  engineNote: overlayEl.querySelectorAll(".engine-none").map(function (n) {
    return n.textContent;
  }),
  post: filePost,
};
/* S275 — the band a machine with NO LCARS-capable CLI gets. `bands` is a COUNT,
   not a boolean: "shown once" is the contract, and a render loop that stacks
   three of them passes every present/absent assertion. */
const engineBanner = {
  hidden: !!engineBannerHost.hidden,
  bands: engineBannerHost.querySelectorAll(".vb-band").length,
  text: engineBannerHost.textContent,
};
// The Align grill console renders its answer options through the very same
// `.choice .opt` idiom; `freeValue` is the free-form box that overrides a pick.
const alignConsole = {
  opts: consoleOpts,
  freeValue: (overlayEl.querySelector("textarea") || { value: null }).value,
};

let firstCardStructure = null;
const firstCard = root.querySelector(".board .card[data-mid]");
if (firstCard) firstCardStructure = structure(firstCard);

/* THE STRIP, as rendered. `hidden` is projected beside the chips because "the
   board offers no filter at all" and "the board offers an empty filter" are
   different products and only one of them is honest. */
const ownerFilter = {
  hidden: !!ownerFilterHost.hidden,
  chips: ownerFilterHost.querySelectorAll("button").map(function (b) {
    return { id: b.getAttribute("data-filter"), text: b.textContent,
             count: b.getAttribute("data-count"),
             cls: b.getAttribute("class") || "",
             pressed: b.getAttribute("aria-pressed"),
             title: b.title || "", disabled: !!b.disabled };
  }),
};

process.stdout.write(JSON.stringify({
  bootErrors: bootErrors,
  ownerFilter: ownerFilter,
  storage: JSON.parse(JSON.stringify(STORE)),
  runErrors: runErrors,
  columns: columns,
  bindings: bindings,
  clicks: CLICKS,
  fetches: FETCHES,
  prevented: prevented,
  overlayHiddenBefore: overlayHiddenBefore,
  overlayHidden: !!overlayEl.hidden,
  focusedMid: focusedCard ? focusedCard.getAttribute("data-mid") : null,
  focusedTag: focused ? focused.tagName : null,
  status: (root.querySelector("#status") || { textContent: "" }).textContent,
  cardStructure: firstCardStructure,
  fileConsole: fileConsole,
  alignConsole: alignConsole,
  engineBanner: engineBanner,
}));
