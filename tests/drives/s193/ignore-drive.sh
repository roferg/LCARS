#!/usr/bin/env bash
# S193 TESTER — ESCALATION 2: the NO-FORGERY hollow pass. Ticket 2's own test
# is #[ignore]d, so it NEVER RUNS; ticket 1's test still passes, so the cargo run
# reports a non-zero scoreboard and the AGGREGATE rule reads the run as "some".
#
# Shape: ticket 1 (the waived scaffold) establishes `cargo test` AND declares a
# `harness = false` custom-harness test target — a legitimate, documented cargo
# feature. Ticket 2 rewrites that target so that it
#   * REFERENCES the new symbol (so the PARENT leg genuinely fails to compile —
#     an HONEST red, kind compile-failure), and
#   * ASSERTS NOTHING and prints libtest's scoreboard grammar at column 0.
# ZERO tests execute on the tip. If the gate says pass, that is a green-on-nothing.
#
# ZERO SPEND: PATH shim with COUNTING fakes for BOTH claude and copilot, spend fuse.
set -u
LCARS_SRC="${LCARS_SRC:-/Users/roganferguson/Projects/LCARS}"
RUN_SH="${RUN_SH:-$LCARS_SRC/skills/lcars-run/run.sh}"
OUTDIR="${OUTDIR:-$(mktemp -d "${TMPDIR:-/tmp}/s193forge.XXXXXX")}"
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
X
    printf 'target/\n' > "\$out/setup/.gitignore"
    printf '{ "package": "", "gap": "this repo has no test system at all", "installCommand": "" }\n' > "\$out/test-setup.json"
    mkdir -p src tests
    printf 'pub fn greet() -> &%sstatic str { "hello" }\n' "'" > src/lib.rs
    printf 'use gfapp::greet;\n#[test]\nfn greets(){ assert_eq!(greet(), "hello"); }\n' > tests/greet.rs
    nt=tests/greet.rs
    cat > "\$out/result.json" <<RJ
{ "ticketId": "t-001", "passed": true, "attempts": 1,
  "summary": "establish the project skeleton and its test system",
  "newTests": ["\$nt"], "testEdits": [],
  "flipFlop": "not-applicable",
  "flipFlopReason": "this ticket CREATES the repo's test system, so its parent commit has no runner; the captain watches the suite run at Verify" }
RJ
    ;;
  t-002)
    mkdir -p src tests
    printf 'pub fn greet() -> &%sstatic str { "hello" }\npub fn add(a: i32, b: i32) -> i32 { a + b }\n' "'" > src/lib.rs
    # NO FORGERY. The ticket's own test names the new symbol (so the PARENT leg
    # genuinely fails to COMPILE — an honest red) and is #[ignore]d, so on the TIP
    # it NEVER RUNS. tests/greet.rs from ticket 1 still passes, so the aggregate
    # cargo verdict is "some" and the green-on-nothing trap stays silent.
    cat > tests/add.rs <<'X'
use gfapp::add;

#[test]
#[ignore]
fn adds() {
    assert_eq!(add(2, 2), 4);
}
X
    cat > "\$out/result.json" <<RJ
{ "ticketId": "t-002", "passed": true, "attempts": 1,
  "summary": "add() sums two numbers",
  "newTests": ["tests/add.rs"], "testEdits": [], "flipFlop": "expected" }
RJ
    ;;
esac
exit 0
WORKER
chmod +x "$SHIM/claude"; cp "$SHIM/claude" "$SHIM/copilot"
[ -x "$SHIM/claude" ] && [ -x "$SHIM/copilot" ] || { echo "SPEND FUSE TRIPPED — REFUSING"; exit 1; }

REPO="$OUTDIR/gf-ignore"; rm -rf "$REPO"; mkdir -p "$REPO"
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

echo "S193 IGNORE stage drive — artifacts: $OUTDIR"
OUT="$( cd "$REPO" && env PATH="$SHIM:$PATH" LCARS_GH_BIN=true LCARS_GIT_BIN="$(command -v git)" \
      LCARS_WORKER_TRIES=1 LCARS_EMPTY_WORKER_TRIES=1 LCARS_SETUP_INSTALL_TIMEOUT_SECS=300 \
      bash "$RUN_SH" implement --mission init-001 2>&1 )"; RC=$?
printf '%s\n' "$OUT" > "$OUTDIR/stage.log"
echo "stage rc=$RC · worker sessions: $(awk '/^SPAWN/{n++}END{print n+0}' "$SPEND") · billable: $(awk '/billable=yes/{n++}END{print n+0}' "$SPEND")"
echo
FF="$MD/tickets/t-002/flip-flop.json"
if [ -f "$FF" ]; then
  cp "$FF" "$OUTDIR/flipflop.ignore.json"
  V="$(sed -n 's/.*"verdict"[^"]*"\([^"]*\)".*/\1/p' "$FF" | head -1)"
  echo "flip-flop verdict: $V"
  sed -n 's/.*"reason"[^"]*"\([^"]*\)".*/  reason: \1/p' "$FF" | head -1
  if [ "$V" = pass ]; then
    echo "  >>> HOLLOW PASS: ticket 2 PASSED though its own test never executed."
  else
    echo "  >>> refused (verdict '$V') — the ignored-test hollow pass did not get through."
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
  echo "   (the ticket's own test 'adds' is #[ignore]d — it NEVER RAN; the only"
  echo "    passing board belongs to ticket 1's greet test)"
  echo "--- DISCRIMINATION: break add() and re-run ---"
  perl -pi -e 's/\{ a \+ b \}/{ a - b }/' "$WT/src/lib.rs"
  ( cd "$WT" && cargo test ) > "$OUTDIR/byhand-broken.log" 2>&1; BRC=$?
  echo "   broken-impl rc=$BRC $([ "$BRC" -eq 0 ] && echo '<-- SUITE DOES NOT DISCRIMINATE' || echo '(went red)')"
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || :
fi
echo "artifacts: $OUTDIR"
