#!/usr/bin/env bash
# tests/lcars-xo-near-miss.test.sh — S258.
#
# WHAT WAS MEASURED, AND WHAT WAS NOT. The four prompt files already tell the
# reviewer to OPERATE the product: `evaluate.md` says "move the way a person
# does: `click`, `type`", requires a record of which control was clicked, and
# states that only an ACTION can settle a `works` criterion. So nothing here
# adds an operate-it clause — that would be adding what is there and claiming
# it. What was genuinely absent is the NEGATIVE half: `near miss` / `near-miss`
# had ZERO hits across all four files, and play/game appeared only as examples
# of judgement, never as an instruction to take a rules-driven thing through the
# paths its own rules say must REFUSE or LOSE. One fault (G2 of nine planted) has
# never been found by anybody, and it is the one that can only be reached that
# way: every reviewer verified the rule by SATISFYING it.
#
# So:
#   1. THE NEGATIVE-RULE CLAUSE — a stated rule is verified by BREAKING it; try
#      the input that is almost right and must be refused; reach an ending the
#      rules call a loss or a refusal. It NAMES NO FAULT: a clause that names a
#      plant proves nothing, so the forbidden words are asserted ABSENT from the
#      clause itself (`repeat`, `permutation`, `score`, `reset`, `limit`).
#   2. THE VOLUNTEERED LANE IS OFFERED IN THE SAME BREATH — breaking a rule is
#      how you meet a fault nobody wrote a criterion for. Prompt text only: the
#      lane stays structurally unable to move the grade, and `xo-score.py` must
#      never learn the word (re-asserted below; owned by lcars-xo-uncontracted).
#
# AND IT IS ASSERTED ON THE ASSEMBLED PROMPT, NOT THE TEMPLATE. The claim that
# "the checklists never reach Number One" came from grepping a template; the
# seam is `run.sh spawn-number-one` → `spawn_number_one` → `spawn_worker`, whose
# $5 to the worker adapter IS the prompt the worker is handed. A stub adapter
# dumps that argument. Every assertion is paired with a MUTATION — the same
# assembled-prompt check against a prompts dir with the clause stripped (or with
# a forbidden word injected) — which must FAIL, so none of them can pass
# vacuously.
#
# ZERO SPEND: a PATH shim fakes both engines and counts every call; the count is
# asserted at the end.
#
# Usage: bash tests/lcars-xo-near-miss.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNSH="$REPO_ROOT/skills/lcars-run/run.sh"
PROMPTS="$REPO_ROOT/skills/lcars-xo/prompts"
SCORE_PY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
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
printf '%s %s\n' "$eng" "\$*" >>"\$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$eng"
done
export PATH="$SHIM:$PATH"

# --- the repo the prompt is assembled in -----------------------------------
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
 "branch": "main", "created": "2026-10-06T10:00:00Z"}
SJ
printf '# p\n' >"$repo/.git/lcars/missions/lcars-1/prd.md"

IN="$TMPROOT/in"; mkdir -p "$IN"
criteria_for() { # <product-type>
  printf '%s\n' "{\"productTypes\": [{\"type\": \"$1\", \"source\": \"the plan\"}],
 \"criteria\": [{\"id\": \"prd-1\", \"text\": \"x\"}]}" >"$IN/criteria.json"
}
criteria_for cli

# --- THE SEAM: the adapter is handed the assembled prompt as $5 -------------
DUMP="$TMPROOT/dump.sh"
cat >"$DUMP" <<'AD'
#!/usr/bin/env bash
printf '%s' "${5:-}" >"$XO_PROMPT_DUMP"
exit 0
AD
chmod +x "$DUMP"
WORKER="$TMPROOT/w"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORKER"; chmod +x "$WORKER"

prompt_for() { # <out-prompt> <mode> [prompts-dir]
  ( cd "$repo" && XO_PROMPT_DUMP="$1" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot \
      LCARS_WORKER_HANG_SECS=0 LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true \
      LCARS_XO_PROMPTS="${3:-$PROMPTS}" \
      bash "$RUNSH" spawn-number-one --mission lcars-1 \
        --mode "$2" --outdir "$TMPROOT/out-$$-$RANDOM" ) >/dev/null 2>&1
}

# A mutated copy of the prompts dir: every line of the clause GONE. Each
# assertion below is run against this too, where it must FAIL — that is the
# proof none of them is passing on something that was already in the file.
mutate() { # <dir> <python-mutation-of-the-text>
  local d="$1" expr="$2" f
  mkdir -p "$d"
  cp "$PROMPTS"/*.md "$d"/
  for f in evaluate.md recheck.md; do
    "$PY" - "$d/$f" "$expr" <<'PYM'
import re, sys
p, mode = sys.argv[1], sys.argv[2]
text = open(p, encoding="utf-8").read()
paras = text.split("\n\n")
anchor = "a rule you only ever"
anchor2 = "rule's fix is held only when"
keep = []
for para in paras:
    low = para.lower()
    if mode == "strip" and (anchor in low or anchor2 in low):
        continue
    if mode == "inject" and (anchor in low or anchor2 in low):
        para = para + " The score must reset to zero."
    keep.append(para)
open(p, "w", encoding="utf-8").write("\n\n".join(keep))
PYM
  done
}

STRIPPED="$TMPROOT/prompts-stripped"; mutate "$STRIPPED" strip
INJECTED="$TMPROOT/prompts-injected"; mutate "$INJECTED" inject

P_EV="$TMPROOT/prompt-evaluate.txt";       prompt_for "$P_EV" evaluate
P_RE="$TMPROOT/prompt-recheck.txt";        prompt_for "$P_RE" recheck
P_EV_S="$TMPROOT/prompt-evaluate-str.txt"; prompt_for "$P_EV_S" evaluate "$STRIPPED"
P_RE_S="$TMPROOT/prompt-recheck-str.txt";  prompt_for "$P_RE_S" recheck "$STRIPPED"
P_EV_I="$TMPROOT/prompt-evaluate-inj.txt"; prompt_for "$P_EV_I" evaluate "$INJECTED"
P_WEB="$TMPROOT/prompt-web.txt";         criteria_for web; prompt_for "$P_WEB" evaluate
P_WORK="$TMPROOT/prompt-workflow.txt";   criteria_for workflow; prompt_for "$P_WORK" evaluate
criteria_for cli

# `tr` the newlines away first: the prompt files wrap at ~78 columns, so every
# phrase worth asserting on is split across lines in the artefact.
flat() { tr '\n' ' ' <"$1" | tr -s ' '; }
says() { flat "$1" | grep -qi -- "$2"; }
occurs() { flat "$1" | grep -oEi -- "$2" | wc -l | tr -d ' '; }

echo "1. THE ASSEMBLED PROMPT — captured at the seam, not read off a template"
check "1a. the evaluate prompt was captured at all" '[ -s "$P_EV" ]'
check "1b. the recheck prompt was captured at all" '[ -s "$P_RE" ]'
check "1c. it IS the assembled artefact — it carries the template AND the round's own block" \
  'says "$P_EV" "You are Number One" && says "$P_EV" "## The mission" &&
   says "$P_EV" "Your output file"'
check "1d. CONTROL — the mutation harness really did reach the same seam" \
  '[ -s "$P_EV_S" ] && [ -s "$P_RE_S" ]'

echo ""
echo "2. THE NEGATIVE-RULE CLAUSE reaches the worker"
check "2a. a rule you only ever satisfied is a rule you have not tested" \
  'says "$P_EV" "a rule you only ever satisfied is a rule you have not tested"'
check "2b. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "a rule you only ever satisfied is a rule you have not tested"'
check "2c. a stated rule is verified by BREAKING it" \
  'says "$P_EV" "verified by breaking it"'
check "2d. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "verified by breaking it"'
check "2e. the input that is ALMOST right and must be refused" \
  'says "$P_EV" "almost right and must be refused"'
check "2e2. …and the thing it is asking for is NAMED — the near miss" \
  'says "$P_EV" "ask for the near miss" && says "$P_RE" "but the near miss turned away"'
check "2e3. MUTATION — stripping the clause removes one named near miss" \
  '[ "$(occurs "$P_EV" "near.miss")" -gt "$(occurs "$P_EV_S" "near.miss")" ] &&
   [ "$(occurs "$P_RE" "near.miss")" -gt "$(occurs "$P_RE_S" "near.miss")" ]'
check "2f. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "almost right and must be refused"'
check "2g. …and what happened is RECORDED whichever way it went" \
  'says "$P_EV" "record what happened either way"'
check "2h. MUTATION — stripping the clause removes one recording instruction" \
  '[ "$(occurs "$P_EV" "record what happened either way")" -gt "$(occurs "$P_EV_S" "record what happened either way")" ]'
check "2i. a refusal that never came is a gap; one you never asked for is untested" \
  'says "$P_EV" "a refusal that never came is a gap" && says "$P_EV" "is .untested."'
check "2j. MUTATION — that assertion fails with the clause stripped" \
  '! says "$P_EV_S" "a refusal that never came is a gap"'
check "2k. THE OTHER HALF — reach an ending the rules call a LOSS or a REFUSAL" \
  'says "$P_EV" "a loss or a refusal"'
check "2l. …and not only the winning one" \
  'says "$P_EV" "not only the winning one"'
check "2m. MUTATION — stripping the clause removes one copy of both instructions" \
  '[ "$(occurs "$P_EV" "a loss or a refusal")" -gt "$(occurs "$P_EV_S" "a loss or a refusal")" ] &&
   [ "$(occurs "$P_EV" "not only the winning one")" -gt "$(occurs "$P_EV_S" "not only the winning one")" ]'

echo ""
echo "3. IT NAMES THE SHAPE AND NEVER A FAULT"
# A clause that names a planted fault proves nothing about reach. So the clause
# ITSELF — the paragraph, cut out of the assembled prompt — is read back and
# checked for the words that would give one away. The whole prompt cannot be
# checked this way (it talks about scores and round limits everywhere, properly),
# which is exactly why the unit of the check is the paragraph.
CLAUSE_PY="$TMPROOT/clause.py"
cat >"$CLAUSE_PY" <<'PYC'
import sys
BANNED = ("repeat", "permutation", "score", "reset", "limit")
text = open(sys.argv[1], encoding="utf-8").read()
anchor = sys.argv[2].lower()
paras = text.split("\n\n")
hit = [p for p in paras if anchor in p.lower()]
if not hit:
    print("NO-CLAUSE")
    sys.exit(0)
clause = "\n\n".join(hit)
if len(sys.argv) > 3 and sys.argv[3] == "--show":
    print(clause)
    sys.exit(0)
named = sorted({w for w in BANNED if w in clause.lower()})
print("NAMES:" + ",".join(named) if named else "clean")
PYC
check "3a. the clause is FOUND in the assembled prompt as its own paragraph" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_EV" "a rule you only ever")" != NO-CLAUSE ]'
check "3b. THE FENCE — the clause names none of repeat/permutation/score/reset/limit" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_EV" "a rule you only ever")" = clean ]'
check "3c. MUTATION — the fence FIRES when a fault word is injected into the clause" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_EV_I" "a rule you only ever")" = "NAMES:reset,score" ]'
check "3d. …and the recheck mirror names none of them either" \
  '[ "$("$PY" "$CLAUSE_PY" "$P_RE" "fix is held only when the rule now")" = clean ]'
check "3e. and no prompt file has learned the word near-miss by naming a plant" \
  '! grep -qiE "repeated digit|permutation|does not reset|score reset" "$PROMPTS"/*.md'

echo ""
echo "4. THE MIRROR — the re-check reads a rule's fix the same way"
check "4a. a rule's fix is held only when the rule now REFUSES" \
  'says "$P_RE" "held only when the rule now refuses"'
check "4b. …a picture of the right input working is not the fix holding" \
  'says "$P_RE" "is not the fix holding"'
check "4c. …nothing settles it but the almost-right input being refused" \
  'says "$P_RE" "almost right input being refused"'
check "4d. MUTATION — all three fail with the mirror stripped" \
  '! says "$P_RE_S" "held only when the rule now refuses" &&
   ! says "$P_RE_S" "is not the fix holding" &&
   ! says "$P_RE_S" "almost right input being refused"'
check "4e. CONTROL — the recheck round still has its own job, unchanged" \
  'says "$P_RE" "say whether its fix HOLDS" && says "$P_RE" "Do not open new findings"'

echo ""
echo "5. THE VOLUNTEERED LANE IS OFFERED — and still cannot move the grade"
check "5a. the worker is told the lane is WELCOME, in the breath that tells it to break a rule" \
  'says "$P_EV" "is welcome"'
check "5b. MUTATION — that fails with the clause stripped, so it is not S251's block answering for it" \
  '! says "$P_EV_S" "is welcome"'
check "5c. …said as a fault nobody wrote a criterion for" \
  'says "$P_EV" "a fault nobody wrote a criterion for"'
check "5d. MUTATION — that fails with the clause stripped too" \
  '! says "$P_EV_S" "a fault nobody wrote a criterion for"'
check "5e. …and in the same breath, that it can never move the grade" \
  'says "$P_EV" "never move your grade"'
check "5f. MUTATION — that fails with the clause stripped" \
  '! says "$P_EV_S" "never move your grade"'
check "5g. CONTROL — S251's own lane block is still there and still says what it said" \
  'says "$P_EV_S" "volunteered" && says "$P_EV_S" "never a send-back"'
check "5h. THE FENCE HOLDS — the scorer has still never heard the word" \
  '! grep -q "volunteered" "$SCORE_PY"'
check "5i. …and neither has the shell that drives the look" \
  '! grep -q "volunteered" "$REPO_ROOT/skills/lcars-xo/xo.sh"'

echo ""
echo "6. THE TRADE THAT PAID FOR IT"
# evaluate.md is held under 689 lines by three other suites, on purpose: a fact
# about one round's inputs belongs in run.sh, not in the template. The clause was
# paid for out of the file, not added on top of it.
check "6a. evaluate.md is still under its 689-line ceiling" \
  '[ "$(grep -c "" "$PROMPTS/evaluate.md")" -lt 689 ]'
check "6b. the per-round pre-launch fact is said by the ROUND, not by the template" \
  '! grep -qi "round before anything is served" "$PROMPTS/evaluate.md" &&
   says "$P_EV" "live-check/cli.md"'
check "6c. …and the round that IS before the launch still says it, whole" \
  '( cd "$repo" && XO_PROMPT_DUMP="$TMPROOT/prompt-pre.txt" LCARS_WORKER_ADAPTER="$DUMP" \
      LCARS_WORKER_BIN="$WORKER" LCARS_WORKER_CLI=copilot LCARS_WORKER_HANG_SECS=0 \
      LCARS_XO_INPUT_DIR="$IN" LCARS_GH_BIN=/usr/bin/true LCARS_XO_PRELAUNCH=1 \
      bash "$RUNSH" spawn-number-one --mission lcars-1 --mode evaluate \
        --outdir "$TMPROOT/out-pre" ) >/dev/null 2>&1;
   says "$TMPROOT/prompt-pre.txt" "THIS ROUND IS BEFORE THE LAUNCH" &&
   says "$TMPROOT/prompt-pre.txt" "asked ONCE for a different"'

echo ""
echo "7. ALL THREE LIVE-CHECK NEAR-MISS ITEMS REACH THE ASSEMBLED PROMPT"
LIVE_CHECK_PY="$TMPROOT/live-check-items.py"
cat >"$LIVE_CHECK_PY" <<'PYC'
import re, sys

text = open(sys.argv[1], encoding="utf-8").read()
headings = (
    "Break a CLI rule with the near miss",
    "Break a page rule with the near miss",
    "Break a workflow rule with the near miss",
)
items = []
for heading in headings:
    match = re.search(
        rf"^### \d+\. {re.escape(heading)}\n.*?(?=^---$|^### \d+\. |\Z)",
        text,
        re.MULTILINE | re.DOTALL,
    )
    if match:
        items.append(match.group(0))

mode = sys.argv[2]
if mode == "count":
    print(len(items))
elif mode == "near-miss":
    print("yes" if any(re.search(r"near miss", item, re.I) for item in items) else "no")
elif mode == "forbidden":
    forbidden = ("repeat", "permutation", "score", "reset", "limit", "duplicate", "collision")
    found = sorted({word for item in items for word in forbidden if re.search(rf"\b{word}\b", item, re.I)})
    print(",".join(found) if found else "clean")
PYC
check "7a. near miss appears inside an assembled live-check checklist item" \
  '[ "$("$PY" "$LIVE_CHECK_PY" "$P_EV" near-miss)" = yes ]'
check "7b. all three new checklist items are in their assembled prompts" \
  '[ "$("$PY" "$LIVE_CHECK_PY" "$P_EV" count)" -eq 1 ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WEB" count)" -eq 1 ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WORK" count)" -eq 1 ]'
check "7c. the assembled CLI near-miss item is present" \
  'says "$P_EV" "Break a CLI rule with the near miss"'
check "7d. the assembled web near-miss item is present" \
  'says "$P_WEB" "Break a page rule with the near miss"'
check "7e. the assembled workflow near-miss item is present" \
  'says "$P_WORK" "Break a workflow rule with the near miss"'
check "7f. none of the forbidden words appears in the three added items" \
  '[ "$("$PY" "$LIVE_CHECK_PY" "$P_EV" forbidden)" = clean ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WEB" forbidden)" = clean ] &&
   [ "$("$PY" "$LIVE_CHECK_PY" "$P_WORK" forbidden)" = clean ]'

echo ""
echo "8. ZERO SPEND"
check "8a. no faked engine CLI was ever invoked" '[ ! -s "$SPEND_LOG" ]'

echo ""
printf 'lcars-xo-near-miss: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
