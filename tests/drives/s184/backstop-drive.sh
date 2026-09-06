#!/usr/bin/env bash
# S184 verification — S183's backstops, stated correctly (the earlier rig POSTed
# {"title","body"} to /api/mission, which 400s on a missing `idea` BEFORE the
# foundation gate is ever consulted — so it proved nothing). Zero spend.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/verify/backstops"; rm -rf "$DEST"; mkdir -p "$DEST"
REPO="$(newrepo "s184-backstop")"
LOG="$DEST/calls.log"; : > "$LOG"; SHIM="$(make_shim "$LOG")"; fuse "$SHIM" || exit 99

echo "=== 4a. CLI: lcars file on a foundationless repo ==="
PRD="$DEST/prd.md"
cat > "$PRD" <<'P'
# PRD — personal finance website

**Problem:** I cannot see where my money goes.
**Goal:** A website that tracks transactions.
**Non-goals:** Bank sync.
**Acceptance criteria:**
- [ ] I can add a transaction and see it listed.
**Open questions:** none
P
drive "$REPO" "$SHIM" -- bash "$FILE_SH" --prd "$PRD"
echo "  [--prd] EXIT=$RC"; printf '%s\n' "$OUT" | head -12 | sed 's/^/  | /'
echo "$RC" > "$DEST/cli-file-prd.rc"; printf '%s\n' "$OUT" > "$DEST/cli-file-prd.out"
drive "$REPO" "$SHIM" -- bash "$FILE_SH" --park "a personal finance website"
echo "  [--park] EXIT=$RC"; printf '%s\n' "$OUT" | head -12 | sed 's/^/  | /'
echo "$RC" > "$DEST/cli-file-park.rc"
echo "  repo left untouched? .git/lcars = $(ls -A "$REPO/.git/lcars" 2>/dev/null | tr '\n' ' ' || echo ABSENT)"

start_daemon() { # extra-args… -> URL
  local tag="$1"; shift
  ( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT PATH="$SHIM:$PATH" \
      LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
      LCARS_WORKER_BIN="$SHIM/claude" LCARS_GH_BIN="$SHIM/claude" \
      python3 -m lcars_serve --port 0 --repo-root "$REPO" "$@" ) >"$DEST/$tag.daemon.log" 2>&1 &
  echo $! > "$DEST/$tag.pid"
  local u=""
  for _ in $(seq 1 200); do
    u="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$DEST/$tag.daemon.log" | head -1)"
    [ -n "$u" ] && break; sleep 0.1
  done
  echo "${u%/}"
}
post() { curl -s -o "$DEST/body" -w '%{http_code}' -X POST -H 'content-type: application/json' -d "$2" "$1$3"; }

U="$(start_daemon rw)"
echo; echo "=== 4b. POST /api/mission WITH a real idea (foundation gate) ==="
c="$(post "$U" '{"idea":"a personal finance website"}' /api/mission)"; echo "HTTP $c"; head -c 300 "$DEST/body"; echo
echo "$c" > "$DEST/api-mission.code"; cp "$DEST/body" "$DEST/api-mission.body"
echo; echo "=== 4c. POST /api/holodeck/start ==="
c="$(post "$U" '{"idea":"a personal finance website"}' /api/holodeck/start)"; echo "HTTP $c"; head -c 200 "$DEST/body"; echo
echo "$c" > "$DEST/api-holodeck.code"
kill "$(cat "$DEST/rw.pid")" 2>/dev/null

echo; echo "=== 4d. READ-ONLY daemon: POST /api/vision/file must be 403 ==="
U="$(start_daemon ro --read-only)"
c="$(post "$U" '{"idea":"x","stack":"Vite + React + Vitest"}' /api/vision/file)"; echo "HTTP $c"; head -c 200 "$DEST/body"; echo
echo "$c" > "$DEST/api-vision-ro.code"
echo "missions after read-only attempt: $(ls "$REPO/.git/lcars/missions" 2>/dev/null | wc -l | tr -d ' ')"
kill "$(cat "$DEST/ro.pid")" 2>/dev/null
echo "WORKER SPAWNS: $(calls "$LOG")  probes=$(probes "$LOG")"
