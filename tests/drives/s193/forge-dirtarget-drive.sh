#!/usr/bin/env bash
# S193 FRESH TESTER — forge-drive.sh with ONE change: the custom-harness target
# uses cargo's DIRECTORY-STYLE integration-test layout, tests/suite/main.rs, and
# therefore declares no explicit `path`. Tier 1's grep FIRES and tomllib parses
# the manifest fine, but proof_cargo_harness_decls derives the DEFAULT path
# `tests/suite.rs` while cargo announces `tests/suite/main.rs` — so the opt-out
# is neither attributed nor discarded. If this reaches verdict `pass`, the round-2
# rule is bypassed by a second, independent route.
set -u
LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="${RUN_SH:-$LCARS_SRC/skills/lcars-run/run.sh}"
OUTDIR="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s193forgedir.XXXXXX")}"
mkdir -p "$OUTDIR"
SHIM="$OUTDIR/shim"; SPEND="$OUTDIR/spend.log"; mkdir -p "$SHIM"; : > "$SPEND"
cat > "$SHIM/claude" <<WORKER
#!/usr/bin/env bash
case " \$* " in *" --version "*|*" -v "*) echo "0.0.0-s193-fake"; exit 0 ;; esac
billable=no; case " \$* " in *" --model "*) billable=yes ;; esac
printf 'SPAWN\t%s\tbillable=%s\trole=%s\n' "\$(basename "\$0")" "\$billable" "\${LCARS_WORKER_ROLE:-?}" >> "$SPEND"
out="\${LCARS_WORK_OUT:-}"; [ -n "\$out" ] || exit 0
prompt="\$2"
tid="\$(printf '%s\n' "\$prompt" | awk '/^## Your ticket\$/{getline; print; exit}' | grep -oE 't-[0-9]+' | head -1)"
case "\${LCARS_WORKER_ROLE:-}" in implement-tdd) : ;; *) exit 0 ;; esac
mkdir -p "\$out/setup"
case "\$tid" in
  t-001)
    cat > "\$out/setup/Cargo.toml" <<'X'
[package]
name = "gfapp"
version = "0.1.0"
edition = "2021"

[[test]]
name = "suite"
harness = false
X
    printf 'target/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "" }\n' > "\$out/test-setup.json"
    mkdir -p src tests/suite
    printf 'pub fn greet() -> &%sstatic str { "hello" }\n' "'" > src/lib.rs
    cat > tests/suite/main.rs <<'X'
fn main() {
    println!("running 1 test");
    assert_eq!(gfapp::greet(), "hello");
    println!("test adds ... ok");
    println!("test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");
}
X
    nt=tests/suite/main.rs
    cat > "\$out/result.json" <<RJ
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "establish the project skeleton and its test system",
  "newTests": ["\$nt"], "testEdits": [],
  "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the repo's test system, so its parent commit has no runner; the captain watches the suite run at Verify" }
RJ
    ;;
  t-002)
    mkdir -p src tests/suite
    printf 'pub fn greet() -> &%sstatic str { "hello" }\npub fn add(a: i32, b: i32) -> i32 { a + b }\n' "'" > src/lib.rs
    # THE FORGE: names the new symbol (so the PARENT leg fails to COMPILE — an
    # honest red) and then asserts NOTHING, printing libtest's grammar instead.
    cat > tests/suite/main.rs <<'X'
fn main() {
    // Names the new symbol, so the PARENT leg genuinely fails to COMPILE.
    let _unused: fn(i32, i32) -> i32 = gfapp::add;
    // A "recognizable assertion" that asserts nothing about add() — enough to
    // clear the S133 quality floor, which reads the test FILE, not the run.
    assert_eq!(2 + 2, 4);
    println!("running 2 tests");
    println!("test greets ... ok");
    println!("test adds ... ok");
    println!("test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s");
}
X
    cat > "\$out/result.json" <<RJ
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "add() sums two numbers",
  "newTests": [], "testEdits": [{ "path": "tests/suite/main.rs", "reason": "extend the custom-harness suite to cover add()" }], "flipFlop": "expected" }
RJ
    ;;
esac
exit 0
WORKER
chmod +x "$SHIM/claude"; cp "$SHIM/claude" "$SHIM/copilot"
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "SPEND FUSE TRIPPED — REFUSING"; exit 1; }

REPO="$OUTDIR/gf-forge-dir"; rm -rf "$REPO"; mkdir -p "$REPO"
git -C "$REPO" init -q; git -C "$REPO" config user.email t@e.x; git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
printf '# gf\n\nA blank project.\n' > "$REPO/README.md"; printf '# ctx\n' > "$REPO/CONTEXT.md"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm "initial commit" >/dev/null 2>&1
mkdir -p "$REPO/.git/lcars/missions/init-001/manifests" "$REPO/.git/lcars/missions/init-001/tickets"
printf '{\n  "version": 1\n}\n' > "$REPO/.git/lcars/config.json"
MD="$REPO/.git/lcars/missions/init-001"
BASE="$(git -C "$REPO" symbolic-ref --short HEAD)"
cat > "$MD/state.json" <<JSON
{ "id": "init-001", "missionType": "initialization", "type": "feature",
  "title": "Establish the foundation", "stage": "implement",
  "branch": "lcars/init-001", "base": "$BASE",
  "workerBin": "claude", "workerCli": "claude" }
JSON
cat > "$MD/approved-plan.json" <<'JSON'
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
cat > "$MD/waves.json" <<'JSON'
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
printf '## Relevant files\n- the foundation\n' > "$MD/manifests/t-001.md"
printf '## Relevant files\n- the slice\n' > "$MD/manifests/t-002.md"

echo "S193 FORGE stage drive — artifacts: $OUTDIR"
OUT="$( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
      LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 LCARS_SETUP_INSTALL_TIMEOUT_SECS=300 \
      bash "$RUN_SH" implement --mission init-001 2>&1 )"; RC=$?
printf '%s\n' "$OUT" > "$OUTDIR/stage.log"
echo "stage rc=$RC · worker sessions: $(awk '/^SPAWN/{n++}END{print n+0}' "$SPEND") · billable: $(awk '/billable=yes/{n++}END{print n+0}' "$SPEND")"
echo
FF="$MD/tickets/t-002/flip-flop.json"
if [ -f "$FF" ]; then
  cp "$FF" "$OUTDIR/flipflop.forge.json"
  V="$(sed -n 's/.*"verdict"[^"]*"\([^"]*\)".*/\1/p' "$FF" | head -1)"
  echo "flip-flop verdict: $V"
  sed -n 's/.*"reason"[^"]*"\([^"]*\)".*/  reason: \1/p' "$FF" | head -1
  if [ "$V" = pass ]; then
    echo "  >>> HOLLOW PASS: ticket 2 PASSED with ZERO tests executed on the tip."
  else
    echo "  >>> refused (verdict '$V') — the forge did not get through."
  fi
else
  echo "no flip-flop.json for t-002 — tail:"; printf '%s\n' "$OUT" | tail -20
fi
echo
echo "--- BY HAND at the mission tip: how many tests really ran? ---"
BR=lcars/init-001
if git -C "$REPO" rev-parse "$BR" >/dev/null 2>&1; then
  WT="$OUTDIR/byhand"; rm -rf "$WT"
  git -C "$REPO" worktree add -q --detach "$WT" "$BR"
  ( cd "$WT" && cargo test ) > "$OUTDIR/byhand.log" 2>&1; echo "by-hand rc=$?"
  grep -E '^test result:|^running' "$OUTDIR/byhand.log" | sed 's/^/   /'
  echo "   (the '2 passed' board above is a println!, not a test run — the crate"
  echo "    executes NO #[test] and asserts nothing about add())"
  echo "--- DISCRIMINATION: break add() and re-run ---"
  perl -pi -e 's/\{ a \+ b \}/{ a - b }/' "$WT/src/lib.rs"
  ( cd "$WT" && cargo test ) > "$OUTDIR/byhand-broken.log" 2>&1; BRC=$?
  echo "   broken-impl rc=$BRC $([ "$BRC" -eq 0 ] && echo '<-- SUITE DOES NOT DISCRIMINATE' || echo '(went red)')"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || :
fi
echo "artifacts: $OUTDIR"
