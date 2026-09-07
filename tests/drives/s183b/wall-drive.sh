# S182's WALL, belt-and-braces: a runnerless repo must still PARK at Implement
# with ZERO hires. Drives the STAGE (`run.sh implement`), not implement-ticket.
set -u
S182="$(dirname "${BASH_SOURCE[0]}")/../s182/rig.sh"
# S182's rig FIRST — its `drive` has a bash-3.2 empty-array bug under `set -u`;
# ours is sourced after so the fixed one wins. Its fixtures/shim are what we want.
. "$S182"
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="$(dirname "${BASH_SOURCE[0]}")/logs/wall.calls"; : > "$LOG"
SH="$(make_shim_compliant "$LOG")"; fuse "$SH" || exit 99
p="$(newrepo wall-runnerless)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{ "name": "runnerless", "scripts": { "dev": "vite" } }
J
echo "export const a=1" > "$p/src/a.js"
commitall "$p" "initial"
mkdir -p "$p/.git/lcars"
cat > "$p/.git/lcars/config.json" <<'J'
{
  "model": "claude-sonnet",
  "projectName": "runnerless",
  "contextFile": null,
  "stack": "js",
  "testCommand": "",
  "worktreeSetupCommand": "",
  "comprehensionBudget": 40,
  "lcarsVersion": "2026.9.1",
  "created": "2026-09-05T00:00:00Z"
}
J
mission_at_implement "$p"
echo "── run.sh implement (the STAGE) on a runnerless repo"
drive "$p" "$SH" -- bash "$RUN_SH" implement --mission test-001
echo "$OUT" | tail -30
echo "── rc=$RC"
echo "── HIRES: $(calls "$LOG")   probes: $(probes "$LOG")"
echo "── park state:"; park_text "$p" | head -40
