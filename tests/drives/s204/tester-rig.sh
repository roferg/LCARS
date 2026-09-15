#!/usr/bin/env bash
# ============================================================================
# S204 TESTER RIG — the FIX ROUND, driven for real.
#
#   bash tests/drives/s204/tester-rig.sh up [tag] [gaps]
#   bash tests/drives/s204/tester-rig.sh down [tag]
#
# Descended from tests/drives/s203/tester-rig.sh (same app, same drawing, same
# throwaway $HOME symlink farm, same LIVE copilot wrapper). Two differences:
#
#   1. TWO planted contradictions instead of one, so ONE round can hold one gap
#      and (when the tester sabotages it) fail another:
#        • #status-line   — drawn beneath #batch-row, ABSENT from the build
#        • #batch-count   — drawn inside #app-header, ABSENT from the build
#   2. `tag` lets several rounds coexist (mission ids, branches, PRs).
#
# THE SILENCE TEST survives: #site-footer and the teal ADD colour are things
# the drawing never mentions. They must come back as interpretations, never as
# filed bugs.
#
# NEVER a bare ./install.sh.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TAG="${2:-a}"
GAPS="${3:-2}"
OUT="${LCARS_S204_RIG_OUT:-${TMPDIR:-/tmp}/lcars-s204-tester-$TAG}"
ENVF="$OUT/rig.env"
FIXTURE_REPO="roferg/lcars-mp-fixture"
MID="lcars-20260913-s204$TAG"
BRANCH="lcars/$MID-grout"

down() {
  [ -f "$ENVF" ] || { echo "no rig.env at $ENVF"; return 0; }
  . "$ENVF"
  for pid in ${RIG_PIDS:-}; do kill "$pid" 2>/dev/null && echo "  TERM $pid"; done
  ( cd "$RIG_FIXTURE" 2>/dev/null && HOME="$RIG_HOME" bash "$REPO/skills/lcars-launch/launch.sh" "$MID" --stop ) 2>&1 | tail -2
}
case "${1:-up}" in down) down; exit 0 ;; esac

# RESOLVE THE REAL COPILOT BINARY — NOT another shim. (2026-09-15)
#
# `command -v copilot` is NOT safe here. On this machine it resolves to
#   ~/Library/Application Support/Code/.../github.copilot-chat/copilotCli/copilot
# which is VS CODE'S OWN shim: a /bin/sh script that launches Code Helper
# running copilotCLIShim.js. That shim then invokes `copilot` BY NAME, finds
# THIS rig's wrapper on PATH, and the two call each other forever.
#
# It fork-bombed the captain's laptop to 5,538 processes on 2026-09-15 while he
# was working on it — ~5 procs per cycle, until the shell could no longer fork
# at all. The wrapper's own PATH-cleaning does not save us: it strips this bin
# dir before exec, but VS Code's shim re-enters with a fresh PATH that finds it
# again, so the cleaning does not survive the hop.
#
# So: take the first candidate that is a REAL binary, and refuse anything that
# is a known shim. An explicit LCARS_S204_COPILOT still wins, but is checked too.
_copilot_is_shim() {  # a shim re-invokes `copilot` by name; a real binary does not
  case "$1" in *"copilotCLIShim"*|*"Code/User/globalStorage"*|*"/Code Helper"*) return 0 ;; esac
  grep -qs 'copilotCLIShim' "$1" 2>/dev/null
}
REAL_COPILOT=""
for _c in "${LCARS_S204_COPILOT:-}" \
          /opt/homebrew/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot \
          /usr/local/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot \
          "$(command -v copilot || true)"; do
  [ -n "$_c" ] && [ -x "$_c" ] || continue
  if _copilot_is_shim "$_c"; then
    echo "  ⚠ skipping $_c — that is an editor shim, not the copilot binary (it would recurse)" >&2
    continue
  fi
  REAL_COPILOT="$_c"; break
done
[ -n "$REAL_COPILOT" ] && echo "  ◇ real copilot: $REAL_COPILOT" >&2
[ -n "$REAL_COPILOT" ] || { echo "no copilot CLI on PATH"; exit 77; }

rm -rf "$OUT"; mkdir -p "$OUT/bin"
: >"$OUT/worker.argv.log"

# ---- the cold-worker wrapper: LIVE copilot, argv logged, NO claude ---------
cat >"$OUT/bin/copilot" <<EOF
#!/usr/bin/env bash
ROLE="\${LCARS_WORKER_ROLE:-<unset>}"
{
  echo "=== \$(date -u +%FT%TZ) cli=copilot role=\$ROLE ==="
  n=0; for a in "\$@"; do n=\$((n+1)); printf '  argv[%d] %s\n' "\$n" "\$a"; done
} >>"$OUT/worker.argv.log"
CLEAN="\$(printf '%s' "\$PATH" | tr ':' '\n' | grep -vxF "$OUT/bin" | paste -sd: -)"
echo "=== \$(date -u +%FT%TZ) LIVE copilot role=\$ROLE ===" >>"$OUT/worker.out.log"
exec env PATH="\$CLEAN" "$REAL_COPILOT" "\$@" \
   > >(tee -a "$OUT/worker.out.log") 2> >(tee -a "$OUT/worker.out.log" >&2)
EOF
chmod +x "$OUT/bin/copilot"

# A TRIPWIRE, not a shim: if anything tries to spend a Claude leg this session
# it fails loudly and the attempt is recorded. No Claude is authorized for S204.
cat >"$OUT/bin/claude" <<EOF
#!/usr/bin/env bash
echo "=== \$(date -u +%FT%TZ) BLOCKED claude role=\${LCARS_WORKER_ROLE:-<unset>} ===" >>"$OUT/claude-attempts.log"
printf '%s\n' "  argv: \$*" >>"$OUT/claude-attempts.log"
echo "S204 TRIPWIRE: a Claude leg is not authorized for this session." >&2
exit 99
EOF
chmod +x "$OUT/bin/claude"

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

# The BUILT app. #status-line and #batch-count are DELIBERATELY ABSENT (the two
# planted contradictions). #site-footer and the teal ADD are things the drawing
# never mentions (the silence test).
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

mkdir -p test
cat >test/smoke.test.js <<'TJ'
// A seed test so `node --test test/` has a suite on the parent commit. The
// fix worker adds its own; this one only proves the runner runs.
const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
test('the board html is served', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'app', 'index.html'), 'utf8');
  assert.match(html, /id="app-header"/);
});
TJ

git add -A
git -c user.email=t@t -c user.name=t commit -qm "the grout tracker board"
git push -q -u origin "$BRANCH" 2>&1 | tail -1

# THE CHECKOUT MUST NOT SIT ON THE MISSION BRANCH. Bug children land their fix
# commits on the PARENT branch by cherry-pick, and git refuses to write a branch
# that is checked out somewhere — measured 2026-09-13: "cherry-pick failed:
# branch ... is checked out", the child errors, and the resolve-logs driver
# exits. Go back to main once the branch is pushed.
git checkout -q main

PR_URL="$(gh pr create --repo "$FIXTURE_REPO" --head "$BRANCH" --base main \
  --title "S204 fixture ($TAG) — the grout tracker board" \
  --body "S204 tester fixture. Closed at teardown." 2>&1 | grep -o 'https://github.com/[^ ]*')"
[ -n "$PR_URL" ] || { echo "pr create failed"; exit 77; }
ISSUE="$(gh issue create --repo "$FIXTURE_REPO" \
  --title "S204 fixture ($TAG) — the grout tracker board" \
  --body "S204 tester fixture Mission at Verify. Closed at teardown." \
  2>/dev/null | sed -n 's|.*/issues/\([0-9]*\).*|\1|p')"
[ -n "$ISSUE" ] || { echo "issue create failed"; exit 77; }
gh issue edit "$ISSUE" --repo "$FIXTURE_REPO" --add-label "lcars:mission,lcars:verify" >/dev/null 2>&1

# ---- the repo config + the planted Verify mission --------------------------
python3 - "$FIXTURE" "$OUT/bin/copilot" "$MID" "$ISSUE" "$PR_URL" "$BRANCH" "$GAPS" <<'PYEOF' || exit 77
import json, os, sys
root, wbin, mid, issue, prurl, branch, gaps = sys.argv[1:8]
gaps = int(gaps)
L = os.path.join(root, ".git", "lcars")
os.makedirs(L, exist_ok=True)
json.dump({"cloneId": "s204-tester", "model": "copilot",
           "projectName": "lcars-mp-fixture", "contextFile": "CONTEXT.md",
           "stack": "node", "testCommand": "node --test",
           "comprehensionBudget": "3", "lcarsVersion": "2026.9.6",
           "workerBin": wbin, "created": "2026-09-13T10:00:00Z"},
          open(os.path.join(L, "config.json"), "w"), indent=2)

m = os.path.join(L, "missions", mid)
os.makedirs(os.path.join(m, "attachments"), exist_ok=True)

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

tickets = [
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
  {"id": "t-5", "title": "The batch count in the header",
   "changesScreenAppearance": True,
   "acceptanceCriteria": [
     {"text": "The header carries a count of how many batches are on the board.",
      "drawnAt": "#batch-count, inside #app-header"}]},
  {"id": "t-4", "title": "Persistence", "changesScreenAppearance": False,
   "acceptanceCriteria": [
     {"text": "Batches survive a restart.", "notVisual": True}]},
]
if gaps < 2:
    tickets = [t for t in tickets if t["id"] != "t-5"]
json.dump({"tickets": tickets}, open(os.path.join(m, "plan.json"), "w"), indent=2)

count_html = ('<span id="batch-count">3 BATCHES</span>' if gaps >= 2 else '')
count_css = ('#batch-count{float:right;font-weight:700}\n' if gaps >= 2 else '')
count_doc = ("""
5. **#batch-count** — inside the header, at its right-hand end, how many
   batches are on the board right now.
""" if gaps >= 2 else "")

open(os.path.join(m, "attachments", "attachment-01.html"), "w").write("""<!doctype html>
<meta charset="utf-8"><title>Grout Tracker — holodeck</title>
<style>
 body{background:#0b0f14;color:#e8e8e8;font:15px system-ui;margin:0}
 #app-header{background:#e08a3c;color:#10131a;padding:14px 20px;font-weight:700}
 #batch-list{background:#141b24;padding:14px 20px;list-style:none}
 #batch-row{display:flex;gap:10px;margin-top:18px}
 #add-batch{background:#5aa6b8;border:0;padding:10px 22px}
 #status-line{margin-top:16px;color:#e08a3c;font-weight:700}
 """ + count_css + """</style>
<div id="app-header">GROUT TRACKER """ + count_html + """</div>
<ul id="batch-list"><li>B-1041</li><li>B-1042</li></ul>
<div id="batch-row"><input id="batch-input"><button id="add-batch">ADD BATCH</button></div>
<div id="status-line">MIX RATIO 3:1 &middot; 2 BATCHES OPEN</div>
""")

open(os.path.join(m, "attachments", "attachment-02.md"), "w").write("""# Concept — the grout batch board

One screen. The tiler opens it with wet hands and reads it from two metres away.

Top to bottom, the drawing's places:

1. **#app-header** — an orange band naming the tool, GROUT TRACKER.
2. **#batch-list** — every recorded batch, one line each, directly under the header.
3. **#batch-row** — an input and an **#add-batch** button to its right.
4. **#status-line** — beneath the add row, in orange, the current mix ratio and
   how many batches are open. This is the line he actually reads across the room;
   without it the board is a list he has to walk up to.
""" + count_doc + """
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
# HEADLESS CHROME NEEDS THE REAL ~/Library. Measured 2026-09-13: under a HOME
# with no Library, Chrome starts and devtools answers, but every Page.navigate
# times out — xo-drive.js reports "INFRA: CDP timeout on Page.navigate" and the
# look scores LOW for a reason that has nothing to do with the app. The product
# runs under the captain's real HOME, so symlinking it is the honest rig.
ln -s "$HOME/Library" "$FAKEHOME/Library" 2>/dev/null || true

# gh keeps its token in the macOS keyring, NOT in ~/.config/gh, so copying that
# directory carries no credential and every copilot spawn dies with
# "No authentication information found". Bake the token into the wrapper so
# even a DETACHED resolve-logs driver inherits it.
GH_TOK="$(gh auth token 2>/dev/null)"
if [ -n "$GH_TOK" ]; then
  printf 'GH_TOKEN=%s\n' "$GH_TOK" > "$OUT/token.env"; chmod 600 "$OUT/token.env"
  TMPW="$OUT/bin/copilot.new"
  { head -1 "$OUT/bin/copilot"
    printf 'export COPILOT_GITHUB_TOKEN=%s\nexport GH_TOKEN=%s\nexport GITHUB_TOKEN=%s\n' "$GH_TOK" "$GH_TOK" "$GH_TOK"
    tail -n +2 "$OUT/bin/copilot"
  } > "$TMPW" && mv "$TMPW" "$OUT/bin/copilot" && chmod +x "$OUT/bin/copilot"
fi

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
