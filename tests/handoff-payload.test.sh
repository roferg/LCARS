#!/usr/bin/env bash
#
# Tests for the S188 HANDOFF PAYLOAD — the issue as a handoff document.
#
# Skill source:
#   skills/lcars-run/issue-body.sh      lcars_issue_body_compose / _refresh,
#                                       lcars_handoff_envelope / _json / _field /
#                                       _parse
#   skills/lcars-run/host-adapter.sh    the new `issue-edit-body` op
#   skills/lcars-file/file.sh           the four filing lanes, now one composer
#   skills/lcars-run/run.sh             the TWO refresh call sites
#   skills/lcars-run/comment-mirror.sh  cm_mirror_verify_feedback
#   skills/lcars-feedback/feedback.sh   the send-back that fires it
#
# WHY THIS EXISTS. Before S188 the GitHub issue was a WRITE-ONCE artifact: four
# filing lanes each composed a body inline, and nothing ever refreshed one. A
# Verify→Align send-back rewrote prd.md LOCALLY and the issue kept the old spec
# forever, so a second laptop adopting that Mission from GitHub would build the
# wrong thing. And nothing in the body was machine-readable — branch, base, type
# and engine lived only in .git/lcars/state.json, which never leaves the laptop.
#
# So this suite proves four things and their boundaries:
#   1. ONE composer, and its output is BYTE-IDENTICAL to what each lane emitted
#      before the refactor — locked against goldens captured from PRE-session
#      code (tests/fixtures/s188-issue-body/, see its README).
#   2. The `lcars:handoff` envelope round-trips compose→parse, tracks state.json,
#      and does not disturb the human body above it — including the github board
#      adapter's Estimate pill regexes, driven here as the REAL python function.
#   3. The body is refreshed at EXACTLY TWO transfer points (the feedback
#      re-grill completion and Verify entry) and NOWHERE else.
#   4. Verify feedback mirrors as ONE living comment, however many send-backs.
#
# ZERO model spend: `gh` is a recording stub, the estimator is a stub, and every
# worker is a PATH-shimmed no-op. Nothing here talks to a network.
#
# Usage: bash tests/handoff-payload.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_SCRIPT="${LCARS_FILE_SCRIPT:-$REPO_ROOT/skills/lcars-file/file.sh}"
RUN_SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
FEEDBACK_SCRIPT="${LCARS_FEEDBACK_SCRIPT:-$REPO_ROOT/skills/lcars-feedback/feedback.sh}"
IB_LIB="$REPO_ROOT/skills/lcars-run/issue-body.sh"
HOST_ADAPTER="$REPO_ROOT/skills/lcars-run/host-adapter.sh"
GOLDEN_DIR="$REPO_ROOT/tests/fixtures/s188-issue-body"

# The interactive version check would prompt on stdin and fetch LCARS's own
# origin. Kill it for the whole suite (the sanctioned knob).
export LCARS_VERSION_CHECK=0
# Nothing here is about the worker hang guard; its 15s poll would dominate.
export LCARS_WORKER_HANG_SECS=0
export LCARS_WORKER_CLI=claude

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ==========================================================================
# Stubs
# ==========================================================================

# THE RECORDING gh. It records argv, and — this is the point of the suite — it
# RECORDS THE BODY IT WAS HANDED, for both issue bodies and comment bodies, so
# every assertion below is about bytes that actually reached the forge seam.
#
#   $GH_LOG      one line per invocation
#   $GH_OPS      one line per semantic op (ISSUE-CREATE / ISSUE-EDIT-BODY /
#                ISSUE-RELABEL / COMMENT-CREATE / COMMENT-EDIT)
#   $GH_BODYDIR  issue-<seq>  the Nth issue body pushed (create or edit)
#                comment-<id> the current body of that living comment
#
# It models REAL `gh api` field semantics (only -F/--field body=@- reads stdin)
# so an adapter regression to `-f` cannot pass, and it understands
# `--body-file -` because that is exactly how the new issue-edit-body op sends.
make_gh_stub() { # path
  cat >"$1" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >>"$GH_LOG"
ARGS=("$@")
mode=""; path=""; body=""; have_body=0
while [ $# -gt 0 ]; do
  case "$1" in
    POST) mode="POST" ;;
    PATCH) mode="PATCH" ;;
    repos/*|/repos/*) path="$1" ;;
    -F|--field)
      case "$2" in
        body=@-) body="$(cat)"; have_body=1 ;;
        body=*)  body="${2#body=}"; have_body=1 ;;
      esac
      shift ;;
    -f|--raw-field)
      case "$2" in body=*) body="${2#body=}"; have_body=1 ;; esac
      shift ;;
    --body-file)
      case "$2" in -) body="$(cat)"; have_body=1 ;; *) body="$(cat "$2")"; have_body=1 ;; esac
      shift ;;
    --body) body="$2"; have_body=1; shift ;;
  esac
  shift
done

next_issue_seq() {
  n=$(( $(cat "$GH_BODYDIR/.seq" 2>/dev/null || echo 0) + 1 ))
  echo "$n" >"$GH_BODYDIR/.seq"; printf '%s' "$n"
}

set -- "${ARGS[@]}"
case "$1 ${2:-}" in
  "issue create")
    s="$(next_issue_seq)"; printf '%s' "$body" >"$GH_BODYDIR/issue-$s"
    echo "ISSUE-CREATE $s" >>"$GH_OPS"
    echo "https://github.com/owner/repo/issues/42"; exit 0 ;;
  "issue edit")
    if [ "$have_body" -eq 1 ]; then
      s="$(next_issue_seq)"; printf '%s' "$body" >"$GH_BODYDIR/issue-$s"
      echo "ISSUE-EDIT-BODY $3 $s" >>"$GH_OPS"
    else
      echo "ISSUE-RELABEL $3" >>"$GH_OPS"
    fi
    exit 0 ;;
  "pr view"|"pr list")
    printf 'state\tOPEN\nmergedAt\t\n'; exit 0 ;;
  "pr create")
    echo "https://github.com/owner/repo/pull/7"; exit 0 ;;
esac

case "$path" in
  */issues/*/comments|*/issues/comments/*)
    [ "$have_body" -eq 0 ] && body=""
    if [ "$mode" = "POST" ]; then
      n=$(( $(cat "$GH_IDSEQ" 2>/dev/null || echo 100) + 1 ))
      echo "$n" >"$GH_IDSEQ"
      printf '%s' "$body" >"$GH_BODYDIR/comment-$n"
      echo "COMMENT-CREATE $n" >>"$GH_OPS"
      printf '{"id":%s}\n' "$n"
    else
      cid="${path##*/}"
      printf '%s' "$body" >"$GH_BODYDIR/comment-$cid"
      echo "COMMENT-EDIT $cid" >>"$GH_OPS"
      printf '{"id":%s}\n' "$cid"
    fi
    ;;
esac
exit 0
EOF
  chmod +x "$1"
}

# The estimator driver stub: `estimate` writes a canonical estimate.json; every
# OTHER subcommand (render-estimate) is forwarded to the REAL run.sh, so the
# "## Estimate" section in these bodies is rendered by the one real renderer.
make_estimator_stub() { # path
  cat >"$1" <<EOF
#!/usr/bin/env bash
sub="\$1"; ALL=("\$@"); shift
mid=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    --mission) mid="\${2:-}"; shift 2 ;;
    --mission=*) mid="\${1#--mission=}"; shift ;;
    *) shift ;;
  esac
done
gitdir="\$(git rev-parse --git-common-dir 2>/dev/null)" || exit 1
case "\$gitdir" in /*) : ;; *) gitdir="\$PWD/\$gitdir" ;; esac
mdir="\$gitdir/lcars/missions/\$mid"
[ -d "\$mdir" ] || exit 1
if [ "\$sub" = "estimate" ]; then
  cat >"\$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "high",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "sonnet", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
JSON
  exit 0
fi
exec bash "$RUN_SCRIPT" "\${ALL[@]}"
EOF
  chmod +x "$1"
}

# A PATH shim faking BOTH engines, so no leg can reach a real CLI even if a
# persisted state.json workerBin beats the env var (S159's measured failure).
make_engine_shims() { # dir
  mkdir -p "$1"
  local e
  for e in claude copilot; do
    cat >"$1/$e" <<'EOF'
#!/usr/bin/env bash
role="${LCARS_WORKER_ROLE:-}"
out="${LCARS_WORK_OUT:-}"
[ -n "$out" ] || exit 0
case "$role" in
  research-questions) : >"$out/questions.txt" ;;
  context-pack)       printf '# Context pack\n\nStub.\n' >"$out/context-pack.md" ;;
  validate)
    cat >"$out/validated-plan.md" <<MD
# Validated Plan: Add an /about route

## Synthesis
Wire the route into the existing router.

## Decisions
- Reuse the existing router table.

## Rationale
The router already resolves every other page; one more entry is the whole change.
MD
    ;;
esac
exit 0
EOF
    chmod +x "$1/$e"
  done
}

NOTIFY_STUB="$TMPROOT/notify"; printf '#!/usr/bin/env bash\nexit 0\n' >"$NOTIFY_STUB"; chmod +x "$NOTIFY_STUB"
ESTIMATOR_STUB="$TMPROOT/estimate-run.sh"; make_estimator_stub "$ESTIMATOR_STUB"
SHIM_DIR="$TMPROOT/shims"; make_engine_shims "$SHIM_DIR"

# ==========================================================================
# Fixtures
# ==========================================================================
new_repo() {
  local repo; repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  cat >"$repo/.git/lcars/config.json" <<'EOF'
{ "cloneId": "c10ec10ec10ec10ec10ec10ec10ec10e", "model": "claude-sonnet", "projectName": "repo", "contextFile": null, "testCommand": "true", "created": "2026-05-30T00:00:00Z" }
EOF
  printf '# Context pack\n\nA fixture repo.\n' >"$repo/.git/lcars/context-pack.md"
  make_gh_stub "$repo/gh"
  mkdir -p "$repo/bodies"
  echo "$repo"
}

# Point every recorder at this repo's own files, then run something.
use_repo() { # repo
  export GH_LOG="$1/gh.log"; : >"$GH_LOG"
  export GH_OPS="$1/gh.ops"; : >"$GH_OPS"
  export GH_BODYDIR="$1/bodies"; rm -rf "$GH_BODYDIR"; mkdir -p "$GH_BODYDIR"
  export GH_IDSEQ="$1/gh.idseq"; : >"$GH_IDSEQ"
}

write_prd() { # path [title]
  cat >"$1" <<EOF
# Mission: ${2:-Fix the broken /about route}

**Type:** bug
**Goal:** The /about route should resolve to the About page instead of 404ing.
**Acceptance Criteria:**
- GET /about returns HTTP 200
- The About page renders its heading
**Out of Scope:**
- Redesigning the About page
**Constraints:**
- Existing router; no new dependencies
EOF
}

write_adr() { # path
  cat >"$1" <<'EOF'
## ADR-001: reuse the existing router

**Context:** The app already ships a router; the /about route is simply unmapped.
**Decision:** Reuse the existing router and register the missing route.
**Alternatives considered:** A second router (rejected: duplicate state).
**Consequences:** No new dependency; one new route registration.
EOF
}

# S196 — `cloneId` PINS THE FINGERPRINT so this suite's expected ids stay
# literal. Mission ids are now `lcars-YYYYMMDD-NNN-<fp>`, where <fp> is the
# first 4 hex of the clone's own `cloneId` (a UUID4 minted on first use, so two
# clones of one repo can never mint the same id — see lcars_clone_id in
# skills/lcars-init/lcars-common.sh). Pinning it makes <fp> the constant `c10e`;
# the lazy-acquisition and old-format-compatibility proofs live in
# tests/mission-id.test.sh.
MID="lcars-20260530-001-c10e"
mdir() { printf '%s/.git/lcars/missions/%s' "$1" "$MID"; }

# file <repo> [args…] — one filing lane invocation with everything pinned.
file_it() {
  local repo="$1"; shift
  # FILE_RUN_BIN lets a leg file a mission with NO estimator at all (an absent
  # estimate.json ⇒ no "## Estimate" section on the filed body) — the precondition
  # NEW-1 needs. Unset ⇒ the canned estimator, exactly as before.
  ( cd "$repo"
    PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$repo/gh" LCARS_RUN_BIN="${FILE_RUN_BIN:-$ESTIMATOR_STUB}" \
      LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
      bash "$FILE_SCRIPT" "$@" >"$repo/file.out" 2>&1 )
}

# nops <OP> — how many of that semantic op the stub recorded.
# `grep -c` ALREADY prints 0 and exits 1 on no match, so a `|| echo 0` fallback
# emits "0\n0" and every `= 0` assertion fails for the wrong reason. Swallow the
# rc instead; the count is grep's own stdout.
nops() { local n; n="$(grep -c "^$1" "$GH_OPS" 2>/dev/null)" || true; printf '%s' "${n:-0}"; }
last_issue_body() {
  local last; last="$(ls "$GH_BODYDIR" 2>/dev/null | grep '^issue-' | sed 's/issue-//' | sort -n | tail -1)"
  [ -n "$last" ] && cat "$GH_BODYDIR/issue-$last"
}

echo "handoff payload (S188)"
[ -f "$IB_LIB" ] || { echo "composer library not found at $IB_LIB"; exit 1; }

# ==========================================================================
# BEHAVIOUR 1 — composer parity: every lane byte-identical to PRE-session
# ==========================================================================
echo "  -- 1. composer parity (goldens captured from pre-S188 code)"

# golden_prefix <recorded-body> <golden> — the recorded body must START with the
# golden's exact bytes. This is the whole invariant: the visible body did not
# move, only an envelope was appended after it.
#
# S196 — ONE normalisation, and only in the direction of the golden: the
# MISSION ID. `laneA-park.body` quotes the mission in its STANDBY line ("Run
# `lcars file <id>`"), and S196 WIDENED the id itself
# (`lcars-YYYYMMDD-NNN` → `…-NNN-<fp>`, a per-clone fingerprint so two laptops
# cannot mint one name for one shared branch). That is a deliberate change to
# the id, not drift in the composer, and the goldens' README forbids editing a
# golden to match new output — so the golden stays byte-for-byte as captured
# and its old-format id is rewritten to $MID at COMPARE time. Every other byte
# is still compared exactly, and a golden with no id in it is untouched by this.
golden_prefix() { # recorded golden
  local norm; norm="$(mktemp)"
  sed "s/lcars-20260530-001/$MID/g" "$2" >"$norm"
  local n; n="$(wc -c <"$norm" | tr -d ' ')"
  cmp -s <(head -c "$n" "$1") "$norm"
  local rc=$?
  rm -f "$norm"
  return $rc
}

# --- lane 4: grill-first --prd --adr, with an estimate ---------------------
r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"; write_adr "$r/a.md"
file_it "$r" --prd "$r/p.md" --adr "$r/a.md"
D4="$GH_BODYDIR/issue-1"
check "1. lane 4 (grill-first prd+adr+estimate) opened an issue" "[ -f '$D4' ]"
check "1. lane 4 body is byte-identical to the pre-S188 golden (modulo envelope)" \
  "golden_prefix '$D4' '$GOLDEN_DIR/laneD-prd-adr-est.body'"
check "1. lane 4 body appends exactly one envelope line" \
  "[ \"\$(grep -c 'lcars:handoff' '$D4')\" = 1 ]"
check "1. lane 4 envelope is the LAST line of the body" \
  "tail -1 '$D4' | grep -q '^<!-- lcars:handoff v1 .* -->\$'"
LANE4_BODY="$TMPROOT/lane4.body"; cp "$D4" "$LANE4_BODY"

# --- lane 4b: grill-first --prd only (no adr, no estimate) -----------------
r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"
( cd "$r"
  PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$r/gh" LCARS_RUN_BIN="/nonexistent" \
    LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --prd "$r/p.md" >"$r/file.out" 2>&1 )
check "1. lane 4 (prd only, no estimate) is byte-identical to the pre-S188 golden" \
  "golden_prefix '$GH_BODYDIR/issue-1' '$GOLDEN_DIR/laneD-prd-only.body'"

# --- lane 1 (park) + lane 2 (--complete over an existing issue) ------------
r="$(new_repo)"; use_repo "$r"
file_it "$r" --park "Make the /about route work again
second line of the idea"
check "1. lane 1 (park) is byte-identical to the pre-S188 golden" \
  "golden_prefix '$GH_BODYDIR/issue-1' '$GOLDEN_DIR/laneA-park.body'"
PARK_BODY="$TMPROOT/park.body"; cp "$GH_BODYDIR/issue-1" "$PARK_BODY"

write_prd "$r/p.md"; write_adr "$r/a.md"
file_it "$r" --complete "$MID" --prd "$r/p.md" --adr "$r/a.md"
check "1. lane 2 (--complete, issue exists) edits the body in place" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" -ge 1 ]"
check "1. lane 2 body is byte-identical to the pre-S188 golden" \
  "golden_prefix '$GH_BODYDIR/issue-2' '$GOLDEN_DIR/laneB-complete-edit.body'"
check "1. lane 2 and lane 4 emit the same bytes for the same inputs" \
  "cmp -s '$GH_BODYDIR/issue-2' '$LANE4_BODY'"

# --- lane 3 (--complete with NO issue: gh was down at park time) -----------
r="$(new_repo)"; use_repo "$r"
( cd "$r"
  PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="/nonexistent/gh" LCARS_RUN_BIN="$ESTIMATOR_STUB" \
    LCARS_DATE="20260530" LCARS_NOW="2026-05-30T00:00:00Z" \
    bash "$FILE_SCRIPT" --park "no gh at park time" >"$r/park.out" 2>&1 )
write_prd "$r/p.md"
file_it "$r" --complete "$MID" --prd "$r/p.md"
check "1. lane 3 (--complete, no issue yet) CREATES the issue" \
  "[ \"\$(nops ISSUE-CREATE)\" = 1 ]"
check "1. lane 3 body is byte-identical to the pre-S188 golden" \
  "golden_prefix '$GH_BODYDIR/issue-1' '$GOLDEN_DIR/laneC-complete-create.body'"

# ==========================================================================
# BEHAVIOUR 2 — the github board adapter still reads a composed body
# ==========================================================================
echo "  -- 2. _pills_from_body still matches a composed body"

# Drive the REAL python function over the REAL composed body. Re-implementing
# the regexes here in bash would prove nothing about the adapter.
PILLS="$(cd "$REPO_ROOT/web" && LANE4_BODY="$LANE4_BODY" python3 - <<'PY' 2>&1
import os, sys, json
sys.path.insert(0, ".")
from lcars_serve.github_adapter import _pills_from_body
body = open(os.environ["LANE4_BODY"], encoding="utf-8").read()
p = _pills_from_body(body)
print(json.dumps({
    "reasoning": (p["reasoning"] or {}).get("level"),
    "implementation": (p["implementation"] or {}).get("level"),
    "cost": bool(p["cost"]),
}))
PY
)"
check "2. _pills_from_body reads the reasoning pill from a composed body" \
  "printf '%s' \"\$PILLS\" | grep -q '\"reasoning\": \"low\"'"
check "2. _pills_from_body reads the implementation pill from a composed body" \
  "printf '%s' \"\$PILLS\" | grep -q '\"implementation\": \"high\"'"
check "2. _pills_from_body still finds a cost in a composed body" \
  "printf '%s' \"\$PILLS\" | grep -q '\"cost\": true'"

# The envelope must be INVISIBLE to the estimate scrape — it is an HTML comment,
# and it must never introduce a second pill match.
check "2. the envelope adds no second 'reasoning =' match" \
  "[ \"\$(grep -c 'reasoning' '$LANE4_BODY')\" = 1 ]"

# ==========================================================================
# BEHAVIOUR 6 — envelope round-trip, and pre-round bodies parse EMPTY
# ==========================================================================
echo "  -- 6. envelope round-trips compose→parse; a pre-round body parses empty"

# Source the library directly — this is exactly how S189 will import the parser.
env_probe() { # body-file key
  bash -c '. "$1"; lcars_handoff_field "$2" "$3"' _ "$IB_LIB" "$2" "$3"
}
check "6. round-trip: id" \
  "[ \"\$(env_probe x '$LANE4_BODY' id)\" = '$MID' ]"
check "6. round-trip: branch" \
  "[ \"\$(env_probe x '$LANE4_BODY' branch)\" = 'lcars/$MID' ]"
check "6. round-trip: base" \
  "[ \"\$(env_probe x '$LANE4_BODY' base)\" = 'main' ]"
check "6. round-trip: type" \
  "[ \"\$(env_probe x '$LANE4_BODY' type)\" = 'bug' ]"
check "6. round-trip: attachments is a count" \
  "[ \"\$(env_probe x '$LANE4_BODY' attachments)\" = '0' ]"
check "6. an aligned body is NOT marked parked" \
  "[ -z \"\$(env_probe x '$LANE4_BODY' parked)\" ]"
check "6. a PARK body carries parked=true" \
  "[ \"\$(env_probe x '$PARK_BODY' parked)\" = 'true' ]"
check "6. a PARK body has no type (null, not empty-string noise)" \
  "[ -z \"\$(env_probe x '$PARK_BODY' type)\" ]"
check "6. the schema version is stamped v1" \
  "[ \"\$(bash -c '. \"\$1\"; lcars_handoff_version \"\$2\"' _ '$IB_LIB' '$LANE4_BODY')\" = 'v1' ]"

PARSED="$(bash -c '. "$1"; lcars_handoff_parse "$2"' _ "$IB_LIB" "$LANE4_BODY")"
# S196 A5 — 7 identity keys + the ESTIMATE PILL FACTS the envelope now records.
# This fixture's estimate.json carries the two criticalities and NO cost block,
# so exactly `estReasoning` + `estImpl` ride along: 9. (Was 7 before this
# session; the number moved because the contract did, not because the parser
# drifted — see the additive-within-v1 note in lcars_handoff_envelope.)
check "6. parse emits one key=value line per envelope key" \
  "[ \"\$(printf '%s\n' \"\$PARSED\" | wc -l | tr -d ' ')\" = 9 ]"

# WHY THE ESTIMATE IS IN THE ENVELOPE AT ALL. A REMOTE card's cost + difficulty
# pills are scraped out of the human "## Estimate" section by the github board
# adapter — and `lcars adopt` is forbidden from doing the same (it never reads
# the captain's prose), so adopting a mission USED TO make all three pills
# vanish. Recorded fields, read by key, are the only honest source.
check "6. round-trip: the reasoning criticality is a RECORDED field" \
  "[ \"\$(env_probe x '$LANE4_BODY' estReasoning)\" = 'low' ]"
check "6. round-trip: so is the implementation criticality" \
  "[ \"\$(env_probe x '$LANE4_BODY' estImpl)\" = 'high' ]"
check "6. an estimate with no cost block records NO cost keys (absent, not zero)" \
  "[ -z \"\$(env_probe x '$LANE4_BODY' estCostUnit)\" ] && [ -z \"\$(env_probe x '$LANE4_BODY' estCostLow)\" ]"
check "6. a PARK body (no estimate at all) carries no estimate keys" \
  "[ -z \"\$(env_probe x '$PARK_BODY' estReasoning)\" ] && [ -z \"\$(env_probe x '$PARK_BODY' estImpl)\" ]"
check "6. parse emits a null field as an EMPTY value, not a missing line" \
  "printf '%s' \"\$PARSED\" | grep -q '^parentIssue	\$'"

# A body from BEFORE this round — no envelope anywhere.
PRE="$TMPROOT/pre-round.body"
printf '# Mission: an issue filed last month\n\n**Type:** feature\n' >"$PRE"
PREPARSE="$(bash -c '. "$1"; lcars_handoff_parse "$2"' _ "$IB_LIB" "$PRE"; printf 'rc=%s' "$?")"
check "6. a body with NO envelope parses to EMPTY, and exits 0 (never an error)" \
  "[ \"\$PREPARSE\" = 'rc=0' ]"
check "6. a field read on a body with no envelope is empty, not an error" \
  "[ -z \"\$(env_probe x '$PRE' branch)\" ]"

# The envelope must track state.json, not a guess. Compose with an engine pinned
# and prove it lands.
r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"
file_it "$r" --prd "$r/p.md" --engine copilot
check "6. the envelope's engine comes from the workerBin resolution" \
  "[ \"\$(env_probe x '$GH_BODYDIR/issue-1' engine)\" = 'copilot' ]"
check "6. that engine is the one state.json persisted" \
  "grep -q '\"workerBin\": *\"copilot\"' '$(mdir "$r")/state.json'"

# attachments > 0 exists so a later adopt can WARN (no issue-asset upload API).
r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"
printf 'a mockup\n' >"$r/mock.png"
file_it "$r" --prd "$r/p.md" --attach "$r/mock.png"
check "6. the envelope counts durable attachments" \
  "[ \"\$(env_probe x '$GH_BODYDIR/issue-1' attachments)\" = '1' ]"

# ==========================================================================
# BEHAVIOUR 3 — the re-grill completion is a transfer point; stages are not
# ==========================================================================
echo "  -- 3. re-grill completion fires ONE body edit; mid-flight stages fire ZERO"

# STRUCTURAL LOCK first: there are exactly TWO refresh call sites in the whole
# skill tree, and they are the two the composer's header names. This is the
# invariant a future stage-level "just refresh here too" would break silently.
# Count only CALLS — `lcars_issue_body_refresh "` with an argument — so the
# library's own definition, its header prose, and the lazy loader's
# `command -v` probes do not inflate the number.
SITES="$(grep -rn 'lcars_issue_body_refresh "' "$REPO_ROOT/skills" \
          | grep -v 'skills/lcars-run/issue-body.sh' | wc -l | tr -d ' ')"
check "3. exactly TWO refresh call sites exist outside the library" "[ \"\$SITES\" = 2 ]"
check "3. one of them is the align re-entry finisher (cmd_research)" \
  "awk '/^cmd_research\(\)/,/^}/' '$RUN_SCRIPT' | grep -q 'lcars_issue_body_refresh'"
check "3. the other is Verify entry (drive_verify)" \
  "awk '/^drive_verify\(\)/,/^}/' '$RUN_SCRIPT' | grep -q 'lcars_issue_body_refresh'"

r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"
file_it "$r" --prd "$r/p.md"
: >"$GH_OPS"   # the filing lane's own create is not a refresh — start clean.

# A Verify send-back: stage back to align, feedback.md on disk.
( cd "$r"
  LCARS_GH_BIN="$r/gh" LCARS_NOW="2026-05-30T01:00:00Z" \
    bash "$FEEDBACK_SCRIPT" --mission "$MID" --feedback "The heading is wrong — it must read About Us." \
    >"$r/fb1.out" 2>&1 )
check "3. a send-back alone edits NO issue body (the re-grill has not happened)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ]"

# THE RE-GRILL: the host CLI rewrites prd.md against feedback.md. That is the
# interactive half; what we drive is the FINISHER — reaching Research.
write_prd "$r/p2.md" "Fix the /about route AND its heading"
printf '\n**Correction:** the heading must read About Us.\n' >>"$r/p2.md"
cp "$r/p2.md" "$(mdir "$r")/prd.md"

( cd "$r"
  PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$r/gh" LCARS_WORKER_BIN="$SHIM_DIR/claude" \
    LCARS_NOTIFY="$NOTIFY_STUB" LCARS_BASE_FRESHNESS=0 \
    bash "$RUN_SCRIPT" research --mission "$MID" >"$r/research.out" 2>&1 )

check "3. the re-grill completion fires EXACTLY ONE issue-edit-body" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
REGRILLED="$(last_issue_body >"$TMPROOT/regrilled.body"; echo "$TMPROOT/regrilled.body")"
check "3. the refreshed body carries the NEW PRD" \
  "grep -q 'About Us' '$REGRILLED'"
check "3. the refreshed body carries an envelope" \
  "grep -q 'lcars:handoff v1' '$REGRILLED'"
check "3. the refreshed envelope still matches state.json" \
  "[ \"\$(env_probe x '$REGRILLED' branch)\" = \"\$(sed -n 's/.*\"branch\": *\"\\([^\"]*\\)\".*/\\1/p' '$(mdir "$r")/state.json' | head -1)\" ]"

# MID-FLIGHT: the very next Stage must NOT touch the body. Research advanced the
# Mission to validate; step it once more and prove the count did not move.
( cd "$r"
  PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$r/gh" LCARS_WORKER_BIN="$SHIM_DIR/claude" \
    LCARS_NOTIFY="$NOTIFY_STUB" LCARS_BASE_FRESHNESS=0 \
    bash "$RUN_SCRIPT" drive --mission "$MID" --step >"$r/step.out" 2>&1 )
check "3. a mid-flight Stage fires ZERO further body edits (stale by design)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"

# ==========================================================================
# BEHAVIOUR 4 — Verify entry refreshes; a re-entry is idempotent
# ==========================================================================
echo "  -- 4. Verify entry refreshes; a re-entry does not spam"

r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"
file_it "$r" --prd "$r/p.md"
: >"$GH_OPS"
M="$(mdir "$r")"
# Park the Mission at Verify with a PR already open, so drive_verify takes its
# poll path (no reconcile, no PR open) and the ONLY thing under test is the
# entry refresh.
python3 - "$M/state.json" <<'PY'
import json, sys, re
p = sys.argv[1]
s = open(p).read()
s = re.sub(r'"stage": *"[^"]*"', '"stage": "verify"', s)
s = s.replace('"githubIssue"', '"prUrl": "https://github.com/owner/repo/pull/7",\n  "githubIssue"', 1)
open(p, "w").write(s)
PY
check "4. fixture is parked at verify with a PR recorded" \
  "grep -q '\"stage\": *\"verify\"' '$M/state.json' && grep -q 'prUrl' '$M/state.json'"

drive_once() {
  ( cd "$r"
    PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$r/gh" LCARS_WORKER_BIN="$SHIM_DIR/claude" \
      LCARS_NOTIFY="$NOTIFY_STUB" LCARS_BASE_FRESHNESS=0 \
      bash "$RUN_SCRIPT" drive --mission "$MID" --step >"$r/verify.$1.out" 2>&1 )
}
drive_once 1
check "4. Verify entry refreshes the body (exactly one edit)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
VBODY="$TMPROOT/verify.body"; last_issue_body >"$VBODY"
check "4. the Verify body carries the envelope" "grep -q 'lcars:handoff v1' '$VBODY'"
COMMENTS_AFTER_1="$(nops COMMENT-CREATE)"

drive_once 2
check "4. a Verify re-entry does NOT re-push an identical body (no edit spam)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
# The S65 mirror owns the per-stage comments; the point here is that a SECOND
# pass through the refresh adds none of its own on top of them.
check "4. a Verify re-entry creates no additional comment" \
  "[ \"\$(nops COMMENT-CREATE)\" = \"\$COMMENTS_AFTER_1\" ]"

# But a body that ACTUALLY changed must still be pushed on re-entry — the skip is
# content-addressed, not a one-shot latch.
printf '\n**Amendment:** the About page also needs a footer.\n' >>"$M/prd.md"
drive_once 3
check "4. a Verify re-entry DOES push when the body genuinely changed" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 2 ]"
last_issue_body >"$TMPROOT/verify2.body"
check "4. the re-pushed body carries the amendment" \
  "grep -q 'needs a footer' '$TMPROOT/verify2.body'"

# A push that FAILED must not record a false 'pushed' marker — the next transfer
# point has to retry it.
check "4. a successful push records the dedup marker" "[ -f '$M/.issue-body.sha' ]"
rm -f "$M/.issue-body.sha"
FAILGH="$r/gh-fail"; printf '#!/usr/bin/env bash\nexit 7\n' >"$FAILGH"; chmod +x "$FAILGH"
( cd "$r"
  PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$FAILGH" LCARS_WORKER_BIN="$SHIM_DIR/claude" \
    LCARS_NOTIFY="$NOTIFY_STUB" LCARS_BASE_FRESHNESS=0 \
    bash "$RUN_SCRIPT" drive --mission "$MID" --step >"$r/verify.fail.out" 2>&1 )
check "4. a FAILED push records no marker, so the next transfer point retries" \
  "[ ! -f '$M/.issue-body.sha' ]"

# ==========================================================================
# BEHAVIOUR 5 — two send-backs, ONE living comment carrying both
# ==========================================================================
echo "  -- 5. two Verify send-backs → ONE living comment with both entries"

r="$(new_repo)"; use_repo "$r"
write_prd "$r/p.md"
file_it "$r" --prd "$r/p.md"
: >"$GH_OPS"
M="$(mdir "$r")"

send_back() { # note now
  ( cd "$r"
    LCARS_GH_BIN="$r/gh" LCARS_NOW="$2" \
      bash "$FEEDBACK_SCRIPT" --mission "$MID" --feedback "$1" >>"$r/fb.out" 2>&1 )
}
send_back "The heading is wrong — it must read About Us." "2026-05-30T01:00:00Z"
check "5. the FIRST send-back CREATES the comment (that create is the ping)" \
  "[ \"\$(nops COMMENT-CREATE)\" = 1 ]"
check "5. the first send-back edits nothing in place" "[ \"\$(nops COMMENT-EDIT)\" = 0 ]"

# Back to verify, then bounce again.
python3 - "$M/state.json" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r'"stage": *"[^"]*"', '"stage": "verify"', s))
PY
send_back "The footer is missing its copyright line." "2026-05-30T02:00:00Z"
check "5. the SECOND send-back creates NO second comment" \
  "[ \"\$(nops COMMENT-CREATE)\" = 1 ]"
check "5. the second send-back PATCHes the same comment in place" \
  "[ \"\$(nops COMMENT-EDIT)\" = 1 ]"

CID="$(grep '^COMMENT-CREATE' "$GH_OPS" | head -1 | awk '{print $2}')"
CBODY="$GH_BODYDIR/comment-$CID"
check "5. the one comment is headed '## Verify feedback'" \
  "head -1 '$CBODY' | grep -q '^## Verify feedback\$'"
check "5. it carries the FIRST entry verbatim" "grep -q 'must read About Us' '$CBODY'"
check "5. it carries the SECOND entry verbatim" "grep -q 'missing its copyright line' '$CBODY'"
check "5. both entries keep their send-back stamps, in order" \
  "[ \"\$(grep -c '^## Feedback — ' '$CBODY')\" = 2 ]"
check "5. the comment mirrors feedback.md exactly (no re-editing of history)" \
  "grep -q 'must read About Us' '$M/feedback.md' && grep -q 'missing its copyright line' '$M/feedback.md'"
check "5. comments.json records the ONE living comment id" \
  "grep -q '\"verify-feedback\"' '$M/comments.json'"
check "5. a send-back never edits the issue BODY (that is not a transfer point)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ]"

# ==========================================================================
# BEHAVIOUR 7 — PART-AWARE COMPOSITION  (S188 fix round 2)
# ==========================================================================
# Fix round 1 answered D1/D3/D4 with a WHOLE-BODY HEURISTIC: recompose, then
# compare the finished text against the last pushed body and refuse when it
# "looked" lossy (under half the size, fewer `^---$` rules, a missing marker).
# A fresh tester beat it four ways in one evening — it false-refused a PRD that
# dropped its own horizontal rule, permanently and silently refused an honest
# 60→3 criteria scope cut, and disarmed itself entirely when the baseline file
# was missing (which the park lane never wrote). That is the same five-round
# death spiral S157's anti-gutting guard died in, and it was cured there the
# same way it is cured here: DELETE the inference.
#
# The composer knows exactly which parts it assembles. So each part's presence
# is now a FACT ABOUT ITS SOURCE, decided BEFORE anything is composed:
#
#   part        source            rebuildable        carried forward   required
#   provenance  state.json        origin=log+parent  from the baseline no
#   spec        prd.md            non-empty          never             YES
#   adr         adr.md            present            from the baseline no
#   estimate    estimate.json     renders            from the baseline no*
#
#   * the estimate is required when the refresh cannot PROVE the issue has none
#     — losing it takes all three board pills with it (D4).
#
# Nothing measures the finished text. There is no ratio, no separator count and
# no "is this loss legitimate?" question anywhere, because nothing can answer it.
echo "  -- 7. part-aware composition: every part is rebuilt, carried forward, or named"

# --- 7.0 the DELETED mechanism stays deleted -------------------------------
check "7. the whole-body regression guard is GONE (no lcars_ib_regression)" \
  "! grep -q 'lcars_ib_regression' '$IB_LIB'"
check "7. no separator counting survives (N1: it counted the PRD's own rules)" \
  "! grep -q \"grep -c '\\^---\\\$'\" '$IB_LIB'"
check "7. no size-ratio rule survives (N2: it refused honest scope cuts)" \
  "! grep -qE 'nn \\* 2|\\* 2\\)\\) -lt' '$IB_LIB'"
check "7. run.sh still calls the refresh best-effort at both sites (|| true)" \
  "[ \"\$(grep -c 'lcars_issue_body_refresh \"\$MISSION_DIR\" >/dev/null 2>&1 || true' '$RUN_SCRIPT')\" = 2 ]"

# --- the fixture: a filed, aligned mission parked one step from Verify ------
# `mkm <repo> [--adr]` files a mission and points its stage at verify, so ONE
# `drive --step` runs the Verify-entry transfer point and nothing else.
mkm() { # repo [prd-path] [adr-path]
  local repo="$1" prd="${2:-}" adr="${3:-}"
  use_repo "$repo"
  [ -n "$prd" ] || { prd="$repo/p.md"; write_prd "$prd"; }
  if [ -n "$adr" ]; then file_it "$repo" --prd "$prd" --adr "$adr"
  else file_it "$repo" --prd "$prd"; fi
  python3 - "$(mdir "$repo")/state.json" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'"stage": *"[^"]*"', '"stage": "verify"', s)
s = s.replace('"githubIssue"', '"prUrl": "https://github.com/owner/repo/pull/7",\n  "githubIssue"', 1)
open(p, "w").write(s)
PY
  : >"$GH_OPS"
}
# re-arm the Verify entry for a SECOND pass on the same mission
reverify() { python3 - "$1/state.json" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r'"stage": *"[^"]*"', '"stage": "verify"', s))
PY
}
drive1() { # repo
  ( cd "$1"
    PATH="$SHIM_DIR:$PATH" LCARS_GH_BIN="$1/gh" LCARS_WORKER_BIN="$SHIM_DIR/claude" \
      LCARS_RUN_BIN="$ESTIMATOR_STUB" LCARS_ISSUE_BODY_RUN_BIN="$ESTIMATOR_STUB" \
      LCARS_NOTIFY="$NOTIFY_STUB" LCARS_BASE_FRESHNESS=0 \
      bash "$RUN_SCRIPT" drive --mission "$MID" --step >"$1/drive.out" 2>&1 )
}
pills() { # body-file → the three pills as JSON, via the REAL github adapter
  ( cd "$REPO_ROOT/web" && python3 -c '
import sys, json; sys.path.insert(0, ".")
from lcars_serve import github_adapter as ga
print(json.dumps(ga._pills_from_body(open(sys.argv[1]).read())))' "$1" )
}

# --- 7.1 CARRY-FORWARD: estimate.json is gone; the section SURVIVES (D4) ----
# The round-1 cure REFUSED here, which left the issue carrying the OLD spec.
# The part model REBUILDS the spec and CARRIES the Estimate section forward, so
# the push happens AND nothing is lost. That is the difference.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -f "$M/estimate.json"
printf '\n**Amended:** the re-grill added this line.\n' >>"$M/prd.md"
drive1 "$r"
check "7. D4: a missing estimate.json still PUSHES the new spec" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "7. D4: and the pushed body still carries the '## Estimate' section" \
  "last_issue_body | grep -q '^## Estimate\$'"
check "7. D4: the pushed body carries the amended spec" \
  "last_issue_body | grep -q 'the re-grill added this line'"
last_issue_body >"$TMPROOT/d4.body"
check "7. D4: all THREE board pills survive on the real github adapter" \
  "[ \"\$(pills '$TMPROOT/d4.body' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for v in d.values() if v))')\" = 3 ]"
check "7. D4: a carried-forward part is NOT a refusal (no breadcrumb)" \
  "[ ! -f '$M/.issue-body.refused' ]"
check "7. D4: a successful push records the dedup marker" "[ -f '$M/.issue-body.sha' ]"

# --- 7.2 the SPEC is the one REQUIRED part ---------------------------------
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
: >"$M/prd.md"                       # an interrupted re-grill wrote nothing
drive1 "$r"
check "7. D3: a 0-byte prd.md pushes NOTHING (the spec is not wiped)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ]"
check "7. D3: and records no marker, so a later transfer point can heal" \
  "[ ! -f '$M/.issue-body.sha' ]"
check "7. D3: the refusal NAMES the part it could not build" \
  "grep -q 'the spec' '$M/.issue-body.refused'"
check "7. D3: the drive did not fail on the refusal" \
  "grep -qv 'no such' '$r/drive.out'"
# …and a mission with NO prd.md at all is not a fault, it is un-aligned.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -f "$M/prd.md"
drive1 "$r"
check "7. an un-aligned mission (no prd.md at all) is silent, not a refusal" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ] && [ ! -f '$M/.issue-body.refused' ]"

# --- 7.3 N2: an HONEST HARD SCOPE CUT now pushes ---------------------------
# The tester's measured case: 60 acceptance criteria re-grilled down to 3
# (5764 → 1096 bytes, ratio 0.19). Round 1 refused this at five consecutive
# transfer points, silently, with no force flag. A shorter spec is no longer
# evidence of anything.
r="$(new_repo)"
{ echo "# Mission: Rebuild the billing pipeline"; echo
  echo "**Type:** feature"
  echo "**Goal:** Replace the batch biller."
  echo "**Acceptance Criteria:**"
  for i in $(seq 1 60); do echo "- The new biller handles case number $i exactly as the old one did, byte for byte"; done
  echo "**Out of Scope:**"; echo "- anything else"
  echo "**Constraints:**"; echo "- none"; } >"$r/big.md"
mkm "$r" "$r/big.md"; M="$(mdir "$r")"
BIG=$(wc -c <"$M/.issue-body.last" | tr -d ' ')
{ echo "# Mission: Rebuild the billing pipeline"; echo
  echo "**Type:** feature"
  echo "**Goal:** Replace the batch biller."
  echo "**Acceptance Criteria:**"
  for i in 1 2 3; do echo "- The new biller handles case number $i exactly as the old one did, byte for byte"; done
  echo "**Out of Scope:**"; echo "- anything else"
  echo "**Constraints:**"; echo "- none"; } >"$M/prd.md"
drive1 "$r"
check "7. N2: an honest 60→3 criteria scope cut PUSHES (no ratio rule left)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "7. N2: and the issue now carries the SHORT spec, not the old one" \
  "last_issue_body | grep -q 'case number 3 ' && ! last_issue_body | grep -q 'case number 40'"
check "7. N2: no refusal breadcrumb was written" "[ ! -f '$M/.issue-body.refused' ]"

# --- 7.4 N1: a PRD that drops its OWN '---' horizontal rule ----------------
r="$(new_repo)"
cat >"$r/rule.md" <<'P'
# Mission: Add a CSV export to the invoice list

**Type:** feature
**Goal:** A finance user can download the invoice list as a CSV.

---

**Acceptance Criteria:**
- An "Export CSV" button sits above the invoice table
- Clicking it downloads the current rows
**Out of Scope:**
- XLSX or PDF export
**Constraints:**
- No new runtime dependencies
P
mkm "$r" "$r/rule.md"; M="$(mdir "$r")"
grep -v '^---$' "$M/prd.md" >"$TMPROOT/p1" && mv "$TMPROOT/p1" "$M/prd.md"
sed -i.bak 's/XLSX or PDF export/XLSX export/' "$M/prd.md" && rm -f "$M/prd.md.bak"
drive1 "$r"
check "7. N1: a PRD that deletes its own '---' rule still pushes" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "7. N1: and no refusal blamed the adr/estimate for it" \
  "[ ! -f '$M/.issue-body.refused' ]"

# --- 7.5 N3: a MISSING baseline degrades honestly, never silently ----------
# With no `.issue-body.last` the refresh cannot know what the issue carries.
# Round 1 read that as "nothing to regress on → ALLOW", and pushed a body with
# the Estimate section (and all three pills) deleted. It now REFUSES and says so.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -f "$M/.issue-body.last" "$M/estimate.json"
printf '\n**Amended:** x\n' >>"$M/prd.md"
drive1 "$r"
check "7. N3: no baseline + no estimate.json pushes NOTHING" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ]"
check "7. N3: and the refusal names the Estimate section" \
  "grep -q 'Estimate' '$M/.issue-body.refused'"
check "7. N3: no dedup marker, so restoring the source heals it" \
  "[ ! -f '$M/.issue-body.sha' ]"
# …but a missing baseline is NOT a blanket refusal: with every source present
# the body is fully rebuildable and pushes.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -f "$M/.issue-body.last"
printf '\n**Amended:** y\n' >>"$M/prd.md"
drive1 "$r"
check "7. N3: no baseline but every source present → the refresh PUSHES" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "7. N3: the push re-seeds the carry-forward baseline" \
  "[ -s '$M/.issue-body.last' ]"

# --- 7.6 the park lane now seeds a baseline too ----------------------------
r="$(new_repo)"; use_repo "$r"
file_it "$r" --park "A parked idea that has not been grilled yet."
PM="$(mdir "$r")"
check "7. the PARK lane seeds .issue-body.last (it never did before)" \
  "[ -s '$PM/.issue-body.last' ]"

# --- 7.7 the HEAL path ------------------------------------------------------
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -f "$M/.issue-body.last" "$M/estimate.json"
printf '\n**Amended:** heal me\n' >>"$M/prd.md"
drive1 "$r"
check "7. heal: the first pass refused" "[ -s '$M/.issue-body.refused' ]"
printf '{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "high", "models": {}, "cost": { "usd": { "low": 1.0, "high": 2.0 } } }\n' >"$M/estimate.json"
reverify "$M"; : >"$GH_OPS"
drive1 "$r"
check "7. heal: with the source restored the next transfer point PUSHES" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "7. heal: the healed body carries the new spec" \
  "last_issue_body | grep -q 'heal me'"
check "7. heal: and the Estimate section is back" \
  "last_issue_body | grep -q '^## Estimate\$'"
check "7. heal: the breadcrumb is deleted" "[ ! -f '$M/.issue-body.refused' ]"

# --- 7.8 the ADR part -------------------------------------------------------
# adr.md vanishing must not silently delete the ADR set off the issue.
r="$(new_repo)"; write_adr "$r/a.md"; write_prd "$r/p.md"
mkm "$r" "$r/p.md" "$r/a.md"; M="$(mdir "$r")"
check "7. adr: the filed body carried the ADR set" \
  "grep -q 'ADR-001' '$M/.issue-body.last'"
rm -f "$M/adr.md"
drive1 "$r"
check "7. adr: a missing adr.md is CARRIED FORWARD, not dropped" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ] && last_issue_body | grep -q 'ADR-001'"
check "7. adr: carry-forward is not a refusal" "[ ! -f '$M/.issue-body.refused' ]"
# …and when the spec ALSO moved, the ADR is STILL carried forward.
#
# OUTCOME CHANGE (S188 fix round 3), stated rather than quietly swapped. Round 2
# asserted a REFUSAL here, because its carry-forward SLICED the ADR out of the
# last pushed body by matching the current prd.md as a line-prefix — a spec that
# had moved made the slice unfindable. The slice is gone: the composer writes the
# ADR bytes down when it emits them, so a moved spec is irrelevant to locating
# it. That also settles NEW-3, where the two paths disagreed — deleting adr.md
# alone silently RESURRECTED the ADR while deleting it during a re-grill refused
# for ever. Both now carry (see the ADR block in lcars_issue_body_refresh), and
# the carry is announced in `lcars status` with the act that removes it. The full
# NEW-3 case, including that removal path, is driven in section 10.
r="$(new_repo)"; write_adr "$r/a.md"; write_prd "$r/p.md"
mkm "$r" "$r/p.md" "$r/a.md"; M="$(mdir "$r")"
rm -f "$M/adr.md"; printf '\n**Amended:** and the spec moved too\n' >>"$M/prd.md"
drive1 "$r"
check "7. adr: adr.md gone AND the spec rewritten → the ADR is still carried" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ] && last_issue_body | grep -q 'ADR-001' \
     && last_issue_body | grep -q 'and the spec moved too' \
     && [ ! -f '$M/.issue-body.refused' ]"
# …a mission that never had an ADR set is never touched by any of that.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
printf '\n**Amended:** trivial missions still push\n' >>"$M/prd.md"
drive1 "$r"
check "7. adr: a mission with no adr.md ever pushes freely" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"

# --- 7.9 the PROVENANCE part ------------------------------------------------
# Rebuilt from state.json when it can be (D1), carried forward when state.json
# has lost the parent — never dropped.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
python3 - "$M/state.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('"id"', '"origin": "log",\n  "parentMission": "lcars-20260530-000",\n  "parentIssue": 41,\n  "id"', 1)
open(p, "w").write(s)
PY
printf '> \xf0\x9f\x90\x9e Logged via `lcars log` against lcars-20260530-000 (#41).\n\n' >"$TMPROOT/prov"
cat "$M/.issue-body.last" >>"$TMPROOT/prov"
cp "$TMPROOT/prov" "$M/.issue-body.last"
printf '\n**Amended:** z\n' >>"$M/prd.md"
drive1 "$r"
check "7. D1: the provenance lead-in is REBUILT from state.json" \
  "last_issue_body | head -1 | grep -q 'Logged via'"
# now blank the parent out of state.json: the source can no longer rebuild it,
# so it is carried forward from the last pushed body.
reverify "$M"; : >"$GH_OPS"
python3 - "$M/state.json" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('"parentMission": "lcars-20260530-000",', '"parentMission": "",'))
PY
printf '\n**Amended:** zz\n' >>"$M/prd.md"
drive1 "$r"
check "7. D1: with the parent gone from state.json it is CARRIED FORWARD" \
  "last_issue_body | head -1 | grep -q 'Logged via'"

# --- 7.10 a refusal REACHES THE CAPTAIN ------------------------------------
# `.issue-body.refused` had zero readers anywhere in skills/ or web/, and both
# call sites swallow stderr — so N2's refusal was invisible. `lcars status`
# reads it now.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
: >"$M/prd.md"
drive1 "$r"
STATUS_OUT="$( cd "$r" && bash "$REPO_ROOT/skills/lcars-status/status.sh" 2>&1 )"
printf '%s\n' "$STATUS_OUT" >"$TMPROOT/status.out"
check "7. lcars status reports the mission whose issue body is not current" \
  "grep -q 'Issue body NOT updated' '$TMPROOT/status.out'"
check "7. …naming the mission" "grep -q '$MID' '$TMPROOT/status.out'"
check "7. …naming the part that could not be built" \
  "grep -q 'the spec' '$TMPROOT/status.out'"
check "7. …and telling the captain what to do about it" \
  "grep -q '→' '$TMPROOT/status.out'"

# --- 7.11 N4: the \\uXXXX un-escaper no longer corrupts non-ASCII ----------
ub() { bash -c '. "$1"; lcars_ib_unesc "$2"' _ "$IB_LIB" "$1"; }
check "7. N4: \\u65e5\\u672c decodes to 日本 (it read back as 'u65e5u672c')" \
  "[ \"\$(ub '\\u65e5\\u672c')\" = '日本' ]"
check "7. N4: an ASCII \\u003E still decodes to >" "[ \"\$(ub 'a\\u003Eb')\" = 'a>b' ]"
check "7. N4: a 2-byte codepoint (\\u00e9) decodes" "[ \"\$(ub '\\u00e9')\" = 'é' ]"
check "7. N4: a surrogate PAIR (\\uD83D\\uDC1E) decodes to one emoji" \
  "[ \"\$(ub '\\uD83D\\uDC1E')\" = '🐞' ]"
check "7. N4: a LONE surrogate is passed through, never mangled" \
  "[ \"\$(ub 'x\\uD83Dy')\" = 'x\\uD83Dy' ]"
check "7. N4: a branch name round-trips through the envelope unharmed" \
  "[ \"\$(ub 'lcars/\\u65e5\\u672c')\" = 'lcars/日本' ]"

# ==========================================================================
# BEHAVIOUR 8 — the envelope's machine contract  (S188 fix round 1)
# ==========================================================================
echo "  -- 8. the envelope survives hostile values and parses exactly once"

ib() { bash -c '. "$1"; shift; "$@"' _ "$IB_LIB" "$@"; }

# --- D6: a state.json value carrying a quote must READ CORRECTLY ------------
HM="$TMPROOT/hostile"; mkdir -p "$HM"
cat >"$HM/state.json" <<'PY_END'
{
  "id": "lcars-hostile-1",
  "branch": "lcars/we\"ird--><!--x",
  "base": "ma\\in",
  "type": "fea\"ture",
  "workerBin": "/usr/local/bin/copilot"
}
PY_END
printf '# Mission: hostile\n\nA spec.\n' >"$HM/prd.md"
check "8. D6: a value containing a quote is read WHOLE, not truncated" \
  "[ \"\$(ib lcars_ib_str '$HM/state.json' branch)\" = 'lcars/we\"ird--><!--x' ]"
check "8. D6: a value containing an escaped backslash is read whole" \
  "[ \"\$(ib lcars_ib_str '$HM/state.json' base)\" = 'ma\\in' ]"
ib lcars_issue_body_compose "$HM" align >"$TMPROOT/hostile.body"
check "8. D6: the envelope is still ONE line" \
  "[ \"\$(tail -1 '$TMPROOT/hostile.body' | grep -c 'lcars:handoff')\" = 1 ]"
check "8. D6: no crafted value can close the HTML comment early" \
  "[ \"\$(grep -c -- '-->' '$TMPROOT/hostile.body')\" = 1 ]"
HOSTILE_JSON="$(python3 - "$TMPROOT/hostile.body" <<'PY'
import json, re, sys
line = open(sys.argv[1]).read().rstrip("\n").split("\n")[-1]
m = re.fullmatch(r"<!-- lcars:handoff v1 (\{.*\}) -->", line)
if not m:
    print("NOT-AN-ENVELOPE"); raise SystemExit
try:
    d = json.loads(m.group(1))
except Exception as e:
    print("BAD-JSON %s" % e); raise SystemExit
print(json.dumps(d, sort_keys=True))
PY
)"
check "8. D6: the envelope is still valid JSON in a well-formed comment" \
  "printf '%s' \"\$HOSTILE_JSON\" | grep -q '^{'"
check "8. D6: and the hostile branch round-trips through the JSON intact" \
  "printf '%s' \"\$HOSTILE_JSON\" | python3 -c 'import json,sys; v=json.load(sys.stdin)[\"branch\"]; sys.exit(0 if v == chr(108)+\"cars/we\\\"ird--><!--x\" else 1)'"
check "8. D6: lcars_handoff_field returns the same hostile branch" \
  "[ \"\$(ib lcars_handoff_field '$TMPROOT/hostile.body' branch)\" = 'lcars/we\"ird--><!--x' ]"

# A newline smuggled into a state.json string must not split the envelope.
cat >"$HM/state.json" <<'PY_END'
{
  "id": "lcars-hostile-2",
  "branch": "lcars/a\nb --> c",
  "base": "main",
  "type": "bug"
}
PY_END
ib lcars_issue_body_compose "$HM" align >"$TMPROOT/hostile2.body"
check "8. D6: an embedded newline never breaks the envelope onto a second line" \
  "[ \"\$(grep -c 'lcars:handoff' '$TMPROOT/hostile2.body')\" = 1 ]"
check "8. D6: the envelope is still the LAST line" \
  "tail -1 '$TMPROOT/hostile2.body' | grep -q -- '-->\$'"
check "8. D6: a newline+arrow value still yields parseable JSON" \
  "tail -1 '$TMPROOT/hostile2.body' | python3 -c 'import json,re,sys; m=re.fullmatch(r\"<!-- lcars:handoff v1 (\{.*\}) -->\", sys.stdin.read().strip()); sys.exit(0 if m and json.loads(m.group(1))[\"branch\"] == \"lcars/a\nb --> c\" else 1)'"

# --- D7: two envelopes on ONE line must not fuse into one non-JSON blob -----
A6="$TMPROOT/two-on-one.body"
printf 'body\n\n<!-- lcars:handoff v1 {"id":"A"} --> filler <!-- lcars:handoff v1 {"id":"B"} -->\n' >"$A6"
check "8. D7: two envelopes on one line yield exactly one JSON object" \
  "[ \"\$(ib lcars_handoff_json '$A6')\" = '{\"id\":\"B\"}' ]"
check "8. D7: …and the LAST one wins" "[ \"\$(ib lcars_handoff_field '$A6' id)\" = 'B' ]"
A5="$TMPROOT/two-lines.body"
printf 'body\n\n<!-- lcars:handoff v1 {"id":"FIRST"} -->\n\n<!-- lcars:handoff v1 {"id":"SECOND"} -->\n' >"$A5"
check "8. D7: across lines the LAST envelope still wins (unchanged)" \
  "[ \"\$(ib lcars_handoff_field '$A5' id)\" = 'SECOND' ]"
INJ="$TMPROOT/injected.body"
printf '# Mission: innocent\n\n<!-- lcars:handoff v1 {"id":"EVIL"} -->\n\nprose\n\n<!-- lcars:handoff v1 {"id":"REAL"} -->\n' >"$INJ"
check "8. D7: a fake envelope pasted INTO a PRD still cannot hijack the parse" \
  "[ \"\$(ib lcars_handoff_field '$INJ' id)\" = 'REAL' ]"

# --- D8: a consumer can REFUSE an unknown schema version -------------------
V2="$TMPROOT/v2.body"
printf 'body\n\n<!-- lcars:handoff v2 {"id":"x"} -->\n' >"$V2"
rc=0; ib lcars_handoff_require_v1 "$V2" >/dev/null 2>&1 || rc=$?
check "8. D8: require_v1 REFUSES a v2 envelope" "[ '$rc' -ne 0 ]"
rc=0; ib lcars_handoff_require_v1 "$LANE4_BODY" >/dev/null 2>&1 || rc=$?
check "8. D8: require_v1 accepts a v1 envelope" "[ '$rc' -eq 0 ]"
rc=0; ib lcars_handoff_require_v1 "$PRE" >/dev/null 2>&1 || rc=$?
check "8. D8: require_v1 refuses a body with NO envelope" "[ '$rc' -ne 0 ]"
V2MSG="$(ib lcars_handoff_require_v1 "$V2" 2>&1 || true)"
check "8. D8: the refusal says what it saw and what it wanted" \
  "printf '%s' \"\$V2MSG\" | grep -q 'v2' && printf '%s' \"\$V2MSG\" | grep -q 'v1'"

# --- D1: the logged-bug provenance survives a refresh ----------------------
echo "  -- 9. a logged bug keeps its '🐞 Logged via' provenance across a refresh"
LM="$TMPROOT/logged"; mkdir -p "$LM"
cat >"$LM/state.json" <<'PY_END'
{
  "id": "lcars-20260530-002",
  "type": "bug",
  "origin": "log",
  "stage": "verify",
  "githubIssue": 43,
  "parentMission": "lcars-20260530-001",
  "parentIssue": 42,
  "branch": "lcars/lcars-20260530-001",
  "base": "main"
}
PY_END
printf '# Mission: CSV export double-fires\n\n**Type:** bug\n' >"$LM/prd.md"
ib lcars_issue_body_compose "$LM" align >"$TMPROOT/logged.body"
check "9. D1: a recomposed logged-bug body leads with the provenance line" \
  "head -1 '$TMPROOT/logged.body' | grep -q 'Logged via .lcars log. against lcars-20260530-001 (#42)\.'"
check "9. D1: …and still carries the PRD under it" \
  "grep -q 'CSV export double-fires' '$TMPROOT/logged.body'"
check "9. D1: …and an envelope with the real parentIssue" \
  "[ \"\$(ib lcars_handoff_field '$TMPROOT/logged.body' parentIssue)\" = '42' ]"
# a bug whose parent had no issue number: the '(#n)' half is omitted, as filed.
python3 - "$LM/state.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace('"parentIssue": 42', '"parentIssue": null'))
PY
ib lcars_issue_body_compose "$LM" align >"$TMPROOT/logged2.body"
check "9. D1: with no parent issue the '(#n)' half is omitted, exactly as filed" \
  "head -1 '$TMPROOT/logged2.body' | grep -q 'against lcars-20260530-001\.\$'"
# a NON-logged mission must gain no provenance line at all.
check "9. D1: an ordinary mission's body grows no provenance line" \
  "! grep -q 'Logged via' '$LANE4_BODY'"

# ==========================================================================
# BEHAVIOUR 10 — THE CARRY-FORWARD IS STRUCTURAL   (S188 fix round 3)
# ==========================================================================
# Round 2 replaced a whole-body heuristic guard with part-aware composition —
# the right move — but LOCATED the carried parts by grepping the captain's
# prose: `^## Estimate$` for the estimate, `**Context:**`/`**Decision:**`/
# `**Alternatives considered:**`/`**Consequences:**` for "does this issue carry
# an ADR". A fresh tester beat both, and this captain writes PRDs ABOUT LCARS —
# a system whose own documentation is full of exactly those strings.
#
#   NEW-1  SILENT BODY CORRUPTION. With no estimate.json, the tail-anchored
#          `^## Estimate$` grep matched a heading inside the PRD, so the
#          "carried estimate" was everything from there to the end of the body —
#          the PRD tail plus the whole ADR set, re-appended. Pushed silently.
#   NEW-2  PERMANENT FALSE REFUSAL. A PRD that merely DOCUMENTS the ADR field
#          names read as "this issue carries an ADR set"; the slice then could
#          not find one, and every transfer point refused for ever, leaving the
#          issue on the OLD spec — the defect S188 exists to close.
#
# The cure is that no part is LOCATED at all any more. The composer WRITES DOWN
# the parts it emitted (`$MISSION_DIR/.issue-body.parts/`, paired to the pushed
# body by checksum), and a carry-forward is a copy out of that record. There is
# no heading search and no field search left to fool.
echo "  -- 10. carried parts come from the composer's own record, never from prose"

# A PRD that is ABOUT the issue body: it carries an H2 literally named
# "## Estimate" AND spells all four ADR field names. Both are captain's prose.
write_meta_prd() { cat >"$1" <<'P'
# Mission: Document the issue body layout

**Type:** feature
**Goal:** The handbook explains how an LCARS issue body is laid out.
**Acceptance Criteria:**
- The handbook shows the section order
- The handbook names every field the board scrapes
**Out of Scope:**
- Changing the composer itself
**Constraints:**
- No new runtime dependencies

## Estimate

MARKER-PRD-TAIL — the composer appends this section from estimate.json.
Each ADR in adr.md carries **Context:**, **Decision:**,
**Alternatives considered:** and **Consequences:**.
P
}

# --- 10.0 the record itself -------------------------------------------------
r="$(new_repo)"; write_adr "$r/a.md"; write_prd "$r/p.md"
mkm "$r" "$r/p.md" "$r/a.md"; M="$(mdir "$r")"
check "10. filing writes the composer's part record" \
  "[ -d '$M/.issue-body.parts' ] && [ -f '$M/.issue-body.parts/flags' ]"
check "10. the record is PAIRED to the pushed body by checksum" \
  "[ \"\$(cat '$M/.issue-body.parts/sum')\" = \"\$(cksum <'$M/.issue-body.last' | tr -d ' \n')\" ]"
check "10. the record holds the ADR bytes, not a search for them" \
  "grep -q 'ADR-001' '$M/.issue-body.parts/adr'"
check "10. the record leaves no staging directory behind" \
  "[ ! -d '$M/.issue-body.parts.staged' ]"

# --- 10.1 NEW-1: an '## Estimate' HEADING IN THE PRD, and no estimate.json ---
r="$(new_repo)"; write_meta_prd "$r/p.md"; write_adr "$r/a.md"
FILE_RUN_BIN=/nonexistent-estimator mkm "$r" "$r/p.md" "$r/a.md"; M="$(mdir "$r")"
check "10. NEW-1 precondition: the filed body has NO composer Estimate section" \
  "[ ! -f '$M/estimate.json' ] && [ \"\$(cat '$M/.issue-body.parts/flags' | grep -c '^est=0\$')\" = 1 ]"
printf '\n**Amended:** the re-grill touched this spec.\n' >>"$M/prd.md"
drive1 "$r"
last_issue_body >"$TMPROOT/new1.body"
check "10. NEW-1: the refresh still pushed the new spec" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ] && grep -q 'the re-grill touched this spec' '$TMPROOT/new1.body'"
check "10. NEW-1: the PRD tail appears exactly ONCE (it was duplicated)" \
  "[ \"\$(grep -c 'MARKER-PRD-TAIL' '$TMPROOT/new1.body')\" = 1 ]"
check "10. NEW-1: the ADR set appears exactly ONCE (it was duplicated)" \
  "[ \"\$(grep -c 'ADR-001' '$TMPROOT/new1.body')\" = 1 ]"
check "10. NEW-1: the PRD's own '## Estimate' heading is not multiplied" \
  "[ \"\$(grep -c '^## Estimate\$' '$TMPROOT/new1.body')\" = 1 ]"
check "10. NEW-1: nothing was appended after the ADR set" \
  "[ \"\$(grep -c '^---\$' '$TMPROOT/new1.body')\" = 1 ]"

# --- 10.2 NEW-2: a PRD that DOCUMENTS the ADR format, on a mission with none --
r="$(new_repo)"; write_meta_prd "$r/p.md"
mkm "$r" "$r/p.md"; M="$(mdir "$r")"
check "10. NEW-2 precondition: this mission never had an adr.md" "[ ! -f '$M/adr.md' ]"
printf '\n**Amended:** documenting is not carrying.\n' >>"$M/prd.md"
drive1 "$r"
check "10. NEW-2: a PRD that documents the ADR format PUSHES normally" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "10. NEW-2: …with no refusal breadcrumb at all" \
  "[ ! -f '$M/.issue-body.refused' ]"
check "10. NEW-2: …and the issue carries the NEW spec, not the old one" \
  "last_issue_body | grep -q 'documenting is not carrying'"
# and it stays cured at the NEXT transfer point (round 2's refusal was permanent)
reverify "$M"; : >"$GH_OPS"
printf '\n**Amended:** and again.\n' >>"$M/prd.md"
drive1 "$r"
check "10. NEW-2: and again at the next transfer point (it was PERMANENT)" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ] && last_issue_body | grep -q 'and again'"

# --- 10.3 NEW-3: adr.md deleted AND the spec re-grilled ---------------------
# OUTCOME CHANGE, stated deliberately (see the source header): round 2 REFUSED
# here — while the same deletion WITHOUT a re-grill silently resurrected the
# ADR. Two paths, opposite answers, for one act. The decision is: an absent
# adr.md ALWAYS carries the ADR forward, because the issue is the handoff
# document and `.git/lcars/` is a cache a cache-loss must never delete GitHub
# content. Removing an ADR is now an explicit act on the record.
r="$(new_repo)"; write_adr "$r/a.md"; write_prd "$r/p.md"
mkm "$r" "$r/p.md" "$r/a.md"; M="$(mdir "$r")"
rm -f "$M/adr.md"; printf '\n**Amended:** and the spec moved too\n' >>"$M/prd.md"
drive1 "$r"
check "10. NEW-3: adr.md gone AND the spec rewritten now PUSHES" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ]"
check "10. NEW-3: …carrying the ADR forward" "last_issue_body | grep -q 'ADR-001'"
check "10. NEW-3: …and the NEW spec with it" \
  "last_issue_body | grep -q 'and the spec moved too'"
check "10. NEW-3: …with no refusal" "[ ! -f '$M/.issue-body.refused' ]"
# the carry is ANNOUNCED, not silent
check "10. NEW-3: the carry leaves a breadcrumb naming the part" \
  "grep -q 'ADR' '$M/.issue-body.carried'"
STATUS_OUT="$( cd "$r" && bash "$REPO_ROOT/skills/lcars-status/status.sh" 2>&1 )"
printf '%s\n' "$STATUS_OUT" >"$TMPROOT/carried.status"
check "10. NEW-3: lcars status announces the carried ADR" \
  "grep -q 'carried forward' '$TMPROOT/carried.status'"
check "10. NEW-3: …and names the act that removes it" \
  "grep -q '.issue-body.parts/adr' '$TMPROOT/carried.status'"
# THE REMOVAL PATH the captain now has
reverify "$M"; : >"$GH_OPS"
rm -f "$M/.issue-body.parts/adr"
printf '\n**Amended:** the ADR is gone for good\n' >>"$M/prd.md"
drive1 "$r"
check "10. NEW-3: forgetting the recorded part REMOVES the ADR from the issue" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 1 ] && ! last_issue_body | grep -q 'ADR-001'"

# --- 10.4 a 0-byte adr.md is a crash artifact, not 'no ADR' -----------------
# The Validate stage can rewrite adr.md from a worker's output (run.sh copies
# $odir/adr.md back), so a 0-byte adr.md is the same shape as the 0-byte prd.md
# D3 refuses on. It must not silently delete the ADR set.
r="$(new_repo)"; write_adr "$r/a.md"; write_prd "$r/p.md"
mkm "$r" "$r/p.md" "$r/a.md"; M="$(mdir "$r")"
: >"$M/adr.md"; printf '\n**Amended:** q\n' >>"$M/prd.md"
drive1 "$r"
check "10. a 0-byte adr.md pushes NOTHING" "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ]"
check "10. …and refuses BY NAME" "grep -qi 'adr' '$M/.issue-body.refused'"
check "10. …with a remedy that does not name a file that never existed" \
  "! grep -q 'from the mission history' '$M/.issue-body.refused'"

# --- 10.5 the CARRIED estimate is announced too (the silent-fossil gap) -----
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -f "$M/estimate.json"; printf '\n**Amended:** pills are a fossil now\n' >>"$M/prd.md"
drive1 "$r"
check "10. a carried estimate writes the carry breadcrumb" \
  "grep -q 'Estimate' '$M/.issue-body.carried'"
STATUS_OUT="$( cd "$r" && bash "$REPO_ROOT/skills/lcars-status/status.sh" 2>&1 )"
printf '%s\n' "$STATUS_OUT" >"$TMPROOT/carried2.status"
check "10. lcars status says the Estimate was carried, not rebuilt" \
  "grep -q 'Estimate carried forward' '$TMPROOT/carried2.status'"
check "10. …and says estimate.json is missing" \
  "grep -q 'estimate.json' '$TMPROOT/carried2.status'"
# …and a LATER refusal does not erase it: the issue still carries what it
# carried, so `lcars status` keeps saying so alongside the refusal.
reverify "$M"; : >"$GH_OPS"; : >"$M/prd.md"
drive1 "$r"
check "10. a refusal does not erase the carry line (the issue is unchanged)" \
  "[ -s '$M/.issue-body.carried' ] && [ -s '$M/.issue-body.refused' ]"
STATUS_OUT="$( cd "$r" && bash "$REPO_ROOT/skills/lcars-status/status.sh" 2>&1 )"
printf '%s\n' "$STATUS_OUT" >"$TMPROOT/both.status"
check "10. lcars status shows BOTH the refusal and the carry" \
  "grep -q 'Issue body NOT updated' '$TMPROOT/both.status' && grep -q 'CARRIED-FORWARD' '$TMPROOT/both.status'"

# a fully rebuildable refresh says nothing at all
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
printf '\n**Amended:** everything rebuildable\n' >>"$M/prd.md"
drive1 "$r"
check "10. a fully rebuilt body leaves NO carry breadcrumb" \
  "[ ! -f '$M/.issue-body.carried' ]"

# --- 10.6 the prose searches are GONE from the library ----------------------
# Comment lines are stripped first: the header EXPLAINS both defeated searches,
# and quoting a bug in prose is not shipping it.
ibcode() { grep -v '^[[:space:]]*#' "$IB_LIB"; }
# The string still appears ONCE in code — as the refusal's human LABEL. What
# must not survive is a SEARCH for it (grep/sed/awk over a body).
check "10. no '## Estimate' search survives in the composer's CODE" \
  "! ibcode | grep -qE '(grep|sed|awk)[^|]*## Estimate'"
check "10. …the only surviving mention is the refusal's own label" \
  "[ \"\$(ibcode | grep -c '## Estimate')\" = 1 ]"
check "10. no ADR field-name search survives in the composer's CODE" \
  "! ibcode | grep -qE 'Alternatives considered|\\*\\*Context:'"
check "10. lcars_ib_prev_has_adr is gone" \
  "! grep -q 'lcars_ib_prev_has_adr()' '$IB_LIB'"

# --- 10.7 a record that predates this layout is NO record -------------------
# Honest degradation, exactly as a baseline with no envelope already degrades.
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
rm -rf "$M/.issue-body.parts"; rm -f "$M/estimate.json"
printf '\n**Amended:** legacy record\n' >>"$M/prd.md"
drive1 "$r"
check "10. a body recorded before this layout reads as NO record" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ] && grep -q 'Estimate' '$M/.issue-body.refused'"
# a record whose checksum no longer matches the recorded body is not a record
r="$(new_repo)"; mkm "$r"; M="$(mdir "$r")"
printf 'tampered\n' >>"$M/.issue-body.last"; rm -f "$M/estimate.json"
printf '\n**Amended:** tampered record\n' >>"$M/prd.md"
drive1 "$r"
check "10. a record that no longer matches its body is not honoured" \
  "[ \"\$(nops ISSUE-EDIT-BODY)\" = 0 ] && grep -q 'Estimate' '$M/.issue-body.refused'"

# ==========================================================================
# The host-adapter op itself
# ==========================================================================
echo "  -- host adapter: issue-edit-body"

r="$(new_repo)"; use_repo "$r"
printf 'a body from stdin\n' | ( cd "$r" && LCARS_GH_BIN="$r/gh" bash "$HOST_ADAPTER" issue-edit-body 42 ) >/dev/null 2>&1
check "op. issue-edit-body sends the body on STDIN via gh issue edit --body-file -" \
  "grep -q 'issue edit 42 --body-file -' '$GH_LOG'"
check "op. it records the body it was handed" \
  "grep -q 'a body from stdin' '$GH_BODYDIR/issue-1'"
rc=0; ( cd "$r" && LCARS_GH_BIN="/nonexistent/gh" bash "$HOST_ADAPTER" issue-edit-body 42 </dev/null ) >/dev/null 2>&1 || rc=$?
check "op. gh absent → soft non-zero, never a die" "[ '$rc' -ne 0 ]"
rc=0; ( cd "$r" && LCARS_GH_BIN="$r/gh" bash "$HOST_ADAPTER" issue-edit-body </dev/null ) >/dev/null 2>&1 || rc=$?
check "op. a missing issue number is a hard error" "[ '$rc' -eq 1 ]"

# ==========================================================================
echo
printf 'handoff payload: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
