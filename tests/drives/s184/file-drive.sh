#!/usr/bin/env bash
# S184 VERIFICATION — the live front door, end to end, to a FILED MISSION.
# REAL copilot (pinned npm CLI, never the VS Code launcher shim), REAL headed
# Chrome, REAL daemon, REAL blank repo. `claude` is a LOUDLY REFUSING stub that
# COUNTS every attempt, so no Claude spend can hide.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${1:-file1}"; MODE="${2:-accept}"
OUT="$HERE/logs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
# Resolved via the shared helper (tests/drives/lib/real-worker.sh) rather than
# a bare `command -v` fallback: that fallback can resolve to an editor's own
# re-invocation shim for `copilot`, which recurses with this rig's wrapper on
# PATH (measured 2026-09-15: fork-bombed to 5,538 processes).
# shellcheck source=/dev/null
. "$HERE/../lib/real-worker.sh"
COPILOT="$(lcars_resolve_real_worker copilot "${LCARS_COPILOT_BIN:-}")" || { echo "no copilot"; exit 1; }

if [ -n "${LIVE_REPO:-}" ]; then REPO="$LIVE_REPO"; else REPO="$(newrepo "s184-verify-$LABEL")"; fi
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/s184vfy.XXXXXX")"
cat > "$SHIM/copilot" <<SH
#!/usr/bin/env bash
n=\$(ls "$OUT"/turn-*.argv 2>/dev/null | wc -l | tr -d ' ')
i=\$(printf '%02d' \$((n+1)))
{ printf '=== ARGV (%s) ===\n' "\$i"; for a in "\$@"; do printf -- '--- arg\n%s\n' "\$a"; done; } > "$OUT/turn-\$i.argv"
date +%s > "$OUT/turn-\$i.t0"
PATH="\${PATH#$SHIM:}" "$COPILOT" "\$@" > "$OUT/turn-\$i.out" 2> "$OUT/turn-\$i.err" </dev/null
rc=\$?
date +%s > "$OUT/turn-\$i.t1"
echo "\$rc" > "$OUT/turn-\$i.rc"
cat "$OUT/turn-\$i.out"
cat "$OUT/turn-\$i.err" >&2
exit \$rc
SH
chmod +x "$SHIM/copilot"
cat > "$SHIM/claude" <<SH
#!/usr/bin/env bash
printf 'CLAUDE-FENCE-HIT\t%s\n' "\$*" >> "$OUT/claude-fence.log"
echo "S184 LIVE FENCE: claude was invoked and is REFUSED (copilot-only leg). argv: \$*" >&2
exit 97
SH
chmod +x "$SHIM/claude"
: > "$OUT/claude-fence.log"
echo "fence: copilot=$COPILOT  claude=REFUSING+COUNTING STUB"

( cd "$LCARS_SRC/web" && exec env -u LCARS_SERVE_PORT -u CLAUDECODE -u CLAUDE_CODE_SSE_PORT \
    PATH="$SHIM:$PATH" LCARS_SERVE_NO_OPEN=1 LCARS_VERSION_CHECK=0 \
    LCARS_WORKER_BIN="$SHIM/copilot" LCARS_GH_BIN=true \
    LCARS_LIVE_LOG="$OUT/worker.live.log" \
    python3 -m lcars_serve --port 0 --repo-root "$REPO" ) >"$OUT/daemon.log" 2>&1 &
DPID=$!
U=""
for _ in $(seq 1 200); do
  U="$(sed -n 's|.*\(http://127\.0\.0\.1:[0-9]*/\).*|\1|p' "$OUT/daemon.log"|head -1)"; [ -n "$U" ] && break; sleep 0.1
done
[ -n "$U" ] || { echo "FAIL: no daemon"; cat "$OUT/daemon.log"; kill $DPID; exit 1; }
echo "daemon: $U repo=$REPO  (pid $DPID)"

PROFILE="${TMPDIR:-/tmp}/lcars-s184-vfy/$LABEL"; rm -rf "$PROFILE"; mkdir -p "$PROFILE"
"$CHROME" --remote-debugging-port=0 --user-data-dir="$PROFILE" --no-first-run \
  --no-default-browser-check --window-size=1440,980 --disable-features=Translate,MediaRouter \
  about:blank >"$OUT/chrome.log" 2>&1 &
CPID=$!
DEV=""
for _ in $(seq 1 200); do [ -f "$PROFILE/DevToolsActivePort" ] && { DEV="$(head -1 "$PROFILE/DevToolsActivePort")"; break; }; sleep 0.1; done
cleanup(){ kill "$CPID" 2>/dev/null; kill "$DPID" 2>/dev/null; }
trap cleanup EXIT
[ -n "$DEV" ] || { echo "SKIP 77 chrome"; exit 77; }
echo "chrome devtools $DEV (HEADED, pid $CPID)"

node "$HERE/file-probe.js" --devtools-port "$DEV" --url "$U" --out "$OUT" \
     --answers "${LIVE_ANSWERS:-$HERE/captain-answers-coop.txt}" \
     --idea "$(cat "${LIVE_IDEA:-$HERE/captain-idea.txt}")" \
     --turns "${LIVE_TURNS:-10}" --chip-turn "${CHIP_TURN:-0}" \
     --mode "$MODE" --stack "${OVERRIDE_STACK:-Go + net/http + go test}" 2>&1 | tee "$OUT/probe.log"

echo "== CLAUDE FENCE HITS: $(wc -l < "$OUT/claude-fence.log" | tr -d ' ')"
echo "== COPILOT TURNS: $(ls "$OUT"/turn-*.argv 2>/dev/null | wc -l | tr -d ' ')"
echo "== RESUME vs FRESH:"
for f in "$OUT"/turn-*.argv; do
  [ -e "$f" ] || continue
  r="$(grep -c -- '--resume' "$f")"; s="$(grep -c -- '--session-id' "$f")"
  echo "  $(basename "$f") resume=$r session-id=$s"
done
echo "== filed missions:"; ls "$REPO/.git/lcars/missions" 2>/dev/null
echo "REPO=$REPO"
echo "OUT=$OUT"
