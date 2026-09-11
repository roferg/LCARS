#!/usr/bin/env bash
# DRIVE 8 — an ADVANCING pipeline: does any *successful* stage transition
# (relabel + comment mirror + advance) fire a body edit?
. "$(dirname "$0")/lib.sh"
# a worker that actually produces stage artifacts
cat >"$SHIM/claude" <<WORKER
#!/usr/bin/env bash
_m=no; for a in "\$@"; do case "\$a" in --model|-m|--model=*) _m=yes ;; esac; done
printf 'SPAWN\tclaude\tmodel=%s\trole=%s\n' "\$_m" "\${LCARS_WORKER_ROLE:-?}" >> "$SPEND"
[ "\$_m" = yes ] && printf 'BILLABLE\tclaude\n' >> "$BILLABLE"
case " \$* " in *" --version "*|*" -v "*) echo "0.0.0-s188-fake"; exit 0 ;; esac
out="\${LCARS_WORK_OUT:-}"; [ -n "\$out" ] || exit 0
case "\${LCARS_WORKER_ROLE:-}" in
  research-questions) : >"\$out/questions.txt" ;;   # ZERO questions → clean advance
esac
exit 0
WORKER
chmod +x "$SHIM/claude"; cp "$SHIM/claude" "$SHIM/copilot"

R="$(new_repo)"; write_prd "$R/prd-in.md"
( cd "$R" && LCARS_DATE=20260907 bash "$FILE_SH" --prd "$R/prd-in.md" ) >/dev/null 2>&1
M="$R/.git/lcars/missions/lcars-20260907-001"
printf '## Feedback — 2026-09-07T12:00:00Z (from verify)\n\nfix it\n\n' >"$M/feedback.md"

hdr "S1 — research on a BOUNCED mission (transfer point 1) — must fire exactly 1"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >"$WORK/s1.out" 2>&1
note "rc=$? stage now: $(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$M/state.json"|head -1)"
tail -4 "$WORK/s1.out" | sed 's/^/    /'
a=$(body_edits); [ "$((a-b))" = 1 ] && ok "one body edit at the transfer point" || bad "edits: $((a-b))"
note "gh calls this stage: $(grep -c '^gh' "$GH_LOG")"
grep '^gh issue edit' "$GH_LOG" | sed 's/^/    /'

hdr "S2 — the mission ADVANCES on: subsequent stages fire ZERO body edits"
b=$(body_edits)
for st in validate plan plan-review schedule implement; do
  ( cd "$R" && bash "$RUN_SH" "$st" --mission lcars-20260907-001 ) >"$WORK/s2.$st.out" 2>&1
  note "$st rc=$? → stage=$(sed -n 's/.*"stage"[^"]*"\([^"]*\)".*/\1/p' "$M/state.json"|head -1)"
done
a=$(body_edits); [ "$a" = "$b" ] && ok "ZERO body edits across the advancing mid-flight stages" || bad "$((a-b)) mid-flight body edits"

hdr "S3 — a SECOND research pass on the same bounced mission (feedback.md persists)"
sed -i '' 's/"stage": "[a-z-]*"/"stage": "align"/' "$M/state.json"
b=$(body_edits); ( cd "$R" && bash "$RUN_SH" research --mission lcars-20260907-001 ) >/dev/null 2>&1
a=$(body_edits); [ "$a" = "$b" ] && ok "an unchanged PRD re-push is skipped (no spam on repeat re-entries)" || bad "re-pushed $((a-b))"

hdr "SPEND"; note "worker spawns: $(spawns)  billable(--model): $(billable)"
sort "$SPEND" | uniq -c | sed 's/^/    /'
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
