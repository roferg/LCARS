/* LCARS Kanban board — vanilla, dependency-free renderer (ADR-007).
 *
 * It depends ONLY on the adapter-neutral board shape from /api/board, never on
 * which adapter (local or github) served it (ADR-003). The live channel
 * (/api/events, SSE) pushes one update per state change; on each we re-fetch
 * and re-render. No framework, no build step.
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

function el(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
}

function levelClass(level) {
  return level === "low" ? "low" : level === "high" ? "high" : "med";
}

function pillNode(p, kind) {
  if (!p) return null;
  if (kind === "cost") return el("span", "pill cost", "⬡ " + (p.label || ""));
  return el("span", "pill " + levelClass(p.level), p.label || "");
}

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

  card.addEventListener("click", function () { openDrawer(m.id); });
  return card;
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

/* --- detail drawer (read-only) --- */
function openDrawer(id) {
  fetch("/api/mission/" + encodeURIComponent(id))
    .then(function (r) { return r.json(); })
    .then(function (m) {
      var body = document.getElementById("drawerBody");
      body.innerHTML = "";
      body.appendChild(el("h3", null,
        (m.issue ? "#" + m.issue + " · " : "") + (m.title || m.id)));
      var pills = el("div", "pills");
      if (m.pills) {
        [pillNode(m.pills.cost, "cost"), pillNode(m.pills.reasoning),
         pillNode(m.pills.implementation)].forEach(function (p) {
          if (p) pills.appendChild(p);
        });
      }
      pills.appendChild(el("span", "pill stage", (m.stage || "").toUpperCase()));
      body.appendChild(pills);
      body.appendChild(el("h3", null, "Live Activity"));
      (m.activity || []).forEach(function (ev) {
        var e = el("div", "evt");
        e.appendChild(el("span", "when", (ev.stage || "").toUpperCase()));
        e.appendChild(el("span", "txt", ev.text || ev.detail || ""));
        body.appendChild(e);
      });
      document.getElementById("drawer").hidden = false;
    });
}

function closeDrawer() {
  document.getElementById("drawer").hidden = true;
}

document.getElementById("drawerClose").addEventListener("click", closeDrawer);

// Clicking the dimmed backdrop (the .drawer itself, outside .drawer-inner) also
// dismisses the drawer; clicks that bubble up from inside .drawer-inner have a
// different target and are ignored.
document.getElementById("drawer").addEventListener("click", function (e) {
  if (e.target === this) closeDrawer();
});

/* --- live channel --- */
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
    // No SSE → fall back to polling.
    setInterval(refresh, 5000);
  }
}

refresh();
connect();
