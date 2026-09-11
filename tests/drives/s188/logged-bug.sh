#!/usr/bin/env bash
# DRIVE 5 — the logged-bug Mission lane, done properly (--parent / --prd).
. "$(dirname "$0")/lib.sh"
LOG_SH="$LCARS_SRC/skills/lcars-log/log.sh"

R="$(new_repo)"; write_prd "$R/prd-in.md"
( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" ) >/dev/null 2>&1
PM="$R/.git/lcars/missions/lcars-20260907-001"
sed -i '' 's/"stage": "align"/"stage": "implement"/' "$PM/state.json"

cat >"$R/bug.md" <<'EOF'
# Mission: CSV export button double-fires

**Type:** bug
**Goal:** Clicking Export CSV twice quickly must produce one download, not two.
**Acceptance Criteria:**
- A second click while an export is in flight is ignored
**Out of Scope:**
- Any change to the CSV contents
**Constraints:**
- No new runtime dependencies
EOF

hdr "L1 — file the bug child with `lcars log`"
( cd "$R" && LCARS_STUB_ISSUE=43 LCARS_DATE=20260907 bash "$LOG_SH" --parent lcars-20260907-001 --prd "$R/bug.md" ) >"$WORK/log.out" 2>&1
note "rc=$?"; tail -8 "$WORK/log.out" | sed 's/^/    /'
BM="$(ls -d "$R"/.git/lcars/missions/*/ | grep -v 'lcars-20260907-001/' | tail -1)"
BID="$(basename "${BM%/}")"
note "bug mission: $BID"
note "state: $(tr -d '\n' <"$BM/state.json" | sed 's/  */ /g' | cut -c1-500)"
BODYF="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
note "recorded body: $(basename "$BODYF") — argv: $(cat "$BODYF.argv" | sed 's/--body-file [^ ]*/--body-file <f>/')"
echo "    --- the logged-bug issue body AS FILED ---"; sed 's/^/    | /' "$BODYF" | head -8
if grep -q 'lcars:handoff' "$BODYF"; then ok "the logged-bug body carries a handoff envelope"
else bad "NEW-MISSION LANE WITH NO ENVELOPE: \`lcars log\` files a Mission (lcars:mission) whose body has no envelope"; fi

hdr "L2 — that bug child at Verify entry"
sed -i '' 's/"stage": "[a-z-]*"/"stage": "verify"/' "$BM/state.json"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" drive --mission "$BID" ) >"$WORK/l2.out" 2>&1
a=$(body_edits); note "Verify-entry body edits: $((a-b))"
if [ "$a" -gt "$b" ]; then
  p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
  echo "    --- what the refresh REPLACED it with ---"; sed 's/^/    | /' "$p" | head -8
  grep -q 'Logged via' "$p" && ok "the '🐞 Logged via' provenance survived" \
    || bad "the refresh DESTROYED the '> 🐞 Logged via \`lcars log\` against <parent> (#n).' provenance header"
  echo "    envelope: $(tail -1 "$p")"
  grep -q '"parentIssue":null' "$p" && bad "the envelope says parentIssue:null on a bug child that HAS a parent" \
    || ok "the envelope carries the real parentIssue"
else note "no push"; fi

echo "WORK=$WORK"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
