#!/usr/bin/env bash
# ============================================================================
# S190 fix round 1 — THE OWNER TREATMENT, MEASURED IN PIXELS.
#
#   bash tests/drives/s190/owner-paint.sh
#   bash tests/drives/s190/owner-paint.sh --calibrate   # the RED CONTROLS
#   bash tests/drives/s190/owner-paint.sh --all
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
# The published-owner files ownership.sh writes. Planted, not fetched: the
# daemon reads them off disk on the render path and this rig never needs a forge.
cache = os.path.join(root, ".git", "lcars", "cache")
os.makedirs(cache, exist_ok=True)
for issue, login in ((101, "roferg"), (102, "picard")):
    with open(os.path.join(cache, "owner-github.com-%d" % issue), "w") as fh:
        fh.write(login + "\n")
PYEOF

  # ---- the daemon ---------------------------------------------------------
  # LCARS_GH_USER pins the identity with no subprocess (rule 1 of lcars_whoami's
  # own order). LCARS_OWNER_WARM=0 because the owners are already planted and a
  # startup warm here would only shell a gh that cannot answer.
  ( cd "$web" && exec env -u LCARS_SERVE_PORT \
      PATH="$out/shim:$PATH" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 LCARS_OWNER_WARM=0 \
      LCARS_GH_USER=roferg LCARS_GH_BIN="$out/shim/gh" \
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

  "$NODE_BIN" "$HERE/owner-paint.js" --devtools-port "$DEV_PORT" --url "$url" \
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
  for variant in dim-the-row dead-det-head-rule motion-gated-filter; do
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
    case "$variant" in
      # THE DEFECT, VERBATIM: dim the row and try to restore the button inside
      # it. This is what shipped, and the drive must call it out.
      dim-the-row)
        printf '\n.card.owned-by-other .card-ctrl{opacity:.55}\n.card.owned-by-other .card-ctrl button[disabled]{opacity:1}\n' >>"$CSS" ;;
      dead-det-head-rule)
        printf '\n.det-head .owner{margin:0}\n' >>"$CSS" ;;
      motion-gated-filter)
        printf '\n@media (prefers-reduced-motion:reduce){.owner .owner-av img{filter:none}}\n' >>"$CSS" ;;
    esac
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
