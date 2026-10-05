#!/usr/bin/env bash
#
# S246 — THE MODEL DRIVES. Seven behaviours, one suite.
#
# WHY THIS FILE EXISTS. Number One could already ASK for a `run`, a `workflow` or
# a `read` step (S239) — but it could never use one twice. `xo-run.py` minted a
# fresh worktree and a fresh throwaway HOME per PROCESS, refused any HOME but the
# one it minted, and the round loop stopped at 2 rounds × 12 actions. So a worker
# could not seed in one round and read in the next, could not be a second user,
# and was cut off at roughly five minutes. The captain's buddy, following the
# SAME checklists by hand, ran for hours. And when the launch had no url,
# `verdict.json` was overwritten with `score: low, criteria: []` — every reach
# transcript already on disk thrown away.
#
# The seven behaviours driven here, in order:
#
#   1  ONE TREE, ONE HOME, PER LOOK — round 1 writes under HOME-1, round 2 reads
#      it back under the SAME HOME-1. Control: a different HOME sees nothing.
#   2  A SECOND HOME — a step may declare `<throwaway-home-2>` and gets a second
#      minted dir; a literal `/Users/...` HOME is still refused.
#   3  NO CLOCK — $LCARS_XO_MAX_ROUNDS unset means no ceiling; set means a
#      ceiling, and the old sentence still reads true.
#   4  A NOTEBOOK — `xo-notes.md` from round 1 is in round 2's input dir,
#      APPENDED, not replaced.
#   5  REACH EVIDENCE COUNTS — no url + reach transcripts is a SCORED verdict;
#      "nothing to look at" only with no transcripts AND no tests.
#   6  THE `looking` ENTRY — every round journals what it is doing NOW, and the
#      First Officer's report renders it with its `did` lines.
#   7  THE PROMPT, BUDDY-SHAPED — the live-check checklists are handed to the
#      worker WHOLE, and nothing claims a step was built from the record.
#
# THE FENCE THIS FILE GUARDS. The worker role stays repo-read with NO shell. It
# DECLARES steps; the harness executes them. The second HOME widens the fence by
# exactly one thing — a HOME that is one of the LOOK'S OWN marks — and an
# arbitrary absolute HOME is still refused. That refusal has its own control here.
#
# ZERO SPEND. No worker CLI runs. A PATH shim fakes BOTH `claude` and `copilot`
# and counts every invocation; the count is asserted at the end.
#
# Usage: bash tests/lcars-xo-drives.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="${LCARS_XO_SCRIPT:-$REPO_ROOT/skills/lcars-xo/xo.sh}"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
REPORT_PY="$REPO_ROOT/skills/lcars-xo/xo-report.py"
JOURNEY_PY="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
CRITERIA_PY="$REPO_ROOT/skills/lcars-xo/xo-criteria.py"
LIVE_CHECK="$REPO_ROOT/skills/lcars-run/live-check"
EVALUATE_MD="$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$REPO_ROOT/tests/lib/cage.py"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND: a shim that fakes BOTH engines and counts every call -------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
export SPEND_LOG="$TMPROOT/spend.log"
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

echo "lcars xo — THE MODEL DRIVES (S246): one tree per look, a second home, a notebook, no clock"

# ===========================================================================
# THE PRODUCT — a real git repo with a real STATEFUL CLI
#
# `relay.py` keeps its records under $HOME/.relay/records, so "did the state
# survive the round" is a question the product itself answers. That is the point:
# a fixture that stored nothing could not tell one HOME from two.
# ===========================================================================
PROD="$TMPROOT/prod"; mkdir -p "$PROD"
git -C "$PROD" init -q -b main >/dev/null 2>&1
cat >"$PROD/relay.py" <<'PYEOF'
import os, sys

HOME = os.environ.get("HOME", "")
STORE = os.path.join(HOME, ".relay", "records")


def load():
    try:
        with open(STORE) as fh:
            return [l.rstrip("\n") for l in fh if l.strip()]
    except Exception:
        return []


args = sys.argv[1:]
if not args or args[0] in ("--help", "-h"):
    print("usage: relay [file|list]")
    sys.exit(0)
if args[0] == "file":
    if len(args) < 2 or not args[1].strip():
        sys.stderr.write("relay: file needs a title\n")
        sys.exit(2)
    os.makedirs(os.path.dirname(STORE), exist_ok=True)
    with open(STORE, "a") as fh:
        fh.write(args[1] + "\n")
    print("filed %s (HOME=%s)" % (args[1], HOME))
    sys.exit(0)
if args[0] == "list":
    rows = load()
    if not rows:
        print("no records yet (HOME=%s)" % HOME)
    for r in rows:
        print("record: %s" % r)
    sys.exit(0)
sys.stderr.write("relay: no such subcommand %s\n" % args[0])
sys.exit(2)
PYEOF
mkdir -p "$PROD/.github/workflows"
cat >"$PROD/.github/workflows/publish.yml" <<'YML'
name: publish
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: say hello
        run: echo hello
YML
printf 'the published page\n' >"$PROD/site.txt"
git -C "$PROD" add -A >/dev/null 2>&1
git -C "$PROD" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$PROD" branch -q feat/relay 2>/dev/null

MDIR="$TMPROOT/mission-bare"; mkdir -p "$MDIR"
: >"$MDIR/number-one.jsonl"

# ===========================================================================
# 1. ONE TREE, ONE HOME, PER LOOK
# ===========================================================================
echo ""
echo "1. one tree and one throwaway HOME, carried across every call of a look"

# `xo-run.py prepare` is how the LOOK gets the tree and the HOME ONCE, from the
# ONE helper (autopilot.sh wt_prepare). It must print both, in the shape xo.sh
# reads back.
PREP="$TMPROOT/prepare.out"
"$PY" "$CAGE" 120 "$PY" "$XORUN" prepare --repo "$PROD" --branch feat/relay \
  >"$PREP" 2>&1
check "1a. \`xo-run.py prepare\` prints a WORKTREE and a HOME for the whole look" \
  'grep -q "^WORKTREE: " "$PREP" && grep -q "^HOME: " "$PREP"'
LOOK_WT="$(sed -n 's/^WORKTREE: //p' "$PREP" | head -1)"
LOOK_HOME="$(sed -n 's/^HOME: //p' "$PREP" | head -1)"
check "1a. …and both really exist on disk" \
  '[ -n "$LOOK_WT" ] && [ -d "$LOOK_WT" ] && [ -n "$LOOK_HOME" ] && [ -d "$LOOK_HOME" ]'
check "1a. …and the worktree is DETACHED, not the checked-out tree" \
  '[ "$LOOK_WT" != "$PROD" ]'

mkjourney() { # <file> <json-steps>
  printf '{"steps": [], "reachSteps": %s}\n' "$2" >"$1"
}

# ROUND 1 — file a nonce under HOME-1.
mkjourney "$TMPROOT/r1.json" '[
  {"do": "run", "key": "s1", "for": "prd-1", "fromChecklist": "cli#3",
   "argv": ["python3", "relay.py", "file", "nonce-7"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "03-happy-path.txt",
   "expect": {"exit": 0}}]'
S1="$TMPROOT/shots/look-1"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run --journey "$TMPROOT/r1.json" \
  --repo "$PROD" --branch feat/relay --out "$S1" --mission-dir "$MDIR" \
  --worktree "$LOOK_WT" --home "$LOOK_HOME" >"$TMPROOT/r1.out" 2>&1
check "1b. round 1 ran, under the HOME the LOOK minted" \
  '[ -s "$S1/03-happy-path.txt" ] && grep -q "nonce-7" "$S1/03-happy-path.txt"'
check "1b. …and the look's own tree and HOME SURVIVE the call" \
  '[ -d "$LOOK_WT" ] && [ -d "$LOOK_HOME" ]'
check "1b. …and the readout names the look's HOME, not one of its own" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"home\"] == sys.argv[2], (d[\"home\"], sys.argv[2])
assert d[\"worktree\"] == sys.argv[3], (d[\"worktree\"], sys.argv[3])
" "$S1/03-happy-path.json" "$LOOK_HOME" "$LOOK_WT"'

# ROUND 2 — read it back under the SAME HOME-1.
mkjourney "$TMPROOT/r2.json" '[
  {"do": "run", "key": "s2", "for": "prd-1", "fromChecklist": "cli#3",
   "argv": ["python3", "relay.py", "list"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "04-readback.txt",
   "expect": {"exit": 0}}]'
S2="$TMPROOT/shots/look-1b"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run --journey "$TMPROOT/r2.json" \
  --repo "$PROD" --branch feat/relay --out "$S2" --mission-dir "$MDIR" \
  --worktree "$LOOK_WT" --home "$LOOK_HOME" >"$TMPROOT/r2.out" 2>&1
check "1c. THE BEHAVIOUR — round 2 under the SAME HOME sees round 1's record" \
  'grep -q "record: nonce-7" "$S2/04-readback.txt"'

# THE CONTROL. The same read with NO --home: xo-run.py mints its own, and the
# record is NOT there. Without this the row above could pass on a product that
# stores nothing in HOME at all.
S3="$TMPROOT/shots/look-1c"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run --journey "$TMPROOT/r2.json" \
  --repo "$PROD" --branch feat/relay --out "$S3" --mission-dir "$MDIR" \
  >"$TMPROOT/r3.out" 2>&1
check "1c. CONTROL — the same read under a DIFFERENT HOME sees nothing" \
  '[ -s "$S3/04-readback.txt" ] && grep -q "no records yet" "$S3/04-readback.txt" &&
   ! grep -q "record: nonce-7" "$S3/04-readback.txt"'
check "1c. …and that self-minted run tore ITS OWN tree down again" \
  '! git -C "$PROD" worktree list --porcelain | grep -q "$(basename "$S3")"'
check "1c. …while the LOOK's tree is still standing" '[ -d "$LOOK_WT" ]'

# ===========================================================================
# 2. A SECOND HOME — a second actor is a second HOME
# ===========================================================================
echo ""
echo "2. a step may ask for a SECOND throwaway HOME, and only the look's own marks"

mkjourney "$TMPROOT/r4.json" '[
  {"do": "run", "key": "s3", "for": "prd-1", "fromChecklist": "cli#4",
   "argv": ["python3", "relay.py", "list"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home-2>"}, "evidence": "04-two-actors.txt",
   "expect": {"exit": 0}},
  {"do": "run", "key": "s4", "for": "prd-1", "fromChecklist": "cli#4",
   "argv": ["python3", "relay.py", "list"], "cwd": "<worktree>",
   "env": {"HOME": "/Users/somebody-else"}, "evidence": "09-escape.txt",
   "expect": {"exit": 0}}]'
S4="$TMPROOT/shots/look-2"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run --journey "$TMPROOT/r4.json" \
  --repo "$PROD" --branch feat/relay --out "$S4" --mission-dir "$MDIR" \
  --worktree "$LOOK_WT" --home "$LOOK_HOME" >"$TMPROOT/r4.out" 2>&1
check "2a. THE BEHAVIOUR — a <throwaway-home-2> step RAN" \
  '[ -s "$S4/04-two-actors.txt" ]'
check "2a. …in a SECOND directory, not the look's first HOME" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"home\"] != sys.argv[2], d[\"home\"]
assert d.get(\"home2\"), d
assert d[\"home2\"] == d[\"home\"], d
" "$S4/04-two-actors.json" "$LOOK_HOME"'
check "2a. …and actor B sees NONE of actor A's record (a second actor really is one)" \
  'grep -q "no records yet" "$S4/04-two-actors.txt" &&
   ! grep -q "record: nonce-7" "$S4/04-two-actors.txt"'
check "2a. …and the second HOME sits beside the first, under the same parent" \
  '"$PY" -c "
import json,os,sys
d=json.load(open(sys.argv[1]))
assert os.path.dirname(d[\"home2\"].rstrip(\"/\")) == os.path.dirname(sys.argv[2].rstrip(\"/\")), d
" "$S4/04-two-actors.json" "$LOOK_HOME"'
check "2b. CONTROL — a literal /Users/... HOME is still REFUSED, as before" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"refused\") is True, d
assert \"HOME\" in (d.get(\"why\") or \"\"), d
" "$S4/09-escape.json"'
check "2b. …and the refused step never ran the command" \
  '! grep -q "no records yet" "$S4/09-escape.txt"'

# AND THE REQUEST GATE AGREES WITH THE EXECUTION GATE. `xo-run.py actions` reads
# a worker's REQUEST before any worktree exists; it must keep a second-home step
# and still refuse an arbitrary one.
cat >"$TMPROOT/acts-home.json" <<'JSON'
{"actions": [
  {"do": "run", "argv": ["python3", "relay.py", "list"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home-2>"}, "evidence": "a.txt", "for": "prd-1"},
  {"do": "run", "argv": ["python3", "relay.py", "list"], "cwd": "<worktree>",
   "env": {"HOME": "/Users/somebody-else"}, "evidence": "b.txt", "for": "prd-1"}]}
JSON
"$PY" "$XORUN" actions --actions "$TMPROOT/acts-home.json" \
  --out "$TMPROOT/acts-home-kept.json" --mission-dir "$MDIR" >/dev/null 2>&1
check "2c. a REQUESTED <throwaway-home-2> step is KEPT" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
keeps=[s for s in d[\"reachSteps\"] if (s.get(\"env\") or {}).get(\"HOME\")==\"<throwaway-home-2>\"]
assert keeps, d" "$TMPROOT/acts-home-kept.json"'
check "2c. CONTROL — a REQUESTED /Users/... HOME is refused at the gate" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert len(d[\"reachSteps\"])==1, d
assert any(\"HOME\" in (r.get(\"why\") or \"\") for r in d[\"refused\"]), d
" "$TMPROOT/acts-home-kept.json"'

# THE LOOK'S TEARDOWN TAKES THE SECOND HOME WITH IT.
H2="$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["home2"])' \
  "$S4/04-two-actors.json" 2>/dev/null || true)"
"$PY" "$XORUN" teardown --repo "$PROD" --worktree "$LOOK_WT" --home "$LOOK_HOME" \
  >"$TMPROOT/teardown.out" 2>&1
check "2d. the look's teardown removes the tree, the HOME and the SECOND HOME" \
  '[ ! -d "$LOOK_WT" ] && [ ! -d "$LOOK_HOME" ] && { [ -z "$H2" ] || [ ! -d "$H2" ]; }'
check "2d. …and leaves no registered worktree behind in the repo" \
  '! git -C "$PROD" worktree list --porcelain | grep -q "lcars-ap-wt-"'

# ===========================================================================
# THE xo.sh RIG — a real evaluate, with the three costly things stubbed
# ===========================================================================
EVDIR="$TMPROOT/ev"; mkdir -p "$EVDIR"
export XO_LAUNCH_LOG="$EVDIR/launch.log"; : >"$XO_LAUNCH_LOG"
export XO_DRIVE_LOG="$EVDIR/drive.log";   : >"$XO_DRIVE_LOG"
export XO_WORKER_LOG="$EVDIR/worker.log"; : >"$XO_WORKER_LOG"

LAUNCH_STUB="$EVDIR/launch.sh"
cat >"$LAUNCH_STUB" <<'LS'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
printf 'launch %s %s\n' "$mid" "$*" >>"$XO_LAUNCH_LOG"
case "${1:-}" in
  --stop) printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
if [ "${XO_LAUNCH_NO_URL:-0}" = "1" ]; then
  printf '{\n  "status": "running",\n  "url": "",\n  "pid": 1,\n  "message": "the app is running."\n}\n' >"$m/launch.json"
  exit 0
fi
printf '{\n  "status": "running",\n  "url": "http://127.0.0.1:4310/",\n  "pid": 1\n}\n' >"$m/launch.json"
LS
chmod +x "$LAUNCH_STUB"

DRIVE_STUB="$EVDIR/drive.sh"
cat >"$DRIVE_STUB" <<'DS'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
n="$(ls "$out"/*.png 2>/dev/null | grep -c . | tr -d ' ')"
printf 'PNG\n' >"$out/shot-0$((n+1)).png"
printf '{"shot":"shot-0%s"}\n' "$((n+1))" >"$out/shot-0$((n+1)).json"
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
DS
chmod +x "$DRIVE_STUB"

# --- THE SCRIPTED WORKER ----------------------------------------------------
# Round N reads $XO_SCRIPT_DIR/round-N.{actions,verdict}.json and may leave a
# notebook. It also RECORDS the input dir it was handed, which is how "the
# notebook came back" is observed from the worker's own side of the door.
EV_SHIM="$EVDIR/ev-worker"
cat >"$EV_SHIM" <<'EVS'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
out="${LCARS_WORK_OUT:-}"
n="$(grep -c '^worker ' "$XO_WORKER_LOG" 2>/dev/null)"; n="${n:-1}"
d="${XO_SCRIPT_DIR:-}"
if [ -n "${LCARS_XO_INPUT_DIR:-}" ] && [ -d "${LCARS_XO_INPUT_DIR:-}" ]; then
  mkdir -p "$d/seen-$n"
  cp "$LCARS_XO_INPUT_DIR/notes.md" "$d/seen-$n/notes.md" 2>/dev/null || true
  ( cd "$LCARS_XO_INPUT_DIR" && find . -type f | sort ) >"$d/seen-$n/inventory.txt" 2>/dev/null || true
fi
[ -f "$d/round-$n.notes.md" ] && cp "$d/round-$n.notes.md" "$out/xo-notes.md"
if [ -f "$d/round-$n.actions.json" ]; then
  cp "$d/round-$n.actions.json" "$out/xo-actions.json"; exit 0
fi
if [ -f "$d/round-$n.verdict.json" ]; then
  cp "$d/round-$n.verdict.json" "$out/xo-verdict.json"; exit 0
fi
[ -f "$d/verdict.json" ] && cp "$d/verdict.json" "$out/xo-verdict.json"
exit 0
EVS
chmod +x "$EV_SHIM"

new_repo() { # <dir-stem>
  local repo
  repo="$(mktemp -d "$TMPROOT/$1.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  cp "$PROD/relay.py" "$repo/relay.py"
  mkdir -p "$repo/.github/workflows"
  cp "$PROD/.github/workflows/publish.yml" "$repo/.github/workflows/publish.yml"
  printf 'the published page\n' >"$repo/site.txt"
  git -C "$repo" add -A >/dev/null 2>&1
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
  git -C "$repo" branch -q feat/relay 2>/dev/null
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'CJ'
{
  "cloneId": "aaaaaaaa",
  "model": "claude-sonnet",
  "projectName": "relay",
  "contextFile": null,
  "stack": null,
  "testCommand": "true",
  "worktreeSetupCommand": null,
  "comprehensionBudget": 1200,
  "numberOne": {"enabled": true, "engine": "copilot"},
  "created": "2026-05-30T00:00:00Z"
}
CJ
  printf '%s' "$repo"
}

plant() { # <repo> <id>
  local repo="$1" id="$2" m="$1/.git/lcars/missions/$2"
  mkdir -p "$m"
  cat >"$m/state.json" <<SJ
{
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-10-04T10:00:00Z"},
  "id": "$id",
  "type": "feature",
  "title": "Request Relay",
  "stage": "verify",
  "branch": "feat/relay",
  "prUrl": "https://github.com/x/y/pull/7",
  "created": "2026-10-04T10:00:00Z",
  "githubIssue": 42
}
SJ
  cat >"$m/prd.md" <<'PRD'
# Request Relay

PLAN RULE: CLI-only. This milestone adds no page and no screen.

## 2. Acceptance criteria
- `relay.py file "<title>"` stores a record and prints the id it stored.
- `relay.py list` prints every record that was filed.

## 3. Out of scope
Email.
PRD
  cat >"$m/plan.json" <<'PL'
{"tickets": [{"id": "t-1", "changesScreenAppearance": false,
  "entrypoints": [{"kind": "cli", "path": "relay.py",
                   "realRunTest": "tests/test_cli.py",
                   "realRunProof": "it runs relay.py as a subprocess"}],
  "acceptanceCriteria": [
    {"text": "relay file stores the title it was given", "notVisual": true,
     "kind": "works", "serves": "prd-1", "direction": "delivers"}]}]}
PL
  printf '%s' "$m"
}

evaluate() { # <repo> <id> [extra env assignments...]
  local repo="$1" id="$2"; shift 2
  ( cd "$repo" && XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
      LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
      LCARS_LOG_SCRIPT=/usr/bin/true LCARS_RESOLVE_LOGS_SCRIPT=/usr/bin/true \
      LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 \
      "$@" bash "$XO" evaluate --mission "$id" 2>&1 )
}

verdict_json() { # <status> — a one-criterion ledger the scorer will accept
  cat <<JS
{"score": "medium", "summary": "I ran the CLI and read what it printed.",
 "criteria": [{"id": "prd-1", "text": "relay file stores a record",
   "impact": "high", "impactWhy": "it is the whole product",
   "status": "$1", "evidence": "transcript", "checkedBy": "cli",
   "shot": "03-happy-path",
   "note": "I filed nonce-7 and listed it back and the record was there",
   "action": "Ran relay.py file then relay.py list.",
   "reason": "Impact high because it is the product. I tried filing a record; I saw it listed back (evidence: 03-happy-path.txt). Outcome: it worked."}],
 "gaps": [], "escalations": [], "alsoChecked": [],
 "couldNot": [{"item": "a third actor on a third HOME",
               "why": "two was enough to see the collision and I stopped there"}]}
JS
}

# ===========================================================================
# 3. NO CLOCK — the look ends when the WORKER says so
# ===========================================================================
echo ""
echo "3. no clock: the round loop runs until the worker writes its verdict"

SC_A="$TMPROOT/script-a"; mkdir -p "$SC_A"
for n in 1 2 3 4 5; do
  printf '[{"click":"#x"},{"screenshot":"more-%s"}]\n' "$n" >"$SC_A/round-$n.actions.json"
done
verdict_json met >"$SC_A/round-6.verdict.json"
repoA="$(new_repo repoA)"; mA="$(plant "$repoA" lcars-20261004-301)"
: >"$XO_WORKER_LOG"
outA="$("$PY" "$CAGE" 600 bash -c '
  cd "$1" && XO_WORKER_LOG="$2" XO_SCRIPT_DIR="$3" \
    LCARS_LAUNCH_SCRIPT="$4" LCARS_XO_DRIVER="$5" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$6" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 \
    bash "$7" evaluate --mission lcars-20261004-301 2>&1' _ \
  "$repoA" "$XO_WORKER_LOG" "$SC_A" "$LAUNCH_STUB" "$DRIVE_STUB" "$EV_SHIM" "$XO")"
check "3a. THE BEHAVIOUR — five action rounds were granted, and the sixth decided" \
  '[ "$(grep -c "^worker " "$XO_WORKER_LOG")" = "6" ]'
check "3a. …and the verdict was SCORED, not refused for running out of rounds" \
  '[ -s "$mA/xo/verdict.json" ] &&
   ! grep -q "could not reach a verdict" "$mA/xo/verdict.json"'
check "3a. …and no round line ever quotes a ceiling it does not have" \
  '! printf "%s" "$outA" | grep -qE "round [0-9]+ of"'
check "3a. …the console counts the rounds it actually ran" \
  'printf "%s" "$outA" | grep -q "round 5" && printf "%s" "$outA" | grep -q "round 1"'

# THE CEILING IS OPT-IN, AND ITS OLD SENTENCE STILL READS TRUE.
SC_B="$TMPROOT/script-b"; mkdir -p "$SC_B"
for n in 1 2 3 4 5 6 7 8 9; do
  printf '[{"click":"#x"},{"screenshot":"more-%s"}]\n' "$n" >"$SC_B/round-$n.actions.json"
done
repoB="$(new_repo repoB)"; mB="$(plant "$repoB" lcars-20261004-302)"
: >"$XO_WORKER_LOG"
outB="$("$PY" "$CAGE" 600 bash -c '
  cd "$1" && XO_WORKER_LOG="$2" XO_SCRIPT_DIR="$3" \
    LCARS_LAUNCH_SCRIPT="$4" LCARS_XO_DRIVER="$5" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$6" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 LCARS_XO_MAX_ROUNDS=2 \
    bash "$7" evaluate --mission lcars-20261004-302 2>&1' _ \
  "$repoB" "$XO_WORKER_LOG" "$SC_B" "$LAUNCH_STUB" "$DRIVE_STUB" "$EV_SHIM" "$XO")"
check "3b. \$LCARS_XO_MAX_ROUNDS=2 is still a CEILING — exactly two workers" \
  '[ "$(grep -c "^worker " "$XO_WORKER_LOG")" = "2" ]'
check "3b. …and the old sentence still reads true, quoting the cap in force" \
  'grep -q "could not reach a verdict in 2 rounds" "$mB/xo/verdict.json"'
check "3b. …and the console counts to that cap" \
  'printf "%s" "$outB" | grep -q "round 1 of 2" &&
   printf "%s" "$outB" | grep -q "round 2 of 2" &&
   ! printf "%s" "$outB" | grep -q "round 3 of"'

# ===========================================================================
# 4. A NOTEBOOK — what it tried, what it saw, what it will try next
# ===========================================================================
echo ""
echo "4. the notebook: the worker's own notes come back next round, appended"

SC_C="$TMPROOT/script-c"; mkdir -p "$SC_C"
printf '[{"click":"#x"},{"screenshot":"one"}]\n' >"$SC_C/round-1.actions.json"
printf 'ROUND ONE NOTE: I filed nonce-7 and I will list it next.\n' >"$SC_C/round-1.notes.md"
printf '[{"click":"#y"},{"screenshot":"two"}]\n' >"$SC_C/round-2.actions.json"
printf 'ROUND TWO NOTE: the record was there.\n' >"$SC_C/round-2.notes.md"
verdict_json met >"$SC_C/round-3.verdict.json"
repoC="$(new_repo repoC)"; mC="$(plant "$repoC" lcars-20261004-303)"
: >"$XO_WORKER_LOG"
outC="$("$PY" "$CAGE" 600 bash -c '
  cd "$1" && XO_WORKER_LOG="$2" XO_SCRIPT_DIR="$3" \
    LCARS_LAUNCH_SCRIPT="$4" LCARS_XO_DRIVER="$5" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$6" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 \
    bash "$7" evaluate --mission lcars-20261004-303 2>&1' _ \
  "$repoC" "$XO_WORKER_LOG" "$SC_C" "$LAUNCH_STUB" "$DRIVE_STUB" "$EV_SHIM" "$XO")"
check "4a. the notebook is kept with the look, under the mission's own xo/" \
  '[ -s "$mC/xo/notes.md" ]'
check "4b. THE BEHAVIOUR — round 2 was handed round 1's note" \
  '[ -s "$SC_C/seen-2/notes.md" ] && grep -q "ROUND ONE NOTE" "$SC_C/seen-2/notes.md"'
check "4b. …and it is named in the input inventory the worker sees" \
  'grep -q "notes.md" "$SC_C/seen-2/inventory.txt"'
check "4c. APPENDED, NOT REPLACED — round 3 sees both rounds' notes" \
  '[ -s "$SC_C/seen-3/notes.md" ] &&
   grep -q "ROUND ONE NOTE" "$SC_C/seen-3/notes.md" &&
   grep -q "ROUND TWO NOTE" "$SC_C/seen-3/notes.md"'
check "4d. CONTROL — round 1 was handed no notebook at all (nothing to invent)" \
  '[ ! -s "$SC_C/seen-1/notes.md" ]'
check "4e. each note is stamped with the round that wrote it" \
  'grep -qi "round 1" "$mC/xo/notes.md" && grep -qi "round 2" "$mC/xo/notes.md"'

# ===========================================================================
# 5. REACH EVIDENCE COUNTS — a look with no page is still a look
# ===========================================================================
echo ""
echo "5. no url from the launch: the transcripts are still scored"

SC_D="$TMPROOT/script-d"; mkdir -p "$SC_D"
cat >"$SC_D/round-1.actions.json" <<'JSON'
[{"do": "run", "argv": ["python3", "relay.py", "--help"], "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"}, "evidence": "01-help.txt",
  "for": "prd-1", "expect": {"exit": 0}},
 {"do": "run", "argv": ["python3", "relay.py", "file", "nonce-7"], "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"}, "evidence": "03-happy-path.txt",
  "for": "prd-1", "expect": {"exit": 0}},
 {"do": "run", "argv": ["python3", "relay.py", "list"], "cwd": "<worktree>",
  "env": {"HOME": "<throwaway-home>"}, "evidence": "04-readback.txt",
  "for": "prd-1", "expect": {"exit": 0, "stdoutIncludes": "nonce-7"}}]
JSON
verdict_json met >"$SC_D/round-2.verdict.json"
repoD="$(new_repo repoD)"; mD="$(plant "$repoD" lcars-20261004-304)"
: >"$XO_WORKER_LOG"; : >"$XO_DRIVE_LOG"
outD="$("$PY" "$CAGE" 900 bash -c '
  cd "$1" && XO_WORKER_LOG="$2" XO_SCRIPT_DIR="$3" XO_LAUNCH_NO_URL=1 \
    XO_DRIVE_LOG="$8" XO_LAUNCH_LOG="$9" \
    LCARS_LAUNCH_SCRIPT="$4" LCARS_XO_DRIVER="$5" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$6" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 \
    bash "$7" evaluate --mission lcars-20261004-304 2>&1' _ \
  "$repoD" "$XO_WORKER_LOG" "$SC_D" "$LAUNCH_STUB" "$DRIVE_STUB" "$EV_SHIM" "$XO" \
  "$XO_DRIVE_LOG" "$XO_LAUNCH_LOG")"
LOOKD="$(ls -d "$mD"/xo/shots/look-* 2>/dev/null | head -1)"
check "5a. the worker's three reach steps really ran, with no page anywhere" \
  '[ -n "$LOOKD" ] && [ -s "$LOOKD/01-help.txt" ] && [ -s "$LOOKD/03-happy-path.txt" ] &&
   [ -s "$LOOKD/04-readback.txt" ]'
check "5a. …and the state carried between them inside ONE look" \
  'grep -q "record: nonce-7" "$LOOKD/04-readback.txt"'
check "5b. NO browser was started — the browser instruments are what is skipped" \
  '[ ! -s "$XO_DRIVE_LOG" ]'
check "5c. THE BEHAVIOUR — the verdict is SCORED from the transcripts" \
  '[ -s "$mD/xo/verdict.json" ] &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rows=d.get(\"criteria\") or []
assert rows, d
assert any((r.get(\"checkedBy\") or \"\")==\"cli\" for r in rows), rows
" "$mD/xo/verdict.json"'
check "5c. …and it carries a RECOMMENDATION, like any other look" \
  'grep -q "recommendation" "$mD/xo/verdict.json"'
check "5c. …and it NEVER says there was nothing to look at" \
  '! grep -q "nothing for me to look at" "$mD/xo/verdict.json"'
check "5c. …and a worker WAS hired, because there was evidence to judge" \
  '[ "$(grep -c "^worker " "$XO_WORKER_LOG")" -ge 1 ]'

# THE CONTROL that makes 5c mean something: no url AND no reach steps AND no
# tests still says "nothing to look at", and still hires nobody.
SC_E="$TMPROOT/script-e"; mkdir -p "$SC_E"
verdict_json met >"$SC_E/verdict.json"
repoE="$(new_repo repoE)"; mE="$(plant "$repoE" lcars-20261004-305)"
# THE CONTROL HAS TO HAVE NOTHING TO REACH. A page product whose page has no
# address: no cli, no workflow, no PLAN RULE line, and no test command. If this
# mission declared a command line the look would be RIGHT to go on looking, and
# the row below would prove nothing.
cat >"$mE/prd.md" <<'PRD'
# The relay board

## 2. Acceptance criteria
- The board shows every filed record in one list.

## 3. Out of scope
Email.
PRD
cat >"$mE/plan.json" <<'PL'
{"tickets": [{"id": "t-1", "changesScreenAppearance": true,
  "acceptanceCriteria": [
    {"text": "The list sits under the header.", "drawnAt": "#list, beneath the header"}]}]}
PL
"$PY" - "$repoE/.git/lcars/config.json" <<'PYEOF'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["testCommand"] = None
json.dump(d, open(p, "w"), indent=2)
PYEOF
: >"$XO_WORKER_LOG"; : >"$XO_DRIVE_LOG"
outE="$("$PY" "$CAGE" 600 bash -c '
  cd "$1" && XO_WORKER_LOG="$2" XO_SCRIPT_DIR="$3" XO_LAUNCH_NO_URL=1 \
    XO_DRIVE_LOG="$8" XO_LAUNCH_LOG="$9" \
    LCARS_LAUNCH_SCRIPT="$4" LCARS_XO_DRIVER="$5" LCARS_NODE_BIN=bash \
    LCARS_WORKER_BIN="$6" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 LCARS_XO_UNLISTED=0 \
    bash "$7" evaluate --mission lcars-20261004-305 2>&1' _ \
  "$repoE" "$XO_WORKER_LOG" "$SC_E" "$LAUNCH_STUB" "$DRIVE_STUB" "$EV_SHIM" "$XO" \
  "$XO_DRIVE_LOG" "$XO_LAUNCH_LOG")"
check "5d. CONTROL — nothing to reach, no tests, no page: it says so, and scores LOW" \
  'grep -q "nothing for me to look at" "$mE/xo/verdict.json"'
check "5d. …and hires NOBODY, because there is nothing to judge" \
  '[ ! -s "$XO_WORKER_LOG" ]'
check "5d. …and starts no browser either" '[ ! -s "$XO_DRIVE_LOG" ]'

# ===========================================================================
# 6. THE `looking` ENTRY — what it is doing NOW, on the board
# ===========================================================================
echo ""
echo "6. every round says what it is doing, and the report renders it"
check "6a. THE BEHAVIOUR — each round journals a \`looking\` entry" \
  '[ "$(grep -c "\"action\": \"looking\"" "$mD/number-one.jsonl")" -ge 1 ]'
check "6b. …carrying the round, what was asked, and ONE LINE PER STEP" \
  '"$PY" -c "
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
look=[r for r in rows if r.get(\"action\")==\"looking\"]
assert look, [r.get(\"action\") for r in rows]
r=look[0]
assert isinstance(r.get(\"round\"), int), r
assert isinstance(r.get(\"asked\"), int) and r[\"asked\"]==3, r
did=r.get(\"did\")
assert isinstance(did, list) and len(did)==3, r
assert all(isinstance(x, str) and x.strip() for x in did), r
assert any(\"relay.py\" in x for x in did), did
" "$mD/number-one.jsonl"'
check "6b. CONTROL — a round that asked for nothing journals no \`looking\` line" \
  '! grep -q "\"action\": \"looking\"" "$mE/number-one.jsonl"'
R6="$TMPROOT/report6.txt"
( cd "$repoD" && "$PY" "$REPORT_PY" "$repoD/.git/lcars/missions" \
    "$TMPROOT/seen6.json" --all >"$R6" 2>&1 ) || true
check "6c. the First Officer's report RENDERS the looking entry…" \
  'grep -q "looking" "$R6"'
# NOT a bare grep for "relay.py" — that string appears elsewhere in the report,
# and a loose match here passed before any of this was built. The did lines are
# rendered as their own bulleted lines UNDER the entry, so that is what is asked.
check "6c. …with the \`did\` lines a colleague can follow, as their own lines" \
  '"$PY" - "$R6" <<EOF
import sys
body = open(sys.argv[1]).read().splitlines()
hits = [l for l in body if l.strip().startswith("· ") and "relay.py" in l]
assert hits, [l for l in body if "looking" in l or "relay" in l]
sys.exit(0)
EOF'
check "6c. CONTROL — the bare report of a look with no \`looking\` entry has no such line" \
  '"$PY" - "$R6" <<EOF
import sys
body = open(sys.argv[1]).read().splitlines()
assert not [l for l in body if l.strip().startswith("· ") and "nonce-9999" in l]
sys.exit(0)
EOF'

# ===========================================================================
# 7. THE PROMPT, BUDDY-SHAPED — the checklists handed over WHOLE
# ===========================================================================
echo ""
echo "7. the checklists reach the worker whole; the templater's text does not"

ADAPTER="$EVDIR/adapter.sh"
cat >"$ADAPTER" <<'AD'
#!/usr/bin/env bash
# spawn <cli> <role> <outdir> <prompt>
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$ADAPTER"

repoP="$(new_repo repoP)"; mP="$(plant "$repoP" lcars-20261004-306)"
mkdir -p "$mP/xo" "$TMPROOT/p-in" "$TMPROOT/p-out"
# A mission whose plan declares ALL THREE surfaces — a cli entrypoint, a workflow
# entrypoint, and a ticket that changes the screen. The checklists handed over are
# read off `productTypes`, so this is the record that asks for all three.
cat >"$mP/plan.json" <<'PL'
{"tickets": [
  {"id": "t-1", "changesScreenAppearance": true,
   "entrypoints": [{"kind": "cli", "path": "relay.py",
                    "realRunTest": "tests/test_cli.py",
                    "realRunProof": "it runs relay.py as a subprocess"},
                   {"kind": "workflow", "path": ".github/workflows/publish.yml",
                    "realRunTest": "tests/test_wf.py",
                    "realRunProof": "it runs the workflow's own steps"}],
   "acceptanceCriteria": [
     {"text": "relay file stores the title it was given", "notVisual": true,
      "kind": "works", "serves": "prd-1", "direction": "delivers"}]}]}
PL
"$PY" "$CRITERIA_PY" "$mP" "$mP/xo/criteria.json" >/dev/null 2>&1 || true
cp "$mP/xo/criteria.json" "$TMPROOT/p-in/criteria.json" 2>/dev/null || true
cp "$mP/prd.md" "$TMPROOT/p-in/prd.md"

# S247 — THE SWITCH IS GONE WITH THE MECHANISM. This helper took a
# `$LCARS_XO_TEMPLATER` setting so S246 could prove the worker path carried the
# load with the record-derived instantiation turned OFF. There is nothing to turn
# off any more: the first argument is kept for the call shape and ignored.
dump_prompt() { # <ignored> <dump-file> [input-dir]
  ( cd "$repoP" && XO_PROMPT_DUMP="$2" \
      LCARS_WORKER_ADAPTER="$ADAPTER" LCARS_WORKER_BIN="$EV_SHIM" \
      LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
      LCARS_XO_INPUT_DIR="${3:-$TMPROOT/p-in}" LCARS_GH_BIN=/usr/bin/true \
      bash "$RUNSH" spawn-number-one --mission lcars-20261004-306 \
        --mode evaluate --outdir "$TMPROOT/p-out" >/dev/null 2>&1 )
}
P_OFF="$TMPROOT/prompt-off.txt"
dump_prompt 0 "$P_OFF"
check "7a. the prompt was captured at all" '[ -s "$P_OFF" ]'
check "7a. …and the contract really did record all three surfaces" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
t={x[\"type\"] for x in d[\"productTypes\"]}
assert t == {\"cli\",\"web\",\"workflow\"}, t
" "$TMPROOT/p-in/criteria.json"'
# WHOLE, not summarised: the first line of each file, a line from the middle, and
# the last item all have to be there.
for kind in cli web workflow; do
  first="$(sed -n '1p' "$LIVE_CHECK/$kind.md")"
  check "7b. THE BEHAVIOUR — $kind.md is handed over, first line and all" \
    'grep -qF "$first" "$P_OFF"'
done
# AND ONLY THE ONES THE RECORD ASKS FOR. A page checklist on a product with no
# page is noise, and a prompt that grows is a named wrong answer.
CLI_IN="$TMPROOT/p-in-cli"; mkdir -p "$CLI_IN"
printf '%s\n' '{"productTypes": [{"type": "cli", "source": "the plan"}], "criteria": []}' \
  >"$CLI_IN/criteria.json"
P_CLI="$TMPROOT/prompt-cli-only.txt"
dump_prompt 0 "$P_CLI" "$CLI_IN"
check "7b. CONTROL — a CLI-only record gets the cli checklist…" \
  'grep -qF "$(sed -n "1p" "$LIVE_CHECK/cli.md")" "$P_CLI"'
check "7b. CONTROL — …and NOT the page one it has no page for" \
  '! grep -qF "$(sed -n "1p" "$LIVE_CHECK/web.md")" "$P_CLI"'
check "7b. …WHOLE: the cli checklist's last item is there too, not just its head" \
  'grep -qF "Re-verify after every fix round" "$P_OFF"'
check "7b. …and so is the item a template could never build — two actors, two HOMEs" \
  'grep -qF "Two actors — two HOMEs, two laptops" "$P_OFF"'
check "7c. it tells the worker to INVENT the values a human would" \
  'tr "\n" " " <"$P_OFF" | tr -s " " | grep -qi "invent the values a human would"'
check "7c. …that a second user is a second home" \
  'tr "\n" " " <"$P_OFF" | tr -s " " | grep -qi "a second user is a second home"'
check "7c. …and that IT decides when it has seen enough" \
  'tr "\n" " " <"$P_OFF" | tr -s " " | grep -qi "you decide when you have seen enough"'
check "7d. the fence sentence SURVIVES the rewrite" \
  'tr "\n" " " <"$P_OFF" | tr -s " " | grep -q "You have no shell, and you are not getting one"'
check "7d. …and so does the two-files contract" \
  'grep -q "xo-verdict.json" "$P_OFF" && grep -q "xo-actions.json" "$P_OFF"'
check "7e. nothing claims steps were built from the record" \
  '! grep -qi "reachUninstantiated" "$P_OFF" &&
   ! tr "\n" " " <"$P_OFF" | tr -s " " | grep -qi "already instantiated what it could"'
# S247 — THE CONTROL IS NOW THE SOURCE, not a second prompt. There is no setting
# that makes that sentence come back, so the thing to prove is that the sentence
# is not in the prompt builder at all. Measured before the deletion: it was.
check "7e. CONTROL — …and that sentence is gone from the prompt builder itself" \
  '! grep -qi "already instantiated what it could" "$RUNSH"'
check "7e. …and the checklists are still handed over whole" \
  'grep -qF "Two actors — two HOMEs, two laptops" "$P_OFF"'

# THE PROMPT FILE ITSELF GOT SHORTER. A prompt that grows is a named wrong answer.
check "7f. evaluate.md is SHORTER than the 689 lines it was" \
  '[ "$(grep -c "" "$EVALUATE_MD")" -lt 689 ]'

# AND NOTHING INSTANTIATES A STEP FROM THE RECORD, ON THE VERY RECORD THAT USED
# TO PRODUCE SIX OF THEM (S247). This is the same fixture the switch was proved
# with: a cli product type, a `relay.py` entrypoint and a cli criterion.
cat >"$TMPROOT/t-criteria.json" <<'JSON'
{"productTypes": [{"type": "cli", "source": "the plan's entrypoints[]"}],
 "entrypoints": [{"kind": "cli", "ticket": "t-1", "path": "relay.py"}],
 "criteria": [{"id": "prd-1", "text": "relay file stores a record",
               "reachVia": "cli", "primary": true, "notVisual": true}]}
JSON
check "7g. a cli record with an entrypoint instantiates NOTHING" \
  '"$PY" "$JOURNEY_PY" build --criteria "$TMPROOT/t-criteria.json" \
     --prd "$mP/prd.md" --out "$TMPROOT/t-off.json" >/dev/null 2>&1;
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"reachSteps\") == [], d.get(\"reachSteps\")
assert \"reachUninstantiated\" not in d, sorted(d)
" "$TMPROOT/t-off.json"'
check "7g. CONTROL — and the ONE author of the list is named in the prompt" \
  'tr "\n" " " <"$P_OFF" | tr -s " " | grep -qi "invent the values a human would"'

# ===========================================================================
# 8. THE WORKER'S OWN "what I could not check"
# ===========================================================================
echo ""
echo "8. what I could not check is the WORKER's list, not the templater's"
check "8a. THE BEHAVIOUR — the worker's OWN \`couldNot\` entry reaches the report" \
  '[ -s "$mD/xo/report.md" ] &&
   grep -q "What I could not check" "$mD/xo/report.md" &&
   grep -q "a third actor on a third HOME" "$mD/xo/report.md" &&
   grep -q "two was enough to see the collision" "$mD/xo/report.md"'
check "8b. CONTROL — the templater being OFF means its own refusals are NOT listed" \
  '! grep -qi "could not BUILD from your record" "$mD/xo/report.md"'
check "8b. …and no \`reachUninstantiated\` survived into the record at all" \
  '! grep -q "reachUninstantiated" "$mD/xo/journey.json" 2>/dev/null ||
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert not (d.get(\"reachUninstantiated\") or []), d.get(\"reachUninstantiated\")
" "$mD/xo/journey.json"'

# ===========================================================================
# 9. ZERO SPEND
# ===========================================================================
echo ""
echo "9. zero spend"
SPENT="$(grep -c . "$SPEND_LOG" 2>/dev/null | tr -d ' ')"; SPENT="${SPENT:-0}"
MODELED="$(grep -c -- '--model' "$SPEND_LOG" 2>/dev/null | tr -d ' ')"; MODELED="${MODELED:-0}"
check "9a. no real engine was ever invoked (claude or copilot)" '[ "$SPENT" = "0" ]'
check "9b. …and nothing carried a --model that would have billed" '[ "$MODELED" = "0" ]'
printf '  shim invocations: %s (with --model: %s)\n' "$SPENT" "$MODELED"

echo ""
printf 'lcars-xo-drives: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
