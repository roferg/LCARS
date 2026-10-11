#!/usr/bin/env bash
#
# S249 — LIVE TARGETS BY CONSENT: a step may reach a real host ONLY when the
# record names it, and the credential is the HARNESS'S to hold.
#
# THE MEASURED PROBLEM. `step_env` (xo-run.py) BUILDS the env — PATH, LANG, HOME,
# TMPDIR plus the step's declared keys — so no credential has ever reached a
# step. A real `publish` was therefore impossible, and 5 of the 29 bugs the
# buddy's weekend found needed one. Nothing blocked the network either: the fence
# was "no credentials" BY ACCIDENT, not by record. Meanwhile the consent record
# the captain actually wrote — `autopilot.json liveTargets {host, owners}` — was
# read by the buddy and by nothing in `skills/lcars-xo/`.
#
# WHAT THIS FILE DRIVES:
#   1  NO CONSENT RECORD → a `live:` step is REFUSED with the sentence
#      "needs a live target: <h>/<o> is not in liveTargets", recorded like any
#      other refusal; its criterion reads `untested (needs a live target)`; and
#      the recommendation is NOT a send-back — an unreachable high-impact row
#      whose only reason is "needs a live target" is OUR infrastructure.
#   2  CONSENT FOR host H owner O → the step RUNS with GH_HOST=H and a real
#      token, the LOCAL FORGE SAW THE Authorization HEADER, the transcript and
#      the readout show `GH_TOKEN=<redacted>` — and a step naming owner P is
#      REFUSED.
#   3  a consented step's `liveEffects` land in `xo/live.json` and the report
#      lists them under "What I touched live".
#   4  THE WORKER CANNOT GRANT ITSELF CONSENT: a `live:` host that is not in the
#      record is refused EVEN WHEN the step also sets `GH_HOST` in its env, and a
#      worker-declared `GH_TOKEN`/`GH_HOST` is STRIPPED from every step.
#   5  THE GREP CONTROL: the token string appears in NO file under `xo/`. The
#      detector is shown to FIRE on a planted token, so it is not blind.
#
# AND THE FENCE DID NOT MOVE FURTHER THAN THAT. S249 widens ONE thing —
# credentials for an allow-listed host. The argv fence is unchanged, and a
# CONSENTED step asking for a shell is still refused for being a shell.
#
# THE RIG IS LOCAL AND REAL: a python HTTP "forge" that LOGS the Authorization
# header it is sent, and `gh` shimmed to print a known fake token. No GitHub.
#
# ZERO SPEND. A PATH shim fakes BOTH `claude` and `copilot` and counts every
# invocation; the count is asserted to be 0.
#
# Usage: bash tests/lcars-xo-live-consent.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
SCOREPY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$REPO_ROOT/tests/lib/cage.py"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
FORGE_PID=""
cleanup() {
  if [ -n "$FORGE_PID" ]; then
    kill "$FORGE_PID" 2>/dev/null
    wait "$FORGE_PID" 2>/dev/null
  fi
  [ -d "$TMPROOT/prod" ] && git -C "$TMPROOT/prod" worktree prune >/dev/null 2>&1
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND -------------------------------------------------------------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
SPEND_LOG="$TMPROOT/spend.log"
: >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

# --- THE CREDENTIAL, FAKED BUT REAL-SHAPED ----------------------------------
# One known string. Nothing in any artifact may ever contain it, and the forge's
# own log (which is the RIG's, not an artifact) is where we prove it travelled.
TOKEN="ghp_FAKE249TOKENd0n0tl0g_7f3a9b1c"
GH_SHIM="$TMPROOT/gh-shim"; mkdir -p "$GH_SHIM"
GH_CALLS="$TMPROOT/gh-calls.log"; : >"$GH_CALLS"
cat >"$GH_SHIM/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$GH_CALLS"
if [ "\$1" = "auth" ] && [ "\$2" = "token" ]; then
  printf '%s\n' "$TOKEN"
  exit 0
fi
exit 1
SH
chmod +x "$GH_SHIM/gh"
export LCARS_GH_BIN="$GH_SHIM/gh"

echo "lcars xo — LIVE TARGETS BY CONSENT: the record decides, the harness holds the credential"

# ===========================================================================
# THE LOCAL FORGE — a real HTTP server that logs the Authorization header
# ===========================================================================
FORGE_LOG="$TMPROOT/forge.log"; : >"$FORGE_LOG"
cat >"$TMPROOT/forge.py" <<'PYEOF'
import http.server, json, sys
LOG = sys.argv[1]


class H(http.server.BaseHTTPRequestHandler):
    def _handle(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except Exception:
            n = 0
        if n:
            self.rfile.read(n)
        with open(LOG, "a") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "authorization": self.headers.get("Authorization") or "",
                "ghHost": self.headers.get("X-Gh-Host") or "",
            }) + "\n")
        body = b'{"ok": true, "url": "https://forge.local/r/1"}'
        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = _handle
    do_POST = _handle

    def log_message(self, *a):
        pass


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print("FORGE: http://127.0.0.1:%d" % srv.server_address[1], flush=True)
srv.serve_forever()
PYEOF
"$PY" "$TMPROOT/forge.py" "$FORGE_LOG" >"$TMPROOT/forge.out" 2>&1 &
FORGE_PID=$!
FORGE_URL=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  FORGE_URL="$(sed -n 's/^FORGE: //p' "$TMPROOT/forge.out" | head -1)"
  [ -n "$FORGE_URL" ] && break
  sleep 0.2
done
echo ""
echo "0. the rig itself"
check "0a. the local forge is up and answering" \
  '[ -n "$FORGE_URL" ] && "$PY" -c "import urllib.request,sys;urllib.request.urlopen(sys.argv[1]+\"/ping\",timeout=5).read()" "$FORGE_URL"'
# The forge saw that ping with NO credential — the control that proves the log
# records what it is sent rather than what we hope.
check "0b. the forge LOGS what it was sent (the ping arrived with no credential)" \
  'grep -q "\"authorization\": \"\"" "$FORGE_LOG"'
: >"$FORGE_LOG"
check "0c. the gh shim hands back the fake token" \
  '[ "$("$LCARS_GH_BIN" auth token -h forge.local)" = "$TOKEN" ]'
# That control was itself a call, so the log starts clean for the real measurement.
: >"$GH_CALLS"

# ===========================================================================
# THE PRODUCT — a tiny CLI that publishes to whatever forge it is pointed at,
# with the credential it finds in its environment. It is CARELESS on purpose in
# `env-dump`: it prints GH_TOKEN verbatim, which is exactly the shape that leaks
# a credential into an artifact, and the harness has to survive it.
# ===========================================================================
PROD="$TMPROOT/prod"; mkdir -p "$PROD"
git -C "$PROD" init -q -b main
cat >"$PROD/relay.py" <<'PYEOF'
import os
import sys
import urllib.request

args = sys.argv[1:]
host = os.environ.get("GH_HOST", "")
tok = os.environ.get("GH_TOKEN", "")
forge = os.environ.get("RELAY_FORGE", "")

if not args or args[0] in ("--help", "-h"):
    print("usage: relay [publish|env-dump]")
    sys.exit(0)
if args[0] == "publish":
    if not forge:
        sys.stderr.write("relay: no forge configured\n")
        sys.exit(3)
    req = urllib.request.Request(forge + "/repos/" + (host or "nohost") + "/publish",
                                 data=b"{}")
    if tok:
        req.add_header("Authorization", "token " + tok)
    req.add_header("X-Gh-Host", host)
    with urllib.request.urlopen(req, timeout=10) as r:
        print("published: %s" % r.read().decode())
    print("GH_HOST=%s" % host)
    print("credential: %s" % ("present" if tok else "absent"))
    sys.exit(0)
if args[0] == "env-dump":
    for k in ("GH_HOST", "GH_TOKEN", "GITHUB_TOKEN", "LCARS_XO_LIVE"):
        print("%s=%s" % (k, os.environ.get(k, "")))
    sys.exit(0)
sys.stderr.write("relay: no such subcommand %s\n" % args[0])
sys.exit(2)
PYEOF
git -C "$PROD" add -A >/dev/null 2>&1
git -C "$PROD" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$PROD" branch -q feat/relay 2>/dev/null

LCARS="$PROD/.git/lcars"
mkdir -p "$LCARS/missions"
printf '{\n  "numberOne": {"enabled": true}\n}\n' >"$LCARS/config.json"

HOST="forge.local"
OWNER="roferg"

# consent_none / consent_autopilot / consent_config — the RECORD, written three
# ways, because where consent is read from is half of what this session builds.
consent_none()      { rm -f "$LCARS/autopilot.json"
                      printf '{\n  "numberOne": {"enabled": true}\n}\n' >"$LCARS/config.json"; }
consent_autopilot() { printf '{"liveTargets": {"host": "%s", "owners": ["%s"]}}\n' \
                        "$1" "$2" >"$LCARS/autopilot.json"; }
consent_config()    { rm -f "$LCARS/autopilot.json"
                      printf '{"numberOne": {"enabled": true, "liveTargets": {"host": "%s", "owners": ["%s"]}}}\n' \
                        "$1" "$2" >"$LCARS/config.json"; }

mission() { # <name> → echoes the mission dir, with its xo/ tree ready
  local d="$LCARS/missions/$1"
  mkdir -p "$d/xo/shots/look-1"
  : >"$d/number-one.jsonl"
  printf '%s' "$d"
}

drive() { # <mission-dir> <journey.json> → runs the reach, caged
  "$PY" "$CAGE" 180 "$PY" "$XORUN" run --journey "$2" --repo "$PROD" \
    --branch feat/relay --out "$1/xo/shots/look-1" --mission-dir "$1" \
    >"$1/run.out" 2>&1
}

readout() { # <mission-dir> <stem> <python expr over d> — true/false
  "$PY" - "$1/xo/shots/look-1/$2.json" "$3" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if eval(sys.argv[2]) else 1)
P
}

# ===========================================================================
# 1. NO CONSENT RECORD — the step is refused, and it says what is missing
# ===========================================================================
echo ""
echo "1. NO CONSENT RECORD — a live step is refused, by name"
consent_none
M1="$(mission m-noconsent)"
cat >"$TMPROOT/j1.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "L1", "for": "prd-3", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "liveEffects": [{"kind": "run", "name": "a publish on $HOST"}],
   "evidence": "01-publish.txt", "expect": {"exit": 0}}
]}
JSON
drive "$M1" "$TMPROOT/j1.json"
check "1a. the run TERMINATES (not caged out)" \
  '! grep -q "TIMED OUT" "$M1/run.out"'
check "1b. the live step is REFUSED" \
  'readout "$M1" 01-publish "d.get(\"refused\") is True"'
check "1c. the refusal is the SENTENCE, naming host/owner and liveTargets" \
  'readout "$M1" 01-publish "\"needs a live target: '"$HOST"'/'"$OWNER"' is not in liveTargets\" in (d.get(\"why\") or \"\")"'
check "1c2. and it is ONE plain sentence, like every other refusal" \
  'readout "$M1" 01-publish "0 < len(d.get(\"why\") or \"\") < 300 and chr(10) not in (d.get(\"why\") or \"x\")"'
check "1d. the command NEVER RAN — the forge saw nothing" \
  '[ ! -s "$FORGE_LOG" ]'
check "1e. the transcript says the command was NOT run" \
  'grep -q "NOT run" "$M1/xo/shots/look-1/01-publish.txt"'
check "1f. the refusal is JOURNALED like any other refusal" \
  'grep -q "step-refused" "$M1/number-one.jsonl"'
check "1g. no credential was even looked up — gh was never called" \
  '[ ! -s "$GH_CALLS" ]'
check "1h. xo/live.json records the refusal against its criterion" \
  '"$PY" - "$M1/xo/live.json" <<'"'"'P'"'"'
import json, sys
d = json.load(open(sys.argv[1]))
r = d.get("refused") or []
sys.exit(0 if any(x.get("criterion") == "prd-3" and "not in liveTargets" in (x.get("why") or "")
                  for x in r) else 1)
P'

# --- and what the CAPTAIN then reads ---------------------------------------
# A ledger of three high-impact rows. prd-3 is the live one; the other two were
# genuinely checked, so this is not the "nothing checked" case.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "relay publish names the host it was given", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "relay --help lists its subcommands", "source": "prd", "primary": true},
  {"id": "prd-3", "text": "publish reaches the real forge and the page shows the host", "source": "prd", "primary": true}
 ]}
C
# THE LEDGER THE LOOK WROTE. The met rows are the shape an existing green suite
# proves settles a row (a picture, cited, at `looks`) — so prd-3 is `met` in the
# CONTROL and the only thing that moves it is this session's own rail.
cat >"$TMPROOT/worker.json" <<'W'
{"score": "high", "summary": "What I could reach worked.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "it is why prd-1 exists", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks",
  "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "it is why prd-2 exists", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks",
  "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."},
 {"id": "prd-3", "impact": "high", "impactWhy": "it is why prd-3 exists", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks",
  "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."}
], "gaps": []}
W

# AND THE SHARPEST CASE: a ledger whose ONLY row is the live one. Settled rows: 0.
# `derive_recommendation`'s S248 floor ("not one row settled → send-back") would
# fire here, and that is exactly the send-back this session must not produce —
# the hole is OUR missing credential, not his build.
cat >"$TMPROOT/criteria-live-only.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-3", "text": "publish reaches the real forge and the page shows the host", "source": "prd", "primary": true}
 ]}
C
cat >"$TMPROOT/worker-live-only.json" <<'W'
{"score": "high", "summary": "The one thing I had to check needs a real host.", "criteria": [
 {"id": "prd-3", "impact": "high", "impactWhy": "it is why prd-3 exists", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks",
  "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."}
], "gaps": []}
W

score() { # <out-dir> <live.json or ""> [worker.json] [criteria.json]
  mkdir -p "$1"
  "$PY" "$CAGE" 240 "$PY" "$SCOREPY" "${3:-$TMPROOT/worker.json}" \
    "${4:-$TMPROOT/criteria.json}" \
    "$1/verdict.json" "" "" "" "" "" "" "" "" "" "" "" "" "$2" \
    >"$1/out.txt" 2>"$1/err.txt"
}
row() { # <out-dir> <criterion> <expr over r>
  "$PY" - "$1/verdict.json" "$2" "$3" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
rows = [c for c in d.get("criteria") or [] if c.get("id") == sys.argv[2]]
if not rows:
    sys.exit(1)
r = rows[0]
sys.exit(0 if eval(sys.argv[3]) else 1)
P
}

S1="$TMPROOT/score-noconsent"
score "$S1" "$M1/xo/live.json"
check "1i. the scored verdict exists" '[ -s "$S1/verdict.json" ]'
check "1j. prd-3 is UNTESTED — a row nobody could reach is never met" \
  'row "$S1" prd-3 "r.get(\"status\") == \"untested\""'
check "1k. its recorded reason is needs-a-live-target" \
  'row "$S1" prd-3 "r.get(\"couldNotCheck\") == \"needs-a-live-target\""'
check "1l. the cause is OURS — infrastructure, never the build" \
  'row "$S1" prd-3 "r.get(\"cause\") == \"infrastructure\""'
check "1m. the report's row reads UNTESTED (needs a live target)" \
  'grep -q "UNTESTED (needs a live target)" "$S1/report.md"'
check "1n. the RECOMMENDATION IS NOT A SEND-BACK" \
  '"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get(\"recommendation\") != \"send-back\" else 1)" "$S1/verdict.json"'
check "1o. it is a FOLLOW-UP, and the follow-up names the live target" \
  '"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));f=\" \".join(d.get(\"followUps\") or []);sys.exit(0 if \"live target\" in f else 1)" "$S1/verdict.json"'
# THE CONTROL BESIDE IT: the SAME ledger with no live record at all still has
# prd-3 as the look rated it. Without this, 1j–1n could be measuring the
# scorer's ordinary behaviour rather than this session's rail.
S1C="$TMPROOT/score-control"
score "$S1C" ""
check "1p. CONTROL — with no live record the same ledger leaves prd-3 met" \
  'row "$S1C" prd-3 "r.get(\"status\") == \"met\""'
check "1q. CONTROL — and says nothing about a live target" \
  '! grep -q "needs a live target" "$S1C/report.md"'

# THE SHARPEST CASE — one row, and it is the live one.
S1L="$TMPROOT/score-live-only"
score "$S1L" "$M1/xo/live.json" "$TMPROOT/worker-live-only.json" "$TMPROOT/criteria-live-only.json"
check "1r. a ledger whose ONLY row needs a live target is STILL not a send-back" \
  '"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if d.get(\"recommendation\") != \"send-back\" else 1)" "$S1L/verdict.json"'
check "1s. CONTROL — the same single-row ledger, blind for ANY OTHER reason, IS a send-back" \
  '"$PY" - "$TMPROOT" "$SCOREPY" <<'"'"'P'"'"'
import json, os, subprocess, sys
tmp, score = sys.argv[1], sys.argv[2]
w = json.load(open(os.path.join(tmp, "worker-live-only.json")))
w["criteria"][0].update({"status": "untested", "couldNotCheck": "unreachable",
                         "cause": "product", "evidence": "none"})
w["criteria"][0].pop("shot", None)
p = os.path.join(tmp, "worker-blind.json")
json.dump(w, open(p, "w"))
out = os.path.join(tmp, "score-blind")
os.makedirs(out, exist_ok=True)
subprocess.run([sys.executable, score, p,
                os.path.join(tmp, "criteria-live-only.json"),
                os.path.join(out, "verdict.json")],
               capture_output=True)
d = json.load(open(os.path.join(out, "verdict.json")))
sys.exit(0 if d.get("recommendation") == "send-back" else 1)
P'

# ===========================================================================
# 2. CONSENT FOR host H owner O — the step runs, the forge sees the header
# ===========================================================================
echo ""
echo "2. CONSENT, from autopilot.json — the step runs and the credential travels"
consent_autopilot "$HOST" "$OWNER"
: >"$FORGE_LOG"; : >"$GH_CALLS"
M2="$(mission m-consented)"
cat >"$TMPROOT/j2.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "L1", "for": "prd-3", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "liveEffects": [{"kind": "run", "name": "publish #1"},
                   {"kind": "branch", "name": "xo-probe-249"}],
   "evidence": "01-publish.txt", "expect": {"exit": 0, "stdoutIncludes": "credential: present"}},
  {"do": "run", "key": "L2", "for": "prd-4", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL"},
   "live": {"host": "$HOST", "owner": "nemesis"},
   "evidence": "02-other-owner.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "L3", "for": "prd-5", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "env-dump"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "03-env-live.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "L4", "for": "prd-6", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "env-dump"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "evidence": "04-env-plain.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "L5", "for": "prd-7", "fromChecklist": "cli#7",
   "argv": ["bash", "-c", "echo pwned"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "05-shell.txt", "expect": {"exit": 0}}
]}
JSON
drive "$M2" "$TMPROOT/j2.json"
check "2a. the run TERMINATES" '! grep -q "TIMED OUT" "$M2/run.out"'
check "2b. the consented step RAN and met its expectation" \
  'readout "$M2" 01-publish "d.get(\"met\") is True and not d.get(\"refused\")"'
check "2c. it ran with GH_HOST set to the consented host" \
  'grep -q "GH_HOST='"$HOST"'" "$M2/xo/shots/look-1/01-publish.txt"'
check "2d. THE FORGE SAW THE Authorization HEADER, carrying the real token" \
  'grep -q "token '"$TOKEN"'" "$FORGE_LOG"'
check "2e. the forge was told the consented host" \
  'grep -q "\"ghHost\": \"'"$HOST"'\"" "$FORGE_LOG"'
check "2f. the credential was looked up by the HARNESS, with gh auth token -h" \
  'grep -q "auth token -h '"$HOST"'" "$GH_CALLS"'
check "2g. the TRANSCRIPT shows GH_TOKEN=<redacted>" \
  'grep -q "GH_TOKEN=<redacted>" "$M2/xo/shots/look-1/01-publish.txt"'
check "2h. the READOUT shows GH_TOKEN=<redacted>" \
  'readout "$M2" 01-publish "\"GH_TOKEN=<redacted>\" in json.dumps(d)"'
check "2i. the readout records WHICH consent allowed it, and from where" \
  'readout "$M2" 01-publish "(d.get(\"live\") or {}).get(\"host\") == \"'"$HOST"'\" and (d.get(\"live\") or {}).get(\"owner\") == \"'"$OWNER"'\" and \"autopilot\" in ((d.get(\"live\") or {}).get(\"consentedBy\") or \"\")"'
check "2j. A STEP NAMING ANOTHER OWNER IS REFUSED, by name" \
  'readout "$M2" 02-other-owner "d.get(\"refused\") is True and \"needs a live target: '"$HOST"'/nemesis is not in liveTargets\" in (d.get(\"why\") or \"\")"'
check "2k. LCARS_XO_LIVE=1 is set on a consented step" \
  'grep -q "LCARS_XO_LIVE=1" "$M2/xo/shots/look-1/03-env-live.txt"'
check "2l. and NOT on a step that asked for nothing live" \
  'grep -q "LCARS_XO_LIVE=$" "$M2/xo/shots/look-1/04-env-plain.txt"'
check "2m. a plain step still gets NO credential at all" \
  'grep -q "GH_TOKEN=$" "$M2/xo/shots/look-1/04-env-plain.txt"'
check "2n. THE FENCE DID NOT WIDEN — a consented step asking for a shell is still refused" \
  'readout "$M2" 05-shell "d.get(\"refused\") is True and \"shell\" in (d.get(\"why\") or \"\")"'
check "2o. the refused shell NEVER ran" \
  '! grep -q "pwned" "$M2/xo/shots/look-1/05-shell.txt"'

# ===========================================================================
# 3. THE LEDGER OF LIVE EFFECTS
# ===========================================================================
echo ""
echo "3. the ledger of live effects — xo/live.json, and the report's own section"
check "3a. xo/live.json exists beside the look" '[ -s "$M2/xo/live.json" ]'
check "3b. it records the consent it ran under" \
  '"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));c=d.get(\"consent\") or {};sys.exit(0 if c.get(\"host\")==\"'"$HOST"'\" and \"'"$OWNER"'\" in (c.get(\"owners\") or []) else 1)" "$M2/xo/live.json"'
check "3c. BOTH declared liveEffects of the consented step are on it" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get(\"effects\") or []
names={str(x.get(\"name\") or \"\") for x in e}
kinds={str(x.get(\"kind\") or \"\") for x in e}
sys.exit(0 if {\"publish #1\",\"xo-probe-249\"} <= names and {\"run\",\"branch\"} <= kinds else 1)" "$M2/xo/live.json"'
check "3d. each effect says which host, owner and step made it" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
e=[x for x in (d.get(\"effects\") or []) if x.get(\"name\")==\"publish #1\"][0]
sys.exit(0 if e.get(\"host\")==\"'"$HOST"'\" and e.get(\"owner\")==\"'"$OWNER"'\" and e.get(\"step\")==\"L1\" else 1)" "$M2/xo/live.json"'
check "3e. a REFUSED step's effects are NOT ledgered — nothing was created" \
  '"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));sys.exit(0 if not (d.get(\"effects\") or []) else 1)" "$M1/xo/live.json"'
check "3f. no effect is ledgered for the refused other-owner step" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if not any(x.get(\"owner\")==\"nemesis\" for x in (d.get(\"effects\") or [])) else 1)" "$M2/xo/live.json"'

S3="$TMPROOT/score-effects"
score "$S3" "$M2/xo/live.json"
check "3g. the report has a What I touched live section" \
  'grep -q "What I touched live" "$S3/report.md"'
check "3h. and it lists both effects by name" \
  'grep -q "publish #1" "$S3/report.md" && grep -q "xo-probe-249" "$S3/report.md"'
check "3i. the section names the host they were made on" \
  '"$PY" -c "
import sys
t=open(sys.argv[1]).read()
s=t.split(\"What I touched live\",1)[1][:1200]
sys.exit(0 if \"'"$HOST"'\" in s else 1)" "$S3/report.md"'
check "3j. the verdict carries the effects as DATA, for a teardown to read" \
  '"$PY" -c "import json,sys;d=json.load(open(sys.argv[1]));e=(d.get(\"live\") or {}).get(\"effects\") or [];sys.exit(0 if len(e)>=2 else 1)" "$S3/verdict.json"'

# ===========================================================================
# 4. THE WORKER CANNOT GRANT ITSELF CONSENT
# ===========================================================================
echo ""
echo "4. the worker cannot grant itself consent — a forged env is stripped"
: >"$FORGE_LOG"; : >"$GH_CALLS"
M4="$(mission m-forged)"
FORGED="WORKER-FORGED-249-TOKEN"
cat >"$TMPROOT/j4.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "F1", "for": "prd-3", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL",
           "GH_HOST": "evil.example", "GH_TOKEN": "$FORGED"},
   "live": {"host": "evil.example", "owner": "$OWNER"},
   "evidence": "01-forged-live.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "F2", "for": "prd-4", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "env-dump"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "GH_HOST": "evil.example",
           "GH_TOKEN": "$FORGED", "GITHUB_TOKEN": "$FORGED"},
   "evidence": "02-forged-plain.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "F3", "for": "prd-5", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL",
           "GH_TOKEN": "$FORGED"},
   "evidence": "03-no-live-block.txt", "expect": {"exit": 0}}
]}
JSON
drive "$M4" "$TMPROOT/j4.json"
check "4a. the run TERMINATES" '! grep -q "TIMED OUT" "$M4/run.out"'
check "4b. a live: host that is not in the record is REFUSED, forged env and all" \
  'readout "$M4" 01-forged-live "d.get(\"refused\") is True and \"needs a live target: evil.example/'"$OWNER"' is not in liveTargets\" in (d.get(\"why\") or \"\")"'
check "4c. the forge was never asked about the host the worker forged" \
  '! grep -q "evil.example" "$FORGE_LOG"'
check "4d. a worker-declared GH_TOKEN is STRIPPED from a plain step" \
  'grep -q "GH_TOKEN=$" "$M4/xo/shots/look-1/02-forged-plain.txt"'
check "4e. a worker-declared GH_HOST is STRIPPED too" \
  'grep -q "GH_HOST=$" "$M4/xo/shots/look-1/02-forged-plain.txt"'
check "4f. a worker-declared GITHUB_TOKEN is STRIPPED as well" \
  'grep -q "GITHUB_TOKEN=$" "$M4/xo/shots/look-1/02-forged-plain.txt"'
check "4g. the readout SAYS which credential keys it stripped" \
  'readout "$M4" 02-forged-plain "\"GH_TOKEN\" in (d.get(\"strippedEnv\") or [])"'
check "4h. a step with NO live: block gets no credential, so its publish is unauthenticated" \
  'readout "$M4" 03-no-live-block "d.get(\"refused\") is not True"'
check "4i. and the forge, if reached at all, saw no Authorization header" \
  '! grep -q "'"$FORGED"'" "$FORGE_LOG" && ! grep -q "'"$TOKEN"'" "$FORGE_LOG"'
check "4j. THE FORGED STRING IS NOWHERE UNDER xo/ — it never even ran" \
  '! grep -rq "'"$FORGED"'" "$M4/xo"'

# --- and the OTHER source of the record, read with the same code ------------
echo ""
echo "4b. the same consent, recorded the repo's way in config.json numberOne"
consent_config "$HOST" "$OWNER"
: >"$FORGE_LOG"; : >"$GH_CALLS"
M4B="$(mission m-config-consent)"
cat >"$TMPROOT/j4b.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "C1", "for": "prd-3", "fromChecklist": "cli#7",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "01-publish.txt", "expect": {"exit": 0, "stdoutIncludes": "credential: present"}}
]}
JSON
drive "$M4B" "$TMPROOT/j4b.json"
check "4k. consent in config.json numberOne.liveTargets is honoured" \
  'readout "$M4B" 01-publish "d.get(\"met\") is True"'
check "4l. the readout says the record it read was config.json" \
  'readout "$M4B" 01-publish "\"config\" in ((d.get(\"live\") or {}).get(\"consentedBy\") or \"\")"'
check "4m. and the forge saw the header on that one too" \
  'grep -q "token '"$TOKEN"'" "$FORGE_LOG"'

# ===========================================================================
# 5. THE GREP CONTROL — the single most important assertion in this file
# ===========================================================================
echo ""
echo "5. THE GREP CONTROL — no token string in any file the look wrote"

# THE DETECTOR, as a function, so the SAME code that clears the artifacts is
# shown to FIRE on a planted token. A grep that cannot fail proves nothing, and
# this suite has watched this one fail on purpose.
token_anywhere_under() { # <dir> → 0 when the token IS found
  grep -rqa "$TOKEN" "$1" 2>/dev/null
}
PLANT="$TMPROOT/plant/xo/shots/look-1"; mkdir -p "$PLANT"
printf 'GH_TOKEN=%s\n' "$TOKEN" >"$PLANT/leaked.txt"
check "5a. THE DETECTOR FIRES on a planted token — it is not blind" \
  'token_anywhere_under "$TMPROOT/plant"'
rm -rf "$TMPROOT/plant"

for m in "$M1" "$M2" "$M4" "$M4B"; do
  check "5b. no token anywhere under $(basename "$m")/xo/" \
    '! token_anywhere_under "$m/xo"'
done
check "5c. no token in the mission journal either" \
  '! grep -rqa "$TOKEN" "$M2/number-one.jsonl"'
check "5d. no token in the whole mission directory of a consented look" \
  '! token_anywhere_under "$M2"'
check "5e. no token in the SCORED verdict or the report the captain reads" \
  '! token_anywhere_under "$TMPROOT/score-effects"'
# AND THE CARELESS PRODUCT IS THE PROOF IT IS A SCRUB, NOT AN ABSENCE: the
# env-dump step PRINTED GH_TOKEN verbatim, and the artifact carries the
# redaction where the value was.
check "5f. the careless env-dump's own output is REDACTED, not silently dropped" \
  'grep -q "GH_TOKEN=<redacted>" "$M2/xo/shots/look-1/03-env-live.txt"'
check "5g. and the readout of that step says it redacted something" \
  'readout "$M2" 03-env-live "int(d.get(\"redactions\") or 0) >= 1"'

# ===========================================================================
# 6. WHAT THE WORKER IS TOLD — the prompt names the consent, not an env switch
# ===========================================================================
echo ""
echo "6. the prompt tells the worker what is consented"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"

# RENDERED, NOT GREPPED. The prompt is assembled by `run.sh spawn-number-one`,
# so the round is spawned for real against a worker adapter that writes the
# prompt to a file instead of spending anything — the same harness
# `lcars-xo-drives` uses. A grep over run.sh would pass on a line that never
# reaches a model.
PR="$TMPROOT/prompt"; mkdir -p "$PR/in" "$PR/out"
printf '%s\n' '{"productTypes": [{"type": "cli", "source": "the plan"}], "criteria": []}' \
  >"$PR/in/criteria.json"
mkdir -p "$LCARS/missions/m-prompt/xo"
printf '{"id":"m-prompt","stage":"verify","branch":"feat/relay"}\n' \
  >"$LCARS/missions/m-prompt/state.json"
printf '# PRD\n' >"$LCARS/missions/m-prompt/prd.md"
cat >"$PR/adapter.sh" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$PR/adapter.sh"
render_prompt() { # <dump-file> [LCARS_XO_LIVE_TARGETS]
  ( cd "$PROD" && XO_PROMPT_DUMP="$1" LCARS_WORKER_ADAPTER="$PR/adapter.sh" \
      LCARS_WORKER_BIN=/usr/bin/true LCARS_WORKER_CLI=copilot \
      LCARS_XO_INPUT_DIR="$PR/in" LCARS_GH_BIN=/usr/bin/true \
      LCARS_XO_LIVE_TARGETS="${2:-}" \
      bash "$RUNSH" spawn-number-one --mission m-prompt --mode evaluate \
        --outdir "$PR/out" ) >/dev/null 2>&1
}
render_prompt "$PR/with.txt" "$HOST (owners: $OWNER)"
render_prompt "$PR/without.txt" ""
check "6a. the prompt was captured at all" '[ -s "$PR/with.txt" ]'
check "6a2. THE BEHAVIOUR — the round TELLS the worker which host is consented" \
  'grep -q "One real host IS consented: '"$HOST"' (owners: '"$OWNER"')" "$PR/with.txt"'
check "6a3. it shows the live: block, naming host and owner" \
  'grep -q "\"live\": {\"host\"" "$PR/with.txt"'
check "6a4. it says a GH_TOKEN the worker declares is STRIPPED" \
  'grep -q "you declare in \`env\` is stripped" "$PR/with.txt"'
check "6b. it tells the worker to declare liveEffects, and why" \
  'grep -q "Declare .liveEffects. on every live step" "$PR/with.txt"'
check "6b2. CONTROL — with no record, the round says NOTHING about a live host" \
  '[ -s "$PR/without.txt" ] && ! grep -q "One real host IS consented" "$PR/without.txt"'
check "6b3. CONTROL — and the rest of the prompt is still there either way" \
  'grep -q "Your output file" "$PR/with.txt" && grep -q "Your output file" "$PR/without.txt"'

# AND THE CONSENT READER THE SHELL USES IS THE FILE THAT WILL REFUSE THE STEP.
consent_says() { ( cd "$PROD" && "$PY" "$XORUN" consent --repo "$PROD" \
                     --lcars-dir "$LCARS" ) 2>&1; }
consent_autopilot "$HOST" "$OWNER"
check "6b4. xo-run.py consent reports the record the harness will judge by" \
  '[ "$(consent_says | sed -n "s/^HOST: //p")" = "'"$HOST"'" ] && \
   [ "$(consent_says | sed -n "s/^OWNERS: //p")" = "'"$OWNER"'" ] && \
   consent_says | grep -q "^SOURCE: autopilot.json"'
consent_none
check "6b5. CONTROL — with no record it says NOTHING at all, which is no consent" \
  '[ -z "$(consent_says)" ]'
consent_autopilot "$HOST" "$OWNER"
check "6c. evaluate.md is NOT where it went — still under its 689-line ceiling" \
  '[ "$(grep -c "" "$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md")" -lt 689 ]'
check "6d. xo.sh hands the consent to the spawn (read from the record, by xo-run.py)" \
  'grep -q "LCARS_XO_LIVE_TARGETS" "$REPO_ROOT/skills/lcars-xo/xo.sh"'
check "6e. there is NO env switch that turns live on" \
  '! grep -qE "LCARS_XO_LIVE_(ON|ENABLE|ALLOW)" "$REPO_ROOT/skills/lcars-xo/xo-run.py"'
check "6f. consent is read from the RECORD — autopilot.json then config.json" \
  'grep -q "autopilot.json" "$XORUN" && grep -q "liveTargets" "$XORUN"'
check "6g. and never from the environment" \
  '! grep -qE "environ.*liveTargets|liveTargets.*environ" "$XORUN"'
# THE INVARIANT THE ROUND DECLARED: the worker never gets a shell, and WebFetch
# is not how a credential gets used. Asserted on the adapter's own lines so a
# later session cannot quietly trade this session's fence for a tool.
#
# S261 — THE FIRST HALF OF THAT SENTENCE NOW APPLIES TO THIS ROLE ONLY. The
# captain amended the S168 clause on 2026-10-08 at 19:33 MDT: the VERIFY LOOK
# runs as the separate role `number-one-live`, which does hold a shell, contained
# by a disposable detached worktree (`lcars-xo-eyes`). `number-one` is now the
# PAPER-GATE posture (`answer`, `recheck`) and the three rows below are
# unchanged and still true of it. 6k is the part that matters to THIS file: the
# credential half did not move — neither role may fetch, so a consented
# credential still cannot be spent through the web.
check "6h. the number-one role is still Read,Grep,Glob,Write on claude" \
  'grep -q "number-one)    printf .Read,Grep,Glob,Write." "$REPO_ROOT/skills/lcars-run/worker-adapter.sh"'
check "6i. and Edit,Bash,NotebookEdit,WebSearch,WebFetch are still DENIED to it" \
  'grep -q "number-one)    printf .Edit,Bash,NotebookEdit,WebSearch,WebFetch." "$REPO_ROOT/skills/lcars-run/worker-adapter.sh"'
# S250 — `grep` is spelled `rg` now (both names resolve to the same search tool,
# measured on copilot 1.0.92), and `create` is GONE from THIS role rather than
# renamed: it needs no write tool, because it says its verdict in its reply and the
# harness writes the file. `create` itself still works and the other read roles
# keep it. What this check has always been for is unchanged — NO SHELL.
check "6j. on copilot it is view,rg,glob — no shell, and no write tool either" \
  'grep -q "number-one)    printf .view,rg,glob." "$REPO_ROOT/skills/lcars-run/worker-adapter.sh"'
# S261 — AND THE CREDENTIAL HALF OF THE INVARIANT DID NOT MOVE. The look's role
# gained a shell; it did NOT gain the network, on either engine. A consented
# GH_TOKEN still cannot be spent through a fetch tool, which is what this file
# exists to protect.
N1_ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"
# The argv goes to a FILE first: `adapter_argv`'s last statement is a
# conditional printf, so on claude it returns 1 with a perfect argv on stdout,
# and this file runs under `pipefail`.
bash "$N1_ADAPTER" argv claude number-one-live "$TMPROOT" >"$TMPROOT/n1live-claude.txt" 2>/dev/null
bash "$N1_ADAPTER" argv copilot number-one-live "$TMPROOT" >"$TMPROOT/n1live-copilot.txt" 2>/dev/null
check "6k. the LOOK's role has a shell but still NO fetch tool on either engine" \
  '[ "$(bash "$N1_ADAPTER" deny claude number-one-live)" = "Edit,NotebookEdit,WebSearch,WebFetch" ] &&
   grep -qxF "Read,Grep,Glob,Write,Bash" "$TMPROOT/n1live-claude.txt" &&
   grep -qxF "view,rg,glob,bash" "$TMPROOT/n1live-copilot.txt" &&
   ! grep -qE "web_fetch|web_search" "$TMPROOT/n1live-copilot.txt"'

# ===========================================================================
# 7. THE MUTATION — the consent gate is shown to be the thing that refuses
# ===========================================================================
# A refusal test passes just as happily against a gate that was never reached.
# So the ONE function that says "nobody consented to this" is commented out in a
# COPY, and the same no-consent step is driven again: with the gate gone it must
# RUN and the forge must see it. If it still refuses, every check in section 1 was
# measuring something else.
echo ""
echo "7. the consent gate, disabled in a copy — the refusals above are IT"
MUT="$TMPROOT/xo-run-noconsent.py"
"$PY" - "$XORUN" "$MUT" <<'MUTEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\ndef live_refusal\(([^)]*)\):\n", src)
assert m, "live_refusal not found — this mutation has drifted"
open(sys.argv[2], "w", encoding="utf-8").write(
    src[:m.end()] + '    return ""\n' + src[m.end():])
MUTEOF
check "7a. the mutant parses (so a non-refusal below is the gate, not a crash)" \
  '"$PY" -c "import py_compile,sys;py_compile.compile(sys.argv[1],doraise=True)" "$MUT"'
consent_none
: >"$FORGE_LOG"
MMUT="$(mission m-mutant)"
sed "s|m-noconsent|m-mutant|" "$TMPROOT/j1.json" >"$TMPROOT/j-mut.json"
# The copy sits outside skills/, so it is told where the ONE worktree helper is —
# otherwise it would refuse for want of autopilot.sh and prove nothing.
LCARS_AUTOPILOT_BIN="$REPO_ROOT/skills/lcars-buddy/autopilot.sh" \
  "$PY" "$CAGE" 180 "$PY" "$MUT" run --journey "$TMPROOT/j-mut.json" --repo "$PROD" \
  --branch feat/relay --out "$MMUT/xo/shots/look-1" --mission-dir "$MMUT" \
  >"$MMUT/run.out" 2>&1
check "7b. MUTATION — with the consent gate gone the step is NOT refused" \
  'readout "$MMUT" 01-publish "d.get(\"refused\") is not True"'
check "7c. MUTATION — and it DOES reach the forge, which is what section 1 stops" \
  '[ -s "$FORGE_LOG" ]'
# AND THE SCRUB IS NOT THE GATE. Even with consent disabled — a step running live
# that nobody allowed — the token is still absent from everything written. The two
# controls are independent, which is the point of having both.
check "7d. the scrub holds even on the mutant's artifacts" \
  '! token_anywhere_under "$MMUT"'
check "7e. and across EVERY mission this suite drove, after everything" \
  '! token_anywhere_under "$LCARS/missions"'
consent_autopilot "$HOST" "$OWNER"


# ===========================================================================
# 9. THE WRAP — A CREDENTIAL BROKEN ACROSS LINES IS STILL A CREDENTIAL
# ===========================================================================
# THE DEFECT THIS SECTION EXISTS FOR. `scrub` matched the secret as an exact
# substring, so the one thing its own docstring names as the threat — "a verbose
# client echoes the request" — defeated it: a `curl -v` dump WRAPS, and a token
# folded at 20 columns is no longer a substring of anything. The whole credential
# landed, in order, in the saved transcript under `xo/`.
echo ""
echo "9. a credential WRAPPED across lines is redacted too (and the count survives)"
consent_autopilot "$HOST" "$OWNER"
: >"$FORGE_LOG"; : >"$GH_CALLS"

# A SECOND CARELESS PRODUCT, committed onto the branch the look detaches from, so
# the step runs it from the worktree like any other. It prints the credential it
# was given in the shapes a real client prints it in.
cat >"$PROD/leaky.py" <<'PYEOF'
import os
import sys

tok = os.environ.get("GH_TOKEN", "")
mode = sys.argv[1] if len(sys.argv) > 1 else ""

if mode == "wrap":
    # What a verbose client echoes, folded by the terminal at 20 columns.
    line = "curl -H 'Authorization: token %s' https://forge.local/api" % tok
    for i in range(0, len(line), 20):
        print(line[i:i + 20])
elif mode == "halves":
    half = len(tok) // 2
    print(tok[:half])
    print(tok[half:])
elif mode == "plain":
    print("GH_TOKEN=%s" % tok)
elif mode == "decoy":
    # NOT A SECRET ANYWHERE IN IT — the control that tells a scrub from a bonfire.
    sys.stdout.write(open(os.environ["DECOY_FILE"], encoding="utf-8").read())
else:
    sys.stderr.write("leaky: no such mode %s\n" % mode)
    sys.exit(2)
PYEOF
git -C "$PROD" add -A >/dev/null 2>&1
git -C "$PROD" -c user.email=t@t -c user.name=t commit -qm leaky >/dev/null 2>&1
git -C "$PROD" branch -f feat/relay main >/dev/null 2>&1

# THE DECOY, byte for byte. Near-misses on purpose: the credential's own prefix,
# the env key, a wrapped line — everything but the secret itself.
DECOY="$TMPROOT/decoy.txt"
cat >"$DECOY" <<'DEOF'
GH_TOKEN=
GITHUB_TOKEN=
relay: publishing to forge.local
a wrapped line of ordinary output that the terminal folded
at twenty columns like any other, carrying no credential
DEOF

# THE DETECTOR FOR THIS SECTION: the token with every whitespace character
# ignored, which is the only way to see a folded one.
token_wrapped_in() { # <file> → 0 when the token IS there, even broken by a break
  "$PY" - "$1" "$TOKEN" <<'P'
import sys
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# A BREAK IS A BREAK IN EITHER ARTIFACT. In the transcript the fold is a real
# newline; in the JSON readout beside it the SAME fold is the two characters
# backslash-n, so a detector that only knew whitespace would call the readout
# clean while the credential sat in it, in order, for anyone to join up.
flat = raw.replace("\\n", "").replace("\\r", "").replace("\\t", "")
sys.exit(0 if sys.argv[2] in "".join(flat.split()) else 1)
P
}
token_wrapped_under() { # <dir> → 0 when SOME file under it carries the token
  found=1
  while IFS= read -r f; do
    if token_wrapped_in "$f"; then found=0; break; fi
  done < <(find "$1" -type f 2>/dev/null)
  return $found
}

# THE DETECTOR IS SHOWN TO FIRE FIRST — on exactly the artifact the tester found.
PLANTW="$TMPROOT/plantw"; mkdir -p "$PLANTW"
"$PY" - "$PLANTW/wrapped.txt" "$TOKEN" <<'P'
import sys
line = "curl -H 'Authorization: token %s' https://forge.local/api" % sys.argv[2]
open(sys.argv[1], "w").write(
    "\n".join(line[i:i + 20] for i in range(0, len(line), 20)) + "\n")
P
check "9a. the wrap detector FIRES on a planted folded token — it is not blind" \
  'token_wrapped_in "$PLANTW/wrapped.txt"'
check "9b. and the OLD exact-substring grep misses that same file — which is the bug" \
  '! grep -qa "$TOKEN" "$PLANTW/wrapped.txt"'
rm -rf "$PLANTW"

M9="$(mission m-wrapped)"
cat >"$TMPROOT/j9.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "W1", "for": "prd-3", "fromChecklist": "cli#9",
   "argv": ["python3", "leaky.py", "wrap"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "01-wrap.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "W2", "for": "prd-4", "fromChecklist": "cli#9",
   "argv": ["python3", "leaky.py", "halves"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "02-halves.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "W3", "for": "prd-5", "fromChecklist": "cli#9",
   "argv": ["python3", "leaky.py", "plain"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "03-plain.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "W4", "for": "prd-6", "fromChecklist": "cli#9",
   "argv": ["python3", "leaky.py", "decoy"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "DECOY_FILE": "$DECOY"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "04-decoy.txt", "expect": {"exit": 0}}
]}
JSON
drive "$M9" "$TMPROOT/j9.json"
check "9c. the run TERMINATES" '! grep -q "TIMED OUT" "$M9/run.out"'
check "9d. the wrapping step RAN (so there was a credential to leak)" \
  'readout "$M9" 01-wrap "d.get(\"met\") is True and not d.get(\"refused\")"'
check "9e. THE WRAPPED CREDENTIAL IS NOT IN THE TRANSCRIPT ON DISK" \
  '! token_wrapped_in "$M9/xo/shots/look-1/01-wrap.txt"'
check "9f. nor in the readout beside it" \
  '! token_wrapped_in "$M9/xo/shots/look-1/01-wrap.json"'
check "9g. nor anywhere under xo/ — the artifact class that promised never to hold one" \
  '! token_wrapped_under "$M9/xo"'
check "9h. nor in the mission journal" \
  '! token_wrapped_in "$M9/number-one.jsonl"'
check "9i. and the redaction is a RECORD, not a silence — the count is still there" \
  'readout "$M9" 01-wrap "int(d.get(\"redactions\") or 0) >= 1"'
# IN THE PRODUCT'S OWN OUTPUT, not in the harness's header line — the header
# already said `GH_TOKEN=<redacted>` before this fix and would make a vacuous
# check pass, so this one reads the stdout block alone.
check "9j. the redaction stands where the folded value was, in the step's own output" \
  '"$PY" - "$M9/xo/shots/look-1/01-wrap.txt" <<'"'"'P'"'"'
import sys
raw = open(sys.argv[1], encoding="utf-8").read()
head, tail = "--- stdout ---\n", "\n--- stderr ---"
i = raw.find(head)
j = raw.find(tail, i)
out = raw[i + len(head):j] if i >= 0 and j > i else ""
sys.exit(0 if "<redacted>" in out else 1)
P'
check "9k. a credential printed in HALVES on two lines is gone too" \
  '! token_wrapped_in "$M9/xo/shots/look-1/02-halves.txt"'
check "9l. CONTROL — a PLAIN unwrapped token is still redacted" \
  'grep -q "GH_TOKEN=<redacted>" "$M9/xo/shots/look-1/03-plain.txt"'
check "9m. CONTROL — and still COUNTED" \
  'readout "$M9" 03-plain "int(d.get(\"redactions\") or 0) >= 1"'
# THE CONTROL THAT TELLS A FIX FROM A BONFIRE. A step whose output holds no
# secret comes back BYTE FOR BYTE, compared against the file it printed.
check "9n. CONTROL — output with no secret in it is BYTE-UNCHANGED by the scrub" \
  '"$PY" - "$M9/xo/shots/look-1/04-decoy.txt" "$DECOY" <<'"'"'P'"'"'
import sys
raw = open(sys.argv[1], encoding="utf-8").read()
want = open(sys.argv[2], encoding="utf-8").read()
head = "--- stdout ---\n"
tail = "\n--- stderr ---"
i = raw.find(head)
j = raw.find(tail, i)
got = raw[i + len(head):j] if i >= 0 and j > i else ""
sys.exit(0 if got == want else 1)
P'
# AND THE PAIR THAT MAKES 9n MEAN SOMETHING: that step DID hold the credential —
# its own header says so — and its output came back untouched anyway.
check "9o. CONTROL — that step was holding the credential all the same" \
  'grep -q "GH_TOKEN=<redacted>" "$M9/xo/shots/look-1/04-decoy.txt"'
check "9p. CONTROL — so its readout counts ZERO redactions" \
  'readout "$M9" 04-decoy "int(d.get(\"redactions\") or 0) == 0"'
check "9q. and the plain exact-substring grep is clear across the whole mission" \
  '! token_anywhere_under "$M9"'

# ===========================================================================
# 10. THE ALLOW-LIST FAILS CLOSED — A STEP THAT NAMES NO REPO IS REFUSED
# ===========================================================================
# THE DEFECT: with `repos[]` recorded, a step declaring {host, owner} and NO repo
# ran and was handed the credential — so the allow-list constrained an honest
# declaration and not a careless one, and the step list is written by the model.
echo ""
echo "10. repos[] is recorded — a step that names NO repo is refused, not allowed"
printf '{"liveTargets": {"host": "%s", "owners": ["%s"], "repos": ["ok-*", "widgets"]}}\n' \
  "$HOST" "$OWNER" >"$LCARS/autopilot.json"
: >"$FORGE_LOG"; : >"$GH_CALLS"
M10="$(mission m-repos)"
cat >"$TMPROOT/j10.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "R1", "for": "prd-3", "fromChecklist": "cli#10",
   "argv": ["python3", "relay.py", "publish"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "RELAY_FORGE": "$FORGE_URL"},
   "live": {"host": "$HOST", "owner": "$OWNER"},
   "evidence": "01-norepo.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "R2", "for": "prd-4", "fromChecklist": "cli#10",
   "argv": ["python3", "relay.py", "env-dump"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER", "repo": "ok-widget"},
   "evidence": "02-allowed.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "R3", "for": "prd-5", "fromChecklist": "cli#10",
   "argv": ["python3", "relay.py", "env-dump"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "live": {"host": "$HOST", "owner": "$OWNER", "repo": "nope"},
   "evidence": "03-other-repo.txt", "expect": {"exit": 0}}
]}
JSON
drive "$M10" "$TMPROOT/j10.json"
check "10a. the run TERMINATES" '! grep -q "TIMED OUT" "$M10/run.out"'
check "10b. A STEP THAT NAMES NO REPO IS REFUSED" \
  'readout "$M10" 01-norepo "d.get(\"refused\") is True"'
check "10c. and the refusal names the situation the way the others do" \
  'readout "$M10" 01-norepo "\"needs a live target: '"$HOST"'/'"$OWNER"' names no repo, and liveTargets allows only the repos ok-*, widgets\" in (d.get(\"why\") or \"\")"'
check "10d. it is ONE plain sentence, like every other refusal" \
  'readout "$M10" 01-norepo "0 < len(d.get(\"why\") or \"\") < 300 and chr(10) not in (d.get(\"why\") or \"x\")"'
check "10e. the careless step NEVER RAN — the forge saw nothing" \
  '[ ! -s "$FORGE_LOG" ]'
check "10f. and it is journaled like any other refusal" \
  'grep -q "step-refused" "$M10/number-one.jsonl"'
check "10g. xo/live.json records it against its criterion" \
  '"$PY" - "$M10/xo/live.json" <<'"'"'P'"'"'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if any(x.get("criterion") == "prd-3" and "names no repo" in (x.get("why") or "")
                  for x in (d.get("refused") or [])) else 1)
P'
check "10h. CONTROL — a step that DOES name a matching repo still RUNS" \
  'readout "$M10" 02-allowed "d.get(\"met\") is True and not d.get(\"refused\")"'
check "10i. CONTROL — and is still handed the credential" \
  'grep -q "LCARS_XO_LIVE=1" "$M10/xo/shots/look-1/02-allowed.txt"'
check "10j. REGRESSION — a repo outside the allow-list is refused as it always was" \
  'readout "$M10" 03-other-repo "d.get(\"refused\") is True and \"whose repos are\" in (d.get(\"why\") or \"\")"'
check "10k. no token under this mission either" \
  '! token_wrapped_under "$M10"'
consent_autopilot "$HOST" "$OWNER"
# ===========================================================================
# 11. THE WORKER IS TOLD ABOUT repos[] — CARRIED THROUGH, AND IN THE EXAMPLE
# ===========================================================================
# THE DEFECT SECTION 10'S CURE CAUSED. Making the allow-list fail closed refuses a
# step that names no repo — but nothing ever told the worker the field exists.
# `xo_live_targets` DROPPED the `REPOS:` line `xo-run.py consent` already prints,
# and the prompt's worked example showed only {host, owner}. So in a repo whose
# record lists repos, a prompt-following worker was refused on EVERY live step:
# "a careless step is allowed" had become "no live step is possible", which is
# worse than the defect it cured.
#
# DRIVEN THROUGH THE PRODUCT'S OWN TWO HALVES, not a grep over either. The reader
# `xo_live_targets` is LIFTED out of xo.sh — the idiom lcars-xo-effect uses for
# `cfg_files_bugs` — so the REAL shell reader runs against the REAL `xo-run.py
# consent`; whatever it prints is then handed to the REAL `run.sh
# spawn-number-one`, which renders the REAL prompt a worker would read.
echo ""
echo "11. the worker is told which repos it may name, and is shown the field"

LIFT="$TMPROOT/live-targets.sh"
awk '/^xo_live_targets\(\) \{/,/^\}$/' "$REPO_ROOT/skills/lcars-xo/xo.sh" >"$LIFT"
check "11a. xo_live_targets was lifted out of xo.sh, and reads through consent" \
  '[ -s "$LIFT" ] && grep -q "consent" "$LIFT"'

# The lifted reader, run with the four things xo.sh hands it and nothing else.
live_targets_says() {
  XO_PY="$PY" XO_RUN_PY="$XORUN" LCARS_DIR="$LCARS" XO_REACH_REPO="$PROD" \
    bash -c 'source "$0"; xo_live_targets' "$LIFT"
}

printf '{"liveTargets": {"host": "%s", "owners": ["%s"], "repos": ["ok-*", "widgets"]}}\n' \
  "$HOST" "$OWNER" >"$LCARS/autopilot.json"
WITH_REPOS="$(live_targets_says)"
consent_autopilot "$HOST" "$OWNER"
NO_REPOS="$(live_targets_says)"

check "11b. THE CARRY — with repos recorded, the reader hands the repo list on" \
  'printf "%s" "$WITH_REPOS" | grep -qF "ok-*" && \
   printf "%s" "$WITH_REPOS" | grep -qF "widgets"'
check "11c. and it still names the host and the owner, as it always did" \
  'printf "%s" "$WITH_REPOS" | grep -qF "$HOST" && \
   printf "%s" "$WITH_REPOS" | grep -qF "owners: $OWNER"'
check "11d. CONTROL — the DEFAULT record (no repos) reads exactly as before" \
  '[ "$NO_REPOS" = "$HOST (owners: $OWNER)" ]'

render_prompt "$PR/repos.txt"   "$WITH_REPOS"
render_prompt "$PR/norepos.txt" "$NO_REPOS"
check "11e. both prompts were captured at all" \
  '[ -s "$PR/repos.txt" ] && [ -s "$PR/norepos.txt" ]'
check "11f. THE BEHAVIOUR — the round TELLS the worker the repo list" \
  'grep -qF "ok-*, widgets" "$PR/repos.txt"'
check "11g. THE BEHAVIOUR — and SHOWS the repo field in the worked example" \
  'grep -qF "\"repo\": \"<one of the repos above>\"" "$PR/repos.txt"'
check "11h. and says in one plain sentence that a repo must be named" \
  'grep -qF "must name a \`repo\` from that list" "$PR/repos.txt"'
check "11i. the live: block is still there, host and owner first" \
  'grep -qF "\"live\": {\"host\"" "$PR/repos.txt"'
check "11j. CONTROL — with no repos recorded the round shows NO repo field" \
  '! grep -qF "\"repo\":" "$PR/norepos.txt"'
check "11k. CONTROL — and does not mention repos at all" \
  '! grep -qF "repos" "$PR/norepos.txt"'
check "11l. CONTROL — the rest of the prompt is there either way" \
  'grep -q "Your output file" "$PR/repos.txt" && \
   grep -q "Your output file" "$PR/norepos.txt" && \
   grep -q "Declare .liveEffects. on every live step" "$PR/repos.txt" && \
   grep -q "Declare .liveEffects. on every live step" "$PR/norepos.txt"'
consent_autopilot "$HOST" "$OWNER"

# ===========================================================================
# 12. S250 FIX ROUND 1 — A LOCAL STAND-IN CANNOT SETTLE THE STEP IT SKIPPED,
#     AND AN EMPTY LIVE LEDGER SAYS SO
# ===========================================================================
#
# THE MEASURED FALSE GREEN (D1). On the first consented drive, one report settled
# two criteria about the SAME push off the SAME local transcript:
#
#   prd-1      "…produces a successful publish run, AND THE PAGE IT PUBLISHES CAN
#              BE DOWNLOADED AND READ BACK"                              → MET
#   t-001-ac1  "…a successful publish run that uploads the site artifact" → UNTESTED
#
# Nothing was pushed and nothing was downloaded: `workflow-run` had executed the
# job's steps ON THE REVIEWER'S LAPTOP and printed, in its own words, that it
# skipped 2 of the 3 — including the upload — and that they were "UNPROVEN, not
# passed". One row read that notice; the other banked a pass off it, and the pass
# fed the headline grade.
#
# The record keyed on is the RUNNER'S OWN, not the criterion's English: `unproven`
# on the step readout, written as the runner declined each step. The control is
# the same shape with nothing skipped — it still reads MET.
#
# AND D4: consent on the record with ZERO live hops used to write no `xo/live.json`
# at all, so the report's "What I touched live" section VANISHED rather than
# saying "nothing" — the one place a teardown reads to know what to archive.
echo ""
echo "12. a local stand-in cannot settle the step it skipped; an empty live ledger says so"

mkdir -p "$PROD/.github/workflows"
cat >"$PROD/.github/workflows/publish.yml" <<'YML'
name: publish
on: push
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: render the page
        run: python3 -c "print('rendered')"
      - uses: actions/upload-artifact@v7
        with:
          path: site
YML
cat >"$PROD/.github/workflows/fails.yml" <<'YML'
name: fails
on: push
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: render the page
        run: python3 -c "import sys; sys.exit(3)"
YML
cat >"$PROD/.github/workflows/all-run.yml" <<'YML'
name: all-run
on: push
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - name: render the page
        run: python3 -c "print('rendered')"
      - name: say it is done
        run: echo done
YML
git -C "$PROD" add -A >/dev/null 2>&1
git -C "$PROD" -c user.email=t@t -c user.name=t commit -qm workflows >/dev/null 2>&1
git -C "$PROD" branch -q -f feat/wf main 2>/dev/null

MWF="$(mission m-standin)"
cat >"$TMPROOT/j-wf.json" <<'JSON'
{"steps": [], "reachSteps": [
  {"do": "workflow", "key": "W1", "for": "prd-1", "fromChecklist": "workflow#1",
   "file": ".github/workflows/publish.yml", "job": "publish",
   "evidence": "07-workflow-run.txt",
   "expect": {"everyRunStepExits": 0}},
  {"do": "workflow", "key": "W2", "for": "prd-2", "fromChecklist": "workflow#2",
   "file": ".github/workflows/all-run.yml", "job": "publish",
   "evidence": "09-all-run.txt",
   "expect": {"everyRunStepExits": 0}},
  {"do": "workflow", "key": "W3", "for": "prd-4", "fromChecklist": "workflow#3",
   "file": ".github/workflows/fails.yml", "job": "publish",
   "evidence": "08-fails.txt",
   "expect": {"everyRunStepExits": 0}},
  {"do": "run", "key": "R1", "for": "prd-3", "fromChecklist": "cli#1",
   "argv": ["python3", "relay.py", "--help"], "cwd": "<worktree>",
   "evidence": "10-help.txt", "expect": {"exit": 0}}
]}
JSON
"$PY" "$CAGE" 240 "$PY" "$XORUN" run --journey "$TMPROOT/j-wf.json" --repo "$PROD" \
  --branch feat/wf --out "$MWF/xo/shots/look-1" --mission-dir "$MWF" \
  >"$MWF/run.out" 2>&1

WSH="$MWF/xo/shots/look-1"
check "12a. (rig) the local workflow run really did skip the packaged actions" \
  'grep -q "UNPROVEN, not passed" "$WSH/07-workflow-run.txt"'
check "12b. the readout RECORDS which steps it did not run, by name" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
u=d.get(\"unproven\") or []
sys.exit(0 if sorted(u)==[\"actions/checkout@v5\",\"actions/upload-artifact@v7\"] and d.get(\"skippedSteps\")==2 else 1)" "$WSH/07-workflow-run.json"'
check "12c. CONTROL — a workflow whose every step is a run: step records NONE" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if (d.get(\"unproven\") or [])==[] and d.get(\"skippedSteps\")==0 else 1)" "$WSH/09-all-run.json"'
check "12d. CONTROL — and that control workflow genuinely ran both its steps" \
  'grep -q "ALL STEPS PASSED (2 run, 0 skipped)" "$WSH/09-all-run.txt"'

# THE LEDGER THAT CLAIMS ALL THREE: prd-1 off the skipping run, prd-2 off the
# complete run, prd-3 off an ordinary CLI transcript. Only prd-1 may move.
cat >"$TMPROOT/criteria-standin.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "pushing the branch publishes a page that can be downloaded and read back", "source": "prd", "primary": true, "kind": "works"},
  {"id": "prd-2", "text": "the workflow runs every step it declares", "source": "prd", "primary": true, "kind": "works"},
  {"id": "prd-3", "text": "relay --help lists its subcommands", "source": "prd", "primary": true, "kind": "works"}
 ]}
C
cat >"$TMPROOT/worker-standin.json" <<'W'
{"score": "high", "summary": "The publish run worked and I read the page back.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "publishing is the point", "status": "met",
  "shot": "07-workflow-run.txt", "evidence": "transcript", "checkedBy": "workflow", "kind": "works",
  "note": "the run exited 0 and the page was there", "action": "ran the publish workflow and read the page back",
  "reason": "I tried running the workflow; I saw it exit 0. Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "every step must run", "status": "met",
  "shot": "09-all-run.txt", "evidence": "transcript", "checkedBy": "workflow", "kind": "works",
  "note": "both steps ran", "action": "ran the all-run workflow",
  "reason": "I tried running the workflow; I saw both steps run. Outcome: met."},
 {"id": "prd-3", "impact": "high", "impactWhy": "the CLI must list its verbs", "status": "met",
  "shot": "10-help.txt", "evidence": "transcript", "checkedBy": "cli", "kind": "works",
  "note": "it listed them", "action": "ran relay.py --help",
  "reason": "I tried running --help; I saw the list. Outcome: met."}
], "gaps": []}
W

score_shots() { # <out-dir> <shots-root> <live.json or ""> <worker> <criteria>
  mkdir -p "$1"
  "$PY" "$CAGE" 240 "$PY" "$SCOREPY" "$4" "$5" \
    "$1/verdict.json" "" "" "" "" "" "" "" "" "" "" "$2" "" "$3" \
    >"$1/out.txt" 2>"$1/err.txt"
}

S12="$TMPROOT/score-standin"
score_shots "$S12" "$MWF/xo/shots" "" \
  "$TMPROOT/worker-standin.json" "$TMPROOT/criteria-standin.json"
check "12e. the scored verdict exists" '[ -s "$S12/verdict.json" ]'
check "12f. prd-1 is UNTESTED — a stand-in that skipped the step cannot settle it" \
  'row "$S12" prd-1 "r.get(\"status\") == \"untested\""'
check "12g. its recorded reason is needs-the-real-run" \
  'row "$S12" prd-1 "r.get(\"couldNotCheck\") == \"needs-the-real-run\""'
check "12h. the cause is OURS — a step we did not run is never his fault" \
  'row "$S12" prd-1 "r.get(\"cause\") == \"infrastructure\" and r.get(\"causeRecorded\") is True"'
check "12i. the row NAMES the steps the run did not carry out" \
  'row "$S12" prd-1 "\"actions/upload-artifact@v7\" in (r.get(\"note\") or \"\") and \"UNPROVEN\" in (r.get(\"note\") or \"\")"'
check "12j. CONTROL — prd-2, off a workflow run that skipped NOTHING, is still MET" \
  'row "$S12" prd-2 "r.get(\"status\") == \"met\""'
check "12k. CONTROL — prd-3, off an ordinary CLI transcript, is still MET" \
  'row "$S12" prd-3 "r.get(\"status\") == \"met\""'
check "12k2. (rig) the failing workflow run skipped a step AND came back red" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if d.get(\"met\") is False and (d.get(\"unproven\") or [])==[\"actions/checkout@v5\"] else 1)" "$WSH/08-fails.json"'
"$PY" - "$TMPROOT/worker-standin.json" "$TMPROOT/worker-standin-red.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
d["criteria"].append({"id": "prd-4", "impact": "high", "impactWhy": "it must fail loudly",
  "status": "met", "shot": "08-fails.txt", "evidence": "transcript",
  "checkedBy": "workflow", "kind": "works", "note": "it stopped",
  "action": "ran the failing workflow", "reason": "I tried it; I saw it stop. Outcome: met."})
json.dump(d, open(sys.argv[2], "w"))
P
"$PY" - "$TMPROOT/criteria-standin.json" "$TMPROOT/criteria-standin-red.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
d["criteria"].append({"id": "prd-4", "text": "the workflow fails loudly when the render fails",
                      "source": "prd", "primary": True, "kind": "works"})
json.dump(d, open(sys.argv[2], "w"))
P
score_shots "$TMPROOT/score-standin-red" "$MWF/xo/shots" "" \
  "$TMPROOT/worker-standin-red.json" "$TMPROOT/criteria-standin-red.json"
check "12k3. CONTROL — a run that reported NO success is left to the other rails" \
  'row "$TMPROOT/score-standin-red" prd-4 "r.get(\"status\") == \"met\""'
check "12k4. CONTROL — …while the GREEN run that skipped a step still moves prd-1" \
  'row "$TMPROOT/score-standin-red" prd-1 "r.get(\"status\") == \"untested\""'
check "12l. the report says so where the captain reads, naming the skipped step" \
  '"$PY" -c "
import sys
t=open(sys.argv[1]).read()
s=t.split(\"What I could not check\",1)
sys.exit(0 if len(s)>1 and \"actions/upload-artifact@v7\" in s[1] and \"UNPROVEN, not passed\" in s[1] else 1)" "$S12/report.md"'
check "12m. and the headline no longer counts it as checked" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=[x for x in d.get(\"criteria\") or []]
met=[x[\"id\"] for x in c if x.get(\"status\")==\"met\"]
sys.exit(0 if sorted(met)==[\"prd-2\",\"prd-3\"] else 1)" "$S12/verdict.json"'
check "12n. CONTROL — with NO shots directory the rail is off and prd-1 stands" \
  'score_shots "$TMPROOT/score-standin-noshots" "" "" \
     "$TMPROOT/worker-standin.json" "$TMPROOT/criteria-standin.json" ; \
   row "$TMPROOT/score-standin-noshots" prd-1 "r.get(\"status\") == \"met\""'

# CONTROL — A ROW THE PROJECT'S OWN TESTS SETTLED IS NOT TOUCHED. Its proof is a
# named line found in the recorded suite output (the S211 over-claiming guard ran
# long before this rail), so a workflow step nobody ran says nothing about it.
cat >"$TMPROOT/tests-ran.json" <<'J'
{"ran": true, "command": "python3 -m unittest", "cwd": "/p", "exitCode": 0,
 "timedOut": false, "timeoutSeconds": 600, "durationSeconds": 3, "outputBytes": 90,
 "truncated": false, "tailCapBytes": 4096, "outcome": "passed",
 "outputTail": "test_publish_uploads_the_artifact (tests.test_publish) ... ok\nOK\n"}
J
"$PY" - "$TMPROOT/worker-standin.json" "$TMPROOT/worker-standin-tests.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for c in d["criteria"]:
    if c["id"] == "prd-1":
        c["evidence"] = "tests"
        c["testQuote"] = "test_publish_uploads_the_artifact (tests.test_publish) ... ok"
json.dump(d, open(sys.argv[2], "w"))
P
mkdir -p "$TMPROOT/score-standin-tests"
"$PY" "$CAGE" 240 "$PY" "$SCOREPY" "$TMPROOT/worker-standin-tests.json" \
  "$TMPROOT/criteria-standin.json" "$TMPROOT/score-standin-tests/verdict.json" \
  "" "$TMPROOT/tests-ran.json" "" "" "" "" "" "" "" "" "$MWF/xo/shots" "" "" \
  >"$TMPROOT/score-standin-tests/out.txt" 2>"$TMPROOT/score-standin-tests/err.txt"
check "12u. CONTROL — a row the project's own tests settled stays MET" \
  'row "$TMPROOT/score-standin-tests" prd-1 "r.get(\"status\") == \"met\" and r.get(\"evidence\") == \"tests\""'
check "12v. CONTROL — …and that fixture's suite citation really was accepted" \
  'row "$TMPROOT/score-standin-tests" prd-1 "\"test_publish_uploads_the_artifact\" in (r.get(\"testQuote\") or \"\")"'

# ── D4: THE EMPTY LIVE LEDGER ────────────────────────────────────────────────
check "12o. consent on the record and no live step still writes xo/live.json" \
  '[ -s "$MWF/xo/live.json" ]'
check "12p. the ledger records the consent it had, and no effects" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
c=d.get(\"consent\") or {}
sys.exit(0 if c.get(\"host\")==\"'"$HOST"'\" and (d.get(\"effects\") or [])==[] and d.get(\"liveSteps\")==0 else 1)" "$MWF/xo/live.json"'
check "12q. the console SAYS nothing was touched live, instead of going quiet" \
  'grep -q "nothing was touched live" "$MWF/run.out"'
S12L="$TMPROOT/score-emptyledger"
score_shots "$S12L" "$MWF/xo/shots" "$MWF/xo/live.json" \
  "$TMPROOT/worker-standin.json" "$TMPROOT/criteria-standin.json"
check "12r. the report STILL has a What I touched live section" \
  'grep -q "What I touched live" "$S12L/report.md"'
check "12s. and it says Nothing, explicitly, with the host that was consented" \
  '"$PY" -c "
import sys
t=open(sys.argv[1]).read()
s=t.split(\"What I touched live\",1)[1][:700]
sys.exit(0 if \"**Nothing.**\" in s and \"'"$HOST"'\" in s and \"not one step asked to\" in s else 1)" "$S12L/report.md"'
check "12t. CONTROL — with no live ledger at all the section stays absent" \
  '! grep -q "What I touched live" "$S12/report.md"'

# ===========================================================================
# ZERO SPEND
# ===========================================================================
echo ""
echo "8. zero spend"
check "8a. no engine was invoked — not claude, not copilot" \
  '[ ! -s "$SPEND_LOG" ]'
check "8b. and nothing asked for a model" \
  '! grep -q -- "--model" "$SPEND_LOG"'

echo ""
printf 'lcars-xo-live-consent: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
