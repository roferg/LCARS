#!/usr/bin/env bash
# PARITY — each lane's body generated from a CLEAN pre-S188 checkout (08eed26)
# vs today's tree. Must differ ONLY by the appended envelope.
. "$(dirname "$0")/lib.sh"
OLD="${LCARS_PRE_S188_WORKTREE:?set LCARS_PRE_S188_WORKTREE to a detached 08eed26 worktree (see README.md)}"

mk_est() { # <run.sh> <out>
  sed "s|__RUN__|$1|" >"$2" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" != "estimate" ]; then exec bash "__RUN__" "$@"; fi
shift; mid=""
while [ $# -gt 0 ]; do case "$1" in --mission) mid="${2:-}"; shift 2 ;; *) shift ;; esac; done
gitdir="$(git rev-parse --git-common-dir 2>/dev/null)"; case "$gitdir" in /*) : ;; *) gitdir="$PWD/$gitdir" ;; esac
mdir="$gitdir/lcars/missions/$mid"; [ -d "$mdir" ] || exit 1
cat >"$mdir/estimate.json" <<JSON
{ "schemaVersion": 1, "reasoningCriticality": "low", "implCriticality": "med",
  "models": { "research": "sonnet", "validate": "sonnet", "plan": "sonnet",
  "planReview": "sonnet", "implement": "opus", "verify": "sonnet" },
  "deviations": [], "estimatorModel": "opus" }
JSON
exit 0
EOF
  chmod +x "$2"
}

gen() { # <src-root> <tag> <lane> → echoes the captured-bodies dir
  local SRC="$1" TAG="$2" LANE="$3"
  local F="$SRC/skills/lcars-file/file.sh" R="$SRC/skills/lcars-run/run.sh"
  local L="$SRC/skills/lcars-log/log.sh"
  local repo; repo="$(new_repo)"
  local est="$WORK/est.$TAG.$LANE.sh"; mk_est "$R" "$est"
  local BOD="$WORK/bod.$TAG.$LANE"; mkdir -p "$BOD"
  local LOG="$WORK/ghlog.$TAG.$LANE"; : >"$LOG"
  write_prd "$repo/prd-in.md"; write_adr "$repo/adr-in.md"
  printf 'fake png bytes\n' >"$repo/shot.png"
  local E=(env BODIES="$BOD" GH_LOG="$LOG" LCARS_GH_BIN="$GH_STUB" LCARS_RUN_BIN="$est"
           LCARS_VERSION_CHECK=0 LCARS_DATE=20260907 LCARS_NOW=2026-09-07T10:00:00Z)
  case "$LANE" in
    D-full)    ( cd "$repo" && "${E[@]}" bash "$F" --prd "$repo/prd-in.md" --adr "$repo/adr-in.md" ) >/dev/null 2>&1 ;;
    D-prdonly) ( cd "$repo" && "${E[@]}" LCARS_RUN_BIN=/nonexistent bash "$F" --prd "$repo/prd-in.md" ) >/dev/null 2>&1 ;;
    D-attach)  ( cd "$repo" && "${E[@]}" bash "$F" --prd "$repo/prd-in.md" --attach "$repo/shot.png" ) >/dev/null 2>&1 ;;
    A-park)    ( cd "$repo" && "${E[@]}" bash "$F" --park "Invoices need a CSV export.

Finance are copy-pasting the table every month." ) >/dev/null 2>&1 ;;
    B-complete)( cd "$repo" && "${E[@]}" bash "$F" --park "Invoices need a CSV export." >/dev/null 2>&1
                 cd "$repo" && "${E[@]}" LCARS_NOW=2026-09-07T11:00:00Z bash "$F" --complete lcars-20260907-001 --prd "$repo/prd-in.md" --adr "$repo/adr-in.md" ) >/dev/null 2>&1 ;;
    E-log)     # THE FIFTH LANE (S188 fix round D2): `lcars log` files a Mission
               # too, and its body was still composed inline. Parity here is the
               # `> 🐞 Logged via …` lead-in + prd.md, byte for byte.
               ( cd "$repo" && "${E[@]}" bash "$F" --prd "$repo/prd-in.md" >/dev/null 2>&1
                 sed -i '' 's/"stage": "align"/"stage": "implement"/' \
                   "$repo/.git/lcars/missions/lcars-20260907-001/state.json"
                 cat >"$repo/bug-in.md" <<'BUG'
# Mission: CSV export button double-fires

**Type:** bug
**Goal:** Clicking Export CSV twice quickly must produce one download, not two.
**Acceptance Criteria:**
- A second click while an export is in flight is ignored
**Out of Scope:**
- Any change to the CSV contents
**Constraints:**
- No new runtime dependencies
BUG
                 cd "$repo" && "${E[@]}" LCARS_RUN_BIN=/nonexistent \
                   bash "$L" --parent lcars-20260907-001 --prd "$repo/bug-in.md" ) >/dev/null 2>&1 ;;
    C-complete-create) # gh was DOWN at park time → --complete must CREATE the issue
               ( cd "$repo" && "${E[@]}" LCARS_GH_BIN=/nonexistent-gh bash "$F" --park "Invoices need a CSV export." >/dev/null 2>&1
                 cd "$repo" && "${E[@]}" LCARS_NOW=2026-09-07T11:00:00Z bash "$F" --complete lcars-20260907-001 --prd "$repo/prd-in.md" --adr "$repo/adr-in.md" ) >/dev/null 2>&1 ;;
  esac
  printf '%s' "$BOD"
}

for lane in A-park B-complete C-complete-create D-full D-prdonly D-attach E-log; do
  hdr "LANE $lane"
  o="$(gen "$OLD" old "$lane")"; n="$(gen "$LCARS_SRC" new "$lane")"
  ofile="$(ls "$o" 2>/dev/null | grep -v argv | tail -1)"; nfile="$(ls "$n" 2>/dev/null | grep -v argv | tail -1)"
  if [ -z "$ofile" ] || [ -z "$nfile" ]; then bad "$lane: no body captured (old='$ofile' new='$nfile')"; continue; fi
  note "old argv: $(cat "$o/$ofile.argv" 2>/dev/null | sed 's/--body-file [^ ]*/--body-file <f>/')"
  note "new argv: $(cat "$n/$nfile.argv" 2>/dev/null | sed 's/--body-file [^ ]*/--body-file <f>/')"
  # BYTE-LEVEL: the new body must be the OLD bytes, then a suffix that is
  # nothing but (optional newline) + blank line + one envelope line.
  res="$(python3 - "$o/$ofile" "$n/$nfile" <<'PYX'
import sys,re
old=open(sys.argv[1],'rb').read(); new=open(sys.argv[2],'rb').read()
if not new.startswith(old):
    i=0
    while i<min(len(old),len(new)) and old[i]==new[i]: i+=1
    print("DIVERGE at byte %d: old=%r new=%r" % (i, old[i:i+60], new[i:i+60])); sys.exit(1)
suf=new[len(old):]
m=re.fullmatch(rb'\n?\n<!-- lcars:handoff v1 \{.*\} -->\n?', suf, re.S)
print("OK suffix=%r" % suf if m else "BADSUFFIX %r" % suf)
sys.exit(0 if m else 1)
PYX
)"
  if [ $? -eq 0 ]; then ok "$lane: byte-identical to 08eed26 + envelope suffix only"; note "$res"
  else bad "$lane: DIVERGED — $res"; fi
  note "envelope: $(tail -1 "$n/$nfile")"
  # also compare against the implementor's golden, where one exists
done
echo "WORK=$WORK"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
