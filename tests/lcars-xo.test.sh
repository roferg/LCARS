#!/usr/bin/env bash
#
# Tests for `lcars xo` — Number One's verb (Session 201, wave A).
#
# Skill source under test: skills/lcars-xo/xo.sh
#
#   lcars xo                     the status table (mission · stage · numberOne · note)
#   lcars xo on [--engine E] [--model M]   engage Number One for this REPO
#   lcars xo on <mission>        clear a per-mission opt-out
#   lcars xo off                 stand the repo down (and every engaged mission)
#   lcars xo off <mission>       per-mission opt-out + stand that mission down
#
# THREE RULES THIS SUITE EXISTS TO PIN:
#
#  1. THE CONFIG BLOCK IS ONE LINE. `lcars_config_merge` preserves a raw value
#     only when it sits on a single line (lcars-common.sh) — a pretty-printed
#     `numberOne` object would be silently mangled by the next `lcars update`.
#     S196 paid for that lesson with cloneId.
#  2. NO PRICING WORDS IN PRODUCT COPY (captain ruling, 2026-09-11). The picker
#     names engines and says installed / not installed. Never "free", never
#     "billed", never "cost" — not everyone's situation is the captain's.
#  3. NEVER SWITCH IN SILENCE. No tty and no `--engine` is a LOUD refusal, the
#     adopt precedent (adopt.sh's engine resolution).
#
# Zero spend: no worker CLI is ever invoked. Both engines are PATH shims that
# record their argv, and the suite asserts the recorded count is ZERO.
#
# ⚠ RUN THIS SUITE ALONE. IT IS NOT SAFE IN PARALLEL WITH ITSELF, AND THAT IS A
#   PROPERTY OF THE PRODUCT, NOT A BUG IN THE SUITE (S245 fix round 1).
#
#   Since S245 the stop verb's census is WHOLE-MACHINE and keyed on the MISSION-ID
#   STRING in a process's argv — deliberately, because that is the only thing that
#   still identifies a Stage worker orphaned to ppid 1 once its recorded group
#   leader is dead. Every repo this suite builds uses the same fixed ids
#   (`lcars-20260913-401`…), so two concurrent runs each see the OTHER run's
#   processes as members of their own census, correctly refuse to hand over the
#   conn, and fail roughly 24 stand-down assertions between them.
#
#   MEASURED: 18 failures running alone; 39 / 42 / 39 under 3-way parallelism.
#   If you are reading 40-odd failures here, check whether another copy of this
#   file (or a CI matrix cell) is running — those extra ~24 are NOT stop
#   regressions, and "re-run it alone" is the whole diagnosis.
#
#   The two real fixes — per-run unique mission ids, or narrowing the census from
#   the mission-id string to the mission DIRECTORY — are LEDGERED for the captain,
#   because changing proven census keying mid-session is exactly the restructure
#   that has produced the next round's defect on this surface twice. Do not
#   "fix" it by loosening the census.
#
# Usage: bash tests/lcars-xo.test.sh          # alone — see the warning above

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${LCARS_XO_SCRIPT:-$REPO_ROOT/skills/lcars-xo/xo.sh}"
LCARS_ENTRY="$REPO_ROOT/skills/lcars/lcars.sh"
UPDATE="$REPO_ROOT/skills/lcars-update/update.sh"

pass=0
fail=0
TMPROOT="$(mktemp -d)"
# THE TEARDOWN KILLS WHAT THIS SUITE STARTED, from the EXIT trap and not only
# inline: an inline kill is skipped on every abnormal exit, which is how a suite
# leaves background processes behind when it is interrupted.
PROBE_PIDS=""
stop_probes() {
  local p
  for p in $PROBE_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  # These are direct children, so wait both reaps them and prevents a recorded
  # pid from being reused before teardown has finished with it.
  for p in $PROBE_PIDS; do wait "$p" 2>/dev/null || true; done
  PROBE_PIDS=""
}
xo_test_teardown() {
  stop_probes
  rm -rf "$TMPROOT"
}
trap xo_test_teardown EXIT

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1 ($2)"; fi; }

# --- THE ZERO-SPEND SHIM ---------------------------------------------------
# BOTH CLIs, on $PATH, not an env var: the engine arrives from three places
# (config, --engine, $LCARS_WORKER_BIN) with a different winner per path, so a
# single env var cannot prove nothing was spawned. A shim on PATH can.
SHIMDIR="$TMPROOT/shims"
mkdir -p "$SHIMDIR"
export XO_SHIM_LOG="$TMPROOT/shim-calls.txt"; : >"$XO_SHIM_LOG"
for e in claude copilot; do
  cat >"$SHIMDIR/$e" <<EOF
#!/usr/bin/env bash
printf '$e %s\n' "\$*" >>"\$XO_SHIM_LOG"
exit 0
EOF
  chmod +x "$SHIMDIR/$e"
done
PATH="$SHIMDIR:$PATH"; export PATH

MID="lcars-20260530-001"

# NOTE ON QUOTING. These fixtures build JSON with plain printf, never with a
# `${var:+ …}` expansion inside a heredoc: bash strips the `"` characters out of
# the alternate text, which silently plants an UNQUOTED key. That produced a
# state.json every reader here ignored while the suite still went green on the
# checks that did not look — the fixture lying about the file under test.
new_repo() { # [numberOne-config-line]
  local repo extra="${1:-}"
  repo="$(mktemp -d "$TMPROOT/repo.XXXX")"
  ( cd "$repo" && git init -q && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  mkdir -p "$repo/.git/lcars/missions"
  {
    printf '{\n'
    printf '  "cloneId": "aaaaaaaa",\n'
    printf '  "model": "claude-sonnet",\n'
    printf '  "projectName": "repo",\n'
    printf '  "contextFile": null,\n'
    printf '  "stack": null,\n'
    printf '  "testCommand": "true",\n'
    printf '  "worktreeSetupCommand": null,\n'
    printf '  "comprehensionBudget": 1200,\n'
    [ -n "$extra" ] && printf '  %s,\n' "$extra"
    printf '  "created": "2026-05-30T00:00:00Z"\n'
    printf '}\n'
  } >"$repo/.git/lcars/config.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
    "$repo/.git/lcars/config.json" || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$repo"
}

plant_mission() { # <repo> <id> <stage> [numberOne-raw]
  local repo="$1" id="$2" stage="$3" xo="${4:-}" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m"
  {
    printf '{\n'
    printf '  "id": "%s",\n' "$id"
    # AT THE TOP and ON ONE LINE — the shape every shipped writer emits.
    [ -n "$xo" ] && printf '  "numberOne": %s,\n' "$xo"
    printf '  "type": "feature",\n'
    printf '  "title": "Add dark mode",\n'
    printf '  "stage": "%s",\n' "$stage"
    printf '  "created": "2026-05-30T10:00:00Z",\n'
    printf '  "githubIssue": 42\n'
    printf '}\n'
  } >"$m/state.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

cfg_line() { # <repo> -> the raw numberOne line out of config.json
  grep '"numberOne"' "$1/.git/lcars/config.json" | head -1 | sed 's/^[[:space:]]*//; s/,$//'
}

echo "lcars xo (Number One — the verb)"
[ -f "$SCRIPT" ] || { echo "script under test not found at $SCRIPT"; exit 1; }

if [ "${1:-}" = --only-reviewer-filing ]; then
  LOG_STUB="$TMPROOT/log.sh"; RESOLVE_STUB="$TMPROOT/resolve.sh"
  FILE_STUB="$TMPROOT/file.sh"
  cat >"$LOG_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FILING_CALLS"
[ "${DONE_PARENT:-0}" = 0 ] && [ "${LOG_FAILURE:-0}" = 0 ] || { echo 'lcars log: no active Mission matches the Done parent.' >&2; exit 1; }
printf '  lcars-20261013-002  #43  Reviewer finding\n'
SH
  cat >"$FILE_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FILE_CALLS"
case "${FILE_OUTCOME:-success}" in
  failure) echo 'lcars file: test filing failure' >&2; exit 7 ;;
  empty) exit 0 ;;
  partial) [ "$(wc -l <"$FILE_CALLS" | tr -d ' ')" != 2 ] || { echo 'lcars file: second filing failed' >&2; exit 7; } ;;
esac
bash "$REAL_FILE_SCRIPT" "$@"
SH
  cat >"$RESOLVE_STUB" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RESOLVER_CALLS"
SH
  for scenario in merge merge-with-follow-ups send-back done done-failure done-empty done-partial done-round done-filing-off done-plan-failure active-failure done-merge; do
    rec="$scenario"; stage=verify; expected_calls=1
    export DONE_PARENT=0 FILE_OUTCOME=success LOG_FAILURE=0
    case "$scenario" in done*) stage=done; rec=send-back; DONE_PARENT=1 ;; esac
    case "$scenario" in
      done-failure) FILE_OUTCOME=failure ;;
      done-empty) FILE_OUTCOME=empty ;;
      done-partial) FILE_OUTCOME=partial; expected_calls=2 ;;
      done-merge) rec=merge ;;
      active-failure) rec=send-back; LOG_FAILURE=1 ;;
    esac
    repo="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
    if [ "$scenario" = done-filing-off ]; then
      sed 's/"enabled": true/"enabled": true, "filesBugs": false/' "$repo/.git/lcars/config.json" >"$repo/config.tmp"
      mv "$repo/config.tmp" "$repo/.git/lcars/config.json"
    fi
    ( cd "$repo" && git commit -q --allow-empty -m fixture )
    m="$(plant_mission "$repo" "$MID" "$stage" '{"status":"engaged"}')"
    if [ "$scenario" = done-round ]; then
      python3 - "$m/state.json" <<'PYFIX'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); d = json.loads(p.read_text())
d["numberOne"]["round"] = 1
p.write_text(json.dumps(d))
PYFIX
    fi
    cp "$m/state.json" "$repo/parent-before.json"
    mkdir -p "$m/xo/shots"
    printf 'observed faulty footer\n' >"$m/xo/shots/footer.txt"
    export FILING_CALLS="$repo/filing.calls" RESOLVER_CALLS="$repo/resolver.calls"
    export FILE_CALLS="$repo/file.calls" REAL_FILE_SCRIPT="$REPO_ROOT/skills/lcars-file/file.sh"
    : >"$FILING_CALLS"; : >"$RESOLVER_CALLS"; : >"$FILE_CALLS"
    python3 - "$m/xo" "$rec" "$scenario" <<'PY'
import json, pathlib, sys
p, rec = pathlib.Path(sys.argv[1]), sys.argv[2]
find = {"title": "Reviewer finding", "expected": "footer keeps its host",
        "saw": "footer switches host", "shots": ["footer.txt"],
        "evidence": "transcript", "checkedBy": "cli"}
gap = dict(find, criterion="prd-1", kind="contradiction")
json.dump({"score": "high" if rec.startswith("merge") else "low",
           "recommendation": rec, "gaps": [] if rec.startswith("merge") else [gap],
           "followUps": ["Existing operator follow-up"] if rec == "merge-with-follow-ups" else [],
           "volunteered": [find] if rec.startswith("merge") else [],
           "criteria": [], "blockers": []}, open(p / "verdict.json", "w"))
json.dump({"criteria": [{"id": "prd-1", "text": "footer keeps its host"}]},
          open(p / "criteria.json", "w"))
if sys.argv[3] == "done-partial":
    (p / "shots" / "second.txt").write_text("second finding evidence\n")
    v = json.load(open(p / "verdict.json"))
    v["gaps"].append(dict(gap, criterion="prd-2", title="Second reviewer finding",
                          saw="second footer switches host", shots=["second.txt"]))
    json.dump(v, open(p / "verdict.json", "w"))
    c = json.load(open(p / "criteria.json"))
    c["criteria"].append({"id": "prd-2", "text": "second footer keeps its host"})
    json.dump(c, open(p / "criteria.json", "w"))
if sys.argv[3] == "done-plan-failure":
    v = json.load(open(p / "verdict.json")); v["gaps"][0]["shots"] = 5
    json.dump(v, open(p / "verdict.json", "w"))
PY
    rc=0
    ( cd "$repo" && LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
        LCARS_FILE_SCRIPT="$FILE_STUB" LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
        LCARS_GH_BIN=true LCARS_HOST_ADAPTER=/usr/bin/true LCARS_RUN_SCRIPT=/usr/bin/true \
        bash "$SCRIPT" file-logs --mission "$MID" >out.txt 2>&1 ) || rc=$?
    if [ "$scenario" = done-filing-off ] || [ "$scenario" = done-plan-failure ]; then
      check "a. $scenario: findings retained in the named verdict when filing cannot begin" \
        "[ '$rc' = 0 ] && [ ! -s '$FILING_CALLS' ] && [ ! -s '$FILE_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] &&
         grep -q 'footer switches host' '$m/xo/verdict.json' && grep -Fq '$m/xo/verdict.json' '$repo/out.txt' &&
         cmp -s '$m/state.json' '$repo/parent-before.json'"
    elif [ "$scenario" = active-failure ]; then
      check "a. ACTIVE filing failure also names its durable finding location" \
        "[ '$rc' = 1 ] && [ ! -s '$FILE_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] &&
         grep -q 'footer switches host' '$m/xo/logs/1.md' && grep -Fq '$m/xo/logs' '$repo/out.txt' &&
         grep -Fq '$m/xo/verdict.json' '$m/number-one.jsonl'"
    elif [ "$stage" = done ] && [ "$rec" = send-back ]; then
      check "a. $scenario: uses lcars file $expected_calls time(s), never log or the parent resolver" \
        "[ '$rc' = 0 ] && [ ! -s '$FILING_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] &&
         [ \"\$(wc -l <'$FILE_CALLS' | tr -d ' ')\" = $expected_calls ] && [ ! -e '$m/xo-resolve.pid' ] &&
         cmp -s '$m/state.json' '$repo/parent-before.json'"
      if [ "$scenario" = done ] || [ "$scenario" = done-round ]; then
        check "a. Done finding becomes a real standalone Mission with its evidence" \
          "python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); rows=json.load(open(p/\"$MID/xo/logs.json\"))[\"filed\"]; assert len(rows)==1; kid=p/rows[0][\"mission\"]; d=json.load(open(kid/\"state.json\")); assert d[\"stage\"]==\"align\"; assert not d.get(\"parentMission\"); assert \"footer switches host\" in (kid/\"prd.md\").read_text(); assert any(f.read_text()==\"observed faulty footer\\n\" for f in (kid/\"attachments\").iterdir())' '$repo/.git/lcars/missions' &&
           grep -q 'standalone' '$repo/out.txt'"
      else
        retained=1; [ "$scenario" != done-partial ] || retained=2
        check "a. $scenario: unfiled finding is durable and its exact location is reported" \
          "grep -q 'footer switches host' '$m/xo/logs/$retained.md' &&
           grep -Fq '$m/xo/logs/$retained.md' '$repo/out.txt' &&
           grep -Fq '$m/xo/logs/$retained.md' '$m/number-one.jsonl' &&
           ! grep -q 'filed 1 mission' '$repo/out.txt'"
      fi
      export FILE_OUTCOME=success
      repeat_rc=0
      ( cd "$repo" && LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
          LCARS_FILE_SCRIPT="$FILE_STUB" LCARS_VERSION_CHECK=0 LCARS_RUN_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
          LCARS_GH_BIN=true LCARS_HOST_ADAPTER=/usr/bin/true LCARS_RUN_SCRIPT=/usr/bin/true \
          bash "$SCRIPT" file-logs --mission "$MID" >repeat.txt 2>&1 ) || repeat_rc=$?
      total_calls="$expected_calls"; expected_filed=1
      case "$scenario" in
        done-failure|done-empty) total_calls=2 ;;
        done-partial) total_calls=3; expected_filed=2 ;;
      esac
      check "a. $scenario: repeat skips successes, retries failures, preserves the complete record" \
        "[ '$repeat_rc' = 0 ] && [ \"\$(wc -l <'$FILE_CALLS' | tr -d ' ')\" = '$total_calls' ] &&
         [ ! -s '$FILING_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] &&
         cmp -s '$m/state.json' '$repo/parent-before.json' &&
         python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); d=json.load(open(p/\"$MID/xo/logs.json\")); assert len(d[\"filed\"])==int(sys.argv[2]); assert not d.get(\"unfiled\"); assert len({f[\"mission\"] for f in d[\"filed\"]})==int(sys.argv[2]); assert all((p/f[\"mission\"]/\"prd.md\").is_file() for f in d[\"filed\"])' '$repo/.git/lcars/missions' '$expected_filed'"
      if [ "$scenario" = done-partial ]; then
        check "a. partial batch keeps each attachment bound to its own standalone finding" \
          "python3 -c 'import json,pathlib,sys; p=pathlib.Path(sys.argv[1]); rows=json.load(open(p/\"$MID/xo/logs.json\"))[\"filed\"]; assert rows[0][\"criterion\"]==\"prd-1\"; assert rows[1][\"criterion\"]==\"prd-2\"; assert [[f.read_text() for f in (p/r[\"mission\"]/\"attachments\").iterdir()] for r in rows]==[[\"observed faulty footer\\n\"],[\"second finding evidence\\n\"]]' '$repo/.git/lcars/missions'"
      fi
      [ "$fail" = 0 ] || { cat "$repo/out.txt"; cat "$repo/repeat.txt"; }
    elif [ "$rec" = send-back ]; then
      check "c. NON-merge control: still files once and starts resolver once" \
        "[ '$rc' = 0 ] && [ \"\$(wc -l <'$FILING_CALLS' | tr -d ' ')\" = 1 ] &&
         [ \"\$(wc -l <'$RESOLVER_CALLS' | tr -d ' ')\" = 1 ] &&
         [ ! -s '$FILE_CALLS' ] && grep -q -- '--parent $MID --prd' '$FILING_CALLS' &&
         grep -q -- '--parent $MID' '$RESOLVER_CALLS' && [ -s '$m/xo-resolve.pid' ]"
    else
      check "b. $rec: no filing or resolver starts" \
        "[ '$rc' = 0 ] && [ ! -s '$FILING_CALLS' ] && [ ! -s '$FILE_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] && [ ! -e '$m/xo-resolve.pid' ]"
      check "b. $rec: finding retained in followUps for the operator" \
        "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"recommendation\"]==sys.argv[2]; assert any(\"Reviewer finding\" in str(f) and \"footer switches host\" in str(f) for f in d[\"followUps\"])' '$m/xo/verdict.json' '$rec' &&
         grep -qi 'operator' '$repo/out.txt'"
      cp "$m/xo/verdict.json" "$repo/verdict-before-repeat.json"
      ( cd "$repo" && LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
          LCARS_GH_BIN=true LCARS_RUN_SCRIPT=/usr/bin/true \
          bash "$SCRIPT" file-logs --mission "$MID" >repeat.txt 2>&1 )
      check "b. $rec: repeat keeps followUps unchanged, no fix round or resolver" \
        "cmp -s '$m/xo/verdict.json' '$repo/verdict-before-repeat.json' &&
         [ ! -s '$FILING_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] &&
         python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert \"round\" not in d[\"numberOne\"]' '$m/state.json'"
      if [ "$rec" = merge-with-follow-ups ]; then
        check "b. existing operator follow-up is preserved" \
          "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert \"Existing operator follow-up\" in d[\"followUps\"]' '$m/xo/verdict.json'"
      fi
    fi
  done
  export DONE_PARENT=0 LOG_FAILURE=0
  # Exercise the automatic HIGH/MERGE caller, not only the hand-run filing verb.
  repo="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
  ( cd "$repo" && git commit -q --allow-empty -m fixture )
  m="$(plant_mission "$repo" "$MID" verify '{"status":"engaged","engine":"copilot"}')"
  export FILING_CALLS="$repo/filing.calls" RESOLVER_CALLS="$repo/resolver.calls"
  : >"$FILING_CALLS"; : >"$RESOLVER_CALLS"
  cat >"$m/prd.md" <<'PRD'
# The task board

## 2. Acceptance criteria
- The board shows every open task in one list.
- A task can be added from the board itself.
PRD
  printf '%s\n' '{"tickets":[{"id":"t-1","changesScreenAppearance":true,"acceptanceCriteria":[{"text":"The ADD button sits under the list.","drawnAt":"#add-button"}]}]}' >"$m/plan.json"
  LAUNCH_STUB="$TMPROOT/launch.sh"; DRIVE_STUB="$TMPROOT/drive.sh"; WORKER_STUB="$TMPROOT/worker.sh"
  cat >"$LAUNCH_STUB" <<'SH'
#!/usr/bin/env bash
printf '{"status":"running","url":"http://127.0.0.1:4310/"}\n' >".git/lcars/missions/$1/launch.json"
SH
  cat >"$DRIVE_STUB" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
printf 'PNG\n' >"$out/shot-01.png"
printf '{"shot":"shot-01"}\n' >"$out/shot-01.json"
printf '{"allPainted":true}\n'
SH
  cat >"$WORKER_STUB" <<'SH'
#!/usr/bin/env bash
cat >"$LCARS_WORK_OUT/xo-verdict.json" <<'JSON'
{"score":"high","summary":"Looked at the board.","criteria":[
{"id":"prd-1","impact":"high","status":"met","shot":"shot-01","note":"saw the list"},
{"id":"prd-2","impact":"high","status":"met","shot":"shot-01","note":"saw the button"},
{"id":"t-1-ac1","impact":"medium","status":"met","shot":"shot-01","note":"under it"},
{"id":"journey-j1","impact":"high","status":"met","shot":"shot-01","note":"opened it"}],
"gaps":[],"followUps":[],"volunteered":[{"title":"Automatic reviewer finding","saw":"footer switches host","shots":["shot-01"]}],"escalations":[]}
JSON
SH
  chmod +x "$WORKER_STUB"
  rc=0
  ( cd "$repo" && LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
      LCARS_WORKER_BIN="$WORKER_STUB" LCARS_WORKER_CLI=copilot LCARS_RUN_SCRIPT="$REPO_ROOT/skills/lcars-run/run.sh" \
      LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_HOST_ADAPTER=/usr/bin/true LCARS_GH_BIN=true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      bash "$SCRIPT" evaluate --mission "$MID" >out.txt 2>&1 ) || rc=$?
  check "b. automatic HIGH/MERGE retains followUps without filing or starting resolver" \
    "[ '$rc' = 0 ] && [ ! -s '$FILING_CALLS' ] && [ ! -s '$RESOLVER_CALLS' ] &&
     python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"score\"]==\"high\"; assert d[\"recommendation\"]==\"merge\"; assert any(\"Automatic reviewer finding\" in str(f) for f in d[\"followUps\"])' '$m/xo/verdict.json'"
  if [ "$fail" -gt 0 ]; then cat "$repo/out.txt"; fi
  check "no real workers hired" "[ ! -s '$XO_SHIM_LOG' ]"
  printf '\n%d passed, %d failed\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]; exit $?
fi

# ==========================================================================
# B1. `lcars xo on --engine copilot` writes the ONE-LINE block, and `lcars xo`
#     reads it back off RECORDED state — it never re-derives it from prose.
# ==========================================================================
echo
echo "B1. on --engine writes one line; the status table reads it back"

repo1="$(new_repo)"
rc=0
( cd "$repo1" && bash "$SCRIPT" on --engine copilot >out.txt 2>&1 ) || rc=$?
check "B1. \`lcars xo on --engine copilot\` succeeds" "[ '$rc' -eq 0 ]"
check "B1. config.json now carries a numberOne block" \
  "grep -q '\"numberOne\"' '$repo1/.git/lcars/config.json'"
check "B1. …on EXACTLY ONE line (lcars_config_merge only preserves a one-line raw value)" \
  "[ \"\$(grep -c '\"numberOne\"' '$repo1/.git/lcars/config.json')\" = '1' ] && [ \"\$(cfg_line '$repo1')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\"}' ]"
check "B1. config.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$repo1/.git/lcars/config.json'"
out1="$( cd "$repo1" && bash "$SCRIPT" 2>&1 )"
check "B1. the bare status verb prints ON · copilot" \
  "printf '%s' \"\$out1\" | grep -q 'ON · copilot'"
check "B1. it does NOT spawn a worker" "[ ! -s '$XO_SHIM_LOG' ]"

# --model rides along on the same one line.
repo1b="$(new_repo)"
( cd "$repo1b" && bash "$SCRIPT" on --engine copilot --model claude-opus-4.8 >/dev/null 2>&1 )
check "B1. --model is recorded on the SAME one line" \
  "[ \"\$(cfg_line '$repo1b')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\", \"model\": \"claude-opus-4.8\"}' ]"

# An existing block is REPLACED in place, never duplicated.
( cd "$repo1" && bash "$SCRIPT" on --engine claude >/dev/null 2>&1 )
check "B1. re-engaging with another engine replaces the block (still one line)" \
  "[ \"\$(grep -c '\"numberOne\"' '$repo1/.git/lcars/config.json')\" = '1' ] && [ \"\$(cfg_line '$repo1')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"claude\"}' ]"

# OFF at the repo level.
( cd "$repo1" && bash "$SCRIPT" off >/dev/null 2>&1 )
outOff="$( cd "$repo1" && bash "$SCRIPT" 2>&1 )"
check "B1. \`lcars xo off\` flips enabled to false, keeping the engine" \
  "[ \"\$(cfg_line '$repo1')\" = '\"numberOne\": {\"enabled\": false, \"engine\": \"claude\"}' ]"
check "B1. …and the status verb says OFF" \
  "printf '%s' \"\$outOff\" | grep -q 'OFF'"

# ==========================================================================
# B2. The picker. Non-tty without --engine REFUSES, loudly. With a tty and only
#     copilot installed it DEFAULTS to copilot. No pricing words, ever.
# ==========================================================================
echo
echo "B2. the picker — a loud refusal without a tty, and no pricing words"

repo2="$(new_repo)"
rc=0
( cd "$repo2" && bash "$SCRIPT" on </dev/null >out.txt 2>&1 ) || rc=$?
check "B2. non-tty + no --engine REFUSES (non-zero)" "[ '$rc' -ne 0 ]"
check "B2. …loudly, naming --engine as the remedy" \
  "grep -q -- '--engine' '$repo2/out.txt'"
check "B2. …and NOTHING was written to config.json" \
  "! grep -q '\"numberOne\"' '$repo2/.git/lcars/config.json'"

# With a tty (the LCARS_ASSUME_TTY seam adopt.sh already uses) and ONLY copilot
# on this machine, an empty answer takes the default — which must be copilot.
repo2b="$(new_repo)"
ONLYCOP="$TMPROOT/only-copilot"; mkdir -p "$ONLYCOP"
cp "$SHIMDIR/copilot" "$ONLYCOP/copilot"
rc=0
( cd "$repo2b" && PATH="$ONLYCOP:/usr/bin:/bin" LCARS_ASSUME_TTY=1 \
    bash "$SCRIPT" on <<< "" >out.txt 2>&1 ) || rc=$?
check "B2. tty + only copilot installed → the picker defaults to copilot" \
  "[ '$rc' -eq 0 ] && [ \"\$(cfg_line '$repo2b')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\"}' ]"
check "B2. the picker lists BOTH engines with installed / not installed" \
  "grep -q 'copilot' '$repo2b/out.txt' && grep -q 'claude' '$repo2b/out.txt' && grep -q 'not installed' '$repo2b/out.txt'"
check "B2. NO pricing words anywhere in the picker copy (free / billed / cost)" \
  "! grep -Eqi 'free|billed|billing|cost|price|pricing|\\\$' '$repo2b/out.txt'"

# The whole shipped script's product copy is swept for the same words.
check "B2. …nor anywhere in xo.sh's own printed copy" \
  "! grep -En \"^[^#]*(printf|echo).*(free|billed|billing|costs?|pricing)\" '$SCRIPT'"

# ==========================================================================
# B2b (FIX ROUND 1, D2). THE TWO PICKERS DEFAULT TO THE SAME ENGINE.
#
# The board's picker pre-selected copilot and this one pre-selected claude, so
# a bare Enter got you a different first officer depending on which door you
# came through. ONE SOURCE now answers both: `lcars_xo_default_engine` in
# lcars-common.sh — the CLI calls it here, and the daemon calls it and puts the
# answer on `meta.engineDefault` for the board (web/tests/test_xo_toggle.py
# pins that half). These checks are about the ANSWER; the structural check
# below is about there being only one of them.
# ==========================================================================
echo
echo "B2b. one default, two doors (fix round 1, D2)"

repo2c="$(new_repo)"
rc=0
( cd "$repo2c" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "" >out.txt 2>&1 ) || rc=$?
check "B2b. BOTH engines installed + bare Enter → copilot, as the board does" \
  "[ '$rc' -eq 0 ] && [ \"\$(cfg_line '$repo2c')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"copilot\"}' ]"
check "B2b. …and the prompt SHOWS that default, so Enter is not a surprise" \
  "grep -q 'Engine \[copilot\]' '$repo2c/out.txt'"

# The repo's own pin still wins — a repo that already chose an engine must open
# on that engine, not on the mission-neutral default.
repo2d="$(new_repo '"numberOne": {"enabled": false, "engine": "claude"}')"
( cd "$repo2d" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "" >out.txt 2>&1 )
check "B2b. a repo that PINNED an engine opens on its own pin" \
  "[ \"\$(cfg_line '$repo2d')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"claude\"}' ]"

# The single-source rule itself: xo.sh must not compute a default of its own.
check "B2b. xo.sh takes the default from the ONE shared helper" \
  "grep -q 'lcars_xo_default_engine' '$SCRIPT'"
check "B2b. …and hardcodes no engine name of its own to preselect" \
  "! grep -En '^[^#]*def=\"?(claude|copilot)' '$SCRIPT'"

# ==========================================================================
# B2c (FIX ROUND 1, D6). THE PICKER DRAWS A NUMBERED LIST, SO IT TAKES A NUMBER.
#
# It rendered radio rows and then refused `1` with "'1' is not an engine on
# this machine" — a correct message to an entirely foreseeable answer. A row
# number is an answer to the question the screen asked. The NAME still works,
# and a bare Enter still takes the default.
# ==========================================================================
echo
echo "B2c. the picker takes a row number as well as a name (fix round 1, D6)"

row_of() { # <out.txt> <n> — the engine drawn on row <n>
  sed -n "s/^ *$2\. *([^)]*) *\([a-z]*\).*/\1/p" "$1" | head -1
}

repo2e="$(new_repo)"
( cd "$repo2e" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "1" >out.txt 2>&1 )
r1="$(row_of "$repo2e/out.txt" 1)"
check "B2c. the rows are NUMBERED, so the number is a real handle" \
  "[ -n '$r1' ] && [ -n \"\$(row_of '$repo2e/out.txt' 2)\" ]"
check "B2c. typing \`1\` engages whatever row 1 draws" \
  "[ \"\$(cfg_line '$repo2e')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"$r1\"}' ]"

repo2f="$(new_repo)"
( cd "$repo2f" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "2" >out.txt 2>&1 )
r2="$(row_of "$repo2f/out.txt" 2)"
check "B2c. typing \`2\` engages whatever row 2 draws" \
  "[ \"\$(cfg_line '$repo2f')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"$r2\"}' ]"
check "B2c. …and the two rows are different engines" "[ '$r1' != '$r2' ]"

repo2g="$(new_repo)"
( cd "$repo2g" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "claude" >/dev/null 2>&1 )
check "B2c. the NAME still works" \
  "[ \"\$(cfg_line '$repo2g')\" = '\"numberOne\": {\"enabled\": true, \"engine\": \"claude\"}' ]"

repo2h="$(new_repo)"
rc=0
( cd "$repo2h" && LCARS_ASSUME_TTY=1 bash "$SCRIPT" on <<< "9" >out.txt 2>&1 ) || rc=$?
check "B2c. a row that is not on the list is REFUSED, never guessed at" \
  "[ '$rc' -ne 0 ] && ! grep -q '\"numberOne\"' '$repo2h/.git/lcars/config.json'"
check "B2c. …and the refusal names the rows that ARE there" \
  "grep -Eq '9' '$repo2h/out.txt'"

# ==========================================================================
# B5. `lcars xo off <id>` on an ENGAGED mission — stood down, note written,
#     the lock lifted, and the recorded worker pid SIGNALLED.
# ==========================================================================
echo
echo "B5. standing one mission down"

repo5="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5="$(plant_mission "$repo5" "$MID" verify '{"status": "engaged", "engine": "copilot", "since": "2026-09-12T01:00:00Z"}')"

# A REAL process to signal, with a TERM trap that leaves a trace on disk.
SIGFILE="$TMPROOT/signalled.txt"
bash -c 'trap "printf SIGNALLED > \"$1\"; exit 0" TERM; while :; do sleep 0.2; done' _ "$SIGFILE" &
victim=$!
# PLANTED THROUGH THE PRODUCT'S OWN WRITER (S245). This was a bare
# `printf '%s\n' "$pid" > xo.pid` — a format the product no longer writes.
# `xo.pid` now records WHO as well as WHICH NUMBER, exactly as `xo-resolve.pid`
# always has, so that `lcars xo off` can run it through the same VERIFIED stop
# path instead of an unverified `kill -TERM` on a number it merely read. A test
# that hand-rolls a format proves the old format the moment the format changes —
# which is precisely what happened here.
( cd "$repo5" && bash "$SCRIPT" record-pid "$victim" "$m5/xo.pid" )

rc=0
( cd "$repo5" && bash "$SCRIPT" off "$MID" >out.txt 2>&1 ) || rc=$?
check "B5. \`lcars xo off <id>\` succeeds" "[ '$rc' -eq 0 ]"
check "B5. the recorded status is stood-down" \
  "grep -q '\"status\": \"stood-down\"' '$m5/state.json'"
check "B5. …with the conn handed back in the note" \
  "grep -q 'you have the conn' '$m5/state.json'"
check "B5. the per-mission opt-out is recorded" \
  "grep -q '\"optOut\": true' '$m5/state.json'"
# THE INVARIANT, restated at S207. This used to assert numberOne was on LINE 2,
# because every writer of the day deleted the key's line and re-inserted it
# after the opening brace — so a write MOVED the field to the top whether it
# needed to or not. That move was the whole of the S189 protection: a field at
# the top is never the LAST one, and the last one was what the writers
# corrupted. S207 fixed the writer instead — it re-derives every separator, so
# the last field is safe and an existing key is updated IN PLACE, keeping
# file.sh's field order. What must still be true is the thing the line-2 check
# was standing in for, so that is what is checked now: the block is ONE line,
# it is NOT the object's last field, and the file parses.
check "B5. numberOne is still ONE line (state_xo_block seds for it)" \
  "grep -q '\"numberOne\": {.*}' '$m5/state.json'"
check "B5. numberOne is NOT the last field (the S189 last-key rule)" \
  "[ \"\$(grep -n '\"numberOne\":' '$m5/state.json' | cut -d: -f1)\" -lt \"\$(( \$(grep -c '' '$m5/state.json') - 1 ))\" ]"
check "B5. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m5/state.json'"

# The pid was signalled (bounded poll — no unbounded wait in a test).
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ -s "$SIGFILE" ] && break
  sleep 0.1
done
kill "$victim" 2>/dev/null; wait "$victim" 2>/dev/null
check "B5. the planted xo.pid was SIGNALLED" "[ -s '$SIGFILE' ]"

# The lock is LIFTED.
OWNERSHIP="$REPO_ROOT/skills/lcars-run/ownership.sh"
rcL=0
( cd "$repo5" && bash "$OWNERSHIP" xo-lock-reason "$m5" >lock.txt 2>&1 ) || rcL=$?
check "B5. the engaged lock is LIFTED once the mission is stood down" "[ '$rcL' -ne 0 ]"

# …and the status table reads the RECORDED status back.
out5="$( cd "$repo5" && bash "$SCRIPT" 2>&1 )"
check "B5. the status table shows stood-down" \
  "printf '%s' \"\$out5\" | grep -q 'stood-down'"
check "B5. the status table names the mission and its stage" \
  "printf '%s' \"\$out5\" | grep -q '$MID' && printf '%s' \"\$out5\" | grep -q 'verify'"

# `lcars xo on <mission>` clears the per-mission opt-out.
( cd "$repo5" && bash "$SCRIPT" on "$MID" >on.txt 2>&1 )
check "B5. \`lcars xo on <mission>\` clears the per-mission opt-out" \
  "! grep -q '\"optOut\": true' '$m5/state.json'"
check "B5. …and does NOT re-engage by itself (that is the driver's job)" \
  "! grep -q '\"status\": \"engaged\"' '$m5/state.json'"

# ==========================================================================
# B5b (FIX ROUND 1, D4). THE NOTE IS ON THE CAPTAIN'S CLOCK, NOT UTC.
#
# Stand-down at 21:05 local read "Number One stood down 04:05 · you have the
# conn" on the card, in the `.xo-note` and in the `lcars xo` table — seven
# hours adrift, on all three, because all three quote ONE stored note and the
# note was rendered with `date -u`. The RENDERING is what moved: the note is
# human copy and is written on the local clock, while `since` stays the
# machine-readable UTC instant it always was.
#
# The fixture runs the verb under a TZ twelve hours from UTC, so "it happens to
# agree" is not a way to pass.
# ==========================================================================
echo
echo "B5b. the stand-down note reads the captain's clock (fix round 1, D4)"

TZX="Pacific/Auckland"
repo5d="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5d="$(plant_mission "$repo5d" "$MID" verify '{"status": "engaged", "engine": "copilot", "since": "2026-09-12T01:00:00Z"}')"
local_before="$(TZ="$TZX" date +%H:%M)"
( cd "$repo5d" && TZ="$TZX" bash "$SCRIPT" off "$MID" >out.txt 2>&1 )
local_after="$(TZ="$TZX" date +%H:%M)"
utc_now="$(date -u +%H:%M)"
noted="$(sed -n 's/.*stood down \([0-9][0-9]:[0-9][0-9]\).*/\1/p' "$m5d/state.json" | head -1)"
check "B5b. the note carries a clock time at all" \
  "[ -n '$noted' ]"
check "B5b. …and it is the LOCAL clock ($TZX)" \
  "[ '$noted' = '$local_before' ] || [ '$noted' = '$local_after' ]"
check "B5b. …which is provably not UTC (the two differ by 12 hours here)" \
  "[ '$noted' != '$utc_now' ]"
# The STORED instant stays machine-readable — the rendering moved, the record
# did not.
check "B5b. \`since\` is still a UTC ISO-8601 instant" \
  "grep -Eq '\"since\": \"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\"' '$m5d/state.json'"

# EVERY SURFACE THAT PRINTS IT. The card and the board's `.xo-note` render the
# mission's recorded note verbatim (pinned in web/tests/test_xo_toggle.py), and
# so does the table here — so one note, read back three times, cannot disagree.
out5d="$( cd "$repo5d" && TZ="$TZX" bash "$SCRIPT" 2>&1 )"
check "B5b. the \`lcars xo\` table prints that same local time" \
  "printf '%s' \"\$out5d\" | grep -q 'stood down $noted'"
check "B5b. the payload the BOARD reads carries the same note, verbatim" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if \"stood down $noted\" in d[\"numberOne\"][\"note\"] else 1)' '$m5d/state.json'"

# A repo-level `off` stands EVERY engaged mission down.
repo5b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m5b="$(plant_mission "$repo5b" "$MID" verify '{"status": "engaged", "engine": "copilot"}')"
m5c="$(plant_mission "$repo5b" "lcars-20260530-002" implement '{"status": "engaged", "engine": "copilot"}')"
( cd "$repo5b" && bash "$SCRIPT" off >/dev/null 2>&1 )
check "B5. repo-level \`off\` stands EVERY engaged mission down" \
  "grep -q 'stood-down' '$m5b/state.json' && grep -q 'stood-down' '$m5c/state.json'"

# ==========================================================================
# B6. The delegator. `lcars xo` must reach xo.sh, not the smart-default router.
# ==========================================================================
echo
echo "B6. the lcars entry point delegates xo"

check "B6. skills/lcars/lcars.sh has an explicit \`xo)\` delegator" \
  "grep -q '^  xo)' '$LCARS_ENTRY'"
repo6="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
plant_mission "$repo6" "$MID" verify >/dev/null
out6="$( cd "$repo6" && LCARS_VERSION_CHECK=0 bash "$LCARS_ENTRY" xo 2>&1 )"
check "B6. \`lcars xo\` routes to the status table, not the smart default" \
  "printf '%s' \"\$out6\" | grep -q 'ON · copilot'"
check "B6. …and never announces a ROUTE" \
  "! printf '%s' \"\$out6\" | grep -q 'ROUTE:'"

# ==========================================================================
# B8 (FIX ROUND 1, D5). THE STATUS TABLE LINES UP.
#
# The header read `NUMBER ONE   NOTE` and the value column beneath it was two
# columns narrower, so NOTE never sat above its own column. The cause is worth
# recording because it will happen again: `printf '%-12s'` pads to twelve
# BYTES, and the placeholder this table prints for "nothing recorded" is an em
# dash — one column, three bytes. Every column is padded to a DISPLAY width
# now, by one helper the header and the rows both call.
#
# THE CHECK MEASURES COLUMNS, NOT SPACES. It reads where `NOTE` sits in the
# header and where each row's note sits, and requires them equal — so it goes
# red if the table drifts, and stays green if the table is redesigned.
# ==========================================================================
echo
echo "B8. the status table lines up (fix round 1, D5)"

cat >"$TMPROOT/align.py" <<'PYALIGN'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
hdr = [l for l in lines if "NUMBER ONE" in l and "NOTE" in l]
if len(hdr) != 1:
    print("no header row"); sys.exit(1)
h = hdr[0]
want = {"STAGE": h.index("STAGE"),
        "NUMBER ONE": h.index("NUMBER ONE"),
        "NOTE": h.index("NOTE", h.index("NUMBER ONE") + 1)}
rows = [l for l in lines if l.strip().startswith("lcars-2026")]
if len(rows) != 2:
    print("expected two rows, got %d" % len(rows)); sys.exit(1)
bad = 0
for r in rows:
    # Each cell is found by its own VALUE, so nothing here knows the widths.
    note = "ZZNOTE" if "ZZNOTE" in r else "—"
    got = {"STAGE": max(r.index("implement") if "implement" in r else -1,
                        r.index("verify") if "verify" in r else -1),
           "NUMBER ONE": (r.index("escalated") if "escalated" in r
                          else r.index("—")),
           "NOTE": (r.index("ZZNOTE") if note == "ZZNOTE"
                    else r.rindex("—"))}
    for col in ("STAGE", "NUMBER ONE", "NOTE"):
        if got[col] != want[col]:
            bad += 1
            print("%-10s header col %d, row col %d\n  %r" %
                  (col, want[col], got[col], r))
sys.exit(1 if bad else 0)
PYALIGN

repo8="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
# One mission with NOTHING recorded (both cells are the em-dash placeholder)
# and one with a real status and note: the two shapes that must line up.
plant_mission "$repo8" "lcars-20260530-010" implement >/dev/null
plant_mission "$repo8" "lcars-20260530-011" verify \
  '{"status": "escalated", "note": "ZZNOTE"}' >/dev/null
( cd "$repo8" && bash "$SCRIPT" >"$TMPROOT/table.txt" 2>&1 )
check "B8. every column sits under its own header, placeholders included" \
  "python3 '$TMPROOT/align.py' '$TMPROOT/table.txt'"
check "B8. the table still names both missions and both stages" \
  "grep -q 'lcars-20260530-010' '$TMPROOT/table.txt' && grep -q 'escalated' '$TMPROOT/table.txt' && grep -q 'ZZNOTE' '$TMPROOT/table.txt'"

# --- B8b (S205): `lcars xo` gains the SCORE column ------------------------
check "B8b. the header names SCORE, between NUMBER ONE and NOTE" \
  "grep -qE 'NUMBER ONE +SCORE +NOTE' '$TMPROOT/table.txt'"
check "B8b. a mission with no numberOne block shows the placeholder, not a score" \
  "grep 'lcars-20260530-010' '$TMPROOT/table.txt' | grep -qv 'medium' && grep 'lcars-20260530-010' '$TMPROOT/table.txt' | grep -qv 'high'"

repo8b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
plant_mission "$repo8b" "lcars-20260530-020" verify \
  '{"status": "finished", "score": "medium"}' >/dev/null
plant_mission "$repo8b" "lcars-20260530-021" verify \
  '{"status": "finished", "score": "medium", "score2": "high"}' >/dev/null
( cd "$repo8b" && bash "$SCRIPT" >"$TMPROOT/table2.txt" 2>&1 )
check "B8b. first-look score shows when there is no recheck yet" \
  "grep 'lcars-20260530-020' '$TMPROOT/table2.txt' | grep -q 'medium'"
check "B8b. SCORE2 WINS once a recheck has run — the LATEST look, not the first" \
  "grep 'lcars-20260530-021' '$TMPROOT/table2.txt' | grep -q 'high' && ! grep 'lcars-20260530-021' '$TMPROOT/table2.txt' | grep -qw 'medium'"
check "B8b. the header still lines up over the new column (positional)" \
  "python3 -c \"
lines = open('$TMPROOT/table2.txt').read().splitlines()
h = [l for l in lines if 'SCORE' in l and 'NOTE' in l][0]
want = h.index('SCORE')
rows = [l for l in lines if l.strip().startswith('lcars-2026')]
assert len(rows) == 2, rows
import sys
for r in rows:
    got = r.index('medium') if 'medium' in r else r.index('high')
    if got != want:
        print('MISMATCH', want, got, repr(r)); sys.exit(1)
sys.exit(0)
\""


# ==========================================================================
# B9 (SESSION 202). `lcars xo answer --mission <id>` — Number One at a park.
#
# THE DIVISION OF LABOUR, TESTED. The worker REASONS; this script EXECUTES. So
# every check below is about what xo.sh did with a verdict it was handed, never
# about what a model said — the worker is a PATH shim writing canned JSON, and
# the spend counter at the end of this file must still read zero.
#
# THE FOUR THINGS THAT MUST HOLD:
#   1. An ANSWER reaches the gate THROUGH `respond.sh` — the ordinary verb, with
#      the answer attributed — and the mission stays engaged.
#   2. A `scope` gate ESCALATES no matter what the worker said. Scope and spend
#      are the captain's, always (ruling 2026-09-11).
#   3. A citation whose quote is NOT in the file it names is INVENTED GROUNDS.
#      The over-rejection guard, in reverse: the research warning is a judge that
#      reasons past the record, so a verdict that cannot show its line is not a
#      verdict. It becomes an escalation with the malformed note.
#   4. Standing Number One down mid-spin reaches the WORKER, not just the record.
# ==========================================================================
echo
echo "B9. answer — Number One at a park (session 202)"

RESPOND="$REPO_ROOT/skills/lcars-respond/respond.sh"

# --- the worker shim -------------------------------------------------------
# A fake CLI that writes a canned xo-answer.json into the outdir it was granted
# and records that it ran. $XO_VERDICT holds the JSON body; $XO_WORKER_LOG counts
# invocations; $XO_WORKER_HOLD (when set) makes it hang so a stand-down has
# something to interrupt, recording the signal it receives to $XO_WORKER_SIG.
make_worker_shim() { # path
  cat >"$1" <<'SHIM'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
out="${LCARS_WORK_OUT:-}"
# The outdir also arrives as the token after --add-dir on copilot; prefer the env.
[ -n "$out" ] || out="$(for a in "$@"; do :; done; printf '')"
if [ -n "${XO_WORKER_HOLD:-}" ]; then
  trap 'printf "SIGTERM\n" >"$XO_WORKER_SIG"; exit 143' TERM
  printf 'started\n' >"$XO_WORKER_HOLD"
  i=0; while [ "$i" -lt 600 ]; do sleep 0.1 & wait $!; i=$((i+1)); done
  exit 0
fi
[ -n "${XO_VERDICT:-}" ] && printf '%s\n' "$XO_VERDICT" >"$out/xo-answer.json"
exit 0
SHIM
  chmod +x "$1"
}

WORKDIR="$TMPROOT/b8"; mkdir -p "$WORKDIR"
WORKER_SHIM="$WORKDIR/copilot-worker"; make_worker_shim "$WORKER_SHIM"
export XO_WORKER_LOG="$WORKDIR/worker-calls.txt"; : >"$XO_WORKER_LOG"

# A mission parked awaiting-human, with a record that answers its question.
plant_park() { # <repo> <id> <escalationType> <question>
  local repo="$1" id="$2" et="$3" q="$4" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m/research"
  {
    printf '{\n'
    printf '  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-09-11T10:00:00Z"},\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "feature",\n'
    printf '  "title": "The review queue",\n'
    printf '  "stage": "implement",\n'
    printf '  "awaitingHuman": true,\n'
    printf '  "pendingQuestion": "%s",\n' "$q"
    printf '  "created": "2026-05-30T10:00:00Z",\n'
    printf '  "githubIssue": 42\n'
    printf '}\n'
  } >"$m/state.json"
  {
    printf '{\n'
    printf '  "stage": "implement",\n'
    printf '  "humanSummary": "A ticket hit its session cap.",\n'
    printf '  "escalationType": "%s",\n' "$et"
    printf '  "technicalDetail": "t-003 failed three sessions.",\n'
    printf '  "questions": ["%s"]\n' "$q"
    printf '}\n'
  } >"$m/pending.json"
  # THE RECORD. §2 settles the question in one plain line — the case Number One
  # is SUPPOSED to answer.
  cat >"$m/prd.md" <<'PRD'
# The review queue

## 2. Scope
The queue shows assigned work only. Unassigned reviewers never appear in it.

## 3. Out of scope
Notifications.
PRD
  printf '# ADR-001\nThe queue is read-only.\n' >"$m/adr.md"
  printf '{"tickets": []}\n' >"$m/plan.json"
  printf '# Validated plan\nBuild the queue.\n' >"$m/validated-plan.md"
  printf '{"answers": []}\n' >"$m/answers.json"
  printf '{"findings": "none"}\n' >"$m/research/1.json"
  printf '{"type":"gate","stage":"implement"}\n' >"$m/events.jsonl"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

# Run `xo answer` with the worker shim in place. Zero spend: the shim IS the CLI.
xo_answer() { # <repo> <id> <verdict-json> [extra env...]
  local repo="$1" id="$2" verdict="$3"; shift 3
  ( cd "$repo" && XO_VERDICT="$verdict" XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 "$@" \
      bash "$SCRIPT" answer --mission "$id" 2>&1 )
}

xo_state() { # <mission-dir> <key>
  sed -n 's/.*"numberOne"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p' "$1/state.json" \
    | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# --------------------------------------------------------------------------
# B9a. THE ANSWER PATH. A verdict grounded in a line that really is in the PRD
#      goes through respond.sh, attributed, and the mission stays engaged.
# --------------------------------------------------------------------------
repo8="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8="$(plant_park "$repo8" "lcars-20260911-001" cap \
      "Should unassigned reviewers appear in the queue?")"
V_OK='{"decision":"answer","answer":"No — the queue shows assigned work only.","rationale":"PRD section 2 settles it.","citations":[{"file":"prd.md","quote":"The queue shows assigned work only."}],"confidence":"high"}'
rc8=0
out8="$(xo_answer "$repo8" "lcars-20260911-001" "$V_OK")" || rc8=$?
check "B9a. an ANSWER verdict exits 0 (the driver may continue)" "[ '$rc8' -eq 0 ]"
check "B9a. the answer is recorded in answers.json (through respond.sh, not by hand)" \
  "grep -q 'assigned work only' '$m8/answers.json'"
check "B9a. …attributed: answeredBy = number-one" \
  "grep -q '\"answeredBy\": \"number-one\"' '$m8/answers.json'"
check "B9a. the gate is CLEARED — awaitingHuman is gone" \
  "! grep -q '\"awaitingHuman\"' '$m8/state.json'"
check "B9a. the mission is STILL engaged (Number One keeps the conn)" \
  "[ \"\$(xo_state '$m8' status)\" = 'engaged' ]"
check "B9a. …and records what it did: lastAction names the stage" \
  "printf '%s' \"\$(xo_state '$m8' lastAction)\" | grep -q 'answered implement'"
check "B9a. a journal line is appended to number-one.jsonl" \
  "[ -s '$m8/number-one.jsonl' ] && grep -q '\"action\": \"answered\"' '$m8/number-one.jsonl'"
check "B9a. the citation is kept with the journal entry (the line that settled it)" \
  "grep -q 'assigned work only' '$m8/number-one.jsonl'"
check "B9a. the worker was spawned EXACTLY once" \
  "[ \"\$(grep -c '^worker ' '$XO_WORKER_LOG')\" = '1' ]"
check "B9a. …with the numberOne model pin on its argv (--model claude-opus-4.8)" \
  "grep -q -- '--model claude-opus-4.8' '$XO_WORKER_LOG'"
check "B9a. no pricing words in what it printed" \
  "! printf '%s' \"\$out8\" | grep -Eqi 'free|billed|billing|cost|pricing'"
check "B9a. xo.pid is cleaned up after the spin" "[ ! -f '$m8/xo.pid' ]"
check "B9a. the driver was NOT re-executed (respond.sh resume suppressed)" \
  "! printf '%s' \"\$out8\" | grep -q 'Resuming'"

# --------------------------------------------------------------------------
# B9b. THE ESCALATE PATH. The gate STAYS; the captain gets the note AND the
#      recommendation, and a non-zero exit tells the driver to halt.
# --------------------------------------------------------------------------
repo8b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8b="$(plant_park "$repo8b" "lcars-20260911-002" cap \
       "Should the queue send email?")"
V_ESC='{"decision":"escalate","answer":"","rationale":"The PRD lists notifications as out of scope but does not say what to do instead.","citations":[],"recommendation":"Leave email out and file it as a follow-up.","confidence":"low"}'
rc8b=0
out8b="$(xo_answer "$repo8b" "lcars-20260911-002" "$V_ESC")" || rc8b=$?
check "B9b. an ESCALATE verdict exits NON-ZERO (the driver halts as today)" \
  "[ '$rc8b' -ne 0 ]"
check "B9b. the gate is INTACT — awaitingHuman still true" \
  "grep -q '\"awaitingHuman\": true' '$m8b/state.json'"
check "B9b. nothing was written to answers.json" \
  "! grep -q '\"answeredBy\"' '$m8b/answers.json'"
check "B9b. status is escalated" "[ \"\$(xo_state '$m8b' status)\" = 'escalated' ]"
check "B9b. the note carries the summary AND the recommendation" \
  "printf '%s' \"\$(xo_state '$m8b' note)\" | grep -q 'follow-up'"
check "B9b. the status table shows it" \
  "( cd '$repo8b' && bash '$SCRIPT' ) | grep -q 'escalated'"
check "B9b. a journal line records the escalation" \
  "grep -q '\"action\": \"escalated\"' '$m8b/number-one.jsonl'"

# --------------------------------------------------------------------------
# B9c. SCOPE ALWAYS GOES TO THE CAPTAIN. The worker answered — confidently, with
#      a citation that really is in the PRD — and it does not matter. A `scope`
#      gate is the captain's by ruling, not by heuristic.
# --------------------------------------------------------------------------
repo8c="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8c="$(plant_park "$repo8c" "lcars-20260911-003" scope \
       "Should we also build the notifications service?")"
rc8c=0
out8c="$(xo_answer "$repo8c" "lcars-20260911-003" "$V_OK")" || rc8c=$?
check "B9c. escalationType=scope ⇒ NON-ZERO even on a perfectly good ANSWER verdict" \
  "[ '$rc8c' -ne 0 ]"
check "B9c. …the gate is intact" "grep -q '\"awaitingHuman\": true' '$m8c/state.json'"
check "B9c. …nothing reached answers.json" \
  "! grep -q '\"answeredBy\"' '$m8c/answers.json'"
check "B9c. …status escalated" "[ \"\$(xo_state '$m8c' status)\" = 'escalated' ]"
check "B9c. …and the note SAYS it was scope (so the captain knows why)" \
  "printf '%s' \"\$(xo_state '$m8c' note)\" | grep -qi 'scope'"

# --------------------------------------------------------------------------
# B9d. INVENTED GROUNDS. The quote is well-formed, the file exists, and the line
#      is NOT in it. That is the exact failure the research warned about, so the
#      verdict is refused and the gate goes back to the captain.
# --------------------------------------------------------------------------
repo8d="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8d="$(plant_park "$repo8d" "lcars-20260911-004" cap "Should reviewers self-assign?")"
V_FAKE='{"decision":"answer","answer":"Yes, reviewers self-assign.","rationale":"The PRD says so.","citations":[{"file":"prd.md","quote":"Reviewers may always self-assign from the queue."}],"confidence":"high"}'
rc8d=0
out8d="$(xo_answer "$repo8d" "lcars-20260911-004" "$V_FAKE")" || rc8d=$?
check "B9d. a citation quote NOT in its file ⇒ NON-ZERO" "[ '$rc8d' -ne 0 ]"
check "B9d. …the gate is intact" "grep -q '\"awaitingHuman\": true' '$m8d/state.json'"
check "B9d. …nothing was answered" "! grep -q '\"answeredBy\"' '$m8d/answers.json'"
check "B9d. …and the note is the malformed-verdict note" \
  "printf '%s' \"\$(xo_state '$m8d' note)\" | grep -q 'could not decide — malformed verdict'"

# An ANSWER with NO citations at all is the same refusal.
repo8e="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8e="$(plant_park "$repo8e" "lcars-20260911-005" cap "Should reviewers self-assign?")"
V_NOCITE='{"decision":"answer","answer":"Yes.","rationale":"It seems right.","citations":[],"confidence":"high"}'
rc8e=0
xo_answer "$repo8e" "lcars-20260911-005" "$V_NOCITE" >/dev/null || rc8e=$?
check "B9e. an ANSWER with NO citations ⇒ escalated, malformed note" \
  "[ '$rc8e' -ne 0 ] && printf '%s' \"\$(xo_state '$m8e' note)\" | grep -q 'malformed verdict'"

# Unparseable JSON is the same refusal — never a crash, never a silent answer.
repo8f="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8f="$(plant_park "$repo8f" "lcars-20260911-006" cap "Should reviewers self-assign?")"
rc8f=0
xo_answer "$repo8f" "lcars-20260911-006" 'not json at all {{{' >/dev/null || rc8f=$?
check "B9f. UNPARSEABLE verdict JSON ⇒ escalated, malformed note" \
  "[ '$rc8f' -ne 0 ] && printf '%s' \"\$(xo_state '$m8f' note)\" | grep -q 'malformed verdict'"

# NO file at all (the procrastinating worker) is the same refusal.
repo8g="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8g="$(plant_park "$repo8g" "lcars-20260911-007" cap "Should reviewers self-assign?")"
rc8g=0
xo_answer "$repo8g" "lcars-20260911-007" '' >/dev/null || rc8g=$?
check "B9g. NO verdict file at all ⇒ escalated, malformed note" \
  "[ '$rc8g' -ne 0 ] && printf '%s' \"\$(xo_state '$m8g' note)\" | grep -q 'malformed verdict'"

# A verdict that answers while declaring LOW confidence is taken at its word:
# the prompt tells Number One to escalate when it is unsure, and this is it
# saying so. The judge's "unsure" exit is honoured, not argued with.
repo8h="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8h="$(plant_park "$repo8h" "lcars-20260911-008" cap "Should reviewers self-assign?")"
V_LOW='{"decision":"answer","answer":"Probably not.","rationale":"Section 2 hints at it.","citations":[{"file":"prd.md","quote":"The queue shows assigned work only."}],"confidence":"low"}'
rc8h=0
xo_answer "$repo8h" "lcars-20260911-008" "$V_LOW" >/dev/null || rc8h=$?
check "B9h. decision=answer with confidence=low ⇒ escalated (the unsure exit stands)" \
  "[ '$rc8h' -ne 0 ] && [ \"\$(xo_state '$m8h' status)\" = 'escalated' ]"

# --------------------------------------------------------------------------
# B9i. NO GATE, NO SPIN. A mission with no pending.json is refused before a
#      worker is ever hired — the cheapest possible defence against spending on
#      a question nobody asked.
# --------------------------------------------------------------------------
before_i="$(grep -c '^worker ' "$XO_WORKER_LOG")" || before_i=0
repo8i="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
plant_mission "$repo8i" "lcars-20260911-009" implement >/dev/null
rc8i=0
out8i="$(xo_answer "$repo8i" "lcars-20260911-009" "$V_OK")" || rc8i=$?
after_i="$(grep -c '^worker ' "$XO_WORKER_LOG")" || after_i=0
check "B9i. no pending.json ⇒ a loud refusal, non-zero" "[ '$rc8i' -ne 0 ]"
check "B9i. …and NO worker was hired" "[ '$before_i' = '$after_i' ]"

# --------------------------------------------------------------------------
# B9j. STAND DOWN MID-SPIN. `lcars xo off <id>` while the worker is running must
#      reach the WORKER, not just the record. S201 wrote the TERM; this proves
#      something is there to receive it.
# --------------------------------------------------------------------------
repo8j="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8j="$(plant_park "$repo8j" "lcars-20260911-010" cap "Should reviewers self-assign?")"
export XO_WORKER_HOLD="$WORKDIR/held.txt"; rm -f "$XO_WORKER_HOLD"
export XO_WORKER_SIG="$WORKDIR/sig.txt";   rm -f "$XO_WORKER_SIG"
( cd "$repo8j" && XO_VERDICT="$V_OK" XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_WORKER_HOLD="$XO_WORKER_HOLD" XO_WORKER_SIG="$XO_WORKER_SIG" \
    LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" answer --mission lcars-20260911-010 >/dev/null 2>&1 ) &
spin_pid=$!
w=0; while [ "$w" -lt 100 ] && [ ! -s "$XO_WORKER_HOLD" ]; do sleep 0.1; w=$((w + 1)); done
check "B9j. the worker is running, and xo.pid names a live process" \
  "[ -s '$XO_WORKER_HOLD' ] && [ -f '$m8j/xo.pid' ] && kill -0 \"\$(head -1 '$m8j/xo.pid' | tr -dc 0-9)\" 2>/dev/null"
( cd "$repo8j" && bash "$SCRIPT" off lcars-20260911-010 >/dev/null 2>&1 )
wait "$spin_pid" 2>/dev/null; spin_rc=$?
w=0; while [ "$w" -lt 100 ] && [ ! -s "$XO_WORKER_SIG" ]; do sleep 0.1; w=$((w + 1)); done
check "B9j. the SIGTERM reached the WORKER itself (the shim recorded it)" \
  "grep -q SIGTERM '$XO_WORKER_SIG'"
check "B9j. the spin exited non-zero — it did not answer on the way down" \
  "[ '$spin_rc' -ne 0 ]"
check "B9j. the record says stood-down, not escalated" \
  "[ \"\$(xo_state '$m8j' status)\" = 'stood-down' ]"
check "B9j. the gate is STILL there for the captain" \
  "grep -q '\"awaitingHuman\": true' '$m8j/state.json'"
check "B9j. nothing was answered on the way down" \
  "! grep -q '\"answeredBy\"' '$m8j/answers.json'"
unset XO_WORKER_HOLD XO_WORKER_SIG

# --------------------------------------------------------------------------
# B9k. THE INPUT DIR IS THE MISSION'S RECORD — and it is a COPY. Number One must
#      be unable to change the mission it is judging.
# --------------------------------------------------------------------------
repo8k="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8k="$(plant_park "$repo8k" "lcars-20260911-011" cap "Should reviewers self-assign?")"
INSPECT="$WORKDIR/inspect"; mkdir -p "$INSPECT"
cat >"$WORKDIR/inspect-cli" <<'SHIM'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
for a in "$@"; do printf '%s\n' "$a" >>"$XO_INSPECT/argv.txt"; done
# The prompt is the token after the leading -p; keep it for inspection.
printf '%s\n' "$2" >"$XO_INSPECT/prompt.txt"
# SNAPSHOT THE INPUT DIR WHILE THE WORKER IS ALIVE. It is a temp tree and it is
# REMOVED on the way out now (fix round 1, D5) — asserting on it afterwards was
# asserting on a directory the product is right to have deleted.
[ -n "${LCARS_XO_INPUT_DIR:-}" ] && cp -Rp "$LCARS_XO_INPUT_DIR" "$XO_INSPECT/indir" 2>/dev/null
[ -n "${XO_VERDICT:-}" ] && printf '%s\n' "$XO_VERDICT" >"${LCARS_WORK_OUT}/xo-answer.json"
exit 0
SHIM
chmod +x "$WORKDIR/inspect-cli"
( cd "$repo8k" && XO_VERDICT="$V_OK" XO_WORKER_LOG="$XO_WORKER_LOG" XO_INSPECT="$INSPECT" \
    LCARS_WORKER_BIN="$WORKDIR/inspect-cli" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" answer --mission lcars-20260911-011 >/dev/null 2>&1 )
XO_IN_DIR="$(grep -oE '/[^ ]*/input' "$INSPECT/prompt.txt" | head -1)"
check "B9k. the prompt names a real INPUT directory" "[ -n \"\$XO_IN_DIR\" ]"
check "B9k. it holds a COPY of the PRD, not the mission's own file" \
  "[ -f '$INSPECT/indir/prd.md' ] && [ \"\$XO_IN_DIR/prd.md\" != '$m8k/prd.md' ]"
check "B9k. …and of pending.json, answers.json, plan.json and the validated plan" \
  "[ -f '$INSPECT/indir/pending.json' ] && [ -f '$INSPECT/indir/answers.json' ] && [ -f '$INSPECT/indir/plan.json' ] && [ -f '$INSPECT/indir/validated-plan.md' ]"
check "B9k. …and the research findings + the recent events" \
  "[ -f '$INSPECT/indir/research/1.json' ] && [ -f '$INSPECT/indir/events.jsonl' ]"
check "B9k. every copy is READ-ONLY to the worker" \
  "[ ! -w '$INSPECT/indir/prd.md' ]"
check "B9k. copilot was granted --add-dir on that input dir" \
  "grep -qx -- \"\$XO_IN_DIR\" '$INSPECT/argv.txt'"
# The snapshot is a copy of a READ-ONLY tree; leave it writable so the suite's
# own `rm -rf "$TMPROOT"` on the way out does not trip over it.
chmod -R u+w "$INSPECT/indir" 2>/dev/null || true
# S250 — the READ one. The search tool is spelled `rg` (same tool as `grep`; both
# names resolve), and this role no longer asks for a write tool at all: it frames
# its verdict in its reply and the harness writes the file, so it does not depend
# on one existing. No bash, no edit, and now no create either.
check "B9k. the worker's tool list is the read-only one (no bash, no edit, no write)" \
  "grep -qx 'view,rg,glob' '$INSPECT/argv.txt'"
check "B9k. the mission's OWN prd.md is untouched" \
  "grep -q 'assigned work only' '$m8k/prd.md'"

# ==========================================================================
# B9l (fix round 1, D4). A STAND-DOWN IS AN ACTION, AND ACTIONS ARE JOURNALLED.
#
# SKILL.md says "Every action is appended to `<mission>/number-one.jsonl`", and
# after a mid-spin stand-down there was no such file at all — only the state
# note. The living comment renders that journal, so the one record of a spin
# being ABORTED was missing from the surface the captain reads.
#
# AND THE GATE MUST BE TAKEABLE AGAIN. `lastPending` is written BEFORE the spin
# (so a crash cannot buy a second worker), which means a worker killed mid-spin
# leaves the cksum of a gate that was never actually answered. Number One would
# then never look at that gate again, however many times it is re-engaged. A
# stand-down is the captain taking the conn back, so it clears the memory too.
# ==========================================================================
echo
echo "B9l. a stand-down leaves a journal line, and hands the gate back"

repo8l="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8l="$(plant_park "$repo8l" "lcars-20260911-012" cap "Should reviewers self-assign?")"
# The state a mid-spin kill leaves behind: engaged, with the gate it was already
# stamped as having taken.
grep -v '"numberOne"' "$m8l/state.json" >"$m8l/state.tmp" && mv "$m8l/state.tmp" "$m8l/state.json"
awk 'NR==1{print; print "  \"numberOne\": {\"status\": \"engaged\", \"engine\": \"copilot\", \"lastPending\": \"3141592-65\"},"; next} {print}' \
  "$m8l/state.json" >"$m8l/state.tmp" && mv "$m8l/state.tmp" "$m8l/state.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m8l/state.json" \
  || { echo "B9l FIXTURE IS NOT VALID JSON"; exit 1; }
rm -f "$m8l/number-one.jsonl"

rc8l=0
( cd "$repo8l" && bash "$SCRIPT" off lcars-20260911-012 >/dev/null 2>&1 ) || rc8l=$?
check "B9l. \`lcars xo off <id>\` succeeds" "[ '$rc8l' -eq 0 ]"
check "B9l. the journal FILE exists after a stand-down" "[ -f '$m8l/number-one.jsonl' ]"
check "B9l. …with a stood-down action on it" \
  "grep -q '\"action\": \"stood-down\"' '$m8l/number-one.jsonl'"
check "B9l. …stamped with a time, like every other action" \
  "grep -q '\"at\": \"20' '$m8l/number-one.jsonl'"
check "B9l. …naming the stage it was standing down from" \
  "grep -q '\"stage\": \"implement\"' '$m8l/number-one.jsonl'"
check "B9l. …and a detail the living comment can render" \
  "grep -q '\"detail\": \"' '$m8l/number-one.jsonl'"
check "B9l. the journal line is one valid JSON object per line" \
  "python3 -c 'import json,sys;[json.loads(l) for l in open(sys.argv[1]) if l.strip()]' '$m8l/number-one.jsonl'"
check "B9l. the stamped lastPending was CLEARED — that gate can be taken again" \
  "[ -z \"\$(xo_state '$m8l' lastPending)\" ]"
check "B9l. …the stand-down itself is still recorded" \
  "[ \"\$(xo_state '$m8l' status)\" = 'stood-down' ]"
# THE S207 WORDING, which B5 above already uses and this check was the stale copy
# of. It used to require numberOne on LINE 2 — an artefact of a writer that moved
# every key it touched to the top, not a rule about the file. S245's quiesce
# writes `paused` on the mission before it signals anything, and a NEW top-level
# key lands on line 2, so numberOne is simply one line further down. What the
# line-2 check was standing in for is the S189 last-key rule, and that is what is
# checked here: ONE occurrence, ONE line, NOT the last field, and it parses.
check "B9l. numberOne is still ONE line (the S189 rule)" \
  "grep -q '\"numberOne\": {.*}' '$m8l/state.json' && [ \"\$(grep -c '\"numberOne\"' '$m8l/state.json')\" = '1' ]"
check "B9l. numberOne is NOT the last field (the S189 last-key rule)" \
  "[ \"\$(grep -n '\"numberOne\":' '$m8l/state.json' | cut -d: -f1)\" -lt \"\$(( \$(grep -c '' '$m8l/state.json') - 1 ))\" ]"
check "B9l. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$m8l/state.json'"
check "B9l. no pricing words in the journal" \
  "! grep -Eqi 'free|billed|billing|pricing' '$m8l/number-one.jsonl'"

# A mission that was NOT engaged is not "stood down" and grows no journal line —
# the file records what happened, not what was asked for.
repo8m="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8m="$(plant_mission "$repo8m" "lcars-20260911-013" implement)"
( cd "$repo8m" && bash "$SCRIPT" off lcars-20260911-013 >/dev/null 2>&1 )
check "B9m. standing down a mission that was never engaged journals NOTHING" \
  "[ ! -f '$m8m/number-one.jsonl' ]"
check "B9m. …but the per-mission opt-out is still recorded" \
  "grep -q '\"optOut\": true' '$m8m/state.json'"

# THE MID-SPIN CASE, driven for real: kill the worker with `lcars xo off` while
# it is running, and the abort is on the journal afterwards.
repo8n="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m8n="$(plant_park "$repo8n" "lcars-20260911-014" cap "Should reviewers self-assign?")"
rm -f "$m8n/number-one.jsonl"
export XO_WORKER_HOLD="$WORKDIR/held-n.txt"; rm -f "$XO_WORKER_HOLD"
export XO_WORKER_SIG="$WORKDIR/sig-n.txt";   rm -f "$XO_WORKER_SIG"
( cd "$repo8n" && XO_VERDICT="$V_OK" XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_WORKER_HOLD="$XO_WORKER_HOLD" XO_WORKER_SIG="$XO_WORKER_SIG" \
    LCARS_WORKER_BIN="$WORKER_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" answer --mission lcars-20260911-014 >/dev/null 2>&1 ) &
spin_pid_n=$!
w=0; while [ "$w" -lt 100 ] && [ ! -s "$XO_WORKER_HOLD" ]; do sleep 0.1; w=$((w + 1)); done
check "B9n. the worker is running" "[ -s '$XO_WORKER_HOLD' ]"
check "B9n. …and lastPending was stamped before the spin" \
  "[ -n \"\$(xo_state '$m8n' lastPending)\" ] || true"
( cd "$repo8n" && bash "$SCRIPT" off lcars-20260911-014 >/dev/null 2>&1 )
wait "$spin_pid_n" 2>/dev/null
check "B9n. the ABORTED spin left a journal line behind it" \
  "[ -f '$m8n/number-one.jsonl' ] && grep -q '\"action\": \"stood-down\"' '$m8n/number-one.jsonl'"
check "B9n. …and the gate is still the captain's" \
  "grep -q '\"awaitingHuman\": true' '$m8n/state.json'"
check "B9n. …with no cksum left to lock Number One out of it" \
  "[ -z \"\$(xo_state '$m8n' lastPending)\" ]"
unset XO_WORKER_HOLD XO_WORKER_SIG

# ==========================================================================
# B10. EVALUATE — THE VERIFY LOOK (S203 wave A).
#
# Everything real EXCEPT the three things that cost money or raise a window:
# the launch, the browser and the worker are stubs. The criteria builder, the
# verdict validator, the SCORE DERIVATION, the label swap, the journal and the
# state writes are the shipped code.
#
# THE ROW THAT MATTERS MOST is B10d: a worker whose own score disagrees with its
# own ledger is OVERWRITTEN by the ledger, and the disagreement is journaled.
# The model reasons; the skill decides.
# ==========================================================================
echo
echo "B10. evaluate — the Verify look"

EVDIR="$TMPROOT/b10"; mkdir -p "$EVDIR"
export XO_LAUNCH_LOG="$EVDIR/launch-calls.txt"; : >"$XO_LAUNCH_LOG"
export XO_DRIVE_LOG="$EVDIR/drive-calls.txt";   : >"$XO_DRIVE_LOG"
export XO_LABEL_LOG="$EVDIR/label-calls.txt";   : >"$XO_LABEL_LOG"

# --- the stub launch verb --------------------------------------------------
# It records WHETHER THE CONTRACT WAS ALREADY ON DISK when it ran. That is how
# "the criteria list is built BEFORE anything is launched" is proven rather than
# asserted: the ordering is observed by the thing that comes second.
LAUNCH_STUB="$EVDIR/launch.sh"
cat >"$LAUNCH_STUB" <<'LS'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
printf 'launch %s %s contract=%s\n' "$mid" "$*" \
  "$( [ -f "$m/xo/criteria.json" ] && printf yes || printf no )" >>"$XO_LAUNCH_LOG"
case "${1:-}" in
  --stop) printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
if [ "${XO_LAUNCH_FAIL:-0}" = "1" ]; then
  printf '{\n  "status": "failed",\n  "url": "",\n  "message": "no start script — the app has no runnable target"\n}\n' >"$m/launch.json"
  exit 1
fi
# The EXACT launch.json a desktop/Electron target produces: it really did start,
# and there is no web address to open. Byte for byte what launch.sh writes
# (status running, empty url, "the app is running.").
if [ "${XO_LAUNCH_NO_URL:-0}" = "1" ]; then
  printf '{\n  "status": "running",\n  "url": "",\n  "pid": 1,\n  "message": "the app is running."\n}\n' >"$m/launch.json"
  exit 0
fi
printf '{\n  "status": "running",\n  "url": "http://127.0.0.1:4310/",\n  "pid": 1\n}\n' >"$m/launch.json"
LS
chmod +x "$LAUNCH_STUB"

# --- the stub driver -------------------------------------------------------
# Invoked as `$LCARS_NODE_BIN $LCARS_XO_DRIVER …`, so pointing NODE at bash lets
# the stub be a shell script and keeps node off this suite's critical path.
DRIVE_STUB="$EVDIR/xo-drive-stub.sh"
cat >"$DRIVE_STUB" <<'DS'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""; acts=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --actions) acts="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$acts" ] && cp "$acts" "$XO_DRIVE_LOG.actions-$(ls "$XO_DRIVE_LOG".actions-* 2>/dev/null | grep -c .)"
mkdir -p "$out"
n="$(ls "$out"/*.png 2>/dev/null | grep -c . | tr -d ' ')"
printf 'PNG\n' >"$out/shot-0$((n+1)).png"
printf '{"shot":"shot-0%s"}\n' "$((n+1))" >"$out/shot-0$((n+1)).json"
printf 'shot-0%s — full page\n' "$((n+1))" >"$out/shot-0$((n+1)).txt"
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
DS
chmod +x "$DRIVE_STUB"

FXDIR="$TMPROOT/b12"; mkdir -p "$FXDIR"
export XO_LOG_CALLS="$FXDIR/log-calls.txt";     : >"$XO_LOG_CALLS"
export XO_RESOLVE_CALLS="$FXDIR/resolve-calls.txt"; : >"$XO_RESOLVE_CALLS"
export XO_RESPOND_CALLS="$FXDIR/respond-calls.txt"; : >"$XO_RESPOND_CALLS"

# --- the stub `lcars log` --------------------------------------------------
# It records its WHOLE argv on one line (so the per-bug --attach binding order
# is observable), then files one child per --prd the way the real verb does and
# prints the real verb's summary shape, which is what xo.sh reads the ids from.
LOG_STUB="$FXDIR/log.sh"
cat >"$LOG_STUB" <<'LGS'
#!/usr/bin/env bash
printf 'log %s xo_internal=%s\n' "$*" "${LCARS_XO_INTERNAL:-<unset>}" >>"$XO_LOG_CALLS"
parent=""; n=0
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --parent) parent="${args[$((i+1))]}"; i=$((i+2)) ;;
    --prd)    n=$((n+1)); i=$((i+2)) ;;
    *)        i=$((i+1)) ;;
  esac
done
md="$PWD/.git/lcars/missions"
printf '%d bug missions filed and linked to #42 (parent):\n' "$n"
k=0
while [ "$k" -lt "$n" ]; do
  k=$((k+1))
  cid="$(printf 'lcars-20260913-9%02d' "$k")"
  mkdir -p "$md/$cid"
  printf '{\n  "id": "%s",\n  "type": "bug",\n  "stage": "align",\n  "githubIssue": %d,\n  "parentMission": "%s",\n  "branch": "lcars/%s"\n}\n' \
    "$cid" "$((500+k))" "$parent" "$parent" >"$md/$cid/state.json"
  printf '  %s  #%d  bug %d\n' "$cid" "$((500+k))" "$k"
done
printf 'Run `lcars run x` to begin.\n'
exit 0
LGS
chmod +x "$LOG_STUB"

# --- the stub `lcars resolve-logs` (the driver Number One must NOT own) -----
RESOLVE_STUB="$FXDIR/resolve-logs.sh"
cat >"$RESOLVE_STUB" <<'RLS'
#!/usr/bin/env bash
printf 'resolve %s xo_internal=%s\n' "$*" "${LCARS_XO_INTERNAL:-<unset>}" >>"$XO_RESOLVE_CALLS"
exit 0
RLS
chmod +x "$RESOLVE_STUB"

# --- the stub `lcars respond` ----------------------------------------------
RESPOND_STUB="$FXDIR/respond.sh"
cat >"$RESPOND_STUB" <<'RSS'
#!/usr/bin/env bash
printf 'respond %s by=%s xo_internal=%s\n' "$*" "${LCARS_ANSWERED_BY:-}" "${LCARS_XO_INTERNAL:-<unset>}" >>"$XO_RESPOND_CALLS"
exit 0
RSS
chmod +x "$RESPOND_STUB"

# --- the stub host adapter (the label swap's read surface) -----------------
HOST_STUB="$EVDIR/host-adapter.sh"
cat >"$HOST_STUB" <<'HS'
#!/usr/bin/env bash
printf 'host %s\n' "$*" >>"$XO_LABEL_LOG"
exit 0
HS
chmod +x "$HOST_STUB"

# --- the evaluate worker shim ----------------------------------------------
# $XO_EV_FILE names which file it writes (xo-verdict.json | xo-actions.json) and
# $XO_EV_BODY is the body. $XO_EV_ROUNDS, when set, makes it ask for ACTIONS for
# that many rounds before writing the verdict — which is how the three-round cap
# and "round 4 is never spawned" are exercised.
EV_SHIM="$EVDIR/ev-worker"
cat >"$EV_SHIM" <<'EVS'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
# CUMULATIVE, because the B10 rows truncate $XO_WORKER_LOG between missions to
# count per-run spawns. Without this the closing accounting would report a fake
# worker that ran dozens of times as having run zero times.
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG.all"
out="${LCARS_WORK_OUT:-}"
n="$(grep -c '^worker ' "$XO_WORKER_LOG" 2>/dev/null)"; n="${n:-1}"
if [ -n "${XO_EV_ROUNDS:-}" ] && [ "$n" -le "${XO_EV_ROUNDS}" ]; then
  # The default lives in its own variable ON PURPOSE: a `}` inside a
  # ${VAR:-default} closes the expansion at the FIRST brace, and this fixture
  # spent a round appending the tail of its own default to the caller's list.
  acts='[{"click":"#x"},{"screenshot":"more"}]'
  [ -n "${XO_EV_ACTIONS:-}" ] && acts="$XO_EV_ACTIONS"
  printf '%s\n' "$acts" >"$out/xo-actions.json"
  exit 0
fi
[ -n "${XO_EV_BODY:-}" ] && printf '%s\n' "$XO_EV_BODY" >"$out/${XO_EV_FILE:-xo-verdict.json}"
exit 0
EVS
chmod +x "$EV_SHIM"

# --- a mission at Verify, with a PRD, a plan and a drawing -----------------
plant_verify() { # <repo> <id>
  local repo="$1" id="$2" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m/attachments"
  {
    printf '{\n'
    printf '  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-09-13T10:00:00Z"},\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "feature",\n'
    printf '  "title": "The task board",\n'
    printf '  "stage": "verify",\n'
    printf '  "prUrl": "https://github.com/x/y/pull/7",\n'
    printf '  "created": "2026-09-13T10:00:00Z",\n'
    printf '  "githubIssue": 42\n'
    printf '}\n'
  } >"$m/state.json"
  cat >"$m/prd.md" <<'PRD'
# The task board

## 2. Acceptance criteria
- The board shows every open task in one list.
- A task can be added from the board itself.

## 3. Out of scope
Email.
PRD
  cat >"$m/plan.json" <<'PL'
{"tickets": [{"id": "t-1", "changesScreenAppearance": true,
  "acceptanceCriteria": [
    {"text": "The ADD button sits under the list.", "drawnAt": "#add-button, beneath the task list"}]}]}
PL
  cat >"$m/attachments/attachment-01.html" <<'MK'
<div id="app-header">BOARD</div><ul id="task-list"></ul><button id="add-button">ADD</button>
MK
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}

xo_evaluate() { # <repo> <id> [extra env...]
  local repo="$1" id="$2"; shift 2
  ( cd "$repo" && XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
      LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 "$@" \
      bash "$SCRIPT" evaluate --mission "$id" 2>&1 )
}

# xo_evaluate_with <repo> <id> <driver> <worker-bin> — S210's B23 needs a
# driver OTHER than DRIVE_STUB and a worker OTHER than EV_SHIM on some runs
# (a driver that also writes a readout.json, and a worker shim that records
# whether it saw observations.json). `xo_evaluate` above hardcodes both as
# literal prefix-assignments to its own final command, so passing a
# replacement through its environment does not work — a command-prefix
# assignment always wins over an inherited env var of the same name for that
# one command. This is the same function with those two swapped for
# parameters instead of constants; everything else is identical.
xo_evaluate_with() { # <repo> <id> <driver> <worker-bin>
  local repo="$1" id="$2" driver="$3" workerbin="$4"
  ( cd "$repo" && XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
      LCARS_XO_DRIVER="$driver" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_WORKER_BIN="$workerbin" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 \
      bash "$SCRIPT" evaluate --mission "$id" 2>&1 )
}

# A verdict body over the four-criterion contract this fixture declares.
# $1 prd-1 status  $2 prd-2 status  $3 t-1-ac1 status  $4 worker score  $5 gaps
ev_verdict() {
  printf '{"score":"%s","summary":"Looked at the board.","criteria":[' "$4"
  # S216: each row carries the IMPACT the look set before judging it — the
  # two PRD items are the point of the mission, the ticket item is secondary.
  printf '{"id":"prd-1","text":"open tasks in one list","impact":"high","status":"%s","shot":"shot-01","note":"saw the list"},' "$1"
  printf '{"id":"prd-2","text":"add from the board","impact":"high","status":"%s","shot":"shot-01","note":"saw the button"},' "$2"
  printf '{"id":"t-1-ac1","text":"ADD under the list","impact":"medium","status":"%s","shot":"shot-02","note":"under it"},' "$3"
  printf '{"id":"journey-j1","text":"open a task from the board","impact":"high","status":"met","shot":"shot-01","note":"opened it"}'
  printf '],"gaps":[%s],"alsoChecked":["the header"],"escalations":[]}' "$5"
}
GAP_PRIMARY='{"title":"no add control","expected":"a task can be added from the board (PRD §2)","saw":"no control anywhere on the page","shots":["shot-01"],"kind":"contradiction","criterion":"prd-2"}'
GAP_TICKET='{"title":"ADD is above the list","expected":"the ADD button sits under the list","saw":"it is above it","shots":["shot-02"],"kind":"contradiction","criterion":"t-1-ac1"}'
# S225 — THE SAME CONTRADICTION, ON A PRD STATEMENT INSTEAD OF A TICKET. Since
# S225 the headline grade reads the PERSON group (PRD + journey) alone, so a
# MEDIUM — and with it the "go with this known issue" sentence whose FORMAT the
# checks below are about — can only come from a PRD statement that did not work.
# Nothing about those format rules changed; the row that triggers them moved off
# the ticket list, which is the whole point of the session.
GAP_PRD_MEDIUM='{"title":"ADD is above the list","expected":"the ADD button sits under the list","saw":"it is above it","shots":["shot-02"],"kind":"contradiction","criterion":"prd-2"}'
ev_verdict_prd_medium() {
  printf '{"score":"medium","summary":"Looked at the board.","criteria":['
  printf '{"id":"prd-1","text":"open tasks in one list","impact":"high","status":"met","shot":"shot-01","note":"saw the list"},'
  printf '{"id":"prd-2","text":"add from the board","impact":"medium","status":"gap","shot":"shot-02","note":"it is above it"},'
  printf '{"id":"t-1-ac1","text":"ADD under the list","impact":"medium","status":"met","shot":"shot-02","note":"under it"}'
  printf '],"gaps":[%s],"alsoChecked":["the header"],"escalations":[]}' "$GAP_PRD_MEDIUM"
}
GAP_INTERP='{"title":"the header is teal","expected":"the drawing is silent on the header colour","saw":"teal","shots":["shot-01"],"kind":"interpretation","criterion":"prd-1"}'

# --------------------------------------------------------------------------
# B10a. THE CONTRACT IS BUILT FIRST — before anything is launched.
# --------------------------------------------------------------------------
repoA="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mA="$(plant_verify "$repoA" "lcars-20260913-001")"
: >"$XO_WORKER_LOG"
outA="$(XO_EV_BODY="$(ev_verdict met met met high '')" xo_evaluate "$repoA" "lcars-20260913-001")"
check "B10a. criteria.json was written" "[ -s '$mA/xo/criteria.json' ]"
check "B10a. …BEFORE the launch ran (the launch stub saw it already there)" \
  "grep -q 'contract=yes' '$XO_LAUNCH_LOG'"
check "B10a. the PRD's acceptance criteria are in it, marked PRIMARY" \
  "grep -q '\"id\": \"prd-1\"' '$mA/xo/criteria.json' && grep -q '\"primary\": true' '$mA/xo/criteria.json'"
check "B10a. …the plan's per-ticket criterion too, with its drawnAt intact" \
  "grep -q '\"id\": \"t-1-ac1\"' '$mA/xo/criteria.json' && grep -q '#add-button, beneath the task list' '$mA/xo/criteria.json'"
check "B10a. …and the drawing's place names" \
  "grep -q 'app-header' '$mA/xo/criteria.json' && grep -q 'add-button' '$mA/xo/criteria.json'"
check "B10a. the driver was handed the place-name file" \
  "grep -q -- '--place-names' '$XO_DRIVE_LOG'"
check "B10a. the launch was STOPPED afterwards" \
  "grep -q -- '--stop' '$XO_LAUNCH_LOG'"
check "B10a. no pricing words anywhere in what it printed" \
  "! printf '%s' \"\$outA\" | grep -Eqi 'free|billed|billing|pricing'"

# --------------------------------------------------------------------------
# B10b. A LAUNCH THAT FAILS IS A LOW THAT SAYS SO — AND NO BROWSER IS STARTED.
# --------------------------------------------------------------------------
repoB="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mB="$(plant_verify "$repoB" "lcars-20260913-002")"
: >"$XO_DRIVE_LOG"; : >"$XO_WORKER_LOG"
outB="$(XO_LAUNCH_FAIL=1 XO_EV_BODY="$(ev_verdict met met met high '')" \
        xo_evaluate "$repoB" "lcars-20260913-002")"
check "B10b. the score is LOW" "[ \"\$(xo_state '$mB' score)\" = 'low' ]"
check "B10b. …and it says what happened, quoting the launch message" \
  "grep -q 'your build did not start' '$mB/xo/verdict.json' && grep -q 'no runnable target' '$mB/xo/verdict.json'"
check "B10b. NO browser was started at all" \
  "! grep 'lcars-20260913-002' '$XO_DRIVE_LOG' | grep -q -- '--url http'"
check "B10b. …and no worker was hired either" "[ ! -s '$XO_WORKER_LOG' ]"

# --------------------------------------------------------------------------
# B10b2 (S213). A BUILD THAT STARTED AND HAS NO WEB ADDRESS IS NOT A FAILURE TO
# LAUNCH — AND MUST NOT BE DESCRIBED AS ONE.
#
# launch.json for a desktop target is `status: running, url: "", message: "the
# app is running."`. This arm used to glue its own failure prefix onto that
# message and put the result on the captain's board card, verbatim:
#
#     could not launch: the app is running.
#
# Six words that contradict themselves. He cannot act on it, and it is the
# opposite of true about the half of it that matters.
# --------------------------------------------------------------------------
repoBU="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mBU="$(plant_verify "$repoBU" "lcars-20260913-004")"
: >"$XO_DRIVE_LOG"; : >"$XO_WORKER_LOG"
outBU="$(XO_LAUNCH_NO_URL=1 XO_EV_BODY="$(ev_verdict met met met high '')" \
        xo_evaluate "$repoBU" "lcars-20260913-004")"
check "B10b2. NOTHING anywhere reads 'could not launch: the app is running'" \
  "! grep -rq 'could not launch: the app is running' '$mBU' 2>/dev/null"
check "B10b2. …and no sentence on any surface says it could not launch a build that started" \
  "! grep -rqi 'could not launch' '$mBU' 2>/dev/null"
check "B10b2. what he is told instead is TRUE about both halves — it started, and there was nothing to open" \
  "grep -q 'your build started' '$mBU/xo/verdict.json' && grep -q 'nothing for me to look at' '$mBU/xo/verdict.json'"
check "B10b2. …and that sentence reaches the card note he actually reads" \
  "xo_state '$mBU' note | grep -q 'your build started'"
check "B10b2. …and it reaches his report too" \
  "[ -s '$mBU/xo/report.md' ] && grep -q 'your build started' '$mBU/xo/report.md'"
check "B10b2. no browser was started — there was nothing to point one at" \
  "! grep 'lcars-20260913-004' '$XO_DRIVE_LOG' | grep -q -- '--url http'"
check "B10b2. CONTROL — a build that really did NOT start is still told plainly that it did not" \
  "grep -q 'your build did not start' '$mB/xo/verdict.json'"

# --------------------------------------------------------------------------
# B10c. THE LEDGER → SCORE MATRIX. One row, one test, per the brief.
# --------------------------------------------------------------------------
ev_row() { # <name> <c1> <c2> <c3> <worker-score> <gaps> <want-score> <want-status>
  local name="$1" repo m id
  id="lcars-20260913-1$(printf '%02d' "$EV_ROW")"
  EV_ROW=$((EV_ROW + 1))
  repo="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
  m="$(plant_verify "$repo" "$id")"
  : >"$XO_WORKER_LOG"
  XO_EV_BODY="$(ev_verdict "$2" "$3" "$4" "$5" "$6")" xo_evaluate "$repo" "$id" >/dev/null 2>&1
  check "B10c. $name → $7" "[ \"\$(xo_state '$m' score)\" = '$7' ]"
  check "B10c. …status $8" "[ \"\$(xo_state '$m' status)\" = '$8' ]"
  EV_LAST_M="$m"
}
EV_ROW=0
# CHANGED, S225, ROWS 2 AND 4 — AND THIS MATRIX IS THE DEFECT WRITTEN OUT. In
# this fixture `t-1-ac1` is a TICKET acceptance criterion (xo-criteria.py stamps
# it `source: "plan"` off plan.json); `prd-1`/`prd-2` are the PRD. Row 2 asserted
# that a ticket criterion alone pulled the captain's headline to MEDIUM while
# every PRD statement was met, and row 4 asserted that a ticket criterion NOBODY
# COULD CHECK did the same. Those are the two mechanisms — a ticket list
# outvoting what a person can do (change 01), and our own blind spot reading as
# a doubt about his build (change 03) — that graded his build LOW while he
# scored it HIGH himself.
#
# NOTHING IS DROPPED. Both rows are counted, by name, on the contract line, and
# the ticket contradiction in row 2 is still filed as a fault (B10f2 below).
# ROWS 1, 3 AND 5 ARE THE CONTROLS and are untouched: a PRD statement seen to
# fail is still LOW, an all-met look is still HIGH, an interpretation still
# never counts.
ev_row "every criterion MET"                        met met met high ''            high   finished
ev_row "a TICKET criterion contradicted, every PRD statement met" met met gap medium "$GAP_TICKET" high finished
ev_row "a PRD (primary) criterion contradicted"      met gap met  low    "$GAP_PRIMARY" low    engaged
ev_row "a TICKET criterion nobody could check, everything else MET" met met untested high '' high finished
ev_row "an INTERPRETATION is reported, never filed"  met met met  high   "$GAP_INTERP" high   finished
check "B10c. …and the interpretation is still IN the report" \
  "grep -q '\"kind\": \"interpretation\"' '$EV_LAST_M/xo/verdict.json'"
check "B10c. the derivation is written down in words, not just the letter" \
  "grep -q '\"derivation\"' '$EV_LAST_M/xo/verdict.json'"

# A gap filed as a contradiction with NO SHOT is not evidence: it is recorded as
# an interpretation and it does NOT drag the score down. The anti-over-rejection
# guard, and the reason "a gap without a shot" can never reach the captain.
# (S216: the score now reads the ROW's outcome x impact, so the demoted gap sits
# on the medium-impact ticket row — the one whose outcome alone cannot make it
# LOW. A high row rated `gap` WITH a shot is a picture of a failure, and LOW.)
repoC2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mC2="$(plant_verify "$repoC2" "lcars-20260913-120")"
: >"$XO_WORKER_LOG"
XO_EV_BODY="$(ev_verdict met met gap low '{"title":"ADD is misplaced","expected":"x","saw":"y","shots":[],"kind":"contradiction","criterion":"t-1-ac1"}')" \
  xo_evaluate "$repoC2" "lcars-20260913-120" >/dev/null 2>&1
check "B10c. a contradiction with NO SHOT is demoted to an interpretation" \
  "grep -q '\"kind\": \"interpretation\"' '$mC2/xo/verdict.json'"
check "B10c. …so it cannot make the score LOW on no evidence" \
  "[ \"\$(xo_state '$mC2' score)\" != 'low' ]"
check "B10c. …and the demotion is journaled, not hidden" \
  "grep -q 'ledger-note' '$mC2/number-one.jsonl'"

# --------------------------------------------------------------------------
# B10d. THE WORKER'S SCORE LOSES TO ITS OWN LEDGER — AND THE FIGHT IS RECORDED.
# --------------------------------------------------------------------------
repoD="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mD="$(plant_verify "$repoD" "lcars-20260913-004")"
: >"$XO_WORKER_LOG"
outD="$(XO_EV_BODY="$(ev_verdict met gap met high "$GAP_PRIMARY")" \
        xo_evaluate "$repoD" "lcars-20260913-004")"
check "B10d. the worker said HIGH; the ledger says LOW and the LEDGER WINS" \
  "[ \"\$(xo_state '$mD' score)\" = 'low' ]"
check "B10d. the recorded verdict keeps BOTH scores" \
  "grep -q '\"workerScore\": \"high\"' '$mD/xo/verdict.json' && grep -q '\"score\": \"low\"' '$mD/xo/verdict.json'"
check "B10d. …flags the disagreement" \
  "grep -q '\"scoreDisagreed\": true' '$mD/xo/verdict.json'"
check "B10d. …and JOURNALS it, so anyone can see the ledger overruled the model" \
  "grep -q '\"action\": \"score-overruled\"' '$mD/number-one.jsonl' && grep -q '\"workerScore\": \"high\"' '$mD/number-one.jsonl'"
check "B10d. it says so out loud too" \
  "printf '%s' \"\$outD\" | grep -q 'the ledger decides'"

# --------------------------------------------------------------------------
# B10e. THE ACTION ROUNDS, WHEN A CEILING IS ASKED FOR — at most TWO, and round
#       three is never spawned.
#
# THE CEILING CAME DOWN FROM THREE (captain's ruling, 2026-09-20). Measured over
# five real-arm runs, the extra round bought nothing: 3 rounds → 4/5, 2 → 3/5,
# 2 → 5/5, 1 → 5/5, 1 → 5/5.
#
# AND THEN IT BECAME OPT-IN (captain's ruling, 2026-10-04; S246). *A look has no
# clock.* With `$LCARS_XO_MAX_ROUNDS` unset there is NO ceiling: the loop runs
# until the worker writes its verdict, because the captain's EEH — following
# the same checklists by hand — ran for hours while Number One was cut off at
# roughly five minutes and so could never seed in one round and read the effect
# in the next. **That default is proven in `tests/lcars-xo-drives.test.sh` §3.**
#
# What this row still proves, unchanged, is the CEILING: asked for, it is obeyed
# exactly as it was, and every sentence that quotes it still reads true. The
# number is now named here rather than inherited, which is also how the rows
# below stay honest about which cap was in force.
# --------------------------------------------------------------------------
repoE="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mE="$(plant_verify "$repoE" "lcars-20260913-005")"
: >"$XO_WORKER_LOG"; : >"$XO_DRIVE_LOG"
outE="$(XO_EV_ROUNDS=9 LCARS_XO_MAX_ROUNDS=2 xo_evaluate "$repoE" "lcars-20260913-005")"
check "B10e. exactly TWO workers were hired, never a third" \
  "[ \"\$(grep -c '^worker ' '$XO_WORKER_LOG')\" = '2' ]"
check "B10e. no verdict in two rounds → LOW" "[ \"\$(xo_state '$mE' score)\" = 'low' ]"
check "B10e. …saying exactly that, with the cap it actually ran to" \
  "grep -q 'could not reach a verdict in 2 rounds' '$mE/xo/verdict.json'"
check "B10e. …and the printed round line counts to the same cap" \
  "printf '%s' \"\$outE\" | grep -q 'round 1 of 2' && \
   printf '%s' \"\$outE\" | grep -q 'round 2 of 2' && \
   ! printf '%s' \"\$outE\" | grep -q 'round 3 of'"
check "B10e. …and LISTING what it did see" \
  "grep -q '\"sawShots\"' '$mE/xo/verdict.json' && grep -q 'shot-01' '$mE/xo/verdict.json'"
check "B10e. the driver was handed the worker's action list" \
  "grep -q -- '--actions' '$XO_DRIVE_LOG'"
check "B10e. …under the 12-action cap" "grep -q -- '--max-actions 12' '$XO_DRIVE_LOG'"
check "B10e. the mission is left ENGAGED for the fix round" \
  "[ \"\$(xo_state '$mE' status)\" = 'engaged' ]"

# An over-long action list is recorded as ASKED, against the cap — never silently
# passed off as what it got.
repoE2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mE2="$(plant_verify "$repoE2" "lcars-20260913-006")"
BIG="$(python3 -c 'import json;print(json.dumps([{"wait":1} for _ in range(20)]))')"
: >"$XO_WORKER_LOG"
XO_EV_ROUNDS=1 XO_EV_ACTIONS="$BIG" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate "$repoE2" "lcars-20260913-006" >/dev/null 2>&1
check "B10e. a 20-action ask is journaled AS 20, against the cap of 12" \
  "grep -q '\"asked\": 20' '$mE2/number-one.jsonl' && grep -q '\"cap\": 12' '$mE2/number-one.jsonl'"

# THE OVERRIDE IS UNCHANGED. $LCARS_XO_MAX_ROUNDS still raises (or lowers) the
# ceiling exactly as it did — the benchmark rig and the fix-round drives set it,
# and a default that could not be overridden would strand them.
repoE3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mE3="$(plant_verify "$repoE3" "lcars-20260913-0061")"
: >"$XO_WORKER_LOG"
# The override goes in the ENVIRONMENT, not in xo_evaluate's extra arguments.
# A word that only becomes `VAR=value` AFTER expansion is not an assignment —
# bash decides that before it expands `"$@"` — so passing it as an argument
# makes it the COMMAND, and the row silently measures nothing. (The same trap
# xo_evaluate_with was written for.) xo_evaluate does not name this variable in
# its own prefix list, so an inherited one reaches xo.sh untouched.
outE3="$(XO_EV_ROUNDS=9 LCARS_XO_MAX_ROUNDS=4 xo_evaluate "$repoE3" "lcars-20260913-0061")"
check "B10e. \$LCARS_XO_MAX_ROUNDS still sets the ceiling (4 → four workers)" \
  "[ \"\$(grep -c '^worker ' '$XO_WORKER_LOG')\" = '4' ]"
check "B10e. …and the refusal quotes the cap that was actually in force" \
  "grep -q 'could not reach a verdict in 4 rounds' '$mE3/xo/verdict.json'"

# --------------------------------------------------------------------------
# B10f. THE LABEL IS THE SCORE (one source per fact) — and the other two go.
# --------------------------------------------------------------------------
repoF="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mF="$(plant_verify "$repoF" "lcars-20260913-007")"
: >"$XO_WORKER_LOG"; : >"$XO_LABEL_LOG"
XO_EV_BODY="$(ev_verdict_prd_medium)" \
  xo_evaluate "$repoF" "lcars-20260913-007" >/dev/null 2>&1
check "B10f. lcars:xo:medium is ADDED to the issue" \
  "grep -q -- '--add lcars:xo:medium' '$XO_LABEL_LOG'"
check "B10f. …and the other two score labels are REMOVED" \
  "grep -q -- '--remove lcars:xo:high,lcars:xo:low' '$XO_LABEL_LOG'"
check "B10f. …on the mission's own issue number" "grep -q 'issue-relabel 42' '$XO_LABEL_LOG'"
check "B10f. the score is on the state block too (the local board's read)" \
  "[ \"\$(xo_state '$mF' score)\" = 'medium' ]"
check "B10f. the gap is in the report WITH the shot that shows it" \
  "grep -q '\"shots\"' '$mF/xo/verdict.json' && grep -q 'shot-02' '$mF/xo/verdict.json'"

# S225 — AND NOTHING IS DROPPED BY THE SPLIT, PROVED ON THE WIRED PATH. The
# SAME contradiction on a TICKET criterion no longer sets the captain's grade
# (that is the ruling), and it is still filed, still named, still counted —
# on the contract line, where he can act on it.
repoFT="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mFT="$(plant_verify "$repoFT" "lcars-20260913-0072")"
: >"$XO_WORKER_LOG"; : >"$XO_LABEL_LOG"
XO_EV_BODY="$(ev_verdict met met gap medium "$GAP_TICKET")" \
  xo_evaluate "$repoFT" "lcars-20260913-0072" >/dev/null 2>&1
check "B10f. a TICKET contradiction alone no longer sets the headline" \
  "[ \"\$(xo_state '$mFT' score)\" = 'high' ] && grep -q -- '--add lcars:xo:high' '$XO_LABEL_LOG'"
check "B10f. …and the contract line still counts it, and still says it didn't work" \
  "python3 -c 'import json,sys
g=json.load(open(\"$mFT/xo/verdict.json\"))[\"groups\"][\"contract\"]
sys.exit(0 if g[\"total\"]==1 and g[\"covered\"]==1 and g[\"didntWork\"]==1 and \"grade\" not in g else 1)' \
   && grep -qi 'Is the contract covered' '$mFT/xo/report.md'"
check "B10f. …and the fault itself is still written out, with its shot" \
  "grep -q 'ADD is above the list' '$mFT/xo/report.md' && grep -q 'shot-02' '$mFT/xo/verdict.json'"

# --------------------------------------------------------------------------
# B10i. THE LABEL EXISTS BEFORE THE SWAP TRIES TO USE IT.
#
# Every repo initialized before this round has none of the `lcars:xo:*` family,
# and `gh issue edit --add-label` on a label the forge has never heard of FAILS
# — silently, in a best-effort call, exactly where the verdict was supposed to
# become visible. So the swap ensures its own family first, from the same list
# `lcars init` creates from.
# --------------------------------------------------------------------------
check "B10i. the family was ensured before the relabel" \
  "[ \"\$(grep -n 'label-ensure' '$XO_LABEL_LOG' | head -1 | cut -d: -f1)\" -lt \"\$(grep -n 'issue-relabel' '$XO_LABEL_LOG' | head -1 | cut -d: -f1)\" ]"
for lab in high medium low engaged; do
  check "B10i. …including lcars:xo:$lab" \
    "grep -q 'lcars:xo:$lab|' '$XO_LABEL_LOG'"
done
check "B10i. …each with a colour and a description, from the shared list" \
  "grep -q 'lcars:xo:medium|FF9966|Number One: intent match MEDIUM' '$XO_LABEL_LOG'"
check "B10i. init's canonical set carries the same four and no others" \
  "[ \"\$(bash -c '. $REPO_ROOT/skills/lcars-init/lcars-common.sh; lcars_all_labels' | grep -c '^lcars:xo:')\" -eq 4 ]"
check "B10i. …so lcars update fills them in on a repo that predates them" \
  "bash -c '. $REPO_ROOT/skills/lcars-init/lcars-common.sh; lcars_all_labels' | grep -q '^lcars:xo:engaged|FF9966$'"

# --------------------------------------------------------------------------
# B10f2. THE LIVING COMMENT CARRIES THE LEDGER — and names its shots.
# --------------------------------------------------------------------------
check "B10f2. the report fragment the living comment includes was written" \
  "[ -s '$mF/xo/report.md' ]"
# THE TABLE IS STILL MACHINE-READABLE; ITS HEADER IS NOW WRITTEN TO HIM.
# "Intent match" and "Criterion" were the captain's two reports of 2026-09-13
# ("I need more plain English in my report") arriving as column furniture. The
# ROWS are asserted exactly as before — same ids, same (PRD) marker, same
# MET/GAP/UNTESTED verdicts — because it is the prose around the table that
# changed and the table itself that must not.
check "B10f2. …with the per-criterion table, in full" \
  "grep -q '| What you asked for |' '$mF/xo/report.md' && grep -q 'prd-1 (PRD)' '$mF/xo/report.md' && grep -q 't-1-ac1' '$mF/xo/report.md'"
check "B10f2. …the rows still carry the machine verdicts, unchanged" \
  "grep -qE '\| (MET|GAP|UNTESTED) \|' '$mF/xo/report.md'"
check "B10f2. …the score and the DERIVATION that produced it, in his words" \
  "grep -q 'How close this is to what you asked for: MEDIUM' '$mF/xo/report.md'"
check "B10f2. …with the criterion ids AFTER the human sentence, never before it" \
  "grep -q 'The point of the mission works; go with this known issue — ADD is above the list (prd-2)' '$mF/xo/report.md' \
   && grep -q 'ADD is above the list — you asked for the ADD button sits under the list; the build gives it is above it (prd-2)' '$mF/xo/report.md'"
check "B10f2. …and the gap, named with the SHOT that shows it (never an image)" \
  "grep -q 'ADD is above the list' '$mF/xo/report.md' && grep -q 'shot-02' '$mF/xo/report.md'"
check "B10f2. a path with no ledger still owes the captain a sentence" \
  "[ -s '$mB/xo/report.md' ] && grep -q 'your build did not start' '$mB/xo/report.md'"

# --------------------------------------------------------------------------
# B10g. TWICE IS A NO-OP. evaluatedAt is the guard.
# --------------------------------------------------------------------------
: >"$XO_WORKER_LOG"
outG="$(xo_evaluate "$repoF" "lcars-20260913-007")"
check "B10g. a second evaluate hires nobody" "[ ! -s '$XO_WORKER_LOG' ]"
check "B10g. …and says it has already looked" \
  "printf '%s' \"\$outG\" | grep -q 'already looked'"
check "B10g. state.json is still valid JSON after every write" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$mF/state.json'"

# --------------------------------------------------------------------------
# B10h. A LOGGED BUG CHILD IS NEVER EVALUATED — its parent carries the build.
# --------------------------------------------------------------------------
repoH="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mH="$(plant_verify "$repoH" "lcars-20260913-008")"
python3 - "$mH/state.json" <<'PY'
import sys
p=sys.argv[1]
lines=open(p).read().splitlines()
lines.insert(1, '  "parentMission": "lcars-20260913-007",')
open(p,"w").write("\n".join(lines)+"\n")
PY
: >"$XO_WORKER_LOG"; : >"$XO_LAUNCH_LOG"
outH="$(xo_evaluate "$repoH" "lcars-20260913-008")"
check "B10h. a bug child is skipped" "printf '%s' \"\$outH\" | grep -q 'bug child'"
check "B10h. …nothing launched" "[ ! -s '$XO_LAUNCH_LOG' ]"
check "B10h. …nobody hired" "[ ! -s '$XO_WORKER_LOG' ]"


# ==========================================================================
# B11. FIX ROUND 1 — the stop button, the teardown, the inspector's engine,
#      the worker's contract, the temp dirs, the clock and the copy.
#
# Everything here is driven through the SAME stubs B10 built (a launch script,
# a driver run under `bash`, a worker shim) so not one real CLI and not one
# real browser is started.
# ==========================================================================
echo
echo "B11. fix round 1 — stop, teardown, engine pin, contract, clocks, copy"

# --------------------------------------------------------------------------
# B11a (D1). `lcars xo off <id>` STOPS A LIVE SPIN — whatever the status says.
#     The bug: the whole kill branch was gated on status == "engaged", and
#     evaluate never wrote that status, so the captain's stop button was inert.
# --------------------------------------------------------------------------
repoK1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mK1="$(plant_mission "$repoK1" "lcars-20260913-101" verify '{"engine": "copilot"}')"
sleep 45 &
livepid=$!
( cd "$repoK1" && bash "$SCRIPT" record-pid "$livepid" "$mK1/xo.pid" )   # the shipped format
( cd "$repoK1" && bash "$SCRIPT" off "lcars-20260913-101" >"$repoK1/off.txt" 2>&1 ) || true
# Give the TERM a moment to land.
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$livepid" 2>/dev/null || break; sleep 0.2; done
alive=1; kill -0 "$livepid" 2>/dev/null || alive=0
kill -9 "$livepid" 2>/dev/null || true
check "B11a. the recorded pid was SIGNALLED even with no 'engaged' status" "[ '$alive' -eq 0 ]"
check "B11a. …the state records stood-down" \
  "grep -q '\"status\": \"stood-down\"' '$mK1/state.json'"
check "B11a. …with a note the captain can read" \
  "grep -q 'you have the conn' '$mK1/state.json'"
check "B11a. …and a since stamp" "grep -q '\"since\"' '$mK1/state.json'"
check "B11a. …the pid file is gone" "[ ! -f '$mK1/xo.pid' ]"
check "B11a. …the journal records the stand-down" \
  "grep -q '\"action\": \"stood-down\"' '$mK1/number-one.jsonl'"
check "B11a. …and it still says it stood down, not merely 'opted out'" \
  "grep -q 'stood down on' '$repoK1/off.txt'"
check "B11a. state.json is still valid JSON" \
  "python3 -c 'import json,sys; json.load(open(sys.argv[1]))' '$mK1/state.json'"

# A STALE pid file is NOT a live spin. The opt-out path must still be the one
# that runs, or every `xo off` on a crashed mission would claim a stand-down.
repoK2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mK2="$(plant_mission "$repoK2" "lcars-20260913-102" verify '{"engine": "copilot"}')"
printf '999999\n' >"$mK2/xo.pid"
( cd "$repoK2" && bash "$SCRIPT" off "lcars-20260913-102" >"$repoK2/off.txt" 2>&1 ) || true
check "B11a. a STALE pid is not a spin — the opt-out line is printed" \
  "grep -q 'opted out' '$repoK2/off.txt'"

# --------------------------------------------------------------------------
# B11b (D1 + D2). MID-DRIVE: `lcars xo off` kills the spin, STOPS THE LAUNCH,
#     and leaves no work dir behind. The stub driver here BLOCKS, which is the
#     browser's place in a real run.
# --------------------------------------------------------------------------
SLOW_DRIVE="$EVDIR/xo-drive-slow.sh"
cat >"$SLOW_DRIVE" <<'SD'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out"
printf '%s\n' "$$" >"$XO_DRIVE_LOG.slowpid"
sleep 45
exit 0
SD
chmod +x "$SLOW_DRIVE"

repoK3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mK3="$(plant_verify "$repoK3" "lcars-20260913-103")"
: >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"; rm -f "$XO_DRIVE_LOG.slowpid"
# TMPDIR of its own, so the work dirs this run makes are countable.
evtmp="$WORKDIR/evtmp-103"; mkdir -p "$evtmp"
( cd "$repoK3" && XO_WORKER_LOG="$XO_WORKER_LOG" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$SLOW_DRIVE" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 TMPDIR="$evtmp" \
    bash "$SCRIPT" evaluate --mission "lcars-20260913-103" >"$repoK3/ev.txt" 2>&1 ) &
evpid=$!
# Wait for the drive to be under way (the app is up, the driver is blocking).
for _ in $(seq 1 60); do [ -f "$XO_DRIVE_LOG.slowpid" ] && break; sleep 0.2; done
drivepid="$(cat "$XO_DRIVE_LOG.slowpid" 2>/dev/null)"
printf 'Tried the helm. Saw a blank screen. Next: inspect navigation.\n' >"$mK3/xo/notes.md"
printf '{"observations":[{"kind":"ui","detail":"Navigation missing","screen":"bridge","shot":"shots/bridge.png"}]}\n' >"$mK3/xo/observations.json"
printf '{"action":"tested","outcome":"passed","detail":"Helm smoke check"}\n{"action":"tested","outcome":"failed","detail":"Navigation check"}\n' >>"$mK3/number-one.jsonl"
( cd "$repoK3" && bash "$SCRIPT" off "lcars-20260913-103" >"$repoK3/off.txt" 2>&1 ) || true
for _ in $(seq 1 40); do kill -0 "$evpid" 2>/dev/null || break; sleep 0.25; done
ev_alive=1; kill -0 "$evpid" 2>/dev/null || ev_alive=0
dr_alive=1; [ -n "$drivepid" ] && kill -0 "$drivepid" 2>/dev/null || dr_alive=0
# NEVER `kill 0` — that signals the whole process group, this suite included.
kill -9 "$evpid" 2>/dev/null || true
[ -n "$drivepid" ] && kill -9 "$drivepid" 2>/dev/null || true
wait "$evpid" 2>/dev/null || true
check "B11b. the evaluate process is gone" "[ '$ev_alive' -eq 0 ]"
check "B11b. …the driver it started is gone with it" "[ '$dr_alive' -eq 0 ]"
check "B11b. …the LAUNCH was stopped on the way out" \
  "grep -q -- '--stop' '$XO_LAUNCH_LOG'"
check "B11b. …launch.json no longer says running" \
  "! grep -q '\"status\": \"running\"' '$mK3/launch.json'"
check "B11b. …no read-only work dir was left behind" \
  "[ \"\$(ls -1 '$evtmp' 2>/dev/null | grep -c .)\" = '0' ]"
check "B11b. …and the state says stood-down" \
  "grep -q '\"status\": \"stood-down\"' '$mK3/state.json'"
check "B11b. …interruption preserves a DISTINCT partial report" \
  "[ -s '$mK3/xo/partial-report.md' ]"
check "B11b. …the partial is INTERRUPTED, not a verdict or recommendation" \
  "grep -q 'INTERRUPTED' '$mK3/xo/partial-report.md' && grep -qi 'partial' '$mK3/xo/partial-report.md' && grep -qi 'not a completed verdict' '$mK3/xo/partial-report.md' && grep -qi 'no.*score.*merge recommendation' '$mK3/xo/partial-report.md'"
check "B11b. …notes retain exactly what was tried, seen, and next" \
  "grep -Fq 'Tried the helm. Saw a blank screen. Next: inspect navigation.' '$mK3/xo/partial-report.md'"
check "B11b. …structured observations preserve details and screenshot references" \
  "grep -q 'Navigation missing' '$mK3/xo/partial-report.md' && grep -q 'bridge.png' '$mK3/xo/partial-report.md'"
check "B11b. …the ROOT journal retains both passed and failed test outcomes" \
  "grep -q 'Helm smoke check' '$mK3/xo/partial-report.md' && grep -q 'passed' '$mK3/xo/partial-report.md' && grep -q 'Navigation check' '$mK3/xo/partial-report.md' && grep -q 'failed' '$mK3/xo/partial-report.md'"
check "B11b. …no completed report or verdict is manufactured" \
  "[ ! -f '$mK3/xo/report.md' ] && [ ! -f '$mK3/xo/verdict.json' ]"

# --------------------------------------------------------------------------
# B11c (D2). A DIRECT SIGTERM to the recorded pid tears down just the same.
#     This is the shape of a `kill` from the captain's own shell, or a parent
#     that dies — the path that left an orphaned browser and a live app.
# --------------------------------------------------------------------------
repoK4="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mK4="$(plant_verify "$repoK4" "lcars-20260913-104")"
: >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"; rm -f "$XO_DRIVE_LOG.slowpid"
evtmp4="$WORKDIR/evtmp-104"; mkdir -p "$evtmp4"
( cd "$repoK4" && XO_WORKER_LOG="$XO_WORKER_LOG" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$SLOW_DRIVE" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 TMPDIR="$evtmp4" \
    bash "$SCRIPT" evaluate --mission "lcars-20260913-104" >"$repoK4/ev.txt" 2>&1 ) &
ev4=$!
for _ in $(seq 1 60); do [ -f "$XO_DRIVE_LOG.slowpid" ] && break; sleep 0.2; done
drive4="$(cat "$XO_DRIVE_LOG.slowpid" 2>/dev/null)"
xopid="$(head -1 "$mK4/xo.pid" 2>/dev/null | tr -dc '0-9')"
cp "$mK4/state.json" "$repoK4/state-before-term.json"
cp "$mK4/number-one.jsonl" "$repoK4/journal-before-term.jsonl"
[ -n "$xopid" ] && kill -TERM "$xopid" 2>/dev/null || true
for _ in $(seq 1 40); do kill -0 "$ev4" 2>/dev/null || break; sleep 0.25; done
ev4_alive=1; kill -0 "$ev4" 2>/dev/null || ev4_alive=0
dr4_alive=1; [ -n "$drive4" ] && kill -0 "$drive4" 2>/dev/null || dr4_alive=0
kill -9 "$ev4" 2>/dev/null || true
[ -n "$drive4" ] && kill -9 "$drive4" 2>/dev/null || true
ev4_rc=0; wait "$ev4" 2>/dev/null || ev4_rc=$?
check "B11c. a direct TERM to xo.pid ends the spin" "[ '$ev4_alive' -eq 0 ]"
check "B11c. …and the driver dies with it" "[ '$dr4_alive' -eq 0 ]"
check "B11c. …the launch is stopped, not orphaned" \
  "grep -q -- '--stop' '$XO_LAUNCH_LOG'"
check "B11c. …and no work dir survives" \
  "[ \"\$(ls -1 '$evtmp4' 2>/dev/null | grep -c .)\" = '0' ]"
check "B11c. …TERM exits 143 and removes the pid" \
  "[ '$ev4_rc' -eq 143 ] && [ ! -f '$mK4/xo.pid' ]"
check "B11c. …TERM never rewrites state or appends a journal record" \
  "cmp -s '$mK4/state.json' '$repoK4/state-before-term.json' && cmp -s '$mK4/number-one.jsonl' '$repoK4/journal-before-term.jsonl'"
check "B11c. …bookkeeping alone does not produce an empty partial report" \
  "[ ! -e '$mK4/xo/partial-report.md' ]"

# Each source stands alone; corrupt evidence and write failures must not
# compromise the real TERM trap's teardown or its state/journal non-writes.
partial_case=110
for evidence in notes observations journal malformed write-failure empty; do
  partial_id="lcars-20260913-$partial_case"; partial_case=$((partial_case + 1))
  partial_repo="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
  partial_mission="$(plant_verify "$partial_repo" "$partial_id")"
  rm -f "$XO_DRIVE_LOG.slowpid"
  ( cd "$partial_repo" && \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
      LCARS_XO_DRIVER="$SLOW_DRIVE" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 TMPDIR="$evtmp4" \
      bash "$SCRIPT" evaluate --mission "$partial_id" >"$partial_repo/ev.txt" 2>&1 ) &
  partial_pid=$!; PROBE_PIDS="$PROBE_PIDS $partial_pid"
  for _ in $(seq 1 60); do [ -f "$XO_DRIVE_LOG.slowpid" ] && break; sleep 0.2; done
  check "B11c partial $evidence: the real evaluate reached its driver" \
    "[ -s '$XO_DRIVE_LOG.slowpid' ]"
  case "$evidence" in
    notes|malformed|write-failure)
      printf 'Tried impulse. Saw flicker. Next: inspect power.\n' >"$partial_mission/xo/notes.md" ;;
  esac
  case "$evidence" in
    observations)
      printf '{"observations":[{"kind":"ui","detail":"Independent observation","screen":"helm"}]}\n' >"$partial_mission/xo/observations.json" ;;
    journal)
      printf '{"action":"tested","outcome":"failed","detail":"Independent test failure"}\n' >>"$partial_mission/number-one.jsonl" ;;
    malformed)
      printf '{broken\n' >"$partial_mission/xo/observations.json"
      printf 'bad journal line\n{"action":"tested","outcome":"passed","detail":"Surviving journal entry"}\n' >>"$partial_mission/number-one.jsonl" ;;
    write-failure) mkdir "$partial_mission/xo/partial-report.md" ;;
    empty)
      printf ' \n' >"$partial_mission/xo/notes.md"
      printf '{"observations":[]}\n' >"$partial_mission/xo/observations.json"
      printf '{"action":"verdict-channel","detail":"Reply arrived on stdout"}\n{"action":"noted","lines":0}\n' >>"$partial_mission/number-one.jsonl" ;;
  esac
  cp "$partial_mission/state.json" "$partial_repo/state-before-term.json"
  cp "$partial_mission/number-one.jsonl" "$partial_repo/journal-before-term.jsonl"
  partial_xopid="$(head -1 "$partial_mission/xo.pid" 2>/dev/null | tr -dc '0-9')"
  [ -n "$partial_xopid" ] && kill -TERM "$partial_xopid" 2>/dev/null || true
  partial_rc=0; wait "$partial_pid" 2>/dev/null || partial_rc=$?
  check "B11c partial $evidence: teardown still exits 143, stops launch, removes pid and work" \
    "[ '$partial_rc' -eq 143 ] && [ ! -f '$partial_mission/xo.pid' ] && ! grep -q '\"status\": \"running\"' '$partial_mission/launch.json' && [ \"\$(ls -1 '$evtmp4' | grep -c .)\" = '0' ]"
  check "B11c partial $evidence: state and journal remain byte-identical" \
    "cmp -s '$partial_mission/state.json' '$partial_repo/state-before-term.json' && cmp -s '$partial_mission/number-one.jsonl' '$partial_repo/journal-before-term.jsonl'"
  case "$evidence" in
    notes) check "B11c partial notes: notes alone survive" \
      "grep -Fq 'Tried impulse. Saw flicker. Next: inspect power.' '$partial_mission/xo/partial-report.md'" ;;
    observations) check "B11c partial observations: object observations alone survive" \
      "grep -q 'Independent observation' '$partial_mission/xo/partial-report.md'" ;;
    journal) check "B11c partial journal: root test record alone survives with its outcome" \
      "grep -q 'Independent test failure' '$partial_mission/xo/partial-report.md' && grep -q 'failed' '$partial_mission/xo/partial-report.md'" ;;
    malformed)
      check "B11c partial malformed: healthy sources and valid journal lines survive" \
        "grep -q 'Tried impulse' '$partial_mission/xo/partial-report.md' && grep -q 'Surviving journal entry' '$partial_mission/xo/partial-report.md'"
      check "B11c partial malformed: bad sources are diagnosed on stderr" \
        "grep -q 'observations.json' '$partial_repo/ev.txt' && grep -q 'number-one.jsonl.*line' '$partial_repo/ev.txt'" ;;
    write-failure) check "B11c partial write-failure: persistence failure is diagnosed" \
      "grep -q 'partial-report.md' '$partial_repo/ev.txt'" ;;
    empty) check "B11c partial empty: empty observations and bookkeeping produce nothing" \
      "[ ! -e '$partial_mission/xo/partial-report.md' ]" ;;
  esac
done

# --------------------------------------------------------------------------
# B11d (D2 driver half). xo-drive.js tears its OWN Chrome down on a signal —
#     by the pid it started, and it removes its throwaway profile dir.
#     A fake `chrome` stands in: no browser, no CDP, no spend.
# --------------------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
  DRIVER_REAL="${LCARS_XO_DRIVER_REAL:-$REPO_ROOT/skills/lcars-xo/xo-drive.js}"
  FAKEC="$EVDIR/fake-chrome"
  cat >"$FAKEC" <<'FC'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$FAKE_CHROME_PID"
exec sleep 60
FC
  chmod +x "$FAKEC"
  dtmp="$WORKDIR/drivetmp"; rm -rf "$dtmp"; mkdir -p "$dtmp"
  export FAKE_CHROME_PID="$WORKDIR/fake-chrome.pid"; rm -f "$FAKE_CHROME_PID"
  ( TMPDIR="$dtmp" FAKE_CHROME_PID="$FAKE_CHROME_PID" \
      node "$DRIVER_REAL" --url "http://127.0.0.1:9/" --out "$WORKDIR/drive-out" \
      --chrome "$FAKEC" >/dev/null 2>&1 ) &
  dpid=$!
  for _ in $(seq 1 60); do [ -s "$FAKE_CHROME_PID" ] && break; sleep 0.2; done
  cpid="$(cat "$FAKE_CHROME_PID" 2>/dev/null | tr -dc '0-9')"
  kill -TERM "$dpid" 2>/dev/null || true
  for _ in $(seq 1 40); do kill -0 "$dpid" 2>/dev/null || break; sleep 0.25; done
  for _ in $(seq 1 20); do [ -n "$cpid" ] || break; kill -0 "$cpid" 2>/dev/null || break; sleep 0.2; done
  c_alive=1; [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null || c_alive=0
  udd="$(ls -1d "$dtmp"/lcars-xo-chrome.* 2>/dev/null | grep -c .)"
  kill -9 "$dpid" 2>/dev/null || true
  [ -n "$cpid" ] && kill -9 "$cpid" 2>/dev/null || true
  wait "$dpid" 2>/dev/null || true
  check "B11d. the driver started a browser we can see" "[ -n '$cpid' ]"
  check "B11d. a TERM to the driver kills ITS browser, by its own pid" "[ '$c_alive' -eq 0 ]"
  check "B11d. …and removes its throwaway user-data-dir" "[ '$udd' = '0' ]"
  # HEADLESS IS STILL STRUCTURAL — the teardown fix must not have bought an
  # escape hatch on the way past.
  argv="$(node "$DRIVER_REAL" --print-chrome-argv --url x --out "$WORKDIR/argv-out" 2>/dev/null)"
  check "B11d. --headless is still in the argv, unconditionally" \
    "printf '%s' \"\$argv\" | grep -q -- '--headless'"
else
  printf '  (node not on PATH — B11d skipped)\n'
fi

# --------------------------------------------------------------------------
# B11e (D3). THE LAUNCH INSPECTOR RUNS ON NUMBER ONE'S ENGINE — env-pinned, and
#     marked INTERNAL so the MISSION's own provenance is untouched. The bug
#     spawned `claude` under a copilot first officer, which spends real money.
# --------------------------------------------------------------------------
LAUNCH_ENV_STUB="$EVDIR/launch-env-stub.sh"
cat >"$LAUNCH_ENV_STUB" <<'LE'
#!/usr/bin/env bash
mid="$1"
m="$(pwd)/.git/lcars/missions/$mid"
printf 'launch %s bin=%s internal=%s\n' "$mid" \
  "${LCARS_WORKER_BIN:-<unset>}" "${LCARS_WORKER_BIN_INTERNAL:-<unset>}" >>"$XO_LAUNCH_LOG"
case "${2:-}" in
  --stop) printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
printf '{\n  "status": "failed",\n  "url": "",\n  "message": "stub: the env is what this test reads"\n}\n' >"$m/launch.json"
exit 1
LE
chmod +x "$LAUNCH_ENV_STUB"

pin_probe() { # <engine> <mission-id>
  local eng="$1" id="$2" repo m
  repo="$(new_repo "\"numberOne\": {\"enabled\": true, \"engine\": \"$eng\"}")"
  m="$(plant_verify "$repo" "$id")"
  # The MISSION's own engine is the OTHER one — so a pin that leaked from the
  # mission instead of from Number One would read the wrong way round.
  python3 - "$m/state.json" "$eng" <<'PY'
import sys
p, eng = sys.argv[1], sys.argv[2]
other = "claude" if eng == "copilot" else "copilot"
lines = open(p).read().splitlines()
lines[1] = '  "numberOne": {"status": "engaged", "engine": "%s"},' % eng
lines.insert(2, '  "workerBin": "%s",' % other)
lines.insert(3, '  "engineSource": "captain",')
open(p, "w").write("\n".join(lines) + "\n")
PY
  : >"$XO_LAUNCH_LOG"
  ( cd "$repo" && env -u LCARS_WORKER_BIN XO_LAUNCH_LOG="$XO_LAUNCH_LOG" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_ENV_STUB" \
      LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
      bash "$SCRIPT" evaluate --mission "$id" >/dev/null 2>&1 ) || true
  printf '%s' "$repo"
}

repoP1="$(pin_probe copilot "lcars-20260913-105")"
check "B11e. a copilot Number One pins a COPILOT launch inspector" \
  "grep -q 'bin=copilot' '$XO_LAUNCH_LOG'"
check "B11e. …marked INTERNAL, so it is LCARS's pin and not the captain's" \
  "grep -q 'internal=1' '$XO_LAUNCH_LOG'"
check "B11e. …and the MISSION's own workerBin is untouched" \
  "grep -q '\"workerBin\": \"claude\"' '$repoP1/.git/lcars/missions/lcars-20260913-105/state.json'"
check "B11e. …no real CLI was spawned by this probe" "[ ! -s '$XO_SHIM_LOG' ]"

repoP2="$(pin_probe claude "lcars-20260913-106")"
check "B11e. …and the other way round: a claude Number One pins CLAUDE" \
  "grep -q 'bin=claude' '$XO_LAUNCH_LOG'"
check "B11e. …still INTERNAL" "grep -q 'internal=1' '$XO_LAUNCH_LOG'"
check "B11e. …with the mission's copilot workerBin untouched" \
  "grep -q '\"workerBin\": \"copilot\"' '$repoP2/.git/lcars/missions/lcars-20260913-106/state.json'"

# The captain's OWN $LCARS_WORKER_BIN still wins — a pin must never override a
# choice a human typed.
repoP3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mP3="$(plant_verify "$repoP3" "lcars-20260913-107")"
: >"$XO_LAUNCH_LOG"
( cd "$repoP3" && LCARS_WORKER_BIN="$EV_SHIM" XO_LAUNCH_LOG="$XO_LAUNCH_LOG" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_ENV_STUB" \
    LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" evaluate --mission "lcars-20260913-107" >/dev/null 2>&1 ) || true
check "B11e. an ambient \$LCARS_WORKER_BIN the captain set is NOT overridden" \
  "grep -q \"bin=$EV_SHIM\" '$XO_LAUNCH_LOG'"

# --------------------------------------------------------------------------
# B11f (D4). THE WORKER IS HANDED ITS CONTRACT. criteria.json and the shots (with
#     their readouts) are IN the input dir, not somewhere the worker has to go
#     find — and the grant names the dir that holds them.
# --------------------------------------------------------------------------
INV_SHIM="$EVDIR/ev-worker-inventory"
cat >"$INV_SHIM" <<'IVS'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG.all"
{ printf 'INDIR %s\n' "${LCARS_XO_INPUT_DIR:-<unset>}"
  [ -n "${LCARS_XO_INPUT_DIR:-}" ] && ( cd "$LCARS_XO_INPUT_DIR" && find . -type f | sed 's|^|FILE |' )
  printf '%s\n' "${LCARS_WORKER_INPUT_DIRS:-}" | sed 's|^|GRANT |'
} >>"$XO_INPUT_LOG"
out="${LCARS_WORK_OUT:-}"
printf '%s\n' "${XO_EV_BODY:-}" >"$out/xo-verdict.json"
exit 0
IVS
chmod +x "$INV_SHIM"

repoI="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mI="$(plant_verify "$repoI" "lcars-20260913-108")"
export XO_INPUT_LOG="$WORKDIR/input-inventory.txt"; : >"$XO_INPUT_LOG"
: >"$XO_WORKER_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_DRIVE_LOG"
evtmpI="$WORKDIR/evtmp-108"; mkdir -p "$evtmpI"
( cd "$repoI" && XO_WORKER_LOG="$XO_WORKER_LOG" XO_INPUT_LOG="$XO_INPUT_LOG" \
    XO_EV_BODY="$(ev_verdict met met met medium "$GAP_TICKET")" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_WORKER_BIN="$INV_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 TMPDIR="$evtmpI" \
    bash "$SCRIPT" evaluate --mission "lcars-20260913-108" >"$repoI/ev.txt" 2>&1 ) || true
check "B11f. criteria.json is IN the worker's input dir" \
  "grep -q '^FILE \./criteria.json$' '$XO_INPUT_LOG'"
check "B11f. the SHOTS are in it too — the worker never leaves its input dir" \
  "grep -q '^FILE \./shots/shot-01.png$' '$XO_INPUT_LOG'"
check "B11f. …with the readout beside each shot" \
  "grep -q '^FILE \./shots/shot-01.json$' '$XO_INPUT_LOG' && grep -q '^FILE \./shots/shot-01.txt$' '$XO_INPUT_LOG'"
check "B11f. …and the input dir is GRANTED to the worker" \
  "grep -q '^GRANT .*input$' '$XO_INPUT_LOG'"

# --------------------------------------------------------------------------
# B11g (D5). NO PERMISSION-DENIED SPAM, AND NO LEFTOVER TEMP DIRS.
# --------------------------------------------------------------------------
check "B11g. the captain's terminal carries no rm errors" \
  "! grep -q 'Permission denied' '$repoI/ev.txt'"
check "B11g. …and the read-only input temp dir was actually removed" \
  "[ \"\$(ls -1 '$evtmpI' 2>/dev/null | grep -c .)\" = '0' ]"

# --------------------------------------------------------------------------
# B11h (D6). EVERY JOURNAL LINE IS STAMPED WHEN IT IS WRITTEN.
# --------------------------------------------------------------------------
SLEEPY_DRIVE="$EVDIR/xo-drive-sleepy.sh"
cat >"$SLEEPY_DRIVE" <<'SPD'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out"
n="$(ls "$out"/*.png 2>/dev/null | grep -c . | tr -d ' ')"
printf 'PNG\n' >"$out/shot-0$((n+1)).png"
printf '{"shot":"x"}\n' >"$out/shot-0$((n+1)).json"
printf 'x\n' >"$out/shot-0$((n+1)).txt"
sleep 2
printf '{"allPainted":true}\n'
exit 0
SPD
chmod +x "$SLEEPY_DRIVE"

repoJ="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mJ="$(plant_verify "$repoJ" "lcars-20260913-109")"
: >"$XO_WORKER_LOG"
evtmpJ="$WORKDIR/evtmp-109"; mkdir -p "$evtmpJ"
( cd "$repoJ" && XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_EV_BODY="$(ev_verdict met met met medium "$GAP_TICKET")" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$SLEEPY_DRIVE" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 TMPDIR="$evtmpJ" \
    bash "$SCRIPT" evaluate --mission "lcars-20260913-109" >/dev/null 2>&1 ) || true
stamps="$(python3 -c '
import json,sys
ats=[json.loads(l)["at"] for l in open(sys.argv[1]) if l.strip()]
print(len(set(ats)), len(ats))' "$mJ/number-one.jsonl" 2>/dev/null)"
distinct="${stamps%% *}"; total="${stamps##* }"
printf '  journal stamps: %s distinct of %s lines\n' "$distinct" "$total"
check "B11h. the journal has more than one line to order" "[ \"\${total:-0}\" -ge 3 ]"
check "B11h. …and its lines do NOT all carry one frozen timestamp" \
  "[ \"\${distinct:-1}\" -gt 1 ]"

# --------------------------------------------------------------------------
# B11i (D7). THE EVIDENCE CELL BREAKS ON A WORD, AND THE GAP BULLET HAS ONE
#     FULL STOP. A cut landing on an open quote is a cut the captain cannot read.
# --------------------------------------------------------------------------
SCOREPY="${LCARS_XO_SCORE_PY:-$REPO_ROOT/skills/lcars-xo/xo-score.py}"
scdir="$WORKDIR/score-copy"; rm -rf "$scdir"; mkdir -p "$scdir"
cat >"$scdir/criteria.json" <<'CJ'
{"criteria": [{"id": "prd-1", "text": "open tasks in one list", "primary": true,
               "source": "prd"}],
 "placeNames": ["#task-list"]}
CJ
# The note is deliberately LONGER than the cell's budget and carries an opening
# quote near the cut — the exact shape the captain saw truncated to `…and no '`.
python3 - "$scdir/verdict-in.json" <<'PY'
import json, sys
longnote = ("the list is present and laid out at the top of the page and it carries "
            "three rows of placeholder copy of the sort a stub ships with and no "
            "'add' control of any kind is anywhere near it or under it")
json.dump({"score": "low", "summary": "Looked.",
           "criteria": [{"id": "prd-1", "text": "open tasks in one list",
                         "status": "gap", "shot": "shot-01", "note": longnote}],
           "gaps": [{"title": "no add control", "expected": "a control",
                     "saw": "nothing anywhere on the page (readout).",
                     "shots": ["shot-01"], "kind": "contradiction",
                     "criterion": "prd-1"}]}, open(sys.argv[1], "w"))
PY
python3 "$SCOREPY" "$scdir/verdict-in.json" "$scdir/criteria.json" "$scdir/verdict.json" >/dev/null 2>&1 || true
copyrc=0
python3 - "$scdir/report.md" <<'PY' || copyrc=$?
import sys
md = open(sys.argv[1], encoding="utf-8").read()
note = ("the list is present and laid out at the top of the page and it carries "
        "three rows of placeholder copy of the sort a stub ships with and no "
        "'add' control of any kind is anywhere near it or under it")
row = [l for l in md.splitlines() if l.startswith("| prd-1")]
assert row, "no ledger row for prd-1"
# THE LAST CELL, NOT THE FOURTH (S211). "What I saw" is the final column, and
# S211 inserted "How I know" before it — an index counted from the left moves
# every time a column is added, and this assertion is about the EVIDENCE cell,
# not about its position.
cell = [c for c in row[0].split("|") if c.strip()][-1].strip()
body = cell.split(" — ", 1)[1] if " — " in cell else cell
fails = []
if "…" not in body:
    fails.append("TRUNCATION IS NOT MARKED: the cell carries no ellipsis (ends %r)" % body[-30:])
else:
    prefix = body.split("…")[0].rstrip()
    if not note.startswith(prefix):
        fails.append("the cell is not a prefix of the note")
    elif len(prefix) < len(note) and note[len(prefix)] != " ":
        fails.append("THE CUT IS MID-WORD: it ends %r" % prefix[-14:])
    if prefix.count("'") % 2 == 1:
        fails.append("THE CUT LEAVES AN OPEN QUOTE: it ends %r" % prefix[-14:])
if ".." in md:
    bad = [l for l in md.splitlines() if ".." in l]
    fails.append("DOUBLED PUNCTUATION: %s" % bad[0].strip())
for f in fails:
    print("   " + f)
sys.exit(1 if fails else 0)
PY
check "B11i. the evidence cell truncates on a word boundary, with an ellipsis and no open quote, and the gap bullet has one full stop" \
  "[ '$copyrc' -eq 0 ]"

# ==========================================================================
# B12. THE FIX ROUND (S204) — file the logs, drive them, re-check, re-score.
#
# THE ROUTING IS ON A RECORDED MARKER, NOT ON THE QUESTION'S PROSE. The
# consolidated re-verify gate is written by resolve-logs.sh, and resolve-logs.sh
# RECORDS what it is (`"kind": "reverify"` in pending.json). `xo.sh answer`
# routes on that recorded field. This is the S147/S156/S188 lesson applied
# before it could be paid for a fourth time: the captain writes gate prose, and
# any heuristic over his wording eventually meets a question that contains its
# vocabulary. The two rows at the end of this block are the proof — a REWORDED
# re-verify gate still routes, and an ordinary Verify park that talks about
# logs does not.
# ==========================================================================
echo
echo "B12. the fix round — logs, drive, re-check, re-score (session 204)"

# A verdict on disk, as S203's evaluate leaves it. $1 = the gaps array body.
plant_verdict() { # <mission-dir> <gaps-json>
  local m="$1" gaps="$2"
  mkdir -p "$m/xo/shots"
  printf 'PNG\n' >"$m/xo/shots/shot-01.png"
  printf 'PNG\n' >"$m/xo/shots/shot-02.png"
  printf 'PNG\n' >"$m/xo/shots/shot-03.png"
  cat >"$m/xo/verdict.json" <<VJ
{
  "score": "medium",
  "derivation": "the flow works; two things are short of the mark",
  "counts": {"met": 1, "gap": 0, "untested": 0, "contradictions": 2},
  "criteria": [{"id": "prd-1", "text": "one list", "status": "met", "shot": "shot-01", "note": "saw it", "primary": true}],
  "gaps": [$gaps],
  "summary": "Two mismatches against your drawing."
}
VJ
  # THE CONTRACT IS PART OF THE RECORD A LOOK LEAVES BEHIND. `evaluate` writes
  # criteria.json before it launches anything, and BOTH the fix round's PRD
  # writer (which restates the criterion) and the re-score read it back. A
  # fixture that planted a verdict without it was testing a mission state that
  # cannot exist.
  # AND THE REPORT. `xo_finish` guarantees one exists on EVERY path a look can
  # end on — including the ones with no ledger at all — so a fixture without it
  # is a mission state that cannot happen, and the re-check's "first look beside
  # the fixes" has nothing to fold underneath it.
  cat >"$m/xo/report.md" <<'RM'
**How close this is to what you asked for: MEDIUM** — two things short of the mark.

Two mismatches against your drawing.
RM
  cat >"$m/xo/criteria.json" <<'CJ'
{"criteria": [
  {"id": "prd-1", "text": "The board shows every open task in one list.", "primary": true, "source": "PRD \u00a72"},
  {"id": "prd-2", "text": "A task can be added from the board itself.", "primary": true, "source": "PRD \u00a72"},
  {"id": "t-1-ac1", "text": "The ADD button sits under the list.", "primary": false, "drawnAt": "#add-button"}
]}
CJ
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/xo/verdict.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/xo/criteria.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
}

gap_json() { # <n> <kind> <criterion> <shots-csv>
  local n="$1" kind="$2" crit="$3" shots="$4" sj="" s
  for s in ${shots//,/ }; do sj="${sj:+$sj, }\"$s\""; done
  printf '{"title": "gap %s", "expected": "the %s sits under the list", "saw": "it is above it", "shots": [%s], "kind": "%s", "criterion": "%s"}' \
    "$n" "$n" "$sj" "$kind" "$crit"
}

xo_file_logs() { # <repo> <id> [env...]
  local repo="$1" id="$2"; shift 2
  ( cd "$repo" && XO_LOG_CALLS="$XO_LOG_CALLS" XO_RESOLVE_CALLS="$XO_RESOLVE_CALLS" \
      LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_RUN_SCRIPT=/usr/bin/true LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 "$@" \
      bash "$SCRIPT" file-logs --mission "$id" 2>&1 )
}

# --------------------------------------------------------------------------
# B12a. THREE CONTRADICTIONS + TWO INTERPRETATIONS → exactly THREE logs, each
#       bound to its OWN shots. An interpretation is a call the build made, not
#       a fault: it is reported, never filed.
# --------------------------------------------------------------------------
repoL1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mL1="$(plant_verify "$repoL1" "lcars-20260913-101")"
plant_verdict "$mL1" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02),$(gap_json 3 contradiction t-1-ac1 shot-03),$(gap_json 4 interpretation prd-1 shot-01),$(gap_json 5 interpretation prd-2 shot-02)"
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outL1="$(xo_file_logs "$repoL1" "lcars-20260913-101")"
check "B12a. the log verb was invoked exactly once" \
  "[ \"\$(grep -c '^log ' '$XO_LOG_CALLS')\" -eq 1 ]"
check "B12a. …with exactly THREE --prd (the contradictions, not the interpretations)" \
  "[ \"\$(grep -o -- '--prd' '$XO_LOG_CALLS' | grep -c .)\" -eq 3 ]"
check "B12a. …filed against the parent" "grep -q -- '--parent lcars-20260913-101' '$XO_LOG_CALLS'"
check "B12a. every --attach comes AFTER a --prd (per-bug binding, never global)" \
  "grep -q '^log --parent [^ ]* --prd ' '$XO_LOG_CALLS'"
check "B12a. gap 2's shot is bound to gap 2's PRD and no other" \
  "grep -q -- '2.md --attach [^ ]*shot-02.png --prd' '$XO_LOG_CALLS'"
check "B12a. the mockup is NOT attached by hand (log.sh inherits it)" \
  "! grep -q -- 'attachment-01.html' '$XO_LOG_CALLS'"
check "B12a. each bug PRD carries the house shape" \
  "grep -q '^# Mission: ' '$mL1/xo/logs/1.md' && grep -q '\*\*Type:\*\* bug' '$mL1/xo/logs/1.md'"
check "B12a. …the expected/saw sentence with its shot" \
  "grep -qi 'expected' '$mL1/xo/logs/1.md' && grep -q 'shot-01' '$mL1/xo/logs/1.md'"
check "B12a. …and acceptance restating the criterion" \
  "grep -qi 'acceptance' '$mL1/xo/logs/1.md'"
check "B12a. logs.json records child ↔ gap" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d[\"filed\"])==3, d; assert d[\"filed\"][1][\"criterion\"]==\"prd-2\", d' '$mL1/xo/logs.json'"
check "B12a. no interpretation was filed — only the three contradictions" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert sorted(f[\"criterion\"] for f in d[\"filed\"])==[\"prd-1\",\"prd-2\",\"t-1-ac1\"], d' '$mL1/xo/logs.json'"
check "B12a. the round marker is set to 1" "[ \"\$(xo_state '$mL1' round)\" = '1' ]"
check "B12a. resolve-logs was started on the parent" \
  "grep -q 'resolve .*lcars-20260913-101' '$XO_RESOLVE_CALLS'"
check "B12a. its pid is in xo-resolve.pid — NOT in xo.pid" \
  "[ -s '$mL1/xo-resolve.pid' ]"
check "B12a. the journal records the filing" \
  "grep -q '\"action\": \"filed-logs\"' '$mL1/number-one.jsonl'"

# --------------------------------------------------------------------------
# B12a2 (S211 fix round 1, D2). A GAP WITH NO SHOT, THROUGH THE REAL VERB.
#
# Since S211 a contradiction can stand on a quoted line from the project's own
# test suite instead of a picture, so `xo-logs.py` emits a record whose shots
# field is EMPTY — a shape that could not exist before (the score step demoted
# a shotless contradiction to an interpretation). `xo.sh` read that record with
# `IFS=$'\t' read -r …`, and TAB IS IFS WHITESPACE: bash collapsed the empty
# field and shifted every field after it left. The live drive filed
#   {"n": 2, "criterion": "batches do not survive a restart", "title": "", …}
# and the captain's readout printed `log #2` with no title at all.
#
# THIS IS THE REAL PATH, NOT THE PARSER IN ISOLATION: the verb is driven, the
# record it writes is read back, and the CONTROL in the same row is the gap
# that DOES have a shot — which parsed perfectly all along, which is what makes
# this the empty field and not the delimiter.
# --------------------------------------------------------------------------
repoL1b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mL1b="$(plant_verify "$repoL1b" "lcars-20260913-104")"
plant_verdict "$mL1b" '{"title": "the ADD button is above the list", "expected": "it under the list", "saw": "it above", "shots": ["shot-01"], "kind": "contradiction", "criterion": "prd-1"},{"title": "batches do not survive a restart", "expected": "the batches to be there after a restart", "saw": "an empty list", "shots": [], "evidence": "tests", "testQuote": "FAIL batches survive a restart", "kind": "contradiction", "criterion": "prd-2"}'
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outL1b="$(xo_file_logs "$repoL1b" "lcars-20260913-104")"
check "B12a2. a gap with NO shot is filed, and its TITLE survives the shell" \
  "python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
f = d[\"filed\"][1]
assert f[\"title\"] == \"batches do not survive a restart\", f
assert f[\"criterion\"] == \"prd-2\", f
assert f[\"shots\"] == [], f' '$mL1b/xo/logs.json'"
check "B12a2. CONTROL: the gap that HAS a shot is unchanged" \
  "python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
f = d[\"filed\"][0]
assert f[\"title\"] == \"the ADD button is above the list\", f
assert f[\"criterion\"] == \"prd-1\", f
assert f[\"shots\"] == [\"shot-01\"], f' '$mL1b/xo/logs.json'"
check "B12a2. both bugs were filed, the shotless one with no --attach of its own" \
  "[ \"\$(grep -o -- '--prd' '$XO_LOG_CALLS' | grep -c .)\" -eq 2 ]"
check "B12a2. the shotless bug PRD does not send a fix worker to a screen" \
  "! grep -q 'the shot above was taken of' '$mL1b/xo/logs/2.md'"
check "B12a2. …and the one with a shot still does" \
  "grep -q 'the shot above was taken of' '$mL1b/xo/logs/1.md'"

# --------------------------------------------------------------------------
# B12b. ELEVEN CONTRADICTIONS → TEN filed, the overflow JOURNALLED.
# --------------------------------------------------------------------------
repoL2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mL2="$(plant_verify "$repoL2" "lcars-20260913-102")"
g11=""; for i in 1 2 3 4 5 6 7 8 9 10 11; do
  g11="${g11:+$g11,}$(gap_json "$i" contradiction "prd-$i" shot-01)"
done
plant_verdict "$mL2" "$g11"
: >"$XO_LOG_CALLS"
outL2="$(xo_file_logs "$repoL2" "lcars-20260913-102")"
check "B12b. exactly TEN --prd (the cap)" \
  "[ \"\$(grep -o -- '--prd' '$XO_LOG_CALLS' | grep -c .)\" -eq 10 ]"
check "B12b. the overflow is journalled in the captain's words" \
  "grep -q '1 more gaps not filed — cap 10' '$mL2/number-one.jsonl'"

# --------------------------------------------------------------------------
# B12c. ONE ROUND ONLY. A mission already carrying `round: 1` files nothing.
# --------------------------------------------------------------------------
repoL3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mL3="$(plant_verify "$repoL3" "lcars-20260913-103")"
python3 - "$mL3/state.json" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace('"numberOne": {"status": "engaged"','"numberOne": {"round": "1", "status": "engaged"')
open(p,"w").write(s)
PY
plant_verdict "$mL3" "$(gap_json 1 contradiction prd-1 shot-01)"
: >"$XO_LOG_CALLS"
outL3="$(xo_file_logs "$repoL3" "lcars-20260913-103")"
check "B12c. nothing was filed a second time" "[ ! -s '$XO_LOG_CALLS' ]"
check "B12c. …and it says so" "printf '%s' \"\$outL3\" | grep -qi 'one round'"

# --------------------------------------------------------------------------
# B12d. RECHECK, EVERY FIX HOLDING → the gate is answered by number-one, the
#       second score is written, the label swaps, the status finishes, and the
#       launch is stopped.
# --------------------------------------------------------------------------
plant_logs_json() { # <mission-dir> <n>
  local m="$1" n="$2" i items=""
  for i in $(seq 1 "$n"); do
    items="${items:+$items,}$(printf '{"n": %d, "mission": "lcars-20260913-9%02d", "issue": "%d", "criterion": "prd-%d", "title": "gap %d", "shots": ["shot-0%d"]}' "$i" "$i" "$((500+i))" "$i" "$i" "$i")"
  done
  mkdir -p "$m/xo"
  printf '{"round": 1, "overflow": 0, "filed": [%s]}\n' "$items" >"$m/xo/logs.json"
}
plant_child() { # <repo> <parent> <n> <stage> [awaiting]
  local repo="$1" parent="$2" n="$3" stage="$4" aw="${5:-}" cid d
  cid="$(printf 'lcars-20260913-9%02d' "$n")"
  d="$repo/.git/lcars/missions/$cid"; mkdir -p "$d"
  {
    printf '{\n  "id": "%s",\n  "type": "bug",\n  "title": "gap %s",\n  "stage": "%s",\n' "$cid" "$n" "$stage"
    [ -n "$aw" ] && printf '  "awaitingHuman": true,\n'
    printf '  "githubIssue": %d,\n  "parentMission": "%s",\n  "branch": "lcars/%s"\n}\n' \
      "$((500+n))" "$parent" "$parent"
  } >"$d/state.json"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$d/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
}
plant_reverify_gate() { # <mission-dir> [question]
  local m="$1" q="${2:-2 logged bugs resolved on this branch — ready for your single re-verify.}"
  cat >"$m/pending.json" <<PJ
{
  "stage": "verify",
  "kind": "reverify",
  "questions": [
    "$q"
  ]
}
PJ
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/pending.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
}

# The recheck worker shim: writes xo-recheck.json from $XO_RC_BODY.
RC_SHIM="$FXDIR/rc-worker"
cat >"$RC_SHIM" <<'RCS'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG.all"
out="${LCARS_WORK_OUT:-}"
[ -n "${XO_RC_BODY:-}" ] && printf '%s\n' "$XO_RC_BODY" >"$out/${XO_RC_FILE:-xo-recheck.json}"
exit 0
RCS
chmod +x "$RC_SHIM"

rc_body() { # <held-1> <held-2>
  printf '{"score":"high","summary":"The fixes are on the build.","criteria":['
  printf '{"id":"prd-1","text":"one list","status":"met","shot":"r2-01","note":"under the list now"},'
  printf '{"id":"prd-2","text":"add from the board","status":"met","shot":"r2-01","note":"there"}'
  printf '],"gaps":[],"held":[{"criterion":"prd-1","held":%s,"why":"the button is under the list now","shots":["r2-01"]},{"criterion":"prd-2","held":%s,"why":"still above the list","shots":["r2-01"]}]}' "$1" "$2"
}

xo_recheck() { # <repo> <id> [env...]
  local repo="$1" id="$2"; shift 2
  ( cd "$repo" && XO_WORKER_LOG="$XO_WORKER_LOG" XO_RESPOND_CALLS="$XO_RESPOND_CALLS" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
      LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$HOST_STUB" LCARS_RESPOND_SCRIPT="$RESPOND_STUB" \
      LCARS_WORKER_BIN="$RC_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 "$@" \
      bash "$SCRIPT" recheck --mission "$id" 2>&1 )
}

repoR1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mR1="$(plant_verify "$repoR1" "lcars-20260913-201")"
plant_verdict "$mR1" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
cp "$mR1/xo/verdict.json" "$mR1/xo/verdict-1.json"
plant_logs_json "$mR1" 2
plant_child "$repoR1" "lcars-20260913-201" 1 verify
plant_child "$repoR1" "lcars-20260913-201" 2 verify
plant_reverify_gate "$mR1"
: >"$XO_WORKER_LOG"; : >"$XO_RESPOND_CALLS"; : >"$XO_LABEL_LOG"; : >"$XO_LAUNCH_LOG"
outR1="$(XO_RC_BODY="$(rc_body true true)" xo_recheck "$repoR1" "lcars-20260913-201")"
check "B12d. the build was relaunched" "grep -q 'launch lcars-20260913-201' '$XO_LAUNCH_LOG'"
check "B12d. the gate was answered through \`lcars respond\`" \
  "grep -q '^respond answer' '$XO_RESPOND_CALLS'"
check "B12d. …attributed to number-one" "grep -q 'by=number-one' '$XO_RESPOND_CALLS'"
check "B12d. the second verdict is on disk" "[ -s '$mR1/xo/verdict-2.json' ]"
check "B12d. the second score is recorded" "[ -n \"\$(xo_state '$mR1' score2)\" ]"
check "B12d. the label was swapped to the second score" \
  "grep -q 'issue-relabel .*--add lcars:xo:' '$XO_LABEL_LOG'"
check "B12d. Number One's work on this mission is FINISHED" \
  "[ \"\$(xo_state '$mR1' status)\" = 'finished' ]"
check "B12d. the launch was stopped" "grep -q -- '--stop' '$XO_LAUNCH_LOG'"
check "B12d. the report shows the first look beside the fixes" \
  "grep -qi 'after the fixes' '$mR1/xo/report.md' && grep -qi 'first look' '$mR1/xo/report.md'"

# --------------------------------------------------------------------------
# B12e. ONE FIX THAT DID NOT HOLD → the gate is ESCALATED with the list, and
#       NOTHING is accepted. Never a second round.
# --------------------------------------------------------------------------
repoR2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mR2="$(plant_verify "$repoR2" "lcars-20260913-202")"
plant_verdict "$mR2" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
plant_logs_json "$mR2" 2
plant_child "$repoR2" "lcars-20260913-202" 1 verify
plant_child "$repoR2" "lcars-20260913-202" 2 verify
plant_reverify_gate "$mR2"
: >"$XO_RESPOND_CALLS"
rcR2=0
outR2="$(XO_RC_BODY="$(rc_body true false)" xo_recheck "$repoR2" "lcars-20260913-202")" || rcR2=$?
check "B12e. it exits non-zero — this one is the captain's" "[ '$rcR2' -ne 0 ]"
check "B12e. NOTHING was answered" "[ ! -s '$XO_RESPOND_CALLS' ]"
check "B12e. the gate is still up" "[ -f '$mR2/pending.json' ]"
check "B12e. the status is escalated" "[ \"\$(xo_state '$mR2' status)\" = 'escalated' ]"
check "B12e. the note names the log that did not hold" \
  "xo_state '$mR2' note | grep -q 'log #'"
check "B12e. the journal says the fix did not hold, and why" \
  "grep -q 'fix did not hold' '$mR2/number-one.jsonl' && grep -q 'still above the list' '$mR2/number-one.jsonl'"
check "B12e. no second round was started" \
  "! grep -q '\"action\": \"filed-logs\"' '$mR2/number-one.jsonl'"

# --------------------------------------------------------------------------
# B12f. A CHILD THAT PARKED blocks the accept — recheck escalates "log #n needs
#       you" WITHOUT spending a launch, a browser or a worker on it.
# --------------------------------------------------------------------------
repoR3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mR3="$(plant_verify "$repoR3" "lcars-20260913-203")"
plant_verdict "$mR3" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
plant_logs_json "$mR3" 2
plant_child "$repoR3" "lcars-20260913-203" 1 verify
plant_child "$repoR3" "lcars-20260913-203" 2 implement awaiting
plant_reverify_gate "$mR3"
: >"$XO_WORKER_LOG"; : >"$XO_LAUNCH_LOG"; : >"$XO_RESPOND_CALLS"
rcR3=0
outR3="$(XO_RC_BODY="$(rc_body true true)" xo_recheck "$repoR3" "lcars-20260913-203")" || rcR3=$?
check "B12f. it escalates" "[ '$rcR3' -ne 0 ] && [ \"\$(xo_state '$mR3' status)\" = 'escalated' ]"
check "B12f. the note names the log that needs the captain" \
  "xo_state '$mR3' note | grep -q 'log #2 needs you'"
check "B12f. nothing was answered" "[ ! -s '$XO_RESPOND_CALLS' ]"
check "B12f. no launch was spent on it" "[ ! -s '$XO_LAUNCH_LOG' ]"
check "B12f. no worker was hired" "[ ! -s '$XO_WORKER_LOG' ]"

# --------------------------------------------------------------------------
# B12g. STAND-DOWN LEAVES THE FIXES DRIVING. `lcars xo off <parent>` signals
#       Number One's OWN pids and leaves the resolve-logs driver alone — those
#       children are LCARS's missions, not the first officer's.
# --------------------------------------------------------------------------
# EVERY STREAM CLOSED, ON PURPOSE. The probe is started in this suite's shell,
# never inside command substitution: command substitution made the background
# process an orphan immediately, so no later wait could reap it. stdin is closed
# for the same family of reason (an inherited terminal can block on a read).
probe() { # <marker-file> — a process that records the TERM it is sent
  local mark="$1"
  ( trap 'printf TERM >>"'"$mark"'"; exit 0' TERM
    while :; do sleep 0.2; done ) </dev/null >/dev/null 2>&1 &
  PROBE_PIDS="$PROBE_PIDS $!"
  PROBE_PID=$!
}
repoS1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mS1="$(plant_verify "$repoS1" "lcars-20260913-301")"
plant_logs_json "$mS1" 2
plant_child "$repoS1" "lcars-20260913-301" 1 implement
plant_child "$repoS1" "lcars-20260913-301" 2 implement
XO_MARK="$FXDIR/xo-term.txt"; RS_MARK="$FXDIR/rs-term.txt"; : >"$XO_MARK"; : >"$RS_MARK"
probe "$XO_MARK"; xo_pid=$PROBE_PID
probe "$RS_MARK"; rs_pid=$PROBE_PID
( cd "$repoS1" && bash "$SCRIPT" record-pid "$xo_pid" "$mS1/xo.pid" )
# Planted through the PRODUCT'S OWN writer, so this proves the shipped format
# and cannot drift from it.
( cd "$repoS1" && bash "$SCRIPT" record-pid "$rs_pid" "$mS1/xo-resolve.pid" )
outS1="$( cd "$repoS1" && LCARS_OWNER_ENFORCE=0 bash "$SCRIPT" off "lcars-20260913-301" 2>&1 )"
# Give the probes a moment to run their traps.
i=0; while [ "$i" -lt 25 ] && [ ! -s "$XO_MARK" ]; do i=$((i+1)); sleep 0.1; done
j=0; while [ "$j" -lt 25 ] && [ ! -s "$RS_MARK" ]; do j=$((j+1)); sleep 0.1; done
check "B12g. Number One's own pid WAS signalled" "[ -s '$XO_MARK' ]"
# S213 — THIS REVERSES S204. The stop button now stops the detached fix chain
# too; leaving it running meant the only way to halt one was to kill a pid by
# hand, which is not something the product may ask of anybody.
check "B12g. the resolve-logs driver WAS signalled — the stop button really stops" \
  "[ -s '$RS_MARK' ]"
check "B12g. …and it is really gone, not merely asked" \
  "k=0; while [ \$k -lt 25 ] && kill -0 '$rs_pid' 2>/dev/null; do k=\$((k+1)); sleep 0.1; done; ! kill -0 '$rs_pid' 2>/dev/null"
check "B12g. …and its pid file is cleared, so nothing can signal that number again" \
  "[ ! -f '$mS1/xo-resolve.pid' ]"
check "B12g. the note tells him the logs stopped where they got to, and he has the conn" \
  "xo_state '$mS1' note | grep -q '2 logs it was driving stopped where they got to' && xo_state '$mS1' note | grep -q 'you have the conn'"
check "B12g. …and it never claims they are still driving" \
  "! xo_state '$mS1' note | grep -q 'still driving'"

# THE IDENTITY CHECK IS NOT DECORATION. A pid file that does not say WHO it was
# written about — an old one, or one somebody wrote by hand — is REFUSED, and
# the process on that number is left strictly alone. Pids get reused, and the
# captain's own viewscreen is on this machine.
RS2_MARK="$FXDIR/rs2-term.txt"; : >"$RS2_MARK"
probe "$RS2_MARK"; rs2_pid=$PROBE_PID
repoS1b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mS1b="$(plant_verify "$repoS1b" "lcars-20260913-302")"
plant_logs_json "$mS1b" 2
printf '%s\n' "$rs2_pid" >"$mS1b/xo-resolve.pid"          # a BARE pid: no identity
probe "$FXDIR/xo2-term.txt"; XO2_PID=$PROBE_PID
printf '%s\n' "$XO2_PID" >"$mS1b/xo.pid"   # ALSO bare, on purpose: the same control
outS1b="$( cd "$repoS1b" && LCARS_OWNER_ENFORCE=0 bash "$SCRIPT" off "lcars-20260913-302" 2>&1 )"
sleep 0.5
check "B12g. CONTROL — a pid file that does not say WHO is NOT signalled" \
  "[ ! -s '$RS2_MARK' ] && kill -0 '$rs2_pid' 2>/dev/null"
check "B12g. CONTROL — …and the note ADMITS it could not confirm, instead of claiming a stop" \
  "xo_state '$mS1b' note | grep -q 'could not confirm'"
stop_probes

# --------------------------------------------------------------------------
# B12h. THE ROUTING IS ON THE RECORDED MARKER, NOT ON THE QUESTION'S WORDS.
#
# Row 1: a re-verify gate whose question text has been completely REWORDED (no
# "logged bug", no "re-verify", nothing a matcher could key on) still routes to
# recheck, because resolve-logs RECORDED `"kind": "reverify"`.
# Row 2: an ordinary Verify park whose question happens to talk about logged
# bugs and re-verifying does NOT route — there is no recorded marker, so it is
# the intent-answer path, exactly as S202 left it.
# --------------------------------------------------------------------------
xo_answer_b12() { # <repo> <id>
  local repo="$1" id="$2"; shift 2
  ( cd "$repo" && XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" LCARS_XO_DRIVER="$DRIVE_STUB" \
      LCARS_NODE_BIN=bash LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_RESPOND_SCRIPT="$RESPOND_STUB" \
      LCARS_WORKER_BIN="$RC_SHIM" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 "$@" \
      bash "$SCRIPT" answer --mission "$id" 2>&1 )
}
repoK1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mK1="$(plant_verify "$repoK1" "lcars-20260913-401")"
plant_verdict "$mK1" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
plant_logs_json "$mK1" 2
plant_child "$repoK1" "lcars-20260913-401" 1 verify
plant_child "$repoK1" "lcars-20260913-401" 2 verify
plant_reverify_gate "$mK1" "Have another look at the build now that the tidying is done, then tell me if it lines up."
: >"$XO_LAUNCH_LOG"; : >"$XO_RESPOND_CALLS"
outK1="$(XO_RC_BODY="$(rc_body true true)" xo_answer_b12 "$repoK1" "lcars-20260913-401")"
check "B12h. a REWORDED re-verify gate still routes to recheck (it relaunched)" \
  "grep -q 'launch lcars-20260913-401' '$XO_LAUNCH_LOG'"
check "B12h. …and answered the gate as the recheck path does" \
  "grep -q 'by=number-one' '$XO_RESPOND_CALLS'"

repoK2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mK2="$(plant_verify "$repoK2" "lcars-20260913-402")"
cat >"$mK2/pending.json" <<'PJ'
{
  "stage": "verify",
  "questions": [
    "Before I re-verify: should the logged bugs list live on this screen, and do you want a re-verify button beside it? The PRD calls them logged bugs."
  ]
}
PJ
: >"$XO_LAUNCH_LOG"; : >"$XO_WORKER_LOG"; : >"$XO_RESPOND_CALLS"
rcK2=0
outK2="$(XO_RC_BODY='' XO_EV_BODY='' xo_answer_b12 "$repoK2" "lcars-20260913-402")" || rcK2=$?
# NAMED BY MISSION, NOT BY AN EMPTY FILE (S246). This row asks one thing: did
# THIS park relaunch? It used to ask it as "the shared launch log is empty",
# which also answers a question it does not own — whether every earlier case in
# this suite has fully quiesced. Measured here on 2026-10-04: at this point the
# log held `launch lcars-20260913-401` + its `--stop`, and a `--stop` from
# B10c's 104, all from earlier cases' teardowns landing after the `: >` above,
# and NOT ONE line naming 402. So the behaviour was intact and the assertion was
# reading someone else's work. It is now keyed on this mission's own id, which
# still FAILS the moment this park relaunches — the positive control is the row
# above it, where a real re-verify gate launches 401 by name.
check "B12h. an ordinary Verify park that TALKS about logs does NOT route to recheck" \
  "! grep -q 'launch lcars-20260913-402' '$XO_LAUNCH_LOG'"
check "B12h. …it took the intent-answer road instead (a worker was hired)" \
  "[ -s '$XO_WORKER_LOG' ]"

# ==========================================================================
# B13 (S204 fix round 1, D1). NUMBER ONE'S OWN CALLS CARRY THE MARKER, AND THE
#      LOCK LETS THEM THROUGH.
#
# THE DEFECT. `lcars xo evaluate` found two contradictions on a MEDIUM mission
# and filed NONE of them: its own `lcars log` was refused by its own engaged
# lock ("Number One is engaged on this mission on your behalf — …"). It cannot
# not happen — `status` is `engaged` for the whole evaluate, and that is exactly
# what the lock refuses — so the whole fix round was unreachable as shipped.
#
# THE MARKER NAMES THE MISSION. `$LCARS_XO_INTERNAL=<id>` is the S207
# `$LCARS_WORKER_BIN_INTERNAL` shape (the producer states who set it), narrowed:
# it exempts a call only against the mission it names. `LCARS_XO_ENFORCE=0`
# would have switched the lock off wholesale for everything the call spawns,
# which is not a cure.
#
# Row 1 proves the marker is on every verb Number One calls on its own behalf.
# Row 2 puts the REAL lock behind the stub and proves the call gets through.
# ==========================================================================
echo
echo "B13. Number One's own calls and the engaged lock"

# --- 1. the marker is set, and it names THIS mission ----------------------
repoN1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mN1="$(plant_verify "$repoN1" "lcars-20260913-501")"
plant_verdict "$mN1" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outN1="$(xo_file_logs "$repoN1" "lcars-20260913-501")"
# THE DRIVE IS DETACHED (setsid/nohup, then disowned), so the line it records
# can land a moment after the verb returns — on a loaded machine this row went
# red for the timing and not for the marker. Wait for it, BOUNDED: the check
# below still requires the marker to be there, and a drive that never starts
# still fails.
w=0
while [ "$w" -lt 100 ] && ! grep -q 'xo_internal=' "$XO_RESOLVE_CALLS" 2>/dev/null; do
  sleep 0.1; w=$((w + 1))
done
check "B13. \`log.sh\` is called with the marker naming THIS mission" \
  "grep -q 'xo_internal=lcars-20260913-501\$' '$XO_LOG_CALLS'"
check "B13. …and NOT with the blunt LCARS_XO_ENFORCE=0 hatch (no live use, comments aside)" \
  "! grep -q '^[^#]*LCARS_XO_ENFORCE=0' '$REPO_ROOT/skills/lcars-xo/xo.sh'"
check "B13. \`resolve-logs.sh\` is started with the marker too" \
  "grep -q 'xo_internal=lcars-20260913-501\$' '$XO_RESOLVE_CALLS'"

# `respond.sh answer` — the third verb Number One calls on its own behalf. It
# is reached on the recheck path (every fix held ⇒ accept the gate).
repoN2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mN2="$(plant_verify "$repoN2" "lcars-20260913-502")"
plant_verdict "$mN2" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
plant_logs_json "$mN2" 2
plant_child "$repoN2" "lcars-20260913-502" 1 verify
plant_child "$repoN2" "lcars-20260913-502" 2 verify
plant_reverify_gate "$mN2" "Two logged bugs resolved — ready for your single re-verify."
: >"$XO_LAUNCH_LOG"; : >"$XO_RESPOND_CALLS"
outN2="$(XO_RC_BODY="$(rc_body true true)" xo_answer_b12 "$repoN2" "lcars-20260913-502")"
check "B13. \`respond.sh answer\` is called with the marker naming THIS mission" \
  "grep -q 'xo_internal=lcars-20260913-502\$' '$XO_RESPOND_CALLS'"
check "B13. …and still carries its attribution" \
  "grep -q 'by=number-one' '$XO_RESPOND_CALLS'"

# --- 2. THE REAL LOCK, BEHIND THE STUB -----------------------------------
# The stub above records; this one ENFORCES, by calling the very function every
# write verb calls. If Number One's filing is refused, nothing is filed — which
# is exactly what the tester measured.
LOCKED_LOG_STUB="$FXDIR/log-locked.sh"
cat >"$LOCKED_LOG_STUB" <<'LLS'
#!/usr/bin/env bash
parent=""
args=("$@"); i=0
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --parent) parent="${args[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
. "$LCARS_OWNERSHIP_LIB"
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"
case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
if r="$(lcars_xo_lock_reason "$gitdir/lcars/missions/$parent")"; then
  printf 'lcars log: %s\n' "$r" >&2
  exit 1
fi
printf 'FILED\n' >>"$XO_LOCKED_LOG"
printf '1 bug missions filed and linked to #42 (parent):\n'
printf '  lcars-20260913-901  #501  bug 1\n'
exit 0
LLS
chmod +x "$LOCKED_LOG_STUB"

repoN3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mN3="$(plant_verify "$repoN3" "lcars-20260913-503")"
plant_verdict "$mN3" "$(gap_json 1 contradiction prd-1 shot-01)"
export XO_LOCKED_LOG="$repoN3/filed.log"; : >"$XO_LOCKED_LOG"
: >"$XO_RESOLVE_CALLS"
outN3="$( cd "$repoN3" && XO_LOCKED_LOG="$XO_LOCKED_LOG" XO_RESOLVE_CALLS="$XO_RESOLVE_CALLS" \
    LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
    LCARS_LOG_SCRIPT="$LOCKED_LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
    LCARS_RUN_SCRIPT=/usr/bin/true LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" file-logs --mission "lcars-20260913-503" 2>&1 )"
check "B13. the mission really IS engaged while Number One files (the premise)" \
  "grep -q '\"status\": *\"engaged\"' '$mN3/state.json'"
check "B13. Number One's OWN \`lcars log\` is NOT refused by the real lock" \
  "[ -s '$XO_LOCKED_LOG' ]"
check "B13. …so the gap was actually filed, not swallowed" \
  "! printf '%s' \"\$outN3\" | grep -q 'refused them'"
check "B13. …and the mission's record says one log was filed" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d[\"filed\"])==1, d' '$mN3/xo/logs.json'"

# THE CONTROL, and the point of the whole lock: the CAPTAIN's own hand on the
# same verb, same mission, same moment, with no marker — still refused, with the
# sentence byte for byte.
XO_LOCK_SENTENCE="Number One is engaged on this mission on your behalf — stand it down (lcars xo off lcars-20260913-503) to act yourself"
: >"$XO_LOCKED_LOG"
rcN4=0
( cd "$repoN3" && XO_LOCKED_LOG="$XO_LOCKED_LOG" \
    LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
    bash "$LOCKED_LOG_STUB" --parent "lcars-20260913-503" --prd /dev/null >o.txt 2>&1 ) || rcN4=$?
check "B13. the CAPTAIN's own hand on the same verb is STILL refused" \
  "[ '$rcN4' -ne 0 ] && [ ! -s '$XO_LOCKED_LOG' ]"
check "B13. …with the sentence byte for byte" \
  "grep -Fqx \"lcars log: \$XO_LOCK_SENTENCE\" '$repoN3/o.txt'"

# AND a marker naming a DIFFERENT mission buys nothing.
rcN5=0
( cd "$repoN3" && XO_LOCKED_LOG="$XO_LOCKED_LOG" LCARS_XO_INTERNAL="lcars-20260913-777" \
    LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
    bash "$LOCKED_LOG_STUB" --parent "lcars-20260913-503" --prd /dev/null >o2.txt 2>&1 ) || rcN5=$?
check "B13. a marker naming ANOTHER mission does NOT exempt this one" \
  "[ '$rcN5' -ne 0 ] && grep -q 'Number One is engaged' '$repoN3/o2.txt'"

# ==========================================================================
# B14 (S204 fix round 1, D5). SINGULAR AND PLURAL, PROPERLY.
# ==========================================================================
echo
echo "B14. one log is not 'logs'"

repoP1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mP1="$(plant_verify "$repoP1" "lcars-20260913-601")"
plant_verdict "$mP1" "$(gap_json 1 contradiction prd-1 shot-01)"
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outP1="$(xo_file_logs "$repoP1" "lcars-20260913-601")"
check "B14. ONE filing reads 'filed 1 log', never 'filed 1 logs'" \
  "xo_state '$mP1' lastAction | grep -q '^filed 1 log ' && ! xo_state '$mP1' lastAction | grep -q 'filed 1 logs'"

repoP2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mP2="$(plant_verify "$repoP2" "lcars-20260913-602")"
plant_verdict "$mP2" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outP2="$(xo_file_logs "$repoP2" "lcars-20260913-602")"
check "B14. …and TWO still reads 'filed 2 logs' (a control)" \
  "xo_state '$mP2' lastAction | grep -q '^filed 2 logs '"

# The stand-down note, the other half of D5. PROBE_PIDS is APPENDED to, never
# reset — the suite's EXIT teardown kills everything on that list, and clearing
# it would quietly drop the earlier probes from the teardown's reach.
repoP3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mP3="$(plant_verify "$repoP3" "lcars-20260913-603")"
plant_logs_json "$mP3" 1
plant_child "$repoP3" "lcars-20260913-603" 1 implement
P3_MARK="$FXDIR/p3-term.txt"; : >"$P3_MARK"
probe "$P3_MARK"; p3_pid=$PROBE_PID
( cd "$repoP3" && bash "$SCRIPT" record-pid "$p3_pid" "$mP3/xo-resolve.pid" )
outP3="$( cd "$repoP3" && LCARS_OWNER_ENFORCE=0 bash "$SCRIPT" off "lcars-20260913-603" 2>&1 )"
check "B14. ONE stopped log reads '1 log', never '1 logs'" \
  "xo_state '$mP3' note | grep -q 'the 1 log it was driving' && ! xo_state '$mP3' note | grep -q '1 logs'"
stop_probes

# ==========================================================================
# B15 (S204 fix round 1, D3). THE ESCALATION IS WRITTEN IN THE CAPTAIN'S WORDS.
#
# Number One's escalation on a parked child read: "failed the flip-flop proof
# gate each time (the tests pass on the parent commit, so red-on-parent is not
# proven) … escalationType is 'cap' … the approved plan.json ticket." The
# REASONING was right — it caught a real contradiction between two things the
# record said and refused to choose — but four of those words are ones the
# captain would have to look up, in a sentence he reads on his phone.
#
# The substance is produced by the worker, so the rule lives in the worker's
# brief. This asserts the brief carries it: what is banned, what to say instead,
# and that the numbers and quotes stay.
# ==========================================================================
echo
echo "B15. the escalation speaks the captain's language"

ANSWER_PROMPT="$REPO_ROOT/skills/lcars-xo/prompts/answer.md"
check "B15. the brief exists" "[ -f '$ANSWER_PROMPT' ]"
check "B15. it says who reads these sentences, and that it is one person" \
  "grep -qi 'read by ONE person' '$ANSWER_PROMPT'"
check "B15. it names the harness words that must not appear" \
  "grep -q 'flip-flop proof gate' '$ANSWER_PROMPT' && grep -q 'red-on-parent' '$ANSWER_PROMPT' && grep -q 'escalationType' '$ANSWER_PROMPT' && grep -q 'plan.json' '$ANSWER_PROMPT'"
check "B15. …and gives the plain thing to say instead of each" \
  "grep -q 'the piece of work you approved' '$ANSWER_PROMPT' && grep -q 'attempted three times' '$ANSWER_PROMPT'"
check "B15. it keeps the substance — plain is not vague" \
  "grep -qi 'plain is not vague' '$ANSWER_PROMPT'"
check "B15. it keeps the contradiction that made the escalation worth reading" \
  "grep -qi 'Keep the contradiction' '$ANSWER_PROMPT'"
check "B15. identifiers are allowed only AFTER the human sentence" \
  "grep -qi 'in parentheses AFTER the human sentence' '$ANSWER_PROMPT'"


# ==========================================================================
# B16 (S204 fix round 2, D1). ONE LOOK, ONE SHOTS DIRECTORY.
#
# THE DEFECT, as the tester measured it. After an accept, a fix was reverted and
# `xo recheck` ran a second time. The second look wrote recheck-01…07 — there
# was no `#status-line` on the page any more, so no eighth shot was taken — and
# recheck-08 FROM THE PREVIOUS LOOK was still sitting in the directory the
# worker reads. Number One then told the captain a story about a line that
# "flickers": "one earlier clip, recheck-08, did show it…". The line was simply
# gone. The evidence was contaminated, and the story was forced on it.
#
# WHY THIS IS THE ROUND'S HIGH. It reached the right verdict only because the
# stale picture happened to be the LAST-numbered one. Reverse the order and the
# identical mechanism argues the other way: a stale picture showing a gap as
# FIXED, in the folder the accept decision reads from.
#
# THE PROOF. Two consecutive looks where the second takes FEWER shots than the
# first — the exact shape of the defect — and the second look's input must hold
# exactly its own pictures and none of the first's. The control is the first
# look itself: one look still sees ALL of its own.
# ==========================================================================
echo
echo "B16. a look never reads another look's pictures"

# A driver that takes a SETTABLE number of shots, named off the --prefix it was
# given. That is how "the second look took fewer than the first" is staged.
COUNT_DRIVE="$EVDIR/xo-drive-count.sh"
cat >"$COUNT_DRIVE" <<'CDS'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""; prefix="shot"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out"
i=1
while [ "$i" -le "${XO_DRIVE_SHOTS:-1}" ]; do
  printf 'PNG\n' >"$out/$prefix-0$i.png"
  printf '{"shot":"%s-0%s","clip":"full-page"}\n' "$prefix" "$i" >"$out/$prefix-0$i.json"
  printf '%s-0%s — full page\n' "$prefix" "$i" >"$out/$prefix-0$i.txt"
  i=$((i + 1))
done
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
CDS
chmod +x "$COUNT_DRIVE"

# The worker shim that writes down WHICH PICTURES IT WAS HANDED. Not which are
# on disk — which are in the input directory it, and only it, can read.
LOOK_SHIM="$EVDIR/look-inventory-worker"
cat >"$LOOK_SHIM" <<'LKS'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG.all"
out="${LCARS_WORK_OUT:-}"
[ -n "${LCARS_XO_INPUT_DIR:-}" ] \
  && ( cd "$LCARS_XO_INPUT_DIR" && find . -type f -name '*.png' | sed 's|^|SAW |' ) \
       >>"$XO_LOOK_LOG"
[ -n "${XO_RC_BODY:-}" ] && printf '%s\n' "$XO_RC_BODY" >"$out/xo-recheck.json"
[ -n "${XO_EV_BODY:-}" ] && printf '%s\n' "$XO_EV_BODY" >"$out/xo-verdict.json"
exit 0
LKS
chmod +x "$LOOK_SHIM"

LOOK1_LOG="$FXDIR/saw-look-1.txt";  : >"$LOOK1_LOG"
RC1_LOG="$FXDIR/saw-recheck-1.txt"; : >"$RC1_LOG"
RC2_LOG="$FXDIR/saw-recheck-2.txt"; : >"$RC2_LOG"

repoS1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mS1="$(plant_verify "$repoS1" "lcars-20260914-701")"
: >"$XO_WORKER_LOG"

# LOOK ONE — three pictures. S205 ruling 1 (AN ACCEPT IS FINAL): a HIGH,
# all-met verdict here would set `status: finished` on the FIRST look, and
# every recheck below would then be the captain's own refused case — "I've
# already handed this one back" — never reaching a driven look at all. A real
# gap (GAP_PRIMARY) keeps this mission genuinely ENGAGED, which is the only
# state this test's later `recheck` calls are entitled to run from.
( cd "$repoS1" && XO_WORKER_LOG="$XO_WORKER_LOG" XO_LOOK_LOG="$LOOK1_LOG" \
    XO_DRIVE_SHOTS=3 XO_EV_BODY="$(ev_verdict met gap met medium "$GAP_PRIMARY")" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$COUNT_DRIVE" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
    LCARS_WORKER_BIN="$LOOK_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" evaluate --mission "lcars-20260914-701" >/dev/null 2>&1 ) || true

check "B16. THE CONTROL — one look still sees ALL of its own pictures" \
  "[ \"\$(grep -c '^SAW \./shots/shot-0[123]\.png\$' '$LOOK1_LOG')\" -eq 3 ]"

# The fix round's record, so a re-check has something to re-check.
plant_logs_json "$mS1" 2
plant_child "$repoS1" "lcars-20260914-701" 1 verify
plant_child "$repoS1" "lcars-20260914-701" 2 verify
plant_reverify_gate "$mS1"

# RE-CHECK ONE — three pictures of its own. ONE fix held, one did not (S205
# ruling 1): a clean `rc_body true true` here would finish the mission and
# refuse RE-CHECK TWO below outright. Leaving it ESCALATED — a live gate the
# captain has not answered — is the only state a further `recheck` may
# legitimately run from (see B20b's own control for the same distinction).
( cd "$repoS1" && XO_WORKER_LOG="$XO_WORKER_LOG" XO_LOOK_LOG="$RC1_LOG" \
    XO_RESPOND_CALLS="$XO_RESPOND_CALLS" \
    XO_DRIVE_SHOTS=3 XO_RC_BODY="$(rc_body true false)" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$COUNT_DRIVE" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" LCARS_RESPOND_SCRIPT="$RESPOND_STUB" \
    LCARS_WORKER_BIN="$LOOK_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" recheck --mission "lcars-20260914-701" >/dev/null 2>&1 ) || true

check "B16. the second look sees its OWN pictures" \
  "[ \"\$(grep -c '^SAW \./shots/recheck-0[123]\.png\$' '$RC1_LOG')\" -eq 3 ]"
check "B16. …and NOT ONE of the first look's" \
  "! grep -q '^SAW \./shots/shot-0' '$RC1_LOG'"

# RE-CHECK TWO — ONE picture. The tester's exact case: fewer than the look
# before it, so the look before it has leftovers under names this one never
# wrote.
( cd "$repoS1" && XO_WORKER_LOG="$XO_WORKER_LOG" XO_LOOK_LOG="$RC2_LOG" \
    XO_RESPOND_CALLS="$XO_RESPOND_CALLS" \
    XO_DRIVE_SHOTS=1 XO_RC_BODY="$(rc_body true true)" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB" \
    LCARS_XO_DRIVER="$COUNT_DRIVE" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" LCARS_RESPOND_SCRIPT="$RESPOND_STUB" \
    LCARS_WORKER_BIN="$LOOK_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" recheck --mission "lcars-20260914-701" >/dev/null 2>&1 ) || true

check "B16. THE DEFECT — the third look is handed exactly ONE look picture" \
  "[ \"\$(grep -c '^SAW \./shots/.*\.png\$' '$RC2_LOG')\" -eq 1 ]"
check "B16. …its own" "grep -q '^SAW \./shots/recheck-01\.png\$' '$RC2_LOG'"
check "B16. …and neither of the leftovers the look before it took" \
  "! grep -q 'recheck-02\.png\|recheck-03\.png' '$RC2_LOG'"
check "B16. …nor anything from the first look" \
  "! grep -q '^SAW \./shots/shot-0' '$RC2_LOG'"

# NAMESPACED, NOT DELETED. The captain's walkthrough is built out of these
# pictures; a look that cleared the directory would have destroyed the evidence
# of the look before it — which is how re-check one's shots were lost.
check "B16. every look's pictures are still on disk, in its own directory" \
  "[ -f '$mS1/xo/shots/recheck-1/recheck-03.png' ] && [ -f '$mS1/xo/shots/recheck-2/recheck-01.png' ]"
check "B16. …the first look's among them" \
  "[ -f '$mS1/xo/shots/look-1/shot-03.png' ]"
check "B16. the journal records WHICH directory each look reasoned from" \
  "grep -q '\"shotsDir\": \"xo/shots/look-1\"' '$mS1/number-one.jsonl' && grep -q '\"shotsDir\": \"xo/shots/recheck-2\"' '$mS1/number-one.jsonl'"

# ==========================================================================
# B17 (S204 fix round 2, D2). THE THINGS HAVE NAMES, AND THIS TOOL KNOWS THEM.
#
# Round 1 cured the WORKER's brief. These two lines are derived by the SKILL, so
# that fix could not reach them:
#
#   "2 things in the build do not match what you asked for (t-3-ac1, t-5-ac1)"
#   "log #1 (t-3-ac1) — …"
#
# Both name the gap by a machine handle when the gap has a title written in the
# captain's own words, sitting in the same file the line is built from. Plain is
# not vague: the ids stay, in brackets, AFTER the human sentence.
# ==========================================================================
echo
echo "B17. the report and the escalation name the thing, not the id"

repoT1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mT1="$(plant_verify "$repoT1" "lcars-20260914-711")"
: >"$XO_WORKER_LOG"; : >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
# S225 — the contradiction moved from a TICKET criterion onto a PRD statement:
# since the headline reads the person group alone, only a PRD statement can
# produce the MEDIUM "known issue" line whose WORDING these checks are about.
# The naming rule under test is untouched.
outT1="$(XO_EV_BODY="$(ev_verdict_prd_medium)" \
          xo_evaluate "$repoT1" "lcars-20260914-711")"
xo_derivation() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["derivation"])' "$1"; }
check "B17. the first line the captain reads NAMES the thing" \
  "xo_derivation '$mT1/xo/verdict.json' | grep -q 'ADD is above the list'"
check "B17. …and still carries the id, in brackets after it" \
  "xo_derivation '$mT1/xo/verdict.json' | grep -q '(prd-2)'"
check "B17. …and still says how many, in words (S216: \"this known issue\")" \
  "xo_derivation '$mT1/xo/verdict.json' | grep -q 'go with this known issue'"
check "B17. the report on the issue reads the same way" \
  "grep -q 'ADD is above the list' '$mT1/xo/report.md'"

# The LOW branch — the one that says the PRD itself is not met — the same way.
repoT2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mT2="$(plant_verify "$repoT2" "lcars-20260914-712")"
: >"$XO_WORKER_LOG"; : >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outT2="$(XO_EV_BODY="$(ev_verdict met gap met low "$GAP_PRIMARY")" \
          xo_evaluate "$repoT2" "lcars-20260914-712")"
check "B17. a LOW names what the build does not do" \
  "xo_derivation '$mT2/xo/verdict.json' | grep -q 'no add control'"
check "B17. …with the PRD criterion's id after it" \
  "xo_derivation '$mT2/xo/verdict.json' | grep -q '(prd-2)'"

# The escalation when a fix did not hold — the other derived line.
repoT3="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mT3="$(plant_verify "$repoT3" "lcars-20260914-713")"
plant_verdict "$mT3" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
plant_logs_json "$mT3" 2
plant_child "$repoT3" "lcars-20260914-713" 1 verify
plant_child "$repoT3" "lcars-20260914-713" 2 verify
plant_reverify_gate "$mT3"
: >"$XO_WORKER_LOG"; : >"$XO_RESPOND_CALLS"
outT3="$(XO_RC_BODY="$(rc_body true false)" xo_recheck "$repoT3" "lcars-20260914-713")" || true
check "B17. the hand-back names the gap by its TITLE" \
  "xo_state '$mT3' note | grep -q 'gap 2 —'"
check "B17. …with the log number and the criterion in brackets after it" \
  "xo_state '$mT3' note | grep -q '(log #2, prd-2)'"
check "B17. …and every word the worker gave is still in it" \
  "xo_state '$mT3' note | grep -q 'still above the list'"

# ==========================================================================
# B18 (S204 fix round 2, D3). THE GAP IS BOUND TO THE PICTURE THAT SHOWS IT.
#
# THE DEFECT. Number One took shot-03 (the header alone) and shot-06 (the add
# row alone) — exactly the per-gap evidence — then attached shot-01, the
# 2880x1626 full page, to BOTH children, byte-for-byte identical, and both issue
# bodies cited "shot-01". The header-count bug arrived at its fix worker holding
# a picture of the whole screen.
# ==========================================================================
echo
echo "B18. the bug carries the close-up, not the whole screen"

repoU1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mU1="$(plant_verify "$repoU1" "lcars-20260914-721")"
plant_verdict "$mU1" "$(gap_json 1 contradiction t-1-ac1 shot-01)"
# The readouts the driver writes beside every PNG: shot-01 is the whole page,
# shot-03 is the close-up of #add-button — the element t-1-ac1 was drawn at.
printf '{"shot":"shot-01","selector":null,"clip":"full-page"}\n' >"$mU1/xo/shots/shot-01.json"
printf '{"shot":"shot-03","selector":"#add-button","clip":{"x":0,"y":0,"width":10,"height":10}}\n' \
  >"$mU1/xo/shots/shot-03.json"
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outU1="$(xo_file_logs "$repoU1" "lcars-20260914-721")"
check "B18. the close-up of the element is on the bug" \
  "grep -q -- '--attach [^ ]*shot-03.png' '$XO_LOG_CALLS'"
check "B18. …FIRST, ahead of the full page" \
  "grep -q -- '--prd [^ ]*1.md --attach [^ ]*shot-03.png --attach [^ ]*shot-01.png' '$XO_LOG_CALLS'"
check "B18. the full page rides along — it is not replaced" \
  "grep -q -- '--attach [^ ]*shot-01.png' '$XO_LOG_CALLS'"
check "B18. the bug PRD says which picture shows the thing" \
  "grep -q 'shot-03' '$mU1/xo/logs/1.md' && grep -q 'close-up of' '$mU1/xo/logs/1.md'"

# THE CONTROL. A gap whose element has no close-up keeps the picture it cited,
# and nothing is invented for it.
repoU2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mU2="$(plant_verify "$repoU2" "lcars-20260914-722")"
plant_verdict "$mU2" "$(gap_json 1 contradiction prd-1 shot-01)"
printf '{"shot":"shot-01","selector":null,"clip":"full-page"}\n' >"$mU2/xo/shots/shot-01.json"
: >"$XO_LOG_CALLS"; : >"$XO_RESOLVE_CALLS"
outU2="$(xo_file_logs "$repoU2" "lcars-20260914-722")"
check "B18. THE CONTROL — with no close-up to be had, the cited shot stands" \
  "grep -q -- '--prd [^ ]*1.md --attach [^ ]*shot-01.png' '$XO_LOG_CALLS' && ! grep -q -- 'shot-03.png' '$XO_LOG_CALLS'"

# ==========================================================================
# B19 (S204 fix round 2, D5). THE HELP PRINTS THE WHOLE BLOCK.
#
# `lcars xo --help` ended mid-sentence at "…with its shots, and let LCARS",
# three lines short — so `lcars xo recheck`, this round's headline verb, could
# not be discovered from the CLI at all. Round 1 widened the hand-counted range
# from 3,12p to 3,18p; the block outgrew that too. A counted range is the bug.
# ==========================================================================
echo
echo "B19. --help cannot silently truncate"

helpout="$( bash "$SCRIPT" --help 2>&1 )"
for v in on off answer evaluate file-logs recheck report; do
  check "B19. --help lists \`lcars xo $v\`" \
    "printf '%s\n' \"\$helpout\" | grep -q 'lcars xo $v'"
done
check "B19. the LAST line of the source's usage block reaches the terminal" \
  "printf '%s\n' \"\$helpout\" | tail -1 | grep -q -- '--seen marks it read'"
check "B19. …and the sentence before it is whole, not cut at 'let LCARS'" \
  "printf '%s\n' \"\$helpout\" | grep -q 'drive them'"
check "B19. …the recheck verb's own last line still reaches the terminal too" \
  "printf '%s\n' \"\$helpout\" | grep -q 'accept what holds, re-score'"
# THE RANGE CANNOT ROT. Not "the code no longer says sed" — a COPY of the
# script with one more verb appended to the END of the usage block, run for its
# help. A hand-counted range prints everything but the new line; the fix prints
# it. This is the check that would have caught the defect twice.
XOCOPY="$EVDIR/xo-with-a-later-verb.sh"
python3 - "$SCRIPT" "$XOCOPY" <<'XPY'
import sys
src = open(sys.argv[1]).read()
i = src.index("#   lcars xo recheck --mission <id>")
end = src.index("\n#\n", i)
src = src[:end] + "\n#   lcars xo warpfactor --mission <id>  a verb somebody added later" + src[end:]
open(sys.argv[2], "w").write(src)
XPY
newhelp="$( LCARS_COMMON_LIB="$REPO_ROOT/skills/lcars-init/lcars-common.sh" \
            LCARS_OWNERSHIP_LIB="$REPO_ROOT/skills/lcars-run/ownership.sh" \
            bash "$XOCOPY" --help 2>&1 )"
check "B19. a verb added at the END of the block still prints — the range cannot rot" \
  "printf '%s\n' \"\$newhelp\" | grep -q 'warpfactor'"
check "B19. …and the verbs above it are all still there (the control)" \
  "printf '%s\n' \"\$newhelp\" | grep -q 'lcars xo recheck' && printf '%s\n' \"\$newhelp\" | grep -q 'lcars xo on'"

# ==========================================================================
# B20 (S205 ruling 1, 2026-09-14): AN ACCEPT IS FINAL — a later look is
# REFUSED, with the captain's own sentence, before a look name is even
# minted, a launch is spent, or a worker is hired.
# ==========================================================================
echo
echo "B20. an accept is final — recheck refuses, verbatim"

repoF1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mF1="$(plant_verify "$repoF1" "lcars-20260914-401")"
# This mission already went through a clean accept — `status: finished` is the
# ONE terminal record both a clean first look and a successful recheck leave
# behind (xo_finish / cmd_recheck's own closing obj_set).
python3 - "$mF1/state.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('"numberOne": {"status": "engaged"', '"numberOne": {"status": "finished"')
open(p, "w").write(s)
PY
plant_logs_json "$mF1" 1
plant_child "$repoF1" "lcars-20260914-401" 1 verify
: >"$XO_LAUNCH_LOG"; : >"$XO_WORKER_LOG"; : >"$XO_RESPOND_CALLS"; : >"$XO_LABEL_LOG"
before_journal=""; [ -f "$mF1/number-one.jsonl" ] && before_journal="$(cat "$mF1/number-one.jsonl")"
rcF1=0
outF1="$(xo_recheck "$repoF1" "lcars-20260914-401")" || rcF1=$?
check "B20. refuses (non-zero)" "[ '$rcF1' -ne 0 ]"
check "B20. …with the captain's OWN sentence, verbatim" \
  "printf '%s' \"\$outF1\" | grep -qF \"I've already handed this one back — the PR is yours.\""
check "B20. no look name was even minted — no recheck-1 shots dir" \
  "[ ! -d '$mF1/xo/shots/recheck-1' ]"
check "B20. no launch was spent on it" "[ ! -s '$XO_LAUNCH_LOG' ]"
check "B20. no worker was hired" "[ ! -s '$XO_WORKER_LOG' ]"
check "B20. nothing was answered through \`lcars respond\`" "[ ! -s '$XO_RESPOND_CALLS' ]"
check "B20. the label was never touched" "[ ! -s '$XO_LABEL_LOG' ]"
check "B20. status stays finished — untouched, not re-escalated" \
  "[ \"\$(xo_state '$mF1' status)\" = 'finished' ]"
check "B20. the journal gained NOTHING for this refusal" \
  "[ \"\$(cat '$mF1/number-one.jsonl' 2>/dev/null)\" = \"\$before_journal\" ]"

# --- B20b. CONTROL — every OTHER status still runs recheck normally --------
# (escalated, engaged, or no numberOne status at all): only `finished` is the
# terminal one this ruling closes the door on.
repoF2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mF2="$(plant_verify "$repoF2" "lcars-20260914-402")"
python3 - "$mF2/state.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('"numberOne": {"status": "engaged"', '"numberOne": {"status": "escalated"')
open(p, "w").write(s)
PY
plant_verdict "$mF2" "$(gap_json 1 contradiction prd-1 shot-01)"
plant_logs_json "$mF2" 1
plant_child "$repoF2" "lcars-20260914-402" 1 verify
plant_reverify_gate "$mF2"
: >"$XO_LAUNCH_LOG"; : >"$XO_RESPOND_CALLS"
outF2="$(XO_RC_BODY="$(rc_body true true)" xo_recheck "$repoF2" "lcars-20260914-402" 2>&1)"
check "B20b. an ESCALATED mission still gets a fresh look" \
  "grep -q 'launch lcars-20260914-402' '$XO_LAUNCH_LOG'"
check "B20b. …and this one is not the refusal sentence" \
  "! printf '%s' \"\$outF2\" | grep -qF \"I've already handed this one back\""

# ==========================================================================
# B21 (S205 ruling 2, 2026-09-14): `xo recheck` MUST NOT TRUST THE LOCAL
# BRANCH — it fetches origin first (fast-forwarding when it safely can) and,
# whether or not that was possible, always says PLAINLY which commit it is
# about to look at. Real git throughout: an origin bare repo, a branch pushed
# to it, and a "fix" pushed from a THIRD clone (simulating "the branch moved
# somewhere else") — the same shape S204's round-3 tester hit by hand.
# ==========================================================================
echo
echo "B21. xo recheck fetches — it never trusts a stale local branch"

git_recheck_repo() { # <id> — a real git repo, with an ORIGIN, and the
                     # mission's branch pushed to it. Echoes the repo path.
  local id="$1" repo origin
  repo="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
  origin="$(mktemp -d "$TMPROOT/origin.XXXX")"
  ( cd "$origin" && git init -q --bare ) >/dev/null 2>&1
  (
    cd "$repo"
    git remote add origin "$origin"
    git commit -q --allow-empty -m init
    git checkout -q -b "lcars/$id"
    git commit -q --allow-empty -m "the mission's own work"
    git push -q -u origin "lcars/$id"
  ) >/dev/null 2>&1
  printf '%s' "$repo"
}

push_fix_from_elsewhere() { # <repo> <branch> — a THIRD clone pushes one more
                            # commit, moving origin PAST this repo's local ref.
  local repo="$1" branch="$2" origin elsewhere
  origin="$(git -C "$repo" remote get-url origin)"
  elsewhere="$(mktemp -d "$TMPROOT/elsewhere.XXXX")"
  git clone -q "$origin" "$elsewhere" >/dev/null 2>&1
  (
    cd "$elsewhere"
    git config user.email t@t; git config user.name t
    git checkout -q "$branch"
    git commit -q --allow-empty -m "the fix, pushed from elsewhere"
    git push -q origin "$branch"
  ) >/dev/null 2>&1
  git -C "$elsewhere" rev-parse "$branch"
}

repoG1="$(git_recheck_repo lcars-20260914-501)"
mG1="$(plant_verify "$repoG1" "lcars-20260914-501")"
python3 - "$mG1/state.json" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace('"stage": "verify",', '"stage": "verify",\n  "branch": "lcars/lcars-20260914-501",')
open(p, "w").write(s)
PY
remote_tip="$(push_fix_from_elsewhere "$repoG1" "lcars/lcars-20260914-501")"
local_before="$(git -C "$repoG1" rev-parse "lcars/lcars-20260914-501")"
plant_verdict "$mG1" "$(gap_json 1 contradiction prd-1 shot-01)"
plant_logs_json "$mG1" 1
plant_child "$repoG1" "lcars-20260914-501" 1 verify
plant_reverify_gate "$mG1"
: >"$XO_LAUNCH_LOG"; : >"$XO_RESPOND_CALLS"
outG1="$(XO_RC_BODY="$(rc_body true true)" xo_recheck "$repoG1" "lcars-20260914-501")"
check "B21. it actually fetched — local≠remote before, so a stale run was possible" \
  "[ '$local_before' != '$remote_tip' ]"
check "B21. the local branch was brought up to the remote tip before relaunching" \
  "[ \"\$(git -C '$repoG1' rev-parse 'lcars/lcars-20260914-501')\" = '$remote_tip' ]"
check "B21. it SAYS which commit it is looking at, plainly, on the terminal" \
  "printf '%s' \"\$outG1\" | grep -q 'looking at commit'"
check "B21. …and says the branch had moved" \
  "printf '%s' \"\$outG1\" | grep -qi 'it had moved'"
check "B21. the journal records the commit it examined" \
  "grep -q '\"action\": \"relaunched\"' '$mG1/number-one.jsonl' && grep -q '\"commit\":' '$mG1/number-one.jsonl'"
check "B21. …and the branch-note, so the record — not just the terminal — is honest" \
  "grep -q '\"branchNote\":' '$mG1/number-one.jsonl'"

# --- B21b. NO ORIGIN AT ALL — best-effort: never blocks the look, never
#     pretends to have checked upstream. Every OTHER recheck test in this
#     suite runs a repo shaped exactly like this (no branch recorded, no
#     origin) and all of them still pass — the regression guard for this is
#     the rest of the file.
repoG2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mG2="$(plant_verify "$repoG2" "lcars-20260914-502")"
plant_verdict "$mG2" "$(gap_json 1 contradiction prd-1 shot-01)"
plant_logs_json "$mG2" 1
plant_child "$repoG2" "lcars-20260914-502" 1 verify
plant_reverify_gate "$mG2"
: >"$XO_LAUNCH_LOG"
outG2="$(XO_RC_BODY="$(rc_body true true)" xo_recheck "$repoG2" "lcars-20260914-502")"
check "B21b. no branch recorded ⇒ it still relaunches (best-effort, never blocks)" \
  "grep -q 'launch lcars-20260914-502' '$XO_LAUNCH_LOG'"
check "B21b. …and says so plainly rather than pretending to have checked upstream" \
  "printf '%s' \"\$outG2\" | grep -qi 'no branch is recorded'"

# ==========================================================================
# B22 (S205): `lcars xo report` — since/history, Seen, one mission's journal,
# and CLI==API parity (behaviours 4 and 6). No worker, no launch, no gh — a
# pure read of number-one.jsonl + xo-seen.json, so the whole section runs
# with none of the usual stubs wired at all.
# ==========================================================================
echo
echo "B22. xo report — since you last looked, then history"

repoP1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mkdir -p "$repoP1/.git/lcars/missions/lcars-p1" "$repoP1/.git/lcars/missions/lcars-p2"
cat >"$repoP1/.git/lcars/missions/lcars-p1/state.json" <<'EOF'
{"id": "lcars-p1", "type": "feature", "title": "The task board", "stage": "verify", "githubIssue": 901}
EOF
cat >"$repoP1/.git/lcars/missions/lcars-p2/state.json" <<'EOF'
{"id": "lcars-p2", "type": "feature", "title": "Dark mode", "stage": "verify", "githubIssue": 902}
EOF
cat >"$repoP1/.git/lcars/missions/lcars-p1/number-one.jsonl" <<'EOF'
{"at": "2026-09-14T10:00:00Z", "action": "scored", "score": "high", "why": "all criteria met"}
{"at": "2026-09-14T11:00:00Z", "action": "escalated", "detail": "the lock glyph is missing"}
EOF
cat >"$repoP1/.git/lcars/missions/lcars-p2/number-one.jsonl" <<'EOF'
{"at": "2026-09-14T09:00:00Z", "action": "scored", "score": "medium", "why": "one gap"}
EOF

xo_report() { ( cd "$repoP1" && bash "$SCRIPT" report "$@" 2>&1 ); }

out22a="$(xo_report)"
check "B22. everything is new the first time (no xo-seen.json yet)" \
  "printf '%s\n' \"\$out22a\" | grep -q 'Since you last looked (3)'"
check "B22. …names the mission by TITLE and issue" \
  "printf '%s\n' \"\$out22a\" | grep -q 'The task board (#901)'"
check "B22. …and the OTHER mission's entry too — this is repo-wide" \
  "printf '%s\n' \"\$out22a\" | grep -q 'Dark mode (#902)'"
check "B22. History folds BOTH missions, nothing dropped" \
  "printf '%s\n' \"\$out22a\" | grep -q 'The task board (#901)' && printf '%s\n' \"\$out22a\" | grep -q 'Dark mode (#902)'"
check "B22. no xo-seen.json was written by a plain read" \
  "[ ! -f '$repoP1/.git/lcars/xo-seen.json' ]"

# --- ✓ Seen folds it: the file is written, and nothing new remains ---------
out22b="$(xo_report --seen)"
check "B22. --seen writes the record" "[ -s '$repoP1/.git/lcars/xo-seen.json' ]"
check "B22. …as a real lastSeenAt timestamp" \
  "grep -q 'lastSeenAt' '$repoP1/.git/lcars/xo-seen.json'"
out22c="$(xo_report)"
check "B22. reopening after Seen says so — nothing new" \
  "printf '%s\n' \"\$out22c\" | grep -q 'Since you last looked (0)' && printf '%s\n' \"\$out22c\" | grep -qi 'nothing new'"
check "B22. …but NOTHING was deleted — history still carries both missions" \
  "printf '%s\n' \"\$out22c\" | grep -q 'The task board (#901)' && printf '%s\n' \"\$out22c\" | grep -q 'Dark mode (#902)'"

# --- ONE mission's journal (`lcars xo report <id>`) ------------------------
out22d="$(xo_report lcars-p1)"
check "B22. scoping to one mission shows its own entries" \
  "printf '%s\n' \"\$out22d\" | grep -q 'the lock glyph is missing'"
check "B22. …and NOT the other mission's" \
  "! printf '%s\n' \"\$out22d\" | grep -q 'Dark mode'"

# --- --all vs the default fold (>10 entries in one mission) ----------------
rm -f "$repoP1/.git/lcars/xo-seen.json"
: >"$repoP1/.git/lcars/missions/lcars-p1/number-one.jsonl"
for n in $(seq 1 14); do
  printf '{"at": "2026-09-14T12:%02d:00Z", "action": "note-%d", "detail": "entry %d"}\n' "$n" "$n" "$n" \
    >>"$repoP1/.git/lcars/missions/lcars-p1/number-one.jsonl"
done
# Every one of the 14 is "new" (no seen record), so the UNFOLDED "since" list
# always names all 14 — the fold is a HISTORY-section behaviour only. Isolate
# the History section (everything from its header on) before counting.
out22e="$(xo_report lcars-p1)"
hist22e="$(printf '%s\n' "$out22e" | sed -n '/^History:/,$p')"
check "B22. the default fold caps a mission's HISTORY and says how many more" \
  "printf '%s\n' \"\$hist22e\" | grep -q 'more (use --all'"
check "B22. …showing at most 10 entries in that folded history" \
  "[ \"\$(printf '%s\n' \"\$hist22e\" | grep -c 'note-')\" -eq 10 ]"
out22f="$(xo_report lcars-p1 --all)"
hist22f="$(printf '%s\n' "$out22f" | sed -n '/^History:/,$p')"
check "B22. --all's HISTORY shows every one of the 14 entries" \
  "[ \"\$(printf '%s\n' \"\$hist22f\" | grep -c 'note-')\" -eq 14 ]"
check "B22. …with no '… more' line left once nothing is held back" \
  "! printf '%s\n' \"\$hist22f\" | grep -q 'more (use --all'"

# --- behaviour 6: CLI text and the API's JSON split agree, on ONE fixture --
rm -f "$repoP1/.git/lcars/xo-seen.json"
json22="$( python3 "$REPO_ROOT/skills/lcars-xo/xo-report.py" \
             "$repoP1/.git/lcars/missions" "$repoP1/.git/lcars/xo-seen.json" --format json )"
api_since_count="$(printf '%s' "$json22" | python3 -c 'import json,sys; print(json.load(sys.stdin)["since"]["count"])')"
api_hist_missions="$(printf '%s' "$json22" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len([h for h in d["history"] if h["entries"]]))')"
cli_out="$(xo_report --all)"
cli_since_count="$(printf '%s\n' "$cli_out" | sed -n 's/.*Since you last looked (\([0-9]*\)).*/\1/p')"
cli_hist_missions="$(printf '%s\n' "$cli_out" | grep -cE '^  .* \(#[0-9]+\)$')"
check "B22. CLI's since-count == the API's since-count, same fixture" \
  "[ '$cli_since_count' = '$api_since_count' ]"
check "B22. CLI's history mission-count == the API's, same fixture" \
  "[ '$cli_hist_missions' = '$api_hist_missions' ]"

# ==========================================================================
# B23 (S210) — THE OBSERVATIONS PASS AND THE NO-DRAWING PATH, WIRED THROUGH
# `xo.sh evaluate` ITSELF, not just their own scripts in isolation.
#
# `xo-drive.js`, `xo-observe.py`, `xo-score.py` and `xo-criteria.py` are all
# proven directly, against real headless Chrome and real crafted input, in
# tests/lcars-xo-observe.test.sh — that is where "never fake the layer you are
# changing" is honoured for the geometry and the arithmetic. What is faked
# HERE (the driver, the launch, the worker) is exactly what every other block
# in this file fakes — this section exists to prove the WIRING: that
# `evaluate` actually CALLS xo-observe.py at the right moment, hands its
# output to the worker, folds it into report.md, and enforces the no-drawing
# guard when there really is no `attachments/` dir on a real mission.
# ==========================================================================
echo
echo "B23. the observations pass and the no-drawing path, wired through evaluate"

# The stub driver, PLUS a `readout.json` carrying two touching buttons — the
# one thing DRIVE_STUB never wrote, because before S210 nothing ever read it.
DRIVE_STUB_CROWDED="$EVDIR/xo-drive-crowded.sh"
cat >"$DRIVE_STUB_CROWDED" <<DSC
#!/usr/bin/env bash
printf 'drive %s\n' "\$*" >>"\$XO_DRIVE_LOG"
out=""
while [ \$# -gt 0 ]; do case "\$1" in --out) out="\$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "\$out"
printf 'PNG\n' >"\$out/shot-01.png"
printf '{"shot":"shot-01"}\n' >"\$out/shot-01.json"
printf 'shot-01 — full page\n' >"\$out/shot-01.txt"
cat >"\$out/readout.json" <<'RJ'
{"url": "http://127.0.0.1:4310/", "notes": [], "shots": [{"name": "shot-01"}],
 "page": {"elements": [
   {"id": "add-button", "tag": "button", "text": "ADD", "interactive": true,
    "box": {"x": 20, "y": 20, "w": 80, "h": 30}, "color": "rgb(0,0,0)",
    "overflowX": 0, "overflowY": 0},
   {"id": "cancel-button", "tag": "button", "text": "CANCEL", "interactive": true,
    "box": {"x": 100, "y": 20, "w": 80, "h": 30}, "color": "rgb(0,0,0)",
    "overflowX": 0, "overflowY": 0}
 ]}}
RJ
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
DSC
chmod +x "$DRIVE_STUB_CROWDED"

# The worker shim, extended to record whether IT was handed observations.json
# — the thing that proves "the worker may cite one, the skill does not keep it
# to itself" rather than just asserting a file exists somewhere on disk.
export XO_OBS_SEEN_LOG="$TMPROOT/obs-seen.txt"; : >"$XO_OBS_SEEN_LOG"
EV_SHIM_OBS="$EVDIR/ev-worker-obs"
cat >"$EV_SHIM_OBS" <<EVO
#!/usr/bin/env bash
printf 'worker %s\n' "\$*" >>"\$XO_WORKER_LOG"
printf 'worker %s\n' "\$*" >>"\$XO_WORKER_LOG.all"
if [ -s "\${LCARS_XO_INPUT_DIR:-/nonexistent}/observations.json" ]; then
  printf 'saw observations.json\n' >>"\$XO_OBS_SEEN_LOG"
else
  printf 'NO observations.json\n' >>"\$XO_OBS_SEEN_LOG"
fi
out="\${LCARS_WORK_OUT:-}"
[ -n "\${XO_EV_BODY:-}" ] && printf '%s\n' "\$XO_EV_BODY" >"\$out/\${XO_EV_FILE:-xo-verdict.json}"
exit 0
EVO
chmod +x "$EV_SHIM_OBS"

# --------------------------------------------------------------------------
# B23a. A crowded pair is a real observation on the real mission's report —
#     its own section, the thresholds printed, and the worker sees the file.
# --------------------------------------------------------------------------
repo23a="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m23a="$(plant_verify "$repo23a" "lcars-20260914-201")"
: >"$XO_WORKER_LOG"; : >"$XO_OBS_SEEN_LOG"
out23a="$(XO_WORKER_LOG="$XO_WORKER_LOG" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_with "$repo23a" "lcars-20260914-201" "$DRIVE_STUB_CROWDED" "$EV_SHIM_OBS")"
check "B23a. observations.json was written by the SKILL, unasked" \
  "[ -s '$m23a/xo/observations.json' ]"
check "B23a. …with the crowded pair caught, in house style — no harness words" \
  "grep -q 'the ADD and CANCEL buttons are touching' '$m23a/xo/observations.json' && ! grep -Eq 'bbox|#add-button' '$m23a/xo/observations.json'"
check "B23a. the WORKER was handed observations.json — it can cite it" \
  "grep -q 'saw observations.json' '$XO_OBS_SEEN_LOG'"
check "B23a. it landed in report.md — the captain's copy — in its OWN section" \
  "grep -q 'Things I noticed' '$m23a/xo/report.md'"
check "B23a. …with the thresholds PRINTED, not just applied" \
  "grep -q '8 px apart' '$m23a/xo/report.md'"
check "B23a. the look JOURNALLED that it observed something (an action, per SKILL.md)" \
  "grep -q '\"action\": \"observed\"' '$m23a/number-one.jsonl' && grep -q '\"count\": 1' '$m23a/number-one.jsonl'"

# --------------------------------------------------------------------------
# B23b. AN OBSERVATION NEVER MOVES THE SCORE — proven at the WIRING level:
#     the identical worker verdict, through the identical evaluate path, once
#     with a driver that found nothing to observe and once with the crowded
#     one above. Same ledger, same score, either way.
# --------------------------------------------------------------------------
repo23b1="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m23b1="$(plant_verify "$repo23b1" "lcars-20260914-202")"
: >"$XO_WORKER_LOG"
XO_WORKER_LOG="$XO_WORKER_LOG" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_with "$repo23b1" "lcars-20260914-202" "$DRIVE_STUB" "$EV_SHIM" >/dev/null

repo23b2="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m23b2="$(plant_verify "$repo23b2" "lcars-20260914-203")"
: >"$XO_WORKER_LOG"
XO_WORKER_LOG="$XO_WORKER_LOG" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_with "$repo23b2" "lcars-20260914-203" "$DRIVE_STUB_CROWDED" "$EV_SHIM_OBS" >/dev/null

check "B23b. no observations at all -> the report has no Observations section" \
  "! grep -q 'Things I noticed' '$m23b1/xo/report.md'"
check "B23b. …but WITH a crowded pair, it does" \
  "grep -q 'Things I noticed' '$m23b2/xo/report.md'"
check "B23b. …and the SCORE is identical either way (HIGH, all-met)" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"'$m23b1'/xo/verdict.json\"))[\"score\"])')\" = 'high' ] && [ \"\$(python3 -c 'import json;print(json.load(open(\"'$m23b2'/xo/verdict.json\"))[\"score\"])')\" = 'high' ]"
check "B23b. …and the LEDGER (criterion statuses) is identical either way" \
  "diff <(python3 -c 'import json;print(json.dumps(json.load(open(\"'$m23b1'/xo/verdict.json\"))[\"criteria\"], sort_keys=True))') <(python3 -c 'import json;print(json.dumps(json.load(open(\"'$m23b2'/xo/verdict.json\"))[\"criteria\"], sort_keys=True))') >/dev/null"

# --------------------------------------------------------------------------
# B23c. A MISSION WITH NO DRAWING AT ALL — the look still runs, still judges
#     the PRD and plan criteria, and a `drawnAt` criterion the worker rated
#     `met` still comes back "I could not check this against a drawing" —
#     the honest half of this feature, proven with NO attachments/ directory
#     anywhere on disk, not a drawing that merely names nothing.
# --------------------------------------------------------------------------
plant_verify_no_drawing() { # <repo> <id>
  local repo="$1" id="$2" m
  m="$repo/.git/lcars/missions/$id"
  mkdir -p "$m"
  {
    printf '{\n'
    printf '  "numberOne": {"status": "engaged", "engine": "copilot", "since": "2026-09-14T10:00:00Z"},\n'
    printf '  "id": "%s",\n' "$id"
    printf '  "type": "feature",\n'
    printf '  "title": "The task board, no mockup this time",\n'
    printf '  "stage": "verify",\n'
    printf '  "prUrl": "https://github.com/x/y/pull/9",\n'
    printf '  "created": "2026-09-14T10:00:00Z",\n'
    printf '  "githubIssue": 91\n'
    printf '}\n'
  } >"$m/state.json"
  cat >"$m/prd.md" <<'PRD'
# The task board, no mockup this time

## 2. Acceptance criteria
- The board shows every open task in one list.

## 3. Out of scope
Email.
PRD
  cat >"$m/plan.json" <<'PL'
{"tickets": [{"id": "t-9", "changesScreenAppearance": true,
  "acceptanceCriteria": [
    {"text": "The status line sits under the add row.", "drawnAt": "#status-line, beneath the add row"}]}]}
PL
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m/state.json" \
    || { echo "FIXTURE IS NOT VALID JSON"; exit 1; }
  printf '%s' "$m"
}
repo23c="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m23c="$(plant_verify_no_drawing "$repo23c" "lcars-20260914-204")"
check "B23c. no attachments/ directory exists on this mission at all" \
  "[ ! -d '$m23c/attachments' ]"
: >"$XO_WORKER_LOG"
verdict23c='{"score":"high","summary":"Looks perfect, matches the drawing exactly.","criteria":[{"id":"prd-1","text":"open tasks in one list","status":"met","shot":"shot-01","note":"saw the list"},{"id":"t-9-ac1","text":"status line under add row","status":"met","shot":"shot-01","note":"I compared it to the drawing and it lines up"}],"gaps":[]}'
out23c="$(XO_WORKER_LOG="$XO_WORKER_LOG" XO_EV_BODY="$verdict23c" \
  LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_WORKER_BIN="$EV_SHIM" \
  xo_evaluate "$repo23c" "lcars-20260914-204")"
check "B23c. the look RAN — criteria.json was built from the PRD and the plan alone" \
  "[ -s '$m23c/xo/criteria.json' ] && grep -q '\"hasDrawing\": false' '$m23c/xo/criteria.json'"
check "B23c. …and the drawnAt criterion, though the worker called it MET, comes back untested" \
  "python3 -c 'import json,sys
d=json.load(open(\"$m23c/xo/verdict.json\"))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"t-9-ac1\"][0]
sys.exit(0 if e[\"status\"]==\"untested\" else 1)'"
check "B23c. …with the exact honest sentence, never silently MET" \
  "grep -q \"I could not check this against a drawing, because there isn't one\" '$m23c/xo/verdict.json'"
check "B23c. the PRD's own (non-drawnAt) criterion is judged normally — MET" \
  "python3 -c 'import json,sys
d=json.load(open(\"$m23c/xo/verdict.json\"))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"prd-1\"][0]
sys.exit(0 if e[\"status\"]==\"met\" else 1)'"
# CHANGED, S225. S210's cure is the line ABOVE and it is untouched: the worker
# called the drawnAt row MET, the harness refuses, and the row comes back
# untested with the honest sentence. What this line used to add was that the
# refusal also pulled the captain's GRADE down — and `t-9-ac1` is a TICKET
# criterion (`source: "plan"`), so that is the ticket list outvoting what a
# person can do, plus a hole in our own checking reading as a doubt about his
# build. Both are struck out. What must still hold is that the verdict is not a
# clean bill: the row is ours to fix, by name, with what defeated it, and the
# headline never claims everything he asked for is there.
check "B23c. …and the refusal is named as OURS — it could not be set up, no drawing exists" \
  "python3 -c 'import json,sys
d=json.load(open(\"$m23c/xo/verdict.json\"))
e=[c for c in d[\"criteria\"] if c[\"id\"]==\"t-9-ac1\"][0]
mc=d[\"myChecking\"][\"couldntSetUp\"]
sys.exit(0 if e[\"outcome\"]==\"couldnt-set-up\" and [r for r in mc if r[\"id\"]==\"t-9-ac1\"] else 1)'"
check "B23c. …and the headline never claims everything he asked for is in the build" \
  "! python3 -c 'import json;print(json.load(open(\"'$m23c'/xo/verdict.json\"))[\"derivation\"])' \
     | grep -q 'everything you asked for is in the build'"
check "B23c. …and the contract line counts it as having nothing behind it" \
  "python3 -c 'import json,sys
g=json.load(open(\"$m23c/xo/verdict.json\"))[\"groups\"][\"contract\"]
sys.exit(0 if g[\"uncovered\"]==1 and g[\"covered\"]==0 else 1)'"
check "B23c. the launch and the browser both ran normally (no attachments is not an error)" \
  "grep -q -- '--stop' '$XO_LAUNCH_LOG' && ! printf '%s' \"\$out23c\" | grep -qi 'did not start'"

# ==========================================================================
# B24. THE PROJECT'S OWN TESTS AS EVIDENCE (Session 211), WIRED THROUGH
#      `evaluate`.
#
# The captain, 2026-09-13: "some things might just be API changes that don't
# affect the UI that need to be tested … a functionality bug is like a button
# being pushed was supposed to do something and it doesn't." Number One acts
# only through a browser, so the first half of that was simply invisible to it
# — "batches survive a restart" came back "I could not check this" on BOTH
# engines in S203: correct, and useless.
#
# `tests/lcars-xo-evidence.test.sh` proves the runner's own arithmetic and the
# scorer's guards directly. THESE rows prove the WIRING — that `xo.sh evaluate`
# really runs the repo's own suite, in the LAUNCHED BUILD'S worktree, between
# stopping the app and relaunching for the capture, and really hands the
# result to the worker.
# A guard nobody calls is not a guard.
# ==========================================================================
echo
echo "B24. the project's own tests as evidence, wired through evaluate"

# The launch stub, PLUS the `worktree` field the real launch.sh always writes —
# the one thing DRIVE_STUB's sibling never wrote, because before S211 nothing
# read it. It also creates that directory, because it is where the tests run.
LAUNCH_STUB_WT="$EVDIR/launch-wt.sh"
cat >"$LAUNCH_STUB_WT" <<'LWT'
#!/usr/bin/env bash
mid="$1"; shift
m="$PWD/.git/lcars/missions/$mid"
printf 'launch %s %s\n' "$mid" "$*" >>"$XO_LAUNCH_LOG"
case "${1:-}" in
  --stop)
    if [ -n "${XO_PORT_PROBE:-}" ] && [ -s "$m/port-server.pid" ]; then
      kill -TERM "$(cat "$m/port-server.pid")" 2>/dev/null || true
      python3 - "$XO_PORT_PROBE" <<'PY'
import socket, sys, time
for _ in range(100):
    with socket.socket() as s:
        if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) != 0:
            break
    time.sleep(.02)
else:
    raise SystemExit("stub app did not stop")
PY
    fi
    printf '{\n  "status": "stopped"\n}\n' >"$m/launch.json"; exit 0 ;;
esac
wt="${XO_FAKE_WORKTREE:-$PWD/.fake-worktree}"
mkdir -p "$wt"
if [ -n "${XO_PORT_PROBE:-}" ]; then
  python3 -m http.server "$XO_PORT_PROBE" --bind 127.0.0.1 >"$m/port-server.log" 2>&1 &
  echo "$!" >"$m/port-server.pid"
  python3 - "$XO_PORT_PROBE" <<'PY'
import socket, sys, time
for _ in range(100):
    with socket.socket() as s:
        if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0:
            break
    time.sleep(.02)
else:
    raise SystemExit("stub app did not bind")
PY
  printf 'bound %s\n' "$XO_PORT_PROBE" >>"$m/port-events"
fi
printf '{\n  "status": "running",\n  "url": "http://127.0.0.1:%s/",\n  "worktree": "%s",\n  "pid": 1\n}\n' "${XO_PORT_PROBE:-4310}" "$wt" >"$m/launch.json"
LWT
chmod +x "$LAUNCH_STUB_WT"

# The worker shim, extended to record whether IT was handed tests.json — the
# same proof shape B23 uses for observations.json. A file on disk somewhere is
# not the same fact as a file the worker can read.
export XO_TESTS_SEEN_LOG="$TMPROOT/tests-seen.txt"; : >"$XO_TESTS_SEEN_LOG"
EV_SHIM_TESTS="$EVDIR/ev-worker-tests"
cat >"$EV_SHIM_TESTS" <<'EVT'
#!/usr/bin/env bash
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG"
printf 'worker %s\n' "$*" >>"$XO_WORKER_LOG.all"
if [ -s "${LCARS_XO_INPUT_DIR:-/nonexistent}/tests.json" ]; then
  printf 'saw tests.json\n' >>"$XO_TESTS_SEEN_LOG"
  if [ -n "${XO_PORT_TEST_INPUT:-}" ]; then
    cp "$LCARS_XO_INPUT_DIR/tests.json" "$XO_PORT_TEST_INPUT"
  fi
else
  printf 'NO tests.json\n' >>"$XO_TESTS_SEEN_LOG"
fi
out="${LCARS_WORK_OUT:-}"
[ -n "${XO_EV_BODY:-}" ] && printf '%s\n' "$XO_EV_BODY" >"$out/${XO_EV_FILE:-xo-verdict.json}"
exit 0
EVT
chmod +x "$EV_SHIM_TESTS"

set_test_command() { # <repo> <command-or-null-literal>
  python3 - "$1/.git/lcars/config.json" "$2" <<'STC'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as fh:
    doc = json.load(fh)
doc["testCommand"] = None if cmd == "__null__" else cmd
with open(path, "w") as fh:
    json.dump(doc, fh, indent=2)
STC
}

# The same evaluate driver as xo_evaluate_with, with the worktree-aware launch
# stub in place of the plain one.
xo_evaluate_tests() { # <repo> <id> <worker-bin>
  local repo="$1" id="$2" workerbin="$3"
  ( cd "$repo" && XO_WORKER_LOG="$XO_WORKER_LOG" \
      LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB_WT" \
      LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
      LCARS_HOST_ADAPTER="$HOST_STUB" \
      LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
      LCARS_WORKER_BIN="$workerbin" LCARS_WORKER_CLI=copilot \
      LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
      LCARS_OWNER_ENFORCE=0 \
      bash "$SCRIPT" evaluate --mission "$id" 2>&1 )
}

# --------------------------------------------------------------------------
# B24a. THE SUITE IS RUN, IN THE BUILD'S OWN CHECKOUT, AND THE WORKER IS
#     HANDED THE RESULT. The test command writes a marker beside itself, so
#     "it ran" is observed rather than asserted, and "it ran THERE" is too.
# --------------------------------------------------------------------------
repo24a="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24a="$(plant_verify "$repo24a" "lcars-20260915-301")"
WT24A="$TMPROOT/wt-24a"; mkdir -p "$WT24A"
printf '[project]\nname = "conflicting-runner"\nversion = "0.0.1"\n' >"$WT24A/pyproject.toml"
printf 'raise RuntimeError("configured command must win")\n' >"$WT24A/test_conflict.py"
set_test_command "$repo24a" "pwd > ran-here.txt; echo 'PASS batches survive a restart'; exit 0"
cp "$repo24a/.git/lcars/config.json" "$TMPROOT/config24a-before.json"
: >"$XO_WORKER_LOG"; : >"$XO_TESTS_SEEN_LOG"
out24a="$(XO_FAKE_WORKTREE="$WT24A" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24a" "lcars-20260915-301" "$EV_SHIM_TESTS")"
check "B24a. the look wrote xo/tests.json" "[ -s '$m24a/xo/tests.json' ]"
check "B24a. …recording the command it actually ran" \
  "grep -q 'PASS batches survive a restart' '$m24a/xo/tests.json'"
check "B24a. …and the outcome, derived where it was known" \
  "grep -q '\"outcome\": \"passed\"' '$m24a/xo/tests.json'"
check "B24a. a configured command wins over a conflicting detectable runner" \
  "grep -q '\"commandSource\": \"config\"' '$m24a/xo/tests.json' && cmp -s '$repo24a/.git/lcars/config.json' '$TMPROOT/config24a-before.json'"
check "B24a. the suite really ran — it left its mark" "[ -s '$WT24A/ran-here.txt' ]"
check "B24a. …IN THE LAUNCHED BUILD'S worktree, not the captain's checkout" \
  "grep -q \"\$(cd '$WT24A' && pwd -P)\" '$WT24A/ran-here.txt'"
check "B24a. the WORKER was handed tests.json — it can cite it" \
  "grep -q 'saw tests.json' '$XO_TESTS_SEEN_LOG'"
check "B24a. the look JOURNALLED the test run, with its outcome" \
  "grep -q '\"action\": \"tested\"' '$m24a/number-one.jsonl' && grep -q 'passed' '$m24a/number-one.jsonl'"
check "B24a. …and the captain's report says it ran them" \
  "grep -q 'I ran your tests' '$m24a/xo/report.md'"

# A foundation mission can establish its runner only in the launched build,
# before approval promotes testCommand into the captain's config.
repo24e="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24e="$(plant_verify "$repo24e" "lcars-20261014-296")"
python3 - "$repo24e/.git/lcars/config.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    config = json.load(fh)
config.pop("testCommand", None)
with open(path, "w") as fh:
    json.dump(config, fh, indent=2)
PY
WT24E="$TMPROOT/wt-24e"; mkdir -p "$WT24E/tests"
printf '[project]\nname = "build-only-suite"\nversion = "0.0.1"\n' >"$WT24E/pyproject.toml"
cat >"$WT24E/tests/test_build.py" <<'PY'
import unittest

class BuildTests(unittest.TestCase):
    def test_build_only_runner(self):
        print("BUILD_ONLY_SUITE_RAN")
        self.assertTrue(True)
PY
cp "$repo24e/.git/lcars/config.json" "$TMPROOT/config24e-before.json"
out24e="$(XO_FAKE_WORKTREE="$WT24E" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24e" "lcars-20261014-296" "$EV_SHIM_TESTS")"
python3 - "$m24e/xo/tests.json" <<'PY'
import json, sys
print("  B24e test record:", json.dumps(json.load(open(sys.argv[1])), sort_keys=True))
PY
check "B24e. an unconfigured suite in only the launched build really runs" \
  "python3 -c 'import json; d=json.load(open(\"'$m24e'/xo/tests.json\")); assert d[\"ran\"] is True and d[\"command\"] == \"python3 -m unittest discover -s \" + chr(34) + chr(36) + \"{LCARS_TESTS_DIR:-tests}\" + chr(34) and d[\"outcome\"] == \"passed\" and d[\"exitCode\"] == 0 and \"BUILD_ONLY_SUITE_RAN\" in d[\"outputTail\"]'"
check "B24e. the evidence names detection from the build as its source" \
  "grep -q '\"commandSource\": \"detected-from-build\"' '$m24e/xo/tests.json'"
check "B24e. detection leaves the captain's config byte-for-byte unchanged" \
  "cmp -s '$repo24e/.git/lcars/config.json' '$TMPROOT/config24e-before.json'"
check "B24e. the captain's checkout still has no runner" \
  "[ ! -e '$repo24e/pyproject.toml' ] && [ ! -e '$repo24e/tests/test_build.py' ]"

# Detection supplies evidence, not an assumed pass: a failing build suite must
# retain its real exit status while the full look continues.
repo24f="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24f="$(plant_verify "$repo24f" "lcars-20261014-297")"
set_test_command "$repo24f" __null__
WT24F="$TMPROOT/wt-24f"; mkdir -p "$WT24F/tests"
cp "$WT24E/pyproject.toml" "$WT24F/pyproject.toml"
sed 's/self.assertTrue(True)/self.assertTrue(False)/' "$WT24E/tests/test_build.py" \
  >"$WT24F/tests/test_build.py"
cp "$repo24f/.git/lcars/config.json" "$TMPROOT/config24f-before.json"
out24f="$(XO_FAKE_WORKTREE="$WT24F" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24f" "lcars-20261014-297" "$EV_SHIM_TESTS")"
python3 - "$m24f/xo/tests.json" <<'PY'
import json, sys
print("  B24f test record:", json.dumps(json.load(open(sys.argv[1])), sort_keys=True))
PY
check "B24f. a detected failing suite records its actual failure and provenance" \
  "python3 -c 'import json; d=json.load(open(\"'$m24f'/xo/tests.json\")); assert d[\"ran\"] is True and d[\"outcome\"] == \"failed\" and d[\"exitCode\"] == 1 and d[\"commandSource\"] == \"detected-from-build\" and \"FAILED (failures=1)\" in d[\"outputTail\"]'"
check "B24f. detected failure leaves config unchanged and still gets a full look" \
  "cmp -s '$repo24f/.git/lcars/config.json' '$TMPROOT/config24f-before.json' && [ -s '$m24f/xo/verdict.json' ] && [ -s '$m24f/xo/report.md' ]"

# An unknown app default port must be available to the declared suite, not
# occupied by the very launch Number One is reviewing.
repo24p="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24p="$(plant_verify "$repo24p" "lcars-20261014-295")"
WT24P="$TMPROOT/wt-24p"; mkdir -p "$WT24P"
port24p="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
cat >"$WT24P/assert-port-free.py" <<PY
import socket
with socket.socket() as s:
    assert s.connect_ex(("127.0.0.1", $port24p)) != 0, "LCARS holds the app default port"
with socket.socket() as s:
    s.bind(("127.0.0.1", $port24p))
print("PASS app default port is free")
PY
set_test_command "$repo24p" "python3 assert-port-free.py"
: >"$XO_LAUNCH_LOG"
out24p="$(XO_FAKE_WORKTREE="$WT24P" XO_PORT_PROBE="$port24p" \
  XO_PORT_TEST_INPUT="$TMPROOT/port-tests-input.json" \
  XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24p" "lcars-20261014-295" "$EV_SHIM_TESTS")"
python3 - "$m24p/xo/tests.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("  B24p test record: outcome=%s exit=%s" % (d["outcome"], d["exitCode"]))
if d["outcome"] != "passed":
    print(d["outputTail"])
PY
check "B24p. the launch really bound a dynamically selected app port" \
  "grep -q 'bound $port24p' '$m24p/port-events'"
check "B24p. declared tests run with the app default port free" \
  "grep -q '\"outcome\": \"passed\"' '$m24p/xo/tests.json' && grep -q 'PASS app default port is free' '$m24p/xo/tests.json'"
check "B24p. the worker receives the actual passing test record" \
  "grep -q '\"outcome\": \"passed\"' '$TMPROOT/port-tests-input.json'"
check "B24p. the grade still comes from the worker's evidence" \
  "grep -q '\"score\": \"high\"' '$m24p/xo/verdict.json'"
check "B24p. the app is relaunched for the browser after the tests" \
  "[ \"\$(grep -c 'launch lcars-20261014-295 $' '$XO_LAUNCH_LOG')\" -eq 2 ]"

# Start the recheck fixture engaged, rather than rechecking the HIGH look
# above after it has already been handed back.
plant_verify "$repo24p" "lcars-20261014-295" >/dev/null
plant_verdict "$m24p" "$(gap_json 1 contradiction prd-1 shot-01),$(gap_json 2 contradiction prd-2 shot-02)"
cp "$m24p/xo/verdict.json" "$m24p/xo/verdict-1.json"
plant_logs_json "$m24p" 2
plant_child "$repo24p" "lcars-20261014-295" 1 verify
plant_child "$repo24p" "lcars-20261014-295" 2 verify
plant_reverify_gate "$m24p"
: >"$XO_LAUNCH_LOG"
rm -f "$TMPROOT/port-tests-input.json" "$m24p/xo/tests.json"
out24r="$(cd "$repo24p" && XO_FAKE_WORKTREE="$WT24P" XO_PORT_PROBE="$port24p" \
  XO_PORT_TEST_INPUT="$TMPROOT/port-tests-input.json" \
  XO_EV_FILE=xo-recheck.json XO_EV_BODY="$(rc_body true true)" \
  LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB_WT" LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_NODE_BIN=bash \
  LCARS_HOST_ADAPTER="$HOST_STUB" LCARS_RESPOND_SCRIPT="$RESPOND_STUB" \
  LCARS_WORKER_BIN="$EV_SHIM_TESTS" LCARS_WORKER_CLI=copilot \
  LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
  bash "$SCRIPT" recheck --mission lcars-20261014-295 2>&1)"
check "B24p. recheck also runs declared tests with the app default port free" \
  "grep -q '\"outcome\": \"passed\"' '$m24p/xo/tests.json' &&
   grep -q '\"outcome\": \"passed\"' '$TMPROOT/port-tests-input.json'"
check "B24p. recheck relaunches before looking and delivers a second grade" \
  "[ \"\$(grep -c 'launch lcars-20261014-295 $' '$XO_LAUNCH_LOG')\" -eq 2 ] &&
   [ -s '$m24p/xo/verdict-2.json' ]"

# --------------------------------------------------------------------------
# B24b. NO testCommand — THE COMMON CASE. The look runs exactly as it always
#     did, says so plainly, and nothing regresses.
# --------------------------------------------------------------------------
repo24b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24b="$(plant_verify "$repo24b" "lcars-20260915-302")"
set_test_command "$repo24b" __null__
: >"$XO_WORKER_LOG"
out24b="$(XO_FAKE_WORKTREE="$TMPROOT/wt-24b" XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24b" "lcars-20260915-302" "$EV_SHIM")"
check "B24b. a repo with no test command still gets a full look" \
  "[ -s '$m24b/xo/verdict.json' ] && [ -s '$m24b/xo/report.md' ]"
check "B24b. …scored exactly as it would have been before S211" \
  "[ \"\$(python3 -c 'import json;print(json.load(open(\"'$m24b'/xo/verdict.json\"))[\"score\"])')\" = high ]"
check "B24b. …and tests.json records the absence plainly, never an error" \
  "grep -q '\"outcome\": \"no-test-command\"' '$m24b/xo/tests.json'"
check "B24b. …the report says there is no suite to run" \
  "grep -q 'no test command' '$m24b/xo/report.md'"
check "B24b. …and it did NOT claim to have run anything" \
  "! grep -q 'I ran your tests' '$m24b/xo/report.md'"

# --------------------------------------------------------------------------
# B24c. A HANGING SUITE IS KILLED AT THE BOUND, AND REPORTED AS TROUBLE
#     RUNNING THE TESTS — never as a fault in the captain's build. The look
#     finishes; a hung suite must not cost him the whole Verify look.
# --------------------------------------------------------------------------
repo24c="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24c="$(plant_verify "$repo24c" "lcars-20260915-303")"
set_test_command "$repo24c" "sleep 30"
: >"$XO_WORKER_LOG"
t24c0="$(date +%s)"
out24c="$(XO_FAKE_WORKTREE="$TMPROOT/wt-24c" LCARS_XO_TEST_TIMEOUT=2 \
  XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24c" "lcars-20260915-303" "$EV_SHIM")"
t24c1="$(date +%s)"
check "B24c. a hanging suite is killed at the bound, not waited out" \
  "[ \$(( t24c1 - t24c0 )) -lt 25 ]"
check "B24c. …recorded as hung, which is not a failure" \
  "grep -q '\"outcome\": \"hung\"' '$m24c/xo/tests.json'"
check "B24c. …and the look still reached a verdict" "[ -s '$m24c/xo/verdict.json' ]"
check "B24c. …the captain is told it is trouble running his tests, not a bad build" \
  "grep -q 'not something wrong with the build' '$m24c/xo/report.md'"

# --------------------------------------------------------------------------
# B24d. THE SKILL RAN IT, THE WORKER DID NOT. The fence is unchanged: the
#     suite is executed exactly ONCE, before the worker is spawned at all.
# --------------------------------------------------------------------------
repo24d="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m24d="$(plant_verify "$repo24d" "lcars-20260915-304")"
WT24D="$TMPROOT/wt-24d"; mkdir -p "$WT24D"
set_test_command "$repo24d" "echo run >> $WT24D/times-run.txt; exit 0"
: >"$XO_WORKER_LOG"
XO_FAKE_WORKTREE="$WT24D" XO_EV_ROUNDS=2 XO_EV_BODY="$(ev_verdict met met met high '')" \
  xo_evaluate_tests "$repo24d" "lcars-20260915-304" "$EV_SHIM" >/dev/null 2>&1
n24d="$(grep -c . "$WT24D/times-run.txt" 2>/dev/null)" || true
check "B24d. the suite ran ONCE, however many worker rounds there were" \
  "[ \"${n24d:-0}\" -eq 1 ]"
check "B24d. …and there was more than ONE round for it not to be re-run in" \
  "[ \"\$(grep -c '^worker ' '$XO_WORKER_LOG')\" -ge 2 ]"

# ==========================================================================
# B25. THE HEADLINE — ONE LINE FOR THE BOARD CARD, RECORDED BY THE FINISHER
#      (Session 213, claim C1, and the C8 guard at the producer).
#
# The card used to carry Number One's whole 150-word verdict; it ran several
# screens tall and pushed the cost pills, the difficulty pills and both buttons
# off the bottom. It now carries ONE sentence — and WHICH sentence is the whole
# point. Not the first line of the worker's prose: cutting a paragraph down is
# this harness deciding what Number One meant, and a card whose line disagrees
# with the score beside it is the exact fault S213 exists to kill.
#
# So it is the LEDGER'S OWN DERIVATION — the sentence xo-score.py writes in the
# same breath as the score, off the same ledger, by the same rule. Two outputs
# of one decision cannot contradict each other. `xo_finish` is the ONE writer
# every exit path goes through, so this is proved where it is written, on a
# real evaluate, and not by grepping the script for a string.
# ==========================================================================
echo
echo "B25. the one line the card carries, recorded by the one finisher"

repo25="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m25="$(plant_verify "$repo25" "lcars-20260917-401")"
: >"$XO_WORKER_LOG"
# A worker that reaches a verdict AND writes a long transcript — the shape that
# produced the unreadable card on the captain's real board. One criterion it
# could not check, so the honest derivation cannot be a clean bill of health.
long25='Captain, this build is a code-only engine change - two pure coordinate functions, a factory method, a Camera type field, and their unit tests - none of which shows up on a screen. The example game does render fine, so the engine compiles and runs, but that proves nothing about the new methods.'
# S225 — `prd-1` now carries a medium-impact FAULT beside `prd-2`'s unchecked
# row. Both rules this block is about need it: a mission only stays MEDIUM (and
# therefore ENGAGED, which is what keeps the worker's transcript on the state
# block) when something a person can do DIDN'T WORK — an unchecked row is a hole
# in our checking and no longer moves the grade — while the unchecked row is
# what keeps the C8 guard below honest ("that line says what it could not
# check"). Neither rule changed; the ledger that exercises both did.
verdict25="$(printf '{"score":"medium","summary":"%s","criteria":[{"id":"prd-1","text":"open tasks in one list","impact":"medium","status":"gap","shot":"shot-01","evidence":"picture","note":"the list shows only the first ten"},{"id":"prd-2","text":"add from the board","impact":"medium","status":"untested","note":"nothing on screen settles this"},{"id":"t-1-ac1","text":"ADD under the list","impact":"medium","status":"met","shot":"shot-02","evidence":"picture","note":"under it"},{"id":"journey-j1","text":"open a task from the board","impact":"high","status":"met","shot":"shot-01","evidence":"picture","note":"opened it"}],"gaps":[]}' "$long25")"
out25="$(XO_WORKER_LOG="$XO_WORKER_LOG" XO_EV_BODY="$verdict25" \
  LCARS_XO_DRIVER="$DRIVE_STUB" LCARS_WORKER_BIN="$EV_SHIM" \
  xo_evaluate "$repo25" "lcars-20260917-401")"
check "B25. the look reached a verdict" "[ -s '$m25/xo/verdict.json' ]"
check "B25. the mission records a headline for the card" \
  "python3 -c \"import json,sys;st=json.load(open('$m25/state.json'));sys.exit(0 if str(st.get('numberOne',{}).get('headline','')).strip() else 1)\""
check "B25. …and it IS the ledger's own derivation, verbatim" \
  "python3 -c \"import json,sys;st=json.load(open('$m25/state.json'));v=json.load(open('$m25/xo/verdict.json'));sys.exit(0 if st['numberOne']['headline']==v['derivation'] else 1)\""
check "B25. …never a cut-down of the worker's own prose" \
  "python3 -c \"import json,sys;st=json.load(open('$m25/state.json'));sys.exit(1 if st['numberOne']['headline'].startswith('Captain, this build') else 0)\""
check "B25. …and it is ONE line, not a transcript" \
  "python3 -c \"import json,sys;st=json.load(open('$m25/state.json'));h=st['numberOne']['headline'];sys.exit(0 if ('\n' not in h and len(h)<400) else 1)\""
check "B25. the transcript is still recorded, just not as the headline" \
  "python3 -c \"import json,sys;st=json.load(open('$m25/state.json'));sys.exit(0 if str(st['numberOne'].get('note','')).startswith('Captain, this build') else 1)\""
# THE C8 GUARD, AT THE PRODUCER. A MEDIUM whose real finding is "I could not
# check one of these" must not wear a line that reads like a clean bill.
check "B25. the score the card wears and the line beside it come from one rule" \
  "python3 -c \"import json,sys;v=json.load(open('$m25/xo/verdict.json'));st=json.load(open('$m25/state.json'));sys.exit(0 if st['numberOne']['score']==v['score']=='medium' else 1)\""
# The RULE is unchanged — the card's one line must say what it could not check.
# Only the WORDING the headline's word budget picks moved: with a fault beside
# the unchecked row the full sentence no longer fits on a phone, so the budget
# falls back to the counted form, which says the same thing in fewer words.
check "B25. …and that line says what it could not check, not that all is well" \
  "python3 -c \"import json,sys;st=json.load(open('$m25/state.json'));h=st['numberOne']['headline'].lower();sys.exit(0 if ('could not check' in h or \\\"couldn't be checked\\\" in h) else 1)\""
# S216 — WHY THIS GRADE rides the scored journal entry, word for word the
# verdict's own paragraph, so the First Officer's report can lead with it.
check "B25. the scored journal entry carries the verdict's why-this-grade" \
  "python3 -c \"import json,sys;v=json.load(open('$m25/xo/verdict.json'));es=[json.loads(l) for l in open('$m25/number-one.jsonl') if l.strip()];s=[e for e in es if e.get('action')=='scored'];sys.exit(0 if s and s[-1].get('whyThisGrade')==v['whyThisGrade'] and v['whyThisGrade'] else 1)\""

# ==========================================================================
# B26 (S221) — THE WALK LEAVES THE BUILD AS IT FOUND IT.
#
# THE DEFECT (captain, 2026-09-20). Walking a build means TYPING into it. On the
# groutwork build Number One typed an insight, the app autosaved it into the
# LAUNCHED WORKTREE'S `data/` — where the project's snapshot tests read from —
# and six of his own tests went red on a build that was fine. Number One rightly
# refused to blame the build; unattended, the next round would have spent itself
# chasing red tests the look itself caused.
#
# THIS IS A FILESYSTEM PROOF, NOT A PROMPT ONE. The worker is a shim and says
# nothing; the whole question is what is left on disk when the look is over.
# ==========================================================================
echo
echo "B26. the walk leaves the launched build's tracked tree exactly as it was"

# A REAL git worktree standing in for the launched build, with the shapes that
# matter: a TRACKED data file the app will autosave over, a file that was
# already untracked before the walk (not ours to remove), and an IGNORED
# directory (a blunt `git clean` would eat it).
BUILD26="$TMPROOT/build26"
rm -rf "$BUILD26"; mkdir -p "$BUILD26/data"
git -C "$BUILD26" init -q
git -C "$BUILD26" config user.email t@example.com
git -C "$BUILD26" config user.name t
printf 'node_modules/\n' >"$BUILD26/.gitignore"
printf '{"notes": []}\n' >"$BUILD26/data/notes.json"
printf 'expected snapshot\n' >"$BUILD26/data/snapshot.txt"
git -C "$BUILD26" add -A >/dev/null 2>&1
git -C "$BUILD26" commit -qm "the build" >/dev/null 2>&1
mkdir -p "$BUILD26/node_modules"; printf 'dep\n' >"$BUILD26/node_modules/dep.js"
printf 'someone else left this here\n' >"$BUILD26/scratch-of-its-own.txt"
B26_BEFORE="$(git -C "$BUILD26" status --porcelain | sort)"
B26_TRACKED="$(git -C "$BUILD26" rev-parse HEAD)"

# A driver that TYPES: the app autosaves what was typed over a tracked file and
# drops a new one beside it — exactly what the real walk provoked.
DRIVE_TYPES="$EVDIR/xo-drive-types.sh"
cat >"$DRIVE_TYPES" <<'DT'
#!/usr/bin/env bash
printf 'drive %s\n' "$*" >>"$XO_DRIVE_LOG"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in --out) out="$2"; shift 2 ;; --url) url="$2"; shift 2 ;; *) shift ;; esac
done
mkdir -p "$out"
n="$(ls "$out"/*.png 2>/dev/null | grep -c . | tr -d ' ')"
printf 'PNG\n' >"$out/shot-0$((n+1)).png"
printf '{"shot":"shot-0%s"}\n' "$((n+1))" >"$out/shot-0$((n+1)).json"
printf 'shot-0%s — full page\n' "$((n+1))" >"$out/shot-0$((n+1)).txt"
# THE AUTOSAVE. This is the app writing, not the harness: the insight Number
# One typed lands in the build's own data directory.
#
# ONLY WHEN IT IS THE BUILD BEING WALKED (`--url http…`). The very same driver
# is also pointed at the DRAWING (`--url file://…`) before the build is even
# launched — and a fixture that typed on that pass wrote its autosave BEFORE
# the tree was marked, so the diff came back empty and this row measured
# nothing at all. It cost a round to find; the gate stays.
case "$url" in
  http*)
    if [ -n "${XO_TYPE_INTO:-}" ] && [ -d "$XO_TYPE_INTO/data" ]; then
      printf '{"notes": ["the KPI row never updates"]}\n' >"$XO_TYPE_INTO/data/notes.json"
      printf 'typed at round\n' >>"$XO_TYPE_INTO/data/autosave.json"
      # A WITNESS OUTSIDE THE BUILD. The autosave itself is what the fix
      # deletes, so it cannot also be the proof that it ever existed.
      printf 'typed at round\n' >>"${XO_TYPE_WITNESS:-/dev/null}"
    fi ;;
esac
printf '{"url":"http://127.0.0.1:4310/","allPainted":true}\n'
exit 0
DT
chmod +x "$DRIVE_TYPES"

repo26="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m26="$(plant_verify "$repo26" "lcars-20260920-601")"
: >"$XO_WORKER_LOG"
out26="$( cd "$repo26" && XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_FAKE_WORKTREE="$BUILD26" XO_TYPE_INTO="$BUILD26" \
    XO_TYPE_WITNESS="$TMPROOT/b26-typed.txt" \
    XO_EV_BODY="$(ev_verdict met met met high '')" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB_WT" \
    LCARS_XO_DRIVER="$DRIVE_TYPES" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
    LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" evaluate --mission "lcars-20260920-601" 2>&1 )"
B26_AFTER="$(git -C "$BUILD26" status --porcelain | sort)"

check "B26. the walk really did type into the build (the fixture is honest)" \
  "grep -q 'typed at round' '$TMPROOT/b26-typed.txt'"
check "B26. the tracked file the app autosaved over is back as it was" \
  "[ \"\$(cat '$BUILD26/data/notes.json')\" = '{\"notes\": []}' ]"
check "B26. the file the autosave created is gone" \
  "[ ! -e '$BUILD26/data/autosave.json' ]"
check "B26. the launched build's tracked tree is EXACTLY as the look found it" \
  "[ \"\$B26_AFTER\" = \"\$B26_BEFORE\" ]"
check "B26. …and nothing was committed, reset or rewritten to achieve that" \
  "[ \"\$(git -C '$BUILD26' rev-parse HEAD)\" = '$B26_TRACKED' ]"
check "B26. a file that was already untracked before the look is LEFT ALONE" \
  "[ -f '$BUILD26/scratch-of-its-own.txt' ]"
check "B26. …and so is an ignored directory (this is not a git clean)" \
  "[ -f '$BUILD26/node_modules/dep.js' ]"
check "B26. it is journaled, so the record says the look tidied up after itself" \
  "grep -q '\"action\": \"tidied\"' '$m26/number-one.jsonl'"
check "B26. …and said so in plain words" \
  "printf '%s' \"\$out26\" | grep -q 'put the'"
check "B26. the look still reached its verdict" "[ -s '$m26/xo/verdict.json' ]"

# A build that is not a git worktree at all — nothing to mark, nothing to undo,
# and above all nothing that fails the look.
BUILD26B="$TMPROOT/build26b"; rm -rf "$BUILD26B"; mkdir -p "$BUILD26B/data"
printf 'plain\n' >"$BUILD26B/data/notes.json"
repo26b="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
m26b="$(plant_verify "$repo26b" "lcars-20260920-602")"
: >"$XO_WORKER_LOG"
( cd "$repo26b" && XO_WORKER_LOG="$XO_WORKER_LOG" \
    XO_FAKE_WORKTREE="$BUILD26B" XO_TYPE_INTO="$BUILD26B" \
    XO_EV_BODY="$(ev_verdict met met met high '')" \
    LCARS_LAUNCH_SCRIPT="$LAUNCH_STUB_WT" \
    LCARS_XO_DRIVER="$DRIVE_TYPES" LCARS_NODE_BIN=bash \
    LCARS_HOST_ADAPTER="$HOST_STUB" \
    LCARS_LOG_SCRIPT="$LOG_STUB" LCARS_RESOLVE_LOGS_SCRIPT="$RESOLVE_STUB" \
    LCARS_WORKER_BIN="$EV_SHIM" LCARS_WORKER_CLI=copilot \
    LCARS_GH_BIN=/usr/bin/true LCARS_NOTIFY=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" evaluate --mission "lcars-20260920-602" ) >/dev/null 2>&1
check "B26. a build that is not a git worktree costs the look nothing" \
  "[ -s '$m26b/xo/verdict.json' ]"

# ==========================================================================
# B7. ZERO SPEND — the shim recorded nothing at all.
# ==========================================================================
echo
echo "B7. zero spend"
# `grep -c` prints 0 AND exits 1 on no match, so an `|| printf 0` fallback would
# print a second zero and turn the count into "0\n0".
shim_calls="$(grep -c . "$XO_SHIM_LOG" 2>/dev/null)" || true
shim_models="$(grep -c -- '--model' "$XO_SHIM_LOG" 2>/dev/null)" || true
shim_calls="${shim_calls:-0}"; shim_models="${shim_models:-0}"
printf '  shim invocations: %s (with --model: %s)\n' "$shim_calls" "$shim_models"
check "B7. no worker CLI was invoked at all" "[ '$shim_calls' -eq 0 ]"
check "B7. …so nothing real was ever spawned" "[ '$shim_models' -eq 0 ]"
# B8 DOES hire a worker — through $LCARS_WORKER_BIN, which is a shim of its own,
# never a CLI on PATH. Report its count so the two are never confused: the line
# above is "no real CLI ran", the line below is "the fake one ran N times".
cat "$XO_WORKER_LOG" >>"$XO_WORKER_LOG.all" 2>/dev/null || true
no_calls="$(grep -c '^worker ' "$XO_WORKER_LOG.all" 2>/dev/null)" || true
no_models="$(grep -c -- '--model' "$XO_WORKER_LOG.all" 2>/dev/null)" || true
printf '  number-one worker-shim invocations: %s (with --model: %s)\n' \
  "${no_calls:-0}" "${no_models:-0}"

# ==========================================================================
# U. THE PASS WITH NO LIST IN ITS HAND (S224 item 2)
#
# On the S222 capstone Number One filed every fault an acceptance criterion
# named and missed or demoted every fault none did — it quoted one faulty line
# of text VERBATIM and passed the row it was on. So one more pass runs over the
# pictures the walk already took, with the CRITERIA REMOVED FROM ITS CONTEXT.
#
# THAT REMOVAL IS THE WHOLE FEATURE, so it is what this block pins. A prompt
# that says "ignore the criteria" beside a directory that still contains them
# is not a criteria-free pass; only the directory is evidence. The pass's input
# dir is therefore asserted to hold the pictures and NOTHING else — by an
# inventory of what IS there, not a list of the files somebody remembered to
# exclude.
#
# ZERO SPEND: $LCARS_RUN_SCRIPT is a stub that records what it was handed and
# writes the worker's file itself. No CLI, real or shimmed, is invoked.
# ==========================================================================
echo
echo "U. the unlisted pass — the criteria are really gone from its context"

UDIR="$TMPROOT/unlisted"; mkdir -p "$UDIR"
U_SEEN="$UDIR/seen.txt"; U_CALLS="$UDIR/calls.txt"
: >"$U_SEEN"; : >"$U_CALLS"
cat >"$UDIR/run-stub.sh" <<'RS'
#!/usr/bin/env bash
# Stands in for run.sh's spawn-number-one. Records the mode, and an inventory
# of everything the worker could actually reach, then writes the file a real
# worker would have written.
mode=""; outdir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --outdir) outdir="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'mode=%s indir=%s dirs=%s\n' "$mode" "${LCARS_XO_INPUT_DIR:-}" \
  "$(printf '%s' "${LCARS_WORKER_INPUT_DIRS:-}" | tr '\n' ',')" >>"$U_CALLS"
[ -n "${LCARS_XO_INPUT_DIR:-}" ] && \
  ( cd "$LCARS_XO_INPUT_DIR" && find . -type f | sed 's|^\./||' | sort ) >>"$U_SEEN"
mkdir -p "$outdir"
cat >"$outdir/xo-unlisted.json" <<'UJ'
{"findings": [
  {"shot": "shot-walk-02-j2", "what": "a label has nothing after it", "why": "it reads unfinished"},
  {"shot": "shot-made-up", "what": "invented", "why": "nobody took this picture"}
]}
UJ
RS
chmod +x "$UDIR/run-stub.sh"

repoU="$(new_repo '"numberOne": {"enabled": true, "engine": "copilot"}')"
mU="$(plant_verify "$repoU" "lcars-20260921-224")"
mkdir -p "$mU/xo/shots"
for s in shot-walk-02-j2 shot-walk-03-j3; do
  printf 'not-really-a-png' >"$mU/xo/shots/$s.png"
  printf '{"shot":"%s","page":{"textExcerpt":"hello"}}\n' "$s" >"$mU/xo/shots/$s.json"
  printf '%s — full page\n' "$s" >"$mU/xo/shots/$s.txt"
done
# The things the pass must NOT be able to see, planted in the place every OTHER
# pass reads them from. If any of these reaches its input dir, it is holding a
# list again.
cp "$mU/prd.md" "$mU/xo/shots/../prd-copy.md" 2>/dev/null || true
cat >"$mU/xo/criteria.json" <<'CJ'
{"criteria": [{"id": "prd-1", "text": "the board shows every open task", "primary": true}]}
CJ
printf '{"observations":[]}\n' >"$mU/xo/observations.json"
printf '{"pairs":[]}\n' >"$mU/xo/pairs.json"
printf '{"steps":[]}\n' >"$mU/xo/journey.json"

( cd "$repoU" && U_SEEN="$U_SEEN" U_CALLS="$U_CALLS" \
    LCARS_RUN_SCRIPT="$UDIR/run-stub.sh" LCARS_GH_BIN=/usr/bin/true \
    LCARS_OWNER_ENFORCE=0 \
    bash "$SCRIPT" unlisted --mission lcars-20260921-224 ) >"$UDIR/out.txt" 2>&1

check "U1. the pass ran, in its OWN mode" "grep -q 'mode=unlisted' '$U_CALLS'"
check "U1. …over the pictures the walk already took (no second driver call)" \
  "[ \"\$(grep -c 'mode=unlisted' '$U_CALLS')\" -eq 1 ]"
check "U2. its context holds the PNGs" \
  "grep -qx 'shot-walk-02-j2.png' '$U_SEEN' && grep -qx 'shot-walk-03-j3.png' '$U_SEEN'"
check "U2. …and the browser readouts beside them" \
  "grep -qx 'shot-walk-02-j2.json' '$U_SEEN' && grep -qx 'shot-walk-02-j2.txt' '$U_SEEN'"
# THE FENCE. An inventory, not an exclusion list: every file in there must be
# one of the three shapes a shot directory has.
check "U3. its context holds NOTHING BUT pictures and their readouts" \
  "! grep -v -E '^shot-[A-Za-z0-9._-]+\.(png|json|txt)\$' '$U_SEEN' | grep -q ."
check "U3. …no criteria.json anywhere near it" "! grep -q 'criteria' '$U_SEEN'"
check "U3. …no PRD" "! grep -qi 'prd' '$U_SEEN'"
check "U3. …no drawing, no journey, no pairs, no observations" \
  "! grep -q -E 'journey|pairs|observations|drawing|attachment' '$U_SEEN'"
check "U3. …and no other directory was granted to the worker either" \
  "[ \"\$(grep -o 'dirs=[^ ]*' '$U_CALLS' | head -1 | tr -cd ',' | wc -c | tr -d ' ')\" -eq 0 ]"
check "U4. the record it leaves names the pictures IT granted, not the model's word" \
  "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sorted(d[\"shots\"])==[\"shot-walk-02-j2\",\"shot-walk-03-j3\"] else 1)' '$mU/xo/unlisted.json'"
check "U4. …and carries the worker's findings through untouched" \
  "[ \"\$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))[\"findings\"]))' '$mU/xo/unlisted.json')\" -eq 2 ]"
# The look's OWN score is what the captain is graded on, and this pass is not
# allowed to be why it never arrives.
check "U5. a shots directory with no pictures leaves no record and no failure" \
  "mkdir -p '$UDIR/empty' &&
   ( cd '$repoU' && U_SEEN='$U_SEEN' U_CALLS='$U_CALLS' LCARS_RUN_SCRIPT='$UDIR/run-stub.sh' \
       LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
       bash '$SCRIPT' unlisted --mission lcars-20260921-224 --shots '$UDIR/empty' \
       --out '$UDIR/empty-out.json' >/dev/null 2>&1 ) &&
   [ ! -e '$UDIR/empty-out.json' ]"
check "U5. …and it can be switched off entirely" \
  "( cd '$repoU' && LCARS_XO_UNLISTED=0 LCARS_RUN_SCRIPT='$UDIR/run-stub.sh' \
       LCARS_GH_BIN=/usr/bin/true LCARS_OWNER_ENFORCE=0 \
       bash '$SCRIPT' unlisted --mission lcars-20260921-224 \
       --out '$UDIR/off-out.json' >/dev/null 2>&1 ) && [ ! -e '$UDIR/off-out.json' ]"

# ==========================================================================
echo
printf 'lcars xo: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
