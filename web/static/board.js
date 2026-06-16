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
  var card = el("div", "card");
  if (m.awaiting) card.className += " awaiting";
  if (m.paused) card.className += " paused";
  if (m.linked) card.className += " child";

  var issue = m.issue ? "#" + m.issue : "—";
  card.appendChild(el("div", "no", issue + " · lcars:" + m.stage));
  card.appendChild(el("div", "ttl", m.title || m.id));

  var pills = el("div", "pills");
  if (m.awaiting) {
    pills.appendChild(el("span", "pill await", "● AWAITING YOU"));
    if (m.pills && m.pills.cost) pills.appendChild(pillNode(m.pills.cost, "cost"));
  } else if (m.pills) {
    var c = pillNode(m.pills.cost, "cost"); if (c) pills.appendChild(c);
    var r = pillNode(m.pills.reasoning); if (r) pills.appendChild(r);
    var i = pillNode(m.pills.implementation); if (i) pills.appendChild(i);
  }
  card.appendChild(pills);

  if (m.paused) card.appendChild(el("div", "no", "⏸ paused"));

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
      var row = el("div", "tk " + (t.state || "pending"));
      row.appendChild(el("span", "dot"));
      var label = (t.id || "") + (t.title ? " · " + t.title : "");
      row.appendChild(document.createTextNode(label));
      tk.appendChild(row);
    });
    card.appendChild(tk);
  }

  // ── inline controls (mock #card .card-ctrl): stage-appropriate write actions
  card.appendChild(cardControls(m));

  card.addEventListener("click", function () { openDetail(m.id); });
  return card;
}

function cardControls(m) {
  var ctrl = el("div", "card-ctrl");
  if (m.awaiting) {
    ctrl.appendChild(applyWriteState(btn("Answer ▸", "danger", function () {
      openRespond(m.id);
    })));
    return ctrl;
  }
  if (m.stage === "verify") {
    ctrl.appendChild(applyWriteState(btn("✓ Verify ▸", "go", function () {
      openVerify(m.id);
    })));
  } else if (m.stage === "done") {
    ctrl.appendChild(btn("Open ▸", null, function () { openDetail(m.id); }));
    return ctrl;
  } else if (m.paused) {
    ctrl.appendChild(applyWriteState(btn("▶ Resume", "go", function () {
      dispatchCard("/api/mission/" + enc(m.id) + "/resume", {});
    })));
  } else if (isRunningStage(m.stage)) {
    ctrl.appendChild(applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCard("/api/mission/" + enc(m.id) + "/pause", {});
    })));
  } else {
    // align (and any pre-run stage): Start launches the run via the Launch panel
    ctrl.appendChild(applyWriteState(btn("▶ Start", "go", function () {
      openLaunch(m.id);
    })));
  }
  ctrl.appendChild(btn("Open ▸", null, function () { openDetail(m.id); }));
  return ctrl;
}

function isRunningStage(stage) {
  return ["research", "validate", "plan", "plan-review", "schedule", "implement"]
    .indexOf(stage) !== -1;
}

function render(board) {
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

  var repo = el("input"); repo.placeholder = "owner/repo (optional)";
  m.body.appendChild(field("Repository", repo));

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
  var go = applyWriteState(btn("File & Begin Alignment ▸", "go big", function () {
    var text = idea.value.trim();
    if (!text) { showErr(err, "Describe the idea first."); return; }
    go.disabled = true; go.textContent = "Filing…";
    postWrite("/api/mission",
      { idea: text, engine: chosen.engine, type: "feature" },
      function () { closeOverlay(); },
      function (msg) { go.disabled = false; go.textContent = "File & Begin Alignment ▸"; showErr(err, msg); });
  }));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  idea.focus();
}

/* ════════════════ SCREEN: LAUNCH / START (#launch) ════════════════ */
function openLaunch(id) {
  fetchMission(id, function (mi) {
    var m = modal("▶ Launch Mission " + idLabel(mi));
    // estimator readout: cost + two difficulty pills
    var pills = el("div", "pills"); pills.style.marginBottom = "16px";
    addPills(pills, mi.pills);
    m.body.appendChild(pills);

    // per-stage model mix — not in the board shape; render a graceful note.
    var mix = el("h4"); mix.textContent = "Per-stage model mix";
    mix.style.marginBottom = "6px";
    m.body.appendChild(mix);
    m.body.appendChild(noteEl(
      "The per-stage model mix is not exposed in the board shape — the cost and " +
      "difficulty pills above are the estimator readout. The override below is " +
      "applied in plain language at start.", "amber"));

    var ov = el("input");
    ov.placeholder = "e.g. “use Opus the whole way through” · “keep reasoning cheap”";
    m.body.appendChild(field("Override (plain language — optional)", ov));

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    m.foot.appendChild(btn("Cancel", null, closeOverlay));
    var go = applyWriteState(btn("▶ Start Run", "go big", function () {
      go.disabled = true; go.textContent = "Starting…";
      // start is synchronous to the run driver's next halt — show a working state.
      postWrite("/api/mission/" + enc(id) + "/start",
        { override: ov.value.trim() || undefined },
        function () { closeOverlay(); },
        function (msg) { go.disabled = false; go.textContent = "▶ Start Run"; showErr(err, msg); });
    }));
    m.foot.appendChild(go);
    showOverlay(m.wrap);
  });
}

/* ════════════════ SCREEN: RESPOND GATE (#respond) ════════════════ */
function openRespond(id) {
  fetchMission(id, function (mi) {
    var m = modal("● Awaiting You — Mission " + idLabel(mi) +
      " · " + (mi.stage || "").toUpperCase(), { wide: true, headClass: "red" });

    var q = el("div", "qtext"); q.style.fontSize = "18px";
    q.textContent = mi.question || "The harness needs your decision to proceed.";
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

    m.foot.appendChild(btn("Cancel", null, closeOverlay));
    var prev = applyWriteState(btn("Preview", null, function () {
      prev.disabled = true; prev.textContent = "Previewing…";
      postWrite("/api/mission/" + enc(id) + "/log", {},
        function (state) {
          prev.disabled = false; prev.textContent = "Preview";
          renderLogPreview(preview, state);
        },
        function (msg) { prev.disabled = false; prev.textContent = "Preview"; showErr(err, msg); });
    }));
    var run = applyWriteState(btn("File & Run Fixes ▸", "warn big", function () {
      run.disabled = true; run.textContent = "Running…";
      postWrite("/api/mission/" + enc(id) + "/log/run", {},
        function () { closeOverlay(); },
        function (msg) { run.disabled = false; run.textContent = "File & Run Fixes ▸"; showErr(err, msg); });
    }));
    m.foot.appendChild(prev);
    m.foot.appendChild(run);
    showOverlay(m.wrap);
  });
}

function renderLogPreview(host, state) {
  host.innerHTML = "";
  var children = (state && state.children) || [];
  var h = el("h4"); h.style.margin = "4px 0 8px";
  h.textContent = "Preview — " + ((state && state.count) || children.length) +
    " linked bug mission" + (children.length === 1 ? "" : "s");
  host.appendChild(h);
  if (!children.length) {
    host.appendChild(noteEl("No bug missions are linked to this parent yet. " +
      "Authoring new bugs from a free-form report is the interactive half of " +
      "Mission Log (deferred); run fixes drives whatever is already linked."));
    return;
  }
  children.forEach(function (c) {
    var card = el("div", "card child"); card.style.cursor = "default";
    card.appendChild(el("div", "no", "↳ child of " + (state.parent || "parent")));
    card.appendChild(el("div", "ttl", c.title || c.id));
    var pills = el("div", "pills");
    pills.appendChild(el("span", "pill", "lcars:" + (c.stage || "plan")));
    card.appendChild(pills);
    host.appendChild(card);
  });
}

/* ════════════════ SCREEN: MISSION DETAIL (#detail) — two-pane ════════════════ */
function openDetail(id) {
  fetchMission(id, function (mi) { renderDetail(mi); });
}

function renderDetail(mi) {
  var grid = el("div", "detail-grid");

  // ── header: tag, title, pills, stage pill, header actions ──
  var head = el("div", "det-head");
  var row1 = el("div", "row1");
  if (mi.issue) row1.appendChild(el("span", "tag", "#" + mi.issue));
  row1.appendChild(el("h3", null, mi.title || mi.id));
  addPills(row1, mi.pills);
  row1.appendChild(el("span", "pill stage", (mi.stage || "").toUpperCase()));

  var actions = el("div", "det-actions");
  if (mi.awaiting) {
    actions.appendChild(applyWriteState(btn("Answer ▸", "danger", function () { openRespond(mi.id); })));
  } else if (mi.paused) {
    actions.appendChild(applyWriteState(btn("▶ Resume", "go", function () {
      dispatchCard("/api/mission/" + enc(mi.id) + "/resume", {}); closeOverlay();
    })));
  } else if (isRunningStage(mi.stage)) {
    actions.appendChild(applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCard("/api/mission/" + enc(mi.id) + "/pause", {}); closeOverlay();
    })));
  } else if (mi.stage === "align") {
    actions.appendChild(applyWriteState(btn("▶ Start", "go", function () { openLaunch(mi.id); })));
  }
  actions.appendChild(applyWriteState(btn("Mission Log", null, function () { openLog(mi.id); })));
  actions.appendChild(applyWriteState(btn("✓ Verify", "go", function () { openVerify(mi.id); })));
  row1.appendChild(actions);
  head.appendChild(row1);
  grid.appendChild(head);

  // ── body: LEFT feed, RIGHT tabs ──
  var body = el("div", "det-body");
  body.appendChild(activityFeed(mi));
  body.appendChild(detailTabs(mi));
  grid.appendChild(body);

  // a close affordance: wrap with a thin header bar? The overlay backdrop + Esc
  // close it; add an explicit close button overlaid on the header for clarity.
  var close = btn("✕", "close", closeOverlay);
  close.className = "close";
  close.style.cssText = "position:absolute;top:14px;right:18px;background:transparent;" +
    "border:none;color:var(--lcars-text-dim);font-size:16px;cursor:pointer";
  head.style.position = "relative";
  head.appendChild(close);

  showOverlay(grid);
}

function activityFeed(mi) {
  var feed = el("div", "feed");
  var h = el("h4", null, "Live Activity — Harness ▸ Issue Comments");
  feed.appendChild(h);
  var acts = mi.activity || [];
  if (!acts.length) {
    feed.appendChild(el("div", "empty", "No activity yet — the harness posts here as the mission advances."));
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
    if (ev.detail || ev.text) ec.appendChild(el("div", "txt", ev.text || ev.detail));
    ec.appendChild(el("div", "bot", "⬡ posted by lcars-bot"));
    e.appendChild(ec);
    feed.appendChild(e);
  });
  return feed;
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
  // ADR detail is not in the board shape; show what we have gracefully.
  pane.appendChild(noteEl("Engineering ADRs are recorded in the mission's " +
    "validated plan — not exposed in the board shape. They appear on the GitHub " +
    "issue comments rendered in the activity feed."));
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
  (mi.tickets || []).forEach(function (t) {
    rows.push({ text: t.title || t.id, done: t.state === "done" });
  });
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

/* ════════════════ boot ════════════════ */
document.getElementById("fileBtn").addEventListener("click", openFile);
refresh();
connect();
probeWrites();
