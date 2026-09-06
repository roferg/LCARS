set -u
. "/Users/roganferguson/Projects/LCARS/tests/drives/s183b/rig.sh"
row() { printf '%-28s fnd=%-13s gate=%-7s %s\n' "$1" "$2" "$3" "$4"; }
probe() {
  local p="$1" want="$2"
  local j; j="$( (cd "$p" && bash "$GATE_SH" --json 2>/dev/null) )"
  local f; f="$(printf '%s' "$j" | sed -E 's/.*"foundation":"?([a-z]*)"?.*/\1/')"
  ( cd "$p" && bash "$GATE_SH" --check >/dev/null 2>&1 ); local rc=$?
  local dec=ALLOW; [ "$rc" = 20 ] && dec=REFUSE
  local mark=""; [ "$dec" != "$want" ] && mark="  <<< MISS (wanted $want)"
  row "$(basename "$p")" "$f" "$dec" "$mark"
}
echo "======== THE FOUR NAMED ATTACKS"
probe "$FIX_ROOT/attack-npm-default"        REFUSE
probe "$FIX_ROOT/attack-testdir-notes"      REFUSE
probe "$FIX_ROOT/attack-script-named-test"  REFUSE
probe "$FIX_ROOT/a-docs-example"            REFUSE
echo "======== THE OTHER ATTACK FIXTURES"
for n in a-ci-only a-nodemodules a-test-is-lint a-testdir-assert-word untested readme blank nit-pristine; do
  case "$n" in blank|readme) w=REFUSE ;; *) w=REFUSE ;; esac
  probe "$FIX_ROOT/$n" $w
done
echo "======== FRESH ATTACKS (built now)"
q="$(newrepo x-docsonly)"; mkdir -p "$q/docs"; printf '# Docs\n\nHow to use it.\n' > "$q/docs/guide.md"; commitall "$q"
probe "$q" REFUSE
q="$(newrepo x-test-dir-empty)"; mkdir -p "$q/tests" "$q/src"; echo hi > "$q/tests/.keep"; echo "console.log(1)" > "$q/src/i.js"; commitall "$q"
probe "$q" REFUSE
q="$(newrepo x-test-dir-readme-it)"; mkdir -p "$q/tests" "$q/src"
printf '# Tests\n\nSomeday. It would be nice to test this.\n' > "$q/tests/README.md"
echo "console.log(1)" > "$q/src/i.js"; commitall "$q"
probe "$q" REFUSE
q="$(newrepo x-t-changelog)"; mkdir -p "$q/src"; printf 'notes\n' > "$q/CHANGELOG.t"; echo "console.log(1)" > "$q/src/i.js"; commitall "$q"
probe "$q" REFUSE
q="$(newrepo x-testscript-echo)"; mkdir -p "$q/src"
printf '{ "name":"z", "scripts": { "test": "echo no tests yet" } }\n' > "$q/package.json"
echo "console.log(1)" > "$q/src/i.js"; commitall "$q"
probe "$q" REFUSE
q="$(newrepo x-readme-mentions-jest)"; mkdir -p "$q/src"
printf '# App\n\nWe plan to use jest and vitest one day.\n' > "$q/README.md"
echo "console.log(1)" > "$q/src/i.js"; commitall "$q"
probe "$q" REFUSE
echo "======== FRESH INVERSE RISKS (must ALLOW)"
q="$(newrepo x-swift-real)"; mkdir -p "$q/Sources/App" "$q/Tests/AppTests"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "App")\n' > "$q/Package.swift"
printf 'public func add(_ a: Int,_ b: Int)->Int{a+b}\n' > "$q/Sources/App/App.swift"
printf 'import XCTest\n@testable import App\nfinal class AppTests: XCTestCase { func testAdd(){ XCTAssertEqual(add(1,2),3) } }\n' > "$q/Tests/AppTests/AppTests.swift"
commitall "$q"; probe "$q" ALLOW
q="$(newrepo x-perl-real)"; mkdir -p "$q/lib" "$q/t"
printf 'package App; sub add { $_[0]+$_[1] } 1;\n' > "$q/lib/App.pm"
printf "use strict; use Test::More tests => 1;\nuse App;\nis(App::add(1,2), 3, 'adds');\n" > "$q/t/add.t"
commitall "$q"; probe "$q" ALLOW
