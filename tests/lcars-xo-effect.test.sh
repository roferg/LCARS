#!/usr/bin/env bash
#
# S240 — EFFECT: the headline is a RECOMMENDATION, and a gap gets FILED.
#
# THE TWO DEFECTS THIS SUITE PINS.
#
#  1. THE HEADLINE WAS A BARE ADJECTIVE. `verdict.json` carried `score:
#     low|medium|high` and nothing else, so the weekend playbook's merge policy
#     (§4) was applied BY HAND on every look — and the two numbers that actually
#     decided the grade (`coveragePct`, `coverageFloorPct`, written into
#     `groups.person` since S226) NEVER REACHED `report.md`. The archive has the
#     case: 83% against a floor of 80 decided `high` while the report the captain
#     read said only "2 I couldn't set up". So the recommendation is DERIVED here,
#     beside the grade, off the same ledger — and both lines of the report say
#     the numbers out loud.
#
#  2. NUMBER ONE FILED NOTHING IT FOUND WITH AN INSTRUMENT OTHER THAN A CAMERA.
#     `xo-logs.py`'s selection rule was "contradictions only", and a contradiction
#     needed a picture or a quoted failing-test line. A gap whose proof is a CLI
#     transcript — the whole point of S239's reach steps — was reported and never
#     filed. The selection is WIDENED (not replaced) to every `gap` proven by ANY
#     recorded instrument plus every high-impact `untested` with a PRODUCT cause,
#     and the PRD it assembles is rewritten to the evidence-first template that
#     `ech.sh file-bug` actually accepts.
#
# WHAT IS NOT CHANGED, AND IS ASSERTED NOT TO BE: the grade ladder
# (`derive_grade`), `checkedBy`/`evidence`, and the WHY wire line.
#
# POSITIVE CONTROLS, each in its own phrasing family:
#   * a CLEAN ledger with the floor met really does reach `merge` — so the rule
#     is not stuck on one verdict and this suite cannot pass on a constant.
#   * a gap whose evidence is NOT an instrument is still NOT filed — so the
#     widening is a widening and not the removal of a rule.
#   * the weekend archive's own PRD (`canvas-weekend-2026-09-26/evidence/
#     filed-prds/bug-020-1.md`) is STILL REFUSED by the real validator lifted out
#     of ech.sh — if this suite ever loosens it, that check goes red.
#   * the shim on PATH is proven to fire before "no spend" is claimed.
#
# Skill source under test:
#   skills/lcars-xo/xo-score.py    — recommendation, because/blockers/followUps,
#                                    report.md lines 1-2, the RECOMMENDATION wire
#   skills/lcars-xo/xo-logs.py     — the widened selection + the evidence-first PRD
#   skills/lcars-xo/xo-journey.py  — coverage reasons that come from the record
#   skills/lcars-eeh/ech.sh — `policy` reads `recommendation`
#
# ZERO SPEND. Pure python/shell over fixture JSON. No worker, no browser, no gh,
# no network. A PATH shim stubs `claude` and `copilot`.
#
# Usage: bash tests/lcars-xo-effect.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
LOGSPY="${LCARS_XO_LOGS_PY:-$REPO_ROOT/skills/lcars-xo/xo-logs.py}"
JOURNEYPY="${LCARS_XO_JOURNEY_PY:-$REPO_ROOT/skills/lcars-xo/xo-journey.py}"
ECH="$REPO_ROOT/skills/lcars-eeh/ech.sh"
ARCHIVE_PRD="$HOME/Projects/lcars-dev/canvas-weekend-2026-09-26/evidence/filed-prds/bug-020-1.md"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

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

# THE REAL VALIDATOR, LIFTED OUT OF THE REAL FILE — never a copy of it. The PY
# heredoc inside `bug_prd_problems` is extracted from ech.sh at run time,
# so a PRD this suite calls valid is one `file-bug` would accept, and a change
# to the validator shows up here instead of being shadowed by a stale duplicate.
VALIDATOR="$TMPROOT/bug_prd_problems.py"
awk '/^bug_prd_problems\(\) \{/,/^\}$/' "$ECH" \
  | awk "/<<'PY'/{f=1;next} /^PY\$/{f=0} f" >"$VALIDATOR"
prd_valid() { "$PY" "$VALIDATOR" "$1" >"$TMPROOT/prd.msg" 2>&1; }

check "0. the real validator was lifted out of ech.sh (non-empty)" \
  "[ -s '$VALIDATOR' ] && grep -q 'Observed live' '$VALIDATOR'"

# ─── THE CONTRACT, SHARED BY EVERY LEDGER BELOW ──────────────────────────────
# Five person-group criteria, so the 80% floor is 4 of 5 and one unchecked row
# is the difference between meeting it and missing it. Identical across cases on
# purpose: any difference in the recommendation is the ledger and nothing else.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "notes add stores the title it was given", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "notes list shows every stored note", "source": "prd", "primary": true},
  {"id": "prd-3", "text": "the published page shows the host the CLI stored", "source": "prd", "primary": true},
  {"id": "prd-4", "text": "publish refuses a note with no title", "source": "prd", "primary": true},
  {"id": "prd-5", "text": "the workflow publishes on a push to main", "source": "prd", "primary": true}
 ]}
C

met() { # <id> <impact>
  printf '{"id": "%s", "impact": "%s", "impactWhy": "it is why %s exists", "status": "met", "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks", "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."}' "$1" "$2" "$1"
}

# A LEDGER WHERE EVERYTHING WORKED AND THE FLOOR IS MET — the positive control
# for `merge`. 5 of 5 checked, 100% against a floor of 80.
{
  printf '{"score": "high", "summary": "Everything I checked worked.", "criteria": ['
  printf '%s,' "$(met prd-1 high)" "$(met prd-2 high)" "$(met prd-3 high)" "$(met prd-4 medium)"
  printf '%s' "$(met prd-5 medium)"
  printf '], "gaps": []}\n'
} >"$TMPROOT/worker-merge.json"

# A LEDGER WITH ONE MEDIUM-IMPACT GAP AND NOTHING HIGH BROKEN — follow-ups.
cat >"$TMPROOT/worker-followups.json" <<'W'
{"score": "medium", "summary": "One cosmetic thing is short.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-3", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-4", "impact": "medium", "impactWhy": "a nicety", "status": "gap",
  "shot": "shot-02", "evidence": "picture", "checkedBy": "browser",
  "note": "it accepted a blank title", "action": "submitted an empty form",
  "reason": "Outcome: gap."},
 {"id": "prd-5", "impact": "medium", "impactWhy": "a nicety", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "read the run log", "reason": "Outcome: met."}
], "gaps": [
 {"criterion": "prd-4", "kind": "contradiction", "title": "publish accepts a note with no title",
  "expected": "a refusal", "saw": "a published empty note", "evidence": "picture",
  "shots": ["shot-02"], "impact": "medium"}
]}
W

# A LEDGER WITH A HIGH-IMPACT GAP — send-back, whatever the grade says.
cat >"$TMPROOT/worker-sendback.json" <<'W'
{"score": "medium", "summary": "The host does not survive the hop.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-3", "impact": "high", "impactWhy": "it is the point", "status": "gap",
  "shot": "01-publish", "evidence": "transcript", "checkedBy": "cli",
  "note": "the page rendered api.github.com, not the host the CLI stored",
  "action": "ran notes publish and read the generated page",
  "reason": "Outcome: gap."},
 {"id": "prd-4", "impact": "medium", "impactWhy": "a nicety", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "submitted the form", "reason": "Outcome: met."},
 {"id": "prd-5", "impact": "medium", "impactWhy": "a nicety", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "read the run log", "reason": "Outcome: met."}
], "gaps": [
 {"criterion": "prd-3", "kind": "contradiction",
  "title": "the published page shows api.github.com, never the host the CLI stored",
  "expected": "the host recorded by notes add", "saw": "a hardcoded api.github.com",
  "evidence": "transcript", "shot": "01-publish", "shots": [],
  "seam": "notes.py cmd_publish (writes host) -> page.py render_host (reads origin)",
  "impact": "high"}
]}
W

# A LEDGER WITH NOTHING BROKEN BUT THE FLOOR MISSED FOR AN INFRASTRUCTURE
# REASON — follow-ups, in its own phrasing family (no gap at all).
cat >"$TMPROOT/worker-infra.json" <<'W'
{"score": "medium", "summary": "Everything I reached worked; two I could not set up.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-3", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-4", "impact": "medium", "impactWhy": "a nicety", "status": "untested",
  "evidence": "none", "couldNotCheck": "unreachable", "cause": "infrastructure",
  "note": "the test runner is not installed on this machine", "reason": "Outcome: untested."},
 {"id": "prd-5", "impact": "medium", "impactWhy": "a nicety", "status": "untested",
  "evidence": "none", "couldNotCheck": "unreachable", "cause": "infrastructure",
  "note": "no GitHub runner is available locally", "reason": "Outcome: untested."}
], "gaps": []}
W

# A LEDGER WHERE A HIGH-IMPACT CRITERION IS UNREACHABLE FOR A PRODUCT REASON —
# send-back, in its own phrasing family (no gap row at all).
cat >"$TMPROOT/worker-product-blind.json" <<'W'
{"score": "medium", "summary": "The thing the mission is for has no way in.", "criteria": [
 {"id": "prd-1", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-2", "impact": "high", "impactWhy": "it is the point", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "opened the page", "reason": "Outcome: met."},
 {"id": "prd-3", "impact": "high", "impactWhy": "it is the point", "status": "untested",
  "evidence": "none", "couldNotCheck": "unreachable", "cause": "product",
  "checkedBy": "cli",
  "note": "the build ships no publish command at all, so there is nothing to run",
  "reason": "Outcome: untested."},
 {"id": "prd-4", "impact": "medium", "impactWhy": "a nicety", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "submitted the form", "reason": "Outcome: met."},
 {"id": "prd-5", "impact": "medium", "impactWhy": "a nicety", "status": "met",
  "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "saw it",
  "action": "read the run log", "reason": "Outcome: met."}
], "gaps": []}
W

run() { # <name> <worker.json>
  mkdir -p "$TMPROOT/$1"
  "$PY" "$SCOREPY" "$2" "$TMPROOT/criteria.json" "$TMPROOT/$1/verdict.json" \
    >"$TMPROOT/$1/out.txt" 2>"$TMPROOT/$1/err.txt"
}
field() { # <name> <key>
  "$PY" - "$TMPROOT/$1/verdict.json" "$2" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get(sys.argv[2])
print(v if isinstance(v, str) else json.dumps(v))
P
}
wire() { sed -n "s/^$2	//p" "$TMPROOT/$1/out.txt" | head -1; }
rline() { sed -n "$2p" "$TMPROOT/$1/report.md"; }

run merge            "$TMPROOT/worker-merge.json"
run followups        "$TMPROOT/worker-followups.json"
run sendback         "$TMPROOT/worker-sendback.json"
run infra            "$TMPROOT/worker-infra.json"
run blind            "$TMPROOT/worker-product-blind.json"

printf '\n── 1. the recommendation replaces the adjective ──\n'

check "1a. a clean ledger with the floor met recommends merge (positive control)" \
  "[ \"\$(field merge recommendation)\" = merge ]"
check "1b. a medium-impact gap and nothing high broken recommends merge-with-follow-ups" \
  "[ \"\$(field followups recommendation)\" = merge-with-follow-ups ]"
check "1c. a high-impact gap recommends send-back" \
  "[ \"\$(field sendback recommendation)\" = send-back ]"
check "1d. the floor missed for INFRASTRUCTURE reasons recommends merge-with-follow-ups" \
  "[ \"\$(field infra recommendation)\" = merge-with-follow-ups ]"
check "1e. a high-impact criterion unreachable for a PRODUCT reason recommends send-back" \
  "[ \"\$(field blind recommendation)\" = send-back ]"
check "1f. the grade LADDER is untouched: the clean ledger still grades high" \
  "[ \"\$(field merge score)\" = high ]"
check "1g. …and the high-impact gap still grades low by the same ladder" \
  "[ \"\$(field sendback score)\" = low ]"
check "1h. …and the infra-blind ledger is still held back to medium by the floor" \
  "[ \"\$(field infra score)\" = medium ]"

check "1i. because[] carries one line per reason, not an empty list" \
  "[ \"\$(field sendback because)\" != '[]' ] && [ \"\$(field sendback because)\" != null ]"
check "1j. blockers[] names the criterion that forced the send-back" \
  "field sendback blockers | grep -q 'prd-3'"
check "1k. blockers[] carries the recorded evidence kind for that criterion" \
  "field sendback blockers | grep -q transcript"
check "1l. followUps[] on the merge-with-follow-ups ledger names its gap" \
  "field followups followUps | grep -q 'prd-4'"
check "1m. a merge has NO blockers (positive control: the key is not a constant)" \
  "[ \"\$(field merge blockers)\" = '[]' ]"
check "1n. the recommendation rides the wire for the shell to mirror" \
  "[ \"\$(wire sendback RECOMMENDATION)\" = send-back ]"
check "1o. …and the wire says merge on the clean ledger (positive control)" \
  "[ \"\$(wire merge RECOMMENDATION)\" = merge ]"
check "1p. the WHY wire line is still the grade derivation, not the recommendation" \
  "[ \"\$(wire sendback WHY)\" = \"\$(field sendback derivation)\" ]"

printf '\n── 2. report.md lines 1 and 2 ──\n'

check "2a. line 1 is the recommendation" \
  "rline sendback 1 | grep -q '^\\*\\*Recommendation: SEND-BACK\\*\\*'"
check "2b. line 1 carries a one-sentence why after the dash" \
  "rline sendback 1 | grep -qE '^\\*\\*Recommendation: SEND-BACK\\*\\* — .{20,}'"
check "2c. line 1 says MERGE on the clean ledger (positive control)" \
  "rline merge 1 | grep -q '^\\*\\*Recommendation: MERGE\\*\\*'"
check "2d. line 1 says MERGE WITH FOLLOW-UPS on the follow-ups ledger" \
  "rline followups 1 | grep -q '^\\*\\*Recommendation: MERGE WITH FOLLOW-UPS\\*\\*'"
check "2e. line 2 is the grade" \
  "rline sendback 2 | grep -q 'How close this is to what you asked for: LOW'"
check "2f. line 2 says how many of how many were checked" \
  "rline sendback 2 | grep -qE 'checked 5 of 5'"
check "2g. line 2 prints the coverage percentage and the floor" \
  "rline infra 2 | grep -q '60%' && rline infra 2 | grep -q 'floor 80%'"
check "2h. line 2 counts the unreachable rows" \
  "rline infra 2 | grep -qE '2 unreachable'"
check "2i. line 2 gives the RECORDED reason for an unreachable row, not a canned one" \
  "rline infra 2 | grep -qi 'runner'"
check "2j. a ledger with nothing unreachable does not claim any (positive control)" \
  "! rline merge 2 | grep -qE '[0-9]+ unreachable'"
check "2k. the coverage numbers are in the verdict too, where S226 put them" \
  "field merge groups | grep -q coveragePct"

printf '\n── 3. filing — the widened selection and the evidence-first PRD ──\n'

SHOTS="$TMPROOT/shots"
mkdir -p "$SHOTS" "$TMPROOT/logs-out"
printf '$ notes publish\nwrote page.html with origin=api.github.com\n' >"$SHOTS/01-publish.txt"
echo '{"selector": "", "clip": "full-page", "url": "file:///page.html"}' >"$SHOTS/shot-02.json"
: >"$SHOTS/shot-02.png"

plan() { # <verdict-dir> <out-dir> [already.json]
  "$PY" "$LOGSPY" "$TMPROOT/$1/verdict.json" "$TMPROOT/criteria.json" \
    "$2" "$SHOTS" 10 "${3:-}" 2>"$TMPROOT/logs.err"
}
PLAN_SB="$(plan sendback "$TMPROOT/logs-out")"
# US (0x1f) is the field separator xo-logs.py uses on purpose — see its
# docstring. `cut` with a literal US is the only split that survives an empty
# field, which is the whole reason a tab was abandoned.
US=$'\x1f'
prd_of() { printf '%s\n' "$1" | grep '^GAP' | head -1 | cut -d"$US" -f3; }
PRD_SB="$(prd_of "$PLAN_SB")"

check "3a. the transcript-proven gap produced one filing plan line" \
  "[ \"\$(printf '%s\n' \"\$PLAN_SB\" | grep -c GAP)\" = 1 ]"
check "3b. …naming prd-3, the criterion it is for" \
  "printf '%s' \"\$PLAN_SB\" | grep -q prd-3"
check "3c. …and a PRD was written to disk" \
  "[ -n \"\$PRD_SB\" ] && [ -s \"\$PRD_SB\" ]"
check "3d. the PRD passes the REAL file-bug validator" \
  "prd_valid \"\$PRD_SB\" || { cat '$TMPROOT/prd.msg'; false; }"
check "3e. the title states the broken behaviour as a sentence" \
  "head -1 \"\$PRD_SB\" | grep -qE '^# Mission: .{25,}'"
check "3f. there is a **Seam:** line" \
  "grep -q '^\\*\\*Seam:\\*\\*' \"\$PRD_SB\""
check "3g. the Goal is the corrected invariant" \
  "grep -q '^\\*\\*Goal:\\*\\*' \"\$PRD_SB\""
check "3h. AC #1 is an Observed live: line" \
  "grep -q '^- Observed live:' \"\$PRD_SB\""
check "3i. AC #1 QUOTES THE TRANSCRIPT PATH — the whole point of the widening" \
  "grep -q '01-publish.txt' \"\$PRD_SB\""
check "3j. the declared seam brings a ROUND-TRIP criterion with it" \
  "grep -qi 'round-trip' \"\$PRD_SB\""
check "3k. there is an Out of Scope section" \
  "grep -q '^\\*\\*Out of Scope:\\*\\*' \"\$PRD_SB\""
check "3l. there is a Constraints section" \
  "grep -q '^\\*\\*Constraints:\\*\\*' \"\$PRD_SB\""
check "3m. Constraints carry the PLAN RULE" \
  "grep -qi 'PLAN RULE' \"\$PRD_SB\""
check "3n. Type is bug" \
  "grep -q '^\\*\\*Type:\\*\\* bug' \"\$PRD_SB\""

# NEVER FILE TWICE. `logs.json` is the record; a second look reads it and files
# nothing for a criterion already filed.
cat >"$TMPROOT/already.json" <<'A'
{"round": 1, "filedAt": "now", "overflow": 0,
 "filed": [{"n": 1, "mission": "lcars-20261002-009-aaaa", "issue": "41",
            "criterion": "prd-3", "title": "the published page shows api.github.com", "shots": []}]}
A
mkdir -p "$TMPROOT/logs-again"
PLAN_AGAIN="$(plan sendback "$TMPROOT/logs-again" "$TMPROOT/already.json")"
check "3o. a second look files NOTHING for a criterion already filed" \
  "[ \"\$(printf '%s\n' \"\$PLAN_AGAIN\" | grep -c '^GAP')\" = 0 ]"
check "3p. …and says so rather than going quiet" \
  "printf '%s' \"\$PLAN_AGAIN\" | grep -q ALREADY"
check "3q. …naming the bug mission it was filed as" \
  "printf '%s' \"\$PLAN_AGAIN\" | grep -q lcars-20261002-009-aaaa"

# THE HIGH-IMPACT UNTESTED WITH A PRODUCT CAUSE IS FILED TOO.
mkdir -p "$TMPROOT/logs-blind"
PLAN_BLIND="$(plan blind "$TMPROOT/logs-blind")"
check "3r. a high-impact untested with a PRODUCT cause is filed" \
  "[ \"\$(printf '%s\n' \"\$PLAN_BLIND\" | grep -c '^GAP')\" = 1 ]"
PRD_BLIND="$(prd_of "$PLAN_BLIND")"
check "3s. …and its PRD passes the real validator too" \
  "prd_valid \"\$PRD_BLIND\" || { cat '$TMPROOT/prd.msg'; false; }"
check "3t. …and its AC #1 quotes the recorded cause, not a canned sentence" \
  "grep -q 'no publish command' \"\$PRD_BLIND\""

# POSITIVE CONTROL FOR THE WIDENING: an untested row whose cause is INFRASTRUCTURE
# is NOT filed — the widening added instruments, it did not remove a rule.
mkdir -p "$TMPROOT/logs-infra"
PLAN_INFRA="$(plan infra "$TMPROOT/logs-infra")"
check "3u. control. an INFRASTRUCTURE-caused untested row is not filed against the build" \
  "[ \"\$(printf '%s\n' \"\$PLAN_INFRA\" | grep -c '^GAP')\" = 0 ]"

# POSITIVE CONTROL: a gap with NO recorded instrument at all is still not filed.
cat >"$TMPROOT/worker-noinstrument.json" <<'W'
{"score": "medium", "summary": "A judgement call, with nothing behind it.", "criteria": [
 {"id": "prd-1", "impact": "medium", "impactWhy": "a nicety", "status": "gap",
  "evidence": "none", "note": "it felt wrong", "reason": "Outcome: gap."}
], "gaps": [
 {"criterion": "prd-1", "kind": "interpretation", "title": "it felt wrong",
  "expected": "something", "saw": "something else", "evidence": "none", "shots": []}
]}
W
run noinstrument "$TMPROOT/worker-noinstrument.json"
mkdir -p "$TMPROOT/logs-none"
PLAN_NONE="$(plan noinstrument "$TMPROOT/logs-none")"
check "3v. control. a gap proven by NO instrument is still not filed" \
  "[ \"\$(printf '%s\n' \"\$PLAN_NONE\" | grep -c '^GAP')\" = 0 ]"

printf '\n── 4. the cap of ten, and the overflow said out loud ──\n'
"$PY" - "$TMPROOT/criteria-many.json" "$TMPROOT/worker-many.json" <<'P'
import json, sys
crit, work = sys.argv[1], sys.argv[2]
ids = ["prd-%d" % i for i in range(1, 15)]
json.dump({"mission": "m", "hasDrawing": False, "placeNames": [], "pictures": [],
           "criteria": [{"id": i, "text": "thing %s works" % i, "source": "prd",
                         "primary": True} for i in ids]}, open(crit, "w"))
rows, gaps = [], []
for i in ids:
    rows.append({"id": i, "impact": "medium", "impactWhy": "a nicety", "status": "gap",
                 "shot": "shot-02", "evidence": "picture", "checkedBy": "browser",
                 "note": "%s did not work" % i, "action": "clicked it",
                 "reason": "Outcome: gap."})
    gaps.append({"criterion": i, "kind": "contradiction",
                 "title": "%s does not do what it says" % i,
                 "expected": "it to work", "saw": "it not working",
                 "evidence": "picture", "shots": ["shot-02"], "impact": "medium"})
json.dump({"score": "low", "summary": "Lots is short.", "criteria": rows, "gaps": gaps},
          open(work, "w"))
P
mkdir -p "$TMPROOT/many" "$TMPROOT/logs-many"
"$PY" "$SCOREPY" "$TMPROOT/worker-many.json" "$TMPROOT/criteria-many.json" \
  "$TMPROOT/many/verdict.json" >"$TMPROOT/many/out.txt" 2>"$TMPROOT/many/err.txt"
PLAN_MANY="$(plan many "$TMPROOT/logs-many")"
check "4a. fourteen filable gaps file exactly ten" \
  "[ \"\$(printf '%s\n' \"\$PLAN_MANY\" | grep -c '^GAP')\" = 10 ]"
check "4b. …and the four that were not filed are said out loud" \
  "printf '%s\n' \"\$PLAN_MANY\" | grep -q '^OVERFLOW' && printf '%s\n' \"\$PLAN_MANY\" | grep -q 4"

printf '\n── 5. coverage reasons come from the record ──\n'
cat >"$TMPROOT/j-criteria.json" <<'C'
{"mission": "m", "hasDrawing": true, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-7", "text": "a published note keeps the host it was given", "source": "prd", "primary": true},
  {"id": "prd-8", "text": "a stored note keeps the origin it was given", "source": "prd", "primary": true}
 ]}
C
cat >"$TMPROOT/records.jsonl" <<'J'
{"at": "2026-10-02T00:00:00Z", "action": "couldnt-check", "criterion": "prd-7", "detail": "the publish command exits 2 before it writes anything, so there is no page to read"}
J
RECORDED="the publish command exits 2"
"$PY" "$JOURNEYPY" build --criteria "$TMPROOT/j-criteria.json" \
  --out "$TMPROOT/journey-rec.json" --records "$TMPROOT/records.jsonl" \
  >"$TMPROOT/journey-rec.txt" 2>&1
"$PY" "$JOURNEYPY" build --criteria "$TMPROOT/j-criteria.json" \
  --out "$TMPROOT/journey-norec.json" \
  >"$TMPROOT/journey-norec.txt" 2>&1
reason_of() { # <journey.json> <id>
  "$PY" - "$1" "$2" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for r in (d.get("coverage") or {}).get("criteria") or []:
    if r.get("id") == sys.argv[2]:
        print(r.get("reason") or "")
        break
P
}
check "5a. --records is accepted and the journey still builds" \
  "[ -s '$TMPROOT/journey-rec.json' ]"
check "5b. the coverage reason for prd-7 is the RECORDED cause" \
  "reason_of '$TMPROOT/journey-rec.json' prd-7 | grep -qF '$RECORDED'"
check "5c. …and does NOT fall back to the canned drawing sentence" \
  "! reason_of '$TMPROOT/journey-rec.json' prd-7 | grep -q 'nothing on the drawing corresponds'"
# THE CONTROL ROW IS THE SAME SHAPE AS prd-7 ON PURPOSE. The first attempt here
# used "a run can be resumed from the saves screen" — which names a screen and a
# verb, so the walk ATTEMPTED it and the row carried no reason at all. The control
# passed on nothing. prd-8 is now a sibling of prd-7: unattemptable in the same
# way, so the ONLY difference between the two rows is whether a record exists.
check "5d. control. prd-8, which has no record, still gets the canned text" \
  "reason_of '$TMPROOT/journey-rec.json' prd-8 | grep -qi \"couldn't set it up\""
check "5e. …and SAYS it is a guess with no record behind it" \
  "reason_of '$TMPROOT/journey-rec.json' prd-8 | grep -qi 'no record'"
check "5f. control. with no --records at all, prd-7 gets the canned text too" \
  "reason_of '$TMPROOT/journey-norec.json' prd-7 | grep -qi \"couldn't set it up\""
check "5g. …marked as having no record behind it" \
  "reason_of '$TMPROOT/journey-norec.json' prd-7 | grep -qi 'no record'"
check "5h. xo.sh hands the journal to xo-journey.py so the record can be read" \
  "grep -q -- '--records' '$REPO_ROOT/skills/lcars-xo/xo.sh'"

printf '\n── 5b. filing is a switch, and OFF files nothing ──\n'
# THE REAL FUNCTION, LIFTED OUT OF THE REAL FILE — same discipline as the
# validator above. `cfg_files_bugs` reads the repo's recorded `numberOne` block;
# the harness here supplies that block and nothing else, so what is under test is
# the gate's own rule and not a mission rig.
GATE="$TMPROOT/gate.sh"
{
  echo 'cfg_block() { printf "%s" "$BLOCK"; }'
  # BOTH halves of the real reader. S240 fix round 1 (D1) split the key lookup
  # out into `cfg_flag` so it is whitespace-insensitive and shared with
  # `cfg_enabled`; lifting only `cfg_files_bugs` left `cfg_flag: command not
  # found`, which made 5k and 5l pass on an empty string instead of on the
  # product. A lift has to bring everything the lifted function calls.
  awk '/^cfg_flag\(\) \{/,/^\}$/' "$REPO_ROOT/skills/lcars-xo/xo.sh"
  awk '/^cfg_files_bugs\(\) \{/,/^\}$/' "$REPO_ROOT/skills/lcars-xo/xo.sh"
} >"$GATE"
check "5i. the gate function was lifted out of xo.sh (non-empty)" \
  "grep -q cfg_files_bugs '$GATE'"
check "5j. an explicit filesBugs:false turns filing OFF" \
  "! BLOCK='{\"enabled\": true, \"filesBugs\": false}' bash -c 'source \"$GATE\"; cfg_files_bugs'"
check "5k. control. filesBugs:true leaves it ON" \
  "BLOCK='{\"enabled\": true, \"filesBugs\": true}' bash -c 'source \"$GATE\"; cfg_files_bugs'"
check "5l. control. a repo that predates the switch still files (absent means on)" \
  "BLOCK='{\"enabled\": true, \"engine\": \"copilot\"}' bash -c 'source \"$GATE\"; cfg_files_bugs'"
check "5m. file_logs_for consults the switch BEFORE it builds a filing plan" \
  "\"\$PY\" - <<'P'
import re, sys
t = open('$REPO_ROOT/skills/lcars-xo/xo.sh').read()
body = t[t.index('file_logs_for() {'):]
gate, plan = body.index('cfg_files_bugs'), body.index('xo-logs.py')
sys.exit(0 if gate < plan else 1)
P"
check "5n. …and says which switch did it, so a captain is not left guessing" \
  "grep -q 'numberOne.filesBugs: false' '$REPO_ROOT/skills/lcars-xo/xo.sh'"

printf '\n── 6. the ECH reads the recommendation, and keeps its fallback ──\n'
check "6a. policy reads \`recommendation\` off Number One's own verdict.json" \
  "grep -q 'verdict.json\" recommendation' '$ECH'"
check "6b. …and KEEPS its playbook fallback for a verdict that names none" \
  "grep -q 'verdict.json\" score' '$ECH'"
check "6c. the verdict carries the one sentence a shell can read with one key" \
  "[ -n \"\$(field sendback recommendationWhy)\" ]"

printf '\n── 7. the validator is not loosened ──\n'
if [ -f "$ARCHIVE_PRD" ]; then
  check "7a. the weekend archive's own PRD is STILL refused by the real validator" \
    "! prd_valid '$ARCHIVE_PRD'"
  check "7b. …and the refusal still names the three counts it fails on" \
    "grep -qi 'Out of Scope' '$TMPROOT/prd.msg' && grep -qi 'Seam' '$TMPROOT/prd.msg' && grep -qi 'Observed live' '$TMPROOT/prd.msg'"
else
  printf '  \033[33mSKIP\033[0m 7a/7b. the archive PRD is not on this machine (%s)\n' "$ARCHIVE_PRD"
fi
cat >"$TMPROOT/bad.md" <<'B'
# Mission: something is wrong somewhere

**Type:** bug
**Goal:** fix the thing
**Acceptance Criteria:**
- the thing works
B
check "7c. control(positive). a PRD missing everything is refused" \
  "! prd_valid '$TMPROOT/bad.md'"
check "7d. control(positive). and our own generated PRD is the one that passes" \
  "prd_valid \"\$PRD_SB\""

printf '\n── 8. the fence ──\n'
check "8a. xo-run.py's argv fence is untouched by this session" \
  "grep -q 'argv' '$REPO_ROOT/skills/lcars-xo/xo-run.py'"
check "8b. the scoring LADDER constants are unchanged" \
  "grep -q 'HIGH_COVERAGE_PCT = 80' '$SCOREPY'"
check "8c. checkedBy's recorded vocabulary is unchanged" \
  "grep -q 'VALID_CHECKED_BY = (\"browser\", \"cli\", \"workflow\", \"test\")' '$SCOREPY'"

printf '\n── zero spend ──\n'
check "spend. no paid CLI was invoked (claude/copilot shim log empty)" \
  "[ ! -s '$SPEND_LOG' ]"
check "spend(positive). the shim is on PATH and would have logged a call" \
  "claude --version >/dev/null 2>&1; [ -s '$SPEND_LOG' ]"
: >"$SPEND_LOG"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
