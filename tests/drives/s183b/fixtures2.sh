#!/usr/bin/env bash
# S183b ROUND-2 fixtures — the harder attacks and the harder inverse risks.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"
mkdir -p "$FIX_ROOT"

# ===== ATTACKS (must be REFUSED) =====
# A1: untested repo whose node_modules is FULL of other people's tests.
p="$(newrepo a-nodemodules)"
mkdir -p "$p/src" "$p/node_modules/lodash/test"
cat > "$p/package.json" <<'J'
{ "name": "app", "dependencies": { "lodash": "^4" } }
J
echo "console.log(1)" > "$p/src/i.js"
echo "{ \"name\": \"lodash\", \"devDependencies\": { \"mocha\": \"^10\" }, \"scripts\": { \"test\": \"mocha\" } }" > "$p/node_modules/lodash/package.json"
echo "describe('x',()=>it('y',()=>{}))" > "$p/node_modules/lodash/test/a.test.js"
commitall "$p"

# A2: a `test/` dir whose only file is a README that happens to say "assert".
p="$(newrepo a-testdir-assert-word)"
mkdir -p "$p/test" "$p/src"
printf '# Testing\n\nWe assert nothing yet. Write tests here someday.\n' > "$p/test/README.md"
echo "console.log(1)" > "$p/src/i.js"
commitall "$p"

# A3: only a CI workflow named test.yml, no tests at all.
p="$(newrepo a-ci-only)"
mkdir -p "$p/.github/workflows" "$p/src"
printf 'name: test\non: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps: [{run: "echo hi"}]\n' > "$p/.github/workflows/test.yml"
echo "console.log(1)" > "$p/src/i.js"
commitall "$p"

# A4: a package.json whose test script is a lint run (names no runner).
p="$(newrepo a-test-is-lint)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{ "name": "linty", "scripts": { "test": "eslint ." }, "devDependencies": { "eslint": "^9" } }
J
echo "console.log(1)" > "$p/src/i.js"
commitall "$p"

# A5: docs holding an EXAMPLE test file (over-permissive risk, ALLOW is a miss).
p="$(newrepo a-docs-example)"
mkdir -p "$p/docs" "$p/src"
echo "console.log(1)" > "$p/src/i.js"
cat > "$p/docs/example.test.js" <<'J'
// Sample from the tutorial — not run by anything.
test('example', () => expect(1).toBe(1))
J
commitall "$p"

# ===== INVERSE RISKS (genuinely tested — must be ALLOWED) =====
# B1: Maven / Java
p="$(newrepo b-maven)"
mkdir -p "$p/src/main/java/com/x" "$p/src/test/java/com/x"
cat > "$p/pom.xml" <<'J'
<project><modelVersion>4.0.0</modelVersion><groupId>x</groupId>
<artifactId>x</artifactId><version>1.0</version>
<dependencies><dependency><groupId>junit</groupId><artifactId>junit</artifactId>
<version>4.13.2</version><scope>test</scope></dependency></dependencies></project>
J
printf 'package com.x;\npublic class M { public static int add(int a,int b){return a+b;} }\n' > "$p/src/main/java/com/x/M.java"
printf 'package com.x;\nimport org.junit.Test;\npublic class MTest { @Test public void t(){} }\n' > "$p/src/test/java/com/x/MTest.java"
commitall "$p"

# B2: PHP / phpunit
p="$(newrepo b-php)"
mkdir -p "$p/src" "$p/tests"
printf '{ "require-dev": { "phpunit/phpunit": "^10" } }\n' > "$p/composer.json"
printf '<?php function add($a,$b){return $a+$b;}\n' > "$p/src/f.php"
printf '<?php use PHPUnit\\Framework\\TestCase;\nclass FTest extends TestCase { public function testAdd(){ $this->assertSame(3, 1+2); } }\n' > "$p/tests/FTest.php"
commitall "$p"

# B3: Elixir / mix
p="$(newrepo b-elixir)"
mkdir -p "$p/lib" "$p/test"
printf 'defmodule App.MixProject do\n  use Mix.Project\n  def project, do: [app: :app, version: "0.1.0"]\nend\n' > "$p/mix.exs"
printf 'defmodule App do\n  def add(a,b), do: a+b\nend\n' > "$p/lib/app.ex"
printf 'defmodule AppTest do\n  use ExUnit.Case\n  test "adds" do\n    assert App.add(1,2) == 3\n  end\nend\n' > "$p/test/app_test.exs"
commitall "$p"

# B4: Swift package
p="$(newrepo b-swift)"
mkdir -p "$p/Sources/App" "$p/Tests/AppTests"
printf '// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: "App")\n' > "$p/Package.swift"
printf 'public func add(_ a: Int, _ b: Int) -> Int { a + b }\n' > "$p/Sources/App/App.swift"
printf 'import XCTest\n@testable import App\nfinal class AppTests: XCTestCase { func testAdd() { XCTAssertEqual(add(1,2), 3) } }\n' > "$p/Tests/AppTests/AppTests.swift"
commitall "$p"

# B5: C++ / CMake + ctest
p="$(newrepo b-cmake)"
mkdir -p "$p/src" "$p/tests"
printf 'cmake_minimum_required(VERSION 3.16)\nproject(app)\nenable_testing()\nadd_subdirectory(tests)\n' > "$p/CMakeLists.txt"
printf 'int add(int a,int b){return a+b;}\n' > "$p/src/add.cpp"
printf 'add_executable(t t.cpp)\nadd_test(NAME t COMMAND t)\n' > "$p/tests/CMakeLists.txt"
printf '#include <cassert>\nint add(int,int);\nint main(){ assert(add(1,2)==3); }\n' > "$p/tests/t.cpp"
commitall "$p"

# B6: tests present but DEEPER than the scan depth — the boundary case.
p="$(newrepo b-deep-tests)"
mkdir -p "$p/src/main/webapp/js/components/widgets"
cat > "$p/package.json" <<'J'
{ "name": "deep", "scripts": { "build": "webpack" } }
J
echo "export const w=1" > "$p/src/main/webapp/js/components/widgets/widget.js"
cat > "$p/src/main/webapp/js/components/widgets/widget.test.js" <<'J'
import { w } from './widget.js'
test('w', () => expect(w).toBe(1))
J
commitall "$p"

# B7: a big real-ish tree with node_modules AND its own tests (speed + prune).
p="$(newrepo b-bigtree)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{ "name": "big", "scripts": { "test": "vitest run" }, "devDependencies": { "vitest": "^2" } }
J
for i in $(seq 1 40); do
  mkdir -p "$p/node_modules/dep$i/lib" "$p/node_modules/dep$i/test"
  echo "{ \"name\": \"dep$i\" }" > "$p/node_modules/dep$i/package.json"
  for j in $(seq 1 20); do echo "x" > "$p/node_modules/dep$i/lib/f$j.js"; done
  echo "it('t',()=>{})" > "$p/node_modules/dep$i/test/a.test.js"
done
echo "export const a=1" > "$p/src/a.js"
echo "import {a} from './a.js'; test('a',()=>expect(a).toBe(1))" > "$p/src/a.test.js"
commitall "$p"

# B8: python with unittest only (no pytest, no pyproject) — bare stdlib.
p="$(newrepo b-py-unittest)"
mkdir -p "$p/app" "$p/tests"
printf 'def add(a,b):\n    return a+b\n' > "$p/app/__init__.py"
printf 'import unittest\nfrom app import add\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(1,2), 3)\n' > "$p/tests/test_add.py"
commitall "$p"

# B9: bats shell tests only.
p="$(newrepo b-bats)"
mkdir -p "$p/bin" "$p/test"
printf '#!/usr/bin/env bash\necho "$(( $1 + $2 ))"\n' > "$p/bin/add"; chmod +x "$p/bin/add"
printf '@test "adds" {\n  run bin/add 1 2\n  [ "$output" = "3" ]\n}\n' > "$p/test/add.bats"
commitall "$p"

echo "ROUND-2 FIXTURES BUILT"
