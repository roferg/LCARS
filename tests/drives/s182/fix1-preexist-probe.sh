#!/usr/bin/env bash
# Was lcars-run.test.sh's implement-stage shape ALREADY changed by S182-as-shipped,
# before this round's hoist? Fixture = lcars-run.test.sh's `new_repo_par` shape:
# a commit, a mission branch, waves.json — and NO config.json / no LCARS_TEST_CMD.
set -u
. /Users/roganferguson/Projects/LCARS/tests/drives/s182/rig.sh
V="${1:?variant}"
r="$(mktemp -d "${TMPDIR:-/tmp}/pre.XXXXXX")"
( cd "$r" && git init -q && git config user.email t@t && git config user.name t \
  && printf '# seed\n' > seed.md && git add seed.md && git commit -qm seed \
  && git checkout -q -b lcars/test-001 )
mission_at_implement "$r"
# record the branch the way new_repo_par does
sed -i '' 's|"branch": "lcars/test-001"|"branch": "lcars/test-001"|' "$r/.git/lcars/missions/test-001/state.json"
log="$(mktemp)"; : > "$log"
SHIM="$(make_shim_compliant "$log")"
drive "$r" "$SHIM" LCARS_EMPTY_WORKER_TRIES=1 LCARS_WORKER_TRIES=1 -- \
  bash "$V" implement-ticket --mission test-001 --ticket t-001
echo "rc=$RC spawns=$(calls "$log")"
printf '%s\n' "$OUT" | tail -3
