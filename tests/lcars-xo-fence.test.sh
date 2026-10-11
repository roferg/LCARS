#!/usr/bin/env bash
#
# S239 HARDENING — THE TWO HOLES THE ROBUSTNESS CAMPAIGN FOUND.
#
# BREAK 1 — a `run` step's argv was not fenced AT ALL. `refuse_reason()` and
# `declared_escape()` each inspected "cwd", "env", "file" and "path"; neither
# ever inspected "argv". So the harness refused the declared DESTINATION while
# handing the COMMAND ITSELF to subprocess.Popen unexamined. Demonstrated on
# 2 Oct 2026 with transcripts on disk: `["bash","-c",…]` got a real shell
# running as the captain, `["cat","<outside>"]` read a sentinel outside both
# fences, `["sh","-c","… > <outside>/PWNED"]` wrote outside the sandbox, and a
# step wrote into the target repo's checked-out working tree. Reachable from
# the WORKER, not just a hand-crafted journey: the same shapes passed
# `xo-run.py actions` and were KEPT into reachSteps. Meanwhile
# prompts/evaluate.md told the model in bold "You have no shell, and you are
# not getting one." — a sentence the harness did not make true.
#
# S261 NOTE, so nobody reads this file as still claiming it: that sentence is
# GONE (captain's amendment, 2026-10-08 19:33 MDT). The reviewer now has a real
# shell, inside a disposable detached worktree, and its containment is that copy
# plus the post-turn mission-state audit — see `lcars-xo-eyes`. NOTHING BELOW
# CHANGES: this file drives the DECLARED-step path's own argv fence, which the
# amendment expressly did not open. A declared step still gets no shell.
#
# BREAK 2 — `teardown()` ran in a `finally`, which a signal does not honour.
# Observed: after killing a look, the target repo still had a REGISTERED
# worktree in .git/worktrees/, the worktree dir and throwaway HOME survived on
# disk, and an orphan child was still running.
#
# WHAT THIS FILE DRIVES:
#   1  argv is fenced in BOTH gates (journey + worker request), the refusal is
#      one plain sentence, journaled, and THE COMMAND NEVER RUNS.
#   2  POSITIVE CONTROLS, the point of the exercise: a legitimate step still
#      RUNS and still reads met:true — `python3 relay.py --help` AND
#      `bash run-tests.sh` (bash with a SCRIPT, not -c, is a real way to run a
#      test script; we refuse `bash -c`, not `bash`).
#   3  the pre-existing cwd / HOME / path refusals still fire.
#   4  a look that receives SIGTERM tears down: no registered worktree left in
#      the target repo, no orphan child — and the DETECTOR for that is shown to
#      FIRE on a deliberately leaked worktree, so it is not blind.
#
# ZERO SPEND. A PATH shim fakes BOTH `claude` and `copilot` and counts every
# invocation; the count is asserted to be 0.
#
# Usage: bash tests/lcars-xo-fence.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XORUN="$REPO_ROOT/skills/lcars-xo/xo-run.py"
PY="${LCARS_PYTHON_BIN:-python3}"
CAGE="$REPO_ROOT/tests/lib/cage.py"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
cleanup() {
  [ -d "$TMPROOT/prod" ] && git -C "$TMPROOT/prod" worktree prune >/dev/null 2>&1
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND -------------------------------------------------------------
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

echo "lcars xo — THE FENCE: a step's argv, and a killed look's teardown"

# ===========================================================================
# THE THROWAWAY WORLD: a real git repo, a real branch, a real tiny CLI, and a
# SENTINEL outside both fences that nothing in here may read or write.
# ===========================================================================
PROD="$TMPROOT/prod"; mkdir -p "$PROD"
git -C "$PROD" init -q -b main
cat >"$PROD/relay.py" <<'PYEOF'
import sys
args = sys.argv[1:]
if not args or args[0] in ("--help", "-h"):
    print("usage: relay [send|list]")
    sys.exit(0)
sys.stderr.write("relay: no such subcommand %s\n" % args[0])
sys.exit(2)
PYEOF
cat >"$PROD/run-tests.sh" <<'SHEOF'
#!/usr/bin/env bash
echo "4 passed, 0 failed"
SHEOF
chmod +x "$PROD/run-tests.sh"
cat >"$PROD/sleeper.py" <<'PYEOF'
import os, sys, time
pf = os.environ.get("PIDFILE")
if pf:
    with open(pf, "w") as fh:
        fh.write(str(os.getpid()))
sys.stdout.write("sleeping\n")
sys.stdout.flush()
time.sleep(90)
PYEOF
git -C "$PROD" add -A >/dev/null 2>&1
git -C "$PROD" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
git -C "$PROD" branch -q feat/relay 2>/dev/null

OUTSIDE="$TMPROOT/outside"; mkdir -p "$OUTSIDE"
printf 'SENTINEL-CONTENT-7f3a9\n' >"$OUTSIDE/sentinel.txt"

MDIR="$TMPROOT/mission"; mkdir -p "$MDIR"

# ===========================================================================
# 1. THE JOURNEY GATE (refuse_reason) — argv is fenced
# ===========================================================================
echo ""
echo "1. a declared step's argv is fenced — shells, interpreters-as-shells, absolute paths"

SHOTS="$TMPROOT/shots/argv"
cat >"$TMPROOT/argv-journey.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "a1", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["bash", "-c", "echo PWNED-BASH > $OUTSIDE/PWNED-BASH"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "01-bash-c.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "a2", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["/bin/sh", "-c", "echo PWNED-SH > $OUTSIDE/PWNED-SH"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "02-sh-c.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "a3", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["cat", "$OUTSIDE/sentinel.txt"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "03-cat-outside.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "a4", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["python3", "-c", "open('$OUTSIDE/PWNED-PY','w').write('x')"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "04-python-c.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "a5", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["/usr/bin/env", "bash", "-c", "echo PWNED-ENV > $OUTSIDE/PWNED-ENV"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "05-env.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "a6", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["python3", "../../../relay.py", "--help"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "06-walkup.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "a7", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["bash"],
   "cwd": "<worktree>", "env": {"HOME": "<throwaway-home>"},
   "evidence": "07-bare-shell.txt", "expect": {"exit": 0}}
]}
JSON
: >"$MDIR/number-one.jsonl"
"$PY" "$CAGE" 150 "$PY" "$XORUN" run \
  --journey "$TMPROOT/argv-journey.json" --repo "$PROD" --branch feat/relay \
  --out "$SHOTS" --mission-dir "$MDIR" >"$TMPROOT/argv.out" 2>&1

check "the argv run TERMINATES (not caged out)" \
  '! grep -q "TIMED OUT" "$TMPROOT/argv.out"'

refused_with() { # <readout.json> <substring the sentence must name>
  "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("refused") is True, ("not refused", d)
why = d.get("why") or ""
assert why, ("no reason given", d)
assert "\n" not in why, ("the refusal is not ONE sentence", why)
assert len(why) < 300, ("the refusal is not one plain sentence", why)
assert sys.argv[2] in why, ("the sentence does not name what was refused",
                            sys.argv[2], why)
' "$1" "$2"
}

check "R1. 'bash -c' is REFUSED, in one sentence naming the shell" \
  'refused_with "$SHOTS/01-bash-c.json" "bash"'
check "R1. '/bin/sh -c' is REFUSED — the BASENAME is matched, so a path is no escape" \
  'refused_with "$SHOTS/02-sh-c.json" "sh"'
check "R1. an absolute path in argv is REFUSED" \
  'refused_with "$SHOTS/03-cat-outside.json" "sentinel.txt"'
check "R1. 'python3 -c' is REFUSED — an interpreter with -c is a shell in a coat" \
  'refused_with "$SHOTS/04-python-c.json" "python3"'
check "R1. 'env bash -c' is REFUSED — env launders argv[0] past the fence" \
  'refused_with "$SHOTS/05-env.json" "env"'
check "R1. an argv path that walks up out of the worktree is REFUSED" \
  'refused_with "$SHOTS/06-walkup.json" ".."'
check "R1. a bare interactive shell is REFUSED" \
  'refused_with "$SHOTS/07-bare-shell.json" "bash"'

# THE WHOLE POINT: refused means NOT RUN. Asserted on the world, not the text.
check "R1. the command NEVER RAN — nothing was written outside the sandbox" \
  '[ ! -e "$OUTSIDE/PWNED-BASH" ] && [ ! -e "$OUTSIDE/PWNED-SH" ] && [ ! -e "$OUTSIDE/PWNED-PY" ] && [ ! -e "$OUTSIDE/PWNED-ENV" ]'
check "R1. the sentinel outside the sandbox was never READ into a transcript" \
  '! grep -rq "SENTINEL-CONTENT-7f3a9" "$SHOTS"'
check "R1. every transcript says the command was NOT run" \
  'grep -q "NOT run" "$SHOTS/01-bash-c.txt" && grep -q "NOT run" "$SHOTS/03-cat-outside.txt"'
check "R1. every argv refusal is JOURNALED as step-refused" \
  '[ "$(grep -c "step-refused" "$MDIR/number-one.jsonl")" -ge 7 ]'
check "R1. the worktree is GONE at teardown" \
  '! git -C "$PROD" worktree list --porcelain | grep -q "lcars-ap-wt-"'

# ===========================================================================
# 2. POSITIVE CONTROL — the legitimate steps STILL RUN
# ===========================================================================
echo ""
echo "2. POSITIVE CONTROL — a legitimate step still runs, and still reads met:true"

GSHOTS="$TMPROOT/shots/good"
cat >"$TMPROOT/good-journey.json" <<'JSON'
{"steps": [], "reachSteps": [
  {"do": "run", "key": "g1", "for": "prd-1", "fromChecklist": "cli#1",
   "argv": ["python3", "relay.py", "--help"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "01-help.txt",
   "expect": {"exit": 0, "stdoutIncludes": "usage: relay"}},
  {"do": "run", "key": "g2", "for": "prd-2", "fromChecklist": "cli#2",
   "argv": ["bash", "run-tests.sh"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "02-tests.txt",
   "expect": {"exit": 0, "stdoutIncludes": "4 passed"}},
  {"do": "run", "key": "g3", "for": "prd-2", "fromChecklist": "cli#3",
   "argv": ["python3", "-m", "json.tool", "--help"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "03-module.txt",
   "expect": {"exit": 0}},
  {"do": "run", "key": "g4", "for": "prd-2", "fromChecklist": "cli#4",
   "argv": ["python3", "<worktree>/relay.py", "--help"], "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>"}, "evidence": "04-marked.txt",
   "expect": {"exit": 0, "stdoutIncludes": "usage: relay"}}
]}
JSON
"$PY" "$CAGE" 150 "$PY" "$XORUN" run \
  --journey "$TMPROOT/good-journey.json" --repo "$PROD" --branch feat/relay \
  --out "$GSHOTS" --mission-dir "$MDIR" >"$TMPROOT/good.out" 2>&1

met_true() {
  "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert not d.get("refused"), ("OVER-REFUSED a legitimate step", d.get("why"))
assert d.get("met") is True, ("did not read met:true", d)
' "$1"
}
check "P2. 'python3 relay.py --help' STILL RUNS and reads met:true" \
  'met_true "$GSHOTS/01-help.json"'
check "P2. 'bash run-tests.sh' STILL RUNS and reads met:true (bash -c is refused, bash is not)" \
  'met_true "$GSHOTS/02-tests.json"'
check "P2. 'python3 -m json.tool --help' STILL RUNS (a -m form is not a -c form)" \
  'met_true "$GSHOTS/03-module.json"'
check "P2. a '<worktree>'-marked absolute path STILL RUNS (it resolves INSIDE the sandbox)" \
  'met_true "$GSHOTS/04-marked.json"'
check "P2. the legitimate run produced real output, not a refusal transcript" \
  'grep -q "usage: relay" "$GSHOTS/01-help.txt" && grep -q "4 passed" "$GSHOTS/02-tests.txt"'

# ===========================================================================
# 3. THE WORKER-REQUEST GATE (declared_escape) — the SAME argv fence
# ===========================================================================
echo ""
echo "3. the worker-request gate refuses the same argv shapes, and keeps the good one"

cat >"$TMPROOT/actions.json" <<JSON
{"actions": [
  {"do": "run", "key": "w1", "argv": ["bash", "-c", "id"], "cwd": "<worktree>"},
  {"do": "run", "key": "w2", "argv": ["cat", "$OUTSIDE/sentinel.txt"], "cwd": "<worktree>"},
  {"do": "run", "key": "w3", "argv": ["python3", "-c", "import os"], "cwd": "<worktree>"},
  {"do": "run", "key": "w4", "argv": ["env", "sh", "-c", "id"], "cwd": "<worktree>"},
  {"do": "run", "key": "w5", "argv": ["python3", "relay.py", "--help"], "cwd": "<worktree>"},
  {"do": "run", "key": "w6", "argv": ["bash", "run-tests.sh"], "cwd": "<worktree>"}
]}
JSON
: >"$MDIR/actions.jsonl"
"$PY" "$XORUN" actions --actions "$TMPROOT/actions.json" \
  --out "$TMPROOT/actions-kept.json" --mission-dir "$MDIR" \
  >"$TMPROOT/actions.out" 2>&1

check "R3. the four shell/absolute requests are REFUSED, never kept" \
  '"$PY" -c "
import json, sys
d = json.load(open(sys.argv[1]))
kept = {s.get(\"key\") for s in (d.get(\"reachSteps\") or [])}
assert not (kept & {\"w1\",\"w2\",\"w3\",\"w4\"}), kept
assert len(d.get(\"refused\") or []) >= 4, d.get(\"refused\")
for r in d[\"refused\"]:
    assert r.get(\"why\"), r
" "$TMPROOT/actions-kept.json"'
check "P3. POSITIVE CONTROL — the two legitimate requests ARE still kept" \
  '"$PY" -c "
import json, sys
d = json.load(open(sys.argv[1]))
kept = {s.get(\"key\") for s in (d.get(\"reachSteps\") or [])}
assert kept == {\"w5\",\"w6\"}, kept
" "$TMPROOT/actions-kept.json"'
check "R3. the request refusal is JOURNALED as action-refused" \
  '[ "$(grep -c "action-refused" "$MDIR/number-one.jsonl")" -ge 4 ]'

# ===========================================================================
# 4. POSITIVE CONTROL — the PRE-EXISTING fences still fire
# ===========================================================================
echo ""
echo "4. POSITIVE CONTROL — the cwd / HOME / path refusals are unchanged"

ESHOTS="$TMPROOT/shots/old"
cat >"$TMPROOT/old-journey.json" <<'JSON'
{"steps": [], "reachSteps": [
  {"do": "run", "key": "o1", "argv": ["python3", "relay.py", "--help"],
   "cwd": "/etc", "env": {"HOME": "<throwaway-home>"},
   "evidence": "01-cwd.txt", "expect": {"exit": 0}},
  {"do": "run", "key": "o2", "argv": ["python3", "relay.py", "--help"],
   "cwd": "<worktree>", "env": {"HOME": "/Users/somebody-else"},
   "evidence": "02-home.txt", "expect": {"exit": 0}},
  {"do": "read", "key": "o3", "path": "../../../../etc/passwd",
   "evidence": "03-read.txt", "expect": {"includes": "root"}}
]}
JSON
"$PY" "$CAGE" 150 "$PY" "$XORUN" run \
  --journey "$TMPROOT/old-journey.json" --repo "$PROD" --branch feat/relay \
  --out "$ESHOTS" --mission-dir "$MDIR" >"$TMPROOT/old.out" 2>&1
check "P4. a cwd outside the worktree is still REFUSED" \
  'refused_with "$ESHOTS/01-cwd.json" "cwd"'
check "P4. a HOME outside the throwaway HOME is still REFUSED" \
  'refused_with "$ESHOTS/02-home.json" "HOME"'
check "P4. a read path outside the worktree is still REFUSED" \
  'refused_with "$ESHOTS/03-read.json" "outside"'

# ===========================================================================
# 5. A KILLED LOOK TEARS DOWN — and 6. the DETECTOR is shown to FIRE
# ===========================================================================
echo ""
echo "5. a look that receives SIGTERM tears down; 6. the leak detector is not blind"

# --- 6 FIRST: prove the detector SEES a leak when one is present ------------
# A probe that says "no leak" proves nothing until it has been watched firing.
LEAK="$TMPROOT/leak-wt"
git -C "$PROD" worktree add -q --detach "$LEAK" feat/relay >/dev/null 2>&1
leaked_worktrees() { git -C "$PROD" worktree list --porcelain | grep -c '^worktree ' ; }
registered() { ls "$PROD/.git/worktrees" 2>/dev/null | wc -l | tr -d ' ' ; }
check "P6. the DETECTOR FIRES: with a worktree deliberately added, it sees it registered" \
  '[ "$(registered)" -ge 1 ] && [ "$(leaked_worktrees)" -ge 2 ]'
git -C "$PROD" worktree remove --force "$LEAK" >/dev/null 2>&1
git -C "$PROD" worktree prune >/dev/null 2>&1
check "P6. ...and with it removed, the same detector reads CLEAN (so it is a detector, not a constant)" \
  '[ "$(registered)" = "0" ]'

# --- 5: SIGTERM a live look -------------------------------------------------
PIDFILE="$TMPROOT/child.pid"
SSHOTS="$TMPROOT/shots/term"
cat >"$TMPROOT/sleep-journey.json" <<JSON
{"steps": [], "reachSteps": [
  {"do": "run", "key": "s1", "argv": ["python3", "sleeper.py"],
   "cwd": "<worktree>",
   "env": {"HOME": "<throwaway-home>", "PIDFILE": "$PIDFILE"},
   "evidence": "01-sleep.txt", "expect": {"exit": 0}}
]}
JSON
"$PY" "$XORUN" run \
  --journey "$TMPROOT/sleep-journey.json" --repo "$PROD" --branch feat/relay \
  --out "$SSHOTS" --mission-dir "$MDIR" >"$TMPROOT/term.out" 2>&1 &
LOOK_PID=$!

# Wait for the look to be genuinely LIVE: a worktree registered AND a child
# running. Without that wait the test could "pass" by killing it before it did
# anything — a blind control.
for _ in $(seq 1 100); do
  if [ "$(registered)" -ge 1 ] && [ -s "$PIDFILE" ]; then break; fi
  "$PY" -c 'import time; time.sleep(0.2)'
done
CHILD_PID="$(cat "$PIDFILE" 2>/dev/null || echo '')"
WAS_LIVE_WT="$(registered)"
WAS_LIVE_CHILD=no
if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then WAS_LIVE_CHILD=yes; fi
check "P5. PRECONDITION — the look really was live (worktree registered, child running)" \
  '[ "$WAS_LIVE_WT" -ge 1 ] && [ "$WAS_LIVE_CHILD" = "yes" ]'

kill -TERM "$LOOK_PID" 2>/dev/null
for _ in $(seq 1 75); do
  kill -0 "$LOOK_PID" 2>/dev/null || break
  "$PY" -c 'import time; time.sleep(0.2)'
done
wait "$LOOK_PID" 2>/dev/null
"$PY" -c 'import time; time.sleep(1.0)'

check "R5. SIGTERM left NO registered worktree in the target repo" \
  '[ "$(registered)" = "0" ]'
check "R5. SIGTERM left no worktree in 'git worktree list' either" \
  '! git -C "$PROD" worktree list --porcelain | grep -q "lcars-ap-wt-"'
check "R5. SIGTERM left NO orphan child process behind" \
  '[ -z "$CHILD_PID" ] || ! kill -0 "$CHILD_PID" 2>/dev/null'
# The look PRINTS the worktree and HOME it minted; the detector reads them back
# from its own output rather than guessing a glob — a glob that matches nothing
# passes whether or not the directory leaked.
LOOK_WT="$(sed -n 's/^  worktree: //p' "$TMPROOT/term.out" | head -1)"
LOOK_HOME="$(sed -n 's/^  HOME: *//p' "$TMPROOT/term.out" | head -1 | sed 's/ (throwaway)//')"
check "P5. PRECONDITION — the look named the worktree and HOME it minted" \
  '[ -n "$LOOK_WT" ] && [ -n "$LOOK_HOME" ]'
check "R5. the throwaway worktree directory is gone from disk" \
  '[ ! -d "$LOOK_WT" ]'
check "R5. the throwaway HOME is gone from disk" \
  '[ ! -d "$LOOK_HOME" ]'
check "R5. teardown is RE-RUNNABLE — calling it twice is harmless" \
  '"$PY" -c "
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], \"skills\", \"lcars-xo\"))
import importlib.util
spec = importlib.util.spec_from_file_location(\"xorun\", os.path.join(sys.argv[1], \"skills\", \"lcars-xo\", \"xo-run.py\"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.teardown(sys.argv[2], \"\", \"\")
m.teardown(sys.argv[2], \"\", \"\")
print(\"ok\")" "$REPO_ROOT" "$PROD"'

# ===========================================================================
# ZERO SPEND
# ===========================================================================
echo ""
echo "zero spend"
check "no worker CLI was invoked anywhere in this file" \
  '[ ! -s "$SPEND_LOG" ]'

echo ""
printf 'lcars xo fence: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
