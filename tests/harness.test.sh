#!/usr/bin/env bash
#
# tests/harness.test.sh — a suite about the TEST HARNESS itself (S208).
#
# It asserts TERMINATION, not output. Since S140 a standing rule has said
# "scoped suites only — the full run has hung sessions". The cause was
# mechanical: every suite defined
#     qgrep() { local _qg_in; _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"; }
# whose bare `cat` has no stdin redirect, while ~94 call sites pass it a FILE.
# From a terminal that blocks forever; with stdin CLOSED `cat` returns empty and
# the assertion passes BY ACCIDENT. So:
#
#   * every probe here runs from a REAL PTY with stdin genuinely OPEN
#     (tests/lib/ptyrun.py). A `</dev/null` probe is the accident that
#     hid this bug for a year and proves nothing;
#   * every probe is caged in its OWN PROCESS GROUP and reports ELAPSED time
#     (tests/lib/cage.py), because `perl -e 'alarm N; exec @ARGV'` does
#     NOT reliably kill a bash blocked on a command substitution;
#   * and there is a PLANTED-HANG CONTROL. A detector that cannot catch a hang
#     it planted itself cannot catch a real one, and a green from it is worthless.
#
# Usage: bash tests/harness.test.sh
#
# ── RECORD: what is still not finished, and what is NOT this session's ──────
# Corrected in fix round 1. The first pass of this session reported FOUR suites
# as still not completing inside a cage after the cure. It is THREE:
#
#   * estimate, lcars-reconcile, lcars-run — still block even with stdin on
#     /dev/null, so they are NOT the stdin class this session cured. Localised
#     to `skills/lcars-run/run.sh estimate` reached via
#     `skills/lcars-file/file.sh --prd` with STUB_ESTIMATE=NONE, blocking before
#     any worker is spawned. That is a THIRD, separate mechanism and S209's
#     headline; it is deliberately not chased here.
#   * lcars-file was WRONG and is withdrawn. It FINISHES: 105.6s, exit 0, last
#     check 19o passing, confirmed on re-run. It was mistaken for unfinished
#     because it prints NO pass/fail summary line at all, while every other
#     suite ends with "<name>: N passed, M failed" or "ALL PASS". That missing
#     summary is a real, PRE-EXISTING defect — ledgered, not fixed here, and
#     deliberately not papered over by adding a line to lcars-file.test.sh.
#
# Also ledgered, NOT caused by S208 and NOT fixed here:
#   * tests/lcars-status.test.sh leaks 4 orphan `status.sh --watch` daemons per
#     run. Reproduced on the PRE-fix tree (a980c94) as well as the cured one, so
#     it is pre-existing. It is newly CONSEQUENTIAL only because suites now
#     actually complete, so every full run adds four more.
#   * Pre-existing red assertions, unrelated to the hang class: base-freshness
#     (30, 45), worker-resolve (5f, 5i), lcars-pause (2b), lcars.test.sh (1, 8),
#     estimate (5a, 5b).
#
# RIGGING TRAP, for whoever extends the probes below: cage.py plus a
# pipe-writing child needs an ON-DISK completion marker. A `sleep` that
# inherits the cage's stdout pipe keeps that pipe open, communicate() never
# sees EOF, and you get a PHANTOM hang that is an artefact of the rig.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAGE="$DIR/lib/cage.py"
PTY="$DIR/lib/ptyrun.py"

# Generous, so a merely SLOW suite never reads as a hang. A blocked read never
# returns at all, so any bound distinguishes the two; this one is a bound on
# patience, not on speed.
HANG_SECS="${LCARS_HARNESS_HANG_SECS:-120}"
# The planted hang is instantaneous-or-never, so it gets a short leash.
CTRL_SECS="${LCARS_HARNESS_CTRL_SECS:-12}"

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# run_pty SECS CMD... -> stdout is the cage's report; the FIRST line is
#   "ELAPSED <n>s EXIT <code>"  or  "ELAPSED <n>s *** TIMED OUT — exceeded ...".
run_pty() { local s="$1"; shift; python3 "$CAGE" "$s" python3 "$PTY" "$@" 2>&1; }
elapsed() { sed -n '1s/^ELAPSED \([0-9.]*\)s.*/\1/p' <<<"$1"; }
# The cage reports a TIMEOUT, which is all it can observe; these probes plant a
# genuine block, so for THEM a timeout is a hang. The naming keeps that
# interpretation here, in the test that earned it, and out of the instrument.
timed_out() { grep -q 'TIMED OUT' <<<"$1"; }

echo "harness (S208): every probe from a pty, stdin OPEN, caged by process group"
echo

# --- 0. The rigging exists -------------------------------------------------
check "0a. process-group cage is present (S197)" "[ -f '$CAGE' ]"
check "0b. pty runner is present" "[ -f '$PTY' ]"

# --- 1. PLANTED-HANG CONTROL — the detector must catch a hang it planted ----
# This is check 1 deliberately: nothing below it means anything if this fails.
cat >"$TMPROOT/planted-hang.test.sh" <<'EOF'
#!/usr/bin/env bash
# Deliberately blocking suite: the exact shape S208 cured, reading inherited stdin.
set -uo pipefail
echo "planted: about to read inherited stdin"
blob="$(cat)"
echo "planted: NEVER REACHED from an open stdin ($blob)"
EOF
ctrl_out="$(run_pty "$CTRL_SECS" bash "$TMPROOT/planted-hang.test.sh")"
ctrl_el="$(elapsed "$ctrl_out")"
echo "  [control] planted hang, pty, stdin open: ELAPSED ${ctrl_el}s"
check "1a. CONTROL: the planted hang IS caught by this detector" \
  "timed_out \"\$ctrl_out\""
# ...and the same planted suite with stdin CLOSED does NOT hang. That asymmetry
# is the whole bug: a </dev/null run is blind to it.
ctrl_dn="$(python3 "$CAGE" "$CTRL_SECS" bash "$TMPROOT/planted-hang.test.sh" 2>&1)"
echo "  [control] planted hang, stdin CLOSED: $(sed -n 1p <<<"$ctrl_dn")"
check "1b. CONTROL: stdin CLOSED hides the same hang (why </dev/null proves nothing)" \
  "! timed_out \"\$ctrl_dn\""

# --- 2. Real suites terminate from a pty with stdin OPEN -------------------
# lcars-pause and lcars-buddy were MEASURED hanging from a pty before the cure
# (30.0s and 25.0s, both killed by the cage; 5.6s and 5.9s after). run-runner is
# a fast canary. Check 2 asserts TERMINATION only — lcars-pause has a red
# assertion of its own, ledgered, and that is not this suite's business.
for s in lcars-pause lcars-buddy run-runner; do
  [ -f "$DIR/$s.test.sh" ] || { bad "2. $s.test.sh missing"; continue; }
  out="$(run_pty "$HANG_SECS" bash "$DIR/$s.test.sh")"
  el="$(elapsed "$out")"
  echo "  [probe] $s.test.sh from a pty, stdin open: ELAPSED ${el}s"
  check "2. $s.test.sh TERMINATES from a pty with stdin open" "! timed_out \"\$out\""
done

# --- 3. run.sh does not stall on a blocking suite --------------------------
# A seeded directory: one suite that passes, one that deliberately blocks.
seed="$TMPROOT/seeded"; mkdir -p "$seed"
cp "$TMPROOT/planted-hang.test.sh" "$seed/zz-blocking.test.sh"
cat >"$seed/aa-trivial.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "trivial: 1 passed, 0 failed"
EOF
run_out="$(run_pty "$HANG_SECS" bash "$DIR/run.sh" "$seed")"
run_el="$(elapsed "$run_out")"
echo "  [probe] run.sh over a seeded dir with a BLOCKING suite: ELAPSED ${run_el}s"
check "3a. run.sh over a blocking suite TERMINATES (does not stall the gate)" \
  "! timed_out \"\$run_out\""
check "3b. run.sh still ran the other suite in that directory" \
  "grep -q 'trivial: 1 passed' <<<\"\$run_out\""
check "3c. run.sh's \$1 target-directory resolution is unchanged (BUG-009)" \
  "grep -q 'TESTS_DIR=\"\$1\"' '$DIR/run.sh'"
check "3d. run.sh honours \$LCARS_TESTS_DIR (BUG-009)" \
  "grep -q 'TESTS_DIR=\"\$LCARS_TESTS_DIR\"' '$DIR/run.sh'"

# --- 4. The class cannot return in file #23 --------------------------------
# A `cat` with no file operand and no `<` redirect reads INHERITED stdin. The
# scanner skips comments and heredoc BODIES (a `gh` stub reading `$(cat)` for
# `--field body=@-` is reading a real pipe, correctly) and allows exactly one
# line: the cured qgrep's drain, reached only when no FILE operand was passed.
GUARD="$DIR/lib/stdin_guard.py"
guard_out="$(python3 "$GUARD" "$DIR"/*.test.sh 2>&1)"; guard_rc=$?
[ -n "$guard_out" ] && printf '%s\n' "$guard_out" | sed 's/^/    /'
check "4a. no *.test.sh reads inherited stdin via an unguarded cat" "[ $guard_rc -eq 0 ]"
check "4b. run.sh invokes every suite with stdin closed" \
  "grep -q 'bash \"\$t\" </dev/null' '$DIR/run.sh'"
# ...and the guard has a control too: a planted offender MUST be caught.
cp "$TMPROOT/planted-hang.test.sh" "$TMPROOT/guard-control.test.sh"
python3 "$GUARD" "$TMPROOT/guard-control.test.sh" >/dev/null 2>&1; guard_ctrl=$?
check "4c. CONTROL: the guard DOES catch a planted unguarded cat" "[ $guard_ctrl -ne 0 ]"

# --- 5. The cure did not drift in ANY suite that carries the helper --------
# SELF-SCALING BY CONSTRUCTION. The set under guard is discovered at run time:
# every tests/*.test.sh whose text DEFINES `qgrep` at column 0. A 23rd suite
# adopting the helper is therefore covered the day it lands — there is no
# hardcoded floor to fall behind.
#
# Each definer must be in exactly ONE of two shapes:
#   * the CURED helper — its body carries BOTH canonical lines byte-for-byte
#     (the operand guard, and the drain reached only when no FILE was passed);
#   * a pure FILE-FORM helper — its body contains no `cat` at all, so it cannot
#     read inherited stdin. tests/lcars-resolve-logs.test.sh is one today: its
#     qgrep is `grep -E "$1" "$2"`, pattern-and-file only, and every call site
#     passes both. That shape predates S208 and is not the hang class.
# Anything else — a body that drains stdin through a `cat` that is NOT the
# canon — is drift, and check 5a NAMES the file.
#
# Why this replaced what was here: the old 5a/5b were TAUTOLOGICAL and could
# never fail. They ran `grep -hxF "$CANON" tests/*.test.sh | sort -u | wc -l`
# and asserted the answer was 1 — but `grep -xF` only ever emits lines EQUAL to
# $CANON, so the answer is 1 whenever ANY file matches, and a DRIFTED file
# simply stops being counted while the check stays green. Proven with a control,
# not deduced. The old 5c's `-ge 22` was the same failure in another costume: a
# hardcoded floor that a 23rd drifted suite walks straight past.
CANON_CAT='  _qg_in="$(cat)"; grep "$@" <<<"$_qg_in"'
CANON_GUARD='  if [ "$_qg_n" -ge 2 ]; then grep "$@"; return; fi'

# qgrep_body FILE -> the definition's lines, from `qgrep() {` to its closing `}`.
qgrep_body() { awk '/^qgrep\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$1"; }

n_def=0; n_cured=0; n_form=0; drift_list=""; pair_list=""
for f in "$DIR"/*.test.sh; do
  grep -q '^qgrep() {' "$f" || continue
  n_def=$((n_def + 1))
  body="$(qgrep_body "$f")"
  has_cat=0;  grep -qxF "$CANON_CAT"   <<<"$body" && has_cat=1
  has_grd=0;  grep -qxF "$CANON_GUARD" <<<"$body" && has_grd=1
  if [ "$has_cat" = 1 ] && [ "$has_grd" = 1 ]; then
    n_cured=$((n_cured + 1))
  elif ! grep -q 'cat' <<<"$body"; then
    n_form=$((n_form + 1))
  else
    drift_list="$drift_list $(basename "$f")"
  fi
  # Half-cured is drift too, and is reported separately so the diagnosis is
  # "this file lost ONE of the pair" rather than a bare count mismatch.
  [ "$has_cat" = "$has_grd" ] || pair_list="$pair_list $(basename "$f")"
done
echo "  [drift] qgrep defined in $n_def suites: $n_cured cured, $n_form file-form, $(set -- $drift_list; echo $#) drifted"
[ -n "$drift_list" ] && echo "    DRIFTED:$drift_list"
[ -n "$pair_list" ]  && echo "    HALF-CURED (drain/guard mismatch):$pair_list"
check "5a. every suite defining qgrep carries the CANONICAL body, or is a pure file-form helper" \
  "[ -z \"\$drift_list\" ]"
check "5b. no suite carries one half of the cured pair without the other" \
  "[ -z \"\$pair_list\" ]"
check "5c. the guard is not vacuous: the cured helper is present, and every definer is accounted for" \
  "[ \"\$n_cured\" -gt 0 ] && [ \$((n_cured + n_form)) -eq \"\$n_def\" ]"
echo
# ==========================================================================
# PART 6 — THE CAGE'S OWN CONTRACT (S244).
#
# cage.py is the harness's ONLY safety device: every unattended suite is run
# through it. Two defects in it are why "the full suite is the merge gate and
# nobody has ever completed a run" stayed a mystery for a year.
#
# 6a THE CAGE DESTROYS THE EVIDENCE. It buffers the caged process's output in
#    `communicate()` and prints it only on a CLEAN exit. On the timeout path it
#    raises TimeoutExpired, the buffered bytes are dropped on the floor, and all
#    the operator is handed is "TIMED OUT -> HUNG". So the one run that most
#    needs a diagnosis is the one run that produces none — you cannot see WHICH
#    assertion it stopped after, which is the only fact that tells a HANG from a
#    merely SLOW suite. Three suites were recorded as hung on this evidence and
#    all three were simply long.
#
# 6b THE CAGE ORPHANS ITS CHILD WHEN IT IS ITSELF KILLED. It spawns with
#    start_new_session=True — deliberately, so the timeout path can killpg the
#    whole tree — but that also puts the child in a session NOTHING ELSE KNOWS
#    ABOUT. cage.py installs no signal handler, so if cage.py is killed before
#    its own timeout fires, it dies without reaping, and the caged suite runs on
#    for ever: ppid 1, its own process group, invisible to any group kill aimed
#    at the launcher. 26 such strays were reaped by hand, the oldest 28 hours
#    old. A cage that leaks the thing it was caging is not a cage.
# ==========================================================================
printf '\n  -- 6: the cage keeps the evidence, and does not leak its child --\n'

# 6a. A command that TALKS and then hangs. Its words must survive the timeout.
cat >"$TMPROOT/noisy-hang.sh" <<'EOF'
#!/usr/bin/env bash
echo "MARKER-BEFORE-THE-HANG"
while :; do sleep 0.2; done
EOF
noisy="$(python3 "$CAGE" 4 bash "$TMPROOT/noisy-hang.sh" 2>&1)"
check "6a. a TIMED-OUT cage still prints what the caged process said before it stopped" \
  "grep -q 'MARKER-BEFORE-THE-HANG' <<<\"\$noisy\""
check "6a-control — the cage still reports the timeout itself" \
  "grep -q 'TIMED OUT' <<<\"\$noisy\""

# ---- 6c. THE CAGE MUST NOT STATE A CONCLUSION IT CANNOT SUPPORT ----------
# The old line read "*** TIMED OUT -> HUNG (group killed) ***". It says HUNG; it
# only knows TIMED OUT. From where the cage stands, "hung", "slow", "waiting on
# a lock" and "legitimately long" are indistinguishable — it observed exactly one
# fact: the child outlived the deadline. The inference cost real money: three
# suites (lcars-xo-observe, 240.6s/182 passed; lcars-xo-render-gate, 441.7s/38
# passed) were measured under a 150s cage, the cage ASSERTED "HUNG", the
# orchestrator believed the instrument, and all shipping was recorded as blocked
# on hangs that do not exist. A measuring instrument reports its measurement.
check "6c. the timeout line does NOT assert HUNG — the cage cannot know that" \
  "! grep -qi 'HUNG' <<<\"\$noisy\""
# The reader's next move is "was it slow, or stuck?". The cage must say that it
# cannot answer that, and point at the child's own output (preserved by 6a),
# which is where the answer actually is.
check "6c. …and it says the cage cannot tell SLOW from STUCK" \
  "grep -qi 'slow' <<<\"\$noisy\" && grep -qi 'stuck\|hang' <<<\"\$noisy\""

# ---- 6d. NAME THE DEADLINE, so a budget problem reads as a budget problem --
# A 150s cage on a 441s suite is a bad budget, not a bad product — but only if
# the line states the budget it exceeded. Two deadlines are probed so the check
# cannot pass on a hardcoded constant.
check "6d. the timeout line names the deadline it exceeded (4s)" \
  "grep -q '4s deadline' <<<\"\$noisy\""
noisy2="$(python3 "$CAGE" 2 bash "$TMPROOT/noisy-hang.sh" 2>&1)"
check "6d-control — a DIFFERENT cage reports ITS own deadline, not 4s" \
  "grep -q '2s deadline' <<<\"\$noisy2\" && ! grep -q '4s deadline' <<<\"\$noisy2\""

# ---- 6e. the machine-readable contract is untouched ----------------------
# Every consumer keys on a first line that starts "ELAPSED <n>s"; harness's own
# elapsed() reads it with `sed -n 1s`. Honesty must not cost the contract.
check "6e. the timeout line still starts with the parseable ELAPSED field" \
  "[ -n \"\$(elapsed \"\$noisy\")\" ]"

# 6b. Kill the CAGE, not the caged process, and see whether the child survives.
# The child records its own pid on disk so the roll call is against a FILE, never
# a live `ps | grep` (which matches its own command line and reports phantoms).
cat >"$TMPROOT/pidfile-hang.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$1"
while :; do sleep 0.2; done
EOF
victim_pidfile="$TMPROOT/caged.pid"
rm -f "$victim_pidfile"
python3 "$CAGE" 600 bash "$TMPROOT/pidfile-hang.sh" "$victim_pidfile" >/dev/null 2>&1 &
cage_pid=$!
# Wait for the child to announce itself, on disk.
cw=0; while [ "$cw" -lt 60 ] && [ ! -s "$victim_pidfile" ]; do cw=$((cw + 1)); sleep 0.1; done
caged_pid="$(cat "$victim_pidfile" 2>/dev/null || true)"
check "6b-control — the caged child really did start (the probe is not vacuous)" \
  "[ -n \"\$caged_pid\" ] && kill -0 \"\$caged_pid\" 2>/dev/null"
# SIGTERM the cage itself. This is the catchable case — what an orchestrator,
# a shell or a session teardown actually sends.
kill -TERM "$cage_pid" 2>/dev/null || true
wait "$cage_pid" 2>/dev/null || true
# Give the reap a moment to land.
rw=0; while [ "$rw" -lt 30 ] && kill -0 "$caged_pid" 2>/dev/null; do rw=$((rw + 1)); sleep 0.1; done
survived=0; kill -0 "$caged_pid" 2>/dev/null && survived=1
echo "  [orphan] cage pid $cage_pid TERMed; caged child $caged_pid survived=$survived"
check "6b. a cage killed before its timeout REAPS its caged child instead of orphaning it" \
  "[ \"\$survived\" -eq 0 ]"
# Leave no orphan from this probe either, whichever way the assertion went.
[ "$survived" -eq 1 ] && kill -KILL "$caged_pid" 2>/dev/null
echo
printf 'harness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
