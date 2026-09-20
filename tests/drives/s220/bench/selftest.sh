#!/usr/bin/env bash
# ===========================================================================
# S220 bench · THE RULER'S OWN CHECK — does the scorer fire at all?
#
#   bash tests/drives/s220/bench/selftest.sh
#
# A benchmark that reports 0/5 is only evidence if it CAN report 5/5. This
# feeds score.py hand-written verdicts — a look that found everything, a look
# that found nothing, and a look that cried wolf over the two correct controls
# — and checks the number that comes back. No worker, no browser, no spend.
#
# Run it after ANY change to score.py or known-answers/*.json.
# ===========================================================================
set -uo pipefail
BENCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

mk() { # <dir> <verdict-json-on-stdin>
  mkdir -p "$1"; cat >"$1/verdict.json"
}
num() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$1" "$2"; }

# --- 1. a look that found every planted fault -------------------------------
# Deliberately NOT worded like anything a real look has said — the rule has to
# turn on naming the part and describing the kind, not on matching a transcript.
mk "$WORK/all" <<'JSON'
{ "score": "low", "criteria": [
 {"id":"a","status":"gap","text":"Save reading","note":"the icon on this control is far too large — it overflows the button that holds it"},
 {"id":"b","status":"gap","text":"Publish board","note":"the label is wrapping onto two lines inside a control this narrow"},
 {"id":"c","status":"gap","text":"the alertChip","note":"its colour is wrong: built green where the drawing has it red"},
 {"id":"d","status":"gap","text":"helpLink","note":"its position is wrong — bottom left of the head instead of the top right"},
 {"id":"e","status":"gap","text":"Export CSV","note":"drawn, but missing from the build entirely"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/all" "$BENCH/known-answers/planted.json" \
  --json "$WORK/all.json" >/dev/null 2>&1
[ "$(num "$WORK/all.json" found)" = "5" ] \
  && ok "a look that reported all five scores 5/5 — the rule CAN fire" \
  || bad "a look that reported all five scored $(num "$WORK/all.json" found)/5 — the ruler is broken"
[ "$(num "$WORK/all.json" falseAlarms)" = "0" ] \
  && ok "…and it raised no false alarm doing it" \
  || bad "…but it counted $(num "$WORK/all.json" falseAlarms) false alarms it should not have"
[ "$(num "$WORK/all.json" gradeEarned)" = "True" ] \
  && ok "…and the grade counts as EARNED, because a declared fault drove it" \
  || bad "…but the grade did not count as earned"

# --- 2. "I could not see it" must never earn recall -------------------------
mk "$WORK/blind" <<'JSON'
{ "score": "low", "criteria": [
 {"id":"a","status":"untested","text":"Save reading","note":"I could not reach this control, so I could not tell whether its icon is too large"},
 {"id":"b","status":"untested","text":"Publish board","note":"unreachable — I cannot say whether the label wraps onto two lines"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/blind" "$BENCH/known-answers/planted.json" \
  --json "$WORK/blind.json" >/dev/null 2>&1
[ "$(num "$WORK/blind.json" found)" = "0" ] \
  && ok "couldn't-check earns no recall, however exactly it describes the fault" \
  || bad "a couldn't-check earned recall — $(num "$WORK/blind.json" found) found"

# --- 3. "it worked" must never earn recall ----------------------------------
mk "$WORK/met" <<'JSON'
{ "score": "high", "criteria": [
 {"id":"a","status":"met","text":"Save reading","note":"the icon is too large and overflows the button, but it is fine"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/met" "$BENCH/known-answers/planted.json" \
  --json "$WORK/met.json" >/dev/null 2>&1
[ "$(num "$WORK/met.json" found)" = "0" ] \
  && ok "a criterion graded 'worked' earns no recall, whatever its note says" \
  || bad "a 'worked' criterion earned recall"
[ "$(num "$WORK/met.json" gradeOk)" = "False" ] \
  && ok "…and a HIGH grade on a build with five faults reads as too high" \
  || bad "…but a high grade passed the grade check"

# --- 4. crying wolf over the correct controls -------------------------------
mk "$WORK/wolf" <<'JSON'
{ "score": "low", "criteria": [
 {"id":"a","status":"gap","text":"the tabBar","note":"the tabs sit in the wrong position — they should not run flush to the edge"},
 {"id":"b","status":"gap","text":"noticeLabel","note":"this label wraps onto two lines and should not"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/wolf" "$BENCH/known-answers/planted.json" \
  --json "$WORK/wolf.json" >/dev/null 2>&1
[ "$(num "$WORK/wolf.json" falseAlarms)" = "2" ] \
  && ok "flagging both correct controls counts 2 false alarms" \
  || bad "flagging both correct controls counted $(num "$WORK/wolf.json" falseAlarms)"
[ "$(num "$WORK/wolf.json" found)" = "0" ] \
  && ok "…and buys no recall at all" \
  || bad "…and somehow bought recall"

# --- 5. half a match is no match --------------------------------------------
# Names the part but complains of nothing; complains loudly but names nothing.
mk "$WORK/half" <<'JSON'
{ "score": "low", "criteria": [
 {"id":"a","status":"gap","text":"Save reading","note":"the button sits 4px lower than the row beside it"},
 {"id":"b","status":"gap","text":"somewhere on this screen","note":"an icon is far too large and overflows the control holding it"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/half" "$BENCH/known-answers/planted.json" \
  --json "$WORK/half.json" >/dev/null 2>&1
[ "$(num "$WORK/half.json" found)" = "0" ] \
  && ok "naming the part without the fault, or the fault without the part, scores nothing" \
  || bad "half a match scored $(num "$WORK/half.json" found) — the rule is looser than README says"

# --- 6. the real arm's known answers are wired up too -----------------------
mk "$WORK/real" <<'JSON'
{ "score": "low", "criteria": [
 {"id":"a","status":"gap","text":"Pull data & start","note":"the icon here is much too big for the control"},
 {"id":"b","status":"gap","text":"the start card","note":"it offers August 2026 and the collect step it leads to says September 2026"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/real" "$BENCH/known-answers/real.json" \
  --json "$WORK/real.json" >/dev/null 2>&1
[ "$(num "$WORK/real.json" found)" = "2" ] \
  && ok "the real arm's answers match the same way (2 of 5)" \
  || bad "the real arm matched $(num "$WORK/real.json" found)/5 where 2 were reported"

# ===========================================================================
# FIX ROUND 1 — the four ways the ruler was caught lying (D1–D4). Every case
# below is the TESTER'S OWN, word for word, so the cure is checked against
# what actually fooled it and not against a paraphrase of it.
# ===========================================================================

# --- 7. D1: a SILENT MODEL must score zero in its own column ----------------
# The tester muted every criterion the model wrote to "met" — the model saying
# nothing at all — and the drill still reported 5/5, "medium, earned". The
# detectors were carrying the whole score and the scoreboard could not say so.
mkdir -p "$WORK/mute"
cat >"$WORK/mute/verdict.json" <<'JSON'
{ "score": "medium", "criteria": [
 {"id":"a","status":"met","text":"Save reading","note":"this one is fine"},
 {"id":"b","status":"met","text":"Publish board","note":"this one is fine too"}
] }
JSON
cat >"$WORK/mute/observations.json" <<'JSON'
{ "thresholds": {}, "observations": [
 {"kind":"oversized-icon","says":"the \"Save reading\" button holds an icon 44px tall inside a control only 34px tall — the icon is bigger than the button it sits in, and its label runs onto 1 line"},
 {"kind":"wrapped-label","says":"the \"Publish board\" button's label runs onto 2 lines in the build where your drawing has 1"}
] }
JSON
python3 "$BENCH/score.py" "$WORK/mute" "$BENCH/known-answers/planted.json" \
  --json "$WORK/mute.json" >/dev/null 2>&1
[ "$(num "$WORK/mute.json" foundByModel)" = "0" ] \
  && ok "a model that says NOTHING scores 0 in the model column, however much the detectors found" \
  || bad "a silent model scored $(num "$WORK/mute.json" foundByModel) by its own eye"
[ "$(num "$WORK/mute.json" foundByDetector)" = "2" ] \
  && ok "…and the detectors' own column reports what THEY found" \
  || bad "…but the detector column read $(num "$WORK/mute.json" foundByDetector), not 2"
[ "$(num "$WORK/mute.json" found)" = "2" ] \
  && ok "…and the union is still printed, beside them and never instead of them" \
  || bad "…but the union read $(num "$WORK/mute.json" found)"

# --- 8. D2: the name from the question, the fault from an unrelated clause --
# Tester's exact case: ONE criterion whose PRD text names all four buttons,
# whose note says they render CORRECTLY, and which complains only about an
# org-picker that is nothing to do with them. It scored 4/5 FOUND.
mkdir -p "$WORK/crosstalk"
cat >"$WORK/crosstalk/verdict.json" <<'JSON'
{"grade":"medium","criteria":[
 {"id":"c1","status":"gap",
  "text":"The MBR flow offers Pull data & start, Continue to builder, Lock month and Back to builder, and the start card shows August 2026 while the collect step shows September 2026.",
  "note":"All of those controls render correctly and match the drawing. The only problem I found is elsewhere: the org-picker icon is 72px and far too big for its 20px chip, and its label wraps onto two lines.",
  "reason":"The org picker in the page header is unrelated to the MBR flow but it is visibly broken."}
]}
JSON
python3 "$BENCH/score.py" "$WORK/crosstalk" "$BENCH/known-answers/real.json" \
  --json "$WORK/crosstalk.json" >/dev/null 2>&1
[ "$(num "$WORK/crosstalk.json" found)" = "0" ] \
  && ok "a criterion that says the four buttons are FINE scores none of them, whatever it complains about elsewhere" \
  || bad "the org-picker note still bought $(num "$WORK/crosstalk.json" found)/5 for parts it called correct"

# --- 9. D3: three findings any person would credit --------------------------
# Tester's exact wordings. None of them carries a number over the 40px floor
# the old oversized-icon regex demanded; r3's REAL icon is 34px in a 32px
# control, so that floor made a measured known fault unreachable.
mkdir -p "$WORK/plain"
cat >"$WORK/plain/verdict.json" <<'JSON'
{"grade":"high","criteria":[
 {"id":"b1","status":"gap","text":"Lock month button parity.",
  "note":"I measured it. Its icon is 34px. The control is only 32px. The caption needs a second row to fit.",
  "reason":"It does not match the drawing."},
 {"id":"b2","status":"gap","text":"The button that kicks off the pull.",
  "note":"The download glyph bursts out past the edges of the pill and the caption needs three rows.",
  "reason":"Clearly wrong beside the mockup."},
 {"id":"b3","status":"gap","text":"Month continuity through the flow.",
  "note":"The month I chose on the first card is not the month the next screen reports. It silently advances by one.",
  "reason":"The value does not carry."}
]}
JSON
python3 "$BENCH/score.py" "$WORK/plain" "$BENCH/known-answers/real.json" \
  --json "$WORK/plain.json" >/dev/null 2>&1
[ "$(num "$WORK/plain.json" found)" = "3" ] \
  && ok "three findings in plain measured English are credited (34px in a 32px control included)" \
  || bad "plain English scored $(num "$WORK/plain.json" found)/3 — the ruler still wants the harness's own wording"
[ "$(num "$WORK/plain.json" foundByModel)" = "3" ] \
  && ok "…and all three land in the MODEL's column, because the model is who said them" \
  || bad "…but only $(num "$WORK/plain.json" foundByModel) landed in the model column"

# --- 10. D4: crying wolf however it is worded -------------------------------
# Both tester quotes about the declared-correct Preview control. Neither uses
# the literal word "button", which is all the old pattern would answer to.
mkdir -p "$WORK/wolf1" "$WORK/wolf2"
cat >"$WORK/wolf1/verdict.json" <<'JSON'
{"grade":"high","criteria":[
 {"id":"x1","status":"gap","text":"Preview control parity.",
  "note":"The Preview control is the wrong shade of blue and sits too far left of where it is drawn.",
  "reason":"It does not match the mockup."}]}
JSON
cat >"$WORK/wolf2/verdict.json" <<'JSON'
{"grade":"high","criteria":[
 {"id":"x2","status":"gap","text":"Preview.",
  "note":"Preview is drawn in the mock but I could not find it anywhere in the build.",
  "reason":"Missing."}]}
JSON
python3 "$BENCH/score.py" "$WORK/wolf1" "$BENCH/known-answers/real.json" \
  --json "$WORK/wolf1.json" >/dev/null 2>&1
python3 "$BENCH/score.py" "$WORK/wolf2" "$BENCH/known-answers/real.json" \
  --json "$WORK/wolf2.json" >/dev/null 2>&1
[ "$(num "$WORK/wolf1.json" falseAlarms)" = "1" ] \
  && ok "\"the wrong shade of blue and sits too far left\" on a correct control IS a false alarm" \
  || bad "the wrong-shade cry of wolf counted $(num "$WORK/wolf1.json" falseAlarms)"
[ "$(num "$WORK/wolf2.json" falseAlarms)" = "1" ] \
  && ok "…and so is \"drawn but I could not find it\", which never says the word button" \
  || bad "the could-not-find cry of wolf counted $(num "$WORK/wolf2.json" falseAlarms)"

# --- 11. D4: a correct control nothing was DRAWN for is not a pass ----------
# The real arm's one correct control has a drawn box of 0x0 — there was never
# anything to hold the build against, so "zero false alarms" over it was a
# number about nothing.
mkdir -p "$WORK/nodraw"
cat >"$WORK/nodraw/verdict.json" <<'JSON'
{ "score": "low", "criteria": [
 {"id":"a","status":"gap","text":"Pull data & start","note":"the icon here is much too big for the control"}] }
JSON
cat >"$WORK/nodraw/pairs.json" <<'JSON'
{ "pairs": [ {"part":"preview","name":"Preview",
   "drawn":{"box":{"x":0,"y":0,"w":0,"h":0},"lines":1},
   "built":{"box":{"x":1077,"y":240,"w":71,"h":30},"lines":1}} ] }
JSON
python3 "$BENCH/score.py" "$WORK/nodraw" "$BENCH/known-answers/real.json" \
  --json "$WORK/nodraw.json" >/dev/null 2>&1
[ "$(num "$WORK/nodraw.json" notComparable)" = "1" ] \
  && ok "a declared-correct control with a 0x0 drawn box is reported NOT COMPARABLE, not passed" \
  || bad "a control nothing was drawn for still counted as a clean pass"

# ===========================================================================
# FIX ROUND 2 — D-A and D-B. Both cases below are the TESTER'S OWN probes,
# word for word.
# ===========================================================================

# --- 12. D-A: the HARNESS's own sentence must not be credited to the model --
# The tester silenced the look, set one criterion to "gap", wrote the finding
# into its `reason`, and left the `reasonByHarness: true` flag the verdict
# stamps at birth — the record's own word that the harness wrote that
# sentence. The drill handed it back "model 1/5, 1 in its own words".
mkdir -p "$WORK/harnessreason"
cat >"$WORK/harnessreason/verdict.json" <<'JSON'
{"score":"medium","criteria":[
 {"id":"h1","status":"gap","text":"Pull data & start",
  "reasonByHarness": true,
  "reason":"Impact high because the whole MBR flow starts from it. I tried measuring the control; I saw the icon is 55px inside a 38px control, bigger than the button it sits in. Outcome: didn't work."}
]}
JSON
python3 "$BENCH/score.py" "$WORK/harnessreason" "$BENCH/known-answers/real.json" \
  --json "$WORK/harnessreason.json" >/dev/null 2>&1
[ "$(num "$WORK/harnessreason.json" foundByModel)" = "0" ] \
  && ok "a finding the record says the HARNESS wrote earns the model nothing" \
  || bad "a harness-written reason scored the model $(num "$WORK/harnessreason.json" foundByModel) 'in its own words'"
[ "$(num "$WORK/harnessreason.json" foundByHarness)" = "1" ] \
  && ok "…it is counted, in the harness's own column, beside the model's" \
  || bad "…but the harness column read $(num "$WORK/harnessreason.json" foundByHarness)"
# …and the SAME sentence without the flag is the look's own words again. The
# flag is read; nothing is inferred from the wording.
mkdir -p "$WORK/ownreason"
sed 's/"reasonByHarness": true,//' "$WORK/harnessreason/verdict.json" \
  >"$WORK/ownreason/verdict.json"
python3 "$BENCH/score.py" "$WORK/ownreason" "$BENCH/known-answers/real.json" \
  --json "$WORK/ownreason.json" >/dev/null 2>&1
[ "$(num "$WORK/ownreason.json" foundByModel)" = "1" ] \
  && ok "…and the same words UNflagged do count for the model — the flag is read, not the wording" \
  || bad "an unflagged reason scored $(num "$WORK/ownreason.json" foundByModel) for the model"

# --- 13. D-B: a measurement pair read the way a person writes it ------------
# Six phrasings the tester measured as MISSES against round 1's replacement
# for the 40px floor. The last two are what a person actually writes.
phr_no=0
must_match() { # <note-prose>
  phr_no=$((phr_no+1))
  local d="$WORK/phr$phr_no"
  mkdir -p "$d"
  python3 - "$d/verdict.json" "$1" <<'PY'
import json, sys
json.dump({"score": "low", "criteria": [
    {"id": "p1", "status": "gap", "text": "Lock month button parity.",
     "note": sys.argv[2], "reason": "It does not match the drawing."}]},
    open(sys.argv[1], "w"))
PY
  python3 "$BENCH/score.py" "$d" "$BENCH/known-answers/real.json" \
    --json "$d.json" >/dev/null 2>&1
  [ "$(num "$d.json" foundByModel)" = "1" ] \
    && ok "credited: \"$1\"" \
    || bad "MISSED: \"$1\" — the comparator still wants a magic word"
}
must_match "Lock month holds a 34px icon inside a 32px control"
must_match "Lock month has a 34px icon in a 32px button"
must_match "Lock month has a 34px icon inside a 32px-tall control"
must_match "the Lock month icon measures 34px tall inside a 32px tall button"
must_match "Lock month has an icon taller than the button it sits in"
must_match "on Lock month the icon is taller than the button that contains it"

# --- 14. F2: the comparator did not know the word "arrow" -------------------
# The vocabulary was the harness's OWN short list (icon/glyph/svg/chevron), so
# the identical sentence scored 1 with "icon" in it and 0 with "arrow" — and
# the build's Continue-to-builder icon IS an arrow: the look's own words for
# it are "an oversized arrow icon". First case is the tester's, word for word.
must_match "on the Lock month control the arrow overflows its 32px frame at 34px"
must_match "on Lock month the arrow is taller than the button it sits in"
must_match "Lock month has a 34px symbol in a 32px control"

# …and the widening changes NOTHING about which way the comparison points:
# an arrow that FITS is not a fault, and a word that merely CONTAINS an icon
# word ("bookmark", "remarkable") is not an icon word.
mkdir -p "$WORK/fits2" "$WORK/notanicon"
cat >"$WORK/fits2/verdict.json" <<'JSON'
{"score":"low","criteria":[
 {"id":"f2","status":"gap","text":"Lock month button parity.",
  "note":"Lock month has a 16px arrow inside a 32px control, smaller than the button it sits in.",
  "reason":"Measured."}]}
JSON
python3 "$BENCH/score.py" "$WORK/fits2" "$BENCH/known-answers/real.json" \
  --json "$WORK/fits2.json" >/dev/null 2>&1
[ "$(num "$WORK/fits2.json" foundByModel)" = "0" ] \
  && ok "an ARROW that fits its control is still not an oversized icon" \
  || bad "a 16px arrow in a 32px control was scored as oversized"
cat >"$WORK/notanicon/verdict.json" <<'JSON'
{"score":"low","criteria":[
 {"id":"n1","status":"gap","text":"Lock month button parity.",
  "note":"The bookmark copy is too big for the remarkable heading above it.",
  "reason":"Wording."}]}
JSON
python3 "$BENCH/score.py" "$WORK/notanicon" "$BENCH/known-answers/real.json" \
  --json "$WORK/notanicon.json" >/dev/null 2>&1
[ "$(num "$WORK/notanicon.json" foundByModel)" = "0" ] \
  && ok "\"bookmark\" and \"remarkable\" are not icon words" \
  || bad "a word merely CONTAINING an icon word scored as one"

# …and the comparison still points ONE way: an icon that FITS is not a fault,
# and the declared-correct control is still a false alarm when cried over.
mkdir -p "$WORK/fits"
cat >"$WORK/fits/verdict.json" <<'JSON'
{"score":"low","criteria":[
 {"id":"f1","status":"gap","text":"Lock month button parity.",
  "note":"Lock month holds a 16px icon inside a 32px control and the icon is smaller than the button it sits in.",
  "reason":"Measured."}]}
JSON
python3 "$BENCH/score.py" "$WORK/fits" "$BENCH/known-answers/real.json" \
  --json "$WORK/fits.json" >/dev/null 2>&1
[ "$(num "$WORK/fits.json" foundByModel)" = "0" ] \
  && ok "an icon that FITS its control is not an oversized icon, however measured" \
  || bad "a 16px icon in a 32px control was scored as oversized"

printf '\nS220 bench selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
