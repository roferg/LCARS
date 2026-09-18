"""Build the phone-width fixture for tests/lcars-xo-phone.test.sh.

    python3 mkfixture.py <outdir> <repo-root> [<extra.css file>]

It copies the SHIPPING board (index.html, board.js, board.css, lcars.css) into
<outdir>, rewrites its absolute asset paths so it loads off the filesystem, and
injects two things and only two:

  1. a `fetch` stub, BEFORE board.js, so the board, the First Officer's report
     and one mission's detail come back canned — no daemon, no network, no gh;
  2. a probe, AFTER board.js, that walks the captain's OWN path to the surface
     under test (the band control → its menu → the report → a mission header →
     that mission on its ◈ Number One tab), measures the result against the
     viewport, and posts the numbers to the parent page.

The parent page is `outer.html`: it holds the board in an IFRAME EXACTLY 390 CSS
PX WIDE, because that is the viewport the defect was measured at and macOS will
not give a real Chrome window narrower than 500 px. An iframe's own width is
what its media queries resolve against, so 390 here is 390 there.

An optional third argument is a CSS file injected LAST, after board.css — how
the test defeats its own cure to prove the defect is really the cure's doing.

Nothing in here is product code: the product is what it loads.
"""
import shutil
import sys, json, os
SP, R = sys.argv[1], sys.argv[2]
os.makedirs(os.path.join(SP, "phone"), exist_ok=True)
for src, name in ((os.path.join(R, "web/static/board.css"), "board.css"),
                  (os.path.join(R, "web/static/board.js"), "board.js"),
                  (os.path.join(R, "docs/lcars.css"), "lcars.css")):
    shutil.copyfile(src, os.path.join(SP, "phone", name))
EXTRA = open(sys.argv[3]).read() if len(sys.argv) > 3 else ""
idx = open(os.path.join(R, "web/static/index.html")).read()
idx = idx.replace('href="/', 'href="').replace('src="/', 'src="')
LONG_WHY = ("I could not check the main thing you asked for — your test suite "
            "never ran, so nothing about the new methods was actually verified. ") * 4

LONG_VERDICT = ("Captain, I could not check the main thing you asked for: your "
                "test suite never ran, so nothing about the new methods was "
                "actually verified. ") * 6
VERDICT = {
  "score": "medium", "derivation": LONG_VERDICT,
  "scoreMeaning": "I could not check anything on your list, so nothing here is vouched for",
  "summary": LONG_VERDICT,
  "counts": {"met": 0, "gap": 0, "untested": 1, "contradictions": 0},
  "criteria": [
    {"id": "prd-1", "text": "worldToScreen converts a world point to a screen point",
     "status": "untested", "evidence": "none", "note": "your test suite never ran",
     "primary": True}],
  "gaps": [], "alsoChecked": ["The header and the map canvas paint as before.",
    "It ran " + ("worldToScreenSpec" * 18)],
}
XOBLOCK = {"status": "engaged", "engine": "copilot", "score": "medium",
           "headline": LONG_VERDICT,
           "meaning": "I could not check anything on your list, so nothing here is vouched for"}
MISSION = {"id": "lcars-20260917-401", "issue": 8, "stage": "implement",
           "title": "Add worldToScreen / screenToWorld to the engine camera",
           "numberOne": dict(XOBLOCK, report={"score": "medium", "status": "engaged",
                                              "engine": "copilot", "verdict": VERDICT,
                                              "logs": [], "shotsDir": "look-1",
                                              "journal": []})}
CARD = dict(MISSION,
            pills={"cost": {"label": "$0.42–$1.44", "level": "low"},
                   "reasoning": {"label": "REASON LOW", "level": "low"},
                   "implementation": {"label": "IMPL LOW", "level": "low"}},
            status="", tickets=[], waves=[])

payload = {
  "counts": {"needs": 1, "all": 3},
  "missions": [
    {"id": "lcars-20260917-202", "issue": 3, "title": "Editor shell UI audit",
     "needsYou": True, "newCount": 2, "score": "low",
     "entries": [
       {"key": "a1", "at": "2026-09-17T04:41:00Z", "rank": "needs-you",
        "action": "escalated", "detail": "a bug it filed stopped before it could be fixed"},
       {"key": "a2", "at": "2026-09-17T04:35:00Z", "rank": "verdict", "action": "scored",
        "score": "low", "why": "a black box hides the import button"}]},
    {"id": "lcars-20260917-201", "issue": 8,
     "title": "worldToScreen / screenToWorld", "needsYou": False,
     "newCount": 1, "score": "medium",
     "entries": [
       {"key": "b1", "at": "2026-09-17T05:58:59Z", "rank": "verdict",
        "action": "scored", "score": "medium", "why": LONG_WHY,
        "steps": ["launched the build", "took 3 pictures"]}]}],
  "since": {"entries": []}, "history": {"missions": []},
}
stub = """<script>
(function () {
  var REPORT = %s;
  var BOARD = %s;
  var MISSION = %s;
  window.fetch = function (path) {
    var p = String(path);
    var body = p.indexOf("/api/xo/report") >= 0 ? REPORT
             : (p.indexOf("/api/mission/") >= 0 ? MISSION : BOARD);
    return Promise.resolve({ ok: true, status: 200,
      json: function () { return Promise.resolve(body); },
      text: function () { return Promise.resolve(JSON.stringify(body)); } });
  };
  window.EventSource = function () { this.close = function () {}; this.addEventListener = function () {}; };
})();
</script>
""" % (json.dumps(payload),
        json.dumps({"missions": [CARD],
                    "meta": {"numberOne": {"enabled": True, "engine": "copilot"},
                             "writes": True}}),
        json.dumps(MISSION))
measure = """<script>
(function () {
  function click(sel, match) {
    var ns = document.querySelectorAll(sel);
    for (var i = 0; i < ns.length; i++) {
      if (!match || (ns[i].textContent || "").indexOf(match) >= 0) {
        ns[i].click(); return true;
      }
    }
    return false;
  }
  function box(sel) {
    var n = document.querySelector(sel);
    if (!n) return null;
    var r = n.getBoundingClientRect();
    return { w: Math.round(r.width), left: Math.round(r.left),
             right: Math.round(r.right) };
  }
  function measure(out) {
    out.viewport = window.innerWidth;
    out.cards = document.querySelectorAll(".card").length;
    out.boardText = (document.getElementById("board") ? document.getElementById("board").textContent : "").slice(0, 60);
    out.pageScrollWidth = document.documentElement.scrollWidth;
    out.modal = box(".modal");
    out.stage = box(".overlay-stage");
    out.grid = box(".detail-grid");
    out.also = box(".xo-also-line");
    out.tabs = box(".tabs") || box(".det-tabs");
    out.pane = box(".xo-pane");
    out.scoreWord = box(".xo-score-word");
    out.lede = box(".xo-lede");
    out.critRow = box(".xo-crit-row");
    out.untestedPill = box(".xo-score.s-medium");
    var mh = document.querySelector(".modal-head");
    out.modalHead = mh ? (mh.textContent || "").slice(0, 40) : null;
    var wides = [], all = document.querySelectorAll(".modal, .modal *");
    for (var i = 0; i < all.length; i++) {
      var r = all[i].getBoundingClientRect();
      if (r.width > window.innerWidth + 1 || r.left < -1 ||
          r.right > window.innerWidth + 1) {
        wides.push({ cls: String(all[i].className || all[i].tagName).slice(0, 40),
                     w: Math.round(r.width), left: Math.round(r.left),
                     right: Math.round(r.right) });
      }
    }
    out.overflowing = wides.slice(0, 12);
    var vl = document.querySelector(".xo-verdict-line");
    if (vl) {
      var vr = vl.getBoundingClientRect(), cs = getComputedStyle(vl);
      out.cardLine = { h: Math.round(vr.height), clamp: cs.webkitLineClamp,
                       overflow: cs.overflow, ellipsis: cs.textOverflow,
                       lineHeight: cs.lineHeight, chars: (vl.textContent || "").length };
    }
    say(out);
  }
  function say(out) {
    var s = "PROBE " + JSON.stringify(out);
    if (window.parent !== window) window.parent.postMessage(s, "*");
  }
  // THE CAPTAIN'S OWN PATH to this surface: the band control opens its menu,
  // the menu opens the First Officer's report, and a mission header in the
  // report opens that mission ON ITS ◈ NUMBER ONE TAB — which is the surface
  // under test. (The card's own `⊙ Read the full report` lands in exactly the
  // same place, by the same openDetail call.)
  setTimeout(function () {
    var out = {};
    out.cardOpened = click(".btn.xo-read-report");
    if (!out.cardOpened) {
      var b = document.getElementById("xoBtn");
      if (b) b.click();
      setTimeout(function () {
        out.menuOpened = click(".overlay button", "First Officer");
        setTimeout(function () {
          out.missionOpened = click(".xo-mopen");
          setTimeout(function () { measure(out); }, 700);
        }, 400);
      }, 300);
    } else {
      setTimeout(function () { measure(out); }, 700);
    }
  }, 700);
})();
</script>
"""
marker = '<script src="board.js"></script>'
assert marker in idx
if EXTRA:
    inner = idx.replace("</head>", "<style>%s</style></head>" % EXTRA, 1)
else:
    inner = idx
inner = inner.replace(marker, stub + marker + measure, 1)
open(os.path.join(SP, "phone/inner.html"), "w").write(inner)
outer = """<!doctype html><html><body style="margin:0;background:#111">
<iframe id="f" src="inner.html" style="width:390px;height:844px;border:0"></iframe>
<pre id="result">pending</pre>
<script>window.addEventListener("message", function (e) {
  document.getElementById("result").textContent = String(e.data);
});</script></body></html>"""
open(os.path.join(SP, "phone/outer.html"), "w").write(outer)
print("ok")
