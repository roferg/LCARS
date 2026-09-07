#!/usr/bin/env bash
# S185 STAGE DRIVE — the initialization mission, through `run.sh implement`.
#
# WHY THE STAGE AND NOT `implement-ticket`: every harness in this round that took
# the shortcut entry point was blind to a blocker that made the feature fail on
# the only path a captain actually uses (twice, over two fix rounds). So this
# drive runs the STAGE.
#
# What it proves, on a REAL git repo with a REAL runner (node's built-in
# `node --test`, installed by the machinery under test via the declared setup):
#   L1  the scaffold ticket ESTABLISHES the test system and exits through the
#       audited waiver, with its reason recorded.
#   L2  the setup files are COMMITTED WITH TICKET 1 — so they are present on the
#       PARENT COMMIT for ticket 2. This is the fact the whole honesty contract
#       rests on and it is MEASURED here, not assumed.
#   L3  ticket 2 runs a GENUINE flip-flop against the runner ticket 1 built:
#       the parent leg RAN, went RED, and the tip is GREEN.
#   L4  a ticket whose implementation never LANDS on the committed branch is
#       CAUGHT by the post-commit gate (which really runs).
#
# ZERO worker spend: the worker CLI is a PATH shim carrying COUNTING fakes for
# BOTH `claude` and `copilot`, behind a SPEND FUSE that refuses to run if either
# is missing. Never $LCARS_WORKER_BIN (S159: it loses to state.json workerBin).
set -u

LCARS_SRC="${LCARS_SRC:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
OUTDIR="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s185drive.XXXXXX")}"
KEEP="${KEEP:-0}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }
# S185 fix round 1 — an ESCAPE-AWARE jq-free reader (mirrors run.sh's json_str).
# The naive `sed 's/.*"key"[^"]*"\([^"]*\)".*/\1/p'` stops at the FIRST
# escaped quote, and EVERY command the real detector emits embeds one — so this
# harness was printing (and, in the by-hand leg, RUNNING) a truncated fragment.
tc_of() { # file -> its testCommand, unescaped
  sed -En 's/.*"testCommand"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$1" \
    | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g'
}

command -v npm  >/dev/null 2>&1 || { echo "SKIP: npm not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

# --- SPEND FUSE (S182 rig contract, verbatim) -------------------------------
SHIM="$OUTDIR/shim"; SPEND="$OUTDIR/spend.log"
mkdir -p "$SHIM"; : > "$SPEND"

# The scripted worker. LCARS invokes it as the `claude` CLI adapter; the ROLE and
# the scratch out dir arrive in the environment. It writes ONLY what a real
# unified TDD worker writes: files in the tree (cwd = its ticket worktree),
# result.json, and — for the scaffold ticket — the declared setup.
cat > "$SHIM/claude" <<WORKER
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*) echo "0.0.0-s185-fake"; exit 0 ;;
esac
printf 'SPAWN\tclaude\t%s\t%s\n' "\${LCARS_WORKER_ROLE:-?}" "\${LCARS_TICKET:-?}" >> "$SPEND"
out="\${LCARS_WORK_OUT:-}"
[ -n "\$out" ] || exit 0
prompt="\$2"
# The implement prompt ends with "## Your ticket" and the ticket id on the next
# line (run.sh spawn_worker implement-tdd) — that anchor is the identification.
tid="\$(printf '%s\n' "\$prompt" | awk '/^## Your ticket\$/{getline; print; exit}' | grep -oE 't-[0-9]+' | head -1)"
printf '%s\n' "\$prompt" > "$OUTDIR/prompt.\${tid:-unknown}.txt" 2>/dev/null || :
case "\${LCARS_WORKER_ROLE:-}" in
  implement-tdd) : ;;
  *) exit 0 ;;
esac
case "\$tid" in
  t-001)
    # THE SCAFFOLD TICKET. Declare the test system (harness applies it), and
    # author one real test in the tree at the repo's convention.
    mkdir -p "\$out/setup"
    cat > "\$out/setup/package.json" <<'PJ'
{
  "name": "gf-app",
  "version": "0.0.0",
  "private": true,
  "scripts": { "test": "node --test" }
}
PJ
    printf 'node_modules/\n' > "\$out/setup/.gitignore"
    cat > "\$out/test-setup.json" <<'TS'
{ "package": "", "gap": "this repo has no test system at all", "installCommand": "npm install --no-audit --no-fund" }
TS
    mkdir -p src test
    printf "module.exports.greet = () => 'hello';\n" > src/greet.js
    cat > test/greet.test.js <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { greet } = require('../src/greet.js');
test('greet says hello', () => { assert.strictEqual(greet(), 'hello'); });
JS
    cat > "\$out/result.json" <<'RJ'
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "establish the project skeleton and its test system",
  "newTests": ["test/greet.test.js"], "testEdits": [],
  "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the repo's test system, so its parent commit has no runner for the tests to be red against; the captain watches the suite run at Verify" }
RJ
    ;;
  t-002)
    mkdir -p src test
    if [ "\${S185_DROP_IMPL:-0}" = 1 ]; then
      # The implementation is written where it can never LAND on the committed
      # branch — the post-commit gate must catch that the change is absent.
      printf 'node_modules/\nsrc/add.js\n' > .gitignore
    fi
    printf "module.exports.add = (a, b) => a + b;\n" > src/add.js
    cat > test/add.test.js <<'JS'
const { test } = require('node:test');
const assert = require('node:assert');
const { add } = require('../src/add.js');
test('adds two numbers', () => { assert.strictEqual(add(2, 2), 4); });
JS
    cat > "\$out/result.json" <<'RJ'
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "add() sums two numbers",
  "newTests": ["test/add.test.js"], "testEdits": [],
  "flipFlop": "expected" }
RJ
    ;;
esac
exit 0
WORKER
chmod +x "$SHIM/claude"
cp "$SHIM/claude" "$SHIM/copilot"

fuse() {
  [ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] && return 0
  echo "SPEND FUSE TRIPPED: no counting claude/copilot in '$SHIM' — REFUSING (would bill)" >&2
  exit 1
}
fuse
spawns() { awk '/^SPAWN/{n++} END{print n+0}' "$SPEND"; }

# --- fixture ----------------------------------------------------------------
newrepo() { # name → path (a REAL git repo, one commit, NO test system)
  local p="$OUTDIR/$1"
  rm -rf "$p"; mkdir -p "$p"
  git -C "$p" init -q
  git -C "$p" config user.email t@e.x
  git -C "$p" config user.name  t
  git -C "$p" config commit.gpgsign false
  printf '# gf\n\nA blank project.\n' > "$p/README.md"
  git -C "$p" add -A >/dev/null 2>&1
  git -C "$p" commit -qm "initial commit" >/dev/null 2>&1
  mkdir -p "$p/.git/lcars"
  printf '{\n  "version": 1\n}\n' > "$p/.git/lcars/config.json"
  echo "$p"
}

mkmission() { # repo → mission dir
  local r="$1"
  local md="$r/.git/lcars/missions/init-001"
  mkdir -p "$md/tickets" "$md/manifests"
  cat > "$md/state.json" <<'JSON'
{
  "id": "init-001",
  "missionType": "initialization",
  "type": "feature",
  "title": "Establish the foundation",
  "stage": "implement",
  "branch": "lcars/init-001",
  "base": "__BASE__",
  "workerBin": "claude",
  "workerCli": "claude"
}
JSON
  cat > "$md/approved-plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Project skeleton and test system",
    "description": "Establish the running skeleton and a working test system.",
    "acceptanceCriteria": ["a single command runs the suite"],
    "dependencies": []
  },
  {
    "id": "t-002",
    "title": "add() sums two numbers",
    "description": "One thin slice on top of the foundation.",
    "acceptanceCriteria": ["add(2,2) is 4"],
    "dependencies": ["t-001"]
  }
]
JSON
  cat > "$md/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": null
      }
    ]
  }
]
JSON
  # The mission's recorded base must be this repo's ACTUAL default branch —
  # a mismatched base makes the landing replay cherry-pick onto the wrong ref.
  local base; base="$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || echo main)"
  sed -i.bak "s/__BASE__/$base/" "$md/state.json" && rm -f "$md/state.json.bak"
  printf '## Relevant files\n- src/greet.js\n' > "$md/manifests/t-001.md"
  printf '## Relevant files\n- src/add.js\n' > "$md/manifests/t-002.md"
  printf '# ctx\n' > "$r/CONTEXT.md"
  git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm ctx >/dev/null 2>&1
  echo "$md"
}

stage() { # repo [extra env pairs...] → RC + OUT (the STAGE, not implement-ticket)
  local r="$1"; shift
  OUT="$( cd "$r" && env PATH="$SHIM:$PATH" \
            LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
            LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 \
            LCARS_SETUP_INSTALL_TIMEOUT_SECS=180 \
            "$@" \
            bash "$RUN_SH" implement --mission init-001 2>&1 )"
  RC=$?
}

echo "S185 stage drive — artifacts: $OUTDIR"

# ===========================================================================
# LEG A — the happy path, end to end through the STAGE
# ===========================================================================
REPO="$(newrepo gf-blank)"; MD="$(mkmission "$REPO")"
stage "$REPO"
note "stage rc=$RC · worker sessions: $(spawns)"

if [ -f "$MD/test-command.json" ]; then
  ok "L1a. the scaffold ticket ESTABLISHED a runner (mission-local record written)"
  note "testCommand: $(tc_of "$MD/test-command.json")"
else
  bad "L1a. no test-command.json — nothing was established. $(printf '%s' "$OUT" | tail -15)"
fi
if [ ! -f "$REPO/.git/lcars/config.json" ] || ! grep -q '"testCommand"' "$REPO/.git/lcars/config.json"; then
  ok "L1b. repo config was NOT written mid-mission (promotion happens at approve)"
else
  bad "L1b. repo config gained testCommand MID-MISSION"
fi
if grep -q '"flipFlop"[[:space:]]*:[[:space:]]*"not-applicable"' "$MD/tickets/t-001/result.json" 2>/dev/null \
   && grep -q 'flipFlopReason' "$MD/tickets/t-001/result.json"; then
  ok "L1c. the scaffold ticket exits through the audited waiver, with a reason"
else
  bad "L1c. t-001 has no recorded waiver+reason"
fi

# L2 — THE FACT THE WHOLE CONTRACT RESTS ON. Ticket 2's PARENT COMMIT must carry
# the setup files, or its flip-flop is not a flip-flop at all.
BR="$(sed -n 's/.*"branch"[^"]*"\([^"]*\)".*/\1/p' "$MD/state.json" | head -1)"
PARENT="$(cat "$MD/tickets/t-002/.commit-base" 2>/dev/null || true)"
[ -n "$PARENT" ] || PARENT="$(git -C "$REPO" rev-parse "$BR^" 2>/dev/null || true)"
if [ -n "$PARENT" ] && git -C "$REPO" cat-file -e "$PARENT:package.json" 2>/dev/null; then
  ok "L2. the setup files ARE on ticket 2's PARENT commit ($PARENT) — measured, not assumed"
else
  bad "L2. package.json is NOT on ticket 2's parent ($PARENT) — every later gate is a lie"
fi

# L3 — the genuine flip-flop.
FF="$MD/tickets/t-002/flip-flop.json"
if [ -f "$FF" ]; then
  V="$(sed -n 's/.*"verdict"[^"]*"\([^"]*\)".*/\1/p' "$FF" | head -1)"
  RAN="$(sed -n 's/.*"ran"[^:]*:[[:space:]]*\([a-z]*\).*/\1/p' "$FF" | head -1)"
  note "t-002 flip-flop verdict=$V parentRan=$RAN"
  if [ "$V" = pass ]; then
    ok "L3a. ticket 2 PASSES a real flip-flop against the runner ticket 1 built"
  else
    bad "L3a. t-002 flip-flop verdict is '$V': $(sed -n 's/.*"reason"[^"]*"\([^"]*\)".*/\1/p' "$FF" | head -1)"
  fi
  if grep -q '"ran"[[:space:]]*:[[:space:]]*true' "$FF"; then
    ok "L3b. …and the PARENT leg actually RAN (not skipped, not inconclusive)"
  else
    bad "L3b. the parent leg never ran — the flip-flop is not evidence"
  fi
else
  bad "L3. no flip-flop.json for t-002 at all"
fi
if grep -q 'ticket_postcommit_ok' "$MD/events.jsonl" 2>/dev/null; then
  ok "L3c. the post-commit gate RAN and verified a ticket green on the committed branch"
else
  bad "L3c. no ticket_postcommit_ok — the post-commit gate never verified anything"
fi

# ===========================================================================
# LEG B — the implementation never LANDS: the post-commit gate must catch it
# ===========================================================================
REPO2="$(newrepo gf-drop)"; MD2="$(mkmission "$REPO2")"
stage "$REPO2" S185_DROP_IMPL=1
note "stage rc=$RC · worker sessions total: $(spawns)"
if grep -q 'ticket_postcommit_red\|ticket_postcommit_error' "$MD2/events.jsonl" 2>/dev/null; then
  ok "L4a. a ticket whose implementation never LANDS is CAUGHT by the post-commit gate"
else
  bad "L4a. the post-commit gate did not catch the missing implementation: $(printf '%s' "$OUT" | tail -12)"
fi
if [ ! -f "$MD2/tickets/t-002/result.json" ]; then
  ok "L4b. …and the not-actually-green result was DROPPED (never counts as green)"
else
  bad "L4b. t-002 kept a green result it did not earn"
fi
if grep -q '"ticket":"t-002"' "$MD2/events.jsonl" 2>/dev/null && ! grep -q 'ticket_green.*t-002' "$MD2/events.jsonl" 2>/dev/null; then
  ok "L4c. t-002 never emitted ticket_green"
else
  bad "L4c. t-002 emitted a green event despite failing the post-commit gate"
fi

printf '\ns185 stage drive: %d passed, %d failed  (worker sessions: %d — all fake)\n' \
  "$PASS" "$FAIL" "$(spawns)"
[ "$KEEP" = 1 ] || note "artifacts kept at $OUTDIR"
[ "$FAIL" -eq 0 ]
