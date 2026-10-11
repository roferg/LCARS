#!/usr/bin/env bash
#
# S240 FIX ROUND 3 — THE ATTACHMENT THAT ATTACHED NOTHING.
#
# THE SAME MISTAKE ROUND 2 CURED, TWO MORE TIMES IN THE SAME FILE. Round 2 fixed
# `evidence_ref`: it probed `<shotsdir>/<name> + ".png"` against a live shot name
# that ALREADY CARRIES ITS EXTENSION (`01-help.txt`), looked for
# `01-help.txt.png`, found nothing, and told seven bug PRDs that the evidence
# "was not retained" while the files sat in `shots/look-1/`.
#
# The identical `sh + ".png"` survived on the ATTACHMENTS path:
#
#   xo-logs.py:614  present = [sh for sh in shots
#                              if os.path.exists(os.path.join(shotsdir, sh + ".png"))]
#   xo-logs.py:632  ",".join(os.path.join(shotsdir, sh + ".png") for sh in shots)
#
# so `xo.sh`'s guard — `[ -f "$s" ] && args+=(--attach "$s")` — was handed
# `…/01-help.txt.png`, a path to nothing, and attached NOTHING. MEASURED on the
# live look's own verdict (a COPY of it): 5 shot paths emitted across 7 filed
# tickets, ONE of them a real file, FOUR of them `….txt.png` phantoms — so 1 of
# 7 tickets carried a picture a fix worker could open.
#
# `shot_selector` (xo-logs.py:148) failed the same way for the same reason: it
# opened `<name> + ".json"`, i.e. `01-help.txt.json`. Its need is NOT "any file
# of that name" — it is specifically the `.json` readout beside the shot — so the
# cure there is the STEM (`01-help.json`), through the same candidate ladder.
#
# THE CURE IS ROUND 2'S, MADE REUSABLE: `shot_candidates` / `shot_file` try the
# name EXACTLY AS GIVEN first, then `<name><ext>`, then `<stem><ext>` — one
# ladder, read by all three call sites, so the two halves cannot drift apart
# again. Every assertion below has a POSITIVE CONTROL on a bare name
# (`shot-01`), because the round-2 defect was created by trading one half for the
# other.
#
# ZERO SPEND. No worker CLI, no browser, no network. A PATH shim stubs `claude`
# AND `copilot` and is PROVEN to fire before "no spend" is claimed.
#
# Usage: bash tests/lcars-xo-attach.test.sh
#        LCARS_XO_LIVE_LOOK=<mission-dir> bash tests/lcars-xo-attach.test.sh
#          ... also re-measures the real live look. The directory is COPIED
#          before it is read; the live evidence is never written to.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-xo/xo.sh"
LOGSPY="$REPO_ROOT/skills/lcars-xo/xo-logs.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# ─── THE NO-SPEND SHIM ───────────────────────────────────────────────────────
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

US=$'\x1f'   # the record separator xo-logs.py prints with (RS in the script)

echo
echo "=== lcars xo: the attachment that attached nothing ==="
echo
printf '── 0. the shim is proven to fire ──\n'
SHIM_RC=0; claude --probe >/dev/null 2>&1 || SHIM_RC=$?
check "0a. the claude shim intercepts (so a later silent log means no spend)" \
  "[ '$SHIM_RC' = 97 ] && grep -q '^claude --probe' '$SPEND_LOG'"
SHIM_RC=0; copilot --probe >/dev/null 2>&1 || SHIM_RC=$?
check "0b. the copilot shim intercepts too" \
  "[ '$SHIM_RC' = 97 ] && grep -q '^copilot --probe' '$SPEND_LOG'"
: >"$SPEND_LOG"

# ─── THE SHOTS DIRECTORY, SHAPED EXACTLY LIKE THE LIVE ONE ───────────────────
# `shots/look-1/` of the only live look anyone has driven holds, side by side:
#   01-help.txt + 01-help.json          a CLI transcript and its readout
#   08-publish.txt + 08-publish.json    ditto
#   shot-01.png + shot-01.json          a real screenshot, the BARE name
# There is NO `01-help.txt.png` and there never was.
SHOTS="$TMPROOT/shots/look-1"
mkdir -p "$SHOTS"
printf 'Usage: relay [OPTIONS] COMMAND\n  file   file a request\n' >"$SHOTS/01-help.txt"
printf 'publishing…\nremote: github.com\n' >"$SHOTS/08-publish.txt"
printf 'PNGDATA' >"$SHOTS/shot-01.png"
printf 'a caption for shot-01\n' >"$SHOTS/shot-01.txt"
cat >"$SHOTS/01-help.json" <<'J'
{"url": "cli:relay --help", "selector": "#relay-help", "clip": {"x": 0, "y": 0, "w": 800, "h": 200}}
J
cat >"$SHOTS/08-publish.json" <<'J'
{"url": "cli:relay publish", "selector": "#relay-publish", "clip": {"x": 0, "y": 0, "w": 800, "h": 200}}
J
cat >"$SHOTS/shot-01.json" <<'J'
{"url": "http://127.0.0.1:8111/", "selector": "#board-header", "clip": {"x": 0, "y": 0, "w": 600, "h": 80}}
J

cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "relay --help lists the file command", "source": "prd", "primary": true, "notVisual": true},
  {"id": "prd-4", "text": "the board header reads Request Relay", "source": "prd", "primary": true},
  {"id": "prd-6", "text": "publish names the host the config stored", "source": "prd", "primary": true, "notVisual": true}
 ]}
C

# THE VERDICT, with the live look's own shot names verbatim. prd-1 and prd-6 cite
# EXTENSION-CARRYING names; prd-4 is the POSITIVE CONTROL — a bare `shot-01`,
# which is what every browser/drawing shot is called and what must keep working.
cat >"$TMPROOT/verdict.json" <<'V'
{"mission": "m", "score": "low", "recommendation": "send-back",
 "gaps": [
  {"criterion": "prd-1", "kind": "contradiction", "title": "help does not list file",
   "expected": "the file command listed in --help", "saw": "no file command",
   "sawInstead": "a help text with only list and publish",
   "evidence": "transcript", "shots": ["01-help.txt", "08-publish.txt"]},
  {"criterion": "prd-4", "kind": "contradiction", "title": "the header reads Relay",
   "expected": "a header reading Request Relay", "saw": "a header reading Relay",
   "sawInstead": "a header reading Relay", "evidence": "picture", "shots": ["shot-01"]},
  {"criterion": "prd-6", "kind": "contradiction", "title": "publish prints a hardcoded host",
   "expected": "the host the config stored", "saw": "a hardcoded github.com",
   "sawInstead": "a hardcoded github.com", "evidence": "transcript", "shots": ["08-publish.txt"]}
 ],
 "criteria": [
  {"id": "prd-1", "status": "gap", "impact": "high", "evidence": "transcript",
   "checkedBy": "cli", "shot": "01-help.txt", "note": "ran it and there is no file command"},
  {"id": "prd-4", "status": "gap", "impact": "medium", "evidence": "picture",
   "checkedBy": "browser", "shot": "shot-01", "note": "the header is wrong"},
  {"id": "prd-6", "status": "gap", "impact": "high", "evidence": "transcript",
   "checkedBy": "cli", "shot": "08-publish.txt", "note": "it printed the hardcoded host"}
 ]}
V

# ─── THE DRIVE: the real xo-logs.py, the real plan records ───────────────────
OUT="$TMPROOT/logs"
PLAN="$("$PY" "$LOGSPY" "$TMPROOT/verdict.json" "$TMPROOT/criteria.json" "$OUT" "$SHOTS" 2>"$TMPROOT/logs.err")"
printf '%s\n' "$PLAN" >"$TMPROOT/plan.txt"

# The attachments CSV for one criterion, read out of the GAP record by field.
csv_of() { # <criterion>
  "$PY" - "$TMPROOT/plan.txt" "$1" <<'P'
import sys
rows = [l.rstrip("\n").split("\x1f") for l in open(sys.argv[1])]
for f in rows:
    if f and f[0] == "GAP" and len(f) > 4 and f[4] == sys.argv[2]:
        print(f[3]); break
P
}
# What `xo.sh` would ACTUALLY attach: its guard is `[ -f "$s" ]`, nothing more.
attached_of() { # <criterion>  -> one existing path per line
  local s
  for s in $(csv_of "$1" | tr ',' ' '); do [ -f "$s" ] && printf '%s\n' "$s"; done
}

printf '\n── 1. the fixture is the live shape, and the drive produced records ──\n'
check "1a. fixture. there is no 01-help.txt.png on disk (there never was)" \
  "[ -f '$SHOTS/01-help.txt' ] && [ ! -e '$SHOTS/01-help.txt.png' ]"
check "1b. fixture. the bare-name control IS a real .png on disk" \
  "[ -f '$SHOTS/shot-01.png' ]"
check "1c. three gaps were filed" \
  "[ \"\$(grep -c '^GAP' '$TMPROOT/plan.txt')\" = 3 ]"
check "1d. fixture. the CSV field is really being read (not an empty string)" \
  "[ -n \"\$(csv_of prd-4)\" ]"

printf '\n── 2. THE DEFECT: an extension-carrying shot is found and ATTACHED ──\n'
check "2a. prd-1's attachments CSV cites the transcript that is on disk" \
  "csv_of prd-1 | grep -q '/01-help\.txt\(,\|$\)'"
check "2b. prd-1 would really be attached: xo.sh's [ -f ] guard passes twice" \
  "[ \"\$(attached_of prd-1 | wc -l | tr -d ' ')\" = 2 ]"
check "2c. prd-6's single transcript is attached" \
  "[ \"\$(attached_of prd-6 | wc -l | tr -d ' ')\" = 1 ]"
check "2d. POSITIVE CONTROL. the BARE name still resolves through the ext probe" \
  "attached_of prd-4 | grep -q '/shot-01\.png$'"
check "2e. every path in every attachments CSV is a file that EXISTS" \
  "[ \"\$(\"$PY\" - '$TMPROOT/plan.txt' <<'P'
import os, sys
bad = [p for l in open(sys.argv[1]) for f in [l.rstrip('\n').split('\x1f')]
       if f[0] == 'GAP' for p in f[3].split(',') if p and not os.path.isfile(p)]
print(len(bad))
P
)\" = 0 ]"
check "2f. and NO path anywhere glues an extension onto one already there" \
  "! grep -q '\.txt\.png\|\.txt\.json\|\.png\.txt\|\.json\.png' '$TMPROOT/plan.txt'"

printf '\n── 3. the PRD prose describes the shots that are there ──\n'
check "3a. prd-1's PRD names the transcript among Number One's shots" \
  "grep -q \"Number One's shots of the running build:.*01-help\.txt\" '$OUT/1.md'"
check "3b. POSITIVE CONTROL. the bare-name PRD still names its shot" \
  "grep -q \"Number One's shots of the running build:.*shot-01\" '$OUT/2.md'"
check "3c. the PRD still cites the evidence path round 2 cured (no regression)" \
  "grep -q 'Recorded in \`.*01-help\.txt\`' '$OUT/1.md'"
check "3d. POSITIVE CONTROL. and the bare-name PRD still cites its own .png" \
  "grep -q 'Recorded in \`.*shot-01\.png\`' '$OUT/2.md'"
check "3e. no PRD claims the evidence was not retained" \
  "! grep -rq 'was not retained' '$OUT/'"

printf '\n── 4. shot_selector: the readout beside an extension-carrying shot ──\n'
cat >"$TMPROOT/sel.py" <<'P'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("xl", os.path.join(sys.argv[1], "xo-logs.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
d = sys.argv[2]
print("EXT=[%s] BARE=[%s] MISSING=[%s]" % (m.shot_selector(d, "01-help.txt"),
                                           m.shot_selector(d, "shot-01"),
                                           m.shot_selector(d, "no-such-shot")))
P
SEL="$("$PY" "$TMPROOT/sel.py" "$REPO_ROOT/skills/lcars-xo" "$SHOTS" 2>&1)"
check "4a. fixture. the probe really ran (it printed its three readings)" \
  "grep -q 'EXT=\[.*\] BARE=\[.*\] MISSING=\[' <<<\"\$SEL\""
check "4b. an extension-carrying name finds its .json readout by STEM" \
  "[ \"\$SEL\" = 'EXT=[#relay-help] BARE=[#board-header] MISSING=[]' ]"

printf '\n── 5. ONE ladder, not two resolvers ──\n'
check "5a. the resolution is a named shared helper" \
  "grep -q '^def shot_candidates' '$LOGSPY' && grep -q '^def shot_file' '$LOGSPY'"
# CODE lines only — the comments above the cure quote the old expressions on
# purpose, to say what went wrong, and must not make this read green or red.
code_of() { grep -vE '^[[:space:]]*#' "$LOGSPY"; }
check "5b. fixture. the code-only reader really sees the file (not an empty pipe)" \
  "[ \"\$(code_of | grep -c 'def shot_file')\" -ge 1 ]"
check "5c. no CALL SITE glues an extension on by hand any more" \
  "! code_of | grep -q 'sh + \"\.png\"' && ! code_of | grep -q 'name + \"\.json\"'"
check "5d. fixture. CONTROL — the parent's expressions ARE still findable as prose" \
  "grep -q 'sh + \"\.png\"' '$LOGSPY'"
check "5e. round 2's exact-name-first rule is what the ladder tries first" \
  "grep -q 'EXACTLY AS IT WAS GIVEN' '$LOGSPY'"

printf '\n── 6. the fence, and nothing spent ──\n'
# Deleted proxies 6a-6d: all four `git diff --quiet` checks are vacuous after
# commit and false-fail unrelated later work. lcars-common, xo-run and the
# adapter/ownership pair are outside this resolver's contract; xo.sh's relevant
# attachment filter is asserted directly below.
check "6e. the attach guard in xo.sh still reads [ -f ] before --attach" \
  "grep -q '\[ -f \"\$s\" \] && args+=(--attach \"\$s\")' '$SCRIPT'"
check "6f. no worker CLI was invoked anywhere in this suite" \
  "[ ! -s '$SPEND_LOG' ]"

# ─── 7. THE REAL LIVE LOOK, OPTIONAL ────────────────────────────────────────
# Only the one live look anyone has driven can prove the field numbers. It is
# COPIED first: that evidence is irreplaceable and is never written to.
if [ -n "${LCARS_XO_LIVE_LOOK:-}" ] && [ -d "${LCARS_XO_LIVE_LOOK}/xo" ]; then
  printf '\n── 7. the real live look (a copy of it) ──\n'
  LIVE="$TMPROOT/live"
  cp -R "$LCARS_XO_LIVE_LOOK" "$LIVE" && chmod -R u+w "$LIVE"
  LOUT="$TMPROOT/live-logs"
  "$PY" "$LOGSPY" "$LIVE/xo/verdict.json" "$LIVE/xo/criteria.json" "$LOUT" \
    "$LIVE/xo/shots/look-1" >"$TMPROOT/live-plan.txt" 2>/dev/null
  cat >"$TMPROOT/live-count.py" <<'P'
import os, sys
tot = real = txtpng = withany = gaps = 0
for line in open(sys.argv[1]):
    f = line.rstrip("\n").split("\x1f")
    if f[0] != "GAP":
        continue
    gaps += 1
    hit = 0
    for p in [x for x in f[3].split(",") if x]:
        tot += 1
        if ".txt.png" in p:
            txtpng += 1
        if os.path.isfile(p):
            real += 1
            hit += 1
    if hit:
        withany += 1
print("GAPS=%d PATHS=%d REAL=%d GLUED=%d TICKETS_WITH_EVIDENCE=%d" %
      (gaps, tot, real, txtpng, withany))
P
  LIVEN="$("$PY" "$TMPROOT/live-count.py" "$TMPROOT/live-plan.txt" 2>&1)"
  printf '     %s\n' "$LIVEN"
  check "7a. fixture. the live look really filed its seven tickets" \
    "grep -q 'GAPS=7 ' <<<\"\$LIVEN\""
  check "7b. every shot path the live look emits is a file on disk" \
    "grep -qE 'PATHS=([1-9][0-9]*) REAL=\1 ' <<<\"\$LIVEN\""
  check "7c. not one glued .txt.png survives on the real data" \
    "grep -q 'GLUED=0' <<<\"\$LIVEN\""
  check "7d. four of the seven live tickets now carry attachable evidence \
(one did before; the other three name no shot at all on their gap record)" \
    "grep -q 'TICKETS_WITH_EVIDENCE=4' <<<\"\$LIVEN\""
  check "7e. the live look's own evidence was not written to" \
    "[ -f '${LCARS_XO_LIVE_LOOK}/xo/shots/look-1/01-help.txt' ]"
fi

echo
printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
