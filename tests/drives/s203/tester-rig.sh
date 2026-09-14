#!/usr/bin/env bash
# ============================================================================
# S203 TESTER RIG — a REAL Verify look by a LIVE Number One.
#
#   bash tests/drives/s203/tester-rig.sh up     # provision, leave it up
#   bash tests/drives/s203/tester-rig.sh down   # kill by recorded pid
#
# What is REAL here: the app (a node http server, no deps), the git branch and
# the PULL REQUEST on roferg/lcars-mp-fixture, the GitHub issue, `lcars launch`
# (its inspector is a live copilot `launch` worker), headless Chrome via
# xo-drive.js, the `number-one` worker, and the label + comment xo.sh writes.
# NOTHING in the evaluate path is stubbed.
#
# THE PLANTED CONTRADICTION: the holodeck drawing names FOUR places —
# #app-header, #batch-list, #add-batch and #status-line. The built app has the
# first three and DELIBERATELY LACKS #status-line, and the plan's ticket
# criterion for it is `drawnAt: "#status-line"`. It is a TICKET criterion, not
# a PRD primary one, so by the score matrix the honest answer is MEDIUM — a
# HIGH would be a failure of the look.
#
# THE SILENCE TEST: the app also carries #site-footer and a teal ADD button,
# neither of which the drawing mentions at all. Those must come back as
# interpretations / also-checked, never as gaps.
#
# NEVER a bare ./install.sh: the skills are symlinked into a throwaway $HOME
# this rig owns and deletes.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
OUT="${LCARS_S203_RIG_OUT:-${TMPDIR:-/tmp}/lcars-s203-tester}"
ENVF="$OUT/rig.env"
FIXTURE_REPO="roferg/lcars-mp-fixture"
MID="lcars-20260913-s203"
BRANCH="lcars/$MID-grout"

down() {
  [ -f "$ENVF" ] || { echo "no rig.env at $ENVF"; return 0; }
  . "$ENVF"
  for pid in ${RIG_PIDS:-}; do kill "$pid" 2>/dev/null && echo "  TERM $pid"; done
  ( cd "$RIG_FIXTURE" 2>/dev/null && HOME="$RIG_HOME" bash "$REPO/skills/lcars-launch/launch.sh" "$MID" --stop ) 2>&1 | tail -2
}
case "${1:-up}" in down) down; exit 0 ;; esac

REAL_COPILOT="${LCARS_S203_COPILOT:-$(command -v copilot || true)}"
REAL_CLAUDE="${LCARS_S203_CLAUDE:-$(command -v claude || true)}"
[ -n "$REAL_COPILOT" ] || { echo "no copilot CLI on PATH"; exit 77; }

rm -rf "$OUT"; mkdir -p "$OUT/bin"
: >"$OUT/worker.argv.log"

# ---- the cold-worker wrapper: LIVE for every role, argv logged -------------
mk_wrapper() { # name real-bin
  cat >"$OUT/bin/$1" <<EOF
#!/usr/bin/env bash
ROLE="\${LCARS_WORKER_ROLE:-<unset>}"
{
  echo "=== \$(date -u +%FT%TZ) cli=$1 role=\$ROLE ==="
  n=0; for a in "\$@"; do n=\$((n+1)); printf '  argv[%d] %s\n' "\$n" "\$a"; done
} >>"$OUT/worker.argv.log"
CLEAN="\$(printf '%s' "\$PATH" | tr ':' '\n' | grep -vxF "$OUT/bin" | paste -sd: -)"
echo "=== \$(date -u +%FT%TZ) LIVE $1 role=\$ROLE ===" >>"$OUT/worker.out.log"
exec env PATH="\$CLEAN" "$2" "\$@" \
   > >(tee -a "$OUT/worker.out.log") 2> >(tee -a "$OUT/worker.out.log" >&2)
EOF
  chmod +x "$OUT/bin/$1"
}
mk_wrapper copilot "$REAL_COPILOT"
[ -n "$REAL_CLAUDE" ] && mk_wrapper claude "$REAL_CLAUDE"

# ---- the sandbox app, on a real branch, with a real PR ---------------------
FIXTURE="$OUT/fixture"
gh repo clone "$FIXTURE_REPO" "$FIXTURE" -- -q >/dev/null 2>&1 \
  || { echo "clone failed"; exit 77; }
cd "$FIXTURE" || exit 77
git checkout -q -b "$BRANCH"
mkdir -p app

cat >app/package.json <<'PJ'
{
  "name": "grout-tracker",
  "version": "0.1.0",
  "private": true,
  "scripts": { "dev": "node server.js" }
}
PJ

cat >app/server.js <<'SJ'
const http = require('http');
const fs = require('fs');
const path = require('path');
const port = process.env.PORT || 4319;
http.createServer((req, res) => {
  const f = path.join(__dirname, 'index.html');
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(fs.readFileSync(f));
}).listen(port, '127.0.0.1', () => {
  console.log('grout tracker listening on http://localhost:' + port);
});
SJ

# The BUILT app. #status-line is DELIBERATELY ABSENT (the planted
# contradiction). #site-footer and the teal ADD are things the drawing never
# mentions (the silence test).
cat >app/index.html <<'IH'
<!doctype html><meta charset="utf-8"><title>Grout Tracker</title>
<style>
 body{background:#0b0f14;color:#e8e8e8;font:15px/1.5 system-ui;margin:0;padding:0}
 #app-header{background:#e08a3c;color:#10131a;padding:14px 20px;font:700 20px system-ui;letter-spacing:.08em}
 main{padding:20px}
 #batch-list{background:#141b24;padding:14px 20px;margin:0;list-style:none;border-left:4px solid #e08a3c}
 #batch-list li{padding:6px 0;border-bottom:1px solid #22303c}
 #batch-row{margin-top:18px;display:flex;gap:10px}
 #batch-input{background:#141b24;border:1px solid #2a3a49;color:#e8e8e8;padding:10px 12px;flex:1}
 #add-batch{background:#5aa6b8;color:#04121a;border:0;padding:10px 22px;font:700 14px system-ui;cursor:pointer}
 #site-footer{margin-top:40px;padding:14px 20px;color:#6d8393;border-top:1px solid #22303c;font-size:12px}
</style>
<div id="app-header">GROUT TRACKER</div>
<main>
  <ul id="batch-list">
    <li>B-1041 &middot; sanded &middot; charcoal</li>
    <li>B-1042 &middot; unsanded &middot; alabaster</li>
    <li>B-1043 &middot; epoxy &middot; slate</li>
  </ul>
  <div id="batch-row">
    <input id="batch-input" placeholder="new batch code">
    <button id="add-batch">ADD BATCH</button>
  </div>
</main>
<div id="site-footer">grout tracker &middot; sandbox build</div>
<script>
 document.getElementById('add-batch').addEventListener('click', function () {
   var v = document.getElementById('batch-input').value.trim();
   if (!v) return;
   var li = document.createElement('li');
   li.textContent = v + ' · new · unmixed';
   document.getElementById('batch-list').appendChild(li);
   document.getElementById('batch-input').value = '';
 });
</script>
IH

git add -A
git -c user.email=t@t -c user.name=t commit -qm "the grout tracker board"
git push -q -u origin "$BRANCH" 2>&1 | tail -1

PR_URL="$(gh pr create --repo "$FIXTURE_REPO" --head "$BRANCH" --base main \
  --title "S203 fixture — the grout tracker board" \
  --body "S203 tester fixture. Closed at teardown." 2>&1 | grep -o 'https://github.com/[^ ]*')"
[ -n "$PR_URL" ] || { echo "pr create failed"; exit 77; }
ISSUE="$(gh issue create --repo "$FIXTURE_REPO" \
  --title "S203 fixture — the grout tracker board" \
  --body "S203 tester fixture Mission at Verify. Closed at teardown." \
  2>/dev/null | sed -n 's|.*/issues/\([0-9]*\).*|\1|p')"
[ -n "$ISSUE" ] || { echo "issue create failed"; exit 77; }
gh issue edit "$ISSUE" --repo "$FIXTURE_REPO" --add-label "lcars:mission,lcars:verify" >/dev/null 2>&1

# ---- the repo config + the planted Verify mission --------------------------
python3 - "$FIXTURE" "$OUT/bin/copilot" "$MID" "$ISSUE" "$PR_URL" "$BRANCH" <<'PYEOF' || exit 77
import json, os, sys
root, wbin, mid, issue, prurl, branch = sys.argv[1:7]
L = os.path.join(root, ".git", "lcars")
os.makedirs(L, exist_ok=True)
json.dump({"cloneId": "s203-tester", "model": "copilot",
           "projectName": "lcars-mp-fixture", "contextFile": "CONTEXT.md",
           "stack": "node", "testCommand": "true",
           "comprehensionBudget": "3", "lcarsVersion": "2026.9.6",
           "workerBin": wbin, "created": "2026-09-13T10:00:00Z"},
          open(os.path.join(L, "config.json"), "w"), indent=2)

m = os.path.join(L, "missions", mid)
os.makedirs(os.path.join(m, "attachments"), exist_ok=True)

# state.json: ONE FIELD PER LINE (the writer refuses anything else).
lines = ['{']
fields = [
    ('id', mid), ('type', 'feature'),
    ('title', 'The grout batch board'),
    ('stage', 'verify'),
    ('branch', branch),
    ('prUrl', prurl),
    ('prNumber', prurl.rsplit('/', 1)[-1]),
    ('created', '2026-09-13T10:00:00Z'),
]
for k, v in fields:
    lines.append('  "%s": %s,' % (k, json.dumps(v)))
lines.append('  "githubIssue": %s' % json.dumps(int(issue)))
lines.append('}')
open(os.path.join(m, "state.json"), "w").write("\n".join(lines) + "\n")
json.load(open(os.path.join(m, "state.json")))

open(os.path.join(m, "prd.md"), "w").write("""# The grout batch board

## 1. Problem
The tiler keeps batch codes on a scrap of card and loses them between rooms.

## 2. Acceptance criteria
- The board shows every recorded grout batch in one list on the page.
- A new batch can be added from the board itself, without leaving the page.
- The board names itself in a header so the tiler knows what he is looking at.

## 3. Out of scope
Photographs, pricing, anything that leaves the page.
""")

json.dump({"tickets": [
  {"id": "t-1", "title": "The batch list", "changesScreenAppearance": True,
   "acceptanceCriteria": [
     {"text": "The batch list is the first thing under the header.",
      "drawnAt": "#batch-list, directly beneath #app-header"}]},
  {"id": "t-2", "title": "Adding a batch", "changesScreenAppearance": True,
   "acceptanceCriteria": [
     {"text": "An ADD BATCH button sits to the right of the input.",
      "drawnAt": "#add-batch, right of #batch-input"}]},
  {"id": "t-3", "title": "The status line", "changesScreenAppearance": True,
   "acceptanceCriteria": [
     {"text": "A status line beneath the add row shows the current mix ratio.",
      "drawnAt": "#status-line, beneath #batch-row"}]},
  {"id": "t-4", "title": "Persistence", "changesScreenAppearance": False,
   "acceptanceCriteria": [
     {"text": "Batches survive a restart.", "notVisual": True}]},
]}, open(os.path.join(m, "plan.json"), "w"), indent=2)

# The holodeck drawing. It NAMES #status-line. The build has no such element.
open(os.path.join(m, "attachments", "attachment-01.html"), "w").write("""<!doctype html>
<meta charset="utf-8"><title>Grout Tracker — holodeck</title>
<style>
 body{background:#0b0f14;color:#e8e8e8;font:15px system-ui;margin:0}
 #app-header{background:#e08a3c;color:#10131a;padding:14px 20px;font-weight:700}
 #batch-list{background:#141b24;padding:14px 20px;list-style:none}
 #batch-row{display:flex;gap:10px;margin-top:18px}
 #add-batch{background:#5aa6b8;border:0;padding:10px 22px}
 #status-line{margin-top:16px;color:#e08a3c;font-weight:700}
</style>
<div id="app-header">GROUT TRACKER</div>
<ul id="batch-list"><li>B-1041</li><li>B-1042</li></ul>
<div id="batch-row"><input id="batch-input"><button id="add-batch">ADD BATCH</button></div>
<div id="status-line">MIX RATIO 3:1 &middot; 2 BATCHES OPEN</div>
""")

open(os.path.join(m, "attachments", "attachment-02.md"), "w").write("""# Concept — the grout batch board

One screen. The tiler opens it with wet hands and reads it from two metres away.

Top to bottom, the drawing's four places:

1. **#app-header** — an orange band naming the tool, GROUT TRACKER.
2. **#batch-list** — every recorded batch, one line each, directly under the header.
3. **#batch-row** — an input and an **#add-batch** button to its right.
4. **#status-line** — beneath the add row, in orange, the current mix ratio and
   how many batches are open. This is the line he actually reads across the room;
   without it the board is a list he has to walk up to.

The drawing says nothing about a footer, and nothing about what colour the ADD
button is — those are the builder's call.
""")
print(m)
PYEOF

# ---- the throwaway HOME symlink farm --------------------------------------
FAKEHOME="$OUT/home"
mkdir -p "$FAKEHOME/.claude/skills"
for d in "$REPO"/skills/*/; do
  ln -sfn "${d%/}" "$FAKEHOME/.claude/skills/$(basename "${d%/}")"
done
cp -R "$HOME/.gitconfig" "$FAKEHOME/.gitconfig" 2>/dev/null || true
mkdir -p "$FAKEHOME/.config"
cp -R "$HOME/.config/gh" "$FAKEHOME/.config/gh" 2>/dev/null || true
cp -R "$HOME/.copilot" "$FAKEHOME/.copilot" 2>/dev/null || true

cat >"$ENVF" <<EOF
RIG_OUT="$OUT"
RIG_FIXTURE="$FIXTURE"
RIG_HOME="$FAKEHOME"
RIG_BIN="$OUT/bin"
RIG_MID="$MID"
RIG_BRANCH="$BRANCH"
RIG_ISSUE="$ISSUE"
RIG_PR="$PR_URL"
RIG_FIXTURE_REPO="$FIXTURE_REPO"
RIG_MDIR="$FIXTURE/.git/lcars/missions/$MID"
RIG_PIDS=""
EOF
echo "  rig.env:  $ENVF"
echo "  fixture:  $FIXTURE"
echo "  mission:  $MID  (issue #$ISSUE, PR $PR_URL)"
echo "  branch:   $BRANCH"
