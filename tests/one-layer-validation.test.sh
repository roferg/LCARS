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
#    or: python3 tests/lib/cage.py 3000 bash tests/one-layer-validation.test.sh
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

# validator_of <repo> → the id of the open validating seat, or nothing. The
# suite asked this with an inline python block eight times over; one helper, so
# a row that needs it cannot quietly ask a different question.
validator_of() {
  python3 - "$1/.git/lcars/autopilot.json" <<'PYVOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for k in sorted((d.get("delegates") or {})):
    v = (d.get("delegates") or {})[k]
    if isinstance(v, dict) and v.get("validates") and v.get("status") != "done":
        sys.stdout.write(k)
        break
PYVOF
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

# ==========================================================================
# THE EXEC TREE — `exec` resolves a script at $SKILLS_DIR/<skill>/<script>,
# where SKILLS_DIR comes from the LAUNCHER's own path. So the fixture plants a
# whole fake skills tree, copies the ech.sh under test into it, and runs THAT
# copy: the real resolution rule is exercised rather than bypassed, and the code
# under test is unchanged. (The pattern is tests/chunk-authority.test.sh's.)
#
# EVERY STAND-IN LOGS THAT IT RAN. That is the whole point: fix round 1's defect
# was a validation pass REACHING the stage machine through `exec`, and the only
# honest proof of a cure is that the thing on the other side of the door was
# never invoked.
EXEC_SKILLS="$TMPROOT/exec-skills"
mkdir -p "$EXEC_SKILLS/lcars-eeh" "$EXEC_SKILLS/lcars-run" "$EXEC_SKILLS/lcars-log" \
         "$EXEC_SKILLS/lcars-file" "$EXEC_SKILLS/lcars-respond" "$EXEC_SKILLS/lcars-resolve-logs"
cp -R "$(dirname "$SCRIPT")/." "$EXEC_SKILLS/lcars-eeh/"
# `live-check` resolves its checklists under $SKILLS_DIR/lcars-run/live-check/,
# so a tree without them refuses for a reason that has nothing to do with
# authority.
cp -R "$(dirname "$SCRIPT")/../lcars-run/live-check" "$EXEC_SKILLS/lcars-run/" 2>/dev/null || true
cat >"$EXEC_SKILLS/lcars-run/run.sh" <<'XSH'
#!/usr/bin/env bash
printf 'RAN lcars-run/run.sh %s\n' "$*" >>"$LCARS_ECH_CWD/exec-ran.log"
XSH
for xp in lcars-respond/respond.sh lcars-resolve-logs/resolve-logs.sh; do
  printf '#!/usr/bin/env bash\nprintf "RAN %%s %%s\\n" "%s" "$*" >>"$LCARS_ECH_CWD/exec-ran.log"\n' \
    "$xp" >"$EXEC_SKILLS/$xp"
done
# A `log.sh` that FILES FOR REAL the way log.sh does, so the `file` act can be
# measured end to end (`exec` consumes the producer's filing receipt).
cat >"$EXEC_SKILLS/lcars-log/log.sh" <<'XSH'
#!/usr/bin/env bash
printf 'RAN lcars-log/log.sh %s\n' "$*" >>"$LCARS_ECH_CWD/exec-ran.log"
parent=""; while [ $# -gt 0 ]; do case "$1" in --parent) parent="$2"; shift ;; esac; shift; done
n=1; while [ -d "$LCARS_ECH_CWD/.git/lcars/missions/xbug-$n" ]; do n=$((n+1)); done
d="$LCARS_ECH_CWD/.git/lcars/missions/xbug-$n"; mkdir -p "$d"
printf '{"id":"xbug-%s","stage":"align","type":"bug","title":"a filed bug","branch":"lcars/%s","parentMission":"%s","parentIssue":"1"}\n' \
  "$n" "$parent" "$parent" >"$d/state.json"
[ -z "${LCARS_FILING_RECEIPT:-}" ] || printf '%s\n' "xbug-$n" >>"$LCARS_FILING_RECEIPT"
XSH
# …and a `file.sh` that CREATES a Mission, so `subdivide` is a real act too.
cat >"$EXEC_SKILLS/lcars-file/file.sh" <<'XSH'
#!/usr/bin/env bash
printf 'RAN lcars-file/file.sh %s\n' "$*" >>"$LCARS_ECH_CWD/exec-ran.log"
id="filed-$$"; d="$LCARS_ECH_CWD/.git/lcars/missions/$id"; mkdir -p "$d"
printf '{"id":"%s","stage":"verify","type":"feature","title":"m","branch":"lcars/%s","issue":"1"}\n' "$id" "$id" >"$d/state.json"
[ -z "${LCARS_FILING_RECEIPT:-}" ] || printf '%s\n' "$id" >>"$LCARS_FILING_RECEIPT"
git -C "$LCARS_ECH_CWD" branch -q "lcars/$id" main 2>/dev/null || true
XSH
chmod +x "$EXEC_SKILLS"/lcars-*/*.sh
EXEC_SCRIPT="$EXEC_SKILLS/lcars-eeh/$(basename "$SCRIPT")"
# xech <seat|-> <repo> <args…> — through the fake tree, as a seat or as the main ECH
xech() {
  local seat="$1" repo="$2"; shift 2
  if [ "$seat" = "-" ]; then ech_at "$EXEC_SCRIPT" "$repo" "$@"
  else LCARS_ECH_AS="$seat" ech_at "$EXEC_SCRIPT" "$repo" "$@"; fi
}
ran_log() { cat "$1/exec-ran.log" 2>/dev/null | tr '\n' '|'; }

# stage_evidence <repo> <mission> — write the PAIRED EVIDENCE `live-check done`
# demands, one row per prepared target: a detector, a target that passes, a
# known-fail control that fails, distinct nonempty evidence files, and a reason
# the control is known to fail.
#
# WITHOUT THIS, § 11 COULD NOT MEASURE THE MERGE END OF THE THREE-STEP ROUTE AT
# ALL. `11i`/`11k` both passed on a mutant that removed the act decider
# entirely, because the refusal they were reading was `live-check done`'s own
# evidence gate and not the authority boundary — a control that reads the wrong
# refusal cannot tell the two builds apart. With the evidence staged, the
# baseline really does reach `ACTION: merge` and the rows discriminate.
stage_evidence() {
  # TWO `local` STATEMENTS, NOT ONE, AND THAT IS NOT STYLE. Measured:
  #   f() { local a="$1" b="$a/x"; echo "$b"; };  f hello  ->  /x
  # bash does NOT see an earlier assignment from within the SAME `local`, so the
  # one-liner this replaces computed its evidence path from an EMPTY `$repo` and
  # tried to write to `/.git/…`. It failed silently inside a command
  # substitution, the fixture produced nothing, and four rows went red pointing
  # at the product.
  local repo="$1" m="$2"
  local ev="$repo/.git/lcars/missions/$m/live-check"
  mkdir -p "$ev"
  python3 - "$repo/.git/lcars/autopilot.json" "$m" "$ev" <<'PYEV'
import json, os, sys
ap, m, ev = sys.argv[1:4]
d = json.load(open(ap))
targets = (((d.get("liveChecks") or {}).get(m) or {}).get("targets")) or []
rows = []
for t in targets:
    safe = "".join(c if c.isalnum() else "_" for c in t)
    for role in ("t", "c"):
        fp = os.path.join(ev, "%s-%s.txt" % (safe, role))
        with open(fp, "w") as fh:
            fh.write("observed output for %s (%s), looked at" % (t, role))
    rows.append({
        "id": t, "detector": "the same grep on both cases",
        "target":  {"verdict": "pass", "observation": "the row rendered the configured host",
                    "evidence": "%s-t.txt" % safe},
        "control": {"verdict": "fail", "observation": "the row rendered the default host",
                    "evidence": "%s-c.txt" % safe,
                    "knownFailure": "the control is built from the pre-fix commit"},
    })
with open(os.path.join(ev, "checks.json"), "w") as fh:
    json.dump(rows, fh, indent=2)
print(len(rows))
PYEV
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
# NO DEFAULT ON THE READ. The first version used `.get("depth", 1)`, which
# defaults a MISSING field to the value the row is looking for — so a build that
# forgot to write `depth` at all read as compliant. A seat with no depth is now
# reported by this row, not excused by it.
check "2d. a sub-ECH's attempt leaves NO layer-two record, and no seat without a depth" \
  "[ $rc2 -ne 0 ] && [ -z \"\$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
bad=[k for k,v in (d.get(\"delegates\") or {}).items() if (v or {}).get(\"depth\") != 1]
print(\" \".join(bad))
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
V3="$(validator_of "$R3")"
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
check "3g. the round is recorded on the CHUNK — keyed by MISSION, not by unit label" \
  "[ \"\$(apj '$R3' delegates.$V3.validationRound)\" = 1 ] \
   && [ \"\$(apj '$R3' validations.m-mine.round)\" = 1 ] \
   && [ -z \"\$(apj '$R3' units.mine.validationRound)\" ]"
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
  VT="$(validator_of "$RT")"
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
  "[ -z \"\$(apj '$R4' delegates.d2.id)\" ] && [ -z \"\$(apj '$R4' validations.m-mine.round)\" ]"
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
V5="$(validator_of "$R5")"
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
  "grep -i 'REQUESTED A VALIDATOR' '$TMPROOT/out5m.txt' | grep -i 'does not count as coverage' >/dev/null"
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
V6="$(validator_of "$R6")"
# A re-check needs something filed to re-check: round 1's findings.
ech_as "$V6" "$R6" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out6f.txt" 2>&1
rc6a=0; ech "$R6" revalidate "$V6" >"$TMPROOT/out6a.txt" 2>&1 || rc6a=$?
check "6a. round 2 opens" \
  "[ $rc6a -eq 0 ] && [ \"\$(apj '$R6' validations.m-mine.round)\" = 2 ]"
rc6b=0; ech "$R6" revalidate "$V6" >"$TMPROOT/out6b.txt" 2>&1 || rc6b=$?
check "6b. round 3 opens" \
  "[ $rc6b -eq 0 ] && [ \"\$(apj '$R6' validations.m-mine.round)\" = 3 ]"
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
  "[ \"\$(apj '$R6' validations.m-mine.round)\" = 3 ]"
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
V6B="$(validator_of "$R6B")"
rc6j=0; ech_as d1 "$R6B" revalidate "$V6B" >"$TMPROOT/out6j.txt" 2>&1 || rc6j=$?
check "6j. a sub-ECH cannot open a validation round — not a verb it may run" \
  "[ $rc6j -ne 0 ] && grep -q 'NOT A VERB A SUB-ECH MAY RUN' '$TMPROOT/out6j.txt'"
# 6k IS DELETED, AND SAYING WHY IS THE POINT. It asserted only an exit code,
# and that exit code comes from the SAME boundary 6j already pins — so it
# passed at `04e9de1`, where `revalidate` does not exist at all and every
# unknown verb exits non-zero. Two rows, one mechanism, one of them unable to
# fail. 6j keeps the rule.
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
V7="$(validator_of "$R7")"
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
# ONE HALF OF AN A/B PAIR WITH 7g, AND THAT IS ALL IT IS. On its own this row
# cannot fail where no narrowing exists — it passes at `04e9de1` — so the
# earlier claim that it was "the same mechanism answering differently" was
# wrong. Its value is as the OTHER side of 7g: a build that narrows EVERYTHING
# passes 7g and fails this, and 7p below proves exactly that against a
# deliberately over-narrowing build.
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
V7B="$(validator_of "$R7B")"
rc7n=0; ech_as "$V7B" "$R7B" drive m-mine >"$TMPROOT/out7n.txt" 2>&1 || rc7n=$?
check "7n. …refused at ROUND 1 too, not only once it is narrowed" \
  "[ $rc7n -ne 0 ] && grep -qi 'A VALIDATION PASS DOES NOT FIX' '$TMPROOT/out7n.txt'"
rc7o=0; ech_as d1 "$R7B" drive m-mine >"$TMPROOT/out7o.txt" 2>&1 || rc7o=$?
check "7o. [control] the DRIVER's own \`drive\` is not refused as a validation pass's" \
  "! grep -q 'NOT AN ACT A VALIDATION PASS MAY PERFORM' '$TMPROOT/out7o.txt' \
   && ! grep -q 'IS OUTSIDE YOUR RE-CHECK' '$TMPROOT/out7o.txt'"
# AND THE PROOF THAT 7f CAN FAIL. 7f on its own passes anywhere no narrowing
# exists, so it is not a control by itself — it is the other half of 7g. Here is
# the build that separates them: one where an EMPTY scope narrows everything
# (which is exactly fix round 1's CURE 3 defect). 7g passes on it; 7f does not.
# IT LIVES IN A REAL SKILLS TREE, and that is not incidental: a launcher
# resolves its brief template, its tier fences and `bug-prd.md` from its OWN
# directory, so a broken copy dropped in $TMPROOT cannot mint at all — its
# `delegate` dies on the missing template, `validator_of` comes back empty,
# `LCARS_ECH_AS=""` runs as the MAIN ECH, and the row then "fails" for a reason
# that has nothing to do with narrowing. Measured, and it is how this control
# was passing-by-accident-of-failure on its first write.
NARROW_BAD="$EXEC_SKILLS/lcars-eeh/over-narrow.sh"
sed 's@^  \[ -n "\$scope" \] || return 0$@  [ -n "$scope" ] || scope="__nothing__"@' "$SCRIPT" >"$NARROW_BAD"
check "7p0. the over-narrowing build really differs from this one, by that one line" \
  "! diff -q '$SCRIPT' '$NARROW_BAD' >/dev/null && grep -q '__nothing__' '$NARROW_BAD'"
R7P="$(fast_chunk_repo)"
ech_at "$NARROW_BAD" "$R7P" delegate mine --validate --trigger wide --why "the keystone" \
  >"$TMPROOT/out7p0.txt" 2>&1
V7P="$(validator_of "$R7P")"
check "7p1. [control] the broken build really minted a validator, so the row can run" \
  "[ -n '$V7P' ] && grep -q 'MINTED' '$TMPROOT/out7p0.txt'"
rc7p=0
LCARS_ECH_AS="$V7P" ech_at "$NARROW_BAD" "$R7P" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out7p.txt" 2>&1 || rc7p=$?
check "7p. [discrimination] 7f's own assertion FAILS on an over-narrowing build" \
  "[ $rc7p -ne 0 ] && grep -q 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out7p.txt'"
# NOT A RESTATEMENT OF 7f — the SAME COMMAND on the two builds, side by side,
# which is the comparison 7f alone cannot make.
check "7p2. [discrimination] the identical filing: refused on that build, accepted on this" \
  "[ $rc7p -ne 0 ] && [ $rc7f -eq 0 ] \
   && grep -q 'FILED:' '$TMPROOT/out7f.txt' && ! grep -q 'FILED:' '$TMPROOT/out7p.txt'"
echo

# =========================================================================
printf '== 8. NO SPIRAL: one pass per chunk per round, and no validating a validator ==\n'
# =========================================================================
R8="$(fast_chunk_repo)"
ech "$R8" delegate mine --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V8="$(validator_of "$R8")"
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
# THE GUARANTEE IS ABOUT BEHAVIOUR, NOT ABOUT WHAT THE BOARD MAY DISPLAY
# (captain's ruling, 2026-11-20). The first version demanded the `delegates`
# screen be byte-identical, which a fresh tester showed STRUCTURALLY FORBIDS
# ever telling the operator the layer a seat sits at: it fails on a build that
# prints it. **A control that dictates the product is the wrong control.** So
# the three screens this session did not touch stay byte-for-byte, and
# `delegates` keeps the half that is a real guarantee — every line the shipped
# screen printed is still printed, unchanged — while remaining free to add.
for v in status stalled next; do
  ech_at "$BASE_SCRIPT" "$R9" "$v" >"$TMPROOT/before.$v" 2>&1 || true
  ech_at "$SCRIPT"      "$R9" "$v" >"$TMPROOT/after.$v"  2>&1 || true
  sed -i.bak "s#$BASE_DIR/##g"  "$TMPROOT/before.$v" 2>/dev/null || true
  sed -i.bak "s#$REPO_ROOT/##g" "$TMPROOT/after.$v"  2>/dev/null || true
  check "9b.$v. \`$v\` is BYTE-IDENTICAL on a single-chunk repo with no validator" \
    "diff -q '$TMPROOT/before.$v' '$TMPROOT/after.$v' >/dev/null"
done
ech_at "$BASE_SCRIPT" "$R9" delegates >"$TMPROOT/before.delegates" 2>&1 || true
ech_at "$SCRIPT"      "$R9" delegates >"$TMPROOT/after.delegates"  2>&1 || true
sed -i.bak "s#$BASE_DIR/##g"  "$TMPROOT/before.delegates" 2>/dev/null || true
sed -i.bak "s#$REPO_ROOT/##g" "$TMPROOT/after.delegates"  2>/dev/null || true
missing_lines() {   # lines present in $1 and absent from $2
  comm -23 <(sort "$1") <(sort "$2")
}
check "9b.delegates. every line the SHIPPED \`delegates\` printed is still printed, unchanged" \
  "[ -z \"\$(missing_lines '$TMPROOT/before.delegates' '$TMPROOT/after.delegates')\" ]"
check "9b.delegates2. …and on a no-validator repo it adds nothing either" \
  "[ -z \"\$(missing_lines '$TMPROOT/after.delegates' '$TMPROOT/before.delegates')\" ]"
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
printf '%s\n' "$R9B" >"$TMPROOT/before.mint.repo"
printf '%s\n' "$R9C" >"$TMPROOT/after.mint.repo"
# WHAT THIS DIFFS IS THE MINT'S **STDOUT**, and saying so matters: the RECORD
# deliberately DID change (`mintedBy`, `depth`), so "a whole mint byte for byte"
# would be a false description of the guarantee. 9d2 asserts the record change
# positively, so the two are never confused again.
check "9d. a plain \`delegate\` mint's own STDOUT is byte-identical to the baseline" \
  "diff -q '$TMPROOT/before.mint' '$TMPROOT/after.mint' >/dev/null"
check "9e. …and both really minted (an empty-vs-empty diff is not a control)" \
  "grep -q 'MINTED: d1' '$TMPROOT/after.mint' && grep -q 'MINTED: d1' '$TMPROOT/before.mint'"
check "9d2. …while the RECORD changed on purpose: the baseline has no minter, this does" \
  "[ -z \"\$(apj \"\$(cat '$TMPROOT/before.mint.repo')\" delegates.d1.mintedBy)\" ] \
   && [ \"\$(apj \"\$(cat '$TMPROOT/after.mint.repo')\" delegates.d1.mintedBy)\" = main ]"

# THE DISCRIMINATION SELF-TEST. A control that cannot fail on a known-bad build
# proves nothing — four of those shipped on 2026-11-18. So the SAME method is
# pointed at a deliberately broken ech.sh, and the diff MUST fire.
BROKEN="$TMPROOT/broken-ech.sh"
sed 's/^  say "DELEGATES"$/  say "DELEGATES (broken)"/' "$SCRIPT" >"$BROKEN"
check "9f. the broken build really differs from the real one by one line" \
  "! diff -q '$SCRIPT' '$BROKEN' >/dev/null && grep -q 'DELEGATES (broken)' '$BROKEN'"
ech_at "$BROKEN" "$R9" delegates >"$TMPROOT/broken.delegates" 2>&1 || true
sed -i.bak "s#$REPO_ROOT/##g" "$TMPROOT/broken.delegates" 2>/dev/null || true
check "9g. [discrimination] the SAME check FIRES on the known-bad build" \
  "[ -n \"\$(missing_lines '$TMPROOT/before.delegates' '$TMPROOT/broken.delegates')\" ]"
check "9g2. …and it is the dropped SHIPPED line that fires it, not noise" \
  "missing_lines '$TMPROOT/before.delegates' '$TMPROOT/broken.delegates' | grep -x 'DELEGATES' >/dev/null"
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
# A REAL BEFORE/AFTER, AND THE NEEDLE IS FLATTENED FIRST. The first version
# greped `may divide this unit between sub-delegates` against the brief as
# written — and that phrase WRAPS A SOURCE LINE BREAK, so the grep matched in no
# revision ever and the row passed at `04e9de1`, whose brief still carries the
# permission. It was the one row charged with proving the removal reached the
# brief. So: mint with the BASELINE script, mint with this one, flatten both,
# and require the needle PRESENT in the first and ABSENT from the second.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
mint_brief() {   # mint_brief <script> <tier> <outfile>
  local s9="$1" t9="$2" o9="$3" r9
  r9="$(new_repo)"; ap_init "$r9"; new_mission "$r9" m-br verify
  ech_at "$s9" "$r9" record 'missions.br.id' m-br >/dev/null 2>&1
  ech_at "$s9" "$r9" tier br --tier "$t9" --why "a brief to compare" >/dev/null 2>&1
  ech_at "$s9" "$r9" delegate br >/dev/null 2>&1
  cp "$r9/.git/lcars/delegates/d1/BRIEF.md" "$o9" 2>/dev/null || : >"$o9"
}
for t10 in T1 T2; do
  mint_brief "$BASE_SCRIPT" "$t10" "$TMPROOT/brief.base.$t10"
  mint_brief "$SCRIPT"      "$t10" "$TMPROOT/brief.now.$t10"
  check "10e.$t10 [known-bad control] the BASELINE $t10 brief DOES carry the permission" \
    "flat '$TMPROOT/brief.base.$t10' | grep -q 'divide this unit between sub-delegates'"
  check "10e2.$t10 …and this build's $t10 brief does NOT" \
    "! flat '$TMPROOT/brief.now.$t10' | grep -q 'divide this unit between sub-delegates'"
  check "10e3.$t10 [regression] …while the ENGINE-row sub-delegate seat rule SURVIVES" \
    "flat '$TMPROOT/brief.now.$t10' | grep -q 'sub-delegate' \
     && flat '$TMPROOT/brief.now.$t10' | grep -q 'every seat you open'"
done
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
# AND THE ACT RULE, which is fix round 1's whole first cure. Each of these is a
# sentence the BASELINE doc does not contain — 10o proves that, so the four
# above it cannot pass on a doc that never learned the rule.
check "10k2. …a validation pass is bounded by the ACT, not by a verb name" \
  "flat '$DOC' | grep -q 'BOUNDED BY THE \*ACT\*, NOT BY A VERB NAME' >/dev/null"
check "10k3. …and the doc names the two acts it MAY perform" \
  "grep -q '\*\*LOOK\*\*' '$DOC' && grep -q '\*\*FILE\*\*' '$DOC'"
check "10k4. …and all four refused ones, including the \`exec\` route for the FIX" \
  "grep -q '\*\*VERDICT\*\*' '$DOC' && grep -q '\*\*DECIDE\*\*' '$DOC' \
   && grep -q '\*\*SUBDIVIDE\*\*' '$DOC' \
   && flat '$DOC' | grep -q 'the same act by another route' >/dev/null"
check "10k5. …and that § 5 of the brief is a SLOT filled by role" \
  "flat '$DOC' | grep -q 'is a \*\*slot\*\*, filled by role exactly once' >/dev/null"
check "10o. [known-bad control] NONE of those sentences is in the baseline doc" \
  "! flat '$BASE_DIR/skills/lcars-eeh/DELEGATION.md' | grep -q 'BOUNDED BY THE' >/dev/null \
   && ! grep -q '\*\*SUBDIVIDE\*\*' '$BASE_DIR/skills/lcars-eeh/DELEGATION.md'"
# NOT THE BARE WORD "SIBLING", which appears 11 times in the BASELINE doc and
# so could never fail. The sentence this round added, flattened, plus the proof
# that the baseline does not contain it.
check "10l. …and a validator is a SIBLING, minted by the main ECH, still layer one" \
  "flat '$DOC' | grep -q 'A validating sub-ECH is a \*\*SIBLING\*\*: minted by the \*\*main ECH\*\*, at \*\*layer one\*\*'"
check "10l2. [known-bad control] …and that sentence is NOT in the baseline doc" \
  "! flat '$BASE_DIR/skills/lcars-eeh/DELEGATION.md' | grep -q 'A validating sub-ECH is a \*\*SIBLING\*\*: minted by the \*\*main ECH\*\*, at \*\*layer one\*\*'"
# REGRESSION GUARD for tests/delegation.test.sh § S352fix/7: the ENGINE row
# rule is about the WINDOWS a delegate opens, not about minting an ECH seat, and
# removing the mint permission must not take it with it.
check "10m0. the DRIVING brief states the cap it is held to" \
  "grep -qi 'exactly ONE LAYER deep' \"$BF9\""
check "10m1. …and both alternatives, so a seat reaching for \`delegate\` has a door" \
  "grep -qi 'more Missions for the factory' \"$BF9\" && grep -q 'BLOCKED:' \"$BF9\""
check "10m2. …and the ninth verb is explained, not just listed" \
  "grep -q 'AND THE NINTH VERB IS YOURS' \"$BF9\" \
   && grep -q 'records that on your seat' \"$BF9\""
check "10m. [regression] the brief still says every seat it opens takes the stamped row" \
  "grep -qi 'every seat you open' \"$BF9\""
check "10n. [regression] …and still names a sub-delegate seat as one of them" \
  "grep -qi 'sub-delegate' \"$BF9\""
echo

# =========================================================================
printf '== 11. THE ACT, NOT THE NAME: the same act by another route is refused ==\n'
# =========================================================================
# FIX ROUND 1, CURE 1. Round 1 wrote the rule at a verb NAME (`[ "$verb" = drive ]`)
# and `cmd_exec` calls the same choke point with `"exec lcars-run/run.sh --mission"`,
# so it never matched. MEASURED BY EFFECT before the cure, in one step:
#
#     validator: drive bug-001                                 -> REFUSED
#     validator: exec lcars-run/run.sh drive --mission bug-001 -> RAN
#
# This is the class S365 fix round 3 already cured for land/approve/push-gated,
# in `subech_exec_target_or_die`'s own words: *"a boundary that bounds only the
# VERB NAMES bounds nothing, because the same act is one `exec` away."*
R11="$(fast_chunk_repo)"
xech - "$R11" delegate mine --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V11="$(validator_of "$R11")"
check "11a. the validator was minted (so the rows below are a real pass's)" "[ -n '$V11' ]"
: >"$R11/exec-ran.log"
rc11a=0; xech "$V11" "$R11" drive m-mine >"$TMPROOT/out11a.txt" 2>&1 || rc11a=$?
check "11b. ROUTE A — the named verb \`drive\` is refused" \
  "[ $rc11a -ne 0 ] && grep -q 'NOT AN ACT A VALIDATION PASS MAY PERFORM' '$TMPROOT/out11a.txt'"
check "11c. …and the refusal names the ACT, so it reads the same by either route" \
  "grep -q 'That is a FIX' '$TMPROOT/out11a.txt'"
rc11b=0; xech "$V11" "$R11" exec lcars-run/run.sh drive --mission m-mine >"$TMPROOT/out11b.txt" 2>&1 || rc11b=$?
check "11d. ROUTE B — THE SAME ACT THROUGH \`exec\` IS REFUSED TOO" \
  "[ $rc11b -ne 0 ] && grep -q 'NOT AN ACT A VALIDATION PASS MAY PERFORM' '$TMPROOT/out11b.txt'"
check "11e. …and the thing behind the door was NEVER INVOKED (measured, not inferred)" \
  "[ -z \"\$(ran_log '$R11')\" ]"
for x11 in lcars-respond/respond.sh lcars-resolve-logs/resolve-logs.sh; do
  : >"$R11/exec-ran.log"
  rc=0; xech "$V11" "$R11" exec "$x11" --mission m-mine >"$TMPROOT/out11.$$.txt" 2>&1 || rc=$?
  check "11f.$x11 the other FIX routes through \`exec\` are refused, and did not run" \
    "[ $rc -ne 0 ] && [ -z \"\$(ran_log '$R11')\" ]"
done
# SUBDIVIDE TAKES NO `--mission` AT ALL, which is why the act is asked at the
# TARGET gate (which runs for every exec) and not only at the scope gate.
: >"$R11/exec-ran.log"
rc11g=0; xech "$V11" "$R11" exec lcars-file/file.sh --prd "$PRD_GOOD" >"$TMPROOT/out11g.txt" 2>&1 || rc11g=$?
check "11g. a validation pass may not FILE A MISSION into a chunk it does not own" \
  "[ $rc11g -ne 0 ] && grep -q 'That FILES A MISSION' '$TMPROOT/out11g.txt' \
   && [ -z \"\$(ran_log '$R11')\" ]"
# THE VERDICT AND THE DECISION — the other two thirds of the measured spiral.
# THE VERDICT AND THE DECISION, WITH THE EVIDENCE STAGED SO THEY CAN ACTUALLY
# REACH THEIR ACTS. `11i`/`11k` used to pass on a mutant that deleted the act
# decider, because the refusal they were reading was `live-check done`'s own
# evidence gate — § 11 could not measure the merge end of the three-step route
# at all. The validator prepares (allowed: `look`), the fixture stages paired
# evidence, and only then is the verdict attempted.
xech "$V11" "$R11" live-check m-mine --type cli >/dev/null 2>&1
ev11="$(stage_evidence "$R11" m-mine | tr -d ' ')"
check "11g2. [control] the evidence fixture staged a row per prepared target" \
  "[ \"\${ev11:-0}\" -gt 0 ] 2>/dev/null && [ -s '$R11/.git/lcars/missions/m-mine/live-check/checks.json' ]"
rc11h=0; xech "$V11" "$R11" live-check done m-mine --verdict pass >"$TMPROOT/out11h.txt" 2>&1 || rc11h=$?
check "11h. a validation pass may not WRITE THE VERDICT" \
  "[ $rc11h -ne 0 ] && grep -q 'That WRITES THE VERDICT' '$TMPROOT/out11h.txt'"
check "11h2. …and the refusal it gets is AUTHORITY, not the evidence gate" \
  "! grep -q 'enumerate every prepared target' '$TMPROOT/out11h.txt'"
check "11i. …and no verdict was recorded" \
  "[ -z \"\$(apj '$R11' liveChecks.m-mine.verdict)\" ]"
rc11j=0; xech "$V11" "$R11" policy --mission m-mine --verdict high --live-check pass >"$TMPROOT/out11j.txt" 2>&1 || rc11j=$?
check "11j. a validation pass may not take the DECISION that prints the merge" \
  "[ $rc11j -ne 0 ] && grep -q 'That is THE DECISION' '$TMPROOT/out11j.txt'"
check "11k. …and it never reached a merge recommendation" \
  "! grep -q 'ACTION: merge' '$TMPROOT/out11j.txt'"
# AND THE BUILD 11h–11k MUST FAIL ON: the act decider removed. On it the SAME
# three steps reach a recorded verdict and `ACTION: merge` — which is the whole
# spiral, and the only honest proof those four rows measure the boundary.
ACT_BAD="$EXEC_SKILLS/lcars-eeh/no-act-gate.sh"
sed 's@^  act="\$(validator_act_of "\$verb")"$@  return 0 # the act decider, removed on purpose@' \
  "$SCRIPT" >"$ACT_BAD"
check "11k2. the no-act-gate build really differs from this one, by that one line" \
  "! diff -q '$SCRIPT' '$ACT_BAD' >/dev/null && grep -q 'removed on purpose' '$ACT_BAD'"
R11B="$(fast_chunk_repo)"
ech_at "$ACT_BAD" "$R11B" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
V11B="$(validator_of "$R11B")"
LCARS_ECH_AS="$V11B" ech_at "$ACT_BAD" "$R11B" live-check m-mine --type cli >/dev/null 2>&1
ev11b="$(stage_evidence "$R11B" m-mine | tr -d ' ')"
rc11m2=0
LCARS_ECH_AS="$V11B" ech_at "$ACT_BAD" "$R11B" live-check done m-mine --verdict pass \
  >"$TMPROOT/out11k2.txt" 2>&1 || rc11m2=$?
check "11k3. [discrimination] on that build the validator DOES record the verdict" \
  "[ $rc11m2 -eq 0 ] && [ \"\$(apj '$R11B' liveChecks.m-mine.verdict)\" = pass ]"
LCARS_ECH_AS="$V11B" ech_at "$ACT_BAD" "$R11B" policy --mission m-mine --verdict high --live-check pass \
  >"$TMPROOT/out11k4.txt" 2>&1 || true
check "11k4. [discrimination] …and REACHES the merge recommendation — the spiral, intact" \
  "grep -q 'ACTION: merge' '$TMPROOT/out11k4.txt'"
check "11k5. [control] …so 11i and 11k are measuring the boundary, not the evidence gate" \
  "[ -n '$V11B' ] && [ \"\${ev11b:-0}\" -gt 0 ] 2>/dev/null"
# AND THE TWO ACTS IT *MAY* PERFORM, so the cure is a boundary and not an outage.
rc11l=0; xech "$V11" "$R11" live-check m-mine --type cli >"$TMPROOT/out11l.txt" 2>&1 || rc11l=$?
check "11l. it MAY LOOK — \`live-check\` is not refused, AND it exits 0" \
  "[ $rc11l -eq 0 ] && ! grep -q 'NOT AN ACT A VALIDATION PASS MAY PERFORM' '$TMPROOT/out11l.txt'"
rc11m=0; xech "$V11" "$R11" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out11m.txt" 2>&1 || rc11m=$?
check "11m. it MAY FILE — \`file-bug\` goes through" \
  "[ $rc11m -eq 0 ] && grep -q 'FILED:' '$TMPROOT/out11m.txt'"
: >"$R11/exec-ran.log"
rc11n=0; xech "$V11" "$R11" exec lcars-log/log.sh --parent m-mine >"$TMPROOT/out11n.txt" 2>&1 || rc11n=$?
check "11n. …and so does the other filing door, \`exec lcars-log/log.sh\`" \
  "[ $rc11n -eq 0 ] && [ -n \"\$(ran_log '$R11')\" ]"
check "11o. …and THAT door records the bug as the DRIVER's, not the validator's" \
  "grep -qE '^xbug-[0-9]+	d1\$' '$R11/.git/lcars/chunk-owners'"
check "11p. …through the same resolver, so the two filing doors agree" \
  "grep -q 'THE DRIVER' '$TMPROOT/out11n.txt' && ! grep -q 'you drive it' '$TMPROOT/out11n.txt'"
# [CONTROL] THE DRIVER IS UNTOUCHED BY ALL OF IT. A cure that froze every seat
# would pass every row above.
: >"$R11/exec-ran.log"
xech d1 "$R11" exec lcars-run/run.sh drive --mission m-mine >/dev/null 2>&1
check "11q. [control] the DRIVER still reaches the stage machine through \`exec\`" \
  "[ -n \"\$(ran_log '$R11')\" ]"
rc11r=0; xech d1 "$R11" drive m-mine >"$TMPROOT/out11r.txt" 2>&1 || rc11r=$?
check "11r. [control] …and its own \`drive\` is not an act refusal" \
  "! grep -q 'NOT AN ACT A VALIDATION PASS MAY PERFORM' '$TMPROOT/out11r.txt'"
# THE DRIVER REACHES THE DECISION FOR REAL, not merely "is not refused by my
# rule". `11s` used to assert only the absence of the act refusal and passed
# while the driver's `policy` exited 1 for an unrelated reason — an absence is
# not a capability. With the verdict recorded by the DRIVER (its own act), the
# row asserts the thing that matters: it reaches `ACTION: merge`.
xech d1 "$R11" live-check m-mine --type cli >/dev/null 2>&1
stage_evidence "$R11" m-mine >/dev/null
rc11s0=0; xech d1 "$R11" live-check done m-mine --verdict pass >"$TMPROOT/out11s0.txt" 2>&1 || rc11s0=$?
check "11s0. [control] the DRIVER may WRITE THE VERDICT, and does" \
  "[ $rc11s0 -eq 0 ] && [ \"\$(apj '$R11' liveChecks.m-mine.verdict)\" = pass ]"
rc11s=0; xech d1 "$R11" policy --mission m-mine --verdict high --live-check pass >"$TMPROOT/out11s.txt" 2>&1 || rc11s=$?
check "11s. [control] …and REACHES \`policy\`'s merge call, exit 0" \
  "[ $rc11s -eq 0 ] && grep -q 'ACTION: merge' '$TMPROOT/out11s.txt' \
   && ! grep -q 'NOT AN ACT A VALIDATION PASS MAY PERFORM' '$TMPROOT/out11s.txt'"
echo

# =========================================================================
printf '== 12. ONE BRIEF, ONE CONTRACT — the contradiction is impossible ==\n'
# =========================================================================
# FIX ROUND 1, CURE 2. A validator's own brief told it to do all three of the
# acts above: § 3's S366 block said *"not yours to fix … you do not merge it and
# you do not mark it verified"*, and § 5 — FIXED template text, 150 lines down,
# no override stated — said *"you take the one action `policy` gives … and you
# drive them."* § 5's body is a SLOT now, filled by role, exactly once.
R12="$(new_repo)"; ap_init "$R12"; new_mission "$R12" m-12 verify
ech "$R12" record 'missions.u12.id' m-12 >/dev/null 2>&1
ech "$R12" tier u12 --tier T1 --why "one owner end to end" >/dev/null 2>&1
ech "$R12" delegate u12 >/dev/null 2>&1
ech "$R12" delegate u12 --validate --trigger irreversible --why "it writes to the forge" >/dev/null 2>&1
V12="$(validator_of "$R12")"
BD12="$R12/.git/lcars/delegates/d1/BRIEF.md"
BV12="$R12/.git/lcars/delegates/$V12/BRIEF.md"
check "12a. both briefs are real mints" "[ -s \"$BD12\" ] && [ -n '$V12' ] && [ -s \"$BV12\" ]"
check "12b. the DRIVER's § 5 is UNCHANGED — it still owns the four steps" \
  "grep -q 'YOUR CHUNK IS YOURS TO VERIFY' \"$BD12\" \
   && grep -q 'you take the one action' \"$BD12\" \
   && grep -q 'and you \*\*drive them\*\*' \"$BD12\""
check "12c. THE VALIDATOR'S BRIEF DOES NOT CARRY THE DRIVER'S CONTRACT AT ALL" \
  "! grep -q 'YOUR CHUNK IS YOURS TO VERIFY' \"$BV12\" \
   && ! grep -q 'you take the one action' \"$BV12\""
check "12d. …it carries the validation pass's: two acts, named" \
  "grep -q 'A validation pass performs exactly TWO acts' \"$BV12\" \
   && grep -q 'YOU LOOK' \"$BV12\" && grep -q 'YOU FILE WHAT YOU FOUND' \"$BV12\""
# ALL FOUR, NOT THREE. The first version asserted "all three" and so BAKED IN
# the gap: `subdivide` was never retracted anywhere in a validator brief.
check "12e. …and names all FOUR refused acts, so it cannot be surprised by one" \
  "grep -q 'live-check done --verdict' \"$BV12\" && grep -q 'the ACTION the verdict pair produces' \"$BV12\" \
   && grep -q 'the FIX, by any route' \"$BV12\" \
   && grep -q 'SUBDIVIDING' \"$BV12\""
check "12f. STRUCTURAL: the slot is filled once, so no brief can hold both" \
  "[ \"\$(grep -c 'YOUR CHUNK IS YOURS TO VERIFY' \"$BD12\")\" = 1 ] \
   && [ \"\$(grep -c 'YOUR CHUNK IS YOURS TO VERIFY' \"$BV12\")\" = 0 ] \
   && [ \"\$(grep -c 'A validation pass performs exactly TWO acts' \"$BD12\")\" = 0 ]"
check "12g. …and no raw slot token leaked into either brief" \
  "! grep -q 'VERIFY_ROLE' \"$BD12\" && ! grep -q 'VERIFY_ROLE' \"$BV12\""
# THE TWO SMALLER FALSE STATEMENTS, same family.
rc12h=0; ech_as "$V12" "$R12" delegate u12 >"$TMPROOT/out12h.txt" 2>&1 || rc12h=$?
check "12h. the cap refusal shown to a VALIDATOR does not offer it \"yours to drive\"" \
  "[ $rc12h -ne 0 ] && grep -q 'ALTERNATIVE (2) IS NOT YOURS EITHER' '$TMPROOT/out12h.txt'"
check "12i. …and points it at the one alternative that IS its own" \
  "grep -q 'the whole answer is alternative (1)' '$TMPROOT/out12h.txt'"
rc12j=0; ech_as d1 "$R12" delegate u12 >"$TMPROOT/out12j.txt" 2>&1 || rc12j=$?
check "12j. [control] the DRIVER still gets BOTH alternatives, unchanged" \
  "[ $rc12j -ne 0 ] && grep -qi 'more Missions' '$TMPROOT/out12j.txt' \
   && ! grep -q 'ALTERNATIVE (2) IS NOT YOURS EITHER' '$TMPROOT/out12j.txt'"
echo

# =========================================================================
printf '== 13. A LEGALLY-MINTED ROUND-2 VALIDATOR IS NOT BRICKED ==\n'
# =========================================================================
# FIX ROUND 1, CURE 3. The narrowing keyed on `validationRound > 1`. Closing a
# round-1 pass and minting a fresh one on a declared trigger is LEGAL and the
# mint says "Round 2 of 3" — but only `revalidate` writes `recheckScope`, so
# that seat met an EMPTY list ("…is: .") on every scoped verb and could do
# nothing but beat. A whole validation round burnt by the state, not the rule.
# It keys on the RECORDED FACT now: a seat that has reported once has a scope.
R13="$(fast_chunk_repo)"
ech "$R13" delegate mine --validate --trigger wide --why "round one" >/dev/null 2>&1
V13A="$(validator_of "$R13")"
ech "$R13" delegate close "$V13A" >/dev/null 2>&1
rc13=0; ech "$R13" delegate mine --validate --trigger wide --why "a second declared pass" \
  >"$TMPROOT/out13.txt" 2>&1 || rc13=$?
V13B="$(validator_of "$R13")"
check "13a. a fresh pass on round 2 is legal and announces the round" \
  "[ $rc13 -eq 0 ] && [ -n '$V13B' ] && [ '$V13B' != '$V13A' ] && grep -q 'Round 2 of 3' '$TMPROOT/out13.txt'"
check "13b. it has NO recheckScope — it has filed nothing, so there is nothing to narrow to" \
  "[ -z \"\$(apj '$R13' delegates.$V13B.recheckScope)\" ]"
rc13c=0; ech_as "$V13B" "$R13" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out13c.txt" 2>&1 || rc13c=$?
check "13c. IT IS NOT BRICKED: it can work its whole chunk, as a fresh pass must" \
  "[ $rc13c -eq 0 ] && grep -q 'FILED:' '$TMPROOT/out13c.txt'"
# 13d's ASSERTION COULD NOT FAIL, measured. It read
#   ! grep -q 'all this round is for, is: *$'
# and that `$` anchor is UNSATISFIABLE: the line always continues with
# ". Re-check those, …". The tester rebuilt the exact Cure-3 defect, the refusal
# was emitted WITH the literal empty list, and 13d PASSED. The real needle is
# `is: . Re-check` — an empty expansion followed by the sentence's own full
# stop — and 13d2/13d3 are the build it must fail on.
check "13d. …and the refusal naming an EMPTY list never appears" \
  "! grep -qF 'all this round is for, is: . Re-check' '$TMPROOT/out13c.txt'"
EMPTY_BAD="$EXEC_SKILLS/lcars-eeh/empty-scope.sh"
sed 's@^  \[ -n "\$scope" \] || return 0$@  : # the Cure-3 defect, restored on purpose@' \
  "$SCRIPT" >"$EMPTY_BAD"
check "13d2. the empty-scope build really differs from this one, by that one line" \
  "! diff -q '$SCRIPT' '$EMPTY_BAD' >/dev/null && grep -q 'the Cure-3 defect, restored' '$EMPTY_BAD'"
R13B="$(fast_chunk_repo)"
ech_at "$EMPTY_BAD" "$R13B" delegate mine --validate --trigger wide --why "round one" >/dev/null 2>&1
V13C="$(validator_of "$R13B")"
ech_at "$EMPTY_BAD" "$R13B" delegate close "$V13C" >/dev/null 2>&1
ech_at "$EMPTY_BAD" "$R13B" delegate mine --validate --trigger wide --why "a second pass" >/dev/null 2>&1
V13D="$(validator_of "$R13B")"
rc13d=0
LCARS_ECH_AS="$V13D" ech_at "$EMPTY_BAD" "$R13B" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out13d.txt" 2>&1 || rc13d=$?
check "13d3. [discrimination] on the empty-scope build the bricking IS reproduced…" \
  "[ $rc13d -ne 0 ] && [ -n '$V13D' ]"
check "13d4. [discrimination] …and 13d's own needle FINDS the empty list there" \
  "grep -qF 'all this round is for, is: . Re-check' '$TMPROOT/out13d.txt'"
rc13e=0; ech "$R13" revalidate "$V13B" >"$TMPROOT/out13e.txt" 2>&1 || rc13e=$?
check "13e. and once it HAS reported, \`revalidate\` narrows it" \
  "[ $rc13e -eq 0 ] && apj '$R13' delegates.$V13B.recheckScope | grep -q 'bug-'"
rc13f=0; ech_as "$V13B" "$R13" live-check m-mine --type cli >"$TMPROOT/out13f.txt" 2>&1 || rc13f=$?
check "13f. [control] …and THEN the chunk root is out of its re-check" \
  "[ $rc13f -ne 0 ] && grep -q 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out13f.txt'"
echo

# =========================================================================
printf '== 16. THE MEASURED EXTRAS: the label, the request, the scope, the re-drive ==\n'
# =========================================================================
# UNIT ALIASING. Two unit LABELS pointing at ONE Mission bought two simultaneous
# "round 1 of 3" validators and 3N rounds, silently, because both bounds keyed
# on the label. They key on the WORK now.
R16="$(fast_chunk_repo)"
ech "$R16" record 'missions.alias.id' m-mine >/dev/null 2>&1
ech "$R16" tier alias --tier T1 --why "the same Mission under a second label" >/dev/null 2>&1
ech "$R16" delegate mine --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
rc16a=0; ech "$R16" delegate alias --validate --trigger undetectable --why "the alias route" \
  >"$TMPROOT/out16a.txt" 2>&1 || rc16a=$?
check "16a. a SECOND unit label on the same Mission buys no second pass" \
  "[ $rc16a -ne 0 ] && grep -qi 'one validation pass' '$TMPROOT/out16a.txt'"
# 16b's NEGATIVE CONJUNCT ASSERTED A KEY THAT NEVER EXISTS: `m-other` is created
# NOWHERE in this suite, so `-z` on it was true on every build, keyed-by-label or
# keyed-by-work. The discriminating key is the SECOND LABEL — `alias` — which a
# label-keyed counter WOULD have written and a work-keyed one never does.
check "16b. …and the round counter is keyed on the WORK, not the label" \
  "[ \"\$(apj '$R16' validations.m-mine.round)\" = 1 ] \
   && [ -z \"\$(apj '$R16' validations.alias.round)\" ] \
   && [ -z \"\$(apj '$R16' units.alias.validationRound)\" ] \
   && [ -z \"\$(apj '$R16' units.mine.validationRound)\" ]"
check "16b2. [control] …and the alias label really does resolve to the same Mission" \
  "[ \"\$(apj '$R16' missions.alias.id)\" = m-mine ] \
   && [ \"\$(apj '$R16' missions.mine.id)\" = m-mine ]"
# A REQUEST IS SPENT WHEN IT IS HONOURED. One line of uncertainty bought all
# three rounds before this.
R16B="$(fast_chunk_repo)"
ech_as d1 "$R16B" request-validator "I cannot tell if the river renders" >/dev/null 2>&1
ech "$R16B" delegate mine --validate >/dev/null 2>&1
V16="$(validator_of "$R16B")"
check "16c. the honoured request is recorded as SPENT, by the validator it bought" \
  "[ \"\$(apj '$R16B' delegates.d1.validatorRequested.consumedBy)\" = '$V16' ]"
ech "$R16B" delegate close "$V16" >/dev/null 2>&1
rc16d=0; ech "$R16B" delegate mine --validate >"$TMPROOT/out16d.txt" 2>&1 || rc16d=$?
check "16d. …so ONE request does not buy a second pass" \
  "[ $rc16d -ne 0 ] && grep -qi 'ALREADY SPENT' '$TMPROOT/out16d.txt'"
check "16e. …and the refusal says how to ask again, or name an axis" \
  "grep -q 'request-validator' '$TMPROOT/out16d.txt' && grep -q -- '--trigger' '$TMPROOT/out16d.txt'"
rc16f=0; ech_as d1 "$R16B" request-validator "still unsure, asking again" >/dev/null 2>&1 || rc16f=$?
rc16g=0; ech "$R16B" delegate mine --validate >"$TMPROOT/out16g.txt" 2>&1 || rc16g=$?
check "16f. [control] a FRESH request is honoured again, so the lane still works" \
  "[ $rc16f -eq 0 ] && [ $rc16g -eq 0 ]"
# A RE-CHECK SCOPE IS THE BUGS IT FILED — never the chunk root, whatever the
# record claims. A hand-edited `filed` used to snapshot the root and narrow
# nothing at all.
R16C="$(fast_chunk_repo)"
ech "$R16C" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
V16C="$(validator_of "$R16C")"
ech_as "$V16C" "$R16C" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
python3 - "$R16C/.git/lcars/autopilot.json" "$V16C" <<'PY16'
import json, sys
f, vid = sys.argv[1:3]
d = json.load(open(f))
d["delegates"][vid]["filed"] = ["m-mine", "nope-does-not-exist", "bug-001"]
json.dump(d, open(f, "w"), indent=2)
PY16
rc16h=0; ech "$R16C" revalidate "$V16C" >"$TMPROOT/out16h.txt" 2>&1 || rc16h=$?
check "16g. a hand-edited \`filed\` cannot make the chunk ROOT the re-check scope" \
  "[ $rc16h -eq 0 ] && ! apj '$R16C' delegates.$V16C.recheckScope | grep -q 'm-mine'"
check "16h. …nor a Mission that is not on disk; and it SAYS what it dropped" \
  "! apj '$R16C' delegates.$V16C.recheckScope | grep -q 'nope-does-not-exist' \
   && grep -q 'DROPPED FROM THE SCOPE' '$TMPROOT/out16h.txt'"
check "16i. …and what it filed for real survives" \
  "apj '$R16C' delegates.$V16C.recheckScope | grep -q 'bug-001'"
rc16j=0; ech_as "$V16C" "$R16C" live-check m-mine --type cli >"$TMPROOT/out16j.txt" 2>&1 || rc16j=$?
check "16j. …so the narrowing actually narrows: the root is still refused" \
  "[ $rc16j -ne 0 ] && grep -q 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out16j.txt'"
# A CLOSED DRIVER + AN OPEN VALIDATOR MUST NOT BLOCK A RE-DRIVE. § 8e advises
# minting an ordinary seat; `delegate_find` reported the VALIDATOR as the unit's
# seat, so that cure was refused as a double mint.
R16D="$(fast_chunk_repo)"
ech "$R16D" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
ech "$R16D" delegate close d1 >/dev/null 2>&1
rc16k=0; ech "$R16D" delegate mine >"$TMPROOT/out16k.txt" 2>&1 || rc16k=$?
check "16k. with the driver closed, a plain mint gives the chunk a NEW DRIVER" \
  "[ $rc16k -eq 0 ] && grep -q 'MINTED' '$TMPROOT/out16k.txt' \
   && ! grep -q 'ALREADY MINTED' '$TMPROOT/out16k.txt'"
ech "$R16" delegate mine >"$TMPROOT/out16l.txt" 2>&1 || true
check "16l. [control] …and with the driver OPEN a second plain mint is still refused" \
  "grep -q 'ALREADY MINTED' '$TMPROOT/out16l.txt'"
# THE COVERAGE LABEL NOW HAS A CONSUMER — the screen the main ECH decides on.
ech "$R16B" delegates >"$TMPROOT/out16m.txt" 2>&1
# A REPORT MUST NOT CONTRADICT THE GATES. `chunk_owner_for` names the driver
# whether or not that seat is still open, and the accept gates honour a claim
# only while its seat IS open — so with the driver closed the bug blocks, and
# saying "it does NOT block" would be a false green in the output.
R16E="$(fast_chunk_repo)"
ech "$R16E" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
V16E="$(validator_of "$R16E")"
ech "$R16E" delegate close d1 >/dev/null 2>&1
rc16q=0; ech_as "$V16E" "$R16E" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out16q.txt" 2>&1 || rc16q=$?
check "16q. with the driver CLOSED, the filing says the bug BLOCKS — not that it does not" \
  "[ $rc16q -eq 0 ] && grep -q 'SEAT IS CLOSED' '$TMPROOT/out16q.txt' \
   && grep -q 'IT BLOCKS' '$TMPROOT/out16q.txt' \
   && ! grep -q 'does NOT block' '$TMPROOT/out16q.txt'"
check "16r. …and it names the main ECH's cure, the one \`delegate_find\` now permits" \
  "grep -q 'mints one beside you' '$TMPROOT/out16q.txt'"
# A FRESH CONTROL, not output borrowed from two earlier sections: the same
# fixture shape as 16q with the driver left OPEN.
R16F="$(fast_chunk_repo)"
ech "$R16F" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
V16F="$(validator_of "$R16F")"
rc16s=0; ech_as "$V16F" "$R16F" file-bug --parent m-mine --prd "$PRD_GOOD" \
  >"$TMPROOT/out16s.txt" 2>&1 || rc16s=$?
check "16s. [control] with the driver OPEN the same filing says it does NOT block" \
  "[ $rc16s -eq 0 ] && grep -q 'does NOT block' '$TMPROOT/out16s.txt' \
   && ! grep -q 'SEAT IS CLOSED' '$TMPROOT/out16s.txt'"
check "16m. the board carries a VALIDATION COVERAGE footer" \
  "grep -q 'VALIDATION COVERAGE' '$TMPROOT/out16m.txt'"
check "16n. …and a chunk whose only pass came down the REQUEST lane reads NOT VALIDATED" \
  "grep -A3 'VALIDATION COVERAGE' '$TMPROOT/out16m.txt' | grep 'NOT VALIDATED' >/dev/null"
ech "$R16" delegates >"$TMPROOT/out16o.txt" 2>&1
check "16o. [control] …while a TRIGGERED pass reads VALIDATED on the same footer" \
  "grep -A3 'VALIDATION COVERAGE' '$TMPROOT/out16o.txt' | grep 'VALIDATED by' >/dev/null"
ech "$R9" delegates >"$TMPROOT/out16p.txt" 2>&1 || true
check "16p. [control] a repo with no validator at all prints no footer" \
  "! grep -q 'VALIDATION COVERAGE' '$TMPROOT/out16p.txt' && [ -s '$TMPROOT/out16p.txt' ]"
echo

# =========================================================================
printf '== 17. THE ROLE REACHES EVERY SECTION, NOT JUST THE ONE IT WAS AIMED AT ==\n'
# =========================================================================
# FIX ROUND 2, CURE A. Round 1 slotted § 5 and stopped there. A fresh tester
# diffed a real driver brief against a real validator brief section by section:
# § 5 DIFFERS (cured) and `### YOUR CHUNK, AND THE AUTHORITY THAT COMES WITH IT`
# was IDENTICAL — so the validator brief still told it, in its own words, to do
# all four acts the harness refuses. The depth-cap sentence in it is the exact
# one round 1's commit message claimed to have fixed: the RUNTIME refusal was
# fixed, the BRIEF was not.
#
# SO THIS SECTION GREPS THE FINISHED ARTEFACT for each refused act and requires
# only RETRACTIONS — and § 17c is the control that makes the whole section
# meaningful: the DRIVER's brief must still carry every one of them.
R17="$(new_repo)"; ap_init "$R17"; new_mission "$R17" m-17 verify
ech "$R17" record 'missions.u17.id' m-17 >/dev/null 2>&1
ech "$R17" tier u17 --tier T1 --why "one owner end to end" >/dev/null 2>&1
ech "$R17" delegate u17 >/dev/null 2>&1
ech "$R17" delegate u17 --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V17="$(validator_of "$R17")"
BD17="$R17/.git/lcars/delegates/d1/BRIEF.md"
BV17="$R17/.git/lcars/delegates/$V17/BRIEF.md"
check "17a. both briefs are real mints of real size" \
  "[ \"\$(wc -c <\"$BD17\" | tr -d ' ')\" -gt 9000 ] && [ -n '$V17' ] \
   && [ \"\$(wc -c <\"$BV17\" | tr -d ' ')\" -gt 9000 ]"
# THE FIVE SENTENCES THE TESTER READ OFF A REAL VALIDATOR BRIEF, by their own
# words. Each is an act the harness refuses; none may survive.
for n17 in \
  "drive your own fixes" \
  "SUBDIVIDE THE WORK AS IT MAKES SENSE" \
  "THESE ARE YOURS, INSIDE YOUR CHUNK" \
  "which you may do freely" \
  "AND THE NINTH VERB IS YOURS" \
  "ABSORBING A STUMBLE" \
  "file a Mission. A new unit" \
  "refused as the main ECH's impostor"; do
  check "17b. the VALIDATOR brief does not say: $n17" \
    "! grep -qF \"$n17\" \"$BV17\""
done
# THE CONTROL THAT MAKES § 17b MEAN SOMETHING. Without it, a mint that emitted
# an EMPTY brief would pass every row above.
for n17c in \
  "drive your own fixes" \
  "SUBDIVIDE THE WORK AS IT MAKES SENSE" \
  "THESE ARE YOURS, INSIDE YOUR CHUNK" \
  "which you may do freely" \
  "AND THE NINTH VERB IS YOURS" \
  "ABSORBING A STUMBLE" \
  "file a Mission. A new unit"; do
  check "17c. [control] the DRIVER brief DOES still say: $n17c" \
    "grep -qF \"$n17c\" \"$BD17\""
done
# AND THE RETRACTIONS ARE PRESENT, each naming the act it retracts.
check "17d. the validator brief retracts FIX, in the chunk-authority section" \
  "grep -q 'you do exactly two things' \"$BV17\" && grep -q 'to fix' \"$BV17\""
check "17e. …retracts SUBDIVIDE, by name" \
  "grep -q 'YOU DO NOT SUBDIVIDE THIS CHUNK' \"$BV17\""
check "17f. …retracts VERDICT and DECIDE in the same place the driver is granted them" \
  "grep -q 'THESE TWO ARE YOURS' \"$BV17\" \
   && grep -q 'AND THESE FOUR ARE REFUSED TO YOU BY NAME' \"$BV17\""
check "17g. …retracts the second depth-cap alternative, which is not a validator's" \
  "grep -q 'USUAL SECOND ALTERNATIVE IS NOT YOURS EITHER' \"$BV17\""
check "17h. …retracts request-validator, because validation is never re-delegated" \
  "grep -q 'IS NOT YOURS EITHER' \"$BV17\" && grep -q 'never re-delegated' \"$BV17\""
check "17i. …and replaces ABSORPTION with REPORTING" \
  "grep -q 'YOU DO NOT ABSORB' \"$BV17\""
check "17j. …and the front door offers it \`lcars log\`, not \`lcars file\`" \
  "grep -q 'lcars file\\\` is NOT yours' \"$BV17\""
check "17k. no raw slot token leaked into either brief" \
  "! grep -qE '\\{\\{[A-Z_]+\\}\\}' \"$BV17\" && ! grep -qE '\\{\\{[A-Z_]+\\}\\}' \"$BD17\""
# THE IMPERSONATION SENTENCE WAS FALSE FOR BOTH ROLES, so it is corrected in
# both: an undeclared seat is NOT refused, and the brief no longer says it is.
for bb17 in "$BD17" "$BV17"; do
  check "17l. neither brief claims an undeclared seat is refused as an impostor" \
    "! grep -q 'impostor' \"$bb17\" && grep -q 'the authority resolves from that' \"$bb17\""
done
echo

# =========================================================================
printf '== 18. BOTH FILING DOORS, AND THE NARROWED ONE THAT HAD NO LOCK ==\n'
# =========================================================================
# CURE B. `cmd_file_bug`'s NEXT block was guarded by `[ -n "$filer" ]` — "is this
# a sub-ECH AT ALL", not by role — so three lines under the OWNER line round 1
# had just made correct, a validation pass was handed `drive`, `resolve-logs`
# and `live-check` as its next steps. All three are refused to it.
R18="$(fast_chunk_repo)"
xech - "$R18" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
V18="$(validator_of "$R18")"
rc18=0; xech "$V18" "$R18" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out18.txt" 2>&1 || rc18=$?
check "18a. the validator's filing succeeds (the row below is a real filing's output)" \
  "[ $rc18 -eq 0 ] && grep -q 'FILED:' '$TMPROOT/out18.txt'"
check "18b. its NEXT step is not a refused verb — no \`drive\`, no \`resolve-logs\`" \
  "! grep -qE '^ +(bash .*resolve-logs|lcars-ech drive)' '$TMPROOT/out18.txt'"
check "18c. …nor \`live-check\` on the chunk root it is about to be narrowed off" \
  "! grep -q 'live-check m-mine --type' '$TMPROOT/out18.txt'"
check "18d. it says what the part it HAS done was, and whose the fix is" \
  "grep -q 'you have FILED it, and that is where your part ends' '$TMPROOT/out18.txt' \
   && grep -q 'd1 drives it' '$TMPROOT/out18.txt'"
check "18e. …and names the three verbs that are refused to it, so it does not try" \
  "grep -q 'are all refused to you, by name' '$TMPROOT/out18.txt'"
# [CONTROL] THE DRIVER'S OWN NEXT BLOCK IS UNTOUCHED — this is the row that
# would catch a cure that simply deleted the block.
rc18f=0; xech d1 "$R18" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out18f.txt" 2>&1 || rc18f=$?
check "18f. [control] the DRIVER still gets all three of its own next steps" \
  "[ $rc18f -eq 0 ] && grep -q 'this is YOUR bug and YOUR chunk' '$TMPROOT/out18f.txt' \
   && grep -q 'lcars-ech drive m-mine' '$TMPROOT/out18f.txt' \
   && grep -q 'resolve-logs.sh --parent m-mine' '$TMPROOT/out18f.txt' \
   && grep -q 'live-check m-mine --type' '$TMPROOT/out18f.txt'"
# CURE C. `exec lcars-log/log.sh --parent <root>` classifies as `file` (allowed)
# and carries NO `--mission`, so the scope gate — and therefore the re-check
# narrowing — was never called. Measured across three real rounds: the narrowed
# door refused, this one returned 0, a Mission was created, it was appended to
# `filed`, and `revalidate` then snapshotted the WIDER list.
rc18g=0; xech - "$R18" revalidate "$V18" >"$TMPROOT/out18g.txt" 2>&1 || rc18g=$?
apj "$R18" "delegates.$V18.recheckScope" >"$TMPROOT/scope18.before"
apj "$R18" "delegates.$V18.filed"        >"$TMPROOT/filed18.before"
check "18g. round 2 opens, bounded to what it filed" \
  "[ $rc18g -eq 0 ] && grep -q 'bug-' '$TMPROOT/scope18.before'"
: >"$R18/exec-ran.log"
rc18h=0; xech "$V18" "$R18" file-bug --parent m-mine --prd "$PRD_GOOD" >"$TMPROOT/out18h.txt" 2>&1 || rc18h=$?
check "18h. the narrowed door refuses the chunk root, as it did before" \
  "[ $rc18h -ne 0 ] && grep -q 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out18h.txt'"
rc18i=0; xech "$V18" "$R18" exec lcars-log/log.sh --parent m-mine >"$TMPROOT/out18i.txt" 2>&1 || rc18i=$?
check "18i. AND SO DOES THE OTHER DOOR — the one with no \`--mission\`" \
  "[ $rc18i -ne 0 ] && grep -q 'RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out18i.txt'"
check "18j. …and \`log.sh\` was NEVER INVOKED (measured, not inferred)" \
  "[ -z \"\$(ran_log '$R18')\" ]"
# 18k COMPARED THE WRONG KEY UNDER A NAME CLAIMING TO MEASURE THE SPIRAL, and
# it passed on the Cure-C-deleted mutant AND on the full red baseline:
# `recheckScope` is written by `revalidate` and by nothing else, so it is
# CONSTANT across a single `exec` on every build. **The widening is in `filed`** —
# that is what the door appends to and what `revalidate` then snapshots into the
# next scope. 18k now compares `filed`, and 18k3 is the mutant it fails on.
apj "$R18" "delegates.$V18.filed" >"$TMPROOT/filed18.after"
check "18k. …so the FILED list did not grow — which is where a widening shows" \
  "cmp -s '$TMPROOT/filed18.before' '$TMPROOT/filed18.after'"
check "18k2. [control] …and the list compared was a real, non-empty one" \
  "grep -q 'bug-' '$TMPROOT/filed18.before' && grep -q 'bug-' '$TMPROOT/filed18.after'"
apj "$R18" "delegates.$V18.recheckScope" >"$TMPROOT/scope18.after"
check "18k4. …and the re-check scope is unchanged too (true on every build)" \
  "cmp -s '$TMPROOT/scope18.before' '$TMPROOT/scope18.after'"
# [CONTROLS] NOT AN OUTAGE, THREE WAYS: in-scope on that door works, the driver
# on that door works, and a validator in ROUND 1 on that door works.
: >"$R18/exec-ran.log"
INSCOPE18="$(tr -d '[]" ' <"$TMPROOT/scope18.before" | cut -d, -f1)"
rc18l=0; xech "$V18" "$R18" exec lcars-log/log.sh --parent "$INSCOPE18" >/dev/null 2>&1 || rc18l=$?
check "18l. [control] the SAME door, on a bug it DID file, goes through" \
  "[ -n '$INSCOPE18' ] && [ $rc18l -eq 0 ] && [ -n \"\$(ran_log '$R18')\" ]"
: >"$R18/exec-ran.log"
rc18m=0; xech d1 "$R18" exec lcars-log/log.sh --parent m-mine >/dev/null 2>&1 || rc18m=$?
check "18m. [control] the DRIVER on that door is untouched — parked D1 is not widened" \
  "[ $rc18m -eq 0 ] && [ -n \"\$(ran_log '$R18')\" ]"
R18B="$(fast_chunk_repo)"
xech - "$R18B" delegate mine --validate --trigger wide --why "round one" >/dev/null 2>&1
V18B="$(validator_of "$R18B")"
: >"$R18B/exec-ran.log"
rc18n=0; xech "$V18B" "$R18B" exec lcars-log/log.sh --parent m-mine >/dev/null 2>&1 || rc18n=$?
check "18n. [control] a validator in ROUND 1 reaches that door — round 1 IS the chunk" \
  "[ $rc18n -eq 0 ] && [ -n \"\$(ran_log '$R18B')\" ]"
echo

# =========================================================================
printf '== 19. THE METHOD, NOT THE ANSWERS: every section classified by role ==\n'
# =========================================================================
# THIS IS THE ROW THAT MAKES THE CLASS NON-RECURRING, and it exists because the
# suite was **242/0 at a tip where `## 3. The LCARS verbs in scope` was
# byte-identical between a driver's brief and a validation pass's** — and that
# section instructs `run.sh drive`, `respond.sh` and `resolve-logs.sh` in the
# imperative, every one of them refused. § 17 greps eight sentences a tester had
# named; it encodes the ANSWERS, so it was blind to the ninth, tenth, eleventh
# and twelfth. Proven empirically, not argued.
#
# SO THIS ROW CARRIES THE METHOD. It splits a REAL driver brief and a REAL
# validation pass's brief into sections on their own headings, normalises seat
# ids and the mint stamp, and holds every section against a DECLARED
# classification:
#
#   MUST_DIFFER  role-bearing: it grants, instructs or describes an act, and the
#                two roles do not have the same acts.
#   MAY_MATCH    role-neutral: it says the same true thing to either seat.
#
# A section in NEITHER list fails the row. So a new template section cannot be
# added without someone deciding which it is, a MUST_DIFFER that goes identical
# fails (the § 3 bug), and a MAY_MATCH that starts differing fails too — which
# forces the decision rather than letting it drift.
SEC_DRIVER="$TMPROOT/sec-driver"
SEC_VALID="$TMPROOT/sec-valid"
R19="$(new_repo)"; ap_init "$R19"; new_mission "$R19" m-19 verify
ech "$R19" record 'missions.u19.id' m-19 >/dev/null 2>&1
ech "$R19" tier u19 --tier T1 --why "one owner end to end" >/dev/null 2>&1
ech "$R19" delegate u19 >/dev/null 2>&1
ech "$R19" delegate u19 --validate --trigger wide --why "the declared keystone" >/dev/null 2>&1
V19="$(validator_of "$R19")"
# section_verdicts <driver-brief> <validator-brief> -> "VERDICT<TAB>heading"
section_verdicts() {
  python3 - "$1" "$2" <<'PYSEC'
import re, sys
def secs(path):
    t = open(path).read()
    t = re.sub(r'\bd[0-9]+\b', '@SEAT@', t)
    t = re.sub(r'Minted .*', 'Minted @WHEN@', t)
    out, cur, buf = {}, '(preamble)', []
    for line in t.splitlines():
        if re.match(r'^#{2,3} ', line):
            out[cur] = '\n'.join(buf); cur = line.strip(); buf = []
        else:
            buf.append(line)
    out[cur] = '\n'.join(buf)
    return out
a, b = secs(sys.argv[1]), secs(sys.argv[2])
for k in a:
    print("%s\t%s" % ("IDENTICAL" if (k in b and a[k] == b[k])
                      else ("DIFFERS" if k in b else "DRIVER-ONLY"), k))
for k in b:
    if k not in a:
        print("VALID-ONLY\t%s" % k)
PYSEC
}
section_verdicts "$R19/.git/lcars/delegates/d1/BRIEF.md" \
                 "$R19/.git/lcars/delegates/$V19/BRIEF.md" >"$SEC_DRIVER" 2>&1
check "19a. [control] both briefs are real mints and the split found every section" \
  "[ \"\$(wc -l <'$SEC_DRIVER' | tr -d ' ')\" -ge 20 ]"
# ---- THE DECLARED CLASSIFICATION. Changing it is a decision, on the record. --
# MUST_DIFFER — each one grants, instructs or describes an ACT:
#
# THE LAST THREE WERE MAY_MATCH UNTIL S368, AND ALL THREE WERE WRONG. Each was
# byte-identical to the driver's and each INSTRUCTS OR PERMITS an act a
# validation pass cannot perform, while the same brief's § 3 says *"You do not
# fix this chunk, you do not merge it and you do not mark it verified."* A table
# that blesses both sides of a contradiction is the § 3 bug again, one section
# over — so the reason each one is role-bearing is recorded here:
#   ## Where you work     *"Work on it. Do not work on `main`."* — a validation
#                         pass does not work on the branch; it reads it and
#                         leaves it as it found it. The driver owns that branch.
#   ## 4. The boundaries  *"Everything you write stays inside `.git/lcars/` or
#                         the mission's own branch."* — a PERMISSION to write to
#                         the branch, and at T2 the same section hands the seat
#                         a tester to stand up and a chunk to divide.
#   ## 6. The engine …    *"EVERY SEAT YOU OPEN TAKES THIS SAME ROW. You will
#                         open seats of your own — a worker, a tester…"* — a
#                         validation pass opens none: a tester of its own is
#                         fresh eyes on fresh eyes, and validation is never
#                         re-delegated.
MUST_DIFFER='### T1 — one delegate owns the unit end-to-end, and ABSORBS ITS OWN STUMBLES
## 2. The output format expected back
## 3. The LCARS verbs in scope
### YOUR CHUNK, AND THE AUTHORITY THAT COMES WITH IT
### THE BOUNDARY: THESE NINE VERBS, AND NOTHING ELSE
### The front door, and it is not optional
### What you decide alone, and what goes UP
## 5. YOU verify your chunk; the MAIN ECH verifies the whole
## Where you work
## 4. The boundaries
## 6. The engine you run on
### And while you work: BEAT
## 1. The goal'
# MAY_MATCH — each one says the same TRUE thing to either seat, and the reason is
# recorded so the next reader can disagree with a specific claim:
#   (preamble)            the title, unit, tier and mint stamp
#   ## Your tier          the recorded tier judgement and the estimate it saw
#   ### RAISING IT …      the BLOCKED beat — the same channel for either seat
#   ### The two-list …    the ledger sign-off on exit
#   ## Sign-off           who minted it, under which recorded judgement
# S368 FIX ROUND 1 TOOK THREE MORE OUT OF THIS LIST, and the reason each was
# wrong is recorded so the next reader can disagree with a specific claim:
#   ### And while you work: BEAT   its single worked example of good beating was
#       *"removed it, re-running the gate"* — a WRITE to the working tree, in the
#       brief of a seat whose § 4 says it writes nothing. One section modelled
#       the act another forbids, and it was the ONLY worked example the seat got.
#   ## 1. The goal                 two of its four `goalSource` branches said
#       *"before you write anything"*, and a validation pass does not write. It
#       now also carries a rider that the goal is a thing to JUDGE, which fires
#       on every branch — a section that is role-correct on only some fixtures is
#       a section nothing is asserting.
#   ### Read these before you write anything   the HEADING is the instruction;
#       the body under it genuinely is role-neutral, which is exactly why a
#       body-diff could not see it. It is ROLE_ONLY now, one heading per role.
MAY_MATCH='(preamble)
## Your tier: T1
### RAISING IT — THIS IS THE CHANNEL, and it is the only one you have
### The two-list sign-off, on exit
## Sign-off'
# ROLE-EXCLUSIVE sections are correct by construction — a section only one role
# has cannot be identical — but they are still declared, so one appearing or
# vanishing is a decision too.
ROLE_ONLY='### ABSORBING A STUMBLE — by using the factory, never by going round it
### Read these before you write anything
### Read these before you look at anything
### YOU ARE THE VALIDATION PASS FOR THIS CHUNK — READ THIS BEFORE § 4
### YOU DO NOT ABSORB — YOU REPORT. (This section is a driver'"'"'s; here is yours.)'
classify_misses() {   # <verdict-file> [must] [may] [only] -> one line per miss
  python3 - "$1" "${2-$MUST_DIFFER}" "${3-$MAY_MATCH}" "${4-$ROLE_ONLY}" <<'PYCL'
import sys
rows = [l.rstrip("\n").split("\t", 1) for l in open(sys.argv[1]) if "\t" in l]
must = set(l for l in sys.argv[2].splitlines() if l)
may  = set(l for l in sys.argv[3].splitlines() if l)
only = set(l for l in sys.argv[4].splitlines() if l)
seen = set()
for verdict, head in rows:
    seen.add(head)
    if head in must:
        if verdict != "DIFFERS":
            print("MUST_DIFFER but %s: %s" % (verdict, head))
    elif head in may:
        if verdict != "IDENTICAL":
            print("MAY_MATCH but %s: %s" % (verdict, head))
    elif head in only:
        if verdict not in ("DRIVER-ONLY", "VALID-ONLY"):
            print("ROLE_ONLY but %s: %s" % (verdict, head))
    else:
        print("UNCLASSIFIED SECTION: %s" % head)
for head in must | may | only:
    if head not in seen:
        print("DECLARED BUT ABSENT: %s" % head)
PYCL
}
check "19b. EVERY SECTION matches its declared role classification, and none is unclassified" \
  "[ -z \"\$(classify_misses '$SEC_DRIVER')\" ]"
if [ -n "$(classify_misses "$SEC_DRIVER")" ]; then
  printf '       --- the sections the table gets wrong ---\n'
  classify_misses "$SEC_DRIVER" | sed 's/^/       /'
fi
check "19c. [control] the table really classifies all three kinds, not one" \
  "grep -c DIFFERS '$SEC_DRIVER' | grep -qv '^0\$' && grep -q IDENTICAL '$SEC_DRIVER' \
   && grep -qE 'DRIVER-ONLY|VALID-ONLY' '$SEC_DRIVER'"
# ---- AND THE MUTANT IT MUST FAIL ON: one fragment reverted to the driver text.
# `$v_verbs` is § 3's role branch; emptying it makes § 3 identical again, which
# is EXACTLY the state the suite was 242/0 in.
SEC_BAD="$EXEC_SKILLS/lcars-eeh/sec-blind.sh"
sed 's@^    v_verbs="Run each one through the launcher that minted this brief, by its absolute path:$@    v_verbs="" # § 3'"'"'s role branch, reverted on purpose\n    unused_verbs="Run each one through the launcher that minted this brief, by its absolute path:@' \
  "$SCRIPT" >"$SEC_BAD"
check "19d. the section-blind build really differs from this one, by that one line" \
  "! diff -q '$SCRIPT' '$SEC_BAD' >/dev/null && grep -q \"reverted on purpose\" '$SEC_BAD'"
R19B="$(new_repo)"; ap_init "$R19B"; new_mission "$R19B" m-19b verify
ech_at "$SEC_BAD" "$R19B" record 'missions.u19b.id' m-19b >/dev/null 2>&1
ech_at "$SEC_BAD" "$R19B" tier u19b --tier T1 --why "one owner" >/dev/null 2>&1
ech_at "$SEC_BAD" "$R19B" delegate u19b >/dev/null 2>&1
ech_at "$SEC_BAD" "$R19B" delegate u19b --validate --trigger wide --why "k" >/dev/null 2>&1
V19B="$(validator_of "$R19B")"
section_verdicts "$R19B/.git/lcars/delegates/d1/BRIEF.md" \
                 "$R19B/.git/lcars/delegates/$V19B/BRIEF.md" >"$SEC_VALID" 2>&1
check "19e. [control] the mutant minted both briefs, so the row below can run" \
  "[ -n '$V19B' ] && [ \"\$(wc -l <'$SEC_VALID' | tr -d ' ')\" -ge 20 ]"
check "19f. [discrimination] § 19b FAILS on the section-blind build" \
  "[ -n \"\$(classify_misses '$SEC_VALID')\" ]"
check "19g. [discrimination] …and it names § 3 as the section that went identical" \
  "classify_misses '$SEC_VALID' | grep -q 'MUST_DIFFER but IDENTICAL: ## 3. The LCARS verbs in scope'"
# ---- AND THE FOUR SECTIONS THIS ROUND BRANCHED, each with the sentence that
# was false. These are § 17's shape — answers, not method — and they are kept
# only as a readable record of WHAT was wrong; § 19b is what stops the next one.
BV19="$R19/.git/lcars/delegates/$V19/BRIEF.md"
BD19="$R19/.git/lcars/delegates/d1/BRIEF.md"
for n19 in \
  "lcars-run/run.sh drive --mission" \
  "This is the front door." \
  "answer a stage's own grill" \
  "AND THOSE ARE THE ONLY SCRIPTS" \
  "What you cured yourself" \
  "how to do the work, which order, which files"; do
  check "19h. the VALIDATOR brief does not say: $n19" \
    "! grep -qF \"$n19\" \"$BV19\""
  check "19i. [control] …and the DRIVER brief does" \
    "grep -qF \"$n19\" \"$BD19\""
done
check "19j. the validator's § 3 names the ONE script it may reach, and the four refused" \
  "grep -q 'THERE IS EXACTLY ONE SCRIPT' \"$BV19\" \
   && grep -q 'AND THE OTHER FOUR ARE REFUSED TO YOU BY NAME' \"$BV19\""
check "19k. …and requires the EXACT id, naming what is refused instead" \
  "grep -q 'Name the Mission by its EXACT id' \"$BV19\" \
   && grep -q 'a title fragment or a second' \"$BV19\""
# THE TIER FENCE IS THE ONE EXCEPTION TO § 19h's SHAPE, deliberately. It is
# DELEGATION.md's own definition of T1, quoted verbatim by contract, so the cure
# is a RIDER beside it rather than a deletion from it — the sentence SURVIVES in
# both briefs and is retracted only in the validator's. 19l is that claim; a row
# in the 19h loop demanding its absence would have demanded a forked fence.
check "19l0. the fence sentence survives in BOTH briefs, because it is quoted verbatim" \
  "grep -qF 'It cures those itself' \"$BD19\" && grep -qF 'It cures those itself' \"$BV19\""
check "19l. the tier fence is RIDDEN, not rewritten — the fence text survives" \
  "grep -q 'It cures those itself' \"$BD19\" \
   && grep -q 'two of that contract' \"$BV19\" \
   && grep -q 'applies to you unchanged' \"$BV19\""
# ---- AND THE SAME METHOD AT T2 (S368, CURE 3). § 19 minted a T1 PAIR ONLY, so
# it could not see T2 at all — and a real T2 pair gets four more sections wrong,
# including one that tells a validation pass to stand up its own reviewer, which
# is the double validation this whole rule exists to prevent. Measured at
# `b726a3e`:
#   ### T1 — … ABSORBS ITS OWN STUMBLES           IDENTICAL at T2, DIFFERS at T1
#       the role RIDER is appended to the END of the contract, and at T2 the end
#       is the T2 fence — so the T1 fence it names goes unridden in the only
#       brief that carries both.
#   ### T2 — T1, plus an independent FRESH-CONTEXT tester at the gate
#       …DIFFERS for that same wrong reason, and the T2 fence's own role-bearing
#       clauses (stand up a tester; divide the unit) were never ridden.
#   ### Standing up your fresh-context tester (T2)  IDENTICAL — byte for byte,
#       the instruction to stand up a fresh-context reviewer, in the brief of the
#       seat that IS the fresh-context reviewer.
#   ## 4. The boundaries  carries two more T2-only bullets at T2 — "Your T2
#       tester is ADDITIVE" and "Division is a means" — both driver acts.
#
# ONE HELPER, used by the T2 pair and by both mutants below, so a row cannot
# quietly mint a different shape than the one it is compared against. The T1
# block above keeps its own inline mint: $R19/$V19/$BD19/$BV19 are read by
# 19h–19l and re-pointing them is a change those rows did not ask for.
mint_pair() {   # mint_pair <script> <tier> <suffix> <verdict-out> -> "<repo>\t<validator>"
  local scr="$1" tr="$2" sfx="$3" out="$4" r v
  r="$(new_repo)"; ap_init "$r"; new_mission "$r" "m-$sfx" verify
  ech_at "$scr" "$r" record "missions.u$sfx.id" "m-$sfx"            >/dev/null 2>&1
  ech_at "$scr" "$r" tier "u$sfx" --tier "$tr" --why "one owner"    >/dev/null 2>&1
  ech_at "$scr" "$r" delegate "u$sfx"                               >/dev/null 2>&1
  ech_at "$scr" "$r" delegate "u$sfx" --validate --trigger wide --why "keystone" >/dev/null 2>&1
  v="$(validator_of "$r")"
  section_verdicts "$r/.git/lcars/delegates/d1/BRIEF.md" \
                   "$r/.git/lcars/delegates/$v/BRIEF.md" >"$out" 2>&1
  printf '%s\t%s' "$r" "$v"
}
# ---- THE T2 CLASSIFICATION. Same three kinds, declared separately because a T2
# brief is not a T1 brief with a section bolted on: it carries BOTH tier fences
# (T2 is defined as a strict superset) and a tester hand-off, and every one of
# those is role-bearing.
MUST_DIFFER_T2='### T1 — one delegate owns the unit end-to-end, and ABSORBS ITS OWN STUMBLES
### T2 — T1, plus an independent FRESH-CONTEXT tester at the gate
## 2. The output format expected back
## 3. The LCARS verbs in scope
### YOUR CHUNK, AND THE AUTHORITY THAT COMES WITH IT
### THE BOUNDARY: THESE NINE VERBS, AND NOTHING ELSE
### The front door, and it is not optional
### What you decide alone, and what goes UP
## 5. YOU verify your chunk; the MAIN ECH verifies the whole
## Where you work
## 4. The boundaries
## 6. The engine you run on
### And while you work: BEAT
## 1. The goal
## Your tier: T2'
# `## Your tier: T2` carries the CONTRACT PREAMBLE — *"Both contracts below are
# yours"*, granted unqualified, on the wrong side of the brief's own retraction.
# At T1 there is no preamble, so `## Your tier: T1` stays MAY_MATCH.
MAY_MATCH_T2='(preamble)
### RAISING IT — THIS IS THE CHANNEL, and it is the only one you have
### The two-list sign-off, on exit
## Sign-off'
ROLE_ONLY_T2='### ABSORBING A STUMBLE — by using the factory, never by going round it
### Read these before you write anything
### Read these before you look at anything
### Standing up your fresh-context tester (T2)
### THE T2 TESTER IS NOT YOURS TO STAND UP — YOU *ARE* THE SECOND LOOK
### YOU ARE THE VALIDATION PASS FOR THIS CHUNK — READ THIS BEFORE § 4
### YOU DO NOT ABSORB — YOU REPORT. (This section is a driver'"'"'s; here is yours.)'
t2misses() { classify_misses "$1" "$MUST_DIFFER_T2" "$MAY_MATCH_T2" "$ROLE_ONLY_T2"; }
SEC_T2="$TMPROOT/sec-t2"
RV19T2="$(mint_pair "$SCRIPT" T2 19t2 "$SEC_T2")"
R19T2="${RV19T2%%	*}"; V19T2="${RV19T2##*	}"
BD19T2="$R19T2/.git/lcars/delegates/d1/BRIEF.md"
BV19T2="$R19T2/.git/lcars/delegates/$V19T2/BRIEF.md"
check "19m. [control] a real T2 pair was minted and the split found every section" \
  "[ -n '$V19T2' ] && [ \"\$(wc -l <'$SEC_T2' | tr -d ' ')\" -ge 22 ]"
check "19m2. [control] …and it really is a T2 pair — BOTH tier fences, in both briefs" \
  "grep -q '^### T1 — ' \"$BD19T2\" && grep -q '^### T2 — ' \"$BD19T2\" \
   && grep -q '^### T1 — ' \"$BV19T2\" && grep -q '^### T2 — ' \"$BV19T2\""
check "19n. EVERY SECTION of the T2 pair matches its declared classification" \
  "[ -z \"\$(t2misses '$SEC_T2')\" ]"
if [ -n "$(t2misses "$SEC_T2")" ]; then
  printf '       --- the sections the T2 table gets wrong ---\n'
  t2misses "$SEC_T2" | sed 's/^/       /'
fi
check "19o. [control] the T2 table really classifies all three kinds, not one" \
  "grep -q DIFFERS '$SEC_T2' && grep -q IDENTICAL '$SEC_T2' \
   && grep -qE 'DRIVER-ONLY|VALID-ONLY' '$SEC_T2'"
# THE RIDER IS ASSERTED *POSITIONALLY*, between the two fence headings. Asking
# only whether the sentence is in the FILE passed at `b726a3e` — it was there,
# in the T2 fence's section instead of the T1 one, which is the whole defect.
check "19p. the T1 fence is ridden IN A T2 BRIEF too — inside that fence's own section" \
  "grep -q 'It cures those itself' \"$BV19T2\" \
   && awk '/^### T1 — /{f=1} /^### T2 — /{f=0} f' \"$BV19T2\" | grep -q 'two of that contract'"
check "19q. …and the T2 fence is ridden as well, in ITS section: no tester, no division" \
  "awk '/^### T2 — /{f=1} /^## Where you work/{f=0} f' \"$BV19T2\" \
     | grep -q \"T2 FENCE'S TWO ACTS ARE NOT YOURS\" \
   && awk '/^### T2 — /{f=1} /^## Where you work/{f=0} f' \"$BV19T2\" \
     | grep -qF 'exec lcars-file/file.sh'"
check "19q2. [control] …and the DRIVER's T2 brief carries NEITHER rider" \
  "! grep -q \"T2 FENCE'S TWO ACTS\" \"$BD19T2\" \
   && ! grep -q 'two of that contract' \"$BD19T2\""
check "19r. the validator's T2 brief never tells it to stand up a tester" \
  "! grep -qF 'Standing up your fresh-context tester' \"$BV19T2\" \
   && ! grep -qF 'ALSO IN YOUR SCOPE, BECAUSE THIS UNIT IS T2' \"$BV19T2\" \
   && ! grep -qF 'What you hand it' \"$BV19T2\" \
   && ! grep -qF 'A hand-back with no tester section' \"$BV19T2\""
check "19r2. [control] …and the DRIVER's T2 brief does, all four ways" \
  "grep -qF 'Standing up your fresh-context tester' \"$BD19T2\" \
   && grep -qF 'ALSO IN YOUR SCOPE, BECAUSE THIS UNIT IS T2' \"$BD19T2\" \
   && grep -qF 'What you hand it' \"$BD19T2\" \
   && grep -qF 'A hand-back with no tester section' \"$BD19T2\""
# ---- MUTANT B: THE THREE SECTIONS S368 RECLASSIFIED, each role branch reverted
# to the driver's text. This is the state the suite was 288/0 in.
ROLE_BAD="$EXEC_SKILLS/lcars-eeh/role-blind.sh"
sed -e 's@^    v_wbranch="  \*\*YOU DO NOT WRITE TO IT.*$@    v_wbranch="" # reverted on purpose\n    unused_wbranch="x@' \
    -e 's@^    v_wfence="- \*\*YOU WRITE NO CODE.*$@    v_wfence="" # reverted on purpose\n    unused_wfence="x@' \
    -e 's@^    v_seatrow="\*\*AND YOU DO NOT OPEN SEATS OF YOUR OWN.*$@    v_seatrow="" # reverted on purpose\n    unused_seatrow="x@' \
  "$SCRIPT" >"$ROLE_BAD"
check "19s. the role-blind build differs from this one, by those three lines" \
  "! diff -q '$SCRIPT' '$ROLE_BAD' >/dev/null \
   && [ \"\$(grep -c 'reverted on purpose' '$ROLE_BAD')\" = 3 ]"
SEC_ROLE="$TMPROOT/sec-role"
RV19RB="$(mint_pair "$ROLE_BAD" T1 19rb "$SEC_ROLE")"
check "19t. [control] the role-blind build minted both briefs, so the rows below can run" \
  "[ -n \"\${RV19RB##*	}\" ] && [ \"\$(wc -l <'$SEC_ROLE' | tr -d ' ')\" -ge 20 ]"
for s19 in '## Where you work' '## 4. The boundaries' '## 6. The engine you run on'; do
  check "19u. [discrimination] § 19b FAILS on it, naming: $s19" \
    "classify_misses '$SEC_ROLE' | grep -qF 'MUST_DIFFER but IDENTICAL: $s19'"
done
# ---- MUTANT C: THE T2 HALF. One sed puts the tier RIDER back where `b726a3e`
# appended it — the end of the whole contract, which at T2 is the T2 fence — and
# one reverts the validator's tester section to the driver's.
T2_BAD="$EXEC_SKILLS/lcars-eeh/t2-blind.sh"
sed -e 's@^  \[ -z "\$v_tier" \] || contract="\$(contract_for_tier .*$@  [ -z "$v_tier" ] || contract="$(printf "%s\\\\n\\\\n%s\\\\n" "$contract" "$v_tier")" # reverted on purpose@' \
    -e 's@^    v_t2tester="### THE T2 TESTER IS NOT YOURS TO STAND UP.*$@    v_t2tester="" # reverted on purpose\n    unused_t2tester="x@' \
  "$SCRIPT" >"$T2_BAD"
check "19v. the T2-blind build differs from this one, by those two lines" \
  "! diff -q '$SCRIPT' '$T2_BAD' >/dev/null \
   && [ \"\$(grep -c 'reverted on purpose' '$T2_BAD')\" = 2 ]"
SEC_T2BAD="$TMPROOT/sec-t2bad"
RV19TB="$(mint_pair "$T2_BAD" T2 19tb "$SEC_T2BAD")"
check "19w. [control] the T2-blind build minted both briefs, so the rows below can run" \
  "[ -n \"\${RV19TB##*	}\" ] && [ \"\$(wc -l <'$SEC_T2BAD' | tr -d ' ')\" -ge 20 ]"
check "19x. [discrimination] § 19n FAILS on it — the rider missed the T1 fence" \
  "t2misses '$SEC_T2BAD' | grep -qF 'MUST_DIFFER but IDENTICAL: ### T1 — one delegate owns the unit end-to-end, and ABSORBS ITS OWN STUMBLES'"
check "19y. [discrimination] …and the tester section went identical in both briefs" \
  "t2misses '$SEC_T2BAD' | grep -qF 'ROLE_ONLY but IDENTICAL: ### Standing up your fresh-context tester (T2)'"
# ---- CURE 3: § 19 ASSERTED *DIFFERENCE*, NEVER *CORRECTNESS* ------------
# A fresh tester built five mutants and ran them through the shipped tables.
# **M3 is why this block exists:** revert § 4's write fence to the DRIVER's
# permission and add a cosmetic parenthetical, so the validator's § 4 reads
# *"Everything you write stays inside … the mission's own branch. (A validation
# pass works to the same fence.)"* — and § 19b PASSED, and § 19n PASSED. The
# section still DIFFERED, so every row stayed green while the cure was silently
# withdrawn. It matters more than it looks: the tester found **no harness
# enforcement of the write fence at all** — nothing seat-related in `ech.sh`
# matches `git (commit|diff|status)|dirty|working tree|uncommitted`, and
# `VALIDATOR_ACTS` is keyed on verb strings only. **The brief is the sole
# control on a validation pass editing the branch.**
#
# SO EVERY MUST_DIFFER SECTION DECLARES ITS RETRACTION, and three things are
# checked per entry: the needle is in the VALIDATOR'S OWN SECTION (not merely
# somewhere in the file — the S368 § 19p lesson), it is **absent from the whole
# driver brief** (which is what makes it a retraction and not boilerplate), and
# the table is complete in BOTH directions, so a new MUST_DIFFER section cannot
# be added without someone writing down what it retracts.
#
# WHAT THIS STILL CANNOT SEE, stated plainly because the next reader will
# assume otherwise: a **paraphrase or an injection inside an already-DIFFERS
# section**. The tester's M4 (a reworded tester instruction) passes all four of
# § 19r's literal greps, and its M5 (a fix instruction added inside a section
# that already differs) is invisible to § 19b, § 19n and all six § 19h greps —
# and it is invisible to these rows too, because the retraction it demands is
# still present. That is a judgement about new prose, not a diff, and no
# grep-shaped control will settle it; `ORCHESTRATION.md` § *the infer-vs-record
# check* is why this suite does not try to build one.
RETRACT='### T1 — one delegate owns the unit end-to-end, and ABSORBS ITS OWN STUMBLES	two of that contract
## 2. The output format expected back	What you FILED
## 3. The LCARS verbs in scope	THERE IS EXACTLY ONE SCRIPT
### YOUR CHUNK, AND THE AUTHORITY THAT COMES WITH IT	You are a VALIDATION PASS over a chunk somebody else drove
### THE BOUNDARY: THESE NINE VERBS, AND NOTHING ELSE	IS NOT YOURS EITHER
### The front door, and it is not optional	is NOT yours: filing a Mission into this chunk is
### What you decide alone, and what goes UP	You do NOT decide:
## 5. YOU verify your chunk; the MAIN ECH verifies the whole	YOU ARE A VALIDATION PASS, AND THIS SECTION IS YOURS
## Where you work	YOU DO NOT WRITE TO IT
## 4. The boundaries	YOU WRITE NO CODE AND YOU COMMIT NOTHING
## 6. The engine you run on	AND YOU DO NOT OPEN SEATS OF YOUR OWN
### And while you work: BEAT	LOOK, NARROW, FILE
## 1. The goal	IT IS TO FIND OUT WHETHER IT IS'
RETRACT_T2='### T1 — one delegate owns the unit end-to-end, and ABSORBS ITS OWN STUMBLES	two of that contract
## 2. The output format expected back	What you FILED
## 3. The LCARS verbs in scope	THERE IS EXACTLY ONE SCRIPT
### YOUR CHUNK, AND THE AUTHORITY THAT COMES WITH IT	You are a VALIDATION PASS over a chunk somebody else drove
### THE BOUNDARY: THESE NINE VERBS, AND NOTHING ELSE	IS NOT YOURS EITHER
### The front door, and it is not optional	is NOT yours: filing a Mission into this chunk is
### What you decide alone, and what goes UP	You do NOT decide:
## 5. YOU verify your chunk; the MAIN ECH verifies the whole	YOU ARE A VALIDATION PASS, AND THIS SECTION IS YOURS
## Where you work	YOU DO NOT WRITE TO IT
## 4. The boundaries	YOU WRITE NO CODE AND YOU COMMIT NOTHING
## 6. The engine you run on	AND YOU DO NOT OPEN SEATS OF YOUR OWN
### And while you work: BEAT	LOOK, NARROW, FILE
## 1. The goal	IT IS TO FIND OUT WHETHER IT IS
### T2 — T1, plus an independent FRESH-CONTEXT tester at the gate	TWO ACTS ARE NOT YOURS EITHER
## Your tier: T2	BOTH FENCES BELOW CARRY A RIDER'
# retract_misses <driver-brief> <validator-brief> <must-table> <retract-table>
retract_misses() {
  python3 - "$1" "$2" "$3" "$4" <<'PYRT'
import re, sys
drv = open(sys.argv[1]).read()
val = open(sys.argv[2]).read()
must = [l for l in sys.argv[3].splitlines() if l]
pairs = {}
for l in sys.argv[4].splitlines():
    if "\t" in l:
        h, n = l.split("\t", 1)
        pairs[h] = n
def body(text, head):
    out, cur, buf = {}, None, []
    for line in text.splitlines():
        if re.match(r'^#{2,3} ', line):
            if cur is not None:
                out[cur] = "\n".join(buf)
            cur, buf = line.strip(), []
        else:
            buf.append(line)
    if cur is not None:
        out[cur] = "\n".join(buf)
    return out.get(head)
for h in must:
    n = pairs.get(h)
    if n is None:
        print("NO DECLARED RETRACTION: %s" % h)
        continue
    b = body(val, h)
    if b is None:
        print("SECTION ABSENT FROM THE VALIDATOR BRIEF: %s" % h)
    elif n not in b:
        print("RETRACTION MISSING from the validator's own section: %s [wanted: %s]" % (h, n))
    if n in drv:
        print("NOT A RETRACTION — the DRIVER brief says it too: %s [%s]" % (h, n))
for h in pairs:
    if h not in must:
        print("DECLARED A RETRACTION FOR A SECTION THAT IS NOT MUST_DIFFER: %s" % h)
PYRT
}
check "19za. [control] a retraction is declared for EVERY MUST_DIFFER section, both tiers" \
  "[ \"\$(printf '%s\\n' \"\$MUST_DIFFER\" | wc -l)\" = \"\$(printf '%s\\n' \"\$RETRACT\" | wc -l)\" ] \
   && [ \"\$(printf '%s\\n' \"\$MUST_DIFFER_T2\" | wc -l)\" = \"\$(printf '%s\\n' \"\$RETRACT_T2\" | wc -l)\" ]"
check "19zb. EVERY MUST_DIFFER section's VALIDATOR SIDE SAYS ITS RETRACTION (T1)" \
  "[ -z \"\$(retract_misses '$BD19' '$BV19' \"\$MUST_DIFFER\" \"\$RETRACT\")\" ]"
if [ -n "$(retract_misses "$BD19" "$BV19" "$MUST_DIFFER" "$RETRACT")" ]; then
  printf '       --- retractions the T1 validator brief does not carry ---\n'
  retract_misses "$BD19" "$BV19" "$MUST_DIFFER" "$RETRACT" | sed 's/^/       /'
fi
check "19zc. …and the same of the T2 pair" \
  "[ -z \"\$(retract_misses '$BD19T2' '$BV19T2' \"\$MUST_DIFFER_T2\" \"\$RETRACT_T2\")\" ]"
if [ -n "$(retract_misses "$BD19T2" "$BV19T2" "$MUST_DIFFER_T2" "$RETRACT_T2")" ]; then
  printf '       --- retractions the T2 validator brief does not carry ---\n'
  retract_misses "$BD19T2" "$BV19T2" "$MUST_DIFFER_T2" "$RETRACT_T2" | sed 's/^/       /'
fi
# ---- MUTANT M3: the tester's own. The cure withdrawn, the difference kept. --
M3_BAD="$EXEC_SKILLS/lcars-eeh/m3-fence-withdrawn.sh"
# BUILT WITH PYTHON, NOT SED: M3 is the DRIVER'S OWN SENTENCE verbatim plus a
# cosmetic parenthetical, and that sentence carries backticks and an apostrophe
# that no single-quoted sed replacement can hand to a double-quoted shell
# string without an escape this suite would then be testing instead of the fix.
python3 - "$SCRIPT" "$M3_BAD" <<'PYM3'
import sys
lines = open(sys.argv[1]).read().split("\n")
for i, l in enumerate(lines):
    if l.startswith('    v_wfence="- **YOU WRITE NO CODE'):
        lines[i] = ('    v_wfence="- Everything you write stays inside \\`.git/lcars/\\` '
                    "or the mission's own branch. "
                    '(A validation pass works to the same fence.)" # reverted on purpose'
                    '\n    unused_wfence="x')
        break
else:
    raise SystemExit("M3: anchor not found in the script under test")
open(sys.argv[2], "w").write("\n".join(lines))
PYM3
check "19zd. the M3 build differs from this one, by that one line" \
  "! diff -q '$SCRIPT' '$M3_BAD' >/dev/null \
   && [ \"\$(grep -c 'reverted on purpose' '$M3_BAD')\" = 1 ] \
   && grep -q 'works to the same fence' '$M3_BAD'"
SEC_M3="$TMPROOT/sec-m3"
RV19M3="$(mint_pair "$M3_BAD" T1 19m3 "$SEC_M3")"
R19M3="${RV19M3%	*}"; V19M3="${RV19M3##*	}"
BD19M3="$R19M3/.git/lcars/delegates/d1/BRIEF.md"
BV19M3="$R19M3/.git/lcars/delegates/$V19M3/BRIEF.md"
check "19ze. [control] M3 minted both briefs, so the rows below can run" \
  "[ -n '$V19M3' ] && [ -s \"$BV19M3\" ] && [ \"\$(wc -l <'$SEC_M3' | tr -d ' ')\" -ge 20 ]"
check "19zf. [control] …and its § 4 STILL DIFFERS — the parenthetical is enough" \
  "grep -q \"^DIFFERS.*## 4. The boundaries\$\" '$SEC_M3'"
check "19zg. [the point] § 19b PASSES on M3 — difference is not correctness" \
  "[ -z \"\$(classify_misses '$SEC_M3')\" ]"
check "19zh. [discrimination] …and § 19zb FAILS on it, naming § 4" \
  "retract_misses \"$BD19M3\" \"$BV19M3\" \"\$MUST_DIFFER\" \"\$RETRACT\" \
     | grep -q 'RETRACTION MISSING.*## 4. The boundaries'"
# AND THE HELPER'S OTHER DIAGNOSTIC HAS ITS OWN KNOWN-BAD CONTROL. "NOT A
# RETRACTION" guards the TABLE rather than the product: it fires when a declared
# needle is boilerplate both briefs carry, which M3 cannot trigger because M3
# REMOVES the needle. So it is proven on a deliberately bad one-entry table.
check "19zi. [control] the NON-retraction branch fires on a needle BOTH briefs carry" \
  "retract_misses \"$BD19\" \"$BV19\" '## 4. The boundaries' \
     \"\$(printf '## 4. The boundaries\\tAlso, and without exception:')\" \
     | grep -q 'NOT A RETRACTION'"
check "19zj. [control] …and that same needle really is in BOTH briefs, so the row is honest" \
  "grep -qF 'Also, and without exception:' \"$BD19\" && grep -qF 'Also, and without exception:' \"$BV19\""
if [ -n "$(retract_misses "$BD19M3" "$BV19M3" "$MUST_DIFFER" "$RETRACT")" ]; then
  printf '       --- what M3 gets wrong (expected) ---\n'
  retract_misses "$BD19M3" "$BV19M3" "$MUST_DIFFER" "$RETRACT" | sed 's/^/       /'
fi
echo

# =========================================================================
printf '== 20. THE GATE FAILS CLOSED: every spelling of a selector it cannot resolve ==\n'
# =========================================================================
# FOUND 1, and the CLASS behind it. Round 2's gate was
# `[ -n "$xseat" ] && mexists "$xparent"`, and `mexists` is
# `[ -f "$MISSIONS/<exact-name>/state.json" ]` while `lcars-log/log.sh` resolves
# `--parent` by exact id OR issue number OR case-insensitive substring of the id
# OR of the title. The gate and the target disagreed about what the argument
# MEANS, and on anything the gate could not resolve it SKIPPED ITSELF.
#
# MEASURED AT `ad34d78` with a loosely-resolving stand-in, narrowed pass:
# the canonical spelling refused, EIGHT others ran, and `filed` grew 1 -> 9.
R20="$(fast_chunk_repo)"
xech - "$R20" delegate mine --validate --trigger wide --why "the keystone" >/dev/null 2>&1
V20="$(validator_of "$R20")"
xech "$V20" "$R20" file-bug --parent m-mine --prd "$PRD_GOOD" >/dev/null 2>&1
xech - "$R20" revalidate "$V20" >/dev/null 2>&1
apj "$R20" "delegates.$V20.filed" >"$TMPROOT/filed20.before"
check "20a. [control] the pass is narrowed and has something in its scope" \
  "apj '$R20' delegates.$V20.recheckScope | grep -q 'bug-' && grep -q 'bug-' '$TMPROOT/filed20.before'"
# EVERY SPELLING, one row each. The point is not the list — it is that each one
# is a selector the GATE cannot resolve and the TARGET can.
spell20() {   # spell20 <label> <args…>
  local label="$1"; shift
  : >"$R20/exec-ran.log"
  local rc=0
  xech "$V20" "$R20" "$@" >"$TMPROOT/out20.txt" 2>&1 || rc=$?
  check "20b. REFUSED, and nothing ran: $label" \
    "[ $rc -ne 0 ] && [ -z \"\$(ran_log '$R20')\" ]"
}
spell20 "--parent m-mine (canonical)"       exec lcars-log/log.sh --parent m-mine
spell20 "--parent mine (unit label)"        exec lcars-log/log.sh --parent mine
spell20 "--parent=mine (equals form)"       exec lcars-log/log.sh --parent=mine
spell20 "two-argument exec form"            exec lcars-log log.sh --parent mine
spell20 "repeated --parent"                 exec lcars-log/log.sh --parent m-mine --parent mine
spell20 "a TITLE substring"                 exec lcars-log/log.sh --parent "mission m-mine"
spell20 "a SIBLING's chunk"                 exec lcars-log/log.sh --parent theirs
spell20 "UPPER CASE (filesystem-dependent)" exec lcars-log/log.sh --parent M-MINE
spell20 "no selector at all"                exec lcars-log/log.sh
spell20 "--mission, loosely"                exec lcars-log/log.sh --mission mine
spell20 "both selectors at once"            exec lcars-log/log.sh --parent m-mine --mission m-mine
# ---- AND THE SELECTOR IS A LITERAL, NOT A PATTERN (S368, CURE 1). The scope
# compare was `printf '%s\n' "$scope" | grep -qx "$sel"` — a BASIC REGULAR
# EXPRESSION — two lines below a comment reading *"the same LITERAL this pass's
# own record carries"*. The same file already gets this right in three other
# places (`grep -qxF`, `grep -qF`), so the intent was never in doubt.
#
# MEASURED AT `b726a3e` with `recheckScope=["bug-001"]`: every selector below
# PASSED the narrowed gate. `lcars-log/log.sh` resolves `--parent` by
# case-insensitive SUBSTRING of the id, so `bug.001` lands on the CHUNK ROOT,
# `filed` grows, and the next `revalidate` snapshots the widened scope — the
# documented spiral, reached through a plausible TYPO rather than an attack.
#
# THE DERIVATION IS FROM THE REAL SCOPE, and each row's known-good control is
# the pair of greps itself: a BRE compare accepts the selector and a LITERAL
# compare does not. That is what makes the refusal below mean "literal", rather
# than "this particular string happens to be refused".
RX20="$(tr -d '[]" ' <"$TMPROOT/filed20.before" | cut -d, -f1)"
check "20b0. [control] the re-check scope is ONE entry and the rows derive from it" \
  "[ -n '$RX20' ] && [ \"\$(apj '$R20' delegates.$V20.recheckScope | tr -cd , )\" = '' ]"
for rx20 in "${RX20/-/.}" "${RX20%%-*}.*" '.*' "${RX20%?}." "^$RX20\$" \
            "[${RX20:0:1}]${RX20:1}" "${RX20}1*" "$RX20\\|x"; do
  check "20b1. [control] \`$rx20\` is a PATTERN a basic-regex compare accepts, and a literal one does not" \
    "printf '%s\\n' '$RX20' | grep -qx '$rx20' \
     && ! printf '%s\\n' '$RX20' | grep -qxF -- '$rx20'"
  spell20 "a REGEX, not a literal: --parent $rx20" \
    exec lcars-log/log.sh --parent "$rx20"
done
# ---- AND A SELECTOR IS ONE STRING, NOT A LIST OF LINES (S368 fix round 1).
# `-F` fixed the PATTERN and left the OTHER separator semantic: POSIX grep takes
# its pattern operand as a **NEWLINE-SEPARATED LIST OF PATTERNS**, so a selector
# that merely CONTAINS an in-scope id on a line of its own satisfied the
# compare — and a selector ENDING in a newline contributes an EMPTY pattern,
# which matches everything. Measured at `cabbb36` on /usr/bin/grep (BSD grep
# 2.6.0-FreeBSD), the one the script resolves: through this same `exec` door,
# narrowed pass, five newline forms all RAN and FILED and `filed` grew 1 -> 7.
#
# THE CLASS, AND WHY THIS IS THE LAST GENERATION: a string equality test was
# implemented with a LINE-MATCHING TOOL. `-qx` was wrong, `-qxF` was wrong,
# `-qxF --` was wrong — each fix tried to make grep behave like `=`. The decider
# is `scope_has` now, which IS `=`, and there is no grep left in it.
check "20b2. [control] the harness's own grep DOES read its pattern as a LINE LIST" \
  "printf '%s\\n' '$RX20' | grep -qxF -- \"\$(printf 'm-theirs\\n%s' '$RX20')\""
check "20b3. [negative control] …and it is the NEWLINE, not whitespace — a CR does NOT match" \
  "! printf '%s\\n' '$RX20' | grep -qxF -- \"\$(printf '%s\\r' '$RX20')\""
NL20_1=$'m-theirs\n'"$RX20"
NL20_2="$RX20"$'\nm-theirs'
NL20_3=$'mine\n'"$RX20"
NL20_4=$'.*\n'"$RX20"
NL20_5="$RX20"$'\n'
for i20 in 1 2 3 4 5; do
  eval "nl20=\$NL20_$i20"
  # BOTH HALVES COMPUTED HERE, never inside an eval'd condition: a newline in a
  # `check` string would be the harness lying to itself about what it ran.
  if printf '%s\n' "$RX20" | grep -qxF -- "$nl20"; then g20=MATCH; else g20=no; fi
  if [ "$nl20" = "$RX20" ]; then e20=equal; else e20=notequal; fi
  lbl20="$(printf '%s' "$nl20" | tr '\n' '/')"
  check "20b4. [control] grep ACCEPTS it as a line list while \`=\` says NOT equal: $lbl20" \
    "[ '$g20' = MATCH ] && [ '$e20' = notequal ]"
  spell20 "a LINE LIST, not one string: $lbl20" \
    exec lcars-log/log.sh --parent "$nl20"
done
apj "$R20" "delegates.$V20.filed" >"$TMPROOT/filed20.after"
check "20c. …and across every spelling the FILED list never grew" \
  "cmp -s '$TMPROOT/filed20.before' '$TMPROOT/filed20.after'"
check "20d. the refusal says it will not guess, rather than naming one spelling" \
  "grep -qE 'WILL NOT GUESS|NAMED NO MISSION|RE-CHECKS ONLY WHAT IT FILED' '$TMPROOT/out20.txt'"
# ---- NOT AN OUTAGE, FOUR WAYS. Each of these must still go through.
: >"$R20/exec-ran.log"
INS20="$(tr -d '[]" ' <"$TMPROOT/filed20.before" | cut -d, -f1)"
rc20e=0; xech "$V20" "$R20" exec lcars-log/log.sh --parent "$INS20" >/dev/null 2>&1 || rc20e=$?
check "20e. [control] the in-scope EXACT id still goes through" \
  "[ -n '$INS20' ] && [ $rc20e -eq 0 ] && [ -n \"\$(ran_log '$R20')\" ]"
: >"$R20/exec-ran.log"
rc20f=0; xech d1 "$R20" exec lcars-log/log.sh --parent mine >/dev/null 2>&1 || rc20f=$?
check "20f. [control] a DRIVER's loose selector is UNTOUCHED — parked D1 not widened" \
  "[ $rc20f -eq 0 ] && [ -n \"\$(ran_log '$R20')\" ]"
: >"$R20/exec-ran.log"
rc20g=0; xech - "$R20" exec lcars-log/log.sh --parent mine >/dev/null 2>&1 || rc20g=$?
check "20g. [control] the MAIN ECH's loose selector is untouched" \
  "[ $rc20g -eq 0 ] && [ -n \"\$(ran_log '$R20')\" ]"
R20B="$(fast_chunk_repo)"
xech - "$R20B" delegate mine --validate --trigger wide --why "round one" >/dev/null 2>&1
V20B="$(validator_of "$R20B")"
: >"$R20B/exec-ran.log"
rc20h=0; xech "$V20B" "$R20B" exec lcars-log/log.sh --parent mine >/dev/null 2>&1 || rc20h=$?
check "20h. [control] a ROUND-1 validator's loose selector is untouched — round 1 IS the chunk" \
  "[ $rc20h -eq 0 ] && [ -n \"\$(ran_log '$R20B')\" ]"
# ---- AND THE CLASS, STATED AS A PROPERTY: the four scoped VERBS fail closed on
# a selector they cannot resolve, by DESIGN now rather than by accident of a
# stricter target. The tester noted they were safe only because `cmd_*` calls
# `mexists … || die` before the scope check; these rows pin that.
for v20 in "file-bug --parent" "live-check" "drive"; do
  rc=0; xech "$V20" "$R20" ${v20% *} ${v20##* } mine --prd "$PRD_GOOD" >"$TMPROOT/out20v.txt" 2>&1 || rc=$?
  check "20i. a loose selector on \`${v20% *}\` fails CLOSED too" "[ $rc -ne 0 ]"
done
check "20j. …and that refusal is the strict resolve, not a scope decision" \
  "grep -qiE 'no (parent )?mission|not in your chunk|OUTSIDE YOUR RE-CHECK|NOT AN ACT' '$TMPROOT/out20v.txt'"
echo

# --- zero spend, every run ------------------------------------------------
check "15a. ZERO worker spend: no claude/copilot was invoked" \
  "[ ! -s '$LCARS_DRIVE_SHIM_LOG' ]"

echo
printf 'one-layer-validation: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
