#!/usr/bin/env bash
# tests/lcars-xo-handover.test.sh — S272, "the holodeck handover".
#
# THREE MEASURED DEFECTS, each reproduced BY HAND before a line of this was
# written, and each with a known-good CONTROL beside it so the check can detect
# its own breakage.
#
#   1. THE GAPS-LANE SCORER CRASH. `xo-score.py`'s gaps loop read
#      `[str(s) for s in g.get("shots") or [] ...]` — it ITERATED the raw value.
#      MEASURED on this branch, through the real scorer:
#        {"shots": 5}                  -> TypeError: 'int' object is not iterable
#        {"shots": true}               -> TypeError: 'bool' object is not iterable
#        {"shots": {"a": "01-help.png"}} -> silently yielded ['a'], the dict's KEY
#        {"shots": ["01-help.png"]}    -> fine (the control)
#      A crash here writes NO scored file at all, which is the same silence the
#      S263 round closed on the volunteered lane. The cure MIRRORS that lane —
#      `_carried_strings`, the one normaliser — rather than inventing a second
#      convention, and D6 of its comment block is why the map must yield the
#      path INSIDE it and not the key.
#
#      THE SAME CRASH CLASS, ONE SIBLING FURTHER ON: `merge_unlisted` built its
#      citation inventory as `set(str(s).strip() for s in (doc.get("shots") or
#      []) ...)`. MEASURED: an unlisted record carrying `"shots": 5` raised the
#      identical TypeError and the scorer again wrote nothing. A cure applied to
#      one call site while an identical sibling stays raw is a known failure in
#      this repo's ledger, so both are cured and both are measured here.
#
#   2. NOTHING TOLD A BUILDER WHICH PORT IS ALREADY TAKEN. `8765` is the
#      viewscreen's own default and the captain's is normally UP on it. On
#      2026-10-09 a build chose it, the launch died, every browser step was
#      silently dropped, and the reviewer graded the screens on unit tests and
#      recommended MERGE. `launch.sh` deliberately OBSERVES the app's chosen
#      port rather than dictating one, so the fix is not in the harness: it is
#      one line of guidance in the file the BUILDER reads.
#
#   3. TWO COUNTS THE CAPTAIN WAS NEVER SHOWN. `journey.json.unrunSteps` (steps
#      KEPT and never run, because there was no page to run them on) and
#      `looksWithNoPicture` (a looks-question that passed with no photograph)
#      are both produced and both reached the REVIEWER's next prompt — and
#      `xo-score.py` said neither word to the CAPTAIN. A look with 11
#      kept-but-never-run steps read "0 refused, 0 dropped" on his own report.
#      Rendered NON-ZERO ONLY (his explicit call): a healthy review must not
#      grow two permanent noise rows.
#
# EVERY CURE IS PROVED BY A MUTATION THAT GOES RED BY BEHAVIOUR. A grep against
# the source is worthless — a session earlier in this round shipped four cures
# guarded only by greps and the measured bug could be fully restored with the
# suite green. So each control here is THIS branch's own scorer with the cured
# line REVERTED to the raw one it replaced, and the revert is verified to have
# changed something before it is trusted as a control.
#
# ADDITIVE ONLY is measured, not asserted: the two new report lines are proved
# to leave the GRADE, the RECOMMENDATION and the whole ledger byte-identical.
#
# ZERO SPEND: nothing here runs a model. The scorer is a pure function of files
# on disk; a PATH shim fakes both engines and the call count is asserted zero.
#
# Usage: bash tests/lcars-xo-handover.test.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XO="$REPO_ROOT/skills/lcars-xo"
SCORE_PY="$XO/xo-score.py"
VIEWSCREEN_SH="$REPO_ROOT/skills/lcars-viewscreen/viewscreen.sh"
BUILDER_MD="$REPO_ROOT/skills/lcars-run/stages/implement-tdd.md"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- ZERO SPEND -------------------------------------------------------------
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

echo "lcars xo — THE HOLODECK HANDOVER: a crash, a taken port, two unsaid counts"

# ===========================================================================
# THE RIG — one criterion, one real shot on disk, and verdicts that differ in
# exactly ONE thing each, so every control isolates one variable.
# ===========================================================================
R="$TMPROOT/rig"; mkdir -p "$R/shots"
printf 'usage: relay [file|list]\n' >"$R/shots/01-help.png"
cat >"$R/criteria.json" <<'CJ'
{"criteria": [
  {"id": "prd-1", "text": "relay file stores the title it was given",
   "source": "prd", "impact": "high"}
]}
CJ

# A verdict whose ONE gap's `shots` field is whatever shape we hand in.
mkgap() { # <json-literal-for-shots> <out>
  "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
shots = json.loads(sys.argv[1])
json.dump({
  "score": "medium", "recommendation": "send-back",
  "summary": "I ran the CLI and read what it printed.",
  "criteria": [{"id": "prd-1",
                "text": "relay file stores the title it was given",
                "impact": "high", "status": "gap", "evidence": "transcript",
                "checkedBy": "cli", "shot": "01-help.png",
                "sawInstead": "a record with an empty title",
                "note": "I filed nonce-7 and listed it back with no title",
                "action": "Ran relay.py file then relay.py list."}],
  "gaps": [{"title": "file stores no title",
            "expected": "the title it was given",
            "saw": "a record with an empty title", "shots": shots,
            "kind": "contradiction", "criterion": "prd-1"}],
  "escalations": [], "alsoChecked": [], "couldNot": []},
  open(sys.argv[2], "w"), indent=2)
PYEOF
}

# THE SHAPES, each as its own file. Named literally — never through a shell
# variable, which is how this project once produced a false green.
mkgap '["01-help.png"]'          "$R/v-list.json"      # the honest control
mkgap '5'                        "$R/v-int.json"
mkgap 'true'                     "$R/v-bool.json"
mkgap '{"a": "01-help.png"}'     "$R/v-map.json"
mkgap '"01-help.png"'            "$R/v-str.json"

# THE CONTROL SCORERS — this branch's own xo-score.py with ONE cured line
# REVERTED to the raw line it replaced. Not an old git revision: once this
# session is committed a git-revision control would silently become the NEW
# scorer and stop firing.
revert_to_raw() { # <marker> <raw-replacement> <out>
  "$PY" - "$SCORE_PY" "$1" "$2" "$3" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
marker, raw, out = sys.argv[2], sys.argv[3], sys.argv[4]
hits = [ln for ln in src.splitlines() if marker in ln]
if len(hits) != 1:
    sys.stderr.write("REVERT-FAILED %s hits=%d\n" % (marker, len(hits)))
    sys.exit(3)
line = hits[0]
indent = re.match(r"[ \t]*", line).group(0)
open(out, "w", encoding="utf-8").write(src.replace(line, indent + raw))
PYEOF
}

RAW_SCORE="$TMPROOT/raw-gaps-score.py"
revert_to_raw 'S272 GAP SHOTS' \
  'shots = [str(s) for s in g.get("shots") or [] if str(s).strip()]' \
  "$RAW_SCORE"
RAW_UNLISTED="$TMPROOT/raw-unlisted-score.py"
revert_to_raw 'S272 UNLISTED SHOTS' \
  'inventory = set(str(s).strip() for s in (doc.get("shots") or []) if str(s).strip())' \
  "$RAW_UNLISTED"

# EVERY CASE GETS ITS OWN DIRECTORY. `xo-score.py` writes the captain's
# markdown as `report.md` BESIDE its output file, so two cases sharing a
# directory would silently read each other's report — a false green of exactly
# the kind this suite exists to refuse.
score() { # <scorer> <verdict> <case-name> [extra argv...]
  local scorer="$1" verdict="$2" name="$3"; shift 3
  local d="$R/out/$name"
  rm -rf "$d"; mkdir -p "$d"
  "$PY" "$scorer" "$verdict" "$R/criteria.json" "$d/verdict.json" "$@" \
    >"$d/stdout.txt" 2>"$d/stderr.txt" || :
}
sfile() { printf '%s\n' "$R/out/$1/verdict.json"; }
gap_shots() { # <case-name> -> the normalised shots list, JSON, one line
  "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
g = (d.get("gaps") or [{}])[0]
print(json.dumps(g.get("shots")))' "$R/out/$1/verdict.json" 2>/dev/null
}
report_of() { # <case-name> -> the captain-facing markdown
  cat "$R/out/$1/report.md" 2>/dev/null
}
grade_of() { # <case-name> -> grade + recommendation + the whole ledger
  "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps([d.get("score"), d.get("recommendation"),
                  d.get("criteria"), d.get("counts"),
                  d.get("groups"), d.get("questionSplit"),
                  d.get("blockers"), d.get("coverageLine")],
                 sort_keys=True))' "$R/out/$1/verdict.json" 2>/dev/null
}
wrote() { [ -s "$R/out/$1/verdict.json" ]; }
crashed() { grep -qF "object is not iterable" "$R/out/$1/stderr.txt" 2>/dev/null; }

echo ""
echo "1. THE GAPS LANE — a malformed \`shots\` refuses cleanly, an honest one still scores"

score "$SCORE_PY" "$R/v-list.json" cured-list
score "$SCORE_PY" "$R/v-int.json"  cured-int
score "$SCORE_PY" "$R/v-bool.json" cured-bool
score "$SCORE_PY" "$R/v-map.json"  cured-map
score "$SCORE_PY" "$R/v-str.json"  cured-str

# THE CONTROL FIRST — a check whose known-good case does not pass measures nothing.
check "1a. CONTROL — the honest list still scores, and the scorer writes a file" \
  'wrote cured-list'
check "1b. CONTROL — the honest list's shot survives verbatim" \
  '[ "$(gap_shots cured-list)" = "[\"01-help.png\"]" ]'
check "1c. CONTROL — and the captain's report cites it" \
  'report_of cured-list | grep -qF "see 01-help.png"'

check "1d. BEHAVIOUR — \`shots: 5\` no longer crashes the scorer: a file is written" \
  'wrote cured-int'
check "1e. …and the unusable number is refused, not stringified into a path" \
  '[ "$(gap_shots cured-int)" = "[]" ]'
check "1f. BEHAVIOUR — \`shots: true\` no longer crashes the scorer" \
  'wrote cured-bool'
check "1g. …and the bool is refused too" \
  '[ "$(gap_shots cured-bool)" = "[]" ]'
check "1h. D6 — a map on a plural field yields the path INSIDE it" \
  '[ "$(gap_shots cured-map)" = "[\"01-help.png\"]" ]'
check "1i. …and NOT the dict's key, which is what it used to yield" \
  '[ "$(gap_shots cured-map)" != "[\"a\"]" ]'
check "1j. D6 — a bare string on a plural field is taken as the one path" \
  '[ "$(gap_shots cured-str)" = "[\"01-help.png\"]" ]' 

echo ""
echo "2. THE MUTATION — the measured bug, restored, goes RED"

score "$RAW_SCORE" "$R/v-list.json" raw-list
score "$RAW_SCORE" "$R/v-int.json"  raw-int
score "$RAW_SCORE" "$R/v-bool.json" raw-bool
score "$RAW_SCORE" "$R/v-map.json"  raw-map

check "2a. the mutation is REAL — it exists and differs from the cured scorer" \
  '[ -s "$RAW_SCORE" ] && ! cmp -s "$RAW_SCORE" "$SCORE_PY"'
check "2b. the mutation is still a WORKING scorer on the honest input (not just broken)" \
  'wrote raw-list && [ "$(gap_shots raw-list)" = "[\"01-help.png\"]" ]'
check "2c. MUTATION RED — \`shots: 5\` through the raw line writes NO file at all" \
  '! wrote raw-int'
check "2d. MUTATION RED — and it raises the measured TypeError" 'crashed raw-int'
check "2e. MUTATION RED — \`shots: true\` through the raw line writes NO file" \
  '! wrote raw-bool && crashed raw-bool'
check "2f. MUTATION RED — the map silently yielded the KEY through the raw line" \
  '[ "$(gap_shots raw-map)" = "[\"a\"]" ]' 

echo ""
echo "3. THE SIBLING — the unlisted pass's citation inventory, same crash class"

cat >"$R/unlisted-good.json" <<'UJ'
{"findings": [{"what": "the footer overlaps the table",
               "shot": "01-help.png", "why": "it reads as one block"}],
 "shots": ["01-help.png"]}
UJ
cat >"$R/unlisted-int.json" <<'UJ'
{"findings": [{"what": "the footer overlaps the table",
               "shot": "01-help.png", "why": "it reads as one block"}],
 "shots": 5}
UJ
cat >"$R/unlisted-map.json" <<'UJ'
{"findings": [{"what": "the footer overlaps the table",
               "shot": "01-help.png", "why": "it reads as one block"}],
 "shots": {"a": "01-help.png"}}
UJ

ul_score() { # <scorer> <unlisted-doc> <case-name>
  score "$1" "$R/v-list.json" "$3" "" "" "" "" "" "" "$2"
}
has_unlisted() { # <case-name>
  "$PY" -c '
import json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("unlisted") or []
sys.exit(0 if rows and "footer overlaps" in json.dumps(rows) else 1)' \
    "$R/out/$1/verdict.json" 2>/dev/null
}

ul_score "$SCORE_PY"     "$R/unlisted-good.json" ul-good
ul_score "$SCORE_PY"     "$R/unlisted-int.json"  ul-int
ul_score "$SCORE_PY"     "$R/unlisted-map.json"  ul-map
ul_score "$RAW_UNLISTED" "$R/unlisted-good.json" rawul-good
ul_score "$RAW_UNLISTED" "$R/unlisted-int.json"  rawul-int

check "3a. CONTROL — an honest inventory still admits the find it cites" \
  'wrote ul-good && has_unlisted ul-good'
check "3b. BEHAVIOUR — \`shots: 5\` on the unlisted record no longer crashes" \
  'wrote ul-int'
check "3c. …and with no readable inventory the guard stands down, keeping the find" \
  'has_unlisted ul-int'
check "3d. D6 — a map inventory is read for the path inside it, so the find stands" \
  'wrote ul-map && has_unlisted ul-map'
check "3e. the sibling mutation is real and still works on honest input" \
  '! cmp -s "$RAW_UNLISTED" "$SCORE_PY" && wrote rawul-good &&
   has_unlisted rawul-good'
check "3f. MUTATION RED — the raw inventory line writes NO file on \`shots: 5\`" \
  '! wrote rawul-int'
check "3g. MUTATION RED — and it raises the same measured TypeError" \
  'crashed rawul-int' 

echo ""
echo "4. THE PORT A BUILDER MUST NOT TAKE — one line, in the file a builder reads"

# WHY THIS FILE. `implement-tdd.md` is the prompt template `spawn_worker` hands
# the unified TDD worker for every ticket (run.sh: spawn_worker implement-tdd
# "$STAGES_DIR/implement-tdd.md"), so it is literally the text a builder reads
# before it writes a line. HOLOGRAM-COMMAND-MODE.md is the EEH's playbook (a stand-in
# human driving LCARS, never the thing that builds) and the live-check files are
# the REVIEWER's checklists — neither is read by the builder. `launch.sh` is
# untouched on purpose: it OBSERVES the app's chosen port rather than dictating
# one, which is the right behaviour for a factory.
DEFAULT_PORT="$(sed -n 's/^DEFAULT_PORT="\([0-9]*\)".*/\1/p' "$VIEWSCREEN_SH" | head -1)"
check "4a. the viewscreen's own default port is readable from its script" \
  '[ -n "$DEFAULT_PORT" ] && [ "$DEFAULT_PORT" -gt 0 ]'
check "4b. the builder's prompt reserves a port at all" \
  'grep -qiE "port" "$BUILDER_MD"'
check "4c. LOCKSTEP — the port it reserves is the one the viewscreen really defaults to" \
  'grep -qF "$DEFAULT_PORT" "$BUILDER_MD"'
check "4d. it tells the builder to AVOID it, not merely that it exists" \
  'grep -niE "port" "$BUILDER_MD" | grep -qiE "avoid|do not|never|reserved"'
check "4e. launch.sh is NOT the place it was put — the observer stays an observer" \
  '! grep -qF "$DEFAULT_PORT" "$REPO_ROOT/skills/lcars-launch/launch.sh"'
check "4f. and the EEH's playbook was not edited to carry it" \
  '! grep -qF "$DEFAULT_PORT" "$REPO_ROOT/skills/lcars-eeh/HOLOGRAM-COMMAND-MODE.md"'

echo ""
echo "5. THE TWO UNSAID COUNTS — rendered on his report, NON-ZERO ONLY"

# A journey carrying ELEVEN kept-but-never-run steps: the measured shape, from a
# look whose build never came up.
"$PY" - "$R/journey-unrun.json" <<'PYEOF'
import json, sys
rows = [{"kind": "browser", "why": "there was no page to run it on",
         "key": "%02d-screen" % (i + 1), "for": "prd-1", "round": "1"}
        for i in range(11)]
json.dump({"unrunSteps": rows,
           "noPage": "your build did not start - could not start the server"},
          open(sys.argv[1], "w"), indent=2)
PYEOF
# THE CONTROL: the same journey with the list EMPTY — a healthy look.
printf '{"unrunSteps": [], "refusedSteps": [], "droppedSteps": []}\n' \
  >"$R/journey-clean.json"

jscore() { # <scorer> <journey> <case-name>
  score "$1" "$R/v-list.json" "$3" "" "" "" "" "" "" "" "" "" "$2"
}
jscore "$SCORE_PY" "$R/journey-unrun.json" j-unrun
jscore "$SCORE_PY" "$R/journey-clean.json" j-clean

check "5a. CONTROL — the clean journey still scores" 'wrote j-clean'
check "5b. CONTROL — the data this renders from really is on the journey" \
  '[ "$("$PY" -c "
import json,sys
print(len(json.load(open(sys.argv[1])).get(\"unrunSteps\") or []))" \
      "$R/journey-unrun.json")" = 11 ]'
check "5c. BEHAVIOUR — eleven never-run steps are COUNTED on the captain's report" \
  'report_of j-unrun | grep -qE "11 step|11 more step"'
check "5d. …and the harness's own reason is said beside the count" \
  'report_of j-unrun | grep -qF "no page to run it on"'
check "5e. NON-ZERO ONLY — an empty list adds no permanent noise row" \
  '[ "$(report_of j-clean | grep -ciE "never ran|no page to run")" = "0" ]'

# A looks-question that PASSED on the project's own TESTS with no photograph
# behind it. The tests lane is the one route past the EARLIER citation guard (a
# met row with no picture is otherwise already demoted before this check runs),
# so it is the only shape that can reach `looksWithNoPicture` — measured by hand
# on this branch, not assumed.
cat >"$R/tests.json" <<'TJ'
{"ran": true, "outcome": "passed", "command": "npm test",
 "outputTail": "PASS relay stores the title it was given\n1 passing\n",
 "testCases": ["PASS relay stores the title it was given"],
 "truncated": false, "tailCapBytes": 8000}
TJ
"$PY" - "$R/v-looks.json" <<'PYEOF'
import json, sys
json.dump({
  "score": "medium", "recommendation": "send-back",
  "summary": "I ran the CLI and read what it printed.",
  "criteria": [{"id": "prd-1",
                "text": "relay file stores the title it was given",
                "impact": "high", "status": "met", "kind": "looks",
                "evidence": "tests", "checkedBy": "test",
                "testQuote": "PASS relay stores the title it was given",
                "note": "the suite says so"}],
  "gaps": [], "escalations": [], "alsoChecked": [], "couldNot": []},
  open(sys.argv[1], "w"), indent=2)
PYEOF
# THE CONTROL: the identical row WITH a picture. One variable — the shot.
"$PY" - "$R/v-looks.json" "$R/v-looks-ok.json" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["criteria"][0]["shot"] = "01-help.png"
json.dump(d, open(sys.argv[2], "w"), indent=2)
PYEOF

lscore() { # <scorer> <verdict> <case-name>
  score "$1" "$2" "$3" "" "$R/tests.json" "" "" "" "" "" "" "" "" "$R/shots"
}
lscore "$SCORE_PY" "$R/v-looks.json"    l-bare
lscore "$SCORE_PY" "$R/v-looks-ok.json" l-ok

check "5f. CONTROL — the data this renders from is really produced" \
  '"$PY" -c "
import json,sys
rows = json.load(open(sys.argv[1])).get(\"looksWithNoPicture\") or []
sys.exit(0 if any(r.get(\"id\")==\"prd-1\" for r in rows) else 1)" "$(sfile l-bare)"'
check "5g. CONTROL — and the row WITH a picture produces none of it" \
  '"$PY" -c "
import json,sys
rows = json.load(open(sys.argv[1])).get(\"looksWithNoPicture\") or []
sys.exit(0 if not rows else 1)" "$(sfile l-ok)"'
check "5h. BEHAVIOUR — the picture-less looks-question is NAMED on his report" \
  'report_of l-bare | grep -qiE "passed with no picture"'
check "5i. …and its criterion id is on that line so he can find it" \
  'report_of l-bare | grep -iE "passed with no picture" -A6 | grep -qF "prd-1"'
check "5j. NON-ZERO ONLY — the same row WITH a picture adds no such section" \
  '[ "$(report_of l-ok | grep -ciE "passed with no picture")" = "0" ]'

echo ""
echo "6. ADDITIVE ONLY — the two new lines changed no grade, no verdict, no ledger"

RAW_REPORT="$TMPROOT/raw-report-score.py"
# Both new render blocks are stripped by their own BEGIN/END markers, so the
# control is this branch's scorer with EXACTLY the new rendering removed and
# nothing else — never an old git revision, which would stop firing the moment
# this session is committed.
"$PY" - "$SCORE_PY" "$RAW_REPORT" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read().splitlines(True)
out, dropping, n = [], False, 0
for ln in src:
    if "S272 RENDER BEGIN" in ln:
        dropping, n = True, n + 1
        continue
    if "S272 RENDER END" in ln:
        dropping = False
        continue
    if not dropping:
        out.append(ln)
if n != 2:
    sys.stderr.write("STRIP-FAILED blocks=%d\n" % n)
    sys.exit(3)
open(sys.argv[2], "w", encoding="utf-8").write("".join(out))
PYEOF

jscore "$RAW_REPORT" "$R/journey-unrun.json" r-unrun
lscore "$RAW_REPORT" "$R/v-looks.json"       r-bare

check "6a. the render-strip mutation is real and still a working scorer" \
  '! cmp -s "$RAW_REPORT" "$SCORE_PY" && wrote r-unrun && wrote r-bare'
check "6b. MUTATION RED — without the block the eleven never-run steps vanish" \
  '[ "$(report_of r-unrun | grep -ciE "never ran|no page to run")" = "0" ]'
check "6c. MUTATION RED — without the block the picture-less looks row vanishes" \
  '[ "$(report_of r-bare | grep -ciE "passed with no picture")" = "0" ]'
check "6d. ADDITIVE — the grade, recommendation and whole ledger are IDENTICAL" \
  '[ "$(grade_of j-unrun)" = "$(grade_of r-unrun)" ]'
check "6e. ADDITIVE — identical on the picture-less looks verdict too" \
  '[ "$(grade_of l-bare)" = "$(grade_of r-bare)" ]'
check "6f. and that comparison is not vacuously comparing two empties" \
  '[ -n "$(grade_of j-unrun)" ] && [ "$(grade_of j-unrun)" != "null" ] &&
   printf "%s" "$(grade_of j-unrun)" | grep -qF "prd-1"'
check "6g. ADDITIVE — every line the cured report keeps, the stripped one kept too" \
  '[ "$(report_of r-unrun | wc -l | tr -d " ")" -lt \
     "$(report_of j-unrun | wc -l | tr -d " ")" ] &&
   [ "$(diff <(report_of r-unrun) <(report_of j-unrun) | grep -c "^<")" = "0" ]'

# ===========================================================================
# S272 FIX ROUND 1 — the five defects a fresh tester drove out from the outside.
#
# EVERY ONE IS PROVED BY A MUTATION THAT GOES RED BY BEHAVIOUR. `mutate` is a
# verified literal substitution against THIS branch's own cured scorer: it
# refuses unless the needle appears exactly as many times as declared, so a
# later edit that moves the cured text turns the control RED rather than
# silently disarming it. A git revision would stop firing the moment this
# session is committed; a source grep proves nothing at all (a session earlier
# in this round shipped four cures guarded only by greps, and the measured bug
# could be fully restored with the suite green).
# ===========================================================================
mutate() { # <out> <needle> <replacement> <expected-hits>
  "$PY" - "$SCORE_PY" "$1" "$2" "$3" "$4" <<'MUTEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
out, needle, repl, want = sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
n = src.count(needle)
if n != want:
    sys.stderr.write("MUTATE-FAILED %r hits=%d want=%d\n" % (needle, n, want))
    sys.exit(3)
open(out, "w", encoding="utf-8").write(src.replace(needle, repl))
MUTEOF
}
why_of() {   # <case-name> -> the GRADE'S reason, exactly as it goes on the wire
  sed -n 's/^WHY\t//p' "$R/out/$1/stdout.txt" 2>/dev/null
}
recwhy_of() { # <case-name> -> the recommendation's reason off the wire
  sed -n 's/^RECOMMENDATION_WHY\t//p' "$R/out/$1/stdout.txt" 2>/dev/null
}
notes_of() { # <case-name> -> every NOTE line off the wire
  sed -n 's/^NOTE\t//p' "$R/out/$1/stdout.txt" 2>/dev/null
}
section_of() { # <case-name> <heading-fragment> -> just that section of his report
  "$PY" -c '
import sys
keep, out = False, []
for ln in open(sys.argv[1], encoding="utf-8"):
    if ln.startswith("### "):
        keep = sys.argv[2] in ln
    if keep:
        out.append(ln)
sys.stdout.write("".join(out))' "$R/out/$1/report.md" "$2" 2>/dev/null
}
unrun_section() { section_of "$1" "never ran anyway"; }
looks_section() { section_of "$1" "passed with no picture"; }

echo ""
echo "8. D3 — THE NEW LOOP MUST NOT CLOBBER THE GRADE'S REASON"

# MEASURED. `main()` holds the grade's reason in a plain `why` and prints it as
# `WHY` ~400 lines BELOW the new render block; `xo.sh:5622` reads that line and
# `xo.sh:5699` hands it to `xo_finish` as the board's headline. The unrun loop
# bound `why` itself and Python scoping is per-FUNCTION, so a journey of nothing
# but unrun steps turned the captain's board headline into the harness's own
# excuse. `RECOMMENDATION_WHY` is printed as `(rec_why or why)`, so it sat on
# the same wire.
#
# ELEVEN unrun steps across EIGHT kinds — the measured shape from the real run.
"$PY" - "$R/journey-mixed.json" <<'JEOF'
import json, sys
kinds = ["shot", "shot", "shot", "click", "click", "navigate", "type",
         "viewport", "wait", "press", "hover"]
why = ("the build never came up in a browser for this look, so this step was "
       "KEPT and then never executed and wrote no evidence - nothing about its "
       "shape was refused (lcars launch died: port 8765 was already in use)")
json.dump({"unrunSteps": [{"kind": k, "why": why, "key": "%02d-step" % (i + 1),
                           "for": "prd-1", "round": "2"}
                          for i, k in enumerate(kinds)],
           "noPage": "lcars launch died: port 8765 was already in use"},
          open(sys.argv[1], "w"), indent=2)
JEOF
# ALL ONE KIND, same count — the control for section 9, and a second clobber
# surface for section 8.
"$PY" - "$R/journey-onekind.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": [{"kind": "click",
                           "why": "there was no page to run it on",
                           "key": "%02d-step" % (i + 1), "round": "2"}
                          for i in range(11)]},
          open(sys.argv[1], "w"), indent=2)
JEOF
# ONE unrun step — the N=1 surface for section 12.
"$PY" - "$R/journey-one.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": [{"kind": "click",
                           "why": "there was no page to run it on",
                           "key": "01-step", "round": "1"}]},
          open(sys.argv[1], "w"), indent=2)
JEOF

# THE BASELINE: the identical verdict with NO journey argument at all.
score "$SCORE_PY" "$R/v-list.json" why-base
jscore "$SCORE_PY" "$R/journey-mixed.json"   why-mixed
jscore "$SCORE_PY" "$R/journey-onekind.json" why-onekind

MUT_WHY="$TMPROOT/mut-d3-why.py"
mutate "$MUT_WHY" '_uwhy' 'why' 7
jscore "$MUT_WHY" "$R/journey-mixed.json" mutwhy-mixed

check "8a. CONTROL — the baseline really produced a grade reason (not vacuous)" \
  '[ -n "$(why_of why-base)" ] &&
   printf "%s" "$(why_of why-base)" | grep -qiF "the point of the mission"'
check "8b. CONTROL — and the journey case really rendered the new section" \
  'unrun_section why-mixed | grep -qF "never ran anyway"'
check "8c. BEHAVIOUR — a journey of ONLY unrun steps leaves WHY byte-identical" \
  '[ "$(why_of why-mixed)" = "$(why_of why-base)" ]'
check "8d. BEHAVIOUR — identical on the all-one-kind journey too" \
  '[ "$(why_of why-onekind)" = "$(why_of why-base)" ]'
check "8e. and RECOMMENDATION_WHY — printed as (rec_why or why) — is identical" \
  '[ "$(recwhy_of why-mixed)" = "$(recwhy_of why-base)" ]'
check "8f. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_WHY" "$SCORE_PY" && wrote mutwhy-mixed'
check "8g. MUTATION RED — a loop variable named \`why\` clobbers the headline" \
  '[ "$(why_of mutwhy-mixed)" != "$(why_of why-base)" ]'
check "8h. MUTATION RED — and what reaches his board is the harness's own excuse" \
  'printf "%s" "$(why_of mutwhy-mixed)" | grep -qF "never came up in a browser"'
check "8i. no OTHER bare name the two new blocks bind is read again by main()" \
  '[ "$(sed -n "/S272 RENDER BEGIN/,/S272 RENDER END/p" "$SCORE_PY" |
        grep -cE "^ +(why|seen|row|had|rounds|kind|label|field) = ")" = "0" ]'

echo ""
echo "9. D1 — A GROUP OF MIXED KINDS MAY NOT WEAR ONE ARBITRARY KIND"

# MEASURED: the loop collapsed rows on `why` ALONE and labelled the group with
# the FIRST row's kind. `unrun_row` builds one identical sentence for every
# step, so every unrun group collapses into exactly one line — and that line
# read "- **11 x `navigate`**" over 3 shots, 2 clicks, a navigate, a type, a
# viewport, a wait, a press and a hover. A false sentence in his own report.
check "9a. CONTROL — eleven steps across eight kinds really are on the journey" \
  '[ "$("$PY" -c "
import json,sys
rows = json.load(open(sys.argv[1]))[\"unrunSteps\"]
print(len(set(r[\"kind\"] for r in rows)))" "$R/journey-mixed.json")" = 8 ]'
check "9b. CONTROL — a group that really IS one kind still names it, collapsed" \
  'unrun_section why-onekind | grep -qF "11 x \`click\`"'
check "9c. BEHAVIOUR — the mixed group claims no single kind" \
  '! unrun_section why-mixed |
     grep -qE "11 x .(shot|click|navigate|type|viewport|wait|press|hover)."'
check "9d. BEHAVIOUR — and it still collapses to ONE line per reason" \
  '[ "$(unrun_section why-mixed | grep -c "^- ")" = "1" ]'
check "9e. BEHAVIOUR — every kind it really covers is named with its count" \
  'unrun_section why-mixed | grep -qF "\`shot\` x3" &&
   unrun_section why-mixed | grep -qF "\`click\` x2" &&
   unrun_section why-mixed | grep -qF "\`navigate\` x1" &&
   unrun_section why-mixed | grep -qF "\`type\` x1" &&
   unrun_section why-mixed | grep -qF "\`viewport\` x1" &&
   unrun_section why-mixed | grep -qF "\`wait\` x1" &&
   unrun_section why-mixed | grep -qF "\`press\` x1" &&
   unrun_section why-mixed | grep -qF "\`hover\` x1"'

MUT_KIND="$TMPROOT/mut-d1-kind.py"
mutate "$MUT_KIND" 'len(_ukinds) == 1' 'len(_ukinds) >= 1' 1
jscore "$MUT_KIND" "$R/journey-mixed.json"   mutkind-mixed
jscore "$MUT_KIND" "$R/journey-onekind.json" mutkind-one

check "9f. the mutation is real and still correct on the single-kind journey" \
  '! cmp -s "$MUT_KIND" "$SCORE_PY" && wrote mutkind-mixed &&
   unrun_section mutkind-one | grep -qF "11 x \`click\`"'
check "9g. MUTATION RED — it labels the mixed group with one arbitrary kind" \
  'unrun_section mutkind-mixed | grep -qE "11 x .(shot|click|navigate)."'
check "9h. MUTATION RED — and the kinds it actually covers vanish" \
  '! unrun_section mutkind-mixed | grep -qF "\`hover\` x1"'

echo ""
echo "10. D2 — A REFUSED CITATION IS RECORDED AND SAID, NEVER SILENTLY DROPPED"

# MEASURED, and the knock-on is the real harm. THE REALISTIC SINGLE-DECLARATION
# CASE: the gap declares no `evidence` word and neither does its ledger row, so
# refusing the citation also removes the structural fallback that inferred
# evidence from "it cited a shot" — and the finding changes CATEGORY. An honest
# `shots` renders under "Where the build does not match what you asked for"; a
# refused one renders under "Calls the build made that your drawing does not
# cover — I am reading these as yours, not as faults", and the gap kind flips
# `contradiction` -> `interpretation`. A GENUINE FAULT is presented to the
# captain as his own design call, and nothing anywhere said a declared citation
# had been thrown away.
mkgap_bare() { # <json-literal-for-shots> <out>
  "$PY" - "$1" "$2" <<'GEOF'
import json, sys
shots = json.loads(sys.argv[1])
json.dump({
  "score": "medium", "recommendation": "send-back",
  "summary": "I ran the CLI and read what it printed.",
  "criteria": [{"id": "prd-1",
                "text": "relay file stores the title it was given",
                "impact": "high", "status": "gap", "checkedBy": "cli",
                "shot": "01-help.png",
                "sawInstead": "a record with an empty title",
                "note": "I filed nonce-7 and listed it back with no title",
                "action": "Ran relay.py file then relay.py list."}],
  "gaps": [{"title": "file stores no title",
            "expected": "the title it was given",
            "saw": "a record with an empty title", "shots": shots,
            "kind": "contradiction", "criterion": "prd-1"}],
  "escalations": [], "alsoChecked": [], "couldNot": []},
  open(sys.argv[2], "w"), indent=2)
GEOF
}
mkgap_bare '["01-help.png"]' "$R/b-honest.json"   # cited, and readable
mkgap_bare '5'               "$R/b-refused.json"  # cited, and UNREADABLE
mkgap_bare '[]'              "$R/b-none.json"     # cited NOTHING — deliberate
score "$SCORE_PY" "$R/b-honest.json"  b-honest
score "$SCORE_PY" "$R/b-refused.json" b-refused
score "$SCORE_PY" "$R/b-none.json"    b-none

refused_flag() { # <case-name> -> True when the ENTRY records the refusal
  "$PY" -c '
import json, sys
g = (json.load(open(sys.argv[1])).get("gaps") or [{}])[0]
print(bool(g.get("shotsRefused")))' "$R/out/$1/verdict.json" 2>/dev/null
}

check "10a. CONTROL — the readable citation still scores as a real mismatch" \
  'wrote b-honest &&
   report_of b-honest | grep -qF "Where the build does not match what you asked for"'
check "10b. CONTROL — and it records no refusal" \
  '[ "$(refused_flag b-honest)" = "False" ]'
check "10c. CONTROL — a gap that cited NOTHING keeps the old wording exactly" \
  '[ "$(refused_flag b-none)" = "False" ] &&
   notes_of b-none | grep -qF "had no picture of it"'
check "10d. BEHAVIOUR — the PRODUCER records that it threw a citation away" \
  '[ "$(refused_flag b-refused)" = "True" ]'
check "10e. BEHAVIOUR — and the two shapes are no longer byte-identical" \
  '! diff -q "$R/out/b-none/report.md" "$R/out/b-refused/report.md" >/dev/null'
check "10f. BEHAVIOUR — the captain is told a picture WAS named, and refused" \
  'report_of b-refused | grep -qiF "could not read the citation"'
check "10g. BEHAVIOUR — and that it is the harness's limit, NOT his design call" \
  'report_of b-refused | grep -qiF "my limit, not your"'
check "10h. BEHAVIOUR — the blanket \"I am reading these as yours\" is qualified" \
  'report_of b-refused |
     grep -qF "I am reading these as yours, not as faults — except"'
check "10i. BEHAVIOUR — \"no shot\" is not claimed of a finding that named one" \
  '! report_of b-refused | grep -qF "(no shot; prd-1)"'
check "10j. BEHAVIOUR — the note no longer misdescribes it as \"no picture\"" \
  '! notes_of b-refused | grep -qF "had no picture of it" &&
   notes_of b-refused | grep -qF "named a picture"'
check "10k. BEHAVIOUR — and the refusal reaches the WIRE, not only the markdown" \
  'notes_of b-refused | grep -qiF "not a path I could read"'

MUT_REF="$TMPROOT/mut-d2-refused.py"
# THREE SITES SINCE FIX ROUND 2: the demotion branch, the new kept-the-row
# `elif` (D-C) and the stamp on the entry. `elif shots_refused:` contains the
# needle, so it becomes `elif False:` — still valid, and still "every refusal
# path off", which is the state this mutation is meant to restore.
mutate "$MUT_REF" 'if shots_refused:' 'if False:' 3
score "$MUT_REF" "$R/b-refused.json" mutref-refused
score "$MUT_REF" "$R/b-honest.json"  mutref-honest

check "10l. the mutation is real and still correct on the honest citation" \
  '! cmp -s "$MUT_REF" "$SCORE_PY" && wrote mutref-refused &&
   report_of mutref-honest |
     grep -qF "Where the build does not match what you asked for"'
check "10m. MUTATION RED — the refusal is recorded nowhere" \
  '[ "$(refused_flag mutref-refused)" = "False" ]'
check "10n. MUTATION RED — a refused citation reads byte-identical to none at all" \
  'diff -q "$R/out/b-none/report.md" "$R/out/mutref-refused/report.md" >/dev/null'
check "10o. MUTATION RED — and the genuine fault is presented as his own call" \
  'report_of mutref-refused |
     grep -qF "your drawing does not say, so I am treating it as your call"'

echo ""
echo "11. D4 — A GUARD THAT STANDS DOWN SAYS SO IN THE NOTES"

# MEASURED: an unlisted record with two findings — one citing the real
# `01-help.png`, one citing an invented `99-never-taken.png`. Against an honest
# inventory the invention is DROPPED and the drop is noted. With `"shots": 5`
# the inventory is empty, BOTH are kept, and `ledgerNotes` was EMPTY — so a
# finding naming a picture nobody took reached his "yours to decide"
# escalations with nothing saying the guard had stood down. The file's own
# stated rule is that a drop happens "loudly, in the notes, never in silence",
# and a disabled guard is the silent case.
cat >"$R/inv-honest.json" <<'IEOF'
{"findings": [{"what": "the footer overlaps the table", "shot": "01-help.png",
               "why": "it reads as one block"},
              {"what": "the sidebar is upside down", "shot": "99-never-taken.png",
               "why": "nobody took this picture"}],
 "shots": ["01-help.png"]}
IEOF
reshape_inv() { # <out> <json-literal-for-shots>
  "$PY" - "$R/inv-honest.json" "$1" "$2" <<'IEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["shots"] = json.loads(sys.argv[3])
json.dump(d, open(sys.argv[2], "w"), indent=2)
IEOF
}
reshape_inv "$R/inv-int.json"   '5'
reshape_inv "$R/inv-empty.json" '[]'

ul_score "$SCORE_PY" "$R/inv-honest.json" inv-honest
ul_score "$SCORE_PY" "$R/inv-int.json"    inv-int
ul_score "$SCORE_PY" "$R/inv-empty.json"  inv-empty
n_unlisted() { # <case-name>
  "$PY" -c '
import json, sys
print(len(json.load(open(sys.argv[1])).get("unlisted") or []))' \
    "$R/out/$1/verdict.json" 2>/dev/null
}

check "11a. CONTROL — with an honest inventory the invented picture is dropped" \
  '[ "$(n_unlisted inv-honest)" = "1" ]'
check "11b. CONTROL — and that drop was already said out loud" \
  'notes_of inv-honest | grep -qF "could not name a picture the walk took"'
check "11c. CONTROL — an inventory of [] stands the guard down, as it always did" \
  '[ "$(n_unlisted inv-empty)" = "2" ] &&
   [ "$(notes_of inv-empty | grep -ci "could not read")" = "0" ]'
check "11d. BEHAVIOUR — a refused inventory keeps both finds (no crash, no drop)" \
  '[ "$(n_unlisted inv-int)" = "2" ]'
check "11e. BEHAVIOUR — and the notes SAY the check was skipped" \
  'notes_of inv-int | grep -qiF "not in a shape I could read"'
check "11f. BEHAVIOUR — naming the risk: one may cite a picture nobody took" \
  'notes_of inv-int | grep -qiF "may name a picture nobody ever took"'

MUT_INV="$TMPROOT/mut-d4-inv.py"
mutate "$MUT_INV" 'if inv_refused and rows:' 'if False and rows:' 1
ul_score "$MUT_INV" "$R/inv-int.json"    mutinv-int
ul_score "$MUT_INV" "$R/inv-honest.json" mutinv-honest

check "11g. the mutation is real and still drops against an honest inventory" \
  '! cmp -s "$MUT_INV" "$SCORE_PY" && wrote mutinv-honest &&
   [ "$(n_unlisted mutinv-honest)" = "1" ]'
check "11h. MUTATION RED — the disabled guard goes back to silence" \
  '[ "$(n_unlisted mutinv-int)" = "2" ] &&
   [ "$(notes_of mutinv-int | grep -ci "shape I could read")" = "0" ]'

echo ""
echo "12. D5 — THE ENGLISH, AND AN ACTION HE CAN TAKE"

jscore "$SCORE_PY" "$R/journey-one.json" one-step

check "12a. CONTROL — the single-step journey rendered the section at all" \
  'unrun_section one-step | grep -qF "I asked for one step"'
check "12b. BEHAVIOUR — at N=1 the closing sentence agrees with the paragraph" \
  'unrun_section one-step | grep -qF "So that step is unchecked" &&
   ! unrun_section one-step | grep -qF "every one of those steps"'
check "12c. CONTROL — at N>1 it still reads as the plural it is" \
  'unrun_section why-mixed | grep -qF "So every one of those steps is unchecked"'

MUT_N1="$TMPROOT/mut-d5-n1.py"
mutate "$MUT_N1" '"that step is" if len(unrun_steps) == 1' \
                 '"every one of those steps is" if len(unrun_steps) == 1' 1
jscore "$MUT_N1" "$R/journey-one.json" mutn1-one
check "12d. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_N1" "$SCORE_PY" && wrote mutn1-one'
check "12e. MUTATION RED — the unconditional plural comes back at N=1" \
  'unrun_section mutn1-one | grep -qF "So every one of those steps is unchecked"'

check "12f. CONTROL — the looks section rendered on the picture-less row" \
  'looks_section l-bare | grep -qF "prd-1"'
check "12g. BEHAVIOUR — it no longer points DOWN at rows that are UP in the table" \
  '! looks_section l-bare | grep -qiF "below" &&
   looks_section l-bare | grep -qF "on the list above"'
check "12h. BEHAVIOUR — and it tells him what to DO about it" \
  'looks_section l-bare | grep -qiF "open the build and look at" &&
   looks_section l-bare | grep -qiF "send this back"'

MUT_DIR="$TMPROOT/mut-d5-dir.py"
mutate "$MUT_DIR" 'already marked unchecked on the list above' \
                  'already marked unchecked on the list below' 1
lscore "$MUT_DIR" "$R/v-looks.json" mutdir-bare
MUT_ACT="$TMPROOT/mut-d5-act.py"
mutate "$MUT_ACT" 'What to do: open the build and look at' \
                  'By the way, there is no picture of' 1
lscore "$MUT_ACT" "$R/v-looks.json" mutact-bare

check "12i. the direction mutation is real and still a working scorer" \
  '! cmp -s "$MUT_DIR" "$SCORE_PY" && wrote mutdir-bare'
check "12j. MUTATION RED — the section points him the wrong way again" \
  'looks_section mutdir-bare | grep -qF "on the list below"'
check "12k. the action mutation is real and still a working scorer" \
  '! cmp -s "$MUT_ACT" "$SCORE_PY" && wrote mutact-bare'
check "12l. MUTATION RED — with the action gone he is left with a fact only" \
  '! looks_section mutact-bare | grep -qiF "open the build and look at"'

echo ""
echo "13. THE FIVE CURES DID NOT UNDO THE THREE THIS SESSION ALREADY SHIPPED"

check "13a. the gaps-lane crash cure still holds (\`shots: 5\` writes a file)" \
  'wrote cured-int && [ "$(gap_shots cured-int)" = "[]" ]'
check "13b. the unlisted-inventory crash cure still holds" \
  'wrote ul-int && has_unlisted ul-int'
check "13c. the two new sections still render, and still only when non-empty" \
  'unrun_section why-mixed | grep -qF "never ran anyway" &&
   [ "$(report_of j-clean | grep -ciE "never ran|no page to run")" = "0" ]'
check "13d. ADDITIVE still — a refused-citation verdict changes no GRADE" \
  '[ "$(grade_of b-refused)" = "$(grade_of b-none)" ]'
check "13e. …and that comparison is not vacuous" \
  '[ -n "$(grade_of b-refused)" ] &&
   printf "%s" "$(grade_of b-refused)" | grep -qF "prd-1"'

echo ""
echo "14. D-A — A LOOK THAT FILED AN INTERPRETATION WAS TOLD IT FILED A MISMATCH"

# MEASURED on the round-1 tip. `shots_refused` is true of ANY gap whose citation
# could not be read, so a gap the LOOK ITSELF filed as `kind: "interpretation"`
# — i.e. the look already said "this is the captain's call, not a fault" — got
# the demotion bullet and read:
#
#   "the toolbar is on the left — the build has a left toolbar. The look filed
#    this as a MISMATCH IN YOUR BUILD and named a picture for it…"
#
# The look said no such thing. That is the same misdescribing-note class the
# round-1 cure existed to close, so the flag is split: `shotsRefused` records
# the unreadable citation, `shotsRefusedDemoted` records only an actual
# demotion, and every "the look filed this as a mismatch" sentence keys off the
# second one. BOTH HALVES ARE CHECKED: the look-declared interpretation must
# NOT be told it filed a mismatch, and a genuinely demoted contradiction MUST
# still be.
mkgap_kind() { # <kind> <json-literal-for-shots> <out>
  "$PY" - "$1" "$2" "$3" <<'KEOF'
import json, sys
kind, shots = sys.argv[1], json.loads(sys.argv[2])
json.dump({
  "score": "medium", "recommendation": "send-back",
  "summary": "I ran the CLI and read what it printed.",
  "criteria": [{"id": "prd-1",
                "text": "relay file stores the title it was given",
                "impact": "high", "status": "gap", "checkedBy": "cli",
                "shot": "01-help.png",
                "sawInstead": "a record with an empty title",
                "note": "I filed nonce-7 and listed it back with no title",
                "action": "Ran relay.py file then relay.py list."}],
  "gaps": [{"title": "the toolbar is on the left",
            "expected": "the drawing does not say",
            "saw": "a left toolbar", "shots": shots,
            "kind": kind, "criterion": "prd-1"}],
  "escalations": [], "alsoChecked": [], "couldNot": []},
  open(sys.argv[3], "w"), indent=2)
KEOF
}
# THE REPRO the fix-round-2 tester named: the look's OWN kind, and `shots: 5`.
mkgap_kind interpretation '5'               "$R/i-refused.json"
# ONE VARIABLE: the identical gap with a READABLE citation.
mkgap_kind interpretation '["01-help.png"]' "$R/i-honest.json"
score "$SCORE_PY" "$R/i-refused.json" i-refused
score "$SCORE_PY" "$R/i-honest.json"  i-honest

demoted_flag() { # <case-name> -> True when the ENTRY records an actual DEMOTION
  "$PY" -c '
import json, sys
g = (json.load(open(sys.argv[1])).get("gaps") or [{}])[0]
print(bool(g.get("shotsRefusedDemoted")))' "$R/out/$1/verdict.json" 2>/dev/null
}
gap_kind() { # <case-name>
  "$PY" -c '
import json, sys
print((json.load(open(sys.argv[1])).get("gaps") or [{}])[0].get("kind"))' \
    "$R/out/$1/verdict.json" 2>/dev/null
}

check "14a. CONTROL — the look-declared interpretation scores and stays one" \
  'wrote i-refused && [ "$(gap_kind i-refused)" = "interpretation" ]'
check "14b. CONTROL — and it really did have an unreadable citation to refuse" \
  '[ "$(refused_flag i-refused)" = "True" ]'
check "14c. BEHAVIOUR — nothing demoted it, so no demotion is recorded" \
  '[ "$(demoted_flag i-refused)" = "False" ]'
check "14d. BEHAVIOUR — the captain is NOT told the look filed it as a mismatch" \
  '! report_of i-refused | grep -qF "MISMATCH IN YOUR BUILD"'
check "14e. BEHAVIOUR — he is told what the look did say: it is his call" \
  'report_of i-refused |
     grep -qF "your drawing does not say, so I am treating it as your call"'
check "14f. BEHAVIOUR — the blanket heading is NOT qualified for a row that is his" \
  '! report_of i-refused | grep -qF "not as faults — except"'
check "14g. BEHAVIOUR — and the unreadable citation is still disclosed on the row" \
  'report_of i-refused | grep -qF "a picture was named, and I could not read the citation"'
check "14h. BEHAVIOUR — and on the wire too, with no claim about a demotion" \
  'notes_of i-refused | grep -qF "stays where the look filed it" &&
   ! notes_of i-refused | grep -qF "moved it to the calls-the-build-made list"'
check "14i. CONTROL — the readable-citation twin claims no refusal at all" \
  '[ "$(refused_flag i-honest)" = "False" ] &&
   ! report_of i-honest | grep -qF "could not read the citation"'
# THE OTHER HALF — the genuinely demoted contradiction MUST still say it.
check "14j. CONTROL (other half) — a real demotion still records one" \
  '[ "$(demoted_flag b-refused)" = "True" ] &&
   [ "$(gap_kind b-refused)" = "interpretation" ]'
check "14k. CONTROL (other half) — and still says the look filed a MISMATCH" \
  'report_of b-refused | grep -qF "MISMATCH IN YOUR BUILD" &&
   report_of b-refused | grep -qF "That is my limit, not your call."'
check "14l. CONTROL (other half) — and still qualifies the heading for it" \
  'report_of b-refused | grep -qF "not as faults — except"'

MUT_DA="$TMPROOT/mut-da-flag.py"
mutate "$MUT_DA" 'g.get("shotsRefusedDemoted")' 'g.get("shotsRefused")' 2
score "$MUT_DA" "$R/i-refused.json" mutda-interp
score "$MUT_DA" "$R/b-refused.json" mutda-contra

check "14m. the mutation is real and still correct on the DEMOTED row" \
  '! cmp -s "$MUT_DA" "$SCORE_PY" && wrote mutda-interp &&
   report_of mutda-contra | grep -qF "MISMATCH IN YOUR BUILD"'
check "14n. MUTATION RED — the look is told it filed a mismatch it never filed" \
  'report_of mutda-interp | grep -qF "MISMATCH IN YOUR BUILD"'
check "14o. MUTATION RED — and his own call is announced as an exception to itself" \
  'report_of mutda-interp | grep -qF "not as faults — except"'

echo ""
echo "15. D-B — \"IT NAMED A PICTURE\" IS NOT SAID WHEN NOTHING WAS NAMED"

# MEASURED on the round-1 tip. The refusal test was `_raw_shots not in (None,
# "", [], (), {})` — five TOP-LEVEL literals and nothing else — so every one of
# these was reported to the captain as "named a picture … I could not read the
# citation" when the look named NOTHING:
#
#   [""]   ["  "]   [None]   [[]]   [{}]   {"a": ""}   {"a": []}
#
# The cure asks the question of the LEAVES: was there a leaf that could never
# have been a path? A bool and a number still are one — see the ruling in the
# source block — and those two halves are both checked here.
for _case in str-empty:'[""]' str-blank:'["  "]' none-in:'[null]' \
             list-in:'[[]]' map-in:'[{}]' map-str:'{"a": ""}' \
             map-list:'{"a": []}'; do
  _n="${_case%%:*}"
  mkgap_bare "${_case#*:}" "$R/e-$_n.json"
  score "$SCORE_PY" "$R/e-$_n.json" "e-$_n"
done
mkgap_bare 'false' "$R/e-false.json"; score "$SCORE_PY" "$R/e-false.json" e-false
mkgap_bare '0'     "$R/e-zero.json";  score "$SCORE_PY" "$R/e-zero.json"  e-zero

check "15a. CONTROL — the honest-empty \`[]\` baseline really scored" \
  'wrote b-none && [ "$(refused_flag b-none)" = "False" ]'
check "15b. BEHAVIOUR — a list of empty strings cited NOTHING, and says so" \
  '[ "$(refused_flag e-str-empty)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-str-empty/report.md" >/dev/null'
check "15c. BEHAVIOUR — …a list of blanks too" \
  '[ "$(refused_flag e-str-blank)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-str-blank/report.md" >/dev/null'
check "15d. BEHAVIOUR — …a list holding a null" \
  '[ "$(refused_flag e-none-in)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-none-in/report.md" >/dev/null'
check "15e. BEHAVIOUR — …a list holding an empty list" \
  '[ "$(refused_flag e-list-in)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-list-in/report.md" >/dev/null'
check "15f. BEHAVIOUR — …a list holding an empty map" \
  '[ "$(refused_flag e-map-in)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-map-in/report.md" >/dev/null'
check "15g. BEHAVIOUR — …a map whose value is an empty string" \
  '[ "$(refused_flag e-map-str)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-map-str/report.md" >/dev/null'
check "15h. BEHAVIOUR — …and a map whose value is an empty list" \
  '[ "$(refused_flag e-map-list)" = "False" ] &&
   diff -q "$R/out/b-none/report.md" "$R/out/e-map-list/report.md" >/dev/null'
check "15i. BEHAVIOUR — none of them claims a picture was named" \
  '[ "$(for c in e-str-empty e-str-blank e-none-in e-list-in e-map-in \
                 e-map-str e-map-list; do
          report_of "$c"; done | grep -c "could not read the citation")" = "0" ]'
# THE OTHER HALF — a scalar leaf IS a malformed citation and must still flag.
check "15j. CONTROL (other half) — \`shots: 5\` is still refused" \
  '[ "$(refused_flag b-refused)" = "True" ] &&
   report_of b-refused | grep -qF "could not read the citation"'
check "15k. CONTROL (other half) — \`shots: true\` is still refused" \
  '[ "$(refused_flag cured-bool)" = "True" ]'
check "15l. THE RULING, APPLIED CONSISTENTLY — \`false\` and \`0\` flag too" \
  '[ "$(refused_flag e-false)" = "True" ] && [ "$(refused_flag e-zero)" = "True" ]'

MUT_DB="$TMPROOT/mut-db-leaf.py"
mutate "$MUT_DB" '_unreadable_citation(_raw_shots)' \
                 '(_raw_shots not in (None, "", [], (), {}))' 2
score "$MUT_DB" "$R/e-str-empty.json" mutdb-empty
score "$MUT_DB" "$R/b-refused.json"   mutdb-refused
score "$MUT_DB" "$R/b-none.json"      mutdb-none

check "15m. the mutation is real and still correct on the two clear cases" \
  '! cmp -s "$MUT_DB" "$SCORE_PY" && wrote mutdb-empty &&
   [ "$(refused_flag mutdb-refused)" = "True" ] &&
   [ "$(refused_flag mutdb-none)" = "False" ]'
check "15n. MUTATION RED — \`[\"\"]\` is called a named picture again" \
  '[ "$(refused_flag mutdb-empty)" = "True" ]'
check "15o. MUTATION RED — and the captain is told so in his own report" \
  'report_of mutdb-empty | grep -qF "could not read the citation"'

# THE SIBLING CALL SITE — the identical rule, measured the same way.
reshape_inv "$R/inv-map-str.json" '{"a": ""}'
ul_score "$SCORE_PY" "$R/inv-map-str.json" inv-map-str
MUT_DBI="$TMPROOT/mut-db-inv.py"
mutate "$MUT_DBI" '_unreadable_citation(_raw_inv)' \
                  '(_raw_inv not in (None, "", [], (), {}))' 1
ul_score "$MUT_DBI" "$R/inv-map-str.json" mutdbi-map-str
ul_score "$MUT_DBI" "$R/inv-int.json"     mutdbi-int

check "15p. BEHAVIOUR — an inventory of \`{\"a\": \"\"}\` recorded no list to read" \
  '[ "$(n_unlisted inv-map-str)" = "2" ] &&
   [ "$(notes_of inv-map-str | grep -ci "shape I could read")" = "0" ]'
check "15q. the sibling mutation is real and still flags the scalar inventory" \
  '! cmp -s "$MUT_DBI" "$SCORE_PY" &&
   notes_of mutdbi-int | grep -qiF "not in a shape I could read"'
check "15r. MUTATION RED — the sibling over-flags the empty-leaf inventory again" \
  'notes_of mutdbi-map-str | grep -qiF "not in a shape I could read"'

echo ""
echo "16. D-C — THE REFUSAL PATH THAT RECORDED THE FACT AND SAID NOTHING"

# MEASURED on the round-1 tip. When a contradiction is KEPT because the
# project's own tests back it, `cite()`'s `evidence == "tests"` branch wins and
# the demotion note never fires — so `verdict.json` carried
# `"shotsRefused": true` while the report AND the wire said nothing at all.
# Round 1 claimed the fact reached all three mediums; on this path it reached
# one. The note is brief, and worded so it is true of every path that KEEPS the
# row (this one, and a look-declared interpretation).
mkgap_tests() { # <json-literal-for-shots> <out>
  "$PY" - "$1" "$2" <<'TEOF'
import json, sys
shots = json.loads(sys.argv[1])
json.dump({
  "score": "medium", "recommendation": "send-back",
  "summary": "I ran the CLI and read what it printed.",
  "criteria": [{"id": "prd-1",
                "text": "relay file stores the title it was given",
                "impact": "high", "status": "gap", "checkedBy": "test",
                "evidence": "tests",
                "testQuote": "PASS relay stores the title it was given",
                "sawInstead": "a record with an empty title",
                "note": "the suite says so",
                "action": "Ran npm test."}],
  "gaps": [{"title": "file stores no title",
            "expected": "the title it was given",
            "saw": "a record with an empty title", "shots": shots,
            "kind": "contradiction", "criterion": "prd-1",
            "evidence": "tests",
            "testQuote": "PASS relay stores the title it was given"}],
  "escalations": [], "alsoChecked": [], "couldNot": []},
  open(sys.argv[2], "w"), indent=2)
TEOF
}
mkgap_tests '5'               "$R/t-refused.json"
mkgap_tests '["01-help.png"]' "$R/t-honest.json"
lscore "$SCORE_PY" "$R/t-refused.json" t-refused
lscore "$SCORE_PY" "$R/t-honest.json"  t-honest

check "16a. CONTROL — the tests guard really kept the row a contradiction" \
  '[ "$(gap_kind t-refused)" = "contradiction" ] &&
   report_of t-refused | grep -qF "Where the build does not match what you asked for"'
check "16b. CONTROL — and the producer really recorded the refusal" \
  '[ "$(refused_flag t-refused)" = "True" ]'
check "16c. CONTROL — nothing demoted it, so no demotion is claimed" \
  '[ "$(demoted_flag t-refused)" = "False" ] &&
   ! report_of t-refused | grep -qF "MISMATCH IN YOUR BUILD"'
check "16d. BEHAVIOUR — the refusal now reaches the captain'\''s REPORT" \
  'report_of t-refused | grep -qF "was not a path I could read"'
check "16e. BEHAVIOUR — and the WIRE, not only verdict.json" \
  'notes_of t-refused | grep -qF "was not a path I could read"'
check "16f. BEHAVIOUR — and it does not pretend the finding moved" \
  'notes_of t-refused | grep -qF "stays where the look filed it"'
check "16g. CONTROL — the readable-citation twin says none of it" \
  '[ "$(refused_flag t-honest)" = "False" ] &&
   [ "$(notes_of t-honest | grep -c "path I could read")" = "0" ]'

MUT_DC="$TMPROOT/mut-dc-kept.py"
mutate "$MUT_DC" 'elif shots_refused:' 'elif False:' 1
lscore "$MUT_DC" "$R/t-refused.json" mutdc-refused
lscore "$MUT_DC" "$R/t-honest.json"  mutdc-honest

check "16h. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_DC" "$SCORE_PY" && wrote mutdc-refused &&
   [ "$(gap_kind mutdc-honest)" = "contradiction" ]'
check "16i. MUTATION RED — the fact is recorded in verdict.json…" \
  '[ "$(refused_flag mutdc-refused)" = "True" ]'
check "16j. MUTATION RED — …and the report and the wire go silent about it" \
  '[ "$(report_of mutdc-refused | grep -c "path I could read")" = "0" ] &&
   [ "$(notes_of mutdc-refused   | grep -c "path I could read")" = "0" ]'

echo ""
echo "17. FIX 4 — THE COMMENT MUST NOT IMPLY THE SIBLING CLOBBER IS CURED"

# Round 1 closed its own note with "Same lesson, and the same \`_\`-prefix
# discipline, as the \`dwhy\` note above" — which a future reader takes as "the
# class is closed". It is not: the \`refusedSteps\` loop ~80 lines above binds
# the BARE name \`why\` in the same \`main()\` scope. That is INHERITED (it
# reproduces on the parent) and is deliberately ledgered, not cured here. The
# comment is a claim about the code, so it is checked two ways: the LINE IT
# NAMES is verified to be the real one, and the clobber it calls live is
# REPRODUCED.
unrun_block() {
  sed -n '/S272 RENDER BEGIN unrun/,/S272 RENDER END unrun/p' "$SCORE_PY"
}
check "17a. the note no longer claims the discipline is applied class-wide" \
  '! unrun_block | grep -qF "and the same \`_\`-prefix"'
check "17b. it states plainly that the class is NOT closed" \
  'unrun_block | grep -qF "NOT** CLOSED"'
check "17c. it says the sibling is live today and ledgered, not fixed" \
  'unrun_block | grep -qF "LIVE TODAY" && unrun_block | grep -qF "LEDGERED"'
check "17d. it names the line, and it names it as inherited" \
  'unrun_block | grep -qF "line 5828" && unrun_block | grep -qF "inherited"'
check "17e. ACCURACY — line 5828 really is the bare \`why\` the note points at" \
  'sed -n "5828p" "$SCORE_PY" | grep -qF '\''why = " ".join(str(row.get("why")'\'''
check "17f. ACCURACY — and it really is inside the \`refusedSteps\` render" \
  '[ "$(sed -n "/Steps I asked for and was not allowed to run/,/where to look for the reason/p" "$SCORE_PY" |
        grep -cF '\''why = " ".join(str(row.get("why")'\'')" = "1" ]'

# AND THE CLOBBER THE NOTE CALLS LIVE, REPRODUCED — the note is only honest if
# this still happens. ONE refused step, nothing else on the journey.
"$PY" - "$R/journey-refused.json" <<'JEOF'
import json, sys
json.dump({"refusedSteps": [{"kind": "shot", "round": "1",
                             "why": "a shell escape the fence would not run"}]},
          open(sys.argv[1], "w"), indent=2)
JEOF
jscore "$SCORE_PY" "$R/journey-refused.json" why-refused

check "17g. CONTROL — the baseline grade reason is still the mission'\''s point" \
  'printf "%s" "$(why_of why-base)" | grep -qiF "the point of the mission"'
check "17h. BEHAVIOUR — the LEDGERED sibling clobber is live, exactly as said" \
  '[ "$(why_of why-refused)" != "$(why_of why-base)" ] &&
   printf "%s" "$(why_of why-refused)" | grep -qF "a shell escape"'
check "17i. CONTROL — and the unrun block beside it does NOT clobber (round 1)" \
  '[ "$(why_of why-mixed)" = "$(why_of why-base)" ]'

echo ""
echo "18. D-E — WORDS, NOT NUMERALS, AT N=1 (he reads this on a phone)"

check "18a. CONTROL — the 11-step journey still reads as the numeral it is" \
  'unrun_section why-mixed | grep -qF "I asked for 11 steps"'
check "18b. BEHAVIOUR — at N=1 the unrun lead reads \"one step\"" \
  'unrun_section one-step | grep -qF "I asked for one step" &&
   ! unrun_section one-step | grep -qF "I asked for 1 step"'
check "18c. BEHAVIOUR — at N=1 the looks lead reads \"One of the checks\"" \
  'looks_section l-bare |
     grep -qF "One of the checks on your list that ask what the screen" &&
   ! looks_section l-bare | grep -qF "1 of the checks"'
check "18d. BEHAVIOUR — and the interpretation heading reads \"the one marked\"" \
  'report_of b-refused | grep -qF "except the one marked below" &&
   ! report_of b-refused | grep -qF "except the 1 marked below"'

# THE N>1 CONTROL FOR THE LOOKS LEAD — its own contract, because only a
# contract row can reach the ledger at all.
cat >"$R/criteria2.json" <<'C2'
{"criteria": [
  {"id": "prd-1", "text": "relay file stores the title it was given",
   "source": "prd", "impact": "high"},
  {"id": "prd-2", "text": "the list screen shows the title in bold",
   "source": "prd", "impact": "high"}
]}
C2
"$PY" - "$R/v-looks2.json" <<'L2'
import json, sys
row = lambda i, t: {"id": "prd-%d" % i, "text": t, "impact": "high",
                    "status": "met", "kind": "looks", "evidence": "tests",
                    "checkedBy": "test",
                    "testQuote": "PASS relay stores the title it was given",
                    "note": "the suite says so"}
json.dump({"score": "medium", "recommendation": "send-back",
           "summary": "I ran the CLI and read what it printed.",
           "criteria": [row(1, "relay file stores the title it was given"),
                        row(2, "the list screen shows the title in bold")],
           "gaps": [], "escalations": [], "alsoChecked": [], "couldNot": []},
          open(sys.argv[1], "w"), indent=2)
L2
mkdir -p "$R/out/l-two"
"$PY" "$SCORE_PY" "$R/v-looks2.json" "$R/criteria2.json" \
      "$R/out/l-two/verdict.json" "" "$R/tests.json" "" "" "" "" "" "" "" \
      "$R/shots" >"$R/out/l-two/stdout.txt" 2>"$R/out/l-two/stderr.txt" || :

check "18e. CONTROL — the two-row look really produced two picture-less rows" \
  '[ "$("$PY" -c "
import json,sys
print(len(json.load(open(sys.argv[1])).get(\"looksWithNoPicture\") or []))" \
        "$(sfile l-two)")" = "2" ]'
check "18f. CONTROL — at N=2 the looks lead is a numeral and a plural verb" \
  'looks_section l-two |
     grep -qF "2 of the checks on your list that ask what the screen"'

MUT_E1="$TMPROOT/mut-de-unrun.py"
mutate "$MUT_E1" '"one" if len(unrun_steps) == 1 else len(unrun_steps)' \
                 'len(unrun_steps)' 1
jscore "$MUT_E1" "$R/journey-one.json" mutde-one
MUT_E2="$TMPROOT/mut-de-looks.py"
mutate "$MUT_E2" '"One" if _n == 1 else _n' '_n' 1
lscore "$MUT_E2" "$R/v-looks.json" mutde-bare
MUT_E3="$TMPROOT/mut-de-except.py"
mutate "$MUT_E3" '"one" if len(_refused_cites) == 1 else len(_refused_cites)' \
                 'len(_refused_cites)' 1
score "$MUT_E3" "$R/b-refused.json" mutde-refused

check "18g. the three mutations are real and still working scorers" \
  '! cmp -s "$MUT_E1" "$SCORE_PY" && ! cmp -s "$MUT_E2" "$SCORE_PY" &&
   ! cmp -s "$MUT_E3" "$SCORE_PY" && wrote mutde-one && wrote mutde-bare &&
   wrote mutde-refused'
check "18h. MUTATION RED — \"I asked for 1 step\" comes back" \
  'unrun_section mutde-one | grep -qF "I asked for 1 step"'
check "18i. MUTATION RED — \"1 of the checks\" comes back" \
  'looks_section mutde-bare | grep -qF "1 of the checks"'
check "18j. MUTATION RED — \"except the 1 marked below\" comes back" \
  'report_of mutde-refused | grep -qF "except the 1 marked below"'

echo ""
echo "19. FIX ROUND 3 — a new crash, and eight sentences that were not true"

# ═══ FIX 1 — THE BLOCKER: THIS SESSION'S OWN NEW READ CRASHED ════════════════
#
# MEASURED BY HAND on this branch before a line of this was written, with the
# honest list as the control beside it:
#   journey.json = {"unrunSteps": 5}  -> rc=1, TypeError: 'int' object is not
#                                       iterable, and NEITHER verdict.json NOR
#                                       report.md written
#   journey.json = {"unrunSteps": [{"kind":"click","why":"no page"}]} -> rc=0
# The PARENT commit scores the scalar file fine and writes both, because the
# parent never read `unrunSteps` at all. So this is the crash-and-write-nothing
# class the whole session was convened to close, introduced by the session's own
# cure. Reachability through the real producers is nil (`xo-run.py` and
# `xo-journey.py` always write lists), so it is a hardening gap and not a live
# break — cured anyway, with the guard `main()` already uses on the gaps list.
"$PY" - "$R/journey-scalar.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": 5}, open(sys.argv[1], "w"), indent=2)
JEOF
"$PY" - "$R/journey-boolish.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": True}, open(sys.argv[1], "w"), indent=2)
JEOF
"$PY" - "$R/journey-stringy.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": "a click"}, open(sys.argv[1], "w"), indent=2)
JEOF
"$PY" - "$R/journey-one-ctl.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": [{"kind": "click", "why": "no page"}]},
          open(sys.argv[1], "w"), indent=2)
JEOF

jscore "$SCORE_PY" "$R/journey-scalar.json"   f1-scalar
jscore "$SCORE_PY" "$R/journey-boolish.json"  f1-bool
jscore "$SCORE_PY" "$R/journey-stringy.json"  f1-string
jscore "$SCORE_PY" "$R/journey-one-ctl.json"  f1-ctl

reported() { [ -s "$R/out/$1/report.md" ]; }

check "19a. CONTROL — the honest one-step list still scores AND renders" \
  'wrote f1-ctl && reported f1-ctl &&
   unrun_section f1-ctl | grep -qF "I asked for one step"'
check "19b. BEHAVIOUR — \`unrunSteps: 5\` writes verdict.json, as the parent did" \
  'wrote f1-scalar'
check "19c. BEHAVIOUR — …and report.md, which is the half that was lost" \
  'reported f1-scalar'
check "19d. BEHAVIOUR — and no TypeError is raised at all" \
  '! crashed f1-scalar && [ ! -s "$R/out/f1-scalar/stderr.txt" ]'
check "19e. BEHAVIOUR — an unreadable list reads as NO list: no section, no noise" \
  '[ "$(report_of f1-scalar | grep -ciE "never ran anyway")" = "0" ]'
check "19f. BEHAVIOUR — \`true\` and a bare string are hardened the same way" \
  'wrote f1-bool && reported f1-bool && wrote f1-string && reported f1-string &&
   ! crashed f1-bool && ! crashed f1-string'

MUT_F1="$TMPROOT/mut-f1-unrun.py"
mutate "$MUT_F1" \
  'journey_doc.get("unrunSteps") if isinstance(journey_doc.get("unrunSteps"), list) else []' \
  'journey_doc.get("unrunSteps") or []' 1
jscore "$MUT_F1" "$R/journey-scalar.json"  mutf1-scalar
jscore "$MUT_F1" "$R/journey-one-ctl.json" mutf1-ctl

check "19g. the mutation is real and still a working scorer on an honest list" \
  '! cmp -s "$MUT_F1" "$SCORE_PY" && wrote mutf1-ctl &&
   unrun_section mutf1-ctl | grep -qF "I asked for one step"'
check "19h. MUTATION RED — the raw read writes NO verdict.json" '! wrote mutf1-scalar'
check "19i. MUTATION RED — and NO report.md either (write-nothing, as measured)" \
  '! reported mutf1-scalar'
check "19j. MUTATION RED — and it raises the measured TypeError" 'crashed mutf1-scalar'

# ═══ THE RIG FOR THE REPORT'S SENTENCES ══════════════════════════════════════
#
# ELEVEN unrun steps, EIGHT kinds, FIVE rounds — 1, 2, 3, 10 and 11, because
# `evaluate.md` tells the look "there is no round clock" so round 10 is
# reachable — and the harness's REAL reason string, copied from `xo-run.py`'s
# `unrun_row`, which ends every reason with the launch failure in brackets.
"$PY" - "$R/journey-f3.json" <<'JEOF'
import json, sys
nopage = "lcars launch found nothing listening on the port the app chose after 60s"
why = ("the build never came up in a browser for this look, so this step was "
       "KEPT and then never executed and wrote no evidence - nothing about its "
       "shape was refused (%s)" % nopage)
kinds = ["shot", "shot", "shot", "click", "click", "navigate", "type",
         "viewport", "wait", "press", "hover"]
rounds = ["1", "2", "3", "10", "11"]
json.dump({"unrunSteps": [{"kind": k, "why": why, "key": "%02d-step" % (i + 1),
                           "for": "prd-1", "round": rounds[i % 5]}
                          for i, k in enumerate(kinds)],
           "noPage": nopage},
          open(sys.argv[1], "w"), indent=2)
JEOF
# THE OTHER HALF for FIX 6 — the same rows with NO `noPage` on the journey. The
# bracketed copy is then the ONLY copy there is and must survive untouched.
"$PY" - "$R/journey-f3.json" "$R/journey-f3-nonp.json" <<'JEOF'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("noPage")
json.dump(d, open(sys.argv[2], "w"), indent=2)
JEOF
# AND ONE WITH A ROUND LABEL THAT IS NOT A NUMBER — a producer may write one,
# and a numeric sort must not crash the scorer on it (FIX 8, second half).
"$PY" - "$R/journey-f3-oddrnd.json" <<'JEOF'
import json, sys
json.dump({"unrunSteps": [{"kind": "click", "why": "no page", "round": r}
                          for r in ("10", "2", "retry", "1")]},
          open(sys.argv[1], "w"), indent=2)
JEOF

jscore "$SCORE_PY" "$R/journey-f3.json"         f3
jscore "$SCORE_PY" "$R/journey-f3-nonp.json"    f3-nonp
jscore "$SCORE_PY" "$R/journey-f3-oddrnd.json"  f3-odd

# How many times the harness's one sentence appears in the section (FIX 6).
nopage_hits() { # <case-name>
  unrun_section "$1" |
    grep -cF "lcars launch found nothing listening on the port the app chose"
}

echo ""
echo "19/FIX 2 — the sentence the same report contradicts"

check "19k. CONTROL — the COUNT is still said" \
  'unrun_section f3 | grep -qF "I asked for 11 steps that the harness kept and then never ran"'
check "19l. CONTROL — the KINDS are still said, with their counts" \
  'unrun_section f3 | grep -qF "Those 11 were:" &&
   unrun_section f3 | grep -qF "\`shot\` x3" &&
   unrun_section f3 | grep -qF "\`click\` x2"'
check "19m. CONTROL — the HARNESS'\''S OWN WORDS are still said" \
  'unrun_section f3 |
     grep -qF "The harness'\''s own words for why there was no page: lcars launch"'
check "19n. CONTROL — and the measured closing fact is still said" \
  'unrun_section f3 | grep -qF "So every one of those steps is unchecked."'
check "19o. BEHAVIOUR — the report no longer tells him to discount what it showed him" \
  '! report_of f3 | grep -qF "has not seen it" &&
   ! report_of f3 | grep -qF "could not reach your build at all"'

MUT_F2="$TMPROOT/mut-f2-overreach.py"
mutate "$MUT_F2" 'w("\nSo %s unchecked.\n"' \
  'w("\nSo %s unchecked. A look that could not reach your build at all has not seen it.\n"' 1
jscore "$MUT_F2" "$R/journey-f3.json" mutf2
check "19p. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F2" "$SCORE_PY" && wrote mutf2 &&
   unrun_section mutf2 | grep -qF "I asked for 11 steps"'
check "19q. MUTATION RED — the overreach is back in his report" \
  'unrun_section mutf2 | grep -qF "could not reach your build at all has not seen it"'

echo ""
echo "19/FIX 3 — \"not a fault in your build\", where the build is often the cause"

check "19r. BEHAVIOUR — the unrun section claims NEITHER rig nor build" \
  '! unrun_section f3 | grep -qF "not a fault in your build" &&
   ! unrun_section f3 | grep -qF "gaps in my checking"'
check "19s. CONTROL — the facts that replaced nothing are all still there" \
  'unrun_section f3 | grep -qF "not refused, and not dropped for want of room" &&
   unrun_section f3 | grep -qF "there was no page to run them against"'
# THE OTHER HALF: the shared constant is PRE-EXISTING and its other call sites
# are untouched. Using it in the unrun section was this session's choice; using
# it over a harness REFUSAL is not, and must still happen.
"$PY" - "$R/journey-ref-ctl.json" <<'JEOF'
import json, sys
json.dump({"refusedSteps": [{"kind": "shot", "round": "1",
                             "why": "a shell escape the fence would not run"}]},
          open(sys.argv[1], "w"), indent=2)
JEOF
jscore "$SCORE_PY" "$R/journey-ref-ctl.json" f3-refctl
check "19t. CONTROL (other half) — the refusals section STILL carries the note" \
  'report_of f3-refctl | grep -qF "not a fault in your build"'

MUT_F3="$TMPROOT/mut-f3-blame.py"
mutate "$MUT_F3" 'to run %s against.\n\n"' \
  'to run %s against. These are gaps in my checking, not a fault in your build.\n\n"' 1
jscore "$MUT_F3" "$R/journey-f3.json" mutf3
check "19u. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F3" "$SCORE_PY" && wrote mutf3'
check "19v. MUTATION RED — the blame claim is back, two lines above the port" \
  'unrun_section mutf3 | grep -qF "not a fault in your build"'

echo ""
echo "19/FIX 4 — the looks count that contradicted the report'\''s own kind split"

# FIVE looks-questions, THREE of them with no photograph — the measured 5-vs-3
# shape. The tests lane is the only route past the earlier citation guard, so
# every row is settled on a real test case (see the note at the l-bare rig).
cat >"$R/criteria5.json" <<'C5'
{"criteria": [
  {"id": "prd-1", "text": "looks row 1", "source": "prd", "impact": "high"},
  {"id": "prd-2", "text": "looks row 2", "source": "prd", "impact": "high"},
  {"id": "prd-3", "text": "looks row 3", "source": "prd", "impact": "high"},
  {"id": "prd-4", "text": "looks row 4", "source": "prd", "impact": "high"},
  {"id": "prd-5", "text": "looks row 5", "source": "prd", "impact": "high"}]}
C5
"$PY" - "$R/tests5.json" <<'T5'
import json, sys
cases = ["PASS looks row %d" % i for i in range(1, 6)]
json.dump({"ran": True, "outcome": "passed", "command": "npm test",
           "outputTail": "\n".join(cases) + "\n5 passing\n",
           "testCases": cases, "truncated": False, "tailCapBytes": 8000},
          open(sys.argv[1], "w"), indent=2)
T5
"$PY" - "$R/v-looks5.json" <<'L5'
import json, sys
def row(i, shot):
    r = {"id": "prd-%d" % i, "text": "looks row %d" % i, "impact": "high",
         "status": "met", "kind": "looks", "evidence": "tests",
         "checkedBy": "test", "testQuote": "PASS looks row %d" % i,
         "note": "the suite says so"}
    if shot:
        r["shot"] = shot
    return r
json.dump({"score": "medium", "recommendation": "send-back",
           "summary": "I ran the CLI and read what it printed.",
           "criteria": [row(1, None), row(2, None), row(3, None),
                        row(4, "01-help.png"), row(5, "01-help.png")],
           "gaps": [], "escalations": [], "alsoChecked": [], "couldNot": []},
          open(sys.argv[1], "w"), indent=2)
L5
l5score() { # <scorer> <case-name>
  local d="$R/out/$2"
  rm -rf "$d"; mkdir -p "$d"
  "$PY" "$1" "$R/v-looks5.json" "$R/criteria5.json" "$d/verdict.json" \
        "" "$R/tests5.json" "" "" "" "" "" "" "" "$R/shots" \
        >"$d/stdout.txt" 2>"$d/stderr.txt" || :
}
l5score "$SCORE_PY" f4-five
# THE TWO NUMBERS, READ OFF HIS OWN REPORT. `split` first, then any UNSCOPED
# claim about how many looks-questions there are. A cured report makes no such
# claim at all and prints -1 for it.
two_numbers() { # <case-name> -> "<kind-split looks> <unscoped claim or -1>"
  "$PY" -c '
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"by the kind of question\.\*\* (\d+) (?:was|were) a looks-question", t)
u = re.search(r"(\d+|One) of the checks on your list ask(?:s)? what the screen", t)
n = -1
if u:
    n = 1 if u.group(1) == "One" else int(u.group(1))
print("%s %d" % (m.group(1) if m else "?", n))' "$R/out/$1/report.md" 2>/dev/null
}

check "19w. CONTROL — the rig really is the 5-vs-3 case" \
  '[ "$("$PY" -c "
import json,sys
d = json.load(open(sys.argv[1]))
print(\"%s %s\" % (d[\"questionSplit\"][\"looks\"],
                  len(d.get(\"looksWithNoPicture\") or [])))" "$(sfile f4-five)")" = "5 3" ]'
check "19x. CONTROL — and the kind split really prints 5 on his report" \
  'report_of f4-five | grep -qF "5 were a looks-question"'
check "19y. BEHAVIOUR — the section says what it counts: 3 that had no picture" \
  'looks_section f4-five |
     grep -qF "3 of the checks on your list that ask what the screen LOOKS LIKE" &&
   looks_section f4-five | grep -qF "had no photograph at any width"'
check "19z. BEHAVIOUR — and makes NO claim about how many looks-questions there are" \
  '[ "$(two_numbers f4-five)" = "5 -1" ]'
check "19aa. CONTROL (other half) — when every looks row lacks a picture, 1 and 1" \
  '[ "$(two_numbers l-bare)" = "1 -1" ] &&
   report_of l-bare | grep -qF "1 was a looks-question" &&
   looks_section l-bare |
     grep -qF "One of the checks on your list that ask what the screen"'

MUT_F4="$TMPROOT/mut-f4-count.py"
mutate "$MUT_F4" 'of the checks on your list that ask what the screen LOOKS "' \
                 'of the checks on your list ask what the screen LOOKS "' 1
l5score "$MUT_F4" mutf4-five
check "19ab. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F4" "$SCORE_PY" && wrote mutf4-five'
check "19ac. MUTATION RED — the two numbers contradict each other again (5 vs 3)" \
  '[ "$(two_numbers mutf4-five)" = "5 3" ]'

echo ""
echo "19/FIX 5 — a plural label may not wear a singular reason"

check "19ad. CONTROL — at N=1 the reason is the producer'\''s sentence, verbatim" \
  'unrun_section f1-ctl | grep -qF -- "- **1 x \`click\`** — no page" &&
   ! unrun_section f1-ctl | grep -qF "each one"'
check "19ae. BEHAVIOUR — at N=11 the singular sentence is DISTRIBUTED, not asserted" \
  'unrun_section f3 |
     grep -qF "— each one: the build never came up in a browser for this look" &&
   ! unrun_section f3 |
     grep -qE "^- \*\*11 steps\*\*.*— the build never came up"'
check "19af. CONTROL — the harness'\''s own words are not edited to fit" \
  'unrun_section f3 | grep -qF "so this step was KEPT and then never executed"'

MUT_F5="$TMPROOT/mut-f5-plural.py"
mutate "$MUT_F5" 'else "each one: %s" % _uhad["why"])' 'else _uhad["why"])' 1
jscore "$MUT_F5" "$R/journey-f3.json" mutf5
check "19ag. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F5" "$SCORE_PY" && wrote mutf5'
check "19ah. MUTATION RED — \"11 steps … so this step was KEPT\" comes back" \
  'unrun_section mutf5 |
     grep -qE "^- \*\*11 steps\*\*.*— the build never came up" &&
   ! unrun_section mutf5 | grep -qF "each one:"'

echo ""
echo "19/FIX 6 — the same sentence twice in three lines"

check "19ai. BEHAVIOUR — the harness'\''s sentence appears ONCE in the section" \
  '[ "$(nopage_hits f3)" = "1" ]'
check "19aj. CONTROL — and it is the labelled paragraph that keeps it" \
  'unrun_section f3 |
     grep -qF "The harness'\''s own words for why there was no page: lcars launch"'
check "19ak. CONTROL — nothing else on the bullet was lost with it" \
  'unrun_section f3 | grep -qF "nothing about its shape was refused"'
# AND A REASON THAT IS *ONLY* THE BRACKETED COPY keeps it — an empty bullet is
# a worse report than a repeated sentence.
"$PY" - "$R/journey-f3-bareonly.json" <<'JEOF'
import json, sys
nopage = "lcars launch found nothing listening on the port the app chose after 60s"
json.dump({"unrunSteps": [{"kind": "click", "why": "(%s)" % nopage, "round": "1"}],
           "noPage": nopage},
          open(sys.argv[1], "w"), indent=2)
JEOF
jscore "$SCORE_PY" "$R/journey-f3-bareonly.json" f3-bareonly
check "19ao2. CONTROL — a bullet is never stripped down to no reason at all" \
  'wrote f3-bareonly && reported f3-bareonly &&
   unrun_section f3-bareonly | grep -qE "^- \*\*1 x .click.\*\* .*lcars launch found nothing"'

check "19al. CONTROL (other half) — with no \`noPage\`, the only copy SURVIVES" \
  '[ "$(nopage_hits f3-nonp)" = "1" ] &&
   unrun_section f3-nonp | grep -qF "shape was refused (lcars launch found nothing" &&
   ! unrun_section f3-nonp | grep -qF "The harness'\''s own words"'

MUT_F6="$TMPROOT/mut-f6-twice.py"
mutate "$MUT_F6" 'if _unopage and _uwhy.endswith' 'if False and _uwhy.endswith' 1
jscore "$MUT_F6" "$R/journey-f3.json" mutf6
check "19am. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F6" "$SCORE_PY" && wrote mutf6'
check "19an. MUTATION RED — he reads the same sentence twice again" \
  '[ "$(nopage_hits mutf6)" = "2" ]'

echo ""
echo "19/FIX 7 — a partly-unreadable \`shots\` list dropped its bad leaf in silence"

mkgap '["01-help.png", 7]'   "$R/v-partial.json"
mkgap '["01-help.png"]'      "$R/v-whole.json"
score "$SCORE_PY" "$R/v-partial.json" f7-partial
score "$SCORE_PY" "$R/v-whole.json"   f7-whole
partial_flag() { # <case-name> -> True when the ENTRY records the partial loss
  "$PY" -c '
import json, sys
g = (json.load(open(sys.argv[1])).get("gaps") or [{}])[0]
print(bool(g.get("shotsRefusedPartial")))' "$R/out/$1/verdict.json" 2>/dev/null
}

check "19ao. CONTROL — a wholly honest list is still SILENT about any drop" \
  'wrote f7-whole && [ "$(partial_flag f7-whole)" = "False" ] &&
   ! notes_of f7-whole | grep -qF "the rest is dropped" &&
   ! report_of f7-whole | grep -qF "the rest is dropped"'
check "19ap. CONTROL — and the partial list still keeps the leaf it COULD read" \
  '[ "$(gap_shots f7-partial)" = "[\"01-help.png\"]" ]'
check "19aq. BEHAVIOUR — the drop is now SAID, in the notes, as the file'\''s rule is" \
  'notes_of f7-partial | grep -qF "something else in the same field that was not a path" &&
   report_of f7-partial | grep -qF "the rest is dropped"'
check "19ar. BEHAVIOUR — and it reaches the WIRE as its own field" \
  '[ "$(partial_flag f7-partial)" = "True" ]'
check "19as. BEHAVIOUR — the two reports are no longer byte-identical" \
  '! diff -q "$R/out/f7-whole/report.md" "$R/out/f7-partial/report.md" >/dev/null'
check "19at. BEHAVIOUR — but it is NOT called a wholly refused citation" \
  '[ "$(refused_flag f7-partial)" = "False" ] &&
   report_of f7-partial | grep -qF "see 01-help.png" &&
   ! report_of f7-partial | grep -qF "a picture was named, and I could not read"'

MUT_F7="$TMPROOT/mut-f7-silent.py"
mutate "$MUT_F7" 'shots_refused_partial = bool(shots and _unreadable_citation(_raw_shots))' \
                 'shots_refused_partial = False' 1
score "$MUT_F7" "$R/v-partial.json" mutf7-partial
score "$MUT_F7" "$R/v-whole.json"   mutf7-whole
check "19au. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F7" "$SCORE_PY" && wrote mutf7-partial &&
   [ "$(gap_shots mutf7-partial)" = "[\"01-help.png\"]" ]'
check "19av. MUTATION RED — the drop goes back to silence: no note, no wire field" \
  '[ "$(partial_flag mutf7-partial)" = "False" ] &&
   ! notes_of mutf7-partial | grep -qF "the rest is dropped"'
check "19aw. MUTATION RED — and the report is byte-identical to the honest one" \
  'diff -q "$R/out/mutf7-whole/report.md" "$R/out/mutf7-partial/report.md" >/dev/null'

echo ""
echo "19/FIX 8 — rounds sorted as strings"

check "19ax. BEHAVIOUR — rounds read in ROUND order, 1, 2, 3, 10, 11" \
  'unrun_section f3 | grep -qF "*(round 1, 2, 3, 10, 11)*" &&
   ! unrun_section f3 | grep -qF "*(round 1, 10, 11, 2, 3)*"'
check "19ay. CONTROL (other half) — a non-numeric round neither crashes nor vanishes" \
  'wrote f3-odd && reported f3-odd && ! crashed f3-odd &&
   unrun_section f3-odd | grep -qF "*(round 1, 2, 10, retry)*"'

MUT_F8="$TMPROOT/mut-f8-strsort.py"
mutate "$MUT_F8" 'if r.isdigit()' 'if False' 1
jscore "$MUT_F8" "$R/journey-f3.json"        mutf8
jscore "$MUT_F8" "$R/journey-f3-oddrnd.json" mutf8-odd
check "19az. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F8" "$SCORE_PY" && wrote mutf8 && wrote mutf8-odd'
check "19ba. MUTATION RED — the lexicographic order comes back" \
  'unrun_section mutf8 | grep -qF "*(round 1, 10, 11, 2, 3)*"'

echo ""
echo "19/FIX 9 — the most confident sentence, standing on the least evidence"

check "19bb. CONTROL — the demoted row still says what the look filed" \
  'report_of b-refused | grep -qF "MISMATCH IN YOUR BUILD" &&
   report_of b-refused | grep -qF "That is my limit, not your call."'
check "19bc. CONTROL — and the ruling stands: a scalar IS an unreadable citation" \
  '[ "$(refused_flag b-refused)" = "True" ] &&
   [ "$(demoted_flag b-refused)" = "True" ]'
check "19bd. BEHAVIOUR — it no longer claims the look NAMED a picture" \
  '! report_of b-refused | grep -qF "named a picture for it"'
check "19be. BEHAVIOUR — it describes the field it could not read instead" \
  'report_of b-refused |
     grep -qF "put something in the picture field that I could not read"'

MUT_F9="$TMPROOT/mut-f9-confident.py"
mutate "$MUT_F9" 'and put something in the picture "' 'and named a picture for it "' 1
score "$MUT_F9" "$R/b-refused.json" mutf9
check "19bf. the mutation is real and still a working scorer" \
  '! cmp -s "$MUT_F9" "$SCORE_PY" && wrote mutf9'
check "19bg. MUTATION RED — the overconfident clause is back" \
  'report_of mutf9 | grep -qF "named a picture for it"'

echo ""
echo "19/FIX 10 — a comment'\''s own arithmetic is a claim about the code"

# Fix round 2 wrote "~250 lines below" for a gap of ~490. Correcting exactly
# this class of false comment was the session's headline fix, so the numbers are
# RECOMPUTED here rather than eyeballed: every one of them goes red the moment a
# later edit moves either line.
arith() {
  "$PY" -c '
import re, sys
L = open(sys.argv[1], encoding="utf-8").read().splitlines()
clob = wire = note1 = note2 = 0
for i, ln in enumerate(L, 1):
    s = ln.strip()
    if s.startswith("why = \" \".join(str(row.get(\"why\")") and i > 5000:
        clob = i
    if "print(\"WHY" in s:
        wire = i
    if "printed as `WHY` on the wire" in s:
        note1 = i
    if "wire at line" in s:
        note2 = i
src = "\n".join(L)
m_near = re.search(r"on the wire ~(\d+)\n?", src)
m_line = re.search(r"wire at line (\d+)", src)
m_clob = re.search(r"BARE name `why` at line (\d+)", src)
m_up   = re.search(r"# ~(\d+) lines above still binds", src)
print("WIRELINE %s %s" % (m_line.group(1), wire))
print("CLOBLINE %s %s" % (m_clob.group(1), clob))
print("NEAR %s %s" % (m_near.group(1), wire - note1))
print("UP %s %s" % (m_up.group(1), note2 - clob))' "$SCORE_PY"
}
check "19bh. ACCURACY — the line the note gives for the WHY print is that line" \
  '[ "$(arith | sed -n "s/^WIRELINE //p")" = "6324 6324" ]'
check "19bi. ACCURACY — and the line it gives for the ledgered clobber is that line" \
  '[ "$(arith | sed -n "s/^CLOBLINE //p")" = "5828 5828" ]'
check "19bj. ACCURACY — \"~400 lines below\" is within 50 of the real distance" \
  '"$PY" -c "
import sys
a, b = sys.argv[1].split()
sys.exit(0 if abs(int(a) - int(b)) <= 50 else 1)" "$(arith | sed -n "s/^NEAR //p")"'
check "19bk. ACCURACY — \"~105 lines above\" is within 20 of the real distance" \
  '"$PY" -c "
import sys
a, b = sys.argv[1].split()
sys.exit(0 if abs(int(a) - int(b)) <= 20 else 1)" "$(arith | sed -n "s/^UP //p")"'
check "19bl. ACCURACY — the wrong number fix round 2 wrote is no longer CLAIMED" \
  '! unrun_block | grep -qF "on the wire ~250" &&
   unrun_block | grep -qF "THE ARITHMETIC IN A COMMENT IS A CLAIM ABOUT CODE"'

echo ""
echo "7. ZERO SPEND"
check "7a. no engine was invoked at any point" '[ ! -s "$SPEND_LOG" ]'

echo ""
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
