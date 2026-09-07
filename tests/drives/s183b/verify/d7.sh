set -u
. "/Users/roganferguson/Projects/LCARS/tests/drives/s183b/rig.sh"
LOG="/Users/roganferguson/Projects/LCARS/tests/drives/s183b/verify/d7.calls"; : > "$LOG"
SH="$(make_shim "$LOG")"; fuse "$SH" || exit 99
PRD="$FIX_ROOT/s183b.prd.md"
trace() { # repo → what exists under .git/lcars
  local p="$1"
  if [ -d "$p/.git/lcars" ]; then find "$p/.git/lcars" | sed "s|$p/.git/|  |"; else echo "  <no .git/lcars at all>"; fi
}
for lane in prd park; do
for st in blank readme untested; do
  p="$(newrepo d7-$lane-$st)"
  case "$st" in
    readme) printf '# Idea\n\nA finance app.\n' > "$p/README.md"; commitall "$p" ;;
    untested) mkdir -p "$p/src"; printf '{ "name":"app","scripts":{"dev":"vite"} }\n' > "$p/package.json";
              echo "console.log(1)" > "$p/src/i.js"; commitall "$p" ;;
  esac
  echo "════════ PRISTINE $lane @ $st  (no lcars init)"
  echo "  before: $(trace "$p" | tr '\n' ' ')"
  before="$(calls "$LOG")"
  if [ "$lane" = prd ]; then drive "$p" "$SH" -- bash "$FILE_SH" --prd "$PRD"
  else drive "$p" "$SH" -- bash "$FILE_SH" --park "a spending summary card"; fi
  echo "  rc=$RC  hires=$(( $(calls "$LOG") - before ))"
  echo "  first line: $(printf '%s' "$OUT" | head -1)"
  echo "  AFTER:"; trace "$p"
  echo "  missions dir exists? $([ -d "$p/.git/lcars/missions" ] && echo YES-DEFECT || echo no)"
  echo "  working tree dirty? $(git -C "$p" status --porcelain | wc -l | tr -d ' ') files"
done
done
echo "TOTAL SPAWNS=$(calls "$LOG") PROBES=$(probes "$LOG")"
