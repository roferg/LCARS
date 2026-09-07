# DEFECT 1 REPRO — `lcars init` then `lcars file` on a repo whose ONLY test
# script is npm's default. The gate refuses BEFORE init and ALLOWS after.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
LOG="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/logs/defect1.calls"; : > "$LOG"
SH="$(make_shim "$LOG")"
p="$(newrepo d1-npm-default)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{ "name": "defaulty", "version": "1.0.0",
  "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
J
echo "console.log('hi')" > "$p/src/index.js"
commitall "$p"
echo "--- BEFORE init"
( cd "$p" && bash "$READINESS_SH" --json )
( cd "$p" && bash "$GATE_SH" --check >/dev/null 2>&1 ); echo "gate rc = $?"
echo "--- lcars init"
drive "$p" "$SH" -- bash "$INIT_SH"; echo "$OUT" | sed 's/^/  /'
echo "--- AFTER init"
( cd "$p" && bash "$READINESS_SH" --json )
echo "config testCommand: $(grep testCommand "$p/.git/lcars/config.json")"
( cd "$p" && bash "$GATE_SH" --check >/dev/null 2>&1 ); echo "gate rc = $?  (0 = FILING ALLOWED)"
echo "--- lcars file"
PRD="$FIX_ROOT/s183b.prd.md"
drive "$p" "$SH" -- bash "$FILE_SH" --prd "$PRD"; echo "$OUT" | sed 's/^/  /'; echo "file rc=$RC"
echo "SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
