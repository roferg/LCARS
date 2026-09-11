#!/usr/bin/env bash
# ===========================================================================
# S196 TESTER — THE ENGINE, PROVED BY INVOCATION COUNT.
# Both `claude` and `copilot` are argv-recording PATH shims (s189/lib.sh).
# A claim about WHICH engine ran is worthless without the count, so every
# phase resets the counters and reports free-vs-billed for that phase alone.
# ZERO MODEL SPEND — nothing here can reach a real CLI.
# ===========================================================================
. "$(dirname "$0")/../s189/lib.sh"

jparse() { if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null; then ok "JSON parses: $2"; else bad "INVALID JSON: $2"; cat "$1" | sed 's/^/      /'; fi; }
zero()  { : >"$SPEND"; : >"$BILLABLE"; }
cnt()   { local n; n=$(grep -c "^SPAWN	$1	" "$SPEND" 2>/dev/null); printf '%s' "${n:-0}"; }
report(){ note "COUNTS → claude=$(cnt claude)  copilot=$(cnt copilot)  billed(--model)=$(billable)"; }

# --- FULL-ARGV shims, replacing lib.sh's counters in place ------------------
# lib.sh records `--model` yes/no; the brief wants the ARGV, so every
# invocation is written out whole. Same SPEND/BILLABLE format, same paths.
ARGV="$WORK/argv.log"; : >"$ARGV"
for e in claude copilot; do
cat >"$SHIM/$e" <<WORKER
#!/usr/bin/env bash
_mdl=no
for a in "\$@"; do case "\$a" in --model|-m|--model=*) _mdl=yes ;; esac; done
printf 'SPAWN\t$e\tmodel=\$_mdl\trole=\${LCARS_WORKER_ROLE:-?}\n' >> "$SPEND"
printf '%s\t%s\t%s\n' "$e" "\${LCARS_WORKER_ROLE:-?}" "\$*" >> "$ARGV"
[ "\$_mdl" = yes ] && printf 'BILLABLE\t$e\n' >> "$BILLABLE"
case " \$* " in *" --version "*|*" -v "*) echo "0.0.0-s196-fake"; exit 0 ;; esac
exit 0
WORKER
chmod +x "$SHIM/$e"
done

DATE="${S196_DATE:-20260909}"
A="$(laptop A)"; C="$(laptop C)"
reset_laptop "$A"; reset_laptop "$C"
lcars_config "$A"
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

hdr "PHASE 1 — mission filed on copilot, this clone's config.json says claude"
mkprd "$WORK/pe.md" "S196 engine — filed on copilot" "The mission's engine must win over the clone's config."
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T13:00:00Z bash "$FILE_SH" --prd "$WORK/pe.md" --engine copilot ) >"$WORK/fe.out" 2>&1
MID="$(ls "$A/.git/lcars/missions" | head -1)"
MD="$A/.git/lcars/missions/$MID"
note "mission: $MID"
WB="$(st_get "$MD/state.json" workerBin)"
[ "$WB" = copilot ] && ok "state.json records workerBin=copilot" || bad "workerBin='$WB' — expected copilot"
ISSUE="$(st_raw "$MD/state.json" githubIssue)"; note "issue #$ISSUE"
# the AMBIENT repo default, deliberately disagreeing
python3 - "$A/.git/lcars/config.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["workerBin"]="claude"; json.dump(d, open(p,"w"), indent=2)
PY
jparse "$A/.git/lcars/config.json" "config.json with workerBin=claude"
note "config workerBin = $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("workerBin"))' "$A/.git/lcars/config.json")"

zero
( cd "$A" && bash "$RUN_SH" research --mission "$MID" ) >"$WORK/run1.out" 2>&1
note "run research rc=$?"
grep -i "worker:" "$WORK/run1.out" | sed 's/^/    /' | head -3
report
C1=$(cnt copilot); K1=$(cnt claude); B1=$(billable)
[ "$C1" -ge 1 ] && ok "the FREE engine (copilot) ran: $C1 invocation(s)" || bad "copilot ran $C1 times"
[ "$K1" -eq 0 ] && ok "the BILLED engine (claude) ran 0 times" || bad "claude ran $K1 times — SILENT ENGINE SWITCH"
[ "$B1" -eq 0 ] && ok "billed(--model) invocations: 0" || bad "billed invocations: $B1"
grep -q "worker: copilot" "$WORK/run1.out" && ok "the provenance line names copilot" || note "no 'worker: copilot' line in this output"
jparse "$MD/state.json" "mission after a real stage spawn"

hdr "PHASE 1b — \$LCARS_WORKER_BIN still outranks the mission (the deliberate operator act)"
zero
( cd "$A" && LCARS_WORKER_BIN=claude bash "$RUN_SH" research --mission "$MID" ) >"$WORK/run1b.out" 2>&1
report
[ "$(cnt claude)" -ge 1 ] && ok "env override reaches claude" || bad "env override did not reach claude"
[ "$(cnt copilot)" -eq 0 ] && ok "copilot did not run under the env override" || bad "copilot also ran"

hdr "PHASE 1c — the argv the free engine was actually spawned with"
note "$(wc -l <"$ARGV" | tr -d ' ') recorded invocations; --model carried by $(grep -c -- '--model' "$ARGV" 2>/dev/null || echo 0)"
sed 's/^/    /' "$ARGV" | cut -c1-200 | head -8

hdr "PHASE 2 — adopt on a machine WITHOUT copilot: NON-INTERACTIVE must fail loudly"
# A SECOND copilot mission, left AT ALIGN — phase 1 drove the first one to
# research, and adopt legitimately refuses a mid-pipeline mission.
mkprd "$WORK/pe2.md" "S196 engine — the handoff mission" "This one is adopted, not driven."
( cd "$A" && LCARS_DATE=$DATE LCARS_NOW=2026-09-09T13:30:00Z bash "$FILE_SH" --prd "$WORK/pe2.md" --engine copilot ) >"$WORK/fe2.out" 2>&1
MID2="$(ls "$A/.git/lcars/missions" | grep -v "^$MID$" | head -1)"
MD2="$A/.git/lcars/missions/$MID2"
ISSUE2="$(st_raw "$MD2/state.json" githubIssue)"
note "handoff mission: $MID2  issue #$ISSUE2  workerBin=$(st_get "$MD2/state.json" workerBin)"
[ "$(st_get "$MD2/state.json" stage)" = align ] && ok "it sits at align (a portable end)" || bad "stage is $(st_get "$MD2/state.json" stage)"
# `claude` only on PATH. Nothing here can reach the real copilot binary.
ONLY_CLAUDE="$WORK/only-claude"; mkdir -p "$ONLY_CLAUDE"
cp "$SHIM/claude" "$ONLY_CLAUDE/claude"
# /opt/homebrew/bin holds a REAL copilot, so it cannot be on this PATH. Only the
# tools the verb genuinely needs are linked in — `gh` is the only one that is not
# already under /usr/bin.
TOOLS="$WORK/tools"; mkdir -p "$TOOLS"; ln -sf "$GH_REAL" "$TOOLS/gh"
BASEPATH="$ONLY_CLAUDE:$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"
command -v copilot >/dev/null 2>&1 && note "copilot IS on the outer PATH ($(command -v copilot)) — the drive's PATH excludes it"
( PATH="$BASEPATH"; hash -r; command -v copilot >/dev/null 2>&1 ) && bad "copilot still reachable on the drive PATH" || ok "copilot is genuinely ABSENT on the drive PATH"
( PATH="$BASEPATH"; hash -r; command -v claude >/dev/null 2>&1 ) && ok "claude IS present on the drive PATH" || bad "claude missing too"

[ -d "$C/.git/lcars" ] && bad "laptop C is not cold" || ok "laptop C is cold"
zero
( cd "$C" && PATH="$BASEPATH" LCARS_GH_BIN="$LCARS_GH_BIN" bash "$ADOPT_SH" "$ISSUE2" </dev/null ) >"$WORK/adopt-ni.out" 2>&1
NIRC=$?
note "adopt (non-interactive) rc=$NIRC"; sed 's/^/    /' "$WORK/adopt-ni.out"
[ "$NIRC" -ne 0 ] && ok "non-interactive adopt REFUSED" || bad "non-interactive adopt succeeded — it must not"
grep -qi "will NOT switch a mission's engine in silence" "$WORK/adopt-ni.out" && ok "it says WHY (no silent switch)" || bad "the refusal does not explain the silent-switch danger"
grep -qi "copilot" "$WORK/adopt-ni.out" && ok "it names the engine the mission wants" || bad "it does not name copilot"
[ -d "$C/.git/lcars/missions" ] && [ -n "$(ls "$C/.git/lcars/missions" 2>/dev/null)" ] \
  && bad "the refusal LEFT A MISSION BEHIND: $(ls "$C/.git/lcars/missions")" || ok "nothing was created"
report
[ "$(spawns)" -eq 0 ] && ok "no engine was invoked at all during the refusal" || bad "$(spawns) engine invocations during a refusal"

hdr "PHASE 3 — adopt ASKS on a real pty, and RECORDS the conversion"
zero
rm -rf "$C/.git/lcars"
ASKOUT="$WORK/adopt-ask.txt"
printf 'claude\n' | script -q "$ASKOUT" /bin/bash -c \
  "cd '$C' && PATH='$BASEPATH' LCARS_GH_BIN='$LCARS_GH_BIN' bash '$ADOPT_SH' '$ISSUE2'" >/dev/null 2>&1
ASKRC=$?
note "adopt (pty) rc=$ASKRC"
sed 's/^/    /' "$ASKOUT" | head -30
cp "$ASKOUT" "$S189_HOME/s196-adopt-ask.txt"
grep -qi "which engine should drive this mission here" "$ASKOUT" && ok "adopt ASKED which engine takes over" || bad "no engine prompt on a real pty"
grep -qi "NOT installed on this machine" "$ASKOUT" && ok "it says the mission's engine is not here" || bad "it does not say copilot is missing"
CMD="$C/.git/lcars/missions/$MID2"
[ -f "$CMD/state.json" ] && ok "mission adopted after the answer" || bad "no mission at $CMD"
jparse "$CMD/state.json" "adopted mission on C"
NWB="$(st_get "$CMD/state.json" workerBin)"
[ "$NWB" = claude ] && ok "the CONVERTED engine is RECORDED (workerBin=claude)" || bad "workerBin='$NWB' — the conversion was not recorded"
ESRC="$(st_get "$CMD/state.json" engineSource)"
note "engineSource = '$ESRC'"
[ "$ESRC" = adopt-converted ] && ok "engineSource records HOW it was chosen" || bad "engineSource='$ESRC'"
head -3 "$CMD/state.json" | grep -q '"workerBin"\|"engineSource"\|"engineResolved"' && ok "the new keys sit at the TOP of the object (house rule)" || note "new keys are not in the first 3 lines: $(head -3 "$CMD/state.json" | tr '\n' ' ')"

hdr "PHASE 3b — the converted engine WINS THE NEXT RUN (counted)"
# The clone adopt seeded has its own config.json; make it DISAGREE, then run.
python3 - "$C/.git/lcars/config.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["workerBin"]="copilot"; json.dump(d, open(p,"w"), indent=2)
PY
jparse "$C/.git/lcars/config.json" "C config with a DISAGREEING workerBin=copilot"
zero
BOTH="$SHIM:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
( cd "$C" && PATH="$BOTH" LCARS_GH_BIN="$LCARS_GH_BIN" bash "$RUN_SH" research --mission "$MID2" ) >"$WORK/run3.out" 2>&1
grep -i "worker:" "$WORK/run3.out" | sed 's/^/    /' | head -3
report
[ "$(cnt claude)" -ge 1 ] && ok "the RECORDED engine (claude) ran: $(cnt claude)" || bad "claude ran $(cnt claude) times"
[ "$(cnt copilot)" -eq 0 ] && ok "config.json's copilot did NOT overrule the recorded choice" || bad "copilot ran $(cnt copilot) times — config beat the recorded engine"

hdr "PHASE 4 — --engine names an engine this machine does not have"
zero
rm -rf "$C/.git/lcars"
( cd "$C" && PATH="$BASEPATH" LCARS_GH_BIN="$LCARS_GH_BIN" bash "$ADOPT_SH" --issue "$ISSUE2" --engine copilot </dev/null ) >"$WORK/adopt-badengine.out" 2>&1
BRC=$?
note "rc=$BRC"; sed 's/^/    /' "$WORK/adopt-badengine.out"
[ "$BRC" -ne 0 ] && ok "refused" || bad "accepted an engine that is not installed"
[ -n "$(ls "$C/.git/lcars/missions" 2>/dev/null)" ] && bad "left a mission behind" || ok "nothing was created"

hdr "SPEND (whole drive)"; note "worker spawns: $(spawns)  billable: $(billable)  gh calls: $(gh_calls)"
printf '\n%d passed, %d failed\nWORK=%s\nMID=%s ISSUE=#%s  MID2=%s ISSUE2=#%s\n' "$PASS" "$FAIL" "$WORK" "$MID" "$ISSUE" "$MID2" "$ISSUE2"
[ "$FAIL" -eq 0 ]
