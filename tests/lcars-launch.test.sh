#!/usr/bin/env bash
#
# Tests for `lcars launch` (skills/lcars-launch/launch.sh).
#
# `lcars launch <mission> [hint]` gets a mission's app running locally so the
# captain can view it during Verify. The flow (architecture fixed by the gating
# spike):
#   1. resolve the mission → its branch → the branch-tip SHA
#   2. check that SHA out into a DISPOSABLE DETACHED git worktree (detached so it
#      does NOT hold the branch ref and block the Implement replay gate)
#   3. spawn a `launch`-role cold worker that DISCOVERS how to run the app and
#      writes launch.json (it never starts anything itself)
#   4. the SKILL launches the discovered command DETACHED (owning the process
#      group) and records the final launch.json
#   5. `--stop` kills the whole process group and prunes the worktree
#
# Every external is stubbed: the worker ($LCARS_WORKER_BIN) is a fake that writes
# a canned discovery launch.json; git is REAL against a temp repo (so worktree
# behaviour is genuinely exercised); the "app" is a perl-sleep script named in the
# canned command (so the skill launches a REAL, killable pid). NO model calls.
#
# We deliberately avoid the `sleep` BINARY anywhere (perl sub-second waits) so the
# suite stays fast and sandbox-safe.
#
# Usage: bash tests/lcars-launch.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH_SH="$REPO_ROOT/skills/lcars-launch/launch.sh"
ADAPTER="$REPO_ROOT/skills/lcars-run/worker-adapter.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'stop_all; rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# Sub-second wait WITHOUT the `sleep` binary (perl select), so the suite is quick
# and never trips a sandbox that blocks foreground `sleep`.
nap() { perl -e 'select(undef,undef,undef,'"${1:-0.3}"')' 2>/dev/null || true; }

# Track pids we launch so the EXIT trap can reap anything a failing test left.
LAUNCHED_PIDS=()
stop_all() {
  local p
  for p in ${LAUNCHED_PIDS[@]+"${LAUNCHED_PIDS[@]}"}; do
    kill -KILL -"$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
  done
}

# --- a throwaway git repo with one mission --------------------------------
# Prints the repo root on stdout. Creates a `lcars/<id>` branch one commit ahead
# of the trunk, and a mission dir whose state.json points at that branch.
make_repo() { # id [workerBin]
  local id="$1" wb="${2:-}"
  local root; root="$(mktemp -d "$TMPROOT/repo.XXXX")"
  (
    cd "$root"
    git init -q
    git config user.email t@t.com
    git config user.name t
    git symbolic-ref HEAD refs/heads/trunk
    printf 'root\n' > README.md
    git add . && git commit -qm init
    git checkout -qb "lcars/$id"
    printf 'app source\n' > app.txt
    git add . && git commit -qm "mission work"
    git checkout -q trunk
  )
  local mdir="$root/.git/lcars/missions/$id"
  mkdir -p "$mdir"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "stage": "verify",\n'
    [ -n "$wb" ] && printf '  "workerBin": "%s",\n' "$wb"
    printf '  "branch": "lcars/%s",\n' "$id"
    printf '  "base": "trunk"\n'
    printf '}\n'
  } > "$mdir/state.json"
  printf '%s\n' "$root"
}

# A worker stub's basename must be a KNOWN adapter cli id (claude|copilot) — the
# skill derives the cli from `basename $LCARS_WORKER_BIN`. So the functional stubs
# below live each in their own dir as a file named `claude`. This helper mints one
# such dir and echoes the `<dir>/claude` path to use.
claude_stub_path() { # -> path ending in /claude, in a fresh dir
  local d; d="$(mktemp -d "$TMPROOT/wk.XXXX")"; printf '%s/claude\n' "$d"
}

# A worker stub that records its full argv (one per line) to $1 and then writes a
# FAILED discovery launch.json to $LCARS_LAUNCH_JSON (so the skill stops without
# launching anything — this stub is for the argv-recording tests).
make_rec_worker() { # path argvfile
  cat >"$1" <<EOF
#!/usr/bin/env bash
: >"$2"
for a in "\$@"; do printf '%s\n' "\$a" >>"$2"; done
printf '{\n  "status": "failed",\n  "message": "stub: discovery not performed"\n}\n' > "\$LCARS_LAUNCH_JSON"
exit 0
EOF
  chmod +x "$1"
}

# A worker stub that writes a READY discovery launch.json to $LCARS_LAUNCH_JSON.
make_ready_worker() { # path command target url howToStop [cwd]
  local cwd="${6:-.}"
  cat >"$1" <<EOF
#!/usr/bin/env bash
cat > "\$LCARS_LAUNCH_JSON" <<'JSON'
{
  "target": "$3",
  "command": "$2",
  "cwd": "$cwd",
  "url": "$4",
  "howToStop": "$5",
  "status": "ready"
}
JSON
exit 0
EOF
  chmod +x "$1"
}

# A worker stub that writes an explicit status=failed discovery with a message.
make_failed_worker() { # path message
  cat >"$1" <<EOF
#!/usr/bin/env bash
cat > "\$LCARS_LAUNCH_JSON" <<'JSON'
{
  "target": "",
  "status": "failed",
  "message": "$2"
}
JSON
exit 0
EOF
  chmod +x "$1"
}

# A pass-through git wrapper (used as $LCARS_GIT_BIN) that intercepts ONLY
# `merge-base` (→ a canned sha) and `diff --name-only` (→ a canned changed-file
# list), delegating every OTHER subcommand to the real git so rev-parse/worktree
# still work against the temp repo. $2 = newline-separated changed paths ("" for
# an empty diff / no touched target).
make_git_stub() { # path changed-paths
  cat >"$1" <<EOF
#!/usr/bin/env bash
if [ "\$1" = merge-base ]; then
  echo 0000000000000000000000000000000000000000
  exit 0
fi
if [ "\$1" = diff ]; then
  cat <<'FILES'
$2
FILES
  exit 0
fi
exec git "\$@"
EOF
  chmod +x "$1"
}

# A long-lived fake "app": stays alive ~30s (killed by --stop long before).
make_app() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
perl -e 'select(undef,undef,undef,30)'
EOF
  chmod +x "$1"
}

# A fake "app" that stays alive for ~N seconds and THEN exits non-zero — models a
# real dev server that spawns through several layers and only reaches its failure
# (ENOENT / "command not found") ~1–2s in, AFTER any single short settle window.
make_app_dies() { # path seconds
  cat >"$1" <<EOF
#!/usr/bin/env bash
perl -e 'select(undef,undef,undef,${2:-1})'
exit 1
EOF
  chmod +x "$1"
}

# A fake "app" that also spawns a CHILD in its process group and records the
# child's pid to $2, so a group-kill can be proven to reap the whole tree.
make_app_with_child() { # path childpidfile
  cat >"$1" <<EOF
#!/usr/bin/env bash
perl -e 'select(undef,undef,undef,30)' &
echo \$! > "$2"
perl -e 'select(undef,undef,undef,30)'
EOF
  chmod +x "$1"
}

json_field() { sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" | head -1; }
json_num()   { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

echo "lcars launch — get a mission's app running for Verify (session 108)"

# =====================================================================
# 1. launch → a DETACHED worktree at the branch tip; outer tree untouched
# =====================================================================
R1="$(make_repo m1)"
APP1="$TMPROOT/app1.sh"; make_app "$APP1"
W1="$(claude_stub_path)"; make_ready_worker "$W1" "$APP1" "m1 dev server" "http://localhost:5173" "Ctrl-C in the window, or lcars launch m1 --stop"
BEFORE_HEAD="$(cd "$R1" && git rev-parse --abbrev-ref HEAD)"
( cd "$R1" && LCARS_WORKER_BIN="$W1" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m1 >/dev/null 2>&1 )
WT1="$R1/.git/lcars/launch/m1"
PID1="$(json_num "$R1/.git/lcars/missions/m1/launch.json" pid)"
[ -n "$PID1" ] && LAUNCHED_PIDS+=("$PID1")
AFTER_HEAD="$(cd "$R1" && git rev-parse --abbrev-ref HEAD)"

# git worktree list reports the REALPATH (macOS /var → /private/var), so match the
# path by suffix rather than exact string.
check "1a. a git worktree was created at .git/lcars/launch/m1" \
  "(cd \"$R1\" && git worktree list --porcelain | grep -Eq 'lcars/launch/m1\$')"
check "1b. that worktree is DETACHED (holds no branch ref)" \
  "(cd \"$R1\" && git worktree list --porcelain | awk '/lcars\\/launch\\/m1\$/{f=1;next} f&&/^detached\$/{print;exit}' | grep -q detached)"
check "1c. the captain's own checkout is untouched (still on trunk)" \
  "[ \"$BEFORE_HEAD\" = trunk ] && [ \"$AFTER_HEAD\" = trunk ]"
check "1d. the worktree checkout is at the mission branch TIP (has app.txt)" \
  "[ -f \"$WT1/app.txt\" ]"
# stop to release
( cd "$R1" && LCARS_WORKER_BIN="$W1" bash "$LAUNCH_SH" m1 --stop >/dev/null 2>&1 )

# =====================================================================
# 2. worker argv carries the `launch` role toolset + the captain's hint,
#    for BOTH engines (recorded-argv assertion).
# =====================================================================
for eng in claude copilot; do
  Re="$(make_repo mE_$eng "$eng")"
  argvf="$TMPROOT/argv.$eng"
  stub="$TMPROOT/$eng"          # basename == the cli id → routes the adapter column
  make_rec_worker "$stub" "$argvf"
  ( cd "$Re" && LCARS_WORKER_BIN="$stub" bash "$LAUNCH_SH" "mE_$eng" "the marketing website" >/dev/null 2>&1 )
  if [ "$eng" = claude ]; then
    check "2a. claude launch argv fences to Read,Grep,Glob,Bash" \
      "grep -qxF 'Read,Grep,Glob,Bash' \"$argvf\""
  else
    check "2a. copilot launch argv fences to view,grep,glob,bash" \
      "grep -qxF 'view,grep,glob,bash' \"$argvf\""
  fi
  check "2b. $eng launch prompt carries the captain's hint" \
    "grep -q 'the marketing website' \"$argvf\""
done

# =====================================================================
# 3. ready launch.json + a live launched pid → readout + status=running
# =====================================================================
R3="$(make_repo m3)"
APP3="$TMPROOT/app3.sh"; make_app "$APP3"
W3="$(claude_stub_path)"; make_ready_worker "$W3" "$APP3" "Holodeck grid" "http://localhost:4000" "press stop, Captain"
OUT3="$( cd "$R3" && LCARS_WORKER_BIN="$W3" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m3 2>&1 )"
LJ3="$R3/.git/lcars/missions/m3/launch.json"
PID3="$(json_num "$LJ3" pid)"
[ -n "$PID3" ] && LAUNCHED_PIDS+=("$PID3")
check "3a. readout names the target" "printf '%s' \"\$OUT3\" | grep -q 'Holodeck grid'"
check "3b. readout names the url" "printf '%s' \"\$OUT3\" | grep -q 'http://localhost:4000'"
check "3c. readout names how to stop" "printf '%s' \"\$OUT3\" | grep -q 'press stop, Captain'"
check "3d. launch.json status is running" "[ \"\$(json_field \"$LJ3\" status)\" = running ]"
check "3e. the launched pid is alive (kill -0 succeeds)" "kill -0 \"$PID3\" 2>/dev/null"
( cd "$R3" && LCARS_WORKER_BIN="$W3" bash "$LAUNCH_SH" m3 --stop >/dev/null 2>&1 )

# 3f. instant death → status=failed, NOT running, plain message.
R3b="$(make_repo m3b)"
Wdie="$(claude_stub_path)"; make_ready_worker "$Wdie" "false" "doomed app" "" "n/a"
OUT3b="$( cd "$R3b" && LCARS_WORKER_BIN="$Wdie" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m3b 2>&1 )"; RC3b=$?
LJ3b="$R3b/.git/lcars/missions/m3b/launch.json"
check "3f. an app that dies immediately → exit non-zero" "[ \"$RC3b\" != 0 ]"
check "3g. instant death → status=failed (not running)" "[ \"\$(json_field \"$LJ3b\" status)\" = failed ]"
check "3h. instant death → a plain-English 'exited immediately' message" \
  "printf '%s' \"\$OUT3b\" | grep -qi 'exited immediately'"

# =====================================================================
# 4. --stop kills the process GROUP (child dies too), prunes the worktree;
#    a subsequent launch works again (idempotent).
# =====================================================================
R4="$(make_repo m4)"
CHILDPID="$TMPROOT/child4.pid"
APP4="$TMPROOT/app4.sh"; make_app_with_child "$APP4" "$CHILDPID"
W4="$(claude_stub_path)"; make_ready_worker "$W4" "$APP4" "warp core monitor" "" "lcars launch m4 --stop"
( cd "$R4" && LCARS_WORKER_BIN="$W4" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m4 >/dev/null 2>&1 )
LJ4="$R4/.git/lcars/missions/m4/launch.json"
PID4="$(json_num "$LJ4" pid)"
[ -n "$PID4" ] && LAUNCHED_PIDS+=("$PID4")
nap 0.4
CHILD4="$(cat "$CHILDPID" 2>/dev/null)"
check "4a. after launch the app pid is alive" "kill -0 \"$PID4\" 2>/dev/null"
check "4b. after launch its child (same group) is alive" "[ -n \"$CHILD4\" ] && kill -0 \"$CHILD4\" 2>/dev/null"
WT4="$R4/.git/lcars/launch/m4"
check "4c. the launch worktree exists before stop" \
  "(cd \"$R4\" && git worktree list --porcelain | grep -Eq 'lcars/launch/m4\$')"

# stop
( cd "$R4" && LCARS_WORKER_BIN="$W4" bash "$LAUNCH_SH" m4 --stop >/dev/null 2>&1 )
nap 0.5
check "4d. --stop killed the app pid" "! kill -0 \"$PID4\" 2>/dev/null"
check "4e. --stop killed the CHILD too (whole process group reaped)" "! kill -0 \"$CHILD4\" 2>/dev/null"
check "4f. --stop set status=stopped" "[ \"\$(json_field \"$LJ4\" status)\" = stopped ]"
check "4g. --stop pruned the launch worktree" \
  "! (cd \"$R4\" && git worktree list --porcelain | grep -Eq 'lcars/launch/m4\$')"

# re-launch works again
rm -f "$CHILDPID"
APP4b="$TMPROOT/app4b.sh"; make_app "$APP4b"
W4b="$(claude_stub_path)"; make_ready_worker "$W4b" "$APP4b" "warp core monitor" "" "lcars launch m4 --stop"
( cd "$R4" && LCARS_WORKER_BIN="$W4b" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m4 >/dev/null 2>&1 )
PID4b="$(json_num "$LJ4" pid)"
[ -n "$PID4b" ] && LAUNCHED_PIDS+=("$PID4b")
check "4h. a subsequent launch after stop works (status=running again)" \
  "[ \"\$(json_field \"$LJ4\" status)\" = running ] && kill -0 \"$PID4b\" 2>/dev/null"
check "4i. the worktree is back after re-launch" \
  "(cd \"$R4\" && git worktree list --porcelain | grep -Eq 'lcars/launch/m4\$')"
( cd "$R4" && LCARS_WORKER_BIN="$W4b" bash "$LAUNCH_SH" m4 --stop >/dev/null 2>&1 )

# =====================================================================
# 5. worker reports failure → skill prints the human message, exits
#    non-zero, launches NOTHING.
# =====================================================================
R5="$(make_repo m5)"
Wf="$(claude_stub_path)"; make_failed_worker "$Wf" "no dev server found — this repo has no package.json or Makefile with a run target"
OUT5="$( cd "$R5" && LCARS_WORKER_BIN="$Wf" bash "$LAUNCH_SH" m5 2>&1 )"; RC5=$?
LJ5="$R5/.git/lcars/missions/m5/launch.json"
check "5a. worker-failed launch exits non-zero" "[ \"$RC5\" != 0 ]"
check "5b. the worker's plain-English message is surfaced" \
  "printf '%s' \"\$OUT5\" | grep -q 'no dev server found'"
check "5c. status stays failed (nothing running)" "[ \"\$(json_field \"$LJ5\" status)\" = failed ]"
check "5d. no pid was recorded (nothing was launched)" \
  "[ -z \"\$(json_num \"$LJ5\" pid)\" ] || [ \"\$(json_num \"$LJ5\" pid)\" = null ]"

# 5e. worker writes NOTHING (empty/invalid discovery) → clean refusal, non-zero.
R5b="$(make_repo m5b)"
Wempty="$(claude_stub_path)"
cat >"$Wempty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$Wempty"
OUT5b="$( cd "$R5b" && LCARS_WORKER_BIN="$Wempty" bash "$LAUNCH_SH" m5b 2>&1 )"; RC5b=$?
check "5e. worker produced no launch.json → exit non-zero with a message" \
  "[ \"$RC5b\" != 0 ] && [ -n \"\$OUT5b\" ]"

# =====================================================================
# 6. unknown mission / missing branch → clean refusal, non-zero,
#    naming the problem (no bare CLI command as the primary line).
# =====================================================================
R6="$(make_repo m6)"
OUT6="$( cd "$R6" && LCARS_WORKER_BIN="$W1" bash "$LAUNCH_SH" nope-not-here 2>&1 )"; RC6=$?
check "6a. unknown mission → exit non-zero" "[ \"$RC6\" != 0 ]"
check "6b. unknown mission → message names the missing mission" \
  "printf '%s' \"\$OUT6\" | grep -qi 'nope-not-here'"

# a mission whose state.json has no branch → refusal naming the branch problem.
R6b="$(make_repo m6b)"
S6b="$R6b/.git/lcars/missions/m6b/state.json"
# rewrite state.json WITHOUT a branch field
{ printf '{\n  "id": "m6b",\n  "stage": "verify"\n}\n'; } > "$S6b"
OUT6b="$( cd "$R6b" && LCARS_WORKER_BIN="$W1" bash "$LAUNCH_SH" m6b 2>&1 )"; RC6b=$?
check "6c. mission with no branch recorded → exit non-zero" "[ \"$RC6b\" != 0 ]"
check "6d. no-branch refusal mentions the branch/run problem" \
  "printf '%s' \"\$OUT6b\" | grep -qiE 'branch|run the mission'"

# =====================================================================
# 7. Liveness is POLLED across the whole settle window, not one fixed sleep.
#    A dev server that dies MID-window (after any single short settle would have
#    already declared it "running") must be caught as failed — this is the exact
#    stale-status:running bug. And a failed launch must PRUNE its disposable
#    worktree so no stray dir is left behind (the "disposable" contract).
# =====================================================================
R7="$(make_repo m7)"
APP7="$TMPROOT/app7.sh"; make_app_dies "$APP7" 1     # alive ~1s, then exits non-zero
W7="$(claude_stub_path)"; make_ready_worker "$W7" "$APP7" "slow-dying dev server" "" "lcars launch m7 --stop"
# Use the REALISTIC DEFAULT window (do NOT pin LCARS_LAUNCH_SETTLE): the whole bug
# is that the old ~0.6s default declared "running" BEFORE a real dev server (which
# takes ~1–2s to reach ENOENT) had failed. The app here dies at ~1s — well inside
# the new default window but well after the old one — so this is red before the fix
# (stale status=running) and green after (polled to failed). The poll loop fails
# FAST at the death (~1s), so the test stays quick despite the larger window.
OUT7="$( cd "$R7" && LCARS_WORKER_BIN="$W7" bash "$LAUNCH_SH" m7 2>&1 )"; RC7=$?
LJ7="$R7/.git/lcars/missions/m7/launch.json"
PID7="$(json_num "$LJ7" pid)"
[ -n "$PID7" ] && LAUNCHED_PIDS+=("$PID7")
check "7a. an app that dies MID-window (alive ~1s, default window) → exit non-zero" \
  "[ \"$RC7\" != 0 ]"
check "7b. mid-window death → status=failed (NOT a stale running)" \
  "[ \"\$(json_field \"$LJ7\" status)\" = failed ]"
check "7c. mid-window death → no live pid recorded" \
  "[ -z \"\$(json_num \"$LJ7\" pid)\" ] || [ \"\$(json_num \"$LJ7\" pid)\" = null ]"
check "7d. mid-window death → a plain-English message (not a stack trace)" \
  "printf '%s' \"\$OUT7\" | grep -qiE 'exited|startup'"
check "7e. the failed launch pruned its disposable worktree (no stray dir)" \
  "! (cd \"$R7\" && git worktree list --porcelain | grep -Eq 'lcars/launch/m7\$')"

# 7f/g. A survivor (alive past the window) still passes cleanly, with a live pid,
#       in bounded time — the poll loop must not delay or fail a healthy app.
R7b="$(make_repo m7b)"
APP7b="$TMPROOT/app7b.sh"; make_app "$APP7b"
W7b="$(claude_stub_path)"; make_ready_worker "$W7b" "$APP7b" "healthy dev server" "http://localhost:9" "lcars launch m7b --stop"
T0="$(perl -e 'print time')"
RC7b=0
( cd "$R7b" && LCARS_WORKER_BIN="$W7b" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m7b >/dev/null 2>&1 ) || RC7b=$?
T1="$(perl -e 'print time')"
LJ7b="$R7b/.git/lcars/missions/m7b/launch.json"
PID7b="$(json_num "$LJ7b" pid)"
[ -n "$PID7b" ] && LAUNCHED_PIDS+=("$PID7b")
check "7f. a survivor still reaches status=running with a live pid" \
  "[ \"$RC7b\" = 0 ] && [ \"\$(json_field \"$LJ7b\" status)\" = running ] && kill -0 \"$PID7b\" 2>/dev/null"
check "7g. the survivor launch completed within a bounded time (< 5s)" \
  "[ \$(( T1 - T0 )) -lt 5 ]"
( cd "$R7b" && LCARS_WORKER_BIN="$W7b" bash "$LAUNCH_SH" m7b --stop >/dev/null 2>&1 )

# =====================================================================
# 8. The launch worktree is PROVISIONED (deps installed) before the app runs.
#    A disposable detached worktree has an EMPTY node_modules; without running the
#    repo's worktreeSetupCommand a real Node/pnpm app dies instantly
#    ("electron-vite: command not found"). The skill must run the resolved
#    worktreeSetupCommand ONCE with the worktree as CWD — mirroring run.sh's
#    provision_worktree() — right after the worktree is created and BEFORE launch.
# =====================================================================
# 8a. PROVISIONING RUNS: an env-override setup command writes a sentinel into CWD;
#     it must land INSIDE the launch worktree (proving cmd ran with wt as CWD).
R8="$(make_repo m8)"
APP8="$TMPROOT/app8.sh"; make_app "$APP8"
W8="$(claude_stub_path)"; make_ready_worker "$W8" "$APP8" "m8 dev server" "" "lcars launch m8 --stop"
( cd "$R8" && LCARS_WORKTREE_SETUP_CMD='touch .provisioned' \
    LCARS_WORKER_BIN="$W8" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m8 >/dev/null 2>&1 )
WT8="$R8/.git/lcars/launch/m8"
PID8="$(json_num "$R8/.git/lcars/missions/m8/launch.json" pid)"
[ -n "$PID8" ] && LAUNCHED_PIDS+=("$PID8")
check "8a. worktreeSetupCommand ran with the worktree as CWD (sentinel inside wt)" \
  "[ -f \"$WT8/.provisioned\" ]"
( cd "$R8" && LCARS_WORKER_BIN="$W8" bash "$LAUNCH_SH" m8 --stop >/dev/null 2>&1 )

# 8b. NO-OP SAFE: with NO worktreeSetupCommand configured and no env override, the
#     launch still proceeds normally (status=running) — the provisioning path is a
#     clean no-op and introduces no error (protects LCARS's own dep-free dogfood).
R8b="$(make_repo m8b)"
APP8b="$TMPROOT/app8b.sh"; make_app "$APP8b"
W8b="$(claude_stub_path)"; make_ready_worker "$W8b" "$APP8b" "m8b dev server" "" "lcars launch m8b --stop"
OUT8b="$( cd "$R8b" && LCARS_WORKER_BIN="$W8b" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m8b 2>&1 )"; RC8b=$?
LJ8b="$R8b/.git/lcars/missions/m8b/launch.json"
PID8b="$(json_num "$LJ8b" pid)"
[ -n "$PID8b" ] && LAUNCHED_PIDS+=("$PID8b")
check "8b. no worktreeSetupCommand → launch still proceeds normally (running)" \
  "[ \"$RC8b\" = 0 ] && [ \"\$(json_field \"$LJ8b\" status)\" = running ]"
( cd "$R8b" && LCARS_WORKER_BIN="$W8b" bash "$LAUNCH_SH" m8b --stop >/dev/null 2>&1 )

# =====================================================================
# 9. An intermediate `status:"launching"` record is persisted BEFORE the
#    discovery worker runs, so any observer (a card reopened mid-launch, SSE, a
#    second browser) during the 15–60s discovery+spawn window sees "launching"
#    instead of the RUN prompt. Deterministic proof: the worker copies the
#    launch.json it SEES on entry to a side file; assert it saw status=launching.
# =====================================================================
R9="$(make_repo m9)"
SEEN9="$TMPROOT/seen9.json"
APP9="$TMPROOT/app9.sh"; make_app "$APP9"
W9="$(claude_stub_path)"
# A worker that records the launch.json present at the moment it runs, THEN writes
# a normal READY discovery so the launch proceeds to running.
cat >"$W9" <<EOF
#!/usr/bin/env bash
# S111: \$LCARS_LAUNCH_JSON now points at the worker's PRIVATE discovery file
# (empty before the worker writes); the "launching" record the harness persists
# BEFORE the worker lives at the sibling launch.json — snapshot THAT.
cp "\$(dirname "\$LCARS_LAUNCH_JSON")/launch.json" "$SEEN9" 2>/dev/null || :
cat > "\$LCARS_LAUNCH_JSON" <<'JSON'
{
  "target": "m9 dev server",
  "command": "$APP9",
  "cwd": ".",
  "url": "",
  "howToStop": "lcars launch m9 --stop",
  "status": "ready"
}
JSON
exit 0
EOF
chmod +x "$W9"
( cd "$R9" && LCARS_WORKER_BIN="$W9" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m9 "the m9 app" >/dev/null 2>&1 )
LJ9="$R9/.git/lcars/missions/m9/launch.json"
PID9="$(json_num "$LJ9" pid)"
[ -n "$PID9" ] && LAUNCHED_PIDS+=("$PID9")
check "9a. the worker saw a launching record already on disk (persisted BEFORE it ran)" \
  "[ \"\$(json_field \"$SEEN9\" status)\" = launching ]"
check "9b. the intermediate record carried the captain's hint as its target" \
  "[ \"\$(json_field \"$SEEN9\" target)\" = 'the m9 app' ]"
check "9c. the final settle overwrote launching → running" \
  "[ \"\$(json_field \"$LJ9\" status)\" = running ]"
# S111 (RUN-button flash): the worker's answer goes to its PRIVATE discovery
# file — the shared launch.json must NEVER carry the worker's \"ready\" status
# (that transient state is what flashed the idle RUN button mid-launch).
check "9f. the worker's ready answer lives in launch-discovery.json, not launch.json" \
  "[ \"\$(json_field \"$(dirname "$LJ9")/launch-discovery.json\" status)\" = ready ]"
( cd "$R9" && LCARS_WORKER_BIN="$W9" bash "$LAUNCH_SH" m9 --stop >/dev/null 2>&1 )

# 9d/e. NEW silent-worker semantics: a worker that writes NOTHING leaves the status
#       STILL at "launching" (the intermediate record it never overwrote). That is
#       the semantic equivalent of the old "no launch.json file" case, so the launch
#       must report FAILED with the human silent-worker message — never a false
#       "running" (the intermediate record must not be mistaken for a result).
R9b="$(make_repo m9b)"
Wsilent="$(claude_stub_path)"
cat >"$Wsilent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$Wsilent"
OUT9b="$( cd "$R9b" && LCARS_WORKER_BIN="$Wsilent" bash "$LAUNCH_SH" m9b 2>&1 )"; RC9b=$?
LJ9b="$R9b/.git/lcars/missions/m9b/launch.json"
check "9d. a silent worker (status still launching) → exit non-zero, status=failed" \
  "[ \"$RC9b\" != 0 ] && [ \"\$(json_field \"$LJ9b\" status)\" = failed ]"
check "9e. the silent-worker failure carries the human 'reported nothing back' message" \
  "printf '%s' \"\$OUT9b\" | grep -qi 'reported nothing back'"

# =====================================================================
# 10. TOUCHED-TARGET DEFAULT: the mission's changed top-level dir(s) are fed to
#     the discovery worker as the DEFAULT target to pin, so a no-hint launch
#     defaults to the app that exercises THIS mission's change (not a sibling
#     target in a multi-target monorepo). Derived from a diff of the mission
#     branch against its merge-base with the recorded base, reduced to top-level
#     target dir(s). Stub git so the diff is deterministic; the rec worker
#     records the assembled prompt so we can inspect the injected section.
# =====================================================================
# 10. SINGLE TARGET: all changes under one package → that dir is pinned.
R10="$(make_repo m10)"
ARGV10="$TMPROOT/argv10"
GIT10="$TMPROOT/git10"; make_git_stub "$GIT10" "packages/editor/src/main.ts
packages/editor/src/app.tsx"
W10="$(claude_stub_path)"; make_rec_worker "$W10" "$ARGV10"
( cd "$R10" && LCARS_GIT_BIN="$GIT10" LCARS_WORKER_BIN="$W10" bash "$LAUNCH_SH" m10 >/dev/null 2>&1 )
check "10a. single touched target → prompt names the touched-target section" \
  "grep -q \"This Mission's changes are in\" \"$ARGV10\""
check "10b. single touched target → the section names packages/editor" \
  "grep -q 'packages/editor' \"$ARGV10\""

# 11. MULTI TARGET: changes span two top-level dirs → BOTH are listed.
R11="$(make_repo m11)"
ARGV11="$TMPROOT/argv11"
GIT11="$TMPROOT/git11"; make_git_stub "$GIT11" "packages/editor/src/main.ts
apps/game/src/index.ts"
W11="$(claude_stub_path)"; make_rec_worker "$W11" "$ARGV11"
( cd "$R11" && LCARS_GIT_BIN="$GIT11" LCARS_WORKER_BIN="$W11" bash "$LAUNCH_SH" m11 >/dev/null 2>&1 )
check "11a. multi touched target → the section lists packages/editor" \
  "grep -q 'packages/editor' \"$ARGV11\""
check "11b. multi touched target → the section ALSO lists apps/game" \
  "grep -q 'apps/game' \"$ARGV11\""

# 12. EMPTY / NO CONTEXT: an empty diff (no derivable target) → NO section, and
#     the prompt is exactly today's — the existing discovery/hint text preserved.
R12="$(make_repo m12)"
ARGV12="$TMPROOT/argv12"
GIT12="$TMPROOT/git12"; make_git_stub "$GIT12" ""     # empty diff
W12="$(claude_stub_path)"; make_rec_worker "$W12" "$ARGV12"
( cd "$R12" && LCARS_GIT_BIN="$GIT12" LCARS_WORKER_BIN="$W12" bash "$LAUNCH_SH" m12 >/dev/null 2>&1 )
check "12a. empty diff → NO touched-target section is injected" \
  "! grep -q \"This Mission's changes are in\" \"$ARGV12\""
check "12b. empty diff → today's existing prompt is preserved (discovery line)" \
  "grep -q 'DISCOVER how to start it' \"$ARGV12\""
check "12c. empty diff → today's existing hint line is preserved" \
  "grep -q 'The captain wants to run' \"$ARGV12\""

# 13. HINT OVERRIDE PRESERVED: with a hint AND a derived target, the hint is
#     still carried and the derived section frames itself as the default the
#     hint OVERRIDES (captain's hint must keep winning).
R13="$(make_repo m13)"
ARGV13="$TMPROOT/argv13"
GIT13="$TMPROOT/git13"; make_git_stub "$GIT13" "packages/editor/src/main.ts"
W13="$(claude_stub_path)"; make_rec_worker "$W13" "$ARGV13"
( cd "$R13" && LCARS_GIT_BIN="$GIT13" LCARS_WORKER_BIN="$W13" bash "$LAUNCH_SH" m13 "the example game" >/dev/null 2>&1 )
check "13a. hint + derived target → the captain's hint is still carried" \
  "grep -q 'the example game' \"$ARGV13\""
check "13b. hint + derived target → the section frames itself as the hint-overridable default" \
  "grep -qi 'OVERRIDES this default' \"$ARGV13\""

# =====================================================================
# 14. ORDERING: the `launching` record is written BEFORE the SLOW pre-flight
#     (`git worktree add --detach` + provision) — the MEASURED bug. It used to be
#     written LATE, only after the ~7s worktree+provision pre-flight, so an
#     observer that reopened a card right after clicking RUN read the STALE
#     pre-launch launch.json and wrongly re-rendered the ⚡ RUN button (the captain
#     could "outrun" the launch). Deterministic proof: the worktreeSetupCommand —
#     which runs DURING provisioning, right after the worktree is created and BEFORE
#     the discovery worker — copies the launch.json it sees to a side file; assert
#     provisioning already saw status=launching (it could only if launching was
#     written BEFORE the worktree/provision step). RED before the write was moved
#     (no launch.json exists at provision time → nothing to copy); GREEN after.
# =====================================================================
R14="$(make_repo m14)"
APP14="$TMPROOT/app14.sh"; make_app "$APP14"
W14="$(claude_stub_path)"; make_ready_worker "$W14" "$APP14" "m14 dev server" "" "lcars launch m14 --stop"
LJ14="$R14/.git/lcars/missions/m14/launch.json"
PROV14="$TMPROOT/prov_seen14.json"
( cd "$R14" && LCARS_WORKTREE_SETUP_CMD="cp '$LJ14' '$PROV14' 2>/dev/null || true" \
    LCARS_WORKER_BIN="$W14" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m14 "the m14 app" >/dev/null 2>&1 )
PID14="$(json_num "$LJ14" pid)"
[ -n "$PID14" ] && LAUNCHED_PIDS+=("$PID14")
check "14a. provisioning already saw a launching record on disk (written BEFORE worktree/provision)" \
  "[ \"\$(json_field \"$PROV14\" status)\" = launching ]"
check "14b. the record provisioning saw carried the captain's hint as its target" \
  "[ \"\$(json_field \"$PROV14\" target)\" = 'the m14 app' ]"
( cd "$R14" && LCARS_WORKER_BIN="$W14" bash "$LAUNCH_SH" m14 --stop >/dev/null 2>&1 )

echo "lcars launch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
