#!/usr/bin/env bash
#
# S239 — REACH. Tests for the five things this session builds.
#
# WHY THIS FILE EXISTS (the measurement, not a hunch). On the Canvas weekend of
# 26–29 Sep 2026, same product, 34 runs: Number One filed 0 of 31 bugs; the
# captain's buddy found all 31. Every one of the 16 recorded misses
# (lcars-dev/canvas-weekend-2026-09-26/evidence/number-one-misses.jsonl) is a
# REACH error and not a judgement error — there was no screen for a CLI, nothing
# was seeded so the surface was never reached, or a stub made the seam
# untestable. Its judgement and its honesty were fine wherever it could reach.
# So this file drives REACH:
#
#   1   the product's TYPES are recorded, and every criterion says how it is
#       REACHED (`reachVia`). A CLI criterion is reached by RUNNING THE CLI.
#   2   the journey carries three new DECLARED step kinds — `run`, `workflow`,
#       `read` — built from the live-check checklists as templates.
#   2b  xo-run.py EXECUTES them, in a DETACHED worktree with a THROWAWAY HOME,
#       caged, writing a transcript + readout beside the browser shots.
#   3b  the worker may REQUEST more of them, under the same ≤12 cap, and a
#       request that tries to leave the worktree is refused and journaled.
#   4   `evaluate --again --because "<why>"` supersedes a finished verdict.
#   5   a FINISHED verdict never blocks `approve`; a LIVE look still does.
#   6   the prompt teaches the new kinds and keeps the honesty rules.
#
# THE FENCE THIS FILE ALSO GUARDS: the worker role stays `repo-read`. It never
# gets a shell. Reach comes from DECLARED steps the HARNESS executes — that is
# the whole design (S168's fence, S222's "a model left to walk freely is a
# lottery").
#
# ZERO SPEND. No worker CLI runs anywhere in this file; a PATH shim fakes BOTH
# `claude` and `copilot` and counts every invocation, and the count is asserted
# to be 0.
#
# Usage: bash tests/lcars-xo-reach.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo/xo.sh"
CRITERIA="$REPO_ROOT/skills/lcars-xo/xo-criteria.py"
JOURNEY="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
OWNERSHIP="$REPO_ROOT/skills/lcars-run/ownership.sh"
AUTOPILOT="$REPO_ROOT/skills/lcars-buddy/autopilot.sh"
LIVE_CHECK="$REPO_ROOT/skills/lcars-run/live-check"
EVALUATE_MD="$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$REPO_ROOT/tests/lib/cage.py"
GIT="${LCARS_GIT_BIN:-git}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND: a shim that fakes BOTH engines and counts every call -------
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

# A WORKER BINARY THAT SPENDS NOTHING, pinned where a look now reaches the worker
# rounds (S246). Until S246 a launch that failed ended the look on the spot, so no
# `evaluate` in this file ever hired anybody. Now a look with no page SCORES WHAT
# IT REACHED instead of discarding it — which is the whole point of that change —
# so the `--again` row below legitimately gets as far as hiring. Unpinned, the
# engine resolves `copilot` off $PATH and the shim records the call; pinned, this
# suite stays about REACH rather than about the engine ladder. It writes neither
# output file, so the round is silent and the look ends.
NOOP_WORKER="$TMPROOT/noop-worker"
printf '#!/usr/bin/env bash\nexit 0\n' >"$NOOP_WORKER"
chmod +x "$NOOP_WORKER"

echo "lcars xo — REACH (S239): product types, declared run/workflow/read steps, re-look, approve"

# ===========================================================================
# 1. PRODUCT TYPES + reachVia, WITH THE SOURCE RECORDED
# ===========================================================================
echo ""
echo "1. the product's types, and how each criterion is reached"

# A CLI-ONLY mission: the PRD declares the PLAN RULE, every ticket declares it
# changes no screen, and the plan declares a `cli` entrypoint (S236's record).
CLIM="$TMPROOT/m-cli"; mkdir -p "$CLIM"
cat >"$CLIM/prd.md" <<'MD'
# Notes — a command line for notes

PLAN RULE: CLI-only. This milestone adds no page and no screen.

## Acceptance criteria
- `notes add "<title>"` stores a note and prints the id it stored.
- `notes --help` lists every subcommand the CLI dispatches.
- `notes list` prints the notes in the order they were added.
MD
cat >"$CLIM/plan.json" <<'JSON'
{"tickets": [
  {"id": "t1", "changesScreenAppearance": false,
   "entrypoints": [{"kind": "cli", "path": "notes.py",
                    "realRunTest": "tests/test_cli.py",
                    "realRunProof": "it runs notes.py as a subprocess"}],
   "seams": [], "seamsNote": "pure store",
   "acceptanceCriteria": [
     {"text": "notes add stores the title it was given", "notVisual": true,
      "kind": "works", "serves": "prd-1", "direction": "delivers"},
     {"text": "notes --help names every subcommand", "notVisual": true,
      "kind": "works", "serves": "prd-2", "direction": "delivers"}]}
]}
JSON
cat >"$CLIM/state.json" <<'JSON'
{"id": "m-cli", "title": "Notes — a command line for notes", "stage": "verify",
 "branch": "feat/notes"}
JSON
"$PY" "$CRITERIA" "$CLIM" "$TMPROOT/cli-criteria.json" >"$TMPROOT/cli-criteria.out" 2>&1
CJ="$TMPROOT/cli-criteria.json"

ptypes() { "$PY" -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps(d.get("productTypes")))' "$1"; }

check "a CLI-only mission records productTypes" \
  '[ -s "$CJ" ] && ptypes "$CJ" | grep -q cli'
check "every recorded product type names its SOURCE" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
ts=d.get(\"productTypes\") or []
assert ts, \"no productTypes\"
for t in ts:
    assert isinstance(t,dict), t
    assert t.get(\"type\"), t
    assert t.get(\"source\"), t
" "$CJ"'
check "a CLI-only mission records NO web product type" \
  '! ptypes "$CJ" | grep -q web'
check "every criterion carries a reachVia" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
cs=d.get(\"criteria\") or []
assert cs
missing=[c[\"id\"] for c in cs if not c.get(\"reachVia\")]
assert not missing, missing
" "$CJ"'
check "a CLI-only PRD yields NO browser rows" \
  '! "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(\" \".join(c.get(\"reachVia\",\"\") for c in d[\"criteria\"]))" "$CJ" | grep -q browser'
check "the CLI criteria are reached by RUNNING the CLI (reachVia cli)" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert any(c.get(\"reachVia\")==\"cli\" for c in d[\"criteria\"]), [c.get(\"reachVia\") for c in d[\"criteria\"]]" "$CJ"'

# A WEB mission: a drawing is present, so the page is a surface to look at.
WEBM="$TMPROOT/m-web"; mkdir -p "$WEBM"
cat >"$WEBM/prd.md" <<'MD'
# The shelf page

## Acceptance criteria
- The shelf page lists every published page with its version.
- The header shows the title of the shelf.
- Clicking `Open the draft` on the shelf opens the draft screen.
MD
cat >"$WEBM/plan.json" <<'JSON'
{"tickets": [
  {"id": "t1", "changesScreenAppearance": true,
   "entrypoints": [], "entrypointsNote": "no new CLI and no workflow",
   "seams": [], "seamsNote": "pure renderer",
   "acceptanceCriteria": [
     {"text": "the header shows the shelf title", "drawnAt": "shelf#header",
      "kind": "looks", "serves": "prd-2", "direction": "delivers"}]}
]}
JSON
# TWO screens, the second reachable only by clicking the first's forward control
# — the shape the browser walk needs (and the shape `main` already walks: the
# positive control for this fixture was taken against main's own xo-journey.py).
cat >"$WEBM/drawing.html" <<'HTML'
<html><body>
<div id="screen-shelf"><h1>The shelf</h1><button>Open the draft</button></div>
<div id="screen-draft"><h2>Draft</h2><textarea placeholder="Give the page a title…"></textarea>
<button>Publish</button></div>
</body></html>
HTML
cat >"$WEBM/state.json" <<'JSON'
{"id": "m-web", "title": "The shelf page", "stage": "verify", "branch": "feat/shelf"}
JSON
"$PY" "$CRITERIA" "$WEBM" "$TMPROOT/web-criteria.json" >/dev/null 2>&1
WJ="$TMPROOT/web-criteria.json"
check "a drawn mission records a web product type, with its source" \
  'ptypes "$WJ" | grep -q web'
check "a drawn criterion is reached through the browser" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert any(c.get(\"reachVia\")==\"browser\" for c in d[\"criteria\"]), [c.get(\"reachVia\") for c in d[\"criteria\"]]" "$WJ"'

# A WORKFLOW entrypoint is its own type.
WFM="$TMPROOT/m-wf"; mkdir -p "$WFM"
cat >"$WFM/prd.md" <<'MD'
# Publish on push

## Acceptance criteria
- Pushing to main publishes the site.
MD
cat >"$WFM/plan.json" <<'JSON'
{"tickets": [
  {"id": "t1", "changesScreenAppearance": false,
   "entrypoints": [{"kind": "workflow", "path": ".github/workflows/publish.yml",
                    "realRunTest": "tests/test_wf.py",
                    "realRunProof": "it runs the job's own run: strings"}],
   "seams": [], "seamsNote": "none",
   "acceptanceCriteria": [
     {"text": "the publish workflow runs every step it declares",
      "notVisual": true, "kind": "works", "serves": "prd-1",
      "direction": "delivers"}]}
]}
JSON
cat >"$WFM/state.json" <<'JSON'
{"id": "m-wf", "title": "Publish on push", "stage": "verify", "branch": "feat/wf"}
JSON
"$PY" "$CRITERIA" "$WFM" "$TMPROOT/wf-criteria.json" >/dev/null 2>&1
FJ="$TMPROOT/wf-criteria.json"
check "a workflow entrypoint records a workflow product type" \
  'ptypes "$FJ" | grep -q workflow'
check "the workflow criterion is reached by running the workflow" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert any(c.get(\"reachVia\")==\"workflow\" for c in d[\"criteria\"]), [c.get(\"reachVia\") for c in d[\"criteria\"]]" "$FJ"'

# ===========================================================================
# 2. THE WALK BEYOND THE BROWSER — declared steps from the checklists
# ===========================================================================
echo ""
echo "2. the browser walk is UNCHANGED, and declares no harness step"

# S247 — WHAT THIS SECTION USED TO ASSERT IS DELETED. It pinned the record-derived
# instantiation: a CLI-only journey emitting `--help`, a bad-input step, a
# workflow step naming the yml. All of that was a SECOND author of the step list
# the worker is now handed whole (S246), and the source of the "could not check"
# noise on every healthy look. What survives here is the half that was always
# right and is untouched by the deletion: `steps` is the browser contract with
# xo-drive.js, and no harness-executed kind may ever appear in it.
"$PY" "$JOURNEY" build --criteria "$CJ" --prd "$CLIM/prd.md" \
  --title "Notes" --out "$TMPROOT/cli-journey.json" >"$TMPROOT/cli-journey.out" 2>&1
CJO="$TMPROOT/cli-journey.json"

"$PY" "$JOURNEY" build --criteria "$WJ" --drawing-html "$WEBM/drawing.html" \
  --prd "$WEBM/prd.md" --title "The shelf" --out "$TMPROOT/web-journey.json" >/dev/null 2>&1
check "a web PRD still emits its click/type steps UNCHANGED" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
kinds={s.get(\"do\") for s in (d.get(\"steps\") or [])}
assert kinds & {\"click\",\"type\",\"gate\"}, kinds
assert not (kinds & {\"run\",\"workflow\",\"read\"}), kinds
" "$TMPROOT/web-journey.json"'
check "the browser steps list never carries a harness-executed kind" \
  '! "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(\" \".join(s.get(\"do\",\"\") for s in (d.get(\"steps\") or [])))" "$CJO" | grep -qE "run|workflow|read"'

# ===========================================================================
# 2b. xo-run.py EXECUTES them — detached worktree, throwaway HOME, caged
# ===========================================================================
echo ""
echo "2b. xo-run.py executes a run step in a detached worktree with a throwaway HOME"

# A REAL git repo with a REAL tiny CLI on a REAL branch. The layer under test is
# the execution of a declared step against a detached worktree, so the repo, the
# branch and the command are all real; only the mission's pipeline is not.
PROD="$TMPROOT/prod"; mkdir -p "$PROD"
git -C "$PROD" init -q -b main
cat >"$PROD/notes.py" <<'PYEOF'
import os, sys
args = sys.argv[1:]
if not args or args[0] in ("--help", "-h"):
    print("usage: notes [add|list]")
    sys.exit(0)
if args[0] == "add":
    if len(args) < 2 or not args[1].strip():
        sys.stderr.write("notes: add needs a title\n")
        sys.exit(2)
    print("stored %s under HOME=%s" % (args[1], os.environ.get("HOME", "?")))
    sys.exit(0)
sys.stderr.write("notes: no such subcommand %s\n" % args[0])
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
      - name: run the renderer as a file
        run: python3 pkg/render.py
YML
mkdir -p "$PROD/pkg"
printf 'from . import helper\n' >"$PROD/pkg/render.py"
printf '' >"$PROD/pkg/__init__.py"
printf 'X = 1\n' >"$PROD/pkg/helper.py"
printf 'the published page\n' >"$PROD/site.txt"
git -C "$PROD" add -A >/dev/null 2>&1
git -C "$PROD" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$PROD" branch -q feat/notes 2>/dev/null

SHOTS="$TMPROOT/shots/look-1"
cat >"$TMPROOT/run-journey.json" <<'JSON'
{"source": ["the cli checklist"], "steps": [], "reachSteps": [
  {"do": "run", "key": "r1", "for": "prd-2", "fromChecklist": "cli#1",
   "argv": ["python3", "notes.py", "--help"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "evidence": "01-help.txt",
   "expect": {"exit": 0, "stdoutIncludes": "usage: notes"}},
  {"do": "run", "key": "r2", "for": "prd-1", "fromChecklist": "cli#2",
   "argv": ["python3", "notes.py", "add", ""], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"},
   "evidence": "02-bad-input.txt",
   "expect": {"exitNonZero": true, "stderrIncludes": "needs a title"}},
  {"do": "read", "key": "r3", "for": "prd-3", "fromChecklist": "web#5",
   "path": "site.txt", "evidence": "05-artifact.txt",
   "expect": {"includes": "the published page"}}
]}
JSON
RUNOUT="$TMPROOT/xorun.out"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run \
  --journey "$TMPROOT/run-journey.json" --repo "$PROD" --branch feat/notes \
  --out "$SHOTS" --mission-dir "$CLIM" >"$RUNOUT" 2>&1
check "xo-run.py run TERMINATES (not caged out)" \
  '! grep -q "TIMED OUT" "$RUNOUT"'
check "it wrote a TRANSCRIPT for the --help step, under the shots dir" \
  '[ -s "$SHOTS/01-help.txt" ]'
check "the transcript holds the command and its exact output" \
  'grep -q -- "notes.py --help" "$SHOTS/01-help.txt" && grep -q "usage: notes" "$SHOTS/01-help.txt"'
check "it wrote a .json readout beside it, as the browser shots do" \
  '[ -s "$SHOTS/01-help.json" ]'
check "the readout records exit, stdout, stderr and the expect verdict" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
for k in (\"do\",\"exit\",\"stdout\",\"stderr\",\"expect\",\"met\",\"for\",\"checkedBy\"):
    assert k in d, (k, sorted(d))
assert d[\"exit\"]==0, d[\"exit\"]
assert d[\"met\"] is True, d
assert d[\"checkedBy\"]==\"cli\", d
" "$SHOTS/01-help.json"'
check "a bad-input step records a NON-zero exit and still counts as met" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"exit\"]!=0, d
assert d[\"met\"] is True, d
" "$SHOTS/02-bad-input.json"'
check "the step ran with the THROWAWAY HOME, not the captain's" \
  '! grep -q "HOME=$HOME" "$SHOTS/01-help.txt"'
check "the readout names the worktree and the throwaway HOME it used" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"worktree\"), d
assert d.get(\"home\"), d
assert d[\"home\"] != sys.argv[2], d
" "$SHOTS/01-help.json" "$HOME"'
check "a `read` step records the artifact's content" \
  '[ -s "$SHOTS/05-artifact.txt" ] && grep -q "the published page" "$SHOTS/05-artifact.txt" && "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"do\"]==\"read\", d
assert \"the published page\" in d.get(\"content\",\"\"), d
assert d[\"met\"] is True, d
" "$SHOTS/05-artifact.json"'
check "the run was against a DETACHED worktree, never the checked-out branch" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"worktree\"] != sys.argv[2], d
" "$SHOTS/01-help.json" "$PROD"'
check "the worktree is GONE at teardown" \
  '! git -C "$PROD" worktree list --porcelain | grep -q "lcars-ap-wt-"'
check "the summary it prints says how many steps it reached" \
  'grep -qiE "[0-9]+ (declared )?step" "$RUNOUT"'

# A STEP THAT TRIES TO LEAVE is REFUSED and journaled.
cat >"$TMPROOT/escape-journey.json" <<'JSON'
{"steps": [], "reachSteps": [
  {"do": "run", "key": "e1", "for": "prd-1", "fromChecklist": "cli#3",
   "argv": ["python3", "notes.py", "--help"], "cwd": "/etc",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "01-escape.txt",
   "expect": {"exit": 0}},
  {"do": "run", "key": "e2", "for": "prd-1", "fromChecklist": "cli#3",
   "argv": ["python3", "notes.py", "--help"], "cwd": "<worktree>",
   "env": {"HOME": "/Users/somebody-else"}, "evidence": "02-escape.txt",
   "expect": {"exit": 0}},
  {"do": "read", "key": "e3", "for": "prd-1", "fromChecklist": "web#5",
   "path": "../../../../etc/passwd", "evidence": "03-escape.txt",
   "expect": {"includes": "root"}}
]}
JSON
ESHOTS="$TMPROOT/shots/look-2"
: >"$CLIM/number-one.jsonl"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run \
  --journey "$TMPROOT/escape-journey.json" --repo "$PROD" --branch feat/notes \
  --out "$ESHOTS" --mission-dir "$CLIM" >"$TMPROOT/escape.out" 2>&1
check "a step whose cwd leaves the worktree is REFUSED" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"refused\") is True, d
assert d.get(\"why\"), d
" "$ESHOTS/01-escape.json"'
check "a step whose HOME leaves the throwaway HOME is REFUSED" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"refused\") is True, d" "$ESHOTS/02-escape.json"'
check "a read step whose path leaves the worktree is REFUSED" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"refused\") is True, d" "$ESHOTS/03-escape.json"'
check "a refusal is JOURNALED to number-one.jsonl, not just dropped" \
  'grep -q "step-refused" "$CLIM/number-one.jsonl"'
check "a refused step NEVER ran the command" \
  '! grep -q "usage: notes" "$ESHOTS/01-escape.txt" 2>/dev/null'
check "the escape run also left no worktree behind" \
  '! git -C "$PROD" worktree list --porcelain | grep -q "lcars-ap-wt-"'

# ===========================================================================
# 3. A WORKFLOW STEP'S EVIDENCE — the real runner, naming the first failure
# ===========================================================================
echo ""
echo "3. a workflow step's evidence is a workflow-run transcript"
cat >"$TMPROOT/wf-run-journey.json" <<'JSON'
{"steps": [], "reachSteps": [
  {"do": "workflow", "key": "w1", "for": "prd-1", "fromChecklist": "workflow#2",
   "file": ".github/workflows/publish.yml", "job": "build",
   "evidence": "02-workflow-run.txt",
   "expect": {"everyStepRuns": "no step fails"}}
]}
JSON
WSHOTS="$TMPROOT/shots/look-3"
"$PY" "$CAGE" 180 "$PY" "$XORUN" run \
  --journey "$TMPROOT/wf-run-journey.json" --repo "$PROD" --branch feat/notes \
  --out "$WSHOTS" --mission-dir "$CLIM" >"$TMPROOT/wf.out" 2>&1
check "the workflow step wrote a transcript" \
  '[ -s "$WSHOTS/02-workflow-run.txt" ]'
check "the transcript is a workflow-run transcript naming the FIRST failing step" \
  'grep -qi "render" "$WSHOTS/02-workflow-run.txt"'
check "the readout records checkedBy workflow and the failing step" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"do\"]==\"workflow\", d
assert d.get(\"checkedBy\")==\"workflow\", d
assert d.get(\"met\") is False, d
assert d.get(\"firstFailingStep\"), d
" "$WSHOTS/02-workflow-run.json"'

# ===========================================================================
# 3b. THE WORKER MAY ASK FOR MORE — under the SAME cap, inside the worktree
# ===========================================================================
echo ""
echo "3b. the worker's requested steps: one cap of 12 across ALL kinds"
"$PY" - "$TMPROOT/actions-many.json" <<'PYEOF'
import json, sys
acts = [{"do": "click", "match": ["Publish"]} for _ in range(6)]
acts += [{"do": "run", "argv": ["python3", "notes.py", "--help"],
          "cwd": "<worktree>", "evidence": "a%d.txt" % i,
          "for": "prd-1"} for i in range(9)]
json.dump({"actions": acts}, open(sys.argv[1], "w"))
PYEOF
"$PY" "$XORUN" actions --actions "$TMPROOT/actions-many.json" \
  --out "$TMPROOT/actions-kept.json" --mission-dir "$CLIM" \
  >"$TMPROOT/actions.out" 2>&1
check "the worker may request run steps at all" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert any(s.get(\"do\")==\"run\" for s in d[\"reachSteps\"]), d" "$TMPROOT/actions-kept.json"'
check "the cap of 12 holds ACROSS all kinds (15 asked, 12 kept)" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
n=len(d.get(\"steps\") or [])+len(d.get(\"reachSteps\") or [])
assert n==12, n
assert d.get(\"asked\")==15, d
assert d.get(\"cap\")==12, d" "$TMPROOT/actions-kept.json"'
cat >"$TMPROOT/actions-escape.json" <<'JSON'
{"actions": [{"do": "run", "argv": ["cat", "/etc/passwd"], "cwd": "/etc",
              "evidence": "x.txt", "for": "prd-1"}]}
JSON
: >"$CLIM/number-one.jsonl"
"$PY" "$XORUN" actions --actions "$TMPROOT/actions-escape.json" \
  --out "$TMPROOT/actions-escape-kept.json" --mission-dir "$CLIM" \
  >"$TMPROOT/actions-escape.out" 2>&1
check "a requested step outside the worktree is REFUSED, not kept" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert not (d.get(\"reachSteps\") or []), d" "$TMPROOT/actions-escape-kept.json"'
check "...and the refusal is JOURNALED" \
  'grep -q "action-refused" "$CLIM/number-one.jsonl"'

# ===========================================================================
# 4. RE-LOOK — `evaluate --again --because "<why>"`
# ===========================================================================
echo ""
echo "4. evaluate --again supersedes a finished verdict; plain evaluate does not"
REPO="$TMPROOT/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
MDIR="$REPO/.git/lcars/missions/lcars-20261002-001-abcd"; mkdir -p "$MDIR/xo"
cat >"$MDIR/state.json" <<'JSON'
{"id": "lcars-20261002-001-abcd", "title": "Notes", "stage": "verify",
 "branch": "feat/notes", "issue": 7,
 "numberOne": {"status": "finished", "evaluatedAt": "2026-10-01T10:00:00Z",
               "score": "low", "recommendation": "send back"}}
JSON
cp "$CLIM/prd.md" "$MDIR/prd.md"
cp "$CLIM/plan.json" "$MDIR/plan.json"
: >"$MDIR/number-one.jsonl"
cat >"$TMPROOT/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMPROOT/gh"
PLAIN="$TMPROOT/plain.out"
( cd "$REPO" && LCARS_GH_BIN="$TMPROOT/gh" LCARS_XO_DRIVE=1 \
  "$PY" "$CAGE" 90 bash "$XO" evaluate --mission lcars-20261002-001-abcd ) \
  >"$PLAIN" 2>&1
check "plain evaluate on a finished mission still says 'already looked'" \
  'grep -q "already looked" "$PLAIN"'
check "plain evaluate journals NOTHING new" \
  '! grep -q "superseded" "$MDIR/number-one.jsonl"'

NOBEC="$TMPROOT/nobecause.out"
( cd "$REPO" && LCARS_GH_BIN="$TMPROOT/gh" \
  "$PY" "$CAGE" 60 bash "$XO" evaluate --mission lcars-20261002-001-abcd --again ) \
  >"$NOBEC" 2>&1
check "--again with no --because is REFUSED (a supersession states its reason)" \
  'grep -qi "because" "$NOBEC"'

AGAIN="$TMPROOT/again.out"
( cd "$REPO" && LCARS_GH_BIN="$TMPROOT/gh" LCARS_XO_DRIVE=1 \
  LCARS_XO_LAUNCH_SCRIPT=/nonexistent \
  LCARS_WORKER_BIN="$NOOP_WORKER" LCARS_WORKER_CLI=copilot \
  "$PY" "$CAGE" 150 bash "$XO" evaluate --mission lcars-20261002-001-abcd \
    --again --because "the test runner is installed now" ) \
  >"$AGAIN" 2>&1
check "--again does NOT say 'already looked'" \
  '! grep -q "already looked" "$AGAIN"'
check "--again journals the supersession WITH the prior score and the reason" \
  'grep -q "superseded" "$MDIR/number-one.jsonl" && grep -q "the test runner is installed now" "$MDIR/number-one.jsonl" && grep -q "\"priorScore\": \"low\"" "$MDIR/number-one.jsonl"'
check "--again needs NO filed logs (the catch-22 is gone)" \
  '[ ! -f "$MDIR/xo/logs.json" ]'

# ───────────────────────────────────────────────────────────────────────────
# 4a. A SUPERSESSION THAT IS REFUSED MUST NOT BE ANNOUNCED (S240 fix round 5, D2)
# ───────────────────────────────────────────────────────────────────────────
# MEASURED: `evaluate --again --because "<why>"` printed
#   "the verdict of <ts> (low) is superseded: <reason>"
# and THEN refused the re-look — on a logged bug child, whose parent carries the
# build and which is never evaluated. The verdict was not in fact mutated; but a
# captain reading that top line has been told his low verdict was just replaced
# by a run that then did nothing. The supersession was also JOURNALED before the
# refusal, so the record carried it too.
#
# THE RULE: refuse first. Nothing announces or records a supersession until the
# re-look is actually going to happen.
CHILD="$REPO/.git/lcars/missions/lcars-20261002-009-abcd"; mkdir -p "$CHILD/xo"
cat >"$CHILD/state.json" <<'JSON'
{"id": "lcars-20261002-009-abcd", "title": "A logged bug", "stage": "verify",
 "branch": "feat/notes", "issue": 9, "parentMission": "lcars-20261002-001-abcd",
 "numberOne": {"status": "finished", "evaluatedAt": "2026-10-01T10:00:00Z",
               "score": "low", "recommendation": "send back"}}
JSON
: >"$CHILD/number-one.jsonl"
REFUSED="$TMPROOT/refused.out"
( cd "$REPO" && LCARS_GH_BIN="$TMPROOT/gh" LCARS_XO_DRIVE=1 \
  "$PY" "$CAGE" 60 bash "$XO" evaluate --mission lcars-20261002-009-abcd \
    --again --because "I want another look" ) >"$REFUSED" 2>&1
check "4a. CONTROL — the re-look on a bug child is still refused, and says why" \
  'grep -q "logged bug child" "$REFUSED"'
check "4a. it does NOT announce a supersession it then refuses to carry out" \
  '! grep -q "is superseded" "$REFUSED"'
check "4a. ...and does NOT record one in the mission journal it refused" \
  '! grep -q "superseded" "$CHILD/number-one.jsonl"'
check "4a. ...and the prior verdict is untouched, as it always was" \
  'grep -q "\"score\": \"low\"" "$CHILD/state.json" && grep -q "2026-10-01T10:00:00Z" "$CHILD/state.json"'

# ===========================================================================
# 4b. THE LOOK ITSELF REACHES — the tree is standing, the WORKER's steps run
# ===========================================================================
# S247 — THE WIRING CHANGED SHAPE, NOT PURPOSE. There used to be an
# `xo_run_reach` before the launch, executing the steps `xo-journey.py` had
# instantiated from the record. Nothing instantiates them any more: the tree is
# still prepared before the launch (a CLI needs no server up, and the first round
# must find it standing), and the steps arrive from the WORKER through
# `xo_reach_actions`, under the same cap, in that same tree.
echo ""
echo "4b. a real look prepares the tree before the launch and runs the worker's steps"
check "xo.sh calls xo-run.py for the steps it was asked for" \
  'grep -q "xo_run_reach" "$XO" && grep -q "xo-run.py" "$XO"'
check "the look's tree and HOME are minted BEFORE the launch" \
  '"$PY" -c "
import sys
t=open(sys.argv[1]).read()
i=t.index(\"  xo_reach_prepare \\\"\$dir\\\"\")
j=t.index(\"--- 2. LAUNCH\")
assert i<j, (i,j)
" "$XO"'
# CODE ONLY, NOT THE PROSE ABOUT IT. The comment on that line NAMES the call it
# replaced, so a whole-text grep can never go green; the probe reads the
# statements. Proved able to fail by the control below.
cat >"$TMPROOT/prelaunch.py" <<'PLEOF'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
head = t[t.index('xo_build_journey "$dir"'):t.index("--- 2. LAUNCH")]
code = [l for l in head.splitlines() if not l.lstrip().startswith("#")]
hits = [l.strip() for l in code if "xo_run_reach" in l]
print(";".join(hits) if hits else "none")
PLEOF
check "NOTHING runs a step before the launch any more (the templater's slot is empty)" \
  '[ "$("$PY" "$TMPROOT/prelaunch.py" "$XO")" = none ]'
cat >"$TMPROOT/replant.py" <<'RPEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src, encoding="utf-8").read()
line = '  xo_reach_prepare "$dir"\n'
assert line in t, "the prepare call has moved — this control has drifted"
open(dst, "w", encoding="utf-8").write(
    t.replace(line, line + '  xo_run_reach "$dir" "$xodir" "$shots"\n', 1))
RPEOF
check "…and that probe can FAIL (the same reader, on a copy that still calls it)" \
  '"$PY" "$TMPROOT/replant.py" "$XO" "$TMPROOT/xo-prelaunch.sh" &&
   [ "$("$PY" "$TMPROOT/prelaunch.py" "$TMPROOT/xo-prelaunch.sh")" != none ]'
check "the worker's requested steps go through the same cap and worktree" \
  'grep -q "xo_reach_actions" "$XO"'
check "…and are RECORDED on the journey as what the harness granted" \
  '"$PY" -c "
import sys
t=open(sys.argv[1]).read()
i=t.index(\"xo_reach_actions() {\")
assert \"reach-record\" in t[i:i+1400], t[i:i+1400]
" "$XO"'
check "the reach journals what it reached, so the report can read it" \
  'grep -q "journal \"\$dir\" reached" "$XO"'
check "a mission with no branch is told so, never run against the checkout" \
  'grep -q "reach-refused" "$XO"'
MJ="$MDIR/xo/journey.json"
check "the look wrote a journey whose reachSteps is the harness's EMPTY log" \
  '[ -s "$MJ" ] && "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"reachSteps\") == [], d.get(\"reachSteps\")
assert \"reachUninstantiated\" not in d, sorted(d)
" "$MJ"'
check "...and nothing in the record was ever announced as a declared step" \
  '! grep -q "declared step(s) I could not run" "$AGAIN"'

# ===========================================================================
# 5. APPROVE UNBLOCKED — a finished verdict is one line, not a refusal
# ===========================================================================
echo ""
echo "5. a finished verdict never blocks approve; a LIVE look still does"
LOCKDIR="$TMPROOT/lockm"; mkdir -p "$LOCKDIR"
cat >"$LOCKDIR/state.json" <<'JSON'
{"id": "lockm", "numberOne": {"status": "engaged", "evaluatedAt": "2026-10-01T10:00:00Z",
 "score": "medium", "recommendation": "merge it"}}
JSON
lockrc() { # <mission-dir> → prints "rc=<n> line=<...>"
  ( set +e
    . "$OWNERSHIP" >/dev/null 2>&1
    out="$(lcars_xo_lock_reason "$1" 2>/dev/null)"; rc=$?
    printf 'rc=%s line=%s\n' "$rc" "$out" )
}
verdline() {
  ( set +e
    . "$OWNERSHIP" >/dev/null 2>&1
    lcars_xo_verdict_line "$1" 2>/dev/null )
}
livelook() { # <mission-dir> → rc of lcars_xo_live_look
  ( set +e
    . "$OWNERSHIP" >/dev/null 2>&1
    lcars_xo_live_look "$1" >/dev/null 2>&1; printf 'rc=%s\n' "$?" )
}
# THE SHARED LOCK IS NOT TOUCHED. S201's sentence is what log / pause / respond
# / feedback / resolve-logs still get for an engaged mission, and
# tests/ownership.test.sh asserts it verbatim. `approve` alone asks the narrower
# question the ruling was about, so that is what is asserted here.
check "the shared S201 lock still refuses an engaged mission (UNCHANGED)" \
  'lockrc "$LOCKDIR" | grep -q "^rc=0 line=.*[A-Za-z]"'
check "...and still names the remedy (xo off)" \
  'lockrc "$LOCKDIR" | grep -q "xo off"'
check "with NO xo.pid, no look is alive (so approve proceeds)" \
  '[ "$(livelook "$LOCKDIR")" = "rc=1" ]'
printf '%s\n' "$$" >"$LOCKDIR/xo.pid"
check "with a LIVE xo.pid a look IS alive (so approve still refuses)" \
  '[ "$(livelook "$LOCKDIR")" = "rc=0" ]'
printf '%s\n' "999999" >"$LOCKDIR/xo.pid"
check "a STALE xo.pid (dead process) is not a live look — a crash does not lock him out" \
  '[ "$(livelook "$LOCKDIR")" = "rc=1" ]'
rm -f "$LOCKDIR/xo.pid"
check "approve asks the NARROW question, not the broad one" \
  'grep -q "lcars_xo_live_look" "$REPO_ROOT/skills/lcars-approve/approve.sh"'
check "no OTHER write verb was narrowed with it" \
  '! grep -l "lcars_xo_live_look" "$REPO_ROOT/skills/lcars-log/log.sh" "$REPO_ROOT/skills/lcars-pause/pause.sh" "$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh" 2>/dev/null | grep -q .'
check "a finished verdict gives approve ONE line to print" \
  'verdline "$LOCKDIR" | grep -q "Number One.s verdict"'
check "that line carries the recommendation (or the grade) and the when" \
  'verdline "$LOCKDIR" | grep -q "merge it" && verdline "$LOCKDIR" | grep -q "2026-10-01"'
check "approve.sh PRINTS that line instead of dying on a finished verdict" \
  'grep -q "lcars_xo_verdict_line" "$REPO_ROOT/skills/lcars-approve/approve.sh"'

# ===========================================================================
# 5b (item 5 of the brief). THE TEST TIMEOUT — suite-timing.json, else the env
# ===========================================================================
echo ""
echo "5b. the test timeout reads suite-timing.json if present, else the env var"
TTREPO="$TMPROOT/ttrepo"; mkdir -p "$TTREPO"
git -C "$TTREPO" init -q -b main
mkdir -p "$TTREPO/.git/lcars"
check "with no suite-timing.json it is the env var" \
  '[ "$( cd "$TTREPO" && LCARS_XO_TEST_TIMEOUT=321 bash "$XO" test-timeout )" = 321 ]'
printf '{"testTimeout": 900}\n' >"$TTREPO/.git/lcars/suite-timing.json"
check "with suite-timing.json its recorded seconds win" \
  '[ "$( cd "$TTREPO" && LCARS_XO_TEST_TIMEOUT=321 bash "$XO" test-timeout )" = 900 ]'
printf '{"nonsense": true}\n' >"$TTREPO/.git/lcars/suite-timing.json"
check "a suite-timing.json with no timing in it falls back, never to 0" \
  '[ "$( cd "$TTREPO" && LCARS_XO_TEST_TIMEOUT=321 bash "$XO" test-timeout )" = 321 ]'
check "the honest wording is kept — the look SAYS it stopped the tests" \
  'grep -q "still running after" "$XO"'

# ===========================================================================
# 6. THE PROMPT CONTRACT
# ===========================================================================
echo ""
echo "6. evaluate.md teaches the new step kinds and keeps the honesty rules"
check "evaluate.md names the three harness-executed step kinds" \
  'grep -qi "run" "$EVALUATE_MD" && grep -q "workflow" "$EVALUATE_MD" && grep -qi "read" "$EVALUATE_MD"'
check "it says the HARNESS runs them and the worker has no shell" \
  'grep -qi "no shell" "$EVALUATE_MD"'
check "it names the live-check checklist as where the steps come from" \
  'grep -qi "live-check" "$EVALUATE_MD"'
check "it teaches checkedBy on every ledger row" \
  'grep -q "checkedBy" "$EVALUATE_MD"'
check "the contract-first rule is kept VERBATIM" \
  'grep -qi "before" "$EVALUATE_MD" && grep -qi "criteri" "$EVALUATE_MD"'
check "the honesty rule is kept — untested is not a failure" \
  'grep -qi "untested" "$EVALUATE_MD"'
check "every checklist item's run/workflow/read template still parses as JSON" \
  '"$PY" - "$LIVE_CHECK" <<'"'"'PYEOF'"'"'
import glob, json, os, re, sys
d = sys.argv[1]
n = 0
for p in sorted(glob.glob(os.path.join(d, "*.md"))):
    for kind, body in re.findall(r"```(run|workflow|read):\n(.*?)```", open(p).read(), re.S):
        json.loads(body)
        n += 1
assert n >= 8, n
PYEOF'

# ===========================================================================
# 7. THE LEDGER ROW NAMES ITS INSTRUMENT (fix round 1, D1 and D5)
# ===========================================================================
# S247 — D2 IS DELETED WITH THE MECHANISM IT GUARDED. D2 was "the declared CLI
# steps ran the wrong subcommand": `<subcommand>` and `<the-main-verb>` were both
# filled with whichever verb the record named first, so a record naming its
# LISTING verb first fed bad input to a command that takes none and the console
# printed `FAILED 02-bad-input.txt` about working software. Nothing instantiates a
# step from the record any more, so the bug and its guard both go.
#
# D1 STAYS, AND IS NOT ABOUT THE TEMPLATER. `checkedBy` is produced on every step
# readout and the prompt teaches it, but the verdict SCHEMA the worker copies
# never named it and the scorer never carried it — so it was present on 0 of 15
# rows while `evidence` read `picture` on 15 of 15, including a row whose only
# shot was `01-help.txt`, a terminal transcript. Identically on BOTH engines,
# which is what makes it a schema fault and not a model fault. D5 stays too: the
# driver must hand a harness kind OVER, not log it as an action it skipped.
echo ""
echo "7. the ledger row names its instrument, and the driver hands reach over"

# --- D1: checkedBy, and an evidence word a transcript can honestly use -------
cat >"$TMPROOT/schema.py" <<'PYEOF'
# The ONE block the worker copies: the fenced JSON that carries `"score"` and
# `"criteria"`. Prose elsewhere in the file is not what gets copied, which is
# the whole point of this check.
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
blocks = [b for b in re.findall(r"```json\n(.*?)```", text, re.S)
          if '"score"' in b and '"criteria"' in b]
assert blocks, "no verdict schema block found at all"
block = blocks[0]
want = sys.argv[2]
if want == "checkedBy":
    assert "checkedBy" in block, block
elif want == "transcript":
    m = re.search(r'"evidence":\s*"([^"]+)"', block)
    assert m, block
    words = m.group(1).split("|")
    assert "transcript" in words, words
print("ok")
PYEOF
check "D1. the verdict SCHEMA the worker copies names checkedBy (not only the prose)" \
  '[ "$("$PY" "$TMPROOT/schema.py" "$EVALUATE_MD" checkedBy)" = ok ]'
check "D1. …and its evidence words include one a TRANSCRIPT can honestly claim" \
  '[ "$("$PY" "$TMPROOT/schema.py" "$EVALUATE_MD" transcript)" = ok ]'

SCOREPY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
SDIR="$TMPROOT/score"; mkdir -p "$SDIR"
cat >"$SDIR/criteria.json" <<'CJ'
{"hasDrawing": true, "placeNames": [], "criteria": [
  {"id": "prd-1", "text": "the help lists every subcommand", "primary": true},
  {"id": "prd-2", "text": "the board shows the list", "primary": false}
]}
CJ
cat >"$SDIR/in.json" <<'IJ'
{"score":"medium","summary":"Looked at the relay.","criteria":[
 {"id":"prd-1","text":"the help lists every subcommand","status":"met",
  "shot":"01-help.txt","evidence":"transcript","checkedBy":"cli",
  "note":"the transcript lists all three subcommands",
  "action":"Ran relay.py --help and read the transcript.",
  "reason":"Impact high because it is the front door. I tried --help; I saw all three (evidence: 01-help.txt). Outcome: met."},
 {"id":"prd-2","text":"the board shows the list","status":"met","shot":"shot-02",
  "evidence":"picture","checkedBy":"browser","note":"saw the list",
  "action":"Looked at the board.",
  "reason":"Impact medium because it is the main screen. I tried looking; I saw the list (evidence: shot-02). Outcome: met."}],
 "gaps":[],"alsoChecked":[],"escalations":[]}
IJ
"$PY" "$SCOREPY" "$SDIR/in.json" "$SDIR/criteria.json" "$SDIR/verdict.json" \
  >"$SDIR/out.tsv" 2>"$SDIR/err.txt"
cat >"$TMPROOT/row.py" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d.get("criteria") or []:
    if e.get("id") == sys.argv[2]:
        print(str(e.get(sys.argv[3], "<absent>")))
        break
else:
    print("<no-such-row>")
PYEOF
ROW="$TMPROOT/row.py"
check "D1. the verdict the captain reads carries checkedBy on the row" \
  '[ "$("$PY" "$ROW" "$SDIR/verdict.json" prd-1 checkedBy)" = cli ]'
check "D1. a transcript-backed row is NOT restamped as a picture" \
  '[ "$("$PY" "$ROW" "$SDIR/verdict.json" prd-1 evidence)" = transcript ]'
check "D1. …and it still stands as met, cited by its transcript filename" \
  '[ "$("$PY" "$ROW" "$SDIR/verdict.json" prd-1 status)" = met ] &&
   [ "$("$PY" "$ROW" "$SDIR/verdict.json" prd-1 shot)" = 01-help.txt ]'
check "D1. positive control — a row that WAS a picture still reads picture, checked by browser" \
  '[ "$("$PY" "$ROW" "$SDIR/verdict.json" prd-2 evidence)" = picture ] &&
   [ "$("$PY" "$ROW" "$SDIR/verdict.json" prd-2 checkedBy)" = browser ]'
check "D1. the report no longer says it SAW on screen what it read in a terminal" \
  '! grep -q "I saw each one on screen" "$SDIR/out.tsv" &&
   ! grep -q "I have a picture of each one" "$SDIR/out.tsv"'
check "D1. …it says what it ran, and counts it apart from what it looked at" \
  'grep -qi "read the transcript" "$SDIR/out.tsv"'
# An instrument word nobody recognises is DROPPED, never defaulted — the same
# rule `kind` already has. A guessed instrument is the fault this cures.
cat >"$SDIR/in-bogus.json" <<'IJ'
{"score":"medium","summary":"Looked.","criteria":[
 {"id":"prd-1","text":"the help lists every subcommand","status":"met",
  "shot":"01-help.txt","evidence":"transcript","checkedBy":"vibes","note":"ok",
  "action":"Ran it."},
 {"id":"prd-2","text":"the board shows the list","status":"met","shot":"shot-02",
  "evidence":"picture","note":"saw it","action":"Looked."}],
 "gaps":[],"alsoChecked":[],"escalations":[]}
IJ
"$PY" "$SCOREPY" "$SDIR/in-bogus.json" "$SDIR/criteria.json" "$SDIR/bogus.json" \
  >"$SDIR/bogus.tsv" 2>&1
check "D1. an unrecognised instrument word is dropped, not defaulted" \
  '[ "$("$PY" "$ROW" "$SDIR/bogus.json" prd-1 checkedBy)" = "<absent>" ]'
check "D1. …and a row that declared none carries none" \
  '[ "$("$PY" "$ROW" "$SDIR/bogus.json" prd-2 checkedBy)" = "<absent>" ]'

# --- D5: the browser driver must not journal a HARNESS step as dropped ------
# `xo_reach_actions` runs every `run`/`workflow`/`read` the worker asked for —
# and the same actions file goes to the driver, which journaled one
# "unknown action, skipped: {...}" per step and set `incomplete`. The WORKER
# READS THOSE NOTES, so a false "skipped" is misinformation in its input.
DRIVE="$REPO_ROOT/skills/lcars-xo/xo-drive.js"
check "D5. the driver says a harness step was HANDED OVER, not skipped" \
  'grep -q "handed to the harness" "$DRIVE"'
check "D5. …and does not call a harness step an unknown action it skipped" \
  '"$PY" - "$DRIVE" <<'"'"'PYEOF'"'"'
import sys
Q = chr(34)
src = open(sys.argv[1], encoding="utf-8").read()
# The FALLBACK itself, not the comment above it that quotes what it used to say
# about a harness step.
i = src.index("notes.push(" + Q + "unknown action, skipped")
# The branch that answers a harness kind must be REACHED FIRST: it sits above
# the fallback that calls an action unknown. And what it journals must neither
# claim the step was dropped nor mark the walk incomplete.
head = src[:i]
j = head.rfind("a.do === " + Q + "run" + Q)
assert j >= 0, "the fallback is reached with no branch that recognises a harness kind"
for kind in ("run", "workflow", "read"):
    assert Q + kind + Q in head[j:], kind
branch = head[j:]
assert "handed to the harness" in branch, branch[:400]
assert "incomplete = true" not in branch, branch[:400]
print("ok")
PYEOF'
NODEBIN="${LCARS_NODE_BIN:-node}"
check "D5. …and the driver is still valid JavaScript" \
  'command -v "$NODEBIN" >/dev/null 2>&1 && "$NODEBIN" --check "$DRIVE" >/dev/null 2>&1'

# ===========================================================================
# 8 + 9 — FIX ROUNDS 2 AND 3, DELETED WITH THEIR MECHANISM (S247)
# ===========================================================================
# Section 8 pinned "a silent record is REFUSED, never guessed": where the record
# did not say which subcommand takes the input, the item joined
# `reachUninstantiated` instead of being built from a guess. Section 9 pinned the
# DELIVERY of those refusals — the console naming the items a one-line record
# edit recovers, `report.md` repeating them, and the by-design items (`cli#4-8`,
# `web#4-6`) kept quiet so the alarm did not fire on every healthy mission.
#
# Both guarded a mechanism that no longer exists. The worker is handed the
# checklists WHOLE and chooses its own steps (S246), so there is no instantiation
# to refuse and no refusal to deliver — and the "could not check" noise those two
# sections carefully managed is gone at its source rather than managed. What the
# captain reads under *What I could not check* is now the blind ledger rows and
# the look's OWN `couldNot` entries, and nothing else; the S247 section below
# proves the two sentences cannot reach a report even from a record that still
# carries the old field.

# ===========================================================================
# S247 — THE TEMPLATER IS DELETED; THE WORKER IS THE ONE AUTHOR OF THE LIST
# ===========================================================================
# WHY (measured, not a hunch). S246 handed the live-check checklists to the
# worker WHOLE and it chose its own steps — 9 unprompted on Copilot, 24 across
# three rounds on Claude, which found all four planted bugs and one nobody
# planted. The record-derived instantiation in `xo-journey.py` was therefore a
# SECOND author of the same list, and a bad one: it can fill `realistic-value`
# and `subcommand` and nothing else, so `cli#4-8` and `web#4-6` went unbuilt on
# EVERY healthy mission "by design" — and the captain read that refusal on every
# single look. S212's scar says a guard that fires every time is a guard nobody
# reads. So the mechanism goes, and with it the two sentences it generated.
#
# THE DELETION IS THE TEST. Every check below either asserts a removed symbol is
# gone, or asserts the replacement carries the load on REAL recorded evidence —
# the six archived looks of the Kelmoor mission, replayed through this scorer
# from a COPY (the archive is never written to).
echo ""
echo "S247-1. no symbol of the record-derived templater survives"

SCOREPY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
XOSH="$REPO_ROOT/skills/lcars-xo/xo.sh"
XOSKILL="$REPO_ROOT/skills/lcars-xo/SKILL.md"

check "S247-1a. xo-journey.py defines no reach_steps" \
  '! grep -q "reach_steps" "$JOURNEY"'
check "S247-1b. xo-journey.py defines no checklist_items" \
  '! grep -q "checklist_items" "$JOURNEY"'
check "S247-1c. xo-journey.py carries no live-check fence regex" \
  '! grep -q "_FENCE" "$JOURNEY" && ! grep -q "LIVE_CHECK_DIR" "$JOURNEY"'
check "S247-1d. no oneLineFix in journey, run or score" \
  '! grep -q "oneLineFix" "$JOURNEY" "$XORUN" "$SCOREPY"'
check "S247-1e. no reachUninstantiated in journey, run or score" \
  '! grep -q "reachUninstantiated" "$JOURNEY" "$XORUN" "$SCOREPY"'
check "S247-1f. xo-run.py has no unbuilt / BY_DESIGN / say_unbuilt" \
  '! grep -qE "BY_DESIGN|say_unbuilt|def unbuilt" "$XORUN"'
check "S247-1g. xo-score.py has no load_unbuilt / unbuilt_lines" \
  '! grep -qE "load_unbuilt|unbuilt_lines" "$SCOREPY"'
check "S247-1h. the LCARS_XO_TEMPLATER switch is gone from every skill file" \
  '! grep -rq "LCARS_XO_TEMPLATER" "$REPO_ROOT/skills"'
# THE LONGEST CONTIGUOUS FRAGMENT, NOT THE WHOLE SENTENCE (S247 fix round, D2).
# This check used to grep for "unbuilt on every healthy mission", and could never
# match: in the deleted source that sentence was assembled by Python string
# concatenation and SPLIT mid-phrase — `"…go unbuilt on every healthy "` on one
# line, `"mission, by design…"` on the next — so no byte run spelling the whole
# sentence ever existed on disk, and the check passed against the PRE-deletion
# tree exactly as happily as against this one. Collapsing newlines does not help:
# what sits between "healthy" and "mission" is `" "`, not a line break. So it
# greps the longest run the source really contained. Measured: that run appears
# EXACTLY ONCE in the pre-deletion tree (xo-run.py, the forbidden sentence
# itself) and nowhere in this one — while the four other "unbuilt on every…"
# comments in the tree do not contain it. S247-1i2 is the mutation.
check "S247-1i. no by-design sentence survives anywhere in the skill" \
  '! grep -rq "unbuilt on every healthy" "$REPO_ROOT/skills"'
check "S247-1i2. MUTATION — split as the deleted source split it, the old grep missed it and this one does not" \
  'rm -rf "$TMPROOT/wrap"; mkdir -p "$TMPROOT/wrap/yes" "$TMPROOT/wrap/no";
   printf "%s\n%s\n" "    \"an artifact nobody named. Those go unbuilt on every healthy \"" "    \"mission, by design; there is nothing to fix.)\")" \
     >"$TMPROOT/wrap/yes/planted.py";
   printf "%s\n" "# the roster went unbuilt on every mission ever looked at" \
     >"$TMPROOT/wrap/no/decoy.py";
   ! grep -rq "unbuilt on every healthy mission" "$TMPROOT/wrap/yes" &&
     grep -rq "unbuilt on every healthy" "$TMPROOT/wrap/yes" &&
   ! grep -rq "unbuilt on every healthy" "$TMPROOT/wrap/no"'
check "S247-1j. no one-line-in-your-record sentence survives either" \
  '! grep -rq "one line in your record" "$REPO_ROOT/skills"'
check "S247-1k. SKILL.md no longer documents the instantiation or its refusals" \
  '! grep -qE "reachUninstantiated|oneLineFix" "$XOSKILL"'
check "S247-1l. SKILL.md says the checklists are ADVICE the worker reads" \
  'tr "\n" " " <"$XOSKILL" | tr -s " " | grep -q "advice the worker reads"'
check "S247-1m. the live-check README says so too" \
  'tr "\n" " " <"$LIVE_CHECK/README.md" | tr -s " " | grep -q "advice the worker reads"'

# A CLI-only record declares NOTHING of its own any more: one author, and it is
# not this file. The journey still carries the key, as an empty list — a reader
# must never have to guess whether a look predates the change.
"$PY" "$JOURNEY" build --criteria "$CJ" --prd "$CLIM/prd.md" \
  --title "Notes" --out "$TMPROOT/s247-cli-journey.json" >/dev/null 2>&1
check "S247-1n. a CLI-only journey instantiates NO reach step from the record" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"reachSteps\") == [], d.get(\"reachSteps\")
assert \"reachUninstantiated\" not in d, sorted(d)
" "$TMPROOT/s247-cli-journey.json"'
check "S247-1o. …and its BROWSER steps and coverage are untouched keys" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert \"steps\" in d and \"coverage\" in d, sorted(d)
" "$TMPROOT/s247-cli-journey.json"'

# ===========================================================================
# S247-2. the two templater sentences cannot reach a report, EVEN FROM A RECORD
#         THAT STILL CARRIES THE OLD FIELD
# ===========================================================================
# THE MUTATION THAT PROVES THIS FIRES. An archived journey with
# `reachUninstantiated` planted on it — two items flagged `oneLineFix`, two not
# — rendered BOTH sentences on the pre-S247 scorer (measured: "one line in your
# record" 1, "unbuilt on every healthy mission" 1). A record on disk from before
# the deletion is exactly that input, so the field being ignored is the check.
echo ""
echo "S247-2. a record still carrying reachUninstantiated renders neither sentence"

MEASURE_SRC="/Users/roganferguson/Projects/lcars-dev/tests/drives/s241/measure"
MEASURE="$TMPROOT/measure"
cp -R "$MEASURE_SRC" "$MEASURE"

score_look() { # <look-dir> <out-dir>
  local d="$1" o="$2"
  mkdir -p "$o"
  "$PY" "$CAGE" 300 "$PY" "$SCOREPY" "$d/verdict.json" "$d/criteria.json" \
    "$o/verdict.json" "$d/observations.json" "$d/tests.json" "$d/impacts.json" \
    "$d/pairs.json" "$d/walk.json" "$d/seed.json" "$d/unlisted.json" \
    "$d/readings.json" "$d/decisions.json" "$d/journey.json" "$d/shots" \
    >"$o/wire.txt" 2>"$o/err.txt"
}

UNB="$TMPROOT/unbuilt-record"; cp -R "$MEASURE/xo-look-1" "$UNB"
"$PY" - "$UNB/journey.json" <<'PLANT'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["reachUninstantiated"] = [
    {"item": "cli#2", "evidence": "02-bad-input.txt", "oneLineFix": True,
     "why": "the record never says which subcommand TAKES the input"},
    {"item": "cli#3", "evidence": "03-happy.txt", "oneLineFix": True,
     "why": "the record never says which subcommand TAKES the input"},
    {"item": "web#4", "evidence": "04-render.txt", "oneLineFix": False,
     "why": "the record does not name the rendered page or deployed artifact"},
    {"item": "web#5", "evidence": "05-deploy.txt", "oneLineFix": False,
     "why": "the record does not name the rendered page or deployed artifact"}]
json.dump(d, open(p, "w"), indent=1)
PLANT
score_look "$UNB" "$TMPROOT/unb-out"
check "S247-2a. the planted record still scored (the probe is not vacuous)" \
  '[ -s "$TMPROOT/unb-out/report.md" ]'
check "S247-2b. …and the report says nothing about a one-line record edit" \
  '! grep -q "one line in your record" "$TMPROOT/unb-out/report.md"'
check "S247-2c. …nor that items go unbuilt on every healthy mission" \
  '! grep -q "every healthy mission" "$TMPROOT/unb-out/report.md"'
check "S247-2d. …and it still has a What-I-could-not-check section (nothing else lost)" \
  'grep -q "What I could not check" "$TMPROOT/unb-out/report.md"'

# ===========================================================================
# S247-3. THE SIX ARCHIVED LOOKS, REPLAYED — the part rows say what their
#         picture proves, the disclosure terminates, and no grade word moves
# ===========================================================================
echo ""
echo "S247-3. the six archived looks replayed through this scorer"

LOOKS="xo-look-1 xo-look-2 xo-look-3 xo-restyle-1 xo-restyle-2 xo-restyle-3"
for look in $LOOKS; do
  score_look "$MEASURE/$look" "$TMPROOT/replay/$look"
done
check "S247-3a. all six looks scored" \
  'n=0; for look in $LOOKS; do [ -s "$TMPROOT/replay/$look/report.md" ] && n=$((n+1)); done;
   [ "$n" = 6 ]'

# The reader for every claim below. One file, so an assertion reads as a claim.
cat >"$TMPROOT/s247probe.py" <<'PROBEEOF'
import json, os, re, sys

what, replay, measure = sys.argv[1], sys.argv[2], sys.argv[3]
LOOKS = ("xo-look-1", "xo-look-2", "xo-look-3",
         "xo-restyle-1", "xo-restyle-2", "xo-restyle-3")
MARK = "I did not check this picture is of the right screen"


def rows(look):
    return [l for l in open(os.path.join(replay, look, "report.md"),
                            encoding="utf-8").read().splitlines()
            if l.startswith("| ")]


def verdict(look):
    return json.load(open(os.path.join(replay, look, "verdict.json"),
                          encoding="utf-8"))


def parts(look):
    """the criteria the PLANNER recorded as a drawn part — a recorded field,
    never an id's spelling and never a filename."""
    doc = json.load(open(os.path.join(measure, look, "criteria.json"),
                         encoding="utf-8"))
    return {str(c.get("id")): str(c.get("drawnPart") or "")
            for c in (doc.get("criteria") or [])
            if str(c.get("drawnPart") or "").strip()}


def cited_part_rows(look):
    """(cid, part, ledger row) for every part criterion that CITES a shot."""
    pr = parts(look)
    for e in (verdict(look).get("criteria") or []):
        cid = str(e.get("id") or "")
        if cid in pr and str(e.get("shot") or "").strip():
            yield cid, pr[cid], e


if what == "no-templater-prose":
    hits = []
    for look in LOOKS:
        for l in rows(look):
            if "by design" in l or "one line in your record" in l:
                hits.append((look, l[:90]))
    assert not hits, hits

elif what == "part-rows-positive":
    n = 0
    bad = []
    for look in LOOKS:
        for cid, part, e in cited_part_rows(look):
            n += 1
            cell = [l for l in rows(look) if l.startswith("| " + cid + " ")]
            assert cell, (look, cid)
            if "laid out at" not in cell[0]:
                bad.append((look, cid, cell[0][:160]))
    assert n == 35, n
    assert not bad, bad[:4]

elif what == "part-rows-recorded":
    # the sentence is COMPOSED ONCE in the scoring pass and recorded on the
    # row, so report.md reads it rather than re-deriving it.
    n = 0
    for look in LOOKS:
        for cid, part, e in cited_part_rows(look):
            lan = e.get("landing") or {}
            assert lan.get("partPlaced") is True, (look, cid, lan)
            assert part in str(lan.get("reason") or ""), (look, cid, lan)
            n += 1
    assert n == 35, n

elif what == "no-bare-part-met":
    bad = []
    for look in LOOKS:
        for cid, part, e in cited_part_rows(look):
            cell = [l for l in rows(look) if l.startswith("| " + cid + " ")][0]
            cols = [c.strip() for c in cell.strip("|").split("|")]
            if cols[2] == "MET" and "laid out at" not in cols[4]:
                bad.append((look, cid, cols[4][:120]))
    assert not bad, bad[:4]

elif what == "disclosures-terminate":
    bad = []
    seen = 0
    for look in LOOKS:
        for l in rows(look):
            i = l.find(MARK)
            if i <= 0:
                continue
            seen += 1
            before = l[:i].rstrip()
            if before and before[-1] not in ".…!?—;":
                bad.append((look, l[max(0, i - 70):i + 20]))
    assert seen >= 10, seen
    assert not bad, bad[:4]

elif what == "landing-reason-carries-clause":
    n = 0
    for look in LOOKS:
        for e in (verdict(look).get("criteria") or []):
            lan = e.get("landing") or {}
            if not lan.get("unplaced"):
                continue
            n += 1
            assert MARK in str(lan.get("reason") or ""), (look, e.get("id"), lan)
    assert n >= 10, n

elif what == "readouts-separate":
    # A TRUNCATION ELLIPSIS IS NOT A FULL STOP (S247 fix round, D1). `clip`
    # ends a shortened note with "…", which says the sentence was CUT off,
    # not that it ended — so the positive readout clause appended after one
    # must still be separated by a dash, exactly as it is after any other
    # unterminated note. Counted per OCCURRENCE on the raw cell, because a
    # line-counting grep would see one hit per row and miss the rest.
    seen = 0
    bad = []
    for look in LOOKS:
        for l in rows(look):
            for m in re.finditer(r"the picture shows ", l):
                seen += 1
                pre = l[:m.start()]
                if pre.endswith(" — "):
                    continue          # the separator did its job
                head = pre.rstrip()
                if not head or head.endswith("|"):
                    continue          # the clause IS the whole cell
                if head[-1] not in ".!?;":
                    bad.append((look, head[-60:]))
    assert seen == 35, seen
    assert not bad, bad[:4]

elif what == "grades":
    print(json.dumps([[look, verdict(look).get("score"),
                       verdict(look).get("recommendation"),
                       {k: (g or {}).get("grade")
                        for k, g in (verdict(look).get("groups") or {}).items()},
                       verdict(look).get("counts")] for look in LOOKS],
                     sort_keys=True))

else:
    raise SystemExit("unknown probe %s" % what)
print("ok")
PROBEEOF

probe() { "$PY" "$TMPROOT/s247probe.py" "$1" "$TMPROOT/replay" "$MEASURE"; }

check "S247-3b. no replayed row says 'by design' or 'one line in your record'" \
  '[ "$(probe no-templater-prose)" = ok ]'
check "S247-3c. all 35 part rows that cite a shot read the POSITIVE statement" \
  '[ "$(probe part-rows-positive)" = ok ]'
check "S247-3d. …recorded on the row by the scoring pass, naming the part" \
  '[ "$(probe part-rows-recorded)" = ok ]'
check "S247-3e. …so no part row reads a bare MET any more" \
  '[ "$(probe no-bare-part-met)" = ok ]'
check "S247-3f. every unverified-picture disclosure is preceded by a terminator" \
  '[ "$(probe disclosures-terminate)" = ok ]'
check "S247-3g. landing.reason carries the unverified clause the cell states" \
  '[ "$(probe landing-reason-carries-clause)" = ok ]'
check "S247-3i. …and every positive readout clause is separated from a severed note" \
  '[ "$(probe readouts-separate)" = ok ]'

# THE CONTROL. Grades, recommendations, group grades and counts are recorded
# BEFORE this session's change (measured at 57bea24) and must be byte-identical
# after it: this round changes what the report SAYS, never what it decides.
cat >"$TMPROOT/grades-at-57bea24.json" <<'GRADES'
[["xo-look-1", "low", "merge-with-follow-ups", {"contract": null, "drawing": "medium", "person": "low"}, {"contradictions": 0, "gap": 0, "met": 27, "untested": 26}], ["xo-look-2", "low", "merge-with-follow-ups", {"contract": null, "drawing": "low", "person": "low"}, {"contradictions": 0, "gap": 0, "met": 23, "untested": 30}], ["xo-look-3", "low", "merge-with-follow-ups", {"contract": null, "drawing": "low", "person": "low"}, {"contradictions": 0, "gap": 0, "met": 26, "untested": 27}], ["xo-restyle-1", "low", "merge-with-follow-ups", {"contract": null, "drawing": "low", "person": "low"}, {"contradictions": 0, "gap": 0, "met": 24, "untested": 29}], ["xo-restyle-2", "low", "merge-with-follow-ups", {"contract": null, "drawing": "low", "person": "low"}, {"contradictions": 0, "gap": 0, "met": 28, "untested": 25}], ["xo-restyle-3", "low", "merge-with-follow-ups", {"contract": null, "drawing": "low", "person": "low"}, {"contradictions": 1, "gap": 1, "met": 25, "untested": 27}]]
GRADES
check "S247-3h. CONTROL — every grade word, recommendation and count is unchanged" \
  'diff <(probe grades | head -1) <(cat "$TMPROOT/grades-at-57bea24.json")'

# ===========================================================================
# S247-4. A PART AGAINST THE WRONG PICTURE IS A GAP, IN THE READOUT'S WORDS
# ===========================================================================
# The negative control for S247-3c, and the thing that proves the rule reads the
# READOUT and not the filename: the same part, the same criterion, the same
# citation — only the recorded measurement changed.
echo ""
echo "S247-4. the same part against a picture that does not show it"

BAT="$TMPROOT/battle-shot"; cp -R "$MEASURE/xo-look-1" "$BAT"
"$PY" - "$BAT" <<'BENDEOF'
import glob, json, os, sys
root = sys.argv[1]
# ONE recorded field, on the shot the archive's own part rows cite: the part is
# in the page and has no box, which is what a part on a screen that is not
# showing measures as. Nothing else in the look is touched.
v = json.load(open(os.path.join(root, "verdict.json")))
crit = json.load(open(os.path.join(root, "criteria.json")))
parts = {str(c.get("id")): str(c.get("drawnPart") or "")
         for c in (crit.get("criteria") or []) if c.get("drawnPart")}
row = next(e for e in v["criteria"]
           if str(e.get("id")) in parts and str(e.get("shot") or "").strip())
part, shot = parts[str(row["id"])], str(row["shot"])
hits = glob.glob(os.path.join(root, "shots", "*", os.path.splitext(shot)[0] + ".json"))
doc = json.load(open(hits[0]))
doc["page"]["places"][part] = {"present": True, "laidOut": False,
                               "box": {"x": 0, "y": 0, "w": 0, "h": 0}}
json.dump(doc, open(hits[0], "w"), indent=1)
print(row["id"])
print(part)
BENDEOF
BAT_ROW="$("$PY" - "$BAT" <<'IDEOF'
import json, os, sys
root = sys.argv[1]
v = json.load(open(os.path.join(root, "verdict.json")))
crit = json.load(open(os.path.join(root, "criteria.json")))
parts = {str(c.get("id")): str(c.get("drawnPart") or "")
         for c in (crit.get("criteria") or []) if c.get("drawnPart")}
row = next(e for e in v["criteria"]
           if str(e.get("id")) in parts and str(e.get("shot") or "").strip())
print(row["id"])
IDEOF
)"
score_look "$BAT" "$TMPROOT/bat-out"
check "S247-4a. the battle-shot replay scored" \
  '[ -s "$TMPROOT/bat-out/verdict.json" ]'
check "S247-4b. the part row is a GAP, not a MET" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=[c for c in d[\"criteria\"] if c[\"id\"]==sys.argv[2]][0]
assert r[\"status\"]==\"gap\", r
" "$TMPROOT/bat-out/verdict.json" "$BAT_ROW"'
check "S247-4c. …and the readout is QUOTED on the row (laidOut: false, 0×0)" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=[c for c in d[\"criteria\"] if c[\"id\"]==sys.argv[2]][0]
n=\" \".join(str(r.get(\"note\") or \"\").split())
assert \"laidOut: false\" in n and \"0×0\" in n, n
" "$TMPROOT/bat-out/verdict.json" "$BAT_ROW"'
check "S247-4d. …and the captain reads it in report.md" \
  'tr "\n" " " <"$TMPROOT/bat-out/report.md" | tr -s " " | grep -q "laidOut: false"'
check "S247-4e. CONTROL — the untouched part rows are still positive" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rows=[c for c in d[\"criteria\"] if (c.get(\"landing\") or {}).get(\"partPlaced\")]
assert len(rows) >= 3, len(rows)
"  "$TMPROOT/bat-out/verdict.json"'

# ===========================================================================
# S247-5. COVERAGE IS COUNTED FROM THE RECORD OF STEPS THAT RAN
# ===========================================================================
# THE MEASUREMENT. `attempted N of M` was computed at BUILD time, before a
# single step had run, so the weekend's ledger shows it never moved: the number
# the captain read was a prediction wearing a measurement's clothes. It is now
# RECOUNTED after the look, from the readouts the harness wrote and the
# transcripts the ledger cites.
echo ""
echo "S247-5. attempted N of M is recounted from the steps that actually ran"

COV="$TMPROOT/cov"; mkdir -p "$COV/shots"
cat >"$COV/journey.json" <<'COVJ'
{"source": ["a constructed record"], "steps": [], "reachSteps": [],
 "coverage": {"group": "can a person do what it promises",
   "attempted": 0, "total": 5,
   "criteria": [
     {"id": "c-1", "text": "one", "attempted": false, "step": null, "reason": "nothing walked it"},
     {"id": "c-2", "text": "two", "attempted": false, "step": null, "reason": "nothing walked it"},
     {"id": "c-3", "text": "three", "attempted": false, "step": null, "reason": "nothing walked it"},
     {"id": "c-4", "text": "four", "attempted": false, "step": null, "reason": "nothing walked it"},
     {"id": "c-5", "text": "five", "attempted": false, "step": null, "reason": "nothing walked it"}]}}
COVJ
# ONE step the harness really ran, recorded exactly as xo-run.py records it…
cat >"$COV/shots/01-help.json" <<'R1'
{"do": "run", "key": "w1", "for": "c-2", "checkedBy": "cli", "met": true,
 "exit": 0, "stdout": "usage: relay", "stderr": "", "checks": []}
R1
# …and one transcript a LEDGER ROW cites, which is the other half of the rule.
cat >"$COV/verdict.json" <<'V1'
{"score": "medium", "criteria": [
  {"id": "c-4", "status": "met", "shot": "02-file.txt", "note": "it filed"},
  {"id": "c-5", "status": "untested", "note": "nothing reached it"}],
 "couldNot": [{"item": "c-5", "why": "the page never came up for me"}]}
V1
: >"$COV/shots/02-file.txt"
"$PY" "$JOURNEY" coverage --journey "$COV/journey.json" --shots "$COV/shots" \
  --verdict "$COV/verdict.json" --out "$COV/journey.json" >"$COV/said.txt" 2>&1
check "S247-5a. the recount printed the number the captain reads" \
  'grep -q "attempted 2 of 5" "$COV/said.txt"'
check "S247-5b. …and wrote it back onto the journey's coverage" \
  '"$PY" -c "
import json,sys
c=json.load(open(sys.argv[1]))[\"coverage\"]
assert c[\"attempted\"]==2 and c[\"total\"]==5, c
" "$COV/journey.json"'
check "S247-5c. the criterion whose STEP ran is attempted, and names the step" \
  '"$PY" -c "
import json,sys
rows={r[\"id\"]:r for r in json.load(open(sys.argv[1]))[\"coverage\"][\"criteria\"]}
assert rows[\"c-2\"][\"attempted\"] is True, rows[\"c-2\"]
assert rows[\"c-2\"][\"step\"]==\"w1\", rows[\"c-2\"]
assert rows[\"c-2\"][\"checkedBy\"]==\"cli\", rows[\"c-2\"]
" "$COV/journey.json"'
check "S247-5d. the criterion whose ledger row cites a TRANSCRIPT is attempted too" \
  '"$PY" -c "
import json,sys
rows={r[\"id\"]:r for r in json.load(open(sys.argv[1]))[\"coverage\"][\"criteria\"]}
assert rows[\"c-4\"][\"attempted\"] is True, rows[\"c-4\"]
assert \"02-file.txt\" in str(rows[\"c-4\"].get(\"reason\") or \"\"), rows[\"c-4\"]
" "$COV/journey.json"'
check "S247-5e. a criterion with no step and no row stays UNTESTED" \
  '"$PY" -c "
import json,sys
rows={r[\"id\"]:r for r in json.load(open(sys.argv[1]))[\"coverage\"][\"criteria\"]}
for i in (\"c-1\",\"c-3\",\"c-5\"):
    assert rows[i][\"attempted\"] is False, rows[i]
    assert rows[i][\"status\"]==\"untested\", rows[i]
" "$COV/journey.json"'
check "S247-5f. …carrying the WORKER'S OWN couldNot reason where it gave one" \
  '"$PY" -c "
import json,sys
rows={r[\"id\"]:r for r in json.load(open(sys.argv[1]))[\"coverage\"][\"criteria\"]}
assert \"the page never came up for me\" in rows[\"c-5\"][\"reason\"], rows[\"c-5\"]
" "$COV/journey.json"'
check "S247-5g. …and 'no step reached it' where it did not" \
  '"$PY" -c "
import json,sys
rows={r[\"id\"]:r for r in json.load(open(sys.argv[1]))[\"coverage\"][\"criteria\"]}
assert \"no step reached it\" in rows[\"c-1\"][\"reason\"], rows[\"c-1\"]
" "$COV/journey.json"'
check "S247-5h. a REFUSED step reached nothing and is not counted" \
  'cp -R "$COV" "$TMPROOT/cov2" &&
   "$PY" -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p)); d[\"refused\"]=True; d[\"met\"]=None
json.dump(d,open(p,\"w\"))" "$TMPROOT/cov2/shots/01-help.json" &&
   "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
d[\"coverage\"][\"criteria\"]=[dict(r,attempted=False,step=None) for r in d[\"coverage\"][\"criteria\"]]
d[\"coverage\"][\"attempted\"]=0
json.dump(d,open(sys.argv[1],\"w\"))" "$TMPROOT/cov2/journey.json" &&
   "$PY" "$JOURNEY" coverage --journey "$TMPROOT/cov2/journey.json" \
     --shots "$TMPROOT/cov2/shots" --verdict "$TMPROOT/cov2/verdict.json" \
     --out "$TMPROOT/cov2/journey.json" | grep -q "attempted 1 of 5"'
# AND IT ONLY EVER MOVES UP. The browser walk is UNCHANGED by this round, so a
# promise the walk already pairs with a step must not be un-counted by a recount
# that only knows about transcripts. Measured: before this guard the recount set
# every browser-attempted row back to false and the number went DOWN.
BROWSED="$TMPROOT/cov-browser"; mkdir -p "$BROWSED/shots"
"$PY" - "$COV/journey.json" "$BROWSED/journey.json" <<'BRWEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d["coverage"]["criteria"]:
    r["attempted"], r["step"], r["reason"] = True, "j1", ""
d["coverage"]["attempted"] = len(d["coverage"]["criteria"])
json.dump(d, open(sys.argv[2], "w"), indent=1)
BRWEOF
echo '{"score": "high", "criteria": []}' >"$BROWSED/verdict.json"
"$PY" "$JOURNEY" coverage --journey "$BROWSED/journey.json" --shots "$BROWSED/shots" \
  --verdict "$BROWSED/verdict.json" --out "$BROWSED/journey.json" >"$BROWSED/said.txt" 2>&1
check "S247-5h2. a recount with no transcripts does NOT un-count the browser walk" \
  'grep -q "attempted 5 of 5" "$BROWSED/said.txt"'
check "S247-5h3. …and every one of those rows keeps its walk step" \
  '"$PY" -c "
import json,sys
rows=json.load(open(sys.argv[1]))[\"coverage\"][\"criteria\"]
assert all(r[\"attempted\"] and r[\"step\"]==\"j1\" for r in rows), rows
assert all(\"status\" not in r for r in rows), rows
" "$BROWSED/journey.json"'
check "S247-5i. xo.sh recounts it after the look, and journals the number" \
  'grep -q "xo_recount_coverage" "$XOSH"'
check "S247-5j. …and the worker's own requested steps are recorded on the journey" \
  'grep -q "reach-record" "$XOSH" && grep -q "reach-record" "$JOURNEY"'

# ===========================================================================
# S247-6. THE FENCE IS STILL REAL — proved by DISABLING it
# ===========================================================================
# The three refusals above (a shell, an absolute path, a read outside the
# worktree) are the whole reason reach is "it proposes, the harness executes".
# A test that passes against a fence that is not there proves nothing, so the
# fence is commented out in a COPY and the same three probes are asserted to
# STOP refusing. If any of them still refuses, the check above was vacuous.
echo ""
echo "S247-6. the fence tests fail when the fence is disabled (the mutation)"

MUT="$TMPROOT/xo-run-nofence.py"
"$PY" - "$XORUN" "$MUT" <<'MUTEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
# ONE edit, at the one door every step goes through: `refuse_reason` is the
# function that says why a step may not run. Commented out, it says nothing.
m = re.search(r"\ndef refuse_reason\(([^)]*)\):\n", src)
assert m, "refuse_reason not found — this mutation has drifted"
cut = src[:m.end()] + '    return ""\n' + src[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(cut)
MUTEOF
check "S247-6a. the mutant parses (so a non-refusal below is the fence, not a crash)" \
  '"$PY" -c "import py_compile,sys;py_compile.compile(sys.argv[1],doraise=True)" "$MUT"'

fence_probe() { # <xo-run.py> <step-json> → the readout's `refused`
  local runpy="$1" step="$2" d
  d="$(mktemp -d "$TMPROOT/fence.XXXXXX")"
  mkdir -p "$d/out"
  printf '{"reachSteps": [%s]}\n' "$step" >"$d/journey.json"
  ( cd "$FPROD" && "$PY" "$CAGE" 120 "$PY" "$runpy" run \
      --journey "$d/journey.json" --out "$d/out" --repo "$FPROD" \
      --branch fence-probe --mission-dir "$d" ) >"$d/log" 2>&1
  "$PY" -c "
import glob, json, sys
hits = sorted(glob.glob(sys.argv[1] + '/*.json'))
if not hits:
    print('nothing-ran'); raise SystemExit(0)
d = json.load(open(hits[0]))
print('refused' if d.get('refused') else 'allowed')" "$d/out"
}

# A real repo on a real branch, so the fence is the only thing deciding.
FPROD="$TMPROOT/fence-prod"; mkdir -p "$FPROD"
printf 'print("hi")\n' >"$FPROD/app.py"
( cd "$FPROD" && "$GIT" init -q . && "$GIT" add -A &&
  "$GIT" -c user.email=t@t -c user.name=t commit -qm init &&
  "$GIT" branch -f fence-probe ) >/dev/null 2>&1

SHELL_STEP='{"do":"run","argv":["bash","-c","echo hi"],"cwd":"<worktree>","env":{"HOME":"<throwaway-home>"},"for":"c1","evidence":"01-shell.txt"}'
ABS_STEP='{"do":"run","argv":["/bin/echo","hi"],"cwd":"<worktree>","env":{"HOME":"<throwaway-home>"},"for":"c1","evidence":"01-abs.txt"}'
OUT_STEP='{"do":"read","path":"/etc/hosts","expect":{},"for":"c1","evidence":"01-out.txt"}'

check "S247-6b. the REAL fence refuses \`bash -c\`" \
  '[ "$(fence_probe "$XORUN" "$SHELL_STEP")" = refused ]'
check "S247-6c. the REAL fence refuses an absolute argv0" \
  '[ "$(fence_probe "$XORUN" "$ABS_STEP")" = refused ]'
check "S247-6d. the REAL fence refuses a read outside the worktree" \
  '[ "$(fence_probe "$XORUN" "$OUT_STEP")" = refused ]'
check "S247-6e. MUTATION — with the fence disabled \`bash -c\` is NOT refused" \
  '[ "$(fence_probe "$MUT" "$SHELL_STEP")" != refused ]'
check "S247-6f. MUTATION — …nor is the absolute argv0" \
  '[ "$(fence_probe "$MUT" "$ABS_STEP")" != refused ]'
check "S247-6g. MUTATION — …nor the read outside the worktree" \
  '[ "$(fence_probe "$MUT" "$OUT_STEP")" != refused ]'

# ===========================================================================
# ZERO SPEND
# ===========================================================================
echo ""
echo "zero spend"
NCALLS="$(wc -l <"$SPEND_LOG" | tr -d ' ')"
WITHMODEL="$(grep -c -- "--model" "$SPEND_LOG" 2>/dev/null || true)"
check "no worker CLI was invoked anywhere in this suite (0 calls)" \
  '[ "$NCALLS" = 0 ]'
echo "  shim: $NCALLS invocation(s), $WITHMODEL carrying --model"

echo ""
printf 'lcars-xo-reach: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
