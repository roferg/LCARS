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

# ==========================================================================
echo
printf 'version check: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
