#!/usr/bin/env bash
# Fast, SCOPED test for the S147 DOTNET gate-leg hardening — REAL SDK drives.
#
# S104-105 gave dotnet detection + compile-failure phrasings, but its gate legs
# were half-built: NO seeded testCommand, NO native isolation case (so a staged
# .cs rode the generic $LCARS_TESTS_DIR path, which `dotnet test` cannot honour),
# and NO VSTest zero-collect phrasings — the open silent-green trap. This suite
# is where the REAL SDK lives: it drives `dotnet test` against `dotnet new xunit`
# fixtures and asserts the harness seams behave on its ACTUAL output —
#   • detect_test_cmd seeds `dotnet test <testproj>` for exactly one test project
#     (solution layout included), warns-and-refuses on several, seeds nothing on
#     none, and NEVER clobbers a hand-set command;
#   • native_scoped_cmd(dotnet) builds a `--filter FullyQualifiedName~Ns.Class`
#     invocation from the CLASSES the staged file declares (the observed FQN is
#     Namespace.Class.Method — the FILE NAME never appears in it), so siblings
#     are compiled but NOT run — the S106 per-stack isolation invariant;
#   • the filter is NAMESPACE-QUALIFIED so a same-named class in another
#     namespace can never ride along (observed collision, spike round 2);
#   • a filter matching NOTHING and an EMPTY test project both exit **0** with
#     VSTest's own "No test matches the given testcase filter" / "No test is
#     available in" — the exact green-on-nothing trap S85/S106 taught us to
#     hunt — so both must read zero-collected → INCONCLUSIVE, never a pass;
#   • no discoverable .csproj ⇒ a legible INCONCLUSIVE naming the fix, never a
#     raw MSBuild stack trace and never a green;
#   • xUnit/NUnit/MSTest assertion output classifies as `assertion` (legibility)
#     without false-firing on app output that merely quotes the phrases.
#
# If no usable dotnet SDK is present the suite SKIPS with a LOUD notice — it
# never silently passes. Zero model tokens: real SDK, stub workers, no network
# beyond whatever `dotnet` restores into its own cache.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
COMMON="${LCARS_COMMON_SH:-$REPO_ROOT/skills/lcars-init/lcars-common.sh}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }

echo "S147 dotnet stack — REAL dotnet SDK drives"

export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
HAVE_SDK=0
if command -v dotnet >/dev/null 2>&1 && dotnet --list-sdks >/dev/null 2>&1 \
   && [ -n "$(dotnet --list-sdks 2>/dev/null)" ]; then
  HAVE_SDK=1
fi

# --- the seams under test ---------------------------------------------------
LIB="$(mktemp "$TMPROOT/lib.XXXX")"
for fn in resolve_stack stack_is_native native_scoped_cmd \
          native_dotnet_project_for native_dotnet_scan native_dotnet_test_fqns \
          native_dotnet_unnameable \
          native_dotnet_declared_tests proof_dotnet_collected_count \
          native_no_target_reason \
          proof_native_run_dir proof_is_test_path rg_signature \
          suite_collected_zero_tests proof_zero_collected; do
  sed -n "/^$fn() {/,/^}/p" "$SCRIPT" >>"$LIB"
done
printf 'json_str() { printf ""; }\n' >>"$LIB"
# shellcheck source=/dev/null
. "$LIB"

# detect_test_cmd + friends come from lcars-common. It defines functions and data
# only and runs nothing on its own, so the suite SOURCES THE WHOLE FILE — exactly
# as init/update/readiness do. (S147: the per-stack seed arms made a hand-listed
# `sed`-extract brittle — a helper added to the chain but forgotten in the list
# silently emptied every seed. Sourcing the real file cannot drift.)
# shellcheck source=/dev/null
. "$COMMON"

export LCARS_STACK=dotnet

# ============================================================================
# 1. SEED MATRIX — detect_test_cmd's dotnet arm (no SDK needed)
# ============================================================================
mk_proj() { # dir name [sdkref=1]
  mkdir -p "$1"
  { echo '<Project Sdk="Microsoft.NET.Sdk">'
    echo '  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>'
    echo '  <ItemGroup>'
    [ "${3:-1}" = 1 ] && echo '    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.14.1" />'
    echo '    <PackageReference Include="xunit" Version="2.9.3" />'
    echo '  </ItemGroup>'
    echo '</Project>'
  } >"$1/$2.csproj"
}

# 1a. single top-level xunit test project → dotnet test <proj>
R="$TMPROOT/seed-single"; mkdir -p "$R"; mk_proj "$R" MyApp.Tests
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = "dotnet test MyApp.Tests.csproj" ] \
  && ok "1a. single test project ⇒ 'dotnet test MyApp.Tests.csproj'" \
  || bad "1a. expected 'dotnet test MyApp.Tests.csproj', got: [$CMD]"

# 1b. solution layout (src/ + tests/) with ONE test project → the same, by path.
#     .NET 10's `dotnet new sln` emits a .slnx, so BOTH extensions must mark the
#     repo as dotnet (observed in the S147 spike).
R="$TMPROOT/seed-sln"; mkdir -p "$R"
: >"$R/Demo.slnx"
mk_proj "$R/src/App" App 0
mk_proj "$R/tests/App.Tests" App.Tests 1
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = "dotnet test tests/App.Tests/App.Tests.csproj" ] \
  && ok "1b. sln + one test project ⇒ 'dotnet test tests/App.Tests/App.Tests.csproj'" \
  || bad "1b. expected the sln test-project path, got: [$CMD]"
S="$(TOPLEVEL="$R" detect_stack)"
[ "$S" = dotnet ] && ok "1c. a .slnx-only solution repo detects as stack=dotnet" \
                  || bad "1c. .slnx repo should detect dotnet, got: [$S]"

# 1d. TWO test projects → NO seed (the S105 ambiguous idiom: warn, never guess).
R="$TMPROOT/seed-two"; mkdir -p "$R"
: >"$R/Demo.sln"
mk_proj "$R/tests/A.Tests" A.Tests 1
mk_proj "$R/tests/B.Tests" B.Tests 1
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ -z "$CMD" ] && ok "1d. two test projects ⇒ NO seed (refuses to guess)" \
              || bad "1d. two test projects should seed nothing, got: [$CMD]"
LIST="$(TOPLEVEL="$R" detect_dotnet_test_projects | tr '\n' ' ')"
case "$LIST" in
  *A.Tests.csproj*B.Tests.csproj*|*B.Tests.csproj*A.Tests.csproj*)
    ok "1e. both candidate projects are NAMED for the warning" ;;
  *) bad "1e. expected both projects listed, got: [$LIST]" ;;
esac

# 1f. a dotnet repo with NO test project → no seed.
R="$TMPROOT/seed-none"; mkdir -p "$R"; mk_proj "$R" App 0
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ -z "$CMD" ] && ok "1f. csproj but no TEST project ⇒ no seed" \
              || bad "1f. expected no seed, got: [$CMD]"

# 1f'. NuGet package ids are CASE-INSENSITIVE, so a csproj written
#      `microsoft.net.test.sdk` is a perfectly valid test project — it used to
#      fall through to the greenfield voice.
R="$TMPROOT/seed-case"; mkdir -p "$R/Low.Proj"
{ echo '<Project Sdk="Microsoft.NET.Sdk">'
  echo '  <ItemGroup><PackageReference Include="microsoft.net.test.sdk" Version="17.14.1" /></ItemGroup>'
  echo '</Project>'
} >"$R/Low.Proj/Low.Proj.csproj"
[ "$(TOPLEVEL="$R" detect_stack)" = dotnet ] \
  && ok "1f'. a lower-case microsoft.net.test.sdk ref is still a test project" \
  || bad "1f'. case-sensitive Test.Sdk match missed a valid test project"
[ "$(TOPLEVEL="$R" detect_test_cmd)" = "dotnet test Low.Proj/Low.Proj.csproj" ] \
  && ok "1f''. …and it seeds normally" \
  || bad "1f''. expected the lower-case project to seed"

# 1g. the *Tests*.csproj NAME convention counts even without the Test.Sdk ref.
R="$TMPROOT/seed-convention"; mkdir -p "$R"
: >"$R/Demo.sln"
mk_proj "$R/src/App" App 0
mk_proj "$R/test/App.Tests" App.Tests 0
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = "dotnet test test/App.Tests/App.Tests.csproj" ] \
  && ok "1g. *Tests*.csproj naming convention seeds without a Test.Sdk ref" \
  || bad "1g. expected the convention project, got: [$CMD]"

# 1h. bin/obj build output is NEVER mistaken for a project.
R="$TMPROOT/seed-binobj"; mkdir -p "$R"; mk_proj "$R" MyApp.Tests
mkdir -p "$R/obj" "$R/bin/Debug"
cp "$R/MyApp.Tests.csproj" "$R/obj/Decoy.Tests.csproj"
cp "$R/MyApp.Tests.csproj" "$R/bin/Debug/Decoy2.Tests.csproj"
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = "dotnet test MyApp.Tests.csproj" ] \
  && ok "1h. bin/ and obj/ copies are ignored (still exactly one project)" \
  || bad "1h. bin/obj decoys leaked into detection, got: [$CMD]"

# D5. THE CANONICAL LAYOUT: `dotnet new xunit -o MyApp.Tests` puts the project
# ONE DIRECTORY DOWN and writes NO root solution. Detection globbed the TOP
# LEVEL only, so the most common C# repo in existence inited as stack:unknown
# with no seed — and then read out the greenfield "no test systems found" lie,
# even though detect_dotnet_test_projects had already recursed and found it.
R="$TMPROOT/seed-onedown"; mkdir -p "$R"; mk_proj "$R/MyApp.Tests" MyApp.Tests
S="$(TOPLEVEL="$R" detect_stack)"
[ "$S" = dotnet ] \
  && ok "1i. dotnet new xunit -o MyApp.Tests (no root marker) detects as dotnet" \
  || bad "1i. the canonical one-dir-down layout should detect dotnet, got: [$S]"
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = "dotnet test MyApp.Tests/MyApp.Tests.csproj" ] \
  && ok "1i'. …and seeds its test project by path" \
  || bad "1i'. expected the one-dir-down seed, got: [$CMD]"
# the recursion is BOUNDED — a project buried deeper than the marker depth does
# not turn an unrelated repo into a dotnet repo.
R="$TMPROOT/seed-deep"; mkdir -p "$R"; mk_proj "$R/a/b/c/d/Deep.Tests" Deep.Tests
[ "$(TOPLEVEL="$R" detect_stack)" = unknown ] \
  && ok "1i''. the marker scan is depth-bounded (a deeply buried csproj is not a marker)" \
  || bad "1i''. the marker scan is unbounded: $(TOPLEVEL="$R" detect_stack)"
# …and build output far below never counts as a marker either.
R="$TMPROOT/seed-objdeep"; mkdir -p "$R/App/obj/Debug/net10.0"
mk_proj "$R/App/obj/Debug/net10.0" Ghost
[ "$(TOPLEVEL="$R" detect_stack)" = unknown ] \
  && ok "1i'''. obj/ build output is not a detection marker" \
  || bad "1i'''. obj/ output leaked into stack detection"

# N2. THE RECURSION MUST NOT EAT OTHER STACKS. A vendored C# sample or a
# `tools/` helper is a *.csproj, not a TEST SYSTEM — but the depth-3 marker scan
# counted any csproj, so a healthy js/python/rust repo flipped to
# ambiguous(js,dotnet) and LOST its working seed. The verdict even contradicted
# itself: it offered ONE candidate while insisting it would not choose between
# them. A recursive marker now counts ONLY when it is an actual test project
# (Microsoft.NET.Test.Sdk ref, or the *Tests*.csproj convention).
mk_vendor() { # dir  — a plain (NON-test) csproj: no Test.Sdk, no Tests name
  mkdir -p "$1"
  { echo '<Project Sdk="Microsoft.NET.Sdk">'
    echo '  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>'
    echo '</Project>'
  } >"$1/$2.csproj"
}
R="$TMPROOT/vendor-js"; mkdir -p "$R"
printf '{ "scripts": { "test": "jest" } }\n' >"$R/package.json"
mk_vendor "$R/vendor/sample" Demo
S="$(TOPLEVEL="$R" detect_stack)"; CMD="$(TOPLEVEL="$R" detect_test_cmd)"
{ [ "$S" = js ] && [ "$CMD" = 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}' ]; } \
  && ok "1k. js + a vendored NON-test csproj stays js and keeps its seed" \
  || bad "1k. N2 REGRESSION: js repo became [$S] with cmd [$CMD]"
# The python fixture declares pytest, because the python arm now claims a RUNNER
# and not a marker (an EMPTY pyproject.toml is not evidence of one — see
# tests/stack-arms.test.sh section I). What this leg locks is unchanged: a
# VENDORED non-test csproj must move neither the stack nor the seed.
R="$TMPROOT/vendor-py"; mkdir -p "$R"
printf '[project]\nname = "app"\n\n[tool.pytest.ini_options]\n' >"$R/pyproject.toml"
mk_vendor "$R/tools" x
S="$(TOPLEVEL="$R" detect_stack)"; CMD="$(TOPLEVEL="$R" detect_test_cmd)"
{ [ "$S" = python ] && [ "$CMD" = 'pytest "${LCARS_TESTS_DIR:-.}"' ]; } \
  && ok "1k'. python + tools/x.csproj stays python and keeps its seed" \
  || bad "1k'. N2 REGRESSION: python repo became [$S] with cmd [$CMD]"
R="$TMPROOT/vendor-rs"; mkdir -p "$R"; printf '[package]\nname="x"\n' >"$R/Cargo.toml"
mk_vendor "$R/bindings/csharp" Y
S="$(TOPLEVEL="$R" detect_stack)"; CMD="$(TOPLEVEL="$R" detect_test_cmd)"
{ [ "$S" = rust ] && [ "$CMD" = 'cargo test' ]; } \
  && ok "1k''. rust + bindings/csharp/Y.csproj stays rust and keeps its seed" \
  || bad "1k''. N2 REGRESSION: rust repo became [$S] with cmd [$CMD]"
# a nested REAL test project is still a marker (D5 must not regress)…
R="$TMPROOT/vendor-real"; mkdir -p "$R"; mk_proj "$R/MyApp.Tests" MyApp.Tests
[ "$(TOPLEVEL="$R" detect_stack)" = dotnet ] \
  && ok "1k'''. a nested REAL test project is still a dotnet marker (D5 holds)" \
  || bad "1k'''. D5 regressed: nested test project no longer detected"
# …and a js repo that genuinely also carries a C# TEST project is honestly
# ambiguous — the rule narrows to test systems, it does not switch off.
R="$TMPROOT/vendor-both"; mkdir -p "$R"
printf '{ "scripts": { "test": "jest" } }\n' >"$R/package.json"
mk_proj "$R/dotnet/App.Tests" App.Tests
case "$(TOPLEVEL="$R" detect_stack)" in
  ambiguous*dotnet*) ok "1k''''. js + a REAL nested C# test project IS ambiguous (honest)" ;;
  *) bad "1k''''. a real nested test project should still count: [$(TOPLEVEL="$R" detect_stack)]" ;;
esac
# a TOP-LEVEL csproj keeps its pre-147 meaning: a marker regardless of content.
R="$TMPROOT/vendor-top"; mkdir -p "$R"; mk_vendor "$R" App
[ "$(TOPLEVEL="$R" detect_stack)" = dotnet ] \
  && ok "1k'''''. a TOP-LEVEL non-test csproj is still a marker (pre-147 rule kept)" \
  || bad "1k'''''. top-level marker behaviour drifted"

# D7 REGRESSION. Pre-S147 a repo with `App.csproj` + a Makefile `test:` target
# seeded `make test` (dotnet had no arm at all). The new arm early-returned on
# the mere PRESENCE of a dotnet marker, so it seeded NOTHING — silently taking
# a working repo's test command away. The dotnet path may only be taken when a
# dotnet TEST PROJECT was actually found; otherwise the pre-existing generic
# fallbacks must still run.
R="$TMPROOT/seed-mk"; mkdir -p "$R"; mk_proj "$R" App 0
# S299 FIXTURE ONLY — the stand-in recipe now invokes a real program.
# This leg has never been about the recipe's CONTENTS; it needed a `make test`
# that exits deterministically without a runner installed, and `@echo` was the
# cheapest way to get one. The inert filter refuses a recipe that is only shell
# no-ops, so the stand-in runs the same thing THROUGH a shell — `sh` is a real
# command, the exit status and the output are identical, and what this leg
# locks is unchanged.
printf 'test:\n\t@sh -c "echo ok"\n' >"$R/Makefile"
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = "make test" ] \
  && ok "1j. csproj + Makefile 'test:' still seeds 'make test' (pre-147 behaviour)" \
  || bad "1j. D7 REGRESSION: the dotnet arm swallowed the Makefile fallback, got: [$CMD]"
R="$TMPROOT/seed-runsh"; mkdir -p "$R/tests"; mk_proj "$R" App 0
# S299 FIXTURE ONLY — the runner now has a BODY. This leg is about ARM
# PRECEDENCE (the dotnet arm must not swallow the generic bash-runner fallback)
# and the file's contents were incidental; it used to be a lone shebang. The
# inert filter refuses a tests/run.sh that holds no command at all, so a
# shebang-only file no longer stands in for "a runner exists" — one real line
# does, and the precedence this leg locks is unchanged.
printf '#!/usr/bin/env bash\nbash tests/suite.sh\n' >"$R/tests/run.sh"
CMD="$(TOPLEVEL="$R" detect_test_cmd)"
[ "$CMD" = 'bash tests/run.sh "${LCARS_TESTS_DIR:-tests}"' ] \
  && ok "1j'. csproj + tests/run.sh still seeds the bash-runner fallback" \
  || bad "1j'. the dotnet arm swallowed the tests/run.sh fallback, got: [$CMD]"

# ============================================================================
# 2. NO PRE-147 DRIFT — every other stack's seed is byte-identical
#    (S148 quoted the $LCARS_TESTS_DIR scope in the js/python seeds; the
#     invocations are otherwise unchanged, and the natives are untouched)
# ============================================================================
R="$TMPROOT/drift-js"; mkdir -p "$R"
printf '{ "scripts": { "test": "jest" } }\n' >"$R/package.json"
[ "$(TOPLEVEL="$R" detect_test_cmd)" = 'npm test -- ${LCARS_TESTS_DIR:+"${LCARS_TESTS_DIR}"}' ] \
  && ok "2a. js seed unchanged" || bad "2a. js seed DRIFTED"
R="$TMPROOT/drift-py"; mkdir -p "$R"
printf '[project]\nname = "app"\n\n[tool.pytest.ini_options]\n' >"$R/pyproject.toml"
[ "$(TOPLEVEL="$R" detect_test_cmd)" = 'pytest "${LCARS_TESTS_DIR:-.}"' ] \
  && ok "2b. python seed unchanged" || bad "2b. python seed DRIFTED"
# …and the marker-only shape this fixture USED to be: a pyproject that declares
# no runner at all no longer seeds an uninstallable `pytest` (the rule itself,
# with both halves of its control, lives in tests/stack-arms.test.sh section I).
R="$TMPROOT/drift-py-bare"; mkdir -p "$R"; : >"$R/pyproject.toml"
[ -z "$(TOPLEVEL="$R" detect_test_cmd)" ] \
  && ok "2b'. …and a pyproject with NO runner evidence claims nothing" \
  || bad "2b'. a bare pyproject still invented a runner: [$(TOPLEVEL="$R" detect_test_cmd)]"
R="$TMPROOT/drift-rs"; mkdir -p "$R"; : >"$R/Cargo.toml"
[ "$(TOPLEVEL="$R" detect_test_cmd)" = 'cargo test' ] \
  && ok "2c. rust seed unchanged" || bad "2c. rust seed DRIFTED"
R="$TMPROOT/drift-go"; mkdir -p "$R"; : >"$R/go.mod"
[ "$(TOPLEVEL="$R" detect_test_cmd)" = 'go test ./...' ] \
  && ok "2d. go seed unchanged" || bad "2d. go seed DRIFTED"
R="$TMPROOT/drift-rb"; mkdir -p "$R/spec"; : >"$R/Gemfile"
[ "$(TOPLEVEL="$R" detect_test_cmd)" = 'bundle exec rspec' ] \
  && ok "2e. ruby seed unchanged" || bad "2e. ruby seed DRIFTED"
# a jvm repo must STILL seed nothing (deliberately ledgered, not implemented)
R="$TMPROOT/drift-jvm"; mkdir -p "$R"; : >"$R/pom.xml"
[ -z "$(TOPLEVEL="$R" detect_test_cmd)" ] \
  && ok "2f. jvm still seeds nothing (S147 ledgers it, does not implement it)" \
  || bad "2f. jvm unexpectedly seeded a command"

# ============================================================================
# 3. THE NATIVE-ISOLATION SEAMS (no SDK needed)
# ============================================================================
( export LCARS_STACK=dotnet; stack_is_native ) \
  && ok "3a. resolve_stack=dotnet ⇒ stack_is_native (own case, not a widened rust|go)" \
  || bad "3a. dotnet should be a native-isolation stack"
for s in rust go ruby; do
  ( export LCARS_STACK=$s; stack_is_native ) \
    || bad "3a'. $s must STILL be native (pre-147 semantics)"
done
for s in js python jvm unknown; do
  ( export LCARS_STACK=$s; stack_is_native ) \
    && bad "3a''. $s must NOT be native (pre-147 semantics)"
done
ok "3a'. rust/go/ruby still native; js/python/jvm/unknown still generic"
# S3: `native_runner_bin` had NO production caller in run.sh — it was dead code
# kept alive only by this suite's own assertion. It is gone; the guard here is
# that it stays gone rather than being re-added with ceremonial coverage.
grep -q '^native_runner_bin()' "$SCRIPT" \
  && bad "3b. native_runner_bin is back in run.sh with no caller (dead code)" \
  || ok "3b. no dead native_runner_bin helper in run.sh"

# 3c/3d: the FQN reader — file-scoped AND braced namespaces, no namespace at all.
#
# EVERY fixture below is written with a leading UTF-8 BOM (EF BB BF), because
# THAT IS WHAT `dotnet new xunit` ACTUALLY WRITES (verified with `xxd` against
# SDK 10.0.107: both UnitTest1.cs and the .csproj start `efbb bf`). Idealised
# BOM-less heredocs made this suite pass while the shipped reader silently
# dropped the namespace on every real template file — the filter then collapsed
# to a bare class name, which is a CONTAINS match, so an unrelated same-named
# class rode along and the gate could pass on a staged file with no tests in it.
# `bom` prefixes the first line of each fixture so the suite fails if the reader
# ever regresses to a `^`-anchored scan.
W="$TMPROOT/fqn"; mkdir -p "$W"
bom="$(printf '\357\273\277')"
mkcs() { # file  (body on stdin) — writes it BOM-first, exactly like the template
  local f="$1"; { printf '%s' "$bom"; cat; } >"$f"
}
mkcs "$W/a.cs" <<'CS'
namespace MyApp.Tests.Staged;
public class AlphaCases
{
    [Fact] public void One() { }
}
public sealed class BetaCases { [Fact] public void Two() { } }
CS
head -c 3 "$W/a.cs" | cmp -s - <(printf '%s' "$bom") \
  && ok "3c0. the fixture really carries the template's UTF-8 BOM" \
  || bad "3c0. fixture is missing the BOM — the test would not catch the defect"
GOT="$(native_dotnet_test_fqns "$W/a.cs" | tr '\n' ' ')"
[ "$GOT" = "MyApp.Tests.Staged.AlphaCases MyApp.Tests.Staged.BetaCases " ] \
  && ok "3c. file-scoped namespace (BOM-prefixed) ⇒ fully-qualified class names" \
  || bad "3c. expected two namespaced FQNs, got: [$GOT]"
mkcs "$W/b.cs" <<'CS'
namespace Legacy.Braced
{
    public class GammaCases { [Fact] public void Three() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/b.cs" | tr '\n' ' ')"
[ "$GOT" = "Legacy.Braced.GammaCases " ] \
  && ok "3d. braced namespace ⇒ fully-qualified class name" \
  || bad "3d. expected Legacy.Braced.GammaCases, got: [$GOT]"
mkcs "$W/c.cs" <<'CS'
public class RootCases { [Fact] public void Four() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/c.cs" | tr '\n' ' ')"
[ "$GOT" = "RootCases " ] \
  && ok "3e. no namespace ⇒ the bare class name (observed VSTest FQN shape)" \
  || bad "3e. expected RootCases, got: [$GOT]"
: >"$W/d.cs"
[ -z "$(native_dotnet_test_fqns "$W/d.cs")" ] \
  && ok "3f. a .cs declaring NO class ⇒ no FQN (no runnable target)" \
  || bad "3f. an empty .cs should yield no FQN"
# CRLF: a file authored on Windows must read exactly like the LF one.
printf '%snamespace MyApp.Tests.Staged;\r\npublic class CrlfCases\r\n{\r\n    [Fact] public void C() { }\r\n}\r\n' \
  "$bom" >"$W/crlf.cs"
GOT="$(native_dotnet_test_fqns "$W/crlf.cs" | tr '\n' ' ')"
[ "$GOT" = "MyApp.Tests.Staged.CrlfCases " ] \
  && ok "3f'. CRLF line endings do not corrupt the namespace or class name" \
  || bad "3f'. CRLF file mis-read, got: [$GOT]"

# D4: a file declaring TWO namespaces — each class must be qualified by the
# namespace ACTUALLY enclosing it. Taking only the FIRST namespace silently
# mis-named every class under the second, so its staged (failing) test was
# never selected by the filter and the gate passed on an unproven test.
mkcs "$W/two-ns.cs" <<'CS'
namespace First.Space
{
    public class OneCases { [Fact] public void A() { } }
}

namespace Second.Space
{
    public class TwoCases { [Fact] public void B() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/two-ns.cs" | tr '\n' ' ')"
[ "$GOT" = "First.Space.OneCases Second.Space.TwoCases " ] \
  && ok "3f''. TWO namespaces in one file ⇒ each class keeps its OWN namespace" \
  || bad "3f''. expected First.Space.OneCases Second.Space.TwoCases, got: [$GOT]"
# …including NESTED braced namespaces, and a class declared after they close.
mkcs "$W/nested-ns.cs" <<'CS'
namespace Outer
{
    namespace Inner
    {
        public class DeepCases { [Fact] public void D() { } }
    }
}
namespace Tail.Space
{
    public class TailCases { [Fact] public void T() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/nested-ns.cs" | tr '\n' ' ')"
[ "$GOT" = "Outer.Inner.DeepCases Tail.Space.TailCases " ] \
  && ok "3f'''. nested braced namespaces close correctly (no prefix bleed)" \
  || bad "3f'''. expected Outer.Inner.DeepCases Tail.Space.TailCases, got: [$GOT]"

# N1: TWO CLASSES ON ONE LINE. A scanner that matches the `class` keyword ONCE
# per line drops the second declaration entirely — it never reaches the filter,
# never runs, and is still recorded proven in flip-flop.json. That is D4's
# outcome surviving through a different trigger, so it gets the same treatment:
# the line is SCANNED, not pattern-matched once.
mkcs "$W/one-line.cs" <<'CS'
namespace App.Tests.OneLine;
public class AlphaCases { [Fact] public void X() { } } public class BetaCases { [Fact] public void Y() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/one-line.cs" | tr '\n' ' ')"
[ "$GOT" = "App.Tests.OneLine.AlphaCases App.Tests.OneLine.BetaCases " ] \
  && ok "3f4. TWO classes on ONE line ⇒ BOTH are emitted (neither silently dropped)" \
  || bad "3f4. expected both one-line classes, got: [$GOT]"
# …and two classes under two DIFFERENT namespaces, all on one line: the scanner
# has to interleave namespace opens/closes with class declarations, not bail out
# of the line the moment it sees the `namespace` keyword.
mkcs "$W/one-line-ns.cs" <<'CS'
namespace A.One { public class OneCases { [Fact] public void O() { } } } namespace B.Two { public class TwoCases { [Fact] public void T() { } } }
CS
GOT="$(native_dotnet_test_fqns "$W/one-line-ns.cs" | tr '\n' ' ')"
[ "$GOT" = "A.One.OneCases B.Two.TwoCases " ] \
  && ok "3f5. TWO namespaces AND two classes on one line ⇒ each correctly qualified" \
  || bad "3f5. expected A.One.OneCases B.Two.TwoCases, got: [$GOT]"

# Smell 1: a '}' CHAR LITERAL must not desync brace depth. The failure shape is
# an UNQUALIFIED term for the next class — precisely the bare contains-match D2
# closed, so no path may emit one even when today's gate still fails correctly.
mkcs "$W/char-brace.cs" <<'CS'
namespace C.Braced
{
    public class CharCases { [Fact] public void C() { var c = '}'; } }
    public class NextCases { [Fact] public void N() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/char-brace.cs" | tr '\n' ' ')"
[ "$GOT" = "C.Braced.CharCases C.Braced.NextCases " ] \
  && ok "3f6. a '}' char literal does not desync brace depth (no bare term)" \
  || bad "3f6. char literal desynced the scanner, got: [$GOT]"
printf '%s' "$GOT" | grep -qE '(^| )[A-Za-z_][A-Za-z0-9_]*( |$)' \
  && bad "3f6'. an UNQUALIFIED term was emitted — the D2 collision shape is back" \
  || ok "3f6'. every emitted term is namespace-qualified"
# a '{' char literal is the mirror hazard.
mkcs "$W/char-brace2.cs" <<'CS'
namespace C.Braced2
{
    public class OpenCases { [Fact] public void O() { var c = '{'; } }
    public class AfterCases { [Fact] public void A() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/char-brace2.cs" | tr '\n' ' ')"
[ "$GOT" = "C.Braced2.OpenCases C.Braced2.AfterCases " ] \
  && ok "3f6''. a '{' char literal does not desync it either" \
  || bad "3f6''. got: [$GOT]"
# …and a brace inside a STRING literal.
mkcs "$W/str-brace.cs" <<'CS'
namespace C.Str
{
    public class StrCases { [Fact] public void S() { var s = "a } b { c"; } }
    public class TailCases { [Fact] public void T() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/str-brace.cs" | tr '\n' ' ')"
[ "$GOT" = "C.Str.StrCases C.Str.TailCases " ] \
  && ok "3f6'''. braces inside a STRING literal are ignored too" \
  || bad "3f6'''. string-literal braces desynced the scanner, got: [$GOT]"

# Smell 2: BLOCK COMMENTS must be stripped, or a file of commented-out classes
# dodges the "declares no test class" INCONCLUSIVE by emitting phantom targets.
mkcs "$W/blockcomment.cs" <<'CS'
namespace Real;
/* namespace Fake { public class FakeCases { } */
public class RealCases { [Fact] public void R() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/blockcomment.cs" | tr '\n' ' ')"
[ "$GOT" = "Real.RealCases " ] \
  && ok "3f7. a single-line /* … */ comment hides the class inside it" \
  || bad "3f7. expected only Real.RealCases, got: [$GOT]"
mkcs "$W/blockcomment-multi.cs" <<'CS'
namespace Real2;
/*
public class GhostOne { [Fact] public void G() { } }
public class GhostTwo { }
*/
public class LiveCases { [Fact] public void L() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/blockcomment-multi.cs" | tr '\n' ' ')"
[ "$GOT" = "Real2.LiveCases " ] \
  && ok "3f7'. a MULTI-LINE block comment hides every class inside it" \
  || bad "3f7'. expected only Real2.LiveCases, got: [$GOT]"
# a file that is ENTIRELY commented-out classes declares NO test class, so the
# leg must read INCONCLUSIVE rather than construct a phantom filter.
mkcs "$W/all-commented.cs" <<'CS'
namespace Ghost;
/*
public class AllGhosts { [Fact] public void G() { } }
*/
CS
[ -z "$(native_dotnet_test_fqns "$W/all-commented.cs")" ] \
  && ok "3f7''. an all-commented-out file yields NO target (⇒ INCONCLUSIVE)" \
  || bad "3f7''. commented-out classes produced a phantom target"
# …while a `//`-commented class is hidden too, and a URL in a string is not a
# comment (the scanner must not treat the `//` in "http://…" as one).
mkcs "$W/line-comment.cs" <<'CS'
namespace Line;
// public class HiddenCases { }
public class UrlCases { [Fact] public void U() { var s = "http://example.com/x"; } }
public class AfterUrlCases { [Fact] public void A() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/line-comment.cs" | tr '\n' ' ')"
[ "$GOT" = "Line.UrlCases Line.AfterUrlCases " ] \
  && ok "3f7'''. // comments hide a class; a // inside a string does not" \
  || bad "3f7'''. expected Line.UrlCases Line.AfterUrlCases, got: [$GOT]"

# N3: `record` and `struct` test classes. The scanner only knew the literal
# `class` keyword, so an xUnit record test class was DROPPED from the filter —
# never run, still recorded proven. The SDK's own discovery confirms these are
# real tests (`RS.RecordCases.RecordRan` is listed by `--list-tests`).
mkcs "$W/shapes.cs" <<'CS'
namespace RS;
public record RecordCases { [Fact] public void R() { } }
public struct StructCases { [Fact] public void S() { } }
public record class RecClassCases { [Fact] public void RC() { } }
public record struct RecStructCases { [Fact] public void RS2() { } }
public class PlainCases { [Fact] public void P() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/shapes.cs" | tr '\n' ' ')"
[ "$GOT" = "RS.RecordCases RS.StructCases RS.RecClassCases RS.RecStructCases RS.PlainCases " ] \
  && ok "3f8. record / struct / record class / record struct all declare targets" \
  || bad "3f8. a non-`class` type declaration was dropped, got: [$GOT]"

# N4: MULTI-LINE STRING STATE. A verbatim (@") or raw (\"\"\") string body was
# scanned as CODE, so a net-negative brace run inside one popped the namespace
# depth and the NEXT class came out BARE — an unqualified contains-term, which
# is the ride-along shape D2 closed. Multi-line verbatim strings holding JSON or
# SQL fixtures are routine in C# tests.
mkcs "$W/verbatim.cs" <<'CS'
namespace App.Tests.Raw
{
    public class RawCases
    {
        const string J = @"
closing braces in data: } } }
";
    }
    public class VictimCases { [Fact] public void V() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/verbatim.cs" | tr '\n' ' ')"
[ "$GOT" = "App.Tests.Raw.RawCases App.Tests.Raw.VictimCases " ] \
  && ok "3f9. a multi-line VERBATIM string does not desync the namespace" \
  || bad "3f9. verbatim string desynced the scanner, got: [$GOT]"
mkcs "$W/raw.cs" <<'CS'
namespace App.Tests.Raw2
{
    public class RawCases2
    {
        const string J = """
raw } } } data
""";
    }
    public class Victim2 { [Fact] public void V() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/raw.cs" | tr '\n' ' ')"
[ "$GOT" = "App.Tests.Raw2.RawCases2 App.Tests.Raw2.Victim2 " ] \
  && ok "3f9'. a multi-line RAW (\"\"\") string does not desync the namespace" \
  || bad "3f9'. raw string desynced the scanner, got: [$GOT]"
# a `""` inside a verbatim string is an ESCAPED quote, not the terminator.
mkcs "$W/verbatim-esc.cs" <<'CS'
namespace App.Tests.Esc
{
    public class EscCases
    {
        const string J = @"he said ""} } }"" and more
still inside } }
";
    }
    public class EscVictim { [Fact] public void V() { } }
}
CS
GOT="$(native_dotnet_test_fqns "$W/verbatim-esc.cs" | tr '\n' ' ')"
[ "$GOT" = "App.Tests.Esc.EscCases App.Tests.Esc.EscVictim " ] \
  && ok "3f9''. a doubled \"\" inside a verbatim string is an escape, not the end" \
  || bad "3f9''. got: [$GOT]"

# GUARD 1 (Part B): NEVER emit an unqualified filter term. Dropping a class is a
# SILENT GREEN; emitting a bogus extra term is only a zero-collect. So whenever
# the scan cannot fully qualify a declared type, the leg must be INCONCLUSIVE —
# the failure direction is always inconclusive, never pass.
mkcs "$W/bare.cs" <<'CS'
public class NoNamespaceCases { [Fact] public void N() { } }
CS
mk_proj "$TMPROOT/guard1/tests/G.Tests" G.Tests
cp "$W/bare.cs" "$TMPROOT/guard1/tests/G.Tests/Lcarsq_bare.cs"
CMD="$(printf 'tests/G.Tests/Lcarsq_bare.cs\n' | REPO_ROOT="$TMPROOT/guard1" native_scoped_cmd dotnet)"
[ -z "$CMD" ] \
  && ok "3f10. an UNQUALIFIED class yields NO command (⇒ INCONCLUSIVE, never a bare ~term)" \
  || bad "3f10. a bare contains-term was emitted: [$CMD]"
MSG="$(native_no_target_reason dotnet "$TMPROOT/guard1" tests/G.Tests/Lcarsq_bare.cs)"
case "$MSG" in
  *namespace*) ok "3f10'. …and the reason names the missing namespace" ;;
  *) bad "3f10'. the guard-1 reason should name the namespace: [$MSG]" ;;
esac

# R1 — GUARD 1's principle extended to the shapes the harness KNOWS it cannot
# name. GUARD 2's floor is an AGGREGATE inequality, and a [Theory] contributes 1
# to the floor but N to the observed count; that N-1 slack is a budget a dropped
# class can hide in, and the correlation is worse than it looks because the SAME
# scanner produces both numbers. A generic type (VSTest renders `Ns.C`1`) and a
# type nested in another type (`Ns.Outer+Inner`) are shapes we already know the
# filter cannot select, so they are REFUSED at command-build time rather than
# emitted-and-hoped-for. GUARD 2 stays as the backstop for unknown-unknowns.
mkcs "$W/unnameable.cs" <<'CS'
namespace UN;
public class GenCases<T> { [Fact] public void G() { } }
public class Outer
{
    public class InnerCases { [Fact] public void I() { } }
}
public class PlainCases { [Fact] public void P() { } }
CS
GOT="$(native_dotnet_unnameable "$W/unnameable.cs" | tr '\n' ' ')"
case "$GOT" in
  *"UN.GenCases"*) ok "3f13. a GENERIC type declaring tests is reported unnameable" ;;
  *) bad "3f13. generic type not reported unnameable: [$GOT]" ;;
esac
case "$GOT" in
  *"InnerCases"*) ok "3f13'. a type NESTED in another type declaring tests is unnameable" ;;
  *) bad "3f13'. nested type not reported unnameable: [$GOT]" ;;
esac
case "$GOT" in
  *PlainCases*) bad "3f13''. a plain nameable class was wrongly reported unnameable" ;;
  *) ok "3f13''. a plain class is NOT reported unnameable" ;;
esac
GOT="$(native_dotnet_test_fqns "$W/unnameable.cs" | tr '\n' ' ')"
case "$GOT" in
  *GenCases*|*InnerCases*) bad "3f13'''. an unnameable type leaked into the filter terms: [$GOT]" ;;
  *) ok "3f13'''. unnameable types are kept OUT of the filter terms" ;;
esac
# NO FALSE-FIRE: nested and generic HELPER types that declare no tests are
# routine in C# test files (fixtures, builders, data holders) and must not
# park a perfectly good ticket.
mkcs "$W/helpers.cs" <<'CS'
namespace HP;
public class MyCases
{
    [Fact] public void T() { }
    private class Helper { public int X; }
    private sealed class Builder<T> { public T V; }
}
CS
[ -z "$(native_dotnet_unnameable "$W/helpers.cs")" ] \
  && ok "3f14. nested/generic HELPER types with NO tests never trigger a refusal" \
  || bad "3f14. false refusal on helper types: [$(native_dotnet_unnameable "$W/helpers.cs" | tr '\n' ' ')]"
[ "$(native_dotnet_test_fqns "$W/helpers.cs" | tr '\n' ' ')" = "HP.MyCases " ] \
  && ok "3f14'. …and the real test class still yields its filter term" \
  || bad "3f14'. expected HP.MyCases, got: [$(native_dotnet_test_fqns "$W/helpers.cs" | tr '\n' ' ')]"
# the command builder REFUSES rather than partially running…
mk_proj "$TMPROOT/unname/tests/U.Tests" U.Tests
cp "$W/unnameable.cs" "$TMPROOT/unname/tests/U.Tests/Lcarsq_un.cs"
CMD="$(printf 'tests/U.Tests/Lcarsq_un.cs\n' | REPO_ROOT="$TMPROOT/unname" native_scoped_cmd dotnet)"
[ -z "$CMD" ] \
  && ok "3f15. a staged file with an unnameable TEST type ⇒ NO command (INCONCLUSIVE)" \
  || bad "3f15. the harness ran a partial selection: [$CMD]"
MSG="$(native_no_target_reason dotnet "$TMPROOT/unname" tests/U.Tests/Lcarsq_un.cs)"
case "$MSG" in
  *GenCases*|*InnerCases*) ok "3f15'. …and the reason NAMES the type it cannot select" ;;
  *) bad "3f15'. the refusal reason should name the type: [$MSG]" ;;
esac

# D1 — the COMPOSITION bug between the R1 carve-out and the R2 #if handling.
# The carve-out only reports a bad-shape type that DECLARED tests, and the R2 fix
# stopped counting attributes inside `#if`. Compose the two and a bad-shape type
# whose every attribute is #if-guarded looks TEST-FREE: not refused (the
# carve-out sees nothing), not emitted (it is unnameable), and not counted (the
# floor is pp-aware) — invisible to BOTH guards, while the SDK really does
# discover it (`dotnet test` defaults to Debug, so DEBUG is defined). A test class
# wholly guarded by `#if NET8_0` / `#if !NETFRAMEWORK` is ordinary in a
# multi-targeted C# test project.
#
# The cure keeps both properties: a SECOND counter that ignores `pp` drives the
# carve-out's "did this declare tests?" question, while the pp-aware counter
# stays GUARD 2's floor.
mkcs "$W/nested-if.cs" <<'CS'
namespace App.Tests.NestIf;
public class Outer {
    public class InnerCases {
#if DEBUG
        [Fact] public void MustFail() { }
#endif
    }
}
public class NormalCases { [Fact] public void Ok() { } }
CS
case "$(native_dotnet_unnameable "$W/nested-if.cs" | tr '\n' ' ')" in
  *InnerCases*) ok "3f18. a NESTED type whose only [Fact] is #if-guarded is still refused" ;;
  *) bad "3f18. INVISIBLE: nested type with only #if-guarded tests was not refused" ;;
esac
mkcs "$W/generic-if.cs" <<'CS'
namespace G.If;
public class GenCases<T> {
#if DEBUG
    [Fact] public void MustFail() { }
#endif
}
public class NormalCases { [Fact] public void Ok() { } }
CS
case "$(native_dotnet_unnameable "$W/generic-if.cs" | tr '\n' ' ')" in
  *GenCases*) ok "3f18'. …and so is the GENERIC variant" ;;
  *) bad "3f18'. INVISIBLE: generic type with only #if-guarded tests was not refused" ;;
esac
# R2 MUST SURVIVE: the pp-aware floor still excludes #if-guarded attributes, so
# the D1 cure does not trade itself back for the false-park it replaced.
[ "$(native_dotnet_declared_tests "$W/nested-if.cs")" = 1 ] \
  && ok "3f18''. GUARD 2's floor still under-counts #if (R2 preserved)" \
  || bad "3f18''. the D1 cure inflated the floor, reintroducing R2: [$(native_dotnet_declared_tests "$W/nested-if.cs")]"
# a bad type whose CLOSING BRACE lands inside an open #if must still report.
mkcs "$W/nested-if-openclose.cs" <<'CS'
namespace App.Tests.OpenIf;
public class Outer {
    public class InnerCases {
        [Fact] public void MustFail() { }
#if DEBUG
    }
}
#endif
public class NormalCases { [Fact] public void Ok() { } }
CS
case "$(native_dotnet_unnameable "$W/nested-if-openclose.cs" | tr '\n' ' ')" in
  *InnerCases*) ok "3f18'''. a bad type closing INSIDE an open #if still reports" ;;
  *) bad "3f18'''. the scope-close report was suppressed by an open #if" ;;
esac
# THE CARVE-OUT MUST SURVIVE (do not trade D1 back for R2): a pure helper type
# still triggers nothing — including one whose body is entirely #if-guarded.
mkcs "$W/helpers-if.cs" <<'CS'
namespace HP2;
public class MyCases
{
    [Fact] public void T() { }
    private class Helper {
#if DEBUG
        public int X;
#endif
    }
    private sealed class Builder<T> { public T V; }
}
CS
[ -z "$(native_dotnet_unnameable "$W/helpers-if.cs")" ] \
  && ok "3f19. pure helper types (even wholly #if-guarded) STILL never refuse" \
  || bad "3f19. the D1 cure broke the helper carve-out: [$(native_dotnet_unnameable "$W/helpers-if.cs" | tr '\n' ' ')]"
[ "$(native_dotnet_test_fqns "$W/helpers-if.cs" | tr '\n' ' ')" = "HP2.MyCases " ] \
  && ok "3f19'. …and the real test class still yields its filter term" \
  || bad "3f19'. got: [$(native_dotnet_test_fqns "$W/helpers-if.cs" | tr '\n' ' ')]"
# one VISIBLE [Fact] alongside #if-guarded ones still reports (regression lock).
mkcs "$W/nested-mixed.cs" <<'CS'
namespace MX;
public class Outer {
    public class InnerCases {
        [Fact] public void Visible() { }
#if DEBUG
        [Fact] public void Guarded() { }
#endif
    }
}
CS
case "$(native_dotnet_unnameable "$W/nested-mixed.cs" | tr '\n' ' ')" in
  *InnerCases*) ok "3f19''. one VISIBLE [Fact] alongside #if-guarded ones still reports" ;;
  *) bad "3f19''. the mixed case stopped reporting" ;;
esac

# R2 — a [Fact] inside a DISABLED #if block must not inflate GUARD 2's floor.
# `#if NET8_0` / `#if DEBUG` / `#if WINDOWS` around a test is routine C#, and the
# consequence of over-counting is not cosmetic: a correct ticket bounces to a
# fresh worker up to three times and then parks awaiting-human.
mkcs "$W/pp.cs" <<'CS'
namespace PP;
public class PPCases
{
#if NEVER_DEFINED
    [Fact] public void Disabled() { }
#endif
    [Fact] public void Enabled() { }
}
CS
N="$(native_dotnet_declared_tests "$W/pp.cs")"
[ "$N" = 1 ] \
  && ok "3f16. a [Fact] inside #if does NOT inflate the declared floor" \
  || bad "3f16. expected 1 declared test outside #if, got: [$N]"
# …and a class declared inside #if is not emitted into the filter either.
mkcs "$W/pp-class.cs" <<'CS'
namespace PP2;
#if NEVER_DEFINED
public class GhostCases { [Fact] public void G() { } }
#endif
public class LiveCases { [Fact] public void L() { } }
CS
[ "$(native_dotnet_test_fqns "$W/pp-class.cs" | tr '\n' ' ')" = "PP2.LiveCases " ] \
  && ok "3f16'. a class declared inside #if is not emitted into the filter" \
  || bad "3f16'. got: [$(native_dotnet_test_fqns "$W/pp-class.cs" | tr '\n' ' ')]"
[ "$(native_dotnet_declared_tests "$W/pp-class.cs")" = 1 ] \
  && ok "3f16''. …and its attributes are not counted either" \
  || bad "3f16''. #if-disabled attributes still counted"

# A generic constraint is not a type declaration: `where T : class` must not be
# read as declaring a type called `where`. (Round 3 claimed this was already
# fixed; it was not — the SECOND `where` was emitted as `W.where`.)
mkcs "$W/constraints.cs" <<'CS'
namespace W;
public class TwoCon<T,U> where T : class where U : new() { }
public class OneCon<T> where T : struct { [Fact] public void C() { } }
public class RealCases { [Fact] public void R() { } }
CS
GOT="$(native_dotnet_test_fqns "$W/constraints.cs" | tr '\n' ' ')"
case "$GOT" in
  *where*) bad "3f17. a `where` CONSTRAINT was read as a type declaration: [$GOT]" ;;
  *) ok "3f17. a generic constraint (where T : class/struct) declares no type" ;;
esac

# GUARD 2 (Part B): the DECLARED test count, for the executed-count cross-check.
# Sound floor established against the SDK: each [Fact] contributes EXACTLY one
# discovered test, each [Theory] contributes AT LEAST one (2x InlineData => 2;
# MemberData with 3 rows => 3; MemberData with ZERO rows => 1 failing test), so
# `collected >= facts + theories` holds and exact equality would be WRONG.
mkcs "$W/counts.cs" <<'CS'
namespace CT;
public class CountCases
{
    [Fact] public void F1() { }
    [Fact(Skip = "wip")] public void F2() { }
    [Theory] [InlineData(1)] [InlineData(2)] public void T1(int n) { }
    [Trait("k","v")] [Fact] public void F3() { }
    public void NotATest() { }
}
CS
N="$(native_dotnet_declared_tests "$W/counts.cs")"
[ "$N" = 4 ] \
  && ok "3f11. declared-test count = 3 [Fact] + 1 [Theory] = 4 (data rows not counted)" \
  || bad "3f11. expected 4 declared tests, got: [$N]"
# NUnit / MSTest attributes count the same way…
mkcs "$W/counts-nunit.cs" <<'CS'
namespace CT2;
public class NCases
{
    [Test] public void A() { }
    [TestMethod] public void B() { }
    [TestCase(1)] [TestCase(2)] public void C(int n) { }
}
CS
N="$(native_dotnet_declared_tests "$W/counts-nunit.cs")"
[ "$N" = 2 ] \
  && ok "3f11'. [Test]/[TestMethod] count; [TestCase] rows deliberately do not" \
  || bad "3f11'. expected 2, got: [$N]"
# …and a COMMENTED-OUT or stringified attribute must not inflate the floor
# (over-counting would false-fire INCONCLUSIVE on a legitimate run).
mkcs "$W/counts-comment.cs" <<'CS'
namespace CT3;
public class CCases
{
    // [Fact] public void Commented() { }
    /* [Fact] public void Blocked() { } */
    [Fact] public void Real() { var s = "[Fact] in a string"; }
}
CS
N="$(native_dotnet_declared_tests "$W/counts-comment.cs")"
[ "$N" = 1 ] \
  && ok "3f11''. commented-out and stringified attributes do not inflate the count" \
  || bad "3f11''. expected 1, got: [$N]"
# the COLLECTED side: sum every VSTest summary line (a multi-project leg emits one each).
CO="$(proof_dotnet_collected_count 'Passed!  - Failed:     0, Passed:     2, Skipped:     0, Total:     2, Duration: 5 ms - A.Tests.dll (net10.0)
Passed!  - Failed:     0, Passed:     3, Skipped:     1, Total:     4, Duration: 9 ms - B.Tests.dll (net10.0)')"
[ "$CO" = 6 ] \
  && ok "3f12. collected count sums EVERY project's summary line (2 + 4 = 6)" \
  || bad "3f12. expected 6 collected, got: [$CO]"
[ "$(proof_dotnet_collected_count 'no summary here')" = 0 ] \
  && ok "3f12'. no summary line ⇒ zero collected" \
  || bad "3f12'. expected 0 for output with no summary"

# 3g. project resolution walks UP to the nearest enclosing .csproj.
P="$TMPROOT/projwalk"; mk_proj "$P/tests/App.Tests" App.Tests
mkdir -p "$P/tests/App.Tests/Deep/Deeper"
: >"$P/tests/App.Tests/Deep/Deeper/X.cs"
GOT="$(native_dotnet_project_for "$P" tests/App.Tests/Deep/Deeper/X.cs)"
[ "$GOT" = "tests/App.Tests/App.Tests.csproj" ] \
  && ok "3g. project walk finds the ENCLOSING csproj from a nested file" \
  || bad "3g. expected tests/App.Tests/App.Tests.csproj, got: [$GOT]"
GOT="$(native_dotnet_project_for "$P" src/Loose.cs)"
[ -z "$GOT" ] \
  && ok "3h. a file outside any project resolves to NO project" \
  || bad "3h. expected empty project for an unenclosed file, got: [$GOT]"

# 3i. the scoped command: one LEG per test project, each `cd`-ed into its own
#     project dir, filters namespace-qualified AND terminated with a `.` so the
#     CONTAINS operator cannot ride along on a longer class name (see 3i').
cp "$W/a.cs" "$P/tests/App.Tests/Lcarsq_t1_alpha.cs"
CMD="$(printf 'tests/App.Tests/Lcarsq_t1_alpha.cs\n' | REPO_ROOT="$P" native_scoped_cmd dotnet)"
[ "$CMD" = '_lq=0; ( cd "tests/App.Tests" && dotnet test "App.Tests.csproj" --filter "FullyQualifiedName~MyApp.Tests.Staged.AlphaCases.|FullyQualifiedName~MyApp.Tests.Staged.BetaCases." ) || _lq=$?; exit $_lq' ] \
  && ok "3i. scoped cmd = one project leg + OR of namespace-qualified FQN prefixes" \
  || bad "3i. unexpected scoped command: [$CMD]"
case "$CMD" in
  *'FullyQualifiedName~MyApp.Tests.Staged.AlphaCases.'*)
    ok "3i'. the filter term ENDS in a dot (collision-safe under the ~ operator)" ;;
  *) bad "3i'. the filter term is not dot-terminated: [$CMD]" ;;
esac
D="$(proof_native_run_dir dotnet "$P" tests/App.Tests/Lcarsq_t1_alpha.cs)"
[ "$D" = "$P" ] \
  && ok "3j. run dir is the LEG ROOT (each leg cd's into its own project dir)" \
  || bad "3j. expected the leg root, got: [$D]"

# D3: staged files in TWO DIFFERENT test projects. Taking the project from the
# FIRST .cs while OR-ing the FQNs of ALL of them meant the SECOND project was
# never built or run — yet flip-flop.json recorded both files as proven. Both
# projects must get their own leg, and a failure in EITHER must fail the run.
Q="$TMPROOT/twoproj"; mk_proj "$Q/tests/A.Tests" A.Tests; mk_proj "$Q/tests/B.Tests" B.Tests
mkcs "$Q/tests/A.Tests/Lcarsq_a.cs" <<'CS'
namespace A.Tests.Staged;
public class ACases { [Fact] public void A1() { } }
CS
mkcs "$Q/tests/B.Tests/Lcarsq_b.cs" <<'CS'
namespace B.Tests.Staged;
public class BCases { [Fact] public void B1() { } }
CS
CMD="$(printf 'tests/A.Tests/Lcarsq_a.cs\ntests/B.Tests/Lcarsq_b.cs\n' \
        | REPO_ROOT="$Q" native_scoped_cmd dotnet)"
case "$CMD" in
  *'cd "tests/A.Tests" && dotnet test "A.Tests.csproj"'*) ALEG=1 ;; *) ALEG=0 ;;
esac
case "$CMD" in
  *'cd "tests/B.Tests" && dotnet test "B.Tests.csproj"'*) BLEG=1 ;; *) BLEG=0 ;;
esac
[ "$ALEG" = 1 ] && [ "$BLEG" = 1 ] \
  && ok "3i''. BOTH test projects get their own leg (neither is silently skipped)" \
  || bad "3i''. a staged project was never run: [$CMD]"
case "$CMD" in
  *'FullyQualifiedName~A.Tests.Staged.ACases.'*'FullyQualifiedName~B.Tests.Staged.BCases.'*)
    # each FQN must sit in the leg of ITS OWN project, never OR'd into the other
    APART="${CMD%%cd \"tests/B.Tests\"*}"
    case "$APART" in
      *'B.Tests.Staged.BCases'*) bad "3i'''. project B's FQN leaked into project A's leg" ;;
      *) ok "3i'''. each project's leg filters only ITS OWN staged classes" ;;
    esac ;;
  *) bad "3i'''. both FQNs should appear, each in its own leg: [$CMD]" ;;
esac
# the run really is per-leg: a RED in the SECOND project must fail the command.
RD="$TMPROOT/twoproj-run"; mkdir -p "$RD/one" "$RD/two"
printf '#!/bin/sh\nexit 0\n' >"$RD/one/ok.sh"; chmod +x "$RD/one/ok.sh"
FAKE="_lq=0; ( cd \"one\" && ./ok.sh ) || _lq=\$?; ( cd \"two\" && false ) || _lq=\$?; exit \$_lq"
( cd "$RD" && bash -c "$FAKE" ) >/dev/null 2>&1
[ "$?" -ne 0 ] \
  && ok "3i''''. the multi-leg command shape fails when ANY leg fails" \
  || bad "3i''''. a failing second leg did not fail the command"

# 3k. no enclosing project ⇒ EMPTY command (the caller renders INCONCLUSIVE)…
mkdir -p "$P/loose"; cp "$W/a.cs" "$P/loose/Lcarsq_t2.cs"
CMD="$(printf 'loose/Lcarsq_t2.cs\n' | REPO_ROOT="$P" native_scoped_cmd dotnet)"
[ -z "$CMD" ] && ok "3k. staged .cs outside any project ⇒ empty cmd (never a green)" \
              || bad "3k. expected empty cmd for an unenclosed file, got: [$CMD]"
# …and so does a MIXED set where only SOME staged files resolve to a project:
# running the resolvable ones would record the unresolvable one as proven.
CMD="$(printf 'tests/App.Tests/Lcarsq_t1_alpha.cs\nloose/Lcarsq_t2.cs\n' \
        | REPO_ROOT="$P" native_scoped_cmd dotnet)"
[ -z "$CMD" ] \
  && ok "3k'. a MIXED set with one unenclosed file ⇒ empty cmd (nothing half-proven)" \
  || bad "3k'. the unenclosed file was silently dropped: [$CMD]"
# …with a message that NAMES THE FIX, not a raw MSBuild trace.
MSG="$(native_no_target_reason dotnet "$P" loose/Lcarsq_t2.cs)"
case "$MSG" in
  *csproj*|*"test project"*) ok "3l. the no-project INCONCLUSIVE names the fix (test project)" ;;
  *) bad "3l. no-project message should name the fix, got: [$MSG]" ;;
esac
case "$MSG" in *MSB1003*|*"Stack Trace"*) bad "3m. message leaked a raw MSBuild trace" ;;
  *) ok "3m. the message is plain English, never a raw MSBuild/stack trace" ;; esac
# a project that IS found but declares no class gets its OWN honest reason
: >"$P/tests/App.Tests/Empty.cs"
MSG2="$(native_no_target_reason dotnet "$P" tests/App.Tests/Empty.cs)"
[ "$MSG2" != "$MSG" ] \
  && ok "3n. 'project found but no test class' has its own distinct message" \
  || bad "3n. the two dotnet no-target reasons must not blur"
# pre-147 stacks keep their EXACT reason text
for s in rust go ruby; do
  EXP="proof-gate: the ticket's $s test file(s) declare no runnable test target — the scoped invocation cannot be constructed."
  [ "$(native_no_target_reason "$s" "$P" x)" = "$EXP" ] \
    || bad "3o. $s no-target reason text DRIFTED"
done
ok "3o. rust/go/ruby no-target reason text is byte-identical to pre-147"

# 3p. dotnet test files are RECOGNISED as test paths (else the gate never fires).
for p in MyApp.Tests/UnitTest1.cs tests/App.Tests/Foo.cs src/Widget.Tests/BarTests.cs; do
  proof_is_test_path "$p" || bad "3p. '$p' should classify as a test path"
done
proof_is_test_path src/Widget.cs && bad "3p'. plain src/Widget.cs must NOT be a test path"
ok "3p. dotnet test-file conventions classify as test paths; app .cs does not"
# GENERATED build output lives under obj/ INSIDE the test project — it must never
# be mistaken for an authored test and staged into the parent leg.
for p in tests/App.Tests/obj/Debug/net10.0/App.Tests.AssemblyInfo.cs \
         tests/App.Tests/obj/Debug/net10.0/App.Tests.GlobalUsings.g.cs \
         tests/App.Tests/bin/Debug/net10.0/Whatever.cs; do
  proof_is_test_path "$p" && bad "3q. generated build output '$p' must NOT be a test path"
done
ok "3q. obj/ and bin/ generated .cs are excluded from the test-path set"

# ============================================================================
# 4. ZERO-COLLECT + CLASSIFY signatures against the SDK's OBSERVED phrasings
# ============================================================================
# (asserted on captured text here; §5 proves the SDK really emits them)
Z1='No test matches the given testcase filter `FullyQualifiedName~Lcarsq_zz` in /x/bin/Debug/net10.0/MyApp.Tests.dll'
Z2='No test is available in /x/bin/Debug/net10.0/Empty.Tests.dll. Make sure that test discoverer & executors are registered and platform & framework version settings are appropriate and try again.'
proof_zero_collected "$Z1" && ok "4a. zero-MATCH filter reads zero-collected" \
                           || bad "4a. filter-matched-nothing must read zero-collected"
proof_zero_collected "$Z2" && ok "4b. EMPTY test project reads zero-collected" \
                           || bad "4b. no-test-available must read zero-collected"
printf '%s' "$Z1" | grep -Eq "$(rg_signature zerotests)" \
  && ok "4c. the shared zerotests arm names the filter phrasing too" \
  || bad "4c. rg_signature zerotests missing the VSTest filter phrasing"
printf '%s' "$Z2" | grep -Eq "$(rg_signature zerotests)" \
  && ok "4d. the shared zerotests arm names the no-test-available phrasing" \
  || bad "4d. rg_signature zerotests missing the VSTest availability phrasing"
# A HEALTHY pass must NEVER read zero-collected (the S106 substring hazard).
GREEN='Passed!  - Failed:     0, Passed:     2, Skipped:     0, Total:     2, Duration: 14 ms - MyApp.Tests.dll (net10.0)'
proof_zero_collected "$GREEN" \
  && bad "4e. a healthy PASS was falsely flagged zero-collected" \
  || ok "4e. a healthy 'Passed! …' run is NOT zero-collected"

# --- D1: the ALL-SKIPPED silent green -------------------------------------
# VSTest DISCOVERS a `[Fact(Skip="…")]` test, so neither "No test matches the
# given testcase filter" nor "No test is available in" is printed — yet ZERO
# tests EXECUTE and the run exits **0**. OBSERVED verbatim, SDK 10.0.107:
#   Skipped! - Failed:     0, Passed:     0, Skipped:     1, Total:     1, …
# rust's `#[ignore]` equivalent (`test result: ok. 0 passed`) is already in the
# guard family, so this was a genuine dotnet-shaped hole: the flip-flop gate
# read a clean green on a leg that proved nothing.
SKIPPED='  Skipped MyApp.Tests.Skipped.AllSkipped.SkipMe [1 ms]

Skipped! - Failed:     0, Passed:     0, Skipped:     1, Total:     1, Duration: 1 ms - MyApp.Tests.dll (net10.0)'
proof_zero_collected "$SKIPPED" \
  && ok "4e1. an ALL-SKIPPED run reads zero-collected (zero tests EXECUTED)" \
  || bad "4e1. SILENT GREEN: an all-skipped VSTest run was not caught"
printf '%s' "$SKIPPED" | grep -Eq "$(rg_signature zerotests)" \
  && ok "4e2. the shared zerotests arm names the all-skipped summary too" \
  || bad "4e2. rg_signature zerotests missing the zero-executed summary"
# …and it must NOT over-fire: a run with 1 passed + 1 skipped REALLY executed a
# test and is a legitimate PASS (observed: the banner flips to `Passed!`).
MIXED='  Skipped MyApp.Tests.Mixed.MixedCases.SkipMe [1 ms]

Passed!  - Failed:     0, Passed:     1, Skipped:     1, Total:     2, Duration: 22 ms - MyApp.Tests.dll (net10.0)'
proof_zero_collected "$MIXED" \
  && bad "4e3. a mixed skip+PASS run was falsely flagged zero-collected" \
  || ok "4e3. a mixed skip+pass run is a real pass, NOT zero-collected"
# a red run (Failed: 1) is a RED, never zero-collect — it must reach the gate.
RED1='Failed!  - Failed:     1, Passed:     0, Skipped:     0, Total:     1, Duration: 16 ms - MyApp.Tests.dll (net10.0)'
proof_zero_collected "$RED1" \
  && bad "4e4. a real RED was falsely flagged zero-collected (it would be swallowed)" \
  || ok "4e4. a real red (Failed: 1) is not zero-collected"

# 4f-4h: assertion legibility across the three frameworks (real captured text).
XUNIT='  Failed MyApp.Tests.Staged.Lcarsq_red.StagedRed [4 ms]
  Error Message:
   Assert.Equal() Failure: Values differ
Expected: 1
Actual:   2
Failed!  - Failed:     1, Passed:     0, Skipped:     0, Total:     1, Duration: 13 ms - MyApp.Tests.dll (net10.0)'
NUNIT='  Failed NFailing [23 ms]
  Error Message:
     Assert.That(1, NUnit.Framework.Is.EqualTo(2))
  Expected: 2
  But was:  1
Failed!  - Failed:     1, Passed:     1, Skipped:     0, Total:     2, Duration: 25 ms - Nu.Tests.dll (net10.0)'
MSTEST='  Failed MFailing [12 ms]
  Error Message:
   Assert.AreEqual failed. Expected:<1>. Actual:<2>.
Failed!  - Failed:     1, Passed:     1, Skipped:     0, Total:     2, Duration: 40 ms - Ms.Tests.dll (net10.0)'
printf '%s' "$XUNIT" | grep -Eq "$(rg_signature assertion)" \
  && ok "4f. xUnit assertion output classifies as ASSERTION" \
  || bad "4f. xUnit assertion output failed to classify"
printf '%s' "$NUNIT" | grep -Eq "$(rg_signature assertion)" \
  && ok "4g. NUnit assertion output classifies as ASSERTION" \
  || bad "4g. NUnit assertion output failed to classify"
printf '%s' "$MSTEST" | grep -Eq "$(rg_signature assertion)" \
  && ok "4h. MSTest assertion output classifies as ASSERTION" \
  || bad "4h. MSTest assertion output failed to classify"
# and the xUnit stderr marker on its own
printf '%s' '[xUnit.net 00:00:00.11]     MyApp.Tests.Staged.Red.R [FAIL]' \
  | grep -Eq "$(rg_signature assertion)" \
  && ok "4i. the [xUnit.net …] [FAIL] diagnostic classifies as ASSERTION" \
  || bad "4i. the xUnit diagnostic line failed to classify"
# S2: xUnit prints the SAME `[xUnit.net …]` prefix for a SKIP. A fully GREEN run
# that merely skipped a test must never classify as a test FAILURE — the arm has
# to anchor on the [FAIL] form, not the prefix. (OBSERVED skip line, 10.0.107.)
GREENSKIP='[xUnit.net 00:00:00.14]     MyApp.Tests.Mixed.MixedCases.SkipMe [SKIP]
  Skipped MyApp.Tests.Mixed.MixedCases.SkipMe [1 ms]

Passed!  - Failed:     0, Passed:     1, Skipped:     1, Total:     2, Duration: 22 ms - MyApp.Tests.dll (net10.0)'
printf '%s' "$GREENSKIP" | grep -Eq "$(rg_signature assertion)" \
  && bad "4i'. a GREEN run with a [SKIP] diagnostic falsely classified as an assertion red" \
  || ok "4i'. a green run whose only xUnit diagnostic is [SKIP] is NOT an assertion red"

# 4j. ADVERSARIAL: app output QUOTING the phrases mid-line must NOT false-fire.
ADV='log.Info("banner: Assert.Equal() Failure: Values differ — demo copy");
render("Failed!  - Failed:     3, Passed: 0" + suffix);
emit("[xUnit.net 00:00:00.10]  fake [FAIL]");
puts("No test matches the given testcase filter is a scary string");
puts("No test is available in this museum exhibit");
Console.WriteLine("Assert.AreEqual failed. Expected:<1>. Actual:<2>.");
Console.WriteLine("  But was:  a quoted narrative line");'
printf '%s' "$ADV" | grep -Eq "$(rg_signature assertion)" \
  && bad "4j. quoted app output FALSELY classified as an assertion red" \
  || ok "4j. app output quoting the phrases mid-line does NOT false-fire (assertion)"
proof_zero_collected "$ADV" \
  && bad "4k. quoted app output FALSELY read as zero-collected" \
  || ok "4k. app output quoting the zero phrasings does NOT false-fire"

# 4l. the S104 dotnet COMPILE arm still matches its original fixtures.
printf '%s' '/x/BrokenTest.cs(5,45): error CS1002: ; expected [/x/MyApp.Tests.csproj]' \
  | grep -Eq "$(rg_signature compile)" \
  && ok "4l. S104 'error CS####' compile match preserved" \
  || bad "4l. the S104 dotnet compile arm DRIFTED"
printf '%s' 'Build FAILED' | grep -Eq "$(rg_signature compile)" \
  && ok "4m. S104 '^Build FAILED' compile match preserved" \
  || bad "4m. the S104 Build FAILED match DRIFTED"
# CS0246 (missing namespace) resolves through the SAME CS#### arm — no new arm.
printf '%s' "/x/MissingNs.cs(3,12): error CS0246: The type or namespace name 'Frobnicator' could not be found (are you missing a using directive or an assembly reference?) [/x/MyApp.Tests.csproj]" \
  | grep -Eq "$(rg_signature compile)" \
  && ok "4n. CS0246 missing-namespace rides the existing CS#### arm (verified, not assumed)" \
  || bad "4n. CS0246 should match the existing compile arm"

# ============================================================================
# 5. REAL SDK DRIVES — the phrasings and exit codes above, from the SDK itself
# ============================================================================
if [ "$HAVE_SDK" -ne 1 ]; then
  skip "DOTNET: no usable dotnet SDK on PATH — SKIPPING every real-SDK drive LOUDLY"
  echo
  printf 'stack-dotnet: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

FX="$TMPROOT/fx"; mkdir -p "$FX"
if ! ( cd "$FX" && dotnet new xunit -n MyApp.Tests -o . ) >"$TMPROOT/new.log" 2>&1; then
  skip "DOTNET: 'dotnet new xunit' failed — SKIPPING the real-SDK drives LOUDLY"
  sed 's/^/      /' "$TMPROOT/new.log" | tail -5
  echo
  printf 'stack-dotnet: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# Every fixture below is written BOM-FIRST, exactly as `dotnet new` writes them.
# a SIBLING test that must never ride along on a scoped leg
mkcs "$FX/SiblingTests.cs" <<'CS'
namespace MyApp.Tests.Sibling;
public class SiblingCases
{
    [Fact] public void SiblingWouldFail() { Assert.Equal(1, 2); }
}
CS
# a same-named class in ANOTHER namespace — the collision the filter must avoid
mkcs "$FX/CollideTests.cs" <<'CS'
namespace Other.Space;
public class Lcarsq_t9_case
{
    [Fact] public void CollidingWouldFail() { Assert.Equal(1, 2); }
}
CS
# a LONGER class name in the SAME namespace — `~` is a CONTAINS match, so a bare
# `~Ns.Lcarsq_t9_case` filter also selects `Lcarsq_t9_caseExtra`. OBSERVED
# riding along on SDK 10.0.107 until the filter term was dot-terminated.
mkcs "$FX/PrefixTests.cs" <<'CS'
namespace MyApp.Tests.Staged;
public class Lcarsq_t9_caseExtra
{
    [Fact] public void PrefixWouldFail() { Assert.Equal(1, 2); }
}
CS

run_scoped() { # staged-relpath(s, newline) → sets RS_RC / RS_OUT
  local rels="$1" cmd dir first
  first="$(printf '%s\n' "$rels" | grep . | head -1)"
  cmd="$(printf '%s\n' "$rels" | REPO_ROOT="$FX" native_scoped_cmd dotnet)"
  RS_CMD="$cmd"
  if [ -z "$cmd" ]; then RS_RC=97; RS_OUT=""; return 0; fi
  dir="$(proof_native_run_dir dotnet "$FX" "$first")"
  RS_OUT="$( cd "$dir" && bash -c "$cmd" 2>&1 )"; RS_RC=$?
}

# 5a. staged GREEN case runs, exits 0, and runs ONLY itself.
mkcs "$FX/Lcarsq_t9_green.cs" <<'CS'
namespace MyApp.Tests.Staged;
public class Lcarsq_t9_case
{
    [Fact] public void StagedGreen() { Assert.Equal(2, 1 + 1); }
}
CS
run_scoped Lcarsq_t9_green.cs
[ "$RS_RC" = 0 ] && ok "5a. staged GREEN case ⇒ exit 0" \
                 || bad "5a. staged green should exit 0 (rc=$RS_RC): $RS_OUT"
printf '%s' "$RS_OUT" | grep -Eq 'Passed!.*Total: *1,' \
  && ok "5b. exactly ONE test ran — siblings compiled but NOT run (isolation)" \
  || bad "5b. expected Total: 1, got: $RS_OUT"
printf '%s' "$RS_OUT" | grep -q 'SiblingWouldFail' \
  && bad "5c. the sibling test RAN — scope was not honoured" \
  || ok "5c. the sibling's failing test never ran"
printf '%s' "$RS_OUT" | grep -q 'CollidingWouldFail' \
  && bad "5d. the same-named class in ANOTHER namespace rode along (collision)" \
  || ok "5d. namespace-qualified filter excludes a same-named class elsewhere"
# D2: the SAME-namespace longer name — the CONTAINS operator's real hazard. The
# fixtures are BOM-bearing, so this also proves the namespace survived the BOM:
# with the namespace dropped the filter degrades to `~Lcarsq_t9_case`, which
# matches BOTH the collider AND the prefix class.
printf '%s' "$RS_OUT" | grep -q 'PrefixWouldFail' \
  && bad "5d'. a LONGER same-namespace class name rode along (the ~ contains match)" \
  || ok "5d'. the dot-terminated filter excludes a longer same-namespace class"
printf '%s' "$RS_CMD" | grep -q 'FullyQualifiedName~MyApp.Tests.Staged.Lcarsq_t9_case\.' \
  && ok "5d''. the filter really carries the namespace read out of a BOM file" \
  || bad "5d''. the BOM swallowed the namespace — filter was: [$RS_CMD]"
proof_zero_collected "$RS_OUT" \
  && bad "5e. a real 1-test PASS was falsely flagged zero-collected" \
  || ok "5e. a real scoped pass is NOT zero-collected"

# 5f. staged RED case ⇒ exit 1 and classifies as an assertion red.
rm -f "$FX/Lcarsq_t9_green.cs"
mkcs "$FX/Lcarsq_t9_red.cs" <<'CS'
namespace MyApp.Tests.Staged;
public class Lcarsq_t9_case
{
    [Fact] public void StagedRed() { Assert.Equal(1, 2); }
}
CS
run_scoped Lcarsq_t9_red.cs
[ "$RS_RC" = 1 ] && ok "5f. staged RED case ⇒ exit 1 (a real red/green round-trip)" \
                 || bad "5f. staged red should exit 1 (rc=$RS_RC): $RS_OUT"
printf '%s' "$RS_OUT" | grep -Eq "$(rg_signature assertion)" \
  && ok "5g. the REAL xUnit red classifies as an assertion red" \
  || bad "5g. the real xUnit red failed to classify: $RS_OUT"
proof_zero_collected "$RS_OUT" \
  && bad "5h. a real RED was falsely flagged zero-collected (a real red would be swallowed)" \
  || ok "5h. a real red is NOT zero-collected"
rm -f "$FX/Lcarsq_t9_red.cs"

# 5i. THE SILENT-GREEN TRAP: a filter matching nothing exits **0**.
OUT="$( cd "$FX" && dotnet test MyApp.Tests.csproj --filter "FullyQualifiedName~Lcarsq_nothing_at_all" 2>&1 )"; RC=$?
[ "$RC" = 0 ] && ok "5i. OBSERVED: a zero-match filter exits 0 (the silent-green trap is real)" \
              || bad "5i. expected exit 0 from a zero-match filter, got rc=$RC"
proof_zero_collected "$OUT" \
  && ok "5j. …and the guard catches it ⇒ INCONCLUSIVE, never a pass" \
  || bad "5j. SILENT GREEN: zero-match filter not caught: $OUT"

# 5k. THE SILENT-GREEN TRAP 2: an EMPTY test project exits **0**.
EP="$TMPROOT/empty"; mkdir -p "$EP"
if ( cd "$EP" && dotnet new xunit -n Empty.Tests -o . ) >>"$TMPROOT/new.log" 2>&1; then
  rm -f "$EP"/UnitTest1.cs "$EP"/Test1.cs
  OUT="$( cd "$EP" && dotnet test 2>&1 )"; RC=$?
  [ "$RC" = 0 ] && ok "5k. OBSERVED: an EMPTY test project exits 0" \
                || bad "5k. expected exit 0 from an empty project, got rc=$RC"
  proof_zero_collected "$OUT" \
    && ok "5l. …and the guard catches it ⇒ INCONCLUSIVE, never a pass" \
    || bad "5l. SILENT GREEN: empty test project not caught: $OUT"
else
  skip "5k/5l. could not scaffold the empty-project fixture"
fi

# 5m. a staged file with NO enclosing project never even runs — sentinel, not green.
mkdir -p "$FX/../loose-cs"
cat >"$TMPROOT/loose-cs.cs" <<'CS'
namespace Loose;
public class LooseCases { [Fact] public void L() { } }
CS
LR="$TMPROOT/looseroot"; mkdir -p "$LR/nowhere"
cp "$TMPROOT/loose-cs.cs" "$LR/nowhere/Lcarsq_t8.cs"
CMD="$(printf 'nowhere/Lcarsq_t8.cs\n' | REPO_ROOT="$LR" native_scoped_cmd dotnet)"
[ -z "$CMD" ] \
  && ok "5m. a test file with no .csproj above it yields NO command (never a green)" \
  || bad "5m. expected no command, got: [$CMD]"

# 5n. STAGING HYGIENE / file-absence probe (the S106 invariant): with the staged
#     file REMOVED, the very same invocation collects nothing — a DETECTABLE
#     difference that proves the runner reacted to the staging.
mkcs "$FX/Lcarsq_t7_probe.cs" <<'CS'
namespace MyApp.Tests.Probe;
public class Lcarsq_t7_probe { [Fact] public void ProbeGreen() { Assert.True(true); } }
CS
run_scoped Lcarsq_t7_probe.cs
PROBE_CMD="$RS_CMD"
[ "$RS_RC" = 0 ] || bad "5n(setup). the probe case should be green (rc=$RS_RC): $RS_OUT"
rm -f "$FX/Lcarsq_t7_probe.cs"
OUT="$( cd "$FX" && bash -c "$PROBE_CMD" 2>&1 )"; RC=$?
proof_zero_collected "$OUT" \
  && ok "5n. with the staged file removed the same invocation collects ZERO (scope proven)" \
  || bad "5n. file-absence probe did not go zero-collect (rc=$RC): $OUT"

# D1 REAL-SDK DRIVE — the all-skipped silent green, end to end through the SAME
# seam the gate uses. A staged class whose every case is `[Fact(Skip=…)]` is
# DISCOVERED (so neither "no test matches" nor "no test is available" prints),
# executes NOTHING, and exits 0. Without the zero-executed guard this is a
# clean green on a leg that proved nothing.
mkcs "$FX/Lcarsq_t6_skipped.cs" <<'CS'
namespace MyApp.Tests.Skipped;
public class Lcarsq_t6_skipped
{
    [Fact(Skip = "wip")] public void WouldFail() { Assert.Equal(1, 2); }
}
CS
run_scoped Lcarsq_t6_skipped.cs
[ "$RS_RC" = 0 ] \
  && ok "5n'. OBSERVED: an ALL-SKIPPED staged class exits 0 (the trap is real)" \
  || bad "5n'. expected exit 0 from an all-skipped run, got rc=$RS_RC: $RS_OUT"
printf '%s' "$RS_OUT" | grep -q '^Skipped! *- *Failed: *0, *Passed: *0,' \
  && ok "5n''. OBSERVED phrasing: 'Skipped! - Failed: 0, Passed: 0, …'" \
  || bad "5n''. unexpected all-skipped summary: $RS_OUT"
proof_zero_collected "$RS_OUT" \
  && ok "5n'''. …and the guard catches it ⇒ INCONCLUSIVE, never a pass" \
  || bad "5n'''. SILENT GREEN: the all-skipped run was not caught: $RS_OUT"
# a MIXED staged class (one skipped, one real pass) REALLY ran a test — pass.
rm -f "$FX/Lcarsq_t6_skipped.cs"
mkcs "$FX/Lcarsq_t6_mixed.cs" <<'CS'
namespace MyApp.Tests.Mixed;
public class Lcarsq_t6_mixed
{
    [Fact(Skip = "wip")] public void Skipped() { }
    [Fact] public void Really() { Assert.True(true); }
}
CS
run_scoped Lcarsq_t6_mixed.cs
[ "$RS_RC" = 0 ] || bad "5n''''(setup). the mixed case should exit 0: $RS_OUT"
proof_zero_collected "$RS_OUT" \
  && bad "5n''''. a REAL 1-passed/1-skipped run was falsely flagged zero-collected" \
  || ok "5n''''. a mixed skip+pass run stays a legitimate PASS (guard does not over-fire)"
rm -f "$FX/Lcarsq_t6_mixed.cs"

# 5o. the seeded testCommand from §1 actually RUNS on a real fixture.
SEED="$(TOPLEVEL="$FX" detect_test_cmd)"
[ "$SEED" = "dotnet test MyApp.Tests.csproj" ] \
  || bad "5o(setup). unexpected seed on the real fixture: [$SEED]"
OUT="$( cd "$FX" && bash -c "$SEED" 2>&1 )"; RC=$?
[ "$RC" = 1 ] \
  && ok "5o. the SEEDED command really runs the suite (the sibling red makes it exit 1)" \
  || bad "5o. seeded command should have run and failed on the sibling (rc=$RC): $OUT"
rm -f "$FX/SiblingTests.cs" "$FX/CollideTests.cs" "$FX/PrefixTests.cs"
OUT="$( cd "$FX" && bash -c "$SEED" 2>&1 )"; RC=$?
[ "$RC" = 0 ] \
  && ok "5p. …and passes once the deliberately-failing sibling is gone" \
  || bad "5p. seeded command should pass on the clean fixture (rc=$RC): $OUT"

echo
printf 'stack-dotnet: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
