#!/usr/bin/env bash
# S186 TESTER — THE ATTACK. Real doors only; edits nothing.
set -u
SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="$SRC/skills/lcars-run/run.sh"
EV="$SRC/skills/lcars-init/establish-vision.sh"
COMMON="$SRC/skills/lcars-init/lcars-common.sh"
OUT="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s186atk.XXXXXX")}"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
note(){ printf '  ·    %s\n' "$1"; }

SHIM="$OUT/shim"; SPEND="$OUT/spend.log"; mkdir -p "$SHIM"; : > "$SPEND"
for b in claude copilot; do
cat > "$SHIM/$b" <<SH
#!/usr/bin/env bash
case " \$* " in *" --version "*|*" -v "*) echo 0.0.0-s186-fake; exit 0 ;; esac
bill=no; case " \$* " in *" --model "*) bill=yes ;; esac
printf 'SPAWN\t%s\tbillable=%s\n' "\$(basename "\$0")" "\$bill" >> "$SPEND"
exit 0
SH
chmod +x "$SHIM/$b"; done
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "SPEND FUSE TRIPPED"; exit 1; }

mkrepo(){ # name [marker-file:content]
  local p="$OUT/$1"; rm -rf "$p"; mkdir -p "$p"
  git -C "$p" init -q; git -C "$p" config user.email t@e.x; git -C "$p" config user.name t
  git -C "$p" config commit.gpgsign false
  mkdir -p "$p/.git/lcars/missions/m1/tickets"
  printf '{\n  "version": 1\n}\n' > "$p/.git/lcars/config.json"
  cat > "$p/.git/lcars/missions/m1/state.json" <<'J'
{
  "id": "m1",
  "missionType": "initialization",
  "type": "feature",
  "title": "t",
  "stage": "implement",
  "branch": "lcars/m1",
  "base": "main"
}
J
  printf 'x\n' > "$p/README.md"; git -C "$p" add -A >/dev/null 2>&1
  git -C "$p" commit -qm i >/dev/null 2>&1
  echo "$p"
}
# real door #1
door1(){ # repo setupdir manifest [env...]
  local r="$1" sd="$2" mf="$3"; shift 3
  ( cd "$r" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_SETUP_GREENFIELD=1 \
      "$@" bash "$RUN_SH" apply-declared-setup-test --mission m1 \
      --result "$mf" --setup "$sd" "" 2>&1 )
}

echo "S186 attack — artifacts: $OUT"
echo
echo "== A. CROSS-ARM ALLOWLIST MATRIX (real apply_declared_setup) =========="
ARMS="js rust go dotnet ruby python jvm"
cmd_for(){ case "$1" in
  js) echo 'npm install --no-audit' ;; rust) echo 'cargo add proptest' ;;
  go) echo 'go get gotest.tools' ;;   dotnet) echo 'dotnet add package xunit' ;;
  ruby) echo 'bundle install' ;;      python) echo 'pip3 install pytest' ;;
  jvm) echo 'gradle init' ;; esac; }
R="$(mkrepo matrix)"; SD="$OUT/sd-empty"; mkdir -p "$SD"
MISMATCH=0; MATRIX=""
for repo_arm in $ARMS; do
  row=""
  for cmd_arm in $ARMS; do
    icmd="$(cmd_for "$cmd_arm")"
    printf '{ "package": "", "gap": "g", "installCommand": "%s" }\n' "$icmd" > "$OUT/mf.json"
    o="$(door1 "$R" "$SD" "$OUT/mf.json" LCARS_SETUP_STACK="$repo_arm")"
    if printf '%s' "$o" | grep -q "is not a plain package-manager invocation for this repo's stack ($repo_arm)"; then
      v=REFUSED
    elif printf '%s' "$o" | grep -q "leaves no test command LCARS can detect"; then
      v=ADMITTED   # got PAST the allowlist (and stopped before any install ran)
    else
      v="OTHER:$(printf '%s' "$o" | sed -n 's/^ASNOTE=//p' | cut -c1-40)"
    fi
    want=REFUSED; [ "$repo_arm" = "$cmd_arm" ] && want=ADMITTED
    [ "$v" = "$want" ] || { MISMATCH=$((MISMATCH+1)); note "MISMATCH repo=$repo_arm cmd='$icmd' → $v (want $want)"; }
    row="$row $(printf '%.1s' "$v")"
  done
  MATRIX="$MATRIX$repo_arm:$row
"
done
printf '%s' "$MATRIX" > "$OUT/matrix.txt"
[ "$MISMATCH" -eq 0 ] && ok "A1. 7x7 matrix: every arm admits ONLY its own package manager (49 cells, 0 mismatches)" \
                      || bad "A1. 7x7 matrix: $MISMATCH mismatched cells"

echo
echo "== A2. ARM RESOLUTION FROM A REAL TREE (no env override) =============="
for a in js:package.json rust:Cargo.toml go:go.mod dotnet:App.csproj ruby:Gemfile python:pyproject.toml jvm:build.gradle; do
  arm="${a%%:*}"; mk="${a##*:}"
  rr="$(mkrepo "arm-$arm")"; : > "$rr/$mk"
  [ "$mk" = package.json ] && printf '{"name":"x"}\n' > "$rr/$mk"
  got="$( cd "$rr" && env PATH="$SHIM:$PATH" bash "$RUN_SH" setup-allow-re-test 2>&1 | sed -n 's/^ARM=//p' )"
  [ "$got" = "$arm" ] && ok "A2.$arm  tree marker $mk → arm '$got'" || bad "A2.$arm  marker $mk → arm '$got' (want $arm)"
done

echo
echo "== B. METACHARACTERS AT BOTH DOORS (sentinel must never exist) ========"
SENT1="$OUT/PWNED_DOOR1"; SENT2="$OUT/PWNED_DOOR2"; rm -f "$SENT1" "$SENT2"
for probe in "npm install --no-audit && touch $SENT1" "npm install \$(touch $SENT1)" "npm install --no-audit; touch $SENT1" "npm install \`touch $SENT1\`" "npm install > $SENT1"; do
  printf '{ "package": "", "gap": "g", "installCommand": "%s" }\n' "$(printf '%s' "$probe" | sed 's/\\/\\\\/g; s/"/\\"/g')" > "$OUT/mf.json"
  o="$(door1 "$R" "$SD" "$OUT/mf.json" LCARS_SETUP_STACK=js)"
  if printf '%s' "$o" | grep -q 'contains a shell metacharacter'; then
    ok "B1. door 1 REFUSED: ${probe:0:46}"
  else bad "B1. door 1 did NOT refuse '${probe}': $(printf '%s' "$o" | tr '\n' ' ' | cut -c1-160)"; fi
done
[ -e "$SENT1" ] && bad "B2. door-1 sentinel EXISTS — a metachar payload EXECUTED" || ok "B2. door-1 sentinel absent — nothing executed"

# --- door 2: setup_reapply_in_worktree over a RECORD on disk ---------------
R2="$(mkrepo reapply)"; MD2="$R2/.git/lcars/missions/m1"
WT="$OUT/wt"; rm -rf "$WT"; mkdir -p "$WT"; printf '{"name":"x"}\n' > "$WT/package.json"
door2(){ printf '{ "package": "", "gap": "g", "installCommand": "%s" }\n' "$1" > "$MD2/test-setup-applied.json"
  ( cd "$R2" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true bash "$RUN_SH" setup-reapply-test --mission m1 "$WT" 2>&1 ); }
o="$(door2 "npm install --no-audit && touch $SENT2")"
grep -q 'test_setup_reapply_refused' "$MD2/events.jsonl" 2>/dev/null \
  && ok "B3. door 2 (setup_reapply_in_worktree) REFUSED a metacharacter install, out loud" \
  || bad "B3. door 2 did not refuse/record: $o"
[ -e "$SENT2" ] && bad "B4. door-2 sentinel EXISTS — the reapply EXECUTED a metachar payload" || ok "B4. door-2 sentinel absent — nothing executed"
# cross-arm at door 2: a JS install re-applied into a RUST worktree
rm -rf "$WT"; mkdir -p "$WT"; printf '[package]\nname="x"\n' > "$WT/Cargo.toml"
: > "$MD2/events.jsonl"
o="$(door2 "npm install --no-audit")"
grep -q "test_setup_reapply_refused" "$MD2/events.jsonl" 2>/dev/null \
  && ok "B5. door 2 REFUSED 'npm install' re-applied into a RUST gate worktree" \
  || bad "B5. door 2 admitted a JS install into a rust worktree: $o"
: > "$MD2/events.jsonl"
rm -rf "$WT"; mkdir -p "$WT"; printf '[package]\nname="x"\n' > "$WT/Cargo.toml"
o="$(door2 "cargo add proptest")"
grep -q "test_setup_reapply_refused" "$MD2/events.jsonl" 2>/dev/null \
  && bad "B6. door 2 REFUSED the rust arm's OWN command in a rust worktree" \
  || ok "B6. door 2 admits the rust arm's own command in a rust worktree"

echo
echo "== C. THE MECHANICS STILL APPLY ON A NON-JS ARM ======================="
SDS="$OUT/sd-src"; rm -rf "$SDS"; mkdir -p "$SDS/src"; printf 'x\n' > "$SDS/src/lib.rs"
printf '{ "package": "", "gap": "g", "installCommand": "" }\n' > "$OUT/mf.json"
o="$(door1 "$R" "$SDS" "$OUT/mf.json" LCARS_SETUP_STACK=rust)"
printf '%s' "$o" | grep -q "targets src/" && ok "C1. rust arm: a declared setup touching src/ is REFUSED" \
  || bad "C1. rust arm: src/ setup not refused: $o"
R3="$(mkrepo overwrite)"; printf 'old\n' > "$R3/Cargo.toml"
SDO="$OUT/sd-ovr"; rm -rf "$SDO"; mkdir -p "$SDO"; printf 'new\n' > "$SDO/Cargo.toml"
o="$(door1 "$R3" "$SDO" "$OUT/mf.json" LCARS_SETUP_STACK=rust)"
printf '%s' "$o" | grep -q "already exists in the package" && ok "C2. rust arm: overwriting an existing file is REFUSED" \
  || bad "C2. rust arm: overwrite not refused: $o"
grep -q '^new$' "$R3/Cargo.toml" && bad "C2b. the existing Cargo.toml was OVERWRITTEN anyway" || ok "C2b. the existing file is untouched"

echo
echo "== D. RUBY: A DECLARATION NAMING NEITHER RSPEC NOR MINITEST ==========="
SDR="$OUT/sd-ruby"; rm -rf "$SDR"; mkdir -p "$SDR"
printf "source 'https://rubygems.org'\ngem 'sinatra'\n" > "$SDR/Gemfile"
o="$(door1 "$(mkrepo rubyneither)" "$SDR" "$OUT/mf.json" LCARS_SETUP_STACK=ruby)"
printf '%s' "$o" | grep -q "leaves no test command LCARS can detect" \
  && ok "D1. ruby: a setup naming neither rspec nor minitest is BOUNCED" \
  || bad "D1. ruby: neither-framework setup was ACCEPTED: $o"
SDR2="$OUT/sd-ruby2"; rm -rf "$SDR2"; mkdir -p "$SDR2"
printf "source 'https://rubygems.org'\ngem 'rspec'\n" > "$SDR2/Gemfile"
RB="$(mkrepo rubyrspec)"; mkdir -p "$RB/spec"; printf 'x\n' > "$RB/spec/a_spec.rb"
o="$(door1 "$RB" "$SDR2" "$OUT/mf.json" LCARS_SETUP_STACK=ruby)"
printf '%s' "$o" | grep -q "leaves no test command LCARS can detect" \
  && bad "D2. ruby: an rspec-naming setup was ALSO bounced (over-refusal): $o" \
  || ok "D2. ruby: an rspec-naming setup gets past the detector gate"

echo
echo "== E. THE FOUNDATION ORACLE, TESTED vs UNTESTED, PER ARM ============="
oracle(){ ( set +u; TOPLEVEL="$1"; . "$COMMON" >/dev/null 2>&1; lcars_test_system_evidence "$1" 2>/dev/null ); }
mkfix(){ local d="$OUT/ora-$1"; rm -rf "$d"; mkdir -p "$d"; echo "$d"; }
# untested / tested pairs per arm
d="$(mkfix rust-un)";  printf '[package]\nname="x"\n' > "$d/Cargo.toml"; RUST_UN="$d"
d="$(mkfix rust-t)";   printf '[package]\nname="x"\n[dev-dependencies]\nproptest="1"\n' > "$d/Cargo.toml"; mkdir -p "$d/tests"; printf '#[test]\nfn t(){}\n' > "$d/tests/a_test.rs"; RUST_T="$d"
d="$(mkfix go-un)";    printf 'module x\n' > "$d/go.mod"; GO_UN="$d"
d="$(mkfix go-t)";     printf 'module x\n' > "$d/go.mod"; printf 'package x\n' > "$d/a_test.go"; GO_T="$d"
d="$(mkfix ruby-un)";  printf "source 'x'\ngem 'sinatra'\n" > "$d/Gemfile"; RUBY_UN="$d"
d="$(mkfix ruby-t)";   printf "source 'x'\ngroup :test do\n  gem 'rspec'\nend\n" > "$d/Gemfile"; RUBY_T="$d"
d="$(mkfix gem-t)";    printf "Gem::Specification.new do |s|\n  s.add_development_dependency 'minitest'\nend\n" > "$d/x.gemspec"; GEM_T="$d"
d="$(mkfix jvm-un)";   printf "plugins { id 'java' }\n" > "$d/build.gradle"; JVM_UN="$d"
d="$(mkfix jvm-t)";    printf "dependencies {\n  testImplementation 'junit:junit:4.13'\n}\n" > "$d/build.gradle"; JVM_T="$d"
d="$(mkfix mvn-un)";   printf '<project><modelVersion>4.0.0</modelVersion></project>\n' > "$d/pom.xml"; MVN_UN="$d"
d="$(mkfix mvn-t)";    printf '<project><dependencies><dependency><scope>test</scope></dependency></dependencies></project>\n' > "$d/pom.xml"; MVN_T="$d"
d="$(mkfix py-un)";    printf '[project]\nname="x"\n' > "$d/pyproject.toml"; PY_UN="$d"
d="$(mkfix py-t)";     printf '[project]\nname="x"\n[tool.pytest.ini_options]\n' > "$d/pyproject.toml"; PY_T="$d"
d="$(mkfix dn-un)";    printf '<Project Sdk="Microsoft.NET.Sdk"></Project>\n' > "$d/App.csproj"; DN_UN="$d"
d="$(mkfix dn-t)";     mkdir -p "$d/App.Tests"; printf '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="Microsoft.NET.Test.Sdk" /></ItemGroup></Project>\n' > "$d/App.Tests/App.Tests.csproj"; DN_T="$d"
# THE S186 ADDITIONS — manifest-level evidence that HEAD could not see.
for pair in "ruby-gemfile:$RUBY_UN:$RUBY_T" "ruby-gemspec:$RUBY_UN:$GEM_T" \
            "jvm-gradle:$JVM_UN:$JVM_T" "jvm-maven:$MVN_UN:$MVN_T" "dotnet:$DN_UN:$DN_T"; do
  n="${pair%%:*}"; rest="${pair#*:}"; u="${rest%%:*}"; t="${rest##*:}"
  eu="$(oracle "$u")"; et="$(oracle "$t")"
  if [ -z "$eu" ] && [ -n "$et" ]; then ok "E.$n  untested→no evidence · tested→'$et'"
  else bad "E.$n  untested→'$eu' (want empty) · tested→'$et' (want non-empty)"; fi
done
# NO REGRESSION: every fixture must read the same as it did at HEAD, except where
# S186 deliberately ADDS evidence (never removes it).
mkdir -p "$OUT/head"
git -C "$SRC" show HEAD:skills/lcars-init/lcars-common.sh > "$OUT/head/lcars-common.sh" 2>/dev/null
oracle_head(){ ( set +u; TOPLEVEL="$1"; . "$OUT/head/lcars-common.sh" >/dev/null 2>&1; lcars_test_system_evidence "$1" 2>/dev/null ); }
REG=0
for d in "$RUST_UN" "$RUST_T" "$GO_UN" "$GO_T" "$RUBY_UN" "$RUBY_T" "$GEM_T" "$JVM_UN" "$JVM_T" \
         "$MVN_UN" "$MVN_T" "$PY_UN" "$PY_T" "$DN_UN" "$DN_T"; do
  w="$(oracle "$d")"; h="$(oracle_head "$d")"
  [ "$w" = "$h" ] && continue
  if [ -z "$h" ] && [ -n "$w" ]; then note "E.reg ADDED on $(basename "$d"): '$w'"
  else REG=$((REG+1)); note "E.reg REGRESSED on $(basename "$d"): HEAD='$h' WIP='$w'"; fi
done
[ "$REG" -eq 0 ] && ok "E.reg  the oracle only ADDS evidence — no fixture reads worse than at HEAD" \
                 || bad "E.reg  $REG fixture(s) read WORSE than at HEAD"
# INHERITED, recorded not asserted: rust/go/python read an UNTESTED repo as tested.
for pr in "rust:$RUST_UN" "go:$GO_UN" "python:$PY_UN"; do
  note "E.inherited $\{pr%%:*}: an UNTESTED fixture reads '$(oracle "$\{pr#*:}")' — identical at HEAD"
done

echo
echo "== F. JS/TS REGRESSION (must be byte-identical) ======================="
mkdir -p "$OUT/head"
git -C "$SRC" show HEAD:skills/lcars-init/establish-vision.sh > "$OUT/head/establish-vision.sh"
git -C "$SRC" show HEAD:skills/lcars-init/lcars-common.sh    > "$OUT/head/lcars-common.sh"
for stk in "TypeScript + Vite + React" "Node.js"; do
  printf 'idea\n' > "$OUT/idea.txt"
  a="$( env STACK="x" bash "$EV" --prd --idea "$OUT/idea.txt" --stack "$stk" --slice "a slice" --title "T" 2>&1 )"
  b="$( env STACK="x" bash "$OUT/head/establish-vision.sh" --prd --idea "$OUT/idea.txt" --stack "$stk" --slice "a slice" --title "T" 2>&1 )"
  [ "$a" = "$b" ] && ok "F1. JS/TS PRD byte-identical to HEAD for stack '$stk'" \
    || { bad "F1. JS/TS PRD CHANGED for '$stk'"; diff <(printf '%s' "$b") <(printf '%s' "$a") | head -20; }
done
o="$( cd "$R" && env PATH="$SHIM:$PATH" LCARS_SETUP_STACK=js bash "$RUN_SH" setup-allow-re-test 2>&1 | sed -n 's/^ALLOW=//p' )"
[ "$o" = '^(pnpm|npm|yarn|bun)[[:space:]]' ] && ok "F2. the js allowlist row is byte-identical to the pre-S186 pattern" \
  || bad "F2. js row is now '$o'"

echo
echo "== G. THE PER-ARM PRD GUIDANCE, READ AS A HUMAN ======================="
for stk in "Rust + Axum" "Go" ".NET 8 / C#" "Ruby on Rails" "Python + FastAPI" "Kotlin + Gradle"; do
  p="$( bash "$EV" --prd --idea "$OUT/idea.txt" --stack "$stk" --slice "a slice" --title "T" 2>&1 )"
  printf '%s\n' "$p" > "$OUT/prd.$(printf '%s' "$stk" | tr -c 'A-Za-z0-9' '_').md"
  if printf '%s' "$p" | grep -q -- '--break-system-packages'; then bad "G1. '$stk' PRD emits --break-system-packages"; fi
  # a COPYABLE command = a backticked token that looks like a shell invocation
  cop="$(printf '%s' "$p" | grep -oE '`[a-z][a-z0-9]*( +--?[a-z-]+| +[a-z][a-z0-9_.-]*)+`' | grep -vE '^`lcars ' || :)"
  if [ -n "$cop" ]; then bad "G2. '$stk' PRD hands the model a COPYABLE command: $(printf '%s' "$cop" | tr '\n' ' ')"; fi
done
ok "G. per-arm PRD scan complete (see $OUT/prd.*.md)"
printf '\nS186 attack: %d passed, %d failed  (worker sessions: %s, billable: %s)\n' \
  "$PASS" "$FAIL" "$(awk '/^SPAWN/{n++}END{print n+0}' "$SPEND")" "$(awk '/billable=yes/{n++}END{print n+0}' "$SPEND")"
echo "artifacts: $OUT"
