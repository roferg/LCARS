#!/usr/bin/env bash
# S185 ROUND-2 PRIORITY 2 — the false-positive matrix for the new bash -n parse
# check, run against BOTH the working tree lib and HEAD's, so NEW vs INHERITED
# is separated by construction.
set -u
SCRATCH=/private/tmp/claude-501/-Users-roganferguson-Projects-lcars-dev/2c448f19-3d03-4296-926a-b442ce6c195f/scratchpad
NEWLIB=/Users/roganferguson/Projects/LCARS/skills/lcars-init/lcars-common.sh
OLDLIB=$SCRATCH/lcars-common.HEAD.sh
FIX="${TMPDIR:-/tmp}lcars-s185"; FIX="${FIX%/}"
R="$FIX/r2-matrix"; rm -rf "$R"; mkdir -p "$R/.git/lcars"
# a JS repo with vitest present so the detector arms are realistic
cat > "$R/package.json" <<'PJ'
{ "name":"m","private":true,"type":"module","scripts":{"test":"vitest run"},
  "devDependencies":{"vitest":"^3.2.7"} }
PJ
mkdir -p "$R/test" "$R/node_modules/.bin"
printf '#!/bin/sh\nexit 0\n' > "$R/node_modules/.bin/vitest"; chmod +x "$R/node_modules/.bin/vitest"

probe() { # lib  command  -> "status|why"
  local lib="$1" cmd="$2"
  python3 - "$R/.git/lcars/config.json" "$cmd" <<'PY'
import json,sys
json.dump({"version":1,"testCommand":sys.argv[2]}, open(sys.argv[1],"w"), indent=2)
PY
  ( cd "$R" && TOPLEVEL="$R" bash -c '
      . "'"$lib"'" >/dev/null 2>&1
      TOPLEVEL="'"$R"'"
      lcars_test_readiness_status "'"$R"'/.git/lcars/config.json" >/dev/null 2>&1
      printf "%s|%s" "${LCARS_TESTREADY_STATUS:-?}" "${LCARS_TESTREADY_BROKEN_WHY:-}"
  ' )
}

VITEST='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
JEST='npx jest ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
MOCHA='npx mocha ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
NPMT='npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
PYT='pytest "${LCARS_TESTS_DIR:-.}"'
EXECV='exec node_modules/.bin/vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'

declare -a NAMES CMDS
add(){ NAMES+=("$1"); CMDS+=("$2"); }
add "detector: vitest (relativizing)"      "$VITEST"
add "detector: jest"                        "$JEST"
add "detector: mocha"                       "$MOCHA"
add "detector: npm test --"                 "$NPMT"
add "detector: pytest"                      "$PYT"
add "update.sh suggestion: exec vitest"     "$EXECV"
add "pipe"                                  'npm test | cat'
add "&& chain"                              'npm run build && npm test'
add "subshell"                              '(cd packages/app && npm test)'
add "single quotes"                         "npx vitest run --reporter 'default'"
add "command substitution"                  'npx vitest run --root "$(pwd)"'
add "trailing comment"                      'npm test # the whole suite'
add "multiline"                             'set -e
npm test'
add "env prefix"                            'CI=1 npx vitest run'
add "redirect + semicolon"                  'npm test 2>&1; exit $?'
add "backslash line continuation"           'npx vitest \
  run'
add "brace group"                           '{ npm test; }'
add "for loop"                              'for d in a b; do npx vitest run "$d"; done'
add "case statement"                        'case "$X" in *) npm test ;; esac'
add "BROKEN: truncated mid-quote (D1)"      'npx vitest run ${LCARS_TESTS_DIR:+\'
add "BROKEN: unclosed dquote"               'npm test "unterminated'
add "BROKEN: unclosed if"                   'if true; then npm test'
add "BROKEN: stray )"                       'npm test )'

printf '%-42s  %-22s  %-22s  %s\n' "COMMAND" "HEAD (before fix)" "WORKTREE (after fix)" "CHANGED?"
printf '%.0s-' {1..110}; echo
for i in "${!NAMES[@]}"; do
  o="$(probe "$OLDLIB" "${CMDS[$i]}")"
  n="$(probe "$NEWLIB" "${CMDS[$i]}")"
  ch=""; [ "$o" != "$n" ] && ch="<<< CHANGED"
  printf '%-42s  %-22s  %-22s  %s\n' "${NAMES[$i]}" "$o" "$n" "$ch"
done
