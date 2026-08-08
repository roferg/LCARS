"use strict";
/* S125 HOLODECK-render harness — loads the SHIPPING web/static/board.js in a
 * sandboxed vm with browser stubs, then drives the REAL deck functions
 * (holoSetMode / renderDeck / holoApplyFilesChanged / openNewProgram /
 * holoSetBanner / applyHolodeckWriteState) and projects the produced DOM to
 * inspectable JSON. Same convention as board_band_harness.js and
 * board_card_harness.js: no DOM library, no build step (ADR-007).
 *
 * WHAT IT CANNOT SEE, said here rather than discovered later: it calls the
 * render functions itself, so it can never tell a working page from a blank
 * one, and it has NO CSS — a pane hidden by `display:none`, sized to zero, or
 * painted the same colour as its background passes every assertion below.
 * `tests/drives/browser/holodeck.sh` is the half that opens real Chrome and
 * MEASURES what painted. Both are required.
 *
 * argv[2]: a JSON file — {act: "...", ...}. See the switch at the bottom.
 */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

/* ── a small DOM stub that is honest about class lists, attributes and text ──
 * Richer than the older harnesses' stub in exactly three ways the deck needs:
 * classList is backed by the real className string (board.js sets both),
 * attributes are RECORDED (the sandbox attribute and data-ctl live there), and
 * querySelector supports the handful of selector shapes board.js actually uses.
 */
function clsList(node) {
  return String(node._cls || "").split(/\s+/).filter(Boolean);
}

/* every scrollIntoView() / focus() board.js asked for, in order */
const SCROLLS = [];
const FOCUSED = [];

/* `children` IS ELEMENTS ONLY — the single most expensive lie a DOM stub can
 * tell. In a real browser `Element.children` is an HTMLCollection of ELEMENT
 * children; text nodes live only in `childNodes`. The first cut of this stub
 * put text nodes in `children`, and S125's reply renderer — which guards
 * `if (para.children.length)` before appending a paragraph — therefore passed
 * every assertion here while DROPPING every plain-text paragraph in real
 * Chrome. It was the browser rig that found it. Keeping the two collections
 * distinct is what lets this harness see that class at all. */
function isElement(n) { return !!(n && n.tag && n.tag.charAt(0) !== "#"); }
function setCls(node, list) { node._cls = list.join(" "); }

/* A style object that RECORDS custom properties. S128's split lives in two CSS
 * custom properties on `.deckview` (`--holo-chat-fr` / `--holo-pv-fr`) rather
 * than an inline `grid-template-columns`, precisely so `.deckview.solo` keeps
 * its own rule — so `setProperty` is the one write this harness has to see.
 * It records; it computes NOTHING. No column is ever laid out here. */
function stubStyle() {
  const props = {};
  const style = {
    _props: props,
    setProperty(k, v) { props[k] = String(v); },
    removeProperty(k) { delete props[k]; },
    getPropertyValue(k) {
      return Object.prototype.hasOwnProperty.call(props, k) ? props[k] : "";
    },
  };
  return style;
}

function stubEl(tag) {
  const node = {
    tag: tag || "",
    style: stubStyle(),
    attrs: {},
    _kids: [],
    parent: null,
    listeners: {},
    _text: "",
    _html: "",
    _cls: "",
    title: "",
    hidden: false,
    disabled: false,
    value: "",
    type: "",
    rows: 0,
    placeholder: "",
    src: "",
  };
  node.classList = {
    add() {
      const s = clsList(node);
      for (const c of arguments) if (s.indexOf(c) === -1) s.push(c);
      setCls(node, s);
    },
    remove() {
      let s = clsList(node);
      for (const c of arguments) s = s.filter((x) => x !== c);
      setCls(node, s);
    },
    toggle(c, on) {
      const has = clsList(node).indexOf(c) !== -1;
      const want = on === undefined ? !has : !!on;
      if (want) node.classList.add(c); else node.classList.remove(c);
      return want;
    },
    contains(c) { return clsList(node).indexOf(c) !== -1; },
  };
  node.appendChild = function (c) {
    if (c) { c.parent = node; node._kids.push(c); }
    return c;
  };
  node.removeChild = function (c) {
    node._kids = node._kids.filter((x) => x !== c);
    return c;
  };
  /* S169 fix round 2 — `Node.contains`. Real elements have it, this stub did
   * not, and board.js uses `document.body.contains(node)` as its standard "is
   * this still on the page?" guard for every repeating timer and poll (the
   * help console, the launch poller, the check band's poll). Without it the
   * harness THREW on the first such guard — which at least fails loudly; the
   * worse shape would have been returning undefined and letting a poll that
   * can never stop test green. It walks parents, exactly as the real one does,
   * and a node contains itself. */
  node.contains = function (other) {
    for (let n = other; n; n = n.parent) {
      if (n === node) return true;
    }
    return false;
  };
  /* S169 — `parentNode` / `nextSibling` / `insertBefore`, the three the image
   * paster (board.js `attachImagePaster`, S91) uses to put its "[Image #N]"
   * chip strip immediately after the textarea it is attached to. Without them
   * the guard `if (textarea.parentNode)` is simply FALSE here and the chips are
   * never inserted — so a harness missing them would report a paste working
   * while the captain sees no chip at all. */
  Object.defineProperty(node, "parentNode", { get() { return node.parent; } });
  Object.defineProperty(node, "nextSibling", {
    get() {
      if (!node.parent) return null;
      const i = node.parent._kids.indexOf(node);
      return i >= 0 ? (node.parent._kids[i + 1] || null) : null;
    },
  });
  node.insertBefore = function (c, ref) {
    if (!c) return c;
    c.parent = node;
    const i = ref ? node._kids.indexOf(ref) : -1;
    if (i < 0) node._kids.push(c); else node._kids.splice(i, 0, c);
    return c;
  };
  Object.defineProperty(node, "childNodes", { get() { return node._kids; } });
  Object.defineProperty(node, "children", {
    get() { return node._kids.filter(isElement); },
  });
  node.setAttribute = function (k, v) {
    node.attrs[k] = String(v);
    if (k === "id") REGISTRY[String(v)] = node;
    if (k === "src") node.src = String(v);
  };
  node.getAttribute = function (k) {
    return Object.prototype.hasOwnProperty.call(node.attrs, k)
      ? node.attrs[k] : null;
  };
  node.removeAttribute = function (k) { delete node.attrs[k]; };
  node.addEventListener = function (ev, fn) {
    (node.listeners[ev] = node.listeners[ev] || []).push(fn);
  };
  node.removeEventListener = function () {};
  node.focus = function () { FOCUSED.push(node); };
  /* RECORDED, never simulated. There is no layout in this process, so the ONE
   * honest thing to assert about "bring it into view" is that board.js asked
   * the browser to do it, on which node, and with what options. Whether the
   * pixels moved is `tests/drives/browser/` and only that. */
  node.scrollIntoView = function (opts) {
    SCROLLS.push({ node: node, opts: opts || null });
  };
  node.click = function () {
    const ev = {
      stopPropagation() {}, preventDefault() {}, target: node,
      key: "", shiftKey: false, ctrlKey: false, metaKey: false, altKey: false,
    };
    (node.listeners.click || []).forEach((fn) => fn(ev));
  };
  /* Fire a NON-click listener (keydown, dblclick, pointerdown). The stub has
   * no event model, so this is the honest minimum: it calls what board.js
   * registered, with the fields board.js reads. It proves a handler runs and
   * what it computes — it can NEVER prove a browser delivers the event. */
  node.fire = function (ev, init) {
    const e = Object.assign({
      stopPropagation() {}, preventDefault() {}, target: node,
      key: "", clientX: 0, shiftKey: false, ctrlKey: false, metaKey: false,
      altKey: false, setPointerCapture() {}, releasePointerCapture() {},
      pointerId: 1,
    }, init || {});
    (node.listeners[ev] || []).forEach((fn) => fn(e));
    return e;
  };
  node.querySelector = function (sel) { return qs(node, sel); };
  node.querySelectorAll = function (sel) { return qsa(node, sel); };
  Object.defineProperty(node, "lastChild", {
    get() { return node._kids[node._kids.length - 1] || null; },
  });
  Object.defineProperty(node, "firstChild", {
    get() { return node._kids[0] || null; },
  });
  Object.defineProperty(node, "className", {
    get() { return node._cls; },
    set(v) { node._cls = String(v == null ? "" : v); },
  });
  Object.defineProperty(node, "textContent", {
    get() { return textOf(node); },
    set(v) { node._text = String(v == null ? "" : v); node._kids = []; },
  });
  Object.defineProperty(node, "innerHTML", {
    get() { return node._html; },
    set(v) {
      // COUNTED, not just recorded. A reply is MODEL-AUTHORED text going into
      // the board's own DOM: the fix that made it legible must not have made it
      // an injection hole, and "was innerHTML ever set on a reply body" is the
      // only assertion that can prove that (setting "" to clear a host is the
      // board's own idiom and is not a write of model text).
      if (v !== "") node._htmlSets = (node._htmlSets || 0) + 1;
      node._html = String(v);
      if (v === "") { node._kids = []; node._text = ""; }
    },
  });
  return node;
}

function textOf(node) {
  let out = node._text || "";
  for (const c of node._kids) out += textOf(c);
  return out;
}

/* selector support: `tag`, `.class`, `#id`, `[attr]`, `[attr=value]`, compound
 * (`.a.b`, `span.x`), and the descendant combinator. Enough for board.js. */
function matchesOne(node, sel) {
  const parts = sel.match(/(^[a-zA-Z][\w-]*)|(\.[\w-]+)|(#[\w-]+)|(\[[^\]]+\])/g);
  if (!parts) return false;
  for (const p of parts) {
    if (p[0] === ".") {
      if (!node.classList.contains(p.slice(1))) return false;
    } else if (p[0] === "#") {
      if (node.attrs.id !== p.slice(1)) return false;
    } else if (p[0] === "[") {
      const inner = p.slice(1, -1);
      const eq = inner.indexOf("=");
      if (eq === -1) {
        if (node.getAttribute(inner) === null) return false;
      } else {
        const k = inner.slice(0, eq);
        const v = inner.slice(eq + 1).replace(/^["']|["']$/g, "");
        if (node.getAttribute(k) !== v) return false;
      }
    } else if (node.tag !== p) return false;
  }
  return true;
}

function walk(root, fn) {
  for (const c of root._kids) { fn(c); walk(c, fn); }
}

function qsa(root, sel) {
  const groups = String(sel).trim().split(/\s+/);
  let current = [root];
  for (const g of groups) {
    const next = [];
    for (const base of current) {
      walk(base, (n) => { if (matchesOne(n, g) && next.indexOf(n) === -1) next.push(n); });
    }
    current = next;
  }
  return current;
}

function qs(root, sel) { const all = qsa(root, sel); return all.length ? all[0] : null; }

const REGISTRY = {};
["mainDeploy", "fileBtn", "conn", "repoMeta", "deployMainBtn", "helpBtn",
 "versionBanner", "readinessBanner", "boardEmpty", "board", "status",
 "viewonly", "overlay", "overlayBody", "holodeckBtn", "deckHost",
 "holoRoBanner"].forEach(function (id) {
  REGISTRY[id] = stubEl("div");
  REGISTRY[id].attrs.id = id;
});
REGISTRY.holodeckBtn.tag = "button";
REGISTRY.holodeckBtn._text = "⬡ Holodeck";
REGISTRY.deckHost.hidden = true;
REGISTRY.holoRoBanner.hidden = true;
REGISTRY.overlay.hidden = true;

const bodyNode = stubEl("body");
const docRoot = stubEl("#document");
docRoot.appendChild(bodyNode);
Object.keys(REGISTRY).forEach((id) => bodyNode.appendChild(REGISTRY[id]));

const FETCHES = [];
const TIMERS = [];
/* A thenable that resolves NOW and FLATTENS a thenable a callback returns —
 * enough of a Promise for postWrite's `fetch().then(r => r.json().then(…))`
 * chain, and synchronous so the act can assert straight after the call. */
function syncThenable(v) {
  return {
    then(f) {
      if (!f) return syncThenable(v);
      const r = f(v);
      return (r && typeof r.then === "function") ? r : syncThenable(r);
    },
    catch() { return this; },
  };
}
function fetchStub(url, opts) {
  FETCHES.push({ url: url, opts: opts || {} });
  // a NEVER-RESOLVING thenable: the call is recorded synchronously (which is
  // all these projections need) and nothing races the assertions.
  const p = { then() { return p; }, catch() { return p; } };
  return p;
}

/* A REAL in-memory Storage. The other board_* harnesses stub `getItem` to null
 * forever, which cannot tell a persisted split from a defaulted one — the whole
 * point of D2's amendment is that the split SURVIVES A RELOAD. Seedable (act
 * `storage`) and projected back out, so a test reads what board.js wrote. */
const STORE = {};
const storageStub = {
  getItem(k) {
    return Object.prototype.hasOwnProperty.call(STORE, k) ? STORE[k] : null;
  },
  setItem(k, v) { STORE[k] = String(v); },
  removeItem(k) { delete STORE[k]; },
};

/* Document-level listeners are RECORDED and callable — a drag registers
 * `pointermove`/`pointerup` on the document, and a test that cannot reach them
 * cannot prove the drag is ever released. */
const DOC_LISTENERS = {};
const documentStub = {
  getElementById(id) { return REGISTRY[id] || null; },
  querySelector(sel) { return qs(docRoot, sel); },
  querySelectorAll(sel) { return qsa(docRoot, sel); },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { const n = stubEl("#text"); n._text = String(t); return n; },
  addEventListener(ev, fn) {
    (DOC_LISTENERS[ev] = DOC_LISTENERS[ev] || []).push(fn);
  },
  removeEventListener(ev, fn) {
    DOC_LISTENERS[ev] = (DOC_LISTENERS[ev] || []).filter((f) => f !== fn);
  },
  body: bodyNode,
  documentElement: docRoot,
  activeElement: null,
};

const sandbox = {
  document: documentStub,
  window: { open() {}, location: { href: "" }, localStorage: storageStub },
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: storageStub,
  setInterval() { return 0; }, clearInterval() {},
  /* S169 fix round 2 — `setTimeout` is RECORDED and runnable. It used to be a
   * no-op returning 0, which cannot tell a wired poll from a dead one: the
   * check band's "running" state schedules a re-ask, and a harness that
   * silently swallowed it would report the band rendering perfectly while the
   * spinner never resolved in a real browser. Nothing fires on its own — an
   * act runs them explicitly (`pollCheck`), so no assertion races a timer. */
  setTimeout(fn, ms) { TIMERS.push({ fn: fn, ms: ms }); return TIMERS.length; },
  clearTimeout() {},
  fetch: fetchStub,
  /* S169 — the composer's image paster reads a pasted file as a data URL
   * (board.js `attachImagePaster`, S91). Firing `onload` INLINE keeps this
   * harness free of async plumbing, and is the same stand-in the File-console
   * harnesses already use (board_hotkeys_harness.js). */
  FileReader: function () {
    const self = this;
    this.result = "";
    this.readAsDataURL = function () {
      self.result = "data:image/png;base64,QUJD";
      if (typeof self.onload === "function") self.onload();
    };
  },
  EventSource: function () { this.addEventListener = function () {}; this.close = function () {}; },
  console, JSON, Math, Date, Promise, encodeURIComponent, decodeURIComponent,
  Array, Object, String, Number, Boolean, RegExp, Set, Map, Error,
};
sandbox.window.document = documentStub;
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

const BOARD_JS = path.join(__dirname, "..", "static", "board.js");
vm.runInContext(fs.readFileSync(BOARD_JS, "utf8"), sandbox, { filename: "board.js" });

/* ── projections ──────────────────────────────────────────────────────────── */
const deck = () => REGISTRY.deckHost;
const txt = (n) => (n ? textOf(n) : "");
/* textOf, minus every subtree carrying `cls` — the harness's stand-in for what
 * a browser's innerText does with a collapsed block. */
function txtExcept(node, cls) {
  if (!node) return "";
  if (node.classList && node.classList.contains(cls)) return "";
  let out = node._text || "";
  for (const c of node._kids) out += txtExcept(c, cls);
  return out;
}
const one = (root, sel) => qs(root, sel);
const many = (root, sel) => qsa(root, sel);

function controlsIn(root) {
  return many(root, "[data-ctl]").map((n) => ({
    label: n.getAttribute("data-ctl"),
    wired: n.getAttribute("data-wired") === "1",
    disabled: !!n.disabled,
    reason: n.getAttribute("data-reason") || "",
  }));
}

function loadPrograms(cfg) {
  sandbox.HOLO.programs = cfg.programs || [];
  sandbox.HOLO.activeId = cfg.activeId || null;
  sandbox.HOLO.busy = !!cfg.busy;
  sandbox.HOLO.filter = cfg.filter || "all";
  if ((cfg.programs || []).length) {
    sandbox.HOLO.sidecarName = cfg.programs[0].sidecarName;
    sandbox.HOLO.commits = cfg.programs[0].commits || 0;
  } else {
    sandbox.HOLO.sidecarName = "groutwork-holodeck";
  }
  // the daemon-supplied header the surface must not invent (D6's full path,
  // and the engine/model the New Program dialog quotes).
  if (cfg.sidecarDisplay !== undefined) {
    sandbox.HOLO.sidecarDisplay = cfg.sidecarDisplay;
  }
  if (cfg.engineName !== undefined) sandbox.HOLO.engineName = cfg.engineName;
  if (cfg.model !== undefined) sandbox.HOLO.model = cfg.model;
  if (cfg.models !== undefined) sandbox.HOLO.models = cfg.models;
  if (cfg.filesChanged && cfg.activeId) {
    const p = (cfg.programs || []).find((x) => x.sessionId === cfg.activeId);
    if (p && p.turns && p.turns.length) {
      p.turns[p.turns.length - 1].filesChanged = cfg.filesChanged;
    }
  }
}

const cfg = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
let out = {};

switch (cfg.act) {
  case "band": {
    sandbox.holoSetMode(false);
    out.boardLabel = REGISTRY.holodeckBtn.textContent.toUpperCase();
    out.boardHiddenOnBoard = bodyNode.classList.contains("on-deck");
    out.deckHiddenOnBoard = !!REGISTRY.deckHost.hidden;
    sandbox.holoSetMode(true);
    out.deckLabel = REGISTRY.holodeckBtn.textContent.toUpperCase();
    out.boardHiddenOnDeck = bodyNode.classList.contains("on-deck");
    out.deckHiddenOnDeck = !!REGISTRY.deckHost.hidden;
    break;
  }
  case "deck": {
    loadPrograms(cfg);
    sandbox.renderDeck();
    const view = one(deck(), ".deckview");
    out.deckviewClass = view ? view.className : "";
    out.paneClasses = view ? view.children.map((c) => clsList(c)[0]) : [];
    out.turnWho = many(deck(), ".turn .who").map((n) => txt(n).toUpperCase());
    out.turnBodies = many(deck(), ".turn .body").map(txt);
    out.fileChips = many(deck(), ".chip-file").map(txt)
      .filter((t) => /\./.test(t));
    out.hasComposer = !!one(deck(), ".composer textarea");
    const send = many(deck(), ".composer [data-ctl]")
      .filter((n) => /send|rendering/i.test(n.getAttribute("data-ctl") || ""));
    out.sendLabel = send.length ? txt(send[0]).toUpperCase() : null;
    out.sendDisabled = send.length ? !!send[0].disabled : null;
    /* S128 (FL-002) — WHOSE WORDS lock the composer. A Send disabled with no
     * explanation is the state a captain who came back mid-turn was left in,
     * and an explanation this side invented would be the readout-honesty class
     * in a new place. `data-reason` is the board's own idiom for it. */
    out.sendReason = send.length
      ? (send[0].getAttribute("data-reason") || "") : null;
    out.sendTitle = send.length ? (send[0].title || "") : null;
    out.workingText = txt(one(deck(), ".holo-working"));
    const frame = one(deck(), "iframe");
    out.iframeSrc = frame ? frame.getAttribute("src") : null;
    out.iframeSandbox = frame ? (frame.getAttribute("sandbox") || "") : "";
    out.previewText = txt(one(deck(), ".pv-none"));
    out.emptyText = txt(one(deck(), ".holo-empty"));
    /* FIX ROUND 2 (defect 6) — the MORNING state is the empty pane with
     * programs waiting in the list, so its copy and its controls are projected
     * apart from the programs pane's. */
    out.emptyControls = controlsIn(one(deck(), ".holo-empty") || stubEl("div"));
    /* FIX ROUND 2 (defect 5) — the chat header's engine pill. It asserted
     * `WARM` unconditionally, two inches under a banner saying the warm
     * conversation is over. */
    const pill = one(deck(), ".chat-head .pill");
    out.headPill = pill ? txt(pill) : "";
    out.headPillReason = pill ? (pill.title || "") : "";
    out.listNames = many(deck(), ".prog .pn").map(txt);
    out.listMeta = many(deck(), ".prog .pm").map(txt);
    /* S126 — one row per program, LIVE or on disk. `onDisk` is the class the
     * row carries, so a test can tell the two kinds apart the way a captain
     * does rather than by re-reading the payload it was handed. */
    out.listRows = many(deck(), ".prog").map((n) => ({
      name: txt(one(n, ".pn")),
      meta: txt(one(n, ".pm")),
      onDisk: n.classList.contains("ondisk"),
      controls: controlsIn(n).map((c) => c.label),
      /* S172 — the chip row's own text and the lineage chip's title, so a
       * test can read what a captain reads off the card rather than
       * re-reading the payload it was handed. */
      prow: txt(one(n, ".prow")),
      dupTitle: one(n, ".pdup") ? (one(n, ".pdup").title || "") : null,
    }));
    const intent = one(deck(), ".pvt-b.intent");
    out.intentTag = intent ? intent.tag : null;
    out.intentHref = intent ? intent.getAttribute("href") : null;
    out.intentReason = intent ? (intent.getAttribute("data-reason") || "") : "";
    /* S127 (FL-007) — INTENT is drawn as half of a segmented control, so what
     * matters is whether it BEHAVES as one: wired to a handler rather than
     * pointing a new browser tab at raw markdown. `intentTarget` is the tell
     * for the old link (`target="_blank"`). */
    out.intentWired = intent ? intent.getAttribute("data-wired") === "1" : null;
    out.intentTarget = intent ? intent.getAttribute("target") : null;
    out.pvToggleOn = many(deck(), ".pv-toggle .pvt-b")
      .map((n) => n.classList.contains("on"));
    out.pvTogglePressed = many(deck(), ".pv-toggle .pvt-b")
      .map((n) => n.getAttribute("aria-pressed"));
    /* S127 (FL-003) — the PREVIEW pane's own controls, apart from the deck's.
     * The defect was that a grounded program's empty preview offered nothing
     * at all; `previewBasisHref` is the one link that cures it, read from the
     * pane the captain is actually looking at. */
    out.previewControls = controlsIn(one(deck(), ".preview") || stubEl("div"));
    const pvBasis = one(deck(), ".pv-none .basis-link");
    out.previewBasisHref = pvBasis ? pvBasis.getAttribute("href") : null;
    out.previewBasisTag = pvBasis ? pvBasis.tag : null;
    out.previewBasisReason = pvBasis
      ? (pvBasis.getAttribute("data-reason") || "") : null;
    out.sidecarChip = txt(one(deck(), ".sidecar-chip"));
    out.controls = controlsIn(deck());
    const chip = one(deck(), ".ground-chip");
    out.groundChipTag = chip ? chip.tag : null;
    out.groundChipHref = chip ? chip.getAttribute("href") : null;
    out.groundChipReason = chip ? (chip.getAttribute("data-reason") || "") : "";
    /* S172 — WHAT THE CHIP SAYS, not just whether it is a link. An inherited
     * basis must not be labelled as this project's own grounding. */
    out.groundChipText = chip ? txt(chip) : null;
    out.groundChipTitle = chip ? (chip.title || "") : "";
    /* FIX ROUND 1 (D7) — the chat header's LINEAGE chip: whose conversation is
     * in the pane. A class of its own, so neither this nor the grounding chip
     * can be read for the other. */
    const cont = one(deck(), ".cont-chip");
    out.contChipText = cont ? txt(cont) : null;
    out.contChipTitle = cont ? (cont.title || "") : "";
    const bodies = many(deck(), ".turn.holo .body");
    const last = bodies.length ? bodies[bodies.length - 1] : null;
    /* THE READABLE REPLY vs THE FOLDED TRACE, kept apart (fix round 2). The
     * cleaner no longer DELETES anything: recognized engine activity is folded
     * into a collapsed `.holo-trace` block that is still in the DOM. So the
     * prose projection must exclude it (a browser's innerText does that for
     * free — the <pre> is `hidden`), and the trace gets its own projection so a
     * test can assert the text SURVIVED rather than that it vanished. */
    out.replyText = last ? txtExcept(last, "holo-trace") : "";
    out.traceBlocks = last ? many(last, ".holo-trace").map((n) => txt(one(n, "pre"))) : [];
    out.traceHidden = last
      ? many(last, ".holo-trace").map((n) => !!one(n, "pre").hidden) : [];
    out.traceSummaries = last
      ? many(last, ".holo-trace").map((n) => txt(one(n, ".ts"))) : [];
    out.replyAllText = last ? txt(last) : "";
    /* S126 (#8) — a fence's INFO STRING. ```html file:mockup.html declares the
     * file the block is, and the render dropped it, so the declared filename
     * never reached the screen at all. */
    out.fenceInfos = last ? many(last, ".fence-info").map(txt) : [];
    out.preTexts = last ? many(last, "pre").map(txt) : [];
    out.replyTags = last ? last.children.map((c) => c.tag) : [];
    let htmlSets = 0;
    if (last) {
      htmlSets += last._htmlSets || 0;
      walk(last, (n) => { htmlSets += n._htmlSets || 0; });
    }
    out.replyInnerHtmlCalls = htmlSets;
    break;
  }
  case "previewRefresh": {
    loadPrograms(cfg);
    sandbox.renderDeck();
    const before = one(deck(), "iframe");
    out.srcBefore = before ? before.getAttribute("src") : null;
    out.applied = sandbox.holoApplyFilesChanged(cfg.filesChanged || []);
    const after = one(deck(), "iframe");
    out.srcAfter = after ? after.getAttribute("src") : null;
    break;
  }
  /* S127 (FL-007) — the ⬡ PREVIEW / ▤ INTENT toggle, driven for real: click
   * INTENT, then (optionally) click back. The whole point of the cure is that
   * the two views swap IN PLACE, so every projection here is read off the DOM
   * the first render built — a re-render would destroy the iframe and hide the
   * defect this act exists to catch. */
  case "intentToggle": {
    loadPrograms(cfg);
    sandbox.renderDeck();
    const framed = one(deck(), "iframe");
    out.iframeSrcAtStart = framed ? framed.getAttribute("src") : null;
    out.nonceAtStart = sandbox.HOLO.nonce;

    const doc = cfg.concept !== undefined ? cfg.concept
      : "## What it must do\n\n1. It remembers what you picked.\n"
        + "2. No flash of the wrong theme.\n";
    const restore = sandbox.fetch;
    // ONLY the jailed preview route answers; everything else keeps the
    // never-resolving stub so nothing races the assertions.
    sandbox.fetch = function (url, opts) {
      FETCHES.push({ url: url, opts: opts || {} });
      if (/\/preview\//.test(String(url)) && !(opts || {}).method) {
        if (cfg.fetchFails) {
          return syncThenable({ status: 404, ok: false,
                                text() { return syncThenable(""); } });
        }
        return syncThenable({ status: 200, ok: true,
                              text() { return syncThenable(doc); } });
      }
      return restore(url, opts);
    };
    const pvState = function () {
      const mock = one(deck(), ".pv-frame") || one(deck(), ".pv-none");
      const panel = one(deck(), ".pv-intent");
      const frame = one(deck(), "iframe");
      const md = panel ? one(panel, ".md") : null;
      return {
        mockClass: mock ? mock.className : null,
        mockHidden: mock ? !!mock.hidden : null,
        intentPresent: !!panel,
        intentHidden: panel ? !!panel.hidden : null,
        intentHtml: md ? md.innerHTML : null,
        intentText: panel ? txt(panel) : "",
        iframeSrc: frame ? frame.getAttribute("src") : null,
        on: many(deck(), ".pv-toggle .pvt-b")
          .map((n) => n.classList.contains("on")),
        pressed: many(deck(), ".pv-toggle .pvt-b")
          .map((n) => n.getAttribute("aria-pressed")),
      };
    };
    try {
      FETCHES.length = 0;
      const intent = one(deck(), ".pvt-b.intent");
      out.intentFound = !!intent;
      out.intentWired = intent
        ? intent.getAttribute("data-wired") === "1" : null;
      if (intent) intent.click();
      out.fetched = FETCHES.map((f) => f.url);
      out.afterIntent = pvState();
      if (cfg.back) {
        FETCHES.length = 0;
        const pv = one(deck(), ".pvt-b.preview");
        out.previewFound = !!pv;
        if (pv) pv.click();
        out.afterBack = pvState();
        out.fetchedOnBack = FETCHES.map((f) => f.url);
        out.nonceAtEnd = sandbox.HOLO.nonce;
        /* AND BACK TO INTENT A SECOND TIME — the bytes are already in hand, so
         * a second network call here would mean the panel re-fetches on every
         * flip. */
        FETCHES.length = 0;
        const again = one(deck(), ".pvt-b.intent");
        if (again) again.click();
        out.fetchedOnSecondIntent = FETCHES.map((f) => f.url);
        out.afterSecondIntent = pvState();
      }
      /* A TURN LANDS WHILE INTENT IS UP. `renderDeck` rebuilds the pane, so
       * this is where a toggle that lives only in the DOM silently reverts. */
      if (cfg.rerender) {
        sandbox.renderDeck();
        out.afterRerender = pvState();
      }
      /* …and a turn that REWROTE concept.md must not leave stale bytes on the
       * panel. Drives the real `holoApplyFilesChanged` path. */
      if (cfg.filesChangedAfter) {
        FETCHES.length = 0;
        sandbox.holoApplyFilesChanged(cfg.filesChangedAfter);
        sandbox.renderDeck();
        out.fetchedAfterChange = FETCHES.map((f) => f.url);
      }
    } finally {
      sandbox.fetch = restore;
    }
    break;
  }
  case "filter": {
    loadPrograms(cfg);
    sandbox.renderDeck();
    out.chipLabels = many(deck(), ".fchip").map((n) => txt(n).toUpperCase());
    const counts = {};
    ["ALL", "DRAFT", "SENT", "DONE"].forEach((name) => {
      const chip = many(deck(), ".fchip")
        .find((n) => (n.getAttribute("data-ctl") || "") === name);
      if (chip) chip.click();
      counts[name] = many(deck(), ".prog").length;
    });
    out.shownForAll = counts.ALL;
    out.shownForDraft = counts.DRAFT;
    out.shownForSent = counts.SENT;
    out.shownForDone = counts.DONE;
    break;
  }
  case "newProgram": {
    sandbox.writesActive = true;
    if (cfg.engineName !== undefined) sandbox.HOLO.engineName = cfg.engineName;
    /* `engineBin` and not `engine`: in these acts `engine` already names the
     * option to CLICK, and the daemon's own binary is a different fact. */
    if (cfg.engineBin !== undefined) sandbox.HOLO.engine = cfg.engineBin;
    if (cfg.model !== undefined) sandbox.HOLO.model = cfg.model;
    if (cfg.models !== undefined) sandbox.HOLO.models = cfg.models;
    const m = sandbox.openNewProgram();
    out.footText = m && m.foot ? txt(m.foot) : "";
    const body = REGISTRY.overlayBody;
    out.text = txt(body);
    const cards = many(body, ".choice-card");
    out.choiceIds = cards.map((c) => c.getAttribute("data-choice"));
    const sel = cards.find((c) => c.classList.contains("sel"));
    out.selected = sel ? sel.getAttribute("data-choice") : null;
    const shot = cards.find((c) => c.getAttribute("data-choice") === "screenshot");
    out.screenshotDisabled = shot ? !!shot.disabled : null;
    out.screenshotReason = shot ? (shot.getAttribute("data-reason") || "") : "";
    out.controls = controlsIn(body);
    /* S127 — the ENGINE PICKER, projected the way the File console's own
     * picker is asserted: the option labels, which one carries `sel`, and the
     * two attributes S140 made load-bearing (role/tabindex for the Tab stop,
     * aria-pressed for what a screen reader is told). */
    const opts = many(body, ".opt");
    out.engineOpts = opts.map(txt);
    out.engineSel = opts.filter((o) => o.classList.contains("sel")).map(txt);
    out.enginePressed = opts.map((o) => o.getAttribute("aria-pressed"));
    out.engineRoles = opts.map((o) => o.getAttribute("role"));
    out.engineTabIndex = opts.map((o) => o.getAttribute("tabindex"));
    break;
  }
  /* S127 (FL-001) — the footer sentence, over a SEQUENCE of selections. The
   * old bug was invisible to any single-shot projection: the line read fine
   * when the dialog opened and never moved again. `foots[0]` is the built
   * sentence and each later entry is the sentence AFTER one click, so a test
   * can assert it CHANGED rather than assert one flattering wording. */
  case "newProgramFoot": {
    sandbox.writesActive = true;
    if (cfg.engineName !== undefined) sandbox.HOLO.engineName = cfg.engineName;
    /* `engineBin` and not `engine`: in these acts `engine` already names the
     * option to CLICK, and the daemon's own binary is a different fact. */
    if (cfg.engineBin !== undefined) sandbox.HOLO.engine = cfg.engineBin;
    if (cfg.model !== undefined) sandbox.HOLO.model = cfg.model;
    if (cfg.models !== undefined) sandbox.HOLO.models = cfg.models;
    const m = sandbox.openNewProgram();
    const body = REGISTRY.overlayBody;
    out.foots = [txt(m.foot)];
    (cfg.clicks || []).forEach((c) => {
      let node = null;
      if (c.engine) {
        node = many(body, ".opt")
          .find((n) => txt(n).toLowerCase().indexOf(c.engine) !== -1);
      } else if (c.mode) {
        node = many(body, ".choice-card")
          .find((n) => n.getAttribute("data-choice") === c.mode);
      }
      if (node) node.click();
      out.foots.push(txt(m.foot));
    });
    /* how many hint spans the footer holds. The S125/S126 failure mode this
     * guards is "cure it by adding a SECOND string beside the first": two
     * sentences, both shown, only one of them true. */
    out.footHints = many(m.foot, ".hint").length;
    break;
  }
  case "newProgramSubmit": {
    sandbox.writesActive = true;
    FETCHES.length = 0;
    if (cfg.engineName !== undefined) sandbox.HOLO.engineName = cfg.engineName;
    if (cfg.engineBin !== undefined) sandbox.HOLO.engine = cfg.engineBin;
    if (cfg.models !== undefined) sandbox.HOLO.models = cfg.models;
    sandbox.openNewProgram();
    const body = REGISTRY.overlayBody;
    const card = many(body, ".choice-card")
      .find((c) => c.getAttribute("data-choice") === cfg.pick);
    if (card) card.click();
    if (cfg.engine) {
      const opt = many(body, ".opt")
        .find((n) => txt(n).toLowerCase().indexOf(cfg.engine) !== -1);
      if (opt) {
        /* KEYBOARD, not mouse, when the test asks for it — S140's guarantee is
         * that this picker is operable without one, and only the keydown path
         * proves it. */
        if (cfg.viaKey) {
          (opt.listeners.keydown || []).forEach((fn) => fn({
            key: cfg.viaKey, preventDefault() {}, stopPropagation() {},
          }));
        } else {
          opt.click();
        }
      }
    }
    const name = one(body, "[data-holo=program-name]");
    if (name) name.value = cfg.program || "Nav rail";
    const run = many(REGISTRY.overlay, "[data-ctl]")
      .concat(many(docRoot, "[data-ctl]"))
      .find((n) => /run program/i.test(n.getAttribute("data-ctl") || ""));
    if (run) run.click();
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.path = post ? post.url : null;
    out.body = post ? JSON.parse(post.opts.body) : null;
    /* S128 (FL-004) — THE DIALOG'S OWN THINKING STATE. The fetch stub never
     * resolves, so this is the dialog exactly as a captain sees it while the
     * grounding pass runs: the button busy, and — the captain's own words —
     * a thinking indicator beside it. */
    const dbusy = one(REGISTRY.overlayBody, ".holo-working");
    out.dialogWorking = dbusy ? txt(dbusy) : null;
    out.dialogWorkingHidden = dbusy ? !!dbusy.hidden : null;
    out.dialogWorkingBars = dbusy ? many(dbusy, ".bars i").length : 0;
    out.dialogWorkingRole = dbusy ? dbusy.getAttribute("role") : null;
    const runBtn = many(REGISTRY.overlay, "[data-ctl]")
      .concat(many(docRoot, "[data-ctl]"))
      .find((n) => /run program|opening the deck/i.test(
        n.getAttribute("data-ctl") || ""));
    out.runDisabled = runBtn ? !!runBtn.disabled : null;
    out.runLabel = runBtn ? txt(runBtn) : null;
    break;
  }
  /* ── S128 (FL-004) — A START THAT FAILS MUST OUTLIVE THE DIALOG ─────────
   * `postWrite`'s failure callback wrote into the dialog's own error line and
   * nowhere else, so closing the dialog — which a first grounding pass is
   * exactly the moment for — made a failed pass fail SILENTLY. This act drives
   * the real submit against a daemon that refuses, then CLOSES the dialog and
   * re-renders the deck: what is asserted afterwards is what survives. */
  case "newProgramFail": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    const errMsg = cfg.error
      || "the copilot worker stopped before it wrote basis.md";
    const restore = sandbox.fetch;
    sandbox.fetch = function (url, opts) {
      FETCHES.push({ url: url, opts: opts || {} });
      if (/\/holodeck\/start$/.test(String(url))
          && (opts || {}).method === "POST") {
        return syncThenable({
          status: cfg.status || 502,
          json: function () {
            return syncThenable({ ok: false, error: errMsg });
          },
        });
      }
      return restore(url, opts);
    };
    try {
      sandbox.openNewProgram();
      const body = REGISTRY.overlayBody;
      const name = one(body, "[data-holo=program-name]");
      if (name) name.value = cfg.program || "Nav rail";
      const run = many(REGISTRY.overlay, "[data-ctl]")
        .concat(many(docRoot, "[data-ctl]"))
        .find((n) => /run program/i.test(n.getAttribute("data-ctl") || ""));
      out.ran = !!run;
      if (run) run.click();
      // the dialog's own half, still true while it is open.
      out.dialogErr = txt(one(body, ".errline"));
      const dbusy = one(body, ".holo-working");
      out.dialogWorkingHidden = dbusy ? !!dbusy.hidden : null;
      const runAgain = many(REGISTRY.overlay, "[data-ctl]")
        .concat(many(docRoot, "[data-ctl]"))
        .find((n) => /run program/i.test(n.getAttribute("data-ctl") || ""));
      out.runReEnabled = runAgain ? !runAgain.disabled : null;
    } finally {
      sandbox.fetch = restore;
    }
    // AND NOW THE DIALOG GOES AWAY, which is the whole test.
    out.bannerKind = (sandbox.HOLO.banner || {}).kind || null;
    sandbox.closeOverlay();
    sandbox.renderDeck();
    const b = one(deck(), ".holo-banner");
    out.bannerPresent = !!b;
    out.bannerClass = b ? b.className : null;
    out.bannerLabel = b ? txt(one(b, ".bl")) : null;
    out.bannerText = b ? txt(one(b, ".bt")) : null;
    break;
  }
  /* ── S128 (FL-002) — the ⬡ HOLODECK band control's activity indicator ────
   * Driven through the REAL `render(board)`, because the fact arrives on the
   * board payload's meta and nowhere else — a client-side timer here would be
   * the same lie in a new place. `metas` is a SEQUENCE, so a test can assert
   * the indicator CLEARS as well as appears (an assertion on one flattering
   * frame would pass against an indicator that never goes out).
   *
   * WHAT THIS CANNOT SEE: there is no CSS here. The dot's colour, its pulse and
   * whether it is visible at all are Chrome's to measure. */
  case "bandActivity": {
    sandbox.writesActive = cfg.writes === false ? false : true;
    sandbox.holoSetMode(!!cfg.onDeck);
    out.states = (cfg.metas || [null]).map((h) => {
      const board = {
        meta: Object.assign({ repo: "acme/groutwork", adapter: "local" },
                            h ? { holodeck: h } : {}),
        missions: [],
        columns: {
          align: [], research: [], validate: [], plan: [], "plan-review": [],
          schedule: [], implement: [], verify: [], done: [],
        },
      };
      sandbox.render(board);
      const b = REGISTRY.holodeckBtn;
      return {
        label: b.textContent,
        className: b.className,
        working: b.classList.contains("working"),
        dots: many(b, ".holo-dot").length,
        title: b.title || "",
        ariaLabel: b.getAttribute("aria-label"),
        disabled: !!b.disabled,
      };
    });
    break;
  }
  case "state": {
    loadPrograms(cfg);
    const opts = { message: cfg.message || "", paths: cfg.paths || [] };
    if (cfg.kind === "offline") opts.retry = { sid: "s1", text: "again" };
    sandbox.holoSetBanner(cfg.kind, opts);
    sandbox.renderDeck();
    const b = one(deck(), ".holo-banner");
    out.bannerClass = b ? b.className : null;
    out.label = b ? txt(one(b, ".bl")).toUpperCase() : null;
    out.text = b ? txt(one(b, ".bt")) : null;
    const act = b ? many(b, "[data-ctl]")[0] : null;
    out.actionLabel = act ? txt(act).toUpperCase() : null;
    out.actionWired = act ? act.getAttribute("data-wired") === "1" : false;
    break;
  }
  /* FIX ROUND 3 — the banner a REAL `/say` reply produces. `state` above sets
   * the banner by hand and so can only see the kind→title table; this drives
   * holoSay's own success path with a daemon payload, which is where the two
   * warning kinds were being bucketed into one title. */
  case "sayWarning": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    const state = { status: cfg.status || "wrote-nothing",
                    warning: cfg.warning || null,
                    sessionId: "s1" };
    /* FIX ROUND 2 — a REFUSED reply (the branch that outranks the warning),
     * and the daemon's `warm` fact that the header pill reads. */
    if (cfg.refused) state.refused = cfg.refused;
    if (cfg.warm !== undefined) state.warm = cfg.warm;
    const restore = sandbox.fetch;
    sandbox.fetch = function (url, opts) {
      FETCHES.push({ url: url, opts: opts || {} });
      // ONLY the /say POST answers; everything else (the refresh, the deck
      // reload holoSay fires afterwards) keeps the never-resolving stub, so
      // nothing else runs and races the assertion.
      if (/\/say$/.test(String(url)) && (opts || {}).method === "POST") {
        return syncThenable({
          status: 200,
          json: function () { return syncThenable({ ok: true, state: state }); },
        });
      }
      return restore(url, opts);
    };
    try {
      sandbox.holoSay("s1", cfg.text || "make the rail wider");
    } finally {
      sandbox.fetch = restore;
    }
    sandbox.renderDeck();
    out.bannerKind = (sandbox.HOLO.banner || {}).kind || null;
    const b = one(deck(), ".holo-banner");
    out.bannerClass = b ? b.className : null;
    out.label = b ? txt(one(b, ".bl")).toUpperCase() : null;
    out.text = b ? txt(one(b, ".bt")) : null;
    const wpill = one(deck(), ".chat-head .pill");
    out.headPill = wpill ? txt(wpill) : "";
    break;
  }
  /* N6 — RETRY TURN must not make the captain say it twice. Drives the REAL
   * sequence: say → the turn fails (busy cleared, offline banner with a retry)
   * → the banner's control clicked. */
  case "retry": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    FETCHES.length = 0;                      // drop board.js's own boot calls
    const said = cfg.text || "make the rail wider";
    sandbox.holoSay("s1", said);
    sandbox.HOLO.busy = false;               // what the error path does
    sandbox.holoSetBanner("offline", {
      message: "the claude worker stopped mid-turn",
      retry: { sid: "s1", text: said },
    });
    sandbox.renderDeck();
    const retry = many(deck(), ".holo-banner [data-ctl]")[0];
    out.retryLabel = retry ? txt(retry).toUpperCase() : null;
    if (retry) retry.click();
    const prog = (sandbox.HOLO.programs || [])[0] || {};
    out.turnTexts = (prog.turns || []).map((t) => t.text);
    out.saidCount = out.turnTexts.filter((t) => t === said).length;
    out.posts = FETCHES.filter((f) => (f.opts.method || "") === "POST").length;
    break;
  }
  /* S126 — clicking a room the daemon is NOT holding asks it to reopen. */
  case "openDisk": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    FETCHES.length = 0;
    const row = many(deck(), ".prog")
      .find((n) => n.classList.contains("ondisk"));
    if (row) row.click();
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.path = post ? post.url : null;
    out.body = post ? JSON.parse(post.opts.body) : null;
    break;
  }
  /* S126 — delete CONFIRMS, then posts. `stopAtConfirm` leaves the dialog
   * open so a test can prove nothing is deleted by merely asking. */
  case "deleteProgram": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    FETCHES.length = 0;
    const rows = many(deck(), ".prog");
    const row = rows.find((n) => {
      const ctl = many(n, "[data-ctl]")
        .find((c) => /delete/i.test(c.getAttribute("data-ctl") || ""));
      return !!ctl && (!cfg.room || txt(one(n, ".pm")).indexOf(cfg.room) !== -1
                       || rows.length === 1 || n.classList.contains("ondisk"));
    }) || rows[0];
    const del = row && many(row, "[data-ctl]")
      .find((c) => /delete/i.test(c.getAttribute("data-ctl") || ""));
    if (del) del.click();
    out.confirmText = txt(REGISTRY.overlayBody);
    if (!cfg.stopAtConfirm) {
      const go = many(REGISTRY.overlay, "[data-ctl]")
        .concat(many(docRoot, "[data-ctl]"))
        .filter((n) => /delete program/i.test(n.getAttribute("data-ctl") || ""));
      if (go.length) go[go.length - 1].click();
    }
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.path = post ? post.url : null;
    out.body = post ? JSON.parse(post.opts.body) : null;
    break;
  }
  /* S172 — ⧉ DUPLICATE, driven for real: find the control on the card, click
   * it, read the confirmation, optionally type a name, then click the dialog's
   * own button and report the POST it made.
   *
   * FIX ROUND 3 — `from: "lock"` drives THE SAME JOURNEY off the control inside
   * a locked program's CHAT PANE instead of off its card. One act, deliberately:
   * the two controls must be one mechanism, and the way to prove that is to
   * assert the same dialog and the same POST come out of both. A second act
   * would let a second road pass. */
  case "duplicateProgram": {
    sandbox.writesActive = cfg.writes === false ? false : true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    FETCHES.length = 0;
    const rows = many(deck(), ".prog");
    const row = rows.find(
      (n) => !cfg.room || txt(one(n, ".pm")).indexOf(cfg.room) !== -1)
      || rows[0];
    const lock = one(deck(), ".holo-lock");
    out.lockPresent = !!lock;
    // the control's HOME for this run. `null` when the lock band the test asked
    // for is not on screen at all, so "no control" cannot pass as "no lock".
    const home = cfg.from === "lock" ? lock : row;
    const dup = home && many(home, "[data-ctl]")
      .find((c) => /duplicate/i.test(c.getAttribute("data-ctl") || ""));
    out.hasControl = !!dup;
    out.controlDisabled = dup ? !!dup.disabled : null;
    out.controlWired = dup ? dup.getAttribute("data-wired") === "1" : null;
    out.controlReason = dup ? (dup.getAttribute("data-reason") || "") : null;
    if (dup) dup.click();
    out.confirmText = txt(REGISTRY.overlayBody);
    const field = one(REGISTRY.overlayBody, "[data-holo=duplicate-name]");
    out.hasNameField = !!field;
    // the property, because that is what board.js sets on an <input> (the
    // house idiom `openNewProgram` uses) — not an attribute.
    out.namePlaceholder = field
      ? (field.placeholder || field.getAttribute("placeholder") || "") : null;
    if (field && cfg.name) field.value = cfg.name;
    if (!cfg.stopAtConfirm) {
      const go = many(REGISTRY.overlay, "[data-ctl]")
        .concat(many(docRoot, "[data-ctl]"))
        .filter((n) => /duplicate program/i.test(
          n.getAttribute("data-ctl") || ""));
      if (go.length) go[go.length - 1].click();
    }
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.path = post ? post.url : null;
    out.body = post ? JSON.parse(post.opts.body) : null;
    break;
  }
  /* S126 — the concept-doc audit, rendered against the turn it belongs to. */
  case "conceptAudit": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    const prog = (sandbox.HOLO.programs || [])[0];
    const last = prog && prog.turns && prog.turns[prog.turns.length - 1];
    if (last) last.conceptAudit = cfg.conceptAudit || null;
    sandbox.renderDeck();
    const note = many(deck(), ".holo-concept");
    out.conceptNote = note.length ? txt(note[note.length - 1]) : "";
    break;
  }
  /* S169 (FL-015) — the daemon's account of what a turn DID, rendered against
   * the turn it belongs to. The `conceptAudit` twin, deliberately: same idiom,
   * same per-turn placement, one voice (the daemon's words, verbatim). */
  case "turnOutcome": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    const prog = (sandbox.HOLO.programs || [])[0];
    const last = prog && prog.turns && prog.turns[prog.turns.length - 1];
    if (last) last.turnOutcome = cfg.turnOutcome || null;
    sandbox.renderDeck();
    const notes = many(deck(), ".holo-outcome");
    const note = notes.length ? notes[notes.length - 1] : null;
    out.outcomePresent = !!note;
    out.outcomeText = txt(note);
    out.outcomeClass = note ? note.className : "";
    out.outcomeLabel = note ? txt(one(note, ".cl")) : "";
    out.fileChips = many(deck(), ".chip-file").map(txt);
    break;
  }
  /* S127 — the hand-off bar under the deck, and the lock band that replaces
   * the composer once a program has been sent. */
  case "handoffBar": {
    sandbox.writesActive = cfg.writes === false ? false : true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    const bar = one(deck(), ".holo-handoff");
    out.barPresent = !!bar;
    out.barText = txt(bar);
    out.barControls = bar ? controlsIn(bar) : [];
    /* S171 — THE GATE. `data-gate` is stamped from the DAEMON's published
     * `derive` block and nothing else, so reading it back is reading what the
     * bar was told, not what it decided. The loading indicator is a NODE — a
     * button that merely says "generating" with nothing moving beside it is
     * the state this round was asked to make visible. */
    out.barGate = bar ? bar.getAttribute("data-gate") : null;
    const gsend = bar ? one(bar, "[data-holo=handoff-send]") : null;
    out.sendLabel = gsend ? gsend.getAttribute("data-ctl") : null;
    out.sendDisabled = gsend ? !!gsend.disabled : null;
    out.sendWired = gsend ? gsend.getAttribute("data-wired") === "1" : null;
    out.barSpinner = bar ? !!one(bar, ".holo-bars .bars i") : false;
    out.skipPresent = bar ? !!one(bar, "[data-holo=handoff-skip]") : false;
    out.retryPresent = bar ? !!one(bar, "[data-holo=handoff-retry]") : false;
    out.hasComposer = !!one(deck(), ".composer textarea");
    const lock = one(deck(), ".holo-lock");
    out.lockPresent = !!lock;
    out.lockText = txt(lock);
    out.lockControls = lock ? controlsIn(lock) : [];
    out.statusChips = many(deck(), ".pstat").map(txt);
    out.missionChips = many(deck(), ".pmission").map(txt);
    break;
  }
  /* ── S169 (FL-013 + FL-014): THE COMPOSER'S UNSENT STATE ──────────────────
   * ONE act for both, because they are one object's state: what he typed and
   * what he pasted are the same unsent turn, and the defect in each was the
   * same one — the value lived only in a node `renderDeck` throws away.
   *
   * `cfg.after` is a list of INTERACTIONS driven through the real functions,
   * and each one records what the captain would find: the textarea's value,
   * whether the node itself was replaced (so "it survived" cannot pass by the
   * pane simply never being rebuilt), and the "[Image #N]" chips on screen.
   * That list IS the trigger inventory this defect needed — the report said a
   * board round-trip, and the mechanism said any repaint at all.
   *
   * WHAT THIS CANNOT SEE, as ever: it calls the render functions itself, so it
   * says nothing about whether the browser's own 4s poll rebuilds the pane.
   * `tests/drives/browser/holodeck.sh` measures that against a real timer.
   */
  case "composer": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    const composer = () => one(deck(), "[data-holo=composer]");
    const chipTexts = () => many(deck(), ".composer .img-chip-name").map(txt);
    let node = composer();
    out.found = !!node;
    const snap = (label) => {
      const now = composer();
      const step = {
        step: label,
        value: now ? now.value : null,
        // the node IDENTITY. A "draft survived" that is really "nothing was
        // rebuilt" proves nothing about the defect.
        rebuilt: now !== node,
        chips: chipTexts(),
        images: (sandbox.HOLO.drafts[cfg.activeId] || {}).images || [],
      };
      node = now;
      out.steps.push(step);
      return step;
    };
    out.steps = [];
    if (node && cfg.type !== undefined) {
      node.value = cfg.type;
      node.fire("input", {});
    }
    if (node && cfg.paste) {
      const file = { type: cfg.pasteType || "image/png",
                     size: cfg.pasteSize || 64,
                     name: cfg.pasteName || "reference.png" };
      node.fire("paste", { clipboardData: {
        items: [{ kind: "file", getAsFile() { return file; } }] } });
    }
    snap("typed");
    (cfg.after || []).forEach((what) => {
      switch (what) {
        case "render":
          sandbox.renderDeck();
          break;
        case "drawer":
          // a class flip on the live DOM by design (Q3) — measured, not assumed
          sandbox.holoDrawerSet(!sandbox.HOLO.drawer);
          break;
        case "banner":
          sandbox.holoSetBanner("notice", { message: "a banner arrived" });
          sandbox.renderDeck();
          break;
        case "switch":
          // …to another program and back, which is the trigger the captain
          // actually described.
          sandbox.HOLO.activeId = cfg.otherId;
          sandbox.renderDeck();
          sandbox.HOLO.activeId = cfg.activeId;
          sandbox.renderDeck();
          break;
        case "deckRoundTrip":
          // ⬡ HOLODECK → ▦ BOARD → ⬡ HOLODECK, his exact words.
          sandbox.holoSetMode(false);
          sandbox.holoSetMode(true);
          break;
        /* S169 (FL-015) — the captain DECLARING the turn's shape on the
         * composer, through the real control he would click. */
        case "ask":
        case "build": {
          const opt = many(deck(), ".composer .holo-intent .iopt")
            .find((n) => n.getAttribute("data-holo-intent") === what);
          out.declared = !!opt;
          if (opt) opt.click();
          break;
        }
        case "send": {
          FETCHES.length = 0;
          const s = many(deck(), ".composer [data-ctl]")
            .find((b) => /send/i.test(b.getAttribute("data-ctl") || ""));
          if (s) s.click();
          const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
          out.sendPath = post ? post.url : null;
          out.sendBody = post ? JSON.parse(post.opts.body) : null;
          break;
        }
        case "enter": {
          FETCHES.length = 0;
          const ta = composer();
          if (ta) ta.fire("keydown", { key: "Enter" });
          const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
          out.sendPath = post ? post.url : null;
          out.sendBody = post ? JSON.parse(post.opts.body) : null;
          break;
        }
        default:
          out.unknownStep = what;
      }
      snap(what);
    });
    out.drafts = JSON.parse(JSON.stringify(sandbox.HOLO.drafts));
    /* S169 (FL-015) — THE AFFORDANCE ITSELF: both halves, which one is
     * pressed, and the verb on the Send control (the only feedback that says
     * the declaration took). Read off the painted composer, not off HOLO. */
    out.intentOpts = many(deck(), ".composer .holo-intent .iopt").map((n) => ({
      intent: n.getAttribute("data-holo-intent"),
      text: txt(n),
      pressed: n.getAttribute("aria-pressed"),
      on: n.classList.contains("on"),
      title: n.title || "",
    }));
    const sendCtl = many(deck(), ".composer [data-ctl]")
      .find((b) => /send/i.test(b.getAttribute("data-ctl") || ""));
    out.sendLabel = sendCtl ? txt(sendCtl) : null;
    out.errText = txt(one(deck(), ".composer .errline"));
    out.errHidden = one(deck(), ".composer .errline")
      ? !!one(deck(), ".composer .errline").hidden : null;
    break;
  }
  /* The INTENT panel's containers (FL-016). The scrim and the scrolling must
   * be on DIFFERENT boxes — see board.css. This half only reports the shape;
   * whether the darkening actually reaches the bottom of a long document is a
   * PIXEL question and lives in tests/drives/browser/holodeck.sh. */
  case "intentBoxes": {
    loadPrograms(cfg);
    sandbox.renderDeck();
    const restore = sandbox.fetch;
    const doc = cfg.concept || "## What it must do\n\n1. It remembers.\n";
    sandbox.fetch = function (url, opts) {
      FETCHES.push({ url: url, opts: opts || {} });
      if (/\/preview\//.test(String(url)) && !(opts || {}).method) {
        return syncThenable({ status: 200, ok: true,
                              text() { return syncThenable(doc); } });
      }
      return restore(url, opts);
    };
    try {
      const intent = one(deck(), ".pvt-b.intent");
      if (intent) intent.click();
      const panel = one(deck(), ".pv-intent");
      out.panelPresent = !!panel;
      out.panelChildren = panel
        ? panel.children.map((n) => n.className) : null;
      const scroll = panel ? one(panel, ".pv-intent-scroll") : null;
      out.scrollPresent = !!scroll;
      out.scrollChildren = scroll
        ? scroll.children.map((n) => n.className) : null;
      out.docInsideScroll = !!(scroll && one(scroll, ".intent-doc"));
      const md = scroll ? one(scroll, ".md") : null;
      out.mdInsideScroll = !!md;
      // `setMd` writes innerHTML, so the rendered document is only readable
      // there — textOf() sees none of it (same as the `intentToggle` act).
      out.mdHtml = md ? md.innerHTML : null;
    } finally {
      sandbox.fetch = restore;
    }
    break;
  }
  /* Clicking ▶ SEND TO ALIGN must ask the DAEMON for the hand-off — by session
   * id, and with no path anywhere in the request. */
  case "sendClick": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    FETCHES.length = 0;
    const ctl = many(deck(), ".holo-handoff [data-ctl]")
      .find((n) => /send to align/i.test(n.getAttribute("data-ctl") || ""));
    out.found = !!ctl;
    if (ctl) ctl.click();
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.path = post ? post.url : null;
    out.body = post ? JSON.parse(post.opts.body) : null;
    break;
  }
  /* S171 — THE GATE'S CLICKS, on the wire. `which` names the control by its
   * data-holo: `handoff-send`, `handoff-skip`, `handoff-retry`. Whatever the
   * bar is showing, exactly one POST may leave the page and this says which. */
  case "gateClick": {
    sandbox.writesActive = true;
    loadPrograms(cfg);
    sandbox.renderDeck();
    FETCHES.length = 0;
    const bar = one(deck(), ".holo-handoff");
    const ctl = bar ? one(bar, `[data-holo=${cfg.which || "handoff-send"}]`)
                    : null;
    out.found = !!ctl;
    out.disabled = ctl ? !!ctl.disabled : null;
    if (ctl) ctl.click();
    const posts = FETCHES.filter((f) => (f.opts.method || "") === "POST");
    out.postCount = posts.length;
    out.path = posts.length ? posts[0].url : null;
    out.body = posts.length ? JSON.parse(posts[0].opts.body) : null;
    break;
  }
  /* The hand-off dialog itself, rendered from a daemon payload — then FILED,
   * so the POST body is what is really asserted. */
  case "handoffDialog": {
    sandbox.writesActive = true;
    FETCHES.length = 0;
    TIMERS.length = 0;
    sandbox.openHandoff(cfg.seed || {});
    const body = REGISTRY.overlayBody;
    out.text = txt(body);
    out.controls = controlsIn(body).concat(controlsIn(REGISTRY.overlay));
    out.choiceIds = many(body, ".choice-card")
      .map((c) => c.getAttribute("data-choice"));
    const sel = many(body, ".choice-card")
      .find((c) => c.classList.contains("sel"));
    out.selected = sel ? sel.getAttribute("data-choice") : null;
    out.guidance = txt(one(body, ".handoff-guidance"));
    out.rides = many(body, ".ride .nm").map(txt);
    const brief = one(body, "[data-holo=handoff-brief]");
    out.briefValue = brief ? brief.value : null;
    /* S169 fix round 2 — THE CHECK BAND and the hint above it. Both live in
     * the brief field, and WHERE they are inside it is half the claim: the box
     * is as tall as the draft, so a finding rendered under it is 800px down.
     * `briefFieldOrder` is the elements of that field in DOM order, which is
     * the only thing this process can say about position (no CSS, no layout —
     * `tests/drives/browser/handoff.sh` is where "on screen" is measured). */
    const bfield = one(body, "[data-holo=handoff-brief-field]");
    out.briefHint = bfield
      ? (bfield.children.filter((n) => clsList(n).indexOf("hint") >= 0)
          .map(txt)[0] || "") : "";
    out.briefFieldOrder = bfield
      ? bfield.children.map((n) => n.getAttribute("data-holo")
          || clsList(n).join(".") || n.tag) : [];
    const readBand = () => {
      const n = one(body, "[data-holo=handoff-derive]");
      return n ? {
        text: txt(n), hidden: !!n.hidden, cls: clsList(n),
        state: n.getAttribute("data-state") || "",
        changes: many(n, "[data-holo=handoff-derive-change]").map(txt),
      } : null;
    };
    out.check = readBand();
    const projectCheck = () => { out.check = readBand(); };
    /* The derivation band's POLL. `openHandoff` schedules a re-ask only while
     * the daemon says "running"; running the recorded timer is the only way to
     * tell that from a band that renders a spinner and never asks again. */
    out.checkTimers = TIMERS.length;
    if (cfg.pollCheck) {
      FETCHES.length = 0;
      const pending = TIMERS.splice(0, TIMERS.length);
      out.pollErrors = [];
      pending.forEach((t) => {
        try { t.fn(); } catch (e) { out.pollErrors.push(String(e)); }
      });
      out.checkPolls = FETCHES.filter((f) => (f.opts.method || "") === "POST")
        .map((f) => ({ url: f.url, body: JSON.parse(f.opts.body) }));
      out.checkTimersAfter = TIMERS.length;
      projectCheck();
    }
    /* S128 — the intent hand-over. `reqRows` is the captured-requirement
     * checklist beside the brief, `missing*` the band that fires when one of
     * his own sentences is not in it, and `questions` the answer boxes. The
     * live re-check is driven through the REAL `input` listener board.js
     * registered, never by calling a projection function. */
    const project128 = () => {
      out.reqRows = many(body, "[data-holo=handoff-req]").map((n) => ({
        text: txt(n), ok: n.getAttribute("data-ok") === "1",
      }));
      const band = one(body, "[data-holo=handoff-missing]");
      out.missingText = band && !band.hidden ? txt(band) : "";
      out.missingHidden = band ? !!band.hidden : true;
    };
    project128();
    const qfield = one(body, "[data-holo=handoff-questions]");
    out.questionsText = txt(qfield);
    out.questions = many(body, "[data-holo=handoff-question]").map((n) => ({
      qid: n.getAttribute("data-qid"), value: n.value,
    }));
    // WHICH field is last before the footer — the questions are meant to be
    // the thing he reads with his hand on the button, and "it exists" is not
    // that claim.
    const fields = many(body, ".field");
    const lastField = fields[fields.length - 1];
    out.lastFieldHolo = lastField ? lastField.getAttribute("data-holo") : null;
    if (cfg.pickScope) {
      const card = many(body, ".choice-card")
        .find((c) => c.getAttribute("data-choice") === cfg.pickScope);
      if (card) card.click();
      const now = many(body, ".choice-card")
        .find((c) => c.classList.contains("sel"));
      out.selectedAfter = now ? now.getAttribute("data-choice") : null;
      // the scope click re-asks the daemon for the guidance — recorded here so
      // a test can prove the block is never rewritten on this side.
      const gp = FETCHES.find((f) => (f.opts.method || "") === "POST");
      out.guidanceRefetch = gp ? {
        path: gp.url, body: JSON.parse(gp.opts.body),
      } : null;
    }
    if (cfg.rewrite !== undefined && brief) {
      brief.value = cfg.rewrite;
      brief.fire("input", {});
      project128();
    }
    if (cfg.then !== undefined && brief) {
      brief.value = cfg.then;
      brief.fire("input", {});
      project128();
    }
    /* ── S128 fix round 1, D1: the STICKY FOOTER. The questions live at the
     * bottom of an 1800px scroll and the File button is laid out from first
     * paint, so "they are in the DOM" was never the claim that mattered. What
     * is asserted here is what rides in the footer BESIDE that button —
     * present at every scroll position, at every viewport, in every browser. */
    const foot = one(body, ".modal-foot");
    const projectFoot = () => {
      const cue = foot ? one(foot, "[data-holo=handoff-qcue]") : null;
      out.footText = txt(foot);
      out.qcue = cue ? {
        text: txt(cue),
        inFoot: !!cue.parent && cue.parent.classList.contains("modal-foot"),
        wired: cue.getAttribute("data-wired") === "1",
        open: cue.getAttribute("data-open"),
        cls: clsList(cue),
      } : null;
    };
    projectFoot();
    const errNode = one(body, ".errline");
    out.errParentCls = errNode && errNode.parent
      ? clsList(errNode.parent).join(" ") : null;
    Object.keys(cfg.answers || {}).forEach((qid) => {
      const box = many(body, "[data-holo=handoff-question]")
        .find((n) => n.getAttribute("data-qid") === qid);
      if (box) { box.value = cfg.answers[qid]; box.fire("input", {}); }
    });
    projectFoot();
    if (cfg.clickCue) {
      SCROLLS.length = 0; FOCUSED.length = 0;
      const cue = foot ? one(foot, "[data-holo=handoff-qcue]") : null;
      out.cueFound = !!cue;
      if (cue) cue.click();
      out.cueScrolled = SCROLLS.map((s) => ({
        holo: s.node.getAttribute("data-holo"),
        cls: clsList(s.node), opts: s.opts,
      }));
      out.cueFocused = FOCUSED.map((n) => ({
        holo: n.getAttribute("data-holo"), qid: n.getAttribute("data-qid"),
      }));
    }
    SCROLLS.length = 0;
    FETCHES.length = 0;
    const file = many(REGISTRY.overlay, "[data-ctl]")
      .concat(many(docRoot, "[data-ctl]"))
      .find((n) => /file mission/i.test(n.getAttribute("data-ctl") || ""));
    out.fileFound = !!file;
    if (file && !cfg.stopBeforeFile) file.click();
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.filePath = post ? post.url : null;
    out.fileBody = post ? JSON.parse(post.opts.body) : null;
    // A refusal is the one error path this process can DRIVE (the fetch stub
    // never resolves, so a 502 cannot be replayed here). What it proves is
    // that showErr asks for the line to be brought into view at all.
    out.errScrolled = SCROLLS.some((s) => clsList(s.node).indexOf("errline") >= 0);
    out.errShown = errNode ? !errNode.hidden : null;
    break;
  }
  /* ── S128 — D2's AMENDED chat ⇄ preview split ──────────────────────────
   * WHAT THIS CANNOT SEE, said here rather than discovered later: there is no
   * CSS and no layout in this process. It reads the two custom properties
   * board.js WRITES and the numbers it computes. It cannot tell you a pane got
   * wider, that the handle is visible, or that a real pointer drags anything —
   * only headless Chrome can, and only by measuring the panes. */
  case "split": {
    Object.keys(STORE).forEach((k) => delete STORE[k]);
    Object.keys(cfg.storage || {}).forEach((k) => { STORE[k] = String(cfg.storage[k]); });
    loadPrograms(cfg);
    sandbox.renderDeck();
    const view = one(deck(), ".deckview");
    const handle = one(deck(), ".deck-split");
    const project = () => ({
      chatFr: view ? view.style.getPropertyValue("--holo-chat-fr") : "",
      pvFr: view ? view.style.getPropertyValue("--holo-pv-fr") : "",
      valueNow: handle ? handle.getAttribute("aria-valuenow") : null,
      stored: STORE["lcars-holo-split"] === undefined
        ? null : STORE["lcars-holo-split"],
    });
    out.present = !!handle;
    out.paneOrder = view ? view.children.map((c) => clsList(c)[0]) : [];
    out.role = handle ? handle.getAttribute("role") : null;
    out.orientation = handle ? handle.getAttribute("aria-orientation") : null;
    out.tabindex = handle ? handle.getAttribute("tabindex") : null;
    out.label = handle ? handle.getAttribute("aria-label") : null;
    out.valueMin = handle ? handle.getAttribute("aria-valuemin") : null;
    out.valueMax = handle ? handle.getAttribute("aria-valuemax") : null;
    out.title = handle ? (handle.title || "") : "";
    out.controls = controlsIn(view || stubEl("div"));
    out.initial = project();
    // the keyboard leg: every key the handle claims, driven through the REAL
    // listener board.js registered.
    out.keys = {};
    (cfg.keys || []).forEach((k) => {
      if (handle) handle.fire("keydown", { key: k });
      out.keys[k] = project();
    });
    if (cfg.dblclick && handle) { handle.fire("dblclick", {}); }
    if (cfg.dblclick) out.afterDblclick = project();
    /* The drag ARITHMETIC, through the pure function the pointermove handler
     * itself calls. It proves the clamp and the fraction; it proves nothing
     * about pixels moving. */
    if (cfg.drags) {
      out.drags = cfg.drags.map((d) => ({
        frac: sandbox.holoSplitFromDrag(d[0], d[1], d[2]),
      }));
    }
    /* THE DRAG LIFECYCLE, through the real pointerdown handler. The stub has no
     * layout, so the two panes are TOLD their widths; everything after that is
     * board.js's own. What this proves is the wiring — that a press registers a
     * move and a release, that the release un-registers them, and that storage
     * is written ONCE at the end rather than on every move. What it cannot
     * prove is that a browser delivers any of these events, or that a pixel
     * moved. */
    if (cfg.drag) {
      const chat = one(deck(), ".holo-chat");
      const pv = one(deck(), ".preview");
      if (chat) chat.offsetWidth = cfg.drag.chatPx;
      if (pv) pv.offsetWidth = cfg.drag.pvPx;
      Object.keys(DOC_LISTENERS).forEach((k) => { DOC_LISTENERS[k] = []; });
      handle.fire("pointerdown", { clientX: 0 });
      out.dragArmed = {
        move: (DOC_LISTENERS.pointermove || []).length,
        up: (DOC_LISTENERS.pointerup || []).length,
        cancel: (DOC_LISTENERS.pointercancel || []).length,
        viewClass: view ? view.className : "",
        stored: STORE["lcars-holo-split"] === undefined
          ? null : STORE["lcars-holo-split"],
      };
      (DOC_LISTENERS.pointermove || []).slice().forEach((fn) => {
        fn({ clientX: cfg.drag.dx, preventDefault() {} });
      });
      out.duringDrag = project();
      (DOC_LISTENERS.pointerup || []).slice().forEach((fn) => {
        fn({ clientX: cfg.drag.dx, preventDefault() {} });
      });
      out.afterDrag = Object.assign(project(), {
        move: (DOC_LISTENERS.pointermove || []).length,
        up: (DOC_LISTENERS.pointerup || []).length,
        cancel: (DOC_LISTENERS.pointercancel || []).length,
        viewClass: view ? view.className : "",
      });
    }
    if (cfg.setTo !== undefined) {
      sandbox.holoSplitSet(cfg.setTo, true);
      out.afterSet = project();
    }
    break;
  }

  /* ── S128 fix round 1 — THE PIXEL CLAMP ────────────────────────────────
   * Pure arithmetic only, and deliberately so: the defect this covers was
   * MEASURED in headless Chrome and is invisible to every DOM assertion in this
   * file. What is provable here is that the numbers board.js feeds the grid can
   * never ask a track to resolve below its px floor — which is the condition
   * that made grid leave a dead band. That the band is actually gone is a
   * Chrome measurement, not this. */
  case "clamp": {
    out.chatMinPx = sandbox.HOLO_CHAT_MIN_PX;
    out.pvMinPx = sandbox.HOLO_PV_MIN_PX;
    out.cases = (cfg.cases || []).map((c) => {
      const frac = c.dx === undefined
        ? sandbox.holoSplitClamp(c.f, c.total)
        : sandbox.holoSplitFromDrag(c.startChatPx, c.dx, c.total);
      return {
        frac: frac,
        chatPx: frac * c.total,
        pvPx: (1 - frac) * c.total,
        sum: frac + (1 - frac),
        bounds: sandbox.holoSplitBounds(c.total),
        degraded: sandbox.holoSplitDegraded(c.total),
      };
    });
    break;
  }

  /* ── S128 — Q3's PROGRAM-LIST DRAWER ──────────────────────────────────── */
  case "drawer": {
    loadPrograms(cfg);
    sandbox.renderDeck();
    const view = one(deck(), ".deckview");
    const btns = many(deck(), ".holo-drawer-btn");
    out.toggleCount = btns.length;
    out.toggleTags = btns.map((b) => b.tag);
    out.toggleText = btns.map(txt);
    out.toggleTitle = btns.length ? (btns[0].title || "") : "";
    out.controls = controlsIn(view || stubEl("div"));
    out.expandedBefore = btns.map((b) => b.getAttribute("aria-expanded"));
    out.classBefore = view ? view.className : "";
    out.scrimPresent = !!one(deck(), ".holo-scrim");
    /* THE STATE TEST. Opening the drawer must not lose the deck — so a marker
     * is stamped on the LIVE transcript node and looked for again afterwards.
     * If the toggle re-rendered the deck, the node is a different object and
     * the marker is gone (which is also the chat's scroll position gone). */
    const tr = one(deck(), ".transcript");
    if (tr) tr._marker = "s128";
    const stamped = one(deck(), ".preview");
    if (stamped) stamped._marker = "s128";
    if (btns.length) btns[0].click();
    const view2 = one(deck(), ".deckview");
    out.classAfter = view2 ? view2.className : "";
    out.expandedAfter = many(deck(), ".holo-drawer-btn")
      .map((b) => b.getAttribute("aria-expanded"));
    const tr2 = one(deck(), ".transcript");
    out.transcriptSurvived = !!(tr2 && tr2._marker === "s128");
    const pv2 = one(deck(), ".preview");
    out.previewSurvived = !!(pv2 && pv2._marker === "s128");
    out.turnCountAfter = many(deck(), ".turn").length;
    // …and closing it again, by the scrim rather than the button, because that
    // is the gesture a captain actually makes.
    const scrim = one(deck(), ".holo-scrim");
    if (scrim && cfg.closeByScrim) scrim.click();
    if (cfg.closeByScrim) {
      const view3 = one(deck(), ".deckview");
      out.classAfterScrim = view3 ? view3.className : "";
      out.expandedAfterScrim = many(deck(), ".holo-drawer-btn")
        .map((b) => b.getAttribute("aria-expanded"));
    }
    break;
  }

  case "viewOnly": {
    sandbox.writesActive = cfg.writes ? true : false;
    sandbox.applyHolodeckWriteState();
    const b = REGISTRY.holodeckBtn;
    out.present = !!b;
    out.disabled = !!b.disabled;
    out.title = b.title || "";
    const ro = REGISTRY.holoRoBanner;
    out.bannerHidden = !!ro.hidden;
    out.bannerClass = ro.hidden ? null : "holo-banner ro";
    out.bannerText = txt(one(ro, ".bt"));
    break;
  }
  case "boardRender": {
    const board = {
      meta: { repo: "acme/groutwork", adapter: "local" },
      missions: [{ id: "m-1" }],
      columns: {
        align: [], research: [], validate: [], plan: [], "plan-review": [],
        schedule: [],
        implement: [{ id: "m-1", issue: 7, stage: "implement", type: "feature",
                      title: "A mission", pills: {} }],
        verify: [], done: [],
      },
    };
    sandbox.render(board);
    out.columnCount = REGISTRY.board.children.length;
    out.cardCount = many(REGISTRY.board, ".card").length;
    out.deckVisible = !REGISTRY.deckHost.hidden;
    break;
  }
  default:
    throw new Error("unknown act: " + cfg.act);
}

process.stdout.write(JSON.stringify(out, null, 2));
