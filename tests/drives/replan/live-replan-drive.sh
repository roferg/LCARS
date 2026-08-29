#!/usr/bin/env bash
# The S178 live re-plan drive — does a LIVE planner treat a review objection as a
# PATCH, or does it rewrite the dependency graph?
#
#   tests/drives/replan/live-replan-drive.sh [<lcars-tree>] [<label>]
#
# COPILOT ONLY. Copilot is free; `claude` is billed and is BLOCKED by a PATH shim
# that exits loudly, so a run that would have spent money fails instead of
# quietly costing. The shim log is reported every run.
#
# WHY THIS EXISTS. The over-correction is MODEL BEHAVIOUR. A fixture can prove
# the deterministic guard fires; it CANNOT prove the prompt works, because the
# thing under test is what a live planner chooses to do when corrected. S178 ran
# this against pristine HEAD (3/3 FAIL) before building anything, which is how we
# learned the live failure is graph CHURN and not the doc's 14-deep chain — see
# tests/fixtures/replan/live/README.md. Re-run it whenever the Plan prompt, the
# revision contract, or the guard changes.
#
# NOTE the drive stages plan-under-review.json itself. In production review_fail
# writes that token when it bounces a Mission back to Plan; this rig hand-builds
# the mission instead, and WITHOUT the token the revision contract and the guard
# both correctly stand down and you measure pre-S178 behaviour. (Measured: three
# runs wasted exactly that way.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
FIX="$REPO/tests/fixtures/replan/live"
TREE="${1:-$REPO}"
LABEL="${2:-live}"
WORK="${LCARS_DRIVE_DIR:-${TMPDIR:-/tmp}}/s178-replan-$LABEL.$$"
ID=lcars-replan-drive
MODEL="${LCARS_WORKER_MODEL:-claude-opus-4.8}"

command -v copilot >/dev/null 2>&1 || { echo "copilot not on PATH — this drive is copilot-only."; exit 2; }

mkdir -p "$WORK/shim" "$WORK/out"
cat >"$WORK/shim/claude" <<'EOF'
#!/bin/sh
echo "S178 DRIVE: refused to spawn \`claude\` (billed). This drive is COPILOT ONLY." >&2
echo "claude $*" >> "${S178_SHIM_LOG:-/dev/null}"
exit 97
EOF
cat >"$WORK/shim/gh" <<'EOF'
#!/bin/sh
# offline forge stub — this drive measures the PLANNER, not GitHub.
case "$1" in auth) echo "Logged in as replan-drive";; repo) echo "s178/drive";; issue) echo 1;; api) echo "{}";; esac
exit 0
EOF
chmod +x "$WORK/shim/claude" "$WORK/shim/gh"

# --- a small real repo the objection is TRUE of (no .overlay/.modal anywhere) --
R="$WORK/repo"; mkdir -p "$R/src" "$R/test"
cat >"$R/src/styles.css" <<'EOF'
:root { --bg: #0b0b0f; --fg: #e8e8f0; }
body { background: var(--bg); color: var(--fg); }
.panel { padding: 16px; border: 1px solid #2a2a35; }
.row { display: flex; justify-content: space-between; }
.row-label { opacity: 0.8; }
EOF
cat >"$R/src/panel.js" <<'EOF'
export function renderPanel(settings) {
  const el = document.createElement('div');
  el.className = 'panel';
  for (const [key, value] of Object.entries(settings)) {
    const row = document.createElement('div');
    row.className = 'row';
    const label = document.createElement('span');
    label.className = 'row-label';
    label.textContent = key;
    const val = document.createElement('span');
    val.textContent = String(value);
    row.append(label, val);
    el.appendChild(row);
  }
  return el;
}
EOF
cat >"$R/src/store.js" <<'EOF'
const DEFAULTS = { theme: 'dark', notifications: true, density: 'comfortable' };
export function loadSettings() { return { ...DEFAULTS }; }
EOF
cat >"$R/src/app.js" <<'EOF'
import { renderPanel } from './panel.js';
import { loadSettings } from './store.js';
export function boot(root) { root.appendChild(renderPanel(loadSettings())); }
EOF
printf '{\n  "name": "s178-drive",\n  "type": "module",\n  "scripts": { "test": "node --test test/" }\n}\n' >"$R/package.json"
printf 'export function noop() {}\n' >"$R/test/placeholder.js"
cat >"$R/CONTEXT.md" <<'EOF'
# s178-drive — settings panel
`src/app.js` boots, `src/panel.js` renders rows, `src/store.js` holds defaults,
`src/styles.css` holds all styling. Tests: `node --test test/`.
EOF
( cd "$R" && git init -q && git add -A && git -c user.email=d@d -c user.name=d commit -qm init ) || exit 1

# init must run INSIDE the fixture repo — it writes .git/lcars/config.json, and
# without it run.sh seds a file that is not there and the drive prints a stray
# error on every run.
( cd "$R" && PATH="$WORK/shim:$PATH" LCARS_GH_BIN="$WORK/shim/gh" \
    bash "$TREE/skills/lcars-init/init.sh" ) >"$WORK/out/init.log" 2>&1 || true
[ -f "$R/.git/lcars/config.json" ] || echo "  ! init wrote no config.json — see $WORK/out/init.log"
( cd "$R" && git branch "lcars/$ID" ) 2>/dev/null

D="$R/.git/lcars/missions/$ID"; mkdir -p "$D"
cp "$FIX/pre-review-plan.json" "$D/plan.json"
cp "$FIX/pre-review-plan.json" "$D/plan-under-review.json"   # what review_fail writes
cp "$FIX/plan-review-1.json"   "$D/plan-review-1.json"
cp "$FIX/prd.md" "$FIX/validated-plan.md" "$D/" 2>/dev/null || true
cat >"$D/state.json" <<EOF
{
  "id": "$ID", "type": "feature", "origin": "file",
  "title": "Settings panel v2", "created": "2026-08-28T19:00:00Z",
  "stage": "plan", "model": "claude-sonnet", "workerBin": "copilot",
  "githubIssue": 1, "planReviewRound": 1,
  "branch": "lcars/$ID", "base": "main"
}
EOF

echo "=== S178 live re-plan drive · label=$LABEL · tree=$TREE · model=$MODEL ==="
( cd "$R" && PATH="$WORK/shim:$PATH" \
    S178_SHIM_LOG="$WORK/out/shim.log" \
    LCARS_GH_BIN="$WORK/shim/gh" \
    LCARS_WORKER_BIN=copilot LCARS_WORKER_MODEL="$MODEL" \
    bash "$TREE/skills/lcars-run/run.sh" plan --mission "$ID" ) >"$WORK/out/run.out" 2>&1
rc=$?
tail -8 "$WORK/out/run.out"
if [ -s "$WORK/out/shim.log" ]; then
  echo "!! CLAUDE WAS INVOKED — this run was NOT zero-spend:"; cat "$WORK/out/shim.log"
else
  echo "zero-spend confirmed: claude never invoked"
fi

"${LCARS_PYTHON_BIN:-python3}" - "$FIX/pre-review-plan.json" "$D/plan.json" <<'PY'
import json, sys
def deps(p):
    return {t["id"]: sorted(t.get("dependencies", [])) for t in json.load(open(p))}
try:
    before, after = deps(sys.argv[1]), deps(sys.argv[2])
except Exception as e:
    print("no comparable plan on disk:", e); raise SystemExit(1)
# The objection asked for exactly ONE edge: t-004 into t-006.
expect = {i: sorted(set(d) | ({"t-004"} if i == "t-006" else set())) for i, d in before.items()}
print("=== dependency graph ===")
for i in sorted(set(before) | set(after)):
    print("  %-6s %-24s -> %s" % (i, before.get(i, "(absent)"), after.get(i, "(absent)")))
if set(after) != set(before):
    print("VERDICT: UNCOMPARABLE — ticket set changed:", sorted(set(after) ^ set(before)))
    raise SystemExit(0)
added   = {i: sorted(set(after[i]) - set(before[i])) for i in before if set(after[i]) - set(before[i])}
removed = {i: sorted(set(before[i]) - set(after[i])) for i in before if set(before[i]) - set(after[i])}
print("  edges ADDED:  ", added or "none")
print("  edges REMOVED:", removed or "none")
print("VERDICT:", "PASS — exactly the one requested edge"
      if after == expect else "FAIL — over-correction / unrequested rewrite")
PY
echo "artifacts: $WORK/out"
exit 0
