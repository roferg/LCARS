#!/usr/bin/env bash
# S184 tester — THE ONE LIVE LEG. A REAL copilot grill through the REAL
# viewscreen front door, in REAL headed Chrome. NO claude is reachable: the
# shim's `claude` refuses loudly rather than being absent, so nothing can
# silently find the billed one.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../s183b/rig.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="${1:-live1}"
OUT="$HERE/logs/$LABEL"; rm -rf "$OUT"; mkdir -p "$OUT"
CHROME="${LCARS_BROWSER_CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
# The REAL npm CLI, never the VS Code launcher shim: that shim re-resolves
# `copilot` from PATH, so with our wrapper first on PATH it recursed into itself
# (measured: 215 nested invocations, one hung turn of 7 minutes). Resolved via
# the shared helper (tests/drives/lib/real-worker.sh) rather than a bare
# `command -v` fallback, which is the exact idiom that let a shim through.
# shellcheck source=/dev/null
. "$HERE/../lib/real-worker.sh"
COPILOT="$(lcars_resolve_real_worker copilot "${LCARS_COPILOT_BIN:-}")" || { echo "no copilot"; exit 1; }

REPO="$(newrepo "s184-live-$LABEL")"
# --- the NO-CLAUDE fence: a real copilot, and a claude that screams ---------
SHIM="$(mktemp -d "${TMPDIR:-/tmp}/s184live.XXXXXX")"
cat > "$SHIM/copilot" <<SH
#!/usr/bin/env bash
# TEE-ING WRAPPER — the real copilot, with the VERBATIM prompt and the VERBATIM
# reply captured for the captain's readout. Nothing about the invocation changes.
n=\$(ls "$OUT"/turn-*.argv 2>/dev/null | wc -l | tr -d ' ')
i=\$(printf '%02d' \$((n+1)))
{ printf '=== ARGV (%s) ===\\n' "\$i"; for a in "\$@"; do printf -- '--- arg\\n%s\\n' "\$a"; done; } > "$OUT/turn-\$i.argv"
date +%s > "$OUT/turn-\$i.t0"
PATH="\${PATH#$SHIM:}" "$COPILOT" "\$@" > "$OUT/turn-\$i.out" 2> "$OUT/turn-\$i.err" </dev/null
rc=\$?
date +%s > "$OUT/turn-\$i.t1"
cat "$OUT/turn-\$i.out"
cat "$OUT/turn-\$i.err" >&2
exit \$rc
SH
chmod +x "$SHIM/copilot"
cat > "$SHIM/claude" <<'SH'
#!/usr/bin/env bash
echo "S184 LIVE FENCE: claude was invoked and is REFUSED (this leg is copilot-only). argv: $*" >&2
exit 97
SH
chmod +x "$SHIM/claude"
echo "fence: copilot=$COPILOT  claude=REFUSING STUB"

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
echo "daemon: $U repo=$REPO"

PROFILE="${TMPDIR:-/tmp}/lcars-s184-live/$LABEL"; rm -rf "$PROFILE"; mkdir -p "$PROFILE"
"$CHROME" --remote-debugging-port=0 --user-data-dir="$PROFILE" --no-first-run \
  --no-default-browser-check --window-size=1440,980 --disable-features=Translate,MediaRouter \
  about:blank >"$OUT/chrome.log" 2>&1 &
CPID=$!
DEV=""
for _ in $(seq 1 200); do [ -f "$PROFILE/DevToolsActivePort" ] && { DEV="$(head -1 "$PROFILE/DevToolsActivePort")"; break; }; sleep 0.1; done
cleanup(){ kill "$CPID" 2>/dev/null; kill "$DPID" 2>/dev/null; }
trap cleanup EXIT
[ -n "$DEV" ] || { echo "SKIP 77 chrome"; exit 77; }
echo "chrome devtools $DEV (HEADED)"

node "$HERE/live-probe.js" --devtools-port "$DEV" --url "$U" --out "$OUT" \
     --answers "${LIVE_ANSWERS:-$HERE/captain-answers.txt}" \
     --idea "$(cat "$HERE/captain-idea.txt")" --turns "${LIVE_TURNS:-10}" 2>&1 | tee "$OUT/probe.log"
echo "artifacts: $OUT"
echo "== filed missions:"; ls "$REPO/.git/lcars/missions" 2>/dev/null
echo "REPO=$REPO"
