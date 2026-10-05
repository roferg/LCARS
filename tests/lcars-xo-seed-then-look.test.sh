#!/usr/bin/env bash
#
# S248 — SEED, THEN LOOK, IN THE TREE THE LAUNCH SERVES; THE RIGHT PAGE, NOT THE
#        FIRST ONE.
#
# THE SPIKE THIS SUITE RECORDS. `launch.sh` cannot be handed an existing detached
# worktree + HOME: it has no `--worktree` and no `--home`, and its parser dies on
# any unknown flag ("unknown option … usage: lcars launch <mission> [hint]
# [--stop]"). The launch contract is a declared invariant of this round, so the
# direction is forced the OTHER way round: THE LOOK ADOPTS `launch.json.worktree`.
# Everything below is written against that shape.
#
# THE DEFECTS THESE FOUR BEHAVIOURS EXIST FOR (measured, weekend of 2026-10-03):
#   • `xo_seed` ran in `launch.json.worktree` AFTER the reach, which ran in
#     `xo-run.py`'s OWN tree. So nothing seeded the tree the worker's steps ran
#     in, and nothing the worker seeded ever reached the page. 7 of 29 missed
#     bugs sat behind "nothing seeded" or "the wrong thing launched".
#   • `launch.sh` was called unconditionally and discovers ONE command: one
#     `make serve` served the FOUNDATION fixture for every later milestone — the
#     single root cause across the whole run — and nothing ever said the page
#     matched no mockup.
#   • `xo-drive.js` already records per-shot `places[sel].present`/`laidOut`. The
#     "wrong screen" signal already existed; nothing escalated on it. This suite
#     reads THAT record. No image is compared anywhere in it.
#
# THE FOUR BEHAVIOURS:
#   1  the worker seeds `file "nonce-9"` in the pre-launch round → the LAUNCHED
#      page (a real server, in the SAME tree) shows `nonce-9` in the walk's first
#      readout. Real Chrome, real `xo-drive.js`, a real git worktree.
#   2  two serve targets declared → the worker's `serve` choice becomes the launch
#      HINT and `launch.json.command` matches it. CONTROL: one target, no ask.
#   3  a page with NONE of the drawing's parts → `wrong-screen` journaled with the
#      url and the parts it looked for, a second target tried ONCE, and the
#      browser rows scored `untested` with that reason. CONTROL: a page WITH the
#      parts is walked and scored normally — without that control this cannot
#      detect over-firing.
#   4  `verifySeed` declared AND a worker seed → both ran, both in `seed.json`,
#      both in the SAME tree.
#
# ZERO SPEND: a PATH shim fakes BOTH `claude` and `copilot` (an env var alone has
# been measured LOSING to a persisted `state.json workerBin`), and the same shim
# is also the pinned `$LCARS_WORKER_BIN`. The counts are printed at the end.
#
# Usage: bash tests/lcars-xo-seed-then-look.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-xo/xo.sh"
XO="$SCRIPT"
PY="${LCARS_PYTHON_BIN:-python3}"
NODE="${LCARS_NODE_BIN:-node}"
CAGE="$REPO_ROOT/tests/lib/cage.py"

pass=0; fail=0
TMPROOT="$(mktemp -d)"

cleanup() {
  # Every server this suite started, and every worktree it registered, goes.
  local p
  for p in "$TMPROOT"/*/serve.pid "$TMPROOT"/*/*/serve.pid; do
    [ -f "$p" ] || continue
    kill "$(cat "$p" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check() { # <name> <shell expression>
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi
}

echo "=== S248 — seed, then look, in the tree the launch serves ==="
echo ""

# ===========================================================================
# ZERO SPEND — the PATH shim, which is ALSO the worker
# ===========================================================================
# It fakes BOTH engines, because the engine resolves from the request body,
# $LCARS_WORKER_BIN *and* a persisted `state.json workerBin`, and an env var has
# been measured losing to the last of those.
#
# What it writes is driven by $XO_PLAN_DIR: call N writes $XO_PLAN_DIR/N.actions
# to `xo-actions.json`, or $XO_PLAN_DIR/N.verdict to `xo-verdict.json`; with
# neither it falls back to $XO_PLAN_DIR/default.verdict. Its own argv is logged
# so the suite can report the invocation count and how many carried `--model`.
SHIMDIR="$TMPROOT/bin"; mkdir -p "$SHIMDIR"
export XO_SHIM_LOG="$TMPROOT/shim.log"; : >"$XO_SHIM_LOG"
cat >"$SHIMDIR/copilot" <<'SHIM'
#!/usr/bin/env bash
printf 'engine=%s %s\n' "$(basename "$0")" "$*" >>"$XO_SHIM_LOG"
out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || exit 0
[ -n "${XO_PLAN_DIR:-}" ] || exit 0
n="$(grep -c '^engine=' "${XO_PLAN_COUNT:-$XO_SHIM_LOG}" 2>/dev/null)"; n="${n:-1}"
if [ -f "$XO_PLAN_DIR/$n.actions" ]; then
  cp "$XO_PLAN_DIR/$n.actions" "$out/xo-actions.json"; exit 0
fi
if [ -f "$XO_PLAN_DIR/$n.verdict" ]; then
  cp "$XO_PLAN_DIR/$n.verdict" "$out/xo-verdict.json"; exit 0
fi
[ -f "$XO_PLAN_DIR/default.verdict" ] && cp "$XO_PLAN_DIR/default.verdict" "$out/xo-verdict.json"
exit 0
SHIM
chmod +x "$SHIMDIR/copilot"
cp "$SHIMDIR/copilot" "$SHIMDIR/claude"; chmod +x "$SHIMDIR/claude"
export PATH="$SHIMDIR:$PATH"

# ===========================================================================
# THE PRODUCT — a page that is EMPTY UNLESS SEEDED
# ===========================================================================
# `relay.py file <title>` writes a record under `requests/` and re-renders
# `index.html` from what is there. Committed, `index.html` lists nothing: the
# ONLY way the page shows a title is that something seeded it in the tree the
# server is serving.
mkproduct() { # <dir> — a git repo on branch feat/relay, committed
  local d="$1"
  mkdir -p "$d/requests" "$d/site"
  cat >"$d/relay.py" <<'RELAY'
#!/usr/bin/env python3
import json, os, sys, time

ROOT = os.path.dirname(os.path.abspath(__file__))
REQ = os.path.join(ROOT, "requests")


def rows():
    out = []
    if not os.path.isdir(REQ):
        return out
    for name in sorted(os.listdir(REQ)):
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(REQ, name)) as fh:
                out.append(json.load(fh))
        except Exception:
            pass
    return out


def render():
    items = "".join('<li class="req">%s</li>' % (r.get("title") or "")
                    for r in rows())
    html = ('<!doctype html><html><head><title>Request Relay</title></head>'
            '<body><div id="app-header">REQUEST RELAY</div>'
            '<ul id="task-list">%s</ul>'
            '<button id="add-button">ADD</button></body></html>' % items)
    with open(os.path.join(ROOT, "index.html"), "w") as fh:
        fh.write(html)
    return html


def main(argv):
    if len(argv) >= 3 and argv[1] == "file":
        os.makedirs(REQ, exist_ok=True)
        rid = "r-%d" % time.time_ns()
        with open(os.path.join(REQ, rid + ".json"), "w") as fh:
            json.dump({"id": rid, "title": argv[2]}, fh)
        render()
        print("filed %s" % rid)
        return 0
    if argv[1:2] == ["render"]:
        render()
        return 0
    if argv[1:2] == ["list"]:
        for r in rows():
            print("%s  %s" % (r.get("id"), r.get("title")))
        return 0
    sys.stderr.write("usage: relay.py file <title> | list | render\n")
    return 2


sys.exit(main(sys.argv))
RELAY
  printf '<!doctype html><html><head><title>Request Relay</title></head><body><div id="app-header">REQUEST RELAY</div><ul id="task-list"></ul><button id="add-button">ADD</button></body></html>\n' >"$d/index.html"
  # The SECOND serve target — the hub, beside the draft preview.
  printf '<!doctype html><html><head><title>Relay hub</title></head><body><div id="hub-title">HUB</div></body></html>\n' >"$d/site/index.html"
  printf '.DS_Store\n' >"$d/.gitignore"
  ( cd "$d" && git init -q -b main . \
      && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm "the relay" \
      && git checkout -q -b feat/relay \
      && git commit -q --allow-empty -m "the branch" ) >/dev/null 2>&1
  mkdir -p "$d/.git/lcars/missions"
  printf '{"repo": "t/relay"}\n' >"$d/.git/lcars/config.json"
}

# A mission at Verify with a drawing, a plan, and the entrypoints the record
# needs for the look to know there is a command line that could seed the page.
plant() { # <repo> <id> <entrypoints-json>
  local repo="$1" id="$2" eps="$3" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m/attachments"
  cat >"$m/state.json" <<ST
{
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-10-05T10:00:00Z"},
  "id": "$id",
  "type": "feature",
  "title": "The request relay",
  "stage": "verify",
  "branch": "feat/relay",
  "prUrl": "https://github.com/t/relay/pull/7",
  "created": "2026-10-05T10:00:00Z",
  "githubIssue": 42
}
ST
  cat >"$m/prd.md" <<'PRD'
# The request relay

## 2. Acceptance criteria
- The page lists every filed request.
- A request can be added from the page itself.

## 3. Out of scope
Email.
PRD
  cat >"$m/plan.json" <<PL
{"tickets": [{"id": "t-1", "changesScreenAppearance": true,
  "entrypoints": $eps,
  "acceptanceCriteria": [
    {"text": "The ADD button sits under the list.", "drawnAt": "#add-button, beneath the task list"},
    {"text": "The filed requests appear in the list.", "drawnAt": "#task-list"}]}]}
PL
  cat >"$m/attachments/attachment-01.html" <<'MK'
<div id="app-header">REQUEST RELAY</div><ul id="task-list"><li>a request</li></ul><button id="add-button">ADD</button>
MK
  printf '%s' "$m"
}

# ===========================================================================
# THE LAUNCH STUB — a REAL git worktree, and (when asked) a REAL server in it
# ===========================================================================
# It stands in for `launch.sh` exactly where the contract is: it writes a
# `launch.json` carrying `status`, `url`, `worktree` and `command`, and it
# records its whole argv so the suite can read what HINT it was handed. It is
# never given a flag the real parser would refuse.
LAUNCH_STUB="$TMPROOT/launch.sh"
cat >"$LAUNCH_STUB" <<'LS'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
wt="${XO_LS_TREE:?}"
case "${1:-}" in
  --stop)
    printf 'stop %s\n' "$mid" >>"$XO_LAUNCH_LOG"
    [ -f "$wt/serve.pid" ] && { kill "$(cat "$wt/serve.pid")" 2>/dev/null; rm -f "$wt/serve.pid"; }
    printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"
    exit 0 ;;
esac
printf 'launch %s | %s | env RELAY_DATA_DIR=%s HOME=%s\n' \
  "$mid" "$*" "${RELAY_DATA_DIR:-<unset>}" "$HOME" >>"$XO_LAUNCH_LOG"
# THE HINT, read back out of the prose the way launch.sh's discovery would.
hint="$*"; hint="${hint#-- }"
cmd="${XO_LS_DEFAULT_CMD:-python3 -m http.server}"
case "$hint" in
  *"with: "*) cmd="${hint#*with: }"; cmd="${cmd%% (cwd*}" ;;
esac
if [ ! -d "$wt" ]; then
  git -C "$PWD" worktree add --detach "$wt" feat/relay >/dev/null 2>&1 \
    || { printf '{\n  "status": "failed",\n  "url": "",\n  "message": "no worktree"\n}\n' >"$m/launch.json"; exit 1; }
fi
url="${XO_LS_URL:-http://127.0.0.1:4310/}"
if [ "${XO_LS_SERVE:-0}" = "1" ]; then
  port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
  sub="${XO_LS_SUBDIR:-}"
  ( cd "$wt/$sub" && exec python3 -m http.server "$port" --bind 127.0.0.1 ) >/dev/null 2>&1 &
  printf '%s' "$!" >"$wt/serve.pid"
  url="http://127.0.0.1:$port/index.html"
  # A server that is not up yet is a page that reads blank for reasons nothing
  # to do with seeding, so wait for the socket rather than guessing.
  python3 - "$port" <<'WAIT'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(100):
    try:
        socket.create_connection(("127.0.0.1", port), 0.2).close()
        sys.exit(0)
    except Exception:
        time.sleep(0.1)
sys.exit(1)
WAIT
fi
printf '{\n  "status": "running",\n  "url": "%s",\n  "pid": 1,\n  "command": "%s",\n  "worktree": "%s"\n}\n' \
  "$url" "$cmd" "$wt" >"$m/launch.json"
cp "$m/launch.json" "$XO_LAUNCH_LOG.json"
exit 0
LS
chmod +x "$LAUNCH_STUB"

# --- the stub driver (for the rows that do not need Chrome) ----------------
# It writes a per-shot readout carrying `places`, which is the record the
# wrong-screen rail reads. `$XO_DS_PRESENT=1` makes every declared part present.
# It deliberately writes NO `landed`/`page` block, so the S241 landing rail stays
# off and a row demoted here can only have been demoted by THIS session's rail.
DRIVE_STUB="$TMPROOT/xo-drive-stub.sh"
cat >"$DRIVE_STUB" <<'DS'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""; prefix="shot"; places=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --place-names) places="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out"
n="$(ls "$out"/*.png 2>/dev/null | grep -c . | tr -d ' ')"
name="$prefix-0$((n+1))"
printf 'PNG\n' >"$out/$name.png"
printf '%s — full page\n' "$name" >"$out/$name.txt"
PLACES="$places" PRESENT="${XO_DS_PRESENT:-0}" python3 - "$out/$name.json" "$name" <<'PYE'
import json, os, sys
dest, name = sys.argv[1], sys.argv[2]
names = []
try:
    with open(os.environ.get("PLACES") or "") as fh:
        doc = json.load(fh)
    names = [str(p).lstrip("#") for p in (doc.get("placeNames") or [])]
except Exception:
    names = []
present = os.environ.get("PRESENT") == "1"
places = {}
for nm in names:
    places[nm] = ({"present": True, "laidOut": True, "box": {"x": 0, "y": 0, "w": 100, "h": 20}}
                  if present else {"present": False})
json.dump({"shot": name, "places": places,
           "textExcerpt": "the page" if present else ""}, open(dest, "w"), indent=2)
PYE
printf '{"url":"x","allPainted":true}\n'
exit 0
DS
chmod +x "$DRIVE_STUB"

HOST_STUB="$TMPROOT/host-adapter.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOST_STUB"; chmod +x "$HOST_STUB"

jq_field() { # <json> <python expression over `d`>
  "$PY" -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

# ===========================================================================
# 1. SEED BEFORE THE WALK, IN THE TREE THE LAUNCH SERVES  (real Chrome)
# ===========================================================================
echo "1. the worker seeds in the pre-launch round and the LAUNCHED page shows it"

R1="$TMPROOT/r1"; mkproduct "$R1"
M1="$(plant "$R1" "lcars-20261005-001" '[{"kind":"cli","path":"relay.py"}]')"
export XO_LAUNCH_LOG="$TMPROOT/r1-launch.log"; : >"$XO_LAUNCH_LOG"
export XO_DRIVE_LOG="$TMPROOT/r1-drive.log"; : >"$XO_DRIVE_LOG"
P1="$TMPROOT/plan1"; mkdir -p "$P1"
# ROUND 1 — before the launch. It declares the seed AND the serve target.
cat >"$P1/1.actions" <<'A1'
{
  "serve": {"argv": ["python3", "-m", "http.server"], "cwd": "<worktree>", "urlPath": "/index.html"},
  "actions": [
    {"do": "run", "key": "seed-one", "for": "the page lists every filed request",
     "argv": ["python3", "relay.py", "file", "nonce-9"], "cwd": "<worktree>",
     "expect": {"exit": 0}}
  ]
}
A1
cat >"$P1/default.verdict" <<'V1'
{"score":"medium","summary":"Looked at the relay.",
 "criteria":[{"id":"prd-1","text":"the page lists every filed request","impact":"high","status":"met","shot":"shot-01","note":"saw it"}],
 "gaps":[],"alsoChecked":[],"escalations":[]}
V1

: >"$TMPROOT/r1-shim.log"
OUT1="$TMPROOT/r1-out.txt"
( export XO_PLAN_DIR="$P1" XO_SHIM_LOG="$TMPROOT/r1-shim.log" \
         XO_LS_TREE="$TMPROOT/r1-tree" XO_LS_SERVE=1
  "$PY" "$CAGE" 600 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 \
      bash "$6" evaluate --mission lcars-20261005-001' _ \
    "$R1" "$LAUNCH_STUB" "$REPO_ROOT/skills/lcars-xo/xo-drive.js" "$HOST_STUB" \
    "$SHIMDIR/copilot" "$SCRIPT" ) >"$OUT1" 2>&1

X1="$M1/xo"
SHOTS1="$(ls -d "$X1"/shots/look-* 2>/dev/null | head -1)"
check "1a. the look adopted the LAUNCH's worktree for its steps" \
  'grep -q "\"action\": \"reach-tree\"" "$M1/number-one.jsonl" &&
   grep -q "\"adopted\": true" "$M1/number-one.jsonl"'
check "1b. seed.json records the WORKER's seed, and the tree it ran in" \
  '[ -s "$X1/seed.json" ] &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1])); w=sys.argv[2]
srcs=d.get(\"sources\") or []
ws=[s for s in srcs if s.get(\"by\")==\"worker\"]
assert ws, d
assert ws[0].get(\"ranIn\")==w, (ws, w)
" "$X1/seed.json" "$TMPROOT/r1-tree"'
check "1c. the walk's FIRST readout shows the seeded record (nonce-9)" \
  '[ -n "$SHOTS1" ] && grep -l "nonce-9" "$SHOTS1"/shot-*.json | head -1 | grep -q .'
check "1d. and the step's OWN readout says it ran in that same tree" \
  '[ -n "$SHOTS1" ] &&
   "$PY" -c "
import glob, json, os, sys
root, wt = sys.argv[1], sys.argv[2]
hits = []
for p in glob.glob(os.path.join(root, \"*.json\")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get(\"do\") == \"run\" and \"nonce-9\" in json.dumps(d.get(\"argv\") or []):
        hits.append(d)
assert hits, sorted(os.path.basename(p) for p in glob.glob(os.path.join(root, \"*.json\")))
assert hits[0].get(\"worktree\") == wt, (hits[0].get(\"worktree\"), wt)
assert hits[0].get(\"exit\") == 0, hits[0]
" "$SHOTS1" "$TMPROOT/r1-tree"'

# ===========================================================================
# 2. THE RIGHT PAGE — the worker names it, and it becomes the HINT
# ===========================================================================
echo ""
echo "2. two serve targets → the worker's choice is the launch hint"

R2="$TMPROOT/r2"; mkproduct "$R2"
M2="$(plant "$R2" "lcars-20261005-002" \
  '[{"kind":"cli","path":"relay.py"},{"kind":"web","path":"index.html","urlPath":"/index.html"},{"kind":"web","path":"site/index.html","urlPath":"/site/index.html"}]')"
export XO_LAUNCH_LOG="$TMPROOT/r2-launch.log"; : >"$XO_LAUNCH_LOG"
export XO_DRIVE_LOG="$TMPROOT/r2-drive.log"; : >"$XO_DRIVE_LOG"
P2="$TMPROOT/plan2"; mkdir -p "$P2"
cat >"$P2/1.actions" <<'A2'
{
  "serve": {"argv": ["python3", "-m", "http.server", "--directory", "site"],
            "cwd": "<worktree>", "urlPath": "/index.html",
            "env": {"RELAY_DATA_DIR": "requests", "HOME": "/Users/somebody-else",
                    "PATH": "/nowhere"}},
  "actions": []
}
A2
cp "$P1/default.verdict" "$P2/default.verdict"

( export XO_PLAN_DIR="$P2" XO_SHIM_LOG="$TMPROOT/r2-shim.log" \
         XO_LS_TREE="$TMPROOT/r2-tree" XO_DS_PRESENT=1
  : >"$XO_SHIM_LOG"
  "$PY" "$CAGE" 300 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 \
      bash "$6" evaluate --mission lcars-20261005-002' _ \
    "$R2" "$LAUNCH_STUB" "$DRIVE_STUB" "$HOST_STUB" "$SHIMDIR/copilot" "$SCRIPT" \
  ) >"$TMPROOT/r2-out.txt" 2>&1

X2="$M2/xo"
check "2a. the look recorded the worker's declared serve target" \
  '[ -s "$X2/serve.json" ] &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"declared\") is True, d
assert d.get(\"argv\")==[\"python3\",\"-m\",\"http.server\",\"--directory\",\"site\"], d
assert d.get(\"urlPath\")==\"/index.html\", d
" "$X2/serve.json"'
check "2b. it reached launch.sh as a HINT, never a flag" \
  'grep -q "python3 -m http.server --directory site" "$TMPROOT/r2-launch.log" &&
   ! grep -q -- "--serve" "$TMPROOT/r2-launch.log" &&
   ! grep -q -- "--worktree" "$TMPROOT/r2-launch.log"'
check "2c. launch.json.command matches the declared argv" \
  '[ "$(jq_field "$TMPROOT/r2-launch.log.json" "d[\"command\"]")" = "python3 -m http.server --directory site" ]'
check "2d. and the choice is on the mission journal" \
  'grep -q "\"action\": \"serve-declared\"" "$M2/number-one.jsonl"'
check "2g. the look's declared env reaches the launched app" \
  'grep -q "RELAY_DATA_DIR=requests" "$TMPROOT/r2-launch.log"'
check "2h. …but a declared HOME does NOT — the launch keeps the real one" \
  '! grep -q "somebody-else" "$TMPROOT/r2-launch.log" &&
   grep -q "HOME=$HOME" "$TMPROOT/r2-launch.log"'
check "2i. …and a declared PATH is refused outright" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get(\"env\") or {}
assert \"RELAY_DATA_DIR\" in e, e
assert \"HOME\" not in e and \"PATH\" not in e, e
" "$X2/serve.json"'

# --- 2e. CONTROL: ONE target, nothing to choose, nothing asked -------------
R2C="$TMPROOT/r2c"; mkproduct "$R2C"
M2C="$(plant "$R2C" "lcars-20261005-012" '[{"kind":"cli","path":"relay.py"}]')"
P2C="$TMPROOT/plan2c"; mkdir -p "$P2C"; cp "$P1/default.verdict" "$P2C/default.verdict"
( export XO_PLAN_DIR="$P2C" XO_SHIM_LOG="$TMPROOT/r2c-shim.log" \
         XO_LAUNCH_LOG="$TMPROOT/r2c-launch.log" XO_DRIVE_LOG="$TMPROOT/r2c-drive.log" \
         XO_LS_TREE="$TMPROOT/r2c-tree" XO_DS_PRESENT=1
  : >"$XO_SHIM_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
  "$PY" "$CAGE" 300 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 \
      bash "$6" evaluate --mission lcars-20261005-012' _ \
    "$R2C" "$LAUNCH_STUB" "$DRIVE_STUB" "$HOST_STUB" "$SHIMDIR/copilot" "$SCRIPT" \
  ) >"$TMPROOT/r2c-out.txt" 2>&1
check "2e. CONTROL — one surface: no serve target is declared for the launch" \
  '[ ! -s "$M2C/xo/serve.json" ] ||
   [ "$(jq_field "$M2C/xo/serve.json" "d.get(\"declared\")")" = "False" ]'
check "2f. CONTROL — and the launch was handed no hint" \
  '! grep -q "with:" "$TMPROOT/r2c-launch.log"'

# ===========================================================================
# 3. THE WRONG SCREEN IS SAID, NOT JUDGED
# ===========================================================================
echo ""
echo "3. a page with none of the drawing's parts is escalated, never graded"

R3="$TMPROOT/r3"; mkproduct "$R3"
M3="$(plant "$R3" "lcars-20261005-003" \
  '[{"kind":"cli","path":"relay.py"},{"kind":"web","path":"index.html","urlPath":"/index.html"},{"kind":"web","path":"site/index.html","urlPath":"/site/index.html"}]')"
P3="$TMPROOT/plan3"; mkdir -p "$P3"
cat >"$P3/1.actions" <<'A3'
{"serve": {"argv": ["python3", "-m", "http.server", "--directory", "site"],
           "cwd": "<worktree>", "urlPath": "/index.html"}, "actions": []}
A3
cat >"$P3/2.actions" <<'A3B'
{"serve": {"argv": ["python3", "-m", "http.server"],
           "cwd": "<worktree>", "urlPath": "/index.html"}, "actions": []}
A3B
cat >"$P3/default.verdict" <<'V3'
{"score":"high","summary":"Looked at the relay.",
 "criteria":[
  {"id":"prd-1","text":"the page lists every filed request","impact":"high","status":"met","shot":"shot-01","note":"saw the list"},
  {"id":"prd-2","text":"a request can be added from the page","impact":"high","status":"met","shot":"shot-01","note":"saw the button"}],
 "gaps":[],"alsoChecked":[],"escalations":[]}
V3

( export XO_PLAN_DIR="$P3" XO_SHIM_LOG="$TMPROOT/r3-shim.log" \
         XO_LAUNCH_LOG="$TMPROOT/r3-launch.log" XO_DRIVE_LOG="$TMPROOT/r3-drive.log" \
         XO_LS_TREE="$TMPROOT/r3-tree" XO_DS_PRESENT=0
  : >"$XO_SHIM_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
  "$PY" "$CAGE" 300 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 \
      bash "$6" evaluate --mission lcars-20261005-003' _ \
    "$R3" "$LAUNCH_STUB" "$DRIVE_STUB" "$HOST_STUB" "$SHIMDIR/copilot" "$SCRIPT" \
  ) >"$TMPROOT/r3-out.txt" 2>&1

X3="$M3/xo"
check "3a. \`wrong-screen\` is journaled, with the url and the parts it looked for" \
  '"$PY" -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
ws=[r for r in rows if r.get(\"action\")==\"wrong-screen\"]
assert ws, [r.get(\"action\") for r in rows]
assert ws[0].get(\"url\"), ws[0]
assert ws[0].get(\"lookedFor\"), ws[0]
" "$M3/number-one.jsonl"'
check "3b. a different serve target was asked for, ONCE" \
  '[ "$("$PY" -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
print(len([r for r in rows if r.get(\"action\")==\"wrong-screen\"]))
" "$M3/number-one.jsonl")" = 1 ] &&
   [ "$(grep -c "^launch " "$TMPROOT/r3-launch.log")" -ge 2 ]'
check "3c. the browser rows are untested, with the wrong-screen reason" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rows=[c for c in (d.get(\"criteria\") or []) if c.get(\"id\") in (\"prd-1\",\"prd-2\")]
assert rows, d
for r in rows:
    assert r.get(\"status\")==\"untested\", r
    said=json.dumps(r).lower()
    assert \"wrong screen\" in said or \"none of the parts\" in said, r
" "$X3/verdict.json"'
check "3d. and no grade was published over that page" \
  '[ "$(jq_field "$M3/state.json" "(d.get(\"numberOne\") or {}).get(\"score\")")" != "high" ]'

# --- 3e. THE CONTROL: the SAME rig, a page WITH the parts ------------------
# Without this row the suite cannot tell a working rail from one that fires on
# everything. Nothing differs but `$XO_DS_PRESENT`.
R3C="$TMPROOT/r3c"; mkproduct "$R3C"
M3C="$(plant "$R3C" "lcars-20261005-013" \
  '[{"kind":"cli","path":"relay.py"},{"kind":"web","path":"index.html","urlPath":"/index.html"},{"kind":"web","path":"site/index.html","urlPath":"/site/index.html"}]')"
P3C="$TMPROOT/plan3c"; mkdir -p "$P3C"
cp "$P3/1.actions" "$P3C/1.actions"; cp "$P3/default.verdict" "$P3C/default.verdict"
( export XO_PLAN_DIR="$P3C" XO_SHIM_LOG="$TMPROOT/r3c-shim.log" \
         XO_LAUNCH_LOG="$TMPROOT/r3c-launch.log" XO_DRIVE_LOG="$TMPROOT/r3c-drive.log" \
         XO_LS_TREE="$TMPROOT/r3c-tree" XO_DS_PRESENT=1
  : >"$XO_SHIM_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
  "$PY" "$CAGE" 300 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 \
      bash "$6" evaluate --mission lcars-20261005-013' _ \
    "$R3C" "$LAUNCH_STUB" "$DRIVE_STUB" "$HOST_STUB" "$SHIMDIR/copilot" "$SCRIPT" \
  ) >"$TMPROOT/r3c-out.txt" 2>&1
check "3e. CONTROL — a page WITH the parts journals no wrong-screen" \
  '! grep -q "\"action\": \"wrong-screen\"" "$M3C/number-one.jsonl"'
check "3f. CONTROL — …and its rows keep the verdict the eye gave them" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rows=[c for c in (d.get(\"criteria\") or []) if c.get(\"id\") in (\"prd-1\",\"prd-2\")]
assert rows, d
assert any(r.get(\"status\")!=\"untested\" for r in rows), rows
" "$M3C/xo/verdict.json"'
check "3g. CONTROL — and only ONE launch was needed" \
  '[ "$(grep -c "^launch " "$TMPROOT/r3c-launch.log")" = 1 ]'

# ===========================================================================
# 4. BOTH SEEDS, ONE TREE
# ===========================================================================
echo ""
echo "4. verifySeed AND a worker seed both ran, in the same tree"

R4="$TMPROOT/r4"; mkproduct "$R4"
M4="$(plant "$R4" "lcars-20261005-004" '[{"kind":"cli","path":"relay.py"}]')"
printf '{"repo": "t/relay", "verifySeed": "python3 relay.py file declared-seed"}\n' \
  >"$R4/.git/lcars/config.json"
P4="$TMPROOT/plan4"; mkdir -p "$P4"
cat >"$P4/1.actions" <<'A4'
{"actions": [
  {"do": "run", "key": "seed-two", "for": "the page lists every filed request",
   "argv": ["python3", "relay.py", "file", "worker-seed"], "cwd": "<worktree>",
   "expect": {"exit": 0}}]}
A4
cp "$P1/default.verdict" "$P4/default.verdict"
( export XO_PLAN_DIR="$P4" XO_SHIM_LOG="$TMPROOT/r4-shim.log" \
         XO_LAUNCH_LOG="$TMPROOT/r4-launch.log" XO_DRIVE_LOG="$TMPROOT/r4-drive.log" \
         XO_LS_TREE="$TMPROOT/r4-tree" XO_DS_PRESENT=1
  : >"$XO_SHIM_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
  "$PY" "$CAGE" 300 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 LCARS_XO_PRELAUNCH=1 \
      bash "$6" evaluate --mission lcars-20261005-004' _ \
    "$R4" "$LAUNCH_STUB" "$DRIVE_STUB" "$HOST_STUB" "$SHIMDIR/copilot" "$SCRIPT" \
  ) >"$TMPROOT/r4-out.txt" 2>&1

X4="$M4/xo"
check "4a. seed.json records BOTH sources" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
by={s.get(\"by\") for s in (d.get(\"sources\") or [])}
assert by=={\"repo\",\"worker\"}, d
" "$X4/seed.json"'
check "4b. both ran in the SAME tree — the one the launch serves" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1])); w=sys.argv[2]
trees={s.get(\"ranIn\") for s in (d.get(\"sources\") or [])}
assert trees=={w}, (trees, w)
" "$X4/seed.json" "$TMPROOT/r4-tree"'
check "4c. and the declared seed's own record is still there (exit, command)" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=[s for s in (d.get(\"sources\") or []) if s.get(\"by\")==\"repo\"][0]
assert r.get(\"command\"), r
assert r.get(\"exit\") == 0, r
" "$X4/seed.json"'
check "4d. the worker's seed step ran, and its transcript proves the tree" \
  '"$PY" -c "
import glob, json, os, sys
root, wt = sys.argv[1], sys.argv[2]
hits = []
for p in glob.glob(os.path.join(root, \"look-*\", \"*.json\")) + glob.glob(os.path.join(root, \"*.json\")):
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if d.get(\"do\") == \"run\" and \"worker-seed\" in json.dumps(d.get(\"argv\") or []):
        hits.append(d)
assert hits, \"no readout for the worker seed step\"
assert hits[0].get(\"worktree\") == wt, (hits[0].get(\"worktree\"), wt)
assert hits[0].get(\"exit\") == 0, hits[0]
" "$X4/shots" "$TMPROOT/r4-tree"'

# ===========================================================================
# 5. FIX ROUND 1 / D2 — A LOOK THAT CHECKED NOTHING CANNOT OPEN WITH "MERGE"
# ===========================================================================
# WHAT THE TESTER SAW. Line 1 of the report over the un-placeable page read
# `**Recommendation: MERGE WITH FOLLOW-UPS**`; line 2 read "checked 0 of 3 (0%)
# … I could not check anything on your list, so nothing here is vouched for."
# The first thing a reader sees said ship it.
#
# WHY THE POLICY ITSELF IS NOT THE BUG. `derive_recommendation` sends an
# `untested` high-impact row whose cause is NOT `product` to `infra_blind`, which
# is a FOLLOW-UP, not a blocker. That is right for ONE row blind for a rig
# reason — and S248's wrong-screen demotion puts EVERY row there, which leaves
# zero gaps and lets a merge out of a run that placed nothing. So the rule added
# is narrow (nothing checked ⇒ never a merge) and rows 5b/5c are the controls
# that prove the rest of the policy did not move.
echo ""
echo "5. a look that could check nothing cannot recommend a merge (fix round 1, D2)"

D2PY="$TMPROOT/d2.py"
cat >"$D2PY" <<'PYD2'
"""The REAL derive_grade/derive_recommendation, imported out of the real file."""
import importlib.util, json, sys

spec = importlib.util.spec_from_file_location("xoscore", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def row(cid, status, impact="high"):
    return {"id": cid, "status": status, "impact": impact,
            "note": "the page I was given showed none of the parts the drawing declares"}


case = sys.argv[2]
if case == "nothing-checked":
    # Every row demoted by the wrong-screen rail: untested, high, no `cause`.
    led = [row("prd-1", "untested"), row("prd-2", "untested"), row("prd-3", "untested")]
elif case == "all-worked":
    led = [row("prd-%d" % i, "met") for i in range(1, 6)]
elif case == "one-blind":
    led = [row("prd-1", "met"), row("prd-2", "met"), row("prd-3", "met"),
           row("prd-4", "met"), row("prd-5", "untested")]
else:
    raise SystemExit("unknown case %s" % case)

adv = mod.derive_recommendation(led, mod.derive_grade(led))
print(json.dumps({"recommendation": adv["recommendation"],
                  "because": adv["because"], "followUps": adv["followUps"]}, indent=2))
PYD2

d2() { "$PY" "$D2PY" "$REPO_ROOT/skills/lcars-xo/xo-score.py" "$1" 2>&1; }
d2rec() { d2 "$1" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)["recommendation"])' 2>/dev/null; }

check "5a. nothing checked at all is NOT a merge of any kind" \
  'r="$(d2rec nothing-checked)"; case "$r" in merge|merge-with-follow-ups) false ;; "") false ;; *) true ;; esac'
check "5b. CONTROL — everything checked and nothing short of the mark IS still \`merge\`" \
  '[ "$(d2rec all-worked)" = merge ]'
check "5c. CONTROL — ONE row blind for a rig reason is still \`merge-with-follow-ups\`" \
  '[ "$(d2rec one-blind)" = merge-with-follow-ups ]'
check "5d. and the reason says, in plain words, that nothing could be checked" \
  'd2 nothing-checked | grep -qi "could not check"'

# --- INTEGRATION: the real report, over the real un-placeable page ---------
# $X3 is section 3's wrong-screen run; $M3C/xo is its own control, same rig,
# only `$XO_DS_PRESENT` different. Both reports already exist.
check "5e. the report over a page nobody could place does NOT open with a merge" \
  '[ -s "$X3/report.md" ] && ! head -1 "$X3/report.md" | grep -q "MERGE"'
check "5f. CONTROL — the same rig over a page it COULD place still can" \
  '[ -s "$M3C/xo/report.md" ] && head -1 "$M3C/xo/report.md" | grep -q "MERGE"'

# ===========================================================================
# 6. FIX ROUND 1 / D1 — A ROUND'S OWN SET-UP STEPS ARE PHOTOGRAPHED
# ===========================================================================
# WHAT THE TESTER SAW. The set-up steps ran in exactly the right workspace
# (`seed.json`: `by: "worker"`, `ranIn: <the launch tree>`) and the filed
# requests survived into the next round — yet EVERY readout in the whole review
# recorded `present=false`. Pictures are taken at the TOP of a round and the
# steps run at the END of it, so a round's own render lands after its camera.
#
# REAL CHROME, REAL SERVER, REAL WORKTREE. The pre-launch round deliberately
# asks for NOTHING, so the first picture is of the empty page — row 6a is the
# precondition, and without it 6b could pass on a page that was never empty.
echo ""
echo "6. a round whose steps ran gets photographed again, after them (fix round 1, D1)"

R5="$TMPROOT/r5"; mkproduct "$R5"
M5="$(plant "$R5" "lcars-20261005-005" '[{"kind":"cli","path":"relay.py"}]')"
P5="$TMPROOT/plan5"; mkdir -p "$P5"
printf '{"actions": []}\n' >"$P5/1.actions"
cat >"$P5/2.actions" <<'A5'
{"actions": [
  {"do": "run", "key": "file-one", "for": "the page lists every filed request",
   "argv": ["python3", "relay.py", "file", "roundone-nonce"], "cwd": "<worktree>",
   "expect": {"exit": 0}}]}
A5
cp "$P1/default.verdict" "$P5/default.verdict"

OUT5="$TMPROOT/r5-out.txt"
( export XO_PLAN_DIR="$P5" XO_SHIM_LOG="$TMPROOT/r5-shim.log" \
         XO_LAUNCH_LOG="$TMPROOT/r5-launch.log" XO_DRIVE_LOG="$TMPROOT/r5-drive.log" \
         XO_LS_TREE="$TMPROOT/r5-tree" XO_LS_SERVE=1
  : >"$XO_SHIM_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
  "$PY" "$CAGE" 600 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=2 \
      bash "$6" evaluate --mission lcars-20261005-005' _ \
    "$R5" "$LAUNCH_STUB" "$REPO_ROOT/skills/lcars-xo/xo-drive.js" "$HOST_STUB" \
    "$SHIMDIR/copilot" "$SCRIPT" ) >"$OUT5" 2>&1

X5="$M5/xo"
SHOTS5="$(ls -d "$X5"/shots/look-* 2>/dev/null | head -1)"
check "6a. PRECONDITION — every picture taken at the TOP of a round is of the empty page" \
  '[ -n "$SHOTS5" ] && ! grep -l "roundone-nonce" "$SHOTS5"/shot-*.json "$SHOTS5"/round1-*.json 2>/dev/null | grep -q .'
check "6b. a readout taken AFTER that round's steps shows what they put on the page" \
  '[ -n "$SHOTS5" ] && grep -l "roundone-nonce" "$SHOTS5"/after1-*.json 2>/dev/null | grep -q .'
check "6c. and the reviewer is TOLD the steps changed the page" \
  '"$PY" -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hits=[r for r in rows if r.get(\"action\")==\"steps-effect\"]
assert hits, [r.get(\"action\") for r in rows]
assert any(r.get(\"changed\") is True for r in hits), hits
" "$M5/number-one.jsonl"'
check "6d. CONTROL — a round that asked for no steps gets no extra picture" \
  '[ -n "$SHOTS5" ] && ls "$SHOTS5"/after1-*.json >/dev/null 2>&1 &&
   ! ls "$SHOTS5"/after2-*.json >/dev/null 2>&1 &&
   ! ls "$M1/xo/shots"/look-*/after*.json >/dev/null 2>&1 &&
   ! ls "$M2/xo/shots"/look-*/after*.json >/dev/null 2>&1'
# THE ROUND PROMPT IS WHERE THE REVIEWER IS TOLD (fix round 1, D1). The prompt
# reaches the engine as `-p <text>` on argv, and the shim logs its whole argv —
# so these two rows read the real sentence out of the real call, not a copy.
prompt_recs() { # <shim-log> <needle> → how many worker calls carried it
  "$PY" - "$1" "$2" <<'PYPR'
import sys
recs, cur = [], None
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("engine="):
        cur = [line]; recs.append(cur)
    elif cur is not None:
        cur.append(line)
print(sum(1 for r in recs if sys.argv[2] in "".join(r)))
PYPR
}
check "6g. the reviewer is TOLD, in its own round prompt, that those shots exist" \
  '[ "$(prompt_recs "$TMPROOT/r5-shim.log" "pictures taken AFTER your set-up steps")" -ge 1 ]'
check "6h. CONTROL — the pre-launch round, which has no pictures at all, is not told it" \
  '[ "$(prompt_recs "$TMPROOT/r5-shim.log" "THIS ROUND IS BEFORE THE LAUNCH")" -ge 1 ] &&
   "$PY" - "$TMPROOT/r5-shim.log" <<PYX
import sys
recs, cur = [], None
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("engine="):
        cur = [line]; recs.append(cur)
    elif cur is not None:
        cur.append(line)
for r in recs:
    t = "".join(r)
    if "THIS ROUND IS BEFORE THE LAUNCH" in t:
        assert "pictures taken AFTER your set-up steps" not in t, "told in the pre-launch round"
PYX
'
check "6e. CONTROL — the right page was placed, so the side-by-side DID run" \
  'grep -q "side by side:" "$OUT5"'
check "6f. CONTROL — a page that filled up records no empty-page cause" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert not d.get(\"pageStillEmpty\"), d
" "$X5/seed.json"'

# ===========================================================================
# 7. FIX ROUND 1 / D3 + D4 — NO MEASUREMENT OVER A PAGE WE REFUSED TO PLACE,
#    AND THE HOME THE STEPS RAN UNDER IS A RECORD
# ===========================================================================
# D3, as the tester saw it: `side by side: 4 drawn part(s): 2 matched, 2
# unreachable, 1 with a measured difference` — printed on the wrong-screen run.
# A look that will not grade a page must not measure against it either.
#
# D4: `seed.json` recorded `ranIn` and never the HOME. The steps run under a
# throwaway HOME while the launched app keeps the real one, so a product reading
# a hardcoded path under `$HOME` has no bridge and its page reads an empty store
# — and the report said only "the page was empty".
#
# The rig: a REAL server on `site/`, which carries NONE of the drawing's parts,
# and a DECLARED `verifySeed` that really runs. Section 6's run is this one's
# control (6e/6f), same code, a page that could be placed.
echo ""
echo "7. the wrong screen stands down the measurement, and names the empty-store cause"

R6="$TMPROOT/r6"; mkproduct "$R6"
M6="$(plant "$R6" "lcars-20261005-006" \
  '[{"kind":"cli","path":"relay.py"},{"kind":"web","path":"index.html","urlPath":"/index.html"},{"kind":"web","path":"site/index.html","urlPath":"/site/index.html"}]')"
printf '{"repo": "t/relay", "verifySeed": "python3 relay.py file hub-seed"}\n' \
  >"$R6/.git/lcars/config.json"
P6="$TMPROOT/plan6"; mkdir -p "$P6"
printf '{"actions": []}\n' >"$P6/1.actions"
cp "$P1/default.verdict" "$P6/default.verdict"

OUT6="$TMPROOT/r6-out.txt"
( export XO_PLAN_DIR="$P6" XO_SHIM_LOG="$TMPROOT/r6-shim.log" \
         XO_LAUNCH_LOG="$TMPROOT/r6-launch.log" XO_DRIVE_LOG="$TMPROOT/r6-drive.log" \
         XO_LS_TREE="$TMPROOT/r6-tree" XO_LS_SERVE=1 XO_LS_SUBDIR=site
  : >"$XO_SHIM_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
  "$PY" "$CAGE" 600 bash -c '
    cd "$1" && env LCARS_LAUNCH_SCRIPT="$2" LCARS_XO_DRIVER="$3" \
      LCARS_HOST_ADAPTER="$4" LCARS_WORKER_BIN="$5" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      LCARS_XO_MAX_ROUNDS=1 LCARS_XO_PRELAUNCH=1 \
      bash "$6" evaluate --mission lcars-20261005-006' _ \
    "$R6" "$LAUNCH_STUB" "$REPO_ROOT/skills/lcars-xo/xo-drive.js" "$HOST_STUB" \
    "$SHIMDIR/copilot" "$SCRIPT" ) >"$OUT6" 2>&1

X6="$M6/xo"
check "7a. PRECONDITION — the wrong screen was found and it stood" \
  'grep -q "\"action\": \"wrong-screen-stands\"" "$M6/number-one.jsonl"'
check "7b. D3 — no side-by-side measurement is reported over that page" \
  '! grep -q "side by side:" "$OUT6"'
check "7c. D3 — and it says why it stood down" \
  'grep -q "\"action\": \"pairing-stood-down\"" "$M6/number-one.jsonl" &&
   grep -qi "not measure" "$OUT6"'
check "7d. D4 — seed.json records the HOME the declared seed ran under" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rows=[s for s in (d.get(\"sources\") or []) if s.get(\"by\")==\"repo\"]
assert rows, d
assert rows[0].get(\"home\"), rows[0]
" "$X6/seed.json"'
check "7e. D4 — a seed that ran onto a page that stayed empty is recorded as such" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
e=d.get(\"pageStillEmpty\") or {}
assert e, d
assert e.get(\"note\"), e
assert e.get(\"home\") or e.get(\"appHome\"), e
" "$X6/seed.json"'
check "7f. D4 — and the report NAMES the two stores as the possible cause" \
  '[ -s "$X6/report.md" ] && grep -qi "HOME" "$X6/report.md"'

# ===========================================================================
# ZERO SPEND, COUNTED
# ===========================================================================
echo ""
total_shim=0; with_model=0
for f in "$TMPROOT"/*shim.log; do
  [ -f "$f" ] || continue
  n="$(grep -c '^engine=' "$f" 2>/dev/null)"; total_shim=$((total_shim + ${n:-0}))
  n="$(grep -c -- '--model' "$f" 2>/dev/null)"; with_model=$((with_model + ${n:-0}))
done
printf 'SHIM: %s invocation(s) of the faked claude/copilot, %s carried --model\n' \
  "$total_shim" "$with_model"
printf 'SPEND: $0.00 — no engine on this machine was ever called.\n'

echo ""
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
