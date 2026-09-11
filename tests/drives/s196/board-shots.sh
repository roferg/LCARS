#!/usr/bin/env bash
# S196 TESTER — the VISUAL WALKTHROUGH, shot off the real product in real
# headed Chrome, against the real fixture repo through real gh.
set -uo pipefail
REPO=/Users/roganferguson/Projects/LCARS
. "$REPO/tests/drives/s196/rig.sh"
S=/tmp/s189
SHOTS="$REPO/tests/drives/s196/shots"
mkdir -p "$SHOTS"
A="$(cat $S/s196-wt-A)"; B="$(cat $S/s196-wt-B)"
MID="$(cat $S/s196-wt-mid)"; ISSUE="$(cat $S/s196-wt-issue)"
SHIM="$(cat $S/s196-wt-shim)"; GHREC="$(cat $S/s196-wt-gh)"
OUT=/tmp/s196/board; mkdir -p "$OUT"
WHICH="${1:-A}"
ROOT="$A"; [ "$WHICH" = B ] && ROOT="$B"
echo "== board of laptop $WHICH ($ROOT) — mission $MID issue #$ISSUE =="
start_daemon "$ROOT" "$OUT/$WHICH" PATH="$SHIM:$PATH" LCARS_GH_BIN="$GHREC" LCARS_WORKER_BIN="$SHIM/claude" || exit 1
start_chrome "$OUT/$WHICH" || exit 1
shift 2>/dev/null
node "$REPO/tests/drives/s196/shoot.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" --out "$SHOTS" --wait-for ".card" --shots "$*"
echo "PIDS_STARTED:$S196_PIDS"
echo "URL:$BOARD_URL"
