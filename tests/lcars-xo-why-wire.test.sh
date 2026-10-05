#!/usr/bin/env bash
#
# THE ONE LINE THE CARD SHOWS IS THE GRADE, NOT WHATEVER THE REPORT SAID LAST
# (S239, captain-authorized fix).
#
# The defect, measured. `xo-score.py` prints a `WHY` wire line; `xo.sh` reads it
# into `$why` and passes it to `xo_finish` as the HEADLINE, which lands on
# `state.json` as `xo.headline` — and `web/lcars_serve/board.py` calls that "the
# ONE LINE the card shows instead of the whole verdict". The module derives that
# line into a local named `why` (assigned in ~20 places across the grading
# ladder) and FREEZES it into the verdict's `derivation` field. Two later loops
# over report prose then re-bound the SAME name:
#
#   1. the unbuilt-items block   — `for items, why in unbuilt_lines(...)`
#   2. the "Choices I made for you" loop over decisions.json — `why = ...d["why"]`
#
# S247 — LOOP 1 IS DELETED WITH THE TEMPLATER, AND ITS SEAT IS NOT EMPTY. The
# block that now writes prose into "What I could not check" is the look's OWN
# `couldNot` list (S246), rendered from `row["why"]`. That is the same hazard in
# the same section, so case A is re-pointed at it rather than retired: the suite's
# job is to pin the WIRE against whatever writes last into that section.
#
# Either one left the LAST sentence of a report section on the wire, so the board
# card read "your record never named the command it runs" where it should have
# read "Everything you asked for is in the build, and I saw each one on screen."
#
# Nothing asserted what `WHY` should CONTAIN on these paths, which is exactly how
# it broke in silence. This suite pins it, on both paths, with the already-frozen
# `derivation` field as the oracle — `derivation` is written before either loop
# runs, so it is the grade line the wire owes the card.
#
# POSITIVE CONTROLS, in the claim's own phrasing family:
#   * a record with NO actionable unbuilt items, and one with NO decisions, must
#     ALSO put the grade derivation on the wire — otherwise this suite could pass
#     on a module that printed the grade by accident and could not tell the two
#     states apart.
#   * the report prose each loop writes must STILL be there: the refusal
#     sentences in "What I could not check", and the decision's own `why` in
#     "Choices I made for you". Curing the wire must not delete the page.
#
# Skill source under test:
#   skills/lcars-xo/xo-score.py  — the wire lines and report.md, rendered here
#                                  and nowhere else.
#
# ZERO SPEND. No worker, no browser, no network — pure Python over fixture JSON.
# A PATH shim stubs `claude` and `copilot` so a stray call would be caught, not
# billed.
#
# Usage: bash tests/lcars-xo-why-wire.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ─── ZERO-SPEND SHIM ─────────────────────────────────────────────────────────
# Nothing in this suite may reach a paid CLI. Any attempt appends to SPEND_LOG
# and the final tally fails on it, so a regression that wires a worker into the
# scorer shows up as a failed check instead of a bill.
SPEND_LOG="$TMPROOT/spend.log"
: >"$SPEND_LOG"
mkdir -p "$TMPROOT/bin"
for c in claude copilot; do
  cat >"$TMPROOT/bin/$c" <<SHIM
#!/usr/bin/env bash
echo "$c \$*" >>"$SPEND_LOG"
exit 97
SHIM
  chmod +x "$TMPROOT/bin/$c"
done
PATH="$TMPROOT/bin:$PATH"
export PATH

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# A two-item primary contract, both met with a shot, so citation guards leave
# them alone and the report renders cleanly. Identical across every case here on
# purpose: the GRADE must not move, so any difference on the wire between cases
# is the defect and nothing else.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "the player can save and resume a run", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "saved runs are shown in a list", "source": "prd", "primary": true}
 ]}
C

cat >"$TMPROOT/worker.json" <<'W'
{"score": "high", "summary": "What I found.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "it is why prd-1 exists",
  "status": "met", "shot": "shot-01", "evidence": "picture",
  "note": "saw it", "reason": "Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "it is why prd-2 exists",
  "status": "met", "shot": "shot-01", "evidence": "picture",
  "note": "saw it", "reason": "Outcome: met."}
], "gaps": []}
W

# ─── FIXTURES ────────────────────────────────────────────────────────────────
# A look that SAYS, in its own words, what it could not get to — the S246 list
# that fills "What I could not check" beside the blind ledger rows, and the last
# thing that writes prose into that section.
"$PY" - "$TMPROOT/worker.json" "$TMPROOT/worker-couldnot.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
d["couldNot"] = [
    {"item": "the second actor", "why": "your record never named the command it runs"},
    {"item": "the owner/login pair", "why": "your record never named the command it runs"},
    {"item": "the deployed page", "why": "your record never named the page it opens"}]
json.dump(d, open(sys.argv[2], "w"), indent=1)
P
UNBUILT_1="your record never named the command it runs"
UNBUILT_2="your record never named the page it opens"

cat >"$TMPROOT/decisions.json" <<'D'
{"decisions": [
  {"question": "What metadata lets the player tell their saves apart",
   "options": ["a timestamp on each slot", "the current map name"],
   "chose": "a timestamp on each slot",
   "why": "it needs no naming step and is unique per save",
   "where": "the save/load menu"},
  {"question": "How many save slots are there",
   "options": ["three fixed slots", "unlimited slots"],
   "chose": "three fixed slots",
   "why": "it bounds the storage and the menu size",
   "where": "the save/load menu"}
]}
D
DECISION_WHY_1="it needs no naming step and is unique per save"
DECISION_WHY_2="it bounds the storage and the menu size"

# POSITIVE CONTROL for the decisions path: a record with no CHOSEN decision, so
# the section never renders.
echo '{"decisions": []}' >"$TMPROOT/decisions-empty.json"

# run <name> <decisions-path> <journey-path> — score with the FULL positional arg
# set so decisions lands at argv[12] and journey at argv[13] exactly as xo.sh
# passes them. Args are passed LITERALLY, never through a word-splitting variable.
run() {
  local name="$1" decisions="$2" journey="$3" worker="${4:-$TMPROOT/worker.json}"
  mkdir -p "$TMPROOT/$name"
  "$PY" "$SCOREPY" \
    "$worker" \
    "$TMPROOT/criteria.json" \
    "$TMPROOT/$name/verdict.json" \
    "" "" "" "" "" "" "" "" \
    "$decisions" \
    "$journey" \
    >"$TMPROOT/$name/out.txt" 2>"$TMPROOT/$name/err.txt"
}

# wire <name> <KEY> — the value of a tab-separated wire line.
wire() { sed -n "s/^$2	//p" "$TMPROOT/$1/out.txt" | head -1; }
# field <name> <json-key> — a top-level string from the verdict.
field() {
  "$PY" - "$TMPROOT/$1/verdict.json" "$2" <<'P'
import json, sys
print(json.load(open(sys.argv[1]))[sys.argv[2]])
P
}

# ─── THE BASELINE: a record with neither block ───────────────────────────────
run plain "" ""
PLAIN_WHY="$(wire plain WHY)"
PLAIN_DERIV="$(field plain derivation)"

echo "The grade line this contract is about:"
printf '  %s\n' "$PLAIN_WHY"

check "0. the baseline run succeeded and wrote a verdict" \
  "[ -s '$TMPROOT/plain/verdict.json' ] && [ -s '$TMPROOT/plain/report.md' ]"
check "0. the baseline WHY is a non-trivial sentence (not vacuous)" \
  "[ \${#PLAIN_WHY} -ge 20 ]"
check "0. the baseline WHY IS the frozen grade derivation" \
  "[ \"\$PLAIN_WHY\" = \"\$PLAIN_DERIV\" ]"

# ─── Case A: a could-not block is present ────────────────────────────────────
run unbuilt "" "" "$TMPROOT/worker-couldnot.json"
A_WHY="$(wire unbuilt WHY)"
A_DERIV="$(field unbuilt derivation)"

# The round-3 delivery, still delivered. These must be green BEFORE the fix too:
# the cure may not cost the report a word.
check "A. the report still raises what the look could not get to" \
  "grep -q 'I could not get to this' '$TMPROOT/unbuilt/report.md'"
check "A. the report still carries the first refusal sentence" \
  "grep -qF '$UNBUILT_1' '$TMPROOT/unbuilt/report.md'"
check "A. the report still carries the second refusal sentence" \
  "grep -qF '$UNBUILT_2' '$TMPROOT/unbuilt/report.md'"
check "A. the report still names the thing each refusal is about" \
  "grep -qF 'the owner/login pair' '$TMPROOT/unbuilt/report.md'"

# THE CONTRACT.
check "A. WHY carries the grade derivation, not the refusal sentence" \
  "[ \"\$A_WHY\" = \"\$A_DERIV\" ]"
check "A. WHY does not carry the first refusal sentence" \
  "! printf '%s' \"\$A_WHY\" | grep -qF '$UNBUILT_1'"
check "A. WHY does not carry the second refusal sentence" \
  "! printf '%s' \"\$A_WHY\" | grep -qF '$UNBUILT_2'"
check "A. the could-not block did not move the wire line off the baseline grade" \
  "[ \"\$A_WHY\" = \"\$PLAIN_WHY\" ]"

# POSITIVE CONTROL: a look that says it could not get to anything renders no such
# block — and its wire line is the grade derivation too. Two states, told apart.
run unbuilt_clean "" ""
B_WHY="$(wire unbuilt_clean WHY)"
check "A(control). with nothing the look could not get to, the block is absent" \
  "! grep -q 'I could not get to this' '$TMPROOT/unbuilt_clean/report.md'"
check "A(control). and WHY is the grade derivation there as well" \
  "[ \"\$B_WHY\" = \"\$(field unbuilt_clean derivation)\" ]"
check "A(control). the two states agree on the wire line (block changes nothing)" \
  "[ \"\$B_WHY\" = \"\$A_WHY\" ]"

# ─── Case C: a decisions.json carrying chosen decisions ──────────────────────
run decided "$TMPROOT/decisions.json" ""
C_WHY="$(wire decided WHY)"
C_DERIV="$(field decided derivation)"

# POSITIVE CONTROL: the decision prose must still reach the report. The cure must
# not delete the section it clobbered the wire from.
check "C. the report still opens 'Choices I made for you'" \
  "grep -q '### Choices I made for you' '$TMPROOT/decided/report.md'"
check "C. the report still carries the first decision's own why" \
  "grep -qF '$DECISION_WHY_1' '$TMPROOT/decided/report.md'"
check "C. the report still carries the second decision's own why" \
  "grep -qF '$DECISION_WHY_2' '$TMPROOT/decided/report.md'"
check "C. the report still names the alternative it passed over" \
  "grep -qF 'the current map name' '$TMPROOT/decided/report.md'"
check "C. the report still says where the choice shows up" \
  "grep -qF 'You will see it in the save/load menu' '$TMPROOT/decided/report.md'"

# THE CONTRACT.
check "C. WHY carries the grade derivation, not the decision's own why" \
  "[ \"\$C_WHY\" = \"\$C_DERIV\" ]"
check "C. WHY does not carry the first decision's why" \
  "! printf '%s' \"\$C_WHY\" | grep -qF '$DECISION_WHY_1'"
check "C. WHY does not carry the LAST decision's why (the clobber's own value)" \
  "! printf '%s' \"\$C_WHY\" | grep -qF '$DECISION_WHY_2'"
check "C. the decisions block did not move the wire line off the baseline grade" \
  "[ \"\$C_WHY\" = \"\$PLAIN_WHY\" ]"

# POSITIVE CONTROL: no chosen decision → no section, and the same wire line.
run decided_none "$TMPROOT/decisions-empty.json" ""
D_WHY="$(wire decided_none WHY)"
check "C(control). with no chosen decision the section is absent" \
  "! grep -q '### Choices I made for you' '$TMPROOT/decided_none/report.md'"
check "C(control). and WHY is the grade derivation there as well" \
  "[ \"\$D_WHY\" = \"\$(field decided_none derivation)\" ]"
check "C(control). the two states agree on the wire line" \
  "[ \"\$D_WHY\" = \"\$C_WHY\" ]"

# ─── Case E: BOTH blocks at once, the worst case ─────────────────────────────
run both "$TMPROOT/decisions.json" "" "$TMPROOT/worker-couldnot.json"
E_WHY="$(wire both WHY)"
check "E. with BOTH blocks present WHY is still the grade derivation" \
  "[ \"\$E_WHY\" = \"\$(field both derivation)\" ]"
check "E. with BOTH blocks present WHY still equals the baseline grade" \
  "[ \"\$E_WHY\" = \"\$PLAIN_WHY\" ]"
check "E. both blocks still rendered in the report" \
  "grep -q 'I could not get to this' '$TMPROOT/both/report.md' && grep -q '### Choices I made for you' '$TMPROOT/both/report.md'"

# ─── THE CONTROL THAT WOULD HAVE CAUGHT THE ORIGINAL BUG ─────────────────────
# The wire line must never TURN UP INSIDE any line either block emitted. This is
# the generic shape of the defect: a report-prose loop re-binding the name the
# wire prints. It catches the next one too, whatever sentence it leaves behind.
#
# CONTAINMENT, not byte-equality, and that distinction is load-bearing. The first
# draft of this control compared the wire line for EQUALITY against each rendered
# line and passed on the broken tree — because the block renders its sentence
# inside a bullet ("- **web#1** — <sentence>"), so the leaked sentence is never
# byte-equal to the whole line. A byte-equal control would have been vacuous. The
# positive control below proves this one is not.
#
# Each block's lines are read back out of report.md between its own headings, so
# the control is measured from what the report actually said, not from a guess.
block_lines() { # <name> <start-regex> <end-regex>
  "$PY" - "$TMPROOT/$1/report.md" "$2" "$3" <<'P'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read().splitlines()
start, end = re.compile(sys.argv[2]), re.compile(sys.argv[3])
on, out = False, []
for ln in text:
    if not on:
        if start.search(ln):
            on = True
        continue
    if end.search(ln):
        break
    out.append(ln)
print("\n".join(out))
P
}

collides() { # <wire-value> ← block lines on stdin; 0 when the wire turns up in one
  local w="$1" ln
  [ -z "$w" ] && return 0   # an empty wire line is itself a failure, so collide
  while IFS= read -r ln; do
    [ -z "${ln//[[:space:]]/}" ] && continue
    case "$ln" in *"$w"*) return 0 ;; esac
  done
  return 1
}

UNBUILT_BLOCK="$(block_lines both '^### What I could not check' '^### ')"
DECISION_BLOCK="$(block_lines both '^### Choices I made for you' '^### What I could not check')"

check "control. the unbuilt block really was captured (non-empty)" \
  "printf '%s' \"\$UNBUILT_BLOCK\" | grep -qF '$UNBUILT_1'"
check "control. the decisions block really was captured (non-empty)" \
  "printf '%s' \"\$DECISION_BLOCK\" | grep -qF '$DECISION_WHY_1'"
check "control. WHY turns up in NO line the unbuilt block emitted" \
  "! printf '%s\n' \"\$UNBUILT_BLOCK\" | collides \"\$E_WHY\""
check "control. WHY turns up in NO line the decisions block emitted" \
  "! printf '%s\n' \"\$DECISION_BLOCK\" | collides \"\$E_WHY\""
# In case E the unbuilt block renders LAST, so it would mask a decisions-block
# leak. Measure that one on the decisions-only run, where nothing can mask it.
DECIDED_BLOCK="$(block_lines decided '^### Choices I made for you' '^### ')"
check "control. the decisions-only block really was captured (non-empty)" \
  "printf '%s' \"\$DECIDED_BLOCK\" | grep -qF '$DECISION_WHY_2'"
check "control. on a decisions-only run WHY turns up in NO line of that block" \
  "! printf '%s\n' \"\$DECIDED_BLOCK\" | collides \"\$C_WHY\""
# POSITIVE CONTROLS for the detector itself: it MUST fire on the exact sentences
# the broken tree leaked, or the two checks above are vacuous.
check "control(positive). the detector fires on the unbuilt block's own sentence" \
  "printf '%s\n' \"\$UNBUILT_BLOCK\" | collides '$UNBUILT_2'"
check "control(positive). the detector fires on the decisions block's own why" \
  "printf '%s\n' \"\$DECISION_BLOCK\" | collides '$DECISION_WHY_2'"

# ─── ZERO SPEND, PROVEN ──────────────────────────────────────────────────────
check "spend. no paid CLI was invoked (claude/copilot shim log empty)" \
  "[ ! -s '$SPEND_LOG' ]"
check "spend(positive). the shim is on PATH and would have logged a call" \
  "claude --version >/dev/null 2>&1; [ -s '$SPEND_LOG' ]"
: >"$SPEND_LOG"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
