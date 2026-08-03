#!/usr/bin/env bash
# ============================================================================
# SELF-TEST for the real-Chrome smoke rig.
#
# The rig exists to catch a class of defect that every node harness in
# web/tests/ is blind to (S163: a deleted `.then(render)` left the shipping
# board a blank page while 1,162 tests stayed green). A rig that can only ever
# report success would license exactly that failure again, so this file proves
# the rig's OWN properties — including that it can go RED.
#
#   bash tests/drives/browser/selftest.sh
#
# It launches real Chrome several times; budget ~1-2 minutes. Zero tokens: the
# only workers on PATH are shims (see smoke.sh) and the rig never posts.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SMOKE="$HERE/smoke.sh"
CALIBRATE="$HERE/calibrate.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-selftest.XXXXXX")"
# u+w first: property 7b deliberately makes a directory read-only, and a crash
# inside it would otherwise leave a scratch dir that rm -rf cannot clear.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n     %s\n' "$1" "${2:-}"; FAILED=$((FAILED + 1)); }
say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# A live Chrome is a precondition of this self-test, not one of its subjects.
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  printf '\n\033[33mSKIP\033[0m  selftest needs a real Chrome at:\n        %s\n' "$CHROME"
  printf '      Install Chrome or set LCARS_BROWSER_CHROME. NOT a pass.\n\n'
  exit 77
fi

# ── 1. a healthy board: exit 0, real card nodes counted in the real DOM ──────
say "1. the rig passes on a healthy board"
OUT1="$WORK/run1"
LCARS_BROWSER_OUT="$OUT1" bash "$SMOKE" >"$WORK/run1.log" 2>&1
RC1=$?
if [ "$RC1" -eq 0 ]; then pass "smoke.sh exited 0"; else
  fail "smoke.sh exited 0" "got $RC1; see $WORK/run1.log"; sed -n '1,60p' "$WORK/run1.log"
fi
if [ -f "$OUT1/result.json" ] && grep -q '"cards": *2' "$OUT1/result.json"; then
  pass "found the fixture's 2 cards in the real DOM"
else
  fail "found the fixture's 2 cards in the real DOM" "$(cat "$OUT1/result.json" 2>/dev/null)"
fi

# ── 4. a screenshot exists where the run said it would ───────────────────────
say "4. the run leaves a screenshot to look at"
SHOT="$(grep -o 'screenshot: .*' "$WORK/run1.log" | tail -1 | sed 's/^screenshot: //')"
if [ -n "$SHOT" ] && [ -s "$SHOT" ]; then
  pass "screenshot at the announced path ($(wc -c <"$SHOT" | tr -d ' ') bytes)"
else
  fail "screenshot at the announced path" "announced='$SHOT'"
fi

# ── 5. nothing survives the run ──────────────────────────────────────────────
say "5. no orphan daemon, Chrome, or held port"
check_orphans() {
  local out="$1" label="$2"
  local dpid cpid port
  dpid="$(sed -n 's/.*"daemonPid": *\([0-9]*\).*/\1/p' "$out/pids.json" 2>/dev/null)"
  cpid="$(sed -n 's/.*"chromePid": *\([0-9]*\).*/\1/p' "$out/pids.json" 2>/dev/null)"
  port="$(sed -n 's/.*"daemonPort": *\([0-9]*\).*/\1/p' "$out/pids.json" 2>/dev/null)"
  if [ -z "$dpid" ] || [ -z "$cpid" ] || [ -z "$port" ]; then
    fail "$label recorded its pids/port" "pids.json=$(cat "$out/pids.json" 2>/dev/null)"
    return
  fi
  if kill -0 "$dpid" 2>/dev/null; then fail "$label left no daemon" "pid $dpid alive"
  else pass "$label left no daemon (pid $dpid)"; fi
  if kill -0 "$cpid" 2>/dev/null; then fail "$label left no Chrome" "pid $cpid alive"
  else pass "$label left no Chrome (pid $cpid)"; fi
  if curl -s -m 2 -o /dev/null "http://127.0.0.1:$port/api/board" 2>/dev/null; then
    fail "$label released its port" "port $port still answering"
  else pass "$label released its port ($port)"; fi
}
check_orphans "$OUT1" "the passing run"

# ── 2. CALIBRATION: the rig goes red when the board stops painting ───────────
say "2. calibration — .then(render) removed makes the rig FAIL"
bash "$CALIBRATE" >"$WORK/calib.log" 2>&1
RCC=$?
if [ "$RCC" -eq 0 ]; then pass "calibrate.sh confirms the rig can go red"; else
  fail "calibrate.sh confirms the rig can go red" "exit $RCC; see $WORK/calib.log"
  sed -n '1,60p' "$WORK/calib.log"
fi

# a failing run must ALSO clean up after itself.
say "5b. the failing run cleans up too"
# calibrate.sh runs the rig with LCARS_BROWSER_OUT=<its work dir>/run.
CALIB_OUT="$(grep -o 'calibration artifacts: .*' "$WORK/calib.log" | tail -1 | sed 's/^calibration artifacts: //')/run"
if [ -f "$CALIB_OUT/pids.json" ]; then
  check_orphans "$CALIB_OUT" "the failing run"
else
  fail "the failing run recorded its pids" "no pids.json under '$CALIB_OUT'"
fi

# ── 3. Chrome missing ⇒ LOUD SKIP, never a silent pass ───────────────────────
say "3. no Chrome ⇒ loud skip that names why"
OUT3="$WORK/run3"
LCARS_BROWSER_OUT="$OUT3" LCARS_BROWSER_CHROME="$WORK/no-such-chrome" \
  bash "$SMOKE" >"$WORK/run3.log" 2>&1
RC3=$?
if [ "$RC3" -eq 0 ]; then
  fail "a missing Chrome is not reported as a pass" "exit 0"
elif [ "$RC3" -eq 77 ]; then pass "exited 77 (skip), not 0"
else fail "exited 77 (skip)" "got $RC3"; fi
if grep -qi "SKIP" "$WORK/run3.log" && grep -q "no-such-chrome" "$WORK/run3.log"; then
  pass "the skip names the missing binary"
else
  fail "the skip names the missing binary" "$(sed -n '1,20p' "$WORK/run3.log")"
fi

# ── 6. back-to-back runs do not collide ──────────────────────────────────────
say "6. two consecutive runs do not collide on a port"
OUT6="$WORK/run6"
LCARS_BROWSER_OUT="$OUT6" bash "$SMOKE" >"$WORK/run6.log" 2>&1
RC6=$?
P1="$(sed -n 's/.*"daemonPort": *\([0-9]*\).*/\1/p' "$OUT1/pids.json" 2>/dev/null)"
P6="$(sed -n 's/.*"daemonPort": *\([0-9]*\).*/\1/p' "$OUT6/pids.json" 2>/dev/null)"
if [ "$RC6" -eq 0 ]; then pass "the second run also exited 0"; else
  fail "the second run also exited 0" "got $RC6; see $WORK/run6.log"
fi
if [ -n "$P1" ] && [ -n "$P6" ] && [ "$P1" != "$P6" ]; then
  pass "each run took its own free port ($P1 then $P6)"
else
  fail "each run took its own free port" "run1=$P1 run2=$P6"
fi
check_orphans "$OUT6" "the second run"

# ── 7. the calibration seam serves the WHOLE app ─────────────────────────────
# The seam (LCARS_BROWSER_WEB_DIR) is what calibrate.sh and every visual-bug
# hunt runs through. It used to serve a copy with NO shared docs/lcars.css, so
# the entire --lcars-* token layer was missing and the board rendered
# yellow-on-yellow — while still PASSING. A visual rig whose own seam silently
# degrades the app is the disease it was built to cure.
say "7. a web/ copy through the calibration seam is served FULLY STYLED"
SEAM="$WORK/seam"; mkdir -p "$SEAM"
cp -R "$REPO/web" "$SEAM/web"; rm -rf "$SEAM/web/lcars_serve/__pycache__"
OUT7="$WORK/run7"
LCARS_BROWSER_WEB_DIR="$SEAM/web" LCARS_BROWSER_OUT="$OUT7" bash "$SMOKE" >"$WORK/run7.log" 2>&1
RC7=$?
if [ "$RC7" -eq 0 ]; then pass "the seam run exited 0"; else
  fail "the seam run exited 0" "got $RC7"; sed -n '1,40p' "$WORK/run7.log"
fi
if grep -q '"servedComplete": true' "$OUT7/result.json" 2>/dev/null; then
  pass "every same-origin stylesheet loaded (no /lcars.css 404)"
else
  fail "every same-origin stylesheet loaded" "$(grep -A6 '"stylesheets"' "$OUT7/result.json" 2>/dev/null)"
fi
if grep -q '"tokenProbe": "#' "$OUT7/result.json" 2>/dev/null; then
  pass "the shared --lcars-* tokens reached :root ($(sed -n 's/.*"tokenProbe": "\(.*\)".*/\1/p' "$OUT7/result.json"))"
else
  fail "the shared --lcars-* tokens reached :root" "tokenProbe empty — the board is unstyled"
fi

# 7b. …and that check must be able to go RED, or it is decoration.
say "7b. a seam that DOES lose the shared stylesheet fails LOUDLY"
SEAM2="$WORK/seam-bare"; mkdir -p "$SEAM2"
cp -R "$REPO/web" "$SEAM2/web"; rm -rf "$SEAM2/web/lcars_serve/__pycache__"
chmod 555 "$SEAM2"          # so the rig CANNOT place docs/lcars.css beside it
LCARS_BROWSER_WEB_DIR="$SEAM2/web" LCARS_BROWSER_OUT="$WORK/run7b" \
  bash "$SMOKE" >"$WORK/run7b.log" 2>&1
RC7B=$?
chmod 755 "$SEAM2"
if [ "$RC7B" -eq 3 ]; then pass "an unstyled app exits 3, not 0"; else
  fail "an unstyled app exits 3, not 0" "got $RC7B"; sed -n '1,40p' "$WORK/run7b.log"
fi
if grep -q 'SERVED INCOMPLETE' "$WORK/run7b.log"; then
  pass "it says so in words, on stdout"
else
  fail "it says so in words, on stdout" "$(sed -n '1,30p' "$WORK/run7b.log")"
fi

# ── 8. a HARNESS failure is never reported as a board failure ────────────────
# Exit 1 is an accusation against the product. A cold headed launch once read a
# stale DevToolsActivePort, failed to reach Chrome, and printed "the board did
# not paint" about a board that was fine.
say "8. a harness/infrastructure failure exits 77 and does NOT accuse the board"
OUT8="$WORK/run8"
LCARS_BROWSER_TIMEOUT=1 LCARS_BROWSER_OUT="$OUT8" bash "$SMOKE" >"$WORK/run8.log" 2>&1
RC8=$?
if [ "$RC8" -eq 77 ]; then pass "a nonsense timeout skips (77), not 1"; else
  fail "a nonsense timeout skips (77), not 1" "got $RC8"; sed -n '1,20p' "$WORK/run8.log"
fi
if grep -qi 'did not paint\|BLANK / WRONG' "$WORK/run8.log"; then
  fail "it does not blame the board" "$(sed -n '1,20p' "$WORK/run8.log")"
else
  pass "it does not blame the board"
fi
mkdir -p "$WORK/run8b"
node "$HERE/cdp.js" --devtools-port 9 --url "http://127.0.0.1:9/" \
  --out "$WORK/run8b" --timeout 2000 >"$WORK/run8b.log" 2>&1
RC8B=$?
if [ "$RC8B" -eq 77 ]; then pass "an unreachable devtools endpoint exits 77, not 1"; else
  fail "an unreachable devtools endpoint exits 77, not 1" "got $RC8B; $(cat "$WORK/run8b.log")"
fi

# 8b. a stale DevToolsActivePort must never be believed.
say "8b. a STALE DevToolsActivePort is not believed"
OUT8C="$WORK/run8c"; mkdir -p "$OUT8C/chrome-profile"
printf '51719\n/devtools/browser/deadbeef-stale-stale-stale' >"$OUT8C/chrome-profile/DevToolsActivePort"
LCARS_BROWSER_OUT="$OUT8C" bash "$SMOKE" >"$WORK/run8c.log" 2>&1
RC8C=$?
if [ "$RC8C" -eq 0 ] && ! grep -q 'devtools :51719' "$WORK/run8c.log"; then
  pass "the run ignored the stale port and drove the real one"
else
  fail "the run ignored the stale port" "exit $RC8C; $(grep -E 'chrome:|SKIP' "$WORK/run8c.log")"
fi

# ── 9. page errors are surfaced on a GREEN run, not only on a red one ───────
say "9. an unexpected page error is SURFACED on a green run"
if grep -q 'page errors: 2 known-benign .*, 0 unexpected' "$WORK/run1.log"; then
  pass "a clean run reports its two known-benign errors and 0 unexpected"
else
  fail "a clean run reports 0 unexpected" "$(grep -i 'page errors' "$WORK/run1.log")"
fi
INJ="$WORK/inject"; mkdir -p "$INJ"
cp -R "$REPO/web" "$INJ/web"; rm -rf "$INJ/web/lcars_serve/__pycache__"
printf '\nsetTimeout(function(){ throw new Error("LCARS SELFTEST injected error"); }, 0);\n' \
  >>"$INJ/web/static/board.js"
OUT9="$WORK/run9"
LCARS_BROWSER_WEB_DIR="$INJ/web" LCARS_BROWSER_OUT="$OUT9" bash "$SMOKE" >"$WORK/run9.log" 2>&1
RC9=$?
if [ "$RC9" -eq 0 ]; then pass "an injected error does not turn the run red"; else
  fail "an injected error does not turn the run red" "got $RC9"
fi
if grep -q 'UNEXPECTED PAGE ERROR' "$WORK/run9.log" &&
   grep -q 'LCARS SELFTEST injected error' "$WORK/run9.log"; then
  pass "the injected error is named on stdout of the GREEN run"
else
  fail "the injected error is named on stdout" "$(grep -i 'page error' -A4 "$WORK/run9.log")"
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mSELFTEST GREEN\033[0m — the rig passes, fails, skips and cleans up.\n'
else
  printf '\033[31mSELFTEST RED\033[0m — %d check(s) failed.\n' "$FAILED"
fi
exit "$FAILED"
