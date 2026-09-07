#!/usr/bin/env bash
# S183b fixture builder — REAL git repos in every state under test.
# Idempotent: re-running rebuilds each fixture from scratch.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/rig.sh"

mkdir -p "$FIX_ROOT"

# ---------- THE FOUR STATES ----------
# 1. blank — git init and nothing else (UNBORN HEAD).
p="$(newrepo blank)"

# 2. readme — a README describing an idea, committed.
p="$(newrepo readme)"
printf '# My Idea\n\nA website that does personal finance stuff.\n' > "$p/README.md"
commitall "$p"

# 3. untested — a real Vite+React scaffold with its `test` script and test
#    dev-deps removed (the captain's measured case).
p="$(newrepo untested)"
mkdir -p "$p/src" "$p/public"
cat > "$p/package.json" <<'J'
{
  "name": "finance-app",
  "private": true,
  "version": "0.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "lint": "eslint .",
    "preview": "vite preview"
  },
  "dependencies": { "react": "^18.3.1", "react-dom": "^18.3.1" },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.1",
    "eslint": "^9.9.0",
    "vite": "^5.4.1"
  }
}
J
cat > "$p/vite.config.js" <<'J'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({ plugins: [react()] })
J
cat > "$p/index.html" <<'J'
<!doctype html><html><body><div id="root"></div>
<script type="module" src="/src/main.jsx"></script></body></html>
J
cat > "$p/src/main.jsx" <<'J'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
ReactDOM.createRoot(document.getElementById('root')).render(<App />)
J
cat > "$p/src/App.jsx" <<'J'
export default function App() { return <h1>Finance</h1> }
J
commitall "$p"

# 4. ready — a fully tested JS repo (vitest devDep, test script, a real spec).
p="$(newrepo ready)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{
  "name": "tested-app",
  "private": true,
  "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^2.0.0" }
}
J
cat > "$p/src/add.js" <<'J'
export const add = (a, b) => a + b
J
cat > "$p/src/add.test.js" <<'J'
import { describe, it, expect } from 'vitest'
import { add } from './add.js'
describe('add', () => { it('adds', () => { expect(add(1,2)).toBe(3) }) })
J
commitall "$p"

# ---------- THE MONOREPO (the ledgered lie) ----------
# npm workspaces, THREE tested packages, each with vitest + a spec.
p="$(newrepo mono)"
cat > "$p/package.json" <<'J'
{
  "name": "mono",
  "private": true,
  "workspaces": ["packages/*"],
  "devDependencies": { "vitest": "^2.0.0" }
}
J
for n in alpha beta gamma; do
  mkdir -p "$p/packages/$n/src"
  cat > "$p/packages/$n/package.json" <<J2
{ "name": "@mono/$n", "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^2.0.0" } }
J2
  echo "export const v = '$n'" > "$p/packages/$n/src/index.js"
  cat > "$p/packages/$n/src/index.test.js" <<'J2'
import { it, expect } from 'vitest'
import { v } from './index.js'
it('has a value', () => { expect(v).toBeTruthy() })
J2
done
commitall "$p"

# pnpm workspace with NO root package.json.
p="$(newrepo pnpm-noroot)"
printf 'packages:\n  - "packages/*"\n' > "$p/pnpm-workspace.yaml"
mkdir -p "$p/packages/core/src"
cat > "$p/packages/core/package.json" <<'J'
{ "name": "core", "scripts": { "test": "vitest run" },
  "devDependencies": { "vitest": "^2.0.0" } }
J
echo "export const x = 1" > "$p/packages/core/src/x.js"
cat > "$p/packages/core/src/x.test.js" <<'J'
import { it, expect } from 'vitest'
import { x } from './x.js'
it('is one', () => { expect(x).toBe(1) })
J
commitall "$p"

# ---------- ATTACKS ON THE ORACLE (must NOT read as a foundation) ----------
# A: npm's DEFAULT test script — not a test system.
p="$(newrepo attack-npm-default)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{ "name": "defaulty", "version": "1.0.0",
  "scripts": { "test": "echo \"Error: no test specified\" && exit 1" } }
J
echo "console.log('hi')" > "$p/src/index.js"
commitall "$p"

# B: a script literally named `test` that tests nothing.
p="$(newrepo attack-script-named-test)"
mkdir -p "$p/src" "$p/scripts"
cat > "$p/package.json" <<'J'
{ "name": "fakey", "scripts": { "test": "./scripts/test" } }
J
printf '#!/usr/bin/env bash\necho "all good"\nexit 0\n' > "$p/scripts/test"
chmod +x "$p/scripts/test"
echo "console.log('hi')" > "$p/src/index.js"
commitall "$p"

# C: a test/ directory containing no framework at all (just notes).
p="$(newrepo attack-testdir-notes)"
mkdir -p "$p/test" "$p/src"
printf 'Manual QA notes.\nOpen the page. Click the button.\n' > "$p/test/NOTES.md"
printf 'Someday we will write tests here.\n' > "$p/test/TODO.txt"
echo "console.log('hi')" > "$p/src/index.js"
commitall "$p"

# ---------- THE INVERSE RISK: genuinely tested, must NOT be refused ----------
# D: test FILES exist, runner NOT installed (no node_modules, no dev-dep).
p="$(newrepo inv-tests-no-runner)"
mkdir -p "$p/src"
cat > "$p/package.json" <<'J'
{ "name": "orphan-tests", "scripts": { "start": "node src/index.js" } }
J
echo "module.exports.add=(a,b)=>a+b" > "$p/src/add.js"
cat > "$p/src/add.test.js" <<'J'
const { add } = require('./add')
const assert = require('assert')
assert.strictEqual(add(1,2), 3)
J
commitall "$p"

# E: workspace where ONLY ONE of three packages is tested.
p="$(newrepo inv-one-tested)"
cat > "$p/package.json" <<'J'
{ "name": "partly", "private": true, "workspaces": ["packages/*"] }
J
for n in a b; do
  mkdir -p "$p/packages/$n/src"
  echo "{ \"name\": \"$n\" }" > "$p/packages/$n/package.json"
  echo "export const q=1" > "$p/packages/$n/src/i.js"
done
mkdir -p "$p/packages/c/src"
cat > "$p/packages/c/package.json" <<'J'
{ "name": "c", "scripts": { "test": "jest" }, "devDependencies": { "jest": "^29" } }
J
echo "export const q=1" > "$p/packages/c/src/i.js"
cat > "$p/packages/c/src/i.test.js" <<'J'
test('q', () => { expect(1).toBe(1) })
J
commitall "$p"

# F: Makefile-driven tests.
p="$(newrepo inv-makefile)"
mkdir -p "$p/t"
printf 'test:\n\t@bash t/all.sh\n\nbuild:\n\t@echo build\n' > "$p/Makefile"
printf '#!/usr/bin/env bash\nset -e\n[ "$((1+1))" = 2 ] || exit 1\necho ok\n' > "$p/t/all.sh"
echo 'int main(void){return 0;}' > "$p/main.c"
commitall "$p"

# G: tests/run.sh — this repo's own shape.
p="$(newrepo inv-tests-runsh)"
mkdir -p "$p/tests" "$p/skills"
printf '#!/usr/bin/env bash\nfor f in "$(dirname "$0")"/*.test.sh; do bash "$f" || exit 1; done\n' > "$p/tests/run.sh"
printf '#!/usr/bin/env bash\n[ 1 = 1 ] && echo PASS\n' > "$p/tests/thing.test.sh"
printf '#!/usr/bin/env bash\necho hi\n' > "$p/skills/thing.sh"
commitall "$p"

# H: rust
p="$(newrepo inv-rust)"
mkdir -p "$p/src" "$p/tests"
printf '[package]\nname = "r"\nversion = "0.1.0"\nedition = "2021"\n' > "$p/Cargo.toml"
printf 'pub fn add(a: i32, b: i32) -> i32 { a + b }\n' > "$p/src/lib.rs"
printf 'use r::add;\n#[test]\nfn works() { assert_eq!(add(1,2), 3); }\n' > "$p/tests/int.rs"
commitall "$p"

# I: go
p="$(newrepo inv-go)"
printf 'module example.com/g\n\ngo 1.22\n' > "$p/go.mod"
printf 'package g\n\nfunc Add(a, b int) int { return a + b }\n' > "$p/g.go"
printf 'package g\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) { if Add(1,2) != 3 { t.Fatal() } }\n' > "$p/g_test.go"
commitall "$p"

# J: python (pytest layout, no config file)
p="$(newrepo inv-python)"
mkdir -p "$p/src/app" "$p/tests"
printf '[project]\nname = "app"\nversion = "0.1.0"\n' > "$p/pyproject.toml"
printf 'def add(a, b):\n    return a + b\n' > "$p/src/app/__init__.py"
printf 'from app import add\n\ndef test_add():\n    assert add(1, 2) == 3\n' > "$p/tests/test_add.py"
commitall "$p"

# K: ruby (rspec)
p="$(newrepo inv-ruby)"
mkdir -p "$p/lib" "$p/spec"
printf "source 'https://rubygems.org'\ngem 'rspec'\n" > "$p/Gemfile"
printf 'def add(a,b); a+b; end\n' > "$p/lib/add.rb"
printf "require_relative '../lib/add'\ndescribe 'add' do\n  it 'adds' do\n    expect(add(1,2)).to eq 3\n  end\nend\n" > "$p/spec/add_spec.rb"
commitall "$p"

# L: dotnet
p="$(newrepo inv-dotnet)"
mkdir -p "$p/App" "$p/App.Tests"
printf '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup></Project>\n' > "$p/App/App.csproj"
printf 'namespace App; public static class M { public static int Add(int a,int b)=>a+b; }\n' > "$p/App/M.cs"
cat > "$p/App.Tests/App.Tests.csproj" <<'J'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net8.0</TargetFramework><IsPackable>false</IsPackable></PropertyGroup>
  <ItemGroup>
    <PackageReference Include="xunit" Version="2.5.0" />
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.8.0" />
  </ItemGroup>
</Project>
J
printf 'using Xunit;\npublic class MTests { [Fact] public void Adds() { Assert.Equal(3, App.M.Add(1,2)); } }\n' > "$p/App.Tests/MTests.cs"
commitall "$p"

# M: monorepo with NO root manifest at all — just packages, all tested.
p="$(newrepo inv-mono-no-root)"
for n in one two; do
  mkdir -p "$p/services/$n/src"
  cat > "$p/services/$n/package.json" <<J2
{ "name": "$n", "scripts": { "test": "mocha" }, "devDependencies": { "mocha": "^10" } }
J2
  echo "module.exports = 1" > "$p/services/$n/src/i.js"
  cat > "$p/services/$n/src/i.test.js" <<'J2'
const assert = require('assert')
describe('i', () => { it('works', () => assert.ok(1)) })
J2
done
commitall "$p"

echo "FIXTURES BUILT UNDER $FIX_ROOT"
ls -1 "$FIX_ROOT"
