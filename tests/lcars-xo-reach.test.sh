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
  "$PY" "$CAGE" 150 bash "$XO" evaluate --mission lcars-20261002-001-abcd \
    --again --because "the test runner is installed now" ) \
  >"$AGAIN" 2>&1
check "--again does NOT say 'already looked'" \
  '! grep -q "already looked" "$AGAIN"'
check "--again journals the supersession WITH the prior score and the reason" \
  'grep -q "superseded" "$MDIR/number-one.jsonl" && grep -q "the test runner is installed now" "$MDIR/number-one.jsonl" && grep -q "\"priorScore\": \"low\"" "$MDIR/number-one.jsonl"'
check "--again needs NO filed logs (the catch-22 is gone)" \
  '[ ! -f "$MDIR/xo/logs.json" ]'

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
