"""Build broken variants and require each S371 control to fail by assertion."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
BASE = "f846b5a"
ECH = "skills/lcars-eeh/ech.sh"


def replace(text, old, new):
    if text.count(old) != 1:
        raise ValueError("mutation must replace exactly one site: " + repr(old))
    return text.replace(old, new)


def function(text, name):
    start = text.index("\n" + name + "() {") + 1
    end = text.index("\n}\n", start) + 3
    return text[start:end]


def run(name, file, edit, test):
    with tempfile.TemporaryDirectory(prefix="s371-mutant-") as directory:
        source = Path(directory)
        shutil.copytree(ROOT / "skills", source / "skills")
        shutil.copy2(ROOT / "install.sh", source / "install.sh")
        path = source / file
        original = path.read_text()
        changed = edit(original)
        if changed == original:
            raise ValueError("mutation changed nothing: " + name)
        path.write_text(changed)
        env = dict(os.environ, LCARS_TEST_SKILLS=str(source / "skills"),
                   LCARS_TEST_SOURCE=str(source))
        start = time.monotonic()
        result = subprocess.run(
            ["bash", str(ROOT / "tests/loose-ends.test.sh"), "LooseEnds.test_" + test],
            cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=600)
        print("%s: %.1fs exit %s" % (name, time.monotonic() - start, result.returncode),
              flush=True)
        print(result.stdout, flush=True)
        if result.returncode != 1 or ("FAIL: test_" + test + " (") not in result.stdout:
            raise SystemExit("mutation proof failed: " + name)


baseline = subprocess.run(["git", "show", BASE + ":" + ECH], cwd=ROOT,
                          check=True, capture_output=True, text=True).stdout
preflight = "preflight_preserves_recorded_false_and_siblings"
init = "fresh_init_is_off_and_preflight_does_not_opt_in"
policy = "policy_off_uses_recorded_live_verdict_not_stale_xo"
review = "verify_requests_declared_review_and_retries_failure_without_second_pr"
refresh = "seat_refresh_tests_exact_branch_then_pushes_without_merging"
moving = "refresh_rejects_success_shaped_failure_and_a_moving_head"
wait = "seat_await_is_bounded_and_only_waits_for_a_parallel_slot"
install = "worktree_install_refuses_live_agents_and_eeh_names_every_dangling_link"

run("preflight restores its old ON recommendation", ECH, lambda s: replace(
    s, function(s, "pf_q_number_one"), function(baseline, "pf_q_number_one")), preflight)
run("fresh init enables Number One", "skills/lcars-init/init.sh", lambda s: replace(
    s, 'numberOne={\\"enabled\\": false}$VERSION_LINE',
    'numberOne={\\"enabled\\": true}$VERSION_LINE'), init)
run("policy requires an absent Number One verdict", ECH, lambda s: replace(
    s, 'if [ "$(jfile "$CFG" numberOne.enabled)" = false ]; then',
    'if false; then'), policy)
run("stale Number One advice overrides OFF policy", ECH, lambda s: replace(replace(
    s, 'if [ -n "$mission" ] && [ "$verdict" != off ]; then',
    'if [ -n "$mission" ]; then'),
    'elif [ "$verdict" = off ]; then',
    'elif [ "$verdict" = off ] && [ -z "$rec" ]; then'), policy)
run("policy ignores the recorded live verdict", ECH, lambda s: replace(
    s, 'local recorded; recorded="$(ap_j "liveChecks.$mission.verdict")"',
    'local recorded; recorded="$live"'), policy)
run("instruction contracts silently opt out", "skills/lcars-approve/pr-reviewers.py",
    lambda s: replace(s, "if contracts:", "if False:"), review)
run("review requests are silently skipped", "skills/lcars-approve/pr-lib.sh",
    lambda s: replace(s, '  [ -n "$reviewers" ] || return 0',
                      '  return 0\n  [ -n "$reviewers" ] || return 0'), review)
run("failed review is called success", "skills/lcars-run/host-adapter.sh",
    lambda s: replace(s, '  "$GH_BIN" pr edit "$1" --add-reviewer "$2"',
                      '  "$GH_BIN" pr edit "$1" --add-reviewer "$2"\n  return 0'), review)
run("Copilot alias becomes an ordinary user login", "skills/lcars-approve/pr-reviewers.py",
    lambda s: replace(s, 'value if value == "@copilot" else value.removeprefix("@")',
                      'value.removeprefix("@")'), review)
run("multi-reviewer receipt cannot round-trip", "skills/lcars-approve/pr-lib.sh",
    lambda s: replace(s, '$(printf \'%s\' "$reviewers" | tr \'\\n\' \',\')', '$reviewers'), review)
run("seat refresh loses its scope gate", ECH, lambda s: replace(
    s, '  subech_scope_or_die refresh "$m"', '  :'), refresh)
run("validator may publish fixes", ECH, lambda s: replace(
    s, "drive*|refresh*)                    printf 'fix'",
    "refresh*)                           printf 'look' ;;\n"
       "    drive*)                             printf 'fix'"), refresh)
run("refresh accepts a failed suite", ECH, lambda s: replace(
    s, '  [ "$rc" -eq 0 ] || die "refresh: suite FAILED (exit $rc); NOTHING pushed."',
    "  :"), refresh)
run("refresh trusts success-shaped FAILED output", ECH, lambda s: replace(
    s, "  if grep -qE '(^|[^A-Za-z])(FAILED|FAIL:)([^A-Za-z]|$)' <<<\"$out\"; then",
    "  if false; then"), moving)
run("suite changes which checkout it tested", ECH, lambda s: replace(
    s, '  [ "$("$GIT_BIN" -C "$wt" rev-parse HEAD)" = "$tip" ] \\\n'
       '    && "$GIT_BIN" -C "$wt" diff --quiet HEAD -- \\\n'
       '    || die "refresh: suite changed the tested checkout; NOTHING pushed."',
    "  :"), moving)
run("refresh pushes an untested moving head", ECH, lambda s: replace(
    s, '  [ "$("$GIT_BIN" -C "$CWD" rev-parse "refs/heads/$br")" = "$tip" ] \\\n'
       '    || die "refresh: Mission head moved during the suite; NOTHING pushed. Re-run."',
    "  :"), moving)
run("refresh tests the root instead of the Mission", ECH, lambda s: replace(
    s, '  out="$(cd "$wt" && HOME="$home" eval "$tc" 2>&1)"; rc=$?',
    '  out="$(cd "$CWD" && HOME="$home" eval "$tc" 2>&1)"; rc=$?'), refresh)
run("refresh pushes main as well as the Mission", ECH, lambda s: replace(
    s, '"$tip:refs/heads/$br" \\\n', '"$tip:refs/heads/$br" "main:refs/heads/main" \\\n'), refresh)
run("seat await is unreachable", ECH, lambda s: replace(
    s, '    --await) shift; cmd_seat_await "$@"; return $? ;;',
    '    --await) die "mutant: seats cannot await" ;;'), wait)
run("await reports a full board as free", ECH, lambda s: replace(
    s, '    if [ "$held" -lt "$MAX_SLOTS" ]; then',
    '    if true; then'), wait)
run("worktree install can repoint live agents", "install.sh", lambda s: replace(
    s, 'if [ "$MODE" != uninstall ] && [ -f "$REPO_ROOT/.git" ]',
    'if false'), install)
run("EEH ignores broken agent links", "skills/lcars-eeh/eeh.sh", lambda s: replace(
    s, 'for agent_link in "$AGENTS_DEST"/*; do',
    'for agent_link in "$AGENTS_DEST/no-such-agent"; do'), install)
run("EEH calls an in-checkout dangling skill synced", "skills/lcars-eeh/eeh.sh",
    lambda s: replace(s, '  if [ ! -e "$entry" ]; then', '  if false; then'), install)
run("EEH never checks the plugin resolves", "skills/lcars-eeh/eeh.sh", lambda s: replace(
    s, '  [ -e "$cop_link" ] || echo "  DANGLING installed plugin: $cop_link -> $(readlink "$cop_link")"',
    '  :'), install)
run("installer ignores unresolved installed links", "install.sh", lambda s: replace(
    s, '  [ "$broken" -eq 0 ] || return 1', '  :'), install)
print("25/25 broken variants rejected by their designated controls", flush=True)
