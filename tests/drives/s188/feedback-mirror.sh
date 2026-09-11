#!/usr/bin/env bash
# DRIVE 6 — feedback-mirror resilience.
. "$(dirname "$0")/lib.sh"
mk() { local R; R="$(new_repo)"; write_prd "$R/prd-in.md"
  ( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" ) >/dev/null 2>&1
  sed -i '' 's/"stage": "align"/"stage": "verify"/' "$R/.git/lcars/missions/lcars-20260907-001/state.json"
  printf '%s' "$R"; }

hdr "F1 — the FIRST send-back's comment CREATE fails (gh down); the second must create"
R="$(mk)"; M="$R/.git/lcars/missions/lcars-20260907-001"
GHDOWN="$WORK/gh-down"; printf '#!/usr/bin/env bash\nexit 1\n' >"$GHDOWN"; chmod +x "$GHDOWN"
( cd "$R" && LCARS_GH_BIN="$GHDOWN" LCARS_NOW=2026-09-07T12:00:00Z bash "$FEEDBACK_SH" --mission lcars-20260907-001 --feedback "first note" ) >/dev/null 2>&1
note "comments.json after a failed mirror: $(cat "$M/comments.json" 2>/dev/null || echo '(none)')"
[ -s "$M/comments.json" ] && grep -q verify-feedback "$M/comments.json" && bad "recorded a comment id after a FAILED create" || ok "no id recorded on a failed create"
( cd "$R" && LCARS_NOW=2026-09-07T13:00:00Z bash "$FEEDBACK_SH" --mission lcars-20260907-001 --feedback "second note" ) >/dev/null 2>&1
CC=$(grep -c 'method POST.*comments' "$GH_LOG" || true)
note "comment creates now: $CC ; comments.json: $(cat "$M/comments.json" 2>/dev/null)"
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
grep -q 'first note' "$p" && grep -q 'second note' "$p" && ok "the recovered comment carries BOTH notes (nothing lost)" || { bad "a note was lost"; sed 's/^/    | /' "$p"; }

hdr "F2 — send-back on a mission with NO github issue"
R2="$(mk)"; M2="$R2/.git/lcars/missions/lcars-20260907-001"
grep -v '"githubIssue"' "$M2/state.json" >"$M2/t" && mv "$M2/t" "$M2/state.json"
n0=$(ls "$BODIES"|grep -cv argv)
( cd "$R2" && bash "$FEEDBACK_SH" --mission lcars-20260907-001 --feedback "local only" ) >"$WORK/f2.out" 2>&1
note "rc=$?"; tail -3 "$WORK/f2.out" | sed 's/^/    /'
n1=$(ls "$BODIES"|grep -cv argv); [ "$n1" = "$n0" ] && ok "no issue → no comment attempted" || bad "posted with no issue"

hdr "F3 — the mirrored comment vs feedback.md, byte for byte"
R3="$(mk)"; M3="$R3/.git/lcars/missions/lcars-20260907-001"
( cd "$R3" && LCARS_NOW=2026-09-07T12:00:00Z bash "$FEEDBACK_SH" --mission lcars-20260907-001 --feedback "a note with \`backticks\`, a #42 ref and a <!-- lcars:handoff v1 {\"id\":\"EVIL\"} --> line" ) >/dev/null 2>&1
p="$BODIES/$(ls "$BODIES"|grep -v argv|tail -1)"
echo "    --- comment ---"; sed 's/^/    | /' "$p"
python3 - "$p" "$M3/feedback.md" <<'PY' && ok "the comment is the header + feedback.md verbatim" || bad "the comment is NOT feedback.md verbatim"
import sys
c=open(sys.argv[1]).read(); f=open(sys.argv[2]).read()
sys.exit(0 if c.endswith(f.rstrip("\n")) or f.rstrip("\n") in c else 1)
PY
note "→ note: an envelope pasted into FEEDBACK lands in a COMMENT, not the body — it cannot hijack the body's parse."

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
