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

function stubEl(tag) {
  const node = {
    tag: tag || "",
    style: {},
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
  node.focus = function () {};
  node.click = function () {
    const ev = {
      stopPropagation() {}, preventDefault() {}, target: node,
      key: "", shiftKey: false, ctrlKey: false, metaKey: false, altKey: false,
    };
    (node.listeners.click || []).forEach((fn) => fn(ev));
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

const documentStub = {
  getElementById(id) { return REGISTRY[id] || null; },
  querySelector(sel) { return qs(docRoot, sel); },
  querySelectorAll(sel) { return qsa(docRoot, sel); },
  createElement(tag) { return stubEl(tag); },
  createTextNode(t) { const n = stubEl("#text"); n._text = String(t); return n; },
  addEventListener() {},
  removeEventListener() {},
  body: bodyNode,
  documentElement: docRoot,
  activeElement: null,
};

const sandbox = {
  document: documentStub,
  window: { open() {}, location: { href: "" } },
  location: { href: "", search: "", pathname: "/" },
  navigator: { userAgent: "node" },
  localStorage: { getItem() { return null; }, setItem() {}, removeItem() {} },
  setInterval() { return 0; }, clearInterval() {},
  setTimeout() { return 0; }, clearTimeout() {},
  fetch: fetchStub,
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
    }));
    const intent = one(deck(), ".pvt-b.intent");
    out.intentTag = intent ? intent.tag : null;
    out.intentHref = intent ? intent.getAttribute("href") : null;
    out.intentReason = intent ? (intent.getAttribute("data-reason") || "") : "";
    out.sidecarChip = txt(one(deck(), ".sidecar-chip"));
    out.controls = controlsIn(deck());
    const chip = one(deck(), ".ground-chip");
    out.groundChipTag = chip ? chip.tag : null;
    out.groundChipHref = chip ? chip.getAttribute("href") : null;
    out.groundChipReason = chip ? (chip.getAttribute("data-reason") || "") : "";
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
    out.hasComposer = !!one(deck(), ".composer textarea");
    const lock = one(deck(), ".holo-lock");
    out.lockPresent = !!lock;
    out.lockText = txt(lock);
    out.lockControls = lock ? controlsIn(lock) : [];
    out.statusChips = many(deck(), ".pstat").map(txt);
    out.missionChips = many(deck(), ".pmission").map(txt);
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
  /* The hand-off dialog itself, rendered from a daemon payload — then FILED,
   * so the POST body is what is really asserted. */
  case "handoffDialog": {
    sandbox.writesActive = true;
    FETCHES.length = 0;
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
    if (cfg.rewrite !== undefined && brief) brief.value = cfg.rewrite;
    FETCHES.length = 0;
    const file = many(REGISTRY.overlay, "[data-ctl]")
      .concat(many(docRoot, "[data-ctl]"))
      .find((n) => /file mission/i.test(n.getAttribute("data-ctl") || ""));
    out.fileFound = !!file;
    if (file && !cfg.stopBeforeFile) file.click();
    const post = FETCHES.find((f) => (f.opts.method || "") === "POST");
    out.filePath = post ? post.url : null;
    out.fileBody = post ? JSON.parse(post.opts.body) : null;
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
