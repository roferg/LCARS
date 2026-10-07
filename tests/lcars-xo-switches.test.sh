#!/usr/bin/env bash
#
# S240 FIX ROUND 1 — THE TWO SWITCHES, THE TRANSCRIPT, AND THE PATH IT CITES.
#
# A fresh tester drove the real production code on planted ledgers and measured
# three defects. This suite pins all three, and each check carries a positive
# control in its own phrasing family so none of them can pass on a constant.
#
#  D1 (HIGH) — THE CONFIG SWITCHES WERE UNREADABLE ON A NORMALLY FORMATTED
#     CONFIG, AND FAILED IN OPPOSITE DIRECTIONS. `cfg_block` read `numberOne`
#     through `lcars_config_get_raw`, a single-line `sed` that takes the rest of
#     the line after the key. MEASURED on a config saying `enabled: true,
#     filesBugs: false`:
#
#       pretty-printed (what any editor writes) -> `{`   =>  enabled OFF,
#                                                           filesBugs FILES
#       one line (what `lcars xo on` writes)    -> the object (and the NEXT key)
#
#     So a hand-edited config silently ignored both switches, in OPPOSITE
#     directions — and the product's own refusal message ("Turn it back on in
#     `.git/lcars/config.json`") is what invites the hand edit. The READERS are
#     fixed; `lcars_config_get_raw` is ledgered as the shared root cause and left
#     alone (see the comment block above `cfg_block`).
#
#  D2 (HIGH) — A TRANSCRIPT-PROVEN FAULT WAS DEMOTED, AND IT DECIDED THE
#     HEADLINE. `settled_by_picture_alone` predates S239, which made
#     `transcript` a real evidence word, so a works-question settled by a CLI
#     run with its transcript on disk read as "a picture alone" and the
#     works-kind downgrade rewrote the row to `untested` / `evidence: none`.
#     MEASURED: a high-impact row came out graded HIGH, recommending
#     `merge-with-follow-ups`, with ZERO blockers and nothing filed.
#
#  D3 (MEDIUM) — THE FILED PRD CITED AN EVIDENCE PATH THAT DID NOT EXIST.
#     `evidence_ref` synthesised a filename off an extension table with no
#     existence guard (`xo.sh` guards only the ATTACHMENT), so AC #1 and AC #4
#     quoted a dead absolute path inside the PARENT's untracked, sweepable
#     `.git/lcars/`. And the prose spliced the ledger row's `note` into "the
#     build gave …", producing "the build gave ran it and it did not do that".
#
# WHAT IS NOT CHANGED, AND IS ASSERTED NOT TO BE: the S240 recommendation rule
# (a `low` from infrastructure still reaches merge-with-follow-ups; the same
# ledger with `cause: product` still reaches send-back), and the grade ladder.
#
# Skill source under test:
#   skills/lcars-xo/xo.sh         — cfg_block / cfg_flag / cfg_enabled /
#                                   cfg_files_bugs, driven through the real
#                                   `status` and `file-logs` verbs
#   skills/lcars-xo/xo-score.py   — settled_by_picture_alone + the works downgrade
#   skills/lcars-xo/xo-logs.py    — evidence_ref's existence guard + the PRD prose
#
# ZERO SPEND. No worker CLI, no browser, no gh, no network. A PATH shim stubs
# `claude` AND `copilot` and is PROVEN to fire before "no spend" is claimed.
#
# Usage: bash tests/lcars-xo-switches.test.sh

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
echo "=== lcars xo: the two switches, the transcript, and the path it cites ==="
echo

# ===========================================================================
printf '── 0. the shim is proven to fire ──\n'
# ===========================================================================
claude --version >/dev/null 2>&1
check "0a. the PATH shim intercepts \`claude\` (so a later 'no spend' means something)" \
  "grep -q '^claude ' '$SPEND_LOG'"
copilot --version >/dev/null 2>&1
check "0b. …and \`copilot\` too" \
  "grep -q '^copilot ' '$SPEND_LOG'"
: >"$SPEND_LOG"

# ===========================================================================
printf '\n── 1. the `enabled` switch, in BOTH config styles ──\n'
# ===========================================================================
# `lcars xo status` prints "NUMBER ONE: ON" / "NUMBER ONE: OFF" straight off
# cfg_enabled, so this drives the real reader through the real verb.

new_repo() { # <name> <numberOne-literal-or-empty> <pretty|oneline>
  local repo="$TMPROOT/$1" blk="$2" style="$3"
  rm -rf "$repo"; mkdir -p "$repo"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  "$PY" - "$repo/.git/lcars/config.json" "$blk" "$style" <<'P'
import json, sys
path, blk, style = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = {"cloneId": "aaaaaaaa", "projectName": "repo", "contextFile": None,
       "stack": None, "testCommand": "true", "worktreeSetupCommand": None,
       "comprehensionBudget": 1200, "created": "2026-05-30T00:00:00Z"}
if blk.strip():
    cfg["numberOne"] = json.loads(blk)
    # `numberOne` is NOT last on purpose — the one-line reader's greed used to
    # swallow whatever followed it, so something has to follow it.
    cfg["zzLast"] = "after the block"
if style == "pretty":
    # EXACTLY what an editor (or `python -m json.tool`, or `jq .`) writes.
    open(path, "w").write(json.dumps(cfg, indent=2) + "\n")
else:
    # EXACTLY what `lcars xo on` writes: every value on the key's own line,
    # the OBJECT on ONE line.
    lines = ["{"]
    items = list(cfg.items())
    for i, (k, v) in enumerate(items):
        comma = "," if i < len(items) - 1 else ""
        lines.append('  %s: %s%s' % (json.dumps(k), json.dumps(v), comma))
    lines.append("}")
    open(path, "w").write("\n".join(lines) + "\n")
json.load(open(path))
P
  printf '%s' "$repo"
}

# CAPTURED, NEVER PIPED. `grep -q` exits on its first match; a pipeline out of a
# still-running xo.sh then takes SIGPIPE and `set -o pipefail` turns the check
# into a 141 — a FAIL that says nothing about the product. This cost the first
# run of this suite six phantom failures, so every assertion below reads a
# CAPTURED string through a here-string.
xo_status() { ( cd "$1" && LCARS_OWNER_ENFORCE=0 bash "$SCRIPT" status 2>&1 ); }
says() { grep -q "$2" <<<"$1"; }

R_PRETTY_ON="$(new_repo cfg-pretty-on '{"enabled": true, "engine": "copilot", "filesBugs": false}' pretty)"
R_ONE_ON="$(new_repo   cfg-one-on    '{"enabled": true, "engine": "copilot", "filesBugs": false}' oneline)"
R_PRETTY_OFF="$(new_repo cfg-pretty-off '{"enabled": false, "engine": "copilot"}' pretty)"
R_ABSENT="$(new_repo   cfg-absent    '' pretty)"

check "1a. the pretty-printed config really is multi-line inside numberOne (fixture proof)" \
  "[ \"\$(grep -c '\"enabled\"' '$R_PRETTY_ON/.git/lcars/config.json')\" = 1 ] && \
   ! grep -q '\"numberOne\": {\"enabled\"' '$R_PRETTY_ON/.git/lcars/config.json'"
check "1b. the one-line config really has the object on one line (fixture proof)" \
  "grep -q '\"numberOne\": {\"enabled\": true' '$R_ONE_ON/.git/lcars/config.json'"

check "1c. D1. a PRETTY-PRINTED config with enabled:true reads ON" \
  "says \"\$(xo_status '$R_PRETTY_ON')\" 'NUMBER ONE: ON'"
check "1d. control. the SINGLE-LINE config with enabled:true still reads ON" \
  "says \"\$(xo_status '$R_ONE_ON')\" 'NUMBER ONE: ON'"
check "1e. control. a pretty-printed enabled:false reads OFF" \
  "says \"\$(xo_status '$R_PRETTY_OFF')\" 'NUMBER ONE: OFF'"
check "1f. control. no numberOne block at all reads OFF (the documented default)" \
  "says \"\$(xo_status '$R_ABSENT')\" 'NUMBER ONE: OFF'"
check "1g. the engine is still read off the pretty block, not lost with it" \
  "says \"\$(xo_status '$R_PRETTY_ON')\" copilot"
check "1h. control. the engine off the one-line block is unchanged" \
  "says \"\$(xo_status '$R_ONE_ON')\" copilot"

# ===========================================================================
printf '\n── 2. the `filesBugs` switch, in BOTH config styles ──\n'
# ===========================================================================
# Driven through the real `file-logs` verb with `lcars log` and `resolve-logs`
# stubbed, so the switch is read by the code that actually gates the filing.

LOG_STUB="$TMPROOT/log.sh"
cat >"$LOG_STUB" <<'LGS'
#!/usr/bin/env bash
printf 'log %s\n' "$*" >>"$XO_LOG_CALLS"
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
chmod +x "$LOG_STUB"

RESOLVE_STUB="$TMPROOT/resolve-logs.sh"
cat >"$RESOLVE_STUB" <<'RLS'
#!/usr/bin/env bash
printf 'resolve %s\n' "$*" >>"$XO_RESOLVE_CALLS"
exit 0
RLS
chmod +x "$RESOLVE_STUB"

HOST_STUB="$TMPROOT/host-adapter.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$HOST_STUB"
chmod +x "$HOST_STUB"

export XO_LOG_CALLS="$TMPROOT/log.calls"
export XO_RESOLVE_CALLS="$TMPROOT/resolve.calls"

# ONE verdict, planted the same way into every repo below, so the only thing
# that differs between the filing cases is the config's own formatting.
plant_mission() { # <repo> <id>
  local repo="$1" id="$2"
  local m="$repo/.git/lcars/missions/$2"
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
  cp "$TMPROOT/verdict-sb.json" "$m/xo/verdict.json"
  printf '$ notes publish\nwrote page.html with origin=github.com\n' \
    >"$m/xo/shots/01-publish.txt"
  printf '%s' "$m"
}

# ─── THE CONTRACT AND THE LEDGERS, SHARED BY SECTIONS 2-5 ────────────────────
# Five person-group criteria; prd-3 is a WORKS question (`notVisual`) whose only
# proof is a CLI transcript — the exemplar S240 exists for.
cat >"$TMPROOT/criteria.json" <<'C'
{"mission": "m", "hasDrawing": false, "placeNames": [], "pictures": [],
 "criteria": [
  {"id": "prd-1", "text": "notes add stores the title it was given", "source": "prd", "primary": true},
  {"id": "prd-2", "text": "notes list shows every stored note", "source": "prd", "primary": true},
  {"id": "prd-3", "text": "the published page shows the host the CLI stored", "source": "prd", "primary": true, "notVisual": true},
  {"id": "prd-4", "text": "publish refuses a note with no title", "source": "prd", "primary": true},
  {"id": "prd-5", "text": "the workflow publishes on a push to main", "source": "prd", "primary": true}
 ]}
C

shot_met() { # <id> <impact>
  printf '{"id": "%s", "impact": "%s", "impactWhy": "it is why %s exists", "status": "met", "shot": "shot-01", "evidence": "picture", "checkedBy": "browser", "kind": "looks", "note": "saw it", "action": "opened the page and read it", "reason": "Outcome: met."}' "$1" "$2" "$1"
}

# THE PLANTED LEDGER. prd-3 is a high-impact WORKS-question GAP whose evidence
# is a CLI transcript: `checkedBy: cli`, a recorded shot name, NO `action`
# string, and `sawInstead` carrying the one sentence that says what went wrong.
{
  printf '{"score": "medium", "summary": "The host does not survive the hop.", "criteria": ['
  printf '%s,' "$(shot_met prd-1 high)" "$(shot_met prd-2 high)"
  printf '{"id": "prd-3", "impact": "high", "impactWhy": "it is the point of the mission", "status": "gap", "kind": "works", "shot": "01-publish", "evidence": "transcript", "checkedBy": "cli", "note": "ran it and it did not do that", "sawInstead": "it printed github.com, the hardcoded one", "reason": "Outcome: gap."},'
  printf '%s,' "$(shot_met prd-4 medium)"
  printf '%s' "$(shot_met prd-5 medium)"
  printf '], "gaps": [{"criterion": "prd-3", "kind": "contradiction", "title": "the published page shows github.com, never the host the CLI stored", "expected": "the host recorded by notes add", "evidence": "transcript", "shot": "01-publish", "shots": [], "seam": "notes.py cmd_publish (writes host) -> page.py render_host (reads origin)", "impact": "high"}]}\n'
} >"$TMPROOT/worker-sb.json"
"$PY" "$SCOREPY" "$TMPROOT/worker-sb.json" "$TMPROOT/criteria.json" \
  "$TMPROOT/verdict-sb.json" >"$TMPROOT/score-sb.out" 2>"$TMPROOT/score-sb.err"

check "2a. the planted ledger scored at all (fixture proof)" \
  "[ -s '$TMPROOT/verdict-sb.json' ]"

xo_file_logs() { # <repo> <id>
  ( cd "$1" && LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_RUN_SCRIPT=/usr/bin/true LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      bash "$SCRIPT" file-logs --mission "$2" 2>&1 )
}

# ONE number, never two. `grep -c` prints `0` AND exits 1 when it matches
# nothing, so a `|| printf 0` fallback printed "0\n0" and `[ = 0 ]` failed on the
# very case it was there for.
filed_count() {
  local n
  n="$(grep -c '^log ' "$XO_LOG_CALLS" 2>/dev/null)" || n=0
  printf '%s' "${n:-0}"
}

# --- pretty-printed, filesBugs:false -> NOTHING is filed ---------------------
RP_OFF="$(new_repo files-pretty-off '{"enabled": true, "engine": "copilot", "filesBugs": false}' pretty)"
plant_mission "$RP_OFF" lcars-20261002-001 >/dev/null
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
OUT_P_OFF="$(xo_file_logs "$RP_OFF" lcars-20261002-001)"
N_P_OFF="$(filed_count)"

check "2b. D1. pretty-printed filesBugs:false files NOTHING" \
  "[ '$N_P_OFF' = 0 ]"
check "2c. …and says which switch did it, rather than going quiet" \
  "says \"\$OUT_P_OFF\" 'filing is off'"

# --- pretty-printed, filesBugs:true -> it files ------------------------------
RP_ON="$(new_repo files-pretty-on '{"enabled": true, "engine": "copilot", "filesBugs": true}' pretty)"
plant_mission "$RP_ON" lcars-20261002-002 >/dev/null
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
OUT_P_ON="$(xo_file_logs "$RP_ON" lcars-20261002-002)"
N_P_ON="$(filed_count)"
check "2d. control. pretty-printed filesBugs:true DOES file" \
  "[ '$N_P_ON' = 1 ]"

# --- pretty-printed, filesBugs absent -> the documented default is ON --------
RP_ABS="$(new_repo files-pretty-absent '{"enabled": true, "engine": "copilot"}' pretty)"
plant_mission "$RP_ABS" lcars-20261002-003 >/dev/null
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
xo_file_logs "$RP_ABS" lcars-20261002-003 >/dev/null
check "2e. control. filesBugs ABSENT files — absent still means the documented default" \
  "[ \"\$(filed_count)\" = 1 ]"

# --- POSITIVE CONTROL: the single-line form works EXACTLY as before ----------
RO_OFF="$(new_repo files-one-off '{"enabled": true, "engine": "copilot", "filesBugs": false}' oneline)"
plant_mission "$RO_OFF" lcars-20261002-004 >/dev/null
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
OUT_O_OFF="$(xo_file_logs "$RO_OFF" lcars-20261002-004)"
check "2f. control. the SINGLE-LINE filesBugs:false still files nothing" \
  "[ \"\$(filed_count)\" = 0 ] && says \"\$OUT_O_OFF\" 'filing is off'"

RO_ON="$(new_repo files-one-on '{"enabled": true, "engine": "copilot", "filesBugs": true}' oneline)"
plant_mission "$RO_ON" lcars-20261002-005 >/dev/null
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
xo_file_logs "$RO_ON" lcars-20261002-005 >/dev/null
check "2g. control. the SINGLE-LINE filesBugs:true still files" \
  "[ \"\$(filed_count)\" = 1 ]"

# ===========================================================================
printf '\n── 3. a transcript is an instrument, not a picture ──\n'
# ===========================================================================
# The DEMOTION case: the identical row with `status: met`. Before the fix the
# works-kind downgrade rewrote it to untested / evidence:none, which graded the
# look HIGH with zero blockers and filed nothing.
"$PY" - "$TMPROOT/worker-sb.json" "$TMPROOT/worker-met.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == "prd-3":
        e["status"] = "met"
d["gaps"] = []
json.dump(d, open(sys.argv[2], "w"))
P
# POSITIVE CONTROL for the guard that must SURVIVE: the same row, same recorded
# shot, but NO `checkedBy` — an evidence WORD with no instrument behind it.
"$PY" - "$TMPROOT/worker-met.json" "$TMPROOT/worker-noinstr.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == "prd-3":
        e.pop("checkedBy", None)
json.dump(d, open(sys.argv[2], "w"))
P
# SECOND POSITIVE CONTROL, a different phrasing family: a works row settled by a
# BROWSER on a PICTURE is still "a picture alone".
"$PY" - "$TMPROOT/worker-met.json" "$TMPROOT/worker-picture.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == "prd-3":
        e["evidence"], e["checkedBy"], e["shot"] = "picture", "browser", "shot-01"
json.dump(d, open(sys.argv[2], "w"))
P

score() { # <name> <worker.json>
  mkdir -p "$TMPROOT/$1"
  "$PY" "$SCOREPY" "$2" "$TMPROOT/criteria.json" "$TMPROOT/$1/verdict.json" \
    >"$TMPROOT/$1/out.txt" 2>"$TMPROOT/$1/err.txt"
}
rowf() { # <name> <criterion> <key>
  "$PY" - "$TMPROOT/$1/verdict.json" "$2" "$3" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == sys.argv[2]:
        v = e.get(sys.argv[3])
        print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
        break
P
}
topf() { # <name> <key>
  "$PY" - "$TMPROOT/$1/verdict.json" "$2" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
v = d.get(sys.argv[2])
print("" if v is None else (v if isinstance(v, str) else json.dumps(v)))
P
}

score sb        "$TMPROOT/worker-sb.json"
score metrow    "$TMPROOT/worker-met.json"
score noinstr   "$TMPROOT/worker-noinstr.json"
score picture   "$TMPROOT/worker-picture.json"

check "3a. D2. a works row settled by a CLI run keeps the status it was given" \
  "[ \"\$(rowf metrow prd-3 status)\" = met ]"
check "3b. …and keeps \`transcript\` as its recorded evidence, not \`none\`" \
  "[ \"\$(rowf metrow prd-3 evidence)\" = transcript ]"
check "3c. …and is not stamped couldNotCheck: works-needs-action" \
  "[ -z \"\$(rowf metrow prd-3 couldNotCheck)\" ]"
check "3d. …and is counted as a works question that WAS exercised" \
  "says \"\$(topf metrow questionSplit)\" '\"worksExercised\": 1'"
check "3e. control. an evidence WORD with no \`checkedBy\` is STILL demoted" \
  "[ \"\$(rowf noinstr prd-3 status)\" = untested ] && \
   [ \"\$(rowf noinstr prd-3 couldNotCheck)\" = works-needs-action ]"
check "3f. control. …and is counted as a works question settled on a picture alone" \
  "says \"\$(topf noinstr questionSplit)\" '\"worksPictureOnly\": 1'"
check "3g. control. a works row a BROWSER settled on a PICTURE is still demoted" \
  "[ \"\$(rowf picture prd-3 status)\" = untested ] && \
   [ \"\$(rowf picture prd-3 couldNotCheck)\" = works-needs-action ]"

printf '\n   …and the GAP form reaches the headline it should:\n'
check "3h. the transcript-proven gap survives as a gap" \
  "[ \"\$(rowf sb prd-3 status)\" = gap ]"
check "3i. …it produces a blocker naming that criterion" \
  "says \"\$(topf sb blockers)\" 'prd-3'"
check "3j. …the blocker carries the recorded instrument" \
  "says \"\$(topf sb blockers)\" transcript"
check "3k. …and it drives send-back" \
  "[ \"\$(topf sb recommendation)\" = send-back ]"
check "3l. control. the demoted-row ledger does NOT reach send-back (so 3k is not a constant)" \
  "[ \"\$(topf noinstr recommendation)\" != send-back ]"
check "3m. the grade LADDER is untouched: the gap ledger still grades low" \
  "[ \"\$(topf sb score)\" = low ]"

# ===========================================================================
printf '\n── 4. the filed PRD never cites a path that is not there ──\n'
# ===========================================================================
US=$'\x1f'
prd_of() { awk -v FS="$US" '/^GAP/ { print $3; exit }' <<<"$1"; }

# A SHOTS DIRECTORY WITH THE TRANSCRIPT ON DISK — the path IS citable.
SHOTS_OK="$TMPROOT/shots-ok"; mkdir -p "$SHOTS_OK"
printf '$ notes publish\nwrote page.html with origin=github.com\n' >"$SHOTS_OK/01-publish.txt"
# A SHOTS DIRECTORY WHERE IT WAS SWEPT — the same ledger, nothing on disk.
SHOTS_GONE="$TMPROOT/shots-gone"; mkdir -p "$SHOTS_GONE"

plan() { # <verdict-name> <out-dir> <shots-dir>
  mkdir -p "$2"
  "$PY" "$LOGSPY" "$TMPROOT/$1/verdict.json" "$TMPROOT/criteria.json" \
    "$2" "$3" 10 2>"$TMPROOT/logs.err"
}
PLAN_OK="$(plan sb "$TMPROOT/out-ok" "$SHOTS_OK")"
PLAN_GONE="$(plan sb "$TMPROOT/out-gone" "$SHOTS_GONE")"
PRD_OK="$(prd_of "$PLAN_OK")"
PRD_GONE="$(prd_of "$PLAN_GONE")"

check "4a. the transcript-proven gap is filed in both cases (fixture proof)" \
  "[ -s \"\$PRD_OK\" ] && [ -s \"\$PRD_GONE\" ]"
check "4b. control. when the transcript IS on disk the path is still cited" \
  "grep -q '01-publish.txt' \"\$PRD_OK\""
check "4c. control. …and that cited path really exists" \
  "[ -f \"\$(sed -n 's|.*\`\($SHOTS_OK/[^\`]*\)\`.*|\\1|p' \"\$PRD_OK\" | sed -n 1p)\" ]"
check "4d. D3. when it was NOT retained, no path is cited at all" \
  "! grep -q '01-publish' \"\$PRD_GONE\""
check "4e. …and it says plainly that the evidence was not retained" \
  "grep -qi 'not retained' \"\$PRD_GONE\""
check "4f. …and names what was observed instead" \
  "grep -q 'it printed github.com, the hardcoded one' \"\$PRD_GONE\""
check "4g. EVERY backtick-quoted absolute path in the filed PRD exists on disk" \
  "\"\$PY\" - \"\$PRD_GONE\" \"\$PRD_OK\" <<'P'
import os, re, sys
bad = []
for p in sys.argv[1:]:
    for m in re.findall(r'\`(/[^\`]+)\`', open(p, encoding='utf-8').read()):
        if not os.path.exists(m):
            bad.append((p, m))
if bad:
    print('DEAD PATHS:', bad)
sys.exit(1 if bad else 0)
P"
check "4h. the round-trip AC is still there (the seam rule is not disturbed)" \
  "grep -qi 'round-trip' \"\$PRD_GONE\""
check "4i. the swept-shot PRD does not promise attachments it has not got" \
  "! grep -q 'Each PNG has a' \"\$PRD_GONE\""

# ===========================================================================
printf '\n── 5. the observation is `sawInstead`, not the row note spliced in ──\n'
# ===========================================================================
check "5a. D3. the observation clause uses sawInstead" \
  "grep -q 'the build gave it printed github.com, the hardcoded one' \"\$PRD_OK\""
check "5b. …and the row's note is NOT spliced into that clause" \
  "! grep -q 'the build gave ran it and it did not do that' \"\$PRD_OK\""

# A LEDGER WITH NO sawInstead AND NO gaps[].saw — the clause must stay
# grammatical rather than swallowing the row's sentence.
"$PY" - "$TMPROOT/worker-sb.json" "$TMPROOT/worker-nosaw.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
for e in d["criteria"]:
    if e["id"] == "prd-3":
        e.pop("sawInstead", None)
json.dump(d, open(sys.argv[2], "w"))
P
score nosaw "$TMPROOT/worker-nosaw.json"
PLAN_NOSAW="$(plan nosaw "$TMPROOT/out-nosaw" "$SHOTS_OK")"
PRD_NOSAW="$(prd_of "$PLAN_NOSAW")"
check "5c. with nothing written as an observation, the clause is still grammatical" \
  "grep -q 'Expected the host recorded by notes add; it did not.' \"\$PRD_NOSAW\""
check "5d. …and the row's own sentence is still said, as its own sentence" \
  "grep -q 'ran it and it did not do that' \"\$PRD_NOSAW\""

# POSITIVE CONTROL in its own phrasing family: a gap whose gaps[] entry DOES
# carry a `saw` noun phrase and no sawInstead still reads off `saw`.
"$PY" - "$TMPROOT/worker-nosaw.json" "$TMPROOT/worker-saw.json" <<'P'
import json, sys
d = json.load(open(sys.argv[1]))
d["gaps"][0]["saw"] = "a hardcoded github.com"
json.dump(d, open(sys.argv[2], "w"))
P
score sawonly "$TMPROOT/worker-saw.json"
PLAN_SAW="$(plan sawonly "$TMPROOT/out-saw" "$SHOTS_OK")"
PRD_SAW="$(prd_of "$PLAN_SAW")"
check "5e. control. a gaps[] \`saw\` noun phrase is still what the clause uses" \
  "grep -q 'the build gave a hardcoded github.com' \"\$PRD_SAW\""

# ===========================================================================
printf '\n── 6. nothing was spent, and the fence was not touched ──\n'
# ===========================================================================
check "6a. no worker CLI was invoked anywhere in this suite" \
  "[ ! -s '$SPEND_LOG' ]"
check "6b. the root cause is ledgered where the readers are" \
  "grep -q 'lcars_config_get_raw' '$SCRIPT' && \
   grep -q 'ROOT CAUSE IS' '$SCRIPT'"
check "6c. lcars_config_get_raw itself is UNCHANGED (shared code, left alone)" \
  "cd '$REPO_ROOT' && git diff --quiet -- skills/lcars-init/lcars-common.sh"
# S257 — THE GUARD SAYS WHAT IT MEANS NOW. It was `git diff --quiet` on
# xo-run.py, which asserted "S254 did not need to edit this file" and so broke
# the moment a later session edited it for an unrelated reason — which S257
# did: it widened the STEP-KIND READER (the verb is the action's key, not a
# `do` field, so every browser action was being refused before it ran) and did
# not go near the fence. The INTENT is the fence itself, so that is what is
# checked, behaviourally, against the real file: a shell is still refused, an
# absolute path outside the worktree is still refused, and a verb on neither
# allow-list is still refused. This cannot rot and cannot pass vacuously.
#
# AND THE SAMPLE SENDS BOTH SPELLINGS OF THE VERB (S257 fix round 1). This guard
# drove the real file and still missed a hole for a whole round, because every
# dangerous step in its sample spelled its verb `do` — and the defect was that
# the argv fence read `do` while the step-kind reader had been widened to read
# the verb off the KEY. The guard was re-run under a mutation and did fail, which
# proved the guard fires and proved NOTHING about whether the behaviour was
# whole: a mutation control on an incomplete sample cannot. So the sample now
# sends the key form of a shell request too — `{"run": "x", "argv": ["sh","-c",…]}`
# and the same for `workflow` — and the hole cannot reopen under a green guard.
check "6d. the argv fence still stands — a shell, an escape and an unknown verb are refused" \
  "$PY - <<'FENCE'
import json, os, subprocess, sys, tempfile
d = tempfile.mkdtemp()
acts = os.path.join(d, 'a.json')
json.dump({'actions': [
    {'do': 'run', 'argv': ['sh', '-c', 'echo hi'], 'cwd': '<worktree>'},
    {'do': 'run', 'argv': ['python3', '-m', 'relay', '--out', '/etc/passwd'],
     'cwd': '<worktree>'},
    # THE KEY FORM OF THE SAME TWO REQUESTS — the verb as the step's key, which
    # is the shape the action schema actually uses and the one this sample was
    # missing.
    {'run': 'x', 'argv': ['sh', '-c', 'echo hi'], 'cwd': '<worktree>'},
    {'workflow': 'x', 'argv': ['bash', '-c', 'echo hi'], 'cwd': '<worktree>'},
    {'frobnicate': 'x'},
    {'click': '#submit'},
]}, open(acts, 'w'))
out = os.path.join(d, 'kept.json')
subprocess.run([sys.executable, '$REPO_ROOT/skills/lcars-xo/xo-run.py', 'actions', '--actions', acts,
                '--out', out, '--cap', '12'], capture_output=True)
k = json.load(open(out))
shells = [r for r in k['refused'] if 'asks for a shell' in (r.get('why') or '')]
sys.exit(0 if len(k['refused']) == 5 and len(k['steps']) == 1
              and not k['reachSteps'] and len(shells) == 3 else 1)
FENCE"
check "6e. worker-adapter.sh and ownership.sh are untouched" \
  "cd '$REPO_ROOT' && git diff --quiet -- skills/lcars-run/worker-adapter.sh skills/lcars-run/ownership.sh"
check "6f. the works-kind downgrade is still IN the code (widened, not removed)" \
  "grep -q 'works-needs-action' '$SCOREPY' && \
   grep -q 'EXERCISED_CHECKED_BY' '$SCOREPY'"

echo
printf '=== %d passed, %d failed ===\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
