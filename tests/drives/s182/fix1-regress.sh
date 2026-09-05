#!/usr/bin/env bash
# S182 fix round 1 — "cures so far" REGRESSION DRIVES, on the real CLI paths,
# behind the inherited counting PATH shim + SPEND FUSE. Zero dollars.
set -u
. /Users/roganferguson/Projects/LCARS/tests/drives/s182/rig.sh
OUT_DIR="${1:?outdir}"; mkdir -p "$OUT_DIR"
P=0; F=0
say(){ printf '  %-6s %s\n' "$1" "$2"; }
okk(){ P=$((P+1)); say ok "$1"; }
noo(){ F=$((F+1)); say FAIL "$1"; }

seed() { # → greenfield repo (a commit, code, no test runner) w/ mission @ implement
  local r; r="$(mktemp -d "${TMPDIR:-/tmp}/s182r.XXXXXX")"
  ( cd "$r" && git init -q && git config user.email t@t && git config user.name t \
    && mkdir -p src && printf 'export const App=()=>null;\n' > src/App.jsx \
    && printf '{ "name":"gf", "private":true, "dependencies": {"react":"^18"} }\n' > package.json \
    && git add -A && git commit -q -m init )
  mission_at_implement "$r"
  echo "$r"
}
cfg() { printf '%s\n' "$2" > "$1/.git/lcars/config.json"; }
runstage() { # repo label
  local r="$1" l="$2" log="$OUT_DIR/calls-$2"; : > "$log"
  local sh; sh="$(make_shim_compliant "$log")"
  drive "$r" "$sh" LCARS_S182=1 -- bash "$RUN_SH" implement --mission test-001
  printf '%s\n' "$OUT" > "$OUT_DIR/$l.out"
  SPAWNS="$(calls "$log")"
}

# --- R1 DEFECT 1: greenfield, `lcars run`'s implement STAGE, ZERO hires ------
r="$(seed)"; cfg "$r" '{
  "stack": "js",
  "testCommand": null
}'
runstage "$r" r1-greenfield-stage
[ "$RC" = 0 ] && [ "$SPAWNS" = 0 ] && okk "R1. stage-level greenfield: rc=0, $SPAWNS paid hires (was 1)" \
  || noo "R1. stage-level greenfield rc=$RC spawns=$SPAWNS"
park_text "$r" | grep -q 'No worker was hired' \
  && okk "R1b. and the park's zero-hire claim is now true stage-wide" || noo "R1b. zero-hire claim missing"

# --- R2 DEFECT 2: whitespace testCommand cannot slip the wall ----------------
r="$(seed)"; cfg "$r" '{
  "stack": "js",
  "testCommand": "   "
}'
runstage "$r" r2-whitespace
[ "$RC" = 0 ] && [ "$SPAWNS" = 0 ] && okk "R2. whitespace testCommand: parked, $SPAWNS hires (was 2)" \
  || noo "R2. whitespace testCommand rc=$RC spawns=$SPAWNS"

# --- R3 DEFECT 3: a monorepo whose packages all HAVE runners ----------------
r="$(seed)"
printf '{ "name":"mono","private":true,"workspaces":["packages/*"] }\n' > "$r/package.json"
for p in a b c; do mkdir -p "$r/packages/$p"
  printf '{ "name":"%s","scripts":{"test":"vitest run"} }\n' "$p" > "$r/packages/$p/package.json"; done
( cd "$r" && git add -A && git commit -q -m mono )
cfg "$r" '{
  "stack": "js",
  "testCommand": null
}'
runstage "$r" r3-monorepo
[ "$RC" = 0 ] && [ "$SPAWNS" = 0 ] && okk "R3. monorepo parks with $SPAWNS hires" || noo "R3. rc=$RC spawns=$SPAWNS"
park_text "$r" | grep -qi 'add a test framework' \
  && noo "R3b. STILL tells a repo with three runners to add a framework" \
  || okk "R3b. no 'add a test framework' advice on a repo that has three"
park_text "$r" | grep -q 'test-readiness verdict' \
  && okk "R3c. the readiness verdict is still cited (S183 keeps the seam)" || noo "R3c. verdict citation lost"

# --- R4 INVARIANT: a repo that HAS a runner still hires ---------------------
r="$(seed)"
printf '#!/usr/bin/env bash\necho "AssertionError: expected"\nexit 1\n' > "$r/t.sh"; chmod +x "$r/t.sh"
( cd "$r" && git add -A && git commit -q -m t )
cfg "$r" "$(printf '{\n  "stack": "js",\n  "testCommand": "bash %s/t.sh"\n}' "$r")"
runstage "$r" r4-hasrunner
[ "$SPAWNS" -gt 0 ] && okk "R4. a repo WITH a runner still reaches the workers ($SPAWNS hires)" \
  || noo "R4. the wall blocked a repo that HAS a runner (rc=$RC)"
park_text "$r" | grep -q 'no test command is configured' \
  && noo "R4b. a repo with a runner got the no-runner park" || okk "R4b. and never gets the no-runner park"

# --- R5 INVARIANT: padded but REAL command still RUNS -----------------------
r="$(seed)"
printf '#!/usr/bin/env bash\necho "AssertionError: expected"\nexit 1\n' > "$r/t.sh"; chmod +x "$r/t.sh"
( cd "$r" && git add -A && git commit -q -m t )
cfg "$r" "$(printf '{\n  "stack": "js",\n  "testCommand": "  bash %s/t.sh  "\n}' "$r")"
runstage "$r" r5-padded
[ "$SPAWNS" -gt 0 ] && okk "R5. padding around a real command does NOT park it ($SPAWNS hires)" \
  || noo "R5. a padded real command was wrongly parked (rc=$RC)"

# --- R6 unborn HEAD: still an actionable park, still zero spend -------------
r="$(mktemp -d "${TMPDIR:-/tmp}/s182u.XXXXXX")"
( cd "$r" && git init -q && git config user.email t@t && git config user.name t )
mission_at_implement "$r"
cfg "$r" '{
  "stack": "js",
  "testCommand": "true"
}'
runstage "$r" r6-unborn
[ "$RC" = 0 ] && [ "$SPAWNS" = 0 ] && okk "R6. unborn HEAD parks at the STAGE with $SPAWNS hires" \
  || noo "R6. unborn HEAD rc=$RC spawns=$SPAWNS"
park_text "$r" | grep -q 'git commit --allow-empty' \
  && okk "R6b. and still hands over the exact unblocking command" || noo "R6b. next step lost"

printf '\nS182 fix-round-1 regression drives: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]
