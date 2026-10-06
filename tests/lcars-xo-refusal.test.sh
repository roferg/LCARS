#!/usr/bin/env bash
#
# S240 FIX ROUND 2 — THE REFUSAL THAT SAID NOTHING, THE CITATION THAT NEVER
# FIRED, AND "A PICTURE" PRINTED OVER A TERMINAL LOG.
#
# A fresh tester drove the FIRST live Copilot look of this session. The look
# itself was sound — 15 stamped rows, `score: low`, `send-back`, three blockers,
# all four findings true faults. But FILING WAS 0 FOR 7, which is the one thing
# the feature exists to do, and the escalation that reported it read:
#
#   ◈ NUMBER ONE: escalated — this one is yours.
#     Number One had 7 gaps to file but `lcars log` refused them —
#
# ending on a dash with nothing after it, with `"detail": ""` in the journal.
#
#  D-A (BLOCKER) — THE REFUSAL DID NOT SAY WHY. `xo.sh` carried
#     `printf '%s' "$lout" | head -1` — the FIRST line of the combined output —
#     into both the sentence and the journal. `log.sh` swallows its per-bug
#     stdout inside its own `$(file_one_bug …)` command substitution and says why
#     on STDERR, so a run that stops mid-batch can leave the first line EMPTY.
#     Cured by `xo_log_refusal_why`, which prefers the LAST `lcars log: ` line
#     (the one that stops the batch and says how many were filed before it), then
#     the first error-looking line, then the last non-empty line — and when there
#     is no output at all says SO, with the status, and names a status above 128
#     as a KILL rather than a refusal.
#
#     WHAT `log.sh` ACTUALLY REFUSED, measured against the live look's own seven
#     generated PRDs with the rig's stubbed `gh`: NOTHING. It filed all 7 and
#     exited 0, twice (with and without the parent's engine threaded as
#     $LCARS_WORKER_BIN). The live non-zero carried no output at all, which is
#     the signature of a kill, not of a validation refusal — and that is exactly
#     the distinction the old dangling dash could not make. Pinned in section 1.
#
#  D-B (HIGH) — THE EVIDENCE CITATION ALMOST NEVER FIRED IN THE FIELD.
#     `evidence_ref` probed `<shotsdir>/<name> + ".png"/".txt"/…`, but a live
#     worker's shot name ALREADY carries its extension (`01-help.txt`), so it
#     looked for `01-help.txt.png`, found nothing, and returned "". MEASURED:
#     6 of the 7 live PRDs said "the evidence was not retained" while
#     `01-help.txt`, `02-workflow-run.txt` and `08-publish.txt` sat in
#     `shots/look-1/`. The name is now tried EXACTLY AS GIVEN first, and the
#     extension probe stays for a bare name.
#
#  D-C (MEDIUM) — "A PICTURE" PRINTED OVER A TERMINAL TRANSCRIPT. A gap record
#     that declared no evidence word was stamped `picture` whenever it cited any
#     shot, so a gap whose only evidence was `02-workflow-run.txt` read
#     `evidence: picture` in the gap AND in the blocker built from it — while the
#     ledger row for the same criterion correctly read `transcript`. The word is
#     now taken from that row first, and the structural fallback reads the whole
#     filename, so a genuine screenshot still reads `picture`.
#
# ZERO SPEND. No worker CLI, no browser, no network. A PATH shim stubs `claude`
# AND `copilot` and is PROVEN to fire before "no spend" is claimed.
#
# Usage: bash tests/lcars-xo-refusal.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/lcars-xo/xo.sh"
SCOREPY="$REPO_ROOT/skills/lcars-xo/xo-score.py"
LOGSPY="$REPO_ROOT/skills/lcars-xo/xo-logs.py"
PY="${LCARS_PYTHON_BIN:-python3}"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }
says() { grep -q "$2" <<<"$1"; }

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

echo
echo "=== lcars xo: the refusal that said nothing, the citation, and the word ==="
echo
printf '── 0. the shim is proven to fire ──\n'
SHIM_RC=0; copilot --probe >/dev/null 2>&1 || SHIM_RC=$?
check "0a. the copilot shim intercepts (so a later silent log means no spend)" \
  "[ '$SHIM_RC' = 97 ] && grep -q '^copilot --probe' '$SPEND_LOG'"
: >"$SPEND_LOG"

# ─── A REPO, A CONFIG, A PLANTED LOOK ────────────────────────────────────────
new_repo() { # <name> <numberOne-literal>
  local repo="$TMPROOT/$1" blk="$2"
  rm -rf "$repo"; mkdir -p "$repo"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  "$PY" - "$repo/.git/lcars/config.json" "$blk" <<'P'
import json, sys
path, blk = sys.argv[1], sys.argv[2]
cfg = {"cloneId": "aaaaaaaa", "projectName": "repo", "contextFile": None,
       "stack": None, "testCommand": "true", "worktreeSetupCommand": None,
       "comprehensionBudget": 1200, "created": "2026-05-30T00:00:00Z"}
cfg["numberOne"] = json.loads(blk)
cfg["zzLast"] = "after the block"
open(path, "w").write(json.dumps(cfg, indent=2) + "\n")
P
  printf '%s' "$repo"
}

# ─── THE CONTRACT ────────────────────────────────────────────────────────────
# prd-3 is a WORKS question whose only proof is a CLI transcript (the S240
# exemplar); prd-4 is a LOOKS question a browser settled on a real screenshot.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "notes add stores the title it was given", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "notes list shows every stored note", "source": "prd", "primary": true},
  {"id": "prd-3", "text": "the published page shows the host the CLI stored", "source": "prd", "primary": true, "notVisual": true},
  {"id": "prd-4", "text": "the board header reads Request Relay", "source": "prd", "primary": true},
  {"id": "prd-5", "text": "the workflow publishes on a push to main", "source": "prd", "primary": true}
 ]}
C

shot_met() { # <id> <impact>
  printf '{"id": "%s", "impact": "%s", "impactWhy": "it is why %s exists", "status": "met", "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks", "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."}' "$1" "$2" "$1"
}

# THE PLANTED LEDGER, SHAPED LIKE THE LIVE ONE.
#  * prd-3 — a GAP. Ledger row declares `evidence: transcript`, `checkedBy: cli`
#    and a shot name that ALREADY CARRIES ITS EXTENSION (`02-workflow-run.txt`),
#    exactly as the live worker wrote it. Its gap record declares NO evidence
#    word — which is the D-C hole.
#  * prd-4 — a GAP a browser settled on a real `.png`. ITS gap record also
#    declares no word. This is the positive control: it must still read
#    `picture`, and it fires in the same run as the transcript case.
{
  printf '{"score": "medium", "summary": "The host does not survive the hop.", "criteria": ['
  printf '%s,' "$(shot_met prd-1 high)" "$(shot_met prd-2 high)"
  printf '{"id": "prd-3", "impact": "high", "impactWhy": "it is the point of the mission", "status": "gap", "kind": "works", "shot": "02-workflow-run.txt", "evidence": "transcript", "checkedBy": "workflow", "note": "ran it and it did not do that", "sawInstead": "it printed github.com, the hardcoded one", "reason": "Outcome: gap."},'
  printf '{"id": "prd-4", "impact": "high", "impactWhy": "it is the first thing anyone reads", "status": "gap", "kind": "looks", "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "note": "the header says Relay Requests", "sawInstead": "a header reading Relay Requests", "action": "opened the board", "reason": "Outcome: gap."},'
  printf '%s' "$(shot_met prd-5 medium)"
  printf '], "gaps": ['
  printf '{"criterion": "prd-3", "kind": "contradiction", "title": "the published page shows github.com, never the host the CLI stored", "expected": "the host recorded by notes add", "shots": ["02-workflow-run.txt"], "seam": "notes.py cmd_publish (writes host) -> page.py render_host (reads origin)", "impact": "high"},'
  printf '{"criterion": "prd-4", "kind": "contradiction", "title": "the board header reads Relay Requests", "expected": "a header reading Request Relay", "shots": ["shot-01"], "impact": "high"}'
  printf ']}\n'
} >"$TMPROOT/worker.json"

"$PY" "$SCOREPY" "$TMPROOT/worker.json" "$TMPROOT/criteria.json" \
  "$TMPROOT/verdict.json" >"$TMPROOT/score.out" 2>"$TMPROOT/score.err"
check "0b. the planted ledger scored at all (fixture proof)" \
  "[ -s '$TMPROOT/verdict.json' ]"

ev_of() { # <verdict> <gaps|blockers> <criterion>
  "$PY" - "$1" "$2" "$3" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for row in d.get(sys.argv[2]) or []:
    if str(row.get("criterion") or "") == sys.argv[3]:
        print(str(row.get("evidence") or ""))
        break
P
}

# ===========================================================================
printf '\n── 1. D-A. when `lcars log` does not finish, the captain is told WHY ──\n'
# ===========================================================================
# Driven through the real `file-logs` verb. Four `lcars log` stubs, each failing
# the way a real one can: chatty-then-dies (the batch-stop die), silent non-zero
# (what the live look actually got), killed by a signal, and the control that
# succeeds.

HOST_STUB="$TMPROOT/host-adapter.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOST_STUB"; chmod +x "$HOST_STUB"
RESOLVE_STUB="$TMPROOT/resolve-logs.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RESOLVE_STUB"; chmod +x "$RESOLVE_STUB"

# CHATTY THEN DIES — the real shape. `log.sh` prints its progress and then dies
# on stderr with `lcars log: … (N filed before it)`; its FIRST line is a blank
# one, which is precisely what `head -1` used to hand the captain.
cat >"$TMPROOT/log-chatty.sh" <<'LGS'
#!/usr/bin/env bash
echo ""
echo "  staging attachments"
echo "lcars log: could not file the bug PRD /x/2.md — see the error above. No bug mission was filed for it, and this batch stops here (1 filed before it)." >&2
exit 1
LGS
chmod +x "$TMPROOT/log-chatty.sh"

# SILENT NON-ZERO — what the first live look got. No stdout, no stderr, rc 1.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMPROOT/log-silent.sh"
chmod +x "$TMPROOT/log-silent.sh"

# KILLED — rc 143 and nothing said.
printf '#!/usr/bin/env bash\nexit 143\n' >"$TMPROOT/log-killed.sh"
chmod +x "$TMPROOT/log-killed.sh"

# THE CONTROL — files, prints its rows the way `log.sh` does, exits 0.
cat >"$TMPROOT/log-ok.sh" <<'LGS'
#!/usr/bin/env bash
parent=""; n=0; args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --parent) parent="${args[$((i+1))]}"; i=$((i+2)) ;;
    --prd)    n=$((n+1)); i=$((i+2)) ;;
    *)        i=$((i+1)) ;;
  esac
done
md="$PWD/.git/lcars/missions"
j=1
while [ "$j" -le "$n" ]; do
  kid="lcars-20261002-90$j-bbbb"
  mkdir -p "$md/$kid"
  printf '{"id": "%s", "stage": "plan", "parent": "%s"}\n' "$kid" "$parent" >"$md/$kid/state.json"
  printf '  %s  #%d  a filed bug\n' "$kid" "$((500 + j))"
  j=$((j + 1))
done
exit 0
LGS
chmod +x "$TMPROOT/log-ok.sh"

plant_mission() { # <repo> <id>
  local repo="$1" id="$2" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m/xo/shots"
  cat >"$m/state.json" <<SJ
{
  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-10-02T10:00:00Z"},
  "id": "$id",
  "type": "feature",
  "title": "The notes CLI",
  "stage": "verify",
  "prUrl": "https://github.com/x/y/pull/7",
  "created": "2026-10-02T10:00:00Z",
  "githubIssue": 42
}
SJ
  cp "$TMPROOT/criteria.json" "$m/xo/criteria.json"
  cp "$TMPROOT/verdict.json"  "$m/xo/verdict.json"
  printf '$ notes publish\nwrote page.html with origin=github.com\n' >"$m/xo/shots/02-workflow-run.txt"
  printf 'PNG-ish bytes\n' >"$m/xo/shots/shot-01.png"
  printf '%s' "$m"
}

drive_file_logs() { # <repo> <id> <log-stub>
  ( cd "$1" && LCARS_LOG_SCRIPT="$3" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_RUN_SCRIPT=/usr/bin/true LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      bash "$SCRIPT" file-logs --mission "$2" 2>&1 )
}

CFG_ON='{"enabled": true, "engine": "copilot", "filesBugs": true}'

# --- chatty then dies --------------------------------------------------------
R_CHATTY="$(new_repo refusal-chatty "$CFG_ON")"
M_CHATTY="$(plant_mission "$R_CHATTY" lcars-20261002-001)"
OUT_CHATTY="$(drive_file_logs "$R_CHATTY" lcars-20261002-001 "$TMPROOT/log-chatty.sh")"
J_CHATTY="$(grep '"action": "escalated"' "$M_CHATTY/number-one.jsonl" 2>/dev/null | tail -1)"

check "1a. fixture. the chatty stub's FIRST line really is blank (the old \`head -1\`)" \
  "[ -z \"\$(bash '$TMPROOT/log-chatty.sh' 2>&1 | head -1)\" ]"
check "1b. it escalated at all" \
  "says \"\$OUT_CHATTY\" 'escalated'"
check "1c. D-A. the message names the reason \`log.sh\` gave" \
  "says \"\$OUT_CHATTY\" 'this batch stops here'"
check "1d. D-A. …and carries how many were filed before it stopped" \
  "says \"\$OUT_CHATTY\" '1 filed before it'"
check "1e. D-A. the journal \`detail\` is not empty" \
  "[ -n \"\$J_CHATTY\" ] && ! says \"\$J_CHATTY\" '\"detail\": \"\"'"
check "1f. D-A. the journal \`detail\` names the same reason" \
  "says \"\$J_CHATTY\" 'this batch stops here'"
check "1g. D-A. the journal records the exit status too" \
  "says \"\$J_CHATTY\" '\"exit\": 1'"

# NO DANGLING DASH, ANYWHERE. Every line of what the captain is shown, and the
# stored note, checked for a trailing em-dash or hyphen.
no_dangling_dash() { # <text>
  ! printf '%s\n' "$1" | grep -qE '(—|-)[[:space:]]*$'
}
check "1h. D-A. no line the captain is shown ends on a dangling dash" \
  "no_dangling_dash \"\$OUT_CHATTY\""
NOTE_CHATTY="$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["numberOne"].get("note") or "")' "$M_CHATTY/state.json" 2>/dev/null)"
check "1i. D-A. the stored note does not end on a dangling dash either" \
  "no_dangling_dash \"\$NOTE_CHATTY\""
check "1j. D-A. the stored note names the reason, not just the fact" \
  "says \"\$NOTE_CHATTY\" 'this batch stops here'"

# --- silent non-zero: WHAT THE LIVE LOOK ACTUALLY GOT ------------------------
R_SILENT="$(new_repo refusal-silent "$CFG_ON")"
M_SILENT="$(plant_mission "$R_SILENT" lcars-20261002-002)"
OUT_SILENT="$(drive_file_logs "$R_SILENT" lcars-20261002-002 "$TMPROOT/log-silent.sh")"
J_SILENT="$(grep '"action": "escalated"' "$M_SILENT/number-one.jsonl" 2>/dev/null | tail -1)"
check "1k. D-A. a SILENT non-zero still says something (the live case)" \
  "says \"\$OUT_SILENT\" 'printed nothing'"
check "1l. D-A. …and gives the exit status, so it can be told from a refusal" \
  "says \"\$OUT_SILENT\" 'status 1'"
check "1m. D-A. the journal detail for the silent case is not empty" \
  "[ -n \"\$J_SILENT\" ] && ! says \"\$J_SILENT\" '\"detail\": \"\"'"
check "1n. D-A. the silent case shows no dangling dash" \
  "no_dangling_dash \"\$OUT_SILENT\""

# --- killed ------------------------------------------------------------------
R_KILL="$(new_repo refusal-killed "$CFG_ON")"
M_KILL="$(plant_mission "$R_KILL" lcars-20261002-003)"
OUT_KILL="$(drive_file_logs "$R_KILL" lcars-20261002-003 "$TMPROOT/log-killed.sh")"
check "1o. D-A. a status above 128 is reported as a KILL, not a refusal" \
  "says \"\$OUT_KILL\" 'KILLED by signal 15'"
check "1p. D-A. …and warns that bugs may already be filed (a re-run doubles them)" \
  "says \"\$OUT_KILL\" 'may already be filed'"

# --- THE POSITIVE CONTROL: a successful filing is UNCHANGED ------------------
R_OK="$(new_repo refusal-ok "$CFG_ON")"
M_OK="$(plant_mission "$R_OK" lcars-20261002-004)"
OUT_OK="$(drive_file_logs "$R_OK" lcars-20261002-004 "$TMPROOT/log-ok.sh")"
check "1q. CONTROL. a successful filing still reports what it filed" \
  "says \"\$OUT_OK\" 'filed 2 mission log'"
check "1r. CONTROL. …and does NOT escalate" \
  "! says \"\$OUT_OK\" 'escalated'"
check "1s. CONTROL. …and still writes the logs.json recheck reads" \
  "[ -s '$M_OK/xo/logs.json' ] && grep -q 'lcars-20261002-901-bbbb' '$M_OK/xo/logs.json'"
check "1t. CONTROL. …and records the filing in the journal, not a refusal" \
  "grep -q '\"action\": \"filed-logs\"' '$M_OK/number-one.jsonl' && \
   ! grep -q 'log-refused' '$M_OK/number-one.jsonl'"

# ===========================================================================
printf '\n── 2. D-B. a shot name that carries its own extension is cited ──\n'
# ===========================================================================
# The real filer, over the real verdict, against a real shots directory.

SHOTS="$TMPROOT/shots"
rm -rf "$SHOTS"; mkdir -p "$SHOTS"
printf '$ gh workflow run publish\nImportError: attempted relative import\n' >"$SHOTS/02-workflow-run.txt"
printf 'PNG-ish bytes\n' >"$SHOTS/shot-01.png"

plan_logs() { # <outdir> <shotsdir>
  rm -rf "$1"; mkdir -p "$1"
  "$PY" "$LOGSPY" "$TMPROOT/verdict.json" "$TMPROOT/criteria.json" "$1" "$2" 10 \
    2>"$1/.err"
}
PLAN="$(plan_logs "$TMPROOT/out" "$SHOTS")"
check "2a. fixture. the filer produced a plan at all" \
  "[ -n \"\$PLAN\" ] && [ -s '$TMPROOT/out/1.md' ]"

# WHICH PRD IS WHOSE, read off the line the filer writes for the criterion it is
# ABOUT ("The criterion is `prd-3`, written at your PRD") — never off a bare id,
# which also appears in the OTHER bug's Out of Scope list. The `.` matches the
# backtick so this file needs none of its own.
prd_for() { # <criterion>
  local f
  for f in "$TMPROOT"/out/*.md; do
    grep -q "The criterion is .$1., written at" "$f" 2>/dev/null \
      && { printf '%s' "$f"; return 0; }
  done
  printf ''
}
PRD_T="$(prd_for prd-3)"
PRD_P="$(prd_for prd-4)"
check "2b. fixture. a PRD was written for each of the two gaps" \
  "[ -n \"\$PRD_T\" ] && [ -n \"\$PRD_P\" ] && [ \"\$PRD_T\" != \"\$PRD_P\" ]"

check "2c. D-B. the .txt-named transcript is cited by its own real path" \
  "grep -q '$SHOTS/02-workflow-run.txt' \"\$PRD_T\""
check "2d. D-B. …so it no longer claims the evidence was not retained" \
  "[ -n \"\$PRD_T\" ] && ! grep -q 'was not retained' \"\$PRD_T\""
check "2e. CONTROL. a BARE name still resolves through the extension probe" \
  "grep -q '$SHOTS/shot-01.png' \"\$PRD_P\""
check "2f. CONTROL. a name with nothing on disk still admits it was not kept" \
  "[ -n \"\$(plan_logs '$TMPROOT/out-gone' '$TMPROOT/empty-shots')\" ] && \
   grep -q 'was not retained' '$TMPROOT/out-gone/1.md'"

# ===========================================================================
printf '\n── 3. D-C. the evidence word comes off the row, not off "it has a shot" ──\n'
# ===========================================================================
G3="$(ev_of "$TMPROOT/verdict.json" gaps prd-3)"
G4="$(ev_of "$TMPROOT/verdict.json" gaps prd-4)"
B3="$(ev_of "$TMPROOT/verdict.json" blockers prd-3)"
B4="$(ev_of "$TMPROOT/verdict.json" blockers prd-4)"

check "3a. fixture. the gap records really declare NO evidence word" \
  "! grep -q '\"criterion\": \"prd-3\", \"kind\": \"contradiction\", \"title\": \"the published page shows github.com, never the host the CLI stored\", \"expected\": \"the host recorded by notes add\", \"evidence\"' '$TMPROOT/worker.json'"
check "3b. D-C. a gap whose only evidence is a .txt reads \`transcript\`" \
  "[ \"\$G3\" = transcript ]"
check "3c. D-C. …and so does the blocker built from it" \
  "[ \"\$B3\" = transcript ]"
check "3d. CONTROL. a genuine screenshot gap still reads \`picture\`" \
  "[ \"\$G4\" = picture ]"
check "3e. CONTROL. …and so does its blocker" \
  "[ \"\$B4\" = picture ]"
# THE WHOLE VERDICT, CHECKED FOR AGREEMENT WITH ITSELF. The captain reads the
# gap and the ledger row for the same criterion side by side; the word must not
# differ between them. This is the assertion that fails on the parent for every
# gap the live look produced, not just the one planted above.
cat >"$TMPROOT/agree.py" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
# THE LEDGER ROWS LIVE UNDER `criteria` IN THE VERDICT. Reading a key that is
# not there would make this check pass on anything, which is how a control goes
# vacuous — so the row count is PRINTED and asserted below.
rows = {str(e.get("id") or ""): str(e.get("evidence") or "")
        for e in d.get("criteria") or []}
if not rows:
    print("NO ROWS READ")
    raise SystemExit(0)
bad = []
for group in ("gaps", "blockers"):
    for g in d.get(group) or []:
        cid = str(g.get("criterion") or "")
        rev, gev = rows.get(cid, ""), str(g.get("evidence") or "")
        if rev and gev and rev != gev:
            bad.append("%s/%s: row=%s %s=%s" % (group, cid, rev, group, gev))
print("; ".join(bad) if bad else "AGREE %d rows" % len(rows))
P
AGREE="$("$PY" "$TMPROOT/agree.py" "$TMPROOT/verdict.json" 2>&1)"
check "3f. fixture. the agreement check really read the ledger rows (not vacuous)" \
  "[ \"\$AGREE\" != 'NO ROWS READ' ]"
check "3g. D-C. no gap or blocker contradicts its own ledger row's evidence word" \
  "[ \"\$AGREE\" = 'AGREE 5 rows' ]"

# The structural fallback, exercised on its own: no ledger word at all.
cat >"$TMPROOT/nameonly.py" <<'P'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import importlib.util
spec = importlib.util.spec_from_file_location("xs", os.path.join(sys.argv[1], "xo-score.py"))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.shot_name_evidence("02-workflow-run.txt"),
      m.shot_name_evidence("round1-01.png"),
      m.shot_name_evidence("shot-01"),
      m.shot_name_evidence("readout.json"))
P
NAMEWORDS="$("$PY" "$TMPROOT/nameonly.py" "$REPO_ROOT/skills/lcars-xo" 2>/dev/null)"
check "3h. D-C. the filename fallback: .txt -> transcript, .png/bare -> picture" \
  "[ \"\$NAMEWORDS\" = 'transcript picture picture measurement' ]"

# ===========================================================================
printf '\n── 4. the ledgered facts, the fence, and nothing spent ──\n'
# ===========================================================================
check "4a. the works downgrade is still gated on a MET row (nothing widened)" \
  "grep -q 'if kind == \"works\" and e\[\"status\"\] == \"met\"' '$SCOREPY'"
check "4b. the round-1 comment no longer calls Cure 2 a protected FAULT" \
  "grep -q 'WHAT IT PROTECTS IS A PASS, NOT A FAULT' '$SCOREPY'"
check "4c. the refusal reason is a named function, not an inlined head -1" \
  "grep -q 'xo_log_refusal_why' '$SCRIPT' && \
   ! grep -q 'refused them — \$(printf' '$SCRIPT'"
check "4d. the auto resolve-logs launch is LEFT EXACTLY AS IT IS (captain's call)" \
  "grep -q 'XO_RESOLVE_SCRIPT\" --parent' '$SCRIPT'"
check "4e. lcars-common.sh is untouched" \
  "cd '$REPO_ROOT' && git diff --quiet -- skills/lcars-init/lcars-common.sh"
# S247 — THE FENCE, NOT THE FILE. This was `git diff --quiet` over the whole of
# `xo-run.py`, which pinned every line in it, fence or not — and S247 legitimately
# deletes 57 lines of templater DELIVERY from that same file (`unbuilt`,
# `BY_DESIGN`, `say_unbuilt`: the "items I could not build" console block). A
# whole-file guard cannot tell that apart from someone weakening the argv fence,
# so it is narrowed to the fence ITSELF and made STRONGER: the refusal symbols are
# compared, source for source, against the committed version. Any edit to any of
# them fails this, and an edit anywhere else in the file does not.
cat >"$TMPROOT/fence-src.py" <<'FENCEEOF'
import ast, sys
WANT = ("SHELLS", "LAUNDERERS", "INTERPRETERS", "SHELL_FLAG_LETTERS",
        "INLINE_FLAG_LETTERS", "INLINE_LONG", "HOME_MARK", "EXTRA_HOME_MARKS",
        "_shell_refusal", "argv_refusal", "declared_escape", "refuse_reason")
src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src)
out = []
for node in tree.body:
    name = None
    if isinstance(node, (ast.FunctionDef,)):
        name = node.name
    elif isinstance(node, ast.Assign) and len(node.targets) == 1 \
            and isinstance(node.targets[0], ast.Name):
        name = node.targets[0].id
    if name in WANT:
        out.append("### %s\n%s" % (name, ast.get_source_segment(src, node)))
missing = [w for w in WANT if not any(o.startswith("### %s\n" % w) for o in out)]
assert not missing, "the fence has lost symbols: %s" % missing
print("\n".join(out))
FENCEEOF
( cd "$REPO_ROOT" && git show HEAD:skills/lcars-xo/xo-run.py ) \
  >"$TMPROOT/xo-run-head.py" 2>/dev/null
check "4f. fixture — the fence symbols are all still there to compare" \
  "$PY '$TMPROOT/fence-src.py' '$REPO_ROOT/skills/lcars-xo/xo-run.py' >'$TMPROOT/fence-now.txt'"
check "4f. the argv fence itself is untouched, symbol for symbol" \
  "$PY '$TMPROOT/fence-src.py' '$TMPROOT/xo-run-head.py' >'$TMPROOT/fence-head.txt' && \
   diff '$TMPROOT/fence-head.txt' '$TMPROOT/fence-now.txt'"
check "4f. CONTROL — that comparison can FAIL (one word changed in a refusal)" \
  "sed 's/is not a step the harness executes/is fine actually/' \
     '$REPO_ROOT/skills/lcars-xo/xo-run.py' >'$TMPROOT/xo-run-weak.py' && \
   sed 's/\\(if prog in SHELLS:\\)/\\1\\n        return \"\"/' \
     '$TMPROOT/xo-run-weak.py' >'$TMPROOT/xo-run-weak2.py' && \
   $PY '$TMPROOT/fence-src.py' '$TMPROOT/xo-run-weak2.py' >'$TMPROOT/fence-weak.txt' && \
   ! diff -q '$TMPROOT/fence-now.txt' '$TMPROOT/fence-weak.txt' >/dev/null"
# S250 — THE FENCE, NOT THE FILE: the same narrowing 4f already got, for the same
# reason and with the same care. This pinned the WHOLE of worker-adapter.sh, and
# S250 touches two copilot TOOL NAMES in it — the search tool is spelled `rg` (same
# tool as `grep`; both names resolve, measured on copilot 1.0.92), and the
# `number-one` role drops `create` so it depends on no write tool at all, saying its
# verdict in its reply instead. `create` still exists and still works; the other
# read roles keep it. A whole-file pin cannot tell that apart from someone weakening the
# fence, so what gets pinned is THE FENCE: every role's claude DENY list, list for
# list, and the refusal that stops a claude spawn whose argv carries none. Those
# are the lines that take a tool away; `adapter_tools` only pre-approves.
# D2 (fix round 1) — THE SPAWN REFUSAL, DRIVEN, NOT GREPPED. 4g's first cut
# asserted the refusal by looking for its ERROR STRING in the source
# (`grep -q 'worker whose argv carries no --disallowedTools'`). That is prose, not
# behaviour: with the whole refusal BLOCK deleted the string survives in the
# comment above it, so the fence could be removed and this suite still read all
# green. Measured — that is exactly what happened.
#
# So the refusal is DRIVEN. A copy of the real adapter is mutated so its claude
# argv emits no `--disallowedTools`, and the spawn is asked for. Two things are
# asserted, and the second is what makes it a fence rather than a failure: the
# spawn is REFUSED *by that check, naming it*, and the CLI stub is NEVER RUN.
#
# The copy is given the real $LCARS_WORKER_GUARD_LIB. Without it a mutated adapter
# in a temp dir dies at the LATER "worker guard is missing" check instead, which
# fails the spawn for an unrelated reason and would pass just as happily with the
# fence deleted (worker-fence.test.sh 1j, now cured the same way).
UNF="$TMPROOT/unfenced"; mkdir -p "$UNF/bin"
sed "s/'--allowedTools' \"\$tools\" '--disallowedTools' \"\$deny\" \\\\/'--allowedTools' \"\$tools\" \\\\/" \
  "$REPO_ROOT/skills/lcars-run/worker-adapter.sh" >"$UNF/adapter.sh"
printf '#!/usr/bin/env bash\nprintf RAN >>"%s/ran.log"\nexit 0\n' "$UNF" >"$UNF/bin/claude"
chmod +x "$UNF/bin/claude"
LCARS_WORKER_GUARD_LIB="$REPO_ROOT/skills/lcars-init/worker-guard.sh" \
  LCARS_WORKER_MODEL= LCARS_WORKER_INPUT_DIRS= \
  bash "$UNF/adapter.sh" argv claude number-one "$UNF/o" >"$UNF/argv.txt" 2>/dev/null
check "4g0. (setup) the mutated adapter really does emit a claude argv with NO deny list" \
  "[ -s '$UNF/argv.txt' ] && ! grep -qxF -- '--disallowedTools' '$UNF/argv.txt'"
DENY_ERR="$UNF/err.txt"
if LCARS_WORKER_GUARD_LIB="$REPO_ROOT/skills/lcars-init/worker-guard.sh" \
   LCARS_WORKER_BIN="$UNF/bin/claude" LCARS_WORKER_MODEL= LCARS_WORKER_INPUT_DIRS= \
   bash "$UNF/adapter.sh" spawn claude number-one "$UNF/out" "p" \
     >/dev/null 2>"$DENY_ERR"; then DENY_REFUSED=SPAWNED; else DENY_REFUSED=REFUSED; fi
# …and refused BY THE FENCE, named: any other non-zero exit would read as a pass.
grep -q 'carries no --disallowedTools' "$DENY_ERR" || DENY_REFUSED="REFUSED-BUT-NOT-BY-THE-FENCE: $(head -1 "$DENY_ERR")"
printf '    the unfenced claude spawn: %s\n' "$DENY_REFUSED"
check "4g. ownership.sh is untouched; worker-adapter still DENIES list-for-list, and REFUSES an unfenced claude spawn before it spends" \
  "cd '$REPO_ROOT' && git diff --quiet -- skills/lcars-run/ownership.sh && \
   [ \"\$(for r in repo-read repo-read-web repo-write launch number-one default; do \
            bash '$REPO_ROOT/skills/lcars-run/worker-adapter.sh' deny claude \$r; echo; \
          done)\" = 'Edit,Bash,NotebookEdit,WebSearch,WebFetch
Edit,Bash,NotebookEdit
NotebookEdit
Edit,Bash,NotebookEdit
Edit,Bash,NotebookEdit,WebSearch,WebFetch
Write,Edit,Bash,NotebookEdit,WebSearch,WebFetch' ] && \
   [ "$DENY_REFUSED" = REFUSED ] && [ ! -f "$UNF/ran.log" ]"
check "4h. no worker CLI was invoked anywhere in this suite" \
  "[ ! -s '$SPEND_LOG' ]"

# ===========================================================================
printf '\n── 5. S250 FIX ROUND 1 — D2 the refusals are visible; D3 "Observed live" says where ──\n'
# ===========================================================================
#
# D2, MEASURED ON THE S250 DRIVE. Six rounds asked for 27 steps; 17 ran. The 10
# refusals each carried an excellent plain-English reason, recorded ONLY in
# `actions-kept-N.json`. The console counted survivors ("… 0 declined at
# execution"); ROUND 3, whose every step was refused, printed NOTHING between
# "round 3 — looking…" and "round 4 — looking…"; and `report.md` said the word
# "refused" zero times while four of its twelve untested rows were untested
# because of one. The captain must be able to tell "it got better at finding and
# filing" from "it got better at saying it could not check".
#
# D3. All three filed bug PRDs opened AC #1 with `Observed live:` when
# `xo/live.json` did not exist and no live step had run. The opener is mandatory
# (`autopilot.sh file-bug` refuses a PRD without it) so it stays — and the clause
# after it now says WHERE, off the step readout's own `live` stamp.

XORUNPY="$REPO_ROOT/skills/lcars-xo/xo-run.py"
XOJOURNEYPY="$REPO_ROOT/skills/lcars-xo/xo-journey.py"
R5="$TMPROOT/r5"; mkdir -p "$R5"

# Round 3 of the drive, in the shapes the harness actually refused: a shell, an
# absolute path, and a second shell. Not one of the three survives.
cat >"$R5/actions-3.json" <<'JSON'
{"actions": [
  {"do": "run", "argv": ["sh", "-c", "python3 -m relay render"], "cwd": "<worktree>",
   "evidence": "20-corrupt.txt", "for": "prd-4"},
  {"do": "run", "argv": ["python3", "-m", "relay", "render", "--out",
                          "/no-such-dir-xo-98765/page.html"], "cwd": "<worktree>",
   "evidence": "21-outside.txt", "for": "prd-4"},
  {"do": "run", "argv": ["sh", "-c", "rm -rf requests"], "cwd": "<worktree>",
   "evidence": "22-wipe.txt", "for": "prd-4"}
]}
JSON
mkdir -p "$R5/m/xo"
printf '{"source": ["the cli checklist"], "steps": [], "reachSteps": []}\n' >"$R5/m/xo/journey.json"
"$PY" "$XORUNPY" actions --actions "$R5/actions-3.json" --out "$R5/m/xo/actions-kept-3.json" \
  --mission-dir "$R5/m" --cap 12 >"$R5/actions.out" 2>&1
check "5a. (rig) all three of round 3's steps really were refused" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
sys.exit(0 if len(d.get(\"refused\") or [])==3 and not (d.get(\"reachSteps\") or []) else 1)" "$R5/m/xo/actions-kept-3.json"'

"$PY" "$XOJOURNEYPY" reach-record --journey "$R5/m/xo/journey.json" \
  --steps "$R5/m/xo/actions-kept-3.json" --round 3 >"$R5/record.out" 2>&1
check "5b. a round whose EVERY step was refused still puts them on the journey record" \
  '"$PY" -c "
import json,sys
d=json.load(open(sys.argv[1]))
r=d.get(\"refusedSteps\") or []
sys.exit(0 if len(r)==3 and all(x.get(\"round\")==\"3\" and x.get(\"why\") for x in r) else 1)" "$R5/m/xo/journey.json"'
check "5c. and reach-record SAYS how many it was refused" \
  'grep -q "refused" "$R5/record.out"'

score5() { # <out-dir> <journey.json or "">
  mkdir -p "$1"
  "$PY" "$SCOREPY" "$TMPROOT/worker.json" "$TMPROOT/criteria.json" \
    "$1/verdict.json" "" "" "" "" "" "" "" "" "" "$2" "" "" "" \
    >"$1/out.txt" 2>"$1/err.txt"
}
score5 "$R5/scored" "$R5/m/xo/journey.json"
check "5d. the report has its own section for the steps it was not allowed to run" \
  'grep -q "Steps I asked for and was not allowed to run" "$R5/scored/report.md"'
check "5e. it counts them, and says the limit is MINE and not his build" \
  '"$PY" -c "
import sys
s=open(sys.argv[1]).read().split(\"Steps I asked for and was not allowed to run\",1)[1][:900]
sys.exit(0 if \"3 steps\" in s and \"gaps in my checking\" in s else 1)" "$R5/scored/report.md"'
check "5f. and it gives the harness's own plain-English reason for each" \
  '"$PY" -c "
import sys
s=open(sys.argv[1]).read().split(\"Steps I asked for and was not allowed to run\",1)[1][:1600]
sys.exit(0 if \"a step has no shell\" in s and \"inside the sandbox\" in s else 1)" "$R5/scored/report.md"'
check "5g. two refusals with the SAME reason are collapsed with a count, not repeated" \
  '"$PY" -c "
import sys
s=open(sys.argv[1]).read().split(\"Steps I asked for and was not allowed to run\",1)[1][:1600]
sys.exit(0 if \"**2 x \" in s and \"*(round 3, 3)*\" in s else 1)" "$R5/scored/report.md"'
check "5h. CONTROL — a look that was refused NOTHING grows no such section" \
  'score5 "$R5/clean" "" ; ! grep -q "Steps I asked for and was not allowed to run" "$R5/clean/report.md"'

# ── THE CONSOLE HALF, run through xo.sh's OWN function, not a copy of it ─────
awk '/^xo_say_refusals\(\)/,/^}$/' "$SCRIPT" >"$R5/say.sh"
check "5i. (rig) the function was lifted out of xo.sh whole" \
  'grep -q "xo_say_refusals()" "$R5/say.sh" && [ "$(tail -1 "$R5/say.sh")" = "}" ]'
XO_PY="$PY" bash -c 'XO_PY="$1"; source "$2"; xo_say_refusals "$3" 3' \
  _ "$PY" "$R5/say.sh" "$R5/m/xo/actions-kept-3.json" >"$R5/console.txt" 2>&1
check "5j. the console says how many were refused BEFORE anything ran" \
  'grep -q "round 3 asked for 3 step(s); 3 were refused before anything ran, 0 went ahead" "$R5/console.txt"'
check "5k. and prints every reason, so round 3 is no longer silent" \
  '[ "$(grep -c "REFUSED (run)" "$R5/console.txt")" = 3 ] && \
   grep -q "a step has no shell" "$R5/console.txt"'
printf '{"asked": 2, "cap": 12, "steps": [], "reachSteps": [{"do": "run"}, {"do": "read"}], "refused": [], "overflow": 0}\n' \
  >"$R5/kept-clean.json"
XO_PY="$PY" bash -c 'XO_PY="$1"; source "$2"; xo_say_refusals "$3" 4' \
  _ "$PY" "$R5/say.sh" "$R5/kept-clean.json" >"$R5/console-clean.txt" 2>&1
check "5l. CONTROL — a round with no refusals prints nothing at all" \
  '[ ! -s "$R5/console-clean.txt" ]'
check "5m. xo.sh records and says the refusals BEFORE the nothing-granted return" \
  '"$PY" -c "
import sys
t=open(sys.argv[1]).read()
body=t.split(\"xo_reach_actions() {\",1)[1].split(\"\n}\",1)[0]
say=body.index(\"xo_say_refusals\")
rec=body.index(\"reach-record --journey\")
stop=body.index(\"xo_reach_count\")
sys.exit(0 if say < rec < stop else 1)" "$SCRIPT"'

# ── D3: THE OPENER KEEPS ITS WORD AND THE SENTENCE SAYS WHERE ───────────────
S5="$TMPROOT/shots-live"; rm -rf "$S5"; mkdir -p "$S5"
printf '$ relay publish\nImportError: attempted relative import\n' >"$S5/02-workflow-run.txt"
printf 'PNG-ish bytes\n' >"$S5/shot-01.png"
printf '{"do": "run", "key": "R1", "for": "prd-3", "checkedBy": "cli", "met": false}\n' \
  >"$S5/02-workflow-run.json"
plan_logs "$TMPROOT/out-local" "$S5" >/dev/null
L_LOCAL="$(grep -l 'The criterion is .prd-3., written at' "$TMPROOT"/out-local/*.md 2>/dev/null | head -1)"
check "5n. (rig) a PRD was written for the transcript-settled gap" '[ -n "$L_LOCAL" ]'
check "5o. AC #1 still OPENS with the mandatory Observed live: line" \
  'grep -q "^- Observed live:" "$L_LOCAL"'
check "5p. and it now says the observation was LOCAL, not on a live host" \
  'grep -q "^- Observed live: in the reviewer.s own detached worktree on one machine, NOT on a live host" "$L_LOCAL"'
printf '{"do": "run", "key": "R1", "for": "prd-3", "checkedBy": "cli", "met": false,\n "live": {"host": "github.com", "owner": "roferg", "repo": "lcars-s235",\n          "consentedBy": "autopilot.json liveTargets"}}\n' \
  >"$S5/02-workflow-run.json"
plan_logs "$TMPROOT/out-live" "$S5" >/dev/null
L_LIVE="$(grep -l 'The criterion is .prd-3., written at' "$TMPROOT"/out-live/*.md 2>/dev/null | head -1)"
check "5q. CONTROL — a step that DID reach a real host says so, and names it" \
  '[ -n "$L_LIVE" ] && \
   grep -q "^- Observed live: on the real host github.com/roferg/lcars-s235 (consented in autopilot.json liveTargets)," "$L_LIVE"'
check "5r. CONTROL — a gap whose evidence has no readout at all claims neither" \
  'L_NONE="$(grep -l "The criterion is .prd-4., written at" "$TMPROOT"/out-live/*.md 2>/dev/null | head -1)" ; \
   [ -n "$L_NONE" ] && grep -q "^- Observed live:" "$L_NONE" && \
   ! grep -q "NOT on a live host" "$L_NONE" && ! grep -q "on the real host" "$L_NONE"'

echo
printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
