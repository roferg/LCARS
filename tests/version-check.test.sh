#!/usr/bin/env bash
#
# Tests for the throttled version CHECK + ask-to-update helper
# (skills/lcars-version/check.sh) and its wiring into the drive loop.
#
# check.sh is the ONE shared helper. Interactive entries call it in `ask` mode;
# headless paths (`run.sh drive`, resolve-logs) call it in `warn` mode. It:
#   - throttles the `git fetch` via a user-level stamp file (< TTL ⇒ cache, no fetch)
#   - computes MULTIPLE verdicts at once: SOURCE_BEHIND / REPO_STALE / DRIFT / CURRENT
#   - in ASK mode offers the update (default ENTER = No):
#       SOURCE_BEHIND ⇒ ff-only pull on a CLEAN MAIN source → install → lcars update
#       REPO_STALE only ⇒ just `lcars update` (no pull, no install)
#       unsafe source (dirty / branched / worktree-held / diverged) ⇒ reason + continue
#   - NEVER fails the calling verb; a fetch failure degrades to a warning
#   - honours LCARS_VERSION_CHECK=0 as a global kill switch (zero git calls)
#
# Everything external is env-injected — git runs against LOCAL fixtures (a temp
# clone + a temp bare "origin"), install/update are recording stubs, stdin is
# scripted. ZERO tokens, ZERO network.
#
# Usage: bash tests/version-check.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$REPO_ROOT/skills/lcars-version/check.sh"
RUN="$REPO_ROOT/skills/lcars-run/run.sh"
REAL_UPDATE="$REPO_ROOT/skills/lcars-update/update.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- a git wrapper that COUNTS fetches + records pull, then delegates -------
# Lets us assert the throttle (fetch count) and the update ORDER (pull marker)
# while still running real git against the fixtures.
make_git_stub() {
  local p="$1" fetchlog="$2" orderlog="$3"
  cat >"$p" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    fetch) echo fetch >> "$fetchlog" ;;
    pull)  echo pull  >> "$orderlog" ;;
  esac
done
exec git "\$@"
EOF
  chmod +x "$p"
}

make_gh_stub() {
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$1"
}

# install stub: records "install" into the order log.
make_install_stub() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
echo install >> "$2"
EOF
  chmod +x "$1"
}

# update stub: records "update" into the order log, then delegates to the REAL
# lcars update so the repo stamp actually moves (asserting "ends current").
make_update_stub() {
  local p="$1" orderlog="$2" gh="$3"
  cat >"$p" <<EOF
#!/usr/bin/env bash
echo update >> "$orderlog"
LCARS_GH_BIN="$gh" bash "$REAL_UPDATE" "\$@"
EOF
  chmod +x "$p"
}

# --- fixture: a bare "origin" + a source clone ----------------------------
# mk_fixture <remote_version> [extra_drift_commit=0|1]
#   origin main = genesis(VERSION 2026.7.1)[, bump to <remote_version>][, drift].
#   FX/src is a fresh clone of it (at the tip). Callers reset/branch/dirty SRC as
#   the verdict under test requires. Copies lcars-common.sh into src so check.sh
#   (LCARS_REPO=src) resolves lcars_config_get for the REPO_STALE verdict.
mk_fixture() {
  local remote="$1" drift="${2:-0}"
  FX="$(mktemp -d "$TMPROOT/fx.XXXX")"
  git init -q --bare "$FX/origin.git"
  git clone -q "$FX/origin.git" "$FX/seed" 2>/dev/null
  (
    cd "$FX/seed"
    git config user.email t@t; git config user.name t
    mkdir -p skills/lcars-init
    cp "$REPO_ROOT/skills/lcars-init/lcars-common.sh" skills/lcars-init/
    printf '2026.7.1\n' >VERSION
    git add -A && git commit -qm genesis
    if [ "$remote" != "2026.7.1" ]; then
      printf '%s\n' "$remote" >VERSION
      git add -A && git commit -qm "bump $remote"
    fi
    if [ "$drift" = "1" ]; then
      printf 'drift\n' >README.md            # a commit that does NOT touch VERSION
      git add -A && git commit -qm "unversioned change"
    fi
    git push -q origin HEAD:main
  )
  git clone -q "$FX/origin.git" "$FX/src" 2>/dev/null
  ( cd "$FX/src" && git config user.email t@t && git config user.name t )
  SRC="$FX/src"
}

# An initialized repo dir whose config.json stamps a given lcarsVersion (empty ⇒
# unstamped). Echoes the repo path.
mk_initrepo() {
  local stamp="$1" d
  d="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  mkdir -p "$d/.git/lcars"
  if [ -n "$stamp" ]; then
    cat >"$d/.git/lcars/config.json" <<JSON
{
  "model": "claude-sonnet",
  "projectName": "p",
  "contextFile": null,
  "testCommand": null,
  "comprehensionBudget": 1200,
  "lcarsVersion": "$stamp",
  "created": "2020-01-01T00:00:00Z"
}
JSON
  else
    cat >"$d/.git/lcars/config.json" <<'JSON'
{
  "model": "claude-sonnet",
  "created": "2020-01-01T00:00:00Z"
}
JSON
  fi
  echo "$d"
}

# Common env for a check.sh run against a fixture (deterministic time + stamp).
# Usage: run_check <mode> <stdin-string> <extra env assignments...>
STAMP=""; ORDER=""; FETCHLOG=""; GITSTUB=""; GHSTUB=""; INSTALLSTUB=""; UPDATESTUB=""
setup_stubs() {
  STAMP="$FX/stamp"; ORDER="$FX/order"; FETCHLOG="$FX/fetch"
  GITSTUB="$FX/git"; GHSTUB="$FX/gh"; INSTALLSTUB="$FX/install"; UPDATESTUB="$FX/update"
  : >"$ORDER"; : >"$FETCHLOG"
  make_git_stub "$GITSTUB" "$FETCHLOG" "$ORDER"
  make_gh_stub "$GHSTUB"
  make_install_stub "$INSTALLSTUB" "$ORDER"
  make_update_stub "$UPDATESTUB" "$ORDER" "$GHSTUB"
}

# ==========================================================================
echo "version check + ask-to-update"

[ -f "$CHECK" ] || { echo "check.sh not found at $CHECK"; exit 1; }

# --- 1. SOURCE_BEHIND, "y" → pull + install + update in order -------------
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 )     # running 2026.7.1, origin ahead 2026.7.2
setup_stubs
REPO1="$(mk_initrepo "2026.7.1")"
OUT="$FX/out1.txt"
printf 'y\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$REPO1" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1
check "1. SOURCE_BEHIND prompt names the remote version + ENGAGE UPDATE" \
  "grep -q '2026.7.2 AVAILABLE' '$OUT' && grep -qi 'ENGAGE UPDATE' '$OUT'"
check "1. 'y' runs pull → install → update IN ORDER" \
  "[ \"\$(tr '\n' ' ' < '$ORDER')\" = 'pull install update ' ]"
check "1. the source clone was fast-forwarded to 2026.7.2" \
  "grep -q '2026.7.2' '$SRC/VERSION'"
check "1. the repo stamp ends CURRENT (restamped to 2026.7.2)" \
  "grep -q '\"lcarsVersion\": *\"2026.7.2\"' '$REPO1/.git/lcars/config.json'"

# --- 2. "n"/ENTER → nothing touched, verb proceeds ------------------------
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 )
setup_stubs
REPO2="$(mk_initrepo "2026.7.1")"
OUT="$FX/out2.txt"
printf '\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$REPO2" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1; rc=$?
check "2. ENTER (default No) exits 0 (verb proceeds)" "[ '$rc' -eq 0 ]"
check "2. ENTER touches NOTHING (no pull/install/update)" \
  "[ ! -s '$ORDER' ]"
check "2. ENTER leaves the source clone unchanged (still 2026.7.1)" \
  "grep -q '2026.7.1' '$SRC/VERSION'"

# --- 3. unsafe source declines with a reason, still proceeds --------------
# 3a. dirty main
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 && echo scratch >dirty.txt )
setup_stubs
OUT="$FX/out3a.txt"
printf 'y\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1; rc=$?
check "3a. dirty source main declines with a reason, exits 0" \
  "[ '$rc' -eq 0 ] && grep -qi 'dirty' '$OUT'"
check "3a. dirty source main does NOT pull" "[ ! -s '$ORDER' ]"

# 3b. main checked out on a branch elsewhere (source not on main)
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 && git checkout -q -b feature/x )
setup_stubs
OUT="$FX/out3b.txt"
printf 'y\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1; rc=$?
check "3b. source not on main declines with a reason, exits 0" \
  "[ '$rc' -eq 0 ] && grep -qi 'not main' '$OUT'"
check "3b. source not on main does NOT pull" "[ ! -s '$ORDER' ]"

# 3c. diverged (non-ff): a local commit not on origin/main
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 && echo local >local.txt \
    && git add -A && git commit -qm "local divergence" )
setup_stubs
OUT="$FX/out3c.txt"
printf 'y\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1; rc=$?
check "3c. diverged source declines with a reason, exits 0" \
  "[ '$rc' -eq 0 ] && grep -qi 'diverged' '$OUT'"
check "3c. diverged source does NOT pull" "[ ! -s '$ORDER' ]"

# --- 4. REPO_STALE only → offers/runs ONLY lcars update -------------------
# Source is CURRENT (src at the tip == remote); only the repo stamp trails.
mk_fixture "2026.7.1"
setup_stubs
REPO4="$(mk_initrepo "2026.7.0")"       # stamped 2026.7.0 < running 2026.7.1
OUT="$FX/out4.txt"
printf 'y\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$REPO4" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1
check "4. REPO_STALE-only prompt offers lcars update (not a source pull)" \
  "grep -qi 'lcars update' '$OUT' && ! grep -qi 'ENGAGE UPDATE' '$OUT'"
check "4. REPO_STALE-only runs ONLY update (no pull, no install)" \
  "[ \"\$(tr '\n' ' ' < '$ORDER')\" = 'update ' ]"
check "4. REPO_STALE-only restamps the repo current (2026.7.1)" \
  "grep -q '\"lcarsVersion\": *\"2026.7.1\"' '$REPO4/.git/lcars/config.json'"

# --- 5. DRIFT → warned, names lcars release -------------------------------
mk_fixture "2026.7.1" 1              # tip has an unversioned commit past VERSION
setup_stubs
OUT="$FX/out5.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "2026.7.1")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" warn </dev/null >"$OUT" 2>&1
check "5. DRIFT warns about unversioned changes" \
  "grep -qi 'unversioned changes' '$OUT'"
check "5. DRIFT names \`lcars release\` as the repair" \
  "grep -qi 'lcars release' '$OUT'"

# --- 6. throttle + kill switch --------------------------------------------
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 )
setup_stubs
CWD6="$(mk_initrepo "2026.7.1")"
# first call fetches (stamp absent) …
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$CWD6" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 LCARS_VERSION_TTL=86400 \
  bash "$CHECK" warn </dev/null >/dev/null 2>&1
# … second call within the window must NOT fetch again.
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$CWD6" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1500 LCARS_VERSION_TTL=86400 \
  bash "$CHECK" warn </dev/null >/dev/null 2>&1
check "6. throttle: exactly ONE fetch across two in-window calls" \
  "[ \"\$(wc -l < '$FETCHLOG' | tr -d ' ')\" = '1' ]"
# kill switch: zero git calls at all.
: >"$FETCHLOG"
KOUT="$FX/out6k.txt"
LCARS_VERSION_CHECK=0 LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" \
  LCARS_VERSION_CWD="$CWD6" LCARS_VERSION_STAMP="$FX/stamp-k" LCARS_NOW_EPOCH=9999 \
  bash "$CHECK" warn </dev/null >"$KOUT" 2>&1
check "6. kill switch (LCARS_VERSION_CHECK=0): zero git fetches" \
  "[ ! -s '$FETCHLOG' ]"
check "6. kill switch produces NO output" "[ ! -s '$KOUT' ]"

# --- 7. run.sh drive warns (headless) — no prompt, no stdin read ----------
# A minimal mission parked at awaiting-human halts the drive IMMEDIATELY (before
# any worker spawn). We point LCARS_VERSION_CHECK_BIN at a recording stub so the
# drive stays token-free + network-free; the stub proves cmd_drive calls it in
# `warn` mode with stdin closed, and its line surfaces in the drive output.
DRV="$(mktemp -d "$TMPROOT/drive.XXXX")"
( cd "$DRV" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )
MID="lcars-20260705-001"
MDIR="$DRV/.git/lcars/missions/$MID"; mkdir -p "$MDIR"
cat >"$MDIR/state.json" <<JSON
{
  "id": "$MID",
  "type": "feature",
  "title": "t",
  "stage": "research",
  "awaitingHuman": true,
  "pendingQuestion": "waiting",
  "created": "2026-07-05T00:00:00Z",
  "githubIssue": null,
  "branch": "lcars/$MID",
  "base": "main"
}
JSON
VCSTUB="$DRV/vcheck"; VCARGV="$DRV/vc.argv"; VCSTDIN="$DRV/vc.stdin"
cat >"$VCSTUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$VCARGV"
# record whether ANY stdin was available (walk-away ⇒ none)
if IFS= read -r -t 0 _ 2>/dev/null; then echo yes > "$VCSTDIN"; else echo no > "$VCSTDIN"; fi
echo "VCHECK-WARN-LINE"
EOF
chmod +x "$VCSTUB"
GHSTUB2="$DRV/gh"; make_gh_stub "$GHSTUB2"
NOTIFY2="$DRV/notify"; printf '#!/usr/bin/env bash\nexit 0\n' >"$NOTIFY2"; chmod +x "$NOTIFY2"
OUT="$DRV/drive.out"
( cd "$DRV" && LCARS_VERSION_CHECK_BIN="$VCSTUB" LCARS_GH_BIN="$GHSTUB2" \
    LCARS_NOTIFY="$NOTIFY2" LCARS_WORKER_BIN="" \
    bash "$RUN" drive --mission "$MID" >"$OUT" 2>&1 )
check "7. drive invokes the version check in WARN mode" \
  "[ \"\$(cat '$VCARGV' 2>/dev/null)\" = 'warn' ]"
check "7. drive gives the version check NO stdin (walk-away)" \
  "grep -q 'no' '$VCSTDIN'"
check "7. the warn line surfaces in the drive output" \
  "grep -q 'VCHECK-WARN-LINE' '$OUT'"
check "7. the drive still HALTS at awaiting-human (proceeds past the check)" \
  "grep -qi 'awaiting' '$OUT'"

# --- 8. PART 0 amendment: unstamped-but-initialized ⇒ needs update ----------
# An LCARS-initialized repo whose config.json has NO lcarsVersion key predates
# versioning ⇒ it DEFINITELY needs `lcars update`. A malformed stamp stays
# unknown (no nag); an uninitialized cwd stays silent. Source is CURRENT here
# (remote == running == 2026.7.1) so REPO_STALE is the only verdict in play.
echo "-- part 0: unstamped-but-initialized ⇒ needs update"

# 8a. unstamped + initialized → warn nags a CLEAN predates message.
mk_fixture "2026.7.1"
setup_stubs
OUT="$FX/out8a.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" warn </dev/null >"$OUT" 2>&1
check "8a. unstamped+initialized → warns it predates versioning + names lcars update" \
  "grep -qi 'predates' '$OUT' && grep -qi 'lcars update' '$OUT'"
check "8a. the predates message is CLEAN (never 'stamp () is behind')" \
  "! grep -qi 'stamp ()' '$OUT' && ! grep -qi 'stamp  is behind' '$OUT'"

# 8b. malformed stamp → stays UNKNOWN: NOT stale, NO update nag.
mk_fixture "2026.7.1"
setup_stubs
OUT="$FX/out8b.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "not-a-version")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" warn </dev/null >"$OUT" 2>&1
check "8b. malformed stamp → NOT flagged stale (no lcars update nag)" \
  "! grep -qi 'lcars update' '$OUT'"

# 8c. uninitialized cwd (no .git/lcars) → silent (no false predates nag).
mk_fixture "2026.7.1"
setup_stubs
PLAIN="$(mktemp -d "$TMPROOT/plain.XXXX")"
( cd "$PLAIN" && git init -q && git config user.email t@t && git config user.name t )
OUT="$FX/out8c.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$PLAIN" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" warn </dev/null >"$OUT" 2>&1
check "8c. uninitialized cwd → no predates / update nag" \
  "! grep -qi 'predates' '$OUT' && ! grep -qi 'lcars update' '$OUT'"

# 8d. ASK mode on an unstamped repo → prompt says PREDATES, 'y' runs lcars update.
mk_fixture "2026.7.1"
setup_stubs
OUT="$FX/out8d.txt"
printf 'y\n' | LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" ask >"$OUT" 2>&1
check "8d. ask-mode unstamped prompt says PREDATES (not 'STAMP  BEHIND')" \
  "grep -qi 'PREDATES' '$OUT'"
check "8d. ask-mode unstamped 'y' runs ONLY lcars update (no pull/install)" \
  "[ \"\$(tr '\n' ' ' < '$ORDER')\" = 'update ' ]"

# --- 9. REPORT + UPDATE modes (the viewscreen daemon's machine surface) -----
echo "-- report + update modes"

# 9a. SOURCE_BEHIND fixture → report emits running/remote + verdict=source_behind.
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 )     # running 2026.7.1, origin 2026.7.2
setup_stubs
OUT="$FX/out9a.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "2026.7.1")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" report </dev/null >"$OUT" 2>&1
check "9a. report emits running=2026.7.1" "grep -qx 'running=2026.7.1' '$OUT'"
check "9a. report emits remote=2026.7.2"  "grep -qx 'remote=2026.7.2' '$OUT'"
check "9a. report emits verdict=source_behind" "grep -qx 'verdict=source_behind' '$OUT'"
check "9a. report is machine-only (no human ⚠ prose)" "! grep -q '⚠' '$OUT'"

# 9b. CURRENT → report emits running but NO verdict lines (banner stays absent).
mk_fixture "2026.7.1"
setup_stubs
OUT="$FX/out9b.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "2026.7.1")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" report </dev/null >"$OUT" 2>&1
check "9b. current → report has NO verdict line" "! grep -q '^verdict=' '$OUT'"
check "9b. current → report still emits running" "grep -qx 'running=2026.7.1' '$OUT'"

# 9c. predates → report emits verdict=repo_predates (distinct from repo_stale).
mk_fixture "2026.7.1"
setup_stubs
OUT="$FX/out9c.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" report </dev/null >"$OUT" 2>&1
check "9c. predates → report emits verdict=repo_predates" "grep -qx 'verdict=repo_predates' '$OUT'"
check "9c. predates → report does NOT emit verdict=repo_stale" "! grep -qx 'verdict=repo_stale' '$OUT'"

# 9d. valid-behind stamp → report emits verdict=repo_stale.
mk_fixture "2026.7.1"
setup_stubs
OUT="$FX/out9d.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$(mk_initrepo "2026.7.0")" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  bash "$CHECK" report </dev/null >"$OUT" 2>&1
check "9d. valid-behind → report emits verdict=repo_stale" "grep -qx 'verdict=repo_stale' '$OUT'"

# 9e. UPDATE mode on a SOURCE_BEHIND fixture → runs pull→install→update, no prompt.
mk_fixture "2026.7.2"
( cd "$SRC" && git reset -q --hard HEAD~1 )
setup_stubs
REPO9="$(mk_initrepo "2026.7.1")"
OUT="$FX/out9e.txt"
LCARS_REPO="$SRC" LCARS_GIT_BIN="$GITSTUB" LCARS_GH_BIN="$GHSTUB" \
  LCARS_VERSION_CWD="$REPO9" LCARS_VERSION_STAMP="$STAMP" LCARS_NOW_EPOCH=1000 \
  LCARS_INSTALL_BIN="$INSTALLSTUB" LCARS_UPDATE_BIN="$UPDATESTUB" \
  bash "$CHECK" update </dev/null >"$OUT" 2>&1; rc=$?
check "9e. update mode runs pull → install → update WITHOUT a prompt" \
  "[ '$rc' -eq 0 ] && [ \"\$(tr '\n' ' ' < '$ORDER')\" = 'pull install update ' ]"
check "9e. update mode never printed a [y/N] prompt" "! grep -qi 'y/N' '$OUT'"
check "9e. update mode restamped the repo current (2026.7.2)" \
  "grep -q '\"lcarsVersion\": *\"2026.7.2\"' '$REPO9/.git/lcars/config.json'"

# ============================================================================
# 10. `lcars release` — the DRIFT-repair (Part 3). Fixture: a plain source repo
# on main with VERSION committed + N unversioned drift commits. The ONE
# summarization worker goes through worker-adapter.sh with a RECORDING STUB —
# stub-argv asserted on BOTH engines, ZERO tokens.
# ============================================================================
echo "-- lcars release (drift repair)"

RELEASE="$REPO_ROOT/skills/lcars-version/release.sh"
[ -f "$RELEASE" ] || { echo "release.sh not found at $RELEASE"; exit 1; }

# A source-repo fixture on main: genesis commit (touches VERSION+CHANGELOG),
# then `drift` extra commits that do NOT touch VERSION. Sets RREPO.
mk_release_fixture() {
  local drift="${1:-0}" i
  RREPO="$(mktemp -d "$TMPROOT/rel.XXXX")"
  git -c init.defaultBranch=main init -q "$RREPO"
  (
    cd "$RREPO"
    git config user.email t@t; git config user.name t
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    printf '2026.7.1\n' > VERSION
    printf '# Changelog\n\nAll notable changes, newest first.\n\n## 2026.7.1 — 2020-01-01\n\nGenesis.\n' > CHANGELOG.md
    git add -A && git commit -qm "genesis 2026.7.1"
    git branch -M main 2>/dev/null || true
    i=1
    while [ "$i" -le "$drift" ]; do
      printf 'change %s\n' "$i" >> feature.txt
      git add -A && git commit -qm "feat: unversioned change $i"
      i=$((i + 1))
    done
  )
}

# A recording worker stub named for its engine (basename = cli id). It records
# argv (one per line) to $2, appends a call marker to $2.calls, and writes the
# changelog entry to $LCARS_WORK_OUT/changelog-entry.md (the adapter sets that env).
make_release_worker() { # path argvlog
  cat >"$1" <<EOF
#!/usr/bin/env bash
: >"$2"
for a in "\$@"; do printf '%s\n' "\$a" >>"$2"; done
printf 'call\n' >>"$2.calls"
printf 'Summarized: rolled up the unversioned changes on main.\n' \
  > "\${LCARS_WORK_OUT:-.}/changelog-entry.md"
exit 0
EOF
  chmod +x "$1"
}

# 10a+10b. On BOTH engines: drift fixture → worker argv recorded (exactly once),
# changelog prepended, VERSION incremented, a release commit made.
for eng in claude copilot; do
  mk_release_fixture 2
  W="$TMPROOT/worker-$eng"; make_release_worker "$W" "$TMPROOT/argv-$eng"
  : >"$TMPROOT/argv-$eng.calls"
  head0="$(git -C "$RREPO" rev-parse HEAD)"
  ln -sf "$W" "$TMPROOT/$eng"   # basename must be the engine id for the adapter
  OUT="$TMPROOT/rel-$eng.out"
  LCARS_REPO="$RREPO" LCARS_GIT_BIN="git" LCARS_WORKER_BIN="$TMPROOT/$eng" \
    LCARS_NOW_YEAR=2026 LCARS_NOW_MONTH=7 LCARS_NOW_DATE=2026-07-09 \
    bash "$RELEASE" >"$OUT" 2>&1; rc=$?
  check "10.$eng release exits 0 on a drift fixture" "[ '$rc' -eq 0 ]"
  check "10.$eng worker invoked EXACTLY once (one stub-argv call)" \
    "[ \"\$(wc -l < '$TMPROOT/argv-$eng.calls' | tr -d ' ')\" = '1' ]"
  check "10.$eng worker argv recorded (adapter spawned it with -p <prompt>)" \
    "grep -qx -- '-p' '$TMPROOT/argv-$eng'"
  check "10.$eng VERSION incremented to 2026.7.2" \
    "[ \"\$(cat '$RREPO/VERSION')\" = '2026.7.2' ]"
  check "10.$eng CHANGELOG prepended (new 2026.7.2 section above the old 2026.7.1)" \
    "[ \"\$(grep -n '## 2026.7.2' '$RREPO/CHANGELOG.md' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n '## 2026.7.1' '$RREPO/CHANGELOG.md' | head -1 | cut -d: -f1)\" ]"
  check "10.$eng CHANGELOG carries the worker's summarized entry" \
    "grep -qi 'Summarized: rolled up' '$RREPO/CHANGELOG.md'"
  check "10.$eng a NEW release commit was made" \
    "[ \"\$(git -C '$RREPO' rev-parse HEAD)\" != '$head0' ] && git -C '$RREPO' log -1 --format='%s' | grep -qi 'release.*2026.7.2'"
  check "10.$eng CHANGELOG preamble stays on top (## is not line 1)" \
    "[ \"\$(grep -n '^## ' '$RREPO/CHANGELOG.md' | head -1 | cut -d: -f1)\" -gt 1 ]"
done

# 10c. month-roll: running 2026.7.1 with now = 2026-08 → 2026.8.1 (N resets).
mk_release_fixture 1
W="$TMPROOT/worker-roll"; make_release_worker "$W" "$TMPROOT/argv-roll"
ln -sf "$W" "$TMPROOT/claude-roll"
LCARS_REPO="$RREPO" LCARS_GIT_BIN="git" LCARS_WORKER_BIN="$TMPROOT/claude-roll" \
  LCARS_WORKER_CLI=claude LCARS_NOW_YEAR=2026 LCARS_NOW_MONTH=8 LCARS_NOW_DATE=2026-08-01 \
  bash "$RELEASE" >/dev/null 2>&1
check "10c. month-roll bumps to 2026.8.1 (N resets on a new month)" \
  "[ \"\$(cat '$RREPO/VERSION')\" = '2026.8.1' ]"

# 10d. clean-main required: a DIRTY source main → refuse, no commit, no worker.
mk_release_fixture 2
W="$TMPROOT/worker-dirty"; make_release_worker "$W" "$TMPROOT/argv-dirty"
: >"$TMPROOT/argv-dirty.calls"
ln -sf "$W" "$TMPROOT/claude-dirty"
( cd "$RREPO" && echo scratch > dirty.txt )      # make the tree dirty
head_d="$(git -C "$RREPO" rev-parse HEAD)"
LCARS_REPO="$RREPO" LCARS_GIT_BIN="git" LCARS_WORKER_BIN="$TMPROOT/claude-dirty" \
  LCARS_WORKER_CLI=claude LCARS_NOW_YEAR=2026 LCARS_NOW_MONTH=7 \
  bash "$RELEASE" >"$TMPROOT/rel-dirty.out" 2>&1; rc=$?
check "10d. dirty main → refuses (non-zero) with a reason" \
  "[ '$rc' -ne 0 ] && grep -qi 'dirty' '$TMPROOT/rel-dirty.out'"
check "10d. dirty main → no release commit made" \
  "[ \"\$(git -C '$RREPO' rev-parse HEAD)\" = '$head_d' ]"
check "10d. dirty main → VERSION unchanged (2026.7.1)" \
  "[ \"\$(cat '$RREPO/VERSION')\" = '2026.7.1' ]"
check "10d. dirty main → NO worker spawned" \
  "[ ! -s '$TMPROOT/argv-dirty.calls' ]"

# 10e. not on main → refuse, no-op.
mk_release_fixture 2
( cd "$RREPO" && git checkout -q -b feature/x )
head_b="$(git -C "$RREPO" rev-parse HEAD)"
LCARS_REPO="$RREPO" LCARS_GIT_BIN="git" LCARS_WORKER_BIN="claude" \
  bash "$RELEASE" >"$TMPROOT/rel-branch.out" 2>&1; rc=$?
check "10e. not-on-main → refuses (non-zero) naming main" \
  "[ '$rc' -ne 0 ] && grep -qi 'not main' '$TMPROOT/rel-branch.out'"
check "10e. not-on-main → VERSION unchanged" \
  "[ \"\$(cat '$RREPO/VERSION')\" = '2026.7.1' ]"

# 10f. NO drift → clean no-op: 'nothing to release', no worker, no commit.
mk_release_fixture 0
W="$TMPROOT/worker-none"; make_release_worker "$W" "$TMPROOT/argv-none"
: >"$TMPROOT/argv-none.calls"
ln -sf "$W" "$TMPROOT/claude-none"
head_n="$(git -C "$RREPO" rev-parse HEAD)"
LCARS_REPO="$RREPO" LCARS_GIT_BIN="git" LCARS_WORKER_BIN="$TMPROOT/claude-none" \
  LCARS_WORKER_CLI=claude LCARS_NOW_YEAR=2026 LCARS_NOW_MONTH=7 \
  bash "$RELEASE" >"$TMPROOT/rel-none.out" 2>&1; rc=$?
check "10f. no-drift → exits 0 with 'nothing to release'" \
  "[ '$rc' -eq 0 ] && grep -qi 'nothing to release' '$TMPROOT/rel-none.out'"
check "10f. no-drift → NO worker spawned" \
  "[ ! -s '$TMPROOT/argv-none.calls' ]"
check "10f. no-drift → no commit, VERSION unchanged" \
  "[ \"\$(git -C '$RREPO' rev-parse HEAD)\" = '$head_n' ] && [ \"\$(cat '$RREPO/VERSION')\" = '2026.7.1' ]"

# ==========================================================================
echo
printf 'version check: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
