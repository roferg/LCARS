#!/usr/bin/env bash
# PILLS — the REAL board function over a REAL composed body, every level word.
. "$(dirname "$0")/lib.sh"
for lv in "low low" "medium high" "high medium"; do
  set -- $lv; RC="$1"; IC="$2"
  R="$(new_repo)"; write_prd "$R/prd-in.md"; write_adr "$R/adr-in.md"
  cat >"$WORK/est.$RC$IC.sh" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" != "estimate" ]; then exec bash "$RUN_SH" "\$@"; fi
shift; mid=""
while [ \$# -gt 0 ]; do case "\$1" in --mission) mid="\${2:-}"; shift 2 ;; *) shift ;; esac; done
gitdir="\$(git rev-parse --git-common-dir 2>/dev/null)"; case "\$gitdir" in /*) : ;; *) gitdir="\$PWD/\$gitdir" ;; esac
mdir="\$gitdir/lcars/missions/\$mid"; [ -d "\$mdir" ] || exit 1
cat >"\$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "$RC", "implCriticality": "$IC",
  "models": { "research": "opus", "validate": "sonnet", "plan": "opus",
  "planReview": "sonnet", "implement": "opus", "verify": "sonnet" },
  "cost": { "unit": "usd", "low": 3.25, "high": 11.4 },
  "deviations": [], "estimatorModel": "opus" }
JSON
exit 0
EOF
  chmod +x "$WORK/est.$RC$IC.sh"
  B="$WORK/pillbod.$RC$IC"; mkdir -p "$B"
  ( cd "$R" && env BODIES="$B" LCARS_RUN_BIN="$WORK/est.$RC$IC.sh" LCARS_DATE=20260907 \
      bash "$FILE_SH" --prd "$R/prd-in.md" --adr "$R/adr-in.md" >/dev/null 2>&1 )
  f="$B/$(ls "$B"|grep -v argv|tail -1)"
  hdr "reasoning=$RC implementation=$IC"
  grep -n 'Criticality' "$f" | sed 's/^/    /'
  ( cd "$LCARS_SRC/web" && python3 - "$f" <<'PY'
import sys,json; sys.path.insert(0,".")
from lcars_serve import github_adapter as ga
b=open(sys.argv[1]).read()
p=ga._pills_from_body(b)
print("    pills:", json.dumps(p))
print("    mix rows:", len(ga._model_mix_from_body(b) or []))
sys.exit(0 if (p["reasoning"] and p["implementation"] and p["cost"]) else 1)
PY
  ) && ok "all three pills scrape from the composed body" || bad "a pill FAILED to scrape"
  # and the envelope must not have polluted anything the scraper reads
  tail -1 "$f" | sed 's/^/    envelope: /'
done
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
