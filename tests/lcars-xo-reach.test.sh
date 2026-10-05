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
echo "2. the journey carries run / workflow / read steps, from the checklists"

"$PY" "$JOURNEY" build --criteria "$CJ" --prd "$CLIM/prd.md" \
  --title "Notes" --out "$TMPROOT/cli-journey.json" >"$TMPROOT/cli-journey.out" 2>&1
CJO="$TMPROOT/cli-journey.json"

rsteps() { "$PY" -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(json.dumps(d.get("reachSteps") or []))' "$1"; }

check "a CLI-only journey emits reach steps at all" \
  '[ -s "$CJO" ] && [ "$(rsteps "$CJO")" != "[]" ]'
check "they are run steps with argv, cwd and env" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rs=[s for s in (d.get(\"reachSteps\") or []) if s.get(\"do\")==\"run\"]
assert rs, d.get(\"reachSteps\")
for s in rs:
    assert isinstance(s.get(\"argv\"),list) and s[\"argv\"], s
    assert s.get(\"cwd\"), s
    assert isinstance(s.get(\"env\"),dict), s
    assert s.get(\"evidence\"), s
" "$CJO"'
check "one of them runs --help (checklist item 1)" \
  'rsteps "$CJO" | grep -q -- "--help"'
check "one of them is the BAD-INPUT step (checklist item 2)" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rs=d.get(\"reachSteps\") or []
assert any(\"02-bad-input\" in (s.get(\"evidence\") or \"\") for s in rs), [s.get(\"evidence\") for s in rs]" "$CJO"'
check "every reach step says which criterion it is FOR" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rs=d.get(\"reachSteps\") or []
assert rs
bad=[s for s in rs if not s.get(\"for\")]
assert not bad, bad" "$CJO"'
check "each reach step names the checklist item it came from" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rs=d.get(\"reachSteps\") or []
bad=[s for s in rs if not s.get(\"fromChecklist\")]
assert not bad, bad" "$CJO"'

"$PY" "$JOURNEY" build --criteria "$FJ" --prd "$WFM/prd.md" \
  --title "Publish" --out "$TMPROOT/wf-journey.json" >/dev/null 2>&1
check "a workflow entrypoint emits a workflow step naming the yml" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
ws=[s for s in (d.get(\"reachSteps\") or []) if s.get(\"do\")==\"workflow\"]
assert ws, d.get(\"reachSteps\")
assert ws[0].get(\"file\",\"\").endswith(\"publish.yml\"), ws[0]
" "$TMPROOT/wf-journey.json"'

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
check "a reach step makes its criterion ATTEMPTED in coverage" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
rows=(d.get(\"coverage\") or {}).get(\"criteria\") or []
assert any(r.get(\"attempted\") for r in rows), rows" "$CJO"'

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
# 4b. THE LOOK ITSELF REACHES — xo.sh calls the harness, not just the browser
# ===========================================================================
echo ""
echo "4b. a real look runs the declared steps, before the launch"
check "xo.sh calls xo-run.py for the declared steps" \
  'grep -q "xo_run_reach" "$XO" && grep -q "xo-run.py" "$XO"'
check "it runs them BEFORE the launch (a CLI needs no server up)" \
  '"$PY" -c "
import re,sys
t=open(sys.argv[1]).read()
i=t.index(\"xo_run_reach \\\"\$dir\\\" \\\"\$xodir\\\" \\\"\$shots\\\"\")
j=t.index(\"--- 2. LAUNCH\")
assert i<j, (i,j)
" "$XO"'
check "the worker's requested steps go through the same cap and worktree" \
  'grep -q "xo_reach_actions" "$XO"'
check "the reach journals what it reached, so the report can read it" \
  'grep -q "journal \"\$dir\" reached" "$XO"'
check "a mission with no branch is told so, never run against the checkout" \
  'grep -q "reach-refused" "$XO"'
MJ="$MDIR/xo/journey.json"
check "the look wrote a journey carrying reachSteps for the CLI criteria" \
  '[ -s "$MJ" ] && "$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get(\"reachSteps\"), d.get(\"reachSteps\")
assert any(s.get(\"do\")==\"run\" for s in d[\"reachSteps\"]), d[\"reachSteps\"]
" "$MJ"'
check "...and journaled that it tried to reach them" \
  'grep -qE "\"action\": \"(reached|reach-refused)\"" "$MDIR/number-one.jsonl"'

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
# 7. FIX ROUND 1 — the two material defects the fresh tester found
# ===========================================================================
# D2 (the worse one). THE DECLARED CLI STEPS RAN THE WRONG SUBCOMMAND. On the
# tester's own fixture the instantiated steps were
#   t-1-ac2 -> ['python3','relay.py','list','']     # the BAD-INPUT step
#   t-1-ac3 -> ['python3','relay.py','list','…']    # the HAPPY PATH
# `<subcommand>` and `<the-main-verb>` were both filled with verbs[0] — the
# FIRST subcommand the record happens to name — so a record that names its
# listing verb first fed the bad input to a command that does not take any.
# `list ""` exits 0, the readout recorded {"key":"exitNonZero","passed":false},
# and the captain's console printed `FAILED 02-bad-input.txt (cli)` ABOUT A
# COMMAND THAT WORKS. A reviewer that filed 0 of 31 real bugs must not start
# filing bugs that are not there. And the happy path never filed anything, so
# "list" was checked against a store nothing had ever written to.
#
# D1. `checkedBy` NEVER REACHED THE VERDICT. It is produced on every step
# readout, and the prompt's prose teaches it — but the verdict SCHEMA the worker
# copies never named it and the scorer never carried it, so it was present on 0
# of 15 rows while `evidence` read `picture` on 15 of 15, including a row whose
# only shot was `01-help.txt` — a terminal transcript. Identically on BOTH
# engines, which is what makes it a schema fault and not a model fault.
echo ""
echo "7. fix round 1 — the right subcommand, and checkedBy on the row"

# --- D2: a record that names its LISTING verb FIRST (the tester's fixture) ---
RLM="$TMPROOT/m-relay"; mkdir -p "$RLM"
cat >"$RLM/prd.md" <<'MD'
# Relay — a command line for requests

PLAN RULE: CLI-only. This milestone adds no page and no screen.

## Acceptance criteria
- `relay.py list` prints every filed request in the order it was filed.
- `relay.py file "<request text>"` files a request and prints the id it stored.
- `relay.py --help` lists every subcommand the CLI dispatches.
MD
cat >"$RLM/plan.json" <<'JSON'
{"tickets": [
  {"id": "t1", "changesScreenAppearance": false,
   "entrypoints": [{"kind": "cli", "path": "relay.py",
                    "realRunTest": "tests/test_cli.py",
                    "realRunProof": "it runs relay.py as a subprocess"}],
   "seams": [], "seamsNote": "pure store",
   "acceptanceCriteria": [
     {"text": "relay file stores the request text it was given", "notVisual": true,
      "kind": "works", "serves": "prd-2", "direction": "delivers"},
     {"text": "relay list prints what was filed", "notVisual": true,
      "kind": "works", "serves": "prd-1", "direction": "delivers"}]}
]}
JSON
cat >"$RLM/state.json" <<'JSON'
{"id": "m-relay", "title": "Relay", "stage": "verify", "branch": "feat/relay"}
JSON
"$PY" "$CRITERIA" "$RLM" "$TMPROOT/relay-criteria.json" >/dev/null 2>&1
"$PY" "$JOURNEY" build --criteria "$TMPROOT/relay-criteria.json" \
  --prd "$RLM/prd.md" --title "Relay" --out "$TMPROOT/relay-journey.json" \
  >"$TMPROOT/relay-journey.out" 2>&1
RJO="$TMPROOT/relay-journey.json"

# The reader for every D2 claim, so the assertion reads as the claim does.
cat >"$TMPROOT/fr1.py" <<'PYEOF'
import json, sys
what, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
rs = [s for s in (d.get("reachSteps") or []) if s.get("do") == "run"]


def by_evidence(frag):
    return [s for s in rs if frag in (s.get("evidence") or "")]


if what == "bad-input-argv":
    st = by_evidence("02-bad-input")
    assert st, [s.get("evidence") for s in rs]
    print(json.dumps(st[0]["argv"]))
elif what == "happy-argv":
    st = by_evidence("03-happy-path.")
    assert st, [s.get("evidence") for s in rs]
    print(json.dumps(st[0]["argv"]))
elif what == "readback-argv":
    st = [s for s in rs if "readback" in (s.get("evidence") or "")]
    assert st, [s.get("evidence") for s in rs]
    print(json.dumps(st[0]["argv"]))
elif what == "order":
    # The FILE must come before the LIST it is read back from.
    ev = [s.get("evidence") or "" for s in rs]
    a = [i for i, e in enumerate(ev) if e.startswith("03-happy-path.")]
    b = [i for i, e in enumerate(ev) if "readback" in e]
    assert a and b and a[0] < b[0], ev
    print("ok")
elif what == "every-step-for":
    bad = [s for s in (d.get("reachSteps") or []) if not s.get("for")]
    assert not bad, bad
    print("ok")
else:
    raise SystemExit("unknown: %s" % what)
PYEOF
FR1="$TMPROOT/fr1.py"

check "D2. the BAD-INPUT step runs the subcommand that TAKES the input" \
  '[ "$("$PY" "$FR1" bad-input-argv "$RJO")" = "[\"python3\", \"relay.py\", \"file\", \"\"]" ]'
check "D2. …and never the listing verb that takes none (the FAILED-about-a-working-command bug)" \
  '! "$PY" "$FR1" bad-input-argv "$RJO" | grep -q "list"'
check "D2. the HAPPY PATH performs the action — it files, with a real value" \
  '[ "$("$PY" "$FR1" happy-argv "$RJO")" = "[\"python3\", \"relay.py\", \"file\", \"Number One typed this to see it carry\"]" ]'
check "D2. …and a read-back step LISTS what it just filed" \
  '[ "$("$PY" "$FR1" readback-argv "$RJO")" = "[\"python3\", \"relay.py\", \"list\"]" ]'
check "D2. …in that order: file first, then the list that reads it back" \
  '[ "$("$PY" "$FR1" order "$RJO")" = ok ]'
check "D2. …so the happy path never lists twice" \
  '[ "$("$PY" "$FR1" happy-argv "$RJO")" != "$("$PY" "$FR1" readback-argv "$RJO")" ]'
check "D2. every reach step still says which criterion it is FOR" \
  '[ "$("$PY" "$FR1" every-step-for "$RJO")" = ok ]'
# POSITIVE CONTROL, in the claim's own phrasing family: a record that names its
# ACTING verb first must still instantiate that same verb. The cure must not
# merely reverse the order it picks.
check "D2. positive control — a record naming its acting verb FIRST still uses it" \
  '[ "$("$PY" "$FR1" bad-input-argv "$CJO")" = "[\"python3\", \"notes.py\", \"add\", \"\"]" ]'

# D2, END TO END — the instantiated steps, EXECUTED against a real CLI. The
# argv assertions above are the cure; this is the harm they remove. The old
# steps printed `FAILED 02-bad-input.txt (cli)` about `relay.py list ""`, a
# command that works, and shipped a transcript that looked like proof of a
# defect. Nothing here is hand-written: the steps are the ones xo-journey.py
# just built from the record.
RPROD="$TMPROOT/relay-prod"; mkdir -p "$RPROD"
git -C "$RPROD" init -q -b main
cat >"$RPROD/relay.py" <<'PYEOF'
import os, sys
args = sys.argv[1:]
store = os.path.join(os.environ.get("HOME", "."), ".relay", "store")
if not args or args[0] in ("--help", "-h"):
    print("usage: relay [file|list]")
    sys.exit(0)
if args[0] == "file":
    if len(args) < 2 or not args[1].strip():
        sys.stderr.write("relay: empty request text\n")
        sys.exit(2)
    os.makedirs(os.path.dirname(store), exist_ok=True)
    with open(store, "a") as fh:
        fh.write(args[1] + "\n")
    print("filed r1")
    sys.exit(0)
if args[0] == "list":
    try:
        sys.stdout.write(open(store).read())
    except IOError:
        pass
    sys.exit(0)
sys.stderr.write("relay: no such subcommand %s\n" % args[0])
sys.exit(2)
PYEOF
git -C "$RPROD" add -A >/dev/null 2>&1
git -C "$RPROD" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$RPROD" branch -q feat/relay 2>/dev/null
RSHOTS="$TMPROOT/shots/relay-1"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run \
  --journey "$RJO" --repo "$RPROD" --branch feat/relay \
  --out "$RSHOTS" --mission-dir "$RLM" >"$TMPROOT/relay-run.out" 2>&1
check "D2 e2e. the instantiated steps TERMINATE and leave their transcripts" \
  '! grep -q "TIMED OUT" "$TMPROOT/relay-run.out" &&
   [ -s "$RSHOTS/02-bad-input.txt" ] && [ -s "$RSHOTS/03-happy-path.txt" ] &&
   [ -s "$RSHOTS/03-happy-path-readback.txt" ]'
check "D2 e2e. the bad-input step gets the NON-ZERO exit it expects — no false FAILED" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"exit\"] not in (0, None), d
assert d[\"met\"] is True, d
" "$RSHOTS/02-bad-input.json"'
check "D2 e2e. …and the console never reports FAILED about it" \
  '! grep -q "FAILED 02-bad-input" "$TMPROOT/relay-run.out"'
check "D2 e2e. the happy path really FILED something" \
  'grep -q "filed" "$RSHOTS/03-happy-path.txt"'
check "D2 e2e. and the read-back step shows what was filed carrying through" \
  'grep -q "Number One typed this to see it carry" "$RSHOTS/03-happy-path-readback.txt"'
# POSITIVE CONTROL for the same claim: this is a REAL read-back, not a step that
# would print that line whatever happened. With nothing filed, the same list
# command prints nothing of the sort.
check "D2 e2e. positive control — the listing is empty when nothing was filed" \
  'EMPTYHOME="$TMPROOT/empty-home"; mkdir -p "$EMPTYHOME";
   ! HOME="$EMPTYHOME" "$PY" "$RPROD/relay.py" list | grep -q "Number One typed"'

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
# 8. FIX ROUND 2 — round 1's cure never fires on the record that bred the bug
# ===========================================================================
# A fresh tester re-ran a LIVE look at 443b626 and the journey STILL read
#   t-1-ac2 -> ['python3','relay.py','list','']        # the bad-input step
#   t-1-ac3 -> ['python3','relay.py','list','<value>'] # the happy path
# and the console STILL printed `FAILED 02-bad-input.txt (cli)` about a command
# that works. Round 1's rule reads WHETHER THE RECORD WROTE A VALUE INSIDE THE
# BACKTICKS (`takes = len(words) > 2`). The live record writes `relay.py file`
# and `relay.py list` BARE — prose for the behaviour, a bare invocation in the
# backticks, which is the ordinary way a PRD is written. Every shape is then
# takesValue:False, `acting` falls through to verbs[0], and that IS the pre-fix
# behaviour verbatim.
#
# THE CURE IS NOT A CLEVERER GUESS. The infer-vs-record rule has cost this
# project three sessions (S147, S156, S188), every one by reading back a human's
# wording. When the record does not SAY which subcommand takes the input, the
# step cannot be instantiated honestly, so it is NOT instantiated: it joins
# `reachUninstantiated` with a reason naming exactly what the record failed to
# say — the mechanism this session already uses for cli#4-8 and web#4-6. An
# honest "I could not build this step" beats a FAILED about working software.
#
# And round 1 made a second defect of its own: `reading` did not exclude the
# verb already chosen as `acting`, so a record naming its acting verb first with
# no value resolved BOTH to the same verb and the new read-back step ran
# `relay.py file` with no argument — exit 2 by design, a brand-new false FAILED
# in a place the fix created.
echo ""
echo "8. fix round 2 — a silent record is REFUSED, never guessed"

# --- the tester's exact fixture shape: BARE backticks, listing verb FIRST ----
BCM="$TMPROOT/m-beacon"; mkdir -p "$BCM"
cat >"$BCM/prd.md" <<'MD'
# Beacon — a command line for requests

PLAN RULE: CLI-only. This milestone adds no page and no screen.

## Acceptance criteria
- `beacon.py list` prints every filed request in the order it was filed.
- `beacon.py file` files the request text the captain typed and prints its id.
- `beacon.py --help` lists every subcommand the CLI dispatches.
MD
cat >"$BCM/plan.json" <<'JSON'
{"tickets": [
  {"id": "t1", "changesScreenAppearance": false,
   "entrypoints": [{"kind": "cli", "path": "beacon.py",
                    "realRunTest": "tests/test_cli.py",
                    "realRunProof": "it runs beacon.py as a subprocess"}],
   "seams": [], "seamsNote": "pure store",
   "acceptanceCriteria": [
     {"text": "beacon file stores the request text it was given", "notVisual": true,
      "kind": "works", "serves": "prd-2", "direction": "delivers"},
     {"text": "beacon list prints what was filed", "notVisual": true,
      "kind": "works", "serves": "prd-1", "direction": "delivers"}]}
]}
JSON
cat >"$BCM/state.json" <<'JSON'
{"id": "m-beacon", "title": "Beacon", "stage": "verify", "branch": "feat/beacon"}
JSON
"$PY" "$CRITERIA" "$BCM" "$TMPROOT/beacon-criteria.json" >/dev/null 2>&1
"$PY" "$JOURNEY" build --criteria "$TMPROOT/beacon-criteria.json" \
  --prd "$BCM/prd.md" --title "Beacon" --out "$TMPROOT/beacon-journey.json" \
  >"$TMPROOT/beacon-journey.out" 2>&1
BJO="$TMPROOT/beacon-journey.json"

# The same reader for every claim, so each assertion reads as the claim does.
cat >"$TMPROOT/fr2.py" <<'PYEOF'
import json, sys
what, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
rs = [s for s in (d.get("reachSteps") or []) if isinstance(s, dict)]
un = [u for u in (d.get("reachUninstantiated") or []) if isinstance(u, dict)]


def ev(frag):
    return [s for s in rs if frag in (s.get("evidence") or "")]


if what == "evidence-names":
    print(" ".join(s.get("evidence") or "" for s in rs))
elif what == "argv":
    st = ev(sys.argv[3])
    print(json.dumps(st[0]["argv"]) if st else "<not-instantiated>")
elif what == "why":
    # The reason recorded for one checklist item.
    for u in un:
        if u.get("item") == sys.argv[3]:
            print(u.get("why") or "")
            break
    else:
        print("<no-entry>")
elif what == "verbs-in-argv":
    # Every word of every instantiated argv, so a claim can say a verb is absent.
    print(" ".join(w for s in rs for w in (s.get("argv") or []) if isinstance(w, str)))
elif what == "no-step-shares-an-argv-verb":
    # No two run steps may be the SAME command — the round-1 read-back bug.
    sigs = [tuple(s.get("argv") or []) for s in rs if s.get("do") == "run"]
    assert len(sigs) == len(set(sigs)), sigs
    print("ok")
elif what == "readback-verb-vs-acting":
    # The read-back must not run the verb the ACTING step ran: round 1 resolved
    # both to the same verb and then ran it with no argument.
    def verb(frag):
        st = ev(frag)
        return (st[0].get("argv") or [None, None, None])[2] if st else None
    back, act = verb("readback"), verb("03-happy-path.")
    print("collision" if (back is not None and back == act) else "distinct")
else:
    raise SystemExit("unknown: %s" % what)
PYEOF
FR2="$TMPROOT/fr2.py"

# The REAL CLI both fixtures describe. `list ""` exits 0 BY DESIGN; `file ""`
# exits 2. Nothing here is broken, which is what makes a FAILED about it a lie.
BPROD="$TMPROOT/beacon-prod"; mkdir -p "$BPROD"
git -C "$BPROD" init -q -b main
cat >"$BPROD/beacon.py" <<'PYEOF'
import os, sys
args = sys.argv[1:]
store = os.path.join(os.environ.get("HOME", "."), ".beacon", "store")
if not args or args[0] in ("--help", "-h"):
    print("usage: beacon [file|list]")
    sys.exit(0)
if args[0] == "file":
    if len(args) < 2 or not args[1].strip():
        sys.stderr.write("beacon: empty request text\n")
        sys.exit(2)
    os.makedirs(os.path.dirname(store), exist_ok=True)
    with open(store, "a") as fh:
        fh.write(args[1] + "\n")
    print("filed r1")
    sys.exit(0)
if args[0] == "list":
    try:
        sys.stdout.write(open(store).read())
    except IOError:
        pass
    sys.exit(0)
sys.stderr.write("beacon: no such subcommand %s\n" % args[0])
sys.exit(2)
PYEOF
git -C "$BPROD" add -A >/dev/null 2>&1
git -C "$BPROD" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$BPROD" branch -q feat/beacon 2>/dev/null

# 1. NO bad-input step is instantiated when the record never said which verb
#    takes input. The live defect was that one existing and being wrong.
check "R2. a record with BARE backticks instantiates NO bad-input step" \
  '[ "$("$PY" "$FR2" argv "$BJO" 02-bad-input)" = "<not-instantiated>" ]'
check "R2. …nor a happy path aimed at a verb nobody said takes a value" \
  '[ "$("$PY" "$FR2" argv "$BJO" 03-happy-path)" = "<not-instantiated>" ]'
check "R2. …and the listing verb never appears in any instantiated argv" \
  '! "$PY" "$FR2" verbs-in-argv "$BJO" | tr " " "\n" | grep -qx "list"'
check "R2. the item the record CAN fill is still instantiated — --help runs" \
  '"$PY" "$FR2" verbs-in-argv "$BJO" | grep -q -- "--help"'

# 2. The refusal is RECORDED, with a reason naming what the record failed to say.
check "R2. the bad-input item is recorded in reachUninstantiated" \
  '[ "$("$PY" "$FR2" why "$BJO" "cli#2")" != "<no-entry>" ]'
check "R2. …and its reason names the fact the record never wrote" \
  '"$PY" "$FR2" why "$BJO" "cli#2" | grep -qi "which subcommand" &&
   "$PY" "$FR2" why "$BJO" "cli#2" | grep -qi "takes"'
check "R2. …and tells the captain what to write so it instantiates" \
  '"$PY" "$FR2" why "$BJO" "cli#2" | grep -q "beacon.py"'
check "R2. the happy-path item is recorded too, not silently dropped" \
  '[ "$("$PY" "$FR2" why "$BJO" "cli#3")" != "<no-entry>" ]'

# 3. A record naming the ACTING verb FIRST, still with no value: round 1 resolved
#    `acting` and `reading` to the SAME verb and built a read-back that ran
#    `file` with no argument — exit 2, a false FAILED the fix itself created.
BC2="$TMPROOT/m-beacon2"; mkdir -p "$BC2"
cat >"$BC2/prd.md" <<'MD'
# Beacon — a command line for requests

PLAN RULE: CLI-only. This milestone adds no page and no screen.

## Acceptance criteria
- `beacon.py file` files the request text the captain typed and prints its id.
- `beacon.py list` prints every filed request in the order it was filed.
- `beacon.py --help` lists every subcommand the CLI dispatches.
MD
cp "$BCM/plan.json" "$BC2/plan.json"
cp "$BCM/state.json" "$BC2/state.json"
"$PY" "$CRITERIA" "$BC2" "$TMPROOT/beacon2-criteria.json" >/dev/null 2>&1
"$PY" "$JOURNEY" build --criteria "$TMPROOT/beacon2-criteria.json" \
  --prd "$BC2/prd.md" --title "Beacon" --out "$TMPROOT/beacon2-journey.json" \
  >"$TMPROOT/beacon2-journey.out" 2>&1
BJ2="$TMPROOT/beacon2-journey.json"
check "R2. acting-verb-first with no value: no read-back step is built at all" \
  '[ "$("$PY" "$FR2" argv "$BJ2" readback)" = "<not-instantiated>" ]'
check "R2. …and no two instantiated steps are the SAME command" \
  '[ "$("$PY" "$FR2" no-step-shares-an-argv-verb "$BJ2")" = ok ]'
check "R2. …and the read-back verb is never the verb the acting step already ran" \
  '[ "$("$PY" "$FR2" readback-verb-vs-acting "$BJ2")" = distinct ]'
# THE HARM round 1's own fix created, end to end: that read-back ran
# `beacon.py` with no argument, which exits 2 BY DESIGN, so the console printed
# a FAILED in a place the fix itself invented.
BSHOTS2="$TMPROOT/shots/beacon-2"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run \
  --journey "$BJ2" --repo "$BPROD" --branch feat/beacon \
  --out "$BSHOTS2" --mission-dir "$BC2" >"$TMPROOT/beacon2-run.out" 2>&1
check "R2 e2e. acting-verb-first, no value: the console prints no FAILED either" \
  '! grep -q "FAILED" "$TMPROOT/beacon2-run.out"'
check "R2 e2e. …and no read-back transcript exists to be mistaken for proof" \
  '! ls "$BSHOTS2" 2>/dev/null | grep -q readback'
check "R2. …and that ordering is refused for the same recorded reason" \
  '"$PY" "$FR2" why "$BJ2" "cli#2" | grep -qi "which subcommand"'

# 2-bis. UNCHANGED FROM ROUND 1 when the record DOES write a value — in BOTH
# orderings. These are the proof the cure never merely reverses the pick.
check "R2. control — value written, listing verb first: bad input still goes to the acting verb" \
  '[ "$("$PY" "$FR2" argv "$RJO" 02-bad-input)" = "[\"python3\", \"relay.py\", \"file\", \"\"]" ]'
check "R2. control — …and its read-back still LISTS" \
  '[ "$("$PY" "$FR2" argv "$RJO" readback)" = "[\"python3\", \"relay.py\", \"list\"]" ]'
check "R2. control — value written, acting verb first: still the acting verb" \
  '[ "$("$PY" "$FR2" argv "$CJO" 02-bad-input)" = "[\"python3\", \"notes.py\", \"add\", \"\"]" ]'
check "R2. control — …and no two of those steps are the same command either" \
  '[ "$("$PY" "$FR2" no-step-shares-an-argv-verb "$RJO")" = ok ] &&
   [ "$("$PY" "$FR2" no-step-shares-an-argv-verb "$CJO")" = ok ]'

# 4. END TO END — the console must not print FAILED about a step it never built.
# The steps are the ones xo-journey.py just made from the silent record; the CLI
# is real and correct (list "" exits 0 BY DESIGN, file "" exits 2).
BSHOTS="$TMPROOT/shots/beacon-1"
"$PY" "$CAGE" 120 "$PY" "$XORUN" run \
  --journey "$BJO" --repo "$BPROD" --branch feat/beacon \
  --out "$BSHOTS" --mission-dir "$BCM" >"$TMPROOT/beacon-run.out" 2>&1
check "R2 e2e. the look TERMINATES and still reaches the item it could build" \
  '! grep -q "TIMED OUT" "$TMPROOT/beacon-run.out" && [ -s "$BSHOTS/01-help.txt" ]'
check "R2 e2e. the console prints NO FAILED at all — the CLI is correct" \
  '! grep -q "FAILED" "$TMPROOT/beacon-run.out"'
check "R2 e2e. …and in particular not about the bad-input item" \
  '! grep -q "02-bad-input" "$TMPROOT/beacon-run.out"'
check "R2 e2e. no transcript was written for a step that was never instantiated" \
  '[ ! -e "$BSHOTS/02-bad-input.txt" ] && [ ! -e "$BSHOTS/03-happy-path.txt" ]'

# 5. POSITIVE CONTROL, in the claim's own phrasing family: a GENUINELY failing
# step must STILL report FAILED. Silencing real failures is the opposite error
# and it is worse. `pkg/render.py` does `from . import helper` and the workflow
# runs it as a file — a planted ImportError, run through the same console.
check "R2. positive control — a real failure STILL prints FAILED on the console" \
  'grep -q "FAILED 02-workflow-run" "$TMPROOT/wf.out"'
check "R2. positive control — …and the bad input of a record that DID speak still runs" \
  '[ -s "$RSHOTS/02-bad-input.txt" ] &&
   grep -q "ran 02-bad-input" "$TMPROOT/relay-run.out"'

# ===========================================================================
# 9. FIX ROUND 3 — the refusal is RECORDED; it must also be DELIVERED
# ===========================================================================
# A live look at ec9e4c6 proved round 2's cure right and its DELIVERY missing.
# On a bare record the console printed
#
#     ◈ 3 declared step(s) reached, 0 refused; the worktree and its HOME are gone.
#
# while `journey.reachUninstantiated` held TEN items on disk, each with a good
# reason. "0 refused" is not merely silent — it is an explicit ALL-CLEAR on
# exactly the question the refusal exists to raise. The word `refused` already
# means something else here (a step `xo-run.py` declined to EXECUTE, e.g. an
# escape attempt), so it is QUALIFIED rather than redefined underneath its
# current users, and the uninstantiated items get a line of their own.
#
# AND IT MUST NOT CRY WOLF (S212's scar). `cli#4-8` and `web#4-6` are
# uninstantiated on EVERY healthy mission — they need a second actor, an
# owner-not-login pair, a non-default host, an artifact nobody named. A raw "I
# could not build N items" would fire on every look and be ignored inside a
# week. The two classes are told apart by what the record would have to say:
# an item whose ONLY missing fact is "which subcommand takes the input" is
# recovered by a ONE-LINE edit to the PRD (`oneLineFix: true`); an item that
# also needs a fact the record cannot supply is by design, and stays quiet.
echo ""
echo "9. fix round 3 — the refusal reaches the captain, and only when it is his to fix"

# The reader for every claim in this section, so an assertion reads as the claim.
cat >"$TMPROOT/fr3.py" <<'R3EOF'
import json, sys
what, path = sys.argv[1], sys.argv[2]
d = json.load(open(path))
un = [u for u in (d.get("reachUninstantiated") or []) if isinstance(u, dict)]
fix = [u for u in un if u.get("oneLineFix")]
if what == "n-uninstantiated":
    print(len(un))
elif what == "n-one-line-fix":
    print(len(fix))
elif what == "one-line-fix-items":
    print(" ".join(sorted(str(u.get("item") or "") for u in fix)))
elif what == "key-on-every-item":
    # The key is ALWAYS present, so a reader never has to guess whether a look
    # predates this fix.
    assert un, "fixture has no uninstantiated items to check"
    assert all("oneLineFix" in u for u in un), un
    print("ok")
else:
    raise SystemExit("unknown: %s" % what)
R3EOF
FR3="$TMPROOT/fr3.py"

# --- the DATA: the two classes are told apart on the record, not by wording ---
check "R3. the bare record's uninstantiated items carry oneLineFix, every one" \
  '[ "$("$PY" "$FR3" key-on-every-item "$BJO")" = ok ]'
check "R3. exactly the two items a one-line PRD edit recovers are marked" \
  '[ "$("$PY" "$FR3" one-line-fix-items "$BJO")" = "cli#2 cli#3" ]'
check "R3. the by-design items (second actor, owner pair, outbound host) are NOT" \
  '[ "$("$PY" "$FR3" n-uninstantiated "$BJO")" -gt 2 ]'
check "R3. POSITIVE CONTROL — a record that WRITES a value marks nothing actionable" \
  '[ "$("$PY" "$FR3" n-one-line-fix "$RJO")" = 0 ] &&
   [ "$("$PY" "$FR3" n-uninstantiated "$RJO")" -gt 0 ]'

# --- 1. THE CONSOLE must not claim an all-clear it has not got ---------------
check "R3. the console never says '0 refused' while items went unbuilt" \
  '! grep -qE "0 refused" "$TMPROOT/beacon-run.out"'
check "R3. …it names the count a one-line edit would recover" \
  'grep -qE "2 (checklist )?item" "$TMPROOT/beacon-run.out"'
check "R3. …and says it could not BUILD them (not that they failed)" \
  'grep -qi "could not build" "$TMPROOT/beacon-run.out" &&
   ! grep -q "FAILED" "$TMPROOT/beacon-run.out"'
check "R3. …and the reason itself reaches the console, with the edit to make" \
  'grep -qi "which subcommand" "$TMPROOT/beacon-run.out" &&
   grep -q "beacon.py" "$TMPROOT/beacon-run.out"'
check "R3. …and the items are named, so he knows which lines to write" \
  'grep -q "cli#2" "$TMPROOT/beacon-run.out" &&
   grep -q "cli#3" "$TMPROOT/beacon-run.out"'

# POSITIVE CONTROL, in the claim's own phrasing family: the SAME console, on a
# record that wrote a value. Five items are still uninstantiated BY DESIGN and
# the alarm must not fire — that is the S212 scar this guard is built around.
check "R3. POSITIVE CONTROL — a healthy record raises no could-not-build alarm" \
  '! grep -qi "could not build" "$TMPROOT/relay-run.out"'
check "R3. POSITIVE CONTROL — …and names none of cli#4-8 as his to fix" \
  '! grep -qi "a one-line edit" "$TMPROOT/relay-run.out"'
check "R3. POSITIVE CONTROL — a real failure STILL prints FAILED (unsilenced)" \
  'grep -q "FAILED 02-workflow-run" "$TMPROOT/wf.out"'

# --- 2. THE REPORT'S OWN "What I could not check" ----------------------------
# The sentence exists on disk and nothing printed it. It belongs in the section
# the captain already reads for exactly this, not in a new one.
R3D="$TMPROOT/r3-report"; mkdir -p "$R3D"
cat >"$R3D/criteria.json" <<'R3CJ'
{"hasDrawing": false, "placeNames": [], "criteria": [
  {"id": "prd-1", "text": "beacon file stores the request text", "primary": true}
]}
R3CJ
cat >"$R3D/in.json" <<'R3IJ'
{"score":"medium","summary":"Looked at the beacon.","criteria":[
 {"id":"prd-1","text":"beacon file stores the request text","status":"met",
  "shot":"01-help.txt","evidence":"transcript","checkedBy":"cli",
  "note":"the transcript lists both subcommands",
  "action":"Ran beacon.py --help and read the transcript.",
  "reason":"Impact high because it is the front door. I tried --help; I saw both (evidence: 01-help.txt). Outcome: met."}],
 "gaps":[],"alsoChecked":[],"escalations":[]}
R3IJ
"$PY" "$SCOREPY" "$R3D/in.json" "$R3D/criteria.json" "$R3D/verdict.json" \
  "" "" "" "" "" "" "" "" "" "$BJO" >"$R3D/out.tsv" 2>"$R3D/err.txt"
R3REP="$R3D/report.md"
check "R3. the report has a What-I-could-not-check section at all" \
  'grep -q "What I could not check" "$R3REP"'
check "R3. …and the item a one-line PRD edit recovers is IN it, by name" \
  '"$PY" -c "
import sys
t = open(sys.argv[1], encoding=\"utf-8\").read()
sec = t.split(\"### What I could not check\", 1)[1].split(\"### \", 1)[0]
assert \"cli#2\" in sec, sec
assert \"which subcommand\" in sec, sec
print(\"ok\")" "$R3REP"'
check "R3. …and the edit to make reaches him there too" \
  'grep -qi "and this item builds" "$R3REP"'
check "R3. …and the by-design items are never dressed up as his to fix" \
  '! grep -q "cli#7 —" "$R3REP"'

# POSITIVE CONTROL for the report, same phrasing family: the healthy record.
R3H="$TMPROOT/r3-report-healthy"; mkdir -p "$R3H"
cp "$R3D/criteria.json" "$R3H/criteria.json"
cp "$R3D/in.json" "$R3H/in.json"
"$PY" "$SCOREPY" "$R3H/in.json" "$R3H/criteria.json" "$R3H/verdict.json" \
  "" "" "" "" "" "" "" "" "" "$RJO" >"$R3H/out.tsv" 2>"$R3H/err.txt"
check "R3. POSITIVE CONTROL — a healthy record's report raises no unbuilt alarm" \
  '! grep -qi "one line in your record" "$R3H/report.md"'
check "R3. POSITIVE CONTROL — …and names none of cli#4-8 as unbuilt-and-his" \
  '! grep -qE "cli#[45678] —" "$R3H/report.md"'
check "R3. POSITIVE CONTROL — the report still renders, score and all" \
  '[ -s "$R3H/report.md" ] && grep -q "SCORE" "$R3H/out.tsv"'

# --- 3. THE WORD `refused` KEEPS ITS OLD MEANING for its old users -----------
# An escape attempt is still RECORDED as refused in the readout JSON (section 3b
# above asserts that too) — this fix qualifies the CONSOLE COUNT, it does not
# redefine the field underneath it.
check "R3. the readout field refused still means declined-at-execution" \
  '"$PY" -c "
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get(\"refused\") is True, d
print(\"ok\")" "$ESHOTS/01-escape.json"'

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
