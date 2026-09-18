"use strict";
/* S205 fix round 2, D2 — THE FIRST OFFICER'S REPORT modal's chip row, in a
 * sandboxed vm.
 *
 * Loads the SHIPPING web/static/board.js against a real (if synthetic) DOM,
 * opens the report modal the real way (`openXoReport()`), lets the report's
 * own `fetch("/api/xo/report")` resolve SYNCHRONOUSLY off a canned payload
 * (the same "settled" thenable trick board_help_harness.js uses — no
 * microtask race to get lost in), then CLICKS the chips in order and
 * projects, after EVERY click, which chip(s) actually carry the `.on`
 * marker and — since the captain has already ruled once that a state read
 * only by hue is a defect — the actual computed distinguishing attributes
 * (class list) rather than a colour.
 *
 * This is the composition proof for the defect the tester found: filtering
 * itself was already correct (the list's own count moves), but `.on` never
 * left "All" because the click handler rebuilt the LIST and never the chip
 * row. A DOM test that only checked filtering, like the render() unit
 * itself, would miss exactly this — the same lesson D1's shot-route test
 * teaches about composition over isolation.
 *
 * argv[2]: a JSON spec file:
 *   { "reportData": <the GET /api/xo/report payload>,
 *     "clicks": [ "all"                    // a FILTER CHIP, by key
 *               | {"view": "time"}         // the by-time / by-mission switch
 *               | {"seen": "<entry key>"}  // one entry's ✓ Seen button
 *               | {"open": "<mission id>"} // a mission header's way in
 *               ],
 *     "seenResponses": [ <report payload>, … ]  // what the daemon answers to
 *   }                                           // each POST /api/xo/seen, in
 *                                               // order. S213 generates these
 *                                               // with the REAL builder after
 *                                               // a REAL mark, so the board is
 *                                               // repainted off what the
 *                                               // server would truly send.
 *
 * stdout: a JSON report — see the bottom of the file.
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

/* ══════════════════ a small real DOM (borrowed verbatim from
   board_help_harness.js's own engine — same selector grammar, same
   classList semantics, proven against this exact board.js already) ══ */

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
const CLICKS = [];
const FETCHES = [];
let ACTIVE = null;

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
  this.type = "";
  this.placeholder = "";
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
Object.defineProperty(Element.prototype, "hidden", {
  get() { return !!this._hidden; },
  set(v) { this._hidden = !!v; if (this._hidden) dropFocusInside(this); },
});

function TextNode(t) {
  Element.call(this, "#text");
  this.nodeType = 3;
  this._text = t == null ? "" : String(t);
}
TextNode.prototype = Object.create(Element.prototype);
TextNode.prototype.constructor = TextNode;

/* ══════════════════ the page — just enough of index.html's band for
   board.js's unconditional boot wiring (fileBtn) not to throw ══════════ */

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
const xoBtn = mk("button", "xoBtn", "btn xo-toggle", topbar);
xoBtn.hidden = true;
mk("button", "deployMainBtn", "btn go", topbar);
mk("button", "fileBtn", "btn go", topbar);
mk("button", "helpBtn", "btn help-btn", topbar);
mk("div", "conn", "conn", topbar);
const content = mk("div", null, "frame-content", frame);
mk("div", "versionBanner", "version-banner", content);
mk("div", "readinessBanner", "readiness-banner", content);
const boardEmpty = mk("div", "boardEmpty", "board-empty", content);
boardEmpty.hidden = true;
const boardWrap = mk("div", null, "board-wrap", content);
mk("div", "board", "board", boardWrap);
const legendEl = mk("div", null, "legend", content);
mk("span", "status", "dim", legendEl);
mk("span", "viewonly", "dim viewonly", legendEl);
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

/* A fetch that resolves SYNCHRONOUSLY for GET /api/xo/report (the exact
 * "settled" thenable board_help_harness.js's own mission-detail stub uses —
 * no microtask race between `openXoReport()`'s `.then(paint)` chain and this
 * script reading the DOM afterwards) and stays inert for everything else
 * (board.js's boot probes /api/board etc.; not this harness's subject). */
const REPORT_DATA = JSON.parse(fs.readFileSync(process.argv[2], "utf8")).reportData
  || { since: { count: 0, entries: [] }, history: [], lastSeenAt: null };

function settled(value) {
  const p = {
    then(fn) {
      if (!fn) return p;
      const out = fn(value);
      return out && typeof out.then === "function" ? out : settled(out);
    },
    catch() { return p; },
  };
  return p;
}
const SEEN_RESPONSES = (JSON.parse(fs.readFileSync(process.argv[2], "utf8"))
  .seenResponses) || [];
let seenPosts = 0;

function fetchStub(url, opts) {
  const method = (opts && opts.method) || "GET";
  let body = null;
  try { body = JSON.parse((opts && opts.body) || "null"); } catch (e) { body = null; }
  FETCHES.push({ url: String(url), method: method, body: body });
  if (method === "GET" && String(url) === "/api/xo/report") {
    return settled({ status: 200, json() { return settled(REPORT_DATA); } });
  }
  // The daemon answers a ✓ Seen with the FRESH report (server.py), wrapped in
  // the ordinary write envelope — so the board repaints off a real answer and
  // never has to ask twice.
  if (method === "POST" && String(url) === "/api/xo/seen") {
    const next = SEEN_RESPONSES[seenPosts++] || REPORT_DATA;
    return settled({ status: 200,
                     json() { return settled({ ok: true, state: next }); } });
  }
  const p = { then() { return p; }, catch() { return p; } };
  return p;
}

const sandbox = {
  document: documentStub,
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval() { return 0; },
  clearInterval() {},
  setTimeout() { return 0; },
  clearTimeout() {},
  fetch: fetchStub,
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
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

for (const name of ["openXoReport", "XO_REPORT_CHIPS"]) {
  if (sandbox[name] === undefined) {
    process.stderr.write(name + " is not defined\n");
    process.exit(2);
  }
}

/* ══════════════════ drive it ══════════════════ */

const spec = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));

try {
  sandbox.openXoReport();
} catch (e) {
  bootErrors.push("openXoReport: " + (e && e.message ? e.message : e));
}

function chipRow() { return overlayEl.querySelector(".xo-report-chips"); }
function chipSnapshot() {
  const row = chipRow();
  if (!row) return [];
  return row.children.map(function (c) {
    return { text: (c.textContent || "").trim(), cls: c.getAttribute("class") || "" };
  });
}
function sinceHeadText() {
  const h = overlayEl.querySelector(".xo-report-since-head");
  return h ? h.textContent : null;
}

const chipsAtOpen = chipSnapshot();
const sinceHeadAtOpen = sinceHeadText();

/* ── S213: the GROUPED view, projected in DOCUMENT ORDER ─────────────────── */
function project(n) {
  if (!n || n.nodeType !== 1) return null;
  return {
    tag: String(n.tagName || "").toLowerCase(),
    cls: n.getAttribute("class") || "",
    text: (n.textContent || "").trim(),
    key: n.getAttribute("data-key") || "",
    mission: n.getAttribute("data-mission") || "",
    chip: n.getAttribute("data-chip") || "",
    view: n.getAttribute("data-view") || "",
    disabled: !!n.disabled,
    children: (n.children || []).map(project).filter(Boolean),
  };
}
function snapshot() {
  const body = overlayEl.querySelector(".overlay-stage") || overlayEl;
  return {
    chips: chipSnapshot(),
    views: (overlayEl.querySelectorAll(".xo-view") || []).map(function (v) {
      return { text: (v.textContent || "").trim(),
               cls: v.getAttribute("class") || "",
               view: v.getAttribute("data-view") || "" };
    }),
    groups: (overlayEl.querySelectorAll(".xo-mgrp") || []).map(project),
    // The BY-TIME list only. `.xo-report-entry` is also the row History folds,
    // and counting both would have made the flat list look twice its size.
    flat: (overlayEl.querySelectorAll(".xo-report-since .xo-report-entry")
           || []).map(project),
    histLine: (function () {
      const h = overlayEl.querySelector(".xo-hist-line");
      return h ? (h.textContent || "").trim() : null;
    })(),
    tree: project(body),
  };
}

const atOpen = snapshot();

const afterClicks = [];
(spec.clicks || []).forEach(function (step) {
  let clickErr = null;
  let hit = null;
  if (typeof step === "string") {
    const row = chipRow();
    hit = row ? row.children.filter(function (c) {
      return (c.getAttribute("data-chip") || "") === step;
    })[0] : null;
    if (!hit) clickErr = "no chip for key " + step;
  } else if (step && step.view) {
    hit = (overlayEl.querySelectorAll(".xo-view") || []).filter(function (v) {
      return (v.getAttribute("data-view") || "") === step.view;
    })[0];
    if (!hit) clickErr = "no view switch for " + step.view;
  } else if (step && step.seen) {
    hit = (overlayEl.querySelectorAll(".xo-seen") || []).filter(function (b) {
      return (b.getAttribute("data-key") || "") === step.seen;
    })[0];
    if (!hit) clickErr = "no ✓ Seen button for entry " + step.seen;
  } else if (step && step.open) {
    hit = (overlayEl.querySelectorAll(".xo-mopen") || []).filter(function (a) {
      return (a.getAttribute("data-mission") || "") === step.open;
    })[0];
    if (!hit) clickErr = "no way in for mission " + step.open;
  } else {
    clickErr = "unrecognised click step";
  }
  if (hit) {
    try { hit.click(); } catch (e) { clickErr = String(e && e.message ? e.message : e); }
  }
  const shot = snapshot();
  shot.step = step;
  shot.error = clickErr;
  shot.sinceHead = sinceHeadText();
  afterClicks.push(shot);
});

/* WRITTEN SYNCHRONOUSLY, then exit. `process.stdout.write` on a pipe is
   ASYNC, and the `process.exit(0)` below it — which this harness needs, because
   board.js's boot arms timers — truncated the report the moment it outgrew the
   pipe buffer. The symptom was a JSON parse error at a byte offset that moved
   with the fixture, which reads exactly like a bug in the code under test. */
fs.writeSync(1, JSON.stringify({
  bootErrors: bootErrors,
  chipsAtOpen: chipsAtOpen,
  sinceHeadAtOpen: sinceHeadAtOpen,
  atOpen: atOpen,
  afterClicks: afterClicks,
  fetches: FETCHES,
  overlayHidden: !!overlayEl.hidden,
}));
process.exit(0);
