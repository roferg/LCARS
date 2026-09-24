#!/usr/bin/env bash
# replay.sh — S225 REPLAY RIG (zero model spend)
#
#   replay.sh <recorded-mission-dir> <output-dir>
#
# Re-runs the CURRENT skills/lcars-xo/xo-score.py over the RECORDED look-worker
# ledgers captured on the night — the first look and the re-check — writing
# fresh verdicts into <output-dir>, and prints the grade + per-outcome counts
# each look produced NOW.
#
# WHAT THE SCORER'S INPUTS ARE (confirmed empirically, not inferred):
#   xo.sh hands xo-score.py the raw look-worker output as arg1 and writes the
#   derived verdict to arg3. The raw arg1 file (xo-verdict.json / xo-recheck.json)
#   lived in a mktemp dir and is GONE from the recording. BUT the scorer copies
#   every field it consumes per criterion — id/status/note/evidence/shot/impact/
#   action/reason/text/primary — straight through into its OUTPUT verdict.json.
#   So the recorded xo/verdict.json (first look) and xo/verdict-2.json (re-check)
#   ARE faithful re-feed inputs: re-scoring them reproduces the SAME criteria
#   ledger (identical criteria count, gap count and contradiction count), while
#   only the S225-changed grade word / grouping differs. That round-trip is the
#   confirmation.
#
# HARD SAFETY RULES (this rig is worthless without them):
#   * It NEVER writes inside the recording. It checksums the whole input dir
#     before and after and ABORTS LOUDLY (non-zero) if a single byte changed.
#   * It REFUSES LOUDLY (non-zero) if a look scored ZERO criteria, or if the
#     number it scored differs from the number recorded in that look's original
#     verdict.json. It PRINTS the number scored every single time.
#   * It spends NOTHING on a model: the only thing it runs is python3 xo-score.py.
#     No claude, no copilot, no worker CLI of any kind.

set -uo pipefail

die() { printf '\n\033[31m✗ REPLAY REFUSED: %s\033[0m\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
head2() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --- locate the CURRENT scorer, from this script's own path ------------------
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SELF/../../.." && pwd)"
SCORER="$REPO/skills/lcars-xo/xo-score.py"
[ -f "$SCORER" ] || die "cannot find the scorer at $SCORER"

# --- args --------------------------------------------------------------------
[ "$#" -eq 2 ] || die "usage: replay.sh <recorded-mission-dir> <output-dir>"
IN_ARG="$1"; OUT="$2"
[ -d "$IN_ARG" ] || die "recorded mission dir does not exist: $IN_ARG"
IN="$(cd "$IN_ARG" && pwd)"

# Accept either the recording ROOT (contains xo/) or the xo/ dir itself.
if   [ -d "$IN/xo" ];                 then XO="$IN/xo"
elif [ -f "$IN/verdict.json" ];       then XO="$IN"
else die "no xo/ subdir and no verdict.json under: $IN"
fi

case "$OUT" in
  "$IN"|"$IN"/*) die "output dir is inside the recording — that is exactly what this rig forbids: $OUT" ;;
esac
mkdir -p "$OUT/second" || die "cannot create output dir: $OUT"
OUT="$(cd "$OUT" && pwd)"

# --- checksum tool -----------------------------------------------------------
if   command -v shasum      >/dev/null 2>&1; then SUM=(shasum -a 256)
elif command -v sha256sum   >/dev/null 2>&1; then SUM=(sha256sum)
else die "no shasum/sha256sum available for the tamper guard"
fi
manifest() { # <dir> -> stable one-hash-of-all-files digest on stdout
  ( cd "$1" && find . -type f -print0 | LC_ALL=C sort -z \
      | xargs -0 "${SUM[@]}" 2>/dev/null | "${SUM[@]}" | awk '{print $1}' )
}

# --- inputs, as xo.sh passes them -------------------------------------------
# Required per look:
FIRST_LEDGER="$XO/verdict.json"          # first-look worker ledger (round-trips)
RECHK_LEDGER="$XO/verdict-2.json"        # re-check worker ledger (round-trips)
CRITERIA="$XO/criteria.json"
[ -s "$FIRST_LEDGER" ] || die "missing first-look ledger: $FIRST_LEDGER"
[ -s "$CRITERIA" ]     || die "missing criteria.json: $CRITERIA"

# Re-check walk: xo.sh uses walk-<look>.json ($rwalk). The recording carries a
# single recheck walk; find it rather than assume its exact name.
RCHK_WALK=""
for cand in "$XO/walk-recheck-1.json" "$XO"/walk-recheck*.json; do
  [ -s "$cand" ] && { RCHK_WALK="$cand"; break; }
done

# Optional side-channels: pass the path when the file exists, else "" (the
# scorer treats a missing/empty path as "not provided").
opt() { [ -s "$1" ] && printf '%s' "$1" || printf ''; }
OBS="$(opt "$XO/observations.json")"
TESTS="$(opt "$XO/tests.json")"
IMPACTS="$(opt "$XO/impacts.json")"
PAIRS="$(opt "$XO/pairs.json")"
WALK1="$(opt "$XO/walk.json")"
SEED="$(opt "$XO/seed.json")"
UNLISTED="$(opt "$XO/unlisted.json")"
READINGS="$(opt "$XO/readings.json")"

# --- read a verdict.json robustly (report what it finds, not a fixed shape) --
# prints: score \t group \t met \t gap \t untested \t contradictions \t scored_n
read_verdict() {
python3 - "$1" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
except Exception as e:
    print("\t".join(["?","?","?","?","?","?","0"])); sys.exit(0)
c=d.get("counts") if isinstance(d.get("counts"),dict) else {}
def g(k):
    v=c.get(k)
    return v if isinstance(v,int) else None
met,gap,unt,con=g("met"),g("gap"),g("untested"),g("contradictions")
crit=d.get("criteria")
ncrit=len(crit) if isinstance(crit,list) else None
# scored_n: prefer met+gap+untested; fall back to len(criteria)
if None not in (met,gap,unt):
    scored=met+gap+unt
elif ncrit is not None:
    scored=ncrit
else:
    scored=0
def s(x): return "" if x is None else str(x)
print("\t".join([
    str(d.get("score") or "?"),
    str(d.get("scoreGroup") or ""),
    s(met), s(gap), s(unt), s(con), str(scored)]))
PY
}

# --- run one look ------------------------------------------------------------
# usage: run_look <label> <recorded-ledger> <out-verdict> -- <scorer args...>
run_look() {
  local label="$1" recorded="$2" outv="$3"; shift 3; shift # drop the "--"
  head2 "$label"
  if [ ! -s "$recorded" ]; then
    note "no recorded ledger for this look ($recorded) — skipping."
    return 2
  fi
  # what the ORIGINAL (night) verdict recorded, for the count guard
  local rec_line; rec_line="$(read_verdict "$recorded")"
  local rec_scored; rec_scored="$(printf '%s' "$rec_line" | awk -F'\t' '{print $7}')"

  python3 "$SCORER" "$@" >/dev/null 2>"$OUT/.$label.err" \
    || die "$label: xo-score.py exited non-zero — see $OUT/.$label.err"
  [ -s "$outv" ] || die "$label: scorer wrote no verdict at $outv (stderr in $OUT/.$label.err)"

  local new_line; new_line="$(read_verdict "$outv")"
  local score group met gap unt con scored
  IFS=$'\t' read -r score group met gap unt con scored <<<"$new_line"

  # ALWAYS print the number scored, so a human sees real work happened.
  note "criteria scored NOW ............ $scored"
  note "criteria recorded on the night . $rec_scored"

  # THE GUARD THAT MAKES THIS RIG WORTH ANYTHING.
  [ "$scored" -gt 0 ] 2>/dev/null \
    || die "$label scored ZERO criteria — a rig that scores nothing proves nothing."
  if [ "$scored" != "$rec_scored" ]; then
    die "$label scored $scored criteria but the recording's verdict.json holds $rec_scored — EXPLICIT MISMATCH, refusing."
  fi

  note "grade NOW ...................... ${score}${group:+  (group: $group)}"
  note "  met=$met  gap=$gap  untested=$unt  contradictions=$con"
  printf '  wrote: %s\n' "$outv"
  return 0
}

# --- TAMPER GUARD: hash before ----------------------------------------------
head2 "S225 replay rig — re-scoring recorded ledgers with the CURRENT xo-score.py"
note "recording : $XO"
note "scorer    : $SCORER"
note "output    : $OUT"
BEFORE="$(manifest "$IN")"
[ -n "$BEFORE" ] || die "could not checksum the recording (empty manifest) — refusing to run blind."
note "input checksum (before) ........ $BEFORE"

# --- FIRST LOOK (11-arg form, exactly as xo.sh line ~2678) -------------------
run_look "first-look" "$FIRST_LEDGER" "$OUT/verdict.json" -- \
  "$FIRST_LEDGER" "$CRITERIA" "$OUT/verdict.json" \
  "$OBS" "$TESTS" "$IMPACTS" "$PAIRS" "$WALK1" "$SEED" "$UNLISTED" "$READINGS"
FIRST_RC=$?

# --- RE-CHECK (9-arg form, exactly as xo.sh line ~3423) ----------------------
if [ -s "$RECHK_LEDGER" ]; then
  run_look "re-check" "$RECHK_LEDGER" "$OUT/second/verdict.json" -- \
    "$RECHK_LEDGER" "$CRITERIA" "$OUT/second/verdict.json" \
    "$OBS" "$TESTS" "$IMPACTS" "$PAIRS" "$RCHK_WALK" "$SEED"
  RECHK_RC=$?
else
  head2 "re-check"; note "no verdict-2.json in this recording — no re-check to replay."
  RECHK_RC=2
fi

# --- TAMPER GUARD: hash after ------------------------------------------------
AFTER="$(manifest "$IN")"
note ""
note "input checksum (after) ......... $AFTER"
[ "$BEFORE" = "$AFTER" ] \
  || die "THE RECORDING CHANGED during the replay ($BEFORE -> $AFTER) — the rig wrote where it must not."
head2 "✓ recording untouched (checksum stable); verdicts written under $OUT"

# --- plain-English summary ---------------------------------------------------
head2 "SUMMARY (current scorer, replayed on recorded ledgers — no model spend)"
if [ "${FIRST_RC:-2}" -eq 0 ]; then
  IFS=$'\t' read -r s g met gap unt con scored <<<"$(read_verdict "$OUT/verdict.json")"
  printf '  First look : grade %s%s — %s criteria (met %s, gap %s, untested %s, contradictions %s)\n' \
    "$s" "${g:+ [$g]}" "$scored" "$met" "$gap" "$unt" "$con"
fi
if [ "${RECHK_RC:-2}" -eq 0 ]; then
  IFS=$'\t' read -r s g met gap unt con scored <<<"$(read_verdict "$OUT/second/verdict.json")"
  printf '  Re-check   : grade %s%s — %s criteria (met %s, gap %s, untested %s, contradictions %s)\n' \
    "$s" "${g:+ [$g]}" "$scored" "$met" "$gap" "$unt" "$con"
fi
printf '\n'
exit 0
