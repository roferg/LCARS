set -u
. "/Users/roganferguson/Projects/LCARS/tests/drives/s183b/rig.sh"
LOG="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/verify/d1b.calls"; : > "$LOG"
SH="$(make_shim "$LOG")"; fuse "$SH" || exit 99
PRD="$FIX_ROOT/s183b.prd.md"

echo "############ D1b — captain's ruling WINS on the npm-default repo"
p="$FIX_ROOT/d1-npm-default"
drive "$p" "$SH" -- bash "$UPDATE_SH" --test-command 'true'; echo "$OUT" | sed 's/^/  /'; echo "  update rc=$RC"
echo "  readiness: $( (cd "$p" && bash "$READINESS_SH" --json) )"
( cd "$p" && bash "$GATE_SH" --check >/dev/null 2>&1 ); echo "  gate rc = $? (0=allow)"
drive "$p" "$SH" -- bash "$FILE_SH" --prd "$PRD"; echo "$OUT" | sed 's/^/  file| /' | head -20; echo "  file rc=$RC"
echo "  missions: $(ls "$p/.git/lcars/missions" 2>/dev/null | tr '\n' ' ')"

echo
echo "############ D1c — LCARS_TEST_CMD env on a fresh npm-default repo"
q="$(newrepo d1c-env)"; mkdir -p "$q/src"
cat > "$q/package.json" <<'J'
{ "name": "defaulty", "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
J
echo "console.log(1)" > "$q/src/i.js"; commitall "$q"
drive "$q" "$SH" LCARS_TEST_CMD=true -- bash "$INIT_SH"; echo "$OUT" | sed 's/^/  /'
echo "  config testCommand: $(grep testCommand "$q/.git/lcars/config.json")"

echo
echo "############ D1d — a REAL vitest repo still gets its runner seeded by init"
r="$(newrepo d1d-vitest)"; mkdir -p "$r/src"
cat > "$r/package.json" <<'J'
{ "name": "tested-app", "private": true, "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^2.0.0" } }
J
echo "export const add=(a,b)=>a+b" > "$r/src/add.js"
cat > "$r/src/add.test.js" <<'J'
import { it, expect } from 'vitest'
import { add } from './add.js'
it('adds', () => { expect(add(1,2)).toBe(3) })
J
commitall "$r"
drive "$r" "$SH" LCARS_INIT_SKIP_PROBE=1 -- bash "$INIT_SH"; echo "$OUT" | sed 's/^/  /'
echo "  config testCommand: $(grep testCommand "$r/.git/lcars/config.json")"
( cd "$r" && bash "$GATE_SH" --check >/dev/null 2>&1 ); echo "  gate rc = $? (0=allow)"

echo
echo "############ D1e — make/pytest/cargo repos still get seeded"
for f in inv-makefile inv-python inv-rust inv-go inv-tests-runsh; do
  x="$FIX_ROOT/$f"; rm -rf "$x/.git/lcars"
  drive "$x" "$SH" LCARS_INIT_SKIP_PROBE=1 -- bash "$INIT_SH" >/dev/null
  printf '  %-20s testCommand=%s\n' "$f" "$(sed -n 's/.*"testCommand": *\(.*\),/\1/p' "$x/.git/lcars/config.json")"
done
echo "SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
