#!/usr/bin/env bash
#
# Tests for `lcars launch --main` (skills/lcars-launch/launch.sh) — the deploy-main
# seam (session 138).
#
# `lcars launch --main [hint]` deploys the LOCAL default-branch HEAD (whatever is
# already merged on the machine) through the SAME launch pipeline a mission uses.
# It is a target-resolution SEAM, not new launch machinery: only MDIR (state home),
# WT (disposable worktree), BRANCH and the resolved SHA are set differently — the
# whole downstream (discovery worker, detached spawn, settle poll, stop, prune,
# atomic launch.json) is the unchanged mission code path.
#
# Contract points exercised here:
#   1. arg surface: --main is mutually exclusive with a mission id; @main reserved;
#      hint words pass through exactly as the mission form does.
#   2. target resolution with NO fetch, ever: config mainBranch → local main →
#      local master → legible die. Proven by a git-argv log with no fetch/pull.
#   3. state home ($LCARS_DIR/main) + the reserved @main worktree key — since S167
#      cut OUTSIDE `.git/` at <repo-parent>/.lcars-launch/<repo>/@main — landing
#      DETACHED at the resolved SHA; no missions dir / state.json needed.
#   4. launch.json additive fields (branch, sha) on the main path ONLY.
#   5. hint → discovery worker, no-context (empty TOUCHED) prompt preserved.
#   6. --main --stop: group-kill + prune, idempotent, trek-voice readout.
#   7. engine resolve tolerates the missing state.json.
#   8. re-deploy picks up a NEW commit on main.
#
# Every external is stubbed exactly like tests/lcars-launch.test.sh: the worker
# ($LCARS_WORKER_BIN) is a fake that writes a canned discovery launch.json; git is
# REAL against a temp repo; the "app" is a perl-sleep script named in the canned
# command (a REAL, killable pid). NO model calls, NO network, NO `sleep` binary.
#
# Usage: bash tests/deploy-main.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH_SH="$REPO_ROOT/skills/lcars-launch/launch.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'stop_all; rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

nap() { perl -e 'select(undef,undef,undef,'"${1:-0.3}"')' 2>/dev/null || true; }

LAUNCHED_PIDS=()
stop_all() {
  local p
  for p in ${LAUNCHED_PIDS[@]+"${LAUNCHED_PIDS[@]}"}; do
    kill -KILL -"$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
  done
}

# --- a throwaway repo whose DEFAULT branch is main/master/<name>, with an
#     initialized .git/lcars but NO missions (the main deploy needs none). ------
# Prints the repo root. $1 = branch name (default main). One commit on that branch.
make_main_repo() { # [branch]
  local br="${1:-main}"
  local root; root="$(mktemp -d "$TMPROOT/mainrepo.XXXX")"
  (
    cd "$root"
    git init -q
    git config user.email t@t.com
    git config user.name t
    git symbolic-ref HEAD "refs/heads/$br"
    printf 'root\n' > README.md
    git add . && git commit -qm init
  )
  mkdir -p "$root/.git/lcars"
  printf '%s\n' "$root"
}

# A mission repo (same shape as the lcars-launch suite) — used only to prove the
# per-mission launch.json stays free of the additive main-only fields.
make_mission_repo() { # id
  local id="$1"
  local root; root="$(mktemp -d "$TMPROOT/msnrepo.XXXX")"
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
    printf '  "branch": "lcars/%s",\n' "$id"
    printf '  "base": "trunk"\n'
    printf '}\n'
  } > "$mdir/state.json"
  printf '%s\n' "$root"
}

# Worker stub dir whose basename is a KNOWN adapter cli id (claude).
claude_stub_path() { local d; d="$(mktemp -d "$TMPROOT/wk.XXXX")"; printf '%s/claude\n' "$d"; }

# Worker stub that writes a READY discovery launch.json to $LCARS_LAUNCH_JSON.
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

# Worker stub that records its full argv (one per line) to $2 AND the assembled
# prompt is the last argv element (the adapter passes the prompt positionally), so
# grepping $2 inspects both the toolset fence and the prompt text. Then writes a
# FAILED discovery so the skill stops WITHOUT launching anything.
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

# A long-lived fake "app" (~30s; killed by --stop long before).
make_app() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
perl -e 'select(undef,undef,undef,30)'
EOF
  chmod +x "$1"
}

# A LOGGING pass-through git: append every invocation's argv to $2, then exec the
# REAL git. Used as $LCARS_GIT_BIN to PROVE no `fetch`/`pull` ever runs.
make_git_logger() { # path logfile
  cat >"$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$2"
exec git "\$@"
EOF
  chmod +x "$1"
}

json_field() { sed -En "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\1/p" "$1" | head -1; }
json_num()   { sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([^,}\"[:space:]]*\).*/\1/p" "$1" | head -1; }

# --- S167: the deploy CHECKOUT lives OUTSIDE `.git/` ---------------------------
# The reserved @main key moved from `.git/lcars/launch/@main` to a sibling of the
# repo, because a worktree inside `.git/` matches Vite's default
# `server.watch.ignored` (`**/.git/**`) and every file watcher is therefore off.
# The deploy's STATE (.git/lcars/main/launch.json) did NOT move.
wt_path() { # repo-root key
  local r; r="$(cd "$1" && pwd -P)"
  printf '%s/.lcars-launch/%s/%s\n' "$(dirname "$r")" "$(basename "$r")" "$2"
}
wt_registered() { # repo-root wt-path
  (cd "$1" && git worktree list --porcelain 2>/dev/null | grep -qxF "worktree $2")
}
wt_detached() { # repo-root wt-path
  (cd "$1" && git worktree list --porcelain 2>/dev/null \
    | awk -v p="worktree $2" '$0==p{f=1;next} f&&/^$/{exit} f&&/^detached$/{print "yes";exit}') \
    | grep -q yes
}

echo "lcars launch --main — deploy the local main HEAD (session 138)"

# =====================================================================
# 1. ARG SURFACE: --main mutually exclusive with a mission id; @main reserved;
#    hint words pass through exactly as the mission form does.
# =====================================================================
# 1a. `--main m1` where m1 IS a mission → legible die, non-zero, no launch.
R1="$(make_mission_repo m1)"
W1="$(claude_stub_path)"; make_ready_worker "$W1" "true" "x" "" "n/a"
OUT1a="$( cd "$R1" && LCARS_WORKER_BIN="$W1" bash "$LAUNCH_SH" --main m1 2>&1 )"; RC1a=$?
check "1a. --main + an existing mission id → exit non-zero" "[ \"$RC1a\" != 0 ]"
check "1a2. --main + mission id → legible message (mentions dropping --main)" \
  "printf '%s' \"\$OUT1a\" | grep -qi 'drop'"
check "1a3. --main + mission id → not a raw stack trace (starts 'lcars launch:')" \
  "printf '%s' \"\$OUT1a\" | grep -q '^lcars launch:'"

# 1b. `m1 --main` (mission parsed BEFORE the flag) → die, non-zero.
OUT1b="$( cd "$R1" && LCARS_WORKER_BIN="$W1" bash "$LAUNCH_SH" m1 --main 2>&1 )"; RC1b=$?
check "1b. mission id BEFORE --main → exit non-zero" "[ \"$RC1b\" != 0 ]"
check "1b2. mission-before-main die names the mutual exclusion (no mission id)" \
  "printf '%s' \"\$OUT1b\" | grep -qi 'no mission id'"

# 1c. `--main "the game viewer"` → the multi-word hint reaches the worker prompt
#     verbatim, joined with spaces, EXACTLY as the mission form does.
R1c="$(make_main_repo)"
ARGV1c="$TMPROOT/argv1c"
W1c="$(claude_stub_path)"; make_rec_worker "$W1c" "$ARGV1c"
( cd "$R1c" && LCARS_WORKER_BIN="$W1c" bash "$LAUNCH_SH" --main the game viewer >/dev/null 2>&1 )
check "1c. --main hint words join with spaces + reach the worker prompt" \
  "grep -q 'the game viewer' \"$ARGV1c\""
check "1c2. --main quoted-style multi-word hint appears on the 'wants to run' line" \
  "grep -q 'wants to run: the game viewer' \"$ARGV1c\""
# 1d. no TOUCHED-TARGET section for --main (no base → no-context prompt preserved).
check "1d. --main has NO mission touched-target section (no-context prompt)" \
  "! grep -q \"This Mission's changes are in\" \"$ARGV1c\""
check "1d2. --main still carries today's byte-identical discovery line" \
  "grep -q 'DISCOVER how to start it' \"$ARGV1c\""

# 1e. a plain mission literally named @main is REJECTED (reserved token).
R1e="$(make_mission_repo atmain)"   # repo has a real mission, but we ask for @main
OUT1e="$( cd "$R1e" && LCARS_WORKER_BIN="$W1" bash "$LAUNCH_SH" @main 2>&1 )"; RC1e=$?
check "1e. lcars launch @main (mission form) → exit non-zero" "[ \"$RC1e\" != 0 ]"
check "1e2. @main refusal says it is reserved + points at --main" \
  "printf '%s' \"\$OUT1e\" | grep -qi 'reserved' && printf '%s' \"\$OUT1e\" | grep -q -- '--main'"

# =====================================================================
# 2. TARGET RESOLUTION — NO fetch, EVER. A full --main deploy over a logging git
#    stub must never invoke fetch or pull. mainBranch config wins; then local
#    main; then local master; else a legible die.
# =====================================================================
# 2a. a full --main deploy to running — assert NO fetch/pull in the git argv log.
R2="$(make_main_repo)"
APP2="$TMPROOT/app2.sh"; make_app "$APP2"
GLOG2="$TMPROOT/gitlog2"; : > "$GLOG2"
GIT2="$TMPROOT/git2"; make_git_logger "$GIT2" "$GLOG2"
W2="$(claude_stub_path)"; make_ready_worker "$W2" "$APP2" "main HEAD app" "http://localhost:3000" ""
( cd "$R2" && LCARS_GIT_BIN="$GIT2" LCARS_WORKER_BIN="$W2" LCARS_LAUNCH_SETTLE=0.6 \
    bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ2="$R2/.git/lcars/main/launch.json"
PID2="$(json_num "$LJ2" pid)"
[ -n "$PID2" ] && LAUNCHED_PIDS+=("$PID2")
check "2a. a full --main deploy reaches status=running" \
  "[ \"\$(json_field \"$LJ2\" status)\" = running ]"
check "2a2. the git argv log NEVER contains a fetch" "! grep -qw fetch \"$GLOG2\""
check "2a3. the git argv log NEVER contains a pull"  "! grep -qw pull  \"$GLOG2\""
check "2a4. the deploy DID run git (log is non-empty — the logger was really used)" \
  "[ -s \"$GLOG2\" ]"
( cd "$R2" && LCARS_GIT_BIN="$GIT2" LCARS_WORKER_BIN="$W2" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# 2b. config mainBranch WINS: point it at a `release` branch and deploy that tip.
R2b="$(make_main_repo main)"
( cd "$R2b" && git checkout -qb release && printf 'rel\n' > REL.txt && git add . && git commit -qm rel && git checkout -q main )
printf '{\n  "mainBranch": "release"\n}\n' > "$R2b/.git/lcars/config.json"
APP2b="$TMPROOT/app2b.sh"; make_app "$APP2b"
W2b="$(claude_stub_path)"; make_ready_worker "$W2b" "$APP2b" "release app" "" ""
( cd "$R2b" && LCARS_WORKER_BIN="$W2b" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ2b="$R2b/.git/lcars/main/launch.json"
PID2b="$(json_num "$LJ2b" pid)"
[ -n "$PID2b" ] && LAUNCHED_PIDS+=("$PID2b")
WT2b="$(wt_path "$R2b" @main)"
REL_SHA="$(cd "$R2b" && git rev-parse release)"
WT2b_SHA="$(cd "$R2b" && git -C "$WT2b" rev-parse HEAD 2>/dev/null)"
check "2b. config mainBranch=release → launch.json branch is release" \
  "[ \"\$(json_field \"$LJ2b\" branch)\" = release ]"
check "2b2. config mainBranch=release → the worktree is checked out at release tip" \
  "[ \"$WT2b_SHA\" = \"$REL_SHA\" ]"
check "2b3. config mainBranch=release → the release-only file is in the checkout" \
  "[ -f \"$WT2b/REL.txt\" ]"
( cd "$R2b" && LCARS_WORKER_BIN="$W2b" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# 2c. master fallback: a repo whose only default branch is master.
R2c="$(make_main_repo master)"
APP2c="$TMPROOT/app2c.sh"; make_app "$APP2c"
W2c="$(claude_stub_path)"; make_ready_worker "$W2c" "$APP2c" "master app" "" ""
( cd "$R2c" && LCARS_WORKER_BIN="$W2c" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ2c="$R2c/.git/lcars/main/launch.json"
PID2c="$(json_num "$LJ2c" pid)"
[ -n "$PID2c" ] && LAUNCHED_PIDS+=("$PID2c")
check "2c. no main branch → falls back to local master (launch.json branch=master)" \
  "[ \"\$(json_field \"$LJ2c\" branch)\" = master ]"
( cd "$R2c" && LCARS_WORKER_BIN="$W2c" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# 2d. neither main nor master nor config → legible die naming mainBranch/config.
R2d="$(make_main_repo trunk)"      # default branch is trunk; no main/master, no cfg
OUT2d="$( cd "$R2d" && LCARS_WORKER_BIN="$W2c" bash "$LAUNCH_SH" --main 2>&1 )"; RC2d=$?
check "2d. no main/master/config → exit non-zero" "[ \"$RC2d\" != 0 ]"
check "2d2. the die names mainBranch + config.json" \
  "printf '%s' \"\$OUT2d\" | grep -q 'mainBranch' && printf '%s' \"\$OUT2d\" | grep -q 'config.json'"

# =====================================================================
# 3. STATE HOME + WORKTREE: $LCARS_DIR/main holds the records (no missions dir);
#    the worktree lands DETACHED at the resolved SHA under the reserved @main path.
# =====================================================================
R3="$(make_main_repo)"
APP3="$TMPROOT/app3.sh"; make_app "$APP3"
W3="$(claude_stub_path)"; make_ready_worker "$W3" "$APP3" "main app" "" ""
MAIN_SHA3="$(cd "$R3" && git rev-parse main)"
( cd "$R3" && LCARS_WORKER_BIN="$W3" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ3="$R3/.git/lcars/main/launch.json"
PID3="$(json_num "$LJ3" pid)"
[ -n "$PID3" ] && LAUNCHED_PIDS+=("$PID3")
WT3="$(wt_path "$R3" @main)"
check "3a. the deploy's launch.json lives at .git/lcars/main/launch.json" \
  "[ -f \"$LJ3\" ]"
check "3b. NO missions dir was created for a pure --main deploy" \
  "[ ! -d \"$R3/.git/lcars/missions\" ]"
check "3c. a git worktree was created at the sibling deploy root (outside .git)" \
  "wt_registered \"$R3\" \"$WT3\" && ! printf '%s' \"$WT3\" | grep -q '/\\.git/'"
check "3d. that worktree is DETACHED (holds no branch ref)" \
  "wt_detached \"$R3\" \"$WT3\""
WT3_SHA="$(cd "$R3" && git -C "$WT3" rev-parse HEAD 2>/dev/null)"
check "3e. the worktree is checked out at the local main HEAD sha" \
  "[ \"$WT3_SHA\" = \"$MAIN_SHA3\" ]"
( cd "$R3" && LCARS_WORKER_BIN="$W3" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# =====================================================================
# 4. launch.json ADDITIVE FIELDS on the main path only; the mission path's
#    launch.json stays byte-identical (branch/sha ABSENT).
# =====================================================================
R4="$(make_main_repo)"
APP4="$TMPROOT/app4.sh"; make_app "$APP4"
W4="$(claude_stub_path)"; make_ready_worker "$W4" "$APP4" "main app" "" ""
SHORT4="$(cd "$R4" && git rev-parse --short main)"
OUT4="$( cd "$R4" && LCARS_WORKER_BIN="$W4" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main 2>&1 )"
LJ4="$R4/.git/lcars/main/launch.json"
PID4="$(json_num "$LJ4" pid)"
[ -n "$PID4" ] && LAUNCHED_PIDS+=("$PID4")
check "4a. main running record carries branch=main" \
  "[ \"\$(json_field \"$LJ4\" branch)\" = main ]"
check "4b. main running record carries the short sha" \
  "[ \"\$(json_field \"$LJ4\" sha)\" = \"$SHORT4\" ]"
check "4c. the readout names branch @ sha (trek voice, no mission id)" \
  "printf '%s' \"\$OUT4\" | grep -q \"main @ $SHORT4\""
check "4d. the readout does NOT reference a mission id" \
  "! printf '%s' \"\$OUT4\" | grep -qi 'mission app'"
( cd "$R4" && LCARS_WORKER_BIN="$W4" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# 4e. a MISSION launch's launch.json has NEITHER branch NOR sha (byte-identical).
R4m="$(make_mission_repo m4m)"
APP4m="$TMPROOT/app4m.sh"; make_app "$APP4m"
W4m="$(claude_stub_path)"; make_ready_worker "$W4m" "$APP4m" "m4m app" "" ""
( cd "$R4m" && LCARS_WORKER_BIN="$W4m" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" m4m >/dev/null 2>&1 )
LJ4m="$R4m/.git/lcars/missions/m4m/launch.json"
PID4m="$(json_num "$LJ4m" pid)"
[ -n "$PID4m" ] && LAUNCHED_PIDS+=("$PID4m")
check "4e. mission launch.json has NO branch field (main-only additive)" \
  "[ -z \"\$(json_field \"$LJ4m\" branch)\" ]"
check "4f. mission launch.json has NO sha field (main-only additive)" \
  "[ -z \"\$(json_field \"$LJ4m\" sha)\" ]"
( cd "$R4m" && LCARS_WORKER_BIN="$W4m" bash "$LAUNCH_SH" m4m --stop >/dev/null 2>&1 )

# =====================================================================
# 5. RE-DEPLOY WHILE RUNNING: a second `--main` deploy while the first is STILL
#    up must GROUP-KILL the first pid before re-spawning into the reused @main
#    worktree — otherwise the early `launching` write overwrites launch.json's
#    pid and the first process is ORPHANED (a later --stop kills only the new
#    one). Shared-machinery fix; this locks it on the --main path.
# =====================================================================
R5="$(make_main_repo)"
APP5="$TMPROOT/app5.sh"; make_app "$APP5"
W5="$(claude_stub_path)"; make_ready_worker "$W5" "$APP5" "main app" "" ""
LJ5="$R5/.git/lcars/main/launch.json"
( cd "$R5" && LCARS_WORKER_BIN="$W5" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
PID5a="$(json_num "$LJ5" pid)"
[ -n "$PID5a" ] && LAUNCHED_PIDS+=("$PID5a")
check "5a. first --main deploy records a live pid" \
  "[ -n \"$PID5a\" ] && kill -0 \"$PID5a\" 2>/dev/null"
# re-deploy while the first is STILL running
( cd "$R5" && LCARS_WORKER_BIN="$W5" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
PID5b="$(json_num "$LJ5" pid)"
[ -n "$PID5b" ] && LAUNCHED_PIDS+=("$PID5b")
nap 0.5
check "5b. the re-deploy recorded a NEW pid (distinct from the first)" \
  "[ -n \"$PID5b\" ] && [ \"$PID5b\" != \"$PID5a\" ]"
check "5c. the first pid was KILLED by the re-deploy (no orphan)" \
  "! kill -0 \"$PID5a\" 2>/dev/null"
check "5d. the second pid is alive + launch.json status=running" \
  "kill -0 \"$PID5b\" 2>/dev/null && [ \"\$(json_field \"$LJ5\" status)\" = running ]"
( cd "$R5" && LCARS_WORKER_BIN="$W5" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )
nap 0.4
check "5e. after --stop the second pid is dead too" "! kill -0 \"$PID5b\" 2>/dev/null"

# =====================================================================
# 6. --main --stop: group-kill + prune, idempotent, trek-voice readout with the
#    correct `lcars launch --main --stop` stand-down hint.
# =====================================================================
R6="$(make_main_repo)"
APP6="$TMPROOT/app6.sh"; make_app "$APP6"
W6="$(claude_stub_path)"; make_ready_worker "$W6" "$APP6" "main app" "" ""
OUT6run="$( cd "$R6" && LCARS_WORKER_BIN="$W6" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main 2>&1 )"
LJ6="$R6/.git/lcars/main/launch.json"
PID6="$(json_num "$LJ6" pid)"
[ -n "$PID6" ] && LAUNCHED_PIDS+=("$PID6")
check "6a. the running deploy's stand-down hint is 'lcars launch --main --stop'" \
  "printf '%s' \"\$OUT6run\" | grep -q -- 'lcars launch --main --stop'"
check "6b. before stop the app pid is alive" "kill -0 \"$PID6\" 2>/dev/null"
OUT6stop="$( cd "$R6" && LCARS_WORKER_BIN="$W6" bash "$LAUNCH_SH" --main --stop 2>&1 )"; RC6stop=$?
nap 0.4
check "6c. --main --stop killed the app pid" "! kill -0 \"$PID6\" 2>/dev/null"
check "6d. --main --stop set status=stopped" "[ \"\$(json_field \"$LJ6\" status)\" = stopped ]"
check "6e. --main --stop pruned the @main worktree (no dir, no stale row)" \
  "! wt_registered \"$R6\" \"\$(wt_path \"$R6\" @main)\" && [ ! -d \"\$(wt_path \"$R6\" @main)\" ]"
check "6f. --main --stop readout is trek-voice, references no mission id" \
  "printf '%s' \"\$OUT6stop\" | grep -qi 'main deploy offline'"
# 6g. idempotent: stopping again when nothing runs is a clean no-op (exit 0).
OUT6b="$( cd "$R6" && LCARS_WORKER_BIN="$W6" bash "$LAUNCH_SH" --main --stop 2>&1 )"; RC6b=$?
check "6g. a second --main --stop (nothing running) is a clean no-op (exit 0)" \
  "[ \"$RC6b\" = 0 ]"

# 6h. a FAILED main launch prunes the @main worktree + reports plain English.
R6h="$(make_main_repo)"
W6h="$(claude_stub_path)"; make_ready_worker "$W6h" "false" "doomed" "" "n/a"   # dies instantly
OUT6h="$( cd "$R6h" && LCARS_WORKER_BIN="$W6h" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main 2>&1 )"; RC6h=$?
LJ6h="$R6h/.git/lcars/main/launch.json"
check "6h. a failed main launch → exit non-zero" "[ \"$RC6h\" != 0 ]"
check "6h2. a failed main launch → status=failed (not a stale running)" \
  "[ \"\$(json_field \"$LJ6h\" status)\" = failed ]"
check "6h3. a failed main launch pruned its @main worktree" \
  "! wt_registered \"$R6h\" \"\$(wt_path \"$R6h\" @main)\" && [ ! -d \"\$(wt_path \"$R6h\" @main)\" ]"
check "6h4. a failed main launch → plain-English message (not a stack trace)" \
  "printf '%s' \"\$OUT6h\" | grep -qi 'exited immediately'"

# =====================================================================
# 7. ENGINE RESOLVE tolerates the missing state.json: a --main deploy with NO
#    state.json anywhere still resolves a worker and reaches running (proving the
#    missing-state.json branch of the WORKER_BIN chain doesn't error/stall).
# =====================================================================
R7="$(make_main_repo)"
APP7="$TMPROOT/app7.sh"; make_app "$APP7"
W7="$(claude_stub_path)"; make_ready_worker "$W7" "$APP7" "main app" "" ""
RC7=0
( cd "$R7" && LCARS_WORKER_BIN="$W7" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 ) || RC7=$?
LJ7="$R7/.git/lcars/main/launch.json"
PID7="$(json_num "$LJ7" pid)"
[ -n "$PID7" ] && LAUNCHED_PIDS+=("$PID7")
check "7a. --main with NO state.json still resolves a worker + reaches running" \
  "[ \"$RC7\" = 0 ] && [ \"\$(json_field \"$LJ7\" status)\" = running ]"
( cd "$R7" && LCARS_WORKER_BIN="$W7" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# =====================================================================
# 8. RE-DEPLOY picks up a NEW commit on main. Deploy, stop (prunes the worktree),
#    add a new commit, re-deploy → the @main worktree is at the NEW sha.
# =====================================================================
R8="$(make_main_repo)"
APP8="$TMPROOT/app8.sh"; make_app "$APP8"
W8="$(claude_stub_path)"; make_ready_worker "$W8" "$APP8" "main app" "" ""
OLD_SHA8="$(cd "$R8" && git rev-parse main)"
( cd "$R8" && LCARS_WORKER_BIN="$W8" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
PID8a="$(json_num "$R8/.git/lcars/main/launch.json" pid)"; [ -n "$PID8a" ] && LAUNCHED_PIDS+=("$PID8a")
( cd "$R8" && LCARS_WORKER_BIN="$W8" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )
# a NEW commit lands on main
( cd "$R8" && printf 'v2\n' > NEW.txt && git add . && git commit -qm v2 )
NEW_SHA8="$(cd "$R8" && git rev-parse main)"
( cd "$R8" && LCARS_WORKER_BIN="$W8" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ8="$R8/.git/lcars/main/launch.json"
PID8b="$(json_num "$LJ8" pid)"; [ -n "$PID8b" ] && LAUNCHED_PIDS+=("$PID8b")
WT8="$(wt_path "$R8" @main)"
WT8_SHA="$(cd "$R8" && git -C "$WT8" rev-parse HEAD 2>/dev/null)"
NEW_SHORT8="$(cd "$R8" && git rev-parse --short main)"
LJ8_SHA="$(json_field "$LJ8" sha)"
check "8a. the two shas actually differ (sanity: a new commit landed)" \
  "[ \"$OLD_SHA8\" != \"$NEW_SHA8\" ]"
check "8b. a re-deploy after a new main commit checks out the NEW sha" \
  "[ \"$WT8_SHA\" = \"$NEW_SHA8\" ]"
check "8c. the re-deployed launch.json records the NEW short sha" \
  "[ \"$LJ8_SHA\" = \"$NEW_SHORT8\" ]"
( cd "$R8" && LCARS_WORKER_BIN="$W8" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

# =====================================================================
# 9. S167 — the @main deploy moved OUT of `.git/`, and a captain who already had
#    one at the legacy in-`.git/` path is MIGRATED, not stranded: the old checkout
#    is removed + pruned before the new one is cut, so he never ends up with two
#    @main checkouts or a stale `git worktree list` row.
# =====================================================================
R9="$(make_main_repo)"
APP9="$TMPROOT/app9.sh"; make_app "$APP9"
W9="$(claude_stub_path)"; make_ready_worker "$W9" "$APP9" "main app" "" ""
OLD9="$(cd "$R9" && pwd -P)/.git/lcars/launch/@main"
SHA9="$(cd "$R9" && git rev-parse main)"
mkdir -p "$(dirname "$OLD9")"
( cd "$R9" && git worktree add --detach "$OLD9" "$SHA9" >/dev/null 2>&1 )
check "9a. (setup) a legacy in-.git @main worktree really is registered" \
  "(cd \"$R9\" && git worktree list --porcelain | grep -qxF \"worktree $OLD9\")"
( cd "$R9" && LCARS_WORKER_BIN="$W9" LCARS_LAUNCH_SETTLE=0.6 bash "$LAUNCH_SH" --main >/dev/null 2>&1 )
LJ9="$R9/.git/lcars/main/launch.json"
PID9="$(json_num "$LJ9" pid)"; [ -n "$PID9" ] && LAUNCHED_PIDS+=("$PID9")
WT9="$(wt_path "$R9" @main)"
check "9b. the legacy in-.git @main worktree was pruned and removed" \
  "! (cd \"$R9\" && git worktree list --porcelain | grep -qxF \"worktree $OLD9\") && [ ! -d \"$OLD9\" ]"
check "9c. the new @main deploy is registered outside .git and really checked out" \
  "wt_registered \"$R9\" \"$WT9\" && [ -f \"$WT9/README.md\" ]"
check "9d. the deploy's STATE stayed under .git/lcars/main" \
  "[ -f \"$LJ9\" ] && [ \"\$(json_field \"$LJ9\" status)\" = running ]"
check "9e. the recorded worktree path carries no .git component" \
  "! printf '%s' \"\$(json_field \"$LJ9\" worktree)\" | grep -q '/\\.git/'"
( cd "$R9" && LCARS_WORKER_BIN="$W9" bash "$LAUNCH_SH" --main --stop >/dev/null 2>&1 )

echo "lcars launch --main: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
