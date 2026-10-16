#!/usr/bin/env bash
# The real driver's stored reviewer lifecycle, with forge and paid CLIs stubbed.
# Run from the repository root; TMPDIR can redirect the disposable scratch.
set -uo pipefail

ROOT="$PWD"
RUN="$ROOT/skills/lcars-run/run.sh"
APPROVE="$ROOT/skills/lcars-approve/approve.sh"
MID="lcars-20261015-001"
WORK="$(mktemp -d "${TMPDIR:-$ROOT}/reviewer-lifecycle.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export REVIEWER_CALLS="$WORK/worker-calls"
export REVIEWER_GH_CALLS="$WORK/gh-calls"
export REVIEWER_NETWORK_CALLS="$WORK/network-calls"
export REVIEWER_REAL_GIT="$(command -v git)"
: >"$REVIEWER_CALLS"
: >"$REVIEWER_GH_CALLS"
: >"$REVIEWER_NETWORK_CALLS"
pass=0 fail=0

# Both host-detected CLIs AND the explicit worker override are trapped.
for cli in claude copilot worker; do
  cat >"$WORK/bin/$cli" <<'SHIM'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$REVIEWER_CALLS"
exit 97
SHIM
  chmod +x "$WORK/bin/$cli"
done
cat >"$WORK/bin/git" <<'SHIM'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    fetch|push|pull|ls-remote|clone)
      printf 'git %s\n' "$*" >>"$REVIEWER_NETWORK_CALLS"
      exit 97 ;;
  esac
done
exec "$REVIEWER_REAL_GIT" "$@"
SHIM
for command in curl wget; do
  cat >"$WORK/bin/$command" <<'SHIM'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$REVIEWER_NETWORK_CALLS"
exit 97
SHIM
  chmod +x "$WORK/bin/$command"
done
cat >"$WORK/bin/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REVIEWER_GH_CALLS"
case "$*" in
  'pr view '*) printf '{"state":"MERGED","mergedAt":"2026-10-15T10:00:00Z"}\n' ;;
esac
exit 0
SHIM
cat >"$WORK/bin/noop" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x "$WORK/bin/git" "$WORK/bin/gh" "$WORK/bin/noop"
export PATH="$WORK/bin:$PATH"
export LCARS_WORKER_BIN="$WORK/bin/worker" LCARS_WORKER_CLI=copilot
export LCARS_GH_BIN="$WORK/bin/gh"
export LCARS_GIT_BIN="$WORK/bin/git"
export LCARS_NOTIFY="$WORK/bin/noop" LCARS_VERSION_CHECK_BIN="$WORK/bin/noop"
export LCARS_OWNER_ENFORCE=0 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS=

check() {
  local label="$1"; shift
  if "$@"; then
    printf 'PASS %s\n' "$label"; pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$label"; fail=$((fail + 1))
  fi
}

FINISHED='{"status":"finished","engine":"claude","since":"2026-10-14T08:00:00Z","evaluatedAt":"2026-10-14T09:00:00Z","score":"high","note":"Intent matched","lastAction":"evaluate","lastPending":"123-456","round":2}'
ENGAGED='{"status":"engaged","engine":"claude","since":"2026-10-14T08:00:00Z","note":"Look abandoned before completion"}'

fixture() { # name stage numberOne-json-or-null [paused]
  local name="$1" stage="$2" reviewer="$3" paused="${4:-false}"
  REPO="$WORK/$name"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  MISSION="$REPO/.git/lcars/missions/$MID"
  mkdir -p "$MISSION"
  python3 - "$MISSION" "$MID" "$stage" "$reviewer" "$paused" "$REPO" <<'PY'
import json, pathlib, sys
m, mid, stage, reviewer, paused, repo = sys.argv[1:]
m = pathlib.Path(m)
state = dict(id=mid, type="feature", title="Reviewer lifecycle", stage=stage,
             githubIssue=42, prUrl="https://example.invalid/org/repo/pull/7",
             prNumber=7, paused=paused == "true", created="2026-10-14T08:00:00Z")
if reviewer != "null":
    state["numberOne"] = json.loads(reviewer)
(m / "state.json").write_text(json.dumps(state, indent=2) + "\n")
(m / "before.json").write_text(json.dumps(state))
(m / "prd.md").write_text("# Reviewer lifecycle\nPreserve completed review evidence.\n")
(m / "events.jsonl").touch()
config = dict(cloneId="aaaaaaaa", projectName="fixture", testCommand="true",
              numberOne=dict(enabled=True, engine="copilot"))
(pathlib.Path(repo) / ".git/lcars/config.json").write_text(json.dumps(config, indent=2) + "\n")
PY
}

drive() { (cd "$REPO" && bash "$RUN" drive --mission "$MID"); }

state_is() {
  python3 - "$MISSION" "$1" "$2" <<'PY'
import json, pathlib, sys
m = pathlib.Path(sys.argv[1])
state = json.loads((m / "state.json").read_text())
before = json.loads((m / "before.json").read_text())
kind, expected = sys.argv[2:]
if kind == "stage":
    assert state["stage"] == expected, state
elif kind == "same":
    assert ("numberOne" in state) == ("numberOne" in before), state
    assert state.get("numberOne") == before.get("numberOne"), state.get("numberOne")
elif kind == "engaged":
    assert state["numberOne"]["status"] == "engaged", state
    assert "evaluatedAt" not in state["numberOne"], state
elif kind == "not-finished":
    assert state.get("numberOne", {}).get("status") != "finished", state
    assert "evaluatedAt" not in state.get("numberOne", {}), state
PY
}

echo "Reviewer lifecycle — real bash driver and stored state"
fixture merged-finished verify "$FINISHED"
check "merged review: driver succeeds" drive
check "merged review: stage becomes done" state_is stage done
check "merged review: entire finished metadata survives" state_is same ""
check "merge was observed through GH" grep -q '^pr view 7 --json state,mergedAt' "$REVIEWER_GH_CALLS"

fixture done-finished done "$FINISHED"
for repeat in 1 2; do
  check "done review pass $repeat: driver succeeds" drive
  check "done review pass $repeat: stage stays done" state_is stage done
  check "done review pass $repeat: entire finished metadata survives" state_is same ""
done

fixture done-no-reviewer done null
check "done without reviewer: driver succeeds" drive
check "done without reviewer: no reviewer is invented despite repo enabled" state_is same ""
check "done without reviewer: completion is not fabricated" state_is not-finished ""

fixture done-abandoned done "$ENGAGED"
check "done abandoned look: driver succeeds" drive
check "done abandoned look: unfinished metadata remains unchanged" state_is same ""
check "done abandoned look: completion is not fabricated" state_is not-finished ""

fixture merged-no-reviewer verify null
check "merge without review: driver succeeds" drive
check "merge without review: stage becomes done" state_is stage done
check "merge without review: engagement is not a completed review" state_is engaged ""

fixture merged-abandoned verify "$ENGAGED"
check "merge abandoned look: driver succeeds" drive
check "merge abandoned look: stage becomes done" state_is stage done
check "merge abandoned look: unfinished metadata remains unchanged" state_is same ""

fixture active-engaged schedule "$ENGAGED" true
check "active engaged mission: driver succeeds" drive
check "active engaged mission: stage is unchanged" state_is stage schedule
check "active engaged mission: conn and timestamp are unchanged" state_is same ""

fixture active-new schedule null true
check "active new mission: driver succeeds" drive
check "active new mission: stage is unchanged" state_is stage schedule
check "active new mission: reviewer still engages normally" state_is engaged ""

# Approval's merge-only entry point is a control: it never re-engaged Number
# One. The fixture has no branch, so no git push is attempted; GH is a shim.
fixture approve-finished verify "$FINISHED"
approve() { (cd "$REPO" && bash "$APPROVE" --mission "$MID" --reapprove); }
check "approve control: command succeeds" approve
check "approve control: stage becomes done" state_is stage done
check "approve control: entire finished metadata survives" state_is same ""

cli_calls="$(wc -l <"$REVIEWER_CALLS" | tr -d ' ')"
model_flags="$(grep -Ec -- '(^| )(-m|--model)( |[=])' "$REVIEWER_CALLS" || true)"
printf 'Worker invocations: %s; model-flag invocations: %s\n' "$cli_calls" "$model_flags"
check "ZERO claude, copilot, or explicit worker invocations" test "$cli_calls" = 0
check "ZERO model-flag invocations" test "$model_flags" = 0
check "ZERO git or HTTP network attempts" test ! -s "$REVIEWER_NETWORK_CALLS"
printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
