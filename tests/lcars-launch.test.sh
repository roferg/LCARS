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
# The CANONICAL form of $TMPROOT (macOS mktemp hands back /var/... which is a
# symlink to /private/var/...). launch.sh canonicalizes every path it builds with
# `pwd -P`, and `git worktree list` reports realpaths, so every expectation in
# this suite must be built from the canonical root or exact-string matches fail.
TMPROOT_P="$(cd "$TMPROOT" && pwd -P)"
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
make_repo() { # id [workerBin] [root]
  local id="$1" wb="${2:-}" root="${3:-}"
  if [ -n "$root" ]; then mkdir -p "$root"; else root="$(mktemp -d "$TMPROOT/repo.XXXX")"; fi
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

# --- S187: fixture apps that REALLY BIND a TCP port ---------------------------
# Every fixture app above is a sleep loop that binds NOTHING — which is exactly
# why a launch whose recorded url pointed at ANOTHER repo's app was invisible to
# this suite. These two helpers are the committed rigging that closes that hole.

# A free localhost TCP port, chosen by the OS and released immediately. Racy in
# principle, fine here: nothing else in this suite is grabbing ports.
free_port() {
  python3 -c 'import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

# free_port that is guaranteed DIFFERENT from every port named in "$@".
free_port_not() { # [port ...]
  local p x i=0
  while [ "$i" -lt 30 ]; do
    p="$(free_port)"
    for x in "$@"; do [ "$p" = "$x" ] && p=""; done
    [ -n "$p" ] && { printf '%s\n' "$p"; return 0; }
    i=$((i + 1))
  done
  printf '%s\n' "$p"
}

# A fake "app" that REALLY binds a TCP port. It:
#   • optionally waits $3 seconds before binding (models a dev server that only
#     reaches its listen() a second or two in — Vite/electron/pnpm layering),
#   • binds 127.0.0.1:$2 and listens,
#   • prints the Vite-style "  Local:   http://localhost:<port>/" line to $LOG,
#   • answers every connection 200 OK naming its own port, and appends one line
#     per request to $4 when given — so a test can prove WHICH app a probe
#     actually reached (the two-repo regression).
# `exec` keeps PID == PGID == the python listener, so the skill's process-group
# enumeration sees the real socket.
make_binding_app() { # path port [delay-seconds] [hits-file]
  cat >"$1" <<EOF
#!/usr/bin/env bash
exec python3 -u -c '
import socket, sys, time
port = int(sys.argv[1]); delay = float(sys.argv[2]); hits = sys.argv[3]
if delay > 0:
    time.sleep(delay)
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(16)
print("  Local:   http://localhost:%d/" % port)
body = ("app on %d" % port).encode()
while True:
    try:
        c, _ = s.accept()
        try:
            c.recv(4096)
        except Exception:
            pass
        if hits:
            f = open(hits, "a"); f.write("hit %d\n" % port); f.close()
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: "
                  + str(len(body)).encode()
                  + b"\r\nConnection: close\r\n\r\n" + body)
        c.close()
    except Exception:
        pass
' $2 ${3:-0} "${4:-}"
EOF
  chmod +x "$1"
}

# How many requests has a binding app answered? (0 when it has never been hit.)
hit_count() { # hits-file
  [ -f "$1" ] || { printf '0\n'; return 0; }
  wc -l < "$1" | tr -d ' '
}

json_field() { sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" | head -1; }
json_num()   { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# --- S167: where a deploy worktree is EXPECTED to live -------------------------
# Deploys are cut OUTSIDE `.git/` — a sibling of the repo, keyed by the repo's
# canonical parent + basename:  <repo-parent>/.lcars-launch/<repo-name>/<key>
# (key = the mission id, or the reserved "@main"). Inside `.git/` a deploy is
# invisible to every watcher-based dev tool (Vite/chokidar ignores `**/.git/**`
# by default), so the app can never observe its own writes.
wt_path() { # repo-root key  → the absolute, canonical expected worktree path
  local r; r="$(cd "$1" && pwd -P)"
  printf '%s/.lcars-launch/%s/%s\n' "$(dirname "$r")" "$(basename "$r")" "$2"
}
# Is EXACTLY this path registered as a worktree of this repo?
wt_registered() { # repo-root wt-path
  (cd "$1" && git worktree list --porcelain 2>/dev/null | grep -qxF "worktree $2")
}
# How MANY worktree rows point at this path (proves "no second cut" / no dupes)?
wt_rows() { # repo-root wt-path
  (cd "$1" && git worktree list --porcelain 2>/dev/null | grep -cxF "worktree $2")
}
# Is that registered worktree DETACHED (holding no branch ref)?
wt_detached() { # repo-root wt-path
  (cd "$1" && git worktree list --porcelain 2>/dev/null \
    | awk -v p="worktree $2" '$0==p{f=1;next} f&&/^$/{exit} f&&/^detached$/{print "yes";exit}') \
    | grep -q yes
}
# Does a path contain a `.git` component anywhere? (the whole point of S167)
has_dotgit_component() { case "/$1/" in */.git/*) return 0 ;; *) return 1 ;; esac; }

echo "lcars launch — get a mission's app running for Verify (session 108)"

# =====================================================================
# 1. launch → a DETACHED worktree at the branch tip; outer tree untouched
# =====================================================================
R1="$(make_repo m1)"
APP1="$TMPROOT/app1.sh"; make_app "$APP1"
W1="$(claude_stub_path)"; make_ready_worker "$W1" "$APP1" "m1 dev server" "http://localhost:5173" "Ctrl-C in the window, or lcars launch m1 --stop"
BEFORE_HEAD="$(cd "$R1" && git rev-parse --abbrev-ref HEAD)"
( cd "$R1" && LCARS_WORKER_BIN="$W1" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m1 >/dev/null 2>&1 )
WT1="$(wt_path "$R1" m1)"
PID1="$(json_num "$R1/.git/lcars/missions/m1/launch.json" pid)"
[ -n "$PID1" ] && LAUNCHED_PIDS+=("$PID1")
AFTER_HEAD="$(cd "$R1" && git rev-parse --abbrev-ref HEAD)"

# git worktree list reports the REALPATH (macOS /var → /private/var); wt_path
# canonicalizes the same way, so these are exact-string matches.
check "1a. a git worktree was created at the sibling deploy root (outside .git)" \
  "wt_registered \"$R1\" \"$WT1\""
check "1b. that worktree is DETACHED (holds no branch ref)" \
  "wt_detached \"$R1\" \"$WT1\""
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
  # S168 — the inspector SWAPPED ITS SHELL FOR A PEN: Write (to author its one
  # discovery artifact) and no general-purpose execution channel, on both engines.
  if [ "$eng" = claude ]; then
    check "2a. claude launch argv fences to Read,Grep,Glob,Write" \
      "grep -qxF 'Read,Grep,Glob,Write' \"$argvf\""
    check "2a2. claude launch argv DENIES the shell (--disallowedTools value)" \
      "grep -qxF 'Edit,Bash,NotebookEdit' \"$argvf\""
    check "2a3. claude launch argv carries the --disallowedTools flag itself" \
      "grep -qxF -- '--disallowedTools' \"$argvf\""
  else
    check "2a. copilot launch argv fences to view,grep,glob,create" \
      "grep -qxF 'view,grep,glob,create' \"$argvf\""
  fi
  # The checkout is GRANTED to the inspector now that it has no shell to reach it.
  check "2c. $eng launch argv grants the disposable checkout for reading" \
    "grep -q 'lcars-launch' \"$argvf\" || [ \"$eng\" = claude ]"
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
WT4="$(wt_path "$R4" m4)"
check "4c. the launch worktree exists before stop" \
  "wt_registered \"$R4\" \"$WT4\""

# stop
( cd "$R4" && LCARS_WORKER_BIN="$W4" bash "$LAUNCH_SH" m4 --stop >/dev/null 2>&1 )
nap 0.5
check "4d. --stop killed the app pid" "! kill -0 \"$PID4\" 2>/dev/null"
check "4e. --stop killed the CHILD too (whole process group reaped)" "! kill -0 \"$CHILD4\" 2>/dev/null"
check "4f. --stop set status=stopped" "[ \"\$(json_field \"$LJ4\" status)\" = stopped ]"
check "4g. --stop pruned the launch worktree" \
  "! wt_registered \"$R4\" \"$WT4\""

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
  "wt_registered \"$R4\" \"$WT4\""
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
# S128: a failed launch KEEPS its checkout — the evidence of WHY it failed (a
# half-provisioned node_modules, a missing binary) lives in that directory, and
# pruning it deleted the only proof the captain could have looked at. It cannot
# accumulate: the path is keyed by mission, so a re-launch reuses this same one
# and `--stop` clears it — and the message says exactly that.
check "7e. the failed launch KEPT its checkout as evidence (not pruned)" \
  "wt_registered \"$R7\" \"\$(wt_path \"$R7\" m7)\" && [ -d \"\$(wt_path \"$R7\" m7)\" ]"
check "7e2. the failure message says where that checkout is and how to clear it" \
  "printf '%s' \"\$OUT7\" | grep -qF \"\$(wt_path \"$R7\" m7)\" \
   && printf '%s' \"\$OUT7\" | grep -q -- '--stop'"
( cd "$R7" && LCARS_WORKER_BIN="$W7" bash "$LAUNCH_SH" m7 --stop >/dev/null 2>&1 )
check "7e3. --stop then clears that left-behind checkout (no accumulation)" \
  "! wt_registered \"$R7\" \"\$(wt_path \"$R7\" m7)\" && [ ! -d \"\$(wt_path \"$R7\" m7)\" ]"

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
WT8="$(wt_path "$R8" m8)"
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

# =====================================================================
# 15. RE-LAUNCH WHILE RUNNING: a second `lcars launch <mission>` while the first
#     app is STILL up must GROUP-KILL the prior recorded pid before re-spawning,
#     so the previous process is never orphaned. The old flow overwrote
#     launch.json's pid with the new one, leaving the first pid leaked (a later
#     --stop killed only the new pid). Regression-locks the shared re-launch
#     guard on the mission path.
# =====================================================================
R15="$(make_repo m15)"
APP15="$TMPROOT/app15.sh"; make_app "$APP15"
W15="$(claude_stub_path)"; make_ready_worker "$W15" "$APP15" "m15 dev server" "" "lcars launch m15 --stop"
LJ15="$R15/.git/lcars/missions/m15/launch.json"
( cd "$R15" && LCARS_WORKER_BIN="$W15" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m15 >/dev/null 2>&1 )
PID15a="$(json_num "$LJ15" pid)"
[ -n "$PID15a" ] && LAUNCHED_PIDS+=("$PID15a")
check "15a. first mission launch records a live pid" \
  "[ -n \"$PID15a\" ] && kill -0 \"$PID15a\" 2>/dev/null"
# re-launch while the first app is STILL running (worktree reused)
( cd "$R15" && LCARS_WORKER_BIN="$W15" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m15 >/dev/null 2>&1 )
PID15b="$(json_num "$LJ15" pid)"
[ -n "$PID15b" ] && LAUNCHED_PIDS+=("$PID15b")
nap 0.5
check "15b. the re-launch recorded a NEW pid (distinct from the first)" \
  "[ -n \"$PID15b\" ] && [ \"$PID15b\" != \"$PID15a\" ]"
check "15c. the first pid was KILLED by the re-launch (no orphan)" \
  "! kill -0 \"$PID15a\" 2>/dev/null"
check "15d. the second pid is alive + launch.json status=running" \
  "kill -0 \"$PID15b\" 2>/dev/null && [ \"\$(json_field \"$LJ15\" status)\" = running ]"
( cd "$R15" && LCARS_WORKER_BIN="$W15" bash "$LAUNCH_SH" m15 --stop >/dev/null 2>&1 )
nap 0.4
check "15e. after --stop the second pid is dead too" "! kill -0 \"$PID15b\" 2>/dev/null"

# =====================================================================
# 16. S167 — THE DEPLOY WORKTREE LIVES OUTSIDE `.git/`.
#     Vite's default `server.watch.ignored` contains `**/.git/**`, so a deploy cut
#     at `.git/lcars/launch/<id>` has its file watcher switched off permanently:
#     the server boots, serves, and then never sees another change (no HMR, no
#     `import.meta.glob` re-evaluation). MEASURED on DX-Scorecard 2026-07-31 —
#     same commit, two locations, one file added while the server ran: inside
#     `.git/` the glob stayed at 1 entry indefinitely, outside it reached 2 within
#     5s. Every watcher-based tool (webpack, nodemon, Tailwind JIT, tsc --watch)
#     fails identically. A deploy that cannot see its own writes is not merely
#     limited — it makes a CORRECT fix read as broken.
#     These cases pin the PATH; the tester proves the watcher for real.
# =====================================================================
R16="$(make_repo m16)"
APP16="$TMPROOT/app16.sh"; make_app "$APP16"
W16="$(claude_stub_path)"; make_ready_worker "$W16" "$APP16" "m16 dev server" "" "lcars launch m16 --stop"
( cd "$R16" && LCARS_WORKER_BIN="$W16" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m16 >/dev/null 2>&1 )
LJ16="$R16/.git/lcars/missions/m16/launch.json"
PID16="$(json_num "$LJ16" pid)"
[ -n "$PID16" ] && LAUNCHED_PIDS+=("$PID16")
WT16="$(wt_path "$R16" m16)"
WT16_REC="$(json_field "$LJ16" worktree)"

check "16a. the mission deploy's worktree path contains NO .git component" \
  "! has_dotgit_component \"$WT16_REC\""
check "16b. it is registered at <repo-parent>/.lcars-launch/<repo>/<mission>" \
  "wt_registered \"$R16\" \"$WT16\""
check "16c. launch.json records that same out-of-.git worktree path" \
  "[ \"$WT16_REC\" = \"$WT16\" ]"
check "16d. the out-of-.git checkout is a REAL checkout at the branch tip" \
  "[ -f \"$WT16/app.txt\" ]"
check "16e. it is still DETACHED (does not hold the mission branch ref)" \
  "wt_detached \"$R16\" \"$WT16\""
# STATE did NOT move with the checkout — the board's SSE fingerprint reads these.
check "16f. launch.json still lives under .git/lcars (state did not move)" \
  "[ -f \"$R16/.git/lcars/missions/m16/launch.json\" ]"
check "16g. launch-discovery.json still lives under .git/lcars" \
  "[ -f \"$R16/.git/lcars/missions/m16/launch-discovery.json\" ]"
check "16h. the deploy root is NOT nested inside the repo (vitest/globs can't see it)" \
  "case \"$WT16\" in \"$(cd "$R16" && pwd -P)\"/*) false ;; *) true ;; esac"

# --stop removes the directory AND leaves no stale registration row.
( cd "$R16" && LCARS_WORKER_BIN="$W16" bash "$LAUNCH_SH" m16 --stop >/dev/null 2>&1 )
check "16i. --stop removed the out-of-.git worktree directory" "[ ! -d \"$WT16\" ]"
check "16j. --stop left NO stale git worktree registration" \
  "! wt_registered \"$R16\" \"$WT16\" && ! (cd \"$R16\" && git worktree list --porcelain | grep -q 'm16\$')"

# =====================================================================
# 17. The --main deploy moves too, to the reserved @main key under the same root.
# =====================================================================
R17="$(make_repo m17)"
( cd "$R17" && git checkout -qb main trunk )       # give it a real main branch
APP17="$TMPROOT/app17.sh"; make_app "$APP17"
W17="$(claude_stub_path)"; make_ready_worker "$W17" "$APP17" "main deploy" "" "lcars launch --main --stop"
( cd "$R17" && LCARS_WORKER_BIN="$W17" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ17="$R17/.git/lcars/main/launch.json"
PID17="$(json_num "$LJ17" pid)"
[ -n "$PID17" ] && LAUNCHED_PIDS+=("$PID17")
WT17="$(wt_path "$R17" @main)"
check "17a. the --main deploy's worktree path contains NO .git component" \
  "! has_dotgit_component \"\$(json_field \"$LJ17\" worktree)\""
check "17b. the --main deploy sits at the reserved @main key outside .git" \
  "wt_registered \"$R17\" \"$WT17\""
check "17c. the --main deploy's STATE still lives at .git/lcars/main/launch.json" \
  "[ -f \"$LJ17\" ]"
( cd "$R17" && LCARS_WORKER_BIN="$W17" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )
check "17d. --main --stop removed the out-of-.git @main directory + registration" \
  "[ ! -d \"$WT17\" ] && ! wt_registered \"$R17\" \"$WT17\""

# =====================================================================
# 18. COLLISION SAFETY: two repos with the SAME basename under DIFFERENT parents
#     must not share a launch root. The key is the repo's CANONICAL parent dir, so
#     the two roots are structurally distinct and neither deploy can see (or tear
#     down) the other's.
# =====================================================================
mkdir -p "$TMPROOT/pa" "$TMPROOT/pb"
R18a="$(make_repo m18 "" "$TMPROOT/pa/samename")"
R18b="$(make_repo m18 "" "$TMPROOT/pb/samename")"
APP18="$TMPROOT/app18.sh"; make_app "$APP18"
W18="$(claude_stub_path)"; make_ready_worker "$W18" "$APP18" "twin dev server" "" "stop"
( cd "$R18a" && LCARS_WORKER_BIN="$W18" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m18 >/dev/null 2>&1 )
( cd "$R18b" && LCARS_WORKER_BIN="$W18" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m18 >/dev/null 2>&1 )
PID18a="$(json_num "$R18a/.git/lcars/missions/m18/launch.json" pid)"; [ -n "$PID18a" ] && LAUNCHED_PIDS+=("$PID18a")
PID18b="$(json_num "$R18b/.git/lcars/missions/m18/launch.json" pid)"; [ -n "$PID18b" ] && LAUNCHED_PIDS+=("$PID18b")
WT18a="$(wt_path "$R18a" m18)"; WT18b="$(wt_path "$R18b" m18)"
check "18a. same-basename repos in different parents get DIFFERENT launch roots" \
  "[ \"$WT18a\" != \"$WT18b\" ]"
check "18b. both twins have their own live worktree" \
  "wt_registered \"$R18a\" \"$WT18a\" && wt_registered \"$R18b\" \"$WT18b\""
check "18c. neither twin's launch root is a parent of the other's" \
  "case \"$WT18b\" in \"$(dirname "$WT18a")\"/*) false ;; *) true ;; esac"
# Stopping one twin must not disturb the other.
( cd "$R18a" && LCARS_WORKER_BIN="$W18" bash "$LAUNCH_SH" m18 --stop >/dev/null 2>&1 )
nap 0.4
check "18d. stopping twin A leaves twin B's worktree + pid untouched" \
  "[ ! -d \"$WT18a\" ] && [ -d \"$WT18b\" ] && kill -0 \"$PID18b\" 2>/dev/null"
( cd "$R18b" && LCARS_WORKER_BIN="$W18" bash "$LAUNCH_SH" m18 --stop >/dev/null 2>&1 )

# =====================================================================
# 19. IDEMPOTENT RE-LAUNCH: a second launch REUSES the worktree at the new path —
#     it does not cut a second one. Proof: a sentinel dropped into the checkout
#     survives (a fresh cut would have wiped it) and exactly ONE registration row
#     points at the path.
# =====================================================================
R19="$(make_repo m19)"
APP19="$TMPROOT/app19.sh"; make_app "$APP19"
W19="$(claude_stub_path)"; make_ready_worker "$W19" "$APP19" "m19 dev server" "" "stop"
( cd "$R19" && LCARS_WORKER_BIN="$W19" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m19 >/dev/null 2>&1 )
WT19="$(wt_path "$R19" m19)"
PID19a="$(json_num "$R19/.git/lcars/missions/m19/launch.json" pid)"; [ -n "$PID19a" ] && LAUNCHED_PIDS+=("$PID19a")
printf 'reuse me\n' > "$WT19/.reuse-sentinel"
( cd "$R19" && LCARS_WORKER_BIN="$W19" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m19 >/dev/null 2>&1 )
PID19b="$(json_num "$R19/.git/lcars/missions/m19/launch.json" pid)"; [ -n "$PID19b" ] && LAUNCHED_PIDS+=("$PID19b")
check "19a. re-launch REUSED the existing worktree (sentinel survived)" \
  "[ -f \"$WT19/.reuse-sentinel\" ]"
check "19b. exactly ONE worktree row points at the deploy path (no second cut)" \
  "[ \"\$(wt_rows \"$R19\" \"$WT19\")\" = 1 ]"
( cd "$R19" && LCARS_WORKER_BIN="$W19" bash "$LAUNCH_SH" m19 --stop >/dev/null 2>&1 )

# =====================================================================
# 20. MIGRATION, not stranding. A captain mid-round may already have a deploy at
#     the OLD in-`.git` path. The next launch must REMOVE + PRUNE it before cutting
#     the new one — never leave two checkouts of one mission, and never leave a
#     live server pointing at a directory that has been torn down (so the migration
#     must cooperate with the existing re-launch pid kill, which runs first).
# =====================================================================
R20="$(make_repo m20)"
APP20="$TMPROOT/app20.sh"; make_app "$APP20"
W20="$(claude_stub_path)"; make_ready_worker "$W20" "$APP20" "m20 dev server" "" "stop"
OLD20="$(cd "$R20" && pwd -P)/.git/lcars/launch/m20"
SHA20="$(cd "$R20" && git rev-parse "lcars/m20")"
mkdir -p "$(dirname "$OLD20")"
( cd "$R20" && git worktree add --detach "$OLD20" "$SHA20" >/dev/null 2>&1 )
# A LIVE server pointing at the old checkout, recorded exactly as a real launch
# would have recorded it (pid + pgid in the mission's launch.json).
perl -e 'select(undef,undef,undef,30)' & OLDPID20=$!
LAUNCHED_PIDS+=("$OLDPID20")
mkdir -p "$R20/.git/lcars/missions/m20"
printf '{\n  "status": "running",\n  "worktree": "%s",\n  "pid": %s,\n  "pgid": %s\n}\n' \
  "$OLD20" "$OLDPID20" "$OLDPID20" > "$R20/.git/lcars/missions/m20/launch.json"
check "20a. (setup) the legacy in-.git worktree really is registered" \
  "(cd \"$R20\" && git worktree list --porcelain | grep -qxF \"worktree $OLD20\")"
( cd "$R20" && LCARS_WORKER_BIN="$W20" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m20 >/dev/null 2>&1 )
WT20="$(wt_path "$R20" m20)"
PID20="$(json_num "$R20/.git/lcars/missions/m20/launch.json" pid)"; [ -n "$PID20" ] && LAUNCHED_PIDS+=("$PID20")
nap 0.4
check "20b. the legacy in-.git worktree was PRUNED from git worktree list" \
  "! (cd \"$R20\" && git worktree list --porcelain | grep -qxF \"worktree $OLD20\")"
check "20c. the legacy in-.git directory was REMOVED (no second checkout)" \
  "[ ! -d \"$OLD20\" ]"
check "20d. the new out-of-.git worktree was cut and is registered" \
  "wt_registered \"$R20\" \"$WT20\" && [ -f \"$WT20/app.txt\" ]"
check "20e. the server that pointed at the torn-down old path was reaped" \
  "! kill -0 \"$OLDPID20\" 2>/dev/null"
check "20f. the re-launched app is alive at the NEW path" \
  "kill -0 \"$PID20\" 2>/dev/null"
( cd "$R20" && LCARS_WORKER_BIN="$W20" bash "$LAUNCH_SH" m20 --stop >/dev/null 2>&1 )

# 20g. --stop also clears a legacy in-.git worktree, so a captain who stops
#      (rather than re-launches) after upgrading is not left with a stale row.
R20b="$(make_repo m20b)"
OLD20b="$(cd "$R20b" && pwd -P)/.git/lcars/launch/m20b"
SHA20b="$(cd "$R20b" && git rev-parse "lcars/m20b")"
mkdir -p "$(dirname "$OLD20b")"
( cd "$R20b" && git worktree add --detach "$OLD20b" "$SHA20b" >/dev/null 2>&1 )
( cd "$R20b" && LCARS_WORKER_BIN="$W20" bash "$LAUNCH_SH" m20b --stop >/dev/null 2>&1 )
check "20g. --stop prunes a legacy in-.git worktree too (no stale row, no dir)" \
  "! (cd \"$R20b\" && git worktree list --porcelain | grep -qxF \"worktree $OLD20b\") && [ ! -d \"$OLD20b\" ]"

# =====================================================================
# 21. TEARDOWN ISOLATION within ONE repo: two missions deployed side by side under
#     the same launch root; stopping one must not disturb the other's checkout,
#     registration or process.
# =====================================================================
R21="$(make_repo m21a)"
# a second mission in the SAME repo
( cd "$R21" && git checkout -qb "lcars/m21b" trunk && printf 'b\n' > b.txt \
    && git add . && git commit -qm "m21b work" && git checkout -q trunk )
M21B="$R21/.git/lcars/missions/m21b"; mkdir -p "$M21B"
printf '{\n  "id": "m21b",\n  "stage": "verify",\n  "branch": "lcars/m21b",\n  "base": "trunk"\n}\n' > "$M21B/state.json"
APP21="$TMPROOT/app21.sh"; make_app "$APP21"
W21="$(claude_stub_path)"; make_ready_worker "$W21" "$APP21" "sibling dev server" "" "stop"
( cd "$R21" && LCARS_WORKER_BIN="$W21" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m21a >/dev/null 2>&1 )
( cd "$R21" && LCARS_WORKER_BIN="$W21" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m21b >/dev/null 2>&1 )
WT21A="$(wt_path "$R21" m21a)"; WT21B="$(wt_path "$R21" m21b)"
PID21A="$(json_num "$R21/.git/lcars/missions/m21a/launch.json" pid)"; [ -n "$PID21A" ] && LAUNCHED_PIDS+=("$PID21A")
PID21B="$(json_num "$R21/.git/lcars/missions/m21b/launch.json" pid)"; [ -n "$PID21B" ] && LAUNCHED_PIDS+=("$PID21B")
check "21a. two missions of one repo get sibling deploys under the same root" \
  "wt_registered \"$R21\" \"$WT21A\" && wt_registered \"$R21\" \"$WT21B\" && [ \"\$(dirname \"$WT21A\")\" = \"\$(dirname \"$WT21B\")\" ]"
( cd "$R21" && LCARS_WORKER_BIN="$W21" bash "$LAUNCH_SH" m21a --stop >/dev/null 2>&1 )
nap 0.4
check "21b. stopping m21a removed ONLY its own worktree" \
  "[ ! -d \"$WT21A\" ] && ! wt_registered \"$R21\" \"$WT21A\""
check "21c. m21b's worktree, registration and process are untouched" \
  "[ -d \"$WT21B\" ] && wt_registered \"$R21\" \"$WT21B\" && kill -0 \"$PID21B\" 2>/dev/null"
( cd "$R21" && LCARS_WORKER_BIN="$W21" bash "$LAUNCH_SH" m21b --stop >/dev/null 2>&1 )
check "21d. after both stops the shared launch root is left clean (no orphan dirs)" \
  "[ ! -d \"$WT21A\" ] && [ ! -d \"$WT21B\" ]"

# =====================================================================
# 22. UNWRITABLE PARENT → a plain-English refusal naming the deploy area, never a
#     crash or a half-made worktree. (UX-33: name what went wrong + what to try.)
# =====================================================================
R22="$(make_repo m22 "" "$TMPROOT/ro22/repo")"
APP22="$TMPROOT/app22.sh"; make_app "$APP22"
W22="$(claude_stub_path)"; make_ready_worker "$W22" "$APP22" "m22 dev server" "" "stop"
chmod a-w "$TMPROOT/ro22"
OUT22="$( cd "$R22" && LCARS_WORKER_BIN="$W22" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m22 2>&1 )"; RC22=$?
chmod u+w "$TMPROOT/ro22"
check "22a. an unwritable repo parent → exit non-zero" "[ \"$RC22\" != 0 ]"
check "22b. the refusal is plain English naming the deploy area (no stack trace)" \
  "printf '%s' \"\$OUT22\" | grep -qi 'deploy' && printf '%s' \"\$OUT22\" | grep -qiE 'writ|permission'"
check "22c. nothing was launched (no running record)" \
  "[ \"\$(json_field \"$R22/.git/lcars/missions/m22/launch.json\" status)\" != running ]"

# =====================================================================
# 23. THE IN-`.git/` REFUSAL NAMES THE CAUSE THAT ACTUALLY APPLIES.
#     Two different causes reach the same guard, and each has a DIFFERENT fix:
#       (a) $LCARS_LAUNCH_ROOT was set and is what put the root under `.git/` —
#           the operator's fix is to change or unset that variable. Telling them
#           to "run from the repo's own checkout" is a dead end: they already are.
#       (b) the root was DERIVED (no override) from a repo that itself lives under
#           a `.git/` — e.g. invoked inside one of run.sh's stage-tree worktrees.
#           THEN "run from the repo's own checkout" is the right advice.
#     The refusal itself is correct in both cases and must stay: a deploy under
#     `.git/` is invisible to every watcher-based dev tool.
# =====================================================================
# 23a–c. CAUSE (a): the override put it there.
R23="$(make_repo m23)"
W23="$(claude_stub_path)"; make_ready_worker "$W23" "/bin/true" "m23 dev server" "" "stop"
BAD_ROOT23="$R23/.git/lcars/launch-red"
OUT23="$( cd "$R23" && LCARS_LAUNCH_ROOT="$BAD_ROOT23" LCARS_WORKER_BIN="$W23" LCARS_LAUNCH_SETTLE=0.6 \
  bash "$LAUNCH_SH" m23 the app 2>&1 )"; RC23=$?
check "23a. an override pointing under .git/ is still REFUSED (non-zero)" "[ \"$RC23\" != 0 ]"
check "23b. the refusal NAMES \$LCARS_LAUNCH_ROOT as the cause and how to fix it" \
  "printf '%s' \"\$OUT23\" | grep -q 'LCARS_LAUNCH_ROOT' \
   && printf '%s' \"\$OUT23\" | grep -qiE 'unset|point it|change it'"
check "23c. it does NOT hand back the dead-end 'run from the repo's own checkout'" \
  "! printf '%s' \"\$OUT23\" | grep -qi \"repo's own checkout\""
check "23d. nothing was deployed under .git/ (the guard held)" \
  "[ ! -d \"$BAD_ROOT23\" ]"

# 23e–g. CAUSE (b): no override — the repo itself sits under a `.git/`, so the
# DERIVED root does too. Staged the way it actually happens: a checkout living
# inside another tree's `.git/` (run.sh cuts its stage-trees at `.git/lcars/...`).
R23B="$(make_repo m23b "" "$TMPROOT/host23/.git/lcars/stage-tree/repo")"
W23B="$(claude_stub_path)"; make_ready_worker "$W23B" "/bin/true" "m23b dev server" "" "stop"
OUT23B="$( cd "$R23B" && LCARS_WORKER_BIN="$W23B" LCARS_LAUNCH_SETTLE=0.6 \
  bash "$LAUNCH_SH" m23b 2>&1 )"; RC23B=$?
check "23e. a DERIVED root under .git/ is refused (non-zero)" "[ \"$RC23B\" != 0 ]"
check "23f. that refusal keeps the checkout advice, which IS the fix here" \
  "printf '%s' \"\$OUT23B\" | grep -qi \"repo's own checkout\""
check "23g. and it does NOT blame an env var the operator never set" \
  "! printf '%s' \"\$OUT23B\" | grep -q 'LCARS_LAUNCH_ROOT'"
# Both messages stay plain English — they say what is wrong, not how it failed.
check "23h. both refusals are plain English (no stack trace / shell noise)" \
  "! printf '%s' \"\$OUT23\" | grep -qE 'line [0-9]+:|Traceback|command not found' \
   && ! printf '%s' \"\$OUT23B\" | grep -qE 'line [0-9]+:|Traceback|command not found'"

# =====================================================================
# 24. S128 — PROVISIONING HONESTY. A mission that ADDS A DEPENDENCY could not be
#     launched and EVERY surface lied about why (measured on groutwork,
#     2026-08-06):
#       • `pnpm install --frozen-lockfile` printed ERR_PNPM_OUTDATED_LOCKFILE and
#         STILL EXITED 0 — so an exit code alone is not the signal;
#       • provisioning ran as `( cd wt && bash -c "$cmd" ) >/dev/null 2>&1`, so
#         that line was thrown away unread;
#       • the app then died with `electron-vite: command not found` — a symptom
#         three layers from the cause — and the failure path PRUNED the worktree,
#         deleting the evidence.
#     The cure is launch-UX honesty, NOT a build gate: capture what provisioning
#     said, carry the REAL reason into the message a person reads, and leave the
#     checkout behind (keyed by mission, so `--stop` still clears it).
# =====================================================================
# 24a/b. The output is CAPTURED, both streams, to a log that outlives the launch.
R24="$(make_repo m24)"
APP24="$TMPROOT/app24.sh"; make_app "$APP24"
W24="$(claude_stub_path)"; make_ready_worker "$W24" "$APP24" "m24 dev server" "" "stop"
( cd "$R24" && LCARS_WORKTREE_SETUP_CMD='echo PROV-STDOUT-MARK; echo PROV-STDERR-MARK >&2' \
    LCARS_WORKER_BIN="$W24" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m24 >/dev/null 2>&1 )
PID24="$(json_num "$R24/.git/lcars/missions/m24/launch.json" pid)"
[ -n "$PID24" ] && LAUNCHED_PIDS+=("$PID24")
PROVLOG24="$R24/.git/lcars/missions/m24/launch-provision.log"
check "24a. provisioning STDOUT is captured to a log a person can read after the fact" \
  "grep -q PROV-STDOUT-MARK \"$PROVLOG24\""
check "24b. provisioning STDERR is captured to that same log (nothing swallowed)" \
  "grep -q PROV-STDERR-MARK \"$PROVLOG24\""
( cd "$R24" && LCARS_WORKER_BIN="$W24" bash "$LAUNCH_SH" m24 --stop >/dev/null 2>&1 )

# 24c–i. THE EXIT-0 LIAR: provisioning prints ERR_PNPM_OUTDATED_LOCKFILE and exits
#        0; the app then dies with the downstream symptom. The message the person
#        sees must lead with the REAL reason, still show the symptom, name the
#        escape hatch, and leave the checkout behind.
R24b="$(make_repo m24b)"
DEAD24="$TMPROOT/app24b.sh"
cat >"$DEAD24" <<'EOF'
#!/usr/bin/env bash
echo "sh: electron-vite: command not found" >&2
exit 127
EOF
chmod +x "$DEAD24"
W24b="$(claude_stub_path)"; make_ready_worker "$W24b" "$DEAD24" "m24b editor" "" "stop"
LOCKERR='echo " ERR_PNPM_OUTDATED_LOCKFILE  Cannot install with frozen-lockfile because pnpm-lock.yaml is not up to date with package.json" >&2; exit 0'
OUT24b="$( cd "$R24b" && LCARS_WORKTREE_SETUP_CMD="$LOCKERR" \
    LCARS_WORKER_BIN="$W24b" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m24b 2>&1 )"; RC24b=$?
LJ24b="$R24b/.git/lcars/missions/m24b/launch.json"
WT24b="$(wt_path "$R24b" m24b)"
check "24c. a provisioning failure that EXITS 0 is still caught → non-zero, status=failed" \
  "[ \"$RC24b\" != 0 ] && [ \"\$(json_field \"$LJ24b\" status)\" = failed ]"
check "24d. the message names the REAL reason (the lockfile), not just the symptom" \
  "printf '%s' \"\$OUT24b\" | grep -qi 'lockfile'"
check "24e. it still reports the symptom the app itself printed" \
  "printf '%s' \"\$OUT24b\" | grep -q 'electron-vite'"
check "24f. it names the escape hatch the person can actually use" \
  "printf '%s' \"\$OUT24b\" | grep -q 'LCARS_WORKTREE_SETUP_CMD'"
check "24g. it points at the captured setup output" \
  "printf '%s' \"\$OUT24b\" | grep -qF 'launch-provision.log'"
check "24h. the checkout was NOT pruned — the evidence survives the failure" \
  "[ -d \"$WT24b\" ] && wt_registered \"$R24b\" \"$WT24b\""
check "24i. the persisted record carries the real reason too (what the board reads)" \
  "printf '%s' \"\$(json_field \"$LJ24b\" message)\" | grep -qi 'lockfile'"
check "24j. the message is plain English, not a raw stack trace" \
  "! printf '%s' \"\$OUT24b\" | grep -qE 'Traceback|line [0-9]+:'"
( cd "$R24b" && LCARS_WORKER_BIN="$W24b" bash "$LAUNCH_SH" m24b --stop >/dev/null 2>&1 )

# 24k/l. An ORDINARY non-zero provisioning exit is reported the same way.
R24c="$(make_repo m24c)"
W24c="$(claude_stub_path)"; make_ready_worker "$W24c" "$DEAD24" "m24c editor" "" "stop"
OUT24c="$( cd "$R24c" && LCARS_WORKTREE_SETUP_CMD='echo "no such package: @groutwork/nope" >&2; exit 3' \
    LCARS_WORKER_BIN="$W24c" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m24c 2>&1 )"; RC24c=$?
check "24k. a non-zero provisioning exit → the failure names dependency setup" \
  "[ \"$RC24c\" != 0 ] && printf '%s' \"\$OUT24c\" | grep -qi 'dependency setup'"
check "24l. and quotes what it actually said" \
  "printf '%s' \"\$OUT24c\" | grep -q 'no such package'"
check "24l2. and names the escape hatch on ANY provisioning failure, not just the lockfile one" \
  "printf '%s' \"\$OUT24c\" | grep -q 'LCARS_WORKTREE_SETUP_CMD'"
( cd "$R24c" && LCARS_WORKER_BIN="$W24c" bash "$LAUNCH_SH" m24c --stop >/dev/null 2>&1 )

# 24q/r. THE SILENCED SETUP — MEASURED on groutwork 2026-08-06, pnpm 9.0.0. Its
#        configured worktreeSetupCommand ends in `--silent`, which SWALLOWS pnpm's
#        own `ERR_PNPM_OUTDATED_LOCKFILE` line: the captured log then holds nothing
#        but a node DeprecationWarning. Quoting the log's tail blindly presents
#        that warning AS the reason — a new lie in place of the old one. So a
#        warning must never be dressed up as the failure, and when nothing in the
#        output explains the failure the message must SAY that (and name the
#        --silent flag that hides it) rather than invent a cause.
#        (S128 fix round 1 / L-4: the --silent ADVICE is only true when the setup
#        command actually carries the flag, so this fixture's command now does —
#        exactly as groutwork's configured one does. The advice-when-there-is-no
#        --silent case is 25e below.)
R24f="$(make_repo m24f)"
W24f="$(claude_stub_path)"; make_ready_worker "$W24f" "$DEAD24" "m24f editor" "" "stop"
NOISY='echo "(node:123) [DEP0169] DeprecationWarning: url.parse() is prone to errors that have security implications." >&2; : pnpm install --frozen-lockfile --silent; exit 1'
OUT24f="$( cd "$R24f" && LCARS_WORKTREE_SETUP_CMD="$NOISY" \
    LCARS_WORKER_BIN="$W24f" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m24f 2>&1 )"; RC24f=$?
check "24q. a warning in the setup output is NOT presented as the failure reason" \
  "[ \"$RC24f\" != 0 ] && ! printf '%s' \"\$OUT24f\" | grep -q 'DeprecationWarning'"
check "24r. instead it admits the output explains nothing, and names --silent as the likely reason why" \
  "printf '%s' \"\$OUT24f\" | grep -qi 'nothing that explains' \
   && printf '%s' \"\$OUT24f\" | grep -q -- '--silent'"
( cd "$R24f" && LCARS_WORKER_BIN="$W24f" bash "$LAUNCH_SH" m24f --stop >/dev/null 2>&1 )

# 24m/n. Provisioning failed but the app came up ANYWAY (deps were already there
#        from a reused worktree): the launch still succeeds — best-effort is kept,
#        so this can never refuse a launch that would have worked — but the
#        readout and the record SAY that setup reported a problem.
R24d="$(make_repo m24d)"
APP24d="$TMPROOT/app24d.sh"; make_app "$APP24d"
W24d="$(claude_stub_path)"; make_ready_worker "$W24d" "$APP24d" "m24d dev server" "" "stop"
OUT24d="$( cd "$R24d" && LCARS_WORKTREE_SETUP_CMD='echo "half-installed" >&2; exit 1' \
    LCARS_WORKER_BIN="$W24d" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m24d 2>&1 )"; RC24d=$?
LJ24d="$R24d/.git/lcars/missions/m24d/launch.json"
PID24d="$(json_num "$LJ24d" pid)"
[ -n "$PID24d" ] && LAUNCHED_PIDS+=("$PID24d")
check "24m. a provisioning failure never blocks an app that does come up (still running)" \
  "[ \"$RC24d\" = 0 ] && [ \"\$(json_field \"$LJ24d\" status)\" = running ]"
check "24n. but the readout warns that dependency setup reported a problem" \
  "printf '%s' \"\$OUT24d\" | grep -qi 'dependency setup'"
( cd "$R24d" && LCARS_WORKER_BIN="$W24d" bash "$LAUNCH_SH" m24d --stop >/dev/null 2>&1 )

# 24o/p. NO FALSE ALARM: clean provisioning + a healthy app → the readout is
#        exactly today's, with no warning and no provisioning noise.
R24e="$(make_repo m24e)"
APP24e="$TMPROOT/app24e.sh"; make_app "$APP24e"
W24e="$(claude_stub_path)"; make_ready_worker "$W24e" "$APP24e" "m24e dev server" "" "stop"
OUT24e="$( cd "$R24e" && LCARS_WORKTREE_SETUP_CMD='echo installing; exit 0' \
    LCARS_WORKER_BIN="$W24e" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m24e 2>&1 )"; RC24e=$?
LJ24e="$R24e/.git/lcars/missions/m24e/launch.json"
PID24e="$(json_num "$LJ24e" pid)"
[ -n "$PID24e" ] && LAUNCHED_PIDS+=("$PID24e")
check "24o. clean provisioning → status=running with no warning in the readout" \
  "[ \"$RC24e\" = 0 ] && [ \"\$(json_field \"$LJ24e\" status)\" = running ] \
   && ! printf '%s' \"\$OUT24e\" | grep -qi 'problem'"
check "24p. and the record carries no provisioning complaint" \
  "! grep -q '\"provisioning\"' \"$LJ24e\""
( cd "$R24e" && LCARS_WORKER_BIN="$W24e" bash "$LAUNCH_SH" m24e --stop >/dev/null 2>&1 )

# =====================================================================
# 25. S128 fix round 1 — the new failure messages must themselves be HONEST.
#     A fresh tester drove the round-0 cure on the real ~/Projects/groutwork and
#     caught it telling the captain three wrong things. Every fixture below is a
#     shape that drive produced verbatim.
# =====================================================================

# 25a/b. L-4a — the reason-extractor threw away every line containing "warn",
#        which drops the single most common way an install or a build announces
#        failure: "N warnings being treated as errors". MEASURED: that line in the
#        log, and the message said the output "printed nothing that explains why".
R25="$(make_repo m25)"
W25="$(claude_stub_path)"; make_ready_worker "$W25" "$DEAD24" "m25 editor" "" "stop"
WERR='echo "error: 12 warnings being treated as errors" >&2; exit 1'
OUT25="$( cd "$R25" && LCARS_WORKTREE_SETUP_CMD="$WERR" \
    LCARS_WORKER_BIN="$W25" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m25 2>&1 )"
check "25a. an error line that MENTIONS warnings is still quoted as the reason" \
  "printf '%s' \"\$OUT25\" | grep -q 'treated as errors'"
check "25b. and the message never claims the output explained nothing" \
  "! printf '%s' \"\$OUT25\" | grep -qi 'nothing that explains'"
# The record this same failure persisted — read BEFORE --stop overwrites it.
MSG25="$(json_field "$R25/.git/lcars/missions/m25/launch.json" message)"
( cd "$R25" && LCARS_WORKER_BIN="$W25" bash "$LAUNCH_SH" m25 --stop >/dev/null 2>&1 )

# 25c/d. L-4b — `fatal:` (git's own error prefix, and common to installers) was
#        not in the vocabulary at all, and neither was "could not" (only "cannot").
#        MEASURED: `fatal: could not reach the registry`, exit 7 → same false claim.
R25b="$(make_repo m25b)"
W25b="$(claude_stub_path)"; make_ready_worker "$W25b" "$DEAD24" "m25b editor" "" "stop"
FATAL='echo "fatal: could not reach the registry" >&2; exit 7'
OUT25b="$( cd "$R25b" && LCARS_WORKTREE_SETUP_CMD="$FATAL" \
    LCARS_WORKER_BIN="$W25b" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m25b 2>&1 )"
check "25c. a fatal: line is recognised as the reason" \
  "printf '%s' \"\$OUT25b\" | grep -q 'could not reach the registry'"
check "25d. and that failure never claims the output explained nothing" \
  "! printf '%s' \"\$OUT25b\" | grep -qi 'nothing that explains'"
( cd "$R25b" && LCARS_WORKER_BIN="$W25b" bash "$LAUNCH_SH" m25b --stop >/dev/null 2>&1 )

# 25e/f. L-4c — "if the setup command runs with --silent, drop that flag" was
#        offered UNCONDITIONALLY, so a captain whose command has no such flag was
#        sent hunting for one. The skill already knows the command string.
R25c="$(make_repo m25c)"
W25c="$(claude_stub_path)"; make_ready_worker "$W25c" "$DEAD24" "m25c editor" "" "stop"
QUIET='echo "(node:123) [DEP0169] DeprecationWarning: url.parse() is prone to errors." >&2; exit 1'
OUT25c="$( cd "$R25c" && LCARS_WORKTREE_SETUP_CMD="$QUIET" \
    LCARS_WORKER_BIN="$W25c" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m25c 2>&1 )"
check "25e. with no --silent in the setup command, the message never advises dropping one" \
  "! printf '%s' \"\$OUT25c\" | grep -q -- '--silent'"
check "25f. but it still admits the output explains nothing rather than inventing a cause" \
  "printf '%s' \"\$OUT25c\" | grep -qi 'nothing that explains'"
( cd "$R25c" && LCARS_WORKER_BIN="$W25c" bash "$LAUNCH_SH" m25c --stop >/dev/null 2>&1 )

# 25g/h. L-5 — the pnpm diagnosis fired on the STRING, not the failure. MEASURED:
#        a setup command that merely MENTIONS the code and exits 0, on a launch
#        that WORKED, produced a confidently specific, entirely invented diagnosis.
#        Staying independent of the exit code is deliberate (pnpm can exit 0 on
#        this — that was the original defect), so the cure is to recognise pnpm
#        REFUSING, not a passing mention.
R25d="$(make_repo m25d)"
APP25d="$TMPROOT/app25d.sh"; make_app "$APP25d"
W25d="$(claude_stub_path)"; make_ready_worker "$W25d" "$APP25d" "m25d dev server" "" "stop"
MENTION='echo "note: we used to hit ERR_PNPM_OUTDATED_LOCKFILE here, but no longer"; exit 0'
OUT25d="$( cd "$R25d" && LCARS_WORKTREE_SETUP_CMD="$MENTION" \
    LCARS_WORKER_BIN="$W25d" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m25d 2>&1 )"; RC25d=$?
LJ25d="$R25d/.git/lcars/missions/m25d/launch.json"
PID25d="$(json_num "$LJ25d" pid)"
[ -n "$PID25d" ] && LAUNCHED_PIDS+=("$PID25d")
check "25g. a passing MENTION of the pnpm code on a clean run raises no diagnosis" \
  "[ \"$RC25d\" = 0 ] && [ \"\$(json_field \"$LJ25d\" status)\" = running ] \
   && ! printf '%s' \"\$OUT25d\" | grep -qi 'lockfile is out of date'"
check "25h. and the record carries no provisioning complaint" \
  "! grep -q '\"provisioning\"' \"$LJ25d\""
( cd "$R25d" && LCARS_WORKER_BIN="$W25d" bash "$LAUNCH_SH" m25d --stop >/dev/null 2>&1 )

# 25i/j. L-6 — provision_worktree returns early when NO setup command is
#        configured, BEFORE it truncates the log, while fail_msg cites the log on
#        mere existence. So in a repo with no setup command, a failure points the
#        captain at an UNRELATED, stale log left by an earlier launch that used the
#        $LCARS_WORKTREE_SETUP_CMD override. (Compare `rm -f $LAUNCH_DISCOVERY`,
#        which handles exactly this hazard for the other artifact.)
R25e="$(make_repo m25e)"
APP25e="$TMPROOT/app25e.sh"; make_app "$APP25e"
W25eOK="$(claude_stub_path)"; make_ready_worker "$W25eOK" "$APP25e" "m25e dev server" "" "stop"
( cd "$R25e" && LCARS_WORKTREE_SETUP_CMD='echo STALE-PROV-MARK; exit 0' \
    LCARS_WORKER_BIN="$W25eOK" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m25e >/dev/null 2>&1 )
PID25e="$(json_num "$R25e/.git/lcars/missions/m25e/launch.json" pid)"
[ -n "$PID25e" ] && LAUNCHED_PIDS+=("$PID25e")
PROVLOG25="$R25e/.git/lcars/missions/m25e/launch-provision.log"
STALE_WAS_THERE=0; grep -q STALE-PROV-MARK "$PROVLOG25" 2>/dev/null && STALE_WAS_THERE=1
( cd "$R25e" && LCARS_WORKER_BIN="$W25eOK" bash "$LAUNCH_SH" m25e --stop >/dev/null 2>&1 )
# Now a launch with NO setup command at all (no override, no repo config), whose
# app dies: nothing was provisioned this time, so nothing may be cited.
W25e="$(claude_stub_path)"; make_ready_worker "$W25e" "$DEAD24" "m25e editor" "" "stop"
OUT25e="$( cd "$R25e" && LCARS_WORKER_BIN="$W25e" LCARS_LAUNCH_SETTLE=0.6 \
    bash "$LAUNCH_SH" m25e 2>&1 )"
check "25i. an earlier launch's provisioning log is cleared when nothing provisions now" \
  "[ \"$STALE_WAS_THERE\" = 1 ] && ! grep -q STALE-PROV-MARK \"$PROVLOG25\" 2>/dev/null"
check "25j. and the failure never points the captain at that stale evidence" \
  "! printf '%s' \"\$OUT25e\" | grep -qF 'Setup output'"
( cd "$R25e" && LCARS_WORKER_BIN="$W25e" bash "$LAUNCH_SH" m25e --stop >/dev/null 2>&1 )

# 25k/l. COSMETIC (the captain asked for cosmetic items this round): the failure
#        ran cause, symptom, evidence and cleanup together on ONE ~600-character
#        terminal line. Break it so the cause reads at a glance — while the
#        PERSISTED record stays the single-line string the board renders today
#        (json_esc does not escape newlines, so a raw one would corrupt the JSON).
check "25k. the failure message breaks before the app's symptom" \
  "printf '%s\n' \"\$OUT25\" | grep -q '^The app then failed:'"
check "25l. and again before the left-behind checkout" \
  "printf '%s\n' \"\$OUT25\" | grep -q '^The checkout is left in place'"
check "25m. but the persisted record's message is still ONE line, carrying both parts" \
  "[ \"\$(printf '%s' \"\$MSG25\" | wc -l | tr -d ' ')\" = 0 ] \
   && printf '%s' \"\$MSG25\" | grep -q 'The app then failed' \
   && printf '%s' \"\$MSG25\" | grep -q 'treated as errors'"

# =====================================================================
# 26. S187 — THE URL IS VERIFIED, NOT PREDICTED.
#     launch.json's `url` used to be whatever the discovery worker GUESSED,
#     written into the running record untouched. The app's real bound port was
#     never observed: liveness only proves the PROCESS is up, and the
#     best-effort curl probe happily 200s against a DIFFERENT repo's app that
#     already holds the predicted port. Measured 2026-09-04: repo A's Vite held
#     5173, repo B predicted 5173 and silently bound 5174, and B's board linked
#     A's app. The fix OBSERVES: enumerate the launched process group, read its
#     LISTEN sockets, and make the record say where the app actually is.
# =====================================================================

# 26a. The toolchain the verification stands on (asserted, never spiked).
check "26a. pgrep -g and lsof are available (the verification toolchain)" \
  "command -v pgrep >/dev/null 2>&1 && { command -v lsof >/dev/null 2>&1 || [ -x /usr/sbin/lsof ]; }"

# 26b-d. A CORRECT prediction must survive untouched — verification is not an
#        excuse to rewrite a url that was already right.
P26="$(free_port)"
R26="$(make_repo m26)"
APP26="$TMPROOT/app26.sh"; make_binding_app "$APP26" "$P26"
W26="$(claude_stub_path)"
make_ready_worker "$W26" "$APP26" "m26 dev server" "http://localhost:$P26" "stop"
OUT26="$( cd "$R26" && LCARS_WORKER_BIN="$W26" LCARS_LAUNCH_SETTLE=1.5 bash "$LAUNCH_SH" m26 2>&1 )"
LJ26="$R26/.git/lcars/missions/m26/launch.json"
PID26="$(json_num "$LJ26" pid)"; [ -n "$PID26" ] && LAUNCHED_PIDS+=("$PID26")
check "26b. an app that binds exactly the predicted port keeps that url" \
  "[ \"\$(json_field \"$LJ26\" url)\" = \"http://localhost:$P26\" ]"
check "26c. and the prediction is recorded alongside it (predictedUrl)" \
  "[ \"\$(json_field \"$LJ26\" predictedUrl)\" = \"http://localhost:$P26\" ]"
check "26d. a right guess raises NO mismatch note anywhere" \
  "! printf '%s' \"\$OUT26\" | grep -qi 'actually listening' \
   && ! grep -q '\"urlNote\"' \"$LJ26\""
( cd "$R26" && LCARS_WORKER_BIN="$W26" bash "$LAUNCH_SH" m26 --stop >/dev/null 2>&1 )

# =====================================================================
# 27. THE BUG: the prediction is wrong and the app bound somewhere else.
#     (5173 predicted, 5174 actually bound — the exact demo failure, one repo.)
# =====================================================================
P27PRED="$(free_port)"
P27REAL="$(free_port_not "$P27PRED")"
R27="$(make_repo m27)"
APP27="$TMPROOT/app27.sh"; make_binding_app "$APP27" "$P27REAL"
W27="$(claude_stub_path)"
make_ready_worker "$W27" "$APP27" "m27 dev server" "http://localhost:$P27PRED" "stop"
OUT27="$( cd "$R27" && LCARS_WORKER_BIN="$W27" LCARS_LAUNCH_SETTLE=1.5 bash "$LAUNCH_SH" m27 2>&1 )"
LJ27="$R27/.git/lcars/missions/m27/launch.json"
PID27="$(json_num "$LJ27" pid)"; [ -n "$PID27" ] && LAUNCHED_PIDS+=("$PID27")
check "27a. the record's url names the port the app ACTUALLY bound" \
  "[ \"\$(json_field \"$LJ27\" url)\" = \"http://localhost:$P27REAL\" ]"
check "27b. the wrong guess is demoted to predictedUrl, not silently lost" \
  "[ \"\$(json_field \"$LJ27\" predictedUrl)\" = \"http://localhost:$P27PRED\" ]"
check "27c. the readout names the mismatch, and names both urls" \
  "printf '%s' \"\$OUT27\" | grep -qi 'actually listening' \
   && printf '%s' \"\$OUT27\" | grep -qF 'http://localhost:$P27PRED' \
   && printf '%s' \"\$OUT27\" | grep -qF 'http://localhost:$P27REAL'"
check "27d. a wrong guess is NOT a failure — the app is still running" \
  "[ \"\$(json_field \"$LJ27\" status)\" = running ]"
check "27e. the On screen line offers the VERIFIED url, never the guess" \
  "printf '%s\n' \"\$OUT27\" | grep -qx '  On screen:  http://localhost:$P27REAL'"
( cd "$R27" && LCARS_WORKER_BIN="$W27" bash "$LAUNCH_SH" m27 --stop >/dev/null 2>&1 )

# =====================================================================
# 28. THE MEASURED TWO-REPO FAILURE — the regression test.
#     Repo A's app holds port P. Repo B's discovery ALSO predicts P, but B's app
#     really binds Q. Before S187 B's record said P, and B's best-effort probe
#     hit A's server and "confirmed" it. B's record must say Q, and the probe
#     must land on B's app and never touch A's.
# =====================================================================
P28A="$(free_port)"
P28B="$(free_port_not "$P28A")"
HITS28A="$TMPROOT/hits28a"; HITS28B="$TMPROOT/hits28b"
R28A="$(make_repo m28a)"; R28B="$(make_repo m28b)"
APP28A="$TMPROOT/app28a.sh"; make_binding_app "$APP28A" "$P28A" 0 "$HITS28A"
APP28B="$TMPROOT/app28b.sh"; make_binding_app "$APP28B" "$P28B" 0 "$HITS28B"
W28A="$(claude_stub_path)"
make_ready_worker "$W28A" "$APP28A" "repo A app" "http://localhost:$P28A" "stop"
# repo B's inspector predicts repo A's port — the collision, scripted.
W28B="$(claude_stub_path)"
make_ready_worker "$W28B" "$APP28B" "repo B app" "http://localhost:$P28A" "stop"
( cd "$R28A" && LCARS_WORKER_BIN="$W28A" LCARS_LAUNCH_SETTLE=1.5 bash "$LAUNCH_SH" m28a >/dev/null 2>&1 )
LJ28A="$R28A/.git/lcars/missions/m28a/launch.json"
PID28A="$(json_num "$LJ28A" pid)"; [ -n "$PID28A" ] && LAUNCHED_PIDS+=("$PID28A")
A_HITS_BEFORE="$(hit_count "$HITS28A")"
OUT28B="$( cd "$R28B" && LCARS_WORKER_BIN="$W28B" LCARS_LAUNCH_SETTLE=1.5 bash "$LAUNCH_SH" m28b 2>&1 )"
LJ28B="$R28B/.git/lcars/missions/m28b/launch.json"
PID28B="$(json_num "$LJ28B" pid)"; [ -n "$PID28B" ] && LAUNCHED_PIDS+=("$PID28B")
nap 0.5
check "28a. repo A's own launch is unaffected (its url is its real port)" \
  "[ \"\$(json_field \"$LJ28A\" url)\" = \"http://localhost:$P28A\" ]"
check "28b. repo B's record names B's OWN port, not the colliding prediction" \
  "[ \"\$(json_field \"$LJ28B\" url)\" = \"http://localhost:$P28B\" ]"
check "28c. and B's predictedUrl preserves the colliding guess" \
  "[ \"\$(json_field \"$LJ28B\" predictedUrl)\" = \"http://localhost:$P28A\" ]"
check "28d. B's readiness probe reached B's OWN app" \
  "[ \"\$(hit_count \"$HITS28B\")\" -ge 1 ]"
check "28e. and B's launch never touched repo A's app" \
  "[ \"\$(hit_count \"$HITS28A\")\" = \"$A_HITS_BEFORE\" ]"
( cd "$R28A" && LCARS_WORKER_BIN="$W28A" bash "$LAUNCH_SH" m28a --stop >/dev/null 2>&1 )
( cd "$R28B" && LCARS_WORKER_BIN="$W28B" bash "$LAUNCH_SH" m28b --stop >/dev/null 2>&1 )

# =====================================================================
# 29. AN APP THAT BINDS NOTHING (the legacy sleep-loop fixture — a CLI tool, a
#     worker, an app that died before listen()). A url we cannot verify must not
#     be published as if it were checked: it is emptied, and the record says so
#     in plain English. Everything else — status, pid/pgid, stop, re-launch —
#     stays exactly as it was before S187.
# =====================================================================
P29="$(free_port)"
R29="$(make_repo m29)"
APP29="$TMPROOT/app29.sh"; make_app "$APP29"
W29="$(claude_stub_path)"
make_ready_worker "$W29" "$APP29" "m29 batch worker" "http://localhost:$P29" "lcars launch m29 --stop"
OUT29="$( cd "$R29" && LCARS_WORKER_BIN="$W29" LCARS_LAUNCH_SETTLE=1.5 bash "$LAUNCH_SH" m29 2>&1 )"
LJ29="$R29/.git/lcars/missions/m29/launch.json"
PID29="$(json_num "$LJ29" pid)"; PGID29="$(json_num "$LJ29" pgid)"
[ -n "$PID29" ] && LAUNCHED_PIDS+=("$PID29")
WT29="$(wt_path "$R29" m29)"
check "29a. nothing listening in the group → the url is emptied, not guessed" \
  "[ -z \"\$(json_field \"$LJ29\" url)\" ]"
check "29b. and the record carries an honest note naming the unverified guess" \
  "printf '%s' \"\$(json_field \"$LJ29\" urlNote)\" | grep -q 'nothing in its process group is listening' \
   && printf '%s' \"\$(json_field \"$LJ29\" urlNote)\" | grep -qF 'http://localhost:$P29'"
check "29c. the captain is told the same thing in the readout" \
  "printf '%s' \"\$OUT29\" | grep -q 'nothing in its process group is listening'"
check "29d. status is still running and pid == pgid (unchanged semantics)" \
  "[ \"\$(json_field \"$LJ29\" status)\" = running ] && [ -n \"$PID29\" ] \
   && [ \"$PID29\" = \"$PGID29\" ] && kill -0 \"$PID29\" 2>/dev/null"
( cd "$R29" && LCARS_WORKER_BIN="$W29" bash "$LAUNCH_SH" m29 --stop >/dev/null 2>&1 )
nap 0.4
check "29e. --stop still group-kills it and prunes the worktree" \
  "! kill -0 \"$PID29\" 2>/dev/null && [ ! -d \"$WT29\" ]"
( cd "$R29" && LCARS_WORKER_BIN="$W29" LCARS_LAUNCH_SETTLE=1.5 bash "$LAUNCH_SH" m29 >/dev/null 2>&1 )
PID29b="$(json_num "$LJ29" pid)"; [ -n "$PID29b" ] && LAUNCHED_PIDS+=("$PID29b")
check "29f. and a re-launch still works (idempotent, as before)" \
  "[ \"\$(json_field \"$LJ29\" status)\" = running ] && kill -0 \"$PID29b\" 2>/dev/null"
( cd "$R29" && LCARS_WORKER_BIN="$W29" bash "$LAUNCH_SH" m29 --stop >/dev/null 2>&1 )

# =====================================================================
# 30. THE LATE BINDER. Real dev servers reach listen() a second or two after the
#     spawn. Sampling the socket ONCE right after the spawn would call every one
#     of them "nothing listening"; the verification must keep looking across the
#     same window the liveness poll already spans.
# =====================================================================
P30="$(free_port)"
R30="$(make_repo m30)"
APP30="$TMPROOT/app30.sh"; make_binding_app "$APP30" "$P30" 2
W30="$(claude_stub_path)"
make_ready_worker "$W30" "$APP30" "m30 slow dev server" "" "stop"
OUT30="$( cd "$R30" && LCARS_WORKER_BIN="$W30" LCARS_LAUNCH_SETTLE=3.5 bash "$LAUNCH_SH" m30 2>&1 )"
LJ30="$R30/.git/lcars/missions/m30/launch.json"
PID30="$(json_num "$LJ30" pid)"; [ -n "$PID30" ] && LAUNCHED_PIDS+=("$PID30")
check "30a. a server that binds ~2s in is still caught inside the window" \
  "[ \"\$(json_field \"$LJ30\" url)\" = \"http://localhost:$P30\" ]"
check "30b. with no prediction at all, the verified url is synthesized" \
  "[ -z \"\$(json_field \"$LJ30\" predictedUrl)\" ] \
   && printf '%s\n' \"\$OUT30\" | grep -qx '  On screen:  http://localhost:$P30'"
( cd "$R30" && LCARS_WORKER_BIN="$W30" bash "$LAUNCH_SH" m30 --stop >/dev/null 2>&1 )

# =====================================================================
# 31. THE WRITE-TOOL FLOOR REACHES THE INSPECTOR (S194 follow-through).
#     S168 took the inspector's shell and left copilot's `create` as its ONLY way
#     to author launch-discovery.json. S194 measured that `create` exists only on
#     a model that offers it — copilot's DEFAULT model does not — and cured every
#     run.sh spawn, but launch spawns through its own path and was never given a
#     model. Measured live 2026-09-11 (copilot 1.0.84): the inspector ran on the
#     default gpt-5.6-sol, was offered view/glob only, reasoned that `create` was
#     "unavailable right now", wrote nothing, and EVERY copilot launch failed with
#     "the inspector reported nothing back". Same precedence as
#     resolve_stage_model's (a)/(d)/(e): env pin > config workerModel > the
#     write-capable alias. Empty for claude => its argv is byte-identical.
# =====================================================================
unset LCARS_WORKER_MODEL
argv_model() { awk 'p == "--model" { print; exit } { p = $0 }' "$1"; }
rec_stub() { # engine → a recording stub path whose basename is the cli id
  local d; d="$(mktemp -d "$TMPROOT/wk31.XXXX")"; printf '%s/%s\n' "$d" "$1"
}

R31="$(make_repo m31 copilot)"
S31="$(rec_stub copilot)"; A31="$TMPROOT/argv31"; make_rec_worker "$S31" "$A31"
( cd "$R31" && LCARS_WORKER_BIN="$S31" bash "$LAUNCH_SH" m31 >/dev/null 2>&1 )
check "31a. copilot launch argv CARRIES --model claude-opus-4.8 (write floor)" \
  "[ \"\$(argv_model \"$A31\")\" = 'claude-opus-4.8' ]"

R31b="$(make_repo m31b claude)"
S31b="$(rec_stub claude)"; A31b="$TMPROOT/argv31b"; make_rec_worker "$S31b" "$A31b"
( cd "$R31b" && LCARS_WORKER_BIN="$S31b" bash "$LAUNCH_SH" m31b >/dev/null 2>&1 )
check "31b. claude launch argv still carries NO --model (floor is empty there)" \
  "[ -s \"$A31b\" ] && ! grep -qxF -- '--model' \"$A31b\""

# The floor is the SAME alias map S78 owns, so it stays config-overridable.
R31c="$(make_repo m31c copilot)"
printf '{"modelAliases":{"copilot":{"opus":"claude-opus-4.9"}}}\n' > "$R31c/.git/lcars/config.json"
S31c="$(rec_stub copilot)"; A31c="$TMPROOT/argv31c"; make_rec_worker "$S31c" "$A31c"
( cd "$R31c" && LCARS_WORKER_BIN="$S31c" bash "$LAUNCH_SH" m31c >/dev/null 2>&1 )
check "31c. modelAliases.copilot.opus overrides the write floor" \
  "[ \"\$(argv_model \"$A31c\")\" = 'claude-opus-4.9' ]"

# Precedence: the floor is the LAST resort — config workerModel and the env pin
# both still win, verbatim, exactly as they do for run.sh's stages.
R31d="$(make_repo m31d copilot)"
printf '{"workerModel":"claude-sonnet-4.6"}\n' > "$R31d/.git/lcars/config.json"
S31d="$(rec_stub copilot)"; A31d="$TMPROOT/argv31d"; make_rec_worker "$S31d" "$A31d"
( cd "$R31d" && LCARS_WORKER_BIN="$S31d" bash "$LAUNCH_SH" m31d >/dev/null 2>&1 )
check "31d. config workerModel still beats the write floor" \
  "[ \"\$(argv_model \"$A31d\")\" = 'claude-sonnet-4.6' ]"
( cd "$R31d" && LCARS_WORKER_MODEL=zzz LCARS_WORKER_BIN="$S31d" bash "$LAUNCH_SH" m31d >/dev/null 2>&1 )
check "31e. env LCARS_WORKER_MODEL pin still beats config and the floor" \
  "[ \"\$(argv_model \"$A31d\")\" = 'zzz' ]"

# The --main deploy has no state.json but spawns the same inspector.
R31f="$(make_repo m31f)"
printf '{"mainBranch":"trunk"}\n' > "$R31f/.git/lcars/config.json"
S31f="$(rec_stub copilot)"; A31f="$TMPROOT/argv31f"; make_rec_worker "$S31f" "$A31f"
( cd "$R31f" && LCARS_WORKER_BIN="$S31f" bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
check "31f. the --main deploy's copilot inspector gets the write floor too" \
  "[ \"\$(argv_model \"$A31f\")\" = 'claude-opus-4.8' ]"

# --- 32. A HINT IS PROSE, NOT ARGV (S215) ---------------------------------
# THE DEFECT. The board's ▸ Deploy Main sent the captain's sentence through
# `h.split()`, so every word became an argv element and the parser below read
# `--config` — a word INSIDE his sentence, in the parentheses of "(npx vite
# --config vite.config.ts)" — as an option it did not know. It died at exit 1
# having launched nothing. The overlay's own placeholder invites prose, so the
# sentence that broke it is the sentence it asked for.
#
# THE CURE HERE. `--` is now a real end-of-options marker: everything after it
# is a positional, whatever it starts with. The daemon passes the hint as ONE
# opaque value after it. Real options BEFORE `--` are unchanged.
CAPTAIN_HINT='run the plain BROWSER dev server for packages/editor using its vite.config.ts (npx vite --config vite.config.ts) — not electron-vite, no Electron'

R32="$(make_repo m32)"
printf '{"mainBranch":"trunk"}\n' > "$R32/.git/lcars/config.json"
S32="$(rec_stub copilot)"; A32="$TMPROOT/argv32"; make_rec_worker "$S32" "$A32"
E32="$TMPROOT/err32"
( cd "$R32" && LCARS_WORKER_BIN="$S32" bash "$LAUNCH_SH" --main -- "$CAPTAIN_HINT" \
    >/dev/null 2>"$E32" )
check "32a. a --word inside a hint sentence is NOT read as an option" \
  "! grep -q 'unknown option' \"$E32\""
check "32b. the whole hint sentence reaches the inspector intact" \
  "grep -qF -- '(npx vite --config vite.config.ts)' \"$A32\""

# The same sentence WITHOUT the marker is the pre-cure path — still refused, so
# we can see the marker is what carries it, not a weakened parser.
E32c="$TMPROOT/err32c"
( cd "$R32" && LCARS_WORKER_BIN="$S32" bash "$LAUNCH_SH" --main --config vite.config.ts \
    >/dev/null 2>"$E32c" )
check "32c. a genuinely unknown option is STILL refused (the parser is intact)" \
  "grep -q 'unknown option' \"$E32c\""

# --stop and --main are still options, and a hint after `--` never eats them.
E32d="$TMPROOT/err32d"
( cd "$R32" && LCARS_WORKER_BIN="$S32" bash "$LAUNCH_SH" --main --stop \
    >/dev/null 2>"$E32d" )
check "32d. --main --stop still parses as options, not as a hint" \
  "! grep -q 'unknown option' \"$E32d\""

# …and the same is true when the hint's FIRST word is a --word. `--` means
# "everything after this is his words", so a hint that OPENS with one is prose
# too. Before the cure this still died: `--` only shifted, it set nothing.
E32e="$TMPROOT/err32e"
( cd "$R32" && LCARS_WORKER_BIN="$S32" bash "$LAUNCH_SH" --main -- '--config vite.config.ts, the browser build' \
    >/dev/null 2>"$E32e" )
check "32e. a hint that OPENS with a --word is prose after the marker too" \
  "! grep -q 'unknown option' \"$E32e\""
check "32f. …and that hint reaches the inspector intact" \
  "grep -qF -- '--config vite.config.ts, the browser build' \"$A32\""

echo "lcars launch: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
