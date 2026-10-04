#!/usr/bin/env bash
#
# Tests for ATTACHMENT WIDENING and the filedAs WRITE-BACK
# (S240 fix round 4, D5 and D4).
#
# D5 — WHAT ACTUALLY HAPPENED, MEASURED on a seven-gap case BEFORE anything was
# changed, counting only attachments whose file is on disk (which is `xo.sh`'s
# own `[ -f "$s" ]` rule):
#
#   gap 1  gaps[].shots (plural)            attach=shot-01.png
#   gap 2  gaps[].shots, two                attach=shot-02.png,shot-03.png
#   gap 3  gaps[].shot (SINGULAR)           attach=(NONE)
#   gap 4  only criteria[].shot on the ROW  attach=(NONE)
#   gap 5  evidencePath                     attach=(NONE)
#   gap 6  a transcript name                attach=(NONE)
#   gap 7  nothing recorded at all          attach=(NONE)
#   -> 2 of 7 arrived with an attachment.
#
# Note what that corrects: it is NOT true that the attachment code reads only
# `gaps[].shots` everywhere — `instrument_of` and `evidence_ref` already read
# `gaps[].shot` and the ledger row's `shot` for the PROSE. It is the ATTACH
# LIST that read one field. Hence "widening", which the captain approved on
# 2026-10-03 having been told plainly that it widens what attaches rather than
# correcting a wrong path: a bug he cannot see is not actionable, and a
# less-relevant screenshot beats none.
#
# D4 — `blockers[].filedAs` was promised by two comments in `xo-score.py` and
# written by nothing, so a SEND-BACK named no bug id and no command. The FILER
# records it (the infer-vs-record rule: the producer writes the fact down, no
# surface parses it back out of finished prose).
#
# Usage: bash tests/xo-attach-widening.test.sh

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XOLOGS="$REPO_ROOT/skills/lcars-xo/xo-logs.py"
XOFILED="$REPO_ROOT/skills/lcars-xo/xo-filed.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0; fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

echo "Number One: attachment widening + filedAs write-back"
[ -f "$XOLOGS" ] || { echo "script under test not found at $XOLOGS"; exit 1; }

# --- the seven-gap case ---------------------------------------------------
# Seven real files on disk, named the way a live look names them (a bare
# `shot-NN` and a transcript that already carries its extension).
T="$TMPROOT/case"; S="$T/shots"; mkdir -p "$S" "$T/out"
for f in shot-01 shot-02 shot-03 shot-04 shot-05 shot-06 shot-07; do
  printf 'png\n' >"$S/$f.png"
  printf '{"url":"http://x"}\n' >"$S/$f.json"
done
printf 'transcript\n' >"$S/01-help.txt"

# EVERY GAP KEYED BY `criterion`, NOT `id`. xo-logs.py builds its gap index off
# `g["criterion"]`; a fixture keyed on `id` makes every gap read as {} and all
# seven come back attachment-less for the WRONG reason — which is exactly how
# the first run of this probe reported 0 of 7 and proved nothing.
"$PY" - "$T" <<'PYFX'
import json, os, sys
T = sys.argv[1]
gaps = [
  {"criterion":"c1","title":"g1","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"picture","shots":["shot-01"]},
  {"criterion":"c2","title":"g2","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"picture","shots":["shot-02","shot-03"]},
  {"criterion":"c3","title":"g3","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"picture","shot":"shot-04"},
  {"criterion":"c4","title":"g4","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"picture"},
  {"criterion":"c5","title":"g5","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"picture","evidencePath":os.path.join(T,"shots","shot-06.png")},
  {"criterion":"c6","title":"g6","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"transcript","transcript":"01-help.txt"},
  {"criterion":"c7","title":"g7","expected":"a","saw":"b","kind":"contradiction",
   "evidence":"picture"},
]
ledger = [
  {"id":"c1","status":"gap","impact":"high","evidence":"picture","shot":"shot-01"},
  {"id":"c2","status":"gap","impact":"high","evidence":"picture"},
  {"id":"c3","status":"gap","impact":"high","evidence":"picture"},
  {"id":"c4","status":"gap","impact":"high","evidence":"picture","shot":"shot-05"},
  {"id":"c5","status":"gap","impact":"high","evidence":"picture"},
  {"id":"c6","status":"gap","impact":"high","evidence":"transcript"},
  {"id":"c7","status":"gap","impact":"high","evidence":"picture"},
]
json.dump({"score":"low","recommendation":"send-back","gaps":gaps,"criteria":ledger,
           "blockers":[{"id":g["criterion"],"evidence":"picture"} for g in gaps],
           "summary":"s"},
          open(os.path.join(T,"verdict.json"),"w"), indent=2)
json.dump({"criteria":[{"id":g["criterion"],"text":"criterion %s" % g["criterion"],
                        "source":"prd"} for g in gaps]},
          open(os.path.join(T,"criteria.json"),"w"))
PYFX

OUT="$("$PY" "$XOLOGS" "$T/verdict.json" "$T/criteria.json" "$T/out" "$S" 10 2>&1)"

# The counter that matters: how many filed gaps arrive with an attachment that
# is really on disk. Written as its own helper so the number is read the same
# way `xo.sh` reads it.
count_with_attachment() {
  printf '%s\n' "$OUT" | "$PY" -c '
import os, sys
RS = "\x1f"
n = withattach = dupes = 0
for line in sys.stdin.read().split("\n"):
    if not line.startswith("GAP"):
        continue
    f = line.split(RS)
    n += 1
    # FIELD 7 IS THE ATTACH LIST. Field 4 stayed the citation the look made
    # itself (what xo/logs.json records and xo recheck re-takes), because a
    # fallback attachment must not rewrite the evidence a gap recorded.
    # NO APOSTROPHES IN HERE: this program is single-quoted in the shell, and
    # one contraction closes the quote 40 lines early.
    csv = f[6] if len(f) > 6 else ""
    real = [p for p in csv.split(",") if p and os.path.isfile(p)]
    if real:
        withattach += 1
    if len(real) != len(set(real)):
        dupes += 1
print("%d %d %d" % (n, withattach, dupes))
'
}
read -r NGAP NATTACH NDUPE <<<"$(count_with_attachment)"

check "1. all seven gaps were filed (else the count below means nothing)" \
  "[ '$NGAP' -eq 7 ]"
check "1. 7 of 7 filed gaps arrive WITH an attachment (saw $NATTACH of $NGAP)" \
  "[ '$NATTACH' -eq 7 ]"
check "1. no ticket carries the SAME file twice (name vs name.png are one file)" \
  "[ '$NDUPE' -eq 0 ]"

# The specific recorded shapes that used to attach nothing, each named, so a
# regression says WHICH shape broke rather than just lowering a count.
has_attach() { # <gap-n> <basename>
  printf '%s\n' "$OUT" | "$PY" -c '
import os, sys
RS = "\x1f"
want_n, want = sys.argv[1], sys.argv[2]
for line in sys.stdin.read().split("\n"):
    if not line.startswith("GAP"):
        continue
    f = line.split(RS)
    if len(f) > 6 and f[1] == want_n:
        for p in f[6].split(","):
            if p and os.path.isfile(p) and os.path.basename(p) == want:
                raise SystemExit(0)
raise SystemExit(1)
' "$1" "$2"
}
check "2. gaps[].shots (plural) still attaches — nothing that worked was traded" \
  "has_attach 1 shot-01.png"
check "2. ...and a two-shot gap still carries both" \
  "has_attach 2 shot-02.png && has_attach 2 shot-03.png"
check "2. gaps[].shot (SINGULAR) now attaches" "has_attach 3 shot-04.png"
check "2. criteria[].shot on the LEDGER ROW now attaches" "has_attach 4 shot-05.png"
check "2. an evidencePath now attaches" "has_attach 5 shot-06.png"
check "2. a transcript name now attaches (its own .txt, not a .png phantom)" \
  "has_attach 6 01-help.txt"
check "2. a gap with NOTHING recorded still arrives with the look's lead picture" \
  "has_attach 7 shot-01.png"

# A gap with no screen behind it at all must NOT gain a picture AND must keep
# its "do not make one" instruction — the widening changes what is ATTACHED,
# never what is CLAIMED.
# THE RECORD IS NOT THE ATTACHMENT. A gap that cited no shot must still
# record none: `xo/logs.json` reads field 4 as this gap's `shots`, and that is
# what `xo recheck` re-takes. The first cut of this widening wrote the wider
# list into field 4 and turned a shotless gap's `"shots": []` into
# `["shot-01"]` — a fallback picture rewriting the gap's own evidence, which
# tests/lcars-xo.test.sh B12a2 caught.
record_csv() { # <gap-n>
  printf '%s\n' "$OUT" | "$PY" -c '
import sys
RS = "\x1f"
want = sys.argv[1]
for line in sys.stdin.read().split("\n"):
    if line.startswith("GAP"):
        f = line.split(RS)
        if len(f) > 3 and f[1] == want:
            print(f[3])
            break
' "$1"
}
check "3. a gap that cited NO shot still RECORDS none (recheck must not re-take a fallback)" \
  "[ -z \"\$(record_csv 7)\" ]"
check "3. ...while that same gap still ATTACHES the lead picture" \
  "has_attach 7 shot-01.png"
check "3. a gap that DID cite a shot still records exactly that one" \
  "record_csv 1 | grep -q 'shot-01.png'"
check "3. a no-screen gap's PRD still admits what was not retained" \
  "grep -Eqi 'not retained|was not kept|no picture|did not keep' '$T/out/7.md'"
check "3. a no-screen gap is never told a screen exists" \
  "! grep -q 'Each PNG has a' '$T/out/7.md'"

# --- D4: the filedAs write-back -------------------------------------------
[ -f "$XOFILED" ] || { echo "  (xo-filed.py absent — D4 checks will fail)"; }
SB="$("$PY" "$XOFILED" "$T/verdict.json" "lcars-20261002-001" \
        "c1=lcars-20261002-010" "c2=lcars-20261002-011" 2>&1)" || SB="ERROR"
check "4. the filer stamps blockers[].filedAs for the bug it filed" \
  "'$PY' -c 'import json,sys; d=json.load(open(sys.argv[1])); b={r[\"id\"]:r.get(\"filedAs\") for r in d[\"blockers\"]}; sys.exit(0 if b.get(\"c1\")==\"lcars-20261002-010\" and b.get(\"c2\")==\"lcars-20261002-011\" else 1)' '$T/verdict.json'"
check "4. ...and leaves an unfiled blocker's filedAs absent, never guessed" \
  "'$PY' -c 'import json,sys; d=json.load(open(sys.argv[1])); r=[x for x in d[\"blockers\"] if x[\"id\"]==\"c7\"][0]; sys.exit(0 if \"filedAs\" not in r else 1)' '$T/verdict.json'"
check "4. the send-back text NAMES each filed bug id" \
  "printf '%s' \"\$SB\" | grep -q 'lcars-20261002-010' && printf '%s' \"\$SB\" | grep -q 'lcars-20261002-011'"
check "4. ...and names the exact resolve command to run" \
  "printf '%s' \"\$SB\" | grep -q 'lcars resolve-logs lcars-20261002-001'"
check "4. ...and says SEND-BACK, so it is readable as the decision it is" \
  "printf '%s' \"\$SB\" | grep -q 'SEND-BACK'"
check "4. the verdict stays valid JSON after the stamp" \
  "'$PY' -c 'import json,sys; json.load(open(sys.argv[1]))' '$T/verdict.json'"

# CONTROL: a verdict that is NOT a send-back prints nothing, so a caller can
# print this unconditionally without inventing a decision.
T2="$TMPROOT/merge"; mkdir -p "$T2"
"$PY" -c 'import json,sys; json.dump({"score":"high","recommendation":"merge","blockers":[{"id":"c1"}]}, open(sys.argv[1],"w"))' "$T2/verdict.json"
SB2="$("$PY" "$XOFILED" "$T2/verdict.json" "lcars-x" "c1=lcars-y" 2>&1)" || SB2="ERROR"
check "4. CONTROL — a merge recommendation prints NO send-back sentence" \
  "[ -z \"\$SB2\" ]"
check "4. CONTROL — ...but the fact is still recorded on the row" \
  "'$PY' -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"blockers\"][0].get(\"filedAs\")==\"lcars-y\" else 1)' '$T2/verdict.json'"

echo
printf 'Number One attachments + filedAs: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
