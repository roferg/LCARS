/* LCARS Kanban board — vanilla, dependency-free renderer + operator surface.
 *
 * READ path (ADR-003): depends ONLY on the adapter-neutral board shape from
 * /api/board, never on which adapter (local or github) served it. The live
 * channel (/api/events, SSE) pushes one update per state change; on each we
 * re-fetch and re-render.
 *
 * WRITE path (ADR-006, LOCAL-BRIDGE only): the operator screens POST to the
 * write endpoints. A 403 means the write layer is inactive (github/view-only) —
 * the board MUST keep rendering; write controls degrade to a disabled/hidden
 * "view-only" affordance and never break the read path.
 *
 * No framework, no build step (ADR-007).
 */
"use strict";

// Pipeline order + the column header colour classes (mirror the mockup).
var STAGE_META = [
  ["align", "Align", "c-amber"],
  ["research", "Research", "c-peach"],
  ["validate", "Validate", "c-blue"],
  ["plan", "Plan", "c-gold"],
  ["plan-review", "Plan Review", "c-violet"],
  ["schedule", "Schedule", "c-pink"],
  ["implement", "Implement", "c-amber"],
  ["verify", "Verify", "c-red"],
  ["done", "Done", "c-green"],
];

// Write-layer state: null=unknown, true=active, false=view-only (a 403 was seen
// or the capability probe said so). When false, write controls are disabled.
var writesActive = null;

// UX-14: the repo the board is attached to (board.meta.repo), captured on every
// render so the detail modal's "View on GitHub" link can build the issue URL
// even when the per-mission payload doesn't echo the repo. May stay null.
var detailRepo = null;

/* UX-28: a board-wide index of mission-id → its GitHub issue number, captured on
   every render. A logged bug carries `parentMission` (a mission id); to render
   the "child of #<parentIssue>" badge + GitHub link we resolve that id to its
   issue here. Falls back to the parent id when the issue isn't on the board. */
var ISSUE_BY_ID = Object.create(null);
function indexIssues(board) {
  ISSUE_BY_ID = Object.create(null);
  (board.missions || []).forEach(function (m) {
    if (m && m.id != null) ISSUE_BY_ID[String(m.id)] = m.issue || null;
  });
}

/* UX-28: is this mission a logged bug (filed via the Mission Log against a
   parent)? The authoritative signal is `type=="bug" && parentMission set`; the
   board shape may not yet echo parentMission (read off disk server-side), so we
   ALSO accept the always-present `linked` flag combined with a bug type. Read
   defensively — every field absent ⇒ not a log bug. */
function isLogBug(m) {
  if (!m) return false;
  var isBug = m.type === "bug";
  var hasParent = m.parentMission != null && String(m.parentMission) !== "";
  return (isBug && hasParent) || (isBug && !!m.linked) || (hasParent && !!m.linked);
}

/* UX-28: resolve the parent's display label for a logged bug. Prefers the
   parent issue number (→ "#142"), resolved from the board index; falls back to
   the raw parent mission id. Returns { text, issue } (issue null when unknown). */
function parentRef(m) {
  var pid = m && m.parentMission != null ? String(m.parentMission) : null;
  if (!pid) return { text: null, issue: null };
  var issue = ISSUE_BY_ID[pid] || null;
  return { text: issue ? "#" + issue : pid, issue: issue };
}

/* UX-17: optimistic "starting" set. After a captain clicks Start the driver
   takes ~2s to spawn → lock → flip mission.running true, during which a naive
   render would still show a clickable Start. We mark the mission id "starting"
   on click and treat it as running across every board refresh until the real
   mission.running becomes true (then clear) OR a safety timeout fires (~30s) so
   a failed start never wedges the card. Keyed by mission id → timeout handle. */
var STARTING = Object.create(null);
var STARTING_TIMEOUT_MS = 30000;

function markStarting(id) {
  if (id == null) return;
  var key = String(id);
  if (STARTING[key]) clearTimeout(STARTING[key]);
  STARTING[key] = setTimeout(function () { clearStarting(key); refresh(); },
    STARTING_TIMEOUT_MS);
}
function clearStarting(id) {
  if (id == null) return;
  var key = String(id);
  if (STARTING[key]) { clearTimeout(STARTING[key]); delete STARTING[key]; }
}
function isStarting(id) {
  return id != null && !!STARTING[String(id)];
}

/* UX-17/UX-20/UX-21: the single source of truth for a mission's run/pause
   lifecycle, derived purely client-side from the adapter-neutral shape (running,
   paused) plus the optimistic STARTING set. Every running-pulse / in-flight /
   paused render gates through these so the four states never overlap.
     starting : optimistic post-click, before running flips true (UX-17)
     pausing  : pause requested but a driver is still live  (paused && running)
     paused   : settled, no live driver                     (paused && !running)
     running  : live driver advancing, not paused           (running && !paused)
   When the real running flag finally arrives we drop the optimistic flag. */
function runState(m) {
  var running = !!(m && m.running);
  var paused = !!(m && m.paused);
  var queued = !!(m && m.queued);
  if (running && isStarting(m.id)) clearStarting(m.id);
  var starting = isStarting(m && m.id) && !paused;
  if (paused && running) return "pausing";
  if (paused) return "paused";
  // UX-29: a mission SCHEDULED in a resolve-logs batch but not yet started reads
  // as "queued / waiting to go" — it is NOT yet running, so it must not show the
  // running pulse. paused/pausing win (a paused queued card reads as paused).
  // A live driver (running) also wins: once it actually starts, it's running.
  if (queued && !running && !starting) return "queued";
  if (running || starting) return "running";
  return "idle";
}
// UX-20/UX-29: the running pulse / "IN FLIGHT" copy may show ONLY when truly
// running and not paused/queued (suppressed while pausing/paused/queued).
// Optimistic-start counts.
function isInFlight(m) { return runState(m) === "running"; }

function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function btn(label, cls, onClick) {
  var b = el("button", "btn" + (cls ? " " + cls : ""), label);
  b.type = "button";
  if (onClick) b.addEventListener("click", function (e) {
    e.stopPropagation();
    onClick(e);
  });
  return b;
}

function levelClass(level) {
  return level === "low" ? "low" : level === "high" ? "high" : "med";
}

function pillNode(p, kind) {
  if (!p) return null;
  if (kind === "cost") return el("span", "pill cost", "⬡ " + (p.label || ""));
  return el("span", "pill " + levelClass(p.level), p.label || "");
}

/* When the write layer is known to be inactive, disable a write control so the
   board stays usable view-only. Controls created before the probe resolves get
   re-checked on click via guardWrite(). */
function applyWriteState(button) {
  if (writesActive === false) {
    button.disabled = true;
    button.title = "view-only board — writes are disabled";
  }
  return button;
}

/* ════════════════ CARD RENDER ════════════════ */
function cardNode(m) {
  var rs = runState(m); // UX-17/20/21: derived run/pause lifecycle (one source).
  var card = el("div", "card");
  if (m.awaiting) card.className += " awaiting";
  // UX-21/UX-22: paused AND pausing both carry the .paused chrome (dimmed body),
  // but the status label + action button are kept high-contrast (see below).
  if (rs === "paused" || rs === "pausing") card.className += " paused";
  // UX-28: a logged bug (child of a parent mission) gets the PINK child chrome.
  // The existing `.child` styling is pink-accented; isLogBug folds in the
  // type=="bug"+parentMission signal so a bug child reads pink even before the
  // backend echoes `linked` for it.
  if (m.linked || isLogBug(m)) card.className += " child";
  if (isLogBug(m)) card.className += " logbug";
  // UX-13/UX-20: a live drive is advancing this mission — flag the card so it
  // carries the running tint. Gated on isInFlight so a paused/pausing card never
  // shows the running animation (UX-20). Optimistic-start counts (UX-17).
  if (isInFlight(m)) card.className += " running";
  // UX-10/UX-16: id handle so a closed modal (Start) can stamp a transient busy
  // animation onto this card (showCardBusy).
  if (m.id != null) card.setAttribute("data-mid", String(m.id));

  var issue = m.issue ? "#" + m.issue : "—";
  card.appendChild(el("div", "no", issue + " · lcars:" + m.stage));
  card.appendChild(el("div", "ttl", m.title || m.id));

  // UX-28: a small "log bug · child of #<parentIssue>" badge on a logged bug,
  // linking to the parent issue when the repo + parent issue resolve. Rendered
  // just under the title so the relationship reads at a glance on the pink card.
  if (isLogBug(m)) card.appendChild(logBugBadge(m));

  var pills = el("div", "pills");
  // UX-29: a "QUEUED · WAITING" pill when scheduled-but-not-started in a
  // resolve-logs batch — distinct from running/paused/awaiting, no running
  // pulse. awaiting still wins (a gate outranks the queue).
  if (rs === "queued" && !m.awaiting) {
    pills.appendChild(el("span", "pill queued", "◷ QUEUED · WAITING"));
  }
  if (m.awaiting) {
    pills.appendChild(el("span", "pill await", "● AWAITING YOU"));
    if (m.pills && m.pills.cost) pills.appendChild(pillNode(m.pills.cost, "cost"));
  } else if (m.pills) {
    var c = pillNode(m.pills.cost, "cost"); if (c) pills.appendChild(c);
    var r = pillNode(m.pills.reasoning); if (r) pills.appendChild(r);
    var i = pillNode(m.pills.implementation); if (i) pills.appendChild(i);
  }
  card.appendChild(pills);

  // UX-21/UX-22: a high-contrast status label for paused/pausing. It carries the
  // .pause-status class so the .paused dim overlay can EXCLUDE it (stays bright).
  // pausing = pause requested but a driver is still live (will stop at the next
  // safe boundary); paused = settled.
  if (rs === "pausing") {
    card.appendChild(el("div", "no pause-status pausing",
      "◐ PAUSING — stopping at next safe boundary"));
  } else if (rs === "paused") {
    card.appendChild(el("div", "no pause-status", "⏸ paused"));
  }

  if (m.progress) {
    var prog = el("div", "progress");
    var bar = el("div", "bar");
    var done = m.progress.ticketsDone || 0;
    var total = m.progress.ticketsTotal || 0;
    var pct = total > 0 ? Math.round((done / total) * 100) : 0;
    var fill = el("i"); fill.style.width = pct + "%"; bar.appendChild(fill);
    prog.appendChild(bar);
    prog.appendChild(el("div", "lab", m.progress.label || ""));
    card.appendChild(prog);
  }

  if (m.tickets && m.tickets.length) {
    var tk = el("div", "tickets");
    m.tickets.forEach(function (t) {
      // UX-23: default/inactive ticket-row text is WHITE (readable); the ACTIVE
      // ticket keeps its orange (the .run/.in-progress states), done/failed keep
      // their state colours. The state class drives the colour entirely in CSS.
      var row = el("div", "tk " + (t.state || "pending"));
      row.appendChild(el("span", "dot"));
      var label = (t.id || "") + (t.title ? " · " + t.title : "");
      row.appendChild(document.createTextNode(label));
      tk.appendChild(row);
    });
    card.appendChild(tk);
  }

  // UX-13/UX-20: live "running" pulse — shown ONLY when truly in flight (running
  // && !paused; optimistic-start counts). Suppressed while pausing/paused so a
  // halting card never shows motion. Client-side animation only.
  if (isInFlight(m)) card.appendChild(runningPulse(stageLabel(m.stage)));

  // ── inline controls (mock #card .card-ctrl): stage-appropriate write actions
  card.appendChild(cardControls(m));

  card.addEventListener("click", function () { openDetail(m.id); });
  return card;
}

/* Stage-appropriate write controls. UX-12: the whole card is click-to-open
   (openDetail), so the explicit "Open ▸" button is gone everywhere; inline
   controls stopPropagation so they don't also open the detail.
   UX-13: `m.running` (a live `run drive` is advancing this mission) overrides the
   pre-run Start → Pause so Start can't be double-triggered, and the running card
   gets a themed client-side pulse so a long silent stage never reads as stuck. */
function cardControls(m) {
  var ctrl = el("div", "card-ctrl");
  if (m.awaiting) {
    ctrl.appendChild(applyWriteState(btn("Answer ▸", "danger", function () {
      openRespond(m.id);
    })));
    return ctrl;
  }
  if (m.stage === "done") {
    return ctrl; // terminal — whole-card click opens detail; no inline control.
  }
  var rs = runState(m);
  if (m.stage === "verify") {
    ctrl.appendChild(applyWriteState(btn("✓ Verify ▸", "go", function () {
      openVerify(m.id);
    })));
  } else if (rs === "paused") {
    // UX-22: RESUME stays at FULL prominence on a dimmed card — the .pause-action
    // class excludes it from the .paused dim overlay.
    var resume = applyWriteState(btn("▶ Resume", "go", function () {
      dispatchCardBusy(m.id, "/api/mission/" + enc(m.id) + "/resume", {},
        ctrl, "Re-engaging warp core…");
    }));
    resume.className += " pause-action";
    ctrl.appendChild(resume);
  } else if (rs === "pausing") {
    // UX-21: pause requested but a driver is still live — it will stop at the
    // next safe boundary. No Pause (already requested) and no Resume yet (still
    // running); show a disabled, full-contrast "Pausing…" affordance.
    var pausing = btn("◐ Pausing…", "warn pause-action", null);
    pausing.disabled = true;
    pausing.title = "Pause requested — stopping at the next safe boundary.";
    ctrl.appendChild(pausing);
  } else if (rs === "running") {
    // UX-13: a live drive is advancing this mission — offer Pause, never Start.
    // UX-17: while OPTIMISTICALLY starting (clicked Start, running not yet true)
    // the Pause button stays disabled so the captain can't pause a half-spawned
    // driver; it enables once the real running flag arrives.
    var pause = applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCardBusy(m.id, "/api/mission/" + enc(m.id) + "/pause", {},
        ctrl, "Holding station…");
    }));
    if (!m.running && isStarting(m.id)) {
      pause.disabled = true;
      pause.title = "Engaging the driver…";
    }
    ctrl.appendChild(pause);
  } else if (isRunningStage(m.stage)) {
    // an in-flight headless stage with no running flag yet — offer Pause, never
    // Start (so Start can't be double-fired).
    ctrl.appendChild(applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCardBusy(m.id, "/api/mission/" + enc(m.id) + "/pause", {},
        ctrl, "Holding station…");
    })));
  } else {
    // align (and any pre-run stage): Start launches the run via the Launch panel
    ctrl.appendChild(applyWriteState(btn("▶ Start", "go", function () {
      openLaunch(m.id);
    })));
  }
  return ctrl;
}

/* UX-28: the "log bug · child of #<parent>" badge for a logged bug. When the
   parent issue + repo resolve it renders as a link to the parent issue;
   otherwise a plain badge (parent mission id). Defensive on every field. */
function logBugBadge(m) {
  var ref = parentRef(m);
  var txt = "log bug" + (ref.text ? " · child of " + ref.text : "");
  // a link only when we can build a GitHub url (repo + numeric parent issue).
  if (detailRepo && ref.issue) {
    var a = el("a", "logbug-badge", txt);
    a.href = "https://github.com/" + detailRepo + "/issues/" + ref.issue;
    a.target = "_blank"; a.rel = "noopener";
    a.title = "logged bug — open the parent mission issue";
    a.addEventListener("click", function (e) { e.stopPropagation(); });
    return a;
  }
  var b = el("span", "logbug-badge", txt);
  b.title = "logged bug — child of a parent mission";
  return b;
}

function isRunningStage(stage) {
  return ["research", "validate", "plan", "plan-review", "schedule", "implement"]
    .indexOf(stage) !== -1;
}

function render(board) {
  indexIssues(board); // UX-28: refresh the id→issue index for parent resolution.
  var root = document.getElementById("board");
  root.innerHTML = "";
  STAGE_META.forEach(function (meta) {
    var key = meta[0], name = meta[1], colour = meta[2];
    var cards = (board.columns && board.columns[key]) || [];
    var col = el("div", "col");
    var head = el("div", "col-head " + colour);
    head.appendChild(el("span", null, name));
    head.appendChild(el("span", "ct", String(cards.length)));
    col.appendChild(head);
    var body = el("div", "col-body");
    cards.forEach(function (m) { body.appendChild(cardNode(m)); });
    col.appendChild(body);
    root.appendChild(col);
  });
  var n = (board.missions || []).length;
  setStatus(n + " active mission" + (n === 1 ? "" : "s"));
  renderMeta(board.meta);
}

/* S70-A: render "which repo am I attached to" + adapter/mode hint in the topbar.
   Depends only on the board shape (board.meta), updated on every live render. */
function renderMeta(meta) {
  // capture the attached repo for the detail "View on GitHub" link (UX-14).
  detailRepo = (meta && meta.repo) || null;
  var host = document.getElementById("repoMeta");
  if (!host) return;
  host.innerHTML = "";
  if (!meta || !meta.repo) return;
  // meta.repo may carry "owner/name" (GitHub-adapter parity); the topbar shows
  // just the repo-NAME segment (strip any "owner/" prefix) — e.g. "LCARS".
  var name = String(meta.repo).split("/").pop() || meta.repo;
  host.appendChild(el("span", "sep", "—"));
  host.appendChild(el("span", "repo", name));
  var adapter = meta.adapter || "local";
  var ro = meta.mode === "read-only";
  var hint = el("span", "hint" + (ro ? " ro" : ""),
    adapter + (ro ? " · view-only" : ""));
  host.appendChild(hint);
}

function setStatus(t) {
  var s = document.getElementById("status");
  if (s) s.textContent = t;
}

function refresh() {
  return fetch("/api/board").then(function (r) { return r.json(); })
    .then(render)
    .catch(function () { setStatus("board unavailable"); });
}

/* ════════════════ OVERLAY HOST ════════════════ */
function overlay() { return document.getElementById("overlay"); }
function overlayBody() { return document.getElementById("overlayBody"); }

function showOverlay(node) {
  var body = overlayBody();
  body.innerHTML = "";
  body.appendChild(node);
  overlay().hidden = false;
}

function closeOverlay() {
  overlay().hidden = true;
  overlayBody().innerHTML = "";
  clearDetailTimers(); // UX-32: never leak the live active-time tick interval.
}

// click on the dimmed backdrop (outside the modal stage content) dismisses.
overlay().addEventListener("click", function (e) {
  if (e.target === this) closeOverlay();
});
document.addEventListener("keydown", function (e) {
  if (e.key === "Escape" && !overlay().hidden) closeOverlay();
});

function enc(s) { return encodeURIComponent(s); }

/* A reusable LCARS modal scaffold. headClass tints the header (red/teal/pink). */
function modal(title, opts) {
  opts = opts || {};
  var wrap = el("div", "modal" + (opts.wide ? " wide" : ""));
  var head = el("div", "modal-head" + (opts.headClass ? " " + opts.headClass : ""));
  head.appendChild(el("span", null, title));
  head.appendChild(btn("✕", "close", closeOverlay));
  // the close button gets the modal-head's bare close styling, not .btn
  head.lastChild.className = "close";
  wrap.appendChild(head);
  var body = el("div", "modal-body");
  wrap.appendChild(body);
  var foot = el("div", "modal-foot");
  wrap.appendChild(foot);
  return { wrap: wrap, body: body, foot: foot, head: head };
}

/* ════════════════ WRITE DISPATCH ════════════════ */
/* POST a write; on success refresh the board (SSE also nudges it). A 403 flips
   the board into view-only mode and surfaces it without breaking the read path.
   onResult(state) is called with the success `state` object. */
function postWrite(path, payload, onResult, onError) {
  return fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload || {}),
  }).then(function (r) {
    return r.json().then(function (data) { return { status: r.status, data: data }; });
  }).then(function (res) {
    if (res.status === 403) {
      markViewOnly();
      if (onError) onError("This board is view-only — writes are disabled.");
      return;
    }
    if (!res.data || res.data.ok !== true) {
      var msg = (res.data && res.data.error) || ("write failed (HTTP " + res.status + ")");
      if (onError) onError(msg);
      return;
    }
    writesActive = true;
    refresh();
    if (onResult) onResult(res.data.state || {});
  }).catch(function () {
    if (onError) onError("Network error — could not reach the daemon.");
  });
}

/* A bare card-level dispatch (pause/resume): no modal, just fire + refresh. */
function dispatchCard(path, payload) {
  postWrite(path, payload, function () {}, function (msg) {
    setStatus(msg);
  });
}

function markViewOnly() {
  writesActive = false;
  var vo = document.getElementById("viewonly");
  if (vo) vo.hidden = false;
  // disable any write controls already on screen.
  var btns = document.querySelectorAll(".board .btn.go, .board .btn.warn, .board .btn.danger");
  btns.forEach(function (b) { applyWriteState(b); });
}

/* Probe the write layer once at boot with a harmless OPTIONS-like POST? The
   server has no capability endpoint; instead we infer view-only lazily — the
   first write that returns 403 flips the flag and disables controls. To give an
   up-front affordance we do a cheap probe against a non-mutating verb shape that
   the server rejects with 400 (active) vs 403 (inactive): POST /api/mission with
   an empty body. Active layer → 400 (missing idea); view-only → 403. */
function probeWrites() {
  fetch("/api/mission", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  }).then(function (r) {
    if (r.status === 403) { markViewOnly(); }
    else { writesActive = true; }
  }).catch(function () { /* leave unknown; lazy 403 handling still applies */ });
}

/* ════════════════ SCREEN: FILE A MISSION (#file) ════════════════ */
function openFile() {
  var m = modal("▦ File New Mission");
  var idea = el("textarea"); idea.rows = 4;
  idea.placeholder = "What do you want to build, improve, or fix?";
  m.body.appendChild(field("The idea — what do you want to build, improve, or fix?", idea));

  // UX-1: the Repository field is removed from the File modal — the viewscreen
  // is per-repo this iteration, so a chooseable repo is useless. The server
  // infers the attached repo; nothing here renders a repo input.

  var engineWrap = el("div", "field");
  engineWrap.appendChild(label("Engine — which CLI drives this mission?"));
  var choice = el("div", "choice");
  var chosen = { engine: "claude" };
  var optClaude = el("span", "opt rec", "⬡ Claude");
  var optCopilot = el("span", "opt", "⬡ Copilot");
  function pick(engine, node) {
    chosen.engine = engine;
    [optClaude, optCopilot].forEach(function (o) { o.classList.remove("sel"); });
    node.classList.add("sel");
  }
  optClaude.classList.add("sel");
  optClaude.addEventListener("click", function () { pick("claude", optClaude); });
  optCopilot.addEventListener("click", function () { pick("copilot", optCopilot); });
  choice.appendChild(optClaude); choice.appendChild(optCopilot);
  engineWrap.appendChild(choice);
  m.body.appendChild(engineWrap);

  var err = el("div", "errline"); err.hidden = true;
  m.body.appendChild(err);

  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  // "File & Begin Alignment" opens the interactive Align grilling console
  // (S70-B) — the structured one-question-at-a-time interview, not a
  // straight-to-skeleton create. The mission lands in Align when the console
  // completes and file.sh runs.
  // UX-2: opening the Align console spawns a worker turn (several seconds) — show
  // the themed working indicator inline while it is in flight; it clears on both
  // success (console replaces the modal) and error.
  // UX-7: Trek-themed loading copy for the Align-open worker turn (POST
  // /api/align/start) — "Scanning the codebase…".
  var fileBusy = workingNode("Scanning the codebase…"); fileBusy.hidden = true;
  m.body.appendChild(fileBusy);

  var go = applyWriteState(btn("File & Begin Alignment ▸", "go big", function () {
    var text = idea.value.trim();
    if (!text) { showErr(err, "Describe the idea first."); return; }
    go.disabled = true; go.textContent = "Scanning…";
    err.hidden = true; fileBusy.hidden = false;
    openAlignConsole(text, chosen.engine, function (msg) {
      go.disabled = false; go.textContent = "File & Begin Alignment ▸";
      fileBusy.hidden = true;
      showErr(err, msg);
    });
  }));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  idea.focus();
}

/* ════════════════ SCREEN: ALIGN GRILLING CONSOLE (#align) ════════════════ */
/* A stateful, multi-turn interview rendered to the mockup's .twopane: one
   question at a time on the LEFT (.qtext + .choice .opt[.rec] + free-form input
   + .progress-line), the PRD assembling LIVE on the RIGHT (.prd-doc). Each
   answer POSTs to /api/align/<sid>/answer; the server spawns the next worker
   turn. On `done` file.sh has already run server-side and the board refreshes. */
function openAlignConsole(idea, engine, onStartError) {
  postWrite("/api/align/start", { idea: idea, engine: engine },
    function (state) { renderAlignConsole(state); },
    function (msg) { if (onStartError) onStartError(msg); });
}

function renderAlignConsole(state) {
  // a session that resolved in one shot (trivial mission) → straight to done.
  if (state.status === "done") { renderAlignDone(state); return; }

  var m = modal("⊹ Alignment Console", { wide: true, headClass: "teal" });
  var pane = el("div", "twopane");

  var left = el("div", "console-l");
  var count = el("div", "qcount");
  var qtext = el("div", "qtext");
  var choices = el("div", "choice");
  var freeWrap = el("div", "field");
  var free = el("textarea"); free.rows = 2;
  free.placeholder = "…or answer in your own words";
  freeWrap.appendChild(label("Your answer")); freeWrap.appendChild(free);
  var err = el("div", "errline"); err.hidden = true;
  // UX-2: themed working indicator for each answer's worker turn (and the final
  // hand-off). Lives in the left console pane; label is re-set per phase.
  // UX-7: themed copy for each Align-answer worker turn + the final hand-off.
  var busy = workingNode("Formulating the next inquiry…"); busy.hidden = true;
  var prog = el("div", "progress-line");
  left.appendChild(count); left.appendChild(qtext); left.appendChild(choices);
  left.appendChild(freeWrap); left.appendChild(err); left.appendChild(busy);
  left.appendChild(prog);

  var right = el("div", "console-r");
  right.appendChild(el("div", "mock-cap", "PRD · building live"));
  var prd = el("div", "prd-doc");
  right.appendChild(prd);

  pane.appendChild(left); pane.appendChild(right);
  m.body.appendChild(pane);
  // the twopane owns its own padding + internal scroll (UX-4/UX-5); .flush makes
  // the body a flush flex container so the panes fill the capped modal height.
  m.body.className = "modal-body flush";

  var submit = applyWriteState(btn("Submit & Continue ▸", "go big", null));
  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  m.foot.appendChild(submit);

  var sid = state.sessionId;
  var picked = { val: null };
  var asked = 0;

  function paintPRD(md) { renderPrdDoc(prd, md || ""); }

  function paintQuestion(st) {
    asked += 1;
    var q = st.question || {};
    count.textContent = "Question " + asked;
    qtext.textContent = q.text || "What would you like to refine?";
    choices.innerHTML = ""; picked.val = null; free.value = ""; err.hidden = true;
    (q.choices || []).forEach(function (c) {
      var isRec = (q.recommended != null && c === q.recommended);
      var opt = el("span", "opt" + (isRec ? " rec" : ""), c);
      opt.addEventListener("click", function () {
        Array.prototype.forEach.call(choices.children, function (o) {
          o.classList.remove("sel"); });
        opt.classList.add("sel"); picked.val = c; free.value = "";
      });
      choices.appendChild(opt);
      if (isRec) { opt.classList.add("sel"); picked.val = c; }
    });
    // a free-form answer overrides any picked choice.
    free.addEventListener("input", function () {
      if (free.value.trim()) {
        Array.prototype.forEach.call(choices.children, function (o) {
          o.classList.remove("sel"); });
        picked.val = null;
      }
    });
    paintPRD(st.prd);
    paintProgress(prog, asked, false);
    submit.disabled = false; submit.textContent = "Submit & Continue ▸";
    free.focus();
  }

  submit.onclick = function () {
    var answer = free.value.trim() || picked.val || "";
    if (!answer) { showErr(err, "Pick the recommendation or type an answer."); return; }
    submit.disabled = true; submit.textContent = "Working…";
    err.hidden = true;
    // UX-2: the worker turn (and, on the final answer, the file.sh hand-off)
    // runs server-side within this POST. Show the themed working indicator the
    // whole time; it clears on the next question, on done, or on error.
    busy.querySelector(".lcars-working-label").textContent =
      "Formulating the next inquiry…";
    busy.hidden = false;
    postWrite("/api/align/" + enc(sid) + "/answer", { answer: answer },
      function (st) {
        busy.hidden = true;
        if (st.status === "done") {
          // explicit, labelled hand-off state before the board refresh swaps in
          // the new Align card and the confirmation modal. UX-7: the captain's
          // subspace/transmission metaphor for the Align→file hand-off.
          busy.querySelector(".lcars-working-label").textContent =
            "Transmitting mission over subspace…";
          busy.hidden = false;
          renderAlignDone(st);
          return;
        }
        paintQuestion(st);
      },
      function (msg) {
        busy.hidden = true;
        submit.disabled = false; submit.textContent = "Submit & Continue ▸";
        showErr(err, msg);
      });
  };

  showOverlay(m.wrap);
  paintQuestion(state);
}

/* Alignment reached: file.sh has already run server-side and the board has
   refreshed (the new card sits in Align). Show a brief confirmation. */
function renderAlignDone(state) {
  var m = modal("⊹ Alignment Reached", { headClass: "teal" });
  m.body.appendChild(noteEl(
    "Alignment reached — the mission is filed and now sits in the " +
    "Align column. The estimator runs against the codebase to set the cost " +
    "and difficulty pills.", "amber"));
  if (state.prd) {
    m.body.appendChild(el("div", "mock-cap", "Final PRD"));
    var prd = el("div", "prd-doc");
    renderPrdDoc(prd, state.prd);
    var box = el("div"); box.style.cssText =
      "background:var(--lcars-black);padding:14px 16px;border-radius:8px;max-height:42vh;overflow:auto";
    box.appendChild(prd);
    m.body.appendChild(box);
  }
  m.foot.appendChild(btn("Done", "go big", closeOverlay));
  showOverlay(m.wrap);
  refresh();
}

/* Render PRD markdown into the .prd-doc panel: section headers (**Foo:** /
   # / ##) become amber .h spans; bullet lines are teal .add additions. Plain
   text passes through. Mirrors the mockup's live-PRD styling. */
function renderPrdDoc(host, md) {
  host.innerHTML = "";
  (md || "").split("\n").forEach(function (line) {
    var hdr = line.match(/^\s*\*\*(.+?):\*\*(.*)$/);
    var heading = line.match(/^\s*#{1,3}\s+(.*)$/);
    if (heading) {
      host.appendChild(el("span", "h", heading[1]));
    } else if (hdr) {
      host.appendChild(el("span", "h", hdr[1]));
      if (hdr[2].trim()) host.appendChild(document.createTextNode(hdr[2].trim() + "\n"));
    } else if (/^\s*[-*]\s+/.test(line)) {
      host.appendChild(el("div", "add", line));
    } else {
      host.appendChild(document.createTextNode(line + "\n"));
    }
  });
}

function paintProgress(host, asked, done) {
  host.innerHTML = "";
  // we don't know the total ahead of time; show one filled bar per answered
  // question plus a current marker. A fixed track of 6 reads like the mockup.
  var total = Math.max(6, asked + 1);
  for (var i = 0; i < total; i++) {
    var seg = el("i");
    if (i < asked - 1) seg.classList.add("on");
    else if (i === asked - 1) seg.classList.add(done ? "on" : "cur");
    host.appendChild(seg);
  }
}

/* ════════════════ SCREEN: LAUNCH / START (#launch) ════════════════ */
function openLaunch(id) {
  fetchMission(id, function (mi) {
    var m = modal("▶ Launch Mission " + idLabel(mi));
    // estimator readout: cost + two difficulty pills
    var pills = el("div", "pills"); pills.style.marginBottom = "16px";
    addPills(pills, mi.pills);
    m.body.appendChild(pills);

    // per-stage model mix (S70-B1): render the estimator's table when present,
    // else keep the graceful note.
    var mix = el("h4"); mix.textContent = "Per-stage model mix";
    mix.style.marginBottom = "6px";
    m.body.appendChild(mix);
    if (mi.modelMix && mi.modelMix.length) {
      m.body.appendChild(modelMixTable(mi.modelMix));
    } else {
      m.body.appendChild(noteEl(
        "The per-stage model mix is not exposed for this mission — the cost and " +
        "difficulty pills above are the estimator readout. The override below is " +
        "applied in plain language at start.", "amber"));
    }

    var ov = el("input");
    ov.placeholder = "e.g. “use Opus the whole way through” · “keep reasoning cheap”";
    m.body.appendChild(field("Override (plain language — optional)", ov));

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    m.foot.appendChild(btn("Cancel", null, closeOverlay));
    var go = applyWriteState(btn("▶ Start Run", "go big", function () {
      // UX-11: the backend returns /start promptly — close the Launch modal
      // immediately (optimistic) and rely on the board/SSE to reflect progress.
      // Don't wait on a long blocking response.
      // UX-10/UX-16: surface the themed working animation on the card briefly via
      // showCardBusy so Start gives feedback while the request is in flight.
      var override = ov.value.trim() || undefined;
      // UX-17: set the OPTIMISTIC starting flag BEFORE closing the modal so the
      // card immediately renders as running (Pause/spinner, never a clickable
      // Start) and stays that way across refreshes until mission.running flips
      // true (cleared in runState) or the safety timeout fires.
      markStarting(id);
      closeOverlay();
      showCardBusy(id, "Engaging…");
      postWrite("/api/mission/" + enc(id) + "/start", { override: override },
        function () { /* board/SSE refresh shows the running state */ },
        function (msg) {
          // a failed start: drop the optimistic flag so Start returns.
          clearStarting(id); setStatus(msg); refresh();
        });
    }));
    m.foot.appendChild(go);
    showOverlay(m.wrap);
  });
}

/* UX-33: strip CLI command syntax from any gate question rendered in the GUI.
   The harness writes captain-facing gate prose that sometimes parrots terminal
   commands — backtick-wrapped `lcars <verb> <id> …` snippets and the bare
   `lcars <verb> …` form. The GUI offers buttons for these, so the raw command
   must never be shown. We drop backtick-wrapped CLI spans entirely, neutralise
   any remaining bare `lcars <verb>` mentions to a friendly phrase, and tidy the
   dangling punctuation/whitespace the removal leaves behind. Defensive: a
   non-string / empty input returns "". */
function sanitizeGateText(text) {
  var s = String(text == null ? "" : text);
  // 1) backtick-wrapped CLI commands → removed wholesale (e.g. `lcars feedback X`).
  s = s.replace(/`[^`]*\blcars\b[^`]*`/gi, "");
  // 2) any other backtick span that is a bare command-ish token → unwrap to text.
  s = s.replace(/`([^`]*)`/g, "$1");
  // 3) bare "lcars <verb> …" up to sentence/clause end → friendly phrase, so a
  //    stray "send the Mission back with lcars feedback PARENT" reads cleanly.
  s = s.replace(/\bwith\s+lcars\s+\w[\w-]*[^.,;]*/gi, "using the send-back action");
  s = s.replace(/\blcars\s+\w[\w-]*\b/gi, "the harness");
  // 4) tidy doubled spaces + dangling " — ." / orphaned punctuation left behind.
  s = s.replace(/\s{2,}/g, " ").replace(/\(\s*\)/g, "")
       .replace(/\s+([.,;])/g, "$1").trim();
  return s;
}

/* UX-33: detect the consolidated re-verify gate. resolve-logs raises ONE
   awaiting-human gate on a PARENT mission once its logged bug children are
   resolved; there is no dedicated `gateKind` field, so we key off the gate
   question's signature phrasing ("re-verify" / "logged bug(s) resolved") on an
   awaiting mission. parentMission being ABSENT (a parent gate) reinforces it,
   but we don't require it (the field may not be on the shape). Defensive: false
   for any non-awaiting / non-matching mission. */
function isReverifyGate(mi) {
  if (!mi || !mi.awaiting) return false;
  var q = String(mi.question || "").toLowerCase();
  if (!q) return false;
  var reverify = q.indexOf("re-verify") !== -1 || q.indexOf("reverify") !== -1;
  var loggedBug = /logged bugs?\b/.test(q) ||
    (q.indexOf("logged bug") !== -1) || q.indexOf("ride this mission's pr") !== -1;
  return reverify && loggedBug;
}

/* ════════════════ SCREEN: RESPOND GATE (#respond) ════════════════ */
function openRespond(id) {
  fetchMission(id, function (mi) {
    // UX-33: a consolidated re-verify gate gets a dedicated, CLI-free screen with
    // accept / send-back action buttons mapped to the existing endpoints.
    if (isReverifyGate(mi)) { openReverifyGate(mi); return; }

    var m = modal("● Awaiting You — Mission " + idLabel(mi) +
      " · " + (mi.stage || "").toUpperCase(), { wide: true, headClass: "red" });

    var q = el("div", "qtext"); q.style.fontSize = "18px";
    // UX-33: never parrot raw `lcars <verb>` CLI syntax in the GUI — sanitize the
    // gate question before display.
    q.textContent = sanitizeGateText(mi.question) ||
      "The harness needs your decision to proceed.";
    m.body.appendChild(q);
    m.body.appendChild(noteEl(
      "Why you’re seeing this — a stage escalated a strategic/scope call. " +
      "Answer below and the mission resumes from where it stopped."));

    var ans = el("textarea"); ans.rows = 3;
    ans.placeholder = "Answer in your own words…";
    m.body.appendChild(field("Your answer", ans));

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    var go = applyWriteState(btn("Submit & Resume ▸", "go big", function () {
      var text = ans.value.trim();
      if (!text) { showErr(err, "Type an answer first."); return; }
      go.disabled = true; go.textContent = "Submitting…";
      postWrite("/api/mission/" + enc(id) + "/respond", { answer: text },
        function () { closeOverlay(); },
        function (msg) { go.disabled = false; go.textContent = "Submit & Resume ▸"; showErr(err, msg); });
    }));
    m.foot.appendChild(go);
    showOverlay(m.wrap);
    ans.focus();
  });
}

/* ════════════════ SCREEN: RE-VERIFY GATE (UX-33) ════════════════ */
/* The consolidated re-verify gate on a parent whose logged bugs are resolved.
   UI-appropriate copy + action BUTTONS (no CLI syntax, no raw mission ids):
     Accept the fixes → /respond (answers the gate; folds each logged bug to Done)
     Send back…       → /verify {decision:"send-back", feedback} (parent feedback)
   The friendly title comes from idLabel (issue # + title), never the raw id. */
function openReverifyGate(mi) {
  var m = modal("✓ Re-verify — " + idLabel(mi),
    { wide: true, headClass: "teal" });

  var lead = el("div", "qtext"); lead.style.fontSize = "18px";
  lead.textContent = "The logged bugs raised against this mission have been " +
    "fixed and folded onto its branch. Re-inspect the fixes, then accept them " +
    "or send the mission back with feedback.";
  m.body.appendChild(lead);
  m.body.appendChild(noteEl(
    "The fixes ride this mission’s pull request — there is no separate PR per " +
    "bug. Accepting folds each logged bug to Done; sending back loops the " +
    "mission to Align with your note.", "amber"));

  // the linked bug children, when the detail shape carries them, listed by
  // friendly title (no raw mission ids). Defensive: omitted when absent.
  var kids = (mi.children || mi.linkedChildren || []);
  if (kids.length) {
    m.body.appendChild(el("h4", null, "Logged bugs resolved"));
    var list = el("div", "log-preview-list");
    kids.forEach(function (c) {
      var row = el("div", "crit");
      row.appendChild(el("span", "pill go", "✓"));
      row.appendChild(document.createTextNode(" " + (c.title || c.id || "Bug")));
      list.appendChild(row);
    });
    m.body.appendChild(list);
  }

  var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

  // Send-back reveals a feedback field, then dispatches the feedback decision.
  var fbWrap = el("div"); fbWrap.hidden = true;
  var fb = el("textarea"); fb.rows = 2;
  fb.placeholder = "What still needs to change? This loops the mission back to Align.";
  fbWrap.appendChild(field("Feedback for send-back", fb));
  m.body.appendChild(fbWrap);

  var sendBack = applyWriteState(btn("↩ Send Back…", "danger", function () {
    if (fbWrap.hidden) { fbWrap.hidden = false; fb.focus(); return; }
    var note = fb.value.trim();
    if (!note) { showErr(err, "Send-back needs a feedback note."); return; }
    sendBack.disabled = true;
    postWrite("/api/mission/" + enc(mi.id) + "/verify",
      { decision: "send-back", feedback: note },
      function () { closeOverlay(); },
      function (msg) { sendBack.disabled = false; showErr(err, msg); });
  }));
  var accept = applyWriteState(btn("✓ Accept the Fixes", "go big", function () {
    accept.disabled = true; accept.textContent = "Accepting…";
    // the re-verify gate is answered via /respond; an explicit accept note is
    // recorded against the gate. Friendly, never CLI.
    postWrite("/api/mission/" + enc(mi.id) + "/respond",
      { answer: "Accepted — the logged-bug fixes look good; fold them to Done." },
      function () { closeOverlay(); },
      function (msg) {
        accept.disabled = false; accept.textContent = "✓ Accept the Fixes";
        showErr(err, msg);
      });
  }));
  m.foot.appendChild(sendBack);
  m.foot.appendChild(accept);
  showOverlay(m.wrap);
}

/* ════════════════ SCREEN: VERIFY (#verify) ════════════════ */
function openVerify(id) {
  fetchMission(id, function (mi) {
    var m = modal("✓ Verify Mission " + idLabel(mi), { wide: true, headClass: "teal" });

    var h = el("h4"); h.style.marginBottom = "8px";
    h.appendChild(document.createTextNode("Acceptance criteria "));
    var hint = el("span", "dim");
    hint.style.cssText = "font-family:var(--font-body);text-transform:none;letter-spacing:0;font-size:11px";
    hint.textContent = "— click any row to toggle";
    h.appendChild(hint);
    m.body.appendChild(h);
    m.body.appendChild(criteriaChecklist(mi));

    if (mi.tickets && mi.tickets.length) {
      var bh = el("h4"); bh.style.margin = "16px 0 8px";
      bh.textContent = "What was built — " + mi.tickets.length + " tickets";
      m.body.appendChild(bh);
      m.body.appendChild(buildSummary(mi));
    }

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    // Send-back reveals a feedback field, then dispatches the OTHER decision.
    var fbWrap = el("div"); fbWrap.hidden = true;
    var fb = el("textarea"); fb.rows = 2;
    fb.placeholder = "What needs to change? This loops the mission back to Align.";
    fbWrap.appendChild(field("Feedback for send-back", fb));
    m.body.appendChild(fbWrap);

    var sendBack = applyWriteState(btn("↩ Send Back…", "danger", function () {
      if (fbWrap.hidden) { fbWrap.hidden = false; fb.focus(); return; }
      var note = fb.value.trim();
      if (!note) { showErr(err, "Send-back needs a feedback note."); return; }
      sendBack.disabled = true;
      postWrite("/api/mission/" + enc(id) + "/verify",
        { decision: "send-back", feedback: note },
        function () { closeOverlay(); },
        function (msg) { sendBack.disabled = false; showErr(err, msg); });
    }));
    var approve = applyWriteState(btn("✓ Approve & Open PR", "go big", function () {
      approve.disabled = true; approve.textContent = "Opening PR…";
      postWrite("/api/mission/" + enc(id) + "/verify", { decision: "approve" },
        function () { closeOverlay(); },
        function (msg) { approve.disabled = false; approve.textContent = "✓ Approve & Open PR"; showErr(err, msg); });
    }));
    m.foot.appendChild(sendBack);
    m.foot.appendChild(approve);
    showOverlay(m.wrap);
  });
}

/* ════════════════ SCREEN: MISSION LOG (#log) ════════════════ */
function openLog(id) {
  fetchMission(id, function (mi) {
    var m = modal("⌖ Mission Log — against " + idLabel(mi), { wide: true, headClass: "pink" });

    var report = el("textarea"); report.rows = 3;
    report.placeholder = "Describe the bug(s) — one or many; we’ll split them.";
    m.body.appendChild(field("What went wrong? (one or many — we’ll split them)", report));

    var preview = el("div");
    m.body.appendChild(preview);

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    // UX-25: both the Preview and the File & Run Fixes actions dispatch a worker
    // turn (~25s on copilot) with no feedback. Show the shared LCARS working
    // animation inline while each POST is in flight; it clears on response AND
    // error. One node, label re-set per action.
    var busy = workingNode("Working…"); busy.hidden = true;
    m.body.appendChild(busy);

    // holds the AUTHORED bug PRDs from the last preview, passed to File & Run.
    var authored = { prds: null };

    m.foot.appendChild(btn("Cancel", null, closeOverlay));
    var prev = applyWriteState(btn("Preview", null, function () {
      prev.disabled = true; prev.textContent = "Splitting…";
      err.hidden = true;
      // UX-25: themed working copy for the split worker turn.
      busy.querySelector(".lcars-working-label").textContent =
        "Splitting the report into bugs…";
      busy.hidden = false;
      // free-form text → AUTHORING preview; empty → read-only linked children.
      postWrite("/api/mission/" + enc(id) + "/log", { text: report.value.trim() },
        function (state) {
          busy.hidden = true;
          prev.disabled = false; prev.textContent = "Preview";
          authored.prds = state && state.authored
            ? (state.children || []).map(function (c) { return c.prd; })
            : null;
          renderLogPreview(preview, state, idLabel(mi));
        },
        function (msg) {
          busy.hidden = true;
          prev.disabled = false; prev.textContent = "Preview"; showErr(err, msg);
        });
    }));
    var run = applyWriteState(btn("File & Run Fixes ▸", "warn big", function () {
      run.disabled = true; run.textContent = "Filing…";
      err.hidden = true;
      // UX-25: themed working copy for the file + dispatch worker turn.
      busy.querySelector(".lcars-working-label").textContent =
        "Filing & dispatching fixes…";
      busy.hidden = false;
      // pass the authored PRDs so log.sh files one bug mission per PRD, then
      // resolve-logs drives them to the single re-verify gate.
      // UX-27: close the dialog on success (optimistic — the board/SSE shows the
      // new child cards); clears the working state with it.
      postWrite("/api/mission/" + enc(id) + "/log/run", { prds: authored.prds || [] },
        function () { busy.hidden = true; closeOverlay(); },
        function (msg) {
          busy.hidden = true;
          run.disabled = false; run.textContent = "File & Run Fixes ▸";
          showErr(err, msg);
        });
    }));
    m.foot.appendChild(prev);
    m.foot.appendChild(run);
    showOverlay(m.wrap);
    report.focus();
  });
}

function renderLogPreview(host, state, parentLabel) {
  host.innerHTML = "";
  var children = (state && state.children) || [];
  var authoredNew = state && state.authored;
  var h = el("h4"); h.style.margin = "4px 0 8px";
  h.textContent = "Preview — " + ((state && state.count) || children.length) +
    " bug mission" + (children.length === 1 ? "" : "s") +
    (authoredNew ? " detected" : " linked");
  host.appendChild(h);
  if (!children.length) {
    host.appendChild(noteEl(
      authoredNew
        ? "The report didn't split into any distinct bugs — refine it and " +
          "preview again."
        : "No bug missions are linked to this parent yet. Describe the bug(s) " +
          "above and Preview to split them into child missions."));
    return;
  }
  // UX-26: the previewed child-bug cards rendered flush (zero gap) and would
  // overflow with many bugs. Render them into a dedicated list that gaps the
  // items vertically and caps its height with overflow-y:auto so a long split
  // scrolls in place rather than pushing the modal footer off-screen.
  var list = el("div", "log-preview-list");
  children.forEach(function (c) {
    var card = el("div", "card child"); card.style.cursor = "default";
    card.appendChild(el("div", "no", "↳ child of " +
      (parentLabel || state.parent || "parent")));
    card.appendChild(el("div", "ttl", "Bug · " + (c.title || c.id)));
    var pills = el("div", "pills");
    // authored-but-not-yet-filed bugs show their planned stage; linked ones
    // show their live stage label.
    pills.appendChild(el("span", "pill", "lcars:" + (c.stage || "plan")));
    card.appendChild(pills);
    list.appendChild(card);
  });
  host.appendChild(list);
}

/* ════════════════ SCREEN: MISSION DETAIL (#detail) — two-pane ════════════════ */
function openDetail(id) {
  fetchMission(id, function (mi) { renderDetail(mi); });
}

function renderDetail(mi) {
  // UX-32: clear any prior live-tick timers before rebuilding the detail so a
  // re-render (or re-open) never stacks intervals.
  clearDetailTimers();
  var grid = el("div", "detail-grid");

  // ── header: tag, title, pills, stage pill, header actions ──
  var head = el("div", "det-head");
  var row1 = el("div", "row1");
  if (mi.issue) row1.appendChild(el("span", "tag", "#" + mi.issue));
  row1.appendChild(el("h3", null, mi.title || mi.id));
  // UX-28: mirror the board card's logged-bug indication in the detail header —
  // the "log bug · child of #<parent>" badge (links to the parent when known).
  if (isLogBug(mi)) row1.appendChild(logBugBadge(mi));
  addPills(row1, mi.pills);
  row1.appendChild(el("span", "pill stage", (mi.stage || "").toUpperCase()));

  // Header actions MIRROR the board card's stage logic (cardControls) — the card
  // is the source of truth (item 1). The primary action (Answer / Pause / Resume
  // / Start / Verify) is gated by stage exactly as the card gates it; Verify is
  // shown ONLY at the verify stage (hidden, not disabled, elsewhere). Mission Log
  // stays available throughout. Done missions carry no primary action.
  var actions = el("div", "det-actions");
  // UX-14: "View on GitHub" link — opens the mission issue in a new tab. Needs
  // both meta.repo and mission.issue; hides gracefully if either is missing.
  var ghRepo = mi.repo || (mi.meta && mi.meta.repo) || detailRepo;
  if (ghRepo && mi.issue) {
    var gh = el("a", "btn", "↗ View on GitHub");
    gh.href = "https://github.com/" + ghRepo + "/issues/" + mi.issue;
    gh.target = "_blank"; gh.rel = "noopener";
    gh.addEventListener("click", function (e) { e.stopPropagation(); });
    actions.appendChild(gh);
  }
  var mrs = runState(mi); // mirror the card's derived lifecycle (UX-17/20/21).
  if (mi.awaiting) {
    actions.appendChild(applyWriteState(btn("Answer ▸", "danger", function () { openRespond(mi.id); })));
  } else if (mi.stage === "verify") {
    actions.appendChild(applyWriteState(btn("✓ Verify", "go", function () { openVerify(mi.id); })));
  } else if (mi.stage === "done") {
    /* terminal — no primary action */
  } else if (mrs === "paused") {
    actions.appendChild(applyWriteState(btn("▶ Resume", "go", function () {
      dispatchCard("/api/mission/" + enc(mi.id) + "/resume", {}); closeOverlay();
    })));
  } else if (mrs === "pausing") {
    // UX-21: pause requested, driver still settling — disabled "Pausing…".
    var dpausing = btn("◐ Pausing…", "warn", null);
    dpausing.disabled = true;
    dpausing.title = "Pause requested — stopping at the next safe boundary.";
    actions.appendChild(dpausing);
  } else if (mrs === "running" || isRunningStage(mi.stage)) {
    // UX-13: mirror the card — a live drive overrides Start → Pause so Start
    // can't be double-fired from the detail header either. UX-17: while
    // optimistically starting the Pause stays disabled until running flips true.
    var dpause = applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCard("/api/mission/" + enc(mi.id) + "/pause", {}); closeOverlay();
    }));
    if (!mi.running && isStarting(mi.id)) {
      dpause.disabled = true; dpause.title = "Engaging the driver…";
    }
    actions.appendChild(dpause);
  } else {
    // align (and any pre-run stage): Start launches the run via the Launch panel.
    actions.appendChild(applyWriteState(btn("▶ Start", "go", function () { openLaunch(mi.id); })));
  }
  // Mission Log is available at every stage (not on terminal Done missions).
  if (mi.stage !== "done") {
    actions.appendChild(applyWriteState(btn("Mission Log", null, function () { openLog(mi.id); })));
  }
  row1.appendChild(actions);
  head.appendChild(row1);

  // UX-31: a STAGE-INDEPENDENT active-time readout in the detail header, so the
  // total stays visible at Verify and Done (where there is no in-flight block).
  // It live-ticks while running (UX-32) and freezes otherwise. Hidden pre-run
  // (activeRuntimeNode returns null for 0s when not running).
  var headRuntime = activeRuntimeNode(mi);
  if (headRuntime) {
    headRuntime.className += " det-runtime";
    head.appendChild(headRuntime);
  }
  grid.appendChild(head);

  // ── body: LEFT feed, RIGHT tabs ──
  var body = el("div", "det-body");
  body.appendChild(activityFeed(mi));
  body.appendChild(detailTabs(mi));
  grid.appendChild(body);

  // Explicit close affordance. It lives in its OWN flow slot at the very end of
  // the header row (after the actions) so it can never overlap the action
  // buttons at any width (item 6); .detail-close styling pins it to the header's
  // top-right with reserved gutter so the title/pills don't run under it.
  var close = btn("✕", "detail-close", closeOverlay);
  close.className = "detail-close";
  head.appendChild(close);

  showOverlay(grid);
}

function activityFeed(mi) {
  var feed = el("div", "feed");
  var acts = mi.activity || [];
  var inFlight = isInFlight(mi); // UX-20: only when running && !paused.
  var rs = runState(mi);

  // UX-18: the CURRENT stage is the latest stage_start with no matching
  // stage_done in the feed (not the first/Align entry). Fall back to mi.stage.
  var activeStage = currentStage(acts) || mi.stage;

  // ── UX-19: a dedicated CURRENT / IN-FLIGHT block, visually separated from the
  // chronological history below. Shows the current stage + live pulse (UX-13)
  // + activeSeconds (UX-24) when in flight; a quiet "paused at <stage>" header
  // when paused/pausing (UX-20: no motion). ──
  if (inFlight) {
    var cur = el("div", "feed-current");
    cur.appendChild(el("h4", null, "Current — In Flight"));
    var live = el("div", "evt s-" + normStage(activeStage) + " evt-live");
    live.appendChild(el("div", "marker"));
    var lec = el("div", "ec");
    lec.appendChild(el("div", "when",
      (activeStage || "").toUpperCase() + " · IN FLIGHT"));
    lec.appendChild(runningPulse(stageLabel(activeStage)));
    var rt = activeRuntimeNode(mi); // UX-24
    if (rt) lec.appendChild(rt);
    live.appendChild(lec);
    cur.appendChild(live);
    feed.appendChild(cur);
  } else if (rs === "pausing" || rs === "paused") {
    // UX-20: paused/pausing shows the paused state ONLY — no running pulse, no
    // "in flight" copy.
    var pc = el("div", "feed-current");
    pc.appendChild(el("h4", null, "Current"));
    var pe = el("div", "evt s-" + normStage(activeStage) + " evt-paused");
    pe.appendChild(el("div", "marker"));
    var pec = el("div", "ec");
    var label = rs === "pausing"
      ? "PAUSING — stopping at the next safe boundary"
      : "PAUSED at " + (activeStage || "").toUpperCase();
    pec.appendChild(el("div", "when", label));
    var rtp = activeRuntimeNode(mi); // UX-24: keep the active-time readout.
    if (rtp) pec.appendChild(rtp);
    pe.appendChild(pec);
    pc.appendChild(pe);
    feed.appendChild(pc);
  }

  // ── history timeline ──
  var hist = el("div", "feed-history");
  hist.appendChild(el("h4", null, "Live Activity — Harness ▸ Issue Comments"));
  if (!acts.length) {
    if (!inFlight && rs !== "pausing" && rs !== "paused") {
      hist.appendChild(el("div", "empty", "No activity yet — the harness posts here as the mission advances."));
    }
    feed.appendChild(hist);
    return feed;
  }
  acts.forEach(function (ev) {
    var stage = normStage(ev.stage);
    var isGate = ev.type === "gate";
    var e = el("div", "evt s-" + (isGate ? "gate" : stage));
    e.appendChild(el("div", "marker"));
    var ec = el("div", "ec");
    var when = ev.ts != null ? fmtTs(ev.ts) + " · " : "";
    ec.appendChild(el("div", "when", when + (ev.stage || "").toUpperCase()));
    ec.appendChild(el("div", "head", headlineFor(ev)));
    // UX-33: sanitize gate/feed prose so a backtick `lcars …` CLI command is
    // never shown verbatim in the GUI feed.
    if (ev.detail || ev.text) {
      ec.appendChild(el("div", "txt", sanitizeGateText(ev.text || ev.detail)));
    }
    ec.appendChild(el("div", "bot", "⬡ posted by lcars-bot"));
    e.appendChild(ec);
    hist.appendChild(e);
  });
  feed.appendChild(hist);
  return feed;
}

/* UX-18: the current/active stage = the latest stage_start event with no later
   matching stage_done for the same stage. Walks the feed (chronological order
   per the shape) and tracks which stages have completed. Returns null when no
   open stage_start exists (then the caller falls back to mi.stage). */
function currentStage(acts) {
  if (!acts || !acts.length) return null;
  var openStart = null;
  acts.forEach(function (ev) {
    var stage = normStage(ev.stage);
    if (ev.type === "stage_start") {
      openStart = stage; // a newer start supersedes an earlier open one.
    } else if (ev.type === "stage_done") {
      if (openStart === stage) openStart = null; // closed.
    }
  });
  return openStart;
}

/* UX-24/UX-32: a human-readable active-runtime readout — mission.activeSeconds
   is the run time EXCLUDING human-wait/paused. Hidden when absent/0 (pre-run).
   The label makes the exclusion explicit.

   UX-32 (captain-approved live tick): when the mission is RUNNING the displayed
   value ticks every 1s from `activeSeconds` + a client anchor, so it no longer
   "jumps" only on a board event; each board refresh re-creates this node and so
   SNAPS/reconciles to the authoritative server value (the snap is EXPECTED). The
   tick is FROZEN when not running (paused/awaiting/queued/verify/done) — it shows
   the frozen total. The interval is registered in DETAIL_TIMERS and cleared when
   the detail closes (no leaked timers). `opts.compact` renders the inline
   feed-block variant (no hint sub-line). */
var DETAIL_TIMERS = [];
function clearDetailTimers() {
  DETAIL_TIMERS.forEach(function (t) { clearInterval(t); });
  DETAIL_TIMERS = [];
}
function activeRuntimeNode(mi, opts) {
  opts = opts || {};
  var base = mi && typeof mi.activeSeconds === "number" ? mi.activeSeconds : 0;
  if (!base || base <= 0) {
    // UX-32: a running mission that has just started may report 0 server-side
    // for a beat — still show a live-ticking "Active 0s" so the readout never
    // disappears mid-run. Non-running with 0 stays hidden (pre-run).
    if (!isInFlight(mi)) return null;
    base = 0;
  }
  var node = el("div", "active-runtime");
  node.title = "active runtime — excludes time awaiting you";
  var val = el("span", "ar-val", "Active " + fmtDuration(base));
  node.appendChild(val);
  if (!opts.compact) {
    node.appendChild(el("span", "ar-hint", "excludes time awaiting you"));
  }
  // UX-32: live tick only while running. Anchor to the wall clock at render time
  // so each second adds to the authoritative server base; the next board refresh
  // rebuilds this node (snap to server). Frozen (no interval) when not running.
  if (isInFlight(mi)) {
    var anchor = Date.now();
    var timer = setInterval(function () {
      if (!document.body.contains(val)) { clearInterval(timer); return; }
      var elapsed = Math.floor((Date.now() - anchor) / 1000);
      val.textContent = "Active " + fmtDuration(base + elapsed);
    }, 1000);
    DETAIL_TIMERS.push(timer);
  }
  return node;
}

/* Human-readable seconds → "Xh Ym Zs" / "Ym Zs" / "Zs" (drops leading zeros). */
function fmtDuration(secs) {
  secs = Math.max(0, Math.floor(secs));
  var h = Math.floor(secs / 3600);
  var m = Math.floor((secs % 3600) / 60);
  var s = secs % 60;
  var out = [];
  if (h) out.push(h + "h");
  if (h || m) out.push(m + "m");
  out.push(s + "s");
  return out.join(" ");
}

var EVENT_HEADS = {
  stage_start: "Stage started", stage_done: "Stage complete",
  wave_start: "Wave started", ticket_start: "Ticket started",
  ticket_attempt: "Ticket attempt", ticket_green: "Ticket green",
  ticket_flagged: "Ticket flagged", gate: "Gate raised", error: "Error",
};
function headlineFor(ev) {
  return EVENT_HEADS[ev.type] || (ev.type || "Event").replace(/_/g, " ");
}

function detailTabs(mi) {
  var tabs = el("div", "tabs");
  var bar = el("div", "tabbar");
  var paneHost = el("div");

  var defs = [
    ["prd", "PRD", prdPane(mi)],
    ["adr", "ADRs", adrPane(mi)],
    ["tk", "Tickets · Waves", ticketsPane(mi)],
  ];
  defs.forEach(function (d, idx) {
    var key = d[0], name = d[1], pane = d[2];
    var tab = el("span", "tab" + (idx === 0 ? " on" : ""), name);
    tab.setAttribute("data-tab", key);
    pane.classList.add("tabpane");
    pane.setAttribute("data-pane", key);
    if (idx === 0) pane.classList.add("on");
    tab.addEventListener("click", function () {
      bar.querySelectorAll(".tab").forEach(function (t) { t.classList.remove("on"); });
      paneHost.querySelectorAll(".tabpane").forEach(function (p) { p.classList.remove("on"); });
      tab.classList.add("on");
      pane.classList.add("on");
    });
    bar.appendChild(tab);
    paneHost.appendChild(pane);
  });
  tabs.appendChild(bar);
  tabs.appendChild(paneHost);
  return tabs;
}

function prdPane(mi) {
  var pane = el("div");
  var label = el("p"); label.style.fontSize = "13px";
  var b = el("b"); b.style.color = "var(--lcars-amber)"; b.textContent = "Acceptance criteria";
  label.appendChild(b);
  pane.appendChild(label);
  pane.appendChild(criteriaChecklist(mi));
  return pane;
}

function adrPane(mi) {
  var pane = el("div");
  // S70-B2: render the mission's engineering ADRs when present (.adr style).
  var adrs = mi.adrs || [];
  if (!adrs.length) {
    // UX-8: keep the first sentence; the old hosted-vs-local claim was
    // misleading (ADRs DO appear in the issue when present), so replace it with
    // the actual reason an ADR is or isn't recorded.
    pane.appendChild(noteEl("No engineering ADRs are recorded for this mission " +
      "— trivial work carries none. ADRs are only recorded for complex work " +
      "involving a real design decision."));
    return pane;
  }
  adrs.forEach(function (a) {
    var adr = el("div", "adr");
    if (a.title) adr.appendChild(el("b", null, a.title));
    if (a.body) {
      var body = el("div");
      body.style.cssText = "white-space:pre-wrap;margin-top:4px;font-size:12px";
      body.textContent = a.body;
      adr.appendChild(body);
    }
    pane.appendChild(adr);
  });
  return pane;
}

function ticketsPane(mi) {
  var pane = el("div");
  var tickets = mi.tickets || [];
  if (!tickets.length) {
    pane.appendChild(noteEl("No nested tickets — a single-ticket mission reuses " +
      "the mission's own issue, so no sub-issue rows are shown."));
    return pane;
  }
  pane.appendChild(buildSummary(mi));
  return pane;
}

/* Human-clickable acceptance-criteria checklist. Clicking a row toggles its
   `.pending` class and the `.mk` glyph (✓/○) client-side. Criteria text is not
   in the board shape, so we derive rows from the ticket titles (each ticket is a
   vertical slice ≈ an acceptance criterion); if none, a single placeholder. */
function criteriaChecklist(mi) {
  var host = el("div");
  var rows = [];
  // S70-B3: prefer the verbatim acceptance criteria parsed from prd.md; fall
  // back to the ticket-derived rows (then a single placeholder) when absent.
  if (mi.criteria && mi.criteria.length) {
    mi.criteria.forEach(function (c) {
      rows.push({ text: c.text, done: !!c.done });
    });
  } else {
    (mi.tickets || []).forEach(function (t) {
      rows.push({ text: t.title || t.id, done: t.state === "done" });
    });
  }
  if (!rows.length) {
    rows.push({ text: "The behaviour described in the PRD works end to end", done: false });
  }
  rows.forEach(function (r) {
    var row = el("div", "check" + (r.done ? "" : " pending"));
    var mk = el("span", "mk", r.done ? "✓" : "○");
    row.appendChild(mk);
    row.appendChild(el("span", null, r.text));
    row.addEventListener("click", function () {
      var pending = row.classList.toggle("pending");
      mk.textContent = pending ? "○" : "✓";
    });
    host.appendChild(row);
  });
  return host;
}

function buildSummary(mi) {
  // group tickets into a per-wave-ish summary. Without wave grouping in the card
  // shape we render one row per ticket with its state pill.
  var host = el("div");
  (mi.tickets || []).forEach(function (t) {
    var row = el("div", "crit");
    var cls = t.state === "done" ? "go" : t.state === "flagged" ? "high" : "med";
    var pill = el("span", "pill " + cls, t.state === "done" ? "✓" : (t.id || ""));
    pill.style.fontSize = "10px";
    row.appendChild(pill);
    row.appendChild(document.createTextNode(" " + (t.title || t.id)));
    host.appendChild(row);
  });
  return host;
}

/* S70-B1: the per-stage model-mix table (mock .mix / .tier.opus / .tier.sonnet).
   modelMix = [{stage, tier, why}]; `why` (the estimator rationale) is shown once
   below the table when present. */
function modelMixTable(mix) {
  var wrap = el("div");
  var table = el("table", "mix");
  var thead = el("thead");
  var hrow = el("tr");
  hrow.appendChild(el("th", null, "Stage"));
  hrow.appendChild(el("th", null, "Model"));
  thead.appendChild(hrow);
  table.appendChild(thead);
  var tbody = el("tbody");
  var why = null;
  mix.forEach(function (r) {
    var tr = el("tr");
    tr.appendChild(el("td", null, r.stage || ""));
    var td = el("td");
    var tierCls = (r.tier === "opus") ? "opus" : (r.tier === "sonnet") ? "sonnet" : "";
    td.appendChild(el("span", "tier" + (tierCls ? " " + tierCls : ""),
      (r.tier || "").toUpperCase()));
    tr.appendChild(td);
    tbody.appendChild(tr);
    if (!why && r.why) why = r.why;
  });
  table.appendChild(tbody);
  wrap.appendChild(table);
  if (why) {
    var note = noteEl(why, "amber");
    note.style.fontSize = "13px";
    wrap.appendChild(note);
  }
  return wrap;
}

/* ════════════════ small helpers ════════════════ */
function field(labelText, control) {
  var f = el("div", "field");
  f.appendChild(label(labelText));
  f.appendChild(control);
  return f;
}
function label(t) { return el("label", null, t); }
function noteEl(text, cls) { return el("div", "note" + (cls ? " " + cls : ""), text); }
function showErr(node, msg) { node.hidden = false; node.textContent = msg; }

/* UX-2 / UX-5: a self-contained, on-theme LCARS "working" indicator for the
   several-second worker-backed waits (Align open, each Align answer, the
   Align→file hand-off). Vanilla CSS animation only (.lcars-working / .lcars-bars
   in board.css) — an animated row of amber/teal elbow bars plus a label.
   Accessible: the visible label carries the state (not colour alone) and the
   node is role=status / aria-live so assistive tech announces it. Caller owns
   show/hide — it clears on BOTH success and error by removing the node. */
function workingNode(labelText) {
  var w = el("div", "lcars-working");
  w.setAttribute("role", "status");
  w.setAttribute("aria-live", "polite");
  var bars = el("div", "lcars-bars");
  for (var i = 0; i < 5; i++) bars.appendChild(el("i"));
  w.appendChild(bars);
  w.appendChild(el("span", "lcars-working-label", labelText || "Working…"));
  return w;
}

/* UX-13: a compact "live drive" pulse for a running mission. It reuses the
   shared working-bars styling (.lcars-working / .lcars-bars) via workingNode,
   adding the .lcars-running modifier for the running tint, plus a stage-aware
   themed label so a silent stage still reads as in motion. role=status / aria-
   live carry the state to assistive tech (not colour alone). */
function runningPulse(label) {
  var w = workingNode(RUNNING_COPY[label] || ("Underway · " + (label || "running") + "…"));
  w.className += " lcars-running";
  return w;
}

/* Friendly Stage names for the running pulse copy lookup + fallback. */
function stageLabel(stage) {
  var s = normStage(stage);
  var map = {
    align: "Align", research: "Research", validate: "Validate", plan: "Plan",
    "plan-review": "Plan Review", schedule: "Schedule",
    implement: "Implement", verify: "Verify", done: "Done",
  };
  return map[s] || (stage || "running");
}

/* UX-7 / UX-13 — curated Star-Trek/LCARS-flavoured running copy per Stage. Each
   line hints at WHAT the harness is doing (headless turns don't stream sub-
   progress, so the copy is curated, not live). The visible label carries the
   state — colour is decoration only (accessible). */
var RUNNING_COPY = {
  "Research": "Sensors sweeping the codebase…",
  "Validate": "Cross-checking the away team's findings…",
  "Plan": "Plotting the course to engineering…",
  "Plan Review": "Bridge officers reviewing the flight plan…",
  "Schedule": "Sequencing the work into waves…",
  "Implement": "Engineering crew on the hull — building…",
  "Verify": "Running final diagnostics…",
  "Align": "Calibrating mission parameters…",
};

/* UX-10/UX-16: stamp the themed working animation onto a mission's board card by
   id (used when the originating modal has already closed — e.g. Start). The next
   board refresh re-renders the card (and, if running, its own pulse) so this is a
   transient affordance. No-op if the card isn't currently on screen. */
function showCardBusy(id, label) {
  var card = document.querySelector('.board .card[data-mid="' + cssEsc(id) + '"]');
  if (!card) return;
  var ctrl = card.querySelector(".card-ctrl");
  var busy = workingNode(label || "Engaging…");
  busy.className += " lcars-running";
  if (ctrl) { ctrl.innerHTML = ""; ctrl.appendChild(busy); }
  else card.appendChild(busy);
}

/* CSS attribute-selector escape for arbitrary mission ids (vanilla, no deps). */
function cssEsc(s) {
  if (window.CSS && CSS.escape) return CSS.escape(s);
  return String(s).replace(/["\\]/g, "\\$&");
}

/* A card-level dispatch that shows the LCARS working animation in `host` while
   the request is in flight (UX-10/UX-16), themed via `label`. Clears on the
   board refresh (success) or on error. Pause/resume return promptly. */
function dispatchCardBusy(id, path, payload, host, label) {
  var busy = workingNode(label || "Engaging…");
  busy.className += " lcars-running";
  if (host) { host.innerHTML = ""; host.appendChild(busy); }
  postWrite(path, payload, function () { /* board refresh re-renders the card */ },
    function (msg) { setStatus(msg); refresh(); });
}

function addPills(host, pills) {
  if (!pills) return;
  var c = pillNode(pills.cost, "cost"); if (c) host.appendChild(c);
  var r = pillNode(pills.reasoning); if (r) host.appendChild(r);
  var i = pillNode(pills.implementation); if (i) host.appendChild(i);
}

function idLabel(mi) {
  return (mi.issue ? "#" + mi.issue : mi.id) +
    (mi.title ? " — " + mi.title : "");
}

function normStage(stage) {
  var s = (stage || "").toLowerCase();
  if (s === "plan_review" || s === "planreview" || s === "review") return "plan-review";
  return s;
}

function fmtTs(ts) {
  // events.jsonl ts may be epoch seconds or an ISO string.
  var d;
  if (typeof ts === "number") {
    d = new Date(ts < 1e12 ? ts * 1000 : ts);
  } else {
    d = new Date(ts);
  }
  if (isNaN(d.getTime())) return String(ts);
  return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
}

function fetchMission(id, cb) {
  fetch("/api/mission/" + enc(id))
    .then(function (r) {
      if (r.status === 404) throw new Error("no such mission");
      return r.json();
    })
    .then(cb)
    .catch(function () { setStatus("mission unavailable"); });
}

/* ════════════════ live channel ════════════════ */
function connect() {
  var conn = document.getElementById("conn");
  try {
    var es = new EventSource("/api/events");
    es.addEventListener("update", function () { refresh(); });
    es.onopen = function () { conn.className = "conn"; conn.textContent = "● LIVE"; };
    es.onerror = function () {
      conn.className = "conn stale"; conn.textContent = "○ RECONNECTING";
    };
  } catch (e) {
    setInterval(refresh, 5000);
  }
}

/* UX-30: PADD rebrand. The header band reads "LCARS · KANBAN" in index.html;
   per the file constraint (board.js/board.css only) we rewrite the brand node
   here at boot to "PADD" with a smaller acronym sub-line below it —
   "Project Alignment & Deployment Display" with the FIRST LETTER of each word
   bolded so it spells out P·A·D·D. Keeps the LCARS "LCARS ·" prefix + tokens.
   Defensive: no-ops if the brand node is missing. */
function brandPADD() {
  var brand = document.querySelector(".topbar .brand");
  if (!brand) return;
  brand.innerHTML = "";
  brand.classList.add("brand-padd");
  // top line: keep the LCARS prefix, swap KANBAN → PADD (the bolded title).
  var line = el("div", "brand-line");
  line.appendChild(document.createTextNode("LCARS · "));
  line.appendChild(el("b", null, "PADD"));
  brand.appendChild(line);
  // sub-line: the expansion, each word's FIRST letter bolded → reads the acronym.
  var sub = el("div", "brand-sub");
  // [word, restOfWord] pairs; the leading letter is bolded.
  [["P", "roject"], ["A", "lignment"], ["D", "eployment"], ["D", "isplay"]]
    .forEach(function (w, idx) {
      if (idx === 2) sub.appendChild(document.createTextNode("& "));
      sub.appendChild(el("b", "acr", w[0]));
      sub.appendChild(document.createTextNode(w[1] + " "));
    });
  brand.appendChild(sub);
}

/* ════════════════ boot ════════════════ */
document.getElementById("fileBtn").addEventListener("click", openFile);
brandPADD();
refresh();
connect();
probeWrites();
