#!/usr/bin/env bash
# ============================================================================
# S168 — THE BOARD'S "VIEW ON GITHUB" LINKS, ON A GITHUB ENTERPRISE HOST.
#
#   bash tests/drives/browser/ghe-links.sh              # the product
#   bash tests/drives/browser/ghe-links.sh --calibrate  # the RED CONTROLS
#   bash tests/drives/browser/ghe-links.sh --all        # both
#
# WHAT IS BEING PROVEN. The captain's repos live on a GitHub ENTERPRISE host
# (*.ghe.com). The harness's stage comments and mission-log issues were taught
# that host long ago; the VIEWSCREEN was not. Both of its issue links built their
# URL by concatenating a literal "https://github.com/" onto meta.repo, so every
# link the captain clicked opened a github.com repository that does not exist,
# and the host had to be hand-edited after every single click.
#
# WHY A BROWSER AND NOT A UNIT TEST. The front-end change is trivial and a node
# harness proves it in milliseconds (web/tests/test_gh_links_render.py). But the
# thing that can actually break is the DAEMON FAILING TO DELIVER THE FIELD TO THE
# LIVE PAGE — and every harness under web/tests/ calls the builders itself, so
# all of them stay green against a daemon that sends nothing at all. That is not
# hypothetical: in S163 the board was blank in Chrome for three fix rounds while
# 1,162 such tests and six tester rounds stayed green. So the verdict here is the
# RESOLVED `href` PROPERTY read off the live anchor in real Chrome — the actual
# URL a click would open — with a real daemon reading a real git remote.
#
# ENTIRELY OFFLINE. Deciding which forge a repo lives on is a question about its
# origin REMOTE URL. Naming a remote never contacts it, so all four scenarios run
# with no network, no GitHub account and no spend.
#
# THE FOUR SCENARIOS
#   1. enterprise  origin https://github.ghe.com/… → links resolve THERE (the fix)
#   2. github.com  origin https://github.com/…     → links resolve there, and the
#                  board payload is byte-identical to before. THIS is the one that
#                  must never break: it is every other user's board.
#   3. no-remote   a real git repo with NO origin  → github.com, no crash
#   4. scp-style   git@github.ghe.com:owner/repo   → the enterprise host again
#
# THE RED CONTROLS are the point of --calibrate. A check that cannot go red is
# decoration. Four variants patch a COPY of web/ and each must make the check
# fail — including one that reverts ONLY the daemon, leaving the front end
# perfect, because that is the failure a node harness is structurally blind to.
# This repo's own web/ is never touched.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"

WORK="${LCARS_BROWSER_GHLINK_OUT:-}"
if [ -z "$WORK" ]; then
  n=0                                  # keep the 2 newest, plus this one
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-ghlink.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-ghlink.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-ghlink.XXXXXX")"
fi
mkdir -p "$WORK"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# The expectation, per scenario. `host` is compared against the host the BROWSER
# parsed out of the resolved href — never against a substring of a string the
# page was built from. `places` names both links, so a run in which one of them
# silently stopped rendering cannot pass by measuring only the other.
write_expect() {   # $1 = file, $2 = host, $3 = expected path
  cat >"$1" <<JSON
{ "host": "$2",
  "path": "$3",
  "mission": "lcars-20260802-001",
  "places": ["card-logbug-badge", "detail-header"] }
JSON
}

# One real-Chrome run: a real daemon over a real git repo with $2 as its origin,
# both links measured, verdict = the resolved href.
#
# The PATH is asserted too, and it is not decoration: meta.repo comes from the
# origin remote when there is one and falls back to the working-tree BASENAME
# when there is not — so a scenario that silently lost its remote would still
# produce a github.com link, and only the path says which repo it names.
run_scenario() {   # $1 = name, $2 = origin (or "-" for none), $3 = expected host
  local wpath="/acme/browser-smoke/issues/4101"
  [ "$2" = "-" ] && wpath="/fixture/issues/4101"   # no remote → the dir basename
  write_expect "$WORK/expect-$1.json" "$3" "$wpath"
  LOG="$WORK/$1.log"
  LCARS_BROWSER_WEB_DIR="${WEB_UNDER_TEST:-$REPO/web}" \
  LCARS_BROWSER_OUT="$WORK/$1" \
  LCARS_BROWSER_ORIGIN="$2" \
  LCARS_BROWSER_LOGBUG=1 \
  LCARS_BROWSER_EXPECT=3 \
  LCARS_BROWSER_GHLINK_CHECK="$WORK/expect-$1.json" \
    bash "$HERE/smoke.sh" >"$LOG" 2>&1
  RC=$?
}

report_scenario() {   # $1 = name, $2 = human description
  case "$RC" in
    0)
      printf '  \033[32m✓\033[0m %s\n' "$2"
      grep -E '^    (card-logbug-badge|detail-header):' "$LOG" | sed 's/^ */      /'
      grep -E '^    board payload meta:' "$LOG" | sed 's/^ */      /'
      return 0 ;;
    77)
      printf '  \033[33m—\033[0m %s — SKIPPED (infrastructure), nothing proven\n' "$2"
      sed -n '1,20p' "$LOG"
      return 77 ;;
    3)
      printf '  \033[31m✗\033[0m %s — INCONCLUSIVE: the app was served without its\n' "$2"
      printf '      stylesheet, so the page measured is a phantom.\n'
      return 1 ;;
    *)
      printf '  \033[31m✗\033[0m %s\n' "$2"
      grep -E '✗|A "VIEW ON GITHUB"|BLANK / WRONG' "$LOG" | sed 's/^ */      /'
      printf '      full log:   %s\n' "$LOG"
      printf '      screenshot: %s/%s/gh-links.png\n' "$WORK" "$1"
      return 1 ;;
  esac
}

# ── the product ─────────────────────────────────────────────────────────────
product_run() {
  say "S168 — the board's GitHub links, in real Chrome, per forge host"
  note "artifacts: $WORK"
  local rc=0 r

  run_scenario enterprise "https://github.ghe.com/acme/browser-smoke.git" github.ghe.com
  report_scenario enterprise "ENTERPRISE origin → both links open github.ghe.com"; r=$?
  [ "$r" -ne 0 ] && rc=$r

  run_scenario githubcom "https://github.com/acme/browser-smoke.git" github.com
  report_scenario githubcom "GITHUB.COM origin → both links still open github.com"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }

  run_scenario noremote "-" github.com
  report_scenario noremote "NO origin remote at all → github.com, no broken link"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }

  run_scenario scpstyle "git@github.ghe.com:acme/browser-smoke.git" github.ghe.com
  report_scenario scpstyle "SCP-STYLE enterprise remote → github.ghe.com"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }

  printf '\n'
  case "$rc" in
    0) printf '\033[32mPROVEN\033[0m — in a real browser, against a real daemon reading a real git\n'
       printf '  remote, every "view on GitHub" link opens the forge the repo is on.\n'
       printf '  screenshot: %s/enterprise/gh-links.png — OPEN IT AND LOOK.\n' "$WORK"
       printf '  measurements: %s/<scenario>/ghlink-check.json\n' "$WORK" ;;
    77) printf '\033[33mSKIPPED\033[0m — infrastructure, nothing proven.\n' ;;
    *) printf '\033[31mFAILED\033[0m — see above.\n' ;;
  esac
  return $rc
}

# ── the red controls ────────────────────────────────────────────────────────
# A patch that did not apply is a RIG fault and exits 77: a control that quietly
# tested the healthy product would be the most flattering possible lie.
make_copy() {   # $1 = name → echoes the web dir
  local dst="$WORK/web-$1"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -R "$REPO/web/lcars_serve" "$REPO/web/static" "$dst/"
  rm -rf "$dst/lcars_serve/__pycache__"
  printf '%s' "$dst"
}

# CONTROL 1 — the bug verbatim: the front end goes back to a hardcoded host.
patch_frontend_reverted() {
  local js="$1/static/board.js"
  grep -q 'GH_HOST_RE.test(boardGhHost)' "$js" || return 1
  /usr/bin/sed -i '' 's|? boardGhHost : "github.com";|? "github.com" : "github.com";|' "$js"
  grep -q '? "github.com" : "github.com";' "$js"
}

# CONTROL 2 — THE ONE A NODE HARNESS CANNOT SEE. The front end is left perfect
# and only the DAEMON is silenced: meta never carries ghHost. Every unit test
# under web/tests/ that drives the builders directly stays green against this.
patch_daemon_silent() {
  local py="$1/lcars_serve/local_adapter.py"
  grep -q 'meta\["ghHost"\] = gh' "$py" || return 1
  /usr/bin/sed -i '' 's|meta\["ghHost"\] = gh|pass  # red control: the daemon says nothing|' "$py"
  grep -q 'red control: the daemon says nothing' "$py"
}

# CONTROL 3 — the daemon sends a host, but the WRONG one. Exercises the host
# COMPARISON; a check that only asked "is it not github.com" would pass this.
patch_wrong_host() {
  local py="$1/lcars_serve/local_adapter.py"
  grep -q 'meta\["ghHost"\] = gh' "$py" || return 1
  /usr/bin/sed -i '' 's|meta\["ghHost"\] = gh|meta["ghHost"] = "wrong.example.com"|' "$py"
  grep -q 'wrong.example.com' "$py"
}

# CONTROL 4 — the GITHUB.COM REGRESSION, which is the one that would hurt every
# other user: the front end pins an enterprise host unconditionally. Run against
# the GITHUB.COM scenario, so this asks "would we notice if we broke everyone
# else's board" — the question the scenario exists to answer.
patch_github_com_broken() {
  local js="$1/static/board.js"
  grep -q 'GH_HOST_RE.test(boardGhHost)' "$js" || return 1
  /usr/bin/sed -i '' 's|? boardGhHost : "github.com";|? boardGhHost : "github.ghe.com";|' "$js"
  grep -q '? boardGhHost : "github.ghe.com";' "$js"
}

control_run() {   # $1 = name, $2 = patch fn, $3 = description, $4 = scenario
  local dir; dir="$(make_copy "$1")"
  if ! "$2" "$dir"; then
    printf '\n\033[33mCONTROL CANNOT RUN\033[0m — the "%s" patch did not apply to the copy.\n' "$1"
    printf '  the code it patches has been restructured; update %s.\n' "$0"
    return 77
  fi
  note "control '$1': $3"
  WEB_UNDER_TEST="$dir"
  case "$4" in
    githubcom) run_scenario "control-$1" "https://github.com/acme/browser-smoke.git" github.com ;;
    *)         run_scenario "control-$1" "https://github.ghe.com/acme/browser-smoke.git" github.ghe.com ;;
  esac
  unset WEB_UNDER_TEST
  case "$RC" in
    1)
      printf '  \033[32m→ went RED, correctly\033[0m\n'
      grep -E '✗' "$LOG" | head -2 | sed 's/^/      /'
      return 0 ;;
    0)
      printf '  \033[31m→ PASSED a board whose links point at the wrong forge. The check\n'
      printf '     is decoration.\033[0m\n'
      sed -n '1,30p' "$LOG"
      return 1 ;;
    77)
      printf '  \033[33m→ skipped (infrastructure) — nothing proven\033[0m\n'
      return 77 ;;
    *)
      printf '  \033[31m→ exited %s — red for the WRONG REASON (3 = served without its\n' "$RC"
      printf '     stylesheet), so the control is inconclusive.\033[0m\n'
      sed -n '1,30p' "$LOG"
      return 1 ;;
  esac
}

calibrate_run() {
  say "RED CONTROLS — can this check actually go red?"
  note "artifacts: $WORK"
  local rc=0 r
  control_run frontend-reverted patch_frontend_reverted \
    "THE BUG VERBATIM — the front end hardcodes github.com again" enterprise; r=$?
  [ "$r" -ne 0 ] && rc=$r
  control_run daemon-silent patch_daemon_silent \
    "the front end is PERFECT and the daemon never sends the field" enterprise; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  control_run wrong-host patch_wrong_host \
    "the daemon sends a host — the wrong one" enterprise; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  control_run github-com-broken patch_github_com_broken \
    "github.com is broken for everyone else (run on the github.com scenario)" githubcom; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  printf '\n'
  case "$rc" in
    0) printf '\033[32mCONTROLS PASSED\033[0m — the check goes red when the front end hardcodes a\n'
       printf '  host, when the DAEMON silently stops sending one, when it sends the\n'
       printf '  wrong one, and when github.com itself is broken. It is not decoration —\n'
       printf '  and the second of those is the one no node harness can see.\n' ;;
    77) printf '\033[33mCONTROLS SKIPPED\033[0m — nothing proven.\n' ;;
    *) printf '\033[31mCONTROLS FAILED\033[0m — see above.\n' ;;
  esac
  return $rc
}

case "$MODE" in
  product)    product_run; exit $? ;;
  --calibrate|calibrate) calibrate_run; exit $? ;;
  --all|all)
    product_run; P=$?
    printf '\n'
    calibrate_run; C=$?
    [ "$P" -eq 0 ] && [ "$C" -eq 0 ] && exit 0
    [ "$P" -eq 77 ] || [ "$C" -eq 77 ] && exit 77
    exit 1 ;;
  *) printf 'usage: %s [--calibrate|--all]\n' "$0"; exit 2 ;;
esac
