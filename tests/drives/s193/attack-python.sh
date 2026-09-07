#!/usr/bin/env bash
# S193 TESTER — ATTACK THE NEW FAIL-FIRST NARROWING (D2).
# Every runner buffer is CAPTURED by really running the runner on this machine;
# every parent/tip fact is a REAL git repo. The verdict comes from the REAL
# proof_parent_red_kind via run.sh's proof-parent-red-kind-test hook.
# Edits nothing. No worker is involved, so no spend is possible on this leg.
set -u
SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="${RUN_SH:-$SRC/skills/lcars-run/run.sh}"
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s193py.XXXXXX")}"
mkdir -p "$OUT"
PASS=0; FAIL=0; HOLLOW=0
ok(){   PASS=$((PASS+1));     printf '  ok     %s\n' "$1"; }
bad(){  FAIL=$((FAIL+1));     printf '  FAIL   %s\n' "$1"; }
hol(){  HOLLOW=$((HOLLOW+1)); printf '  HOLLOW %s\n' "$1"; }
note(){ printf '  ·      %s\n' "$1"; }

prk(){ # <files> <parent-sha> <tip-wt>  ; runner output on stdin
  local files="$1" parent="${2:-}" wt="${3:-}"; local a=()
  [ -n "$parent" ] && a=("${a[@]+${a[@]}}" --sha "$parent")
  [ -n "$wt" ]     && a=("${a[@]+${a[@]}}" "$wt")
  env LCARS_GH_BIN=true LCARS_GIT_BIN=git LCARS_PRK_FILES="$files" \
    bash "$RUN_SH" proof-parent-red-kind-test ${a[@]+"${a[@]}"} | tr -d '\n'
}
zc(){ env LCARS_GH_BIN=true LCARS_GIT_BIN=git bash "$RUN_SH" proof-zero-collected-test; }
zverdict(){ if printf '%s' "$1" | zc; then echo ZERO; else echo NONZERO; fi; }

# A repo with a PARENT commit (scaffold only) and a TIP commit (scaffold + the
# ticket's files). Returns "<dir> <parentsha>" via globals REPO/PARENT/TIP.
mkrepo(){ # name
  REPO="$OUT/$1"; rm -rf "$REPO"; mkdir -p "$REPO"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@t; git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
}
commit(){ git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "$1" >/dev/null 2>&1; }

echo "S193 python attack — artifacts: $OUT"
echo "python3: $(python3 --version)  at $(command -v python3)"
echo "run.sh:  $RUN_SH"
echo

# ============================ P0 — the HONEST fail-first (must be a RUNNER red)
echo "== P0. honest fail-first: the missing module is the file THIS ticket adds =="
mkrepo p0
printf 'test:\n\tpython3 -m unittest discover -v\n' > "$REPO/Makefile"
printf 'def greet():\n    return "hello"\n' > "$REPO/greet.py"
printf 'import unittest\nfrom greet import greet\nclass T(unittest.TestCase):\n    def test_g(self): self.assertEqual(greet(),"hello")\n' > "$REPO/test_greet.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
printf 'import unittest\nfrom add import add\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(add(2,2),4)\n' > "$REPO/test_add.py"
# PARENT LEG: the ticket's TEST file staged onto the parent, impl absent.
PLOG="$OUT/p0.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1; echo "  parent rc=$?" >/dev/null
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p0.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "add.py" "$PARENT" "$TIP" < "$PLOG")"
note "parent buffer: $(grep -cE '^Ran [0-9]+ tests? in ' "$PLOG") runner banner(s), $(grep -c 'ModuleNotFoundError' "$PLOG") ModuleNotFoundError"
[ "$K" = missing-new-module ] && ok "P0 did: real fail-first red. expected missing-new-module. saw $K" \
                             || bad "P0 did: real fail-first red. expected missing-new-module. saw $K"

# ==================== P1 — a genuinely missing THIRD-PARTY module (must stay env)
echo
echo "== P1. missing THIRD-PARTY module (requests), same unittest banner =="
mkrepo p1
printf 'test:\n\tpython3 -m unittest discover -v\n' > "$REPO/Makefile"
printf 'def greet():\n    return "hello"\n' > "$REPO/greet.py"
printf 'import unittest\nimport requests\nclass T(unittest.TestCase):\n    def test_g(self): self.assertTrue(True)\n' > "$REPO/test_x.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p1.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p1.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "add.py" "$PARENT" "$TIP" < "$PLOG")"
note "missing modules seen: $(grep -o "No module named '\?[a-z_]*" "$PLOG" | sort -u | tr '\n' ' ')"
[ "$K" = env-failure ] && ok "P1 did: missing third-party dep. expected env-failure. saw env-failure" \
                       || hol "P1 did: missing third-party dep. expected env-failure. saw $K  <-- DEAD RUNNER READ AS PROOF"

# ==================== P2 — the VENV IS GONE (interpreter path missing)
echo
echo "== P2. the venv is GONE — the test command's interpreter does not exist =="
mkrepo p2
printf 'test:\n\t.venv/bin/python -m unittest discover -v\n' > "$REPO/Makefile"
printf 'import unittest\nfrom add import add\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(add(2,2),4)\n' > "$REPO/test_add.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p2.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p2.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "add.py" "$PARENT" "$TIP" < "$PLOG")"
note "buffer: $(tr '\n' '|' < "$PLOG" | cut -c1-160)"
case "$K" in
  env-failure) ok "P2 did: missing venv interpreter. expected env-failure. saw env-failure" ;;
  missing-new-module) hol "P2 expected env-failure. saw $K  <-- DEAD RUNNER READ AS PROOF" ;;
  *) bad "P2 expected env-failure (or at worst a non-proof kind). saw $K  [INHERITED? see report]" ;;
esac

# ==================== P2b — venv gone, invoked via a bare `python3 -m` in a venv shape
echo
echo "== P2b. venv activated but its site-packages wiped (pytest uninstalled) =="
mkrepo p2b
printf 'test:\n\tpython3 -m pytest -q\n' > "$REPO/Makefile"
printf 'from add import add\ndef test_a(): assert add(2,2)==4\n' > "$REPO/test_add.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p2b.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p2b.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "add.py" "$PARENT" "$TIP" < "$PLOG")"
note "buffer: $(tr '\n' '|' < "$PLOG" | cut -c1-200)"
[ "$K" = env-failure ] && ok "P2b did: pytest not installed. expected env-failure. saw env-failure" \
                       || hol "P2b expected env-failure. saw $K  <-- DEAD RUNNER READ AS PROOF"

# ==================== P3 — THE SHARP ONE: the RUNNER ITSELF is a new module
echo
echo "== P3. the TEST RUNNER ITSELF is a module the ticket adds (python3 -m gfrunner) =="
mkrepo p3
printf 'test:\n\tpython3 -m gfrunner\n' > "$REPO/Makefile"
printf 'import unittest\nfrom add import add\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(add(2,2),4)\n' > "$REPO/test_add.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p3.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf 'import unittest\nunittest.main(module=None, argv=["x","discover"])\n' > "$REPO/gfrunner.py"
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p3.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "gfrunner.py
add.py" "$PARENT" "$TIP" < "$PLOG")"
note "buffer: $(tr '\n' '|' < "$PLOG" | cut -c1-200)"
[ "$K" = env-failure ] && ok "P3 did: runner module absent at parent, ALL facts 1/3/4 hold. expected env-failure. saw env-failure" \
                       || hol "P3 expected env-failure (fact 2 must refuse: the runner never started). saw $K  <-- DEAD RUNNER READ AS PROOF"

# ============ P4 — FORGE fact 2: the harness prints the runner banner itself
echo
echo "== P4. FORGE the 'runner started' banner at column 0, runner still stone dead =="
mkrepo p4
printf 'test:\n\t@echo "Ran 1 test in 0.001s"\n\t@python3 -m gfrunner\n' > "$REPO/Makefile"
printf 'import unittest\nfrom add import add\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(add(2,2),4)\n' > "$REPO/test_add.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p4.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf 'import unittest\nunittest.main(module=None, argv=["x","discover"])\n' > "$REPO/gfrunner.py"
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p4.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "gfrunner.py
add.py" "$PARENT" "$TIP" < "$PLOG")"
note "buffer: $(tr '\n' '|' < "$PLOG" | cut -c1-220)"
[ "$K" = env-failure ] && ok "P4 forged banner + dead runner. expected env-failure. saw env-failure" \
                       || hol "P4 forged banner + dead runner. expected env-failure. saw $K  <-- DEAD RUNNER READ AS PROOF"

# ============ P5 — stem collision on a NON-python file the ticket adds
echo
echo "== P5. the ticket adds only add.md (never a module) — stem collision on 'add' =="
mkrepo p5
printf 'test:\n\tpython3 -m unittest discover -v\n' > "$REPO/Makefile"
printf 'import unittest\nfrom add import add\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(add(2,2),4)\n' > "$REPO/test_add.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p5.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf '# add\n' > "$REPO/add.md"; commit tip
TIP="$OUT/p5.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "add.md" "$PARENT" "$TIP" < "$PLOG")"
note "changed non-test set is add.md ONLY — no python module was ever written"
[ "$K" = missing-new-module ] \
  && note "P5 saw $K — fact 3 matches on STEM+extension-stripped path, so a non-module file satisfies it. (Not a pass on its own: the TIP leg is still red. Reported as a sharp edge.)" \
  || note "P5 saw $K"

# ============ P6 — BOTH a ticket module and a third-party module missing
echo
echo "== P6. the ticket's module AND a third-party module both missing =="
mkrepo p6
printf 'test:\n\tpython3 -m unittest discover -v\n' > "$REPO/Makefile"
printf 'import unittest\nfrom add import add\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(add(2,2),4)\n' > "$REPO/test_add.py"
printf 'import unittest\nimport requests\nclass U(unittest.TestCase):\n    def test_b(self): self.assertTrue(True)\n' > "$REPO/test_net.py"
commit scaffold; PARENT="$(git -C "$REPO" rev-parse HEAD)"
PLOG="$OUT/p6.parent.log"; ( cd "$REPO" && make test ) > "$PLOG" 2>&1
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"; commit tip
TIP="$OUT/p6.tip"; rm -rf "$TIP"; git -C "$REPO" worktree add -q --detach "$TIP" HEAD
K="$(prk "add.py" "$PARENT" "$TIP" < "$PLOG")"
note "missing modules seen: $(grep -o "No module named '\?[a-z_]*" "$PLOG" | sort -u | tr '\n' ' ')"
[ "$K" = env-failure ] && ok "P6 did: mixed missing modules. expected env-failure (EVERY module must map). saw env-failure" \
                       || hol "P6 expected env-failure. saw $K  <-- one unmapped module did not veto"

# ============ P7 — FAIL CLOSED when the facts are not plumbed
echo
echo "== P7. the SAME honest fail-first buffer with NO parent/tip facts =="
K="$(prk "add.py" "" "" < "$OUT/p0.parent.log")"
[ "$K" = env-failure ] && ok "P7 did: no facts supplied. expected env-failure (fails CLOSED). saw env-failure" \
                       || bad "P7 expected env-failure with no facts. saw $K"

# ============ P8 — python TIP-side green-on-nothing must still be ZERO
echo
echo "== P8. python tip leg that COLLECTS NOTHING (green-on-nothing) =="
mkrepo p8
printf 'test:\n\tpython3 -m unittest discover -v\n' > "$REPO/Makefile"
printf 'def add(a,b):\n    return a+b\n' > "$REPO/add.py"
commit scaffold
TLOG="$OUT/p8.tip.log"; ( cd "$REPO" && make test ) > "$TLOG" 2>&1; RC=$?
note "rc=$RC · buffer: $(tr '\n' '|' < "$TLOG" | cut -c1-140)"
V="$(zverdict "$(cat "$TLOG")")"
[ "$V" = ZERO ] && ok "P8 did: unittest discovering nothing (exit 0). expected ZERO. saw ZERO" \
                || hol "P8 expected ZERO. saw $V  <-- GREEN ON NOTHING"

# ============ P9 — a suite of only skipped tests
echo
echo "== P9. python tip leg where every test is SKIPPED =="
mkrepo p9
printf 'test:\n\tpython3 -m unittest discover -v\n' > "$REPO/Makefile"
printf 'import unittest\nclass T(unittest.TestCase):\n    @unittest.skip("x")\n    def test_a(self): self.assertEqual(1,2)\n' > "$REPO/test_skip.py"
commit scaffold
TLOG="$OUT/p9.tip.log"; ( cd "$REPO" && make test ) > "$TLOG" 2>&1; RC=$?
note "rc=$RC · buffer: $(tr '\n' '|' < "$TLOG" | cut -c1-160)"
V="$(zverdict "$(cat "$TLOG")")"
note "P9 saw $V — unittest counts a skipped case in 'Ran 1 test', so the zero-collect trap does not fire. INHERITED (identical on HEAD)."

printf '\nS193 python attack: %d ok, %d fail, %d HOLLOW-PASS\n' "$PASS" "$FAIL" "$HOLLOW"
echo "artifacts: $OUT"
