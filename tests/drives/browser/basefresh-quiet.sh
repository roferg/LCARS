#!/usr/bin/env bash
# ============================================================================
# S164 — THE QUIET BASE-FRESHNESS LINE, IN A REAL BROWSER.
#
#   bash tests/drives/browser/basefresh-quiet.sh              # the product
#   bash tests/drives/browser/basefresh-quiet.sh --calibrate   # the RED CONTROL
#   bash tests/drives/browser/basefresh-quiet.sh --all         # both
#
# WHAT IS BEING PROVEN. The captain filed from a checkout one commit behind
# origin. GET /api/base-freshness answered:
#
#   {"verdict":"stale","loud":false,"behindBy":1, "reason":"local 'main' is 1
#    commit(s) behind origin and fast-forwards cleanly, but this was a READ-ONLY
#    check — nothing was moved. Filing a Mission brings 'main' up to date first."}
#
# …and the File console showed NOTHING, because the pre-flight was gated on
# `loud`. His ruling: tell me — QUIETLY. One calm informational line. Explicitly
# not a warning: no amber, no alarm colour, no call to action; muted metadata.
#
# WHY A BROWSER AND NOT A UNIT TEST. Every harness under web/tests/ is a STUB OF
# A BROWSER — no cascade, no layout, no paint, and each one calls render() for
# itself. S163's board was blank in Chrome for three fix rounds while 1,162 of
# them stayed green. S162 shipped an amber warning that rendered as muted
# metadata, with a test asserting the CSS rule existed sitting green beside it.
# So the claims here are MEASURED off the live element: a real non-zero bounding
# box, the colour the cascade actually resolved, and the contrast of that colour
# composited over whatever is really painted behind it.
#
# THE RED CONTROL is not optional, and it is the reason for --calibrate. A check
# that cannot go red proves nothing. It patches a COPY of web/ two ways — the
# line ABSENT (the pre-S164 gate, verbatim) and the line WEARING THE WARNING
# TREATMENT (the S162 disease, deliberately reintroduced) — and requires the
# check to fail on both. This repo's own web/ is never touched.
#
# EXIT: 0 proven · 1 the product (or, under --calibrate, the CHECK) is wrong ·
#       77 skipped / infrastructure — loudly, and never a pass.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
MODE="${1:-product}"

WORK="${LCARS_BROWSER_BF_OUT:-}"
if [ -z "$WORK" ]; then
  n=0                                  # keep the 2 newest, plus this one
  for d in $(ls -dt "${TMPDIR:-/tmp}"/lcars-browser-bf.?????? 2>/dev/null); do
    n=$((n + 1)); [ "$n" -le 2 ] && continue
    case "$d" in "${TMPDIR:-/tmp}"/lcars-browser-bf.??????) [ -d "$d" ] && rm -rf "$d" ;; esac
  done
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/lcars-browser-bf.XXXXXX")"
fi
mkdir -p "$WORK"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# ── the record: the captain's own, measured on a real fixture 2026-08-02 ────
# Verbatim from the endpoint, not paraphrased. The rig serves it through a stub
# reporter so a real Chrome sees exactly the state he was in.
cat >"$WORK/record.json" <<'JSON'
{ "verdict": "stale", "loud": false,
  "reason": "local 'main' is 1 commit(s) behind origin and fast-forwards cleanly, but this was a READ-ONLY check — nothing was moved. Filing a Mission brings 'main' up to date first.",
  "fix": "", "fixNote": "", "blocker": "",
  "behindBy": 1, "aheadBy": 0, "baseSha": "ccc3333",
  "checkedAt": "2026-08-02T09:00:00Z", "missionBranchAtBase": null }
JSON

# The expectation. `reasonSubstring` is a slice of the guard's OWN sentence: the
# front end must render the record's words, not a second freshness vocabulary of
# its own (the S158/S160 principle — loudness and wording are CARRIED).
cat >"$WORK/expect.json" <<'JSON'
{ "mode": "quiet",
  "reasonSubstring": "1 commit(s) behind origin and fast-forwards cleanly",
  "minContrast": 4.5 }
JSON

run_against() {   # $1 = web dir, $2 = run name → sets RC, LOG
  LOG="$WORK/$2.log"
  LCARS_BROWSER_WEB_DIR="$1" \
  LCARS_BROWSER_OUT="$WORK/$2" \
  LCARS_BROWSER_BASEFRESH="$WORK/record.json" \
  LCARS_BROWSER_CONSOLE_CHECK="$WORK/expect.json" \
    bash "$HERE/smoke.sh" >"$LOG" 2>&1
  RC=$?
}

# ── the product ─────────────────────────────────────────────────────────────
product_run() {
  say "S164 — the quiet base-freshness line, in real Chrome"
  note "artifacts: $WORK"
  run_against "$REPO/web" product
  case "$RC" in
    0)
      printf '\n\033[32mPROVEN\033[0m — the quiet line is really on the screen.\n'
      grep -E 'file console:|it says:' "$LOG" | sed 's/^/  /'
      printf '  screenshot: %s/product/file-console.png  — OPEN IT AND LOOK.\n' "$WORK"
      printf '  measurements: %s/product/console-check.json\n' "$WORK"
      return 0 ;;
    77)
      printf '\n\033[33mSKIPPED\033[0m — infrastructure, nothing proven.\n'
      sed -n '1,25p' "$LOG"
      return 77 ;;
    3)
      printf '\n\033[31mINCONCLUSIVE\033[0m — the app was served WITHOUT its stylesheet, so any\n'
      printf '  colour read off that page is a phantom.\n'
      sed -n '1,40p' "$LOG"
      return 1 ;;
    *)
      printf '\n\033[31mFAILED\033[0m — the File console does not show the quiet line correctly.\n'
      grep -E '✗|THE FILE CONSOLE|THE BOARD DID NOT PAINT' "$LOG" | sed 's/^/  /'
      printf '  full log:   %s\n' "$LOG"
      printf '  screenshot: %s/product/file-console.png\n' "$WORK"
      return 1 ;;
  esac
}

# ── the red control ─────────────────────────────────────────────────────────
# Each variant patches a COPY and must make the check FAIL. A patch that did not
# apply is a rig fault and exits 77: a control that silently tested the healthy
# product would be the most flattering possible lie.
make_copy() {   # $1 = name → echoes the web dir
  local dst="$WORK/web-$1"
  rm -rf "$dst"; mkdir -p "$dst"
  cp -R "$REPO/web/lcars_serve" "$REPO/web/static" "$dst/"
  rm -rf "$dst/lcars_serve/__pycache__"
  printf '%s' "$dst"
}

patch_absent() {   # the pre-S164 gate, verbatim: quiet records say nothing
  local js="$1/static/board.js"
  grep -q 'if (!bf) return;' "$js" || return 1
  /usr/bin/sed -i '' 's/if (!bf) return;/if (!bf || !bf.loud) return;/' "$js"
  grep -q 'if (!bf || !bf.loud) return;' "$js"
}

patch_warning() {  # it speaks, but dressed as the alarm (the S162 disease)
  local js="$1/static/board.js"
  grep -q ': baseFreshnessQuietLine(bf);' "$js" || return 1
  /usr/bin/sed -i '' 's/: baseFreshnessQuietLine(bf);/: baseFreshnessBlock(bf, "bf-body");/' "$js"
  /usr/bin/sed -i '' 's/if (!bf.loud) wrap.className = "file-basefresh quiet";//' "$js"
  ! grep -q 'baseFreshnessQuietLine(bf);' "$js" && ! grep -q 'file-basefresh quiet' "$js"
}

# The two above make the LINE wrong; these two make its STYLING wrong while
# leaving the element exactly where it is. They exist because the first pair
# fails early ("no .bf-quiet line") and so never exercises the colour, panel and
# contrast assertions — and an assertion that is never exercised by a control is
# an assertion nobody has shown can go red. This is the S162 defect precisely:
# the rule is in the stylesheet, and what reaches the screen is the other one.
patch_amber() {    # the quiet line, repainted as the amber warning
  local css="$1/static/board.css"
  grep -q '^\.file-basefresh\.quiet{background:none;box-shadow:none;padding:0;$' "$css" || return 1
  /usr/bin/sed -i '' 's/^\.file-basefresh\.quiet{background:none;box-shadow:none;padding:0;$/.file-basefresh.quiet{/' "$css"
  /usr/bin/sed -i '' 's/^  color:var(--lcars-text,#eee);opacity:\.8}$/  color:var(--lcars-amber);opacity:1}/' "$css"
  grep -q 'color:var(--lcars-amber);opacity:1}' "$css" &&
    ! grep -q '^\.file-basefresh\.quiet{background:none' "$css"
}

patch_invisible() {  # "muted" quietly become unreadable — the other failure mode
  local css="$1/static/board.css"
  grep -q '^  color:var(--lcars-text,#eee);opacity:\.8}$' "$css" || return 1
  /usr/bin/sed -i '' 's/^  color:var(--lcars-text,#eee);opacity:\.8}$/  color:var(--lcars-text,#eee);opacity:.06}/' "$css"
  grep -q 'opacity:\.06}' "$css"
}

control_run() {   # $1 = name, $2 = patch fn, $3 = description
  local dir; dir="$(make_copy "$1")"
  if ! "$2" "$dir"; then
    printf '\n\033[33mCONTROL CANNOT RUN\033[0m — the "%s" patch did not apply to the copy.\n' "$1"
    printf '  board.js has been restructured; update %s.\n' "$0"
    return 77
  fi
  note "control '$1': $3"
  run_against "$dir" "control-$1"
  case "$RC" in
    1)
      printf '  \033[32m→ went RED, correctly\033[0m\n'
      grep -E '✗' "$LOG" | head -4 | sed 's/^/      /'
      return 0 ;;
    0)
      printf '  \033[31m→ PASSED a broken console. The check is decoration.\033[0m\n'
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
  say "RED CONTROL — can this check actually go red?"
  note "artifacts: $WORK"
  local rc=0 r
  control_run absent patch_absent \
    "the pre-S164 gate restored — a quiet record renders nothing"; r=$?
  [ "$r" -ne 0 ] && rc=$r
  control_run warning patch_warning \
    "the line speaks, but wearing the amber warning treatment"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  control_run amber patch_amber \
    "the line stays, its quiet styling is stripped — amber panel, amber text"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  control_run invisible patch_invisible \
    "the line stays and is muted to the point of being unreadable"; r=$?
  [ "$r" -ne 0 ] && { [ "$rc" -eq 0 ] && rc=$r; }
  printf '\n'
  case "$rc" in
    0) printf '\033[32mCONTROLS PASSED\033[0m — the check goes red when the line is missing, when\n'
       printf '  it is dressed as a warning, when the amber panel reaches it, and when it\n'
       printf '  is muted into unreadability. It is not decoration.\n' ;;
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
