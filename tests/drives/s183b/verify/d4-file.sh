set -u
. "/Users/roganferguson/Projects/LCARS/tests/drives/s183b/rig.sh"
LOG="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/verify/d4.calls"; : > "$LOG"
SH="$(make_shim "$LOG")"; fuse "$SH" || exit 99
PRD="$FIX_ROOT/s183b.prd.md"
for n in b-swift b-perl mono pnpm-noroot inv-tests-no-runner b-maven b-elixir b-php b-py-unittest b-bats b-cmake b-scala inv-one-tested inv-mono-no-root; do
  p="$FIX_ROOT/$n"
  rm -rf "$p/.git/lcars"
  drive "$p" "$SH" LCARS_INIT_SKIP_PROBE=1 -- bash "$INIT_SH" >/dev/null 2>&1
  tc="$(sed -n 's/.*"testCommand": *\([^,]*\),.*/\1/p' "$p/.git/lcars/config.json")"
  before="$(calls "$LOG")"
  drive "$p" "$SH" -- bash "$FILE_SH" --prd "$PRD"
  ok="$(printf '%s' "$OUT" | sed -n 's/.*Mission filed: *\([a-z0-9-]*\).*/\1/p' | head -1)"
  printf '%-22s tc=%-12s file rc=%-3s %s %s\n' "$n" "${tc:-?}" "$RC" \
     "$([ -n "$ok" ] && echo "FILED $ok" || echo "*** NOT FILED ***")" \
     "hires=$(( $(calls "$LOG") - before ))"
  [ -n "$ok" ] || printf '%s\n' "$OUT" | sed 's/^/      | /' | head -6
done
echo "TOTAL SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
