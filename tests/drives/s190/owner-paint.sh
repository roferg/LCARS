#!/usr/bin/env bash
# ============================================================================
# S190 fix round 1 — THE OWNER TREATMENT, MEASURED IN PIXELS.
#
#   bash tests/drives/s190/owner-paint.sh
#   bash tests/drives/s190/owner-paint.sh --calibrate   # the RED CONTROLS
#   bash tests/drives/s190/owner-paint.sh --all
#
# S196 HALF B EXTENDED IT RATHER THAN BUILDING A SECOND RIG — the file keeps its
# S190 name because it is the same drive asking the same question of more of the
# board. Three defects were added to its subject, and one FIXTURE:
#
#   B1  OWNERSHIP WAS ENCODED IN COLOUR ALONE. amber = mine, blue = someone
#       else's, 1.51:1 apart with the colour removed — the same pill to a
#       greyscale screenshot, a projector, and a red-green colourblind reader.
#       Proven by DESATURATING the page in real Chrome and re-reading the pixels
#       through the filter (and by proving the filter bit: r == g == b).
#   B2  A REMOTE mission's controls were `opacity:.4/.7` on a saturated fill —
#       1.79:1 against the live Adopt beside them, i.e. the same button, which
#       is S191's D4 verbatim on the one surface S191 left out because it needed
#       a remote fixture. They now take the SAME `.btn.locked` treatment.
#   B3  …and the CARD stops drawing them at all (captain ruling: hide Verify,
#       offer only Adopt).
#   S196 BEAM  A PORTRAIT THAT HAD NOT ARRIVED YET WAS A HOLE. `ownerNode()`
#       degraded a FAILED avatar and never a PENDING one, so an in-flight (or
#       lazily-deferred) portrait painted a flat dark disc at rest — the exact
#       hole the .dead degrade exists to prevent, reachable without anything
#       ever erroring. Proven by HOLDING the avatar's own GET with CDP's
#       `Fetch.enable`, so the real board sits in the real pending state and
#       the disc can be read and photographed in it; plus the RENDERED BOXES
#       of the disc and the portrait inside it, which is the only way to see
#       the specificity trap (`.beam img` (0,1,1) losing to `.owner .owner-av
#       img` (0,2,1) and painting the portrait out of round).
#   B5  THERE WAS NO WAY TO FILTER THE BOARD BY OWNERSHIP. Four facets — mine /
#       someone else's / unassigned / remote — proven ON THE REAL PAGE: the
#       chips paint solid-vs-hollow (the same axis as B1 and the lock), each
#       chip's count is what the board actually DRAWS, the `o` key is dispatched
#       at the browser through the real hotkey layer, the choice survives a real
#       `Page.reload` out of real localStorage, and a payload that stops
#       carrying an identity shows the WHOLE board rather than none of it.
#       And the constraint the whole thing lives under: 50 filter applications,
#       0 page fetches, `gh` invocations 1 -> 1 — S152's one cached listing per
#       cycle, never per render, counted off this rig's own shim log.
#
# THE REMOTE FIXTURE IS A `gh issue list` THAT ANSWERS. A remote card cannot be
# planted on disk — being absent from disk is what makes it remote — so the gh
# shim serves two rows from a file and every other gh call still exits 1. Still
# zero spend: no network, no engine, one `cat`.
#
# WHY A BROWSER, AND WHY PIXELS. Round 1 returned three CSS defects that EVERY
# suite in this repo is structurally blind to, and one of them is the purest
# example the project has produced:
#
#   D2  `.card.owned-by-other .card-ctrl{opacity:.55}` makes a COMPOSITING
#       GROUP. The child rule `button[disabled]{opacity:1}` therefore CANNOT
#       raise the button back out of it. `getComputedStyle(button).opacity` says
#       "1". The screen says 55%. A rule-exists test is green, a computed-style
#       test is green, and the comment beside the rule promises a legibility
#       guarantee the cascade cannot keep.
#   D3  `.det-head .owner{margin:0}` styles an element the app never renders in
#       that place at all — `ownerNode()` is only ever called from `cardNode()`.
#   D6  a saturation `filter` was being reset under
#       `@media (prefers-reduced-motion:reduce)`. Colour is not motion.
#
# So: real daemon, real board.js, real board.css, real Chrome, and the verdict
# on D2 is read off the SCREENSHOT — the ink-to-paper contrast of the actual
# painted pixels inside the locked control, not any number the cascade reports.
#
# ZERO SPEND. No engine binary is ever invoked; `claude`/`copilot`/`gh` on PATH
# are logging shims that exit 1, the identity is pinned with $LCARS_GH_USER, and
# the owner cache is planted on disk. The ONE network call is the shipping
# board's own `https://github.com/<login>.png?size=64` avatar fetch — a public
# image GET, which is what the product does; if it does not load, the avatar
# checks SKIP LOUDLY and are never reported as a pass.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }
skip() { printf '\n\033[33mSKIP\033[0m — %s\n\n' "$*"; exit 77; }

WORK="${LCARS_S190_PAINT_OUT:-}"
if [ -z "$WORK" ]; then
  n=0
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-s190-paint.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-s190-paint.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-s190-paint.XXXXXX")"
fi
mkdir -p "$WORK"

PY_BIN="${LCARS_PY_BIN:-python3}"
NODE_BIN="${LCARS_NODE_BIN:-node}"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
command -v "$PY_BIN"   >/dev/null 2>&1 || skip "no python3"
command -v "$NODE_BIN" >/dev/null 2>&1 || skip "no node"
[ -x "$CHROME" ] || skip "no real Chrome at: $CHROME (set LCARS_BROWSER_CHROME). NOT a pass."

# ── one run of the whole drive against a given web/ dir ─────────────────────
# $1 = web dir · $2 = run name → sets RC and LOG.
run_against() {
  local web="$1" name="$2"
  local out="$WORK/$name"
  mkdir -p "$out"
  LOG="$WORK/$name.log"

  # ---- zero-spend PATH shims, and a gh that shadows the real one ----------
  mkdir -p "$out/shim"
  local eng
  for eng in claude copilot gh; do
    cat >"$out/shim/$eng" <<EOF
#!/usr/bin/env bash
echo "$eng \$*" >>"$out/shim.log"
exit 1
EOF
    chmod +x "$out/shim/$eng"
  done
  : >"$out/shim.log"

  # ---- S196 (B2/B3/B4): THE REMOTE FIXTURE ------------------------------
  # A remote card cannot be planted on disk — being ABSENT from disk is what
  # makes it remote. It exists only as an OPEN issue the forge lists, so the
  # only honest fixture is a `gh issue list` that answers. This drives the real
  # remote.RemoteMissions → github_adapter.card_from_issue → board.js path end
  # to end; nothing about the overlay is stubbed.
  #
  # TWO ROWS, and each is a different half of the defect:
  #   #201 verify   — ADOPTABLE. The card the tester shot: a dead `▶ START`
  #                   beside the live Adopt, 1.79:1 apart. S197 gave it a
  #                   HANDOFF ENVELOPE naming `copilot`, because the adopt
  #                   engine picker's default is the engine the mission was
  #                   FILED on and a body with no envelope can never say what
  #                   that was. Both CLIs are on this PATH (the shims above),
  #                   so this row is the TWO-CLI LAPTOP — the case the CLI
  #                   decides silently and the captain has never seen.
  #   #202 research — NOT adoptable. The worse card: ONE control, dead, and no
  #                   Adopt at all. After B3 it must offer nothing.
  #   #106 CLOSED   — NOT a remote card at all, and that is the point. It is
  #                   the issue belonging to the LOCAL mission `m-shipped-mine`
  #                   below: laptop B merged it, so GitHub closed it (the PR
  #                   body carries `Closes #106`) and `lcars approve` relabelled
  #                   it `lcars:done`. This laptop's `.git/lcars` still says
  #                   verify. Two live two-laptop runs found exactly this card
  #                   offering a live `✓ Review PR ▸` for a merged PR. It must
  #                   draw NO second card (local wins) and it must WITHDRAW that
  #                   control on the local one.
  # BOTH UNASSIGNED on purpose — `.card.owned-by-other` must keep meaning the
  # S190 lock and nothing else, so the S190/S191 checks above measure exactly
  # the cards they were written for.
  cat >"$out/remote-issues.json" <<'JSONEOF'
[
  {"number":201,"title":"Remote — driven on the other laptop","state":"OPEN",
   "labels":[{"name":"lcars:mission"},{"name":"lcars:verify"}],
   "body":"A mission being driven from another machine.\n\n<!-- lcars:handoff v1 {\"id\":\"lcars-20260909-201\",\"branch\":\"lcars/lcars-20260909-201\",\"base\":\"main\",\"type\":\"feature\",\"engine\":\"copilot\",\"parentIssue\":null,\"attachments\":0} -->",
   "updatedAt":"2026-09-08T10:00:00Z","assignees":[],
   "subIssuesSummary":{"completed":0,"total":0,"percentCompleted":0}},
  {"number":202,"title":"Remote — mid-pipeline, nothing to offer","state":"OPEN",
   "labels":[{"name":"lcars:mission"},{"name":"lcars:research"}],
   "body":"A mission being driven from another machine.",
   "updatedAt":"2026-09-08T09:00:00Z","assignees":[],
   "subIssuesSummary":{"completed":0,"total":0,"percentCompleted":0}},
  {"number":106,"title":"Shipped — merged on the other laptop","state":"CLOSED",
   "labels":[{"name":"lcars:mission"},{"name":"lcars:done"}],
   "body":"This mission's PR merged on the other laptop.",
   "updatedAt":"2026-09-09T18:00:00Z","assignees":[{"login":"roferg"}],
   "subIssuesSummary":{"completed":0,"total":0,"percentCompleted":0}}
]
JSONEOF
  # …and the ONE gh call the overlay makes, answered from that file. Every OTHER
  # gh invocation still exits 1: the identity is pinned with $LCARS_GH_USER and
  # the owners are planted on disk, so a gh that could also answer those would be
  # faking a layer this drive is not about. Still ZERO SPEND — no network, no
  # engine, one `cat`.
  cat >"$out/shim/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$out/shim.log"
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  cat "$out/remote-issues.json"
  exit 0
fi
exit 1
EOF
  chmod +x "$out/shim/gh"

  # ---- the fixture: two missions, one MINE, one SOMEBODY ELSE'S ----------
  # Planted with web/tests/_fixtures.py, the same planter every unit suite uses,
  # so the cards on screen are the cards those suites reason about. Both sit at
  # `verify`, which is the stage whose control row carries a real action — a
  # locked card with nothing in its control row would prove nothing about how a
  # locked control paints.
  local fixture="$out/fixture"
  mkdir -p "$fixture"
  "$PY_BIN" - "$REPO" "$fixture" <<'PYEOF' || return 77
import sys, os
repo, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "web"))
from tests import _fixtures as fx
fx.plant_simple(root, "m-mine", stage="verify", issue=101,
                title="Mine — the board is fully live here",
                created="2026-06-01T10:00:00Z",
                pr_url="https://github.com/acme/repo/pull/7", pr_number="7",
                review="open")
fx.plant_simple(root, "m-theirs", stage="verify", issue=102,
                title="Theirs — watch, do not drive",
                created="2026-06-02T10:00:00Z",
                pr_url="https://github.com/acme/repo/pull/8", pr_number="8",
                review="open")
# S191 fix round 1 (D4): THE PAIR THE DEFECT IS ABOUT. Two missions at the SAME
# stage, in the SAME column, differing in exactly one fact — who owns them — so
# the two cards can be shot at identical framing and compared by eye and by
# pixel. `align` is the stage whose control row is a plain live `▶ Start`, and
# START was the button the capstone reported as reading fully actionable while
# locked. The verify pair above stays: its ⊘ label is the smallest type in any
# control row and is what the contrast floor is measured on.
fx.plant_simple(root, "m-align-mine", stage="align", issue=103,
                title="Mine — I can drive this",
                created="2026-06-03T10:00:00Z")
fx.plant_simple(root, "m-align-theirs", stage="align", issue=104,
                title="Theirs — I cannot drive this",
                created="2026-06-04T10:00:00Z")
# S196 B5 FIX ROUND 1 — THE DONE CARD, and it is the entire fixture for that
# defect. `assemble()` (web/lcars_serve/board.py) puts EVERY card in its Stage
# column, done included, but keeps done OUT of `board.missions`, because that
# list backs the "N active missions" count. With no done card on the board the
# two populations are IDENTICAL and a footer counting the wrong one reads
# perfectly correct — which is why 53 unit tests and this drive both missed it.
# With one: 7 cards on the board, 3 of them mine, 6 active. Assigned to ME on
# purpose, so it moves the NUMERATOR as well; a done card owned by somebody
# else would only have moved the denominator.
fx.plant_simple(root, "m-done-mine", stage="done", issue=105,
                title="Mine — finished, and still on the board",
                created="2026-06-05T10:00:00Z")
# THE MISSION THAT SHIPPED FROM SOMEWHERE ELSE. Local, at verify, with an open
# PR recorded — i.e. IDENTICAL on disk to `m-mine` above, which is the whole
# design of the fixture: the two cards differ in exactly one fact, and that fact
# lives only on the forge (issue #106 is CLOSED and wears `lcars:done`; #101 is
# not in the listing at all). Anything that paints differently between them is
# the cure, and nothing else can be.
fx.plant_simple(root, "m-shipped-mine", stage="verify", issue=106,
                title="Mine — but it already shipped from the other laptop",
                created="2026-06-06T10:00:00Z",
                pr_url="https://github.com/acme/repo/pull/9", pr_number="9",
                review="open")
# S197 — THE PROVENANCE HALF. A mission that was adopted here with the engine
# CHOSEN at the handoff. `engineSource: adopt-chosen` is what a deliberate human
# answer is recorded as, and "chosen at adopt" is what the card must then print
# — the other half of the picker, and the one that stops a captain's own choice
# reading on the card as a mechanical conversion.
fx.plant_simple(root, "m-adopted-chosen", stage="align", issue=107,
                title="Adopted here — the engine was CHOSEN at the handoff",
                created="2026-06-07T10:00:00Z", worker_bin="claude")
import json as _json
_sp = os.path.join(root, ".git", "lcars", "missions", "m-adopted-chosen",
                   "state.json")
with open(_sp) as fh:
    _st = _json.load(fh)
_st["engineResolved"] = "claude"
_st["engineSource"] = "adopt-chosen"
with open(_sp, "w") as fh:
    _json.dump(_st, fh, indent=2)
# The published-owner files ownership.sh writes. Planted, not fetched: the
# daemon reads them off disk on the render path and this rig never needs a forge.
cache = os.path.join(root, ".git", "lcars", "cache")
os.makedirs(cache, exist_ok=True)
for issue, login in ((101, "roferg"), (102, "picard"),
                     (103, "roferg"), (104, "picard"),
                     (105, "roferg"), (106, "roferg"), (107, "roferg")):
    with open(os.path.join(cache, "owner-github.com-%d" % issue), "w") as fh:
        fh.write(login + "\n")
PYEOF

  # ---- S201: THE INHERITANCE SEAM ----------------------------------------
  # A later round that needs THE SAME board, daemon and Chrome with ONE more
  # fact planted on it hooks in here instead of forking 700 lines. The extra
  # planter is handed the repo and the fixture root, exactly as the built-in
  # one above is, and runs AFTER it — so it can add missions, add a config, or
  # amend what the built-in planter wrote, and can never silently replace it.
  if [ -n "${LCARS_PAINT_PLANT:-}" ]; then
    [ -f "$LCARS_PAINT_PLANT" ] \
      || { teardown; skip "LCARS_PAINT_PLANT is not a file: $LCARS_PAINT_PLANT"; }
    "$PY_BIN" "$LCARS_PAINT_PLANT" "$REPO" "$fixture" || return 77
  fi

  # ---- the daemon ---------------------------------------------------------
  # LCARS_GH_USER pins the identity with no subprocess (rule 1 of lcars_whoami's
  # own order). LCARS_OWNER_WARM=0 because the owners are already planted and a
  # startup warm here would only shell a gh that cannot answer.
  ( cd "$web" && exec env -u LCARS_SERVE_PORT \
      PATH="$out/shim:$PATH" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 LCARS_OWNER_WARM=0 \
      LCARS_GH_USER=roferg LCARS_GH_BIN="$out/shim/gh" \
      LCARS_REMOTE_OVERLAY=1 LCARS_REMOTE_POLL=10 \
      LCARS_WORKER_BIN="$out/shim/claude" \
      "$PY_BIN" -m lcars_serve --port 0 --repo-root "$fixture" ) \
    >"$out/daemon.log" 2>&1 &
  DAEMON_PID=$!

  local url=""
  local i
  for i in $(seq 1 150); do
    url="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$out/daemon.log" 2>/dev/null | head -1)"
    [ -n "$url" ] && break
    kill -0 "$DAEMON_PID" 2>/dev/null || break
    sleep 0.1
  done
  [ -n "$url" ] || { teardown; skip "the daemon never bound a port; see $out/daemon.log"; }
  note "daemon:    $url (pid $DAEMON_PID)"

  # ---- real Chrome, its own throwaway profile, its own free devtools port --
  local profile="$out/chrome-profile"
  mkdir -p "$profile"
  rm -f "$profile/DevToolsActivePort"
  local headless="--headless=new"
  [ "${LCARS_BROWSER_HEADED:-}" = "1" ] && headless=""
  "$CHROME" \
    --user-data-dir="$profile" --remote-debugging-port=0 $headless \
    --no-first-run --no-default-browser-check --no-service-autorun \
    --disable-background-networking --disable-sync --disable-extensions \
    --disable-component-update --disable-default-apps --disable-popup-blocking \
    --window-size=1440,1000 about:blank >"$out/chrome.log" 2>&1 &
  CHROME_PID=$!

  # DevToolsActivePort is a RACE unless both lines have arrived (smoke.sh's
  # lesson, reproduced rather than reinvented: a content test, never a line
  # count) AND the port actually answers.
  DEV_PORT=""
  local deadline=$(( $(date +%s) + 30 )) p ws
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$profile/DevToolsActivePort" ]; then
      p="$(sed -n 1p "$profile/DevToolsActivePort" | tr -d '[:space:]')"
      ws="$(sed -n 2p "$profile/DevToolsActivePort" | tr -d '[:space:]')"
      case "$p" in ''|*[!0-9]*) p="" ;; esac
      case "$ws" in /devtools/*) ;; *) p="" ;; esac
      if [ -n "$p" ] && "$NODE_BIN" -e '
        fetch("http://127.0.0.1:" + process.argv[1] + "/json/version",
              { signal: AbortSignal.timeout(2000) })
          .then((r) => r.json())
          .then((j) => process.exit(j && j.webSocketDebuggerUrl ? 0 : 1))
          .catch(() => process.exit(1));' "$p" >/dev/null 2>&1; then
        DEV_PORT="$p"; break
      fi
    fi
    kill -0 "$CHROME_PID" 2>/dev/null || break
    sleep 0.2
  done
  [ -n "$DEV_PORT" ] || { teardown; skip "Chrome never opened a usable devtools port; see $out/chrome.log"; }
  note "chrome:    devtools :$DEV_PORT (pid $CHROME_PID)"

  # …and the SECOND half of the seam: which driver asks the questions. Default
  # is this round's own; S201 points it at `tests/drives/s201/xo-paint.js`,
  # which REQUIRES this one for its primitives rather than re-implementing a
  # CDP client, a PNG reader and a contrast formula.
  "$NODE_BIN" "${LCARS_PAINT_DRIVER:-$HERE/owner-paint.js}" \
    --devtools-port "$DEV_PORT" --url "$url" --timeout 75000 \
    --out "$out" 2>&1 | tee "$LOG"
  RC=${PIPESTATUS[0]}
  teardown
  return 0
}

DAEMON_PID=""
CHROME_PID=""
teardown() {
  # ONLY the pids this script started, by recorded pid. Never by name.
  local pid
  for pid in "$CHROME_PID" "$DAEMON_PID"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null
  done
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local alive=0
    for pid in "$CHROME_PID" "$DAEMON_PID"; do
      [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && alive=1
    done
    [ "$alive" -eq 0 ] && break
    sleep 0.3
  done
  for pid in "$CHROME_PID" "$DAEMON_PID"; do
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
  DAEMON_PID=""; CHROME_PID=""
}
trap 'teardown' EXIT INT TERM

FAILED=0

# ── the product ─────────────────────────────────────────────────────────────
if [ "$MODE" = "product" ] || [ "$MODE" = "--all" ]; then
  say "S190 owner treatment — the PAINTED result, in real Chrome"
  run_against "$REPO/web" product
  if [ "$RC" -eq 0 ]; then
    printf '\033[32mPROVEN\033[0m — the locked controls paint legibly and no dead rule ships.\n'
    # S197 — THE DELIVERABLE. The captain asked for a report WITH IMAGES of the
    # engine question, so the three frames that answer it are copied out of the
    # throwaway work dir into the capstone's own shot folder, where he (and the
    # next session) can find them without knowing what $TMPDIR was that day.
    SHOTS="$REPO/tests/drives/s196-capstone/shots/adopt-picker"
    mkdir -p "$SHOTS"
    for f in board.png adopt-picker-open.png adopt-picker.png \
             adopt-picker-grey.png adopt-provenance-chosen.png; do
      [ -f "$WORK/product/$f" ] && cp "$WORK/product/$f" "$SHOTS/$f"
    done
    printf 'shots:     %s\n' "$SHOTS"
  elif [ "$RC" -eq 77 ]; then
    exit 77
  else
    printf '\033[31mFAILED\033[0m — see %s\n' "$WORK/product.log"
    FAILED=1
  fi
fi

# ── the RED CONTROLS ────────────────────────────────────────────────────────
# A check that cannot go red is decoration. Each variant patches a COPY of web/
# and MUST make the drive fail. This repo's own web/ is never touched.
if [ "$MODE" = "--calibrate" ] || [ "$MODE" = "--all" ]; then
  printf '\n'
  say "CALIBRATION — can this drive see each defect it claims to?"
  i=0
  for variant in dim-the-row dead-det-head-rule motion-gated-filter \
                 lock-looks-live lock-wears-no-mark \
                 owner-pill-colour-only remote-lock-looks-live \
                 remote-keeps-dead-controls adopt-stutters \
                 filter-draws-everything filter-counts-lie \
                 filter-forgets-on-reload filter-refetches-the-board \
                 filter-footer-counts-active-only \
                 beam-pending-is-a-hole beam-img-outranks-its-disc \
                 beam-window-restarts-on-repaint \
                 shipped-card-never-learns shipped-lie-is-only-disabled \
                 adopt-never-asks adopt-picker-looks-the-same \
                 adopt-picker-dies-on-repaint; do
    # ONE CONTROL AT A TIME, when that is what is being asked. The full set is
    # sixteen browser runs; `LCARS_S190_ONLY=beam-pending-is-a-hole,...` narrows
    # it while a control is being written, and an empty value means all of them.
    case ",${LCARS_S190_ONLY:-},"  in
      ",,") ;;
      *",$variant,"*) ;;
      *) continue ;;
    esac
    i=$((i + 1))
    BROKEN="$WORK/broken-$variant"
    mkdir -p "$BROKEN"
    cp -R "$REPO/web/lcars_serve" "$REPO/web/static" "$BROKEN/"
    rm -rf "$BROKEN/lcars_serve/__pycache__"
    # docs/lcars.css is served from beside the package; without it the board
    # paints yellow-on-yellow and still "passes" (smoke.sh selftest property 7).
    if [ -f "$REPO/docs/lcars.css" ]; then
      mkdir -p "$BROKEN/../docs" && cp "$REPO/docs/lcars.css" "$BROKEN/../docs/lcars.css"
    fi
    CSS="$BROKEN/static/board.css"
    JS="$BROKEN/static/board.js"
    PATCHED=1
    case "$variant" in
      # THE DEFECT, VERBATIM: dim the row and try to restore the button inside
      # it. This is what shipped, and the drive must call it out.
      dim-the-row)
        printf '\n.card.owned-by-other .card-ctrl{opacity:.55}\n.card.owned-by-other .card-ctrl button[disabled]{opacity:1}\n' >>"$CSS" ;;
      dead-det-head-rule)
        printf '\n.det-head .owner{margin:0}\n' >>"$CSS" ;;
      motion-gated-filter)
        printf '\n@media (prefers-reduced-motion:reduce){.owner .owner-av img{filter:none}}\n' >>"$CSS" ;;
      # S191 fix round 1 (D4). THE DEFECT THE CAPSTONE SENT BACK, verbatim: put
      # the locked control back on the live control's saturated fill with a dim
      # over it. Every number round 1 measured stays true and the button becomes
      # indistinguishable from a live one — which is the whole point of measuring
      # the SEPARATION between two controls rather than either one alone.
      lock-looks-live)
        printf '\n.btn.locked{opacity:.7;background:var(--lcars-teal);color:var(--lcars-text-on-color);border-color:var(--lcars-teal);border-style:solid}\n' >>"$CSS" ;;
      # …and the OTHER half. Neuter the label mark in board.js, so a locked
      # `▶ Start` still says it will go. Patched with sed and then VERIFIED to
      # have actually changed the file: tests/drives/browser/calibrate.sh sat
      # dead for six sessions because its cut silently matched nothing, and a red
      # control that cannot go red is worse than no red control at all.
      lock-wears-no-mark)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/^      markLocked(n);$/      \/* markLocked(n); *\//' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── S196 B1. THE DEFECT, VERBATIM: ownership back in COLOUR ALONE. The
      # pill keeps its hue change and loses the fill change, which is exactly
      # what shipped — and is 1.52:1 in luminance, i.e. the same pill once the
      # colour is gone. Appended AFTER the cured rule, same specificity, so
      # source order hands it the win.
      owner-pill-colour-only)
        printf '\n.card.owned-by-other .owner{--owner-fill:var(--owner-col);--owner-ink:var(--lcars-text-on-color);--owner-edge:solid}\n' >>"$CSS" ;;
      # ── S196 B2. Put the remote detail's locked controls back on the live
      # control's saturated fill. Scoped to `.det-actions` so it hits the REMOTE
      # measurement and leaves S191's own board-card pair alone: two red controls
      # that both fire on one check prove less than two that fire on one each.
      # ── S197. THE DEFECT, VERBATIM: the card never learns. `shippedVerdict`
      # returns null, so the daemon's fact reaches nothing — no pill, no dashed
      # edge, no sweep — and the card goes back to offering a live
      # `✓ Review PR ▸` for a pull request that merged on the other laptop.
      # This is precisely what two live two-laptop runs photographed.
      #
      # PATCHED WITH sed AND THEN VERIFIED TO HAVE BITTEN (cmp against the
      # .bak). tests/drives/browser/calibrate.sh sat DEAD FROM S176 TO S191
      # because its cut silently matched nothing, and a recent lesson in this
      # very file is that an indentation change broke an older control's sed —
      # so the pattern is deliberately NOT anchored to a column.
      shipped-card-never-learns)
        "${LCARS_SED_BIN:-sed}" -i.bak \
          's/function shippedVerdict(m) {/function shippedVerdict(m) { return null;/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # …and the HALF-CURE, which is the more interesting red control: leave the
      # sweep in place (so the button is disabled and hollow and wears `⊘`) but
      # take out the affordance that REPLACES THE LABEL. The board then reads
      # `⊘ Review PR ▸` about a PR that is merged — the lie made unclickable
      # rather than withdrawn, which is not the same thing and must not pass.
      shipped-lie-is-only-disabled)
        "${LCARS_SED_BIN:-sed}" -i.bak \
          's/var over = shippedOnVerify(m); if (over) return over;/var over = null;/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      remote-lock-looks-live)
        printf '\n.det-actions .btn.locked{background:var(--lcars-teal);color:var(--lcars-text-on-color);border-color:var(--lcars-teal);border-style:solid}\n' >>"$CSS" ;;
      # ── S196 B3. Neuter the removal so the remote card keeps its dead
      # controls. sed, and then VERIFIED to have bitten — tests/drives/browser/
      # calibrate.sh sat DEAD FROM S176 TO S191 because its cut silently matched
      # nothing (it cut a `.then(render)` line that S176 had folded away), and a
      # red control that cannot go red is worse than none at all.
      remote-keeps-dead-controls)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/^      if (!k\.disabled) continue;$/      if (k.disabled) continue;/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── S196 B4. Put the stutter back: a hollow triangle beside a solid one.
      # Also sed, also verified.
      adopt-stutters)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/"◆ Adopt ▸"/"▹ Adopt ▸"/g' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── S196 B5. FOUR CONTROLS, ONE PER PROMISE THE FILTER MAKES, because a
      # check that cannot go red is decoration and one control that trips every
      # check proves less than four that trip one each. Every one is a `sed`
      # that is then VERIFIED to have bitten (cmp against the .bak):
      # tests/drives/browser/calibrate.sh sat DEAD FROM S176 TO S191 because its
      # cut silently matched nothing, and a red control that cannot go red is
      # worse than no red control at all.
      #
      # 1. THE FILTER DOES NOT FILTER. The strip still paints, the chips still
      #    count, the status line still says "filtered" — and the board draws
      #    every card. This is the failure a rule-exists test cannot see and the
      #    one a unit harness would also miss, because every harness in
      #    web/tests calls render() itself.
      filter-draws-everything)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/^      \.filter(function (m) { return ownerFilterShows(m, active); });$/      ;/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # 2. THE COUNT LIES. The chip prints one number and the board draws
      #    another — the specific defect the "counts agree" checks exist for.
      filter-counts-lie)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/String(counts\[f.id\])/String(counts[f.id] + 1)/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # 3. IT FORGETS. The choice is never written, so a refresh silently throws
      #    away the question the captain asked. Nothing on screen says so.
      filter-forgets-on-reload)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/s\.setItem(OWNER_FILTER_KEY, OWNER_FILTER\.join(","));/0;/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # 4. THE ONE THAT COSTS MONEY — the S152 constraint broken in the most
      #    natural way there is: ask the daemon to re-answer. It looks correct,
      #    it IS correct on screen, and it puts a forge round trip behind every
      #    chip. This is the control the gh-invocation count exists for.
      filter-refetches-the-board)
        "${LCARS_SED_BIN:-sed}" -i.bak 's|^  repaintBoard();$|  fetch("/api/board").then(function (r) { return r.json(); }).then(render);|' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── S196 B5 FIX ROUND 1. THE DEFECT, VERBATIM: the footer goes back to
      #    counting `board.missions` — which EXCLUDES done — while the chips
      #    and the column heads keep counting `board.columns`, which does not.
      #    Nothing else on the page moves, which is precisely what made it hard
      #    to see: the strip is right, the heads are right, the cards are
      #    right, and one sentence at the bottom quietly says "2 of 6" over
      #    three drawn cards under a chip reading 3. It can only go red at all
      #    because the fixture now carries a done mission — with an all-active
      #    board this patch is a no-op on screen, and a control that cannot go
      #    red is worse than no control at all.
      filter-footer-counts-active-only)
        "${LCARS_SED_BIN:-sed}" -i.bak 's#^    var total = allCards.length;$#    var total = (board.missions || []).length; allCards = board.missions || [];#' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── S196 THE TRANSPORTER MATERIALIZE. Two controls, one per half of the
      #    change, because a control that trips every check proves less than
      #    two that trip one each. Both are `sed` and both are then VERIFIED to
      #    have bitten (cmp against the .bak): tests/drives/browser/
      #    calibrate.sh sat DEAD FROM S176 TO S191 because its cut silently
      #    matched nothing, and a red control that cannot go red is worse than
      #    no red control at all.
      #
      # 1. THE DEFECT, VERBATIM — a PENDING portrait back to a resting hole.
      #    The disc still exists, still has its ring, still has the right
      #    geometry; it simply says nothing while the portrait is in flight,
      #    which is exactly what shipped and exactly what no error handler and
      #    no unit harness can see. Every stylesheet rule stays correct.
      beam-pending-is-a-hole)
        "${LCARS_SED_BIN:-sed}" -i.bak 's/^\( *\)beam\.className = "beam loading";$/\1beam.className = "beam";/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # 2. THE SPECIFICITY TRAP, verbatim — what the captain's mock did first.
      #    Put the OLD explicit sizing and the portrait's own ring back, so the
      #    portrait is larger than the disc that clips it and two black rings
      #    fight inside a visibly non-circular avatar. Nothing in the sheet
      #    reads wrong; only the rendered boxes can see it, which is the whole
      #    reason those boxes are measured.
      beam-img-outranks-its-disc)
        "${LCARS_SED_BIN:-sed}" -i.bak \
          -e 's|^  width:100%;height:100%;object-fit:cover;$|  width:calc(var(--owner-h) + 4px);height:calc(var(--owner-h) + 4px);object-fit:cover;|' \
          -e 's|^  border:0;border-radius:50%;$|  border:1px solid var(--lcars-black,#030608);border-radius:50%;|' "$CSS"
        if cmp -s "$CSS" "$CSS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$CSS.bak" ;;
      # ── S196.1 THE DEFECT, VERBATIM — the give-up window as a DURATION
      #    again. Put back the shape that shipped: every rebuilt node arms a
      #    fresh AVATAR_GIVE_UP_MS instead of the time REMAINING against the
      #    deadline recorded on first sight. Nothing else changes — the memo
      #    exists, the timer is armed, the pad is lit, the stylesheet is
      #    correct. It simply never expires while the board keeps repainting,
      #    which is most of a mission. Verified to have bitten (cmp against
      #    the .bak): tests/drives/browser/calibrate.sh sat DEAD FROM S176 TO
      #    S191 because its cut silently matched nothing, and a red control
      #    that cannot go red is worse than no red control at all.
      beam-window-restarts-on-repaint)
        "${LCARS_SED_BIN:-sed}" -i.bak \
          -e 's/^      var left = AVATAR_DEADLINE\[src\] - now;$/      var left = AVATAR_GIVE_UP_MS;/' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── S197 THE DEFECT, VERBATIM — the board that could not ask. Remove
      #    the one line that opens the picker and Adopt goes straight back to
      #    dispatching with no `--engine`, which is precisely the state the
      #    captain found: on a laptop with only the other CLI, that POST comes
      #    back as adopt.sh's refusal. The drive must notice that nothing was
      #    asked. UNANCHORED (`s|…|…|` with no ^/$), per the lesson that an
      #    indentation change once silently killed an older control; verified
      #    to have bitten by cmp against the .bak.
      adopt-never-asks)
        "${LCARS_SED_BIN:-sed}" -i.bak \
          -e 's|if (openAdoptPicker(b, m)) return;|/* asked nothing */|' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
      # ── …and the SHARPER one, which is the failure actually worth guarding
      #    against: the picker OPENS, both options are there, everything the
      #    DOM can see is correct — and the option in force paints the same as
      #    the one merely on offer, so "the default is the mission's engine" is
      #    a claim the screen does not make. A class-name test is green on
      #    this. Only the pixels are not. Appended AFTER the cured rule at the
      #    same specificity, so source order hands it the win.
      adopt-picker-looks-the-same)
        printf '\n.adopt-picker .btn.adopt-engine.chosen{background:transparent;color:var(--lcars-text-bright);border-color:var(--lcars-border)}\n' >>"$CSS" ;;
      # ── THE DEFECT THIS RIG FOUND WHILE IT WAS BEING WRITTEN, VERBATIM: the
      #    open question lived only in the DOM, so the board's own four-second
      #    repaint deleted it underneath the captain mid-decision. Put that
      #    back by refusing to re-open the picker on the rebuilt card —
      #    everything else stays (the memo is written, the option is chosen,
      #    the first paint is perfect). A DOM-shape test taken immediately
      #    after the click is green on this; only a rig that WAITS can see it.
      #    Unanchored, and cmp-verified to have bitten.
      adopt-picker-dies-on-repaint)
        "${LCARS_SED_BIN:-sed}" -i.bak \
          -e 's|if (ADOPT_PICKING\[adoptKey(m)\]) openAdoptPicker(adopt, m);|/* it does not come back */|' "$JS"
        if cmp -s "$JS" "$JS.bak"; then
          printf '  \033[31mFAIL\033[0m  control "%s" did not patch anything (the cut matched no line)\n' "$variant"
          FAILED=1; PATCHED=0
        fi
        rm -f "$JS.bak" ;;
    esac
    [ "$PATCHED" -eq 1 ] || continue
    run_against "$BROKEN" "calib-$variant"
    if [ "$RC" -eq 0 ]; then
      printf '  \033[31mFAIL\033[0m  control "%s" did NOT make the drive go red\n' "$variant"
      FAILED=1
    elif [ "$RC" -eq 77 ]; then
      printf '  \033[33mSKIP\033[0m  control "%s" could not run\n' "$variant"
      FAILED=1
    else
      printf '  \033[32mPASS\033[0m  control "%s" turned the drive red\n' "$variant"
    fi
  done
fi

printf '\nartifacts: %s\n' "$WORK"
exit "$FAILED"
