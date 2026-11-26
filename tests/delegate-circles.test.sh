#!/usr/bin/env bash
#
# tests/delegate-circles.test.sh — S359: A DELEGATE GOING IN CIRCLES IS NAMED
# (skill source: skills/lcars-eeh/ech.sh § delegate_beat_rows / cmd_stalled
#              + skills/lcars-eeh/DELEGATION.md § NO SILENT HOURS).
#
# THE FOURTH PUBLISHED DEFENCE AGAINST SILENT FAILURE. S351 gave the ECH a beat
# (silence), S352 a BLOCKED lane (the delegate spoke), S354 a step number and a
# BEATING BUT NOT MOVING lane (motion). All three read the delegate's clock or
# its step. None of them can see the pattern this suite is about: THE SAME WORK,
# DONE AGAIN, WITH NOTHING CHANGING.
#
# WHICH RUN TAUGHT THE SIGNATURE — AND THE TRAP IT SET. The signature was not
# guessed; it was read out of the S353 capstone's own records (mission
# lcars-20261119-001-7f06, frozen at lcars-dev/tests/drives/s353/evidence/
# d2-frozen/d2-record.json):
#
#   TRUE POSITIVE — ticket t-001 burned all three TDD sessions. Sessions 1 and 2
#   each ran the IDENTICAL gate command and failed on the SAME single
#   out-of-scope file; the worker reported 6 iterations inside one session.
#
#   TRUE NEGATIVE — and this is the trap. Delegate d2 beat FIVE times at the
#   SAME step 2/7 over ~60 minutes, and every beat carried DIFFERENT content:
#   "research done (10 agents), validate running" → "validate/plan(5 tickets)/
#   plan-review/schedule(4 waves) done, implement running" → "implement wave
#   1/4, ticket t-001 in progress" → … A detector keyed on THE STEP NOT
#   INCREMENTING would have accused a delegate that was visibly advancing.
#
# SO THE SIGNATURE IS KEYED ON THE WORK NOT CHANGING, NEVER ON THE STEP NOT
# INCREMENTING. § 3 below replays that exact beat sequence, verbatim from the
# record, and asserts the lane stays SILENT about it. That is the most important
# assertion in this file: a false positive here teaches the captain to ignore
# the lane, which is worse than not having it.
#
# WHICH RECORDS IT READS. Only ones the product ALREADY writes: the beat `line`,
# the beat `step` {k,n}, and `status`. NO NEW TELEMETRY. In particular the ECH
# records nothing about a delegate's working tree — it has no path, no pid and
# no worktree for one — so "did the working tree change between beats" is a fact
# this product does not have, and the lane is honest about being blind to a
# delegate that loops while REWORDING each beat (§ 4).
#
# DEPENDENCIES ARE ENV-INJECTED (the lcars-init pattern) and zero worker spend
# is pinned by the PATH shim, exactly as tests/delegation.test.sh does it.
#
# Usage: bash tests/delegate-circles.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${LCARS_ECH_SCRIPT:-$REPO_ROOT/skills/lcars-eeh/ech.sh}"

pass=0
fail=0
if [ -n "${LCARS_TEST_TMP_ROOT:-}" ]; then
  TMPROOT="$(mktemp -d "$LCARS_TEST_TMP_ROOT/circles.XXXXXX")"
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

# --- the spend fuse (tests/delegation.test.sh's, verbatim in intent) ------
SHIM_DIR="$DIR/lib/shims/deploy-watcher"
export LCARS_DRIVE_SHIM_LOG="$TMPROOT/worker-shim.log"
: >"$LCARS_DRIVE_SHIM_LOG"
PATH="$SHIM_DIR:$PATH"; export PATH
if [ ! -x "$SHIM_DIR/claude" ] || [ ! -x "$SHIM_DIR/copilot" ]; then
  printf 'SPEND FUSE TRIPPED: no counting claude/copilot at %s — REFUSING (would bill)\n' \
    "$SHIM_DIR" >&2
  exit 1
fi

# --- fixtures -------------------------------------------------------------

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
{ "testCommand": "bash tests/run.sh", "engine": "copilot" }
JSON
  echo "$repo"
}

new_mission() {
  local repo="$1" id="$2" stage="$3"
  local d="$repo/.git/lcars/missions/$id"
  mkdir -p "$d"
  cat >"$d/state.json" <<JSON
{
  "id": "$id",
  "stage": "$stage",
  "type": "feature",
  "title": "mission $id",
  "branch": "lcars/$id",
  "issue": "1"
}
JSON
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
  local path="$1" rc="$2"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$0 $*" >> "$STUB_LOG"\n'
    printf 'exit %s\n' "$rc"
  } >"$path"
  chmod +x "$path"
}

STUBS="$TMPROOT/stubs"
STUB_LOG="$TMPROOT/stub.log"
: >"$STUB_LOG"
mkdir -p "$STUBS"
for s in run.sh approve.sh xo.sh respond.sh log.sh file.sh resolve-logs.sh notify.sh crontab gh; do
  stub "$STUBS/$s" 0
done

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
  LCARS_LOG_SCRIPT="$STUBS/log.sh" \
  LCARS_FILE_SCRIPT="$STUBS/file.sh" \
  LCARS_RESOLVE_LOGS_SCRIPT="$STUBS/resolve-logs.sh" \
  LCARS_NOTIFY="$STUBS/notify.sh" \
  LCARS_CRONTAB_BIN="$STUBS/crontab" \
  LCARS_GH_BIN="$STUBS/gh" \
  bash "$script" "$@" </dev/null
}
ech() { local repo="$1"; shift; ech_at "$SCRIPT" "$repo" "$@"; }

# A repo with ONE minted T1 delegate (id d1) on a real mission.
circ_repo() {
  local r; r="$(new_repo)"
  ap_init "$r"
  new_mission "$r" progress implement
  ech "$r" tier progress --tier T1 --why "one bounded unit" >"$TMPROOT/mint.log" 2>&1
  ech "$r" delegate progress >>"$TMPROOT/mint.log" 2>&1
  printf '%s\n' "$r"
}

# THE PLANTED LOOP — the capstone's TRUE POSITIVE in miniature: t-001's two TDD
# sessions ran the IDENTICAL gate command and failed on the SAME out-of-scope
# file. Three identical beats, the step never advancing.
LOOP_LINE='ran the scope gate: FAIL — one out-of-scope file, src/other.py'
circ_loop_repo() {
  local r; r="$(circ_repo)"
  ech "$r" beat d1 "$LOOP_LINE" --step 4/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 "$LOOP_LINE" --step 4/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 "$LOOP_LINE" --step 4/7 >>"$TMPROOT/beat.log" 2>&1
  printf '%s\n' "$r"
}

# THE CAPSTONE'S OWN SEQUENCE, verbatim from d2-record.json. Five beats at the
# SAME step 2/7, every one DIFFERENT work. A delegate that was advancing.
circ_capstone_repo() {
  local r; r="$(circ_repo)"
  ech "$r" beat d1 'BLOCKED: this seat is copilot model gpt-6.1-sol; the brief requires copilot model claude-opus-5.5. Mission work has not started; ECH must provide the stamped model seat.' >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'ECH answered the block: relaunched on the stamped seat copilot/claude-opus-5.5. Begin the unit.' >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'completed step 1 of 7: oriented — seat copilot/opus-5.5, budget exit 0, mission at stage align' --step 1/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'step 2 of 7 running: drive — research done (10 agents), validate running' --step 2/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'step 2 of 7 running: drive — validate/plan(5 tickets)/plan-review/schedule(4 waves) done, implement running' --step 2/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'step 2 of 7 running: implement wave 1/4, ticket t-001 in progress' --step 2/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'step 2 of 7 running: implement wave 1/4, t-001 in proof gates' --step 2/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r" beat d1 'step 2 of 7 running: t-001 flip-flop FAIL session 1 (tip red); harness re-spawned tdd session 2' --step 2/7 >>"$TMPROOT/beat.log" 2>&1
  printf '%s\n' "$r"
}

circ_limit() ( export LCARS_ECH_CIRCLE_BEATS="$1"; shift; ech "$@"; )

# ==========================================================================
printf '\n== S359/1. A PLANTED LOOP IS NAMED, WITH ITS EVIDENCE ==\n'
# ==========================================================================
r1="$(circ_loop_repo)"
ech "$r1" stalled >"$TMPROOT/s1.out" 2>"$TMPROOT/s1.err"; rc=$?
cat "$TMPROOT/s1.out" | sed 's/^/       /'
check "S359/1 \`stalled\` exits 0 and opens a GOING IN CIRCLES line for d1" \
  "[ $rc -eq 0 ] && grep -q '^GOING IN CIRCLES: d1 ' '$TMPROOT/s1.out'"
check "S359/1 the line carries the unit and the tier, like every other lane" \
  "grep -q '^GOING IN CIRCLES: d1 (unit progress, tier T1)' '$TMPROOT/s1.out'"
check "S359/1 THE EVIDENCE — how many times the same work was reported" \
  "grep -q 'GOING IN CIRCLES.*3 times' '$TMPROOT/s1.out'"
check "S359/1 THE EVIDENCE — the repeated work quoted in the delegate's OWN WORDS" \
  "grep -qF 'ran the scope gate: FAIL — one out-of-scope file, src/other.py' '$TMPROOT/s1.out'"
check "S359/1 THE THRESHOLD APPLIED is stated on the line that applies it" \
  "grep -q 'GOING IN CIRCLES.*3 beats (LCARS_ECH_CIRCLE_BEATS)' '$TMPROOT/s1.out'"
check "S359/1 it says which step the repetition is happening at" \
  "grep -q 'GOING IN CIRCLES.*step 4/7' '$TMPROOT/s1.out'"
check "S359/1 THE NEXT ACTION is named, with this delegate's own ids filled in" \
  "grep -q 'delegate close d1' '$TMPROOT/s1.out' && grep -qi 'RE-BRIEF' '$TMPROOT/s1.out'"
check "S359/1 NEVER A KILL — the lane says so out loud, as the other lanes do" \
  "grep -q 'A KILL IS NOT ON THAT LIST' '$TMPROOT/s1.out'"
check "S359/1 it says what CLEARS the line (different work, or an advancing step)" \
  "grep -qi 'what clears this line.*DIFFERENT work' '$TMPROOT/s1.out'"
check "S359/1 IT IS NOT A VERDICT, and it says that too" \
  "grep -qi 'not a verdict' '$TMPROOT/s1.out'"
check "S359/1 ITS OWN TALLY — counted apart from quiet, blocked and untimeable" \
  "grep -qE '^1 delegate\(s\) are GOING IN CIRCLES' '$TMPROOT/s1.out'"
check "S359/1 the circles tally is NOT merged into the quiet/blocked tallies" \
  "! grep -q 'gone quiet past the limit' '$TMPROOT/s1.out' && ! grep -q 'RAISED A BLOCK' '$TMPROOT/s1.out'"
check "S359/1 the lane is distinct from NOT-MOVING: both appear, each in its own words" \
  "grep -q '^NOT-MOVING DELEGATE: d1' '$TMPROOT/s1.out' && grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s1.out'"
check "S359/1 nothing was written to stderr by a healthy run of the lane" \
  "[ ! -s '$TMPROOT/s1.err' ]"
# AND THE LANE IS ON THE VERB THE HOLOGRAM ACTUALLY DRIVES ON (the S353 lesson:
# a lane reachable only from an hourly cron entry has an hour of latency).
ech "$r1" next --all >"$TMPROOT/s1.next" 2>&1
check "S359/1 \`next\` banners the circling delegate (not only the hourly \`stalled\`)" \
  "grep -q 'DELEGATE GOING IN CIRCLES: d1' '$TMPROOT/s1.next'"
check "S359/1 ...and it is a BANNER, not the plan: the one NEXT: line still follows" \
  "grep -q '^NEXT:' '$TMPROOT/s1.next'"

# ==========================================================================
printf '\n== S359/2. AN ADVANCING STEP IS PROGRESS, NOT A CIRCLE ==\n'
# ==========================================================================
r2="$(circ_repo)"
for k in 1 2 3 4 5; do
  ech "$r2" beat d1 "ran the suite and committed" --step "$k/7" >>"$TMPROOT/beat.log" 2>&1
done
ech "$r2" stalled >"$TMPROOT/s2.out" 2>"$TMPROOT/s2.err"; rc=$?
check "S359/2 five identical lines across FIVE ADVANCING steps is never accused" \
  "[ $rc -eq 0 ] && ! grep -q 'GOING IN CIRCLES' '$TMPROOT/s2.out'"
check "S359/2 ...and the not-moving lane is silent about it too (it IS moving)" \
  "! grep -q 'NOT-MOVING' '$TMPROOT/s2.out'"

# ==========================================================================
printf '\n== S359/3. THE CAPSTONE DELEGATE — A WORKING DELEGATE IS NEVER ACCUSED ==\n'
# ==========================================================================
# THE MOST IMPORTANT ASSERTION IN THIS FILE. Five beats at a FIXED step 2/7,
# each carrying different work: the real sequence a naive "same step number"
# detector would have accused.
r3="$(circ_capstone_repo)"
ech "$r3" stalled >"$TMPROOT/s3.out" 2>"$TMPROOT/s3.err"; rc=$?
check "S359/3 the capstone's real beats at a FIXED step are NOT called a circle" \
  "[ $rc -eq 0 ] && ! grep -q 'GOING IN CIRCLES' '$TMPROOT/s3.out'"
check "S359/3 [control] the fixture really did beat 5 times at the same step 2/7" \
  "python3 - '$r3/.git/lcars/autopilot.json' <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))['delegates']['d1']
at2 = [b for b in r['beats'] if b.get('step') == {'k': 2, 'n': 7}]
assert len(at2) == 5, len(at2)
assert len({b['line'] for b in at2}) == 5, 'the fixture must carry FIVE DIFFERENT lines'
PY"
check "S359/3 [control] the MOTION signal still fires on it — that lane was right" \
  "grep -q '^NOT-MOVING DELEGATE: d1' '$TMPROOT/s3.out'"
ech "$r3" next --all >"$TMPROOT/s3.next" 2>&1
check "S359/3 \`next\` does not banner a circle for the working delegate either" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s3.next'"

# ==========================================================================
printf '\n== S359/4. REWORDED WORK: THE LIMIT IS STATED, NOT FAKED ==\n'
# ==========================================================================
r4="$(circ_repo)"
ech "$r4" beat d1 'still fixing the scope gate failure' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r4" beat d1 'the scope gate is still failing, working it' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r4" beat d1 'scope gate: continuing to fix the failure' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r4" stalled >"$TMPROOT/s4.out" 2>"$TMPROOT/s4.err"; rc=$?
check "S359/4 a loop REWORDED each beat is NOT caught — no capability is faked" \
  "[ $rc -eq 0 ] && ! grep -q 'GOING IN CIRCLES' '$TMPROOT/s4.out'"
check "S359/4 ...and the MOTION lane still catches it, which is the other half" \
  "grep -q '^NOT-MOVING DELEGATE: d1' '$TMPROOT/s4.out'"
# AND THE LIMIT IS SAID OUT LOUD WHERE THE LANE REPORTS, so a reader is never
# left thinking a quiet lane means no loop.
check "S359/4 the lane's own footer STATES what it cannot catch (reworded loops)" \
  "grep -qi 'REWORDING each beat is NOT caught' '$TMPROOT/s1.out'"
check "S359/4 the published doc states the same blind spot" \
  "grep -qi 'reword' '$REPO_ROOT/skills/lcars-eeh/DELEGATION.md'"
# TRIVIAL VARIANCE — case and whitespace — is the same work and IS caught.
r4b="$(circ_repo)"
ech "$r4b" beat d1 're-ran the gate' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r4b" beat d1 'Re-ran   the gate' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r4b" beat d1 're-ran the gate.' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
# NO PIPE INTO `grep -q` ANYWHERE IN THIS FILE. Under `set -o pipefail` a
# `grep -q` that matches early exits and SIGPIPEs the still-writing producer,
# and the pipeline's status becomes the producer's 141 — a genuine match read
# back as a failure. tests/lcars-eeh.test.sh carries the same warning in its
# `qgrep` header. Every assertion here greps a FILE.
ech "$r4b" stalled >"$TMPROOT/s4b.out" 2>/dev/null
check "S359/4 case, spacing and a trailing stop are the SAME work, and are caught" \
  "grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s4b.out'"

# ==========================================================================
printf '\n== S359/5. A DONE DELEGATE IS NEVER ACCUSED ==\n'
# ==========================================================================
r5="$(circ_loop_repo)"
ech "$r5" delegate close d1 >>"$TMPROOT/close.log" 2>&1
ech "$r5" stalled >"$TMPROOT/s5.out" 2>"$TMPROOT/s5.err"; rc=$?
check "S359/5 [control] it WAS being named before it was closed" \
  "grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s1.out'"
check "S359/5 a CLOSED (status done) delegate is never called a circle" \
  "[ $rc -eq 0 ] && ! grep -q 'GOING IN CIRCLES' '$TMPROOT/s5.out'"
check "S359/5 [control] the close really landed in the record" \
  "python3 -c \"import json;print(json.load(open('$r5/.git/lcars/autopilot.json'))['delegates']['d1']['status'])\" | grep -qx done"

# ==========================================================================
printf '\n== S359/6. THE THRESHOLD IS OVERRIDABLE, AND THE APPLIED VALUE IS STATED ==\n'
# ==========================================================================
r6="$(circ_loop_repo)"
circ_limit 5 "$r6" stalled >"$TMPROOT/s6a.out" 2>"$TMPROOT/s6a.err"; rc=$?
check "S359/6 raised to 5, a 3-repeat loop is NOT named (the override is read)" \
  "[ $rc -eq 0 ] && ! grep -q 'GOING IN CIRCLES' '$TMPROOT/s6a.out'"
r6b="$(circ_repo)"
ech "$r6b" beat d1 "$LOOP_LINE" --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r6b" beat d1 "$LOOP_LINE" --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r6b" stalled >"$TMPROOT/s6pre.out" 2>/dev/null
check "S359/6 at the default 3, TWO repeats are not enough" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s6pre.out'"
circ_limit 2 "$r6b" stalled >"$TMPROOT/s6b.out" 2>"$TMPROOT/s6b.err"; rc=$?
check "S359/6 lowered to 2, the same two repeats ARE named" \
  "[ $rc -eq 0 ] && grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s6b.out'"
check "S359/6 and the line states the value ACTUALLY APPLIED, not the default" \
  "grep -q 'GOING IN CIRCLES.*2 beats (LCARS_ECH_CIRCLE_BEATS)' '$TMPROOT/s6b.out' && ! grep -q 'GOING IN CIRCLES.*3 beats' '$TMPROOT/s6b.out'"
circ_limit 1 "$r6b" stalled >/dev/null 2>"$TMPROOT/s6c.err"
check "S359/6 one beat cannot show a repetition: 1 is out of range and degrades" \
  "grep -q 'WARNING.*LCARS_ECH_CIRCLE_BEATS' '$TMPROOT/s6c.err'"

# ==========================================================================
printf '\n== S359/7. A MALFORMED THRESHOLD DEGRADES AND SILENCES NOTHING ==\n'
# ==========================================================================
r7="$(circ_loop_repo)"
circ_limit '3 beats' "$r7" stalled >"$TMPROOT/s7.out" 2>"$TMPROOT/s7.err"; rc=$?
check "S359/7 a malformed value is a WARNING and never a refusal: exit 0" \
  "[ $rc -eq 0 ]"
check "S359/7 it warns on stderr and names the rejected value" \
  "grep -q 'WARNING.*LCARS_ECH_CIRCLE_BEATS' '$TMPROOT/s7.err' && grep -q '3 beats' '$TMPROOT/s7.err'"
check "S359/7 THE KNOWN-GOOD CONTROL: the lane still FIRES on the real loop" \
  "grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s7.out'"
check "S359/7 ...and says in band that the DEFAULT is what it applied" \
  "grep -q 'GOING IN CIRCLES.*3 beats (LCARS_ECH_CIRCLE_BEATS).*DEFAULT' '$TMPROOT/s7.out'"
# AND IT DOES NOT TAKE DOWN MACHINERY THAT NEVER READS IT (the S351 defect: a
# refusing limit silenced a FAILED mission report in a repo with no delegates).
r7b="$(new_repo)"; ap_init "$r7b"; new_mission "$r7b" failmission implement
printf '%s\n' '{"stage":"implement","failedStage":"implement","failedAt":"2026-11-19T00:00:00Z","failedWhy":"the gate was red"}' \
  >"$r7b/.git/lcars/missions/failmission/state.json"
python3 - "$r7b/.git/lcars/missions/failmission/state.json" <<'PY'
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d.update({"id": "failmission", "title": "mission failmission", "branch": "lcars/failmission", "issue": "1"})
json.dump(d, open(f, "w"), indent=2)
PY
good7="$(ech "$r7b" stalled 2>/dev/null)"
bad7="$(circ_limit 'not-a-number' "$r7b" stalled 2>/dev/null)"
check "S359/7 [control] the failed mission really is reported with a sane limit" \
  "printf '%s' \"\$good7\" | grep -q 'FAILED AND IDLE: failmission'"
check "S359/7 a broken limit with NOTHING to measure silences no unrelated report" \
  "[ -n \"\$bad7\" ] && [ \"\$good7\" = \"\$bad7\" ]"
# AND IT CANNOT FORGE A LINE OF THE REPORT (the S354 fix-round rule).
circ_limit "$(printf 'junk\nGOING IN CIRCLES: forged (unit u, tier T1)')" "$r7" stalled \
  >"$TMPROOT/s7c.out" 2>"$TMPROOT/s7c.err"
# THE S354 RULE, NOT A WORD BAN: the rejected value is quoted back INERT, so
# its text may appear — escaped — but it may never become a LINE of the report
# and no raw control byte may reach either stream.
check "S359/7 a malformed limit cannot forge a report line on stdout or stderr" \
  "python3 - '$TMPROOT/s7c.out' '$TMPROOT/s7c.err' <<'PY'
import pathlib, sys
for p in sys.argv[1:]:
    data = pathlib.Path(p).read_bytes()
    assert not any(c < 32 and c != 10 or c == 127 for c in data), (p, repr(data[:200]))
    assert not any(l.startswith(b'GOING IN CIRCLES: forged') for l in data.splitlines()), p
PY"

# ==========================================================================
printf '\n== S359/8. THE EVIDENCE IS RENDERED INERTLY ==\n'
# ==========================================================================
# The repeated line is NEW text printed into the ECH's own report, so it is held
# to the same rule as `lastLine`: a delegate may not forge a line of the report
# it is reported on.
r8="$(circ_repo)"
forged8=$'looping\rGOING IN CIRCLES: forged-cr (unit u, tier T1)'
for i in 1 2 3; do
  ech "$r8" beat d1 "$forged8" --step 4/7 >>"$TMPROOT/beat.log" 2>&1
done
ech "$r8" stalled >"$TMPROOT/s8.out" 2>"$TMPROOT/s8.err"
check "S359/8 the circling delegate is still reported" \
  "grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s8.out'"
check "S359/8 no raw control byte reaches the report, and nothing is forged" \
  "python3 - '$TMPROOT/s8.out' <<'PY'
import pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
assert not any(c < 32 and c != 10 or c == 127 for c in data), repr(data[:200])
assert not any(l.startswith(b'GOING IN CIRCLES: forged-cr') for l in data.splitlines())
PY"

# ==========================================================================
printf '\n== S359/9. REGRESSION: NO DELEGATES MEANS BYTE-IDENTICAL OUTPUT ==\n'
# ==========================================================================
# THE BASELINE IS A WHOLE SKILLS TREE, not a lone copied script (S354/2's
# pattern). `ech.sh` resolves its siblings — `captain-steps.py` among them —
# relative to its own path, so a baseline script dropped into a temp dir alone
# fails on a path error and the comparison would be of two different faults.
#
# AND IT IS THIS SESSION'S OWN PARENT, NOT `main`, FOR A STATED REASON. `main`
# would be the stronger claim and it is the one tests/delegation.test.sh makes,
# but S358 fix round 2 — THREE COMMITS BEFORE THIS ONE, on this same branch —
# deliberately appended the part name to every `PLAYBOOK:` line (`(lcars-eeh
# docs ech-intake)`). Measured here: `next` and `status` therefore differ from
# `main` on purpose, and pinning them to `main` would RED on somebody else's
# intended change and teach the next session to delete this guard. `stalled`
# below is still held to `main` as well, which is the claim this lane's own
# regression needs. The sha is the commit `fix/trusted-claim` carried before
# S359 touched it.
S359_PARENT='c539f54'
BASE9="$TMPROOT/baseline"
if mkdir -p "$BASE9" && cp -R "$REPO_ROOT/skills" "$BASE9/skills" \
  && git -C "$REPO_ROOT" show "$S359_PARENT:skills/lcars-eeh/ech.sh" >"$BASE9/skills/lcars-eeh/ech.sh" 2>/dev/null \
  && mkdir -p "$TMPROOT/base-main" && cp -R "$REPO_ROOT/skills" "$TMPROOT/base-main/skills" \
  && git -C "$REPO_ROOT" show main:skills/lcars-eeh/ech.sh >"$TMPROOT/base-main/skills/lcars-eeh/ech.sh" 2>/dev/null; then
  base9sh="$BASE9/skills/lcars-eeh/ech.sh"
  r9="$(new_repo)"; ap_init "$r9"; new_mission "$r9" quiet implement
  for verb in stalled next; do
    now9="$(ech "$r9" $verb 2>&1; printf 'EXIT=%s' "$?")"
    base9="$(ech_at "$base9sh" "$r9" $verb 2>&1; printf 'EXIT=%s' "$?")"
    now9="$(printf '%s' "$now9" | sed -e "s|$BASE9|@ROOT@|g" -e "s|$REPO_ROOT|@ROOT@|g" -e 's/[0-9]\{10\}/@EPOCH@/g')"
    base9="$(printf '%s' "$base9" | sed -e "s|$BASE9|@ROOT@|g" -e "s|$REPO_ROOT|@ROOT@|g" -e 's/[0-9]\{10\}/@EPOCH@/g')"
    check "S359/9 NO delegates: \`$verb\` stdout+stderr+exit byte-identical to BEFORE S359" \
      "[ \"\$now9\" = \"\$base9\" ]"
    [ "$now9" = "$base9" ] || printf '       --- base ---\n%s\n       --- now ---\n%s\n' "$base9" "$now9"
  done
  # AND `stalled` — THE VERB THIS SESSION ACTUALLY TOUCHED — IS HELD TO SHIPPED
  # `main` AS WELL. That is the claim the brief asks for, and it is the one a
  # delegate-free repo can still make: with nothing to measure, every word of
  # the mission report is the shipped one.
  now9m="$(ech "$r9" stalled 2>&1; printf 'EXIT=%s' "$?")"
  base9m="$(ech_at "$TMPROOT/base-main/skills/lcars-eeh/ech.sh" "$r9" stalled 2>&1; printf 'EXIT=%s' "$?")"
  check "S359/9 NO delegates: \`stalled\` is byte-identical to shipped \`main\` too" \
    "[ \"\$now9m\" = \"\$base9m\" ]"
  [ "$now9m" = "$base9m" ] || printf '       --- main ---\n%s\n       --- now ---\n%s\n' "$base9m" "$now9m"
  # `status` is compared UNFILTERED against the parent: S350's two extra lines
  # (`tiers:` / `delegates:`) are on BOTH sides of this comparison, so filtering
  # one side would be the only thing that could make it pass.
  now9s="$(ech "$r9" status 2>&1; printf 'EXIT=%s' "$?")"
  base9s="$(ech_at "$base9sh" "$r9" status 2>&1; printf 'EXIT=%s' "$?")"
  now9s="$(printf '%s' "$now9s" | sed -e "s|$BASE9|@ROOT@|g" -e "s|$REPO_ROOT|@ROOT@|g")"
  base9s="$(printf '%s' "$base9s" | sed -e "s|$BASE9|@ROOT@|g" -e "s|$REPO_ROOT|@ROOT@|g")"
  check "S359/9 NO delegates: \`status\` stdout+stderr+exit byte-identical to BEFORE S359" \
    "[ \"\$now9s\" = \"\$base9s\" ]"
  [ "$now9s" = "$base9s" ] || printf '       --- base ---\n%s\n       --- now ---\n%s\n' "$base9s" "$now9s"
  ech "$r9" status >"$TMPROOT/s9.status" 2>&1
  check "S359/9 ...and those two lines still say 'none' rather than inventing a circle" \
    "grep -qi 'delegates: none' '$TMPROOT/s9.status'"
  # AND WITH THE NEW LIMIT SET, which nothing in a delegate-free repo reads.
  now9b="$(circ_limit 7 "$r9" stalled 2>&1; printf 'EXIT=%s' "$?")"
  base9b="$(ech_at "$base9sh" "$r9" stalled 2>&1; printf 'EXIT=%s' "$?")"
  check "S359/9 NO delegates: setting LCARS_ECH_CIRCLE_BEATS changes nothing at all" \
    "[ \"\$now9b\" = \"\$base9b\" ]"
else
  bad "S359/9 no baseline driver (git show of the parent / main ech.sh failed)"
fi

# ==========================================================================
printf '\n== S359/10. THE FOURTH-READER RULE STILL HOLDS ==\n'
# ==========================================================================
# The row contract from S352 fix round 2: every reader binds every column the
# producer emits, plus a visible remainder. The guard itself lives in
# tests/delegation.test.sh; it is EXTRACTED here so this suite proves the
# contract without running that suite.
guard9="$TMPROOT/rowguard.py"
awk '$0 == "cat >\"$ROWGUARD\" <<\047ROWGUARD_PY\047" {on=1; next}
     on && $0 == "ROWGUARD_PY" {exit}
     on {print}' "$DIR/delegation.test.sh" >"$guard9"
check "S359/10 [control] the shared row guard was really extracted" "[ -s '$guard9' ]"
out9="$(python3 "$guard9" "$SCRIPT" 2>&1)"; rc=$?
printf '%s\n' "$out9" | sed 's/^/       /'
check "S359/10 PROBLEMS=0 at 20 columns and FOUR readers" \
  "[ $rc -eq 0 ] && [ \"\$out9\" = 'COLS=20 READERS=4 PROBLEMS=0' ]"
sed "s/^\(DELEGATE_ROW_COLS='[^']*\)'/\1 forgotten'/" "$SCRIPT" >"$TMPROOT/extra-column.sh"
out9b="$(python3 "$guard9" "$TMPROOT/extra-column.sh" 2>&1)"; rc=$?
check "S359/10 a 21st column with no reader widened still FAILS the guard" \
  "[ $rc -ne 0 ] && printf '%s' \"\$out9b\" | grep -q 'COLS=21 READERS=4 PROBLEMS=4'"
for v10 in stalled 'next --all' status; do
  ech "$r1" $v10 >/dev/null 2>>"$TMPROOT/s10.err"
done
check "S359/10 no reader complains of column drift at runtime (stalled, next, status)" \
  "! grep -qi 'DELEGATE_ROW_COLS' '$TMPROOT/s10.err'"

# ==========================================================================
printf '\n== S359/11. THE RULE IS PUBLISHED WHERE A DELEGATE AND THE ECH READ IT ==\n'
# ==========================================================================
check "S359/11 DELEGATION.md names the lane" \
  "grep -q 'GOING IN CIRCLES' '$REPO_ROOT/skills/lcars-eeh/DELEGATION.md'"
check "S359/11 ...and it says the signature keys on THE WORK, not the step number" \
  "python3 - '$REPO_ROOT/skills/lcars-eeh/DELEGATION.md' <<'PY'
import sys
s = open(sys.argv[1]).read()
sec = s.split('## NO SILENT HOURS', 1)[1].split('\n## ', 1)[0]
assert 'GOING IN CIRCLES' in sec, 'the lane must live in NO SILENT HOURS'
assert 'LCARS_ECH_CIRCLE_BEATS' in sec
assert 'reword' in sec.lower(), 'the blind spot must be stated'
PY"
ech "$r1" --help >"$TMPROOT/s11.help" 2>&1
check "S359/11 the help advertises the override" \
  "grep -q 'LCARS_ECH_CIRCLE_BEATS' '$TMPROOT/s11.help'"
check "S359/11 HOLOGRAM-COMMAND-MODE.md is UNTOUCHED by this session" \
  "git -C '$REPO_ROOT' diff --exit-code HEAD -- skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"

# ==========================================================================
printf '\n== S359/13. A LOOP THAT RECOVERS IS NO LONGER ACCUSED ==\n'
# ==========================================================================
# S359 FIX ROUND 1, DEFECT 2. The committed report STATED two clearing
# conditions in its own words — "a beat describing DIFFERENT work ... or an
# advancing `--step K/N`" — and the suite asserted only that it PRINTED that
# sentence. Neither condition worked: the running maximum `c_count` only ever
# increased, so an accusation latched for the delegate's whole life. Prose
# tested, mechanism untested. These assertions test the MECHANISM.
# THE KNOWN-FAIL CONTROL FOR THIS WHOLE FIX ROUND is the lane AS FIRST
# COMMITTED, and it is NOT `$S359_PARENT`. Measured: pointing these controls at
# the parent made them fail, because that commit predates the lane entirely and
# reports no circle for ANY fixture — it would have "passed" a control it never
# ran, which is the exact shape of a green that proves nothing. The sha is
# pinned the way $S359_PARENT is, because HEAD moves the moment this fix is
# committed and a control that tracks HEAD silently becomes a control OF THE
# CURE instead of of the defect.
S359_FIRST_CUT='f172cf1'
BUG13="$TMPROOT/first-cut"
BUG13SH="$BUG13/skills/lcars-eeh/ech.sh"
mkdir -p "$BUG13" && cp -R "$REPO_ROOT/skills" "$BUG13/skills" \
  && git -C "$REPO_ROOT" show "$S359_FIRST_CUT:skills/lcars-eeh/ech.sh" >"$BUG13SH" 2>/dev/null
check "S359/13 [control] the baseline really IS the lane as first committed, defect and all" \
  "[ -s '$BUG13SH' ] && grep -qF 'circ, c_high, c_count, c_line = {}, None, 0, \"\"' '$BUG13SH'"

r13="$(circ_loop_repo)"
ech "$r13" stalled >"$TMPROOT/s13a.out" 2>/dev/null
check "S359/13 [control] the planted loop IS accused before anything recovers" \
  "grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s13a.out'"
# CLEARING CONDITION 1, verbatim from the report: a beat describing DIFFERENT work.
ech "$r13" beat d1 'found it — the out-of-scope file was a stale symlink; removed it' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r13" stalled >"$TMPROOT/s13b.out" 2>/dev/null
check "S359/13 a beat describing DIFFERENT work CLEARS the line, as the report promises" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s13b.out'"
# CLEARING CONDITION 2: an advancing --step starts a fresh run. Isolated from
# condition 1 on purpose — the LINE here is the unchanged loop line, so only the
# step advance can clear it.
r13b="$(circ_loop_repo)"
ech "$r13b" beat d1 "$LOOP_LINE" --step 5/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r13b" stalled >"$TMPROOT/s13c.out" 2>/dev/null
check "S359/13 an ADVANCING step starts a fresh run even when the line is unchanged" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s13c.out'"
# AND THE FULL RECOVERY: a real loop, then the delegate works its way out
# through DISTINCT work at climbing steps. The latched report named step 7/7 and
# quoted a line that was never reported at step 7/7.
r13c="$(circ_loop_repo)"
ech "$r13c" beat d1 'dropped the stale file from the scope list'      --step 5/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r13c" beat d1 'scope gate GREEN; running the flip-flop gate'    --step 6/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r13c" beat d1 'flip-flop green on tip, red on parent; writing the hand-back' --step 7/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r13c" stalled >"$TMPROOT/s13d.out" 2>/dev/null
check "S359/13 a delegate that WORKED ITS WAY OUT is not still accused at step 7/7" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s13d.out'"
check "S359/13 ...and the stale loop line is not quoted at a step it never happened at" \
  "! grep -qF '$LOOP_LINE' '$TMPROOT/s13d.out'"
check "S359/13 [known-fail control] the PARENT script still latches the same fixture" \
  "ech_at '$BUG13SH' '$r13c' stalled 2>/dev/null >'$TMPROOT/s13e.out' ; grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s13e.out'"

# ==========================================================================
printf '\n== S359/14. DISTINCT WORK BETWEEN REPEATS IS NOT A CIRCLE ==\n'
# ==========================================================================
# S359 FIX ROUND 1, DEFECT 3. The tally was a dict over the WHOLE run, so the
# repeats never had to be CONSECUTIVE. A delegate interleaving real progress
# with a recurring status line was accused — while the line printed above it
# asserted "nothing in its own account of it has changed", which was false.
r14="$(circ_repo)"
ech "$r14" beat d1 'waiting on the suite'                  --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r14" beat d1 't-001 green, 3 files changed'          --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r14" beat d1 'waiting on the suite'                  --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r14" beat d1 't-002 tests written, red as expected'  --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r14" beat d1 'waiting on the suite'                  --step 4/7 >>"$TMPROOT/beat.log" 2>&1
ech "$r14" stalled >"$TMPROOT/s14.out" 2>/dev/null; rc=$?
check "S359/14 real progress BETWEEN the repeats is not a circle (they must be consecutive)" \
  "[ $rc -eq 0 ] && ! grep -q 'GOING IN CIRCLES' '$TMPROOT/s14.out'"
check "S359/14 [control] the delegate is still VISIBLE — the motion lane fires on it" \
  "grep -q '^NOT-MOVING DELEGATE: d1' '$TMPROOT/s14.out'"
check "S359/14 [known-fail control] the PARENT script accused this working delegate" \
  "ech_at '$BUG13SH' '$r14' stalled 2>/dev/null >'$TMPROOT/s14b.out' ; grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s14b.out'"
# AND WITH NO `--step` AT ALL — the documented default for every caller minted
# before S354. With no step there is no run window, so the delegate's whole
# lifetime was one run and an interleaved status line was accused.
r14c="$(circ_repo)"
ech "$r14c" beat d1 'waiting on the suite'            >>"$TMPROOT/beat.log" 2>&1
ech "$r14c" beat d1 'rewrote the fixture loader'      >>"$TMPROOT/beat.log" 2>&1
ech "$r14c" beat d1 'waiting on the suite'            >>"$TMPROOT/beat.log" 2>&1
ech "$r14c" beat d1 'loader green; onto the gate'     >>"$TMPROOT/beat.log" 2>&1
ech "$r14c" beat d1 'waiting on the suite'            >>"$TMPROOT/beat.log" 2>&1
ech "$r14c" stalled >"$TMPROOT/s14c.out" 2>/dev/null
check "S359/14 a delegate reporting NO step is judged on consecutive repeats too" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s14c.out'"
check "S359/14 [control] three CONSECUTIVE identical beats with no step ARE still caught" \
  "r14d=\"\$(circ_repo)\"; for i in 1 2 3; do ech \"\$r14d\" beat d1 'waiting on the suite' >/dev/null 2>&1; done; ech \"\$r14d\" stalled >'$TMPROOT/s14d.out' 2>/dev/null; grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s14d.out'"

# ==========================================================================
printf '\n== S359/15. THE BRIEF CARRIES THE LANE, AND STOPS MANUFACTURING IT ==\n'
# ==========================================================================
# S359 FIX ROUND 1, DEFECT 1. The product MANUFACTURED the false positive: the
# brief's runnable beat example was `"completed step $K of $N"` — a PURE
# FUNCTION of K and N — directly above the instruction "Repeat the current step
# if it is still running". Obeying the brief literally produced three identical
# lines and an accusation. And the rendered brief mentioned this lane ZERO
# times, while carrying {{BEAT_LIMIT}} twice for the silence lane, breaking
# DELEGATION.md's own rule that the brief states the limit it is held to.
TPL15="$REPO_ROOT/skills/lcars-eeh/delegate-brief.md"
git -C "$REPO_ROOT" show "$S359_PARENT:skills/lcars-eeh/delegate-brief.md" >"$TMPROOT/tpl-parent.md" 2>/dev/null
check "S359/15 [known-fail control] the PARENT template never mentioned the lane" \
  "[ -s '$TMPROOT/tpl-parent.md' ] && ! grep -qi 'circle' '$TMPROOT/tpl-parent.md'"
check "S359/15 the template now carries the lane's own slot, as it does the beat limit" \
  "grep -q '{{CIRCLE_LIMIT}}' '$TPL15'"
# THE EXAMPLE MUST NOT BE A PURE FUNCTION OF K AND N. The capstone's real
# surviving beat shape is "step 2 of 7 running: <what changed>".
cat >"$TMPROOT/purefn.py" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
sec = src.split('### And while you work: BEAT', 1)[1].split('## 3.', 1)[0]
cmds = [l for l in sec.splitlines() if l.startswith('    ') and ' beat ' in l]
assert len(cmds) == 1, cmds
msg = re.search(r'beat \{\{DELEGATE_ID\}\} "([^"]*)"', cmds[0])
assert msg, cmds[0]
vars_ = set(re.findall(r'\$\{?([A-Za-z_][A-Za-z0-9_]*)', msg.group(1)))
print("MSGVARS=" + ",".join(sorted(vars_)))
sys.exit(0 if vars_ - {"K", "N"} else 1)
PY
check "S359/15 [known-fail control] the PARENT example WAS a pure function of K and N" \
  "! python3 '$TMPROOT/purefn.py' '$TMPROOT/tpl-parent.md' >'$TMPROOT/purefn-parent.out' 2>&1"
check "S359/15 the example now carries WHAT CHANGED, not only the two numbers" \
  "python3 '$TMPROOT/purefn.py' '$TPL15' >'$TMPROOT/purefn-now.out' 2>&1"
check "S359/15 line 153's instruction is KEPT — repeating a step is correct behaviour" \
  "grep -q 'do not invent an advance to quiet the watchdog' '$TPL15'"
# AND THE RENDERED BRIEF SAYS IT, with the limit ACTUALLY APPLIED.
r15="$(circ_repo)"
B15="$r15/.git/lcars/delegates/d1/BRIEF.md"
check "S359/15 [control] the brief really rendered" "[ -s '$B15' ]"
check "S359/15 the rendered brief NAMES the lane it is held to" \
  "grep -q 'GOING IN CIRCLES' '$B15'"
check "S359/15 ...and states the threshold, so the obligation travels with the hand-off" \
  "grep -q '3 times running' '$B15' && grep -q 'LCARS_ECH_CIRCLE_BEATS' '$B15'"
check "S359/15 no unfilled template token survives the new slot" \
  "! grep -q '{{' '$B15'"
# A BRIEF MINTED UNDER AN OVERRIDE STATES THE FIGURE IT WAS MINTED UNDER —
# BEAT_LIMIT's contract, applied to this lane.
r15b="$(new_repo)"; ap_init "$r15b"; new_mission "$r15b" progress implement
( export LCARS_ECH_CIRCLE_BEATS=5
  ech "$r15b" tier progress --tier T1 --why "one bounded unit"
  ech "$r15b" delegate progress ) >>"$TMPROOT/mint.log" 2>&1
B15B="$r15b/.git/lcars/delegates/d1/BRIEF.md"
check "S359/15 a brief minted under an override states THAT figure, never the default" \
  "grep -q '5 times running' '$B15B' && ! grep -q '3 times running' '$B15B'"
# AND S354/10'S CONTRACT STILL HOLDS: the example RUNS AS IT STANDS. Held here
# so this suite proves it without running tests/delegation.test.sh (~57 min).
python3 - "$B15" "$TMPROOT/brief-beat15.sh" <<'PY'
import sys
s = open(sys.argv[1]).read().split('### And while you work: BEAT', 1)[1].split('## 3.', 1)[0]
open(sys.argv[2], 'w').write('\n'.join(l[4:] for l in s.splitlines() if l.startswith('    ')) + '\n')
PY
( cd "$r15" && bash "$TMPROOT/brief-beat15.sh" ) >"$TMPROOT/brief-cmd15.log" 2>&1; rc=$?
check "S359/15 the rendered beat example STILL RUNS AS IT STANDS and records step 1/7" \
  "[ $rc -eq 0 ] && python3 -c \"import json;d=json.load(open('$r15/.git/lcars/autopilot.json'))['delegates']['d1']['step'];assert (d['k'],d['n'])==(1,7),d\""

# ==========================================================================
printf '\n== S359/16. THE PRECISION IT GAINED COST SENSITIVITY, AND IT SAYS SO ==\n'
# ==========================================================================
# S359 FIX ROUND 2, AND IT IS AN HONESTY FIX, NOT A MECHANISM ONE. Fix round 1
# required a circle's repeats to be CONSECUTIVE. That cured three false
# positives and it holds — but it bought precision with SENSITIVITY, and the
# product did not say so. MEASURED by a fresh tester: a perfect two-beat cycle
# ("ran the scope gate: FAIL" / "reverting and trying the same fix again") run
# FOUR times round scores circles=0. So the lane can now only see a cycle of
# length ONE, and every realistic loop in this factory — gate red → revert →
# retry, research → plan → research → plan — alternates between two or more
# reports and is invisible to it. The tester grepped DELEGATION.md, ech.sh and
# delegate-brief.md for any statement of that limit: NO MATCHES. This project's
# own rule is that a lane states its limit WHERE IT REPORTS — the rewording
# limit already does exactly that — because a quiet lane a reader believes is
# exhaustive is itself a false green. The consecutive rule is NOT changed here;
# only what the product says about it.
S359_R1='9ff5476'
R1DIR="$TMPROOT/round1"
R1SH="$R1DIR/skills/lcars-eeh/ech.sh"
R1DOC="$TMPROOT/round1-DELEGATION.md"
mkdir -p "$R1DIR" && cp -R "$REPO_ROOT/skills" "$R1DIR/skills" \
  && git -C "$REPO_ROOT" show "$S359_R1:skills/lcars-eeh/ech.sh" >"$R1SH" 2>/dev/null
git -C "$REPO_ROOT" show "$S359_R1:skills/lcars-eeh/DELEGATION.md" >"$R1DOC" 2>/dev/null
check "S359/16 [control] the baseline IS fix round 1 — consecutive repeats, silent about it" \
  "[ -s '$R1SH' ] && grep -qF 'THE REPEATS MUST BE CONSECUTIVE' '$R1SH' && [ -s '$R1DOC' ]"

# --- (1) THE FOOTER, WHERE THE LANE ITSELF REPORTS -----------------------
r16="$(circ_loop_repo)"
ech "$r16" stalled >"$TMPROOT/s16a.out" 2>/dev/null
check "S359/16 the footer states the lane sees only CONSECUTIVE repetition" \
  "grep -qi 'consecutive' '$TMPROOT/s16a.out'"
check "S359/16 ...and names the shape it therefore cannot see: a loop that ALTERNATES" \
  "grep -qi 'alternat' '$TMPROOT/s16a.out'"
check "S359/16 ...and points at the lane that DOES still fire on that shape" \
  "grep -q 'BEATING BUT NOT MOVING' '$TMPROOT/s16a.out'"
check "S359/16 [known-fail control] fix round 1's own footer said none of it" \
  "ech_at '$R1SH' '$r16' stalled 2>/dev/null >'$TMPROOT/s16a-r1.out'; grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s16a-r1.out' && ! grep -qi 'consecutive' '$TMPROOT/s16a-r1.out' && ! grep -qi 'alternat' '$TMPROOT/s16a-r1.out'"

# --- (2) THE PUBLISHED DOC, BESIDE THE REWORDING LIMIT -------------------
check "S359/16 DELEGATION.md states the same limit beside the rewording one" \
  "python3 - '$REPO_ROOT/skills/lcars-eeh/DELEGATION.md' <<'PY'
import sys
s = open(sys.argv[1]).read()
sec = s.split('## NO SILENT HOURS', 1)[1].split('\n## ', 1)[0]
blind = sec.split('AND WHAT THIS LANE CANNOT CATCH', 1)[1].lower()
assert 'reword' in blind, 'the first blind spot must still be stated'
assert 'consecutive' in blind, 'the consecutive-only limit must be stated AS A LIMIT'
assert 'alternat' in blind, 'the alternating-loop shape must be named'
PY"
check "S359/16 [known-fail control] fix round 1's doc stated it in no blind spot of its own" \
  "! python3 - '$R1DOC' <<'PY'
import sys
s = open(sys.argv[1]).read()
blind = s.split('AND WHAT THIS LANE CANNOT CATCH', 1)[1].lower()
assert 'consecutive' in blind and 'alternat' in blind
PY"

# --- (3) THE BEHAVIOURAL ANCHOR: THE RUN WHERE THE LIMIT BITES -----------
# The tester's fixture, in its own shape: a perfect two-beat cycle, four times
# round, the step never advancing. This is the classic loop of this factory and
# the lane is silent on it.
r16b="$(circ_repo)"
for i16 in 1 2 3 4; do
  ech "$r16b" beat d1 'ran the scope gate: FAIL - src/other.py out of scope' --step 4/7 >>"$TMPROOT/beat.log" 2>&1
  ech "$r16b" beat d1 'reverting the change and trying the same fix again'   --step 4/7 >>"$TMPROOT/beat.log" 2>&1
done
ech "$r16b" stalled >"$TMPROOT/s16b.out" 2>/dev/null
sed 's/^/       /' "$TMPROOT/s16b.out"
check "S359/16 a two-beat cycle run four times is NOT named a circle — the blind spot, measured" \
  "! grep -q 'GOING IN CIRCLES' '$TMPROOT/s16b.out'"
check "S359/16 ...and the delegate is NOT invisible: the motion lane still names it" \
  "grep -q '^NOT-MOVING DELEGATE: d1' '$TMPROOT/s16b.out'"
# AND WHAT THAT MEANS FOR THE READER OF THIS RUN, PROVEN RATHER THAN ASSERTED.
# The footer carrying the limit is printed inside `cmd_stalled`'s `dc > 0`
# branch, so on THIS run — the one where the limit actually bites — the report
# does not carry it, and DELEGATION.md is the only surface that states it here.
# Recorded as a measured RESIDUAL and deliberately NOT pinned by an assertion:
# a later fix that makes the limit print on a SILENT lane must not have to
# delete a test to do it.
if grep -qi 'consecutive' "$TMPROOT/s16b.out"; then
  printf '  \033[33mNOTE\033[0m S359/16 the consecutive-only limit DOES print on a silent circles lane\n'
else
  printf '  \033[33mNOTE\033[0m S359/16 RESIDUAL: the limit is stated only where the lane FIRES; on this silent run the report does not carry it (DELEGATION.md does)\n'
fi

# --- (4) THE KNOWN-GOOD CONTROL: nothing the lane caught is given up -----
check "S359/16 [known-good] a real CONSECUTIVE loop still fires" \
  "grep -q '^GOING IN CIRCLES: d1' '$TMPROOT/s16a.out'"
check "S359/16 [known-good] ...still quotes its evidence in the delegate's own words" \
  "grep -qF '$LOOP_LINE' '$TMPROOT/s16a.out'"
check "S359/16 [known-good] ...and the pre-existing REWORDING limit is still stated" \
  "grep -qi 'REWORDING each beat is NOT caught' '$TMPROOT/s16a.out'"

# ==========================================================================
printf '\n== S359/12. ZERO WORKER SPEND ==\n'
# ==========================================================================
check "S359/12 no AI CLI was invoked by this suite (PATH shim log empty)" \
  "[ ! -s '$LCARS_DRIVE_SHIM_LOG' ]"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
