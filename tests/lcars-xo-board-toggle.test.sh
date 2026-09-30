#!/usr/bin/env bash
#
# Tests for THE BOARD'S NUMBER ONE TOGGLE (S222 BREAK C).
#
# Source under test: web/lcars_serve/actions.py → Actions.xo_on — the thing
# POST /api/xo/on calls. The shipping object, in process, against a stubbed
# `xo` script. ZERO SPEND: no worker CLI runs anywhere in this file.
#
# THE DEFECT. `lcars xo on` is not a quick command any more. Since S220 it ALSO
# sweeps every mission sitting at Verify with no score of Number One's — one at
# a time, each look caged at 45 minutes. Eight unscored missions is therefore up
# to six hours of work, and `xo_on` dispatched it with the BLOCKING `_run`,
# which has no timeout at all. One click on the board's toggle, one HTTP POST
# held open for the rest of the night. The config write and the banner happen
# BEFORE the sweep and the server is threaded, so the board did flip ON and the
# sweep did survive the client giving up — this is a hang the captain watches,
# not a correctness break, and that is exactly why it is worth curing: the one
# human action of the whole walk-away flow must not look broken.
#
# THE CURE, AND WHAT IT MAY NOT COST. Fire-and-forget would return instantly and
# throw away the one thing the blocking call was buying: an engine `xo.sh`
# refuses ("'foo' is not an engine on this machine") comes back as a 502 the
# board prints, and `dispatchCard` shows exactly that. A silent failure behind a
# spinner is worse than the hang. So the dispatch WAITS BRIEFLY — long enough
# for a refusal, which happens before the config is even written — and then lets
# the sweep go on in the background with its output captured.
#
# Usage: bash tests/lcars-xo-board-toggle.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WEB_DIR="$REPO_ROOT/web"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
qgrep(){ grep -E "$1" "$2" >/dev/null 2>&1; }

new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  mkdir -p "$repo/.git/lcars/missions"
  printf '{ "projectName": "repo" }\n' >"$repo/.git/lcars/config.json"
  echo "$repo"
}

# Drive the REAL dispatcher in process. The ANSWER goes to $ANS (a file, because
# a skill banner contains apostrophes and `check` evals its argument) and the
# elapsed milliseconds to $MS. An ActionError — what the board prints — is
# written as "ERR <message>".
ANS="$TMPROOT/answer.txt"
MS="$TMPROOT/elapsed.txt"
xo_on_via_daemon() { # <repo> <xo-stub> [engine]
  ( cd "$1" && LCARS_T_WEB="$WEB_DIR" LCARS_T_REPO="$1" LCARS_T_XO="$2" \
      LCARS_T_ENGINE="${3-copilot}" LCARS_T_ANS="$ANS" LCARS_T_MS="$MS" python3 -c '
import json, os, sys, time
sys.path.insert(0, os.environ["LCARS_T_WEB"])
from lcars_serve.actions import Actions, ActionError
a = Actions(repo_root=os.environ["LCARS_T_REPO"],
            scripts={"xo": os.environ["LCARS_T_XO"]})
t0 = time.time()
try:
    ans = json.dumps(a.xo_on(engine=os.environ["LCARS_T_ENGINE"]))
except ActionError as exc:
    ans = "ERR %s" % (exc,)
open(os.environ["LCARS_T_MS"], "w").write("%d" % int((time.time() - t0) * 1000))
open(os.environ["LCARS_T_ANS"], "w").write(ans)
' )
}
elapsed_under() { [ "$(tr -dc '0-9' <"$MS")" -lt "$1" ]; }

echo "lcars xo on — the board toggle (S222 BREAK C)"
[ -f "$WEB_DIR/lcars_serve/actions.py" ] || { echo "actions.py not found"; exit 1; }

# ==========================================================================
# 1. A SLOW SWEEP DOES NOT HOLD THE CLICK OPEN.
#
# The stub is `lcars xo on` on a night with unscored missions waiting: it prints
# its banner at once (as cmd_on does, before the sweep) and then works for a
# long time. The real thing would work for hours.
# ==========================================================================
echo
echo "1. a slow sweep does not hold the click open"

repo1="$(new_repo)"
XO_SLOW="$TMPROOT/xo-slow.sh"
cat >"$XO_SLOW" <<SLOW
#!/usr/bin/env bash
echo "NUMBER ONE: ON · copilot"
echo "  I'm reviewing 3 missions that were waiting at Verify with no score of mine."
sleep 20
echo "swept" >"$TMPROOT/swept.marker"
exit 0
SLOW
chmod +x "$XO_SLOW"
rm -f "$TMPROOT/swept.marker"
xo_on_via_daemon "$repo1" "$XO_SLOW"

check "1. the toggle came back fast — not held open by the sweep" \
  "elapsed_under 15000"
check "1. …and it did not raise: the board is told Number One is ON" \
  "qgrep '\"enabled\": true' '$ANS'"
check "1. …reporting the engine it engaged" \
  "qgrep '\"engine\": \"copilot\"' '$ANS'"
check "1. the sweep had NOT finished when the click returned" \
  "[ ! -e '$TMPROOT/swept.marker' ]"

# …and it really does go on sweeping after the click returned.
waited=0
while [ ! -e "$TMPROOT/swept.marker" ] && [ "$waited" -lt 40 ]; do sleep 1; waited=$((waited + 1)); done
check "1. the sweep SURVIVES the click returning (it is detached, not killed)" \
  "[ -e '$TMPROOT/swept.marker' ]"
check "1. its output is CAPTURED, not discarded" \
  "qgrep 'reviewing 3 missions' '$repo1/.git/lcars/logs/spawn-xo.log'"

# ==========================================================================
# 2. AN ENGINE THE MACHINE DOES NOT HAVE IS STILL REFUSED TO HIS FACE.
#
# `xo.sh` dies on that before it writes a single config key, so the refusal
# arrives in well under the grace. It must come back as the raise the board
# prints — NOT vanish into a spawn log behind a cheerful "enabled".
# ==========================================================================
echo
echo "2. a refusal still reaches the captain"

repo2="$(new_repo)"
XO_REFUSE="$TMPROOT/xo-refuse.sh"
cat >"$XO_REFUSE" <<'NOPE'
#!/usr/bin/env bash
echo "lcars xo: 'ansible' is not an engine on this machine — nothing was engaged." >&2
exit 1
NOPE
chmod +x "$XO_REFUSE"
xo_on_via_daemon "$repo2" "$XO_REFUSE" ansible
check "2. the dispatcher RAISES — the board prints this, it is not swallowed" \
  "qgrep '^ERR ' '$ANS'"
check "2. …carrying xo.sh's own sentence, so he knows what to fix" \
  "qgrep 'not an engine on this machine' '$ANS'"
check "2. …and the skill's exit code, not just its prose" \
  "qgrep 'exited 1' '$ANS'"
check "2. the refusal is quick (it happens before the sweep can start)" \
  "elapsed_under 15000"

# ==========================================================================
# 3. THE ORDINARY QUIET NIGHT still answers synchronously and truthfully:
#    nothing is waiting at Verify, so the sweep is over in a blink.
# ==========================================================================
echo
echo "3. a quiet night still answers straight away"

repo3="$(new_repo)"
XO_QUIET="$TMPROOT/xo-quiet.sh"
cat >"$XO_QUIET" <<'QUIET'
#!/usr/bin/env bash
echo "NUMBER ONE: ON · claude"
exit 0
QUIET
chmod +x "$XO_QUIET"
xo_on_via_daemon "$repo3" "$XO_QUIET" claude
check "3. it comes back enabled" \
  "qgrep '\"enabled\": true' '$ANS'"
check "3. …with the banner the skill printed, for the board to show" \
  "qgrep 'NUMBER ONE: ON' '$ANS'"

# ==========================================================================
# 4. THE ENGINE IS STILL VALIDATED AT THE DOOR — nothing that reads as a flag
#    or a path becomes an argv word, and a body with no engine is refused.
# ==========================================================================
echo
echo "4. the door checks are unchanged"

repo4="$(new_repo)"
xo_on_via_daemon "$repo4" "$XO_QUIET" "--help"
check "4. a leading dash is a flag, not an engine name" \
  "qgrep 'is not an engine name' '$ANS'"
xo_on_via_daemon "$repo4" "$XO_QUIET" ""
check "4. no engine at all is refused where the captain can see it" \
  "qgrep 'which engine should Number One use' '$ANS'"

# ==========================================================================
echo
printf 'lcars xo on (board toggle): %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
