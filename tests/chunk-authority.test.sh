#!/usr/bin/env bash
#
# tests/chunk-authority.test.sh — S365: A SUB-ECH OWNS ITS CHUNK, AND ITS OWN
# BUGS STOP GATING THE PARENT.
#
# (skill source: skills/lcars-eeh/ech.sh § subech_* / cmd_file_bug / cmd_ask /
#                cmd_land, skills/lcars-eeh/chunk-owners.sh,
#                skills/lcars-approve/approve.sh § open_logged_children,
#                skills/lcars-eeh/DELEGATION.md § AUTHORITY TRAVELS WITH THE
#                CHUNK, skills/lcars-eeh/delegate-brief.md § 5)
#
# WHAT THE CAPTAIN RULED, 2026-11-20. Delegation was built as ONE level with all
# authority kept at the top: a delegate's hand-back is a REPORT, and `file-bug`,
# `ask` and `land` are reserved to the ECH. What he actually hand-prompts is a
# tree where AUTHORITY TRAVELS WITH THE CHUNK — a sub-ECH owns a chunk, hands it
# to the factory, makes sure it lands, VALIDATES it, FILES ITS OWN BUGS and
# DRIVES ITS OWN FIXES. The main ECH owns the overall ask and verifies the WHOLE.
#
# IT IS A RE-READING, NOT A REVERSAL. The rule it replaces cites the evidence
# that an automated reviewer filed 0 of 31 bugs while the ECH's own live check
# found all 31. That says A ROBOT REVIEWER'S VERDICT IS NO SUBSTITUTE FOR A REAL
# LOOK — not "only one ECH may ever look". A sub-ECH IS an ECH doing its own real
# look, so `HOLOGRAM-COMMAND-MODE.md` § 6's standing job is UNCHANGED; what
# changes is WHICH ECH owns WHICH scope.
#
# AND THE MEASURED HALF. On the 2026-11-18 capstone the supervisor filed four
# bugs through the front door exactly as briefed, and the parent then could not
# be accepted until all four reached their own Verify — `resolve-logs` orders
# them but does not drive them, so clearing it meant four full pipelines. ON THAT
# BUILD, AN ECH THAT FILES BUGS AGAINST A LIVE MISSION HAS ENDED THAT MISSION'S
# RUN. The gate is right to exist (nothing should silently drop a logged bug) and
# its TIMING is wrong: a bug a sub-ECH owns and is driving must not block the
# parent; an UNOWNED, UNDRIVEN one still must, named by id.
#
# THE CONTROL THAT MATTERS IS § 6, NOT § 5. A false accept — shipping a parent
# whose genuinely unresolved, unowned bug nobody is driving — is worse than the
# blocking this session cures. So § 6 attacks it from four directions: an
# unowned bug, a bug whose owner has been CLOSED OUT, a bug whose record claims
# an owner NO DELEGATE RECORD BACKS, and a mixed parent where one bug is driven
# and one is not.
#
# PROOF SURFACE. *Real:* real git repos, real Mission + child bug Mission
# records, a real minted sub-ECH record and brief, the real `lcars-ech` verbs,
# and THE REAL ACCEPT PATH — `skills/lcars-approve/approve.sh` itself, through
# its own pre-merge gate. *Faked:* the forge (gh / host adapter), the reconcile
# engine, `lcars log` (a stub that files a real linked child record the way
# log.sh does), and the AI CLIs (pinned to zero spend by the PATH shim).
# *Blind to:* whether a sub-ECH uses the authority WELL — only a live run shows
# that.
#
# THE KNOWN-GOOD CONTROL (§ 8) IS A REAL BEFORE/AFTER. It runs the BASELINE
# ech.sh — extracted from $LCARS_BASELINE_REF, the branch tip before this
# session — beside the current one on a repo with no sub-ECHs, and diffs
# `stalled`, `next` and `status` byte for byte. A missing baseline ref is a
# FAILURE here, never a skip: a control that quietly does not run is a green
# that proves nothing.
#
# Usage: bash tests/chunk-authority.test.sh
#    or: python3 tests/lib/cage.py 300 bash tests/chunk-authority.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"
APPROVE="${LCARS_APPROVE_SCRIPT:-$REPO_ROOT/skills/lcars-approve/approve.sh}"
CHUNK_LIB="$REPO_ROOT/skills/lcars-eeh/chunk-owners.sh"
DOC="$REPO_ROOT/skills/lcars-eeh/DELEGATION.md"
HCM="$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"
# THE BASELINE FOR § 8's BYTE-FOR-BYTE CONTROL: 20ae817 is this branch's tip
# before S365 (S364's narrowing-proof commit). Override it only to re-point the
# control at a different "before".
BASELINE_REF="${LCARS_BASELINE_REF:-20ae817}"

pass=0
fail=0
if [ -n "${LCARS_TEST_TMP_ROOT:-}" ]; then
  TMPROOT="$(mktemp -d "$LCARS_TEST_TMP_ROOT/chunkauth.XXXXXX")"
else
  TMPROOT="$(mktemp -d)"
fi

teardown() {
  local f p
  for f in "$TMPROOT"/*/.git/lcars/autopilot.json; do
    [ -f "$f" ] || continue
    for p in $(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$f"); do
      kill -9 "$p" 2>/dev/null || true
    done
  done
  rm -rf "$TMPROOT"
}
trap teardown EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- the spend fuse (tests/delegation.test.sh's, verbatim in intent) --------
SHIM_DIR="$DIR/lib/shims/deploy-watcher"
export LCARS_DRIVE_SHIM_LOG="$TMPROOT/worker-shim.log"
: >"$LCARS_DRIVE_SHIM_LOG"
PATH="$SHIM_DIR:$PATH"; export PATH
if [ ! -x "$SHIM_DIR/claude" ] || [ ! -x "$SHIM_DIR/copilot" ]; then
  printf 'SPEND FUSE TRIPPED: no counting claude/copilot at %s — REFUSING (would bill)\n' \
    "$SHIM_DIR" >&2
  exit 1
fi

# =========================================================================
# FIXTURES — the ECH side
# =========================================================================

new_repo() {
  [ -n "${TMPROOT:-}" ] && [ -d "$TMPROOT" ] \
    || { echo "FENCE: TMPROOT is missing — refusing to run git with an empty path" >&2; exit 97; }
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXXXX")" \
    || { echo "FENCE: mktemp failed under $TMPROOT — refusing" >&2; exit 97; }
  [ -n "$repo" ] && [ -d "$repo" ] \
    || { echo "FENCE: empty repo path from mktemp — refusing" >&2; exit 97; }
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@example.com
  git -C "$repo" config user.name  Tester
  echo seed >"$repo/README.md"
  git -C "$repo" add -A
  git -C "$repo" commit -qm seed
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'JSON'
{ "testCommand": "true", "engine": "copilot" }
JSON
  echo "$repo"
}

# new_mission <repo> <id> <stage> [type] [parentMission]
new_mission() {
  local repo="$1" id="$2" stage="$3" type="${4:-feature}" parent="${5:-}"
  local d="$repo/.git/lcars/missions/$id"
  mkdir -p "$d"
  if [ -n "$parent" ]; then
    cat >"$d/state.json" <<JSON
{
  "id": "$id",
  "stage": "$stage",
  "type": "$type",
  "title": "mission $id",
  "branch": "lcars/$parent",
  "parentMission": "$parent",
  "parentIssue": "1",
  "issue": "1"
}
JSON
  else
    cat >"$d/state.json" <<JSON
{
  "id": "$id",
  "stage": "$stage",
  "type": "$type",
  "title": "mission $id",
  "branch": "lcars/$id",
  "issue": "1"
}
JSON
  fi
  git -C "$repo" branch -q "lcars/$id" main 2>/dev/null || true
}

ap_init() {
  local repo="$1" scope="${2:-M0}"
  cat >"$repo/.git/lcars/autopilot.json" <<JSON
{
  "spec": "spec.md",
  "engine": "copilot",
  "scope": ["$scope"],
  "missions": {},
  "questions": {},
  "pending": {}
}
JSON
}

stub() {
  local path="$1" rc="$2" body="${3:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$0 $*" >> "$STUB_LOG"\n'
    [ -n "$body" ] && printf '%s\n' "$body"
    printf 'exit %s\n' "$rc"
  } >"$path"
  chmod +x "$path"
}

STUBS="$TMPROOT/stubs"
STUB_LOG="$TMPROOT/stub.log"
: >"$STUB_LOG"
mkdir -p "$STUBS"
for s in run.sh approve.sh xo.sh respond.sh file.sh resolve-logs.sh notify.sh crontab gh; do
  stub "$STUBS/$s" 0
done

# A `lcars log` stub that files for REAL the way log.sh does — a bug Mission
# linked to its parent — because file-bug VERIFIES the linkage it claims.
# (Lifted from tests/lcars-ech.test.sh § S234.3.)
LOGFILES='parent=""; prds=""
while [ $# -gt 0 ]; do
  case "$1" in --parent) parent="$2"; shift ;; --prd) prds="$prds $2"; shift ;; esac
  shift
done
n=0
for p in $prds; do
  n=$((n+1))
  while [ -d "$LCARS_ECH_CWD/.git/lcars/missions/bug-00$n" ]; do n=$((n+1)); done
  d="$LCARS_ECH_CWD/.git/lcars/missions/bug-00$n"
  mkdir -p "$d"
  cp "$p" "$d/prd.md"
  cat >"$d/state.json" <<JSON
{"id":"bug-00$n","stage":"align","type":"bug","title":"a filed bug",
 "branch":"lcars/$parent","parentMission":"$parent","parentIssue":"1",
 "labels":["lcars:align","lcars:bug","lcars:linked","lcars:mission"]}
JSON
done'
stub "$STUBS/log-files.sh" 0 "$LOGFILES"

# A `lcars-file/file.sh` stand-in that creates a REAL Mission the way file.sh
# does — a directory with a `state.json` under `.git/lcars/missions/`. `exec`
# attributes a Mission by DIFFING that directory, so the fixture has to make a
# real one; a stub that only exits 0 would prove nothing.
FILEMAKES='id=""
while [ $# -gt 0 ]; do
  case "$1" in --id) id="$2"; shift ;; esac
  shift
done
[ -n "$id" ] || id="filed-$$"
d="$LCARS_ECH_CWD/.git/lcars/missions/$id"
mkdir -p "$d"
cat >"$d/state.json" <<JSON
{"id":"$id","stage":"verify","type":"feature","title":"mission $id",
 "branch":"lcars/$id","issue":"1"}
JSON
# AND ITS BRANCH, which the real file.sh cuts too — `live-check` prepares a
# worktree from it, so a Mission record with no branch fails for a reason that
# has nothing to do with authority (measured: "git worktree add --detach
# failed for lcars/<id>").
git -C "$LCARS_ECH_CWD" branch -q "lcars/$id" main 2>/dev/null || true'
stub "$STUBS/file-makes.sh" 0 "$FILEMAKES"
# AND IT HAS TO LIVE WHERE `exec` RESOLVES SCRIPTS: $SKILLS_DIR/<skill>/<script>,
# which `exec` refuses to escape (no `..`, no absolute path). So the fixture
# plants a whole fake skills tree and points the launcher at it — the real
# resolution rule exercised, not bypassed.
# It mirrors the lcars-eeh dir OF THE SCRIPT UNDER TEST, so the same fixture
# measures the baseline and the cure without a second code path.
EXEC_SKILLS="$TMPROOT/exec-skills"
mkdir -p "$EXEC_SKILLS/lcars-file" "$EXEC_SKILLS/lcars-eeh"
cp -R "$(dirname "$SCRIPT")"/. "$EXEC_SKILLS/lcars-eeh/"
cp "$STUBS/file-makes.sh" "$EXEC_SKILLS/lcars-file/file.sh"
# A `lcars-log/log.sh` creator too (F2 files UNDER a parent through it), and a
# `lcars-run/run.sh` stand-in that is NOT a Mission creator but DOES see one
# appear while it runs — F3's measured defect in miniature.
mkdir -p "$EXEC_SKILLS/lcars-log"
LOGMAKES='parent=""; id=""
while [ $# -gt 0 ]; do
  case "$1" in --parent) parent="$2"; shift ;; --id) id="$2"; shift ;; esac
  shift
done
[ -n "$id" ] || id="xbug-$$"
d="$LCARS_ECH_CWD/.git/lcars/missions/$id"
mkdir -p "$d"
cat >"$d/state.json" <<JSON
{"id":"$id","stage":"align","type":"bug","title":"a filed bug",
 "branch":"lcars/$parent","parentMission":"$parent","parentIssue":"1"}
JSON'
stub "$STUBS/log-makes.sh" 0 "$LOGMAKES"
cp "$STUBS/log-makes.sh" "$EXEC_SKILLS/lcars-log/log.sh"
RUNMAKES='# NOT a Mission creator. It stands in for the documented long-running
# use (`exec lcars-run/run.sh drive`) and creates a Mission the way ANOTHER
# TERMINAL would during the call — the exact shape F3 was measured on.
d="$LCARS_ECH_CWD/.git/lcars/missions/m-elsewhere"
mkdir -p "$d"
cat >"$d/state.json" <<JSON
{"id":"m-elsewhere","stage":"verify","type":"feature","title":"the captains own",
 "branch":"lcars/m-elsewhere","issue":"1"}
JSON'
mkdir -p "$EXEC_SKILLS/lcars-run"
stub "$STUBS/run-makes.sh" 0 "$RUNMAKES"
cp "$STUBS/run-makes.sh" "$EXEC_SKILLS/lcars-run/run.sh"
# S365 fix round 3. THE SCRIPTS THE TESTER REACHED, each one an ACT rather than
# a name. The approve stand-in MERGES for real in fixture terms: it records a
# pr-merge and sets the Mission's stage to done, which is exactly what the
# measured bypass did. If the allow-list leaks, these leave evidence.
for sk3 in lcars-approve lcars-answer lcars-feedback lcars-init lcars-xo lcars-respond lcars-resolve-logs; do
  mkdir -p "$EXEC_SKILLS/$sk3"
done
APPROVEMERGES='mission=""
while [ $# -gt 0 ]; do
  case "$1" in --mission) mission="$2"; shift ;; esac
  shift
done
printf "pr-merge %s\n" "$mission" >>"$LCARS_ECH_CWD/merged.log"
d="$LCARS_ECH_CWD/.git/lcars/missions/$mission"
[ -d "$d" ] && printf "{\"id\":\"%s\",\"stage\":\"done\",\"type\":\"feature\",\"title\":\"t\"}\n" "$mission" >"$d/state.json"'
stub "$STUBS/approve-merges.sh" 0 "$APPROVEMERGES"
cp "$STUBS/approve-merges.sh" "$EXEC_SKILLS/lcars-approve/approve.sh"
RAN3='printf "RAN %s\n" "$0" >>"$LCARS_ECH_CWD/ran.log"'
for pair3 in lcars-answer/answer.sh lcars-feedback/feedback.sh lcars-init/init.sh \
             lcars-xo/xo.sh lcars-respond/respond.sh lcars-resolve-logs/resolve-logs.sh; do
  stub "$STUBS/ran3.sh" 0 "$RAN3"
  cp "$STUBS/ran3.sh" "$EXEC_SKILLS/$pair3"
done
# A run.sh that REPORTS THE SEAT IT INHERITED, so the env-inheritance property
# is measured rather than assumed. It is the same script `exec` resolves for
# `lcars-run/run.sh`, so one of the two has to win: this one is used only by the
# inheritance rows, through its own copy.
mkdir -p "$EXEC_SKILLS/lcars-run"
SEATECHO='printf "SEAT=%s\n" "${LCARS_ECH_AS:-NONE}" >"$LCARS_ECH_CWD/seat.txt"'
stub "$STUBS/seat-echo.sh" 0 "$SEATECHO"
# `live-check` resolves its checklists at $SKILLS_DIR/lcars-run/live-check/, so
# a tree without them refuses for a reason that has nothing to do with
# authority — the first run of this section failed three rows on exactly that.
mkdir -p "$EXEC_SKILLS/lcars-run"
cp -R "$(dirname "$SCRIPT")/../lcars-run/live-check" "$EXEC_SKILLS/lcars-run/" 2>/dev/null || true
EXEC_SCRIPT="$EXEC_SKILLS/lcars-eeh/$(basename "$SCRIPT")"

# ech_at <script> <repo> <args…> — every external dependency env-injected.
ech_at() {
  local script="$1" repo="$2"; shift 2
  mkdir -p "$TMPROOT/tmp"
  TMPDIR="$TMPROOT/tmp" \
  LCARS_ECH_CWD="$repo" \
  STUB_LOG="$STUB_LOG" \
  LCARS_RUN_SCRIPT="$STUBS/run.sh" \
  LCARS_APPROVE_SCRIPT="$STUBS/approve.sh" \
  LCARS_XO_SCRIPT="$STUBS/xo.sh" \
  LCARS_RESPOND_SCRIPT="$STUBS/respond.sh" \
  LCARS_LOG_SCRIPT="$STUBS/log-files.sh" \
  LCARS_FILE_SCRIPT="$STUBS/file.sh" \
  LCARS_RESOLVE_LOGS_SCRIPT="$STUBS/resolve-logs.sh" \
  LCARS_NOTIFY="$STUBS/notify.sh" \
  LCARS_CRONTAB_BIN="$STUBS/crontab" \
  LCARS_GH_BIN="$STUBS/gh" \
  bash "$script" "$@" </dev/null
}
ech() { local repo="$1"; shift; ech_at "$SCRIPT" "$repo" "$@"; }
# `exec` resolves scripts under the LAUNCHER's own skills dir, so running the
# launcher FROM the fake tree is what points it at the fixture's file.sh. The
# launcher is a copy of the real ech.sh, so the code under test is unchanged.
xech() {              # xech <seat|-> <repo> <args…>  — through the fake tree
  local seat="$1" repo="$2"; shift 2
  if [ "$seat" = "-" ]; then
    ech_at "$EXEC_SCRIPT" "$repo" "$@"
  else
    LCARS_ECH_AS="$seat" ech_at "$EXEC_SCRIPT" "$repo" "$@"
  fi
}
# The same, but AS a sub-ECH seat.
ech_as() {
  local seat="$1" repo="$2"; shift 2
  LCARS_ECH_AS="$seat" ech_at "$SCRIPT" "$repo" "$@"
}

# A valid evidence-first bug PRD (file-bug's own gate must pass before any
# authority question can be the thing under test).
PRD_GOOD="$TMPROOT/bug-good.md"
cat >"$PRD_GOOD" <<'MD'
# Mission: every rendered row shows the default host, never the stored one

**Type:** bug
**Seam:** relay.py cmd_file (writes the record) -> pkg/model.py host_of (reads it)
**Goal:** The host the CLI stores is the host the page renders, for every record.
**Acceptance Criteria:**
- Observed live: `RELAY_HOST=github.example.com python3 relay.py file "sandwich"` stored `"origin": "github.example.com"` in `requests/r-1759300000000.json`; `python3 -m pkg.render` then rendered `<td class="host">github.com</td>`.
- ONE shared field name, declared in `pkg/model.py` and used by both halves.
- Round-trip test with NO hand-written fixture: the test files a record with the CLI's own `cmd_file`, renders it with the real `render()`, and asserts the rendered host is the one that was configured.
**Out of Scope:**
- The hardcoded `api.github.com` in `cmd_publish` (filed separately).
**Constraints:**
- Stdlib only; no network in tests.
MD

# A repo with TWO units, each a real Mission, and a sub-ECH minted on the first
# THROUGH THE REAL VERBS — `tier` then `delegate`, which mints the real brief.
#   mine   — unit `mine`,   mission `m-mine`,   sub-ECH d1
#   theirs — unit `theirs`, mission `m-theirs`, sub-ECH d2
# A real mint is ~11s a delegate, so it is spent where the MINT is the thing
# under test (§ 1 and § 7) and `fast_chunk_repo` is used everywhere the
# RECORD is what matters.
two_chunk_repo() {
  local r; r="$(new_repo)"
  ap_init "$r"
  new_mission "$r" m-mine   verify
  new_mission "$r" m-theirs verify
  ech "$r" record 'missions.mine.id'   m-mine   >/dev/null 2>&1
  ech "$r" record 'missions.theirs.id' m-theirs >/dev/null 2>&1
  ech "$r" tier mine   --tier T1 --why "one owner end to end" >/dev/null 2>&1
  ech "$r" tier theirs --tier T1 --why "a sibling chunk"      >/dev/null 2>&1
  ech "$r" delegate mine   >/dev/null 2>&1
  ech "$r" delegate theirs >/dev/null 2>&1
  printf '%s\n' "$r"
}

# THE SAME TWO CHUNKS, WITH THE DELEGATE RECORDS WRITTEN DIRECTLY — the same
# fields `delegate` writes (`id`, `unit`, `tier`, `status`, `mission`), which
# are the only ones any authority question reads. Nothing about a refusal, a
# gate or an accept depends on the brief file, and § 1 / § 7 prove the real
# mint writes exactly this shape.
fast_chunk_repo() {
  local r; r="$(new_repo)"
  new_mission "$r" m-mine   verify
  new_mission "$r" m-theirs verify
  cat >"$r/.git/lcars/autopilot.json" <<'JSON'
{
  "spec": "spec.md",
  "engine": "copilot",
  "scope": ["M0"],
  "missions": { "mine": { "id": "m-mine" }, "theirs": { "id": "m-theirs" } },
  "questions": {},
  "pending": {},
  "units": { "mine": { "tier": "T1" }, "theirs": { "tier": "T1" } },
  "delegates": {
    "d1": { "id": "d1", "unit": "mine",   "tier": "T1", "status": "minted",
            "mission": "m-mine" },
    "d2": { "id": "d2", "unit": "theirs", "tier": "T1", "status": "minted",
            "mission": "m-theirs" }
  }
}
JSON
  # The artifacts a real mint writes: the brief, and S365 fix round 2's SEAT
  # MARKER. An ownership claim is only honoured when BOTH are there — that two
  # `[ -f ]` test is the one adjudicator both accept gates share — so a fixture
  # without them would be testing the wrong refusal.
  mkdir -p "$r/.git/lcars/delegates/d1" "$r/.git/lcars/delegates/d2"
  echo "# BRIEF d1" >"$r/.git/lcars/delegates/d1/BRIEF.md"
  echo "# BRIEF d2" >"$r/.git/lcars/delegates/d2/BRIEF.md"
  : >"$r/.git/lcars/delegates/d1/OPEN"
  : >"$r/.git/lcars/delegates/d2/OPEN"
  printf '%s\n' "$r"
}

echo "S365 — a sub-ECH owns its chunk, and its own bugs stop gating the parent"
echo

# =========================================================================
printf '== 1. IN-CHUNK `file-bug` BY A SUB-ECH: ALLOWED, AND RECORDED WITH ITS OWNER ==\n'
# =========================================================================
R1="$(two_chunk_repo)"
check "1a. [precondition] two sub-ECHs were minted on two units" \
  "[ -f '$R1/.git/lcars/delegates/d1/BRIEF.md' ] && [ -f '$R1/.git/lcars/delegates/d2/BRIEF.md' ]"
F1="$(ech_as d1 "$R1" file-bug --parent m-mine --prd "$PRD_GOOD" 2>&1)"; f1rc=$?
check "1b. a sub-ECH may file a bug INSIDE its own chunk" "[ $f1rc -eq 0 ]"
check "1c. the child bug Mission really exists" \
  "[ -f '$R1/.git/lcars/missions/bug-001/state.json' ]"
check "1d. the filing says who owns it, by delegate id" \
  "printf '%s' \"\$F1\" | grep -q 'd1'"
check "1e. the ownership is RECORDED, not just printed" \
  "[ -f '$R1/.git/lcars/chunk-owners' ] && grep -q 'bug-001' '$R1/.git/lcars/chunk-owners' && grep -q 'd1' '$R1/.git/lcars/chunk-owners'"
check "1f. and the record is readable through the shared library" \
  "[ -f '$CHUNK_LIB' ] && [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R1/.git/lcars' bug-001)\" = d1 ]"
# A bug logged UNDER a bug is still inside the same chunk.
F1B="$(ech_as d1 "$R1" file-bug --parent bug-001 --prd "$PRD_GOOD" 2>&1)"; f1brc=$?
check "1g. a bug under its own bug Mission is still IN the chunk (it ascends)" \
  "[ $f1brc -eq 0 ]"
# THE KNOWN-FAIL CONTROL for this section: the MAIN ECH is unchanged.
F1M="$(ech "$R1" file-bug --parent m-theirs --prd "$PRD_GOOD" 2>&1)"; f1mrc=$?
check "1h. [control] the MAIN ECH still files anywhere, on any chunk" "[ $f1mrc -eq 0 ]"
check "1i. [control] …and a main-ECH filing claims no owner" \
  "! grep -q '^bug-003' '$R1/.git/lcars/chunk-owners' 2>/dev/null"
echo

# =========================================================================
printf '== 2. OUT-OF-CHUNK `file-bug`: REFUSED BY NAME, SAYING WHOSE CHUNK IT IS ==\n'
# =========================================================================
R2="$(fast_chunk_repo)"
F2="$(ech_as d1 "$R2" file-bug --parent m-theirs --prd "$PRD_GOOD" 2>&1)"; f2rc=$?
check "2a. a sub-ECH may NOT file a bug outside its chunk" "[ $f2rc -ne 0 ]"
check "2b. the refusal names the Mission it refused" \
  "printf '%s' \"\$F2\" | grep -q 'm-theirs'"
check "2c. the refusal names WHOSE chunk it is, by delegate id" \
  "printf '%s' \"\$F2\" | grep -q 'd2'"
check "2d. the refusal names the seat's OWN chunk, so the boundary is visible" \
  "printf '%s' \"\$F2\" | grep -q 'm-mine'"
check "2e. the refusal says authority travels with the chunk" \
  "printf '%s' \"\$F2\" | grep -qi 'chunk'"
check "2f. the refused filing filed NOTHING" \
  "[ ! -d '$R2/.git/lcars/missions/bug-001' ]"
check "2g. …and recorded no ownership" \
  "[ ! -f '$R2/.git/lcars/chunk-owners' ] || ! grep -q 'm-theirs' '$R2/.git/lcars/chunk-owners'"
# A Mission NO sub-ECH owns is the MAIN ECH's, and the refusal must say so
# rather than naming a delegate that does not exist.
new_mission "$R2" m-nobody verify
F2N="$(ech_as d1 "$R2" file-bug --parent m-nobody --prd "$PRD_GOOD" 2>&1)"; f2nrc=$?
check "2h. an unowned Mission is refused too" "[ $f2nrc -ne 0 ]"
check "2i. …and the refusal says it is the MAIN ECH's, naming no phantom delegate" \
  "printf '%s' \"\$F2N\" | grep -qi 'main ECH'"
# A SEAT NOBODY MINTED MAY NOT BECOME THE MAIN ECH BY TYPO. This is the hole
# that would hand full authority to any value of the variable.
F2X="$(LCARS_ECH_AS=d99 ech_at "$SCRIPT" "$R2" file-bug --parent m-mine --prd "$PRD_GOOD" 2>&1)"; f2xrc=$?
check "2j. a seat claiming a delegate id NOBODY MINTED is refused, not promoted" \
  "[ $f2xrc -ne 0 ]"
check "2k. …and the refusal names the id it could not find" \
  "printf '%s' \"\$F2X\" | grep -q 'd99'"
echo

# =========================================================================
printf '== 3. `ask` AND `land` STAY RESERVED — THE REFUSAL NAMES THE MAIN ECH ==\n'
# =========================================================================
R3="$(fast_chunk_repo)"
A3="$(ech_as d1 "$R3" ask "should this chunk ship?" --mission m-mine \
        --command "lcars-ech land m-mine" --rollback "nothing" 2>&1)"; a3rc=$?
check "3a. a sub-ECH may NOT run \`ask\`, even inside its own chunk" "[ $a3rc -ne 0 ]"
# THE REFUSAL IS NOW THE BOUNDARY'S (fix round 2, F5) — `ask` is simply not on
# the allow-list — and it still has to carry everything the per-verb refusal
# carried: who owns it, why, and the one channel back. These rows are unchanged
# on purpose: they are what stopped the boundary from being a worse message.
check "3b. the refusal names the MAIN ECH as the owner of \`ask\`" \
  "printf '%s' \"\$A3\" | grep -qi 'main ECH'"
check "3c. it says WHY — the interrupt budget is not the sub-ECH's to spend" \
  "printf '%s' \"\$A3\" | grep -qi 'interrupt budget'"
check "3d. it hands over the route it DOES have: a BLOCKED: beat" \
  "printf '%s' \"\$A3\" | grep -q 'BLOCKED'"
check "3e. the refused \`ask\` raised NO question for the captain" \
  "! grep -q 'should this ship' '$R3/.git/lcars/autopilot.json'"
check "3f. …and fired no notification" \
  "! grep -q 'notify.sh m-mine' '$STUB_LOG'"
L3="$(ech_as d1 "$R3" land m-mine 2>&1)"; l3rc=$?
check "3g. a sub-ECH may NOT run \`land\`, even inside its own chunk" "[ $l3rc -ne 0 ]"
check "3h. the refusal names the MAIN ECH as the owner of the landing decision" \
  "printf '%s' \"\$L3\" | grep -qi 'main ECH'"
check "3i. it says why — landing is ONE decision" \
  "printf '%s' \"\$L3\" | grep -qi 'one decision'"
check "3j. the refused \`land\` called approve NOT ONCE" \
  "! grep -q 'approve.sh' '$STUB_LOG'"
# THE CONTROL: the main ECH's own `ask` and `land` are untouched.
A3M="$(ech "$R3" ask "a real captain call" --mission m-mine \
        --command "echo x" --rollback "nothing" 2>&1)"; a3mrc=$?
check "3k. [control] the MAIN ECH's \`ask\` still works" "[ $a3mrc -eq 0 ]"
check "3l. [control] …and really raised the question" \
  "grep -q 'a real captain call' '$R3/.git/lcars/autopilot.json'"
echo

# =========================================================================
printf '== 4. A SUB-ECH RUNS ITS OWN VERIFY GATE ON ITS CHUNK, AND DRIVES ITS FIXES ==\n'
# =========================================================================
R4="$R3"   # the same chunks; § 3 raised no driver and wrote no verdict
LC4="$(ech_as d1 "$R4" live-check m-mine --type cli 2>&1)"; lc4rc=$?
check "4a. a sub-ECH runs its OWN live check on its own chunk" "[ $lc4rc -eq 0 ]"
LC4O="$(ech_as d1 "$R4" live-check m-theirs --type cli 2>&1)"; lc4orc=$?
check "4b. …and may not run one on a sibling's chunk" "[ $lc4orc -ne 0 ]"
check "4c. that refusal names the sibling that owns it" \
  "printf '%s' \"\$LC4O\" | grep -q 'd2'"
# `policy` has its own precondition (a RECORDED live check), which both of
# these hit. What is under test is the AUTHORITY gate in front of it: in its
# own chunk the seat gets past it and meets policy's real rule; outside it it
# never gets that far.
P4="$(ech_as d1 "$R4" policy --mission m-mine --verdict high --live-check pass 2>&1)"
check "4d. a sub-ECH gets PAST the authority gate on \`policy\` in its own chunk" \
  "! printf '%s' \"\$P4\" | grep -q 'NOT IN YOUR CHUNK'"
check "4d2. …and meets policy's own rule instead, which is unchanged" \
  "printf '%s' \"\$P4\" | grep -qi 'no live check is recorded'"
P4O="$(ech_as d1 "$R4" policy --mission m-theirs --verdict high --live-check pass 2>&1)"; p4orc=$?
check "4e. …and never reaches it on a sibling's chunk" \
  "[ $p4orc -ne 0 ] && printf '%s' \"\$P4O\" | grep -q 'NOT IN YOUR CHUNK'"
D4="$(ech_as d1 "$R4" drive m-mine 2>&1)"; d4rc=$?
check "4f. a sub-ECH DRIVES its own fixes inside its chunk" "[ $d4rc -eq 0 ]"
D4O="$(ech_as d1 "$R4" drive m-theirs 2>&1)"; d4orc=$?
check "4g. …and may not drive a sibling's chunk" "[ $d4orc -ne 0 ]"
check "4h. the drive refusal names the owner, not just 'denied'" \
  "printf '%s' \"\$D4O\" | grep -q 'd2'"
# HCM § 6's STANDING JOB IS UNCHANGED — asserted on the file, because the
# re-reading must not have quietly weakened the ECH's own look.
check "4i. HCM § 6 still says the live check is the standing job, not a fallback" \
  "grep -qi 'standing job' '$HCM'"
check "4j. and NOTHING was removed from HOLOGRAM-COMMAND-MODE.md" \
  "[ \"\$(git -C '$REPO_ROOT' diff '$BASELINE_REF' -- skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md | grep -c '^-[^-]')\" = 0 ]"
echo

# =========================================================================
printf '== 5. AN OWNED, DRIVEN BUG DOES NOT GATE THE PARENT ==\n'
# =========================================================================
R5="$(fast_chunk_repo)"
ech_as d1 "$R5" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
check "5a. [precondition] the sub-ECH's bug is OPEN (stage align, not done)" \
  "grep -q '\"stage\":\"align\"' '$R5/.git/lcars/missions/bug-001/state.json'"
: >"$STUB_LOG"
L5="$(ech "$R5" land m-mine 2>&1)"; l5rc=$?
# NOT THE EXIT CODE: `land` has several later gates of its own (its own live
# check is one of them) and any of them also exits 10, so a bare `-ne 10` would
# be asserting something this behaviour does not claim. What is under test is
# that THE OPEN-CHILDREN GATE did not fire, which is a named refusal.
check "5b. the open-children gate does NOT fire on a bug a sub-ECH is driving" \
  "! printf '%s' \"\$L5\" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG'"
# AND IF IT STOPPED, IT STOPPED SOMEWHERE ELSE. `land` has later gates of its
# own and this fixture reaches one of them — the sign-off gate, which refuses
# to claim a merge approve did not make — so this names the question it DID
# raise rather than asserting an exit code the behaviour never promised. (The
# let-through notice itself says "logged bug", so grepping for those words is
# not an instrument either: the question ledger is.)
check "5b2. …and the question it raised, if any, is a LATER gate's, not that bug's" \
  "[ $l5rc -eq 0 ] || grep -q 'did NOT merge' '$R5/.git/lcars/autopilot.json'"
check "5c. …it did not raise a captain question about that bug" \
  "! grep -q 'cannot be landed' '$R5/.git/lcars/autopilot.json'"
check "5d. …and it reached the real approve verb" \
  "grep -q 'approve.sh' '$STUB_LOG'"
check "5e. the bug it let through is NAMED, with its owner — never silent" \
  "printf '%s' \"\$L5\" | grep -q 'bug-001' && printf '%s' \"\$L5\" | grep -q 'd1'"
echo

# =========================================================================
printf '== 6. AN UNOWNED, UNDRIVEN BUG STILL GATES IT — AND IS NAMED BY ID ==\n'
printf '   (the false-accept control: four ways a bug is NOT being driven)\n'
# =========================================================================
# 6A — nobody owns it (the main ECH filed it, or `lcars log` did).
R6="$(fast_chunk_repo)"
ech "$R6" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
L6="$(ech "$R6" land m-mine 2>&1)"; l6rc=$?
check "6a. an UNOWNED open bug still blocks the parent" "[ $l6rc -eq 10 ]"
check "6b. the refusal names it BY ID" \
  "grep -q 'bug-001' '$R6/.git/lcars/autopilot.json'"
check "6c. the refusal's wording is the unchanged one the captain's board matches" \
  "grep -q 'cannot be landed' '$R6/.git/lcars/autopilot.json'"
check "6d. and it says WHY it blocks — nobody owns it" \
  "printf '%s' \"\$L6\" | grep -qi 'no sub-ECH\|unowned\|nobody'"
check "6e. nothing was handed to approve" "! grep -q 'approve.sh m-mine' '$STUB_LOG'"

# 6B — it WAS owned, and its sub-ECH has been CLOSED OUT. Ownership is released
# on close: a closed sub-ECH drives nothing.
R6B="$(fast_chunk_repo)"
ech_as d1 "$R6B" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
check "6f. [precondition] it was owned while the sub-ECH was open" \
  "[ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R6B/.git/lcars' bug-001)\" = d1 ]"
ech "$R6B" delegate close d1 >/dev/null 2>&1
check "6g. closing the sub-ECH RELEASES its claim on the bug" \
  "[ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R6B/.git/lcars' bug-001)\" ]"
L6B="$(ech "$R6B" land m-mine 2>&1)"; l6brc=$?
check "6h. …so the bug blocks the parent again" "[ $l6brc -eq 10 ]"
check "6i. …named by id" "grep -q 'bug-001' '$R6B/.git/lcars/autopilot.json'"

# 6C — THE FORGED CLAIM. A hand-written ownership line naming a delegate no
# record backs must not buy an accept.
R6C="$(fast_chunk_repo)"
ech "$R6C" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
mkdir -p "$R6C/.git/lcars/delegates/d77"
echo "# a brief nobody minted" >"$R6C/.git/lcars/delegates/d77/BRIEF.md"
: >"$R6C/.git/lcars/delegates/d77/OPEN"
printf 'bug-001\td77\n' >>"$R6C/.git/lcars/chunk-owners"
L6C="$(ech "$R6C" land m-mine 2>&1)"; l6crc=$?
check "6j. a claim naming a delegate NO RECORD BACKS does not clear the gate" \
  "[ $l6crc -eq 10 ]"
check "6k. …and the refusal says the claim is unbacked, naming the id it claimed" \
  "printf '%s' \"\$L6C\" | grep -q 'd77'"

# 6D — THE MIXED PARENT. One bug driven, one not: the undriven one still blocks
# and the refusal must name THAT one, not both and not the wrong one.
R6D="$(fast_chunk_repo)"
ech_as d1 "$R6D" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1   # bug-001, owned
ech     "$R6D" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1     # bug-002, unowned
L6D="$(ech "$R6D" land m-mine 2>&1)"; l6drc=$?
check "6l. a parent with one driven and one undriven bug is still blocked" \
  "[ $l6drc -eq 10 ]"
check "6m. the refusal names the UNDRIVEN one" \
  "grep -q 'bug-002' '$R6D/.git/lcars/autopilot.json'"
check "6n. …and does NOT list the driven one in the blocking sentence" \
  "! grep -o 'Mission(s)[^\"]*' '$R6D/.git/lcars/autopilot.json' | grep -q 'bug-001'"

# 6E — THE REAL ACCEPT PATH, not just the ECH's pre-check. approve.sh's own
# pre-merge gate must agree with `land` about what a blocker is.
PID="lcars-20260930-101"; CID="lcars-20260930-102"; PBRANCH="lcars/$PID"
approve_repo() {
  local cstage="${1:-verify}" repo
  repo="$(mktemp -d "$TMPROOT/arepo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && printf 'orig\n' >README.md && git add -A && git commit -q -m init )
  local base; base="$(cd "$repo" && git rev-parse --abbrev-ref HEAD)"
  ( cd "$repo" && git checkout -q -b "$PBRANCH" \
      && printf 'feature\n' >feature.txt && git add -A \
      && git commit -q -m "lcars($PID) t-001: the feature" && git checkout -q "$base" )
  local p="$repo/.git/lcars/missions/$PID"; mkdir -p "$p"
  cat >"$p/state.json" <<EOF
{ "id": "$PID", "type": "feature", "title": "Publish discussions", "stage": "verify",
  "review": "open", "prUrl": "https://github.com/acme/repo/pull/77", "prNumber": 77,
  "githubIssue": 42, "branch": "$PBRANCH", "base": "$base" }
EOF
  local c="$repo/.git/lcars/missions/$CID"; mkdir -p "$c"
  cat >"$c/state.json" <<EOF
{ "id": "$CID", "type": "bug", "title": "publish stops with no Artifacts category",
  "stage": "$cstage", "githubIssue": 51, "parentMission": "$PID", "parentIssue": 42,
  "branch": "$PBRANCH", "base": "$PBRANCH" }
EOF
  echo '{ "testCommand": "true" }' >"$repo/.git/lcars/config.json"
  cat >"$repo/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"; exit 0
EOF
  cat >"$repo/host" <<'EOF'
#!/usr/bin/env bash
echo "host $*" >>"$GH_LOG"
case "${1:-}" in
  pr-view)  printf 'state\tOPEN\nbaseRefName\tmain\nheadRefName\tb\ntitle\tt\nnumber\t1\n'; exit 0 ;;
  pr-merge) exit 0 ;;
esac
exit 0
EOF
  cat >"$repo/recon" <<'EOF'
#!/usr/bin/env bash
echo "run $*" >>"$RUN_LOG"; exit 0
EOF
  chmod +x "$repo/gh" "$repo/host" "$repo/recon"
  : >"$repo/gh.log"; : >"$repo/run.log"
  printf '%s\n' "$repo"
}
approve_in() {
  local repo="$1"; shift
  ( cd "$repo" \
      && GH_LOG="$repo/gh.log" RUN_LOG="$repo/run.log" \
         LCARS_GH_BIN="$repo/gh" LCARS_GIT_BIN="$(command -v git)" \
         LCARS_HOST_ADAPTER="$repo/host" \
         LCARS_RUN_SCRIPT="$repo/recon" \
         LCARS_MERGE_RETRIES=1 LCARS_MERGE_RETRY_SLEEP=0 \
         bash "$APPROVE" --mission "$PID" "$@" )
}
# Minimal, REAL sub-ECH record for the approve-side fixture.
own_it() { # repo delegate
  local repo="$1" did="$2"
  cat >"$repo/.git/lcars/autopilot.json" <<JSON
{ "spec": "spec.md", "engine": "copilot", "scope": ["M0"], "missions": {},
  "questions": {}, "pending": {},
  "delegates": { "$did": { "id": "$did", "unit": "u", "tier": "T1",
    "status": "minted", "mission": "$PID" } } }
JSON
  mkdir -p "$repo/.git/lcars/delegates/$did"
  echo "# BRIEF $did" >"$repo/.git/lcars/delegates/$did/BRIEF.md"
  : >"$repo/.git/lcars/delegates/$did/OPEN"
  printf '%s\t%s\n' "$CID" "$did" >>"$repo/.git/lcars/chunk-owners"
}
A6="$(approve_repo verify)"
rcA6=0; approve_in "$A6" >"$A6/out.txt" 2>&1 || rcA6=$?
check "6o. [control] the REAL approve still refuses an unowned open bug" \
  "[ \$rcA6 -ne 0 ] && grep -q 'logged bug(s) still open' '$A6/out.txt'"
check "6p. [control] …and merged nothing" "! grep -q 'pr-merge' '$A6/gh.log'"
A6B="$(approve_repo verify)"; own_it "$A6B" d1
rcA6B=0; approve_in "$A6B" >"$A6B/out.txt" 2>&1 || rcA6B=$?
check "6q. the REAL approve does NOT refuse a bug a sub-ECH owns and drives" \
  "! grep -q 'logged bug(s) still open' '$A6B/out.txt'"
check "6r. …and it says so out loud, naming the bug and its owner" \
  "grep -q '$CID' '$A6B/out.txt' && grep -q 'd1' '$A6B/out.txt'"
check "6s. …said ONCE, not once per gate call" \
  "[ \"\$(grep -c 'owns and is driving' '$A6B/out.txt')\" = 1 ]"
echo

# =========================================================================
printf '== 7. THE MINTED BRIEF CARRIES THE AUTHORITY, THE SCOPE AND THE LIMITS ==\n'
# =========================================================================
R7="$R1"   # the REAL mint from § 1 — the brief under test is the one it wrote
B7="$R7/.git/lcars/delegates/d1/BRIEF.md"
check "7a. [precondition] the brief was minted" "[ -f '$B7' ]"
check "7b. it says the delegate OWNS a chunk" "grep -qi 'your chunk' '$B7'"
check "7c. it names the chunk's scope — the Mission id itself" \
  "grep -q 'm-mine' '$B7'"
check "7d. it names \`file-bug\` as the delegate's OWN verb, in its chunk" \
  "grep -q 'file-bug' '$B7'"
check "7e. it names \`live-check\` as the delegate's own verify gate" \
  "grep -q 'live-check' '$B7'"
check "7f. it states the LIMIT: \`ask\` and \`land\` stay with the main ECH" \
  "grep -q 'The ECH keeps these to ITSELF' '$B7' \
   && grep -A3 'The ECH keeps these to ITSELF' '$B7' | grep -q 'ask' \
   && grep -A3 'The ECH keeps these to ITSELF' '$B7' | grep -q 'land'"
check "7g. it names the main ECH as who verifies the WHOLE" \
  "grep -qi 'the whole' '$B7'"
check "7h. it tells the seat HOW to identify itself, so the authority resolves" \
  "grep -q 'LCARS_ECH_AS' '$B7'"
check "7i. DELEGATION.md is the ONE statement of it" \
  "grep -qi 'authority travels with the chunk' '$DOC'"
check "7j. …and it keeps the evidence that this is a RE-READING, not a reversal" \
  "grep -q '0 of 31' '$DOC'"
echo

# =========================================================================
printf '== 8. KNOWN-GOOD CONTROL: A REPO WITH NO SUB-ECHS IS BYTE-IDENTICAL ==\n'
# =========================================================================
BASE_DIR="$TMPROOT/baseline"
mkdir -p "$BASE_DIR"
base_ok=0
if git -C "$REPO_ROOT" rev-parse --verify "$BASELINE_REF^{commit}" >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" archive "$BASELINE_REF" skills | tar -x -C "$BASE_DIR" 2>/dev/null; then
    base_ok=1
  fi
fi
check "8a. the BASELINE ($BASELINE_REF) was extracted — a control that cannot run is not a pass" \
  "[ '$base_ok' = 1 ] && [ -f '$BASE_DIR/skills/lcars-eeh/ech.sh' ]"
BASE_SCRIPT="$BASE_DIR/skills/lcars-eeh/ech.sh"

# A repo with real missions, a real question, a real failed drive — and NO
# delegates at all, which is every repo the captain has today.
R8="$(new_repo)"
ap_init "$R8"
new_mission "$R8" m-plain verify
new_mission "$R8" bug-plain align bug m-plain
ech "$R8" record 'missions.M0.id' m-plain >/dev/null 2>&1
for v in stalled next status; do
  ech_at "$BASE_SCRIPT" "$R8" "$v" >"$TMPROOT/before.$v" 2>&1 || true
  ech_at "$SCRIPT"      "$R8" "$v" >"$TMPROOT/after.$v"  2>&1 || true
  # The baseline lives at another path, so its own absolute self-references
  # differ by construction; normalise ONLY the two checkout roots.
  sed -i.bak "s#$BASE_DIR/##g" "$TMPROOT/before.$v" 2>/dev/null || true
  sed -i.bak "s#$REPO_ROOT/##g" "$TMPROOT/after.$v" 2>/dev/null || true
  check "8b.$v. \`$v\` is BYTE-IDENTICAL to the baseline on a repo with no sub-ECHs" \
    "diff -q '$TMPROOT/before.$v' '$TMPROOT/after.$v' >/dev/null"
done
check "8c. …and the before/after really had content to compare" \
  "[ -s '$TMPROOT/after.status' ] && [ -s '$TMPROOT/after.next' ]"
# THE KNOWN-FAIL CONTROL FOR § 8 ITSELF, and it is also the BEFORE/AFTER of the
# cure. `stalled`, `next` and `status` are read-only reporters this session did
# not touch, so pointing the control at THEM would only prove they are
# unchanged twice over — a comparison that can never fail is not a control. So
# the same method is pointed at the one verb that DID change, on a repo with a
# sub-ECH driving its own bug: the baseline must block that accept and the cure
# must not.
R8B="$(fast_chunk_repo)"
ech_as d1 "$R8B" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
ech_at "$BASE_SCRIPT" "$R8B" land m-mine >"$TMPROOT/before.land" 2>&1; b8rc=$?
ech_at "$SCRIPT"      "$R8B" land m-mine >"$TMPROOT/after.land"  2>&1; a8rc=$?
check "8d. [known-fail control] the BASELINE blocked the accept on the sub-ECH's own bug" \
  "[ $b8rc -eq 10 ] && grep -q 'bug-001' '$R8B/.git/lcars/autopilot.json'"
check "8d2. …and the cure does not block it on that bug" \
  "! grep -q 'BLOCKED BY UNOWNED LOGGED BUG' '$TMPROOT/after.land'"
check "8d3. …so the diffing method in 8b can tell a difference when there IS one" \
  "! diff -q '$TMPROOT/before.land' '$TMPROOT/after.land' >/dev/null"
# And a repo with no chunk-owners file at all behaves as it always did on the
# accept path — the degradation case approve.sh must survive.
A8="$(approve_repo verify)"
rm -f "$A8/.git/lcars/chunk-owners"
rcA8=0; approve_in "$A8" >"$A8/out.txt" 2>&1 || rcA8=$?
check "8e. approve with NO ownership record at all behaves exactly as before" \
  "[ \$rcA8 -ne 0 ] && grep -q 'logged bug(s) still open' '$A8/out.txt'"
# AND `exec` ITSELF, which gained a branch in fix round 1. For the MAIN ECH it
# still `exec`s — the process is replaced, as it always was — so its output and
# its exit status must be byte-for-byte the baseline's. (A sub-ECH's call is
# forked instead, which is the only way anything can be recorded after it.)
EXEC_SKILLS_BASE="$TMPROOT/exec-skills-base"
mkdir -p "$EXEC_SKILLS_BASE/lcars-file" "$EXEC_SKILLS_BASE/lcars-eeh"
if [ "$base_ok" = 1 ]; then
  cp -R "$BASE_DIR/skills/lcars-eeh/." "$EXEC_SKILLS_BASE/lcars-eeh/"
fi
cp "$STUBS/file-makes.sh" "$EXEC_SKILLS_BASE/lcars-file/file.sh"
R8C="$(new_repo)"; ap_init "$R8C"; new_mission "$R8C" m-plain verify
R8D="$(new_repo)"; ap_init "$R8D"; new_mission "$R8D" m-plain verify
ech_at "$EXEC_SKILLS_BASE/lcars-eeh/$(basename "$SCRIPT")" "$R8C"   exec lcars-file/file.sh --id m-new >"$TMPROOT/before.exec" 2>&1; e8b=$?
ech_at "$EXEC_SCRIPT" "$R8D" exec lcars-file/file.sh --id m-new >"$TMPROOT/after.exec" 2>&1; e8a=$?
check "8f. a MAIN-ECH \`exec\` is byte-identical to the baseline, same exit status" \
  "[ '$e8b' = '$e8a' ] && diff -q '$TMPROOT/before.exec' '$TMPROOT/after.exec' >/dev/null"
check "8f2. …and it really filed the Mission both times (not silent on both sides)" \
  "[ -f '$R8C/.git/lcars/missions/m-new/state.json' ] \
   && [ -f '$R8D/.git/lcars/missions/m-new/state.json' ]"
check "8f3. …and claimed no owner on either side" \
  "[ ! -f '$R8C/.git/lcars/chunk-owners' ] && [ ! -f '$R8D/.git/lcars/chunk-owners' ]"
echo

# =========================================================================
printf '== 9. A SUB-ECH SUBDIVIDES ITS CHUNK: THE MISSIONS IT FILES ARE ITS OWN ==\n'
# =========================================================================
# THE CAPTAIN, 2026-11-20, in his own words: *"sub echs can chunk the work they
# want to the factory how they see fit. So if they get told add fish to the
# river system that's impacted by water level, they can sub divide the missions
# they feed the factory as it makes sense."* So a sub-ECH handed ONE chunk is
# EXPECTED to file several Missions for it and drive all of them. With a chunk
# of "the seeded Mission plus bugs beneath it" it would be refused on two of its
# own three.
#
# WIDENING A CHUNK IS EXACTLY HOW A BLOCKER COULD GO QUIET, so § 9f re-runs all
# four of § 6's control shapes at the new, wider root. That is the row that
# matters here.
R9="$(fast_chunk_repo)"
X9A="$(xech d1 "$R9" exec lcars-file/file.sh --id m-fish 2>&1)"; x9arc=$?
X9B="$(xech d1 "$R9" exec lcars-file/file.sh --id m-water 2>&1)"; x9brc=$?
X9C="$(xech d1 "$R9" exec lcars-file/file.sh --id m-cast 2>&1)"; x9crc=$?
check "9a. [precondition] the three Missions were really created" \
  "[ $x9arc -eq 0 ] && [ $x9brc -eq 0 ] && [ $x9crc -eq 0 ] \
   && [ -f '$R9/.git/lcars/missions/m-fish/state.json' ] \
   && [ -f '$R9/.git/lcars/missions/m-water/state.json' ] \
   && [ -f '$R9/.git/lcars/missions/m-cast/state.json' ]"
check "9b. each one is RECORDED as the sub-ECH's, in the one ownership record" \
  "[ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-fish)\" = d1 ] \
   && [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-water)\" = d1 ] \
   && [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-cast)\" = d1 ]"
check "9b2. …and \`exec\` says so, naming the Mission and the seat" \
  "printf '%s' \"\$X9A\" | grep -q 'm-fish' && printf '%s' \"\$X9A\" | grep -q 'd1'"
# BEHAVIOUR 1 — all four chunk verbs work on every one of the three.
# ONE COUNTER PER VERB, not one for all four: the first run of this section
# failed `[ 3 -eq 0 ]` and the number said nothing about WHICH verb, which is
# the measurement naming the fix rather than the reader guessing at it.
lc9=0; fb9=0; dr9=0; po9=0
for m9 in m-fish m-water m-cast; do
  xech d1 "$R9" live-check "$m9" --type cli >/dev/null 2>&1 || lc9=$((lc9+1))
  xech d1 "$R9" file-bug --parent "$m9" --prd "$PRD_GOOD" >/dev/null 2>&1 || fb9=$((fb9+1))
  xech d1 "$R9" drive "$m9" >/dev/null 2>&1 || dr9=$((dr9+1))
  # The real waiter clears its own recorded pid on exit; the stub's is already
  # gone, so clear the record too or the two-mission ceiling (MAX_SLOTS) refuses
  # the third drive for a reason that is not about authority.
  xech - "$R9" record "drivers.$m9.pid" '' >/dev/null 2>&1
  p9="$(xech d1 "$R9" policy --mission "$m9" --verdict high --live-check pass 2>&1)"
  printf '%s' "$p9" | grep -q 'NOT IN YOUR CHUNK' && po9=$((po9+1))
done
check "9c. \`live-check\` works on ALL THREE Missions it filed"  "[ $lc9 -eq 0 ]"
check "9c2. \`file-bug\` works on all three"                      "[ $fb9 -eq 0 ]"
check "9c3. \`drive\` works on all three"                         "[ $dr9 -eq 0 ]"
check "9c4. \`policy\` clears the authority gate on all three"    "[ $po9 -eq 0 ]"
# BEHAVIOUR 4 — a bug beneath a Mission IT FILED is in its chunk, one level
# wider than the seed. The bugs filed above are exactly that case; name it.
check "9d. a bug beneath a Mission it FILED is in its chunk (the descent is now rooted wider)" \
  "[ -f '$R9/.git/lcars/missions/bug-001/state.json' ] \
   && [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' bug-001)\" = d1 ]"
# BEHAVIOUR 2 — a Mission the MAIN ECH filed belongs to nobody.
X9M="$(xech - "$R9" exec lcars-file/file.sh --id m-main 2>&1)"; x9mrc=$?
check "9e. a Mission the MAIN ECH filed is owned by NO sub-ECH (unchanged behaviour)" \
  "[ $x9mrc -eq 0 ] && [ -f '$R9/.git/lcars/missions/m-main/state.json' ] \
   && [ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-main)\" ]"
check "9e2. …and a sub-ECH may not act on it — it is the MAIN ECH's" \
  "! xech d1 '$R9' live-check m-main --type cli >/dev/null 2>&1"
# BEHAVIOUR 3 — nor on a Mission ANOTHER sub-ECH filed, and the owner is named.
xech d2 "$R9" exec lcars-file/file.sh --id m-theirs-own >/dev/null 2>&1
S9="$(xech d1 "$R9" live-check m-theirs-own --type cli 2>&1)"; s9rc=$?
check "9f. a sub-ECH may NOT act on a Mission ANOTHER sub-ECH filed" "[ $s9rc -ne 0 ]"
check "9f2. …and the refusal NAMES the sibling that owns it" \
  "printf '%s' \"\$S9\" | grep -q 'd2'"
# BEHAVIOUR 7 — closing releases EVERYTHING, Missions as well as bugs.
C9="$(xech - "$R9" delegate close d1 2>&1)"
check "9g. \`delegate close\` releases the Missions it filed, not just its bugs" \
  "[ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-fish)\" ] \
   && [ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-water)\" ] \
   && [ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-cast)\" ] \
   && [ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' bug-001)\" ]"
check "9g2. …and it SAYS what it released, by id" \
  "printf '%s' \"\$C9\" | grep -q 'm-fish' && printf '%s' \"\$C9\" | grep -qi 'released'"
check "9g3. …and d2's claim is untouched by d1's close" \
  "[ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R9/.git/lcars' m-theirs-own)\" = d2 ]"
check "9g4. …and the Mission records themselves were NOT touched" \
  "[ -f '$R9/.git/lcars/missions/m-fish/state.json' ]"
echo

# =========================================================================
printf '== 9b. THE FALSE-ACCEPT CONTROL AT THE NEW, WIDER ROOT ==\n'
printf '   (all four of § 6 shapes, on a Mission the sub-ECH FILED)\n'
# =========================================================================
# 9h — unowned bug beneath a FILED Mission still blocks it.
R9H="$(fast_chunk_repo)"
xech d1 "$R9H" exec lcars-file/file.sh --id m-fish >/dev/null 2>&1
xech - "$R9H" file-bug --parent m-fish --prd "$PRD_GOOD" >/dev/null 2>&1   # main ECH: unowned
L9H="$(xech - "$R9H" land m-fish 2>&1)"; l9hrc=$?
check "9h. an UNOWNED bug beneath a Mission the sub-ECH filed STILL blocks it" \
  "[ $l9hrc -eq 10 ] && printf '%s' \"\$L9H\" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG'"
check "9h2. …named BY ID" "grep -q 'bug-001' '$R9H/.git/lcars/autopilot.json'"
# 9i — owner closed out: the bug blocks again.
R9I="$(fast_chunk_repo)"
xech d1 "$R9I" exec lcars-file/file.sh --id m-fish >/dev/null 2>&1
xech d1 "$R9I" file-bug --parent m-fish --prd "$PRD_GOOD" >/dev/null 2>&1
check "9i. [precondition] that bug is owned and driven while the seat is open" \
  "! xech - '$R9I' land m-fish 2>&1 | grep -q 'BLOCKED BY UNOWNED LOGGED BUG'"
xech - "$R9I" delegate close d1 >/dev/null 2>&1
L9I="$(xech - "$R9I" land m-fish 2>&1)"; l9irc=$?
check "9i2. once its owner is CLOSED the bug blocks that filed Mission again" \
  "[ $l9irc -eq 10 ] && printf '%s' \"\$L9I\" | grep -q 'bug-001'"
# 9j — a forged claim at the wider root buys nothing.
R9J="$(fast_chunk_repo)"
xech d1 "$R9J" exec lcars-file/file.sh --id m-fish >/dev/null 2>&1
xech - "$R9J" file-bug --parent m-fish --prd "$PRD_GOOD" >/dev/null 2>&1
mkdir -p "$R9J/.git/lcars/delegates/d77"
echo "# a brief nobody minted" >"$R9J/.git/lcars/delegates/d77/BRIEF.md"
: >"$R9J/.git/lcars/delegates/d77/OPEN"
printf 'bug-001\td77\n' >>"$R9J/.git/lcars/chunk-owners"
L9J="$(xech - "$R9J" land m-fish 2>&1)"; l9jrc=$?
check "9j. a claim NO RECORD BACKS still blocks a filed Mission, naming the id" \
  "[ $l9jrc -eq 10 ] && printf '%s' \"\$L9J\" | grep -q 'd77'"
# 9k — mixed: one driven, one not, beneath a FILED Mission.
R9K="$(fast_chunk_repo)"
xech d1 "$R9K" exec lcars-file/file.sh --id m-fish >/dev/null 2>&1
xech d1 "$R9K" file-bug --parent m-fish --prd "$PRD_GOOD" >/dev/null 2>&1   # bug-001 owned
xech - "$R9K" file-bug --parent m-fish --prd "$PRD_GOOD" >/dev/null 2>&1    # bug-002 unowned
L9K="$(xech - "$R9K" land m-fish 2>&1)"; l9krc=$?
check "9k. a filed Mission with one driven and one undriven bug is still blocked" \
  "[ $l9krc -eq 10 ]"
check "9k2. the refusal names the UNDRIVEN one" \
  "grep -q 'bug-002' '$R9K/.git/lcars/autopilot.json'"
check "9k3. …and does NOT list the driven one in the blocking sentence" \
  "! grep -o 'Mission(s)[^\"]*' '$R9K/.git/lcars/autopilot.json' | grep -q 'bug-001'"
# 9l — THE REAL ACCEPT PATH does not change its mind about a Mission row.
# A Mission id in `chunk-owners` must never make approve.sh let a bug past.
A9="$(approve_repo verify)"
mkdir -p "$A9/.git/lcars/delegates/d1"
echo "# BRIEF d1" >"$A9/.git/lcars/delegates/d1/BRIEF.md"
: >"$A9/.git/lcars/delegates/d1/OPEN"
printf '%s\td1\n' "$PID" >>"$A9/.git/lcars/chunk-owners"    # the PARENT is owned, not the bug
rc9=0; approve_in "$A9" >"$A9/out.txt" 2>&1 || rc9=$?
check "9l. a MISSION row in the record does not buy its bug child an accept" \
  "[ \$rc9 -ne 0 ] && grep -q 'logged bug(s) still open' '$A9/out.txt'"
check "9l2. …and nothing merged" "! grep -q 'pr-merge' '$A9/gh.log'"
echo

# =========================================================================
printf '== 11. THE BOUNDARY: DENY BY DEFAULT (the fresh tester, F5/F6) ==\n'
# =========================================================================
# THE SUITE WAS GREEN WHILE ALL OF THIS WAS TRUE, which is the gap these rows
# close. Round 1 added authority as CHECKS ON PARTICULAR VERBS: six verbs opted
# in, about twenty did not. The tester walked through with real verbs and zero
# hand-editing, and the identity mechanism — 16/16 forgery attacks refused —
# was irrelevant, because the seat never had to GUESS an id. It ISSUED one.
R11="$(fast_chunk_repo)"
cp "$R11/.git/lcars/autopilot.json" "$TMPROOT/ap11.before"
printf '# spec\n' >"$TMPROOT/spec12.md"
# ---- 11a: THE ESCALATION CHAIN, as ONE end-to-end row -------------------
# record -> tier -> delegate -> act as the seat you just minted.
e1="$(xech d1 "$R11" record 'missions.theirs.id' m-theirs 2>&1)"; e1rc=$?
e2="$(xech d1 "$R11" tier theirs --tier T1 --why "mine now" 2>&1)"; e2rc=$?
e3="$(xech d1 "$R11" delegate theirs 2>&1)"; e3rc=$?
e4rc=0; xech d9 "$R11" live-check m-theirs --type cli >/dev/null 2>&1 || e4rc=$?
check "11a. THE ESCALATION CHAIN IS BROKEN AT ITS FIRST LINK, and at every link" \
  "[ $e1rc -ne 0 ] && [ $e2rc -ne 0 ] && [ $e3rc -ne 0 ] && [ $e4rc -ne 0 ]"
check "11a2. …\`record\` is refused, naming the MAIN ECH as owner" \
  "printf '%s' \"\$e1\" | grep -qi 'main ECH' && printf '%s' \"\$e1\" | grep -q 'NOT A VERB A SUB-ECH MAY RUN'"
# The fixture already maps `theirs` -> m-theirs (that is d2's own chunk), so
# the measurement is that the RECORD DID NOT CHANGE, not that the id is absent.
check "11a3. …and it wrote NOTHING: the record is byte-identical to before" \
  "cmp -s '$R11/.git/lcars/autopilot.json' '$TMPROOT/ap11.before'"
check "11a4. …\`tier\` recorded no judgement" \
  "! grep -q 'mine now' '$R11/.git/lcars/autopilot.json'"
# ANCHORED TO THE MINT'S OWN BANNER, not to the word. The refusal's reason now
# contains the sentence "a seat has MINTED ITSELF a seat", and a bare
# `grep MINTED` matched the refusal that proves the attack failed — a test
# tripped by the prose of its own cure.
check "11a5. …and \`delegate\` MINTED NOTHING — no third seat, no brief" \
  "[ ! -d '$R11/.git/lcars/delegates/d3' ] && ! printf '%s\n' \"\$e3\" | grep -q '^MINTED:'"
check "11a6. the refusal lists the verbs the seat DOES have, so it is not a dead end" \
  "printf '%s' \"\$e1\" | grep -q 'file-bug' && printf '%s' \"\$e1\" | grep -q 'beat'"
check "11a7. …and hands back the one channel it has" \
  "printf '%s' \"\$e1\" | grep -q 'BLOCKED'"
# ---- 11b: every other ungated verb the tester named ---------------------
nb=0; nbnames=""
for v11 in record tier delegate delegates grant answered init preflight status \
           next stalled playbook report engines worktree workflow-run heartbeat \
           watch await _waiter push-gated ask land; do
  if xech d1 "$R11" "$v11" >/dev/null 2>&1; then nb=$((nb+1)); nbnames="$nbnames $v11"; fi
done
check "11b. NONE of the 23 main-ECH verbs runs for a sub-ECH (deny by default)" \
  "[ $nb -eq 0 ]    # granted:$nbnames"
# F6 — DELEGATION.md's own table says push-gated is never allowed. Now it isn't.
pg11="$(xech d1 "$R11" push-gated 2>&1)"; pg11rc=$?
check "11c. [F6] \`push-gated\` is refused, as \`DELEGATION.md\`'s table already said" \
  "[ $pg11rc -ne 0 ] && printf '%s' \"\$pg11\" | grep -q 'NOT A VERB A SUB-ECH MAY RUN'"
check "11c2. …and the doc and the code agree on the allow-list, from ONE constant" \
  "grep -q 'SUBECH_VERBS=\"beat exec budget ledger file-bug live-check policy drive\"' '$REPO_ROOT/skills/lcars-eeh/ech.sh' \
   && grep -q 'beat exec budget ledger file-bug live-check policy drive' '$DOC'"
# ---- 11d: the allow-list still WORKS — the control that matters ---------
# A boundary that refuses everything is not a cure, it is an outage.
ok11=0
xech d1 "$R11" beat d1 "step 1 of 2: looking" >/dev/null 2>&1 || ok11=$((ok11+1))
xech d1 "$R11" live-check m-mine --type cli >/dev/null 2>&1 || ok11=$((ok11+1))
xech d1 "$R11" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1 || ok11=$((ok11+1))
xech d1 "$R11" drive m-mine >/dev/null 2>&1 || ok11=$((ok11+1))
xech d1 "$R11" exec lcars-file/file.sh --id m-own >/dev/null 2>&1 || ok11=$((ok11+1))
xech d1 "$R11" ledger feedback '{"kind":"lcars-bug","delegate":"d1","what":"nothing found"}' >/dev/null 2>&1 || ok11=$((ok11+1))
check "11d. [control] all eight allowed verbs still RUN for a sub-ECH" "[ $ok11 -eq 0 ]"
check "11d2. [control] …and the MAIN ECH's own verbs are all untouched" \
  "xech - '$R11' status >/dev/null 2>&1 && xech - '$R11' record 'missions.theirs.id' m-theirs >/dev/null 2>&1 \
   && xech - '$R11' tier theirs --tier T1 --why 'the main ECH chunking' >/dev/null 2>&1"
# ---- 11e: and the brief TELLS the seat its boundary ---------------------
check "11e. the minted brief states the allow-list, rendered from the same constant" \
  "grep -q 'beat exec budget ledger file-bug live-check policy drive' '$B7'"
check "11e2. …and says it is deny-by-default, with the reason" \
  "grep -qi 'deny-by-default' '$B7' && grep -qi 'mint ITSELF' '$B7'"
echo

# =========================================================================
printf '== 12. ONE ADJUDICATOR: land and approve cannot disagree (F1) ==\n'
# =========================================================================
# THE LIBRARY WAS SHARED AND THE ADJUDICATION WAS NOT. `lcars_chunk_owner`
# tested a row plus a BRIEF.md; `land` ALSO read the delegate record through
# python. Two documented verbs reached the disagreement: `init --force` drops
# `delegates` by design, leaves the briefs by design, and left `chunk-owners`
# alone — after which `land` BLOCKED and `approve` MERGED.
R12="$(fast_chunk_repo)"
xech d1 "$R12" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
check "12a. [precondition] the bug is owned and driven" \
  "[ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R12/.git/lcars' bug-001)\" = d1 ]"
I12="$(xech - "$R12" init --spec "$TMPROOT/spec12.md" --scope M0 --force 2>&1)"
check "12b. \`init --force\` RELEASES the ownership it orphans" \
  "[ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_claim '$R12/.git/lcars' bug-001)\" ]"
check "12b2. …and shuts the seat it discarded" \
  "[ ! -f '$R12/.git/lcars/delegates/d1/OPEN' ]"
check "12b3. …and SAYS so, beside the records it already names" \
  "printf '%s' \"\$I12\" | grep -qi 'OWNERSHIP RELEASED'"
check "12b4. …and it did NOT delete the brief (a durable artifact, by design)" \
  "[ -f '$R12/.git/lcars/delegates/d1/BRIEF.md' ]"
# THE DISAGREEMENT ITSELF: a row + a brief but NO open seat. Both gates must
# reach the same answer, and that answer must be BLOCK.
R12B="$(approve_repo verify)"
mkdir -p "$R12B/.git/lcars/delegates/d1"
echo "# BRIEF d1" >"$R12B/.git/lcars/delegates/d1/BRIEF.md"
printf '%s\t%s\n' "$CID" d1 >>"$R12B/.git/lcars/chunk-owners"   # no OPEN marker
rc12=0; approve_in "$R12B" >"$R12B/out.txt" 2>&1 || rc12=$?
check "12c. the REAL approve REFUSES a claim whose seat is not open" \
  "[ \$rc12 -ne 0 ] && grep -q 'logged bug(s) still open' '$R12B/out.txt'"
check "12c2. …and merged nothing" "! grep -q 'pr-merge' '$R12B/gh.log'"
# …and the ECH's own pre-check agrees, on the same shape, for the same reason.
R12C="$(fast_chunk_repo)"
xech d1 "$R12C" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
rm -f "$R12C/.git/lcars/delegates/d1/OPEN"
L12="$(xech - "$R12C" land m-mine 2>&1)"; l12rc=$?
check "12d. \`land\` blocks on exactly the same shape" \
  "[ $l12rc -eq 10 ] && printf '%s' \"\$L12\" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG'"
check "12d2. …and names the id it refused and WHY — not just 'nobody owns it'" \
  "printf '%s' \"\$L12\" | grep -q 'd1' && printf '%s' \"\$L12\" | grep -qi 'NOT OPEN'"
check "12e. [control] with the marker back, BOTH let it through again" \
  ": >'$R12C/.git/lcars/delegates/d1/OPEN'; ! printf '%s' \"\$(xech - '$R12C' land m-mine 2>&1)\" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG'"
check "12f. the adjudicator is ONE function, and \`land\` no longer has its own" \
  "grep -q 'lcars_chunk_owner' '$REPO_ROOT/skills/lcars-approve/approve.sh' \
   && [ \"\$(grep -c 'delegates\.\$owner\.' '$SCRIPT')\" = 0 ]"
echo

# =========================================================================
printf '== 13. A CREATION IS SCOPE-CHECKED BEFORE IT IS RECORDED (F2) ==\n'
# =========================================================================
# `d1` ran `exec lcars-log/log.sh --parent m-theirs` and was handed
# `CHUNK: xbug-1 is now yours (d1)`. Both gates then let `m-theirs` through and
# d1 could `live-check` inside d2's chunk.
R13="$(fast_chunk_repo)"
X13="$(xech d1 "$R13" exec lcars-log/log.sh --parent m-theirs --id xbug-1 2>&1)"
check "13a. [precondition] the bug under the sibling's Mission really was created" \
  "[ -f '$R13/.git/lcars/missions/xbug-1/state.json' ]"
check "13b. it is attributed to NOBODY" \
  "[ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_claim '$R13/.git/lcars' xbug-1)\" ]"
check "13c. and the refusal says so, naming the parent and the chunk" \
  "printf '%s' \"\$X13\" | grep -q 'REFUSED TO ATTRIBUTE' && printf '%s' \"\$X13\" | grep -q 'm-theirs'"
check "13d. so the sibling's Mission did NOT join d1's chunk" \
  "! xech d1 '$R13' live-check m-theirs --type cli >/dev/null 2>&1"
check "13e. …and that undriven bug now BLOCKS the sibling's accept, by id" \
  "printf '%s' \"\$(xech - '$R13' land m-theirs 2>&1)\" | grep -q 'xbug-1'"
check "13f. [control] a bug under its OWN chunk is still attributed normally" \
  "xech d1 '$R13' exec lcars-log/log.sh --parent m-mine --id xbug-2 >/dev/null 2>&1; \
   [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R13/.git/lcars' xbug-2)\" = d1 ]"
check "13g. [control] a PARENTLESS Mission is still claimable — subdivide as you see fit" \
  "xech d1 '$R13' exec lcars-file/file.sh --id m-root2 >/dev/null 2>&1; \
   [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R13/.git/lcars' m-root2)\" = d1 ]"
echo

# =========================================================================
printf '== 14. THE ATTRIBUTION WINDOW IS BOUNDED (F3) ==\n'
# =========================================================================
# A Mission the captain filed from another terminal during a six-second `exec`
# was attributed to the sub-ECH, because the diff spanned ANY script's whole
# life — and `exec … run.sh drive` is a documented long-running use with two
# concurrent slots by design.
R14="$(fast_chunk_repo)"
X14="$(xech d1 "$R14" exec lcars-run/run.sh drive --mission m-mine 2>&1)"; x14rc=$?
check "14a. [precondition] a Mission really appeared while that script ran" \
  "[ -f '$R14/.git/lcars/missions/m-elsewhere/state.json' ]"
check "14b. a NON-CREATING script attributes NOTHING — no window at all" \
  "[ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_claim '$R14/.git/lcars' m-elsewhere)\" ]"
check "14b2. …and it said nothing about a chunk, because it measured nothing" \
  "! printf '%s' \"\$X14\" | grep -q 'CHUNK:'"
check "14c. so that Mission is not in d1's chunk" \
  "! xech d1 '$R14' live-check m-elsewhere --type cli >/dev/null 2>&1"
check "14d. [control] a DECLARED creator is still measured and still attributes" \
  "xech d1 '$R14' exec lcars-file/file.sh --id m-mine2 >/dev/null 2>&1; \
   [ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R14/.git/lcars' m-mine2)\" = d1 ]"
# AND THE LOWER BOUND: a record older than the call is not attributed, even
# though the listing only noticed it during the call.
R14B="$(fast_chunk_repo)"
mkdir -p "$R14B/.git/lcars/missions/m-stale"
printf '{"id":"m-stale","stage":"verify","type":"feature","title":"older"}\n' \
  >"$R14B/.git/lcars/missions/m-stale/state.json"
touch -t 202001010000 "$R14B/.git/lcars/missions/m-stale/state.json"
# It is not in the "before" listing only because the suite plants it after the
# fact; the point under test is the MTIME bound, not the listing.
check "14e. [precondition] the planted record is genuinely older" \
  "[ \"\$(. '$CHUNK_LIB'; lcars_chunk_claim '$R14B/.git/lcars' m-stale)\" = '' ]"
X14B="$(xech d1 "$R14B" exec lcars-file/file.sh --id m-fresh 2>&1)"
check "14f. the fresh Mission is attributed and the stale one is not" \
  "[ \"\$(. '$CHUNK_LIB'; lcars_chunk_owner '$R14B/.git/lcars' m-fresh)\" = d1 ] \
   && [ -z \"\$(. '$CHUNK_LIB'; lcars_chunk_claim '$R14B/.git/lcars' m-stale)\" ]"
echo

# =========================================================================
printf '== 16. THE BOUNDARY BOUNDS WHAT A SEAT *DOES* (fix round 3, cure 1) ==\n'
# =========================================================================
# ROUND 2 BOUNDED THE VERB NAMES. `exec` reaches a sibling script, and the ACTS
# those scripts perform were not bounded at all. Measured by a fresh tester,
# same fixture, `LCARS_ECH_AS=d1` whose chunk is NOT the Mission it merged:
#
#     lcars-ech land m-land                                 -> DENIED
#     lcars-ech exec lcars-approve/approve.sh --mission m-land
#         -> pr-merge calls = 1 ; stage AFTER = "done"
#
# IT MERGED A MISSION IT WAS NEVER HANDED. `land`, `approve` and `push-gated`
# are each refused BY NAME with their own sentence about landing being the main
# ECH's one decision — and the identical decision was one `exec` away.
R16="$(fast_chunk_repo)"
: >"$R16/merged.log"; : >"$R16/ran.log"
# ---- 16a: THE PAIR, IN ONE ROW, so they can never drift apart again -----
l16="$(xech d1 "$R16" land m-theirs 2>&1)"; l16rc=$?
x16="$(xech d1 "$R16" exec lcars-approve/approve.sh --mission m-theirs 2>&1)"; x16rc=$?
check "16a. \`land\` IS DENIED **AND** \`exec approve.sh\` IS DENIED — the name and the act" \
  "[ $l16rc -ne 0 ] && [ $x16rc -ne 0 ]"
check "16a2. …and NOTHING MERGED: no pr-merge, and the Mission is still at verify" \
  "[ ! -s '$R16/merged.log' ] && grep -q '\"stage\": *\"verify\"' '$R16/.git/lcars/missions/m-theirs/state.json'"
check "16a3. the \`exec\` refusal says WHY — that it is the same decision by another route" \
  "printf '%s' \"\$x16\" | grep -qi 'MERGES' && printf '%s' \"\$x16\" | grep -qi 'one decision'"
check "16a4. …and names the MAIN ECH as the owner, with the route back" \
  "printf '%s' \"\$x16\" | grep -qi 'main ECH' && printf '%s' \"\$x16\" | grep -q 'BLOCKED'"
# IT IS DENIED IN ITS OWN CHUNK TOO: landing is not a scope question.
x16b="$(xech d1 "$R16" exec lcars-approve/approve.sh --mission m-mine 2>&1)"; x16brc=$?
check "16a5. …and it is refused on its OWN chunk as well — landing is never a scope question" \
  "[ $x16brc -ne 0 ] && [ ! -s '$R16/merged.log' ]"
# ---- 16b: one row per denied script -------------------------------------
for pair16 in "lcars-answer/answer.sh:the Review decision" \
              "lcars-feedback/feedback.sh:the Review decision" \
              "lcars-init/init.sh:the reset that releases its own claims" \
              "lcars-xo/xo.sh:Number One, which the captain has ruled OFF" \
              "lcars-eeh/ech.sh:this program itself"; do
  sc16="${pair16%%:*}"; wh16="${pair16#*:}"
  o16="$(xech d1 "$R16" exec "$sc16" 2>&1)"; r16=$?
  check "16b. \`exec $sc16\` is REFUSED ($wh16)" \
    "[ $r16 -ne 0 ] && printf '%s' \"\$o16\" | grep -q 'IS NOT A SCRIPT A SUB-ECH MAY REACH'"
done
check "16b2. …and none of them RAN: no script left a mark" \
  "[ ! -s '$R16/ran.log' ]"
check "16b3. the xo refusal names the captain's standing ruling, not just 'denied'" \
  "printf '%s' \"\$(xech d1 '$R16' exec lcars-xo/xo.sh 2>&1)\" | grep -qi 'Number One is OFF'"
# ---- 16c: NOT AN OUTAGE — the documented scripts still reach their work --
# This is the control that matters: the coordinator declined an allow-list in
# round 2 because it would break `respond.sh`, `resolve-logs.sh` and `xo.sh`.
# That was a reason to put them ON the list, and here they are.
n16=0; n16names=""
for sc16 in lcars-file/file.sh lcars-log/log.sh lcars-run/run.sh \
            lcars-respond/respond.sh lcars-resolve-logs/resolve-logs.sh; do
  o16="$(xech d1 "$R16" exec "$sc16" --mission m-mine 2>&1)"
  if printf '%s' "$o16" | grep -q 'IS NOT A SCRIPT A SUB-ECH MAY REACH'; then
    n16=$((n16+1)); n16names="$n16names $sc16"
  fi
done
check "16c. [control] all five documented delegate scripts still REACH their work" \
  "[ $n16 -eq 0 ]    # refused:$n16names"
check "16c2. [control] …and the MAIN ECH still reaches every script, including approve" \
  "xech - '$R16' exec lcars-approve/approve.sh --mission m-theirs >/dev/null 2>&1; [ -s '$R16/merged.log' ]"
check "16c3. the brief names the exec allow-list, from the same ONE constant" \
  "grep -q 'lcars-file/file.sh lcars-log/log.sh lcars-run/run.sh lcars-respond/respond.sh lcars-resolve-logs/resolve-logs.sh' '$B7' \
   && grep -q 'SUBECH_EXEC_SCRIPTS=\"lcars-file/file.sh lcars-log/log.sh lcars-run/run.sh lcars-respond/respond.sh lcars-resolve-logs/resolve-logs.sh\"' '$REPO_ROOT/skills/lcars-eeh/ech.sh'"
check "16c4. …and the brief no longer hands a delegate Number One" \
  "! grep -q 'lcars-xo/xo.sh\`$' '$B7'"
# ---- 16d: an ALLOWED script still obeys the chunk ----------------------
R16D="$(fast_chunk_repo)"
d16="$(xech d1 "$R16D" exec lcars-run/run.sh drive --mission m-theirs 2>&1)"; d16rc=$?
check "16d. an allowed script with a \`--mission\` OUTSIDE the chunk is refused" \
  "[ $d16rc -ne 0 ] && printf '%s' \"\$d16\" | grep -q 'NOT IN YOUR CHUNK'"
check "16d2. …and it names the sibling that owns it" \
  "printf '%s' \"\$d16\" | grep -q 'd2'"
check "16d3. [control] …and the SAME script on its OWN chunk still runs" \
  "xech d1 '$R16D' exec lcars-run/run.sh drive --mission m-mine >/dev/null 2>&1"
# ---- 16e: LCARS_ECH_AS IS INHERITED, DELIBERATELY AND MEASURED ----------
# It was the only reason `exec lcars-eeh/ech.sh delegate theirs` was ever
# refused, and nothing stated or tested it. Measured here through an ALLOWED
# script that reports the seat it was handed.
R16E="$(fast_chunk_repo)"
cp "$STUBS/seat-echo.sh" "$EXEC_SKILLS/lcars-run/run.sh"
xech d1 "$R16E" exec lcars-run/run.sh --mission m-mine >/dev/null 2>&1
check "16e. a script \`exec\` runs INHERITS \`LCARS_ECH_AS\` — the property is real" \
  "[ -f '$R16E/seat.txt' ] && grep -q '^SEAT=d1$' '$R16E/seat.txt'"
: >"$R16E/seat.txt"
xech - "$R16E" exec lcars-run/run.sh --mission m-mine >/dev/null 2>&1
check "16e2. [control] …and the MAIN ECH passes no seat, so inheritance is not a leak" \
  "grep -q '^SEAT=NONE$' '$R16E/seat.txt'"
cp "$STUBS/run-makes.sh" "$EXEC_SKILLS/lcars-run/run.sh"
check "16e3. and the doc STATES the property, so it is no longer an accident" \
  "grep -qi 'inherited by a re-entered' '$DOC'"
echo

# =========================================================================
printf '== 17. ONE READER OF \"OPEN\", EVERYWHERE (fix round 3, cure 2) ==\n'
# =========================================================================
# `delegate_is_open` read the record's `status` AND the marker; both accept
# gates read the marker only. Measured disagreeing in OPPOSITE DIRECTIONS at
# once, with the permissive side on the GATES:
#
#   main ECH: record delegates.d1.status done   (instead of `delegate close`)
#     -> marker still present
#     -> both accept gates see owner d1   -> the bug STOPS BLOCKING
#     -> the seat itself: "that sub-ECH is CLOSED" -> refused
R17="$(fast_chunk_repo)"
xech d1 "$R17" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
r17="$(xech - "$R17" record 'delegates.d1.status' done 2>&1)"; r17rc=$?
check "17a. \`record delegates.*\` is REFUSED — a seat's record is not a field to edit" \
  "[ $r17rc -ne 0 ] && printf '%s' \"\$r17\" | grep -qi 'not a key this verb writes'"
check "17a2. …and it names the verbs that DO own a seat" \
  "printf '%s' \"\$r17\" | grep -q 'delegate close'"
check "17a3. …and it wrote nothing: the status is untouched" \
  "! grep -q '\"status\": *\"done\"' '$R17/.git/lcars/autopilot.json'"
# AND THE TWO SURFACES NOW GIVE THE SAME ANSWER, on every documented route.
# Route 1 — `delegate close`.
R17B="$(fast_chunk_repo)"
xech d1 "$R17B" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
xech - "$R17B" delegate close d1 >/dev/null 2>&1
seat17b=0; xech d1 "$R17B" live-check m-mine --type cli >/dev/null 2>&1 || seat17b=1
gate17b=0; printf '%s' "$(xech - "$R17B" land m-mine 2>&1)" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG' && gate17b=1
check "17b. after \`delegate close\`: the SEAT reads closed AND the GATE blocks — one answer" \
  "[ $seat17b -eq 1 ] && [ $gate17b -eq 1 ]"
# Route 2 — the marker removed on its own (what `init --force` does).
R17C="$(fast_chunk_repo)"
xech d1 "$R17C" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
rm -f "$R17C/.git/lcars/delegates/d1/OPEN"
seat17c=0; xech d1 "$R17C" live-check m-mine --type cli >/dev/null 2>&1 || seat17c=1
gate17c=0; printf '%s' "$(xech - "$R17C" land m-mine 2>&1)" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG' && gate17c=1
check "17c. marker gone: the SEAT reads closed AND the GATE blocks — the same one answer" \
  "[ $seat17c -eq 1 ] && [ $gate17c -eq 1 ]"
check "17c2. …and the seat's refusal names the marker, not a record field" \
  "printf '%s' \"\$(xech d1 '$R17C' live-check m-mine --type cli 2>&1)\" | grep -q 'OPEN'"
# THE CONTROL: with the seat genuinely open, BOTH surfaces say open.
R17D="$(fast_chunk_repo)"
xech d1 "$R17D" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
check "17d. [control] seat open: the SEAT works AND the GATE lets it through" \
  "xech d1 '$R17D' live-check m-mine --type cli >/dev/null 2>&1 \
   && ! printf '%s' \"\$(xech - '$R17D' land m-mine 2>&1)\" | grep -q 'BLOCKED BY UNOWNED LOGGED BUG'"
check "17e. \`delegate_is_open\` has NO reader of its own any more" \
  "[ \"\$(awk '/^delegate_is_open\(\) \{/,/^\}/' '$SCRIPT' | grep -c 'ap_j')\" = 0 ]"
echo

# =========================================================================
printf '== 10. REGRESSION GUARD: the delegation.test.sh invariants this diff touches ==\n'
# =========================================================================
# `tests/delegation.test.sh` takes ~57 minutes and may not be run mid-session,
# and this diff rewrote § 5 and the reserved list of the very brief it pins. So
# the assertions it makes about THOSE LINES are restated here, scoped, and run
# every time this suite runs — the "cures so far" list ORCHESTRATION.md asks a
# fix round to keep green, applied to a neighbouring suite instead of a round.
new_mission "$R1" m-third verify
ech "$R1" record 'missions.third.id' m-third >/dev/null 2>&1
ech "$R1" tier third --tier T2 --why "it needs a fresh tester" >/dev/null 2>&1
ech "$R1" delegate third >/dev/null 2>&1
BT2="$R1/.git/lcars/delegates/d3/BRIEF.md"
check "10a. [precondition] a real T2 brief was minted beside the T1 one" \
  "[ -f '$BT2' ] && [ -f '$B7' ]"
for pair in "T1:d1:$B7" "T2:d3:$BT2"; do
  bt="${pair%%:*}"; rest="${pair#*:}"; bd="${rest%%:*}"; bf="${rest#*:}"
  check "10b.$bt [delegation 8c] the brief still says the ECH will verify, and names live-check" \
    "grep -qi 'the ECH will' '$bf' && grep -qi 'live-check' '$bf'"
  check "10c.$bt [delegation 9d] the exact pinned sentence survives" \
    "grep -qi 'the ECH will verify the work itself' '$bf'"
  check "10d.$bt [delegation 8c] it names file-bug" "grep -q 'file-bug' '$bf'"
  check "10e.$bt [delegation 8c] the hand-back is a REPORT, never a verdict" \
    "grep -qi 'report, never a verdict' '$bf'"
  check "10f.$bt [delegation 8c] Number One is named as the other instrument" \
    "grep -qi 'Number One' '$bf'"
  check "10g.$bt [delegation 9d] verified / approved / landed are all still said" \
    "grep -qi 'verified' '$bf' && grep -qi 'approved' '$bf' && grep -qi 'landed' '$bf'"
  check "10h.$bt [delegation 9d] it carries the 0-of-31 evidence" "grep -q '31' '$bf'"
  check "10i.$bt [delegation 3] the BLOCKED channel is a runnable command" \
    "grep -q 'beat $bd \"BLOCKED' '$bf'"
  check "10j.$bt [delegation 3] it says the ECH READS it" "grep -qi 'the ECH reads' '$bf'"
  check "10k.$bt [delegation 3] it says that channel does not interrupt the captain" \
    "grep -qi 'does not interrupt the captain' '$bf'"
  check "10l.$bt [delegation 3] \`ask\` is in the reserved list" \
    "grep -q 'The ECH keeps these to ITSELF' '$bf' && grep -A3 'The ECH keeps these to ITSELF' '$bf' | grep -q 'ask'"
  check "10m.$bt [delegation 3c] \`file-bug\` is still named there — now as the OUT-OF-CHUNK limit" \
    "grep -A3 'The ECH keeps these to ITSELF' '$bf' | grep -q 'file-bug'"
  check "10n.$bt \`land\` is in the reserved list too" \
    "grep -A3 'The ECH keeps these to ITSELF' '$bf' | grep -q 'land'"
  check "10o.$bt [delegation 3c] the bug-PRD door is still named" \
    "grep -q 'bug-prd.md' '$bf'"
done
check "10p. [delegation 4] §2 does not carry the flat prohibition that contradicts §3" \
  "! grep -qF 'The ECH files these; you do not' '$BT2'"
check "10q. [delegation 4] §3 still says the T2 bug list is FILED THROUGH a verb" \
  "grep -q 'The bug list is FILED THROUGH' '$BT2'"
# DELEGATION.md's own gate section, as delegation.test.sh § D10 pins it.
GATE="$(awk '/^## THE UNCONDITIONAL GATE/,/^## The verbs/' "$DOC")"
check "10r. [delegation D10] the gate section restates no numbered sequence of its own" \
  "[ \"\$(printf '%s\\n' \"\$GATE\" | grep -cE '^[0-9]+\. ' | tr -d ' ')\" = 0 ]"
check "10s. [delegation D10] it still POINTS at HOLOGRAM-COMMAND-MODE.md § 6" \
  "printf '%s' \"\$GATE\" | grep -q 'HOLOGRAM-COMMAND-MODE.md'"
check "10t. [delegation D10] it keeps the sentence that is DELEGATION.md's OWN" \
  "printf '%s' \"\$GATE\" | grep -qi 'report, never a verdict'"
check "10u. [delegation D10] it keeps the 0-of-31 evidence that justifies the rule" \
  "printf '%s' \"\$GATE\" | grep -q '0 of 31'"
check "10v. [delegation D10] the three verbs are still named, so the gate stays findable" \
  "printf '%s' \"\$GATE\" | grep -q 'live-check' && printf '%s' \"\$GATE\" | grep -q 'policy' \
   && printf '%s' \"\$GATE\" | grep -q 'file-bug'"
echo

# --- zero spend, every run ------------------------------------------------
check "15a. ZERO worker spend: no claude/copilot was invoked" \
  "[ ! -s '$LCARS_DRIVE_SHIM_LOG' ]"

echo
printf 'chunk-authority: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
