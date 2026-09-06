# Compact: just the gate decision per repo (no filing side-effects).
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
printf '%-26s %-13s %-9s %s\n' REPO FOUNDATION DECISION EXPECTED
printf '%.0s-' {1..90}; echo
for d in "$FIX_ROOT"/*/; do
  n="$(basename "$d")"
  f="$( ( cd "$d" && bash "$GATE_SH" --json 2>/dev/null ) | sed -E 's/.*"foundation":(null|"([^"]*)").*/\2/' )"
  ( cd "$d" && bash "$GATE_SH" --check >/dev/null 2>&1 ); rc=$?
  dec=ALLOW; [ "$rc" = 20 ] && dec=REFUSE
  case "$n" in
    blank|readme|untested|attack-*) exp=REFUSE ;;
    *) exp=ALLOW ;;
  esac
  mark=""; [ "$dec" != "$exp" ] && mark="   <<< MISMATCH"
  printf '%-26s %-13s %-9s %s%s\n' "$n" "$f" "$dec" "$exp" "$mark"
done
