#!/usr/bin/env bash
# ===========================================================================
# S196 TESTER — THE WIDENED ID (R4), on two genuinely separate cold clones.
#   1. Same repo, same user, same host, same day → DIFFERENT mission ids.
#   2. The fingerprint is NOT mocked: it comes from a real per-clone uuid4
#      persisted as `cloneId`, and the id carries its first 4 chars.
#   3. THE COMPATIBILITY PROMISE: a LEGACY id (no fingerprint) still resolves,
#      still runs, and still adopts.
# ===========================================================================
. "$(dirname "$0")/../s189/lib.sh"

jparse() { if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then ok "JSON parses: $2"; else bad "INVALID JSON: $2 ($1)"; fi; }

DATE="${S196_DATE:-20260909}"
A="$(laptop A)"; B="$(laptop B)"
# laptop C — a THIRD genuinely cold clone, for the adopt-a-legacy-id leg.
C="$(laptop C)"
reset_laptop "$A"; reset_laptop "$B"; reset_laptop "$C"
lcars_config "$A"; lcars_config "$B"

mkprd() { cat >"$1" <<EOF
# Mission: $2

**Type:** feature
**Goal:** $3
**Acceptance Criteria:**
- it does the thing
**Out of Scope:**
- everything else
**Constraints:**
- No new runtime dependencies
EOF
}

hdr "STEP 1 — two cold clones, same repo/user/host/day, file with the CURRENT product"
mkprd "$WORK/p1.md" "S196 widened id — clone A" "Clone A files something."
mkprd "$WORK/p2.md" "S196 widened id — clone B" "Clone B files something else."
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T11:00:00Z bash "$FILE_SH" --prd "$WORK/p1.md" ) >"$WORK/f1.out" 2>&1
( cd "$B" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T11:05:00Z bash "$FILE_SH" --prd "$WORK/p2.md" ) >"$WORK/f2.out" 2>&1
MA="$(ls "$A/.git/lcars/missions" | head -1)"; MB="$(ls "$B/.git/lcars/missions" | head -1)"
note "A → $MA"; note "B → $MB"
[ -n "$MA" ] && [ -n "$MB" ] || { bad "a clone filed nothing"; sed 's/^/    /' "$WORK/f1.out" "$WORK/f2.out" | head -30; exit 1; }
[ "$MA" != "$MB" ] && ok "DIFFERENT ids from two cold clones on the same day" || bad "STILL COLLIDING: $MA"
case "$MA" in lcars-$DATE-[0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "A's id carries a 4-hex fingerprint" ;; *) bad "A's id is not fingerprinted: $MA" ;; esac
case "$MB" in lcars-$DATE-[0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ok "B's id carries a 4-hex fingerprint" ;; *) bad "B's id is not fingerprinted: $MB" ;; esac

hdr "STEP 2 — the fingerprint is NOT mocked: it comes from a real per-clone id"
CIDA="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cloneId",""))' "$A/.git/lcars/config.json" 2>/dev/null)"
CIDB="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cloneId",""))' "$B/.git/lcars/config.json" 2>/dev/null)"
note "cloneId A = '$CIDA'"; note "cloneId B = '$CIDB'"
case "$CIDA" in [0-9a-f]*) [ "${#CIDA}" = 32 ] && ok "A's cloneId is 32-hex (uuid4)" || bad "A's cloneId is ${#CIDA} chars" ;; *) bad "A has no cloneId" ;; esac
[ -n "$CIDA" ] && [ "$CIDA" != "$CIDB" ] && ok "the two clones hold DIFFERENT cloneIds" || bad "cloneIds equal or missing"
FPA="${MA##*-}"; FPB="${MB##*-}"
[ "$FPA" = "$(printf '%s' "$CIDA" | cut -c1-4)" ] && ok "A's id fingerprint '$FPA' really is cloneId[0:4]" || bad "A's fingerprint '$FPA' != cloneId[0:4] '$(printf '%s' "$CIDA" | cut -c1-4)'"
[ "$FPB" = "$(printf '%s' "$CIDB" | cut -c1-4)" ] && ok "B's id fingerprint '$FPB' really is cloneId[0:4]" || bad "B's fingerprint mismatch"
jparse "$A/.git/lcars/config.json" "A config.json after lazy cloneId backfill"
jparse "$B/.git/lcars/config.json" "B config.json after lazy cloneId backfill"
note "A config: $(tr -d '\n' <"$A/.git/lcars/config.json")"
# The house rule: a NEW key goes at the TOP of the object.
head -2 "$A/.git/lcars/config.json" | grep -q '"cloneId"' && ok "cloneId is the FIRST key (house rule)" || bad "cloneId is not at the top of config.json"
# the branch really is per-clone too
BRA="$(st_get "$A/.git/lcars/missions/$MA/state.json" branch)"; BRB="$(st_get "$B/.git/lcars/missions/$MB/state.json" branch)"
note "branches: $BRA  vs  $BRB"
[ "$BRA" != "$BRB" ] && ok "the SHARED-REMOTE branch names differ too (the real collision)" || bad "branches still collide: $BRA"

hdr "STEP 3 — sequence scan survives a MIXED missions dir (legacy + fingerprinted)"
mkdir -p "$A/.git/lcars/missions/lcars-$DATE-007" "$A/.git/lcars/missions/not-a-mission"
printf '{ "id": "lcars-%s-007" }\n' "$DATE" >"$A/.git/lcars/missions/lcars-$DATE-007/state.json"
mkprd "$WORK/p3.md" "S196 widened id — after a legacy neighbour" "Sequence past a legacy id."
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T11:10:00Z bash "$FILE_SH" --prd "$WORK/p3.md" ) >"$WORK/f3.out" 2>&1
RC3=$?
M3="$(ls "$A/.git/lcars/missions" | grep -v 'not-a-mission' | grep -v -- "-007$" | grep -v -- "^$MA$" | head -1)"
note "3rd mint: '$M3' (rc=$RC3)"
sed 's/^/    /' "$WORK/f3.out" | tail -4
case "$M3" in lcars-$DATE-008-*) ok "sequenced to 008 past the legacy -007 and the junk dir" ;; *) bad "unexpected 3rd id: '$M3'" ;; esac
grep -qi "arithmetic\|10#\|value too great" "$WORK/f3.out" && bad "an arithmetic error leaked into filing" || ok "no arithmetic error on a mixed dir"
rm -rf "$A/.git/lcars/missions/not-a-mission"

hdr "STEP 4 — THE COMPATIBILITY PROMISE: a LEGACY id still resolves and still runs"
# Forge nothing: the pre-S196 product itself minted the -007 above? No — that one
# is a stub. Use clone B, filed by the PRE-S196 product, as the real legacy case.
OLD_FILE_SH="${S196_OLD_SRC:-/tmp/s196/LCARS-old}/skills/lcars-file/file.sh"
reset_laptop "$B"; lcars_config "$B"
mkprd "$WORK/p4.md" "S196 legacy id — filed by the pre-S196 product" "A legacy mission that must keep working."
( cd "$B" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T12:00:00Z bash "$OLD_FILE_SH" --prd "$WORK/p4.md" ) >"$WORK/f4.out" 2>&1
LEG="$(ls "$B/.git/lcars/missions" | head -1)"
note "legacy mission: '$LEG'"
case "$LEG" in lcars-$DATE-[0-9][0-9][0-9]) ok "legacy shape on disk" ;; *) bad "not a legacy id: $LEG" ;; esac
LEG_ISSUE="$(st_raw "$B/.git/lcars/missions/$LEG/state.json" githubIssue)"
note "legacy issue: #$LEG_ISSUE"

( cd "$B" && bash "$STATUS_SH" ) >"$WORK/st4.out" 2>&1
grep -q "$LEG" "$WORK/st4.out" && ok "lcars status LISTS the legacy mission" || { bad "status does not list $LEG"; sed 's/^/      /' "$WORK/st4.out" | head; }
# resolve by PARTIAL id — the captain's everyday selector
( cd "$B" && bash "$RUN_SH" --mission "${LEG#lcars-}" --step ) >"$WORK/run4.out" 2>&1
R4=$?
note "run --mission ${LEG#lcars-} --step rc=$R4"
sed 's/^/    /' "$WORK/run4.out" | head -12
grep -qi "no mission\|could not resolve\|not found\|ambiguous" "$WORK/run4.out" && bad "the legacy id did not RESOLVE" || ok "the legacy id resolves through the partial-id selector"
jparse "$B/.git/lcars/missions/$LEG/state.json" "legacy mission after a run --step"

hdr "STEP 5 — a LEGACY id still ADOPTS, into a genuinely cold third clone"
[ -d "$C/.git/lcars" ] && bad "laptop C is not cold" || ok "laptop C has NO .git/lcars"
( cd "$C" && bash "$ADOPT_SH" "$LEG_ISSUE" ) >"$WORK/adopt-legacy.out" 2>&1
AR=$?
note "adopt rc=$AR"; sed 's/^/    /' "$WORK/adopt-legacy.out" | head -20
[ -f "$C/.git/lcars/missions/$LEG/state.json" ] && ok "legacy mission rebuilt on C under its ORIGINAL id ($LEG)" \
  || { bad "no $LEG on C"; note "C holds: $(ls "$C/.git/lcars/missions" 2>/dev/null | tr '\n' ' ')"; }
jparse "$C/.git/lcars/missions/$LEG/state.json" "adopted legacy mission on C"
CID_C="$(st_get "$C/.git/lcars/missions/$LEG/state.json" id)"
[ "$CID_C" = "$LEG" ] && ok "the id was REUSED, never re-minted" || bad "id changed on adopt: '$CID_C'"

hdr "SPEND"; note "worker spawns: $(spawns)  billable: $(billable)  gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\n' "$PASS" "$FAIL" "$WORK"
printf 'A=%s B_legacy=%s (#%s) C_adopted=%s\n' "$MA" "$LEG" "$LEG_ISSUE" "$LEG"
[ "$FAIL" -eq 0 ]
