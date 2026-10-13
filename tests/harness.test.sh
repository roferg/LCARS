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
cat >"$seed/bb-failing.test.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "failing: deliberate exit 7"
exit 7
EOF
run_out="$(run_pty "$HANG_SECS" bash "$DIR/run.sh" "$seed")"
run_clean="$(tr -d '\r' <<<"$run_out")"
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
check "3e. run.sh names each suite before it starts" \
  "grep -q '^SUITE aa-trivial.test.sh\$' <<<\"\$run_clean\" && grep -q '^SUITE bb-failing.test.sh\$' <<<\"\$run_clean\""
check "3f. run.sh reports elapsed time and the real exit status for each suite" \
  "grep -Eq '^RESULT aa-trivial.test.sh elapsed=[0-9]+s exit=0\$' <<<\"\$run_clean\" && grep -Eq '^RESULT bb-failing.test.sh elapsed=[0-9]+s exit=7\$' <<<\"\$run_clean\""
check "3g. run.sh summarizes suites run, suites failed and total elapsed time" \
  "grep -Eq '^SUITES run=3 failed=1 elapsed=[0-9]+s\$' <<<\"\$run_clean\""
full_gate_names="$(for f in "$DIR"/*.test.sh; do basename "$f"; done)"
check "3h. the full gate includes web-python.test.sh by name" \
  "grep -qx 'web-python.test.sh' <<<\"\$full_gate_names\""

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

# ---- 6f. THE CAGE TELLS A CALLER THE TRUTH, NOT ONLY A READER (S289) ------
# It printed `EXIT 7` and then exited 0 ITSELF. So `cage … && <next step>` read
# a RED suite as a pass, and unattended is exactly the context where nobody
# reads the printed line: an overnight chain structurally could not see a
# failure. It nearly fooled the 2026-10-11 orchestrator, which took a
# background job's exit 0 for the verdict when the verdict was only in the text.
# The cure is the PROCESS STATUS ONLY. The first line is a contract several
# readers parse (`sed -n 1p`), so every probe below asserts it byte-for-byte
# with the measured seconds — the one part that legitimately varies —
# normalised out. GOLD_* are transcripts of the pre-change output.
GOLD_FAIL='ELAPSED <n>s EXIT 7'
GOLD_PASS='ELAPSED <n>s EXIT 0'
GOLD_TIMEOUT='ELAPSED <n>s *** TIMED OUT — exceeded the 2s deadline (group killed). A timeout is not a verdict: this cage cannot tell SLOW from STUCK. If the deadline was the wrong budget, raise it; otherwise read the caged output below for where it stopped. ***'
# The seconds are the measurement; everything else is the contract.
contract_line() { sed -n '1s/^ELAPSED [0-9][0-9.]*s/ELAPSED <n>s/p' <<<"$1"; }

f_out="$(python3 "$CAGE" 30 bash -c 'echo CHILD-SPOKE-ON-FAILURE; exit 7' 2>&1)"; f_rc=$?
check "6f. a caged suite that FAILS exits the cage with the child's status (7)" \
  "[ \"\$f_rc\" -eq 7 ]"
check "6f-contract — …and its first line is byte-identical to the pre-change one" \
  "[ \"\$(contract_line \"\$f_out\")\" = \"\$GOLD_FAIL\" ]"
check "6f-control — the failing child's own output still follows the line" \
  "grep -q 'CHILD-SPOKE-ON-FAILURE' <<<\"\$f_out\""

p_out="$(python3 "$CAGE" 30 bash -c 'echo CHILD-SPOKE-ON-PASS; exit 0' 2>&1)"; p_rc=$?
check "6f. a caged suite that PASSES still exits 0 (the regression that matters most)" \
  "[ \"\$p_rc\" -eq 0 ]"
check "6f-contract — …and its first line is byte-identical to the pre-change one" \
  "[ \"\$(contract_line \"\$p_out\")\" = \"\$GOLD_PASS\" ]"
check "6f-control — the passing child's own output still follows the line" \
  "grep -q 'CHILD-SPOKE-ON-PASS' <<<\"\$p_out\""

# A TIMEOUT IS NOT A FAILING SUITE, and a caller must be able to tell them
# apart — that distinction is the whole point of the status change. 124 is
# timeout(1)'s convention.
cat >"$TMPROOT/talks-then-hangs.sh" <<'EOF'
#!/usr/bin/env bash
echo "MARKER-S289-BEFORE-THE-DEADLINE"
while :; do sleep 0.2; done
EOF
t_out="$(python3 "$CAGE" 2 bash "$TMPROOT/talks-then-hangs.sh" 2>&1)"; t_rc=$?
check "6f. a caged suite that OUTRUNS ITS DEADLINE exits 124, not 0 and not the child's" \
  "[ \"\$t_rc\" -eq 124 ]"
check "6f-contract — …and the TIMED OUT sentence is unchanged, word for word" \
  "[ \"\$(contract_line \"\$t_out\")\" = \"\$GOLD_TIMEOUT\" ]"
# S244's evidence-preservation fix must survive the status change: the status is
# the only thing that moves, and the one run that most needs a diagnosis is the
# one that produces it.
check "6f-control — S244 holds: a timed-out cage STILL prints what the child said" \
  "grep -q 'MARKER-S289-BEFORE-THE-DEADLINE' <<<\"\$t_out\""
# …and 124 as a STATUS is never ambiguous, because a child that exits 124 on its
# own says so on the line. Status plus line separates the two cases.
c124_out="$(python3 "$CAGE" 30 bash -c 'exit 124' 2>&1)"; c124_rc=$?
check "6f-control — a child that exits 124 ITSELF is still told apart by the line" \
  "[ \"\$c124_rc\" -eq 124 ] && grep -q 'EXIT 124' <<<\"\$c124_out\" && ! grep -q 'TIMED OUT' <<<\"\$c124_out\""

# THE CALLER-LEVEL PROOF, in the exact shape CLAUDE.md and ORCHESTRATION.md tell
# every unattended run to use. The exit code is the mechanism; this is the harm.
reached_fail="$(python3 "$CAGE" 30 bash -c 'exit 7' >/dev/null 2>&1 && echo REACHED)"
reached_pass="$(python3 "$CAGE" 30 bash -c 'exit 0' >/dev/null 2>&1 && echo REACHED)"
check "6f. \`cage … && <next step>\` does NOT advance past a failing suite" \
  "[ -z \"\$reached_fail\" ]"
check "6f-control — …and it DOES advance past a passing one (not merely always red)" \
  "[ \"\$reached_pass\" = REACHED ]"

# A child killed by a SIGNAL is reported as the shell reports it (128+N), not as
# python's truncated negative. The line keeps printing the raw `EXIT -9`.
k_out="$(python3 "$CAGE" 30 bash -c 'kill -9 $$' 2>&1)"; k_rc=$?
check "6f-control — a child KILLED by a signal exits 128+N (137), and the line is unchanged" \
  "[ \"\$k_rc\" -eq 137 ] && [ \"\$(contract_line \"\$k_out\")\" = 'ELAPSED <n>s EXIT -9' ]"

# THE SIGNALLED PATH IS UNCHANGED (it was already honest): a cage that is itself
# TERMed exits the way the signal would have, 128+15.
cat >"$TMPROOT/s289-sleeper.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$1"
while :; do sleep 0.2; done
EOF
s289_pidfile="$TMPROOT/s289-caged.pid"; rm -f "$s289_pidfile"
python3 "$CAGE" 600 bash "$TMPROOT/s289-sleeper.sh" "$s289_pidfile" >"$TMPROOT/s289-sig.txt" 2>&1 &
s289_cage=$!
sw=0; while [ "$sw" -lt 60 ] && [ ! -s "$s289_pidfile" ]; do sw=$((sw + 1)); sleep 0.1; done
s289_child="$(cat "$s289_pidfile" 2>/dev/null || true)"
kill -TERM "$s289_cage" 2>/dev/null || true
wait "$s289_cage" 2>/dev/null; s289_rc=$?
check "6f-control — a TERMed cage still exits 128+15 and still says CAGE SIGNALLED" \
  "[ \"\$s289_rc\" -eq 143 ] && grep -q 'CAGE SIGNALLED' '$TMPROOT/s289-sig.txt'"
[ -n "$s289_child" ] && kill -KILL "$s289_child" 2>/dev/null

# A USAGE ERROR KEEPS ITS OWN EXIT. It must not be dressed up as either a clean
# pass or a timeout: 0 would hide it, 124 would misname it.
python3 "$CAGE" >/dev/null 2>&1; u_rc=$?
check "6f-control — a cage invoked with no deadline and no command keeps its exit 1" \
  "[ \"\$u_rc\" -eq 1 ] && [ \"\$u_rc\" -ne 124 ]"

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

# ==========================================================================
# PART 7 — A SUITE MUST REAP WHAT IT STARTS.
#
# This measures the thing itself: persistent processes newly adopted by pid 1
# after a suite exits. A source scan cannot establish that. The one-second
# settling window deliberately excludes the detached resolve-logs handoff,
# which briefly reparents by design and then exits.
# Attribution is best-effort: sampled ancestry, an inherited marker, or a
# cwd/argv tie to this probe's unique tempdir. Candidates with none of those
# ties are printed and counted as unattributed, NOT blamed or killed. A child
# can shed every tie; these snapshots also cannot see short-lived orphans or
# processes that never reparent to pid 1. The D6 controls live in
# tests/harness-orphans.test.sh.
# ==========================================================================
printf '\n  -- 7: suites leave no attributed persistent ppid-1 processes --\n'

command -v lsof >/dev/null || { echo "orphan probes require lsof" >&2; exit 1; }

ppid1_snapshot() {
  ps -eo pid=,ppid= | awk '$2 == 1 { print $1 }' | sort -n >"$1"
}

cat >"$TMPROOT/orphan-probe-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
exec 9>"$1.marker"
printf '%s\n' "$$" >"$1"
shift
exec "$@"
EOF
chmod +x "$TMPROOT/orphan-probe-wrapper.sh"

record_descendants() { # <root-pid> <output-file>
  local root="$1" out="$2" table="$TMPROOT/descendants.ps"
  local frontier="$root" seen=" $root " next parent child
  ps -eo pid=,ppid= >"$table"
  while [ -n "$frontier" ]; do
    next=""
    for parent in $frontier; do
      for child in $(awk -v p="$parent" '$2 == p { print $1 }' "$table"); do
        case "$seen" in *" $child "*) continue ;; esac
        printf '%s\n' "$child" >>"$out"
        seen="$seen$child "
        next="$next $child"
      done
    done
    frontier="$next"
  done
}

suite_path_signal() { # <pid> <argv>
  local pid="$1" argv="$2" suite_dir cwd
  suite_dir="$(cd "$TMPROOT" && pwd -P)"
  cwd="$(lsof -nP -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  case "$cwd/" in "$suite_dir/"*) return 0 ;; esac
  case "$argv " in
    *"$TMPROOT/"*|*"$suite_dir/"*|*"$TMPROOT "*|*"$suite_dir "*) return 0 ;;
  esac
  return 1
}

orphan_probe() { # <label> <deadline> <command...>
  local label="$1" deadline="$2"
  local before="$TMPROOT/$label.before"
  local first="$TMPROOT/$label.first" after="$TMPROOT/$label.after"
  local report="$TMPROOT/$label.cage" new="$TMPROOT/$label.new"
  local rootfile="$TMPROOT/$label.root" observed="$TMPROOT/$label.observed"
  local cage_pid root p argv candidates="$TMPROOT/$label.candidates"
  local unattributed="$TMPROOT/$label.unattributed"
  shift 2
  : >"$observed"
  ppid1_snapshot "$before"
  python3 "$CAGE" "$deadline" bash "$TMPROOT/orphan-probe-wrapper.sh" "$rootfile" "$@" >"$report" 2>&1 &
  cage_pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -s "$rootfile" ]; do i=$((i + 1)); sleep 0.02; done
  root="$(cat "$rootfile" 2>/dev/null || true)"
  while kill -0 "$cage_pid" 2>/dev/null; do
    [ -n "$root" ] && record_descendants "$root" "$observed"
    sleep 0.05
  done
  wait "$cage_pid" 2>/dev/null || true
  sleep 1
  ppid1_snapshot "$first"
  sleep 1
  ppid1_snapshot "$after"
  sort -nu "$observed" -o "$observed"
  comm -13 "$before" "$first" | grep -Fxf "$after" >"$candidates" || true
  : >"$new"
  : >"$unattributed"
  while read -r p; do
    argv="$(ps -p "$p" -o args= 2>/dev/null)" || argv="<exited or argv unavailable>"
    [ -n "$argv" ] || argv="<empty argv>"
    # A fast double-fork can lose both ancestry and the inherited descriptor.
    # Its suite path is independent evidence; no evidence means unknown, not safe.
    if grep -qxF "$p" "$observed" ||
       lsof -nP -a -p "$p" "$rootfile.marker" >/dev/null 2>&1 ||
       suite_path_signal "$p" "$argv"; then
      printf '%s\n' "$p" >>"$new"
    else
      printf '%s\t%s\n' "$p" "$argv" >>"$unattributed"
      printf '  [orphan] %s unattributed pid=%s argv=%s\n' "$label" "$p" "$argv"
    fi
  done <"$candidates"
  printf '  [orphan] %s: attributed=%s unattributed=%s\n' "$label" \
    "$(wc -l <"$new" | tr -d ' ')" "$(wc -l <"$unattributed" | tr -d ' ')"
  ORPHAN_NEW="$new"
  ORPHAN_UNATTRIBUTED="$unattributed"
  ORPHAN_REPORT="$report"
}

# CONTROL: the detector must first prove that it catches a suite which really
# abandons a child. The marker is in argv so the measured process is explicit,
# and the exact detected pid is removed before any real-suite measurement.
cat >"$TMPROOT/planted-orphan.test.sh" <<'EOF'
#!/usr/bin/env bash
while :; do sleep 1; done &
sleep 1
exit 0
EOF
orphan_probe planted-orphan 10 bash "$TMPROOT/planted-orphan.test.sh"
planted_count="$(wc -l <"$ORPHAN_NEW" | tr -d ' ')"
check "7a. CONTROL: the ppid-1 probe catches a deliberately leaking suite" \
  "[ \"\$planted_count\" -ge 1 ] && ps -p \"\$(head -1 '$ORPHAN_NEW')\" -o args= | grep -q 'planted-orphan.test.sh'"
while read -r p; do
  [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
done <"$ORPHAN_NEW"

cat >"$TMPROOT/fast-orphan.py" <<'PY'
import os, sys
if os.fork():
    os._exit(0)
os.setsid()
if os.fork():
    os._exit(0)
with open(sys.argv[1], "w") as handle:
    handle.write(str(os.getpid()) + "\n")
fd = os.open("/dev/null", os.O_RDWR)
for target in (0, 1, 2):
    os.dup2(fd, target)
os.execl("/bin/sleep", "s256-fast-orphan", "300")
PY
orphan_probe fast-orphan 10 python3 "$TMPROOT/fast-orphan.py" "$TMPROOT/fast.pid"
fast_pid="$(cat "$TMPROOT/fast.pid")"
echo "  [orphan] fast double-fork: $(wc -l <"$ORPHAN_NEW" | tr -d ' ') detected"
check "7c. CONTROL: a fast double-fork is caught even if its parent link was never sampled" \
  "grep -qx \"\$fast_pid\" '$ORPHAN_NEW' && [ \"\$(ps -p \"\$fast_pid\" -o ppid= | tr -d ' ')\" = 1 ]"
kill -KILL "$fast_pid" 2>/dev/null || true

# Measure the detector against a small fixture; the gate owns product suites.
cat >"$TMPROOT/clean-orphan.test.sh" <<'EOF'
#!/usr/bin/env bash
sleep 300 &
child=$!
kill -TERM "$child"
wait "$child" 2>/dev/null || true
EOF
orphan_probe clean-orphan 10 bash "$TMPROOT/clean-orphan.test.sh"
n="$(wc -l <"$ORPHAN_NEW" | tr -d ' ')"
echo "  [orphan] clean fixture: $n attributed persistent new ppid-1 process(es); $(sed -n '1p' "$ORPHAN_REPORT")"
check "7b. the clean fixture leaves ZERO attributed persistent ppid-1 processes" \
  "[ \"\$n\" -eq 0 ] && grep -Eq '^ELAPSED [0-9.]+s EXIT 0$' '$ORPHAN_REPORT'"
while read -r p; do
  ps -p "$p" -o pid=,ppid=,args= 2>/dev/null | sed 's/^/    /'
  kill -KILL "$p" 2>/dev/null || true
done <"$ORPHAN_NEW"

echo
printf 'harness: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
