#!/usr/bin/env bash
# S186 TESTER — PER-ARM STAGE DRIVE (captain stand-in, edits nothing).
#
# Drives the REAL `run.sh implement` STAGE (never implement-ticket) of an
# initialization mission on a REAL git repo per classifier arm, with a REAL
# toolchain, and answers the session's actual question:
#     does ticket 2's proof gate provably run against the runner ticket 1 built?
# Then, TRUSTING NOTHING LCARS PRINTS, it runs the established command BY HAND in
# a fresh worktree at the mission-branch tip and proves the suite DISCRIMINATES
# (break the code -> RED).
#
# ZERO SPEND: PATH shim with COUNTING fakes for BOTH claude and copilot behind a
# SPEND FUSE. Never $LCARS_WORKER_BIN.
set -u
LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="$LCARS_SRC/skills/lcars-run/run.sh"
OUTDIR="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s186drive.XXXXXX")}"
ARMS="${ARMS:-rust go dotnet ruby python}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }
tc_of() { sed -En 's/.*"testCommand"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$1" | head -1 | sed 's/\\"/"/g; s/\\\\/\\/g'; }

# ---------------- SPEND FUSE ----------------
SHIM="$OUTDIR/shim"; SPEND="$OUTDIR/spend.log"
mkdir -p "$SHIM"; : > "$SPEND"
cat > "$SHIM/claude" <<WORKER
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*) echo "0.0.0-s186-fake"; exit 0 ;;
esac
billable=no
case " \$* " in *" --model "*) billable=yes ;; esac
printf 'SPAWN\t%s\tbillable=%s\trole=%s\tticket=%s\n' "\$(basename "\$0")" "\$billable" "\${LCARS_WORKER_ROLE:-?}" "\${LCARS_TICKET:-?}" >> "$SPEND"
out="\${LCARS_WORK_OUT:-}"; [ -n "\$out" ] || exit 0
prompt="\$2"
tid="\$(printf '%s\n' "\$prompt" | awk '/^## Your ticket\$/{getline; print; exit}' | grep -oE 't-[0-9]+' | head -1)"
printf '%s\n' "\$prompt" > "$OUTDIR/prompt.\${S186_ARM:-x}.\${tid:-unknown}.txt" 2>/dev/null || :
case "\${LCARS_WORKER_ROLE:-}" in implement-tdd) : ;; *) exit 0 ;; esac
mkdir -p "\$out/setup"
case "\${S186_ARM:-}:\$tid" in
  rust:t-001)
    cat > "\$out/setup/Cargo.toml" <<'X'
[package]
name = "gfapp"
version = "0.1.0"
edition = "2021"
X
    printf 'target/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "" }\n' > "\$out/test-setup.json"
    mkdir -p src tests
    printf 'pub fn greet() -> &%sstatic str { "hello" }\n' "'" > src/lib.rs
    printf 'use gfapp::greet;\n#[test]\nfn greets() { assert_eq!(greet(), "hello"); }\n' > tests/greet.rs
    ;;
  rust:t-002)
    mkdir -p src tests
    printf 'pub fn greet() -> &%sstatic str { "hello" }\npub fn add(a: i32, b: i32) -> i32 { a + b }\n' "'" > src/lib.rs
    printf 'use gfapp::add;\n#[test]\nfn adds() { assert_eq!(add(2, 2), 4); }\n' > tests/add.rs
    ;;
  go:t-001)
    printf 'module gfapp\n\ngo 1.21\n' > "\$out/setup/go.mod"
    printf 'bin/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "" }\n' > "\$out/test-setup.json"
    printf 'package gfapp\n\nfunc Greet() string { return "hello" }\n' > greet.go
    printf 'package gfapp\n\nimport "testing"\n\nfunc TestGreet(t *testing.T) { if Greet() != "hello" { t.Fatal("bad") } }\n' > greet_test.go
    ;;
  go:t-002)
    printf 'package gfapp\n\nfunc Add(a int, b int) int { return a + b }\n' > add.go
    printf 'package gfapp\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) { if Add(2, 2) != 4 { t.Fatal("bad") } }\n' > add_test.go
    ;;
  dotnet:t-001)
    mkdir -p "\$out/setup/Tests"
    cat > "\$out/setup/Tests/Tests.csproj" <<'X'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>disable</Nullable>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="../app/**/*.cs" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>
</Project>
X
    printf 'bin/\nobj/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "dotnet restore Tests/Tests.csproj" }\n' > "\$out/test-setup.json"
    mkdir -p Tests app
    printf 'namespace Gf;\npublic static class Greeter { public static string Greet() => "hello"; }\n' > app/Greeter.cs
    printf 'using Xunit;\nusing Gf;\npublic class GreetTests { [Fact] public void Greets() { Assert.Equal("hello", Greeter.Greet()); } }\n' > Tests/GreetTests.cs
    ;;
  dotnet:t-002)
    mkdir -p Tests app
    printf 'namespace Gf;\npublic static class Adder { public static int Add(int a, int b) => a + b; }\n' > app/Adder.cs
    printf 'using Xunit;\nusing Gf;\npublic class AddTests { [Fact] public void Adds() { Assert.Equal(4, Adder.Add(2, 2)); } }\n' > Tests/AddTests.cs
    ;;
  ruby:t-001)
    cat > "\$out/setup/Rakefile" <<'X'
require 'rake/testtask'
Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  t.test_files = FileList['test/**/*_test.rb']
end
task :default => :test
X
    printf '.bundle/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "" }\n' > "\$out/test-setup.json"
    mkdir -p lib test
    printf "def greet\n  'hello'\nend\n" > lib/greet.rb
    printf "require 'minitest/autorun'\nrequire 'greet'\nclass GreetTest < Minitest::Test\n  def test_greet\n    assert_equal 'hello', greet\n  end\nend\n" > test/greet_test.rb
    ;;
  ruby:t-002)
    mkdir -p lib test
    printf "def add(a, b)\n  a + b\nend\n" > lib/add.rb
    printf "require 'minitest/autorun'\nrequire 'add'\nclass AddTest < Minitest::Test\n  def test_add\n    assert_equal 4, add(2, 2)\n  end\nend\n" > test/add_test.rb
    ;;
  python:t-001)
    printf 'test:\n\tpython3 -m unittest discover -v\n' > "\$out/setup/Makefile"
    printf '__pycache__/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "" }\n' > "\$out/test-setup.json"
    printf 'def greet():\n    return "hello"\n' > greet.py
    printf 'import unittest\nfrom greet import greet\n\nclass T(unittest.TestCase):\n    def test_greet(self):\n        self.assertEqual(greet(), "hello")\n' > test_greet.py
    ;;
  python:t-002)
    printf 'def add(a, b):\n    return a + b\n' > add.py
    printf 'import unittest\nfrom add import add\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(add(2, 2), 4)\n' > test_add.py
    ;;
esac
case "\${S186_ARM:-}:\$tid" in
  rust:t-001)   nt=tests/greet.rs ;;      rust:t-002)   nt=tests/add.rs ;;
  go:t-001)     nt=greet_test.go ;;       go:t-002)     nt=add_test.go ;;
  dotnet:t-001) nt=Tests/GreetTests.cs ;; dotnet:t-002) nt=Tests/AddTests.cs ;;
  ruby:t-001)   nt=test/greet_test.rb ;;  ruby:t-002)   nt=test/add_test.rb ;;
  python:t-001) nt=test_greet.py ;;       python:t-002) nt=test_add.py ;;
  *) nt="" ;;
esac
if [ "\$tid" = t-001 ]; then
  cat > "\$out/result.json" <<RJ
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "establish the project skeleton and its test system",
  "newTests": ["\$nt"], "testEdits": [],
  "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the repo's test system, so its parent commit has no runner; the captain watches the suite run at Verify" }
RJ
else
  cat > "\$out/result.json" <<RJ
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "add() sums two numbers",
  "newTests": ["\$nt"], "testEdits": [], "flipFlop": "expected" }
RJ
fi
exit 0
WORKER
chmod +x "$SHIM/claude"; cp "$SHIM/claude" "$SHIM/copilot"
fuse() { [ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] && return 0
  echo "SPEND FUSE TRIPPED: counting fakes missing in '$SHIM' — REFUSING (would bill)" >&2; exit 1; }
fuse
spawns()   { awk '/^SPAWN/{n++} END{print n+0}' "$SPEND"; }
billable() { awk '/billable=yes/{n++} END{print n+0}' "$SPEND"; }

newrepo() {
  local p="$OUTDIR/$1"; rm -rf "$p"; mkdir -p "$p"
  git -C "$p" init -q; git -C "$p" config user.email t@e.x; git -C "$p" config user.name t
  git -C "$p" config commit.gpgsign false
  printf '# gf\n\nA blank project.\n' > "$p/README.md"
  git -C "$p" add -A >/dev/null 2>&1; git -C "$p" commit -qm "initial commit" >/dev/null 2>&1
  mkdir -p "$p/.git/lcars"; printf '{\n  "version": 1\n}\n' > "$p/.git/lcars/config.json"
  echo "$p"
}
mkmission() {
  local r="$1" md="$1/.git/lcars/missions/init-001"
  mkdir -p "$md/tickets" "$md/manifests"
  cat > "$md/state.json" <<'JSON'
{
  "id": "init-001",
  "missionType": "initialization",
  "type": "feature",
  "title": "Establish the foundation",
  "stage": "implement",
  "branch": "lcars/init-001",
  "base": "__BASE__",
  "workerBin": "claude",
  "workerCli": "claude"
}
JSON
  cat > "$md/approved-plan.json" <<'JSON'
[
  {
    "id": "t-001",
    "title": "Project skeleton and test system",
    "description": "Establish the running skeleton and a working test system.",
    "acceptanceCriteria": ["a single command runs the suite"],
    "dependencies": []
  },
  {
    "id": "t-002",
    "title": "add() sums two numbers",
    "description": "One thin slice on top of the foundation.",
    "acceptanceCriteria": ["add(2,2) is 4"],
    "dependencies": ["t-001"]
  }
]
JSON
  cat > "$md/waves.json" <<'JSON'
[
  {
    "wave": 1,
    "tickets": [
      {
        "id": "t-001",
        "issue": null
      }
    ]
  },
  {
    "wave": 2,
    "tickets": [
      {
        "id": "t-002",
        "issue": null
      }
    ]
  }
]
JSON
  local base; base="$(git -C "$r" symbolic-ref --short HEAD 2>/dev/null || echo main)"
  sed -i.bak "s/__BASE__/$base/" "$md/state.json" && rm -f "$md/state.json.bak"
  printf '## Relevant files\n- the foundation\n' > "$md/manifests/t-001.md"
  printf '## Relevant files\n- the slice\n' > "$md/manifests/t-002.md"
  printf '# ctx\n' > "$r/CONTEXT.md"
  git -C "$r" add -A >/dev/null 2>&1; git -C "$r" commit -qm ctx >/dev/null 2>&1
  echo "$md"
}

# manifest file that must be on ticket 2's PARENT commit, and the impl file the
# by-hand DISCRIMINATING check breaks.
manifest_of() { case "$1" in rust) echo Cargo.toml;; go) echo go.mod;; dotnet) echo Tests/Tests.csproj;; ruby) echo Rakefile;; python) echo Makefile;; esac; }
# the GREET impl — always present at the tip (ticket 1 always lands), so the
# DISCRIMINATING check works whether or not ticket 2 was accepted.
impl_of()     { case "$1" in rust) echo src/lib.rs;; go) echo greet.go;; dotnet) echo app/Greeter.cs;; ruby) echo lib/greet.rb;; python) echo greet.py;; esac; }
have_tool()   { case "$1" in rust) command -v cargo;; go) command -v go;; dotnet) command -v dotnet;; ruby) command -v rake;; python) command -v python3;; esac >/dev/null 2>&1; }

echo "S186 per-arm stage drive — artifacts: $OUTDIR"
for ARM in $ARMS; do
  echo; echo "=== ARM: $ARM ==============================================="
  if ! have_tool "$ARM"; then note "SKIP $ARM — no local toolchain"; continue; fi
  REPO="$(newrepo "gf-$ARM")"; MD="$(mkmission "$REPO")"
  T0=$(date +%s)
  OUT="$( cd "$REPO" && env PATH="$SHIM:$PATH" S186_ARM="$ARM" \
        LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
        LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 \
        LCARS_SETUP_INSTALL_TIMEOUT_SECS=300 \
        bash "$RUN_SH" implement --mission init-001 2>&1 )"; RC=$?
  T1=$(date +%s)
  printf '%s\n' "$OUT" > "$OUTDIR/stage.$ARM.log"
  note "stage rc=$RC in $((T1-T0))s · worker sessions so far: $(spawns)"

  if [ -f "$MD/test-command.json" ]; then
    TC="$(tc_of "$MD/test-command.json")"
    ok "[$ARM] L1a. scaffold ticket ESTABLISHED a runner — testCommand: $TC"
  else
    TC=""; bad "[$ARM] L1a. no test-command.json: $(printf '%s' "$OUT" | tail -8 | tr '\n' ' ')"
  fi
  if ! grep -q '"testCommand"' "$REPO/.git/lcars/config.json" 2>/dev/null; then
    ok "[$ARM] L1b. repo config NOT written mid-mission"
  else bad "[$ARM] L1b. repo config gained testCommand MID-MISSION"; fi
  if grep -q '"flipFlop"[[:space:]]*:[[:space:]]*"not-applicable"' "$MD/tickets/t-001/result.json" 2>/dev/null \
     && grep -q flipFlopReason "$MD/tickets/t-001/result.json" 2>/dev/null; then
    ok "[$ARM] L1c. scaffold ticket exits through the audited waiver, with a reason"
  else bad "[$ARM] L1c. t-001 has no recorded waiver+reason"; fi

  BR="$(sed -n 's/.*"branch"[^"]*"\([^"]*\)".*/\1/p' "$MD/state.json" | head -1)"
  PARENT="$(cat "$MD/tickets/t-002/.commit-base" 2>/dev/null || true)"
  # the gate's OWN recorded parent is the authority when the ticket never landed
  [ -n "$PARENT" ] || PARENT="$(sed -n 's/.*"parentSha"[^"]*"\([^"]*\)".*/\1/p' "$MD/tickets/t-002/flip-flop.json" 2>/dev/null | head -1)"
  [ -n "$PARENT" ] || PARENT="$(git -C "$REPO" rev-parse "$BR^" 2>/dev/null || true)"
  MF="$(manifest_of "$ARM")"
  if [ -n "$PARENT" ] && git -C "$REPO" cat-file -e "$PARENT:$MF" 2>/dev/null; then
    ok "[$ARM] L2. $MF IS on ticket 2's PARENT commit ($PARENT) — measured"
  else bad "[$ARM] L2. $MF is NOT on ticket 2's parent ($PARENT)"; fi

  FF="$MD/tickets/t-002/flip-flop.json"
  if [ -f "$FF" ]; then
    cp "$FF" "$OUTDIR/flipflop.$ARM.json"
    V="$(sed -n 's/.*"verdict"[^"]*"\([^"]*\)".*/\1/p' "$FF" | head -1)"
    note "[$ARM] flip-flop: $(tr -d '\n' < "$FF" | cut -c1-320)"
    [ "$V" = pass ] && ok "[$ARM] L3a. ticket 2 PASSES a real flip-flop against the runner ticket 1 built" \
                    || bad "[$ARM] L3a. flip-flop verdict '$V'"
    grep -q '"ran"[[:space:]]*:[[:space:]]*true' "$FF" \
      && ok "[$ARM] L3b. the PARENT leg actually RAN" \
      || bad "[$ARM] L3b. the parent leg never ran"
  else bad "[$ARM] L3. no flip-flop.json for t-002"; fi
  grep -q ticket_postcommit_ok "$MD/events.jsonl" 2>/dev/null \
    && ok "[$ARM] L3c. the post-commit gate RAN and verified green on the committed branch" \
    || bad "[$ARM] L3c. no ticket_postcommit_ok"

  # ---- BY HAND, in a FRESH worktree at the mission-branch tip -------------
  if [ -n "$TC" ] && git -C "$REPO" rev-parse "$BR" >/dev/null 2>&1; then
    WT="$OUTDIR/byhand-$ARM"; rm -rf "$WT"
    git -C "$REPO" worktree add -q --detach "$WT" "$BR" >/dev/null 2>&1
    HRC=0; ( cd "$WT" && eval "$TC" ) > "$OUTDIR/byhand.$ARM.log" 2>&1 || HRC=$?
    if [ "$HRC" -eq 0 ]; then ok "[$ARM] L5a. BY HAND at the mission tip: '$TC' → GREEN (rc 0)"
    else bad "[$ARM] L5a. BY HAND '$TC' rc=$HRC: $(tail -5 "$OUTDIR/byhand.$ARM.log" | tr '\n' ' ')"; fi
    IMPL="$(impl_of "$ARM")"
    if [ -f "$WT/$IMPL" ]; then
      perl -pi -e 's/hello/goodbye/' "$WT/$IMPL"
      BRC=0; ( cd "$WT" && eval "$TC" ) > "$OUTDIR/byhand-broken.$ARM.log" 2>&1 || BRC=$?
      if [ "$BRC" -ne 0 ]; then ok "[$ARM] L5b. DISCRIMINATING: broke $IMPL (hello→goodbye) → suite went RED (rc $BRC)"
      else bad "[$ARM] L5b. NOT DISCRIMINATING: suite still GREEN on broken $IMPL"; fi
    else bad "[$ARM] L5b. impl file $IMPL absent at the tip — nothing to break"; fi
    git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || :
  else
    bad "[$ARM] L5. no test command / no mission branch — cannot run by hand"
  fi
done
printf '\nS186 arm drive: %d passed, %d failed  (worker sessions: %d, billable: %d)\n' \
  "$PASS" "$FAIL" "$(spawns)" "$(billable)"
echo "artifacts: $OUTDIR"
