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

// Version banner dismissal — session-only (in-memory, NOT persisted). Clicking the
// banner's ✕ hides it for the rest of this page's life; a refresh / relaunch of the
// viewscreen reloads board.js, resets this to false, and the banner returns.
var versionBannerDismissed = false;

// UX-14: the repo the board is attached to (board.meta.repo), captured on every
// render so the detail modal's "View on GitHub" link can build the issue URL
// even when the per-mission payload doesn't echo the repo. May stay null.
var detailRepo = null;

/* UX-28: a board-wide index of mission-id → its GitHub issue number, captured on
   every render. A logged bug carries `parentMission` (a mission id); to render
   the "child of #<parentIssue>" badge + GitHub link we resolve that id to its
   issue here. Falls back to the parent id when the issue isn't on the board. */
var ISSUE_BY_ID = Object.create(null);
/* BUG-035: a board-wide index of parent-mission-id → its linked bug CHILDREN
   (the active cards carrying parentMission == that id), captured on every render.
   A parent whose resolve-logs batch is in flight (children exist that are NOT all
   at verify) must lock its Verify actions; we derive that from this index. */
var CHILDREN_BY_PARENT = Object.create(null);
function indexIssues(board) {
  ISSUE_BY_ID = Object.create(null);
  CHILDREN_BY_PARENT = Object.create(null);
  (board.missions || []).forEach(function (m) {
    if (!m || m.id == null) return;
    ISSUE_BY_ID[String(m.id)] = m.issue || null;
    var pid = m.parentMission != null ? String(m.parentMission) : null;
    if (pid) {
      (CHILDREN_BY_PARENT[pid] || (CHILDREN_BY_PARENT[pid] = [])).push(m);
    }
  });
}

/* BUG-035: is a parent mission's logged-bug batch IN FLIGHT? True when it has
   linked, non-done bug children that are NOT all at the verify stage — i.e.
   resolve-logs is still driving them, before the consolidated re-verify gate is
   up. Re-enable (returns false) when none are in flight (no children) or every
   non-done child has reached verify (the consolidated gate is ready). Derived
   from the board index, so it is available wherever a card is rendered. */
function resolvingChildren(parentId) {
  if (parentId == null) return [];
  var kids = CHILDREN_BY_PARENT[String(parentId)] || [];
  return kids.filter(function (c) {
    return c && (c.stage || "").toLowerCase() !== "done";
  });
}
function isResolvingLocked(m) {
  if (!m || m.id == null) return false;
  var pending = resolvingChildren(m.id);
  if (!pending.length) return false;
  // locked while ANY non-done child has not yet reached verify (batch in flight).
  return pending.some(function (c) {
    return (c.stage || "").toLowerCase() !== "verify";
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
  // BUG-033: prefer the bug card's OWN carried parentIssue (from its
  // state.json) so the badge keeps "#<n>" even after the parent merges/goes Done
  // and drops off the active board (ISSUE_BY_ID only indexes active cards). Fall
  // back to ISSUE_BY_ID, then the raw parent mission id.
  var carried = (m && m.parentIssue != null && m.parentIssue !== "")
    ? m.parentIssue : null;
  var issue = carried != null ? carried : (pid ? (ISSUE_BY_ID[pid] || null) : null);
  if (!pid && issue == null) return { text: null, issue: null };
  return { text: issue != null ? "#" + issue : pid, issue: issue };
}

/* UX-17: optimistic "starting" set. After a captain clicks Start the driver
   takes ~2s to spawn → lock → flip mission.running true, during which a naive
   render would still show a clickable Start. We mark the mission id "starting"
   on click and treat it as running across every board refresh until the real
   mission.running becomes true (then clear) OR a safety timeout fires (~30s) so
   a failed start never wedges the card. Keyed by mission id → timeout handle. */
var STARTING = Object.create(null);
var STARTING_TIMEOUT_MS = 30000;

/* S110: instant client-side "launching" marker for the RUN affordance. Even with
   the server writing its `launching` record first (launch.sh), a card closed and
   reopened within the ~network-latency window before the POST lands could still
   read the pre-launch launch.json and flash a false ⚡ RUN. Keyed by mission id →
   true, set synchronously on the RUN click and cleared once the launch RESOLVES
   (running/failed/stopped) or the dispatch POST errors. Lives only for this page
   session (a refresh drops it — the server's launching record then covers the
   reopen case). */
var pendingLaunch = Object.create(null);

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

/* BUG-044: optimistic "merging" set. After BUG-040 made the Merge (approve)
   click fire-and-forget, the card keeps rendering the clickable "✓ Review PR ▸"
   for ~2-3s until the next refresh/SSE delivers the real reconcileStatus that
   flips it to the disabled "◐ Merge heal in progress…" (BUG-039). In that gap a
   second click fires ANOTHER approve → a concurrent reconcile/self-heal (wasted
   spend + worktree clash). We mark the mission id "merging" on click and treat
   it as actively healing across every board refresh until the real state arrives
   (reconcileStatus / awaiting / left verify — see clearMergingOnState) OR a
   safety timeout fires (~30s) so a failed dispatch never wedges the card.
   Keyed by mission id → timeout handle — mirrors the STARTING pattern (UX-17). */
var MERGING = Object.create(null);
var MERGING_TIMEOUT_MS = 30000;

function markMerging(id, fromStatus) {
  if (id == null) return;
  var key = String(id);
  if (MERGING[key]) clearTimeout(MERGING[key].t);
  // BUG-078: remember the reconcileStatus that was current at dispatch (the
  // "origin" gate the captain clicked from) so clearMergingOnState can tell a
  // STILL-same-state repaint (keep busy, sticky) from a real TERMINAL change
  // (clear). Keyed by id → { t: timeout handle, from: origin reconcileStatus }.
  MERGING[key] = {
    t: setTimeout(function () { clearMerging(key); refresh(); },
      MERGING_TIMEOUT_MS),
    from: fromStatus || null,
  };
}
function clearMerging(id) {
  if (id == null) return;
  var key = String(id);
  if (MERGING[key]) { clearTimeout(MERGING[key].t); delete MERGING[key]; }
}
function isMerging(id) {
  return id != null && !!MERGING[String(id)];
}
function mergingFrom(id) {
  var e = id != null && MERGING[String(id)];
  return e ? e.from : null;
}
/* BUG-078: the shared disabled busy affordance shown while an optimistic merge /
   reapprove / retry-merge is in flight — identical copy to verifyAffordance's
   "healing" kind, so the card reads the same whether the busy state is a live
   reconcile or an optimistic post-click one. */
function mergeBusyBtn() {
  var b = btn("◐ Merge heal in progress…", "warn", null);
  b.disabled = true;
  b.title = "Self-healing the merge against main — Merge is unavailable until "
    + "it settles.";
  return b;
}
/* BUG-044: drop the optimistic merging flag once the REAL state arrives — the
   reconcile started (reconcileStatus truthy), it escalated to a human gate
   (awaiting), or the mission left verify / went done. Mirrors how STARTING is
   cleared in runState once m.running flips true. Call from cardControls render. */
function clearMergingOnState(m) {
  if (!m || m.id == null || !isMerging(m.id)) return;
  // BUG-067: the reapprove gate ITSELF carries reconcileStatus==awaiting-reapprove
  // (a truthy reconcileStatus) at click time, so we must NOT clear the optimistic
  // merging flag merely because reconcileStatus is set — that would re-arm the
  // Reapprove button before the merge even ran. Clear only once the state has
  // genuinely MOVED past the merge: the mission left verify (→ done), a fresh
  // in-flight heal sub-state began (merging/retesting/resolving/healing), it
  // escalated to a design call, or the merge surfaced as failed.
  // BUG-078: clear only on a TERMINAL change away from the gate the captain
  // clicked. The mission left verify (→ done) is always terminal. Otherwise the
  // served reconcileStatus must have genuinely CHANGED from the origin gate — a
  // repaint that still shows the SAME state (e.g. still awaiting-reapprove while
  // the merge runs, or still merge-failed mid retry) keeps the busy flag sticky,
  // so the button never reverts mid-flight. A fresh in-flight heal sub-state or
  // an escalation is also terminal for the optimistic flag.
  var rs = m.reconcileStatus;
  var from = mergingFrom(m.id);
  var moved = (m.stage || "").toLowerCase() !== "verify"
    || rs === "merging" || rs === "retesting" || rs === "resolving"
    || rs === "healing" || rs === "escalated"
    || (rs === "merge-failed" && from !== "merge-failed")
    || (rs === "awaiting-reapprove" && from && from !== "awaiting-reapprove");
  if (moved) clearMerging(m.id);
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

/* A small, semi-transparent mark of the CLI driving this mission, sat in the
   card's top-right corner so the engine reads at a glance. Driven purely by
   m.engine (state.json.workerBin, surfaced on the board shape by S78) — so it
   covers logged-bug child cards too (a bug inherits its parent's engine). It is
   DECORATIVE: aria-hidden + pointer-events:none so it never intercepts the
   card's click-to-open. Returns null when the engine is unknown (no badge). */
var ENGINE_SVG = {
  // Official single-colour marks (Simple Icons, CC0): GitHub Copilot + Claude.
  // One <path> each, coloured by `currentColor` (set per engine in CSS); the
  // 0 0 24 24 viewBox matches the badge box. Nominative use only — a private
  // dashboard tagging which CLI drives a mission.
  copilot: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z"/></svg>',
  claude: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z"/></svg>'
};
function engineBadge(m) {
  var eng = String(m.engine || "").toLowerCase();
  var kind = eng.indexOf("copilot") >= 0 ? "copilot"
           : eng.indexOf("claude") >= 0 ? "claude" : "";
  if (!kind) return null;
  var b = el("div", "engine-badge engine-" + kind);
  b.setAttribute("aria-hidden", "true");
  b.title = kind === "copilot" ? "Copilot" : "Claude";
  b.innerHTML = ENGINE_SVG[kind];
  return b;
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
  // S113: the ACTUAL usage pill (display-only). Filled hexagon ⬢ vs the
  // estimate's outline ⬡ so EST and ACTUAL read apart at a glance; a `partial`
  // marker rides both the label ("· partial") and a class for honest styling.
  if (kind === "actual") {
    return el("span", "pill actual" + (p.partial ? " partial" : ""),
      "⬢ ACTUAL " + (p.label || ""));
  }
  return el("span", "pill " + levelClass(p.level), p.label || "");
}

/* S113: the "EST ⬡ $a–$b → ⬢ ACTUAL $c" comparison line for the Verify surfaces
   (openVerify + openReverifyGate). Reads the estimate cost pill (mi.pills.cost)
   and the ACTUAL usage pill (mi.pills.actual, present ONLY for a verify/done
   mission with usage). Returns null when there is no actual to compare (no
   usage → the dialog renders byte-identically to before this round). */
function costCompareLine(mi) {
  if (!mi.pills || !mi.pills.actual) return null;
  var row = el("div", "cost-compare");
  row.style.cssText =
    "margin:14px 0;display:flex;gap:8px;align-items:center;flex-wrap:wrap";
  var cap = el("span", "dim"); cap.textContent = "EST";
  row.appendChild(cap);
  var est = pillNode(mi.pills.cost, "cost");
  if (est) { row.appendChild(est); }
  else { var dash = el("span", "dim"); dash.textContent = "—"; row.appendChild(dash); }
  row.appendChild(document.createTextNode("→"));
  row.appendChild(pillNode(mi.pills.actual, "actual"));
  return row;
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

  // Engine watermark (Copilot / Claude) in the top-right corner. Decorative,
  // semi-transparent; null when the engine is unknown.
  var badge = engineBadge(m);
  if (badge) card.appendChild(badge);

  var issue = m.issue ? "#" + m.issue : "—";
  card.appendChild(el("div", "no", issue + " · lcars:" + m.stage));
  // Mission-log-grounding round: a logged bug runs Research in a scoped GROUNDING
  // mode (it anchors the symptom to the existing code, not full research). While
  // the card sits in the Research column, show a small "grounding" descriptor so
  // the Research pass reads as scoped — on the same generic card, no new type.
  if (normStage(m.stage) === "research" && m.groundingResearch) {
    card.appendChild(el("div", "no grounding-note",
      "grounding · scoped to existing code"));
  }
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
    // S113: an awaiting verify mission still shows its ACTUAL spend beside EST.
    if (m.pills) { var aw = pillNode(m.pills.actual, "actual"); if (aw) pills.appendChild(aw); }
  } else if (m.pills) {
    var c = pillNode(m.pills.cost, "cost"); if (c) pills.appendChild(c);
    // S113: ACTUAL usage pill (present only for verify/done missions with usage).
    var a = pillNode(m.pills.actual, "actual"); if (a) pills.appendChild(a);
    var r = pillNode(m.pills.reasoning); if (r) pills.appendChild(r);
    var i = pillNode(m.pills.implementation); if (i) pills.appendChild(i);
  }
  // S110: surface a LAUNCHED demo app on the card itself, so the captain reads
  // "the app is running" from the board at a glance (not only inside the Verify
  // dialog). Additive — driven purely by m.launch (absent ⇒ no badge, byte-
  // identical to before). Only the live/launching states show; failed/stopped/
  // absent render exactly as today. Reuses the dialog's ● LIVE idiom.
  if (m.launch && m.launch.status === "running") {
    // S110: the ● APP LIVE pill carries an inline ■ stop control so the captain
    // can stand a running app down STRAIGHT FROM THE BOARD — no need to open the
    // Verify dialog (unreachable when focused on a logged-bug flow). It hits the
    // SAME endpoint the dialog's ■ STOP uses (…/launch/stop). btn() already
    // stopPropagations before our handler (the card is click-to-open), and we
    // stopPropagation again FIRST for good measure so stopping never also opens
    // the detail dialog.
    var livePill = el("span", "pill go", "● APP LIVE ");
    var stop = btn("■", "pill-stop", function (e) {
      if (e) e.stopPropagation();
      // Optimistically disable so a double-click can't fire the stop twice; the
      // board's SSE re-render drops the whole pill once launch.status flips off
      // "running" (the card is rebuilt from fresh m).
      stop.disabled = true;
      stop.title = "Stopping…";
      postWrite("/api/mission/" + enc(m.id) + "/launch/stop", {},
        function () { /* SSE re-render removes the pill (fresh m) — nothing to do */ },
        function (msg) {
          // Re-enable and surface the reason on the control itself (no modal).
          stop.disabled = false;
          stop.title = msg || "Stop failed — try again";
        });
    });
    stop.title = "Stop the app";
    applyWriteState(stop); // view-only boards disable it (and set the view-only title)
    livePill.appendChild(stop);
    pills.appendChild(livePill);
  } else if (m.launch && m.launch.status === "launching") {
    // Informational only — matches the dialog, which offers STOP only once running.
    pills.appendChild(el("span", "pill", "▶ LAUNCHING…"));
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

  // S76 / BUG-039: a verify-stage mission may be RECONCILING with the updated
  // base — merging main in, re-verifying the merged branch, or self-healing via
  // its linked bug children — and this is now the normal case WHILE its PR is
  // open. Surface the state as a note whenever a verify mission carries a live
  // reconcileStatus (NO !m.prUrl gate), so the card reads as actively healing
  // (or awaiting a design call when escalated). No `lcars …` CLI text (UX-33).
  if (m.stage === "verify" && m.reconcileStatus) {
    // BUG-067: pick the chrome by sub-state — a merge-failed outcome reads as an
    // ERROR (attention), the awaiting-reapprove / escalated gates as a persistent
    // "needs you" call, the in-flight sub-states (merging/retesting/resolving/
    // healing) as a calm "self-healing…" progress note.
    var rs2 = m.reconcileStatus;
    var rclass = rs2 === "merge-failed"
        ? "no reconcile-status failed"
      : (rs2 === "escalated" || rs2 === "awaiting-reapprove")
        ? "no reconcile-status escalated"
        : "no reconcile-status healing";
    card.appendChild(el("div", rclass, reconcileNote(rs2)));
    // BUG-067: when the engine persisted a human-readable summary (reconcileNote),
    // show it verbatim under the status line so the captain reads WHY (the green
    // re-test count for a reapprove gate, or the failure reason for merge-failed)
    // — the field that was never surfaced before (the silent revert bug).
    if (m.reconcileNote) {
      card.appendChild(el("div", "reconcile-detail", m.reconcileNote));
    }
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
    card.appendChild(cardTickets(m.tickets));
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
  // BUG-067: the reapprove gate. The heal converged green and the engine STOPPED
  // here (awaiting-human, reconcileStatus == awaiting-reapprove) instead of
  // auto-merging. Render a CLEAR, PERSISTENT "Reapprove ▸" action so the captain
  // ships the reconciled, re-tested tip — checked BEFORE the generic awaiting
  // branch (which would mislabel it "Answer ▸" and open the respond dialog).
  if (isReconcileAwaitingReapprove(m)) {
    // BUG-078: the per-click button.disabled (BUG-070) is lost on the next
    // poll/SSE repaint (a fresh button is built), and a repaint that still serves
    // awaiting-reapprove (the merge hasn't finished) would re-render the LIVE
    // Reapprove — a busy → Reapprove → merged flicker. Keep the optimistic merge
    // flag STICKY across those intermediate repaints: clear it only on a TERMINAL
    // change (clearMergingOnState clears on done/merge-failed, NOT on a still-
    // awaiting-reapprove repaint), and while it survives render the disabled busy
    // affordance so the button stays "Merge heal in progress…" from click to the
    // terminal state. Re-uses the shared MERGING set (no parallel mechanism).
    clearMergingOnState(m);
    if (isMerging(m.id)) { ctrl.appendChild(mergeBusyBtn()); return ctrl; }
    // BUG-070: capture the button so the click disables it immediately (mirror
    // the Merge button, BUG-044) — no double-fire of the reapprove dispatch.
    var reBtn = applyWriteState(btn("✓ Reapprove ▸", "go", function () {
      doReapprove(m.id, ctrl, reBtn, m.reconcileStatus);
    }));
    ctrl.appendChild(reBtn);
    return ctrl;
  }
  // BUG-067: the merge FAILED (push/merge rejected — surfaced, not silent). It is
  // an attention state, not a routine gate: offer a retry of the merge-only path
  // (Reapprove) so the captain can re-attempt after fixing the cause, styled as a
  // danger/attention affordance carrying the reason (reconcileNote, on the card).
  if (isReconcileMergeFailed(m)) {
    // BUG-078: keep the Retry-merge busy state sticky too — once a retried merge
    // is dispatched (markMerging), a repaint that still serves merge-failed must
    // not revert to the live Retry button until a terminal change. (Reaching
    // merge-failed is itself terminal for an awaiting-reapprove dispatch, so the
    // flag is already cleared by the time a FRESH merge-failed gate renders.)
    clearMergingOnState(m);
    if (isMerging(m.id)) { ctrl.appendChild(mergeBusyBtn()); return ctrl; }
    // BUG-070: same optimistic disable as the Reapprove gate above.
    var retryBtn = applyWriteState(btn("↻ Retry merge ▸", "danger", function () {
      doReapprove(m.id, ctrl, retryBtn, m.reconcileStatus);
    }));
    ctrl.appendChild(retryBtn);
    return ctrl;
  }
  if (m.awaiting) {
    // BUG-042: an escalated reconcile is an awaiting-human DESIGN CALL, not a
    // "Review PR". Label its action so it reads as a design decision (the dialog
    // — openRespond/openVerify gate — presents the question text). Suppress Merge.
    var alabel = isReconcileEscalated(m) ? "◆ Make the call ▸" : "Answer ▸";
    ctrl.appendChild(applyWriteState(btn(alabel, "danger", function () {
      openRespond(m.id);
    })));
    return ctrl;
  }
  if (m.stage === "done") {
    return ctrl; // terminal — whole-card click opens detail; no inline control.
  }
  var rs = runState(m);
  if (m.stage === "verify") {
    // BUG-044: drop the optimistic merging flag once the real state has arrived.
    clearMergingOnState(m);
    // BUG-049: the verify-affordance decision is SHARED with the detail header
    // (verifyAffordance) so both gate identically during a reconcile/merge/heal.
    // BUG-035: a logged-bug batch in flight → disabled "resolving N…", no
    // openVerify. BUG-039/044: a self-heal (incl. an optimistic isMerging) →
    // disabled "Merge heal in progress…", no openVerify. Otherwise the live
    // Verify/Review PR action.
    var aff = verifyAffordance(m);
    if (aff.kind !== "action") {
      var gated = btn(aff.label, aff.cls, null);
      gated.disabled = !!aff.disabled;
      if (aff.title) gated.title = aff.title;
      ctrl.appendChild(gated);
      return ctrl;
    }
    ctrl.appendChild(applyWriteState(btn(aff.label, aff.cls, function () {
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
  } else if (rs === "queued") {
    // UX-29 follow-up: a logged bug SCHEDULED in a resolve-logs batch but not yet
    // started (state.json.queued) — the batch resolver OWNS its scheduling and
    // drives it automatically when its turn comes. The status pill already reads
    // "QUEUED · WAITING"; the control must MATCH it. Falling through to the Start
    // `else` (below) rendered a live Start on a queued card, inviting a manual
    // launch that RACES the batch driver for the same mission (two drivers, lock
    // contention). Show a disabled "Queued…" affordance instead — mirrors the
    // non-actionable `pausing` pattern above.
    var queuedAff = btn("◷ Queued…", "warn", null);
    queuedAff.disabled = true;
    queuedAff.title =
      "Scheduled in a resolve-logs batch — it starts automatically when its turn comes.";
    ctrl.appendChild(queuedAff);
  } else if (isRunningStage(m.stage) && m.dispatched) {
    // BUG-062: an in-flight headless stage with no live running flag yet — offer
    // Pause, never Start (so Start can't be double-fired). Gated on `dispatched`
    // (the run was actually launched: events on disk OR a live driver lock).
    // Without that gate a logged bug fast-tracked to plan but FILED-but-HELD at
    // estimate-review (only estimate.json, no events) keyed off the STAGE alone
    // and wrongly showed Pause; it must show Start until the run is dispatched.
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

/* UX-39: a COMPACT ticket strip for the board card. Rendering EVERY ticket let a
   big mission's card grow unbounded; the full list already lives in the detail
   TICKETS·WAVES tab. Here we show only the salient few — the ACTIVE/current
   ticket plus a small window of neighbours — and collapse the rest into an
   "and N more…" affordance. A capped, scrollable area is the belt-and-braces
   guard so the card never grows unbounded regardless of ticket count. */
var CARD_TICKET_CAP = 3; // how many ticket rows to show before "and N more…".
function cardTickets(tickets) {
  var tk = el("div", "tickets");
  // pick the active ticket (run/in-progress), else the first not-done, else 0.
  var activeIdx = -1;
  for (var a = 0; a < tickets.length; a++) {
    var st = tickets[a].state;
    if (st === "run" || st === "in-progress") { activeIdx = a; break; }
  }
  if (activeIdx === -1) {
    for (var b = 0; b < tickets.length; b++) {
      if (tickets[b].state !== "done") { activeIdx = b; break; }
    }
  }
  if (activeIdx === -1) activeIdx = 0;
  // a window of CARD_TICKET_CAP centred-ish on the active ticket, clamped to ends.
  var start = Math.max(0, Math.min(activeIdx, tickets.length - CARD_TICKET_CAP));
  var end = Math.min(tickets.length, start + CARD_TICKET_CAP);
  var hiddenBefore = start;
  var hiddenAfter = tickets.length - end;
  if (hiddenBefore > 0) {
    tk.appendChild(ticketMore(hiddenBefore + " earlier…"));
  }
  for (var i = start; i < end; i++) {
    var t = tickets[i];
    // UX-23: default/inactive ticket-row text is WHITE; active=orange, done=teal,
    // flagged=red — the state class drives the colour entirely in CSS.
    var row = el("div", "tk " + (t.state || "pending"));
    row.appendChild(el("span", "dot"));
    var labelText = (t.id || "") + (t.title ? " · " + t.title : "");
    row.appendChild(document.createTextNode(labelText));
    tk.appendChild(row);
  }
  if (hiddenAfter > 0) {
    tk.appendChild(ticketMore("and " + hiddenAfter + " more…"));
  }
  return tk;
}
function ticketMore(text) {
  var row = el("div", "tk-more");
  row.textContent = text;
  return row;
}

/* UX-28: the "log bug · child of #<parent>" badge for a logged bug. When the
   parent issue + repo resolve it renders as a link to the parent issue;
   otherwise a plain badge (parent mission id). Defensive on every field. */
function logBugBadge(m) {
  var ref = parentRef(m);
  // UX-40: a READABLE label (not a tiny chip) — a bug glyph + "BUG · child of
  // #<parent>" at bumped size/contrast. Styling lives in .logbug-badge (CSS).
  var txt = "⊗ BUG" + (ref.text ? " · child of " + ref.text : "");
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
  renderVersionBanner(board.meta && board.meta.version);
}

/* S130: the version UPDATE banner. Driven purely by the ADDITIVE
   board.meta.version block ({running, remote?, stamped?, verdicts[]}). The banner
   is HIDDEN unless there is an ACTIONABLE update: SOURCE_BEHIND → "LCARS <remote>
   AVAILABLE — ENGAGE UPDATE"; REPO_STALE / REPO_PREDATES → "UPDATE LCARS IN THIS
   REPO — <stamped> → <running>", each with an update button that POSTs
   /api/update (decline reasons render inline). A drift-only state (main moved
   without a bump) is a maintainer signal with no board action, so it shows no
   banner — it lives in the CLI. A current install (no verdicts) is likewise
   hidden and byte-identical to before. A VIEW-ONLY build (writesActive === false)
   shows the banner WITHOUT the button — read-safe info, no write affordance. */
function renderVersionBanner(version) {
  var host = document.getElementById("versionBanner");
  if (!host) return;
  host.innerHTML = "";
  // Dismissed for this session → stay hidden through every live re-render.
  if (versionBannerDismissed) { host.hidden = true; return; }
  var verdicts = (version && version.verdicts) || [];
  var sourceBehind = verdicts.indexOf("source_behind") >= 0;
  var repoStale = verdicts.indexOf("repo_stale") >= 0
               || verdicts.indexOf("repo_predates") >= 0;
  // The board banner is an ACTIONABLE "update available/needed" affordance. Only
  // source-behind and repo-stale/predates qualify (each has an ENGAGE UPDATE
  // button). A drift-only state ("main moved without a bump") is a maintainer
  // signal with no board action — it lives in the CLI (`lcars version` /
  // `lcars release`), not as a persistent banner — so the board shows NOTHING
  // (and a successful update, which leaves at most drift, makes the banner clear).
  if (!sourceBehind && !repoStale) { host.hidden = true; return; }
  host.hidden = false;

  var remote = version.remote || "";
  var running = version.running || "";

  // Always name LCARS (never just "REPO", which reads as the repo's own code) and
  // show BOTH the current version and the one they'd move to. sourceBehind updates
  // the whole install to the released version; repoStale/predates re-syncs the
  // LCARS wired into THIS repo up to the version already installed.
  var stamped = version.stamped || "";
  var predates = verdicts.indexOf("repo_predates") >= 0;
  // Only actionable states reach here (the guard above returns on drift-only /
  // current), so this is either sourceBehind or repoStale.
  var msg, sub = "";
  if (sourceBehind) {
    msg = "LCARS " + (remote || "UPDATE") + " AVAILABLE — ENGAGE UPDATE";
    if (running) sub = "this install is on " + running;
  } else {  // repoStale / predates
    if (stamped) {
      // from → to, both known (repo stamp behind the installed version)
      msg = "UPDATE LCARS IN THIS REPO — " + stamped + " → " + (running || "LATEST");
    } else {
      // predates versioning: no stamp to show a "from" for
      msg = "UPDATE LCARS IN THIS REPO → " + (running || "LATEST");
      sub = predates ? "this repo is unstamped (predates versioning)"
                     : "this repo is on an older LCARS";
    }
  }

  var verdictClass = sourceBehind ? "source" : "repo";
  var band = el("div", "vb-band " + verdictClass);
  band.appendChild(el("span", "vb-pip", ""));
  var msgEl = el("span", "vb-msg", msg);
  band.appendChild(msgEl);
  if (sub) band.appendChild(el("span", "vb-run", sub));

  // Right cluster: the ENGAGE UPDATE button (if any) and the ✕ sit together, tight,
  // in one margin-left:auto group — so the band's 14px gap never opens up between
  // them and they share a clean vertical centre. Any status/decline text (vb-reason)
  // is a band sibling to the LEFT of the cluster, so an empty one adds no gap here.
  var right = el("div", "vb-right");
  var hasButton = writesActive !== false && (sourceBehind || repoStale);
  if (hasButton) {
    var reason = el("span", "vb-reason");
    var b = btn("▸ ENGAGE UPDATE", "go vb-btn", function () {
      // In-flight: recolour the band LCARS blue and say so, so the press has
      // visible feedback while pull → install → lcars update runs (seconds).
      b.disabled = true;
      band.classList.remove(verdictClass);
      band.classList.add("vb-updating");
      msgEl.textContent = "UPDATING LCARS…";
      reason.textContent = "";
      postWrite("/api/update", {}, function (state) {
        // Finished: flash teal "UPDATE COMPLETE"; the live SSE tick re-fetches
        // and clears the banner once the stamp reads current (memo invalidated).
        band.classList.remove("vb-updating");
        band.classList.add("vb-done");
        msgEl.textContent = "UPDATE COMPLETE";
        reason.textContent = (state && state.update) ? state.update : "";
      }, function (m) {
        // Failed/declined: revert to the verdict colour and surface the reason.
        band.classList.remove("vb-updating");
        band.classList.add(verdictClass);
        b.disabled = false;
        msgEl.textContent = msg;
        reason.textContent = m;
      });
    });
    band.appendChild(reason);
    right.appendChild(b);
  }

  // Session-only dismiss ✕: hide the banner for the rest of this page's life. No
  // persistence — a refresh / relaunch brings it back.
  var x = btn("✕", "vb-x", function () {
    versionBannerDismissed = true;
    host.hidden = true;
    host.innerHTML = "";
  });
  x.title = "Dismiss until the viewscreen is refreshed or relaunched";
  x.setAttribute("aria-label", "Dismiss update banner for this session");
  right.appendChild(x);
  band.appendChild(right);

  host.appendChild(band);
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

/* ════════════════ IMAGE PASTE / DROP (S91) ════════════════ */
/* CLI-style image attachment for one input surface. The captain pastes or drops
   an image; we read it as base64 and show a CLI-style placeholder chip
   "[Image #N]" with a remove ✕ — NO thumbnail, NO render, NO detail viewer
   (UX-33: a placeholder chip only, no CLI-command text leaked). The images ride
   the EXISTING postWrite body as images:[{name,type,dataB64}] (no new endpoint);
   the daemon stages them and the conversational worker (the Align grill / the
   Mission-Log split) actually sees them. Writes are a LOCAL-BRIDGE affordance —
   a view-only board never offers them (writesActive === false short-circuits, and
   the server 403s any write regardless). Client-side type + size pre-checks
   mirror the server allow-list + body cap so a bad paste fails fast and clearly. */
var IMAGE_TYPES = ["image/png", "image/jpeg", "image/gif", "image/webp"];
var IMAGE_MAX_BYTES = 8 * 1024 * 1024;   /* headroom under the 12 MB server cap */

function attachImagePaster(textarea, onError) {
  var imgs = [];
  var chips = el("div", "img-chips");
  chips.hidden = true;
  if (textarea.parentNode) {
    textarea.parentNode.insertBefore(chips, textarea.nextSibling);
  }
  function repaint() {
    chips.innerHTML = "";
    chips.hidden = imgs.length === 0;
    imgs.forEach(function (img, i) {
      var chip = el("span", "img-chip");
      chip.appendChild(el("span", "img-chip-name", "[Image #" + (i + 1) + "]"));
      var x = el("span", "img-chip-x", "✕");
      x.title = "Remove this image";
      x.addEventListener("click", function (e) {
        e.stopPropagation();
        imgs.splice(i, 1); repaint();
      });
      chip.appendChild(x);
      chips.appendChild(chip);
    });
  }
  function accept(file) {
    if (writesActive === false) {
      if (onError) onError("This board is view-only — image attach is disabled.");
      return;
    }
    if (IMAGE_TYPES.indexOf(file.type) < 0) {
      if (onError) onError("Unsupported image — use PNG, JPEG, GIF or WebP.");
      return;
    }
    if (file.size > IMAGE_MAX_BYTES) {
      if (onError) onError("Image is too large — keep it under 8 MB.");
      return;
    }
    var reader = new FileReader();
    reader.onload = function () {
      var res = String(reader.result || "");
      var comma = res.indexOf(",");           /* strip the data: URL prefix */
      var b64 = comma >= 0 ? res.slice(comma + 1) : res;
      imgs.push({ name: file.name || "pasted-image", type: file.type,
                  dataB64: b64 });
      repaint();
    };
    reader.readAsDataURL(file);
  }
  function harvest(items) {
    var found = false;
    for (var i = 0; items && i < items.length; i++) {
      var it = items[i];
      if (it.kind === "file") {
        var f = it.getAsFile();
        if (f && f.type && f.type.indexOf("image/") === 0) {
          accept(f); found = true;
        }
      }
    }
    return found;
  }
  textarea.addEventListener("paste", function (e) {
    var dt = e.clipboardData;
    if (dt && harvest(dt.items)) { e.preventDefault(); }
  });
  textarea.addEventListener("dragover", function (e) { e.preventDefault(); });
  textarea.addEventListener("drop", function (e) {
    var dt = e.dataTransfer;
    if (!dt) { return; }
    var handled = harvest(dt.items);
    if (!handled && dt.files) {
      for (var i = 0; i < dt.files.length; i++) {
        var f = dt.files[i];
        if (f.type && f.type.indexOf("image/") === 0) { accept(f); handled = true; }
      }
    }
    if (handled) { e.preventDefault(); }
  });
  return {
    /* the postWrite payload value: the chip list, or undefined when empty so
       JSON.stringify omits the `images` key and the turn is unchanged. */
    payload: function () { return imgs.length ? imgs.slice() : undefined; },
    clear: function () { imgs = []; repaint(); },
  };
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
  var optClaude = el("span", "opt", "⬡ Claude");
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

  // S91: paste/drop an image into the idea box → a "[Image #N]" chip; it rides
  // /api/align/start so the grill worker sees the screenshot from turn one.
  var ideaImgs = attachImagePaster(idea, function (msg) { showErr(err, msg); });

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
    openAlignConsole(text, chosen.engine, ideaImgs.payload(), function (msg) {
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
function openAlignConsole(idea, engine, images, onStartError) {
  postWrite("/api/align/start", { idea: idea, engine: engine, images: images },
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
  // S91: paste/drop an image into the grill reply → a "[Image #N]" chip on THIS
  // turn; it rides /api/align/<sid>/answer so the warm worker sees it this turn.
  var freeImgs = attachImagePaster(free, function (msg) { showErr(err, msg); });
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
  // BUG-015: is the question currently on screen the grill's CLOSING turn (the
  // explicit "anything else before I file?" check-in)? When it is, answering it
  // confirms filing — the server then runs the cold opus estimator + file.sh
  // (~1–2 min) inside that POST — so the in-flight spinner must read as
  // "estimating & creating mission", NOT the between-questions grill copy.
  var closing = { val: false };

  function paintPRD(md) { renderPrdDoc(prd, md || ""); }

  function paintQuestion(st) {
    asked += 1;
    var q = st.question || {};
    closing.val = !!q.closing;
    count.textContent = "Question " + asked;
    qtext.textContent = q.text || "What would you like to refine?";
    choices.innerHTML = ""; picked.val = null; free.value = ""; err.hidden = true;
    (q.choices || []).forEach(function (c) {
      var isRec = (q.recommended != null && c === q.recommended);
      // Dedupe the "recommended" indicator (S67): some workers (Copilot) bake
      // "(recommended)" into the option label text, others (claude) don't. When
      // the label text already carries it, the text IS the indicator — suppress
      // the REC pill via .no-pill (keep .rec/.sel highlight). When it doesn't,
      // the pill is the sole indicator and stays. Net: exactly one per option.
      var textHasRec = /\(\s*recommended\s*\)/i.test(c);
      var cls = "opt" + (isRec ? " rec" + (textHasRec ? " no-pill" : "") : "");
      var opt = el("span", cls, c);
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
    // BUG-073: an EMPTY answer is allowed — it means "nothing to add / accept
    // the recommendation / proceed". Do NOT block on a blank box; the server
    // treats an empty answer as a proceed signal (and the grill's surfaced
    // recommendation stands). Typing an answer still overrides the recommendation
    // exactly as before.
    var answer = free.value.trim() || picked.val || "";
    submit.disabled = true; submit.textContent = "Working…";
    err.hidden = true;
    // UX-2: the worker turn (and, on the final answer, the file.sh hand-off)
    // runs server-side within this POST. Show the themed working indicator the
    // whole time; it clears on the next question, on done, or on error.
    // BUG-015: when the captain is answering the CLOSING turn, this POST runs the
    // slow cold-opus estimate + mission creation — show a DISTINCT loading copy so
    // it reads as progress ("estimating & creating mission"), not a stuck grill
    // spinner. Otherwise it's a normal between-questions grill turn.
    busy.querySelector(".lcars-working-label").textContent = closing.val
      ? "Estimating cost & creating mission…"
      : "Formulating the next inquiry…";
    busy.hidden = false;
    postWrite("/api/align/" + enc(sid) + "/answer",
      { answer: answer, images: freeImgs.payload() },
      function (st) {
        busy.hidden = true;
        freeImgs.clear();   // attached images consumed by this turn
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
  // UX-36: the grill length is genuinely variable — the harness does NOT commit
  // to a fixed count. Don't fake a ~6-segment track (that implied "of 6"). Show
  // ONLY a growing track: one filled segment per ANSWERED question, plus a
  // single active "grilling…" marker for the current open question. No fixed
  // total, no "of N", so the bar reads as honestly open-ended.
  var answered = done ? asked : Math.max(0, asked - 1);
  for (var i = 0; i < answered; i++) {
    host.appendChild(el("i", "on"));
  }
  // the current question is still open (not yet answered) → an indeterminate
  // "grilling…" marker that pulses, sitting after the answered segments.
  if (!done) {
    var cur = el("i", "cur grilling");
    cur.title = "grilling…";
    host.appendChild(cur);
  }
  // a small honest caption so the growing track reads as a count of answered
  // questions, never an "x of fixed-total" bar.
  var cap = el("span", "prog-count",
    answered === 0
      ? "Grilling…"
      : answered + " answered" + (done ? "" : " · grilling…"));
  host.appendChild(cap);
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
      m.body.appendChild(modelMixTable(mi.modelMix, mi.groundingResearch));
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

/* BUG-027: the "Why you're seeing this" copy is TYPE-AWARE — a regression gate
   is NOT a strategic/scope call, so it must not read as one. Choose the wording
   from the harness's escalationType ("regression" | "scope" | "cap"); an unknown
   / absent type degrades to the generic copy (pre-harness behaviour). */
function whyCopyForGate(type) {
  switch (type) {
    case "regression":
      return "Why you’re seeing this — two of your changes conflict: a later " +
        "fix re-broke a test an earlier change locked in. Tell the harness how " +
        "to reconcile them (or send the mission back to re-fix), and it resumes " +
        "from where it stopped.";
    case "cap":
      return "Why you’re seeing this — the harness hit its automatic-retry limit " +
        "on this step and needs your call before it tries again. Answer below " +
        "and the mission resumes from where it stopped.";
    case "scope":
      return "Why you’re seeing this — a stage escalated a strategic/scope call. " +
        "Answer below and the mission resumes from where it stopped.";
    default:
      return "Why you’re seeing this — the harness needs your decision to " +
        "proceed. Answer below and the mission resumes from where it stopped.";
  }
}

/* ════════════════ SCREEN: RESPOND GATE (#respond) ════════════════ */
function openRespond(id) {
  fetchMission(id, function (mi) {
    // UX-33: a consolidated re-verify gate gets a dedicated, CLI-free screen with
    // accept / send-back action buttons mapped to the existing endpoints.
    if (isReverifyGate(mi)) { openReverifyGate(mi); return; }

    // BUG-042: an escalated reconcile raised a player-experience DESIGN QUESTION,
    // not an error gate. Title it as a design call. The body still renders the
    // question text (mi.gate.humanSummary || mi.question) with a free-form answer
    // that posts to /respond — the engine consumes it on the next reconcile pass.
    var design = isReconcileEscalated(mi);
    var m = design
      ? modal("◆ Your Design Call — Mission " + idLabel(mi),
              { wide: true, headClass: "teal" })
      : modal("● Awaiting You — Mission " + idLabel(mi) +
              " · " + (mi.stage || "").toUpperCase(),
              { wide: true, headClass: "red" });

    // BUG-027: the harness now writes a legible, type-aware gate envelope into
    // pending.json, surfaced on the card as `mi.gate` ({humanSummary,
    // escalationType, technicalDetail}). Render:
    //   • humanSummary as the HEADLINE (plain language, GitHub issue numbers —
    //     never raw t-XXX);
    //   • the "Why you're seeing this" copy chosen from escalationType (a
    //     regression gate must NOT read as a strategic/scope call);
    //   • technicalDetail behind a collapsible "Technical details" disclosure,
    //     NOT in the headline.
    // Degrade gracefully when the fields are absent (pre-harness): fall back to
    // the sanitized question text + the generic scope copy, exactly as before.
    var gate = mi.gate || {};
    var headline = sanitizeGateText(gate.humanSummary || mi.question) ||
      "The harness needs your decision to proceed.";

    var q = el("div", "qtext"); q.style.fontSize = "18px";
    q.textContent = headline;
    m.body.appendChild(q);
    // BUG-042: a reconcile design call gets player-experience framing, not the
    // generic/error "why you're seeing this" copy.
    m.body.appendChild(noteEl(design
      ? "Reconciling with main surfaced a design choice only you can make. " +
        "Decide how it should behave for the player, answer below, and the heal " +
        "continues on the next pass."
      : whyCopyForGate(gate.escalationType),
      design ? "amber" : undefined));

    // technicalDetail → collapsible disclosure (raw reason + command + any
    // internal ids). Only shown when the harness supplied it.
    if (gate.technicalDetail) {
      var det = el("details", "gate-tech");
      var sum = el("summary"); sum.textContent = "Technical details";
      det.appendChild(sum);
      var pre = el("pre", "gate-tech-body");
      pre.textContent = String(gate.technicalDetail);
      det.appendChild(pre);
      m.body.appendChild(det);
    }

    var ans = el("textarea"); ans.rows = 3;
    ans.placeholder = design
      ? "Describe how it should behave for the player…"
      : "Answer in your own words…";
    m.body.appendChild(field(design ? "Your design call" : "Your answer", ans));

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    var goLabel = design ? "◆ Submit Decision ▸" : "Submit & Resume ▸";
    var go = applyWriteState(btn(goLabel, "go big", function () {
      var text = ans.value.trim();
      if (!text) { showErr(err, "Type an answer first."); return; }
      go.disabled = true; go.textContent = "Submitting…";
      postWrite("/api/mission/" + enc(id) + "/respond", { answer: text },
        function () { closeOverlay(); },
        function (msg) { go.disabled = false; go.textContent = goLabel; showErr(err, msg); });
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

  // S113: EST → ACTUAL cost line (present only when this mission has usage).
  var costLine = costCompareLine(mi);
  if (costLine) m.body.appendChild(costLine);

  // S109: RUN / STOP the mission's app so the captain can view it during re-verify.
  m.body.appendChild(launchAffordance(mi));

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

/* S109: the RUN / STOP launch affordance, shared by BOTH Verify surfaces
   (openVerify + openReverifyGate) — one component. Reads mi.launch
   {status,target,url,message}:
     • absent / stopped / failed → a themed ⚡ RUN button + an optional one-line
       hint input (a prior failure shows its plain-English message above it — the
       message is human English already, never a raw command or stack trace).
     • running → the target + a clickable URL + a ■ STOP button.
   Clicking dispatches to the daemon (POST …/launch | …/launch/stop), which OWNS
   the launched process group. A workingNode covers the in-flight "launching…"
   state; on completion the panel re-fetches this mission and re-renders in place
   (launching → running / failed) without closing the dialog. View-only builds
   degrade the buttons via applyWriteState like every other write. */
function launchAffordance(mi) {
  var wrap = el("div", "launch-panel");
  wrap.style.cssText = "margin:14px 0;padding:10px;border-radius:6px;"
    + "background:rgba(153,153,255,.10)";

  // S110: a single closure-scoped poll timer. While the panel shows LAUNCHING
  // it re-fetches on a cadence so a card reopened mid-launch AUTO-ADVANCES to
  // ● LIVE / failed the moment launch.json resolves (SSE nudges the board cards
  // but never the contents of an already-open dialog). render() is the sole
  // owner: it clears this at the top and re-arms it only in the launching
  // branch, so exactly one loop is ever live and it stops on resolve.
  var pollTimer = null;
  // S110: the launch.status the panel is CURRENTLY painting. Lets a poll tick
  // that's still "launching" detect that nothing visible changed and skip the
  // full teardown+rebuild — which would restart the busy-wave CSS animation
  // every 1.5s and make it visibly stutter.
  var shownStatus = null;
  // S110: has the captain triggered a launch FROM THIS panel instance? Gates the
  // failure banner so a stale "failed" status surfaced on a fresh open renders a
  // clean RUN prompt (no leftover error), while a launch started here that then
  // fails still shows its message. Deliberately per-instance: reopening the card
  // resets it — never surface a STALE failure on open (see S110 edge note).
  var attempted = false;

  // S110: the poll callback, factored out so it can be re-armed from BOTH the
  // launching branch and the unchanged-launching fast-path without a full
  // render. Halts the loop once the dialog is closed (panel off the DOM).
  function pollTick() {
    if (!document.body.contains(wrap)) { clearTimeout(pollTimer); pollTimer = null; return; }
    reload();
  }

  function busyLabel(busy, text) {
    var lab = busy.querySelector(".lcars-working-label");
    if (lab) lab.textContent = text;
  }

  function reload() {
    // Re-fetch the mission so the panel reflects the settled launch state
    // (SSE also nudges the board; this keeps the OPEN dialog in sync). The
    // truth comes from the live launch.json — RUN only if genuinely idle,
    // Launching… if a launch is in flight, ● LIVE if running.
    fetchMission(mi.id, function (fresh) {
      mi.launch = fresh.launch;
      // S110: the launch has RESOLVED once the live record reads a terminal state
      // — drop the instant client-side marker so a genuinely idle mission can show
      // RUN again (and a running/failed one renders its own state).
      var fs = fresh.launch && fresh.launch.status;
      if (fs === "running" || fs === "failed" || fs === "stopped") {
        delete pendingLaunch[String(mi.id)];
      }
      render(fresh.launch);
    }, function () {
      // Resilience: if the re-fetch fails (network/error), don't leave the
      // panel stuck on the neutral "checking" state — fall back to the board
      // copy so the captain still has a usable affordance.
      render(mi.launch);
    });
  }

  // A neutral, trustworthy-until-proven placeholder while reload() fetches the
  // live launch.json: bars only, NO hint input and NO RUN button — so a card
  // reopened during a launch's spin-up window can never flash a false RUN.
  function renderChecking() {
    wrap.textContent = "";
    var head = el("div", "dim");
    head.style.cssText = "text-transform:uppercase;letter-spacing:.08em;"
      + "font-size:11px;margin-bottom:6px";
    head.textContent = "Run the app";
    wrap.appendChild(head);
    var busy = workingNode("Checking app status…");
    wrap.appendChild(busy);
  }

  function render(launch) {
    var status = launch && launch.status;
    // S110: unchanged-launching fast-path. If the panel is ALREADY painting the
    // animated launching state, a poll tick that's still "launching" must NOT
    // tear down + rebuild the panel — that recreates the busy node and restarts
    // its wave animation from the start (a visible stutter every 1.5s). Just
    // re-arm the poll (the timer that fired is spent) and return, leaving the
    // live launching DOM untouched.
    if (status === "launching" && shownStatus === "launching") {
      clearTimeout(pollTimer);
      pollTimer = setTimeout(pollTick, 1500);
      return;
    }
    // S110: reset the poll loop on every render — only the launching branch
    // below re-arms it, guaranteeing exactly one live timer at any moment.
    clearTimeout(pollTimer); pollTimer = null;
    // Record the status this render is about to paint so subsequent poll ticks
    // can detect an unchanged launching state and hit the fast-path above.
    shownStatus = status;
    wrap.textContent = "";
    var head = el("div", "dim");
    head.style.cssText = "text-transform:uppercase;letter-spacing:.08em;"
      + "font-size:11px;margin-bottom:6px";
    head.textContent = "Run the app";
    wrap.appendChild(head);

    var err = el("div", "errline"); err.hidden = true; wrap.appendChild(err);
    var busy = workingNode("Launching the app…"); busy.hidden = true;
    wrap.appendChild(busy);

    if (status === "launching") {
      // A launch is in flight (15–60s: discovery worker + app spawn). Show ONLY the
      // busy state — no hint input, no RUN button. launch.sh persists this record
      // for the whole window, so reopening the card mid-launch lands here too. It
      // resolves to running / failed via reload() / SSE.
      busy.hidden = false;
      busyLabel(busy, "Launching the app…");
      // S110: keep polling the live launch.json until it resolves. reload()
      // re-fetches and re-renders, so this self-perpetuates while still
      // launching and naturally stops once the status becomes running / failed
      // / stopped (those branches don't reschedule).
      // Poll until the launch resolves. The detach check lives in pollTick (not
      // reload) so the INITIAL reload — fired before the caller attaches this
      // panel to the DOM — still runs; only the ongoing poll halts once the
      // dialog is closed (the panel is no longer in the document).
      pollTimer = setTimeout(pollTick, 1500);
      return;
    }
    if (status === "running") {
      var line = el("div"); line.style.marginBottom = "8px";
      line.appendChild(el("span", "pill go", "● LIVE"));
      line.appendChild(document.createTextNode(
        " " + (launch.target || "the app") + " "));
      if (launch.url) {
        var a = el("a"); a.href = launch.url; a.target = "_blank";
        a.rel = "noopener"; a.textContent = launch.url;
        line.appendChild(a);
      }
      wrap.appendChild(line);
      var stop = applyWriteState(btn("■ STOP", "danger", function () {
        err.hidden = true; busy.hidden = false;
        busyLabel(busy, "Standing the app down…");
        stop.disabled = true;
        postWrite("/api/mission/" + enc(mi.id) + "/launch/stop", {},
          function () { reload(); },
          function (msg) {
            busy.hidden = true; stop.disabled = false; showErr(err, msg);
          });
      }));
      wrap.appendChild(stop);
    } else {
      // S110: only surface the failure banner as immediate feedback for a launch
      // the captain triggered in THIS panel instance (attempted). A stale "failed"
      // status painted on a fresh open renders the clean RUN prompt below — the
      // hint input + RUN button still render regardless; only the banner is gated.
      if (status === "failed" && attempted && launch && launch.message) {
        showErr(err, launch.message);
      }
      var hint = el("input", "launch-hint"); hint.type = "text";
      hint.placeholder =
        "Optional — name the app or its directory (e.g. “the game in web/”)";
      hint.style.cssText = "width:100%;box-sizing:border-box;margin-bottom:8px";
      wrap.appendChild(hint);
      var run = applyWriteState(btn("⚡ RUN", "go", function () {
        var h = (hint.value || "").trim();
        // S110: mark this mission launching SYNCHRONOUSLY, before anything async,
        // so a card closed and reopened in the window before the POST lands still
        // renders LAUNCHING (never a false RUN). Cleared when the launch resolves
        // (reload) or the dispatch errors (below).
        pendingLaunch[String(mi.id)] = true;
        // S110: a launch was dispatched from this panel instance — arm the failure
        // banner so if this launch resolves to "failed", render() surfaces its
        // message (reload() → render(failed) / the dispatch error path below).
        attempted = true;
        // Optimistically re-render into the launching state so the hint input +
        // RUN button vanish immediately (a launch takes 15–60s). This mirrors the
        // record launch.sh persists, so it matches a card reopened mid-launch.
        render({ status: "launching", target: h });
        postWrite("/api/mission/" + enc(mi.id) + "/launch", { hint: h },
          function () { reload(); },
          function (msg) {
            // Dispatch failed → not launching; drop the marker and fall back to
            // the RUN prompt with the error.
            delete pendingLaunch[String(mi.id)];
            render(mi.launch);
            var e2 = wrap.querySelector(".errline");
            if (e2) showErr(e2, msg);
          });
      }));
      wrap.appendChild(run);
    }
  }

  // S110: mi.launch is the SSE-LAGGED board copy. During a launch's spin-up
  // window (15–60s) it can still read as pre-launch (absent / stopped / failed)
  // even though a launch just started — painting the RUN state from it here
  // would flash a FALSE ⚡ RUN button before reload() corrects it a beat later.
  //  • ACTIVE states (running / launching) are trustworthy enough to paint now.
  //  • Otherwise render a NEUTRAL "Checking…" (no RUN button) first; reload()
  //    then renders the TRUTH from the live launch.json.
  var openStatus = mi.launch && mi.launch.status;
  if (pendingLaunch[String(mi.id)]) {
    // S110: a launch was dispatched from this page session and hasn't resolved —
    // paint LAUNCHING immediately (never RUN, never "checking"), then let reload()
    // resolve it against the live launch.json.
    render({ status: "launching" });
  } else if (openStatus === "running" || openStatus === "launching") {
    render(mi.launch);
  } else {
    renderChecking();
  }
  // Freshen from the CURRENT launch.json so a launch already in flight renders
  // as launching/running (hiding RUN); a truly idle mission settles to RUN.
  reload();
  return wrap;
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

    // S113: EST → ACTUAL cost line (present only when this mission has usage).
    var costLine = costCompareLine(mi);
    if (costLine) m.body.appendChild(costLine);

    // BUG-030: a Mission-Log bug child (mi.parentMission set) has NO PR concept —
    // its fix rides the PARENT's PR. The Verify dialog for such a bug must show NO
    // PR affordance at all: no "Merge PR" button and no "re-run to open a PR" copy.
    // It offers exactly two actions — "✓ Verify" (accept the fix, which folds the
    // bug to Done via the resolve-logs complete path) and "Send Back". We branch
    // the whole PR-row + footer render on whether the mission has a parent.
    var isBugChild = !!mi.parentMission;

    // S75: Verify auto-opens the PR, so a (top-level) verify card is normally "in
    // review" with a recorded prUrl. Show the PR link + the in-review state, and
    // make the primary action MERGE the PR (not "open" it — that already
    // happened). Before a PR exists (shouldn't normally happen) degrade to a plain
    // note. SKIPPED entirely for a bug child (no PR concept).
    var inReview = !!(mi.prUrl && (mi.review === "open" || mi.review == null));
    if (isBugChild) {
      var foldNote = el("div", "dim");
      foldNote.style.margin = "14px 0";
      foldNote.textContent = "This fix rides the parent mission’s pull request — " +
        "there is no separate PR for this bug. Verifying folds it to Done.";
      m.body.appendChild(foldNote);
    } else if (mi.prUrl) {
      var prRow = el("div", "pr-review-row");
      prRow.style.cssText = "margin:14px 0;padding:10px;border-radius:6px;background:rgba(255,153,0,.08)";
      var st = el("span", "dim");
      // BUG-042: an escalated reconcile is an awaiting-human design call, NOT
      // "in review — Review PR". Read the PR row as healing/awaiting in that case.
      st.textContent = isReconcileEscalated(mi)
        ? "Awaiting your design call — PR · "
        : isReconcileHealing(mi)
          ? "Merge heal in progress — PR · "
          : "In review — PR open · ";
      var link = el("a"); link.href = mi.prUrl; link.target = "_blank";
      // BUG-036: never render a bare "PR #". The adapter populates prNumber
      // (deriving from prUrl when absent); fall back to deriving it here too.
      link.rel = "noopener";
      link.textContent = "PR #" + (mi.prNumber || prNumberFromUrl(mi.prUrl) || "");
      prRow.appendChild(st); prRow.appendChild(link);
      m.body.appendChild(prRow);
    } else {
      var noPr = el("div", "dim");
      noPr.style.margin = "14px 0";
      noPr.textContent = "No PR open yet — re-run the mission so Verify opens it.";
      m.body.appendChild(noPr);
    }

    // S109: RUN / STOP the mission's app so the captain can view it during Verify.
    m.body.appendChild(launchAffordance(mi));

    var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

    // Send-back reveals a feedback field, then dispatches the OTHER decision.
    // S75: send-back now also closes the open PR (handled by feedback.sh).
    var fbWrap = el("div"); fbWrap.hidden = true;
    var fb = el("textarea"); fb.rows = 2;
    fb.placeholder = "What needs to change? This loops the mission back to Align"
      + (mi.prUrl ? " and closes the PR." : ".");
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
    // BUG-039: a self-heal (merge/reconcile) is IN FLIGHT — no merge is possible.
    // Replace the primary action with a disabled "Merge heal in progress…"
    // affordance and drop Send Back (the heal owns the branch right now).
    // BUG-044: an OPTIMISTIC merge (clicked, real reconcileStatus not yet here)
    // gates the same way so a re-opened dialog can't fire a second approve.
    if (isReconcileHealing(mi) || isMerging(mi.id)) {
      m.body.appendChild(noteEl(
        "A self-heal is reconciling this mission with main — re-testing and "
        + "healing the merged branch to green. Merge becomes available once it "
        + "settles. Nothing to do right now.", "amber"));
      var healing = btn("◐ Merge heal in progress…", "warn", null);
      healing.disabled = true;
      healing.title = "Self-healing the merge against main — Merge is unavailable.";
      m.foot.appendChild(healing);
      showOverlay(m.wrap);
      return;
    }
    // BUG-035: a parent with a resolve-logs batch in flight (linked non-done bug
    // children not all at verify) must SUPPRESS both Merge and Accept until the
    // consolidated re-verify gate is up. Show a non-actionable "resolving N
    // logged bug(s)…" state.
    if (!isBugChild && isResolvingLocked(mi)) {
      var pend = resolvingChildren(mi.id);
      m.body.appendChild(noteEl(
        "Logged-bug fixes are in flight against this mission (" + pend.length
        + " not yet folded). Merge and Accept are unavailable until the "
        + "consolidated re-verify gate is ready.", "amber"));
      var lock = btn("◐ resolving " + pend.length + " logged bug"
        + (pend.length === 1 ? "" : "s") + "…", "warn", null);
      lock.disabled = true;
      lock.title = "Resolve-logs batch in flight — re-verify gate not yet ready.";
      m.foot.appendChild(lock);
      showOverlay(m.wrap);
      return;
    }
    // The primary action.
    //   • bug child (BUG-030): "✓ Verify" — accept the fix; the backend routes
    //     the approve decision to the resolve-logs fold (no PR merge). Always
    //     enabled (no PR gating — there is no PR to wait on).
    //   • top-level: "✓ Merge PR" — merge the open PR (the "ship it"). Disabled
    //     gracefully when no PR is open yet.
    var mergeLabel = isBugChild ? "✓ Verify" : "✓ Merge PR";
    var busyLabel = isBugChild ? "Verifying…" : "Merging PR…";
    var merge = applyWriteState(btn(mergeLabel, "go big", function () {
      // BUG-040: the Merge dispatch is fire-and-forget server-side and returns
      // promptly — close the dialog on a successful dispatch and let the board
      // (SSE/refresh) reflect the evolving state (reconciling → escalated → done).
      // BUG-044: OPTIMISTICALLY mark the card busy on the very first click so the
      // card/dialog become non-clickable immediately (before the real
      // reconcileStatus arrives), preventing a second approve → concurrent
      // reconcile. Cleared when the real state lands (clearMergingOnState) or by
      // the safety timeout. On a dispatch ERROR we clear it so the card re-arms.
      markMerging(id);
      merge.disabled = true; merge.textContent = busyLabel;
      postWrite("/api/mission/" + enc(id) + "/verify", { decision: "approve" },
        function () { closeOverlay(); },
        function (msg) { clearMerging(id); merge.disabled = false; merge.textContent = mergeLabel; showErr(err, msg); });
    }));
    if (!isBugChild && !inReview) {
      merge.disabled = true;
      merge.title = "No open PR to merge yet — re-run the mission so Verify opens one.";
    }
    m.foot.appendChild(sendBack);
    m.foot.appendChild(merge);
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

    // S91: paste/drop an image into the bug-report box → a "[Image #N]" chip; it
    // rides /api/mission/<id>/log so the Mission-Log split worker sees the shot.
    var reportImgs = attachImagePaster(report, function (msg) { showErr(err, msg); });

    // UX-25: both the Preview and the File & Run Fixes actions dispatch a worker
    // turn (~25s on copilot) with no feedback. Show the shared LCARS working
    // animation inline while each POST is in flight; it clears on response AND
    // error. One node, label re-set per action.
    var busy = workingNode("Working…"); busy.hidden = true;
    m.body.appendChild(busy);

    // holds the AUTHORED bug PRDs from the last preview + the captain's per-bug
    // override inputs (S74) so they survive Preview → File → Run. `filed` flips
    // true once /log/file has persisted the bugs (then "Run Fixes" only resolves).
    var authored = { prds: null, overrides: [], filed: false };

    m.foot.appendChild(btn("Cancel", null, closeOverlay));
    var prev = applyWriteState(btn("Preview", null, function () {
      // BUG-024: ignore re-clicks while the split/estimate request is pending.
      if (prev.disabled) { return; }
      prev.disabled = true; prev.textContent = "Splitting…";
      err.hidden = true;
      // UX-25: themed working copy for the split worker turn.
      busy.querySelector(".lcars-working-label").textContent =
        "Splitting the report into bugs…";
      busy.hidden = false;
      // free-form text → AUTHORING preview; empty → read-only linked children.
      postWrite("/api/mission/" + enc(id) + "/log",
        { text: report.value.trim(), images: reportImgs.payload() },
        function (state) {
          busy.hidden = true;
          // S92: keep the pasted screenshots alive past Preview — they must ride
          // the /log/file body too so they become DURABLE attachments on every
          // filed bug. They are cleared only after a successful File (below).
          prev.disabled = false; prev.textContent = "Preview";
          authored.prds = state && state.authored
            ? (state.children || []).map(function (c) { return c.prd; })
            : null;
          // per-bug EXPLICIT image refs (the split worker mapped the report's
          // "image 1"/"the second screenshot" wording to numbers). Round-trip
          // them to /log/file so the daemon recomputes the SAME orphaned∪explicit
          // union at filing (the pill shown here uses the already-computed union).
          authored.imageRefs = state && state.authored
            ? (state.children || []).map(function (c) { return c.imageRefs || []; })
            : null;
          authored.overrides = (state && state.children || [])
            .map(function (c) { return c.override || ""; });
          authored.filed = !!(state && (state.filed || !state.authored));
          renderLogPreview(preview, state, idLabel(mi), authored);
          // Reveal File only when this preview AUTHORED ≥1 bug to file. Stays
          // hidden for the read-only linked-children view and for a 0-bug split.
          file.hidden = !(state && state.authored && (state.children || []).length);
        },
        function (msg) {
          busy.hidden = true;
          prev.disabled = false; prev.textContent = "Preview"; showErr(err, msg);
        });
    }));
    // S74 / BUG-059: the captain reviews each bug's ESTIMATE (cost + difficulty
    // pills + suggested model) and can STEER the model BEFORE anything runs. We
    // FILE the authored bugs first (so log.sh runs the estimator + persists each
    // estimate.json) and re-render the panel with the per-bug estimate + override
    // box — then we HOLD. Filing NEVER auto-proceeds into the fix; only the
    // explicit "Go" (revealed after File) resolves the already-filed batch.
    var file = applyWriteState(btn("File", null, function () {
      // BUG-024: the File/preview control kicks off the async estimate (log.sh
      // runs the estimator on every child). It MUST NOT be re-clickable while the
      // request is in flight — a second click re-triggers the estimate (duplicate
      // previews / a race / wasted worker spend). Ignore clicks while pending,
      // disable + show a loading state, and re-enable only on success OR error.
      if (file.disabled) { return; }   // already pending — ignore the click
      err.hidden = true;
      busy.querySelector(".lcars-working-label").textContent =
        "Filing bugs and estimating each fix…";
      busy.hidden = false;
      file.disabled = true;
      var fileLabel = file.textContent;
      file.textContent = "Filing…";
      postWrite("/api/mission/" + enc(id) + "/log/file",
        { prds: authored.prds || [], overrides: authored.overrides || [],
          imageRefs: authored.imageRefs || [],  // per-bug routing
          images: reportImgs.payload() },   // S92: durable attachments on file
        function (state) {
          busy.hidden = true; file.disabled = false; file.textContent = fileLabel;
          reportImgs.clear();          // attachments now persisted on each bug
          authored.prds = null;        // bugs are filed now — Run only resolves
          authored.filed = true;
          file.hidden = true;          // filing is done
          run.hidden = false;          // reveal Run Fixes
          // S74 follow-up: keep the server's per-bug override verdicts (resolved
          // label / normalization error) keyed by child id so the panel echoes
          // them — a steer that couldn't be normalized shows its error, not a
          // silent drop onto the default model.
          authored.resolved = indexOverrides(state && state.overrides);
          renderLogPreview(preview, state, idLabel(mi), authored);
        },
        function (msg) {
          busy.hidden = true; file.disabled = false; file.textContent = fileLabel;
          showErr(err, msg);
        });
    }));
    var run = applyWriteState(btn("Go ▸", "go big", function () {
      // BUG-059 — the explicit human GO. The bugs are ALWAYS filed first (the
      // File step computed + showed each estimate and HELD); this button is the
      // captain's confirm-after-review, so it only RESOLVES the already-filed
      // batch. We never file+run in one click here — filing must hold for the
      // cost review (the combined path is the daemon's confirm:true power path,
      // not the UI default). If the bugs somehow aren't filed yet, refuse rather
      // than auto-proceed.
      if (!authored.filed) {
        showErr(err, "Click File first to estimate each fix, then Go to run.");
        return;
      }
      err.hidden = true;
      // BUG-G (front-end half): the backend dispatches the fixes fire-and-forget
      // and returns promptly, so close the dialog IMMEDIATELY on dispatch
      // (optimistic — the same close-on-dispatch pattern as the Start modal).
      // S74 follow-up CHANGE 4: the per-bug override box lives in the post-File
      // breakdown, so on the resolve-already-filed path we send the edited
      // overrides — the backend (_apply_child_overrides) persists each onto its
      // already-filed child's state.json before dispatching the batch.
      var payload = { overrides: authored.overrides || [] };  // resolve filed
      closeOverlay();
      setStatus("Fixes dispatched — child bug missions are being driven…");
      postWrite("/api/mission/" + enc(id) + "/log/run", payload,
        function () { /* board/SSE refresh shows the new child cards */ },
        function (msg) {
          // a failed dispatch: surface it in the status line (the modal is gone)
          // and refresh so the board reconciles. The spinner already cleared.
          setStatus(msg); refresh();
        });
    }));
    file.hidden = true;    // revealed only after a Preview that splits ≥1 bug
    run.hidden = true;     // revealed once the bugs are filed for review
    m.foot.appendChild(prev);
    m.foot.appendChild(file);
    m.foot.appendChild(run);
    showOverlay(m.wrap);
    report.focus();
  });
}

function renderLogPreview(host, state, parentLabel, authored) {
  host.innerHTML = "";
  var children = (state && state.children) || [];
  var authoredNew = state && state.authored;
  var filed = state && (state.filed || (!authoredNew && children.length));
  var h = el("h4"); h.style.margin = "4px 0 8px";
  h.textContent = (filed ? "Review — " : "Preview — ") +
    ((state && state.count) || children.length) +
    " bug mission" + (children.length === 1 ? "" : "s") +
    (authoredNew ? " detected" : filed ? " filed" : " linked");
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
  // UX-26: render the child-bug cards into a list that gaps the items and caps
  // its height with overflow-y:auto so a long split scrolls in place.
  var list = el("div", "log-preview-list");
  children.forEach(function (c, i) {
    var card = el("div", "card child"); card.style.cursor = "default";
    card.appendChild(el("div", "no", "↳ child of " +
      (parentLabel || state.parent || "parent")));
    card.appendChild(el("div", "ttl", "Bug · " + (c.title || c.id)));
    var pills = el("div", "pills");
    pills.appendChild(el("span", "pill", "lcars:" + (c.stage || "plan")));
    // per-bug image pill (Mission-Log per-bug routing): the FINAL image set this
    // bug will carry (its explicit refs ∪ the orphaned/all-bugs images). A small
    // "🖼 1,2" chip — no thumbnail. Absent/empty ⇒ no pill (theme-consistent).
    if (c.images && c.images.length) {
      pills.appendChild(el("span", "pill img",
        "🖼 " + c.images.join(",")));
    }
    // S74 follow-up CHANGE 1: the PREVIEW (pre-file) stage shows the SPLITS ONLY
    // — the "↳ child of …" breadcrumb, the "Bug · <title>" line, and the
    // lcars:plan pill. The estimate-driven pills, the model mix, and the override
    // box are POST-file only (CHANGE 3/4), since the estimate is computed at File.
    if (filed) {
      // S74: REUSE the Mission-card / Launch pill set — ONE cost pill + TWO
      // difficulty pills — off this bug's estimate. addPills no-ops on a child
      // with no estimate yet (graceful degradation).
      if (c.pills) addPills(pills, c.pills);
      card.appendChild(pills);
      // The suggested per-stage model mix — the SAME modelMixTable the Launch
      // panel renders. Mission-log-grounding round: a logged bug now walks the
      // FULL pipeline, so its mix INCLUDES Research (grounding) + Validate; the
      // shape carries exactly the stages the estimate scored. Only when exposed.
      if (c.modelMix && c.modelMix.length) {
        card.appendChild(modelMixTable(c.modelMix, c.groundingResearch));
      }
      // S74 follow-up CHANGE 4: the per-bug OVERRIDE box lives in the post-File
      // breakdown (not at preview). The captain edits these, then clicks Run
      // Fixes; each value is collected into authored.overrides[i] and threaded to
      // its child via the /log/run payload (→ _file_children persists
      // state.json.modelOverride). Pre-fill with any already-persisted override.
      var ov = el("input");
      ov.placeholder =
        "Override (optional) — e.g. \"use Opus\" · \"keep it cheap\" · all:opus";
      ov.value = (authored && authored.overrides && authored.overrides[i]) ||
        c.override || "";
      if (authored) {
        if (!authored.overrides) authored.overrides = [];
        authored.overrides[i] = ov.value.trim();
      }
      card.appendChild(field("Model override (optional)", ov));
      // S74 follow-up: an LCARS-styled confirmation line that echoes the RESOLVED
      // steer ("Opus 4.8 → Opus · all stages") live as the captain types, and the
      // normalization error inline if the steer couldn't be understood (the
      // server is the source of truth — it surfaces resolved+error in the
      // /log/file & /log/run response; here we also echo the common deterministic
      // cases instantly so plain language is never silently dropped on-screen).
      var steer = el("div", "steer-echo"); steer.hidden = true;
      card.appendChild(steer);
      var srvOv = (authored && authored.resolved && authored.resolved[c.id]) || null;
      var echoSteer = function (rawVal) {
        var raw = (rawVal || "").trim();
        if (!raw) {
          // no steer typed — fall back to any server verdict (e.g. an error left
          // from a prior File/Run), else hide.
          if (srvOv && srvOv.error) {
            steer.hidden = false; steer.className = "steer-echo err";
            steer.textContent = "⚠ " + srvOv.error;
          } else { steer.hidden = true; }
          return;
        }
        var r = previewOverride(raw);
        if (r) {
          steer.hidden = false; steer.className = "steer-echo ok";
          steer.textContent = raw + " → " + overrideLabel(r);
        } else if (srvOv && srvOv.error) {
          steer.hidden = false; steer.className = "steer-echo err";
          steer.textContent = "⚠ " + srvOv.error;
        } else {
          // tier-less plain language: the bounded worker resolves it at File/Run.
          steer.hidden = false; steer.className = "steer-echo pending";
          steer.textContent = "“" + raw + "” — model intent resolved when filed.";
        }
      };
      ov.addEventListener("input", function () {
        if (!authored.overrides) authored.overrides = [];
        authored.overrides[i] = ov.value.trim();
        echoSteer(ov.value);
      });
      echoSteer(ov.value);   // initial echo (pre-filled / server-resolved value)
    } else {
      card.appendChild(pills);
    }
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
  // BUG-067: the reapprove / merge-failed gates carry awaiting=true but are NOT a
  // generic "Answer ▸" respond gate — they ship via the merge-only Reapprove
  // path. Intercept them BEFORE the awaiting branch so the header offers the
  // right action (and clears the optimistic merge flag once state moves).
  if (isReconcileAwaitingReapprove(mi) || isReconcileMergeFailed(mi)) {
    // BUG-078: clear the optimistic merge flag only on a terminal change, then —
    // if a dispatched reapprove/retry is still in flight (isMerging) — render the
    // SAME disabled busy affordance the card shows, sticky across repaints, so the
    // header button never reverts to the live Reapprove mid-merge (mirrors card).
    clearMergingOnState(mi);
    var raff = verifyAffordance(mi);
    if (raff.kind !== "reapprove" && raff.kind !== "merge-failed") {
      var rGated = btn(raff.label, raff.cls, null);
      rGated.disabled = !!raff.disabled;
      if (raff.title) rGated.title = raff.title;
      actions.appendChild(rGated);
    } else {
      // BUG-070: disable the header Reapprove button on the first click (mirror the
      // Merge button, BUG-044) before closing the overlay, so a fast double-click
      // can't double-fire the reapprove dispatch.
      var rBtn = applyWriteState(btn(raff.label, raff.cls, function () {
        doReapprove(mi.id, null, rBtn, mi.reconcileStatus); closeOverlay();
      }));
      actions.appendChild(rBtn);
    }
  } else if (mi.awaiting) {
    actions.appendChild(applyWriteState(btn("Answer ▸", "danger", function () { openRespond(mi.id); })));
  } else if (mi.stage === "verify") {
    // BUG-049: the header verify action must gate IDENTICALLY to the card — a
    // plain "✓ Verify" here while a mission is mid-reconcile/heal/resolving (the
    // dialog it opens IS gated, but the affordance shouldn't show). Use the SAME
    // shared verifyAffordance decision the card control uses (DRY): a gated kind
    // renders a disabled/relabelled button (no openVerify); only the live action
    // wires Verify/Review PR. clearMergingOnState mirrors the card so an
    // optimistic merge flag drops once the real reconcile state arrives.
    clearMergingOnState(mi);
    var daff = verifyAffordance(mi);
    if (daff.kind !== "action") {
      var dgated = btn(daff.label, daff.cls, null);
      dgated.disabled = !!daff.disabled;
      if (daff.title) dgated.title = daff.title;
      actions.appendChild(dgated);
    } else {
      actions.appendChild(applyWriteState(btn(daff.label, daff.cls, function () { openVerify(mi.id); })));
    }
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
  } else if (mrs === "running" || (isRunningStage(mi.stage) && mi.dispatched)) {
    // UX-13: mirror the card — a live drive overrides Start → Pause so Start
    // can't be double-fired from the detail header either. UX-17: while
    // optimistically starting the Pause stays disabled until running flips true.
    // BUG-062: the stage-based fallback is gated on `dispatched` (the run was
    // actually launched) so a filed-but-held mission (estimate-only, no events)
    // shows Start, not Pause — identical to the card control.
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
  // BUG-046: a logged-bug CHILD (type=="bug" && parentMission set, the isLogBug
  // predicate that gates the rest of the logged-bug chrome) is itself a bug entry
  // — you cannot log bugs AGAINST a logged bug. So the button renders for
  // top-level missions only, never for a bug child.
  if (mi.stage !== "done" && !isLogBug(mi)) {
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
    // UX-37: the remaining prose is worker-authored Markdown — render it XSS-safe
    // (sanitizeGateText runs FIRST, mdToHtml escapes before emitting any tag).
    if (ev.detail || ev.text) {
      var txt = el("div", "txt");
      setMd(txt, sanitizeGateText(ev.text || ev.detail));
      ec.appendChild(txt);
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
  // BUG-047: `activeSecondsAt` is the SERVER wall-clock (seconds) at which `base`
  // (activeSeconds) was computed. The live display = base + (now - activeSecondsAt)
  // while running — so it is correct on EVERY render/re-open, not re-based from the
  // stale snapshot (which equals the total only up to the last stage boundary, so a
  // close→re-open mid-stage used to reset the clock). Client/server share the host
  // clock, so this is accurate to a few seconds. Absent ⇒ fall back to render-time
  // anchor (old behaviour) so a pre-anchor shape still ticks.
  var anchorAt = mi && typeof mi.activeSecondsAt === "number" ? mi.activeSecondsAt : null;
  function liveSeconds() {
    // FREEZE when not running (awaiting/paused/queued/verify/done) — shows the
    // frozen total, preserving "excludes time awaiting you" semantics: the
    // in-flight delta only advances while actively running.
    if (!isInFlight(mi)) return base;
    var nowSec = Date.now() / 1000;
    if (anchorAt != null) {
      return base + Math.max(0, Math.floor(nowSec - anchorAt));
    }
    return base; // no anchor → freeze at base (the tick below handles fallback).
  }
  var node = el("div", "active-runtime");
  node.title = "active runtime — excludes time awaiting you";
  var val = el("span", "ar-val", "Active " + fmtDuration(liveSeconds()));
  node.appendChild(val);
  if (!opts.compact) {
    node.appendChild(el("span", "ar-hint", "excludes time awaiting you"));
  }
  // UX-32/BUG-047: live tick only while running. Recompute from the SERVER anchor
  // every tick (and on every render this node is rebuilt, re-reading the anchor),
  // so a re-open shows true elapsed from the anchor rather than re-basing from a
  // stale snapshot. Frozen (no interval) when not running.
  if (isInFlight(mi)) {
    var fallbackAnchor = Date.now();
    var timer = setInterval(function () {
      if (!document.body.contains(val)) { clearInterval(timer); return; }
      var secs;
      if (anchorAt != null) {
        secs = liveSeconds();
      } else {
        secs = base + Math.floor((Date.now() - fallbackAnchor) / 1000);
      }
      val.textContent = "Active " + fmtDuration(secs);
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
  // S76: a logged-bug child (incl. a self-authored reconcile bug) carries no
  // Acceptance-Criteria section — its detailed PRD (Conflict/failure summary,
  // Root cause, Intended fix, …) IS the auditable record, so render the full PRD
  // body for a bug child when the detail shape carries it. The captain audits the
  // self-heal straight from here.
  if (isLogBug(mi) && mi.prd) {
    var cap = el("div", "mock-cap", "Bug report (PRD)");
    cap.style.marginTop = "12px";
    pane.appendChild(cap);
    var doc = el("div", "prd-doc");
    renderPrdDoc(doc, mi.prd);
    var box = el("div");
    box.style.cssText = "background:var(--lcars-black);padding:12px 14px;border-radius:8px;max-height:40vh;overflow:auto";
    box.appendChild(doc);
    pane.appendChild(box);
  }
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
      // UX-37: ADR bodies are worker-authored Markdown — render it (XSS-safe).
      var body = el("div", "adr-body");
      body.style.cssText = "margin-top:4px;font-size:12px";
      setMd(body, a.body);
      adr.appendChild(body);
    }
    pane.appendChild(adr);
  });
  return pane;
}

/* UX-38: the stages BEFORE the Plan stage, where decomposition into tickets/
   waves simply hasn't happened yet (so an "empty" tickets pane is expected, not
   a single-ticket mission). */
function isPrePlanStage(stage) {
  return ["align", "research", "validate"].indexOf(normStage(stage)) !== -1;
}

function ticketsPane(mi) {
  var pane = el("div");
  var tickets = mi.tickets || [];
  // UX-38: the empty-state is STAGE-AWARE — pre-Plan it would be wrong to claim a
  // single-ticket mission "reuses the issue" (decomposition hasn't run yet).
  if (!tickets.length) {
    if (isPrePlanStage(mi.stage)) {
      // pre-Plan: decomposition is still ahead — say so clearly (Trek-flavored).
      pane.appendChild(noteEl(
        "Standing by for the Plan stage. This mission has not been broken down " +
        "into tickets and waves yet — the harness decomposes the validated plan " +
        "into vertical-slice tickets at the Plan stage, and the work crew is " +
        "assigned into waves from there. Check back once the mission reaches Plan.",
        "amber"));
    } else {
      // at/after Plan with no tickets → a genuine single-ticket mission.
      pane.appendChild(noteEl("No nested tickets — a single-ticket mission reuses " +
        "the mission's own issue, so no sub-issue rows are shown."));
    }
    return pane;
  }
  // exactly one ticket at/after Plan → keep the single-ticket message (a lone
  // slice reuses the issue; a one-row "wave" reads as noise).
  if (tickets.length === 1 && !isPrePlanStage(mi.stage)) {
    pane.appendChild(noteEl("Single-ticket mission — the one slice rides the " +
      "mission's own issue, so no separate sub-issue rows are shown."));
    return pane;
  }
  // multiple tickets → the existing ticket/wave rows.
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
    // UX-37: acceptance-criteria text is worker-authored Markdown — render it
    // inline (XSS-safe). The .md-inline node trims block margins so a criterion
    // still sits on one row.
    var ctext = el("span", "md md-inline");
    setMd(ctext, r.text);
    ctext.classList.add("md-inline");
    row.appendChild(ctext);
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
    // UX-37: ticket title/rationale is worker-authored Markdown — render inline.
    var ttext = el("span", "md md-inline");
    setMd(ttext, " " + (t.title || t.id || ""));
    row.appendChild(ttext);
    host.appendChild(row);
  });
  return host;
}

/* S70-B1: the per-stage model-mix table (mock .mix / .tier.opus / .tier.sonnet).
   modelMix = [{stage, tier, why}]; `why` (the estimator rationale) is shown once
   below the table when present. */
function modelMixTable(mix, grounding) {
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
    // Mission-log-grounding round: on a grounding mission the Research row runs
    // in the scoped GROUNDING mode, so tag it "Research · grounding" to explain
    // why a bug still carries a Research row on the same generic card.
    var stageTxt = r.stage || "";
    if (grounding && stageTxt === "Research") stageTxt = "Research · grounding";
    tr.appendChild(el("td", null, stageTxt));
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

/* S74 follow-up: the per-bug model steer is NORMALIZED server-side (passthrough
   <scope>:<tier> → deterministic parse → bounded worker fallback → never silent-
   drop). This is the SAME deterministic map, mirrored client-side so the panel
   echoes the resolved steer LIVE as the captain types (the long-tail worker
   fallback only runs server-side at File/Run). Returns {scope,tier} or null. */
function previewOverride(raw) {
  if (!raw) return null;
  var s = String(raw).trim();
  if (!s) return null;
  var m = /^(all|reasoning|implementation):(sonnet|opus)$/i.exec(s);
  if (m) return { scope: m[1].toLowerCase(), tier: m[2].toLowerCase() };
  var low = s.toLowerCase();
  var tier = null;
  if (/\bopus\b/.test(low) || /4[._-]?8\b/.test(low)) tier = "opus";
  else if (/\bsonnet\b/.test(low) || /4[._-]?6\b/.test(low) ||
           /\b(cheap|cheaper|budget|inexpensive|save|saving)\b/.test(low))
    tier = "sonnet";
  if (!tier) return null;        // inconclusive → resolved server-side at File/Run
  var scope = "all";
  if (/\b(reason|reasoning|think|thinking|plan|planning)\b/.test(low))
    scope = "reasoning";
  else if (/\b(implement|implementation|impl|coding|code|build|building)\b/.test(low))
    scope = "implementation";
  return { scope: scope, tier: tier };
}
function indexOverrides(list) {
  var by = {};
  (list || []).forEach(function (o) { if (o && o.id) by[o.id] = o; });
  return by;
}
function overrideLabel(r) {
  if (!r) return null;
  var tier = r.tier === "opus" ? "Opus" : "Sonnet";
  var scope = r.scope === "reasoning" ? "reasoning stages"
    : r.scope === "implementation" ? "implementation stages" : "all stages";
  return tier + " · " + scope;
}

/* ════════════════ UX-37: XSS-SAFE MARKDOWN → HTML ════════════════
   Worker-authored prose (ADR bodies, the PRD tab, ticket rationale/acceptance
   criteria, activity-feed descriptions) arrives as Markdown and was rendering
   LITERALLY ("**Context:**", backtick `code`). This helper renders a SMALL,
   dependency-free (ADR-007) subset of Markdown.

   SECURITY (content is worker-authored ⇒ UNTRUSTED): we ESCAPE every HTML
   metacharacter FIRST (so no raw tag the author wrote can ever reach the DOM as
   markup), THEN we splice in our OWN small, fixed set of tags from the escaped
   text. Because escaping happens before any tag insertion, a payload like
   `<img onerror=…>` or `<script>` becomes inert text. Links are restricted to
   http(s)/mailto schemes and the href is itself the already-escaped capture, so
   a `javascript:` URL can't slip through. We never use the raw input again after
   escaping — only the escaped string is transformed.

   Supported: headings (#, ##, ###), unordered lists (-, *, +), ordered lists,
   **bold**, *italic* / _italic_, `inline code`, [text](url) links, and blank-
   line-separated paragraphs with <br> for single newlines.

   Returns an HTML STRING; callers set it via `setMd(node, md)` which assigns it
   to innerHTML (safe — every tag in the string is one we emitted). */
function escapeHtml(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/* Apply inline markup to an ALREADY-ESCAPED line. Order matters: code spans
   first (their contents are taken verbatim, no further inline parsing), then
   links, then bold, then italic. */
function mdInline(escaped) {
  var s = escaped;
  // `inline code` → <code> (escaped already; just wrap).
  s = s.replace(/`([^`]+?)`/g, function (_, code) {
    return "<code>" + code + "</code>";
  });
  // [text](url) — url already escaped; allow only safe schemes (http/https/
  // mailto) or root-relative paths. Anything else renders as plain text.
  s = s.replace(/\[([^\]]+?)\]\(([^)\s]+?)\)/g, function (whole, text, url) {
    if (/^(https?:|mailto:)/i.test(url) || /^\/[^/]/.test(url)) {
      return '<a href="' + url + '" target="_blank" rel="noopener">' + text + "</a>";
    }
    return whole; // unsafe/unknown scheme → leave as the literal (escaped) text.
  });
  // **bold** / __bold__
  s = s.replace(/\*\*([^*]+?)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/__([^_]+?)__/g, "<strong>$1</strong>");
  // *italic* / _italic_ (avoid eating the ** already consumed above).
  s = s.replace(/(^|[^*])\*([^*]+?)\*($|[^*])/g, "$1<em>$2</em>$3");
  s = s.replace(/(^|[^_])_([^_]+?)_($|[^_])/g, "$1<em>$2</em>$3");
  return s;
}

function mdToHtml(md) {
  var lines = String(md == null ? "" : md).split(/\r?\n/);
  var out = [];
  var i = 0;
  while (i < lines.length) {
    var raw = lines[i];
    var esc = escapeHtml(raw);
    var trimmed = raw.replace(/^\s+/, "");
    // blank line → paragraph break (handled by paragraph grouping below).
    if (!trimmed) { i++; continue; }
    // heading
    var h = trimmed.match(/^(#{1,3})\s+(.*)$/);
    if (h) {
      var lvl = h[1].length + 2; // # → h3, ## → h4, ### → h5 (keep within page scale)
      out.push("<h" + lvl + ">" + mdInline(escapeHtml(h[2])) + "</h" + lvl + ">");
      i++;
      continue;
    }
    // unordered list block
    if (/^[-*+]\s+/.test(trimmed)) {
      out.push("<ul>");
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        var item = lines[i].replace(/^\s*[-*+]\s+/, "");
        out.push("<li>" + mdInline(escapeHtml(item)) + "</li>");
        i++;
      }
      out.push("</ul>");
      continue;
    }
    // ordered list block
    if (/^\d+\.\s+/.test(trimmed)) {
      out.push("<ol>");
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
        var oitem = lines[i].replace(/^\s*\d+\.\s+/, "");
        out.push("<li>" + mdInline(escapeHtml(oitem)) + "</li>");
        i++;
      }
      out.push("</ol>");
      continue;
    }
    // paragraph: gather consecutive non-blank, non-block lines, join with <br>.
    var para = [];
    while (i < lines.length) {
      var l = lines[i];
      var t = l.replace(/^\s+/, "");
      if (!t || /^(#{1,3})\s+/.test(t) || /^[-*+]\s+/.test(t) || /^\d+\.\s+/.test(t)) break;
      para.push(mdInline(escapeHtml(l)));
      i++;
    }
    out.push("<p>" + para.join("<br>") + "</p>");
  }
  return out.join("");
}

/* Render Markdown into a node's innerHTML. The string comes solely from
   mdToHtml(), every tag of which we emitted ourselves over escaped text — so
   this is safe despite using innerHTML (UX-37). */
function setMd(node, md) {
  node.innerHTML = mdToHtml(md);
  node.classList.add("md");
  return node;
}

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

/* S76 — a human-readable note for the main-ahead reconcile sub-state. No `lcars …`
   CLI text leaks (UX-33); the copy carries the state + iterate-to-green hint. */
/* BUG-049: the SHARED verify-affordance decision. Both the board card control
   (cardControls) and the detail-header action row must gate the verify action
   IDENTICALLY during a reconcile/merge/heal — otherwise the header offers a
   plain "✓ Verify" while a mission is mid-reconcile (the dialog it opens IS
   gated, but the affordance shouldn't appear). One helper returns the decision
   so both render the same priority gating (mirrors cardControls' order):
     escalated : awaiting-human reconcile DESIGN CALL → "Make the call" (answer)
     resolving : a logged-bug batch in flight        → disabled "resolving N…"
     healing   : a merge/self-heal in flight (incl. optimistic isMerging)
                                                      → disabled "Merge heal…"
     action    : the live Verify/Review PR action     → "✓ Review PR"/"✓ Verify"
   The renderer reads `.kind` and builds the right button (the card and header
   wire their own click handlers / dispatch styles). */
function verifyAffordance(m) {
  if (!m) return null;
  // BUG-078: an OPTIMISTIC reapprove/retry-merge dispatch is in flight (isMerging,
  // kept sticky by clearMergingOnState until a terminal change). It must win over
  // the reapprove / merge-failed gate kinds below so the button stays the disabled
  // busy affordance across repaints — no busy → Reapprove → merged flicker. The
  // caller is expected to have run clearMergingOnState first (terminal-only clear).
  if (isMerging(m.id)) {
    return {
      kind: "healing", label: "◐ Merge heal in progress…",
      cls: "warn", disabled: true,
      title: "Self-healing the merge against main — Merge is unavailable until "
        + "it settles.",
    };
  }
  // BUG-067: the heal converged → reapprove gate. A merge-only Reapprove action,
  // NOT a "Review PR" (the PR is already reconciled + re-tested green).
  if (isReconcileAwaitingReapprove(m)) {
    return { kind: "reapprove", label: "✓ Reapprove ▸", cls: "go" };
  }
  // BUG-067: the merge FAILED — an attention state offering a retry of the
  // merge-only path (NOT silence, NOT a routine "Review PR").
  if (isReconcileMergeFailed(m)) {
    return { kind: "merge-failed", label: "↻ Retry merge ▸", cls: "danger" };
  }
  if (isReconcileEscalated(m)) {
    return { kind: "escalated", label: "◆ Make the call ▸", cls: "danger" };
  }
  if (isResolvingLocked(m)) {
    var pend = resolvingChildren(m.id);
    return {
      kind: "resolving",
      label: "◐ resolving " + pend.length + " logged bug"
        + (pend.length === 1 ? "" : "s") + "…",
      cls: "warn", disabled: true,
      title: "Logged-bug fixes are in flight — Merge is unavailable until the "
        + "consolidated re-verify gate is ready.",
    };
  }
  if (isReconcileHealing(m) || isMerging(m.id)) {
    return {
      kind: "healing", label: "◐ Merge heal in progress…",
      cls: "warn", disabled: true,
      title: "Self-healing the merge against main — Merge is unavailable until "
        + "it settles.",
    };
  }
  return {
    kind: "action", label: m.prUrl ? "✓ Review PR ▸" : "✓ Verify ▸", cls: "go",
  };
}

/* BUG-039 / BUG-067: a self-heal (merge/reconcile) is IN FLIGHT — merging the
   base in, re-testing the merged branch, resolving a conflict, or self-healing.
   While this is true the Merge action must be SUPPRESSED (no merge possible
   mid-heal). escalated / awaiting-reapprove / merge-failed are NOT in-flight
   (each is a human-facing terminal-of-the-heal state) — handled separately. */
function isReconcileHealing(m) {
  if (!m || m.stage !== "verify") return false;
  var rs = m.reconcileStatus;
  return rs === "merging" || rs === "retesting" || rs === "resolving"
      || rs === "healing";
}

/* BUG-042: the reconcile raised an awaiting-human DESIGN QUESTION (a
   player-experience call), not a "Review PR". The mission is awaiting-human with
   reconcileStatus === "escalated". */
function isReconcileEscalated(m) {
  return !!(m && m.stage === "verify" && m.reconcileStatus === "escalated");
}

/* BUG-067: the merge self-heal CONVERGED green and the engine STOPPED at the
   reapprove gate (it no longer auto-merges). The mission is awaiting-human with
   reconcileStatus === "awaiting-reapprove" — the board renders a persistent gate
   with a Reapprove action (NOT a transient flash, NOT a silent revert to verify). */
function isReconcileAwaitingReapprove(m) {
  return !!(m && m.stage === "verify"
            && m.reconcileStatus === "awaiting-reapprove");
}

/* BUG-067: the push/merge FAILED (e.g. non-fast-forward, checks, auth). The
   engine surfaces it as reconcileStatus === "merge-failed" with the reason in
   reconcileNote — the board renders this distinctly as an error/attention state
   (NOT silence; today this outcome vanished and the card reverted to verify). */
function isReconcileMergeFailed(m) {
  return !!(m && m.stage === "verify" && m.reconcileStatus === "merge-failed");
}

function reconcileNote(status) {
  switch (status) {
    case "merging":   return "◐ reconciling with main — merging the updated base in";
    case "retesting": return "◐ re-verifying the merged branch against main";
    case "resolving": return "◐ reconciling — resolving the merge conflict";
    case "healing":   return "◐ reconciling — self-healing the merge to green";
    case "awaiting-reapprove":
      return "● reconciled & green — reapprove to merge";
    case "merge-failed":
      return "✖ merge failed — needs you";
    case "escalated": return "● reconcile needs you — couldn't auto-heal against main";
    default:          return "◐ reconciling with main";
  }
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

/* BUG-067 / BUG-065: dispatch the Reapprove (merge-only) path. The engine runs
   the merge fire-and-forget server-side, so this returns promptly. We apply the
   OPTIMISTIC merging busy-state immediately (markMerging + showCardBusy) so the
   card flips to "merging…" without a manual refresh (BUG-065), then rely on the
   board/SSE to land the real outcome (done, or the merge-failed attention state).
   On a dispatch error we clear the optimistic flag so the card re-arms.
   BUG-070: mirror the Merge button (BUG-044) — the Reapprove button itself is
   DISABLED + relabelled busy on the very first click (before the optimistic
   markMerging / before the dispatch returns), so a second click can't re-fire
   the reapprove dispatch while the merge is in flight. The disable is cleared on
   a dispatch ERROR (re-arm) and the optimistic merge flag clears when the served
   state advances out of awaiting-reapprove (clearMergingOnState) or via timeout. */
function doReapprove(id, host, button, fromStatus) {
  if (button) { button.disabled = true; button.textContent = "Merging PR…"; }
  // BUG-078: record the gate clicked from (awaiting-reapprove / merge-failed) so
  // the optimistic busy flag stays sticky until a TERMINAL change away from it.
  markMerging(id, fromStatus);
  if (host) {
    var busy = workingNode("Merging the reconciled tip…");
    busy.className += " lcars-running";
    host.innerHTML = ""; host.appendChild(busy);
  }
  postWrite("/api/mission/" + enc(id) + "/reapprove", {},
    function () { /* board/SSE refresh shows the merge outcome */ },
    function (msg) {
      clearMerging(id);
      if (button) { button.disabled = false; }
      setStatus(msg); refresh();
    });
}

function addPills(host, pills) {
  if (!pills) return;
  var c = pillNode(pills.cost, "cost"); if (c) host.appendChild(c);
  // S113: ACTUAL usage pill in the detail pill row (present only verify/done + usage).
  var a = pillNode(pills.actual, "actual"); if (a) host.appendChild(a);
  var r = pillNode(pills.reasoning); if (r) host.appendChild(r);
  var i = pillNode(pills.implementation); if (i) host.appendChild(i);
}

function idLabel(mi) {
  return (mi.issue ? "#" + mi.issue : mi.id) +
    (mi.title ? " — " + mi.title : "");
}

/* BUG-036: derive a PR number from a PR url's trailing /pull/<n> (front-end
   fallback when prNumber isn't on the shape). Returns null when not present. */
function prNumberFromUrl(url) {
  var m = /\/pull\/(\d+)/.exec(String(url || ""));
  return m ? parseInt(m[1], 10) : null;
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

function fetchMission(id, cb, onErr) {
  fetch("/api/mission/" + enc(id))
    .then(function (r) {
      if (r.status === 404) throw new Error("no such mission");
      return r.json();
    })
    .then(cb)
    .catch(function () {
      // An optional caller-supplied error handler keeps a live panel from
      // getting stuck on a transient state (e.g. launchAffordance's "checking")
      // when the fetch fails; the default keeps the historic status message.
      if (typeof onErr === "function") { onErr(); return; }
      setStatus("mission unavailable");
    });
}

/* ════════════════ live channel ════════════════ */
/* BUG-065: keep the board live WITHOUT a manual page refresh after a write action
   (Go / Merge / Reapprove) AND as a reconcile sub-state advances. Two paths back
   each other up:
     1. SSE (/api/events) pushes one `update` per SETTLED state change — but it
        debounces behind a quiet window, so a churning, multi-step reconcile/heal
        (state.json rewritten merging→retesting→…→awaiting-reapprove) only emits
        ONCE writes stop. That left the board frozen mid-heal (the bug: transient
        states flashed by / the failed outcome was never surfaced).
     2. A lightweight SAFETY POLL re-fetches the board on a steady interval so the
        evolving sub-states (and the write actions' own fire-and-forget effects,
        which land asynchronously after the POST returns) appear live regardless.
   The poll is cheap (one /api/board GET) and idempotent with the SSE — whichever
   observes the change first re-renders; the other is a no-op re-render. */
var LIVE_POLL_MS = 4000;
function connect() {
  var conn = document.getElementById("conn");
  // The safety poll runs ALWAYS (independent of SSE health) so a debounced or
  // dropped SSE never leaves the board stale during a reconcile.
  setInterval(refresh, LIVE_POLL_MS);
  try {
    var es = new EventSource("/api/events");
    es.addEventListener("update", function () { refresh(); });
    es.onopen = function () { conn.className = "conn"; conn.textContent = "● LIVE"; };
    es.onerror = function () {
      conn.className = "conn stale"; conn.textContent = "○ RECONNECTING";
    };
  } catch (e) {
    /* no EventSource — the safety poll above is the sole live path. */
  }
}

/* UX-30: PADD rebrand. The header band reads "LCARS · KANBAN" in index.html;
   per the file constraint (board.js/board.css only) we rewrite the brand node
   here at boot to "PADD" with a smaller acronym sub-line below it —
   "Project Alignment & Development Display" with the FIRST LETTER of each word
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
  [["P", "roject"], ["A", "lignment"], ["D", "evelopment"], ["D", "isplay"]]
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
