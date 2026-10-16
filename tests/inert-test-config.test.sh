#!/usr/bin/env bash
# S299 — AN INERT DECLARATION IS NOT AN ESTABLISHED TEST SYSTEM.
#
# MEASURED, 2026-10-15: an implementor bounced by the post-hoc gate for "no test
# command LCARS can detect at the repo root" came back with a `tox.ini` holding
# nothing but
#
#     [tox]
#     envlist =
#
# — a stub that runs nothing. The gate PASSED the session (the real runner was
# detected separately, so that run's outcome happened to be fine), which is the
# shape of the hole: a worker can satisfy the gate with an artifact that merely
# LOOKS like test configuration.
#
# This suite is the stamp of the cure, in two halves that must BOTH hold:
#
#   A. THE REGRESSION TABLE, and it is the half that matters most. A FALSE
#      NEGATIVE here is worse than the bug: a legitimate repo refused is a real
#      mission dead. One row per shape `detect_test_cmd` supports, each pinned
#      to the value MEASURED from the detector BEFORE the cure — not to what it
#      ought to return.
#   B. THE INERT SHAPES, each paired with a control that must print a DIFFERENT
#      answer. Every refusal below was first proven inert by RUNNING it (`make
#      test` on a recipe-less target prints "Nothing to be done" and exits 0;
#      an empty `tests/run.sh` exits 0 having run nothing; `npm test` on an
#      empty script exits 0) — the refusals are not opinions about syntax.
#
#   C. THE REFUSAL SPEAKS. A human who put the file there is told WHAT was found
#      and WHY it is not enough, through the product's own gate note.
#
# ZERO worker spend by construction: nothing here spawns a worker, and the one
# leg that shells into `lcars run` does it under a PATH shim with COUNTING fakes
# for BOTH CLIs plus the spend fuse.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n' "$1"; }

# --- SPEND FUSE (the rig.sh contract, verbatim) -----------------------------
SHIM="$TMPROOT/shim"; SPEND_LOG="$TMPROOT/spend.log"
mkdir -p "$SHIM"; : > "$SPEND_LOG"
for b in claude copilot; do
  cat > "$SHIM/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*) echo "0.0.0-s299-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\t%s\n' "\$(basename "\$0")" >> "$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$b"
done
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || {
  echo "SPEND FUSE: counting fakes missing — refusing to run"; exit 1; }

# The REAL entry point, never a helper — the same call the gate makes.
dtc() { # repo → detect_test_cmd's answer for it
  ( bash -c '. "'"$COMMON"'" >/dev/null 2>&1; TOPLEVEL="'"$1"'"; detect_test_cmd' )
}
# The REAL message surface.
inert_why() { # repo → detect_inert_test_config's phrase ("" when there is none)
  ( bash -c '. "'"$COMMON"'" >/dev/null 2>&1; TOPLEVEL="'"$1"'"; detect_inert_test_config' ) 2>/dev/null
}
mk() { local d="$TMPROOT/$1"; mkdir -p "$d"; printf '%s' "$d"; }

# The fixture builders — one per shape, so a row of the table reads as the repo
# it describes rather than as a pile of heredocs.
pkg()   { printf '%s' "$2" > "$1/package.json"; }
mkfile(){ printf '%s' "$2" > "$1/Makefile"; }
runsh() { mkdir -p "$1/tests"; printf '%s' "$2" > "$1/tests/run.sh"; }

# ===========================================================================
# A. THE REGRESSION TABLE — every supported shape, pinned to MEASURED values
# ===========================================================================
# WHERE THESE VALUES COME FROM: each one was read out of the detector as it
# stood at c630b7f, before a line of the cure existed. The arms the table walks
# are `DETECT_TEST_CMD_ARMS` itself — js, python, rust, go, dotnet, ruby,
# generic — plus `jvm`, which `detect_stack` knows and `detect_test_cmd`
# deliberately has no arm for (its measured answer is EMPTY, and that is a fact
# this table locks so a later arm cannot land unnoticed).
echo "== A. THE SUPPORTED-STACK REGRESSION TABLE (measured before-values) =="

NPM_DEF='npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}'
VITEST='npx vitest run ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR#"$PWD/"}"}'
PYTEST='pytest "${LCARS_TESTS_DIR:-.}"'
UNITTEST='python3 -m unittest discover -s "${LCARS_TESTS_DIR:-tests}"'
UNITTEST_P='python3 -m unittest discover -s "${LCARS_TESTS_DIR:-tests}" -p "*_test.py"'
RUNSH='bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"'

row() { # label  repo  want
  local got; got="$(dtc "$2")"
  if [ "$got" = "$3" ]; then ok "$1"
  else bad "$1 — DRIFTED: want [$3] got [$got]"; fi
}

d="$(mk a-js-jest)";        pkg "$d" '{"scripts":{"test":"jest"}}'
row "A1.  js single-package (jest)" "$d" "$NPM_DEF"
d="$(mk a-js-mocha)";       pkg "$d" '{"scripts":{"test":"mocha"}}'
row "A2.  js single-package (mocha)" "$d" "$NPM_DEF"
d="$(mk a-js-vitest)";      pkg "$d" '{"scripts":{"test":"vitest run"}}'
row "A3.  js single-package (vitest → the relativizing form)" "$d" "$VITEST"
d="$(mk a-js-wsv)";         pkg "$d" '{"scripts":{"test":"vitest run"}}'
printf 'packages:\n  - "p/*"\n' > "$d/pnpm-workspace.yaml"
row "A4.  js pnpm workspace (vitest)" "$d" "$VITEST"
d="$(mk a-js-wsfall)";      pkg "$d" '{"workspaces":["p/*"],"scripts":{"test":"turbo test"}}'
row "A5.  js workspace, runner not named → the npm fallback" "$d" "$NPM_DEF"

d="$(mk a-py-ini)";         : > "$d/pytest.ini"
row "A6.  python (pytest.ini)" "$d" "$PYTEST"
d="$(mk a-py-proj)";        printf '[project]\nname="x"\n[tool.pytest.ini_options]\n' > "$d/pyproject.toml"
row "A7.  python (pyproject declares pytest)" "$d" "$PYTEST"
d="$(mk a-py-tox)";         printf '[tox]\nenvlist = py311\n[testenv]\ndeps = pytest\ncommands = pytest\n' > "$d/tox.ini"
row "A8.  python (a REAL tox.ini naming pytest)" "$d" "$PYTEST"
d="$(mk a-py-unit)";        printf '[project]\nname="x"\n' > "$d/pyproject.toml"
mkdir -p "$d/tests"; : > "$d/tests/test_a.py"
row "A9.  python (stdlib unittest layout)" "$d" "$UNITTEST"
d="$(mk a-py-unitp)";       printf '[project]\nname="x"\n' > "$d/pyproject.toml"
mkdir -p "$d/tests"; : > "$d/tests/a_test.py"
row "A10. python (unittest, *_test.py pattern)" "$d" "$UNITTEST_P"
d="$(mk a-py-bare)";        printf '[project]\nname="x"\n' > "$d/pyproject.toml"
row "A11. python (a bare pyproject claims nothing — unchanged)" "$d" ""

d="$(mk a-rust)";           printf '[package]\nname="x"\n' > "$d/Cargo.toml"
row "A12. rust (Cargo.toml)" "$d" "cargo test"
d="$(mk a-go)";             printf 'module x\n' > "$d/go.mod"
row "A13. go (go.mod)" "$d" "go test ./..."

d="$(mk a-dn1)"; mkdir -p "$d/A.Tests"
printf '<Project><ItemGroup><PackageReference Include="xunit"/></ItemGroup></Project>' > "$d/A.Tests/A.Tests.csproj"
row "A14. dotnet (exactly one test project)" "$d" "dotnet test A.Tests/A.Tests.csproj"
d="$(mk a-dn2)"; mkdir -p "$d/A.Tests" "$d/B.Tests"
printf '<Project><ItemGroup><PackageReference Include="xunit"/></ItemGroup></Project>' > "$d/A.Tests/A.Tests.csproj"
printf '<Project><ItemGroup><PackageReference Include="xunit"/></ItemGroup></Project>' > "$d/B.Tests/B.Tests.csproj"
row "A15. dotnet (several → claimed, deliberately no command)" "$d" ""

d="$(mk a-rb-rspec)";       printf "source 'x'\ngem 'rspec'\n" > "$d/Gemfile"
row "A16. ruby (Gemfile names rspec)" "$d" "bundle exec rspec"
d="$(mk a-rb-mini)";        printf "source 'x'\n" > "$d/Gemfile"; : > "$d/Rakefile"; mkdir -p "$d/test"
row "A17. ruby (test/ + Rakefile → minitest)" "$d" "bundle exec rake test"
d="$(mk a-rb-amb)";         : > "$d/Rakefile"; mkdir -p "$d/test" "$d/spec"
row "A18. ruby (both layouts → ambiguous, no command)" "$d" ""

d="$(mk a-mk)";             mkfile "$d" 'test:
	bash t.sh
'
row "A19. generic (a Makefile test: target with a recipe)" "$d" "make test"
d="$(mk a-runsh)";          runsh "$d" '#!/usr/bin/env bash
set -e
for f in tests/*.test.sh; do bash "$f"; done
'
row "A20. generic (a real tests/run.sh)" "$d" "$RUNSH"

d="$(mk a-jvm)";            printf '<project/>' > "$d/pom.xml"
row "A21. jvm (a stack with no detector arm — measured EMPTY)" "$d" ""
d="$(mk a-none)"
row "A22. an empty repo claims nothing" "$d" ""

# A23 — THE GROUND-TRUTH ARTIFACT, and the row that shows why tightening the
# python MARKER gate would have been the false negative this session must not
# ship. The inert tox.ini is noise; the runner the detector names here
# (`unittest discover` over a real test file) is REAL and RUNS. It must survive.
d="$(mk a-tox-decoy-real)"; printf '[tox]\nenvlist =\n' > "$d/tox.ini"
mkdir -p "$d/tests"; : > "$d/tests/test_a.py"
row "A23. an inert tox.ini BESIDE a real unittest layout still detects the REAL runner" "$d" "$UNITTEST"

# ===========================================================================
# B. THE INERT SHAPES — refused, each against a control with a DIFFERENT answer
# ===========================================================================
echo "== B. AN ARTIFACT THAT PROVABLY RUNS NOTHING IS NOT A TEST SYSTEM =="

refuses() { # label  repo
  local got; got="$(dtc "$2")"
  if [ -z "$got" ]; then ok "$1"
  else bad "$1 — ACCEPTED a decoy: [$got]"; fi
}
accepts() { # label  repo  want
  local got; got="$(dtc "$2")"
  if [ "$got" = "$3" ]; then ok "$1"
  else bad "$1 — want [$3] got [$got]"; fi
}

# B1. A MAKEFILE `test:` TARGET WITH NO RECIPE. Proven inert by running it:
#     `make test` → "Nothing to be done for `test'.", exit 0, no tests.
d="$(mk b-mk-empty)";  mkfile "$d" 'test:
'
refuses "B1a. a Makefile test: target with NO recipe is refused" "$d"
d="$(mk b-mk-phony)";  mkfile "$d" '.PHONY: test
test:

build:
	cc x.c
'
refuses "B1b. …and the .PHONY form of the same no-op is refused too" "$d"
#     THE CONTROL — a DIFFERENT answer from the same arm, so B1a is not just
#     "this suite refuses every Makefile".
# S299 FIX ROUND 1 — THIS CONTROL WAS ITSELF A DECOY. It wrote `@echo ran` and
# asserted it was accepted, which is precisely the inconsistency fix round 1
# closes: the identical string in a package.json `test` script was refused one
# section below (B3d). The control's JOB is "a real recipe is accepted", so it
# now carries a real recipe; `@echo ran` moved to E1a, where it is refused.
d="$(mk b-mk-real)";   mkfile "$d" 'test:
	PYTHONPATH=. pytest -q
'
accepts "B1c. CONTROL: one recipe line and the SAME file is accepted" "$d" "make test"
d="$(mk b-mk-prereq)"; mkfile "$d" 'test: unit integ
unit:
	@echo u
integ:
	@echo i
'
accepts "B1d. CONTROL: a recipe-less target with PREREQUISITES still runs them" "$d" "make test"
d="$(mk b-mk-semi)";   mkfile "$d" 'test: ; @echo inline
'
accepts "B1e. CONTROL: a recipe written inline after a semicolon is a recipe" "$d" "make test"
# S299 FIX ROUND 1 — same repair, same reason: the double-colon RULE is what
# this leg locks, so the recipe behind it is now a real command.
d="$(mk b-mk-dcolon)"; mkfile "$d" 'test::
	@bash tests/suite.sh
'
accepts "B1f. CONTROL: a double-colon rule with a recipe is accepted" "$d" "make test"
d="$(mk b-mk-incl)";   mkfile "$d" 'include extra.mk
test:
'
printf 'test:\n\t@echo from-include\n' > "$d/extra.mk"
accepts "B1g. CONTROL: a Makefile that INCLUDES another is never called inert (the recipe may be out of sight)" "$d" "make test"

# B2. AN EMPTY tests/run.sh. Proven inert by running it: exit 0, nothing ran.
d="$(mk b-run-empty)"; runsh "$d" ''
refuses "B2a. a zero-byte tests/run.sh is refused" "$d"
d="$(mk b-run-cmt)";   runsh "$d" '#!/usr/bin/env bash
# TODO: run the tests
set -euo pipefail
'
refuses "B2b. …and one that is only a shebang, comments and set-flags is refused" "$d"
# S299 FIX ROUND 1 — `set -e` + `exit 0` is not "one real command"; both are
# shell no-ops and fix round 1 refuses them (E6a, E8a). The control now holds a
# command that actually invokes a program.
d="$(mk b-run-real)";  runsh "$d" '#!/usr/bin/env bash
set -e
bash tests/suite.sh
'
accepts "B2c. CONTROL: one real command and the SAME file is accepted" "$d" "$RUNSH"

# B3. A package.json `test` SCRIPT THAT RUNS NOTHING. Proven inert by running
#     it: `npm test` on `""` exits 0 having run nothing; npm's own generated
#     placeholder echoes and exits 1. Neither names a runner.
d="$(mk b-js-empty)";  pkg "$d" '{"scripts":{"test":""}}'
refuses "B3a. an EMPTY npm test script is refused" "$d"
d="$(mk b-js-npmdef)"; pkg "$d" '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
refuses "B3b. npm's own generated placeholder is refused" "$d"
d="$(mk b-js-true)";   pkg "$d" '{"scripts":{"test":"true"}}'
refuses "B3c. a script that is just \`true\` is refused" "$d"
d="$(mk b-js-echo)";   pkg "$d" '{"scripts":{"test":"echo all good"}}'
refuses "B3d. a script that only echoes is refused" "$d"
#     THE CONTROLS — anything we cannot PROVE runs nothing is accepted. These
#     are the false-negative traps: each one's first word, or its truncated
#     text, could fool a lazier check.
d="$(mk b-js-runall)"; pkg "$d" '{"scripts":{"test":"run-all"}}'
accepts "B3e. CONTROL: an unrecognised command is accepted (we cannot prove it inert)" "$d" "$NPM_DEF"
d="$(mk b-js-shell)";  pkg "$d" '{"scripts":{"test":"./scripts/test.sh"}}'
accepts "B3f. CONTROL: a script file is accepted" "$d" "$NPM_DEF"
d="$(mk b-js-nested)"; pkg "$d" '{"scripts":{"test":"npm run test:unit"}}'
accepts "B3g. CONTROL: a delegating script is accepted" "$d" "$NPM_DEF"
d="$(mk b-js-esc)";    pkg "$d" '{"scripts":{"test":"echo \"hello\" && jest"}}'
accepts "B3h. CONTROL: an echo that then runs jest is accepted (the escaped-quote trap)" "$d" "$NPM_DEF"
d="$(mk b-js-pipe)";   pkg "$d" '{"scripts":{"test":"echo x | node t.js"}}'
accepts "B3i. CONTROL: an echo PIPED into a real command is accepted (the first-word trap)" "$d" "$NPM_DEF"
d="$(mk b-js-nodetest)"; pkg "$d" '{"scripts":{"test":"node --test"}}'
accepts "B3j. CONTROL: node's built-in runner is accepted" "$d" "$NPM_DEF"

# B4. FALLING THROUGH IS NOT THE SAME AS REFUSING. A placeholder npm script
#     beside a REAL Makefile target now reaches the generic arm — the dotnet
#     arm's recorded lesson (S147: never take an existing arm's answer away).
d="$(mk b-fallthru)";  pkg "$d" '{"scripts":{"test":"echo \"Error: no test specified\" && exit 1"}}'
# S299 FIX ROUND 1 — the Makefile here has to be a REAL one for the leg to mean
# anything: "the npm placeholder no longer steals a real `make test`". `@echo
# ran` was not real, and after fix round 1 both sides would be decoys and the
# leg would pass for the wrong reason.
mkfile "$d" 'test:
	bash tests/suite.sh
'
accepts "B4. a placeholder npm script no longer STEALS a real \`make test\`" "$d" "make test"

# ===========================================================================
# C. THE REFUSAL SAYS WHAT WAS FOUND AND WHY IT IS NOT ENOUGH
# ===========================================================================
echo "== C. THE REFUSAL IS ACTIONABLE =="

says() { # label  repo  pattern… → the reason must exist and mention every pattern
  local label="$1" repo="$2" why p; why="$(inert_why "$repo")"
  shift 2
  if [ -z "$why" ]; then bad "$label — no reason at all"; return; fi
  for p in "$@"; do
    case "$why" in *"$p"*) ;; *) bad "$label — [$why] does not mention '$p'"; return ;; esac
  done
  ok "$label — [$why]"
}

says "C1. the Makefile refusal names the artifact and the reason" "$TMPROOT/b-mk-empty" "Makefile" "test:" "no recipe"
says "C2. the tests/run.sh refusal names the artifact and the reason" "$TMPROOT/b-run-empty" "tests/run.sh" "no commands"
says "C3. the npm refusal names the artifact and the reason" "$TMPROOT/b-js-empty" "package.json" "test" "runs no tests"

# C4 — THE GROUND-TRUTH ARTIFACT GETS NAMED. The detector already returned
# nothing for a lone inert tox.ini (measured at c630b7f), so the hole there was
# never DETECTION — it was that the refusal said only "nothing detected" to a
# captain who had just put a file there. This leg is message-only and, by
# construction, cannot move a detection outcome: `detect_inert_test_config` is
# consulted for the WORDING, never by the python arm.
d="$(mk c-tox)"; printf '[tox]\nenvlist =\n' > "$d/tox.ini"
says "C4. a tox.ini declaring no environment is named in the refusal" "$d" "tox.ini" "envlist"
accepts "C4b. CONTROL: and the detector's answer for it is unchanged (still empty)" "$d" ""
why_real="$(inert_why "$TMPROOT/a-py-tox")"
if [ -z "$why_real" ]; then
  ok "C4c. CONTROL: a REAL tox.ini (envlist + [testenv]) yields NO inert reason"
else
  bad "C4c. a real tox.ini was called inert: [$why_real]"
fi

# C5 — A HEALTHY REPO HAS NOTHING TO EXPLAIN. The message surface must stay
# silent where there is no decoy, or every refusal note becomes noise.
for q in a-js-jest a-py-proj a-rust a-go a-mk a-runsh; do
  w="$(inert_why "$TMPROOT/$q")"
  if [ -z "$w" ]; then ok "C5. no inert reason invented for a healthy repo ($q)"
  else bad "C5. $q was called inert: [$w]"; fi
done

# C6 — THROUGH THE PRODUCT'S OWN GATE. `greenfield-detect-cmd-test` is the
# offline hook onto the REAL detector the scaffold arm gates on; it must now
# also hand back the reason, because that is what the gate's refusal note
# quotes to the human.
gf() { # repo → the hook's output
  ( cd "$1" && env PATH="$SHIM:$PATH" LCARS_GP_ROOT="$1" LCARS_VERSION_CHECK=0 \
      bash "$SCRIPT" greenfield-detect-cmd-test 2>&1 )
}
out="$(gf "$TMPROOT/b-mk-empty")"
if printf '%s' "$out" | grep -q '^DETECTED=$'; then
  ok "C6a. the real gate hook detects NOTHING for a recipe-less Makefile target"
else
  bad "C6a. the gate hook still detects a command: $(printf '%s' "$out" | tr '\n' '|')"
fi
if printf '%s' "$out" | grep -q '^INERT=.*no recipe'; then
  ok "C6b. …and reports WHY, so the gate's refusal can quote it"
else
  bad "C6b. the gate hook reports no reason: $(printf '%s' "$out" | tr '\n' '|')"
fi
out="$(gf "$TMPROOT/a-mk")"
if printf '%s' "$out" | grep -q '^DETECTED=make test$' && printf '%s' "$out" | grep -q '^INERT=$'; then
  ok "C6c. CONTROL: a real Makefile target still detects \`make test\` with no reason attached"
else
  bad "C6c. the control drifted: $(printf '%s' "$out" | tr '\n' '|')"
fi

# ===========================================================================
# E. ONE JUDGEMENT, THREE ARMS (S299 FIX ROUND 1)
# ===========================================================================
# MEASURED, 2026-10-15, on the FIRST build of this filter: the no-op judgement
# was wired to ONE arm out of three. The npm arm asked "does this name a runner,
# or is it only shell no-ops?"; the Makefile-recipe and tests/run.sh arms asked
# only "is there any command at all?". So the SAME STRING got TWO VERDICTS —
# `"test": "true"` was refused while a Makefile recipe of `true` was accepted,
# and the product contradicted its own claim that it requires something that can
# actually run.
#
# THE CURE IS STRUCTURAL: `_dtc_noop_only` is now the only copy of the
# judgement and all three arms call it, so they CANNOT drift apart again. E9 is
# the leg that proves that structurally rather than by example: it drives the
# same list of strings through all three arms and insists the verdicts MATCH.
#
# Every refusal below is paired with a CONTROL through the SAME arm that must
# print a DIFFERENT answer. Two arms agreeing on "refused" is not a pass.
echo "== E. THE SAME STRING GETS THE SAME VERDICT IN ALL THREE ARMS =="

mk_mk()  { local d; d="$(mk "$1")"; mkfile "$d" "test:
	$2
"; printf '%s' "$d"; }
mk_sh()  { local d; d="$(mk "$1")"; runsh "$d" "#!/usr/bin/env bash
$2
"; printf '%s' "$d"; }

# E1–E4 — THE DECOYS THE FIRST BUILD ACCEPTED. Each was `make test`-accepted
# before this round; each is the npm arm's own no-op vocabulary.
refuses "E1a. a Makefile recipe of \`@echo \"no tests yet\"\` is refused" "$(mk_mk e-mk-echo '@echo "no tests yet"')"
accepts "E1b. CONTROL: \`PYTHONPATH=. pytest -q\` in the SAME position is accepted" "$(mk_mk e-mk-pytest 'PYTHONPATH=. pytest -q')" "make test"
refuses "E2a. a Makefile recipe of \`true\` is refused" "$(mk_mk e-mk-true 'true')"
accepts "E2b. CONTROL: \`./gradlew test\` is accepted" "$(mk_mk e-mk-gradle './gradlew test')" "make test"
refuses "E3a. a Makefile recipe of \`:\` is refused" "$(mk_mk e-mk-colon ':')"
accepts "E3b. CONTROL: \`@mvn -q test\` is accepted (the \`@\` prefix is stripped, the runner is seen)" "$(mk_mk e-mk-mvn '@mvn -q test')" "make test"
refuses "E4a. a Makefile recipe of \`exit 0\` is refused" "$(mk_mk e-mk-exit 'exit 0')"
accepts "E4b. CONTROL: \`-pytest -q\` is accepted (make's dash prefix)" "$(mk_mk e-mk-dash '-pytest -q')" "make test"

# E5 — THE FALSE-NEGATIVE TRAPS. A legitimate recipe this read cannot decode
# must ACCEPT. These are the shapes real Makefiles use, and a refusal here would
# strand a real repo at the filing gate — strictly worse than the decoy.
accepts "E5a. CONTROL: a sub-make (\`\$(MAKE) -C app test\`) is accepted" "$(mk_mk e-mk-sub '$(MAKE) -C app test')" "make test"
accepts "E5b. CONTROL: \`cd src && go test ./...\` is accepted" "$(mk_mk e-mk-cd 'cd src && go test ./...')" "make test"
accepts "E5c. CONTROL: \`set -e; for d in */; do (cd \$\$d && pytest); done\` is accepted" "$(mk_mk e-mk-loop 'set -e; for d in */; do (cd $$d && pytest); done')" "make test"
accepts "E5d. CONTROL: \`docker compose run --rm test\` is accepted" "$(mk_mk e-mk-docker 'docker compose run --rm test')" "make test"
accepts "E5e. CONTROL: \`test -d tests && pytest || true\` is accepted" "$(mk_mk e-mk-guard 'test -d tests && pytest || true')" "make test"
accepts "E5f. CONTROL: a recipe whose command is simply UNKNOWN to us is accepted" "$(mk_mk e-mk-unknown './run-the-suite --all')" "make test"

# E5g — A GENERATED RULE IS OUT OF SIGHT, like an included one. The `test:`
# line inside a `define` body is indistinguishable from a real target to a
# structural read, so a Makefile that can generate rules is accepted whole. The
# control is the IDENTICAL no-op recipe with no `define` around it.
d="$(mk e-mk-define)"; mkfile "$d" 'define T
test:
	true
endef
$(eval $(T))
'
accepts "E5g. CONTROL: a Makefile with a \`define\`/\`\$(eval …)\` block is never called inert" "$d" "make test"
refuses "E5h. …while the SAME \`true\` recipe without the define is still refused" "$(mk_mk e-mk-truebare 'true')"

# E6–E8 — THE SAME, through the tests/run.sh arm.
refuses "E6a. a tests/run.sh body of \`true\` is refused" "$(mk_sh e-sh-true 'true')"
accepts "E6b. CONTROL: a body that SOURCES a library is accepted (\`.\` is not a no-op)" "$(mk_sh e-sh-source '. tests/lib.sh')" "$RUNSH"
refuses "E7a. an \`echo … >&2\` + \`exit 0\` body is refused (a descriptor redirection is not a hiding place)" "$(mk_sh e-sh-stderr 'echo "no tests configured" >&2
exit 0')"
accepts "E7b. CONTROL: a REAL command with the SAME redirection is accepted" "$(mk_sh e-sh-redir './suite.sh >out.log 2>&1')" "$RUNSH"
refuses "E8a. a tests/run.sh body of \`:\` is refused" "$(mk_sh e-sh-colon ':')"
accepts "E8b. CONTROL: a python tests/run.sh is accepted (\`import\` is not a no-op)" "$(mk_sh e-sh-py 'import subprocess
subprocess.run(["pytest"])')" "$RUNSH"

# E8c — A DELIBERATE NON-REFUSAL, recorded rather than fixed. `cd "$(dirname
# "$0")"` and nothing else is a pointless tests/run.sh, and it is ACCEPTED,
# because a command substitution really does run a command (`: $(./suite.sh)`
# runs the suite) and the shared judgement bails on `$(` for that reason. The
# accept-bias outranks this decoy: refusing it means dropping the one guard that
# keeps an invisible command from being called a no-op.
accepts "E8c. a \`cd \"\$(dirname \"\$0\")\"\` body is ACCEPTED — a command substitution is never provably inert" "$(mk_sh e-sh-cdonly 'cd "$(dirname "$0")"')" "$RUNSH"

# ---------------------------------------------------------------------------
# E9 — THE ANTI-DIVERGENCE LEG. The bug was not a wrong answer; it was TWO
# answers to one question. So this drives ONE list of bodies through ALL THREE
# arms and fails the moment any two disagree. It is the leg that makes a fourth
# copy of the judgement impossible to land quietly.
# ---------------------------------------------------------------------------
verdict_mk() { [ -z "$(dtc "$(mk_mk "v-mk-$1" "$2")")" ] && echo REFUSED || echo ACCEPTED; }
verdict_sh() { [ -z "$(dtc "$(mk_sh "v-sh-$1" "$2")")" ] && echo REFUSED || echo ACCEPTED; }
verdict_js() { local d; d="$(mk "v-js-$1")"
  printf '{"scripts":{"test":%s}}' "$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')" > "$d/package.json"
  [ -z "$(dtc "$d")" ] && echo REFUSED || echo ACCEPTED; }

i=0
for body in 'true' ':' 'exit 0' 'echo no tests here' 'printf "x"' 'false'; do
  i=$((i+1))
  a="$(verdict_mk "n$i" "$body")"; b="$(verdict_sh "n$i" "$body")"; c="$(verdict_js "n$i" "$body")"
  if [ "$a" = REFUSED ] && [ "$b" = REFUSED ] && [ "$c" = REFUSED ]; then
    ok "E9. a no-op (\`$body\`) is refused IDENTICALLY by all three arms"
  else
    bad "E9. DIVERGED on a no-op (\`$body\`): Makefile=$a run.sh=$b package.json=$c"
  fi
done
i=0
for body in './suite.sh' 'bash tests/all.sh' 'node ./t.js' 'PYTHONPATH=. pytest -q' 'run-all --ci'; do
  i=$((i+1))
  a="$(verdict_mk "y$i" "$body")"; b="$(verdict_sh "y$i" "$body")"; c="$(verdict_js "y$i" "$body")"
  if [ "$a" = ACCEPTED ] && [ "$b" = ACCEPTED ] && [ "$c" = ACCEPTED ]; then
    ok "E9. a real command (\`$body\`) is accepted IDENTICALLY by all three arms"
  else
    bad "E9. DIVERGED on a real command (\`$body\`): Makefile=$a run.sh=$b package.json=$c"
  fi
done

# ===========================================================================
# F. THE REFUSAL MUST NOT MISDESCRIBE WHAT IT FOUND (S299 FIX ROUND 1)
# ===========================================================================
# Two real files were refused with the words "a Makefile `test:` target with no
# recipe and no prerequisites". Both HAVE a recipe. One of them is a working
# Makefile and should never have been refused at all.
echo "== F. THE REFUSAL DESCRIBES THE FILE THAT IS ACTUALLY THERE =="

# F1 — `.RECIPEPREFIX`, THE ROUND'S ONE FALSE NEGATIVE. GNU Make >= 3.82 lets a
# Makefile choose its recipe-introducing character, and a `>`-prefixed recipe is
# a legal, working recipe. The detector looked for tabs and nothing else, so it
# saw no recipe and refused a repo whose `make test` runs the suite.
#
# HONEST CAVEAT, recorded by the tester and still true: this box ships GNU Make
# 3.81, which PREDATES the directive (it answers "*** missing separator"), so
# runnability cannot be demonstrated here. The evidence is the directive's spec
# plus the detection change; the control below is what keeps the change from
# being a blanket "accept any Makefile".
d="$(mk f-recipeprefix)"; mkfile "$d" '.RECIPEPREFIX = >
test:
>pytest -q
'
accepts "F1a. a .RECIPEPREFIX recipe is SEEN, and the Makefile is accepted" "$d" "make test"
d="$(mk f-recipeprefix-empty)"; mkfile "$d" '.RECIPEPREFIX = >
test:
'
refuses "F1b. CONTROL: .RECIPEPREFIX with NO recipe line is still refused" "$d"
d="$(mk f-recipeprefix-noop)"; mkfile "$d" '.RECIPEPREFIX = >
test:
>@echo "no tests yet"
'
refuses "F1c. CONTROL: and a .RECIPEPREFIX recipe that is a no-op is still refused" "$d"

# F2 — EIGHT SPACES INSTEAD OF A TAB. Refusing is CORRECT (real make: "***
# missing separator (did you mean TAB instead of 8 spaces?). Stop." — verified
# by running it on this box). Claiming there is no recipe was not: the fix is one
# keystroke and naming it is the entire value of the message.
d="$(mk f-spaces)"; mkfile "$d" 'test:
        pytest -q
'
refuses "F2a. a space-indented recipe is refused (make cannot read the file)" "$d"
says    "F2b. …and the refusal names the REAL problem" "$d" "SPACES" "tab" "missing separator"
w="$(inert_why "$TMPROOT/f-spaces")"
case "$w" in
  *"no recipe"*) bad "F2c. the refusal STILL claims there is no recipe: [$w]" ;;
  *)             ok  "F2c. …and no longer claims the file has no recipe" ;;
esac
d="$(mk f-spaces-ctl)"; mkfile "$d" 'test:
	pytest -q
'
accepts "F2d. CONTROL: the IDENTICAL recipe behind a TAB is accepted" "$d" "make test"

# F3 — THE NO-OP RECIPE'S OWN SENTENCE. It must quote what it found and must not
# borrow the "no recipe" wording either.
says "F3a. a no-op recipe refusal quotes the recipe" "$TMPROOT/e-mk-echo" "Makefile" "no test runner" 'echo "no tests yet"'
w="$(inert_why "$TMPROOT/e-mk-echo")"
case "$w" in
  *"no recipe"*) bad "F3b. the no-op-recipe refusal claims there is no recipe: [$w]" ;;
  *)             ok  "F3b. …and does not claim the target has no recipe" ;;
esac
says "F3c. a no-op tests/run.sh refusal quotes the body" "$TMPROOT/e-sh-stderr" "tests/run.sh" "no test runner" "no tests configured"

# ===========================================================================
# G. WHAT `lcars init` TELLS THE CAPTAIN (S299 FIX ROUND 1)
# ===========================================================================
# MEASURED on the real product: over a Makefile decoy, `lcars init` printed
#   ⚠ TEST SYSTEMS OFFLINE — this repo HAS a test system (a Makefile `test:`
#   target) but no test command is configured … Repair: lcars update
#   --test-command '<command>'
# — it asserted the EXACT claim this filter exists to deny, and then prescribed
# the escape hatch. The tester followed that prescription and got ✓ TEST SYSTEMS
# ONLINE and a passing probe for a `make test` that prints "Nothing to be done".
# The product's own advice walked him back into the bug.
#
# WORDING ONLY, deliberately. `lcars_test_system_evidence` still claims a test
# system from file presence (it feeds the FILING gate, where a false negative
# kills a mission before it starts, and it is ledgered there), the ROUTE is
# unchanged, and `--test-command` remains available for someone who knows a
# runner LCARS missed. Only the sentence changed.
echo "== G. INIT NO LONGER ASSERTS THE OPPOSITE OF WHAT IT JUST DECIDED =="

INIT_SH="$REPO_ROOT/skills/lcars-init/init.sh"
init_line() { # repo → init's readiness line
  ( cd "$1" && env PATH="$SHIM:$PATH" LCARS_VERSION_CHECK=0 bash "$INIT_SH" 2>&1 \
      | grep -E 'TEST SYSTEMS? OFFLINE|NO TEST SYSTEMS? FOUND' | head -1 )
}
gitrepo() { local d; d="$(mk "$1")"; ( cd "$d" && git init -q 2>/dev/null ); printf '%s' "$d"; }

d="$(gitrepo g-mk)"; mkfile "$d" 'test:
'
printf 'print("x")\n' > "$d/app.py"
L="$(init_line "$d")"
case "$L" in
  *"HAS a test system"*) bad "G1a. init STILL tells the captain he has a test system: [$L]" ;;
  "") bad "G1a. init printed no readiness line at all" ;;
  *)  ok  "G1a. init no longer claims the decoy repo HAS a test system" ;;
esac
case "$L" in
  *"no recipe"*) ok  "G1b. …it names the artifact it found and why it does not count" ;;
  *)             bad "G1b. init's line does not name what was found: [$L]" ;;
esac
case "$L" in
  *"Repair: lcars update --test-command"*) bad "G1c. init still PRESCRIBES the escape hatch as the repair: [$L]" ;;
  *)                                       ok  "G1c. …and no longer prescribes --test-command as THE repair" ;;
esac
case "$L" in
  *"--test-command"*) ok  "G1d. …while the hatch stays available for someone who knows a runner is here" ;;
  *)                  bad "G1d. the escape hatch disappeared from init's line: [$L]" ;;
esac

# G2 — THE CONTROL, and it must print a DIFFERENT line. A repo that genuinely
# HAS a test system (a jest devDependency) and simply has no command configured
# still gets S183's sentence, word for word. If this drifts, the fix above was a
# blanket rewrite rather than a plumbing job.
d="$(gitrepo g-real)"
printf '{"name":"x","devDependencies":{"jest":"^29"}}\n' > "$d/package.json"
printf 'console.log(1)\n' > "$d/index.js"
L2="$(init_line "$d")"
case "$L2" in
  *"HAS a test system"*"a test framework in package.json"*) ok "G2a. CONTROL: a genuinely tested repo still reads \"HAS a test system\"" ;;
  *) bad "G2a. the control drifted: [$L2]" ;;
esac
[ "$L2" != "$L" ] && ok "G2b. CONTROL: the two repos get DIFFERENT lines" \
                  || bad "G2b. decoy and tested repo print the SAME line — the control proves nothing"

# G3 — THE RESTORED CLAUSE. Before this session a repo carrying npm's generated
# placeholder read "◇ NO TEST SYSTEM FOUND — … (the `test` script here names no
# test runner)". The filter stopped emitting a candidate for it, which is right,
# and the repo fell through to a branch where that parenthetical did not exist —
# so the cure made the message LESS specific than the bug it replaced.
d="$(gitrepo g-npm)"
printf '{"name":"x","scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}}\n' > "$d/package.json"
printf 'console.log(1)\n' > "$d/index.js"
L3="$(init_line "$d")"
case "$L3" in
  *"names no test runner"*) ok "G3a. the npm-placeholder repo is told its \`test\` script names no test runner" ;;
  *) bad "G3a. the restored clause is missing: [$L3]" ;;
esac
case "$L3" in
  *"NO TEST SYSTEM FOUND"*) ok "G3b. …in the same voice it had before (code, nothing to prove it with)" ;;
  *) bad "G3b. the voice drifted: [$L3]" ;;
esac

# ===========================================================================
# H. THE OTHER TWO SURFACES (S299 FIX ROUND 2)
# ===========================================================================
# Round 1 cured the CLI readiness line (section G) and left the SAME
# contradiction standing on two more surfaces. Both are covered here, each
# against a live control that must answer DIFFERENTLY — two arms printing the
# same answer is a failed control, never a pass.
#
#   H1  readiness.sh --json. The reason never left the shell, so the VIEWSCREEN
#       — the surface the captain actually works from — could only print the
#       foundation's half of the story and asserted "this repo HAS a test
#       system" on a repo whose CLI line said the configuration cannot run.
#       MEASURED through the real chain (readiness.sh → LocalAdapter →
#       readinessCopy): the decoy's band was byte-identical to a repo carrying a
#       real jest config. The board branch itself is pinned by the node-vm
#       harness in web/tests/test_readiness.py; this is the payload it reads.
#   H2  lcars update --fix-tests, the third copy of the sentence.
#
# MESSAGE/PAYLOAD ONLY. `foundation` keeps its value, `foundation-gate --json`
# is byte-identical across every repo on this machine (measured), and the
# filing route does not move — a false negative at the filing gate refuses a
# mission before it starts, which is strictly worse than the decoy.
echo "== H. THE BOARD PAYLOAD AND --fix-tests TELL THE SAME STORY =="

READINESS_SH="$REPO_ROOT/skills/lcars-init/readiness.sh"
rjson() { # repo → readiness.sh --json
  ( cd "$1" && env PATH="$SHIM:$PATH" bash "$READINESS_SH" --json 2>/dev/null )
}
jkey() { # json key → the value, or "" (null reads as "")
  printf '%s' "$1" | python3 -c 'import json,sys
try: v = json.load(sys.stdin).get(sys.argv[1])
except Exception: v = None
print("" if v is None else v)' "$2" 2>/dev/null
}

# H1 — the DECOY: a recipe-less `test:` target over real code.
d="$(gitrepo h-mk)"; mkfile "$d" 'test:
'
printf 'print("x")\n' > "$d/app.py"
J="$(rjson "$d")"
IW="$(jkey "$J" inertWhy)"
case "$IW" in
  *"no recipe"*) ok "H1a. readiness --json carries inertWhy naming the artifact and why it cannot run" ;;
  "")            bad "H1a. readiness --json has no inertWhy for the decoy: [$J]" ;;
  *)             bad "H1a. inertWhy is present but says something else: [$IW]" ;;
esac
# The axes must BOTH survive — the board needs the pair, not a replacement.
[ "$(jkey "$J" foundation)" = unconfigured ] \
  && ok "H1b. …while \`foundation\` keeps its value (the FILING gate is untouched)" \
  || bad "H1b. foundation moved on the decoy: [$(jkey "$J" foundation)]"
case "$(jkey "$J" foundationWhy)" in
  "a Makefile \`test:\` target") ok "H1c. …and \`foundationWhy\` is unchanged too" ;;
  *) bad "H1c. foundationWhy drifted: [$(jkey "$J" foundationWhy)]" ;;
esac

# H1d — THE CONTROL. A repo that genuinely HAS a test system and simply has no
# command configured must carry NO inert reason at all, so the board keeps
# S183's sentence there word for word. If this drifts, the plumbing became a
# blanket rewrite.
d2="$(gitrepo h-real)"
printf 'module.exports={}\n' > "$d2/jest.config.js"
printf 'console.log(1)\n' > "$d2/index.js"
J2="$(rjson "$d2")"
[ -z "$(jkey "$J2" inertWhy)" ] \
  && ok "H1d. CONTROL: a real-framework repo carries NO inert reason" \
  || bad "H1d. the control repo was handed an inert reason: [$(jkey "$J2" inertWhy)]"
[ "$(jkey "$J2" foundation)" = unconfigured ] \
  && ok "H1e. CONTROL: …and reaches the SAME verdict, so the only difference is the reason" \
  || bad "H1e. the control is not even the same verdict: [$(jkey "$J2" foundation)]"
[ "$J" != "$J2" ] \
  && ok "H1f. CONTROL: the two payloads DIFFER" \
  || bad "H1f. decoy and real repo emit the SAME payload — the control proves nothing"

# H2 — `lcars update --fix-tests`. Detection has no candidate on either repo, so
# both reach the discovery crew and both fail it; the REPORT is what differs.
#
# THE WORKER IS A RECORDER, not the PATH fuse. run_discovery resolves
# $LCARS_WORKER_BIN first, so pointing it at a local recorder means nothing
# reaches a CLI through PATH and D1's zero keeps its exact meaning, while this
# leg still walks the real run_discovery path. The recorder writes no discovery
# JSON, which is the honest "crew came back with nothing" outcome.
UPDATE_SH="$REPO_ROOT/skills/lcars-update/update.sh"
# It is NAMED `claude` on purpose: run_discovery passes `basename $wb` to the
# worker adapter as the CLI, and the adapter refuses an argv it has no profile
# for — so a recorder called anything else never gets invoked and an assertion
# over its argv would be measuring an empty file.
WRECDIR="$TMPROOT/wrec"; mkdir -p "$WRECDIR"
WREC="$WRECDIR/claude"; WLOG="$TMPROOT/worker-argv.txt"; : > "$WLOG"
cat > "$WREC" <<WR
#!/usr/bin/env bash
case " \$* " in *" --version "*|*" -v "*) echo "0.0.0-s299-recorder"; exit 0 ;; esac
printf '%s\n' "\$*" >> "$WLOG"
exit 0
WR
chmod +x "$WREC"
fixline() { # repo → --fix-tests output
  ( cd "$1" && env PATH="$SHIM:$PATH" LCARS_WORKER_BIN="$WREC" \
      LCARS_VERSION_CHECK=0 bash "$UPDATE_SH" --fix-tests 2>&1 )
}
mkdir -p "$d/.git/lcars"  && printf '{\n  "testCommand": null\n}\n' > "$d/.git/lcars/config.json"
mkdir -p "$d2/.git/lcars" && printf '{\n  "testCommand": null\n}\n' > "$d2/.git/lcars/config.json"
F1="$(fixline "$d")";  RC1=$?
F2="$(fixline "$d2")"; RC2=$?
case "$F1" in
  *"HAS a test system"*) bad "H2a. --fix-tests STILL tells the captain he has a test system: [$F1]" ;;
  *)                     ok  "H2a. --fix-tests no longer claims the decoy HAS a test system" ;;
esac
case "$F1" in
  *"cannot run"*"no recipe"*) ok "H2b. …it names the artifact and why it cannot run" ;;
  *) bad "H2b. --fix-tests does not name what was found: [$F1]" ;;
esac
case "$F1" in
  *"REPAIR INCOMPLETE"*) ok "H2c. …in the same REPAIR-INCOMPLETE voice (a repair that did not land)" ;;
  *) bad "H2c. the voice drifted: [$F1]" ;;
esac
case "$F1" in
  *"Config untouched"*) ok "H2d. …and still promises the config was untouched" ;;
  *) bad "H2d. the config-untouched promise disappeared: [$F1]" ;;
esac
grep -q '"testCommand": null' "$d/.git/lcars/config.json" \
  && ok "H2e. …and the promise is TRUE — nothing was written" \
  || bad "H2e. --fix-tests wrote a testCommand on the decoy"
# H2f — THE CONTROL: the shipped sentence, word for word, on a real test system.
case "$F2" in
  *"HAS a test system (jest.config.js)"*) ok "H2f. CONTROL: a real-framework repo still reads \"HAS a test system\"" ;;
  *) bad "H2f. the control drifted: [$F2]" ;;
esac
[ "$F1" != "$F2" ] \
  && ok "H2g. CONTROL: the two repos get DIFFERENT reports" \
  || bad "H2g. decoy and real repo print the SAME report — the control proves nothing"
# The exit code is part of the contract: a repair that did not land is non-zero,
# and it was non-zero before this round too.
{ [ "$RC1" -ne 0 ] && [ "$RC2" -ne 0 ]; } \
  && ok "H2h. both arms still exit non-zero (the exit contract did not move)" \
  || bad "H2h. an exit code moved: decoy=$RC1 control=$RC2"
# And no --model upgrade was smuggled into the discovery spawn.
if grep -q -- '--model' "$WLOG" 2>/dev/null; then
  bad "H2i. the discovery spawn passed --model: [$(grep -o -- '--model[^ ]* *[^ ]*' "$WLOG" | head -1)]"
else
  ok "H2i. the discovery spawn passed no --model (argv recorded: $(wc -l < "$WLOG" | tr -d ' ') invocation(s))"
fi

# ===========================================================================
# D. ZERO SPEND
# ===========================================================================
n="$(grep -c '^SPAWN' "$SPEND_LOG" 2>/dev/null | head -1)"
if [ "${n:-0}" = "0" ]; then
  ok "D1. ZERO worker spend across the whole suite (counting shim saw 0 spawns)"
else
  bad "D1. the suite SPAWNED $n worker(s) — money leaked"
fi

printf '\ninert-test-config: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
