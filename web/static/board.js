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

/* S168: the FORGE HOST the board is attached to (board.meta.ghHost), captured on
   every render beside detailRepo. The captain works in *.ghe.com repos, and both
   issue links below used to concatenate a literal "https://github.com/" — so
   every link went to a github.com repository that does not exist and had to be
   hand-edited after the click.

   The daemon sends a BARE HOST and only when it is NOT github.com (see
   local_adapter.gh_host: `gh_hostname` returns empty there on purpose, so a
   github.com payload is byte-identical to before). Absent/null therefore means
   "github.com", which is what ghIssueUrl falls back to. May stay null. */
var boardGhHost = null;

/* A DNS hostname and nothing else — no scheme, no path, no port, no space. The
   daemon already refuses anything else, but this value is spliced into a URL the
   captain CLICKS, and a guard that only exists upstream is not a guard here. */
var GH_HOST_RE = /^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/;

/* Capture "which forge, which repo" off a board payload. Called at the TOP of
   render(), BEFORE any card is built, and again from renderMeta.

   The ordering is load-bearing, and getting it wrong was a real defect measured
   in Chrome on 2026-08-03: renderMeta ran at the END of render(), so on the
   FIRST paint of a fresh page `detailRepo` was still null while the cards were
   being built, and a logged bug's "⊗ BUG · child of #<n>" badge rendered as a
   plain <span> instead of a link to the parent issue. It only became a link if
   some later re-render happened to come along. */
function captureForgeIdentity(meta) {
  // UX-14: the repo the detail "View on GitHub" link is built from.
  detailRepo = (meta && meta.repo) || null;
  // S168: …and the forge HOST those links must point at. Reassigned on EVERY
  // render, so a payload that stops carrying it reverts to github.com rather
  // than leaving a stale enterprise host on the page.
  boardGhHost = (meta && typeof meta.ghHost === "string") ? meta.ghHost : null;
  /* S190: WHO THIS BOARD IS. Captured here for exactly the ordering reason the
     block above records — cardNode() needs it BEFORE the first card is built, or
     the very first paint of a fresh page decides "is this mine?" against a null
     and renders every owned card unlocked until some later re-render happens by.
     Reassigned on EVERY render, so a payload that stops carrying an identity
     (auth expired, gh removed) reverts to "we do not know" and stops locking,
     rather than leaving a stale login deciding whose work this is. */
  var s = meta && meta.self;
  selfLogin = (s && typeof s.login === "string" && s.login) ? s.login : null;
}

/* ════════════════ S190: OWNER, AVATAR, AND THE LIGHT LOCK ════════════════

   The board's half of the solo protocol. The daemon publishes two facts —
   `card.owner {login, avatarUrl}` and `meta.self {login}` — and this is the only
   place that turns them into a verdict.

   THE POSTURE IS lcars_owner_lock_reason's, MIRRORED EXACTLY (ownership.sh):

     * an UNASSIGNED mission is NEVER locked — empty is "unowned", not an error;
     * an UNRESOLVABLE identity NEVER locks anything — if we cannot say who we
       are, we do not get to tell the captain he is someone else;
     * only WRITE affordances are affected; every read (the card, the detail, the
       activity feed, the ticket rows) stays wide open.

   A false lock is strictly worse than the thing the lock prevents: it shuts the
   captain out of his own work because a network hiccuped. So every uncertain
   case answers "not locked".

   AND THIS IS NOT THE LOCK. A disabled button is a courtesy — anyone can POST
   straight past the DOM, and the tester will. The lock is the daemon's
   server-side re-check (server._dispatch_verb → Actions.owner_lock_reason),
   which re-asks the forge live and 403s with this same sentence. */

/* The login LCARS is acting as (board.meta.self.login), or null when nothing
   could say. Captured on every render beside detailRepo/boardGhHost. */
var selfLogin = null;

/* The owner's login when this mission is DEMONSTRABLY someone else's, else null.
   The single predicate the whole lock is built on. */
function ownerLockLogin(m) {
  var owner = m && m.owner && m.owner.login;
  if (!owner) return null;      // unassigned / never asked → never locked
  if (!selfLogin) return null;  // we cannot say who we are → never locked
  if (owner === selfLogin) return null;
  return owner;
}

/* The refusal, in one sentence. It is byte-identical to the line
   `lcars_owner_lock_reason` prints and the line the daemon's 403 carries — the
   captain must not be told two different things by the tooltip and the refusal
   that follows if he clicks past it. Pinned on both sides by tests. */
function ownerLockLine(login) {
  return "assigned to " + login +
    " — reassign it to yourself on GitHub to take command";
}

/* THE LOCK MARK — the glyph half of "this control is locked".

   S191's capstone (D4) found the light lock ENFORCED perfectly and INVISIBLE. A
   locked `▶ Start` and a live `▶ Start` were the same button: same shape, same
   saturated teal, distinguishable only by the owner pill's colour two rows up.
   The .7 dim the previous round measured so carefully is imperceptible on that
   fill. So the captain clicks something that looks live and gets a tooltip —
   and a lock the eye cannot see is a lie the hand discovers.

   TWO THINGS CARRY THE STATE, at the two distances a card is read from. The
   stylesheet drains the FILL (a locked control goes hollow in the lock's own
   blue — `.btn.danger`'s existing idiom, no new vocabulary), which is what you
   see across the room. This carries the near reading: the leading ACTION glyph
   is REPLACED with `⊘`, because `▶` on a control that will not go is the lie
   stated a second time, in the one place the eye lands last.

   `⊘` IS NOT A NEW GLYPH. It is the one the Verify lock label has worn since
   S190, looked at by a tester at 3x and confirmed to sit at the same weight as
   the board's ▶ ✓ ⊗ ⬡ ▦ family. Nothing outside that family is introduced here —
   S190's D3 and this session's own `⇩` near-miss were both exactly that mistake. */
var LOCK_GLYPH = "⊘";
/* The leading glyphs a control wears to say what it will DO. A locked control
   must wear none of them. */
var LOCK_ACTION_GLYPHS = "▶▸▹✓⏸◐◷↻◆⊹";

function markLocked(n) {
  if (!n) return;
  // THE STATE CLASS FIRST, and unconditionally — the fill is the half that
  // reads across the room, so no control may miss it.
  if ((" " + String(n.className || "") + " ").indexOf(" locked ") < 0) {
    n.className = String(n.className || "") + " locked";
  }
  // THE LABEL, for TEXT-ONLY CONTROLS ONLY. A button carrying element children
  // is left exactly as it is rather than flattened: `textContent =` would
  // silently delete those children, which is the S163 shape (a node quietly
  // removed) in new clothes. Every control cardControls builds is a plain
  // `btn(label, …)`, so this covers the row; anything richer keeps its label
  // and still gets the fill, the disable and the tooltip.
  if (n.children && n.children.length) return;
  var t = String(n.textContent == null ? "" : n.textContent).replace(/^\s+/, "");
  if (!t) return;
  if (t.charAt(0) === LOCK_GLYPH) return;   // already marked (the Verify label)
  if (LOCK_ACTION_GLYPHS.indexOf(t.charAt(0)) >= 0) {
    t = t.slice(1).replace(/^\s+/, "");
  }
  n.textContent = LOCK_GLYPH + " " + t;
}

/* Disable every write control under `host` when this mission is someone else's.

   A SUBTREE SWEEP, deliberately, rather than a condition threaded through
   cardControls' dozen branches. Those branches are the accumulated history of
   this board — reapprove gates, merge-failed retries, queued cards, filing
   windows, START ALIGNMENT — and any one of them added later would silently
   miss a per-branch check. A sweep cannot miss a branch: whatever the card
   decided to draw, if it is a button in the control row it is disabled and it
   says why.

   Note what is NOT swept: the ● APP LIVE stop control lives in the PILL row, not
   here, so a launched app can still be stood down (S187 owns the launch
   affordance and this session changes nothing about it). */
function applyOwnerLock(host, m) {
  var login = ownerLockLogin(m);
  if (!host || !login) return host;
  var line = ownerLockLine(login);
  (function walk(n) {
    if (!n) return;
    var tag = String(n.tagName || n.tag || "").toUpperCase();
    if (tag === "BUTTON") {
      n.disabled = true;
      n.title = line;
      // …and SAY SO on the label itself (D4). The sweep is the right place for
      // it for the same reason it is the right place for the disable: whatever
      // branch of cardControls drew this button, it is now marked.
      markLocked(n);
    }
    var kids = n.children || [];
    for (var i = 0; i < kids.length; i++) walk(kids[i]);
  })(host);
  return host;
}

/* The Verify/Merge affordance for a mission held by someone else, or null.

   WHY THE LOCK ALSO SITS INSIDE verifyAffordance. The sweep above stops at the
   card. `verifyAffordance` is shared by the board card AND the DETAIL header —
   that sharing is deliberate (BUG-049: both must gate identically during a
   reconcile or a merge) — so calling this at the TOP of it covers the
   Verify/Merge action on BOTH surfaces from one place. Without it, opening
   someone else's mission would show a live ✓ Merge in the header, and the only
   thing between a click and a merge would be the daemon's 403.

   It outranks the busy / reapprove / merge-failed kinds on purpose: every one of
   those describes work IN FLIGHT, and none of it is work THIS laptop may act on.

   It is a FUNCTION rather than eight inline lines because verifyAffordance's
   opening bytes are pinned by an existing regression guard (test_server's BUG-078
   window check) — a long insertion there would break a test that has nothing to
   do with this session. One call, two lines, guard intact. */
function ownerLockOnVerify(m) {
  var login = ownerLockLogin(m);
  if (!login) return null;
  return {
    kind: "owned-by-other", label: "⊘ " + login + "'s mission",
    cls: "warn", disabled: true, title: ownerLockLine(login),
  };
}

/* The owner treatment: an LCARS pill — the avatar in a fully-rounded LEFT CAP,
   the handle in uppercase display type on the colour block beside it.

   THE DESIGN PROBLEM: a GitHub avatar is a PHOTOGRAPH, and LCARS has no
   photographs — it is flat colour blocks, rounded caps and uppercase type. So
   the photo is not dropped onto the console; it is FRAMED by it, inset inside a
   solid cap that reads as part of the chrome, with the handle carrying the LCARS
   voice beside it. All geometry, no new tokens (ADR-007).

   THE DEAD-SRC DEGRADE is wired here rather than left to alt text: a broken
   <img> keeps its box and its class (the S164 legend-swatch lesson), so an
   avatar that fails would otherwise leave a hole in the cap that looks
   deliberate. On error the image is REMOVED and the block is marked `.dead`, so
   the stylesheet closes the cap and the handle stands alone — a complete,
   intentional-looking pill, not a damaged one.

   Returns null when there is no owner: a card with nothing to say about
   ownership renders exactly as it did before this round. */
function ownerNode(m) {
  var o = m && m.owner;
  if (!o || !o.login) return null;
  var wrap = el("div", "owner");
  var handle = el("span", "owner-handle", String(o.login).toUpperCase());
  if (o.avatarUrl) {
    var cap = el("span", "owner-av");
    var img = document.createElement("img");
    img.src = o.avatarUrl;
    img.alt = o.login;
    // Decorative-but-identifying: the handle beside it already carries the name
    // in text, so a reader that never loads the image loses nothing.
    img.setAttribute("loading", "lazy");
    // github.com is a third party; send it no referrer from the captain's board.
    img.setAttribute("referrerpolicy", "no-referrer");
    img.addEventListener("error", function () {
      if (cap.parentNode) cap.parentNode.removeChild(cap);
      wrap.className = "owner dead";
    });
    cap.appendChild(img);
    wrap.appendChild(cap);
  } else {
    wrap.className = "owner dead";
  }
  wrap.appendChild(handle);
  // The whole pill carries the same sentence the locked controls do, so hovering
  // the person explains the state without hunting for a disabled button.
  var lock = ownerLockLogin(m);
  wrap.title = lock ? ownerLockLine(lock) : (String(o.login) + " owns this mission");
  return wrap;
}

/* ═══════════════ S191: THE REMOTE CARD (driven from another machine) ═══════

   A laptop with no `.git/lcars` for a mission still SEES it: the daemon reads
   the forge on a slow cached poll and adds a card carrying what the issue
   actually knows — stage (from the STAGE LABEL), awaiting-human, owner, and
   during Implement the closed/total ticket count. `card.remote === true` is the
   whole contract; everything below keys off that one boolean.

   IT IS READ-ONLY, AND THAT IS NOT A LIMITATION TO APOLOGISE FOR. The mission is
   being driven by a `run` on ANOTHER machine, holding a driver lock this laptop
   cannot see and writing artifacts this laptop does not have. A live Start here
   would promise something LCARS genuinely cannot do. So every write affordance
   is disabled and says why, in one sentence.

   THE ONE THING IT DOES OFFER IS ADOPT, at exactly the two ENDS of the pipeline
   (align / verify) — S189's v1 portability boundary. At align the spec IS the
   issue body; at verify the branch and the PR are both on the forge; between
   them the next stage reads local artifacts that were never synced, so an adopt
   there would hand the captain a mission missing the files it is about to open.
   The card offers what is honest and stays quiet about the rest. */

/* The refusal, in one sentence — the tooltip on every disabled control. */
var REMOTE_LINE =
  "driven from another machine — adopt at Align/Verify to act here";

function isRemote(m) { return !!(m && m.remote === true); }

/* Disable every write control under `host` on a REMOTE mission.

   A SUBTREE SWEEP, for the same reason S190's applyOwnerLock is one: cardControls
   is a dozen accumulated branches and the detail header is a dozen more, and a
   per-branch check is a check the next branch will forget. A sweep cannot miss a
   branch — whatever the surface decided to draw, if it is a button it is
   disabled and it says why.

   TWO EXEMPTIONS, both by class and both deliberate: `detail-close` (a modal you
   cannot close is a trap, and closing writes nothing) and `remote-adopt` (the one
   action a remote card exists to offer). Exempting BY CLASS rather than by
   build order means the sweep can be called at any point in either builder
   without a comment about where it has to go. */
function applyRemoteLock(host, m) {
  if (!host || !isRemote(m)) return host;
  (function walk(n) {
    if (!n) return;
    var tag = String(n.tagName || n.tag || "").toUpperCase();
    var cls = " " + String(n.className || "") + " ";
    if (tag === "BUTTON"
        && cls.indexOf(" detail-close ") < 0
        && cls.indexOf(" remote-adopt ") < 0) {
      n.disabled = true;
      n.title = REMOTE_LINE;
    }
    var kids = n.children || [];
    for (var i = 0; i < kids.length; i++) walk(kids[i]);
  })(host);
  return host;
}

/* The REMOTE marker. A pill, in the pill row, in the existing LCARS vocabulary
   (S190's idiom: no new visual language for a new fact) — the framed diamond is in the
   product's own console-glyph family (the set test_help_console pins) and is used
   nowhere else, so it reads as its own state rather than borrowing another's. First in the row on purpose: WHERE this mission is being driven
   outranks what it will cost. */
function remotePill() {
  return el("span", "pill remote", "◈ REMOTE · DRIVEN ELSEWHERE");
}

/* ADOPT — take command of a remote mission on THIS laptop.

   Offered ONLY where the daemon said it is honest (`m.adoptable`, derived from
   the stage label), never wherever the front end feels like it: the boundary is
   a product rule and it belongs on the one side that can also enforce it.

   It POSTs the ISSUE NUMBER, because that is what a remote card IS — there is no
   local mission id yet, and minting one is exactly what `lcars adopt` refuses to
   do (the id already names the branch and the issue). On success the mission
   becomes LOCAL, the overlay stops drawing a remote card for that issue, and the
   local card takes its place on the next refresh. */
function adoptControl(m) {
  if (!isRemote(m) || !m.adoptable) return null;
  var b = btn("▹ Adopt ▸", "go remote-adopt", function () {
    if (b.disabled) return;
    b.disabled = true;
    b.textContent = "◐ Adopting…";
    postWrite("/api/mission/" + enc(m.issue != null ? m.issue : m.id)
              + "/adopt", {},
      function (state) {
        // The board refresh postWrite already fired swaps in the LOCAL card.
        //
        // S196 A4 — ADOPT'S WARNINGS ARE NOT SWALLOWED. This used to say only
        // "Adopted #34 — it is a local mission now." and drop everything else
        // adopt printed: no testCommand could be detected, the attachments could
        // not follow the issue, no open PR resolves at Verify, this repo's config
        // prefers a different engine. Each of those is something the captain must
        // act on, and the one surface that could tell him threw them away.
        //
        // The daemon lifts them off adopt's own `⚠` marker and hands them over
        // as `warnings`; this reads that FIELD, never adopt's prose. A warned
        // adopt is a WARN verdict, not an ok one — it succeeded, and it is not
        // finished business.
        var warns = (state && state.warnings) || [];
        var head = "Adopted #" + m.issue + " — it is a local mission now.";
        if (warns.length) {
          setVerdict(head + " ⚠ " + warns.join(" ⚠ "), "warn");
        } else {
          setVerdict(head, "ok");
        }
      },
      function (msg) {
        b.disabled = false;
        b.textContent = "▹ Adopt ▸";
        // A VERDICT, not a silent re-enable: adopt.sh refuses for reasons the
        // captain has to read (wrong stage, no handoff envelope, no gh), and a
        // button that quietly came back would say none of them.
        setVerdict(msg || "Adopt failed.", "err");
      });
  });
  b.title = "Rebuild this mission on THIS machine from its GitHub issue";
  return act("adopt", applyWriteState(b));
}

/* The control row of a remote card: swept read-only, then ADOPT added.

   ORDER MATTERS ONLY FOR READABILITY — the sweep exempts the adopt button by
   class, so this would be correct either way — but sweeping first and adding
   second says plainly that adopt is the exception to a rule, not a survivor of
   one. */
function remoteControls(host, m) {
  if (!isRemote(m)) return host;
  applyRemoteLock(host, m);
  var adopt = adoptControl(m);
  if (adopt && host) host.appendChild(adopt);
  return host;
}

/* THE FORGE DID NOT ANSWER. `meta.remote.status === "unavailable"` means the
   daemon HAS gh and asked, and got nothing back — no auth, no network, not a
   GitHub remote, rate-limited. It is worth ONE quiet line in the footer beside
   the view-only marker, and nothing more: the local cards are all still there
   and completely usable, so this is an ambient condition, never an alert.

   ABSENT ⇒ HIDDEN. A board with no gh carries no `remote` key at all and this
   never shows, which is what keeps it invisible to everybody who has one laptop. */
function renderRemoteNote(remote) {
  var host = document.getElementById("remoteNote");
  if (!host) return;
  var down = !!(remote && remote.status === "unavailable");
  host.hidden = !down;
  host.textContent = down
    ? "○ REMOTE DATA UNAVAILABLE — showing local missions only" : "";
}

/* THE one place the board builds a link to an issue. The scheme is pinned HERE,
   never sent by the daemon, so nothing arriving over the wire can become it. */
function ghIssueUrl(repo, issue) {
  var host = (typeof boardGhHost === "string" && GH_HOST_RE.test(boardGhHost))
    ? boardGhHost : "github.com";
  return "https://" + host + "/" + repo + "/issues/" + issue;
}

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
/* S163: which READ ADAPTER served this board (`board.meta.adapter`, ADR-003 —
   "local" | "github"). Captured here because one S163 rule depends on a card
   field the two adapters do not mean the same thing by: the github adapter
   cannot see LOCAL events.jsonl, the driver lock or state.json, so it publishes
   `dispatched`/`queued`/`running` as hardcoded `false` PLACEHOLDERS (its own
   comments say so — "present, non-crashing, False"). Reading those as a
   measurement on a forge board would let a card claim a batch has never been
   driven when nothing there can know. `board.py` always fills this in (it
   defaults to "local"), so in the product it is never unknown. */
var BOARD_ADAPTER = null;
function indexIssues(board) {
  ISSUE_BY_ID = Object.create(null);
  CHILDREN_BY_PARENT = Object.create(null);
  BOARD_ADAPTER = (board && board.meta && board.meta.adapter) || null;
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
/* ── S163 fix round 7 (D2): the CLIENT's copy of `_waiting_children` ─────────
   The bugs on this parent still waiting to be fixed — the review panel's rows,
   and (because `Go ▸` spawns `resolve-logs --parent`) what the click will drive.

   It exists because the card had been counting for itself with a DIFFERENT
   rule. `resolvingChildren` excludes only `done`, so a child at `verify` — the
   consolidated re-verify gate, i.e. work already finished — was still in the
   card's count while the daemon's `_waiting_children` had long since dropped
   it. The round-7 tester drove one of two filed bugs to `verify` by hand (the
   recovery round 6's own bound prescribes) and read three numbers off one repo
   at one instant: card 2, panel 1, Go 1.

   The daemon's `waitingCount` is still the reading wherever it is published —
   this is the fallback for a payload that carries none — so what matters here
   is that the two rules AGREE. The exclusions are `_waiting_children`'s, in its
   order, and any change there has to be mirrored here:

     done / verify    the fix has landed, or is at its gate.
     queued / running a driver already has it; re-offering invites a second.

   The one exclusion it cannot mirror is "a Go already took this bug", which
   lives in the daemon's dispatch record — and does not need mirroring, because
   `logFixState` returns early on `m.logDispatch` before it ever gets here. */
function waitingChildren(parentId) {
  return resolvingChildren(parentId).filter(function (c) {
    return (c.stage || "").toLowerCase() !== "verify"
      && !c.queued && !c.running;
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

/* Park & Align (S137 / BUG-3): optimistic "aligning" set. START ALIGNMENT fires a
   warm-grill POST (/api/align/start) that only RENDERS when the worker turn returns
   — seconds later. With no guard the live button stays clickable and gives no
   feedback, so a frustrated captain clicks it repeatedly and each click spawns a
   NEW server-side _AlignSession that later "flashes" as a stray console. On the
   click we mark the mission id "aligning": both the card control and the detail
   header then render a DISABLED "⊹ Scanning…" affordance across every repaint (SSE
   included) so a re-click is impossible until the console actually opens
   (clearAligning on success) or the open errors / is superseded. Mirrors the
   STARTING pattern (UX-17).

   S128 / FL-009 — THERE IS NO WALL-CLOCK TIMEOUT HERE, ON PURPOSE. This map
   used to hold a 60s setTimeout handle that cleared the guard and refresh()ed.
   On the S127 capstone the captain's opening Align turn took 61s: the timer
   fired one second before the turn RETURNED, the card re-armed to START
   ALIGNMENT, and a turn that had already done the work was presented as a
   failure. He clicked again — which spawned a SECOND real worker (free on
   copilot, billed on claude). A bigger constant is the same guess with a longer
   fuse: a holodeck-born mission's opening turn reads a 28KB mockup and a
   concept doc on top of ~5s of MCP spawn, so every hand-off sits on the
   threshold, and the next artifact moves it again.

   So the guard's lifetime IS THE REQUEST'S LIFETIME — a fact, not a guess. It
   is armed on the click and released by exactly one event: the /api/align/start
   POST settling. Success opens the console (clearAligning in openAlignConsole);
   an error — including `postWrite`'s .catch, which is the DAEMON DYING mid-turn
   arriving as a rejected fetch — clears it with a message. That rejection is
   the safety net, and it is an event rather than a clock, so it cannot fire on
   a turn that is merely slow.

   What the record holds instead of a handle is `since` — the click's timestamp
   — so the card can SAY how long the turn has been running (`aligningFor`).
   Silence is what made the original defect frightening; "⊹ Scanning the
   codebase… 1m 35s" reads as slow, where a bare spinner reads as broken.

   A page RELOAD during a turn loses this map — it is client memory. That half is
   the daemon's, and it is now published: see `alignScanState` below. */
var ALIGNING = Object.create(null);

function markAligning(id) {
  if (id == null) return;
  ALIGNING[String(id)] = { since: Date.now() };
}
function clearAligning(id) {
  if (id == null) return;
  delete ALIGNING[String(id)];
}
function isAligning(id) {
  return id != null && !!ALIGNING[String(id)];
}
/* S128/FL-009: seconds the in-flight Align turn has been running, or null when
   the record carries no start (a forced flag in a test harness). */
function aligningFor(id) {
  var rec = id == null ? null : ALIGNING[String(id)];
  if (!rec || typeof rec !== "object" || !rec.since) return null;
  return Math.max(0, Math.floor((Date.now() - rec.since) / 1000));
}
/* `<base>` plus the elapsed time when we know it. Every scanning surface (the
   card band, the control, its tooltip) reads through this so they cannot
   disagree about how long the same turn has been running. */
function scanningLabel(secs, base) {
  return secs == null ? base : base + " " + fmtDuration(secs);
}

/* S128/FL-009 — THE DAEMON'S HALF, which is what closes the KNOWN GAP above.

   `ALIGNING` is this tab's memory. A reload throws it away, and the card used to
   re-arm to START ALIGNMENT on a turn that was still running — the same lie
   FL-009 is about, through a different door, with the same second real worker
   waiting behind the re-click.

   So the daemon publishes the fact (`_align_busy_fields` in actions.py, the
   `alignBusy` twin of f667ce8's `busy`/`busySince`/`busyFor`) and this reads it.
   Same split as `logFilingState` next door: the client map is the INSTANT half
   (no round trip, no SSE tick, and it covers the gap before the first poll), the
   server stamp is the DURABLE half that survives a reload.

   WHICH WINS. The daemon, on both counts — it is the only one that can see the
   worker. Its PRESENCE makes the card scan even when this tab has no memory of a
   click (a reload, a second tab, a POST that came back on a proxy timeout while
   the turn kept running), and its elapsed seconds are preferred over the local
   click time because the local time is when we ASKED, not when the turn began.
   Its ABSENCE, though, clears nothing: a board built a moment before the session
   registered, or a card off this board entirely, would then re-arm the guard on a
   live turn — FL-009 again. The guard is still released by exactly one event, the
   /api/align/start POST settling. The daemon fact is for the case where that
   memory is GONE, not a replacement for it.

   NOT A NEW WORDING. The label is the one `scanningLabel` already renders, so a
   reloaded tab and the tab that clicked say the same thing about the same turn. */
function alignScanState(m) {
  var stamp = (m && m.alignBusy && typeof m.alignBusy === "object")
    ? m.alignBusy : null;
  var srv = (stamp && typeof stamp["for"] === "number")
    ? Math.max(0, Math.floor(stamp["for"])) : null;
  var local = aligningFor(m && m.id);
  return {
    scanning: !!(m && isAligning(m.id)) || !!stamp,
    // the daemon's elapsed when it published one; this tab's click otherwise.
    secs: srv != null ? srv : local
  };
}

/* Park & Align (F1 — background the final estimate): optimistic "finalizing" set.
   Answering the CLOSING grill turn runs the cold-opus estimator + file.sh --complete
   server-side INSIDE that answer POST (~1–2 min). The captain may close/navigate while
   it runs — closing does NOT abort the in-flight fetch — so the parked card shows an
   animated "◐ FINALIZING & COSTING…" band + a disabled control until the server
   finishes and the board refresh swaps in the aligned card. In-memory only; mirrors
   ALIGNING.

   S169 / FL-017 — THERE IS NO WALL-CLOCK TIMEOUT HERE ANY MORE, for the reason
   ALIGNING above has none. This map used to hold a `setTimeout` on
   `FINALIZING_TIMEOUT_MS = 300000` that cleared the guard and `refresh()`ed:
   byte-for-byte FL-009's shape with 300s in place of 60s. On expiry it dropped
   the band and re-armed the card while the estimator and `file.sh --complete`
   were still running — a run that was still going, presented as one that had
   stopped, with a real second worker waiting behind the re-click. The captain
   hit it live on the S128 drive ("OK the mission is costing after the grill").
   FL-009's ruling was written for exactly this: *"do NOT just raise the number.
   A bigger constant is the same guess with a longer fuse, and the next artifact
   makes it wrong again."*

   So the guard's lifetime IS THE REQUEST'S LIFETIME. It is armed on the closing
   submit and released by exactly one event: the /api/align/<sid>/answer POST
   settling — `done` on success, and the error handler on failure, which is
   where a DAEMON THAT DIED mid-finalize arrives as a rejected fetch. That
   rejection is the safety net, and being an event rather than a clock it cannot
   fire on a finalize that is merely slow.

   What the record holds instead of a timer handle is `since`, so the band can
   say how long it has been going (`finalizingFor`) rather than sitting silent.

   A page RELOAD during a finalize loses this map — it is client memory, and
   that was FL-009's second half too. That half is the daemon's, and it is now
   published: see `alignFinalizeState` below.

   Caveat (v1): fully closing the browser TAB may interrupt the in-flight
   finalize — documented, not handled. */
var FINALIZING = Object.create(null);

function markFinalizing(id) {
  if (id == null) return;
  FINALIZING[String(id)] = { since: Date.now() };
}
function clearFinalizing(id) {
  if (id == null) return;
  delete FINALIZING[String(id)];
}
function isFinalizing(id) {
  return id != null && !!FINALIZING[String(id)];
}
/* S169/FL-017: seconds this tab's finalize has been running, or null when the
   record carries no start (a forced flag in a test harness). The ALIGNING twin. */
function finalizingFor(id) {
  var rec = id == null ? null : FINALIZING[String(id)];
  if (!rec || typeof rec !== "object" || !rec.since) return null;
  return Math.max(0, Math.floor((Date.now() - rec.since) / 1000));
}

/* S169/FL-017 — THE DAEMON'S HALF, and it closes the reload gap exactly as
   `alignScanState` does for the scan.

   `FINALIZING` is this tab's memory. A reload throws it away, and the card
   re-armed to START ALIGNMENT over a `file.sh --complete` that was still
   running. So the daemon publishes the fact (`_align_finalizing_fields` in
   actions.py, the `alignFinalizing` twin of `alignBusy`) and this reads it.

   WHICH WINS. The daemon, on both counts, for `alignScanState`'s reasons: its
   PRESENCE makes the card finalize even when this tab has no memory of the
   submit, and its elapsed is preferred because it is when the DISPATCH began,
   not when we asked. Its ABSENCE clears nothing — a board built a moment before
   the dispatch was stamped would otherwise re-arm the guard on a live finalize,
   which is FL-017 again through the other door.

   NOT A NEW WORDING: the label is the one `finalizingPulse` already renders. */
function alignFinalizeState(m) {
  var stamp = (m && m.alignFinalizing && typeof m.alignFinalizing === "object")
    ? m.alignFinalizing : null;
  var srv = (stamp && typeof stamp["for"] === "number")
    ? Math.max(0, Math.floor(stamp["for"])) : null;
  var local = finalizingFor(m && m.id);
  return {
    finalizing: !!(m && isFinalizing(m.id)) || !!stamp,
    secs: srv != null ? srv : local
  };
}

/* S162 (backgroundable mission-log filing): the optimistic "filing" set — the
   Mission-Log twin of FINALIZING. "File & Cost" DISPATCHES the S161
   file-by-sessionId POST and CLOSES the console, so from that instant the PARENT
   CARD is the only surface telling the captain anything. This map is the fast
   half of that promise: it flips the card to the disabled "◐ FILING & COSTING…"
   control + the persistent animated band on the click itself, with no round trip
   and no SSE tick. The DURABLE half is the daemon's `logFiling` stamp, which a
   reloaded tab reads instead (exactly the alignResume split).

   It is deliberately NOT FINALIZING with a second meaning. A parked mission can
   be finalizing an Align turn while a verify mission files logged bugs, and one
   card can legitimately be doing BOTH — sharing a map would let either state
   clear the other's band, and would make "is this mission busy?" a question with
   two different right answers. One map per meaning (the S161-D2 lesson about two
   meanings under one key, applied to state rather than copy).

   The timeout is the estimator's scale, not the network's: filing runs the cost
   estimator once PER logged bug, so a big batch is minutes. It is only a
   backstop for a card whose daemon went away mid-flight — the server stamp
   settles the normal case (clearFilingOnState). */
var FILING = Object.create(null);
var FILING_TIMEOUT_MS = 600000;

function markFiling(id) {
  if (id == null) return;
  var key = String(id);
  if (FILING[key]) clearTimeout(FILING[key]);
  FILING[key] = setTimeout(function () { clearFiling(key); refresh(); },
    FILING_TIMEOUT_MS);
}
function clearFiling(id) {
  if (id == null) return;
  var key = String(id);
  if (FILING[key]) { clearTimeout(FILING[key]); delete FILING[key]; }
}
function isFiling(id) {
  return id != null && !!FILING[String(id)];
}

/* S162 — the statuses a `logFiling` stamp can END on. `filed` is the clean one;
   `partial` and `failed` are outcomes the captain has to see (see logFilingNote).
   `previewed` and `filing` are deliberately absent: they are both live. */
var LOG_FILING_TERMINAL = ["filed", "partial", "failed"];

/* S162 — the ONE reading of a card's mission-log filing state. The band, the
   control and the failure note all derive from this, so no two surfaces can
   describe the same session differently (the S161-D2 lesson: one builder, or the
   card and the console eventually contradict each other).

   `filing` is the union of the two halves: the client map (instant, this tab
   only) OR the server stamp (durable, survives a reload). Everything else comes
   from the stamp alone — the client knows it dispatched a filing, it does not
   know how the daemon got on, so it never guesses counts or reasons. */
function logFilingState(m) {
  var stamp = (m && m.logFiling && typeof m.logFiling === "object")
    ? m.logFiling : null;
  var status = (stamp && typeof stamp.status === "string") ? stamp.status : "";
  var num = function (v) { return typeof v === "number" ? v : null; };
  return {
    stamp: stamp,
    status: status,
    filing: !!(m && isFiling(m.id)) || status === "filing",
    terminal: LOG_FILING_TERMINAL.indexOf(status) !== -1,
    bugCount: stamp ? num(stamp.bugCount) : null,
    filedCount: stamp ? num(stamp.filedCount) : null,
    // S163 fix round 3: bugs waiting to be fixed on the MISSION, across every
    // report — the review panel's length and what `Go ▸` will drive. Absent on a
    // pre-round-3 stamp, and `null` there rather than 0, so "the daemon did not
    // say" is never read as "none".
    waitingCount: stamp ? num(stamp.waitingCount) : null,
    // the daemon's own words for a shortfall/failure. Never synthesised here.
    error: (stamp && stamp.error) ? String(stamp.error) : ""
  };
}

/* S162 — drop the optimistic flag once the SERVER has settled this filing.

   Only on a TERMINAL status, or on the stamp vanishing altogether (the session
   was discarded, or the captain's Go consumed it — either way there is nothing
   left to be filing). NOT on "anything that isn't `filing`": the board cached at
   the moment of the click still carries the session's PRE-dispatch `previewed`
   stamp, so that rule would wipe the band one frame after drawing it — the
   BUG-078 sticky-optimism lesson, which is precisely the flicker this band
   exists to remove. Mirrors clearMergingOnState. */
function clearFilingOnState(m) {
  if (!m || m.id == null || !isFiling(m.id)) return;
  var st = logFilingState(m);
  if (!st.stamp || st.terminal) clearFiling(m.id);
}

/* S163 (the "Fix Filed Bugs" follow-through): the optimistic "the captain's Go
   is dispatched" set — the third map in this family, and the same split as the
   other two (client map for the instant, server stamp for the durable).

   Why a flag is needed at all: the Go's own effects are ASYNC. `log_run` spawns
   resolve-logs fire-and-forget and returns, and it is resolve-logs — seconds
   later — that stamps each child `queued`. In that gap the board still looks
   exactly like the PRE-Go board (children filed, none driven), which is the one
   picture that must not re-offer the dispatch. This flag closes it for the tab
   that clicked; `m.logDispatch` (the daemon's additive stamp) closes it for a tab
   that reloaded.

   The timeout is the dispatch's scale, not a batch's: resolve-logs only has to
   BOOT and schedule, not finish. Two minutes is a backstop for a spawn that died
   without ever touching a child — after it the card falls back to what disk says,
   which is the honest answer when nothing else is known. */
var LOGRUN = Object.create(null);
var LOGRUN_TIMEOUT_MS = 120000;

/* S163 fix round 4 (D1) — the steers a REFUSED Go handed back.

   `Go ▸` closes the console optimistically (BUG-G: the dispatch is
   fire-and-forget and the POST returns in milliseconds), so a refusal arrives
   with nowhere to land. The refusal is the honest answer — a steer the daemon
   could not resolve must not run the bug on a model the captain did not choose —
   but a refusal that also EATS the instruction is the same loss as the silent
   drop it replaced, one click later.

   So the typed map is parked here, keyed by parent mission, and the next
   `openLog` for that parent seeds its boxes from it. One reopen (the ⚙ control
   is right there on the card) and the words are back, editable, with the
   daemon's reason echoed beside the bug they belong to. Consumed on read: it is
   a hand-off between two consoles, not a second source of truth. */
var PENDING_STEERS = Object.create(null);
function stashSteers(id, steers) {
  if (id == null || !steers) return;
  var any = false;
  for (var k in steers) { if (steers[k]) { any = true; break; } }
  if (any) PENDING_STEERS[String(id)] = steers;
}
function takeSteers(id) {
  if (id == null) return null;
  var key = String(id), held = PENDING_STEERS[key];
  delete PENDING_STEERS[key];
  return held || null;
}
/* S163 fix round 5 (D1): a REFUSAL now reopens the review by itself, so the
   opening console can no longer be the thing that consumes the stash — a
   captain who closes that reopened console and comes back through the card's
   ⚙ control would find their words gone, which is the loss the stash exists to
   prevent. The console PEEKS; only a Go the daemon ACCEPTED consumes
   (`takeSteers`, in the success callback), because only then are the words
   spent. A later Go re-stashes whatever is in the boxes anyway, so the held map
   can never go stale. */
function peekSteers(id) {
  if (id == null) return null;
  return PENDING_STEERS[String(id)] || null;
}

function markLogRun(id) {
  if (id == null) return;
  var key = String(id);
  if (LOGRUN[key]) clearTimeout(LOGRUN[key]);
  LOGRUN[key] = setTimeout(function () { clearLogRun(key); refresh(); },
    LOGRUN_TIMEOUT_MS);
}
function clearLogRun(id) {
  if (id == null) return;
  var key = String(id);
  if (LOGRUN[key]) { clearTimeout(LOGRUN[key]); delete LOGRUN[key]; }
}
function isLogRunDispatched(id) {
  return id != null && !!LOGRUN[String(id)];
}

/* Drop the optimistic flag once the SERVER shows the dispatch really happened —
   the daemon's own `logDispatch` stamp, or a child a DRIVER has visibly touched
   (queued / running), or no non-done children left at all.

   Every one of those keeps the control hidden by itself, so this can never
   flicker the control back: it hands over from one suppressing reason to
   another, exactly as clearFilingOnState hands the band over to the stamp.

   S163 fix round 1 (D1): `dispatched` used to be in that list and had to come
   OUT — it is `bool(events) || running` on the adapter, and the File & Cost
   estimator writes `worker_usage` events onto every child at filing time, so it
   is true on a batch nothing has ever driven. Reading it here was the same
   mistake as reading it in logFixState, one handover earlier: the very first
   repaint after the Go (which runs off the CACHED, pre-Go board) would have
   seen "moved", dropped the flag, and put the control back under the captain's
   cursor with resolve-logs already booting. */
function clearLogRunOnState(m) {
  if (!m || m.id == null || !isLogRunDispatched(m.id)) return;
  if (m.logDispatch) { clearLogRun(m.id); return; }
  var kids = resolvingChildren(m.id);
  if (!kids.length) { clearLogRun(m.id); return; }
  var moved = kids.some(function (c) {
    return c && (c.queued || c.running);
  });
  if (moved) clearLogRun(m.id);
}

/* ── S163: is this parent's logged-bug batch FILED BUT NOT DISPATCHED? ────────
   The ONE reading behind the card control, the detail control and their copy.

   This is the window BUG-059 creates and nothing used to serve. Filing runs the
   estimator on each bug and then STOPS, deliberately, so the captain can review
   every cost/difficulty pill and steer a model before anything runs. A captain
   who closed the console lands in that window with the review un-taken — and the
   card's only control was S77's DISABLED "◐ resolving N logged bugs…", which is
   derived from "the parent has linked, non-done, non-verify children" and is
   therefore true the instant filing completes, while nothing is running and
   nothing will run. A dead end that describes work in flight.

   Telling the two apart cannot be done from the children's EXISTENCE — both
   states have non-done, non-verify children. So it is measured, in this order:

     isLogRunDispatched   this tab clicked Go. Instant, no round trip.
     m.logDispatch        a Go for this parent HAS been dispatched (additive
                          stamp; the daemon holds it in memory AND writes it to
                          `<parent>/log-dispatch.json`, so it survives the
                          daemon — see _mark_log_dispatched). Outranked by a
                          live session, so a fresh report re-opens the review.
     logFiling status     the daemon's live session. `filed` and `partial` are
                          the window; the Go CONSUMES the session, so such a
                          stamp still on the card is positive evidence no Go has
                          been taken. `filing`/`previewed` belong to S162's band.
     the children         no session and no dispatch record — the daemon
                          restarted and its memory went with it, but the bugs are
                          real linked children on disk. A batch NO DRIVER has
                          ever touched is filed-but-idle. One child moving
                          withdraws it — the batch is running, whatever the rest
                          read.

   S163 fix round 1 (D1) — what "no driver has touched it" is allowed to mean.
   That last branch shipped reading `!c.dispatched && !c.queued && !c.running`
   and was therefore DEAD CODE in production: `dispatched` is
   `bool(events) || running` on the LocalAdapter, and File & Cost runs the
   estimator on every bug it files, whose worker logs a `worker_usage` event
   onto that child before the captain sees a single pill. So every filed child
   is `dispatched` from birth, the branch never fired, and a daemon restart —
   the exact case it existed for — dropped the captain back into S77's disabled
   lock with no route to the review at all (and since S162 File & Cost ALWAYS
   closes the console, this control is the only route there is).

   The two signals that survive are the ones a DRIVER produces: resolve-logs
   stamps `queued` on every bug it schedules, and `running` is a live driver
   lock. `dispatched` is the ESTIMATOR's footprint and answers a different
   question (BUG-062: "should this card read Start or Pause?"), which is why it
   is left exactly as it is rather than redefined.

   ── S163 fix round 2 (D1): a `partial` is IN this window ──────────────────
   The first cut keyed on a clean `filed` only, reasoning that a shortfall was
   S162's story to tell and that two statements on one card would confuse. The
   tester measured what that cost: a batch of 3 with 2 really filed showed the
   pre-S163 disabled "◐ resolving 2 logged bugs…" on card AND detail, with no
   dispatch record, nothing running and nothing that ever would.

   And the product contradicted ITSELF about it. `kill -9` the daemon, relaunch,
   change nothing on disk — the live `partial` session is simply gone — and the
   children fallback below rendered "⚙ FIX 2 FILED BUGS", live. One repo state,
   two answers, decided by how long the daemon had been up. That is the sharpest
   evidence the exclusion was wrong, and `test_the_live_session_and_the_
   restarted_daemon_agree` pins it so it cannot come back.

   So the gate is a MEASUREMENT, not a status name: `filedCount >= 1` — there is
   something filed to fix. That reading also settles `failed` without a special
   case, since `_settle_log_session` defines it as "none landed" (`partial if
   filed else failed`), so its count is 0 and it is refused here; were a future
   daemon ever to leave children on disk under a `failed`, the captain would get
   the way forward rather than the lock, which is the safe direction.

   What the widening must NOT do is bury the shortfall — S161 made "the unfiled
   text is preserved verbatim and can be retried" a ship-blocker-grade promise.
   Three things keep it: `shortfall` puts BOTH numbers in the label ("FIX 2 OF 3
   FILED BUGS", never a bare "2"), the tooltip says the missing bugs are still
   held and retryable, and S162's note is left exactly where it was so the
   daemon's own reason stays on the card underneath.

   Returns {ready, count, shortfall, source, sessionId}; `ready:false` means
   every other surface behaves exactly as it did before this session. */
/* How many of the LATEST batch never reached disk — 0 when nothing was lost, or
   when the daemon did not give both numbers (never inferred from the children,
   which cannot see a bug that was refused before it ever existed). One reader,
   because two call sites now need the same sentence. */
function logBatchShortfall(st) {
  return (st.status !== "filed" && st.bugCount != null && st.filedCount != null)
    ? Math.max(0, st.bugCount - st.filedCount) : 0;
}

function logFixState(m) {
  var none = { ready: false, count: null, shortfall: 0, source: null,
               sessionId: null, resume: false };
  if (!m || m.id == null) return none;
  // you cannot log bugs against a logged bug (BUG-046), so a bug child is never
  // the parent of a filed batch.
  if (isLogBug(m)) return none;
  if (isLogRunDispatched(m.id)) return none;
  /* S163 fix round 7 (D3): a dispatch suppresses the way forward only while the
     drive it records EXISTS. Round 6 suppressed on the record's mere presence,
     and the tester found what that costs when the resolve-logs dies: a card and
     a detail both showing a permanently disabled "◐ RESOLVING 3 LOGGED BUGS…",
     no affordance anywhere, and a 409 whose advice named an event that could not
     occur. The daemon now MEASURES the resolver process and marks a record it
     cannot evidence `stale` (see `_resolver_alive`), so a card that has stopped
     being able to prove a drive stops claiming one — and offers the resume
     instead. A live drive is untouched: `stale` is absent and this still
     returns. */
  var dispatch = (m.logDispatch && typeof m.logDispatch === "object")
    ? m.logDispatch : null;
  if (dispatch && !dispatch.stale) return none;
  var st = logFilingState(m);
  // a filing still in flight is S162's story — there is nothing to review yet.
  if (st.filing) return none;
  /* ── S163 fix round 3 (D1 + D2): the daemon's own count of WAITING bugs ────
     `waitingCount` is "how many bugs on this MISSION are still waiting to be
     fixed", across every report — the length of the review panel and, because
     `Go ▸` spawns `resolve-logs --parent`, exactly what the click will drive.
     It outranks the batch measurements below wherever the daemon publishes it,
     and it cures two measured defects at once:

       D2  the count SHRANK. A parent holding two undispatched bugs got a
           second, 1-bug report; `filedCount` described that batch, so the card
           read "⚙ FIX 1 FILED BUG" while three bugs waited and the Go ran all
           three.
       D1  an un-filed second report HID the first. A `previewed`/`failed`
           stamp returned none here, so two bugs sitting on disk lost their only
           route to the review — and the only way back was `Discard Preview`,
           which destroys the unfiled bugs' authored text.

     A stamp with no `waitingCount` is a pre-round-3 shape (or a hand-built
     fixture); everything below is unchanged for it. */
  /* S163 fix round 7 (D2): the MISSION-level count, published on every parent
     card that has bugs waiting — session or no session, read-write board or
     view-only. It outranks the session stamp's copy of the same number (they
     come from the same `_waiting_children` call, so they cannot disagree; this
     just makes which one is read unambiguous) and, more importantly, it is
     present in the case that broke: a clean `filed` batch leaves no durable
     record, so a restarted daemon published nothing and the card fell through
     to counting children with a looser rule than the daemon's. */
  var pub = typeof m.logWaitingCount === "number" ? m.logWaitingCount : null;
  if (pub != null && pub > 0) {
    return { ready: true, count: pub, shortfall: logBatchShortfall(st),
             source: st.stamp ? "session" : "children",
             sessionId: (st.stamp && st.stamp.sessionId) || null,
             // S163 fix round 7 (D3): a run over bugs a DEAD drive already took
             // is a resume, and the daemon will only grant it as one — so the
             // control has to know, and its Go has to say so on the wire.
             resume: !!dispatch };
  }
  if (pub === 0) return none;   // the daemon measured, and nothing is waiting.
  if (st.stamp && st.waitingCount != null) {
    if (st.waitingCount > 0) {
      return { ready: true, count: st.waitingCount,
               // the shortfall is still THIS BATCH's fact, so it is still read
               // from this batch's two numbers. n + shortfall then reads as
               // "bugs authored against this mission and not yet fixed", of
               // which n are on disk — true in the one-report case the label
               // was written for and true beside older waiting bugs too.
               shortfall: logBatchShortfall(st),
               source: "session", sessionId: st.stamp.sessionId || null,
               resume: !!dispatch };
    }
    // waitingCount === 0 — nothing on this mission is waiting. Fall through: the
    // children measurement below says the same thing and refuses too, and a
    // `failed` stamp must still not speak for children it never touched.
  }
  if (st.stamp && st.terminal) {
    // How many bugs THIS batch got onto disk. At `filed` the three sources
    // agree, so the old precedence stands. At `partial` `bugCount` is the WHOLE
    // batch — using it would be the exact overstatement this fix exists to
    // prevent — so only the measured `filedCount`, or the children, may answer.
    var n = st.filedCount != null ? st.filedCount
          : (st.status === "filed" && st.bugCount != null
              ? st.bugCount : resolvingChildren(m.id).length);
    if (n) {
      // ...and how many did NOT land. Stated only when BOTH numbers are the
      // daemon's (never inferred from the children, which cannot see a bug that
      // was refused before it ever existed).
      var missing = logBatchShortfall(st);
      return { ready: true, count: n, shortfall: missing, source: "session",
               sessionId: st.stamp.sessionId || null, resume: !!dispatch };
    }
    // n === 0 — this batch put NOTHING on disk (`failed`, by the daemon's own
    // definition). S163 fix round 2, the third face of D1, measured live on the
    // real daemon after the first two were cured: a parent holding a
    // filed-but-never-dispatched batch showed "⚙ FIX 4 FILED BUGS", then a
    // SECOND report whose bugs were all refused flipped the same card back to
    // the disabled "◐ resolving 4 logged bugs…" — with those four children
    // untouched throughout, and a restart flipping it straight back again.
    //
    // A stamp is authoritative about the batch IT describes. One that landed
    // nothing describes nothing on disk, so it must not speak for what was
    // already there: fall through to the children measurement, which is exactly
    // what a restarted daemon reads. S162's failure note still renders beside
    // whatever that says, so the refusal is reported either way.
  } else if (st.stamp) {
    // `previewed` on a PRE-round-3 stamp — a live console is authoring against
    // this parent and the daemon has not told us what is waiting. Reached only
    // for a stamp with no `waitingCount` (the branch above answers otherwise),
    // so this is the old bound preserved for the old shape, not a live rule:
    // round 3 measured that this branch could bury bugs already on disk (D1).
    return none;
  }
  // ...but ONLY where those fields are measurements. On a github board they are
  // hardcoded placeholders (see BOARD_ADAPTER), so "no driver has ever touched
  // this batch" is a thing that view cannot establish — and a card must not
  // state what it cannot know. There the S77 lock, which needs only the
  // children's stages, keeps the card.
  if (BOARD_ADAPTER === "github") return none;
  /* S163 fix round 7 (D2): the SAME measurement the daemon takes — see
     `waitingChildren`. `resolvingChildren` was the wrong list here (it keeps a
     child parked at its `verify` gate), which is how the card came to promise
     two bugs over a panel of one. A batch where a driver has visibly touched
     something still withdraws the control outright rather than counting the
     remainder: that batch is in flight, and offering a partial re-run of it is
     the double dispatch this round spent two rounds closing. */
  var kids = waitingChildren(m.id);
  if (!kids.length) return none;
  var touched = resolvingChildren(m.id).some(function (c) {
    return c && (c.queued || c.running);
  });
  if (touched) return none;
  // shortfall 0, and that is not a claim that nothing was lost — it is the
  // absence of one. With the session gone the daemon cannot know a third bug was
  // ever authored, so the card counts what it can see and says no more (the
  // S160/S161 rule: never state what the code cannot know). This is also exactly
  // why the agreement test compares the VERDICT, not the wording.
  return { ready: true, count: kids.length, shortfall: 0, source: "children",
           sessionId: null, resume: !!dispatch };
}

/* Park & Align (F2 — resume mid-grill): the client-side resumable map {missionId: sid}.
   Closing an Align console mid-grill KEEPS the warm session (no /cancel) and marks its
   parked mission resumable so the card flips to "▹ RESUME ALIGN" instantly. A card can
   ALSO carry the server's `m.alignResume` (the board overlay) so RESUME survives a page
   reload — resumableSid()/isResumable() read both. In-memory (dies with the tab). */
var RESUMABLE = Object.create(null);
function markResumable(id, sid) {
  if (id != null && sid) RESUMABLE[String(id)] = sid;
}
function clearResumable(id) {
  if (id != null) delete RESUMABLE[String(id)];
}
function resumableSid(m) {
  if (!m || m.id == null) return null;
  var client = RESUMABLE[String(m.id)];
  if (client) return client;
  if (m.alignResume && m.alignResume.sid) return m.alignResume.sid;
  return null;
}
function isResumable(m) { return !!resumableSid(m); }

/* BUG-3: the single in-flight START-ALIGNMENT open ({id}). Closing/cancelling the
   BUG-3: a one-shot "on next overlay close" callback — null for ordinary modals,
   set by renderAlignConsole to POST cancel its warm align session on ✕/backdrop/
   Esc (all route through closeOverlay). Closing an unrelated overlay never aborts an
   in-flight START-ALIGNMENT open — the click-guard (isAligning) already prevents
   duplicate spawns, so the console simply opens when its worker turn returns. */
var onOverlayClose = null;

/* F1: is the Align grilling console currently the open overlay? Set when
   renderAlignConsole shows it, cleared in closeOverlay. The finalize-done path reads
   it to decide modal-vs-silent: if the captain backgrounded the console, skip the
   "Alignment Reached" modal and let the board refresh show the aligned card. */
var alignConsoleOpen = false;

/* FIX-A: the last board payload render() drew, cached so the aligning flow can force
   an INSTANT client-only repaint. Parking/aligning changes no server state, so no SSE
   tick is guaranteed — without this the persistent scanning band would only appear (or
   clear) on the next unrelated refresh. render() only rebuilds #board (never an open
   overlay), so re-rendering while a modal is up is safe. */
var LAST_BOARD = null;
function repaintBoard() { if (LAST_BOARD) render(LAST_BOARD); }

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

/* S196 A3(g) — "copilot · mission pin", in words, from RECORDED fields only.

   `engineSource` and `engineResolved` are written by whichever producer made the
   choice, at the moment it made it: `lcars adopt` when the captain picks the
   engine at the handoff, run.sh's resolver when it resolves for a run. This
   function only NAMES what they say — it never re-derives which source would
   have won by reading config, which is the inference S147/S156/S188 each paid
   fix rounds for. An unknown source is printed verbatim rather than swallowed:
   a source this front end has not heard of is still a fact, and hiding it would
   put the board back where it started.

   Null when nothing is recorded, so a pre-S196 card is unchanged. */
var ENGINE_SOURCE_WORDS = {
  "mission":         "mission pin",
  "config":          "repo config",
  "env":             "$LCARS_WORKER_BIN",
  "detected":        "host CLI",
  "default":         "default",
  "adopt-kept":      "mission pin · kept at adopt",
  "adopt-converted": "converted at adopt",
  "adopt-chosen":    "chosen at adopt"
};
function engineProvenanceLine(m) {
  var src = String((m && m.engineSource) || "");
  if (!src) return null;
  var eng = String((m && m.engineResolved) || (m && m.engine) || "");
  var why = ENGINE_SOURCE_WORDS[src] || src;
  return eng ? (eng + " · " + why) : why;
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

/* S140 — machine-readable identity for an EXISTING control, so the keyboard
   command deck can resolve and `.click()` the very same button the mouse would.
   ATTRIBUTE-ONLY: it changes nothing about how a control looks, gates, or
   behaves — which is precisely what makes a hotkey gated identically to its
   button (an absent or disabled control is a silent no-op). */
function act(name, node) {
  if (node) node.setAttribute("data-act", name);
  return node;
}

/* S140 — a SPAN rendered as a control (the File console's engine picker, the
   pasted-image ✕) is unreachable by keyboard: no tab stop, no activation key.
   This is the card focus model applied to one node — role="button" + tabindex=0
   (so Tab lands on it and board.css's amber :focus-visible ring shows it) plus
   the WAI-ARIA button pattern's two activation keys.

   ATTRIBUTE + KEY ONLY: Enter/Space `.click()` the very node the mouse clicks,
   so the control's own handler is the single implementation — no second code
   path, no new write path, nothing about the click flow changes. Modifier chords
   stay with the browser, and every OTHER key (Escape above all) keeps bubbling
   to the global listeners; only the key we consumed stops here, which is what
   keeps the command deck from ALSO acting on an activation. */
function keyActivable(node) {
  if (!node) return node;
  node.setAttribute("role", "button");
  node.setAttribute("tabindex", "0");
  node.addEventListener("keydown", function (e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key !== "Enter" && e.key !== " ") return;
    e.preventDefault();
    e.stopPropagation();
    node.click();
  });
  return node;
}

/* ════════════════ CARD RENDER ════════════════ */
function cardNode(m) {
  var rs = runState(m); // UX-17/20/21: derived run/pause lifecycle (one source).
  // S162: reconcile the optimistic "filing" flag with what the server now says,
  // BEFORE anything reads it — so the band, the control and the failure note all
  // render off one settled answer within a single card build.
  clearFilingOnState(m);
  // S163: and the same for the optimistic "the Go is dispatched" flag, so the
  // control, the S77 lock and the copy are all decided from one settled answer.
  clearLogRunOnState(m);
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
  // S190: this mission is DEMONSTRABLY someone else's. A marker class only —
  // the stylesheet dims the (already disabled) control row so the card reads as
  // "you can watch this, you cannot drive it" from across the room. Absent for
  // an unassigned mission, for my own, and whenever identity is unresolvable,
  // so a board with no identity on it carries no new class at all.
  if (ownerLockLogin(m)) card.className += " owned-by-other";
  // S191: …and this one is not driven from here at all. A marker class only —
  // the stylesheet gives the card its cool "somewhere else" chrome; the controls
  // are disabled by remoteControls below, never by CSS.
  if (isRemote(m)) card.className += " remote";
  // UX-10/UX-16: id handle so a closed modal (Start) can stamp a transient busy
  // animation onto this card (showCardBusy).
  if (m.id != null) {
    card.setAttribute("data-mid", String(m.id));
    // S140: the card is the keyboard command deck's focus target. role/tabindex
    // put it in the tab order and make Enter-to-open read correctly to assistive
    // tech; the whole card was already click-to-open, so this is attribute-only.
    card.setAttribute("role", "button");
    card.setAttribute("tabindex", "0");
  }

  // Engine watermark (Copilot / Claude) in the top-right corner. Decorative,
  // semi-transparent; null when the engine is unknown.
  var badge = engineBadge(m);
  if (badge) card.appendChild(badge);

  var issue = m.issue ? "#" + m.issue : "—";
  card.appendChild(el("div", "no", issue + " · lcars:" + m.stage));
  // S196 A3(g): the ENGINE and WHERE IT CAME FROM, on the card, in words.
  // The corner watermark says WHICH cli; it has never said WHY, and "why" is the
  // half that costs money — a mission filed on copilot and silently re-homed onto
  // billed claude by a clone's config.json looked identical to one that chose
  // claude on purpose. A second meta line rather than more text on the first, so
  // `#34 · lcars:verify` stays byte-identical, and ABSENT entirely for a mission
  // that has recorded no provenance (every pre-S196 card renders as before).
  var prov = engineProvenanceLine(m);
  if (prov) card.appendChild(el("div", "no engine-src", prov));
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

  // S190: WHOSE MISSION IS THIS — the avatar + handle pill, under the title and
  // above the estimate pills, so "who" reads before "how much". Null (and so
  // nothing appended) whenever the payload carries no owner, which is what keeps
  // every card on an identity-free board byte-identical to before this round.
  var own = ownerNode(m);
  if (own) card.appendChild(own);

  var pills = el("div", "pills");
  // S191: WHERE is this being driven — first in the row, because a card you
  // cannot act on has to say so before it says anything else.
  if (isRemote(m)) pills.appendChild(remotePill());
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
  } else if (m.prdPending) {
    // Park & Align (S137): a PARKED mission is pre-PRD standby — filed via
    // `lcars file --park`, no grill run yet, so it has NO estimate. Show a
    // themed ship-status STANDBY badge (Trek voice) INSTEAD of estimate pills;
    // the estimate pills appear once the alignment grill completes and the
    // estimator runs (the SSE refresh swaps in the normal aligned card).
    pills.appendChild(el("span", "pill standby", "◇ STANDBY · AWAITING ALIGNMENT"));
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
    var stop = act("launch-stop", btn("■", "pill-stop", function (e) {
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
    }));
    stop.title = "Stop the app";
    applyWriteState(stop); // view-only boards disable it (and set the view-only title)
    livePill.appendChild(stop);
    pills.appendChild(livePill);
  } else if (m.launch && m.launch.status === "launching") {
    // Informational only — matches the dialog, which offers STOP only once running.
    pills.appendChild(el("span", "pill", "▶ LAUNCHING…"));
  }
  // S160: the base-freshness badge. Additive and condition-gated — the adapter
  // sends `baseFreshness` ONLY for a record the guard carried LOUD, so a card
  // with a healthy (or quietly-handled) base is byte-identical to before this
  // round. It rides the pill row rather than a band of its own: it is a
  // property OF this Mission (the tree it was cut from), not of the board.
  var bfp = baseFreshnessPill(m.baseFreshness);
  if (bfp) pills.appendChild(bfp);
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

  // S162: a mission-log filing that ended in a shortfall or a refusal. The
  // captain may have closed the console on dispatch, so the card is the surface
  // that has to say so — never a band that simply stops. Condition-gated on a
  // terminal-but-not-clean session (logFilingNote returns null otherwise), so a
  // card with no live log session is byte-identical to before this round.
  var lfNote = logFilingNote(m);
  if (lfNote) card.appendChild(lfNote);

  if (m.progress) {
    var prog = el("div", "progress");
    var bar = el("div", "bar");
    var done = m.progress.ticketsDone || 0;
    var total = m.progress.ticketsTotal || 0;
    var pct = total > 0 ? Math.round((done / total) * 100) : 0;
    var fill = el("i"); fill.style.width = pct + "%"; bar.appendChild(fill);
    prog.appendChild(bar);
    prog.appendChild(el("div", "lab", m.progress.label || ""));
    // S178: the wave SHAPE beside the wave COUNT. "14 WAVES · 1 TICKET EACH —
    // NO PARALLELISM" is a signal the captain can act on; "WAVE 1/14" is not.
    // Additive and condition-gated — a payload with no `shape` (every pre-S178
    // adapter, and the GitHub adapter, which serves no progress at all) renders
    // byte-identically to before.
    if (m.progress.shape) {
      var shapeCls = "shape" + (/NO PARALLELISM/.test(m.progress.shape) ? " serial" : "");
      prog.appendChild(el("div", shapeCls, m.progress.shape));
    }
    card.appendChild(prog);
  }

  if (m.tickets && m.tickets.length) {
    card.appendChild(cardTickets(m.tickets));
  }

  // UX-13/UX-20: live "running" pulse — shown ONLY when truly in flight (running
  // && !paused; optimistic-start counts). Suppressed while pausing/paused so a
  // halting card never shows motion. Client-side animation only.
  if (isInFlight(m)) card.appendChild(runningPulse(stageLabel(m.stage), m.liveness));
  // F1: a parked mission whose closing turn is FINALIZING server-side (estimate +
  // file.sh --complete) gets an animated "◐ Finalizing & costing…" band the whole
  // time — even after the captain backgrounds the console — until the board refresh
  // swaps in the aligned card. Precedence: finalizing > scanning.
  // S169/FL-017: …and on a RELOADED tab the same band comes back off the
  // daemon's `alignFinalizing`, so a card whose mission is still costing does
  // not re-arm itself under a live file.sh.
  else if (alignFinalizeState(m).finalizing) card.appendChild(finalizingPulse(m));
  // FIX-A: a parked mission mid-scan (START ALIGNMENT clicked, warm grill opening)
  // gets the SAME persistent animated band — rendered on every repaint while
  // isAligning so the motion survives board rebuilds until the console opens.
  // S128/FL-009: …and on a RELOADED tab the same band comes back off the
  // daemon's `alignBusy`, so the card a captain returns to still reads as live.
  else if (alignScanState(m).scanning) card.appendChild(scanningPulse(m));
  // S162: the mission-log filing band is deliberately OUTSIDE that chain. Those
  // three are one mission's own state (it is either running, finalizing its
  // Align, or opening a grill); a log filing is work on that mission's CHILDREN,
  // on its own clock, and a card can honestly be doing both at once. Chaining it
  // would make one of the two states silently invisible.
  if (logFilingState(m).filing) card.appendChild(filingPulse());

  // ── inline controls (mock #card .card-ctrl): stage-appropriate write actions
  // S190: …swept by the light lock AFTER they are built. See applyOwnerLock for
  // why this is a sweep and not a check inside each of cardControls' branches.
  // S191: …and then swept AGAIN for a REMOTE mission, which is a different fact
  // from S190's lock and can be true when the lock is not: a mission I OWN,
  // driving on my other laptop, passes ownerLockLogin (the owner IS me) and must
  // still be read-only here. Two sweeps, two facts, neither one covering for the
  // other. remoteControls also adds the one live control a remote card gets.
  card.appendChild(remoteControls(applyOwnerLock(cardControls(m), m), m));

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
  // S162: the disabled ◐ FILING & COSTING… affordance, rendered BEFORE the
  // stage-appropriate control and never INSTEAD of it — a log filing is news
  // about this mission's children, so the mission's own action (verify gate,
  // Pause, START ALIGNMENT…) is untouched. Every branch below appends to this
  // same host, so both survive whichever one runs. Absent with no filing in
  // flight, which is what keeps an unaffected card byte-identical.
  var lfCtrl = logFilingControl(m);
  if (lfCtrl) ctrl.appendChild(lfCtrl);
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
    var reBtn = act("reapprove", applyWriteState(btn("✓ Reapprove ▸", "go", function () {
      doReapprove(m.id, ctrl, reBtn, m.reconcileStatus);
    })));
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
    var retryBtn = act("retry-merge", applyWriteState(btn("↻ Retry merge ▸", "danger", function () {
      doReapprove(m.id, ctrl, retryBtn, m.reconcileStatus);
    })));
    ctrl.appendChild(retryBtn);
    return ctrl;
  }
  if (m.awaiting) {
    // BUG-042: an escalated reconcile is an awaiting-human DESIGN CALL, not a
    // "Review PR". Label its action so it reads as a design decision (the dialog
    // — openRespond/openVerify gate — presents the question text). Suppress Merge.
    var alabel = isReconcileEscalated(m) ? "◆ Make the call ▸" : "Answer ▸";
    ctrl.appendChild(act("answer", applyWriteState(btn(alabel, "danger", function () {
      openRespond(m.id);
    }))));
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
    // S163: the one gated kind that is nonetheless LIVE. It is not the mission's
    // own Verify action (Merge/Accept stay suppressed — there are unfixed bugs
    // filed against this mission), it is the way forward for its logged-bug
    // batch: reopen the cost review the captain skipped by closing the console.
    if (aff.kind === "fix-filed") {
      ctrl.appendChild(fixFiledControl(m, aff));
      return ctrl;
    }
    // S163 fix round 2 (D2): a gated kind that deliberately draws NOTHING —
    // the filing window, whose one honest statement (◐ FILING & COSTING…) was
    // already appended above by logFilingControl. Returning here rather than
    // falling through is what keeps the card from carrying both.
    if (aff.suppress) return ctrl;
    if (aff.kind !== "action") {
      var gated = act("verify", btn(aff.label, aff.cls, null));
      gated.disabled = !!aff.disabled;
      if (aff.title) gated.title = aff.title;
      ctrl.appendChild(gated);
      return ctrl;
    }
    ctrl.appendChild(act("verify", applyWriteState(btn(aff.label, aff.cls, function () {
      openVerify(m.id);
    }))));
  } else if (rs === "paused") {
    // UX-22: RESUME stays at FULL prominence on a dimmed card — the .pause-action
    // class excludes it from the .paused dim overlay.
    var resume = act("resume", applyWriteState(btn("▶ Resume", "go", function () {
      dispatchCardBusy(m.id, "/api/mission/" + enc(m.id) + "/resume", {},
        ctrl, "Re-engaging warp core…");
    })));
    resume.className += " pause-action";
    ctrl.appendChild(resume);
  } else if (rs === "pausing") {
    // UX-21: pause requested but a driver is still live — it will stop at the
    // next safe boundary. No Pause (already requested) and no Resume yet (still
    // running); show a disabled, full-contrast "Pausing…" affordance.
    var pausing = act("pause", btn("◐ Pausing…", "warn pause-action", null));
    pausing.disabled = true;
    pausing.title = "Pause requested — stopping at the next safe boundary.";
    ctrl.appendChild(pausing);
  } else if (rs === "running") {
    // UX-13: a live drive is advancing this mission — offer Pause, never Start.
    // UX-17: while OPTIMISTICALLY starting (clicked Start, running not yet true)
    // the Pause button stays disabled so the captain can't pause a half-spawned
    // driver; it enables once the real running flag arrives.
    var pause = act("pause", applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCardBusy(m.id, "/api/mission/" + enc(m.id) + "/pause", {},
        ctrl, "Holding station…");
    })));
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
    var queuedAff = act("start", btn("◷ Queued…", "warn", null));
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
    ctrl.appendChild(act("pause", applyWriteState(btn("⏸ Pause", "warn", function () {
      dispatchCardBusy(m.id, "/api/mission/" + enc(m.id) + "/pause", {},
        ctrl, "Holding station…");
    }))));
  } else if (m.prdPending) {
    // Park & Align (S137): a PARKED mission has NO PRD, so it must NEVER be
    // runnable — a plain "▶ Start" launches a RUN via the Launch panel. Offer
    // "▹ START ALIGNMENT" instead: it opens the warm grill console seeded from
    // the parked mission (align_start with its missionId); on grill completion
    // the SSE refresh swaps this standby card for a normal aligned card. BUG-3:
    // startAlignmentControl renders the disabled "⊹ Scanning…" busy-guard while
    // the open is in flight so a repaint can't offer a re-click (double-spawn).
    ctrl.appendChild(startAlignmentControl(m));
  } else {
    // align (and any pre-run stage): Start launches the run via the Launch panel
    ctrl.appendChild(act("start", applyWriteState(btn("▶ Start", "go", function () {
      openLaunch(m.id);
    }))));
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
    a.href = ghIssueUrl(detailRepo, ref.issue);
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
  // S140: a full rebuild would drop the keyboard focus — note which card has it.
  var keepFocus = focusedMissionId();
  LAST_BOARD = board; // FIX-A: cache for forced client-only repaints (scanning band).
  indexIssues(board); // UX-28: refresh the id→issue index for parent resolution.
  // BEFORE a single card is built: cardNode → logBugBadge needs the repo + forge
  // host to make its badge a LINK. renderMeta below sets the same two, but it
  // runs after this loop, which on a first paint left the badge a dead <span>.
  captureForgeIdentity(board.meta);
  var root = document.getElementById("board");
  root.innerHTML = "";
  /* S184 — THE FRONT DOOR REPLACES THE BOARD. Decided before a single column is
     built, so on a day-zero repo there are literally NO columns in the DOM: the
     captain is not looking at a pipeline he cannot use. Re-decided on EVERY
     render, so the door lifts by itself the moment the initialization mission
     lands (an SSE tick, nothing to reload) — the same way S183's lock lifts. */
  var onFrontDoor = frontDoorActive(board);
  setFrontDoorMode(onFrontDoor);
  if (onFrontDoor) {
    renderFrontDoor(board.meta.frontDoor);
  } else {
    var fdHost = frontDoorHost();
    if (fdHost) { fdHost.innerHTML = ""; fdHost.hidden = true; }
  }
  if (!onFrontDoor) STAGE_META.forEach(function (meta) {
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
  restoreCardFocus(keepFocus); // S140: keyboard focus survives the rebuild.
  var n = (board.missions || []).length;
  // S163 fix round 5: the ROUTINE line. It describes the board, so it yields to
  // a verdict an action has just reported — this write is what erased a refusal
  // 33 ms after it appeared.
  setIdleStatus(n + " active mission" + (n === 1 ? "" : "s"));
  renderEmptyState(n); // S141: a cold board teaches itself (the ? mention).
  renderMeta(board.meta);
  renderMainDeploy(board.meta);
  renderVersionBanner(board.meta && board.meta.version);
  renderRemoteNote(board.meta && board.meta.remote);
  renderTestReadiness(board.meta && board.meta.testReadiness);
  /* S183: the FOUNDATION LOCK. On EVERY render, so it lifts as well as locks —
     an initialization mission landing (S185) clears meta.foundation and the
     board unlocks itself on the next SSE push, with nothing to reload. */
  paintFoundationLock(board.meta && board.meta.foundation);
  /* S128 (FL-002): the ⬡ HOLODECK band control's activity indicator, from the
     daemon's own `meta.holodeck`. On EVERY render, so it clears as well as
     lights — and off the board payload, because the board is the surface a
     captain who walked away from a running program is actually looking at. */
  renderHolodeckActivity(board.meta && board.meta.holodeck);
  // S146: an open File console's inline readiness block re-verdicts LIVE off
  // every render (SSE included) — the warning clears in place, the typed idea
  // survives (the hook repaints only its own block, never the console).
  if (fileReadinessSync) {
    fileReadinessSync(board.meta && board.meta.testReadiness);
  }
}

/* S139: the local main-deploy band. Renders the deploy status FROM
   board.meta.mainLaunch into the topbar #mainDeploy host on EVERY render, so SSE
   keeps every browser in sync (the ▸ Deploy Main POST's settled return drives the
   immediate flip). The ▸ Deploy Main button is a static topbar control (always
   present, opens the deploy modal); this host shows the LIVE state beside it,
   mirroring the per-mission launchAffordance state machine:
     absent / none / stopped → empty host (just the ▸ Deploy Main button);
     launching → a busy ◐ DEPLOYING… pill;
     running   → ● MAIN LIVE + short sha + clickable url + ■ STOP (confirmless);
     failed    → a themed plain-English message (▸ Deploy Main is the retry).
   Star Trek voice, never a CI widget. Depends only on the board shape. */
// Client-side transient: set the instant ■ STOP is clicked, so every re-render
// (SSE tick, refresh) during the BLOCKING stop shows a disabled ◐ STOPPING…
// instead of recreating a fresh, clickable STOP — you can't smack stop twice.
// It clears itself the moment the board leaves the running state (stopped/
// absent/failed) or the stop request errors.
var mainDeployStopping = false;
function renderMainDeploy(meta) {
  var host = document.getElementById("mainDeploy");
  if (!host) return;
  host.innerHTML = "";
  var ml = meta && meta.mainLaunch;
  var status = ml && ml.status;
  // Once the deploy is no longer running, the stop has landed (or never was) —
  // drop the transient so a future deploy's STOP is clickable again.
  if (status !== "running") mainDeployStopping = false;
  // The ▸ Deploy Main button and the live status are MUTUALLY EXCLUSIVE: while a
  // deploy is spinning up or live, the status pill REPLACES the button in place
  // (captain UX ruling) — you don't deploy what's already deployed. Any other
  // state (absent / stopped / failed) shows the button so you can (re)deploy /
  // retry. Toggling display keeps the button's band slot, so the status pill
  // lands exactly where the button was.
  var mainBtn = document.getElementById("deployMainBtn");
  var active = status === "launching" || status === "running";
  if (mainBtn) mainBtn.style.display = active ? "none" : "";
  // absent / stopped ⇒ nothing beside the button (byte-identical to today).
  if (!ml || !status || status === "stopped") return;
  if (status === "launching") {
    host.appendChild(el("span", "deploy-pill deploying", "◐ DEPLOYING…"));
    return;
  }
  if (status === "running") {
    // ● MAIN LIVE and ■ STOP are ONE integrated segmented capsule (captain UX
    // ruling): the teal status segment + a fused maroon STOP on its right edge,
    // sharing the pill's rounded ends (the .deploy-live wrapper clips them).
    var seg = el("span", "deploy-live");
    var live = el("span", "deploy-pill live");
    live.appendChild(document.createTextNode("● MAIN LIVE"));
    if (ml.sha) live.appendChild(el("span", "sha", " " + ml.sha));
    seg.appendChild(live);
    if (mainDeployStopping) {
      // stop already in flight — a disabled STOPPING… segment, NOT a button, so
      // it survives re-renders and can't be clicked again.
      var stopping = el("span", "btn danger deploy-stop deploy-stopping",
                        "◐ STOPPING…");
      seg.appendChild(stopping);
    } else {
      // ■ STOP is cheap/reversible → confirmless; a view-only build disables it
      // via applyWriteState. First click flips to STOPPING… immediately (a
      // re-render honours mainDeployStopping) so a second click can't land.
      var stop = applyWriteState(btn("■ STOP", "danger", function () {
        mainDeployStopping = true;
        renderMainDeploy(meta);
        postWrite("/api/deploy/main/stop", {},
          function () { /* SSE/refresh will show the stopped board */ },
          function (msg) {
            mainDeployStopping = false;
            renderMainDeploy(meta);
            // S163 fix round 5: a VERDICT — the band reverts to ■ STOP on the
            // line above, so without this the screen shows a deploy still
            // running and no word of the stop that was refused.
            setVerdict(msg, "err");
          });
      }));
      stop.classList.add("deploy-stop");
      seg.appendChild(stop);
    }
    host.appendChild(seg);
    if (ml.url) {
      var a = el("a", "deploy-url");
      a.href = ml.url; a.target = "_blank"; a.rel = "noopener";
      a.textContent = ml.url;
      a.addEventListener("click", function (e) { e.stopPropagation(); });
      host.appendChild(a);
    }
    return;
  }
  // failed (or any other terminal): surface the plain-English message; the
  // ▸ Deploy Main button is the retry affordance.
  var msg = (ml && ml.message) || "the main deploy failed.";
  host.appendChild(el("span", "deploy-pill failed", "⚠ " + msg));
}

/* S139: the ▸ Deploy Main modal — an optional-instructions input + a DEPLOY
   action that POSTs /api/deploy/main {hint}. Mirrors the launchAffordance hint
   idiom; the band (renderMainDeploy) then flips to ◐ DEPLOYING… → ● MAIN LIVE on
   the settled return / SSE. CLI parity (ADR-002): nothing here that
   `lcars launch --main` doesn't already do. */
function openDeployMain() {
  var m = modal("▸ Deploy Main");
  var intro = el("div", "dim");
  intro.style.cssText = "margin-bottom:10px;font-size:13px;line-height:1.4";
  intro.textContent = "Bring the local main HEAD onto the viewscreen — the "
    + "build already merged on this machine (no fetch).";
  m.body.appendChild(intro);
  var hint = el("input", "launch-hint"); hint.type = "text";
  hint.placeholder =
    "Optional — name the app or its directory (e.g. “the game in web/”)";
  hint.style.cssText = "width:100%;box-sizing:border-box";
  m.body.appendChild(field("Instructions (optional)", hint));
  var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);
  var busy = workingNode("Bringing main online…"); busy.hidden = true;
  m.body.appendChild(busy);
  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  var go = applyWriteState(btn("▸ Deploy", "go", function () {
    var h = (hint.value || "").trim();
    go.disabled = true; go.textContent = "Deploying…";
    err.hidden = true; busy.hidden = false;
    postWrite("/api/deploy/main", { hint: h },
      function () { closeOverlay(); refresh(); },
      function (msg) {
        go.disabled = false; go.textContent = "▸ Deploy";
        busy.hidden = true; showErr(err, msg);
      });
  }));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  hint.focus();
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

/* ════════════════ S146: TEST-READINESS (banner + File-console fix) ════════
   Driven purely by the ADDITIVE board.meta.testReadiness block
   ({status: missing|broken|unknown, suggestion, testCommand}) — ABSENT on a
   ready repo, so a ready board renders byte-identically to before this round.
   Two voices, never blurred (captain ruling):
     repair    (broken/missing) — "⚠ TEST SYSTEMS OFFLINE" + the ⚡ FIX action;
     bootstrap (unknown)        — a greenfield repo reads as calm STATUS
                                  (S183: an INITIALIZATION mission's engineering
                                  crew will establish them), never an alarm.
   The fix is ONE POST (/api/config/fix-tests → update.sh --fix-tests:
   suggest-or-discover → set → probe → verdict). Filing/parking are NEVER
   blocked by any readiness state. */
function readinessCopy(tr) {
  /* S183 FIX ROUND 1 (D3) — READ THE FOUNDATION, which rides in the SAME
     payload. This function branched on `status === "unknown"` alone, and
     `unknown` is three different repos: a `git init`, a repo full of code with
     no test system, and — MEASURED — an npm-workspaces monorepo whose three
     packages all run vitest, which the board told "◇ NO TEST SYSTEMS FOUND …
     Start it with Establish Vision" while ▦ FILE MISSION sat enabled beside it.
     The CLI readiness line was already cured on this axis; the board was not.

     The foundation is consulted FIRST because it is the honest axis and because
     it is what the band controls are locked on: a repo whose ▦ FILE MISSION is
     disabled must not also be offered a "detected candidate" (the npm-default
     `"test": "echo … && exit 1"` placeholder reads `missing` + `untested`, and
     saying both is telling the captain two different stories about one repo).
     `unconfigured` from `broken` / `missing` / `ambiguous` keeps its own
     shipped voice below — those states were never wrong. */
  var fnd = tr && tr.foundation;
  if (fnd === "untested") {
    return {
      voice: "bootstrap",
      line: "◇ NO TEST SYSTEM FOUND — this repo has code, and nothing to prove "
          + "a change with.",
      sub: "Start with Establish Vision — normal missions unlock when the "
         + "foundation lands.",
    };
  }
  if (tr && tr.status === "unknown" && fnd === "unconfigured") {
    /* The repo HAS a test system; LCARS just has no command for it. That is the
       `lcars update --test-command` case — the repair voice, worded the way the
       CLI line words it, never the bootstrap one. */
    return {
      voice: "repair",
      line: "⚠ TEST SYSTEMS OFFLINE — this repo HAS a test system but no test "
          + "command is configured; missions cannot be proof-gated.",
      sub: tr.foundationWhy ? "found: " + tr.foundationWhy : "",
    };
  }
  if (tr && tr.status === "unknown") {
    return {
      voice: "bootstrap",
      /* S183: the same calm bootstrap voice, with the promise it can actually
         keep. A normal Mission is refused on this repo (the foundation gate);
         what establishes the test systems is an INITIALIZATION mission's crew,
         launched from Establish Vision. */
      line: "◇ NO TEST SYSTEMS FOUND — the first mission here is an "
          + "initialization mission, and its engineering crew will establish "
          + "them.",
      sub: "Start it with Establish Vision — normal missions unlock when it "
         + "lands.",
    };
  }
  /* S147: AMBIGUOUS is its own voice — a THIRD state, never blurred into the
     other two. This repo is NOT greenfield: it HAS test systems, several of
     them, and LCARS refuses to choose. Telling the captain "the crew will
     establish them" would be a lie on a repo that already has real test
     infrastructure. It carries the repair voice's styling (a captain CAN
     resolve it) but a different AFFORDANCE: `choices` are the detected
     candidate commands, rendered as one-click picks. ⚡ FIX is deliberately
     NOT offered here — on this state it posts /api/config/fix-tests, which
     dispatches a PAID discovery worker to make the very choice the line just
     said LCARS would not make. */
  if (tr && tr.status === "ambiguous") {
    return {
      voice: "repair",
      line: "⚠ MULTIPLE TEST SYSTEMS DETECTED — LCARS will not choose for you; "
          + "missions cannot be proof-gated until one is selected.",
      sub: tr.stacks ? "candidates: " + tr.stacks : "",
      choices: (tr.candidates && tr.candidates.length) ? tr.candidates : null,
    };
  }
  var sub = "";
  if (tr && tr.status === "broken" && tr.testCommand) {
    sub = "configured runner not found: " + tr.testCommand;
  } else if (tr && tr.status === "missing" && tr.suggestion) {
    sub = "detected candidate: " + tr.suggestion;
  } else if (tr && tr.status === "missing") {
    sub = "no test command configured";
  }
  return {
    voice: "repair",
    line: "⚠ TEST SYSTEMS OFFLINE — missions cannot be proof-gated.",
    sub: sub,
  };
}

/* ── S183: THE FOUNDATION LOCK ────────────────────────────────────────────
   `meta.foundation` is present ONLY when this repo has no test foundation
   (greenfield = nothing here; untested = code with no test system). In that
   state a normal Mission cannot be filed and the holodeck is locked (captain
   ruling, 2026-09-05): the foundation is established first, by an
   initialization mission from Establish Vision, with the captain at Verify.

   THE BUTTON STATE IS THE PRODUCT HERE. The daemon refuses these POSTs with a
   409 either way, but a captain who can click ▦ FILE MISSION, type an idea and
   only then be told the repo cannot take one has been misled by the board —
   so the controls are disabled, and the REASON is said (the read-only idiom:
   `data-reason` + `title`, never a silently greyed button). */
var FOUNDATION_LOCK_REASON = {
  greenfield:
    "This repo is empty — there is no code and no test system yet, so a "
    + "Mission has no way to prove any work. Start with Establish Vision: say "
    + "what you want to build and LCARS files an initialization mission that "
    + "lays the foundation.",
  untested:
    "This repo has code but no test system, so a Mission has no way to prove "
    + "any work. Start with Establish Vision: LCARS recommends a stack and "
    + "files an initialization mission that lays the foundation.",
};

function foundationLocked(f) {
  return f === "greenfield" || f === "untested";
}

/* THE LOCK STATE, held in ONE place (S183 fix round 1, D2).
   `paintFoundationLock` used to write #holodeckBtn's disabled/title/data-reason
   itself, and so does `holoPaintBandBtn` — which render() calls immediately
   AFTER it (board.js: paintFoundationLock, then renderHolodeckActivity). The
   second painter unconditionally set `disabled = (writesActive === false)`,
   rewrote the title and REMOVED data-reason, so the shipped board carried
   class="btn go foundation-locked" with disabled:false, opacity:1,
   cursor:pointer — MEASURED in real headed Chrome, and clicking it opened the
   deck. The captain got all the way in and typed a brief before the daemon's
   409 refused him.

   Two painters over one control is the defect, not their order: hand-ordering
   them would only work until the next call site. So the fact lives here and
   holoPaintBandBtn — the ONE owner of that button — reads it alongside
   read-only mode and the working-program indicator. */
var foundationLockReason = "";

function paintFoundationLock(foundation) {
  var locked = foundationLocked(foundation);
  var reason = locked
    ? (FOUNDATION_LOCK_REASON[foundation] || FOUNDATION_LOCK_REASON.greenfield)
    : "";
  foundationLockReason = reason;
  var b = document.getElementById("fileBtn");
  if (b) {
    if (locked) {
      b.disabled = true;
      b.title = reason;
      b.setAttribute("data-reason", reason);
      if (b.classList) b.classList.add("foundation-locked");
    } else {
      /* Only ever UNDO our own lock — read-only mode paints these same
         attributes, and stomping them here would re-enable a control a
         view-only board must never offer. */
      if (b.classList && b.classList.contains("foundation-locked")) {
        b.classList.remove("foundation-locked");
        b.disabled = writesActive === false;
        b.removeAttribute("data-reason");
        b.title = "";
      }
    }
  }
  /* ⬡ HOLODECK is painted by its own single owner, which now considers the
     lock. Calling it here means the lock APPLIES and LIFTS through exactly the
     same path the SSE tick uses. */
  holoPaintBandBtn();
}

/* ══════════════ S184 — ESTABLISH VISION: THE DAY-ZERO FRONT DOOR ══════════
   THE FRONT DOOR REPLACES THE BOARD. S183 shipped the rule and the captain saw
   it driven in real Chrome: seven empty columns, a warning banner, two greyed-
   out controls, and the one thing you are meant to do written as small print
   inside the banner. His verdict — "really clunky for getting in there and
   initializing a new greenfield project" — is about the SHAPE, not the copy, so
   bolting an ESTABLISH VISION button onto that locked board would keep the
   wrong shape and merely label it. His ruling:

       the board does not render until there is something to put on it.

   THE RULE IS NARROW, AND THE NARROWNESS IS THE WHOLE SAFETY ARGUMENT.
   `meta.frontDoor` is set by the daemon ONLY when the verdict locks AND the
   repo has nothing to put on a board. Measured on the captain's machine before
   this was written: `Flappy-Bird` is an initialized repo whose foundation
   verdict is `untested` and which carries TWO real missions. A front door keyed
   on `meta.foundation` alone — the obvious reading of the brief — would have
   DELETED that board and hidden both missions behind "What are we building?".
   So this reads the POSITIVE key the daemon computed, and it ALSO re-checks
   locally that the board is empty: two independent guards over the one thing
   this session must never do.

   S183's lock is NOT deleted and NOT weakened. It still paints on every render,
   and it is what protects every surface this door does not cover: the read-only
   build, the GitHub adapter, and a foundationless repo that DOES have a board.
   ──────────────────────────────────────────────────────────────────────── */

/* The copy, per verdict. Two screens, and the difference between them is the
   difference between not knowing and knowing: on `untested` LCARS can SEE the
   code, so asking "what are we building?" would be the harness admitting it did
   not look. (Captain ruling 2026-09-05: skip that grill on `untested`.) */
var FRONT_DOOR_COPY = {
  greenfield: {
    cls: "greenfield",
    kicker: "◇ New project",
    grillKicker: "◇ Establishing vision",
    ask: ["What are we building?"],
    say: "Describe it however you like. LCARS will ask a few questions, "
       + "recommend a stack and say why, then build the foundation — a running "
       + "skeleton with a working test system — before any feature work starts.",
    placeholder: "A website that does personal finance stuff…",
    primary: "▸ Establish vision",
    ghost: "Paste a spec instead",
    escape: "Already have tests LCARS can't see? Point it at them: ",
    escapeCode: "lcars update --test-command '<command>'",
  },
  untested: {
    cls: "untested",
    kicker: "◇ No test system",
    grillKicker: "◇ Establishing the test foundation",
    ask: ["I can see the code.", "I can't prove a change."],
    say: "Every LCARS ticket is proven by running its tests — red on the parent "
       + "commit, green on the tip. This project has no runner, so there's "
       + "nothing to prove a change with yet.",
    primary: "▸ Establish test foundation",
    ghost: "I have one — point LCARS at it",
    escape: "Scope is the foundation only: a runner, a first real test, and the "
          + "wiring to run it. Your code is not touched.",
  },
};

/* frontDoorActive — the ONE decision, in one place.
   BOTH guards, deliberately:
     • the daemon's positive `meta.frontDoor` key (locked verdict AND no
       missions — computed by the same helper the CLI front door calls), and
     • a local re-count of the cards, so a stale payload can never eat a board
       that has since gained a mission.
   Plus: LOCAL adapter only, and never on a view-only build — the front door is
   an invitation to DO something, and a board that cannot write must not offer
   one. Those two are exactly the surfaces item 8 keeps S183's lock alive for. */
function frontDoorActive(board) {
  var meta = (board && board.meta) || {};
  if ((meta.adapter || "local") !== "local") return false;
  if (writesActive === false) return false;
  if (!meta.frontDoor || !foundationLocked(meta.frontDoor.foundation)) return false;
  return boardCardCount(board) === 0;
}

function boardCardCount(board) {
  var n = (board && board.missions && board.missions.length) || 0;
  var cols = (board && board.columns) || {};
  for (var k in cols) {
    if (Object.prototype.hasOwnProperty.call(cols, k) && cols[k] && cols[k].length) {
      n += cols[k].length;
    }
  }
  return n;
}

/* The live front-door state. Kept OUT of the DOM so an SSE re-render repaints
   the same screen the captain is on instead of throwing him back to screen 1
   mid-sentence. `screen` ∈ ask | grill | recommend; `rec` is the recommendation
   the grill produced. */
var frontDoorState = { screen: "ask", sid: null, idea: "", busy: false,
                       question: null, rec: null, error: "", note: "",
                       /* S195 — the engine, held HERE for the same reason
                          `screen` is: the door repaints on every SSE tick, so a
                          pick kept in the DOM is a pick lost on the next one.
                          Empty until the payload names one; `frontDoorEngine`
                          resolves it against the daemon's preselection. */
                       engine: "" };

function frontDoorHost() { return document.getElementById("frontDoor"); }

function setFrontDoorMode(on) {
  var b = document.body;
  if (b && b.classList) {
    if (on) b.classList.add("on-front-door"); else b.classList.remove("on-front-door");
  }
  paintFrontDoorBand(on);
}

/* THE BAND IS PART OF THE SHAPE (S184 fix round 1, D1).
   The front door said "nothing is being withheld from you" while ⬡ HOLODECK and
   ▦ FILE MISSION sat six inches above it, greyed out — MEASURED in real headed
   Chrome. That is the captain's original complaint about S183's board ("really
   clunky"), still on screen: a day-zero page whose furniture is disabled
   controls for a pipeline that does not exist yet. Brief item 1 says no dimmed
   controls; the approved mockup's band carries the brand, the repo name and the
   LOCAL / ● LIVE chips and nothing else.

   So the board's controls are HIDDEN on the front door — presentation only, and
   only here. Nothing is deleted, `paintFoundationLock` is untouched and still
   runs, and the moment the door lifts every control comes back in exactly the
   state its own painter left it in. `hidden` (not a class, not inline display)
   because board.css's global `[hidden]{display:none !important}` beats
   `renderMainDeploy`'s inline `style.display`, and because an attribute is
   something a test can actually see.

   ? HELP goes too: the console it opens is the BOARD's help — hotkeys for cards
   and columns that are not on screen — so on day zero it is an offer to explain
   a thing the captain cannot see. */
var FRONT_DOOR_BAND_HIDDEN = ["deployMainBtn", "mainDeploy", "holodeckBtn",
                              "fileBtn", "helpBtn"];
function paintFrontDoorBand(on) {
  FRONT_DOOR_BAND_HIDDEN.forEach(function (id) {
    var n = document.getElementById(id);
    if (n) n.hidden = !!on;
  });
}

/* ── S195: WHICH CLI DRIVES THIS PROJECT ───────────────────────────────────
   The captain's ruling: the choice is made ON THE FRONT DOOR, before the grill
   starts, because that is where the decision naturally occurs — and it powers
   BOTH the grill conversation AND every stage of the mission the door files.

   THREE RULES, and each is a rule rather than a taste:

     1. OFFER ONLY WHAT IS INSTALLED. `fd.engines` is the daemon's list, from
        the one `command -v` detector `lcars init` already verifies claude
        through (lcars-common.sh). The board never guesses: no engines key ⇒ no
        control at all, and nothing added to the POST — an older daemon, the
        GitHub adapter, or a `--facts` that could not answer must leave this
        surface byte-identical to S184's.

     2. ONE ENGINE IS NOT A CHOICE. With a single CLI installed there is no
        picker — a one-option control is furniture. But the door still SAYS
        which engine will run it, because a day-zero screen that silently picks
        the thing that spends money is the surface this round exists to avoid.

     3. IT IS GONE ONCE THE CONVERSATION STARTS. The grill session is warm on
        the engine it opened with, so a picker on the grill screen would offer a
        switch nothing could honour. */

var ENGINE_LABELS = { claude: "Claude", copilot: "Copilot" };

function engineLabel(e) {
  return ENGINE_LABELS[String(e || "").toLowerCase()] || String(e || "");
}

function frontDoorEngines(fd) {
  var list = (fd && fd.engines) || [];
  return Object.prototype.toString.call(list) === "[object Array]" ? list : [];
}

/* The engine in force: the captain's pick when he has made one AND it is still
   on offer, otherwise the daemon's preselection (repo config > the single
   installed engine > claude). Re-derived on every render so a payload that
   changes underneath the door can never leave a stale engine selected. */
function frontDoorEngine(fd) {
  var list = frontDoorEngines(fd);
  var picked = String(frontDoorState.engine || "");
  for (var i = 0; i < list.length; i++) {
    if (String(list[i]) === picked) return picked;
  }
  var pre = String((fd && fd.engine) || "");
  for (var j = 0; j < list.length; j++) {
    if (String(list[j]) === pre) return pre;
  }
  return list.length ? String(list[0]) : "";
}

/* Paint the control into `host`, or nothing at all. Returns nothing — the
   choice lives in `frontDoorState.engine`, never in the DOM. */
function renderFrontDoorEngine(host, fd) {
  var list = frontDoorEngines(fd);
  if (!list.length) return;                       // rule 1: nothing to offer
  var chosen = frontDoorEngine(fd);
  frontDoorState.engine = chosen;
  var wrap = el("div", "fd-engine");
  if (list.length === 1) {
    // rule 2: say it, do not offer it.
    wrap.appendChild(el("div", "fd-engine-one",
      "Engine · " + engineLabel(list[0]) + " will run this — the only "
      + "LCARS-capable CLI installed on this machine."));
    host.appendChild(wrap);
    return;
  }
  wrap.appendChild(el("div", "fd-engine-h",
    "Engine — which CLI drives this project?"));
  var choice = el("div", "choice");
  var nodes = [];
  list.forEach(function (eng) {
    var name = String(eng);
    /* keyActivable, like the File console's picker: these are spans rendered as
       controls, and a control you cannot Tab to is not a control. */
    var opt = keyActivable(el("span", "opt", "⬡ " + engineLabel(name)));
    opt.setAttribute("aria-pressed", name === chosen ? "true" : "false");
    if (name === chosen) opt.classList.add("sel");
    opt.addEventListener("click", function () {
      frontDoorState.engine = name;
      nodes.forEach(function (o) {
        o.classList.remove("sel");
        o.setAttribute("aria-pressed", "false");
      });
      opt.classList.add("sel");
      opt.setAttribute("aria-pressed", "true");
    });
    nodes.push(opt);
    choice.appendChild(opt);
  });
  wrap.appendChild(choice);
  wrap.appendChild(el("div", "fd-engine-note",
    "It runs the conversation AND every stage of the mission it files, and "
    + "becomes this project's default."));
  host.appendChild(wrap);
}

/* The body of the POST, with `engine` present ONLY when there is one. An
   explicit empty string would be a pick, and there is none to make. */
function frontDoorEngineBody(body) {
  var e = String(frontDoorState.engine || "");
  if (e) body.engine = e;
  return body;
}

function renderFrontDoor(fd) {
  var host = frontDoorHost();
  if (!host) return;
  var copy = FRONT_DOOR_COPY[fd && fd.foundation] || FRONT_DOOR_COPY.greenfield;
  host.innerHTML = "";
  host.hidden = false;
  host.className = "front-door " + copy.cls;
  /* ONE inner column, and every screen paints into it. The host is the
     CENTERING frame (it owns the free vertical space); this is the measure. */
  var body = el("div", "fd-inner");
  host.appendChild(body);
  host = body;
  if (frontDoorState.screen === "recommend" && frontDoorState.rec) {
    renderFrontDoorRecommendation(host, frontDoorState.rec);
    return;
  }
  /* The override screen is a SCREEN, not a transient overlay — it has to
     survive a repaint. It did not, at first: `frontDoorOverride` painted
     straight into the host without recording where the captain was, so the very
     next SSE tick (or the boot refresh) re-rendered the RECOMMENDATION over the
     top of him mid-decision. Caught by the harness driving the real click chain
     through a drain, which is exactly the class of bug a screenshot cannot
     see. Every screen the captain can be on is now a value of
     `frontDoorState.screen`. */
  if (frontDoorState.screen === "override" && frontDoorState.rec) {
    renderFrontDoorOverride(host, frontDoorState.rec);
    return;
  }
  /* THE GRILL IS A SCREEN, AND IT GETS ITS OWN HEAD (fix round 2, D6).
     It used to wear screen 1's — "◇ NEW PROJECT / WHAT ARE WE BUILDING? /
     Describe it however you like…" — sitting above a completely different
     question the model was actually asking. Nothing on the page said a
     conversation was under way, so turn 6 looked exactly like turn 1. */
  var onGrill = frontDoorState.screen === "grill";
  if (onGrill) {
    host.appendChild(el("div", "fd-kicker", copy.grillKicker));
    var gask = el("div", "fd-ask");
    gask.appendChild(el("span", null, "Let's talk it through."));
    host.appendChild(gask);
    host.appendChild(el("div", "fd-say",
      "One question at a time. Answer in your own words, or pick one of the "
      + "options. Nothing is filed until you have approved a recommendation "
      + "you are free to refuse."));
    renderFrontDoorQuestion(host, frontDoorState.question);
  } else {
    host.appendChild(el("div", "fd-kicker", copy.kicker));
    var ask = el("div", "fd-ask");
    copy.ask.forEach(function (line) { ask.appendChild(el("span", null, line)); });
    host.appendChild(ask);
    host.appendChild(el("div", "fd-say", copy.say));
  }

  /* SCREEN 2's FOUND PANEL. Every value is REAL detection handed over by
     `establish-vision.sh --facts` — the same numbers `lcars` prints on the CLI.
     A report that guesses is worse than no report: this is what a captain
     pointing LCARS at real work reads to decide whether it understood his
     repo. */
  if (copy.cls === "untested" && !onGrill) {
    var found = el("div", "fd-found");
    found.appendChild(fdRow("Stack", fd.stackLabel || "not recognised"));
    found.appendChild(fdRow("Source files",
      (fd.sourceFiles === 0 || fd.sourceFiles) ? String(fd.sourceFiles) : "—"));
    found.appendChild(fdRow("Test runner", "none found", true));
    found.appendChild(fdRow("Proof", "not possible yet", true));
    host.appendChild(found);
  }

  /* The free-text field: screen 1 asks for the idea; screen 2 does not ask what
     we are building at all, and a grill turn asks for THIS answer. */
  var box = null;
  if (copy.cls !== "untested" || onGrill) {
    box = el("textarea", "fd-field");
    box.rows = 5;
    box.placeholder = frontDoorState.screen === "grill"
      ? "Your answer…" : (copy.placeholder || "");
    if (frontDoorState.screen !== "grill") box.value = frontDoorState.idea || "";
    host.appendChild(box);
  }

  /* S195 — the engine, on BOTH doors and ONLY on the ask screens. Below the
     idea box and above the primary action: it is the last thing settled before
     the conversation starts, and it must not shove the textarea down the page
     mid-sentence the way the base-freshness block once did (S160 D4).

     AND ONLY WHILE IT IS STILL A CHOICE. `busy` means the opening turn is in
     flight and `sid` means a session already exists — in both cases the grill
     is (or is about to be) warm on the engine it opened with, and a click that
     changed `frontDoorState.engine` then would send the FILING to a different
     CLI than the one that ran the interview. That split is the one thing
     file.sh's engine header says must never happen, and it is invisible on
     screen, so the control is withdrawn rather than left live and ignored. */
  if (!onGrill && !frontDoorState.busy && !frontDoorState.sid) {
    renderFrontDoorEngine(host, fd);
  }

  var actions = el("div", "fd-actions");
  if (frontDoorState.busy) {
    actions.appendChild(el("div", "fd-busy", "◐ THINKING…"));
  } else {
    var go = el("button", "btn go",
                frontDoorState.screen === "grill" ? "▸ Continue" : copy.primary);
    go.type = "button";
    go.addEventListener("click", function () {
      frontDoorSubmit(box ? (box.value || "") : "");
    });
    actions.appendChild(go);
    var ghost = el("button", "btn ghost", copy.ghost);
    ghost.type = "button";
    ghost.addEventListener("click", function () { frontDoorGhost(copy.cls); });
    actions.appendChild(ghost);
  }
  host.appendChild(actions);

  var esc = el("div", "fd-escape");
  esc.appendChild(el("span", null, copy.escape));
  if (copy.escapeCode) esc.appendChild(el("code", null, copy.escapeCode));
  host.appendChild(esc);
  if (frontDoorState.error) host.appendChild(el("div", "fd-note err", frontDoorState.error));
  else if (frontDoorState.note) host.appendChild(el("div", "fd-note", frontDoorState.note));
}

/* THE SLICE IS A NOUN PHRASE (S184 fix round 1, D3).
   The template supplies the sentence — "One thin vertical slice that proves
   both: <slice>." — so `slice` is the phrase that COMPLETES it, e.g. "importing
   a CSV row and showing it". A live model's output shape is a lottery (S175),
   and it will hand back a whole sentence that restates the label; measured
   output before this cure:

     "One thin vertical slice that proves both: A running app, a working test
      system, and one thin slice that proves both — importing a CSV row and
      showing it.."

   — the label said twice and a doubled full stop. So the renderer is
   DEFENSIVE rather than trusting: if the phrase restated the label, keep only
   the tail after the dash or colon that followed it, and never let the caller's
   trailing period double the template's. Same normalisation lives in
   `establish-vision.sh` (ev_norm_slice) for the PRD and the vision doc, so the
   screen and the filed mission cannot say different things. */
function frontDoorSlice(v) {
  var t = String(v == null ? "" : v).trim();
  if (!t) return "";
  var m = t.match(
    /^[^—:]*\b(?:thin(?:\s+vertical)?\s+slice|proves?\s+both)\b[^—:]*[—:]\s*(\S.*)$/i);
  if (m) t = m[1].trim();
  return t.replace(/[.\s]+$/, "");
}

/* THE QUESTION IS AN OBJECT — {text, choices, recommended, closing} — and it
   was appended to the DOM as one. `textContent = <object>` puts the literal
   characters `[object Object]` on screen, which is what the captain read on
   EVERY grill turn of both live runs, in real headed Chrome (fix round 2, D3).
   A plain string is tolerated too: the worker's reply shape is not guaranteed,
   and `_align_turn` itself already coerces a bare string into {text}. */
function frontDoorQuestionText(q) {
  if (q == null) return "";
  if (typeof q === "string") return q;
  return String(q.text || q.recommended || "");
}

/* …and the model's CHOICES were thrown away with it. It offered them on most
   measured turns, so the captain was reading a question that had already
   listed its own answers, above an empty free-text box. */
function frontDoorQuestionChoices(q) {
  if (!q || typeof q !== "object" || !q.choices || !q.choices.length) return [];
  var out = [];
  for (var i = 0; i < q.choices.length; i++) {
    var c = q.choices[i];
    var label = (c && typeof c === "object") ? (c.text || c.label || c.value) : c;
    label = String(label == null ? "" : label).trim();
    if (label) out.push(label);
  }
  return out;
}

function renderFrontDoorQuestion(host, q) {
  var text = frontDoorQuestionText(q);
  if (text) host.appendChild(el("div", "fd-q", text));
  var choices = frontDoorQuestionChoices(q);
  /* Busy = his answer is already in flight. Leaving the options live would let
     him send a second one into the same turn. */
  if (!choices.length || frontDoorState.busy) return;
  var rec = (q && typeof q === "object") ? String(q.recommended || "").trim() : "";
  var wrap = el("div", "fd-choices");
  choices.forEach(function (label) {
    var isRec = !!rec && label === rec;
    var b = el("button", "btn ghost fd-choice" + (isRec ? " rec" : ""),
               isRec ? label + "  · recommended" : label);
    b.type = "button";
    /* The CLEAN label is the answer — never the decorated one on the face. */
    b.addEventListener("click", function () { frontDoorSubmit(label); });
    wrap.appendChild(b);
  });
  host.appendChild(wrap);
}

function fdRow(k, v, warn) {
  var row = el("div", "fd-row");
  row.appendChild(el("div", "fd-k", k));
  row.appendChild(el("div", "fd-v" + (warn ? " warn" : ""), v));
  return row;
}

/* SCREEN 3 — THE RECOMMENDATION.
   Three things are load-bearing here and each of them is a rule, not a taste:
     1. the reasons are in the captain's language about HIS idea (the grill's
        job; this only renders them), because a reason he cannot check is
        marketing copy;
     2. the SCOPE FENCE is ON SCREEN — what this first mission builds, and the
        features that are being DEFERRED rather than quietly dropped;
     3. "⇄ Choose a different stack" sits BESIDE "✓ Accept", never behind a
        menu. A recommendation the captain cannot refuse is a decision, and the
        stack is his call. The override is what lands in the PRD. */
function renderFrontDoorRecommendation(host, rec) {
  host.appendChild(el("div", "fd-kicker", "◇ Recommendation · foundation mission"));
  var ask = el("div", "fd-ask");
  ask.appendChild(el("span", null, rec.stack || "a stack"));
  host.appendChild(ask);

  var because = el("ul", "fd-because");
  (rec.reasons || []).forEach(function (r) {
    if (r) because.appendChild(el("li", null, r));
  });
  host.appendChild(because);

  var fence = el("div", "fd-fence");
  fence.appendChild(el("div", "fd-fence-h", "What this first mission builds"));
  var ul = el("ul");
  ul.appendChild(el("li", null, "A running skeleton — it boots and shows something."));
  ul.appendChild(el("li", null, "A working test system for " + (rec.stack || "this stack")
                                + " that you can watch run."));
  ul.appendChild(el("li", null, "One thin vertical slice that proves both: "
                                + (frontDoorSlice(rec.slice)
                                   || "the skeleton renders and a real test covers it") + "."));
  fence.appendChild(ul);
  var deferred = (rec.deferred || []).filter(function (d) { return !!d; });
  fence.appendChild(el("div", "fd-deferred",
    (deferred.length ? deferred.join(", ") : "Everything else you described")
    + " — recorded in your vision, and each becomes a normal mission once the "
    + "foundation lands."));
  host.appendChild(fence);

  var actions = el("div", "fd-actions");
  if (frontDoorState.busy) {
    actions.appendChild(el("div", "fd-busy", "◐ FILING…"));
  } else {
    var accept = el("button", "btn go", "✓ Accept & file mission");
    accept.type = "button";
    accept.addEventListener("click", function () { frontDoorFile(rec); });
    actions.appendChild(accept);
    var other = el("button", "btn ghost", "⇄ Choose a different stack");
    other.type = "button";
    other.addEventListener("click", function () { frontDoorOverride(rec); });
    actions.appendChild(other);
  }
  host.appendChild(actions);
  if (frontDoorState.error) host.appendChild(el("div", "fd-note err", frontDoorState.error));
}

/* THE OVERRIDE. It is not a dialogue about whether he may — he may. It swaps the
   stack line for an input, and whatever he types is what `--stack` carries into
   the PRD and the vision doc. */
function frontDoorOverride(rec) {
  frontDoorState.screen = "override";
  frontDoorState.rec = rec;
  frontDoorRepaint();
}

function renderFrontDoorOverride(host, rec) {
  host.innerHTML = "";
  host.appendChild(el("div", "fd-kicker", "◇ Your stack, your call"));
  var ask = el("div", "fd-ask");
  ask.appendChild(el("span", null, "Which stack?"));
  host.appendChild(ask);
  host.appendChild(el("div", "fd-say",
    "LCARS recommended " + (rec.stack || "a stack")
    + ". Name any stack you prefer — the one you enter is the one the "
    + "initialization mission is built on."));
  var box = el("input", "fd-field");
  box.value = rec.stack || "";
  host.appendChild(box);
  var actions = el("div", "fd-actions");
  var go = el("button", "btn go", "✓ Use this stack & file mission");
  go.type = "button";
  go.addEventListener("click", function () {
    var chosen = (box.value || "").trim() || rec.stack;
    frontDoorFile({ stack: chosen, reasons: ["Chosen by the captain, overriding "
                    + "the recommendation of " + (rec.stack || "the grill") + "."],
                    slice: rec.slice, deferred: rec.deferred, idea: rec.idea });
  });
  actions.appendChild(go);
  var back = el("button", "btn ghost", "◂ Back to the recommendation");
  back.type = "button";
  back.addEventListener("click", function () {
    frontDoorState.screen = "recommend";
    frontDoorRepaint();
  });
  actions.appendChild(back);
  host.appendChild(actions);
}

/* The grill: the EXISTING Align console machinery with `vision:true`, never a
   second interviewer (brief item 5). The daemon prepends the foundation brief —
   the same text `establish-vision.sh --brief` prints on the CLI — so the fence
   is stated in the grill's own words on both front doors. */
function frontDoorSubmit(text) {
  var t = (text || "").trim();
  frontDoorState.error = "";
  if (frontDoorState.screen === "grill" && frontDoorState.sid) {
    if (!t) { frontDoorState.error = "Answer the question to continue."; return frontDoorRepaint(); }
    frontDoorState.busy = true; frontDoorRepaint();
    return postWrite("/api/align/" + frontDoorState.sid + "/answer", { answer: t },
      frontDoorTurn, frontDoorFailed);
  }
  var fd = LAST_BOARD && LAST_BOARD.meta && LAST_BOARD.meta.frontDoor;
  if ((fd && fd.foundation) !== "untested" && !t) {
    frontDoorState.error = "Say what you want to build — a sentence is enough.";
    return frontDoorRepaint();
  }
  frontDoorState.idea = t;
  frontDoorState.busy = true; frontDoorRepaint();
  return postWrite("/api/align/start",
                   frontDoorEngineBody({ idea: t, vision: true }),
                   frontDoorTurn, frontDoorFailed);
}

function frontDoorTurn(state) {
  frontDoorState.busy = false;
  var t = (state && state.turn) || state || {};
  /* S184 FIX ROUND 2 (D1) — THE KEY THE DAEMON ACTUALLY SENDS.
     This read `t.sid`. Every align turn returns `sessionId`
     (`actions.py::_align_turn`), so `frontDoorState.sid` stayed null forever,
     `frontDoorSubmit` never took its answer branch, and EVERY answer went back
     to `POST /api/align/start` carrying the answer as a brand-new IDEA.
     Measured live: 19 turns, 19 distinct `--session-id=<new uuid>`, ZERO
     `--resume=`. The model re-asked "what are we building?" forever and forgot
     a stack it had locked in one turn earlier. There is no server path that
     sends `sid` on an align turn (`alignResume.sid` is a CARD stamp, a
     different payload), so there is no alias to keep. */
  frontDoorState.sid = t.sessionId || frontDoorState.sid;
  if (t.recommendation) {
    frontDoorState.rec = t.recommendation;
    if (!frontDoorState.rec.idea) frontDoorState.rec.idea = frontDoorState.idea;
    frontDoorState.screen = "recommend";
  } else if (t.question) {
    frontDoorState.question = t.question;
    frontDoorState.screen = "grill";
  }
  frontDoorRepaint();
}

function frontDoorFailed(msg) {
  frontDoorState.busy = false;
  frontDoorState.error = msg || "That did not go through.";
  frontDoorRepaint();
}

function frontDoorFile(rec) {
  frontDoorState.busy = true; frontDoorState.error = ""; frontDoorState.rec = rec;
  frontDoorRepaint();
  postWrite("/api/vision/file", frontDoorEngineBody({
    idea: rec.idea || frontDoorState.idea,
    stack: rec.stack,
    reasons: rec.reasons || [],
    deferred: rec.deferred || [],
    slice: rec.slice || "",
  }), function () {
    /* The mission has landed, so the repo now HAS something to put on a board
       and the next render drops the door on its own. Reset so a later
       foundationless repo opens on screen 1. */
    frontDoorState = { screen: "ask", sid: null, idea: "", busy: false,
                       question: null, rec: null, error: "", note: "",
                       engine: "" };
  }, frontDoorFailed);
}

function frontDoorGhost(kind) {
  /* Both ghosts are real, and both are escape hatches rather than second
     opinions: on a blank repo, paste a spec instead of being interviewed; on a
     repo with code, tell LCARS about the runner it could not see. */
  if (kind === "untested") {
    frontDoorState.note = "";
    var cmd = window.prompt && window.prompt(
      "What command runs this project's tests?", "");
    if (!cmd) return;
    return postWrite("/api/config/test-command", { testCommand: cmd },
      function () { frontDoorState.note = "Recorded — re-checking this repo."; },
      frontDoorFailed);
  }
  frontDoorState.note = "Paste the whole spec into the box above — LCARS reads "
                      + "it as your answer to the first question.";
  frontDoorRepaint();
}

function frontDoorRepaint() {
  renderFrontDoor(LAST_BOARD && LAST_BOARD.meta && LAST_BOARD.meta.frontDoor);
}

/* The band-level strip: its OWN row below the top band (the version-banner
   placement idiom — never inside the topbar button cluster, so it coexists
   with the Deploy Main control). View-only builds show the STATUS without the
   FIX affordance. */
var readinessBusy = false; // transient: a banner ⚡ FIX is in flight
function renderTestReadiness(tr) {
  var host = document.getElementById("readinessBanner");
  if (!host) return;
  host.innerHTML = "";
  if (!tr || !tr.status) { host.hidden = true; return; }
  host.hidden = false;

  var copy = readinessCopy(tr);
  var band = el("div", "rb-band " + copy.voice);
  band.appendChild(el("span", "rb-msg", copy.line));
  if (copy.sub) band.appendChild(el("span", "rb-sub", copy.sub));

  // The repair voice carries the one-click fix; the bootstrap voice is pure
  // status (never an action item), and a view-only build hides the affordance.
  // AMBIGUOUS carries picks instead: choosing is the repair, and it costs
  // nothing (one /api/config/test-command POST, the sanctioned setter).
  if (copy.choices && writesActive !== false) {
    var creason = el("span", "rb-reason");
    band.appendChild(creason);
    copy.choices.forEach(function (cmd) {
      var cb = btn("▸ USE: " + cmd, "go rb-btn", function () {
        if (readinessBusy) return;
        readinessBusy = true;
        cb.disabled = true;
        cb.textContent = "◐ SETTING…";
        band.classList.add("rb-busy");
        creason.textContent = "";
        postWrite("/api/config/test-command", { testCommand: cmd }, function () {
          readinessBusy = false;
          band.classList.remove("rb-busy");
          band.classList.add("rb-done");
          cb.textContent = "✓ TEST SYSTEMS ONLINE";
        }, function (msg) {
          readinessBusy = false;
          band.classList.remove("rb-busy");
          cb.disabled = false;
          cb.textContent = "▸ USE: " + cmd;
          creason.textContent = msg;
        });
      });
      band.appendChild(cb);
    });
    host.appendChild(band);
    return;
  }
  if (copy.voice === "repair" && writesActive !== false) {
    var reason = el("span", "rb-reason");
    var b = btn("⚡ FIX TEST SYSTEMS", "go rb-btn", function () {
      if (readinessBusy) return;
      readinessBusy = true;
      b.disabled = true;
      b.textContent = "◐ REPAIRING TEST SYSTEMS…";
      band.classList.add("rb-busy");
      reason.textContent = "";
      postWrite("/api/config/fix-tests", {}, function () {
        // Success: the settled return + SSE re-render clear the banner (the
        // fresh meta has no testReadiness). Flash the done state meanwhile.
        readinessBusy = false;
        band.classList.remove("rb-busy");
        band.classList.add("rb-done");
        b.textContent = "✓ TEST SYSTEMS ONLINE";
      }, function (msg) {
        // Failure: plain-English report inline; the button re-arms.
        readinessBusy = false;
        band.classList.remove("rb-busy");
        b.disabled = false;
        b.textContent = "⚡ FIX TEST SYSTEMS";
        reason.textContent = msg;
      });
    });
    if (readinessBusy) { b.disabled = true; b.textContent = "◐ REPAIRING TEST SYSTEMS…"; }
    band.appendChild(reason);
    band.appendChild(b);
  }
  host.appendChild(band);
}

/* S146: the File-console inline warning — rendered ABOVE the idea box when the
   repo is unready. One themed line + ⚡ FIX TEST SYSTEMS (one POST walks
   suggest-or-discover → set → probe server-side) + an editable command input
   as the manual OVERRIDE. Success re-verdicts live (the settled return AND the
   SSE re-render both repaint this block in place) — the console never closes,
   the typed idea is never touched. A failed fix reports plainly and leaves the
   input ready. Filing/parking proceed regardless. Read-only builds render the
   status line only (no affordances). */
var fileReadinessSync = null; // live re-verdict hook while the console is open
function fileReadinessBlock(tr) {
  var wrap = el("div", "file-readiness");

  function paint(cur) {
    wrap.innerHTML = "";
    if (!cur || !cur.status) {
      // The systems came online while the console was open — the warning
      // clears IN PLACE (teal confirmation), console + idea untouched.
      wrap.className = "file-readiness online";
      wrap.appendChild(el("div", "fr-line",
        "✓ TEST SYSTEMS ONLINE — missions will be proof-gated."));
      return;
    }
    var copy = readinessCopy(cur);
    wrap.className = "file-readiness " + copy.voice;
    wrap.appendChild(el("div", "fr-line",
      copy.line + (copy.sub ? " · " + copy.sub : "")));
    if (writesActive === false) return; // view-only: status only

    var row = el("div", "fr-row");
    var report = el("div", "fr-report");
    report.hidden = true;
    var input = el("input");
    input.type = "text";
    input.placeholder = "Manual override — the exact command that runs the suite";
    input.value = cur.suggestion || cur.testCommand || "";

    var fix, set;
    function busy(b, label) {
      fix.disabled = true; set.disabled = true;
      b.textContent = label;
      report.hidden = true;
    }
    function rearm() {
      fix.disabled = false; set.disabled = false;
      fix.textContent = "⚡ FIX TEST SYSTEMS";
      set.textContent = "SET";
    }
    function onDone(state) {
      var fresh = state && state.board && state.board.meta
        && state.board.meta.testReadiness;
      paint(fresh || null);
    }
    function onFail(msg) {
      rearm();
      report.hidden = false;
      report.textContent = msg; // plain report; the input stays ready
    }
    // S147: on the AMBIGUOUS verdict the repair IS the choice, so the console
    // offers one pick per detected candidate instead of ⚡ FIX (which would
    // dispatch a paid discovery worker to choose). The manual override input
    // stays exactly where it is — typing a command is still the escape hatch.
    if (copy.choices) {
      copy.choices.forEach(function (cmd) {
        var cb = applyWriteState(btn("▸ USE: " + cmd, "go", function () {
          cb.disabled = true;
          cb.textContent = "◐ SETTING…";
          report.hidden = true;
          postWrite("/api/config/test-command", { testCommand: cmd },
            onDone,
            function (msg) {
              cb.disabled = false;
              cb.textContent = "▸ USE: " + cmd;
              report.hidden = false;
              report.textContent = msg;
            });
        }));
        row.appendChild(cb);
      });
    }
    fix = applyWriteState(btn("⚡ FIX TEST SYSTEMS", "go", function () {
      busy(fix, "◐ REPAIRING…");
      postWrite("/api/config/fix-tests", {}, onDone, onFail);
    }));
    set = applyWriteState(btn("SET", null, function () {
      var v = (input.value || "").trim();
      if (!v) {
        report.hidden = false;
        report.textContent = "Type the command first.";
        return;
      }
      busy(set, "◐ SETTING…");
      postWrite("/api/config/test-command", { testCommand: v }, onDone, onFail);
    }));
    if (!copy.choices) row.appendChild(fix);
    row.appendChild(input);
    row.appendChild(set);
    wrap.appendChild(row);
    wrap.appendChild(report);
  }

  paint(tr);
  fileReadinessSync = function (fresh) { paint(fresh || null); };
  return wrap;
}

/* ════════════════ S160: BASE FRESHNESS ═══════════════════════════════════
   S158 (file time) and S159 (drive time) already decide whether the branch a
   Mission is cut from is the tree the rest of the world sees — and both print
   their verdict to STDOUT, which the daemon swallows. A captain filing from
   this board never saw a word of it. This is that verdict, on the board.

   TWO RULES GOVERN EVERYTHING BELOW.

   1. GATED ON `loud`, NEVER ON THE VERDICT NAME. The vocabulary is five words
      (current / updated / stale / unknown / child-base) and `unknown` covers
      BOTH the silent everyday no-remote repo and the loud unreachable-origin
      one. Any allowlist of verdict names is therefore wrong about one of them,
      always — which is exactly why S158 made loudness a CARRIED field. The
      adapter already dropped every quiet record, so `m.baseFreshness` present
      IS the condition; nothing here re-judges it.

   2. THE COPY COMES FROM THE RECORD. The guard wrote one honest sentence
      naming what happened (`reason`), the exact command that clears it (`fix`),
      the prose beside it (`fixNote`) and WHAT is blocking (`blocker`). We
      DISPLAY those. We do not compose a second opinion about git state here,
      because two opinions is one more surface that can be wrong.

   3. THE HEADLINE NAMES WHAT IS BLOCKING, NOT THE COMMIT COUNT. A dirty tree
      that is also 1 behind used to render `⚠ BASE · 1 BEHIND` — and "1 behind"
      is precisely the state the captain was ruled safe to ignore, while the
      dirty tree that actually STOPPED the fast-forward appeared only in the
      body. So the badge leads with the record's carried `blocker` and appends
      the distance after it: the blocking thing first, the measurement second,
      neither invented here. A record with no blocker (nothing is blocking) or
      an unrecognised one falls back to the distance, so an older record — or a
      lane a future LCARS adds — still renders something true.

   `behindBy` may be null (never measured): a rendered "0 BEHIND" from a check
   that measured nothing is the one lie a consumer cannot detect, so null reads
   as an absence, not a zero.

   AMBER, and NEVER A MODAL. Filing is never blocked by any of this — warn
   loudly, file anyway. */

/* blocker token → the two words the badge leads with. The tokens are the
   guard's (skills/lcars-init/lcars-common.sh); this map only spells them for a
   human. Anything not listed falls through to the distance — a badge that
   guessed at an unknown token would be inventing the one thing rule 2 forbids. */
var BASE_BLOCKER_LABEL = {
  "dirty-tree": "DIRTY TREE",
  "diverged": "DIVERGED",
  "not-checked-out": "NOT CHECKED OUT",
  "untracked-clobber": "WOULD OVERWRITE",
  "merge-refused": "MERGE REFUSED",
  "behind-trunk": "BEHIND TRUNK",
  "unreachable": "ORIGIN UNREACHABLE",
  /* NOT a shade of "unreachable": origin answered a ref listing instantly and
     LCARS killed its own bounded fetch at its own deadline. Telling a captain
     their reachable origin is unreachable is the copy-that-lies class, and this
     lane is the one that still carries a runnable `fix`. */
  "fetch-timeout": "FETCH TIMED OUT",
  /* The token is deliberately generic (one lane covers rebase / merge /
     cherry-pick / revert / bisect) and so is its headline — WHICH operation is
     in the record's own sentence, where the guard wrote it. */
  "operation-in-progress": "UNFINISHED GIT OPERATION",
};

function baseFreshnessCopy(bf) {
  if (!bf) return null;
  var v = bf.verdict || "";
  var n = bf.behindBy;
  var measured = (typeof n === "number");
  var blocked = BASE_BLOCKER_LABEL[bf.blocker || ""] || "";
  var badge;
  if (v === "child-base") {
    /* Not a fault, and not this Mission's to answer for: its base IS another
       Mission's branch. The guard carries this quiet, so it should never reach
       here — but if it ever does, the word must not be "stale". */
    badge = "◇ BASE · PARENT MISSION";
  } else if (blocked) {
    /* The blocking condition leads; the distance rides behind it when it was
       really measured (an unreachable origin measured nothing). */
    badge = "⚠ BASE · " + blocked + (measured ? " · " + n + " BEHIND" : "");
  } else if (v === "unknown") {
    badge = "⚠ BASE UNVERIFIED";
  } else if (v === "stale") {
    badge = measured ? ("⚠ BASE · " + n + " BEHIND") : "⚠ BASE STALE";
  } else {
    badge = "⚠ BASE · " + String(v).toUpperCase();
  }
  return { badge: badge, reason: bf.reason || "", fix: bf.fix || "",
           note: bf.fixNote || "" };
}

/* The compact card badge: one pill, the record's sentence as its tooltip. */
function baseFreshnessPill(bf) {
  var copy = baseFreshnessCopy(bf);
  if (!copy) return null;
  var pill = el("span", "pill basefresh", copy.badge);
  /* The long form lives in the detail; on the card the reason is the hover, so
     the badge is never the only thing the captain gets. `Fix:` labels ONLY a
     runnable command — the guidance beside it gets its own unlabelled line, for
     the same reason the detail block does (see baseFreshnessBlock). */
  pill.title = copy.reason
    + (copy.fix ? "\n\nFix: " + copy.fix : "")
    + (copy.note ? "\n\n" + copy.note : "");
  return pill;
}

/* The long form: the badge, the guard's sentence, and its command. Used by the
   mission detail and by the File console's pre-flight line — ONE builder, so
   the two can never describe the same record differently. */
function baseFreshnessBlock(bf, cls) {
  var copy = baseFreshnessCopy(bf);
  if (!copy) return null;
  var wrap = el("div", cls);
  wrap.appendChild(el("div", "bf-head", copy.badge));
  if (copy.reason) wrap.appendChild(el("div", "bf-why", copy.reason));
  /* No empty Fix row: some conditions genuinely have no command that would
     clear them (origin has to come back first), and an empty "Fix:" label
     invites the captain to look for one that isn't there.

     AND `Fix:` LABELS A COMMAND, NOTHING ELSE. A tester pasted two of these
     into a shell — `git stash -u   (or commit your work)   then   git pull
     --ff-only origin main` gave `syntax error near unexpected token '('`, and
     `reach origin first (VPN / network / auth) — then …` was not a command at
     all. The guard now keeps `fix` to one runnable line and puts the
     alternative, the caveat and the manual step in `fixNote`, which renders
     UNLABELLED below it: prose that is never dressed as something to run. */
  if (copy.fix) wrap.appendChild(el("div", "bf-fix", "Fix: " + copy.fix));
  if (copy.note) wrap.appendChild(el("div", "bf-note", copy.note));
  return wrap;
}

/* S164 — THE QUIET LINE. Behind, and nothing for the captain to do about it.
   The commonest state there is: local 'main' is a few commits behind origin and
   fast-forwards cleanly, so the guard records it `stale` and DELIBERATELY QUIET
   (lcars-common.sh step 8b) — the captain's next action, filing, IS the fix, and
   a warning whose only remedy is the thing they were already doing reproduces
   itself forever. Quiet, though, is not SILENT: filing one commit behind, the
   console said nothing at all, and the captain ruled he wants to be told.

   So this is REASSURANCE, and it is built to be unmistakable from the warning
   above it: no ⚠ badge, no `Fix:` command, no amber — the wrapper is marked
   `quiet` and the CSS strips the amber panel from it, one muted line of the
   guard's OWN reason and nothing else.

   The gate is `behindBy` — a MEASURED distance greater than zero. Not a verdict
   allowlist: `loud` is a carried field precisely because two records can share a
   verdict and mean opposite things (S158), and `behindBy: null` means the check
   measured nothing, which is exactly the reassuring-zero lie the guard refuses
   to tell. `updated` is the one exclusion, and it is a MEASUREMENT question, not
   a vocabulary one: its `behindBy` is the distance LCARS already MOVED, not one
   the captain is still at, so "filing brings it up to date" would be false. It
   cannot reach this console anyway — the reporter behind /api/base-freshness
   pins LCARS_BASE_CHECK_ONLY=1 and never moves a ref — but a surface that would
   invent news if it ever did is a surface waiting to lie. */
function baseFreshnessQuietLine(bf) {
  if (!bf || typeof bf.behindBy !== "number" || bf.behindBy <= 0) return null;
  if (bf.verdict === "updated") return null;
  var copy = baseFreshnessCopy(bf);
  if (!copy || !copy.reason) return null;
  /* copy.reason, not a sentence of our own: ONE voice for the base's state
     across the pill, the detail block and this line (see baseFreshnessCopy). */
  return el("div", "bf-quiet", copy.reason);
}

/* The File-console PRE-FLIGHT line. The whole point of the session: a stale or
   dirty base is named on the console the Mission is filed from, not discovered
   afterwards in stdout nobody reads.

   ASYNCHRONOUS AND NON-BLOCKING BY DESIGN. The block is appended EMPTY and
   HIDDEN the instant the console opens, so the captain can start typing at
   once; GET /api/base-freshness (a read — the reporter behind it never moves a
   ref) fills it in when it answers. A quiet verdict, a null answer, or a failed
   request all leave it hidden — silence is the correct output for "nothing for
   you to do here", and a console that shrugged at the captain because a check
   timed out would be worse than one that never checked.

   AND IT IS MOUNTED BELOW THE IDEA FIELD (S160 round 2, D4). Above it, the
   block's late arrival REFLOWED the field the captain was already typing into:
   measured against a real GitHub remote the console was interactive at 37ms and
   the block landed at 1.3–1.8s, moving the textarea's top 131px → 300px in one
   frame — 16.3s against a slow origin. Focus and typed text survived, but the
   field jumped out from under a captain mid-sentence. Reserving the height was
   the alternative and it is worse: the block is ABSENT entirely on the common
   quiet path, so a reservation is a permanent empty gap on every healthy repo.
   Below the field, the block pushes only the engine picker and the footer —
   nothing anyone is typing into — and the overlay is top-anchored
   (`align-items:flex-start`), so the textarea cannot be shifted from beneath.
   It is still on the console, still before the captain commits to filing. */
function fileBaseFreshnessBlock() {
  var wrap = el("div", "file-basefresh");
  wrap.hidden = true;
  fetch("/api/base-freshness")
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var bf = d && d.baseFreshness;
      /* `loud` is read here only because this endpoint reports on the REPO (no
         Mission has been filed yet), so unlike the card payload the quiet
         records were never filtered out upstream. It picks the TREATMENT now
         rather than deciding whether to speak at all: loud → the warning block,
         unchanged; quiet-but-behind → the calm line (S164). */
      if (!bf) return;
      var block = bf.loud ? baseFreshnessBlock(bf, "bf-body")
                          : baseFreshnessQuietLine(bf);
      if (!block) return;
      if (!bf.loud) wrap.className = "file-basefresh quiet";
      wrap.appendChild(block);
      wrap.hidden = false;
    })
    .catch(function () { /* a check that could not run says nothing */ });
  return wrap;
}

/* S70-A: render "which repo am I attached to" + adapter/mode hint in the topbar.
   Depends only on the board shape (board.meta), updated on every live render. */
function renderMeta(meta) {
  // capture the attached repo + forge host for the board's GitHub links. render()
  // already did this before it built the cards (it has to — see
  // captureForgeIdentity); repeated here so renderMeta stays correct on its own.
  captureForgeIdentity(meta);
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

/* ── S163 fix round 5 (D1): the status line has TWO kinds of writer ───────────
 *
 * The tester pressed Go on a batch carrying an unusable model steer, the daemon
 * refused it correctly, and the screen said the opposite. Sampling #status every
 * 15 ms:
 *
 *     +  16ms  Fixes dispatched — child bug missions are being driven…
 *     +  66ms  the logged bugs were NOT dispatched — …
 *     +  99ms  16 active missions
 *
 * The verdict — the one frame that told the captain the run had not happened —
 * lived 33 ms. What erased it was not a competing action: it was `render()`
 * writing its routine "N active missions" line, which every write triggers via
 * `postWrite → refresh → render`. Any action that reports an outcome and then
 * refreshes was racing its own repaint, and the repaint always won.
 *
 * So the two writers are now told apart AT THE CAUSE, rather than by timing:
 *
 *   setStatus(t)      an ACTION speaking. Supersedes whatever was there,
 *                     including a live verdict — newer news wins. Unchanged for
 *                     every existing caller: it writes, exactly as before.
 *   setVerdict(t)     an action's OUTCOME — refused, dispatched, applied-but.
 *                     Sticky: it is what the captain came back to read, so it
 *                     stays until another ACTION has something to say.
 *   setIdleStatus(t)  the ROUTINE repaint describing the board. Yields to a
 *                     live verdict; otherwise identical to before.
 *
 * Nothing here is on a timer. A timer would only have widened the 33 ms window,
 * and a walk-away feature's verdict must not have a lifetime measured in frames.
 */
/* ── S163 fix round 6 (D2 + D4): the two things round 5 left ──────────────────
 *
 * D2 — STICKY AGAINST THE REPAINT, NEVER AGAINST THE CAPTAIN. Round 5 put the
 * clear in `postWrite`, so only a WRITE could retire a verdict. The captain's
 * next move very often is not a write: the tester left a refusal about mission
 * -003 on screen, opened a DIFFERENT mission's Mission Log, previewed and
 * discarded it, and -003's refusal was still there at every one of 100 seconds
 * of samples. True sentence, wrong moment — and the next thing they did read as
 * having produced it.
 *
 * So opening a console retires the last outcome too (`retireVerdict`, called
 * from `openLog`/`openDetail`): a write and a console are the two ways a captain
 * starts anything. Deliberately NOT a timer — this is a walk-away feature, and a
 * verdict that expires on elapsed seconds expires precisely for the captain who
 * was not at the desk to read it. Time is not evidence; an action is.
 *
 * D4 — AND IT HAS TO BE LEGIBLE WHERE IT LANDS. On the modal-closing paths
 * (`File & Cost` refused, the Go's "…but N steers were not applied") the console
 * is gone by the time the daemon answers, so `#status` is the ONLY carrier — and
 * it rendered in `.dim`, #50688a on #030608, 3.6:1 at 12px, with no state class
 * at all. `writeStatus` therefore owns the class list as well as the text: one
 * writer, so a verdict can never arrive dressed as the routine line. The colour
 * is proved by resolving the real cascade in the tests, never by the rule
 * existing — this round has already shipped one amber rule that lost. */
var STATUS_VERDICT = null;
var STATUS_VERDICT_KIND = null;
/* The last routine line the board wrote, so retiring a verdict can put the
   screen back rather than leaving stale words up until the next repaint. */
var STATUS_IDLE = null;

function writeStatus(t, cls) {
  var s = document.getElementById("status");
  if (!s) return;
  s.textContent = t;
  s.className = cls || "dim";
}

function setStatus(t) {
  STATUS_VERDICT = null;   // an action is speaking; the old verdict is history
  STATUS_VERDICT_KIND = null;
  writeStatus(t);
}

/* The outcome of a completed action — kept on screen through every routine
   repaint that follows it (S163 fix round 5).

   Sticky against the REPAINT, never against the captain: `postWrite` drops the
   held verdict the instant another write is dispatched, so an outcome can never
   sit over an action it is not about. That matters most for the dispatches that
   report no copy of their own (Start, pause/resume, discard, reapprove) — with
   nothing else to clear it, a refusal from five minutes ago would still be on
   screen, which is the same lie in the other direction. */
function setVerdict(t, kind) {
  STATUS_VERDICT = t;
  STATUS_VERDICT_KIND = kind || null;
  writeStatus(t, verdictClass(kind));
}
/* The class list a verdict wears. `status-verdict` alone is the neutral,
   prominent one (an outcome worth reading — amber); `err` says the thing did
   not happen; `ok` says it did. All three beat `.dim` because `.dim` is simply
   not on the element — a source-order or specificity win over it would be the
   same fragile arrangement that let `.card .no` mute S162's amber. */
function verdictClass(kind) {
  if (kind === "err") return "status-verdict err";
  if (kind === "ok") return "status-verdict ok";
  // S196: `warn` — it HAPPENED, and it is not finished business (an adopt that
  // carried warnings). Deliberately the neutral, prominent amber rather than a
  // fourth colour: amber already means "an outcome worth reading", which is
  // exactly the register. Named explicitly so it is a decision, not a fallthrough.
  if (kind === "warn") return "status-verdict";
  return "status-verdict";
}
function clearVerdict() { STATUS_VERDICT = null; STATUS_VERDICT_KIND = null; }

/* The captain has started something else — a console, not a write (postWrite
   has its own clear). Drop the held outcome AND put the routine line back,
   because what the captain reads is the screen, not the variable: a console
   opens without a repaint, so a clear that only moved the flag would leave the
   stale sentence up until the next poll. */
function retireVerdict() {
  if (STATUS_VERDICT == null) return;
  clearVerdict();
  if (STATUS_IDLE != null) writeStatus(STATUS_IDLE);
}

/* What the board holds, written on every render. It DESCRIBES; it never
   reports. A live verdict outranks it — and is re-asserted rather than merely
   skipped, so a verdict survives even a repaint that wrote first. */
function setIdleStatus(t) {
  STATUS_IDLE = t;
  if (STATUS_VERDICT == null) writeStatus(t);
  else writeStatus(STATUS_VERDICT, verdictClass(STATUS_VERDICT_KIND));
}

/* ── THE PAINT PATH. Every card the captain ever sees comes through this. ────
   S163 fix round 7 (D1): the `.then(render)` below was DELETED by round 5 while
   the comment beneath it was being written, and the shipping board went
   permanently blank — a healthy daemon, eight 200s in thirty seconds, SSE
   ● LIVE, zero JS errors, zero cards, `#status` frozen on "loading…". 1137 unit
   tests stayed green throughout, because every one of them calls render() by
   hand and none had ever asked the app to paint itself.

   Two lessons, both cheap to keep: a comment goes ABOVE the line it explains,
   never in place of it; and `tests/test_board_boot_paints.py` now boots this
   file the way a browser does and fails if this chain is broken anywhere. */
/* ── S176: the board stops rebuilding itself over nothing ────────────────────
   `connect()` installs setInterval(refresh, LIVE_POLL_MS) and render() opens
   with `root.innerHTML = ""` and rebuilds EVERY card in EVERY column. There was
   no diff and no change check, so the board tore itself down and rebuilt four
   times a minute whether or not a byte had moved. Measured on a 56-mission repo
   (DX-Scorecard, 51 of them done) that is a full teardown + rebuild of 56 cards
   landing on the main thread while the captain is trying to click one. The
   comment below used to call the redundant path "a no-op re-render"; it never
   was one.

   WHY THE PAYLOAD AND NOT `fingerprint()` — read this before "optimising" it.
   The obvious version polls the daemon's fingerprint and skips the FETCH. That
   is wrong and it fails silently: fingerprint() is a DISK signature (mission
   files, main/launch.json, config.json, the detection-marker digest), but
   `meta.holodeck` is assembled from IN-MEMORY daemon session state
   (actions.py `_holodeck`). A holodeck program that starts or stops working
   changes this payload with the fingerprint sitting perfectly still, and the
   unconditional poll is the only thing that has ever surfaced it. Comparing
   what actually came back cannot miss that — or `meta.version`, or any future
   meta contributor — because the thing compared IS the thing drawn.

   The check lives HERE and not inside render() on purpose: repaintBoard() calls
   render(LAST_BOARD) deliberately, with an unchanged payload, to reflect a
   client-side transient. Gating render() itself would turn that into a no-op.

   Fetch-gating is still available later, but it needs a token the daemon
   computes over every meta contributor. That is a bigger change than this, and
   worthless until the board build itself is cheap (S176 part A). */
var LAST_BOARD_SIG = null;

function refresh() {
  return fetch("/api/board").then(function (r) { return r.json(); })
    .then(function (board) {
      var sig = JSON.stringify(board);
      // Unchanged since the last board we actually DREW → leave the DOM alone.
      if (sig === LAST_BOARD_SIG) return;
      LAST_BOARD_SIG = sig;
      render(board);
    })
    // Deliberately setStatus, NOT setVerdict (round 5). This is the READ path
    // failing: an ambient condition, not an action's outcome. It must be
    // replaceable by the next successful render (which writes through
    // setIdleStatus), or a board that came back would keep reporting itself
    // unavailable for ever — the same lie this round exists to kill, inverted.
    .catch(function () {
      // S176: and INVALIDATE the comparison. Without this, a board that failed
      // to arrive is followed by an identical payload that gets skipped as
      // "unchanged" — stranding an unpainted board and a status line stuck on
      // "board unavailable" after the daemon has already come back.
      LAST_BOARD_SIG = null;
      setStatus("board unavailable");
    });
}

/* ════════════════ OVERLAY HOST ════════════════ */
function overlay() { return document.getElementById("overlay"); }
function overlayBody() { return document.getElementById("overlayBody"); }

function showOverlay(node) {
  var body = overlayBody();
  // D8: help RAISES over whatever is on the stage — the console underneath stays
  // in the document (coverConsole hid it) so its live loops keep running, and the
  // help console is simply appended alongside. Every OTHER console REPLACES the
  // stage, which also retires a pending cover: whatever help was holding is gone
  // for good, so a later close can never conjure it back over its replacement.
  if (!isHelpNode(node)) {
    coveredConsole = null;
    body.innerHTML = "";
  }
  body.appendChild(node);
  overlay().hidden = false;
}

/* ── D8/D-A: HELP IS A COVER, NOT A REPLACEMENT (one deep) ──────────────────
   `?` is S140's ONE overlaySafe binding, on purpose: a captain lost inside
   another console is invited to press it. Raising the help console through
   showOverlay() alone therefore DESTROYED what it was raised over — `f`, half
   an idea typed, `?`, Esc landed on the board with the idea gone.

   So the open path COVERS instead. It covers IN PLACE: the console underneath
   never moves, it is only hidden (board.css gives `[hidden]` display:none), and
   the close path un-hides it. Nothing is detached, re-rendered or re-fetched, so
   a textarea's text, the engine picker's chosen option and every console-scoped
   global ride through untouched — the covered console is not being CLOSED, it is
   being covered.

   D-A is why "in place" and not "lifted out and put back". Live loops inside a
   console self-cancel when they find themselves off the document —
   `if (!document.body.contains(node)) { clearInterval(timer); return; }` guards
   the mission detail's Active tick and the Verify launch poll, and re-attaching
   the nodes restarts nothing. Detaching therefore froze a running mission's clock
   for ever and stranded a mid-launch panel on "Launching the app…". A HIDDEN
   element is still document.body.contains(...), so every such guard keeps
   passing and the whole class of defect goes — including loops not written yet.

   One deep is all it takes: help cannot be raised over help. */
var coveredConsole = null; // {nodes, focus} — what the help console sits on

function isHelpNode(node) {
  return !!(node && node.classList && node.classList.contains("help-console"));
}

function helpConsoleOpen() {
  return !overlay().hidden && !!overlayBody().querySelector(".help-console");
}

/* Hide the console currently on the stage, where it stands. Returns null when the
   stage is empty (help opened from the bare board covers nothing). */
function coverConsole() {
  if (overlay().hidden) return null;
  var body = overlayBody();
  // The captain's PLACE in that console — a focused control inside it — is part
  // of intact: a browser blurs the active element the moment it stops being
  // rendered, so remember it and hand it back on the way out (S140's whole point
  // is a keyboard captain).
  var was = document.activeElement;
  var focus = (was && was !== document.body && body.contains(was)) ? was : null;
  var kept = [];
  for (var i = 0; i < body.children.length; i++) {
    var child = body.children[i];
    child.hidden = true;
    kept.push(child);
  }
  return kept.length ? { nodes: kept, focus: focus } : null;
}

/* Show it again, exactly where it never stopped being. True when a console was
   restored, which is closeOverlay()'s signal that this close was a dismissal of
   the COVER, not of the overlay. */
function uncoverConsole() {
  if (!coveredConsole) return false;
  var saved = coveredConsole;
  coveredConsole = null;
  var body = overlayBody();
  // Drop ONLY the help console — the nodes under it are untouched, so nothing
  // that was running stops and nothing has to be restarted.
  var help = body.querySelector(".help-console");
  if (help && help.parentNode) help.parentNode.removeChild(help);
  for (var i = 0; i < saved.nodes.length; i++) saved.nodes[i].hidden = false;
  overlay().hidden = false;
  if (saved.focus && saved.focus.focus) saved.focus.focus();
  return true;
}

function closeOverlay() {
  // D8: closing the help console raised OVER another console gives that console
  // back and stops here — every console-scoped global (onOverlayClose,
  // fileReadinessSync, alignConsoleOpen, the detail's live tick timers) is left
  // untouched because the console underneath never closed. Every close route
  // (Escape, the head's ✕, the footer Close, the backdrop) reaches this one
  // function, so they all restore identically.
  if (uncoverConsole()) return;
  overlay().hidden = true;
  overlayBody().innerHTML = "";
  clearDetailTimers(); // UX-32: never leak the live active-time tick interval.
  fileReadinessSync = null; // S146: drop the File-console re-verdict hook.
  alignConsoleOpen = false; // F1: the console (if it was open) is now dismissed.
  // Fire (and clear) the one-shot close hook — set by renderAlignConsole. F2: closing
  // the CONSOLE mid-grill KEEPS the warm session (no /cancel) and marks its parked
  // mission RESUMABLE so the card flips to ▹ RESUME ALIGN. Closing an UNRELATED overlay
  // (e.g. the detail modal opened mid-scan) has no hook set, so the in-flight alignment
  // is untouched — the click-guard (isAligning) already prevents duplicate spawns.
  var hook = onOverlayClose; onOverlayClose = null;
  if (hook) hook();
}

// click on the dimmed backdrop (outside the modal stage content) dismisses.
overlay().addEventListener("click", function (e) {
  if (e.target === this) closeOverlay();
});
document.addEventListener("keydown", function (e) {
  if (e.key === "Escape" && !overlay().hidden) closeOverlay();
});

/* ════════════════ S140 — THE KEYBOARD COMMAND DECK ════════════════
   The board is drivable without a mouse: arrows walk the card focus, Enter opens
   the focused mission, and single letters fire that mission's REAL controls or
   the global consoles.

   The safety property that makes this cheap: an action key NEVER calls a handler
   and NEVER opens a write path of its own. It resolves the focused card from
   `document.activeElement.closest('[data-mid]')`, querySelectors the card's own
   control by its `data-act` identity, and `.click()`s that element. A hotkey is
   therefore gated IDENTICALLY to the button it triggers — an absent control is a
   no-op, and a disabled one (applyWriteState on a view-only board, a busy
   affordance mid-dispatch) dispatches nothing at all. Read-only stays read-only
   by construction, not by a parallel check that could drift.

   Escape is NOT ours: the listener directly above owns it, and nothing here
   matches it, so it is never double-handled. */

/* GUARD 1's predicate — a typing target must always win the keystroke, so the
   File console's idea box and the Align answer field behave like text fields. */
function isTypingTarget(node) {
  if (!node) return false;
  var tag = node.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || node.isContentEditable === true;
}

function focusedCard() {
  var a = document.activeElement;
  return (a && a.closest) ? a.closest(".card[data-mid]") : null;
}

/* Column-relative navigation walks the RENDERED column containers by DOM
   structure — never a hardcoded stage list — so a re-shaped board (the multi-repo
   round) inherits this unchanged. */
function boardColumns() {
  return Array.prototype.slice.call(document.querySelectorAll(".board .col"));
}
function columnCards(col) {
  return Array.prototype.slice.call(col.querySelectorAll(".card[data-mid]"))
    .filter(function (c) {
      // Skip a collapsed card. A DOM without layout (the test harness) reports no
      // rects API at all — treat those as visible rather than as an empty board.
      return typeof c.getClientRects !== "function" || c.getClientRects().length > 0;
    });
}
function focusFirstCard() {
  var cols = boardColumns();
  for (var i = 0; i < cols.length; i++) {
    var cards = columnCards(cols[i]);
    if (cards.length) { cards[0].focus(); return true; }
  }
  return false;
}
/* ↑ / ↓ — previous/next card in the SAME column, clamped at both ends (a hold
   never runs the focus off the board). */
function navColumn(step) {
  var cur = focusedCard();
  if (!cur) return focusFirstCard();
  var col = cur.closest(".col");
  if (!col) return false;
  var cards = columnCards(col);
  var idx = cards.indexOf(cur);
  if (idx === -1) return false;
  cards[Math.max(0, Math.min(idx + step, cards.length - 1))].focus();
  return true;
}
/* ← / → — the nearest card in the adjacent NON-EMPTY column (empty columns are
   skipped over, not stopped at; a shorter column clamps to its last card). */
function navAcross(step) {
  var cur = focusedCard();
  if (!cur) return focusFirstCard();
  var col = cur.closest(".col");
  if (!col) return false;
  var cols = boardColumns();
  var here = cols.indexOf(col);
  if (here === -1) return false;
  var idx = columnCards(col).indexOf(cur);
  for (var j = here + step; j >= 0 && j < cols.length; j += step) {
    var cards = columnCards(cols[j]);
    if (!cards.length) continue;
    cards[Math.max(0, Math.min(idx, cards.length - 1))].focus();
    return true;
  }
  return false;
}

/* The whole of action dispatch. `acts` is a preference order — the first control
   the focused card actually renders wins (a card shows either Pause or Resume,
   never both). Returns false when the card has no such control, so the key falls
   through to the browser untouched. */
function clickCardAct(acts) {
  var card = focusedCard();
  if (!card) return false;
  for (var i = 0; i < acts.length; i++) {
    var target = card.querySelector('[data-act="' + acts[i] + '"]');
    if (target) { target.click(); return true; }
  }
  return false;
}
function cardActRunner(acts) {
  return function () { return clickCardAct(acts); };
}

/* A band console key clicks the band's own button — same gating, and a build
   without that button (or one whose button is swapped out for a live status, as
   ▸ Deploy Main is during a deploy) is a silent no-op. */
function clickBandControl(id) {
  var b = document.getElementById(id);
  if (!b) return false;
  if (b.disabled) return false;
  if (b.style && b.style.display === "none") return false;
  b.click();
  return true;
}

/* S141 — the ? console. Defined below, next to the ORIENTATION briefing it
   renders; declared here only so the binding table can reference it. */

/* ── THE BINDING TABLE ────────────────────────────────────────────────────────
   ONE structure, and the single source of truth for the command deck. S141
   renders the ? cheatsheet by ITERATING it, so a binding added here shows up in
   the help console with no extra work and the two can never drift.
     keys  — the keycaps to print, in order (human-readable, not DOM key values)
     on    — the LOWERCASED e.key values that trigger it ([] ⇒ documented but
             handled elsewhere, as Escape is)
     scope — "global" | "board" | "card": what the binding acts on
     overlaySafe — may fire while a console is open (GUARD 2's only exception)
     label — the cheatsheet's action line */
var KEY_BINDINGS = [
  { id: "help", keys: ["?"], on: ["?"], scope: "global", overlaySafe: true,
    label: "Open the help console",
    run: function () { openHelp(); return true; } },
  { id: "file", keys: ["f"], on: ["f"], scope: "global",
    label: "Open the File Mission console",
    run: function () { return clickBandControl("fileBtn"); } },
  // OPENS the ▸ Deploy Main console; the deploy itself is that console's own
  // ▸ Deploy button. S141 renders these labels VERBATIM, so a label that said
  // "Deploy the local main build" would ship as a lie in the help console —
  // the key deploys nothing on its own.
  { id: "deploy", keys: ["d"], on: ["d"], scope: "global",
    label: "Open the main-deploy console",
    run: function () { return clickBandControl("deployMainBtn"); } },
  { id: "nav-column", keys: ["↑", "↓"], on: ["arrowup", "arrowdown"],
    scope: "board", label: "Move between missions in a column",
    run: function (e) { return navColumn(e.key === "ArrowDown" ? 1 : -1); } },
  { id: "nav-across", keys: ["←", "→"], on: ["arrowleft", "arrowright"],
    scope: "board", label: "Move between columns",
    run: function (e) { return navAcross(e.key === "ArrowRight" ? 1 : -1); } },
  // Enter AND Space: a card announces role="button", and the WAI-ARIA button
  // pattern owes BOTH keys. Space is safe to claim because `run` returns false
  // in every case where the key isn't actually activating a card — no card
  // focused, or a real BUTTON/A holding the focus — and the listener only
  // preventDefault()s a run that returned true. So Space still scrolls the page
  // off the board, still activates a focused button, and (GUARD 1) still types
  // a space inside the File console's idea box.
  { id: "open", keys: ["Enter", "Space"], on: ["enter", " "], scope: "card",
    label: "Open the focused mission",
    run: function () {
      // A focused BUTTON or link activates itself on Enter/Space — leave that to
      // the browser rather than opening the detail behind the control's action.
      var a = document.activeElement;
      if (a && (a.tagName === "BUTTON" || a.tagName === "A")) return false;
      var card = focusedCard();
      if (!card) return false;
      openDetail(card.getAttribute("data-mid"));
      return true;
    } },
  // Same honesty bar as `d` — and D-C: the label must be true of BOTH card states,
  // because one key resolves data-act=start on whichever card holds focus and the
  // two states put different buttons (and different consoles) there. A HOLDING
  // card's ▶ Start opens the ▶ Launch Mission console (model mix + override box,
  // nothing runs until its ▶ Start Run); a STANDBY card's ▹ START ALIGNMENT opens
  // the ⊹ Alignment Console instead. Naming either one would ship as a lie on the
  // other card, so the label names neither: whichever start console the focused
  // mission offers, the key opens it and never engages a drive by itself.
  { id: "start", keys: ["s"], on: ["s"], scope: "card", acts: ["start"],
    label: "Open the focused mission's start console",
    run: cardActRunner(["start"]) },
  { id: "pause", keys: ["p"], on: ["p"], scope: "card", acts: ["pause", "resume"],
    label: "Pause or resume the focused mission",
    run: cardActRunner(["pause", "resume"]) },
  { id: "verify", keys: ["v"], on: ["v"], scope: "card", acts: ["verify"],
    label: "Open Verify for the focused mission",
    run: cardActRunner(["verify"]) },
  // STAND-DOWN ONLY, and the label says so. The ⚡ RUN control (data-act=launch)
  // is built exclusively by launchAffordance(), which is appended into OVERLAY
  // bodies — never onto a board card. clickCardAct only ever searches INSIDE the
  // focused card, so naming "launch" here would be unreachable code, and inside
  // the detail (where ⚡ RUN does exist) GUARD 2 correctly blocks `l` anyway.
  // Since S141 renders these labels VERBATIM into the cheatsheet, a label
  // promising to start an app would ship as a lie in the help console.
  { id: "launch", keys: ["l"], on: ["l"], scope: "card",
    acts: ["launch-stop"],
    label: "Stand down the focused mission's live app",
    run: cardActRunner(["launch-stop"]) },
  // Documented here so the cheatsheet is complete, but deliberately UNBOUND:
  // the Escape listener above owns it and must not be double-handled.
  { id: "close", keys: ["Esc"], on: [], scope: "global",
    label: "Close the open console", run: null },
];

function hotkeyBindingFor(key) {
  for (var i = 0; i < KEY_BINDINGS.length; i++) {
    var b = KEY_BINDINGS[i];
    if (b.on && b.on.indexOf(key) !== -1) return b;
  }
  return null;
}

document.addEventListener("keydown", function (e) {
  // GUARD 3 — modifier chords belong to the browser and the OS (⌘S, ⌥→, ^C).
  // Shift is NOT a bail: `?` is Shift+/ on most layouts.
  if (e.ctrlKey || e.metaKey || e.altKey) return;
  // GUARD 4 — key auto-repeat. A HELD key streams keydown events where a mouse
  // cannot repeat; each would .click() again, and the write handlers POST
  // without a synchronous in-flight guard. One keystroke = one action.
  if (e.repeat) return;
  var binding = hotkeyBindingFor(String(e.key || "").toLowerCase());
  // Cheap bail before any DOM traversal — most keystrokes are not ours.
  if (!binding || typeof binding.run !== "function") return;
  // GUARD 1 — never hijack typing.
  if (isTypingTarget(document.activeElement)) return;
  // GUARD 2 — an open console owns the keyboard; only `?` may act over it.
  if (!overlay().hidden && !binding.overlaySafe) return;
  if (binding.run(e) !== false) e.preventDefault();
});

/* S140: render() blows the board away and rebuilds it, which would drop the
   keyboard focus to <body> mid-drive (an SSE tick or the 4s safety poll is
   enough). Remember which mission held it and put it back if that card survived
   the rebuild; a card that is gone simply loses focus — never a guess at a
   neighbour, which would silently re-aim the next action key. */
function focusedMissionId() {
  var card = focusedCard();
  return card ? card.getAttribute("data-mid") : null;
}
function restoreCardFocus(mid) {
  if (mid == null) return;
  var sel = '.board .card[data-mid="' + String(mid).replace(/["\\]/g, "\\$&") + '"]';
  var card = document.querySelector(sel);
  if (card) card.focus();
}

/* ════════════════ S141 — THE ? CONSOLE ════════════════
   One modal, two sections, one scroll, reachable two ways (the band's ? button
   and the S140 ? key — the sanctioned overlaySafe exception, so a captain lost
   inside another console can still ask). Esc closes it through the EXISTING
   overlay listener; nothing here handles Escape.

     COMMAND DECK — the keyboard cheatsheet, GENERATED by iterating KEY_BINDINGS.
       There is no second list, so the deck cannot drift from the bindings: add a
       binding to the table and its row appears here with no other edit.
     ORIENTATION — the getting-started briefing, rendered from the declared
       ORIENTATION_BRIEFING structure below rather than assembled from scattered
       string concatenation, so it reads like a document under review and every
       control it names can be walked by a test.

   The console is READ-ONLY by nature: it opens no write path and touches no
   endpoint, which is why the band's ? button is the one control not gated
   through applyWriteState. On a view-only board it adds ONE line saying the
   commands it describes are inert here — the named controls are still on screen
   (disabled, not absent), so the briefing never points at nothing. */

/* Each step names the on-screen controls it refers to, and DECLARES each one:
   the label as printed in the copy, the selector that resolves it, and the
   surface it lives on (band / board / file-console / align-console /
   verify-console). test_help_console.py walks every reference against the real
   surface built by the shipping code — a primer that stops matching the product
   turns the suite red. */
var ORIENTATION_BRIEFING = {
  deckIntro: "Every key acts on the board itself. Typing in a console always "
    + "wins the keystroke, and ⌘ / ⌃ / ⌥ chords stay with your browser.",
  intro: "This board is the bridge. Each card is a Mission — one idea under "
    + "way, travelling left to right from the first interview to a merged pull "
    + "request. The ship drives itself between the columns and stops for you at "
    + "the gates.",
  columns: ["Align", "Research", "Validate", "Plan", "Plan Review", "Schedule",
            "Implement", "Verify", "Done"],
  // D-B: honest about what a view-only build ACTUALLY does, MEASURED rather than
  // assumed — the first two attempts at this line were both wrong because they
  // were reasoned about instead of checked. markViewOnly() disables
  // #deployMainBtn plus every `.board .btn.go/.warn/.danger`, and those ARE the
  // console openers: of the six consoles this briefing names, exactly ONE still
  // opens — ▦ File Mission (#fileBtn lives outside .board and writes nothing by
  // itself; its foot buttons are the gated controls). ▹ START ALIGNMENT, ▶ Start,
  // Answer ▸, ✓ Review PR ▸ and ▸ Deploy Main are all dead where they stand, so
  // their consoles never open at all. ⏸ Pause / ▶ Resume are likewise inert.
  // So the line promises the File console and the reading, names nothing it
  // cannot deliver, and says plainly that the rest is disabled on the spot.
  // ViewOnlyOpenersMeasuredTest re-measures all of this against a real read-only
  // board, so a third wrong wording cannot ship.
  viewOnly: "This board is VIEW-ONLY. Read the board and every Mission freely — "
    + "this reference and the ▦ File Mission console still open, but nothing "
    + "commits from here. Every other write control is disabled where it "
    + "stands, so the console behind it never opens.",
  steps: [
    {
      id: "file",
      title: "1 · File a Mission",
      body: "▦ File Mission in the top band opens the console. Describe the "
        + "idea in plain language — a feature, a change, a fault. Under it, "
        + "Engine picks which CLI flies the Mission; it is set to Claude unless "
        + "you say otherwise. ◇ File to Backlog ▸ puts it on the board as "
        + "standby: filed, not yet interviewed. File & Begin Alignment starts "
        + "the interview now.",
      refs: [
        { label: "▦ File Mission", selector: "#fileBtn", surface: "band" },
        // The console's third control, between the idea box and the foot
        // buttons — named so the step leaves nothing on that surface unaccounted
        // for. It resolves through the same `.field label` idiom the Align step
        // uses (the field carries no id of its own).
        { label: "Engine", selector: ".field label", surface: "file-console" },
        { label: "◇ File to Backlog ▸", selector: ".modal-foot .btn",
          surface: "file-console" },
        { label: "File & Begin Alignment", selector: ".modal-foot .btn",
          surface: "file-console" },
      ],
    },
    {
      id: "align",
      title: "2 · Answer the Align grill",
      body: "Alignment is an interview, not a form: one question at a time, "
        + "each with a recommended answer you can take or override under Your "
        + "answer. The PRD assembles beside the questions as you go. A standby "
        + "card waits in Align until you press ▹ START ALIGNMENT on it. When "
        + "the questions stop the Mission is filed, and its card settles in "
        + "Align with the cost and difficulty of the work read off against it.",
      refs: [
        { label: "▹ START ALIGNMENT", selector: '[data-act="start"]',
          surface: "board" },
        { label: "Your answer", selector: ".field label",
          surface: "align-console" },
      ],
    },
    {
      id: "stages",
      title: "3 · Watch the stages advance",
      body: "▶ Start on a Mission that is holding opens the launch console — "
        + "the model assigned to each stage, and an override box if you want to "
        + "steer that in plain language. ▶ Start Run engages the drive, and "
        + "from there the Mission walks the columns on its own: Align, "
        + "Research, Validate, Plan, Plan Review, Schedule, Implement, Verify, "
        + "Done. ⏸ Pause halts it at the next safe boundary and ▶ Resume "
        + "re-engages. A card under way pulses. Open any card for the full "
        + "readout.",
      refs: [
        { label: "▶ Start", selector: '[data-act="start"]', surface: "board" },
        // The console standing between ▶ Start and the drive. Naming it is the
        // point: the button on the card opens a screen, and the drive is only
        // spawned by THIS control inside it.
        { label: "▶ Start Run", selector: ".modal-foot .btn.go",
          surface: "launch-console" },
        { label: "⏸ Pause", selector: '[data-act="pause"]', surface: "board" },
        { label: "▶ Resume", selector: '[data-act="resume"]', surface: "board" },
      ],
    },
    {
      id: "hails",
      title: "4 · Answer when the ship hails you",
      body: "A stage that cannot decide alone stops and asks — a change of "
        + "scope, a slice it cannot draw, a ticket it could not finish. That "
        + "card turns red and offers Answer ▸. Answer it and the Mission "
        + "resumes from exactly where it stopped.",
      refs: [
        { label: "Answer ▸", selector: '[data-act="answer"]', surface: "board" },
      ],
    },
    {
      id: "verify",
      title: "5 · Review at Verify",
      // The three parts of the review are NOT all unconditional, and the copy
      // must not pretend otherwise. Acceptance criteria always render; "what
      // was built" only when the mission carries tickets or a contract proof;
      // the EST → ACTUAL line only once usage has been recorded against the run
      // (costCompareLine returns null without mi.pills.actual). All three
      // renderings are real and a captain meets each of them.
      body: "Verify is yours. ✓ Review PR ▸ opens the review. The acceptance "
        + "criteria are always there to tick off; beneath them the console adds "
        + "what was built once the run has tickets to show for it, and the "
        + "estimate against what it actually cost once the run has been costed. "
        + "⚡ RUN stands the Mission's app up locally so you can look at the "
        + "real thing first. ✓ Merge PR ships it; ↩ Send Back… returns the "
        + "Mission to Align with your note.",
      refs: [
        { label: "✓ Review PR ▸", selector: '[data-act="verify"]',
          surface: "board" },
        { label: "⚡ RUN", selector: '[data-act="launch"]',
          surface: "verify-console" },
        { label: "✓ Merge PR", selector: '[data-act="merge"]',
          surface: "verify-console" },
        { label: "↩ Send Back…", selector: '[data-act="send-back"]',
          surface: "verify-console" },
      ],
    },
    {
      id: "deploy",
      title: "6 · Deploy main",
      body: "▸ Deploy Main in the top band stands up this repo's local main "
        + "build — the ship as it already sails, not a Mission branch — so you "
        + "can see what is live before you judge what is coming.",
      refs: [
        { label: "▸ Deploy Main", selector: "#deployMainBtn", surface: "band" },
      ],
    },
  ],
};

/* One <kbd> per keycap + the binding's own label. Nothing about a row is written
   by hand: both halves come straight off the KEY_BINDINGS entry. */
function keyRow(binding) {
  var row = el("div", "keyrow");
  var caps = el("div", "keycaps");
  (binding.keys || []).forEach(function (cap) {
    caps.appendChild(el("kbd", null, cap));
  });
  row.appendChild(caps);
  row.appendChild(el("div", "keylabel", binding.label || ""));
  return row;
}

function commandDeckSection() {
  var sec = el("section", "help-sec");
  sec.setAttribute("id", "help-deck");
  sec.appendChild(el("h4", null, "COMMAND DECK"));
  sec.appendChild(el("p", "help-lead", ORIENTATION_BRIEFING.deckIntro));
  var deck = el("div", "keydeck");
  KEY_BINDINGS.forEach(function (b) { deck.appendChild(keyRow(b)); });
  sec.appendChild(deck);
  return sec;
}

function orientationSection() {
  var sec = el("section", "help-sec");
  sec.setAttribute("id", "help-orientation");
  sec.appendChild(el("h4", null, "ORIENTATION"));
  sec.appendChild(el("p", "orient-intro", ORIENTATION_BRIEFING.intro));
  ORIENTATION_BRIEFING.steps.forEach(function (step) {
    var s = el("div", "orient-step");
    s.setAttribute("data-step", step.id);
    s.appendChild(el("div", "step-title", step.title));
    s.appendChild(el("div", "step-body", step.body));
    sec.appendChild(s);
  });
  // The ONE difference a view-only build makes. A read-write board appends
  // nothing here, so its console is byte-identical to a board that never heard
  // of view-only.
  if (writesActive === false) {
    sec.appendChild(el("div", "help-viewonly", ORIENTATION_BRIEFING.viewOnly));
  }
  return sec;
}

function openHelp() {
  // ▤ (U+25A4), not ⌨ (U+2328): every other console title in the product wears a
  // flat geometric glyph from the same family (▦ ▸ ✓ ▶ ⊹ ⌖), and U+2328 has no
  // such form — it falls through to the system EMOJI font and renders as a
  // photorealistic PC keyboard, the only pictorial glyph anywhere on the bridge.
  // D8: one deep. Help over help would either stack a second console or drop
  // the console the first help is holding — pressing ? again is a no-op that
  // leaves the cover, and what it covers, exactly as they are.
  if (helpConsoleOpen()) return true;
  // Lift whatever console is on the stage BEFORE showOverlay() clears it; Esc
  // (or any other close route) puts it back, live and intact.
  coveredConsole = coverConsole();
  var m = modal("▤ Bridge Reference — Command Deck & Orientation", { wide: true });
  m.wrap.className += " help-console";
  m.body.appendChild(commandDeckSection());
  m.body.appendChild(orientationSection());
  m.foot.appendChild(btn("Close", null, closeOverlay));
  showOverlay(m.wrap);
  return true;
}

/* First-run discoverability. A board holding zero Missions says what to do and
   names the ? console; the moment a Mission lands the host hides again and the
   board is byte-identical to before this round. No pulse, no nag, no dismissal
   state to remember. */
function renderEmptyState(count) {
  var host = document.getElementById("boardEmpty");
  if (!host) return;
  host.innerHTML = "";
  if (count > 0) { host.hidden = true; return; }
  host.hidden = false;
  host.appendChild(el("div", "be-title", "NO MISSIONS ON THE BOARD"));
  host.appendChild(el("div", "be-body",
    "File the first one with ▦ File Mission in the top band — "
    + "or press ? for orientation."));
}

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
  // S163 fix round 5: a new write supersedes the previous action's verdict.
  // This is the ONLY thing that clears it for the dispatches that report no
  // copy of their own, and it is why their refusals can safely be verdicts.
  clearVerdict();
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
      /* S169 fix round 1 — the REFUSAL BODY rides along as a second argument.
         Purely additive: every existing handler takes one parameter and is
         byte-identical in behaviour. It exists so a caller can act on a FACT
         the daemon stated (`sessionReset`) instead of reading its sentence,
         which is the classifier road this round exists to stay off. */
      if (onError) onError(msg, res.data || {});
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
    // S163 fix round 5: a VERDICT. There is no modal and no card copy for a
    // pause/resume that was refused — this line is the whole report, and the
    // next SSE tick would otherwise wipe it before it could be read.
    setVerdict(msg, "err");
  });
}

function markViewOnly() {
  writesActive = false;
  var vo = document.getElementById("viewonly");
  if (vo) vo.hidden = false;
  // disable any write controls already on screen.
  var btns = document.querySelectorAll(".board .btn.go, .board .btn.warn, .board .btn.danger");
  btns.forEach(function (b) { applyWriteState(b); });
  // S139: the topbar ▸ Deploy Main button lives outside .board — disable it too
  // on a view-only build (the STOP button in the band is re-created per render,
  // so applyWriteState already governs it).
  var dm = document.getElementById("deployMainBtn");
  if (dm) applyWriteState(dm);
  // S125 (D7): and the ⬡ HOLODECK control, which does NOT go through
  // applyWriteState — a view-only board must SAY why the deck is unavailable,
  // not just grey a button out (see applyHolodeckWriteState).
  applyHolodeckWriteState();
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
    else { writesActive = true; applyHolodeckWriteState(); }
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

/* `store` (S169, FL-014) is OPTIONAL and exists for ONE reason: a surface whose
   textarea is destroyed and rebuilt by a re-render. The three modal surfaces
   below live inside a dialog that is torn down as a whole, so their list is
   safely a closure. The HOLODECK COMPOSER is not: `renderDeck` rebuilds it on
   every turn, program switch and banner, and a paste whose only memory is this
   closure disappears with the node exactly as the typed draft did (FL-013).
   Rather than a second paster beside this one, the list is SEEDED from and
   WRITTEN BACK to the caller's object — `{ get, set }` — so there is still one
   image paster on the board and one place a pasted image is held. */
function attachImagePaster(textarea, onError, store) {
  var imgs = store ? ((store.get() || []).slice()) : [];
  var chips = el("div", "img-chips");
  chips.hidden = true;
  if (textarea.parentNode) {
    textarea.parentNode.insertBefore(chips, textarea.nextSibling);
  }
  function repaint() {
    // EVERY mutation lands here (accept / remove / clear), so this is the one
    // line that has to write the list back.
    if (store) store.set(imgs.slice());
    chips.innerHTML = "";
    chips.hidden = imgs.length === 0;
    imgs.forEach(function (img, i) {
      var chip = el("span", "img-chip");
      chip.appendChild(el("span", "img-chip-name", "[Image #" + (i + 1) + "]"));
      // S140 fix: the ✕ is the console's other span-as-control — same treatment,
      // so an attached image can be dropped without reaching for the mouse.
      var x = keyActivable(el("span", "img-chip-x", "✕"));
      x.title = "Remove this image";
      x.setAttribute("aria-label", "Remove this image");
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
  // A SEEDED LIST HAS TO PAINT ITS CHIPS (S169). Restoring the value of a
  // rebuilt textarea while its "[Image #1]" chip stays missing would be a
  // half-restored draft, which is worse than none: he would send a turn
  // believing the screenshot went with it.
  if (imgs.length) repaint();
  return {
    /* the postWrite payload value: the chip list, or undefined when empty so
       JSON.stringify omits the `images` key and the turn is unchanged. */
    payload: function () { return imgs.length ? imgs.slice() : undefined; },
    clear: function () { imgs = []; repaint(); },
  };
}

/* ════════════════ SCREEN: FILE A MISSION (#file) ════════════════ */
function openFile() {
  /* S183 — the FOUNDATION LOCK, said rather than implied. `paintFoundationLock`
     disables ▦ FILE MISSION, but a hotkey (`f`) and the empty-board prompt both
     reach this function directly, so the console itself refuses: it opens with
     the reason and the way forward, and NO idea box to type into. Establish
     Vision replaces this in S184 — see skills/lcars-init/foundation-gate.sh. */
  var f0 = LAST_BOARD && LAST_BOARD.meta && LAST_BOARD.meta.foundation;
  if (foundationLocked(f0)) {
    var lm = modal("◇ No Test Foundation");
    lm.body.appendChild(el("div", "note",
      FOUNDATION_LOCK_REASON[f0] || FOUNDATION_LOCK_REASON.greenfield));
    lm.body.appendChild(el("div", "note",
      "Every LCARS ticket is proven by RUNNING its tests — red on the parent "
      + "commit, green on the tip. If this repo DOES have a test system and "
      + "LCARS just cannot see it, point LCARS at it with "
      + "`lcars update --test-command '<command>'`."));
    showOverlay(lm.wrap);
    return lm;
  }
  var m = modal("▦ File New Mission");
  // S146: when the repo's test systems are unready, the console opens with the
  // readiness warning ABOVE the idea box — one themed line, the one-click
  // ⚡ FIX, and the manual-override input. A READY repo appends NOTHING here,
  // so its console is byte-identical to before this round. Never blocks filing.
  var tr0 = LAST_BOARD && LAST_BOARD.meta && LAST_BOARD.meta.testReadiness;
  if (tr0) m.body.appendChild(fileReadinessBlock(tr0));
  var idea = el("textarea"); idea.rows = 4;
  idea.placeholder = "What do you want to build, improve, or fix?";
  m.body.appendChild(field("The idea — what do you want to build, improve, or fix?", idea));
  // S160: the base-freshness PRE-FLIGHT. It goes in EMPTY and HIDDEN and fills
  // itself in when the read answers, so it never delays the console by a
  // millisecond and never becomes a wall between the captain and filing. A
  // healthy base adds NOTHING here.
  //
  // BELOW the idea field, not above it (round 2, D4): the check answers 1.3s+
  // after the console is interactive, and mounted above it shoved the textarea
  // down 169px mid-sentence. Everything it can push now — the engine picker and
  // the footer — is something nobody is typing into. The readiness block above
  // stays above: it is rendered from board state ALREADY IN HAND, so it is
  // there in the first frame and moves nothing.
  m.body.appendChild(fileBaseFreshnessBlock());

  // UX-1: the Repository field is removed from the File modal — the viewscreen
  // is per-repo this iteration, so a chooseable repo is useless. The server
  // infers the attached repo; nothing here renders a repo input.

  var engineWrap = el("div", "field");
  engineWrap.appendChild(label("Engine — which CLI drives this mission?"));
  var choice = el("div", "choice");
  var chosen = { engine: "claude" };
  // S140 fix: the picker is keyboard-operable (Tab to it, Enter/Space selects).
  // Attribute + keydown only — the click path and what it does are untouched.
  var optClaude = keyActivable(el("span", "opt", "⬡ Claude"));
  var optCopilot = keyActivable(el("span", "opt", "⬡ Copilot"));
  function pick(engine, node) {
    chosen.engine = engine;
    [optClaude, optCopilot].forEach(function (o) {
      o.classList.remove("sel");
      o.setAttribute("aria-pressed", "false");
    });
    node.classList.add("sel");
    node.setAttribute("aria-pressed", "true");
  }
  optClaude.classList.add("sel");
  optClaude.setAttribute("aria-pressed", "true");
  optCopilot.setAttribute("aria-pressed", "false");
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
  // Park & Align (S137 / FIX-C): PARK is now the DEFAULT primary action (captain
  // ruling). "◇ File to Backlog ▸" files the idea INSTANTLY as a pre-PRD STANDBY
  // mission (POST /api/park → file.sh --park) — NO grill opens. The parked card
  // lands on the board (SSE nudges it); the captain aligns it later from the
  // card's START ALIGNMENT. It is the SOLE teal button in this modal, but SAME
  // size as the others (class "go", not "go big" — captain ruling). Gated through
  // applyWriteState so a view-only board disables it.
  var park = applyWriteState(btn("◇ File to Backlog ▸", "go", function () {
    var text = idea.value.trim();
    if (!text) { showErr(err, "Describe the idea first."); return; }
    park.disabled = true; park.textContent = "Filing…";
    err.hidden = true;
    postWrite("/api/park",
      { idea: text, engine: chosen.engine, images: ideaImgs.payload() },
      function () { closeOverlay(); refresh(); },
      function (msg) {
        park.disabled = false; park.textContent = "◇ File to Backlog ▸";
        showErr(err, msg);
      });
  }));
  // "File & Begin Alignment" is now the SECONDARY (plain, non-teal) option — it
  // opens the interactive Align grilling console (S70-B), the structured
  // one-question-at-a-time interview, not a straight-to-skeleton create. The
  // mission lands in Align when the console completes and file.sh runs.
  // UX-2/UX-7: opening the console spawns a worker turn (several seconds) — show
  // the themed "Scanning the codebase…" indicator inline while it is in flight;
  // it clears on success (console replaces the modal) and on error.
  var fileBusy = workingNode("Scanning the codebase…"); fileBusy.hidden = true;
  m.body.appendChild(fileBusy);

  var go = applyWriteState(btn("File & Begin Alignment", null, function () {
    var text = idea.value.trim();
    if (!text) { showErr(err, "Describe the idea first."); return; }
    go.disabled = true; go.textContent = "Scanning…";
    err.hidden = true; fileBusy.hidden = false;
    openAlignConsole(text, chosen.engine, ideaImgs.payload(), function (msg) {
      go.disabled = false; go.textContent = "File & Begin Alignment";
      fileBusy.hidden = true;
      showErr(err, msg);
    });
  }));
  // Footer order (primary rightmost, per the modal convention):
  // [Cancel] [File & Begin Alignment (secondary)] [◇ File to Backlog ▸ (primary)].
  m.foot.appendChild(go);
  m.foot.appendChild(park);
  showOverlay(m.wrap);
  idea.focus();
}

/* ════════════════ SCREEN: ALIGN GRILLING CONSOLE (#align) ════════════════ */
/* A stateful, multi-turn interview rendered to the mockup's .twopane: one
   question at a time on the LEFT (.qtext + .choice .opt[.rec] + free-form input
   + .progress-line), the PRD assembling LIVE on the RIGHT (.prd-doc). Each
   answer POSTs to /api/align/<sid>/answer; the server spawns the next worker
   turn. On `done` file.sh has already run server-side and the board refreshes. */
function openAlignConsole(idea, engine, images, onStartError, missionId) {
  // Park & Align (S137): with `missionId` this is the grill-COMPLETION of an
  // already-parked mission — the server seeds the session from its idea.md +
  // engine + parked attachments, so the body carries only the id. Otherwise it's
  // a fresh File-console grill (idea/engine/images), byte-identical to before.
  var body = missionId
    ? { missionId: missionId }
    : { idea: idea, engine: engine, images: images };
  postWrite("/api/align/start", body,
    function (state) {
      // BUG-3: the console is opening — re-arm the START ALIGNMENT control (the
      // busy-guard's job is done) and drop the scanning band. renderAlignConsole
      // itself is engine-agnostic and never sees the missionId, so we clear here on
      // its behalf. The console opens whether or not the captain closed an unrelated
      // overlay during this in-flight POST — they clicked START ALIGNMENT; honoring
      // it (rather than aborting on a stray close) is the intent.
      if (missionId) { clearAligning(missionId); repaintBoard(); } // FIX-A: drop band.
      // `completing` = this grill is aligning an ALREADY-PARKED mission (missionId)
      // in place, not filing a brand-new one — so the hand-off copy reads
      // "aligning mission", never "creating mission". F1/F2: missionId is threaded
      // through so the submit handler can markFinalizing and the close hook can mark
      // the mission resumable.
      renderAlignConsole(state, !!missionId, missionId);
    },
    function (msg) {
      // BUG-3: the open failed — drop the busy-guard so the card/detail re-arm.
      if (missionId) { clearAligning(missionId); repaintBoard(); } // FIX-A: drop band.
      if (onStartError) onStartError(msg);
    });
}

/* Park & Align (S137): open the warm Align grill for a PARKED mission (the
   card's START ALIGNMENT). The server seeds it from the parked idea/engine/
   attachments; on completion it dispatches `file.sh --complete <id>` and the
   board refresh swaps the standby card for a normal aligned card. */
function startAlignment(missionId) {
  // S163 fix round 5 — left as setStatus, on purpose. The align console does
  // NOT dispatch through `postWrite`, so nothing in this flow would ever clear a
  // sticky verdict: a captain who retried and got the console open would be
  // reading "could not open the alignment console" over an open console. Making
  // this legible needs the align flow to report its own success first, which is
  // a different session's change. Ledgered, not silently converted.
  openAlignConsole(null, null, null, function (msg) {
    setStatus(msg || "Could not open the alignment console.");
  }, missionId);
}

/* The START/RESUME ALIGNMENT affordance shared by the board card control and the
   detail header (DRY). Takes the card object `m` so it can read the server's resume
   flag (m.alignResume). Precedence (highest first):
     • F1 finalizing  → DISABLED "◐ FINALIZING & COSTING…" (never clickable).
     • BUG-3 scanning → DISABLED "⊹ Scanning…" (open in flight; no re-click).
     • F2 resumable   → clickable "▹ RESUME ALIGN" (reopen the warm grill mid-question).
     • default        → clickable "▹ START ALIGNMENT". */
function startAlignmentControl(m) {
  var id = m && m.id;
  // S169/FL-017: "is a finalize running?" is answered by this tab's submit
  // guard OR by the daemon's published fact — the second is what a reloaded tab
  // reads, and what stops it offering START ALIGNMENT over a live file.sh.
  var fstate = alignFinalizeState(m);
  if (fstate.finalizing) {
    var fin = act("start", btn(scanningLabel(fstate.secs,
                                             "◐ FINALIZING & COSTING…"), "go",
                               null));
    fin.disabled = true;
    fin.title = scanningLabel(fstate.secs,
                              "Finalizing the PRD and estimating cost —"
                              + " this has been running")
      + ". The card updates itself the moment it lands.";
    return fin;
  }
  // S128/FL-009: "is a turn running?" is answered by this tab's click-guard OR by
  // the daemon's published fact — the second is what a reloaded tab reads.
  var scan = alignScanState(m);
  if (scan.scanning) {
    // …and the elapsed time rides the label, so a turn that is merely slow says
    // so rather than sitting silent until something gives up on it.
    var busy = act("start", btn(scanningLabel(scan.secs, "⊹ Scanning…"), "go",
                                null));
    busy.disabled = true;
    busy.title = scanningLabel(scan.secs, "The alignment turn has been running")
      + " — the console opens when its first question lands.";
    return busy;
  }
  if (isResumable(m)) {
    var sid = resumableSid(m);
    return act("start", applyWriteState(btn("▹ RESUME ALIGN", "go", function () {
      resumeAlignment(id, sid);
    })));
  }
  return act("start", applyWriteState(btn("▹ START ALIGNMENT", "go", function () {
    beginAlignment(id);
  })));
}

/* BUG-3: arm the click-guard + busy feedback, then open the warm grill. markAligning
   flips every repaint of this card/detail to the disabled "⊹ Scanning…" control (so
   repeated clicks can't spawn duplicate sessions); FIX-A forces an INSTANT client-only
   repaint so the PERSISTENT animated scanning band (scanningPulse, keyed on isAligning)
   appears the moment of the click — parking/aligning changes no server state, so no SSE
   tick is guaranteed. */
function beginAlignment(id) {
  markAligning(id);
  repaintBoard(); // FIX-A: draw the scanning band now, not only on the next SSE tick.
  startAlignment(id);
}

/* F2: reopen a backgrounded Align grill at its current question. GET the session's
   open turn and render the console (completing=true so the hand-off copy reads
   "aligning", and missionId threaded for finalize/close bookkeeping). If the warm
   session has aged out (404 — daemon restart or a very old session), drop the
   resumable flag and fall back to a fresh START ALIGNMENT so the captain is never
   stuck on a dead RESUME button. */
function resumeAlignment(missionId, sid) {
  if (!sid) { startAlignment(missionId); return; }
  fetch("/api/align/" + enc(sid), { headers: { "Accept": "application/json" } })
    .then(function (r) {
      if (r.ok) return r.json();
      if (r.status === 404) {
        clearResumable(missionId); repaintBoard();
        startAlignment(missionId);
      }
      return null;
    })
    .then(function (state) {
      if (!state) return;
      renderAlignConsole(state, true, missionId);
    })
    .catch(function () {
      // S163 fix round 5 — setStatus, same reason as startAlignment above: this
      // flow has no `postWrite` to clear a verdict, so a sticky one could sit
      // over a console that opened fine on the retry.
      setStatus("Could not reach the alignment console.");
    });
}

function renderAlignConsole(state, completing, missionId) {
  // `completing` (Park & Align): true when this grill is ALIGNING an already-
  // parked mission in place (vs filing a brand-new one) — drives the closing-turn
  // hand-off copy below so a parked mission never reads "creating mission".
  // `missionId` (F1/F2): the parked mission being aligned — threaded so the submit
  // handler can markFinalizing on the closing turn and the close hook can mark the
  // mission RESUMABLE. Absent for a fresh File-console grill (no card yet).
  // a session that resolved in one shot (trivial mission) → straight to done.
  if (state.status === "done") { renderAlignDone(state); return; }
  // F2: the console is (re)opening for this mission — it is ACTIVE again, so drop any
  // resumable flag and repaint the card away from ▹ RESUME ALIGN.
  if (missionId) { clearResumable(missionId); repaintBoard(); }

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
    // S140 fix: the answer options are the SAME span-as-control idiom as the File
    // console's engine picker, and this console is one screen on from "File &
    // Begin Alignment" — so a captain filing from the keyboard hits it. One place
    // writes/clears the selection, so the announced state (aria-pressed) can
    // never drift from the .sel chrome.
    function clearOptSel() {
      Array.prototype.forEach.call(choices.children, function (o) {
        o.classList.remove("sel");
        o.setAttribute("aria-pressed", "false");
      });
    }
    function selectOpt(node, val) {
      clearOptSel();
      node.classList.add("sel");
      node.setAttribute("aria-pressed", "true");
      picked.val = val;
    }
    (q.choices || []).forEach(function (c) {
      var isRec = (q.recommended != null && c === q.recommended);
      // Dedupe the "recommended" indicator (S67): some workers (Copilot) bake
      // "(recommended)" into the option label text, others (claude) don't. When
      // the label text already carries it, the text IS the indicator — suppress
      // the REC pill via .no-pill (keep .rec/.sel highlight). When it doesn't,
      // the pill is the sole indicator and stays. Net: exactly one per option.
      var textHasRec = /\(\s*recommended\s*\)/i.test(c);
      var cls = "opt" + (isRec ? " rec" + (textHasRec ? " no-pill" : "") : "");
      // keyActivable: Tab reaches the option, Enter/Space picks it — the same
      // node the mouse clicks, so there is one handler and one behaviour.
      var opt = keyActivable(el("span", cls, c));
      opt.setAttribute("aria-pressed", "false");
      opt.addEventListener("click", function () {
        selectOpt(opt, c); free.value = "";
      });
      choices.appendChild(opt);
      if (isRec) selectOpt(opt, c);
    });
    // a free-form answer overrides any picked choice.
    free.addEventListener("input", function () {
      if (free.value.trim()) {
        clearOptSel();
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
    // F1: answering the CLOSING turn runs the estimate + file.sh --complete
    // server-side inside this POST. Mark the parked mission FINALIZING now so — if the
    // captain backgrounds the console — the card shows the "◐ Finalizing & costing…"
    // band with a disabled control until the server finishes. No-op without a
    // missionId (a fresh File-console grill has no card to badge).
    if (closing.val && missionId) { markFinalizing(missionId); repaintBoard(); }
    // UX-2: the worker turn (and, on the final answer, the file.sh hand-off)
    // runs server-side within this POST. Show the themed working indicator the
    // whole time; it clears on the next question, on done, or on error.
    // BUG-015: when the captain is answering the CLOSING turn, this POST runs the
    // slow cold-opus estimate + mission file/complete — show a DISTINCT loading copy
    // so it reads as progress, not a stuck grill spinner. Otherwise it's a normal
    // between-questions grill turn. Park & Align: a parked mission already EXISTS, so
    // it's being ALIGNED in place, never "created".
    busy.querySelector(".lcars-working-label").textContent = closing.val
      ? (completing ? "Estimating cost & aligning mission…"
                    : "Estimating cost & creating mission…")
      : "Formulating the next inquiry…";
    busy.hidden = false;
    postWrite("/api/align/" + enc(sid) + "/answer",
      { answer: answer, images: freeImgs.payload() },
      function (st) {
        busy.hidden = true;
        freeImgs.clear();   // attached images consumed by this turn
        if (st.status === "done") {
          // F1: the finalize completed server-side — drop the FINALIZING band (the
          // board refresh from postWrite already shows the aligned card).
          if (missionId) clearFinalizing(missionId);
          if (!alignConsoleOpen) {
            // F1: the captain BACKGROUNDED the console mid-finalize — don't pop the
            // success modal over the board; the refresh already swapped in the
            // aligned card. Just repaint so the card drops its finalizing band.
            repaintBoard();
            return;
          }
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
        // S169/FL-017 — THE OTHER HALF OF "RELEASED BY AN EVENT". The guard was
        // armed on the closing submit and, before this, only the SUCCESS path
        // dropped it: a finalize that failed — a dead daemon, a 502 from the
        // estimator, a network drop — left the card banded and its control
        // disabled forever, with the timer that used to bail it out now gone.
        // The POST settling is the event, and settling includes settling badly.
        if (missionId) { clearFinalizing(missionId); repaintBoard(); }
        submit.disabled = false; submit.textContent = "Submit & Continue ▸";
        showErr(err, msg);
      });
  };

  // F2: dismissing this console (✕ / backdrop click / Esc — all route through
  // closeOverlay) KEEPS the warm worker session so the captain can RESUME at this
  // exact question — it no longer POSTs /cancel. For a parked mission (missionId) we
  // mark it RESUMABLE and repaint so its card flips to ▹ RESUME ALIGN instantly. If
  // the mission is FINALIZING (the captain closed while the closing turn estimates),
  // leave that alone — F1 owns the card's band and the mission is completing, not
  // resumable. A fresh File-console grill (no missionId) has no card; its warm
  // session simply lingers in memory (ages out on its own — v1 in-memory only).
  onOverlayClose = function () {
    if (!missionId || !sid) return;
    if (isFinalizing(missionId)) return;   // this tab armed it on the submit.
    markResumable(missionId, sid);
    repaintBoard();
  };
  alignConsoleOpen = true; // F1: the console is now the open overlay.
  showOverlay(m.wrap);
  paintQuestion(state);
}

/* Alignment reached: file.sh has already run server-side and the board has
   refreshed (the new card sits in Align). Show a brief confirmation. */
function renderAlignDone(state) {
  // BUG-3: the align completed server-side (file.sh ran) — there is no warm
  // session left to reap, so drop any close hook the console had set.
  onOverlayClose = null;
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
          // S163 fix round 5: a VERDICT — the modal closed on dispatch, so this
          // is the captain's only account of a start that did not happen, and
          // the `refresh()` on this very line used to erase it.
          clearStarting(id); setVerdict(msg, "err"); refresh();
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
    case "environment":
      // S157 × #93. The full-suite gate could not re-run the suites against a
      // trustworthy dependency environment (the worktree was symlinked to a
      // shared install its own lockfile had replaced). NOT a code problem, and
      // the harness deliberately dispatched NO worker — no edit to any ticket
      // clears a stale toolchain. This wording tracks what the CLI prints for the
      // same gate (escalate_full_suite_regression’s environment branch); the two
      // surfaces must not invent separate stories for one event.
      return "Why you’re seeing this — your TOOLCHAIN is stale, not your code. " +
        "The tests were re-run against dependencies this branch’s own lockfile " +
        "replaced, so the harness cannot tell whether anything regressed — and no " +
        "ticket is implicated. Nothing here is a decision about the work: repair " +
        "the provisioning (`lcars update`) and run the mission again.";
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
    m.body.appendChild(linkedBugsSection(kids));
  }

  // S134: the CONTRACT AMENDMENTS block for the parent mission's own tickets.
  // Null (nothing appended) for a pre-S133 mission → byte-identical.
  var reAmend = contractAmendments(mi);
  if (reAmend) m.body.appendChild(reAmend);

  // S113: EST → ACTUAL cost line (present only when this mission has usage).
  var costLine = costCompareLine(mi);
  if (costLine) m.body.appendChild(costLine);

  // S109: RUN / STOP the mission's app so the captain can view it during re-verify.
  m.body.appendChild(launchAffordance(mi));

  var err = el("div", "errline"); err.hidden = true; m.body.appendChild(err);

  // Send-back reveals a feedback field, then dispatches the feedback decision.
  var fbWrap = el("div"); fbWrap.hidden = true;
  var fb = el("textarea"); fb.rows = 2;
  // A logged bug's send-back loops the BUG(s) back to Plan (feedback.sh routes a
  // type=bug+parent mission to Plan, not Align) — the parent mission + its PR are
  // untouched. This gate is always about logged bugs, so name Plan, not Align.
  fb.placeholder = "What still needs to change? This loops the affected logged bug(s) back to Plan — the parent mission and its PR stay put.";
  fbWrap.appendChild(field("Feedback for send-back", fb));
  m.body.appendChild(fbWrap);

  var sendBack = act("send-back", applyWriteState(btn("↩ Send Back…", "danger", function () {
    if (fbWrap.hidden) { fbWrap.hidden = false; fb.focus(); return; }
    var note = fb.value.trim();
    if (!note) { showErr(err, "Send-back needs a feedback note."); return; }
    sendBack.disabled = true;
    postWrite("/api/mission/" + enc(mi.id) + "/verify",
      { decision: "send-back", feedback: note },
      function () { closeOverlay(); },
      function (msg) { sendBack.disabled = false; showErr(err, msg); });
  })));
  var accept = act("accept", applyWriteState(btn("✓ Accept the Fixes", "go big", function () {
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
  })));
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
      var stop = act("launch-stop", applyWriteState(btn("■ STOP", "danger", function () {
        err.hidden = true; busy.hidden = false;
        busyLabel(busy, "Standing the app down…");
        stop.disabled = true;
        postWrite("/api/mission/" + enc(mi.id) + "/launch/stop", {},
          function () { reload(); },
          function (msg) {
            busy.hidden = true; stop.disabled = false; showErr(err, msg);
          });
      })));
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
      var run = act("launch", applyWriteState(btn("⚡ RUN", "go", function () {
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
      })));
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
    } else if (mi.contractProof) {
      // S134 parity: a SINGLE-ticket mission carries no ticket rows, but its lone
      // ticket's proof-of-work rides the mission as `contractProof`. Surface the
      // PROVEN / N/A chip so the board matches the CLI verify-summary. Absent for
      // a pre-S133 / multi-ticket mission → this branch never fires (byte-identical).
      var bh1 = el("h4"); bh1.style.margin = "16px 0 8px";
      bh1.textContent = "What was built";
      m.body.appendChild(bh1);
      m.body.appendChild(buildSummary(mi));
    }

    // S134: the CONTRACT AMENDMENTS block (declared test edits). Null (nothing
    // appended) for a pre-S133 mission, so the readout is byte-identical.
    var amend = contractAmendments(mi);
    if (amend) m.body.appendChild(amend);

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
    // A logged-bug child loops back to PLAN on send-back (feedback.sh routes a
    // type=bug+parent mission to Plan) and its fix rides the PARENT's PR, so the
    // PR is never touched. A top-level mission loops back to Align (and closes its
    // own PR). Name the right target so send-back reads as what it actually does.
    fb.placeholder = isBugChild
      ? "What needs to change? This loops this bug back to Plan — the parent mission’s PR is untouched."
      : "What needs to change? This loops the mission back to Align"
        + (mi.prUrl ? " and closes the PR." : ".");
    fbWrap.appendChild(field("Feedback for send-back", fb));
    m.body.appendChild(fbWrap);

    var sendBack = act("send-back", applyWriteState(btn("↩ Send Back…", "danger", function () {
      if (fbWrap.hidden) { fbWrap.hidden = false; fb.focus(); return; }
      var note = fb.value.trim();
      if (!note) { showErr(err, "Send-back needs a feedback note."); return; }
      sendBack.disabled = true;
      postWrite("/api/mission/" + enc(id) + "/verify",
        { decision: "send-back", feedback: note },
        function () { closeOverlay(); },
        function (msg) { sendBack.disabled = false; showErr(err, msg); });
    })));
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
    var merge = act("merge", applyWriteState(btn(mergeLabel, "go big", function () {
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
    })));
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
/* `opts.fix` (S163) — this console was opened by the card's "⚙ FIX N FILED BUGS"
   control rather than by the Mission Log button, i.e. the captain is coming BACK
   to a batch that is already filed. Exactly one behaviour changes: when the
   daemon is holding no session (it restarted), the console loads the read-only
   view of the bugs already linked to this parent instead of opening blank. Same
   console, same restore, same Go — one option, no second flow. */
function openLog(id, opts) {
  opts = opts || {};
  /* S163 fix round 6 (D2): opening a console is the captain starting something
     else, so the last action's outcome stops being the news — EXCEPT when this
     open IS that action's continuation. A refused Go reopens the review and
     hands its own reason in through `opts.error`; retiring the verdict there
     would delete round 5's cure while curing round 6's defect. */
  if (!opts.error) retireVerdict();
  fetchMission(id, function (mi) {
    var m = modal("⌖ Mission Log — against " + idLabel(mi), { wide: true, headClass: "pink" });

    var report = el("textarea"); report.rows = 3;
    report.placeholder = "Describe the bug(s) — one or many; we’ll split them.";
    m.body.appendChild(field("What went wrong? (one or many — we’ll split them)", report));

    /* S163 fix round 3 (D1) — the WAITING-BUGS review, its own panel.

       The bugs on this mission that are still waiting to be fixed, with their
       cost pills and their per-bug steer boxes: the captain's ruling, "show me
       everything that will run". At `filed`/`partial` the daemon's own children
       list already IS that list, so `preview` below renders it and this stays
       empty. It earns its own node for the OTHER statuses — a second report
       mid-author, or one that filed nothing — where the console has two true
       things to say at once and must not choose between them:

         • these N bugs are waiting to be fixed  (this panel, + a live Go)
         • these M bugs' text never filed        (`recover` below, + File)

       That was D1: clicking "⚙ FIX 2 FILED BUGS" landed in the failed report's
       console — no pills, no steers, a Go that could only refuse — and the only
       exit was `Discard Preview`, which throws the unfiled text away. Neither
       fact may cost the other, so both are on screen. It sits ABOVE the
       authoring preview because the captain arrived here for the review. */
    var fixPanel = el("div"); fixPanel.hidden = true;
    m.body.appendChild(fixPanel);

    var preview = el("div");
    m.body.appendChild(preview);

    // S161 fix round 2 (N1) — the RECOVERY panel: the authored text of the bugs a
    // filing did NOT get onto disk. Empty (and hidden) unless the daemon reports a
    // shortfall it is still holding text for.
    var recover = el("div"); recover.hidden = true;
    m.body.appendChild(recover);

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

    // Mirrors the DAEMON's session (S161) for this console's lifetime: the
    // authored bug PRDs, the captain's per-bug override inputs (S74), and the
    // `sessionId` that lets the daemon file them. Pre-S161 these PRDs lived ONLY
    // here, so closing the console between Preview and File threw them away and
    // the captain had to re-run (and re-pay for) the split worker. Now the daemon
    // holds them and this is a cache: `restoreLogSession()` below rebuilds it from
    // GET /api/mission/<id>/log/session whenever the console is reopened.
    var authored = { prds: null, overrides: [], filed: false, sessionId: null,
                     // S163 fix round 3 (D2): the post-File steers, KEYED BY THE
                     // BUG'S MISSION ID. They used to be a positional list that
                     // the daemon re-paired against a DIFFERENT list, which is
                     // how "all:opus" typed against the third bug was written
                     // onto the first — a bug that was never on screen. An id
                     // cannot slide onto its neighbour. (`overrides` stays the
                     // positional FILE-time array, where the bugs have no ids
                     // yet and position is all there is.)
                     // S163 fix round 4 (D1): pre-seeded with whatever a
                     // REFUSED Go handed back for this parent, so reopening the
                     // review restores the captain's own words rather than
                     // asking them to remember what they typed. S163 fix round
                     // 5: PEEKED, not consumed — the refusal reopens this
                     // console itself now, and closing that reopened console
                     // must not be what loses the words.
                     steers: peekSteers(id) || {},
                     // how many bugs on this mission are waiting to be fixed —
                     // what Go will drive, even when this console is also
                     // holding an un-filed report.
                     waiting: 0,
                     // the daemon's session status, mirrored so the footer can
                     // tell "nothing landed yet" (discardable) from "bugs are on
                     // disk" (keep it — the card should keep saying so).
                     status: null,
                     // S161 fix round 3 (R1): how many authored bugs the daemon is
                     // still holding UNFILED, and their titles — what a re-preview
                     // would destroy, so the console can name it before it happens.
                     unfiled: 0, unfiledTitles: [] };
    // S162: the control's name. It DISPATCHES the filing — the estimator runs
    // once per logged bug, server-side — and hands the captain the parent card,
    // so the name says what the click is going to cost them rather than just
    // "File". The retry label ("File N Remaining") is built from the same word.
    var fileLabel = "File & Cost";
    /* The retry control's SEMANTIC name — what File MEANS for the session this
       console is holding right now ("File & Cost" for a fresh split, "File N
       Remaining" for a shortfall retry). Kept beside the button and written only by
       `setFileLabel`, because the DOM text is not a safe source for copy that
       names the control: it goes transient during a dispatch ("Filing…") and, if
       a state change forgets to relabel, stale. */
    var fileName = fileLabel;
    var LOG_POLL_MS = 900;
    var pollTimer = null;

    function busyLabel(text) {
      busy.querySelector(".lcars-working-label").textContent = text;
    }

    function consoleLive() {
      // the overlay body is emptied on close, detaching this modal — stop then.
      return document.body.contains(m.wrap);
    }

    function stopPoll() {
      if (pollTimer) { clearTimeout(pollTimer); pollTimer = null; }
    }

    /* Re-arm a footer control after a dispatch settles. Goes back through
       applyWriteState so a VIEW-ONLY board keeps it disabled — clearing
       `disabled` blindly would hand a read-only board a live write button. */
    function rearm(button, label) {
      button.disabled = false;
      button.textContent = label;
      return applyWriteState(button);
    }

    /* Re-arm the File control AND record what it now means. Every state that
       settles the File control goes through here, so the button, its tooltip and
       the copy that names it can never drift apart. */
    function setFileLabel(label) {
      fileName = label;
      // BEFORE rearm: applyWriteState (inside it) overwrites the title with the
      // view-only reason, and on a read-only board that message must win.
      file.title = fileTitle();
      return rearm(file, label);
    }

    /* S162 — what File & Cost will actually DO, from the state of this console.
       With a daemon session it dispatches and hands over the card; without one
       (a restart dropped the session) the legacy POST holds until every estimate
       is in. Two behaviours, so two sentences — a single tooltip would be a lie
       half the time. */
    function fileTitle() {
      return authored.sessionId
        ? ("File the logged bugs and run the cost estimator on each one. This " +
           "dispatches — you can close this console and watch the mission card.")
        : ("File the logged bugs and run the cost estimator on each one. This " +
           "holds here until every estimate is in.");
    }

    /* While the daemon is filing (the estimator runs per bug — the long step) the
       console follows the session rather than holding a POST open. The captain may
       close the console at any point; the poll simply stops and the parent card's
       `logFiling` stamp carries the truth. */
    function pollSession() {
      stopPoll();
      if (!consoleLive()) return;
      pollTimer = setTimeout(function () {
        pollTimer = null;
        if (!consoleLive()) return;
        fetchLogSession(id, function (s) {
          if (!consoleLive()) return;
          // no session any more — it was discarded, replaced by a newer preview,
          // or the daemon went away. We can't tell which from here, so we don't
          // claim to: just stop showing an in-flight filing.
          if (!s) { busy.hidden = true; return; }
          if (s.status === "filing") { pollSession(); return; }
          adoptSession(s);
        }, pollSession);
      }, LOG_POLL_MS);
    }

    /* Render the console FROM a daemon session payload — the one function both
       the restore-on-reopen path and the file-dispatch path go through, so a
       reopened console and a live one can never disagree. */
    function adoptSession(s) {
      if (!s) return;
      authored.sessionId = s.sessionId || null;
      authored.status = s.status || null;
      // S163 fix round 3: how many bugs this MISSION has waiting, from the
      // daemon. Drives the Go's arming in every state, so a console holding an
      // un-filed report still offers to run the bugs that are already on disk.
      authored.waiting = (s.waiting || []).length ||
        (typeof s.waitingCount === "number" ? s.waitingCount : 0);
      // R1: mirror what the daemon still holds unfiled, so the Preview control can
      // say what a re-split would throw away instead of doing it quietly.
      authored.unfiled = (s.unfiled || []).length;
      authored.unfiledTitles = (s.unfiled || []).map(function (u) {
        return u.title || "Untitled bug";
      });
      disarmDiscard();
      var kids = s.children || [];
      // `filed` = the daemon's post-condition check found EVERY authored bug on
      // disk. `partial` = only some of them did (S161 fix D1) — the batch as
      // requested did NOT happen, so it is deliberately NOT `filed`: the children
      // that landed are real and reviewable (Go can drive them), the shortfall is
      // stated instead of swallowed, and File becomes a RETRY of the bugs that are
      // missing (S161 fix round 2 / N1 — the daemon files only those, so the
      // children that landed can never be duplicated).
      if (s.status === "filed" || s.status === "partial") {
        stopPoll();
        authored.prds = null;          // the bugs exist now; Go only resolves
        authored.filed = true;
        authored.resolved = indexOverrides(s.overrides);
        busy.hidden = true;
        // S163 fix round 6 (ledger): a Go over an EMPTY review is a control
        // whose only possible outcome is a refusal. The tester reached one by
        // filing a report that detected no bugs — "Review — 0 bug missions
        // waiting to be fixed", with Go ▸ live above it. The panel IS the
        // promise about what Go runs, so an empty panel offers no Go.
        run.hidden = !(s.children || []).length;
        rearm(prev, "Preview");
        // the daemon's `children` here IS the waiting list (S163 fix round 3),
        // so the main panel is the review and `fixPanel` has nothing to add.
        renderLogFixReview(fixPanel, null, idLabel(mi), authored);
        renderLogPreview(preview, s, idLabel(mi), authored);
        // N1: at `partial` the bugs that did NOT land are still held by the
        // daemon, so show their authored text (nothing the split worker wrote is
        // lost) and turn File into a RETRY of exactly those. Before this fix File
        // sat hidden-but-enabled at `partial`, offering an action whose only
        // possible outcome was a 409, while the missing bug's PRD was gone.
        var left = (s.status === "partial")
          ? ((s.unfiled || []).length || Math.max(0, (s.bugCount || 0) -
                                                     (s.filedCount || 0)))
          : 0;
        renderLogUnfiled(recover, s.status === "partial" ? s.unfiled : null);
        file.hidden = !left;
        setFileLabel(left ? "File " + left + " Remaining" : fileLabel);
        if (s.status === "partial") {
          showErr(err, s.error || "Some of the logged bugs did not file — the " +
                                  "ones below are on disk; the rest are still " +
                                  "held here, so File again retries just those.");
        }
        markDismissState();
        return;
      }
      authored.prds = kids.map(function (c) { return c.prd; });
      authored.imageRefs = kids.map(function (c) { return c.imageRefs || []; });
      authored.overrides = (s.steers && s.steers.length)
        ? s.steers.slice() : kids.map(function () { return ""; });
      authored.filed = false;
      // S163 fix round 3 (D1): the authoring statuses. The bugs already waiting
      // on this mission are real and reviewable whatever this report is doing,
      // so the review panel + Go come from `waiting`, not from `filed`.
      renderLogFixReview(fixPanel, s.waiting, idLabel(mi), authored);
      run.hidden = !authored.waiting;
      if (s.status === "filing") {
        busyLabel("Filing bugs and estimating each fix…");
        busy.hidden = false;
        // "Filing…" is TRANSIENT progress text, not the control's name — leave
        // `fileName` alone so any copy that names the retry keeps naming it.
        file.hidden = false; file.disabled = true; file.textContent = "Filing…";
        renderLogPreview(preview, s, idLabel(mi), authored);
        renderLogUnfiled(recover, null);
        markDismissState();
        pollSession();
        return;
      }
      // previewed | failed — the authored bugs are STILL held by the daemon, so
      // File is armed again and a retry costs no second split worker turn.
      stopPoll();
      busy.hidden = true;
      file.hidden = !kids.length;
      setFileLabel(fileLabel);
      renderLogPreview(preview, s, idLabel(mi), authored);
      // N1: at `failed` nothing reached disk, so every authored bug is recoverable
      // text — show it (the preview list carries titles only, and the captain has
      // to see what log.sh refused in order to fix it).
      renderLogUnfiled(recover, s.status === "failed" ? s.unfiled : null);
      if (s.status === "failed") {
        showErr(err, s.error || "Filing the logged bugs failed — try again.");
      }
      markDismissState();
    }

    /* ── S161 fix round 3 (R1): Preview must not quietly destroy held text ────
       At `partial` the footer read [Discard Unfiled] [Preview] [File 1 Remaining]:
       the one control that WARNED was the deliberate escape hatch, and the one that
       actually lost the captain's ~25s split — Preview, which replaces the session
       and with it the authored text of every bug that never reached disk — carried
       no warning and not even a tooltip.

       The DAEMON is the guard (it refuses such a preview outright; a client can
       always be bypassed, and the tester reached this by posting straight at the
       API). This half makes the choice legible rather than surprising: the first
       click ARMS the discard, relabelling itself to name what it would cost, and
       only the second click sends `discardUnfiled` — the same explicit consent the
       daemon requires. With nothing stranded (`previewed`, or a fully `filed`
       batch) Preview is exactly what it always was: one click, no ceremony. */
    var discardArmed = false;
    var PREVIEW_TITLE = "Split the report above into bug missions — one worker " +
      "turn, replacing whatever this console is currently holding";

    /* How many authored bugs a re-split would destroy the only copy of. */
    function strandedCount() {
      if (!authored.sessionId) return 0;
      if (authored.status !== "partial" && authored.status !== "failed") return 0;
      return authored.unfiled || 0;
    }

    function strandedNames() {
      var t = (authored.unfiledTitles || []).slice(0, 3).map(function (n) {
        return "“" + n + "”";
      });
      var rest = (authored.unfiledTitles || []).length - t.length;
      return t.join(", ") + (rest > 0 ? " and " + rest + " more" : "");
    }

    function armDiscard(n) {
      discardArmed = true;
      rearm(prev, "Preview & Discard " + n + " Unfiled");
      prev.title = "Click again to re-split the report and THROW AWAY the " +
        "authored text of the " + n + " bug" + (n === 1 ? "" : "s") +
        " that never filed";
      showErr(err, "Preview would re-split the report and throw away the " +
        "authored text of " + n + " bug" + (n === 1 ? "" : "s") +
        " that never reached disk (" + strandedNames() + ") — that split is " +
        // name the retry control by the label it is CARRYING for this session
        // ("File & Cost" at `failed`, "File N Remaining" at `partial`) — copy that
        // guesses eventually lies about the UI it points at. Read it from
        // `fileName`, not from the DOM: the button's text goes transient while a
        // file dispatch is in flight, and a warning that says “Filing…” keeps
        // your bugs names a control that does not exist.
        "already paid for. “" + (fileName || fileLabel) + "” keeps " +
        (n === 1 ? "it" : "them") + "; click Preview again to discard " +
        (n === 1 ? "it" : "them") + " and re-split.");
    }

    function disarmDiscard() {
      discardArmed = false;
      rearm(prev, "Preview");
      prev.title = PREVIEW_TITLE;
    }

    /* ── S161 fix D3: the abandoned-preview escape hatch ──────────────────────
       A live session stamps `logFiling` on the parent card, and before this there
       was no way to clear it — the endpoints the captain would reach for
       (log/cancel, log/discard, log/close) all 404'd, so an abandoned preview sat
       on the card until the daemon restarted.

       The parity we copy is Align's, and Align's is deliberate in BOTH halves:
       `POST /api/align/<sid>/cancel` exists, and yet dismissing the grill console
       (✕ / Esc / backdrop) does NOT call it — F2 keeps the warm session so the
       card can offer RESUME. Same split here, for a stronger reason: the whole
       point of S161 is that closing this console no longer throws the authored
       PRDs away, so auto-discarding on dismissal would re-open the exact trap the
       session was built to close (and re-charge the captain for the split worker).

       So the DISCARD is an explicit control — the footer button, which relabels
       itself to say what it now does — and ✕/Esc/backdrop still background the
       console. While a filing is in flight, and once every authored bug is on
       disk, the footer offers no discard at all: that state is news the parent card
       should keep telling until the captain's Go consumes it.

       N1 adds `partial` to the discardable set, and it is the sharpest case: some
       bugs landed and the rest exist ONLY as the text this session holds. The Go
       deliberately keeps such a session alive (driving what landed must not destroy
       the rest), so this is the only way to clear the card — and the label says what
       it throws away rather than pretending to be a plain Close. */
    function discardable() {
      // Never on a view-only build: the discard is a WRITE, so a board that 403s
      // writes must neither offer it nor advertise it. (A read-only build can hold
      // no session either — belt and braces, and it keeps the label honest.)
      return writesActive !== false && !!authored.sessionId &&
        (authored.status === "previewed" || authored.status === "failed" ||
         authored.status === "partial");
    }

    /* Label the footer's dismissal for what it will ACTUALLY do from here. */
    function markDismissState() {
      if (!discardable()) {
        dismiss.textContent = "Close";
        dismiss.title = "Close this console — the Mission Log keeps its place";
      } else if (authored.status === "partial") {
        dismiss.textContent = "Discard Unfiled";
        dismiss.title = "Throw away the authored text of the bugs that did not " +
          "file and clear this mission's card — the bugs that DID file are kept";
      } else {
        dismiss.textContent = "Discard Preview";
        dismiss.title =
          "Throw away the authored bugs and clear this mission's card";
      }
    }

    function dismissConsole() {
      // Discard from a state the captain can still throw away (previewed/failed —
      // nothing landed — or partial, where only the leftover text is lost);
      // otherwise just close. postWrite refreshes the board, which is what drops
      // the card's stamp.
      if (discardable()) {
        postWrite("/api/mission/" + enc(id) + "/log/discard", {},
                  // S163 fix round 5: a VERDICT — the console is closed on the
                  // next line whether the discard worked or not, so a refusal
                  // has nowhere else to be said.
                  function () {}, function (msg) { setVerdict(msg, "err"); });
      }
      closeOverlay();
    }

    /* On open: if the daemon is holding a session for this parent, pick it up
       exactly where the captain left it (S161). No session ⇒ a fresh console.

       S163 — EXCEPT when the card sent us here to fix an already-filed batch. The
       daemon's session is in-memory (it dies with the daemon), and the bugs are
       real linked children on disk that outlive it, so "no session" there does
       NOT mean "nothing to review": it means the memory went and the work did
       not. Falling back to the READ-ONLY linked-children preview rebuilds the
       review from disk and arms Go. It is the same empty-box Preview a captain
       can click by hand — it authors nothing, files nothing and mints no session,
       so it can never re-file the batch or re-charge the split worker.

       S163 fix round 1 (D2) — and the same is true when the captain arrives by
       the OTHER door. After a restart the detail's Mission-Log button is the
       route a captain reaches for by habit, and it opened a BLANK console: no
       mention of the bug already filed, no costs, no children, and a `Go ▸`
       that could only refuse. Nothing there was false, but nothing there was
       useful either, and it was the last route back.

       So the fallback is keyed on the STATE, not on which button was pressed:
       `logFixState(mi).ready` is precisely "this parent has a filed batch no
       Go has been taken for", the same reading the card's control renders
       from. `opts.fix` stays because the card can send us here in the seconds
       before the board's own children index catches up. A parent with no filed
       batch is untouched — the plain console still opens blank, and still
       posts nothing. */
    function restoreLogSession() {
      // Read the state ONCE, before the async GET, so the fallback decision and
      // the card's control are answering from the same board snapshot.
      var filedBatch = logFixState(mi).ready;
      fetchLogSession(id, function (s) {
        if (!consoleLive()) return;
        if (s) { adoptSession(s); return; }
        if (opts.fix || filedBatch) runPreview();
      }, function () {
        // ...and the same on a GET that FAILED rather than 404'd. "Never a dead
        // button" has to hold for every way the session can be unreachable, not
        // just the tidy one — and what disk says is the truth in both cases.
        if ((opts.fix || filedBatch) && consoleLive()) runPreview();
      });
    }

    // NOT applyWriteState'd: dismissing a console is not a write, and a view-only
    // board (which can hold no session, so never takes the discard branch) must
    // always be able to close what it opened.
    var dismiss = btn("Close", null, dismissConsole);
    dismiss.title = "Close this console — the Mission Log keeps its place";
    m.foot.appendChild(dismiss);
    /* The Preview dispatch, lifted out of the button so S163's restore fallback
       can reach it. ONE implementation, so the card's "Fix Filed Bugs" route and
       the captain's own empty-box Preview click are the same code — a second
       copy is how a fallback path quietly grows different rules. */
    function runPreview() {
      // BUG-024: ignore re-clicks while the split/estimate request is pending.
      if (prev.disabled) { return; }
      // R1: an AUTHORING re-split (there is text in the box) that would destroy
      // authored bugs the daemon still holds unfiled asks first — once. An empty
      // box is the read-only linked-children view, which destroys nothing.
      var stranded = report.value.trim() ? strandedCount() : 0;
      if (stranded && !discardArmed) { armDiscard(stranded); return; }
      // S163: an EMPTY box is not a split — it is the read-only view of the bugs
      // already linked to this parent, and it spends no worker turn. Saying
      // "Splitting the report into bugs…" over it describes work that is not
      // happening (and, on the Fix Filed Bugs route, work the captain never
      // asked for). Two behaviours, two sentences.
      var authoring = !!report.value.trim();
      prev.disabled = true;
      prev.textContent = authoring ? "Splitting…" : "Loading…";
      err.hidden = true;
      // UX-25: themed working copy for the split worker turn.
      busy.querySelector(".lcars-working-label").textContent = authoring
        ? "Splitting the report into bugs…"
        : "Loading the bugs already filed against this mission…";
      busy.hidden = false;
      // free-form text → AUTHORING preview; empty → read-only linked children.
      postWrite("/api/mission/" + enc(id) + "/log",
        // R1: `discardUnfiled` is the captain's confirmation, and it only ever
        // rides a click they armed. Without it the daemon refuses any preview that
        // would destroy authored text it is still holding unfiled.
        { text: report.value.trim(), images: reportImgs.payload(),
          discardUnfiled: discardArmed },
        function (state) {
          busy.hidden = true;
          // S92: keep the pasted screenshots alive past Preview — they must ride
          // the /log/file body too so they become DURABLE attachments on every
          // filed bug. They are cleared only after a successful File (below).
          // The fresh split has its own (empty) unfiled ledger, so the armed
          // discard is spent — disarm through applyWriteState, never a bare
          // `disabled = false` (a prior round shipped that bug).
          authored.unfiled = 0; authored.unfiledTitles = [];
          disarmDiscard();
          // S161: the daemon minted a session holding these authored PRDs. Keep
          // its id — File now posts only the sid, and closing the console no
          // longer discards the split (reopening restores from the session).
          authored.sessionId = (state && state.sessionId) || null;
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
          // S163: reveal Go for the READ-ONLY linked-children view. That view IS
          // a cost review — it renders each already-filed bug with its estimate
          // pills and its S74 steer box — and it shipped with no way to act on
          // it: `run` stayed hidden, so the one route back to an already-filed
          // batch (reopen the console, Preview an empty box) ended in a panel
          // that could only be closed. It is also the daemon-restart fallback the
          // card's "Fix Filed Bugs" lands on, which must never be a dead panel.
          // An AUTHORING preview keeps Go hidden: nothing is on disk yet, and the
          // File step (and BUG-059's hold) comes first.
          run.hidden = !(authored.filed &&
                         ((state && state.children) || []).length);
          // S161 fix D3: a fresh authoring preview IS a discardable session — mark
          // it so the footer offers the escape hatch (and so a later dismissal can
          // tell "nothing landed" apart from "bugs are on disk").
          authored.status = authored.sessionId ? "previewed" : null;
          markDismissState();
          // S163 fix round 3: on the READ-ONLY route (the daemon-restart
          // fallback the card's control lands on) the panel is the WAITING
          // bugs — the list Go will drive — not every child ever linked. A bug
          // already fixed and parked at the consolidated gate is not something
          // to re-run, and showing it would break the review's one promise.
          var shown = state;
          if (state && !state.authored && state.waiting) {
            shown = { parent: state.parent, authored: false, filed: true,
                      children: state.waiting };
            authored.waiting = state.waiting.length;
          }
          renderLogPreview(preview, shown, idLabel(mi), authored);
          // a fresh split supersedes any earlier shortfall — clear its recovery
          // panel so old unfiled text can't read as this preview's.
          renderLogUnfiled(recover, null);
          // Reveal File only when this preview AUTHORED ≥1 bug to file. Stays
          // hidden for the read-only linked-children view and for a 0-bug split.
          file.hidden = !(state && state.authored && (state.children || []).length);
          // S161 fix round 4: and RELABEL it for the session that now exists. A
          // re-preview confirmed from `partial` left the retry label behind —
          // "File 1 Remaining" still sitting on a button that would file all 3
          // bugs of the fresh split. Through setFileLabel → rearm →
          // applyWriteState, never a bare textContent/disabled assignment, so a
          // view-only board stays inert.
          setFileLabel(fileLabel);
        },
        function (msg) {
          busy.hidden = true;
          // the split did not happen, so nothing was destroyed and nothing was
          // superseded: go back to a plain, un-armed Preview (via applyWriteState —
          // never a bare `disabled = false`) and show the daemon's own words. If
          // this was the R1 refusal, the message names the bugs at stake.
          disarmDiscard();
          showErr(err, msg);
          // R1: the daemon is the guard, so a console whose picture of the session
          // is stale (it thinks nothing is stranded; the daemon knows better) would
          // otherwise re-post the same refused preview for ever. No split happened,
          // so whatever the daemon holds is still the truth — go and ask it, which
          // re-arms the confirmation from FACT rather than from parsing this
          // sentence.
          if (authored.sessionId) restoreLogSession();
        });
    }
    var prev = applyWriteState(btn("Preview", null, runPreview));
    // R1: say what Preview does, from the first paint. Its silence next to a
    // neighbour that warned was part of why the destructive click read as harmless.
    prev.title = PREVIEW_TITLE;
    // S74 / BUG-059: the captain reviews each bug's ESTIMATE (cost + difficulty
    // pills + suggested model) and can STEER the model BEFORE anything runs. We
    // FILE the authored bugs first (so log.sh runs the estimator + persists each
    // estimate.json) and re-render the panel with the per-bug estimate + override
    // box — then we HOLD. Filing NEVER auto-proceeds into the fix; only the
    // explicit "Go" (revealed after File) resolves the already-filed batch.
    var file = applyWriteState(btn(fileLabel, null, function () {
      // BUG-024: the File/preview control kicks off the async estimate (log.sh
      // runs the estimator on every child). It MUST NOT be re-clickable while the
      // request is in flight — a second click re-triggers the estimate (duplicate
      // previews / a race / wasted worker spend). Ignore clicks while pending,
      // disable + show a loading state, and re-enable only on success OR error.
      if (file.disabled) { return; }   // already pending — ignore the click
      err.hidden = true;
      // S161: with a daemon session the body carries ONLY the sid (+ the steers
      // the captain may have edited) — the PRDs, per-bug image refs and pasted
      // screenshots already live server-side, and the POST DISPATCHES rather than
      // holding for the estimator. Without one (no session is being held for this
      // console) fall back to the unchanged legacy prds-in-body form.
      // N1: from `partial` this is a RETRY of the bugs that never reached disk, and
      // `authored.overrides` is then indexed by the children that LANDED — sending
      // it would ask the daemon to re-index the captain's steers onto other bugs.
      // Send the sid alone; the session's own steers still ride the dispatch.
      if (authored.sessionId) {
        /* ── S162: File & Cost is a dispatch the captain can walk away from ──
           The estimator runs once per logged bug server-side; S161 made this POST
           return in ~2ms rather than hold for it, and this is what that seam was
           for. Mark the parent mission filing, CLOSE the console, and force an
           instant repaint so the ◐ FILING & COSTING… band is already on the card
           as the overlay disappears — the same close-on-dispatch shape `Go ▸`
           uses, and the same optimistic-flag-then-repaint shape START ALIGNMENT
           uses (no server state changes on the click, so no SSE tick is
           guaranteed).

           Closing is the DEFAULT, not a requirement: reopening the console
           restores this very session from the daemon (restoreLogSession), so a
           captain who prefers to watch the estimates land can simply reopen — and
           one who stays sees the console close and the card take over. */
        var payload = authored.status === "partial"
          ? { sessionId: authored.sessionId }
          : { sessionId: authored.sessionId,
              overrides: authored.overrides || [] };
        markFiling(id);
        closeOverlay();
        repaintBoard();
        // The console is already gone by the time this lands, so the copy points
        // at where the truth now LIVES rather than at a dialog that no longer
        // exists ("you can close this" would be describing a closed window).
        setStatus("Filing the logged bugs and costing each fix — the mission " +
                  "card will say when it is done.");
        postWrite("/api/mission/" + enc(id) + "/log/file", payload,
          function () { /* the parent card's logFiling stamp carries it now */ },
          function (msg) {
            // The daemon REFUSED the dispatch, so nothing is filing. Drop the
            // optimistic band rather than leave the card claiming work that was
            // never accepted, and say why on the only surface left — the console
            // that would have shown it is already gone.
            //
            // S163 fix round 5: a VERDICT. This is the Go's defect one control
            // over — same optimistic close, same "only surface left", same
            // `setStatus` + `refresh()` pair that erased the reason ~30 ms
            // later. The console is gone, so an erased line here leaves the
            // captain with NO account of a filing that never happened.
            clearFiling(id);
            repaintBoard();
            setVerdict(msg, "err");
            refresh();
          });
        return;
      }
      busyLabel("Filing bugs and estimating each fix…");
      busy.hidden = false;
      file.disabled = true;
      // transient progress text only — `fileName` keeps the control's NAME, so the
      // re-preview warning can still point at it while this POST is in flight.
      file.textContent = "Filing…";
      // The LEGACY prds-in-body form, unchanged from pre-S161 — and deliberately
      // NOT backgrounded: with no daemon session this POST holds for the whole
      // estimator run and there is no `logFiling` stamp for a card to read, so
      // closing the console would strand the captain with no surface at all.
      var payload = { prds: authored.prds || [], overrides: authored.overrides || [],
                      imageRefs: authored.imageRefs || [],  // per-bug routing
                      images: reportImgs.payload() };  // S92: durable attachments
      postWrite("/api/mission/" + enc(id) + "/log/file", payload,
        function (state) {
          if (state && state.status) {
            // A daemon session appeared under a console that had none (a restart
            // race). Follow it rather than pretend the legacy response shape.
            reportImgs.clear();
            adoptSession(state);
            return;
          }
          // legacy blocking response — unchanged from pre-S161.
          busy.hidden = true; setFileLabel(fileLabel);
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
          // the legacy path mints no session, so there is nothing to discard.
          authored.status = null;
          markDismissState();
          renderLogPreview(preview, state, idLabel(mi), authored);
          renderLogUnfiled(recover, null);
        },
        function (msg) {
          busy.hidden = true; setFileLabel(fileLabel);
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
      // S163 fix round 3 (D1): `authored.waiting` is the OTHER way this can be
      // legitimate — a console holding an un-filed report on a mission that
      // already has filed bugs waiting. The tester's exact dead end: the panel
      // above listed two reviewable bugs and this refused with "Click File
      // first", whose only remedy destroyed the un-filed text.
      if (!authored.filed && !authored.waiting) {
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
      // S163 fix round 3 (D2): KEYED BY MISSION ID. A positional list was
      // re-paired by the daemon against a different list of children, which is
      // how a steer typed against the third bug was written onto the first.
      var payload = { overrides: authored.steers || {} };     // resolve filed
      /* S163 fix round 7 (D3): if this parent is carrying a dispatch the daemon
         has marked STALE — a Go was taken and the resolve-logs driving it is
         gone — then this click is a RESUME, and it has to say so or the daemon
         refuses it (correctly: an un-flagged Go over a standing record is the
         double dispatch). Read off the mission the console was opened for, so
         the flag can only ever be set where the card was already showing the
         resume control. Same endpoint, same spawn — never a second path. */
      if (mi && mi.logDispatch && mi.logDispatch.stale) payload.resume = true;
      // S163 fix round 4 (D1): park the typed steers BEFORE the console goes,
      // so a refusal has something to hand back. Cleared the moment the daemon
      // accepts the dispatch — a successful Go consumed them.
      stashSteers(id, payload.overrides);
      // S163: the batch is dispatched from this instant, so the card's
      // "⚙ FIX N FILED BUGS" must go with the console — the review is taken and
      // re-offering it would invite a SECOND resolve-logs driver over the same
      // children. The daemon's effects are async (resolve-logs stamps `queued`
      // seconds later), so this optimistic flag covers the gap for this tab and
      // the daemon's `logDispatch` stamp covers a reloaded one. Repaint at once
      // for the same reason START ALIGNMENT does: no server state changed on the
      // click, so no SSE tick is guaranteed.
      markLogRun(id);
      closeOverlay();
      repaintBoard();
      /* S163 fix round 5 (D1): this line used to read "Fixes dispatched — child
         bug missions are being driven…", set HERE — before the POST had
         resolved. On a Go the daemon refused, that sentence was simply false,
         and it is the first thing a walk-away captain reads before leaving.

         An in-flight line may only describe the REQUEST. The claim that
         anything is being driven now waits for the daemon to say so, in the
         success callback, where it is a verdict rather than a guess. (The
         optimistic CARD flag above is a different thing and stays: it hides a
         control to prevent a second dispatch, and it is dropped again below if
         the Go is refused — it asserts nothing to the captain.) */
      setStatus("Asking the daemon to run the filed bugs — nothing is "
                + "driving yet.");
      postWrite("/api/mission/" + enc(id) + "/log/run", payload,
        function (state) {
          /* board/SSE refresh shows the new child cards. S163 fix round 4 (D1):
             a verdict the daemon reported but did NOT block on — today only a
             steer naming a bug that is not waiting on this mission — has no
             console left to appear in, so it is said on the surface that is
             still here. Never invented: only the daemon's own words. */
          takeSteers(id);
          var bad = ((state && state.overrides) || []).filter(function (o) {
            return o && o.error;
          });
          /* S163 fix round 5 (D1): BOTH of these are verdicts, and both used to
             be erased ~30 ms later by the repaint `postWrite` fires before this
             callback runs. The "…but N model steers were not applied" one is
             the more expensive loss: the dispatch really happened, so nothing
             else on the board will ever mention the steer that did not. */
          if (bad.length) {
            setVerdict("Fixes dispatched — but " + bad.length + " model steer"
              + (bad.length === 1 ? " was" : "s were") + " not applied: "
              + bad.map(function (o) { return o.error; }).join("; "));
          } else {
            setVerdict("Fixes dispatched — child bug missions are being driven…",
                       "ok");
          }
        },
        function (msg) {
          // a failed dispatch: surface it in the status line (the modal is gone)
          // and refresh so the board reconciles. The spinner already cleared.
          // S163: and DROP the optimistic flag — nothing is being driven, so the
          // card must go back to offering the review rather than hiding it
          // behind a dispatch that never happened.
          clearLogRun(id);
          // S163 fix round 5 (D1): a VERDICT, not a status. The daemon's
          // sentence names each bug and the words it could not use, and it is
          // the only account of what just happened — `refresh()` on the next
          // line is precisely what used to wipe it.
          setVerdict(msg, "err"); refresh();
          /* …and put the REVIEW back in front of the captain. The reason is
             legible on the status line either way, but the console is where it
             is ACTIONABLE: the per-bug row carries the daemon's reason beside
             the box holding the captain's own words (handed back by
             `stashSteers` above), so the steer can be edited and Go pressed
             again without remembering anything.

             Reopening is the difference between "the run did not happen" and
             "the run did not happen, and here is where to fix it". A captain
             who has to KNOW to reopen the review learns nothing by looking.

             Not on a view-only board: the write gate has just refused, and
             re-opening a console whose every control is disabled would only
             restate the banner. */
          if (writesActive) openLog(id, { fix: true, error: msg });
        });
    }));
    // S162: seed the control's name AND its tooltip through the SAME writer every
    // later state uses, so the first paint cannot be the one state that describes
    // itself differently (and so the seeding still routes through the write gate).
    setFileLabel(fileLabel);
    file.hidden = true;    // revealed only after a Preview that splits ≥1 bug
    run.hidden = true;     // revealed once the bugs are filed for review
    m.foot.appendChild(prev);
    m.foot.appendChild(file);
    m.foot.appendChild(run);
    // S163 fix round 5 (D1): the console was OPENED BY A REFUSAL — carry the
    // daemon's own sentence into it, so the reason sits inside the review it
    // belongs to and not only on the status line behind it. Never invented and
    // never re-worded: the string the daemon refused with.
    if (opts.error) showErr(err, opts.error);
    showOverlay(m.wrap);
    report.focus();
    // S161: pick up a session the daemon is already holding for this parent, so
    // reopening a closed console restores the authored bugs (or an in-flight
    // filing) instead of starting over on a fresh split worker turn.
    restoreLogSession();
  });
}

/* ════════ S161 fix round 2 (N1): the RECOVERY panel ════════
   The authored text of the logged bugs that did NOT reach disk.

   The Mission-Log split worker costs a real ~25s billable turn, which is the whole
   reason the daemon holds its output. Round 1 made a shortfall HONEST ("only 1 of 2
   authored bugs filed") and then dropped the missing bug's PRD on the floor: the
   session reported the filed child only, the temp file named in the error was
   already unlinked, and the advice — "log the ones that failed as a new report" —
   meant retyping the bug and paying for a second split. This panel is the other
   half of the cure: the daemon carries those authored rows on every session
   response (`unfiled`), and here they are, in full, selectable.

   Read-only by construction: text to copy and a File that retries, no edit-and-
   resubmit path (the daemon owns the words, so there is nothing here to save). */
function renderLogUnfiled(host, unfiled) {
  host.innerHTML = "";
  var rows = (unfiled || []).filter(function (u) { return u && u.prd; });
  if (!rows.length) { host.hidden = true; return; }
  host.hidden = false;
  var h = el("h4"); h.style.margin = "12px 0 6px";
  h.textContent = rows.length + " authored bug" + (rows.length === 1 ? "" : "s") +
    " did NOT file — the text is still here";
  host.appendChild(h);
  // Two honest routes, because there is NO edit-in-place here (the daemon owns the
  // words): File again fixes a transient fault; a PRD the script itself refused has
  // to be copied out and re-authored. Promising an edit this panel cannot do would
  // be the same class of lie as the count that started this round.
  host.appendChild(noteEl(
    "Nothing the split worker wrote was lost. If the fault was transient, File " +
    "again — it re-files only these, and costs no second split. If the bug PRD " +
    "itself was refused, copy the text below into a new report and fix it there."));
  rows.forEach(function (u) {
    var card = el("div", "card child"); card.style.cursor = "default";
    card.appendChild(el("div", "no", "↳ not filed"));
    card.appendChild(el("div", "ttl", "Bug · " + (u.title || "Untitled bug")));
    var body = el("textarea");
    body.rows = 6;
    body.readOnly = true;
    body.value = u.prd;
    body.title = "The authored bug PRD, exactly as the split worker wrote it";
    card.appendChild(body);
    host.appendChild(card);
  });
}

/* ════════ S163 fix round 3 (D1): the WAITING-BUGS review, as its own panel ════
   The captain's ruling in one function: "show me everything that will run".
   `waiting` is the daemon's list of every bug on this mission still waiting to
   be fixed — the same list `Go ▸` drives, because `resolve-logs --parent` takes
   a parent and drives all of it to one consolidated gate.

   It DELEGATES to renderLogPreview rather than drawing its own cards: the pills,
   the model mix and the S74 steer box are one implementation, so this panel and
   the post-File review can never grow different rules (the second-copy trap this
   file has been bitten by before). Empty/absent ⇒ the panel hides, which is what
   the `filed`/`partial` statuses want — there the daemon's own `children` list
   already IS the waiting list. */
function renderLogFixReview(host, waiting, parentLabel, authored) {
  var rows = waiting || [];
  if (!rows.length) { host.innerHTML = ""; host.hidden = true; return; }
  host.hidden = false;
  renderLogPreview(host, { parent: null, authored: false, filed: true,
                           children: rows }, parentLabel, authored);
  // Said once, at the top, because this panel appears BESIDE an un-filed report
  // and the captain has to know which of the two `Go ▸` acts on.
  host.insertBefore(
    noteEl("These are already filed and estimated. Go ▸ runs all of them — the " +
           "report below is separate, and File & Cost is what files it."),
    host.children[1] || null);
}

/* Record one bug's steer on the keyed map — INCLUDING an empty one.

   S163 fix round 6 (D1). This used to DELETE a blank rather than send "", on the
   reasoning that "the daemon skips blanks either way" and an empty entry per
   untouched bug is noise in a log. The first clause was true and was the defect:
   because a blank never reached the wire, an emptied box was indistinguishable
   from a bug the captain had not touched, so there was no way to say "this bug
   has no steer any more". The tester deleted an unusable steer, pressed Go, and
   watched the panel hand the deleted words back and the next Go re-send them.

   Every box the panel renders now rides the dispatch, empty ones included, which
   is what makes the payload a faithful record of the panel rather than a partial
   one — "what you see is exactly what Go runs", on the wire. The daemon reads a
   blank against a bug it is showing as a retraction (`_apply_child_overrides`). */
function setSteer(authored, id, raw) {
  authored.steers[id] = (raw || "").trim();
}

function renderLogPreview(host, state, parentLabel, authored) {
  host.innerHTML = "";
  var children = (state && state.children) || [];
  var authoredNew = state && state.authored;
  var filed = state && (state.filed || (!authoredNew && children.length));
  var h = el("h4"); h.style.margin = "4px 0 8px";
  // S163 fix round 3: the review's tail says WAITING TO BE FIXED, not "filed".
  // Every bug in it is filed, so the old word was not false — but the panel is
  // now scoped to the mission rather than to one batch, and its whole promise is
  // that this list is what the Go will run. The heading is where that promise is
  // either kept or quietly narrowed.
  /* S163 fix round 7 (D2): the heading counts THE LIST UNDER IT, full stop.
     It used to prefer `state.count`, which every producer computes as
     `len(children)` — every producer except the read-only preview, where
     `children` is every linked bug and the panel renders `waiting`. A count
     that describes a different list from the one beneath it is the same shape
     as the `count` key S161's D2 deleted for meaning two things; the fix is the
     same one, moved to the reader that could still pick the wrong list.
     Counting `children.length` makes overstating structurally impossible: the
     number and the rows are now one expression apart. */
  h.textContent = (filed ? "Review — " : "Preview — ") + children.length +
    " bug mission" + (children.length === 1 ? "" : "s") +
    (authoredNew ? " detected" : filed ? " waiting to be fixed" : " linked");
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
      // S163 fix round 3 (D2): the box is bound to THIS BUG'S MISSION ID, not to
      // its row number. The steers used to be collected into a positional array
      // that the daemon re-paired against a different list, so a steer could —
      // and did — land on a bug that was never on screen. `c.id` is present for
      // every row this branch renders (it only runs post-File), so there is no
      // slot left for a position to be guessed from.
      // The daemon's own verdict on this bug's last steer (resolved label, or a
      // normalization error). Read BEFORE the box is built, because S163 fix
      // round 4 (D1) makes an ERRORED verdict re-seed the box: the captain's raw
      // words are the thing to edit, and after a refused Go on another tab (or a
      // reload) they exist nowhere else. Only on an error — a steer that
      // RESOLVED is still pre-filled from `c.override`, its persisted form.
      var srvOv = (authored && authored.resolved && authored.resolved[c.id]) || null;
      var ov = el("input");
      ov.placeholder =
        "Override (optional) — e.g. \"use Opus\" · \"keep it cheap\" · all:opus";
      /* S163 fix round 6 (D1): a steer the client is HOLDING for this bug wins
         outright, even when it is empty. The old expression used `||`, so an
         emptied box fell through to the server's errored verdict and the
         captain's deletion was undone on the very next repaint — the refusal
         then went on naming a steer that no longer existed anywhere but here.
         The daemon drops that verdict on the clearing Go, so this is the second
         of two locks on the same door; it is here because the box must be right
         on the repaint that happens BEFORE the Go, too. */
      var held = (authored && authored.steers &&
                  Object.prototype.hasOwnProperty.call(authored.steers, c.id))
        ? authored.steers[c.id] : null;
      ov.value = held != null ? held
        : ((srvOv && srvOv.error && srvOv.raw) || c.override || "");
      if (authored) {
        if (!authored.steers) authored.steers = {};
        setSteer(authored, c.id, ov.value);
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
        } else if (unsupportedTier(raw)) {
          /* S163 fix round 4 (D1): a model LCARS has no tier for. The tester
             typed "use haiku", was told "model intent resolved when filed", and
             the steer was dropped on the floor. It is knowable from the word, so
             it is said from the word — now, in red, naming the choices. */
          steer.hidden = false; steer.className = "steer-echo err";
          steer.textContent = "⚠ “" + unsupportedTier(raw) + "” is not a model "
            + "tier LCARS can pick — choose Opus or Sonnet.";
        } else if (srvOv && srvOv.error) {
          steer.hidden = false; steer.className = "steer-echo err";
          steer.textContent = "⚠ " + srvOv.error;
        } else {
          /* Tier-less plain language ("be really thorough on this one"): the
             bounded worker gets ONE go at it when Go is pressed.

             S163 fix round 4 (D1) — the copy. This line used to read "model
             intent resolved when filed", which was false twice over on the
             surface it appears on: this IS the post-filing review, so there is
             no later "when filed" moment, and nothing was ever going to resolve
             it — the daemon dropped it silently and dispatched anyway. What it
             says now is the whole truth of what happens next: the resolution is
             attempted at Go, and a Go that cannot resolve it REFUSES rather than
             running the bug on a model the captain did not choose. */
          steer.hidden = false; steer.className = "steer-echo pending";
          steer.textContent = "“" + raw + "” — no model tier recognised yet. "
            + "Go resolves it, and refuses the run if it cannot.";
        }
      };
      ov.addEventListener("input", function () {
        if (!authored.steers) authored.steers = {};
        setSteer(authored, c.id, ov.value);
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
  // S163 fix round 6 (D2): the other door a captain opens onto a mission. Same
  // rule as openLog — reading a card is starting something else, and the last
  // action's verdict must stop speaking over it.
  retireVerdict();
  fetchMission(id, function (mi) { renderDetail(mi); });
}

function renderDetail(mi) {
  // UX-32: clear any prior live-tick timers before rebuilding the detail so a
  // re-render (or re-open) never stacks intervals.
  clearDetailTimers();
  // S163: settle the optimistic Go flag BEFORE the header's action row is built
  // — verifyAffordance reads it, and S162's own clearFilingOnState below runs
  // after the row for a control that is appended after it. A detail opened
  // straight from a link never went through cardNode, so it must be done here.
  clearLogRunOnState(mi);
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
    gh.href = ghIssueUrl(ghRepo, mi.issue);
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
    // S163: mirror the card — the detail is where the captain lands when they
    // click the card to look closer, and it is built by a different function, so
    // a control left out of here goes silent at exactly that moment. Same
    // builder, so the two cannot word it differently.
    if (daff.kind === "fix-filed") {
      actions.appendChild(fixFiledControl(mi, daff));
    } else if (daff.suppress) {
      // S163 fix round 2 (D2): the filing window — nothing here, because
      // logFilingControl below adds the one statement this window gets. Same
      // decision as the card's, from the same affordance.
    } else if (daff.kind !== "action") {
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
  } else if (mi.prdPending) {
    // Park & Align (S137 / BUG-1): a PARKED mission has NO PRD, so it is NEVER
    // runnable — the plain "▶ Start" below launches a RUN via the Launch panel.
    // Mirror the card control (▹ START ALIGNMENT) instead; startAlignmentControl
    // shares the BUG-3 busy-guard so this detail button also disables on click.
    actions.appendChild(startAlignmentControl(mi));
  } else {
    // align (and any pre-run stage): Start launches the run via the Launch panel.
    actions.appendChild(applyWriteState(btn("▶ Start", "go", function () { openLaunch(mi.id); })));
  }
  // Mission Log is VERIFY-ONLY (captain ruling): a mission cannot be logged
  // against until it reaches Verify — every earlier stage (align incl. parked,
  // research, validate, plan, implement) and terminal Done must NOT show it.
  // BUG-046: a logged-bug CHILD (type=="bug" && parentMission set, the isLogBug
  // predicate that gates the rest of the logged-bug chrome) is itself a bug entry
  // — you cannot log bugs AGAINST a logged bug. So the button renders for
  // top-level missions only, never for a bug child.
  if (mi.stage === "verify" && !isLogBug(mi)) {
    actions.appendChild(applyWriteState(btn("Mission Log", null, function () { openLog(mi.id); })));
  }
  // S162: mirror the card's filing affordance here too — the detail NEVER runs
  // through the board's card builder (the align_overlay_mission lesson), so a
  // surface left out of this goes silent at exactly the moment the captain clicks
  // the card to look closer. Built by the same function as the card's, so the two
  // cannot word it differently, and placed beside Mission Log because that is the
  // console it is telling you about — the mission's own primary action keeps its
  // place at the head of the row. (cardNode reconciles the optimistic flag for the
  // board; a detail opened straight from a link needs it done here too.)
  clearFilingOnState(mi);
  var dFiling = logFilingControl(mi);
  if (dFiling) actions.appendChild(dFiling);
  // S191: ADOPT rides the detail header too, on the same terms as the card —
  // the captain who opened a remote mission to read it is exactly the one who
  // decides to take command of it.
  var dAdopt = adoptControl(mi);
  if (dAdopt) actions.appendChild(dAdopt);
  row1.appendChild(actions);
  head.appendChild(row1);

  // S160: the card badge's long form — the guard's own sentence and the exact
  // command that clears it, directly under the header where the captain lands
  // when they click the badge's card. Absent entirely for a healthy base.
  var bfBlock = baseFreshnessBlock(mi.baseFreshness, "det-basefresh");
  if (bfBlock) head.appendChild(bfBlock);

  // S162: and the card's band / failure state, so the detail tells the same
  // story. Both are condition-gated (null with no live session), so a mission
  // that never logged a bug opens byte-identically to before this round.
  if (logFilingState(mi).filing) head.appendChild(filingPulse());
  var dNote = logFilingNote(mi);
  if (dNote) head.appendChild(dNote);

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
  // S191: the detail is the OTHER door onto a mission, built by a different
  // function, so a control left out of the card's sweep goes live at exactly the
  // moment the captain clicks in for a closer look. One sweep over the whole
  // grid; ✕ and ADOPT are exempt by class (see applyRemoteLock).
  applyRemoteLock(grid, mi);
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
    lec.appendChild(runningPulse(stageLabel(activeStage), mi.liveness));
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
  // S115: group the ordered stream into collapsible per-stage / per-wave
  // sections so a big mission reads at a glance. Completed sections collapse to
  // one LCARS summary band; the active (last) section stays open; every event is
  // still reachable (each band expands; an "expand all" reveals the lot). A
  // small mission (a single section) renders effectively as the old flat feed —
  // no band chrome is forced onto a mission with nothing to collapse.
  var sections = groupActivityIntoSections(acts);
  if (sections.length <= 1) {
    // Passthrough: 1 (or 0) section → the flat timeline exactly as before.
    acts.forEach(function (ev) { hist.appendChild(renderEvent(ev)); });
    feed.appendChild(hist);
    return feed;
  }
  // >1 section → collapsible bands + an expand-all affordance.
  var bands = [];
  var expandRow = el("div", "feed-expand");
  var expandBtn = el("button", "feed-expand-btn", "⧉ Expand all");
  var allOpen = false;
  expandBtn.addEventListener("click", function () {
    allOpen = !allOpen;
    bands.forEach(function (b) { b.setOpen(allOpen); });
    expandBtn.textContent = allOpen ? "⊟ Collapse to summary" : "⧉ Expand all";
  });
  expandRow.appendChild(expandBtn);
  hist.appendChild(expandRow);
  sections.forEach(function (sec) {
    var band = sectionNode(sec);
    bands.push(band);
    hist.appendChild(band.node);
  });
  feed.appendChild(hist);
  return feed;
}

/* S115: render ONE activity event as the standard `.evt` timeline block. Factored
   out of activityFeed so the SAME per-event rendering is reused by the flat
   small-mission passthrough AND inside every expandable section — no event is
   ever rendered by only one path, and every event maps to exactly one `.evt`
   node (the "nothing lost" invariant). Behaviour is byte-identical to the old
   inline loop. */
function renderEvent(ev) {
  var stage = normStage(ev.stage);
  var isGate = ev.type === "gate";
  // S134: a proof-gate event gets an extra accent class (green/red/teal) so its
  // outcome reads at a glance; every other event keeps its plain stage accent.
  var proofCls = PROOF_EVENT_CLASS[ev.type];
  var e = el("div", "evt s-" + (isGate ? "gate" : stage) + (proofCls ? " " + proofCls : ""));
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
  return e;
}

/* S115: group an ORDERED activity stream (mi.activity — {ts,stage,type,detail,
   text}) into collapsible sections, CLIENT-SIDE, off the stream alone (no board
   shape / event changes). A `stage_start` opens a STAGE section; a `wave_start`
   opens a WAVE section (numbered by its ordinal within the run). The Implement
   stage_start is a bare header that the first wave ABSORBS, so it is never an
   orphan band. Any other event joins the current section (a fresh stage-change
   with no explicit boundary opens an implicit stage section). Nothing is ever
   dropped: every input event lands in exactly one section, in order.

   Each section carries derived summary data: ticketCount (ticket_start events),
   greenCount / flaggedCount, sessionCount, bounceCount (ticket_gate_bounce
   events — a gate rejection that cost a hire), a `flagged` marker (any ticket
   flagged), the first/last ts and their durationSec, and `active` (the LAST
   section — the in-flight / most-recent one, which renders OPEN).

   sessionCount is THE HIRE COUNT, and there is exactly ONE derivation rule for
   it, shared with run.sh's ticket_hire_count(), comment-mirror's
   cm_ticket_sessions() and lcars-status's pace line: the NUMBER of
   ticket_attempt events FOR A TICKET, ANY phase. Every ticket_attempt is one
   real worker DISPATCH — on a current mission they are all phase=tdd; on a
   pre-S133 standoff mission the test-writer and implementer events were each a
   dispatch too, so counting them is honest there as well. It is NOT the max
   `attempt` VALUE (pre-S133 streams number per phase, so the max under-counts)
   and it is NOT derived from anything else.

   S173 FIX ROUND 2 (N1) — the counters are PER TICKET OVER THE WHOLE STREAM,
   not per section. `wave_start` is durably deduped against events.jsonl but
   `stage_start` is NOT, so every real re-entry (respond→run resume, a manual
   retry, the auto-advance driver re-running Implement) appends a second
   stage_start and this grouper opens a second section on it — splitting one
   wave's hires across two bands, so a ticket that took 3 hires rendered "↻ 2
   worker sessions" while the other three surfaces all said 3. A band therefore
   reports, for each ticket it shows a hire (or bounce) for, that ticket's TOTAL
   over the entire stream. bounceCount had the identical scope bug and is cured
   on the identical rule.
   THE SECTIONING ITSELF IS DELIBERATELY UNCHANGED (the captain chose the narrow
   fix): the timeline still visibly splits at a resume, stage_start is still not
   deduped, sections are never merged. Only the NUMBER changed.
   An event with no `data.ticket` (a malformed or very old row) cannot be
   attributed, so it is counted once, locally, where it sits — never dropped.

   NO ticket_attempt events ⇒ sessionCount is null: the hire count is UNKNOWN,
   the chip is omitted, and NOTHING is substituted for it. (Until this fix an
   outcome fallback — greens + flaggeds — was rendered under the word
   "sessions", so a wave where every ticket landed first try wore "↻ 3
   sessions", and a ticket that struggled through 5 worker iterations with no
   ticket_attempt on file wore nothing.)
   Every count keys off the event TYPE, never off detail text, so a historical
   or MIXED-vocabulary stream tallies identically to a fresh one. */
function groupActivityIntoSections(acts) {
  var sections = [];
  var cur = null;
  var waveOrdinal = 0;

  // S173 FIX ROUND 2 (N1+N2). ONE ordered pre-pass over the WHOLE stream, before
  // any sectioning, producing:
  //   streamHires/streamBounces — per-ticket TOTALS, so a band can report a
  //     ticket's real count wherever those events sit in the timeline; and
  //   ev.hireIndex — each ticket_attempt's position in ITS OWN ticket's hire
  //     sequence (1st, 2nd, 3rd …), which is what the headline shows. The wire's
  //     `attempt` value is NOT that sequence on a historical stream (a pre-S133
  //     standoff numbers per PHASE, so two dispatches both carry attempt=1; a
  //     gapped stream jumps 1→3), so a wire-indexed headline contradicted the
  //     chip above it. Count and index now come off the same series.
  // The pre-pass reads only event TYPE and `data.ticket`; it changes nothing
  // about how events are GROUPED.
  var streamHires = {}, streamBounces = {}, hireSeq = {};
  (acts || []).forEach(function (ev) {
    if (!ev || typeof ev !== "object") return;
    var tid = ticketOf(ev);
    if (ev.type === "ticket_attempt") {
      if (tid) {
        streamHires[tid] = (streamHires[tid] || 0) + 1;
        hireSeq[tid] = (hireSeq[tid] || 0) + 1;
        ev.hireIndex = hireSeq[tid];
      } else {
        // unattributable: it still happened, it just cannot be pooled with a
        // ticket's other hires — and it gets NO index rather than a wrong one.
        delete ev.hireIndex;
      }
    } else if (ev.type === "ticket_gate_bounce" && tid) {
      streamBounces[tid] = (streamBounces[tid] || 0) + 1;
    }
  });

  function tally(sec, ev) {
    sec.events.push(ev);
    var t = tsSeconds(ev.ts);
    if (t != null) {
      if (sec.startTs == null) sec.startTs = t;
      sec.endTs = t;
    }
    var tid;
    switch (ev.type) {
      case "ticket_start": sec.ticketCount++; break;
      case "ticket_green": sec.greenCount++; break;
      case "ticket_flagged": sec.flaggedCount++; sec.flagged = true; break;
      case "ticket_attempt":
        tid = ticketOf(ev);
        if (tid) sec._hireTickets[tid] = 1; else sec._looseHires++;
        break;
      case "ticket_gate_bounce":
        tid = ticketOf(ev);
        if (tid) sec._bounceTickets[tid] = 1; else sec._looseBounces++;
        break;
    }
  }
  function open(kind, stage, wave) {
    var sec = {
      kind: kind, stage: normStage(stage), wave: wave || null,
      events: [], startTs: null, endTs: null,
      ticketCount: 0, greenCount: 0, flaggedCount: 0, flagged: false,
      bounceCount: 0,
      // the TICKETS this section showed a hire / bounce for; the whole-stream
      // totals for those tickets are summed in the finalize pass below.
      _hireTickets: {}, _bounceTickets: {}, _looseHires: 0, _looseBounces: 0,
    };
    sections.push(sec);
    cur = sec;
    return sec;
  }

  (acts || []).forEach(function (ev) {
    if (!ev || typeof ev !== "object") return;
    var stage = normStage(ev.stage);
    if (ev.type === "wave_start") {
      waveOrdinal++;
      // Absorb a bare stage header (only a stage_start, no tickets yet) of the
      // same stage into this wave so the Implement stage_start isn't an orphan.
      if (cur && cur.kind === "stage" && cur.stage === stage &&
          cur.ticketCount === 0 &&
          cur.events.every(function (e) { return e.type === "stage_start"; })) {
        cur.kind = "wave";
        cur.wave = waveOrdinal;
        tally(cur, ev);
        return;
      }
      open("wave", stage, waveOrdinal);
      tally(cur, ev);
      return;
    }
    if (ev.type === "stage_start") {
      open("stage", stage);
      tally(cur, ev);
      return;
    }
    // Any other event: join the current section. Open an implicit stage section
    // when none is open, or when the stage changes with no explicit boundary
    // (never re-splitting an open wave, whose events share the implement stage).
    if (!cur || (cur.kind !== "wave" && cur.stage !== stage)) {
      open("stage", stage);
    }
    tally(cur, ev);
  });

  sections.forEach(function (sec, i) {
    sec.active = (i === sections.length - 1);
    sec.durationSec = (sec.startTs != null && sec.endTs != null)
      ? Math.max(0, Math.round(sec.endTs - sec.startTs)) : null;
    // BACK-COMPAT: a pre-S134 stream has no ticket_attempt events at all. The
    // hire count is then genuinely UNKNOWN — null, so every surface omits it.
    // An outcome count is NOT a hire count and is never substituted for one.
    // Never NaN, never a fabricated number, on any stream.
    var hires = sumStreamTotals(sec._hireTickets, streamHires) + sec._looseHires;
    sec.sessionCount = hires > 0 ? hires : null;
    sec.bounceCount = sumStreamTotals(sec._bounceTickets, streamBounces)
      + sec._looseBounces;
    delete sec._hireTickets; delete sec._bounceTickets;
    delete sec._looseHires; delete sec._looseBounces;
  });
  return sections;
}

/* S173 FIX ROUND 2: the ticket an event belongs to, or null when the stream does
   not say. Reads the structured `data.ticket` the adapter passes through — never
   detail text, which is prose and disagrees across vocabularies on purpose. */
function ticketOf(ev) {
  var t = ev && ev.data && ev.data.ticket;
  return (typeof t === "string" && t) ? t : null;
}

/* S173 FIX ROUND 2: sum a ticket-id SET's whole-stream totals. */
function sumStreamTotals(idSet, totals) {
  var n = 0;
  Object.keys(idSet || {}).forEach(function (id) { n += (totals[id] || 0); });
  return n;
}

/* S115: ts → whole seconds (epoch). Mirrors fmtTs's tolerance of epoch-seconds,
   epoch-millis and ISO strings; returns null for an unparseable/absent ts so a
   section duration is simply omitted rather than NaN. */
function tsSeconds(ts) {
  if (ts == null) return null;
  if (typeof ts === "number") return ts < 1e12 ? ts : ts / 1000;
  var n = new Date(ts).getTime();
  return isNaN(n) ? null : n / 1000;
}

/* S115: the LCARS section title — "WAVE n" for a wave band, the stage label
   (uppercased) for a stage band. */
function sectionTitle(sec) {
  if (sec.kind === "wave") return "WAVE " + sec.wave;
  return stageLabel(sec.stage).toUpperCase();
}

/* S115: the one-line Star-Trek-voiced summary shown on a collapsed band. Wave
   bands read "N tickets · M worker sessions · K bounces · <dur>" (the hire and
   bounce counters silent when there is nothing to report); stage bands read a stage-flavoured
   line with the duration. Duration is omitted when unknown. Kept as the plain-
   text fallback; the band now renders sectionSummaryChips (graphic stat chips)
   with the SAME singular/plural + omit-when-zero rules. */
function sectionSummary(sec) {
  var bits = [];
  if (sec.kind === "wave") {
    bits.push(sec.ticketCount + " ticket" + (sec.ticketCount === 1 ? "" : "s"));
    // S173: silence when nothing went wrong — a wave whose every ticket landed
    // on its FIRST hire wears no counter at all. Only > 1 is worth saying.
    if (sec.sessionCount > 1) {
      bits.push(sec.sessionCount + " worker session"
        + (sec.sessionCount === 1 ? "" : "s"));
    }
    if (sec.bounceCount > 0) {
      bits.push(sec.bounceCount + " bounce" + (sec.bounceCount === 1 ? "" : "s"));
    }
  } else {
    bits.push(sec.active ? "in progress" : "complete");
  }
  if (sec.durationSec != null && sec.durationSec > 0) bits.push(fmtDuration(sec.durationSec));
  return bits.join(" · ");
}

/* VISUAL POLISH (S115 follow-up): the band summary rendered as discrete,
   icon-led LCARS stat chips instead of one run-together line. Returns an ARRAY
   of chip spans (each its own class) so sectionNode can drop them into the band.
   Same omit/singular-plural rules as sectionSummary:
     WAVE  → ⬢ tickets (teal) · ↻ worker sessions (amber, RED when any flagged)
             · ⤫ gate bounces (RED, the "something went wrong" signal) · ◷ dur
     STAGE → in-progress (pulsing dot) / complete chip · ◷ dur
   A chip whose value is nothing-to-report is omitted exactly as the text summary
   omits it: NO session chip at ≤ 1 hire (a first-try wave wears no counter), no
   bounce chip at 0 bounces, no duration chip when unknown. */
function sectionSummaryChips(sec) {
  var chips = [];
  if (sec.kind === "wave") {
    chips.push(el("span", "band-chip chip-tickets",
      "⬢ " + sec.ticketCount + " ticket" + (sec.ticketCount === 1 ? "" : "s")));
    if (sec.sessionCount > 1) {
      // RED tint when this wave carries a flagged ticket, amber otherwise.
      chips.push(el("span",
        "band-chip chip-sessions" + (sec.flaggedCount > 0 ? " flagged" : ""),
        "↻ " + sec.sessionCount + " worker session"
          + (sec.sessionCount === 1 ? "" : "s")));
    }
    if (sec.bounceCount > 0) {
      // The signal that something WENT WRONG — a gate rejected a hire and LCARS
      // had to re-spawn. Always red; a wave with 0 and a wave with 2 are now
      // distinguishable at a glance, without opening either.
      chips.push(el("span", "band-chip chip-bounces",
        "⤫ " + sec.bounceCount + " bounce" + (sec.bounceCount === 1 ? "" : "s")));
    }
  } else {
    // STAGE: an in-progress (pulsing dot via CSS ::before) / complete chip.
    chips.push(el("span", "band-chip chip-status" + (sec.active ? " active" : ""),
      sec.active ? "in progress" : "✓ complete"));
  }
  if (sec.durationSec != null && sec.durationSec > 0) {
    chips.push(el("span", "band-chip chip-duration", "◷ " + fmtDuration(sec.durationSec)));
  }
  return chips;
}

/* VISUAL POLISH: a thin wave-health micro-bar — a GREEN segment (greenCount) and
   a RED segment (flaggedCount) sized proportionally to the wave's ticketCount,
   the remainder left neutral (in-flight / not-yet-resolved). Returns the bar
   node, or null for a stage section or a zero-ticket wave (no bar rendered,
   matching where the chips degrade). Counts are clamped so a stray over-count
   never overflows the bar. Decorative (aria-hidden). */
function sectionHealthBar(sec) {
  if (!sec || sec.kind !== "wave" || !sec.ticketCount || sec.ticketCount <= 0) return null;
  var total = sec.ticketCount;
  var green = Math.max(0, Math.min(sec.greenCount || 0, total));
  var red = Math.max(0, Math.min(sec.flaggedCount || 0, total - green));
  var bar = el("div", "band-health");
  bar.setAttribute("aria-hidden", "true");
  var g = el("span", "hb-green");
  g.style.width = (green / total * 100) + "%";
  var r = el("span", "hb-red");
  r.style.width = (red / total * 100) + "%";
  bar.appendChild(g);
  bar.appendChild(r);
  return bar;
}

/* S115: one collapsible section. Returns {node, setOpen(bool)}. The band header
   (caret + title + summary + a ⚠ flag marker when any ticket flagged) toggles the
   events on click; the ACTIVE section opens by default, completed sections
   collapse to just the band. The events container always CONTAINS every event
   (rendered via renderEvent) — collapsing only hides it, so nothing is ever
   dropped or unreachable. */
function sectionNode(sec) {
  var wrap = el("div", "feed-section s-" + sec.stage + (sec.active ? " open" : ""));
  var band = el("div", "feed-band");
  var caret = el("span", "band-caret", sec.active ? "▾" : "▸");
  band.appendChild(caret);
  band.appendChild(el("span", "band-title", sectionTitle(sec)));
  // VISUAL POLISH: discrete icon-led stat chips (+ the graphic FLAGGED badge)
  // in one right-aligned cluster, replacing the run-together band-summary text.
  var chipWrap = el("div", "band-chips");
  sectionSummaryChips(sec).forEach(function (c) { chipWrap.appendChild(c); });
  // Graphic FLAGGED badge: the red pill now reads as a badge — ⚠ glyph + a
  // subtle pulse/glow (the animation is gated on prefers-reduced-motion in CSS).
  if (sec.flagged) chipWrap.appendChild(el("span", "band-flag", "⚠ FLAGGED"));
  band.appendChild(chipWrap);
  // VISUAL POLISH: the wave-health micro-bar (green/red split), waves-with-
  // tickets only — null (nothing appended) for stage / zero-ticket sections.
  var health = sectionHealthBar(sec);
  if (health) band.appendChild(health);
  var events = el("div", "band-events");
  sec.events.forEach(function (ev) { events.appendChild(renderEvent(ev)); });
  events.hidden = !sec.active;

  function setOpen(o) {
    events.hidden = !o;
    caret.textContent = o ? "▾" : "▸";
    if (o) wrap.classList.add("open"); else wrap.classList.remove("open");
  }
  band.addEventListener("click", function () { setOpen(events.hidden); });

  wrap.appendChild(band);
  wrap.appendChild(events);
  return { node: wrap, setOpen: setOpen };
}

/* S115: the mission-log PARENT's linked-bug list gets the same collapsed-band
   idiom as the activity feed — resolved bugs fold into one LCARS summary band
   (expandable, so nothing is lost), while any still-active bug stays open as its
   own row. A short list (≤3, or nothing worth folding) renders flat exactly as
   before — no chrome forced onto a parent with only a couple of bugs. */
function linkedBugsSection(kids) {
  var wrap = el("div", "log-preview-list");
  function bugRow(c) {
    var row = el("div", "crit");
    row.appendChild(el("span", "pill go", "✓"));
    row.appendChild(document.createTextNode(" " + (c.title || c.id || "Bug")));
    return row;
  }
  function resolved(c) {
    var s = normStage(c.stage);
    return s === "done" || s === "verify" || !!c.done || !!c.resolved;
  }
  var doneKids = kids.filter(resolved);
  var activeKids = kids.filter(function (c) { return !resolved(c); });
  if (kids.length <= 3 || doneKids.length <= 1) {
    kids.forEach(function (c) { wrap.appendChild(bugRow(c)); });
    return wrap;
  }
  var band = el("div", "feed-section s-done");
  var head = el("div", "feed-band");
  var caret = el("span", "band-caret", "▸");
  head.appendChild(caret);
  head.appendChild(el("span", "band-title", "RESOLVED"));
  head.appendChild(el("span", "band-summary",
    doneKids.length + " logged bug" + (doneKids.length === 1 ? "" : "s") + " fixed"));
  var list = el("div", "band-events"); list.hidden = true;
  doneKids.forEach(function (c) { list.appendChild(bugRow(c)); });
  head.addEventListener("click", function () {
    list.hidden = !list.hidden;
    caret.textContent = list.hidden ? "▸" : "▾";
    if (list.hidden) band.classList.remove("open"); else band.classList.add("open");
  });
  band.appendChild(head);
  band.appendChild(list);
  wrap.appendChild(band);
  activeKids.forEach(function (c) { wrap.appendChild(bugRow(c)); });
  return wrap;
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
  ticket_attempt: "Worker session", ticket_green: "Ticket green",
  ticket_flagged: "Ticket flagged", gate: "Gate raised", error: "Error",
  // S134 — the S133 unified-implementer proof-gate vocabulary, in Trek console
  // voice. There is NO per-event role chip anymore: with one unified worker the
  // old Test-Writer / Implementer distinction is retired. The visible sub-
  // structure is the PROOF GATE outcome (below) and the worker-session marker
  // (headlineFor, for any indexed ticket_attempt).
  flip_flop_pass: "PROOF ACCEPTED",
  flip_flop_fail: "PROOF REJECTED",
  flip_flop_inconclusive: "PROOF INCONCLUSIVE",
  flip_flop_skipped: "PROOF WAIVED — N/A",
  ticket_test_edits: "CONTRACT AMENDMENT",
  ticket_gate_bounce: "Gate bounce — fresh worker",
};

/* S134 — the accent class for each S133 proof-gate event, so the timeline reads
   the proof outcome at a glance (green accept, red reject, teal amendment). Any
   event NOT in this map keeps its plain stage accent — nothing lost. */
var PROOF_EVENT_CLASS = {
  flip_flop_pass: "proof-pass",
  flip_flop_fail: "proof-fail",
  flip_flop_inconclusive: "proof-fail",
  flip_flop_skipped: "proof-na",
  ticket_test_edits: "proof-amend",
  ticket_gate_bounce: "proof-bounce",
};

function headlineFor(ev) {
  // S134: the worker-session marker. On a bounce (gate rejection → fresh worker,
  // up to 3 sessions) each unified-TDD session emits a ticket_attempt with
  // phase=tdd + attempt=N. Surface that session number so multiple worker passes
  // on one ticket are legible — the meaningful sub-structure that replaces the
  // retired role distinction (there is no role/"TDD" chip anywhere). NO
  // captain-facing headline says "attempt", on any stream.
  if (ev.type === "ticket_attempt") {
    // S173 FIX ROUND: ANY phase, not just tdd. A pre-S133 standoff stream
    // carries phase=test-writer / phase=implementer, and each of those events
    // was a real worker dispatch too — they used to fall through to the literal
    // "Ticket attempt", which is how the retired word survived on every
    // historical mission's timeline.
    //
    // S173 FIX ROUND 2 (N2): the index is the event's position in ITS TICKET's
    // own hire sequence (`hireIndex`, derived by groupActivityIntoSections from
    // the same series the band counts), NOT the wire's `attempt` value. Fix
    // round 1 surfaced the wire value for every phase, and on a historical
    // stream the two series are unrelated: a pre-S133 ticket's two dispatches
    // BOTH carry attempt=1, so a band reading "↻ 2 worker sessions" opened onto
    // "Worker session 1" twice; a gapped stream showed 1 and 3 under a chip
    // saying 2. A headline must never contradict the band above it.
    // No derived index (an unattributable event, or headlineFor called on an
    // ungrouped event) ⇒ DROP the number rather than show an untrustworthy one;
    // EVENT_HEADS then supplies the phase-neutral "Worker session".
    if (ev.hireIndex != null) return "Worker session " + ev.hireIndex;
  }
  return EVENT_HEADS[ev.type] || (ev.type || "Event").replace(/_/g, " ");
}

function detailTabs(mi) {
  // Park & Align: a PARKED mission has no PRD/ADRs/tickets yet — the grill hasn't
  // run. Showing the PRD tabs (with the "The behaviour described in the PRD works
  // end to end" placeholder criterion) reads as if a spec exists. Instead show a
  // themed standby panel so the detail honestly says the mission is awaiting Align.
  if (mi.prdPending) {
    var pend = el("div", "tabs");
    pend.appendChild(el("div", "mock-cap", "◇ STANDBY — AWAITING ALIGNMENT"));
    var msg = el("p"); msg.style.fontSize = "13px"; msg.style.opacity = "0.8";
    msg.textContent = "No PRD yet — this mission is parked. Run the Align grill to "
      + "define its spec; the PRD, ADRs and tickets appear here once it is aligned.";
    pend.appendChild(msg);
    return pend;
  }

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

/* S134 parity — the proof-bearing ticket rows the Verify surfaces render.
   Normally the mission's own ticket rows (mi.tickets). A SINGLE-ticket mission
   carries NO rows (the lone slice reuses the mission's own issue), so its lone
   ticket's proof rides the mission as `mi.contractProof`; we synthesize one row
   from it so the flip-flop chip + contract amendments render exactly as the CLI
   verify-summary shows them. A multi-ticket mission never carries contractProof
   (adapter), so there is no double-render. */
function proofTickets(mi) {
  var tickets = (mi && mi.tickets) || [];
  if (tickets.some(function (t) { return t && t.proof; })) return tickets;
  var cp = mi && mi.contractProof;
  if (cp) return [{ id: cp.id, title: cp.title || cp.id, state: "done", proof: cp }];
  return tickets;
}

function buildSummary(mi) {
  // group tickets into a per-wave-ish summary. Without wave grouping in the card
  // shape we render one row per ticket with its state pill.
  var host = el("div");
  proofTickets(mi).forEach(function (t) {
    var row = el("div", "crit");
    var cls = t.state === "done" ? "go" : t.state === "flagged" ? "high" : "med";
    var pill = el("span", "pill " + cls, t.state === "done" ? "✓" : (t.id || ""));
    pill.style.fontSize = "10px";
    row.appendChild(pill);
    // UX-37: ticket title/rationale is worker-authored Markdown — render inline.
    var ttext = el("span", "md md-inline");
    setMd(ttext, " " + (t.title || t.id || ""));
    row.appendChild(ttext);
    // S134: the flip-flop verdict chip — PROVEN (tests proved fail-on-parent /
    // pass-on-tip) or N/A (declared not-applicable, with the reason shown). Only
    // rendered when the ticket carries S133 proof data, so a pre-S133 ticket row
    // is byte-identical to before this round.
    var chip = flipFlopChip(t);
    if (chip) row.appendChild(chip);
    host.appendChild(row);
  });
  return host;
}

/* S134: the per-ticket flip-flop verdict chip (or null for a pre-S133 ticket /
   a ticket with no recorded verdict). PROVEN reads teal (go); N/A reads dim and
   shows the reason inline; a fail/inconclusive verdict reads red. */
function flipFlopChip(t) {
  var ff = t && t.proof && t.proof.flipFlop;
  if (!ff || !ff.verdict) return null;
  var wrap = el("span", "ff-wrap");
  wrap.style.marginLeft = "6px";
  if (ff.verdict === "proven") {
    wrap.appendChild(el("span", "ff-chip proven", "◈ PROVEN"));
  } else if (ff.verdict === "n-a") {
    wrap.appendChild(el("span", "ff-chip na", "◇ N/A"));
    if (ff.reason) {
      var why = el("span", "ff-reason dim", " " + ff.reason);
      why.style.fontSize = "11px";
      wrap.appendChild(why);
    }
  } else {
    wrap.appendChild(el("span", "ff-chip rejected", "✗ " + String(ff.verdict).toUpperCase()));
    if (ff.reason) wrap.appendChild(el("span", "ff-reason dim", " " + ff.reason));
  }
  return wrap;
}

/* S134 — the CONTRACT AMENDMENTS block: the declared test edits ({path, reason}
   verbatim) the unified TDD worker made across a mission's tickets, presented as
   one LCARS-themed section. Rules:
     • pre-S133 mission (NO ticket carries proof data) → returns null, so nothing
       is appended and the Verify readout is byte-identical to before this round;
     • proofed mission with NO declared edits anywhere → a single quiet line;
     • otherwise → the amendments, each row naming ticket · path — reason (the
       reason rendered as verbatim text, never markdown, so a contract is exact).
   The board reads the SAME shape the CLI verify_contract_readout reads. */
function contractAmendments(mi) {
  // S134 parity: proofTickets folds in a single-ticket mission's mission-level
  // proof (mi.contractProof) so the amendments render identically to the CLI.
  var tickets = proofTickets(mi);
  var proofed = tickets.some(function (t) { return t && t.proof; });
  if (!proofed) return null;                 // pre-S133 → byte-identical

  var wrap = el("div", "contract-amend");
  wrap.style.margin = "16px 0 8px";
  var edits = [];
  tickets.forEach(function (t) {
    ((t.proof && t.proof.declaredEdits) || []).forEach(function (e) {
      if (e && e.path) edits.push({ id: t.id, path: e.path, reason: e.reason || "" });
    });
  });
  if (!edits.length) {
    // exactly one quiet line — no existing tests were adapted this mission.
    var quiet = el("div", "amend-none dim",
      "No contract changes — no existing tests were adapted.");
    quiet.style.fontSize = "13px";
    wrap.appendChild(quiet);
    return wrap;
  }
  var head = el("h4", null, "Contract amendments");
  head.style.margin = "0 0 8px";
  wrap.appendChild(head);
  var note = el("div", "dim");
  note.style.cssText = "font-size:12px;margin-bottom:6px";
  note.textContent = "Existing tests the work adapted — each declared with a reason.";
  wrap.appendChild(note);
  edits.forEach(function (e) {
    var row = el("div", "amend-row");
    row.style.cssText = "margin:4px 0;padding:8px 10px;border-radius:6px;background:rgba(255,153,0,.08)";
    var tid = el("span", "amend-tid");
    tid.style.cssText = "font-weight:bold;color:var(--lcars-amber);margin-right:6px";
    tid.textContent = e.id;
    var path = el("span", "amend-path");
    path.style.cssText = "font-family:var(--font-mono,monospace);font-size:12px";
    path.textContent = e.path;
    row.appendChild(tid);
    row.appendChild(path);
    // reason VERBATIM (textContent, not markdown) — a contract must be exact.
    var reason = el("div", "amend-reason");
    reason.style.cssText = "font-size:12px;margin-top:2px;opacity:.9";
    reason.textContent = e.reason;
    row.appendChild(reason);
    wrap.appendChild(row);
  });
  return wrap;
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
/* S128 fix round 1, D2 — AND IT BRINGS THE LINE INTO VIEW.

   This is the one call every modal in board.js surfaces a failure through, and
   nine of them append their `.errline` into `.modal-body` — the region that
   SCROLLS. The tester's filing POST came back 502, this function ran, the line
   was populated and `hidden:false`… 1,115px below the bottom of the visible
   body, in a modal whose sticky footer had already reverted the button to
   "▦ File Mission". A sweep of every error node intersecting the viewport
   returned []. A real outcome presented as nothing — FL-009's disease one door
   over.

   Making the line visible and leaving it where the captain is not looking is
   not reporting. `block:"nearest"` is deliberate: it moves the scroll only when
   the line is genuinely out of view, so an error already on screen does not
   yank the page out from under him. Guarded because the node harnesses have no
   layout and no such method. */
function showErr(node, msg) {
  node.hidden = false;
  node.textContent = msg;
  if (node.scrollIntoView) node.scrollIntoView({ block: "nearest" });
}

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
/* S163 fix round 4 (D1): the models LCARS has NO tier for — the client mirror of
   the daemon's `unsupported_tier`. `haiku` is a real model and a reasonable
   thing for a captain to type; what it is not is one of the two tiers LCARS
   chooses between, and that is knowable from the word alone. Knowing it HERE is
   what lets the console refuse before Go rather than accept, post, and have the
   daemon refuse — the tester's "refused loudly BEFORE Go, if that is knowable".
   Returns the offending word, or null. */
function unsupportedTier(raw) {
  if (!raw) return null;
  var m = /\b(haiku|gpt|gpt-?[0-9.]+|o[134](?:-mini)?|gemini|grok|llama|mistral|deepseek|qwen|codex)\b/i
    .exec(String(raw));
  return m ? m[0] : null;
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
/* FIX-A: the PERSISTENT animated band shown on a parked card from the START
   ALIGNMENT click until the warm grill console opens. Same animated bars as
   runningPulse (.lcars-running), so the scan reads as live motion the whole time
   instead of flashing once and dying to a static grey button. Re-rendered on every
   repaint while the scan is in flight (card render), so no repaint can wipe it. */
function scanningPulse(m) {
  // S128/FL-009: the band is the surface a captain actually watches, so it
  // carries the elapsed time of the in-flight turn — this tab's click when it
  // has one, the daemon's start when it does not (a reload). `m` is optional:
  // without it (or before the first turn is armed) the label is exactly as it was.
  var w = workingNode(scanningLabel(alignScanState(m).secs,
                                    "⊹ Scanning the codebase…"));
  w.className += " lcars-running";
  return w;
}

/* F1: the PERSISTENT animated band shown on a parked card while the CLOSING turn
   finalizes server-side (estimate + file.sh --complete) — including after the captain
   backgrounds the console — until the board refresh swaps in the aligned card. Same
   animated bars as scanningPulse (.lcars-running); label is the finalizing phase. */
function finalizingPulse(m) {
  // S169/FL-017: the band carries the elapsed time of the in-flight finalize —
  // the daemon's dispatch clock when it published one, this tab's submit
  // otherwise — through the SAME `scanningLabel` the scan band uses, so the two
  // states cannot describe elapsed time two different ways. `m` is optional:
  // without it the label is exactly as it was.
  var w = workingNode(scanningLabel(alignFinalizeState(m).secs,
                                    "◐ Finalizing & costing…"));
  w.className += " lcars-running";
  return w;
}

/* ════════ S162 — the mission-log filing surface (card + detail) ════════
   Three nodes, one state reading (logFilingState), one set of strings. Every
   piece of copy about a log filing is built HERE: nothing anywhere reads a label
   back out of the DOM to describe this state (S161's re-preview warning did, and
   ended up telling the captain that a control called "Filing…" was the one
   holding their bugs). All three return null / draw nothing unless their exact
   condition holds, so a card with no live session is byte-identical to pre-S162. */
var FILING_CONTROL_LABEL = "◐ FILING & COSTING…";
var FILING_BAND_LABEL = "◐ Filing bugs & costing each fix…";
var FILING_CONTROL_TITLE =
  "Filing the logged bugs and running the cost estimator on each one — you can " +
  "leave this; the card will say when it is done.";
/* True by construction while a session is live: the daemon holds the authored
   text of every bug that is not on disk (S161/N1), so reopening the console
   recovers it and File re-files only what is missing — no second split worker. */
var FILING_RECOVERY_HINT =
  "Open the Mission Log — the bugs that did not file are still held there.";

/* The DISABLED "◐ FILING & COSTING…" affordance. Mirrors the F1 finalizing
   control exactly: born disabled, wired to nothing, and carrying the `.btn.go`
   chrome that markViewOnly() sweeps, so a view-only board cannot end up holding
   a live-looking one. Never re-armed — the only thing that clears it is the
   filing ending (there is no "cancel a filing" and this must not imply one). */
function logFilingControl(m) {
  if (!logFilingState(m).filing) return null;
  var b = act("log-filing", btn(FILING_CONTROL_LABEL, "go", null));
  b.disabled = true;
  b.title = FILING_CONTROL_TITLE;
  return b;
}

/* The PERSISTENT animated band, drawn on every repaint while the filing is live
   — the same bars as scanningPulse/finalizingPulse, so a backgrounded filing
   reads as live motion rather than a static grey button. */
function filingPulse() {
  var w = workingNode(FILING_BAND_LABEL);
  w.className += " lcars-running";
  return w;
}

/* The counts, in ONE sentence fragment built in ONE place — `filedCount` and
   `bugCount` are the daemon's two self-describing names (S161-D2), and this is
   the only place they are turned into prose. Empty when the stamp is missing
   either: a card that cannot count must not print a number. */
function logFilingCounts(st) {
  if (st.bugCount == null || st.filedCount == null) return "";
  return st.filedCount + " of " + st.bugCount + " filed";
}

/* The card/detail state for a filing that ENDED BADLY.

   This is the half that makes closing the console safe. The captain dispatched a
   filing and walked away; if a shortfall or a refusal just made the band stop
   animating, they would be left believing bugs exist that do not. So a `partial`
   or a `failed` replaces the band with a legible, persistent state that names
   what happened — the count from the stamp, and the daemon's own reason
   verbatim. A clean `filed` renders nothing (the bugs are simply there, awaiting
   the captain's Go — the follow-through control for that is S163's). */
function logFilingNote(m) {
  var st = logFilingState(m);
  if (st.filing || !st.terminal || st.status === "filed") return null;
  var counts = logFilingCounts(st);
  var head = st.status === "partial"
    ? ("● only " + (counts || "some logged bugs filed"))
    : ("✖ logging the bugs failed" + (counts ? " — " + counts : ""));
  var host = el("div", "log-filing-note");
  // `failed` (nothing landed) reads as the attention state; `partial` as the
  // amber "look at this" — some bugs really are on disk and reviewable.
  //
  // NOT a `.no` line, and that omission is load-bearing. `.no` means "a muted
  // metadata number" (the `#142 · lcars:verify` line), and `.card .no` ties
  // `.card .log-filing-status` on specificity while sitting LATER in board.css —
  // so carrying both handed this line the metadata grey and threw the amber away
  // before it ever reached the screen. `.failed` survived only by accident, on a
  // second colour at a higher specificity. `.log-filing-status` already sets the
  // font, size and letter-spacing it was borrowing, so `.no` contributed nothing
  // here but the colour that defeated it. Measured, not argued, in
  // FilingStatusStyleTest.
  var line = el("div", "log-filing-status" +
    (st.status === "failed" ? " failed" : ""), head);
  line.title = FILING_RECOVERY_HINT;
  host.appendChild(line);
  // The reason, exactly as the daemon stated it. Absent when it gave none —
  // an empty line beats an invented cause (S160/S161: never claim what the code
  // cannot know).
  if (st.error) host.appendChild(el("div", "log-filing-detail", st.error));
  return host;
}

/* ════════ S163 — the "Fix Filed Bugs" follow-through (card + detail) ════════
   One label builder, one tooltip, built HERE beside S162's strings for the same
   reason: every sentence about a mission's logged-bug batch comes from one place,
   so the card and the detail cannot word the same state differently.

   The count is in the LABEL, not just the tooltip: "Fix Filed Bugs" alone reads
   as a mode, and the number is the fact that makes the click a decision (four
   bugs is four cost estimates the captain is about to approve at once). */
/* S163 fix round 2 (D1): `shortfall` is how many of the batch never reached
   disk. With one, the label carries BOTH numbers — "⚙ FIX 2 OF 3 FILED BUGS".
   A bare "FIX 2 FILED BUGS" over a 3-bug batch would be true and misleading in
   the same breath: the count is the fact that makes the click a decision, and a
   captain approving 2 estimates has to know they asked for 3. The total is
   rebuilt from the two measurements (n + shortfall) rather than passed
   separately, so the two halves of the sentence cannot drift.

   S163 fix round 3 restates what the two numbers MEAN without touching the
   words: `n` is now every bug waiting to be fixed on the mission (the captain's
   ruling), and `shortfall` is still the latest batch's un-filed text. So the
   label reads "of the N+S bugs authored against this mission and not yet fixed,
   N are on disk and S never filed" — the one-report case D4 asks for ("1 OF 2")
   is unchanged, and it stays true when older waiting bugs sit beside it. */
/* S163 fix round 7 (D3): `resume` names what the click really is when a Go has
   already been taken over these bugs and the drive that took them is gone. "FIX"
   would read as "nothing has happened yet", which is the one thing that is not
   true here — and the captain needs to know a previous run went missing rather
   than discover it from a duplicate branch later. Same stem (`⚙ FIX `) so every
   surface that finds this control by its shape still finds it. */
function fixFiledLabel(n, shortfall, resume) {
  var head = "⚙ FIX " + n +
    (shortfall ? " OF " + (n + shortfall) : "") +
    " FILED BUG" + (n === 1 && !shortfall ? "" : "S");
  return resume ? head + " AGAIN" : head;
}
/* Says what the click OPENS, not what it runs — because it opens the review and
   dispatches nothing. That distinction IS BUG-059's hold, so the copy carries it.

   S163 fix round 2: with a shortfall it also carries S161's promise. The captain
   must not have to count cards to discover a bug never filed, and must not be
   left thinking the text of it is gone — the console this opens is still holding
   it and File retries exactly those. (S162's note says the same underneath, in
   the daemon's own words; this is the half that travels with the button.) */
/* S163 fix round 3 (D1): the tooltip promised "the bugs already filed" and, in
   the state the tester hit, delivered a failed report's console instead. It now
   describes what the click really opens under the captain's ruling — EVERY bug
   on this mission still waiting to be fixed, which is also exactly what the Go
   will run — so the sentence and the panel say the same thing. */
var FIX_FILED_TITLE =
  "Reopen the Mission Log at the cost review for every bug still waiting to be " +
  "fixed on this mission — check each estimate, steer any model, then Go to run " +
  "them all. Nothing runs until you do.";
/* S163 fix round 7 (D3): the resume's own sentence. It has to say the two things
   the card cannot show — that a run WAS dispatched, and that the thing which was
   running it is not running any more — or "AGAIN" is a mystery. */
var FIX_RESUME_TITLE =
  "A run was dispatched for these bugs, but the resolve-logs driving it is no " +
  "longer running and they never reached the consolidated re-verify gate. " +
  "Nothing is in flight. Reopen the cost review and Go to run them again.";
function fixFiledTitle(shortfall, resume) {
  if (resume) return FIX_RESUME_TITLE;
  if (!shortfall) return FIX_FILED_TITLE;
  return FIX_FILED_TITLE + " " + shortfall + " bug" +
    (shortfall === 1 ? "" : "s") + " did NOT file — the authored text is still " +
    "held in that console, and File retries just " +
    (shortfall === 1 ? "it" : "them") + ".";
}

/* The LIVE control, built once for both surfaces (the card's inline controls and
   the detail's action row). The title is set BEFORE applyWriteState so a
   view-only board's own reason wins — the S161 setFileLabel lesson, which is the
   difference between a disabled button that explains itself and one that lies
   about what it would do. */
function fixFiledControl(m, aff) {
  var b = btn(aff.label, aff.cls, function () { openLog(m.id, { fix: true }); });
  b.title = aff.title;
  return act("fix-filed", applyWriteState(b));
}

function runningPulse(label, liveness) {
  var base = RUNNING_COPY[label] || ("Underway · " + (label || "running") + "…");
  // S114: a REAL liveness tail derived from the worker's output activity (present
  // only while a live worker's sidecar exists). ABSENT ⇒ today's plain pulse,
  // byte-identical DOM (class list + label text) to before this round.
  var lv = livenessTail(liveness);
  var w = workingNode(lv ? (base + " — " + lv.text) : base);
  w.className += " lcars-running";
  if (lv) {
    w.className += " " + lv.cls;
    // A quiet/thinking-with-stale worker dampens the bars (still visible, calmer)
    // so a genuinely silent stage no longer reads as "actively producing".
    if (lv.quiescent) w.className += " lcars-quiescent";
  }
  return w;
}

/* S114 — the LCARS-voice liveness tail for the running pulse. Maps the server's
   liveness {state, quietSeconds} to a short uppercase phrase + a class the CSS
   tints/dampens. `producing` stays lively ("WRITING OUTPUT"); `thinking` reads as
   working with a subspace-quiet tail once it's been silent a beat; `quiet` reads
   as idle-but-watched, escalating to "hang guard watching" past ~4m (the guard's
   territory). Returns null when there's no liveness (caller renders the plain
   pulse). */
function fmtQuiet(s) {
  s = (typeof s === "number" && s > 0) ? Math.floor(s) : 0;
  if (s < 60) return s + "s";
  var m = Math.floor(s / 60);
  return m + "m";
}
function livenessTail(lv) {
  if (!lv || typeof lv !== "object" || !lv.state) return null;
  var q = (typeof lv.quietSeconds === "number") ? lv.quietSeconds : 0;
  if (lv.state === "producing") {
    return { text: "WRITING OUTPUT", cls: "live-producing", quiescent: false };
  }
  if (lv.state === "thinking") {
    return {
      text: "THINKING" + (q >= 3 ? " · SUBSPACE QUIET " + fmtQuiet(q) : ""),
      cls: "live-thinking",
      quiescent: q >= 8,
    };
  }
  // quiet
  return {
    text: "SUBSPACE QUIET " + fmtQuiet(q) + (q >= 240 ? " — HANG GUARD WATCHING" : ""),
    cls: "live-quiet",
    quiescent: true,
  };
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
  var owned = ownerLockOnVerify(m); if (owned) return owned; // S190
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
    // S163: the FILED-BUT-NOT-DISPATCHED window. The predicate above is
    // deliberately UNCHANGED — it also suppresses this parent's Merge/Accept,
    // and suppressing them while bugs are filed against the mission is right in
    // both windows. What changes is only the CONTROL and its COPY: here the lock
    // would be a disabled sentence about work in flight when BUG-059 has parked
    // the children and nothing runs without the captain's Go. So this window
    // gets the way FORWARD instead — the same suppression, an honest button.
    // The instant the Go is dispatched logFixState goes not-ready and the lock
    // below returns, now telling the truth (see logFixState).
    var fix = logFixState(m);
    if (fix.ready) {
      return {
        kind: "fix-filed",
        label: fixFiledLabel(fix.count, fix.shortfall, fix.resume),
        cls: "go", count: fix.count, shortfall: fix.shortfall,
        resume: fix.resume,
        title: fixFiledTitle(fix.shortfall, fix.resume),
      };
    }
    // S163 fix round 2 (D2) — the FILING window says ONE thing, not two.
    //
    // Measured by the tester through the whole ~60s filing of a 3-bug batch, on
    // card AND detail, with the daemon's own stamp reading `filedCount: 0`:
    //     ◐ FILING & COSTING…[DISABLED]   ◐ resolving 3 logged bugs…[DISABLED]
    // Nothing was resolving. It is D1's lie again from the same cause — S77's
    // lock is derived from the children EXISTING, and filing is precisely the
    // window in which they appear one at a time while nothing drives any of
    // them. (A/B'd against board.js at S162: pre-existing, not introduced here.)
    //
    // The honest statement already exists and is rendered by BOTH surfaces from
    // one builder (logFilingControl, beside this one on the card and in the
    // detail's action row), so this returns a SUPPRESSED affordance rather than
    // a second sentence: the predicate still runs, the parent's Merge/Accept
    // stay gated exactly as before, and the only thing that changes is that the
    // duplicate control is not drawn. It comes back the instant the filing ends
    // (test_the_lock_returns_the_moment_the_filing_ends).
    if (logFilingState(m).filing) {
      return { kind: "log-filing", suppress: true };
    }
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
    // S163 fix round 5: a VERDICT — the busy animation is replaced by the
    // repaint on this same line, so without it the refusal leaves no trace at
    // all and the card simply looks as though nothing was ever clicked.
    function (msg) { setVerdict(msg, "err"); refresh(); });
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
      // S163 fix round 5: a VERDICT — a merge that was refused is exactly the
      // outcome a captain must not have to guess at, and clearing the optimistic
      // "merging…" state makes the card look untouched once the line is gone.
      setVerdict(msg, "err"); refresh();
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
      // S163 fix round 5 — setStatus by choice: a failed READ, like "board
      // unavailable" above. Nothing was dispatched, so there is no outcome to
      // preserve, and it must yield to the next successful render.
      setStatus("mission unavailable");
    });
}

/* S161 — the live daemon-side Mission-Log session for a parent mission.
   GET /api/mission/<id>/log/session; 404 (the normal case — no session) calls
   back with null so the console just opens fresh. Read-only: it dispatches
   nothing, so polling it is free. */
function fetchLogSession(id, cb, onErr) {
  fetch("/api/mission/" + enc(id) + "/log/session")
    .then(function (r) {
      if (r.status === 404) return null;   // no live session — open fresh
      if (!r.ok) throw new Error("log session unavailable");
      return r.json();
    })
    .then(function (s) { if (cb) cb(s); })
    .catch(function () { if (onErr) onErr(); });
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

/* ════════════════════════════════════════════════════════════════════════
   S125 — THE HOLODECK (D1–D3, D6–D8, D12)

   A cheap design room that lives INSIDE this frame. `⬡ HOLODECK` swaps the
   board content for the deck; the same control reads `▦ BOARD` on the way back
   (D1). Three panes — PROGRAMS · CHAT · LIVE PREVIEW (D2) — and the preview is
   the sidecar's REAL file served over the jailed read route, refreshed when a
   turn's `filesChanged` says the file moved (D3), never re-rendered from the
   reply text.

   S126 added durable programs and the concept doc; S127 added SEND TO ALIGN,
   the hand-off dialog and the draft→sent lock; S172 built ⧉ DUPLICATE TO KEEP
   DESIGNING, on the card AND in the locked program's own pane. WHAT IS STILL
   DELIBERATELY NOT HERE, and why nothing on screen pretends otherwise: the
   INTENT panel's inline contents (the ▤ control opens the file instead),
   CAPTURE SCREENS, and the `done` state. Anything not yet real is ABSENT, or
   visibly disabled WITH the reason — never a control that does nothing when you
   click it, and never a reason that has stopped being true.
   ════════════════════════════════════════════════════════════════════════ */
var HOLO = {
  on: false,            // is the deck showing instead of the board?
  programs: [],         // GET /api/holodeck — the daemon's LIVE sessions
  activeId: null,       // which program the chat + preview are showing
  busy: false,          // a turn is in flight
  filter: "all",        // D11's chips, over a real draft→sent lifecycle (S127)
  // Q3 (S128) — is the PROGRAM DRAWER open? Only meaningful below the
  // stylesheet's breakpoint, where the list stops being a column. It lives here
  // and not only as a class because renderDeck rebuilds the deckview on every
  // turn, and a drawer whose only memory is that node slams shut mid-turn.
  drawer: false,
  banner: null,         // D7 — {kind, label, text, paths, action}
  /* S128 (FL-002) — THE DAEMON'S `meta.holodeck`, or null. The one fact the
     board band's activity indicator is allowed to be drawn from: is a program
     mid-turn, since when, and the sentence that says so. It arrives on the
     BOARD payload (not the deck's), because the whole point is that it is
     readable from the board — where a captain who walked away is standing.
     A client-side timer here would be a guess, and a guessed spinner is the
     readout lie this round exists to close. */
  working: null,
  /* S171 — WHICH PROGRAMS THIS PAGE IS ALREADY WATCHING A DERIVATION ON.
     `renderDeck` runs on every refresh, so a poll started from the render
     would multiply once per repaint; and a page that RELOADS onto a running
     pass must start one, because there was no click to start it here. One
     entry per session id answers both — it is bookkeeping about this tab's
     timers only, never a claim about what the daemon is doing. */
  derivePolls: Object.create(null),
  nonce: 0,             // the preview's cache-buster; bumped per file change
  sidecarName: null,    // learnt from the first program (D6's footer chip)
  commits: 0,
  // THE DAEMON'S HEADER (fix round 1). Everything here is a fact only the
  // daemon can know, and each one was previously invented on this side:
  //   sidecarDisplay  the archive's FULL path, `~`-folded — D6's empty state
  //                   shows a LOCATION, and a basename is not one.
  //   engineName/model  what will ACTUALLY run. The dialog printed a hardcoded
  //                   "sonnet tier" that is false on copilot (opus there).
  //   engine/models   S127. The New Program dialog now PICKS the engine, so it
  //                   needs two more facts only the daemon has: the daemon's
  //                   own engine as an INVOCABLE path (`engine`), so choosing
  //                   the engine it was started with sends that exact binary
  //                   rather than a bare name that may resolve elsewhere on
  //                   $PATH; and `models`, the per-engine tier table, so the
  //                   footer can state the tier of an engine this daemon is
  //                   NOT running without board.js owning a second copy of
  //                   `_holodeck_model`.
  sidecarDisplay: "",
  engine: "",
  engineName: "",
  model: "",
  models: {},
  // S127 (FL-007) — WHICH HALF OF THE ⬡ PREVIEW / ▤ INTENT TOGGLE IS SHOWING.
  // It lives here and not in the DOM because `renderDeck` rebuilds the pane on
  // every turn: a toggle whose only memory is the node it drew flips back to
  // the mockup underneath a captain who is mid-read. `pvSid` is what makes
  // switching PROGRAMS land on the mockup instead of on the previous
  // program's intent — one guard, rather than a reset at four call sites.
  pvView: "preview",
  pvSid: null,
  // the intent panel's bytes, per program. Dropped when a turn actually
  // rewrites `concept.md` — the same discipline D3 applies to the mockup.
  intent: { sid: null, text: null, err: null, loading: false },
  /* S169 (FL-013 + FL-014) — THE COMPOSER'S UNSENT STATE, PER PROGRAM.
     `{ <sessionId>: { text: "<what he typed>", images: [<pastes>] } }`.

     WHY IT IS HERE AND NOT IN THE TEXTAREA. `holoChatPane` builds the composer
     as a fresh `el("textarea")` on every render, so its value lived ONLY in
     that node — and `renderDeck` rebuilds the pane on a turn landing, a
     program switch, a banner, a drawer toggle, a deck re-entry. The captain
     typed a paragraph, went to the board to deploy main, came back, and it was
     gone: no warning, no undo, on the ONE surface whose whole premise is
     capturing requirements in his own words. This is the same treatment
     `pvView`/`pvSid` and S127's drag handle already get — view state that must
     outlive a repaint lives in HOLO — and it is restored INTO the same
     textarea rather than shadowed by a second node beside it.

     KEYED BY SESSION ID, and a MAP rather than `pvSid`'s single slot, because
     "switch programs and come back" is one of the triggers that loses work:
     a one-slot guard would cure the board round-trip and keep the defect.

     THE PASTED IMAGES LIVE IN THE SAME OBJECT (FL-014) on purpose. They are
     one thing — the unsent turn — and `attachImagePaster` otherwise keeps its
     list in a closure that dies with the node exactly like `value` did.

     …AND SO DOES `intent` (FL-015). It is the third field of one unsent turn —
     what he typed, what he pasted, and whether he is ASKING or DIRECTING — so
     it belongs in this object and not in a fourth store beside it. Default
     "build". It is per-TURN, not a mode: `holoDraftClear` drops the whole
     draft when the turn is sent, so the next turn starts at "build" again.
     A sticky ASK would be worse than no control at all — he would flip it
     once, type "make the rail wider" three turns later, and get an answer. */
  drafts: Object.create(null),
};

/* READ this program's unsent turn. Never null, so every caller reads one shape
   — but it does NOT create: rendering a composer is not the same as the
   captain typing in one, and a read that stored would leave an empty draft
   behind for every program ever painted, including one just sent. */
function holoDraftFor(sid) {
  return (sid && HOLO.drafts[sid]) || { text: "", images: [], intent: "build" };
}

/* …and WRITE it. The only thing that puts a draft in HOLO is the captain
   putting something in the composer. */
function holoDraftPut(sid) {
  if (!sid) return { text: "", images: [], intent: "build" };
  var d = HOLO.drafts[sid];
  if (!d) { d = HOLO.drafts[sid] = { text: "", images: [], intent: "build" }; }
  return d;
}

/* The turn has been said — it is in the transcript now, so it is no longer a
   draft. Called from `holoSay` (not from the composer) so a refused send keeps
   what he typed. */
function holoDraftClear(sid) {
  if (sid && HOLO.drafts[sid]) delete HOLO.drafts[sid];
}

var HOLO_FILTERS = [["all", "ALL"], ["draft", "DRAFT"], ["sent", "SENT"],
                    ["done", "DONE"]];

function deckHost() { return document.getElementById("deckHost"); }

function holoActive() {
  /* S126 — a program listed FROM DISK has `sessionId: null`, honestly, because
     no conversation is running for it. Without this guard a null `activeId`
     would match the first such card and the deck would open a chat pane for a
     program the daemon is not holding — a composer that 404s on send. */
  if (!HOLO.activeId) return null;
  for (var i = 0; i < HOLO.programs.length; i++) {
    if (HOLO.programs[i].sessionId === HOLO.activeId) return HOLO.programs[i];
  }
  return null;
}

/* A control ON THE DECK. Every one carries its own honesty: `data-wired` when
   something actually happens on click, `data-reason` when it is disabled and
   the reason is the whole point of it still being visible. The no-dead-controls
   test reads exactly these two attributes, so a control added later cannot slip
   through by being neither. */
function holoCtl(node, label, onClick, reason) {
  node.setAttribute("data-ctl", label);
  if (onClick) {
    node.setAttribute("data-wired", "1");
    node.addEventListener("click", function (e) {
      e.stopPropagation();
      onClick(e);
    });
  } else if (reason) {
    node.disabled = true;
    node.title = reason;
    node.setAttribute("aria-disabled", "true");
    node.setAttribute("data-reason", reason);
  }
  return node;
}

function holoBtn(label, cls, onClick, reason) {
  var b = el("button", "btn" + (cls ? " " + cls : ""), label);
  b.type = "button";
  return holoCtl(b, label, onClick, reason);
}

/* D8 — recency in plain language. "which one was that" is the actual question a
   captain asks days later, and a raw timestamp does not answer it. Old work
   falls back to a stardate rather than "1,247 days ago". */
function holoWhen(ts) {
  if (!ts) return "just now";
  var secs = (Date.now() / 1000) - ts;
  if (secs < 90) return "now";
  if (secs < 3600) return Math.round(secs / 60) + " min ago";
  if (secs < 86400) return Math.round(secs / 3600) + "h ago";
  if (secs < 172800) return "yesterday";
  if (secs < 864000) return Math.round(secs / 86400) + " days ago";
  var d = new Date(ts * 1000);
  return "stardate " + (d.getFullYear() - 1946) + "" +
    String(Math.round(((d.getMonth() * 30 + d.getDate()) / 365) * 1000)).slice(0, 3);
}

function holoBase(p) {
  var i = String(p || "").lastIndexOf("/");
  return i === -1 ? String(p || "") : String(p).slice(i + 1);
}

/* S127 (D11) — a program's PLACE IN ITS LIFE: draft → sent → done.

   Read from `lifecycle` first and `status` only as the fallback, because
   `status` carries two different facts on the daemon's side: the program's
   lifecycle on the list, and a TURN'S OUTCOME ("standing-by", "ok", "refused",
   "ended") on the payloads that update over it. `lifecycle` is never
   overwritten, so a locked program cannot read "standing-by" here. */
function holoLifecycle(p) {
  return (p && (p.lifecycle || p.status)) || "draft";
}

/* ── D1: entering and leaving the deck ─────────────────────────────────── */
/* The board furniture is hidden by ONE class on <body>, never by setting
   `hidden` on each node: render() rebuilds the board area and re-decides those
   flags on every SSE tick, so a JS flag set at enter-time would be wiped by the
   very next one and the board would bleed back through the deck. */
function holoSetMode(on) {
  HOLO.on = !!on;
  var body = document.body;
  if (body && body.classList) body.classList.toggle("on-deck", HOLO.on);
  var host = deckHost();
  if (host) host.hidden = !HOLO.on;
  holoPaintBandBtn();
  if (HOLO.on) { renderDeck(); holoRefresh(); }
}

/* ONE FUNCTION PAINTS THE BAND CONTROL (S128). It carries three independent
   facts and each used to be written by a different handler:

     • which way it goes — `⬡ HOLODECK` on the board, `▦ BOARD` on the deck;
     • whether writes are live at all — D7's view-only refusal, WITH its reason;
     • and now whether the daemon says a program is mid-turn (FL-002).

   They are painted together because `textContent =` REPLACES a node's children:
   an activity dot appended by a second handler is silently wiped the next time
   the label is written, which is the class of bug two handlers over one control
   always eventually produce. View-only OUTRANKS activity — a board that cannot
   run a program must not sprout a dot claiming one is running. */
var HOLO_RO_REASON =
  "This board is a read-only view. The holodeck writes files, so it is "
  + "unavailable here — open the board locally to run a program.";

function holoPaintBandBtn() {
  var b = document.getElementById("holodeckBtn");
  if (!b) return;
  var ro = writesActive === false;
  /* S183 fix round 1 (D2): the FOURTH independent fact this one button carries
     — the foundation lock (captain ruling: the holodeck is locked until the
     repo has a test foundation). It is read here rather than painted by
     paintFoundationLock, because THIS function is the button's single owner and
     the previous split let it silently unlock a locked deck. Read-only still
     OUTRANKS everything; a lock outranks the activity dot, which must never
     claim a program is running on a deck nobody can open. */
  var lock = (!ro && foundationLockReason) ? foundationLockReason : "";
  var blocked = ro || !!lock;
  b.disabled = blocked;
  b.textContent = HOLO.on ? "▦ Board" : "⬡ Holodeck";
  if (b.classList) b.classList.toggle("holo-on", HOLO.on);
  /* No CSS of its own: `.btn[disabled]` already dims to .4 and shows
     `cursor: not-allowed` (the treatment ▦ FILE MISSION was measured wearing).
     The class is a marker for paintFoundationLock's undo, not a style. */
  if (b.classList) b.classList.toggle("foundation-locked", !!lock);
  /* The dot is the OFF-DECK signal. On the deck the working turn is already
     visible in the chat pane, and a second indicator two inches away is a
     second voice about one fact. */
  var w = (!blocked && !HOLO.on && HOLO.working && HOLO.working.count)
    ? HOLO.working : null;
  if (b.classList) b.classList.toggle("working", !!w);
  if (w) {
    var dot = el("span", "holo-dot");
    dot.setAttribute("aria-hidden", "true");   // a colour, not information
    b.appendChild(dot);
  }
  b.title = ro ? HOLO_RO_REASON
    : (lock ? lock
    : (w ? String(w.message || "")
         : (HOLO.on ? "back to the mission board"
                    : "the holodeck — design a mockup in chat")));
  if (blocked) b.setAttribute("data-reason", ro ? HOLO_RO_REASON : lock);
  else b.removeAttribute("data-reason");
  /* A DOT IS NOTHING TO A SCREEN READER. The daemon's sentence — which names
     the program and how long it has been going — is what is announced, and it
     is removed again the moment nothing is in flight. */
  if (w) b.setAttribute("aria-label", "⬡ Holodeck — " + String(w.message || ""));
  else b.removeAttribute("aria-label");
}

/* The board payload's `meta.holodeck`, or nothing at all. Called on every
   render, so the indicator follows the daemon DOWN as well as up — an
   indicator that only ever lights is a worse lie than none. */
function renderHolodeckActivity(h) {
  HOLO.working = (h && h.count) ? h : null;
  holoPaintBandBtn();
}

function toggleHolodeck() {
  if (writesActive === false) return;   // view-only: the control is disabled
  /* S183 fix round 1 (D2): the foundation lock, in the same idiom — ENTERING is
     refused, LEAVING never is (a captain already on the deck must always be
     able to get back to the board). The disabled button is the first line; this
     is the second, for any path that reaches the deck without it. */
  if (!HOLO.on && foundationLockReason) return;
  holoSetMode(!HOLO.on);
}

function holoRefresh() {
  return fetch("/api/holodeck").then(function (r) { return r.json(); })
    .then(function (data) {
      HOLO.programs = (data && data.programs) || [];
      HOLO.sidecarDisplay = (data && data.sidecarDisplay) || "";
      HOLO.engine = (data && data.engine) || "";
      HOLO.engineName = (data && data.engineName) || "";
      HOLO.model = (data && data.model) || "";
      HOLO.models = (data && data.models) || {};
      if (data && data.sidecarName) HOLO.sidecarName = data.sidecarName;
      if (HOLO.programs.length) {
        HOLO.sidecarName = HOLO.programs[0].sidecarName;
        HOLO.commits = HOLO.programs[0].commits || 0;
      }
      /* S169 (FL-013) — a draft belongs to a program, so it dies with one.
         Ending a program (or a daemon that no longer holds it) is the only
         thing that drops an unsent turn; every other repaint keeps it. */
      var live = Object.create(null);
      for (var d = 0; d < HOLO.programs.length; d++) {
        if (HOLO.programs[d].sessionId) live[HOLO.programs[d].sessionId] = 1;
      }
      Object.keys(HOLO.drafts).forEach(function (sid) {
        if (!live[sid]) delete HOLO.drafts[sid];
      });
      if (HOLO.activeId && !holoActive()) HOLO.activeId = null;
      if (!HOLO.activeId) {
        // only a LIVE program can be the active one — a room read off disk has
        // no session to talk to until it is reopened (S126).
        for (var i = 0; i < HOLO.programs.length; i++) {
          if (HOLO.programs[i].sessionId) {
            HOLO.activeId = HOLO.programs[i].sessionId;
            break;
          }
        }
      }
      renderDeck();
    })
    .catch(function () { /* the deck simply shows what it last knew */ });
}

/* ════════════════════════════════════════════════════════════════════════
   D2, AMENDED 2026-08-05 (captain, S127 live drive) — THE CHAT ⇄ PREVIEW SPLIT

     "I need some way to resize the chat window to give the mock render more
      room. This becomes more important if I make the window full screen. Then
      the chat takes up a comical amount of room."

   D2 originally fixed the split at `1.15fr : 1fr` and refused a handle: a
   draggable split is state to persist, a thing to get wrong on reload, and a
   decision to make every session. That reasoning was not wrong about the costs,
   it was wrong about the alternative — it compared them against a fixed split
   that is CORRECT, when the fixed split is wrong at every width except the one
   it was tuned at. `1.15fr` grows the chat without bound: at full screen on a
   2560px display that is ~1250px of chat against a natural readable line of ~70
   characters, every pixel past that spent on the one pane that cannot use it
   while the preview — which D2 itself calls "the point" — starves. And "a
   decision every session" is answered by PERSISTING it: he sets it once.

   WHAT IS DELIBERATELY ABSENT. There is no cap on the chat's growth, here or in
   the stylesheet. The captain chose the handle ALONE, explicitly over an option
   that also capped the chat automatically. He wants the control, not a rule
   guessing for him. `test_the_chat_column_is_NOT_capped` is the guard.

   THE ONE NUMBER TO CHANGE is HOLO_SPLIT_DEFAULT. `1.15 : 1` is chat 53.5%,
   which is the poor starting position the amendment names; a preview-favouring
   default is inside the ruling and wanted. 0.42 puts the chat at ~510px on a
   1440px laptop — near the natural readable line — and hands the rest to the
   render.

   The split rides in TWO CUSTOM PROPERTIES on `.deckview` rather than an inline
   `grid-template-columns`, because an inline value would also override
   `.deckview.solo` — a deck with no chat and no preview at all.
   ════════════════════════════════════════════════════════════════════════ */
var HOLO_SPLIT_KEY = "lcars-holo-split";
var HOLO_SPLIT_DEFAULT = 0.42;  // ← the chat's share of (chat + preview)

/* THE TWO PIXEL FLOORS, named once. The stylesheet's `minmax()` mins are
   `var(--holo-chat-min,340px)` / `var(--holo-pv-min,360px)` and MUST be these
   same two numbers — `test_the_px_floors_are_ONE_pair_shared_by_the_stylesheet
   _and_the_js` fails if they drift, because a mismatch is the bug below coming
   straight back.

   FIX ROUND 1 — WHY THE CLAMP MOVED INTO PIXELS. The first cut left the floors
   to CSS alone: `minmax(340px, var(--holo-chat-fr))`. Measured in headless
   Chrome at viewport 1600 (deck 1516, span 1293), a drag to 0.25 produced
   tracks `216px 340px 7px 714.75px` — a sum of 1278 against 1516, i.e. a 238px
   DEAD BAND on the right of the deck. When an fr max resolves below the px min,
   grid clamps that track to the min correctly, but then resolves the OTHER
   track's fr against the ORIGINAL free space rather than the space the clamp
   released; the surplus is never redistributed. The user-visible result was the
   exact opposite of what the captain asked for — he drags left to give the mock
   render more room and gets an empty band.

   So the fractions handed to the grid are clamped HERE, against the live span,
   so no fr track is ever asked to resolve below its floor and the pair always
   consumes the whole span. The `minmax()` mins stay as a safety net for a
   viewport too narrow for any valid split; the normal path never reaches them.

   This is a MINIMUM-side clamp. It is not, and must not become, a cap on the
   chat's growth — the captain rejected that explicitly. There is no maximum
   pixel constant here for exactly that reason. */
var HOLO_CHAT_MIN_PX = 340;
var HOLO_PV_MIN_PX = 360;

/* The fraction-space guard, used when nothing has been laid out yet (first
   paint, a headless harness) and there is no span to measure. */
var HOLO_SPLIT_MIN = 0.15;
var HOLO_SPLIT_MAX = 0.85;
var HOLO_SPLIT_STEP = 0.02;     // one arrow-key nudge
var HOLO_SPLIT = null;          // in-memory; null = not read from storage yet

/* Is the span too narrow to satisfy BOTH floors? Then no split exists that
   does, and the bounds below collapse to a single value. */
function holoSplitDegraded(total) {
  return !!total && total > 0 && total <= HOLO_CHAT_MIN_PX + HOLO_PV_MIN_PX + 2;
}

/* [min, max] fraction for a chat+preview span of `total` px, derived from the
   two floors rather than hardcoded — a wider deck legitimately permits a
   narrower chat FRACTION, because the bound is a pixel.

   The +1 is a pixel of slack: without it the bound resolves to EXACTLY the
   floor and `toFixed()`'s rounding can land a hair under it, which is enough to
   trip the clamp and strand a pixel or two of band.

   `null` when there is nothing to measure — the caller then keeps the
   fraction-space guard, which is the honest answer rather than an invented
   one. */
function holoSplitBounds(total) {
  if (!total || total <= 0) return null;
  if (holoSplitDegraded(total)) {
    /* DEGRADED, and the choice is stated rather than emergent: divide the span
       in PROPORTION TO THE TWO FLOORS, so neither pane is singled out to absorb
       the shortfall and the answer is the same whatever was stored or dragged.
       Both panes end up under their floor — there is no room — and the
       stylesheet's `minmax()` mins then hold each track at its minimum, so the
       deck overflows and clips rather than silently hiding one pane. Below this
       width the three-pane contract simply does not fit. */
    var f = HOLO_CHAT_MIN_PX / (HOLO_CHAT_MIN_PX + HOLO_PV_MIN_PX);
    return [f, f];
  }
  return [(HOLO_CHAT_MIN_PX + 1) / total, 1 - (HOLO_PV_MIN_PX + 1) / total];
}

/* The chat+preview span in px, measured off the live deck. `chat.offsetLeft` is
   the 216px program-list track above the breakpoint and 0 below it (where the
   list is an out-of-flow drawer), so one read covers both layouts without this
   file having to know what the stylesheet decided. */
function holoSplitSpan() {
  var host = deckHost();
  var view = host && host.querySelector ? host.querySelector(".deckview") : null;
  if (!view || !view.querySelector) return 0;
  var chat = view.querySelector(".holo-chat");
  var handle = view.querySelector(".deck-split");
  if (!chat || !handle) return 0;
  var span = (view.clientWidth || 0) - (chat.offsetLeft || 0)
             - (handle.offsetWidth || 0);
  return span > 0 ? span : 0;
}

/* Storage is OPTIONAL and never fatal: Safari's private mode throws on read,
   an embedded webview may not have it at all, and a deck that cannot remember
   its split is still a deck. */
function holoStore() {
  try {
    return (typeof localStorage !== "undefined" && localStorage) || null;
  } catch (e) { return null; }
}

/* `total` is optional: with a span it clamps in PIXELS, without one it falls
   back to the fraction-space guard. */
function holoSplitClamp(f, total) {
  f = parseFloat(f);
  if (!isFinite(f)) f = HOLO_SPLIT_DEFAULT;
  f = Math.min(HOLO_SPLIT_MAX, Math.max(HOLO_SPLIT_MIN, f));
  var b = holoSplitBounds(total);
  if (b) f = Math.min(b[1], Math.max(b[0], f));
  return f;
}

function holoSplitGet() {
  if (HOLO_SPLIT !== null) return HOLO_SPLIT;
  var raw = null;
  try {
    var s = holoStore();
    if (s) raw = s.getItem(HOLO_SPLIT_KEY);
  } catch (e) { raw = null; }
  HOLO_SPLIT = (raw === null || raw === "") ? HOLO_SPLIT_DEFAULT
                                            : holoSplitClamp(raw);
  return HOLO_SPLIT;
}

/* THE CAPTAIN'S PREFERENCE, as opposed to what fits. `holoSplitGet` is the
   number he chose; `holoSplitEffective` is that number made legal for the width
   currently on screen. They are kept apart on purpose: a 0.25 set on a 2560px
   display is legal there and illegal at 1100px, and collapsing the two would
   mean a window he narrowed for five minutes silently ate the preference. */
function holoSplitEffective() {
  return holoSplitClamp(holoSplitGet(), holoSplitSpan());
}

/* `persist` is false mid-drag and true when the gesture ENDS — a pointermove
   writes to storage sixty times a second otherwise, for one decision. Every
   caller is an EXPLICIT gesture, so this one does write the pixel-clamped
   value: he moved it in this window, at this width. */
function holoSplitSet(f, persist) {
  HOLO_SPLIT = holoSplitClamp(f, holoSplitSpan());
  holoSplitApply();
  if (persist) {
    try {
      var s = holoStore();
      if (s) s.setItem(HOLO_SPLIT_KEY, String(HOLO_SPLIT));
    } catch (e) { /* a deck that cannot remember is still a deck */ }
  }
  return HOLO_SPLIT;
}

function holoSplitReset() { return holoSplitSet(HOLO_SPLIT_DEFAULT, true); }

/* The split a drag of `dx` pixels lands on, over a chat+preview span of
   `total`. PURE, and separate from the pointer plumbing on purpose: a node
   harness can never deliver a pointer event, but it can prove the arithmetic
   and the clamp — which is the half that has the off-by-one in it. */
function holoSplitFromDrag(startChatPx, dx, total) {
  if (!total) return holoSplitGet();
  return holoSplitClamp((startChatPx + dx) / total, total);
}

function holoSplitApply() {
  var host = deckHost();
  var view = host && host.querySelector ? host.querySelector(".deckview") : null;
  if (!view || !view.style || !view.style.setProperty) return;
  /* the EFFECTIVE split, not the stored one: a value saved on a wider window is
     replayed into a narrower one on the next reload, and unclamped that reopens
     the dead band on a deck nobody has touched. The preference is left alone —
     widen the window again and it comes back. */
  var f = holoSplitEffective();
  /* six places, not four: the bounds are pixel-derived, and rounding a bound
     down by a ten-thousandth is enough to put a track back under its floor. */
  view.style.setProperty("--holo-chat-fr", f.toFixed(6) + "fr");
  view.style.setProperty("--holo-pv-fr", (1 - f).toFixed(6) + "fr");
  var h = view.querySelector(".deck-split");
  if (h) h.setAttribute("aria-valuenow", String(Math.round(f * 100)));
}

/* THE HANDLE. A grid COLUMN, not an overlay: it cannot sit on top of either
   pane's content, and because both panes keep a floor it can never be pushed
   off the edge — after any drag it is still there to drag back. */
function holoSplitHandle() {
  var h = el("div", "deck-split");
  h.appendChild(el("span", "grip"));
  /* The standard window-splitter role, so assistive tech says what this is and
     where it sits instead of "group". NOT keyActivable: that idiom maps
     Enter/Space onto `click`, and a click is what ENDS a drag — the reset would
     fire every time the captain let go of the handle. */
  h.setAttribute("role", "separator");
  h.setAttribute("aria-orientation", "vertical");
  h.setAttribute("aria-label", "Chat / preview split");
  h.setAttribute("aria-valuemin", String(Math.round(HOLO_SPLIT_MIN * 100)));
  h.setAttribute("aria-valuemax", String(Math.round(HOLO_SPLIT_MAX * 100)));
  h.setAttribute("tabindex", "0");
  h.title = "Drag to give the preview more room. Arrow keys nudge it; "
    + "double-click resets it.";
  /* It IS wired — three real handlers below — so it says so in the deck's own
     no-dead-controls vocabulary. It is not wired to `click`, which is why this
     is stated rather than inferred by holoCtl. */
  h.setAttribute("data-ctl", "chat / preview split");
  h.setAttribute("data-wired", "1");

  h.addEventListener("pointerdown", function (e) { holoSplitDrag(e, h); });
  h.addEventListener("dblclick", function (e) {
    if (e && e.preventDefault) e.preventDefault();
    holoSplitReset();
  });
  h.addEventListener("keydown", function (e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    var d = 0;
    if (e.key === "ArrowLeft") d = -HOLO_SPLIT_STEP;
    else if (e.key === "ArrowRight") d = HOLO_SPLIT_STEP;
    else if (e.key === "Home" || e.key === "Enter" || e.key === " ") {
      e.preventDefault(); e.stopPropagation();
      holoSplitReset();
      return;
    } else return;
    e.preventDefault();
    /* stopPropagation so the deck's global key handling never ALSO acts on a
       nudge — the same discipline keyActivable applies. */
    e.stopPropagation();
    /* a keyboard nudge persists immediately: there is no "gesture end" to wait
       for, and a keyboard user who re-sets the split on every reload has an
       inaccessible control. It steps from the EFFECTIVE split — the one on
       screen — so the first press moves the handle the captain can see rather
       than a stored value that is currently out of range at this width. */
    holoSplitSet(holoSplitEffective() + d, true);
  });
  return h;
}

/* The other half of "the bound is a pixel". Narrowing the window can put the
   stored split out of range without a single gesture, and the deck must
   re-clamp as it happens rather than at the next reload. Bound once, lazily,
   because board.js is also loaded by node harnesses with no window events. */
var HOLO_RESIZE_BOUND = false;
function holoBindResize() {
  if (HOLO_RESIZE_BOUND) return;
  if (typeof window === "undefined" || !window || !window.addEventListener) return;
  HOLO_RESIZE_BOUND = true;
  window.addEventListener("resize", function () {
    if (HOLO.on) holoSplitApply();
  });
}

function holoSplitDrag(e, handle) {
  /* looked up from the host rather than `handle.parentNode`, so the handle can
     be moved in the tree without silently disabling the drag. */
  var host = deckHost();
  var view = host && host.querySelector ? host.querySelector(".deckview") : null;
  var chat = view && view.querySelector ? view.querySelector(".holo-chat") : null;
  var pv = view && view.querySelector ? view.querySelector(".preview") : null;
  if (!chat || !pv) return;
  /* the span the grid is DIVIDING, not the sum of what the two panes currently
     occupy. Before the pixel clamp those two differed by exactly the dead band,
     and a drag that measured the panes would have carried the gap along with
     it, never able to close it. */
  var total = holoSplitSpan() || ((chat.offsetWidth || 0) + (pv.offsetWidth || 0));
  if (!total) return;
  var startX = e.clientX;
  var startChat = chat.offsetWidth || 0;
  if (e.preventDefault) e.preventDefault();
  if (view.classList) view.classList.add("dragging");
  /* Pointer capture keeps the drag alive over the IFRAME. Without it the very
     first pixel of travel puts the pointer inside the sandboxed preview
     document, which swallows the move events and the handle sticks. */
  try { if (handle.setPointerCapture) handle.setPointerCapture(e.pointerId); }
  catch (err) { /* not every pointer type can be captured */ }
  function move(ev) {
    holoSplitSet(holoSplitFromDrag(startChat, ev.clientX - startX, total),
                 false);
  }
  function up() {
    document.removeEventListener("pointermove", move);
    document.removeEventListener("pointerup", up);
    document.removeEventListener("pointercancel", up);
    if (view.classList) view.classList.remove("dragging");
    holoSplitSet(holoSplitGet(), true);   // one write, at the end of the gesture
  }
  document.addEventListener("pointermove", move);
  document.addEventListener("pointerup", up);
  document.addEventListener("pointercancel", up);
}

/* ════════════════════════════════════════════════════════════════════════
   Q3, RESOLVED 2026-08-05 (captain, S127 live drive) — THE PROGRAM DRAWER

   Below the breakpoint the PROGRAM LIST collapses to a drawer; chat and preview
   keep the full width. The list is the pane least needed moment-to-moment, so
   it hides behind a control rather than shrinking the two panes the work
   actually happens in. The PREVIEW explicitly does NOT become a toggle at any
   width — D2's "the preview is the point, it must be permanently visible"
   survives everywhere.

   THE OTHER NUMBER TO CHANGE is the breakpoint, and it is in board.css
   (`@media (max-width:1199px)`) rather than here, because nothing about this
   behaviour is decided in JS: the toggle is rendered at EVERY width and the
   stylesheet alone decides whether it is on screen. That is what lets opening
   the drawer be a single class flip on the live DOM instead of a re-render —
   and a re-render is the chat's scroll position, the preview's iframe, and the
   whole deck's state, gone.
   ════════════════════════════════════════════════════════════════════════ */
function holoDrawerSet(on) {
  HOLO.drawer = !!on;
  var host = deckHost();
  if (!host) return;
  var view = host.querySelector(".deckview");
  if (view && view.classList) view.classList.toggle("drawer-open", HOLO.drawer);
  /* Every toggle on screen restates the same fact — the solo deck and the chat
     header each carry one, and they are the same control, not two states. */
  var btns = host.querySelectorAll(".holo-drawer-btn");
  for (var i = 0; i < btns.length; i++) {
    btns[i].setAttribute("aria-expanded", HOLO.drawer ? "true" : "false");
  }
}

/* ONE BUILDER, TWO PLACEMENTS — the chat header when a program is open, and the
   empty deck when none is (the morning state is SOLO, has no chat header, and
   is exactly the state in which the list is wanted). A real <button>, so the
   browser's own keyboard handling applies: wrapping one in keyActivable fires
   click TWICE for a single Enter, which on a toggle is a visible no-op. */
function holoDrawerToggle() {
  var b = el("button", "btn holo-drawer-btn", "☰ Programs");
  b.type = "button";
  b.setAttribute("aria-expanded", HOLO.drawer ? "true" : "false");
  b.title = "Show or hide the program list. On a narrow window it becomes a "
    + "drawer so the chat and the preview keep the full width.";
  return holoCtl(b, "programs drawer", function () {
    holoDrawerSet(!HOLO.drawer);
  });
}

/* Click-away, the gesture people actually make to dismiss a drawer. It is a
   sibling of the panes rather than a child of one, and the stylesheet keeps it
   out of the way entirely above the breakpoint. */
function holoScrim() {
  var s = el("div", "holo-scrim");
  s.setAttribute("aria-hidden", "true");
  return holoCtl(s, "close programs drawer", function () {
    holoDrawerSet(false);
  });
}

/* ── the deck itself ───────────────────────────────────────────────────── */
function renderDeck() {
  var host = deckHost();
  if (!host) return;
  host.innerHTML = "";
  var banner = holoBannerNode();
  if (banner) host.appendChild(banner);
  var active = holoActive();
  var view = el("div", "deckview" + (active ? "" : " solo")
                + (HOLO.drawer ? " drawer-open" : ""));
  view.appendChild(holoProgramsPane());
  if (active) {
    view.appendChild(holoChatPane(active));
    /* THE HANDLE, between the chat and the preview and nowhere else — the
       216px program list is not part of this split (D2's amendment says so in
       its last line). A solo deck has neither pane, so it gets no handle. */
    view.appendChild(holoSplitHandle());
    view.appendChild(holoPreviewPane(active));
  } else {
    view.appendChild(holoEmptyDeck());
  }
  view.appendChild(holoScrim());
  host.appendChild(view);
  /* The split is re-stamped on the freshly built node: renderDeck rebuilds the
     deck on every turn, and a split whose only memory is the node it drew snaps
     back to the default under a captain who moved it one turn ago. */
  holoSplitApply();
  holoBindResize();
  /* S127 — THE HAND-OFF BAR, under everything and always reachable (the mock's
     own placement). It spans the deck rather than living in one pane because
     sending is an act on the PROGRAM, not on the chat or the preview. */
  if (active) host.appendChild(holoHandoffBar(active));
}

/* ▶ SEND TO ALIGN, and the honest state of it.

   Whether it can fire (`handoffReady`) and the sentence when it cannot
   (`handoffBlocked`) are BOTH the daemon's: the deck must never invent an
   explanation for a refusal it did not make. A SENT program gets no button at
   all — the lock band in the chat pane is the whole account, and a second
   control repeating it would be a second voice. */

/* ── S171: SEND TO ALIGN IS A GATE WITH A WAIT ─────────────────────────────

   THE CAPTAIN'S DESIGN, in his words: *"just leaning more on what the AI pass
   does and making that step a gated wait that retriggers behind a wait guard
   if you keep chatting with the composer."*

   S170 started the derivation when the hand-off DIALOG opened, which had two
   costs he then paid for real: a captain who opened it to look and went back
   to drawing burned a pass, and the wait lived inside a dialog he had to keep
   open to watch. So THIS control is the gate. Four states, and the daemon owns
   every one of them (`p.derive`, published by `_holodeck_meta`):

     state "none"     no change list for this draft, nothing running
                      → ▶ GENERATE THE CHANGE LIST · a click posts `derive`
     state "running"  a pass is in flight
                      → ◐ GENERATING CHANGE LIST… · disabled, with the SAME
                        `.holo-working` bars the chat pane uses
     done, ok         → ▶ SEND TO ALIGN · opens the dialog, list already in it
     done, not ok     the pass did not answer
                      → ▶ SEND TO ALIGN (live — see below) + ↻ try again
     state "off"      the derivation is switched off by configuration
                      → ▶ SEND TO ALIGN, ungated. Gating on a pass that will
                        never run would be a door with no handle.

   NEVER A CLIENT-SIDE GUESS AND NEVER A TIMER. The disabled state is rendered
   because the DAEMON said `running`; nothing here sets a flag or counts down.
   That is FL-009 (`alignBusy`) and FL-017 (FINALIZING's 5-minute fuse) for the
   third time, and the ruling both times was that a bigger constant is the same
   guess with a longer fuse.

   INVALIDATION IS A FACT, NOT A FLAG. `_handoff_derive_fingerprint` covers
   `mockup.html`, so a composer turn that redraws it stops matching the stored
   answer and the daemon peeks back to "none" all by itself. Nothing on this
   side has to notice a turn happened.

   ── S172: THE ESCAPE HATCH IS DELETED, AND THAT IS THE CAPTAIN'S CALL ────

   `Send without the change list` rode on every gated state. His words after
   driving it: *"we don't need the send without change list one."*

   S171 built it as MANDATORY, because gating reverses a property S170 proved
   with an `ast` test. Re-reading the states shows the fear was bigger than the
   risk, and this is the whole argument:

     · a FAILED pass — a dead engine, a timeout, an unreadable reply — already
       leaves ▶ SEND TO ALIGN LIVE, with ↻ try again beside it. The primary
       control IS the road through. An outage never stranded him;
     · `none` is the state before he has asked for anything. The list costs him
       one click and he can send from `failed` if it will not run;
     · so the ONLY state the hatch uniquely covered is `running` — and the
       honest cost of losing it is that a hung pass has to time out (the daemon
       bounds it at 420s and the room keeps the answer).

   AND THE FILING ROADS ARE UNCHANGED. `file_mission`, `park`, `align_start`
   and `_handoff_idea` still never read the derivation — the `ast` test that
   proves it is still green. This gate has always been an affordance on the
   deck, and deleting a second door does not put a lock on the first.

   NO CANCEL CONTROL WAS BUILT IN ITS PLACE, deliberately. Nobody has observed
   a hang. If one is ever seen, the honest control is one that STOPS the pass —
   not one that walks around it — and it should be built then, against a real
   observation, rather than guessed at now. */
function holoDeriveGate(p) {
  var d = p.derive || {};
  var st = d.state || "off";
  if (st === "done") return d.ok ? "ready" : "failed";
  if (st === "running" || st === "none") return st;
  return "off";
}

function holoHandoffBar(p) {
  var bar = el("div", "holo-handoff");
  if (holoLifecycle(p) === "sent") {
    bar.appendChild(el("span", "hl", "⧗ Sent"));
    bar.appendChild(el("span", "hint", p.missionId
      ? "This program was handed over as mission " + p.missionId
        + " and is read-only."
      : "This program was handed over and is read-only."));
    return bar;
  }
  var gate = p.handoffReady ? holoDeriveGate(p) : "off";
  bar.setAttribute("data-gate", gate);
  var d = p.derive || {};
  var n = (d.changes || []).length;
  /* ONE SENTENCE, and it is about the state the bar is IN. The daemon's own
     `why` is quoted for a pass that did not answer — the deck never composes
     a reason for a failure it did not have. */
  var hint = "The mockup and the concept doc go with it — you never have to "
           + "find them.";
  if (!p.handoffReady) {
    hint = p.handoffBlocked || "";
  } else if (gate === "none") {
    hint = "One read-only pass reads your project against the finished mockup "
         + "and writes the list of what is different into your brief. It takes "
         + "a few minutes and you can walk away — it keeps running.";
  } else if (gate === "running") {
    hint = "Reading your project against the mockup. This survives closing the "
         + "deck, a reload and a daemon restart — come back when you like.";
  } else if (gate === "ready") {
    hint = "✓ " + n + " change" + (n === 1 ? "" : "s")
         + " read off your project are in the brief, with the mockup and the "
         + "concept doc. Nothing left to wait for.";
  } else if (gate === "failed") {
    hint = "LCARS could not read your project against the mockup"
         + (d.why ? " — " + d.why : "")
         + ". Nothing is blocked: ▶ Send to Align still works and the brief is "
         + "missing only the change list — or try the pass again.";
  }
  bar.appendChild(el("span", "hint", hint));
  if (gate === "running") {
    bar.appendChild(holoWorkingBars());
    /* AND THE WATCH IS RE-ARMED FROM THE RENDER, not only from the click. He
       may have RELOADED onto a pass that was already running — the daemon owns
       it and the room persists the answer, so the page has to pick the watch
       back up with no click to hang it on. Guarded per session id, because
       renderDeck runs on every refresh. */
    holoDerivePollDeck(p.sessionId);
  }
  bar.appendChild(el("span", "grow"));

  if (gate === "failed") {
    /* ── S172: THE SAME SIZE AS THE CONTROL BESIDE IT ──────────────────────
       From the captain's own screenshot: `SEND WITHOUT THE CHANGE LIST`
       rendered as a small outlined pill against a full-size filled
       `◐ GENERATING CHANGE LIST…` — two different weights of control on one
       row, which reads as two unrelated things rather than one bar. The hatch
       is gone (above), and this is the pairing it leaves behind.

       So both controls in this bar are `big` and they differ by FILL, not by
       size: ▶ Send to Align is `go big` (filled, the thing to do), this one is
       `big` (outlined, the other thing you can do). One family. */
    var again = holoBtn("↻ Try the change list again", "big", function () {
      holoDeriveStart(p.sessionId, true);
    });
    again.setAttribute("data-holo", "handoff-retry");
    bar.appendChild(applyWriteState(again));
  }

  var send;
  if (!p.handoffReady) {
    send = holoBtn("▶ Send to Align", "go big", null,
                   p.handoffBlocked || "There is nothing to hand over yet.");
  } else if (gate === "none") {
    send = holoBtn("▶ Generate the change list", "go big", function () {
      holoDeriveStart(p.sessionId, false);
    });
  } else if (gate === "running") {
    /* DISABLED BECAUSE THE DAEMON SAYS A PASS IS IN FLIGHT — and the reason a
       hover gives is the same fact, not an apology. */
    send = holoBtn("◐ Generating change list…", "go big", null,
                   "A read-only pass is reading your project against the "
                   + "mockup. It is the daemon's, not this page's: closing "
                   + "the deck does not stop it.");
  } else {
    send = holoBtn("▶ Send to Align", "go big", function () {
      holoPromote(p.sessionId);
    });
  }
  send.setAttribute("data-holo", "handoff-send");
  send.setAttribute("data-gate", gate);
  bar.appendChild(applyWriteState(send));
  return bar;
}

/* The SAME four bars the chat pane and the New Program dialog use — one
   working idiom in this feature, not three. */
function holoWorkingBars() {
  var w = el("span", "holo-bars");
  w.setAttribute("role", "status");
  w.setAttribute("aria-live", "polite");
  var bars = el("span", "bars");
  for (var i = 0; i < 4; i++) bars.appendChild(el("i"));
  w.appendChild(bars);
  return w;
}

/* Start the pass, then let the DAEMON drive what the button says.

   The response is the same `derive` block the deck payload carries, so the
   bar is repainted from the daemon's answer to this very request — never from
   an assumption that posting means running. `holoRefresh` then keeps asking
   while it is in flight; the poll is a poll and not a stream for `promote`'s
   own reason (S170), and its stop condition is the daemon saying it stopped. */
var HOLO_DERIVE_POLL_MS = 4000;

function holoDeriveStart(sid, force) {
  if (!sid) return;
  postWrite("/api/holodeck/" + sid + "/derive", force ? { force: true } : {},
    function (state) {
      var prog = null;
      for (var i = 0; i < HOLO.programs.length; i++) {
        if (HOLO.programs[i].sessionId === sid) prog = HOLO.programs[i];
      }
      if (prog) prog.derive = state.derive || prog.derive;
      renderDeck();
      holoDerivePollDeck(sid);
    }, function (msg) {
      holoSetBanner("offline", { message: msg });
      renderDeck();
    });
}

/* Ask the daemon again while the pass is in flight, and STOP the moment it is
   not. `holoRefresh` re-reads every program (the derivation state included),
   so this adds no second source of truth — it only decides how often to look
   while there is something to look at. */
function holoDerivePollDeck(sid) {
  if (!sid || HOLO.derivePolls[sid]) return;
  HOLO.derivePolls[sid] = true;
  setTimeout(function () {
    HOLO.derivePolls[sid] = false;
    var live = null;
    for (var i = 0; i < HOLO.programs.length; i++) {
      if (HOLO.programs[i].sessionId === sid) live = HOLO.programs[i];
    }
    if (!live || ((live.derive || {}).state !== "running")) return;
    holoRefresh();
  }, HOLO_DERIVE_POLL_MS);
}

function holoVisiblePrograms() {
  if (HOLO.filter === "all") return HOLO.programs.slice();
  return HOLO.programs.filter(function (p) {
    return holoLifecycle(p) === HOLO.filter;
  });
}

function holoProgramsPane() {
  var pane = el("div", "programs");
  var head = el("div", "ph");
  head.appendChild(el("span", "dot"));
  head.appendChild(el("span", null, "Programs"));
  pane.appendChild(head);

  // D11's chips. Counts come from the REAL list, over the real lifecycle S127
  // landed: DRAFT and SENT move as programs are handed over. DONE still reads 0
  // for every program, because nothing yet reads back whether a mission MERGED
  // — an honest zero for a state that exists and is not wired.
  var chips = el("div", "pfilter");
  HOLO_FILTERS.forEach(function (f) {
    var key = f[0];
    var n = key === "all" ? HOLO.programs.length
      : HOLO.programs.filter(function (p) {
          return holoLifecycle(p) === key;
        }).length;
    var chip = el("span", "fchip" + (HOLO.filter === key ? " on" : ""),
                  f[1] + " " + n);
    keyActivable(holoCtl(chip, f[1], function () {
      HOLO.filter = key;
      renderDeck();
    }));
    chips.appendChild(chip);
  });
  pane.appendChild(chips);

  var list = el("div", "plist");
  var shown = holoVisiblePrograms();
  if (!shown.length) {
    list.appendChild(el("div", "pnone", HOLO.programs.length
      ? "No " + HOLO.filter + " programs."
      : "No programs yet. Nothing has been run on this deck."));
  }
  shown.forEach(function (p) {
    /* S126 — TWO KINDS OF CARD. A live conversation, and a room read off disk
       that this daemon has never held. They are marked apart because they
       behave apart: clicking the first switches the chat to it, clicking the
       second asks the daemon to pick it back up (a WARM RESTART — a fresh
       worker handed the transcript, never a resumed session). */
    var onDisk = !p.sessionId;
    var row = el("div", "prog" + (p.sessionId && p.sessionId === HOLO.activeId
                                  ? " on" : "") + (onDisk ? " ondisk" : ""));
    row.appendChild(el("div", "pn", p.program || "Untitled program"));
    var meta = el("div", "pm");
    meta.appendChild(el("span", null, "⬡ " + (p.turnCount || 0) + " turn"
      + ((p.turnCount === 1) ? "" : "s")));
    // D8 — recency is the answer to "which one was that", so it says WHAT the
    // time refers to. "2 days ago" alone could be when it was opened, listed,
    // or committed; design work is picked up days later and the question is
    // always when it was last WORKED ON.
    meta.appendChild(el("span", null, "last worked " + holoWhen(p.lastTouched)));
    // THE ROOM, so two cards that READ the same are still legible (round 2).
    // The daemon's collision check refuses names that normalize alike, but it
    // does not hunt homoglyphs — "sidebаr" with a Cyrillic а is a name a
    // captain may honestly have typed, and refusing it is worse than showing
    // which room it landed in. The room is the discriminator.
    if (p.room || p.programDir) {
      meta.appendChild(el("span", "proom", "⌂ " + (p.room
                                                   || holoBase(p.programDir))));
    }
    row.appendChild(meta);
    var prow = el("div", "prow");
    var life = holoLifecycle(p);
    prow.appendChild(el("span", "pstat" + (life === "sent" ? " sent" : ""),
                        life));
    // S127 (D11) — a SENT program carries its mission number on the card. The
    // program list is where a captain asks "what happened to that one", and
    // the honest answer is a mission id he can find on the board.
    if (life === "sent" && p.missionId) {
      prow.appendChild(el("span", "pmission", "▦ " + p.missionId));
    }
    /* S172 — WHERE A DUPLICATE CAME FROM, on the card. "Which one was that"
       is the question the program list exists to answer, and a duplicate's
       whole point is that it continues an earlier design — so the lineage the
       daemon records has to be visible where a captain is choosing between
       two cards that look alike. The mission the parent was filed as is in the
       title rather than on the face: it is the parent's number, not this
       program's, and printing it beside a `draft` chip would read as this
       one's. */
    if (p.duplicatedFrom && p.duplicatedFrom.room) {
      var dup = el("span", "pdup", "⧉ from " + (p.duplicatedFrom.program
                                                || p.duplicatedFrom.room));
      dup.title = "Duplicated from " + p.duplicatedFrom.room
        + (p.duplicatedFrom.missionId
           ? ", which was filed as mission " + p.duplicatedFrom.missionId : "");
      prow.appendChild(dup);
    }
    if (onDisk) {
      // Said on the card, not only in a class: this program is in the archive
      // and nothing is talking to it right now.
      prow.appendChild(el("span", "pdisk", "⌾ in the archive"));
    }
    prow.appendChild(el("span", "grow"));
    /* S172 — ⧉ DUPLICATE, on EVERY card INCLUDING A LOCKED ONE. That is the
       state it exists for: a sent program is read-only for ever (the daemon
       409s every turn on it, because it is the exact design a mission was
       briefed on), and duplicating it is the only way to keep designing from a
       design that already shipped. Rendering it on drafts only would hide the
       control in precisely the case it was built for. */
    prow.appendChild(applyWriteState(holoBtn("⧉ Duplicate", "small",
                                             function () {
      holoConfirmDuplicate(p);
    })));
    /* DELETE IS A GIT OPERATION, and the confirmation says so. The room is
       `git rm`'d and committed, so the honest word for this is "removed from
       the deck", not "deleted forever". */
    prow.appendChild(applyWriteState(holoBtn("⌫ Delete", "small", function () {
      holoConfirmDelete(p);
    })));
    row.appendChild(prow);
    keyActivable(holoCtl(row, p.program || "program", function () {
      if (onDisk) {
        holoOpen(p.room || holoBase(p.programDir),
                 p.engineRecorded ? p.engine : null);
        return;
      }
      HOLO.activeId = p.sessionId;
      HOLO.banner = null;
      renderDeck();
    }));
    list.appendChild(row);
  });
  pane.appendChild(list);

  var foot = el("div", "pfoot");
  var add = holoBtn("＋ New Program", "go", openNewProgram);
  add.style.width = "100%";
  foot.appendChild(applyWriteState(add));
  // D6: after the empty state named it once, the sidecar is a name and a
  // commit count. Knowing where your archive lives is knowing; being told the
  // path on every screen is plumbing.
  var chip = el("div", "sidecar-chip");
  if (HOLO.sidecarName) {
    chip.appendChild(document.createTextNode("⬡ "));
    chip.appendChild(el("b", null, HOLO.sidecarName));
    chip.appendChild(document.createTextNode(
      " · " + HOLO.commits + " commit" + (HOLO.commits === 1 ? "" : "s")
      + " · local only"));
  } else {
    chip.textContent = "Design files live in a separate repo beside this one — "
      + "never inside your project.";
  }
  foot.appendChild(chip);
  pane.appendChild(foot);
  return pane;
}

/* D6 + mock screen 2 — the first thing a captain ever sees on the deck. It says
   where the files will live BEFORE it asks for anything, because a tool that
   hides where your work goes is a tool you cannot back up. This is the ONE
   place a path is shown. */
function holoEmptyDeck() {
  var e = el("div", "holo-empty");
  /* FIX ROUND 2 — THE MORNING STATE. This pane is shown in TWO situations, and
     until now it said the same thing in both. The second is the one a captain
     is in every morning: yesterday's programs are in the list on the left,
     nothing is selected (correctly — the auto-select deliberately picks up only
     a LIVE program, because handing him an archived one means a composer that
     404s), and the whole main area said "PROGRAM STANDING BY / Describe a
     screen…" over one prominent ＋ NEW PROGRAM. Nothing pointed at the list,
     and the one button was the wrong move: under the same name it lands in the
     room-reuse disclosure, under a different one his work is in two places.
     The GUARD is right; this was the copy. */
  var waiting = (HOLO.programs || []).length;
  /* Q3 (S128) — the SOLO deck has no chat header to hang the drawer control on,
     and this is the state in which the list is most wanted: the copy below
     points straight at it ("your programs are in the list on the left"), which
     is a lie on a narrow window unless something can open it. */
  e.appendChild(holoDrawerToggle());
  e.appendChild(el("div", "arch", "Holodeck"));
  e.appendChild(el("div", "sub", waiting ? "Pick a program back up"
                                         : "Program standing by"));
  if (waiting) {
    e.appendChild(el("p", null,
      "Your programs are in the list on the left — click one to carry on with "
      + "it. Nothing was lost when the deck was closed: each program's room "
      + "still holds its mockup, the whole conversation, and its concept doc."));
    e.appendChild(el("p", "quiet",
      "＋ New Program starts a separate one. Under the same name it carries on "
      + "in that program's room; under a different name you have the same "
      + "design in two places."));
  } else {
    e.appendChild(el("p", null,
      "Describe a screen, a component, or a whole flow and I will build it as a "
      + "live mockup you can look at. We iterate here — cheaply, no missions, no "
      + "branches — until it looks right."));
  }
  e.appendChild(applyWriteState(holoBtn("＋ New Program", "go big",
                                        openNewProgram)));
  var where = el("div", "where");
  where.appendChild(document.createTextNode("Files land in "));
  // D6 wants the PATH, not the name. The reason for naming the sidecar at all
  // is that this archive is the captain's, it outlives the mission, and he must
  // be able to back it up — and you cannot back up a basename. The daemon sends
  // the `~`-folded form (only it knows $HOME); the name is the last resort, for
  // a deck rendered before the first list call has answered.
  where.appendChild(el("b", null, HOLO.sidecarDisplay || HOLO.sidecarName
    || (holoRepoName() + "-holodeck")));
  where.appendChild(document.createTextNode(
    " — a separate repo beside this one, never inside your project. "
    + "It is local git, pushed only if you ask."));
  e.appendChild(where);
  return e;
}

function holoRepoName() {
  var meta = LAST_BOARD && LAST_BOARD.meta;
  var repo = (meta && (meta.repo || meta.repoName)) || "";
  repo = String(repo);
  var i = repo.lastIndexOf("/");
  return (i === -1 ? repo : repo.slice(i + 1)) || "this project";
}

/* D12 — "the program header links to it". `basis.md` is what makes a grounding
   CORRECTABLE, and a grounding you cannot read is one you cannot correct.

   ONE BUILDER, TWO PLACEMENTS (S127 FL-003). The file is now reachable from the
   chat header chip AND from the empty preview, because the two are needed at
   different moments: the empty preview is the pane a captain is actually
   staring at the instant a grounding pass lands, and the chip is the only route
   left once a mockup exists and that empty state is gone. What must NOT be
   duplicated is the MECHANISM — S125 lost two rounds to a second control
   carrying its own URL and its own wording. Both call this one function, so
   they cannot disagree about where the file is, whether it is there, or what to
   say when it is not: `basisFile` is the daemon saying the file really exists,
   so the link can never 404, and without it the control stays visibly off with
   the reason rather than pointing into thin air. */
/* S172 — AND WHOSE GROUNDING IT IS. On a DUPLICATE the basis came over with the
   copy: it is what LCARS read for the ORIGINAL program, not a fresh look at
   this project. By the time a captain duplicates a design its mission has
   usually landed, so the app has MOVED and the basis describes what it used to
   be. `basisInherited` is the daemon's own answer and `basisNotice` is its own
   sentence for why — this side adds not one word, it only stops asserting the
   grounding is this project's current one. */
function holoBasisNode(p, label, cls) {
  if (p.basisFile) {
    var link = el("a", cls, label);
    link.setAttribute("href", holoPreviewPath(p, p.basisFile));
    link.setAttribute("target", "_blank");
    link.setAttribute("rel", "noopener noreferrer");
    link.title = p.basisInherited ? p.basisNotice
      : "read basis.md — what the holodeck found in " + holoRepoName();
    link.setAttribute("data-ctl", label);
    link.setAttribute("data-wired", "1");
    return link;
  }
  return holoCtl(el("span", cls, label), label, null,
    "The grounding pass has not written basis.md yet — there is nothing "
    + "to read until it does.");
}

/* ── the chat pane ─────────────────────────────────────────────────────── */
function holoChatPane(p) {
  var pane = el("div", "holo-chat");
  var head = el("div", "chat-head");
  /* Q3 (S128) — the drawer control, FIRST in the header where a ☰ is looked
     for. Rendered at every width; the stylesheet hides it above the breakpoint,
     where the list is a column already on screen. */
  head.appendChild(holoDrawerToggle());
  head.appendChild(el("div", "ct", p.program || "Program"));
  if (p.grounded || p.mode === "grounding") {
    /* S172 — the chip must not keep saying "grounded in <repo>" over a basis
       that came over with a duplicate. The words carry the fact, not a class:
       a new class needs a stylesheet rule to reach the screen, and text always
       does. */
    head.appendChild(holoBasisNode(
      p,
      p.basisInherited ? "▣ inherited grounding — may be stale"
        : "▣ grounded in " + holoRepoName(),
      "ground-chip"));
  }
  /* FIX ROUND 1 (D7) — AND WHOSE CONVERSATION IS IN THIS PANE. A duplicate
     opens with the PARENT'S whole chat replayed into it, and the only thing
     that ever said so was the banner — which is transient. One refresh later
     the header named this program, the turns below it were somebody else's,
     and nothing on the screen joined the two up; the card's ⧉ from chip is in
     the other pane and gone the moment the drawer shuts. The header is where a
     captain looks to know WHAT HE IS READING, so the fact lives here too. It
     states the lineage and nothing more — that the history is not binding is
     the worker's instruction and the banner's sentence, and repeating it here
     would be the second voice this deck keeps having to remove. */
  if (p.duplicatedFrom && p.duplicatedFrom.room) {
    var cont = el("span", "cont-chip",
                  "⧉ continuing " + (p.duplicatedFrom.program
                                     || p.duplicatedFrom.room));
    cont.title = "The conversation below came over from " + p.duplicatedFrom.room
      + (p.duplicatedFrom.missionId
         ? ", which was filed as mission " + p.duplicatedFrom.missionId : "")
      + ". This is a new program — nothing in that history is binding, and the "
      + "one it came from is untouched.";
    head.appendChild(cont);
  }
  head.appendChild(el("span", "grow"));
  /* FIX ROUND 2 — "WARM" IS A FACT THE DAEMON MEASURES, NOT A DECORATION.
     On a program picked back up this pill read `WARM · CLAUDE` two inches
     under the banner saying the conversation that built it is over and the
     worker answering the next turn is a fresh one — "warm" being the exact
     word for the thing that did not survive. It is equally untrue on a program
     that has not spoken yet: a design program spends nothing until the first
     turn, which is what OPENS the warm session.

     `warm` is `sess.started` — the daemon's own answer to "is there a session
     to resume", the same evidence S125's N4 cure is keyed off. The pill states
     it rather than asserting it, and never goes silent about the engine. */
  var warm = !!p.warm;
  var pill = el("span", "pill", (warm ? "WARM · " : "FRESH · ")
               + holoEngineName(p));
  /* ONE VOICE (fix round 3). The FRESH tooltip used to go on to say the next
     turn is "handed this program's transcript as context" — the restart
     banner's own claim, restated two inches below it in different words, and
     the only second voice left on the deck. It is DELETED rather than
     rephrased: the tooltip's job is the PILL's fact — whether a worker session
     is open — and the banner is the whole account of the restart. */
  pill.title = (warm
    ? ("The worker session is open, so a follow-up turn resumes it — LCARS "
       + "re-sends nothing.")
    : "No worker session is open yet. Your next turn starts one.")
    /* FIX ROUND 5 — WHERE THE ENGINE IN THE PILL CAME FROM. The pill has
       always named what will ANSWER, and that stays. What it could not say is
       whether that is the program's own history or merely what this
       viewscreen happens to be running — and on a live drive those were
       different engines, with the wrong one reading as the answer. Every
       program built before round 5 has no engine in its record, so it is told
       exactly that rather than handed an invention. */
    + (p.engineRecorded
       ? (" It is the engine this program was designed on.")
       : (" This program's record does not say which engine it was designed "
          + "on, so it runs on this viewscreen's default."));
  head.appendChild(pill);
  head.appendChild(applyWriteState(holoBtn("⌫ End Program", null, function () {
    holoEnd(p.sessionId);
  })));
  pane.appendChild(head);

  var tr = el("div", "transcript");
  (p.turns || []).forEach(function (t) {
    if (t.text) {
      var you = el("div", "turn you");
      you.appendChild(el("div", "who", "You"));
      you.appendChild(el("div", "body", t.text));
      /* S169 FIX ROUND 1 — AND WHAT HE ATTACHED TO IT. Measured on the
         2026-08-06 drive: he pasted a sketch, said "this sketch is the look I
         want", and after a reload the reopened chat showed no chip at all —
         his own line pointing at nothing. The names come from the DAEMON's
         turn list (`_turns_payload`), which is read back out of
         `transcript.md` on a reopen, so this survives a refresh, a reload and
         a program picked up weeks later. The chip shape is the composer's own
         (`.img-chips`/`.img-chip`), not a second one. */
      var att = t.attachments || [];
      if (att.length) {
        var chips = el("div", "img-chips");
        att.forEach(function (n) {
          var chip = el("span", "img-chip");
          chip.appendChild(el("span", "img-chip-name", "◫ " + holoBase(n)));
          chips.appendChild(chip);
        });
        you.appendChild(chips);
      }
      tr.appendChild(you);
    }
    if (t.reply) {
      var h = el("div", "turn holo");
      h.appendChild(el("div", "who", "Holodeck"));
      h.appendChild(holoReplyNode(t.reply));
      var files = (t.filesChanged || []).map(function (c) {
        return typeof c === "string" ? c : c.path;
      });
      if (files.length) {
        var did = el("div", "did");
        files.forEach(function (f) {
          var name = holoBase(f);
          did.appendChild(el("span", "chip-file"
            + (/\.md$/i.test(name) ? " doc" : ""), name));
        });
        h.appendChild(did);
      }
      /* S126 — THE CONCEPT-DOC AUDIT, ON THE TURN IT IS ABOUT. The daemon
         checks that a turn which moved the mockup left a `concept.md` behind,
         and only the failure is shown: a check that speaks on every turn is a
         check people stop reading. It is a NOTE beside the turn, not a modal
         banner — nothing is broken and nothing was lost, there is simply
         nothing written down yet for the hand-off to carry. The words are the
         daemon's (the one-voice rule). */
      if (t.conceptAudit && t.conceptAudit.status === "missing") {
        var cn = el("div", "holo-concept");
        cn.appendChild(el("span", "cl", "▤ No concept doc"));
        cn.appendChild(el("span", "ct3", t.conceptAudit.message || ""));
        h.appendChild(cn);
      }
      /* S169 (FL-015) — WHAT THE TURN DID, on the turn it is about. The
         captain asked a question, the holodeck answered it AND rebuilt part of
         the mockup, and nothing on this screen said so — the file chips above
         name what changed, but a turn that changed NOTHING said nothing at
         all, so "it answered and left the design alone" and "it answered and
         quietly redesigned the events tab" looked identical until he opened
         the preview.

         The daemon reads both halves off the audit it already runs and writes
         the sentence (`_turn_outcome`); this renders it and invents nothing.
         It is deliberately quiet on an ordinary build turn that wrote — the
         chips above already say that, and a note that speaks every turn stops
         being read. `.no` when nothing was written, `.drift` when a turn he
         DECLARED a question wrote anyway, which is the defect itself. */
      var oc = t.turnOutcome;
      if (oc && oc.message) {
        var on = el("div", "holo-outcome" + (oc.wrote ? " drift" : " no"));
        on.appendChild(el("span", "cl",
          oc.wrote ? "◆ Changed on a question" : "◇ Nothing written"));
        on.appendChild(el("span", "ct3", oc.message));
        h.appendChild(on);
      }
      tr.appendChild(h);
    }
  });
  if (!(p.turns || []).length) {
    tr.appendChild(el("div", "pnone",
      "Say what you want to see. The first turn opens the conversation."));
  }
  /* S128 (FL-002) — WHO SAYS A TURN IS RUNNING. `HOLO.busy` is this tab's
     memory of its own send and nothing else: a reload, a second tab, or a
     return from the board has none of it, so a deck that re-rendered mid-turn
     read exactly like an idle one — while the daemon would correctly refuse
     the next `/say`. `p.busy` is the daemon's own fact and is the only one
     that survives the client that started the turn.

     The daemon's wins when both are true, because it is the one that knows
     WHEN the turn started; this tab does not, and the whole complaint was that
     nothing said how long it had been going. */
  var deckBusy = !!(p && p.busy);
  var working = deckBusy || HOLO.busy;
  if (working) {
    tr.appendChild(holoWorkingNode(deckBusy ? p.busyLabel : null));
  }
  pane.appendChild(tr);
  // THE DECK IS THE VIEWPORT (fix round 1). The transcript is the ONE thing on
  // the deck that grows, so it is the one thing that scrolls — and it must land
  // on the newest turn, or a long conversation re-opens showing its own opening
  // line. Deferred to the next frame because the node has no height until it is
  // in the document.
  if (typeof setTimeout === "function") {
    setTimeout(function () { tr.scrollTop = tr.scrollHeight; }, 0);
  }

  /* S127 (D11) — A SENT PROGRAM HAS NO COMPOSER. The band REPLACES it rather
     than greying it out, on the mock's reasoning: a disabled input invites
     "why can't I type here?", and a band that says what happened, when, and
     which mission holds it answers that before it is asked.

     Why locked at all: the mission received a SNAPSHOT of these exact files.
     If the mockup keeps moving afterwards, the design on screen and the brief
     the workers are building to disagree silently — and the disagreement
     surfaces at Verify as "this doesn't match", with no way to tell which side
     moved. */
  if (holoLifecycle(p) === "sent") {
    var lock = el("div", "holo-lock");
    var lh = el("div", "lh");
    lh.appendChild(el("span", "li", "⧗"));
    lh.appendChild(el("span", "lt", "Sent to Align"
      + (p.missionId ? " · mission " + p.missionId : "")));
    lock.appendChild(lh);
    lock.appendChild(el("p", null,
      "This program is read-only now. The mission was briefed on the mockup "
      + "and the concept doc exactly as they were when you sent them, so "
      + "changing them here would leave it building to something you can no "
      + "longer see. Everything is still readable — the transcript above, the "
      + "mockup in the preview, and the whole room in your archive."));
    /* S172 FIX ROUND 3 — AND THE WAY ON, NAMED IN THE SAME BREATH. This
       paragraph used to stop at "read-only", under a hatch that apologised for
       not existing. The captain is standing in this room when he discovers the
       lock, so this is where the road out has to be said — in the same words
       the daemon's own refusal uses, so the sentence he gets from the composer
       and the sentence he reads here are one story. */
    lock.appendChild(el("p", null,
      "⧉ Duplicate is the way on: it opens a NEW program carrying this one's "
      + "mockup, concept doc and whole conversation, editable from the first "
      + "turn — and this one stays exactly as it was handed over."));
    /* THE ESCAPE HATCH, LIVE. Wanting to carry on after sending is normal —
       but it is a NEW design, and the mission in flight was briefed on the old
       one, so it goes into a room of its own. S127 shipped this DISABLED with
       the truth that the session had not built it; S172 built it and rewrote
       the daemon's refusal to point at it, and left this greyed out — so the
       one room a captain is standing in when he hits the lock went on saying
       the thing he had just been told exists does not. It is THE CARD'S OWN
       ROAD, called here: one confirmation, one POST, one mechanism. */
    lock.appendChild(applyWriteState(holoBtn(
      "⧉ Duplicate to keep designing", "small", function () {
        holoConfirmDuplicate(p);
      })));
    pane.appendChild(lock);
    return pane;
  }

  // the composer. Enter sends, Shift+Enter is a newline — the mock's contract,
  // and the one every chat surface a captain has ever used shares.
  var comp = el("div", "composer");
  var ta = el("textarea");
  ta.placeholder = "Describe what you want to see…";
  ta.rows = 3;
  ta.setAttribute("data-holo", "composer");
  comp.appendChild(ta);
  /* S169 (FL-013) — THE UNSENT TURN, PUT BACK. This pane is rebuilt from
     scratch on every render, so the value has to be restored from HOLO here
     and recorded on every keystroke below. Nothing else about the composer
     changes: it is the same textarea, with what he had already typed in it. */
  var draft = holoDraftFor(p.sessionId);
  ta.value = draft.text || "";
  ta.addEventListener("input", function () {
    holoDraftPut(p.sessionId).text = ta.value;
  });
  /* S169 (FL-014) — AND IT TAKES A PASTED IMAGE. Designing a mockup FROM a
     reference screenshot is the archetypal thing to ask this room for, and it
     was the one design surface on the board that could not take one: the
     daemon has had an honest refusal for the case since S124, but with no
     paste handler here the clipboard event was never harvested, nothing was
     ever sent, and that sentence could never fire. A pasted image did
     NOTHING, in silence — the exact thing this file's own header forbids.
     Same paster as the File and Log boxes (S91), with the list kept in the
     draft so a re-render does not eat it either. */
  var cerr = el("div", "errline"); cerr.hidden = true;
  comp.appendChild(cerr);
  var compImgs = attachImagePaster(ta, function (msg) { showErr(cerr, msg); }, {
    get: function () { return holoDraftFor(p.sessionId).images; },
    set: function (list) { holoDraftPut(p.sessionId).images = list; },
  });
  var row = el("div", "crow");
  /* S169 (FL-015) — THE OPTIONAL DECLARATION. See `holoIntentToggle`. */
  var intentSel = holoIntentToggle(p.sessionId, function () { paintSend(); });
  row.appendChild(intentSel);
  row.appendChild(el("span", "hint", "⏎ send · ⇧⏎ newline · paste a screenshot"));
  row.appendChild(el("span", "grow"));
  var send = holoBtn("Send ▸", "go", function () {
    holoSay(p.sessionId, ta.value, compImgs.payload(),
            holoDraftFor(p.sessionId).intent);
  });
  /* The control has to SHOW it took, or it is a switch he flips and then
     wonders about. The verb on the button is the whole feedback: Ask ▸ /
     Send ▸, off the same draft field the POST reads, so the button and the
     request can never disagree about what this turn is. */
  function paintSend() {
    if (send.disabled) return;
    send.textContent =
      holoDraftFor(p.sessionId).intent === "ask" ? "Ask ▸" : "Send ▸";
  }
  paintSend();
  if (working) {
    send.disabled = true;
    /* S169 (FL-015) — "Working…", not "Rendering…". A turn in flight is a turn
       in flight; whether it is rendering anything is not known until it has
       written something, and the captain met this control asserting a render
       over a turn he had only asked a question on. Same word as the strip
       above it, for the same reason. */
    send.textContent = "Working…";
    /* AND WHY — in the daemon's words, on the same discipline the hand-off bar
       already follows (`handoffBlocked`). A composer that is locked with no
       explanation is exactly the state the captain came back to; an
       explanation this side invented would be a second voice about a refusal
       it did not make. `data-reason` is the board's own idiom for a control
       that is disabled WITH the reason. */
    if (deckBusy && p.busyReason) {
      send.title = p.busyReason;
      send.setAttribute("aria-disabled", "true");
      send.setAttribute("data-reason", p.busyReason);
    }
  }
  ta.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey && !e.ctrlKey && !e.metaKey) {
      e.preventDefault();
      if (!send.disabled) holoSay(p.sessionId, ta.value, compImgs.payload(),
                                  holoDraftFor(p.sessionId).intent);
    }
  });
  row.appendChild(applyWriteState(send));
  comp.appendChild(row);
  pane.appendChild(comp);
  return pane;
}

/* S169 (FL-015) — ASK vs BUILD, DECLARED ON THE COMPOSER.

   The captain asked the holodeck what it meant by the events tab; it answered
   him and then spent a long turn rebuilding part of the mockup he had not asked
   it to touch. His bar, in his words: *"Would be better to answer and let me
   guide then waste time on a render update."*

   THE OBVIOUS CURE IS THE TRAP, so it is not here: nothing in this product
   looks at his sentence and decides whether it is a question. S156's classifier
   fell from 14/14 to 5/14 the moment a tester reworded its own corpus without
   changing a meaning, and the cure was deleting the signals and moving the
   decision to a DECLARATION. He phrases things however he phrases them.

   So there are two declarations and no guesses, and they compose:
     • the DEFAULT one is in the turn prompt — the worker is told answer-then-
       stop is the right move on a turn that is not a direction, and the worker
       is the only reader that has his actual sentence;
     • THIS one is his, explicit, and a rewording cannot defeat it.

   IT IS OPTIONAL BY CONSTRUCTION and must stay that way. He never has to flip
   it to ask a question — the prompt already covers him — so it can never become
   the switch he forgot and blamed. It is also PER-TURN, not a mode: the draft
   (and with it this field) is cleared when the turn is sent, so ASK never leaks
   into the next thing he types.

   The state lives in `HOLO.drafts[sid].intent` — the object Wave 2 built for
   the unsent turn's text and images — because what he typed, what he pasted and
   what shape the turn is are one thing, and a fourth store beside them is the
   two-mechanism trap this round has lost rounds to. */
function holoIntentToggle(sid, onchange) {
  var wrap = el("div", "holo-intent");
  wrap.setAttribute("role", "group");
  wrap.setAttribute("aria-label", "Is this turn a direction or a question?");
  var opts = [["build", "◈ Build", "Direct a change — the holodeck builds it."],
              ["ask", "? Ask", "Ask a question — the holodeck answers and "
               + "changes nothing: no mockup edit, no concept.md edit."]];
  var btns = [];
  function paint() {
    var cur = holoDraftFor(sid).intent === "ask" ? "ask" : "build";
    btns.forEach(function (b) {
      var on = b.getAttribute("data-holo-intent") === cur;
      if (on) b.classList.add("on"); else b.classList.remove("on");
      b.setAttribute("aria-pressed", on ? "true" : "false");
    });
  }
  opts.forEach(function (o) {
    var b = keyActivable(el("span", "iopt", o[1]));
    b.setAttribute("data-holo-intent", o[0]);
    b.title = o[2];
    b.addEventListener("click", function () {
      holoDraftPut(sid).intent = o[0];
      paint();
      if (onchange) onchange();
    });
    btns.push(b);
    wrap.appendChild(b);
  });
  paint();
  return wrap;
}

/* ── rendering a reply (mock screen 4 is CLEAN PROSE) ──────────────────────
   The chat was printing the engine's markdown SOURCE (`# heading`, `**bold**`,
   `| pipe | tables |`) and its TOOL TRACE (`● List directory .`, `└ 3 files
   found`, `● Create mockup.html +68`) — engine internals leaking into a design
   conversation.

   THE ONE RULE THIS MUST NOT BREAK: a reply is text a LANGUAGE MODEL WROTE, and
   it is going into the board's own DOM. Everything below builds NODES and sets
   `textContent`; nothing here touches `innerHTML`, so making it legible cannot
   have made it an injection channel. (Tested: `replyInnerHtmlCalls` must be 0
   and `<img src=x onerror=…>` must render as the literal characters.) */

/* ── engine activity: COLLAPSED, NEVER DELETED (fix round 2) ───────────────
   Round 1 FILTERED lines out, and the filter was the defect — not the pattern
   in it. `/^\s*[└⎿├│]/` deleted any line opening with a box-drawing glyph, so a
   captain who sketched a rail layout in chat got back `┌────────────┐` alone:
   the `│ SWATCHES │` body and the closing `└────┘` were destroyed with nothing
   on screen to say so. A third, cleverer regex would be beaten too, because
   ASCII diagrams and `●`-bulleted design notes are among the most likely things
   to be said IN A DESIGN CONVERSATION.

   So the mechanism is gone. Recognized activity is folded into a muted,
   expandable row; everything else is prose; and the two together are always the
   WHOLE reply, line for line. A misclassification now costs a cosmetic oddity
   the captain can open, and CANNOT remove a character of what he was shown.

   The recognizer stays conservative on top of that: a trace line is a glyph, a
   tool VERB, and an ARGUMENT-shaped tail — a path, a `.ext`, a `+68`, a
   parenthesised call, or nothing. "● Update the radius only if the swatches
   move" is a sentence, and stays prose. A continuation glyph is trace only
   while a recognized run is open; standing alone it is somebody drawing a box.

   The one rule none of this may break: model text still never reaches
   `innerHTML` — every line below becomes a TEXT NODE. */
/* FIX ROUND 5 — `✗` joins the glyph class. Copilot prints a FAILED tool block
   with that head (`✗ Edit mockup.html` / `  └ Multiple matches found`, captured
   at `web/tests/fixtures/s126-live/copilot-failed-edit-reply.txt`), and it was
   rendering in the middle of the conversation as a design decision. The tail
   test is UNCHANGED, so `✗ Delete the old rail it never shipped` is still a
   sentence — and the chat folds rather than deletes either way. */
var HOLO_TOOL_LINE = /^\s*[●⏺◆✗]\s*(list directory|read|create|update|edit|write|search|grep|glob|view|bash|fetch|task|delete|move|copy|thinking)\b(.*)$/i;
var HOLO_TRACE_CONT = /^\s*[└⎿├│]/;

/* Does the tail of a `● Verb …` line look like a tool ARGUMENT rather than a
   sentence? Anything unsure answers false — a trace line shown as prose costs
   nothing, and this is the only judgement call left in the recognizer. */
function holoArgish(tail) {
  tail = String(tail == null ? "" : tail).trim();
  if (!tail) return true;
  if (/[(`"']/.test(tail)) return true;
  var toks = tail.split(/\s+/);
  for (var i = 0; i < toks.length; i++) {
    var t = toks[i];
    if (t === "." || t === ".." || /[\/\\]/.test(t)
        || /\.[A-Za-z0-9]+$/.test(t) || /^[+-]\d+$/.test(t)) return true;
  }
  return false;
}

function holoIsToolLine(ln) {
  var m = HOLO_TOOL_LINE.exec(ln);
  return !!m && holoArgish(m[2]);
}

/* [{trace, lines}] — EVERY line of the reply, in order, exactly once. This is
   the guarantee: concatenating the segments' lines reproduces the reply. */
function holoSegments(text) {
  var lines = String(text == null ? "" : text).replace(/\r\n/g, "\n").split("\n");
  var segs = [];
  var run = false;
  for (var i = 0; i < lines.length; i++) {
    var ln = lines[i];
    var trace;
    if (holoIsToolLine(ln)) { trace = true; run = true; }
    else if (run && HOLO_TRACE_CONT.test(ln)) { trace = true; }
    else { trace = false; run = false; }
    var last = segs[segs.length - 1];
    if (last && last.trace === trace) last.lines.push(ln);
    else segs.push({ trace: trace, lines: [ln] });
  }
  return segs;
}

/* One recognized run, folded away. Muted, one line, and it OPENS — the text is
   in the DOM the whole time, so a wrong guess is recoverable by clicking. */
function holoTraceNode(lines) {
  var wrap = el("div", "holo-trace");
  var n = lines.filter(function (l) { return l.trim(); }).length;
  var pre = el("pre", "tl", lines.join("\n"));
  pre.hidden = true;
  var sum = el("span", "ts", "");
  function paint() {
    sum.textContent = "⚙ tool activity · " + n + " line" + (n === 1 ? "" : "s")
      + " · " + (pre.hidden ? "show" : "hide");
    sum.setAttribute("aria-expanded", pre.hidden ? "false" : "true");
  }
  paint();
  keyActivable(holoCtl(sum, "tool activity", function () {
    pre.hidden = !pre.hidden;
    paint();
  }));
  wrap.appendChild(sum);
  wrap.appendChild(pre);
  return wrap;
}

/* Inline marks, applied as TEXT NODES: **bold**, *italic*, `code`. Anything it
   does not understand stays exactly as the model typed it. */
function holoInline(host, text) {
  var re = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*\s][^*]*\*)/g;
  var last = 0, m;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) {
      host.appendChild(document.createTextNode(text.slice(last, m.index)));
    }
    var tok = m[0];
    if (tok.indexOf("**") === 0) {
      host.appendChild(el("b", null, tok.slice(2, -2)));
    } else if (tok.charAt(0) === "`") {
      host.appendChild(el("code", null, tok.slice(1, -1)));
    } else {
      host.appendChild(el("i", null, tok.slice(1, -1)));
    }
    last = m.index + tok.length;
  }
  if (last < text.length) {
    host.appendChild(document.createTextNode(text.slice(last)));
  }
  return host;
}

function holoReplyNode(reply) {
  var body = el("div", "body md");
  holoSegments(reply).forEach(function (seg) {
    if (seg.trace) body.appendChild(holoTraceNode(seg.lines));
    else holoRenderProse(body, seg.lines);
  });
  if (!body.childNodes.length) {
    body.appendChild(el("p", "md-p", String(reply || "").trim()));
  }
  return body;
}

function holoRenderProse(body, lines) {
  var i = 0;
  var para = null;
  var paraFilled = false;
  /* `paraFilled` is a FLAG, not `para.children.length` — and that is not a
     style choice. In a real browser `Element.children` is ELEMENTS ONLY: a
     paragraph of plain prose has text nodes and NO element children, so the
     length test dropped every unstyled paragraph on the floor. It passed every
     node-harness assertion (whose stub had text nodes in `children`) and the
     browser rig caught it. Never ask `.children` whether a node has content. */
  function flush() {
    if (para && paraFilled) body.appendChild(para);
    para = null;
    paraFilled = false;
  }
  while (i < lines.length) {
    var ln = lines[i];
    // fenced code — kept verbatim, in a <pre>, never parsed as markdown.
    //
    // S126 (#8) — AND ITS INFO STRING REACHES THE SCREEN. The turn prompt asks
    // the engine for ```file:<path> whenever a write tool fails it, and the
    // DAEMON then writes that block: the info string is the only thing saying
    // WHICH FILE the slab of HTML below became. It was dropped, so the captain
    // read an unlabelled wall of markup. Printed verbatim — the declaration is
    // the model's, and LCARS neither reformats nor interprets it here.
    if (/^\s*```/.test(ln)) {
      flush();
      var info = ln.replace(/^\s*```/, "").trim();
      var buf = [];
      i += 1;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) {
        buf.push(lines[i]); i += 1;
      }
      i += 1;
      // a TEXT NODE, like every other thing the model wrote (`el` sets
      // textContent) — an info string is model-authored text too.
      if (info) body.appendChild(el("div", "fence-info", info));
      body.appendChild(el("pre", null, buf.join("\n")));
      continue;
    }
    // a markdown table: a header row, its ---- rule, then body rows.
    if (/^\s*\|.*\|\s*$/.test(ln) && i + 1 < lines.length
        && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
      flush();
      var table = el("table", "md-t");
      var cells = function (row) {
        return row.trim().replace(/^\||\|$/g, "").split("|")
          .map(function (c) { return c.trim(); });
      };
      var thead = el("tr");
      cells(ln).forEach(function (c) { thead.appendChild(holoInline(el("th"), c)); });
      table.appendChild(thead);
      i += 2;
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        var tr = el("tr");
        cells(lines[i]).forEach(function (c) {
          tr.appendChild(holoInline(el("td"), c));
        });
        table.appendChild(tr);
        i += 1;
      }
      body.appendChild(table);
      continue;
    }
    // a bullet list.
    if (/^\s*[-*+]\s+/.test(ln)) {
      flush();
      var ul = el("ul", "md-l");
      while (i < lines.length && /^\s*[-*+]\s+/.test(lines[i])) {
        ul.appendChild(holoInline(el("li"), lines[i].replace(/^\s*[-*+]\s+/, "")));
        i += 1;
      }
      body.appendChild(ul);
      continue;
    }
    // a heading. ALL levels render as one deck-sized heading: the chat is a
    // conversation, not a document, and six type sizes in a reply is the
    // engine's outline structure leaking through as visual noise.
    var head = /^\s*(#{1,6})\s+(.*)$/.exec(ln);
    if (head) {
      flush();
      body.appendChild(holoInline(el("h4", "md-h"), head[2]));
      i += 1;
      continue;
    }
    if (!ln.trim()) { flush(); i += 1; continue; }
    if (!para) para = el("p", "md-p");
    // A NEWLINE, NOT A SPACE (fix round 2, measured in Chrome). Markdown joins
    // consecutive lines into one paragraph, and that rule flattened a captain's
    // ASCII diagram into a single run of box glyphs — the text was all there
    // and the picture was gone. THIS IS A CHAT: the line breaks he typed are
    // his, so they are kept (`.md-p` is `pre-wrap`, so long prose still wraps).
    if (paraFilled) para.appendChild(document.createTextNode("\n"));
    // A paragraph carrying box-drawing glyphs is a DRAWING, and is set
    // monospaced or the box does not line up (measured in Chrome). Purely
    // cosmetic in both directions — the worst a wrong guess does is change a
    // typeface, and no classification here can ever remove a character.
    if (/[─-╿]/.test(ln) && para.classList) para.classList.add("diag");
    holoInline(para, ln);
    paraFilled = true;
    i += 1;
  }
  flush();
  return body;
}

function holoEngineName(p) {
  var e = String((p && p.engine) || "");
  var base = holoBase(e).toUpperCase();
  return base || "ENGINE";
}

/* The mock's rendering state, in the deck's own accent rather than the board's
   amber working bars — this is the holodeck materialising something, and it
   reads as its own room.

   S128 — `text` is optional and exists so there is ONE working idiom in this
   feature, not three. It is used by:
     • the chat pane, with no argument, for a turn THIS tab just sent;
     • the chat pane again, with the DAEMON's `busyLabel`, for a turn that was
       already running when the deck re-rendered (a returning deck cannot know
       when it started, so it may not say);
     • the New Program dialog, while it opens the deck (FL-004 — the captain
       asked for a thinking icon there in as many words).
   A second spinner shape for any of those is the two-mechanism trap S125 lost
   two rounds to. */
/* S169 (FL-015) — the client's ONE working sentence, authored once. It says
   WORKING and not "rendering": until a turn has written something, a render is
   a claim nothing on this side has earned. `holoWorkingNode` below is the only
   reader. */
var HOLO_WORKING_TEXT = "Working on the holodeck…";

function holoWorkingNode(text) {
  var w = el("div", "holo-working");
  w.setAttribute("role", "status");
  w.setAttribute("aria-live", "polite");
  var bars = el("span", "bars");
  for (var i = 0; i < 4; i++) bars.appendChild(el("i"));
  w.appendChild(bars);
  /* S169 (FL-015) — THE BANNER THE CAPTAIN READ. It said "Rendering on the
     holodeck…" through a long turn on which he had asked a question, not
     directed a build: working-state copy asserting a REASON that neither this
     tab nor the daemon can know until the turn has written something. This is
     the one place the client's own working sentence is authored — every other
     working strip on the deck either passes the DAEMON's label in (a returning
     deck) or reaches this default. */
  w.appendChild(el("span", "wt", text || HOLO_WORKING_TEXT));
  return w;
}

/* ── the live preview (D3) ─────────────────────────────────────────────── */
function holoPreviewPath(p, file) {
  if (!p || !file) return null;
  return "/api/holodeck/" + encodeURIComponent(p.sessionId) + "/preview/"
    + String(file).split("/").map(encodeURIComponent).join("/");
}

function holoPreviewSrc(p) {
  var base = p && holoPreviewPath(p, p.previewFile);
  return base ? base + "?v=" + HOLO.nonce : null;
}

/* Which half of the segmented control this program is showing. A program with
   no concept doc has nothing to toggle TO, and a program that is not the one
   the captain last flipped starts on its mockup — so switching programs never
   lands on the previous one's intent. */
function holoPvView(p) {
  if (!p || !p.conceptFile) return "preview";
  if (HOLO.pvSid !== p.sessionId) return "preview";
  return HOLO.pvView === "intent" ? "intent" : "preview";
}

function holoPreviewPane(p) {
  var pane = el("div", "preview");
  var head = el("div", "pv-head");
  var tog = el("span", "pv-toggle");
  var view = holoPvView(p);
  var pv = el("span", "pvt-b preview", "⬡ Preview");
  /* D14's INTENT, AND IT IS A TOGGLE NOW (S127 FL-007). It shipped as an
     `<a target="_blank">` onto the jailed route — so clicking it opened a
     browser tab of raw markdown — while being DRAWN as half of the same
     segmented control as ⬡ Preview. The captain clicked the affordance D14
     specifies and got something else.

     S126's stated reason for the link does not hold: rendering `concept.md`
     here is not "a second surface beside the file", because this pane ALREADY
     renders `mockup.html` from a file on that same route. The real
     second-source risk would be re-deriving the requirements from the
     transcript in JS; showing THE FILE is the opposite of that, and the file is
     what hands off to a Mission.

     With no concept doc it is still visibly off, saying what is actually true —
     that state is fix round 2's and it is preserved exactly. */
  var intent;
  if (p.conceptFile) {
    intent = el("span", "pvt-b intent", "▤ Intent");
    intent.title = "read concept.md — the written half of this design, and "
      + "what a Mission is handed at the end";
  } else {
    intent = el("span", "pvt-b intent", "▤ Intent");
    /* FIX ROUND 2 — the daemon withholds `conceptFile` for an EMPTY
       concept.md as well as a missing one, because a control that opens a
       blank panel is worse than a control that is visibly off. So this sentence
       is read by a captain who may be looking at a concept.md sitting in his
       own room, and it must not tell him the file is not there. */
    holoCtl(intent, "▤ Intent", null,
            "Nothing has been written into this program's concept.md yet — "
            + "ask for it in the chat and the holodeck keeps it current from "
            + "then on.");
  }
  tog.appendChild(pv);
  tog.appendChild(intent);
  head.appendChild(tog);
  head.appendChild(el("span", "grow"));
  var fname = el("span", "fname", p.previewFile || "no mockup yet");
  head.appendChild(fname);
  pane.appendChild(head);

  var stage = el("div", "pv-stage");
  var src = holoPreviewSrc(p);
  var mock;
  if (src) {
    var frame = el("div", "pv-frame");
    var f = el("iframe");
    f.setAttribute("id", "holoPreview");
    f.setAttribute("title", "the mockup, live from the sidecar");
    /* ══ THE SECURITY PROPERTY OF THIS WHOLE PANE ══════════════════════════
       What is inside this frame is HTML A LANGUAGE MODEL WROTE, served from
       the daemon's OWN origin. Same-origin script in here could read the
       board's DOM, its storage, and POST to the daemon's write API — the
       holodeck would then be a way to make LCARS act on the model's behalf.

       `allow-scripts` is granted because a self-contained multi-screen mockup
       switches its own views in JS (ADR-007) and a preview that cannot do that
       is not showing the captain the artifact that hands off.

       `allow-same-origin` is DELIBERATELY ABSENT, and the two together are the
       only combination that matters: with both, the sandbox grants back
       everything it took away and this attribute becomes decoration. Without
       same-origin the frame runs in an OPAQUE origin — no board DOM, no
       storage, no same-origin fetch. Nothing else is granted either: no forms,
       no popups, no top-level navigation, so the mockup cannot navigate the
       board away or open anything.

       The route's own headers (server.py `_send_preview`: nosniff + a
       default-src 'none' CSP with connect-src and form-action none) are the
       second layer. Do not add `allow-same-origin` here to "fix" a mockup that
       wants to fetch something — a mockup that fetches is not self-contained. */
    f.setAttribute("sandbox", "allow-scripts");
    f.setAttribute("referrerpolicy", "no-referrer");
    f.setAttribute("src", src);
    f.src = src;
    frame.appendChild(f);
    mock = frame;
  } else {
    mock = holoPreviewEmpty(p);
  }
  stage.appendChild(mock);

  /* BOTH VIEWS LIVE IN THE STAGE AT ONCE, and the toggle only ever HIDES one.
     Re-rendering the stage to swap them would destroy the iframe and reload a
     mockup that has not changed — D3's whole guarantee is that the preview
     moves when the FILE moved and at no other time. */
  var panel = p.conceptFile ? el("div", "pv-intent") : null;
  if (panel) stage.appendChild(panel);

  function paint(want) {
    mock.hidden = want === "intent";
    if (panel) panel.hidden = want !== "intent";
    pv.classList.toggle("on", want === "preview");
    pv.setAttribute("aria-pressed", want === "preview" ? "true" : "false");
    if (panel) {
      intent.classList.toggle("on", want === "intent");
      intent.setAttribute("aria-pressed", want === "intent" ? "true" : "false");
    }
    fname.textContent = want === "intent"
      ? p.conceptFile : (p.previewFile || "no mockup yet");
  }

  if (panel) {
    keyActivable(holoCtl(pv, "⬡ Preview", function () {
      holoPvSet(p, "preview", paint, panel);
    }));
    keyActivable(holoCtl(intent, "▤ Intent", function () {
      holoPvSet(p, "intent", paint, panel);
    }));
  } else {
    // nothing to toggle to, so ⬡ Preview is simply the pane you are looking at
    // — the same treatment it has always had, not a dead control.
    holoCtl(pv, "⬡ Preview", null, null);
    pv.setAttribute("data-wired", "1");
  }
  paint(view);
  // a re-render that landed while INTENT was up has to repopulate it, or the
  // captain's next turn blanks the document he was reading.
  if (view === "intent") holoIntentFill(p, panel);
  pane.appendChild(stage);

  var foot = el("div", "pv-foot");
  foot.appendChild(el("span", "fl", "Program room"));
  foot.appendChild(el("span", "chip-file", holoBase(p.programDir || "")));
  foot.appendChild(el("span", "grow"));
  foot.appendChild(el("span", "fl",
    (p.commits || 0) + " commit" + (p.commits === 1 ? "" : "s")));
  pane.appendChild(foot);
  return pane;
}

/* WHAT AN EMPTY STAGE MEANS DEPENDS ON WHETHER A GROUNDING PASS LANDED
   (S127 FL-003). A grounding pass reads the project and writes `basis.md`; it
   draws nothing, and that is correct. But the wording below was byte-identical
   to a blank-deck program's, so a captain whose pass had just SUCCEEDED —
   8.5kB of source-cited basis.md, committed — read "Nothing on the holodeck
   yet · Ask for a screen and it will appear here" and said "I don't
   understand." The pass was step one of two and the deck never said so.

   `grounded` is the daemon's own fact (`_holodeck_meta`), not an inference from
   `mode`, which moves to "design" after the opening pass. */
function holoPreviewEmpty(p) {
  var none = el("div", "pv-none");
  if (!p.grounded) {
    none.appendChild(el("div", "t", "Nothing on the holodeck yet"));
    none.appendChild(el("p", null,
      "The preview shows the mockup file itself, straight from the program's "
      + "room in the sidecar. Ask for a screen and it will appear here."));
    return none;
  }
  /* S172 — a DUPLICATE never ran a pass; its basis came over with the copy.
     "This program read <repo>" is a claim about work that did not happen here,
     and on a duplicate it is usually a claim about a project that has since
     moved. */
  if (p.basisInherited) {
    none.appendChild(el("div", "t", "Nothing on the holodeck yet"));
    none.appendChild(el("p", null, p.basisNotice
      || "This program's grounding came over with the duplicate."));
    none.appendChild(holoBasisNode(p, "▣ Read basis.md", "basis-link"));
    none.appendChild(el("p", "next",
      "Describe a screen, a component or a whole flow in the chat and it will "
      + "be built here."));
    return none;
  }
  none.appendChild(el("div", "t", "Grounding pass complete"));
  none.appendChild(el("p", null,
    "This program read " + holoRepoName() + " "
    + (p.basisFile
       ? "and wrote down the design language it found — its colours, type "
         + "scale, spacing and component shapes."
       : "but has not written basis.md yet, so there is nothing to read back "
         + "of it.")
    + " A grounding pass builds no mockup, which is why the stage is empty."));
  none.appendChild(holoBasisNode(p, "▣ Read basis.md", "basis-link"));
  none.appendChild(el("p", "next",
    "Describe a screen, a component or a whole flow in the chat and it will be "
    + "built here, in the language the pass just found."));
  return none;
}

function holoPvSet(p, want, paint, panel) {
  HOLO.pvSid = p.sessionId;
  HOLO.pvView = want;
  paint(want);
  if (want === "intent") holoIntentFill(p, panel);
}

/* D14's captured intent, rendered IN the pane it is a toggle of.

   The bytes come over the SAME jailed preview route the mockup does, and the
   markdown goes through the board's own renderer (`setMd`/`mdToHtml`, UX-37) —
   there is no second renderer and no second markdown look. Nothing here is
   re-derived from the transcript: this renders THE FILE, which is the thing
   that hands off to a Mission, so the panel and the hand-off can never disagree.

   Cached per program, and the cache is dropped by `holoApplyFilesChanged` when
   a turn actually rewrote `concept.md` — the same rule D3 gives the mockup:
   refresh because the FILE changed, never because a reply said it had. */
function holoIntentFill(p, host) {
  if (!host || !p || !p.conceptFile) return;
  var c = HOLO.intent;
  if (c.sid === p.sessionId && (c.text != null || c.err)) {
    holoIntentPaint(host, c.text, c.err);
    return;
  }
  if (c.sid === p.sessionId && c.loading) {
    holoIntentPaint(host, null, null);
    return;
  }
  c = HOLO.intent = { sid: p.sessionId, text: null, err: null, loading: true };
  holoIntentPaint(host, null, null);
  var unreadable = "concept.md could not be read from this program's room. "
    + "The document is still there — this is the deck failing to fetch it, "
    + "not the holodeck losing it.";
  function settle(text, err) {
    if (HOLO.intent !== c) return;      // a newer request or program won
    c.loading = false;
    c.text = text;
    c.err = err;
    holoIntentPaint(host, text, err);
  }
  fetch(holoPreviewPath(p, p.conceptFile), {
    headers: { "Accept": "text/plain" },
  }).then(function (r) {
    // NOT `throw` — the failure path has to be a value, so that a daemon that
    // answers 404 and a daemon that never answers land in the same place.
    if (!r || !(r.ok || r.status === 200)) { settle(null, unreadable); return null; }
    return r.text();
  }).then(function (text) {
    if (text == null) return;
    settle(String(text), null);
  }).catch(function () {
    settle(null, unreadable);
  });
}

/* S169 (FL-016) — WHY THERE IS A BOX INSIDE THE BOX.

   `.pv-intent` used to be BOTH the scroll container and the containing block
   for the readability scrim that makes this document legible over the deck's
   grid. An absolutely-positioned child of a scroll container is sized to the
   PADDING BOX — one viewport-height rectangle, not the scrollable content —
   and it scrolls with the content. So the scrim was a single screen's worth of
   darkening that slid up and off, and every word past the first screen sat
   bare on the grid. The captain hit it on his own captured requirements.

   The technique itself is not wrong; it was copied from `.pv-none` (FL-006),
   a pane that does NOT scroll, where `inset:0` is exactly right. The cure is
   to give it a container that does not scroll: `.pv-intent` keeps the scrim
   and stops scrolling, and THIS node — created here on every paint, so there
   is one place the panel's content is built and no second source of truth —
   is the thing that scrolls, above it.

   Do NOT "fix" this by stretching the scrim: `height:100%` resolves against
   the same padding box and changes nothing, and a JS-measured height is a
   number that goes stale on the next reflow. */
function holoIntentScroller(host) {
  var s = el("div", "pv-intent-scroll");
  host.appendChild(s);
  return s;
}

function holoIntentPaint(host, text, err) {
  host.innerHTML = "";
  var scroll = holoIntentScroller(host);
  if (err) {
    var note = el("div", "pv-intent-note");
    note.appendChild(el("div", "t", "Intent unavailable"));
    note.appendChild(el("p", null, err));
    scroll.appendChild(note);
    return;
  }
  if (text == null) {
    scroll.appendChild(workingNode("Reading concept.md…"));
    return;
  }
  var doc = el("div", "intent-doc");
  var body = String(text).trim();
  if (body) {
    setMd(doc, body);
  } else {
    /* The daemon withholds `conceptFile` for an EMPTY concept.md, so reaching
       here means the file emptied between the list call and this click. Say
       that, rather than showing a blank panel that reads as a broken toggle. */
    doc.appendChild(el("p", null,
      "concept.md is in this program's room but has nothing in it yet — ask "
      + "for it in the chat and the holodeck keeps it current from then on."));
  }
  scroll.appendChild(doc);
}

/* D3's refresh trigger, and the whole reason the preview can be trusted: the
   iframe is re-pointed because the FILE on disk changed (the turn payload's
   `filesChanged`), never because the reply said it had. A turn that changed
   nothing leaves the preview exactly where it was — no flicker, and no
   "something happened" signal for something that did not. */
function holoApplyFilesChanged(files, program) {
  var p = program || holoActive();
  if (!p) return false;
  function changed(name) {
    var want = holoBase(name);
    return (files || []).some(function (c) {
      return holoBase(typeof c === "string" ? c : (c && c.path)) === want;
    });
  }
  /* D14's INTENT panel obeys the same rule (S127 FL-007): a turn that rewrote
     `concept.md` drops the cached bytes, so the next render reads the file
     again. A turn that did not touch it leaves the captain's place on the
     document exactly where it was. The return value below is untouched — it is
     the MOCKUP's answer, and it is what tells the caller a preview refreshed. */
  if (p.conceptFile && HOLO.intent.sid === p.sessionId
      && changed(p.conceptFile)) {
    HOLO.intent = { sid: null, text: null, err: null, loading: false };
  }
  if (!p.previewFile) return false;
  var hit = changed(p.previewFile);
  if (!hit) return false;
  HOLO.nonce += 1;
  var f = document.getElementById("holoPreview");
  var src = holoPreviewSrc(p);
  if (f && src) { f.setAttribute("src", src); f.src = src; }
  return true;
}

/* ── a turn ────────────────────────────────────────────────────────────── */
function holoSay(sid, text, images, intent) {
  text = String(text || "").trim();
  if (!text || HOLO.busy) return;
  /* S169 (FL-015) — read BEFORE `holoDraftClear` below wipes the draft this
     came out of, and passed on verbatim. The daemon normalises; this side does
     not interpret. */
  intent = intent === "ask" ? "ask" : "build";
  /* S169 (FL-013) — THE TURN IS SAID, so it stops being a draft. Cleared here
     rather than in the composer, and only past the guard above: a send that
     was refused (empty, or a turn already in flight) must leave what he typed
     exactly where it is. */
  holoDraftClear(sid);
  HOLO.busy = true;
  HOLO.banner = null;
  // show the captain's words immediately — they are already said, and a chat
  // that swallows your line until the reply lands feels broken.
  //
  // BUT A RETRY IS THE SAME LINE, NOT A SECOND ONE (fix round 2). RETRY TURN
  // calls straight back in here with the text of the turn that died — whose
  // unanswered turn is still sitting at the end of the transcript — and round 1
  // pushed a second copy, so the captain read himself saying it twice. He said
  // it once. (The daemon reuses that same pending turn for the same reason.)
  var p = holoActive();
  var turns = p ? (p.turns = p.turns || []) : null;
  var pending = turns && turns.length ? turns[turns.length - 1] : null;
  if (turns && !(pending && pending.text === text && !pending.reply)) {
    turns.push({ text: text, reply: null, intent: intent });
  } else if (pending) {
    pending.intent = intent;
  }
  renderDeck();
  /* `images` rides the EXISTING body, exactly as the File console's idea box
     and the Log box already do (S91) — the daemon stages them into the
     program's room and threads them into THIS turn. `undefined` when nothing
     was pasted, so JSON.stringify omits the key and the request is
     byte-identical to before. */
  postWrite("/api/holodeck/" + sid + "/say",
            { text: text, images: images, intent: intent },
    function (state) {
      HOLO.busy = false;
      var cur = holoActive();
      if (cur) {
        cur.previewFile = state.previewFile || cur.previewFile;
        cur.commits = state.commits != null ? state.commits : cur.commits;
        // S126: `conceptFile` is what makes the ▤ Intent control openable, and
        // it can appear on any turn — it is the turn the worker first writes
        // the concept doc on.
        if (state.conceptFile !== undefined) cur.conceptFile = state.conceptFile;
        // and the turn that OPENS the warm session is the turn the pill stops
        // saying FRESH — not the next poll (fix round 2).
        if (state.warm !== undefined) cur.warm = state.warm;
        var last = (cur.turns || [])[cur.turns.length - 1];
        if (last && last.reply == null) {
          last.reply = state.reply || "";
          last.filesChanged = state.filesChanged || [];
          last.conceptAudit = state.conceptAudit || null;
          /* S169 (FL-015) — the daemon's account of what this turn DID, kept
             on the turn it is about, exactly like `conceptAudit` beside it. */
          last.turnOutcome = state.turnOutcome || null;
        }
      }
      if (state.status === "refused" && state.refused) {
        // `paths` is NOT passed on: the daemon's message already names them,
        // and round 1's banner printed the stray path twice for exactly that
        // reason. One account of what happened, from one place.
        holoSetBanner("refused", { message: state.refused.message });
      } else if (state.warning) {
        // ONE TITLE PER KIND (fix round 3). Both warnings used to arrive under
        // "Turn not certified", which is a LIE about a `no-write` turn: its
        // audit ran and completed, nothing was uncertified — the engine simply
        // did not write. The kind is already on the payload; use it.
        holoSetBanner(HOLO_WARNING_BANNER[state.warning.kind] || "unverified",
                      { message: state.warning.message });
      }
      // bump the preview BEFORE the re-render so the fresh src is what paints.
      holoApplyFilesChanged(state.filesChanged, cur);
      renderDeck();
      holoRefresh();
    },
    function (msg, err) {
      HOLO.busy = false;
      /* S169 FIX ROUND 1 — A RETRY THAT WOULD RE-POISON IS NOT A RETRY.
         When the daemon says it RESET the warm session (`sessionReset`), the
         attachment this turn carried is what the engine refused, and re-sending
         it into the fresh session would kill that one too — measured live on
         copilot: a poisoned session dies on every later turn, attachment or
         not. The line is retried WITHOUT it, which is exactly what the banner
         tells him to do. Read off the daemon's FACT, never off its wording. */
      var reset = !!(err && err.sessionReset);
      holoSetBanner("offline", { message: msg,
                                 retry: { sid: sid, text: text,
                                          images: reset ? null : images,
                                          intent: intent } });
      renderDeck();
    });
}

/* ── S127: SEND TO ALIGN ───────────────────────────────────────────────────
   Two steps, and the split is the point. `holoPromote` asks the DAEMON for the
   hand-off — it resolves the program's room, reads its concept doc, drafts the
   brief and composes the guidance. `openHandoff` renders exactly what came
   back and posts the captain's brief with the program's SESSION ID.

   THE PATH NEVER COMES NEAR THIS FILE. The board asks for a hand-off by session
   id and files by session id; the daemon owns every filename in between. That
   is the captain's bar ("he never types a file path… never sees the plumbing")
   and it is also the security property: a path this side could read is a path
   this side could send. */
function holoPromote(sid) {
  if (!sid) return;
  postWrite("/api/holodeck/" + sid + "/promote", {}, function (state) {
    openHandoff(state);
  }, function (msg) {
    holoSetBanner("offline", { message: msg });
    renderDeck();
  });
}

/* S171 — THE LITERAL-WORD REQUIREMENT CHECK IS GONE FROM BOTH SIDES.

   `holoMissingRequirements` mirrored the daemon's `_handoff_missing`: a
   containment test on the captain's own words, run per keystroke, painting a
   ✓/⚠ row per captured requirement and an amber band under them. It went with
   the daemon's copy, and for the daemon's reason — his literal words are no
   longer IN the brief (the numbered "in your own words" list left it), so the
   check would have reported nearly every requirement as missing on every
   hand-off. The reasoning, and the risk that was accepted, is written up in
   full in actions.py where `_handoff_missing` used to be. Nothing replaced it
   here; a smarter checker on the browser side would be the same mistake with
   a worse view of the facts. */

/* ── S169: the pre-drafted brief now carries THREE things ──────────────────
   His own words, what the mockup CHANGES about the app he has today, and what
   it IMPLIES that nobody has settled. The daemon composes all three (one
   function, `_handoff_parts`); these two only decide how the box is SIZED and
   how it is DESCRIBED, which is the half a browser can get wrong. */
var HOLO_BRIEF_ROWS_MIN = 8, HOLO_BRIEF_ROWS_MAX = 20;

function holoBriefRows(text) {
  var n = String(text == null ? "" : text).split("\n").length;
  return Math.max(HOLO_BRIEF_ROWS_MIN, Math.min(HOLO_BRIEF_ROWS_MAX, n));
}

function holoCount(n, one, many) {
  return n + " " + (n === 1 ? one : many);
}

function holoBriefHint(seed) {
  /* S171 — THE FALLBACK BRANCH IS GONE, because so is the fallback. The head
     of the brief used to be drafted off the concept doc, down a three-rung
     ladder (`summarySource` said which rung), and this sentence explained a
     degraded draft. The head is now the captain's own opening description,
     carried byte-for-byte, which every program has — there is no rung to fall
     to and nothing to apologise for. */
  /* KEPT SHORT, AND THAT IS A MEASUREMENT, NOT A STYLE PREFERENCE. The first
     draft of this sentence ran to three lines (87px) and pushed itself out of
     the modal body's visible band at a 677px window — the line whose whole job
     is to be seen by a captain who reads one screen. Measured by
     tests/drives/browser/handoff.sh, which now hit-tests it. */
  /* S169 FIX ROUND 2 — AND IT WAS STILL ASSERTING THE COMPARISON.

     It read "8 things you said, 18 CHANGES THE MOCKUP MAKES TO TODAY'S APP and
     5 it implies". Fix round 1 corrected the caption INSIDE the box to say the
     list is the design chat's own account and "not a reading of your code" —
     and left this line, four inches above it, claiming the daemon had compared
     the mockup against the captain's app. It had not: it read `## Decisions`,
     a section a model wrote from the conversation, and counted its bullets.

     The count is the same number; the claim about where it came from is now
     true. What the mockup was actually READ against is the check band's
     business, below — and that one only says so when a pass really ran. */
  /* S170 — AND NOW THE SENTENCE HAS TWO SOURCES, so it names both. His words
     and what the mockup implies come out of the concept doc; THE CHANGE LIST
     DOES NOT — it is read off his project and the drawing by a pass that
     stands in the repo. Saying "drafted from your concept doc" over a list
     that was not is the same class of lie fix round 2 took out of here, one
     source along. */
  /* S171 — AND IT NO LONGER COUNTS "things you said". The brief's first line
     IS what he said, whole and unedited, so a count of quoted fragments would
     be counting something that is not in the box. It is named, not numbered. */
  var parts = ["your own words"];
  var d = (seed.changes || []).length, i = (seed.implied || []).length;
  var o = (seed.outOfScope || []).length;
  if (d) {
    parts.push(holoCount(d, "change read off your project",
                         "changes read off your project"));
  }
  if (i) parts.push(i + " the mockup implies");
  if (o) parts.push(o + " out of scope");
  var last = parts.pop();
  return "In this brief: "
    + (parts.length ? parts.join(", ") + " and " + last : last)
    + ". Scroll it — all of it is yours to correct.";
}

/* ── S170: THE DERIVATION BAND — the wait, made honest ────────────────────
   SEND TO ALIGN is a stage now, by the captain's own design: *"make send to
   align a stage with wait time where the holodeck does a final diff and
   summarization… I know this means it can take a few minutes and we can make
   it so it can walk away, but I feel like that would yield a better result."*

   S169's band rendered a spinner on a dialog. THE WAIT WAS ALREADY REAL —
   154–220s measured, a 420s bound, a 520s poll budget — and hiding it behind
   "Reading these lines back…" told a captain nothing about whether he could
   leave. This band's whole job is that he CAN.

   FOUR STATES, DIFFERENT ON PURPOSE, and two of them are the reason it exists:
   "the pass ran and produced a list" and "the pass could not run" must never
   look alike, because the second one leaves a section MISSING from his brief
   and only this band can tell him so. `derive.ok === false` means THE PASS DID
   NOT ANSWER. It is not "the mockup changes nothing".

   AND IT NEVER BLOCKS. ▦ FILE MISSION is live in every one of these states. */
function holoDeriveRender(box, derive, opts) {
  var state = (derive && derive.state) || "off";
  box.className = "handoff-derive";
  box.setAttribute("data-state", state === "done"
    ? (derive.ok ? "done" : "failed") : state);
  while (box.firstChild) box.removeChild(box.firstChild);
  if (state === "off") { box.hidden = true; return; }
  box.hidden = false;
  if (state === "running") {
    /* THE ONE SENTENCE THAT MAKES IT A WALK-AWAY. It says what is happening,
       how long it takes, and — the part a client cannot invent — that closing
       this dialog does not stop it. The daemon owns the pass, so this is a
       fact, not reassurance. */
    box.className = "handoff-derive running";
    /* ── AND IT IS THREE LINES, WHICH IS A MEASUREMENT ─────────────────────
       This band sits between the hint and the brief box, so every pixel of it
       is a pixel of the captain's own draft off the first screen. The first
       version of this copy said all of the above in two paragraphs and came to
       ~170px in real Chrome — which left EIGHT visible lines of brief at
       1440x677 and FOUR at 1280x613, against a bar of nine and six. Found by
       tests/drives/browser/handoff.sh on its first run, which is exactly what
       that rig is for; no unit test in this repo can see it.

       So it says the three things and stops: it is working and takes minutes,
       he may leave (and how far that survives), and the brief below is
       sendable without a change list. */
    box.appendChild(el("span", "ck-head",
      "⧗ Working out what the mockup changes about your project"
      + holoDeriveElapsed(derive) + " — a few minutes. CLOSE THIS AND WALK "
      + "AWAY IF YOU LIKE: it keeps running, survives a reload and a restart, "
      + "and the change list drops into the brief below when it lands. You can "
      + "send the brief without one."));
    return;
  }
  if (!derive.ok) {
    /* SAYS SO, PLAINLY, and does not dress it up. Nothing is blocked; what he
       has to know is that a section of his brief is NOT THERE, which is a
       different thing from a list that came back empty. */
    box.className = "handoff-derive failed";
    box.appendChild(el("span", "ck-head",
      "LCARS could not read your project against the mockup"
      + (derive.why ? " — " + derive.why : "")
      + ". Nothing is blocked: the brief below is missing only the change "
      + "list, and you can send it as it is or write the changes yourself."));
    return;
  }
  var n = (derive.changes || []).length;
  if (!n) {
    /* A REAL ANSWER, AND A STRANGE ONE. The pass ran and reported no
       difference at all, which on a program somebody spent an afternoon
       drawing is far more likely to be a bad pass than a true finding. It is
       not dressed up as a clean result and it is not called a failure — it is
       reported exactly as what happened. */
    box.className = "handoff-derive failed";
    box.appendChild(el("span", "ck-head",
      "A read-only pass compared your project with the mockup and found "
      + "nothing different. On a design you have been working on, that is "
      + "much more likely to be a bad pass than a true answer — read the "
      + "mockup yourself before you send this."));
    return;
  }
  box.className = "handoff-derive done";
  box.appendChild(el("span", "ck-head",
    "✓ A read-only pass stood in your project, compared it with the mockup "
    + "and found " + n + " change" + (n === 1 ? "" : "s")
    + ". They are in the brief below, in your own writing space. Anything the "
    + "mockup leaves as your app already has it produces no line — that is "
    + "why this is shorter than the design chat."));
  if (opts && opts.appended) {
    /* HIS OWN WORDS WERE NOT TOUCHED, and he is told rather than left to
       notice. FL-013 is this defect one surface over — unsent text destroyed
       by a re-render — and the rule is the same: never overwrite what a human
       typed. ONE LINE, because every pixel of this band is a pixel of his
       brief off the first screen (measured — see the running state). */
    box.appendChild(el("div", "ck-row",
      "You had edited your brief while this was running, so LCARS added them "
      + "at the BOTTOM of it and changed nothing you wrote."));
  }
}

/* "· started 45s ago" — or nothing at all when the daemon did not say.

   ELAPSED IS COMPUTED FROM THE DAEMON'S OWN CLOCK READING, never from a
   timestamp this side subtracts against its own: that is the class of bug the
   turn banner's `busyFor` was built to avoid (S128/FL-002). `startedAt` is a
   server epoch and `derive.now`, when present, is the same server's idea of
   now; without both, this says nothing rather than guessing. */
function holoDeriveElapsed(derive) {
  var t = derive && derive.startedAt, now = derive && derive.now;
  if (!t || !now || now < t) return "";
  var s = Math.round(now - t);
  if (s < 5) return "";
  if (s < 90) return " · started " + s + "s ago";
  return " · started " + Math.round(s / 60) + " min ago";
}

/* Ask again while the pass is in flight. It is a POLL and not a stream because
   `promote` is already the endpoint that answers this question — a second road
   (an SSE channel, a status endpoint) would be a second thing to keep in step
   with the draft, and the draft is what the pass PRODUCES.

   IT STOPS WHEN THE DIALOG GOES. `document.body.contains` is the test: the
   overlay is REMOVED on close (unlike the help console, which covers), so a
   detached band is a closed dialog and there is nobody left to tell. The pass
   itself does not stop — it is the daemon's, and the room keeps the answer. */
/* The budget MUST outlast the daemon's own bound on the pass, or the band
   gives up on a worker that is still working and reports a failure the daemon
   never had. The daemon stops a pass at 420s (`_handoff_derive_timeout`,
   itself measured off three live copilot drives at 154/193/220s); 130 × 4s is
   520s, which covers that plus the spawn and the last poll's own interval. */
var HOLO_CHECK_POLL_MS = 4000, HOLO_CHECK_POLL_MAX = 130;

function holoDerivePoll(seed, box, picked, tries, onLanded) {
  if (!box || !document.body.contains(box)) return;
  if (tries > HOLO_CHECK_POLL_MAX) {
    /* AND THIS ONE IS ABOUT THE DIALOG, NOT THE PASS. The daemon may still be
       working and the room will still get the answer; what ran out is this
       page's patience. Saying "it failed" here would be the band asserting
       something it cannot know. */
    holoDeriveRender(box, { state: "done", ok: false,
      why: "it did not finish while this dialog was open. It may still be "
        + "running — close this and press ▶ SEND TO ALIGN again in a minute" });
    return;
  }
  setTimeout(function () {
    if (!box || !document.body.contains(box)) return;
    postWrite("/api/holodeck/" + seed.sessionId + "/promote",
      { scope: picked.scope }, function (state) {
        if (!box || !document.body.contains(box)) return;
        var derive = state.derive || { state: "off" };
        if (derive.state === "running") {
          holoDeriveRender(box, derive);
          holoDerivePoll(seed, box, picked, tries + 1, onLanded);
          return;
        }
        /* IT LANDED. The daemon has redrafted the brief WITH the change list
           in it, and only the caller knows whether the captain has typed since
           — so the caller decides, and this reports which way it went. */
        holoDeriveRender(box, derive, onLanded ? onLanded(state, derive) : null);
      }, function (msg) {
        if (!box || !document.body.contains(box)) return;
        holoDeriveRender(box, { state: "done", ok: false, why: msg });
      });
  }, HOLO_CHECK_POLL_MS);
}

/* The hand-off dialog (mock screen 6, D5/D13/D14/D15). One screen: a REAL
   writing space pre-drafted from the conversation, how much to build, what
   rides along by NAME, and — visible before he sends — exactly how the mission
   will be told to read the mockup. One button: ▦ FILE MISSION. */
function openHandoff(seed) {
  var m = modal("▶ Send to Align", { headClass: "teal" });
  var err = el("div", "errline"); err.hidden = true;

  m.body.appendChild(el("div", "hint",
    "Sending " + (seed.program || "this program")
    + ". The mockup and the concept doc go with it — you never have to find "
    + "them."));

  /* 1. THE BRIEF. A writing space, not a title field (D15): conveying what you
     mean about a feature with UI is the thing that was hard before the
     holodeck, and getting it wrong was expensive at whole-mission scale. The
     mock makes the LOOK cheap to correct; it does nothing for the reasoning,
     and reasoning needs room. Pre-drafted so the page is never blank. */
  /* Declared here rather than beside the scope cards below, because the check
     band's poll re-asks `promote` and has to send the scope he is on. One
     object, read by reference — the cards mutate it, the poll reads it. */
  var picked = { scope: seed.scope || "look+behaviour" };
  var f1 = el("div", "field");
  f1.setAttribute("data-holo", "handoff-brief-field");
  f1.appendChild(label("Your brief — what you are actually asking for"));
  var brief = el("textarea");
  /* S169 — THE BOX HAS TO SHOW THAT IT GREW.

     The draft used to be the captain's own words and nothing else — six lines
     in an eight-row box, so the whole of it was on screen. It now also carries
     what the mockup CHANGES about the app he has today and what it IMPLIES,
     which on both real fixtures is ~31 lines. Left at eight rows, two thirds
     of his brief would sit inside a scrollbox he has no reason to scroll —
     which is D1 all over again, one level down: the session's own goal,
     delivered and invisible.

     So the box takes the size of what is in it, CLAMPED. The floor keeps a
     short draft from collapsing into a slot; the ceiling is what stops this
     from being the change that pushed everything below it off the screen —
     the dialog is already 1812px against a ~677px window. Measured in real
     Chrome by tests/drives/browser/handoff.sh, which is where a claim about
     what is on screen belongs. */
  brief.rows = holoBriefRows(seed.brief);
  brief.value = seed.brief || "";
  brief.setAttribute("data-holo", "handoff-brief");
  brief.placeholder = "What do you want built, and why this way?";
  /* …AND IT HAS TO SAY WHAT IS IN IT. The counts come from the DAEMON's own
     sets (`_handoff_parts`), never counted here, so the sentence cannot claim
     something the draft does not contain.

     S169 FIX ROUND 1 — IT MOVED ABOVE THE BOX. It used to sit directly under
     it, which worked only while the box was short enough for both to share the
     first screen. The box is now as tall as the draft (see `fitBrief`), so
     "under the box" is 800px down — and this is the ONE line that tells a
     captain who reads one screen that there are two more sections below his
     own words. Above it, it is the first thing he reads and it stays on screen
     at every viewport, including the 613px one where the tester measured it
     clipped mid-height by the footer band. */
  var briefHint = el("span", "hint", holoBriefHint(seed));
  f1.appendChild(briefHint);
  /* …AND THE CHECK BAND SITS BETWEEN THE HINT AND THE BOX (S169 fix round 2).

     Above the box for the same measured reason the hint is: the box is as tall
     as the draft, so anything under it is 800px down, and this is the line that
     has to make a one-screen skim land on the wrong sentence. Under the hint
     rather than over it, because the hint says what the draft IS and this says
     what was found in it — and a finding above its own subject reads as a
     banner about the dialog. */
  var checkBox = el("div", "handoff-derive");
  checkBox.setAttribute("data-holo", "handoff-derive");
  checkBox.hidden = true;
  f1.appendChild(checkBox);
  holoDeriveRender(checkBox, seed.derive || { state: "off" });
  f1.appendChild(brief);
  m.body.appendChild(f1);

  /* ── S170: WHAT HAPPENS WHEN THE DERIVATION LANDS WHILE HE IS SITTING HERE
     The daemon redrafts the brief WITH the change list in it, so the honest
     move is to put the new draft in the box — but ONLY if the box still holds
     exactly what the daemon last put there. FL-013 was unsent chat text
     destroyed by a re-render; this is the same textarea class one dialog over,
     and the rule is the same: NEVER OVERWRITE WHAT A HUMAN TYPED.

     `pristine` is a byte comparison against the last draft the daemon gave,
     not a "dirty" flag — a captain who types a word and deletes it again has
     not edited anything, and a flag would say he had. */
  function briefIsPristine() { return brief.value === seed.brief; }
  function briefLanded(state, derive) {
    if (briefIsPristine()) {
      seed.brief = state.brief || seed.brief;
      brief.value = seed.brief;
      fitBrief();
      rehint(state);
      return null;
    }
    /* HE TYPED WHILE IT RAN. So the change list is APPENDED to the end of what
       he wrote, and not one character of his own text is touched.

       THE OTHER ROAD WAS BUILT AND MEASURED AND THROWN AWAY. It left the box
       alone and printed the changes in the band for him to copy across; in
       real Chrome (tests/drives/browser/handoff.sh) three change rows took the
       band to a height that left THREE visible lines of his brief at 1440x677
       against a bar of nine. A finding delivered on top of a slot is S128's D1,
       and this round is not shipping it a second time.

       THE WORDS ARE THE DAEMON'S (`changesBlock`), never composed here — what
       he reads and what the Mission is told cannot drift. And the caret is put
       back, because assigning to a textarea's value jumps it to the end, which
       is the same "a re-render ate my typing" feeling FL-013 was about. */
    /* S172 — TWO BLOCKS, because the pass now produces two things: what is
       different, and what it FOUND AND DID NOT REPORT because his own
       out-of-scope ruling made it ambiguous. `impliedBlock` carries only the
       pass's own questions — bucket 2's declared items are already in the
       draft he is typing into. Both are the DAEMON's words. */
    var blocks = [];
    [state.changesBlock, state.impliedBlock].forEach(function (b) {
      if (b && brief.value.indexOf(b) === -1) blocks.push(b);
    });
    if (!blocks.length) return null;
    var block = blocks.join("\n\n");
    var at = brief.selectionStart, to = brief.selectionEnd;
    brief.value = brief.value.replace(/\s+$/, "") + "\n\n" + block + "\n";
    try { brief.setSelectionRange(at, to); } catch (e) { /* not focused */ }
    seed.brief = brief.value;
    fitBrief();
    rehint(state);
    return { appended: (derive.changes || []).length };
  }
  /* AND THE LINE THAT SAYS WHAT IS IN THE BRIEF HAS TO MOVE WITH IT.
     The dialog opens while the pass is still running, so at that moment the
     draft has no change list and the hint honestly says so. When the list
     lands the hint would otherwise still be describing the brief he had a
     minute ago — undercounting the box he is about to send, which is the same
     class of lie fix round 2 took out of this sentence for a different
     reason. Recomposed from the DAEMON's sets, never counted here. */
  function rehint(state) {
    seed.changes = state.changes || seed.changes;
    seed.implied = state.implied || seed.implied;
    seed.outOfScope = state.outOfScope || seed.outOfScope;
    briefHint.textContent = holoBriefHint(seed);
  }

  /* 1b. THE ✓ CAPTURED-REQUIREMENTS CHECKLIST IS GONE (S171).

     It listed every captured requirement under "What you said, in your own
     words — is it all in there?" and marked each ✓ or ⚠ against the brief. The
     captain named this surface and the numbered list in the box in one breath:
     both are the raw chat feed, and the list is what he was deleting by hand
     before sending. With his words no longer quoted in the brief, every row
     here would have gone ⚠ on every hand-off — a panel of warnings that are
     all false, beside ▦ FILE MISSION. See actions.py at `_handoff_missing`'s
     old home for what was accepted with it. */

  /* 2. HOW MUCH TO BUILD (D13). Declared, never inferred: a mockup cannot tell
     you whether its toggle is meant to persist, and a wrong guess is either a
     wasted backend or a missing one. Declaring costs one click. */
  var f2 = el("div", "field");
  f2.appendChild(label("How much of this should be built?"));
  var choices = el("div", "choices");
  var SCOPES = [
    ["look+behaviour", "⚙", "Look and behaviour",
     "Build it for real — backend, state, persistence, the lot. The mockup "
     + "says how it looks; your brief says what it must do."],
    ["look-only", "◐", "Look only",
     "A reskin. Match the mockup visually and change no behaviour — same "
     + "data, same actions, same outcomes."],
  ];
  var guideBox = el("pre", "handoff-guidance");
  SCOPES.forEach(function (o) {
    var card = el("div", "choice-card" + (o[0] === picked.scope ? " sel" : ""));
    card.appendChild(el("span", "ci", o[1]));
    var cc = el("span", "cc");
    cc.appendChild(el("span", "ct2", o[2]));
    cc.appendChild(el("span", "cd", o[3]));
    card.appendChild(cc);
    card.setAttribute("data-choice", o[0]);
    card.setAttribute("aria-pressed", o[0] === picked.scope ? "true" : "false");
    keyActivable(holoCtl(card, o[2], function () {
      picked.scope = o[0];
      Array.prototype.forEach.call(choices.children, function (c) {
        c.classList.remove("sel");
        c.setAttribute("aria-pressed", "false");
      });
      card.classList.add("sel");
      card.setAttribute("aria-pressed", "true");
      // THE GUIDANCE FOLLOWS THE CHOICE, and it is re-fetched from the DAEMON
      // rather than assembled here: the block shown and the block filed have to
      // be the same words, and the only way to guarantee that is for one side
      // to write them.
      holoRefreshGuidance(seed, picked.scope, guideBox);
    }));
    choices.appendChild(card);
  });
  f2.appendChild(choices);
  m.body.appendChild(f2);

  /* 3. WHAT RIDES ALONG — by NAME. Never a path: he does not need one and
     should never be shown one. */
  var f3 = el("div", "field");
  f3.appendChild(label("What rides along — attached automatically"));
  var rides = el("div", "rides");
  (seed.rides || []).forEach(function (r) {
    var row = el("div", "ride");
    row.appendChild(el("span", "ic", /\.md$/i.test(r.name) ? "▤" : "⬡"));
    row.appendChild(el("span", "nm", r.name));
    row.appendChild(el("span", "ds", r.what || ""));
    rides.appendChild(row);
  });
  f3.appendChild(rides);
  f3.appendChild(el("span", "hint",
    "They are copied into the Mission's own attachments and read by every "
    + "stage. They never enter your repository."));
  m.body.appendChild(f3);

  /* 4. THE GUIDANCE, MADE VISIBLE (D15). A pasted screenshot arrives with no
     instructions attached and every downstream stage guesses what it was for.
     This block is what the holodeck adds — and showing it is also one more
     place the non-shipping declaration appears, which is the S164-measured
     cure rather than a single prose pin. */
  var f4 = el("div", "field");
  f4.setAttribute("data-holo", "handoff-guidance-field");
  f4.appendChild(label("How the mockup will be read — goes into the Mission"));
  guideBox.textContent = seed.guidance || "";
  guideBox.setAttribute("data-holo", "handoff-guidance");
  f4.appendChild(guideBox);
  m.body.appendChild(f4);

  /* 5. THE OPEN QUESTIONS — LAST, deliberately (S128, FL-011 b). The holodeck
     writes `## Open questions` into the concept doc and on the S127 capstone it
     was RIGHT: it named all five things the captain objected to at Verify. It
     was also never read by `promote`, so the five reached the mission as
     settled decisions he had never made — and every gate downstream honoured
     them.

     They go here, at the bottom, because this is the last thing he reads with
     his hand on the button. He is right there, they are short, and answering
     five questions costs less than one wrong build. Anything he leaves blank
     rides in marked STILL OPEN — the daemon writes that block, so silence
     arrives as silence instead of as agreement.

     S128 FIX ROUND 1, D1 — "last in the DOM" was never the same claim as "in
     front of him", and a browser said so. Measured: this body is 1812px tall,
     the visible window is 677px at 1440x900 and 443px at 900x640, and this
     block starts 546–780px BELOW the fold — while ▦ File Mission is laid out
     and clickable in the sticky footer from first paint. The tester clicked it
     at scrollTop 0 and filed a mission whose five open questions he had never
     seen. Nothing on screen said they existed; even this field's own label was
     546px down.

     The cue that fixes it is in the FOOTER, below — see `qcue`. It stays here,
     last, because the position is right for the captain who reads the dialog;
     what was missing is a signal for the one who does not. */
  var questions = seed.questions || [];
  var qBoxes = [];
  var qField = null;
  if (questions.length) {
    var f5 = el("div", "field");
    qField = f5;
    f5.setAttribute("data-holo", "handoff-questions");
    f5.appendChild(label("Before you send — " + questions.length
                         + " open question"
                         + (questions.length === 1 ? "" : "s")
                         + " from the design session"));
    var qlist = el("div", "handoff-questions");
    questions.forEach(function (q) {
      var row = el("div", "hq");
      row.appendChild(el("div", "qt", q.text || ""));
      var box = el("input");
      box.type = "text";
      box.value = "";
      box.setAttribute("data-holo", "handoff-question");
      box.setAttribute("data-qid", q.id || "");
      box.placeholder = "Your answer — or leave blank to send it as open";
      row.appendChild(box);
      qlist.appendChild(row);
      qBoxes.push({ id: q.id, box: box });
    });
    f5.appendChild(qlist);
    f5.appendChild(el("span", "hint",
      "These came out of designing this. What you answer becomes a "
      + "requirement, in your words. Anything you leave blank arrives in the "
      + "Mission with NO ANSWER RECORDED and quoted exactly as it reads here; "
      + "anything genuinely undecided gets asked again, and none of it is ever "
      + "read as a decision you made."));
    m.body.appendChild(f5);
  }

  var go = applyWriteState(holoBtn("▦ File Mission", "go big", function () {
    var text = String(brief.value || "").trim();
    if (!text) { showErr(err, "Write the brief first."); return; }
    go.disabled = true;
    go.textContent = "Filing…";
    err.hidden = true;
    // Only what he actually TYPED. A blank box is not an empty answer — it is
    // no answer, and it has to reach the Mission as one.
    var answers = {};
    qBoxes.forEach(function (q) {
      var said = String(q.box.value || "").trim();
      if (said) answers[q.id] = said;
    });
    postWrite("/api/park", {
      idea: text,
      engine: /copilot/i.test(String(seed.engine || "")) ? "copilot" : "claude",
      holodeck: seed.sessionId,
      holodeckScope: picked.scope,
      holodeckAnswers: answers,
    }, function () {
      closeOverlay();
      // Back to the BOARD: the card he just filed is there, and driving it is
      // his next move. The deck's own list refreshes behind it so the program
      // reads `sent` when he comes back.
      holoSetMode(false);
      holoRefresh();
      refresh();
    }, function (msg) {
      go.disabled = false;
      go.textContent = "▦ File Mission";
      showErr(err, msg);
    });
  }));
  /* ── THE FOOTER IS THE ONLY THING ALWAYS ON SCREEN (S128 fix round 1) ─────
     `.modal-body` scrolls; `.modal-foot` does not. Everything below therefore
     rides beside the button rather than at the bottom of an 1812px document the
     captain has no reason to reach.

     D2 — THE ERROR LINE MOVES HERE. It was appended to `m.body`, so a filing
     that came back 502 painted its explanation 1,115px out of sight while the
     button quietly said "▦ File Mission" again. The report of a failure belongs
     with the control that failed. (`showErr` now also scrolls the line into
     view, which cures the same class for the eight other dialogs that keep
     their errline in the scrolling body.)

     D1 — THE OPEN-QUESTIONS CUE. Three fixes were on the table: a count here,
     auto-scrolling the questions into view on open, or moving them above the
     scope cards. This is the count, and it is a CONTROL.

     Auto-scroll was rejected: opening the dialog already focuses the brief (the
     pre-drafted paragraph he is meant to check first), and landing him mid-
     document with the brief off-screen trades one invisible thing for another.
     Moving the block up was rejected too: the body is 1812px and the visible
     window is 443px at 900x640, so "higher" is still below the fold — it would
     have relocated the defect, not removed it, and it costs the deliberate
     hand-on-the-button position for the captain who DOES read.

     A footer cue is the only option that holds at every viewport and every
     scroll position, including the one the tester actually used (scrollTop 0).
     It does not block the filing — a hard stop at the last click of a design
     session is the wrong shape, and the daemon carries an unanswered question
     into the Mission marked STILL OPEN. It makes filing without KNOWING
     impossible, which is the claim that failed. And it stays honest as he
     works: the count falls as he answers, and the warning clears when none are
     left, so it still means something on the day it fires. */
  var qcue = null;
  function syncQCue() {
    if (!qcue) return;
    var open = 0;
    qBoxes.forEach(function (q) {
      if (!String(q.box.value || "").trim()) open += 1;
    });
    var n = qBoxes.length;
    qcue.setAttribute("data-open", String(open));
    qcue.classList.toggle("open", open > 0);
    /* S169 FIX ROUND 2 — IT STOPPED CRYING WOLF.

       It read `⚠ N OPEN QUESTIONS UNANSWERED — READ THEM FIRST` in the amber
       warning language of the missing-requirement band, and on the 2026-08-07
       capstone that was the loudest thing in the dialog AND FALSE: both
       questions were settled in their own text and one of them was then
       re-asked at a real human gate the captain had already answered.

       It also fires at every single open, before he has had one second to
       answer anything — so it was a warning about a state that is guaranteed
       true at the moment it appears. That is the definition of a warning that
       trains you to click past it, and it sits beside ▦ FILE MISSION.

       What it says now is the count and the invitation, which is the job S128
       built it for (make filing without KNOWING they exist impossible). The ⚠
       and the amber are reserved for the two bands that report something
       MEASURED. */
    qcue.textContent = open
      ? "▸ " + open + " open question" + (open === 1 ? "" : "s")
        + " from the design session — read "
        + (open === 1 ? "it" : "them") + " before you file"
      : "✓ all " + n + " open question" + (n === 1 ? "" : "s") + " answered";
    qcue.title = open
      ? "They came out of designing this. Anything you leave blank is filed "
        + "with no answer recorded, quoted verbatim — you can send it either "
        + "way."
      : "Every open question from the design session has an answer.";
  }
  if (qBoxes.length) {
    qcue = holoBtn("Read the open questions", "qcue", function () {
      if (qField && qField.scrollIntoView) {
        qField.scrollIntoView({ behavior: "smooth", block: "start" });
      }
      var first = null;
      qBoxes.forEach(function (q) {
        if (!first && !String(q.box.value || "").trim()) first = q.box;
      });
      first = first || qBoxes[0].box;
      if (first && first.focus) first.focus();
    });
    qcue.setAttribute("data-holo", "handoff-qcue");
    qBoxes.forEach(function (q) {
      q.box.addEventListener("input", syncQCue);
    });
    syncQCue();
  }

  m.foot.className += " handoff-foot";
  m.foot.appendChild(err);
  if (qcue) m.foot.appendChild(qcue);
  m.foot.appendChild(el("span", "hint",
    "Files the Mission at Align, on the board, with the artifacts attached."));
  m.foot.appendChild(el("span", "grow"));
  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  /* ── THE DIALOG OPENS AT THE TOP OF HIS BRIEF (S169) ─────────────────────
     MEASURED, not reasoned about. Focusing a textarea makes the browser scroll
     it into view, and a 380px box in a 438px scrolling body does not fit with
     room to spare — so `brief.focus()` alone scrolled `.modal-body` down by
     234px and the captain met this dialog with the TOP OF HIS OWN WORDS 55px
     ABOVE the window. The draft had grown; the first thing on screen was the
     middle of it. Nothing in web/tests/ can see that (no CSS, no layout); it
     came off tests/drives/browser/handoff.sh at 1440x677 on the first run.

     The caret goes to character 0 first — so the browser has no reason to
     scroll anywhere — and the body is pinned back to the top afterwards
     regardless, because the ONE thing that must be true when this opens is
     that he is looking at line 1. */
  if (brief.setSelectionRange) {
    try { brief.setSelectionRange(0, 0); } catch (e) { /* not text-like */ }
  }
  if (brief.focus) brief.focus();
  brief.scrollTop = 0;
  /* ── ONE SCROLLER, AND IT IS THE MODAL BODY (S169 FIX ROUND 1) ────────────
     MEASURED in real Chrome, and it is the tester's "single biggest threat to
     the value proposition". The `rows` clamp sized the box in SOURCE LINES,
     and the draft's lines are long: at 1440x677 the box laid out 269px tall
     against 835px of content — 566px (68%) of the captain's own brief behind a
     NESTED inner scrollbar, inside a `.modal-body` that was itself hiding
     1,321px. The section he most needs to check, `## Implied by the mockup`,
     was dead last at the bottom of the INNER scroller. S128's "below the fold"
     had become "below the fold of an inner box", and `rows` cannot see it
     because wrapping is a layout fact.

     So the box takes the height of its LAID-OUT CONTENT and stops scrolling
     itself. `.modal-body` is then the only scroller in the dialog, one wheel
     gesture reaches every section, and the sticky footer (▦ FILE MISSION and
     the ⚠ open-questions cue) is untouched — it is a sibling of the body, not
     of this box.

     `rows` stays as the FLOOR for a short draft and as the pre-paint size, so
     nothing collapses to a slot before this runs. Re-run on input because he
     rewrites the brief — that is the whole point of it being a writing space —
     and a box that grew once and then trapped his own additions would be the
     same defect with his words in it. */
  function fitBrief() {
    brief.style.height = "auto";
    var want = brief.scrollHeight;
    if (!(want > 0)) return;
    brief.style.height = want + "px";
    /* …AND THEN CHECK, because `scrollHeight` and `height` do not measure the
       same rectangle and which ones they include depends on `box-sizing`. The
       first pass left the box exactly 2px short (its border) — a 2px inner
       scrollbar is still an inner scrollbar. Reading the residue back off the
       element beats hard-coding a box model that a later stylesheet can
       change. */
    var over = brief.scrollHeight - brief.clientHeight;
    if (over > 0) brief.style.height = (want + over) + "px";
  }
  fitBrief();
  brief.addEventListener("input", fitBrief);
  /* ── AND THE CHECK'S POLL STARTS **AFTER** THE DIALOG IS ON THE PAGE ──────
     Its own stop condition is `document.body.contains(band)` — the dialog has
     gone, so there is nobody to tell. `showOverlay` is what puts this dialog in
     the document, and it runs at the BOTTOM of this function; started from
     where the band is built, the very first call read "not on the page yet" and
     returned, and the band sat on "Reading these lines back against the
     mockup…" forever while the daemon's answer waited unread.

     Found by web/tests/board_holodeck_harness.js the moment `setTimeout` was
     recorded instead of swallowed — the previous stub returned 0 and dropped
     the callback, which cannot tell a wired poll from a dead one. */
  /* ── S172, SAID PLAINLY: THIS BRANCH IS NO LONGER REACHED FROM THE DECK ──
     `Send without the change list` was the only control that opened this
     dialog while a pass was in flight, and the captain has deleted it. Every
     remaining door — ▶ SEND TO ALIGN at `ready`, at `failed`, and at `off` —
     opens on a settled derivation, so `seed.derive.state` is not `running`.

     IT IS KEPT, NOT DELETED, and that is a deliberate call rather than an
     oversight: the running band, this poll and `briefLanded` are what make a
     door into the wait SAFE, and the hatch's own note says a cancel control is
     the honest thing to build if a hang is ever observed. Tearing the landing
     machinery out today would mean rebuilding it then. What must not happen is
     someone reading this branch as live product behaviour: it is not, until
     something opens this dialog during a pass again. */
  if ((seed.derive || {}).state === "running") {
    holoDerivePoll(seed, checkBox, picked, 1, briefLanded);
  }
  m.body.scrollTop = 0;
  return m;
}

/* Re-ask the daemon for the guidance when the build scope changes. The block
   is never rewritten on this side — one voice, and the words the captain reads
   are the words the Mission is given. */
function holoRefreshGuidance(seed, scope, box) {
  postWrite("/api/holodeck/" + seed.sessionId + "/promote", { scope: scope },
    function (state) {
      seed.guidance = state.guidance || seed.guidance;
      seed.scope = state.scope || scope;
      box.textContent = seed.guidance || "";
    }, function (msg) {
      /* IT SAYS SO. Leaving the previous scope's block on screen would be the
         one thing this pane exists to prevent — the captain reading one set of
         instructions while the Mission is given another. The dispatch still
         sends `holodeckScope`, so the daemon applies what he picked; what is
         lost is only the preview, and that is what this says. */
      box.textContent = "LCARS could not fetch the guidance for this choice ("
        + (msg || "no reason given") + "). The Mission will still be given the "
        + "guidance for \"" + scope + "\" — this box just cannot show it right "
        + "now. Pick the other option and back again to retry.";
    });
}

function holoEnd(sid) {
  postWrite("/api/holodeck/" + sid + "/end", {}, function () {
    if (HOLO.activeId === sid) HOLO.activeId = null;
    holoRefresh();
  }, function (msg) {
    holoSetBanner("offline", { message: msg });
    renderDeck();
  });
}

/* ── S126: picking a program back up ───────────────────────────────────────
   The daemon mints a NEW session and replays `transcript.md` into its opening
   prompt. The banner is the daemon's own account of that, verbatim (the
   one-voice rule S125 landed on): it says the worker is a fresh one carrying
   the history, and this side adds not one word — least of all a session id,
   which is precisely the kind of unfounded reassurance S125's finding #2 was
   about. */
/* FIX ROUND 5 — AND IT SENDS THE ENGINE THE PROGRAM WAS BUILT ON. This posted
   `{room}` alone, so the daemon had nothing but its own default to fall back
   on and a program designed on one CLI reopened on another — measured live,
   and the reverse direction spends real money.

   It relays a FACT or nothing: `engineRecorded` is the daemon's own answer to
   "does this program's record name an engine", and an explicit engine OUTRANKS
   the record. Sending the default here would pin the wrong CLI in the one
   place the rule cannot see it is a guess. */
function holoOpen(room, engine) {
  if (!room) return;
  var body = { room: room };
  if (engine) body.engine = engine;
  postWrite("/api/holodeck/open", body, function (state) {
    HOLO.activeId = state.sessionId;
    HOLO.banner = null;
    if (state.warmRestart && state.warmRestart.message) {
      holoSetBanner("restart", { message: state.warmRestart.message });
    }
    holoRefresh();
  }, function (msg) {
    holoSetBanner("offline", { message: msg });
    renderDeck();
  });
}

/* ── S172: duplicating a program, carrying its history ────────────────────
   The captain's ruling is that a duplicate BRINGS THE CHAT OVER, so the dialog
   says that before the button: what he gets is not a copy of the files, it is a
   NEW program that remembers the conversation and is editable from the first
   turn. It also states the two things that would otherwise be a surprise later
   — the original stays exactly as it was handed over, and the change list does
   NOT come over, because that list describes his project as it was when this
   design was filed.

   THE NAME FIELD IS EMPTY ON PURPOSE. The daemon owns room naming: it is the
   only side that can see which rooms are taken, and a duplicate is the one
   place in the product where a collision is likely (the obvious name is derived
   from one that already exists). Blank is the road that cannot collide; typing
   a name is the override, and a name whose room is taken is REFUSED there
   rather than written over. */
function holoConfirmDuplicate(p) {
  var room = p.room || holoBase(p.programDir);
  var sent = holoLifecycle(p) === "sent";
  var m = modal("⧉ Duplicate program", { headClass: "teal" });
  m.body.appendChild(el("p", null,
    "Duplicate " + (p.program || room) + " (" + room + ") into a new program?"));
  m.body.appendChild(el("p", null,
    "The copy carries the mockup, the concept doc, the grounding, anything you "
    + "pasted in — and the WHOLE conversation, so the holodeck can see why the "
    + "design looks the way it does. It opens as a draft you can type into "
    + "straight away, and nothing in that history is binding."));
  m.body.appendChild(el("p", null,
    (sent
      ? "This program stays locked and exactly as it was handed over"
        + (p.missionId ? " to mission " + p.missionId : "") + " — nothing here "
        + "touches it. "
      : "This program is left exactly as it is. ")
    + "The change list does not come over: it describes your project as it was "
    + "when this design was drafted, so the copy starts without one and offers "
    + "to work out a fresh one when you send it."));
  var f = el("div", "field");
  f.appendChild(label("Name for the copy"));
  var name = el("input");
  name.type = "text";
  name.placeholder = "leave blank and LCARS gives it a free name";
  name.setAttribute("data-holo", "duplicate-name");
  f.appendChild(name);
  m.body.appendChild(f);
  var err = el("div", "errline"); err.hidden = true;
  m.body.appendChild(err);
  var go = applyWriteState(holoBtn("⧉ Duplicate Program", "go", function () {
    go.disabled = true;
    go.textContent = "Duplicating…";
    var body = { room: room };
    if ((name.value || "").trim()) body.program = name.value.trim();
    postWrite("/api/holodeck/duplicate", body, function (state) {
      closeOverlay();
      /* STRAIGHT INTO THE NEW ROOM. The whole point of the gesture is to keep
         designing, and the daemon has already opened it (a fresh session, the
         transcript replayed) — leaving him on the locked card he clicked from
         would be the one place he cannot type. */
      HOLO.activeId = state.sessionId;
      HOLO.banner = null;
      if (state.duplicated && state.duplicated.message) {
        holoSetBanner("duplicated", { message: state.duplicated.message });
      }
      holoRefresh();
    }, function (msg) {
      go.disabled = false;
      go.textContent = "⧉ Duplicate Program";
      showErr(err, msg);
    });
  }));
  m.foot.appendChild(el("span", "grow"));
  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  return m;
}

/* ── S126: deleting a program, without deleting the work ──────────────────
   `git rm` + a commit, so the answer to "I removed the wrong one" is a
   checkout. The dialog says that BEFORE the button, because a confirmation
   whose only content is "are you sure?" makes the captain guess at the stakes.
   The daemon's reply then names the exact commit to check back out.

   FIX ROUND 3, DEFECT 1. This copy read "so nothing is destroyed … all stay in
   the sidecar's history and can be checked back out" — flatly, in advance, of a
   room that might never have been committed at all. That is the daemon's own
   lie one step earlier, and a confirmation is the worst place to tell it: it is
   the sentence the captain decides on. It now describes the mechanism the
   daemon actually runs — recorded first, removed second, and refused rather
   than destroyed if the recording cannot be made. */
function holoConfirmDelete(p) {
  var room = p.room || holoBase(p.programDir);
  // `red` — the tints the modal scaffold actually defines are red/teal/pink
  // (board.css :504). A headClass with no rule behind it is a header that
  // silently renders as the default one.
  // `■` — every CONSOLE TITLE in the product wears a flat, single-colour glyph
  // from the LCARS geometric family (test_help_console's D7 sweep). This one
  // shipped as `⌫`, a keyboard-key symbol from a different family entirely. ■
  // is already the product's HALT mark (■ STOP on the launch band and the
  // ● APP LIVE pill), which is the right note over a red destructive header.
  // The BUTTONS keep `⌫`: a control glyph names the gesture (erase), a title
  // glyph names the console — the deck already opens `⬡ New Program` from a
  // `＋ New Program` button on exactly that split.
  var m = modal("■ Remove program", { headClass: "red" });
  m.body.appendChild(el("p", null,
    "Remove " + (p.program || room) + " (" + room + ") from the deck?"));
  m.body.appendChild(el("p", null,
    "LCARS commits the whole program — the mockup, the transcript, the concept "
    + "doc — into the sidecar's git history FIRST, and only then removes the "
    + "room. It will tell you the exact command to check it back out. If it "
    + "cannot record the program, it refuses and removes nothing."));
  var err = el("div", "errline"); err.hidden = true;
  m.body.appendChild(err);
  var go = applyWriteState(holoBtn("⌫ Delete Program", "danger", function () {
    go.disabled = true;
    go.textContent = "Removing…";
    postWrite("/api/holodeck/delete", { room: room }, function (state) {
      closeOverlay();
      if (p.sessionId && HOLO.activeId === p.sessionId) HOLO.activeId = null;
      if (state && state.message) {
        holoSetBanner("removed", { message: state.message });
      }
      holoRefresh();
    }, function (msg) {
      go.disabled = false;
      go.textContent = "⌫ Delete Program";
      showErr(err, msg);
    });
  }));
  m.foot.appendChild(el("span", "grow"));
  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  return m;
}

/* ── D7: the failure states, in LCARS voice ────────────────────────────── */
/* ONE VOICE (fix round 2). The daemon's message is the whole account of what
   happened; this side supplies CHROME — the title, the colour, the RETRY
   control — and adds not one word of its own.

   Round 1 wrote a second copy beside the server's, and every failure then said
   everything twice: "your program is safe" and "the chat is still running"
   arrived once from here and once from the daemon, mid-sentence, and the
   refusal banner ran to 1208 characters with the stray path printed TWICE.
   Worse, this half still claimed the holodeck "never touches your project, and
   nothing out there has been changed or removed by LCARS" — an AUTHORSHIP
   claim, sitting directly above the server's carefully-cured "LCARS watches the
   files, not who touched them — it cannot tell whether the holodeck went
   outside its room or something else did". Two voices, and the louder one was
   the wrong one. The parallel copy is DELETED, not arbitrated. */
function holoSetBanner(kind, opts) {
  HOLO.banner = { kind: kind, opts: opts || {} };
}

/* kind → [class, title]. Chrome only; the text always comes from the daemon. */
var HOLO_BANNERS = {
  offline:    ["down",   "Holodeck offline"],
  refused:    ["refuse", "Write refused"],
  // the AUDIT degraded — LCARS could not walk the whole project, so it cannot
  // certify that nothing changed outside the room.
  unverified: ["refuse", "Turn not certified"],
  // the audit was FINE; the engine answered with the file instead of writing
  // it. Nothing to certify, nothing saved.
  "no-write": ["refuse", "Nothing was written"],
  notice:     ["note",   "This room already holds work"],
  /* S128 (FL-004) — A START THAT FAILED, said somewhere the dialog cannot take
     with it. `openNewProgram`'s error line dies the moment the dialog closes,
     and a first grounding pass is exactly when a captain wanders off, so a
     failed pass used to fail in total silence. This reuses the deck's OWN
     banner channel rather than adding a second notification path. */
  "start-failed": ["refuse", "The program did not open"],
  /* S126 — a program picked back up off disk. NOT titled "resumed": the warm
     worker session died with the daemon that held it and what is running now
     is a fresh one carrying the transcript. The daemon's message says exactly
     that; the title must not undo it. */
  restart:    ["note",   "Picked up where you left off"],
  /* S172 — a NEW program carrying an old one's history. NOT titled "copied":
     the chat came over too, which is the whole ruling, and the daemon's message
     is the account of what that means. */
  duplicated: ["note",   "Duplicated — a new program, carrying the chat"],
  removed:    ["note",   "Program removed — the archive kept it"],
};

/* A daemon `warning.kind` → the banner that tells the truth about it. Anything
   unknown falls back to the cautious one rather than going unannounced. */
var HOLO_WARNING_BANNER = {
  "no-write": "no-write",
  "audit-incomplete": "unverified",
  "end-audit-pending": "unverified",
};

function holoBannerNode() {
  var b = HOLO.banner;
  if (!b) return null;
  var o = b.opts || {};
  var kind = HOLO_BANNERS[b.kind];
  if (!kind) return null;
  var node = el("div", "holo-banner " + kind[0]);
  node.appendChild(el("span", "bl", kind[1]));
  node.appendChild(el("span", "bt", String(o.message == null ? "" : o.message)
    .trim() || "LCARS has nothing to add beyond that."));
  if (b.kind === "offline" && o.retry) {
    node.appendChild(applyWriteState(holoBtn("Retry turn", "danger",
      function () {
        HOLO.banner = null;
        // A RETRY IS THE SAME TURN — the same line AND the same screenshot
        // (S169). Dropping the images here would re-send a "make it look like
        // this" turn with nothing to look at. The ONE case where the retry
        // carries no image is the one the DAEMON already decided (fix round 1,
        // `sessionReset`): the attachment is what killed the session, and it is
        // dropped where `holoSay` builds this payload, not here.
        holoSay(o.retry.sid, o.retry.text, o.retry.images, o.retry.intent);
      })));
  }
  return node;
}

/* D7 · VIEW ONLY — the control is DISABLED WITH THE REASON, never silently
   absent. A missing button teaches nothing; a greyed one with no explanation
   teaches less. The banner says the same thing where it cannot be missed. */
function applyHolodeckWriteState() {
  var ro = writesActive === false;
  var reason = HOLO_RO_REASON;
  // S128: the control itself is painted by the ONE function that owns it (see
  // holoPaintBandBtn) — this half is the banner and the forced exit.
  holoPaintBandBtn();
  var host = document.getElementById("holoRoBanner");
  if (host) {
    host.innerHTML = "";
    host.hidden = !ro;
    if (ro) {
      host.appendChild(el("span", "bl", "View only"));
      host.appendChild(el("span", "bt", reason));
    }
  }
  if (ro && HOLO.on) holoSetMode(false);
}

/* ── S127: which engine a NEW program runs on ─────────────────────────────
   The captain opened the viewscreen with no $LCARS_WORKER_BIN and every
   program died on a 502 telling him to restart the daemon. The daemon has
   taken an engine on /api/holodeck/start since S124; nothing in front of him
   could name one, and he could not run one program on claude and the next on
   copilot without a restart in between.

   These four are the whole front-end rule, kept out of the dialog body so the
   dialog reads as a dialog. None of them RESOLVES anything — resolution is the
   daemon's (`_resolve_holodeck_engine` / `_program_engine`), and adding a
   second resolver here is how this feature has produced money bugs before. */

/* Which OFFERED engine the daemon itself was started on, or "" for none.
   `engineName` is a basename (`claude`, `copilot`, and in the wild a wrapper
   around either), so it is binned the same way the daemon bins it — the
   contains-"copilot" test in `_is_copilot`. That is a BINNING rule, not the
   tier table: the tiers arrive from the daemon in `HOLO.models` precisely so
   this file never carries a second copy of them. */
function holoDaemonEngine() {
  var name = String(HOLO.engineName || "").toLowerCase();
  if (!name) return "";
  return name.indexOf("copilot") !== -1 ? "copilot" : "claude";
}

/* THE MONEY DEFAULT. A daemon started with an engine keeps behaving exactly as
   it does today — its own engine is what sits preselected. With NOTHING
   configured the preselection is copilot, because the holodeck is explicitly
   the cheap room: copilot is free for this captain and claude is billed, so
   the option under his cursor on an unconfigured daemon must not be the one
   that spends. */
function holoDefaultEngine() { return holoDaemonEngine() || "copilot"; }

/* What to actually SEND for a picked engine. Picking the engine the daemon was
   started on sends that daemon's own binary, not the bare name: a wrapper at
   /opt/…/claude must not silently become whichever `claude` $PATH finds. */
function holoEngineBin(key) {
  return (key === holoDaemonEngine() && HOLO.engine) ? HOLO.engine : key;
}

/* "copilot claude-opus-4.8" — the engine and the tier it will really run at.
   The tier comes from the daemon's published table; with none published for
   that engine it names the engine and STOPS. A guess here is the readout-lie
   class the hardcoded "sonnet tier" already cost this feature once. */
function holoEngineTier(key) {
  var mine = key === holoDaemonEngine();
  var name = (mine && HOLO.engineName) ? HOLO.engineName : key;
  var model = (HOLO.models || {})[key] || (mine ? (HOLO.model || "") : "");
  return name + (model ? " " + model : "");
}

/* ── D12: ＋ NEW PROGRAM asks what, and what from ───────────────────────── */
/* The one question that decides whether the mock looks like your project or
   like a stranger's product. Declared, never inferred: only the captain knows
   whether a greenfield idea should inherit an existing app's language. */
function openNewProgram() {
  var m = modal("⬡ New Program", { headClass: "teal" });
  var err = el("div", "errline"); err.hidden = true;

  /* ONE SENTENCE, ONE FUNCTION (FL-001). The footer hint was assembled once
     while the dialog was being built and never rebuilt, so it lied in two
     directions the moment either choice moved:
       • the tier half read the DAEMON's engine — now the engine is picked
         right here, so it must follow the pick;
       • `· read-only` was appended unconditionally, and is simply false on
         Blank deck, where no pass over the captain's project happens at all.
     Both halves are DERIVED from (picked engine, picked mode) below, and every
     control that can change either one calls `paintFoot`. Deliberately NOT a
     second string beside the old one: S125 lost two fix rounds to exactly that
     shape, and so did S126's tool-trace stripper. */
  var footHint = el("span", "hint", "");
  function footSentence() {
    // what the START itself does to the captain's project, per mode. Only
    // `grounding` reads it, so only `grounding` may claim a read-only read.
    var lead = picked.val === "grounding" ? "One cheap pass"
             : picked.val === "screenshot" ? "One cheap pass over your screenshot"
             : "Nothing is read from your project";
    var parts = [lead, holoEngineTier(chosenEngine.val)];
    if (picked.val === "grounding") parts.push("read-only");
    return parts.join(" · ");
  }
  function paintFoot() { footHint.textContent = footSentence(); }

  var f1 = el("div", "field");
  f1.appendChild(label("What are we designing?"));
  var name = el("input");
  name.type = "text";
  name.placeholder = "A tile picker sidebar for the room editor";
  name.setAttribute("data-holo", "program-name");
  f1.appendChild(name);
  m.body.appendChild(f1);

  var f2 = el("div", "field");
  f2.appendChild(label("Start from"));
  var choices = el("div", "choices");
  var picked = { val: "grounding" };
  // S124's holodeck_start REJECTS images with a 400, so the screenshot option
  // is not a control that errors when clicked — it is visibly off, with the
  // reason. The alternative (hide it) loses the fact that this is the road the
  // captain asked for and it is coming.
  //
  // S169 FIX ROUND 1 — AND THE REASON WAS MADE STALE BY THIS SESSION. It read
  // "the holodeck cannot take pasted images yet, so this would fail the moment
  // you clicked Run", four inches from a composer that this session taught to
  // take a pasted screenshot and that WORKS. The captain reads one product, so
  // one of the two had to become true: the START road still refuses (nothing
  // here opens a program from an image), and its refusal now says WHERE paste
  // does work instead of denying the feature exists.
  var OPTS = [
    ["grounding", "▣", "This project's look",
     "One read-only pass over " + holoRepoName() + " to learn how it already "
     + "looks — colours, type, spacing, and the shape of its existing "
     + "components — so the new flow arrives looking like it belongs. Reads "
     + "only. Never writes to your project.", true, null],
    ["screenshot", "◫", "A screenshot",
     "Paste a picture of the screen you are changing. For a look that is not "
     + "in the repo — a design elsewhere, a competitor, a sketch.", false,
     "Not yet: a program cannot be STARTED from an image. Open it on one of "
     + "the other two roads, then paste the screenshot straight into the chat "
     + "on your first turn — the composer takes it."],
    ["design", "⬡", "Blank deck",
     "Nothing exists yet. Start from the LCARS look and invent from there.",
     false, null],
  ];
  OPTS.forEach(function (o) {
    var key = o[0], off = o[5];
    var card = el("div", "choice-card"
      + (key === picked.val ? " sel" : "") + (off ? " off" : ""));
    card.appendChild(el("span", "ci", o[1]));
    var cc = el("span", "cc");
    var t = el("span", "ct2", o[2]);
    if (o[4]) t.appendChild(el("span", "rec", "Recommended"));
    cc.appendChild(t);
    cc.appendChild(el("span", "cd", o[3]));
    if (off) cc.appendChild(el("span", "why", "⚠ " + off));
    card.appendChild(cc);
    card.setAttribute("data-choice", key);
    if (off) {
      holoCtl(card, o[2], null, off);
    } else {
      keyActivable(holoCtl(card, o[2], function () {
        picked.val = key;
        Array.prototype.forEach.call(choices.children, function (c) {
          c.classList.remove("sel");
          c.setAttribute("aria-pressed", "false");
        });
        card.classList.add("sel");
        card.setAttribute("aria-pressed", "true");
        // FL-001: this handler used to move the `sel` class and nothing else,
        // which is why the footer sentence was frozen at whatever it read when
        // the dialog opened — including "read-only" for a Blank deck.
        paintFoot();
      }));
      card.setAttribute("aria-pressed", key === picked.val ? "true" : "false");
    }
    choices.appendChild(card);
  });
  f2.appendChild(choices);
  m.body.appendChild(f2);

  /* S127 — THE ENGINE PICKER. Same markup, classes and interaction as the File
     console's own picker (`.field` / `.choice` / `.opt` / `sel` /
     aria-pressed / keyActivable): it is the picker the captain already knows,
     and S140 made that one keyboard-operable — Tab to it, Enter/Space selects
     — which a new mouse-only picker would quietly regress. */
  var f3 = el("div", "field");
  f3.appendChild(label("Engine — which CLI runs this program?"));
  var echoice = el("div", "choice");
  var chosenEngine = { val: holoDefaultEngine() };
  var optClaude = keyActivable(el("span", "opt", "⬡ Claude"));
  var optCopilot = keyActivable(el("span", "opt", "⬡ Copilot"));
  function pickEngine(engine, node) {
    chosenEngine.val = engine;
    [optClaude, optCopilot].forEach(function (o) {
      o.classList.remove("sel");
      o.setAttribute("aria-pressed", "false");
    });
    node.classList.add("sel");
    node.setAttribute("aria-pressed", "true");
    paintFoot();
  }
  optClaude.addEventListener("click", function () {
    pickEngine("claude", optClaude);
  });
  optCopilot.addEventListener("click", function () {
    pickEngine("copilot", optCopilot);
  });
  echoice.appendChild(optClaude); echoice.appendChild(optCopilot);
  f3.appendChild(echoice);
  m.body.appendChild(f3);
  // the INITIAL selection goes through the same one function every later click
  // does — no second block setting `sel` and aria-pressed by hand, which is
  // where a picker's default and its clicks drift apart.
  pickEngine(chosenEngine.val,
             chosenEngine.val === "copilot" ? optCopilot : optClaude);

  m.body.appendChild(err);

  /* S128 (FL-004) — THE DIALOG'S THINKING INDICATOR, in the captain's own
     words: "the dialog itself needs a thinking icon as well". A grounding pass
     spawns a worker and can run for a minute; the only busy state was the
     button's label, which is a very quiet thing to stare at.

     It is the SAME `.holo-working` the chat pane renders — one working idiom in
     this feature, not two — and it is built once here rather than on click, so
     the failure path has something to hide again. */
  var busy = holoWorkingNode("Opening the deck — the first pass reads your "
                             + "project and can take a minute.");
  busy.hidden = true;
  m.body.appendChild(busy);

  m.body.appendChild(el("div", "hint",
    "Whatever it learns, you can see: a grounding pass writes what it found "
    + "into the program as basis.md — the actual tokens, not a description of "
    + "them. A grounding you cannot inspect is one you cannot correct."));

  var go = applyWriteState(holoBtn("⬡ Run Program", "go big", function () {
    var nm = String(name.value || "").trim();
    if (!nm) { showErr(err, "Say what you are designing first."); return; }
    go.disabled = true;
    go.textContent = "Opening the deck…";
    err.hidden = true;
    busy.hidden = false;
    postWrite("/api/holodeck/start",
      { program: nm, mode: picked.val, engine: holoEngineBin(chosenEngine.val) },
      function (state) {
        closeOverlay();
        HOLO.activeId = state.sessionId;
        HOLO.banner = null;
        // A ROOM THAT ALREADY HOLDS WORK IS DISCLOSED, NOT DISCOVERED. End a
        // program and re-create the same name and the "new" one adopts the old
        // room — `turnCount: 0` beside the previous program's mockup in the
        // preview. Silence was the defect; the daemon says what is in there and
        // this puts it where he cannot miss it, before his first word.
        if (state.roomNotice && state.roomNotice.message) {
          holoSetBanner("notice", { message: state.roomNotice.message });
        }
        holoSetMode(true);
      },
      function (msg) {
        go.disabled = false;
        go.textContent = "⬡ Run Program";
        busy.hidden = true;
        showErr(err, msg);
        /* S128 (FL-004) — AND SOMEWHERE THAT OUTLIVES THIS DIALOG. The line
           above is the whole account of the failure while the dialog is open,
           and dies with it: close it and a grounding pass that FAILED failed
           in silence — no banner, no board signal, nothing the captain would
           ever see. This is the deck's existing banner channel, not a second
           notification path, so there is still one place a holodeck failure
           is reported. renderDeck is unconditional: the banner belongs in the
           deck host whether or not the deck is the visible half right now. */
        holoSetBanner("start-failed", { message: msg });
        renderDeck();
      });
  }));
  // WHAT WILL ACTUALLY RUN — the one sentence `footSentence` derives, already
  // painted by the initial `pickEngine` above. The tier half comes from the
  // daemon's own `_holodeck_model` (published per engine), never a copy of it
  // here: this line was once the hardcoded "One cheap pass · sonnet tier ·
  // read-only", which is false on copilot AND false on a Blank deck.
  m.foot.appendChild(footHint);
  m.foot.appendChild(el("span", "grow"));
  m.foot.appendChild(btn("Cancel", null, closeOverlay));
  m.foot.appendChild(go);
  showOverlay(m.wrap);
  if (name.focus) name.focus();
  return m;
}

/* ════════════════ boot ════════════════ */
document.getElementById("fileBtn").addEventListener("click", openFile);
/* S139: the ▸ Deploy Main button, wired next to the File control. Defensive: a
   build without the button (older index.html) simply skips the wiring. */
var deployMainBtn = document.getElementById("deployMainBtn");
if (deployMainBtn) deployMainBtn.addEventListener("click", openDeployMain);
/* S141: the band's ? control, opening the very console the ? key opens. It is
   deliberately NOT run through applyWriteState — help is read-only, and a
   view-only board needs it most. Defensive like the deploy wiring above. */
var helpBtn = document.getElementById("helpBtn");
if (helpBtn) helpBtn.addEventListener("click", openHelp);
/* S125 (D1): the ⬡ HOLODECK control. ONE control for both directions — it reads
   ▦ BOARD while the deck is up. Defensive like the wirings above: an older
   index.html without the button simply has no deck. */
var holodeckBtn = document.getElementById("holodeckBtn");
if (holodeckBtn) {
  holodeckBtn.addEventListener("click", toggleHolodeck);
  applyHolodeckWriteState();
}
brandPADD();
refresh();
connect();
probeWrites();
