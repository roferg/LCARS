#!/usr/bin/env bash
# S189 setup — the two laptops and the fixture's label set. Idempotent; run it
# once before the drives. Creates NOTHING that has to be torn down except the
# `lcars:*` labels (harmless, and what a real `lcars init` would have left).
. "$(dirname "$0")/lib.sh"

hdr "labels on $FIXTURE (what \`lcars init\` creates)"
. "$LCARS_SRC/skills/lcars-init/lcars-common.sh"
have="$("$GH_REAL" label list -R "$FIXTURE" --limit 200 --json name -q '.[].name' 2>/dev/null)"
made=0
for s in $LCARS_STAGE_LABELS; do L="lcars:$s"; case "
$have" in *"
$L") ;; esac
  printf '%s\n' "$have" | grep -qx "$L" || { "$GH_REAL" label create "$L" -R "$FIXTURE" -c 5599ff -d "$(lcars_label_desc "$L" 2>/dev/null)" >/dev/null 2>&1 && made=$((made+1)); }
done
for s in $LCARS_TYPE_LABELS $LCARS_STATUS_LABELS $LCARS_REL_LABELS $LCARS_ROLE_LABELS; do
  L="lcars:$s"
  printf '%s\n' "$have" | grep -qx "$L" || { "$GH_REAL" label create "$L" -R "$FIXTURE" -c cc99ff -d "$(lcars_label_desc "$L" 2>/dev/null)" >/dev/null 2>&1 && made=$((made+1)); }
done
ok "label set present ($made created this run)"

hdr "the two laptops"
A="$(laptop A)"; B="$(laptop B)"
[ -d "$A/.git" ] && ok "laptop A: $A" || bad "laptop A clone failed"
[ -d "$B/.git" ] && ok "laptop B: $B" || bad "laptop B clone failed"
note "A HEAD: $(cd "$A" && git rev-parse --abbrev-ref HEAD) @ $(cd "$A" && git rev-parse --short HEAD)"
note "B HEAD: $(cd "$B" && git rev-parse --abbrev-ref HEAD) @ $(cd "$B" && git rev-parse --short HEAD)"
[ "$(cd "$A" && git rev-parse --abbrev-ref HEAD)" = main ] && ok "A is on main (not an unborn master — the leg-B trap)" || bad "A is not on main"

hdr "identity"
me="$(host whoami)"; note "host-adapter whoami → '$me'"
[ -n "$me" ] && ok "whoami resolves" || bad "whoami empty"
hdr "SPEND"; note "worker spawns: $(spawns)  billable: $(billable)"
printf '\n%d passed, %d failed\nS189_HOME=%s\nWORK=%s\n' "$PASS" "$FAIL" "$S189_HOME" "$WORK"
