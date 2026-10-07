#!/usr/bin/env bash
# tests/lcars-xo-uncontracted.test.sh — S251 fix round 1.
#
# WHAT WAS MEASURED (the brief, not an opinion). Six faults were planted, one per
# class, with the mission's requirements deliberately naming none of them.
# Number One FOUND five of six and FILED three. It withheld two on purpose, in
# its own words: "No criterion covers the footer link, so I am not filing it."
# The product gave it nowhere to put them:
#
#   * `alsoChecked` is documented as "things you looked at that were FINE",
#     rendered as one semicolon-joined prose line, and `xo-logs.py` never reads
#     it. Score-neutral AND unfileable.
#   * the `unlisted` lane routes to `escalations` and is handed ONLY pictures, so
#     it is structurally blind to every command-line fault.
#
# So this file holds four cures and their controls:
#
#   1. AN UNCONTRACTED FINDING IS FILEABLE. `volunteered[]` on the verdict is
#      read by `xo-logs.py` alongside `gaps[]`, filed, marked NOT ASKED FOR, and
#      it does NOT move the grade or the recommendation — the contract-first rule
#      stands, so a volunteered find is information, never a verdict.
#   2. THE CHECKLISTS ARE IN THE WORKER'S HAND. Asserted on the assembled
#      prompt, which is where the question can actually be answered; plus the one
#      line that stops a reviewer reproducing the numbering from memory.
#   3. THE LINK TARGET IS RECORDED. `href`/`src` in the browser readout, so
#      "prints host A, links to host B" can be settled by a picture's readout.
#   4. THE ONE-SURFACE RULE IS GUARDED ON THERE BEING ONE. Three surfaces used
#      to give every row `browser`, including the plain command-line ones.
#
# ZERO SPEND: a PATH shim fakes both engines and counts every call; the count is
# asserted at the end.
#
# Usage: bash tests/lcars-xo-uncontracted.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
LOGS_PY="$REPO_ROOT/skills/lcars-xo/xo-logs.py"
CRITERIA_PY="$REPO_ROOT/skills/lcars-xo/xo-criteria.py"
SCORE_PY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
DRIVE_JS="$REPO_ROOT/skills/lcars-xo/xo-drive.js"
LIVE_CHECK="$REPO_ROOT/skills/lcars-run/live-check"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND: a shim that fakes BOTH engines and counts every call -------
SHIM="$TMPROOT/shim"; mkdir -p "$SHIM"
export SPEND_LOG="$TMPROOT/spend.log"
: >"$SPEND_LOG"
for eng in claude copilot; do
  cat >"$SHIM/$eng" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$eng" "\$*" >>"$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

echo "lcars xo — AN UNCONTRACTED FINDING, THE CHECKLISTS, THE LINK TARGET, THE ONE SURFACE"

RS=$'\x1f'

# ===========================================================================
# THE RIG for cure 1 — a verdict, a criteria.json and a shots dir on disk.
# ===========================================================================
C1="$TMPROOT/c1"; mkdir -p "$C1/shots" "$C1/logs"
cat >"$C1/criteria.json" <<'CJ'
{"criteria": [
  {"id": "prd-1", "text": "notes add stores the title it was given",
   "source": "prd", "impact": "high"}
]}
CJ
printf 'usage: notes [add|list]\n' >"$C1/shots/01-help.txt"
printf 'the footer\n'              >"$C1/shots/07-footer.txt"

# A CONTRACTED gap (the control) and an UNCONTRACTED finding (the cure), in one
# verdict, so the two lanes are measured against each other on one input.
cat >"$C1/verdict.json" <<'VJ'
{"score": "medium",
 "recommendation": "send-back",
 "because": "the one criterion the captain wrote down is contradicted",
 "summary": "I ran the CLI and read what it printed.",
 "criteria": [
   {"id": "prd-1", "text": "notes add stores the title it was given",
    "impact": "high", "status": "gap", "evidence": "transcript",
    "checkedBy": "cli", "shot": "01-help.txt",
    "sawInstead": "a record with an empty title",
    "note": "I added nonce-7 and listed it back with no title",
    "action": "Ran notes.py add then notes.py list."}
 ],
 "gaps": [
   {"title": "add stores no title", "expected": "the title it was given",
    "saw": "a record with an empty title", "shots": ["01-help.txt"],
    "kind": "contradiction", "criterion": "prd-1"}
 ],
 "blockers": [{"id": "prd-1", "evidence": "transcript"}],
 "volunteered": [
   {"title": "the footer links to a second host",
    "expected": "the footer link to point at the host the page prints",
    "saw": "the page prints relay.example and the footer href is github.com",
    "shots": ["07-footer.txt"], "evidence": "transcript", "checkedBy": "cli",
    "note": "nothing the captain wrote down covers the footer"}
 ],
 "escalations": [], "alsoChecked": [], "couldNot": []}
VJ

# The SAME verdict with the volunteered lane empty — the control that proves
# nothing extra is filed when there is nothing volunteered.
"$PY" - "$C1/verdict.json" "$C1/verdict-none.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["volunteered"] = []
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF

run_logs() { # <verdict> <outdir>
  mkdir -p "$2"
  "$PY" "$LOGS_PY" "$1" "$C1/criteria.json" "$2" "$C1/shots" 2>/dev/null
}

echo ""
echo "1. CURE 1 — an uncontracted finding is FILED, and marked as nobody's ask"

PLAN_BOTH="$(run_logs "$C1/verdict.json" "$C1/logs-both")"
PLAN_NONE="$(run_logs "$C1/verdict-none.json" "$C1/logs-none")"

gap_lines() { printf '%s\n' "$1" | grep -c "^GAP" || true; }

check "1a. THE BEHAVIOUR — two bugs are filed, the contracted gap AND the volunteered find" \
  '[ "$(gap_lines "$PLAN_BOTH")" = "2" ]'
check "1b. CONTROL — with nothing volunteered, exactly the ONE contracted gap files" \
  '[ "$(gap_lines "$PLAN_NONE")" = "1" ]'
check "1c. the contracted gap is STILL bug #1, byte for byte as before" \
  'printf "%s\n" "$PLAN_BOTH" | grep "^GAP${RS}1${RS}" >/dev/null &&
   [ "$(printf "%s\n" "$PLAN_BOTH" | grep "^GAP${RS}1${RS}" | cut -d"$RS" -f5)" = "prd-1" ]'
check "1d. the contracted bug's PRD is IDENTICAL to the run with no volunteered find" \
  'cmp -s "$C1/logs-both/1.md" "$C1/logs-none/1.md"'
check "1e. the volunteered find is filed SECOND — after every contracted gap" \
  '[ -f "$C1/logs-both/2.md" ]'
check "1f. its title says plainly that nobody asked for it" \
  'grep -qi "not asked for" "$C1/logs-both/2.md"'
check "1g. its criterion id is NOT a criterion of the record" \
  '[ "$(printf "%s\n" "$PLAN_BOTH" | grep "^GAP${RS}2${RS}" | cut -d"$RS" -f5)" != "prd-1" ]'
check "1h. it carries its EVIDENCE, like any gap" \
  'grep -q "07-footer.txt" "$C1/logs-both/2.md"'
check "1i. it says in the PRD that no criterion covers it" \
  'tr "\n" " " <"$C1/logs-both/2.md" | tr -s " " | grep -qi "no criterion"'
check "1j. it says it did NOT move the grade or the recommendation" \
  'tr "\n" " " <"$C1/logs-both/2.md" | tr -s " " | grep -qi "did not change the grade"'
check "1k. it is a lower severity than a contracted gap, and says which" \
  'grep -qi "lower severity" "$C1/logs-both/2.md"'
check "1l. the volunteered bug is NOT presented as a send-back driver" \
  '! grep -qi "send-back" "$C1/logs-both/2.md"'
# THE FENCE ON THE SEND-BACK, MEASURED. `xo-filed.py` prints the send-back
# sentence from the mission ids the filer hands it; a volunteered bug named in
# that sentence is exactly "a volunteered finding became the verdict".
# AND THE RECORD SHAPE IS UNCHANGED. `xo.sh` splits a GAP record with SEVEN
# `read` names and bash gives the LAST name everything left over, so an EIGHTH
# field lands inside the attachment list and every attachment is silently lost.
# Measured: an earlier cut of this cure added a lane field and cost B12a and three
# B18 checks in `lcars-xo`. The volunteered lane is recorded in the criterion id,
# not in a field.
check "1m. a volunteered GAP record still has EXACTLY seven fields" \
  '[ "$(printf "%s\n" "$PLAN_BOTH" | grep "^GAP${RS}2${RS}" | tr -cd "$RS" | wc -c | tr -d " ")" = "6" ]'
check "1n. …and so does the contracted one" \
  '[ "$(printf "%s\n" "$PLAN_BOTH" | grep "^GAP${RS}1${RS}" | tr -cd "$RS" | wc -c | tr -d " ")" = "6" ]'
check "1n2. the volunteered id carries the lane, under the name both halves share" \
  'grep -q "VOL_ID_PREFIX" "$LOGS_PY" &&
   printf "%s\n" "$PLAN_BOTH" | grep "^GAP${RS}2${RS}" | cut -d"$RS" -f5 | grep -q "^volunteered-"'
# THE FENCE ITSELF — measured on the real stamper, with BOTH bugs handed to it
# exactly as the filer hands them over.
check "1o. THE BEHAVIOUR — handed both bugs, the send-back names only the contracted one" \
  'cp "$C1/verdict.json" "$C1/v-both.json";
   out="$("$PY" "$REPO_ROOT/skills/lcars-xo/xo-filed.py" "$C1/v-both.json" lcars-p \
            prd-1=lcars-kid-1 volunteered-1=lcars-kid-2 2>/dev/null)";
   printf "%s" "$out" | grep -q "goes back for 1 bug" &&
     printf "%s" "$out" | grep -q "lcars-kid-1" &&
     ! printf "%s" "$out" | grep -q "lcars-kid-2"'
check "1o2. …and it stamps filedAs on the contracted row only" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d[\"blockers\"][0].get(\"filedAs\")==\"lcars-kid-1\", d[\"blockers\"]
for v in d.get(\"volunteered\") or []:
    assert \"filedAs\" not in v, v
" "$C1/v-both.json"'
# S257 — THE GUARD SAYS WHAT IT MEANS NOW. It was `git diff --quiet` on
# xo.sh, which asserted "S251 did not need to edit this file" and so broke the
# moment any LATER session edited xo.sh for an unrelated reason (S257 added the
# per-round entry url there). The INTENT is the lane fence: the volunteered
# lane is read in the FILER and nowhere else, and the shell must never learn
# the word. That is what is checked, and it cannot rot.
check "1o3. the lane fence lives in the filer, not the shell — xo.sh never names it" \
  '! grep -q "volunteered" "$REPO_ROOT/skills/lcars-xo/xo.sh"'
check "1p. CONTROL — the send-back sentence, given only the contract lane, names ONE bug" \
  'cp "$C1/verdict.json" "$C1/verdict-filed.json";
   out="$("$PY" "$REPO_ROOT/skills/lcars-xo/xo-filed.py" "$C1/verdict-filed.json" lcars-p \
            prd-1=lcars-kid-1 2>/dev/null)";
   printf "%s" "$out" | grep -q "goes back for 1 bug" &&
     ! printf "%s" "$out" | grep -q "lcars-kid-2"'

# THE INVARIANT, MEASURED ON THE SCORER ITSELF. A volunteered find reaches
# `xo-logs.py`; it must reach NOTHING that decides a grade.
echo ""
echo "2. CURE 1's INVARIANT — the grade and the recommendation do not move"

check "2a. xo-score.py never reads a volunteered lane" \
  '! grep -q "volunteered" "$SCORE_PY"'
check "2b. xo-criteria.py never reads it either — it is not a criterion" \
  '! grep -q "volunteered" "$CRITERIA_PY"'
check "2c. and the filer leaves the verdict's own grade and recommendation alone" \
  '"$PY" -c "
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
assert a[\"score\"]==b[\"score\"], (a[\"score\"],b[\"score\"])
assert a[\"recommendation\"]==b[\"recommendation\"]
assert a[\"blockers\"]==b[\"blockers\"]
" "$C1/verdict.json" "$C1/verdict-none.json"'

# ===========================================================================
# CURE 2 — the checklists, measured on the ASSEMBLED PROMPT
# ===========================================================================
echo ""
echo "3. CURE 2 — the live-check checklists are in Number One's own hand"

repo="$TMPROOT/repo"; mkdir -p "$repo"
( cd "$repo" && git init -q -b main && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf 'x\n' >"$repo/f.txt"
( cd "$repo" && git add -A && git commit -qm init ) >/dev/null 2>&1
mkdir -p "$repo/.git/lcars/missions/lcars-1/xo"
cat >"$repo/.git/lcars/config.json" <<'CJ'
{"cloneId": "a", "model": "claude-sonnet", "projectName": "r",
 "testCommand": "true", "numberOne": {"enabled": true, "engine": "copilot"},
 "created": "2026-05-30T00:00:00Z"}
CJ
cat >"$repo/.git/lcars/missions/lcars-1/state.json" <<'SJ'
{"id": "lcars-1", "type": "feature", "title": "T", "stage": "verify",
 "branch": "main", "created": "2026-10-04T10:00:00Z"}
SJ
printf '# p\n' >"$repo/.git/lcars/missions/lcars-1/prd.md"

DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

prompt_for() { # <input-dir> <out-prompt> [mode]
  ( cd "$repo" && XO_PROMPT_DUMP="$2" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$1" LCARS_GH_BIN=/usr/bin/true \
      bash "$RUNSH" spawn-number-one --mission lcars-1 \
        --mode "${3:-evaluate}" --outdir "$TMPROOT/out-$$-$RANDOM" ) >/dev/null 2>&1
}

IN_CLI="$TMPROOT/in-cli"; mkdir -p "$IN_CLI"
printf '%s\n' '{"productTypes": [{"type": "cli", "source": "the plan"}],
 "criteria": [{"id": "prd-1", "text": "x"}]}' >"$IN_CLI/criteria.json"
P_CLI="$TMPROOT/prompt-cli.txt"
prompt_for "$IN_CLI" "$P_CLI"

check "3a. the prompt was captured at all" '[ -s "$P_CLI" ]'
check "3b. the CLI checklist file goes over WHOLE, named" \
  'grep -qF "live-check/cli.md" "$P_CLI"'
check "3c. …and item 4, two actors — one of the three classes it skipped" \
  'grep -qF "Two actors" "$P_CLI"'
check "3d. …and item 5, the identities that usually coincide" \
  'grep -qiF "usually coincide" "$P_CLI"'
check "3e. …and item 7, the host of every outbound call" \
  'grep -qiF "host of every outbound call" "$P_CLI"'
check "3f. THE CURE — it is told to work the numbered items IN ORDER, not from memory" \
  'tr "\n" " " <"$P_CLI" | tr -s " " | grep -qi "in the order they are numbered"'
check "3g. …and to SAY which numbered item it did not do, rather than go quiet" \
  'tr "\n" " " <"$P_CLI" | tr -s " " | grep -qi "say which numbered item"'
check "3h. CONTROL — a web-only record does NOT get the CLI checklist" \
  'IN_W="$TMPROOT/in-web"; mkdir -p "$IN_W";
   printf "%s\n" "{\"productTypes\": [{\"type\": \"web\", \"source\": \"the plan\"}], \"criteria\": []}" >"$IN_W/criteria.json";
   prompt_for "$IN_W" "$TMPROOT/prompt-web.txt";
   grep -qF "live-check/web.md" "$TMPROOT/prompt-web.txt" &&
     ! grep -qF "live-check/cli.md" "$TMPROOT/prompt-web.txt"'
check "3i. CONTROL — the answer mode gets no checklists at all" \
  'prompt_for "$IN_CLI" "$TMPROOT/prompt-answer.txt" answer;
   ! grep -qF "live-check/cli.md" "$TMPROOT/prompt-answer.txt"'
check "3j. AND THE OTHER HALF OF CURE 1 — the worker is told it can file what nobody asked for" \
  'tr "\n" " " <"$P_CLI" | tr -s " " | grep -qi "volunteered"'
check "3k. …and told plainly that doing so does not send his work back" \
  'tr "\n" " " <"$P_CLI" | tr -s " " | grep -qi "never a send-back"'
check "3l. the ONE mechanism S247 deleted stays deleted — no record-derived templater" \
  '! grep -q "reachUninstantiated\|oneLineFix" "$RUNSH" &&
   ! grep -rq "LCARS_XO_TEMPLATER" "$REPO_ROOT/skills"'
check "3m. evaluate.md is still under its ceiling" \
  '[ "$(wc -l <"$REPO_ROOT/skills/lcars-xo/prompts/evaluate.md" | tr -d " ")" -lt 689 ]'

# ===========================================================================
# CURE 3 — the link target is recorded
# ===========================================================================
echo ""
echo "4. CURE 3 — href and src are in the browser readout"

check "4a. THE BEHAVIOUR — the readout records each element's href" \
  'grep -q "href:" "$DRIVE_JS"'
check "4b. …and its src" \
  'grep -q "src:" "$DRIVE_JS"'
# THE REAL MEASUREMENT: run the element-readout expression against a DOM, with
# no browser — a tiny stand-in for the handful of DOM calls it makes.
check "4c. THE MEASUREMENT — href and src sit INSIDE the per-element record, not loose in the file" \
  '"$PY" -c "
import sys
src = open(sys.argv[1], encoding=\"utf-8\").read()
i = src.index(\"elements.push({\")
j = src.index(\"elementsNote\", i)
blk = src[i:j]
assert \"href:\" in blk, \"no href in the element record\"
assert \"src:\" in blk, \"no src in the element record\"
# AND IT IS THE ATTRIBUTE AS THE PAGE WROTE IT, never a resolved guess.
assert \"getAttribute(\\\"href\\\")\" in blk, blk[:200]
" "$DRIVE_JS"'
check "4d. CONTROL — the readout file still parses with nothing changed about url/title" \
  'grep -q "url: location.href" "$DRIVE_JS" && grep -q "title: document.title" "$DRIVE_JS"'
check "4e. CONTROL — xo-drive.js is still syntactically whole" \
  'node --check "$DRIVE_JS"'

# ===========================================================================
# CURE 4 — the one-surface rule, guarded on there being one
# ===========================================================================
echo ""
echo "5. CURE 4 — the milestone's ONE surface, only when it HAS one"

reach_of() { # <types-csv> — prints "<reachVia> <whyThatReach>"
  "$PY" - "$CRITERIA_PY" "$1" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("xc", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
types = [{"type": t, "source": "the plan"} for t in sys.argv[2].split(",") if t]
# A plain criterion: no reachVia, no ticket, no drawnAt, no notVisual. The ONLY
# rule that can answer it is rule 4.
crit = {"id": "prd-1", "text": "the CLI stores the title it was given"}
via, why = m.reach_for(crit, types, {}, {})
print(via); print(why)
PYEOF
}

R_CLI="$(reach_of cli)"
R_WEB="$(reach_of web)"
R_WF="$(reach_of workflow)"
R_THREE="$(reach_of web,cli,workflow)"
R_TWO="$(reach_of web,cli)"
R_NONE="$(reach_of "")"

check "5a. CONTROL — a CLI-only milestone still gets cli" \
  '[ "$(printf "%s\n" "$R_CLI" | head -1)" = "cli" ]'
check "5b. CONTROL — a web-only milestone still gets browser" \
  '[ "$(printf "%s\n" "$R_WEB" | head -1)" = "browser" ]'
check "5c. CONTROL — a workflow-only milestone still gets workflow" \
  '[ "$(printf "%s\n" "$R_WF" | head -1)" = "workflow" ]'
check "5d. THE BEHAVIOUR — three surfaces no longer hand a plain CLI row browser" \
  '[ "$(printf "%s\n" "$R_THREE" | head -1)" != "browser" ]'
check "5e. …it says instead that the record does not settle it" \
  '[ "$(printf "%s\n" "$R_THREE" | head -1)" = "none" ]'
check "5f. TWO surfaces are not one either" \
  '[ "$(printf "%s\n" "$R_TWO" | head -1)" != "browser" ]'
check "5g. CONTROL — no surface recorded is unchanged: still none" \
  '[ "$(printf "%s\n" "$R_NONE" | head -1)" = "none" ]'
check "5h. the rule's own comment no longer promises a guard it does not have" \
  '"$PY" -c "
import sys
src = open(sys.argv[1], encoding=\"utf-8\").read()
i = src.index(\"4. THE MILESTONE\")
blk = src[i:i+2400]
assert \"len(\" in blk or \"== 1\" in blk, blk[:300]
" "$CRITERIA_PY"'

printf '\n  \033[1m%d pass, %d fail\033[0m\n' "$pass" "$fail"
SPEND="$(wc -l <"$SPEND_LOG" | tr -d ' ')"
printf '  shim invocations: %s\n' "$SPEND"
check "ZERO SPEND — no faked engine CLI was ever invoked" '[ "$SPEND" = "0" ]'
[ "$SPEND" = "0" ] || sed 's/^/    shim| /' "$SPEND_LOG"
printf '\nlcars-xo-uncontracted: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
