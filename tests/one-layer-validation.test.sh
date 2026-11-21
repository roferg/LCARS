#!/usr/bin/env bash
#
# tests/one-layer-validation.test.sh — S366: ONE LAYER DEEP, ONE VALIDATION
# PASS, THREE ROUNDS.
#
# (skill source: skills/lcars-eeh/ech.sh § the boundary / cmd_delegate /
#                cmd_request_validator / cmd_revalidate / subech_scope_or_die,
#                skills/lcars-eeh/DELEGATION.md § ONE LAYER …,
#                § THE VALIDATION RULE)
#
# WHAT THE CAPTAIN RULED, 2026-11-20. Authority travels with the chunk: a main
# ECH mints sub-ECHs ONE LAYER DEEP, each owning a chunk it hands to the factory,
# makes land, VALIDATES, files its own bugs for and drives its own fixes on. He
# then named the two things that could spiral, and this suite is both of them:
#
#   DEPTH   — "a sub-ECH MAY NOT MINT A SUB-ECH. Hard stop, enforced."
#   DOUBLE  — "I worry about how the main ech chooses when to use [a separate
#              validator] vs letting the sub ech that drove the work to validate
#              it. I also don't want to end up with spiralling double validation."
#
# WHAT S365 ALREADY LANDED, AND WHY THIS SUITE DOES NOT RE-TEST IT. The verb
# boundary (`SUBECH_VERBS`, one constant, deny-by-default) ALREADY refuses
# `delegate` to a sub-ECH, alongside `record` and `tier`, because those three in
# a row are the self-minting chain. So the REFUSAL exists and
# `tests/chunk-authority.test.sh` § 1 owns it. What was still owed is the other
# half, and it is what § 1 and § 2 below measure: the record carries WHO MINTED
# WHOM, and the refusal NAMES THE CAP AND THE TWO LEGAL ALTERNATIVES instead of
# only saying "not a verb a sub-ECH may run". Extending the one constant, never
# adding a second check beside it — round 2 of S365 deleted exactly that
# duplication once already.
#
# THE TRIGGERS ARE THE INDUSTRY'S AXES. Safety-critical practice scales
# INDEPENDENCE to the severity of an UNDETECTED failure; four-eyes is reserved
# for IRREVERSIBLE acts; `CODEOWNERS` triages by BLAST RADIUS. Size-as-proxy is
# widely used, widely criticised, and deliberately NOT a trigger here — and
# neither is "it changes something on screen", because a button moving four
# pixels is a visual change a test asserts perfectly well, and that trigger
# would fire on every UI chunk and re-create the double validation the rule
# exists to prevent. § 3 pins all four of those by name.
#
# PROOF SURFACE. *Real:* real git repos, real Mission records, REAL mints
# through the real `tier` + `delegate` verbs (§ 2, § 3, § 5, § 9), real validator
# records, the real `file-bug` path with the real chunk-owners library, and the
# real refusals. *Faked:* the forge (gh), `lcars log` (a stub that files a real
# linked child record the way log.sh does), and the AI CLIs (pinned to zero
# spend by the PATH shim). *Blind to:* whether the three triggers are the RIGHT
# three — only a live run shows that, and S367 is where it shows.
#
# THE KNOWN-GOOD CONTROL (§ 9) IS A REAL BEFORE/AFTER, AND IT PROVES IT CAN
# FAIL. It runs the BASELINE ech.sh — extracted from $LCARS_BASELINE_REF, the
# branch tip before this session — beside the current one on a single-chunk repo
# with NO validator, and diffs `delegates`, `status`, `stalled` and a whole
# `delegate` mint byte for byte. Then it points the SAME method at a
# deliberately broken build and requires the diff to FIRE. A control that cannot
# fail on a known-bad build proves nothing; four of those shipped on 2026-11-18.
#
# Usage: bash tests/one-layer-validation.test.sh
#    or: python3 tests/lib/cage.py 600 bash tests/one-layer-validation.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"
DOC="$REPO_ROOT/skills/lcars-eeh/DELEGATION.md"
# THE BASELINE FOR § 9's BYTE-FOR-BYTE CONTROL: 04e9de1 is this branch's tip
# before S366 (S365's last fix round). Override it only to re-point the control.
BASELINE_REF="${LCARS_BASELINE_REF:-04e9de1}"

pass=0
fail=0
if [ -n "${LCARS_TEST_TMP_ROOT:-}" ]; then
  TMPROOT="$(mktemp -d "$LCARS_TEST_TMP_ROOT/onelayer.XXXXXX")"
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

# --- the spend fuse (tests/chunk-authority.test.sh's, verbatim in intent) ---
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
# FIXTURES
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
{ "id": "$id", "stage": "$stage", "type": "$type", "title": "mission $id",
  "branch": "lcars/$parent", "parentMission": "$parent",
  "parentIssue": "1", "issue": "1" }
JSON
  else
    cat >"$d/state.json" <<JSON
{ "id": "$id", "stage": "$stage", "type": "$type", "title": "mission $id",
  "branch": "lcars/$id", "issue": "1" }
JSON
  fi
  git -C "$repo" branch -q "lcars/$id" main 2>/dev/null || true
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
# linked to its parent — because `file-bug` VERIFIES the linkage it claims.
# (Lifted from tests/chunk-authority.test.sh, which lifted it from
# tests/lcars-ech.test.sh § S234.3.)
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
ech()    { local repo="$1"; shift; ech_at "$SCRIPT" "$repo" "$@"; }
ech_as() { local seat="$1" repo="$2"; shift 2; LCARS_ECH_AS="$seat" ech_at "$SCRIPT" "$repo" "$@"; }

# apj <repo> <dotted.path> → the recorded value, or nothing.
apj() {
  python3 - "$1/.git/lcars/autopilot.json" "$2" <<'PY'
import json, sys
try:
    cur = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for p in sys.argv[2].split("."):
    if isinstance(cur, dict) and p in cur:
        cur = cur[p]
    else:
        sys.exit(0)
if isinstance(cur, bool):
    sys.stdout.write("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    sys.stdout.write(json.dumps(cur, sort_keys=True))
else:
    sys.stdout.write(str(cur))
PY
}

ap_init() {
  local repo="$1" scope="${2:-M0}"
  cat >"$repo/.git/lcars/autopilot.json" <<JSON
{ "spec": "spec.md", "engine": "copilot", "scope": ["$scope"],
  "missions": {}, "questions": {}, "pending": {} }
JSON
}

# TWO CHUNKS WITH THE DELEGATE RECORDS WRITTEN DIRECTLY — the same fields
# `delegate` writes, which are the only ones an authority question reads, plus
# S366's own `mintedBy`/`depth`. A real mint is spent where the MINT is the
# thing under test (§ 2, § 3, § 5, § 9); everywhere else the RECORD is.
#   mine   — unit `mine`,   mission `m-mine`,   driver d1
#   theirs — unit `theirs`, mission `m-theirs`, driver d9
fast_chunk_repo() {
  local r; r="$(new_repo)"
  new_mission "$r" m-mine   verify
  new_mission "$r" m-theirs verify
  cat >"$r/.git/lcars/autopilot.json" <<'JSON'
{
  "spec": "spec.md", "engine": "copilot", "scope": ["M0"],
  "missions": { "mine": { "id": "m-mine" }, "theirs": { "id": "m-theirs" } },
  "questions": {}, "pending": {},
  "units": { "mine": { "tier": "T1", "tierWhy": "one owner end to end" },
             "theirs": { "tier": "T1", "tierWhy": "a sibling chunk" } },
  "delegates": {
    "d1": { "id": "d1", "unit": "mine",   "tier": "T1", "status": "minted",
            "mission": "m-mine",   "mintedBy": "main", "depth": 1 },
    "d9": { "id": "d9", "unit": "theirs", "tier": "T1", "status": "minted",
            "mission": "m-theirs", "mintedBy": "main", "depth": 1 }
  }
}
JSON
  # The artifacts a real mint writes: the brief, and the SEAT MARKER. An
  # ownership claim is only honoured when BOTH are there.
  local d
  for d in d1 d9; do
    mkdir -p "$r/.git/lcars/delegates/$d"
    echo "# BRIEF $d" >"$r/.git/lcars/delegates/$d/BRIEF.md"
    : >"$r/.git/lcars/delegates/$d/OPEN"
  done
  printf '%s\n' "$r"
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

# =========================================================================
printf '== 1. THE DEPTH CAP: a sub-ECH mint is refused, WITH THE CAP NAMED ==\n'
# =========================================================================
# S365 already refuses the verb. What is owed is the REASON: an operator (or a
# live seat) reading the refusal must learn the cap and the two things it may do
# INSTEAD, or the refusal is a wall with no door in it.
R1="$(fast_chunk_repo)"
OUT1="$TMPROOT/out1.txt"
rc1=0; ech_as d1 "$R1" delegate theirs >"$OUT1" 2>&1 || rc1=$?
check "1a. a sub-ECH's mint attempt is REFUSED" "[ $rc1 -ne 0 ]"
check "1b. it is the SAME boundary refusal S365 landed, extended not replaced" \
  "grep -q 'NOT A VERB A SUB-ECH MAY RUN' '$OUT1'"
check "1c. …still carrying the escalation-chain reason S365 wrote" \
  "grep -q 'MINTED ITSELF a seat' '$OUT1'"
check "1d. THE CAP IS NAMED: sub-ECHs are exactly ONE LAYER deep" \
  "grep -qi 'ONE LAYER' '$OUT1'"
check "1e. ALTERNATIVE 1 is named: hand the work back UP to the main ECH" \
  "grep -qi 'hand .*back' '$OUT1' && grep -q 'BLOCKED:' '$OUT1'"
check "1f. ALTERNATIVE 2 is named: chunk it into MORE MISSIONS for the factory" \
  "grep -qi 'more Missions' '$OUT1'"
check "1g. …with the runnable door, so the alternative is usable not theoretical" \
  "grep -q 'exec lcars-file/file.sh' '$OUT1'"
check "1h. …and it says a sub-ECH MAY do that freely (the captain's own tweak)" \
  "grep -qi 'freely' '$OUT1'"
check "1i. NOTHING WAS MINTED: no third delegate record" \
  "[ -z \"\$(apj '$R1' delegates.d2.id)\" ] && [ -z \"\$(apj '$R1' delegates.d10.id)\" ]"
check "1j. …and no brief was written" \
  "[ ! -f '$R1/.git/lcars/delegates/d2/BRIEF.md' ]"
# THE CAP RIDES THE VERB IT BELONGS TO. `record` and `tier` are refused for the
# escalation-chain reason; neither of them MINTS anything, so a cap sentence on
# them would be noise — and a refusal that says everything says nothing.
rc1b=0; ech_as d1 "$R1" record 'missions.theirs.id' m-theirs >"$TMPROOT/out1b.txt" 2>&1 || rc1b=$?
check "1k. [control] \`record\` is still refused, with the chain reason" \
  "[ $rc1b -ne 0 ] && grep -q 'MINTED ITSELF a seat' '$TMPROOT/out1b.txt'"
check "1l. [control] …but NOT with the depth cap — the cap rides \`delegate\`" \
  "! grep -qi 'more Missions' '$TMPROOT/out1b.txt'"
rc1c=0; ech_as d1 "$R1" tier theirs --tier T1 --why x >"$TMPROOT/out1c.txt" 2>&1 || rc1c=$?
check "1m. [control] \`tier\` likewise" \
  "[ $rc1c -ne 0 ] && ! grep -qi 'more Missions' '$TMPROOT/out1c.txt'"
echo

# =========================================================================
printf '== 2. THE RECORD CARRIES WHO MINTED WHOM, AT BOTH LAYERS ==\n'
# =========================================================================
# Today nothing in the record carries a parent or a depth, so the cap is
# enforced and not RECORDED — and the shape of a run is invisible on disk.
R2="$(new_repo)"
ap_init "$R2"
new_mission "$R2" m-one verify
ech "$R2" record 'missions.one.id' m-one >/dev/null 2>&1
ech "$R2" tier one --tier T1 --why "one owner end to end" >/dev/null 2>&1
ech "$R2" delegate one >"$TMPROOT/out2.txt" 2>&1
check "2a. the real mint succeeded (so the fields below are a real mint's)" \
  "grep -q 'MINTED: d1' '$TMPROOT/out2.txt'"
check "2b. the record says WHO minted it: the main ECH" \
  "[ \"\$(apj '$R2' delegates.d1.mintedBy)\" = main ]"
check "2c. …and at WHAT LAYER it sits: one" \
  "[ \"\$(apj '$R2' delegates.d1.depth)\" = 1 ]"
# AND THE SECOND LAYER, WHICH IS THE ONE THAT MUST NEVER EXIST. The refused
# attempt in § 1 left no record at all; this asserts the absence positively,
# across every seat, so a future mint path that forgets the cap is caught by the
# RECORD and not only by the refusal.
rc2=0; ech_as d1 "$R2" delegate one >/dev/null 2>&1 || rc2=$?
check "2d. a sub-ECH's attempt leaves NO layer-two record anywhere" \
  "[ $rc2 -ne 0 ] && [ -z \"\$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(\" \".join(k for k,v in (d.get(\"delegates\") or {}).items() if (v or {}).get(\"depth\",1)!=1))
' '$R2/.git/lcars/autopilot.json')\" ]"
check "2e. …and every seat on disk names a minter, so the shape is readable" \
  "[ \"\$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(sum(1 for v in (d.get(\"delegates\") or {}).values() if not (v or {}).get(\"mintedBy\")))
' '$R2/.git/lcars/autopilot.json')\" = 0 ]"
echo

# =========================================================================
printf '== 3. A SIBLING VALIDATOR IS MINTED BY THE MAIN ECH, ON A TRIGGER ==\n'
# =========================================================================
R3="$(fast_chunk_repo)"
OUT3="$TMPROOT/out3.txt"
rc3=0
ech "$R3" delegate mine --validate --trigger undetectable \
  --why "the AC is \"the error reads clearly\" and no test can fail on it" \
  >"$OUT3" 2>&1 || rc3=$?
check "3a. the main ECH may mint a sibling validator on a declared trigger" \
  "[ $rc3 -eq 0 ] && grep -q 'MINTED' '$OUT3'"
V3="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R3/.git/lcars/autopilot.json" | tr -d ' ')"
check "3b. the record marks it as validating that chunk" \
  "[ -n '$V3' ] && [ \"\$(apj '$R3' delegates.$V3.validates)\" = mine ]"
check "3c. …WITH ITS TRIGGER, recorded the way the tier judgement already is" \
  "[ \"\$(apj '$R3' delegates.$V3.validationTrigger)\" = undetectable ]"
check "3d. …and WITH ITS REASON, which is the half a trigger name cannot carry" \
  "apj '$R3' delegates.$V3.validationWhy | grep -q 'reads clearly'"
check "3e. …and which seat DROVE the chunk it is validating" \
  "[ \"\$(apj '$R3' delegates.$V3.validatorFor)\" = d1 ]"
check "3f. it is a SIBLING: minted by the main ECH, still layer one" \
  "[ \"\$(apj '$R3' delegates.$V3.mintedBy)\" = main ] && [ \"\$(apj '$R3' delegates.$V3.depth)\" = 1 ]"
check "3g. the round is recorded, on the CHUNK, so it survives the seat closing" \
  "[ \"\$(apj '$R3' delegates.$V3.validationRound)\" = 1 ] && [ \"\$(apj '$R3' units.mine.validationRound)\" = 1 ]"
check "3h. a TRIGGERED pass counts as validation coverage" \
  "[ \"\$(apj '$R3' delegates.$V3.countsAsCoverage)\" = true ]"
check "3i. the brief carries the validation contract it is held to" \
  "grep -qi 'ONLY the bugs you filed' '$R3/.git/lcars/delegates/$V3/BRIEF.md'"
check "3j. …and that its findings go back to the DRIVER as bugs" \
  "grep -qi 'back to the driving sub-ECH' '$R3/.git/lcars/delegates/$V3/BRIEF.md'"
check "3k. …and that validation is never re-delegated" \
  "grep -qi 'never re-delegated' '$R3/.git/lcars/delegates/$V3/BRIEF.md'"
# THE OTHER TWO TRIGGERS, each in its own repo so the round counter cannot
# confound the result.
for trio in irreversible wide; do
  RT="$(fast_chunk_repo)"
  rct=0
  ech "$RT" delegate mine --validate --trigger "$trio" --why "a declared reason" \
    >"$TMPROOT/out3.$trio.txt" 2>&1 || rct=$?
  VT="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$RT/.git/lcars/autopilot.json" | tr -d ' ')"
  check "3l.$trio. \`$trio\` is one of the three declared triggers" \
    "[ $rct -eq 0 ] && [ \"\$(apj '$RT' delegates.$VT.validationTrigger)\" = '$trio' ]"
done
# AND THE TWO NON-TRIGGERS, BY NAME. These are the whole point of the rule: both
# are plausible, both are refused, and the refusal says why.
R3B="$(fast_chunk_repo)"
rc3b=0; ech "$R3B" delegate mine --validate --trigger large --why "a big diff" \
  >"$TMPROOT/out3b.txt" 2>&1 || rc3b=$?
check "3m. SIZE IS NOT A TRIGGER — a big chunk does not buy a second pass" \
  "[ $rc3b -ne 0 ] && grep -qi 'size' '$TMPROOT/out3b.txt'"
check "3n. …and the refusal names the three that ARE triggers" \
  "grep -q 'undetectable' '$TMPROOT/out3b.txt' && grep -q 'irreversible' '$TMPROOT/out3b.txt' \
   && grep -q 'wide' '$TMPROOT/out3b.txt'"
rc3c=0; ech "$R3B" delegate mine --validate --trigger visual --why "it changes the screen" \
  >"$TMPROOT/out3c.txt" 2>&1 || rc3c=$?
check "3o. A VISUAL CHANGE IS NOT A TRIGGER either (the captain, 2026-11-20)" \
  "[ $rc3c -ne 0 ] && grep -qi 'visual' '$TMPROOT/out3c.txt'"
check "3p. …and it says why: a button moving is a change a test asserts fine" \
  "grep -qi 'button' '$TMPROOT/out3c.txt'"
rc3d=0; ech "$R3B" delegate mine --validate --trigger wide >"$TMPROOT/out3d.txt" 2>&1 || rc3d=$?
check "3q. a trigger with NO REASON is refused — the reason is half the record" \
  "[ $rc3d -ne 0 ] && grep -q -- '--why' '$TMPROOT/out3d.txt'"
check "3r. [control] and none of those four refusals minted anything" \
  "[ -z \"\$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(\" \".join(k for k,v in (d.get(\"delegates\") or {}).items() if (v or {}).get(\"validates\")))
' '$R3B/.git/lcars/autopilot.json' | tr -d ' ')\" ]"
echo

# =========================================================================
printf '== 4. NO TRIGGER AND NO RECORDED REQUEST: REFUSED ==\n'
# =========================================================================
# THE DEFAULT IS THE DRIVER. This is the refusal that stops double validation
# from becoming the habit, so it has to teach the default rather than just stop.
R4="$(fast_chunk_repo)"
rc4=0; ech "$R4" delegate mine --validate >"$TMPROOT/out4.txt" 2>&1 || rc4=$?
check "4a. a validator with neither a trigger nor a request is REFUSED" "[ $rc4 -ne 0 ]"
check "4b. the refusal states the DEFAULT: the driving sub-ECH validates" \
  "grep -qi 'driving sub-ECH validates' '$TMPROOT/out4.txt'"
check "4c. …names all three declared triggers" \
  "grep -q 'undetectable' '$TMPROOT/out4.txt' && grep -q 'irreversible' '$TMPROOT/out4.txt' \
   && grep -q 'wide' '$TMPROOT/out4.txt'"
check "4d. …and names the weaker lane, with the verb that opens it" \
  "grep -q 'request-validator' '$TMPROOT/out4.txt'"
check "4e. nothing was minted" \
  "[ -z \"\$(apj '$R4' delegates.d2.id)\" ] && [ -z \"\$(apj '$R4' units.mine.validationRound)\" ]"
echo

# =========================================================================
printf '== 5. THE DRIVER MAY ASK — honoured, and NEVER counted as coverage ==\n'
# =========================================================================
R5="$(fast_chunk_repo)"
rc5=0; ech_as d1 "$R5" request-validator "I cannot tell if the river renders" \
  >"$TMPROOT/out5.txt" 2>&1 || rc5=$?
check "5a. a driving sub-ECH MAY request a validator (it is a verb it may run)" \
  "[ $rc5 -eq 0 ]"
check "5b. the request is RECORDED on its own seat, with its reason" \
  "apj '$R5' delegates.d1.validatorRequested.why | grep -q 'river renders'"
check "5c. the verb says plainly that a request is NOT a trigger" \
  "grep -qi 'not a trigger' '$TMPROOT/out5.txt'"
check "5d. …and that it will not be counted as coverage" \
  "grep -qi 'not .*coverage' '$TMPROOT/out5.txt'"
rc5e=0; ech "$R5" delegate mine --validate >"$TMPROOT/out5e.txt" 2>&1 || rc5e=$?
V5="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R5/.git/lcars/autopilot.json" | tr -d ' ')"
check "5e. a RECORDED REQUEST is always honoured, with no trigger at all" \
  "[ $rc5e -eq 0 ] && [ -n '$V5' ]"
check "5f. the record says the lane it came down" \
  "[ \"\$(apj '$R5' delegates.$V5.validationTrigger)\" = driver-request ]"
check "5g. …and that it does NOT count as coverage" \
  "[ \"\$(apj '$R5' delegates.$V5.countsAsCoverage)\" = false ]"
check "5h. the mint says so out loud, where the operator reads it" \
  "grep -qi 'does NOT count as validation coverage' '$TMPROOT/out5e.txt'"
ech "$R5" delegates >"$TMPROOT/out5i.txt" 2>&1
check "5i. and the board says so too — coverage is visible, not buried in JSON" \
  "grep -qi 'does not count as coverage' '$TMPROOT/out5i.txt'"
check "5j. …and it shows the shape: a sibling validator at layer one" \
  "grep -qi 'validator' '$TMPROOT/out5i.txt' && grep -qi 'layer 1' '$TMPROOT/out5i.txt'"
# AND THE REQUEST ITSELF IS VISIBLE WHERE THE DECISION IS MADE. `delegates` is
# the screen the main ECH reads to decide whether to spend a sibling, so a
# request it cannot see is a request it will not honour.
R5R="$(fast_chunk_repo)"
ech_as d1 "$R5R" request-validator "I cannot tell if the river renders" >/dev/null 2>&1
ech "$R5R" delegates >"$TMPROOT/out5m.txt" 2>&1
check "5m. an OUTSTANDING request shows on the board, with the reason" \
  "grep -qi 'REQUESTED A VALIDATOR' '$TMPROOT/out5m.txt' \
   && grep -q 'river renders' '$TMPROOT/out5m.txt'"
check "5n. …saying there and then that it does not count as coverage" \
  "grep -i 'REQUESTED A VALIDATOR' '$TMPROOT/out5m.txt' | grep -qi 'does not count as coverage'"
check "5o. [control] a seat that has NOT asked shows no request line" \
  "[ \"\$(grep -ci 'REQUESTED A VALIDATOR' '$TMPROOT/out5m.txt')\" = 1 ]"
# [CONTROL] A REQUEST BY ANOTHER CHUNK'S DRIVER UNLOCKS NOTHING HERE. Otherwise
# one seat's uncertainty would buy a validator over somebody else's work, which
# is a reach across chunks by the back door.
R5B="$(fast_chunk_repo)"
ech_as d9 "$R5B" request-validator "I am unsure about MY chunk" >/dev/null 2>&1
rc5k=0; ech "$R5B" delegate mine --validate >"$TMPROOT/out5k.txt" 2>&1 || rc5k=$?
check "5k. [control] a request from ANOTHER chunk's driver unlocks nothing here" \
  "[ $rc5k -ne 0 ] && grep -qi 'driving sub-ECH validates' '$TMPROOT/out5k.txt'"
rc5l=0; ech "$R5B" request-validator "as the main ECH" >"$TMPROOT/out5l.txt" 2>&1 || rc5l=$?
check "5l. the MAIN ECH is refused the request lane — it mints with a trigger" \
  "[ $rc5l -ne 0 ] && grep -q -- '--trigger' '$TMPROOT/out5l.txt'"
echo

# =========================================================================
printf '== 6. AT MOST THREE ROUNDS, THEN THE MAIN ECH DECIDES ==\n'
# =========================================================================
R6="$(fast_chunk_repo)"
ech "$R6" delegate mine --validate --trigger wide --why "the declared keystone" \
  >/dev/null 2>&1
V6="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R6/.git/lcars/autopilot.json" | tr -d ' ')"
# A re-check needs something filed to re-check: round 1's findings.
ech_as "$V6" "$R6" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out6f.txt" 2>&1
rc6a=0; ech "$R6" revalidate "$V6" >"$TMPROOT/out6a.txt" 2>&1 || rc6a=$?
check "6a. round 2 opens" \
  "[ $rc6a -eq 0 ] && [ \"\$(apj '$R6' units.mine.validationRound)\" = 2 ]"
rc6b=0; ech "$R6" revalidate "$V6" >"$TMPROOT/out6b.txt" 2>&1 || rc6b=$?
check "6b. round 3 opens" \
  "[ $rc6b -eq 0 ] && [ \"\$(apj '$R6' units.mine.validationRound)\" = 3 ]"
rc6c=0; ech "$R6" revalidate "$V6" >"$TMPROOT/out6c.txt" 2>&1 || rc6c=$?
check "6c. ROUND 4 IS REFUSED" "[ $rc6c -ne 0 ]"
check "6d. the refusal names the three-round bound" \
  "grep -qi 'three rounds' '$TMPROOT/out6c.txt'"
check "6e. …and hands the call to the MAIN ECH" \
  "grep -qi 'main ECH decides' '$TMPROOT/out6c.txt'"
check "6f. …and says the main ECH does NOT validate again" \
  "grep -qi 'does not validate' '$TMPROOT/out6c.txt'"
check "6g. …and it borrows ORCHESTRATION.md's own bound rather than inventing one" \
  "grep -qi 'ORCHESTRATION' '$TMPROOT/out6c.txt'"
check "6h. nothing advanced: the chunk is still at round 3" \
  "[ \"\$(apj '$R6' units.mine.validationRound)\" = 3 ]"
# ONE COUNTER, BOTH DOORS. Closing the validator and minting a fresh one must
# not reset the bound — that is the obvious way round it.
ech "$R6" delegate close "$V6" >/dev/null 2>&1
rc6i=0; ech "$R6" delegate mine --validate --trigger wide --why "another pass" \
  >"$TMPROOT/out6i.txt" 2>&1 || rc6i=$?
check "6i. a FRESH validator on a chunk already at three rounds is refused too" \
  "[ $rc6i -ne 0 ] && grep -qi 'three rounds' '$TMPROOT/out6i.txt'"
# VALIDATION IS NEVER RE-DELEGATED, and `revalidate` is where that would happen.
R6B="$(fast_chunk_repo)"
ech "$R6B" delegate mine --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V6B="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R6B/.git/lcars/autopilot.json" | tr -d ' ')"
rc6j=0; ech_as d1 "$R6B" revalidate "$V6B" >"$TMPROOT/out6j.txt" 2>&1 || rc6j=$?
check "6j. a sub-ECH cannot open a validation round — not a verb it may run" \
  "[ $rc6j -ne 0 ] && grep -q 'NOT A VERB A SUB-ECH MAY RUN' '$TMPROOT/out6j.txt'"
rc6k=0; ech_as "$V6B" "$R6B" revalidate "$V6B" >"$TMPROOT/out6k.txt" 2>&1 || rc6k=$?
check "6k. …and neither can the VALIDATOR itself — validation is not self-renewing" \
  "[ $rc6k -ne 0 ]"
rc6l=0; ech "$R6B" revalidate d1 >"$TMPROOT/out6l.txt" 2>&1 || rc6l=$?
check "6l. \`revalidate\` on a DRIVER is refused — it is not a validation pass" \
  "[ $rc6l -ne 0 ] && grep -qi 'is not a validator' '$TMPROOT/out6l.txt'"
echo

# =========================================================================
printf '== 7. ON RE-REPORT IT RE-CHECKS ONLY WHAT IT FILED ==\n'
# =========================================================================
R7="$(fast_chunk_repo)"
ech "$R7" delegate mine --validate --trigger irreversible --why "it writes to the forge" \
  >/dev/null 2>&1
V7="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R7/.git/lcars/autopilot.json" | tr -d ' ')"
# ROUND 1 IS THE WHOLE CHUNK. That is what a validation pass IS.
rc7a=0; ech_as "$V7" "$R7" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out7a.txt" 2>&1 || rc7a=$?
check "7a. round 1: the validator may file against the whole chunk" \
  "[ $rc7a -eq 0 ] && grep -q 'FILED: bug-001' '$TMPROOT/out7a.txt'"
check "7b. ITS FINDINGS GO TO THE DRIVER: the bug is recorded as the DRIVER's" \
  "grep -q '^bug-001	d1\$' '$R7/.git/lcars/chunk-owners'"
check "7c. …and the mint's own words say so, where the seat reads them" \
  "grep -qi 'the driver' '$TMPROOT/out7a.txt'"
check "7d. the producer RECORDS what it filed — nothing greps for it later" \
  "apj '$R7' delegates.$V7.filed | grep -q 'bug-001'"
rc7e=0; ech "$R7" revalidate "$V7" >"$TMPROOT/out7e.txt" 2>&1 || rc7e=$?
check "7e. the re-check SCOPE is snapshotted when the round opens" \
  "[ $rc7e -eq 0 ] && apj '$R7' delegates.$V7.recheckScope | grep -q 'bug-001'"
# THROUGH THE SAME CHOKE POINT 7g AND 7j GO THROUGH, so the positive and the
# negative are the same mechanism answering differently — a positive measured
# somewhere else proves the narrowing exists, not that it narrows correctly.
rc7f=0; ech_as "$V7" "$R7" file-bug --parent bug-001 --prd "$PRD_GOOD" \
  >"$TMPROOT/out7f.txt" 2>&1 || rc7f=$?
check "7f. round 2: the validator MAY still work the bug it filed" \
  "[ $rc7f -eq 0 ] && grep -q 'FILED:' '$TMPROOT/out7f.txt'"
rc7g=0; ech_as "$V7" "$R7" live-check m-mine --type cli >"$TMPROOT/out7g.txt" 2>&1 || rc7g=$?
check "7g. ROUND 2 WIDENING IS REFUSED: the chunk root is out of its re-check" \
  "[ $rc7g -ne 0 ] && grep -qi 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out7g.txt'"
check "7h. …and the refusal names what it DID file, so the bound is actionable" \
  "grep -q 'bug-001' '$TMPROOT/out7g.txt'"
check "7i. …and the terminating rule, so a widening seat learns why" \
  "grep -qi 'never the whole chunk again' '$TMPROOT/out7g.txt'"
rc7j=0; ech_as "$V7" "$R7" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out7j.txt" 2>&1 || rc7j=$?
check "7j. a NEW filing against the chunk root is refused in round 2 as well" \
  "[ $rc7j -ne 0 ] && grep -qi 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out7j.txt'"
# [CONTROL] THE DRIVER IS NOT NARROWED. The narrowing is the VALIDATOR's bound,
# and a control that cannot tell them apart would pass on a build that froze
# everybody.
rc7k=0; ech_as d1 "$R7" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out7k.txt" 2>&1 || rc7k=$?
check "7k. [control] the DRIVER still owns its whole chunk in round 2" \
  "[ $rc7k -eq 0 ] && grep -q 'FILED:' '$TMPROOT/out7k.txt'"
# A VALIDATION PASS LOOKS AND FILES; IT DOES NOT FIX. The findings go to the
# driver, so `drive` is not a validator's verb — at ANY round, including the
# first, which is why this is measured at round 2 AND at round 1 below.
rc7l=0; ech_as "$V7" "$R7" drive bug-001 >"$TMPROOT/out7l.txt" 2>&1 || rc7l=$?
check "7l. a validator may not DRIVE a fix, even for a bug it filed itself" \
  "[ $rc7l -ne 0 ] && grep -qi 'A VALIDATION PASS DOES NOT FIX' '$TMPROOT/out7l.txt'"
check "7m. …and the refusal names the seat the finding goes to instead" \
  "grep -q 'd1' '$TMPROOT/out7l.txt' && grep -q 'file-bug' '$TMPROOT/out7l.txt'"
R7B="$(fast_chunk_repo)"
ech "$R7B" delegate mine --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V7B="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R7B/.git/lcars/autopilot.json" | tr -d ' ')"
rc7n=0; ech_as "$V7B" "$R7B" drive m-mine >"$TMPROOT/out7n.txt" 2>&1 || rc7n=$?
check "7n. …refused at ROUND 1 too, not only once it is narrowed" \
  "[ $rc7n -ne 0 ] && grep -qi 'A VALIDATION PASS DOES NOT FIX' '$TMPROOT/out7n.txt'"
rc7o=0; ech_as d1 "$R7B" drive m-mine >"$TMPROOT/out7o.txt" 2>&1 || rc7o=$?
check "7o. [control] the DRIVER's own \`drive\` is untouched by that refusal" \
  "! grep -qi 'A VALIDATION PASS DOES NOT FIX' '$TMPROOT/out7o.txt'"
echo

# =========================================================================
printf '== 8. NO SPIRAL: one pass per chunk per round, and no validating a validator ==\n'
# =========================================================================
R8="$(fast_chunk_repo)"
ech "$R8" delegate mine --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V8="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(k for k,v in (d.get("delegates") or {}).items() if (v or {}).get("validates")))
' "$R8/.git/lcars/autopilot.json" | tr -d ' ')"
rc8a=0; ech "$R8" delegate mine --validate --trigger undetectable --why "a second pair" \
  >"$TMPROOT/out8a.txt" 2>&1 || rc8a=$?
check "8a. TWO VALIDATORS ON ONE CHUNK IS REFUSED while one is open" \
  "[ $rc8a -ne 0 ] && grep -qi 'one validation pass' '$TMPROOT/out8a.txt'"
check "8b. …and it names the one that is already on it" \
  "[ -n '$V8' ] && grep -q \"$V8\" '$TMPROOT/out8a.txt'"
# A VALIDATOR VALIDATING A VALIDATOR. With the driver closed the only open seat
# on the chunk is the validator, which is the shape that would let a pass be
# validated in turn — the spiral by another name.
ech "$R8" delegate close d1 >/dev/null 2>&1
rc8c=0; ech "$R8" delegate mine --validate --trigger wide --why "validate the validator" \
  >"$TMPROOT/out8c.txt" 2>&1 || rc8c=$?
check "8c. A VALIDATION PASS IS NOT ITSELF VALIDATED" \
  "[ $rc8c -ne 0 ] && grep -qi 'is not itself validated' '$TMPROOT/out8c.txt'"
rc8d=0; ech_as "$V8" "$R8" delegate theirs >"$TMPROOT/out8d.txt" 2>&1 || rc8d=$?
check "8d. a VALIDATOR cannot mint anything either — the cap is on every seat" \
  "[ $rc8d -ne 0 ] && grep -qi 'ONE LAYER' '$TMPROOT/out8d.txt'"
# AND A CHUNK NOTHING HAS DRIVEN HAS NOTHING TO VALIDATE INDEPENDENTLY.
R8B="$(fast_chunk_repo)"
ech "$R8B" delegate close d1 >/dev/null 2>&1
rc8e=0; ech "$R8B" delegate mine --validate --trigger wide --why "nobody drove it" \
  >"$TMPROOT/out8e.txt" 2>&1 || rc8e=$?
check "8e. a chunk with no DRIVING seat has nothing to validate independently" \
  "[ $rc8e -ne 0 ] && grep -qi 'no .*sub-ECH .*driv' '$TMPROOT/out8e.txt'"
echo

# =========================================================================
printf '== 9. KNOWN-GOOD CONTROL: one chunk, no validator, BYTE-IDENTICAL ==\n'
# =========================================================================
BASE_DIR="$TMPROOT/baseline"
mkdir -p "$BASE_DIR"
base_ok=0
if git -C "$REPO_ROOT" rev-parse --verify "$BASELINE_REF^{commit}" >/dev/null 2>&1; then
  if git -C "$REPO_ROOT" archive "$BASELINE_REF" skills | tar -x -C "$BASE_DIR" 2>/dev/null; then
    base_ok=1
  fi
fi
check "9a. the BASELINE ($BASELINE_REF) was extracted — a control that cannot run is not a pass" \
  "[ '$base_ok' = 1 ] && [ -f '$BASE_DIR/skills/lcars-eeh/ech.sh' ]"
BASE_SCRIPT="$BASE_DIR/skills/lcars-eeh/ech.sh"

# ONE CHUNK, ONE DRIVER, NO VALIDATOR — which is every run the captain has had
# until tonight. Both scripts read the SAME repo, so only the two checkout roots
# differ and they are normalised away.
R9="$(fast_chunk_repo)"
ech "$R9" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
for v in delegates status stalled next; do
  ech_at "$BASE_SCRIPT" "$R9" "$v" >"$TMPROOT/before.$v" 2>&1 || true
  ech_at "$SCRIPT"      "$R9" "$v" >"$TMPROOT/after.$v"  2>&1 || true
  sed -i.bak "s#$BASE_DIR/##g"  "$TMPROOT/before.$v" 2>/dev/null || true
  sed -i.bak "s#$REPO_ROOT/##g" "$TMPROOT/after.$v"  2>/dev/null || true
  check "9b.$v. \`$v\` is BYTE-IDENTICAL on a single-chunk repo with no validator" \
    "diff -q '$TMPROOT/before.$v' '$TMPROOT/after.$v' >/dev/null"
done
check "9c. …and there was real content to compare" \
  "[ -s '$TMPROOT/after.delegates' ] && grep -q 'd1' '$TMPROOT/after.delegates'"

# AND A WHOLE MINT, which is the verb this session actually changed. Two
# identical repos, because a unit can only be minted once.
mint_out() {   # mint_out <script> <outfile>
  local s="$1" o="$2" r
  r="$(new_repo)"
  ap_init "$r"
  new_mission "$r" m-solo verify
  ech_at "$s" "$r" record 'missions.solo.id' m-solo >/dev/null 2>&1
  ech_at "$s" "$r" tier solo --tier T1 --why "one owner end to end" >/dev/null 2>&1
  ech_at "$s" "$r" delegate solo >"$o" 2>&1
  sed -i.bak -e "s#$r#REPO#g" -e "s#$BASE_DIR/##g" -e "s#$REPO_ROOT/##g" "$o" 2>/dev/null || true
  printf '%s\n' "$r"
}
R9B="$(mint_out "$BASE_SCRIPT" "$TMPROOT/before.mint")"
R9C="$(mint_out "$SCRIPT"      "$TMPROOT/after.mint")"
check "9d. a plain \`delegate\` mint's own OUTPUT is byte-identical to the baseline" \
  "diff -q '$TMPROOT/before.mint' '$TMPROOT/after.mint' >/dev/null"
check "9e. …and both really minted (an empty-vs-empty diff is not a control)" \
  "grep -q 'MINTED: d1' '$TMPROOT/after.mint' && grep -q 'MINTED: d1' '$TMPROOT/before.mint'"

# THE DISCRIMINATION SELF-TEST. A control that cannot fail on a known-bad build
# proves nothing — four of those shipped on 2026-11-18. So the SAME method is
# pointed at a deliberately broken ech.sh, and the diff MUST fire.
BROKEN="$TMPROOT/broken-ech.sh"
sed 's/^  say "DELEGATES"$/  say "DELEGATES (broken)"/' "$SCRIPT" >"$BROKEN"
check "9f. the broken build really differs from the real one by one line" \
  "! diff -q '$SCRIPT' '$BROKEN' >/dev/null && grep -q 'DELEGATES (broken)' '$BROKEN'"
ech_at "$BROKEN" "$R9" delegates >"$TMPROOT/broken.delegates" 2>&1 || true
sed -i.bak "s#$REPO_ROOT/##g" "$TMPROOT/broken.delegates" 2>/dev/null || true
check "9g. [discrimination] the SAME diff FIRES on the known-bad build" \
  "! diff -q '$TMPROOT/before.delegates' '$TMPROOT/broken.delegates' >/dev/null"
echo

# =========================================================================
printf '== 10. THE RULES ARE WRITTEN DOWN, AND THE OLD PERMISSION IS GONE ==\n'
# =========================================================================
check "10a. DELEGATION.md states the one-layer cap" \
  "grep -qi 'EXACTLY ONE LAYER' '$DOC'"
check "10b. …and that a sub-ECH may not mint one" \
  "grep -qi 'MAY NOT MINT' '$DOC'"
check "10c. …and both legal alternatives" \
  "grep -qi 'more Missions' '$DOC' && grep -q 'BLOCKED:' '$DOC'"
check "10d. THE OLD UNBOUNDED PERMISSION IS GONE" \
  "! grep -qi 'divide the unit between sub-delegates' '$DOC' \
   && ! grep -qi 'may divide its unit between sub-delegates' '$DOC'"
# AGAINST A REAL MINT'S BRIEF — § 2's. `fast_chunk_repo`'s brief is a two-word
# fixture stand-in, and a grep against that is a grep against nothing.
BF9="$R2/.git/lcars/delegates/d1/BRIEF.md"
check "10e0. [control] the brief under test is a REAL mint's, not the fixture's" \
  "[ -f \"$BF9\" ] && [ \"\$(wc -c <\"$BF9\" | tr -d ' ')\" -gt 4000 ]"
check "10e. …from the minted brief too" \
  "! grep -qi 'may divide this unit between sub-delegates' \"$BF9\""
check "10f. the three triggers are named in the doc" \
  "grep -qi 'UNDETECTABLE' '$DOC' && grep -qi 'IRREVERSIBLE' '$DOC' && grep -qi 'WIDE' '$DOC'"
check "10g. …size-as-proxy is declared NOT a trigger" \
  "grep -qi 'size-as-proxy' '$DOC'"
check "10h. …a visual change is declared NOT a trigger" \
  "grep -qi 'not .*the chunk changes something visual\|button moving' '$DOC'"
check "10i. …the request lane is never counted as coverage" \
  "grep -qi 'never be counted as coverage\|not .*counted as coverage' '$DOC'"
check "10j. …three rounds, then the main ECH decides" \
  "grep -qi 'three rounds' '$DOC' && grep -qi 'main ECH' '$DOC'"
check "10k. …validation is never re-delegated" \
  "grep -qi 'never re-delegated' '$DOC'"
check "10l. …and a validator is a SIBLING, still layer one" \
  "grep -qi 'SIBLING' '$DOC'"
# REGRESSION GUARD for tests/delegation.test.sh § S352fix/7: the ENGINE row
# rule is about the WINDOWS a delegate opens, not about minting an ECH seat, and
# removing the mint permission must not take it with it.
check "10m0. the DRIVING brief states the cap it is held to" \
  "grep -qi 'exactly ONE LAYER deep' \"$BF9\""
check "10m1. …and both alternatives, so a seat reaching for \`delegate\` has a door" \
  "grep -qi 'more Missions for the factory' \"$BF9\" && grep -q 'BLOCKED:' \"$BF9\""
check "10m2. …and the ninth verb is explained, not just listed" \
  "grep -q 'request-validator' \"$BF9\" && grep -i 'request-validator' \"$BF9\" \
   | grep -qv '^ *beat exec'"
check "10m. [regression] the brief still says every seat it opens takes the stamped row" \
  "grep -qi 'every seat you open' \"$BF9\""
check "10n. [regression] …and still names a sub-delegate seat as one of them" \
  "grep -qi 'sub-delegate' \"$BF9\""
echo

# --- zero spend, every run ------------------------------------------------
check "15a. ZERO worker spend: no claude/copilot was invoked" \
  "[ ! -s '$LCARS_DRIVE_SHIM_LOG' ]"

echo
printf 'one-layer-validation: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
