#!/usr/bin/env bash
#
# S232 — approve's three side effects, each of which cost the captain real
# attention over the Canvas weekend (26–29 Sep 2026):
#
#   A. OPEN CHILDREN. `lcars approve` merged a parent Mission while its logged
#      bugs were still in flight. `fold_logged_children` runs AFTER `gh pr merge`
#      has already landed and merely WARNS ("their fixes are NOT in this PR"), so
#      by the time the captain read the warning the parent was shipped and the
#      children were stranded outside resolve-logs' reach. There is now a
#      PRE-MERGE gate: a parent with an OPEN (unfolded, not-done) logged bug is
#      REFUSED, nothing is merged, and the refusal names each child and the one
#      command that clears it. No --force — the captain's rule is refuse.
#
#   B. TESTCOMMAND. `promote_test_command` UNCONDITIONALLY overwrote
#      .git/lcars/config.json's testCommand with the worker-declared one, and
#      replaced the captain's hand-recorded `python3 -m unittest discover …` with
#      an UNINSTALLED `pytest`. Only an ABSENT testCommand is filled now; a
#      value already there WINS, the declaration is recorded on the mission as
#      `declaredTestCommand`, and approve says which it kept. Compared EXACTLY:
#      any difference keeps the captain's (a whitespace-normalising compare is
#      the wrong answer — it licenses an overwrite).
#
#   C. SECOND DRIVE. `lcars answer respond` → respond.sh hands back to the
#      driver, and NOTHING recorded that a drive was already running, so a second
#      driver could start on top of a live one. `run.sh drive` now RECORDS itself
#      at $MISSION_DIR/drive.pid (pid + started-at) and removes it on exit via
#      the driver-lock trap; respond and `lcars` read that ONE record through
#      lcars-common.sh. Record, never infer — `pgrep run.sh` is the wrong answer
#      (ORCHESTRATION.md § infer-vs-record).
#
# PROOF SURFACE: real git, the real verbs (approve / resolve-logs / respond /
# run.sh drive) and a REAL background driver process. Only the forge (gh) and
# the AI workers are stubbed — no network, no worker, no tokens.
#
# Run it CAGED and read the cage's own verdict line, never $?:
#   python3 tests/lib/cage.py 300 bash tests/approve-side-effects.test.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPROVE="${LCARS_APPROVE_SCRIPT:-$REPO_ROOT/skills/lcars-approve/approve.sh}"
RESOLVE_LOGS="$REPO_ROOT/skills/lcars-resolve-logs/resolve-logs.sh"
RESPOND="$REPO_ROOT/skills/lcars-respond/respond.sh"
RUN_SH="$REPO_ROOT/skills/lcars-run/run.sh"
LCARS_SH="$REPO_ROOT/skills/lcars/lcars.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"
COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

PID="lcars-20260930-101"        # the parent Mission
CID="lcars-20260930-102"        # its logged bug
PBRANCH="lcars/$PID"

pdir_of() { echo "$1/.git/lcars/missions/$PID"; }
cdir_of() { echo "$1/.git/lcars/missions/$CID"; }

# --- stubs: the forge, the host adapter's forge, a worker, a driver ----------
make_gh_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" | tr '\n' ' ' >>"$GH_LOG"; echo >>"$GH_LOG"
exit 0
EOF
  chmod +x "$1"
}

make_host_stub() { # path — pr-view OPEN, pr-merge succeeds, everything else 0
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "host $*" >>"$GH_LOG"
case "${1:-}" in
  pr-view)  printf 'state\tOPEN\nbaseRefName\tmain\nheadRefName\tb\ntitle\tt\nnumber\t1\n'; exit 0 ;;
  pr-merge) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$1"
}

make_worker_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "WORKER $*" >>"$WORKER_LOG"
exit 0
EOF
  chmod +x "$1"
}

# A stand-in for the sibling run.sh. Records every invocation to $RUN_LOG, so a
# SECOND driver is directly observable as a line in that file.
make_run_stub() { # path [exit-code]
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo "run \$*" >>"\$RUN_LOG"
exit ${2:-0}
EOF
  chmod +x "$1"
}

# ===========================================================================
# FIXTURE A — a parent Mission at verify with an open PR and ONE logged bug
# child whose fix is a REAL commit on the parent branch (so the REAL
# resolve-logs fold can accept it).
#   $1 repo   $2 the child's stage (verify | plan | done)
# ===========================================================================
new_parent_child_repo() { # child-stage -> repo path
  local cstage="${1:-verify}" repo
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'orig\n' >README.md && git add -A && git commit -q -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  # The parent's ticket, then the CHILD's fix — both real commits on the branch.
  ( cd "$repo" && git checkout -q -b "$PBRANCH" \
      && printf 'feature\n' >feature.txt && git add -A \
      && git commit -q -m "lcars($PID) t-001: the feature" \
      && printf 'fixed\n' >>feature.txt && git add -A \
      && git commit -q -m "lcars($CID) t-001: the logged bug's fix" \
      && git checkout -q "$base" )

  local p; p="$(pdir_of "$repo")"; mkdir -p "$p/tickets/t-001"
  cat >"$p/prd.md" <<'EOF'
# Mission: Publish discussions
**Goal:** Publish a discussion thread per page.
**Acceptance Criteria:**
- A thread appears per page
EOF
  cat >"$p/state.json" <<EOF
{
  "id": "$PID",
  "type": "feature",
  "title": "Publish discussions",
  "stage": "verify",
  "review": "open",
  "prUrl": "https://github.com/acme/repo/pull/77",
  "prNumber": 77,
  "created": "2026-09-30T10:00:00Z",
  "githubIssue": 42,
  "branch": "$PBRANCH",
  "base": "$base"
}
EOF
  echo '[ { "id": "t-001", "title": "The feature" } ]' >"$p/approved-plan.json"

  local c; c="$(cdir_of "$repo")"; mkdir -p "$c/tickets/t-001"
  cat >"$c/prd.md" <<'EOF'
# Mission: publish stops when the Artifacts category is missing
**Goal:** Fall back to the default category.
EOF
  cat >"$c/state.json" <<EOF
{
  "id": "$CID",
  "type": "bug",
  "title": "publish stops when the Artifacts category is missing",
  "stage": "$cstage",
  "created": "2026-09-30T11:00:00Z",
  "githubIssue": 51,
  "parentMission": "$PID",
  "parentIssue": 42,
  "branch": "$PBRANCH",
  "base": "$PBRANCH"
}
EOF
  echo '{ "passed": true, "attempts": 1 }' >"$c/tickets/t-001/result.json"
  ( cd "$repo" && git rev-parse "$PBRANCH" ) >"$c/tickets/t-001/.commit-sha"
  echo '{ "testCommand": "true" }' >"$repo/.git/lcars/config.json"
  echo "$repo"
}

# Run the REAL approve on a repo, with the forge and the reconcile engine stubbed.
approve_in() { # repo  extra-args…
  local repo="$1"; shift
  ( cd "$repo" \
      && GH_LOG="$repo/gh.log" \
         LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
         LCARS_HOST_ADAPTER="$repo/host" \
         LCARS_RUN_SCRIPT="$repo/recon" RUN_LOG="$repo/run.log" \
         LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_LOGS" \
         LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
         bash "$APPROVE" --mission "$PID" "$@" )
}

# Run the REAL resolve-logs fold of the parent's verified children.
fold_in() { # repo
  local repo="$1"
  ( cd "$repo" \
      && GH_LOG="$repo/gh.log" RUN_LOG="$repo/run.log" \
         LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
         LCARS_HOST_ADAPTER="$repo/host" \
         LCARS_RUN_SCRIPT="$repo/recon" \
         LCARS_NOTIFY="$repo/notify" LCARS_NOTIFY_NO_DESKTOP=1 \
         bash "$RESOLVE_LOGS" complete --parent "$PID" )
}

stub_repo() { # repo — drop every stub the helpers above expect into it
  local repo="$1"
  make_gh_stub  "$repo/gh"
  make_host_stub "$repo/host"
  make_run_stub "$repo/recon" 0
  make_worker_stub "$repo/worker"
  cat >"$repo/notify" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$repo/notify"
  : >"$repo/gh.log"; : >"$repo/run.log"; : >"$repo/worker.log"
}

echo "S232 approve's three side effects — open children, testCommand, one driver"
echo

# ===========================================================================
# BEHAVIOUR 1 — a parent with ONE OPEN (unfolded) logged bug is REFUSED
# PRE-MERGE. Nothing merges. The refusal names the child (id, title, stage) and
# the exact next command.
# ===========================================================================
r1="$(new_parent_child_repo verify)"; stub_repo "$r1"
rc1=0; approve_in "$r1" >"$r1/out.txt" 2>&1 || rc1=$?
s1="$(pdir_of "$r1")/state.json"
check "1a. approve exits NON-ZERO with an open logged bug" "[ '$rc1' -ne 0 ]"
check "1b. it merged NOTHING (no pr-merge on the forge seam)" \
  "! grep -q 'pr-merge' '$r1/gh.log'"
check "1c. it never even ran the reconcile pre-step" \
  "! grep -q 'reconcile' '$r1/run.log'"
check "1d. the parent stays at verify (no false Done)" \
  "grep -q '\"stage\": *\"verify\"' '$s1'"
check "1e. no lcars:done label was applied" \
  "! grep -q 'lcars:done' '$r1/gh.log'"
check "1f. the refusal names the child's mission id" "grep -q '$CID' '$r1/out.txt'"
check "1g. the refusal names the child's title" \
  "grep -q 'Artifacts category is missing' '$r1/out.txt'"
check "1h. the refusal names the child's stage" \
  "grep -q 'stage verify' '$r1/out.txt'"
check "1i. the refusal names the exact next command" \
  "grep -q 'lcars resolve-logs $PID' '$r1/out.txt'"
check "1j. there is NO --force escape hatch in approve's arg parser" \
  "! grep -qE -- '[-][-]force[)=]' '$APPROVE'"

# A child mid-flight at an EARLIER stage is refused just the same.
r1b="$(new_parent_child_repo plan)"; stub_repo "$r1b"
rc1b=0; approve_in "$r1b" >"$r1b/out.txt" 2>&1 || rc1b=$?
check "1k. a child still at plan is refused too" "[ '$rc1b' -ne 0 ]"
check "1l. and nothing merged" "! grep -q 'pr-merge' '$r1b/gh.log'"
check "1m. the refusal reports its stage as plan" \
  "grep -q 'stage plan' '$r1b/out.txt'"

echo

# ===========================================================================
# BEHAVIOUR 2 — the SAME parent, after the REAL resolve-logs folded the child,
# gets PAST the gate and merges. The gate reads the fold record S231 writes.
# ===========================================================================
r2="$(new_parent_child_repo verify)"; stub_repo "$r2"
rc2f=0; fold_in "$r2" >"$r2/fold.txt" 2>&1 || rc2f=$?
c2="$(cdir_of "$r2")/state.json"
check "2a. the real fold succeeded" "[ '$rc2f' -eq 0 ]"
check "2b. the child carries S231's fold record" "grep -q 'foldedInto' '$c2'"
: >"$r2/gh.log"; : >"$r2/run.log"
rc2=0; approve_in "$r2" >"$r2/out.txt" 2>&1 || rc2=$?
s2="$(pdir_of "$r2")/state.json"
check "2c. approve now gets PAST the open-children gate (no refusal)" \
  "! grep -qi 'logged bug' '$r2/out.txt' || grep -q 'pr-merge' '$r2/gh.log'"
check "2d. it reached the merge" "grep -q 'pr-merge' '$r2/gh.log'"
check "2e. it exited 0" "[ '$rc2' -eq 0 ]"
check "2f. the parent is Done" "grep -q '\"stage\": *\"done\"' '$s2'"

# A child already at `done` (however it got there) is likewise no obstacle.
r2b="$(new_parent_child_repo done)"; stub_repo "$r2b"
rc2b=0; approve_in "$r2b" >"$r2b/out.txt" 2>&1 || rc2b=$?
check "2g. a child at done does not block the merge" "[ '$rc2b' -eq 0 ]"
check "2h. and the merge happened" "grep -q 'pr-merge' '$r2b/gh.log'"

echo

# ===========================================================================
# FIXTURE B — an INITIALIZATION mission at verify whose scaffold ticket
# DECLARED a runner in the mission-local test-command.json.
#   $1 the declared command   $2 (opt) the config's existing testCommand
# ===========================================================================
IID="lcars-20260930-201"
new_init_repo() { # declared [existing-config-cmd] -> repo
  local declared="$1" existing="${2:-}" repo
  repo="$(mktemp -d "$TMPROOT/init.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "lcars/$IID" \
      && printf 'x\n' >a.txt && git add -A && git commit -q -m "lcars($IID) t-001" \
      && git checkout -q "$base" )
  local m="$repo/.git/lcars/missions/$IID"; mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: Establish the test foundation
**Goal:** Stand up a runner.
EOF
  cat >"$m/state.json" <<EOF
{
  "id": "$IID",
  "type": "feature",
  "missionType": "initialization",
  "title": "Establish the test foundation",
  "stage": "verify",
  "review": "open",
  "prUrl": "https://github.com/acme/repo/pull/88",
  "prNumber": 88,
  "created": "2026-09-30T10:00:00Z",
  "githubIssue": 60,
  "branch": "lcars/$IID",
  "base": "$base"
}
EOF
  python3 - "$m/test-command.json" "$declared" <<'PY'
import json,sys
json.dump({"testCommand": sys.argv[2], "establishedBy": "t-001"},
          open(sys.argv[1], "w"), indent=2)
PY
  if [ -n "$existing" ]; then
    python3 - "$repo/.git/lcars/config.json" "$existing" <<'PY'
import json,sys
json.dump({"testCommand": sys.argv[2]}, open(sys.argv[1], "w"), indent=2)
PY
  else
    printf '{\n  "model": "claude-sonnet"\n}\n' >"$repo/.git/lcars/config.json"
  fi
  echo "$repo"
}

approve_init_in() { # repo
  local repo="$1"
  ( cd "$repo" \
      && GH_LOG="$repo/gh.log" \
         LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
         LCARS_HOST_ADAPTER="$repo/host" \
         LCARS_RUN_SCRIPT="$repo/recon" RUN_LOG="$repo/run.log" \
         LCARS_RESOLVE_LOGS_SCRIPT="$repo/recon" \
         LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
         bash "$APPROVE" --mission "$IID" )
}

# The captain's own recorded command — the stdlib runner the weekend clobbered.
CAPTAINS='python3 -m unittest discover -s tests'

# ===========================================================================
# BEHAVIOUR 3 — the captain's recorded testCommand WINS. The weekend replaced
# `python3 -m unittest discover …` with an uninstalled `pytest`.
# ===========================================================================
r3="$(new_init_repo 'pytest' "$CAPTAINS")"; stub_repo "$r3"
CFG3="$r3/.git/lcars/config.json"
rc3=0; approve_init_in "$r3" >"$r3/out.txt" 2>&1 || rc3=$?
S3="$r3/.git/lcars/missions/$IID/state.json"
check "3a. approve still merged (this is not a merge refusal)" "[ '$rc3' -eq 0 ]"
check "3b. the captain's testCommand is UNCHANGED in repo config" \
  "python3 -c \"import json;assert json.load(open('$CFG3'))['testCommand']=='''$CAPTAINS'''\""
check "3c. the declared pytest was NOT written into repo config" \
  "! grep -q '\"testCommand\": *\"pytest\"' '$CFG3'"
check "3d. the declaration is RECORDED on the mission as declaredTestCommand" \
  "grep -q '\"declaredTestCommand\": *\"pytest\"' '$S3'"
check "3e. approve SAYS which command it kept" \
  "grep -q 'unittest discover' '$r3/out.txt'"
check "3f. …and names the declaration it set aside" \
  "grep -q 'pytest' '$r3/out.txt'"
check "3g. the mission still reached Done" \
  "grep -q '\"stage\": *\"done\"' '$S3'"
check "3h. repo config is still valid JSON" \
  "python3 -c \"import json;json.load(open('$CFG3'))\""

# A difference that is ONLY whitespace still keeps the captain's — comparing
# loosely is the rejected wrong answer.
r3b="$(new_init_repo 'npx  vitest   run' 'npx vitest run')"; stub_repo "$r3b"
CFG3B="$r3b/.git/lcars/config.json"
approve_init_in "$r3b" >"$r3b/out.txt" 2>&1 || true
check "3i. a whitespace-only difference STILL keeps the captain's value" \
  "python3 -c \"import json;assert json.load(open('$CFG3B'))['testCommand']=='npx vitest run'\""

# An IDENTICAL declaration is a no-op: config unchanged, nothing set aside.
r3c="$(new_init_repo 'npx vitest run' 'npx vitest run')"; stub_repo "$r3c"
CFG3C="$r3c/.git/lcars/config.json"
approve_init_in "$r3c" >"$r3c/out.txt" 2>&1 || true
check "3j. an identical declaration leaves repo config exactly as it was" \
  "python3 -c \"import json;assert json.load(open('$CFG3C'))['testCommand']=='npx vitest run'\""

echo

# ===========================================================================
# BEHAVIOUR 4 — an ABSENT testCommand is still FILLED (today's behaviour,
# preserved: this is the S185 unlock and nothing about it changes).
# ===========================================================================
r4="$(new_init_repo 'npx vitest run')"; stub_repo "$r4"
CFG4="$r4/.git/lcars/config.json"
check "4a. precondition: repo config has NO testCommand" \
  "! grep -q 'testCommand' '$CFG4'"
rc4=0; approve_init_in "$r4" >"$r4/out.txt" 2>&1 || rc4=$?
check "4b. approve exits 0" "[ '$rc4' -eq 0 ]"
check "4c. the declared command IS promoted into an absent slot" \
  "python3 -c \"import json;assert json.load(open('$CFG4'))['testCommand']=='npx vitest run'\""
check "4d. and approve still announces the unlock" \
  "grep -q 'FOUNDATION ESTABLISHED' '$r4/out.txt'"

echo
# ===========================================================================
# FIXTURE C — a drivable mission, for the drive.pid record.
#
# The probe stands in for the version check, which `cmd_drive` runs right after
# it takes the driver lock. It COPIES the live drive.pid out — so the record is
# OBSERVED while the driver genuinely is running, not reconstructed afterwards —
# and its sleep holds the driver open for as long as a case needs.
#
# Every case gets its OWN mission id: the live-driver count below is a `pgrep -f`
# over the driver's command line, and a leftover driver from an earlier case
# carrying the same id would make that count lie.
# ===========================================================================
ddir_of() { echo "$1/.git/lcars/missions/$2"; }

new_drive_repo() { # id [stage] [awaiting] -> repo
  local did="$1" stage="${2:-plan}" awaiting="${3:-}" repo
  repo="$(mktemp -d "$TMPROOT/drive.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  local m="$repo/.git/lcars/missions/$did"; mkdir -p "$m"
  cat >"$m/prd.md" <<'EOF'
# Mission: A drivable mission
**Goal:** Exist so the driver can take its lock.
EOF
  {
    echo '{'
    printf '  "id": "%s",\n' "$did"
    echo '  "type": "feature",'
    echo '  "title": "A drivable mission",'
    printf '  "stage": "%s",\n' "$stage"
    if [ -n "$awaiting" ]; then
      echo '  "awaitingHuman": true,'
      echo '  "pendingQuestion": "which shape should the card take?",'
    fi
    echo '  "created": "2026-09-30T10:00:00Z",'
    echo '  "githubIssue": 70,'
    printf '  "branch": "lcars/%s",\n' "$did"
    printf '  "base": "%s"\n' "$base"
    echo '}'
  } >"$m/state.json"
  if [ -n "$awaiting" ]; then
    cat >"$m/pending.json" <<'EOF'
{
  "stage": "plan",
  "questions": [ "which shape should the card take?" ]
}
EOF
  fi
  echo '{ "testCommand": "true" }' >"$repo/.git/lcars/config.json"
  echo "$repo"
}

make_probe() { # repo sleep-seconds
  cat >"$1/probe" <<EOF
#!/usr/bin/env bash
if [ -f "\$LCARS_DRIVE_REC" ]; then cp "\$LCARS_DRIVE_REC" "\$LCARS_DRIVE_OBS"; fi
sleep ${2:-0}
exit 0
EOF
  chmod +x "$1/probe"
}

# Run the REAL driver. In the FOREGROUND when $1 is "fg"; otherwise BACKGROUND,
# with `exec` so $! is the DRIVER's own pid (a wrapping subshell would swallow
# the signal the SIGTERM case sends).
drive_fg() { # repo id
  local repo="$1" did="$2"
  ( cd "$repo" && env GH_LOG="$repo/gh.log" WORKER_LOG="$repo/worker.log" \
      LCARS_DRIVE_REC="$(ddir_of "$repo" "$did")/drive.pid" \
      LCARS_DRIVE_OBS="$repo/obs.txt" \
      LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
      LCARS_HOST_ADAPTER="$repo/host" LCARS_WORKER_BIN="$repo/worker" \
      LCARS_VERSION_CHECK_BIN="$repo/probe" \
      bash "$RUN_SH" drive --mission "$did" ) >"$repo/drive.out" 2>&1
}

wait_for()   { local f="$1" n=0; while [ ! -f "$f" ] && [ "$n" -lt 150 ]; do sleep 0.2; n=$((n+1)); done; }
wait_gone()  { local f="$1" n=0; while [ -f "$f" ]  && [ "$n" -lt 250 ]; do sleep 0.2; n=$((n+1)); done; }

echo

# ===========================================================================
# BEHAVIOUR 5 — `run.sh drive` RECORDS itself at $MISSION_DIR/drive.pid while it
# runs, and REMOVES the record on exit: on a clean stop, on a NON-ZERO exit, and
# when it is killed mid-flight. Nothing infers a live driver from `pgrep`.
# ===========================================================================
D5="lcars-20260930-351"
r5="$(new_drive_repo "$D5" verify)"; stub_repo "$r5"; make_probe "$r5" 0
DREC5="$(ddir_of "$r5" "$D5")/drive.pid"
rc5=0; drive_fg "$r5" "$D5" || rc5=$?
check "5a. the driver WROTE drive.pid while it was running" "[ -s '$r5/obs.txt' ]"
check "5b. the record's first line is a pid" \
  "head -1 '$r5/obs.txt' | grep -qE '^[0-9]+\$'"
check "5c. the record's second line is a started-at stamp" \
  "sed -n 2p '$r5/obs.txt' | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'"
check "5d. drive.pid is REMOVED when the driver exits cleanly" "[ ! -f '$DREC5' ]"
check "5e. no worker was spawned" "[ ! -s '$r5/worker.log' ]"

# A NON-ZERO exit must clean up too — the trap covers the whole class of
# abnormal exits, a `die` included.
D5B="lcars-20260930-352"
r5b="$(new_drive_repo "$D5B" nonsense)"; stub_repo "$r5b"; make_probe "$r5b" 0
DREC5B="$(ddir_of "$r5b" "$D5B")/drive.pid"
rc5b=0; drive_fg "$r5b" "$D5B" || rc5b=$?
check "5f. precondition: that drive really did exit non-zero" "[ '$rc5b' -ne 0 ]"
check "5g. it still recorded itself" "[ -s '$r5b/obs.txt' ]"
check "5h. and drive.pid is gone after the failure exit" "[ ! -f '$DREC5B' ]"

# KILLED mid-flight (SIGTERM): the driver-lock trap is armed on INT/TERM too.
D5C="lcars-20260930-353"
r5c="$(new_drive_repo "$D5C" plan)"; stub_repo "$r5c"; make_probe "$r5c" 4
DREC5C="$(ddir_of "$r5c" "$D5C")/drive.pid"
( cd "$r5c" && exec env GH_LOG="$r5c/gh.log" WORKER_LOG="$r5c/worker.log" \
    LCARS_DRIVE_REC="$DREC5C" LCARS_DRIVE_OBS="$r5c/obs.txt" \
    LCARS_GH_BIN="$r5c/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$r5c/host" LCARS_WORKER_BIN="$r5c/worker" \
    LCARS_VERSION_CHECK_BIN="$r5c/probe" \
    bash "$RUN_SH" drive --mission "$D5C" ) >"$r5c/drive.out" 2>&1 &
kpid=$!
wait_for "$DREC5C"
check "5i. drive.pid EXISTS on disk while the driver is genuinely live" \
  "[ -f '$DREC5C' ]"
LIVE5="$(head -1 "$DREC5C" 2>/dev/null)"
check "5j. the recorded pid is a LIVE process" \
  "[ -n '${LIVE5:-}' ] && kill -0 '${LIVE5:-0}' 2>/dev/null"
check "5k. and it IS the driver's own pid" "[ '${LIVE5:-0}' = '$kpid' ]"
kill -TERM "$kpid" 2>/dev/null
wait "$kpid" 2>/dev/null
wait_gone "$DREC5C"
check "5l. drive.pid is removed when the driver is SIGTERMed" "[ ! -f '$DREC5C' ]"
pkill -TERM -f "drive --mission $D5C" 2>/dev/null || true

echo

# ===========================================================================
# BEHAVIOUR 6 — with a LIVE driver, `respond answer` records the answer, clears
# the gate, SAYS a drive is already running, and spawns NO second driver.
# ===========================================================================
D6="lcars-20260930-361"
r6="$(new_drive_repo "$D6" plan awaiting)"; stub_repo "$r6"; make_probe "$r6" 12
DREC6="$(ddir_of "$r6" "$D6")/drive.pid"
( cd "$r6" && exec env GH_LOG="$r6/gh.log" WORKER_LOG="$r6/worker.log" \
    LCARS_DRIVE_REC="$DREC6" LCARS_DRIVE_OBS="$r6/obs.txt" \
    LCARS_GH_BIN="$r6/gh" LCARS_GIT_BIN="$(command -v git)" \
    LCARS_HOST_ADAPTER="$r6/host" LCARS_WORKER_BIN="$r6/worker" \
    LCARS_VERSION_CHECK_BIN="$r6/probe" \
    bash "$RUN_SH" drive --mission "$D6" ) >"$r6/drive.out" 2>&1 &
dpid6=$!
wait_for "$DREC6"
check "6a. precondition: a real driver is live and has recorded itself" \
  "[ -f '$DREC6' ] && kill -0 \"\$(head -1 '$DREC6')\" 2>/dev/null"
make_run_stub "$r6/run-spy" 0
rc6=0
( cd "$r6" && GH_LOG="$r6/gh.log" RUN_LOG="$r6/spawn.log" \
    LCARS_GH_BIN="$r6/gh" LCARS_RUN_SCRIPT="$r6/run-spy" \
    bash "$RESPOND" answer --mission "$D6" --answer "ok, use the compact card" \
    >"$r6/out.txt" 2>&1 ) || rc6=$?
check "6b. respond exits 0 (the answer IS recorded)" "[ '$rc6' -eq 0 ]"
check "6c. the answer is persisted in answers.json" \
  "grep -q 'compact card' '$(ddir_of "$r6" "$D6")/answers.json'"
check "6d. the awaiting-human gate is cleared" \
  "! grep -q '\"awaitingHuman\": *true' '$(ddir_of "$r6" "$D6")/state.json'"
check "6e. respond SAYS a drive is already running for this mission" \
  "grep -q 'a drive is already running for $D6' '$r6/out.txt'"
check "6f. …and names the pid and when it started" \
  "grep -qE 'pid [0-9]+ since [0-9]{4}-' '$r6/out.txt'"
check "6g. …and says the live drive will pick the answer up" \
  "grep -qi 'pick it up' '$r6/out.txt'"
check "6h. it spawned NO second driver" "[ ! -s '$r6/spawn.log' ]"
check "6i. exactly ONE live driver process for this mission" \
  "[ \"\$(pgrep -f 'drive --mission $D6' | wc -l | tr -d ' ')\" = 1 ]"
kill -TERM "$dpid6" 2>/dev/null; wait "$dpid6" 2>/dev/null
pkill -TERM -f "drive --mission $D6" 2>/dev/null || true
wait_gone "$DREC6"
check "6j. and once that driver is gone, so is its record" "[ ! -f '$DREC6' ]"

echo

# ===========================================================================
# BEHAVIOUR 7 — a STALE drive.pid (the process is gone) counts as ABSENT:
# respond resumes exactly as it does today.
# ===========================================================================
D7="lcars-20260930-371"
r7="$(new_drive_repo "$D7" plan awaiting)"; stub_repo "$r7"
printf '999999\n2026-09-30T12:00:00Z\n' >"$(ddir_of "$r7" "$D7")/drive.pid"
make_run_stub "$r7/run-spy" 0
rc7=0
( cd "$r7" && GH_LOG="$r7/gh.log" RUN_LOG="$r7/spawn.log" \
    LCARS_GH_BIN="$r7/gh" LCARS_RUN_SCRIPT="$r7/run-spy" \
    bash "$RESPOND" answer --mission "$D7" --answer "go on" \
    >"$r7/out.txt" 2>&1 ) || rc7=$?
check "7a. respond exits 0 over a stale record" "[ '$rc7' -eq 0 ]"
check "7b. it RESUMED the drive (a stale pid counts as absent)" \
  "grep -q 'drive --mission $D7' '$r7/spawn.log'"
check "7c. it did NOT claim a drive was already running" \
  "! grep -q 'already running for' '$r7/out.txt'"

# …and with NO record at all, respond resumes exactly as before (unchanged).
D7B="lcars-20260930-372"
r7b="$(new_drive_repo "$D7B" plan awaiting)"; stub_repo "$r7b"
make_run_stub "$r7b/run-spy" 0
( cd "$r7b" && GH_LOG="$r7b/gh.log" RUN_LOG="$r7b/spawn.log" \
    LCARS_GH_BIN="$r7b/gh" LCARS_RUN_SCRIPT="$r7b/run-spy" \
    bash "$RESPOND" answer --mission "$D7B" --answer "go on" \
    >"$r7b/out.txt" 2>&1 ) || true
check "7d. with NO record, respond resumes as it always did" \
  "grep -q 'drive --mission $D7B' '$r7b/spawn.log'"

# …and the LCARS_RESPOND_RESUME=0 path is untouched: it prints the command and
# spawns nothing, live driver or not.
D7C="lcars-20260930-373"
r7c="$(new_drive_repo "$D7C" plan awaiting)"; stub_repo "$r7c"
printf '%s\n2026-09-30T12:00:00Z\n' "$$" >"$(ddir_of "$r7c" "$D7C")/drive.pid"
make_run_stub "$r7c/run-spy" 0
( cd "$r7c" && GH_LOG="$r7c/gh.log" RUN_LOG="$r7c/spawn.log" \
    LCARS_RESPOND_RESUME=0 \
    LCARS_GH_BIN="$r7c/gh" LCARS_RUN_SCRIPT="$r7c/run-spy" \
    bash "$RESPOND" answer --mission "$D7C" --answer "go on" \
    >"$r7c/out.txt" 2>&1 ) || true
check "7e. LCARS_RESPOND_RESUME=0 still just prints the resume command" \
  "grep -q 'Resume plan with' '$r7c/out.txt'"
check "7f. …and spawns nothing" "[ ! -s '$r7c/spawn.log' ]"

echo

# ===========================================================================
# BEHAVIOUR 8 — ONE record, TWO consumers. `lcars` auto-advance reads the same
# drive.pid and refuses to start a second driver on a live mission.
# ===========================================================================
D8="lcars-20260930-381"
r8="$(new_drive_repo "$D8" plan)"; stub_repo "$r8"
printf '%s\n2026-09-30T12:00:00Z\n' "$$" >"$(ddir_of "$r8" "$D8")/drive.pid"
make_run_stub "$r8/run-spy" 0
rc8=0
( cd "$r8" && GH_LOG="$r8/gh.log" RUN_LOG="$r8/spawn.log" \
    LCARS_GH_BIN="$r8/gh" LCARS_RUN_SCRIPT="$r8/run-spy" \
    LCARS_VERSION_CHECK_BIN="/usr/bin/true" \
    bash "$LCARS_SH" "$D8" >"$r8/out.txt" 2>&1 ) || rc8=$?
check "8a. \`lcars <id>\` on a live-driven mission says so" \
  "grep -q 'a drive is already running for $D8' '$r8/out.txt'"
check "8b. …and starts no second driver" "[ ! -s '$r8/spawn.log' ]"

# The control: with no record it drives as it always did.
D8B="lcars-20260930-382"
r8b="$(new_drive_repo "$D8B" plan)"; stub_repo "$r8b"
make_run_stub "$r8b/run-spy" 0
( cd "$r8b" && GH_LOG="$r8b/gh.log" RUN_LOG="$r8b/spawn.log" \
    LCARS_GH_BIN="$r8b/gh" LCARS_RUN_SCRIPT="$r8b/run-spy" \
    LCARS_VERSION_CHECK_BIN="/usr/bin/true" \
    bash "$LCARS_SH" "$D8B" >"$r8b/out.txt" 2>&1 ) || true
check "8c. CONTROL: with no record, \`lcars <id>\` drives" \
  "grep -q 'drive --mission $D8B' '$r8b/spawn.log'"

echo

# ===========================================================================
# BEHAVIOUR 9 — the shared reader itself. It lives in lcars-common.sh so both
# consumers read ONE record, and a stale pid reads as absent.
# ===========================================================================
check "9a. the shared drive-record reader lives in lcars-common.sh" \
  "grep -q 'lcars_drive_live' '$COMMON_LIB'"
probe_dir="$TMPROOT/rec"; mkdir -p "$probe_dir"
live_out="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_drive_live "$probe_dir" )"; live_rc=$?
check "9b. no record → non-zero, and nothing printed" \
  "[ '$live_rc' -ne 0 ] && [ -z '$live_out' ]"
printf '999999\n2026-09-30T12:00:00Z\n' >"$probe_dir/drive.pid"
stale_rc=0
( . "$COMMON_LIB" >/dev/null 2>&1; lcars_drive_live "$probe_dir" >/dev/null ) || stale_rc=$?
check "9c. a STALE pid reads as absent" "[ '$stale_rc' -ne 0 ]"
printf '%s\n2026-09-30T12:00:00Z\n' "$$" >"$probe_dir/drive.pid"
live2="$( . "$COMMON_LIB" >/dev/null 2>&1; lcars_drive_live "$probe_dir" )"; live2_rc=$?
check "9d. a LIVE pid reads as present, with its pid and its stamp" \
  "[ '$live2_rc' -eq 0 ] && grep -q '$$' <<<'$live2' && grep -q '2026-09-30T12:00:00Z' <<<'$live2'"
# …and neither consumer INFERS one. Comment lines are excluded on purpose: the
# design notes in both files name `pgrep` as the rejected approach, and a check
# that cannot tell a warning from a call would have to be deleted to stay green.
code_only() { grep -vE '^[[:space:]]*#' "$1"; }
check "9e. neither consumer CALLS pgrep to detect a drive" \
  "! code_only '$REPO_ROOT/skills/lcars-respond/respond.sh' | grep -q 'pgrep' \
     && ! code_only '$REPO_ROOT/skills/lcars/lcars.sh' | grep -q 'pgrep'"

# ===========================================================================
# BEHAVIOUR 10 — THE UNREADABLE CHILD RECORD (S232 fix round 1, D1).
#
# The gate keyed on ONE line: `[ "$(json_str "$cstate" parentMission)" = "$MISSION_ID" ]
# || continue`. json_str is a sed reader, so a state.json that is scrambled or
# blank yields EMPTY for every field — indistinguishable from a record that says
# "not a child of this Mission" — and the child was SILENTLY skipped. The tester
# damaged only the child's state.json, three ways, and got 3 of 3 MERGED with no
# refusal and no warning at all: the one shape where the new gate was WORSE than
# nothing, because it was silent.
#
# The parent↔child link is ONE-DIRECTIONAL (only the child records
# `parentMission`; log.sh writes nothing on the parent side and there is no
# loggedChildren list), so an unreadable record genuinely cannot be attributed.
# The cure therefore fails closed on AMBIGUITY:
#
#   • a state.json that EXISTS but cannot be READ by the gate's own reader
#     (scrambled, blank, truncated past its id/stage) is unambiguously broken →
#     REFUSE, naming the exact file. Even one belonging to an unrelated mission:
#     nothing can tell us it is unrelated. That is the house precedent
#     (init-mission.test.sh B5, "an unreadable mission ordering REFUSES").
#   • a mission DIRECTORY with NO state.json is NOT blocked, because a mission
#     directory legitimately exists before its state.json is written (log.sh
#     mkdir vs its state write; same in file.sh), so an interrupted filing or a
#     partial .git/lcars restore leaves one, and it is invisible to every other
#     LCARS surface (status / respond / resolve-logs all glob */state.json).
#     Blocking there would brick approve over a record no other verb thinks
#     exists. It is WARNED about instead, by name — never silent again.
# ===========================================================================
damage_child() { # repo  scrambled|blank|deleted
  local repo="$1" how="$2" cs; cs="$(cdir_of "$repo")/state.json"
  case "$how" in
    scrambled) printf '{ not json\n' >"$cs" ;;
    blank)     : >"$cs" ;;
    deleted)   rm -f "$cs" ;;
  esac
}

# --- scrambled: refuse, name the file ---------------------------------------
r10="$(new_parent_child_repo verify)"; stub_repo "$r10"
damage_child "$r10" scrambled
rc10=0; approve_in "$r10" >"$r10/out.txt" 2>&1 || rc10=$?
s10="$(pdir_of "$r10")/state.json"
check "10a. a SCRAMBLED child state.json is REFUSED (fail closed)" "[ '$rc10' -ne 0 ]"
check "10b. nothing merged" "! grep -q 'pr-merge' '$r10/gh.log'"
check "10c. it never ran the reconcile pre-step" "! grep -q 'reconcile' '$r10/run.log'"
check "10d. the parent stays at verify" "grep -q '\"stage\": *\"verify\"' '$s10'"
check "10e. the refusal names the EXACT unreadable file" \
  "grep -q '$CID/state.json' '$r10/out.txt'"
check "10f. the refusal ends with the merge promise" \
  "grep -q 'Nothing has been merged' '$r10/out.txt'"

# --- blank: same ------------------------------------------------------------
r10b="$(new_parent_child_repo verify)"; stub_repo "$r10b"
damage_child "$r10b" blank
rc10b=0; approve_in "$r10b" >"$r10b/out.txt" 2>&1 || rc10b=$?
check "10g. a BLANK child state.json is REFUSED" "[ '$rc10b' -ne 0 ]"
check "10h. nothing merged" "! grep -q 'pr-merge' '$r10b/gh.log'"
check "10i. and that refusal names the file too" \
  "grep -q '$CID/state.json' '$r10b/out.txt'"

# --- deleted: the DECIDED shape — merges, but says so, by name --------------
r10c="$(new_parent_child_repo verify)"; stub_repo "$r10c"
damage_child "$r10c" deleted
rc10c=0; approve_in "$r10c" >"$r10c/out.txt" 2>&1 || rc10c=$?
check "10j. a DELETED child state.json does NOT block the merge (decided)" \
  "[ '$rc10c' -eq 0 ] && grep -q 'pr-merge' '$r10c/gh.log'"
check "10k. …but it is NEVER silent: the directory is named" \
  "grep -q '$CID' '$r10c/out.txt'"
check "10l. …and the warning says what it means" \
  "grep -qi 'no state.json' '$r10c/out.txt'"
check "10m. …warned ONCE, not once per gate call" \
  "[ \"\$(grep -c 'no state.json' '$r10c/out.txt')\" -eq 1 ]"

# --- CONTROL: an unreadable record that is NOT a bug and NOT this parent's ---
# Nothing can tell us it is unrelated — that is the whole ambiguity — so it
# refuses too. Asserted so the next reader knows this was a DECISION.
r10d="$(new_parent_child_repo verify)"; stub_repo "$r10d"
rc10df=0; fold_in "$r10d" >"$r10d/fold.txt" 2>&1 || rc10df=$?
: >"$r10d/gh.log"; : >"$r10d/run.log"
OID="lcars-20260930-999"
mkdir -p "$r10d/.git/lcars/missions/$OID"
printf '{ not json\n' >"$r10d/.git/lcars/missions/$OID/state.json"
rc10d=0; approve_in "$r10d" >"$r10d/out.txt" 2>&1 || rc10d=$?
check "10n. the folded child folded cleanly (fixture sanity)" "[ '$rc10df' -eq 0 ]"
check "10o. an UNRELATED unreadable record refuses too (ambiguity, not attribution)" \
  "[ '$rc10d' -ne 0 ]"
check "10p. nothing merged" "! grep -q 'pr-merge' '$r10d/gh.log'"
check "10q. and it names that record" \
  "grep -q '$OID/state.json' '$r10d/out.txt'"

# --- CONTROL: the two known-good ends, so this section can detect its own break
r10e="$(new_parent_child_repo verify)"; stub_repo "$r10e"
rc10e=0; approve_in "$r10e" >"$r10e/out.txt" 2>&1 || rc10e=$?
check "10r. CONTROL: an INTACT open child still refuses" \
  "[ '$rc10e' -ne 0 ] && grep -q 'logged bug(s) still open' '$r10e/out.txt'"
check "10s. CONTROL: …and for the OLD reason, not the unreadable one" \
  "! grep -qi 'cannot be read' '$r10e/out.txt'"

r10f="$(new_parent_child_repo verify)"; stub_repo "$r10f"
rc10ff=0; fold_in "$r10f" >"$r10f/fold.txt" 2>&1 || rc10ff=$?
: >"$r10f/gh.log"; : >"$r10f/run.log"
rc10f=0; approve_in "$r10f" >"$r10f/out.txt" 2>&1 || rc10f=$?
check "10t. CONTROL: a repo whose children are all FOLDED still MERGES" \
  "[ '$rc10ff' -eq 0 ] && [ '$rc10f' -eq 0 ] && grep -q 'pr-merge' '$r10f/gh.log'"
check "10u. CONTROL: …with no unreadable-record noise at all" \
  "! grep -qi 'cannot be read\|no state.json' '$r10f/out.txt'"

# ===========================================================================
# BEHAVIOUR 11 — THE TWO REMAINING WAYS A RECORD IS UNATTRIBUTABLE
# (S232 fix round 2, D1–D4).
#
# Round 1's refusal states the right rule — "an unreadable record cannot be
# attributed either way" — but applied it to only ONE of the two ways a record
# can be unattributable, so the rule a captain would infer was true with two
# exceptions he could never predict. This section closes the class.
#
# D1. A SYMLINK or a DIRECTORY where state.json should be merged SILENTLY, and
#     was classed as the LENIENT "mission directory with no state.json" case.
#     That branch's own rationale — "a mission directory exists before its
#     state.json is written, so an interrupted filing leaves one" — is FALSE for
#     both shapes: an interrupted filing cannot produce a dangling symlink or a
#     directory named state.json, and `mkdir …/state.json` was a deliberate
#     bypass of the gate. `[ -f ]` is false for both, which is exactly how they
#     fell through; `[ -e ]`/`[ -L ]` tell "something is there" from "nothing is
#     there". So: a path that EXISTS where the record should be but cannot be
#     opened and read as a regular file is UNREADABLE (refuse, name it). Only a
#     genuinely ABSENT path keeps the lenient warning.
#
# D2. A record that lost ONLY its parent link merged SILENTLY — valid JSON, id
#     and stage intact, so the gate trusted it, and with no parentMission it
#     simply failed the child test and was skipped. Nothing can attribute that
#     record either, which is the exact condition the refusal exists for. The
#     discriminator is `type: bug` AND no parentMission AND stage != done: a bug
#     record MUST have a parent to be a logged bug (log.sh requires `type: bug`
#     and always writes parentMission), while an ordinary mission legitimately
#     has none. It WARNS rather than refuses, because `lcars file` also accepts
#     `**Type:** bug` (file.sh: `case "$TYPE" in feature|bug)`) and writes NO
#     parentMission, so a standalone bug mission is a LEGITIMATE record of this
#     shape and a refusal would brick approve on a healthy repo.
#
# D3. A `chmod 000` record leaked `sed: …: Permission denied` above the refusal.
# D4. The refusal pointed at the wrong mission ("cannot tell whether it is a
#     logged bug of X" about a mission that never had one).
# ===========================================================================

# --- D1: a DANGLING SYMLINK where the record should be ----------------------
r11="$(new_parent_child_repo verify)"; stub_repo "$r11"
rm -f "$(cdir_of "$r11")/state.json"
ln -s "$(cdir_of "$r11")/gone.json" "$(cdir_of "$r11")/state.json"
rc11=0; approve_in "$r11" >"$r11/out.txt" 2>&1 || rc11=$?
check "11a. a DANGLING SYMLINK where state.json should be is REFUSED" "[ '$rc11' -ne 0 ]"
check "11b. nothing merged" "! grep -q 'pr-merge' '$r11/gh.log'"
check "11c. the refusal names the exact path" "grep -q '$CID/state.json' '$r11/out.txt'"
check "11d. …and it is NOT classed as the lenient no-record case" \
  "! grep -qi 'no state.json' '$r11/out.txt'"

# --- D1: a DIRECTORY named state.json (the deliberate bypass) ---------------
r11b="$(new_parent_child_repo verify)"; stub_repo "$r11b"
rm -f "$(cdir_of "$r11b")/state.json"; mkdir -p "$(cdir_of "$r11b")/state.json"
rc11b=0; approve_in "$r11b" >"$r11b/out.txt" 2>&1 || rc11b=$?
check "11e. a DIRECTORY named state.json is REFUSED" "[ '$rc11b' -ne 0 ]"
check "11f. nothing merged" "! grep -q 'pr-merge' '$r11b/gh.log'"
check "11g. the refusal names the exact path" "grep -q '$CID/state.json' '$r11b/out.txt'"
check "11h. …and it is NOT classed as the lenient no-record case" \
  "! grep -qi 'no state.json' '$r11b/out.txt'"

# --- D3: chmod 000 still refuses, with NO raw tool error above the refusal ---
r11c="$(new_parent_child_repo verify)"; stub_repo "$r11c"
chmod 000 "$(cdir_of "$r11c")/state.json"
rc11c=0; approve_in "$r11c" >"$r11c/out.txt" 2>&1 || rc11c=$?
chmod 644 "$(cdir_of "$r11c")/state.json"
check "11i. an UNREADABLE-PERMISSIONS record still refuses (round 1, kept)" \
  "[ '$rc11c' -ne 0 ] && grep -q '$CID/state.json' '$r11c/out.txt'"
check "11j. …and no raw reader error leaks to the captain" \
  "! grep -qi 'Permission denied' '$r11c/out.txt' && ! grep -q '^sed:' '$r11c/out.txt'"

# --- D4: the refusal no longer claims the damaged record is this Mission's ---
r11d="$(new_parent_child_repo verify)"; stub_repo "$r11d"
rc11df=0; fold_in "$r11d" >"$r11d/fold.txt" 2>&1 || rc11df=$?
: >"$r11d/gh.log"; : >"$r11d/run.log"
UID4="lcars-20260930-500"
mkdir -p "$r11d/.git/lcars/missions/$UID4"
printf '{ not json\n' >"$r11d/.git/lcars/missions/$UID4/state.json"
rc11d=0; approve_in "$r11d" >"$r11d/out.txt" 2>&1 || rc11d=$?
check "11k. the fixture folded cleanly" "[ '$rc11df' -eq 0 ]"
check "11l. an unrelated unreadable record still refuses" "[ '$rc11d' -ne 0 ]"
check "11m. the refusal RULES OUT rather than asserting whose record it is" \
  "grep -q 'cannot rule out' '$r11d/out.txt' && ! grep -q 'cannot tell whether it is a logged bug' '$r11d/out.txt'"
check "11n. it still names the file, the irreversibility and the remedy" \
  "grep -q '$UID4/state.json' '$r11d/out.txt' && grep -qi 'irreversible' '$r11d/out.txt' \
     && grep -q 'then approve again' '$r11d/out.txt'"
check "11o. it says plainly that removing the whole directory is safe" \
  "grep -qi 'directory' '$r11d/out.txt' && grep -qi 'safe' '$r11d/out.txt'"
check "11p. …and still ends with the merge promise" \
  "grep -q 'Nothing has been merged' '$r11d/out.txt'"

# --- D2: a bug record that lost ONLY its parent link ------------------------
# Built from the shape `lcars log` actually writes, with parentMission /
# parentIssue / origin removed — valid JSON, id and stage intact.
orphan_bug_in() { # repo  id  stage  flavour(plain|bom|trailing-comma|half)
  local repo="$1" oid="$2" ostage="$3" flavour="${4:-plain}" d
  d="$repo/.git/lcars/missions/$oid"; mkdir -p "$d"
  case "$flavour" in
    bom)   printf '\xef\xbb\xbf' >"$d/state.json" ;;
    *)     : >"$d/state.json" ;;
  esac
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$oid"
    printf '  "type": "bug",\n'
    printf '  "title": "the mix ratio status line is wrong",\n'
    printf '  "stage": "%s",\n' "$ostage"
    printf '  "created": "2026-09-30T11:30:00Z",\n'
    printf '  "githubIssue": 61,\n'
    case "$flavour" in
      half) printf '  "branch": "lcars/%s"' "$oid" ;;   # truncated, never closed
      trailing-comma) printf '  "branch": "lcars/%s",\n}\n' "$oid" ;;
      *)    printf '  "branch": "lcars/%s"\n}\n' "$oid" ;;
    esac
  } >>"$d/state.json"
}

r11e="$(new_parent_child_repo verify)"; stub_repo "$r11e"
rc11ef=0; fold_in "$r11e" >"$r11e/fold.txt" 2>&1 || rc11ef=$?
: >"$r11e/gh.log"; : >"$r11e/run.log"
orphan_bug_in "$r11e" lcars-20260930-601 verify plain
rc11e=0; approve_in "$r11e" >"$r11e/out.txt" 2>&1 || rc11e=$?
check "11q. a bug record with NO parent link is NEVER SILENT again" \
  "grep -qi 'no parent link' '$r11e/out.txt'"
check "11r. …it names the record" "grep -q 'lcars-20260930-601' '$r11e/out.txt'"
check "11s. …and it WARNS rather than blocking (a standalone filed bug is legal)" \
  "[ '$rc11e' -eq 0 ] && grep -q 'pr-merge' '$r11e/gh.log'"
check "11t. …warned ONCE, not once per gate call" \
  "[ \"\$(grep -ci 'no parent link' '$r11e/out.txt')\" -eq 1 ]"

# the three malformed flavours of the same shape
for fl in bom trailing-comma half; do
  rx="$(new_parent_child_repo verify)"; stub_repo "$rx"
  rcxf=0; fold_in "$rx" >"$rx/fold.txt" 2>&1 || rcxf=$?
  : >"$rx/gh.log"; : >"$rx/run.log"
  orphan_bug_in "$rx" lcars-20260930-602 verify "$fl"
  rcx=0; approve_in "$rx" >"$rx/out.txt" 2>&1 || rcx=$?
  check "11u[$fl]. the $fl variant is reported too, never silent" \
    "grep -qi 'no parent link\|cannot be read' '$rx/out.txt' && grep -q 'lcars-20260930-602' '$rx/out.txt'"
done

# --- CONTROL: an ORDINARY mission with no parent link is UNTOUCHED -----------
r11f="$(new_parent_child_repo verify)"; stub_repo "$r11f"
rc11ff=0; fold_in "$r11f" >"$r11f/fold.txt" 2>&1 || rc11ff=$?
: >"$r11f/gh.log"; : >"$r11f/run.log"
SOLO="lcars-20260930-700"
mkdir -p "$r11f/.git/lcars/missions/$SOLO"
cat >"$r11f/.git/lcars/missions/$SOLO/state.json" <<EOF
{
  "id": "$SOLO",
  "type": "feature",
  "title": "a standalone mission of its own",
  "stage": "plan",
  "created": "2026-09-30T09:00:00Z",
  "branch": "lcars/$SOLO",
  "base": "main"
}
EOF
rc11f=0; approve_in "$r11f" >"$r11f/out.txt" 2>&1 || rc11f=$?
check "11v. CONTROL: an ordinary standalone mission with no parent link MERGES" \
  "[ '$rc11f' -eq 0 ] && grep -q 'pr-merge' '$r11f/gh.log'"
check "11w. CONTROL: …and is never mentioned at all" \
  "! grep -q '$SOLO' '$r11f/out.txt'"

# --- CONTROL: a DONE mission's record must keep NOT blocking -----------------
# Load-bearing for the whole trade-off: it is what stops a repo full of old
# finished missions wedging the captain months later.
r11g="$(new_parent_child_repo verify)"; stub_repo "$r11g"
rc11gf=0; fold_in "$r11g" >"$r11g/fold.txt" 2>&1 || rc11gf=$?
: >"$r11g/gh.log"; : >"$r11g/run.log"
orphan_bug_in "$r11g" lcars-20260930-800 done plain
rc11g=0; approve_in "$r11g" >"$r11g/out.txt" 2>&1 || rc11g=$?
check "11x. CONTROL: a DONE mission's damaged record does NOT block the merge" \
  "[ '$rc11g' -eq 0 ] && grep -q 'pr-merge' '$r11g/gh.log'"
check "11y. CONTROL: …and is not even warned about" \
  "! grep -q 'lcars-20260930-800' '$r11g/out.txt'"

# --- CONTROL: the known-good ends again, AFTER this round's widening ---------
r11h="$(new_parent_child_repo verify)"; stub_repo "$r11h"
rc11h=0; approve_in "$r11h" >"$r11h/out.txt" 2>&1 || rc11h=$?
check "11z. CONTROL: an INTACT open child still refuses for the OLD reason" \
  "[ '$rc11h' -ne 0 ] && grep -q 'logged bug(s) still open' '$r11h/out.txt' \
     && ! grep -qi 'cannot be read\|no parent link' '$r11h/out.txt'"

r11i="$(new_parent_child_repo verify)"; stub_repo "$r11i"
rc11if=0; fold_in "$r11i" >"$r11i/fold.txt" 2>&1 || rc11if=$?
: >"$r11i/gh.log"; : >"$r11i/run.log"
rc11i=0; approve_in "$r11i" >"$r11i/out.txt" 2>&1 || rc11i=$?
check "11aa. CONTROL: a properly FOLDED child still merges with NO noise" \
  "[ '$rc11if' -eq 0 ] && [ '$rc11i' -eq 0 ] && grep -q 'pr-merge' '$r11i/gh.log' \
     && ! grep -qi 'cannot be read\|no state.json\|no parent link' '$r11i/out.txt'"

# --- CONTROL: a genuinely ABSENT record keeps the LENIENT warning ------------
r11j="$(new_parent_child_repo verify)"; stub_repo "$r11j"
rm -f "$(cdir_of "$r11j")/state.json"
rc11j=0; approve_in "$r11j" >"$r11j/out.txt" 2>&1 || rc11j=$?
check "11bb. CONTROL: a genuinely ABSENT state.json still only WARNS and merges" \
  "[ '$rc11j' -eq 0 ] && grep -q 'pr-merge' '$r11j/gh.log' && grep -qi 'no state.json' '$r11j/out.txt'"

echo
printf 'approve-side-effects: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
