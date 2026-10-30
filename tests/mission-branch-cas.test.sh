#!/usr/bin/env bash
# S338: a concurrent writer must never lose a commit to the startup fast-forward.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="${LCARS_COMMON_SCRIPT:-$ROOT/skills/lcars-init/lcars-common.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf '  ok %s\n' "$name"
  else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$name"; fi
}
export REAL_GIT="$(command -v git)"
cat >"$TMP/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
inject() {
  [ ! -e "$RACE_DONE" ] || return 0
  : >"$RACE_DONE"
  blob="$(printf 'concurrent work must survive\n' | "$REAL_GIT" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\tconcurrent.txt\n' "$blob" | "$REAL_GIT" mktree)"
  concurrent="$(printf 'concurrent work\n' | "$REAL_GIT" commit-tree "$tree" -p "${RACE_PARENT:-$RACE_TIP}")"
  "$REAL_GIT" update-ref refs/heads/lcars/test "$concurrent" "$RACE_TIP"
  printf '%s\n' "$concurrent" >"$RACE_SHA"
}
if [ "${RACE_AT:-}" = safety ] &&
   [ "$*" = "rev-list --count $RACE_BASE..$RACE_TIP" ]; then
  "$REAL_GIT" "$@"
  inject
  exit 0
fi
if [ "${RACE_AT:-}" = registration ] && [ "$1" = worktree ] &&
   [ ! -e "$RACE_DONE" ]; then
  "$REAL_GIT" "$@"
  : >"$RACE_DONE"
  "$REAL_GIT" worktree add -q "$RACE_WT" lcars/test
  exit 0
fi
case "$1" in
  branch|update-ref)
    if [ "${RACE_AT:-}" = publish ]; then inject; fi
    printf '%s\n' "$*" >>"$WRITE_LOG"
    ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP/git"

rig() {
  local name="$1" bare="$2" logs="$3"
  mkdir "$TMP/$name"
  cd "$TMP/$name"
  if [ "$bare" = true ]; then git init -q --bare -b main
  else git init -q -b main; fi
  git config user.name test
  git config user.email test@example.com
  git config core.logAllRefUpdates "$logs"
  local tree
  tree="$(git mktree </dev/null)"
  RACE_TIP="$(printf 'original\n' | git commit-tree "$tree")"
  RACE_BASE="$(printf 'base advance\n' | git commit-tree "$tree" -p "$RACE_TIP")"
  git update-ref refs/heads/main "$RACE_BASE"
  git update-ref refs/heads/lcars/test "$RACE_TIP"
  if [ "$bare" = false ]; then git reset -q --hard main; fi
  export RACE_TIP RACE_BASE
  # Files recording the interleaving live outside the repo, not in its checkout.
  export RACE_DONE="$TMP/$name.done" RACE_SHA="$TMP/$name.sha" WRITE_LOG="$TMP/$name.writes"
  : >"$WRITE_LOG"
}
advance() {
  (
    . "$COMMON"
    export LCARS_GIT_BIN="$TMP/git"
    lcars_base_advance_mission_branch lcars/test main
    lcars_base_branch_note_drive lcars/test main
    printf '%s\n' "$LCARS_MB_MOVE" >"$TMP/move"
  ) >"$TMP/stdout" 2>"$TMP/stderr"
}

# KNOWN-FAIL control: all queries and writes are real Git. The adapter only
# schedules another writer after the safety measurement or just before publish.
for bare in false true; do
  for logs in true false; do
    for at in safety publish; do
      name="race-bare-$bare-reflogs-$logs-$at"
      rig "$name" "$bare" "$logs"
      export RACE_AT="$at"
      advance
      concurrent="$(cat "$RACE_SHA")"
      check "$name: writer really committed" git cat-file -e "$concurrent^{commit}"
      check "$name: concurrent commit remains reachable" git merge-base --is-ancestor "$concurrent" lcars/test
      check "$name: ref still belongs to concurrent writer" test "$(git rev-parse lcars/test)" = "$concurrent"
      check "$name: reported refusal" grep -qx refused "$TMP/move"
      check "$name: actionable diagnostic" grep -qi 'changed.*retry\|changed.*re-drive' "$TMP/stdout"
      check "$name: exactly one publication attempt" test "$(wc -l <"$WRITE_LOG" | tr -d ' ')" = 1
      if [ "$logs" = false ]; then
        check "$name: no reflog safety net" test -z "$(git reflog show lcars/test)"
      fi
    done
  done
done

rig concurrent-beyond-base false false
export RACE_AT=publish RACE_PARENT="$RACE_BASE"
advance
check "writer beyond base: commit remains reachable" git merge-base --is-ancestor "$(cat "$RACE_SHA")" lcars/test
check "writer beyond base: refused rather than rewound" grep -qx refused "$TMP/move"
unset RACE_PARENT

rig late-registration false false
export RACE_AT=registration RACE_WT="$TMP/late-checkout"
advance
check "late checkout: registered after first query" test -e "$RACE_DONE"
check "late checkout: refused" grep -qx refused "$TMP/move"
check "late checkout: SHA unchanged" test "$(git rev-parse lcars/test)" = "$RACE_TIP"
check "late checkout: no pointer write" test ! -s "$WRITE_LOG"
check "late checkout: reported checkout change" grep -qi 'became checked out' "$TMP/stdout"
git worktree remove "$RACE_WT"
unset RACE_WT

unset RACE_AT
rig own-work false false
own="$(printf 'mission work\n' | git commit-tree "$(git mktree </dev/null)" -p "$RACE_TIP")"
git update-ref refs/heads/lcars/test "$own" "$RACE_TIP"
advance
check "own commits: refused" grep -qx refused "$TMP/move"
check "own commits: original SHA unchanged" test "$(git rev-parse lcars/test)" = "$own"
check "own commits: existing warning retained" grep -q 'forcing this pointer would DESTROY those 1 commit(s)' "$TMP/stdout"
check "own commits: no write attempted" test ! -s "$WRITE_LOG"

rig symbolic false false
git update-ref refs/heads/other "$RACE_TIP"
git symbolic-ref refs/heads/lcars/test refs/heads/other
advance
check "symbolic branch: unrelated target unchanged" test "$(git rev-parse other)" = "$RACE_TIP"
check "symbolic branch: mission reaches base" test "$(git rev-parse lcars/test)" = "$RACE_BASE"

rig happy false false
advance
check "ordinary fast-forward: moved" grep -qx moved "$TMP/move"
check "ordinary fast-forward: contains base" test "$(git rev-parse lcars/test)" = "$RACE_BASE"
check "ordinary fast-forward: empty stderr" test ! -s "$TMP/stderr"
if [ -n "${LCARS_CONTROL_COMMON:-}" ]; then
  cp "$TMP/stdout" "$TMP/happy.stdout"
  cp "$TMP/stderr" "$TMP/happy.stderr"
  git update-ref refs/heads/lcars/test "$RACE_TIP" "$RACE_BASE"
  COMMON="$LCARS_CONTROL_COMMON" advance
  check "ordinary fast-forward: parent stdout byte-identical" cmp "$TMP/happy.stdout" "$TMP/stdout"
  check "ordinary fast-forward: parent stderr byte-identical" cmp "$TMP/happy.stderr" "$TMP/stderr"
fi

printf '\n%d passed / %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
