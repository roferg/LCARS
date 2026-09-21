#!/usr/bin/env bash
# S221 fix 4 — measure the gap under BOTH filter rows in REAL headless Chrome.
#
#   bash tests/drives/s221/run.sh [<scratch-dir>]
#
# Boots the REAL daemon (tests/drives/s223/rig.sh, inherited not rebuilt)
# against a THROWAWAY fixture repo, opens both reports in real Chrome, and
# prints the measured px gap under each filter row. Reaps ONLY its own PIDs —
# never by name; the captain runs his own viewscreen daemon.
#
# Zero spend: the rig's PATH shim fakes claude/copilot/gh and exits 1.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
SCR="${1:-${TMPDIR:-/tmp}/lcars-s221}"
mkdir -p "$SCR"
. "$REPO_ROOT/tests/drives/s223/rig.sh"
trap s223_teardown EXIT

FX="$SCR/fx"; rm -rf "$FX"; mkdir -p "$FX"
git -C "$FX" init -q
git -C "$FX" config user.email t@example.com
git -C "$FX" config user.name t
printf 'a build\n' >"$FX/README.md"
git -C "$FX" add -A >/dev/null 2>&1 && git -C "$FX" commit -qm init >/dev/null 2>&1
mkdir -p "$FX/.git/lcars/missions/lcars-20260920-001"
printf '{"repo": "roferg/fixture", "testCommand": "true"}\n' >"$FX/.git/lcars/config.json"
cat >"$FX/.git/lcars/missions/lcars-20260920-001/state.json" <<'JSON'
{"id":"lcars-20260920-001","type":"feature","title":"The tile readout",
 "stage":"verify","created":"2026-09-20T10:00:00Z","githubIssue":10,
 "branch":"lcars/lcars-20260920-001","base":"main",
 "numberOne":{"status":"finished","score":"medium","engine":"copilot",
   "headline":"Most of it works; one thing I could not check."}}
JSON
# A JOURNAL, so the First Officer's report has real entries to head — an empty
# report renders its empty-state note, and a gap measured against that is a gap
# under nothing. These are the shapes xo-report.py ranks: a verdict, a step, and
# something that needs him.
J="$FX/.git/lcars/missions/lcars-20260920-001/number-one.jsonl"
cat >"$J" <<'JL'
{"at":"2026-09-20T10:01:00Z","action":"criteria","count":12}
{"at":"2026-09-20T10:02:00Z","action":"launched","url":"http://127.0.0.1:4310/"}
{"at":"2026-09-20T10:03:00Z","action":"looked","round":0,"shots":6}
{"at":"2026-09-20T10:05:00Z","action":"scored","score":"medium","whyThisGrade":"Most of it works; one thing I could not check."}
{"at":"2026-09-20T10:06:00Z","action":"filed-logs","count":2}
{"at":"2026-09-20T10:07:00Z","action":"escalated","note":"I could not reach the settings screen."}
JL

OUT="$SCR/run"; rm -rf "$OUT"; mkdir -p "$OUT"
SHOTS="${S221_SHOTS:-$HERE/shots}"
s223_start_daemon "$FX" "$OUT" || exit 1
s223_start_chrome "$OUT" || exit 1
node "$HERE/gap.js" --devtools-port "$DEV_PORT" --url "$BOARD_URL" --out "$SHOTS" \
  "${@:2}" | tee "$OUT/gap.json"
rc="${PIPESTATUS[0]}"
python3 - "$OUT/gap.json" <<'PY' || true
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("could not read the measurement: %s" % e); raise SystemExit(0)
for c in d.get("checks", []):
    print(("PASS " if c["ok"] else "FAIL ") + c["name"])
for k, v in (d.get("rows") or {}).items():
    print("  %-20s gap = %s px   (row margin-bottom %s, next %s)"
          % (k, v.get("gap"), v.get("rowMarginBottom"), v.get("nextTag")))
PY
echo "shim invocations: $(s223_shim_count "$OUT")"
exit "$rc"
