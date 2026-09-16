#!/usr/bin/env bash
# ============================================================================
# S211 TESTER RIG — the project's own tests as evidence, driven for real.
#
#   bash tests/drives/s211/rig.sh up   <variant>   # pass|fail|none|hang|crash
#   bash tests/drives/s211/rig.sh down <variant>
#
# Descended from tests/drives/s204/tester-rig.sh. Differences:
#   * NO GitHub. gh is a stub (LCARS_GH_BIN) — nothing is created on a remote.
#   * The fixture is a LOCAL git repo with a REAL, GENUINELY-RUNNABLE suite.
#     (S211's fixture warning: an existence check is not proof — RUN the thing.)
#   * Five variants, one per testCommand shape the look must survive.
#
# The app: the grout tracker (same shape as S204 so the drawing/criteria are
# familiar). The suite is `node --test` over test/*.test.js — note `node --test
# test/` is NOT the same thing on node 25 (it resolves test/ as a MODULE and
# crashes), which is itself one of our variants.
# NEVER a bare ./install.sh.
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
VARIANT="${2:-pass}"
# R2: one port per variant so several drives can run at once (R1 lost the hang
# leg to a 4331 collision between two concurrent looks).
case "$VARIANT" in pass) PORT=4361;; fail) PORT=4362;; none) PORT=4363;; hang) PORT=4364;; crash) PORT=4365;; *) PORT=4366;; esac
OUT="${LCARS_S211_OUT:-/tmp/s211t/rig-$VARIANT}"
ENVF="$OUT/rig.env"
MID="lcars-20260916-s211$VARIANT"
BRANCH="lcars/$MID-grout"

down() {
  [ -f "$ENVF" ] || { echo "no rig.env at $ENVF"; return 0; }
  . "$ENVF"
  ( cd "$RIG_FIXTURE" 2>/dev/null && HOME="$RIG_HOME" bash "$REPO/skills/lcars-launch/launch.sh" "$MID" --stop ) 2>&1 | tail -2
}
case "${1:-up}" in down) down; exit 0 ;; esac

. "$REPO/tests/drives/lib/real-worker.sh"
REAL_COPILOT="$(lcars_resolve_real_worker copilot "${LCARS_S211_COPILOT:-}")" || exit 77

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
exec env PATH="\$CLEAN" "$REAL_COPILOT" "\$@" \
   > >(tee -a "$OUT/worker.out.log") 2> >(tee -a "$OUT/worker.out.log" >&2)
EOF
chmod +x "$OUT/bin/copilot"

# TRIPWIRE. Zero Claude is authorized for S211.
cat >"$OUT/bin/claude" <<EOF
#!/usr/bin/env bash
echo "=== \$(date -u +%FT%TZ) BLOCKED claude role=\${LCARS_WORKER_ROLE:-<unset>} argv: \$* ===" >>"$OUT/claude-attempts.log"
echo "S211 TRIPWIRE: a Claude leg is not authorized." >&2
exit 99
EOF
chmod +x "$OUT/bin/claude"

# gh: a STUB. Nothing this rig does touches a remote.
cat >"$OUT/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >>"$OUT/gh.log"
case "\$1" in
  issue) case "\$2" in view) echo '{"number":1,"title":"stub","body":"","labels":[],"comments":[]}';; esac;;
  api)   echo '{}';;
esac
exit 0
EOF
chmod +x "$OUT/bin/gh"

FIXTURE="$OUT/fixture"; mkdir -p "$FIXTURE"; cd "$FIXTURE" || exit 77
git init -q -b main .
mkdir -p app test

cat >app/package.json <<'PJ'
{ "name":"grout-tracker","version":"0.1.0","private":true,
  "scripts": { "dev": "node server.js" } }
PJ
cat >app/server.js <<SJ
const http=require('http'),fs=require('fs'),path=require('path');
const port=process.env.PORT||$PORT;
http.createServer((req,res)=>{res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'});
 res.end(fs.readFileSync(path.join(__dirname,'index.html')));})
 .listen(port,'127.0.0.1',()=>console.log('grout tracker listening on http://localhost:'+port));
SJ
# The BUILT app. #status-line is DELIBERATELY ABSENT (a planted visual gap).
cat >app/index.html <<'IH'
<!doctype html><meta charset="utf-8"><title>Grout Tracker</title>
<style>
 body{background:#0b0f14;color:#e8e8e8;font:15px/1.5 system-ui;margin:0}
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
 document.getElementById('add-batch').addEventListener('click',function(){
  var v=document.getElementById('batch-input').value.trim(); if(!v) return;
  var li=document.createElement('li'); li.textContent=v+' · new · unmixed';
  document.getElementById('batch-list').appendChild(li);
  document.getElementById('batch-input').value='';});
</script>
IH

# ---- the suite, per variant ------------------------------------------------
cat >app/store.js <<'ST'
// the persistence the notVisual criterion is about
const fs=require('fs');
exports.save=(f,b)=>fs.writeFileSync(f,JSON.stringify(b));
exports.load=(f)=>fs.existsSync(f)?JSON.parse(fs.readFileSync(f,'utf8')):[];
ST
case "$VARIANT" in
  pass|none)
    cat >test/persist.test.js <<'TJ'
const {test}=require('node:test'); const a=require('node:assert');
const os=require('node:os'),p=require('node:path'),fs=require('node:fs');
const s=require('../app/store');
test('batches survive a restart', () => {
  const f=p.join(os.tmpdir(),'s211-'+Date.now()+'.json');
  s.save(f,[{code:'B-1041'}]); a.deepEqual(s.load(f),[{code:'B-1041'}]); fs.unlinkSync(f);
});
TJ
    cat >test/header.test.js <<'TJ'
const {test}=require('node:test'); const a=require('node:assert');
const fs=require('node:fs'),p=require('node:path');
test('renders the header', () => {
  a.match(fs.readFileSync(p.join(__dirname,'..','app','index.html'),'utf8'),/id="app-header"/);
});
TJ
    TESTCMD='node --test' ;;
  fail)
    cat >test/persist.test.js <<'TJ'
const {test}=require('node:test'); const a=require('node:assert');
const os=require('node:os'),p=require('node:path');
const s=require('../app/store');
test('batches survive a restart', () => {
  // the build forgets: load() is pointed at a fresh file every boot
  const f=p.join(os.tmpdir(),'s211-'+Date.now()+Math.random()+'.json');
  s.save(f,[{code:'B-1041'}]);
  a.deepEqual(s.load(p.join(os.tmpdir(),'s211-other-'+Date.now()+'.json')),[{code:'B-1041'}],
              'the batches were gone after a restart');
});
TJ
    cat >test/header.test.js <<'TJ'
const {test}=require('node:test'); const a=require('node:assert');
const fs=require('node:fs'),p=require('node:path');
test('renders the header', () => {
  a.match(fs.readFileSync(p.join(__dirname,'..','app','index.html'),'utf8'),/id="app-header"/);
});
TJ
    TESTCMD='node --test' ;;
  hang)
    cat >test/persist.test.js <<'TJ'
const {test}=require('node:test');
test('batches survive a restart', async () => { await new Promise(()=>{}); });
TJ
    TESTCMD='node --test --test-timeout=0' ;;
  crash)
    # THE GROUTWORK CLASS: a dangling symlink where the runner should be.
    mkdir -p node_modules/.bin
    ln -sfn /nonexistent/deleted-mission-worktree/vitest node_modules/vitest
    cat >test/persist.test.js <<'TJ'
const {test}=require('node:test'); const a=require('node:assert');
test('batches survive a restart', () => { a.equal(1,1); });
TJ
    cat >crash-runner.js <<'CJ'
// stands in for `vitest` behind node_modules/.bin — the symlink is dangling,
// so the runner dies before a single test is collected. Exactly the shape the
// captain's own groutwork checkout is in.
require('./node_modules/vitest');
CJ
    TESTCMD='node crash-runner.js' ;;
esac

git add -A
git -c user.email=t@t -c user.name=t commit -qm "the grout tracker board"
git checkout -q -b "$BRANCH"
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "mission branch"
git checkout -q main

# ---- config + the planted Verify mission ----------------------------------
[ "$VARIANT" = none ] && TESTCMD=""
python3 - "$FIXTURE" "$OUT/bin/copilot" "$MID" "$BRANCH" "$TESTCMD" <<'PYEOF' || exit 77
import json, os, sys
root, wbin, mid, branch, testcmd = sys.argv[1:6]
L = os.path.join(root, ".git", "lcars"); os.makedirs(L, exist_ok=True)
cfg = {"cloneId":"s211-tester","model":"copilot","projectName":"grout-tracker",
       "contextFile":"CONTEXT.md","stack":"node","comprehensionBudget":"3",
       "lcarsVersion":"2026.9.6","workerBin":wbin,"created":"2026-09-16T10:00:00Z"}
if testcmd: cfg["testCommand"] = testcmd
json.dump(cfg, open(os.path.join(L,"config.json"),"w"), indent=2)
m = os.path.join(L,"missions",mid); os.makedirs(os.path.join(m,"attachments"), exist_ok=True)
json.dump({"id":mid,"type":"feature","title":"The grout batch board","stage":"verify",
           "branch":branch,"prUrl":"https://github.com/roferg/none/pull/1","prNumber":"1",
           "created":"2026-09-16T10:00:00Z","githubIssue":1},
          open(os.path.join(m,"state.json"),"w"), indent=2)
open(os.path.join(m,"prd.md"),"w").write("""# The grout batch board

## 1. Problem
The tiler keeps batch codes on a scrap of card and loses them between rooms.

## 2. Acceptance criteria
- The board shows every recorded grout batch in one list on the page.
- A new batch can be added from the board itself, without leaving the page.
- The board names itself in a header so the tiler knows what he is looking at.

## 3. Out of scope
Photographs, pricing, anything that leaves the page.
""")
json.dump({"tickets":[
 {"id":"t-1","title":"The batch list","changesScreenAppearance":True,
  "acceptanceCriteria":[{"text":"The batch list is the first thing under the header.",
                          "drawnAt":"#batch-list, directly beneath #app-header"}]},
 {"id":"t-2","title":"Adding a batch","changesScreenAppearance":True,
  "acceptanceCriteria":[{"text":"An ADD BATCH button sits to the right of the input.",
                          "drawnAt":"#add-batch, right of #batch-input"}]},
 {"id":"t-3","title":"The status line","changesScreenAppearance":True,
  "acceptanceCriteria":[{"text":"A status line beneath the add row shows the current mix ratio.",
                          "drawnAt":"#status-line, beneath #batch-row"}]},
 {"id":"t-4","title":"Persistence","changesScreenAppearance":False,
  "acceptanceCriteria":[{"text":"Batches survive a restart.","notVisual":True}]},
 {"id":"t-6","title":"CSV export","changesScreenAppearance":False,
  "acceptanceCriteria":[{"text":"The export writes valid CSV with a header row.","notVisual":True}]},
]}, open(os.path.join(m,"plan.json"),"w"), indent=2)
open(os.path.join(m,"attachments","attachment-01.html"),"w").write("""<!doctype html>
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
open(os.path.join(m,"attachments","attachment-02.md"),"w").write("""# Concept — the grout batch board

One screen. The tiler opens it with wet hands and reads it from two metres away.

1. **#app-header** — an orange band naming the tool, GROUT TRACKER.
2. **#batch-list** — every recorded batch, one line each, directly under the header.
3. **#batch-row** — an input and an **#add-batch** button to its right.
4. **#status-line** — beneath the add row, in orange, the current mix ratio and
   how many batches are open.

The drawing says nothing about a footer, and nothing about what colour the ADD
button is — those are the builder's call. Nothing in the drawing shows where a
batch is stored between sessions, or what an export looks like.
""")
print(m)
PYEOF

# ---- the throwaway HOME symlink farm --------------------------------------
FAKEHOME="$OUT/home"; mkdir -p "$FAKEHOME/.claude/skills"
for d in "$REPO"/skills/*/; do ln -sfn "${d%/}" "$FAKEHOME/.claude/skills/$(basename "${d%/}")"; done
ln -s "$HOME/Library" "$FAKEHOME/Library" 2>/dev/null || true
GH_TOK="$(gh auth token 2>/dev/null)"
if [ -n "$GH_TOK" ]; then
  TMPW="$OUT/bin/copilot.new"
  { head -1 "$OUT/bin/copilot"
    printf 'export COPILOT_GITHUB_TOKEN=%s\nexport GH_TOKEN=%s\nexport GITHUB_TOKEN=%s\n' "$GH_TOK" "$GH_TOK" "$GH_TOK"
    tail -n +2 "$OUT/bin/copilot"; } > "$TMPW" && mv "$TMPW" "$OUT/bin/copilot" && chmod +x "$OUT/bin/copilot"
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
RIG_MDIR="$FIXTURE/.git/lcars/missions/$MID"
RIG_TESTCMD="$TESTCMD"
EOF
echo "  rig.env:   $ENVF"
echo "  fixture:   $FIXTURE"
echo "  mission:   $MID   variant=$VARIANT   testCommand=[$TESTCMD]"
# PROVE THE SUITE, do not assume it (the S211 fixture warning).
if [ -n "$TESTCMD" ]; then
  ( cd "$FIXTURE" && timeout 30 bash -c "$TESTCMD" >/dev/null 2>&1; echo "  suite pre-flight exit: $?" )
fi
